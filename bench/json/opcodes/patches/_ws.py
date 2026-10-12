"""Whitespace skip variants: an inlined entry that returns at once on a
byte above space, and an out-of-line run that classifies 16 bytes at a
time. `cls` is the Zig expression giving the whitespace mask of `v`."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import add_helpers, replace_fn

ENTRY = r'''
pub inline fn skip_space(__rig_in_s: []const u8, __rig_in_at: i64) i64 {
    const s = rig.rt(__rig_in_s);
    const at = rig.rt(__rig_in_at);
    if (at < 0) {
        return at;
    }
    if ((at < rig.len(s.len)) and (rig.at(s, at) > SPACE)) {
        return at;
    }
    return skip_space_run(s, at);
}
'''

SCALAR_RUN = r'''
@NOINLINE@fn skip_space_run(s: []const u8, at: i64) i64 {
    var i: i64 = at;
    while (true) {
        if (!(i < rig.len(s.len))) break;
        {
            const c: u8 = rig.at(s, i);
            if (c > SPACE) {
                return i;
            }
            if (((c == SPACE) and ((i + 8) <= rig.len(s.len))) and (rig.readInt(u64, s, i, .little) == SPACES)) {
                i += 8;
            } else if ((((c == SPACE) or (c == LF)) or (c == CR)) or (c == TAB)) {
                i += 1;
            } else {
                return i;
            }
        }
    }
    return i;
}
'''

VECTOR_RUN = r'''
inline fn wsMask(v: @Vector(16, u8)) @Vector(16, bool) {
    return @CLS@;
}
@NOINLINE@fn skip_space_run(s: []const u8, at: i64) i64 {
    var i: i64 = at;
    const n: i64 = rig.len(s.len);
    while (i + 16 <= n) : (i += 16) {
        if (rig.maskFirst(!wsMask(rig.simdRead(@Vector(16, u8), s, i, rig.Endian.little)))) |k| {
            return i + k;
        }
    }
    if ((i < n) and (n >= 16)) {
        const m: u64 = rig.maskBits(!wsMask(rig.simdRead(@Vector(16, u8), s, n - 16, rig.Endian.little))) >> @intCast((i + 16) - n);
        if (m != 0) return i + @as(i64, @ctz(m));
        return n;
    }
    while (i < n) : (i += 1) {
        const c = rig.at(s, i);
        if (!((c == SPACE) or (c == LF) or (c == CR) or (c == TAB))) return i;
    }
    return i;
}
'''

CMP = "(v == @as(@Vector(16, u8), @splat(SPACE))) | (v == @as(@Vector(16, u8), @splat(LF))) | (v == @as(@Vector(16, u8), @splat(CR))) | (v == @as(@Vector(16, u8), @splat(TAB)))"
# One lookup by the low nibble: the table holds the one whitespace byte
# with that low nibble, or 0, so a lane is whitespace when it equals it.
TBL = "opLookupNib(@as(@Vector(16, u8), .{ 0x20, 0, 0, 0, 0, 0, 0, 0, 0, 0x09, 0x0A, 0, 0, 0x0D, 0, 0 }), v & @as(@Vector(16, u8), @splat(15))) == v"


def make(run, cls=None, inline=False):
    def patch(s):
        s = add_helpers(s)
        body = run if cls is None else run.replace("@CLS@", cls)
        body = body.replace("@NOINLINE@", "inline " if inline else "noinline ")
        return replace_fn(s, "skip_space", ENTRY + body)
    return patch

# The position advances by a constant, decided by a branch on the whole
# block (`m.all()`): the next read never waits for a vector-to-register
# crossing unless the branch mispredicts.
ALL_LOOP = r'''
inline fn wsMask(v: @Vector(16, u8)) @Vector(16, bool) {
    return @CLS@;
}
pub inline fn skip_space(__rig_in_s: []const u8, __rig_in_at: i64) i64 {
    const s = rig.rt(__rig_in_s);
    const at = rig.rt(__rig_in_at);
    if (at < 0) {
        return at;
    }
    var i: i64 = at;
    while (true) {
        if (!(i < rig.len(s.len))) break;
        {
            const c: u8 = rig.at(s, i);
            if (c > SPACE) {
                return i;
            }
            if ((c == SPACE) and ((i + 16) <= rig.len(s.len)) and rig.maskAll(wsMask(rig.simdRead(@Vector(16, u8), s, i, rig.Endian.little)))) {
                i += 16;
            } else if (((c == SPACE) and ((i + 8) <= rig.len(s.len))) and (rig.readInt(u64, s, i, .little) == SPACES)) {
                i += 8;
            } else if ((((c == SPACE) or (c == LF)) or (c == CR)) or (c == TAB)) {
                i += 1;
            } else {
                return i;
            }
        }
    }
    return i;
}
'''


def make_all(cls):
    def patch(s):
        s = add_helpers(s)
        return replace_fn(s, "skip_space", ALL_LOOP.replace("@CLS@", cls))
    return patch
