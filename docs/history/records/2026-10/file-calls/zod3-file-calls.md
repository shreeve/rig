# Trig's file calls and the blocking pool: attribution and the Zig ceiling (2026-10-31)

Queue row 20, for the owner's speed plan against tsrs.
[tsrs-standing-4.md](../hash-race/tsrs-standing-4.md) put about 3 ms of
zod3's gap on `std.file` through the blocking pool: `realpath` at 2.0 ms
of user time, plus 777 futex and 387 epoll calls. This record counts the
calls Trig makes, times each one and its hand-off, and measures what the
calls cost when made on the calling thread, before any Rig change.
[inline-idle.md](../consolidation-2/inline-idle.md) built that change
once, measured it on ts-pattern alone, and found Trig's whole run did not
move. This record measures the other five projects too.

**Answer.**
- `realpath` is not the lead: Trig makes 4 calls a run on every project,
  0.1-0.2 ms in all.
- The cost is the hand-off of `stat`. zod3 makes 290 of its 387 pool
  calls to `stat`, each about 1.6 µs of work and 4 µs of hand-off on a
  quiet Mac.
- Made on the calling thread, the metadata calls make zod3 2.2-2.9%
  faster by the median and mitt 3.5-3.9% on the Mac. That is over the
  bar.
- tiny-invariant, superstruct and neverthrow gain 0.5-1.6%, under it.
  ts-pattern is within the noise, as inline-idle found.
- pup (x86, the machine standing-4 timed) is not measured yet. It waits
  for a pup slot. No Rig change is proposed until it is.

## Method

- **Builds.** Trig `2ba0719` (standing-4's), its `src/` and
  `tools/trig/main.rig`, built `rig build --release` (no PGO, which is
  Linux only) by Rig main `179c50afa`
  ([buildtrig.sh](data/buildtrig.sh)). Every arm prints the same bytes as
  main on zod3, ts-pattern and mitt.
- **Arms**, each a change to `std/file.zig`'s `pool` only:
  - `main`: every call goes through `rig.blockingStop` to the pool;
  - `direct`: every call runs on the calling thread
    ([direct.diff](data/direct.diff));
  - `meta`: `read` goes to the pool, and `stat`, `read_dir` and
    `realpath` run on the calling thread ([meta.diff](data/meta.diff)).
- **Counts.** [instrument.patch](data/instrument.patch) times each call
  around `blockingStop` (wall) and inside the pool thread (run). It also
  counts the waiter's spins in `poolCall`'s `finishing` state, and prints
  the totals as `main` ends. Hand-off is wall minus run: the queue, the
  pool thread's wake, and the worker's wake back.
- **Timing.** [timetrig.py](data/timetrig.py): the six projects, `-p
  tsconfig.trig.json --noEmit --singleThreaded`. The variants run in
  turn, the first rotated each round, through `tools/low`. Results are
  medians and minimums of wall time, with user and system time.
- **The Mac** was shared with other builders. Round 1 ran at load 3-6
  and round 2 at load 3-5. A third round, at load 15-18, scattered by up
  to 30% and is not used.

## What Trig calls

Trig's OS layer (`tools/trig/main.rig`) is its only use of `std.file`. It
reads a file (`file.read`), asks what is at a path (`file.stat`), lists a
directory (`file.read_dir`), and resolves a path (`file.realpath`, for
`$PWD`, the executable, and a link that names nothing). Trig calls each
from its main fiber, so each goes through the blocking pool.

Calls a run, and microseconds summed over the run (Mac, load 3-5, mean of
3 runs; [mac-counts.txt](data/mac-counts.txt)):

| project | call | calls | wall | work on the pool thread | hand-off | hand-off a call |
|---|---|---:|---:|---:|---:|---:|
| zod3 | `stat` | 290 | 1,618 | 472 | **1,145** | 3.9 µs |
| zod3 | `read` | 87 | 1,914 | 1,556 | 357 | 4.1 µs |
| zod3 | `read_dir` | 6 | 181 | 158 | 22 | 3.7 µs |
| zod3 | `realpath` | 4 | 168 | 113 | 54 | 13 µs |
| ts-pattern | `stat` | 264 | 1,742 | 542 | 1,199 | 4.5 µs |
| ts-pattern | `read` | 80 | 4,761 | 4,371 | 389 | 4.9 µs |
| tiny-invariant | `stat` | 97 | 556 | 153 | 402 | 4.1 µs |
| superstruct | `stat` | 50 | 310 | 119 | 190 | 3.8 µs |
| mitt | `stat` | 95 | 512 | 143 | 369 | 3.9 µs |
| neverthrow | `stat` | 36 | 253 | 105 | 147 | 4.1 µs |

- Every project makes exactly 4 `realpath` calls, 0.1-0.2 ms in all.
- **zod3's hand-off is about 1.6 ms a run on a quiet Mac.** At load 14-15
  it was 41 ms (25 ms of it `stat`): a hand-off waits on two threads
  being scheduled, so it grows with the machine's load.
- **The waiter never spun on the Mac:** no call found its pool thread in
  `finishing`.
- **On Linux** standing-4's `strace -f` of zod3 shows the same shape: 377
  `statx`, 4 `readlink` (the `/proc/self/fd` step of Zig's
  `realPathFile`, one a `realpath`), and 777 futex and 387 `epoll_pwait`
  calls. That is about two futex calls and one epoll wait for each of
  the 387 pool calls.
- **standing-4's 2.0 ms under `__rig_std_file.realpath`** cannot be
  `realpath`'s own work at 4 calls a run. One explanation is the PGO
  build's inlined pool wait attributed to that symbol. Another is the
  waiter spinning in `finishing` while its pool thread is descheduled on
  the one core (`taskset -c 6`) that both share. Neither is measured yet.
  The instrumented build pinned to one pup core will tell.

## The ceiling (Mac)

Wall time by median (and by minimum), against `main`
([round 1](data/mac-round1.txt), [round 2](data/mac-round2.txt)):

| project | `main` | `direct` r1 | `direct` r2 | `meta` r2 |
|---|---:|---:|---:|---:|
| zod3 | 110.3 / 129.7 ms | **4.1% (2.6%) faster** | **2.9% (4.8%) faster** | **2.2% (4.8%) faster** |
| ts-pattern | 551 / 655 ms | 2.2% (0.2%) faster | 1.2% faster (6.3% slower) | 1.2% faster (2.8% slower) |
| tiny-invariant | 56.6 / 59.6 ms | 1.9% (1.6%) faster | 1.1% (0.6%) faster | 0.5% (0.5%) faster |
| superstruct | 23.7 / 25.7 ms | 3.4% (2.1%) faster | 0.9% slower (2.4% faster) | 1.2% (2.4%) faster |
| mitt | 20.4 / 22.3 ms | **3.9% (4.0%) faster** | **3.7% (4.0%) faster** | **3.5% (4.4%) faster** |
| neverthrow | 21.1 / 22.8 ms | 1.6% (1.6%) faster | 1.6% faster (0.6% slower) | 1.6% faster (0.9% slower) |

- **System time** falls 1.6-3.0 ms on zod3 and 0.3-0.6 ms on the small
  projects.
- **User time** moves by 0.5 ms or less, except zod3's in round 1 (2.5
  ms).
