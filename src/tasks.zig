//! Tasks: a call running as a task of its own (`f(x)&`), sets of tasks
//! (`Tasks[T]`), waiting for several (`task.both`, `task.all`), how a
//! task is canceled, deadlines (`time.within`), and calling a function
//! on each element on several tasks (`par.map`, `par.each`). The runtime (`runtime.zig`) imports this file and
//! gives emitted code its names (`rig.Task`, `rig.Tasks`,
//! `rig.waitTasks`); `bin/rig` writes it beside the runtime as
//! `rig/tasks.zig`.

const std = @import("std");
const rt = @import("runtime.zig");

const Int = rt.Int;
const List = rt.List;
const defaultAllocator = rt.defaultAllocator;
const dropElement = rt.dropElement;
const io = rt.io;
const oom = rt.oom;
const task = rt.task;


/// `Task(T)`: a call running as a task of its own (`f(x)&`), which gives
/// a `T` when it ends. It runs as a fiber of the scheduler (`rt.sched`),
/// on a stack of its own. `wait` takes its result. Dropping a task that can fail cancels it and waits for
/// it; dropping one that cannot only waits, unless the task dropping it
/// is canceled. Either way its result is
/// dropped, so no task outlives the scope that holds it, nor the loans
/// it was given.
///
/// Cancellation. A cancel reaches a task only at its fallible waiting
/// points (`check`, `sleep`, a wait on a set, and `wait` on a task). It
/// is sticky: the `Control` the task shares with its owner records it,
/// it ends a wait the task is in that a cancel may end, and every
/// waiting point the task reaches after it fails with
/// `task.Stop.canceled`.
pub fn Task(comptime T: type) type {
    return struct {
        handle: Handle(T),
        control: *Control,

        const Self = @This();
        /// Its arguments, for `typeName`.
        pub const __rig_args = .{T};
        const fallible = @typeInfo(T) == .error_union;

        /// `f(args...)&`: start the call as a task, which keeps the
        /// deadline of the task starting it.
        pub fn spawn(comptime f: anytype, args: anytype) Self {
            const Args = @TypeOf(args);
            // A fiber is on a stack of its own already, and the runtime
            // keeps its state per fiber. `run` gives `T` even where `f` is
            // generic.
            const Fiber = struct {
                fn run(control: *Control, deadline: ?i96, a: Args) T {
                    task().control = control;
                    task().deadline = deadline;
                    defer control.finish();
                    return @call(.auto, f, a);
                }
            };
            // The task's record holds its `Control`: one allocation for
            // both.
            const made = rt.sched.spawn(T, Control, Fiber.run, .{ task().deadline, args });
            return .{ .handle = .{ .job = made.job }, .control = made.extra };
        }

        /// `recv.name(args...)&`: start a method's call as a task. `recv`
        /// is the receiver's address, or the address of a view of it. A
        /// method that takes its receiver by value is given it here,
        /// before the task starts.
        pub fn spawnMethod(recv: anytype, comptime name: []const u8, args: anytype) Self {
            const P = @TypeOf(recv);
            const Ptr = if (@typeInfo(@typeInfo(P).pointer.child) == .pointer) @typeInfo(P).pointer.child else P;
            const ptr: Ptr = if (Ptr == P) recv else recv.*;
            const method = @field(@typeInfo(Ptr).pointer.child, name);
            const Receiver = @typeInfo(@TypeOf(method)).@"fn".param_types[0].?;
            if (@typeInfo(Receiver) == .pointer) return spawn(method, .{ptr} ++ args);
            return spawn(method, .{ptr.*} ++ args);
        }

        /// `<t.wait()`: wait for the task to end and take its result. A
        /// task that waits passes a cancel on to the task it waits for:
        /// one canceled before the wait cancels it, and one canceled
        /// during the wait wakes the waiter, which passes it on. Waiting
        /// on a task that can fail is a fallible waiting point, so a
        /// canceled waiter drops the result and fails; waiting on one that
        /// cannot fail finishes, and the cancel stays for the waiter's
        /// next waiting point. Waiting on a task that can fail is also
        /// stopped by the waiter's deadline (`time.within`): the task is
        /// canceled and waited for, and the wait fails with
        /// `task.Stop.timeout`.
        pub fn wait(self: Self) T {
            var t = self;
            defer t.release();
            if (canceledHere()) {
                var result = t.stop();
                if (comptime !fallible) return result;
                dropElement(T, &result);
                return canceled_error;
            }
            var result: T = undefined;
            // A cancel that comes to the waiter during the wait wakes it,
            // and it passes the cancel on to the task it waits on, then
            // waits for that task's end.
            const job = t.handle.job;
            const mine: ?*const std.atomic.Value(bool) = if (task().control) |c| &c.canceled else null;
            const deadline = if (fallible) task().deadline else null;
            var timed_out = false;
            if (!job.waitEnd(mine, deadline)) {
                timed_out = !(if (mine) |c| c.load(.acquire) else false);
                t.control.cancel();
                _ = job.waitEnd(null, null);
            }
            result = job.result;
            if (comptime fallible) if (timed_out) {
                dropElement(T, &result);
                return timeout_error;
            };
            // Canceled while it waited, even when the task ended before
            // the cancel could reach it.
            const passed_on = t.control.canceled.load(.acquire) or (if (mine) |c| c.load(.acquire) else false);
            if (!passed_on) return result;
            markCanceled();
            if (comptime !fallible) return result;
            dropElement(T, &result);
            return canceled_error;
        }

        /// `<t.cancel()`: cancel the task, wait for it, and take what it
        /// gave: `task.Stop.canceled` when the cancel reached it, or its
        /// result when it ended first. Only a task that can fail is
        /// canceled; the checker rejects any other.
        pub fn cancel(self: Self) T {
            var t = self;
            defer t.release();
            return t.stop();
        }

        pub fn __rig_print(_: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeAll("<task>");
        }

        /// A task that cannot fail is waited for, unless the task that
        /// drops it is canceled, which passes the cancel on.
        pub fn __rig_drop(self: *Self) void {
            defer self.release();
            var result = if (fallible or canceledHere()) self.stop() else self.handle.result();
            dropElement(T, &result);
        }

        /// Record the cancel, which ends a wait the task is in that a
        /// cancel may end, and wait for the task.
        fn stop(self: *Self) T {
            self.control.cancel();
            return self.handle.stopped();
        }

        fn release(self: *Self) void {
            self.handle.free();
        }
    };
}

