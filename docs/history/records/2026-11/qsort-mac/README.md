# qsort against Rayon on the Mac: where the time goes (2026-11-19)

The cell: fork-order's qsort ([fork.rig](../fork-order/fork.rig) against
[rayon/](../fork-order/rayon/src/main.rs)), 2^22 Ints, at 10 workers and at
1, on the Mac (Apple M5, 4 performance and 6 efficiency cores). Rig main
586e3939a (after #1158), `rig build --release`; Rayon 1.12.0, Rust 1.99.1,
LTO and one codegen unit. Every timed run inside `tools/mac-claim`, the
programs in rotating order, both worker counts each round
([pboard.py](pboard.py)); paired ratios by round, median [quartiles] and
rounds won ([gstats.py](gstats.py), [pstats.py](pstats.py)); every sum
checked (psum 16760439056, qsort 4194304). Raw samples in [raw/](raw/).
The Mac carried other sessions' work (load 3 to 6).

## The answer in short

- **Nothing in qsort's own work trails Rayon.** One thread, alone: the
  leaf sort level with `sort_unstable` (1.007), the partition into fresh
  Lists 22% faster, a List made and filled 5.4 times faster, a growing
  `extend` 27% faster. fork.rig with no task (seq.rig) runs qsort in
  138-142 ms against Rayon's 151-156 at one thread: 8% faster.
- **At 1 worker the whole gap is the monitor.** With #1168 (head
  3084f159b) fork.rig's qsort is 8% faster than Rayon at every placement
  tried (0.917-0.934, 23 or 24 of 24 rounds), and equal to seq.rig.
- **At 10 workers Rig is level.** With #1168, 0.976-0.994 of Rayon (12-14
  of 24 rounds); main at three placements, 1.01-1.04. The critical path
  runs through partitions and the `extend`s at the top levels, where Rig
  loses about 4.4 ms to its realloc and its first touch of fresh memory,
  and wins it back in the deeper subtrees (table below).
- **main's fork.rig binary is a layout outlier.** The same qsort code at
  eight placements (only `main`'s size changed): seven run alike, and the
  placement main's fork.rig gets runs 15% slower at 1 worker (193.7
  against 164.9-170.6 ms) and 6-10% slower at 10. With the monitor held
  off it is still 18% slower, so it is placement, not preemption. It is
  most of what the 2026-11-19 board reads as qsort's regression after
  #1158, and most of fork.rig's 1.27 at 1 worker.
- **A fork's start waits on the monitor, about 0.6-0.9 ms, but that is not
  on qsort's critical path.** Waking a sleeping worker as the fork is made
  cuts the wait to 0.01-0.02 ms and changes qsort by nothing measurable
  (same binary, wake on against off: 1.015 [0.966-1.082] at 10 workers).
  Not built.

Nothing was built: no change measured clean. What belongs to other
builders is at the end.

## Where the time goes at 10 workers

[phases.rig](phases.rig) is fork.rig's qsort with the steps of its top
three levels stamped, and [rust-phases/](rust-phases/src/main.rs) its Rayon
twin (both free each input once partitioned, and neither runs psum
first). Node `d/p` is depth `d`, path `p` (`2p` the low half the maker
runs, `2p+1` the high half offered to other workers). The pivot is the
middle element, so the halves are uneven: the top splits 420,803 low
against 3,773,500 high. Board b1, 30 rounds, medians in ms:

| node | length | Rig late | Rust late | Rig part | Rust part | Rig own | Rust own | Rig ext | Rust ext |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 0/0 | 4,194,304 | | | 5.68 | 4.50 | 4.05 | 5.73 | 3.24 | 2.59 |
| 1/1 | 3,773,500 | 0.55 | 0.11 | 6.61 | 6.07 | 28.12 | 36.78 | 3.86 | 1.28 |
| 2/2 | 1,593,843 | | | 1.63 | 2.07 | 24.53 | 34.51 | 1.32 | 0.10 |
| 2/3 | 2,179,656 | 0.90 | 0.01 | 5.41 | 4.01 | 2.86 | 31.44 | 1.51 | 1.62 |

`late` is the time from the maker's fork to the half's start, `part` the
partition, `own` the maker's own half, `ext` its two `extend`s. Whole qsort:
Rig 51.7, Rust 52.2 (0.982 [0.941-1.026]).

Both critical paths run 0/0, 1/1, 1/1's own half (2/2's subtree), then the
two `extend`s back up. On it, against Rust:

