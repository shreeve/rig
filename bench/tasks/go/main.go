// Go's goroutines timed as bench/tasks/tasks.rig times Rig's tasks:
// spawn, chain, fanout, yield, hog, produce. Run as `tasks-go many`, it holds
// many sleeping goroutines at once (many), and as `tasks-go idle`, none,
// sleeping as long. Prints `NAME NS CHECK` per benchmark.
package main

import (
	"fmt"
	"os"
	"runtime"
	"strconv"
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
	produceN   = 200
	produceWk  = 10000
	many       = 10000
	manyNap    = 200 * time.Millisecond
	chunks     = 1024
	evenWork   = 61000
	skewBase   = 1200
	allocRound = 4400
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

func manyTasks(nap time.Duration) {
	t := time.Now()
	results := make([]int64, many)
	var wg sync.WaitGroup
	for i := 0; i < many; i++ {
		wg.Add(1)
		go func(i int) { time.Sleep(nap); results[i] = 1; wg.Done() }(i)
	}
	wg.Wait()
	var sum int64
	for _, x := range results {
		sum += x
	}
	fmt.Println("many", time.Since(t).Nanoseconds(), sum)
}

// The scaling benchmarks (bench/tasks/bench-scale), each run alone as
// `tasks-go scale NAME W`, as tasks.rig runs them: W is 1 for the work and
// 0 for none. Each chunk, and each split of the tree, is a goroutine.

func cost(i int64) int64 { return skewBase * (1 + i*7919%100) }

// Each chunk's Lists and Strings go to a slot of its own, so they reach
// the heap as Rig's and Rust's do, and no two goroutines write one slot.
var keepLists [chunks][]int64
var keepStrings [chunks]string

func churn(i int64, rounds int64) int64 {
	var total int64
	for k := int64(0); k < rounds; k++ {
		xs := make([]int64, 0)
		for j := int64(0); j < 16; j++ {
			xs = append(xs, i+j+k)
		}
		s := "item " + strconv.FormatInt(k, 10)
		keepLists[i] = xs
		keepStrings[i] = s
		for _, x := range xs {
			total = (total + x) % 1000003
		}
		total = (total + int64(len(s))) % 1000003
	}
	return total
}

func chunk(name string, i, w int64) int64 {
	switch name {
	case "even":
		return spin(w * (evenWork + i))
	case "skew":
		return spin(w * cost(i))
	default:
		return churn(i, w*allocRound)
	}
}

func tree(lo, hi, w int64) int64 {
	if hi-lo == 1 {
		return spin(w * cost(lo))
	}
	mid := (lo + hi) / 2
	var a int64
	var wg sync.WaitGroup
	wg.Add(1)
	go func() { a = tree(lo, mid, w); wg.Done() }()
	b := tree(mid, hi, w)
	wg.Wait()
	return (b + a) % 1000003
}

func scale(name string, w int64) {
	t := time.Now()
	var check int64
	if name == "tree" {
		check = tree(0, chunks, w)
	} else {
		results := make([]int64, chunks)
		var wg sync.WaitGroup
		for i := int64(0); i < chunks; i++ {
			wg.Add(1)
			go func(i int64) { results[i] = chunk(name, i, w); wg.Done() }(i)
		}
		wg.Wait()
		for _, x := range results {
			check = (check + x) % 1000003
		}
	}
	fmt.Println(name, time.Since(t).Nanoseconds(), check)
}

func main() {
	if len(os.Args) > 3 && os.Args[1] == "scale" {
		w := int64(1)
		if os.Args[3] == "0" {
			w = 0
		}
		scale(os.Args[2], w)
		return
	}
	if len(os.Args) > 1 {
		// `long` sleeps 1 s, long enough for bench-scale to read the
		// memory of the goroutines from outside while they sleep.
		nap := manyNap
		if len(os.Args) > 2 && os.Args[2] == "long" {
			nap = time.Second
		}
		if os.Args[1] == "many" {
			manyTasks(nap)
		} else {
			t := time.Now()
			time.Sleep(nap)
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

	t = time.Now()
	ps := make([]int64, produceN)
	var pwg sync.WaitGroup
	var mine int64
	for i := int64(0); i < produceN; i++ {
		pwg.Add(1)
		go func(i int64) { ps[i] = spin(produceWk + i); pwg.Done() }(i)
		mine = (mine + spin(produceWk)) % 1000003
	}
	ns = time.Since(t).Nanoseconds()
	pwg.Wait()
	sum = mine
	for _, x := range ps {
		sum = (sum + x) % 1000003
	}
	fmt.Println("produce", ns, sum)
}