/// How a task is held: its fiber's record, which keeps its result once
/// it ends. `result` waits for the task and gives what it gave, again on
/// a later call; `stopped` does so once a cancel is recorded.
fn Handle(comptime T: type) type {
    return struct {
        job: *rt.sched.Job(T),

        fn result(h: *@This()) T {
            return h.job.join();
        }

        /// A fiber sees the cancel at its next waiting point, or in the
        /// wait it is in (`Control.cancel`).
        fn stopped(h: *@This()) T {
            return h.job.join();
        }

        /// The task has ended and its result is kept for a later wait.
        fn keep(_: *@This(), _: T) void {}

        fn free(h: *@This()) void {
            h.job.free();
        }
    };
}

/// What a task and its owner share: whether the task is canceled, and
/// whether it has ended. Its owner records a cancel (`cancel`), and the
/// task records one that reaches it through a wait (`Task.wait`). A task in a set, or in `task.both`, also tells the
/// `Wakeup` of what waits on it when it ends. Allocated outside the leak
/// count, as the backend's own records are.
pub const Control = struct {
    canceled: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    wakeup: std.atomic.Value(?*Wakeup) = .init(null),
    /// The task's fiber, whose wait a cancel ends
    /// (`rt.sched.interruptForCancel`).
    fiber: ?*rt.sched.Fiber = null,

    /// Record a cancel, and end the wait the task is in, when a cancel
    /// may end it. A task waiting on another passes
    /// the cancel on itself (`Task.wait`).
    fn cancel(self: *Control) void {
        self.canceled.store(true, .seq_cst);
        if (self.fiber) |f| rt.sched.interruptForCancel(f);
    }

    /// The task has ended: record it, then wake what waits on it. A
    /// waiter that registers after the task ends finds `done` set
    /// (`Wakeup.watch`), so no end goes unseen.
    fn finish(self: *Control) void {
        self.done.store(true, .seq_cst);
        if (self.wakeup.load(.seq_cst)) |w| w.tick();
    }
};

