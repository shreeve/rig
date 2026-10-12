#!/usr/bin/env python3
"""nibble.py OUTDIR MODE: rewrite the emitted json.zig's "mask bits, test, ctz"
exits to the NEON nibble mask (shrn #4 + one fmov; ctz >> 2).

MODE for the 64-lane loop:
  nibble  four nibble masks (one per 16-byte piece), OR-tested in the GPR
  umaxv   umaxv of the OR of the four pieces; on a hit, nibble-mask piece by piece
16-lane sites (blocks and the overlapping tail) always take the nibble mask."""
import os, re, sys

d, mode = sys.argv[1], sys.argv[2]
p = d + "/json.zig"
s = open(p).read()

HELPERS = r'''
const NibV = @Vector(16, u8);
/// The lanes of a 16-lane mask as bytes, 0xFF or 0.
inline fn nibBytes(m: @Vector(16, bool)) NibV {
    return @select(u8, m, @as(NibV, @splat(0xFF)), @as(NibV, @splat(0)));
}
/// NEON nibble mask of 16 mask bytes: shrn #4, then one fmov. Lane k owns bits 4k..4k+3.
inline fn nibOf(b: NibV) u64 {
    return @as(u64, @bitCast(@as(@Vector(8, u8), @truncate(@as(@Vector(8, u16), @bitCast(b)) >> @splat(4)))));
}
inline fn nib16(m: @Vector(16, bool)) u64 {
    return nibOf(nibBytes(m));
}
extern fn @"llvm.aarch64.neon.umaxv.i32.v16i8"(NibV) i32;
/// The first true lane of a 32-lane mask, or null: two nibble masks, one test.
inline fn first32(m: @Vector(32, bool)) ?i64 {
    const bytes: [2]NibV = @bitCast(@select(u8, m, @as(@Vector(32, u8), @splat(0xFF)), @as(@Vector(32, u8), @splat(0))));
    const n0 = nibOf(bytes[0]);
    const n1 = nibOf(bytes[1]);
    if (n0 | n1 == 0) return null;
    if (n0 != 0) return @as(i64, @ctz(n0) >> 2);
    return 16 + @as(i64, @ctz(n1) >> 2);
}
/// The first true lane of a 64-lane mask, or null.
inline fn first64(m: @Vector(64, bool)) ?i64 {
    const w = @select(u8, m, @as(@Vector(64, u8), @splat(0xFF)), @as(@Vector(64, u8), @splat(0)));
    const bytes: [4]NibV = @bitCast(w);
    if (comptime MODE64 == .nibble) {
        const n0 = nibOf(bytes[0]);
        const n1 = nibOf(bytes[1]);
        const n2 = nibOf(bytes[2]);
        const n3 = nibOf(bytes[3]);
        if ((n0 | n1) | (n2 | n3) == 0) return null;
        if (n0 != 0) return @as(i64, @ctz(n0) >> 2);
        if (n1 != 0) return 16 + @as(i64, @ctz(n1) >> 2);
        if (n2 != 0) return 32 + @as(i64, @ctz(n2) >> 2);
        return 48 + @as(i64, @ctz(n3) >> 2);
    } else {
        // The OR of the four pieces by halving shuffles: an OR of `bytes[k]`
        // makes LLVM move the pieces through general registers.
        const o32 = @shuffle(u8, w, undefined, iota(32, 0)) | @shuffle(u8, w, undefined, iota(32, 32));
        const o16: NibV = @shuffle(u8, o32, undefined, iota(16, 0)) | @shuffle(u8, o32, undefined, iota(16, 16));
        if (@"llvm.aarch64.neon.umaxv.i32.v16i8"(o16) == 0) return null;
        inline for (0..4) |k| {
            const n = nibOf(bytes[k]);
            if (n != 0) return @as(i64, 16 * k) + @as(i64, @ctz(n) >> 2);
        }
        unreachable;
    }
}
fn iota(comptime n: usize, comptime from: i32) @Vector(n, i32) {
    var a: [n]i32 = undefined;
    for (&a, 0..) |*x, j| x.* = from + @as(i32, @intCast(j));
    return a;
}
const MODE64: enum { nibble, umaxv } = .@MODE@;
'''.replace("@MODE@", mode)

anchor = 'const rig = @import("rig/runtime.zig");\n'
assert s.count(anchor) == 1
s = s.replace(anchor, anchor + HELPERS)

n_total = 0
# 16-lane block: const m: u64 = rig.maskBits(X16);\n if (m != 0) { return i + @as(i64, @ctz(@as(u64, m))); }
blk = re.compile(r'const m: u64 = rig\.maskBits\((.*?)\);\n(\s*)if \(m != 0\) \{\n(\s*)return i \+ @as\(i64, @ctz\(@as\(u64, m\)\)\);')
def blk_sub(mo):
    x = mo.group(1)
    for w in ("64", "32"):
        if "@Vector(%s" % w in x:
            return 'if (first%s(%s)) |k| {\n%sreturn i + k;' % (w, x, mo.group(3))
    return 'const m: u64 = nib16(%s);\n%sif (m != 0) {\n%sreturn i + @as(i64, @ctz(m) >> 2);' % (x, mo.group(2), mo.group(3))
s, n = blk.subn(blk_sub, s); n_total += n; n_blk = n
# Overlapping tail: @as(u64, rig.maskBits(X)) >> @intCast(E);\n if (m != 0) { return i + @as(i64, @ctz(@as(u64, m))); }
tail = re.compile(r'const m: u64 = @as\(u64, rig\.maskBits\((.*)\)\) >> @intCast\((rig\.addProven\(i, 16\) - rig\.len\(s\.len\))\);\n(\s*)if \(m != 0\) \{\n(\s*)return i \+ @as\(i64, @ctz\(@as\(u64, m\)\)\);')
s, n = tail.subn(lambda mo: 'const m: u64 = nib16(%s) >> @intCast(4 * (%s));\n%sif (m != 0) {\n%sreturn i + @as(i64, @ctz(m) >> 2);' % (mo.group(1), mo.group(2), mo.group(3), mo.group(4)), s)
n_total += n
assert "rig.maskBits(" not in s, "a maskBits site was not rewritten"
if os.environ.get("NIB_BREAK"):  # mutation check: a wrong tail shift must fail the tests
    s, k = re.subn(r">> @intCast\(4 \* \(", ">> @intCast(3 * (", s); assert k > 0
open(p, "w").write(s)
print("rewrote %d sites (%d blocks, %d tails)" % (n_total, n_blk, n))
