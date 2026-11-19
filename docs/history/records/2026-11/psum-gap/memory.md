# psum gap, the memory system (2026-11-18)

Expert: memory system. Programs: fork.rig at main's code (a303f69fd = 3ffd5672d in src/std) and its Rayon
twin, the standings-1118 binaries on pup (/zfs/trig-pup/standings-1118/fork/{rig,rig-aa,rayon}), fresh
builds on the Mac. Raw data, scripts and summaries: `psum-gap/memory-data/` (pup copies in
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

## The decision (owner): huge pages for a heap's first segment

alloc.zig asks huge pages for every segment, "a heap's first as its later ones", knowing it "costs a
heap that keeps to one segment ... up to 2 MiB it has not written". That is a deliberate huge-page policy
(THP Design A and the kernel-leads records). So I report the change and have not opened a PR. The change
(probe B, cleaned):

- In `newPage`, a heap's first segment (`h.segment == null`, not `h.taken`) asks huge pages only for its
  second 2 MiB, and marks the segment `huge = false` so its pages fault in ahead as small ones do.
- Under `enabled=always`, it asks small pages for the first 2 MiB (`ask(s, huge_page, .small)`).
- Its doc comment and the file's header say so.

It costs at most 512 small-page TLB entries per heap and commits less memory. Before it lands it needs
Trig's light gate and a Trig timing board (checker heaps' first segments), bench/tasks, bench/net, the
guards, and a qsort board.

Default: approve probe B as a change of its own, with those gates.

## Built (lead's request): PR #1156, draft

Branch `seg-first-small` (from 08b2caf1a). Its full numbers are in the tracked record
docs/history/records/2026-11/psum-gap-memory/README.md ("The change as built").
- psum at 12 workers takes 18-19% less time; Rig is 1-3% behind Rayon, from 22-27%.
- psum at 1 worker is 1.5-1.7% slower (TLB misses on the first 2 MiB).
- qsort, bench/tasks (except a noisy hog row) and bench/net are level.
- bench/tasks' peak memory is 2.3 MB, from 8.7.
- Probe C (the first heap exempt) was dropped: qsort at 1 worker was 3.7% slower.
