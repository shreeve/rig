// Go's goroutines timed as bench/tasks/tasks.rig times Rig's tasks:
// spawn, chain, fanout, yield. Prints `NAME NS CHECK` per benchmark.
package main

import (
	"fmt"
	"runtime"
	"sync"
	"time"
)

const (
	waves      = 100
	size       = 1000
	chainN     = 10000
	fanTasks   = 10
	fanWork    = 20000000
	yieldTasks = 100
	yields     = 10000
)

//go:noinline
func leaf(i int64) int64 { return i }

//go:noinline
func spin(n int64) int64 {
	var total int64
	for i := int64(0); i < n; i++ {
		total = (total + i*7) % 1000003
	}
	return total
}

func main() {
	t := time.Now()
	var sum int64
	for w := 0; w < waves; w++ {
		results := make([]int64, size)
		var wg sync.WaitGroup
		for i := 0; i < size; i++ {
			wg.Add(1)
			go func(i int) { results[i] = leaf(int64(i)); wg.Done() }(i)
		}
		wg.Wait()
		for _, x := range results {
			sum += x
		}
	}
	fmt.Println("spawn", time.Since(t).Nanoseconds(), sum)

	t = time.Now()
	sum = 0
	ch := make(chan int64)
	for i := int64(0); i < chainN; i++ {
		go func(i int64) { ch <- leaf(i) }(i)
		sum += <-ch
	}
	fmt.Println("chain", time.Since(t).Nanoseconds(), sum)

	t = time.Now()
	results := make([]int64, fanTasks)
	var wg sync.WaitGroup
	for i := 0; i < fanTasks; i++ {
		wg.Add(1)
		go func(i int) { results[i] = spin(fanWork + int64(i)); wg.Done() }(i)
	}
	wg.Wait()
	sum = 0
	for _, x := range results {
		sum += x
	}
	fmt.Println("fanout", time.Since(t).Nanoseconds(), sum)

	t = time.Now()
	ys := make([]int64, yieldTasks)
	for i := 0; i < yieldTasks; i++ {
		wg.Add(1)
		go func(i int) {
			for j := 0; j < yields; j++ {
				runtime.Gosched()
			}
			ys[i] = yields
			wg.Done()
		}(i)
	}
	wg.Wait()
	sum = 0
	for _, x := range ys {
		sum += x
	}
	fmt.Println("yield", time.Since(t).Nanoseconds(), sum)
}
