# std.text's parse_int and format_int against Go's strconv.ParseInt(s,
# base, 64) and FormatInt: the same generated strings in bases 2 to 36
# are parsed by a Rig program,
# built with --release, and by a Go program, and their outputs must be
# equal line for line. Each line is the base, the string's bytes in hex,
# and the value, `invalid`, or `overflow`. The strings: random digits of
# every length up to past Int's, Int.max and Int.min with one digit
# changed, leading zeros, long runs with one bad byte, random bytes,
# signs alone or doubled, and formatted values in either case; then, in
# every base, Int.max, Int.min, 2^63 with and without a sign, each with
# leading zeros, and every byte alone and after a `1`. Where the digits
# overflow before a bad byte, Go reports the overflow and std the bad
# byte, as `parse_int` documents: the Go program gives `invalid` for any
# string that is not a sign and digits, and counts those cases. Then
# format_int writes, in every base and both cases, the powers of 10 and
# of the base and their neighbors, the ends of Int, and random values of
# every magnitude. Skipped when `go` is not installed.
# timeout: 600
source "$ROOT/test/cli/_lib.sh"

if ! command -v go >/dev/null; then
    echo "go is not installed: skipped"
    exit 0
fi

cat >main.rig <<'EOF'
use std.text

CASES = 120000
COMMON = [2, 8, 10, 16]
CHARS = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+-_ x./:@[`{\x80\xff\x00"
BAD = " _x.+-/:@[`{\x80\xff\x00"
ODD = ["", "+", "-", "+-1", "-+1", "--1", "++1", " 1", "1 ", "0x1", "0b1", "1_0", "-0", "+0", "00", "-00", "+ 1"]
HEX = "0123456789abcdef"

# A linear congruential generator, the same as the Go program's.
obj Gen
  x: Int

# The next number of `g`, 0 to 32767.
fun next(g: !Gen) -> Int
  g.x = (g.x * 1103515245 + 12345) % 2147483648
  g.x / 65536

# A random digit of `base`, a letter in either case.
fun digit(g: !Gen, base: Int) -> U8
  d = next(!g) % base
  return U8(48 + d) if d < 10
  up = next(!g) % 2 == 0
  U8(55 + d) if up else U8(87 + d)

sub sign(g: !Gen, s: !String)
  k = next(!g) % 3
  !s.push(43) if k == 1
  !s.push(45) if k == 2

sub digits(g: !Gen, s: !String, base: Int, n: Int)
  for _ in 0..n
    !s.push(digit(!g, base))

fun random_case(g: !Gen, base: Int) -> String
  s = String()
  kind = next(!g) % 8
  if kind == 0
    sign(!g, !s)
    n = 1 + next(!g) % (text.format_int(Int.max, base).len + 3)
    digits(!g, !s, base, n)
  else if kind == 1 or kind == 2
    t = text.format_int(Int.max if kind == 1 else Int.min, base)
    tv = ?t[..]
    pos = kind - 1 + next(!g) % (t.len - kind + 1)
    for i in 0..t.len
      if i == pos
        !s.push(digit(!g, base))
      else
        !s.push(tv[i])
  else if kind == 3
    n = next(!g) % 26
    for _ in 0..n
      !s.push(CHARS[next(!g) % CHARS.len])
  else if kind == 4
    sign(!g, !s)
    z = next(!g) % 70
    for _ in 0..z
      !s.push(48)
    n = next(!g) % 22
    digits(!g, !s, base, n)
  else if kind == 5
    sign(!g, !s)
    n = 15 + next(!g) % 60
    pos = next(!g) % (n + 1)
    for i in 0..n + 1
      if i == pos
        !s.push(BAD[next(!g) % BAD.len])
      else
        !s.push(digit(!g, base))
  else if kind == 6
    !s.add(ODD[next(!g) % ODD.len])
  else
    v = next(!g) * 35184372088832 + next(!g) * 1073741824 + next(!g) * 32768 + next(!g)
    v = v >> (next(!g) % 63)
    v = -v if next(!g) % 2 == 0 else v
    up = next(!g) % 2 == 0
    !s.push(43) if v >= 0 and next(!g) % 4 == 0
    !s.add(text.format_int(v, base, upper: up))
  s

sub check(base: Int, s: ?String)
  line = String()
  !line.add(base, " x")
  for b in s
    !line.push(HEX[Int(b) >> 4])
    !line.push(HEX[Int(b) & 15])
  v = text.parse_int(s, base) catch |err|
    !line.add(" ", "overflow" if err == text.ParseError.overflow else "invalid")
    print(line)
    return
  !line.add(" ", v)
  print(line)

sub main()
  g = Gen(x: 7)
  for _ in 0..CASES
    pick = next(!g)
    base = 2 + next(!g) % 35
    base = COMMON[pick / 2 % 4] if pick % 2 == 0 else base
    s = random_case(!g, base)
    check(base, ?s)
  zeros = String()
  for _ in 0..70
    !zeros.push(48)
  for base in 2..37
    max = text.format_int(Int.max, base)
    min = text.format_int(Int.min, base)
    edges = [String(max), String(min), String(min[1..]), String("+", min[1..]), String("-", max),
             String(max, "0"), String(min, "0"), String(zeros, max), String("-", zeros, min[1..]),
             String("+", zeros, min[1..]), String(min, "1")]
    for e in edges
      check(base, ?e)
    for b in 0..256
      one = String()
      !one.push(U8(b))
      check(base, ?one)
      !one.clear()
      !one.push(49)
      !one.push(U8(b))
      check(base, ?one)
  values: List[Int] = List()
  for v in [0, 1, 9, 10, 11, 99, 100, 101, 999, 1000, 35, 36, 37, Int.max, Int.max - 1]
    !values.push(v)
  p = 1
  while p <= Int.max / 10
    p *= 10
    !values.push(p - 1)
    !values.push(p)
  for _ in 0..3000
    v = next(!g) * 35184372088832 + next(!g) * 1073741824 + next(!g) * 32768 + next(!g)
    !values.push(v >> (next(!g) % 63))
  for base in 2..37
    q = 1
    while q <= Int.max / base
      q *= base
      !values.push(q - 1)
      !values.push(q)
    for v in values
      for w in [v, -v, -v - 1]
        print(base, text.format_int(w, base), text.format_int(w, base, upper: true))
    while values.len > 0 and q > 1
      q /= base
      _ = !values.pop()
      _ = !values.pop()
EOF

cat >main.go <<'EOF'
package main

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"
)

const cases = 120000

var common = []int64{2, 8, 10, 16}

const chars = "0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ+-_ x./:@[`{\x80\xff\x00"
const bad = " _x.+-/:@[`{\x80\xff\x00"

var odd = []string{"", "+", "-", "+-1", "-+1", "--1", "++1", " 1", "1 ", "0x1", "0b1", "1_0", "-0", "+0", "00", "-00", "+ 1"}

type gen struct{ x int64 }

func (g *gen) next() int64 {
	g.x = (g.x*1103515245 + 12345) % 2147483648
	return g.x / 65536
}

func (g *gen) digit(base int64) byte {
	d := g.next() % base
	if d < 10 {
		return byte(48 + d)
	}
	if g.next()%2 == 0 {
		return byte(55 + d)
	}
	return byte(87 + d)
}

func (g *gen) sign(s []byte) []byte {
	switch g.next() % 3 {
	case 1:
		s = append(s, '+')
	case 2:
		s = append(s, '-')
	}
	return s
}

func (g *gen) digits(s []byte, base, n int64) []byte {
	for i := int64(0); i < n; i++ {
		s = append(s, g.digit(base))
	}
	return s
}

func (g *gen) randomCase(base int64) []byte {
	var s []byte
	kind := g.next() % 8
	switch {
	case kind == 0:
		s = g.sign(s)
		s = g.digits(s, base, 1+g.next()%int64(len(strconv.FormatInt(1<<63-1, int(base)))+3))
	case kind == 1 || kind == 2:
		var t string
		if kind == 1 {
			t = strconv.FormatInt(1<<63-1, int(base))
		} else {
			t = strconv.FormatInt(-1<<63, int(base))
		}
		pos := kind - 1 + g.next()%(int64(len(t))-kind+1)
		for i := int64(0); i < int64(len(t)); i++ {
			if i == pos {
				s = append(s, g.digit(base))
			} else {
				s = append(s, t[i])
			}
		}
	case kind == 3:
		n := g.next() % 26
		for i := int64(0); i < n; i++ {
			s = append(s, chars[g.next()%int64(len(chars))])
		}
	case kind == 4:
		s = g.sign(s)
		z := g.next() % 70
		for i := int64(0); i < z; i++ {
			s = append(s, '0')
		}
		s = g.digits(s, base, g.next()%22)
	case kind == 5:
		s = g.sign(s)
		n := 15 + g.next()%60
		pos := g.next() % (n + 1)
		for i := int64(0); i < n+1; i++ {
			if i == pos {
				s = append(s, bad[g.next()%int64(len(bad))])
			} else {
				s = append(s, g.digit(base))
			}
		}
	case kind == 6:
		s = append(s, odd[g.next()%int64(len(odd))]...)
	default:
		a := g.next()
		b := g.next()
		c := g.next()
		d := g.next()
		v := a*35184372088832 + b*1073741824 + c*32768 + d
		v = v >> (g.next() % 63)
		if g.next()%2 == 0 {
			v = -v
		}
		up := g.next()%2 == 0
		if v >= 0 && g.next()%4 == 0 {
			s = append(s, '+')
		}
		f := strconv.FormatInt(v, int(base))
		if up {
			f = strings.ToUpper(f)
		}
		s = append(s, f...)
	}
	return s
}

// Whether s is a sign and one or more digits of base.
func written(s string, base int) bool {
	if len(s) > 0 && (s[0] == '+' || s[0] == '-') {
		s = s[1:]
	}
	if len(s) == 0 {
		return false
	}
	for i := 0; i < len(s); i++ {
		c := s[i]
		d := 99
		switch {
		case '0' <= c && c <= '9':
			d = int(c - '0')
		case 'a' <= c && c <= 'z':
			d = int(c-'a') + 10
		case 'A' <= c && c <= 'Z':
			d = int(c-'A') + 10
		}
		if d >= base {
			return false
		}
	}
	return true
}

var w = bufio.NewWriter(os.Stdout)
var rangeFirst, syntaxOdd int

func check(base int64, s []byte) {
	fmt.Fprintf(w, "%d x%x ", base, s)
	v, err := strconv.ParseInt(string(s), int(base), 64)
	ok := written(string(s), int(base))
	switch {
	case !ok:
		if errors.Is(err, strconv.ErrRange) {
			rangeFirst++
		}
		fmt.Fprintln(w, "invalid")
	case errors.Is(err, strconv.ErrRange):
		fmt.Fprintln(w, "overflow")
	case err != nil:
		syntaxOdd++
		fmt.Fprintln(w, "invalid")
	default:
		fmt.Fprintln(w, v)
	}
}

func main() {
	g := &gen{x: 7}
	for n := 0; n < cases; n++ {
		pick := g.next()
		base := 2 + g.next()%35
		if pick%2 == 0 {
			base = common[pick/2%4]
		}
		check(base, g.randomCase(base))
	}
	zeros := strings.Repeat("0", 70)
	for base := int64(2); base < 37; base++ {
		max := strconv.FormatInt(1<<63-1, int(base))
		min := strconv.FormatInt(-1<<63, int(base))
		edges := []string{max, min, min[1:], "+" + min[1:], "-" + max, max + "0", min + "0",
			zeros + max, "-" + zeros + min[1:], "+" + zeros + min[1:], min + "1"}
		for _, e := range edges {
			check(base, []byte(e))
		}
		for b := 0; b < 256; b++ {
			check(base, []byte{byte(b)})
			check(base, []byte{'1', byte(b)})
		}
	}
	values := []int64{0, 1, 9, 10, 11, 99, 100, 101, 999, 1000, 35, 36, 37, 1<<63 - 1, 1<<63 - 2}
	for p := int64(1); p <= (1<<63-1)/10; {
		p *= 10
		values = append(values, p-1, p)
	}
	for n := 0; n < 3000; n++ {
		a := g.next()
		b := g.next()
		c := g.next()
		d := g.next()
		v := a*35184372088832 + b*1073741824 + c*32768 + d
		values = append(values, v>>(g.next()%63))
	}
	for base := int64(2); base < 37; base++ {
		q := int64(1)
		for q <= (1<<63-1)/base {
			q *= base
			values = append(values, q-1, q)
		}
		for _, v := range values {
			for _, x := range []int64{v, -v, -v - 1} {
				f := strconv.FormatInt(x, int(base))
				fmt.Fprintln(w, base, f, strings.ToUpper(f))
			}
		}
		for len(values) > 0 && q > 1 {
			q /= base
			values = values[:len(values)-2]
		}
	}
	w.Flush()
	fmt.Fprintf(os.Stderr, "%d strings overflow before a bad byte; %d strings of a sign and digits Go rejects\n", rangeFirst, syntaxOdd)
}
EOF

rig build --release -o prog main.rig || fail "build"
./prog >rig.out 2>rig.err; expect_rc $? 0 "rig run: $(head -c 2000 rig.err)"
GOFLAGS= go run main.go >go.out 2>go.err || fail "go run: $(head -c 2000 go.err)"
lines=$(wc -l <go.out | tr -d ' ')
[[ $lines -gt 450000 ]] || fail "go printed only $lines lines"
expect_has "$(cat go.err)" " 0 strings of a sign and digits Go rejects" "Go's syntax"
if ! cmp -s rig.out go.out; then
    diff rig.out go.out | head -c 3000
    fail "text.parse_int or format_int differs from Go's strconv"
fi
for kind in invalid overflow; do
    n=$(grep -c " $kind\$" go.out)
    [[ $n -gt 1000 ]] || fail "only $n lines are $kind"
done
echo "$lines lines agree with $(go version); $(cat go.err)"
