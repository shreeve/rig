// A 16-stack reservation (mmap PROT_NONE + 16 mprotect RW, as sched.takeStack) and
// variants, timed with 0 or 9 other threads of the process running, idle-spinning
// or each reserving and touching at once. Medians of R, in us.
const std = @import("std");
extern "c" fn clock_gettime_nsec_np(clock: u32) u64;
extern "c" fn usleep(us: c_uint) c_int;
fn nap(ms: u32) void { _ = usleep(ms * 1000); }
fn now() u64 { return clock_gettime_nsec_np(8); }
const guard: usize = 16 << 20; const len: usize = 64 << 20; const span = guard + len + 16384;
var stop = std.atomic.Value(bool).init(false);
var go = std.atomic.Value(u32).init(0);
fn spin() void { while (!stop.load(.monotonic)) std.atomic.spinLoopHint(); }
fn reserveProtect() []align(16384) u8 {
    const got = std.posix.mmap(null, span * 16, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch unreachable;
    const base = @intFromPtr(got.ptr);
    for (0..16) |i| _ = std.posix.system.mprotect(@ptrFromInt(base + i * span + guard), len, .{ .READ = true, .WRITE = true });
    return got;
}
fn reserveRWGuardsNone() []align(16384) u8 {
    // the whole chunk read-write, then each guard made inaccessible
    const got = std.posix.mmap(null, span * 16, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch unreachable;
    const base = @intFromPtr(got.ptr);
    for (0..16) |i| _ = std.posix.system.mprotect(@ptrFromInt(base + i * span), guard, .{});
    return got;
}
fn reserveFixed() []align(16384) u8 {
    const got = std.posix.mmap(null, span * 16, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0) catch unreachable;
    const base = @intFromPtr(got.ptr);
    for (0..16) |i| _ = std.posix.mmap(@ptrFromInt(base + i * span + guard), len, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true, .FIXED = true }, -1, 0) catch unreachable;
    return got;
}
fn touchAll(got: []align(16384) u8) void {
    const base = @intFromPtr(got.ptr);
    for (0..16) |i| @as(*volatile u8, @ptrFromInt(base + i * span + guard + len - 64)).* = 1;
}
var res: [16]u64 = undefined;
fn worker(i: usize, f: *const fn () []align(16384) u8) void {
    while (go.load(.acquire) == 0) std.atomic.spinLoopHint();
    const t = now();
    const g = f();
    touchAll(g);
    res[i] = now() - t;
    while (!stop.load(.monotonic)) std.atomic.spinLoopHint();
    std.posix.munmap(g);
}
fn median(xs: []u64) u64 { std.mem.sort(u64, xs, {}, std.sort.asc(u64)); return xs[xs.len / 2]; }
pub fn main() !void {
    const R = 15;
    const fs = [_]struct { n: []const u8, f: *const fn () []align(16384) u8 }{ .{ .n = "mmap none + 16 mprotect rw (Rig)", .f = reserveProtect }, .{ .n = "mmap rw + 16 mprotect guard none", .f = reserveRWGuardsNone }, .{ .n = "mmap none + 16 mmap FIXED rw", .f = reserveFixed } };
    for (fs) |v| {
        var a: [R]u64 = undefined; var b: [R]u64 = undefined; var c: [R]u64 = undefined;
        for (0..R) |r| {
            // alone
            var t = now(); var g = v.f(); a[r] = now() - t; std.posix.munmap(g);
            // 9 threads spinning
            stop.store(false, .seq_cst);
            var th: [9]std.Thread = undefined;
            for (&th) |*x| x.* = try std.Thread.spawn(.{}, spin, .{});
            nap(2);
            t = now(); g = v.f(); b[r] = now() - t; std.posix.munmap(g);
            stop.store(true, .seq_cst);
            for (th) |x| x.join();
            // 10 threads reserving and touching at once
            stop.store(false, .seq_cst); go.store(0, .seq_cst);
            var tw: [10]std.Thread = undefined;
            for (&tw, 0..) |*x, i| x.* = try std.Thread.spawn(.{}, worker, .{ i, v.f });
            nap(2);
            go.store(1, .release);
            nap(5);
            stop.store(true, .seq_cst);
            for (tw) |x| x.join();
            c[r] = median(res[0..10]);
        }
        std.debug.print("{s}: alone {d:.1} us, 9 others spinning {d:.1} us, 10 at once (median thread, with touch) {d:.1} us\n", .{ v.n, @as(f64, @floatFromInt(median(&a))) / 1e3, @as(f64, @floatFromInt(median(&b))) / 1e3, @as(f64, @floatFromInt(median(&c))) / 1e3 });
    }
}
