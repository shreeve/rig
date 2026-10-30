//! Tasks: a call running as a task of its own (`f(x)&`), sets of tasks
//! (`Tasks[T]`), waiting for several (`task.all`), how a
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
            return start(false, f, args);
        }

        /// `f(args...)&` for a local task: one given or lent a value that
        /// stays on one thread (a `*` handle whose count is not atomic, a
        /// Cell of more than one word, a Signal, a function). It and the
        /// task starting it run on this thread from now on.
        pub fn spawnLocal(comptime f: anytype, args: anytype) Self {
            return start(true, f, args);
        }

        fn start(comptime local: bool, comptime f: anytype, args: anytype) Self {
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
                    // A call that may fail with fields writes them into
                    // the task's record.
                    if (comptime takesSlot(@TypeOf(f))) return @call(.auto, f, a ++ .{rt.failSlot(&control.err)});
                    return @call(.auto, f, a);
                }
            };
            // The task's record holds its `Control`: one allocation for
            // both. It keeps the isolate of the task starting it, which
            // records it before it can run (`Control.made`).
            const state = task();
            const made = rt.sched.spawn(T, Control, Fiber.run, .{ state.deadline, args }, .{ .isolate = state.isolate }, local);
            return .{ .handle = .{ .job = made.job }, .control = made.extra };
        }

        /// `recv.name(args...)&`: start a method's call as a task. `recv`
        /// is the receiver's address, or the address of a view of it. A
        /// method that takes its receiver by value is given it here,
        /// before the task starts.
        pub fn spawnMethod(recv: anytype, comptime name: []const u8, args: anytype) Self {
            return startMethod(false, recv, name, args);
        }

        /// `recv.name(args...)&` for a local task (`spawnLocal`).
        pub fn spawnMethodLocal(recv: anytype, comptime name: []const u8, args: anytype) Self {
            return startMethod(true, recv, name, args);
        }

        /// `x.area()&` through a witness (`W.area`, docs/design/apis.md,
        /// Stage 3): `recv` is the receiver's address, or the address of a
        /// view of it, as for `spawnMethod`.
        pub fn spawnWitness(comptime f: anytype, recv: anytype, args: anytype) Self {
            return start(false, f, .{rt.selfArg(f, recv)} ++ args);
        }

        /// `spawnWitness` for a local task (`spawnLocal`).
        pub fn spawnWitnessLocal(comptime f: anytype, recv: anytype, args: anytype) Self {
            return start(true, f, .{rt.selfArg(f, recv)} ++ args);
        }

        /// `s.area()&` through an API object (docs/design/apis.md, Stage
        /// 5): the entry `name` of its table, given the address the object
        /// holds; the object, its two words, goes to the task, which its
        /// braces' crossing bound allows. An entry of a fallible method
        /// takes the slot, which the task's record gives it; an entry
        /// whose result goes out through the caller's place, a place of
        /// the task's own (`resultOut`).
        pub fn spawnObject(obj: anytype, comptime name: []const u8, args: anytype) Self {
            return startObject(false, obj, name, args);
        }

        /// `spawnObject` for a local task (`spawnLocal`).
        pub fn spawnObjectLocal(obj: anytype, comptime name: []const u8, args: anytype) Self {
            return startObject(true, obj, name, args);
        }

        fn startObject(comptime local: bool, obj: anytype, comptime name: []const u8, args: anytype) Self {
            const O = @TypeOf(obj);
            const A = @TypeOf(args);
            const Entry = @TypeOf(@field(obj.vt.*, name));
            const Call = if (comptime takesSlot(Entry)) struct {
                fn run(o: O, a: A, out: rt.ErrSlot) T {
                    return @call(.auto, @field(o.vt.*, name), .{o.ptr} ++ a ++ .{out});
                }
            } else if (comptime resultOut(Entry, T)) struct {
                fn run(o: O, a: A) T {
                    var res = rt.outPlace(T);
                    return rt.packOut(T, @call(.auto, @field(o.vt.*, name), .{o.ptr} ++ a ++ .{&res}), &res);
                }
            } else struct {
                fn run(o: O, a: A) T {
                    return @call(.auto, @field(o.vt.*, name), .{o.ptr} ++ a);
                }
            };
            return start(local, Call.run, .{ obj, args });
        }

        fn startMethod(comptime local: bool, recv: anytype, comptime name: []const u8, args: anytype) Self {
            const P = @TypeOf(recv);
            const Ptr = if (@typeInfo(@typeInfo(P).pointer.child) == .pointer) @typeInfo(P).pointer.child else P;
            const ptr: Ptr = if (Ptr == P) recv else recv.*;
            const method = @field(@typeInfo(Ptr).pointer.child, name);
            const Receiver = @typeInfo(@TypeOf(method)).@"fn".param_types[0].?;
            if (@typeInfo(Receiver) == .pointer) return start(local, method, .{ptr} ++ args);
            return start(local, method, .{ptr.*} ++ args);
        }

        /// `>t`: wait for the task to end and take its result. A
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
            return self.waitWith(rt.no_slot);
        }

        /// `>t` where the waiter catches the task's failure, or passes it
        /// on, with its fields: they move from the task's record into
        /// the waiter's slot `out`.
        pub fn waitInto(self: Self, out: rt.ErrSlot) T {
            return self.waitWith(out);
        }

        fn waitWith(self: Self, out: anytype) T {
            var t = self;
            defer t.release();
            if (canceledHere()) {
                var result = t.stop();
                if (comptime !fallible) return result;
                dropResult(T, &result, &t.control.err);
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
                dropResult(T, &result, &t.control.err);
                return timeout_error;
            };
            // Canceled while it waited, even when the task ended before
            // the cancel could reach it. Only the waiter's own cancel
            // counts: a task its owner canceled, as `par.map` cancels its
            // helpers after a failure, leaves the owner as it was.
            const canceled = if (mine) |c| c.load(.acquire) else false;
            if (!canceled) return keepResult(T, result, &t.control.err, out);
            if (comptime !fallible) return result;
            dropResult(T, &result, &t.control.err);
            return canceled_error;
        }

        /// `<t.cancel()`: cancel the task, wait for it, and take what it
        /// gave: `task.Stop.canceled` when the cancel reached it, or its
        /// result when it ended first. Only a task that can fail is
        /// canceled; the checker rejects any other.
        pub fn cancel(self: Self) T {
            return self.cancelWith(rt.no_slot);
        }

        /// `<t.cancel()` where the caller takes the failure's fields
        /// into its slot `out`.
        pub fn cancelInto(self: Self, out: rt.ErrSlot) T {
            return self.cancelWith(out);
        }

        fn cancelWith(self: Self, out: anytype) T {
            var t = self;
            defer t.release();
            return keepResult(T, t.stop(), &t.control.err, out);
        }

        pub fn __rig_print(_: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeAll("<task>");
        }

        /// A task that cannot fail is waited for, unless the task that
        /// drops it is canceled, which passes the cancel on.
        pub fn __rig_drop(self: *Self) void {
            defer self.release();
            var result = if (fallible or canceledHere()) self.stop() else self.handle.result();
            dropResult(T, &result, &self.control.err);
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

/// Whether an entry of type `F` (a function's address) of a method whose
/// result is a `T` gives it through the caller's place (`rt.packOut`):
/// it returns a flag where the method gives a `T?`.
fn resultOut(comptime F: type, comptime T: type) bool {
    const ret = @typeInfo(@typeInfo(F).pointer.child).@"fn".return_type orelse return false;
    return ret == bool and T != bool;
}

/// Whether a function of type `F` takes the slot its failure's fields go
/// in (`rt.ErrSlot`), as its last parameter: one that may fail with
/// fields.
fn takesSlot(comptime F: type) bool {
    const info = switch (@typeInfo(F)) {
        .@"fn" => |f| f,
        .pointer => |p| switch (@typeInfo(p.child)) {
            .@"fn" => |f| f,
            else => return false,
        },
        else => return false,
    };
    if (info.param_types.len == 0) return false;
    const last = info.param_types[info.param_types.len - 1] orelse return false;
    return last == rt.ErrSlot;
}

/// Drop `result`, a task's: its value, or its failure's fields, which
/// `data` holds.
fn dropResult(comptime T: type, result: *T, data: *rt.ErrData) void {
    if (comptime @typeInfo(T) == .error_union) {
        if (result.*) |_| {} else |err| return rt.dropErrorData(err, data);
    }
    dropElement(T, result);
}

/// `result`, a task's, as its waiter takes it: a failure's fields, which
/// `data` holds, move into the waiter's slot `out`, or are dropped where
/// the waiter has none.
fn keepResult(comptime T: type, result: T, data: *rt.ErrData, out: anytype) T {
    keepFailure(T, &result, data, out);
    return result;
}

/// `keepResult`'s part for a failure: its fields, which `data` holds, move
/// into `out`, or are dropped where there is none.
fn keepFailure(comptime T: type, result: *const T, data: *rt.ErrData, out: anytype) void {
    if (comptime @typeInfo(T) == .error_union) {
        if (result.*) |_| {} else |err| {
            if (comptime @TypeOf(out) == rt.ErrSlot) rt.putFields(out, data) else rt.dropErrorData(err, data);
        }
    }
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
/// whether it has ended. A cancel is recorded only by what cancels the
/// task (`cancel`): its owner, an isolate stopping, or an interrupt. A
/// task never takes one from a task it waits on, or from one it cancels.
/// A task in a set, or in `task.all`, also tells the `Wakeup` of what
/// waits on it when it ends. Allocated outside the leak count, as the
/// backend's own records are.
pub const Control = struct {
    /// The fields of the task's failure, which its call writes when it
    /// takes a slot (`rt.ErrSlot`), until a waiter takes them or the
    /// task's result is dropped.
    err: rt.ErrData = undefined,
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

/// What a set of tasks, or `task.all`, waits on: a count each of its
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
    /// waiter's deadline passes, or the waiter is canceled: a waiting
    /// point.
    fn sleep(self: *Wakeup, seen: u32) Stop!void {
        const deadline = task().deadline;
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

/// What `task.all` gives for the tasks `Tup` (a tuple of
/// `Task`s): each one's value, in order, failing when any can fail.
fn TaskValues(comptime Tup: type) type {
    const tasks = @typeInfo(Tup).@"struct".field_types;
    var values: [tasks.len]type = undefined;
    var results: [tasks.len]type = undefined;
    var fallible = false;
    for (tasks, &values, &results) |Tk, *V, *R| {
        R.* = Tk.__rig_args[0];
        if (@typeInfo(R.*) == .error_union) {
            fallible = true;
            V.* = @typeInfo(R.*).error_union.payload;
        } else V.* = R.*;
    }
    const Values = @Tuple(&values);
    return if (fallible) WaitErr(&results)!Values else Values;
}

/// The error set a wait for work whose results are `Rs` fails with:
/// their sets and `task.Stop`, which every wait may fail with; `anyerror`
/// when one of them is a `T!`. The checker gives the wait the one of the
/// sets that holds the rest and `task.Stop` (`Checker.waitSet`), so the
/// two agree.
fn WaitErr(comptime Rs: []const type) type {
    var E: type = Stop;
    for (Rs) |R| if (@typeInfo(R) == .error_union) {
        const S = @typeInfo(R).error_union.error_set;
        if (S == anyerror) return anyerror;
        E = E || S;
    };
    return E;
}

/// `task.all(a, b, ...)`: wait for tasks of any
/// types, and give each one's value. When some can fail, waiting is a
/// waiting point, and the first task to fail, in the order they end,
/// cancels the others: the call waits for them, drops what they gave,
/// and fails with its error.
pub fn waitTasks(tasks: anytype) TaskValues(@TypeOf(tasks)) {
    return waitTasksWith(tasks, rt.no_slot);
}

/// `task.all(...)` where the waiter takes the failure's fields into its
/// slot `out`.
pub fn waitTasksInto(tasks: anytype, out: rt.ErrSlot) TaskValues(@TypeOf(tasks)) {
    return waitTasksWith(tasks, out);
}

fn waitTasksWith(tasks: anytype, out: anytype) TaskValues(@TypeOf(tasks)) {
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
                // The first failure's fields move out of its record before
                // the record is freed.
                keepFailure(@TypeOf(result), &result, &ts[i].control.err, out);
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
            const slept = w.sleep(seen);
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
        dropResult(@TypeOf(result), &result, &ts[i].control.err);
        ts[i].release();
    };
    inline for (0..n) |i| if (got[i]) dropElement(@TypeOf(values[i]), &values[i]);
    // Every failure is a task's, or the wait's own `task.Stop`.
    return @errorCast(err);
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
/// - The waiting task's deadline (`time.within`) bounds a wait on a set
///   that can fail: when it passes, the rest are canceled and the wait
///   fails with `task.Stop.timeout`.
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
        len: Int = 0,

        const Self = @This();
        /// Its arguments, for `typeName`.
        pub const __rig_args = .{T};
        const fallible = @typeInfo(T) == .error_union;
        const Value = if (fallible) @typeInfo(T).error_union.payload else T;
        /// What `wait_all` gives: the results, or nothing for tasks that
        /// give none.
        const Results = if (Value == void) void else List(Value);
        /// The set its tasks fail with: `anyerror` for a `T!`, or the set a
        /// `T!E` declares, which holds `task.Stop`, as every wait's does.
        const Err = if (fallible) @typeInfo(T).error_union.error_set else void;
        const All = if (fallible) Err!Results else Results;

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
            self.len = @intCast(self.items.items.len);
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

        /// `>ts`: every result, in the order added; nothing for tasks that
        /// give none.
        pub fn wait_all(self: Self) All {
            return self.waitAllWith(rt.no_slot);
        }

        /// `>ts` where the waiter takes the failure's fields into its slot
        /// `out`.
        pub fn wait_allInto(self: Self, out: rt.ErrSlot) All {
            return self.waitAllWith(out);
        }

        fn waitAllWith(self: Self, out: anytype) All {
            var s = self;
            defer s.free();
            const n = s.items.items.len;
            if (comptime !fallible) {
                if (comptime Value == void) {
                    for (s.items.items) |t| t.wait();
                    return;
                }
                var values = List(Value).initCapacity(@intCast(n));
                for (s.items.items) |t| values.push(t.wait());
                return values;
            }
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
                    // Its failure's fields are taken from its record
                    // before the record is freed.
                    keepFailure(T, &result, &t.control.err, out);
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
                const slept = s.wakeup.?.sleep(seen);
                rt.sched.unblock();
                slept catch |err| {
                    s.stopUntaken(taken);
                    dropGot(results, got);
                    return err;
                };
            }
            if (comptime Value == void) return;
            var values = List(Value).initCapacity(@intCast(n));
            for (results) |v| values.push(v);
            return values;
        }

        /// `<ts.wait_first()`: the first result to succeed.
        pub fn wait_first(self: Self) T {
            return self.waitFirstWith(rt.no_slot);
        }

        /// `<ts.wait_first()` where the waiter takes the last failure's
        /// fields into its slot `out`.
        pub fn wait_firstInto(self: Self, out: rt.ErrSlot) T {
            return self.waitFirstWith(out);
        }

        fn waitFirstWith(self: Self, out: anytype) T {
            if (comptime !fallible) @compileError("rig: wait_first is only for a set that can fail");
            var s = self;
            defer s.free();
            const n = s.items.items.len;
            if (n == 0) @panic("wait_first on a set with no tasks");
            const taken = defaultAllocator().alloc(bool, n) catch oom();
            defer defaultAllocator().free(taken);
            @memset(taken, false);
            const untaken: Untaken = .{ .items = s.items.items, .taken = taken };
            const b = untaken.blocked();
            var left = n;
            // The last failure, with its fields: each one replaces the one
            // before, whose fields are dropped.
            var last: ?Err = null;
            var last_data: rt.ErrData = undefined;
            while (true) {
                const seen = s.wakeup.?.ticks.load(.seq_cst);
                for (s.items.items, 0..) |*t, i| {
                    if (taken[i] or !t.control.done.load(.seq_cst)) continue;
                    taken[i] = true;
                    left -= 1;
                    const result = t.handle.result();
                    if (result) |_| {} else |err| {
                        if (last) |l| rt.dropErrorData(l, &last_data);
                        last = err;
                        last_data = t.control.err;
                    }
                    t.release();
                    if (result) |v| {
                        if (last) |l| rt.dropErrorData(l, &last_data);
                        s.stopUntaken(taken);
                        s.items.items.len = 0;
                        return v;
                    } else |_| {}
                }
                if (left == 0) {
                    s.items.items.len = 0;
                    const l = last.?;
                    if (comptime @TypeOf(out) == rt.ErrSlot) rt.putFields(out, &last_data) else rt.dropErrorData(l, &last_data);
                    return l;
                }
                rt.sched.block(&b);
                const slept = s.wakeup.?.sleep(seen);
                rt.sched.unblock();
                slept catch |err| {
                    if (last) |l| rt.dropErrorData(l, &last_data);
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
                dropResult(T, &result, &t.control.err);
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
                dropResult(T, &result, &t.control.err);
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
    if (@typeInfo(R) == .error_union) return WaitErr(&.{R})!List(@typeInfo(R).error_union.payload);
    return List(R);
}

/// What `par.each` gives for `f`: nothing, failing when `f` can.
fn EachOut(comptime F: type) type {
    return if (@typeInfo(ReturnOf(F)) == .error_union) WaitErr(&.{ReturnOf(F)})!void else void;
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
    /// The first failure's fields.
    failure_data: rt.ErrData = undefined,

    /// Record `err`, with its fields in `data`, unless a failure came
    /// first, whose fields are kept and these dropped.
    fn fail(self: *ParState, err: anyerror, data: *rt.ErrData) void {
        if (self.failed.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
            self.failure = err;
            self.failure_data = data.*;
        } else rt.dropErrorData(err, data);
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
    return parRunInto(fallible, n, limit, ctx, body, rt.no_slot);
}

/// `parRun` where the run's failure's fields go into the caller's slot
/// `out`, or are dropped where it has none.
fn parRunInto(comptime fallible: bool, n: usize, limit: Int, ctx: anytype, comptime body: anytype, out: anytype) if (fallible) anyerror!void else void {
    if (n == 0) return;
    const workers: usize = if (rt.scheduled) rt.sched.workersRunning() else 1;
    // Deterministic, on one thread, the elements are still split among
    // tasks, so the seed tries their interleavings.
    const want: usize = if (limit > 0) @intCast(limit) else if (rt.sched.deterministic) 4 else workers;
    const count = @min(want, n);
    const chunk = @max(1, n / (count * 8));
    if (count <= 1 or chunk >= n) {
        if (comptime !fallible) return callChunk(body, ctx, 0, n, undefined) catch unreachable;
        var slot: rt.ErrData = undefined;
        callChunk(body, ctx, 0, n, rt.failSlot(&slot)) catch |err| {
            if (comptime @TypeOf(out) == rt.ErrSlot) rt.putFields(out, &slot) else rt.dropErrorData(err, &slot);
            return err;
        };
        return;
    }
    var state: ParState = .{ .n = n, .chunk = chunk };
    const Ctx = @TypeOf(ctx);
    const Worker = struct {
        fn run(s: *ParState, c: Ctx) void {
            while (!s.failed.load(.acquire)) {
                const lo = s.next.fetchAdd(s.chunk, .monotonic);
                if (lo >= s.n) return;
                const hi = @min(lo + s.chunk, s.n);
                if (comptime fallible) {
                    // Each chunk fails into a slot of its own, which the
                    // run keeps if it fails first.
                    var slot: rt.ErrData = undefined;
                    callChunk(body, c, lo, hi, rt.failSlot(&slot)) catch |err| return s.fail(err, &slot);
                } else callChunk(body, c, lo, hi, undefined) catch unreachable;
            }
        }
    };
    const helpers = defaultAllocator().alloc(Task(void), count - 1) catch oom();
    defer defaultAllocator().free(helpers);
    for (helpers) |*t| t.* = Task(void).spawn(Worker.run, .{ &state, ctx });
    Worker.run(&state, ctx);
    if (fallible and state.failed.load(.acquire)) for (helpers) |t| t.control.cancel();
    for (helpers) |t| t.wait();
    if (comptime fallible) if (state.failed.load(.acquire)) {
        if (comptime @TypeOf(out) == rt.ErrSlot) rt.putFields(out, &state.failure_data) else rt.dropErrorData(state.failure, &state.failure_data);
        return state.failure;
    };
}

/// `body(ctx, lo, hi)`, a chunk of a `par` run, given `slot` for its
/// failure's fields when it takes one.
fn callChunk(comptime body: anytype, ctx: anytype, lo: usize, hi: usize, slot: rt.ErrSlot) anyerror!void {
    if (comptime @typeInfo(@TypeOf(body)).@"fn".param_types.len == 4) return body(ctx, lo, hi, slot);
    return body(ctx, lo, hi);
}

/// `par.map(?xs, f, limit: n)`: a List of `f(x)` for each element `x` of
/// the slice `xs`, in its order, each call on one of up to `limit` tasks
/// (`parRun`). Each task writes the values of its chunks in place. When
/// a call fails, the values made are dropped: those that need it are
/// marked as they are made.
pub fn parMap(xs: anytype, f: anytype, limit: Int) MapOut(@TypeOf(f)) {
    return parMapInto(xs, f, limit, rt.no_slot);
}

/// `parMap` where a failure's fields go into the caller's slot `out`.
pub fn parMapInto(xs: anytype, f: anytype, limit: Int, out_slot: anytype) MapOut(@TypeOf(f)) {
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

        fn chunk(c: *const @This(), lo: usize, hi: usize, slot: rt.ErrSlot) if (fallible) anyerror!void else void {
            for (lo..hi) |i| {
                if (comptime fallible) {
                    c.out[i] = try c.f.call(rt.argsWithSlot(F, .{rt.lend(&c.xs[i])}, slot));
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
        parRunInto(true, xs.len, limit, &ctx, Ctx.chunk, out_slot) catch |err| {
            if (comptime marked) for (ctx.out, ctx.made) |*v, m| if (m) dropElement(V, v);
            rt.drop(&out);
            // Every failure is `f`'s, or a wait's `task.Stop` in it.
            return @errorCast(err);
        };
    } else parRunInto(false, xs.len, limit, &ctx, Ctx.chunk, out_slot);
    out.len = xs.len;
    return out;
}

/// `par.each(!xs, f, limit: n)`: `f(!x)` for each element `x` of the
/// slice `xs`, each call on one of up to `limit` tasks (`parRun`).
pub fn parEach(xs: anytype, f: anytype, limit: Int) EachOut(@TypeOf(f)) {
    return parEachInto(xs, f, limit, rt.no_slot);
}

/// `parEach` where a failure's fields go into the caller's slot `out`.
pub fn parEachInto(xs: anytype, f: anytype, limit: Int, out: anytype) EachOut(@TypeOf(f)) {
    const F = @TypeOf(f);
    const fallible = @typeInfo(ReturnOf(F)) == .error_union;
    const Ctx = struct {
        xs: @TypeOf(xs),
        f: F,

        fn chunk(c: *const @This(), lo: usize, hi: usize, slot: rt.ErrSlot) if (fallible) anyerror!void else void {
            for (lo..hi) |i| {
                if (comptime fallible) try c.f.call(rt.argsWithSlot(F, .{&c.xs[i]}, slot)) else c.f.call(.{&c.xs[i]});
            }
        }
    };
    const ctx: Ctx = .{ .xs = xs, .f = f };
    if (comptime !fallible) return parRunInto(false, xs.len, limit, &ctx, Ctx.chunk, out);
    // Every failure is `f`'s, or a wait's `task.Stop` in it.
    return parRunInto(true, xs.len, limit, &ctx, Ctx.chunk, out) catch |err| @errorCast(err);
}

/// What `par.workers` gives for `f`: a List of each call's value, or
/// nothing when `f` gives nothing, failing when `f` can.
fn WorkersOut(comptime F: type) type {
    const R = ReturnOf(F);
    const fallible = @typeInfo(R) == .error_union;
    const V = if (fallible) @typeInfo(R).error_union.payload else R;
    const ok = if (V == void) void else List(V);
    return if (fallible) WaitErr(&.{R})!ok else ok;
}

/// `par.workers(!states, ?items, f)`: one task for each state, the
/// calling task among them, each calling `f(!s, x)` with its own state
/// `s` on the next item `x` it takes, in the order of `items`, until
/// none is left. A List of each call's value, in the order of the
/// items, whichever task made it; nothing when `f` gives nothing. The
/// first call to fail stops the tasks taking more and cancels them,
/// and once all have ended, the call fails with its error, the values
/// made dropped.
pub fn parWorkers(states: anytype, items: anytype, f: anytype) WorkersOut(@TypeOf(f)) {
    return parWorkersInto(states, items, f, rt.no_slot);
}

/// `parWorkers` where a failure's fields go into the caller's slot `out`.
pub fn parWorkersInto(states: anytype, items: anytype, f: anytype, out_slot: anytype) WorkersOut(@TypeOf(f)) {
    const F = @TypeOf(f);
    const R = ReturnOf(F);
    const fallible = @typeInfo(R) == .error_union;
    const V = if (fallible) @typeInfo(R).error_union.payload else R;
    const gives = V != void;
    const n = items.len;
    if (states.len == 0 and n > 0) @panic("par.workers has no states to take the items");
    var out = if (gives) List(V).initCapacity(@intCast(n)) else {};
    _ = &out;
    const Ctx = struct {
        items: @TypeOf(items),
        f: F,
        out: if (gives) []V else void,
        made: if (marked) []bool else void,
        next: std.atomic.Value(usize) = .init(0),
        failed: std.atomic.Value(bool) = .init(false),
        failure: anyerror = undefined,
        failure_data: rt.ErrData = undefined,

        const marked = fallible and gives and rt.needsDrop(V);
        const Ctx = @This();

        /// The worker of state `s`: the next item, until none is left
        /// or a call has failed.
        fn run(c: *Ctx, s: @TypeOf(&states[0])) void {
            while (!c.failed.load(.acquire)) {
                const i = c.next.fetchAdd(1, .monotonic);
                if (i >= c.items.len) return;
                const x = rt.lend(&c.items[i]);
                if (comptime fallible) {
                    // Each call fails into a slot of its own, which the
                    // run keeps if it fails first.
                    var slot: rt.ErrData = undefined;
                    const v = c.f.call(rt.argsWithSlot(F, .{ s, x }, rt.failSlot(&slot))) catch |err| {
                        if (c.failed.cmpxchgStrong(false, true, .acq_rel, .acquire) == null) {
                            c.failure = err;
                            c.failure_data = slot;
                        } else rt.dropErrorData(err, &slot);
                        return;
                    };
                    if (comptime gives) c.out[i] = v;
                    if (comptime marked) c.made[i] = true;
                } else if (comptime gives) {
                    c.out[i] = c.f.call(.{ s, x });
                } else c.f.call(.{ s, x });
            }
        }
    };
    const marked = Ctx.marked;
    var ctx: Ctx = .{ .items = items, .f = f, .out = if (gives) out.buf.ptr[0..n] else {}, .made = undefined };
    if (comptime marked) {
        ctx.made = defaultAllocator().alloc(bool, n) catch oom();
        @memset(ctx.made, false);
    }
    defer if (comptime marked) defaultAllocator().free(ctx.made);
    if (states.len > 0) {
        // The other states' tasks start first, so each takes items as
        // soon as it runs; the calling task works with the first state.
        const helpers = defaultAllocator().alloc(Task(void), states.len - 1) catch oom();
        defer defaultAllocator().free(helpers);
        for (helpers, states[1..]) |*t, *s| t.* = Task(void).spawn(Ctx.run, .{ &ctx, s });
        Ctx.run(&ctx, &states[0]);
        if (fallible and ctx.failed.load(.acquire)) for (helpers) |t| t.control.cancel();
        for (helpers) |t| t.wait();
    }
    if (comptime fallible) if (ctx.failed.load(.acquire)) {
        if (comptime @TypeOf(out_slot) == rt.ErrSlot) rt.putFields(out_slot, &ctx.failure_data) else rt.dropErrorData(ctx.failure, &ctx.failure_data);
        if (comptime marked) for (ctx.out, ctx.made) |*v, m| if (m) dropElement(V, v);
        if (comptime gives) rt.drop(&out);
        // Every failure is `f`'s, or a wait's `task.Stop` in it.
        return @errorCast(ctx.failure);
    };
    if (comptime gives) {
        out.len = n;
        return out;
    }
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
    return isolateInto(f, rt.no_slot);
}

/// `isolate` where a failure's fields go into the caller's slot `out`,
/// or are dropped where it has none.
pub fn isolateInto(f: anytype, out: anytype) IsolateOut(@TypeOf(f)) {
    var own: rt.ErrData = undefined;
    const slot: rt.ErrSlot = if (comptime @TypeOf(out) == rt.ErrSlot) out else rt.failSlot(&own);
    const result = isolateWith(f, slot);
    if (comptime @TypeOf(out) != rt.ErrSlot) if (result) |_| {} else |err| rt.dropErrorData(err, &own);
    return result;
}

/// `isolate`, with `f`'s failure's fields in `slot` when it takes one.
fn isolateWith(f: anytype, slot: rt.ErrSlot) IsolateOut(@TypeOf(f)) {
    const F = @TypeOf(f);
    const R = ReturnOf(F);
    const state = task();
    var rec: Isolate = .{ .fiber = rt.sched.current(), .outer = state.isolate, .id = rt.isolateBegins(state.isolate) };
    const Run = struct {
        f: F,
        rec: *Isolate,
        slot: rt.ErrSlot,
        result: R = undefined,

        fn entry(p: *anyopaque) callconv(.c) noreturn {
            const run: *@This() = @ptrCast(@alignCast(p));
            run.result = run.f.call(rt.argsWithSlot(F, .{}, run.slot));
            rt.sched.leaveApart(run.rec.home);
        }
    };
    var run: Run = .{ .f = f, .rec = &rec, .slot = slot };
    state.isolate = &rec;
    rt.sched.runApart(&rec.home, &run, Run.entry);
    task().isolate = rec.outer;
    if (rec.panicked.load(.seq_cst)) return panicked_error;
    return run.result;
}

/// `task.supervise(f, restarts: n, per: ns)`: run `f` isolated, and run
/// it again when it fails or panics, at most `n` times within `ns`
/// nanoseconds (always when `n` is negative; within any time when `ns` is
/// 0); past that, fail as its last run failed. A cancel or a deadline is
/// no failure to start again from: it fails at once.
pub fn supervise(f: anytype, restarts: Int, per: Int) IsolateOut(@TypeOf(f)) {
    return superviseInto(f, restarts, per, rt.no_slot);
}

/// `supervise` where the last run's failure's fields go into the caller's
/// slot `out`; a run started again drops its fields first.
pub fn superviseInto(f: anytype, restarts: Int, per: Int, out: anytype) IsolateOut(@TypeOf(f)) {
    var count: Int = 0;
    var window: i96 = 0;
    while (true) {
        var own: rt.ErrData = undefined;
        if (isolateWith(f, rt.failSlot(&own))) |v| return v else |err| {
            errdefer if (comptime @TypeOf(out) == rt.ErrSlot) {
                rt.putFields(out, &own);
            } else rt.dropErrorData(err, &own);
            if (err == canceled_error or err == timeout_error) return err;
            if (restarts >= 0) {
                if (per > 0) {
                    const now = rt.sched.nowNs();
                    if (count == 0 or now - window > per) {
                        window = now;
                        count = 0;
                    }
                }
                if (count >= restarts) return err;
                count += 1;
            }
            rt.dropErrorData(err, &own);
        }
    }
}

/// What `isolate` gives for `f`: its value, failing as it can fail and
/// with `task.Stop.panicked`.
fn IsolateOut(comptime F: type) type {
    const R = ReturnOf(F);
    return WaitErr(&.{R})!(if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R);
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
// Channels
// -----------------------------------------------------------------------------

/// `Chan(T)`: a bounded channel, behind a shared handle counted
/// atomically (`*Chan[T](n)`), so its handles go to any task. `send`
/// waits for room, `recv` for a value, and both are fallible waiting
/// points; a closed channel gives its receivers what it holds, then
/// none. Every operation is a select of its own (`selectArms`): one
/// record (`Sel`) the first operation that can complete claims with one
/// compare-and-swap, so of a select's arms exactly one commits.
pub fn Chan(comptime T: type) type {
    return struct {
        lock: rt.sched.SpinLock = .{},
        buf: []T,
        head: usize = 0,
        len: usize = 0,
        closed: bool = false,
        /// Operations waiting to receive and to send, oldest first.
        receivers: Queue = .{},
        senders: Queue = .{},

        const Self = @This();
        /// Marks the type for `rt.Shared`'s atomic counts.
        pub const __rig_chan = {};
        /// Its arguments, for `typeName`.
        pub const __rig_args = .{T};
        pub const Item = T;

        pub fn __rig_print(_: Self, w: *std.Io.Writer) std.Io.Writer.Error!void {
            try w.writeAll("<chan>");
        }

        pub fn __rig_drop(self: *Self) void {
            while (self.len > 0) {
                var v = self.take();
                dropElement(T, &v);
            }
            defaultAllocator().free(self.buf);
        }

        /// A waiting operation: an arm of a select, in its caller's
        /// frame. A receiver's `value` is filled when a sender claims it;
        /// a sender's is taken when a receiver does.
        pub const Node = struct {
            sel: *Sel,
            arm: u32,
            value: T = undefined,
            /// A receiver that a close claimed, not a value.
            closed: bool = false,
            next: ?*Node = null,
            prev: ?*Node = null,
        };

        const Queue = struct {
            first: ?*Node = null,
            last: ?*Node = null,

            fn push(q: *Queue, n: *Node) void {
                n.next = null;
                n.prev = q.last;
                if (q.last) |l| l.next = n else q.first = n;
                q.last = n;
            }

            fn remove(q: *Queue, n: *Node) void {
                if (n.prev) |p| p.next = n.next else if (q.first == n) q.first = n.next else return;
                if (n.next) |x| x.prev = n.prev else q.last = n.prev;
                n.next = null;
                n.prev = null;
            }

            /// The oldest node whose select this claims for it, taken
            /// off the queue; nodes whose select is over are dropped.
            fn claim(q: *Queue) ?*Node {
                while (q.first) |n| {
                    q.remove(n);
                    if (n.sel.claim(n.arm)) return n;
                }
                return null;
            }
        };

        pub fn make(capacity: Int) Self {
            const cap: usize = @intCast(@max(capacity, 1));
            return .{ .buf = defaultAllocator().alloc(T, cap) catch oom() };
        }

        fn put(self: *Self, v: T) void {
            self.buf[(self.head + self.len) % self.buf.len] = v;
            self.len += 1;
        }

        fn take(self: *Self) T {
            const v = self.buf[self.head];
            self.head = (self.head + 1) % self.buf.len;
            self.len -= 1;
            return v;
        }

        /// Receive at once, under the lock, into `out`: a value buffered
        /// (moving a waiting sender's into its place), or one a waiting
        /// sender hands over, or none when closed; false when it would
        /// wait.
        fn recvNow(self: *Self, out: *?T) bool {
            if (self.len > 0) {
                out.* = self.take();
                if (self.senders.claim()) |n| {
                    self.put(n.value);
                    n.sel.wake();
                }
                return true;
            }
            if (self.senders.claim()) |n| {
                out.* = n.value;
                n.sel.wake();
                return true;
            }
            if (self.closed) {
                out.* = null;
                return true;
            }
            return false;
        }

        /// Send `v` at once, under the lock: to a waiting receiver, or
        /// into the buffer; false when it would wait.
        fn sendNow(self: *Self, v: T) bool {
            if (self.closed) @panic("send on a closed channel");
            if (self.receivers.claim()) |n| {
                n.value = v;
                n.sel.wake();
                return true;
            }
            if (self.len < self.buf.len) {
                self.put(v);
                return true;
            }
            return false;
        }

        /// `!ch.send(<v)!`: wait for room, and send `v`.
        pub fn send(self: *Self, v: T) anyerror!void {
            var arms = .{SendArm(T, void){ .chan = self, .value = v, .f = {} }};
            _ = try selectArms(&arms);
        }

        /// `(!ch).recv()!`: wait for a value, or none once the channel is
        /// closed and empty.
        pub fn recv(self: *Self) anyerror!?T {
            var arms = .{RecvArm(T, void){ .chan = self, .f = {} }};
            _ = try selectArms(&arms);
            return arms[0].got;
        }

        /// `!ch.close()`: no more sends; receivers waiting get none, and a
        /// sender waiting panics.
        pub fn close(self: *Self) void {
            self.lock.lock();
            defer self.lock.unlock();
            if (self.closed) return;
            self.closed = true;
            while (self.receivers.claim()) |n| {
                n.closed = true;
                n.sel.wake();
            }
            if (self.senders.first != null) @panic("a channel was closed while a task waited to send on it");
        }
    };
}

/// `*Chan[T](n)`: a channel of `n` slots (at least one), behind its first
/// handle.
pub fn chan(comptime T: type, capacity: Int) *rt.Shared(Chan(T)) {
    return rt.shared(Chan(T).make(capacity));
}

/// What a select waits on: claimed by the first arm that completes
/// (`state` is its index plus one), and the fiber to wake then.
const Sel = struct {
    state: std.atomic.Value(u32) = .init(open),
    fiber: *rt.sched.Fiber,
    epoch: std.atomic.Value(u32) = .init(0),

    const open = 0;
    /// Claimed by the select itself, as it gives up.
    const gave_up = std.math.maxInt(u32);

    fn claim(sel: *Sel, arm: u32) bool {
        return sel.state.cmpxchgStrong(open, arm + 1, .seq_cst, .seq_cst) == null;
    }

    fn wake(sel: *Sel) void {
        _ = rt.sched.interrupt(sel.fiber, sel.epoch.load(.seq_cst), false);
    }
};

/// A receiving arm: `(!ch).on_recv(f)`, or `recv` alone (`F` void).
pub fn RecvArm(comptime T: type, comptime F: type) type {
    return struct {
        chan: *Chan(T),
        f: F,
        node: Chan(T).Node = undefined,
        got: ?T = null,

        pub const Value = ?T;

        fn key(a: *@This()) usize {
            return @intFromPtr(a.chan);
        }

        fn now(a: *@This()) bool {
            return a.chan.recvNow(&a.got);
        }

        fn wait(a: *@This(), sel: *Sel, arm: u32) void {
            a.node = .{ .sel = sel, .arm = arm };
            a.chan.receivers.push(&a.node);
        }

        fn unwait(a: *@This()) void {
            a.chan.receivers.remove(&a.node);
        }

        /// It won while waiting: what the sender or the close left.
        fn won(a: *@This()) void {
            a.got = if (a.node.closed) null else a.node.value;
        }

        /// It lost: nothing of it to drop.
        fn lost(_: *@This()) void {}
    };
}

/// A sending arm: `(!ch).on_send(<v, f)`, or `send` alone (`F` void).
pub fn SendArm(comptime T: type, comptime F: type) type {
    return struct {
        chan: *Chan(T),
        value: T,
        f: F,
        node: Chan(T).Node = undefined,

        fn key(a: *@This()) usize {
            return @intFromPtr(a.chan);
        }

        fn now(a: *@This()) bool {
            return a.chan.sendNow(a.value);
        }

        fn wait(a: *@This(), sel: *Sel, arm: u32) void {
            a.node = .{ .sel = sel, .arm = arm, .value = a.value };
            a.chan.senders.push(&a.node);
        }

        fn unwait(a: *@This()) void {
            a.chan.senders.remove(&a.node);
        }

        fn won(_: *@This()) void {}

        /// It lost: the value it held is dropped.
        fn lost(a: *@This()) void {
            dropElement(T, &a.value);
        }
    };
}

/// `rig.recvArm(handle, f)` and `rig.sendArm(handle, v, f)`: the arms
/// `task.select` takes.
pub fn recvArm(handle: anytype, f: anytype) RecvArm(ChanItem(@TypeOf(handle)), @TypeOf(f)) {
    return .{ .chan = &chanBox(handle).value, .f = f };
}

pub fn sendArm(handle: anytype, v: anytype, f: anytype) SendArm(ChanItem(@TypeOf(handle)), @TypeOf(f)) {
    return .{ .chan = &chanBox(handle).value, .value = v, .f = f };
}

fn chanBox(handle: anytype) ChanBox(@TypeOf(handle)) {
    return if (@typeInfo(@typeInfo(@TypeOf(handle)).pointer.child) == .pointer) handle.* else handle;
}

fn ChanBox(comptime H: type) type {
    const Child = @typeInfo(H).pointer.child;
    return if (@typeInfo(Child) == .pointer) Child else H;
}

fn ChanItem(comptime H: type) type {
    return @FieldType(@typeInfo(ChanBox(H)).pointer.child, "value").Item;
}

/// Wait until one of `arms` (a tuple, behind a pointer) completes, and
/// give its index: at once when one can, trying them from a place the
/// scheduler's random choice or a counter picks, so none starves; else
/// each waits on its channel, and the first to complete claims the
/// select, which wakes and takes the others back. A fallible waiting
/// point: a cancel or the deadline ends it, unless an arm won first.
/// Every arm but the winner is `lost`.
fn selectArms(arms: anytype) anyerror!u32 {
    const n = @typeInfo(@TypeOf(arms.*)).@"struct".field_types.len;
    if (canceledHere()) return dropAll(arms, canceled_error);
    if (pastDeadline()) return dropAll(arms, timeout_error);
    lockAll(arms);
    const start = rotation() % n;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const at = (start + i) % n;
        var done = false;
        inline for (0..n) |k| if (k == at) {
            done = arms[k].now();
        };
        if (done) {
            unlockAll(arms);
            loseAllBut(arms, @intCast(at));
            return @intCast(at);
        }
    }
    const f = rt.sched.current() orelse {
        unlockAll(arms);
        @panic("a channel waited outside a task");
    };
    var sel: Sel = .{ .fiber = f };
    var e = rt.sched.beginWait(true);
    sel.epoch.store(e, .seq_cst);
    inline for (0..n) |k| arms[k].wait(&sel, k);
    unlockAll(arms);
    while (true) {
        if (sel.state.load(.seq_cst) != Sel.open) break;
        if (canceledHere() or pastDeadline()) {
            if (sel.state.cmpxchgStrong(Sel.open, Sel.gave_up, .seq_cst, .seq_cst) == null) break;
            break;
        }
        rt.sched.commitWait(e, task().deadline);
        if (sel.state.load(.seq_cst) != Sel.open) break;
        e = rt.sched.beginWait(true);
        sel.epoch.store(e, .seq_cst);
    }
    // Take back the arms still waiting; the winner's claimer is done with
    // it, since it held that channel's lock.
    lockAll(arms);
    inline for (0..n) |k| arms[k].unwait();
    unlockAll(arms);
    const state = sel.state.load(.acquire);
    if (state == Sel.gave_up) {
        inline for (0..n) |k| arms[k].lost();
        return if (canceledHere()) canceled_error else timeout_error;
    }
    const winner: u32 = state - 1;
    inline for (0..n) |k| if (k == winner) arms[k].won();
    loseAllBut(arms, winner);
    return winner;
}

var select_turn: std.atomic.Value(u32) = .init(0);

fn rotation() usize {
    return select_turn.fetchAdd(1, .monotonic);
}

fn dropAll(arms: anytype, err: anyerror) anyerror!u32 {
    const n = @typeInfo(@TypeOf(arms.*)).@"struct".field_types.len;
    inline for (0..n) |k| arms[k].lost();
    return err;
}

fn loseAllBut(arms: anytype, winner: u32) void {
    const n = @typeInfo(@TypeOf(arms.*)).@"struct".field_types.len;
    inline for (0..n) |k| if (k != winner) arms[k].lost();
}

/// Lock each channel of `arms` once, in the order of their addresses, so
/// two selects never wait on each other's locks.
fn lockAll(arms: anytype) void {
    var keys = chanKeys(arms);
    std.mem.sort(usize, keys.slice(), {}, std.sort.asc(usize));
    var last: usize = 0;
    for (keys.slice()) |k| {
        if (k == last) continue;
        last = k;
        lockAt(arms, k);
    }
}

fn unlockAll(arms: anytype) void {
    var keys = chanKeys(arms);
    std.mem.sort(usize, keys.slice(), {}, std.sort.asc(usize));
    var last: usize = 0;
    for (keys.slice()) |k| {
        if (k == last) continue;
        last = k;
        unlockAt(arms, k);
    }
}

fn ChanKeys(comptime n: usize) type {
    return struct {
        items: [n]usize,
        fn slice(k: *@This()) []usize {
            return &k.items;
        }
    };
}

fn chanKeys(arms: anytype) ChanKeys(@typeInfo(@TypeOf(arms.*)).@"struct".field_types.len) {
    const n = @typeInfo(@TypeOf(arms.*)).@"struct".field_types.len;
    var keys: ChanKeys(n) = undefined;
    inline for (0..n) |k| keys.items[k] = arms[k].key();
    return keys;
}

fn lockAt(arms: anytype, key: usize) void {
    const n = @typeInfo(@TypeOf(arms.*)).@"struct".field_types.len;
    inline for (0..n) |k| if (arms[k].key() == key) {
        arms[k].chan.lock.lock();
        return;
    };
}

fn unlockAt(arms: anytype, key: usize) void {
    const n = @typeInfo(@TypeOf(arms.*)).@"struct".field_types.len;
    inline for (0..n) |k| if (arms[k].key() == key) {
        arms[k].chan.lock.unlock();
        return;
    };
}

/// `task.select(arm, ...)`: wait until one arm's channel operation
/// completes, commit that one alone, and give what its function gives:
/// for `on_recv`, called with the value received, or none once the
/// channel is closed and empty; for `on_send`, called once the value is
/// sent. The values of the sending arms that lose are dropped.
pub fn select(arms_in: anytype) SelectOut(@TypeOf(arms_in)) {
    var data: rt.ErrData = undefined;
    return selectInto(arms_in, rt.failSlot(&data));
}

/// `select`, giving a failure's fields to the slot `slot` its `!` or
/// `catch` lends, as a fallible arm's function takes one.
pub fn selectInto(arms_in: anytype, slot: rt.ErrSlot) SelectOut(@TypeOf(arms_in)) {
    var arms = arms_in;
    const n = @typeInfo(@TypeOf(arms)).@"struct".field_types.len;
    const winner = try selectArms(&arms);
    inline for (0..n) |k| if (k == winner) {
        const A = @TypeOf(arms[k]);
        const F = @TypeOf(arms[k].f);
        if (@hasDecl(A, "Value")) return arms[k].f.call(rt.argsWithSlot(F, .{arms[k].got}, slot));
        return arms[k].f.call(rt.argsWithSlot(F, .{}, slot));
    };
    unreachable;
}

fn SelectOut(comptime Arms: type) type {
    const F = @typeInfo(Arms).@"struct".field_types[0];
    const R = ReturnOf(@FieldType(F, "f"));
    return anyerror!(if (@typeInfo(R) == .error_union) @typeInfo(R).error_union.payload else R);
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

        /// A free slot in its mailbox, as a deadlock names a wait for one
        /// (`actorSpawn`).
        const slot_label: rt.sched.Label = .{ .actor = actorName(T), .method = "", .slot = true };

        /// Whether a call made with `&` could take a slot now: what a
        /// wait for one waits on, for a deadlock's walk.
        fn slotFree(p: *const anyopaque) bool {
            const self: *const Self = @ptrCast(@alignCast(p));
            return self.pending.load(.seq_cst) < self.capacity;
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
        fn dieInline(h: *rt.sched.Held) void {
            heldBy(h).kill(h.doing);
        }

        /// A panic in the runner: the actor dies, the runner's handle
        /// goes, and the panic stops here (`TaskState.runner`).
        fn dieRunner(h: *rt.sched.Held) void {
            const self = heldBy(h);
            self.kill(h.doing);
            const box: *rt.Shared(Self) = @fieldParentPtr("value", self);
            box.dropStrong();
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
            f.state.runner = true;
            defer {
                f.held = held.next;
                f.state.runner = false;
            }
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
    const stop = panicStops();
    var at = f.held;
    f.held = null;
    while (at) |h| : (at = h.next) h.die(h);
    return stop;
}

/// Whether a panic on the running fiber stops at an actor's runner the
/// fiber is, before any actor dies (`actorsDie`). A runner marks its
/// task once as it starts, so a call made inline pays nothing for this.
pub fn panicStops() bool {
    if (!rt.scheduled) return false;
    const f = rt.sched.current() orelse return false;
    return f.state.runner;
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
    const box = rt.shared(Actor(@TypeOf(value)){ .value = value, .capacity = @intCast(rt.unsigned(@max(capacity, 1))) });
    return box;
}

/// `*Actor.supervised(make, mailbox: n, restarts: r, per: ns)`: an actor
/// whose value `make`, an owned closure it keeps, makes now and again
/// each time a panic ends it, at most `restarts` times within `per`
/// nanoseconds (`Actor.kill`).
pub fn actorSupervised(make: anytype, capacity: Int, restarts: Int, per: Int) *rt.Shared(Actor(@TypeOf(make.value).__rig_fn[1])) {
    const T = @TypeOf(make.value).__rig_fn[1];
    const value = make.value.invoke(.{});
    return rt.shared(Actor(T){ .value = value, .capacity = @intCast(rt.unsigned(@max(capacity, 1))), .make = make, .restarts = restarts, .per = per });
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
    // Waiting for a slot, the fiber blocks on the actor, as a call to it
    // does: a slot frees only once the actor answers a call made with
    // `&`, so a wait the actor's own method makes, or one through calls
    // that come back to the waiter, is a deadlock (`rt.sched.block`).
    const A = @TypeOf(self.*);
    const slot_wait: rt.sched.Blocked = .{ .call = .{ .label = &A.slot_label, .held_by = &self.held_by, .msg = self, .answered = A.slotFree } };
    var blocked = false;
    while (true) {
        const n = self.pending.load(.seq_cst);
        if (n < self.capacity) {
            if (self.pending.cmpxchgWeak(n, n + 1, .seq_cst, .seq_cst) == null) break;
            continue;
        }
        if (!blocked) {
            blocked = true;
            rt.sched.block(&slot_wait);
        }
        rt.sched.yield();
    }
    if (blocked) rt.sched.unblock();
    const Run = struct {
        fn run(b: @TypeOf(box), a: @TypeOf(args)) R {
            defer {
                _ = b.value.pending.fetchSub(1, .seq_cst);
                b.dropStrong();
            }
            return @TypeOf(b.value).call(b, name, a);
        }

        /// `run` of a method that may fail with fields: it is given the
        /// task's slot, last.
        fn runInto(b: @TypeOf(box), a: @TypeOf(args), slot: rt.ErrSlot) R {
            defer {
                _ = b.value.pending.fetchSub(1, .seq_cst);
                b.dropStrong();
            }
            return @TypeOf(b.value).call(b, name, a ++ .{slot});
        }
    };
    if (comptime takesSlot(@TypeOf(@field(@TypeOf(self.value), name)))) return Task(R).spawn(Run.runInto, .{ box.cloneStrong(), args });
    return Task(R).spawn(Run.run, .{ box.cloneStrong(), args });
}

/// `std.task`'s `Stop`, as the emitted code names its errors: what a
/// waiting point of any `std` module may fail with (`expectShim`).
pub const Stop = error{ @"std.task.Stop.canceled", @"std.task.Stop.timeout", @"std.task.Stop.panicked" };

/// `task.Stop.canceled`, the error a canceled task's waiting points fail
/// with.
const canceled_error = error.@"std.task.Stop.canceled";

/// Whether the running task is canceled. `main` never is. Sequentially
/// consistent: a waiting point begins its wait and then looks here, and
/// a canceler sets the flag and then looks at the wait
/// (`Control.cancel`), so at least one of the two sees the other.
fn canceledHere() bool {
    const control = task().control orelse return false;
    return control.canceled.load(.seq_cst);
}

/// `task.workers(n)`: run tasks on `n` workers (1 to 64), in place of
/// one per core or `RIG_WORKERS`; whether it took effect, which it does
/// only before the program's first task starts the workers, and in a
/// program that makes tasks.
pub fn setWorkers(n: Int) bool {
    if (!rt.scheduled or n < 1) return false;
    return rt.sched.askWorkers(@intCast(n));
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
/// thread, where only an interrupt's cancel of `main` can come
/// (`sleepHere`).
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
        const d = deadline orelse return sleepHere(ns);
        if (d >= until) return sleepHere(ns);
        const left = d - nowNs();
        if (left > 0) try sleepHere(@intCast(left));
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

/// Sleep `ns` nanoseconds on this thread, outside the scheduler. An
/// interrupt that cancels `main` ends the sleep (its handler leaves
/// system calls to fail with EINTR, `rt.cancelOnInterrupt`), and the
/// sleep fails with `Stop.canceled`; Zig's own sleep would go back to
/// sleeping.
fn sleepHere(ns: i64) Stop!void {
    const posix = std.posix;
    if (canceledHere()) return canceled_error;
    var left: posix.timespec = .{ .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)), .nsec = @intCast(@rem(ns, std.time.ns_per_s)) };
    rt.flushBeforeWait();
    while (true) {
        switch (posix.errno(posix.system.nanosleep(&left, &left))) {
            .INTR => if (canceledHere()) return canceled_error,
            else => return,
        }
    }
}

test "a task given what crosses cores runs anywhere, and a local task and its maker are pinned" {
    const builtin = @import("builtin");
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var free_pinned = true;
        var maker_pinned_before = true;
        var local_pinned = false;
        var maker_pinned_after = false;
        fn one() u64 {
            return 1;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            const t = Task(u64).spawn(one, .{});
            free_pinned = t.handle.job.header.fiber.home != null;
            maker_pinned_before = rt.sched.current().?.home != null;
            _ = t.wait();
            const u = Task(u64).spawnLocal(one, .{});
            local_pinned = u.handle.job.header.fiber.home != null;
            maker_pinned_after = rt.sched.current().?.home != null;
            _ = u.wait();
        }
    };
    rt.sched.runForTest(Run.first, 2);
    try std.testing.expect(!Run.free_pinned);
    try std.testing.expect(!Run.maker_pinned_before);
    try std.testing.expect(Run.local_pinned);
    try std.testing.expect(Run.maker_pinned_after);
}

test "a task's failure data moves to the waiter's slot, and is dropped wherever it is discarded" {
    const builtin = @import("builtin");
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const G = rt.TestErrorGlue;
    const Run = struct {
        var kept: u8 = 0;
        var drops_after_into: usize = 0;
        var drops_after_wait: usize = 0;
        var drops_after_cancel: usize = 0;
        var drops_after_drop: usize = 0;
        fn fails(out: rt.ErrSlot) anyerror!i64 {
            out.bytes[0] = 7;
            return error.WithData;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            G.drops.store(0, .seq_cst);
            var slot: rt.ErrData = undefined;
            const a = Task(anyerror!i64).spawn(fails, .{});
            if (a.waitInto(rt.failSlot(&slot))) |_| {} else |_| kept = slot.bytes[0];
            drops_after_into = G.drops.load(.seq_cst);
            const b = Task(anyerror!i64).spawn(fails, .{});
            _ = b.wait() catch {};
            drops_after_wait = G.drops.load(.seq_cst);
            const c = Task(anyerror!i64).spawn(fails, .{});
            _ = c.cancel() catch {};
            drops_after_cancel = G.drops.load(.seq_cst);
            var d = Task(anyerror!i64).spawn(fails, .{});
            d.__rig_drop();
            drops_after_drop = G.drops.load(.seq_cst);
        }
    };
    rt.sched.runForTest(Run.first, 2);
    try std.testing.expectEqual(@as(u8, 7), Run.kept);
    try std.testing.expectEqual(@as(usize, 0), Run.drops_after_into);
    try std.testing.expectEqual(@as(usize, 1), Run.drops_after_wait);
    try std.testing.expectEqual(@as(usize, 2), Run.drops_after_cancel);
    try std.testing.expectEqual(@as(usize, 3), Run.drops_after_drop);
}

test "a set of tasks keeps the failure it gives and drops every other one's data" {
    const builtin = @import("builtin");
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const G = rt.TestErrorGlue;
    const Run = struct {
        var all_kept: u8 = 0;
        var first_kept: u8 = 0;
        var drops_after_all: usize = 0;
        var drops_after_first: usize = 0;
        var drops_after_drop: usize = 0;
        fn fails(n: u8, out: rt.ErrSlot) anyerror!i64 {
            out.bytes[0] = n;
            return error.WithData;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            G.drops.store(0, .seq_cst);
            var slot: rt.ErrData = undefined;
            var a: Tasks(anyerror!i64) = .{};
            a.add(Task(anyerror!i64).spawn(fails, .{5}));
            if (a.wait_allInto(rt.failSlot(&slot))) |l| {
                var v = l;
                v.__rig_drop();
            } else |_| all_kept = slot.bytes[0];
            drops_after_all = G.drops.load(.seq_cst);
            var b: Tasks(anyerror!i64) = .{};
            b.add(Task(anyerror!i64).spawn(fails, .{1}));
            b.add(Task(anyerror!i64).spawn(fails, .{2}));
            if (b.wait_firstInto(rt.failSlot(&slot))) |_| {} else |_| first_kept = slot.bytes[0];
            drops_after_first = G.drops.load(.seq_cst);
            var c: Tasks(anyerror!i64) = .{};
            c.add(Task(anyerror!i64).spawn(fails, .{3}));
            c.add(Task(anyerror!i64).spawn(fails, .{4}));
            c.__rig_drop();
            drops_after_drop = G.drops.load(.seq_cst);
        }
    };
    rt.sched.runForTest(Run.first, 2);
    try std.testing.expectEqual(@as(u8, 5), Run.all_kept);
    try std.testing.expectEqual(@as(usize, 0), Run.drops_after_all);
    try std.testing.expect(Run.first_kept == 1 or Run.first_kept == 2);
    try std.testing.expectEqual(@as(usize, 1), Run.drops_after_first);
    try std.testing.expectEqual(@as(usize, 3), Run.drops_after_drop);
}

test "a par run keeps its first chunk's failure data and drops every later one's" {
    const builtin = @import("builtin");
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const G = rt.TestErrorGlue;
    const Run = struct {
        var kept: u8 = 0;
        var failed = false;
        var drops: usize = 0;
        var calls: std.atomic.Value(usize) = .init(0);
        const Ctx = struct {};
        fn chunk(_: *const Ctx, lo: usize, _: usize, out: rt.ErrSlot) anyerror!void {
            _ = calls.fetchAdd(1, .seq_cst);
            out.bytes[0] = @intCast(lo + 1);
            return error.WithData;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            G.drops.store(0, .seq_cst);
            const ctx: Ctx = .{};
            var slot: rt.ErrData = undefined;
            parRunInto(true, 64, 4, &ctx, chunk, rt.failSlot(&slot)) catch {
                failed = true;
                kept = slot.bytes[0];
            };
            drops = G.drops.load(.seq_cst);
        }
    };
    rt.sched.runForTest(Run.first, 4);
    try std.testing.expect(Run.failed);
    try std.testing.expect(Run.kept >= 1);
    // Every chunk that ran failed: one was kept, the rest dropped.
    try std.testing.expectEqual(Run.calls.load(.seq_cst) - 1, Run.drops);
}
