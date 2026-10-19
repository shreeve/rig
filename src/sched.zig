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
    const n = workerCount();
    workers = std.heap.smp_allocator.alloc(Worker, n) catch rt.oom();
    for (workers, 0..) |*w, i| w.* = .{ .rng = @intCast(i * 2654435761 % 4294967291 + 1) };
    stopping.store(false, .seq_cst);
    var m: Main = .{ .fiber = .{ .run = Main.start, .done = Main.end }, .arg = arg, .run = run };
    m.fiber.state.stack_guard = guard;
    m.fiber.sp = initialFrame(&m.fiber, top);
    me_slot = &workers[0];
    workers[0].ring.push(&m.fiber);
    for (workers[1..]) |*w| w.thread = std.Thread.spawn(.{}, workerMain, .{w}) catch rt.oom();
    loop(&workers[0]);
    for (workers[1..]) |*w| w.thread.?.join();
    for (workers) |*w| freeStacks(w);
    std.heap.smp_allocator.free(workers);
    workers = &.{};
    me_slot = null;
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
            sleep(w);
            continue;
        };
        runFiber(w, f);
    }
}

fn runFiber(w: *Worker, f: *Fiber) void {
    // A fiber gets its stack when it first runs, from this worker, which
    // keeps it for the next when the fiber ends.
    if (f.sp == 0) {
        const s = takeStack();
        f.stack = s;
        f.state.stack_guard = .{ .lo = s.base, .hi = s.base + s.guard };
        f.sp = initialFrame(f, s.top());
    }
    w.current = f;
    switchTo(&w.sp, f.sp);
    w.current = null;
    if (w.after) |a| {
        w.after = null;
        a.run(f, a.ctx);
    } else if (f.finished) {
        if (f.stack) |s| {
            f.stack = null;
            releaseStack(w, s);
        }
        if (f.done) |d| d(f);
    }
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
    if (2 * searching.load(.acquire) >= workers.len) return null;
    _ = searching.fetchAdd(1, .seq_cst);
    w.searching = true;
    defer if (w.searching) {
        w.searching = false;
        _ = searching.fetchSub(1, .seq_cst);
    };
    w.rng ^= w.rng << 13;
    w.rng ^= w.rng >> 17;
    w.rng ^= w.rng << 5;
    const start = w.rng % workers.len;
    for (0..workers.len) |k| {
        const v = &workers[(start + k) % workers.len];
        if (v == w) continue;
        if (w.ring.stealFrom(&v.ring)) |f| {
            w.searching = false;
            if (searching.fetchSub(1, .seq_cst) == 1) notify();
            return f;
        }
    }
    return global.pop();
}

/// Wake a sleeping worker when work was made and no worker is looking.
fn notify() void {
    if (searching.load(.seq_cst) != 0) return;
    if (sleepers.count.load(.seq_cst) == 0) return;
    if (sleepers.pop()) |w| wakeWorker(w);
}

fn wakeWorker(w: *Worker) void {
    w.woken.store(1, .seq_cst);
    rt.io().futexWake(u32, &w.woken.raw, 1);
}

