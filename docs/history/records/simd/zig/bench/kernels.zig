// Compare+bitmask kernels: SIMD at N = 16/32/64, NEON idioms, and SWAR.
// Job A (mask_*): write the linear u64 bitmask of '"' for every 64-byte block.
// Job B (scan_*): visit every '"' position (count + sum of positions).
const std = @import("std");
const builtin = @import("builtin");
const V16 = @Vector(16, u8);
const V32 = @Vector(32, u8);
const V64 = @Vector(64, u8);
const Q: u8 = '"';
const is_a64 = builtin.cpu.arch == .aarch64;

// ---------------------------------------------------------------- SIMD
inline fn bm(comptime n: usize, p: *const [n]u8) @Int(.unsigned, n) {
    const v: @Vector(n, u8) = p.*;
    return @bitCast(v == @as(@Vector(n, u8), @splat(Q)));
}
pub export fn mask_simd16(p: [*]const u8, nblk: usize, out: [*]u64) void {
    for (0..nblk) |b| {
        const blk: *const [64]u8 = p[b * 64 ..][0..64];
        var m: u64 = 0;
        inline for (0..4) |k| m |= @as(u64, bm(16, blk[k * 16 ..][0..16])) << (k * 16);
        out[b] = m;
    }
}
pub export fn mask_simd32(p: [*]const u8, nblk: usize, out: [*]u64) void {
    for (0..nblk) |b| {
        const blk: *const [64]u8 = p[b * 64 ..][0..64];
        out[b] = @as(u64, bm(32, blk[0..32])) | (@as(u64, bm(32, blk[32..64])) << 32);
    }
}
pub export fn mask_simd64(p: [*]const u8, nblk: usize, out: [*]u64) void {
    for (0..nblk) |b| out[b] = bm(64, p[b * 64 ..][0..64]);
}

// NEON: simdjson's AND-weights + addp chain (intrinsic), aarch64 only.
extern fn @"llvm.aarch64.neon.addp.v16i8"(V16, V16) V16;
const weights: V16 = .{ 1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128 };
inline fn cmpw(p: *const [16]u8) V16 {
    const v: V16 = p.*;
    return @select(u8, v == @as(V16, @splat(Q)), weights, @as(V16, @splat(0)));
}
inline fn addp64(blk: *const [64]u8) u64 {
    const addp = @"llvm.aarch64.neon.addp.v16i8";
    const s = addp(addp(cmpw(blk[0..16]), cmpw(blk[16..32])), addp(cmpw(blk[32..48]), cmpw(blk[48..64])));
    const r: @Vector(2, u64) = @bitCast(addp(s, s));
    return r[0];
}
pub export fn mask_neon_addp(p: [*]const u8, nblk: usize, out: [*]u64) void {
    if (!is_a64) unreachable;
    for (0..nblk) |b| out[b] = addp64(p[b * 64 ..][0..64]);
}
// Portable spelling of the same chain (LLVM turns it into uzp1/uzp2/orr).
const even16 = blk: {
    var m: [16]i32 = undefined;
    for (0..8) |i| {
        m[i] = 2 * i;
        m[8 + i] = ~@as(i32, 2 * i);
    }
    break :blk m;
};
const odd16 = blk: {
    var m: [16]i32 = undefined;
    for (0..8) |i| {
        m[i] = 2 * i + 1;
        m[8 + i] = ~@as(i32, 2 * i + 1);
    }
    break :blk m;
};
inline fn paddp(a: V16, b: V16) V16 {
    return @shuffle(u8, a, b, even16) +% @shuffle(u8, a, b, odd16);
}
pub export fn mask_portable_addp(p: [*]const u8, nblk: usize, out: [*]u64) void {
    for (0..nblk) |b| {
        const blk: *const [64]u8 = p[b * 64 ..][0..64];
        const s = paddp(paddp(cmpw(blk[0..16]), cmpw(blk[16..32])), paddp(cmpw(blk[32..48]), cmpw(blk[48..64])));
        const r: @Vector(2, u64) = @bitCast(paddp(s, s));
        out[b] = r[0];
    }
}

// NEON shrn nibble mask: 64 bytes -> 4 u64 (4 bits per byte). Not the
// linear mask; written to a 4x-sized output.
inline fn nib(p: *const [16]u8) u64 {
    const v: V16 = p.*;
    const m = @select(u8, v == @as(V16, @splat(Q)), @as(V16, @splat(0xFF)), @as(V16, @splat(0)));
    const w: @Vector(8, u16) = @bitCast(m);
    const n: @Vector(8, u8) = @truncate(w >> @splat(4));
    return @bitCast(n);
}
pub export fn mask_nibble(p: [*]const u8, nblk: usize, out: [*]u64) void {
    for (0..nblk) |b| {
        const blk: *const [64]u8 = p[b * 64 ..][0..64];
        inline for (0..4) |k| out[4 * b + k] = nib(blk[k * 16 ..][0..16]);
    }
}

