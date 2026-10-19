//! The scheduler: Rig's tasks run as fibers, each on a stack of its own,
//! switched by saving and restoring the registers a call keeps
//! (`switchTo`), not by the operating system. One worker thread per core
//! runs them; the thread that runs `main` is worker 0, and `main` is the
//! first fiber (`runMain`). A program selects it with `__rig_scheduler`
//! (`RIG_SCHEDULER=1` when `bin/rig` builds it); `bin/rig` writes this
//! file beside the runtime as `rig/sched.zig`.
//!
//! Each worker owns a ring of fibers ready to run, which it takes from in
//! order; a worker with none takes from the global queue, or steals half
//! of another's ring. A worker with nothing to do sleeps until woken, and
//! work made where no worker searches for it wakes one, which wakes
//! another if it finds more. A fiber that stops (to yield, or to wait) is
//! queued, or recorded as waiting, only once it has switched away, by
//! the worker it left (`After`), so no other worker resumes it while its
//! registers are still being saved.

const std = @import("std");
const builtin = @import("builtin");
const rt = @import("runtime.zig");

/// A fiber: a task's own stack, and the stack pointer it left when it
/// last switched away, below the registers it saved there.
pub const Fiber = struct {
    sp: usize = 0,
    run: *const fn (*Fiber) void,
    stack: ?Stack = null,
    /// What the runtime keeps for the task (`rt.task`).
    state: rt.TaskState = .{},
    /// Set by the fiber as its last act, before it switches away for good.
    finished: bool = false,
    /// What its worker does once it has switched away for good: publish
    /// its end (`Header`), or nothing for `main`.
    done: ?*const fn (*Fiber) void = null,
    /// The next fiber in the global queue.
    next: ?*Fiber = null,
    /// The fiber that handed this one its worker (`handoff`), to switch
    /// back to when this one ends without stopping first.
    handoff: ?*Fiber = null,
    /// The epoch of that fiber's wait as it handed its worker over.
    handoff_epoch: u32 = 0,
    /// Its wait for what another fiber or thread does (`Wait`).
    wait: Wait = .{},
};

/// What a worker does with the fiber that just switched away, once it has:
/// queue it again (`yield`), or record it as waiting (`park`).
const After = struct {
    run: *const fn (*Fiber, ?*anyopaque) void,
    ctx: ?*anyopaque = null,
};

/// A worker: its own stack pointer while a fiber runs, the fiber
/// running, its ring of ready fibers, its stacks to reuse, and the word it
/// sleeps on.
const Worker = struct {
    sp: usize = 0,
    current: ?*Fiber = null,
    after: ?After = null,
    ring: Ring = .{},
    /// The fiber to run next: the one this worker's fibers last made
    /// ready, still in cache. Only this worker takes it, at most
    /// `lifo_limit` times in a row.
    lifo: ?*Fiber = null,
    lifo_streak: u8 = 0,
    free: ?*FreeStack = null,
    free_count: u32 = 0,
    /// A fiber handed this worker that ended and switched straight back
    /// to the fiber that handed it over, which finishes it (`handoff`).
    returned: ?*Fiber = null,
    /// Turns since it last looked at the global queue first.
    tick: u32 = 0,
    /// The futex word it sleeps on: 1 once woken.
    woken: std.atomic.Value(u32) = .init(0),
    /// The next worker asleep (`Sleepers`).
    next_sleeper: ?*Worker = null,
    searching: bool = false,
    rng: u32 = 1,
    thread: ?std.Thread = null,
};

/// The workers, worker 0 first; set by `runMain`.
var workers: []Worker = &.{};
threadlocal var me_slot: ?*Worker = null;

/// This thread's worker. A fiber may resume on another thread after any
/// switch, and a compiler may reuse a thread-local's address within a
/// function, so every read goes through this call, which is never inlined.
noinline fn me() ?*Worker {
    return me_slot;
}

/// Test only: how many workers `runMain` starts, in place of
/// `RIG_WORKERS` or the core count.
var workers_override: ?usize = null;
var global: Global = .{};
var sleepers: Sleepers = .{};
/// Workers looking for work to steal: a worker that makes work wakes a
/// sleeping one only when none is looking.
var searching: std.atomic.Value(u32) = .init(0);
var stopping: std.atomic.Value(bool) = .init(false);

/// The fiber running on this thread, or none outside every fiber.
pub fn current() ?*Fiber {
    const w = me() orelse return null;
    return w.current;
}

/// Make `f` ready to run, next on this worker: in its "run next" slot,
/// whose fiber before it moves to the ring, where other workers can
/// take it. Waking a sleeping worker is left to when there is such a
/// fiber to take, and none is looking (`notify`). Outside the workers,
/// `f` goes to the global queue.
pub fn wake(f: *Fiber) void {
    const w = me() orelse {
        global.push(f);
        return notify();
    };
    const before = w.lifo;
    w.lifo = f;
    if (before) |b| {
        w.ring.push(b);
        notify();
    }
}

/// Make `f` ready to run after the fibers already ready on this worker.
fn wakeLast(f: *Fiber) void {
    if (me()) |w| w.ring.push(f) else global.push(f);
    notify();
}

/// Let other fibers run, then go on.
pub fn yield() void {
    stop(.{ .run = requeue });
}

fn requeue(f: *Fiber, _: ?*anyopaque) void {
    wakeLast(f);
}

/// How many times in a row a worker runs its "run next" fiber before it
/// takes one from its ring, so two fibers waking each other cannot keep
/// the others waiting.
const lifo_limit = 3;

// -----------------------------------------------------------------------------
// Waiting
// -----------------------------------------------------------------------------