/// What a set of tasks, or `task.both`, waits on: a count each of its
/// tasks adds to as it ends, which a waiter sleeps on until it changes.
const Wakeup = struct {
    ticks: std.atomic.Value(u32) = .init(0),
    /// The fiber waiting on the count and the epoch of its wait
    /// (`rt.sched.Wait`).
    waiter: std.atomic.Value(?*anyopaque) = .init(null),
    waiter_epoch: std.atomic.Value(u32) = .init(0),

    fn create() *Wakeup {
        const w = std.heap.smp_allocator.create(Wakeup) catch oom();
        w.* = .{};
        return w;
    }

    fn destroy(self: *Wakeup) void {
        std.heap.smp_allocator.destroy(self);
    }

    fn watch(self: *Wakeup, control: *Control) void {
        control.wakeup.store(self, .seq_cst);
    }

    fn tick(self: *Wakeup) void {
        _ = self.ticks.fetchAdd(1, .seq_cst);
        if (self.waiter.load(.seq_cst)) |f| _ = rt.sched.interrupt(@ptrCast(@alignCast(f)), self.waiter_epoch.load(.seq_cst), false);
    }

    /// Sleep until a watched task ends after `seen` was read, the
    /// deadline or the waiter's own passes, or the waiter is canceled: a
    /// waiting point.
    fn sleep(self: *Wakeup, seen: u32, within: ?i96) Stop!void {
        const deadline = earlier(within, task().deadline);
        if (canceledHere()) return canceled_error;
        if (deadline) |d| if (nowNs() >= d) return timeout_error;
        // The fiber sleeps until a tick, the deadline, or a cancel wakes it.
        while (self.ticks.load(.seq_cst) == seen) {
            if (canceledHere()) return canceled_error;
            if (deadline) |d| if (nowNs() >= d) return timeout_error;
            const e = rt.sched.beginWait(true);
            self.waiter.store(rt.sched.current().?, .seq_cst);
            self.waiter_epoch.store(e, .seq_cst);
            if (self.ticks.load(.seq_cst) != seen) return;
            if (canceledHere()) return canceled_error;
            rt.sched.commitWait(e, deadline);
        }
    }
};

/// What `task.both` and `task.all` give for the tasks `Tup` (a tuple of
/// `Task`s): each one's value, in order, failing when any can fail.
fn TaskValues(comptime Tup: type) type {
    const tasks = @typeInfo(Tup).@"struct".field_types;
    var values: [tasks.len]type = undefined;
    var fallible = false;
    for (tasks, &values) |Tk, *V| {
        const R = Tk.__rig_args[0];
        if (@typeInfo(R) == .error_union) {
            fallible = true;
            V.* = @typeInfo(R).error_union.payload;
        } else V.* = R;
    }
    const Values = @Tuple(&values);
    return if (fallible) anyerror!Values else Values;
}

