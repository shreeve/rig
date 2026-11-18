// The open-loop load generator of bench/mixed/bench-mixed, the same for
// every server.
//
//	load -addr A -rates R1,R2,... [-conns C] [-duration D] [-warmup W]
//	     [-mix K] [-idle N]
//	load -addr A -idle N    hold N idle connections only: prints
//	                        `ready` once all are open, and holds them
//	                        until stdin closes
//
// It first opens N idle connections, each making one request and then
// holding open until the end. Then, for each rate R in turn, it opens C
// connections and sends R requests a second over them, for W and then
// D, at fixed times that do not depend on the answers (wrk2's method):
// connection c sends its i-th request at start + (c + i*C)/R. A
// connection sends one request at a time, so when an answer comes late
// the next request goes as soon as it can, and its latency counts from
// the time it was meant to start, not from when it went: a stall shows
// in every request it delayed (no coordinated omission). Every K-th
// request is `GET /hash?seed=S` (S below 64), whose answer is checked
// against the hash computed here, and the rest `GET /`. Requests meant
// to start in the first W are not counted. A request meant to start in
// the window but not sent by its end counts with the latency it had
// reached then, a lower bound.
//
// The requests are sent by one pacing thread that never sleeps: it reads
// the clock in a loop and writes each request at its time, so a request
// leaves within a few microseconds of when it was meant to (`-pace
// spin`, the default). A sleeping generator is not on time: Go's timers
// wait in epoll, whose timeouts are whole milliseconds, so a goroutine
// asleep until its next request wakes up to a millisecond late whenever
// every thread of the generator is idle, and how often that is depends
// on how the server's answers arrive. `-pace sleep` paces that way, one
// sleeping goroutine a connection, as this generator did until
// 2026-11-17: against servers on pup its timer woke 50 to 700 µs late
// at the 99th percentile, by the server, and each server's p99 was that
// lateness plus a constant.
//
// For each rate it prints `mark` as its counted window opens and again
// as it closes, then one line, latencies in microseconds:
//
//	RATE ACHIEVED SENT UNSENT ERRORS P50 P99 P999 MAX TRIVIAL_P99
//	COMPUTE_P99 TIMER_P99 LOAD_CORES
//
// ACHIEVED is answers a second over the window; TIMER_P99 is how late
// this generator sent a request whose connection was free at its time,
// the floor under every latency; LOAD_CORES is the CPU time this
// generator spent over the window, in cores.
// Last it checks 100 of the idle connections still answer, and prints
// `idle OK/CHECKED`.
package main

