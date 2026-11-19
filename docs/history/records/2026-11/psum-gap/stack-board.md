# psum stack board: #1156 (hp) and #1158 (early) on pup (2026-11-18)

Scripts, logs and raw samples: /Users/shreeve/Data/Code/Claude/rig/rig/psum-gap/stack/ (raw/ holds every
board's output and samples; the pup copy is /zfs/trig-pup/psum-gap/stack/).

## Arms (private branches on GitHub, built with tools/pup-rig)

| arm | SHA | what |
|---|---|---|
| main | ee994781b | origin/main |
| hp | ea7217f22 (`psum-stack-hp`) | main + #1156 (seg-first-small 725a89e00) |
| early | 0498f93e7 (`psum-stack-early`) | main + #1158 (early-start 1484329cf). Its tree is identical to the refreshed PR head 664b926a2 (`git diff` is empty), so I kept it. |
| both | 644e8e694 (`psum-stack-both`) | hp + #1158 |
| aa | copy of main's binaries | A/A |

Only CHANGELOG conflicted; both entries kept. Worktree: ~/Data/Code/worktrees/rig/psum-stack.

## Gates

| | Debug | ReleaseSafe | ReleaseFast | Trig light |
|---|---|---|---|---|
| hp ea7217f22 | FAIL | FAIL | FAIL | GREEN (162 s, 119/119) |
| early 0498f93e7 | pass | pass | pass | GREEN (164 s, 119/119) |
| both 644e8e694 | FAIL | FAIL | FAIL | not run (not asked) |
| PR head 725a89e00 alone | FAIL | | | |

The same test fails in all three modes, and on #1156's own head:
`alloc.test.on Linux a new segment is aligned for huge pages and asks for them while 2 MiB blocks are free, of a
heap that faults in ahead or not`, at `try std.testing.expect(!faultsAhead(&later))` (src/alloc.zig:3763). It fails
every time, and the test is wrong, not the allocator: the test sets `later.taken = segment_size` (4 MiB). Then
`newPage` calls `took(segment_size)`, so `later.taken` becomes 8 MiB = `prefault_big`, and
`faultsAhead` (`h.taken >= prefault_big or leads(h)`) is true. The test skips off Linux, so the Mac never runs it.
#1156's author needs to fix the test, for example by setting `later.taken` below `prefault_big - segment_size`.

## Fork board (fork-order's fork.rig, the right half forked; Rayon twin LTO), medians in ms (range)

20 rounds (slot 591), confirmed at 60 rounds (slot 593). The checks agree (psum 16760439056, qsort 4194304).
Table: the 60-round board; the 20-round board is in parentheses where it differs by more than 1%.

| config | row | main | aa | hp | early | both | Rayon |
|---|---|---|---|---|---|---|---|
| 1 worker | psum | 11.89 | 11.91 | 12.12 | 11.88 | 12.02 | 11.90 |
| 1 worker | qsort | 274.9 | 275.0 | 277.5 | 271.5 | 272.9 | 266.2 |
| 12 workers | psum | 5.78 | 5.80 | 4.62 (4.71) | 5.46 (5.39) | 4.18 | 4.69 (4.59) |
| 12 workers | qsort | 97.9 | 96.4 | 97.7 | 96.9 | 98.5 | 123.0 |

Against main (60 rounds; 20 rounds in parentheses) and Rayon:

- psum, 12 workers: hp 20% less time (19%); early 6% less (7%); both 28% less (28%). Against Rayon: main 23%
  slower, hp level (1% faster; 2.6% slower at 20 rounds), early 16% slower, both 11% faster (10%).
- psum, 1 worker: main is level with Rayon (0.1%). hp 1.9% slower than main (1.3%), and both 1.1% slower (0.9%),
  against an A/A of 0.1% (0.2%). early is level.
- qsort: within the A/A at both counts (the A/A at 12 workers is 1.6%, and 5.4% at 20 rounds). Rig is 20% ahead of Rayon at 12
  workers and 3% behind at 1.

## bench/tasks, actors, net on 0-11 (5 rounds, fastest of 9 a round; net 9), tasks again at 15 rounds

The checks agree. Ratio to main (A/A in the first column):

| row | aa | hp | early | both |
|---|---|---|---|---|
| tasks spawn (5 / 15 rounds) | 0.984 / 0.986 | 1.023 / 1.009 | 1.008 / 0.996 | 1.056 / 1.024 |
| tasks chain | 1.002 / 0.993 | 1.005 / 1.001 | 1.004 / 0.993 | 0.994 / 1.004 |
| tasks fanout | 0.999 / 0.999 | 0.998 / 0.998 | 0.998 / 0.999 | 0.998 / 0.999 |
| tasks yield | 0.995 / 0.979 | 0.932 / 0.969 | 1.036 / 1.021 | 0.993 / 0.999 |
| tasks hog (~13 µs) | 0.989 / 1.034 | 1.104 / 1.074 | 0.979 / 1.034 | 1.031 / 1.096 |
| tasks produce | 1.000 / 0.999 | 1.000 / 1.001 | 0.996 / 1.000 | 1.002 / 0.999 |
| actors solo | 0.965 | 1.012 | 0.980 | 0.989 |
| actors contend | 0.994 | 0.925 | 0.994 | 0.922 |
| actors spread | 1.004 | 0.962 | 1.022 | 0.958 |
| net pingpong | 1.008 | 1.000 | 1.014 | 0.992 |
| net echo | 1.008 | 0.988 | 1.009 | 1.003 |
| net connect | 1.006 | 1.012 | 1.022 | 1.013 |

Full medians and ranges: raw/bench-board.txt and raw/tasks15-board.txt.

bench/http closed loop on 0-11, 7 rounds (median req/s, range): main 716,987 (608k-856k), aa 758,772 (1.058),
hp 776,225 (1.083), early 701,478 (0.978), both 737,757 (1.029). The A/A spread is 5.8%, so every arm is level.
p99 is 237-250 µs for all.

## Peak RSS (/usr/bin/time -v, median of 5, MB)

| program | main | aa | hp | early | both | Rayon |
|---|---|---|---|---|---|---|
| fork.rig, 1 worker | 823 | 811 | 846 | 853 | 846 | 488 |
| fork.rig, 12 workers | 843 | 894 | 851 | 916 | 839 | 764 |
| bench/tasks, 0-11 | 14.7 | 12.5 | 3.3 | 14.6 | 4.1 | |

fork.rig's RSS runs from 757 to 968 MB within one arm, so its arms are level. Rig holds more than Rayon at 1
worker, 823 against 488 MB, on main as on every arm. bench/tasks: hp and both hold 72-78% less.

## Rows slower than main beyond the A/A

1. psum at 1 worker: hp 1.9% slower, both 1.1% (A/A 0.1%). Seen at 20 and 60 rounds; the author reported 1.5-1.7%.
2. tasks hog: hp 7-10% slower, both 3-10% (A/A 1-3%). A ~13 µs row whose ranges overlap. Slower on both boards, so
   it is probably real but small; the author called it unsettled.
3. tasks spawn, both: 5.6% slower at 5 rounds (ranges apart), 2.4% at 15 (A/A 1.4%, ranges overlap). Borderline.
4. early: tasks yield 2-4% slower and net connect 2.2% slower, against an A/A of 1-2%, with ranges that overlap. Borderline.

Slots 591, 592 and 593 were all ab slots; every quiet check was honoured. The Trig timing A/B was left alone.
