# Free fork-join: the ceiling (Expert A, 2026-11-18)

Question 3 of the [brief](brief.md): how fast can a fork-join runtime of
Rig's shape run psum and qsort against Rayon, and which of Rig's per-fork
costs does free fork-join remove, each with its share? Measured on the Mac
(Apple M5, 4 performance and 6 efficiency cores, macOS 27.2.1). pup is a
job for the Rig session ([ceil/pup-job.sh](ceil/pup-job.sh), below).

## The answer in short

- **The ceiling runs psum's warm passes 3-4% faster than Rayon at 10
  workers, and level with it at 1** (psum3: 2.048 against 2.160 ms; 3.659
  against 3.805). Rig (main plus the early start) is 2-3% behind the
  ceiling warm at 10 workers and 7-8% behind at 1.
- **Per join, the ceiling pays 3.7 ns, Rayon 9.9, Rig 67.6** (`nil`, the
  tree with no memory, warm, 1 worker). The four costs put back into the
  ceiling explain 23.6 ns of Rig's 64 ns over it: a stack and two switches
  20.5 ns, the seq_cst atomics 8.2, a heap record 0.9, the monitor's count
  0.8 (they overlap: together 23.6). The other 40 ns are Rig's task path
  itself (record setup, run-next slots and ring, the handoff protocol,
  `fiberMain`), which no single arm reproduces.
- **On psum those costs are small.** At 1 worker Rig's 64 ns a join is
  0.26 ms of 3.7 (7%), which is the whole warm gap to the ceiling (3.98
  against 3.66 ms). At 10 workers it is 0.03 ms a worker, about 1%, and
  no arm, nor all four together, moves psum at 10 workers beyond the A/A
  arm's spread.
- **Rig's monitor is the whole of Rig's qsort gap at 1 worker** (16%: with
  its period at 10 ms instead of 50 µs, fork.rig's qsort equals the same
  program with no task) and 4% of its psum at 1 worker. Forks kept out of
  `queuedHere` remove it.
- **What decides the one-pass board is the first pass,** not the fork.
  With the early start, Rig's one-pass psum at 10 workers already beats
  Rayon on the Mac (2.452 against 2.542 ms, paired 0.970 [0.910-1.000]).
  Both pay 0.4 ms in their first pass that the ceiling does not (Rig psum1
  2.573, Rayon 2.575, ceiling 2.173; warm 2.12, 2.16, 2.05), and at 1
  worker 2.5-3.5 ms. That first-pass cost appears in fork.rig with no task
  at all (seq.rig), so it is not fork-join (below, "The first pass").

## The ceiling

[ceil/ceil.zig](ceil/ceil.zig), Zig 0.17, about 700 lines with the arms:

- One worker a core, `main` worker 0; workers start before the input is
  built and each touches its allocators (the heap arm's segment, the stack
  pool's mapping, libc malloc) before it works.
- A Chase-Lev deque per worker (owner pushes and pops the bottom; thieves
  take the top with a compare-and-swap; the owner's pop a seq_cst store of
  `bottom` and seq_cst load of `top`, the C11 form without fences, which
  Zig 0.17 no longer has).
- `join(f, a, b)`: b's record (job header, argument, result) lives in the
  caller's frame; push it, run `f(a)` inline, pop: if the record is still
  there, run `f(b)` inline, reading nothing back from the record; else
  help (steal and run other forks) until the thief's done flag is up.
- Idle workers search (random victim order) for 100 µs, then sleep on a
  futex with a 10 ms timeout. A push wakes one sleeper when none searches
  (one wake in flight); a searcher that finds work and was the last
  searcher wakes the next: a chain, as Rig's and Go's schedulers.
- psum as fork.rig: 2^25 Ints, halves to 8,192, the leaf `rig.fold
  (.add_wrap)` copied from src/runtime.zig (what Rig emits for `s +%= x`;
  no turn count, as fork.rig is built to be preempted). qsort as fork.rig:
  partition into three owned lists (libc malloc), the high half forked,
  leaves of 8,192 sorted by Rig's own integer sort (std/sort.zig at
  origin/main copied as [ceil/rigsort.zig](ceil/rigsort.zig), its runtime
  import pointed at [ceil/sortstub.zig](ceil/sortstub.zig)).
