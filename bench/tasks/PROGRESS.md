# Task benchmark progress

Each row is one measurement of `bench/tasks/bench-tasks` (README.md):
time per operation, best of 5, on an Apple M5 with 10 cores. Read down
a column to see how a benchmark moves. The reference rows are Tokio's
and Go's at the baseline; the Rig rows below them are added as the
scheduler grows (`bench-tasks --record "#PR: what changed"`, which
appends to the end of the file, so a Mac row moves up into its table).
`hog` came with #355 and `memory` with #356: the rows before them have
none, and Tokio's and Go's are from then. Until #356 the scheduler was
the `rig-sched` variant, and `rig-fast` ran on Zig's `Threaded`
backend; from #356 on, `rig-fast` runs on the scheduler.

| Date | Change | Variant | spawn (per task) | chain (per task) | fanout (per run) | yield (per yield) | hog (per step) | memory (per task) |
|---|---|---|---|---|---|---|---|---|
| 2026-10-19 | reference | tokio | 171 ns | 167 ns | 69.0 ms | 40 ns | 2.9 ms | 270 B |
| 2026-10-19 | reference | go | 232 ns | 223 ns | 69.6 ms | 233 ns | 3.2 ms | 2.9 KiB |
| 2026-10-19 | #347: baseline, Zig's `Threaded` backend | rig-fast | 12.28 us | 10.29 us | 82.7 ms | 412 ns |
| 2026-10-19 | #348: fibers on one worker | rig-sched | 103 ns | 47 ns | 570.5 ms | 17 ns |
| 2026-10-19 | #349: a worker per core, with stealing | rig-sched | 206 ns | 61 ns | 75.8 ms | 13 ns |
| 2026-10-19 | #351: stacks, handoff, a faster spawn | rig-sched | 132 ns | 45 ns | 76.4 ms | 11 ns |
| 2026-10-19 | #352: waiting without spinning | rig-sched | 105 ns | 47 ns | 76.4 ms | 8 ns |
| 2026-10-19 | #355: yield checks | rig-sched | 113 ns | 45 ns | 78.2 ms | 10 ns | 84.11 us |
| 2026-10-19 | #356: the scheduler is the default | rig-fast | 94 ns | 49 ns | 78.0 ms | 8 ns | 84.63 us | 32.0 KiB |
| 2026-10-19 | #358: guards sized to the program | rig-fast | 106 ns | 44 ns | 77.8 ms | 10 ns | 101.25 us | 17.0 KiB |
| 2026-10-19 | #371: deterministic runs | rig-fast | 107 ns | 44 ns | 78.4 ms | 8 ns | 82.82 us | 17.0 KiB |
| 2026-10-19 | #372: task.isolate | rig-fast | 110 ns | 44 ns | 77.8 ms | 10 ns | 93.15 us | 17.0 KiB |
| 2026-10-20 | #383: actors | rig-fast | 109 ns | 45 ns | 80.0 ms | 10 ns | 102.17 us | 17.0 KiB |
| 2026-10-20 | #386: the idle path | rig-fast | 99 ns | 47 ns | 86.8 ms | 11 ns | 106.03 us | 17.0 KiB |
| 2026-10-20 | #389: deadlock detection | rig-fast | 104 ns | 47 ns | 86.6 ms | 11 ns | 91.37 us | 17.0 KiB |
| 2026-10-20 | #391: actor failure | rig-fast | 101 ns | 44 ns | 80.8 ms | 10 ns | 79.27 us | 17.0 KiB |
| 2026-10-20 | #392: supervised actors | rig-fast | 104 ns | 44 ns | 80.8 ms | 8 ns | 105.28 us | 17.0 KiB |
| 2026-10-20 | #393: pollers and timers per worker | rig-fast | 105 ns | 47 ns | 109.2 ms | 12 ns | 111.98 us | 17.0 KiB |
| 2026-10-20 | #405: free tasks run on any worker again | rig-fast | 97 ns | 43 ns | 81.0 ms | 10 ns | 73.83 us | 17.0 KiB |
| 2026-10-21 | #535: interrupts cancel main | rig-fast | 108 ns | 43 ns | 77.7 ms | 6 ns | 86.08 us | 17.1 KiB |
| 2026-10-22 | main before #541, interleaved | rig-fast | 126 ns | 44 ns | 78.5 ms | 6 ns | 67.51 us | 17.1 KiB |
| 2026-10-22 | #541: a run-next fill wakes no worker | rig-fast | 142 ns | 45 ns | 80.3 ms | 9 ns | 102.05 us | 17.1 KiB |
| 2026-10-22 | main before #552, interleaved | rig-fast | 143 ns | 44 ns | 77.7 ms | 9 ns | 67.31 us | 17.1 KiB |
| 2026-10-22 | #552: each worker on cache lines of its own | rig-fast | 125 ns | 45 ns | 77.3 ms | 5 ns | 56.41 us | 17.1 KiB |
| 2026-10-23 | main before #581, interleaved | rig-fast | 76 ns | 44 ns | 77.0 ms | 5 ns | 69.06 us | 17.1 KiB |
| 2026-10-23 | #581: a sleeping worker leaves the run-next notice set | rig-fast | 79 ns | 44 ns | 76.4 ms | 5 ns | 53.21 us | 17.1 KiB |
| 2026-10-27 | main 54a7158b5 before #725, interleaved | rig-fast | 111 ns | 44 ns | 83.7 ms | 5 ns | 81.34 us | 17.1 KiB |
| 2026-10-27 | #725: a freed large block serves any request it fits | rig-fast | 112 ns | 44 ns | 83.5 ms | 5 ns | 75.66 us | 17.1 KiB |
| 2026-10-27 | main 967e1ac11 before #726, interleaved | rig-fast | 109 ns | 42 ns | 81.8 ms | 5 ns | 87.38 us | 17.1 KiB |
| 2026-10-27 | #726: huge pages for new blocks of 16 MiB or more (Linux only) | rig-fast | 96 ns | 43 ns | 82.5 ms | 5 ns | 81.33 us | 17.1 KiB |
| 2026-10-28 | main de6ef3e41 before #767, interleaved | rig-fast | 103 ns | 41 ns | 79.8 ms | 5 ns | 99.44 us | 17.1 KiB |
| 2026-10-28 | #767: a frozen value's allocation has no weak count | rig-fast | 98 ns | 42 ns | 80.7 ms | 5 ns | 92.94 us | 17.1 KiB |
| 2026-10-29 | main 277fba515 before #773, interleaved | rig-fast | 113 ns | 48 ns | 101.3 ms | 7 ns | 91.19 us | 17.1 KiB |
| 2026-10-29 | #773: pointer-sized ^T? and ~T?, no dead drops, a cheaper last drop | rig-fast | 112 ns | 50 ns | 91.0 ms | 8 ns | 109.10 us | 17.1 KiB |
| 2026-10-30 | main a8acfdc5c before #779, interleaved | rig-fast | 100 ns | 45 ns | 84.9 ms | 5 ns | 76.29 us | 17.1 KiB |
| 2026-10-30 | #779: no read buffer held while waiting, untouched signal stacks and fresh stacks, TCP_NODELAY | rig-fast | 84 ns | 45 ns | 88.7 ms | 5 ns | 76.95 us | 16.6 KiB |
| 2026-10-30 | main a8acfdc5c before #781 | rig-fast | 112 ns | 44 ns | 84.9 ms | 5 ns | 94.74 us | 17.1 KiB |
| 2026-10-30 | main a8acfdc5c before #781 | rig-safe | 91 ns | 54 ns | 75.1 ms | 6 ns | 79.08 us | 17.1 KiB |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-fast | 110 ns | 45 ns | 85.7 ms | 5 ns | 107.39 us | 17.1 KiB |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-safe | 90 ns | 54 ns | 71.6 ms | 5 ns | 117.56 us | 17.1 KiB |
| 2026-10-30 | main a8acfdc5c before #780, alternated | rig-fast | 110 ns | 45 ns | 88.0 ms | 5 ns | 79.97 us | 17.1 KiB |
| 2026-10-30 | #780: String and List appends grow by value | rig-fast | 92 ns | 45 ns | 88.5 ms | 5 ns | 95.72 us | 17.1 KiB |

