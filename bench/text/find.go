// Go's substring search, bytes.Index (strings.Index is the same code,
// internal/bytealg, on a string), timed as bench/text/time.rig times
// std.text's `find`: the same cases, reps, and loop, printed as time.rig
// prints them (`SIZE K KIND NS FOUND`). `go build -o find-go find.go`, then
// `find-go FILE`.
package main

import (
	"bytes"
	"fmt"
	"os"
	"time"
)

// Read after the loops, so no search is dropped as dead.
var sink int

//go:noinline
func caseNs(s, pat []byte, reps int) int64 {
	best := int64(1) << 62
	sum := 0
	for range 5 {
		t0 := time.Now()
		for range reps {
			r := bytes.Index(s, pat)
			if r < 0 {
				r = 7
			}
			sum += r
		}
		ns := time.Since(t0).Nanoseconds()
		best = min(best, ns)
	}
	sink += sum
	return best
}

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: find-go FILE")
		os.Exit(2)
	}
	all, err := os.ReadFile(os.Args[1])
	if err != nil {
		fmt.Fprintln(os.Stderr, "find-go:", err)
		os.Exit(1)
	}
	if len(all) < 8192 {
		fmt.Fprintln(os.Stderr, "find-go: the file is shorter than 8 KiB")
		os.Exit(1)
	}
	for _, size := range []int{8, 16, 32, 64, 1024, 4096, len(all)} {
		start := len(all)/2 + 17
		if size == len(all) {
			start = 0
		}
		s := all[start : start+size]
		for _, k := range []int{1, 3, 12, 40} {
			if k > size {
				continue
			}
			for _, kind := range []string{"early", "late", "miss"} {
				at := (len(s) - k) * 15 / 16
				if kind == "early" {
					at = len(s) / 16
				}
				pat := make([]byte, k)
				for j := range k {
					pat[j] = s[at+j]
					if kind == "miss" && j == k/2 {
						pat[j] = 1
					}
				}
				found := bytes.Index(s, pat)
				work := found
				if found < 0 {
					work = len(s)
				}
				reps := max(100_000_000/(work+64), 16)
				ns := caseNs(s, pat, reps)
				fmt.Println(size, k, kind, float64(ns)/float64(reps), found)
			}
		}
	}
	if sink == -1 {
		fmt.Println()
	}
}
