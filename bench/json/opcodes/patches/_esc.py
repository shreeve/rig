"""Escaped strings: the text between escapes copied as it is scanned, a
block at a time (`String` write window: store a whole block into reserved
room, keep its first k bytes), instead of a scan (`plain`) and then a
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
    const n: i64 = rig.len(s.len);
    const l = &out.list;
    while (i + 16 <= n) : (i += 16) {
        const v = rig.simdRead(@Vector(16, u8), s, i, rig.Endian.little);
        out.reserve(16);
        const dst: *align(1) @Vector(16, u8) = @ptrCast(l.items.ptr + l.items.len);
        dst.* = v;
        if (rig.maskFirst(special(v))) |k| {
            l.items.len += @intCast(k);
            return i + k;
        }
        l.items.len += 16;
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
    const n: i64 = rig.len(s.len);
    const l = &out.list;
    while (i + 8 <= n) : (i += 8) {
        const w = rig.readInt(u64, s, i, .little);
        out.reserve(8);
        const dst: *align(1) u64 = @ptrCast(l.items.ptr + l.items.len);
        dst.* = w;
        const m = special64(w);
        if (m != 0) {
            const k = first_marked64(m);
            l.items.len += @intCast(k);
            return i + k;
        }
        l.items.len += 8;
    }
    return i;
}
'''

OLD = '''                const j: i64 = rig.rt(self.plain(src, i));
                if (j < 0) {'''
NEW = '''                i = copyPlain(&self.text, src, i);
                if ((i < rig.len(src.len)) and ((rig.at(src, i) == QUOTE) or (rig.at(src, i) == BACKSLASH) or (rig.at(src, i) < SPACE))) {
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
