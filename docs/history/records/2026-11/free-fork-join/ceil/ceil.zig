//! The ceiling: a work-stealing fork-join runtime of Rig's shape, written
//! by hand, on fork-order's psum and qsort (fork.rig, rayon::join's order).
//!
//! One worker a core, `main` worker 0. Each worker has a Chase-Lev deque
//! of forks: the owner pushes and pops the bottom, a thief takes the
//! oldest at the top. `join(f, a, b)` pushes b's record, which lives in
//! the caller's frame, runs `f(a)` inline, then pops b and runs it inline
//! if no thief took it, else helps (steals and runs other forks) until
//! the thief's done flag is up. Idle workers search (steal from victims
//! in a random order) for a while, then sleep on a futex; a push wakes a
//! sleeper when none searches, and a searcher that finds work and was the
//! last searcher wakes the next (a chain, as Rig's and Go's schedulers).
//!
//! Workers start before the input is built, and each touches its
//! allocators first, so a timed pass measures the fork-join, not the
//! start-up (#1156, #1158).
//!
//! The arms put Rig's per-fork costs back one at a time (`Cfg`, set by
//! the root file that imports this one):
//! - `heap`: the fork's record taken from a per-worker allocator of
//!   256-byte blocks and freed after the join, instead of the frame.
//! - `stack`: every fork that runs (popped by its owner or stolen) runs
//!   on a stack of its own, taken from a per-worker pool (fresh, untouched
//!   pages the first time), with a switch to it and a switch back: Rig's
//!   own switch (`switchNaked`, sched.zig).
//! - `sc`: the atomics of Rig's spawn and handoff: a seq_cst swap of the
//!   worker's run-next slot at the fork, and at the join a seq_cst swap
//!   (the waiter's word), a seq_cst compare-and-swap (the slot take),
//!   three seq_cst stores (`Done`) and one after (the status).
//! - `monitor`: Rig's preemption monitor's loop: a thread that looks at
//!   every worker every 50 us while any deque holds work (1 ms while any
//!   runs, doubling to 10 ms while all are idle), and sends SIGURG (a
//!   handler that does nothing) to a worker that ran no new fork between
//!   two looks while its deque held work at both, backing off as Rig's
//!   does (four in a row, then doubling waits up to 1 ms). Rig's handler
//!   then stops the fiber; this one returns, so the worker stays signaled
//!   at the backed-off rate where Rig's would have moved on. Workers count the forks
//!   they run, as Rig's count the fibers.
//! - `seq`: no forks at all: `join` calls both halves in turn.
const std = @import("std");
const builtin = @import("builtin");
const root = @import("root");
const rigsort = @import("rigsort.zig");

pub const Cfg = struct {
    heap: bool = false,
    stack: bool = false,
    sc: bool = false,
    monitor: bool = false,
    seq: bool = false,
    /// Worker 0 a thread `main` starts, not `main` itself (a probe: as
    /// Rayon's pool runs a join from `main`, and as macOS places threads).
    offmain: bool = false,
    /// Timed passes of each a process: 1 as the board's programs, 3 for
    /// the cold pass then two warm ones.
    passes: u32 = 1,
};
const cfg: Cfg = root.cfg;

const GRAIN = 8192;
const max_workers = 64;
const gpa = std.heap.c_allocator;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn nowNs() i96 {
    return std.Io.Clock.awake.now(io()).toNanoseconds();
}

fn oom() noreturn {
    @panic("out of memory");
}

// -----------------------------------------------------------------------------
// Jobs and the deque
// -----------------------------------------------------------------------------

const Job = struct {
    exec: *const fn (*Job) void,
    done: std.atomic.Value(u32) = .init(0),
};

const deque_cap = 1024;

