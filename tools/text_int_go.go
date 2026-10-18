// The expected result of the case `text int go` in
// test/rig/std-text-int-go.rig.test: std.text's parse_int and format_int
// against Go's strconv.ParseInt(s, base, 64) and FormatInt. It generates
// the same strings as the case, in bases 2 to 36, writes for each a line
// of the base, the string's bytes in hex, and the value, `invalid`, or
// `overflow`, then the lines of FormatInt in every base and both cases,
// and prints the digest of those lines the case prints. Where the digits
// overflow before a bad byte, Go reports the overflow and std the bad
// byte, as `parse_int` documents: this program gives `invalid` for any
// string that is not a sign and digits.
//
// Regenerate the case's result after changing its strings (here and in
// the case alike):
//
//	go run tools/text_int_go.go

package main

import (
	"bufio"
	"bytes"
	"errors"
	"fmt"
	"os"
	"runtime"
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

var buf bytes.Buffer
var w = bufio.NewWriter(&buf)
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
	if syntaxOdd != 0 {
		fmt.Fprintf(os.Stderr, "%d strings of a sign and digits Go rejects\n", syntaxOdd)
		os.Exit(1)
	}
	// The case's digest: two polynomial hashes of every byte of every line,
	// its newline included, each byte counted as itself plus one.
	var a, b, lines, invalid, overflow int64
	for _, c := range buf.Bytes() {
		a = (a*257 + int64(c) + 1) % 2147483647
		b = (b*263 + int64(c) + 1) % 2147483629
		if c == '\n' {
			lines++
		}
	}
	for _, l := range strings.Split(buf.String(), "\n") {
		if strings.HasSuffix(l, " invalid") {
			invalid++
		} else if strings.HasSuffix(l, " overflow") {
			overflow++
		}
	}
	fmt.Println("lines", lines, "invalid", invalid, "overflow", overflow, "digest", a, b)
	fmt.Fprintf(os.Stderr, "%s; %d strings overflow before a bad byte\n", runtime.Version(), rangeFirst)
}
