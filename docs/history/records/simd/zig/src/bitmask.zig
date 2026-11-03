// 3. Compare + bitmask. Every function takes a block pointer and returns
// the mask of bytes equal to '"'. The portable form is
// @bitCast(@Vector(N,bool)) -> uN; the others are NEON idioms written in
// plain portable Zig, to see whether LLVM reaches shrn / addp from them.
const std = @import("std");
const V16 = @Vector(16, u8);
const V32 = @Vector(32, u8);
const V64 = @Vector(64, u8);
const Q = '"';

// ---- Portable: one compare, @bitCast the bool vector ---------------------
export fn bm16(p: *const [16]u8) u16 {
    const v: V16 = p.*;
    return @bitCast(v == @as(V16, @splat(Q)));
}
export fn bm32(p: *const [32]u8) u32 {
    const v: V32 = p.*;
    return @bitCast(v == @as(V32, @splat(Q)));
}
export fn bm64(p: *const [64]u8) u64 {
    const v: V64 = p.*;
    return @bitCast(v == @as(V64, @splat(Q)));
}

// ---- Portable: four 16-lane bitcasts combined into a u64 ----------------
export fn bm64_4x16(p: *const [64]u8) u64 {
    var m: u64 = 0;
    inline for (0..4) |k| {
        const v: V16 = p[k * 16 ..][0..16].*;
        const b: u16 = @bitCast(v == @as(V16, @splat(Q)));
        m |= @as(u64, b) << (k * 16);
    }
    return m;
}

// ---- NEON idiom 1: shrn narrowing to a 64-bit nibble mask ---------------
// Compare -> 0x00/0xFF bytes -> view as 8 x u16 -> >>4 -> truncate to 8 x u8
// = vshrn_n_u16(..., 4). Each input byte becomes 4 bits of the u64.
inline fn byteMask16(v: V16) V16 {
    return @select(u8, v == @as(V16, @splat(Q)), @as(V16, @splat(0xFF)), @as(V16, @splat(0)));
}
inline fn nibbles(m: V16) u64 {
    const w: @Vector(8, u16) = @bitCast(m);
    const n: @Vector(8, u8) = @truncate(w >> @splat(4));
    return @bitCast(n);
}
export fn nib16(p: *const [16]u8) u64 {
    return nibbles(byteMask16(p.*));
}
// First match index from the nibble mask (the typical parser use).
export fn nib16_first(p: *const [16]u8) u32 {
    const n = nibbles(byteMask16(p.*));
    return @ctz(n) >> 2; // 16 if none
}
// First match from the portable bitcast, for comparison.
export fn bm16_first(p: *const [16]u8) u32 {
    const v: V16 = p.*;
    const b: u16 = @bitCast(v == @as(V16, @splat(Q)));
    return @ctz(b);
}
// Any-match from @reduce (umaxv on NEON, pmovmskb+test on x86).
export fn any16(p: *const [16]u8) bool {
    const v: V16 = p.*;
    return @reduce(.Or, v == @as(V16, @splat(Q)));
}

// ---- NEON idiom 2: AND with bit weights, then pairwise adds (addp) ------
// simdjson's to_bitmask for 64 bytes: 4 x AND, 3 x ADDP, extract u64.
const weights: V16 = .{ 1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128 };
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
// addp(a, b): pairwise add of the concatenation a ++ b.
inline fn addp(a: V16, b: V16) V16 {
    const e = @shuffle(u8, a, b, even16);
    const o = @shuffle(u8, a, b, odd16);
    return e +% o;
}
export fn bm64_addp(p: *const [64]u8) u64 {
    const a = byteMask16(p[0..16].*) & weights;
    const b = byteMask16(p[16..32].*) & weights;
    const c = byteMask16(p[32..48].*) & weights;
    const d = byteMask16(p[48..64].*) & weights;
    const s1 = addp(a, b);
    const s2 = addp(c, d);
    const s3 = addp(s1, s2);
    const s4 = addp(s3, s3);
    const r: @Vector(2, u64) = @bitCast(s4);
    return r[0];
}
// 16 lanes -> u16 by AND weights + addv on each half.
export fn bm16_addv(p: *const [16]u8) u16 {
    const m = byteMask16(p.*) & weights;
    const lo = @shuffle(u8, m, undefined, [8]i32{ 0, 1, 2, 3, 4, 5, 6, 7 });
    const hi = @shuffle(u8, m, undefined, [8]i32{ 8, 9, 10, 11, 12, 13, 14, 15 });
    return @as(u16, @reduce(.Add, lo)) | (@as(u16, @reduce(.Add, hi)) << 8);
}

// ---- 64-byte nibble form: four shrn -> four u64 nibble masks -------------
// (a "1 bit per 4" representation of 64 bytes = 256 bits); cheaper to make,
// but consumers must shift by 2 for indices.
export fn nib64_any(p: *const [64]u8, out: *[4]u64) void {
    inline for (0..4) |k| out[k] = nibbles(byteMask16(p[k * 16 ..][0..16].*));
}
