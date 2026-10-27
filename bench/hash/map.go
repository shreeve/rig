// Go's built-in map (a SwissTable since Go 1.24: groups of 8 slots
// scanned a word at a time, tables of at most 1,024 slots under a
// directory that grows a table at a time), timed as bench/hash/map.rs
// times hashbrown, with its own hash (the runtime's, AES-based where the
// CPU has AES); Go takes no hash of the program's. A remove is a lookup
// and a delete, as Go has no operation that does both. `go build -o go
// map.go`; prints `KEYS OP NS CHECK` per line.
package main

import (
	"fmt"
	"time"
)

const mul int64 = -7046029254386353131
const n int64 = 1_000_000

func out(keys, op string, ns, check int64) {
	fmt.Printf("%s %s %d %d\n", keys, op, ns, check)
}

// Keeps the maps alive until the timing is done, as Rust's black_box does.
var sink []map[int64]int64

func sized(s int64) {
	total := 4 * n
	k := int64(1)
	if s < n {
		k = n / s
	}
	reps := total / (k * s)
	name := fmt.Sprintf("int%d", s)
	var ins, rem time.Duration
	var check int64
	for r := int64(0); r < reps; r++ {
		maps := make([]map[int64]int64, k)
		for j := range maps {
			maps[j] = map[int64]int64{}
		}
		t := time.Now()
		for j, m := range maps {
			base := int64(j) * s
			for i := int64(0); i < s; i++ {
				m[(base+i)*mul] = i
			}
		}
		ins += time.Since(t)
		t = time.Now()
		for j, m := range maps {
			base := int64(j) * s
			for i := int64(0); i < s; i++ {
				key := (base + i) * mul
				if v, ok := m[key]; ok {
					check += v
					delete(m, key)
				}
			}
		}
		rem += time.Since(t)
		sink = maps
	}
	sink = nil
	scale := func(d time.Duration) int64 { return d.Nanoseconds() * n / total }
	out(name, "insert", scale(ins), reps*k*s)
	out(name, "remove", scale(rem), check)
	m := map[int64]int64{}
	for i := int64(0); i < s; i++ {
		m[i*mul] = i
	}
	rounds := total / s
	var sum int64
	t := time.Now()
	for r := int64(0); r < rounds; r++ {
		for i := int64(0); i < s; i++ {
			if v, ok := m[i*mul]; ok {
				sum += v
			}
		}
	}
	out(name, "hit", scale(time.Since(t)), sum)
	var found int64
	t = time.Now()
	for r := int64(0); r < rounds; r++ {
		for i := s; i < 2*s; i++ {
			if _, ok := m[i*mul]; ok {
				found++
			}
		}
	}
	out(name, "miss", scale(time.Since(t)), found)
	sum = 0
	t = time.Now()
	for r := int64(0); r < rounds; r++ {
		for _, v := range m {
			sum += v
		}
	}
	out(name, "iterate", scale(time.Since(t)), sum)
}

// splitmix64's output for n + 1: a bijection, so distinct n give
// distinct keys, scattered over all 64 bits.
func scatter(n int64) int64 {
	z := (uint64(n) + 1) * 0x9e3779b97f4a7c15
	z = (z ^ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ^ (z >> 27)) * 0x94d049bb133111eb
	return int64(z ^ (z >> 31))
}

const seed int64 = 0x5eed

// v shuffled by Fisher-Yates, swap i choosing scatter(seed + i) % (i + 1).
func shuffle(v []int64) {
	for i := len(v) - 1; i > 0; i-- {
		j := int(uint64(scatter(seed+int64(i))) % uint64(i+1))
		v[i], v[j] = v[j], v[i]
	}
}

// The ops of sized on random keys (scatter of 0, 1, ...), read from
// slices made before the timing; hits look the keys up in shuffled order.
func random(s int64) {
	total := 4 * n
	k := int64(1)
	if s < n {
		k = n / s
	}
	reps := total / (k * s)
	name := fmt.Sprintf("rnd%d", s)
	keys := make([]int64, k*s)
	for i := range keys {
		keys[i] = scatter(int64(i))
	}
	var ins, rem time.Duration
	var check int64
	for r := int64(0); r < reps; r++ {
		maps := make([]map[int64]int64, k)
		for j := range maps {
			maps[j] = map[int64]int64{}
		}
		t := time.Now()
		for j, m := range maps {
			ks := keys[int64(j)*s : int64(j+1)*s]
			for i, key := range ks {
				m[key] = int64(i)
			}
		}
		ins += time.Since(t)
		t = time.Now()
		for j, m := range maps {
			for _, key := range keys[int64(j)*s : int64(j+1)*s] {
				if v, ok := m[key]; ok {
					check += v
					delete(m, key)
				}
			}
		}
		rem += time.Since(t)
		sink = maps
	}
	sink = nil
	scale := func(d time.Duration) int64 { return d.Nanoseconds() * n / total }
	out(name, "insert", scale(ins), reps*k*s)
	out(name, "remove", scale(rem), check)
	m := map[int64]int64{}
	for i, key := range keys[:s] {
		m[key] = int64(i)
	}
	hit := append([]int64(nil), keys[:s]...)
	shuffle(hit)
	miss := make([]int64, s)
	for i := range miss {
		miss[i] = scatter(8*n + int64(i))
	}
	rounds := total / s
	var sum int64
	t := time.Now()
	for r := int64(0); r < rounds; r++ {
		for _, key := range hit {
			if v, ok := m[key]; ok {
				sum += v
			}
		}
	}
	out(name, "hit", scale(time.Since(t)), sum)
	var found int64
	t = time.Now()
	for r := int64(0); r < rounds; r++ {
		for _, key := range miss {
			if _, ok := m[key]; ok {
				found++
			}
		}
	}
	out(name, "miss", scale(time.Since(t)), found)
	sum = 0
	t = time.Now()
	for r := int64(0); r < rounds; r++ {
		for _, v := range m {
			sum += v
		}
	}
	out(name, "iterate", scale(time.Since(t)), sum)
}

func main() {
	for _, s := range []int64{16, 1000, 100_000, 4_000_000} {
		sized(s)
	}
	for _, s := range []int64{16, 1000, 100_000, 4_000_000} {
		random(s)
	}
}