## x86-64 (pup)

The same benchmarks on pup: Linux, x86-64, 22 cores. Tokio builds from
the crates.io release (pup has no `misc/tokio` clone).

| Date | Change | Variant | spawn (per task) | chain (per task) | fanout (per run) | yield (per yield) | hog (per step) | memory (per task) |
|---|---|---|---|---|---|---|---|---|
| 2026-10-19 | reference | tokio | 252 ns | 252 ns | 101.2 ms | 44 ns | 2.3 ms | 372 B |
| 2026-10-19 | reference | go | 272 ns | 265 ns | 84.9 ms | 474 ns | 1.9 ms | 2.9 KiB |
| 2026-10-19 | #352: Zig's `Threaded` backend | rig-fast | 20.37 us | 19.94 us | 109.3 ms | 98 ns |
| 2026-10-19 | #352: waiting without spinning | rig-sched | 274 ns | 82 ns | 108.0 ms | 7 ns |
| 2026-10-19 | #355: yield checks | rig-sched | 222 ns | 82 ns | 96.7 ms | 7 ns | 73.60 us |
| 2026-10-19 | #356: the scheduler is the default | rig-fast | 272 ns | 82 ns | 103.8 ms | 7 ns | 71.54 us | 9.0 KiB |
| 2026-10-19 | #358: guards sized to the program | rig-fast | 311 ns | 76 ns | 102.3 ms | 7 ns | 55.78 us | 5.2 KiB |
| 2026-10-19 | #371: deterministic runs | rig-fast | 272 ns | 82 ns | 99.6 ms | 9 ns | 46.50 us | 5.2 KiB |
| 2026-10-19 | #372: task.isolate | rig-fast | 313 ns | 78 ns | 101.4 ms | 9 ns | 82.35 us | 5.2 KiB |
| 2026-10-20 | #383: actors | rig-fast | 270 ns | 79 ns | 97.9 ms | 11 ns | 57.12 us | 5.2 KiB |
| 2026-10-20 | #386: the idle path | rig-fast | 246 ns | 83 ns | 98.1 ms | 8 ns | 79.89 us | 5.2 KiB |
| 2026-10-20 | #389: deadlock detection | rig-fast | 278 ns | 79 ns | 98.0 ms | 8 ns | 69.41 us | 5.2 KiB |
| 2026-10-20 | #391: actor failure | rig-fast | 298 ns | 78 ns | 99.4 ms | 8 ns | 69.97 us | 5.2 KiB |
| 2026-10-20 | #392: supervised actors | rig-fast | 271 ns | 84 ns | 107.9 ms | 8 ns | 66.15 us | 5.2 KiB |
| 2026-10-20 | #393: pollers and timers per worker | rig-fast | 273 ns | 78 ns | 91.2 ms | 5 ns | 68.24 us | 5.2 KiB |
| 2026-10-20 | #405: free tasks run on any worker again | rig-fast | 276 ns | 79 ns | 93.6 ms | 8 ns | 91.87 us | 5.2 KiB |
| 2026-10-21 | #535: interrupts cancel main | rig-fast | 194 ns | 92 ns | 93.4 ms | 5 ns | 67.07 us | 5.3 KiB |
| 2026-10-22 | main before #541, interleaved (pup cores 8,9) | rig-fast | 73 ns | 96 ns | 344.1 ms | 24 ns | 156.09 us | 4.6 KiB |
| 2026-10-22 | #541: a run-next fill wakes no worker (pup cores 8,9) | rig-fast | 69 ns | 86 ns | 314.3 ms | 27 ns | 133.24 us | 4.6 KiB |
| 2026-10-22 | main before #552, interleaved (pup cores 8,9) | rig-fast | 68 ns | 86 ns | 309.7 ms | 25 ns | 130.13 us | 4.6 KiB |
| 2026-10-22 | #552: each worker on cache lines of its own (pup cores 8,9) | rig-fast | 64 ns | 86 ns | 309.6 ms | 22 ns | 130.50 us | 4.6 KiB |
| 2026-10-23 | main before #581, interleaved (pup cores 8,9) | rig-fast | 61 ns | 86 ns | 310.8 ms | 23 ns | 130.79 us | 4.6 KiB |
| 2026-10-23 | #581: a sleeping worker leaves the run-next notice set (pup cores 8,9) | rig-fast | 63 ns | 86 ns | 310.3 ms | 23 ns | 130.86 us | 4.6 KiB |
| 2026-10-24 | main before #621, interleaved (pup cores 8,9) | rig-fast | 62 ns | 87 ns | 309.7 ms | 22 ns | 130.07 us | 4.6 KiB |
| 2026-10-24 | #621: os.memory counts each allocation (pup cores 8,9) | rig-fast | 64 ns | 86 ns | 309.6 ms | 22 ns | 130.11 us | 4.6 KiB |
| 2026-10-24 | main before #624, interleaved (pup cores 6,7) | rig-fast | 64 ns | 91 ns | 310.8 ms | 24 ns | 134.49 us | 4.6 KiB |
| 2026-10-24 | #624: the blocking pool keeps a few threads busy (pup cores 6,7) | rig-fast | 64 ns | 90 ns | 311.0 ms | 24 ns | 134.76 us | 4.6 KiB |
| 2026-10-25 | main before #677, interleaved (pup cores 6,7) | rig-fast | 66 ns | 92 ns | 331.0 ms | 24 ns | 140.85 us | 4.6 KiB |
| 2026-10-25 | #677: fewer yield checks (pup cores 6,7) | rig-fast | 66 ns | 93 ns | 333.6 ms | 25 ns | 140.56 us | 4.6 KiB |
| 2026-10-25 | main 99dcccf13 (before #677 and #683), interleaved (pup cores 6,7) | rig-fast | 63 ns | 89 ns | 309.8 ms | 25 ns | 135.02 us | 4.6 KiB |
| 2026-10-25 | #683: the pool's spin lock waits by reading (pup cores 6,7) | rig-fast | 63 ns | 87 ns | 310.0 ms | 24 ns | 134.40 us | 4.6 KiB |
| 2026-10-27 | main 54a7158b5 before #725, interleaved (pup cores 6,7) | rig-fast | 60 ns | 86 ns | 309.8 ms | 22 ns | 131.65 us | 4.6 KiB |
| 2026-10-27 | #725: a freed large block serves any request it fits (pup cores 6,7) | rig-fast | 61 ns | 85 ns | 310.0 ms | 21 ns | 131.06 us | 4.6 KiB |
| 2026-10-27 | main 967e1ac11 before #726, interleaved (pup cores 6,7) | rig-fast | 60 ns | 86 ns | 310.0 ms | 21 ns | 130.86 us | 4.6 KiB |
| 2026-10-27 | #726: huge pages for new blocks of 16 MiB or more (pup cores 6,7) | rig-fast | 60 ns | 85 ns | 310.1 ms | 21 ns | 130.64 us | 4.6 KiB |
| 2026-10-28 | main de6ef3e41 before #767, interleaved (pup core 6) | rig-fast | 79 ns | 85 ns | 595.6 ms | 34 ns | 176.92 us | 4.5 KiB |
| 2026-10-28 | #767: a frozen value's allocation has no weak count (pup core 6) | rig-fast | 80 ns | 85 ns | 594.2 ms | 34 ns | 176.87 us | 4.5 KiB |
| 2026-10-29 | main 277fba515 before #773, interleaved (pup core 6) | rig-fast | 85 ns | 91 ns | 603.2 ms | 36 ns | 179.18 us | 4.5 KiB |
| 2026-10-29 | #773: pointer-sized ^T? and ~T?, no dead drops, a cheaper last drop (pup core 6) | rig-fast | 79 ns | 85 ns | 597.7 ms | 36 ns | 178.29 us | 4.5 KiB |
| 2026-10-30 | main a8acfdc5c before #779, interleaved (pup core 8) | rig-fast | 81 ns | 86 ns | 598.8 ms | 34 ns | 177.33 us | 4.5 KiB |
| 2026-10-30 | #779: no read buffer held while waiting, untouched signal stacks and fresh stacks, TCP_NODELAY (pup core 8) | rig-fast | 79 ns | 85 ns | 600.4 ms | 33 ns | 176.57 us | 4.5 KiB |
| 2026-10-30 | main a8acfdc5c before #781 | rig-fast | 195 ns | 86 ns | 97.5 ms | 4 ns | 42.46 us | 5.2 KiB |
| 2026-10-30 | main a8acfdc5c before #781 | rig-safe | 207 ns | 101 ns | 89.5 ms | 4 ns | 65.56 us | 5.3 KiB |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-fast | 205 ns | 91 ns | 97.8 ms | 4 ns | 42.93 us | 5.2 KiB |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-safe | 193 ns | 95 ns | 85.8 ms | 4 ns | 53.17 us | 5.3 KiB |
| 2026-10-30 | main a8acfdc5c before #780, alternated (pup core 6) | rig-fast | 79 ns | 85 ns | 593.5 ms | 35 ns | 177.51 us | 4.5 KiB |
| 2026-10-30 | #780: String and List appends grow by value (pup core 6) | rig-fast | 78 ns | 86 ns | 593.2 ms | 34 ns | 177.35 us | 4.5 KiB |
| 2026-10-30 | main 344257fc0 before #783 | rig-fast | 96 ns | 45 ns | 88.5 ms | 5 ns | 88.13 us | 16.6 KiB |
| 2026-10-30 | main 344257fc0 before #783 | rig-safe | 89 ns | 53 ns | 69.5 ms | 5 ns | 79.26 us | 16.6 KiB |
| 2026-10-30 | #783: a stream splits; an end wakes only its waits | rig-fast | 89 ns | 44 ns | 80.3 ms | 5 ns | 101.75 us | 16.6 KiB |
| 2026-10-30 | #783: a stream splits; an end wakes only its waits | rig-safe | 95 ns | 53 ns | 69.9 ms | 5 ns | 72.88 us | 16.6 KiB |
| 2026-10-30 | main 344257fc0 before #783, alternated (pup core 6) | rig-fast | 78 ns | 85 ns | 593.6 ms | 34 ns | 176.32 us | 4.5 KiB |
| 2026-10-30 | #783: a stream splits; an end wakes only its waits (pup core 6) | rig-fast | 78 ns | 86 ns | 593.8 ms | 34 ns | 176.23 us | 4.5 KiB |
