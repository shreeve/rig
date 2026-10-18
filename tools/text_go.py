#!/usr/bin/env python3
"""Record what Go's unicode/utf8, unicode/utf16, and unicode.IsSpace give
for the strings and values the case `std.utf8, std.utf16, and is_space
agree with Go` of test/rig/std-text-go.rig.test reads, as that case's
expected result. It is named for the script of test/cli it replaces,
text_go.sh.

    tools/text_go.py            write test/rig/std-text-go.rig.test
    tools/text_go.py --check    fail when that file is not what it writes
    tools/text_go.py --compare RIG
                                build the case's program with RIG
                                --release and compare its lines with Go's,
                                line for line, to find where they part

Run it to regenerate the file after a change to the program below: it
needs `go`, and runs no rig. The same generated strings and values are
read by the Rig program, the case's whole program, and by a Go program
calling Go's functions. Each string, built from pieces of valid and
invalid UTF-8 and random bytes, makes a line of its length,
`rune_count`, `is_valid`, `is_ascii`, `unit_count`, `rune_after`,
`rune_before`, and `rune_size` at every index, its `runes`, and
`byte_index` from -1 to two past its units. Each value makes a line of
`size`, `utf16.size`, `push_rune`'s bytes, `is_surrogate`,
`pair_from_rune`, and `is_space`; pairs make lines of `rune_from_pair`;
and every value from -3 to 0x110003 goes into one hash of all of those.
Go prints its lines. The Rig program, given no argument, prints the
count and a hash of each section's lines, which this computes from Go's
lines, and given `lines`, prints the lines as Go does.
"""
import argparse
import os
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CASES = os.path.join(ROOT, "test", "rig", "std-text-go.rig.test")

PIECES = r'"\x61", "\x00", "\x7f", "\x5a", "\x61\x62\x63\x64\x65\x66\x67\x68", "\xc2\x80", "\xdf\xbf", "\xc3\xa9", "\xe0\xa0\x80", "\xed\x9f\xbf", "\xee\x80\x80", "\xef\xbf\xbd", "\xef\xbf\xbf", "\xe4\xb8\xad", "\xf0\x90\x80\x80", "\xf4\x8f\xbf\xbf", "\xf0\x9f\x98\x80", "\x80", "\xbf", "\xc0", "\xc1", "\xc2", "\xe0", "\xe0\x80", "\xed\xa0", "\xed\xa0\x80", "\xf0", "\xf0\x8f", "\xf0\x9f\x98", "\xf4\x90", "\xf5", "\xf8", "\xff", "\xfe"'
EDGES = "0xD7FF, 0xD800, 0xD801, 0xDBFF, 0xDC00, 0xDC01, 0xDFFF, 0xE000, 0, -1, 0x10000, 0xFFFD"
SPOTS = "0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xE000, 0xFFFD, 0xFFFF, 0x10000, 0x10FFFF, 0x110000"
M = 1000000007

