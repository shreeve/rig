"""Digits 16 at a time with SIMD, in place of SWAR's 8: one 16-byte read,
`d = v -% '0'`, the first lane with `d >= 10` (`m.first()`), the k digits
moved to the top lanes by a lookup with indexes `iota + k - 16` (tbl /
pshufb give 0 for an index of 16 or more: leading zeros), then the value
by pairwise multiply-adds: pmaddubsw, pmaddwd, packusdw, pmaddwd on x86;
widening multiplies and pairwise adds on NEON (portable Zig). The SWAR
loop still takes the input's last 15 bytes."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import add_helpers, fn_text, replace_fn

SIXTEEN = r'''
const op_sse41 = op_builtin.cpu.arch == .x86_64 and op_builtin.zig_backend == .stage2_llvm and
    std.Target.x86.featureSetHas(op_builtin.cpu.features, .sse4_1);
extern fn @"llvm.x86.ssse3.pmadd.ub.sw.128"(@Vector(16, u8), @Vector(16, i8)) @Vector(8, i16);
extern fn @"llvm.x86.sse2.pmadd.wd"(@Vector(8, i16), @Vector(8, i16)) @Vector(4, i32);
extern fn @"llvm.x86.sse41.packusdw"(@Vector(4, i32), @Vector(4, i32)) @Vector(8, u16);
const POW10_16: [17]u64 = .{ 1, 10, 100, 1000, 10000, 100000, 1000000, 10000000, 100000000, 1000000000, 10000000000, 100000000000, 1000000000000, 10000000000000, 100000000000000, 1000000000000000, 10000000000000000 };
fn opIdx(comptime n: usize, comptime step: usize, comptime from: usize) [n]i32 {
    var a: [n]i32 = undefined;
    for (&a, 0..) |*x, j| x.* = @intCast(from + j * step);
    return a;
}
/// The value of 16 digits, one a lane, the first in lane 0.
inline fn sixteenDigits(d: OpV) u64 {
    if (comptime op_sse41 and @MADD@) {
        const p = @"llvm.x86.ssse3.pmadd.ub.sw.128"(d, .{ 10, 1, 10, 1, 10, 1, 10, 1, 10, 1, 10, 1, 10, 1, 10, 1 });
        const q = @"llvm.x86.sse2.pmadd.wd"(p, .{ 100, 1, 100, 1, 100, 1, 100, 1 });
        const r = @"llvm.x86.sse41.packusdw"(q, q);
        const e = @"llvm.x86.sse2.pmadd.wd"(@bitCast(r), .{ 10000, 1, 10000, 1, 10000, 1, 10000, 1 });
        return @as(u64, @as(u32, @bitCast(e[0]))) *% 100000000 +% @as(u64, @as(u32, @bitCast(e[1])));
    }
    const ev: @Vector(8, u16) = @shuffle(u8, d, undefined, opIdx(8, 2, 0));
    const od: @Vector(8, u16) = @shuffle(u8, d, undefined, opIdx(8, 2, 1));
    const p = ev *% @as(@Vector(8, u16), @splat(10)) +% od;
    const pe: @Vector(4, u32) = @shuffle(u16, p, undefined, opIdx(4, 2, 0));
    const po: @Vector(4, u32) = @shuffle(u16, p, undefined, opIdx(4, 2, 1));
    const q = pe *% @as(@Vector(4, u32), @splat(100)) +% po;
    const qe: @Vector(2, u32) = @shuffle(u32, q, undefined, opIdx(2, 2, 0));
    const qo: @Vector(2, u32) = @shuffle(u32, q, undefined, opIdx(2, 2, 1));
    const r = qe *% @as(@Vector(2, u32), @splat(10000)) +% qo;
    return @as(u64, r[0]) *% 100000000 +% @as(u64, r[1]);
}
'''

LOOP = r'''
    while (true) {
        if (!((i + 16) <= rig.len(s.len))) break;
        const d = rig.simdRead(OpV, s, i, rig.Endian.little) -% @as(OpV, @splat(0x30));
        if (rig.maskFirst(@NONDIGIT@)) |k| {
            if (k > 0) {
                const iota: OpV = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
                const top = opLookup(d, iota +% @as(OpV, @splat(@as(u8, @truncate(@as(u64, @bitCast(k -% 16)))))));
                m.* = m.* *% POW10_16[@intCast(k)] +% sixteenDigits(top);
            }
            return i + k;
        }
        m.* = m.* *% 10000000000000000 +% sixteenDigits(d);
        i += 16;
    }
'''

CMP = "d >= @as(OpV, @splat(10))"
SAT = "(d -| @as(OpV, @splat(9))) != @as(OpV, @splat(0))"


def make(nondigit=CMP, madd=True):
    def patch(s):
        s = add_helpers(s)
        body = fn_text(s, "take_digits")
        anchor = "    var i: i64 = at;\n"
        assert body.count(anchor) == 1
        body = body.replace(anchor, anchor + LOOP.replace("@NONDIGIT@", nondigit).strip("\n") + "\n")
        s = replace_fn(s, "take_digits", body)
        return s + SIXTEEN.replace("@MADD@", "true" if madd else "false")
    return patch
