# Why Trig scales worse than tsrs on every core (2026-10-24)

The owner's question: why is Trig not faster on every core, and is Rig
overwhelming the cores (more threads than cores, a growing blocking pool,
workers spinning, E-cores)? The fact to explain, from Trig's
docs/RESULTS.md ("the bench against tsrs at its fastest", pup, ts-pattern,
check mode): Trig with one checker 1.164 s against tsrs's 0.661 s on one
thread (1.76×); on every core 0.496 s against 0.223 s (2.22×). Trig gains
2.35× from one to all cores, tsrs 2.96×.

Measurement and diagnosis only; no code changed.

## Setup

- pup (Core Ultra 9 185H), Trig's bench-fair release build (the same tree
  as the RESULTS row: plain release, with debug info, copied read-only to
  `/zfs/worktrees/rig/perf-scaling/`), and the shipped tsrs
  (`/zfs/trig-pup/tsrs-shipped/package/tsrs`, 0.18.0).
- Cores 3 and 4 never used. "All cores" here is `taskset -c 0-2,5-11`
  (10 logical CPUs, five P-cores with their siblings), not the bench's
  0-11. One thread: `taskset -c 6` (sibling 7 idle).
- `--checkers 4` is Trig's default (tsc's); tsrs's default mode also
  checks ts-pattern with four checker threads (`checker-0` to `-3`), plus
  a rayon pool of one thread per CPU for parsing.
- Tools: `perf stat`, `perf record -g` (frame pointers), `perf sched
  record` turned into per-thread run intervals, `RIG_SCHED_STATS=1`,
  `strace -c -f`, `perf c2c`. From about 18:05 pup ran a queue of release
  builds (slot pairs 1,2 / 10,11 / 0,5) and Trig's A/B builds and timings;
  measurements from then on were taken on cores no build used (E-cores
  12-19, or 6-9 for counts), where only ratios are compared.

## 1. Is Rig oversubscribing the cores? No.

| | Trig, 4 checkers, 10 CPUs | tsrs default, 10 CPUs |
|---|---|---|
| threads made | 11: 10 workers (one per CPU in the affinity mask), 1 blocking-pool thread | 24: rayon pool of 10, 4 checkers, helpers |
| threads that ever run work | 4 (5 when a checker fiber moves once) | 10 while parsing (26 ms), then 4 |
| idle workers | each wakes once, sleeps once, never again (`RIG_SCHED_STATS`: `slept 1`) | rayon threads spin then yield: 1,669 `sched_yield` |
| context switches, run | 848 (715 at one checker) | 1,597 |
| CPU migrations, run | 10 | 45 |
| E-cores or LP cores | none when pinned (see 1b) | none when pinned |
| scheduler symbols in the profile | 0.03% of samples | n/a |
| allocator symbols | 3.35% at 4 checkers, 3.19% at one: no contention | n/a |
| false sharing (`perf c2c`) | 2 local HITM in 4,965 records, both in the kernel | n/a |

At one checker Trig's task-clock is 1,220 ms; at four on 10 CPUs it is
1,344 ms (+10%): 5.7% more instructions (each checker builds the global
and library types again; tsrs pays the same, +6.3% at four), and a lower
clock with four cores busy (cycles +4.8%, cycles per instruction
unchanged). tsrs: task-clock +10%, cycles +5%, the same. Rig's runtime, in all: under 2% of the all-core wall
time (sections 3 and 4).

**1b. Placement.** Unpinned, Rig makes one worker per CPU in the mask: 22
on pup. 18 of them sleep at once and stay asleep; four run the checkers.
Linux places those four, not Rig. With cores 6-9 and 12-19 allowed (two
idle P-cores with their siblings, and eight E-cores; the other P-cores
were building), three runs each: Trig put two checkers on P-cores 6 and
8 and two on E-cores, never on a sibling (wall 632-660 ms); tsrs the
same (312-340 ms). So E-cores are used only when there are fewer idle
P-cores than checkers, by both. A quiet run with every P-core but 3 and 4
allowed was not possible: pup ran release builds and Trig's A/B queue
from 18:05 on.