const Deque = struct {
    top: std.atomic.Value(isize) align(128) = .init(0),
    bottom: std.atomic.Value(isize) align(128) = .init(0),
    buf: [deque_cap]?*Job align(128) = @splat(null),

    fn push(d: *Deque, j: *Job) void {
        const b = d.bottom.load(.monotonic);
        const t = d.top.load(.acquire);
        if (b - t >= deque_cap) @panic("deque full");
        @atomicStore(?*Job, &d.buf[@intCast(b & (deque_cap - 1))], j, .monotonic);
        d.bottom.store(b + 1, .release);
    }

    /// The owner takes the newest; null when a thief took it.
    fn pop(d: *Deque) ?*Job {
        const b = d.bottom.load(.monotonic) - 1;
        d.bottom.store(b, .seq_cst);
        const t = d.top.load(.seq_cst);
        if (t > b) {
            d.bottom.store(b + 1, .monotonic);
            return null;
        }
        const j = @atomicLoad(?*Job, &d.buf[@intCast(b & (deque_cap - 1))], .monotonic);
        if (t == b) {
            const won = d.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) == null;
            d.bottom.store(b + 1, .monotonic);
            return if (won) j else null;
        }
        return j;
    }

    /// A thief takes the oldest.
    fn steal(d: *Deque) ?*Job {
        while (true) {
            const t = d.top.load(.seq_cst);
            const b = d.bottom.load(.seq_cst);
            if (t >= b) return null;
            const j = @atomicLoad(?*Job, &d.buf[@intCast(t & (deque_cap - 1))], .monotonic);
            if (d.top.cmpxchgStrong(t, t + 1, .seq_cst, .monotonic) == null) return j;
        }
    }

    fn holds(d: *Deque) bool {
        return d.bottom.load(.monotonic) > d.top.load(.monotonic);
    }
};

// -----------------------------------------------------------------------------
// Workers
// -----------------------------------------------------------------------------

/// The `heap` arm's allocator: 256-byte blocks from 4 MiB segments mapped
/// as needed, a free list per worker (the joiner frees on the worker that
/// allocated, as no continuation moves).
const Heap = struct {
    const block = 256;
    const segment = 4 << 20;
    const Free = struct { next: ?*Free };
    free: ?*Free = null,
    next: usize = 0,
    end: usize = 0,

    fn alloc(h: *Heap) *align(64) anyopaque {
        if (h.free) |f| {
            h.free = f.next;
            return @ptrCast(@alignCast(f));
        }
        if (h.next == h.end) {
            const m = std.posix.mmap(null, segment, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch oom();
            h.next = @intFromPtr(m.ptr);
            h.end = h.next + segment;
        }
        const p = h.next;
        h.next += block;
        return @ptrFromInt(p);
    }

    fn release(h: *Heap, p: *anyopaque) void {
        const f: *Free = @ptrCast(@alignCast(p));
        f.next = h.free;
        h.free = f;
    }
};

/// The `stack` arm's stacks: a region of `count` stacks mapped (never
/// touched) as the worker starts, handed out last-freed first.
const Stacks = struct {
    const size = 512 << 10;
    const count = 256;
    base: usize = 0,
    free: [count]u16 = undefined,
    n: usize = 0,

    fn init(s: *Stacks) void {
        const m = std.posix.mmap(null, size * count, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true }, -1, 0) catch oom();
        s.base = @intFromPtr(m.ptr);
        for (0..count) |i| s.free[i] = @intCast(count - 1 - i);
        s.n = count;
    }

    fn take(s: *Stacks) u16 {
        if (s.n == 0) @panic("out of stacks");
        s.n -= 1;
        return s.free[s.n];
    }

    fn give(s: *Stacks, i: u16) void {
        s.free[s.n] = i;
        s.n += 1;
    }

    fn top(s: *Stacks, i: u16) usize {
        return s.base + (@as(usize, i) + 1) * size;
    }
};

const Worker = struct {
    deque: Deque = .{},
    runs: std.atomic.Value(u64) align(128) = .init(0),
    slot: std.atomic.Value(usize) align(128) = .init(0),
    id: usize = 0,
    rng: u64 = 0,
    tid: usize = 0,
    heap: Heap = .{},
    stacks: Stacks = .{},
};

var workers: []Worker = &.{};
var nworkers: usize = 1;
threadlocal var me: *Worker = undefined;

var searching: std.atomic.Value(u32) align(128) = .init(0);
var sleepers: std.atomic.Value(u32) align(128) = .init(0);
var waking: std.atomic.Value(u32) align(128) = .init(0);
var epoch: std.atomic.Value(u32) align(128) = .init(0);
var started: std.atomic.Value(u32) align(128) = .init(0);
var spin_ns: i96 = 100 * std.time.ns_per_us;

/// Work was made: wake a sleeper when none searches, one wake in flight.
inline fn notify() void {
    if (sleepers.load(.seq_cst) == 0 or searching.load(.monotonic) != 0) return;
    notifySlow();
}