/// Sleep until woken: listed as asleep first, then, after a last look
/// for work made meanwhile, on the futex.
fn sleep(w: *Worker) void {
    w.woken.store(0, .seq_cst);
    sleepers.push(w);
    if (stopping.load(.seq_cst) or hasWork()) {
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
        std.posix.munmap(@as([*]align(std.heap.page_size_min) u8, @ptrFromInt(n.stack.base))[0 .. n.stack.guard + n.stack.len + std.heap.pageSize()]);
        std.heap.smp_allocator.destroy(n);
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

/// What a task's waiter shares with the fiber that runs it: whether it
/// has ended, or is waited on, the fiber waiting for it, and how to free
/// the record. Its end is published by the worker the fiber left for
/// good, so the record is never freed while the fiber still runs.
pub const Header = struct {
    fiber: Fiber,
    status: std.atomic.Value(u8) = .init(running),
    waiter: ?*Fiber = null,
    destroy: *const fn (*Header) void,

    const running = 0;
    const waited = 1;
    const ended = 2;

    fn end(f: *Fiber) void {
        const h: *Header = @fieldParentPtr("fiber", f);
        if (h.status.swap(ended, .acq_rel) == waited) wake(h.waiter.?);
    }

    /// Record `f` as the waiter, unless the task has ended, when `f` goes
    /// on at once.
    fn wait(f: *Fiber, ctx: ?*anyopaque) void {
        const h: *Header = @ptrCast(@alignCast(ctx.?));
        h.waiter = f;
        if (h.status.cmpxchgStrong(running, waited, .acq_rel, .acquire) != null) wake(f);
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
            if (self.header.status.load(.acquire) != Header.ended) park(.{ .run = Header.wait, .ctx = &self.header });
            return self.result;
        }

        pub fn free(self: *Self) void {
            self.header.destroy(&self.header);
        }
    };
}

/// Start `f(args...)` as a fiber, ready to run, and give its record.
pub fn spawn(comptime T: type, comptime f: anytype, args: anytype) *Job(T) {
    const Args = @TypeOf(args);
    const Full = struct {
        job: Job(T),
        args: Args,

        fn start(fiber: *Fiber) void {
            const h: *Header = @fieldParentPtr("fiber", fiber);
            const j: *Job(T) = @fieldParentPtr("header", h);
            const full: *@This() = @fieldParentPtr("job", j);
            j.result = @call(.auto, f, full.args);
        }

        fn destroy(h: *Header) void {
            const j: *Job(T) = @fieldParentPtr("header", h);
            const full: *@This() = @fieldParentPtr("job", j);
            std.heap.smp_allocator.destroy(full);
        }
    };
    const full = std.heap.smp_allocator.create(Full) catch rt.oom();
    full.* = .{ .job = .{ .header = .{ .fiber = .{ .run = Full.start, .done = Header.end }, .destroy = Full.destroy } }, .args = args };
    wake(&full.job.header.fiber);
    return &full.job;
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

const FreeStack = struct { stack: Stack, next: ?*FreeStack };

/// A stack to run a fiber on: one a fiber that ended on this worker
/// left, or a new one.
fn takeStack() Stack {
    if (me()) |w| if (w.free) |n| {
        w.free = n.next;
        const s = n.stack;
        std.heap.smp_allocator.destroy(n);
        return s;
    };
    const guard = rt.task_guard;
    const len = rt.task_stack_size;
    const got = std.posix.mmap(null, guard + len + std.heap.pageSize(), .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch rt.oom();
    const base = @intFromPtr(got.ptr);
    if (std.posix.errno(std.posix.system.mprotect(@ptrFromInt(base + guard), len, .{ .READ = true, .WRITE = true })) != .SUCCESS) rt.oom();
    return .{ .base = base, .guard = guard, .len = len };
}

/// Keep a stack a fiber has finished with, for the next on `w`.
fn releaseStack(w: *Worker, s: Stack) void {
    const n = std.heap.smp_allocator.create(FreeStack) catch rt.oom();
    n.* = .{ .stack = s, .next = w.free };
    w.free = n;
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
/// `switchTo` (or, new, starts at `fiberStartNaked`).
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
            \\ mov %%rsp, (%%rdi)
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
            \\ and $-16, %%rsp
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
    f.run(f);
    f.finished = true;
    switchTo(&f.sp, me().?.sp);
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
        fn leaf(i: u64) u64 {
            if (i % 7 == 0) yield();
            return i;
        }
        fn first(_: *anyopaque) callconv(.c) void {
            var jobs: [2000]*Job(u64) = undefined;
            for (0..50) |_| {
                for (&jobs, 0..) |*j, i| j.* = spawn(u64, leaf, .{@as(u64, i)});
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
