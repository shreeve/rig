# Task benchmarks

Times Rig's tasks (SPEC §18) against Tokio's and Go's on the same four
benchmarks, so the scheduler's work can be measured against the
runtimes it aims to match. It is not part of the test suite or CI.

```sh
bench/tasks/bench-tasks
D=$(mktemp -d)
bench/tasks/bench-tasks --out $D --build-only
bench/tasks/bench-tasks --out $D --time-only --reps 9
```

It needs `bin/rig` built first, Cargo, and Go. `bench/tasks/bench-tasks
--help` lists the variants (`rig-fast`, `tokio` and `go` by default;
`rig-safe`, and `rig-sched` on the scheduler, on request) and the
options. `--record "#PR: what changed"` adds the Rig rows to
[PROGRESS.md](PROGRESS.md), which tracks each benchmark as the
scheduler grows ([docs/concurrency/SCHEDULER.md](../../docs/concurrency/SCHEDULER.md)).

## The benchmarks

Each program runs all four, times each with the monotonic clock, and
prints `NAME NS CHECK`; the driver rejects a run whose checks differ
between programs.

| Name | What it does | Per |
|---|---|---|
| `spawn` | 100 waves, each starting 1,000 tasks that return their index, then waiting for all of them | task |
| `chain` | 10,000 times: start one task, wait for it | task |
| `fanout` | 10 tasks of CPU work (a 20-million-step loop each) at once | run |
| `yield` | 100 tasks, each yielding 10,000 times | yield |

`spawn` and `chain` measure what a task costs to start, schedule, finish
and wake its waiter: in bulk, and one at a time on the critical path.
`fanout` measures how well CPU work spreads over the cores. `yield`
measures a switch between tasks that do no work.

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

## Baseline

The first numbers, on 2026-10-19, an Apple M5 with 10 cores, best of
5, with Rig on Zig's `Threaded` backend, which starts an OS thread per
task:

```text
        rig-fast          tokio             go                vs tokio
spawn   12.28 us/task     171 ns/task       232 ns/task       rig-fast 72.0x slower, go 1.4x slower
chain   10.29 us/task     167 ns/task       223 ns/task       rig-fast 61.5x slower, go 1.3x slower
fanout  82.7 ms/run       69.0 ms/run       69.6 ms/run       rig-fast 1.2x slower, go 1.0x slower
yield   412 ns/yield      40 ns/yield       233 ns/yield      rig-fast 10.4x slower, go 5.9x slower
```

Tokio is the target for `spawn`, `chain` and `yield`. In `fanout`,
starting its 10 tasks costs about 0.1 ms even on this backend, so the
rest of its gap is the compiled loop's, not the scheduler's.
