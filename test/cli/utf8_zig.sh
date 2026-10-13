# std.utf8 against Zig's std.unicode, built with --release: every code
# point is written by `push_rune` as Zig encodes it, in `size` bytes,
# and read back by `rune_after`, `rune_before`, and `rune_size`, and
# neither Zig nor `size` encodes a surrogate or anything past
# U+10FFFF; every string of one to three bytes, and every four-byte one
# from a first byte of 0xC0 or more whose last byte is an edge of the
# continuation range, is read at 0 by `rune_size` and `rune_after` as
# Zig's decoder reads it. `RIG_STD` adds the reference, `std.utf8ref`.
# timeout: 600
source "$ROOT/test/cli/_lib.sh"

mkdir lib
cp "$ROOT"/std/*.rig "$ROOT"/std/*.zig lib/

cat >lib/utf8ref.rig <<'EOF'
extern zig "utf8ref.zig"
  # The index just past the sequence Zig decodes at `at`, or -1.
  pub fun end(s: ?String, at: Int) -> Int
  # The code point Zig decodes at `at`, or -1.
  pub fun code(s: ?String, at: Int) -> Int
  # Whether Zig encodes `r` as exactly the bytes of `s`.
  pub fun encodes(r: Int, s: ?String) -> Bool
EOF

cat >lib/utf8ref.zig <<'EOF'
const std = @import("std");
const unicode = std.unicode;

fn decode(s: []const u8, at: i64) ?struct { u21, usize } {
    const i: usize = @intCast(at);
    if (i >= s.len) return null;
    const n = unicode.utf8ByteSequenceLength(s[i]) catch return null;
    if (s.len - i < n) return null;
    const b = s[i..];
    const c: u21 = switch (n) {
        1 => b[0],
        2 => unicode.utf8Decode2(b[0..2].*) catch return null,
        3 => unicode.utf8Decode3(b[0..3].*) catch return null,
        4 => unicode.utf8Decode4(b[0..4].*) catch return null,
        else => unreachable,
    };
    return .{ c, i + n };
}

pub fn end(s: []const u8, at: i64) i64 {
    const d = decode(s, at) orelse return -1;
    return @intCast(d[1]);
}

pub fn code(s: []const u8, at: i64) i64 {
    const d = decode(s, at) orelse return -1;
    return d[0];
}

pub fn encodes(r: i64, s: []const u8) bool {
    var buf: [4]u8 = undefined;
    const n = unicode.utf8Encode(@intCast(r), &buf) catch return false;
    return std.mem.eql(u8, buf[0..n], s);
}
EOF

cat >main.rig <<'EOF'
use std.utf8
use std.utf8ref

EDGE = [0x00, 0x7F, 0x80, 0x81, 0xBF, 0xC0, 0xFF]

# The code points whose bytes or reading differ from Zig's.
fun code_points() -> Int
  bad = 0
  out = String()
  c = 0
  while c <= 0x10FFFF : c += 1
    if c >= 0xD800 and c <= 0xDFFF
      if utf8ref.encodes(c, "") or utf8.size(c) != none
        bad += 1
      continue
    !out.clear()
    utf8.push_rune(!out, c)
    n = out.len
    r = utf8.rune_after(?out, 0)
    b = utf8.rune_before(?out, n)
    if not utf8ref.encodes(c, ?out) or r.rune != c or r.size != n or b.rune != c or b.size != n or (utf8.rune_size(?out, 0) ?? 0) != n or (utf8.size(c) ?? 0) != n
      bad += 1
  if utf8ref.encodes(0x110000, "") or utf8.size(0x110000) != none or utf8.size(-1) != none
    bad += 1
  bad

# Whether std.utf8 reads `s` at 0 as Zig does: the same size, and Zig's
# code point, or `REPLACEMENT` of size 1 where Zig decodes none.
fun agrees(s: ?String) -> Bool
  e = utf8ref.end(s, 0)
  return false if (utf8.rune_size(s, 0) ?? -1) != e
  r = utf8.rune_after(s, 0)
  if e < 0
    return r.rune == utf8.REPLACEMENT and r.size == 1
  r.rune == utf8ref.code(s, 0) and r.size == e

# Sets `s` to the bytes of `b`.
sub set(s: !String, b: []Int)
  !s.clear()
  for x in b
    !s.push(U8(x))

# The strings `agrees` fails on, after printing how many it read.
fun sequences() -> Int
  bad = 0
  read = 0
  s = String()
  for a in 0..256
    for b in 0..256
      set(!s, [a, b])
      read += 2
      if not agrees(?s[..1]) or not agrees(?s)
        bad += 1
      for c in 0..256
        set(!s, [a, b, c])
        read += 1
        if not agrees(?s)
          bad += 1
        if a >= 0xC0
          for d in EDGE
            set(!s, [a, b, c, d])
            read += 1
            if not agrees(?s)
              bad += 1
  print(read)
  bad

sub main()
  print(code_points(), sequences())
EOF

RIG_STD="$PWD/lib" rig build --release -o prog main.rig || fail "build"
out=$(./prog 2>&1); expect_rc $? 0 "run: $out"
expect_eq "$out" $'46268416\n0 0' "agreement with Zig's std.unicode"
