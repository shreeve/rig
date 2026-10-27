// Go's built-in map (a SwissTable since Go 1.24: groups of 8 slots
// scanned a word at a time, tables of at most 1,024 slots under a
// directory that grows a table at a time), timed as
// bench/hash/rust/src/main.rs times hashbrown, every row of
// bench/hash/WORKLOADS.md, with its own hash (the runtime's, AES-based
// where the CPU has AES); Go takes no hash of the program's. A remove is
// a lookup and a delete, as Go has no operation that does both. `go
// build -o go map.go`; prints `KEYS OP NS CHECK` per line, or with the
// argument `mem` (`mem0`) builds one map of 4,000,000 keys (the keys
// alone) for its peak memory.
package main

import (
	"fmt"
	"os"
	"strconv"
	"time"
)

const mul int64 = -7046029254386353131
const n int64 = 1_000_000

func out(keys, op string, ns, check int64) {
	fmt.Printf("%s %s %d %d\n", keys, op, ns, check)
}

// Keeps the maps alive until the timing is done, as Rust's black_box does.
var sink any

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

// text(n) of bench/hash/WORKLOADS.md: 7 to 27 bytes, distinct by the
// part after #.
func text(n int64) string {
	return strconv.FormatUint(uint64(scatter(n))>>(n%48), 10) + "#" + strconv.FormatInt(n, 10)
}

// big(i): eight integers from i.
func big(i int64) [8]int64 {
	return [8]int64{i, i + 1, i + 2, i + 3, i + 4, i + 5, i + 6, i + 7}
}

// 0, 1, ..., s - 1, shuffled.
func shuffledRange(s int64) []int64 {
	p := make([]int64, s)
	for i := range p {
		p[i] = int64(i)
	}
	shuffle(p)
	return p
}

// One lookup at a time, each waiting for the last: the map is one cycle
// through its keys, in shuffled order. Each key scatter(i) is put in
// order of i, with the key after it in the cycle as its value, so a map
// that keeps its entries in order meets them out of order.
func latency(s int64) {
	total := 4 * n
	p := shuffledRange(s)
	m := map[int64]int64{}
	next := make([]int64, s)
	for t := int64(0); t < s; t++ {
		next[p[t]] = p[(t+1)%s]
	}
	for i := int64(0); i < s; i++ {
		m[scatter(i)] = scatter(next[i])
	}
	key := scatter(p[0])
	t := time.Now()
	for r := int64(0); r < total; r++ {
		key = m[key]
	}
	out(fmt.Sprintf("lat%d", s), "chain", time.Since(t).Nanoseconds()*n/total, key)
}

// A map of s keys turned over: each step removes the oldest key and
// inserts a new one.
func churn(s int64) {
	total := 4 * n
	turns := total / 2
	keys := make([]int64, s+turns)
	for i := range keys {
		keys[i] = scatter(int64(i))
	}
	m := map[int64]int64{}
	for i := int64(0); i < s; i++ {
		m[keys[i]] = i
	}
	var check int64
	t := time.Now()
	for i := int64(0); i < turns; i++ {
		key := keys[i]
		if v, ok := m[key]; ok {
			check += v
			delete(m, key)
		}
		m[keys[s+i]] = s + i
	}
	ns := time.Since(t).Nanoseconds()
	sink = m
	sink = nil
	out(fmt.Sprintf("churn%d", s), "turnover", ns*n/total, check)
}

// Lookups that hit half the time, in shuffled order.
func mixed(s int64) {
	total := 4 * n
	m := map[int64]int64{}
	for i := int64(0); i < s; i++ {
		m[scatter(i)] = i
	}
	look := make([]int64, s)
	for i := range look {
		if i%2 == 0 {
			look[i] = scatter(int64(i))
		} else {
			look[i] = scatter(8*n + int64(i))
		}
	}
	shuffle(look)
	var sum int64
	t := time.Now()
	for r := int64(0); r < total/s; r++ {
		for _, key := range look {
			if v, ok := m[key]; ok {
				sum += v
			}
		}
	}
	out(fmt.Sprintf("mix%d", s), "half", time.Since(t).Nanoseconds()*n/total, sum)
}

