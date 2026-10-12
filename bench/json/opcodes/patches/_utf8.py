"""UTF-8 a vector at a time (Keiser and Lemire, "Validating UTF-8 in less
than one instruction per byte", 2021): three nibble lookups (tbl /
pshufb), the bytes 1, 2 and 3 places before each lane from the block
before (ext / palignr), and two saturating subtracts (uqsub / psubusb).

Once `plain` meets a byte of 0x80 or more, the run goes 16 bytes a step,
the previous block carried, to the string's first quote, backslash or
control byte; the lanes from that byte on are cleared (ASCII), so a
sequence cut short there is an error. Any error, and the input's last 15
bytes, go back to the scalar loop from the run's start, which reports the
exact offset."""
import os, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import add_helpers, replace_fn

KL = r'''
const KL_TOO_SHORT: u8 = 1 << 0;
const KL_TOO_LONG: u8 = 1 << 1;
const KL_OVERLONG_3: u8 = 1 << 2;
const KL_TOO_LARGE: u8 = 1 << 3;
const KL_SURROGATE: u8 = 1 << 4;
const KL_OVERLONG_2: u8 = 1 << 5;
const KL_TOO_LARGE_1000: u8 = 1 << 6;
const KL_OVERLONG_4: u8 = 1 << 6;
const KL_TWO_CONTS: u8 = 1 << 7;
const KL_CARRY: u8 = KL_TOO_SHORT | KL_TOO_LONG | KL_TWO_CONTS;
const KL_1H: OpV = .{
    KL_TOO_LONG, KL_TOO_LONG, KL_TOO_LONG, KL_TOO_LONG, KL_TOO_LONG, KL_TOO_LONG, KL_TOO_LONG, KL_TOO_LONG,
    KL_TWO_CONTS, KL_TWO_CONTS, KL_TWO_CONTS, KL_TWO_CONTS,
    KL_TOO_SHORT | KL_OVERLONG_2,
    KL_TOO_SHORT,
    KL_TOO_SHORT | KL_OVERLONG_3 | KL_SURROGATE,
    KL_TOO_SHORT | KL_TOO_LARGE | KL_TOO_LARGE_1000 | KL_OVERLONG_4,
};
const KL_1L: OpV = .{
    KL_CARRY | KL_OVERLONG_3 | KL_OVERLONG_2 | KL_OVERLONG_4,
    KL_CARRY | KL_OVERLONG_2,
    KL_CARRY,
    KL_CARRY,
    KL_CARRY | KL_TOO_LARGE,
    KL_CARRY | KL_TOO_LARGE | KL_TOO_LARGE_1000,
    KL_CARRY | KL_TOO_LARGE | KL_TOO_LARGE_1000,
    KL_CARRY | KL_TOO_LARGE | KL_TOO_LARGE_1000,
    KL_CARRY | KL_TOO_LARGE | KL_TOO_LARGE_1000,
    KL_CARRY | KL_TOO_LARGE | KL_TOO_LARGE_1000,
    KL_CARRY | KL_TOO_LARGE | KL_TOO_LARGE_1000,
    KL_CARRY | KL_TOO_LARGE | KL_TOO_LARGE_1000,
    KL_CARRY | KL_TOO_LARGE | KL_TOO_LARGE_1000,
    KL_CARRY | KL_TOO_LARGE | KL_TOO_LARGE_1000 | KL_SURROGATE,
    KL_CARRY | KL_TOO_LARGE | KL_TOO_LARGE_1000,
    KL_CARRY | KL_TOO_LARGE | KL_TOO_LARGE_1000,
};
const KL_2H: OpV = .{
    KL_TOO_SHORT, KL_TOO_SHORT, KL_TOO_SHORT, KL_TOO_SHORT, KL_TOO_SHORT, KL_TOO_SHORT, KL_TOO_SHORT, KL_TOO_SHORT,
    KL_TOO_LONG | KL_OVERLONG_2 | KL_TWO_CONTS | KL_OVERLONG_3 | KL_TOO_LARGE_1000 | KL_OVERLONG_4,
    KL_TOO_LONG | KL_OVERLONG_2 | KL_TWO_CONTS | KL_OVERLONG_3 | KL_TOO_LARGE,
    KL_TOO_LONG | KL_OVERLONG_2 | KL_TWO_CONTS | KL_SURROGATE | KL_TOO_LARGE,
    KL_TOO_LONG | KL_OVERLONG_2 | KL_TWO_CONTS | KL_SURROGATE | KL_TOO_LARGE,
    KL_TOO_SHORT, KL_TOO_SHORT, KL_TOO_SHORT, KL_TOO_SHORT,
};
/// The error bits of block `v`, whose bytes before it are `prev`'s.
inline fn klCheck(prev: OpV, v: OpV) OpV {
    const p1 = opPrev(prev, v, 1);
    const p2 = opPrev(prev, v, 2);
    const p3 = opPrev(prev, v, 3);
    const lo: OpV = @splat(0x0F);
    const sc = opLookupNib(KL_1H, p1 >> @splat(4)) & opLookupNib(KL_1L, p1 & lo) & opLookupNib(KL_2H, v >> @splat(4));
    const third = p2 -| @as(OpV, @splat(0xE0 - 0x80));
    const fourth = p3 -| @as(OpV, @splat(0xF0 - 0x80));
    return ((third | fourth) & @as(OpV, @splat(0x80))) ^ sc;
}
/// From `at`, a byte of 0x80 or more that starts a sequence: the index of
/// the first quote, backslash or control byte, every byte before it
/// checked; or -1 for the scalar loop to take over from `at`.
@INLINE@fn utf8Run(s: []const u8, at: i64) i64 {
    var i: i64 = at;
    const n: i64 = rig.len(s.len);
    var prev: OpV = @splat(0);
    var err: OpV = @splat(0);
    while (i + 16 <= n) : (i += 16) {
        var v = rig.simdRead(OpV, s, i, rig.Endian.little);
        const sp = (v == @as(OpV, @splat(QUOTE))) | (v == @as(OpV, @splat(BACKSLASH))) | (v < @as(OpV, @splat(SPACE)));
        if (rig.maskFirst(sp)) |k| {
            const iota: OpV = .{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15 };
            v = @select(u8, iota < @as(OpV, @splat(@as(u8, @intCast(k)))), v, @as(OpV, @splat(0)));
            err |= klCheck(prev, v);
            if (rig.maskAny(err != @as(OpV, @splat(0)))) return -1;
            return i + k;
        }
        err |= klCheck(prev, v);
        prev = v;
    }
    return -1;
}
'''

PLAIN = r'''
    pub inline fn plain(__rig_in_self: *Doc, __rig_in_src: []const u8, __rig_in_at: i64) i64 {
        const self = rig.rt(__rig_in_self);
        const src = rig.rt(__rig_in_src);
        const at = rig.rt(__rig_in_at);
        const n: i64 = rig.len(src.len);
        var i: i64 = at;
        while (true) {
            i = skip_plain_ascii(src, i);
            if ((i >= n) or (rig.at(src, i) < 0x80)) {
                return i;
            }
            const r = utf8Run(src, i);
            if (r >= 0) {
                return r;
            }
            while (true) {
                if (!((i < n) and (rig.at(src, i) >= 0x80))) break;
                const j: i64 = rig.rt(utf8_end3(src, i));
                if (j < 0) {
                    return rig.rt(self.fail(.utf8, i));
                }
                i = j;
            }
        }
        return n;
    }
'''


def make(inline=False):
    def patch(s):
        s = add_helpers(s)
        s += KL.replace("@INLINE@", "inline " if inline else "noinline ")
        return replace_fn(s, "plain", PLAIN)
    return patch