noinline fn notifySlow() void {
    if (waking.cmpxchgStrong(0, 1, .seq_cst, .monotonic) != null) return;
    _ = epoch.fetchAdd(1, .seq_cst);
    io().futexWake(u32, &epoch.raw, 1);
}

fn nextRand(w: *Worker) u64 {
    var x = w.rng;
    x ^= x << 13;
    x ^= x >> 7;
    x ^= x << 17;
    w.rng = x;
    return x;
}

fn stealAny(w: *Worker) ?*Job {
    const n = nworkers;
    if (n == 1) return null;
    const start: usize = @intCast(nextRand(w) % n);
    for (0..n) |k| {
        const v = (start + k) % n;
        if (v == w.id) continue;
        if (workers[v].deque.steal()) |j| return j;
    }
    return null;
}

fn anyHolds() bool {
    for (workers[0..nworkers]) |*v| if (v.deque.holds()) return true;
    return false;
}

fn runJob(w: *Worker, j: *Job) void {
    if (cfg.monitor) w.runs.store(w.runs.load(.monotonic) +% 1, .monotonic);
    if (cfg.stack) runOnStack(w, j) else j.exec(j);
}

fn idleLoop(w: *Worker) noreturn {
    _ = searching.fetchAdd(1, .seq_cst);
    while (true) {
        const since = nowNs();
        var rounds: u32 = 0;
        while (true) {
            if (stealAny(w)) |j| {
                if (searching.fetchSub(1, .seq_cst) == 1) notify();
                runJob(w, j);
                _ = searching.fetchAdd(1, .seq_cst);
                rounds = 0;
                continue;
            }
            rounds += 1;
            for (0..32) |_| std.atomic.spinLoopHint();
            if (rounds % 64 == 0 and nowNs() - since > spin_ns) break;
        }
        // Sleep: announce, look once more, wait.
        _ = searching.fetchSub(1, .seq_cst);
        _ = sleepers.fetchAdd(1, .seq_cst);
        const e = epoch.load(.seq_cst);
        if (!anyHolds()) {
            io().futexWaitTimeout(u32, &epoch.raw, e, .{ .duration = .{ .raw = .fromMilliseconds(10), .clock = .awake } }) catch {};
        }
        _ = sleepers.fetchSub(1, .seq_cst);
        _ = searching.fetchAdd(1, .seq_cst);
        waking.store(0, .seq_cst);
    }
}

fn touchAllocators(w: *Worker) void {
    if (cfg.heap) w.heap.release(w.heap.alloc());
    if (cfg.stack) w.stacks.init();
    const p = gpa.alloc(u8, 64) catch oom();
    @as(*volatile u8, &p[0]).* = 1;
    gpa.free(p);
}

fn workerMain(w: *Worker) void {
    me = w;
    w.tid = threadId();
    touchAllocators(w);
    _ = started.fetchAdd(1, .seq_cst);
    idleLoop(w);
}

fn threadId() usize {
    return @intFromPtr(std.c.pthread_self());
}

// -----------------------------------------------------------------------------
// join
// -----------------------------------------------------------------------------

fn Rec(comptime Arg: type, comptime R: type, comptime f: fn (Arg) R) type {
    return struct {
        job: Job,
        arg: Arg,
        res: R = undefined,
        words: [4]std.atomic.Value(usize) = @splat(.init(0)),

        fn exec(j: *Job) void {
            const self: *@This() = @fieldParentPtr("job", j);
            self.res = f(self.arg);
            j.done.store(1, .release);
        }
    };
}

