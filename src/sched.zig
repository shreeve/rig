//! The scheduler: Rig's tasks run as fibers, each on a stack of its own,
//! switched by saving and restoring the registers a call keeps
//! (`switchTo`), not by the operating system. One worker thread per core
//! runs them; the thread that runs `main` is worker 0, and `main` is the
//! first fiber (`runMain`). Every program that makes tasks runs on it;
//! `bin/rig` writes this file beside the runtime as `rig/sched.zig`.
//!
//! Each worker owns a ring of fibers ready to run, which it takes from in
//! order; a worker with none takes from the global queue, or steals half
//! of another's ring. A worker with nothing to do sleeps until woken, and
//! work made where no worker searches for it wakes one, which wakes
//! another if it finds more. A fiber that stops (to yield, or to wait) is
//! queued, or recorded as waiting, only once it has switched away, by
//! the worker it left (`After`), so no other worker resumes it while its
//! registers are still being saved.
//!
//! A program started with `RIG_SEED` set runs deterministically instead
//! (`deterministic`): on one thread, with a virtual clock, and with the
//! seed choosing which ready fiber runs next.

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
    /// What it waits on while it blocks (`block`), for a deadlock's walk.
    blocked: std.atomic.Value(?*const Blocked) = .init(null),
    /// The actors it runs a method of, newest first (`Held`).
    held: ?*Held = null,
    /// Waits that end at once it may still make before it yields
    /// (`spendBudget`), so a socket that is always ready cannot keep it
    /// on its worker.
    budget: u8 = budget_size,
    /// The worker it runs on and no other, once pinned (`pinHere`): a
    /// local task, and the task that made one. It waits in that worker's
    /// `pinned` queue, never in a ring or the global queue, so no other
    /// worker takes it.
    home: ?*Worker = null,
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
    /// Blocks to reuse (`takeBlock`).
    blocks: ?*FreeBlock = null,
    block_count: u32 = 0,
    /// A fiber handed this worker that ended and switched straight back
    /// to the fiber that handed it over, which finishes it (`handoff`).
    returned: ?*Fiber = null,
    /// Turns since it last looked at the global queue first.
    tick: u32 = 0,
    /// 1 once woken from its sleep, in its poller (`sleep`).
    woken: std.atomic.Value(u32) = .init(0),
    /// The kernel's queue of events it sleeps in (`Poller`), and the
    /// fibers whose waits have a deadline it set (`Timers`).
    poller: Poller = .{},
    timers: Timers = .{},
    /// Its pinned fibers that are ready (`Fiber.home`), which only it runs;
    /// other workers and threads add to it.
    pinned: Global = .{},
    /// 1 while it sleeps, so a thread that adds to `pinned` kicks its
    /// poller.
    idle: std.atomic.Value(u32) = .init(0),
    /// When its sleep in its poller ends: the earliest deadline any
    /// worker held as it went to sleep, `no_due` for none, or `awake`.
    /// A timer set earlier kicks it (`kickForTimer`).
    sleep_due: std.atomic.Value(i64) = .init(awake),
    /// When its yield checks last looked at its poller (`serviceBusy`).
    polled_at: i96 = 0,
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
/// Set when work is made while every worker is busy; the first yield
/// check to see it clears it and takes that work (`claimWaiting`), and
/// a worker that finds no work and sleeps clears it too. A recursive
/// call only reads it (`rt.tickCall`), on a cache line of its own, so
/// what the scheduler writes beside it never slows those reads.
pub var waiting: Flag = .{};

const Flag = extern struct {
    value: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
    _: [std.atomic.cache_line - 4]u8 = undefined,

    pub fn load(f: *const Flag, comptime order: std.builtin.AtomicOrder) u32 {
        return f.value.load(order);
    }
    fn store(f: *Flag, v: u32, comptime order: std.builtin.AtomicOrder) void {
        f.value.store(v, order);
    }
    fn swap(f: *Flag, v: u32, comptime order: std.builtin.AtomicOrder) u32 {
        return f.value.swap(v, order);
    }
};

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
    if (deterministic) return ready.append(std.heap.smp_allocator, f) catch rt.oom();
    const here = me();
    if (f.home) |home| if (home != here) return wakeHome(f, home);
    const w = here orelse {
        global.push(f);
        return notifyNew();
    };
    const before = w.lifo;
    w.lifo = f;
    if (before) |b| {
        if (b.home != null) return w.pinned.push(b);
        w.ring.push(b);
        notifyNew();
    }
}

/// Make `f` ready to run after the fibers already ready on this worker.
fn wakeLast(f: *Fiber) void {
    if (deterministic) return wake(f);
    if (f.home) |home| return wakeHome(f, home);
    if (me()) |w| w.ring.push(f) else global.push(f);
    notify();
}

/// Queue the pinned fiber `f` on its worker, and wake that worker if it
/// sleeps: it looks at its queue after it marks itself idle, and before
/// it sleeps in its poller (`sleep`).
fn wakeHome(f: *Fiber, home: *Worker) void {
    home.pinned.push(f);
    if (home != me() and home.idle.load(.seq_cst) != 0) home.poller.kick();
}

/// Pin the running fiber to its worker, and give the worker to pin a
/// task it makes to (`spawn`): what makes a task local. A local task
/// shares handles whose counts are not atomic with the task that made it,
/// so both stay on one thread from then on.
pub fn pinHere() ?*Worker {
    if (deterministic) return null;
    const w = me() orelse return null;
    w.current.?.home = w;
    return w;
}

/// Let other fibers run, then go on.
pub fn yield() void {
    stop(.{ .run = requeue });
}

fn requeue(f: *Fiber, _: ?*anyopaque) void {
    wakeLast(f);
}

/// A yield check of a loop (`rt.turn`): yield when other work waits
/// for this worker, in its "run next" slot or ring, or in the global
/// queue, or take work that waits for a busy one (`claimWaiting`). Work
/// a sleeping or searching worker can take is left to it.
pub noinline fn tick() void {
    const w = me() orelse return;
    // Deterministic: computing costs virtual time, and the seed decides
    // whether to yield to ready work.
    if (deterministic) {
        computed();
        if (ready.items.len > 0 and random(2) == 0) yield();
        return;
    }
    serviceBusy(w);
    if (hasOwnWork(w)) return yield();
    if (waiting.load(.monotonic) != 0) claimWaiting(w);
}

/// How often at most a busy worker's yield checks look at its poller: a
/// look is a system call, and a descriptor's readiness waits this long
/// at worst while every worker computes.
const poll_interval: i96 = 250 * std.time.ns_per_us;

/// A yield check of the busy worker `w`: wake the fibers whose timers are
/// due on it, and those its poller's events make ready, looking at the
/// poller at most every `poll_interval`. It reads the clock only when
/// `w` holds a timer or a descriptor, so a loop that holds neither pays
/// two loads.
fn serviceBusy(w: *Worker) void {
    const due = w.timers.due.load(.monotonic);
    const polls = w.poller.count.load(.monotonic) != 0;
    if (due == no_due and !polls) return;
    const now = nowNs();
    if (due <= now) _ = w.timers.fire(now);
    if (polls and now - w.polled_at >= poll_interval) {
        w.polled_at = now;
        _ = w.poller.poll(0);
    }
}

/// A recursive call that saw `waiting` set (`rt.tickCall`).
pub noinline fn tickCall() void {
    @branchHint(.cold);
    const w = me() orelse return;
    claimWaiting(w);
}

/// Clear `waiting`, if no other check has, and yield to the work that
/// waits: this worker's own, or half of another's ring, stolen as a
/// searching worker would.
fn claimWaiting(w: *Worker) void {
    if (waiting.swap(0, .monotonic) == 0) return;
    if (hasOwnWork(w)) return yield();
    if (workers.len < 2) return;
    for (workers) |*v| {
        if (v == w) continue;
        if (w.ring.stealFrom(&v.ring)) |f| {
            w.ring.push(f);
            return yield();
        }
    }
}

fn hasOwnWork(w: *Worker) bool {
    return w.lifo != null or !w.ring.isEmpty() or w.pinned.count.load(.seq_cst) != 0 or global.count.load(.monotonic) != 0;
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
    /// The worker's timers that hold its deadline, while they do.
    timers: ?*Timers = null,

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
    if (deadline != null) if (f.wait.timers) |t| t.cancel(f);
}

/// Once the fiber has switched away: set its timer, then mark it asleep,
/// unless a waker has come first, when it goes on.
fn fallAsleep(f: *Fiber, timed: ?*anyopaque) void {
    if (timed != null) (if (deterministic) &timers else &me().?.timers).add(f);
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
    if (deterministic) return virtual_now;
    return std.Io.Timestamp.now(rt.io(), .awake).nanoseconds;
}

