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
const split = rt.split;

// Unit 0 of a split build defines every cell of this file
// (`split.cell`).
comptime {
    if (split.on and split.main) _ = .{
        workers_len,
        workers_override,
        global,
        sleepers,
        searching,
        stopping,
        waiting,
        deterministic,
        seed_value,
        rng_state,
        virtual_now,
        ready,
        timers,
        watcher,
        registered,
        test_pause,
        kicking,
        retire_after,
        pool,
        spare,
        dense_spare,
        dense,
        dense_lists,
        home_lost,
        all_workers,
        grow_lock,
        started,
        workers_asked,
        graph,
        preempt_states,
        owing,
        watch_thread,
        watch_word,
        exit_state,
    };
}

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
    /// It runs on a dense stack when one can be had (`takeDense`): the
    /// compiler found nothing in it that needs a large one.
    dense: bool = false,
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

/// Give back a stack a task that panicked left to its boundary
/// (`abandon`, `tasks.Isolate`), to the running worker.
pub const giveStack = if (preempt) giveStackApart else giveStackIn;

/// `giveStack` in a program built to be preempted: never inlined into
/// the program's own code (`mustNotBeInCode`).
noinline fn giveStackApart(s: Stack) void {
    return giveStackIn(s);
}

fn giveStackIn(s: Stack) void {
    releaseStack(me().?, s);
}

/// What a worker does with the fiber that just switched away, once it has:
/// queue it again (`yield`), or record it as waiting (`park`).
const After = struct {
    run: *const fn (*Fiber, ?*anyopaque) void,
    ctx: ?*anyopaque = null,
};

/// A worker: its own stack pointer while a fiber runs, the fiber
/// running, its ring of ready fibers, its stacks to reuse, and the word it
/// sleeps on.
///
/// A worker begins a cache line and fills whole lines (`thread`'s
/// alignment), so no line holds two workers' fields: the fields each
/// writes at every switch never slow the other's.
const Worker = struct {
    sp: usize = 0,
    current: ?*Fiber = null,
    after: ?After = null,
    /// The running fiber's code runs on this worker's own stack now
    /// (`onWorkerStack`), and the fiber's stack pointer where it left.
    on_own_stack: bool = false,
    back_sp: usize = 0,
    ring: Ring = .{},
    /// The fibers to run next: the ones this worker's fibers last made
    /// ready, still in cache, in a circle whose newest is at `lifo_head`.
    /// A fiber made ready takes the slot after the newest, which holds
    /// the oldest or nothing, by one swap; the oldest it displaces goes to
    /// the ring. This worker takes the newest, at most `lifo_limit` times
    /// in a row; a worker with nothing else to steal takes the oldest
    /// once it has waited there a while (`stealNext`), as Go's `runnext`.
    /// A task made and waited for runs at once while it is still in a
    /// slot (`handoff`), so a fiber that makes several and waits for each
    /// in turn waits behind none of the ring's. Whoever moves a slot from
    /// a fiber to null by one atomic step owns that fiber, as with one
    /// slot.
    lifo: [run_next_slots]std.atomic.Value(?*Fiber) = @splat(.init(null)),
    /// The slot of the newest fiber in `lifo`. Only this worker writes
    /// it; another reads it only to find the oldest, which its
    /// compare-and-swap on the slot then confirms.
    lifo_head: std.atomic.Value(u8) = .init(0),
    lifo_streak: u8 = 0,
    /// The large stacks it keeps free and has yet to run a fiber on.
    stacks: StackList = .{},
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
    /// Set while a yield check wakes the fibers its timers and poller
    /// make ready, which it then yields to (`wake`).
    servicing: bool = false,
    /// The next worker asleep (`Sleepers`).
    next_sleeper: ?*Worker = null,
    searching: bool = false,
    rng: u32 = 1,
    /// What it did, which `RIG_SCHED_STATS=1` prints as `main` ends
    /// (`printStats`): fibers it ran, of them pinned ones, fibers it
    /// stole, and times it slept. The watcher reads `slept` too
    /// (`watchWanted`).
    ran: u64 = 0,
    ran_pinned: u64 = 0,
    stole: u64 = 0,
    slept: std.atomic.Value(u64) = .init(0),
    /// Its `slept` as the watcher began its last watch.
    watch_mark: std.atomic.Value(u64) = .init(0),
    thread: ?std.Thread align(std.atomic.cache_line) = null,
};

/// How many of `all_workers` run tasks; set by `runMain`, and raised by
/// `task.workers` (`growWorkers`).
var workers_len_var: std.atomic.Value(usize) = .init(0);
const workers_len = split.cell(&workers_len_var, "sched.workers_len");

/// The workers, worker 0 first. Their number can grow under a reader, so
/// a reader calls this once and keeps the slice for its whole walk. A
/// worker in it may not have started: its ring and slots are empty, and
/// its poller is open.
inline fn workersNow() []Worker {
    return all_workers.*[0..workers_len.load(.acquire)];
}
threadlocal var me_slot_var: ?*Worker = null;
inline fn me_slot() *?*Worker {
    return split.local(&me_slot_var, "sched.me_slot");
}

/// This thread's worker. A fiber may resume on another thread after any
/// switch, and a compiler may reuse a thread-local's address within a
/// function, so every read goes through this call, which is never inlined.
noinline fn me() ?*Worker {
    if (preempt) mustNotBeInCode(@returnAddress());
    return me_slot().*;
}

/// Test only: how many workers `runMain` starts, in place of
/// `RIG_WORKERS` or the core count.
var workers_override_var: ?usize = null;
const workers_override = split.cell(&workers_override_var, "sched.workers_override");
var global_var: Global = .{};
const global = split.cell(&global_var, "sched.global");
var sleepers_var: Sleepers = .{};
const sleepers = split.cell(&sleepers_var, "sched.sleepers");
/// Workers looking for work to steal: a worker that makes work wakes a
/// sleeping one only when none is looking.
var searching_var: Flag = .{};
const searching = split.cell(&searching_var, "sched.searching");
var stopping_var: OnLine(bool) = .{};
const stopping = split.cell(&stopping_var, "sched.stopping");
/// Set when work is made while every worker is busy, or a fiber that
/// goes on running fills its worker's "run next" slot (`wake`); the first
/// yield check to see it clears it and takes that work (`claimWaiting`),
/// and a worker that finds no work and sleeps clears it too; either sets
/// it again while another worker's "run next" slot holds a fiber
/// (`takeWaiting`). A recursive call only reads it (`rt.tickCall`), on a
/// cache line of its own, so what the scheduler writes beside it never
/// slows those reads.
var waiting_var: Flag = .{};
pub const waiting = split.cell(&waiting_var, "sched.waiting");

/// An atomic the scheduler's workers write, or read at every step, on a
/// cache line of its own: what any other thread writes beside it never
/// slows it, wherever the linker puts it (the size of a type with an
/// aligned field is a multiple of that alignment, so nothing follows it on
/// its line).
fn OnLine(comptime T: type) type {
    return struct {
        value: std.atomic.Value(T) align(std.atomic.cache_line) = .init(std.mem.zeroes(T)),

        const Self = @This();

        pub fn load(f: *const Self, comptime order: std.builtin.AtomicOrder) T {
            return f.value.load(order);
        }
        fn store(f: *Self, v: T, comptime order: std.builtin.AtomicOrder) void {
            f.value.store(v, order);
        }
        fn swap(f: *Self, v: T, comptime order: std.builtin.AtomicOrder) T {
            return f.value.swap(v, order);
        }
        fn fetchAdd(f: *Self, v: T, comptime order: std.builtin.AtomicOrder) T {
            return f.value.fetchAdd(v, order);
        }
        fn fetchSub(f: *Self, v: T, comptime order: std.builtin.AtomicOrder) T {
            return f.value.fetchSub(v, order);
        }
    };
}
const Flag = OnLine(u32);

/// The fiber running on this thread, or none outside every fiber.
pub inline fn current() ?*Fiber {
    if (preempt) return @call(.never_inline, currentOf, .{});
    return currentOf();
}

fn currentOf() ?*Fiber {
    // Under preemption its own read of the slot, with no check: this call
    // is never inlined into the program's code.
    const w = (if (preempt) me_slot().* else me()) orelse return null;
    return w.current;
}

/// Make `f` ready to run, next on this worker: in its "run next" slot,
/// whose fiber before it moves to the ring, where it waits behind `f`,
/// so a worker asleep is woken for that one when none is looking
/// (`notifyNew`). Filling the slot wakes no worker: this one runs `f`
/// next when it woke `f` itself, from its poller or a timer as it looks
/// for work, at a task's end, or at a yield check, which yields to it
/// when no idle worker could take it (`servicing`, `leftToIdle`); and a
/// fiber that woke `f` and goes on running either stops soon, as one that
/// sends and then waits for the answer does, or reaches a yield check,
/// which hands `f` on, so a worker woken for it at once would mostly find
/// it gone. So two tasks that answer each other stay on one worker, and
/// fork-join (`t = f()&; g(); >t`) spreads at `g`'s first yield check,
/// loop or recursive (`waiting`), which wakes an idle worker for `f` and
/// lets `g` run on. In a build preempted by signal, which has no yield
/// checks, a worker that switches to a fiber while others wait in its
/// slots wakes one (`spread`), and a maker that goes on computing hands
/// `f` on at the monitor's stop (`afterPreempt`). A worker that
/// searches also takes a fiber left in a busy worker's slot a while
/// (`stealNext`). Outside the workers, `f` goes to the global queue.
pub const wake = if (preempt) wakeApart else wakeIn;

/// `wake` in a program built to be preempted: never inlined into
/// the program's own code (`mustNotBeInCode`).
noinline fn wakeApart(f: *Fiber) void {
    return wakeIn(f);
}

fn wakeIn(f: *Fiber) void {
    if (deterministic.*) return ready.append(std.heap.smp_allocator, f) catch rt.oom();
    const here = me();
    if (f.home) |home| if (home != here) return wakeHome(f, home);
    const w = here orelse {
        global.push(f);
        return notifyNew();
    };
    // Into the slot after the newest, which holds the oldest or nothing:
    // the oldest goes to the ring.
    const i = (w.lifo_head.raw +% 1) % run_next_slots;
    w.lifo_head.store(i, .monotonic);
    if (w.lifo[i].swap(f, .seq_cst)) |b| {
        if (b.home != null) w.pinned.push(b) else {
            _ = w.ring.push(b);
            return notifyNew();
        }
    }
    if (f.home != null or w.current == null or w.servicing) return;
    // After the slot is filled, so a worker that cleared `waiting` either
    // sees the slot full or sees the flag clear here (`takeWaiting`).
    if (waiting.load(.seq_cst) == 0) waiting.store(1, .monotonic);
}

/// Make `f` ready to run after the fibers already ready on this worker,
/// waking a sleeping worker only when other work waits here, ahead of
/// `f`, which one could take meanwhile: a fiber alone, as a lone task's
/// `task.check()` yields, runs again next.
const wakeLast = if (preempt) wakeLastApart else wakeLastIn;

/// `wakeLast` in a program built to be preempted: never inlined into
/// the program's own code (`mustNotBeInCode`).
noinline fn wakeLastApart(f: *Fiber) void {
    return wakeLastIn(f);
}

fn wakeLastIn(f: *Fiber) void {
    if (deterministic.*) return wakeIn(f);
    if (f.home) |home| return wakeHome(f, home);
    const w = me() orelse {
        global.push(f);
        return notify();
    };
    // Only these could another worker take: pinned fibers stay, and the
    // global queue's push wakes one itself.
    if (w.ring.push(f) or nextHeld(w, .monotonic)) notify();
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
pub const pinHere = if (preempt) pinHereApart else pinHereIn;

/// `pinHere` in a program built to be preempted: never inlined into
/// the program's own code (`mustNotBeInCode`).
noinline fn pinHereApart() ?*Worker {
    return pinHereIn();
}

fn pinHereIn() ?*Worker {
    if (deterministic.*) return null;
    const w = me() orelse return null;
    w.current.?.home = w;
    return w;
}

/// Let other fibers run, then go on.
pub const yield = if (preempt) yieldApart else yieldIn;

noinline fn yieldApart() void {
    yieldIn();
}

fn yieldIn() void {
    stopIn(.{ .run = requeue });
}

fn requeue(f: *Fiber, _: ?*anyopaque) void {
    wakeLastIn(f);
}

/// A yield check of a loop (`rt.turn`): yield when other work waits
/// for this worker, in its "run next" slot or ring, or in the global
/// queue, or take work that waits for a busy one (`claimWaiting`). Work
/// a sleeping or searching worker can take is left to it.
pub noinline fn tick() void {
    const w = me() orelse return;
    // Deterministic: computing costs virtual time, which wakes the fibers
    // whose timers it reaches, as a busy worker's check does, and the
    // seed decides whether to yield to ready work.
    if (deterministic.*) {
        computed();
        fireDue();
        if (ready.items.len > 0 and random(2) == 0) yield();
        return;
    }
    // Timers and the poller are serviced on the worker's stack, after a
    // stop, as a preempted fiber's are (`afterTick`): `Poller.poll`'s
    // frame is a task's deepest, and a check reaches it at most every
    // `poll_interval`.
    if (serviceNow(w)) return stopIn(.{ .run = afterTick });
    if (hasOwnWork(w)) {
        if (leftToIdle(w)) return;
        return yield();
    }
    if (waiting.load(.monotonic) != 0) claimWaiting(w);
}

/// On the worker's stack, after a yield check's stop (`tick`): service
/// the worker's timers and poller (`serviceBusy`), then go on as the
/// check would: behind the work that waits (`yield`), or else run `f`
/// again next, from the worker's newest "run next" slot (`wakeIn`).
fn afterTick(f: *Fiber, _: ?*anyopaque) void {
    const w = me().?;
    serviceBusy(w);
    if (yieldsAfterService(w)) wakeLastIn(f) else wakeIn(f);
}

/// Whether a check of the busy worker `w` has timers due or its poller to
/// look at (`serviceBusy`). It reads the clock only when `w` holds a timer
/// or a descriptor, so a loop that holds neither pays two loads.
fn serviceNow(w: *Worker) bool {
    const due = w.timers.due.load(.monotonic);
    const polls = w.poller.count.load(.monotonic) != 0;
    if (due == no_due and !polls) return false;
    const now = nowNs();
    return due <= now or (polls and now - w.polled_at >= poll_interval);
}

/// What a check decides on the worker's stack once it has serviced the
/// worker (`afterTick`, `afterPreempt`): whether the stopped fiber goes
/// behind the work that waits, for this worker or for another busy one,
/// taken into this worker's ring (`stealWaiting`), as `tick` and
/// `claimWaiting` decide on the fiber's stack.
fn yieldsAfterService(w: *Worker) bool {
    if (hasOwnWork(w)) return !leftToIdle(w);
    if (waiting.load(.monotonic) == 0 or !takeWaiting(w) or !othersWait(w)) return false;
    if (leftToIdle(w)) {
        waiting.store(1, .monotonic);
        return false;
    }
    return stealWaiting(w);
}

/// Whether work that waits on the busy worker `w`, or for any busy one
/// (`claimWaiting`), is left to a worker with nothing to do, which is woken for it, rather
/// than displacing the fiber running here: so a task that makes tasks
/// goes on running while idle workers take them, as Go's `go` leaves its
/// maker running and wakes an idle processor. Only while they keep up,
/// with no more than the fiber in `w`'s "run next" slot waiting here: a
/// burst of tasks that fills its ring runs here, where its maker waits
/// for it, cheaper than spread over cores. Not when every worker is busy,
/// nor for pinned work, which only `w` may run. A worker woken or looking
/// may miss a fiber in a "run next" slot, which no sleeper looks in
/// (`takeWaiting`): a loop's next check sees it still there, and a check
/// that took `waiting`'s notice to leave it sets the notice again, so the
/// next check wakes one again or yields to it.
fn leftToIdle(w: *Worker) bool {
    if (w.pinned.count.load(.seq_cst) != 0 or !w.ring.isEmpty()) return false;
    if (searching.load(.seq_cst) != 0) return true;
    if (sleepers.count.load(.seq_cst) == 0) return false;
    notify();
    return true;
}

/// How often at most a busy worker's yield checks look at its poller: a
/// look is a system call, and a descriptor's readiness waits this long
/// at worst while every worker computes.
const poll_interval: i96 = 250 * std.time.ns_per_us;

/// The service of the busy worker `w` at a yield check or a preemption
/// stop, on the worker's stack (`afterTick`, `afterPreempt`): wake the
/// fibers whose timers are due on it, and those its poller's events make
/// ready, looking at the poller at most every `poll_interval`.
fn serviceBusy(w: *Worker) void {
    const due = w.timers.due.load(.monotonic);
    const polls = w.poller.count.load(.monotonic) != 0;
    if (due == no_due and !polls) return;
    w.servicing = true;
    defer w.servicing = false;
    const now = nowNs();
    if (due <= now) _ = w.timers.fire(now);
    if (polls and now - w.polled_at >= poll_interval) {
        w.polled_at = now;
        _ = w.poller.poll(0);
    }
}

/// A waiting point of the running fiber (`rt.checkStop`), in a build with
/// signal preemption: if a signal found the fiber outside the program's
/// code or under a lock since its last one (`Pre.owed`), run the yield
/// check that signal asked for. A task that spends its time in system
/// calls and the runtime, as a loop of `file.read` does, is rarely
/// stopped in its own code, and without this held its worker, and the
/// timers due on it, for seconds. Every call that reaches the file
/// system or a socket begins at a waiting point.
pub noinline fn atWaitingPoint() void {
    if (!preempt) return;
    const w = me() orelse return;
    const p = preOf(w);
    if (p.no_preempt != 0 or !p.owed.swap(false, .monotonic)) return;
    _ = owing.fetchSub(1, .monotonic);
    tick();
}

/// A slow path of the runtime's, the allocator's or a List's growth, about
/// to return to `at`, in a build with signal preemption: if `at` is in
/// the program's code, where a signal may stop the fiber at any
/// instruction, run the yield check a signal left owed there
/// (`atWaitingPoint`). A loop that allocates spends its time in the
/// runtime, where signals stop nothing. Anywhere else the caller may hold
/// the worker's state, so nothing runs. Called only on those rare paths.
pub noinline fn settleAt(at: usize) void {
    if (!preempt or owing.load(.monotonic) == 0 or !inCode(at)) return;
    atWaitingPoint();
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
    if (!takeWaiting(w)) return;
    // Left to an idle worker, the notice stands: the fiber waits in a
    // slot no sleeper looks in, and only `waiting` keeps it in sight
    // (`takeWaiting`) until a worker takes it. A notice of work already
    // gone, as a task made and handed its worker at once leaves, ends
    // here.
    if (!hasOwnWork(w) and !othersWait(w)) return;
    if (leftToIdle(w)) return waiting.store(1, .monotonic);
    if (hasOwnWork(w) or stealWaiting(w)) yield();
}

/// Take into `w`'s ring work that waits for another busy worker, as
/// `claimWaiting` does: half of another's ring, or the fiber in another's
/// "run next" slot; whether any was taken. A preempted fiber's
/// (`afterPreempt`), which then holds the fiber rather than yield.
fn stealWaiting(w: *Worker) bool {
    const ws = workersNow();
    if (ws.len < 2) return false;
    for (ws) |*v| {
        if (v == w) continue;
        if (w.ring.stealFrom(&v.ring)) |f| {
            w.stole += 1;
            _ = w.ring.push(f);
            return true;
        }
    }
    for (ws) |*v| {
        if (v == w) continue;
        if (takeNext(v)) |f| {
            _ = w.ring.push(f);
            return true;
        }
    }
    return false;
}

/// Whether work waits in a busy worker's queues other than `w`'s: its
/// "run next" slot or its ring.
fn othersWait(w: *Worker) bool {
    for (workersNow()) |*v| {
        if (v != w and (nextHeld(v, .monotonic) or !v.ring.isEmpty())) return true;
    }
    return false;
}

fn hasOwnWork(w: *Worker) bool {
    return nextHeld(w, .monotonic) or !w.ring.isEmpty() or w.pinned.count.load(.seq_cst) != 0 or global.count.load(.monotonic) != 0;
}

// -----------------------------------------------------------------------------
// Preemption
// -----------------------------------------------------------------------------
//
// A program built to be preempted has no yield checks
// (`rt.preempt`): a monitor thread looks at the workers every `Monitor`
// period, and one that has run the same fiber for a slice while other
// work waits for it, or whose timers are due or whose poller holds
// events, gets SIGURG. Its handler stops the fiber only where that is
// safe: the program counter in the program's own code (`preempt_section`,
// which the compiler puts every function of Rig source in), on a stack
// with room for the trampoline. It then makes the fiber return into
// `preemptEntry`, as if called there: the trampoline saves every
// register the interrupted code may hold, the flags, and the vector and
// x87 state, and switches to the worker's own stack (`preemptSwitch`),
// where `afterPreempt` runs what `tick` would and puts the fiber in the
// global queue, or runs it again next; when the fiber runs again, the
// trampoline returns to the instruction it stopped at with all of them
// restored. So a stop needs only the trampoline's save on the fiber's
// stack (`preempt_room`).
//
// Any worker may take a fiber stopped so: the program's own code keeps
// nothing of its worker in a register, since the scheduler's code that
// reads its worker is never inlined into it (`current`,
// `mustNotBeInCode`), and the thread-local it reads (`rt.task`'s) is used
// only outside every fiber. A program that makes a local task is not
// built to be preempted (`bin/rig` keeps its yield checks): local tasks
// share counts that are not atomic and take turns at their waits and
// yield checks, where none is half-changed.

/// Whether this build can be preempted by signal:
/// a target whose signal context and trampoline are written here, and
/// LLVM's backend, whose assembler takes the trampoline (Zig's own x86_64
/// backend, which a debug build for Linux uses, takes neither `xsave`
/// nor `ret $n`): Linux on x86-64, and macOS on arm64 with x15 reserved
/// (`+reserve_x15`, which `bin/rig` passes), the register the trampoline
/// returns by, since no arm64 instruction branches to an address in
/// memory. Elsewhere a program built so keeps its yield checks.
pub const preempt_built = builtin.zig_backend == .stage2_llvm and switch (builtin.cpu.arch) {
    .x86_64 => builtin.os.tag == .linux,
    .aarch64 => builtin.os.tag == .macos and std.Target.aarch64.featureSetHas(builtin.cpu.features, .reserve_x15),
    else => false,
};

/// The section of the program's own code, the only code a signal stops a
/// task in.
pub const preempt_section = if (builtin.object_format == .macho) "__TEXT,__rig_text" else "rig_text";

const preempt = rt.preempt;
/// Whether the program is built to be preempted, for alloc.zig's locks.
pub const preempting = preempt;

/// The bounds of `preempt_section`: on ELF, the symbols the linker
/// defines, weak, since a program all of whose code the optimizer inlined
/// into the runtime's has no such section, and is never stopped; on
/// Mach-O, whose linker defines none, the section's place in the loaded
/// image, which `findCode` reads before any fiber runs.
const code_start = if (preempt and !macho) @extern(?*const u8, .{ .name = "__start_rig_text", .linkage = .weak }) else {};
const code_end = if (preempt and !macho) @extern(?*const u8, .{ .name = "__stop_rig_text", .linkage = .weak }) else {};
const macho = builtin.object_format == .macho;
var code_lo: usize = 0;
var code_hi: usize = 0;

inline fn inCode(pc: usize) bool {
    if (macho) return pc >= code_lo and pc < code_hi;
    return pc >= @intFromPtr(code_start) and pc < @intFromPtr(code_end);
}

extern "c" fn getsectiondata(header: *const anyopaque, segment: [*:0]const u8, section: [*:0]const u8, size: *c_ulong) ?[*]const u8;
extern "c" fn _dyld_get_image_header(image: u32) ?*const anyopaque;

/// Read where the loaded image holds `preempt_section`, on Mach-O: in
/// the executable, dyld's first image.
fn findCode() void {
    if (!macho) return;
    const header = _dyld_get_image_header(0) orelse return;
    var size: c_ulong = 0;
    const at = getsectiondata(header, "__TEXT", "__rig_text", &size) orelse return;
    code_lo = @intFromPtr(at);
    code_hi = code_lo + size;
}

/// What preemption keeps for each worker, beside its `Worker`, which
/// stays as it is in a program not built to be preempted.
var preempt_states_var: [max_workers]Preempt = @splat(.{});
const preempt_states = split.cell(&preempt_states_var, "sched.preempt_states");

/// How many workers owe a yield check (`Preempt.owed`): what `settleAt`
/// reads first, one load of a word no worker writes until a signal leaves
/// a check owed, so a slow path that finds none owed pays nothing more.
var owing_var: Flag = .{};
const owing = split.cell(&owing_var, "sched.owing");

/// A signal left the yield check it asked for owed on `w`.
fn owe(w: *Worker) void {
    // A flag the worker's own thread sets and clears, not a lock:
    // uncounted for preemption.
    if (!preOf(w).owed.swap(true, .monotonic)) _ = owing.fetchAdd(1, .monotonic);
}

inline fn preOf(w: *const Worker) *Preempt {
    return &preempt_states[(@intFromPtr(w) - @intFromPtr(all_workers.*.ptr)) / @sizeOf(Worker)];
}

/// What preemption keeps for a worker.
const Preempt = struct {
    /// Its thread, to signal (`rt.threadId`). Each worker's begins a
    /// cache line, as a `Worker` does.
    tid: usize align(std.atomic.cache_line) = 0,
    /// How many fibers it has started running: the monitor sees it run
    /// one fiber for as long as this stays the same.
    runs: std.atomic.Value(u32) = .init(0),
    /// Fibers it preempted, and the signals the monitor sent it.
    preempts: u64 = 0,
    signals: std.atomic.Value(u64) = .init(0),
    /// Signals that found the program counter outside the program's code,
    /// or too little stack for the trampoline.
    outside: u64 = 0,
    cramped: u64 = 0,
    /// The stack pointer the last signal stopped a fiber at, and the most
    /// any stop then took of the fiber's stack, from there to the switch
    /// to the worker's stack: what `preempt_room` has to hold
    /// (test/cli/preempt.sh).
    stopped_sp: usize = 0,
    deepest: usize = 0,
    /// Held while the monitor signals its thread, and as the thread
    /// leaves, which clears `tid` (`leavePreempt`): a thread is never
    /// signaled once it has ended.
    signaling: SpinLock = .{},
    /// Locks it holds (`holdOff`): while any is held, no signal stops
    /// the fiber holding it.
    no_preempt: u32 = 0,
    held_off: u64 = 0,
    /// A signal found the fiber outside the program's code or under a
    /// lock, so the yield check it asked for is owed: the fiber's next
    /// waiting point runs it (`atWaitingPoint`). Set and cleared on the
    /// worker's own thread, by the handler and by the fiber.
    owed: std.atomic.Value(bool) = .init(false),
    /// Where the last signals it declined found the fiber, in turn, for
    /// `RIG_SCHED_STATS=1` to name: a long wait for a stop is traced to
    /// the function that held it (test/cli/preempt_cover.sh).
    declined_at: [8]usize = @splat(0),
    declined_n: u32 = 0,
};

/// Note that a signal to `w` was declined at `pc`.
fn declined(w: *Worker, pc: usize) void {
    const pre = preOf(w);
    pre.declined_at[pre.declined_n % pre.declined_at.len] = pc;
    pre.declined_n +%= 1;
}

/// A lock is taken on this thread: no signal stops its fiber until it is
/// let go (`holdOn`). Every spin lock and the output lock count. The
/// optimizer may inline a lock's code into the program's own
/// (`preempt_section`); the count goes through this call, never inlined,
/// to this thread's worker, and a lock is never held across a switch, so
/// it is taken and let go on one thread.
pub noinline fn holdOff() void {
    if (!preempt) return;
    if (me_slot().*) |w| preOf(w).no_preempt += 1;
}

/// A lock `holdOff` counted is let go.
pub noinline fn holdOn() void {
    if (!preempt) return;
    if (me_slot().*) |w| preOf(w).no_preempt -|= 1;
}

/// The signal the monitor stops a fiber by. SIGURG, as Go's: the system
/// sends it only to a process that asks for out-of-band data, and a
/// program that does not handle it ignores it.
const preempt_signal: std.posix.SIG = .URG;

/// The room below the stack pointer a stop needs on the fiber's stack:
/// the red zone, the trampoline's save of the registers, and the few
/// frames that switch to the worker's stack (`preemptSwitch`, `stopIn`,
/// `switchTo`), which decides there (`afterPreempt`). A debug build's
/// frames are larger, and `RIG_PREEMPT_TRACE`'s walk runs on the fiber's
/// stack, so those keep the old 32 KiB.
const trampoline_room: usize = switch (builtin.cpu.arch) {
    .x86_64 => 136 + 96 + 64 + std.mem.alignForward(usize, vector_state.size, 64),
    .aarch64 => 144 + 720,
    else => 0,
};
const preempt_room: usize = if (builtin.mode == .debug) 32 << 10 else trampoline_room + (2 << 10);

fn installPreempt() void {
    findCode();
    const act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = onPreempt },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO | std.posix.SA.ONSTACK | std.posix.SA.RESTART,
    };
    std.posix.sigaction(preempt_signal, &act, null);
}

/// Linux x86-64's `ucontext_t`, as far as its registers: the general
/// registers start at byte 40, the stack pointer 15th and the program
/// counter 16th of them (`REG_RSP`, `REG_RIP`).
const linux_rsp = 40 + 15 * 8;
const linux_rip = 40 + 16 * 8;

/// macOS arm64's `ucontext_t`: a pointer to its machine context at byte
/// 48, whose registers x0-x28, fp, lr and sp start at byte 16 and whose
/// pc follows them, at 272 (<sys/_types/_ucontext.h>,
/// <mach/arm/_structs.h>). The target is arm64, not arm64e: the pc and
/// sp there are plain addresses, unsigned.
const darwin_mcontext = 48;
const darwin_fp = 16 + 29 * 8;
const darwin_sp = 16 + 31 * 8;
const darwin_pc = 16 + 32 * 8;

