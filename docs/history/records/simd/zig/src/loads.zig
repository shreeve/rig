// 1. Loads and stores. Each function returns the lane-sum of the loaded
// bytes (wrapping) so the load cannot be optimized away and the asm stays
// small; the interesting part is the load and any bounds check before it.
const V16 = @Vector(16, u8);
const V32 = @Vector(32, u8);
const V64 = @Vector(64, u8);

// Slice + runtime offset: bytes[i..][0..N].*
export fn load16_slice(p: [*]const u8, len: usize, i: usize) u8 {
    const bytes = p[0..len];
    const v: V16 = bytes[i..][0..16].*;
    return @reduce(.Add, v);
}
export fn load32_slice(p: [*]const u8, len: usize, i: usize) u8 {
    const bytes = p[0..len];
    const v: V32 = bytes[i..][0..32].*;
    return @reduce(.Add, v);
}
export fn load64_slice(p: [*]const u8, len: usize, i: usize) u8 {
    const bytes = p[0..len];
    const v: V64 = bytes[i..][0..64].*;
    return @reduce(.Add, v);
}

// From a pointer to an array: no bounds check possible or needed.
export fn load16_arrptr(p: *const [16]u8) u8 {
    const v: V16 = p.*;
    return @reduce(.Add, v);
}
export fn load64_arrptr(p: *const [64]u8) u8 {
    const v: V64 = p.*;
    return @reduce(.Add, v);
}

// From a pointer to a vector (natural alignment = 16/32/64): aligned load.
export fn load16_vecptr(p: *const V16) u8 {
    return @reduce(.Add, p.*);
}
// Pointer to an under-aligned vector.
export fn load16_vecptr_align1(p: *align(1) const V16) u8 {
    return @reduce(.Add, p.*);
}

// Store: vector -> array element range.
export fn store16_slice(p: [*]u8, len: usize, i: usize, x: u8) void {
    const bytes = p[0..len];
    const v: V16 = @splat(x);
    bytes[i..][0..16].* = v;
}

// A block loop: four 16-byte loads per 64-byte step, guarded by the loop
// condition. Does ReleaseSafe keep a check per load, one per block, or none?
export fn block_loop_4x16(p: [*]const u8, len: usize) u32 {
    const bytes = p[0..len];
    var i: usize = 0;
    var acc: u32 = 0;
    const q: V16 = @splat('"');
    while (i + 64 <= bytes.len) : (i += 64) {
        const a: V16 = bytes[i..][0..16].*;
        const b: V16 = bytes[i + 16 ..][0..16].*;
        const c: V16 = bytes[i + 32 ..][0..16].*;
        const d: V16 = bytes[i + 48 ..][0..16].*;
        const ma: u16 = @bitCast(a == q);
        const mb: u16 = @bitCast(b == q);
        const mc: u16 = @bitCast(c == q);
        const md: u16 = @bitCast(d == q);
        acc +%= @as(u32, @popCount(ma)) + @popCount(mb) + @popCount(mc) + @popCount(md);
    }
    return acc;
}

// Same, slicing the 64-byte block once and splitting the array.
export fn block_loop_1x64(p: [*]const u8, len: usize) u32 {
    const bytes = p[0..len];
    var i: usize = 0;
    var acc: u32 = 0;
    const q: V16 = @splat('"');
    while (i + 64 <= bytes.len) : (i += 64) {
        const blk: *const [64]u8 = bytes[i..][0..64];
        const a: V16 = blk[0..16].*;
        const b: V16 = blk[16..32].*;
        const c: V16 = blk[32..48].*;
        const d: V16 = blk[48..64].*;
        const ma: u16 = @bitCast(a == q);
        const mb: u16 = @bitCast(b == q);
        const mc: u16 = @bitCast(c == q);
        const md: u16 = @bitCast(d == q);
        acc +%= @as(u32, @popCount(ma)) + @popCount(mb) + @popCount(mc) + @popCount(md);
    }
    return acc;
}

// Loop where the guard does not imply the bound (i < len only).
export fn block_loop_badguard(p: [*]const u8, len: usize) u32 {
    const bytes = p[0..len];
    var i: usize = 0;
    var acc: u32 = 0;
    const q: V16 = @splat('"');
    while (i < bytes.len) : (i += 16) {
        const a: V16 = bytes[i..][0..16].*;
        const ma: u16 = @bitCast(a == q);
        acc +%= @popCount(ma);
    }
    return acc;
}
