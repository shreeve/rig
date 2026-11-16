# Benchmarks

Every number here comes from the repository's benchmark scripts, run on
2026-11-15 at Rig's main branch (7a2efd0f3) on an Apple M5 with 10
cores (macOS, arm64). Each script builds and times all three runtimes
in turn, so they compare like with like. Rig builds with `--release`
(Zig's safe mode, every check kept), Tokio with `cargo build --release`
(LTO, one codegen unit) on its multi-threaded runtime, and Go with
`go build`. Each number is the fastest of interleaved runs: 14 for
tasks, over two runs of the script, 7 for actors, 10 for networking,
and 6 for HTTP. The raw runs are in
[records/2026-11/concurrency-bench-remeasure/](../history/records/2026-11/concurrency-bench-remeasure/README.md).

The x86-64 Linux numbers wait to be measured with `--release` on the
22-core Linux machine; until then this page gives none.

## Tasks (`bench/tasks`)

| Benchmark | What it measures |
|---|---|
| spawn | 100 waves of 1,000 tasks that return their index, waited for together; per task |
| chain | 10,000 times: start one task and wait for it; per task |
| fanout | 10 tasks of CPU work at once; per run |
| yield | 100 tasks, each yielding 10,000 times; per yield |
| hog | how long a task waits behind a long computation, while 32 more keep every core busy; per step |
| produce | 200 tasks of CPU work made between the maker's own; per run |
| memory | resident memory per task, with 10,000 tasks asleep |

| | spawn | chain | fanout | yield | hog | produce | memory |
|---|---|---|---|---|---|---|---|
| Rig | 133 ns | 51 ns | 65.8 ms | 6 ns | 153 ns | 5.3 ms | 16.6 KiB |
| Tokio | 175 ns | 165 ns | 66.1 ms | 39 ns | 3.3 ms | 6.0 ms | 262 B |
| Go | 228 ns | 199 ns | 67.2 ms | 226 ns | 3.4 ms | 5.8 ms | 2.9 KiB |

Rig is ahead of Tokio and Go in `spawn`, `chain`, `yield`, `hog` and
`produce`, and level in `fanout`. A task behind a long computation
waits for a slice of it, since a signal stops the computation, where in
Tokio and Go it waits for all of it.

It is behind in memory per task, since each task holds at least one
page of its own stack. Counted as the kernel counts a process
(`footprint`, page tables included; `bench/tasks/bench-scale`), a
sleeping task holds 17.1 KiB, 537 B of it page tables, against Tokio's
264 B and Go's 2.9 KiB. That is a task on a dense stack, which a
release build gives every task whose stack the compiler can bound; a
task with recursion or a call through a pointer keeps a large
stack with a page table of its own, about twice that
([the scheduler](../internals/scheduler.md), "Stacks").

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
| solo | 5.0 ns | 3.4 ns | 138 ns |
| contend | 15 ns | 77 ns | 267 ns |
| spread | 0.9 ns | 0.5 ns | 30 ns |

The contended numbers swing from run to run in every runtime, since
they depend on whether the counter stays on one core.

## Networking (`bench/net`)

Loopback: a ping-pong and an echo round trip over one connection, and
opening a connection.

| | Rig | Tokio | Go |
|---|---|---|---|
| ping-pong round trip | 16.4 µs | 13.6 µs | 16.4 µs |
| echo round trip | 8.5 µs | 5.8 µs | 7.3 µs |
| connect | 50.7 µs | 59.7 µs | 61.7 µs |

A loopback round trip costs mostly the system calls. Rig opens a
connection faster than Tokio and Go, and its round trips are slower
than Tokio's: 20% in ping-pong and 47% in echo, where 100 connections
are ready at once.

## HTTP (`bench/http`)

`GET /` answered with 13 bytes, over 64 keep-alive connections for 3
seconds, from one load generator written in Go and the same for every
server; then the memory of 5,000 idle connections, per connection.
Rig's server is `http.serve`; Tokio's is hyper; Go's is `net/http`.

| | req/s | p50 | p99 | per idle connection |
|---|---|---|---|---|
| Rig | 128,402 | 492 µs | 690 µs | 16.7 KiB |
| hyper | 139,202 | 453 µs | 617 µs | 18.6 KiB |
| Go | 120,522 | 521 µs | 1,014 µs | 18.5 KiB |

Rig answers 7.8% fewer requests a second than hyper and 6.5% more than
Go. The memory of an idle connection here is resident memory. Counted
as the kernel counts a process, page tables included, over 2,000 idle
connections, Rig's holds 17.3 KiB, hyper's 18.7 KiB, and Go's 20.2 KiB:
a Rig connection waits on a dense stack and holds no read or write
buffer, which come from its worker while it answers a request.

The load generator and the server share the machine, as in any loopback
benchmark, so a server that spends less CPU leaves more to the load.
The load generator is closed-loop, which understates p99.

## Fork-join

Divide and conquer with `f()&` and `>t` against `rayon::join`, fastest
of 20 interleaved runs: the sum of 2^25 Ints split in halves down to
8,192, and a quicksort of 2^22 Ints that partitions into two owned
Lists, each half a task down to 8,192. The programs are in the record.

| | Rig | Rayon |
|---|---|---|
| parallel sum | 2.83 ms | 2.39 ms |
| quicksort | 80.2 ms | 52.5 ms |

## Reproducing them

Each script builds all three versions and prints a table; `--help`
lists the options. They need `bin/rig` built first (`zig build`), Cargo,
and Go.

```sh
bench/tasks/bench-tasks --reps 7
bench/tasks/bench-scale --variants rig-safe,tokio,go --no-scale
bench/actors/bench-actors --reps 7
bench/net/bench-net --reps 7
bench/http/bench-http --idle 5000      # 10000 on Linux
```

Time on a quiet machine: other work skews every number, the contended
ones most. Each directory's README describes its method, and its
PROGRESS.md tracks every measurement since it began.
