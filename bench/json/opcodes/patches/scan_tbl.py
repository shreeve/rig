"""String scan: the 16-lane classifier as simdjson's two nibble lookups
(tbl / pshufb) and an AND, instead of two compares, a signed compare and
two ORs. Width and SWAR stage unchanged (TIER = 16, 16 lanes)."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import add_helpers, replace_fn

SPECIAL = r'''
pub inline fn special(__rig_in_v: @Vector(16, u8)) @Vector(16, bool) {
    const v = rig.rt(__rig_in_v);
    // High nibble: 0, 1 and 8-F are control or non-ASCII (bit 1); 2 may be
    // a quote (bit 2), 5 a backslash (bit 4). Low nibble: every one may be
    // bit 1; 2 also bit 2, C also bit 4.
    const hi: OpV = .{ 1, 1, 2, 0, 0, 4, 0, 0, 1, 1, 1, 1, 1, 1, 1, 1 };
    const lo: OpV = .{ 1, 1, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 5, 1, 1, 1 };
    const c = opLookupNib(hi, v >> @splat(4)) & opLookupNib(lo, v & @as(OpV, @splat(15)));
    return c != @as(OpV, @splat(0));
}
'''


def patch(s):
    return replace_fn(add_helpers(s), "special", SPECIAL)
