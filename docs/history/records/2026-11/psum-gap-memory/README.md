# psum gap: the memory system (2026-11-18)

Expert: memory system. Programs: fork.rig at main's code (a303f69fd = 3ffd5672d in src/std) and its Rayon
twin, the standings-1118 binaries on pup (/zfs/trig-pup/standings-1118/fork/{rig,rig-aa,rayon}), fresh
builds on the Mac. Raw data, scripts and summaries: `data/` beside this file (pup copies in
/zfs/trig-pup/psum-gap/mem/). Every run's sums agreed (psum 16760439056, qsort 4194304).

## Findings

1. **pup, all workers: each worker heap's first huge page is faulted inside the timed pass. It costs
   Rig about 1.2 ms of 5.9 (20%), nearly the whole 12-worker gap.** A new worker's first small block (a
   task record) writes its heap's first segment, which asks `MADV_HUGEPAGE` (alloc.zig `newPage`), so
   the first write faults and zeroes 2 MiB. With 12 workers that is 24 MiB of zeroing on 12 critical
   paths while psum saturates DRAM. Evidence:
   - Every page fault of one run, recorded with perf (8 workers, E-cores). In the 10.6 ms after the
     first worker fault there are 7 faults on 4 MiB-aligned segment headers, one per new worker heap,
     plus 123 four-KiB task-stack faults.
   - THP switched off for the whole process (prctl wrapper): Rig at 12 workers is 10-12% *faster*
     (5.57 against 6.32 ms, and 5.27 against 5.88), although its input then sits on small pages.
     Rayon with glibc's THP tunable is 23% slower (5.84 against 4.75): the same mechanism, through
     glibc's per-thread arenas.
   - Probe A (a heap's first segment keeps small pages, `dae70a0be`) and probe B (its first 2 MiB small,
     its second 2 MiB still asking huge, `fa7d173b0`), branch `psum-mem`. 20 rounds each, slots 581 and
     582:

| 12 workers, psum | main | A/A | probe A | probe B | Rayon |
|---|---|---|---|---|---|
| slot 581 | 5.88 (5.60-6.50) | 5.93 | 4.55 (4.37-5.43) | | 4.65 |
| slot 582 | 5.97 (5.48-6.62) | 6.27 | 4.90 (4.36-5.33) | 4.78 (4.41-5.74) | 4.64 |

   Probe B: main takes 1.25x as long. Rig against Rayon goes from 29% slower to 3% slower. In slot 581
   probe A was 2% faster than Rayon.
   - At 1 worker neither probe moves psum (14.47-14.55 against 14.48). qsort at 1 worker:
     probe A is 3.0% and 3.1% slower in two boards (A/A 0.4-0.9%), because the main heap's first 4 MiB
     lose huge pages. Probe B is 0.7% slower, within noise. qsort at 12 workers: both level.
   - Peak RSS (whole process, 3 runs, `/usr/bin/time`) and THP faults are unchanged by probe A
     (w1: main 863-970 MB, A 970-1,015; w8: 866-903 against 836-899; THP faults about 440-505 each).
     A probe can only commit less, up to 2 MiB less per heap that stays small.

2. **pup, 1 worker: the gap is not memory.** One pass at the memory ceiling (bw.zig: write psum's input,
   time one pass on P-core 6) takes 10.6-11.2 ms on huge pages and 11.25 on small ones. Rayon runs at
   11.9 on small pages, 5% above its ceiling. Rig runs at 14.1-14.5 on huge pages, 30% above its own.
   Rig's dTLB load misses are a sixth of Rayon's (whole process: 16k against 100k), and its huge pages
   are worth 2-6% to it (THP off: 14.76-14.88). The other ~3 ms belongs to the per-split and scheduler
   costs and the leaf, not to bandwidth.

3. **Leaf order costs bandwidth, a lot on the Mac.** fork.rig puts the *left* half on the task and runs
   the right half itself. So at one worker the leaves run right to left, each 64 KiB read forwards.
   Rayon's `join(l, r)` runs left first: ascending. The bw ceiling, same data, leaves descending against
   ascending:
   - pup: 1% slower (huge pages, vectors), 4% (small pages, vectors), 16% (scalar).
   - Mac M5, P-core: **28% slower** (5.62 against 4.40 ms).

   On the Mac, Rig at 1 worker (6.00 ms) sits at the descending ceiling plus start-up, and Rayon
   (4.22 ms) at the ascending one. Most of the Mac's one-worker gap is this order: the hardware
   prefetchers ramp up on forward streams. The runtime expert's splitR/rayonR arms test the swap.
   A fair twin of `rayon::join(|| psum(l), || psum(r))` spawns the right half. Spawning the right half
   changes the benchmark, not the compiler.

4. **Mac, all workers: at the ceiling.** 10 threads read at 2.61 ms (103 GB/s); Rig takes 2.63, Rayon
   2.52 (Rig 4% slower). There are no huge pages, and a worker heap's first segment faults 16 KiB at a
   time, so finding 1 does not arise there.

5. **Other.** Rig's task-stack faults inside the pass (123 four-KiB faults in 10 ms at 8 workers) cost
   about 0.1-0.2 ms. Placing stacks is the scheduler's job; I note it and leave it. fork.rig's peak RSS
   is 1.3-1.8x Rayon's (Rig 0.86-1.0 GB, Rayon 0.50-0.71 GB), most of it after psum (qsort's Lists, or
   freed blocks kept per heap). That lies outside psum and is worth a look of its own.