/// The red zone below the stack pointer, which the code a signal stops
/// may use and the trampoline steps over: 128 bytes on both targets.
const red_zone = 128;

/// SIGURG: stop the running fiber where it is, if it is safe to, by
/// making it call `preemptEntry`. Async-signal-safe: it reads this
/// thread's worker and the fiber's stack bounds, and writes one word on
/// the fiber's stack below its red zone.
fn onPreempt(_: std.posix.SIG, _: *const std.posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    const uc: [*]u8 = @ptrCast(ctx orelse return);
    const w = me_slot().* orelse return;
    const f = w.current orelse return;
    const regs: [*]u8 = if (macho) @as(*const [*]u8, @ptrCast(@alignCast(uc + darwin_mcontext))).* else uc;
    const pc_at: *usize = @ptrCast(@alignCast(regs + if (macho) darwin_pc else linux_rip));
    const sp_at: *usize = @ptrCast(@alignCast(regs + if (macho) darwin_sp else linux_rsp));
    const pc = pc_at.*;
    const sp = sp_at.*;
    if (!inCode(pc)) {
        preOf(w).outside += 1;
        declined(w, pc);
        owe(w);
        return;
    }
    if (preOf(w).no_preempt != 0) {
        preOf(w).held_off += 1;
        declined(w, pc);
        owe(w);
        return;
    }
    // Room for the trampoline above the guard, and this handler on its
    // own stack, not below the fiber's stack pointer.
    const guard = f.state.stack_guard;
    const here = @frameAddress();
    const room: usize = if (preempt_trace) 32 << 10 else preempt_room;
    if ((guard.hi != 0 and sp < guard.hi + room) or (here < sp and here > sp -| (8 << 20))) {
        preOf(w).cramped += 1;
        return;
    }
    // The stopped instruction's address below the red zone, as a call
    // would leave it. On arm64, a frame record just below the stack
    // pointer, the stopped frame pointer then the stopped pc, as if the
    // stopped instruction had called the trampoline; the 16 bytes of the
    // red zone it covers are kept in a slot below the red zone, which the
    // trampoline puts back as it returns (`preemptEntryArm`).
    const ret = sp - red_zone - if (builtin.cpu.arch == .aarch64) 16 else 8;
    if (builtin.cpu.arch == .aarch64) {
        const record: *[2]usize = @ptrFromInt(sp - 16);
        @as(*[2]usize, @ptrFromInt(ret)).* = record.*;
        record.* = .{ @as(*const usize, @ptrCast(@alignCast(regs + darwin_fp))).*, pc };
    } else @as(*usize, @ptrFromInt(ret)).* = pc;
    sp_at.* = ret;
    pc_at.* = @intFromPtr(&preemptEntry);
    preOf(w).stopped_sp = sp;
}

/// The vector and x87 state the trampoline saves: by `xsave`, x87, SSE,
/// and, as the target has them, AVX's upper halves and AVX-512's masks
/// and registers (components 0, 1, 2, 5, 6, 7, at their standard
/// offsets); by `fxsave`, x87 and SSE alone.
const vector_state: struct { size: usize, mask: u32, save: []const u8, restore: []const u8 } = blk: {
    if (!preempt) break :blk .{ .size = 0, .mask = 0, .save = "", .restore = "" };
    const has = std.Target.x86.featureSetHas;
    const fs = builtin.cpu.features;
    if (!has(fs, .xsave)) break :blk .{ .size = 512, .mask = 0, .save = "fxsave64 (%%rsp)", .restore = "fxrstor64 (%%rsp)" };
    const avx512 = has(fs, .avx512f);
    const avx = has(fs, .avx);
    break :blk .{
        .size = if (avx512) 2688 else if (avx) 832 else 576,
        .mask = if (avx512) 0xe7 else if (avx) 0x7 else 0x3,
        .save = "xsave64 (%%rsp)",
        .restore = "xrstor64 (%%rsp)",
    };
};

/// Where a preempted fiber resumes, entered with the program counter it
/// stopped at on top of its stack, 128 bytes (the red zone) below where
/// its stack pointer was. On x86-64 it pushes the frame pointer onto it,
/// making the frame record a call would leave, saves the flags and the
/// registers a call may change, clears the direction flag, saves the
/// vector state on a 64-byte boundary (its header zeroed, as `xrstor`
/// needs), calls `preemptSwitch`, restores all of it, and returns past the
/// red zone. A walk of frame pointers, and one by its unwind information,
/// goes on from it into the stopped code: its frame's canonical address
/// is the stopped stack pointer, and its return address the stopped pc.
fn preemptEntry() callconv(.naked) void {
    switch (builtin.cpu.arch) {
        .x86_64 => preemptEntryX86(),
        .aarch64 => preemptEntryArm(),
        else => comptime unreachable,
    }
}

inline fn preemptEntryX86() void {
    const size = comptime std.mem.alignForward(usize, vector_state.size, 64);
    const header = if (vector_state.mask == 0) "" else std.fmt.comptimePrint(
        \\ movq $0, {0d}(%%rsp)
        \\ movq $0, {1d}(%%rsp)
        \\ movq $0, {2d}(%%rsp)
        \\ movq $0, {3d}(%%rsp)
        \\ movq $0, {4d}(%%rsp)
        \\ movq $0, {5d}(%%rsp)
        \\ movq $0, {6d}(%%rsp)
        \\ movq $0, {7d}(%%rsp)
        \\ movl ${8d}, %%eax
        \\ xorl %%edx, %%edx
        \\
    , .{ 512, 520, 528, 536, 544, 552, 560, 568, vector_state.mask });
    const mask = if (vector_state.mask == 0) "" else std.fmt.comptimePrint(
        \\ movl ${d}, %%eax
        \\ xorl %%edx, %%edx
        \\
    , .{vector_state.mask});
    asm volatile (std.fmt.comptimePrint(
            \\ .cfi_def_cfa %%rsp, 136
            \\ .cfi_offset %%rip, -136
            \\ pushq %%rbp
            \\ .cfi_def_cfa_offset 144
            \\ .cfi_offset %%rbp, -144
            \\ movq %%rsp, %%rbp
            \\ .cfi_def_cfa_register %%rbp
            \\ pushfq
            \\ pushq %%rax
            \\ pushq %%rcx
            \\ pushq %%rdx
            \\ pushq %%rsi
            \\ pushq %%rdi
            \\ pushq %%r8
            \\ pushq %%r9
            \\ pushq %%r10
            \\ pushq %%r11
            \\ cld
            \\ andq $-64, %%rsp
            \\ subq ${d}, %%rsp
            \\
        , .{size}) ++ header ++ vector_state.save ++ "\n" ++
            \\ callq %[f:P]
            \\
        ++ mask ++ vector_state.restore ++ "\n" ++
            \\ leaq -80(%%rbp), %%rsp
            \\ popq %%r11
            \\ popq %%r10
            \\ popq %%r9
            \\ popq %%r8
            \\ popq %%rdi
            \\ popq %%rsi
            \\ popq %%rdx
            \\ popq %%rcx
            \\ popq %%rax
            \\ popfq
            \\ popq %%rbp
            \\ .cfi_def_cfa %%rsp, 136
            \\ retq $128
        :
        : [f] "X" (&preemptedC),
    );
}

