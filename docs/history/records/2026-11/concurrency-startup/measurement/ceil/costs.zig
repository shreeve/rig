// Microcosts of what Rig's first parallel call does: thread spawn to first run,
// kqueue open, a 16-stack reservation (mmap + 16 mprotect), the first touch of a
// stack page, and an alternate signal stack. Medians of R runs, in ns.
const std = @import("std");
extern "c" fn clock_gettime_nsec_np(clock: u32) u64;
fn now() u64 { return clock_gettime_nsec_np(8); }
var started: [16]std.atomic.Value(u64) = @splat(.init(0));
fn body(i: usize) void { started[i].store(now(), .seq_cst); }
fn median(xs: []u64) u64 { std.mem.sort(u64, xs, {}, std.sort.asc(u64)); return xs[xs.len / 2]; }
pub fn main() !void {
    const R = 21;
    var spawn9: [R]u64 = undefined; var firstrun: [R]u64 = undefined; var lastrun: [R]u64 = undefined;
    var kq: [R]u64 = undefined; var res: [R]u64 = undefined; var touch1: [R]u64 = undefined; var touch16: [R]u64 = undefined; var alt: [R]u64 = undefined;
    const guard: usize = 16 << 20; const len: usize = 64 << 20; const span = guard + len + 16384;
    for (0..R) |r| {
        for (&started) |*s| s.store(0, .seq_cst);
        var th: [9]std.Thread = undefined;
        const t0 = now();
        for (0..9) |i| th[i] = try std.Thread.spawn(.{}, body, .{i});
        const t1 = now();
        for (th) |t| t.join();
        var mn: u64 = std.math.maxInt(u64); var mx: u64 = 0;
        for (0..9) |i| { const v = started[i].load(.seq_cst); mn = @min(mn, v); mx = @max(mx, v); }
        spawn9[r] = t1 - t0; firstrun[r] = mn - t0; lastrun[r] = mx - t0;
        var t = now();
        var fds: [9]i32 = undefined;
        for (&fds) |*f| f.* = std.c.kqueue();
        kq[r] = now() - t;
        for (fds) |f| _ = std.c.close(f);
        t = now();
        const got = try std.posix.mmap(null, span * 16, .{}, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
        const base = @intFromPtr(got.ptr);
        for (0..16) |i| _ = std.posix.system.mprotect(@ptrFromInt(base + i * span + guard), len, .{ .READ = true, .WRITE = true });
        res[r] = now() - t;
        t = now();
        @as(*volatile u8, @ptrFromInt(base + guard + len - 64)).* = 1;
        touch1[r] = now() - t;
        t = now();
        for (1..16) |i| @as(*volatile u8, @ptrFromInt(base + i * span + guard + len - 64)).* = 1;
        touch16[r] = (now() - t) / 15;
        std.posix.munmap(got);
        t = now();
        const a = try std.posix.mmap(null, 256 << 10, .{ .READ = true, .WRITE = true }, .{ .TYPE = .PRIVATE, .ANONYMOUS = true, .NORESERVE = true }, -1, 0);
        try std.posix.sigaltstack(&.{ .sp = a.ptr, .flags = 0, .size = 256 << 10 }, null);
        alt[r] = now() - t;
        std.posix.sigaltstack(&.{ .sp = a.ptr, .flags = std.posix.system.SS.DISABLE, .size = 0 }, null) catch {};
        std.posix.munmap(a);
    }
    std.debug.print("spawn 9 threads (caller) {d} ns\nfirst thread runs after {d} ns\nlast of 9 runs after {d} ns\n9 kqueues {d} ns\nreserve 16 stacks (mmap+16 mprotect) {d} ns\nfirst touch, first stack {d} ns\nfirst touch, next stacks {d} ns each\nalt stack mmap+sigaltstack {d} ns\n", .{ median(&spawn9), median(&firstrun), median(&lastrun), median(&kq), median(&res), median(&touch1), median(&touch16), median(&alt) });
}
