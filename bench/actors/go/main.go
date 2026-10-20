// A counter behind Go's sync.Mutex, timed as bench/actors/actors.rig
// times Rig's actors: solo, contend, spread. Every call takes the lock
// and gives the new count. Prints `NAME NS CHECK` per benchmark.
package main

import (
	"fmt"
	"sync"
	"time"
)

const (
	solo         = 1000000
	contendTasks = 8
	contendCalls = 100000
	spreadTasks  = 1000
	spreadCalls  = 1000
)

type counter struct {
	mu   sync.Mutex
	hits int64
}

//go:noinline
func (c *counter) add(n int64) int64 {
	c.mu.Lock()
	c.hits += n
	h := c.hits
	c.mu.Unlock()
	return h
}

func (c *counter) get() int64 {
	c.mu.Lock()
	defer c.mu.Unlock()
	return c.hits
}

func soloBench() {
	c := &counter{}
	t := time.Now()
	var last int64
	for i := 0; i < solo; i++ {
		last = c.add(1)
	}
	fmt.Println("solo", time.Since(t).Nanoseconds(), last)
}

func contendBench() {
	c := &counter{}
	t := time.Now()
	var wg sync.WaitGroup
	for i := 0; i < contendTasks; i++ {
		wg.Add(1)
		go func() {
			for j := 0; j < contendCalls; j++ {
				c.add(1)
			}
			wg.Done()
		}()
	}
	wg.Wait()
	fmt.Println("contend", time.Since(t).Nanoseconds(), c.get())
}

func spreadBench() {
	t := time.Now()
	results := make([]int64, spreadTasks)
	var wg sync.WaitGroup
	for i := 0; i < spreadTasks; i++ {
		wg.Add(1)
		go func(i int) {
			c := &counter{}
			var last int64
			for j := 0; j < spreadCalls; j++ {
				last = c.add(1)
			}
			results[i] = last
			wg.Done()
		}(i)
	}
	wg.Wait()
	var sum int64
	for _, x := range results {
		sum += x
	}
	fmt.Println("spread", time.Since(t).Nanoseconds(), sum)
}

func main() {
	soloBench()
	contendBench()
	spreadBench()
}
