# Datetime phase 0: the `Duration` layout, per call (2026-11-20)

The datetime design (§5.1) leaves one decision to a measurement: the
layout of `Duration`. Layout A is Jiff's, whole seconds (an `Int`) and
nanoseconds (an `I32`) of one sign, 16 bytes; layout B is one `Int` of
nanoseconds. This record holds the nanoseconds a call for each, from
`bench/duration`, and a run of `bench/tasks`, `bench/actors`,
`bench/net` and `bench/http` as phase 1's baseline. It makes no
recommendation: the owner decides on the per-call numbers.

## Method

- **Machine and build.** Apple M5, 10 cores, macOS 27.2.1; the
  `datetime-p0` worktree at main 901544ab0, `bin/rig` built with a plain
  `tools/heavy zig build`. The benchmark is built with `rig build
  --release`, which is Zig's **ReleaseSafe**: overflow and range checks
  stay in, as in a user's release build. Every timed run held the Mac's
  claim (`tools/mac-claim`), which starts it once the machine is quiet.
  No x86 run: pup's timing slot was left to Trig.
- **Stand-ins.** Both layouts are written in Rig in
  `bench/duration/duration.rig`, with no compiler change, over today's
  `std.time`: its clock gives an `Int` of nanoseconds (`t.elapsed()`,
  `t.since(u)`) and its waits take one (`sleep`, `within`, `after`), so
  each call converts there, as the design keeps the scheduler an `Int`
  of nanoseconds underneath. A monotonic reading is today's `Instant`,
  one `Int`, in both.
  - A from nanoseconds: `s = n / 10^9`, `ns = I32(n % 10^9)` (one sign,
    since `/` and `%` truncate toward zero).
  - A to nanoseconds for a reading's `add`: `s * 10^9 + ns`, which
    panics past an `Int` (§5.7).
  - A to nanoseconds for a wait: the same, or `Int.max` (`Int.min`) once
    the seconds reach ±9,223,372,036, so a wait longer than an `Int` of
    nanoseconds waits as long as the scheduler can (§5.8). The runtime
    already holds a deadline in an `i96`, so `Int.max` cannot overflow
    it.
  - B passes its field as it is.
- **Cases.** Each is a loop in a `called` function making the call N
  times:

  | Case | Each call | N |
  |---|---|---|
  | `elapsed()` | a clock read, made a duration | 400,000 |
  | `since` | the difference of two readings, made a duration | 10,000,000 |
  | deadline `add`, compare | a reading plus a duration, compared with another reading | 10,000,000 |
  | `sleep(0)` | `time.sleep` of a zero duration | 5,000,000 |
  | `within`, empty function | `time.within` of 5 s around a function that gives 0 | 400,000 |
  | `select`, `after` loses | a send to a channel of one slot, then a `select` of its receive and `time.after` of 5 s | 200,000 |
  | `select`, `after(0)` wins | a `select` whose one arm is `time.after` of zero | 200,000 |

- **Rounds.** 20 rounds; in each, every case runs A and B in turns (B
  first in odd rounds). The table gives the fastest round of each,
  divided by N. Three boards ran, each under its own claim.
- **Not optimized away.**
  - A duration passes through `hint.opaque` at every call, so no
    conversion moves out of the loop, and what a call gives is kept
    with `hint.keep`, so it is computed. Each loop's total is checked
    against N.
  - `duration check` runs each loop at N and at 2N (fastest of 5): the
    ratio of their times was 1.82 to 2.12 for every case and layout, on
    board 1 under the claim (2.0 or within 0.05 of it for 11 of the 14).
  - The disassembly (`lldb`, `disassemble -n __rig_main.since_a` and
    the others) shows the work in each loop. A's `elapsed()` and
    `since` loops do `smulh`, `asr`, `add`, `msub` (the division by
    10^9 as a multiply) and store both fields each time; A's deadline
    loop does `mul` and `smulh` (the overflow check of `s * 10^9`),
    `ldrsw`, and two checked adds; A's `sleep` loop compares the
    seconds with both limits before the multiply. The `I32` range check
    of `n % 10^9` is folded away. B's loops do the subtraction or the
    add alone. Both layouts' `hint.opaque` stores the value it hides:
    16 bytes for A, 8 for B.

## Results

Nanoseconds a call, ReleaseSafe, the fastest of 20 rounds, three boards
(board 1 / board 2 / board 3):

