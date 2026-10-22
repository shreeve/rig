#!/usr/bin/env python3
"""make_wsspec.py IN OUT: std.json with a specialized document[dense: Bool],
the whitespace bitmap in the dense instance only, chosen once per parse."""
import sys
s = open(sys.argv[1]).read()
rep = [
("""  ints: List[Int]
""","""  ints: List[Int]
  # The non-space bytes of the 64 from `ws_at` on, bit k for byte
  # ws_at + k, kept between `skip_ws_run` calls in a dense document.
  ws_at: Int
  ws_bits: U64
"""),
("""    return true if (!self).document(src) >= 0""","""    self.ws_at = -128
    # A long, deeply indented document skips its whitespace with the
    # bitmap; any other, with the scalar loop. One choice per parse, so
    # each copy of `document` holds one way.
    ok = 0
    if src.len >= WS_PROBE_MIN and long_runs(src)
      ok = (!self).document[true](src)
    else
      ok = (!self).document[false](src)
    return true if ok >= 0"""),
("""  fun document(!self, src: ?String) -> Int""","""  fun document[dense: Bool](!self, src: ?String) -> Int"""),
("""  # Parses `"key"` and the `:` after it; returns where the value starts.""","""  # The index of the first byte from `at` on that is not whitespace: the
  # scalar loop in most documents, the bitmap in a dense one.
  fun skip_ws[dense: Bool](!self, s: ?String, at: Int) -> Int
    return skip_space(s, at) if not dense
    return at if at < 0
    return at if at < s.len and s[at] > SPACE
    return at + 1 if at + 1 < s.len and s[at] == SPACE and s[at + 1] > SPACE
    (!self).skip_ws_run(s, at)

  # `skip_ws`'s run, as sonic-rs finds it: from a bitmap of the non-space
  # bytes of a 64-byte block, classified once and kept between calls.
  fun skip_ws_run(!self, s: ?String, at: Int) -> Int
    i = at
    while true
      k = i - self.ws_at
      if k >= 0 and k < 64
        m = self.ws_bits >> k
        return i + m.trailing_zeros() if m != 0
        i = self.ws_at + 64
      return skip_space(s, i) if i + 64 > s.len
      v = s.read[Simd[U8, 64]](i)
      self.ws_at = i
      self.ws_bits = ((v == SPACE) | (v == LF) | (v == CR) | (v == TAB)).not().bits()
    -1

  # Parses `"key"` and the `:` after it; returns where the value starts."""),
("""fun skip_space(s: ?String, at: Int) -> Int""","""# Inputs shorter than this always take the scalar loop: probing would
# cost a small one a large part of its parse.
WS_PROBE_MIN = 65536
# The mean length, in bytes, of runs of 2 or more whitespace bytes above
# which the bitmap pays: deeply indented documents.
WS_LONG = 16

# Whether `s`'s whitespace comes in long runs, from 8 windows of 512
# bytes spread over it: the mean length of the runs of 2 or more bytes
# that start in them, against WS_LONG.
fun long_runs(s: ?String) -> Bool
  total = 0
  runs = 0
  for j in 0..8
    i = j * (s.len / 8)
    stop = i + 512
    while i < stop and i < s.len
      c = s[i]
      if c == SPACE or c == LF or c == CR or c == TAB
        end = skip_space(s, i)
        if end - i >= 2
          total += end - i
          runs += 1
        i = end
      else
        i += 1
  runs > 0 and total > runs * WS_LONG

fun skip_space(s: ?String, at: Int) -> Int"""),
("""ints: List(), error""","""ints: List(), ws_at: -128, ws_bits: 0, error"""),
]
for a, b in rep:
    assert s.count(a) == 1, a[:60]
    s = s.replace(a, b)
d0 = s.index("  fun document[dense: Bool]"); d1 = s.index("  # Records the first error", d0)
doc = s[d0:d1].replace("skip_space(src, ", "(!self).skip_ws[dense](src, ")
assert doc.count("skip_ws[dense]") == 4, doc.count("skip_ws[dense]")
open(sys.argv[2], "w").write(s[:d0] + doc + s[d1:])
