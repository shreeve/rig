# Free fork-join, the inline run: the Mac board (2026-11-19)

The third build commit of [runtime.md](runtime.md) §6: a fork its waiter
reaches unstarted runs on the waiter's stack and fiber (`sched.runHere`),
on #1171's frame records and #1168's narrowed monitor. Arms, each a
`rig build --release` of the same source:

- `main`: origin/main 9bffe8747; `rec`: #1171's head f8fd3bcf3;
- `new`: this branch's first build; `n2`: with an inline run taken back
  from the ring counted as a fiber started, as a handoff's is (45adf14ab);
- `aa`: a copy of `new` (b1) or `n2` (b4), run as its own arm;
- `rayon`, `rayon3`: fork-order's and the ceiling round's Rayon twins.

fork-order's fork.rig (one psum and one qsort a process, cold) at three
code placements each (`0`, and `1`, `2` with 3 and 6 never-taken prints at
the end of `main`, as qsort-mac/shift did); fork3.rig (three passes each,
`nil` the psum tree with no work, 4,095 joins). The Mac was shared with
other sessions (load 5-11), under `tools/mac-claim`; ratios are paired
medians per round with the interquartile range ([stats.py](inline/stats.py)).

## `new` (b1, 20 and 10 rounds)

| row | main | rec | new | Rayon |
|---|---:|---:|---:|---:|
| nil, 1 worker, ns a join | 67 | 57 | 29 | 10 |
| psum, 1 worker, ms | 7.78-8.13 | 7.22-7.53 | 6.76-6.91 | 7.00 |
| qsort, 1 worker, ms | 171.4-176.0 | 142.2-143.9 | 149.5-153.8 | 153.9 |
| psum, 10 workers, ms | 2.60-2.82 | 2.59-2.67 | 2.53-2.79 | 2.71 |
| qsort, 10 workers, ms | 58.6-59.8 | 57.4-59.0 | 58.5-59.4 | 59.0 |
| peak, qsort's process, 1 worker | 774-793 MiB | 502 | 599-604 | 583 |

qsort at one worker was 5% slower than #1171, with 100 MiB more at its
peak. An inline chain did not move the monitor's count of fibers started
(`runs`), where #1171's handoffs from the ring did, so its fiber was
stopped every slice (10 ms) with its forks waiting, and the worker ran
them breadth first. `n2` counts an inline run taken back from the ring as
a handoff counts it.

## `n2` (b4, 16 rounds; b5, 10)

| row | main | rec | n2 | Rayon |
|---|---:|---:|---:|---:|
| nil, 1 worker, ns a join | 69 | 61-65 | 31-32 | 10 |
| nil, 10 workers, µs a tree | 131-141 | 93-113 | 71-72 | 58-60 |
| psum, 1 worker, ms | 8.51 | 7.70-8.08 | 6.90-7.37 (0.84-0.91 of Rayon) | 8.23 |
| qsort, 1 worker, ms | 185.2 | 145.0-150.1 | 143.9-145.4 (0.91-0.93) | 155.8 |
| psum, 10 workers, ms | 2.75 | 2.67-2.93 | 2.58-2.71 (0.94-0.98) | 2.82 |
| qsort, 10 workers, ms | 61.8 | 59.7-61.1 | 60.0-61.6 (0.96-0.99) | 62.0 |
| peak, qsort's process, 1 / 10 workers | 787 / 700 MiB | 502 / 673 | 502 / 675 | 582 / 789 |

The A/A arm read 1.035 of Rayon on psum at one worker against `n20`'s
0.843 from the same binary, so a single psum cell moves 10-20% here from
round to round on this machine; qsort's cells and `nil` hold within 4%.
Raw samples: [inline/](inline/) (b1, b2, b4, b5, as `board.py` wrote
them).

## bench/tasks, actors, net (b6, 12 rounds; b3, 7)

bench/tasks against main, paired medians (`rec` beside it): chain 0.46
(0.259 ms against 0.557; #1171 0.87), the one row a waiter takes its task
back unstarted every time; spawn 0.90, yield 0.96, produce 1.00, fanout
1.03 (#1171 1.02), hog level. bench/actors (contend 12.3 ms against
11.9, solo 5.22 against 5.17, spread 1.04 against 1.11) and bench/net
(connect 25.8 against 26.0, echo 530 against 526, pingpong 328 against
346) level within this machine's spread, over 7 rounds against main.
Peak memory level: tasks 11.5 MiB, actors 4.0, net 7.1-7.2.