## 2. The all-core timeline

Per-thread busy share per 25 ms of one all-core run (P-cores, load 0.95,
`perf sched`); each row a thread:

```
ms           0   25   50   75  ...  225  250  275  300  325  350  375 ... 475  500
main        90   94   98   99  ...  100   99  100  100  100   99  100 ... 100   61   head, checker, tail
worker a     0    0   83   99  ...  100  100   99  100  100   89    0 ...   0    0   checker ends 372
worker b     0    0   83   99  ...  100  100   99  100   54    0    0 ...   0    0   checker ends 339
worker c     0    0   83   99  ...   93    0    0    0    0    0    0 ...   0    0   checker ends 251
```

Time with k threads running (ms): 1 thread 196, 2 threads 34, 3 threads
28, 4 threads 256. Average concurrency 2.66 of a possible 4.

The phases, from the call stacks of every sample:

| Phase | ms | What runs |
|---|---|---|
| head, serial | 54 | exec, config, `FileLoader.load`: parse 24 ms, bind 5, file I/O through the blocking pool, `new_checker` x4 2.7 ms |
| check, 4 tasks | 54 to ~490 | checkers end at 251, 339, 372 and ~490 ms: durations 197, 285, 318, 436 ms (mean 309; the longest 1.41× the mean) |
| tail, serial | ~26 | dropping the program and the checkers (`rig.alloc.free` under `dropFields` in `emit_files_and_report_errors`) 15-20 ms; sorting and printing the diagnostics ~9 ms |

The same shape on the E-cores (12-19): Trig's checkers take 336, 503, 578
and ~760 ms (longest 1.40× the mean).

## 3. tsrs, the same way

| | wall | task-clock | instructions | page faults | max RSS |
|---|---|---|---|---|---|
| Trig, 1 checker | 1.228 s | 1,220 ms | 13.21G | 80,924 | 333 MB |
| Trig, 4 checkers | 0.504 s | 1,344 ms | 13.97G | 93,823 | 384 MB |
| tsrs, 1 thread, Go order | 0.674 s | 669 ms | 7.35G | 17,805 | |
| tsrs, default, all | 0.210 s | 738 ms | 7.46G | 19,008 | 190 MB |

Cycles in the kernel (cores 6-9): Trig 7.5% at one checker, 7.0% at four;
tsrs 6.5%, then 4.3%. Trig's faults are almost all first touches of fresh
pages (memcpy into a grown List's new block, `rig.table` pushes, map
growth): its footprint is twice tsrs's.

Per-checker work on the E-cores (12-19), four checkers:

| | checker durations (ms) | longest / mean | head | total |
|---|---|---|---|---|
| Trig (Go's partition) | 336, 503, 578, ~760 | 1.40 | 73 ms | 851 ms |
| tsrs, Go's order | 257, 283, 384, 407 | 1.22 | 29 ms | 443 ms |
| tsrs, default (its assignment, stealing) | 258, 259, 265, 278 | 1.05 | 30 ms | 367 ms |

tsrs's head is parallel: its rayon pool parses the 169 files on every
thread in about 26 ms (12 ms of parse on one thread), and its bind is
included; Trig's head is one thread, 54 ms on a P-core (parse 32 ms and
bind 11 ms by `--extendedDiagnostics` at one checker).

By checker count (all cores, fastest of 5, s):

| checkers | 1 | 2 | 3 | 4 | 5 | 6 | 8 | 10 |
|---|---|---|---|---|---|---|---|---|
| Trig | 1.15 | 0.76 | 0.86 | 0.47 | 0.56 | 0.48 | 0.47 | 0.45 |
| tsrs, Go's order | 0.63 | 0.40 | 0.46 | 0.23 | 0.20 | 0.22 | 0.21 | 0.17 |
| tsrs, default | 0.62 | 0.34 | 0.24 | 0.20 | 0.18 | 0.16 | 0.17 | 0.19 |

