// A Go net/http server for bench/mixed/bench-mixed: `Hello, world!` at
// `/`, and at `/hash?seed=N` the FNV-1a hash of 4 KiB of data, 8 times
// over, starting from N, as decimal text; 404 elsewhere. It prints the
// port it listens on, then serves until it is killed.
package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
	"strconv"
)

// 4 KiB of bytes from a xorshift generator, the same in every server.
func makeData() []byte {
	data := make([]byte, 4096)
	x := uint64(0x9E3779B97F4A7C15)
	for i := range data {
		x ^= x << 13
		x ^= x >> 7
		x ^= x << 17
		data[i] = byte(x)
	}
	return data
}

// FNV-1a, 64 bits, over data rounds times, starting from seed.
func fnv1a(data []byte, seed uint64, rounds int) uint64 {
	h := uint64(14695981039346656037) ^ seed
	for r := 0; r < rounds; r++ {
		for _, b := range data {
			h ^= uint64(b)
			h *= 1099511628211
		}
	}
	return h
}

func main() {
	addr := "127.0.0.1:0"
	if len(os.Args) > 1 {
		addr = os.Args[1]
	}
	data := makeData()
	l, err := net.Listen("tcp", addr)
	if err != nil {
		panic(err)
	}
	fmt.Println(l.Addr().(*net.TCPAddr).Port)
	mux := http.NewServeMux()
	mux.HandleFunc("/{$}", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("content-type", "text/plain; charset=utf-8")
		w.Write([]byte("Hello, world!"))
	})
	mux.HandleFunc("/hash", func(w http.ResponseWriter, r *http.Request) {
		seed, _ := strconv.ParseInt(r.URL.Query().Get("seed"), 10, 64)
		w.Header().Set("content-type", "text/plain; charset=utf-8")
		w.Write([]byte(strconv.FormatUint(fnv1a(data, uint64(seed), 8), 10)))
	})
	http.Serve(l, mux)
}