/// `task.both(a, b)`, `task.all(a, b, c, ...)`: wait for tasks of any
/// types, and give each one's value. When some can fail, waiting is a
/// waiting point, and the first task to fail, in the order they end,
/// cancels the others: the call waits for them, drops what they gave,
/// and fails with its error.
pub fn waitTasks(tasks: anytype) TaskValues(@TypeOf(tasks)) {
    const Tup = @TypeOf(tasks);
    const n = @typeInfo(Tup).@"struct".field_types.len;
    const Out = TaskValues(Tup);
    const fallible = @typeInfo(Out) == .error_union;
    const Values = if (fallible) @typeInfo(Out).error_union.payload else Out;
    var values: Values = undefined;
    if (comptime !fallible) {
        inline for (0..n) |i| values[i] = tasks[i].wait();
        return values;
    }
    var ts = tasks;
    const w = Wakeup.create();
    defer w.destroy();
    inline for (0..n) |i| w.watch(ts[i].control);
    var taken: [n]bool = @splat(false);
    var got: [n]bool = @splat(false);
    var left: usize = n;
    var failure: ?anyerror = null;
    while (left > 0 and failure == null) {
        const seen = w.ticks.load(.seq_cst);
        inline for (0..n) |i| {
            if (failure == null and !taken[i] and ts[i].control.done.load(.seq_cst)) {
                taken[i] = true;
                left -= 1;
                const result = ts[i].handle.result();
                ts[i].release();
                const R = @TypeOf(result);
                if (@typeInfo(R) == .error_union) {
                    if (result) |v| {
                        values[i] = v;
                        got[i] = true;
                    } else |err| failure = err;
                } else {
                    values[i] = result;
                    got[i] = true;
                }
            }
        }
        if (left > 0 and failure == null) w.sleep(seen, null) catch |err| {
            failure = err;
        };
    }
    const err = failure orelse return values;
    inline for (0..n) |i| if (!taken[i]) ts[i].control.cancel();
    inline for (0..n) |i| if (!taken[i]) {
        var result = ts[i].handle.stopped();
        dropElement(@TypeOf(result), &result);
        ts[i].release();
    };
    inline for (0..n) |i| if (got[i]) dropElement(@TypeOf(values[i]), &values[i]);
    return err;
}

/// The monotonic clock, in nanoseconds: the time a deadline counts on,
/// virtual in a deterministic run (`rt.sched.deterministic`).
fn nowNs() i96 {
    return rt.sched.nowNs();
}

/// `time.monotonic()`: the monotonic clock, which a deterministic run
/// keeps virtual.
pub fn monotonicNs() Int {
    return @intCast(nowNs());
}

/// The deadline `within` nanoseconds from now, or none.
fn deadlineIn(within: ?Int) ?i96 {
    const ns = within orelse return null;
    return nowNs() + ns;
}

/// The earlier of two deadlines, either of which may be none.
fn earlier(a: ?i96, b: ?i96) ?i96 {
    const x = a orelse return b;
    const y = b orelse return a;
    return @min(x, y);
}

/// Whether the running task's deadline has passed.
fn pastDeadline() bool {
    const d = task().deadline orelse return false;
    return nowNs() >= d;
}

/// A deadline as `time.within` keeps it in an `Int`: none is the
/// largest.
const never: Int = std.math.maxInt(Int);

/// `time.within(ns, f)` begins: the running task's deadline becomes
/// `ns` nanoseconds from now, unless the one it has is earlier. Gives
/// the one it had, for `restoreDeadline`.
pub fn enterDeadline(ns: Int) Int {
    const t = task();
    const outer = t.deadline;
    t.deadline = earlier(outer, nowNs() + ns);
    return if (outer) |d| @intCast(d) else never;
}

/// `time.within(ns, f)` ends: the running task's deadline is again the
/// one `enterDeadline` gave.
pub fn restoreDeadline(outer: Int) void {
    task().deadline = if (outer == never) null else outer;
}

/// `task.Stop.timeout`, what a wait whose deadline passes fails with.
const timeout_error = error.@"std.task.Stop.timeout";

