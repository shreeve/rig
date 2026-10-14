# std.utf8, std.utf16, and std.unicode's white space against Go's
# unicode/utf8, unicode/utf16, and unicode.IsSpace, which define them:
# the same generated strings and values are read by a Rig program, built
# with --release, and by a Go program calling Go's functions, and their
# outputs must be equal line for line. Each string, built from pieces of
# valid and invalid UTF-8 and random bytes, prints its length,
# `rune_count`, `is_valid`, `is_ascii`, `unit_count`, `rune_after`,
# `rune_before`, and `rune_size` at every index, its `runes`, and
# `byte_index` from -1 to two past its units. Each value prints `size`,
# `utf16.size`, `push_rune`'s bytes, `is_surrogate`, `pair_from_rune`,
# and `is_space`; pairs print `rune_from_pair`; and every value
# from -3 to 0x110003 goes into one hash of all of those. Skipped when
# `go` is not installed.
# timeout: 600
source "$ROOT/test/cli/_lib.sh"

if ! command -v go >/dev/null; then
    echo "go is not installed: skipped"
    exit 0
fi

PIECES='"\x61", "\x00", "\x7f", "\x5a", "\x61\x62\x63\x64\x65\x66\x67\x68", "\xc2\x80", "\xdf\xbf", "\xc3\xa9", "\xe0\xa0\x80", "\xed\x9f\xbf", "\xee\x80\x80", "\xef\xbf\xbd", "\xef\xbf\xbf", "\xe4\xb8\xad", "\xf0\x90\x80\x80", "\xf4\x8f\xbf\xbf", "\xf0\x9f\x98\x80", "\x80", "\xbf", "\xc0", "\xc1", "\xc2", "\xe0", "\xe0\x80", "\xed\xa0", "\xed\xa0\x80", "\xf0", "\xf0\x8f", "\xf0\x9f\x98", "\xf4\x90", "\xf5", "\xf8", "\xff", "\xfe"'
EDGES='0xD7FF, 0xD800, 0xD801, 0xDBFF, 0xDC00, 0xDC01, 0xDFFF, 0xE000, 0, -1, 0x10000, 0xFFFD'
SPOTS='0x7F, 0x80, 0x7FF, 0x800, 0xD7FF, 0xD800, 0xDBFF, 0xDC00, 0xDFFF, 0xE000, 0xFFFD, 0xFFFF, 0x10000, 0x10FFFF, 0x110000'

cat >main.rig <<'EOF'
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

sub value(r: Int)
  b = String()
  utf8.push_rune(!b, r)
  line = String()
  !line.add(r, " ", utf8.size(r) ?? -1, " ", utf16.size(r) ?? -1, " ")
  for x in b
    !line.add(Int(x), ".")
  p = utf16.pair_from_rune(r)
  !line.add(" ", utf16.is_surrogate(r), " ", p.hi, " ", p.lo, " ", unicode.is_space(r))
  print(line)

sub text_line(s: ?String)
  line = String()
  !line.add(s.len, " ", utf8.rune_count(s), " ", utf8.is_valid(s), " ", utf8.is_ascii(s), " ", utf16.unit_count(s), " |")
  for i in 0..s.len + 1
    d = utf8.rune_after(s, i)
    e = utf8.rune_before(s, i)
    !line.add(" ", d.rune, "/", d.size, "/", e.rune, "/", e.size, "/", utf8.rune_size(s, i) ?? 0)
  !line.add(" |")
  for r in utf8.runes(s)
    !line.add(" ", r)
  !line.add(" |")
  for u in -1..utf16.unit_count(s) + 3
    !line.add(" ", utf16.byte_index(s, u))
  print(line)

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
  g = Gen(x: 42)
  for _ in 0..20000
    s = String()
    pieces = next(!g) % 13
    for _ in 0..pieces
      k = next(!g)
      if k % 6 == 0
        !s.push(U8(next(!g) % 256))
      else
        !s.add(PIECES[next(!g) % PIECES.len])
    text_line(?s)
  for r in -3..0x900
    value(r)
  for c in SPOTS
    for d in -4..5
      value(c + d)
  for _ in 0..20000
    a = next(!g)
    value((a * 32768 + next(!g)) % 0x110020 - 8)
  for hi in EDGES
    for lo in EDGES
      print(hi, lo, utf16.rune_from_pair(hi, lo))
  for _ in 0..20000
    hi = 0xD700 + next(!g) % 0xA00
    lo = 0xD700 + next(!g) % 0xA00
    print(hi, lo, utf16.rune_from_pair(hi, lo))
  print(hash_all())
EOF

cat >main.go <<'EOF'
package main

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
EOF

for f in main.rig main.go; do
    PIECES="$PIECES" EDGES="$EDGES" SPOTS="$SPOTS" perl -pi -e 's/\@PIECES\@/$ENV{PIECES}/; s/\@EDGES\@/$ENV{EDGES}/; s/\@SPOTS\@/$ENV{SPOTS}/' "$f"
done

rig build --release -o prog main.rig || fail "build"
./prog >rig.out 2>rig.err; expect_rc $? 0 "rig run: $(head -c 2000 rig.err)"
GOFLAGS= go run main.go >go.out 2>go.err || fail "go run: $(head -c 2000 go.err)"
lines=$(wc -l <go.out | tr -d ' ')
[[ $lines -gt 60000 ]] || fail "go printed only $lines lines"
if ! cmp -s rig.out go.out; then
    diff rig.out go.out | head -c 3000
    fail "std.utf8, std.utf16, and is_space differ from Go"
fi
echo "$lines lines agree with $(go version)"
