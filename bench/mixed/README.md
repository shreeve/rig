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
  generator's own timer lateness (how late it woke for a request it was
  waiting to send: the floor under every latency), and the cores each
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
  the generator's own work (one goroutine per connection, a timer per
  request) takes cores the servers would otherwise have. Its timer
  lateness is reported so the floor is visible.
- **One machine's loopback** has no network delay or loss, and its
  system calls dominate a trivial request's cost.
- **Saturation** here is the machine's, server and generator together,
  not the server's alone.
- **Rates are uniform,** as in wrk2, not Poisson; real arrivals are
  burstier.
- **128 load connections.** A schedule's slots per connection are C/R
  apart (1.3 ms at 100,000 a second), so a connection rarely has a
  request in flight when its next is due, until the server falls behind.

## Timing on the Mac

Timing runs only under `tools/mac-claim`, with builds through
`tools/heavy` (AGENTS.md, "Timing on the Mac"); each claim is at most
20 minutes, so a run of more rounds is several claims appending to one
`--raw` file, then `--summary`:

```sh
O=/tmp/bench-mixed; R=$O/raw.jsonl
tools/heavy bench/mixed/bench-mixed --out $O --build-only
tools/mac-claim bench-mixed bench/mixed/bench-mixed --out $O --time-only --rounds 5 --raw $R
bench/mixed/bench-mixed --summary $R
```

## On Linux

Pinned to cores 0-11 on every timed command (a slot's shell otherwise
runs on two low-power cores), with more rates, since the machine has
more cores:

```sh
O=/zfs/bench-mixed; R=$O/raw.jsonl
taskset -c 12-19 bench/mixed/bench-mixed --out $O --build-only
taskset -c 0-11 bench/mixed/bench-mixed --out $O --time-only --rounds 5 --idle 10000 \
  --rates 50000,100000,150000,200000,250000,300000,350000 --raw $R
bench/mixed/bench-mixed --summary $R
```

## Where it stands

The rows are in [PROGRESS.md](PROGRESS.md), and the first measurement
and what it found are in
[docs/history/records/2026-11/concurrency-mixed/](../../docs/history/records/2026-11/concurrency-mixed/README.md).