// Text keys, each put into the map and found by an equal text made
// apart; a million operations a row.
func strings(s int64) {
	k := int64(1)
	if s < n {
		k = n / s
	}
	reps := n / (k * s)
	name := fmt.Sprintf("str%d", s)
	var ins, rem time.Duration
	var check int64
	for r := int64(0); r < reps; r++ {
		put := make([]string, k*s)
		take := make([]string, k*s)
		for i := range put {
			put[i] = text(int64(i))
		}
		for i := range take {
			take[i] = text(int64(i))
		}
		maps := make([]map[string]int64, k)
		for j := range maps {
			maps[j] = map[string]int64{}
		}
		t := time.Now()
		for j, m := range maps {
			for i, key := range put[int64(j)*s : int64(j+1)*s] {
				m[key] = int64(i)
			}
		}
		ins += time.Since(t)
		put = nil
		t = time.Now()
		for j, m := range maps {
			for _, key := range take[int64(j)*s : int64(j+1)*s] {
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
	out(name, "insert", ins.Nanoseconds(), reps*k*s)
	out(name, "remove", rem.Nanoseconds(), check)
	m := map[string]int64{}
	for i := int64(0); i < s; i++ {
		m[text(i)] = i
	}
	hit := make([]string, s)
	for i, p := range shuffledRange(s) {
		hit[i] = text(p)
	}
	miss := make([]string, s)
	for i := range miss {
		miss[i] = text(8*n + int64(i))
	}
	var sum int64
	t := time.Now()
	for r := int64(0); r < n/s; r++ {
		for _, key := range hit {
			if v, ok := m[key]; ok {
				sum += v
			}
		}
	}
	out(name, "hit", time.Since(t).Nanoseconds(), sum)
	var found int64
	t = time.Now()
	for r := int64(0); r < n/s; r++ {
		for _, key := range miss {
			if _, ok := m[key]; ok {
				found++
			}
		}
	}
	out(name, "miss", time.Since(t).Nanoseconds(), found)
}

// random's insert, remove, hit and iterate with a value of eight
// integers.
func bigs(s int64) {
	total := 4 * n
	k := int64(1)
	if s < n {
		k = n / s
	}
	reps := total / (k * s)
	name := fmt.Sprintf("big%d", s)
	keys := make([]int64, k*s)
	for i := range keys {
		keys[i] = scatter(int64(i))
	}
	var ins, rem time.Duration
	var check int64
	for r := int64(0); r < reps; r++ {
		maps := make([]map[int64][8]int64, k)
		for j := range maps {
			maps[j] = map[int64][8]int64{}
		}
		t := time.Now()
		for j, m := range maps {
			for i, key := range keys[int64(j)*s : int64(j+1)*s] {
				m[key] = big(int64(i))
			}
		}
		ins += time.Since(t)
		t = time.Now()
		for j, m := range maps {
			for _, key := range keys[int64(j)*s : int64(j+1)*s] {
				if v, ok := m[key]; ok {
					check += v[7]
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
	m := map[int64][8]int64{}
	for i, key := range keys[:s] {
		m[key] = big(int64(i))
	}
	hit := append([]int64(nil), keys[:s]...)
	shuffle(hit)
	var sum int64
	t := time.Now()
	for r := int64(0); r < total/s; r++ {
		for _, key := range hit {
			if v, ok := m[key]; ok {
				sum += v[7]
			}
		}
	}
	out(name, "hit", scale(time.Since(t)), sum)
	sum = 0
	t = time.Now()
	for r := int64(0); r < total/s; r++ {
		for _, v := range m {
			sum += v[0]
		}
	}
	out(name, "iterate", scale(time.Since(t)), sum)
}

// mem: one map of 4,000,000 keys, for its peak memory; mem0: the keys
// alone, the baseline.
func memory(withMap bool) {
	const count = 4_000_000
	keys := make([]int64, count)
	for i := range keys {
		keys[i] = scatter(int64(i))
	}
	if !withMap {
		fmt.Printf("mem0 %d len %d\n", count, len(keys))
		return
	}
	m := map[int64]int64{}
	for i, key := range keys {
		m[key] = int64(i)
	}
	fmt.Printf("mem %d len %d\n", count, len(m))
}

func main() {
	if len(os.Args) > 1 && (os.Args[1] == "mem" || os.Args[1] == "mem0") {
		memory(os.Args[1] == "mem")
		return
	}
	for _, s := range []int64{16, 1000, 100_000, 4_000_000} {
		sized(s)
	}
	for _, s := range []int64{16, 24, 1000, 1500, 100_000, 150_000, 3_000_000, 4_000_000} {
		random(s)
	}
	for _, s := range []int64{16, 1000, 100_000, 4_000_000} {
		latency(s)
	}
	for _, s := range []int64{16, 1000, 100_000, 4_000_000} {
		churn(s)
	}
	for _, s := range []int64{16, 1000, 100_000, 4_000_000} {
		mixed(s)
	}
	for _, s := range []int64{16, 1000, 100_000, 1_000_000} {
		strings(s)
	}
	for _, s := range []int64{16, 1000, 100_000, 1_000_000} {
		bigs(s)
	}
}