/// `Tasks(T)`: a set of tasks of one type (`Tasks[T]`), each added with
/// `add` and kept, with its loans, until a wait or the set's drop. A
/// set's tasks tell its `Wakeup` as each ends, so a wait sees them in the
/// order they end.
///
/// - `wait_all` gives every result, in the order added. In a set that
///   can fail, the first task to fail cancels the rest, and the wait
///   fails with its error.
/// - `wait_first`, only for a set that can fail, gives the first result
///   to succeed and cancels the rest; when every task fails, it fails
///   with the error of the last.
/// - `within` is a deadline in nanoseconds, only for a set that can
///   fail: when it passes, the rest are canceled and the wait fails with
///   `task.Stop.timeout`.
/// - Waiting on a set that can fail is a waiting point: a canceled
///   waiter cancels every task and fails with `task.Stop.canceled`.
/// - Dropping a set cancels every task that can fail first, then waits
///   for them all, so the cancels overlap.
/// - A set of tasks that give no result drops each one that has ended
///   well as the next is added, so a set a server adds to for its whole
///   life holds only those still running, and those that failed.
pub fn Tasks(comptime T: type) type {
    return struct {
        items: std.ArrayList(Task(T)) = .empty,
        wakeup: ?*Wakeup = null,
        /// How many tasks the set holds: `ts.len`.
        len: usize = 0,

        const Self = @This();
        /// Its arguments, for `typeName`.
        pub const __rig_args = .{T};
        const fallible = @typeInfo(T) == .error_union;
        const Value = if (fallible) @typeInfo(T).error_union.payload else T;
        /// What `wait_all` gives: the results, or nothing for tasks that
        /// give none.
        const Results = if (Value == void) void else List(Value);
        const All = if (fallible) anyerror!Results else Results;

        /// `!ts.add(t)`: take the task into the set.
        pub fn add(self: *Self, t: Task(T)) void {
            if (Value == void) self.dropEnded();
            // Only a set that can fail waits for whichever task ends
            // first; one that cannot waits for each in turn, so its tasks
            // need not tell a shared count as they end.
            if (fallible) {
                const w = self.wakeup orelse blk: {
                    const w = Wakeup.create();
                    self.wakeup = w;
                    break :blk w;
                };
                w.watch(t.control);
            }
            self.items.append(defaultAllocator(), t) catch oom();
            self.len = self.items.items.len;
        }

        /// Drop each task that has ended well, keeping one that failed
        /// for a wait to report.
        fn dropEnded(self: *Self) void {
            var kept: usize = 0;
            for (self.items.items) |*t| {
                if (t.control.done.load(.seq_cst)) {
                    var result = t.handle.result();
                    const ok = if (fallible) !std.meta.isError(result) else true;
                    if (ok) {
                        dropElement(T, &result);
                        t.release();
                        continue;
                    }
                    // Its result is kept: its handle is spent, so the task
                    // is kept as one already waited for.
                    t.handle.keep(result);
                }
                self.items.items[kept] = t.*;
                kept += 1;
            }
            self.items.items.len = kept;
        }

        /// `<ts.wait_all()`: every result, in the order added; nothing
        /// for tasks that give none.
        pub fn wait_all(self: Self, within: ?Int) All {
            var s = self;
            defer s.free();
            const n = s.items.items.len;
            if (comptime !fallible) {
                if (comptime Value == void) {
                    for (s.items.items) |t| t.wait();
                    return;
                }
                var out = List(Value).initCapacity(@intCast(n));
                for (s.items.items) |t| out.push(t.wait());
                return out;
            }
            const deadline = deadlineIn(within);
            const results = defaultAllocator().alloc(Value, n) catch oom();
            defer defaultAllocator().free(results);
            // `taken`: waited for; `got`: waited for, and gave a result.
            const flags = defaultAllocator().alloc(bool, 2 * n) catch oom();
            defer defaultAllocator().free(flags);
            @memset(flags, false);
            const taken = flags[0..n];
            const got = flags[n..];
            var left = n;
            while (left > 0) {
                const seen = s.wakeup.?.ticks.load(.seq_cst);
                for (s.items.items, 0..) |*t, i| {
                    if (taken[i] or !t.control.done.load(.seq_cst)) continue;
                    taken[i] = true;
                    left -= 1;
                    const result = t.handle.result();
                    t.release();
                    if (result) |v| {
                        results[i] = v;
                        got[i] = true;
                    } else |err| {
                        s.stopUntaken(taken);
                        dropGot(results, got);
                        return err;
                    }
                }
                if (left == 0) break;
                s.wakeup.?.sleep(seen, deadline) catch |err| {
                    s.stopUntaken(taken);
                    dropGot(results, got);
                    return err;
                };
            }
            if (comptime Value == void) return;
            var out = List(Value).initCapacity(@intCast(n));
            for (results) |v| out.push(v);
            return out;
        }

        /// `<ts.wait_first()`: the first result to succeed.
        pub fn wait_first(self: Self, within: ?Int) T {
            if (comptime !fallible) @compileError("rig: wait_first is only for a set that can fail");
            var s = self;
            defer s.free();
            const n = s.items.items.len;
            if (n == 0) @panic("wait_first on a set with no tasks");
            const deadline = deadlineIn(within);
            const taken = defaultAllocator().alloc(bool, n) catch oom();
            defer defaultAllocator().free(taken);
            @memset(taken, false);
            var left = n;
            var last: anyerror = undefined;
            while (true) {
                const seen = s.wakeup.?.ticks.load(.seq_cst);
                for (s.items.items, 0..) |*t, i| {
                    if (taken[i] or !t.control.done.load(.seq_cst)) continue;
                    taken[i] = true;
                    left -= 1;
                    const result = t.handle.result();
                    t.release();
                    if (result) |v| {
                        s.stopUntaken(taken);
                        s.items.items.len = 0;
                        return v;
                    } else |err| last = err;
                }
                if (left == 0) {
                    s.items.items.len = 0;
                    return last;
                }
                s.wakeup.?.sleep(seen, deadline) catch |err| {
                    s.stopUntaken(taken);
                    s.items.items.len = 0;
                    return err;
                };
            }
        }

        /// Cancel every task not yet taken, then wait for each and drop
        /// what it gave.
        fn stopUntaken(self: *Self, taken: []const bool) void {
            for (self.items.items, taken) |t, k| {
                if (!k) t.control.cancel();
            }
            for (self.items.items, taken) |*t, k| {
                if (k) continue;
                var result = t.handle.stopped();
                dropElement(T, &result);
                t.release();
            }
        }

        /// Drop the results a failed wait had gathered.
        fn dropGot(results: []Value, got: []const bool) void {
            for (results, got) |*v, g| if (g) dropElement(Value, v);
        }

        fn free(self: *Self) void {
            self.items.deinit(defaultAllocator());
            if (self.wakeup) |w| w.destroy();
        }

        pub fn __rig_print(self: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.print("<{d} tasks>", .{self.items.items.len});
        }

        /// Cancel first, when the tasks can fail or the task dropping the
        /// set is canceled, then wait for each.
        pub fn __rig_drop(self: *Self) void {
            defer self.free();
            if (fallible or canceledHere()) {
                for (self.items.items) |t| t.control.cancel();
            }
            for (self.items.items) |*t| {
                var result = if (fallible or canceledHere()) t.handle.stopped() else t.handle.result();
                dropElement(T, &result);
                t.release();
            }
        }
    };
}