RIG = r"""use std.os
use std.utf8
use std.utf16
use std.unicode

PIECES = [@PIECES@]
EDGES = [@EDGES@]
SPOTS = [@SPOTS@]
M = 1000000007

# A linear congruential generator, the same as the Go program's.
obj Gen
  x: Int

# The next number of `g`, 0 to 32767.
fun next(g: !Gen) -> Int
  g.x = (g.x * 1103515245 + 12345) % 2147483648
  g.x / 65536

# A section's lines: printed, or counted and hashed, each line's bytes
# and then a newline.
obj Lines
  print: Bool
  n: Int = 0
  h: Int = 0

sub take(d: !Lines, line: ?String)
  if d.print
    print(line)
    return
  for x in line
    d.h = (d.h * 31 + Int(x)) % M
  d.h = (d.h * 31 + 10) % M
  d.n += 1

sub value(d: !Lines, r: Int)
  b = String()
  utf8.push_rune(!b, r)
  line = String()
  !line.add(r, " ", utf8.size(r) ?? -1, " ", utf16.size(r) ?? -1, " ")
  for x in b
    !line.add(Int(x), ".")
  p = utf16.pair_from_rune(r)
  !line.add(" ", utf16.is_surrogate(r), " ", p.hi, " ", p.lo, " ", unicode.is_space(r))
  take(!d, ?line)

sub text_line(d: !Lines, s: ?String)
  line = String()
  !line.add(s.len, " ", utf8.rune_count(s), " ", utf8.is_valid(s), " ", utf8.is_ascii(s), " ", utf16.unit_count(s), " |")
  for i in 0..s.len + 1
    e = utf8.rune_after(s, i)
    f = utf8.rune_before(s, i)
    !line.add(" ", e.rune, "/", e.size, "/", f.rune, "/", f.size, "/", utf8.rune_size(s, i) ?? 0)
  !line.add(" |")
  for r in utf8.runes(s)
    !line.add(" ", r)
  !line.add(" |")
  for u in -1..utf16.unit_count(s) + 3
    !line.add(" ", utf16.byte_index(s, u))
  take(!d, ?line)

sub pair(d: !Lines, hi: Int, lo: Int)
  line = String()
  !line.add(hi, " ", lo, " ", utf16.rune_from_pair(hi, lo))
  take(!d, ?line)

# One hash of every value's results from -3 to 0x110003.
fun hash_all() -> Int
  h = 0
  b = String()
  r = -3
  while r <= 0x110003 : r += 1
    !b.clear()
    utf8.push_rune(!b, r)
    for x in b
      h = (h * 31 + Int(x)) % M
    p = utf16.pair_from_rune(r)
    f = (utf8.size(r) ?? -1) + 2 + 8 * ((utf16.size(r) ?? -1) + 2)
    f = f + (64 if utf16.is_surrogate(r) else 0) + (128 if unicode.is_space(r) else 0)
    h = (h * 31 + f) % M
    h = (h * 31 + p.hi) % M
    h = (h * 31 + p.lo) % M
  h

sub main()
  args = os.args()
  lines = args.len > 1 and args[1] == "lines"
  g = Gen(x: 42)
  texts = Lines(print: lines)
  for _ in 0..20000
    s = String()
    pieces = next(!g) % 13
    for _ in 0..pieces
      k = next(!g)
      if k % 6 == 0
        !s.push(U8(next(!g) % 256))
      else
        !s.add(PIECES[next(!g) % PIECES.len])
    text_line(!texts, ?s)
  values = Lines(print: lines)
  for r in -3..0x900
    value(!values, r)
  for c in SPOTS
    for d in -4..5
      value(!values, c + d)
  for _ in 0..20000
    a = next(!g)
    value(!values, (a * 32768 + next(!g)) % 0x110020 - 8)
  pairs = Lines(print: lines)
  for hi in EDGES
    for lo in EDGES
      pair(!pairs, hi, lo)
  for _ in 0..20000
    hi = 0xD700 + next(!g) % 0xA00
    lo = 0xD700 + next(!g) % 0xA00
    pair(!pairs, hi, lo)
  if lines
    print(hash_all())
    return
  print("strings", texts.n, texts.h)
  print("values", values.n, values.h)
  print("pairs", pairs.n, pairs.h)
  print("every value", hash_all())
"""

GO = r"""package main

import (
	"bufio"
	"fmt"
	"os"
	"unicode"
	"unicode/utf16"
	"unicode/utf8"
)

var pieces = []string{@PIECES@}
var edges = []rune{@EDGES@}
var spots = []rune{@SPOTS@}

const m = 1000000007

type gen struct{ x int64 }

func (g *gen) next() int64 {
	g.x = (g.x*1103515245 + 12345) % 2147483648
	return g.x / 65536
}

var w = bufio.NewWriter(os.Stdout)

func value(r rune) {
	b := utf8.AppendRune(nil, r)
	fmt.Fprintf(w, "%d %d %d ", r, utf8.RuneLen(r), utf16.RuneLen(r))
	for _, x := range b {
		fmt.Fprintf(w, "%d.", x)
	}
	hi, lo := utf16.EncodeRune(r)
	fmt.Fprintf(w, " %t %d %d %t\n", utf16.IsSurrogate(r), hi, lo, unicode.IsSpace(r))
}

func isASCII(s string) bool {
	for i := 0; i < len(s); i++ {
		if s[i] >= utf8.RuneSelf {
			return false
		}
	}
	return true
}

func unitCount(s string) int { return len(utf16.Encode([]rune(s))) }

func byteIndex(s string, units int) int {
	n := 0
	for i, r := range s {
		if n >= units {
			return i
		}
		n += utf16.RuneLen(r)
	}
	return len(s)
}

func runeSize(s string, i int) int {
	r, size := utf8.DecodeRuneInString(s[i:])
	if size == 0 || (r == utf8.RuneError && size == 1) {
		return 0
	}
	return size
}

func textLine(s string) {
	units := unitCount(s)
	fmt.Fprintf(w, "%d %d %t %t %d |", len(s), utf8.RuneCountInString(s), utf8.ValidString(s), isASCII(s), units)
	for i := 0; i <= len(s); i++ {
		r, n := utf8.DecodeRuneInString(s[i:])
		q, k := utf8.DecodeLastRuneInString(s[:i])
		fmt.Fprintf(w, " %d/%d/%d/%d/%d", r, n, q, k, runeSize(s, i))
	}
	fmt.Fprint(w, " |")
	for _, r := range s {
		fmt.Fprintf(w, " %d", r)
	}
	fmt.Fprint(w, " |")
	for u := -1; u < units+3; u++ {
		fmt.Fprintf(w, " %d", byteIndex(s, u))
	}
	fmt.Fprintln(w)
}

func hashAll() int64 {
	var h int64
	for r := rune(-3); r <= 0x110003; r++ {
		for _, x := range utf8.AppendRune(nil, r) {
			h = (h*31 + int64(x)) % m
		}
		hi, lo := utf16.EncodeRune(r)
		f := int64(utf8.RuneLen(r)+2) + 8*int64(utf16.RuneLen(r)+2)
		if utf16.IsSurrogate(r) {
			f += 64
		}
		if unicode.IsSpace(r) {
			f += 128
		}
		h = (h*31 + f) % m
		h = (h*31 + int64(hi)) % m
		h = (h*31 + int64(lo)) % m
	}
	return h
}

func main() {
	defer w.Flush()
	g := &gen{x: 42}
	for n := 0; n < 20000; n++ {
		var s []byte
		count := g.next() % 13
		for j := int64(0); j < count; j++ {
			k := g.next()
			if k%6 == 0 {
				s = append(s, byte(g.next()%256))
			} else {
				s = append(s, pieces[g.next()%int64(len(pieces))]...)
			}
		}
		textLine(string(s))
	}
	for r := rune(-3); r < 0x900; r++ {
		value(r)
	}
	for _, c := range spots {
		for d := rune(-4); d < 5; d++ {
			value(c + d)
		}
	}
	for n := 0; n < 20000; n++ {
		a := g.next()
		value(rune((a*32768+g.next())%0x110020 - 8))
	}
	for _, hi := range edges {
		for _, lo := range edges {
			fmt.Fprintln(w, hi, lo, utf16.DecodeRune(hi, lo))
		}
	}
	for n := 0; n < 20000; n++ {
		hi := rune(0xD700 + g.next()%0xA00)
		lo := rune(0xD700 + g.next()%0xA00)
		fmt.Fprintln(w, hi, lo, utf16.DecodeRune(hi, lo))
	}
	fmt.Fprintln(w, hashAll())
}
"""

