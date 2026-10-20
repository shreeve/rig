# Actor benchmarks

Times calls of Rig's actors (SPEC §18, "Actors") against the two ways
other runtimes guard shared state: a counter behind Go's `sync.Mutex`,
and a counter run as a Tokio actor, a task serving a bounded `mpsc`
channel whose messages carry a `oneshot` for the answer. It is not part
of the test suite or CI.

```sh
bench/actors/bench-actors
D=$(mktemp -d)
bench/actors/bench-actors --out $D --build-only
bench/actors/bench-actors --out $D --time-only --reps 9
```

It needs `bin/rig` built first, Cargo, and Go. `bench/actors/bench-actors
--help` lists the variants (`rig-fast`, `tokio` and `go` by default;
`rig-safe` on request) and the options. `--record "#PR: what changed"`
adds the Rig rows to [PROGRESS.md](PROGRESS.md).

## The benchmarks

Each program runs all three, times each with the monotonic clock, and
prints `NAME NS CHECK`; the driver rejects a run whose checks differ
between programs. Every call adds 1 to the count and waits for the new
count.

| Name | What it does | Per |
|---|---|---|
| `solo` | one task calls one counter 1,000,000 times | call |
| `contend` | 8 tasks call one counter 100,000 times each | call |
| `spread` | 1,000 tasks each make a counter of their own and call it 1,000 times | call |

`solo` measures a call no one else competes for: Rig's idle path, an
uncontended lock, and Tokio's message and reply. `contend` measures one
counter many cores want at once. `spread` measures many counters in
parallel, with the cost of starting the tasks and making the counters.

## The rules

As in [bench/tasks](../tasks/README.md): the same work and constants in
each program; each runtime as it is used (Rig with `--release=fast`,
Tokio with `cargo build --release` on its multi-threaded runtime, Go
with `go build`); Tokio from the repository's `misc/tokio` clone when
there is one; the best of interleaved runs; arm64 timed on the Mac and
x86 on pup, on a quiet machine.

## Where it stands

On 2026-10-20, with the idle path, best of 7. On the Mac (an Apple M5
with 10 cores):

```text
         rig-fast    tokio       go          vs tokio
solo     4.9 ns/call 134 ns/call 3.7 ns/call rig-fast 27.5x faster, go 36.7x faster
contend  6.9 ns/call 134 ns/call 21 ns/call  rig-fast 19.2x faster, go 6.5x faster
spread   1.6 ns/call 35 ns/call  0.7 ns/call rig-fast 21.0x faster, go 47.9x faster
```

On pup (Linux, x86-64, 22 cores):

```text
         rig-fast    tokio       go          vs tokio
solo     13 ns/call  260 ns/call 12 ns/call  rig-fast 20.7x faster, go 21.3x faster
contend  33 ns/call  252 ns/call 66 ns/call  rig-fast 7.7x faster, go 3.8x faster
spread   2.2 ns/call 16 ns/call  1.3 ns/call rig-fast 7.2x faster, go 12.1x faster
```

A call that finds the actor idle runs inline, so `solo` costs about
what Go's uncontended lock does, and a Tokio actor's message and reply
cost twenty times more. Under contention a caller spins briefly, as
Go's mutex does, before it sends a message; `contend` swings widely
from run to run in every runtime, as whichever core holds the counter
keeps it. `spread` adds starting 1,000 tasks and making 1,000 counters
to its calls, where Go's goroutines and plain mutexes cost less.