/// What a function lent as `f` (a `rig.FnRef`) returns.
fn ReturnOf(comptime F: type) type {
    return @typeInfo(@TypeOf(F.call)).@"fn".return_type.?;
}

/// What `par.map` gives for `f`: a List of each call's value, failing
/// when `f` can.
fn MapOut(comptime F: type) type {
    const R = ReturnOf(F);
    if (@typeInfo(R) == .error_union) return anyerror!List(@typeInfo(R).error_union.payload);
    return List(R);
}

/// What `par.each` gives for `f`: nothing, failing when `f` can.
fn EachOut(comptime F: type) type {
    return if (@typeInfo(ReturnOf(F)) == .error_union) anyerror!void else void;
}

/// What the tasks of a `par.map` or `par.each` share: where the next
/// chunk of the elements starts, how long a chunk is, and the first
/// failure, which stops the others taking more.
const ParState = struct {
    next: std.atomic.Value(usize) = .init(0),
    n: usize,
    chunk: usize,
    failed: std.atomic.Value(bool) = .init(false),
    failure: anyerror = undefined,

    /// Record `err`, unless a failure came first.
    fn fail(self: *ParState, err: anyerror) void {
        if (self.failed.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) self.failure = err;
    }
};

/// Run `body(ctx, lo, hi)` over the chunks of `0..n`, on up to `limit`
/// tasks, or one per worker when `limit` is not positive: the calling
/// task and the ones it starts each take the next chunk in turn until
/// none is left. About eight chunks go to each task, so one that ends
/// early takes more, and a chunk holds at least one element. With one
/// task, or one chunk, the calling task runs them all. The first chunk
/// to fail stops the tasks taking more and cancels them, and once all
/// have ended, the run fails with its error.
fn parRun(comptime fallible: bool, n: usize, limit: Int, ctx: anytype, comptime body: anytype) if (fallible) anyerror!void else void {
    if (n == 0) return;
    const workers: usize = if (rt.scheduled) rt.sched.workersRunning() else 1;
    // Deterministic, on one thread, the elements are still split among
    // tasks, so the seed tries their interleavings.
    const want: usize = if (limit > 0) @intCast(limit) else if (rt.sched.deterministic) 4 else workers;
    const count = @min(want, n);
    const chunk = @max(1, n / (count * 8));
    if (count <= 1 or chunk >= n) return body(ctx, 0, n);
    var state: ParState = .{ .n = n, .chunk = chunk };
    const Ctx = @TypeOf(ctx);
    const Worker = struct {
        fn run(s: *ParState, c: Ctx) void {
            while (!s.failed.load(.acquire)) {
                const lo = s.next.fetchAdd(s.chunk, .monotonic);
                if (lo >= s.n) return;
                const hi = @min(lo + s.chunk, s.n);
                if (comptime fallible) {
                    body(c, lo, hi) catch |err| return s.fail(err);
                } else body(c, lo, hi);
            }
        }
    };
    const helpers = defaultAllocator().alloc(Task(void), count - 1) catch oom();
    defer defaultAllocator().free(helpers);
    for (helpers) |*t| t.* = Task(void).spawn(Worker.run, .{ &state, ctx });
    Worker.run(&state, ctx);
    if (fallible and state.failed.load(.acquire)) for (helpers) |t| t.control.cancel();
    for (helpers) |t| t.wait();
    if (comptime fallible) if (state.failed.load(.acquire)) return state.failure;
}

