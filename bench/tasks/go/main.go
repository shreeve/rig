// Go's goroutines timed as bench/tasks/tasks.rig times Rig's tasks:
// spawn, chain, fanout, yield, hog. Run as `tasks-go many`, it holds
// many sleeping goroutines at once (many), and as `tasks-go idle`, none,
// sleeping as long. Prints `NAME NS CHECK` per benchmark.
package main

import (
	"fmt"
	"os"
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
	hogTasks   = 32
	hogWork    = 20000000
	hogChain   = 50
	hogSlice   = 1000000
	many       = 10000
	manyNap    = 200 * time.Millisecond
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

func manyTasks() {
	t := time.Now()
	results := make([]int64, many)
	var wg sync.WaitGroup
	for i := 0; i < many; i++ {
		wg.Add(1)
		go func(i int) { time.Sleep(manyNap); results[i] = 1; wg.Done() }(i)
	}
	wg.Wait()
	var sum int64
	for _, x := range results {
		sum += x
	}
	fmt.Println("many", time.Since(t).Nanoseconds(), sum)
}

func main() {
	if len(os.Args) > 1 {
		if os.Args[1] == "many" {
			manyTasks()
		} else {
			t := time.Now()
			time.Sleep(manyNap)
			fmt.Println("idle", time.Since(t).Nanoseconds(), 1)
		}
		return
	}
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

	hogs := make([]int64, hogTasks)
	for i := 0; i < hogTasks; i++ {
		wg.Add(1)
		go func(i int) { hogs[i] = spin(hogWork + int64(i)); wg.Done() }(i)
	}
	slices := make([]int64, hogChain)
	var swg sync.WaitGroup
	t = time.Now()
	sum = 0
	for i := int64(0); i < hogChain; i++ {
		swg.Add(1)
		go func(i int64) { slices[i] = spin(hogSlice + i); swg.Done() }(i)
		go func(i int64) { ch <- leaf(i) }(i)
		go func(i int64) { ch <- leaf(i) }(i)
		sum += <-ch
		sum += <-ch
	}
	ns := time.Since(t).Nanoseconds()
	wg.Wait()
	for _, x := range hogs {
		sum += x
	}
	swg.Wait()
	for _, x := range slices {
		sum += x
	}
	fmt.Println("hog", ns, sum)
}
