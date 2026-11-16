# Benchmarks

Every number here comes from the repository's benchmark scripts, run on
2026-11-15 at Rig's main branch (7a2efd0f3) on an Apple M5 with 10
cores (macOS, arm64). Each script builds and times all three runtimes
in turn, so they compare like with like. Rig builds with `--release`
(Zig's safe mode, every check kept), Tokio with `cargo build --release`
(LTO, one codegen unit) on its multi-threaded runtime, and Go with
`go build`. Rig has no faster mode with its checks off, and the
comparison wants none: Rust's `--release` keeps its bounds checks, and
Rig's keeps its bounds and overflow checks, so each side is measured as
it ships, and a check that costs time is answered by the compiler
proving it away, never by turning it off. Each number is the fastest
of interleaved runs: 14 for
tasks, over two runs of the script, 7 for actors, 10 for networking,
and 6 for HTTP. The raw runs are in
[records/2026-11/concurrency-bench-remeasure/](../history/records/2026-11/concurrency-bench-remeasure/README.md).

The Linux numbers come from a 22-core Intel Core Ultra 9 185H (x86-64,
6 P-cores with two threads each, 8 E-cores and 2 low-power cores), at
bfd872b6d and 1f35fc1da, whose compiler and runtime are 7a2efd0f3's.
Every runtime runs on the same cores, the P-cores 0-11 (`taskset`), the
fastest of 7 interleaved runs for tasks, actors and networking.

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

On Linux:

| | spawn | chain | fanout | yield | hog | produce | memory |
|---|---|---|---|---|---|---|---|
| Rig | 168 ns | 100 ns | 59.6 ms | 6 ns | 316 ns | 6.0 ms | 4.7 KiB |
| Tokio | 236 ns | 213 ns | 65.4 ms | 32 ns | 3.2 ms | 5.5 ms | 373 B |
| Go | 210 ns | 234 ns | 55.1 ms | 244 ns | 3.0 ms | 4.9 ms | 2.8 KiB |

There Rig leads in `spawn`, `chain`, `yield` and `hog`, and is behind
in `produce`, 9% slower than Tokio and 22% slower than Go; Go leads
`fanout`, where Rig is 10% ahead of Tokio. A sleeping task, counted
with its page tables, holds 5.2 KiB, 521 B of it page tables, against
Tokio's 391 B and Go's 2.8 KiB: a page is 4 KiB there, against the
Mac's 16 KiB.

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

On Linux:

| | Rig | Go mutex | Tokio actor |
|---|---|---|---|
| solo | 11 ns | 11 ns | 241 ns |
| contend | 24 ns | 52 ns | 232 ns |
| spread | 2.0 ns | 1.8 ns | 25 ns |

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

On Linux:

| | Rig | Tokio | Go |
|---|---|---|---|
| ping-pong round trip | 5.30 µs | 4.90 µs | 5.53 µs |
| echo round trip | 1.10 µs | 1.29 µs | 0.96 µs |
| connect | 25.2 µs | 31.3 µs | 43.1 µs |

There Rig's ping-pong is 8% slower than Tokio's, its echo 15% shorter,
and it opens a connection fastest of the three.

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

On Linux, on the P-cores 0-11, with 10,000 idle connections, the fastest
of 18 runs over six slots, and hyper also at 6 workers, its best on
those cores (its default is one a core, 12):

| | req/s | p50 | p99 | per idle connection | CPU per request |
|---|---|---|---|---|---|
| Rig | 845,543 | 59 µs | 284 µs | 8.8 KiB | 5.9-6.5 µs |
| hyper, 12 workers | 365,783 | 165 µs | 340 µs | 10.8 KiB | 5.1-5.2 µs |
| hyper, 6 workers | 485,942 | 101 µs | 325 µs | | 5.4 µs |
| Go | 450,728 | 98 µs | 737 µs | 18.9 KiB | 15.2-15.4 µs |

Rig's throughput swings from run to run more than the others': 592,000
to 846,000 requests a second over the 18 runs, where hyper held 352,000
to 366,000 at 12 workers and 473,000 to 486,000 at 6, and Go 444,000 to
451,000. Rig spends 14-27% more CPU on a request than hyper, and serves
more because it keeps more cores busy: its server used 4.9 to 5.2 cores,
hyper's 1.8 at 12 workers and 2.6 at 6, whose busiest worker was busy a
sixth of the time at 12 and under half at 6. With 12 workers each on
cores 0-19, E-cores included, Rig served 676,000 to 865,000, hyper
442,000 to 447,000 and Go 540,000 to 549,000. Counted with page tables,
over 2,000 idle connections, Rig's holds 9.7 KiB, hyper's 10.9 KiB and
Go's 20.1 KiB.

## Fork-join

Divide and conquer with `f()&` and `>t` against `rayon::join`, fastest
of 20 interleaved runs: the sum of 2^25 Ints split in halves down to
8,192, and a quicksort of 2^22 Ints that partitions into two owned
Lists, each half a task down to 8,192. The programs are in the record.

| | Rig | Rayon |
|---|---|---|
| parallel sum | 2.83 ms | 2.39 ms |
| quicksort | 80.2 ms | 52.5 ms |

On Linux, on cores 0-11:

| | Rig | Rayon |
|---|---|---|
| parallel sum | 6.66 ms | 4.48 ms |
| quicksort | 120.6 ms | 117.3 ms |

The sum trails Rayon on both machines; on the Mac most of its gap is
the first parallel call's start-up, the workers' threads and their first
stacks ([records/2026-11/concurrency-startup](../history/records/2026-11/concurrency-startup/README.md)).
The quicksort is 3% behind Rayon on Linux and 53% on the Mac.

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
