//! Step 3a of the Mac preemption port: on arm64 macOS, how long a
//! signal sent by `pthread_kill` takes to reach a thread that is
//! running, and whether rewriting the signal context's pc and sp to
//! enter a trampoline that returns by `br x15` (x15 reserved,
//! `+reserve_x15`) resumes the stopped code with every register intact.
//!
//! zig build-exe -OReleaseFast -mcpu=native+reserve_x15 probe.zig
//! ./probe [signals]
const std = @import("std");
const builtin = @import("builtin");

comptime {
    if (builtin.cpu.arch != .aarch64 or builtin.os.tag != .macos) @compileError("arm64 macOS only");
}

const Machine = extern struct {
    far: u64,
    esr: u32,
    exception: u32,
    regs: [32]u64, // x0-x28, fp, lr, sp
    pc: u64,
    cpsr: u32,
    pad: u32,
};
const Context = extern struct {
    onstack: c_int,
    sigmask: u32,
    stack: extern struct { sp: ?*anyopaque, size: usize, flags: c_int },
    link: ?*anyopaque,
    mcsize: usize,
    mcontext: *Machine,
};

inline fn ticks() u64 {
    return asm volatile ("isb\nmrs %[t], cntvct_el0"
        : [t] "=r" (-> u64),
    );
}

var sent_at: std.atomic.Value(u64) = .init(0);
var seen_at: std.atomic.Value(u64) = .init(0);
var entered_at: std.atomic.Value(u64) = .init(0);
var handled: std.atomic.Value(u64) = .init(0);
var entered: std.atomic.Value(u64) = .init(0);
var stop: std.atomic.Value(bool) = .init(false);
var rewrite = true;
var mach = false;

extern "c" fn pthread_mach_thread_np(std.c.pthread_t) u32;
extern "c" fn thread_suspend(u32) c_int;
extern "c" fn thread_resume(u32) c_int;
extern "c" fn thread_get_state(u32, c_int, *State, *u32) c_int;
extern "c" fn thread_set_state(u32, c_int, *const State, u32) c_int;
/// ARM_THREAD_STATE64 (flavor 6), 68 words.
const State = extern struct { x: [29]u64, fp: u64, lr: u64, sp: u64, pc: u64, cpsr: u32, flags: u32 };
var suspended: [*]u64 = undefined;
extern "c" fn pthread_set_qos_class_self_np(c_uint, c_int) c_int;
var qos: c_uint = 0;

fn onSignal(_: std.posix.SIG, _: *const std.posix.siginfo_t, ctx: ?*anyopaque) callconv(.c) void {
    seen_at.store(ticks(), .monotonic);
    const uc: *Context = @ptrCast(@alignCast(ctx.?));
    const m = uc.mcontext;
    if (rewrite) {
        // As if the stopped instruction called the trampoline: its pc
        // on the stack below the 128-byte red zone, 16-byte aligned.
        const sp = m.regs[31];
        const at = sp - 128 - 16;
        @as(*u64, @ptrFromInt(at)).* = m.pc;
        m.regs[31] = at;
        m.pc = @intFromPtr(&entry);
    }
    _ = handled.fetchAdd(1, .release);
}

fn enteredC() callconv(.c) void {
    entered_at.store(ticks(), .monotonic);
    // Clobber what a call may: the caller-saved vector and general
    // registers, as `preempted` would.
    var v: @Vector(4, f32) = @splat(@floatFromInt(entered.load(.monotonic)));
    asm volatile ("" : [v] "+w" (v));
    _ = entered.fetchAdd(1, .release);
}