| Case | A | B | A − B |
|---|---|---|---|
| `elapsed()` | 14.53 / 15.15 / 14.81 | 12.67 / 13.25 / 12.82 | 1.87 / 1.91 / 2.00 |
| `since` | 0.59 / 0.59 / 0.59 | 0.30 / 0.29 / 0.29 | 0.29 / 0.30 / 0.30 |
| deadline `add`, compare | 0.43 / 0.42 / 0.43 | 0.29 / 0.30 / 0.30 | 0.14 / 0.12 / 0.13 |
| `sleep(0)` | 1.15 / 0.94 / 1.13 | 0.89 / 0.87 / 0.89 | 0.26 / 0.07 / 0.23 |
| `within`, empty function | 14.61 / 15.09 / 14.86 | 14.51 / 14.78 / 14.71 | 0.10 / 0.31 / 0.16 |
| `select`, `after` loses | 40.62 / 41.21 / 41.13 | 40.61 / 41.25 / 41.54 | 0.01 / −0.05 / −0.40 |
| `select`, `after(0)` wins | 31.21 / 32.42 / 31.60 | 31.16 / 32.35 / 31.97 | 0.05 / 0.07 / −0.37 |

- The conversion from nanoseconds costs A 0.3 ns a call in `since`,
  where nothing else runs, and 1.9 to 2.0 ns in `elapsed()`, beside a
  clock read of about 12.7 ns. Why the same instructions cost more
  beside the clock call was not established; one build's code
  placement can move a loop by 5-7% on Apple cores (AGENTS.md), about
  0.8 ns at this size, and only one build was timed.
- The conversion to nanoseconds costs A 0.12 to 0.14 ns on a deadline's
  `add`, and 0.07 to 0.26 ns on `sleep(0)`.
- In `within` and both `select`s, A − B lies within −0.40 to 0.31 ns,
  inside the spread of B itself from board to board in those cases (0.27 to 1.19 ns): the call costs
  15 to 42 ns and the conversion is not seen apart from it.

## Baselines for phase 1

Each driver run once on the Mac, as its README gives it, built with
`--build-only` (through `tools/heavy`) and timed with `--time-only` at
its default repetitions (5 for tasks, actors and net; 3 for http), each
under its own claim; the drivers interleave their variants and keep the
fastest. Rig `--release` (ReleaseSafe); Tokio 1.54.1 from the
`misc/tokio` clone (hyper from crates.io), `cargo build --release`; Go
1.27.3; Rust 1.99.1.

`bench/tasks`:

| Benchmark | Rig | Tokio | Go |
|---|---|---|---|
| spawn | 133 ns/task | 171 ns | 231 ns |
| chain | 26 ns/task | 159 ns | 198 ns |
| fanout | 69.2 ms/run | 69.7 ms | 71.2 ms |
| yield | 7 ns/yield | 42 ns | 180 ns |
| hog | 150 ns/step | 4.1 ms | 4.3 ms |
| produce | 5.2 ms/run | 5.4 ms | 5.6 ms |
| memory | 16.6 KiB/task | 256 B | 2.9 KiB |

`bench/actors`:

| Benchmark | Rig | Tokio | Go |
|---|---|---|---|
| solo | 5.1 ns/call | 124 ns | 3.5 ns |
| contend | 14 ns/call | 250 ns | 80 ns |
| spread | 0.9 ns/call | 32 ns | 0.5 ns |

`bench/net`:

| Benchmark | Rig | Tokio | Go |
|---|---|---|---|
| pingpong | 13.03 µs/trip | 14.13 µs | 16.32 µs |
| echo | 5.08 µs/trip | 5.34 µs | 6.00 µs |
| connect | 49.42 µs/conn | 49.08 µs | 61.50 µs |

`bench/http` (64 connections, 3 s, best of 3; idle connections 10,000):

| Server | req/s | p50 | p99 | Per idle connection |
|---|---|---|---|---|
| Rig | 181,695 | 339 µs | 621 µs | 16.7 KiB |
| hyper on Tokio | 170,273 | 369 µs | 603 µs | 18.6 KiB |
| Go | 151,059 | 401 µs | 1,111 µs | 19.3 KiB |

The drivers rewrite `bench/actors/tokio/Cargo.lock` and
`bench/net/tokio/Cargo.lock` to the clone's Tokio version (1.53.3 to
1.54.1) when they build; both were restored after the run.