- Built as `rig build --release` builds: `-Osafe -fomit-frame-pointer
  -fno-stack-protector -mcpu=native+reserve_x15` ([ceil/build.sh](ceil/build.sh)).

The arms, each its own binary (a root file sets `cfg`):

| arm | what it puts back |
|---|---|
| `ceil` | nothing (`aa`: the same binary copied) |
| `heap` | the record from a per-worker allocator of 256-byte blocks (4 MiB segments, a free list), freed after the join, instead of the frame |
| `stack` | every fork that runs, popped or stolen, runs on a stack of its own (a per-worker pool of 512 KiB stacks, mapped untouched as the worker starts, last freed first), with Rig's own `switchNaked` to it and back: a stand-in for a fiber per task that reuses stacks as Rig's free list does, but takes a stack only when the fork runs, not when it is made |
| `sc` | Rig's spawn and handoff atomics: a seq_cst swap of the worker's run-next word at the fork; at the join a seq_cst swap (the waiter's word), a seq_cst compare-and-swap (the slot take), three seq_cst stores (`Done`), and one after (the status) |
| `mon` | Rig's monitor loop (`watchSlices`): a thread looking at every worker every 50 µs while any deque holds work (1 ms while any runs, doubling to 10 ms idle), and SIGURG to a worker that ran no new fork between two looks while its deque held work at both, backing off as Rig's does (four in a row, then doubling waits up to 1 ms); workers count the forks they run. The handler returns at once: Rig's would stop the fiber |
| `all4` | all four together |
| `seq` | no fork: `join` calls both halves in turn |

Rig itself: fork.rig built by `bin/rig` of the early-start worktree
(664b926a2, main plus #1158), `rig build --release`; `rig-aa` the same
binary copied; `rig-seq` ([ceil/seq.rig](ceil/seq.rig)) fork.rig with no
task, both halves plain calls in the same order; [ceil/fork3.rig](ceil/fork3.rig)
the three-pass program. Rayon: the record's twin copied to
[ceil/rayon/](ceil/rayon/) and a three-pass copy [ceil/rayon3/](ceil/rayon3/),
Rayon 1.12.0, Rust 1.99.1, `cargo build --release --offline` (LTO, one
codegen unit).

Probes (not arms): `off` (worker 0 a thread `main` starts),
`cbuild.sh` (the ceiling printing its input's build time),
[ceil/probe-rayon/](ceil/probe-rayon/) with `spin.sh` (Rayon spinning
200 ms before the timed psum), `nosig.sh` (the monitor arm sending no
signal), `rig-wait.sh` (fork.rig with `RIG_PREEMPT_WAIT_US=10000`).
Binaries are built into `ceil/bin` and `ceil/bin2` (not tracked).

Every sum of every arm checked as the board read it: psum 16760439056,
qsort 4194304 (sorted, times its length), nil 33554432. None differed.

## Method

[ceil/board.py](ceil/board.py): each round runs every program at 1 worker
and at 10 (`CEIL_WORKERS`, `RIG_WORKERS`, `RAYON_NUM_THREADS`), the worker
counts alternating, the programs rotating. One process times one psum and
one qsort right after building each input (board 1b), or three psums, three
nils and three qsorts (board 3: the first pass cold, then warm; qsort's
input rebuilt each time, outside the timing). 30 rounds each, every run in
`tools/mac-claim` (boards at 20:48 and 20:53, load 3-6 at their start and
end: other sessions' work, which the claim waits on but cannot stop).
[ceil/stats.py](ceil/stats.py): medians, ranges, and ratios paired by
round, median [quartiles]. Raw samples and logs in [raw/](raw/):
board1.json (the first board, same programs, before seq.rig's halves were
put in order; it agrees), board1b.json, board3.json (whose `mon` and
`all4` binaries signal without Rig's backoff, which ceil.zig gained after
them; mon.json reboards both with it), mon.json (the monitor
arm with the backoff), probe1.json and probe2.json (below); the `.txt`
files are stats.py's tables against the ceiling and against Rayon.

## Board 1b: one psum and one qsort a process (as the record's board)

Medians, ms (range); paired ratio to the ceiling, median [quartiles]:

| row | workers | ceil | aa | Rig | rig-aa | rig-seq | Rayon |
|---|---:|---|---|---|---|---|---|
| psum | 1 | 3.686 (3.57-4.35) | 3.732, 1.010 [0.989-1.034] | 6.298 (5.06-10.0), 1.717 | 6.490, 1.714 | 6.005 (4.35-10.5) | 6.143 (4.53-7.27), 1.620 |
| psum | 10 | 2.162 (2.06-3.48) | 2.080, 0.984 [0.934-1.022] | 2.452 (2.28-4.19), 1.126 [1.093-1.187] | 2.442, 1.149 | 6.149 | 2.542 (2.34-3.81), 1.173 [1.126-1.255] |
| qsort | 1 | 155.8 (151-163) | 156.0, 1.002 | 163.2 (154-219), 1.045 | 162.4, 1.041 | 137.6 (132-147) | 149.9 (142-162), 0.962 |
| qsort | 10 | 67.5 (60-102) | 65.4, 1.000 [0.931-1.064] | 57.3 (50-98), 0.863 | 57.0, 0.850 | 137.4 | 55.3 (52-84), 0.833 |

Against Rayon, paired: Rig psum at 10 workers 0.970 [0.910-1.000] (Rig 3%
faster), at 1 worker 1.045 [1.012-1.154]; the ceiling 0.852 at 10 and
0.617 at 1 (the first-pass effect, below).

The arms on the same board, paired to the ceiling:

| arm | psum 1 | psum 10 | qsort 1 | qsort 10 |
|---|---|---|---|---|
| aa | 1.010 [0.989-1.034] | 0.984 [0.934-1.022] | 1.002 [0.997-1.006] | 1.000 [0.931-1.064] |
| heap | 0.999 [0.974-1.027] | 0.995 [0.951-1.030] | 1.000 [0.989-1.006] | 1.008 [0.918-1.063] |
| stack | 1.020 [0.986-1.042] | 1.004 [0.966-1.020] | 1.004 [0.995-1.010] | 0.953 [0.890-1.029] |
| sc | 1.006 [0.952-1.031] | 0.971 [0.923-0.999] | 1.001 [0.993-1.007] | 0.985 [0.931-1.041] |
| mon (no backoff) | 1.003 [0.976-1.029] | 0.991 [0.953-1.015] | 1.073 [1.067-1.080] | 0.992 [0.916-1.035] |
| mon (Rig's backoff, mon.json) | 1.006 [0.991-1.017] | 0.987 [0.950-1.019] | 1.072 [1.064-1.076] | 1.010 [0.972-1.057] |
| all4 (with backoff, mon.json) | 1.038 [1.023-1.056] | 1.013 [0.985-1.041] | 1.073 [1.069-1.085] | 1.001 [0.961-1.044] |
| seq | 1.000 [0.981-1.012] | 1.727 [1.664-1.783] | 1.008 [0.999-1.020] | 2.379 [2.229-2.555] |

## Board 3: the first pass, then warm ones

Medians, ms; psum1 is the cold pass, psum3 the third:

| row | workers | ceil | Rig | Rayon | Rig / Rayon paired | ceil / Rayon paired |
|---|---:|---:|---:|---:|---|---|
| psum1 | 1 | 3.802 | 7.271 | 6.737 | 1.068 [0.967-1.227] | 0.584 |
| psum2 | 1 | 3.710 | 3.959 | 3.581 | 1.086 [1.057-1.156] | 1.020 [0.950-1.164] |
| psum3 | 1 | 3.659 | 3.981 | 3.805 | 1.072 [0.955-1.125] | 1.000 [0.925-1.162] |
| psum1 | 10 | 2.173 | 2.573 | 2.575 | 1.024 [0.945-1.074] | 0.846 [0.782-0.949] |
| psum2 | 10 | 2.065 | 2.226 | 2.202 | 1.034 [0.941-1.121] | 0.968 [0.881-1.024] |
| psum3 | 10 | 2.048 | 2.121 | 2.160 | 0.977 [0.933-1.040] | 0.963 [0.911-1.033] |
| qsort1 | 10 | 68.7 | 60.3 | 56.9 | 1.054 | 1.202 |
| qsort3 | 1 | 150.0 | 142.1 | 148.0 | | 1.020 |
| qsort3 | 10 | 54.3 | 50.9 | 51.3 | | |

On psum the ceiling's warm arms at 10 workers sit within 2% of it (heap
0.995, stack 0.985, sc 1.017, mon 1.009, all4 1.017 on psum3; the A/A arm
1.033). The ceiling's own first pass costs it 0.1 ms over warm at 10
workers (2.17 against 2.05); Rig's and Rayon's cost them 0.4.

## Per join: `nil`

psum's tree, each leaf giving its length, 4,095 joins; warm (nil2 and
nil3 pooled, 60 samples each), board 3:

| program | 1 worker, µs | ns a join | over the ceiling, ns | 10 workers, µs | over the ceiling, ns a join |
|---|---:|---:|---:|---:|---:|
| seq (no fork) | 5.1 | 1.3 | | 4.5 | |
| ceil | 15.0 | 3.7 | 0 | 13.6 | 0 |
| aa | 15.0 | 3.7 | 0.0 | 13.0 | -0.2 |
| heap | 18.6 | 4.5 | 0.9 | 14.8 | 0.3 |
| stack | 98.9 | 24.1 | 20.5 | 26.4 | 3.1 |
| sc | 48.7 | 11.9 | 8.2 | 18.9 | 1.3 |
| mon | 18.2 | 4.4 | 0.8 | 14.9 | 0.3 |
| all4 | 111.5 | 27.2 | 23.6 | 34.4 | 5.1 |
| Rig | 277.0 | 67.6 | 64.0 | 87.5 | 18.0 |
| Rayon | 40.6 | 9.9 | 6.3 | 39.6 | 6.3 |

(At 10 workers a 13-88 µs tree is mostly done before the sleeping workers
wake, so those columns are the cost on the critical path, not a join's.)

## What each cost is worth

On the Mac, for psum (4,095 forks), per join at 1 worker and as a share of
the ceiling's psum:

| Rig's cost | free fork-join | ns a join (nil) | psum, 1 worker | psum, 10 workers |
|---|---|---:|---|---|
| a fresh stack and two switches per fork | removes (the fork runs inline on the joiner's stack) | 20.5 | 0.084 ms, 2.3% (stack arm 1.020) | 0.3%, within the A/A |
| seq_cst atomics in spawn and handoff | removes (a deque push and pop: one seq_cst store and load in the pop) | 8.2 | 0.034 ms, 0.9% (arm 1.006) | within the A/A |
| a heap record per fork | removes (the record in the frame) | 0.9 | 0.004 ms, 0.1% | within the A/A |
| the monitor waking every 50 µs while a ring holds forks | removes if forks stay out of `queuedHere` | 0.8 (the count) | 0.6% in the ceiling (arm 1.006); 4% in Rig (probe 2) | within the A/A |
| the four together | | 23.6 | 3.8% (all4 1.038 [1.023-1.056]) | 1.3% (1.013 [0.985-1.041]) |
| the rest of Rig's task path (record setup, run-next slots and ring, handoff, `fiberMain`, `tickCall`) | removes, where the fork runs inline | 40.4 | 0.17 ms, 4.5% | about 0.5% |
| Rig in all | | 64.0 | warm psum3 1.076 against the ceiling; the predicted 0.26 ms is the measured 0.32 within noise | warm psum3 1.021 |

On qsort (511 forks) every per-fork cost is invisible but one: the
**monitor**. In qsort's long partitions a fork waits in the deque while
its maker partitions 2^21 elements, so the monitor looks every 50 µs
throughout (and signals the maker: 208 times a process with the backoff,
519 without). It costs the ceiling 7% at 1 worker (166.6 against 155.8 ms;
1.072 [1.064-1.076]), from its wake-ups alone (probe 2). In Rig it is
larger: **fork.rig's qsort at 1 worker is 16-19% slower than the same
program with no task (161.5-163.2 against 135.2-137.6 ms), and all of that
is the monitor** (probe 2: with a 10 ms period, 136.3). The ceiling's own
fork-join costs qsort 1% (seq 1.008). Free fork-join, keeping forks out of
`queuedHere`, removes it.

The first pass's heap and stack faults: on the Mac a heap's first segment
faults 16 KiB at a time and the ceiling's stack arm (fresh stacks in the
first pass) costs nothing measurable cold or warm at 10 workers (one-pass
1.004, psum3 0.985). The pup costs (#1156's huge page, #1158's thread
start) cannot be measured here; pup-job.sh times the ceiling's cold pass
there, where the ceiling, whose workers start early and touch their heaps,
stands for main with both fixes.

## The first pass

At 1 worker Rig's and Rayon's first psum takes 6-7 ms and their warm ones
3.6-4.0, with a wide range (Rayon 3.8-9.3 ms); the ceiling's first pass
equals its warm ones (3.80 against 3.66-3.71, a narrow range). rig-seq,
fork.rig with no task at all, shows the same slow first pass (6.0 ms,
4.3-10.5), so it is not fork-join. Probe 1 ([raw/probe1.txt](raw/probe1.txt),
20 rounds, 1 worker):

- Not thread placement: the ceiling with worker 0 a thread `main` starts
  (`off`, which also builds the input there) runs its first pass in 3.79 ms.
- Not the cores' clock: Rayon spinning 200 ms on its main thread between
  building the input and timing psum (`probe-rayon`, `SPIN_MS=200`) is as
  slow (7.26 against 7.05 ms).
- Rayon builds its input in 19.3 ms, the ceiling in 28.5 (written by a
  plain loop, which Zig 0.17 does not vectorize).
- Not the program run before: in board 1b and probe 1 the slow first
  passes are as slow after a Rayon run as after any other.
- And not always there: in probe 2, half an hour later, fork.rig's and
  rig-seq's first pass took 3.6-5.2 ms (medians 4.10 and 3.78), close to
  warm. The cause is not found. It is outside the runtime (rig-seq has no
  task), it lifts Rayon's and Rig's one-pass rows alike, and the ceiling
  never showed it. Two short runs of the monitor arm (0.5 s) ran during
  probe 1's 28 seconds.

At 10 workers the same effect is the first pass's 0.4 ms for Rig and
Rayon. Board 1b's ceiling psum (2.16 ms, 15% faster than Rayon) carries
it; the like-for-like distance from the ceiling to Rayon is the warm one:
3-4% at 10 workers, level at 1.

## qsort

The ceiling's qsort is 15-20% slower than Rig's and Rayon's at 10 workers
(67.5 against 57.3 and 55.3 ms) and level at 1 (155.8 against 163.2 and
149.9). Its fork-join is not the cause: no arm moves it, and it gains as
much from 10 workers as Rig does over its own sequential program (ceil seq
over ceil 2.38; rig-seq over Rig 2.40). The difference is in the
partition and the lists (Zig's `ArrayList.append` in safe mode, libc
malloc), outside question 3. The leaf is Rig's own sort in both.

## Probe 2: the monitor, and Rig's qsort at 1 worker

[raw/probe2.txt](raw/probe2.txt), 20 rounds at 1 and 10 workers: the
monitor arm, the monitor arm sending no signal (`CEIL_NOSIG=1`: it looks
and counts only), fork.rig, fork.rig with its monitor's period while work
waits at 10 ms instead of 50 µs (`RIG_PREEMPT_WAIT_US=10000`, `rig-wait`),
and rig-seq.

| row | workers | ceil | mon | mon, no signal | Rig | rig-wait | rig-seq |
|---|---:|---:|---:|---:|---:|---:|---:|
| psum | 1 | 3.734 | 3.711 | 3.629 | 4.102 | 3.975 | 3.776 |
| psum | 10 | 2.077 | 2.133 | 2.235 | 2.313 | 2.293 | 3.758 |
| qsort | 1 | 156.6 | 167.9 | 167.6 | 161.5 | 136.3 | 135.2 |
| qsort | 10 | 66.1 | 65.1 | 67.3 | 54.1 | 55.1 | 135.3 |

- **Rig's monitor is the whole of Rig's qsort gap at 1 worker.** With its
  period at 10 ms, fork.rig's qsort takes 136.3 ms against 161.5 (paired
  0.846 [0.828-0.856]): level with the same program with no task (135.2).
  At 10 workers it changes nothing (1.013). On psum at 1 worker it is
  worth 4% (0.962 [0.915-1.010]); at 10, nothing (1.006).
- **In the ceiling the cost is the monitor's wake-ups, not its signals:**
  the arm costs qsort 7% at 1 worker with signals and without (1.072 and
  1.071). A thread waking every 50 µs (2,000-2,100 looks a process) costs
  the one busy worker about 5 µs a look on macOS, whichever core the
  monitor lands on; Rig's monitor, which also stops the fiber, costs it
  more (16%).
- In this probe Rig's first psum at 1 worker took 3.9-5.2 ms (median 4.10),
  with no slow first read (the next section): Rig over the ceiling 1.112
  [1.015-1.217], rig-seq 0.996. So Rig's fork-join costs psum 8-11% at 1
  worker here, of which the monitor is 3-4 points.

## pup: the job for the Rig session

[ceil/pup-job.sh](ceil/pup-job.sh):

    ceil/pup-job.sh build /zfs/trig-pup/ffj-ceil/run1 /zfs/trig-pup/rig-664b926a2/bin/rig
    # then, inside an ab slot the Rig session opens (about 15 minutes):
    ceil/pup-job.sh time /zfs/trig-pup/ffj-ceil/run1

`build` copies the sources to `OUT/src` and builds, on E-cores 12-19 with
no slot: every ceiling arm (one-pass and three-pass, the A/A copies), the
Rayon twins (`cargo build --release --offline` in the copies), and, given
a `bin/rig` (the early-start commit 664b926a2, from `tools/pup-rig
664b926a2`, or main once #1156 and #1158 land), fork.rig, fork3.rig and
seq.rig. `time` runs board 1 (one pass) and board 3 (three passes), 20
rounds each, at 1 worker on core 6 and 12 workers on cores 0-11, the
driver on core 8, writing `board1.json`, `board3.json`, their logs, and
stats.py's tables `board1.txt`, `board3.txt`. `all` does both. The
ceiling's Linux build links glibc (`-lc`; libc malloc, as Rust's); it was
cross-compiled from the Mac for x86-64 Linux. On pup the monitor arm
stops at its start with an errno Zig's wrapper treats as unreachable
(`std/c.zig`, `errno`), even with SIGURG set and sent by system call, so
the job leaves out the arms that run it (`mon`, `mon3`, `all4`,
`all43`); the Mac's boards measured them.

## Can Rig beat Rayon on psum at 12 workers on pup?

Yes on the record's board, once #1156 and #1158 land, and free fork-join
is not what decides it; about 75% sure.

- The board times the process's first pass. Rayon starts its 11 threads
  inside that pass (0.75-0.94 ms on pup, runtime.md); Rig with the early
  start does not. The runtime expert's probe with both fixes ran the first
  pass in 3.87 ms against Rayon's 4.32 (10% faster), and on the Mac the
  early start alone already puts Rig 3% ahead at 10 workers (paired 0.970).
- Warm, pup has Rig 2-3% behind Rayon (3.14-3.24 against 3.09-3.16). The
  ceiling says a runtime of Rig's shape can be 3-4% ahead warm on the Mac;
  Rig's per-fork cost at 12 workers on pup is about 0.02 ms (71 ns a join
  after #1152, over 12 workers), under 1% of a 3.1 ms pass, so free
  fork-join closes at most about a third of pup's warm gap. The rest is in
  the ramp (waking twelve workers from sleep) and the first-pass memory
  effect, which the ceiling avoids and Rig does not.
- What makes me unsure: pup's numbers come from other programs and other
  days, the probe's 3.87 ms had the heap warmed at thread start (not
  exactly #1156's small first page), and THP and the input's first read
  behave differently on pup. pup-job.sh's board, with the early-start Rig,
  the ceiling and Rayon in one slot, settles it.

## The pup board (Rig session, ab slot 607)

`pup-job.sh` with Rig at main 2dc9a46f5 (before the early start and the
first-segment fault), the monitor arms left out, quiet honoured; the
data is on pup in `/zfs/trig-pup/ffj-ceil/run2/` (`board1.txt`,
`board3.txt`, and the JSON beside them). Medians, each arm's time over
the ceiling's, paired by round:

| row | workers | Rig | Rayon | stack | heap, sc, seq |
|---|---:|---:|---:|---:|---|
| psum | 1 | 1.065 | 1.083 | 1.032 | level |
| psum | 12 | 1.515 (6.09 ms) | 1.181 (4.61 ms) | 1.059 | |
| qsort | 1 | 0.900 | 0.868 | | rig-seq 0.632 |
| qsort | 12 | 0.691 (102.6 ms) | 0.866 (126.6 ms) | | |
| nil, first pass | 1 | 9.8 (0.388 ms) | 1.6 | 2.84 | heap 1.22, sc 3.29 |
| nil, first pass | 12 | 7.6 | 1.9 | | |

The ceiling takes psum's one pass at 12 workers in 3.94 ms. That is 15%
under Rayon's 4.61, on pup, with its workers started and their heaps
touched before the pass: a runtime of Rig's shape can beat Rayon there.
Rig at main took 6.09 ms. The early start and the first-segment fault
(#1158) target that pass. Per join (`nil`), Rig trails the ceiling most:
9.8 times its time at one worker, where Rayon is 1.6. That gap is what
free fork-join targets. The ceiling's qsort is slower than both Rig and
Rayon on pup too, from its partition code (see "qsort").

## What I could not measure

- pup itself (the job is written, not run), and therefore the huge-page
  and thread-start costs; x86's seq_cst stores (an `xchg` each, where
  AArch64 stores seq_cst and release alike), so the `sc` arm's share on pup
  is likely larger than the Mac's 8 ns a join.
- A stack per task taken when the task is made, as Rig takes it: the
  stack arm takes one when the fork runs, so it holds fewer stacks at once
  and touches fewer fresh ones in a cold pass.
- Rig's preemption itself: the monitor arm's handler returns, so it
  measures the signals, not a fiber stopped and moved.
- The remaining 40 ns a join of Rig's task path, by piece.
- Why Rig's and Rayon's first pass read the input slowly on the Mac in
  four boards and not in the fifth.