/// The arm64 trampoline, entered with the stack pointer 144 bytes below
/// where it was stopped, at the 16 bytes of the red zone the handler
/// moved there, which a frame record replaced (`onPreempt`): the stopped
/// frame pointer, then the stopped instruction's address. It saves the
/// registers a call may change (x0-x17 but x15, x18 being Darwin's), the
/// frame pointer and link register, the flags, the floating-point status
/// and control, and all of q0-q31, points the frame pointer at the
/// record, calls `preemptSwitch`, restores them and the red zone, and returns
/// by x15, which code built to be preempted never uses (`+reserve_x15`).
/// A walk of frame pointers, and one by its unwind information, goes on
/// from it into the stopped code: its frame's canonical address is the
/// stopped stack pointer, and its return address is the record's, in
/// x15's column, so the stopped code's own link register stays its own.
inline fn preemptEntryArm() void {
    asm volatile (
        \\ .cfi_def_cfa sp, 144
        \\ .cfi_return_column x15
        \\ .cfi_offset x15, -8
        \\ .cfi_offset x29, -16
        \\ sub sp, sp, #720
        \\ .cfi_def_cfa_offset 864
        \\ stp x0, x1, [sp, #0]
        \\ stp x2, x3, [sp, #16]
        \\ stp x4, x5, [sp, #32]
        \\ stp x6, x7, [sp, #48]
        \\ stp x8, x9, [sp, #64]
        \\ stp x10, x11, [sp, #80]
        \\ stp x12, x13, [sp, #96]
        \\ stp x14, x16, [sp, #112]
        \\ stp x17, x29, [sp, #128]
        \\ str x30, [sp, #144]
        \\ .cfi_offset x30, -720
        \\ mrs x0, nzcv
        \\ mrs x1, fpsr
        \\ stp x0, x1, [sp, #152]
        \\ mrs x0, fpcr
        \\ str x0, [sp, #168]
        \\ stp q0, q1, [sp, #176]
        \\ stp q2, q3, [sp, #208]
        \\ stp q4, q5, [sp, #240]
        \\ stp q6, q7, [sp, #272]
        \\ stp q8, q9, [sp, #304]
        \\ stp q10, q11, [sp, #336]
        \\ stp q12, q13, [sp, #368]
        \\ stp q14, q15, [sp, #400]
        \\ stp q16, q17, [sp, #432]
        \\ stp q18, q19, [sp, #464]
        \\ stp q20, q21, [sp, #496]
        \\ stp q22, q23, [sp, #528]
        \\ stp q24, q25, [sp, #560]
        \\ stp q26, q27, [sp, #592]
        \\ stp q28, q29, [sp, #624]
        \\ stp q30, q31, [sp, #656]
        \\ add x29, sp, #848
        \\ bl %[f]
        \\ ldp q0, q1, [sp, #176]
        \\ ldp q2, q3, [sp, #208]
        \\ ldp q4, q5, [sp, #240]
        \\ ldp q6, q7, [sp, #272]
        \\ ldp q8, q9, [sp, #304]
        \\ ldp q10, q11, [sp, #336]
        \\ ldp q12, q13, [sp, #368]
        \\ ldp q14, q15, [sp, #400]
        \\ ldp q16, q17, [sp, #432]
        \\ ldp q18, q19, [sp, #464]
        \\ ldp q20, q21, [sp, #496]
        \\ ldp q22, q23, [sp, #528]
        \\ ldp q24, q25, [sp, #560]
        \\ ldp q26, q27, [sp, #592]
        \\ ldp q28, q29, [sp, #624]
        \\ ldp q30, q31, [sp, #656]
        \\ ldr x0, [sp, #168]
        \\ msr fpcr, x0
        \\ ldp x0, x1, [sp, #152]
        \\ msr nzcv, x0
        \\ msr fpsr, x1
        \\ ldr x30, [sp, #144]
        \\ ldp x17, x29, [sp, #128]
        \\ ldp x14, x16, [sp, #112]
        \\ ldp x12, x13, [sp, #96]
        \\ ldp x10, x11, [sp, #80]
        \\ ldp x8, x9, [sp, #64]
        \\ ldp x6, x7, [sp, #48]
        \\ ldp x4, x5, [sp, #32]
        \\ ldp x2, x3, [sp, #16]
        \\ ldr x15, [sp, #856]
        \\ ldr x0, [sp, #720]
        \\ ldr x1, [sp, #728]
        \\ str x0, [sp, #848]
        \\ str x1, [sp, #856]
        \\ ldp x0, x1, [sp, #0]
        \\ add sp, sp, #864
        \\ .cfi_def_cfa_offset 0
        \\ br x15
        :
        : [f] "X" (&preemptedC),
    );
}

fn preemptedC() callconv(.c) void {
    preemptSwitch();
}

/// A fiber the monitor's signal stopped (`preemptEntry`): do what a loop's
/// yield check does (`tick`), wake what its worker's timers and poller
/// make ready, and if work waits, for this worker or for another busy
/// one, go back in line behind it, in the global queue.
fn preemptSwitch() void {
    const w = me() orelse return;
    // A flag set once, not a lock: uncounted for preemption.
    if (preempt_trace and !preempt_traced.swap(true, .monotonic)) std.debug.dumpCurrentStackTrace(.{ .allow_unsafe_unwind = true });
    // A program built to be preempted makes no local task (`bin/rig`
    // keeps the yield checks of one that does), so no fiber is pinned;
    // one that were is never stopped, since its siblings share counts
    // that are not atomic and may run only at its waiting points.
    if (w.current.?.home != null) return;
    stopIn(.{ .run = afterPreempt });
}

/// On the worker's stack, after the stop (`preemptSwitch`): do what a
/// loop's yield check does (`tick`), wake what the worker's timers and
/// poller make ready, and if work waits, for this worker or for another
/// busy one, queue `f` behind it (`behind`); else run `f` again next,
/// from the worker's newest "run next" slot (`wakeIn`), where its
/// trampoline returns into the stopped code.
fn afterPreempt(f: *Fiber, _: ?*anyopaque) void {
    const w = me().?;
    preOf(w).deepest = @max(preOf(w).deepest, preOf(w).stopped_sp -| f.sp);
    serviceBusy(w);
    // Nothing to yield to: the fiber runs again next, from the newest of
    // the worker's "run next" slots, as one just woken would.
    if (!yieldsAfterService(w)) return wakeIn(f);
    preOf(w).preempts += 1;
    behind(f, null);
}

/// Queue the fiber `f` just preempted in the global queue, as Go does:
/// behind the fibers made or woken on any worker, which each worker runs
/// first, and the other preempted ones; a worker looks there every 61
/// turns and when its own queues are empty.
fn behind(f: *Fiber, _: ?*anyopaque) void {
    global.push(f);
    notify();
}

/// What `me` does when it is called from the program's own code, which
/// a signal may stop anywhere: such code could keep the worker it gave in
/// a register, and after a stop resume on another worker with it. The
/// scheduler's code that reads its worker is never inlined there
/// (`current`); a call that is panics, the first time it runs.
fn mustNotBeInCode(ret: usize) void {
    if (inCode(ret)) {
        @branchHint(.cold);
        @panic("rig: the scheduler's code was inlined into the program's, where a signal may stop it");
    }
}

// The monitor: a thread of its own, started with the workers.

/// The slice a fiber runs while other work waits before it is
/// preempted: 10 ms, as Go's, or `RIG_PREEMPT_SLICE_US` microseconds.
fn sliceNs() i96 {
    return envUs("RIG_PREEMPT_SLICE_US", 10_000);
}

/// The microseconds the environment variable `name` gives, else `default`,
/// in nanoseconds: the prototype's knobs.
fn envUs(comptime name: []const u8, default: u32) i96 {
    if (rt.process.*) |p| if (p.environ.getPosix(name)) |v| {
        const n = std.fmt.parseInt(u32, v, 10) catch 0;
        if (n > 0) return @as(i96, n) * std.time.ns_per_us;
    };
    return @as(i96, default) * std.time.ns_per_us;
}

/// `RIG_PREEMPT_TRACE=1`: the first fiber preempted prints the stack it
/// was stopped on, from `preemptSwitch` through the trampoline.
var preempt_trace = false;
var preempt_traced: std.atomic.Value(bool) = .init(false);

/// The monitor's thread, which `stopMonitor` joins as `main` ends,
/// before `runMain` frees the workers it reads; and the word it sleeps
/// on between looks, which `stopMonitor` changes to wake it.
var watch_thread_var: ?std.Thread = null;
const watch_thread = split.cell(&watch_thread_var, "sched.watch_thread");
var watch_word_var: std.atomic.Value(u32) = .init(0);
const watch_word = split.cell(&watch_word_var, "sched.watch_word");

fn startMonitor() void {
    if (rt.process.*) |p| preempt_trace = if (p.environ.getPosix("RIG_PREEMPT_TRACE")) |v| std.mem.eql(u8, v, "1") else false;
    installPreempt();
    watch_thread.* = std.Thread.spawn(.{ .stack_size = 64 << 10 }, watchSlices, .{ sliceNs(), envUs("RIG_PREEMPT_WAIT_US", 50) }) catch return;
}

/// As `main` ends, once `stopping` is set: wake the monitor and wait for
/// it to end, so it reads no worker after `runMain` frees them, and the
/// next run, in a test, starts a monitor of its own.
fn stopMonitor() void {
    const t = watch_thread.* orelse return;
    _ = watch_word.fetchAdd(1, .seq_cst);
    rt.io().futexWake(u32, &watch_word.raw, 1);
    t.join();
    watch_thread.* = null;
}

/// Every period: signal each worker that has run one fiber since the
/// last look while work waited for it all that time, work it had then
/// and has still, having started none since (so the work waits no more
/// than about two periods, as a yield check's turns let it); or that has
/// run one for a slice while any work waits (`workWaits`); or whose
/// timers are due or whose poller holds events. The period is the wait
/// (`RIG_PREEMPT_WAIT_US`, 50 µs) while any worker has work waiting, 1
/// ms while any runs a fiber, and twice as long each period every worker
/// spends without, up to 10 ms. It ends as `main` ends (`stopMonitor`).
fn watchSlices(slice: i96, wait: i96) void {
    var seen: [max_workers]u32 = @splat(0);
    var since: [max_workers]i96 = @splat(0);
    var had: [max_workers]bool = @splat(false);
    // Signals sent to each worker since it last switched, and when it is
    // signaled next once it has declined `resignal_free` of them.
    var tries: [max_workers]u32 = @splat(0);
    var next_at: [max_workers]i96 = @splat(0);
    var period: i96 = std.time.ns_per_ms;
    while (true) {
        const word = watch_word.load(.seq_cst);
        if (stopping.load(.seq_cst)) return;
        rt.io().futexWaitTimeout(u32, &watch_word.raw, word, .{ .duration = .{ .raw = .{ .nanoseconds = period }, .clock = .awake } }) catch {};
        if (stopping.load(.seq_cst)) return;
        const now = nowReal();
        var busy = false;
        var queued = false;
        for (workersNow(), 0..) |*w, i| {
            const runs = preOf(w).runs.load(.monotonic);
            const running = @atomicLoad(?*Fiber, &w.current, .monotonic) != null;
            const work = queuedHere(w);
            queued = queued or work;
            defer had[i] = work;
            if (!running or runs != seen[i]) {
                seen[i] = runs;
                since[i] = now;
                tries[i] = 0;
                busy = busy or running;
                continue;
            }
            busy = true;
            const waited = work and had[i];
            if (!waited and !serviceDue(w, now) and (now - since[i] < slice or !workWaits(w))) continue;
            // Again until it stops: a signal that finds the fiber outside
            // the program's code does nothing. After `resignal_free` in a
            // row, each waits twice as long as the one before, up to
            // `resignal_most`, so a worker in a long system call, or in
            // the runtime's code, is not interrupted every period.
            if (tries[i] >= resignal_free and now < next_at[i]) continue;
            tries[i] += 1;
            if (tries[i] >= resignal_free) next_at[i] = now + resignalAfter(tries[i], wait);
            _ = preOf(w).signals.fetchAdd(1, .monotonic);
            const pre = preOf(w);
            pre.signaling.lockApart();
            signalThread(pre.tid);
            pre.signaling.unlockApart();
        }
        period = if (queued) wait else if (busy) std.time.ns_per_ms else @min(2 * period, 10 * std.time.ns_per_ms);
    }
}

/// How many signals in a row the monitor sends a worker that declines
/// them, one a period, before it backs off (`watchSlices`).
const resignal_free = 4;

/// The longest the monitor waits between signals to a worker that keeps
/// declining them: a computation stopped late waits this long at most
/// past its slice, well inside what `test/cli/preempt_cover.sh` allows.
const resignal_most: i96 = std.time.ns_per_ms;

/// The wait before the signal after the `tries`th in a row to a worker
/// that declines them: `wait` doubled for each past `resignal_free`, up
/// to `resignal_most`.
fn resignalAfter(tries: u32, wait: i96) i96 {
    const shift: u6 = @intCast(@min(tries - resignal_free + 1, 16));
    return @min(wait << shift, resignal_most);
}

/// Whether work waits in `w`'s own queues: its "run next" slot, its
/// ring, and its pinned fibers, where fibers made or woken wait. Fibers
/// that were preempted wait in the global queue, which only the slice
/// hurries (`afterPreempt`).
fn queuedHere(w: *Worker) bool {
    return nextHeld(w, .monotonic) or !w.ring.isEmpty() or w.pinned.count.load(.monotonic) != 0;
}

/// Whether work waits that a preempted fiber of the busy worker `w` would
/// run: its own, or work that waits for a busy worker (`waiting`).
fn workWaits(w: *Worker) bool {
    return hasOwnWork(w) or waiting.load(.monotonic) != 0;
}

/// Whether the busy worker `w` has a timer due, or descriptors whose
/// poller holds events, which its own yield checks would have seen to.
fn serviceDue(w: *Worker, now: i96) bool {
    if (w.timers.due.load(.monotonic) <= now) return true;
    if (w.poller.count.load(.monotonic) == 0) return false;
    var fds = [1]std.posix.pollfd{.{ .fd = w.poller.fd, .events = std.posix.POLL.IN, .revents = 0 }};
    return (std.posix.poll(&fds, 0) catch 0) > 0;
}

fn sleepNs(ns: i96) void {
    if (builtin.os.tag == .linux) {
        const req: std.os.linux.timespec = .{ .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)), .nsec = @intCast(@mod(ns, std.time.ns_per_s)) };
        _ = std.os.linux.nanosleep(&req, null);
    } else {
        const req: std.c.timespec = .{ .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)), .nsec = @intCast(@mod(ns, std.time.ns_per_s)) };
        _ = std.c.nanosleep(&req, null);
    }
}

/// This thread, a worker, ends: once this returns the monitor no longer
/// signals it (`Preempt.signaling`).
fn leavePreempt(w: *Worker) void {
    if (!preempt) return;
    const pre = preOf(w);
    pre.signaling.lockApart();
    pre.tid = 0;
    pre.signaling.unlockApart();
}

fn signalThread(id: usize) void {
    if (id == 0) return;
    if (builtin.link_libc) {
        _ = std.c.pthread_kill(@ptrFromInt(id), preempt_signal);
    } else {
        _ = std.os.linux.tgkill(std.os.linux.getpid(), @intCast(id), preempt_signal);
    }
}

/// How many times in a row a worker runs its "run next" fiber before it
/// takes one from its ring, so two fibers waking each other cannot keep
/// the others waiting.
const lifo_limit = 3;

/// How many fibers a worker holds to run next (`Worker.lifo`): enough
/// that a fiber that makes a few tasks and waits for each runs them at
/// once, past the ring.
const run_next_slots = 4;

/// Whether any of `w`'s "run next" slots holds a fiber.
inline fn nextHeld(w: *Worker, comptime order: std.builtin.AtomicOrder) bool {
    // All four read, and one test: no branch for each slot.
    var any: usize = 0;
    inline for (&w.lifo) |*slot| any |= @intFromPtr(slot.load(order));
    return any != 0;
}

/// The slot of `w`'s "run next" circle that holds `f`, looked for by
/// plain loads from the newest back, where a task just made sits.
fn nextSlotOf(w: *Worker, f: *Fiber) ?u8 {
    // Most waits find their task elsewhere: one test for all four.
    var hit = false;
    inline for (&w.lifo) |*slot| hit = hit or slot.load(.monotonic) == f;
    if (!hit) return null;
    const head = w.lifo_head.load(.monotonic);
    var k: u8 = 0;
    while (k < run_next_slots) : (k += 1) {
        const i = (head +% run_next_slots -% k) % run_next_slots;
        if (w.lifo[i].load(.monotonic) == f) return i;
    }
    return null;
}

/// Whether `f` is in one of `w`'s "run next" slots.
fn nextHolds(w: *Worker, f: *Fiber) bool {
    return nextSlotOf(w, f) != null;
}

/// Take `f` from the slot of `w`'s that holds it, by one atomic step:
/// whether this took it. Called by `w`'s own fiber: when `f` was the
/// newest, the next made takes the slot it leaves.
fn takeFromNext(w: *Worker, f: *Fiber) bool {
    const i = nextSlotOf(w, f) orelse return false;
    if (w.lifo[i].cmpxchgStrong(f, null, .seq_cst, .monotonic) != null) return false;
    if (w.lifo_head.raw == i) w.lifo_head.store((i +% run_next_slots -% 1) % run_next_slots, .monotonic);
    return true;
}

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
pub const commitWait = if (preempt) commitWaitApart else commitWaitIn;

/// `commitWait` in a program built to be preempted: never inlined into
/// the program's own code, and one call in all (`mustNotBeInCode`).
noinline fn commitWaitApart(epoch: u32, deadline: ?i96) void {
    commitWaitIn(epoch, deadline);
}

fn commitWaitIn(epoch: u32, deadline: ?i96) void {
    const f = current().?;
    if (deadline) |d| {
        f.wait.deadline = d;
        f.wait.timer_epoch = epoch;
    }
    parkIn(.{ .run = fallAsleep, .ctx = if (deadline != null) @ptrFromInt(1) else null });
    // Awake: a timer still set for this wait is taken back, so none
    // touches this fiber once it goes on.
    if (deadline != null) if (f.wait.timers) |t| t.cancel(f);
}

/// Once the fiber has switched away: set its timer, then mark it asleep,
/// unless a waker has come first, when it goes on.
fn fallAsleep(f: *Fiber, timed: ?*anyopaque) void {
    if (timed != null) (if (deterministic.*) timers else &me().?.timers).add(f);
    const w = f.wait.word.load(.seq_cst);
    if (Wait.epochOf(w) == f.wait.epoch and w & Wait.states == Wait.about) {
        if (f.wait.word.cmpxchgStrong(w, (w & ~Wait.states) | Wait.asleep, .seq_cst, .seq_cst) == null) return;
    }
    wake(f);
}

/// End the wait `epoch` of `f`, if it is still on, and give whether this
/// call ended it. A cancel passes `cancel`, and ends only a wait that a
/// cancel may end.
pub const interrupt = if (preempt) interruptApart else interruptIn;

/// `interrupt` in a program built to be preempted: never inlined into
/// the program's own code (`mustNotBeInCode`).
noinline fn interruptApart(f: *Fiber, epoch: u32, cancel: bool) bool {
    return interruptIn(f, epoch, cancel);
}

fn interruptIn(f: *Fiber, epoch: u32, cancel: bool) bool {
    var w = f.wait.word.load(.seq_cst);
    while (true) {
        if (Wait.epochOf(w) != epoch) return false;
        const state = w & Wait.states;
        if (state == Wait.woken) return false;
        if (cancel and w & Wait.cancelable_bit == 0) return false;
        w = f.wait.word.cmpxchgWeak(w, (w & ~Wait.states) | Wait.woken, .seq_cst, .seq_cst) orelse {
            if (state == Wait.asleep) wakeIn(f);
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
pub const interruptForCancel = if (preempt) interruptForCancelApart else interruptForCancelIn;

/// `interruptForCancel` in a program built to be preempted: never
/// inlined into the program's own code (`mustNotBeInCode`).
noinline fn interruptForCancelApart(f: *Fiber) void {
    interruptForCancelIn(f);
}

fn interruptForCancelIn(f: *Fiber) void {
    _ = interruptIn(f, Wait.epochOf(f.wait.word.load(.seq_cst)), true);
}

/// The fibers waiting for one condition that another fiber or thread
/// makes true: a slot of an actor's mailbox coming free, the last task
/// of an isolate ending, a descriptor becoming ready. A lock the caller
/// keeps guards the list and the condition. A waiter looks at the
/// condition and lists itself under it (`sleepOn`); a waker makes the
/// condition true, then, under it, takes fibers off the list and wakes
/// them (`wakeOne`, `wakeAll`). A woken fiber takes the lock before it
/// goes on, so no waker touches its entry after, and its entry says
/// whether a waker took it off or a timer or a cancel woke it.
pub const Waiters = struct {
    first: ?*Node = null,
    last: ?*Node = null,

    /// A waiting fiber's entry, in its own frame.
    const Node = struct {
        fiber: *Fiber,
        epoch: u32,
        prev: ?*Node = null,
        next: ?*Node = null,
        listed: bool = true,
    };

    fn remove(ws: *Waiters, n: *Node) void {
        if (!n.listed) return;
        n.listed = false;
        if (n.prev) |p| p.next = n.next else ws.first = n.next;
        if (n.next) |x| x.prev = n.prev else ws.last = n.prev;
    }

    /// Wake the fiber waiting longest, taking it off; whether there was
    /// one whose wait this ended.
    pub const wakeOne = if (preempt) wakeOneApart else wakeOneIn;

    /// `wakeOne` in a program built to be preempted: never inlined into
    /// the program's own code (`mustNotBeInCode`).
    noinline fn wakeOneApart(ws: *Waiters) bool {
        return wakeOneIn(ws);
    }

    fn wakeOneIn(ws: *Waiters) bool {
        while (ws.first) |n| {
            ws.remove(n);
            if (interruptIn(n.fiber, n.epoch, false)) return true;
        }
        return false;
    }

    /// Wake every fiber listed; whether there was one.
    pub const wakeAll = if (preempt) wakeAllApart else wakeAllIn;

    /// `wakeAll` in a program built to be preempted: never inlined into
    /// the program's own code (`mustNotBeInCode`).
    noinline fn wakeAllApart(ws: *Waiters) bool {
        return wakeAllIn(ws);
    }

    fn wakeAllIn(ws: *Waiters) bool {
        var any = false;
        while (wakeOneIn(ws)) any = true;
        return any;
    }
};

/// Sleep on `ws` under `lock`, which the caller holds and holds again
/// when this returns, until a waker takes the running fiber off the list,
/// `deadline` passes, or, when `cancelable`, its task is canceled:
/// whether a waker took it off.
pub const sleepOn = if (preempt) sleepOnApart else sleepOnIn;

/// `sleepOn` in a program built to be preempted: never inlined into the
/// program's own code (`mustNotBeInCode`).
noinline fn sleepOnApart(ws: *Waiters, lock: *SpinLock, deadline: ?i96, cancelable: bool) bool {
    return sleepOnIn(ws, lock, deadline, cancelable);
}

fn sleepOnIn(ws: *Waiters, lock: *SpinLock, deadline: ?i96, cancelable: bool) bool {
    const f = current().?;
    var n: Waiters.Node = .{ .fiber = f, .epoch = beginWait(cancelable), .prev = ws.last };
    if (ws.last) |l| l.next = &n else ws.first = &n;
    ws.last = &n;
    lock.unlock();
    // A cancel that came before the wait began found no wait to end.
    const over = (cancelable and isCanceled(f)) or (if (deadline) |d| nowNs() >= d else false);
    if (!over) commitWaitIn(n.epoch, deadline);
    lock.lock();
    defer ws.remove(&n);
    return !n.listed;
}

/// The monotonic clock, in nanoseconds: what deadlines count on.
pub fn nowNs() i96 {
    if (deterministic.*) return virtual_now.*;
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
var deterministic_var = false;
pub const deterministic = split.cell(&deterministic_var, "sched.deterministic");
/// The seed it runs with.
var seed_value_var: u64 = 0;
pub const seed_value = split.cell(&seed_value_var, "sched.seed_value");
var rng_state_var: u64 = 1;
const rng_state = split.cell(&rng_state_var, "sched.rng_state");
/// The virtual monotonic clock, in nanoseconds.
var virtual_now_var: i96 = 0;
const virtual_now = split.cell(&virtual_now_var, "sched.virtual_now");
/// The fibers ready to run, in place of the workers' rings.
var ready_var: std.ArrayList(*Fiber) = .empty;
const ready = split.cell(&ready_var, "sched.ready");

/// Run deterministically with seed `s` (`deterministic`).
pub fn seed(s: u64) void {
    deterministic.* = true;
    seed_value.* = s;
    // splitmix64 of the seed, so nearby seeds start far apart, and
    // never 0, which xorshift would keep.
    var z = s +% 0x9e3779b97f4a7c15;
    z = (z ^ (z >> 30)) *% 0xbf58476d1ce4e5b9;
    z = (z ^ (z >> 27)) *% 0x94d049bb133111eb;
    rng_state.* = (z ^ (z >> 31)) | 1;
}

/// A number below `n` from the seeded generator (xorshift64*).
fn random(n: usize) usize {
    rng_state.* ^= rng_state.* >> 12;
    rng_state.* ^= rng_state.* << 25;
    rng_state.* ^= rng_state.* >> 27;
    return @intCast((rng_state.* *% 0x2545f4914f6cdd1d) % n);
}

/// What a yield check or `task.check()` costs on the virtual clock: so
/// a computation that never waits still reaches its deadline.
const check_cost: i96 = 1_000;

/// A yield check or `task.check()` ran: move the virtual clock on.
pub fn computed() void {
    virtual_now.* += check_cost;
}

/// Move the virtual clock forward to `t`, never back: a program that
/// makes no tasks sleeps so (`rt.taskSleep`).
pub fn advanceTo(t: i96) void {
    if (t > virtual_now.*) virtual_now.* = t;
}

/// What a deterministic run that can never go on panics with: every task
/// waits, and nothing can wake one (`advanceClock`). A run that is not
/// deterministic reports none, since an outside event (an interrupt,
/// which cancels `main`) may still end a wait.
const deadlock_message = "every task is waiting on another, and none can run: a deadlock";

/// No fiber is ready: move the virtual clock to the earliest timer and
/// wake each fiber whose deadline that reaches. With no timer either,
/// every task waits on another, and none can ever run: a deadlock.
/// A fiber waiting on a file descriptor wakes once it is ready, at
/// whatever time: the poller is looked at first, without waiting, and
/// waited on when nothing else can end a wait.
fn advanceClock() void {
    const p = &all_workers.*[0].poller;
    if (p.count.load(.monotonic) != 0 and p.poll(0)) return;
    const due = timers.due.load(.acquire);
    if (due == no_due) {
        if (p.count.load(.monotonic) != 0) {
            _ = p.poll(null);
            return;
        }
        @panic(deadlock_message);
    }
    // Bytes written to a socket may still be on their way to the other
    // end, which macOS delivers on loopback later, the later the busier
    // the machine: while a registered socket has bytes it has not yet
    // seen its other end take (`unsent`), and they move, wait for them,
    // in real time, then a moment more, before the clock jumps past a
    // deadline a wait on them set. Bytes that stop moving, in a buffer
    // its reader leaves full, do not hold the clock.
    if (p.count.load(.monotonic) != 0) {
        var left = unsent();
        var moved = nowReal();
        while (left != 0) {
            if (p.poll(settle_ns)) return;
            const now_left = unsent();
            if (now_left != left) {
                left = now_left;
                moved = nowReal();
            } else if (nowReal() - moved >= stuck_ns) break;
        }
        if (p.poll(settle_ns)) return;
    }
    advanceTo(due);
    fireDue();
}

/// How long, in real time, a deterministic run with descriptors
/// registered waits for their events before its clock jumps to a timer,
/// once no socket has bytes on their way.
const settle_ns: i96 = std.time.ns_per_ms;

/// How long bytes on their way may stand still before a deterministic
/// run's clock jumps anyway: a buffer whose reader waits on the clock.
const stuck_ns: i96 = 500 * std.time.ns_per_ms;

/// The bytes the registered sockets of a deterministic run have sent and
/// not yet seen their other ends take: macOS's `SO_NWRITE`, Linux's
/// `SIOCOUTQ`. A descriptor that is not a socket counts none.
fn unsent() u64 {
    var total: u64 = 0;
    var at = registered.*;
    while (at) |r| : (at = r.next) {
        var n: c_int = 0;
        if (builtin.os.tag.isDarwin()) {
            var len: std.posix.socklen_t = @sizeOf(c_int);
            if (std.c.getsockopt(r.fd, std.c.SOL.SOCKET, 0x1024, @ptrCast(&n), &len) != 0) continue;
        } else if (builtin.os.tag == .linux) {
            if (@as(isize, @bitCast(std.os.linux.ioctl(r.fd, 0x5411, @intFromPtr(&n)))) != 0) continue;
        }
        if (n > 0) total += @intCast(n);
    }
    return total;
}
/// Wake each fiber whose deadline the virtual clock has reached: the
/// clock also moves while fibers compute (`computed`).
fn fireDue() void {
    _ = timers.fire(virtual_now.*);
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
    /// Taken uncounted (`lockApart`), as `Global`'s.
    lock: SpinLock = .{},
    heap: std.ArrayList(*Fiber) = .empty,
    /// Its earliest deadline, which workers read without the lock, or
    /// `no_due`.
    due: std.atomic.Value(i64) = .init(no_due),

    fn add(t: *Timers, f: *Fiber) void {
        t.lock.lockApart();
        defer t.lock.unlockApart();
        t.heap.append(std.heap.smp_allocator, f) catch rt.oom();
        f.wait.heap_index = t.heap.items.len - 1;
        f.wait.timers = t;
        t.up(f.wait.heap_index);
        t.publish();
        // The earliest it holds: a worker asleep until later wakes for it.
        if (f.wait.heap_index == 0 and !deterministic.*) kickForTimer(t.due.load(.monotonic));
    }

    fn cancel(t: *Timers, f: *Fiber) void {
        t.lock.lockApart();
        defer t.lock.unlockApart();
        if (f.wait.heap_index != Wait.no_index) t.removeAt(f.wait.heap_index);
        f.wait.timers = null;
        t.publish();
    }

    /// Wake each fiber whose deadline `now` has reached; whether any.
    fn fire(t: *Timers, now: i96) bool {
        if (t.due.load(.acquire) > now) return false;
        t.lock.lockApart();
        defer t.lock.unlockApart();
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
var timers_var: Timers = .{};
const timers = split.cell(&timers_var, "sched.timers");

/// A worker's `sleep_due` while it is not asleep.
const awake = std.math.minInt(i64);

/// The earliest deadline any worker holds, or `no_due`: when a worker
/// about to sleep wakes up.
fn earliestDue() i64 {
    var due: i64 = no_due;
    for (workersNow()) |*v| due = @min(due, v.timers.due.load(.seq_cst));
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
    for (workersNow()) |*v| {
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
    /// On the Mac in a release build: whether its worker waits in it,
    /// and whether `os.exit` claimed it there (`ExitClaim`), so the worker
    /// stops as it wakes, before it reads a single event (`tearDown`).
    parked: std.atomic.Value(ExitClaim) = .init(.awake),

    const darwin = builtin.os.tag.isDarwin();
    const linux = builtin.os.tag == .linux;
    const max_events = 64;

    fn open(p: *Poller) void {
        if (darwin) {
            p.fd = std.c.kqueue();
            if (p.fd < 0) failed("kqueue", p.fd);
            const ev: std.c.Kevent = .{ .ident = 0, .filter = std.c.EVFILT.USER, .flags = std.c.EV.ADD | std.c.EV.CLEAR, .fflags = 0, .data = 0, .udata = 0 };
            var none: [1]std.c.Kevent = undefined;
            _ = std.c.kevent(p.fd, @ptrCast(&ev), 1, &none, 0, null);
        } else if (linux) {
            const linux_ = std.os.linux;
            p.fd = @intCast(@as(isize, @bitCast(linux_.epoll_create1(linux_.EPOLL.CLOEXEC))));
            if (p.fd < 0) failed("epoll_create1", p.fd);
            p.kick_fd = @intCast(@as(isize, @bitCast(linux_.eventfd(0, linux_.EFD.NONBLOCK | linux_.EFD.CLOEXEC))));
            if (p.kick_fd < 0) failed("eventfd", p.kick_fd);
            var ev: linux_.epoll_event = .{ .events = linux_.EPOLL.IN | linux_.EPOLL.ET, .data = .{ .ptr = 0 } };
            _ = linux_.epoll_ctl(p.fd, linux_.EPOLL.CTL_ADD, p.kick_fd, &ev);
        }
    }

    /// A worker's poller could not be made: a panic naming the call and
    /// what the system said (`rc`, the call's result).
    fn failed(comptime call: []const u8, rc: i32) noreturn {
        @branchHint(.cold);
        const e: std.posix.E = if (linux) @enumFromInt(-rc) else std.posix.errno(rc);
        var buf: [96]u8 = undefined;
        @panic(std.fmt.bufPrint(&buf, "the scheduler's {s} failed: {t}", .{ call, e }) catch call);
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
    /// handled; a worker holding it, asleep in the poller, is woken to
    /// let go.
    fn remove(p: *Poller, fd: i32) void {
        if (!p.lock.tryLock()) {
            _ = p.removers.fetchAdd(1, .seq_cst);
            p.kick();
            p.lock.lock();
            _ = p.removers.fetchSub(1, .seq_cst);
        }
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
    /// unless it means to wait. A look that takes the poller's kick
    /// leaves it there again: a worker looks at the pollers of others as
    /// it goes to sleep (`serviceAll`), and at its own, and one of them,
    /// or itself, may be between its last look for work and its sleep,
    /// when a kick taken from under it would leave it asleep with work
    /// queued for it.
    fn poll(p: *Poller, timeout: ?i96) bool {
        // A look, which leaves a kick it takes; but a deterministic run,
        // on one thread, has no worker to leave it for, and waits a
        // moment in its poller after a look (`advanceClock`), which a
        // kick left there would end.
        const look = timeout != null and timeout.? == 0 and !deterministic.*;
        if (timeout == null or timeout.? > 0) rt.flushBeforeWait();
        var kicked = false;
        defer if (kicked) p.kick();
        if (look) {
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
            // A wait, not a look: `os.exit` may claim this worker while it
            // waits, and it then stops before it reads what woke it.
            if (tears_down and !look) p.parked.store(.waiting, .seq_cst);
            const n = std.c.kevent(p.fd, &evs, 0, &evs, max_events, tp);
            if (tears_down and !look and p.parked.swap(.awake, .seq_cst) == .claimed) stopForExit(me().?, true);
            if (n <= 0) return false;
            for (evs[0..@intCast(n)]) |ev| {
                if (ev.udata == 0) {
                    if (look) kicked = true;
                    continue;
                }
                const r: *Registration = @ptrFromInt(ev.udata);
                // An end (EV_EOF) is its own filter's readiness: the end
                // of reading wakes the reader, the end of writing (this
                // side's shutdown, or the other end's reset) the writer.
                const bits: u32 = if (ev.filter == std.c.EVFILT.READ) Registration.readable else Registration.writable;
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
                    if (look) {
                        kicked = true;
                        continue;
                    }
                    var drain: u64 = 0;
                    _ = linux_.read(p.kick_fd, std.mem.asBytes(&drain), 8);
                    continue;
                }
                const r: *Registration = @ptrFromInt(ev.data.ptr);
                var bits: u32 = 0;
                if (ev.events & (linux_.EPOLL.IN | linux_.EPOLL.RDHUP | linux_.EPOLL.HUP | linux_.EPOLL.ERR) != 0) bits |= Registration.readable;
                if (ev.events & (linux_.EPOLL.OUT | linux_.EPOLL.HUP | linux_.EPOLL.ERR) != 0) bits |= Registration.writable;
                if (r.ready(bits)) any = true;
            }
        }
        return any;
    }
};

/// The sleeping worker that watches every poller, or none: while a
/// worker that does not sleep holds descriptors, it sleeps no longer than
/// `watch_every`, and as it wakes looks at every poller (`serviceAll`),
/// so a busy worker's descriptors wait no longer than that for a look,
/// even while its own yield checks do not come (`sleepIn`). It keeps the
/// watch from one look to the next while such a worker is awake or has
/// slept since the watch began, so one that sleeps and wakes many times
/// a millisecond, as one answering a socket does, finds the watch held
/// and kicks no one as it wakes (`sleep`). Once every such worker has
/// slept through a whole watch, the watcher lets it go.
var watcher_var: std.atomic.Value(?*Worker) = .init(null);
const watcher = split.cell(&watcher_var, "sched.watcher");

/// How long at most the watching worker sleeps between looks.
const watch_every: i96 = std.time.ns_per_ms;

/// Whether a worker other than `w`, awake, holds descriptors: what the
/// watcher looks at every poller for.
fn busyDescriptors(w: ?*Worker) bool {
    for (workersNow()) |*v| {
        if (v == w) continue;
        if (v.poller.count.load(.monotonic) != 0 and v.idle.load(.seq_cst) == 0) return true;
    }
    return false;
}

/// Whether `w` is to watch: a worker other than it that holds
/// descriptors is awake, or has slept since the last watch began, so it
/// woke since.
fn watchWanted(w: *Worker) bool {
    if (busyDescriptors(w)) return true;
    for (workersNow()) |*v| {
        if (v == w or v.poller.count.load(.monotonic) == 0) continue;
        if (v.slept.load(.monotonic) != v.watch_mark.load(.monotonic)) return true;
    }
    return false;
}

/// Sleep in `w`'s poller up to `timeout`; when a worker that does not
/// sleep holds descriptors and no other worker watches, watch: sleep at
/// most `watch_every`, and look at every poller on waking. A watcher
/// holds the watch until it sleeps without one, or goes back to work
/// (`sleep`). It lets go of the watch before it looks at the other
/// workers: a worker that wakes to run fibers marks itself awake before
/// it looks for a watcher, all sequentially consistent, so either it sees
/// no watcher and kicks a sleeper, or this sees it awake.
fn sleepIn(w: *Worker, timeout: ?i96) void {
    if (workersNow().len >= 2) {
        const held = watcher.load(.monotonic) == w;
        if (held) watcher.store(null, .seq_cst);
        if (watchWanted(w) and watcher.cmpxchgStrong(null, w, .seq_cst, .monotonic) == null) {
            for (workersNow()) |*v| v.watch_mark.store(v.slept.load(.monotonic), .monotonic);
            _ = w.poller.poll(if (timeout) |t| @min(t, watch_every) else watch_every);
            return serviceAll();
        }
    }
    _ = w.poller.poll(timeout);
}

/// A watcher, or a worker holding descriptors while none watches, woke
/// to run fibers: while a worker that does not sleep holds descriptors,
/// have a sleeping worker look again, and watch (`sleepIn`).
fn passWatch() void {
    if (!busyDescriptors(null)) return;
    sleepers.lock.lock();
    const next_up = sleepers.top;
    sleepers.lock.unlock();
    if (next_up) |v| v.poller.kick();
}

/// A file descriptor a poller watches: how many times the poller has
/// seen it become ready each way (its edges), and the fibers waiting to
/// read and to write, as many of each as wait, as tasks that share a
/// listener each wait to accept. Readiness is edge-triggered: an edge
/// wakes every fiber waiting on it, and each tries its read, write, or
/// accept, and waits again only once that would block. A caller reads
/// the count before its call (`edges`) and waits only while it is
/// unchanged (`waitReady`), so an edge after the call reaches every such
/// caller, whichever of them runs first, and none takes it from another.
pub const Registration = struct {
    fd: i32,
    poller: *Poller,
    /// The edges seen: to read in the low 32 bits, to write in the high.
    seen: std.atomic.Value(u64) = .init(0),
    /// Guards `readers` and `writers`. `waiting` counts the fibers about
    /// to list themselves or listed: a waiter counts itself, then looks
    /// at `seen`, and the poller counts an edge, then looks at the count,
    /// so it takes the lock only when one may wait.
    lock: SpinLock = .{},
    waiting: std.atomic.Value(u32) = .init(0),
    readers: Waiters = .{},
    writers: Waiters = .{},
    /// Its neighbors in the list of every registration, kept in a
    /// deterministic run, which looks at what each still has to send
    /// before its clock jumps (`unsent`).
    prev: ?*Registration = null,
    next: ?*Registration = null,

    /// An end of the descriptor is readiness too, for the waits it ends:
    /// the end of reading (the other end shut down writing, EOF or RDHUP)
    /// is readiness to read, and the end of writing (EOF on macOS's write
    /// filter) readiness to write; a hang-up or a failure (HUP, ERR, a
    /// reset) is both. Each wait then tries its read or write, which
    /// returns at once, 0 or a failure, so none waits on an end again,
    /// and one side's end never wakes the other side's wait.
    pub const readable: u32 = 1;
    pub const writable: u32 = 2;

    /// The edges seen for `interest`, from `seen`'s value `v`.
    fn edgesOf(v: u64, interest: u32) u32 {
        return @truncate(if (interest == readable) v else v >> 32);
    }

    /// The poller saw `bits`: count an edge each way, then wake who waits
    /// on them.
    fn ready(r: *Registration, bits: u32) bool {
        _ = r.seen.fetchAdd(@as(u64, bits & readable) | @as(u64, bits & writable) << 31, .seq_cst);
        if (r.waiting.load(.seq_cst) == 0) return false;
        r.lock.lock();
        defer r.lock.unlock();
        var any = false;
        if (bits & readable != 0 and r.readers.wakeAll()) any = true;
        if (bits & writable != 0 and r.writers.wakeAll()) any = true;
        return any;
    }
};

/// Watch `fd`, which must not block, with the running worker's poller
/// (worker 0's outside the workers); null when the kernel refuses it.
pub const register = if (preempt) registerApart else registerIn;

/// `register` in a program built to be preempted: never inlined into
/// the program's own code (`mustNotBeInCode`).
noinline fn registerApart(fd: i32) ?*Registration {
    return registerIn(fd);
}

fn registerIn(fd: i32) ?*Registration {
    if (!started.*) startWorkers();
    const w = me() orelse &all_workers.*[0];
    const r = std.heap.smp_allocator.create(Registration) catch rt.oom();
    r.* = .{ .fd = fd, .poller = &w.poller };
    if (!w.poller.add(fd, r)) {
        std.heap.smp_allocator.destroy(r);
        return null;
    }
    if (deterministic.*) {
        r.next = registered.*;
        if (registered.*) |n| n.prev = r;
        registered.* = r;
    }
    return r;
}

/// Every registration, in a deterministic run, which runs on one thread.
var registered_var: ?*Registration = null;
const registered = split.cell(&registered_var, "sched.registered");

/// Stop watching the descriptor and free `r`, before the descriptor is
/// closed. No fiber may be waiting on it.
pub fn deregister(r: *Registration) void {
    if (deterministic.*) {
        if (r.prev) |p| p.next = r.next else if (registered.* == r) {
            registered.* = r.next;
        }
        if (r.next) |n| n.prev = r.prev;
    }
    r.poller.remove(r.fd);
    std.heap.smp_allocator.destroy(r);
}

/// The edges `r`'s poller has seen for `interest`: what a caller reads
/// before a call that may find the descriptor not ready, to wait on
/// (`waitReady`).
pub fn edges(r: *Registration, interest: u32) u32 {
    return Registration.edgesOf(r.seen.load(.acquire), interest);
}

/// How a wait on a descriptor ended (`waitReady`).
pub const Readiness = enum { ready, canceled, timeout };

/// Wait for `r` to be ready for `interest` (`Registration.readable` or
/// `.writable`), or for its end, until `deadline`: for an edge past
/// `seen`, the count the caller read before the call that would have
/// blocked (`edges`). A cancel ends the wait when `cancelable`. An edge
/// that came since is taken at once, which spends from the fiber's budget
/// (`spendBudget`).
pub fn waitReady(r: *Registration, interest: u32, seen: u32, deadline: ?i96, cancelable: bool) Readiness {
    const f = current().?;
    const ws = if (interest == Registration.readable) &r.readers else &r.writers;
    while (true) {
        if (edges(r, interest) != seen) {
            spendBudget();
            return .ready;
        }
        if (cancelable and isCanceled(f)) return .canceled;
        if (deadline) |d| if (nowNs() >= d) return .timeout;
        pausePoint();
        // An edge the poller saw before this fiber was listed, under the
        // lock, or one that woke it: it tries its call again.
        r.lock.lock();
        _ = r.waiting.fetchAdd(1, .seq_cst);
        const woken = Registration.edgesOf(r.seen.load(.seq_cst), interest) != seen or sleepOn(ws, &r.lock, deadline, cancelable);
        _ = r.waiting.fetchSub(1, .seq_cst);
        r.lock.unlock();
        if (woken) return .ready;
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
var test_pause_var: std.atomic.Value(?*Pause) = .init(null);
pub const test_pause = split.cell(&test_pause_var, "sched.test_pause");

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
pub const spendBudget = if (preempt) spendBudgetApart else spendBudgetIn;

/// `spendBudget` in a program built to be preempted: never inlined into
/// the program's own code (`mustNotBeInCode`).
noinline fn spendBudgetApart() void {
    return spendBudgetIn();
}

fn spendBudgetIn() void {
    const f = current() orelse return;
    f.budget -%= 1;
    if (f.budget != 0) return;
    f.budget = budget_size;
    if (!deterministic.*) if (me()) |w| if (hasOwnWork(w)) yield();
}

/// Wake the fibers whose timers are due on worker `w`, and those its
/// poller's events make ready, when it has descriptors: what a worker
/// looks at every 61 turns.
fn service(w: *Worker) void {
    deliverInterrupt();
    if (w.timers.due.load(.acquire) != no_due) _ = w.timers.fire(nowNs());
    if (w.poller.count.load(.monotonic) != 0) _ = w.poller.poll(0);
}

/// Before a worker sleeps: wake the fibers whose timers are due on any
/// worker, and those the events of any poller no worker sleeps in make
/// ready.
fn serviceAll() void {
    deliverInterrupt();
    const now = nowNs();
    for (workersNow()) |*v| {
        _ = v.timers.fire(now);
        if (v.poller.count.load(.monotonic) != 0) _ = v.poller.poll(0);
    }
}

/// An interrupt canceled `main` (`rt.onInterrupt`): end its wait, here
/// on a worker, as the handler may not. What a worker looks at as it
/// services its poller and timers.
inline fn deliverInterrupt() void {
    if (rt.interrupt_pending.load(.monotonic)) {
        @branchHint(.unlikely);
        if (rt.interrupt_pending.swap(false, .seq_cst)) rt.cancelMain();
    }
}

/// From the interrupt handler: wake every worker, so one sleeping in its
/// poller, or the next to service it, passes the cancel on. A kick is
/// one system call, which a handler may make. Once `main` has ended
/// there is nothing to cancel: `runMain` closes the pollers only after
/// `stopping` is set and every handler that looked before has left
/// (`kicking`).
pub fn kickForInterrupt() void {
    _ = kicking.fetchAdd(1, .seq_cst);
    defer _ = kicking.fetchSub(1, .seq_cst);
    if (stopping.load(.seq_cst)) return;
    for (workersNow()) |*w| w.poller.kick();
}

/// How many interrupt handlers are kicking the pollers.
var kicking_var: std.atomic.Value(u32) = .init(0);
const kicking = split.cell(&kicking_var, "sched.kicking");

// -----------------------------------------------------------------------------
// The blocking pool
// -----------------------------------------------------------------------------

/// Threads that run calls which block the thread they run on (reading a
/// file, say), so no worker blocks on one: a fiber that makes such a call
/// waits, and the pool thread that ran it wakes it. A call counts a
/// thread busy as it is handed one (`submit`); a thread idle
/// `retire_after` ends.
///
/// A call that finds no thread idle, and more calls queued than threads
/// on their way back from one (`finishing`, which take the next call
/// without sleeping), starts a thread, up to `soft` (one fewer than the
/// performance cores): a stream of short calls (a file read each) keeps a few
/// threads busy, each taking the next call as it ends one, rather than
/// waking a sleeping thread for each, and does not crowd the file
/// system. Past `soft`, the pool grows toward `max` only while its
/// oldest queued call has waited `grow_after` (`monitor`), so calls that
/// block for long (a pipe, a slow disk) still get threads.
/// `RIG_BLOCKING_THREADS` sets both bounds.
const Pool = struct {
    lock: SpinLock = .{},
    head: ?*Call = null,
    tail: ?*Call = null,
    /// Threads waiting for a call: `idle` of them free, and `reserved`
    /// counted busy by a call queued for one, never more than the calls
    /// queued (`queued`).
    idle: u32 = 0,
    reserved: u32 = 0,
    queued: u32 = 0,
    /// Threads that ran a call and woke its fiber, not yet back under the
    /// lock, where each takes the next call queued.
    finishing: std.atomic.Value(u32) = .init(0),
    /// Threads running, idle or not.
    threads: u32 = 0,
    word: std.atomic.Value(u32) = .init(0),
    /// The threads a call starts at once (`soft`), and the most the pool
    /// runs (`max`), read once (`poolBounds`).
    soft: u32 = 0,
    max: u32 = 0,
    /// The monitor's word, which a call moves as it waits for a thread
    /// past `soft`; whether the monitor runs, and whether it looks every
    /// `grow_after` (`ticking`), so a call need not wake it.
    monitor_word: std.atomic.Value(u32) = .init(0),
    monitoring: bool = false,
    ticking: bool = false,
    /// Each running pool thread's waker, under the lock: a thread lists
    /// its own as it starts and takes it off before it ends, so a waker
    /// listed names a live thread (`stop`).
    wakers: ?*Waker = null,
    /// Calls a waiter left that are not yet freed: each still runs, or
    /// waits for a thread, and may hold what its result owns
    /// (`settleLeftCalls`).
    left_calls: std.atomic.Value(u32) = .init(0),
    /// When a thread last ended a call, or the monitor last started one:
    /// the pool grows past `soft` only once no thread has ended one for
    /// `grow_after`, so its threads are blocked, not merely behind.
    progress: i96 = 0,

    const default_max = 64;

    fn submit(p: *Pool, c: *Call) void {
        // The clock is read before the lock is taken, never under it.
        const at = nowReal();
        p.lock.lock();
        if (p.max == 0) poolBounds(p);
        c.next = null;
        c.at = at;
        if (p.tail) |t| t.next = c else p.head = c;
        p.tail = c;
        p.queued += 1;
        // What the call needs: an idle thread woken; a thread started; the
        // monitor started, or woken unless it already looks; or nothing,
        // when a thread on its way back takes it, or every thread is busy
        // and the first to end a call takes it.
        var wake_idle = false;
        var start = false;
        var start_monitor = false;
        var watch = false;
        if (p.idle > 0) {
            p.idle -= 1;
            p.reserved += 1;
            wake_idle = true;
        } else if (p.queued - p.reserved > p.finishing.load(.seq_cst)) {
            if (p.threads < p.soft) {
                p.threads += 1;
                start = true;
            } else if (p.threads < p.max and !stopping.load(.acquire)) {
                if (!p.monitoring) {
                    p.monitoring = true;
                    start_monitor = true;
                } else watch = !p.ticking;
            }
        }
        p.lock.unlock();
        if (start) {
            const th = std.Thread.spawn(.{}, poolMain, .{p}) catch rt.oom();
            th.detach();
        } else if (start_monitor) {
            const th = std.Thread.spawn(.{}, monitor, .{p}) catch rt.oom();
            th.detach();
        } else if (watch) {
            _ = p.monitor_word.fetchAdd(1, .seq_cst);
            rt.io().futexWake(u32, &p.monitor_word.raw, 1);
        } else if (wake_idle) {
            _ = p.word.fetchAdd(1, .seq_cst);
            rt.io().futexWake(u32, &p.word.raw, 1);
        }
    }

    /// Whether no call is queued, running, or on its way back, and none a
    /// waiter left is still out: every thread waits for a call. Under the
    /// lock.
    fn isIdle(p: *Pool) bool {
        return p.head == null and p.queued == 0 and p.reserved == 0 and p.idle == p.threads and
            p.finishing.load(.seq_cst) == 0 and p.left_calls.load(.seq_cst) == 0;
    }

    /// The next call, for a thread that waited for it when `waited`: it
    /// fills a reservation, if there is one, and is otherwise no longer
    /// free.
    fn take(p: *Pool, waited: bool) ?*Call {
        const c = p.head orelse return null;
        p.head = c.next;
        if (p.head == null) p.tail = null;
        p.queued -= 1;
        if (waited) {
            if (p.reserved > 0) p.reserved -= 1 else p.idle -= 1;
        } else if (p.reserved > p.queued) {
            // A busy thread took the call a waiting one was reserved for,
            // which is free again.
            p.reserved -= 1;
            p.idle += 1;
        }
        return c;
    }

    /// As `main` ends: wake the idle threads, which end, and wait for
    /// every thread to end, up to `stop_wait` for one still running a
    /// call a fiber gave up waiting for (`blockingStop`) that its wake
    /// did not end, which may never return: the process then ends under
    /// it.
    fn stop(p: *Pool) void {
        const since = nowReal();
        _ = p.monitor_word.fetchAdd(1, .seq_cst);
        rt.io().futexWake(u32, &p.monitor_word.raw, 1);
        while (true) {
            _ = p.word.fetchAdd(1, .seq_cst);
            rt.io().futexWake(u32, &p.word.raw, std.math.maxInt(u32));
            _ = p.monitor_word.fetchAdd(1, .seq_cst);
            rt.io().futexWake(u32, &p.monitor_word.raw, 1);
            p.lock.lock();
            const left = p.threads + @intFromBool(p.monitoring);
            p.lock.unlock();
            if (left == 0 or nowReal() - since >= stop_wait) return;
            std.Thread.yield() catch {};
        }
    }

    const stop_wait: i96 = std.time.ns_per_s;
    const wake_again: i96 = std.time.ns_per_ms;

    /// Wake each thread whose call was left again: for a wake that came
    /// before the call entered its system call, and so was lost.
    fn wakeLeft(p: *Pool) void {
        p.lock.lock();
        defer p.lock.unlock();
        var w = p.wakers;
        while (w) |k| : (w = k.next) if (k.control.canceled.load(.seq_cst)) rt.wakeThread(k.thread);
    }

    /// List the running thread's waker; under the lock.
    fn listWaker(p: *Pool, w: *Waker) void {
        w.prev = null;
        w.next = p.wakers;
        if (p.wakers) |h| h.prev = w;
        p.wakers = w;
    }

    /// Take the running thread's waker off the list; under the lock.
    fn unlistWaker(p: *Pool, w: *Waker) void {
        if (w.prev) |a| a.next = w.next else p.wakers = w.next;
        if (w.next) |b| b.prev = w.prev;
        w.prev = null;
        w.next = null;
    }

    /// How long the oldest queued call waits before the pool grows past
    /// `soft`, and how often the monitor looks.
    const grow_after: i96 = std.time.ns_per_ms;
};

/// How long a pool thread waits for a call before it ends.
var retire_after_var: i96 = 10 * std.time.ns_per_s;
const retire_after = split.cell(&retire_after_var, "sched.retire_after");

/// The pool's bounds: `RIG_BLOCKING_THREADS` for both, if set; else
/// `soft` one fewer than the performance cores (`performanceCores`),
/// which the workers share, at least 2, and `max` `Pool.default_max`.
/// On a Mac of 4 performance cores, loco read 125,000 files 9% faster
/// with 3 threads than with 4.
fn poolBounds(p: *Pool) void {
    if (rt.process.*) |proc| if (proc.environ.getPosix("RIG_BLOCKING_THREADS")) |v| {
        const n = std.fmt.parseInt(u32, v, 10) catch 0;
        if (n > 0) {
            p.soft = n;
            p.max = n;
            return;
        }
    };
    p.soft = @max(2, @min(performanceCores() -| 1, Pool.default_max));
    p.max = Pool.default_max;
}

/// The cores a thread runs fastest on: on macOS the performance cores
/// (`hw.perflevel0.physicalcpu`), elsewhere every core, at most 8.
fn performanceCores() u32 {
    if (rt.macPerformanceCores()) |n| return n;
    return @intCast(@min(8, std.Thread.getCpuCount() catch 4));
}

/// Grow the pool past `soft` while its threads are blocked: once its
/// oldest queued call has waited `Pool.grow_after`, and no thread has
/// ended a call for as long (`progress`), start one thread, up to `max`,
/// and look again `grow_after` later; sleep while no call waits. It ends
/// as `main` ends (`stop`).
fn monitor(p: *Pool) void {
    defer rt.fast_alloc.threadExit();
    const alt = rt.AltStack.attach();
    defer alt.detach();
    while (true) {
        const seen = p.monitor_word.load(.seq_cst);
        const now = nowReal();
        p.lock.lock();
        if (stopping.load(.acquire)) {
            p.monitoring = false;
            p.ticking = false;
            p.lock.unlock();
            return;
        }
        const backlog = p.head != null and p.queued - p.reserved > p.finishing.load(.seq_cst);
        var start = false;
        if (backlog and p.threads < p.max and now - p.head.?.at >= Pool.grow_after and now - p.progress >= Pool.grow_after) {
            p.threads += 1;
            p.progress = now;
            start = true;
        }
        p.ticking = backlog;
        p.lock.unlock();
        if (start) {
            const th = std.Thread.spawn(.{}, poolMain, .{p}) catch rt.oom();
            th.detach();
        }
        // While a call waits, look again in `grow_after`; else sleep until
        // a call waits past `soft` (or `retire_after`, to look anyway).
        const wait_for = if (backlog) Pool.grow_after else retire_after.*;
        rt.io().futexWaitTimeout(u32, &p.monitor_word.raw, seen, .{ .duration = .{ .raw = .{ .nanoseconds = wait_for }, .clock = .awake } }) catch {};
    }
}


/// A call for the blocking pool: how to run it, and how to end the wait
/// of the fiber that made it.
const Call = struct {
    run: *const fn (*Call) void,
    next: ?*Call = null,
    /// When it was queued (`submit`), for the monitor.
    at: i96 = 0,
};

var pool_var: Pool = .{};
const pool = split.cell(&pool_var, "sched.pool");

fn poolMain(p: *Pool) void {
    // The thread's heap goes to the next thread as it ends (`alloc.zig`).
    defer rt.fast_alloc.threadExit();
    const alt = rt.AltStack.attach();
    defer alt.detach();
    waker().thread = rt.threadId();
    rt.task().control = &waker().control;
    p.lock.lock();
    p.listWaker(waker());
    // Started for a call: it is busy, not among the threads waiting.
    var waited = false;
    while (true) {
        if (p.take(waited)) |c| {
            p.lock.unlock();
            c.run(c);
            const ended = nowReal();
            p.lock.lock();
            _ = p.finishing.fetchSub(1, .seq_cst);
            p.progress = ended;
            waited = false;
            continue;
        }
        if (stopping.load(.acquire)) {
            p.threads -= 1;
            p.unlistWaker(waker());
            p.lock.unlock();
            return;
        }
        p.idle += 1;
        waited = true;
        const since = nowReal();
        while (true) {
            const seen = p.word.load(.seq_cst);
            p.lock.unlock();
            rt.io().futexWaitTimeout(u32, &p.word.raw, seen, .{ .duration = .{ .raw = .{ .nanoseconds = retire_after.* }, .clock = .awake } }) catch {};
            p.lock.lock();
            if (p.head != null) break;
            // No call: end once idle long enough, or as `main` ends. With
            // none queued, none is reserved, so this thread is free.
            if (stopping.load(.acquire) or nowReal() - since >= retire_after.*) {
                p.idle -= 1;
                p.threads -= 1;
                p.unlistWaker(waker());
                p.lock.unlock();
                return;
            }
        }
    }
}

/// The real monotonic clock, in nanoseconds, even in a deterministic run.
fn nowReal() i96 {
    return std.Io.Timestamp.now(rt.io(), .awake).nanoseconds;
}

/// `f(args...)`, a call that may block its thread: on the blocking pool,
/// while the fiber making it waits, so its worker runs other fibers.
/// Outside every fiber, and in a deterministic run, it runs here. No
/// cancel or deadline ends the wait (`blockingStop` is the waiting point
/// that does), so the fiber waits until the call is done, and `args` are
/// passed as they are: a call may read into a buffer its caller lends.
pub fn blocking(comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    if (!onPool()) return @call(.auto, f, args);
    return switch (poolCall(f, args, false, null)) {
        .done => |r| r,
        .canceled, .timeout => unreachable,
    };
}

/// How a call on the blocking pool ended for the fiber waiting on it.
pub fn PoolResult(comptime R: type) type {
    return union(enum) { done: R, canceled, timeout };
}

/// `f(args...)` on the blocking pool as a waiting point: a cancel of the
/// running task, or its deadline, ends the wait (`.canceled`,
/// `.timeout`) while the call runs on to its end on its thread, which
/// then drops its result (`rt.dropElement`). The waiter that leaves
/// cancels the call and wakes the system call it blocks in (`Waker`),
/// so a call that waits on another process (a FIFO's open, a pipe's
/// read) ends at its next retry (`rt.checkStop`); one not yet started
/// never starts. So the call must not point
/// into the waiter's frame: `args` are copied into the call's own state,
/// a `[]const u8` among them copied with what it points to, and freed
/// once `f` returns. Any other pointer among them, at any depth, is
/// rejected as the program compiles (`leavable`), since the waiter may
/// free what it points to, or the call write through it, after the
/// waiter left. What the call writes into it owns: a `rt.String` or an
/// `rt.net.Fd` passed by value moves into the call, which drops it or
/// returns it. A call that never starts gives it back at once, into
/// `back`, or drops it when `back` is null (`giveBack`): its waiter,
/// stopped before it was queued or while it was, knows it never will.
/// A task canceled, or past its deadline, before the call starts does
/// not make it. Outside every fiber, and in a deterministic run, it
/// runs here.
pub fn blockingStop(comptime f: anytype, args: anytype, back: ?*@TypeOf(args)) PoolResult(@typeInfo(@TypeOf(f)).@"fn".return_type.?) {
    if (!onPool()) return .{ .done = @call(.auto, f, args) };
    return poolCall(f, args, true, back);
}

/// Whether a call `blocking` or `blockingStop` makes here goes to the
/// blocking pool, rather than running on this thread.
pub fn onPool() bool {
    return !deterministic.* and current() != null;
}

/// As the program ends, before its leak check (`rt.finish`): wait for
/// each call a waiter left to end and drop what its result owns, up to
/// `Pool.stop_wait` for one its wake does not end, waking the threads of
/// those still running every `Pool.wake_again`. A waiter wakes its call
/// as it leaves, but the call's thread may not have run since.
pub fn settleLeftCalls() void {
    if (pool.left_calls.load(.seq_cst) == 0) return;
    const since = nowReal();
    var woke = since;
    while (pool.left_calls.load(.seq_cst) != 0) {
        const now = nowReal();
        if (now - since >= Pool.stop_wait) return;
        if (now - woke >= Pool.wake_again) {
            woke = now;
            pool.wakeLeft();
        }
        std.Thread.yield() catch {};
    }
}

/// Spins a pool call's waiter makes while the call is `finishing`
/// before it yields its thread (`poolCall`).
const finishing_spins = 64;

/// How a waiter that stops waiting for a pool call stops the call: its
/// thread, to wake the system call it blocks in (`rt.wakeThread`), and
/// the cancel flag that thread's task state points to, which the call's
/// retry loop sees (`rt.checkStop`). Each pool thread has one, cleared
/// as it starts each call, and listed in `Pool.wakers` while it runs.
pub const Waker = struct {
    thread: usize = 0,
    control: rt.Control = .{},
    prev: ?*Waker = null,
    next: ?*Waker = null,
};

threadlocal var waker_var: Waker = .{};
inline fn waker() *Waker {
    return split.local(&waker_var, "sched.waker");
}

fn poolCall(comptime f: anytype, args: anytype, comptime stoppable: bool, back: ?*@TypeOf(args)) PoolResult(@typeInfo(@TypeOf(f)).@"fn".return_type.?) {
    const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    const Args = @TypeOf(args);
    const fiber = current().?;
    const C = struct {
        call: Call = .{ .run = run },
        args: Args,
        result: R = undefined,
        /// `pending` until the call returns, then `finishing` while its
        /// thread wakes the waiter, then `done`; or `abandoned`, once
        /// the waiter gave up, when the thread frees it all.
        state: std.atomic.Value(u8) = .init(pending),
        fiber: *Fiber,
        epoch: std.atomic.Value(u32) = .init(0),
        /// The waker of the pool thread running the call, null before
        /// one starts it; and whether a waiter that gave up has used it,
        /// before which the thread does not leave the call.
        waker: std.atomic.Value(?*Waker) = .init(null),
        left: std.atomic.Value(bool) = .init(false),
        /// Whether the waiter that gave up took the arguments back, as
        /// it does when no thread had started the call; published by
        /// `left`.
        taken: bool = false,

        const pending = 0;
        const finishing = 1;
        const done = 2;
        const abandoned = 3;
        const Self = @This();

        fn run(c: *Call) void {
            const self: *Self = @fieldParentPtr("call", c);
            waker().control.canceled.store(false, .seq_cst);
            if (stoppable) {
                // The waker is published before the state is read, and a
                // waiter that gives up reads it after it marks the state:
                // so either it cancels and wakes this thread, or the call
                // does not run.
                self.waker.store(waker(), .seq_cst);
                if (self.state.load(.seq_cst) == abandoned) {
                    self.waitLeft();
                    if (!self.taken) {
                        freeArgs(&self.args);
                        dropOwned(&self.args);
                    }
                    _ = pool.finishing.fetchAdd(1, .seq_cst);
                    self.free();
                    return;
                }
            }
            self.result = @call(.auto, f, self.args);
            if (stoppable) freeArgs(&self.args);
            // Counted on its way back before the fiber can call again
            // (`Pool.finishing`).
            _ = pool.finishing.fetchAdd(1, .seq_cst);
            if (self.state.cmpxchgStrong(pending, finishing, .seq_cst, .seq_cst) != null) {
                // The waiter gave up: no one takes the result.
                rt.dropElement(R, &self.result);
                self.free();
                return;
            }
            _ = interrupt(self.fiber, self.epoch.load(.seq_cst), false);
            self.state.store(done, .seq_cst);
        }

        /// Free a call its waiter gave up on, once the waiter has woken
        /// this thread: until then the thread stays, so the signal finds
        /// it.
        fn free(self: *Self) void {
            self.waitLeft();
            std.heap.smp_allocator.destroy(self);
            _ = pool.left_calls.fetchSub(1, .seq_cst);
        }

        /// Wait until the waiter that gave up is done with the call.
        fn waitLeft(self: *Self) void {
            var spins: u32 = 0;
            while (!self.left.load(.acquire)) {
                spins += 1;
                if (spins < finishing_spins) std.atomic.spinLoopHint() else std.Thread.yield() catch {};
            }
        }
    };
    const c = std.heap.smp_allocator.create(C) catch rt.oom();
    c.* = .{ .args = args, .fiber = fiber };
    if (stoppable) ownArgs(&c.args);
    if (stoppable) if (stopReason(fiber)) |why| {
        freeArgs(&c.args);
        giveBack(&c.args, back);
        std.heap.smp_allocator.destroy(c);
        return stopped(R, why);
    };
    c.epoch.store(beginWait(stoppable), .seq_cst);
    pool.submit(&c.call);
    const deadline = if (stoppable) fiber.state.deadline else null;
    var spins: u32 = 0;
    while (true) {
        switch (c.state.load(.seq_cst)) {
            C.done => break,
            // The pool's thread has woken this one and has a store left.
            // On another core that takes nanoseconds; on this core (a
            // program pinned to one) the wake may have preempted it, so
            // after a few spins this thread gives the core up.
            C.finishing => {
                spins += 1;
                if (spins < finishing_spins) std.atomic.spinLoopHint() else std.Thread.yield() catch {};
                continue;
            },
            else => {},
        }
        if (stoppable) if (stopReason(fiber)) |why| {
            if (c.state.cmpxchgStrong(C.pending, C.abandoned, .seq_cst, .seq_cst) == null) {
                // Cancel the call and wake the system call it may block
                // in, so it stops (`rt.checkStop`); then the call is its
                // thread's to free.
                // No waker means no thread will start it: a thread
                // publishes its waker before it looks at the state, which
                // this one has marked. So the arguments come back now,
                // and a descriptor among them closes at once, not when a
                // thread is free.
                _ = pool.left_calls.fetchAdd(1, .seq_cst);
                if (c.waker.load(.seq_cst)) |w| {
                    w.control.canceled.store(true, .seq_cst);
                    rt.wakeThread(w.thread);
                } else {
                    freeArgs(&c.args);
                    giveBack(&c.args, back);
                    c.taken = true;
                }
                c.left.store(true, .release);
                return stopped(R, why);
            }
            continue;
        };
        commitWait(c.epoch.load(.monotonic), deadline);
        if (c.state.load(.seq_cst) != C.pending) continue;
        c.epoch.store(beginWait(stoppable), .seq_cst);
    }
    const r = c.result;
    std.heap.smp_allocator.destroy(c);
    return .{ .done = r };
}

/// Why the fiber `f` stops waiting, if it does: its task is canceled, or
/// its deadline has passed.
fn stopReason(f: *Fiber) ?PoolResultTag {
    if (isCanceled(f)) return .canceled;
    if (f.state.deadline) |d| if (nowNs() >= d) return .timeout;
    return null;
}

const PoolResultTag = enum { canceled, timeout };

fn stopped(comptime R: type, why: PoolResultTag) PoolResult(R) {
    return switch (why) {
        .canceled => .canceled,
        .timeout => .timeout,
    };
}

/// Copy each `[]const u8` among `args` into memory of its own, for a call
/// its waiter may leave (`blockingStop`); and reject, as the program
/// compiles, an argument that is not `leavable`.
fn ownArgs(args: anytype) void {
    const info = @typeInfo(@TypeOf(args.*)).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs, 0..) |name, T, a, i| {
        if (a.@"comptime") continue;
        comptime if (!isBytes(T) and !leavable(T)) @compileError(std.fmt.comptimePrint(
            "rig.blockingStop: argument {d} ({s}) holds a pointer, and a canceled waiter goes on while the call may still use it; pass bytes as a []const u8, which is copied, and move what the call writes into in as an rt.String or rt.net.Fd it owns",
            .{ i, @typeName(T) },
        ));
        if (comptime isBytes(T)) {
            const s = @field(args.*, name);
            @field(args.*, name) = std.heap.smp_allocator.dupe(u8, s) catch rt.oom();
        }
    }
}

/// Free the copies `ownArgs` made.
fn freeArgs(args: anytype) void {
    const info = @typeInfo(@TypeOf(args.*)).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, T, a| {
        if (comptime isBytes(T) and !a.@"comptime") std.heap.smp_allocator.free(@field(args.*, name));
    }
}

/// Give what a call that never runs would have owned back into `back`,
/// or drop it when `back` is null: every argument but a `[]const u8`,
/// which `freeArgs` frees. An argument known as the program compiles is
/// no one's, and needs nothing.
pub fn giveBack(args: anytype, back: ?*@TypeOf(args.*)) void {
    const to = back orelse return dropOwned(args);
    const info = @typeInfo(@TypeOf(args.*)).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, T, a| {
        if (comptime !isBytes(T) and !a.@"comptime") @field(to.*, name) = @field(args.*, name);
    }
}

fn dropOwned(args: anytype) void {
    const info = @typeInfo(@TypeOf(args.*)).@"struct";
    inline for (info.field_names, info.field_types, info.field_attrs) |name, T, a| {
        if (comptime !isBytes(T) and !a.@"comptime") rt.dropElement(T, &@field(args.*, name));
    }
}

fn isBytes(comptime T: type) bool {
    return T == []const u8;
}

/// Whether a value of `T` may stay with a call its waiter left: it holds
/// no pointer, at any depth, but in what the call owns (`rt.String`,
/// `rt.net.Fd`).
fn leavable(comptime T: type) bool {
    if (T == rt.String or T == rt.net.Fd) return true;
    return switch (@typeInfo(T)) {
        .pointer => false,
        .optional => |o| leavable(o.child),
        .error_union => |e| leavable(e.payload),
        .array => |a| leavable(a.child),
        .vector => |v| leavable(v.child),
        inline .@"struct", .@"union" => |u| for (u.field_types) |F| {
            if (!leavable(F)) break false;
        } else true,
        else => true,
    };
}

/// Stop running until another fiber wakes this one (`wake`). `after`
/// runs on the worker once this fiber has switched away: it records the
/// fiber where the waker will find it, or queues it again when what it
/// waits for has already happened.
pub const park = if (preempt) parkApart else parkIn;

noinline fn parkApart(after: After) void {
    parkIn(after);
}

fn parkIn(after: After) void {
    stopIn(after);
}

const stop = if (preempt) stopApart else stopIn;

/// `stop` in a program built to be preempted: never inlined into
/// the program's own code (`mustNotBeInCode`).
noinline fn stopApart(after: After) void {
    return stopIn(after);
}

fn stopIn(after: After) void {
    const w = me().?;
    const f = w.current.?;
    // A fiber that stops goes back to its worker, so whoever handed it
    // over waits for its end the usual way (`Header.wait`).
    f.handoff = null;
    w.after = after;
    checkOffOwnStack(w);
    switchTo(&f.sp, w.sp);
    checkHome(f);
}

/// In a safe build, a pinned fiber that resumes on a worker other than
/// its home panics: the counts it shares with its home's fibers are not
/// atomic (`pinHere`). A load and a branch per switch.
inline fn checkHome(f: *Fiber) void {
    if (!std.debug.runtime_safety) return;
    const home = f.home orelse return;
    if (me() != home) home_lost.*(f);
}

/// What `checkHome` does when a fiber resumes away from home; a test sets
/// it to note so instead.
var home_lost_var: *const fn (*Fiber) void = homeLost;
const home_lost = split.cell(&home_lost_var, "sched.home_lost");

fn homeLost(_: *Fiber) void {
    @branchHint(.cold);
    @panic("rig: a pinned task resumed on a worker other than its own");
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
            // A raise under way finishes first, and one after this makes
            // no worker: every worker there will be is woken.
            grow_lock.lock();
            const ws = workersNow();
            grow_lock.unlock();
            for (ws) |*w| wakeWorker(w);
        }
    };
    // Worker 0 runs `main` alone until its first task (`startWorkers`).
    const cap = @max(max_workers, workers_override.* orelse 0);
    all_workers.* = std.heap.smp_allocator.alloc(Worker, cap) catch rt.oom();
    for (all_workers.*, 0..) |*w, i| w.* = .{ .rng = @intCast(i * 2654435761 % 4294967291 + 1) };
    workers_len.store(1, .release);
    const first = &all_workers.*[0];
    first.poller.open();
    openDense();
    started.* = false;
    stopping.store(false, .seq_cst);
    var m: Main = .{ .fiber = .{ .run = Main.start, .done = Main.end }, .arg = arg, .run = run };
    m.fiber.state.stack_guard = guard;
    m.fiber.sp = initialFrame(&m.fiber, top);
    me_slot().* = first;
    if (preempt) preOf(first).tid = rt.threadId();
    if (deterministic.*) wake(&m.fiber) else _ = first.ring.push(&m.fiber);
    loop(first);
    // `stopping` is set, so past a raise under way the workers are final.
    grow_lock.lock();
    const ws = workersNow();
    grow_lock.unlock();
    stopMonitor();
    while (kicking.load(.seq_cst) != 0) std.atomic.spinLoopHint();
    pool.stop();
    printStats();
    for (ws[1..]) |*w| w.thread.?.join();
    timers.clear();
    for (ws) |*w| {
        freeStacks(w);
        freeBlocks(w);
        w.timers.clear();
        w.poller.close();
    }
    freeSpare();
    std.heap.smp_allocator.free(all_workers.*);
    workers_len.store(0, .release);
    all_workers.* = &.{};
    me_slot().* = null;
    // Workers stopped asleep are still listed; the next run, in a test,
    // starts with none.
    sleepers.* = .{};
    workers_asked.* = null;
    searching.store(0, .seq_cst);
    waiting.store(0, .monotonic);
    watcher.store(null, .seq_cst);
    ready.clearAndFree(std.heap.smp_allocator);
    registered.* = null;
}

/// Where the last signals `w` declined found its fiber, as addresses in
/// the executable's file (less the slide the loader gave it on macOS),
/// so `atos` or `addr2line` names their functions.
fn printDeclined(w: *Worker, i: usize) void {
    const pre = preOf(w);
    const n = @min(pre.declined_n, pre.declined_at.len);
    if (n == 0) return;
    const slide: usize = if (macho) @bitCast(_dyld_get_image_vmaddr_slide(0)) else 0;
    var buf: [1024]u8 = undefined;
    var len = (std.fmt.bufPrint(&buf, "rig: worker {d}: declined at", .{i}) catch return).len;
    const exe: usize = if (macho) @intFromPtr(_dyld_get_image_header(0)) else 0;
    for (pre.declined_at[0..n]) |pc| {
        // On macOS a library's code, the system's above all, is named by
        // its file.
        if (macho) {
            var info: std.c.dl_info = undefined;
            if (std.c.dladdr(@ptrFromInt(pc), &info) != 0 and @intFromPtr(info.fbase) != exe) {
                const file = std.mem.span(info.fname);
                len += (std.fmt.bufPrint(buf[len .. buf.len - 1], " {s}", .{std.fs.path.basename(file)}) catch return).len;
                continue;
            }
        }
        len += (std.fmt.bufPrint(buf[len .. buf.len - 1], " 0x{x}", .{pc -% slide}) catch return).len;
    }
    buf[len] = '\n';
    _ = std.posix.system.write(2, &buf, len + 1);
}

extern "c" fn _dyld_get_image_vmaddr_slide(image_index: u32) isize;

/// With `RIG_SCHED_STATS=1` set, print what each worker did to stderr,
/// as `main` ends: so a test can check where work ran without timing it.
fn printStats() void {
    const p = rt.process.* orelse return;
    const v = p.environ.getPosix("RIG_SCHED_STATS") orelse return;
    if (!std.mem.eql(u8, v, "1")) return;
    var buf: [320]u8 = undefined;
    for (workersNow(), 0..) |*w, i| {
        if (preempt) printDeclined(w, i);
        const line = (if (preempt)
            std.fmt.bufPrint(&buf, "rig: worker {d}: ran {d}, pinned {d}, stole {d}, slept {d}, preempted {d}, signaled {d} ({d} outside the program's code, {d} under a lock, {d} without room), deepest stop {d} of {d} bytes\n", .{ i, w.ran, w.ran_pinned, w.stole, w.slept.raw, preOf(w).preempts, preOf(w).signals.raw, preOf(w).outside, preOf(w).held_off, preOf(w).cramped, preOf(w).deepest, preempt_room })
        else
            std.fmt.bufPrint(&buf, "rig: worker {d}: ran {d}, pinned {d}, stole {d}, slept {d}\n", .{ i, w.ran, w.ran_pinned, w.stole, w.slept.raw })) catch continue;
        _ = std.posix.system.write(2, line.ptr, line.len);
    }
}

/// Test only: run `run` as `main`, on a stack of its own, with `n`
/// workers.
pub fn runForTest(run: *const fn (*anyopaque) callconv(.c) void, n: usize) void {
    workers_override.* = n;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, run, s.top(), .{});
}

/// The most workers a program runs.
const max_workers = 64;
var all_workers_var: []Worker = &.{};
const all_workers = split.cell(&all_workers_var, "sched.all_workers");
var started_var = false;
const started = split.cell(&started_var, "sched.started");

/// Start the other workers, when `main` makes its first task: by then
/// the runtime has the program's environment, for `RIG_WORKERS`, and a
/// program that makes none starts none.
fn startWorkers() void {
    started.* = true;
    const n = if (deterministic.*) 1 else @min(workerCount(), all_workers.*.len);
    const ws = all_workers.*[0..n];
    for (ws[1..]) |*w| w.poller.open();
    workers_len.store(n, .release);
    for (ws[1..]) |*w| w.thread = std.Thread.spawn(.{}, workerMain, .{w}) catch rt.oom();
    if (preempt and !deterministic.*) startMonitor();
}

/// How many workers the program asked for (`task.workers`), in place of
/// `RIG_WORKERS` or one per core.
var workers_asked_var: ?usize = null;
const workers_asked = split.cell(&workers_asked_var, "sched.workers_asked");

/// `task.workers(n)`: run tasks on `n` workers, at most `max_workers`,
/// from when they start, as the program makes its first task, or from
/// now if they have started and `n` is no fewer than run; whether it took
/// effect. A deterministic run keeps to one thread. Never inlined into
/// the program's own code (`mustNotBeInCode`, through `onWorkerStack`).
pub noinline fn askWorkers(n: usize) bool {
    const want = @max(1, @min(n, max_workers));
    if (!started.*) {
        workers_asked.* = want;
        return true;
    }
    if (deterministic.*) return false;
    return onWorkerStack(growWorkers, .{want});
}

/// Held across a raise, and as a program's end reads the final workers,
/// so a raise finishes before the end looks, or makes no worker after it.
var grow_lock_var: SpinLock = .{};
const grow_lock = split.cell(&grow_lock_var, "sched.grow_lock");

/// Run `n` workers, if that is no fewer than run and the program is not
/// ending; whether it now runs `n`. The new workers' pollers open before
/// the length is published, for the walks that touch every published
/// poller (`kickForInterrupt`, `wakeWorker`); their threads start after
/// it, so each finds itself among the workers.
fn growWorkers(n: usize) bool {
    grow_lock.lock();
    defer grow_lock.unlock();
    const have = workers_len.load(.monotonic);
    if (n <= have) return n == have;
    if (stopping.load(.seq_cst) or (tears_down and exit_state.phase.load(.seq_cst) != .idle)) return false;
    const fresh = all_workers.*[have..n];
    for (fresh) |*w| w.poller.open();
    workers_len.store(n, .release);
    for (fresh) |*w| w.thread = std.Thread.spawn(.{}, workerMain, .{w}) catch rt.oom();
    return true;
}

/// How many workers run tasks, or will once the program makes its first
/// task, without starting them (`startWorkers`): one in a deterministic
/// run.
pub fn workerTotal() usize {
    if (started.*) return workersNow().len;
    if (deterministic.*) return 1;
    return @min(workerCount(), all_workers.*.len);
}

/// How many workers run tasks, starting them first if they have not.
pub fn workersRunning() usize {
    if (!started.*) startWorkers();
    return workersNow().len;
}

fn workerCount() usize {
    if (workers_override.*) |n| return n;
    if (workers_asked.*) |n| return n;
    if (rt.process.*) |p| if (p.environ.getPosix("RIG_WORKERS")) |v| {
        const n = std.fmt.parseInt(usize, v, 10) catch 0;
        if (n > 0) return n;
    };
    return @max(1, std.Thread.getCpuCount() catch 1);
}

fn workerMain(w: *Worker) void {
    defer rt.fast_alloc.threadExit();
    const alt = rt.AltStack.attach();
    defer alt.detach();
    me_slot().* = w;
    if (preempt) preOf(w).tid = rt.threadId();
    defer leavePreempt(w);
    loop(w);
}

/// A worker's life: run what is ready, look for more, sleep when there
/// is none, until `main` ends.
fn loop(w: *Worker) void {
    while (!stopping.load(.acquire)) {
        if (tears_down and exit_state.phase.load(.acquire) != .idle) stopForExit(w, false);
        if (deterministic.*) {
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
            if (spare.count.load(.monotonic) > spareKept()) trimSpare();
            if (dense_spare.count.load(.monotonic) > spareKept()) trimDense();
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
    w.ran += 1;
    if (preempt) preOf(w).runs.store(preOf(w).runs.raw +% 1, .monotonic);
    if (f.home != null) w.ran_pinned += 1;
    prepare(w, f);
    spread(w);
    w.current = f;
    switchTo(&w.sp, f.sp);
    // The fiber that switched away: `f`, or one `f` handed this worker.
    const gone = w.current.?;
    w.current = null;
    if (w.after) |a| {
        w.after = null;
        a.run(gone, a.ctx);
    } else if (gone.finished) {
        endStack(w, gone);
        if (gone.done) |d| d(gone);
    }
}

/// As `w` switches to a fiber, at its loop or by a handoff: when other
/// work still waits in its "run next" slots or its ring while a worker
/// sleeps and none looks for work, wake one for it (`notify`). A fiber
/// made ready into a slot wakes no worker (`wakeIn`), and a fiber that
/// makes several tasks and waits for the first, or for anything, leaves
/// the others there as its worker runs on: the woken worker takes them
/// (`stealNext`). A build preempted by signal has no yield check that
/// would hand them on, and without this they waited for the monitor's
/// stop, about 1 ms. A switch with nothing else waiting costs two loads.
inline fn spread(w: *Worker) void {
    if (!nextHeld(w, .monotonic) and w.ring.isEmpty()) return;
    notify();
}

/// The fiber `f` has switched away for good: its stack, unless a panic
/// left it elsewhere (`abandon`), goes back to `w`.
fn endStack(w: *Worker, f: *Fiber) void {
    const s = f.stack orelse return;
    f.stack = null;
    releaseStack(w, s);
}

/// Give a fiber that has not run yet its stack, from this worker, which
/// keeps it for the next when the fiber ends.
fn prepare(w: *Worker, f: *Fiber) void {
    if (f.sp != 0) return;
    const s = (if (f.dense) takeDense(w) else null) orelse takeStack();
    f.stack = s;
    f.state.stack_guard = .{ .lo = s.base, .hi = s.base + s.guard, .len = s.len };
    f.sp = initialFrame(f, s.top());
}

/// The next fiber to run: the global queue's (first, one turn in 61, so
/// it is never starved), this worker's "run next" fiber, its pinned
/// fibers' and its ring's, the global queue's, or one stolen.
fn next(w: *Worker) ?*Fiber {
    // Deterministic: any ready fiber, as the seed picks, once the timers
    // the clock has reached have woken theirs.
    if (deterministic.*) {
        deliverInterrupt();
        fireDue();
        if (ready.items.len == 0) return null;
        return ready.swapRemove(random(ready.items.len));
    }
    w.tick +%= 1;
    if (w.tick % 61 == 0) {
        service(w);
        if (global.pop()) |f| return f;
    }
    // The newest first; the next made takes the slot it leaves.
    var k: u8 = if (nextHeld(w, .monotonic)) 0 else run_next_slots;
    while (k < run_next_slots) : (k += 1) {
        const i = (w.lifo_head.raw +% run_next_slots -% k) % run_next_slots;
        const slot = &w.lifo[i];
        if (slot.load(.monotonic) == null) continue;
        const f = slot.swap(null, .seq_cst) orelse continue;
        w.lifo_head.store((i +% run_next_slots -% 1) % run_next_slots, .monotonic);
        if (w.lifo_streak < lifo_limit) {
            w.lifo_streak += 1;
            return f;
        }
        // Run a fiber from the ring first, and leave this one to be
        // stolen meanwhile.
        if (f.home != null) w.pinned.push(f) else _ = w.ring.push(f);
        break;
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
    const ws = workersNow();
    if (ws.len < 2) return null;
    // A worker woken to look for work is counted as searching already.
    if (!w.searching) {
        if (2 * searching.load(.acquire) >= ws.len) return null;
        _ = searching.fetchAdd(1, .seq_cst);
        w.searching = true;
    }
    w.rng ^= w.rng << 13;
    w.rng ^= w.rng >> 17;
    w.rng ^= w.rng << 5;
    const start = w.rng % ws.len;
    for (0..ws.len) |k| {
        const v = &ws[(start + k) % ws.len];
        if (v == w) continue;
        if (w.ring.stealFrom(&v.ring)) |f| {
            w.stole += 1;
            return f;
        }
    }
    if (global.pop()) |f| return f;
    // No ring had any: take a fiber another worker has kept in its "run
    // next" slot a while.
    for (0..ws.len) |k| {
        const v = &ws[(start + k) % ws.len];
        if (v == w) continue;
        if (stealNext(v)) |f| {
            w.stole += 1;
            return f;
        }
    }
    return null;
}

/// How long a fiber waits in a busy worker's "run next" slot before a
/// worker with nothing to do takes it: long enough that a fiber made and
/// waited for at once runs on its maker's worker (`handoff`), as Go waits
/// 3 µs before it takes a `runnext`.
const steal_next_after: i96 = 3 * std.time.ns_per_us;

/// Take the fiber in `v`'s "run next" slot, if it is still there after
/// `steal_next_after`. A pinned one taken so goes back to its home's
/// queue.
fn stealNext(v: *Worker) ?*Fiber {
    const slot = oldestNext(v) orelse return null;
    const f = slot.load(.seq_cst) orelse return null;
    // Wait without reading the slot, whose line its owner writes.
    const until = nowNs() + steal_next_after;
    while (nowNs() < until) std.atomic.spinLoopHint();
    if (slot.cmpxchgStrong(f, null, .seq_cst, .monotonic) != null) return null;
    return unlessPinned(f);
}

/// The oldest of `v`'s "run next" slots that holds a fiber, which a
/// worker from outside takes: the first after the newest, going round.
fn oldestNext(v: *Worker) ?*std.atomic.Value(?*Fiber) {
    const head = v.lifo_head.load(.monotonic);
    var k: u8 = 1;
    while (k <= run_next_slots) : (k += 1) {
        const i = (head +% k) % run_next_slots;
        if (v.lifo[i].load(.seq_cst) != null) return &v.lifo[i];
    }
    return null;
}

/// Take the fiber in `v`'s "run next" slot at once: for a yield check
/// told work waits (`claimWaiting`), as filling a slot tells them
/// (`wake`).
fn takeNext(v: *Worker) ?*Fiber {
    const slot = oldestNext(v) orelse return null;
    const f = slot.load(.seq_cst) orelse return null;
    if (slot.cmpxchgStrong(f, null, .seq_cst, .monotonic) != null) return null;
    return unlessPinned(f);
}

/// A fiber taken from another worker's slot: it, or, when it is pinned,
/// none, as it goes back to its home's queue.
fn unlessPinned(f: *Fiber) ?*Fiber {
    if (f.home) |home| {
        wakeHome(f, home);
        return null;
    }
    return f;
}

/// `notify` for work woken or made, not a fiber that yielded: when no
/// worker is looking or asleep, every one is busy, and their yield
/// checks are told it waits (`waiting`).
fn notifyNew() void {
    if (deterministic.*) return;
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
    if (deterministic.*) return;
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
/// to find clears `waiting` (`takeWaiting`). While it sleeps, it wakes
/// the fibers whose timers come due on any worker, and those its
/// poller's events make ready, and goes back to running them.
fn sleep(w: *Worker) void {
    w.slept.store(w.slept.raw + 1, .monotonic);
    _ = takeWaiting(w);
    w.woken.store(0, .seq_cst);
    w.idle.store(1, .seq_cst);
    defer w.idle.store(0, .seq_cst);
    sleepers.push(w);
    if (stopping.load(.seq_cst) or (tears_down and exit_state.phase.load(.seq_cst) != .idle)) {
        if (!sleepers.remove(w)) waitWoken(w);
        return;
    }
    if (searching.load(.seq_cst) == 0 and hasWork()) {
        // Work made while it went to sleep, which woke no one: it looks
        // for it again as a searching worker, so once it finds some, it
        // wakes another for the rest (`loop`), as Go's scheduler does
        // (formal/Models/Sleep.lean).
        if (sleepers.remove(w)) {
            w.searching = true;
            _ = searching.fetchAdd(1, .seq_cst);
        } else waitWoken(w);
        return;
    }
    // A worker that holds the watch and goes back to work passes it on;
    // one that holds descriptors marks itself awake, then has a sleeper
    // watch if none does (`sleepIn`).
    defer {
        const held = watcher.load(.monotonic) == w;
        if (held) watcher.store(null, .seq_cst);
        if (held or w.poller.count.load(.monotonic) != 0) {
            w.idle.store(0, .seq_cst);
            if (held or watcher.load(.seq_cst) == null) passWatch();
        }
    }
    while (w.woken.load(.seq_cst) == 0) {
        serviceAll();
        if (!hasOwnWork(w)) {
            w.sleep_due.store(no_due, .seq_cst);
            const due = earliestDue();
            w.sleep_due.store(due, .seq_cst);
            sleepIn(w, if (due == no_due) null else @max(@as(i96, due) - nowNs(), 0));
            w.sleep_due.store(awake, .seq_cst);
            if (!hasOwnWork(w)) continue;
        }
        // Fibers made ready here: run them, unless a waker took this
        // worker off the list meanwhile, when it waits for its kick.
        if (!sleepers.remove(w)) waitWoken(w);
        return;
    }
}

/// Clear `waiting`, for `w`'s check that takes its notice (`claimWaiting`)
/// or as `w` goes to sleep, and give whether it was set. The flag is one
/// bit for many notices, and a fiber in another worker's "run next" slot
/// is seen by no sleeper and by its maker's recursive checks only through
/// it, so the flag is set again while any other worker's slot holds a
/// fiber. The clearing swap and the slot reads after it, against a
/// maker's swap into its slot and its read of the flag after that
/// (`wake`), are sequentially consistent, so one side sees the other: the
/// clearer sees the fiber, or the maker sees the flag clear and sets it.
fn takeWaiting(w: *Worker) bool {
    if (waiting.load(.monotonic) == 0) return false;
    if (waiting.swap(0, .seq_cst) == 0) return false;
    for (workersNow()) |*v| {
        if (v != w and nextHeld(v, .seq_cst)) {
            waiting.store(1, .monotonic);
            break;
        }
    }
    return true;
}

fn waitWoken(w: *Worker) void {
    while (w.woken.load(.seq_cst) == 0) _ = w.poller.poll(null);
}

fn hasWork() bool {
    if (global.count.load(.seq_cst) != 0) return true;
    for (workersNow()) |*v| if (!v.ring.isEmpty()) return true;
    return false;
}

fn freeStacks(w: *Worker) void {
    while (w.stacks.free) |n| {
        w.stacks.free = n.next;
        unmapStack(n.stack);
    }
    w.stacks.free_count = 0;
    if (w.stacks.fresh_left > 0) {
        const span = rt.task_guard + rt.task_stack_size + std.heap.pageSize();
        std.posix.munmap(@as([*]align(std.heap.page_size_min) u8, @ptrFromInt(w.stacks.fresh_next))[0 .. span * w.stacks.fresh_left]);
    }
    w.stacks.fresh_left = 0;
}

// -----------------------------------------------------------------------------
// The teardown at `os.exit`
// -----------------------------------------------------------------------------
//
// On the Mac a process's exit is the kernel freeing its page-table pages,
// about 13 µs each (one for each Table, each fiber stack touched, and
// each 32 MiB of segments), and its resident pages, on one core. When
// `os.exit` is called while every other worker can be stopped,
// `tearDown` has them all unmap the program's memory in parallel first,
// so the kernel is left little, and the process then ends as before.
// The work stays in the process: its time, its CPU time, and its peak
// are counted as before. The design and why it is sound:
// docs/history/records/2026-11/exit/parallel-teardown.md.

/// Whether `os.exit` tears down in parallel: release builds on the Mac.
/// Linux's parallel unmapping is unmeasured, so it ends as before.
const tears_down = builtin.os.tag.isDarwin() and builtin.optimize != .debug;

const ExitPhase = enum(u32) { idle, gathering, go, plain };

/// A worker's state in its poller (`Poller.parked`): awake, waiting in
/// the system's call, or claimed there by `os.exit`. Whichever of the
/// worker's swap as it wakes and `os.exit`'s compare-and-swap comes
/// first decides: a worker claimed never handles what woke it.
const ExitClaim = enum(u32) { awake, waiting, claimed };

/// The teardown's state, on lines of its own: every worker's loop reads
/// `phase` before it takes a fiber.
const Exit = struct {
    phase: std.atomic.Value(ExitPhase) align(std.atomic.cache_line) = .init(.idle),
    /// Workers stopped for it: claimed in their pollers, or stopped at the
    /// top of their loops (`stopForExit`).
    stopped: std.atomic.Value(u32) align(std.atomic.cache_line) = .init(0),
    /// The next piece to unmap, of `total`, and the pieces unmapped.
    next: std.atomic.Value(u32) = .init(0),
    finished: std.atomic.Value(u32) = .init(0),
    total: u32 = 0,
    /// Workers that take pieces, the caller first, up to `helpers`; when
    /// the workers stopped (for `RIG_SCHED_STATS`).
    helping: std.atomic.Value(u32) = .init(1),
    helpers: u32 = 1,
    stopped_at: i96 = 0,
    /// The ranges, the bytes of each piece of each, and the first piece
    /// of each.
    ranges: [rt.fast_alloc.exit_ranges_max]rt.fast_alloc.ExitRange = undefined,
    piece: [rt.fast_alloc.exit_ranges_max]usize = undefined,
    first: [rt.fast_alloc.exit_ranges_max + 1]u32 = undefined,
    count: usize = 0,
};
var exit_var: Exit = .{};
const exit_state = split.cell(&exit_var, "sched.exit");

/// How many threads unmap, the caller among them: on the Mac's kernel
/// more than two gain little (Trig at 8 checkers: 4.6 ms on one, 3.2 on
/// two, 3.3 on four, 3.1 on ten), and each more only spins on its locks.
const exit_helpers = 4;

/// Below this much kernel time to save, `os.exit` does not stop the
/// workers: waking them costs tens of microseconds.
const teardown_min_us = 400;

/// How long `os.exit` waits for the other workers to stop before it ends
/// the process as before.
const exit_stop_wait: i96 = 2 * std.time.ns_per_ms;

/// The address space one page-table page maps: 32 MiB with the Mac's
/// 16 KiB pages (2048 entries of 8 bytes), 2 MiB with 4 KiB ones. Pieces
/// unmapped apart are cut on its boundaries, so no two threads free the
/// same page-table page.
fn tableSpan() usize {
    const page = std.heap.pageSize();
    return page * (page / @sizeOf(usize));
}

/// Unmap `len` bytes at `start`, a range Rig mapped and never gave back,
/// ignoring the result: a call that fails leaves the kernel the work.
fn unmapForExit(start: usize, len: usize) void {
    _ = std.c.munmap(@ptrFromInt(start), len);
}

/// `os.exit`, after it has flushed the output: on the Mac in a release
/// build, unmap the program's segments, its Tables' regions and its free
/// fiber stacks on every worker before the process ends, when every other
/// worker can be stopped first; otherwise return at once. With
/// `RIG_SCHED_STATS=1` set it says which it did.
pub noinline fn tearDown() void {
    if (!tears_down) return;
    const stats = statsWanted();
    const began = nowReal();
    const why = tearDownAll();
    if (!stats) return;
    var buf: [128]u8 = undefined;
    const line = (if (why) |reason|
        std.fmt.bufPrint(&buf, "rig: exit: plain, {s}\n", .{reason})
    else
        std.fmt.bufPrint(&buf, "rig: exit: torn down on {d} of {d} workers, {d} pieces, in {d} us ({d} us to stop them)\n", .{ exit_state.helpers, workersNow().len, exit_state.total, @divTrunc(nowReal() - began, std.time.ns_per_us), @divTrunc(exit_state.stopped_at - began, std.time.ns_per_us) })) catch return;
    _ = std.posix.system.write(2, line.ptr, line.len);
}

fn statsWanted() bool {
    const p = rt.process.* orelse return false;
    const v = p.environ.getPosix("RIG_SCHED_STATS") orelse return false;
    return std.mem.eql(u8, v, "1");
}

/// The teardown, or why not. Every range it unmaps is unmapped only once
/// every other worker has stopped, never to run a fiber again, and the
/// blocking pool is idle and held, so nothing but the kernel touches it
/// again.
fn tearDownAll() ?[]const u8 {
    if (!started.* or deterministic.*) return "no workers";
    var ws = workersNow();
    if (ws.len < 2) return "one worker";
    if (stopping.load(.seq_cst)) return "main has returned";
    const w = me() orelse return "not on a worker";
    const span = tableSpan();
    const work = rt.fast_alloc.exitWork(span);
    var stacks: usize = 0;
    for (ws) |*v| stacks += @atomicLoad(u32, &v.stacks.free_count, .monotonic);
    stacks += spare.count.load(.monotonic);
    // About 13 µs a page-table page, and 8 µs a MiB of segments.
    if (13 * (work.page_tables + stacks) + 8 * work.segment_mib < teardown_min_us) return "little to free";
    if (othersRun(w, ws)) return "a task runs";
    const ex = exit_state;
    // No signal switches this fiber away from here on.
    holdOff();
    // Under a raise's lock: a raise under way finishes first, and its
    // workers are waited for as the others, and one after this makes none.
    grow_lock.lock();
    const lost = ex.phase.cmpxchgStrong(.idle, .gathering, .seq_cst, .seq_cst) != null;
    ws = workersNow();
    grow_lock.unlock();
    if (lost) return "another exit";
    // A worker waiting in its poller is claimed there and stops as it
    // wakes; one awake stops at the top of its loop. Each is kicked, so
    // it wakes to help.
    var claimed: u32 = 0;
    for (ws) |*v| if (v != w) {
        if (v.poller.parked.cmpxchgStrong(.waiting, .claimed, .seq_cst, .seq_cst) == null) claimed += 1;
        wakeWorker(v);
    };
    _ = ex.stopped.fetchAdd(claimed, .seq_cst);
    const until = nowReal() + exit_stop_wait;
    while (ex.stopped.load(.seq_cst) < ws.len - 1) {
        if (othersRun(w, ws)) return giveUp("a task runs");
        if (nowReal() > until) return giveUp("the workers did not stop");
        std.atomic.spinLoopHint();
    }
    // No fiber can run now, so none can make a call: held for good, the
    // pool's lock keeps its threads from taking one, or ending.
    pool.lock.lock();
    if (!pool.isIdle()) return giveUp("the pool is busy");
    ex.stopped_at = nowReal();
    ex.helpers = @intCast(@min(ws.len, exit_helpers));
    plan(ex, span, ex.helpers);
    ex.phase.store(.go, .seq_cst);
    unmapShare(w, ex);
    // The pieces others took. A worker past `helpers`, or claimed and not
    // yet awake, takes none, and leaves its free stacks to the kernel.
    while (ex.finished.load(.seq_cst) < ex.total) std.atomic.spinLoopHint();
    return null;
}

/// Whether a worker other than `w` runs a fiber.
fn othersRun(w: *Worker, ws: []Worker) bool {
    for (ws) |*v| if (v != w and @atomicLoad(?*Fiber, &v.current, .seq_cst) != null) return true;
    return false;
}

/// The workers that stopped sleep until the process ends.
fn giveUp(why: []const u8) []const u8 {
    exit_state.phase.store(.plain, .seq_cst);
    return why;
}

/// A worker sees `os.exit` tearing down at the top of its loop, before
/// it takes a fiber, or wakes in its poller claimed by it (`claimed`,
/// counted stopped already): it stops, never to run a fiber again, does
/// its share once told to, and sleeps until the process ends.
noinline fn stopForExit(w: *Worker, claimed: bool) noreturn {
    const ex = exit_state;
    if (!claimed) _ = ex.stopped.fetchAdd(1, .seq_cst);
    while (true) switch (ex.phase.load(.seq_cst)) {
        .go => break,
        .plain => sleepForever(),
        else => std.atomic.spinLoopHint(),
    };
    // Past `helpers` more threads only contend for the kernel's locks.
    if (ex.helping.fetchAdd(1, .monotonic) < ex.helpers) unmapShare(w, ex);
    sleepForever();
}

fn sleepForever() noreturn {
    while (true) sleepNs(std.time.ns_per_s);
}

/// Cut the ranges into pieces on page-table boundaries: the segments
/// written, densely, a page-table page's span each; the rest, sparse,
/// into about four pieces a worker in all.
fn plan(ex: *Exit, span: usize, helpers: usize) void {
    const got = rt.fast_alloc.exitRanges(&ex.ranges);
    var sparse: usize = 0;
    for (got.ranges[got.dense..]) |r| sparse += r.len;
    const sparse_piece = @max(span, std.mem.alignForward(usize, sparse / (4 * helpers), span));
    var total: u32 = 0;
    for (got.ranges, 0..) |r, i| {
        const piece = if (i < got.dense) span else sparse_piece;
        ex.piece[i] = piece;
        ex.first[i] = total;
        // A multiple of the span, not always a power of two.
        const lo = r.start - r.start % piece;
        total += @intCast(std.math.divCeil(usize, r.start + r.len - lo, piece) catch unreachable);
    }
    ex.count = got.ranges.len;
    ex.first[ex.count] = total;
    ex.total = total;
}

/// A worker's share: the free stacks on its own list, whose links live in
/// the stacks themselves, then pieces, as many as it takes before none
/// are left.
fn unmapShare(w: *Worker, ex: *Exit) void {
    const stack_span = rt.task_guard + rt.task_stack_size + std.heap.pageSize();
    while (w.stacks.free) |n| {
        w.stacks.free = n.next;
        unmapForExit(n.stack.base, stack_span);
    }
    w.stacks.free_count = 0;
    // The spare list's stacks go with whichever worker takes them first.
    if (spare.lock.tryLock()) {
        defer spare.lock.unlock();
        while (spare.head) |n| {
            spare.head = n.next;
            unmapForExit(n.stack.base, stack_span);
        }
        spare.count.store(0, .monotonic);
    }
    while (true) {
        const k = ex.next.fetchAdd(1, .monotonic);
        if (k >= ex.total) return;
        var i: usize = 0;
        while (ex.first[i + 1] <= k) i += 1;
        const r = ex.ranges[i];
        const piece = ex.piece[i];
        const at = r.start - r.start % piece + (k - ex.first[i]) * piece;
        const lo = @max(at, r.start);
        const hi = @min(at + piece, r.start + r.len);
        unmapForExit(lo, hi - lo);
        _ = ex.finished.fetchAdd(1, .seq_cst);
    }
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

    /// Push `f`, and give whether the ring held others; when it is full,
    /// move half of it, and `f`, to the global queue.
    fn push(r: *Ring, f: *Fiber) bool {
        while (true) {
            const t = r.tail.load(.monotonic);
            const h = r.head.load(.acquire);
            if (t -% h < size) {
                r.slots[t % size].store(f, .monotonic);
                r.tail.store(t +% 1, .seq_cst);
                return t != h;
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
            return true;
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
            for (buf[1..n]) |g| _ = r.push(g);
            return buf[0];
        }
    }
};

/// The global queue: fibers made outside the workers, and the overflow
/// of full rings. A spin lock guards it; `count` lets a worker see it is
/// empty without taking the lock.
const Global = struct {
    /// Taken uncounted (`lockApart`): the queue is reached only from the
    /// scheduler's entries, its workers, and its monitor. On a cache line
    /// of its own with the fields below, which every worker writes.
    lock: SpinLock align(std.atomic.cache_line) = .{},
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
        g.lock.lockApart();
        defer g.lock.unlockApart();
        if (g.tail) |t| t.next = list else g.head = list;
        g.tail = last;
        _ = g.count.fetchAdd(n, .seq_cst);
    }

    fn pop(g: *Global) ?*Fiber {
        if (g.count.load(.acquire) == 0) return null;
        g.lock.lockApart();
        defer g.lock.unlockApart();
        const f = g.head orelse return null;
        g.head = f.next;
        if (g.head == null) g.tail = null;
        _ = g.count.fetchSub(1, .seq_cst);
        return f;
    }
};

/// The workers asleep, a stack a spin lock guards.
const Sleepers = struct {
    /// Taken uncounted (`lockApart`), as `Global`'s, and on a cache line
    /// of its own, as `Global`'s.
    lock: SpinLock align(std.atomic.cache_line) = .{},
    top: ?*Worker = null,
    count: std.atomic.Value(u32) = .init(0),

    fn push(s: *Sleepers, w: *Worker) void {
        s.lock.lockApart();
        defer s.lock.unlockApart();
        w.next_sleeper = s.top;
        s.top = w;
        _ = s.count.fetchAdd(1, .seq_cst);
    }

    fn pop(s: *Sleepers) ?*Worker {
        s.lock.lockApart();
        defer s.lock.unlockApart();
        const w = s.top orelse return null;
        s.top = w.next_sleeper;
        _ = s.count.fetchSub(1, .seq_cst);
        return w;
    }

    /// Take `w` off the list; false when a waker took it first.
    fn remove(s: *Sleepers, w: *Worker) bool {
        s.lock.lockApart();
        defer s.lock.unlockApart();
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

    /// Take the lock. A waiter reads until the lock looks free and only
    /// then tries to take it, so waiters do not pass the line between
    /// them while the holder works; it never yields its thread, since a
    /// yield is a system call each time and the pool's lock is held only
    /// between its threads' calls (on loco at one worker, a yield after
    /// 100 reads raises kernel time by 43%).
    pub fn lock(l: *SpinLock) void {
        if (preempt) holdOff();
        while (l.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            while (l.held.load(.monotonic)) std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(l: *SpinLock) void {
        l.held.store(false, .release);
        if (preempt) holdOn();
    }

    pub fn tryLock(l: *SpinLock) bool {
        if (preempt) holdOff();
        const took = l.held.cmpxchgStrong(false, true, .acquire, .monotonic) == null;
        if (preempt and !took) holdOn();
        return took;
    }

    /// Take the lock in code apart from the program's, uncounted: a
    /// signal that comes while it is held finds the program counter
    /// outside `preempt_section` and stops nothing, so long as no code
    /// in the section runs before `unlockApart`. Only the scheduler's
    /// own lists and the bodies of entries reached through a call never
    /// inlined (`XApart`) take a lock so; test/cli/preempt_section.sh
    /// checks that none lies in the section, and a safe build checks
    /// where each runs (`mustNotBeInCode`).
    pub inline fn lockApart(l: *SpinLock) void {
        if (preempt and std.debug.runtime_safety) mustNotBeInCode(programCounter());
        // Uncounted: apart from the program's code.
        while (l.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) {
            while (l.held.load(.monotonic)) std.atomic.spinLoopHint();
        }
    }

    /// Let go a lock `lockApart` took.
    pub inline fn unlockApart(l: *SpinLock) void {
        l.held.store(false, .release);
    }
};

/// The address of the instruction it is inlined at, in a program built
/// to be preempted (x86-64 or arm64).
inline fn programCounter() usize {
    return switch (builtin.cpu.arch) {
        .x86_64 => asm volatile ("leaq (%%rip), %[at]"
            : [at] "=r" (-> usize),
        ),
        .aarch64 => asm volatile ("adr %[at], ."
            : [at] "=r" (-> usize),
        ),
        else => 0,
    };
}

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
pub const Label = struct {
    actor: []const u8,
    method: []const u8,
    /// Not a method: a free slot in the actor's mailbox, which a call made
    /// with `&` waits for (`tasks.actorSpawn`).
    slot: bool = false,
};

/// What a fiber waits on while it blocks.
pub const Blocked = union(enum) {
    /// A task's end.
    task: *Header,
    /// An actor's answer to a call.
    call: CallWait,
    /// The end of any of several tasks: a set that can fail, or
    /// `task.all`.
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
    /// A panic on the fiber: the actor dies (`tasks.actorsDie`).
    die: *const fn (*Held) void,
    next: ?*Held,
    /// The fiber, and what it waits on, while it blocks (`block`).
    fiber: *Fiber = undefined,
    blocked: *const Blocked = undefined,
};

/// Held while a fiber walks the chain of waits.
var graph_var: std.atomic.Value(bool) = .init(false);
const graph = split.cell(&graph_var, "sched.graph");

fn lockGraph() void {
    if (preempt) holdOff();
    while (graph.cmpxchgWeak(false, true, .seq_cst, .monotonic) != null) std.atomic.spinLoopHint();
}

fn unlockGraph() void {
    graph.store(false, .seq_cst);
    if (preempt) holdOn();
}

/// The running fiber blocks on `b` until `unblock`: publish it, and walk
/// the chain of waits from it. One that can never end, by coming back
/// here or by leading into a cycle of other waits, is a deadlock, which
/// panics naming the calls of its cycle.
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
    if (leadsOn(b)) walkFrom(f, b);
}

/// Call `f(args)` on the running fiber's worker's own stack, below the
/// point it switched to the fiber (`Worker.sp`), unused while the fiber
/// runs, as Go's `systemstack` does: code whose stack the fiber's could
/// not bound runs there instead (docs/history/records/2026-11/task-memory/
/// cold-paths.md). The rules:
///
/// 1. No signal stops the fiber while `f` runs (`holdOff`): a stop would
///    save its context inside the worker's own frames.
/// 2. `f` never parks, yields, or switches fibers: the worker's loop would
///    reuse the stack under it. A safe build panics if it tries
///    (`checkOffOwnStack`).
/// 3. A panic in `f` goes back to the fiber's stack first and panics
///    there (`panicOnFiberStack`).
/// 4. Called from code already on the worker's stack, and off a worker
///    or outside a fiber (an after-hook, `main` before the scheduler),
///    `f` runs where it is.
///
/// Never inlined, so its calls stay in a function of their own, which
/// `tools/stack-census.py` counts as its frame alone: each call it makes
/// runs on a worker's stack or outside any task.
pub noinline fn onWorkerStack(comptime f: anytype, args: anytype) @typeInfo(@TypeOf(f)).@"fn".return_type.? {
    const R = @typeInfo(@TypeOf(f)).@"fn".return_type.?;
    const w = me() orelse return @call(.auto, f, args);
    if (w.current == null or w.on_own_stack) return @call(.auto, f, args);
    const OnWorker = struct {
        args: @TypeOf(args),
        result: R = undefined,

        fn run(p: *anyopaque) callconv(.c) void {
            const c: *@This() = @ptrCast(@alignCast(p));
            c.result = @call(.auto, f, c.args);
        }
    };
    var call: OnWorker = .{ .args = args };
    if (preempt) holdOff();
    w.back_sp = (stackPointer() - 256) & ~@as(usize, 15);
    w.on_own_stack = true;
    // Below the worker's saved registers, past a red zone, 16-aligned.
    rt.switchStack(&call, &OnWorker.run, (w.sp - 256) & ~@as(usize, 15));
    w.on_own_stack = false;
    if (preempt) holdOn();
    return call.result;
}

/// The stack pointer here.
inline fn stackPointer() usize {
    return switch (builtin.cpu.arch) {
        .aarch64 => asm volatile ("mov %[sp], sp"
            : [sp] "=r" (-> usize),
        ),
        .x86_64 => asm volatile ("mov %%rsp, %[sp]"
            : [sp] "=r" (-> usize),
        ),
        else => @frameAddress(),
    };
}

/// Rule 2 of `onWorkerStack`: in a safe build, a fiber that would switch
/// away while its code runs on the worker's stack panics.
inline fn checkOffOwnStack(w: *Worker) void {
    if (std.debug.runtime_safety and w.on_own_stack) parkedOnOwnStack();
}

fn parkedOnOwnStack() noreturn {
    @branchHint(.cold);
    @panic("rig: a task waited or switched away while on its worker's stack (sched.onWorkerStack)");
}

/// Rule 3 of `onWorkerStack`: a panic that finds the running fiber's code
/// on its worker's stack calls `f(args)` on the fiber's own stack instead,
/// below where it left, never to come back: the worker's stack under
/// `Worker.sp` is scratch, and the panic goes on as one on the fiber's
/// stack would. Returns when the code is not on the worker's stack.
pub fn panicOnFiberStack(comptime f: anytype, args: anytype) void {
    const w = me() orelse return;
    if (!w.on_own_stack) return;
    w.on_own_stack = false;
    if (preempt) holdOn();
    const Again = struct {
        args: @TypeOf(args),

        fn run(p: *anyopaque) callconv(.c) void {
            const c: *@This() = @ptrCast(@alignCast(p));
            @call(.auto, f, c.args);
        }
    };
    var call: Again = .{ .args = args };
    rt.switchStack(&call, &Again.run, w.back_sp);
    unreachable;
}

/// `block`'s walk, on the worker's own stack (`onWorkerStack`): its
/// 16 KiB of waits, steps and message would otherwise sit on the
/// fiber's. The walk holds the graph's lock, so no signal stops the fiber
/// meanwhile (`lockGraph`).
noinline fn walkFrom(f: *Fiber, b: *const Blocked) void {
    if (onWorkerStack(walkOn, .{ f, b })) |t| {
        unblock();
        @panic(t);
    }
}

/// The walk, on the worker's stack: the deadlock's message, if the walk
/// finds one. The message is copied off that stack, which the worker uses
/// again once the fiber stops, to memory of its own that the panic's
/// report reads and that stays: a deadlock's panic is rare, and its
/// report may wait on the output's lock.
noinline fn walkOn(f: *Fiber, b: *const Blocked) ?[]const u8 {
    var walk: Walk = .{ .me = f };
    var buf: [1024]u8 = undefined;
    lockGraph();
    const text = if (walk.stuck(b, 0) and walk.holds()) walk.describe(&buf) else null;
    unlockGraph();
    const t = text orelse return null;
    return std.heap.page_allocator.dupe(u8, t) catch "deadlock";
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
    /// The first cycle found, to name: back to `me`, or among the waits
    /// `me`'s leads into.
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
        for (w.path[0..depth], 0..) |p, i| if (p == b) {
            // The waits from `i` on make a cycle; when it does not pass
            // through `me`, `me` waits on it all the same.
            if (w.n == 0) {
                w.n = depth - i;
                @memcpy(w.cycle[0..w.n], w.steps[i..depth]);
            }
            return true;
        };
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
            .task => |h| !h.done.over(),
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
            if (l.slot) {
                n.out.print("a slot in {s}'s mailbox", .{l.actor}) catch {};
            } else n.out.print("{s}.{s}", .{ l.actor, l.method }) catch {};
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
        return x.slot == y.slot and std.mem.eql(u8, x.actor, y.actor) and std.mem.eql(u8, x.method, y.method);
    }
};

// -----------------------------------------------------------------------------
// Tasks
// -----------------------------------------------------------------------------

/// A one-shot completion: a task's end (`Header`), or an actor call's
/// answer (`tasks.Message`). One fiber may wait for it: it records itself
/// and the epoch of its wait, and marks the status `waited`. What
/// finishes it marks it `ending`, wakes that waiter, if any, and only
/// then `ended`, and the waiter goes on only once it reads `ended`, so
/// the record it may then free is no longer touched.
pub const Done = struct {
    status: std.atomic.Value(u8) = .init(running),
    waiter: std.atomic.Value(?*Fiber) = .init(null),
    epoch: std.atomic.Value(u32) = .init(0),

    const running = 0;
    const waited = 1;
    const ending = 2;
    const ended = 3;

    pub const finish = if (preempt) finishApart else finishIn;

    /// `finish` in a program built to be preempted: never inlined into
    /// the program's own code (`mustNotBeInCode`).
    noinline fn finishApart(d: *Done) void {
        finishIn(d);
    }

    fn finishIn(d: *Done) void {
        if (d.status.swap(ending, .seq_cst) == waited) {
            _ = interruptIn(d.waiter.load(.seq_cst).?, d.epoch.load(.seq_cst), false);
        }
        d.status.store(ended, .seq_cst);
    }

    /// Whether it is finished, or finishing: for a deadlock's walk.
    pub fn over(d: *const Done) bool {
        return d.status.load(.seq_cst) >= ending;
    }

    /// Whether it is finished; while it is finishing, wait for that.
    pub fn isDone(d: *Done) bool {
        while (true) {
            const s = d.status.load(.seq_cst);
            if (s == ended) return true;
            if (s != ending) return false;
            std.atomic.spinLoopHint();
        }
    }

    /// A select's arm on it (`tasks.EndArm`): record wait `epoch` of
    /// `fiber` as the one to wake, as `wait` does, and give whether it
    /// is finished or finishing already, when nothing may wake the
    /// fiber for it. The fiber is its one waiter: it holds what this is
    /// the end of, and two arms of its select on one end record the same.
    pub fn watch(d: *Done, fiber: *Fiber, epoch: u32) bool {
        d.waiter.store(fiber, .seq_cst);
        d.epoch.store(epoch, .seq_cst);
        if (d.status.cmpxchgStrong(running, waited, .seq_cst, .seq_cst)) |s| return s != waited;
        return false;
    }

    /// The watcher begins wait `epoch`: that is the one to wake. It
    /// looks once more after (`over`), so a finish that read the wait
    /// before is seen there.
    pub fn rewatch(d: *Done, epoch: u32) void {
        d.epoch.store(epoch, .seq_cst);
    }

    /// Take a watch back, so what finishes it later wakes no one, and the
    /// next waiter, on any fiber, records itself afresh. While it is
    /// finishing, wait for that, so its waker is done with the watcher.
    pub fn unwatch(d: *Done) void {
        _ = d.status.cmpxchgStrong(waited, running, .seq_cst, .seq_cst);
        _ = d.isDone();
    }

    /// Wait for it to finish, or, when `cancel` is given, for that flag
    /// to be set first, or for `deadline` to pass, when this gives false.
    pub const wait = if (preempt) waitApart else waitIn;

    /// `wait` in a program built to be preempted: never inlined into the
    /// program's own code (`mustNotBeInCode`).
    noinline fn waitApart(d: *Done, cancel: ?*const std.atomic.Value(bool), deadline: ?i96) bool {
        return waitIn(d, cancel, deadline);
    }

    inline fn waitIn(d: *Done, cancel: ?*const std.atomic.Value(bool), deadline: ?i96) bool {
        while (!d.isDone()) {
            if (cancel) |c| if (c.load(.seq_cst)) return false;
            if (deadline) |t| if (nowNs() >= t) return false;
            const e = beginWait(cancel != null);
            d.waiter.store(current().?, .seq_cst);
            d.epoch.store(e, .seq_cst);
            if (d.status.cmpxchgStrong(running, waited, .seq_cst, .seq_cst)) |s| {
                if (s != waited) continue;
            }
            if (cancel) |c| if (c.load(.seq_cst)) return false;
            commitWaitIn(e, deadline);
        }
        return true;
    }
};

/// What a task's waiter shares with the fiber that runs it: the task's
/// end (`Done`), whether it panicked, and how to free the record. The end
/// is published by the worker the fiber left for good (`end`), so the
/// record is never freed while the fiber still runs.
pub const Header = struct {
    fiber: Fiber,
    done: Done = .{},
    /// Set when the task panicked and ended where it stood, with no
    /// result (`abandon`).
    panicked: std.atomic.Value(bool) = .init(false),
    destroy: *const fn (*Header) void,

    pub fn end(f: *Fiber) void {
        const h: *Header = @fieldParentPtr("fiber", f);
        h.done.finish();
    }

    /// Wait for the task to end, or, when `cancel` is given, for that
    /// flag to be set first, or for `deadline` to pass, when this gives
    /// false.
    const waitEnd = if (preempt) waitEndApart else waitEndIn;

    noinline fn waitEndApart(h: *Header, cancel: ?*const std.atomic.Value(bool), deadline: ?i96) bool {
        return waitEndIn(h, cancel, deadline);
    }

    fn waitEndIn(h: *Header, cancel: ?*const std.atomic.Value(bool), deadline: ?i96) bool {
        if (h.done.isDone()) return true;
        const b: Blocked = .{ .task = h };
        block(&b);
        defer unblock();
        {
            const w = me().?;
            // Not started, and next on this worker: run it now. A fiber in
            // the "run next" slot may also be one woken partway, which
            // goes on where it stopped instead. A wait with a deadline
            // sleeps on its timer instead.
            if (deadline == null and h.fiber.sp == 0 and nextHolds(w, &h.fiber)) handoff(w, h, cancel);
        }
        return Done.waitIn(&h.done, cancel, deadline);
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
/// next on it (in one of its "run next" slots): switch
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
    // Taken by a worker with nothing else to do meanwhile: wait for it the
    // usual way.
    if (!takeFromNext(w, f)) return;
    h.done.waiter.store(waiter, .seq_cst);
    h.done.epoch.store(e, .seq_cst);
    h.done.status.store(Done.waited, .seq_cst);
    // The waiter is marked asleep by the task, once this switch has saved
    // it (`fiberMain`), so no waker queues it while it still runs.
    f.handoff = waiter;
    f.handoff_epoch = e;
    prepare(w, f);
    spread(w);
    w.current = f;
    w.ran += 1;
    if (f.home != null) w.ran_pinned += 1;
    checkOffOwnStack(w);
    switchTo(&waiter.sp, f.sp);
    // Back: the task ended straight back here, or stopped and later ended
    // the usual way, or a cancel woke this fiber first.
    checkHome(waiter);
    const now = me().?;
    if (now.returned) |done| {
        now.returned = null;
        endStack(now, done);
        h.done.status.store(Done.ended, .seq_cst);
    }
}

/// Start `f(args...)` as a fiber, ready to run, and give its record,
/// and an `Extra` the record holds for the caller (`tasks.zig` keeps a
/// task's `Control` there), which `f` gets first. A `local` task, and the
/// fiber making it, are pinned to this worker (`pinHere`).
pub const spawn = if (preempt) spawnApart else spawnIn;

/// `spawn` in a program built to be preempted: never inlined into the
/// program's own code, and one call in all (`mustNotBeInCode`).
noinline fn spawnApart(comptime T: type, comptime Extra: type, comptime f: anytype, args: anytype, extra: Extra, local: bool, dense_stack: bool) Spawned(T, Extra) {
    return spawnIn(T, Extra, f, args, extra, local, dense_stack);
}

fn spawnIn(comptime T: type, comptime Extra: type, comptime f: anytype, args: anytype, extra: Extra, local: bool, dense_stack: bool) Spawned(T, Extra) {
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

        /// `destroy` in a program built to be preempted: never inlined
        /// into a task's waiter (`Job.free`), in the program's own code,
        /// since Zig's allocator takes a lock of its own, uncounted.
        noinline fn destroyApart(h: *Header) void {
            destroy(h);
        }
    };
    if (!started.*) startWorkers();
    const full = std.heap.smp_allocator.create(Full) catch rt.oom();
    full.* = .{ .job = .{ .header = .{ .fiber = .{ .run = Full.start, .done = Header.end, .dense = dense_stack }, .destroy = if (preempt) Full.destroyApart else Full.destroy } }, .extra = extra, .args = args };
    // An `Extra` that names its task's fiber is given it, for a cancel to
    // reach the fiber's wait (`interruptForCancel`), and one that records
    // its task somewhere does so before the task can run (`made`).
    if (@hasField(Extra, "fiber")) full.extra.fiber = &full.job.header.fiber;
    if (@hasDecl(Extra, "made")) full.extra.made();
    if (local) full.job.header.fiber.home = pinHereIn();
    wakeIn(&full.job.header.fiber);
    return .{ .job = &full.job, .extra = &full.extra };
}

/// Start `f(args...)` as a fiber no one waits for: its record frees
/// itself once the fiber has ended (an actor's runner, `tasks.Actor`).
pub const spawnDetached = if (preempt) spawnDetachedApart else spawnDetachedIn;

/// `spawnDetached` in a program built to be preempted: never inlined
/// into the program's own code (`mustNotBeInCode`).
noinline fn spawnDetachedApart(comptime f: anytype, args: anytype) void {
    return spawnDetachedIn(f, args);
}

fn spawnDetachedIn(comptime f: anytype, args: anytype) void {
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
    if (!started.*) startWorkers();
    const full = std.heap.smp_allocator.create(Full) catch rt.oom();
    full.* = .{ .fiber = .{ .run = Full.start, .done = Full.end }, .args = args };
    wakeIn(&full.fiber);
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

    /// Whether it lies in a reservation of dense stacks (`takeDense`):
    /// only those are shorter than a large stack.
    fn isDense(s: Stack) bool {
        return s.len < rt.task_stack_size;
    }

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
pub const takeBlock = if (preempt) takeBlockApart else takeBlockIn;

/// `takeBlock` in a program built to be preempted: never inlined into
/// the program's own code (`mustNotBeInCode`).
noinline fn takeBlockApart() *[block_size]u8 {
    return takeBlockIn();
}

fn takeBlockIn() *[block_size]u8 {
    if (me()) |w| if (w.blocks) |b| {
        w.blocks = b.next;
        w.block_count -= 1;
        return @ptrCast(b);
    };
    return std.heap.page_allocator.create([block_size]u8) catch rt.oom();
}

/// Give back a block `takeBlock` gave: this worker keeps it, or the
/// system has it back.
pub const giveBlock = if (preempt) giveBlockApart else giveBlockIn;

/// `giveBlock` in a program built to be preempted: never inlined into
/// the program's own code (`mustNotBeInCode`).
noinline fn giveBlockApart(given: *[block_size]u8) void {
    return giveBlockIn(given);
}

fn giveBlockIn(given: *[block_size]u8) void {
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

/// One class of a worker's stacks: those it keeps free, linked through
/// the stacks themselves, and those of its last reservation no fiber has
/// run on yet, `fresh_left` of them from `fresh_next` up.
const StackList = struct {
    free: ?*FreeStack = null,
    free_count: u32 = 0,
    fresh_next: usize = 0,
    fresh_left: u32 = 0,
};

comptime {
    std.debug.assert(@sizeOf(FreeStack) <= rt.unwind_headroom);
}

/// How many stacks a worker keeps free on its own list. Past that, it
/// moves `spare_batch` of them to the spare list all workers share
/// (`Spare`), from which a worker with none takes a batch back before it
/// maps new ones.
const keep_free = 32;

/// How many free stacks the spare list keeps for each worker once the
/// workers are idle: with `keep_free`, at most 64 a worker, the rest
/// returned to the system (`trimSpare`).
const spare_per_worker = 32;

/// How many stacks past `spare_per_worker` a worker the spare list holds
/// before the worker that gives it more trims it at once, not when it is
/// next idle.
const spare_over = 1024;

/// How many stacks move between a worker's list and the spare list at once.
const spare_batch = 16;

/// The free stacks no worker holds, linked as a worker's are. A burst of
/// tasks ends with more free stacks than any worker keeps, often on other
/// workers than the ones that mapped them. Returning each to the system
/// as its fiber ends flushed the TLB of every core running the program,
/// once a stack. Here they wait until a worker is idle, which returns the
/// surplus in address order, a run of neighbouring stacks (`chunk`) in
/// one call and one flush.
const Spare = struct {
    lock: SpinLock align(std.atomic.cache_line) = .{},
    head: ?*FreeStack = null,
    /// Written under the lock; read without it to skip the lock when the
    /// list has nothing to give or nothing to trim.
    count: std.atomic.Value(u32) = .init(0),
};
var spare_var: Spare = .{};
const spare = split.cell(&spare_var, "sched.spare");
var dense_spare_var: Spare = .{};
const dense_spare = split.cell(&dense_spare_var, "sched.dense_spare");

/// How many stacks one reservation of address space holds.
const chunk = 16;

/// A stack to run a fiber on: one a fiber that ended on this worker
/// left, or the next of its last reservation, or the first of a new
/// one. The stacks of a reservation stay untouched until a fiber runs on
/// each, so they hold no page, nor the table that would map it.
fn takeStack() Stack {
    const w = me();
    const guard = rt.task_guard;
    const len = rt.task_stack_size;
    const span = guard + len + std.heap.pageSize();
    if (w) |x| {
        if (x.stacks.free == null and spare.count.load(.monotonic) != 0) takeSpare(&x.stacks, spare);
        if (x.stacks.free) |n| {
            x.stacks.free = n.next;
            x.stacks.free_count -= 1;
            return n.stack;
        }
        if (x.stacks.fresh_left > 0) {
            const b = x.stacks.fresh_next;
            x.stacks.fresh_next += span;
            x.stacks.fresh_left -= 1;
            return .{ .base = b, .guard = guard, .len = len };
        }
    }
    const count: usize = if (w != null) chunk else 1;
    const got = std.posix.mmap(null, span * count, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch rt.oom();
    const base = @intFromPtr(got.ptr);
    rt.fast_alloc.keepSmall(base, span * count);
    for (0..count) |i| {
        const b = base + i * span;
        if (std.posix.errno(std.posix.system.mprotect(@ptrFromInt(b + guard), len, .{ .READ = true, .WRITE = true })) != .SUCCESS) rt.oom();
    }
    if (w) |x| {
        x.stacks.fresh_next = base + span;
        x.stacks.fresh_left = @intCast(count - 1);
    }
    return .{ .base = base, .guard = guard, .len = len };
}

/// Keep a stack a fiber has finished with, for the next on `w`, or
/// return it to the system when `w` keeps enough, or always in a build
/// that sanitizes (`RIG_SANITIZE=1`), so a late write into it faults.
fn releaseStack(w: *Worker, s: Stack) void {
    if (s.isDense()) return releaseDense(w, s);
    if (rt.sanitize) return unmapStack(s);
    if (w.stacks.free_count >= keep_free and giveSpare(&w.stacks, spare) > spareKept() + spare_over) trimSpare();
    const n: *FreeStack = @ptrFromInt(s.base + s.guard + s.len - @sizeOf(FreeStack));
    n.* = .{ .stack = s, .next = w.stacks.free };
    w.stacks.free = n;
    w.stacks.free_count += 1;
}

/// Move `spare_batch` of the free stacks of `l` to the spare list `sp`,
/// and give how many it then holds.
fn giveSpare(l: *StackList, sp: *Spare) u32 {
    var last = l.free.?;
    for (1..spare_batch) |_| last = last.next.?;
    const first = l.free.?;
    l.free = last.next;
    l.free_count -= spare_batch;
    sp.lock.lock();
    defer sp.lock.unlock();
    last.next = sp.head;
    sp.head = first;
    const n = sp.count.raw + spare_batch;
    sp.count.store(n, .monotonic);
    return n;
}

/// How many free stacks the spare list keeps.
fn spareKept() u32 {
    return @intCast(spare_per_worker * workersNow().len);
}

/// Return the spare list's stacks past `spareKept` to the system, in
/// address order, each run of neighbouring stacks in one call: as a
/// worker goes idle (`loop`), or as a burst passes `spare_over`.
fn trimSpare() void {
    const sp = spare;
    const kept = spareKept();
    sp.lock.lock();
    var list = sp.head;
    const n = sp.count.raw;
    sp.head = null;
    sp.count.store(0, .monotonic);
    sp.lock.unlock();
    if (n <= kept) return putSpare(sp, list, n);
    list = sortStacks(list, n);
    const span = rt.task_guard + rt.task_stack_size + std.heap.pageSize();
    var left = n - kept;
    while (left > 0) {
        const lo = list.?.stack.base;
        var hi = lo + span;
        var taken: u32 = 1;
        var rest = list.?.next;
        // Each link lives in its stack: read before the run is unmapped.
        while (taken < left) : (taken += 1) {
            const r = rest orelse break;
            if (r.stack.base != hi) break;
            hi += span;
            rest = r.next;
        }
        std.posix.munmap(@as([*]align(std.heap.page_size_min) u8, @ptrFromInt(lo))[0 .. hi - lo]);
        list = rest;
        left -= taken;
    }
    putSpare(sp, list, kept);
}

/// Put `n` stacks, linked from `list`, back on the spare list.
fn putSpare(sp: *Spare, list: ?*FreeStack, n: u32) void {
    const first = list orelse return;
    var last = first;
    while (last.next) |x| last = x;
    sp.lock.lock();
    defer sp.lock.unlock();
    last.next = sp.head;
    sp.head = first;
    sp.count.store(sp.count.raw + n, .monotonic);
}

/// The `n` free stacks of `list`, in address order: a merge sort of the
/// links in place, bottom up, in runs of 1, 2, 4 and on, so its frame is
/// fixed and the worker's stack it runs on is bounded (no recursion).
fn sortStacks(list: ?*FreeStack, n: u32) ?*FreeStack {
    var head = list;
    var width: usize = 1;
    while (width < n) : (width *= 2) {
        var rest = head;
        var tail: *?*FreeStack = &head;
        while (rest) |a| {
            const b = cutAfter(a, width);
            rest = if (b) |x| cutAfter(x, width) else null;
            tail = mergeStacks(tail, a, b);
        }
    }
    return head;
}

/// End the run of `k` free stacks that starts at `first`, and give the
/// stack after it.
fn cutAfter(first: *FreeStack, k: usize) ?*FreeStack {
    var last = first;
    for (1..k) |_| last = last.next orelse return null;
    const after = last.next;
    last.next = null;
    return after;
}

/// Merge the address-ordered runs `a` and `b` into `tail.*`, and give the
/// link after the merged run's last stack.
fn mergeStacks(tail_in: *?*FreeStack, a_in: ?*FreeStack, b_in: ?*FreeStack) *?*FreeStack {
    var tail = tail_in;
    var a = a_in;
    var b = b_in;
    while (a != null and b != null) {
        const take_a = a.?.stack.base < b.?.stack.base;
        const x = if (take_a) a.? else b.?;
        if (take_a) a = x.next else b = x.next;
        tail.* = x;
        tail = &x.next;
    }
    tail.* = if (a != null) a else b;
    while (tail.*) |x| tail = &x.next;
    return tail;
}

/// Take up to `spare_batch` stacks from the spare list `sp` for `l`, which
/// has none of its own.
fn takeSpare(l: *StackList, sp: *Spare) void {
    sp.lock.lock();
    defer sp.lock.unlock();
    var n: u32 = 0;
    while (n < spare_batch) : (n += 1) {
        const got = sp.head orelse break;
        sp.head = got.next;
        got.next = l.free;
        l.free = got;
    }
    sp.count.store(sp.count.raw - n, .monotonic);
    l.free_count += n;
}

/// Return the spare list's stacks to the system, as the scheduler ends.
fn freeSpare() void {
    const sp = spare;
    while (sp.head) |n| {
        sp.head = n.next;
        unmapStack(n.stack);
    }
    sp.count.store(0, .monotonic);
}

// Dense stacks: tasks with no recursion and no call through a pointer
// (`Fiber.dense`) take a stack close beside the others of its reservation,
// so they share page tables, under a guard sized from the executable's own
// frames (`rt.denseGuard`). A fault in the guard is a stack overflow, as
// on a large stack.

/// How many dense stacks a worker reserves at a time.
const dense_chunk = 32;

/// The address space one mapping of dense stacks holds.
const dense_region: usize = 64 << 30;

/// Where a region's stacks begin: a page table's reach on arm64, so a
/// chunk fills tables whole.
const dense_align: usize = 32 << 20;

const Dense = struct {
    /// On a cache line of its own with the fields below (`OnLine`).
    lock: SpinLock align(std.atomic.cache_line) = .{},
    /// The guard (`rt.denseGuard`), read as the scheduler starts; 0 for
    /// no dense stacks.
    guard: usize = 0,
    /// The part of the current region not yet handed out.
    next: usize = 0,
    end: usize = 0,
    /// The bases of stacks returned to the system whose addresses are
    /// kept, under `lock`. Not linked through the stacks, whose pages are
    /// gone (`trimDense`).
    cold: std.ArrayList(usize) = .empty,
};
var dense_var: Dense = .{};
const dense = split.cell(&dense_var, "sched.dense");

/// A worker's dense stacks, each list on a cache line of its own, and
/// kept out of `Worker`: where its fields fall on their lines is what the
/// scheduler's speed depends on, and Zig lays them out.
const DenseList = struct { list: StackList align(std.atomic.cache_line) = .{} };
var dense_lists_var: [max_workers]DenseList = @splat(.{});
const dense_lists = split.cell(&dense_lists_var, "sched.dense_lists");

/// The dense stacks `w` keeps.
fn denseOf(w: *Worker) *StackList {
    const i = (@intFromPtr(w) - @intFromPtr(all_workers.*.ptr)) / @sizeOf(Worker);
    return &dense_lists[i].list;
}

/// Read the guard the executable holds, as the scheduler starts.
fn openDense() void {
    dense.guard = rt.denseGuard();
}

/// The dense stack at `base`.
fn denseAt(base: usize) Stack {
    return .{ .base = base, .guard = dense.guard, .len = rt.dense_stride - dense.guard - std.heap.pageSize() };
}

/// A dense stack for a fiber on `x`, or null for a large one: in a program
/// with no guard, or out of address space. As `takeStack`,
/// but the reservation is shared and never returned to the system.
fn takeDense(x: *Worker) ?Stack {
    if (dense.guard == 0) return null;
    const l = denseOf(x);
    if (l.free == null and dense_spare.count.load(.monotonic) != 0) takeSpare(l, dense_spare);
    if (l.free) |n| {
        l.free = n.next;
        l.free_count -= 1;
        return n.stack;
    }
    if (l.fresh_left == 0) {
        @branchHint(.unlikely);
        if (takeCold(l)) |s| return s;
        if (!reserveDense(l)) return null;
    }
    const b = l.fresh_next;
    l.fresh_next += rt.dense_stride;
    l.fresh_left -= 1;
    return writableDense(denseAt(b));
}

/// A dense stack whose pages went back (`trimDense`), and up to
/// `spare_batch - 1` more for the list `l`, so workers meet at the lock
/// once a batch and not once a stack. Null when there are none. Linking
/// one touches its top page, which its fiber would touch first anyway.
noinline fn takeCold(l: *StackList) ?Stack {
    var batch: [spare_batch]usize = undefined;
    dense.lock.lock();
    const n = @min(batch.len, dense.cold.items.len);
    const from = dense.cold.items.len - n;
    @memcpy(batch[0..n], dense.cold.items[from..]);
    dense.cold.items.len = from;
    dense.lock.unlock();
    if (n == 0) return null;
    for (batch[1..n]) |base| {
        const s = denseAt(base);
        const n2: *FreeStack = @ptrFromInt(s.base + s.guard + s.len - @sizeOf(FreeStack));
        n2.* = .{ .stack = s, .next = l.free };
        l.free = n2;
        l.free_count += 1;
    }
    return denseAt(batch[0]);
}

/// Give the list `l` a chunk of new dense stacks, mapping a region when the last
/// is used up. False when no region can be reserved.
noinline fn reserveDense(l: *StackList) bool {
    const size = dense_chunk * rt.dense_stride;
    dense.lock.lock();
    if (dense.end - dense.next < size) {
        const got = std.posix.mmap(null, dense_region, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch {
            dense.lock.unlock();
            return false;
        };
        rt.fast_alloc.keepSmall(@intFromPtr(got.ptr), dense_region);
        dense.next = std.mem.alignForward(usize, @intFromPtr(got.ptr), dense_align);
        dense.end = @intFromPtr(got.ptr) + dense_region;
    }
    const base = dense.next;
    dense.next += size;
    dense.lock.unlock();
    l.fresh_next = base;
    l.fresh_left = dense_chunk;
    return true;
}

/// Make the dense stack `s` writable, as it is first handed out, so a
/// chunk's stacks no task uses take no system call.
fn writableDense(s: Stack) Stack {
    if (std.posix.errno(std.posix.system.mprotect(@ptrFromInt(s.base + s.guard), s.len, .{ .READ = true, .WRITE = true })) != .SUCCESS) rt.oom();
    return s;
}

/// Keep a dense stack a fiber has finished with, as `releaseStack`. A
/// build that sanitizes makes it inaccessible and never uses it again, so
/// a late write into it faults.
fn releaseDense(w: *Worker, s: Stack) void {
    if (rt.sanitize) return retireDense(s);
    const l = denseOf(w);
    if (l.free_count >= keep_free and giveSpare(l, dense_spare) > spareKept() + spare_over) trimDense();
    const n: *FreeStack = @ptrFromInt(s.base + s.guard + s.len - @sizeOf(FreeStack));
    n.* = .{ .stack = s, .next = l.free };
    l.free = n;
    l.free_count += 1;
}

/// Make the dense stack `s` inaccessible for good, so a late write into it
/// faults. Its address is not used again.
fn retireDense(s: Stack) void {
    _ = std.posix.system.mprotect(@ptrFromInt(s.base + s.guard), s.len, .{});
}

/// Return the pages of the dense spare list's stacks past `spareKept` to
/// the system, in address order, each run in one call, as `trimSpare`.
/// Their addresses stay reserved, and wait on `Dense.cold`: their links
/// went with their pages.
noinline fn trimDense() void {
    const sp = dense_spare;
    const kept = spareKept();
    sp.lock.lock();
    const list = sp.head;
    const n = sp.count.raw;
    sp.head = null;
    sp.count.store(0, .monotonic);
    sp.lock.unlock();
    trimDenseList(sp, list, n, kept);
}

/// `trimDense` of the `n` stacks of `list`, keeping `kept`.
fn trimDenseList(sp: *Spare, first: ?*FreeStack, n: u32, kept: u32) void {
    var list = first;
    if (n <= kept) return putSpare(sp, list, n);
    var left = n - kept;
    list = sortStacks(list, n);
    var returned: u32 = 0;
    while (left > 0) {
        const lo = list.?.stack.base;
        var hi = lo + rt.dense_stride;
        var taken: u32 = 1;
        var rest = list.?.next;
        // Each link lives in its stack: read before the run's pages go.
        while (taken < left) : (taken += 1) {
            const r = rest orelse break;
            if (r.stack.base != hi) break;
            hi += rt.dense_stride;
            rest = r.next;
        }
        // The pages go first: the moment an address is on the list another
        // worker may take it and run on it, and Linux wipes what is
        // advised at once. Room and the addresses under one hold of the
        // lock: another worker trims too, and room made apart from them
        // is shared.
        adviseFree(lo, hi - lo);
        dense.lock.lock();
        const room = dense.cold.ensureUnusedCapacity(std.heap.smp_allocator, taken);
        if (room) |_| {
            var b = lo;
            while (b < hi) : (b += rt.dense_stride) dense.cold.appendAssumeCapacity(b);
        } else |_| {}
        dense.lock.unlock();
        room catch rt.oom();
        list = rest;
        left -= taken;
        returned += taken;
    }
    putSpare(sp, list, n - returned);
}

/// Give the pages of `[at, at + len)` back to the system and keep the
/// addresses.
fn adviseFree(at: usize, len: usize) void {
    const advice: u32 = if (builtin.os.tag == .macos) 7 else std.posix.MADV.DONTNEED; // MADV_FREE_REUSABLE
    _ = std.posix.system.madvise(@ptrFromInt(at), len, advice);
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
pub const runApart = if (preempt) runApartApart else runApartIn;

/// `runApart` in a program built to be preempted: never inlined into
/// the program's own code (`mustNotBeInCode`).
noinline fn runApartApart(home: *usize, arg: *anyopaque, entry: *const fn (*anyopaque) callconv(.c) noreturn) void {
    return runApartIn(home, arg, entry);
}

fn runApartIn(home: *usize, arg: *anyopaque, entry: *const fn (*anyopaque) callconv(.c) noreturn) void {
    if (me()) |w| checkOffOwnStack(w);
    const s = takeStack();
    const state = rt.task();
    const guard = state.stack_guard;
    state.stack_guard = .{ .lo = s.base, .hi = s.base + s.guard, .len = s.len };
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
/// `panicked`, so whoever waits for it learns so. Its stack, which the
/// caller has taken (`f.stack` null), is not given back; `ended` runs in
/// place of its end once it has switched off that stack for good, and
/// calls `Header.end` itself. It ends so even when handed its worker.
pub fn abandon(ended: *const fn (*Fiber) void) noreturn {
    const f = current().?;
    f.done = ended;
    f.handoff = null;
    const h: *Header = @fieldParentPtr("fiber", f);
    h.panicked.store(true, .seq_cst);
    finishFiber(f);
}

test "a watch on a task's end, taken back, leaves its finish waking no one" {
    // A select's arm records its fiber as the end's one waiter (`watch`)
    // and takes the watch back when another arm wins (`unwatch`): the
    // finish after, wherever the task went, touches no fiber.
    var stale: Fiber = undefined;
    var d: Done = .{};
    try std.testing.expect(!d.watch(&stale, 7));
    try std.testing.expectEqual(Done.waited, d.status.load(.seq_cst));
    // A second arm of the same select on the same end records the same.
    try std.testing.expect(!d.watch(&stale, 7));
    d.rewatch(8);
    try std.testing.expectEqual(@as(u32, 8), d.epoch.load(.seq_cst));
    d.unwatch();
    try std.testing.expectEqual(Done.running, d.status.load(.seq_cst));
    // With no waiter left, a finish that tried to wake one would stop
    // at its `.?`.
    d.waiter.store(null, .seq_cst);
    d.finish();
    try std.testing.expect(d.isDone());
    // A watch made once it is over says so, for the arm to claim.
    var e: Done = .{};
    e.finish();
    try std.testing.expect(e.watch(&stale, 1));
    e.unwatch();
    try std.testing.expect(e.isDone());
}

test "no cache line holds two workers' fields" {
    try std.testing.expect(@alignOf(Worker) >= std.atomic.cache_line);
    try std.testing.expect(@sizeOf(Worker) % std.atomic.cache_line == 0);
}

test "the scheduler's shared counters each fill whole cache lines" {
    inline for (.{ Flag, OnLine(bool), Global, Sleepers, Spare }) |T| {
        try std.testing.expect(@alignOf(T) >= std.atomic.cache_line);
        try std.testing.expect(@sizeOf(T) % std.atomic.cache_line == 0);
    }
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
    workers_override.* = 1;
    defer workers_override.* = null;
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

test "the other stacks of a new reservation stay untouched until a fiber runs on each" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var looked: usize = 0;
        var resident: usize = 0;
        fn first(_: *anyopaque) callconv(.c) void {
            // The worker has taken no stack yet, so this is the first of
            // a new reservation of `chunk`.
            const s = takeStack();
            defer releaseStack(me().?, s);
            const page = std.heap.pageSize();
            const span = s.guard + s.len + page;
            for (1..chunk) |i| {
                const top = s.base + i * span + s.guard + s.len - page;
                var v: [1]u8 = undefined;
                std.posix.mincore(@ptrFromInt(top), page, &v) catch continue;
                looked += 1;
                if (v[0] & 1 != 0) resident += 1;
            }
        }
    };
    runForTest(Run.first, 1);
    try std.testing.expectEqual(@as(usize, chunk - 1), Run.looked);
    try std.testing.expectEqual(@as(usize, 0), Run.resident);
}

test "a worker's surplus of free stacks waits on the spare list, then goes back to the system but 64 a worker" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        const n = 200;
        var stacks: [n]Stack = undefined;
        var spare_before: u32 = 0;
        var spare_after: u32 = 0;
        var kept: u32 = 0;
        var mapped: usize = 0;
        fn first(_: *anyopaque) callconv(.c) void {
            const w = me().?;
            for (&stacks) |*s| s.* = takeStack();
            // Released out of order, as tasks end.
            var i: usize = 0;
            while (i < n) : (i += 1) releaseStack(w, stacks[(i * 37) % n]);
            spare_before = spare.count.load(.monotonic);
            kept = w.stacks.free_count;
            trimSpare();
            spare_after = spare.count.load(.monotonic);
            const page = std.heap.pageSize();
            for (stacks) |s| {
                const top: [*]align(std.heap.page_size_min) u8 = @ptrFromInt(s.base + s.guard + s.len - page);
                std.posix.msync(top[0..page], std.posix.MSF.ASYNC) catch continue;
                mapped += 1;
            }
        }
    };
    runForTest(Run.first, 1);
    try std.testing.expect(Run.kept <= keep_free);
    try std.testing.expectEqual(@as(u32, Run.n), Run.spare_before + Run.kept);
    try std.testing.expectEqual(@as(u32, spare_per_worker), Run.spare_after);
    try std.testing.expectEqual(@as(usize, Run.kept + spare_per_worker), Run.mapped);
}

test "dense stacks lie one stride apart under their guards, and their pages go back while their addresses stay" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    if (rt.sanitize) return error.SkipZigTest;
    const Run = struct {
        const n = 200;
        var stacks: [n]Stack = undefined;
        var stride_ok = true;
        var writable = true;
        var dense_all = true;
        var spare_after: u32 = 0;
        var cold: usize = 0;
        var again: ?Stack = null;
        var guarded: Stack = undefined;
        fn first(_: *anyopaque) callconv(.c) void {
            const w = me().?;
            dense.guard = 64 << 10;
            for (&stacks) |*s| s.* = takeDense(me().?).?;
            for (stacks[1..dense_chunk], stacks[0 .. dense_chunk - 1]) |b, a| stride_ok = stride_ok and b.base == a.base + rt.dense_stride;
            for (stacks) |s| {
                dense_all = dense_all and s.isDense() and s.guard == dense.guard and s.guard + s.len + std.heap.pageSize() == rt.dense_stride;
                const last: *volatile usize = @ptrFromInt(s.base + s.guard + s.len - @sizeOf(usize));
                last.* = 7;
                const low: *volatile usize = @ptrFromInt(s.base + s.guard);
                low.* = 7;
                writable = writable and last.* == 7 and low.* == 7;
            }
            guarded = stacks[0];
            var i: usize = 0;
            while (i < n) : (i += 1) releaseDense(w, stacks[(i * 37) % n]);
            trimDense();
            spare_after = dense_spare.count.load(.monotonic);
            cold = dense.cold.items.len;
            // With its own list and the spare list used up, a worker takes
            // an address whose pages went back.
            const l = denseOf(w);
            while (l.free) |f| {
                l.free = f.next;
            }
            l.free_count = 0;
            while (dense_spare.head) |f| dense_spare.head = f.next;
            dense_spare.count.store(0, .monotonic);
            l.fresh_left = 0;
            again = takeDense(w);
            dense.guard = 0;
        }
    };
    runForTest(Run.first, 1);
    try std.testing.expect(Run.stride_ok);
    try std.testing.expect(Run.dense_all);
    try std.testing.expect(Run.writable);
    try std.testing.expectEqual(@as(u32, spare_per_worker), Run.spare_after);
    try std.testing.expect(Run.cold > 0);
    const s = Run.again.?;
    try std.testing.expect(s.isDense());
    try std.testing.expectEqual(@as(usize, 0), (s.base - Run.guarded.base) % rt.dense_stride);
}

test "workers that return dense stacks at once do not overrun the list of their addresses" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    if (rt.sanitize) return error.SkipZigTest;
    const Run = struct {
        const Unit = struct {};
        const workers_n = 4;
        const per = 400;
        const rounds = 30;
        var arrived: std.atomic.Value(u32) = .init(0);
        var cleared: std.atomic.Value(u32) = .init(0);
        fn trims(_: *Unit) u64 {
            var stacks: [per]Stack = undefined;
            for (0..rounds) |r| {
                for (&stacks) |*s| s.* = takeDense(me().?).?;
                var list: ?*FreeStack = null;
                for (stacks) |s| {
                    const n: *FreeStack = @ptrFromInt(s.base + s.guard + s.len - @sizeOf(FreeStack));
                    n.* = .{ .stack = s, .next = list };
                    list = n;
                }
                // Together, with the list of addresses at no capacity, so
                // each trim's room is all that holds its own addresses.
                if (arrived.fetchAdd(1, .seq_cst) + 1 == (r + 1) * workers_n) {
                    dense.lock.lock();
                    dense.cold.clearAndFree(std.heap.smp_allocator);
                    dense.lock.unlock();
                    cleared.store(@intCast(r + 1), .seq_cst);
                }
                while (cleared.load(.seq_cst) < r + 1) yield();
                trimDenseList(dense_spare, list, per, 0);
            }
            return 1;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            dense.guard = 64 << 10;
            var jobs: [workers_n]*Job(u64) = undefined;
            for (&jobs) |*j| j.* = spawn(u64, Unit, trims, .{}, .{}, false, false).job;
            var total: u64 = 0;
            for (jobs) |j| {
                total += j.join();
                j.free();
            }
            dense.guard = 0;
            done = total;
        }
        var done: u64 = 0;
    };
    runForTest(Run.first, Run.workers_n);
    try std.testing.expectEqual(@as(u64, Run.workers_n), Run.done);
}

test "a dense stack a sanitizing build retires faults at a late write" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var retired: Stack = undefined;
        fn first(_: *anyopaque) callconv(.c) void {
            dense.guard = 64 << 10;
            retired = takeDense(me().?).?;
            const top: *volatile usize = @ptrFromInt(retired.base + retired.guard + retired.len - @sizeOf(usize));
            top.* = 7;
            retireDense(retired);
            dense.guard = 0;
        }
        fn touch() void {
            const top: *volatile usize = @ptrFromInt(retired.base + retired.guard + retired.len - @sizeOf(usize));
            top.* = 8;
        }
    };
    runForTest(Run.first, 1);
    var err: [1024]u8 = undefined;
    const r = try inChild(Run.touch, &err);
    try std.testing.expect(r.signaled);
}

test "a dense stack's guard faults" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var guarded: Stack = undefined;
        fn first(_: *anyopaque) callconv(.c) void {
            dense.guard = 64 << 10;
            guarded = takeDense(me().?).?;
            dense.guard = 0;
        }
        fn touch() void {
            const below: *volatile usize = @ptrFromInt(guarded.base + guarded.guard - @sizeOf(usize));
            below.* = 7;
        }
    };
    runForTest(Run.first, 1);
    var err: [1024]u8 = undefined;
    const r = try inChild(Run.touch, &err);
    try std.testing.expect(r.signaled);
}

/// Run `run` in a child process: whether a signal ended it, its exit
/// status, and what it wrote to stderr (into `err`).
fn inChild(comptime run: fn () void, err: []u8) !struct { signaled: bool, code: u8, stderr: []u8 } {
    const sys = std.posix.system;
    var fds: [2]std.posix.fd_t = undefined;
    if (std.posix.errno(sys.pipe(&fds)) != .SUCCESS) return error.PipeFailed;
    const pid = sys.fork();
    if (pid == 0) {
        _ = sys.dup2(fds[1], std.posix.STDERR_FILENO);
        run();
        sys.exit(0);
    }
    _ = sys.close(fds[1]);
    var n: usize = 0;
    while (n < err.len) {
        const got = std.posix.read(fds[0], err[n..]) catch break;
        if (got == 0) break;
        n += got;
    }
    _ = sys.close(fds[0]);
    var status: if (builtin.target.os.tag == .linux) i32 else c_int = 0;
    if (builtin.target.os.tag == .linux) {
        if (std.posix.errno(sys.waitpid(@intCast(pid), &status, 0)) != .SUCCESS) return error.WaitFailed;
    } else if (sys.waitpid(pid, &status, 0) != pid) return error.WaitFailed;
    const st: u32 = @bitCast(@as(i32, @intCast(status)));
    return .{ .signaled = st & 0x7f != 0, .code = @truncate(st >> 8), .stderr = err[0..n] };
}

test "free stacks sort into address order, whatever their number and order" {
    var nodes: [100]FreeStack = undefined;
    var prng = std.Random.DefaultPrng.init(7);
    for ([_]u32{ 0, 1, 2, 3, 5, 8, 31, 64, 65, 100 }) |n| {
        var list: ?*FreeStack = null;
        for (nodes[0..n], 0..) |*x, i| {
            x.* = .{ .stack = .{ .base = @as(usize, prng.random().int(u32)) * 128 + i, .guard = 0, .len = 0 }, .next = list };
            list = x;
        }
        var count: u32 = 0;
        var last: usize = 0;
        var it = sortStacks(list, n);
        while (it) |x| : (it = x.next) {
            try std.testing.expect(x.stack.base >= last);
            last = x.stack.base;
            count += 1;
        }
        try std.testing.expectEqual(n, count);
    }
}

test "onWorkerStack runs its function on the worker's stack, and in place when nested or off a worker" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var fiber_at: usize = 0;
        var worker_at: usize = 0;
        var nested_at: usize = 0;
        var off_at: usize = 0;
        fn nested() usize {
            return @frameAddress();
        }
        fn onWorker(k: usize) usize {
            nested_at = onWorkerStack(nested, .{});
            return @frameAddress() + k;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            fiber_at = @frameAddress();
            worker_at = onWorkerStack(onWorker, .{@as(usize, 0)});
        }
        fn here() usize {
            return @frameAddress();
        }
    };
    runForTest(Run.first, 1);
    const apart = struct {
        fn by(a: usize, b: usize) usize {
            return if (a > b) a - b else b - a;
        }
    };
    // A fiber's stack and its worker's are separate mappings, far apart.
    try std.testing.expect(apart.by(Run.worker_at, Run.fiber_at) > 1 << 20);
    try std.testing.expect(apart.by(Run.nested_at, Run.worker_at) < 64 << 10);
    Run.off_at = onWorkerStack(Run.here, .{});
    try std.testing.expect(apart.by(Run.off_at, @frameAddress()) < 64 << 10);
}

test "a task that would wait while on its worker's stack panics, in a safe build" {
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        fn waits() void {
            yield();
        }
        fn first(_: *anyopaque) callconv(.c) void {
            onWorkerStack(waits, .{});
        }
        fn child() void {
            runForTest(first, 1);
        }
    };
    var buf: [4096]u8 = undefined;
    const got = try inChild(Run.child, &buf);
    try std.testing.expect(got.signaled);
    try std.testing.expect(std.mem.indexOf(u8, got.stderr, "while on its worker's stack") != null);
}

test "a panic on the worker's stack goes on on the fiber's own" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var fiber_at: usize = 0;
        fn goesOn() void {
            const here = @frameAddress();
            const d = if (here > fiber_at) here - fiber_at else fiber_at - here;
            // Back on the fiber's stack, just below where it left; and no
            // longer counted as on the worker's.
            std.posix.system.exit(if (d < 64 << 10 and !me().?.on_own_stack) 42 else 43);
        }
        fn panics() void {
            panicOnFiberStack(goesOn, .{});
        }
        fn first(_: *anyopaque) callconv(.c) void {
            fiber_at = @frameAddress();
            onWorkerStack(panics, .{});
        }
        fn child() void {
            runForTest(first, 1);
        }
    };
    var buf: [256]u8 = undefined;
    const got = try inChild(Run.child, &buf);
    try std.testing.expect(!got.signaled);
    try std.testing.expectEqual(@as(u8, 42), got.code);
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
                for (&jobs, 0..) |*j, i| j.* = spawn(u64, Unit, leaf, .{@as(u64, i)}, .{}, false, false).job;
                for (jobs) |j| {
                    sum += j.join();
                    j.free();
                }
            }
        }
    };
    workers_override.* = 4;
    defer workers_override.* = null;
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
                const j = spawn(u64, Unit, leaf, .{@as(u64, i)}, .{}, false, false).job;
                sum += j.join();
                j.free();
            }
        }
    };
    workers_override.* = 4;
    defer workers_override.* = null;
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
                const j = spawn(u64, Unit, leaf, .{i * 4 + k}, .{}, false, false).job;
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
            for (&jobs, 0..) |*j, i| j.* = spawn(u64, Unit, local, .{ home, @as(u64, i) }, .{}, true, false).job;
            for (jobs) |j| {
                sum += j.join();
                j.free();
                if (me().? != home) _ = moved.fetchAdd(1, .seq_cst);
            }
        }
    };
    workers_override.* = 4;
    defer workers_override.* = null;
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
            const j = spawn(u8, Unit, writer, .{fds[1]}, .{}, false, false).job;
            while (true) {
                const seen = edges(r, Registration.readable);
                var b: [1]u8 = undefined;
                const n: isize = @bitCast(std.posix.system.read(fds[0], &b, 1));
                if (n == 1) {
                    got = b[0];
                    break;
                }
                waited = true;
                if (waitReady(r, Registration.readable, seen, null, false) != .ready) return;
            }
            _ = j.join();
            j.free();
            timed_out = waitReady(r, Registration.readable, edges(r, Registration.readable), nowNs() + std.time.ns_per_ms, false) == .timeout;
            deregister(r);
            _ = std.posix.system.close(fds[0]);
            _ = std.posix.system.close(fds[1]);
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
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
            return waitReady(r, Registration.readable, edges(r, Registration.readable), nowNs() + 2 * std.time.ns_per_s, true);
        }

        fn first(_: *anyopaque) callconv(.c) void {
            const fds = testPipe();
            const r = register(fds[0]).?;
            test_pause.store(&pause, .seq_cst);
            const j = spawn(Readiness, Unit, reader, .{r}, .{}, false, false).job;
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
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expectEqual(Readiness.canceled, Run.got);
    // Ended by the cancel, not by the deadline, after which the wait
    // looks at the flag again.
    try std.testing.expect(Run.took < std.time.ns_per_s);
}

test "an edge after a wait's call would block reaches it, though another waiter woken by the edge runs first" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var got: Readiness = .timeout;
        var pause: Pause = .{};
        const Unit = struct {};

        /// Read the pipe, find it empty, and wait: held between its last
        /// look and its wait (`pausePoint`) while a byte comes and the
        /// other waiter is woken for it. No read follows that could make
        /// the kernel report the byte again.
        fn reader(_: *Unit, r: *Registration) Readiness {
            const seen = edges(r, Registration.readable);
            var b: [1]u8 = undefined;
            std.debug.assert(@as(isize, @bitCast(std.posix.system.read(r.fd, &b, 1))) < 0);
            return waitReady(r, Registration.readable, seen, nowNs() + 200 * std.time.ns_per_ms, false);
        }

        fn first(_: *anyopaque) callconv(.c) void {
            const fds = testPipe();
            const r = register(fds[0]).?;
            test_pause.store(&pause, .seq_cst);
            const j = spawn(Readiness, Unit, reader, .{r}, .{}, false, false).job;
            while (!pause.reached.load(.seq_cst)) yield();
            // This fiber waits too, and is woken by the byte, before the
            // reader looks again, whose read came before it.
            const seen = edges(r, Registration.readable);
            _ = std.posix.system.write(fds[1], "x", 1);
            _ = waitReady(r, Registration.readable, seen, null, false);
            pause.go.store(true, .seq_cst);
            got = j.join();
            j.free();
            deregister(r);
            _ = std.posix.system.close(fds[0]);
            _ = std.posix.system.close(fds[1]);
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expectEqual(Readiness.ready, Run.got);
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
            return waitReady(r, Registration.readable, edges(r, Registration.readable), nowNs() + 2 * std.time.ns_per_s, true);
        }

        /// The waiter: it makes the reader and waits for it at once, by
        /// handoff, unless its own cancel comes first, when it passes the
        /// cancel on.
        fn waiter(_: *Unit, r: *Registration) u8 {
            const f = current().?;
            f.state.control = &outer;
            outer.fiber = f;
            const j = spawn(Readiness, Unit, reader, .{r}, .{}, false, false).job;
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
            const j = spawn(u8, Unit, waiter, .{r}, .{}, false, false).job;
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
    workers_override.* = 2;
    defer workers_override.* = null;
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
            const j = spawn(u8, Unit, napper, .{}, .{}, false, false).job;
            // The napper runs here, sets its timer on this worker, and
            // this fiber computes without a yield check.
            yield();
            in_time = testSpinUntil(&done, false);
            _ = j.join();
            j.free();
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
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
            if (waitReady(r, Registration.readable, edges(r, Registration.readable), null, false) == .ready) read.store(true, .seq_cst);
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            const a = spawn(u8, Unit, napper, .{}, .{}, false, false).job;
            yield();
            napped_in_time = testSpinUntil(&napped, true);
            _ = a.join();
            a.free();
            const fds = testPipe();
            const r = register(fds[0]).?;
            const b = spawn(u8, Unit, reader, .{r}, .{}, false, false).job;
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
    workers_override.* = 1;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(Run.napped_in_time);
    try std.testing.expect(Run.read_in_time);
}

test "a task made while its maker computes runs beside it, from the maker's next yield check" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var ran = std.atomic.Value(bool).init(false);
        var turns = std.atomic.Value(u64).init(0);
        var in_time = false;
        const Unit = struct {};
        /// Done only once its maker has turned meanwhile, which it can
        /// only while the two run at once: this one makes no yield check.
        fn beside(_: *Unit) u8 {
            const from = turns.load(.seq_cst);
            const until = nowNs() + 2 * std.time.ns_per_s;
            while (turns.load(.seq_cst) < from + 1000 and nowNs() < until) std.atomic.spinLoopHint();
            ran.store(turns.load(.seq_cst) >= from + 1000, .seq_cst);
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            _ = workersRunning();
            // Let the other worker go to sleep.
            testNap(20 * std.time.ns_per_ms);
            const j = spawn(u8, Unit, beside, .{}, .{}, false, false).job;
            // The task is in this worker's run-next slot, and this one
            // computes, with a yield check each turn.
            const until = nowNs() + 2 * std.time.ns_per_s;
            while (!j.header.done.over() and nowNs() < until) {
                _ = turns.fetchAdd(1, .seq_cst);
                tick();
            }
            _ = j.join();
            in_time = ran.load(.seq_cst);
            j.free();
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(Run.in_time);
}

test "a task's maker that computes keeps its worker while an idle worker runs what it made" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var child_on = std.atomic.Value(?*Worker).init(null);
        var moved = false;
        var ok = false;
        const Unit = struct {};
        fn child(_: *Unit) u8 {
            child_on.store(me(), .seq_cst);
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            _ = workersRunning();
            // Let the other worker go to sleep.
            testNap(20 * std.time.ns_per_ms);
            const home = me();
            const j = spawn(u8, Unit, child, .{}, .{}, false, false).job;
            // The child waits in this worker's run-next slot while this
            // one computes, checking each turn: the check leaves it to the
            // idle worker, which it wakes, and never yields.
            const until = nowNs() + 2 * std.time.ns_per_s;
            while (child_on.load(.seq_cst) == null and nowNs() < until) {
                tick();
                if (me() != home) moved = true;
            }
            ok = child_on.load(.seq_cst) != null and child_on.load(.seq_cst) != home;
            _ = j.join();
            j.free();
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(Run.ok);
    try std.testing.expect(!Run.moved);
}

test "a task's maker that computes yields to what it made when every other worker is busy" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var holding = std.atomic.Value(bool).init(false);
        var release = std.atomic.Value(bool).init(false);
        var child_on = std.atomic.Value(?*Worker).init(null);
        var ok = false;
        const Unit = struct {};
        /// Holds the other worker, with no yield check.
        fn hold(_: *Unit) u8 {
            holding.store(true, .seq_cst);
            const until = nowNs() + 2 * std.time.ns_per_s;
            while (!release.load(.seq_cst) and nowNs() < until) std.atomic.spinLoopHint();
            return 0;
        }
        fn child(_: *Unit) u8 {
            child_on.store(me(), .seq_cst);
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            _ = workersRunning();
            const h = spawn(u8, Unit, hold, .{}, .{}, false, false).job;
            // Hand the holder to the other worker: yield until it runs there.
            const until = nowNs() + 2 * std.time.ns_per_s;
            while (!holding.load(.seq_cst) and nowNs() < until) yield();
            const home = me();
            const j = spawn(u8, Unit, child, .{}, .{}, false, false).job;
            while (child_on.load(.seq_cst) == null and nowNs() < until) tick();
            ok = child_on.load(.seq_cst) == home;
            release.store(true, .seq_cst);
            _ = j.join();
            j.free();
            _ = h.join();
            h.free();
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(Run.ok);
}

test "a task's maker that computes yields to a local task it made, though a worker is idle" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var ran = std.atomic.Value(bool).init(false);
        var ok = false;
        const Unit = struct {};
        fn child(_: *Unit) u8 {
            ran.store(true, .seq_cst);
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            _ = workersRunning();
            testNap(20 * std.time.ns_per_ms);
            const j = spawn(u8, Unit, child, .{}, .{}, true, false).job;
            const until = nowNs() + 2 * std.time.ns_per_s;
            while (!ran.load(.seq_cst) and nowNs() < until) tick();
            ok = ran.load(.seq_cst);
            _ = j.join();
            j.free();
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(Run.ok);
}

test "two tasks that answer each other over a socket stay on one worker" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        const trips = 2000;
        /// The worker each side last wrote from, and how many times a
        /// side read on a worker other than the one its answer came from.
        var on = [2]?*Worker{ null, null };
        var crossed = std.atomic.Value(u32).init(0);
        const Unit = struct {};
        fn send(r: *Registration, side: usize) void {
            on[side] = me();
            _ = std.posix.system.write(r.fd, "x", 1);
        }
        fn receive(r: *Registration, side: usize) void {
            while (true) {
                const seen = edges(r, Registration.readable);
                var b: [1]u8 = undefined;
                const n: isize = @bitCast(std.posix.system.read(r.fd, &b, 1));
                if (n == 1) break;
                if (waitReady(r, Registration.readable, seen, null, false) != .ready) return;
            }
            if (me() != on[1 - side]) _ = crossed.fetchAdd(1, .monotonic);
        }
        fn server(_: *Unit, r: *Registration) u8 {
            for (0..trips) |_| {
                receive(r, 1);
                send(r, 1);
            }
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            _ = workersRunning();
            const fds = testTcpPair();
            const rs = [2]*Registration{ register(fds[0]).?, register(fds[1]).? };
            const j = spawn(u8, Unit, server, .{rs[1]}, .{}, false, false).job;
            for (0..trips) |_| {
                send(rs[0], 0);
                receive(rs[0], 0);
            }
            _ = j.join();
            j.free();
            for (rs, fds) |r, fd| {
                deregister(r);
                _ = std.posix.system.close(fd);
            }
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    // Each side is woken by the poller of the worker it then runs on, which
    // wakes no other worker to take it; the worker watching the busy one's
    // poller moves the pair now and then.
    try std.testing.expect(Run.crossed.load(.monotonic) < Run.trips / 4);
}

/// A connected pair of loopback TCP sockets that do not block.
fn testTcpPair() [2]i32 {
    const posix = std.posix;
    const sys = posix.system;
    const l: i32 = @intCast(sys.socket(posix.AF.INET, posix.SOCK.STREAM, 0));
    var sa: sys.sockaddr.in = .{ .port = 0, .addr = @bitCast([4]u8{ 127, 0, 0, 1 }) };
    var len: posix.socklen_t = @sizeOf(sys.sockaddr.in);
    _ = sys.bind(l, @ptrCast(&sa), len);
    _ = sys.listen(l, 1);
    _ = sys.getsockname(l, @ptrCast(&sa), &len);
    const c: i32 = @intCast(sys.socket(posix.AF.INET, posix.SOCK.STREAM, 0));
    _ = sys.connect(c, @ptrCast(&sa), len);
    const a: i32 = @intCast(sys.accept(l, null, null));
    _ = sys.close(l);
    for ([2]i32{ a, c }) |fd| {
        if (builtin.os.tag == .linux) {
            _ = std.os.linux.fcntl(fd, std.os.linux.F.SETFL, @as(u32, @bitCast(std.os.linux.O{ .NONBLOCK = true })));
        } else {
            _ = std.c.fcntl(fd, std.c.F.SETFL, @as(c_int, @bitCast(std.c.O{ .NONBLOCK = true })));
        }
    }
    return .{ a, c };
}

test "a deterministic run waits for bytes on their way on a socket before its clock jumps past the wait's deadline" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var timeouts: u32 = 0;
        const Unit = struct {};
        fn writer(_: *Unit, fd: i32) u8 {
            _ = std.posix.system.write(fd, "x", 1);
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            for (0..200) |_| {
                const fds = testTcpPair();
                const r = register(fds[0]).?;
                const j = spawn(u8, Unit, writer, .{fds[1]}, .{}, false, false).job;
                if (waitReady(r, Registration.readable, edges(r, Registration.readable), nowNs() + std.time.ns_per_ms, false) != .ready) timeouts += 1;
                _ = j.join();
                j.free();
                deregister(r);
                _ = std.posix.system.close(fds[0]);
                _ = std.posix.system.close(fds[1]);
            }
        }
    };
    seed(1);
    defer deterministic.* = false;
    workers_override.* = 1;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expectEqual(@as(u32, 0), Run.timeouts);
}

test "a look at a poller leaves its kick for the worker that sleeps in it" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    var p: Poller = .{};
    p.open();
    defer p.close();
    // A waker kicks the worker about to sleep in `p`; another worker,
    // going to sleep itself, looks at `p` first.
    p.kick();
    _ = p.poll(0);
    // The worker's sleep ends at once, not at its timeout.
    const start = nowNs();
    _ = p.poll(2 * std.time.ns_per_s);
    try std.testing.expect(nowNs() - start < std.time.ns_per_s);
}

test "a run-next fiber that wakes no worker is handed on at its maker's next recursive check" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var ran = std.atomic.Value(bool).init(false);
        var in_time = false;
        const Unit = struct {};
        fn mark(_: *Unit) u8 {
            ran.store(true, .seq_cst);
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            _ = workersRunning();
            testNap(20 * std.time.ns_per_ms);
            const j = spawn(u8, Unit, mark, .{}, .{}, false, false).job;
            // Computing in recursion: each call reads `waiting`, as
            // `rt.tickCall` does.
            const until = nowNs() + 2 * std.time.ns_per_s;
            while (!ran.load(.seq_cst) and nowNs() < until) {
                if (waiting.load(.monotonic) != 0) tickCall();
            }
            in_time = ran.load(.seq_cst);
            _ = j.join();
            j.free();
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(Run.in_time);
}

test "a run-next fiber made as the other worker goes to sleep is handed on at its maker's next recursive check" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var ended = std.atomic.Value(bool).init(false);
        var ran = std.atomic.Value(bool).init(false);
        var misses: u32 = 0;
        const Unit = struct {};
        fn helper(_: *Unit) u8 {
            ended.store(true, .seq_cst);
            return 0;
        }
        fn mark(_: *Unit) u8 {
            ran.store(true, .seq_cst);
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            _ = workersRunning();
            testNap(20 * std.time.ns_per_ms);
            for (0..4000) |round| {
                ended.store(false, .seq_cst);
                ran.store(false, .seq_cst);
                // A task the other worker runs, which ends at once: that
                // worker then looks for work, finds none, and sleeps.
                const h = spawn(u8, Unit, helper, .{}, .{}, false, false).job;
                yield();
                while (!ended.load(.seq_cst)) std.atomic.spinLoopHint();
                // Made a little later each round, so some round makes it
                // as that worker goes to sleep.
                const until = nowNs() + @as(i96, @intCast(round % 80)) * 100;
                while (nowNs() < until) std.atomic.spinLoopHint();
                const j = spawn(u8, Unit, mark, .{}, .{}, false, false).job;
                // Computing in recursion: each call reads `waiting`, as
                // `rt.tickCall` does.
                const give_up = nowNs() + 50 * std.time.ns_per_ms;
                while (!ran.load(.seq_cst) and nowNs() < give_up) {
                    if (waiting.load(.monotonic) != 0) tickCall();
                }
                // One check more, in case this thread lost the CPU past
                // the deadline before it made one.
                if (waiting.load(.monotonic) != 0) tickCall();
                if (!ran.load(.seq_cst)) misses += 1;
                _ = j.join();
                j.free();
                _ = h.join();
                h.free();
                if (misses != 0) break;
            }
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expectEqual(@as(u32, 0), Run.misses);
}

test "a run-next fiber whose notice another worker's check took is handed on at the next recursive check" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var y_ready = std.atomic.Value(bool).init(false);
        var m_filled = std.atomic.Value(bool).init(false);
        var y_claimed = std.atomic.Value(bool).init(false);
        var ran = std.atomic.Value(bool).init(false);
        var in_time = false;
        const Unit = struct {};
        fn tiny(_: *Unit) u8 {
            return 0;
        }
        fn mark(_: *Unit) u8 {
            ran.store(true, .seq_cst);
            return 0;
        }
        /// Spin as recursion does, reading `waiting` each call, until
        /// `mark` has run or 50 ms pass.
        fn recurse() void {
            const until = nowNs() + 50 * std.time.ns_per_ms;
            while (!ran.load(.seq_cst) and nowNs() < until) {
                if (waiting.load(.monotonic) != 0) tickCall();
            }
            // One check more, in case this thread lost the CPU past the
            // deadline before it made one.
            if (waiting.load(.monotonic) != 0) tickCall();
        }
        /// On the other worker: make a task into its own slot, setting
        /// `waiting`; once the maker has filled its slot too, take the
        /// flag at a recursive check, which yields to its own task.
        fn other(_: *Unit) u8 {
            const g = spawn(u8, Unit, tiny, .{}, .{}, false, false).job;
            y_ready.store(true, .seq_cst);
            while (!m_filled.load(.seq_cst)) std.atomic.spinLoopHint();
            tickCall();
            y_claimed.store(true, .seq_cst);
            recurse();
            _ = g.join();
            g.free();
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            _ = workersRunning();
            testNap(20 * std.time.ns_per_ms);
            const y = spawn(u8, Unit, other, .{}, .{}, false, false).job;
            // Off to the other worker: this one takes `other` from its
            // slot, and the woken one this fiber from the ring.
            yield();
            while (!y_ready.load(.seq_cst)) std.atomic.spinLoopHint();
            // The flag is set already, so filling the slot leaves it.
            const j = spawn(u8, Unit, mark, .{}, .{}, false, false).job;
            m_filled.store(true, .seq_cst);
            while (!y_claimed.load(.seq_cst)) std.atomic.spinLoopHint();
            recurse();
            in_time = ran.load(.seq_cst);
            _ = j.join();
            j.free();
            _ = y.join();
            y.free();
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(Run.in_time);
}

test "an idle worker wakes for the descriptors of a busy one" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var read = std.atomic.Value(bool).init(false);
        var in_time = false;
        const Unit = struct {};
        fn reader(_: *Unit, r: *Registration) u8 {
            if (waitReady(r, Registration.readable, edges(r, Registration.readable), null, false) == .ready) read.store(true, .seq_cst);
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            // Pinned, so this worker stays busy with it, and holds the
            // descriptor, registered here.
            _ = pinHere();
            const fds = testPipe();
            const r = register(fds[0]).?;
            const j = spawn(u8, Unit, reader, .{r}, .{}, false, false).job;
            // The reader runs here and waits; the other worker goes to
            // sleep with nothing to do.
            yield();
            testNap(20 * std.time.ns_per_ms);
            // Busy a while, so the other worker, woken for this one's
            // timer, has gone back to sleep with nothing to wake it for.
            const until = nowNs() + 30 * std.time.ns_per_ms;
            while (nowNs() < until) std.atomic.spinLoopHint();
            _ = std.posix.system.write(fds[1], "x", 1);
            in_time = testSpinUntil(&read, false);
            _ = j.join();
            j.free();
            deregister(r);
            _ = std.posix.system.close(fds[0]);
            _ = std.posix.system.close(fds[1]);
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(Run.in_time);
}

fn testSleepReal(ms: u64) u64 {
    std.Io.sleep(rt.io(), .fromNanoseconds(@intCast(ms * std.time.ns_per_ms)), .awake) catch {};
    return ms;
}

test "the blocking pool runs calls at once, counting a thread busy as it hands it a call, and keeps to its most" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var together: i96 = 0;
        var one_thread: i96 = 0;
        const Unit = struct {};
        fn caller(_: *Unit, ms: u64) u64 {
            return blocking(testSleepReal, .{ms});
        }
        fn pair() i96 {
            const start = nowNs();
            const a = spawn(u64, Unit, caller, .{100}, .{}, false, false).job;
            const b = spawn(u64, Unit, caller, .{100}, .{}, false, false).job;
            _ = a.join();
            _ = b.join();
            a.free();
            b.free();
            return nowNs() - start;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            // At most one thread: the two calls take turns.
            one_thread = pair();
            // As many as `RIG_BLOCKING_THREADS` gives. One thread is idle:
            // the first call is handed it, and the second, finding none
            // idle, starts another.
            pool.lock.lock();
            pool.soft = 0;
            pool.max = 0;
            pool.lock.unlock();
            together = pair();
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    pool.soft = 1;
    pool.max = 1;
    defer pool.soft = 0;
    defer pool.max = 0;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(Run.together < 180 * std.time.ns_per_ms);
    try std.testing.expect(Run.one_thread >= 200 * std.time.ns_per_ms);
}

test "past its soft bound, the blocking pool grows once a queued call has waited" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var together: i96 = 0;
        const Unit = struct {};
        fn caller(_: *Unit, ms: u64) u64 {
            return blocking(testSleepReal, .{ms});
        }
        fn first(_: *anyopaque) callconv(.c) void {
            // One thread at once, two at most: the second call, finding
            // the first's thread busy, waits for the monitor, which
            // starts a thread for it after `grow_after`, so the calls
            // overlap, as a call that blocks for good would need.
            const start = nowNs();
            const a = spawn(u64, Unit, caller, .{200}, .{}, false, false).job;
            const b = spawn(u64, Unit, caller, .{200}, .{}, false, false).job;
            _ = a.join();
            _ = b.join();
            a.free();
            b.free();
            together = nowNs() - start;
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    pool.soft = 1;
    pool.max = 2;
    defer pool.soft = 0;
    defer pool.max = 0;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(Run.together < 350 * std.time.ns_per_ms);
}

test "a cancel or a deadline ends a wait on the blocking pool, and the call runs on" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var timed: PoolResult(u64) = .{ .done = 0 };
        var canceled: PoolResult(u64) = .{ .done = 0 };
        var done: PoolResult(u64) = .canceled;
        var took: i96 = 0;
        var ctl: TestControl = .{};
        var path_ok = std.atomic.Value(bool).init(false);
        const Unit = struct {};
        fn slowEcho(path: []const u8) u64 {
            _ = testSleepReal(300);
            if (std.mem.eql(u8, path, "a path")) path_ok.store(true, .seq_cst);
            return path.len;
        }
        fn late(_: *Unit) u8 {
            const f = current().?;
            f.state.control = &ctl;
            ctl.fiber = f;
            canceled = blockingStop(testSleepReal, .{300}, null);
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            const f = current().?;
            // A deadline: the wait ends at it, and the call, whose path
            // the waiter's frame no longer holds, runs on.
            var path_buf = "a path".*;
            const start = nowNs();
            f.state.deadline = start + 20 * std.time.ns_per_ms;
            timed = blockingStop(slowEcho, .{@as([]const u8, &path_buf)}, null);
            took = nowNs() - start;
            f.state.deadline = null;
            @memset(&path_buf, 'z');
            // A cancel.
            const j = spawn(u8, Unit, late, .{}, .{}, false, false).job;
            testNap(20 * std.time.ns_per_ms);
            ctl.cancel();
            _ = j.join();
            j.free();
            done = blockingStop(testSleepReal, .{1}, null);
            testNap(400 * std.time.ns_per_ms);
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(Run.timed == .timeout);
    try std.testing.expect(Run.took < 200 * std.time.ns_per_ms);
    try std.testing.expect(Run.canceled == .canceled);
    try std.testing.expect(Run.done == .done);
    try std.testing.expect(Run.path_ok.load(.seq_cst));
}

test "a pool thread idle long enough ends" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var after: u32 = 99;
        fn first(_: *anyopaque) callconv(.c) void {
            _ = workersRunning();
            _ = blocking(testSleepReal, .{1});
            testNap(300 * std.time.ns_per_ms);
            pool.lock.lock();
            after = pool.threads;
            pool.lock.unlock();
        }
    };
    retire_after.* = 50 * std.time.ns_per_ms;
    defer retire_after.* = 10 * std.time.ns_per_s;
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expectEqual(@as(u32, 0), Run.after);
}

test "RIG_SCHED_STATS counts: what each worker ran, stole, and slept" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var ran: u64 = 0;
        var pinned: u64 = 0;
        const Unit = struct {};
        fn leaf(_: *Unit) u8 {
            return 1;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            for (0..100) |_| {
                const j = spawn(u8, Unit, leaf, .{}, .{}, true, false).job;
                _ = j.join();
                j.free();
            }
            for (workersNow()) |*w| {
                ran += w.ran;
                pinned += w.ran_pinned;
            }
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    // `main`, then each local task, pinned, and `main` again after each.
    try std.testing.expect(Run.ran >= 101);
    try std.testing.expect(Run.pinned >= 100);
}

test "a pinned fiber that resumes away from its home is caught" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    const Run = struct {
        var lost = std.atomic.Value(u32).init(0);
        var elsewhere: Worker = .{};
        fn note(_: *Fiber) void {
            _ = lost.fetchAdd(1, .seq_cst);
        }
        /// Queue the fiber on the ring of the worker it left, as no wake
        /// of a pinned fiber does: a bug, for the check to catch.
        fn misqueue(f: *Fiber, _: ?*anyopaque) void {
            _ = me().?.ring.push(f);
        }
        fn first(_: *anyopaque) callconv(.c) void {
            const f = current().?;
            // Pinned to a worker no fiber runs on.
            f.home = &elsewhere;
            stop(.{ .run = misqueue });
            f.home = null;
        }
    };
    home_lost.* = Run.note;
    defer home_lost.* = homeLost;
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expectEqual(@as(u32, 1), Run.lost.load(.seq_cst));
}

test "a deterministic run waits for bytes on their way on a socket, though every core is busy" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Load = struct {
        var halt = std.atomic.Value(bool).init(false);
        fn spin() void {
            var x: u64 = 0;
            while (!halt.load(.monotonic)) x +%= 1;
            std.mem.doNotOptimizeAway(x);
        }
    };
    const Run = struct {
        var timeouts: u32 = 0;
        const Unit = struct {};
        fn writer(_: *Unit, fd: i32) u8 {
            // Enough that loopback delivers it in pieces, later.
            var buf: [256 * 1024]u8 = undefined;
            @memset(&buf, 'x');
            var off: usize = 0;
            while (off < buf.len) {
                const n: isize = @bitCast(std.posix.system.write(fd, buf[off..].ptr, buf.len - off));
                if (n <= 0) {
                    yield();
                    continue;
                }
                off += @intCast(n);
            }
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            for (0..40) |_| {
                const fds = testTcpPair();
                const r = register(fds[0]).?;
                const w = register(fds[1]).?;
                const j = spawn(u8, Unit, writer, .{fds[1]}, .{}, false, false).job;
                var got: usize = 0;
                var buf: [64 * 1024]u8 = undefined;
                while (got < 256 * 1024) {
                    const seen = edges(r, Registration.readable);
                    const n: isize = @bitCast(std.posix.system.read(fds[0], &buf, buf.len));
                    if (n > 0) {
                        got += @intCast(n);
                        continue;
                    }
                    if (waitReady(r, Registration.readable, seen, nowNs() + std.time.ns_per_ms, false) != .ready) {
                        timeouts += 1;
                        break;
                    }
                }
                _ = j.join();
                j.free();
                deregister(r);
                deregister(w);
                _ = std.posix.system.close(fds[0]);
                _ = std.posix.system.close(fds[1]);
            }
        }
    };
    const cores = std.Thread.getCpuCount() catch 4;
    var threads: [128]std.Thread = undefined;
    const n = @min(2 * cores, threads.len);
    for (threads[0..n]) |*t| t.* = try std.Thread.spawn(.{}, Load.spin, .{});
    defer {
        Load.halt.store(true, .monotonic);
        for (threads[0..n]) |t| t.join();
    }
    seed(1);
    defer deterministic.* = false;
    workers_override.* = 1;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expectEqual(@as(u32, 0), Run.timeouts);
}

test "a blocking call fills a buffer its caller lends, and a stoppable one takes no pointer but bytes it copies" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    // blockingStop rejects, as it compiles, what the call could write
    // through after its waiter left, and copies what it only reads.
    comptime {
        std.debug.assert(!leavable([]u8));
        std.debug.assert(!leavable(*u64));
        std.debug.assert(!leavable(?[]u8));
        std.debug.assert(!leavable(*const u64));
        std.debug.assert(!leavable([:0]const u8));
        std.debug.assert(!leavable([]const []const u8));
        std.debug.assert(!leavable(struct { s: []const u8 }));
        std.debug.assert(!leavable(struct { p: ?*u8, n: u8 }));
        std.debug.assert(!leavable([2]*u8));
        std.debug.assert(!leavable(union(enum) { a: u8, b: []u8 }));
        std.debug.assert(!leavable(std.ArrayList(u8)));
        std.debug.assert(leavable(u64));
        std.debug.assert(leavable(rt.String));
        std.debug.assert(leavable(rt.net.Fd));
        std.debug.assert(leavable(struct { fd: rt.net.Fd, buf: rt.String, n: ?u64 }));
        std.debug.assert(leavable([4]i64));
        std.debug.assert(isBytes([]const u8) and !isBytes([]u8));
    }
    const Run = struct {
        var filled = false;
        const Unit = struct {};
        fn fill(buf: []u8) usize {
            @memset(buf, 'z');
            return buf.len;
        }
        fn caller(_: *Unit) u8 {
            var buf: [64]u8 = @splat(0);
            const n = blocking(fill, .{@as([]u8, &buf)});
            filled = n == 64 and std.mem.allEqual(u8, &buf, 'z');
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            const j = spawn(u8, Unit, caller, .{}, .{}, false, false).job;
            _ = j.join();
            j.free();
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expect(Run.filled);
}

test "a fiber that allocates, moves to another worker, and allocates again uses its new thread's heap" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var moved = std.atomic.Value(u32).init(0);
        const Unit = struct {};
        var stale_used = std.atomic.Value(u32).init(0);
        fn noteLost() void {
            _ = lost.fetchAdd(1, .monotonic);
        }
        var lost = std.atomic.Value(u32).init(0);
        /// What a caller that kept its thread's heap across a switch
        /// would do: the owner check must see it. A fiber moves only
        /// when a worker steals it, which a busy machine may not do for
        /// thousands of switches, so each waits for its move, returning
        /// at the first.
        fn stale(_: *Unit) u8 {
            for (0..1_000_000) |_| {
                const before = me();
                const h = rt.fast_alloc.heapForTest();
                yield();
                if (me() == before) continue;
                rt.fast_alloc.checkOwnForTest(h);
                _ = stale_used.fetchAdd(1, .monotonic);
                return 0;
            }
            return 0;
        }
        /// Two allocations with a switch between, in one function, where
        /// a compiler could keep the first thread-local address for the
        /// second; a safe build's owner check catches a stale heap. Each
        /// runs 2000 rounds, and on until some fiber has moved, as a
        /// busy machine may steal none for a while.
        fn hop(_: *Unit) u8 {
            const a = rt.fast_alloc.allocator;
            var i: usize = 0;
            while (i < 2000 or (moved.load(.monotonic) == 0 and i < 1_000_000)) : (i += 1) {
                const before = me();
                const x = a.alloc(u8, 24) catch unreachable;
                yield();
                const y = a.alloc(u8, 40) catch unreachable;
                if (me() != before) _ = moved.fetchAdd(1, .monotonic);
                a.free(x);
                a.free(y);
            }
            return 0;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            var jobs: [16]*Job(u8) = undefined;
            for (&jobs) |*j| j.* = spawn(u8, Unit, hop, .{}, .{}, false, false).job;
            for (jobs) |j| {
                _ = j.join();
                j.free();
            }
            hop_lost = lost.load(.monotonic);
            // A heap kept across a switch, used on another thread.
            var stales: [8]*Job(u8) = undefined;
            for (&stales) |*j| j.* = spawn(u8, Unit, stale, .{}, .{}, false, false).job;
            for (stales) |j| {
                _ = j.join();
                j.free();
            }
        }
        var hop_lost: u32 = 0;
    };
    if (!std.debug.runtime_safety) return error.SkipZigTest;
    rt.fast_alloc.owner_lost.* = Run.noteLost;
    defer rt.fast_alloc.owner_lost.* = rt.fast_alloc.owner_lost_default;
    workers_override.* = 4;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    // The fibers did move, and allocating through the allocator never
    // used another thread's heap.
    try std.testing.expect(Run.moved.load(.monotonic) > 0);
    try std.testing.expectEqual(@as(u32, 0), Run.hop_lost);
    // A heap kept across a move is caught each time it is used.
    try std.testing.expect(Run.stale_used.load(.monotonic) > 0);
    try std.testing.expectEqual(Run.stale_used.load(.monotonic), Run.lost.load(.monotonic) - Run.hop_lost);
}

/// Fill the send buffer of `fds[1]`, of a pair (`testTcpPair`), and the
/// other end's receive buffer, registered as `r`, until a wait for room
/// times out: each buffer is set small, which keeps the system from
/// growing it, and the bytes still on their way make room as they land,
/// so it fills again until none come.
fn testFill(fds: [2]i32, r: *Registration) void {
    const posix = std.posix;
    const small: c_int = 16 * 1024;
    posix.setsockopt(fds[0], posix.SOL.SOCKET, posix.SO.RCVBUF, std.mem.asBytes(&small)) catch {};
    posix.setsockopt(fds[1], posix.SOL.SOCKET, posix.SO.SNDBUF, std.mem.asBytes(&small)) catch {};
    var buf: [16 * 1024]u8 = undefined;
    @memset(&buf, 'x');
    var quiet: u32 = 0;
    while (quiet < 2) {
        const seen = edges(r, Registration.writable);
        while (true) {
            const n: isize = @bitCast(posix.system.write(fds[1], &buf, buf.len));
            if (n <= 0) break;
        }
        quiet = if (waitReady(r, Registration.writable, seen, nowNs() + 20 * std.time.ns_per_ms, false) == .timeout) quiet + 1 else 0;
    }
}

test "a wait to read sleeps after its own side of the socket shuts down writing" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var got: Readiness = .ready;
        fn first(_: *anyopaque) callconv(.c) void {
            const fds = testTcpPair();
            const r = register(fds[1]).?;
            // macOS reports the end of writing on the write filter, which
            // is no readiness to read.
            _ = std.posix.system.shutdown(fds[1], std.posix.SHUT.WR);
            got = waitReady(r, Registration.readable, edges(r, Registration.readable), nowNs() + 50 * std.time.ns_per_ms, false);
            deregister(r);
            _ = std.posix.system.close(fds[0]);
            _ = std.posix.system.close(fds[1]);
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expectEqual(Readiness.timeout, Run.got);
}

test "a wait to write on a full buffer sleeps after the other end shuts down writing" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var got: Readiness = .ready;
        fn first(_: *anyopaque) callconv(.c) void {
            const fds = testTcpPair();
            const r = register(fds[1]).?;
            testFill(fds, r);
            // The other end's end of writing (EOF to read, RDHUP) makes no
            // room to write.
            const seen = edges(r, Registration.writable);
            _ = std.posix.system.shutdown(fds[0], std.posix.SHUT.WR);
            got = waitReady(r, Registration.writable, seen, nowNs() + 50 * std.time.ns_per_ms, false);
            deregister(r);
            _ = std.posix.system.close(fds[0]);
            _ = std.posix.system.close(fds[1]);
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expectEqual(Readiness.timeout, Run.got);
}

test "a wait to write on a full buffer ends when the other end closes, and the write fails" {
    if (builtin.target.os.tag != .macos and builtin.target.os.tag != .linux) return error.SkipZigTest;
    const Run = struct {
        var got: Readiness = .timeout;
        var took: i96 = 0;
        var failed = false;
        fn first(_: *anyopaque) callconv(.c) void {
            const fds = testTcpPair();
            const r = register(fds[1]).?;
            testFill(fds, r);
            // Closed with bytes unread, the other end resets the
            // connection.
            const seen = edges(r, Registration.writable);
            _ = std.posix.system.close(fds[0]);
            const start = nowNs();
            got = waitReady(r, Registration.writable, seen, nowNs() + 2 * std.time.ns_per_s, false);
            took = nowNs() - start;
            const n: isize = @bitCast(std.posix.system.write(fds[1], "x", 1));
            failed = n < 0;
            deregister(r);
            _ = std.posix.system.close(fds[1]);
        }
    };
    workers_override.* = 2;
    defer workers_override.* = null;
    const s = takeStack();
    var dummy: u8 = 0;
    runMain(&dummy, Run.first, s.top(), .{});
    try std.testing.expectEqual(Readiness.ready, Run.got);
    try std.testing.expect(Run.took < std.time.ns_per_s);
    try std.testing.expect(Run.failed);
}

test "every lock the runtime takes is counted for preemption" {
    // A lock taken in code the optimizer inlines into the program's own,
    // where a signal may stop the fiber holding it, must count itself
    // (`holdOff`, within the three lines before it), or say why it need
    // not ("uncounted"). A spin on a flag or a word (a compare-and-swap
    // from false or 0, a swap to true) and each `std.Io.Mutex` the
    // runtime takes, in every file the runtime is made of, are what the
    // scan finds.
    const files = [_][]const u8{ @embedFile("runtime.zig"), @embedFile("sched.zig"), @embedFile("tasks.zig"), @embedFile("alloc.zig"), @embedFile("net.zig"), @embedFile("ordered.zig"), @embedFile("unordered.zig"), @embedFile("table.zig"), @embedFile("split.zig") };
    const takes = [_][]const u8{ "cmpxchgWeak(false, true", "cmpxchgStrong(false, true", "cmpxchgWeak(0, 1", "cmpxchgStrong(0, 1", ".swap(true", "lockUncancelable(", ".lock(io", "_lock.tryLock()" };
    for (files) |text| {
        var before: [3][]const u8 = .{ "", "", "" };
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            defer before = .{ before[1], before[2], line };
            const code = std.mem.trimStart(u8, line, " ");
            if (std.mem.startsWith(u8, code, "//") or std.mem.indexOf(u8, line, "const takes") != null) continue;
            const takes_one = for (takes) |t| {
                if (std.mem.indexOf(u8, line, t) != null) break true;
            } else false;
            if (!takes_one) continue;
            const counted = for (before ++ [1][]const u8{line}) |l| {
                if (std.mem.indexOf(u8, l, "holdOff") != null or std.mem.indexOf(u8, l, "ncounted") != null) break true;
            } else false;
            if (!counted) {
                std.debug.print("a lock taken without the count: {s}\n", .{code});
                return error.Uncounted;
            }
        }
    }
}