/// How a fiber waits for what another fiber or thread does: a task's end,
/// a set's count, a timer, a cancel, or a call on the blocking pool. Each
/// wait has a number, its epoch. The fiber begins it (`beginWait`), tells
/// its waker the epoch, looks once more at what it waits for, and commits
/// (`commitWait`): it switches away, and its worker marks it asleep. A
/// waker moves the wait from about to sleep, or asleep, to woken, for its
/// epoch only (`interrupt`). So exactly one waker wins; one that comes
/// before the fiber has switched away leaves it woken, and the fiber goes
/// straight back on a queue; and one that comes late finds a later epoch
/// and does nothing.
pub const Wait = struct {
    /// The epoch, whether a cancel may end the wait, and its state.
    word: std.atomic.Value(u64) = .init(0),
    epoch: u32 = 0,
    /// When a timer may end the wait: its deadline, the epoch it was set
    /// for, and its place in the timer heap.
    deadline: i96 = 0,
    timer_epoch: u32 = 0,
    heap_index: usize = no_index,

    const about = 0;
    const asleep = 1;
    const woken = 2;
    const cancelable_bit: u64 = 4;
    const states: u64 = 3;
    const no_index = std.math.maxInt(usize);

    fn pack(epoch: u32, cancelable: bool, state: u64) u64 {
        return (@as(u64, epoch) << 3) | (if (cancelable) cancelable_bit else 0) | state;
    }

    fn epochOf(w: u64) u32 {
        return @truncate(w >> 3);
    }
};

/// Begin a wait of the running fiber, which a cancel may end when
/// `cancelable`, and give its epoch, for its waker to pass to
/// `interrupt`.
pub fn beginWait(cancelable: bool) u32 {
    const f = current().?;
    f.wait.epoch +%= 1;
    f.wait.word.store(Wait.pack(f.wait.epoch, cancelable, Wait.about), .seq_cst);
    return f.wait.epoch;
}

/// Sleep until the wait `epoch`, which `beginWait` gave, is woken, or
/// `deadline` (the monotonic clock, in nanoseconds) passes.
pub fn commitWait(epoch: u32, deadline: ?i96) void {
    const f = current().?;
    if (deadline) |d| {
        f.wait.deadline = d;
        f.wait.timer_epoch = epoch;
    }
    park(.{ .run = fallAsleep, .ctx = if (deadline != null) @ptrFromInt(1) else null });
    // Awake: a timer still set for this wait is taken back, so none
    // touches this fiber once it goes on.
    if (deadline != null) timers.cancel(f);
}

/// Once the fiber has switched away: set its timer, then mark it asleep,
/// unless a waker has come first, when it goes on.
fn fallAsleep(f: *Fiber, timed: ?*anyopaque) void {
    if (timed != null) timers.add(f);
    const w = f.wait.word.load(.seq_cst);
    if (Wait.epochOf(w) == f.wait.epoch and w & Wait.states == Wait.about) {
        if (f.wait.word.cmpxchgStrong(w, (w & ~Wait.states) | Wait.asleep, .seq_cst, .seq_cst) == null) return;
    }
    wake(f);
}

/// End the wait `epoch` of `f`, if it is still on, and give whether this
/// call ended it. A cancel passes `cancel`, and ends only a wait that a
/// cancel may end.
pub fn interrupt(f: *Fiber, epoch: u32, cancel: bool) bool {
    var w = f.wait.word.load(.seq_cst);
    while (true) {
        if (Wait.epochOf(w) != epoch) return false;
        const state = w & Wait.states;
        if (state == Wait.woken) return false;
        if (cancel and w & Wait.cancelable_bit == 0) return false;
        w = f.wait.word.cmpxchgWeak(w, (w & ~Wait.states) | Wait.woken, .seq_cst, .seq_cst) orelse {
            if (state == Wait.asleep) wake(f);
            return true;
        };
    }
}

/// Take the wait `epoch` of `f`, asleep, as `interrupt` does, but without
/// queueing `f`: for the fiber `f` handed its worker to, which switches
/// straight back to it (`fiberMain`). False when a waker took it first.
fn claim(f: *Fiber, epoch: u32) bool {
    var w = f.wait.word.load(.seq_cst);
    while (Wait.epochOf(w) == epoch and w & Wait.states == Wait.asleep) {
        w = f.wait.word.cmpxchgWeak(w, (w & ~Wait.states) | Wait.woken, .seq_cst, .seq_cst) orelse return true;
    }
    return false;
}

/// A cancel of the task `f` runs: end its present wait, if a cancel may.
pub fn interruptForCancel(f: *Fiber) void {
    _ = interrupt(f, Wait.epochOf(f.wait.word.load(.seq_cst)), true);
}

/// The monotonic clock, in nanoseconds: what deadlines count on.
pub fn nowNs() i96 {
    return std.Io.Timestamp.now(rt.io(), .awake).nanoseconds;
}

// -----------------------------------------------------------------------------
// Timers
// -----------------------------------------------------------------------------

/// The fibers waiting with a deadline, earliest first, and the thread
/// that sleeps until the earliest and wakes those whose deadline has
/// passed. Its lock is held while it wakes one, so a fiber that takes its
/// timer back (`cancel`) knows the thread is done with it.
const Timers = struct {
    lock: SpinLock = .{},
    heap: std.ArrayList(*Fiber) = .empty,
    /// The futex word its thread sleeps on: changed when an earlier
    /// deadline is set, and when the program ends.
    word: std.atomic.Value(u32) = .init(0),
    thread: ?std.Thread = null,

    fn add(t: *Timers, f: *Fiber) void {
        t.lock.lock();
        const earliest = t.heap.items.len == 0 or f.wait.deadline < t.heap.items[0].wait.deadline;
        t.heap.append(std.heap.smp_allocator, f) catch rt.oom();
        f.wait.heap_index = t.heap.items.len - 1;
        t.up(f.wait.heap_index);
        if (t.thread == null) t.thread = std.Thread.spawn(.{}, timerMain, .{t}) catch rt.oom();
        t.lock.unlock();
        if (earliest) t.poke();
    }

    fn cancel(t: *Timers, f: *Fiber) void {
        t.lock.lock();
        defer t.lock.unlock();
        if (f.wait.heap_index != Wait.no_index) t.removeAt(f.wait.heap_index);
    }

    fn poke(t: *Timers) void {
        _ = t.word.fetchAdd(1, .seq_cst);
        rt.io().futexWake(u32, &t.word.raw, 1);
    }

    fn less(t: *Timers, i: usize, j: usize) bool {
        return t.heap.items[i].wait.deadline < t.heap.items[j].wait.deadline;
    }

    fn swap(t: *Timers, i: usize, j: usize) void {
        const items = t.heap.items;
        std.mem.swap(*Fiber, &items[i], &items[j]);
        items[i].wait.heap_index = i;
        items[j].wait.heap_index = j;
    }

    fn up(t: *Timers, start: usize) void {
        var i = start;
        while (i > 0) {
            const parent = (i - 1) / 2;
            if (!t.less(i, parent)) return;
            t.swap(i, parent);
            i = parent;
        }
    }

    fn down(t: *Timers, start: usize) void {
        var i = start;
        const n = t.heap.items.len;
        while (true) {
            var least = i;
            const l = 2 * i + 1;
            const r = l + 1;
            if (l < n and t.less(l, least)) least = l;
            if (r < n and t.less(r, least)) least = r;
            if (least == i) return;
            t.swap(i, least);
            i = least;
        }
    }

    fn removeAt(t: *Timers, i: usize) void {
        const f = t.heap.items[i];
        const last = t.heap.items.len - 1;
        if (i != last) t.swap(i, last);
        _ = t.heap.pop();
        f.wait.heap_index = Wait.no_index;
        if (i < t.heap.items.len) {
            t.down(i);
            t.up(i);
        }
    }

    fn stop(t: *Timers) void {
        const th = t.thread orelse return;
        t.poke();
        th.join();
        t.thread = null;
        t.heap.deinit(std.heap.smp_allocator);
        t.heap = .empty;
    }
};