// -----------------------------------------------------------------------------
// The deterministic mode
// -----------------------------------------------------------------------------

/// Whether the program runs deterministically: started with `RIG_SEED`
/// set (`rt.start`, `seed`), as `rig test` starts one. It then runs on
/// one thread, every blocking call in place; the monotonic clock is
/// virtual, starting at 0 and jumping to the earliest timer whenever no
/// fiber is ready (`advanceClock`); and the seed picks which ready fiber
/// runs next and whether a yield check yields (`random`). So a run with
/// the same seed makes the same choices, and a sleep takes no time. Each
/// yield check and `task.check()` moves the clock 1 µs (`computed`), so
/// a computation that never waits reaches its deadline too.
pub var deterministic = false;
/// The seed it runs with.
pub var seed_value: u64 = 0;
var rng_state: u64 = 1;
/// The virtual monotonic clock, in nanoseconds.
var virtual_now: i96 = 0;
/// The fibers ready to run, in place of the workers' rings.
var ready: std.ArrayList(*Fiber) = .empty;

/// Run deterministically with seed `s` (`deterministic`).
pub fn seed(s: u64) void {
    deterministic = true;
    seed_value = s;
    // splitmix64 of the seed, so nearby seeds start far apart, and
    // never 0, which xorshift would keep.
    var z = s +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    rng_state = (z ^ (z >> 31)) | 1;
}

/// A number below `n` from the seeded generator (xorshift64*).
fn random(n: usize) usize {
    rng_state ^= rng_state >> 12;
    rng_state ^= rng_state << 25;
    rng_state ^= rng_state >> 27;
    return @intCast((rng_state *% 0x2545f4914f6cdd1d) % n);
}

/// What a yield check or `task.check()` costs on the virtual clock: so
/// a computation that never waits still reaches its deadline.
const check_cost: i96 = 1_000;

/// A yield check or `task.check()` ran: move the virtual clock on.
pub fn computed() void {
    virtual_now += check_cost;
}

/// Move the virtual clock forward to `t`, never back: a program that
/// makes no tasks sleeps so (`rt.taskSleep`).
pub fn advanceTo(t: i96) void {
    if (t > virtual_now) virtual_now = t;
}

/// No fiber is ready: move the virtual clock to the earliest timer and
/// wake each fiber whose deadline that reaches. With no timer either,
/// every task waits on another, and none can ever run: a deadlock.
/// A fiber waiting on a file descriptor wakes once it is ready, at
/// whatever time: the poller is looked at first, without waiting, and
/// waited on when nothing else can end a wait.
fn advanceClock() void {
    const p = &workers[0].poller;
    if (p.count.load(.monotonic) != 0 and p.poll(0)) return;
    const due = timers.due.load(.acquire);
    if (due == no_due) {
        if (p.count.load(.monotonic) != 0) {
            _ = p.poll(null);
            return;
        }
        @panic("every task is waiting on another, and none can run: a deadlock");
    }
    advanceTo(due);
    fireDue();
}

/// Wake each fiber whose deadline the virtual clock has reached: the
/// clock also moves while fibers compute (`computed`).
fn fireDue() void {
    _ = timers.fire(virtual_now);
}

// -----------------------------------------------------------------------------
// Timers
// -----------------------------------------------------------------------------

