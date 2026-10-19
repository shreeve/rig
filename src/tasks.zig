//! Tasks: a call running as a task of its own (`f(x)&`), sets of tasks
//! (`Tasks[T]`), waiting for several (`task.both`, `task.all`), and how a
//! task is canceled. The runtime (`runtime.zig`) imports this file and
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

        /// `f(args...)&`: start the call as a task.
        pub fn spawn(comptime f: anytype, args: anytype) Self {
            const Args = @TypeOf(args);
            // A fiber is on a stack of its own already, and the runtime
            // keeps its state per fiber. `run` gives `T` even where `f` is
            // generic.
            const Fiber = struct {
                fn run(control: *Control, a: Args) T {
                    task().control = control;
                    defer control.finish();
                    return @call(.auto, f, a);
                }
            };
            // The task's record holds its `Control`: one allocation for
            // both.
            const made = rt.sched.spawn(T, Control, Fiber.run, .{args});
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
        /// next waiting point.
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
            if (!job.waitEnd(mine)) {
                t.control.cancel();
                _ = job.waitEnd(null);
            }
            result = job.result;
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
    /// deadline passes, or the waiter is canceled: a waiting point.
    fn sleep(self: *Wakeup, seen: u32, deadline: ?i96) Stop!void {
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

/// The monotonic clock, in nanoseconds: the time a deadline counts on.
fn nowNs() i96 {
    return std.Io.Timestamp.now(io(), .awake).nanoseconds;
}

/// The deadline `within` nanoseconds from now, or none.
fn deadlineIn(within: ?Int) ?i96 {
    const ns = within orelse return null;
    return nowNs() + ns;
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
/// when the running task is canceled, and otherwise lets other tasks
/// run; in a program that makes none, it does nothing.
pub fn check() Stop!void {
    if (canceledHere()) return canceled_error;
    if (rt.scheduled) rt.sched.yield();
}

/// `time.sleep(ns)`: a waiting point that waits `ns` nanoseconds: the
/// fiber sleeps until its timer, or a cancel, wakes it. A program that
/// makes no tasks sleeps on its thread, where no cancel can come.
pub fn sleep(ns: i64) Stop!void {
    if (ns <= 0) return;
    if (!rt.scheduled) return std.Io.sleep(io(), .fromNanoseconds(ns), .awake) catch {};
    const until = nowNs() + ns;
    while (true) {
        if (canceledHere()) return canceled_error;
        if (nowNs() >= until) return;
        const e = rt.sched.beginWait(true);
        if (canceledHere()) return canceled_error;
        rt.sched.commitWait(e, until);
    }
}
