// The same server in Go: a hit counter every request shares, rooms
// people join, and one route that panics. Run it with `go run .`, then
// `curl localhost:8080/hit`, `/join?room=rig`, `/boom`.
package main

import (
	"fmt"
	"log"
	"net/http"
	"os"
	"sync"
	"sync/atomic"
)

type Rooms struct {
	mu      sync.Mutex
	members map[string]int
}

func (r *Rooms) Join(room string) int {
	r.mu.Lock()
	defer r.mu.Unlock()
	r.members[room]++
	return r.members[room]
}

func pick(xs []int, i int) int {
	return xs[i]
}

// net/http recovers a handler's panic by closing the connection without
// an answer, so a 500 takes a wrapper of our own.
func recoverer(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		defer func() {
			if err := recover(); err != nil {
				log.Printf("panic: %v", err)
				http.Error(w, "internal error", http.StatusInternalServerError)
			}
		}()
		next.ServeHTTP(w, r)
	})
}

func main() {
	addr := "127.0.0.1:8080"
	if len(os.Args) > 1 {
		addr = os.Args[1]
	}
	var hits atomic.Int64
	rooms := &Rooms{members: map[string]int{}}

	mux := http.NewServeMux()
	mux.HandleFunc("/hit", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "hits %d", hits.Add(1))
	})
	mux.HandleFunc("/join", func(w http.ResponseWriter, r *http.Request) {
		room := r.URL.Query().Get("room")
		if room == "" {
			room = "lobby"
		}
		fmt.Fprintf(w, "members %d", rooms.Join(room))
	})
	mux.HandleFunc("/boom", func(w http.ResponseWriter, r *http.Request) {
		fmt.Fprintf(w, "%d", pick([]int{1, 2, 3}, 7))
	})
	log.Fatal(http.ListenAndServe(addr, recoverer(mux)))
}
