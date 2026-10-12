// Semantics checks, run on every target that can execute here:
//   zig test src/check.zig                              (aarch64-macos)
//   zig test -target wasm32-wasi[-mcpu=...+simd128] --test-cmd wasmtime --test-cmd-bin
// Each test also runs at comptime where Zig allows it.
const std = @import("std");
const builtin = @import("builtin");
const expect = std.testing.expect;
const expectEqual = std.testing.expectEqual;
const V16 = @Vector(16, u8);
const V32 = @Vector(32, u8);
const V64 = @Vector(64, u8);

fn rt(comptime T: type, x: T) T {
    var y: T = x;
    _ = &y;
    return @as(*volatile T, &y).*;
}

fn sample(comptime n: usize) [n]u8 {
    var b: [n]u8 = undefined;
    for (&b, 0..) |*x, i| x.* = if (i % 7 == 3 or i == n - 1) '"' else @intCast('a' + i % 26);
    return b;
}
fn scalarMask(comptime n: usize, b: [n]u8) @Int(.unsigned, n) {
    var m: @Int(.unsigned, n) = 0;
    for (b, 0..) |x, i| {
        if (x == '"') m |= @as(@Int(.unsigned, n), 1) << @intCast(i);
    }
    return m;
}

test "bitmask: lane i is bit i, at runtime and comptime, N = 16/32/64" {
    inline for (.{ 16, 32, 64 }) |n| {
        const b = comptime sample(n);
        const want = scalarMask(n, b);
        const v: @Vector(n, u8) = rt([n]u8, b);
        const got: @Int(.unsigned, n) = @bitCast(v == @as(@Vector(n, u8), @splat('"')));
        try expectEqual(want, got);
        const ct = comptime blk: {
            const cv: @Vector(n, u8) = b;
            break :blk @as(@Int(.unsigned, n), @bitCast(cv == @as(@Vector(n, u8), @splat('"'))));
        };
        try expectEqual(want, ct);
    }
}

test "nibble mask (shrn idiom) and first index" {
    const b = sample(16);
    const v: V16 = rt([16]u8, b);
    const m = @select(u8, v == @as(V16, @splat('"')), @as(V16, @splat(0xFF)), @as(V16, @splat(0)));
    const w: @Vector(8, u16) = @bitCast(m);
    const n: @Vector(8, u8) = @truncate(w >> @splat(4));
    const nib: u64 = @bitCast(n);
    const bm = scalarMask(16, b);
    // every nibble is 0xF or 0x0 and mirrors the bitmask
    for (0..16) |i| try expectEqual(@as(u64, if ((bm >> @intCast(i)) & 1 == 1) 0xF else 0), (nib >> @intCast(4 * i)) & 0xF);
    try expectEqual(@as(u32, @ctz(bm)), @as(u32, @ctz(nib)) >> 2);
}

test "addp idiom gives the linear 64-bit mask" {
    const weights: V16 = .{ 1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128 };
    const even = comptime blk: {
        var m: [16]i32 = undefined;
        for (0..8) |i| {
            m[i] = 2 * i;
            m[8 + i] = ~@as(i32, 2 * i);
        }
        break :blk m;
    };
    const odd = comptime blk: {
        var m: [16]i32 = undefined;
        for (0..8) |i| {
            m[i] = 2 * i + 1;
            m[8 + i] = ~@as(i32, 2 * i + 1);
        }
        break :blk m;
    };
    const S = struct {
        fn addp(a: V16, c: V16) V16 {
            return @shuffle(u8, a, c, even) +% @shuffle(u8, a, c, odd);
        }
    };
    const b = sample(64);
    var q: [4]V16 = undefined;
    inline for (0..4) |k| {
        const v: V16 = rt([16]u8, b[k * 16 ..][0..16].*);
        q[k] = @select(u8, v == @as(V16, @splat('"')), @as(V16, @splat(0xFF)), @as(V16, @splat(0))) & weights;
    }
    const s = S.addp(S.addp(q[0], q[1]), S.addp(q[2], q[3]));
    const r: @Vector(2, u64) = @bitCast(S.addp(s, s));
    try expectEqual(scalarMask(64, b), r[0]);
}

test "prefix xor: shift ladder" {
    const x: u64 = rt(u64, 0x0000_1000_0100_0010);
    var m = x;
    inline for (.{ 1, 2, 4, 8, 16, 32 }) |k| m ^= m << k;
    var want: u64 = 0;
    var acc: u1 = 0;
    for (0..64) |i| {
        acc ^= @truncate(x >> @intCast(i));
        want |= @as(u64, acc) << @intCast(i);
    }
    try expectEqual(want, m);
}

test "lookup fallback (array) agrees with a 16-entry table" {
    const t: [16]u8 = .{ 16, 0, 0, 0, 0, 0, 0, 0, 0, 8, 10, 4, 1, 12, 0, 0 };
    const idx: V16 = rt(V16, .{ 0, 1, 9, 10, 11, 12, 13, 15, 3, 0, 9, 9, 12, 2, 1, 0 });
    var r: V16 = undefined;
    inline for (0..16) |k| r[k] = t[idx[k]];
    inline for (0..16) |k| try expectEqual(t[idx[k]], r[k]);
}

test "reductions and min/max/saturating" {
    const a: V16 = rt(V16, .{ 200, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 255 });
    try expectEqual(@as(u8, 1), @reduce(.Min, a));
    try expectEqual(@as(u8, 255), @reduce(.Max, a));
    try expectEqual(@as(u8, @truncate(200 + 105 + 255)), @reduce(.Add, a)); // wraps
    const s = a +| @as(V16, @splat(100));
    try expectEqual(@as(u8, 255), s[0]);
    try expectEqual(@as(u8, 101), s[1]);
    try expectEqual(@as(u8, 0), (a -| @as(V16, @splat(250)))[1]);
}

test "firstTrue / countTrues from std.simd" {
    const v: V16 = rt([16]u8, sample(16));
    const p = v == @as(V16, @splat('"'));
    try expectEqual(@as(?u4, 3), std.simd.firstTrue(p));
    try expectEqual(@as(u5, @popCount(scalarMask(16, sample(16)))), std.simd.countTrues(p));
}

test "sizes and alignment of vector types (memory layout)" {
    // Printed, not asserted, so every target reports its layout.
    inline for (.{ @Vector(16, u8), @Vector(32, u8), @Vector(64, u8), @Vector(3, u8), @Vector(3, u32), @Vector(16, bool), @Vector(64, bool), @Vector(16, u3), @Vector(4, u24) }) |T| {
        std.debug.print("{s}: size {d} align {d} bits {d}\n", .{ @typeName(T), @sizeOf(T), @alignOf(T), @bitSizeOf(T) });
    }
}

test "vector <-> array coercion keeps lane order; bool vector bitcast is per lane" {
    const arr: [4]u32 = .{ 1, 2, 3, 4 };
    const v: @Vector(4, u32) = arr;
    try expectEqual(@as(u32, 3), v[2]);
    const bv: @Vector(4, bool) = .{ true, false, false, true };
    try expectEqual(@as(u4, 0b1001), @as(u4, @bitCast(bv)));
    const ba: [4]bool = bv; // coercion, byte per lane
    try expect(ba[3]);
}