| step on the critical path | Rig − Rust, ms | share of 51.7 | why |
|---|---:|---:|---|
| 1/1's `extend`s (out of 1.59 M grown to 3.77 M) | +2.58 | 5.0% | realloc copies the 12.7 MB and faults in a fresh 30 MB block; Rust's grows in place |
| top partition (two fresh 16 MB Lists) | +1.18 | 2.3% | first touch of fresh memory; warm, Rig's partition is 22% faster |
| 0/0's `extend`s (420 K grown to 4.19 M) | +0.65 | 1.3% | as above |
| 1/1's partition | +0.54 | 1.0% | |
| the fork 1/1 starting late | +0.44 | 0.9% | the monitor's look (below), not on the path in net |
| 1/1's wait for 2/3 | +1.92 | 3.7% | 2/3 started 0.9 ms late |
| 1/1's own half, the 2/2 subtree | −8.66 | −16.8% | Rig's per-thread heaps reuse memory; Rust's subtree likely pays libc malloc's fresh mappings and their faults on many threads |
| in all | −1.35 | | level (whole qsort: 51.7 against 52.2) |

At 1 worker the leaf sorts take 27.6 ms of qsort's (Rig and Rust alike,
claimed micro run, [micro.rig](micro.rig), [rust-micro/](rust-micro/src/main.rs),
[raw/micro.txt](raw/micro.txt), 42 runs each):

| piece, one thread | Rig ms | Rust ms | Rig / Rust |
|---|---:|---:|---:|
| partition 2^22 into three fresh Lists | 3.59 | 4.63 | 0.777 |
| partition into Lists made beforehand (passed as `!List`) | 3.15 | 2.10 | 1.505 |
| `extend` a full List of 2^21 by 2^21 (grows) | 0.77 | 1.06 | 0.727 |
| `extend` into room already there | 0.31 | 0.34 | 0.923 |
| `List(capacity: 2^21)` filled by pushes | 0.53 | 2.87 | 0.184 |
| 512 leaves of 8,192: copy and sort | 27.59 | 27.39 | 1.007 |
| 512 leaves: copy alone | 0.57 | 0.60 | 0.951 |

The one slower row, the partition into Lists passed by `!` view, is not
fork.rig's form (its Lists are locals, whose pointer and length stay in
registers); a loop of pushes through a view reloads them.

## The layout outlier

[shift/s1.rig](shift/s1.rig) is fork.rig with `k` never-taken prints at
the end of `main`, which only grow `main` and so move qsort and the sort
functions after it (`main` is placed first in the program's section);
qsort's instructions are identical in all eight (same sequence, 358
instructions). Board b5, 20 rounds; s0 is fork.rig as it is:

| | qsort at | 1 worker ms | / s0 | 10 workers ms | / s0 |
|---|---|---:|---|---:|---|
| s0 (fork.rig) | 0x10005bf10 | 193.7 | | 65.6 | |
| s1 | 0x10005c044 | 168.9 | 0.860 [0.845-0.886] | 60.4 | 0.904 [0.851-0.981] |
| s2 | 0x10005c0c4 | 167.8 | 0.852 | 61.5 | 0.944 |
| s3 | 0x10005c198 | 164.9 | 0.848 | 62.9 | 0.930 |
| s4 | 0x10005c280 | 168.9 | 0.858 | 61.5 | 0.947 |
| s5 | 0x10005c35c | 170.1 | 0.864 | 62.0 | 0.907 |
| s6 | 0x10005c440 | 170.2 | 0.872 | 61.0 | 0.900 |
| s7 | 0x10005c520 | 170.6 | 0.864 | 61.5 | 0.918 |
| Rayon | | 152.6 | 0.788 | 59.9 | 0.914 |

With the monitor held off (`RIG_PREEMPT_WAIT_US=1000000
RIG_PREEMPT_SLICE_US=1000000`, board b7, 16 rounds) s0 takes 166.0 ms at 1
worker and s1-s3 139.6-141.8: s0 still 18% slower, so it is the placement
and not the monitor's stops. (And with no monitor, Rig's qsort at 1
worker is 7.5% faster than Rayon's 151.7.)

In s0 the partition loop's hot path runs from 0x10005bff4 to 0x10005c010,
across the 16 KiB boundary at 0x10005c000. The other placements put it
clear of one. A synthetic loop of the same shape placed across a 16 KiB
or a 4 KiB boundary ran 2-10% slower than one at a 16 KiB boundary's
start ([shift/straddle-gen.py](shift/straddle-gen.py),
[raw/straddle.txt](raw/straddle.txt)), less than s0 loses, so the boundary
is a suspect, not the proven cause. Earlier arms that moved qsort agree:
`drop.rig` (qsort at the same address, loop at the same place) 183.8 ms;
#1158's parent, an arm with one line added to `spawnIn`, and `nopsum.rig`
(all other placements) 161.7-170.