/// `f(a)` inline and `f(b)` offered to the other workers: rayon::join's
/// order, fork.rig's (`b = f(right)&; a = f(left); a + >b`).
inline fn join(comptime Arg: type, comptime R: type, comptime f: fn (Arg) R, a: Arg, b: Arg) struct { R, R } {
    if (cfg.seq) return .{ f(a), f(b) };
    const T = Rec(Arg, R, f);
    const w = me;
    var frame: T = undefined;
    _ = &frame;
    const rec: *T = if (cfg.heap) @ptrCast(@alignCast(w.heap.alloc())) else &frame;
    comptime std.debug.assert(@sizeOf(T) <= Heap.block);
    rec.* = .{ .job = .{ .exec = T.exec }, .arg = b };
    if (cfg.sc) _ = w.slot.swap(@intFromPtr(rec), .seq_cst);
    w.deque.push(&rec.job);
    notify();
    const ra = f(a);
    var rb: R = undefined;
    if (cfg.sc) {
        _ = rec.words[0].swap(1, .seq_cst);
        _ = w.slot.cmpxchgStrong(@intFromPtr(rec), 0, .seq_cst, .seq_cst);
    }
    if (w.deque.pop()) |j| {
        std.debug.assert(j == &rec.job);
        if (cfg.sc) {
            rec.words[1].store(1, .seq_cst);
            rec.words[2].store(1, .seq_cst);
            rec.words[3].store(1, .seq_cst);
        }
        if (cfg.stack or cfg.monitor) {
            runJob(w, j);
            rb = rec.res;
        } else {
            rb = f(rec.arg);
        }
        if (cfg.sc) rec.words[0].store(2, .seq_cst);
    } else {
        // Stolen: help until the thief is done.
        while (rec.job.done.load(.acquire) == 0) {
            if (stealAny(w)) |j| runJob(w, j) else std.atomic.spinLoopHint();
        }
        rb = rec.res;
    }
    if (cfg.heap) w.heap.release(rec);
    return .{ ra, rb };
}

// -----------------------------------------------------------------------------
// The stack arm: Rig's switch (sched.zig, `switchNaked`, `frameCalling`)
// -----------------------------------------------------------------------------

const saved_bytes = switch (builtin.target.cpu.arch) {
    .aarch64 => 160,
    .x86_64 => 7 * 8,
    else => @compileError("aarch64 and x86_64 only"),
};

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

