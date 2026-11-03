// 4. Runtime-index byte lookup (pshufb / tbl / i8x16.swizzle).
// Zig has no builtin for it: @shuffle needs a comptime mask and a vector
// cannot be indexed by a runtime value. These are the candidate spellings.
const std = @import("std");
const builtin = @import("builtin");
const V = @Vector(16, u8);

// (a) Array indexing in a lane loop. LLVM may pattern-match the
//     build_vector(extract(t, extract(i, k))) into a variable permute.
export fn lut_array(t: *const [16]u8, i: *const [16]u8, o: *[16]u8) void {
    const iv: V = i.*;
    const idx = iv & @as(V, @splat(15)); // in range: no bounds check needed
    var r: [16]u8 = undefined;
    inline for (0..16) |k| r[k] = t[idx[k]];
    o.* = r;
}
// (a') Same but on a vector table coerced to an array first.
export fn lut_vecarray(t: *const V, i: *const V, o: *V) void {
    const ta: [16]u8 = t.*;
    const idx = i.* & @as(V, @splat(15));
    var r: V = undefined;
    inline for (0..16) |k| r[k] = ta[idx[k]];
    o.* = r;
}
// (a'') Without the & 15: the index is a u8, so ReleaseSafe bounds-checks it.
export fn lut_array_unmasked(t: *const [16]u8, i: *const [16]u8, o: *[16]u8) void {
    const iv: V = i.*;
    var r: [16]u8 = undefined;
    inline for (0..16) |k| r[k] = t[iv[k]];
    o.* = r;
}
// (a''') runtime for-loop (not inline)
export fn lut_loop(t: *const [16]u8, i: *const [16]u8, o: *[16]u8) void {
    for (o, i) |*d, s| d.* = t[s & 15];
}

// (b) @select cascade over a comptime table (classification constant).
const table: [16]u8 = .{ 16, 0, 0, 0, 0, 0, 0, 0, 0, 8, 10, 4, 1, 12, 0, 0 };
export fn lut_select(i: *const V, o: *V) void {
    const idx = i.* & @as(V, @splat(15));
    var r: V = @splat(0);
    inline for (0..16) |k| {
        if (table[k] != 0)
            r = @select(u8, idx == @as(V, @splat(k)), @as(V, @splat(table[k])), r);
    }
    o.* = r;
}

// (c) LLVM intrinsic through `extern fn @"llvm.*"` (LLVM backend only).
const has_ssse3 = builtin.cpu.arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3);
const has_neon = builtin.cpu.arch == .aarch64;
const has_wasm_simd = builtin.cpu.arch.isWasm() and std.Target.wasm.featureSetHas(builtin.cpu.features, .simd128);
extern fn @"llvm.aarch64.neon.tbl1"(V, V) V;
extern fn @"llvm.x86.ssse3.pshuf.b.128"(V, V) V;
extern fn @"llvm.wasm.swizzle"(V, V) V;
inline fn lut16(t: V, idx: V) V {
    if (comptime has_neon) return @"llvm.aarch64.neon.tbl1"(t, idx);
    if (comptime has_ssse3) return @"llvm.x86.ssse3.pshuf.b.128"(t, idx);
    if (comptime has_wasm_simd) return @"llvm.wasm.swizzle"(t, idx);
    const ta: [16]u8 = t;
    var r: V = undefined;
    inline for (0..16) |k| r[k] = if (idx[k] < 16) ta[idx[k]] else 0;
    return r;
}
export fn lut_intrinsic(t: *const V, i: *const V, o: *V) void {
    o.* = lut16(t.*, i.* & @as(V, @splat(15)));
}

// (d) The simdjson classifier: two nibble lookups and an AND.
const lo_tbl: V = .{ 16, 0, 0, 0, 0, 0, 0, 0, 0, 8, 12, 1, 2, 9, 0, 0 };
const hi_tbl: V = .{ 8, 0, 18, 4, 0, 1, 0, 1, 0, 0, 0, 3, 2, 1, 0, 0 };
export fn classify_intrinsic(i: *const V, o: *V) void {
    const x = i.*;
    o.* = lut16(lo_tbl, x & @as(V, @splat(15))) & lut16(hi_tbl, x >> @splat(4));
}
export fn classify_array(i: *const V, o: *V) void {
    const x = i.*;
    const lo = x & @as(V, @splat(15));
    const hi = x >> @splat(4);
    const lt: [16]u8 = lo_tbl;
    const ht: [16]u8 = hi_tbl;
    var r: V = undefined;
    inline for (0..16) |k| r[k] = lt[lo[k]] & ht[hi[k]];
    o.* = r;
}