- **`meta` keeps nearly all of `direct`'s gain.** The cost is the round
  trip of the metadata calls, not where `read`'s strings are allocated.
- **ts-pattern's 255 metadata calls** are about 1 ms of a 550-650 ms run,
  within its noise, as inline-idle found.

## What would carry it, if pup confirms

- **The smallest form** runs `stat`, `exists`, `read_dir` and `realpath`
  on the calling thread. These calls never read a file's contents, so no
  pipe, FIFO, terminal or device can block them:
  - `read_dir` opens with `O_DIRECTORY`;
  - `realpath` opens with `O_PATH` on Linux and is libc's `realpath`
    on macOS;
  - `stat` opens nothing.
- **That drops inline-idle's regular-file checks** for `read` and
  `open`, about half its 736 lines.
- **What stays open is a call that hangs**, such as a `stat` on a network
  mount that has stopped answering. Go makes the same call on its own
  thread, and its `sysmon` hands the processor to another thread after
  20 µs. Rig has two choices:
  - inline-idle's rescue: the pool's monitor wakes a worker to steal the
    stuck one's ring after 1 ms;
  - run the call only when the worker has nothing else queued, with no
    rescue, and accept that a hang stalls the fibers that come to that
    worker later.
- **Either choice changes how the scheduler behaves,** so it goes to the
  owner with the pup numbers.

## Not yet measured

- **The x86 ceiling:** `main` against `meta` on pup, the six projects
  pinned to P-core 6 as standing-4 timed them, with a PGO build of each
  arm. It needs a pup timing slot and one release build per arm.
- **The waiter's spins on one shared core:** the instrumented build
  under `taskset -c 12`, which tests the second explanation of
  standing-4's 2.0 ms.
- **The runtime benches** (tasks, actors, net, http) do not call
  `std.file`'s metadata calls, so the `meta` arm cannot change them. A
  built change would still run them.
