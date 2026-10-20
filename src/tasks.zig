//! Tasks: a call running as a task of its own (`f(x)&`), sets of tasks
//! (`Tasks[T]`), waiting for several (`task.both`, `task.all`), how a
//! task is canceled, deadlines (`time.within`), calling a function on
//! each element on several tasks (`par.map`, `par.each`), the boundary a
//! panic stops at (`task.isolate`), and actors (`*Actor(x)`). The runtime (`runtime.zig`) imports this file and
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
                    const state = task();
                    state.control = control;
                    state.deadline = deadline;
                    state.isolate = control.isolate;
                    defer control.finish();
                    return @call(.auto, f, a);
                }
            };
            // The task's record holds its `Control`: one allocation for
            // both. It keeps the isolate of the task starting it, which
            // records it before it can run (`Control.made`).
            const state = task();
            const made = rt.sched.spawn(T, Control, Fiber.run, .{ state.deadline, args }, .{ .isolate = state.isolate });
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
            result = job.taken();
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
    /// The isolate the task runs under, which lists it until it ends.
    isolate: ?*Isolate = null,
    /// Its neighbors in that isolate's list.
    iso_prev: ?*Control = null,
    iso_next: ?*Control = null,

    /// The task is made and not yet running: it runs under the isolate
    /// of the task starting it, which lists it now, so a panic there
    /// stops it before the stack it may point into is left
    /// (`Isolate.stop`).
    pub fn made(self: *Control) void {
        const iso = self.isolate orelse return;
        iso.add(self);
    }

    /// Record a cancel, and end the wait the task is in, when a cancel
    /// may end it. A task waiting on another passes
    /// the cancel on itself (`Task.wait`).
    pub fn cancel(self: *Control) void {
        self.canceled.store(true, .seq_cst);
        if (self.fiber) |f| rt.sched.interruptForCancel(f);
    }

    /// The task has ended: record it, then wake what waits on it. A
    /// waiter that registers after the task ends finds `done` set
    /// (`Wakeup.watch`), so no end goes unseen.
    fn finish(self: *Control) void {
        if (self.isolate) |iso| iso.remove(self);
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
    const Untaken = struct {
        ts: *const Tup,
        taken: *const [n]bool,

        fn member(ctx: *const anyopaque, i: usize) ?*rt.sched.Header {
            const u: *const @This() = @ptrCast(@alignCast(ctx));
            inline for (0..n) |k| if (k == i) return if (u.taken[k]) null else &u.ts[k].handle.job.header;
            unreachable;
        }
    };
    const untaken: Untaken = .{ .ts = &ts, .taken = &taken };
    const b: rt.sched.Blocked = .{ .any = .{ .ctx = &untaken, .len = n, .member = Untaken.member } };
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
        if (left > 0 and failure == null) {
            rt.sched.block(&b);
            const slept = w.sleep(seen, null);
            rt.sched.unblock();
            slept catch |err| {
                failure = err;
            };
        }
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

        /// The tasks a wait on the set has not taken, for a deadlock's
        /// walk (`rt.sched.Blocked.any`).
        const Untaken = struct {
            items: []const Task(T),
            taken: []const bool,

            fn member(ctx: *const anyopaque, i: usize) ?*rt.sched.Header {
                const u: *const Untaken = @ptrCast(@alignCast(ctx));
                return if (u.taken[i]) null else &u.items[i].handle.job.header;
            }

            fn blocked(u: *const Untaken) rt.sched.Blocked {
                return .{ .any = .{ .ctx = u, .len = u.items.len, .member = member } };
            }
        };

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
            const untaken: Untaken = .{ .items = s.items.items, .taken = taken };
            const b = untaken.blocked();
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
                rt.sched.block(&b);
                const slept = s.wakeup.?.sleep(seen, deadline);
                rt.sched.unblock();
                slept catch |err| {
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
            const untaken: Untaken = .{ .items = s.items.items, .taken = taken };
            const b = untaken.blocked();
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
                rt.sched.block(&b);
                const slept = s.wakeup.?.sleep(seen, deadline);
                rt.sched.unblock();
                slept catch |err| {
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

/// A boundary a panic stops at: a call of `task.isolate(f)`, which runs
/// `f` on a stack apart (`rt.sched.runApart`), and lists every task
/// started under it, by `f` or by those tasks, until it ends. A panic in
/// `f`, or in a task under it, stops them all: each is canceled, and
/// the isolate waits for them to end, since they may point into `f`'s
/// frames. Then `f`'s stack is left where it stands, its frames
/// abandoned, what they own left allocated, and `isolate` fails with
/// `task.Stop.panicked`. Nothing outside `f` was lent to it to write,
/// so all a panic half-changed is `f`'s own.
pub const Isolate = struct {
    /// The fiber `isolate` was called on, whose own stack waits at
    /// `home` while `f` runs apart.
    fiber: ?*rt.sched.Fiber,
    home: usize = 0,
    /// The isolate this one is inside, on the same fiber.
    outer: ?*Isolate,
    /// Set once a panic reached it.
    panicked: std.atomic.Value(bool) = .init(false),
    /// Its id, for the leak checker's count of what a panic leaves.
    id: u32,
    lock: rt.sched.SpinLock = .{},
    first: ?*Control = null,

    fn add(self: *Isolate, c: *Control) void {
        self.lock.lock();
        defer self.lock.unlock();
        c.iso_prev = null;
        c.iso_next = self.first;
        if (self.first) |n| n.iso_prev = c;
        self.first = c;
    }

    fn remove(self: *Isolate, c: *Control) void {
        self.lock.lock();
        defer self.lock.unlock();
        if (c.iso_prev) |p| p.iso_next = c.iso_next else self.first = c.iso_next;
        if (c.iso_next) |n| n.iso_prev = c.iso_prev;
        c.iso_prev = null;
        c.iso_next = null;
    }

    /// Cancel every task listed; with `wait`, until none is.
    fn stop(self: *Isolate, wait: bool) void {
        while (true) {
            self.lock.lock();
            var c = self.first;
            while (c) |x| : (c = x.iso_next) x.cancel();
            const left = self.first != null;
            self.lock.unlock();
            if (!left or !wait) return;
            rt.sched.yield();
        }
    }
};

/// `task.isolate(f)`: run `f` (a `rig.FnRef` that takes nothing) apart,
/// and give what it gives; or, when a panic in it or in a task under it
/// reached this boundary, fail with `task.Stop.panicked` (`Isolate`).
pub fn isolate(f: anytype) IsolateOut(@TypeOf(f)) {
    const F = @TypeOf(f);
    const R = ReturnOf(F);
    const state = task();
    var rec: Isolate = .{ .fiber = rt.sched.current(), .outer = state.isolate, .id = rt.isolateBegins(state.isolate) };
    const Run = struct {
        f: F,
        rec: *Isolate,
        result: R = undefined,

        fn entry(p: *anyopaque) callconv(.c) noreturn {
            const run: *@This() = @ptrCast(@alignCast(p));
            run.result = run.f.call(.{});
            rt.sched.leaveApart(run.rec.home);
        }
    };
    var run: Run = .{ .f = f, .rec = &rec };
    state.isolate = &rec;
    rt.sched.runApart(&rec.home, &run, Run.entry);
    task().isolate = rec.outer;
    if (rec.panicked.load(.seq_cst)) return panicked_error;
    return run.result;
}

/// What `isolate` gives for `f`: its value, failing as it can fail and
/// with `task.Stop.panicked`.
fn IsolateOut(comptime F: type) type {
    const R = ReturnOf(F);
    return anyerror!(if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R);
}

/// `task.Stop.panicked`, what `isolate` fails with when a panic reached
/// it.
const panicked_error = error.@"std.task.Stop.panicked";

/// A panic, reported, reached `iso`, the running task's nearest isolate.
/// On the isolate's own fiber, its tasks are stopped and waited for, and
/// the fiber leaves the stack apart for its own (`Isolate`). In a task
/// under it, the tasks are stopped, and this task ends where it stands,
/// marked as panicked, so its owner's wait or drop passes the panic on,
/// up to the isolate's fiber.
pub fn panicked(iso: *Isolate) noreturn {
    iso.panicked.store(true, .seq_cst);
    rt.isolatePanicked(iso.id);
    rt.leaveFrames();
    if (iso.fiber == rt.sched.current()) {
        task().unwinding = true;
        iso.stop(true);
        task().unwinding = false;
        rt.sched.leaveApart(iso.home);
    }
    iso.stop(false);
    if (task().control) |c| c.finish();
    rt.sched.abandon();
}

// -----------------------------------------------------------------------------
// Actors
// -----------------------------------------------------------------------------

/// `Actor(T)`: a value of type `T` that one task at a time changes, the
/// actor's own: `*Actor(x)` moves `x` into it, and its handles, counted
/// atomically (`rt.Shared`), go to any task. A method called through a
/// handle is a message (`actorCall`): it joins the actor's mailbox, and
/// the actor runs one at a time, each to its end, in the order they
/// came. A runner task drains the mailbox while it has messages, holding
/// a handle of its own, so the last handle, and the actor's `drop`, may
/// be the runner's, in its own task. A message lives in its caller's
/// frame, which waits for the answer, so the mailbox needs no bound; a
/// call made with `&` (`actorSpawn`) takes one of `capacity` slots while
/// it is in flight, and waits for a free one.
pub fn Actor(comptime T: type) type {
    return struct {
        value: T,
        lock: rt.sched.SpinLock = .{},
        first: ?*Message = null,
        last: ?*Message = null,
        /// `busy` while the actor runs a method: a runner task drains the
        /// mailbox, or a caller runs one inline (`claim`); `mail` once a
        /// message is sent to a busy actor. While it is 0 the mailbox is
        /// empty, so claiming the actor, and giving it back when no
        /// message came meanwhile, are one atomic step each.
        state: std.atomic.Value(u8) = .init(0),
        /// Calls made with `&` in flight, against `capacity`.
        pending: std.atomic.Value(u32) = .init(0),
        capacity: u32 = default_mailbox,
        /// The method running in the actor while the fiber running it
        /// blocks, for a deadlock's walk (`rt.sched.Held`).
        held_by: std.atomic.Value(?*rt.sched.Held) = .init(null),
        /// The message the runner runs, which a panic in it answers as
        /// panicked (`kill`); only the runner's fiber touches it.
        running: ?*Message = null,
        /// The method a panic ended the actor in, once it has died.
        died_in: ?*const rt.sched.Label = null,
        /// A supervised actor's: the function that makes its value
        /// (`actorSupervised`), how many restarts it allows within `per`
        /// nanoseconds (all when `restarts` is negative; within any time
        /// when `per` is 0), and those counted in the window that began
        /// at `window_start`.
        make: ?*rt.Shared(rt.Closure(&.{}, T)) = null,
        restarts: Int = -1,
        per: Int = 0,
        restarted: Int = 0,
        window_start: i96 = 0,
        /// The value a panic ended, which the function makes again before
        /// the next method runs (`remake`), and whether it is making it.
        stale: bool = false,
        remaking: bool = false,

        const Self = @This();

        /// Method `name` as a deadlock names it.
        fn label(comptime name: []const u8) *const rt.sched.Label {
            return &struct {
                const l: rt.sched.Label = .{ .actor = actorName(T), .method = name };
            }.l;
        }
        /// Marks the type for `rt.Shared`'s atomic counts.
        pub const __rig_actor = {};
        /// Its arguments, for `typeName`.
        pub const __rig_args = .{T};

        pub fn __rig_print(_: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeAll("<actor>");
        }

        /// A dead actor's value is abandoned, not dropped: a panic may
        /// have left it half-changed (`kill`).
        pub fn __rig_drop(self: *Self) void {
            if (self.make) |m| m.dropStrong();
            if (self.state.load(.acquire) & dead != 0 or self.stale) return;
            dropElement(T, &self.value);
        }

        /// A panic in method `in`, on the fiber running it, ends the
        /// actor: its value is abandoned, the call the runner runs is
        /// answered as panicked, and the calls queued, as made to an actor
        /// that died; so is every later call (`send`).
        ///
        /// A supervised actor starts again instead, while its restarts
        /// allow: the call it ran then panics in its caller, the calls
        /// queued stay, and the value is made again before the next
        /// method runs. A panic in making it ends the actor for good.
        fn kill(self: *Self, in: *const rt.sched.Label) void {
            self.lock.lock();
            if (self.state.load(.acquire) & dead != 0) {
                self.lock.unlock();
                return;
            }
            if (self.make != null and !self.remaking and self.mayRestart()) {
                rt.abandonValue(T, &self.value);
                self.stale = true;
                const running = self.running;
                self.running = null;
                // The fiber that ran it stops here: the calls queued go
                // to a runner of their own, or the actor is idle.
                const more = self.first != null;
                if (!more) self.state.store(0, .release);
                self.lock.unlock();
                if (running) |m| {
                    m.outcome = Message.panicked;
                    m.answer();
                }
                if (more) {
                    const box: *rt.Shared(Self) = @fieldParentPtr("value", self);
                    rt.sched.spawnDetached(runner, .{box.cloneStrong()});
                }
                return;
            }
            self.died_in = in;
            _ = self.state.fetchOr(dead, .acq_rel);
            var queued = self.first;
            self.first = null;
            self.last = null;
            const running = self.running;
            self.running = null;
            self.lock.unlock();
            if (running) |m| {
                m.outcome = Message.panicked;
                m.answer();
            }
            while (queued) |m| {
                queued = m.next;
                m.started = true;
                m.outcome = Message.died;
                m.answer();
            }
            rt.abandonValue(T, &self.value);
        }

        /// Whether a supervised actor may start again: one more restart
        /// within its limit, which counts it. Under the actor's lock.
        fn mayRestart(self: *Self) bool {
            if (self.restarts < 0) return true;
            if (self.per > 0) {
                const now = rt.sched.nowNs();
                if (self.restarted == 0 or now - self.window_start > self.per) {
                    self.window_start = now;
                    self.restarted = 0;
                }
            }
            if (self.restarted >= self.restarts) return false;
            self.restarted += 1;
            return true;
        }

        /// Make the value again, on the fiber about to run a method
        /// (`held`), as `supervised`: a panic here ends the actor for good.
        fn remake(self: *Self, held: *rt.sched.Held) void {
            const doing = held.doing;
            held.doing = label("supervised");
            self.remaking = true;
            self.value = self.make.?.value.invoke(.{});
            self.remaking = false;
            self.stale = false;
            held.doing = doing;
        }

        /// The actor that `h`, a fiber's hold on an actor, names.
        fn heldBy(h: *rt.sched.Held) *Self {
            return @alignCast(@fieldParentPtr("held_by", h.held_by));
        }

        /// A panic on a fiber that runs a method inline: the actor dies,
        /// and the panic goes on to the fiber's own boundary.
        fn dieInline(h: *rt.sched.Held) bool {
            heldBy(h).kill(h.doing);
            return false;
        }

        /// A panic in the runner: the actor dies, the runner's handle
        /// goes, and the panic stops here.
        fn dieRunner(h: *rt.sched.Held) bool {
            const self = heldBy(h);
            self.kill(h.doing);
            const box: *rt.Shared(Self) = @fieldParentPtr("value", self);
            box.dropStrong();
            return true;
        }

        /// A call of method `name` found the actor dead.
        fn calledDead(self: *Self, comptime name: []const u8) noreturn {
            @branchHint(.cold);
            var buf: [256]u8 = undefined;
            const in = self.died_in.?;
            const text = std.fmt.bufPrint(&buf, "{s}.{s}: the actor died from a panic in {s}.{s}", .{ actorName(T), name, in.actor, in.method }) catch "an actor that died from a panic was called";
            @panic(text);
        }

        /// What method `name` of `T` gives.
        fn Result(comptime name: []const u8) type {
            return @typeInfo(@TypeOf(@field(T, name))).@"fn".return_type.?;
        }

        /// Run method `name` on the value with `args`: through its
        /// address, or on a copy for a method that takes the value.
        fn invoke(self: *Self, comptime name: []const u8, args: anytype) Result(name) {
            const method = @field(T, name);
            const Recv = @typeInfo(@TypeOf(method)).@"fn".param_types[0].?;
            const recv = if (@typeInfo(Recv) == .pointer) &self.value else self.value;
            return @call(.auto, method, .{recv} ++ args);
        }

        /// Call method `name` through handle `box` and wait for its
        /// answer. A method that can fail and has not started when the
        /// caller is canceled, or its deadline passes, is withdrawn, and
        /// the call fails with `task.Stop.canceled` or `.timeout`; one
        /// that started runs to its end, and the caller waits for it.
        ///
        /// An idle actor's method runs inline, on the caller's stack, as
        /// the actor (`runInline`), with no message and no switch; what
        /// arrived meanwhile goes to a runner after it (`release`).
        pub fn call(box: *rt.Shared(Self), comptime name: []const u8, args: anytype) Result(name) {
            const R = Result(name);
            const self = &box.value;
            const fallible = @typeInfo(R) == .error_union;
            if (comptime fallible) {
                if (canceledHere()) return canceled_error;
                if (pastDeadline()) return timeout_error;
            }
            const f = rt.sched.current();
            const t = if (f) |x| &x.state else task();
            if (f != null and self.claim(t)) {
                var held: rt.sched.Held = .{ .held_by = &self.held_by, .doing = label(name), .die = dieInline, .next = f.?.held };
                f.?.held = &held;
                defer {
                    f.?.held = held.next;
                    self.release(box);
                }
                if (self.stale) self.remake(&held);
                return self.runInline(t, name, args);
            }
            const Call = struct {
                msg: Message,
                actor: *Self,
                args: @TypeOf(args),
                result: R = undefined,

                fn run(m: *Message) void {
                    const c: *@This() = @fieldParentPtr("msg", m);
                    c.result = c.actor.invoke(name, c.args);
                }
            };
            var c: Call = .{ .msg = .{ .run = Call.run, .label = label(name) }, .actor = self, .args = args };
            if (!self.send(box, &c.msg)) self.calledDead(name);
            const b: rt.sched.Blocked = .{ .call = .{ .label = label(name), .held_by = &self.held_by, .msg = &c.msg, .answered = Message.answered } };
            rt.sched.block(&b);
            const done = c.msg.waitAnswer(self, fallible);
            rt.sched.unblock();
            switch (c.msg.outcome) {
                Message.panicked => rt.passPanicFrom("an actor's method this task called panicked"),
                Message.died => self.calledDead(name),
                else => {},
            }
            if (!done) {
                if (comptime fallible) return if (canceledHere()) canceled_error else timeout_error;
                unreachable;
            }
            return c.result;
        }

        /// Put `m` in the mailbox, and start a runner when none drains it;
        /// false, with nothing sent, once the actor has died.
        fn send(self: *Self, box: *rt.Shared(Self), m: *Message) bool {
            self.lock.lock();
            if (self.state.load(.acquire) & dead != 0) {
                self.lock.unlock();
                return false;
            }
            if (self.last) |l| l.next = m else self.first = m;
            self.last = m;
            const start = self.state.fetchOr(busy | mail, .acq_rel) == 0;
            self.lock.unlock();
            if (start) rt.sched.spawnDetached(runner, .{box.cloneStrong()});
            return true;
        }

        /// Take the actor for a call run inline: when it is idle, which
        /// means its mailbox is empty, and the caller's stack has room
        /// (`roomInline`).
        ///
        /// A caller that finds it running inline with no mail spins a
        /// little first (`claim_spins`), as a mutex does, since a short
        /// method is soon done and sleeping costs more than the wait.
        fn claim(self: *Self, t: *rt.TaskState) bool {
            if (!roomInline(t)) return false;
            if (self.state.cmpxchgStrong(0, busy, .acquire, .monotonic) == null) return true;
            return claimSpinning(&self.state);
        }

        /// Run method `name` inline as the actor: under no cancel or
        /// deadline, as its runner runs one, so a canceled caller cannot
        /// stop it partway. A panic in it ends the actor and goes on to
        /// the caller's own boundary (`dieInline`).
        fn runInline(self: *Self, t: *rt.TaskState, comptime name: []const u8, args: anytype) Result(name) {
            const control, const deadline = .{ t.control, t.deadline };
            t.control, t.deadline = .{ null, null };
            defer t.control, t.deadline = .{ control, deadline };
            return self.invoke(name, args);
        }

        /// A call run inline is done: messages sent meanwhile go to a
        /// runner, and otherwise the actor is idle again.
        fn release(self: *Self, box: *rt.Shared(Self)) void {
            if (self.state.cmpxchgStrong(busy, 0, .release, .monotonic) == null) return;
            rt.sched.spawnDetached(runner, .{box.cloneStrong()});
        }

        /// Take `m` out of the mailbox, unless it has started.
        fn withdraw(self: *Self, m: *Message) bool {
            self.lock.lock();
            defer self.lock.unlock();
            if (m.started) return false;
            var prev: ?*Message = null;
            var at = self.first;
            while (at) |x| : ({
                prev = x;
                at = x.next;
            }) if (x == m) {
                if (prev) |p| p.next = x.next else self.first = x.next;
                if (self.last == x) self.last = prev;
                return true;
            };
            return false;
        }

        /// The runner: each message in turn, until the mailbox is empty;
        /// then its handle goes, which may be the last. A panic in a
        /// method stops here (`dieRunner`): the actor dies, and the
        /// runner ends where it stands.
        fn runner(box: *rt.Shared(Self)) void {
            const self = &box.value;
            const f = rt.sched.current().?;
            var held: rt.sched.Held = .{ .held_by = &self.held_by, .doing = undefined, .die = dieRunner, .next = f.held };
            f.held = &held;
            defer f.held = held.next;
            while (true) {
                self.lock.lock();
                const m = self.first orelse {
                    self.state.store(0, .release);
                    self.lock.unlock();
                    break;
                };
                self.first = m.next;
                if (self.first == null) self.last = null;
                m.started = true;
                self.lock.unlock();
                held.doing = m.label;
                if (self.stale) self.remake(&held);
                self.running = m;
                m.run(m);
                self.running = null;
                m.answer();
            }
            box.dropStrong();
        }
    };
}

/// How many calls made with `&` an actor holds in flight at once.
const default_mailbox = 64;

/// What a deadlock calls an actor of `T`: its name in Rig, without the
/// module or the type's arguments.
fn actorName(comptime T: type) []const u8 {
    if (@hasDecl(T, "__rig_name")) {
        const first = T.__rig_name.name[0];
        if (@TypeOf(first) == []const u8 or @typeInfo(@TypeOf(first)) == .pointer) return first;
    }
    return @typeName(T);
}

/// `Actor.claim` after its first try failed: spin while the actor runs
/// inline with no mail, up to `claim_spins` times, then give up.
noinline fn claimSpinning(state: *std.atomic.Value(u8)) bool {
    if (rt.sched.deterministic) return false;
    for (0..claim_spins) |_| {
        for (0..32) |_| std.atomic.spinLoopHint();
        const seen = state.load(.monotonic);
        if (seen != 0 and seen != busy) return false;
        if (seen == 0 and state.cmpxchgStrong(0, busy, .acquire, .monotonic) == null) return true;
    }
    return false;
}

/// How many times a caller spins on a busy actor before it sends a
/// message (`Actor.claim`): a few short spins, as Go's mutex makes.
const claim_spins = 4;

/// The bits of `Actor.state`.
const busy: u8 = 1;
const mail: u8 = 2;
/// Set for good once a panic ends the actor (`Actor.kill`).
const dead: u8 = 4;

/// A panic on the running fiber: every actor it runs a method of dies,
/// since each of those methods stops partway (`rt.sched.Held`). Whether
/// the fiber is an actor's runner, where the panic stops.
pub fn actorsDie() bool {
    if (!rt.scheduled) return false;
    const f = rt.sched.current() orelse return false;
    var stop = false;
    var at = f.held;
    f.held = null;
    while (at) |h| : (at = h.next) stop = h.die(h) or stop;
    return stop;
}

/// Whether the running task's stack has room for an actor's method run
/// inline (`Actor.claim`): `inline_reserve` bytes or more above its
/// guard. A stack the runtime did not map, or one it cannot place the
/// frame in, has none.
fn roomInline(t: *rt.TaskState) bool {
    const g = t.stack_guard;
    const at = @frameAddress();
    if (g.hi == 0 or at < g.hi or at - g.hi > rt.task_stack_size) return false;
    return at - g.hi >= inline_reserve;
}

/// The stack a method run inline leaves its caller at least: a quarter
/// of a task's stack. A deeper caller sends a message, which the actor's
/// own task runs on a stack of its own.
const inline_reserve = rt.task_stack_size / 4;

/// A call of an actor's method, in its caller's frame: the actor runs
/// it (`run`) and answers, which wakes the caller. Its status goes from
/// `queued` (or `waited`, once the caller sleeps on it) to `ending` and
/// `ended`, as a task's `Header` does, so the caller returns, and its
/// frame goes, only after the runner is done with it.
const Message = struct {
    next: ?*Message = null,
    run: *const fn (*Message) void,
    /// The method called, as a deadlock names it.
    label: *const rt.sched.Label,
    /// Taken by a runner, under the actor's lock: no longer withdrawn.
    started: bool = false,
    status: std.atomic.Value(u8) = .init(queued),
    /// How it was answered: `done`, or, when the actor died, `panicked`
    /// for the call it ran then and `died` for one queued (`Actor.kill`).
    outcome: u8 = done,
    waiter: std.atomic.Value(?*rt.sched.Fiber) = .init(null),
    waiter_epoch: std.atomic.Value(u32) = .init(0),

    const done = 0;
    const panicked = 1;
    const died = 2;

    const queued = 0;
    const waited = 1;
    const ending = 2;
    const ended = 3;

    fn answer(m: *Message) void {
        if (m.status.swap(ending, .seq_cst) == waited) {
            _ = rt.sched.interrupt(m.waiter.load(.seq_cst).?, m.waiter_epoch.load(.seq_cst), false);
        }
        m.status.store(ended, .seq_cst);
    }

    /// Whether the message at `p` has been answered, for a deadlock's
    /// walk (`rt.sched.Blocked`).
    fn answered(p: *const anyopaque) bool {
        const m: *const Message = @ptrCast(@alignCast(p));
        return m.status.load(.seq_cst) >= ending;
    }

    fn isEnded(m: *Message) bool {
        while (true) {
            const s = m.status.load(.seq_cst);
            if (s == ended) return true;
            if (s != ending) return false;
            std.atomic.spinLoopHint();
        }
    }

    /// Wait for the answer; with `stoppable`, a cancel or the deadline
    /// withdraws a message that has not started, when this gives false.
    fn waitAnswer(m: *Message, owner: anytype, stoppable: bool) bool {
        var stop = stoppable;
        while (!m.isEnded()) {
            if (stop and (canceledHere() or pastDeadline())) {
                if (owner.withdraw(m)) return false;
                // Started: it runs to its end, and the caller waits.
                stop = false;
                continue;
            }
            const e = rt.sched.beginWait(stop);
            m.waiter.store(rt.sched.current().?, .seq_cst);
            m.waiter_epoch.store(e, .seq_cst);
            if (m.status.cmpxchgStrong(queued, waited, .seq_cst, .seq_cst)) |s| {
                if (s != waited) continue;
            }
            if (stop and (canceledHere() or pastDeadline())) continue;
            rt.sched.commitWait(e, if (stop) task().deadline else null);
        }
        return true;
    }
};

/// `*Actor(x)` and `*Actor(x, mailbox: n)`: the actor, behind its first
/// handle.
pub fn actor(value: anytype, capacity: Int) *rt.Shared(Actor(@TypeOf(value))) {
    const box = rt.shared(Actor(@TypeOf(value)){ .value = value, .capacity = @intCast(@max(capacity, 1)) });
    return box;
}

/// `*Actor.supervised(make, mailbox: n, restarts: r, per: ns)`: an actor
/// whose value `make`, an owned closure it keeps, makes now and again
/// each time a panic ends it, at most `restarts` times within `per`
/// nanoseconds (`Actor.kill`).
pub fn actorSupervised(make: anytype, capacity: Int, restarts: Int, per: Int) *rt.Shared(Actor(@TypeOf(make.value).__rig_fn[1])) {
    const T = @TypeOf(make.value).__rig_fn[1];
    const value = make.value.invoke(.{});
    return rt.shared(Actor(T){ .value = value, .capacity = @intCast(@max(capacity, 1)), .make = make, .restarts = restarts, .per = per });
}

/// The `Shared(Actor(T))` a handle reaches: the handle, or a view of one.
fn boxOf(handle: anytype) BoxOf(@TypeOf(handle)) {
    return if (@typeInfo(@typeInfo(@TypeOf(handle)).pointer.child) == .pointer) handle.* else handle;
}

fn BoxOf(comptime H: type) type {
    const Child = @typeInfo(H).pointer.child;
    return if (@typeInfo(Child) == .pointer) Child else H;
}

/// `c.m(args)` through an actor handle (`Actor.call`).
pub fn actorCall(handle: anytype, comptime name: []const u8, args: anytype) ActorResult(@TypeOf(handle), name) {
    const box = boxOf(handle);
    return @TypeOf(box.value).call(box, name, args);
}

/// What method `name` gives through a handle of type `H`.
fn ActorResult(comptime H: type, comptime name: []const u8) type {
    const Box = @typeInfo(BoxOf(H)).pointer.child;
    const A = @FieldType(Box, "value");
    return A.Result(name);
}

/// `c.m(args)&`: the call as a task, which holds a handle of its own and
/// one of the actor's `&` slots until it is answered, waiting for a free
/// one first.
pub fn actorSpawn(handle: anytype, comptime name: []const u8, args: anytype) Task(ActorResult(@TypeOf(handle), name)) {
    const R = ActorResult(@TypeOf(handle), name);
    const box = boxOf(handle);
    const self = &box.value;
    while (true) {
        const n = self.pending.load(.seq_cst);
        if (n < self.capacity) {
            if (self.pending.cmpxchgWeak(n, n + 1, .seq_cst, .seq_cst) == null) break;
            continue;
        }
        rt.sched.yield();
    }
    const Run = struct {
        fn run(b: @TypeOf(box), a: @TypeOf(args)) R {
            defer {
                _ = b.value.pending.fetchSub(1, .seq_cst);
                b.dropStrong();
            }
            return @TypeOf(b.value).call(b, name, a);
        }
    };
    return Task(R).spawn(Run.run, .{ box.cloneStrong(), args });
}

/// `std.task`'s `Stop`, as the emitted code names its errors: what a
/// waiting point of any `std` module may fail with (`expectShim`).
pub const Stop = error{ @"std.task.Stop.canceled", @"std.task.Stop.timeout", @"std.task.Stop.panicked" };

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
