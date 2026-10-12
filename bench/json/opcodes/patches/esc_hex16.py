"""Escapes: two `\\uXXXX` back to back (escaped CJK text) decoded from one
16-byte read: the `\\u` pattern by compares, the eight hex digits checked
and valued by two nibble lookups (tbl / pshufb), gathered by a shuffle
and paired into four bytes by a multiply-add (shift-or); one crossing
gives both code points. The input position advances by 12, a constant,
so no read waits on the crossing. Anything else takes the scalar path."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import add_helpers, fn_text, replace_fn

HEX = r'''
/// The code points of the two `\uXXXX` escapes at `at` (the first in the
/// high half), or null unless both are there with four hex digits each.
inline fn hexPair(s: []const u8, at: i64) ?u32 {
    const v = rig.simdRead(OpV, s, at, rig.Endian.little);
    const lo = v & @as(OpV, @splat(15));
    const hi = v >> @splat(4);
    // A hex digit: high nibble 3 with low 0-9 (bit 1), or 4 or 6 with low 1-6 (bit 2).
    const vh: OpV = .{ 0, 0, 0, 1, 2, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const vl: OpV = .{ 1, 3, 3, 3, 3, 3, 3, 1, 1, 1, 0, 0, 0, 0, 0, 0 };
    const is_hex = (opLookupNib(vh, hi) & opLookupNib(vl, lo)) != @as(OpV, @splat(0));
    // Its value: the low nibble, plus 9 for a letter.
    const add: OpV = .{ 0, 0, 0, 0, 9, 0, 9, 0, 0, 0, 0, 0, 0, 0, 0, 0 };
    const val = lo +% opLookupNib(add, hi);
    const pat: OpV = .{ '\\', 'u', 0, 0, 0, 0, '\\', 'u', 0, 0, 0, 0, 0, 0, 0, 0 };
    const hex_lane = @Vector(16, bool){ false, false, true, true, true, true, false, false, true, true, true, true, false, false, false, false };
    const pat_lane = @Vector(16, bool){ true, true, false, false, false, false, true, true, false, false, false, false, false, false, false, false };
    const ok = @select(bool, hex_lane, is_hex, @select(bool, pat_lane, v == pat, @as(@Vector(16, bool), @splat(true))));
    if (!rig.maskAll(ok)) return null;
    const g: @Vector(8, u8) = @shuffle(u8, val, undefined, [8]i32{ 2, 3, 4, 5, 8, 9, 10, 11 });
    const hi4: @Vector(4, u8) = @shuffle(u8, g, undefined, [4]i32{ 0, 2, 4, 6 });
    const lo4: @Vector(4, u8) = @shuffle(u8, g, undefined, [4]i32{ 1, 3, 5, 7 });
    const b: [4]u8 = (hi4 << @splat(4)) | lo4;
    return std.mem.readInt(u32, &b, .big);
}
'''

OLD = "        var c: i64 = rig.rt(self.hex4(src, at + 2));\n"
NEW = '''        if ((at + 16) <= rig.len(src.len)) {
            if (hexPair(src, at)) |cd| {
                const c2: i64 = cd >> 16;
                const d2: i64 = cd & 0xFFFF;
                if ((c2 >= 0x800) and ((c2 < 0xD800) or (c2 > 0xDFFF)) and (d2 >= 0x800) and ((d2 < 0xD800) or (d2 > 0xDFFF))) {
                    rig.rt(push_utf8_two3(&self.text, c2, d2));
                    return at + 12;
                }
            }
        }
'''


def patch(s):
    s = add_helpers(s)
    body = fn_text(s, "unicode")
    assert body.count(OLD) == 1
    return replace_fn(s, "unicode", body.replace(OLD, NEW + OLD)) + HEX