var timers: Timers = .{};

fn timerMain(t: *Timers) void {
    while (!stopping.load(.acquire)) {
        const seen = t.word.load(.seq_cst);
        t.lock.lock();
        const now = nowNs();
        while (t.heap.items.len > 0 and t.heap.items[0].wait.deadline <= now) {
            const f = t.heap.items[0];
            t.removeAt(0);
            _ = interrupt(f, f.wait.timer_epoch, false);
        }
        const earliest: ?i96 = if (t.heap.items.len > 0) t.heap.items[0].wait.deadline else null;
        t.lock.unlock();
        const timeout: std.Io.Timeout = if (earliest) |d| .{ .duration = .{ .raw = .fromNanoseconds(@max(d - nowNs(), 0)), .clock = .awake } } else .none;
        rt.io().futexWaitTimeout(u32, &t.word.raw, seen, timeout) catch {};
    }
}

// -----------------------------------------------------------------------------
// The blocking pool
// -----------------------------------------------------------------------------

/// Threads that run calls which block the thread they run on (reading a
/// file, say), so no worker blocks on one: a fiber that makes such a call
/// waits, and the pool thread that ran it wakes it. A pool thread is
/// started when a call finds none idle, up to `max_pool`.
const Pool = struct {
    lock: SpinLock = .{},
    head: ?*Call = null,
    tail: ?*Call = null,
    idle: u32 = 0,
    threads: std.ArrayList(std.Thread) = .empty,
    word: std.atomic.Value(u32) = .init(0),

    const max_pool = 64;

    fn submit(p: *Pool, c: *Call) void {
        p.lock.lock();
        c.next = null;
        if (p.tail) |t| t.next = c else p.head = c;
        p.tail = c;
        if (p.idle == 0 and p.threads.items.len < max_pool) {
            const th = std.Thread.spawn(.{}, poolMain, .{p}) catch rt.oom();
            p.threads.append(std.heap.smp_allocator, th) catch rt.oom();
        }
        p.lock.unlock();
        _ = p.word.fetchAdd(1, .seq_cst);
        rt.io().futexWake(u32, &p.word.raw, 1);
    }

    fn take(p: *Pool) ?*Call {
        const c = p.head orelse return null;
        p.head = c.next;
        if (p.head == null) p.tail = null;
        return c;
    }

    fn stop(p: *Pool) void {
        _ = p.word.fetchAdd(1, .seq_cst);
        rt.io().futexWake(u32, &p.word.raw, std.math.maxInt(u32));
        for (p.threads.items) |th| th.join();
        p.threads.deinit(std.heap.smp_allocator);
        p.threads = .empty;
    }
};

/// A call for the blocking pool: how to run it, and the wait it ends.
const Call = struct {
    run: *const fn (*Call) void,
    fiber: *Fiber,
    epoch: u32,
    next: ?*Call = null,
};

var pool: Pool = .{};

fn poolMain(p: *Pool) void {
    while (true) {
        const seen = p.word.load(.seq_cst);
        p.lock.lock();
        const c = p.take() orelse {
            if (stopping.load(.acquire)) {
                p.lock.unlock();
                return;
            }
            p.idle += 1;
            p.lock.unlock();
            rt.io().futexWaitUncancelable(u32, &p.word.raw, seen);
            p.lock.lock();
            p.idle -= 1;
            p.lock.unlock();
            continue;
        };
        p.lock.unlock();
        c.run(c);
        _ = interrupt(c.fiber, c.epoch, false);
    }
}

/// `f(args...)`, a call that may block its thread: on the blocking pool,
/// while the fiber making it waits, so its worker runs other fibers.
/// Outside every fiber, it runs here.
pub fn blocking(comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    const fiber = current() orelse return @call(.auto, f, args);
    const C = struct {
        call: Call,
        args: @TypeOf(args),
        result: R = undefined,

        fn run(c: *Call) void {
            const self: *@This() = @fieldParentPtr("call", c);
            self.result = @call(.auto, f, self.args);
        }
    };
    var c: C = .{ .call = .{ .run = C.run, .fiber = fiber, .epoch = beginWait(false) }, .args = args };
    pool.submit(&c.call);
    commitWait(c.call.epoch, null);
    return c.result;
}

/// Stop running until another fiber wakes this one (`wake`). `after`
/// runs on the worker once this fiber has switched away: it records the
/// fiber where the waker will find it, or queues it again when what it
/// waits for has already happened.
pub fn park(after: After) void {
    stop(after);
}

fn stop(after: After) void {
    const w = me().?;
    const f = w.current.?;
    // A fiber that stops goes back to its worker, so whoever handed it
    // over waits for its end the usual way (`Header.wait`).
    f.handoff = null;
    w.after = after;
    switchTo(&f.sp, w.sp);
}

