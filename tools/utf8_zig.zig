//! The expected result of the case `utf8 zig` in
//! test/rig/std-utf8-zig.rig.test: what Zig's std.unicode makes of the
//! case's code points and byte strings, as the digest the case prints of
//! what std.utf8 makes of them. Every code point but the surrogates is
//! encoded, its length and then its bytes taken into the digest; Zig
//! encodes no surrogate and nothing past U+10FFFF. Every string of one
//! or two bytes, every three-byte one whose last byte is an edge of the
//! continuation range, and every four-byte one from a first byte of 0xC0
//! or more whose last two bytes are edges, is read at 0: the index just
//! past the sequence Zig decodes and its code point, or, where Zig
//! decodes none, -1 and U+FFFD of size 1, as std.utf8 reads it. A
//! four-byte string's second byte is any byte after the first bytes that
//! narrow the second byte's range (0xE0, 0xED, 0xF0, 0xF4), and an edge
//! after the others.
//!
//! The case's strings and digest are the same as this program's; after a
//! change to either, regenerate the case's result:
//!
//!     zig run tools/utf8_zig.zig
//!
//! The comparison this records, run whole against Zig (every string of up
//! to three bytes, and many more of four), is `UTF8_ZIG_FULL=1` on
//! test/cli/utf8_zig.sh.
const std = @import("std");
const unicode = std.unicode;

/// Two polynomial hashes of the numbers taken, each counted as itself
/// plus two, and how many strings were read.
const Digest = struct {
    a: i64 = 0,
    b: i64 = 0,
    n: i64 = 0,

    fn take(d: *Digest, x: i64) void {
        d.a = @mod(d.a * 257 + x + 2, 2147483647);
        d.b = @mod(d.b * 263 + x + 2, 2147483629);
    }
};

const EDGE = [_]u8{ 0x00, 0x7F, 0x80, 0x81, 0xBF, 0xC0, 0xFF };
const BOUND = [_]u8{ 0x00, 0x7F, 0x80, 0x8F, 0x90, 0x9F, 0xA0, 0xBF, 0xC0, 0xFF };

fn bound(x: u8) bool {
    return std.mem.indexOfScalar(u8, &BOUND, x) != null;
}

fn wide(a: u8) bool {
    return a == 0xE0 or a == 0xED or a == 0xF0 or a == 0xF4;
}

/// Reads `s` at 0 as the case expects std.utf8 to.
fn read(d: *Digest, s: []const u8) void {
    d.n += 1;
    decoded: {
        const n = unicode.utf8ByteSequenceLength(s[0]) catch break :decoded;
        if (s.len < n) break :decoded;
        const c: u21 = switch (n) {
            1 => s[0],
            2 => unicode.utf8Decode2(s[0..2].*) catch break :decoded,
            3 => unicode.utf8Decode3(s[0..3].*) catch break :decoded,
            4 => unicode.utf8Decode4(s[0..4].*) catch break :decoded,
            else => unreachable,
        };
        d.take(n);
        d.take(c);
        d.take(n);
        return;
    }
    d.take(-1);
    d.take(0xFFFD);
    d.take(1);
}

pub fn main() !void {
    var d: Digest = .{};
    var buf: [4]u8 = undefined;
    var c: u32 = 0;
    while (c <= 0x10FFFF) : (c += 1) {
        const r: u21 = @intCast(c);
        if (c >= 0xD800 and c <= 0xDFFF) {
            if (unicode.utf8Encode(r, &buf)) |_| return error.EncodedSurrogate else |_| {}
            continue;
        }
        const n = try unicode.utf8Encode(r, &buf);
        d.take(n);
        for (buf[0..n]) |b| d.take(b);
    }
    if (unicode.utf8Encode(@as(u21, 0x110000), &buf)) |_| return error.EncodedPastMax else |_| {}
    for (0..256) |ai| {
        const a: u8 = @intCast(ai);
        read(&d, &.{a});
        for (0..256) |bi| {
            const b: u8 = @intCast(bi);
            read(&d, &.{ a, b });
            for (BOUND) |x| {
                read(&d, &.{ a, b, x });
                if (a >= 0xC0 and (wide(a) or bound(b))) {
                    for (EDGE) |y| read(&d, &.{ a, b, x, y });
                }
            }
        }
    }
    std.debug.print("0 {d} {d} {d}\n", .{ d.n, d.a, d.b });
}
