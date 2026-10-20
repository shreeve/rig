# Benchmarks

Every number here comes from the repository's benchmark scripts, run on
2026-10-20 at Rig's main branch, on two machines: an Apple M5 with 10
cores (macOS, arm64), and a 22-core Linux machine (x86-64). Each table
is one run of its script, which builds and times all three runtimes in
turn, so they compare like with like. Rig builds with `--release=fast`,
Tokio with `cargo build --release` (LTO, one codegen unit) on its
multi-threaded runtime, and Go with `go build`. Each benchmark is the
best of interleaved runs: 7 for tasks and actors, 3 for networking and
HTTP.

## Tasks (`bench/tasks`)

| Benchmark | What it measures |
|---|---|
| spawn | 100 waves of 1,000 tasks that return their index, waited for together; per task |
| chain | 10,000 times: start one task and wait for it; per task |
| fanout | 10 tasks of CPU work at once; per run |
| yield | 100 tasks, each yielding 10,000 times; per yield |
| hog | how long a task waits behind a long computation, while 32 more keep every core busy; per step |
| memory | resident memory per task, with 10,000 tasks asleep |

Apple M5:

| | spawn | chain | fanout | yield | hog | memory |
|---|---|---|---|---|---|---|
| Rig | 105 ns | 44 ns | 78.2 ms | 10 ns | 80.5 µs | 17.0 KiB |
| Tokio | 172 ns | 118 ns | 71.6 ms | 42 ns | 4.3 ms | 264 B |
| Go | 232 ns | 188 ns | 70.8 ms | 245 ns | 4.3 ms | 2.9 KiB |

Linux, 22 cores:

| | spawn | chain | fanout | yield | hog | memory |
|---|---|---|---|---|---|---|
| Rig | 251 ns | 80 ns | 107.8 ms | 8 ns | 77.2 µs | 5.2 KiB |
| Tokio | 284 ns | 250 ns | 102.9 ms | 47 ns | 2.3 ms | 355 B |
| Go | 296 ns | 271 ns | 92.7 ms | 440 ns | 2.0 ms | 2.9 KiB |

Rig is ahead of Tokio and Go in `spawn`, `chain`, `yield` and `hog` on
both machines. It is behind in memory per task, since each task holds
at least one page of its own stack, and in `fanout`, by 5 to 16
percent, a gap in the compiled loop rather than the scheduler.

## Actor calls (`bench/actors`)

A counter, called to add one and give the new count: Rig's actor
against a counter behind Go's `sync.Mutex`, and against a Tokio actor,
a task serving a bounded `mpsc` channel with a `oneshot` for each
answer. Every call waits for its answer.

| Benchmark | What it measures |
|---|---|
| solo | one task calls one counter 1,000,000 times |
| contend | 8 tasks call one counter 100,000 times each |
| spread | 1,000 tasks each make a counter and call it 1,000 times |

Time per call:

| | Rig | Go mutex | Tokio actor |
|---|---|---|---|
| Apple M5, solo | 5.0 ns | 3.5 ns | 135 ns |
| Apple M5, contend | 31 ns | 79 ns | 269 ns |
| Apple M5, spread | 0.9 ns | 0.5 ns | 31 ns |
| Linux, solo | 15 ns | 11 ns | 253 ns |
| Linux, contend | 35 ns | 65 ns | 270 ns |
| Linux, spread | 2.5 ns | 1.4 ns | 16 ns |

The contended numbers swing from run to run in every runtime, since
they depend on whether the counter stays on one core.

## Networking (`bench/net`)

Loopback: a ping-pong and an echo round trip over one connection, and
opening a connection.

| | Rig | Tokio | Go |
|---|---|---|---|
| Apple M5, ping-pong round trip | 14.9 µs | 15.1 µs | 16.2 µs |
| Apple M5, echo round trip | 5.9 µs | 5.6 µs | 5.7 µs |
| Apple M5, connect | 59.7 µs | 61.3 µs | 60.1 µs |
| Linux, ping-pong round trip | 5.2 µs | 5.5 µs | 6.6 µs |
| Linux, echo round trip | 1.08 µs | 2.30 µs | 0.98 µs |
| Linux, connect | 35.9 µs | 30.6 µs | 49.7 µs |

A loopback round trip costs mostly the system calls, so the three stay
close.

## HTTP (`bench/http`)

`GET /` answered with 13 bytes, over 64 keep-alive connections for 3
seconds, from one load generator written in Go and the same for every
server; then the memory of idle connections, per connection: 5,000 on
the Mac and 10,000 on Linux. Rig's server is `http.serve`; Tokio's is
hyper; Go's is `net/http`.

| | req/s | p50 | p99 | per idle connection |
|---|---|---|---|---|
| Apple M5, Rig | 169,215 | 369 µs | 641 µs | 17.0 KiB |
| Apple M5, hyper | 179,227 | 349 µs | 596 µs | 18.6 KiB |
| Apple M5, Go | 162,663 | 364 µs | 1,139 µs | 18.3 KiB |
| Linux, Rig | 830,158 | 54 µs | 437 µs | 9.2 KiB |
| Linux, hyper | 296,728 | 163 µs | 763 µs | 10.8 KiB |
| Linux, Go | 235,075 | 153 µs | 1,492 µs | 18.7 KiB |

The load generator and the server share the machine, as in any loopback
benchmark, so a server that spends less CPU leaves more to the load.
An idle Rig connection holds no read or write buffer; they come from
its worker while it answers a request.

## Reproducing them

Each script builds all three versions and prints a table; `--help`
lists the options. They need `bin/rig` built first (`zig build`), Cargo,
and Go.

```sh
bench/tasks/bench-tasks --reps 7
bench/actors/bench-actors --reps 7
bench/net/bench-net
bench/http/bench-http --idle 5000      # 10000 on Linux
```

Time on a quiet machine: other work skews every number, the contended
ones most. Each directory's README describes its method, and its
PROGRESS.md tracks every measurement since it began.