/// `par.map(?xs, f, limit: n)`: a List of `f(x)` for each element `x` of
/// the slice `xs`, in its order, each call on one of up to `limit` tasks
/// (`parRun`). Each task writes the values of its chunks in place. When
/// a call fails, the values made are dropped: those that need it are
/// marked as they are made.
pub fn parMap(xs: anytype, f: anytype, limit: Int) MapOut(@TypeOf(f)) {
    const F = @TypeOf(f);
    const R = ReturnOf(F);
    const fallible = @typeInfo(R) == .error_union;
    const V = if (fallible) @typeInfo(R).error_union.payload else R;
    var out = List(V).initCapacity(@intCast(xs.len));
    const Ctx = struct {
        xs: @TypeOf(xs),
        f: F,
        out: []V,
        made: if (marked) []bool else void,

        const marked = fallible and rt.needsDrop(V);

        fn chunk(c: *const @This(), lo: usize, hi: usize) if (fallible) anyerror!void else void {
            for (lo..hi) |i| {
                if (comptime fallible) {
                    c.out[i] = try c.f.call(.{rt.lend(&c.xs[i])});
                    if (comptime marked) c.made[i] = true;
                } else c.out[i] = c.f.call(.{rt.lend(&c.xs[i])});
            }
        }
    };
    const marked = Ctx.marked;
    var ctx: Ctx = .{ .xs = xs, .f = f, .out = out.buf.ptr[0..xs.len], .made = undefined };
    if (comptime marked) {
        ctx.made = defaultAllocator().alloc(bool, xs.len) catch oom();
        @memset(ctx.made, false);
    }
    defer if (comptime marked) defaultAllocator().free(ctx.made);
    if (comptime fallible) {
        parRun(true, xs.len, limit, &ctx, Ctx.chunk) catch |err| {
            if (comptime marked) for (ctx.out, ctx.made) |*v, m| if (m) dropElement(V, v);
            rt.drop(&out);
            return err;
        };
    } else parRun(false, xs.len, limit, &ctx, Ctx.chunk);
    out.len = xs.len;
    return out;
}