/// The fibers waiting with a deadline that one worker set, earliest
/// first, as Go keeps one heap per processor: the worker wakes them when
/// it looks (`service`, and its yield checks, `serviceBusy`), and a
/// worker about to sleep wakes those due on any (`serviceAll`), and
/// sleeps no longer than until the earliest (`earliestDue`); a deadline
/// earlier than a sleeping worker's wakes it (`kickForTimer`). Its lock is held while it wakes one, so a fiber that
/// takes its timer back (`cancel`) knows no worker is done with it. In a
/// deterministic run one set serves the virtual clock (`timers`).
const Timers = struct {
    lock: SpinLock = .{},
    heap: std.ArrayList(*Fiber) = .empty,
    /// Its earliest deadline, which workers read without the lock, or
    /// `no_due`.
    due: std.atomic.Value(i64) = .init(no_due),

    fn add(t: *Timers, f: *Fiber) void {
        t.lock.lock();
        defer t.lock.unlock();
        t.heap.append(std.heap.smp_allocator, f) catch rt.oom();
        f.wait.heap_index = t.heap.items.len - 1;
        f.wait.timers = t;
        t.up(f.wait.heap_index);
        t.publish();
        // The earliest it holds: a worker asleep until later wakes for it.
        if (f.wait.heap_index == 0 and !deterministic) kickForTimer(t.due.load(.monotonic));
    }

    fn cancel(t: *Timers, f: *Fiber) void {
        t.lock.lock();
        defer t.lock.unlock();
        if (f.wait.heap_index != Wait.no_index) t.removeAt(f.wait.heap_index);
        f.wait.timers = null;
        t.publish();
    }

    /// Wake each fiber whose deadline `now` has reached; whether any.
    fn fire(t: *Timers, now: i96) bool {
        if (t.due.load(.acquire) > now) return false;
        t.lock.lock();
        defer t.lock.unlock();
        var any = false;
        while (t.heap.items.len > 0 and t.heap.items[0].wait.deadline <= now) {
            const f = t.heap.items[0];
            t.removeAt(0);
            _ = interrupt(f, f.wait.timer_epoch, false);
            any = true;
        }
        t.publish();
        return any;
    }

    fn publish(t: *Timers) void {
        const d: i64 = if (t.heap.items.len > 0) @intCast(@min(t.heap.items[0].wait.deadline, no_due)) else no_due;
        t.due.store(d, .seq_cst);
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

    fn clear(t: *Timers) void {
        t.heap.deinit(std.heap.smp_allocator);
        t.heap = .empty;
        t.due.store(no_due, .release);
    }
};

/// No deadline.
const no_due = std.math.maxInt(i64);

/// The timers of a deterministic run.
var timers: Timers = .{};

/// A worker's `sleep_due` while it is not asleep.
const awake = std.math.minInt(i64);

/// The earliest deadline any worker holds, or `no_due`: when a worker
/// about to sleep wakes up.
fn earliestDue() i64 {
    var due: i64 = no_due;
    for (workers) |*v| due = @min(due, v.timers.due.load(.seq_cst));
    return due;
}

/// A timer due at `due` was set, the earliest its worker holds: unless a
/// worker asleep wakes by then, kick one, which sleeps again until the
/// earliest deadline. A worker about to sleep notes that it may sleep
/// for good before it reads the deadlines (`sleep`), and the timer's
/// worker publishes the deadline before it reads those notes, all
/// sequentially consistent: so either the sleeper sees the deadline, or
/// this sees the sleeper.
fn kickForTimer(due: i64) void {
    var late: ?*Worker = null;
    for (workers) |*v| {
        const until = v.sleep_due.load(.seq_cst);
        if (until == awake) continue;
        if (until <= due) return;
        if (late == null) late = v;
    }
    if (late) |v| v.poller.kick();
}

// -----------------------------------------------------------------------------
// The poller
// -----------------------------------------------------------------------------

/// A worker's queue of kernel events, kqueue on macOS and epoll on Linux:
/// it sleeps in it (`sleep`), and the file descriptors registered with it
/// (`Registration`) wake the fibers waiting on them when they are ready.
/// A worker that sleeps in it holds its lock, so no other polls it, and a
/// registration is never freed while its events are handled (`close`);
/// a worker that runs fibers polls it every 61 turns, and its yield
/// checks every `poll_interval` (`serviceBusy`), and a worker about to
/// sleep polls the others' (`serviceAll`), so a busy worker's
/// descriptors wait no longer than its next turns.
const Poller = struct {
    fd: i32 = -1,
    /// Linux: the eventfd that wakes it (`kick`).
    kick_fd: i32 = -1,
    lock: SpinLock = .{},
    /// How many descriptors are registered with it.
    count: std.atomic.Value(u32) = .init(0),
    /// Removers waiting for the lock (`remove`): a worker does not block
    /// in the poller again while one waits, so the lock it lets go of
    /// when kicked goes to the remover.
    removers: std.atomic.Value(u32) = .init(0),

    const darwin = builtin.os.tag.isDarwin();
    const linux = builtin.os.tag == .linux;
    const max_events = 64;

    fn open(p: *Poller) void {
        if (darwin) {
            p.fd = std.c.kqueue();
            if (p.fd < 0) rt.oom();
            const ev: std.c.Kevent = .{ .ident = 0, .filter = std.c.EVFILT.USER, .flags = std.c.EV.ADD | std.c.EV.CLEAR, .fflags = 0, .data = 0, .udata = 0 };
            var none: [1]std.c.Kevent = undefined;
            _ = std.c.kevent(p.fd, @ptrCast(&ev), 1, &none, 0, null);
        } else if (linux) {
            const linux_ = std.os.linux;
            p.fd = @intCast(@as(isize, @bitCast(linux_.epoll_create1(linux_.EPOLL.CLOEXEC))));
            p.kick_fd = @intCast(@as(isize, @bitCast(linux_.eventfd(0, linux_.EFD.NONBLOCK | linux_.EFD.CLOEXEC))));
            if (p.fd < 0 or p.kick_fd < 0) rt.oom();
            var ev: linux_.epoll_event = .{ .events = linux_.EPOLL.IN | linux_.EPOLL.ET, .data = .{ .ptr = 0 } };
            _ = linux_.epoll_ctl(p.fd, linux_.EPOLL.CTL_ADD, p.kick_fd, &ev);
        }
    }

    fn close(p: *Poller) void {
        if (p.fd >= 0) _ = std.posix.system.close(p.fd);
        if (p.kick_fd >= 0) _ = std.posix.system.close(p.kick_fd);
        p.* = .{};
    }

    /// Wake the worker sleeping in it, or make its next sleep end at once.
    fn kick(p: *Poller) void {
        if (darwin) {
            const ev: std.c.Kevent = .{ .ident = 0, .filter = std.c.EVFILT.USER, .flags = 0, .fflags = std.c.NOTE.TRIGGER, .data = 0, .udata = 0 };
            var none: [1]std.c.Kevent = undefined;
            _ = std.c.kevent(p.fd, @ptrCast(&ev), 1, &none, 0, null);
        } else if (linux) {
            const one: u64 = 1;
            _ = std.os.linux.write(p.kick_fd, std.mem.asBytes(&one), 8);
        }
    }

    /// Watch `fd` for both readiness to read and to write, reported to
    /// `r` each time it changes (edge-triggered).
    fn add(p: *Poller, fd: i32, r: *Registration) bool {
        if (darwin) {
            const flags = std.c.EV.ADD | std.c.EV.CLEAR;
            const evs = [2]std.c.Kevent{
                .{ .ident = @intCast(fd), .filter = std.c.EVFILT.READ, .flags = flags, .fflags = 0, .data = 0, .udata = @intFromPtr(r) },
                .{ .ident = @intCast(fd), .filter = std.c.EVFILT.WRITE, .flags = flags, .fflags = 0, .data = 0, .udata = @intFromPtr(r) },
            };
            var none: [1]std.c.Kevent = undefined;
            if (std.c.kevent(p.fd, &evs, 2, &none, 0, null) < 0) return false;
        } else if (linux) {
            const linux_ = std.os.linux;
            var ev: linux_.epoll_event = .{ .events = linux_.EPOLL.IN | linux_.EPOLL.OUT | linux_.EPOLL.RDHUP | linux_.EPOLL.ET, .data = .{ .ptr = @intFromPtr(r) } };
            if (@as(isize, @bitCast(linux_.epoll_ctl(p.fd, linux_.EPOLL.CTL_ADD, fd, &ev))) < 0) return false;
        } else return false;
        _ = p.count.fetchAdd(1, .monotonic);
        return true;
    }

    /// Stop watching `fd`. Under the lock, so no event for it is being
    /// handled; the worker sleeping in the poller is woken to let go.
    fn remove(p: *Poller, fd: i32) void {
        _ = p.removers.fetchAdd(1, .seq_cst);
        p.kick();
        p.lock.lock();
        _ = p.removers.fetchSub(1, .seq_cst);
        defer p.lock.unlock();
        if (darwin) {
            const evs = [2]std.c.Kevent{
                .{ .ident = @intCast(fd), .filter = std.c.EVFILT.READ, .flags = std.c.EV.DELETE, .fflags = 0, .data = 0, .udata = 0 },
                .{ .ident = @intCast(fd), .filter = std.c.EVFILT.WRITE, .flags = std.c.EV.DELETE, .fflags = 0, .data = 0, .udata = 0 },
            };
            var none: [1]std.c.Kevent = undefined;
            _ = std.c.kevent(p.fd, &evs, 2, &none, 0, null);
        } else if (linux) {
            _ = std.os.linux.epoll_ctl(p.fd, std.os.linux.EPOLL.CTL_DEL, fd, null);
        }
        _ = p.count.fetchSub(1, .monotonic);
    }

    /// Wait up to `timeout` nanoseconds (0: only look; null: until an
    /// event) for events, and wake the fibers waiting on what they make
    /// ready; whether any. One who cannot take the lock does nothing,
    /// unless it means to wait.
    fn poll(p: *Poller, timeout: ?i96) bool {
        if (timeout != null and timeout.? == 0) {
            if (!p.lock.tryLock()) return false;
        } else {
            while (p.removers.load(.seq_cst) != 0) std.atomic.spinLoopHint();
            p.lock.lock();
        }
        defer p.lock.unlock();
        var any = false;
        if (darwin) {
            var evs: [max_events]std.c.Kevent = undefined;
            var ts: std.c.timespec = undefined;
            const tp: ?*const std.c.timespec = if (timeout) |t| blk: {
                ts = .{ .sec = @intCast(@divTrunc(t, std.time.ns_per_s)), .nsec = @intCast(@mod(t, std.time.ns_per_s)) };
                break :blk &ts;
            } else null;
            const n = std.c.kevent(p.fd, &evs, 0, &evs, max_events, tp);
            if (n <= 0) return false;
            for (evs[0..@intCast(n)]) |ev| {
                if (ev.udata == 0) continue;
                const r: *Registration = @ptrFromInt(ev.udata);
                var bits: u32 = if (ev.filter == std.c.EVFILT.READ) Registration.readable else Registration.writable;
                if (ev.flags & std.c.EV.EOF != 0) bits |= Registration.closed;
                if (r.ready(bits)) any = true;
            }
        } else if (linux) {
            const linux_ = std.os.linux;
            var evs: [max_events]linux_.epoll_event = undefined;
            const ms: i32 = if (timeout) |t| @intCast(@min(@divTrunc(t + std.time.ns_per_ms - 1, std.time.ns_per_ms), std.math.maxInt(i32))) else -1;
            const rc: isize = @bitCast(linux_.epoll_wait(p.fd, &evs, max_events, ms));
            if (rc <= 0) return false;
            for (evs[0..@intCast(rc)]) |ev| {
                if (ev.data.ptr == 0) {
                    var drain: u64 = 0;
                    _ = linux_.read(p.kick_fd, std.mem.asBytes(&drain), 8);
                    continue;
                }
                const r: *Registration = @ptrFromInt(ev.data.ptr);
                var bits: u32 = 0;
                if (ev.events & (linux_.EPOLL.IN | linux_.EPOLL.RDHUP | linux_.EPOLL.HUP | linux_.EPOLL.ERR) != 0) bits |= Registration.readable;
                if (ev.events & (linux_.EPOLL.OUT | linux_.EPOLL.HUP | linux_.EPOLL.ERR) != 0) bits |= Registration.writable;
                if (ev.events & (linux_.EPOLL.RDHUP | linux_.EPOLL.HUP | linux_.EPOLL.ERR) != 0) bits |= Registration.closed;
                if (r.ready(bits)) any = true;
            }
        }
        return any;
    }
};

/// A file descriptor a poller watches: what it has seen the descriptor
/// become ready for since a wait last took it, and the fibers waiting to
/// read and to write. Readiness is edge-triggered: a waiter that took it
/// tries its read or write, and waits again only once that would block.
pub const Registration = struct {
    fd: i32,
    poller: *Poller,
    ready_bits: std.atomic.Value(u32) = .init(0),
    reader: Waiter = .{},
    writer: Waiter = .{},

    pub const readable: u32 = 1;
    pub const writable: u32 = 2;
    /// The other end closed, or the descriptor failed: every wait ends.
    pub const closed: u32 = 4;

    /// The fiber waiting, and the epoch of its wait. A poller waking it
    /// holds it (`waking` in place of the fiber) until it is done, and
    /// the fiber takes itself back only once no poller holds it
    /// (`leave`), so a fiber that goes on and ends is never touched
    /// after.
    const Waiter = struct {
        fiber: std.atomic.Value(?*Fiber) = .init(null),
        epoch: std.atomic.Value(u32) = .init(0),

        const waking: *Fiber = @ptrFromInt(std.mem.alignBackward(usize, std.math.maxInt(usize), @alignOf(Fiber)));

        fn wakeIt(w: *Waiter) bool {
            const f = w.fiber.load(.seq_cst) orelse return false;
            if (f == waking) return false;
            if (w.fiber.cmpxchgStrong(f, waking, .seq_cst, .seq_cst) != null) return false;
            defer w.fiber.store(f, .seq_cst);
            return interrupt(f, w.epoch.load(.seq_cst), false);
        }

        /// The fiber `f` is done waiting: take it back, once no poller
        /// holds it.
        fn leave(w: *Waiter, f: *Fiber) void {
            while (w.fiber.cmpxchgWeak(f, null, .seq_cst, .monotonic) != null) std.atomic.spinLoopHint();
        }
    };

    /// The poller saw `bits`: record them, then wake who waits on them.
    fn ready(r: *Registration, bits: u32) bool {
        _ = r.ready_bits.fetchOr(bits, .seq_cst);
        var any = false;
        if (bits & (readable | closed) != 0 and r.reader.wakeIt()) any = true;
        if (bits & (writable | closed) != 0 and r.writer.wakeIt()) any = true;
        return any;
    }
};

/// Watch `fd`, which must not block, with the running worker's poller
/// (worker 0's outside the workers); null when the kernel refuses it.
pub fn register(fd: i32) ?*Registration {
    if (!started) startWorkers();
    const w = me() orelse &workers[0];
    const r = std.heap.smp_allocator.create(Registration) catch rt.oom();
    r.* = .{ .fd = fd, .poller = &w.poller };
    if (!w.poller.add(fd, r)) {
        std.heap.smp_allocator.destroy(r);
        return null;
    }
    return r;
}

/// Stop watching the descriptor and free `r`, before the descriptor is
/// closed. No fiber may be waiting on it.
pub fn deregister(r: *Registration) void {
    r.poller.remove(r.fd);
    std.heap.smp_allocator.destroy(r);
}

/// How a wait on a descriptor ended (`waitReady`).
pub const Readiness = enum { ready, canceled, timeout };

/// Wait for `r` to be ready for `interest` (`Registration.readable` or
/// `.writable`), or to be closed, until `deadline`; a cancel ends the
/// wait when `cancelable`. Readiness the poller saw before is taken at
/// once, which spends from the fiber's budget (`spendBudget`).
pub fn waitReady(r: *Registration, interest: u32, deadline: ?i96, cancelable: bool) Readiness {
    const f = current().?;
    const waiter = if (interest == Registration.readable) &r.reader else &r.writer;
    while (true) {
        if (r.ready_bits.load(.seq_cst) & (interest | Registration.closed) != 0) {
            _ = r.ready_bits.fetchAnd(~interest, .seq_cst);
            spendBudget();
            return .ready;
        }
        if (cancelable and isCanceled(f)) return .canceled;
        if (deadline) |d| if (nowNs() >= d) return .timeout;
        pausePoint();
        const e = beginWait(cancelable);
        waiter.epoch.store(e, .seq_cst);
        waiter.fiber.store(f, .seq_cst);
        // Readiness the poller saw before this waiter was there, and a
        // cancel that came before the wait began, which found no wait to
        // end: either one, and the fiber goes on.
        const seen = r.ready_bits.load(.seq_cst) & (interest | Registration.closed) != 0;
        if (!seen and !(cancelable and isCanceled(f))) commitWait(e, deadline);
        waiter.leave(f);
    }
}

/// Whether the task `f` runs is canceled: a sequentially consistent load,
/// which a canceler's store of the flag, then its load of the wait's
/// word (`interruptForCancel`), pairs with, so of the fiber that begins
/// a wait and then looks, and the canceler, at least one sees the other.
fn isCanceled(f: *Fiber) bool {
    const control = f.state.control orelse return false;
    return control.canceled.load(.seq_cst);
}

/// Test only: a handshake held open at a point a test names
/// (`pausePoint`), until the test lets it go, so the test can land
/// another thread's step there.
pub const Pause = struct {
    reached: std.atomic.Value(bool) = .init(false),
    go: std.atomic.Value(bool) = .init(false),
};

/// The pause the next `pausePoint` holds, set by a test.
pub var test_pause: std.atomic.Value(?*Pause) = .init(null);

/// In a test that set `test_pause`, hold here until it lets go: between
/// a waiting point's last look at its cancel flag and the wait it begins.
inline fn pausePoint() void {
    if (!builtin.is_test) return;
    if (test_pause.load(.monotonic) == null) return;
    const p = test_pause.swap(null, .seq_cst) orelse return;
    p.reached.store(true, .seq_cst);
    while (!p.go.load(.seq_cst)) std.atomic.spinLoopHint();
}

/// How many waits that end at once a fiber makes before it yields.
const budget_size = 128;

/// A wait ended at once: spend from the running fiber's budget, and yield
/// once it is spent, so other work on its worker runs.
pub fn spendBudget() void {
    const f = current() orelse return;
    f.budget -%= 1;
    if (f.budget != 0) return;
    f.budget = budget_size;
    if (!deterministic) if (me()) |w| if (hasOwnWork(w)) yield();
}

/// Wake the fibers whose timers are due on worker `w`, and those its
/// poller's events make ready, when it has descriptors: what a worker
/// looks at every 61 turns.
fn service(w: *Worker) void {
    if (w.timers.due.load(.acquire) != no_due) _ = w.timers.fire(nowNs());
    if (w.poller.count.load(.monotonic) != 0) _ = w.poller.poll(0);
}

/// Before `w` sleeps: wake the fibers whose timers are due on any worker,
/// and those the events of any poller no worker sleeps in make ready.
fn serviceAll(w: *Worker) void {
    const now = nowNs();
    for (workers) |*v| {
        _ = v.timers.fire(now);
        if (v.poller.count.load(.monotonic) != 0) _ = v.poller.poll(0);
    }
    _ = w;
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
    // Deterministic, it runs here: no other thread could end its wait
    // in an order the seed decides.
    if (deterministic) return @call(.auto, f, args);
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
    workers[0].poller.open();
    started = false;
    stopping.store(false, .seq_cst);
    var m: Main = .{ .fiber = .{ .run = Main.start, .done = Main.end }, .arg = arg, .run = run };
    m.fiber.state.stack_guard = guard;
    m.fiber.sp = initialFrame(&m.fiber, top);
    me_slot = &workers[0];
    if (deterministic) wake(&m.fiber) else workers[0].ring.push(&m.fiber);
    loop(&workers[0]);
    pool.stop();
    for (workers[1..]) |*w| w.thread.?.join();
    timers.clear();
    for (workers) |*w| {
        freeStacks(w);
        freeBlocks(w);
        w.timers.clear();
        w.poller.close();
    }
    std.heap.smp_allocator.free(all_workers);
    workers = &.{};
    all_workers = &.{};
    me_slot = null;
    // Workers stopped asleep are still listed; the next run, in a test,
    // starts with none.
    sleepers = .{};
    searching.store(0, .seq_cst);
    waiting.store(0, .monotonic);
    ready.clearAndFree(std.heap.smp_allocator);
}

/// Test only: run `run` as `main`, on a stack of its own, with `n`
/// workers.
pub fn runForTest(run: *const fn (*anyopaque) callconv(.c) void, n: usize) void {
    workers_override = n;
    defer workers_override = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, run, s.top(), .{});
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
    const n = if (deterministic) 1 else @min(workerCount(), all_workers.len);
    workers = all_workers[0..n];
    for (workers[1..]) |*w| w.poller.open();
    for (workers[1..]) |*w| w.thread = std.Thread.spawn(.{}, workerMain, .{w}) catch rt.oom();
}

