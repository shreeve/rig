# bench/fork against Rayon, pup, Rig a303f69fd (2026-11-18)

- **Machine:** pup (Intel Core Ultra 9 185H, x86-64 Linux), ab slot 557 (15 min, opened 15:42:28, closed
  15:43:08 by the script's trap), 1,969 free 2 MiB blocks, load under 1, no other holder.
  `quiet-check.sh 557`: honoured (no user process ran on cores 12-19 during the slot).
- **Programs:** docs/history/records/2026-11/concurrency-bench-remeasure/fork: `fork.rig` built by
  `rig build --release` (ReleaseSafe) with Rig a303f69fd (`tools/pup-rig`, /zfs/trig-pup/rig-a303f69fd);
  the A/A arm is a byte copy of that binary (`cmp` equal); the Rayon twin is the 2026-11-15 build
  (/zfs/trig-pup/bench-remeasure-3f4564a4b/build/fork/rayon; the source is unchanged since; Rayon 1.11,
  LTO, one codegen unit).
- **Method:** `s1118-fork-board.py` (scripts/), 20 rounds; each round runs both configurations in
  alternating order and the three arms in rotating order. 1 worker: `taskset -c 6` (sibling 7 idle),
  `RIG_WORKERS=1 RAYON_NUM_THREADS=1`. 12 workers: `taskset -c 0-11`, `RIG_WORKERS=12
  RAYON_NUM_THREADS=12`. The driver ran on P-core 8. Every run's check agreed (psum 16760439056, qsort
  4194304). Each process times one psum (2^25 Ints, grain 8,192) and one qsort (2^22 Ints, grain 8,192).
- Raw samples: raw/fork-samples.txt; the board's output: raw/fork-board.txt.

## Results, ms (median of 20, range in brackets)

| config | row | Rig | A/A | Rayon | Rig against Rayon (medians) | A/A against Rig |
|---|---|---|---|---|---|---|
| 1 worker | psum | 14.36 (13.94-15.23) | 14.32 (13.95-14.54) | 11.89 (11.77-13.23) | Rig 21% slower | 0.3% |
| 1 worker | qsort | 255.78 (247.98-267.61) | 254.45 (246.10-265.18) | 266.85 (262.80-278.50) | Rig 4% faster | 0.5% |
| 12 workers | psum | 6.05 (5.36-7.27) | 6.03 (5.60-6.92) | 4.66 (4.42-5.23) | Rig 30% slower | 0.4% |
| 12 workers | qsort | 96.31 (83.67-102.06) | 96.77 (88.98-102.35) | 123.39 (115.41-137.80) | Rig 22% faster (Rayon takes 1.28x) | 0.5% |

The A/A arm lands within 0.5% of Rig on every row, well inside each row's spread.

## Against the last pup numbers (F2, 2026-11-15, Rig 1f35fc1da, cores 0-11, fastest of 20)

F2 kept only the fastest of each row, so the comparison is fastest against fastest, 12 workers:

| row | Rig F2 | Rig now | Rayon F2 | Rayon now | Rig/Rayon F2 | Rig/Rayon now |
|---|---|---|---|---|---|---|
| psum | 6.66 | 5.36 | 4.48 | 4.42 | 1.49 (49% slower) | 1.21 (21% slower) |
| qsort | 120.55 | 83.67 | 117.25 | 115.41 | 1.03 (3% slower) | 0.72 (Rayon takes 1.38x) |

Rayon is where it was (1-2% within noise); Rig's psum is 20% faster and its qsort 31% faster than on
15 Nov. Between 1f35fc1da and a303f69fd: b1a7b7b27 (`>t` takes its task back from its worker's ring and
runs it by handoff, #1147) and 2df40501c (a `for` that folds integers into a local runs by vectors,
#1146, which is psum's leaf loop `s +%= x`).

## Notes

- Neither row scales far: 12 workers against 1 is 2.4x (Rig) and 2.6x (Rayon) on psum, which reads
  256 MB once and is bound by memory bandwidth, and 2.7x (Rig) and 2.2x (Rayon) on qsort, whose top
  partitions run on one core.
- psum at one worker is 21% slower than Rayon, so the 12-worker psum gap is mostly the leaf loop and
  the per-split cost, not stealing.
- qsort's 12-worker spread is wide for both (Rig 22%, Rayon 19% from fastest to slowest).
- The 1-worker runs pin one core; Rig at RIG_WORKERS=1 still runs `&` through its scheduler.
