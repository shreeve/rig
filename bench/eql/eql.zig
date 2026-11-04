//! Byte equality: the runtime's `bytesEql` against `std.mem.eql(u8, …)`,
//! by length, on equal inputs and on inputs that differ in their first
//! byte. Each round compares 4096 pairs of one length at varied
//! offsets, so neither the pointers nor the length are known to the
//! loop. The fastest of 15 interleaved rounds, in nanoseconds per
//! compare.
//!
//!     zig run -O ReleaseFast --dep runtime -Mroot=bench/eql/eql.zig -Mruntime=src/runtime.zig
//!
//! The same with `-- check` after it instead tests
//! `bytesEql` against `std.mem.eql` on every length to 300, every
//! alignment, and a difference at every byte.

const std = @import("std");
const rt = @import("runtime");

const pairs = 4096;
const reps = 64;
const rounds = 15;
const lengths = [_]usize{ 0, 1, 2, 3, 4, 5, 7, 8, 9, 12, 15, 16, 17, 20, 24, 31, 32, 33, 40, 48, 63, 64, 65, 76, 96, 127, 128 };

var buf_a: [pairs * 2 + 512]u8 = undefined;
var buf_b: [pairs * 2 + 512]u8 = undefined;

/// A value the optimizer cannot see through.
inline fn opaqueValue(x: usize) usize {
    var y = x;
    std.mem.doNotOptimizeAway(&y);
    return @as(*volatile usize, &y).*;
}

fn timeOne(io: std.Io, comptime which: enum { std, rig }, n: usize) u64 {
    const len = opaqueValue(n);
    var hits: usize = 0;
    const t0 = std.Io.Clock.awake.now(io);
    for (0..reps) |_| {
        var off: usize = 0;
        for (0..pairs) |_| {
            const a = buf_a[off..][0..len];
            const b = buf_b[off + 3 ..][0..len];
            hits += @intFromBool(switch (which) {
                .std => std.mem.eql(u8, a, b),
                .rig => rt.bytesEql(a, b),
            });
            off = (off + 2) & (pairs * 2 - 1);
        }
    }
    const ns = t0.untilNow(io, .awake).toNanoseconds();
    std.mem.doNotOptimizeAway(hits);
    return @intCast(ns);
}

fn fill(differ: bool) void {
    for (&buf_a, 0..) |*c, i| c.* = @truncate(i *% 7 +% 1);
    // b[i + 3] == a[i]: every pair compares equal unless `differ`.
    for (&buf_b, 0..) |*c, i| c.* = if (i >= 3) buf_a[i - 3] else 0;
    // Differing in the first byte: every a[i] differs from b[i + 3].
    if (differ) for (buf_b[3..]) |*c| {
        c.* +%= 1;
    };
}

fn check() void {
    var a: [400]u8 = undefined;
    var b: [400]u8 = undefined;
    for (&a, 0..) |*c, i| c.* = @truncate(i *% 31 +% 5);
    for (0..300) |n| for (0..8) |oa| for (0..8) |ob| {
        @memcpy(b[ob..][0..n], a[oa..][0..n]);
        const x = a[oa..][0..n];
        const y = b[ob..][0..n];
        if (!rt.bytesEql(x, y)) std.debug.panic("equal, length {d}, offsets {d} {d}", .{ n, oa, ob });
        for (0..n) |k| {
            b[ob + k] ^= 0x40;
            if (rt.bytesEql(x, y)) std.debug.panic("differ at {d}, length {d}", .{ k, n });
            b[ob + k] ^= 0x40;
        }
        if (n > 0 and rt.bytesEql(x, b[ob..][0 .. n - 1])) std.debug.panic("length {d} vs {d}", .{ n, n - 1 });
    };
    std.debug.print("bytesEql agrees with std.mem.eql to 300 bytes\n", .{});
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var args = init.minimal.args.iterate();
    _ = args.skip();
    if (args.next()) |arg| if (std.mem.eql(u8, arg, "check")) return check();

    std.debug.print("{s:>5} {s:>9} {s:>9} {s:>7}   {s:>9} {s:>9} {s:>7}\n", .{ "len", "std eq", "rig eq", "rig/std", "std ne", "rig ne", "rig/std" });
    for (lengths) |n| {
        var best: [2][2]u64 = .{ .{ std.math.maxInt(u64), std.math.maxInt(u64) }, .{ std.math.maxInt(u64), std.math.maxInt(u64) } };
        for (0..2) |d| {
            fill(d == 1);
            for (0..rounds) |_| {
                best[d][0] = @min(best[d][0], timeOne(io, .std, n));
                best[d][1] = @min(best[d][1], timeOne(io, .rig, n));
            }
        }
        const per: f64 = @floatFromInt(pairs * reps);
        const ns = struct {
            fn f(t: u64, p: f64) f64 {
                return @as(f64, @floatFromInt(t)) / p;
            }
        }.f;
        std.debug.print("{d:>5} {d:>9.3} {d:>9.3} {d:>7.2}   {d:>9.3} {d:>9.3} {d:>7.2}\n", .{
            n,                                                                         ns(best[0][0], per),                               ns(best[0][1], per),
            @as(f64, @floatFromInt(best[0][1])) / @as(f64, @floatFromInt(best[0][0])), ns(best[1][0], per),                               ns(best[1][1], per),
            @as(f64, @floatFromInt(best[1][1])) / @as(f64, @floatFromInt(best[1][0])),
        });
    }
}