/// Run fibers until `main`'s ends: `run(arg)` as the first fiber, on the
/// stack whose top is `top`, the one `rt.onOwnStack` mapped. `guard` is
/// that stack's guard, for the overflow handler (`rt.TaskState`). The
/// other workers start here and stop when `main` ends; `RIG_WORKERS`
/// sets how many there are, one per core by default.
pub fn runMain(arg: *anyopaque, run: *const fn (*anyopaque) callconv(.c) void, top: usize, guard: rt.StackGuard) void {
    const Main = struct {
        fiber: Fiber,
        arg: *anyopaque,
        run: *const fn (*anyopaque) callconv(.c) void,
        ended: std.atomic.Value(bool) = .init(false),

        fn start(f: *Fiber) void {
            const m: *@This() = @fieldParentPtr("fiber", f);
            m.run(m.arg);
        }

        fn end(f: *Fiber) void {
            const m: *@This() = @fieldParentPtr("fiber", f);
            m.ended.store(true, .seq_cst);
            stopping.store(true, .seq_cst);
            for (workers) |*w| wakeWorker(w);
        }
    };
    // Worker 0 runs `main` alone until its first task (`startWorkers`).
    const cap = @max(max_workers, workers_override orelse 0);
    all_workers = std.heap.smp_allocator.alloc(Worker, cap) catch rt.oom();
    for (all_workers, 0..) |*w, i| w.* = .{ .rng = @intCast(i * 2654435761 % 4294967291 + 1) };
    workers = all_workers[0..1];
    started = false;
    stopping.store(false, .seq_cst);
    var m: Main = .{ .fiber = .{ .run = Main.start, .done = Main.end }, .arg = arg, .run = run };
    m.fiber.state.stack_guard = guard;
    m.fiber.sp = initialFrame(&m.fiber, top);
    me_slot = &workers[0];
    workers[0].ring.push(&m.fiber);
    loop(&workers[0]);
    timers.stop();
    pool.stop();
    for (workers[1..]) |*w| w.thread.?.join();
    for (workers) |*w| freeStacks(w);
    std.heap.smp_allocator.free(all_workers);
    workers = &.{};
    all_workers = &.{};
    me_slot = null;
}

/// The most workers a program runs.
const max_workers = 64;
var all_workers: []Worker = &.{};
var started = false;

/// Start the other workers, when `main` makes its first task: by then
/// the runtime has the program's environment, for `RIG_WORKERS`, and a
/// program that makes none starts none.
fn startWorkers() void {
    started = true;
    const n = @min(workerCount(), all_workers.len);
    workers = all_workers[0..n];
    for (workers[1..]) |*w| w.thread = std.Thread.spawn(.{}, workerMain, .{w}) catch rt.oom();
}

fn workerCount() usize {
    if (workers_override) |n| return n;
    if (rt.process) |p| if (p.environ.getPosix("RIG_WORKERS")) |v| {
        const n = std.fmt.parseInt(usize, v, 10) catch 0;
        if (n > 0) return n;
    };
    return @max(1, std.Thread.getCpuCount() catch 1);
}

fn workerMain(w: *Worker) void {
    std.Thread.maybeAttachSignalStack();
    me_slot = w;
    loop(w);
}

/// A worker's life: run what is ready, look for more, sleep when there
/// is none, until `main` ends.
fn loop(w: *Worker) void {
    while (!stopping.load(.acquire)) {
        const f = next(w) orelse {
            if (w.searching) {
                w.searching = false;
                _ = searching.fetchSub(1, .seq_cst);
            }
            sleep(w);
            continue;
        };
        // Work found: stop searching, and if this worker was the last
        // searching, wake another to look for more.
        if (w.searching) {
            w.searching = false;
            if (searching.fetchSub(1, .seq_cst) == 1) notify();
        }
        runFiber(w, f);
    }
}

fn runFiber(w: *Worker, f: *Fiber) void {
    prepare(f);
    w.current = f;
    switchTo(&w.sp, f.sp);
    // The fiber that switched away: `f`, or one `f` handed this worker.
    const gone = w.current.?;
    w.current = null;
    if (w.after) |a| {
        w.after = null;
        a.run(gone, a.ctx);
    } else if (gone.finished) {
        if (gone.stack) |s| {
            gone.stack = null;
            releaseStack(w, s);
        }
        if (gone.done) |d| d(gone);
    }
}

/// Give a fiber that has not run yet its stack, from this worker, which
/// keeps it for the next when the fiber ends.
fn prepare(f: *Fiber) void {
    if (f.sp != 0) return;
    const s = takeStack();
    f.stack = s;
    f.state.stack_guard = .{ .lo = s.base, .hi = s.base + s.guard };
    f.sp = initialFrame(f, s.top());
}

/// The next fiber to run: the global queue's (first, one turn in 61, so
/// it is never starved), this worker's "run next" fiber, its ring's, the
/// global queue's, or one stolen.
fn next(w: *Worker) ?*Fiber {
    w.tick +%= 1;
    if (w.tick % 61 == 0) if (global.pop()) |f| return f;
    if (w.lifo) |f| {
        if (w.lifo_streak < lifo_limit) {
            w.lifo = null;
            w.lifo_streak += 1;
            return f;
        }
        // Run a fiber from the ring first, and leave this one to be
        // stolen meanwhile.
        w.lifo = null;
        w.ring.push(f);
    }
    w.lifo_streak = 0;
    if (w.ring.pop()) |f| return f;
    if (global.pop()) |f| return f;
    return search(w);
}

/// Steal half of another worker's ring, starting from a random one. At
/// most half the workers search at once; a worker that finds work, and
/// was the last searching, wakes another to look for more.
fn search(w: *Worker) ?*Fiber {
    if (workers.len < 2) return null;
    // A worker woken to look for work is counted as searching already.
    if (!w.searching) {
        if (2 * searching.load(.acquire) >= workers.len) return null;
        _ = searching.fetchAdd(1, .seq_cst);
        w.searching = true;
    }
    w.rng ^= w.rng << 13;
    w.rng ^= w.rng >> 17;
    w.rng ^= w.rng << 5;
    const start = w.rng % workers.len;
    for (0..workers.len) |k| {
        const v = &workers[(start + k) % workers.len];
        if (v == w) continue;
        if (w.ring.stealFrom(&v.ring)) |f| return f;
    }
    return global.pop();
}

