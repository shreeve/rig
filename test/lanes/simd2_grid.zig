// The SIMD round 2 operations against a scalar reference, on every lane
// type, lane count, amount, and table size, with vectors loaded from bytes
// by a noinline function so that nothing folds at compile time:
//
//   simd2_grid [seeds]          every cell; exits 1 if any lane is wrong
//   simd2_grid shl <type> <n>   a `vecShl` that loses a bit in its last
//                               lane: must panic "left shift overflowed bits"
//
// Operations: `+|` and `-|` (`rig.vecAddSat`, `vecSubSat`, and the
// scalar operators),
// `rig.vecShl` (on vectors that lose no bits), `vecShlWrap`, `vecShr`,
// `rig.lookup` (tables of 16, 32, 64 bytes; indexes of every lane count,
// biased to the edges: past the table, `pshufb`'s bit 7, 0x70), and
// `rig.lag` (every amount). `simd2_grid.py` builds it for each target and
// mode and runs it.
const std = @import("std");
const rig = @import("rig");

const types = .{ u8, i8, u16, i16, u32, i32, u64, i64 };
const lane_counts = .{ 2, 4, 8, 16, 32, 64 };

var bad: usize = 0;

fn fail(comptime fmt: []const u8, args: anytype) void {
    bad += 1;
    if (bad <= 40) std.debug.print(fmt ++ "\n", args);
}

noinline fn load(comptime T: type, comptime n: usize, xs: *const [n]T) @Vector(n, T) {
    return xs.*;
}

noinline fn amount(c: usize) usize {
    return c;
}

/// Lane values: random, or the type's edges and their neighbours.
fn lanes(comptime T: type, comptime n: usize, r: std.Random) [n]T {
    const edges = [_]T{ std.math.minInt(T), std.math.minInt(T) +% 1, std.math.maxInt(T), std.math.maxInt(T) -% 1, 0, 1, @bitCast(@as(@Int(.unsigned, @bitSizeOf(T)), 1) << (@bitSizeOf(T) - 1)), 0x70, 0x7F };
    var xs: [n]T = undefined;
    for (&xs) |*x| x.* = switch (r.uintLessThan(u8, 3)) {
        0 => edges[r.uintLessThan(usize, edges.len)],
        1 => @truncate(r.int(T) >> @intCast(r.uintLessThan(usize, @bitSizeOf(T)))),
        else => r.int(T),
    };
    return xs;
}

noinline fn saturating(comptime T: type, comptime n: usize, r: std.Random) void {
    const xs = lanes(T, n, r);
    const ys = lanes(T, n, r);
    const a = load(T, n, &xs);
    const b = load(T, n, &ys);
    const add: [n]T = rig.vecAddSat(a, b);
    const sub: [n]T = rig.vecSubSat(a, b);
    for (xs, ys, add, sub, 0..) |x, y, s, d, i| {
        const wide_s = @as(i128, x) + @as(i128, y);
        const wide_d = @as(i128, x) - @as(i128, y);
        const want_s: T = @intCast(std.math.clamp(wide_s, std.math.minInt(T), std.math.maxInt(T)));
        const want_d: T = @intCast(std.math.clamp(wide_d, std.math.minInt(T), std.math.maxInt(T)));
        if (x +| y != want_s) fail("scalar +| {s}: {d} +| {d} gave {d}, want {d}", .{ @typeName(T), x, y, x +| y, want_s });
        if (x -| y != want_d) fail("scalar -| {s}: {d} -| {d} gave {d}, want {d}", .{ @typeName(T), x, y, x -| y, want_d });
        if (s != want_s) fail("+| {s} x{d} lane {d}: {d} +| {d} gave {d}, want {d}", .{ @typeName(T), n, i, x, y, s, want_s });
        if (d != want_d) fail("-| {s} x{d} lane {d}: {d} -| {d} gave {d}, want {d}", .{ @typeName(T), n, i, x, y, d, want_d });
    }
}

