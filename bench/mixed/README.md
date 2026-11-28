# Mixed-workload HTTP benchmark, open loop

Times Rig's HTTP server (`http.serve`, docs/STD.md) against hyper on
Tokio and Go's `net/http` under an open-loop load: requests arrive at a
fixed rate whatever the answers, some of them compute, and thousands of
idle keep-alive connections stay open throughout. It is not part of the
test suite or CI.

```sh
bench/mixed/bench-mixed                                  # build, then 5 rounds
bench/mixed/bench-mixed --out DIR --build-only           # build into DIR
bench/mixed/bench-mixed --out DIR --time-only --raw R    # time DIR's builds, rows to R
bench/mixed/bench-mixed --summary R                      # the table for R's rows
```

It needs `bin/rig` built first, Cargo (hyper comes from crates.io), and
Go. `bench/mixed/bench-mixed --help` lists the options.

## Why open loop

bench/http is closed-loop: 64 connections each wait for an answer
before they send again. When a server stalls, the load generator stalls
with it and sends nothing, so the requests that would have waited are
never sent and never counted (coordinated omission), and its p99
understates what clients would see. Every request there is also
trivial, so it never shows a slow request holding up quick ones.

## What it measures

Each server answers `GET /` with `Hello, world!`, and
`GET /hash?seed=N` with the 64-bit FNV-1a hash of 4 KiB of data, 8
times over, starting from N, as decimal text: about 31 µs of one core
on an Apple M5, the same in all three (a loop of one multiply a byte,
which no compiler can vectorize). The data are the same 4,096 bytes of
a xorshift generator in every server. Each handler is that language's
plain code: the hash runs in the handler, on the task or goroutine
that serves the connection, with no thread pool in any of them.

The load generator, `bench/mixed/load` in Go, is the same for every
server:

- **Idle connections.** It first opens N connections (`--idle`, 5,000
  by default), each makes one request, and they stay open through every
  rate, so the server's poller and scheduler carry them. At the end it
  checks that 100 of them still answer (`idle 100/100` in the output).
  Rig's server closes a connection idle for 60 s and hyper's and Go's
  never do, so Rig's runs with `RIG_HTTP_IDLE_MS=600000`.
  `--idle-apart` holds them from a process of their own instead, to
  tell their cost to the generator from their cost to the server and
  the kernel.
- **Open-loop load, wrk2's method.** For each rate R it opens C more
  connections (`--conns`, 128) and connection c sends its i-th request
  at start + (c + i·C)/R, a schedule fixed in advance. A connection has
  one request in flight at a time (HTTP/1.1 without pipelining), so a
  late answer delays the requests behind it, and each request's latency
  counts from when it was meant to start, not from when it went. A
  stall shows in every request it held back.
- **The mix.** Every 4th request (`--mix`) is `/hash`, the rest `/`.
  The generator checks every answer: the status, and the body against
  the hash it computed itself.
- **The window.** Each rate runs 1 s (`--warmup`) and then 5 s
  (`--duration`) counted. A request meant to start in the counted
  window but still unsent when it closes counts with the latency it had
  reached then, so past saturation the latencies are lower bounds.
- **The figures.** Achieved throughput (answers a second in the
  window), the 50th, 99th and 99.9th percentile and the largest
  latency, the 99th percentile of `/` and of `/hash` apart, the
  generator's own lateness (how late it sent a request whose
  connection was free at its time: the floor under every latency), and
  the cores each
  process used over the window: the server's from its CPU time, read by
  bench-mixed when the generator marks the window's ends, and the
  generator's own.
- **Rounds.** A round starts each server once, fresh, and runs it
  through every rate in increasing order; the order of the servers
  rotates by one each round. The table gives, for each rate and server,
  the median over the rounds and, in brackets, the best (the highest
  throughput, the lowest latency).

Every run prints a line with the date, the load average, the commit and
the machine first (`# bench-mixed ...`).

## Its limits

- **The load generator shares the machine.** On a loopback benchmark it
  must: a server that spends less CPU leaves more to the generator, and
  the generator's own work (one thread that reads the clock in a loop
  and writes each request at its time, and one goroutine per connection
  that reads the answers) takes cores the servers would otherwise have,
  one of them whole. Its lateness is reported so the floor is visible:
  about 5 µs at the 99th percentile on Linux. On the Mac the one thread
  that writes every request is later, about 100 µs at 55,000 a second
  and 470 to 650 at 100,000, where the sleeping generator's was 45 and
  280: read the lateness column before a Mac tail.
- **A generator that sleeps is not on time.** Until 2026-11-17 each
  connection's goroutine slept until its next request (`-pace sleep`
  still does). Go's timers wait in epoll, whose timeouts are whole
  milliseconds, so a sleeper woke up to a millisecond late whenever
  every thread of the generator was idle, and how often that was
  depended on how the server's answers arrived: on pup at 80,000 a
  second on one core its lateness was 585 µs at the 99th percentile
  against Rig and 242 against hyper, and each server's p99 was that
  lateness plus a constant (920 and 650 µs). Sent on time, the two
  are level (50 and 51 µs). PROGRESS.md's rows before that date carry
  the sleeping generator's lateness in their p99 and p99.9.
- **One machine's loopback** has no network delay or loss, and its
  system calls dominate a trivial request's cost.
- **Saturation** here is the machine's, server and generator together,
  not the server's alone.
- **Rates are uniform,** as in wrk2, not Poisson; real arrivals are
  burstier.
- **Idle connections cost every server alike.** On the Mac the 5,000
  idle connections raise p99.9 at 20,000 a second from about 150 µs to
  about 900 µs in all three servers, wherever the client ends are held:
  a floor of the machine's, under which no server's lead shows.
- **128 load connections.** A schedule's slots per connection are C/R
  apart (1.3 ms at 100,000 a second), so a connection rarely has a
  request in flight when its next is due, until the server falls behind.

## Timing on the Mac

Timing runs only under `cpuq drain`, with builds as `cpuq run`s
(AGENTS.md, "Timing on the Mac"); each drain is at most 20 minutes,
so a run of more rounds is several drains appending to one
`--raw` file, then `--summary`:

```sh
O=/tmp/bench-mixed; R=$O/raw.jsonl
cpuq run --label rig:bench-mixed-build -- bench/mixed/bench-mixed --out $O --build-only
cpuq drain --all --label rig:bench-mixed -- bench/mixed/bench-mixed --out $O --time-only --rounds 5 --raw $R
bench/mixed/bench-mixed --summary $R
```

## On Linux

Pinned to cores 0-11 on every timed command (a slot's shell otherwise
runs on two low-power cores), with more rates, since the machine has
more cores:

```sh
O=/zfs/trig-pup/bench-mixed; R=$O/raw.jsonl
taskset -c 12-19 bench/mixed/bench-mixed --out $O --build-only
taskset -c 0-11 bench/mixed/bench-mixed --out $O --time-only --rounds 5 --idle 10000 \
  --rates 50000,100000,150000,200000,250000,300000,350000 --raw $R
bench/mixed/bench-mixed --summary $R
```

The build runs on the E-cores, the timing in a pup timing slot
(AGENTS.md, "Sharing pup"), and outputs go on `/zfs`, never the shared
`/tmp`. The rates are a first guess; a first round finds saturation.

## Where it stands

The rows are in [PROGRESS.md](PROGRESS.md), and the first measurement
and what it found are in
[docs/history/records/2026-11/concurrency-mixed/](../../docs/history/records/2026-11/concurrency-mixed/README.md).
