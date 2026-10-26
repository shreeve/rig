# Inline file calls on an idle worker: measured, not taken (2026-10-25)

**Question.** Each blocking file call from a fiber goes through the
blocking pool: a wake, a switch to a pool thread, and a wake back. When
the calling worker has nothing else to run, that round trip is pure
cost. Trig's serial loader made about 640 futex calls on ts-pattern,
against tsrs's 5, and loco's walk paid about 13 µs a directory. Would
running such a call on the worker itself, when it is idle, make either
faster?

**Answer.** Not by enough. Futex calls fell from 702 to 32 and Trig's
front end got 5% faster, but that is 2 ms of a run of about 1,090 ms,
and Trig's whole run did not move. loco did not gain, since its calls
almost always find other work queued. The change was 736 lines, 357
of them in the scheduler, and it does not pay for them (AGENTS.md, "A
speed feature pays for its lines"). The owner decided not to land it.
The code stays on branch `inline-idle` (`fc347a174`, closed PR #689).

## What was built

- **When:** a bounded call runs on the calling worker when its run-next
  slot, ring, and pinned queue are empty and the global queue is
  empty. The bounded calls are stat, `exists`, `realpath`, `read_dir`,
  and `read` or `open` of a regular file.
- **Only regular files:** `read` and `open` stat first and open only a
  regular file, with `O_NONBLOCK|O_NOCTTY`, then confirm it with fstat.
  A pipe, FIFO, device, tty, or socket goes to the pool unopened.
  `read_dir` opens with `O_DIRECTORY`, which refuses anything else. A
  `File` known to be regular also reads and writes inline.
- **A cap:** at most the pool's soft bound of calls run at once, inline
  and pooled together. Without it, loco on all cores was 21% slower
  (kernel time 4.0 s to 7.4 s).
- **Rescue:** while calls run inline, the pool's monitor checks every
  1 ms. For a call past 1 ms it wakes a sleeping worker, which steals
  the stuck worker's ring and services its poller and timers. Pinned
  fibers wait for the call to finish.
- **Cancel and deadlines** are checked before a call starts. Seeded
  runs are untouched, and `RIG_INLINE_FILE_CALLS=0` turns it off.
- **Tests:**
  - Four unit tests in `sched.zig`: idle against busy, cancel and
    deadline, the off switch, and the rescue. The rescue test fails
    with the rescue disabled.
  - A command-line script for a FIFO with 1 and 4 workers and seeds
    1 to 20, and for a canceled stat.
  - The full suite, pup's unit tests in three modes, and loco's light
    gate were green.

## Numbers

Trig on ts-pattern (`-p tsconfig.trig.json --noEmit`), main against the
change:

| measure | main | inline |
|---|---:|---:|
| futex calls, front end (pup) | 632 | 27 |
| futex calls, one checker (pup) | 702 | 32 |
| front end (pup) | 41.6 ms | 39.5 ms |
| front end (Mac) | 33.0 ms | 31.6 ms |
| one checker (pup) | 1088.8 ms | 1092.7 ms |
| one checker (Mac) | 604.7 ms | 606.3 ms |

loco on ~/Data/Code/trig (Mac, load from 3 to 23):
- `--json`: 1,347 ms against 1,316 ms;
- `--jobs=1`: 1,825 ms against 1,790 ms;
- the walk rows within 3%.

All of that is noise. Only 39 of 8,729 calls ran inline in the
`--jobs=1` walk.

The runtime benches (tasks, actors, net, http) and std.json safe on pup
cores 6 and 7 were within 1%.

## What the numbers say

- **The round trip was not where the time went.** Trig loads its files
  once, before checking, and the pool's wakes are a few milliseconds of
  that. The one gap the change closed, futex calls, was a count, not
  time.
- **Busy programs never take the path.** A walk with tasks queued finds
  work on its worker and goes to the pool as before.
- **The old reason is already gone.** A pool thread's first allocation
  made a second heap, which used to turn off faulting ahead. The
  prefault rules since then (#674, #678) decide by each heap's own
  work, so that no longer costs anything.