More checkers do not help Trig past four: the longest checker's files
stay together (Go's partition keeps related files on one checker), so its
time barely falls (check 418 ms at 4, 371 at 10).

## 4. What the scaling gap is made of, ranked

Trig's all-core wall (P-cores) is about 516 ms traced: 54 serial, 436
of checking, 26 serial. With its checkers perfectly balanced it would be
about 390 (54 + 309 + 26). Ranked by the wall time each costs:

1. **Unbalanced checkers: ~110-125 ms (21-25% of the all-core time).**
   The longest of Trig's four checkers is 1.41× the mean (436 ms against
   309); for about 120 ms of the check one thread runs alone. tsrs in Go's order is 1.22×,
   and its default mode, with its own assignment and stealing, 1.05×.
   Two parts: Go's static partition (tsrs in Go's order has it too), and
   a skew of Trig's own: on the E-cores, checker durations sorted by
   length, Trig's heaviest is 1.87× tsrs's and the others 1.31-1.78×
   (1.64× in all), so the heaviest group's files are among Trig's
   slowest; that checker
   spends 66-98% of its last 150 ms under `choose_overload`. Not Rig: the
   tasks run where they are put, and Rig's stealing works (the one fiber
   that moved did).
2. **The serial head: ~25 ms of its 54 (5%).** Parse and bind run on one
   thread before any checker starts; tsrs's parallel head is 29 ms. Of
   Trig's 54 ms, file I/O goes through the blocking pool: worker 0 sleeps
   and is woken 317 times (`RIG_SCHED_STATS`), about 4 ms of waiting.
3. **The serial tail: ~20 ms (4%).** Freeing the program and four
   checkers' heaps at the end (15-20 ms; 12 ms at one checker), memory
   the process is about to give back by exiting.
4. **Per-core cost in parallel: at most 3%, under 15 ms.** Cycles per
   instruction do not change from one checker to four (the lower
   all-core clock hits tsrs alike). Within it: LLC load misses rise 49%
   (tsrs 20%), about 150 MB/s of memory traffic, far below what the memory gives; 13K more page faults,
   since a heap faults ahead only while it is the program's only one
   (`alloc.zig` `prefault`; the allocator-g9 record found prefaulting per
   heap gained nothing); 432 `munmap` calls against 177 at one checker
   (TLB shootdowns to the other checkers' cores).
5. **Rig's scheduler: nothing measurable.** 0.03% of samples; no
   spinning; no growth of the blocking pool (one thread).

Duplicated work (each checker's own global types, +5.7% instructions) is
the same for tsrs and is not part of the gap.

Single-thread speed (1.76×) is the rest of the 2.22× all-core gap: Trig's
13.2G instructions against 7.3G.

## 5. The top fixes, with expected wins

1. **Balance the checking (Trig).** tsrs's default assignment with
   stealing, under its history fixes for exact output (Trig's
   docs/checker/CHECKERS.md, "What tsrs teaches"), or a split of the
   heaviest group: from 1.41× to about 1.05× the mean, about 0.10 s of
   0.496 (about 25% faster on every core), more than the "5 to 10%"
   CHECKERS.md expected from Go mode. And find why the heaviest group's
   files are Trig's slowest (`choose_overload`): that is single-thread
   work that also shortens the critical path. Rig's part is ready: tasks,
   stealing, and `*Frozen` for shared read-only state.
2. **Parse and bind in tasks (Trig, on Rig's tasks).** The head from 54 ms
   to about 25-30 ms: about 5% on every core. Reading the files with
   fewer blocking-pool hops (a batch per call, or a read per file task)
   saves about 4 ms of it (Rig).
3. **Exit without freeing (Rig and Trig).** End the process once the
   output is written instead of dropping the program and the checkers:
   15-20 ms on every core (4%), 12 ms on one thread (1%). Rig could offer
   it as a release-build exit that skips the drops still pending (a
   leak-checked build keeps them).

Single-thread items that also scale: page faults (81K against tsrs's 18K;
`rig.table` maps with `MADV_NOHUGEPAGE`, and List growth maps a fresh
block each time) cost about 4% against tsrs's kernel share; huge pages
for big tables are being tried elsewhere (`/zfs/trig-pup/trial/hp`).
