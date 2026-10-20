// A Go net/http server for bench/http/bench-http: `Hello, world!` at
// `/`, 404 elsewhere. It prints the port it listens on, then serves
// until it is killed.
package main

import (
	"fmt"
	"net"
	"net/http"
	"os"
)

func main() {
	addr := "127.0.0.1:0"
	if len(os.Args) > 1 {
		addr = os.Args[1]
	}
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
	http.Serve(l, mux)
}