/// `par.each(!xs, f, limit: n)`: `f(!x)` for each element `x` of the
/// slice `xs`, each call on one of up to `limit` tasks (`parRun`).
pub fn parEach(xs: anytype, f: anytype, limit: Int) EachOut(@TypeOf(f)) {
    const F = @TypeOf(f);
    const fallible = @typeInfo(ReturnOf(F)) == .error_union;
    const Ctx = struct {
        xs: @TypeOf(xs),
        f: F,

        fn chunk(c: *const @This(), lo: usize, hi: usize) if (fallible) anyerror!void else void {
            for (lo..hi) |i| {
                if (comptime fallible) try c.f.call(.{&c.xs[i]}) else c.f.call(.{&c.xs[i]});
            }
        }
    };
    const ctx: Ctx = .{ .xs = xs, .f = f };
    return parRun(fallible, xs.len, limit, &ctx, Ctx.chunk);
}

/// `std.task`'s `Stop`, as the emitted code names its errors: what a
/// waiting point of any `std` module may fail with (`expectShim`).
pub const Stop = error{ @"std.task.Stop.canceled", @"std.task.Stop.timeout" };

/// `task.Stop.canceled`, the error a canceled task's waiting points fail
/// with.
const canceled_error = error.@"std.task.Stop.canceled";

/// Whether the running task is canceled. `main` never is.
fn canceledHere() bool {
    const control = task().control orelse return false;
    return control.canceled.load(.acquire);
}

/// Record that the running task is canceled.
fn markCanceled() void {
    if (task().control) |control| control.canceled.store(true, .release);
}

/// `task.check()`: a waiting point that waits for nothing. It fails
/// when the running task is canceled or its deadline has passed, and
/// otherwise lets other tasks run; in a program that makes none, it
/// only checks the deadline.
pub fn check() Stop!void {
    if (rt.sched.deterministic) rt.sched.computed();
    if (canceledHere()) return canceled_error;
    if (pastDeadline()) return timeout_error;
    if (rt.scheduled) rt.sched.yield();
}

/// `time.sleep(ns)`: a waiting point that waits `ns` nanoseconds: the
/// fiber sleeps until its timer, or a cancel, wakes it. When the task's
/// deadline comes first, it sleeps until then and fails with
/// `task.Stop.timeout`. A program that makes no tasks sleeps on its
/// thread, where no cancel can come.
pub fn sleep(ns: i64) Stop!void {
    if (ns <= 0) return;
    const until = nowNs() + ns;
    const deadline = task().deadline;
    // Deterministic and with no tasks, the clock jumps.
    if (!rt.scheduled and rt.sched.deterministic) {
        if (deadline) |d| if (d < until) {
            rt.sched.advanceTo(d);
            return timeout_error;
        };
        return rt.sched.advanceTo(until);
    }
    if (!rt.scheduled) {
        const d = deadline orelse return std.Io.sleep(io(), .fromNanoseconds(ns), .awake) catch {};
        if (d >= until) return std.Io.sleep(io(), .fromNanoseconds(ns), .awake) catch {};
        const left = d - nowNs();
        if (left > 0) std.Io.sleep(io(), .fromNanoseconds(@intCast(left)), .awake) catch {};
        return timeout_error;
    }
    const wake_at = earlier(until, deadline);
    while (true) {
        if (canceledHere()) return canceled_error;
        const now = nowNs();
        if (now >= until) return;
        if (deadline) |d| if (now >= d) return timeout_error;
        const e = rt.sched.beginWait(true);
        if (canceledHere()) return canceled_error;
        rt.sched.commitWait(e, wake_at);
    }
}