/// Wake a sleeping worker when work was made and no worker is looking,
/// counting it as searching from now, so the next work made does not
/// wake another before this one has looked.
fn notify() void {
    if (searching.load(.seq_cst) != 0) return;
    if (sleepers.count.load(.seq_cst) == 0) return;
    if (sleepers.pop()) |w| {
        _ = searching.fetchAdd(1, .seq_cst);
        w.searching = true;
        wakeWorker(w);
    }
}

fn wakeWorker(w: *Worker) void {
    w.woken.store(1, .seq_cst);
    rt.io().futexWake(u32, &w.woken.raw, 1);
}

/// Sleep until woken: listed as asleep first, then, after a last look
/// for work made meanwhile, on the futex. Work a worker searching will
/// find needs no last look: only work made when none searches, which
/// woke no one (`notify`), keeps this worker up.
fn sleep(w: *Worker) void {
    w.woken.store(0, .seq_cst);
    sleepers.push(w);
    if (stopping.load(.seq_cst) or (searching.load(.seq_cst) == 0 and hasWork())) {
        if (!sleepers.remove(w)) waitWoken(w);
        return;
    }
    waitWoken(w);
}

fn waitWoken(w: *Worker) void {
    while (w.woken.load(.seq_cst) == 0) rt.io().futexWaitUncancelable(u32, &w.woken.raw, 0);
}

fn hasWork() bool {
    if (global.count.load(.seq_cst) != 0) return true;
    for (workers) |*v| if (!v.ring.isEmpty()) return true;
    return false;
}

fn freeStacks(w: *Worker) void {
    while (w.free) |n| {
        w.free = n.next;
        unmapStack(n.stack);
    }
    w.free_count = 0;
}

// -----------------------------------------------------------------------------
// Queues
// -----------------------------------------------------------------------------

/// A worker's ring of fibers ready to run. Its owner pushes at `tail`;
/// its owner and thieves take from `head`, by compare-and-swap. A thief
/// copies the fibers it would take, then claims them by moving `head`
/// past them; a slot is written again only once `head` has passed it.
const Ring = struct {
    const size = 256;
    slots: [size]std.atomic.Value(?*Fiber) = @splat(.init(null)),
    head: std.atomic.Value(u32) = .init(0),
    tail: std.atomic.Value(u32) = .init(0),

    fn isEmpty(r: *Ring) bool {
        return r.head.load(.seq_cst) == r.tail.load(.seq_cst);
    }

    /// Push `f`; when the ring is full, move half of it, and `f`, to the
    /// global queue.
    fn push(r: *Ring, f: *Fiber) void {
        while (true) {
            const t = r.tail.load(.monotonic);
            const h = r.head.load(.acquire);
            if (t -% h < size) {
                r.slots[t % size].store(f, .monotonic);
                r.tail.store(t +% 1, .seq_cst);
                return;
            }
            // Full: claim the older half, then hand it over.
            const half = size / 2;
            if (r.head.cmpxchgWeak(h, h +% half, .acq_rel, .monotonic) != null) continue;
            var batch: ?*Fiber = f;
            f.next = null;
            var i: u32 = 0;
            while (i < half) : (i += 1) {
                const g = r.slots[(h +% i) % size].load(.monotonic).?;
                g.next = batch;
                batch = g;
            }
            global.pushList(batch.?, half + 1);
            return;
        }
    }

    fn pop(r: *Ring) ?*Fiber {
        while (true) {
            const h = r.head.load(.acquire);
            const t = r.tail.load(.monotonic);
            if (h == t) return null;
            const f = r.slots[h % size].load(.monotonic);
            if (r.head.cmpxchgWeak(h, h +% 1, .acq_rel, .monotonic) == null) return f;
        }
    }

    /// Take half of `victim`'s ring, rounded up, into this one (empty, its
    /// owner's), and give the first to run.
    fn stealFrom(r: *Ring, victim: *Ring) ?*Fiber {
        var buf: [size / 2 + 1]*Fiber = undefined;
        while (true) {
            const h = victim.head.load(.acquire);
            const t = victim.tail.load(.acquire);
            const avail = t -% h;
            if (avail == 0 or avail > size) return null;
            const n = avail - avail / 2;
            for (0..n) |i| buf[i] = victim.slots[(h +% @as(u32, @intCast(i))) % size].load(.monotonic) orelse return null;
            if (victim.head.cmpxchgWeak(h, h +% n, .acq_rel, .monotonic) != null) continue;
            for (buf[1..n]) |g| r.push(g);
            return buf[0];
        }
    }
};

/// The global queue: fibers made outside the workers, and the overflow
/// of full rings. A spin lock guards it; `count` lets a worker see it is
/// empty without taking the lock.
const Global = struct {
    lock: SpinLock = .{},
    head: ?*Fiber = null,
    tail: ?*Fiber = null,
    count: std.atomic.Value(u32) = .init(0),

    fn push(g: *Global, f: *Fiber) void {
        f.next = null;
        g.pushList(f, 1);
    }

    /// Append `list`, `n` fibers linked through `next`.
    fn pushList(g: *Global, list: *Fiber, n: u32) void {
        var last = list;
        while (last.next) |x| last = x;
        g.lock.lock();
        defer g.lock.unlock();
        if (g.tail) |t| t.next = list else g.head = list;
        g.tail = last;
        _ = g.count.fetchAdd(n, .seq_cst);
    }

    fn pop(g: *Global) ?*Fiber {
        if (g.count.load(.acquire) == 0) return null;
        g.lock.lock();
        defer g.lock.unlock();
        const f = g.head orelse return null;
        g.head = f.next;
        if (g.head == null) g.tail = null;
        _ = g.count.fetchSub(1, .seq_cst);
        return f;
    }
};

