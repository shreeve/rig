// prog MODE FILE N: N full parses of FILE with Go's encoding/json/v2, timed;
// prints "<ns> <check>", check = the top-level element count summed over
// runs, as the other competitors do. The input is read once, untimed.
//
// Modes:
//   - any: json.Unmarshal into an `any`, a tree of maps, slices, strings,
//     float64s and bools, Go's nearest to std.json's tape.
//   - tokens: one jsontext.Decoder, reset for each run, reading every
//     token; the streaming layer under v2, which allocates no tree. Its
//     check is the number of tokens instead.
//   - v1: encoding/json (v1) Unmarshal into an `any`, for reference.
package main

import (
	"bytes"
	jsonv1 "encoding/json"
	"encoding/json/jsontext"
	json "encoding/json/v2"
	"errors"
	"fmt"
	"io"
	"os"
	"strconv"
	"time"
)

func count(v any) uint64 {
	switch x := v.(type) {
	case []any:
		return uint64(len(x))
	case map[string]any:
		return uint64(len(x))
	}
	return 1
}

func main() {
	if len(os.Args) != 4 {
		fmt.Fprintln(os.Stderr, "usage: prog any|tokens|v1 FILE N")
		os.Exit(2)
	}
	mode := os.Args[1]
	buf, err := os.ReadFile(os.Args[2])
	if err != nil {
		fmt.Fprintln(os.Stderr, "read", os.Args[2])
		os.Exit(2)
	}
	n, _ := strconv.Atoi(os.Args[3])
	var check uint64
	r := bytes.NewReader(buf)
	dec := jsontext.NewDecoder(r)
	start := time.Now()
	for i := 0; i < n; i++ {
		switch mode {
		case "any":
			var v any
			if err := json.Unmarshal(buf, &v); err != nil {
				fmt.Fprintln(os.Stderr, "parse error:", err)
				os.Exit(1)
			}
			check += count(v)
		case "v1":
			var v any
			if err := jsonv1.Unmarshal(buf, &v); err != nil {
				fmt.Fprintln(os.Stderr, "parse error:", err)
				os.Exit(1)
			}
			check += count(v)
		case "tokens":
			r.Reset(buf)
			dec.Reset(r)
			for {
				if _, err := dec.ReadToken(); err != nil {
					if errors.Is(err, io.EOF) {
						break
					}
					fmt.Fprintln(os.Stderr, "parse error:", err)
					os.Exit(1)
				}
				check++
			}
		default:
			fmt.Fprintln(os.Stderr, "mode: any, tokens or v1")
			os.Exit(2)
		}
	}
	fmt.Printf("%d %d\n", time.Since(start).Nanoseconds(), check)
}