/// How many workers run tasks, starting them first if they have not.
pub fn workersRunning() usize {
    if (!started) startWorkers();
    return workers.len;
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
        if (deterministic) {
            const f = next(w) orelse {
                advanceClock();
                continue;
            };
            runFiber(w, f);
            continue;
        }
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
/// it is never starved), this worker's "run next" fiber, its pinned
/// fibers' and its ring's, the global queue's, or one stolen.
fn next(w: *Worker) ?*Fiber {
    // Deterministic: any ready fiber, as the seed picks, once the timers
    // the clock has reached have woken theirs.
    if (deterministic) {
        fireDue();
        if (ready.items.len == 0) return null;
        return ready.orderedRemove(random(ready.items.len));
    }
    w.tick +%= 1;
    if (w.tick % 61 == 0) {
        service(w);
        if (global.pop()) |f| return f;
    }
    if (w.lifo) |f| {
        if (w.lifo_streak < lifo_limit) {
            w.lifo = null;
            w.lifo_streak += 1;
            return f;
        }
        // Run a fiber from the ring first, and leave this one to be
        // stolen meanwhile.
        w.lifo = null;
        if (f.home != null) w.pinned.push(f) else w.ring.push(f);
    }
    w.lifo_streak = 0;
    // Pinned fibers and the ring take turns first, so neither keeps the
    // other waiting.
    if (w.tick & 1 == 0) if (w.pinned.pop()) |f| return f;
    if (w.ring.pop()) |f| return f;
    if (w.pinned.pop()) |f| return f;
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

/// `notify` for work woken or made, not a fiber that yielded: when no
/// worker is looking or asleep, every one is busy, and their yield
/// checks are told it waits (`waiting`).
fn notifyNew() void {
    if (deterministic) return;
    if (searching.load(.seq_cst) == 0 and sleepers.count.load(.seq_cst) == 0) {
        if (waiting.load(.monotonic) == 0) waiting.store(1, .monotonic);
        return;
    }
    notify();
}

/// Wake a sleeping worker when work was made and no worker is looking,
/// counting it as searching from now, so the next work made does not
/// wake another before this one has looked.
fn notify() void {
    if (deterministic) return;
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
    w.poller.kick();
}

/// Sleep until woken: listed as asleep first, then, after a last look
/// for work made meanwhile, in its poller. Work a worker searching will
/// find needs no last look: only work made when none searches, which
/// woke no one (`notify`), keeps this worker up. A worker with no work
/// to find clears `waiting`. While it sleeps, it wakes the fibers whose
/// timers come due on any worker, and those its poller's events make
/// ready, and goes back to running them.
fn sleep(w: *Worker) void {
    if (waiting.load(.monotonic) != 0) waiting.store(0, .monotonic);
    w.woken.store(0, .seq_cst);
    w.idle.store(1, .seq_cst);
    defer w.idle.store(0, .seq_cst);
    sleepers.push(w);
    if (stopping.load(.seq_cst) or (searching.load(.seq_cst) == 0 and hasWork())) {
        if (!sleepers.remove(w)) waitWoken(w);
        return;
    }
    while (w.woken.load(.seq_cst) == 0) {
        serviceAll(w);
        if (!hasOwnWork(w)) {
            w.sleep_due.store(no_due, .seq_cst);
            const due = earliestDue();
            w.sleep_due.store(due, .seq_cst);
            _ = w.poller.poll(if (due == no_due) null else @max(@as(i96, due) - nowNs(), 0));
            w.sleep_due.store(awake, .seq_cst);
            if (!hasOwnWork(w)) continue;
        }
        // Fibers made ready here: run them, unless a waker took this
        // worker off the list meanwhile, when it waits for its kick.
        if (!sleepers.remove(w)) waitWoken(w);
        return;
    }
}

fn waitWoken(w: *Worker) void {
    while (w.woken.load(.seq_cst) == 0) _ = w.poller.poll(null);
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

pub const SpinLock = struct {
    held: std.atomic.Value(bool) = .init(false),

    pub fn lock(l: *SpinLock) void {
        while (l.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) std.atomic.spinLoopHint();
    }

    pub fn unlock(l: *SpinLock) void {
        l.held.store(false, .release);
    }

    pub fn tryLock(l: *SpinLock) bool {
        return l.held.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
    }
};

// -----------------------------------------------------------------------------
// Deadlocks
// -----------------------------------------------------------------------------
//
// A fiber that blocks publishes what it waits on (`block`): a task's end,
// an actor's answer to a call, or the end of any of several tasks. Each
// actor it runs a method of then names that wait too (`Held`), so a call
// waiting on the actor leads on to it. The fiber then walks the chain of
// waits from its own, under one lock (`graph`), and a chain that comes
// back to it is a deadlock: none of its waits can end. The walk that
// closes a cycle finds it, since of two that close it at once the later
// sees the other's wait. A record lives in its fiber's frame until
// `unblock`, which clears it and then waits out a walk in progress, so a
// walk never reads one that has gone; and a record cleared during a walk
// cannot come back before the walk ends, so a cycle whose records are all
// still there at its end held, all at once, then.

/// Whether waits are watched: in a program that makes actors, which
/// every cycle of waits passes through, since the tasks a task waits on
/// are its own.
const watched = @hasDecl(@import("root"), "__rig_actors");

/// A method of an actor, as a deadlock names it: `Bank.pay`.
pub const Label = struct { actor: []const u8, method: []const u8 };

/// What a fiber waits on while it blocks.
pub const Blocked = union(enum) {
    /// A task's end.
    task: *Header,
    /// An actor's answer to a call.
    call: CallWait,
    /// The end of any of several tasks: a set that can fail, or
    /// `task.both`.
    any: AnyWait,

    pub const CallWait = struct {
        /// The method called.
        label: *const Label,
        /// The actor's `held_by`: the method running in it, while the
        /// fiber running it blocks.
        held_by: *const std.atomic.Value(?*Held),
        /// The call, and whether it has been answered.
        msg: *const anyopaque,
        answered: *const fn (*const anyopaque) bool,
    };

    pub const AnyWait = struct {
        ctx: *const anyopaque,
        len: usize,
        /// The record of task `i`, or null once the waiter took it.
        member: *const fn (*const anyopaque, usize) ?*Header,
    };
};

/// An actor a fiber runs a method of, in the fiber's frame, on its list
/// (`Fiber.held`). While the fiber blocks, the actor's `held_by` names
/// it, and so what the fiber waits on.
pub const Held = struct {
    held_by: *std.atomic.Value(?*Held),
    /// The method it runs.
    doing: *const Label,
    /// A panic on the fiber: the actor dies (`tasks.actorsDie`); true
    /// when the fiber is the actor's runner, where the panic stops.
    die: *const fn (*Held) bool,
    next: ?*Held,
    /// The fiber, and what it waits on, while it blocks (`block`).
    fiber: *Fiber = undefined,
    blocked: *const Blocked = undefined,
};

/// Held while a fiber walks the chain of waits.
var graph: std.atomic.Value(bool) = .init(false);

fn lockGraph() void {
    while (graph.cmpxchgWeak(false, true, .seq_cst, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockGraph() void {
    graph.store(false, .seq_cst);
}

/// The running fiber blocks on `b` until `unblock`: publish it, and walk
/// the chain of waits from it. One that comes back here is a deadlock,
/// which panics naming its calls.
pub fn block(b: *const Blocked) void {
    if (!watched) return;
    const f = current() orelse return;
    f.blocked.store(b, .seq_cst);
    var at = f.held;
    while (at) |h| : (at = h.next) {
        h.fiber = f;
        h.blocked = b;
        h.held_by.store(h, .seq_cst);
    }
    if (!leadsOn(b)) return;
    var walk: Walk = .{ .me = f };
    var buf: [1024]u8 = undefined;
    lockGraph();
    const text = if (walk.stuck(b, 0) and walk.holds()) walk.describe(&buf) else null;
    unlockGraph();
    if (text) |t| {
        unblock();
        @panic(t);
    }
}

/// Whether the wait `b` leads to a fiber that blocks too, which a cycle
/// needs: read without the lock, since the waiter keeps what it waits on.
/// A wait whose next fiber runs closes no cycle now, and when that fiber
/// blocks, its own walk finds this wait.
fn leadsOn(b: *const Blocked) bool {
    return switch (b.*) {
        .task => |h| h.fiber.blocked.load(.seq_cst) != null,
        .call => |c| c.held_by.load(.seq_cst) != null,
        .any => |a| for (0..a.len) |i| {
            const h = a.member(a.ctx, i) orelse continue;
            if (h.fiber.blocked.load(.seq_cst) != null) break true;
        } else false,
    };
}

/// The running fiber's wait is over: take back what `block` published,
/// and wait out a walk that may still read it.
pub fn unblock() void {
    if (!watched) return;
    const f = current() orelse return;
    f.blocked.store(null, .seq_cst);
    var at = f.held;
    while (at) |h| : (at = h.next) h.held_by.store(null, .seq_cst);
    if (graph.load(.seq_cst)) {
        lockGraph();
        unlockGraph();
    }
}

/// A walk of the chain of waits from `me`'s.
const Walk = struct {
    me: *Fiber,
    /// The waits on the way from `me`'s, by depth, and where each leads.
    path: [max_steps]*const Blocked = undefined,
    steps: [max_steps]Step = undefined,
    /// The first way found back to `me`, to name the cycle.
    cycle: [max_steps]Step = undefined,
    n: usize = 0,
    /// What the walk read, to check it still holds once it is done.
    seen: [max_seen]Seen = undefined,
    n_seen: usize = 0,

    const max_steps = 64;
    const max_seen = 256;

    /// A wait: the call it waits on, or null for a task's end, and the
    /// fiber it leads to, at the method running in the actor called.
    const Step = struct { call: ?*const Label, fiber: *Fiber, at: ?*Held };

    const Seen = union(enum) {
        fiber: struct { f: *Fiber, b: *const Blocked },
        held: struct { held_by: *const std.atomic.Value(?*Held), h: *Held },
        call: Blocked.CallWait,
        task: *Header,
    };

    /// Whether every way the wait `b` can end leads back to `me`, through
    /// fibers that block: then it can never end. A wait already on the
    /// way here counts as one that cannot end, since each way out of it
    /// comes back to it, and every wait on the way blocks.
    fn stuck(w: *Walk, b: *const Blocked, depth: usize) bool {
        if (depth == max_steps) return false;
        for (w.path[0..depth]) |p| if (p == b) return true;
        w.path[depth] = b;
        switch (b.*) {
            .task => |h| {
                if (!w.see(.{ .task = h })) return false;
                return w.through(.{ .call = null, .fiber = &h.fiber, .at = null }, depth);
            },
            .call => |c| {
                if (!w.see(.{ .call = c })) return false;
                const h = c.held_by.load(.seq_cst) orelse return false;
                if (!w.see(.{ .held = .{ .held_by = c.held_by, .h = h } })) return false;
                return w.through(.{ .call = c.label, .fiber = h.fiber, .at = h }, depth);
            },
            .any => |a| {
                var pending = false;
                for (0..a.len) |i| {
                    const h = a.member(a.ctx, i) orelse continue;
                    if (!w.see(.{ .task = h })) return false;
                    pending = true;
                    if (!w.through(.{ .call = null, .fiber = &h.fiber, .at = null }, depth)) return false;
                }
                return pending;
            },
        }
    }

    /// Whether the wait at `depth`, which leads as `step` says, comes
    /// back to `me`, or to a fiber that blocks in a wait that does.
    fn through(w: *Walk, step: Step, depth: usize) bool {
        w.steps[depth] = step;
        if (step.fiber == w.me) {
            if (w.n == 0) {
                w.n = depth + 1;
                @memcpy(w.cycle[0..w.n], w.steps[0..w.n]);
            }
            return true;
        }
        // A fiber that runs the method a call waits on blocks in the wait
        // it published as it blocked; a task's fiber, in its own.
        const then = if (step.at) |h| h.blocked else step.fiber.blocked.load(.seq_cst) orelse return false;
        if (!w.see(.{ .fiber = .{ .f = step.fiber, .b = then } })) return false;
        return w.stuck(then, depth + 1);
    }

    /// Note what the walk read, when it still stands: false once the
    /// walk has read too much, or `s` already fails.
    fn see(w: *Walk, s: Seen) bool {
        if (w.n_seen == max_seen or !stands(s)) return false;
        w.seen[w.n_seen] = s;
        w.n_seen += 1;
        return true;
    }

    /// Whether all the walk read still stands.
    fn holds(w: *const Walk) bool {
        for (w.seen[0..w.n_seen]) |s| if (!stands(s)) return false;
        return true;
    }

    fn stands(s: Seen) bool {
        return switch (s) {
            .fiber => |x| x.f.blocked.load(.seq_cst) == x.b,
            .held => |x| x.held_by.load(.seq_cst) == x.h,
            .call => |c| !c.answered(c.msg),
            .task => |h| h.status.load(.seq_cst) < Header.ending,
        };
    }

    /// The cycle, as the methods that make it, from one running in an
    /// actor on it: each fiber's methods, outermost first, then the call
    /// it waits on, as `Bank.pay -> Ledger.post -> Bank.balance`, where
    /// `Bank.balance` waits on `Bank.pay`. A method named just before, as
    /// the call that waits on it, is not named again; a wait on a task is
    /// `a task`.
    fn describe(w: *const Walk, buf: []u8) []const u8 {
        var out: std.Io.Writer = .fixed(buf);
        const steps = w.cycle[0..w.n];
        const k = for (steps, 0..) |s, i| {
            if (s.at != null) break i;
        } else 0;
        out.writeAll("deadlock: these calls wait on each other, and none can go on: ") catch {};
        var names: Names = .{ .out = &out };
        names.methods(steps[k]);
        const start = names.last;
        for (1..steps.len + 1) |i| {
            const s = steps[(k + i) % steps.len];
            if (s.call) |c| {
                if (i < steps.len or !same(c, start)) names.add(c);
            } else names.task();
            if (i < steps.len) names.methods(s);
        }
        return out.buffered();
    }

    /// Names written in turn, with arrows between them.
    const Names = struct {
        out: *std.Io.Writer,
        last: ?*const Label = null,
        first: bool = true,

        /// The methods running on the fiber a step leads to, outermost
        /// first: from the one the step's call waits on, or every one
        /// for a task's.
        fn methods(n: *Names, s: Step) void {
            var list: [max_steps]*const Label = undefined;
            var count: usize = 0;
            var at = s.fiber.held;
            while (at) |h| : (at = h.next) {
                if (count < list.len) {
                    list[count] = h.doing;
                    count += 1;
                }
                if (h == s.at) break;
            }
            while (count > 0) {
                count -= 1;
                n.add(list[count]);
            }
        }

        fn add(n: *Names, l: *const Label) void {
            if (n.last) |last| if (same(last, l)) return;
            n.arrow();
            n.out.print("{s}.{s}", .{ l.actor, l.method }) catch {};
            n.last = l;
        }

        fn task(n: *Names) void {
            n.arrow();
            n.out.writeAll("a task") catch {};
            n.last = null;
        }

        fn arrow(n: *Names) void {
            if (!n.first) n.out.writeAll(" -> ") catch {};
            n.first = false;
        }
    };

    fn same(a: ?*const Label, b: ?*const Label) bool {
        const x = a orelse return false;
        const y = b orelse return false;
        return std.mem.eql(u8, x.actor, y.actor) and std.mem.eql(u8, x.method, y.method);
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
    /// Set when the task panicked and ended where it stood, with no
    /// result (`abandon`).
    panicked: std.atomic.Value(bool) = .init(false),
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
    /// flag to be set first, or for `deadline` to pass, when this gives
    /// false.
    fn waitEnd(h: *Header, cancel: ?*const std.atomic.Value(bool), deadline: ?i96) bool {
        if (h.isEnded()) return true;
        const b: Blocked = .{ .task = h };
        block(&b);
        defer unblock();
        {
            const w = me().?;
            // Not started, and next on this worker: run it now. A fiber in
            // the "run next" slot may also be one woken partway, which
            // goes on where it stopped instead. A wait with a deadline
            // sleeps on its timer instead.
            if (deadline == null and w.lifo == &h.fiber and h.fiber.sp == 0) handoff(w, h, cancel);
        }
        while (!h.isEnded()) {
            if (cancel) |c| if (c.load(.seq_cst)) return false;
            if (deadline) |d| if (nowNs() >= d) return false;
            const e = beginWait(cancel != null);
            h.waiter.store(current().?, .seq_cst);
            h.waiter_epoch.store(e, .seq_cst);
            if (h.status.cmpxchgStrong(running, waited, .seq_cst, .seq_cst)) |s| {
                if (s != waited) continue;
            }
            if (cancel) |c| if (c.load(.seq_cst)) return false;
            commitWait(e, deadline);
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
        /// gives the same result; the owner takes it once (`Task`). A
        /// task that panicked gave none: the panic passes to the waiter
        /// (`rt.passPanic`).
        pub fn join(self: *Self) T {
            _ = self.header.waitEnd(null, null);
            return self.taken();
        }

        /// The result of the task, which has ended; when it panicked
        /// instead, the panic passes on.
        pub fn taken(self: *Self) T {
            if (self.header.panicked.load(.seq_cst)) rt.passPanic();
            return self.result;
        }

        /// Wait for the task to end, unless the flag `cancel` is set
        /// or `deadline` passes first: whether it has ended.
        pub fn waitEnd(self: *Self, cancel: ?*const std.atomic.Value(bool), deadline: ?i96) bool {
            return self.header.waitEnd(cancel, deadline);
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
/// the usual way and wakes it. A cancel that came before the wait began,
/// when `cancel` is given, leaves the task where it is.
fn handoff(w: *Worker, h: *Header, cancel: ?*const std.atomic.Value(bool)) void {
    const waiter = w.current.?;
    const f = &h.fiber;
    pausePoint();
    const e = beginWait(cancel != null);
    if (cancel) |c| if (c.load(.seq_cst)) return;
    w.lifo = null;
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
/// task's `Control` there), which `f` gets first. A `local` task, and the
/// fiber making it, are pinned to this worker (`pinHere`).
pub fn spawn(comptime T: type, comptime Extra: type, comptime f: anytype, args: anytype, extra: Extra, local: bool) Spawned(T, Extra) {
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
    full.* = .{ .job = .{ .header = .{ .fiber = .{ .run = Full.start, .done = Header.end }, .destroy = Full.destroy } }, .extra = extra, .args = args };
    // An `Extra` that names its task's fiber is given it, for a cancel to
    // reach the fiber's wait (`interruptForCancel`), and one that records
    // its task somewhere does so before the task can run (`made`).
    if (@hasField(Extra, "fiber")) full.extra.fiber = &full.job.header.fiber;
    if (@hasDecl(Extra, "made")) full.extra.made();
    if (local) full.job.header.fiber.home = pinHere();
    wake(&full.job.header.fiber);
    return .{ .job = &full.job, .extra = &full.extra };
}

/// Start `f(args...)` as a fiber no one waits for: its record frees
/// itself once the fiber has ended (an actor's runner, `tasks.Actor`).
pub fn spawnDetached(comptime f: anytype, args: anytype) void {
    const Args = @TypeOf(args);
    const Full = struct {
        fiber: Fiber,
        args: Args,

        fn start(fiber: *Fiber) void {
            const full: *@This() = @fieldParentPtr("fiber", fiber);
            @call(.auto, f, full.args);
        }

        fn end(fiber: *Fiber) void {
            const full: *@This() = @fieldParentPtr("fiber", fiber);
            std.heap.smp_allocator.destroy(full);
        }
    };
    if (!started) startWorkers();
    const full = std.heap.smp_allocator.create(Full) catch rt.oom();
    full.* = .{ .fiber = .{ .run = Full.start, .done = Full.end }, .args = args };
    wake(&full.fiber);
}

/// What `spawn` gives: the task's record, and the `Extra` in it.
pub fn Spawned(comptime T: type, comptime Extra: type) type {
    return struct { job: *Job(T), extra: *Extra };
}

// -----------------------------------------------------------------------------
// Stacks
// -----------------------------------------------------------------------------

/// A fiber's stack: `guard` bytes of inaccessible address space at
/// `base`, then the stack, then one inaccessible page.
pub const Stack = struct {
    base: usize,
    guard: usize,
    len: usize,

    fn top(s: Stack) usize {
        return s.base + s.guard + s.len - rt.unwind_headroom;
    }
};

/// The size of a block a task holds only while it works, as an HTTP
/// connection holds its buffers while it reads and answers a request
/// (`net.Conn`), and gives back while it waits.
pub const block_size = 16 * 1024;

/// How many blocks a worker keeps for the next; one more goes back to the
/// system, so a burst of work leaves no memory behind once it ends.
const keep_blocks = 64;

const FreeBlock = struct { next: ?*FreeBlock };

/// A block of `block_size` bytes: one this worker kept, or a new one from
/// the system.
pub fn takeBlock() *[block_size]u8 {
    if (me()) |w| if (w.blocks) |b| {
        w.blocks = b.next;
        w.block_count -= 1;
        return @ptrCast(b);
    };
    return std.heap.page_allocator.create([block_size]u8) catch rt.oom();
}

/// Give back a block `takeBlock` gave: this worker keeps it, or the
/// system has it back.
pub fn giveBlock(given: *[block_size]u8) void {
    if (me()) |w| if (w.block_count < keep_blocks) {
        const b: *FreeBlock = @ptrCast(@alignCast(given));
        b.next = w.blocks;
        w.blocks = b;
        w.block_count += 1;
        return;
    };
    std.heap.page_allocator.destroy(given);
}

fn freeBlocks(w: *Worker) void {
    while (w.blocks) |b| {
        w.blocks = b.next;
        const kept: *[block_size]u8 = @ptrCast(@alignCast(b));
        std.heap.page_allocator.destroy(kept);
    }
    w.block_count = 0;
}

/// A free stack's link in its worker's list, kept in the stack itself, in
/// the room left at its top (`rt.unwind_headroom`): on the page the next
/// fiber's first frame touches anyway, so a free stack holds no page a
/// fiber would not.
const FreeStack = struct { stack: Stack, next: ?*FreeStack };

comptime {
    std.debug.assert(@sizeOf(FreeStack) <= rt.unwind_headroom);
}

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
    const n: *FreeStack = @ptrFromInt(s.base + s.guard + s.len - @sizeOf(FreeStack));
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
/// made with hold the fiber (x19, rbx) and `fiberMain` (x20, r12). It
/// enters `fiberMain`, which never returns, with no frame and no return
/// address above it, so a stack trace's walk ends there.
fn fiberStartNaked() callconv(.naked) void {
    switch (builtin.target.cpu.arch) {
        .aarch64 => asm volatile (
            \\ mov x0, x19
            \\ mov x29, xzr
            \\ mov x30, xzr
            \\ br x20
        ),
        .x86_64 => asm volatile (
            \\ mov %%rbx, %%rdi
            \\ xorl %%ebp, %%ebp
            \\ andq $-16, %%rsp
            \\ pushq $0
            \\ jmp *%%r12
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
    finishFiber(f);
}

/// End the running fiber `f` for good: back to its worker, which
/// publishes its end (`runFiber`), or to the fiber that handed it the
/// worker. A fiber that panicked ends so too, its frames left as they
/// were (`abandon`). Inline: a call here costs every task's end several
/// nanoseconds (`bench/tasks` chain).
inline fn finishFiber(f: *Fiber) noreturn {
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
    return frameCalling(@intFromPtr(f), @intFromPtr(&fiberMain), top);
}

/// The stack pointer that, switched to, calls `entry(arg)`, which never
/// returns, at `top`, with no frame above it (`fiberStartNaked`).
fn frameCalling(arg: usize, entry: usize, top: usize) usize {
    const sp = (top & ~@as(usize, 15)) - saved_bytes;
    const slots: [*]usize = @ptrFromInt(sp);
    @memset(slots[0 .. saved_bytes / 8], 0);
    switch (builtin.target.cpu.arch) {
        .aarch64 => {
            slots[0] = arg; // x19
            slots[1] = entry; // x20
            slots[11] = @intFromPtr(&fiberStartNaked); // x30
        },
        .x86_64 => {
            slots[3] = entry; // r12
            slots[4] = arg; // rbx
            slots[6] = @intFromPtr(&fiberStartNaked); // the return address
        },
        else => unreachable,
    }
    return sp;
}

/// Run `entry(arg)` on a stack of its own, within the running fiber,
/// which keeps waiting and switching there as anywhere: `task.isolate`.
/// `entry` never returns; it ends with `leaveApart(home.*)`, after its
/// work or after a panic, and the fiber goes on here on its own stack,
/// whose frames the stack apart could not reach. The stack apart is then
/// kept for the next.
pub fn runApart(home: *usize, arg: *anyopaque, entry: *const fn (*anyopaque) callconv(.c) noreturn) void {
    const s = takeStack();
    const state = rt.task();
    const guard = state.stack_guard;
    state.stack_guard = .{ .lo = s.base, .hi = s.base + s.guard };
    switchTo(home, frameCalling(@intFromPtr(arg), @intFromPtr(entry), s.top()));
    rt.task().stack_guard = guard;
    releaseStack(me().?, s);
}

/// Leave the stack `runApart` made for good, back to the fiber's own
/// stack at `home`.
pub fn leaveApart(home: usize) noreturn {
    var gone: usize = 0;
    switchTo(&gone, home);
    unreachable;
}

/// End the running fiber, one `spawnDetached` started, where it stands,
/// its frames left as they were: an actor's runner whose method panicked.
pub fn abandonDetached() noreturn {
    finishFiber(current().?);
}

/// End the running fiber where it stands, its frames left as they are:
/// a task that panicked (`tasks.panicked`). Its record is marked
/// `panicked`, so whoever waits for it learns so.
pub fn abandon() noreturn {
    const f = current().?;
    const h: *Header = @fieldParentPtr("fiber", f);
    h.panicked.store(true, .seq_cst);
    finishFiber(f);
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
                for (&jobs, 0..) |*j, i| j.* = spawn(u64, Unit, leaf, .{@as(u64, i)}, .{}, false).job;
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
                const j = spawn(u64, Unit, leaf, .{@as(u64, i)}, .{}, false).job;
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

test "local tasks and the fiber that made them stay on its worker, woken there by other workers' tasks" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var sum: u64 = 0;
        var moved = std.atomic.Value(u32).init(0);
        const Unit = struct {};
        fn leaf(_: *Unit, i: u64) u64 {
            var x: u64 = i;
            for (0..200) |k| x +%= k * i;
            if (i % 2 == 0) yield();
            return i;
        }
        /// A local task: it waits on a task free to run anywhere, whose
        /// end wakes it from another worker, and checks it never moved.
        fn local(_: *Unit, home: *Worker, i: u64) u64 {
            var got: u64 = 0;
            for (0..4) |k| {
                const j = spawn(u64, Unit, leaf, .{i * 4 + k}, .{}, false).job;
                yield();
                if (me().? != home) _ = moved.fetchAdd(1, .seq_cst);
                got += j.join();
                j.free();
                if (me().? != home) _ = moved.fetchAdd(1, .seq_cst);
            }
            return got;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            var jobs: [200]*Job(u64) = undefined;
            const home = me().?;
            for (&jobs, 0..) |*j, i| j.* = spawn(u64, Unit, local, .{ home, @as(u64, i) }, .{}, true).job;
            for (jobs) |j| {
                sum += j.join();
                j.free();
                if (me().? != home) _ = moved.fetchAdd(1, .seq_cst);
            }
        }
    };
    workers_override = 4;
    defer workers_override = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expectEqual(@as(u64, 799 * 800 / 2), Run.sum);
    try std.testing.expectEqual(@as(u32, 0), Run.moved.load(.seq_cst));
}

test "a fiber waiting on a pipe wakes when its other end is written, and a deadline ends such a wait" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var got: u8 = 0;
        var timed_out = false;
        var waited = false;
        const Unit = struct {};

        fn nap(ns: i96) void {
            const e = beginWait(false);
            commitWait(e, nowNs() + ns);
        }

        fn writer(_: *Unit, fd: i32) u8 {
            nap(2 * std.time.ns_per_ms);
            _ = std.posix.system.write(fd, "x", 1);
            return 0;
        }

        fn first(_: *anyopaque) callconv(.c) void {
            const fds = testPipe();
            const r = register(fds[0]).?;
            const j = spawn(u8, Unit, writer, .{fds[1]}, .{}, false).job;
            while (true) {
                var b: [1]u8 = undefined;
                const n: isize = @bitCast(std.posix.system.read(fds[0], &b, 1));
                if (n == 1) {
                    got = b[0];
                    break;
                }
                waited = true;
                if (waitReady(r, Registration.readable, null, false) != .ready) return;
            }
            _ = j.join();
            j.free();
            timed_out = waitReady(r, Registration.readable, nowNs() + std.time.ns_per_ms, false) == .timeout;
            deregister(r);
            _ = std.posix.system.close(fds[0]);
            _ = std.posix.system.close(fds[1]);
        }
    };
    workers_override = 2;
    defer workers_override = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(Run.waited);
    try std.testing.expectEqual(@as(u8, 'x'), Run.got);
    try std.testing.expect(Run.timed_out);
}

/// The type of a task's cancel flag and the fiber a cancel wakes
/// (`tasks.Control`), for the tests below.
const TestControl = @typeInfo(@typeInfo(@FieldType(rt.TaskState, "control")).optional.child).pointer.child;

fn testPipe() [2]i32 {
    var fds: [2]i32 = undefined;
    if (builtin.os.tag == .linux) {
        _ = std.os.linux.pipe2(&fds, .{ .NONBLOCK = true });
    } else {
        _ = std.c.pipe(&fds);
        for (fds) |fd| _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
    }
    return fds;
}

test "a cancel that lands after a wait on a descriptor last looked, but before it began, still ends it" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var got: Readiness = .ready;
        var took: i96 = 0;
        var ctl: TestControl = .{};
        var pause: Pause = .{};
        const Unit = struct {};

        /// Wait to read a pipe no one writes, for up to 2 s: only a
        /// cancel ends the wait sooner.
        fn reader(_: *Unit, r: *Registration) Readiness {
            const f = current().?;
            f.state.control = &ctl;
            ctl.fiber = f;
            return waitReady(r, Registration.readable, nowNs() + 2 * std.time.ns_per_s, true);
        }

        fn first(_: *anyopaque) callconv(.c) void {
            const fds = testPipe();
            const r = register(fds[0]).?;
            test_pause.store(&pause, .seq_cst);
            const j = spawn(Readiness, Unit, reader, .{r}, .{}, false).job;
            while (!pause.reached.load(.seq_cst)) yield();
            ctl.cancel();
            const start = nowNs();
            pause.go.store(true, .seq_cst);
            got = j.join();
            took = nowNs() - start;
            j.free();
            deregister(r);
            _ = std.posix.system.close(fds[0]);
            _ = std.posix.system.close(fds[1]);
        }
    };
    workers_override = 2;
    defer workers_override = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expectEqual(Readiness.canceled, Run.got);
    // Ended by the cancel, not by the deadline, after which the wait
    // looks at the flag again.
    try std.testing.expect(Run.took < std.time.ns_per_s);
}

test "a cancel that lands as a waiter is about to hand its worker to a task still ends the wait" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var waited: bool = true;
        var got: Readiness = .ready;
        var outer: TestControl = .{};
        var inner: TestControl = .{};
        var pause: Pause = .{};
        const Unit = struct {};

        /// The task waited on: it waits to read a pipe no one writes, for
        /// up to 2 s, unless it is canceled first.
        fn reader(_: *Unit, r: *Registration) Readiness {
            const f = current().?;
            f.state.control = &inner;
            inner.fiber = f;
            return waitReady(r, Registration.readable, nowNs() + 2 * std.time.ns_per_s, true);
        }

        /// The waiter: it makes the reader and waits for it at once, by
        /// handoff, unless its own cancel comes first, when it passes the
        /// cancel on.
        fn waiter(_: *Unit, r: *Registration) u8 {
            const f = current().?;
            f.state.control = &outer;
            outer.fiber = f;
            const j = spawn(Readiness, Unit, reader, .{r}, .{}, false).job;
            waited = j.waitEnd(&outer.canceled, null);
            if (!waited) inner.cancel();
            got = j.join();
            j.free();
            return 0;
        }

        fn first(_: *anyopaque) callconv(.c) void {
            const fds = testPipe();
            const r = register(fds[0]).?;
            test_pause.store(&pause, .seq_cst);
            const j = spawn(u8, Unit, waiter, .{r}, .{}, false).job;
            while (!pause.reached.load(.seq_cst)) yield();
            outer.cancel();
            pause.go.store(true, .seq_cst);
            _ = j.join();
            j.free();
            deregister(r);
            _ = std.posix.system.close(fds[0]);
            _ = std.posix.system.close(fds[1]);
        }
    };
    workers_override = 2;
    defer workers_override = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(!Run.waited);
    try std.testing.expectEqual(Readiness.canceled, Run.got);
}

fn testNap(ns: i96) void {
    const e = beginWait(false);
    commitWait(e, nowNs() + ns);
}

/// Spin, without yielding, until `flag` is set or 2 s pass, and give
/// whether it was set; with `ticks`, make a yield check each turn, as a
/// loop of a program does.
fn testSpinUntil(flag: *const std.atomic.Value(bool), ticks: bool) bool {
    const until = nowNs() + 2 * std.time.ns_per_s;
    while (!flag.load(.seq_cst)) {
        if (nowNs() >= until) return false;
        if (ticks) tick() else std.atomic.spinLoopHint();
    }
    return true;
}

test "a timer set earlier than a sleeping worker's wakes it, though the timer's own worker computes" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var done = std.atomic.Value(bool).init(false);
        var in_time = false;
        const Unit = struct {};
        fn napper(_: *Unit) u8 {
            testNap(10 * std.time.ns_per_ms);
            done.store(true, .seq_cst);
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            // Pinned, so the other worker cannot take it, and asleep a
            // while, so that worker sleeps with no deadline to wake for.
            _ = pinHere();
            _ = workersRunning();
            testNap(20 * std.time.ns_per_ms);
            const j = spawn(u8, Unit, napper, .{}, .{}, false).job;
            // The napper runs here, sets its timer on this worker, and
            // this fiber computes without a yield check.
            yield();
            in_time = testSpinUntil(&done, false);
            _ = j.join();
            j.free();
        }
    };
    workers_override = 2;
    defer workers_override = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(Run.in_time);
}

test "a lone worker's yield checks wake the fibers its timers and its poller make ready" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var napped = std.atomic.Value(bool).init(false);
        var read = std.atomic.Value(bool).init(false);
        var napped_in_time = false;
        var read_in_time = false;
        const Unit = struct {};
        fn napper(_: *Unit) u8 {
            testNap(10 * std.time.ns_per_ms);
            napped.store(true, .seq_cst);
            return 0;
        }
        fn reader(_: *Unit, r: *Registration) u8 {
            if (waitReady(r, Registration.readable, null, false) == .ready) read.store(true, .seq_cst);
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            const a = spawn(u8, Unit, napper, .{}, .{}, false).job;
            yield();
            napped_in_time = testSpinUntil(&napped, true);
            _ = a.join();
            a.free();
            const fds = testPipe();
            const r = register(fds[0]).?;
            const b = spawn(u8, Unit, reader, .{r}, .{}, false).job;
            yield();
            _ = std.posix.system.write(fds[1], "x", 1);
            read_in_time = testSpinUntil(&read, true);
            _ = b.join();
            b.free();
            deregister(r);
            _ = std.posix.system.close(fds[0]);
            _ = std.posix.system.close(fds[1]);
        }
    };
    workers_override = 1;
    defer workers_override = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(Run.napped_in_time);
    try std.testing.expect(Run.read_in_time);
}
