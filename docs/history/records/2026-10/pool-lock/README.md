# The blocking pool's lock: read before taking, never yield (2026-10-25)

**Question.** #624 put the blocking pool's state under the scheduler's
`SpinLock`, whose waiters retried the compare-and-swap in a tight loop.
Loc found that loco's walk paid for it. How should the lock wait?

**Answer.** A waiter reads the lock until it looks free and only then
tries to take it, and it never yields. The pool also reads the clock
outside its lock (in `submit`, the monitor, and `poolMain`). This is
variant `-c` (branch `pool-lock-c`).

## Variants

| variant | branch | how a waiter waits |
|---|---|---|
| main | `99dcccf13` | retries the compare-and-swap |
| yield | `pool-lock`, `32f042105` | reads before taking; yields after 100 reads |
| b | `pool-lock-b`, `32f91039f` | the same, yielding after 1,000 reads |
| c | `pool-lock-c`, `f7703624b` | reads before taking; never yields |
| d | `pool-lock-d`, `59282f12d` | a parking lock for the pool alone: 100 spins, then a futex wait |

## loco (measured by Loc, Mac)

Yielding after 100 reads made the walk 11% faster (123 against 139 ms),
but raised `--jobs=1` kernel time on the full read by 43% (4.11 to
5.89 s): with one worker beside the pool threads, waiters yield often,
and each yield is a system call. That ruled out yielding.

c and d against main, all from loco 791d540. Fastest of 7 (under load,
fastest of 3). Each cell is min wall ms / median user s / median sys s.
Load was 4 at the start and 13.6 by the end, so wall differences under
about 5% are noise.

| run | main | c | d |
|---|---|---|---|
| trig `--no-ignore --json` | 1,466 / 2.49 / 4.66 | 1,444 / 2.45 / 4.70 | 1,445 / 2.47 / 4.65 |
| same, `--jobs=1` | 1,952 / 1.76 / 4.81 | 1,996 / 1.75 / 5.93 | 2,020 / 1.74 / 6.21 |
| walk only | 150 / 0.09 / 0.49 | 164 / 0.09 / 0.47 | 152 / 0.10 / 0.51 |
| walk only, `--jobs=1` | 180 / 0.08 / 0.47 | 149 / 0.08 / 0.53 | 182 / 0.09 / 0.47 |
| under load, trig | 2,584 / 3.88 / 7.84 | 2,294 / 2.87 / 7.76 | 2,124 / 2.19 / 7.72 |
| under load, `--jobs=1` | 5,249 / 2.84 / 8.07 | 4,992 / 2.07 / 7.67 | 5,115 / 2.02 / 7.80 |

c's `--jobs=1` sys moved between sessions: 3.88 s in an earlier run,
below main, and 5.93 s here, above it. Most of that row is load.

## Oversubscription (pup)

A spin lock that never yields is at its worst when the holder is
descheduled, so each build ran a program of 200 tasks, each reading a
small file 1,000 times through the pool, on two cores (`taskset -c 0,5`) with the
pool's threads competing for them. Thirty rounds, interleaved; pup's
load from other sessions rose from 4.9 to 9 during the run.

| build | min s | median s | p90 s | max s | mean sys s | runs over 0.9 s |
|---|---:|---:|---:|---:|---:|---:|
| main | 0.50 | 0.60 | 0.71 | 1.25 | 0.78 | 1 |
| c | 0.49 | 0.57 | 0.65 | 1.25 | 0.79 | 2 |
| d | 0.49 | 0.57 | 1.21 | 1.26 | 0.93 | 5 |

The runs over 0.9 s come in all three builds, at the same length, so
they are the machine's load, not the lock. c does not degrade when
oversubscribed: its median and p90 are the best of the three, and its
kernel time equals main's.

## Runtime benches (pup)

main and c on cores 6 and 7, interleaved, three rounds of 5 reps (http:
three rounds of 3), fastest kept. Load 2 to 3.5 from other sessions.

| bench | main | c |
|---|---:|---:|
| tasks spawn | 63 ns | 63 ns |
| tasks chain | 89 ns | 87 ns |
| tasks fanout | 309.8 ms | 310.0 ms |
| tasks yield | 25 ns | 24 ns |
| tasks hog | 135.02 us | 134.40 us |
| actors solo / contend / spread | 12 / 15 / 11 ns | 12 / 15 / 11 ns |
| net pingpong | 5.16 us | 5.07 us |
| net echo | 3.95 us | 3.94 us |
| net connect | 29.93 us | 29.77 us |
| http | 196,161 req/s | 195,093 req/s |

Every result is within 2%. `SpinLock` also guards the scheduler's other
shared state (the global queue, timers, the poller, task and actor state),
which these benches exercise, so its new wait costs
nothing there.

## Decision

c: it is the smallest change, it holds up oversubscribed, and d's one
win (7% under load on loco's default run) does not outweigh its larger
mechanism and its higher sys under oversubscription.
