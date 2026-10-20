# Task benchmarks

Times Rig's tasks (SPEC §18) against Tokio's and Go's on the same five
timed benchmarks and a memory measurement, so the scheduler's work can
be measured against the runtimes it aims to match. It is not part of
the test suite or CI.

```sh
bench/tasks/bench-tasks
D=$(mktemp -d)
bench/tasks/bench-tasks --out $D --build-only
bench/tasks/bench-tasks --out $D --time-only --reps 9
```

It needs `bin/rig` built first, Cargo, and Go. `bench/tasks/bench-tasks
--help` lists the variants (`rig-fast`, `tokio` and `go` by default;
`rig-safe` on request) and the options. The Rig programs run on the
scheduler with one worker per core, or `RIG_WORKERS` when set.
`--record "#PR: what changed"` adds the Rig rows to
[PROGRESS.md](PROGRESS.md), which tracks each benchmark as the
scheduler grows ([docs/internals/scheduler.md](../../docs/internals/scheduler.md)).

Before a change to the scheduler or to tasks lands, run
`bench/tasks/bench-tasks --variants rig-fast --gate` on a quiet machine:
it fails when any benchmark takes more than 1.5 times the last `rig-fast`
row PROGRESS.md holds for the machine's architecture. The suite checks
results, not speed; `test/cli/task_spread.sh` checks that tasks spread
over the workers.

## The benchmarks

Each program runs the five timed benchmarks, times each with the
monotonic clock, and prints `NAME NS CHECK`; the driver rejects a run whose checks differ
between programs. The driver also runs each program as `PROGRAM many`,
which holds 10,000 tasks at once, each sleeping 200 ms, and as
`PROGRAM idle`, which makes none; `memory` is the difference in their
peak resident memory, per task. It measures memory after every timed
run, so the tasks one program holds and frees never slow the next
one's times.

| Name | What it does | Per |
|---|---|---|
| `spawn` | 100 waves, each starting 1,000 tasks that return their index, then waiting for all of them | task |
| `chain` | 10,000 times: start one task, wait for it | task |
| `fanout` | 10 tasks of CPU work (a 20-million-step loop each) at once | run |
| `yield` | 100 tasks, each yielding 10,000 times | yield |
| `hog` | 32 tasks of CPU work (a 20-million-step loop each) keep every core busy; meanwhile, 50 times: queue a task of CPU work (a 1-million-step loop), then start two tasks and wait for both | step |
| `memory` | resident memory per task, with 10,000 tasks asleep (above) | task |

`spawn` and `chain` measure what a task costs to start, schedule, finish
and wake its waiter: in bulk, and one at a time on the critical path.
`fanout` measures how well CPU work spreads over the cores. `yield`
measures a switch between tasks that do no work. `hog` measures how
long a task waits behind one that computes without waiting: the first
of each step's two tasks is queued behind that step's loop on the
waiter's worker, while the 32 loops keep the other workers busy, so it
waits until that loop yields or ends.

## The rules

So the numbers compare like with like:

- **Same work.** The programs share their constants and do the same
  thing at each step; a task returns its value to its waiter in each.
  Rig waits through a task or a set (`Tasks`), Tokio through
  `JoinHandle`s, and Go through a `WaitGroup` or a channel.
- **Each runtime as it is used.** Rig builds with `--release=fast`,
  Tokio with `cargo build --release` (LTO, one codegen unit) on its
  multi-threaded runtime with its default worker count, and Go with
  `go build` and its default `GOMAXPROCS`. The benchmarks run inside a
  task in each: Tokio's in a spawned task, Go's in the main goroutine.
- **Tokio from the clone.** Tokio builds from the repository's
  `misc/tokio` clone when there is one (`--tokio` names another), else
  from the crates.io release Cargo resolves.
- **Best of interleaved runs.** Each variant runs `--reps` times, the
  variants in turn, and the fastest of each benchmark counts.
- **Where to time.** Time arm64 on the Mac and x86 on pup, on a quiet
  machine; never on burst, a shared VM.

## Where it stands

The latest rows are in [PROGRESS.md](PROGRESS.md), which `--record`
writes, from the reference rows of Tokio and Go and the first Rig row,
on Zig's `Threaded` backend, to the scheduler as it is. The headline
numbers against Tokio and Go are in
[docs/launch/benchmarks.md](../../docs/launch/benchmarks.md).

Rig is ahead of Tokio wherever the scheduler is what is measured:
starting, waiting for, and switching tasks, and keeping a task that
waits behind a long computation from waiting for all of it. It is
behind in memory, where a task holds a page of stack, and in `fanout`,
whose gap is the compiled loop's, not the scheduler's.
