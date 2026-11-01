# Actor benchmark progress

Each row is one measurement of `bench/actors/bench-actors` (README.md):
time per call, best of 7, on an Apple M5 with 10 cores. Read down a
column to see how a benchmark moves. The reference rows are Tokio's and
Go's when the benchmark began; the Rig rows below them are added as
actors grow (`bench-actors --record "#PR: what changed"`, which appends
to the end of the file, so a Mac row moves up into its table).

| Date | Change | Variant | solo (per call) | contend (per call) | spread (per call) |
|---|---|---|---|---|---|
| 2026-10-20 | reference | tokio | 134 ns | 134 ns | 35 ns |
| 2026-10-20 | reference | go | 3.7 ns | 21 ns | 0.7 ns |
| 2026-10-20 | #383: actors, every call a message | rig-fast | 99 ns | 151 ns | 35 ns |
| 2026-10-20 | #386: the idle path | rig-fast | 4.9 ns | 6.9 ns | 1.6 ns |
| 2026-10-20 | #389: deadlock detection | rig-fast | 6.0 ns | 34 ns | 1.7 ns |
| 2026-10-20 | #391: actor failure | rig-fast | 5.9 ns | 42 ns | 1.3 ns |
| 2026-10-20 | #392: supervised actors | rig-fast | 5.0 ns | 33 ns | 1.0 ns |
| 2026-10-20 | #405: free tasks run on any worker again | rig-fast | 5.0 ns | 34 ns | 0.9 ns |
| 2026-10-21 | #535: interrupts cancel main | rig-fast | 5.0 ns | 29 ns | 0.9 ns |
| 2026-10-22 | main before #541, interleaved | rig-fast | 5.1 ns | 30 ns | 0.9 ns |
| 2026-10-22 | #541: a run-next fill wakes no worker | rig-fast | 5.0 ns | 33 ns | 1.0 ns |
| 2026-10-22 | main before #552, interleaved | rig-fast | 5.1 ns | 31 ns | 0.9 ns |
| 2026-10-22 | #552: each worker on cache lines of its own | rig-fast | 5.1 ns | 29 ns | 0.9 ns |
| 2026-10-23 | main before #581, interleaved | rig-fast | 5.0 ns | 40 ns | 1.0 ns |
| 2026-10-23 | #581: a sleeping worker leaves the run-next notice set | rig-fast | 5.0 ns | 40 ns | 0.9 ns |
| 2026-10-27 | main 54a7158b5 before #725, interleaved | rig-fast | 5.0 ns | 26 ns | 0.8 ns |
| 2026-10-27 | #725: a freed large block serves any request it fits | rig-fast | 5.0 ns | 25 ns | 0.8 ns |
| 2026-10-27 | main 967e1ac11 before #726, interleaved | rig-fast | 5.0 ns | 25 ns | 0.8 ns |
| 2026-10-27 | #726: huge pages for new blocks of 16 MiB or more (Linux only) | rig-fast | 5.0 ns | 25 ns | 0.8 ns |
| 2026-10-28 | main de6ef3e41 before #767, interleaved | rig-fast | 5.0 ns | 31 ns | 0.8 ns |
| 2026-10-28 | #767: a frozen value's allocation has no weak count | rig-fast | 5.0 ns | 30 ns | 0.9 ns |
| 2026-10-29 | main 277fba515 before #773, interleaved | rig-fast | 5.6 ns | 46 ns | 1.3 ns |
| 2026-10-29 | #773: pointer-sized ^T? and ~T?, no dead drops, a cheaper last drop | rig-fast | 5.6 ns | 49 ns | 1.3 ns |
| 2026-10-30 | main a8acfdc5c before #779, interleaved | rig-fast | 5.1 ns | 42 ns | 1.1 ns |
| 2026-10-30 | #779: no read buffer held while waiting, untouched signal stacks and fresh stacks, TCP_NODELAY | rig-fast | 5.1 ns | 40 ns | 1.1 ns |
| 2026-10-30 | main a8acfdc5c before #781 | rig-fast | 5.1 ns | 30 ns | 1.0 ns |
| 2026-10-30 | main a8acfdc5c before #781 | rig-safe | 5.2 ns | 30 ns | 0.9 ns |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-fast | 5.1 ns | 31 ns | 0.9 ns |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-safe | 5.2 ns | 30 ns | 1.0 ns |
| 2026-10-30 | main a8acfdc5c before #780, alternated | rig-fast | 5.1 ns | 29 ns | 0.9 ns |
| 2026-10-30 | #780: String and List appends grow by value | rig-fast | 5.0 ns | 30 ns | 0.9 ns |

