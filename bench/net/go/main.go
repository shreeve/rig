// Go's net package timed as bench/net/net.rig times Rig's std.net:
// pingpong, echo, connect. Prints `NAME NS CHECK` per benchmark.
package main

import (
	"fmt"
	"io"
	"net"
	"sync"
	"time"
)

const (
	ping      = 20000
	echoConns = 100
	echoTrips = 1000
	connects  = 500
	size      = 64
)

func echo(c net.Conn) int64 {
	defer c.Close()
	buf := make([]byte, 4096)
	var total int64
	for {
		n, err := c.Read(buf)
		if n > 0 {
			total += int64(n)
			if _, werr := c.Write(buf[:n]); werr != nil {
				return total
			}
		}
		if err != nil {
			return total
		}
	}
}

func serve(l net.Listener, conns int) chan int64 {
	out := make(chan int64, 1)
	go func() {
		var wg sync.WaitGroup
		var mu sync.Mutex
		var sum int64
		for i := 0; i < conns; i++ {
			c, err := l.Accept()
			if err != nil {
				panic(err)
			}
			wg.Add(1)
			go func() {
				n := echo(c)
				mu.Lock()
				sum += n
				mu.Unlock()
				wg.Done()
			}()
		}
		wg.Wait()
		out <- sum
	}()
	return out
}

func client(addr string, msg []byte, trips int) int64 {
	c, err := net.Dial("tcp", addr)
	if err != nil {
		panic(err)
	}
	defer c.Close()
	got := make([]byte, size)
	var back int64
	for i := 0; i < trips; i++ {
		if _, err := c.Write(msg); err != nil {
			panic(err)
		}
		if _, err := io.ReadFull(c, got); err != nil {
			panic(err)
		}
		back += size
	}
	return back
}

func listen() (net.Listener, string) {
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	return l, l.Addr().String()
}

func main() {
	msg := make([]byte, size)
	for i := range msg {
		msg[i] = 'x'
	}
	{
		l, addr := listen()
		s := serve(l, 1)
		t := time.Now()
		back := client(addr, msg, ping)
		ns := time.Since(t).Nanoseconds()
		fmt.Println("pingpong", ns, back+<-s)
		l.Close()
	}
	{
		l, addr := listen()
		s := serve(l, echoConns)
		t := time.Now()
		var wg sync.WaitGroup
		var mu sync.Mutex
		var back int64
		for i := 0; i < echoConns; i++ {
			wg.Add(1)
			go func() {
				n := client(addr, msg, echoTrips)
				mu.Lock()
				back += n
				mu.Unlock()
				wg.Done()
			}()
		}
		wg.Wait()
		ns := time.Since(t).Nanoseconds()
		fmt.Println("echo", ns, back+<-s)
		l.Close()
	}
	{
		l, addr := listen()
		s := serve(l, connects)
		t := time.Now()
		var back int64
		for i := 0; i < connects; i++ {
			back += client(addr, msg, 1)
		}
		ns := time.Since(t).Nanoseconds()
		fmt.Println("connect", ns, back+<-s)
		l.Close()
	}
}