fn startNaked() callconv(.naked) void {
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

fn switchTo(from: *usize, to: usize) void {
    var f: SwitchFn = @ptrCast(&switchNaked);
    asm volatile (""
        : [f] "+r" (f),
    );
    f(from, to);
}

fn frameCalling(arg: usize, entry: usize, top: usize) usize {
    const sp = (top & ~@as(usize, 15)) - saved_bytes;
    const slots: [*]usize = @ptrFromInt(sp);
    @memset(slots[0 .. saved_bytes / 8], 0);
    switch (builtin.target.cpu.arch) {
        .aarch64 => {
            slots[0] = arg;
            slots[1] = entry;
            slots[11] = @intFromPtr(&startNaked);
        },
        .x86_64 => {
            slots[3] = entry;
            slots[4] = arg;
            slots[6] = @intFromPtr(&startNaked);
        },
        else => unreachable,
    }
    return sp;
}

const Apart = struct { job: *Job, back: usize = 0 };

fn apartMain(a: *Apart) callconv(.c) noreturn {
    a.job.exec(a.job);
    var gone: usize = 0;
    switchTo(&gone, a.back);
    unreachable;
}

fn runOnStack(w: *Worker, j: *Job) void {
    const s = w.stacks.take();
    var a: Apart = .{ .job = j };
    switchTo(&a.back, frameCalling(@intFromPtr(&a), @intFromPtr(&apartMain), w.stacks.top(s)));
    w.stacks.give(s);
}

// -----------------------------------------------------------------------------
// The monitor arm
// -----------------------------------------------------------------------------

fn onUrg(_: std.posix.SIG, _: *const std.posix.siginfo_t, _: ?*anyopaque) callconv(.c) void {}

var signals: std.atomic.Value(u64) = .init(0);
var looks: std.atomic.Value(u64) = .init(0);
/// CEIL_NOSIG=1: the monitor looks and counts, and sends no signal (a probe).
var no_signals = false;

fn monitorMain() void {
    var seen: [max_workers]u64 = @splat(0);
    var had: [max_workers]bool = @splat(false);
    // Signals sent to each worker since it last ran a new fork, and when
    // it is signaled next once it has declined `resignal_free` of them
    // (Rig's `watchSlices`: four in a row, then each twice as long after
    // the one before, up to 1 ms).
    var tries: [max_workers]u32 = @splat(0);
    var next_at: [max_workers]i96 = @splat(0);
    const wait: i96 = 50 * std.time.ns_per_us;
    var period: i96 = std.time.ns_per_ms;
    while (true) {
        sleepNs(period);
        _ = looks.fetchAdd(1, .monotonic);
        const now = nowNs();
        var queued = false;
        var busy = false;
        for (workers[0..nworkers], 0..) |*w, i| {
            const runs = w.runs.load(.monotonic);
            const work = w.deque.holds();
            queued = queued or work;
            defer had[i] = work;
            if (runs != seen[i]) {
                seen[i] = runs;
                tries[i] = 0;
                busy = true;
                continue;
            }
            if (!(work and had[i]) or w.tid == 0) continue;
            if (tries[i] >= resignal_free and now < next_at[i]) continue;
            tries[i] += 1;
            if (tries[i] >= resignal_free) {
                const shift: u6 = @intCast(@min(tries[i] - resignal_free + 1, 16));
                next_at[i] = now + @min(wait << shift, std.time.ns_per_ms);
            }
            _ = signals.fetchAdd(1, .monotonic);
            if (!no_signals) _ = std.c.pthread_kill(@ptrFromInt(w.tid), .URG);
        }
        period = if (queued) wait else if (busy) std.time.ns_per_ms else @min(2 * period, 10 * std.time.ns_per_ms);
    }
}

const resignal_free = 4;

fn sleepNs(ns: i96) void {
    const req: std.c.timespec = .{ .sec = @intCast(@divTrunc(ns, std.time.ns_per_s)), .nsec = @intCast(@mod(ns, std.time.ns_per_s)) };
    _ = std.c.nanosleep(&req, null);
}

// -----------------------------------------------------------------------------
// psum and qsort, as fork.rig
// -----------------------------------------------------------------------------

/// The leaf: `rig.fold(.add_wrap, ...)` as Rig emits `for x in xs; s +%= x`
/// (runtime.zig), without its turn count (a program built to be preempted,
/// as fork.rig is, counts no turns).
inline fn fold(s: i64, xs: []const i64) i64 {
    const lanes = comptime blk: {
        const most = 32 / @sizeOf(i64);
        const native = std.simd.suggestVectorLength(i64) orelse 16 / @sizeOf(i64);
        break :blk @min(most, @max(native, 16 / @sizeOf(i64)));
    };
    const V = @Vector(lanes, i64);
    const c = 16 * lanes;
    var a0: V = @splat(0);
    var a1: V = @splat(0);
    var a2: V = @splat(0);
    var a3: V = @splat(0);
    var r = s;
    var i: usize = 0;
    while (i + c <= xs.len) : (i += c) {
        const p = xs[i..][0..c];
        var j: usize = 0;
        while (j < c) : (j += 4 * lanes) {
            a0 +%= @as(V, p[j..][0..lanes].*);
            a1 +%= @as(V, p[j + lanes ..][0..lanes].*);
            a2 +%= @as(V, p[j + 2 * lanes ..][0..lanes].*);
            a3 +%= @as(V, p[j + 3 * lanes ..][0..lanes].*);
        }
    }
    r +%= @reduce(.Add, (a0 +% a1) +% (a2 +% a3));
    for (xs[i..]) |x| r +%= x;
    return r;
}

fn psum(xs: []const i64) i64 {
    if (xs.len <= GRAIN) return fold(0, xs);
    const mid = xs.len / 2;
    const r = join([]const i64, i64, psum, xs[0..mid], xs[mid..]);
    return r[0] +% r[1];
}

/// psum's tree with no memory: each leaf gives its length (runtime.md's
/// `nil`), so a pass is the fork-join alone.
fn nil(xs: []const i64) i64 {
    if (xs.len <= GRAIN) return @intCast(xs.len);
    const mid = xs.len / 2;
    const r = join([]const i64, i64, nil, xs[0..mid], xs[mid..]);
    return r[0] +% r[1];
}

const L = std.ArrayList(i64);

fn qsort(xs_in: L) L {
    var xs = xs_in;
    if (xs.items.len <= GRAIN) {
        rigsort.unstable_int(i64, xs.items);
        return xs;
    }
    const n = xs.items.len;
    const pivot = xs.items[n / 2];
    var lo = L.initCapacity(gpa, n / 2) catch oom();
    var mid: L = .empty;
    var hi = L.initCapacity(gpa, n / 2) catch oom();
    for (xs.items) |x| {
        if (x < pivot) {
            lo.append(gpa, x) catch oom();
        } else if (x > pivot) {
            hi.append(gpa, x) catch oom();
        } else {
            mid.append(gpa, x) catch oom();
        }
    }
    const r = join(L, L, qsort, lo, hi);
    var out = r[0];
    var high = r[1];
    out.appendSlice(gpa, mid.items) catch oom();
    out.appendSlice(gpa, high.items) catch oom();
    high.deinit(gpa);
    mid.deinit(gpa);
    xs.deinit(gpa);
    return out;
}

// -----------------------------------------------------------------------------
// main
// -----------------------------------------------------------------------------

fn say(comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch unreachable;
    std.Io.File.stdout().writeStreamingAll(io(), line) catch {};
}

fn envInt(name: [*:0]const u8) ?usize {
    const v = std.c.getenv(name) orelse return null;
    return std.fmt.parseInt(usize, std.mem.span(v), 10) catch null;
}

pub fn main() void {
    if (cfg.offmain) {
        const t = std.Thread.spawn(.{ .stack_size = 16 << 20 }, body, .{}) catch oom();
        t.join();
        return;
    }
    body();
}

fn body() void {
    nworkers = envInt("CEIL_WORKERS") orelse envInt("RIG_WORKERS") orelse (std.Thread.getCpuCount() catch 1);
    nworkers = @max(1, @min(nworkers, max_workers));
    no_signals = envInt("CEIL_NOSIG") != null;
    if (envInt("CEIL_SPIN_US")) |us| spin_ns = @as(i96, @intCast(us)) * std.time.ns_per_us;
    workers = std.heap.page_allocator.alloc(Worker, nworkers) catch oom();
    for (workers, 0..) |*w, i| w.* = .{ .id = i, .rng = 0x9E3779B97F4A7C15 *% (i + 1) };
    me = &workers[0];
    workers[0].tid = threadId();
    touchAllocators(&workers[0]);
    if (cfg.monitor) {
        const act: std.posix.Sigaction = .{
            .handler = .{ .sigaction = onUrg },
            .mask = std.posix.sigemptyset(),
            .flags = std.posix.SA.SIGINFO | std.posix.SA.ONSTACK | std.posix.SA.RESTART,
        };
        std.posix.sigaction(.URG, &act, null);
    }
    for (workers[1..]) |*w| {
        const t = std.Thread.spawn(.{}, workerMain, .{w}) catch oom();
        t.detach();
    }
    while (started.load(.seq_cst) != nworkers - 1) std.atomic.spinLoopHint();
    if (cfg.monitor) {
        const t = std.Thread.spawn(.{ .stack_size = 64 << 10 }, monitorMain, .{}) catch oom();
        t.detach();
    }

    const n = 1 << 25;
    const t0 = nowNs();
    const xs = gpa.alloc(i64, n) catch oom();
    for (xs, 0..) |*x, i| x.* = @mod(@as(i64, @intCast(i)) *% 2654435761, 1000);
    if (envInt("CEIL_BUILD") != null) say("build {d} 0\n", .{nowNs() - t0});
    var k: u32 = 1;
    while (k <= cfg.passes) : (k += 1) {
        const t = nowNs();
        const s = psum(xs);
        const el = nowNs() - t;
        if (cfg.passes == 1) say("psum {d} {d}\n", .{ el, s }) else say("psum{d} {d} {d}\n", .{ k, el, s });
    }
    if (cfg.passes > 1) {
        k = 1;
        while (k <= cfg.passes) : (k += 1) {
            const t = nowNs();
            const s = nil(xs);
            say("nil{d} {d} {d}\n", .{ k, nowNs() - t, s });
        }
    }
    gpa.free(xs);

    const m = 1 << 22;
    k = 1;
    while (k <= cfg.passes) : (k += 1) {
        var ys = L.initCapacity(gpa, m) catch oom();
        for (0..m) |i| ys.appendAssumeCapacity((@as(i64, @intCast(i)) *% 6364136223846793005 +% 1442695040888963407) >> 20);
        const t = nowNs();
        var zs = qsort(ys);
        const el = nowNs() - t;
        var ok: usize = 1;
        for (1..zs.items.len) |i| {
            if (zs.items[i - 1] > zs.items[i]) ok = 0;
        }
        if (cfg.passes == 1) say("qsort {d} {d}\n", .{ el, ok * zs.items.len }) else say("qsort{d} {d} {d}\n", .{ k, el, ok * zs.items.len });
        zs.deinit(gpa);
    }
    if (cfg.monitor and envInt("CEIL_SIGNALS") != null) say("monitor looks {d} signals {d}\n", .{ looks.load(.monotonic), signals.load(.monotonic) });
    std.process.exit(0);
}
