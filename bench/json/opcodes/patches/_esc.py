"""Escaped strings: the text between escapes copied as it is scanned, a
block at a time (`String.pushKeep`: store a whole block, keep its first k
bytes), instead of a scan (`plain`) and then a
`String.add` of the run. A run that meets a byte of 0x80 or more, or the
input's last block, goes the old way from there."""
import os, re, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from _common import add_helpers, fn_text, replace_fn

COPY16 = r'''
/// Appends the plain ASCII bytes from `at` on to `out`, 16 at a time;
/// returns the index of the first quote, backslash, control byte or byte
/// of 0x80 or more, or where fewer than 16 bytes are left.
inline fn copyPlain(out: *rig.String, s: []const u8, at: i64) i64 {
    var i: i64 = at;
    const n: i64 = rig.lenOf(s);
    while (i + 16 <= n) : (i += 16) {
        const v = rig.simdRead(@Vector(16, u8), s, i, rig.Endian.little);
        // A whole block stored, its first k bytes kept (`String.pushKeep`).
        if (rig.maskFirst(special(v))) |k| {
            out.pushKeep(@Vector(16, u8), v, k, rig.Endian.little);
            return i + k;
        }
        out.pushKeep(@Vector(16, u8), v, 16, rig.Endian.little);
    }
    return i;
}
'''

COPY8 = r'''
/// Appends the plain ASCII bytes from `at` on to `out`, 8 at a time
/// (SWAR); returns the index of the first quote, backslash, control byte
/// or byte of 0x80 or more, or where fewer than 8 bytes are left.
inline fn copyPlain(out: *rig.String, s: []const u8, at: i64) i64 {
    var i: i64 = at;
    const n: i64 = rig.lenOf(s);
    while (i + 8 <= n) : (i += 8) {
        const w = rig.readInt(u64, s, i, .little);
        // A whole word stored, its first k bytes kept (`String.pushKeep`).
        const m = special64(w);
        if (m != 0) {
            const k = first_marked64(m);
            out.pushKeep(u64, w, k, rig.Endian.little);
            return i + k;
        }
        out.pushKeep(u64, w, 8, rig.Endian.little);
    }
    return i;
}
'''

OLD = '''                const j: i64 = rig.rt(self.plain(src, i));
                if (j < 0) {'''
NEW = '''                i = copyPlain(&self.text, src, i);
                if ((i < rig.lenOf(src)) and ((rig.at(src, i) == QUOTE) or (rig.at(src, i) == BACKSLASH) or (rig.at(src, i) < SPACE))) {
                    break :__rig_body_29;
                }
                const j: i64 = rig.rt(self.plain(src, i));
                if (j < 0) {'''


def make(copy):
    def patch(s):
        s = add_helpers(s)
        body = fn_text(s, "escaped")
        # The loop body's label, whose number depends on the source.
        label = re.search(r"(__rig_body_\d+): \{", body).group(1)
        assert body.count(OLD) == 1
        s = replace_fn(s, "escaped", body.replace(OLD, NEW.replace("__rig_body_29", label)))
        return s + copy
    return patch
