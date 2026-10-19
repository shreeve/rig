# Task benchmarks

Times Rig's tasks (SPEC §18) against Tokio's and Go's on the same five
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
`rig-safe` on request) and the options. The Rig programs run on the
scheduler with one worker per core, or `RIG_WORKERS` when set. `--record "#PR: what changed"` adds the Rig rows to
[PROGRESS.md](PROGRESS.md), which tracks each benchmark as the
scheduler grows ([docs/concurrency/SCHEDULER.md](../../docs/concurrency/SCHEDULER.md)).

## The benchmarks

Each program runs all five, times each with the monotonic clock, and
prints `NAME NS CHECK`; the driver rejects a run whose checks differ
between programs. The driver also runs each program as `PROGRAM many`,
which holds 10,000 tasks at once, each sleeping 200 ms, and as
`PROGRAM idle`, which makes none; `memory` is the difference in their
peak resident memory, per task.

| Name | What it does | Per |
|---|---|---|
| `spawn` | 100 waves, each starting 1,000 tasks that return their index, then waiting for all of them | task |
| `chain` | 10,000 times: start one task, wait for it | task |
| `fanout` | 10 tasks of CPU work (a 20-million-step loop each) at once | run |
| `yield` | 100 tasks, each yielding 10,000 times | yield |
| `hog` | 32 tasks of CPU work (a 20-million-step loop each) keep every core busy; meanwhile, 50 times: queue a task of CPU work (a 1-million-step loop), then start two tasks and wait for both | step |

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

On 2026-10-19, after #356 made the scheduler the default, best of 7.
On the Mac (an Apple M5 with 10 cores):

```text
        rig-fast          tokio             go                vs tokio
spawn   100 ns/task       178 ns/task       291 ns/task       rig-fast 1.8x faster, go 1.6x slower
chain   54 ns/task        165 ns/task       221 ns/task       rig-fast 3.1x faster, go 1.3x slower
fanout  82.9 ms/run       68.7 ms/run       70.1 ms/run       rig-fast 1.2x slower, go 1.0x slower
yield   10 ns/yield       42 ns/yield       247 ns/yield      rig-fast 4.2x faster, go 5.8x slower
hog     69.25 us/step     4.0 ms/step       4.2 ms/step       rig-fast 58.3x faster, go 1.0x slower
memory  32.0 KiB/task     262 B/task        2.8 KiB/task      rig-fast 125.0x more, go 11.1x more
```

On pup (Linux, x86-64, 22 cores):

```text
        rig-fast          tokio             go                vs tokio
spawn   293 ns/task       328 ns/task       354 ns/task       rig-fast 1.1x faster, go 1.1x slower
chain   88 ns/task        212 ns/task       282 ns/task       rig-fast 2.4x faster, go 1.3x slower
fanout  94.4 ms/run       96.0 ms/run       80.6 ms/run       rig-fast 1.0x faster, go 1.2x faster
yield   7 ns/yield        43 ns/yield       474 ns/yield      rig-fast 6.2x faster, go 11.0x slower
hog     44.00 us/step     2.2 ms/step       1.9 ms/step       rig-fast 49.9x faster, go 1.2x faster
memory  9.0 KiB/task      367 B/task        2.9 KiB/task      rig-fast 25.0x more, go 8.0x more
```

Rig is ahead of Tokio wherever the scheduler is what is measured:
starting, waiting for, and switching tasks, and keeping a task that
waits behind a long computation from waiting for all of it. It is
behind in memory, where a task holds two pages of stack, and on the
Mac in `fanout`, whose gap is the compiled loop's. PROGRESS.md tracks
each step.

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
