const std = @import("std");
const builtin = @import("builtin");
const V = @Vector(16, u8);
/// `table.lookup(idx)`: lane i is table[idx[i]], or 0 when idx[i] >= 16.
pub fn lookup16(comptime n: usize, table: V, idx: @Vector(n, u8)) @Vector(n, u8) {
    const arch = builtin.cpu.arch;
    if (comptime n % 16 == 0) {
        const tbl = comptime if (arch == .aarch64 and std.Target.aarch64.featureSetHas(builtin.cpu.features, .neon))
            "llvm.aarch64.neon.tbl1.v16i8"
        else if (arch.isWasm() and std.Target.wasm.featureSetHas(builtin.cpu.features, .simd128))
            "llvm.wasm.swizzle"
        else if (arch == .x86_64 and std.Target.x86.featureSetHas(builtin.cpu.features, .ssse3))
            "llvm.x86.ssse3.pshuf.b.128"
        else
            "";
        if (tbl.len != 0) {
            const f = @extern(*const fn (V, V) callconv(.c) V, .{ .name = tbl });
            const ia: [n]u8 = idx;
            var out: [n]u8 = undefined;
            inline for (0..n / 16) |k| {
                var piece: V = ia[k * 16 ..][0..16].*;
                // pshufb reads only the low 4 bits unless the top bit is set.
                if (comptime arch == .x86_64) piece |= @select(u8, piece >= @as(V, @splat(16)), @as(V, @splat(0x80)), @as(V, @splat(0)));
                out[k * 16 ..][0..16].* = f(table, piece);
            }
            return out;
        }
    }
    const t: [16]u8 = table;
    const ia: [n]u8 = idx;
    var out: [n]u8 = undefined;
    for (ia, 0..) |j, i| out[i] = if (j < 16) t[j] else 0;
    return out;
}
pub fn main() void {
    const lo: V = .{ 16, 0, 0, 0, 0, 0, 0, 0, 0, 8, 10, 4, 1, 12, 0, 0 };
    const hi: V = .{ 8, 0, 17, 2, 0, 4, 0, 4, 0, 0, 0, 0, 0, 0, 0, 0 };
    const text = "{\"a\": [1, 2],\t\"b\":\r\n {}}   xyz  0123456789abcdefghijklmnopqrstuv";
    const v: @Vector(64, u8) = text[0..64].*;
    const k = lookup16(64, lo, v & @as(@Vector(64, u8), @splat(15))) & lookup16(64, hi, v >> @splat(4));
    const ws: u64 = @bitCast((k & @as(@Vector(64, u8), @splat(0x18))) != @as(@Vector(64, u8), @splat(0)));
    const op: u64 = @bitCast((k & @as(@Vector(64, u8), @splat(0x07))) != @as(@Vector(64, u8), @splat(0)));
    std.debug.print("{x} {x}\n", .{ ws, op });
}