## Numbers (medians, ms; ranges in data files)

| | pup 1 worker | pup 12 workers | Mac 1 worker | Mac 10 workers |
|---|---|---|---|---|
| Rig main | 14.48 | 5.97 | 6.00 | 2.63 |
| Rig, probe B | 14.50 | 4.78 | n/a (Linux only) | n/a |
| Rayon | 11.91 | 4.64 | 4.22 | 2.52 |
| ceiling (bw, ascending) | 10.6-11.2 (huge), 11.25 (small) | 3.14 (huge), 3.30 (small) | 4.40 | 2.61 |
| ceiling, leaves descending | 11.28 (huge, vec) | | 5.62 | |

The Mac board ran under tools/mac-claim for 15 rounds. Its ranges are wide (an A/A of 4.5% at 1
worker). pup slots: 580 (memory board, 10 rounds), 581 and 582 (probes, 20 rounds each). In slot 581
another session ran a build on E-core 16 (quiet check not honoured), and slot 582 repeats its result
quietly.

## The change as built

Built as `alloc: a heap's first segment keeps small pages for its first 2 MiB` (branch
`seg-first-small`, from 08b2caf1a, which has #1151's wider fold). In `newPage`, a heap's first
segment asks for huge pages only for its second 2 MiB, as long as the heap has taken nothing else
(`h.taken <= segment_size`, as probe B), and asks for small pages for its first 2 MiB, which matters
only under `enabled=always` (`firstHalfSmall`). The segment counts as one of small pages.

Boards on pup (`data/m4.py`, rounds of fork at 1 worker on P-core 6 and 12 on 0-11 with Rayon,
bench/tasks at 12 workers on 0-11 and bench/net in slot 583's rounds; arms rotating; quiet checks
honoured). Slots 583 (20 rounds), 584 (30) and 585 (30, with probe C below). Branch against main,
medians; A/A against main in brackets:

| row | slot 583 | slot 584 | slot 585 |
|---|---|---|---|
| psum, 12 workers | 0.828 (0.991) | 0.821 (1.003) | 0.814 (1.032) |
| psum, 1 worker | 1.017 (1.001) | 1.015 (0.998) | 1.017 (1.003) |
| qsort, 12 workers | 0.992 (0.961) | 1.009 (1.028) | 1.008 (1.017) |
| qsort, 1 worker | 0.999 (0.990) | 1.011 (1.012) | 0.990 (0.992) |
| tasks spawn | 0.993 (1.009) | 0.973 (0.977) | 0.996 (0.998) |
| tasks chain | 0.997 (0.996) | 0.998 (0.994) | 0.999 (1.002) |
| tasks fanout | 0.999 (1.001) | 1.000 (0.994) | 1.001 (1.001) |
| tasks yield | 0.947 (0.979) | 0.956 (1.010) | 0.985 (1.026) |
| tasks hog | 1.178 (1.003) | 1.115 (1.021) | 1.025 (0.984) |
| tasks produce | 0.991 (0.995) | 0.999 (0.982) | 1.013 (1.003) |
| net pingpong | 0.992 (0.991) | | |
| net echo | 0.994 (1.010) | | |
| net connect | 0.998 (0.987) | | |

- psum at 12 workers, ms: main 5.89, 5.84, 5.82; branch 4.88, 4.80, 4.74; Rayon 4.84, 4.66, 4.65.
  Rig against Rayon goes from 22-27% slower to 1-3% slower.
- psum at 1 worker, ms: main 12.39, 12.42, 12.36; branch 12.61, 12.61, 12.57; Rayon 11.88, 11.80,
  11.88. The branch is 1.5-1.7% slower in all three boards, beyond the A/A arm. Whole-process counts at
  1 worker (E-core 13, two runs each) show 1,752-1,867 page faults against 1,115-1,406, dTLB load
  misses 24.6k-26.5k against 16.3k-19.0k, and store misses 12.3k-13.0k against 2.6k-3.7k. Kernel cycles
  are not higher (the 2 MiB zeroing they replace costs more), and user cycles are 2-4% higher: the cost
  is TLB misses on the heap's first 2 MiB.
- hog is about 20 us a step and its range is 0.014-0.036 ms in every arm. The branch reads 2.5-18%
  slower in its median, and the effect is not settled at this noise.
- Peak RSS (`/usr/bin/time`, E-cores 12-19, 5 interleaved runs, `data/rss.txt`):

| program | main | branch |
|---|---|---|
| fork, 1 worker | 919 MB | 918 MB |
| fork, 8 workers | 898 MB | 887 MB |
| bench/tasks, the timed run | 8.7 MB | 2.3 MB |
| bench/tasks `idle` | 2.31 MB | 0.39 MB |
| bench/tasks `many` (10,000 tasks asleep) | 48.1 MB | 47.4 MB |

  bench-tasks' `memory` row is (`many` - `idle`) / 10,000: 4.58 KB a task on main and 4.70 on the
  branch. Every number is lower, but the baseline it subtracts falls further.
- Probe C (`ce0f3edd6`, not kept): the program's first heap exempt (`h.all_next != null`). Slot 585:
  psum at 1 worker 0.7% slower, at 12 workers 0.806, but qsort at 1 worker 3.7% slower and hog 22%
  slower. It was dropped.

Not measured here (the lead runs them): Trig's light gate and timing A/B, and the Linux unit tests.
