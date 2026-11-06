package main

import (
	"fmt"
	"sync"
	"time"
)

const (
	N       = 200
	WORK    = 30000
	REPEATS = 20
)

//go:noinline
func spin(n int) int {
	total := 0
	for i := 0; i < n; i++ {
		total = (total + i*7) % 1000003
	}
	return total
}

func round() (int64, int64, int) {
	t := time.Now()
	res := make([]int, N)
	var wg sync.WaitGroup
	mine := 0
	for i := 0; i < N; i++ {
		wg.Add(1)
		go func(i int) { res[i] = spin(WORK + i); wg.Done() }(i)
		mine = (mine + spin(WORK)) % 1000003
	}
	produced := time.Since(t).Nanoseconds()
	wg.Wait()
	all := time.Since(t).Nanoseconds()
	sum := mine
	for _, x := range res {
		sum = (sum + x) % 1000003
	}
	return produced, all, sum
}

func main() {
	t := time.Now()
	spin(WORK)
	fmt.Println("one", time.Since(t).Nanoseconds())
	var bp, ba int64
	check := 0
	for r := 0; r < REPEATS; r++ {
		p, a, s := round()
		if r == 0 || p < bp {
			bp = p
		}
		if r == 0 || a < ba {
			ba = a
		}
		check = s
	}
	fmt.Println("produce", bp, "all", ba, "check", check)
}