/// The workers asleep, a stack a spin lock guards.
const Sleepers = struct {
    lock: SpinLock = .{},
    top: ?*Worker = null,
    count: std.atomic.Value(u32) = .init(0),

    fn push(s: *Sleepers, w: *Worker) void {
        s.lock.lock();
        defer s.lock.unlock();
        w.next_sleeper = s.top;
        s.top = w;
        _ = s.count.fetchAdd(1, .seq_cst);
    }

    fn pop(s: *Sleepers) ?*Worker {
        s.lock.lock();
        defer s.lock.unlock();
        const w = s.top orelse return null;
        s.top = w.next_sleeper;
        _ = s.count.fetchSub(1, .seq_cst);
        return w;
    }

    /// Take `w` off the list; false when a waker took it first.
    fn remove(s: *Sleepers, w: *Worker) bool {
        s.lock.lock();
        defer s.lock.unlock();
        var at = &s.top;
        while (at.*) |x| : (at = &x.next_sleeper) {
            if (x == w) {
                at.* = x.next_sleeper;
                _ = s.count.fetchSub(1, .seq_cst);
                return true;
            }
        }
        return false;
    }
};

const SpinLock = struct {
    held: std.atomic.Value(bool) = .init(false),

    fn lock(l: *SpinLock) void {
        while (l.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    fn unlock(l: *SpinLock) void {
        l.held.store(false, .release);
    }
};

// -----------------------------------------------------------------------------
// Tasks
// -----------------------------------------------------------------------------

/// What a task's waiter shares with the fiber that runs it: whether the
/// task has ended, the fiber waiting for it and the epoch of that wait,
/// and how to free the record. The end is published by the worker the
/// fiber left for good (`end`), so the record is never freed while the
/// fiber still runs, and the waiter goes on only once the status says
/// `ended`, after the waker is done with it.
pub const Header = struct {
    fiber: Fiber,
    status: std.atomic.Value(u8) = .init(running),
    waiter: std.atomic.Value(?*Fiber) = .init(null),
    waiter_epoch: std.atomic.Value(u32) = .init(0),
    destroy: *const fn (*Header) void,

    const running = 0;
    const waited = 1;
    const ending = 2;
    const ended = 3;

    fn end(f: *Fiber) void {
        const h: *Header = @fieldParentPtr("fiber", f);
        if (h.status.swap(ending, .seq_cst) == waited) {
            _ = interrupt(h.waiter.load(.seq_cst).?, h.waiter_epoch.load(.seq_cst), false);
        }
        h.status.store(ended, .seq_cst);
    }

    /// Whether the task has ended; while its end is being published,
    /// wait for that to finish.
    fn isEnded(h: *Header) bool {
        while (true) {
            const s = h.status.load(.seq_cst);
            if (s == ended) return true;
            if (s != ending) return false;
            std.atomic.spinLoopHint();
        }
    }

    /// Wait for the task to end, or, when `cancel` is given, for that
    /// flag to be set first, when this gives false.
    fn waitEnd(h: *Header, cancel: ?*const std.atomic.Value(bool)) bool {
        if (!h.isEnded()) {
            const w = me().?;
            // Not started, and next on this worker: run it now. A fiber in
            // the "run next" slot may also be one woken partway, which
            // goes on where it stopped instead.
            if (w.lifo == &h.fiber and h.fiber.sp == 0) handoff(w, h, cancel != null);
        }
        while (!h.isEnded()) {
            if (cancel) |c| if (c.load(.seq_cst)) return false;
            const e = beginWait(cancel != null);
            h.waiter.store(current().?, .seq_cst);
            h.waiter_epoch.store(e, .seq_cst);
            if (h.status.cmpxchgStrong(running, waited, .seq_cst, .seq_cst)) |s| {
                if (s != waited) continue;
            }
            if (cancel) |c| if (c.load(.seq_cst)) return false;
            commitWait(e, null);
        }
        return true;
    }
};

/// A task's record: its header and, once it has ended, its result.
pub fn Job(comptime T: type) type {
    return struct {
        header: Header,
        result: T = undefined,

        const Self = @This();

        /// Wait for the task to end and give its result. Waiting again
        /// gives the same result; the owner takes it once (`Task`).
        pub fn join(self: *Self) T {
            _ = self.header.waitEnd(null);
            return self.result;
        }

        /// Wait for the task to end, unless the flag `cancel` is set
        /// first: whether it has ended.
        pub fn waitEnd(self: *Self, cancel: ?*const std.atomic.Value(bool)) bool {
            return self.header.waitEnd(cancel);
        }

        pub fn free(self: *Self) void {
            self.header.destroy(&self.header);
        }
    };
}

/// Hand this worker to the task of `h`, which has not started and is
/// next on it (its "run next" slot, which only this worker takes): switch
/// straight to it, on its own stack, and straight back when it ends,
/// past the queues. The fiber waiting sleeps as it hands its worker over,
/// recorded as the task's waiter, so a task that stops on the way ends
/// the usual way and wakes it.
fn handoff(w: *Worker, h: *Header, cancelable: bool) void {
    const waiter = w.current.?;
    const f = &h.fiber;
    w.lifo = null;
    const e = beginWait(cancelable);
    h.waiter.store(waiter, .seq_cst);
    h.waiter_epoch.store(e, .seq_cst);
    h.status.store(Header.waited, .seq_cst);
    // The waiter is marked asleep by the task, once this switch has saved
    // it (`fiberMain`), so no waker queues it while it still runs.
    f.handoff = waiter;
    f.handoff_epoch = e;
    prepare(f);
    w.current = f;
    switchTo(&waiter.sp, f.sp);
    // Back: the task ended straight back here, or stopped and later ended
    // the usual way, or a cancel woke this fiber first.
    const now = me().?;
    if (now.returned) |done| {
        now.returned = null;
        if (done.stack) |s| {
            done.stack = null;
            releaseStack(now, s);
        }
        h.status.store(Header.ended, .seq_cst);
    }
}

/// Start `f(args...)` as a fiber, ready to run, and give its record,
/// and an `Extra` the record holds for the caller (`tasks.zig` keeps a
/// task's `Control` there), which `f` gets first.
pub fn spawn(comptime T: type, comptime Extra: type, comptime f: anytype, args: anytype) Spawned(T, Extra) {
    const Args = @TypeOf(args);
    const Full = struct {
        job: Job(T),
        extra: Extra = .{},
        args: Args,

        fn start(fiber: *Fiber) void {
            const h: *Header = @fieldParentPtr("fiber", fiber);
            const j: *Job(T) = @fieldParentPtr("header", h);
            const full: *@This() = @fieldParentPtr("job", j);
            j.result = @call(.auto, f, .{&full.extra} ++ full.args);
        }

        fn destroy(h: *Header) void {
            const j: *Job(T) = @fieldParentPtr("header", h);
            const full: *@This() = @fieldParentPtr("job", j);
            std.heap.smp_allocator.destroy(full);
        }
    };
    if (!started) startWorkers();
    const full = std.heap.smp_allocator.create(Full) catch rt.oom();
    full.* = .{ .job = .{ .header = .{ .fiber = .{ .run = Full.start, .done = Header.end }, .destroy = Full.destroy } }, .args = args };
    // An `Extra` that names its task's fiber is given it, for a cancel to
    // reach the fiber's wait (`interruptForCancel`).
    if (@hasField(Extra, "fiber")) full.extra.fiber = &full.job.header.fiber;
    wake(&full.job.header.fiber);
    return .{ .job = &full.job, .extra = &full.extra };
}

/// What `spawn` gives: the task's record, and the `Extra` in it.
pub fn Spawned(comptime T: type, comptime Extra: type) type {
    return struct { job: *Job(T), extra: *Extra };
}

// -----------------------------------------------------------------------------
// Stacks
// -----------------------------------------------------------------------------

/// A fiber's stack: `guard` bytes of inaccessible address space at
/// `base`, then the stack, then one inaccessible page, as
/// `rt.onTaskStack` maps a task's.
pub const Stack = struct {
    base: usize,
    guard: usize,
    len: usize,

    fn top(s: Stack) usize {
        return s.base + s.guard + s.len - rt.unwind_headroom;
    }
};

/// A free stack's link in its worker's list, kept in the stack itself, at
/// the bottom of its usable part.
const FreeStack = struct { stack: Stack, next: ?*FreeStack };

/// How many stacks a worker keeps free; one more is returned to the
/// system, with what its fiber touched.
const keep_free = 64;

/// How many stacks one reservation of address space holds.
const chunk = 16;

/// A stack to run a fiber on: one a fiber that ended on this worker
/// left, or one of a new reservation, whose others it keeps free.
fn takeStack() Stack {
    const w = me();
    if (w) |x| if (x.free) |n| {
        x.free = n.next;
        x.free_count -= 1;
        return n.stack;
    };
    const guard = rt.task_guard;
    const len = rt.task_stack_size;
    const span = guard + len + std.heap.pageSize();
    const count: usize = if (w != null) chunk else 1;
    const got = std.posix.mmap(null, span * count, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch rt.oom();
    const base = @intFromPtr(got.ptr);
    for (0..count) |i| {
        const b = base + i * span;
        if (std.posix.errno(std.posix.system.mprotect(@ptrFromInt(b + guard), len, .{ .READ = true, .WRITE = true })) != .SUCCESS) rt.oom();
        if (i > 0) releaseStack(w.?, .{ .base = b, .guard = guard, .len = len });
    }
    return .{ .base = base, .guard = guard, .len = len };
}

/// Keep a stack a fiber has finished with, for the next on `w`, or
/// return it to the system when `w` keeps enough.
fn releaseStack(w: *Worker, s: Stack) void {
    if (w.free_count >= keep_free) return unmapStack(s);
    const n: *FreeStack = @ptrFromInt(s.base + s.guard);
    n.* = .{ .stack = s, .next = w.free };
    w.free = n;
    w.free_count += 1;
}

fn unmapStack(s: Stack) void {
    std.posix.munmap(@as([*]align(std.heap.page_size_min) u8, @ptrFromInt(s.base))[0 .. s.guard + s.len + std.heap.pageSize()]);
}

// -----------------------------------------------------------------------------
// Switching
// -----------------------------------------------------------------------------

/// The registers a call keeps, saved on the stack being left: on aarch64
/// x19..x30 and d8..d15, 160 bytes; on x86_64 rbx, rbp and r12..r15
/// under the return address.
const saved_bytes = switch (builtin.target.cpu.arch) {
    .aarch64 => 160,
    .x86_64 => 7 * 8,
    else => @compileError("rig: the scheduler runs on aarch64 and x86_64"),
};

/// Save the registers a call keeps on the stack running, store its
/// stack pointer in `from`, and resume the stack at `to`: the fiber or
/// the worker that saved it there, which returns from its own
/// `switchTo` (or, new, starts at `fiberStartNaked`). An x86_64
/// instruction that writes memory names its size (`movq`), as Zig's own
/// x86_64 assembler, which builds debug code, requires.
fn switchNaked() callconv(.naked) void {
    switch (builtin.target.cpu.arch) {
        .aarch64 => asm volatile (
            \\ sub sp, sp, #160
            \\ stp x19, x20, [sp, #0]
            \\ stp x21, x22, [sp, #16]
            \\ stp x23, x24, [sp, #32]
            \\ stp x25, x26, [sp, #48]
            \\ stp x27, x28, [sp, #64]
            \\ stp x29, x30, [sp, #80]
            \\ stp d8, d9, [sp, #96]
            \\ stp d10, d11, [sp, #112]
            \\ stp d12, d13, [sp, #128]
            \\ stp d14, d15, [sp, #144]
            \\ mov x2, sp
            \\ str x2, [x0]
            \\ mov sp, x1
            \\ ldp x19, x20, [sp, #0]
            \\ ldp x21, x22, [sp, #16]
            \\ ldp x23, x24, [sp, #32]
            \\ ldp x25, x26, [sp, #48]
            \\ ldp x27, x28, [sp, #64]
            \\ ldp x29, x30, [sp, #80]
            \\ ldp d8, d9, [sp, #96]
            \\ ldp d10, d11, [sp, #112]
            \\ ldp d12, d13, [sp, #128]
            \\ ldp d14, d15, [sp, #144]
            \\ add sp, sp, #160
            \\ ret
        ),
        .x86_64 => asm volatile (
            \\ push %%rbp
            \\ push %%rbx
            \\ push %%r12
            \\ push %%r13
            \\ push %%r14
            \\ push %%r15
            \\ movq %%rsp, (%%rdi)
            \\ mov %%rsi, %%rsp
            \\ pop %%r15
            \\ pop %%r14
            \\ pop %%r13
            \\ pop %%r12
            \\ pop %%rbx
            \\ pop %%rbp
            \\ ret
        ),
        else => unreachable,
    }
}

/// Where a new fiber's first switch lands: the registers its frame was
/// made with hold the fiber (x19, rbx) and `fiberMain` (x20, r12).
fn fiberStartNaked() callconv(.naked) void {
    switch (builtin.target.cpu.arch) {
        .aarch64 => asm volatile (
            \\ mov x0, x19
            \\ blr x20
            \\ brk #0
        ),
        .x86_64 => asm volatile (
            \\ mov %%rbx, %%rdi
            \\ andq $-16, %%rsp
            \\ call *%%r12
            \\ ud2
        ),
        else => unreachable,
    }
}

const SwitchFn = *const fn (from: *usize, to: usize) callconv(.c) void;

/// `switchNaked` as a function to call. The empty `asm` hides which
/// function the pointer names, so no optimizer inlines the naked body,
/// which takes its arguments in registers only a call sets.
fn switchTo(from: *usize, to: usize) void {
    var f: SwitchFn = @ptrCast(&switchNaked);
    asm volatile (""
        : [f] "+r" (f),
    );
    f(from, to);
}

/// A fiber's body: its `run`, then back to its worker for good, which
/// publishes its end (`runFiber`).
fn fiberMain(f: *Fiber) callconv(.c) noreturn {
    // Handed a worker: the fiber that handed it over has switched away, so
    // mark it asleep; when a cancel woke it first, queue it, and end the
    // usual way.
    if (f.handoff) |back| {
        const e = f.handoff_epoch;
        const about = back.wait.word.load(.seq_cst);
        const asleep_now = Wait.epochOf(about) == e and about & Wait.states == Wait.about and
            back.wait.word.cmpxchgStrong(about, (about & ~Wait.states) | Wait.asleep, .seq_cst, .seq_cst) == null;
        if (!asleep_now) {
            f.handoff = null;
            wake(back);
        }
    }
    f.run(f);
    f.finished = true;
    const w = me().?;
    // Handed over and never stopped: straight back to the fiber that
    // handed it over, which finishes it (`handoff`), unless a cancel has
    // woken that fiber already, when this one ends the usual way.
    if (f.handoff) |back| {
        f.handoff = null;
        if (claim(back, f.handoff_epoch)) {
            w.returned = f;
            w.current = back;
            switchTo(&f.sp, back.sp);
            unreachable;
        }
    }
    switchTo(&f.sp, w.sp);
    unreachable;
}

/// The stack pointer a new fiber starts from, below `top`: a frame of
/// saved registers whose return address is `fiberStartNaked`.
fn initialFrame(f: *Fiber, top: usize) usize {
    const sp = (top & ~@as(usize, 15)) - saved_bytes;
    const slots: [*]usize = @ptrFromInt(sp);
    @memset(slots[0 .. saved_bytes / 8], 0);
    switch (builtin.target.cpu.arch) {
        .aarch64 => {
            slots[0] = @intFromPtr(f); // x19
            slots[1] = @intFromPtr(&fiberMain); // x20
            slots[11] = @intFromPtr(&fiberStartNaked); // x30
        },
        .x86_64 => {
            slots[3] = @intFromPtr(&fiberMain); // r12
            slots[4] = @intFromPtr(f); // rbx
            slots[6] = @intFromPtr(&fiberStartNaked); // the return address
        },
        else => unreachable,
    }
    return sp;
}

test "fibers switch, yield to each other in turn, and finish" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var log: [8]u8 = undefined;
        var n: usize = 0;
        fn note(c: u8) void {
            log[n] = c;
            n += 1;
        }
        fn a(_: *Fiber) void {
            note('a');
            yield();
            note('c');
        }
        fn b(_: *Fiber) void {
            note('b');
            yield();
            note('d');
        }
        fn first(_: *anyopaque) callconv(.c) void {
            var fa: Fiber = .{ .run = a };
            var fb: Fiber = .{ .run = b };
            const sa = takeStack();
            const sb = takeStack();
            fa.sp = initialFrame(&fa, sa.top());
            fb.sp = initialFrame(&fb, sb.top());
            fa.stack = sa;
            fb.stack = sb;
            wake(&fa);
            wake(&fb);
            while (!fa.finished or !fb.finished) yield();
            note('e');
        }
    };
    workers_override = 1;
    defer workers_override = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    // Each fiber's steps happen in order, the two fibers take turns, and
    // `main`, waiting for both, finishes last.
    const log = Run.log[0..Run.n];
    try std.testing.expectEqual(@as(usize, 5), log.len);
    const at = struct {
        fn of(l: []const u8, c: u8) usize {
            return std.mem.indexOfScalar(u8, l, c).?;
        }
    }.of;
    try std.testing.expect(at(log, 'a') < at(log, 'c') and at(log, 'b') < at(log, 'd'));
    try std.testing.expect(at(log, 'c') > at(log, 'b') and at(log, 'd') > at(log, 'a'));
    try std.testing.expectEqual(@as(u8, 'e'), log[4]);
}

test "many workers run many fibers, each waited for, and their results add up" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var sum: u64 = 0;
        const Unit = struct {};
        fn leaf(_: *Unit, i: u64) u64 {
            if (i % 7 == 0) yield();
            return i;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            var jobs: [2000]*Job(u64) = undefined;
            for (0..50) |_| {
                for (&jobs, 0..) |*j, i| j.* = spawn(u64, Unit, leaf, .{@as(u64, i)}).job;
                for (jobs) |j| {
                    sum += j.join();
                    j.free();
                }
            }
        }
    };
    workers_override = 4;
    defer workers_override = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expectEqual(@as(u64, 50 * (1999 * 2000 / 2)), Run.sum);
}

test "a task waited for as soon as it is made runs by handoff, and one that stops on the way still ends" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var sum: u64 = 0;
        const Unit = struct {};
        fn leaf(_: *Unit, i: u64) u64 {
            if (i % 3 == 0) yield();
            return i;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            for (0..20000) |i| {
                const j = spawn(u64, Unit, leaf, .{@as(u64, i)}).job;
                sum += j.join();
                j.free();
            }
        }
    };
    workers_override = 4;
    defer workers_override = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expectEqual(@as(u64, 19999 * 20000 / 2), Run.sum);
}