noinline fn shifts(comptime T: type, comptime n: usize, r: std.Random) void {
    for (0..@bitSizeOf(T)) |c| {
        const k: std.math.Log2Int(T) = @intCast(c);
        var xs = lanes(T, n, r);
        const v = load(T, n, &xs);
        const wrapped: [n]T = rig.vecShlWrap(v, amount(c));
        const right: [n]T = rig.vecShr(v, amount(c));
        for (xs, wrapped, right, 0..) |x, w, s, i| {
            if (w != x << k) fail("<<% {s} x{d} by {d} lane {d}: {d} gave {d}, want {d}", .{ @typeName(T), n, c, i, x, w, x << k });
            if (s != x >> k) fail(">> {s} x{d} by {d} lane {d}: {d} gave {d}, want {d}", .{ @typeName(T), n, c, i, x, s, x >> k });
        }
        // Lanes that keep their bits: `<<` gives what `<<%` does.
        for (&xs) |*x| x.* = x.* >> k;
        if (@typeInfo(T).int.signedness == .signed and c > 0) for (&xs) |*x| {
            x.* = x.* >> 1;
        };
        const kept: [n]T = rig.vecShl(load(T, n, &xs), amount(c));
        for (xs, kept, 0..) |x, s, i| if (s != x << k) fail("<< {s} x{d} by {d} lane {d}: {d} gave {d}, want {d}", .{ @typeName(T), n, c, i, x, s, x << k });
    }
}

noinline fn lookups(comptime m: usize, comptime n: usize, r: std.Random) void {
    var t: [m]u8 = undefined;
    r.bytes(&t);
    const edges = [_]u8{ 0, 15, 16, 31, 32, 47, 48, 63, 64, 0x6F, 0x70, 0x7F, 0x80, 0x8F, 0x90, 0xEF, 0xF0, 0xFF };
    var is: [n]u8 = undefined;
    for (&is) |*x| x.* = switch (r.uintLessThan(u8, 3)) {
        0 => edges[r.uintLessThan(usize, edges.len)],
        1 => r.uintLessThan(u8, m),
        else => r.int(u8),
    };
    const got: [n]u8 = rig.lookup(load(u8, m, &t), load(u8, n, &is));
    for (is, got, 0..) |j, g, i| {
        const want: u8 = if (j < m) t[j] else 0;
        if (g != want) fail("lookup table {d} x{d} lane {d}: index {d} gave {d}, want {d}", .{ m, n, i, j, g, want });
    }
}

noinline fn lags(comptime T: type, comptime n: usize, r: std.Random) void {
    const ps = lanes(T, n, r);
    const cs = lanes(T, n, r);
    const p = load(T, n, &ps);
    const c = load(T, n, &cs);
    inline for (1..n) |k| {
        const got: [n]T = rig.lag(k, c, p);
        for (got, 0..) |g, i| {
            const want = if (i >= k) cs[i - k] else ps[n - k + i];
            if (g != want) fail("lag[{d}] {s} x{d} lane {d}: gave {d}, want {d}", .{ k, @typeName(T), n, i, g, want });
        }
    }
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(init.gpa);
    _ = args.next();
    const first = args.next();
    if (first != null and std.mem.eql(u8, first.?, "shl")) {
        const ty = args.next().?;
        const count = try std.fmt.parseInt(usize, args.next().?, 10);
        inline for (types) |T| inline for (lane_counts) |n| {
            if (std.mem.eql(u8, ty, @typeName(T)) and count == n) {
                var xs: [n]T = @splat(1);
                xs[n - 1] = @bitCast(@as(@Int(.unsigned, @bitSizeOf(T)), 1) << (@bitSizeOf(T) - 2));
                const v: [n]T = rig.vecShl(load(T, n, &xs), amount(2));
                std.debug.print("no panic: {any}\n", .{v});
                std.process.exit(4);
            }
        };
        return error.UnknownCell;
    }
    const seeds = if (first) |s| try std.fmt.parseInt(usize, s, 10) else 20;
    var cells: usize = 0;
    for (0..seeds) |seed| {
        var prng = std.Random.DefaultPrng.init(seed);
        const r = prng.random();
        inline for (types) |T| inline for (lane_counts) |n| {
            saturating(T, n, r);
            shifts(T, n, r);
            cells += 2;
            // `lag` is one shuffle whatever the lanes hold: every amount
            // on half the lane types keeps the build small.
            if (comptime T == u8 or T == u16 or T == i32 or T == u64) {
                lags(T, n, r);
                cells += 1;
            }
        };
        inline for (.{ 16, 32, 64 }) |m| inline for (lane_counts) |n| {
            for (0..8) |_| lookups(m, n, r);
            cells += 1;
        };
    }
    std.debug.print("{d} cells, {d} bad lanes\n", .{ cells, bad });
    if (bad > 0) std.process.exit(1);
}