import (
	"bufio"
	"bytes"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"runtime"
	"runtime/debug"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

// The data and the hash every server computes for `/hash`.
func makeData() []byte {
	data := make([]byte, 4096)
	x := uint64(0x9E3779B97F4A7C15)
	for i := range data {
		x ^= x << 13
		x ^= x >> 7
		x ^= x << 17
		data[i] = byte(x)
	}
	return data
}

func fnv1a(data []byte, seed uint64, rounds int) uint64 {
	h := uint64(14695981039346656037) ^ seed
	for r := 0; r < rounds; r++ {
		for _, b := range data {
			h ^= uint64(b)
			h *= 1099511628211
		}
	}
	return h
}

const seeds = 64

var (
	trivialReq = []byte("GET / HTTP/1.1\r\nHost: bench\r\n\r\n")
	trivialAns = []byte("Hello, world!")
	computeReq [seeds][]byte
	computeAns [seeds][]byte
)

// Send req on c and read its answer whole; fail unless its body is want.
func roundTrip(c net.Conn, r *bufio.Reader, req, want []byte, body []byte) ([]byte, error) {
	if _, err := c.Write(req); err != nil {
		return body, err
	}
	return readAnswer(r, want, body)
}

// Read one answer whole; fail unless its body is want.
func readAnswer(r *bufio.Reader, want []byte, body []byte) ([]byte, error) {
	length := -1
	status := ""
	for {
		line, err := r.ReadSlice('\n')
		if err != nil {
			return body, err
		}
		if status == "" {
			status = string(line)
			continue
		}
		if len(line) == 2 && line[0] == '\r' {
			break
		}
		if k, v, ok := strings.Cut(string(line), ":"); ok && strings.EqualFold(strings.TrimSpace(k), "content-length") {
			length, _ = strconv.Atoi(strings.TrimSpace(v))
		}
	}
	if length < 0 {
		return body, fmt.Errorf("no content-length")
	}
	if cap(body) < length {
		body = make([]byte, length)
	}
	body = body[:length]
	if _, err := io.ReadFull(r, body); err != nil {
		return body, err
	}
	if !strings.Contains(status, " 200 ") || !bytes.Equal(body, want) {
		return body, fmt.Errorf("unexpected answer: %q %q", strings.TrimSpace(status), body)
	}
	return body, nil
}

type sample struct {
	lat     time.Duration
	compute bool
}

type connResult struct {
	samples []sample
	timer   []time.Duration
	sent    int
	unsent  int
	done    int // answers that came within the window
	errors  int
	err     error
	read    int // paced: answers read
}

func dial(addr string) net.Conn {
	c, err := net.Dial("tcp", addr)
	if err != nil {
		fmt.Fprintln(os.Stderr, "load: dial:", err)
		os.Exit(1)
	}
	return c
}

// Close by a reset, leaving no client port in TIME_WAIT.
func reset(c net.Conn) {
	c.(*net.TCPConn).SetLinger(0)
	c.Close()
}

// One connection's share of a rate: requests at start + i*interval.
func drive(c net.Conn, idx int, start, counted, end time.Time, interval time.Duration, mix int, res *connResult) {
	r := bufio.NewReaderSize(c, 4096)
	var body []byte
	for i := 0; ; i++ {
		intended := start.Add(time.Duration(i) * interval)
		if !intended.Before(end) {
			return
		}
		now := time.Now()
		if now.After(end) {
			// Meant for the window, never sent: counted at the latency
			// it had reached by the end.
			for ; intended.Before(end); intended = start.Add(time.Duration(i) * interval) {
				if !intended.Before(counted) {
					res.unsent++
					res.samples = append(res.samples, sample{end.Sub(intended), (idx+i)%mix == 0})
				}
				i++
			}
			return
		}
		waited := false
		if intended.After(now) {
			time.Sleep(intended.Sub(now))
			waited = true
		}
		sent := time.Now()
		compute := (idx+i)%mix == 0
		req, want := trivialReq, trivialAns
		if compute {
			s := (idx*7 + i) % seeds
			req, want = computeReq[s], computeAns[s]
		}
		var err error
		body, err = roundTrip(c, r, req, want, body)
		got := time.Now()
		if err != nil {
			res.errors++
			res.err = err
			return
		}
		if intended.Before(counted) {
			continue
		}
		res.sent++
		if !got.After(end) {
			res.done++
		}
		res.samples = append(res.samples, sample{got.Sub(intended), compute})
		if waited {
			res.timer = append(res.timer, sent.Sub(intended))
		}
	}
}

// A connection paced by the pacing thread (`-pace spin`). At most one
// request is on it at a time: `inflight` is held by whoever sends, the
// pacer at a request's time or the reader as an answer comes with
// requests overdue, and let go by the reader once the answer is read.
type paced struct {
	c        net.Conn
	idx      int
	conns    int
	t0       time.Time
	step     float64 // nanoseconds between the rate's requests
	mix      int
	due      atomic.Int32 // requests whose time has come, not yet sent
	inflight atomic.Int32
	next     int // the next request to send; its sender's alone
	res      *connResult
}

var closing atomic.Bool

func (p *paced) intended(i int) time.Time {
	return p.t0.Add(time.Duration(float64(p.idx+i*p.conns) * p.step))
}

func (p *paced) request(i int) (req, want []byte, compute bool) {
	if (p.idx+i)%p.mix == 0 {
		s := (p.idx*7 + i) % seeds
		return computeReq[s], computeAns[s], true
	}
	return trivialReq, trivialAns, false
}

// Send the next request that is due, if the connection is free. From
// the pacer (`onTime`), how late it goes is the generator's own
// lateness (`timer`), which only the pacer appends to.
func (p *paced) pump(onTime bool, counted time.Time) {
	for {
		if !p.inflight.CompareAndSwap(0, 1) {
			return
		}
		if closing.Load() || p.due.Load() == 0 {
			p.inflight.Store(0)
			if closing.Load() || p.due.Load() == 0 {
				return
			}
			continue
		}
		p.due.Add(-1)
		i := p.next
		p.next++
		req, _, _ := p.request(i)
		if _, err := p.c.Write(req); err != nil {
			// The reader's read fails too, and counts it.
			return
		}
		if onTime {
			if at := p.intended(i); !at.Before(counted) {
				p.res.timer = append(p.res.timer, time.Since(at))
			}
		}
		return
	}
}

// Read the answers of one paced connection, in order, until the run
// closes it.
func (p *paced) read(counted, end time.Time) {
	r := bufio.NewReaderSize(p.c, 4096)
	var body []byte
	res := p.res
	for i := 0; ; i++ {
		_, want, compute := p.request(i)
		var err error
		body, err = readAnswer(r, want, body)
		got := time.Now()
		if err != nil {
			if !closing.Load() {
				res.errors++
				res.err = err
			}
			return
		}
		if at := p.intended(i); !at.Before(counted) {
			res.sent++
			if !got.After(end) {
				res.done++
			}
			res.samples = append(res.samples, sample{got.Sub(at), compute})
		}
		res.read = i + 1
		p.inflight.Store(0)
		p.pump(false, counted)
	}
}

// `runRate`'s connections, paced by this thread: request k of the rate
// goes at t0 + k/rate on connection k mod conns, which is each
// connection's i-th at its start + i*interval.
func pace(ps []*paced, t0, counted, end time.Time, rate float64) {
	runtime.LockOSThread()
	defer runtime.UnlockOSThread()
	step := float64(time.Second) / rate
	k := 0
	at := t0
	for {
		now := time.Now()
		if !now.Before(end) {
			return
		}
		for !at.After(now) {
			if !at.Before(end) {
				return
			}
			p := ps[k%len(ps)]
			p.due.Add(1)
			p.pump(true, counted)
			k++
			at = t0.Add(time.Duration(float64(k) * step))
		}
	}
}

func selfCPU() time.Duration {
	var ru syscall.Rusage
	syscall.Getrusage(syscall.RUSAGE_SELF, &ru)
	return time.Duration(ru.Utime.Nano() + ru.Stime.Nano())
}

func pct(xs []time.Duration, p float64) int64 {
	if len(xs) == 0 {
		return 0
	}
	i := int(float64(len(xs)) * p)
	if i >= len(xs) {
		i = len(xs) - 1
	}
	return xs[i].Microseconds()
}

func sorted(xs []time.Duration) []time.Duration {
	sort.Slice(xs, func(i, j int) bool { return xs[i] < xs[j] })
	return xs
}

func runRate(addr string, rate float64, conns int, warmup, duration time.Duration, mix int, spin bool) {
	cs := make([]net.Conn, conns)
	for i := range cs {
		cs[i] = dial(addr)
	}
	interval := time.Duration(float64(conns) / rate * float64(time.Second))
	results := make([]connResult, conns)
	t0 := time.Now().Add(50 * time.Millisecond)
	counted := t0.Add(warmup)
	end := counted.Add(duration)
	var wg sync.WaitGroup
	var ps []*paced
	var paced_done sync.WaitGroup
	if spin {
		// No collection while the pacer runs: a pause would hold a
		// request back. The samples have their room already.
		defer debug.SetGCPercent(debug.SetGCPercent(-1))
		room := int(rate*(warmup+duration).Seconds())/conns + 16
		closing.Store(false)
		for i := range cs {
			results[i].samples = make([]sample, 0, room)
			results[i].timer = make([]time.Duration, 0, room)
			p := &paced{c: cs[i], idx: i, conns: conns, t0: t0, step: float64(time.Second) / rate, mix: mix, res: &results[i]}
			ps = append(ps, p)
			wg.Add(1)
			go func() {
				defer wg.Done()
				p.read(counted, end)
			}()
		}
		paced_done.Add(1)
		go func() {
			defer paced_done.Done()
			pace(ps, t0, counted, end, rate)
		}()
	}
	for i := range cs {
		if spin {
			break
		}
		wg.Add(1)
		go func(i int) {
			defer wg.Done()
			start := t0.Add(interval * time.Duration(i) / time.Duration(conns))
			drive(cs[i], i, start, counted, end, interval, mix, &results[i])
		}(i)
	}
	// The CPU this generator spends over the counted window, and a
	// `mark` line at each end of it, at which bench-mixed reads the
	// server's: running `ps` from here would fork a process that holds
	// every connection, and stall the run.
	time.Sleep(time.Until(counted))
	fmt.Println("mark")
	me0 := selfCPU()
	time.Sleep(time.Until(end))
	fmt.Println("mark")
	me1 := selfCPU()
	if spin {
		// The pacer has stopped at the end; no reader sends once
		// `closing` is set. A connection with a request out is given
		// 5 s for its answer; then every reader's read is ended.
		paced_done.Wait()
		closing.Store(true)
		limit := time.Now().Add(5 * time.Second)
		for _, p := range ps {
			for p.inflight.Load() != 0 && time.Now().Before(limit) {
				time.Sleep(100 * time.Microsecond)
			}
			p.c.SetReadDeadline(time.Now())
		}
		wg.Wait()
		// Meant for the window and not answered: never sent, or sent
		// and still out; counted at the latency reached by the end.
		for _, p := range ps {
			for i := p.res.read; ; i++ {
				at := p.intended(i)
				if !at.Before(end) {
					break
				}
				if !at.Before(counted) {
					_, _, compute := p.request(i)
					p.res.unsent++
					p.res.samples = append(p.res.samples, sample{end.Sub(at), compute})
				}
			}
		}
	}
	wg.Wait()
	for _, c := range cs {
		reset(c)
	}
	var all, trivial, compute, timer []time.Duration
	sent, unsent, done, errors := 0, 0, 0, 0
	for i := range results {
		r := &results[i]
		for _, s := range r.samples {
			all = append(all, s.lat)
			if s.compute {
				compute = append(compute, s.lat)
			} else {
				trivial = append(trivial, s.lat)
			}
		}
		timer = append(timer, r.timer...)
		sent += r.sent
		unsent += r.unsent
		done += r.done
		errors += r.errors
		if r.err != nil {
			fmt.Fprintln(os.Stderr, "load: connection", i, "failed:", r.err)
		}
	}
	all, trivial, compute, timer = sorted(all), sorted(trivial), sorted(compute), sorted(timer)
	var max int64
	if len(all) > 0 {
		max = all[len(all)-1].Microseconds()
	}
	secs := duration.Seconds()
	fmt.Printf("%d %d %d %d %d %d %d %d %d %d %d %d %.2f\n",
		int(rate), int(float64(done)/secs), sent, unsent, errors,
		pct(all, 0.50), pct(all, 0.99), pct(all, 0.999), max,
		pct(trivial, 0.99), pct(compute, 0.99), pct(timer, 0.99),
		(me1-me0).Seconds()/secs)
}

func main() {
	addr := flag.String("addr", "", "the server's address")
	rates := flag.String("rates", "", "requests a second, comma-separated, one run each")
	conns := flag.Int("conns", 128, "connections that carry the load")
	duration := flag.Duration("duration", 5*time.Second, "how long each rate is counted")
	warmup := flag.Duration("warmup", time.Second, "how long each rate runs before it is counted")
	mix := flag.Int("mix", 4, "every K-th request computes")
	idle := flag.Int("idle", 0, "connections to open and hold idle throughout")
	pause := flag.Duration("pause", 500*time.Millisecond, "the pause between rates")
	pacing := flag.String("pace", "spin", "how requests are timed: spin (one thread reading the clock) or sleep (a sleeping goroutine a connection)")
	flag.Parse()
	if *pacing != "spin" && *pacing != "sleep" {
		fmt.Fprintln(os.Stderr, "load: -pace is spin or sleep")
		os.Exit(2)
	}
	data := makeData()
	for s := 0; s < seeds; s++ {
		computeReq[s] = []byte(fmt.Sprintf("GET /hash?seed=%d HTTP/1.1\r\nHost: bench\r\n\r\n", s))
		computeAns[s] = []byte(strconv.FormatUint(fnv1a(data, uint64(s), 8), 10))
	}
	// One address gives a client about 28,000 ports on Linux, so idle
	// connections spread over 127.0.0.1, .2, ... there, every 20,000;
	// macOS has only 127.0.0.1.
	host, port, _ := net.SplitHostPort(*addr)
	held := make([]net.Conn, 0, *idle)
	for i := 0; i < *idle; i++ {
		to := *addr
		if runtime.GOOS == "linux" && host == "127.0.0.1" {
			to = net.JoinHostPort(fmt.Sprintf("127.0.0.%d", 1+i/20000), port)
		}
		c := dial(to)
		if _, err := roundTrip(c, bufio.NewReader(c), trivialReq, trivialAns, nil); err != nil {
			fmt.Fprintln(os.Stderr, "load: idle request:", err)
			os.Exit(1)
		}
		held = append(held, c)
	}
	if *rates == "" {
		// Hold only: say so, and hold until stdin closes.
		fmt.Println("ready")
		io.Copy(io.Discard, os.Stdin)
	}
	for _, f := range strings.Split(*rates, ",") {
		if f == "" {
			continue
		}
		rate, err := strconv.ParseFloat(f, 64)
		if err != nil || rate <= 0 {
			fmt.Fprintln(os.Stderr, "load: bad rate", f)
			os.Exit(2)
		}
		runRate(*addr, rate, *conns, *warmup, *duration, *mix, *pacing == "spin")
		time.Sleep(*pause)
	}
	// The idle connections are still open and answer.
	checked, ok := 0, 0
	if len(held) > 0 {
		step := len(held)/100 + 1
		for i := 0; i < len(held); i += step {
			checked++
			c := held[i]
			c.SetDeadline(time.Now().Add(5 * time.Second))
			if _, err := roundTrip(c, bufio.NewReader(c), trivialReq, trivialAns, nil); err == nil {
				ok++
			}
		}
	}
	fmt.Printf("idle %d/%d\n", ok, checked)
	for _, c := range held {
		reset(c)
	}
}
