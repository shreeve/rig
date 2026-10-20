// 5. Reductions, 6. select / splat / iota / firstTrue / prefix-xor / clmul.
const std = @import("std");
const builtin = @import("builtin");
const V = @Vector(16, u8);
const V4 = @Vector(4, u32);

export fn red_or_bool(a: *const V, b: *const V) bool { return @reduce(.Or, a.* == b.*); }
export fn red_and_bool(a: *const V, b: *const V) bool { return @reduce(.And, a.* == b.*); }
export fn red_or_u8(a: *const V) u8 { return @reduce(.Or, a.*); }
export fn red_and_u8(a: *const V) u8 { return @reduce(.And, a.*); }
export fn red_xor_u8(a: *const V) u8 { return @reduce(.Xor, a.*); }
export fn red_add_u8(a: *const V) u8 { return @reduce(.Add, a.*); } // wrapping
export fn red_add_u32(a: *const V4) u32 { return @reduce(.Add, a.*); }
export fn red_min_u8(a: *const V) u8 { return @reduce(.Min, a.*); }
export fn red_max_u8(a: *const V) u8 { return @reduce(.Max, a.*); }
export fn red_min_i8(a: *const @Vector(16, i8)) i8 { return @reduce(.Min, a.*); }
// Widening sum (what a byte counter wants): add u8 lanes into a u16/u32.
export fn red_add_widen(a: *const V) u32 {
    const w: @Vector(16, u16) = a.*;
    return @reduce(.Add, w);
}

export fn sel(a: *const V, b: *const V, c: *const V, o: *V) void {
    o.* = @select(u8, a.* < b.*, b.*, c.*);
}
export fn splat_rt(x: u8, o: *V) void { o.* = @splat(x); }
export fn iota_add(a: *const V, o: *V) void { o.* = a.* +% std.simd.iota(u8, 16); }

// firstTrue: std.simd (reduce Or + select + reduce Min) vs ctz of bitmask.
export fn first_std(a: *const V) i32 {
    const r = std.simd.firstTrue(a.* == @as(V, @splat('"')));
    return if (r) |x| x else -1;
}
export fn first_ctz(a: *const V) u32 {
    const m: u16 = @bitCast(a.* == @as(V, @splat('"')));
    return @ctz(m); // 16 = none
}
export fn count_std(a: *const V) u32 {
    return std.simd.countTrues(a.* == @as(V, @splat('"')));
}
export fn count_pop(a: *const V) u32 {
    const m: u16 = @bitCast(a.* == @as(V, @splat('"')));
    return @popCount(m);
}

// Prefix XOR of a u64 (simdjson's in-string mask).
export fn prefix_xor_shift(x: u64) u64 {
    var m = x;
    m ^= m << 1;
    m ^= m << 2;
    m ^= m << 4;
    m ^= m << 8;
    m ^= m << 16;
    m ^= m << 32;
    return m;
}
// std.simd.prefixScan on a bool vector (Xor), then bitcast.
export fn prefix_xor_scan(x: u64) u64 {
    const b: @Vector(64, bool) = @bitCast(x);
    return @bitCast(std.simd.prefixScan(.Xor, 1, b));
}
// Carry-less multiply by all-ones = prefix XOR. Through LLVM intrinsics.
extern fn @"llvm.aarch64.neon.pmull64"(u64, u64) @Vector(16, u8);
extern fn @"llvm.x86.pclmulqdq"(@Vector(2, i64), @Vector(2, i64), i8) @Vector(2, i64);
const has_pclmul = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .pclmul);
const has_aes = builtin.cpu.arch == .aarch64 and std.Target.aarch64.featureSetHas(builtin.cpu.features, .aes);
export fn prefix_xor_clmul(x: u64) u64 {
    if (comptime has_aes) {
        const r: @Vector(2, u64) = @bitCast(@"llvm.aarch64.neon.pmull64"(x, ~@as(u64, 0)));
        return r[0];
    }
    if (comptime has_pclmul) {
        const a: @Vector(2, i64) = .{ @bitCast(x), 0 };
        const b: @Vector(2, i64) = .{ -1, 0 };
        const r = @"llvm.x86.pclmulqdq"(a, b, 0);
        return @bitCast(r[0]);
    }
    return prefix_xor_shift(x);
}
