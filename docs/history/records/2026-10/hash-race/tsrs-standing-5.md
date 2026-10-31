# Where Trig stands against tsrs at four checkers (2026-10-31)

Item 10 of the list to match or beat tsrs: Trig checks with several
checkers in tasks, so how does Trig at four checkers compare with tsrs on
one thread, and with tsrs on four? [tsrs-standing-4.md](tsrs-standing-4.md)
measured one checker only. Measurement only; no code changed. Scripts and
raw output are in [tsrs-standing-5-data/](tsrs-standing-5-data/).

This predates pool-yield (#819, not merged when this ran), which takes
about 10M cycles off every run's start-up. The small projects' numbers
will move with it.

## Method

- **Machine.** pup (Core Ultra 9 185H). One thread on P-core 6 with its
  sibling 7 idle. Four on P-cores 0, 6, 8 and 10, one per physical core,
  with their siblings 5, 7, 9 and 11 idle. `perf` and `/usr/bin/time` ran
  on the E-cores 12-19. Before each round `time.sh` waited until no
  other thread ran on cores 0 and 5-11; it waited 16 times. Load 1.2 to
  2.4. Release builds ran on the E-cores throughout.
- **Variants** ([time.sh](tsrs-standing-5-data/time.sh)):
  - `trig1` and `trig4`: Trig `2ba0719` PGO, built by Rig `d0af9f62a`
    (#810's build, which differs from main only in std/crypto; sha256
    `13a7cc23a0b54faf`), at `--singleThreaded` and at `--checkers 4`;
  - `tsrs1` and `tsrs4`: shipped tsrs 0.18.0 (sha256
    `d0bd720c20e99007`), Go's checker assignment, no lazy members, at
    `--singleThreaded` with `RAYON_NUM_THREADS=1` and at `--checkers 4`
    with `RAYON_NUM_THREADS=4`.
- **Timing.** 20 rounds of the six projects, the first variant rotated
  each round. One `perf stat` per run (wall, user and system time, user
  and kernel cycles, user instructions, page faults) and peak RSS by
  `/usr/bin/time`. Every one of the 480 runs printed tsrs1's bytes.

## Wall time

The median, as a percentage more or less than tsrs on one thread
([times-summary.md](tsrs-standing-5-data/times-summary.md) has the
fastest runs, user cycles and peak RSS for every cell).

| project | tsrs1 | Trig, 1 checker | Trig, 4 checkers | tsrs, 4 threads |
|---|---:|---|---|---|
| ts-pattern | 750.8 ms | 5.2% more | 56.6% less | 60.0% less |
| zod3 | 117.5 ms | 30.7% more | 13.9% less | 41.8% less |
| mitt | 18.4 ms | 35.9% more | 62.0% more | 19.6% more |
| neverthrow | 19.5 ms | 37.8% more | 55.0% more | 22.4% more |
| superstruct | 22.8 ms | 42.2% more | 17.8% more | 18.1% less |
| tiny-invariant | 54.4 ms | 30.9% more | 33.7% more | 4.4% more |

- **Large projects.** At four checkers Trig is ahead of tsrs on one
  thread: 2.3 times as fast on ts-pattern, 14% less time on zod3. Against
  tsrs on four threads it is behind: 8.5% slower on ts-pattern (325.7
  against 300.3 ms) and 48% slower on zod3 (101.1 against 68.4 ms).
- **Small projects.** Four checkers do not pay. On mitt and neverthrow
  Trig at four is slower than Trig at one (29.8 against 25.0 ms, 30.2
  against 26.8). tsrs also loses from one thread to four there, but
  by less.
- **One checker, ts-pattern.** tsrs1's runs spread from 648.5 to 751 ms,
  so its median is high. By the fastest run Trig is 14.8% slower (744.4
  against 648.5 ms), close to standing-4's; by user cycles, 12.2% more.

## Time, cycles and memory at four

Medians, from [times.txt](tsrs-standing-5-data/times.txt):

| project | variant | user ms | system ms | kernel cycles | page faults | peak RSS MB |
|---|---|---:|---:|---:|---:|---:|
| ts-pattern | trig1 | 712 | 82 | 336M | 40,239 | 246.9 |
| ts-pattern | trig4 | 782 | 98 | 423M | 48,399 | 276.6 |
| ts-pattern | tsrs1 | 629 | 107 | 466M | 37,476 | 201.2 |
| ts-pattern | tsrs4 | 711 | 210 | 869M | 44,095 | 226.8 |
| zod3 | trig1 | 130 | 24 | 89M | 7,774 | 84.1 |
| zod3 | trig4 | 186 | 48 | 179M | 18,965 | 111.6 |
| zod3 | tsrs1 | 104 | 13 | 51M | 5,414 | 54.0 |
| zod3 | tsrs4 | 159 | 26 | 89M | 9,280 | 85.4 |
| mitt | trig1 | 17 | 8 | 27M | 2,263 | 31.9 |
| mitt | trig4 | 18 | 14 | 40M | 2,881 | 34.8 |
| mitt | tsrs1 | 11 | 7 | 20M | 2,394 | 18.0 |
| mitt | tsrs4 | 20 | 15 | 39M | 4,097 | 28.5 |

- **zod3.** From one checker to four, Trig's user time grows 43% and
  tsrs's 53%, but Trig's page faults grow 2.4 times against tsrs's 1.7,
  and its system time doubles. Trig4's peak RSS is 107% more than
  tsrs1's and 31% more than tsrs4's.
- **ts-pattern.** tsrs4 spends twice tsrs1's system time and kernel
  cycles; Trig4 grows 20% and 26%. Trig4 scales by its user work.

## What follows

Two items for the list, from these numbers:

1. Why four checkers start up slower than one on mitt and neverthrow:
   task spawn, per-checker setup, program loans, the scheduler. Profile
   Trig1 against Trig4 at start-up, on top of pool-yield.
2. Why zod3 scales worse than tsrs from one to four, and why Trig4's
   peak RSS is 107% more than tsrs1's: what each checker duplicates, and
   whose code (Rig's or Trig's) makes the faults.