## x86-64 (pup)

The same benchmarks on pup: Linux, x86-64, 22 cores. Tokio builds from
the crates.io release (pup has no `misc/tokio` clone).

| Date | Change | Variant | solo (per call) | contend (per call) | spread (per call) |
|---|---|---|---|---|---|
| 2026-10-20 | reference | tokio | 260 ns | 252 ns | 16 ns |
| 2026-10-20 | reference | go | 12 ns | 66 ns | 1.3 ns |
| 2026-10-20 | #386: the idle path | rig-fast | 13 ns | 33 ns | 2.2 ns |
| 2026-10-20 | #389: deadlock detection | rig-fast | 15 ns | 32 ns | 1.8 ns |
| 2026-10-20 | #391: actor failure | rig-fast | 12 ns | 31 ns | 1.8 ns |
| 2026-10-20 | #392: supervised actors | rig-fast | 14 ns | 34 ns | 2.3 ns |
| 2026-10-20 | #405: free tasks run on any worker again | rig-fast | 17 ns | 38 ns | 2.2 ns |
| 2026-10-21 | #535: interrupts cancel main | rig-fast | 14 ns | 30 ns | 1.8 ns |
| 2026-10-22 | main before #541, interleaved (pup cores 8,9) | rig-fast | 13 ns | 17 ns | 12 ns |
| 2026-10-22 | #541: a run-next fill wakes no worker (pup cores 8,9) | rig-fast | 11 ns | 14 ns | 10 ns |
| 2026-10-22 | main before #552, interleaved (pup cores 8,9) | rig-fast | 12 ns | 15 ns | 11 ns |
| 2026-10-22 | #552: each worker on cache lines of its own (pup cores 8,9) | rig-fast | 11 ns | 14 ns | 10 ns |
| 2026-10-23 | main before #581, interleaved (pup cores 8,9) | rig-fast | 12 ns | 14 ns | 11 ns |
| 2026-10-23 | #581: a sleeping worker leaves the run-next notice set (pup cores 8,9) | rig-fast | 11 ns | 14 ns | 10 ns |
| 2026-10-24 | main before #621, interleaved (pup cores 8,9) | rig-fast | 12 ns | 14 ns | 11 ns |
| 2026-10-24 | #621: os.memory counts each allocation (pup cores 8,9) | rig-fast | 11 ns | 14 ns | 10 ns |
| 2026-10-24 | main before #624, interleaved (pup cores 6,7) | rig-fast | 12 ns | 15 ns | 11 ns |
| 2026-10-24 | #624: the blocking pool keeps a few threads busy (pup cores 6,7) | rig-fast | 12 ns | 15 ns | 11 ns |
| 2026-10-25 | main before #677, interleaved (pup cores 6,7) | rig-fast | 13 ns | 16 ns | 11 ns |
| 2026-10-25 | #677: fewer yield checks (pup cores 6,7) | rig-fast | 13 ns | 16 ns | 11 ns |
| 2026-10-25 | main 99dcccf13 (before #677 and #683), interleaved (pup cores 6,7) | rig-fast | 12 ns | 15 ns | 11 ns |
| 2026-10-25 | #683: the pool's spin lock waits by reading (pup cores 6,7) | rig-fast | 12 ns | 15 ns | 11 ns |
| 2026-10-27 | main 54a7158b5 before #725, interleaved (pup cores 6,7) | rig-fast | 11 ns | 15 ns | 10 ns |
| 2026-10-27 | #725: a freed large block serves any request it fits (pup cores 6,7) | rig-fast | 11 ns | 15 ns | 10 ns |
| 2026-10-27 | main 967e1ac11 before #726, interleaved (pup cores 6,7) | rig-fast | 11 ns | 15 ns | 10 ns |
| 2026-10-27 | #726: huge pages for new blocks of 16 MiB or more (pup cores 6,7) | rig-fast | 11 ns | 15 ns | 10 ns |
| 2026-10-28 | main de6ef3e41 before #767, interleaved (pup core 6) | rig-fast | 11 ns | 11 ns | 12 ns |
| 2026-10-28 | #767: a frozen value's allocation has no weak count (pup core 6) | rig-fast | 11 ns | 11 ns | 12 ns |
| 2026-10-29 | main 277fba515 before #773, interleaved (pup core 6) | rig-fast | 11 ns | 11 ns | 12 ns |
| 2026-10-29 | #773: pointer-sized ^T? and ~T?, no dead drops, a cheaper last drop (pup core 6) | rig-fast | 11 ns | 11 ns | 12 ns |
| 2026-10-30 | main a8acfdc5c before #779, interleaved (pup core 8) | rig-fast | 11 ns | 11 ns | 12 ns |
| 2026-10-30 | #779: no read buffer held while waiting, untouched signal stacks and fresh stacks, TCP_NODELAY (pup core 8) | rig-fast | 11 ns | 11 ns | 12 ns |
| 2026-10-30 | main a8acfdc5c before #781 | rig-fast | 12 ns | 36 ns | 1.6 ns |
| 2026-10-30 | main a8acfdc5c before #781 | rig-safe | 17 ns | 36 ns | 2.0 ns |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-fast | 13 ns | 34 ns | 1.7 ns |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-safe | 13 ns | 35 ns | 1.8 ns |
| 2026-10-30 | main a8acfdc5c before #780, alternated (pup core 6) | rig-fast | 12 ns | 12 ns | 12 ns |
| 2026-10-30 | #780: String and List appends grow by value (pup core 6) | rig-fast | 12 ns | 12 ns | 12 ns |
| 2026-10-30 | main 344257fc0 before #783 | rig-fast | 5.0 ns | 28 ns | 0.9 ns |
| 2026-10-30 | main 344257fc0 before #783 | rig-safe | 5.2 ns | 26 ns | 0.9 ns |
| 2026-10-30 | #783: a stream splits; an end wakes only its waits | rig-fast | 5.0 ns | 27 ns | 0.9 ns |
| 2026-10-30 | #783: a stream splits; an end wakes only its waits | rig-safe | 5.2 ns | 26 ns | 0.9 ns |
| 2026-10-30 | main 344257fc0 before #783, alternated (pup core 6) | rig-fast | 11 ns | 11 ns | 12 ns |
| 2026-10-30 | #783: a stream splits; an end wakes only its waits (pup core 6) | rig-fast | 11 ns | 11 ns | 12 ns |
| 2026-10-30 | main before #788, alternated (pup core 6) | rig-fast | 11 ns | 11 ns | 12 ns |
| 2026-10-30 | #788: reads grow a String unfilled (pup core 6) | rig-fast | 11 ns | 11 ns | 12 ns |
| 2026-10-31 | #815: a heap that does not fault in ahead keeps 1 MiB of freed large blocks resident | rig-fast | 5.0 ns | 28 ns | 0.9 ns |
| 2026-10-31 | main 1ac34e1bb before #819, alternated (pup core 6) | rig-fast | 11 ns | 14 ns | 10 ns |
| 2026-10-31 | #819: a pool call's waiter yields while the call finishes (pup core 6) | rig-fast | 11 ns | 14 ns | 10 ns |
| 2026-10-31 | main 1ac34e1bb before #819, alternated (Mac, load 8-11) | rig-fast | 5 ns | 27 ns | 0.9 ns |
| 2026-10-31 | #819: a pool call's waiter yields while the call finishes (Mac, load 8-11) | rig-fast | 5 ns | 27 ns | 0.8 ns |
| 2026-10-31 | main 1ac34e1bb before row 22 seg, alternated (pup core 6) | rig-fast | 11 ns | 14 ns | 10 ns |
| 2026-10-31 | row 22 seg: segments ask for huge pages at a low floor (pup core 6) | rig-fast | 11 ns | 14 ns | 10 ns |
