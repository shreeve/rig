// NEON-specific bitmask idioms, through LLVM intrinsics (aarch64 only),
// and portable spellings that try to reach the same instructions.
const V16 = @Vector(16, u8);
const Q = '"';
extern fn @"llvm.aarch64.neon.addp.v16i8"(V16, V16) V16;
extern fn @"llvm.aarch64.neon.uaddv.i32.v8i8"(@Vector(8, u8)) i32;

inline fn cmp(p: *const [16]u8) V16 {
    const v: V16 = p.*;
    return @select(u8, v == @as(V16, @splat(Q)), @as(V16, @splat(0xFF)), @as(V16, @splat(0)));
}
const weights: V16 = .{ 1, 2, 4, 8, 16, 32, 64, 128, 1, 2, 4, 8, 16, 32, 64, 128 };

// simdjson to_bitmask: 4 cmeq, 4 and, 4 addp, fmov.  Linear 64-bit mask.
export fn neon_bm64_addp(p: *const [64]u8) u64 {
    const addp = @"llvm.aarch64.neon.addp.v16i8";
    const a = cmp(p[0..16]) & weights;
    const b = cmp(p[16..32]) & weights;
    const c = cmp(p[32..48]) & weights;
    const d = cmp(p[48..64]) & weights;
    const s = addp(addp(a, b), addp(c, d));
    const r: @Vector(2, u64) = @bitCast(addp(s, s));
    return r[0];
}
// 16 -> u16 with addp: and, addp, addp, addp, fmov (simdjson 16-byte form).
export fn neon_bm16_addp(p: *const [16]u8) u16 {
    const addp = @"llvm.aarch64.neon.addp.v16i8";
    const a = cmp(p) & weights;
    const x1 = addp(a, a);
    const x2 = addp(x1, x1);
    const s = addp(x2, x2); // lanes 0,1 hold the lo,hi mask bytes
    const r: @Vector(8, u16) = @bitCast(s);
    return r[0];
}

// Kutenin's SRI chain: 64 bytes -> u64 with bit (4*j + i) for byte 16*i + j
// (an interleaved, not linear, mask). Portable spelling of vsriq_n_u8:
// sri(a, b, n) = (a & ~(0xFF >> n)) | (b >> n).
inline fn sri(a: V16, b: V16, comptime n: u3) V16 {
    const keep: V16 = @splat(~@as(u8, 0xFF >> n));
    return (a & keep) | (b >> @splat(n));
}
export fn neon_bm64_sri(p: *const [64]u8) u64 {
    const c0 = cmp(p[0..16]);
    const c1 = cmp(p[16..32]);
    const c2 = cmp(p[32..48]);
    const c3 = cmp(p[48..64]);
    const t0 = sri(c1, c0, 1);
    const t1 = sri(c3, c2, 1);
    const t2 = sri(t1, t0, 2);
    const t3 = sri(t2, t2, 4);
    const w: @Vector(8, u16) = @bitCast(t3);
    const n: @Vector(8, u8) = @truncate(w >> @splat(4));
    return @bitCast(n);
}

// Portable addp spelling with a non-disjoint operand so LLVM cannot turn
// the add into an or (it did for bitmask.zig's bm64_addp).
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
export fn portable_addp(a: *const V16, b: *const V16, o: *V16) void {
    o.* = @shuffle(u8, a.*, b.*, even16) +% @shuffle(u8, a.*, b.*, odd16);
}
