# Fork-join against Rayon, each half in the same order (2026-11-18)

The fork-join board's Rig program and its Rayon twin walked memory in
opposite orders. This record holds the program that walks it Rayon's way,
both orders for both runtimes, and the Mac's board of the four.

## The two orders

`rayon::join(a, b)` runs `a` on the calling thread and offers `b` to the
other threads. A Rig `&` offers its call and the maker runs on. So

    a = psum(?left)&
    b = psum(xs[mid..])

offers the left half and runs the right: the opposite of
`rayon::join(|| psum(l), || psum(r))`. With one worker the offered half
runs last, so that program sums its 4,096 leaves from the top of the array
down, each leaf forwards, and Rayon's sums them from the bottom up. The
hardware's prefetchers follow a forward walk and lose a backward one at
every leaf.

The twin of `rayon::join(|| psum(l), || psum(r))` offers the right half:

    b = psum(?right)&
    a = psum(xs[..mid])
    a +% >b

| program | the maker runs | offered to other workers |
|---|---|---|
| [fork.rig](fork.rig) | the first half | the second |
| [rayon/](rayon/src/main.rs) | the first half | the second |
| [fork-left.rig](fork-left.rig) | the second half | the first |
| [rayon-right-first/](rayon-right-first/src/main.rs) | the second half | the first |

fork.rig and rayon/ are the pair a board compares. fork-left.rig is the
program of [concurrency-bench-remeasure](../concurrency-bench-remeasure/)
and of the [2026-11-18 standings](../standings-1118/); rayon-right-first/
is its twin. qsort's halves are swapped the same way in each.

## The Mac's board

Apple M5 (4 performance and 6 efficiency cores), macOS 27.2.1. Rig main
08b2caf1a (after #1151), `rig build --release`; Rayon 1.12.0, Rust 1.99.1,
`cargo build --release` (LTO, one codegen unit). Each process times one
psum (2^25 Ints, leaves of 8,192) and one qsort (2^22 Ints). Three boards
under `tools/mac-claim`, 100 rounds in all; a round runs every program at 1
worker and at 10, the programs in rotating order ([board.py](board.py),
[stats.py](stats.py), samples in [raw/](raw/)). `aa` is fork.rig built a
second time. Every run's checks agree (psum 16760439056, qsort 4194304).
The Mac carried other work throughout (load 3 to 5), so the medians are
slower than a quiet machine's and the paired ratios are what compare.

Medians, ms:

| row | workers | fork.rig | aa | fork-left.rig | rayon | rayon-right-first |
|---|---:|---:|---:|---:|---:|---:|
| psum | 1 | 6.82 | 6.84 | 7.65 | 6.49 | 7.38 |
| psum | 10 | 2.74 | 2.76 | 2.77 | 2.64 | 2.70 |
| qsort | 1 | 168.43 | 168.85 | 173.37 | 156.62 | 157.30 |
| qsort | 10 | 60.54 | 60.66 | 59.07 | 58.95 | 58.20 |

Ratios paired by round, median [quartiles], and the rounds the first
program won:

| row | workers | fork.rig / rayon | fork-left.rig / rayon-right-first | fork-left.rig / rayon | A/A (aa / fork.rig) |
|---|---:|---|---|---|---|
| psum | 1 | 1.048 [0.977-1.169] 32 | 1.034 [0.963-1.118] 33 | 1.190 [1.088-1.271] 8 | 0.967 [0.877-1.054] 64 |
| psum | 10 | 1.021 [0.963-1.080] 38 | 1.035 [0.977-1.127] 34 | 1.057 [0.962-1.153] 35 | 1.004 [0.939-1.101] 48 |
| qsort | 1 | 1.085 [1.059-1.109] 8 | 1.100 [1.083-1.126] 1 | 1.108 [1.084-1.139] 3 | 0.992 [0.977-1.015] 60 |
| qsort | 10 | 1.026 [0.975-1.059] 35 | 1.011 [0.960-1.051] 41 | 0.997 [0.939-1.042] 54 | 1.011 [0.965-1.048] 45 |

What the order alone costs each runtime (the backward walk over the
forward one, paired):

| row | workers | Rig (fork-left.rig / fork.rig) | Rayon (rayon-right-first / rayon) |
|---|---:|---|---|
| psum | 1 | 1.121 [1.037-1.216] | 1.119 [1.057-1.207] |
| psum | 10 | 1.041 [0.975-1.124] | 1.008 [0.946-1.092] |
| qsort | 1 | 1.025 [1.000-1.052] | 1.006 [0.994-1.016] |
| qsort | 10 | 0.968 [0.919-1.026] | 0.983 [0.958-1.008] |

## What it shows

- **psum, one worker.** The backward walk costs each runtime 12%. Against
  Rayon's forward walk the old program was 19% slower; in the same order
  Rig is 5% slower (and 3% slower when both walk backward). The A/A arm
  reads 3% off level on this row, so 5% is within about 3% either way.
- **psum, 10 workers.** Level in either order: 2% slower, inside the A/A
  quartiles.
- **qsort, one worker.** The order is worth 2.5% to Rig and nothing to
  Rayon (its halves are separate Lists, not one array). Rig is 8.5% slower
  in the same order, where the old pair read 11%.
- **qsort, 10 workers.** Level in either order. Both runtimes run a little
  faster offering the low half (Rig 3%, Rayon 2%); in the same order Rig is
  2.6% slower, inside the A/A quartiles.

The order is the program's, not the runtime's: `&` offers its call and the
maker runs on. A fork-join over one array reads it forwards when the maker
keeps the first half.