// ---------------------------------------------------------------- SWAR
// Exact zero-byte detector: 0x80 in each byte of w equal to Q.
inline fn swarHi(comptime T: type, w: T) T {
    const lo7: T = @as(T, ~@as(T, 0)) / 0xFF * 0x7F;
    const x = w ^ (@as(T, ~@as(T, 0)) / 0xFF * Q);
    const t = (x & lo7) +% lo7;
    return ~(t | x | lo7);
}
// @bitCast([16]u8 -> u128) and std.mem.readInt(u128) load byte by byte in
// Zig 0.17; a pointer cast gives one 16-byte load.
inline fn load128(p: *const [16]u8) u128 {
    return @as(*align(1) const u128, @ptrCast(p)).*;
}
// 0x80-per-byte -> 8-bit mask (bit k = byte k) by multiply.
inline fn compress8(h: u64) u8 {
    return @truncate(((h >> 7) *% 0x0102040810204080) >> 56);
}
pub export fn mask_swar64(p: [*]const u8, nblk: usize, out: [*]u64) void {
    for (0..nblk) |b| {
        const blk: *const [64]u8 = p[b * 64 ..][0..64];
        var m: u64 = 0;
        inline for (0..8) |k| {
            const w = std.mem.readInt(u64, blk[k * 8 ..][0..8], .little);
            m |= @as(u64, compress8(swarHi(u64, w))) << (k * 8);
        }
        out[b] = m;
    }
}
pub export fn mask_swar128(p: [*]const u8, nblk: usize, out: [*]u64) void {
    for (0..nblk) |b| {
        const blk: *const [64]u8 = p[b * 64 ..][0..64];
        var m: u64 = 0;
        inline for (0..4) |k| {
            const w = load128(blk[k * 16 ..][0..16]);
            const h = swarHi(u128, w);
            const lo: u64 = compress8(@truncate(h));
            const hi: u64 = compress8(@truncate(h >> 64));
            m |= (lo | (hi << 8)) << (k * 16);
        }
        out[b] = m;
    }
}
pub export fn mask_scalar(p: [*]const u8, nblk: usize, out: [*]u64) void {
    for (0..nblk) |b| {
        var m: u64 = 0;
        for (0..64) |i| m |= @as(u64, @intFromBool(p[b * 64 + i] == Q)) << @intCast(i);
        out[b] = m;
    }
}

// ---------------------------------------------------------------- Job B
pub const Acc = extern struct { count: u64, sum: u64 };
inline fn visit(acc: *Acc, pos: usize) void {
    acc.count += 1;
    acc.sum +%= pos;
}
pub export fn scan_simd16(p: [*]const u8, len: usize, acc: *Acc) void {
    var i: usize = 0;
    while (i + 16 <= len) : (i += 16) {
        var m = bm(16, p[i..][0..16]);
        while (m != 0) : (m &= m - 1) visit(acc, i + @ctz(m));
    }
}
pub export fn scan_simd16_any(p: [*]const u8, len: usize, acc: *Acc) void {
    var i: usize = 0;
    while (i + 16 <= len) : (i += 16) {
        const v: V16 = p[i..][0..16].*;
        const c = v == @as(V16, @splat(Q));
        if (!@reduce(.Or, c)) continue;
        var m: u16 = @bitCast(c);
        while (m != 0) : (m &= m - 1) visit(acc, i + @ctz(m));
    }
}
pub export fn scan_nibble16(p: [*]const u8, len: usize, acc: *Acc) void {
    var i: usize = 0;
    while (i + 16 <= len) : (i += 16) {
        var n = nib(p[i..][0..16]);
        while (n != 0) {
            const t = @ctz(n);
            visit(acc, i + (t >> 2));
            n &= ~(@as(u64, 0xF) << @intCast(t));
        }
    }
}
pub export fn scan_simd32(p: [*]const u8, len: usize, acc: *Acc) void {
    var i: usize = 0;
    while (i + 32 <= len) : (i += 32) {
        var m = bm(32, p[i..][0..32]);
        while (m != 0) : (m &= m - 1) visit(acc, i + @ctz(m));
    }
}
pub export fn scan_simd64(p: [*]const u8, len: usize, acc: *Acc) void {
    var i: usize = 0;
    while (i + 64 <= len) : (i += 64) {
        var m = bm(64, p[i..][0..64]);
        while (m != 0) : (m &= m - 1) visit(acc, i + @ctz(m));
    }
}
pub export fn scan_neon_addp(p: [*]const u8, len: usize, acc: *Acc) void {
    if (!is_a64) unreachable;
    var i: usize = 0;
    while (i + 64 <= len) : (i += 64) {
        var m = addp64(p[i..][0..64]);
        while (m != 0) : (m &= m - 1) visit(acc, i + @ctz(m));
    }
}
pub export fn scan_swar64(p: [*]const u8, len: usize, acc: *Acc) void {
    var i: usize = 0;
    while (i + 8 <= len) : (i += 8) {
        var h = swarHi(u64, std.mem.readInt(u64, p[i..][0..8], .little));
        while (h != 0) : (h &= h - 1) visit(acc, i + (@ctz(h) >> 3));
    }
}
pub export fn scan_swar128(p: [*]const u8, len: usize, acc: *Acc) void {
    var i: usize = 0;
    while (i + 16 <= len) : (i += 16) {
        var h = swarHi(u128, load128(p[i..][0..16]));
        while (h != 0) : (h &= h - 1) visit(acc, i + (@ctz(h) >> 3));
    }
}
pub export fn scan_std(p: [*]const u8, len: usize, acc: *Acc) void {
    const s = p[0..len];
    var i: usize = 0;
    while (std.mem.findScalarPos(u8, s, i, Q)) |j| {
        visit(acc, j);
        i = j + 1;
    }
}
pub export fn scan_scalar(p: [*]const u8, len: usize, acc: *Acc) void {
    for (0..len) |i| if (p[i] == Q) visit(acc, i);
}