/// Saves x0-x18 except x15, x29, x30, NZCV, FPSR, FPCR and q0-q31, calls
/// `enteredC`, restores them, and returns to the pc the handler left at
/// the stack pointer, by x15.
fn entry() callconv(.naked) void {
    asm volatile (
        \\ sub sp, sp, #720
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
        \\ add x29, sp, #128
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
        \\ ldp x0, x1, [sp, #0]
        \\ add sp, sp, #720
        \\ ldr x15, [sp]
        \\ add sp, sp, #144
        \\ br x15
        :
        : [f] "X" (&enteredC),
    );
}

/// Work that keeps many general and vector registers live: sixteen
/// integer streams and eight float streams.
noinline fn work(rounds: u64) [2]u64 {
    var a: [16]u64 = undefined;
    for (&a, 0..) |*x, i| x.* = 0x9e3779b97f4a7c15 *% (i + 1);
    var f: [8]f64 = undefined;
    for (&f, 0..) |*x, i| x.* = @floatFromInt(i + 1);
    var r: u64 = 0;
    while (r < rounds) : (r += 1) {
        inline for (0..16) |i| a[i] = a[i] *% 6364136223846793005 +% (2 * i + 1);
        inline for (0..8) |i| f[i] = f[i] * 0.999999 + @as(f64, @floatFromInt(a[i] >> 40)) * 1e-9;
        asm volatile ("" ::: .{ .memory = true });
    }
    var s: u64 = 0;
    for (a) |x| s ^= x;
    var t: f64 = 0;
    for (f) |x| t += x;
    return .{ s, @bitCast(t) };
}

var handle: std.atomic.Value(usize) = .init(0);
var result: [2]u64 = undefined;
var spin_rounds: u64 = 0;

var alt: [64 << 10]u8 align(16) = undefined;

fn spinner() void {
    const ss: std.posix.stack_t = .{ .sp = &alt, .size = alt.len, .flags = 0 };
    std.posix.sigaltstack(&ss, null) catch unreachable;
    if (qos != 0) _ = pthread_set_qos_class_self_np(qos, 0);
    handle.store(@intFromPtr(std.c.pthread_self()), .release);
    var total: [2]u64 = .{ 0, 0 };
    var n: u64 = 0;
    while (!stop.load(.monotonic)) : (n += 1) {
        const r = work(100_000);
        total[0] ^= r[0];
        total[1] ^= r[1];
    }
    spin_rounds = n;
    result = total;
}

fn lessThan(_: void, a: u64, b: u64) bool {
    return a < b;
}

fn report(name: []const u8, xs: []u64) void {
    std.mem.sort(u64, xs, {}, lessThan);
    const ns = struct {
        fn of(t: u64) f64 {
            return @as(f64, @floatFromInt(t)) * 1e9 / 24e6;
        }
    }.of;
    std.debug.print("{s}: n {d}, median {d:.0} ns, p90 {d:.0}, p99 {d:.0}, max {d:.0}\n", .{ name, xs.len, ns(xs[xs.len / 2]), ns(xs[xs.len * 9 / 10]), ns(xs[xs.len * 99 / 100]), ns(xs[xs.len - 1]) });
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    var it = try init.minimal.args.iterateAllocator(gpa);
    defer it.deinit();
    _ = it.next();
    const n: usize = if (it.next()) |a| try std.fmt.parseInt(usize, a, 10) else 20_000;
    if (it.next()) |a| {
        rewrite = !std.mem.eql(u8, a, "plain");
        mach = std.mem.eql(u8, a, "mach");
    }

    const act: std.posix.Sigaction = .{
        .handler = .{ .sigaction = onSignal },
        .mask = std.posix.sigemptyset(),
        .flags = std.posix.SA.SIGINFO | std.posix.SA.ONSTACK | std.posix.SA.RESTART,
    };
    std.posix.sigaction(.URG, &act, null);

    if (it.next()) |a| qos = try std.fmt.parseInt(c_uint, a, 0);
    if (qos != 0) _ = pthread_set_qos_class_self_np(qos, 0);
    const delivery = try gpa.alloc(u64, n);
    const through = try gpa.alloc(u64, n);
    const t = try std.Thread.spawn(.{}, spinner, .{});
    while (handle.load(.acquire) == 0) std.atomic.spinLoopHint();
    const h: std.c.pthread_t = @ptrFromInt(handle.load(.acquire));
    // Let the spinner settle on a core.
    const settle = ticks() + 24_000 * 50;
    while (ticks() < settle) std.atomic.spinLoopHint();
    const port = pthread_mach_thread_np(h);
    const susp = try gpa.alloc(u64, n);
    suspended = susp.ptr;
    var outside: u64 = 0;
    if (mach) for (0..n) |i| {
        const want_in = entered.load(.monotonic) + 1;
        const t0 = ticks();
        if (thread_suspend(port) != 0) return error.Suspend;
        susp[i] = ticks() - t0;
        var st: State = undefined;
        var count: u32 = @sizeOf(State) / 4;
        if (thread_get_state(port, 6, &st, &count) != 0) return error.GetState;
        if (st.pc < @intFromPtr(&work) or st.pc >= @intFromPtr(&work) + 4096) {
            outside += 1;
            _ = thread_resume(port);
            delivery[i] = 0;
            through[i] = 0;
            continue;
        }
        const at = st.sp - 128 - 16;
        @as(*u64, @ptrFromInt(at)).* = st.pc;
        st.sp = at;
        st.pc = @intFromPtr(&entry);
        if (thread_set_state(port, 6, &st, count) != 0) return error.SetState;
        if (thread_resume(port) != 0) return error.Resume;
        delivery[i] = ticks() - t0;
        while (entered.load(.acquire) < want_in) std.atomic.spinLoopHint();
        through[i] = entered_at.load(.monotonic) -| t0;
        const next = ticks() + 1200;
        while (ticks() < next) std.atomic.spinLoopHint();
    };
    if (!mach) for (0..n) |i| {
        const want = handled.load(.monotonic) + 1;
        const want_in = entered.load(.monotonic) + 1;
        const t0 = ticks();
        sent_at.store(t0, .monotonic);
        _ = std.c.pthread_kill(h, .URG);
        while (handled.load(.acquire) < want) std.atomic.spinLoopHint();
        if (rewrite) while (entered.load(.acquire) < want_in) std.atomic.spinLoopHint();
        delivery[i] = seen_at.load(.monotonic) -| t0;
        through[i] = if (rewrite) entered_at.load(.monotonic) -| t0 else 0;
        // About 50 µs apart, as the monitor's shortest period.
        const next = ticks() + 1200;
        while (ticks() < next) std.atomic.spinLoopHint();
    };
    stop.store(true, .monotonic);
    t.join();
    if (mach) {
        std.debug.print("{d} stops outside work, left alone\n", .{outside});
        report("thread_suspend returns", susp);
        report("suspend to resume returned", delivery);
        report("suspend to the trampoline's call", through);
    } else report("pthread_kill to handler", delivery);
    if (rewrite and !mach) report("pthread_kill to the trampoline's call", through);

    // Recompute the spinner's rounds with no signals: a register the
    // trampoline failed to keep changes the result.
    var total: [2]u64 = .{ 0, 0 };
    for (0..spin_rounds) |_| {
        const r = work(100_000);
        total[0] ^= r[0];
        total[1] ^= r[1];
    }
    const same = total[0] == result[0] and total[1] == result[1];
    std.debug.print("{d} signals, {d} entered, {d} rounds of work: {s}\n", .{ handled.load(.monotonic), entered.load(.monotonic), spin_rounds, if (same) "registers intact" else "MISMATCH" });
    if (!same) std.process.exit(1);
}
