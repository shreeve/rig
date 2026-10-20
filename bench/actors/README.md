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

The latest rows are in [PROGRESS.md](PROGRESS.md), which `--record`
writes, and the headline numbers against Tokio and Go are in
[docs/launch/benchmarks.md](../../docs/launch/benchmarks.md).

A call that finds the actor idle runs inline, so `solo` costs about
what Go's uncontended lock does, and a Tokio actor's message and reply
cost many times more. Under contention a caller spins briefly, as
Go's mutex does, before it sends a message; `contend` swings widely
from run to run in every runtime, as whichever core holds the counter
keeps it. `spread` adds starting 1,000 tasks and making 1,000 counters
to its calls, where Go's goroutines and plain mutexes cost less.
