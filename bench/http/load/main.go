// The load generator of bench/http/bench-http, the same for every
// server.
//
//	load -addr A -conns C -duration D   C kept-alive connections, each
//	                                    sending GET / and waiting for the
//	                                    answer, for D; prints
//	                                    `REQUESTS RPS P50_US P99_US`
//	load -addr A -idle N                N connections, each making one
//	                                    request and then holding open;
//	                                    prints `ready` once all are open,
//	                                    and holds until stdin closes
package main

import (
	"bufio"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"runtime"
	"sort"
	"strconv"
	"strings"
	"sync"
	"time"
)

const request = "GET / HTTP/1.1\r\nHost: bench\r\n\r\n"

// Send one request on c and read its answer whole.
func roundTrip(c net.Conn, r *bufio.Reader) error {
	if _, err := io.WriteString(c, request); err != nil {
		return err
	}
	length := -1
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return err
		}
		if line == "\r\n" {
			break
		}
		if k, v, ok := strings.Cut(line, ":"); ok && strings.EqualFold(strings.TrimSpace(k), "content-length") {
			length, _ = strconv.Atoi(strings.TrimSpace(v))
		}
	}
	if length < 0 {
		return fmt.Errorf("no content-length")
	}
	_, err := io.CopyN(io.Discard, r, int64(length))
	return err
}

func main() {
	addr := flag.String("addr", "", "the server's address")
	conns := flag.Int("conns", 64, "connections")
	duration := flag.Duration("duration", 3*time.Second, "how long to send")
	idle := flag.Int("idle", 0, "connections to open and hold")
	flag.Parse()
	if *idle > 0 {
		// One address gives a client about 28,000 ports on Linux, so
		// the connections spread over 127.0.0.1, .2, ... there, every
		// 20,000; macOS has only 127.0.0.1.
		host, port, _ := net.SplitHostPort(*addr)
		held := make([]net.Conn, 0, *idle)
		for i := 0; i < *idle; i++ {
			to := *addr
			if runtime.GOOS == "linux" && host == "127.0.0.1" {
				to = net.JoinHostPort(fmt.Sprintf("127.0.0.%d", 1+i/20000), port)
			}
			c, err := net.Dial("tcp", to)
			if err != nil {
				fmt.Fprintln(os.Stderr, "dial:", err)
				os.Exit(1)
			}
			if err := roundTrip(c, bufio.NewReader(c)); err != nil {
				fmt.Fprintln(os.Stderr, "request:", err)
				os.Exit(1)
			}
			held = append(held, c)
		}
		fmt.Println("ready")
		io.Copy(io.Discard, os.Stdin)
		return
	}
	var mu sync.Mutex
	var all []time.Duration
	var wg sync.WaitGroup
	end := time.Now().Add(*duration)
	for i := 0; i < *conns; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			c, err := net.Dial("tcp", *addr)
			if err != nil {
				panic(err)
			}
			defer c.Close()
			r := bufio.NewReader(c)
			var mine []time.Duration
			for time.Now().Before(end) {
				t := time.Now()
				if err := roundTrip(c, r); err != nil {
					panic(err)
				}
				mine = append(mine, time.Since(t))
			}
			mu.Lock()
			all = append(all, mine...)
			mu.Unlock()
		}()
	}
	wg.Wait()
	sort.Slice(all, func(i, j int) bool { return all[i] < all[j] })
	n := len(all)
	fmt.Println(n, int(float64(n)/duration.Seconds()), all[n/2].Microseconds(), all[n*99/100].Microseconds())
}