So fork.rig's board row moves 6-18% with where the linker puts qsort, and
any change to the runtime or `main` can move it. The 2026-11-19 board's
fork.rig/rayon of 1.27 at 1 worker and 1.07-1.08 at 10 (boards b2-b4)
are mostly that: #1158's parent (4c218d366) reads 1.08 and 0.99 there,
and three other placements of main 1.08-1.14 and 1.01-1.04 (board b6).

## With #1168

#1168's head (3084f159b, which predates #1158) built with four placements
of the same source (m0-m3), main at three (s1-s3), seq.rig, and Rayon,
board b6, 24 rounds, ratios to Rayon:

| | 1 worker | 10 workers |
|---|---|---|
| #1168, m0-m3 | 0.917-0.934 (23-24 of 24) | 0.976-0.994 (12-14 of 24) |
| main, s1-s3 | 1.083-1.138 | 1.010-1.044 |
| seq.rig (no task) | 0.922 | 2.430 |

So #1168 takes qsort at 1 worker from 8-14% slower than Rayon to 8%
faster, to seq.rig's time; at 10 workers it reads level to 2% faster,
inside the quartiles.

## The fork's late start, and the wake not built

A fork goes into its maker's "run next" slot and wakes no one
(`sched.wakeIn`). In a build preempted by signal there is no yield check
to hand it on, so it waits until the monitor sees it at two looks: the
first look comes within the busy period (1 ms), the second 50 µs later.
phases.rig shows it: each offered half starts 0.35-0.9 ms after its fork
at 10 workers, against Rayon's 0.01-0.11.

The arm: `spawnIn` calls `notify()` after queuing the fork, in a preempted
build, when the maker runs a fiber (as Go's `newproc` calls `wakep`).
A sleeping worker takes the fork through `stealNext`, 0.01-0.02 ms after
it is made. Same binary, the wake switched by an environment variable,
board b4, 30 rounds:

| | 1 worker | 10 workers |
|---|---|---|
| fork.rig, wake / no wake | 1.014 [0.986-1.076] | 1.015 [0.966-1.082] |
| phases.rig, wake / no wake | 1.001 [0.988-1.022] | 0.983 [0.945-1.053] |

Nothing: the late halves are not on the critical path (the maker's own
half, 2/2, is), and 1/1's partition starting 0.6 ms earlier only makes it
wait longer for 2/3. A first build of the same arm without the switch
read 10% faster at 10 workers; the switched board shows that was its
placement. The wake would also cost `bench/tasks`' chain (a task made and
waited for at once) a wake per task while workers sleep, so it is not
worth building for qsort.

## What belongs to other builders

1. **Layout (compiler, emit and link: `keepCodeApart`).** A hot loop's
   placement moves fork.rig's qsort 15-18% at 1 worker and 6-10% at 10;
   boards that compare runtimes on one binary each can read a placement
   as a regression. Suggested: boards build each Rig arm at two or three
   placements (as shift/ does) and report the median; and a design look
   at aligning the program section's functions and hot loops (Zig 0.17
   passes no `-align-loops` to LLVM).
2. **alloc.zig, the memory expert (Rig session).** A List that grows
   past 16 MiB on macOS is copied into a fresh mapping (no `mremap`
   there); libmalloc's large realloc grows in place. On qsort's critical
   path at 10 workers that is about 3.2 ms of 51.7 (6%), and the first
   touch of the top partition's two fresh 16 MB Lists about 1.2 ms (2%).
   A pup job could tell whether `mremap` already closes it on Linux.
3. **The monitor (#1168).** It settles qsort at 1 worker; nothing more is
   needed for qsort.

## Files

- [phases.rig](phases.rig), [rust-phases/](rust-phases/src/main.rs): the stamped twins.
- [micro.rig](micro.rig), [rust-micro/](rust-micro/src/main.rs), [microrun.sh](microrun.sh): the pieces alone.
- [seq.rig](seq.rig), [nopsum.rig](nopsum.rig), [drop.rig](drop.rig), [rust-nopsum.rs](rust-nopsum.rs), [rust-drop.rs](rust-drop.rs): fork.rig with no task, with no psum first, and freeing each input once partitioned; Rust's twins of the last two.
- [shift/](shift/): the placement variant (`k` = 1 shown) and the synthetic loop.
- [raw/](raw/): b1 (phases), b2 (variants, #1158's parent, first wake arm), b3 (wake arm, slowed monitor), b4 (wake switched in one binary), b5 (placements), b6 (#1168), b7 (placements, monitor held off), micro.txt, straddle.txt; each `.log` holds the machine's load at start and end.
