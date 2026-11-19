# Early workers' memory (2026-11-19)

Since #1158 (586e3939a), a program that makes tasks and never names `task.workers` starts its workers
as `main` starts. Each worker takes and gives back one record before it looks for work, so the fault
on its heap's first segment comes before the work, not on psum's critical path. On Linux that segment
asked for huge pages, so the fault zeroed a whole 2 MiB page, and every idle worker then held 2 MiB.
On pup at 12 workers that took a program of two tasks from 35.1 MiB to 57.9 MiB, and bench/tasks from
15.6 MiB to 25.1 MiB (psum-gap/eval1158.md).

**Change:** the worker marks its heap before taking that record (`alloc.startSmall`). The heap's first
segment then keeps small pages for its first 2 MiB and asks for huge pages for its second
(`firstHalfSmall`). An idle worker holds the segment's header page and its record's page, not 2 MiB.
A worker that writes past 2 MiB of small blocks reaches huge pages, and its later segments ask for
them whole. Nothing else changes:
- main's heap;
- workers started at the first task, including every program that names `task.workers`, as Trig does;
- RIG_WORKERS=1;
- the Mac.

## Method

pup (Core Ultra 9 185H), Rig main 586e3939a (`cur`), the branch 8232a7573 (`new`), a byte copy of
`cur` (`aa`), and main before #1158 (2dc9a46f5, eval1158's arms, `pre`).
- Programs: fork-order's fork.rig, eval1158's fewtask.rig (two tasks of about a second each), and
  bench/tasks.
- Builds: `rig build --release` on E-cores 12-19 with no slot open (`data/b6.sh`).
- Timing: on P-cores, in slot 620 (quiet honoured) and slot 621. During slot 621 another session's unit
  tests ran on E-cores 12-19, so its quiet check was not honoured.
- Scripts: `data/m7.sh` and `data/m8.sh`.
- Every run's checks agreed.

## Results

**Peak RSS** (KiB, median of 5 interleaved runs, `/usr/bin/time -v`, RIG_WORKERS=12 on 0-11, slot 620):

| program | pre (before #1158) | cur (main) | new |
|---|---|---|---|
| fewtask (2 tasks) | 35,076 | 57,868 | 35,128 |
| bench/tasks, timed rows | 15,648 | 25,056 | 5,460 |
| bench/tasks `many` (10,000 tasks asleep) | 47,764 | 70,312 | 48,116 |
| bench/tasks `idle` | 2,316 | 25,124 | 2,364 |
| fork.rig | 900,712 | 968,148 | 940,368 (ranges overlap: 844-1,002 MB in every arm) |

Slot 621 repeats it: fewtask 57,872 against 35,128, bench/tasks 25,116 against 4,808, `many` 70,576
against 47,944, `idle` 25,120 against 2,368. bench-tasks' `memory` row is 4.6 KiB a task in every arm.

**Fork board** (`s1118-order-board.py`, ms, median, range):

| row | cur | new | aa | pre | Rayon |
|---|---|---|---|---|---|
| psum, 12 workers (620, 30 rounds) | 3.95 (3.48-4.75) | 3.91 (3.50-5.20) | 3.99 | 5.80 | 4.69 |
| psum, 12 workers (621, 20 rounds) | 4.19 (3.59-5.41) | 3.93 (3.62-5.36) | 3.77 | | 4.62 |
| qsort, 12 workers (620) | 96.4 | 97.3 | 97.8 | 96.7 | 124.3 |
| psum, 1 worker (620) | 11.91 | 11.86 | 11.89 | 11.93 | 11.96 |
| qsort, 1 worker (620) | 273.5 | 276.7 | 274.1 | 274.7 | 267.6 |

At one worker no worker starts early, so `new` runs the same code as `cur`. Its qsort row, 1.2% slower,
shows the noise of that row. psum at 12 workers stays 16-17% faster than Rayon.

**bench/tasks**, by its own driver (`--time-only --reps 9`, the fastest of 9 a round, median of 8
rounds, 12 workers on 0-11, slot 621), new against cur (A/A in brackets):

| row | spawn | chain | fanout | yield | hog | produce | memory |
|---|---|---|---|---|---|---|---|
| new/cur | 0.900 (1.007) | 1.000 (1.000) | 1.001 (1.002) | 0.857 (1.000) | 1.027 (0.987) | 1.009 (1.017) | 1.000 (1.000) |

hog's ranges overlap: new 290-366 ns a step, cur 271-345. Slot 620 ran single runs, not the driver's
fastest of 9: hog new/cur 1.156, aa/cur 0.932, at about 18 us a run. Each worker's heap writes its
first small blocks to 4 KiB pages rather than a huge page faulted whole, and hog's step is a few
microseconds of such work.

**Probe D** (`259788286`, not kept): a worker started small faulted in each 64 KiB class page of its
first segment in one call, rather than 4 KiB at a time. hog read 0.970 of cur and spawn 0.918, but
bench/tasks' peak rose to 10.5 MiB from 4.8 and fewtask's to 35.5 MiB. That is no clear gain for the
memory, so it was dropped.

## fork.rig's peak against Rayon's

fork.rig's peak RSS is 1.3x Rayon's on the Mac (804 against 621 MB at one worker) and 1.8x on pup
(about 900 against 500). The extra is live memory, not memory the allocator keeps.
- **Heap profile:** at one worker, `RIG_HEAP_PROFILE=1` measures 774-859 MiB live at the peak, against
  the 256 MiB input and roughly 130 MiB qsort needs when the tasks run depth first.
- **Sites:** `RIG_HEAP_PROFILE=sites` finds about 840 Lists made by about 420 qsort tasks, all in
  progress at once (255 MiB), with 366 more one level down (85 MiB).
- **Likely cause:** every 1,024 turns, the partition loop's yield check (`sched.tick`) yields while
  the worker's own ring holds work and no idle worker will take it. At one worker, that work is
  qsort's own forked halves, so each partition yields to its child, which starts its own partition
  and allocates its two Lists. The fork-join then runs breadth-first. Rayon has no yield checks and
  stays depth first.
- **Status:** this is the scheduler's fairness rule, a documented behavior ("a long loop never keeps
  that work waiting"), so it is left as a finding for the scheduler and the owner, not changed here.
