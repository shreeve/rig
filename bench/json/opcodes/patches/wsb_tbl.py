"""For src:wsbits*: the 64-byte block's whitespace classified by the
nibble lookup (tbl / pshufb, then a compare), 16 bytes at a time, in
place of four compares and three ORs per 16 bytes."""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import add_helpers

FN = r'''
inline fn wsNot64(v: @Vector(64, u8)) @Vector(64, bool) {
    const t: OpV = .{ 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0x09, 0x0A, 0, 0, 0x0D, 0, 0 };
    const p: [4]OpV = @bitCast(v);
    var r: [4]OpV = undefined;
    inline for (0..4) |k| r[k] = opLookupNib(t, p[k] & @as(OpV, @splat(15)));
    return @as(@Vector(64, u8), @bitCast(r)) != v;
}
'''


def patch(s):
    s = add_helpers(s)
    pat = re.compile(r"rig\.maskBits\(\(!\(\(\(\(v == rig\.rt\(@as\(@Vector\(64, u8\), @splat\(SPACE\)\)\)\) \| \(v == rig\.rt\(@as\(@Vector\(64, u8\), @splat\(LF\)\)\)\)\) \| \(v == rig\.rt\(@as\(@Vector\(64, u8\), @splat\(CR\)\)\)\)\) \| \(v == rig\.rt\(@as\(@Vector\(64, u8\), @splat\(TAB\)\)\)\)\)\)\)")
    s, n = pat.subn("rig.maskBits(wsNot64(v))", s)
    assert n == 1, n
    return s + FN