# The Go program's lines by section, a line a string, a value, or a
# pair, and then the hash of every value.
SECTIONS = [("strings", 20000),
            ("values", (0x900 + 3) + 9 * len(SPOTS.split(",")) + 20000),
            ("pairs", len(EDGES.split(",")) ** 2 + 20000)]


def fill(text):
    return text.replace("@PIECES@", PIECES).replace("@EDGES@", EDGES).replace("@SPOTS@", SPOTS)


def go_lines():
    with tempfile.TemporaryDirectory() as d:
        main = os.path.join(d, "main.go")
        with open(main, "w") as f:
            f.write(fill(GO))
        r = subprocess.run(["go", "run", main], capture_output=True, env=dict(os.environ, GOFLAGS=""))
        if r.returncode:
            sys.exit("go run: " + r.stderr.decode()[:2000])
    return r.stdout.decode().split("\n")[:-1]


def expected(lines):
    """What the Rig program prints given no argument, from Go's lines."""
    out, at = [], 0
    for name, n in SECTIONS:
        h = 0
        for line in lines[at : at + n]:
            for b in line.encode() + b"\n":
                h = (h * 31 + b) % M
        out.append(f"{name} {n} {h}")
        at += n
    if len(lines) != at + 1:
        sys.exit(f"Go printed {len(lines)} lines, not {at + 1}")
    out.append(f"every value {lines[at]}")
    return out


def cases(lines):
    q = "'" * 3
    body = "\n".join(("  " + l) if l else "" for l in fill(RIG).rstrip("\n").split("\n"))
    want = "\n".join("  " + l for l in expected(lines))
    return (
        "# std: std.utf8, std.utf16, and std.unicode's white space against Go's\n"
        "# unicode/utf8, unicode/utf16, and unicode.IsSpace, which define them.\n"
        "# Written by tools/text_go.py from Go's answers: run it to write this\n"
        "# file again after a change to the program, which it holds.\n\n"
        f'test "std.utf8, std.utf16, and is_space agree with Go", {q}, whole: true, release: true, timeout: 300\n'
        f"{want}\n{q}\n{body}\n"
    )


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--check", action="store_true")
    ap.add_argument("--compare", metavar="RIG")
    a = ap.parse_args()
    lines = go_lines()
    if a.compare:
        with tempfile.TemporaryDirectory() as d:
            prog = os.path.join(d, "main.rig")
            with open(prog, "w") as f:
                f.write(fill(RIG))
            env = dict(os.environ, RIG_OUT_DIR=os.path.join(d, "out"))
            subprocess.run([a.compare, "build", "--release", "-o", os.path.join(d, "prog"), prog], check=True, env=env)
            got = subprocess.run([os.path.join(d, "prog"), "lines"], capture_output=True, check=True).stdout.decode().split("\n")[:-1]
        for k, (g, w) in enumerate(zip(got, lines)):
            if g != w:
                sys.exit(f"line {k + 1} differs:\n  rig: {g}\n  go:  {w}")
        if len(got) != len(lines):
            sys.exit(f"rig printed {len(got)} lines, Go {len(lines)}")
        print(f"{len(lines)} lines agree")
        return
    text = cases(lines)
    if a.check:
        with open(CASES) as f:
            if f.read() != text:
                sys.exit(f"{CASES} is not what tools/text_go.py writes")
        return
    with open(CASES, "w") as f:
        f.write(text)


main()
