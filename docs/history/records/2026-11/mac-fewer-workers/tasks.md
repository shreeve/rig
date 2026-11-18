# bench/tasks on the Mac: does "fewer awake workers" win pure task scheduling? (2026-11-17)

Probe arms only: no pull request, nothing for merge. Machine: Apple M5, 4 performance cores (CPUs 6-9)
and 6 efficiency cores (CPUs 0-5), macOS 27.2.1. Rig main 68f4a6d15 (#1138); Tokio 1.54.1 from
`misc/tokio`, Rayon from `misc/rayon`, Go 1.27.3 (bench/tasks' own builds, `bench-tasks --build-only`).
bench/net's Tokio and bench/http's hyper and load generator are the mac-closed-loop session's builds.

- Worktree, left in place: `/Users/shreeve/Data/Code/worktrees/rig/mac-tasks` (branch `mac-tasks` at
  main, no commit; `src/` clean). Everything is in its `bb/` folder (untracked): binaries (`arms/`,
  `rigs/`), drivers (`board.py`, `summ.py`, `prun.c` = a launcher that reads the exited process's
  `rusage_info_v6`, so the P-core share of short runs), `claim*.sh` (what each claim ran),
  `raw/*.jsonl` (every run), `appendix.sh` (prints the appendix below), `sched.probe.zig`, `spawn.rig`.
  A copy of the scripts and raw runs: `/Users/shreeve/Data/Code/Claude/rig/rig/fable-review/mac-tasks/`.
- Branches, pushed: **`probe-tasks-switches`** 1420b31f1 + 664e78054 (every probe switch, read from the
  environment; the second commit adds `RIG_P_PUSHCAP`), **`probe-tasks-spin`** fb1948c58 (the plain arm
  the proof ran). Each commit message says it is a probe, not for merge.
- Every timed run held the Mac's claim (`tools/mac-claim`: mt-1, mt-2, mt-2b, mt-3, mt-4, mt-5, mt-6,
  mt-P1, mt-P2, mt-P3; each under its limit); every build ran through `tools/heavy`;
  `~/Data/Code/mumps-compare/.mac-quiet` was absent (the drivers refuse to run with it); no pup, no burst,
  no pkill. **One departure to know:** from 22:41 to 23:08 both heavy slots were held by two `swarm`
  runs of the `mac-one` worktree that had made no progress since 22:38 (0% CPU, colliding in one
  `.swarm/`); I relaunched my builds with `RIG_HEAVY_SLOTS=3` (heavy's own knob; it still queues in
  order), then a `mac-one` claim series held the Mac until 23:21. About 40 minutes of the box went to
  waiting.

## The answer in short

1. **Rig trails no bench/tasks row on this Mac.** Against Tokio (12 rounds, medians): spawn 1.25x
   faster, chain 3.1x, yield 7.0x, hog about 19,000x, produce 1.19x, fanout level (1.003). Against Go:
   1.6x, 4.0x, 41x, 19,000x, 1.18x, level. Rayon's only bench/tasks row, produce, is level (Rayon
   1.4% slower). The rows where Rig trails are the fork-join record's: **psum 7% and qsort 8% behind
   Rayon** (12 rounds; was 18% and 53% on 2026-11-15) — and that gap is single-thread code, not the
   scheduler: at one worker Rig is 36% (psum) and 30% (qsort) slower than Rayon at one thread, and
   Rig scales better from 1 to 10 workers (3.1x and 3.3x against Rayon's 2.4x and 2.7x).
2. **The principle has a large ceiling on one row, spawn.** Rig's spawn is 2.6x faster at 2 workers
   than at 10 (5.9 against 15.4 ms) and 1.8x faster at 4; Tokio's is 2.2x faster at 1 thread than at
   10. At 1-4 workers every cycle is on a performance core, but 4 workers (100% P) are still 32% slower
   than 2: the cost is coordination (11 steals and 1.25 sleeps and wakes a wave per worker at 10 workers, against 0.85 steals
   and 0.5 sleeps a wave per worker at 2, 0.09 s of system time against 0.007 at 2 workers), not only efficiency cores.
   Every other row wants every worker: yield 9.2x slower at 1 worker, fanout 7x, produce 1.8x.
3. **No probe wins.** 25 arms in four screening rounds and one proof. Caps on awake workers (any
   form) win spawn and lose fanout or yield 1.6-4.6x; the backlog, chain, help-after and push caps lose
   spawn or other rows; QoS, spreading, the run-next steal and spawning into the ring do nothing or
   worse. The best, **spinning 5 µs before sleeping on performance cores only** (`probe-tasks-spin`),
   makes bench/tasks' spawn row 27% faster than main (16 rounds, all under main; A/A 0.982) but the
   same work repeated in one process **26% slower** (15 rounds, all over main; A/A 1.016), bench/http's
   closed loop **3.4% slower** (15 rounds, all under main; A/A 0.995) and bench/net 2-6% slower. The
   spawn row's win is the scheduler's start-up (the first 100 waves after the workers start run 14 ms;
   the same waves warm run 9.2-10 ms), not the steady state. **Nothing beats noise as a change worth
   building.** What I would try next is in section 6.

## 1. The rows, measured again (claim mt-1, 23:24; 12 rounds interleaved and rotated)

How quiet: the board began with load 5.0 (the board's own runs raise it to 6.6) and nothing else over
50% of a core at either end; claim mt-1's own wait for quiet came first. Every round is in A1 and A2.

| row (per) | Rig median (min) | Tokio | Go | Rayon | Rig against Tokio | against Go |
|---|---:|---:|---:|---:|---|---|
| spawn (task) | 144 ns (116) | 178 ns (173) | 229 ns (228) | | 1.25x faster [1.15-1.91] | 1.60x |
| chain (task) | 55 ns (53) | 177 ns (160) | 222 ns (214) | | 3.12x [2.59-3.50] | 4.05x |
| fanout (run) | 68.8 ms (67.5) | 69.7 ms (66.5) | 69.0 ms (66.1) | | 1.003 [0.933-1.062] | 1.008 |
| yield (yield) | 6.1 ns (6.0) | 43.8 ns (40.9) | 248.6 ns (246.6) | | 6.96x | 40.6x |
| hog (step) | 0.22 µs (0.18) | 4.2 ms (2.9) | 4.3 ms (4.0) | | about 19,000x | about 19,000x |
| produce (run) | 5.24 ms (5.20) | 6.26 ms (5.79) | 6.19 ms (5.96) | 5.32 ms (5.28) | 1.19x [1.10-1.21] | 1.18x; Rayon 1.014 |
| psum (fork record) | 2.65 ms (2.60) | | | 2.48 ms (2.45) | Rayon 0.934 [0.925-0.961]: **Rig 7% slower** | |
| qsort (fork record) | 58.4 ms (54.8) | | | 54.0 ms (52.1) | Rayon 0.938 [0.813-0.972]: **Rig 8% slower** | |

Whole process (bench/tasks, median a run): Rig 0.32 s wall, 2.98 s user, 0.017 s system, 2,709
involuntary switches, 10.5 G cycles, 51% on performance cores; Tokio 0.39 s, 3.27 s, 6,068, 11.6 G, 53%.

## 2. Where the time goes

### By worker count (claims mt-2 and mt-2b; 6 and 8 rounds; A3, A4)

bench/tasks, Rig with `RIG_WORKERS`, Tokio with `TOKIO_WORKER_THREADS` (ms, median):

| workers | spawn Rig / Tokio | chain | fanout | yield | produce | P-core share of cycles, Rig / Tokio |
|---:|---|---|---|---|---|---|
| 1 | 6.57 / 8.26 | 0.553 / 0.807 | 487 / 482 | 56.5 / 16.4 | 9.44 / 4.83 | 100% / 100% |
| 2 | **5.86** / 16.77 | 0.540 / 1.83 | 250 / 247 | 24.9 / 19.3 | 6.23 / 4.97 | 100% / 100% |
| 4 | 7.72 / 18.46 | 0.538 / 1.66 | 133 / 154 | 11.2 / 20.2 | 5.23 / 6.26 | 100% / 100% |
| 6 | 11.73 / 18.99 | 0.554 / 1.80 | 101 / 111 | 8.67 / 31.4 | 5.22 / 6.26 | 74% / 77% |
| 10 | 15.39 / 17.83 | 0.544 / 1.74 | 69 / 71 | **6.12** / 44.1 | 5.29 / 6.25 | 51% / 53% |

- **Rig goes faster with fewer workers on spawn only**: 2.6x at 2 workers, 2.0x at 4. Tokio too, and
  more so (fastest at one thread). Hog is level at every count (0.008-0.011 ms).
- **Is the gain from staying on performance cores?** Partly. 1, 2 and 4 workers run 100% on performance
  cores, yet 4 is 32% slower than 2; 6 (74%) and 10 (51%) add 52% and 31% more. So each extra worker
  costs coordination first and an efficiency core second.
- **Every other row wants every worker** (yield 9.2x, fanout 7x slower at one worker), and Tokio's
  produce at 1-2 threads (4.83-4.97 ms) is 8% under Rig's best (5.22 at 4-6 workers): Tokio's producer
  keeps its core while one thread runs it all; noted, not pursued.

The fork record (psum, qsort; ms):

| workers | psum Rig / Rayon | qsort Rig / Rayon | system s a run, Rig / Rayon |
|---:|---|---|---|
| 1 | 7.97 / 5.87 (1.36x) | 191.6 / 146.8 (1.31x) | 0.051 / 0.026 |
| 2 | 5.06 / 4.19 | 121.3 / 91.2 | 0.072 / 0.030 |
| 4 | 3.74 / 3.40 | 82.0 / 59.0 | 0.096 / 0.039 |
| 6 | 2.97 / 2.61 | 73.3 / 55.5 | 0.127 / 0.056 |
| 10 | 2.58 / 2.43 (1.06x) | 58.7 / 54.7 (1.07x) | 0.091 / 0.110 |

The gap is widest at one worker, where no scheduling happens: it is the leaves' code (the sum loop and
the partition into Lists in a safe build, against Rust's), and Rig narrows it as workers are added. No
probe moved psum; caps and the backlog rule slowed qsort 20-28% (A6). Not a scheduler row.

### spawn at 10 workers: counters and profile (claim mt-4; A16, A17)

`spawn.rig` (bench/tasks' spawn wave, 100 waves of 1,000, repeated 20 times in one process, each
repetition printed): warm, main runs 9.2-10.0 ms a repetition at 10 workers and 7.4-7.8 at 2 or 4; the
first repetitions of a run are sometimes 14-22 ms (A8: 4 of 20 in one run), as bench/tasks' spawn row,
which is the first 100 waves after the workers start, reads 14 ms. `RIG_SCHED_STATS=1` over 200
repetitions: at 10 workers each worker ran 2.0M fibers, stole 220k times and slept 25k times (1.25 sleeps
a wave a worker); at 2 workers 10M fibers, 17k steals, 10k sleeps. `/usr/bin/time` a run of 20: system
0.091 s at 10 workers against 0.007 at 2, involuntary switches 19,000 against 2,400, user 0.87 s against
0.28. `sample` (2 s, 10 workers): 4,431 samples in `kevent64` (sleeping workers), then `sched.next` 608
and `sched.search` 254 (searching and the 3 µs wait on a run-next slot), `switchNaked` 310,
`fiberStartNaked` 273; at 2 workers the program's own path dominates. A wave's 1,000 leaves are about
20 µs of work; ten workers spend it waking, stealing half of the maker's ring, and sleeping again.

## 3. The probes

One probe build (`probe-tasks-switches`), switched by environment variables read as the workers start,
the mac-echo probe's switches plus these (all in `src/sched.zig`):

| switch | what it does |
|---|---|
| `RIG_P_MAXAWAKE=N` | `notify` wakes no sleeper while N workers are awake (mac-echo's) |
| `RIG_P_SPREAD=N` | `spread` wakes only when the ring holds N fibers (mac-echo's) |
| `RIG_P_NOSTEALNEXT=1` | a searcher takes nothing from run-next slots (mac-echo's) |
| `RIG_P_QOS=N` | each worker thread asks for QoS class N (33 = user-interactive) |
| `RIG_P_BACKLOG=K` | `notify` wakes only while the caller's ring holds K fibers for each worker awake |
| `RIG_P_CHAIN=K` | the last searcher that found work wakes another only while some ring holds K |
| `RIG_P_SPIN=µs`, `RIG_P_SPINP=1` | a worker with nothing to run spins for work first; with SPINP only on a performance core (`pthread_cpu_number_np` at or above `hw.perflevel1.logicalcpu`) |
| `RIG_P_SPINSEARCH=1` | the spinner counts as searching (no wakes meanwhile, as Go's spinning M) and also sees run-next slots |
| `RIG_P_HELPAFTER=ns` | ring work wakes a sleeper only once that ring has held work this long |
| `RIG_P_STEALNEXT_NS=ns` | the wait before a run-next fiber is stolen (main 3 µs) |
| `RIG_P_SPAWNRING=1` | a task made while a worker sleeps goes to the ring, not a run-next slot |
| `RIG_P_PUSHCAP=N` | a fiber pushed from a slot to the ring wakes no sleeper while N are awake (spread, yield and the searcher chain uncapped) |

**Screening, bench/tasks, ratio to main paired by round, median** (10 rounds each; `aa` is the probe
with no switch, the arms' own A/A; every round in A5, A7, A9, A10b):

| arm | spawn | chain | fanout | yield | produce | verdict |
|---|---|---|---|---|---|---|
| aa (four boards) | 1.094-1.189 | 0.990-1.018 | 0.987-1.025 | 1.004-1.077 | 0.992-1.006 | the probe build itself |
| awake 4 / awake 2 | 0.481 / 0.393 | 1.000 / 1.006 | **1.600 / 2.839** | **2.105 / 4.637** | 0.999 / 1.167 | loses |
| backlog 2 / 8 | 0.996 / 0.780 | level | 1.133 / 1.149 | 1.038 / **1.948** | 1.164 / 1.164 | loses |
| chain 4 | 1.130 | 0.999 | 1.007 | 1.048 | 0.999 | loses spawn |
| no chain (K huge) | 0.983 | 1.010 | 1.012 | 1.053 | 1.004 | as aa |
| spread 4 | 1.169 | 0.992 | 0.970 | 1.028 | 0.992 | as aa |
| QoS user-interactive | 1.180 | 0.986 | 0.997 | 1.038 | 1.003 | as aa (perf-cores.md agrees) |
| spin 20 µs, every core | 1.355 / 1.307 (spinsearch) | 1.029 / 1.164 | level | 1.161 / 1.093 | level | loses |
| **spin 5 µs, P only** | **0.712** | 0.994 | 0.984 | 1.045 | 1.002 | wins the row |
| spin 20 µs, P only | 0.688, 0.725 | 1.003-1.014 | level | 1.084-1.086 | level | wins the row, costs yield |
| spin 50 µs, P only | 1.297 | 1.010 | 1.003 | 1.058 | 0.996 | loses |
| spin 20 P + spinsearch | 0.664 | **1.136** | 1.012 | 1.072 | 0.989 | costs chain (reads every slot) |
| the same + help-after 10 µs | 0.584 | 1.126 | 1.009 | 1.073 | 0.993 | costs chain |
| help-after 10 / 30 µs | 1.544 / 1.875 | level | 1.03 | 1.06 / 1.04 | level | loses |
| steal-next 0 / 1 µs / none | 1.120 / 1.088 / 1.038 | level | 0.988 / 1.001 / **3.181** | ~1.03-1.05 | 0.993 / 0.999 / 1.109 | as aa, or loses |
| spawn into the ring | 1.236 | **3.479** | 1.002 | 1.028 | 1.107 | loses (no handoff) |
| push cap 4 / 2 / 1 | 1.235 / 1.396 / 1.921 | level | 1.04 / 1.01 / 1.00 | 1.03-1.04 | level | loses |
| `RIG_WORKERS` 2 / 4 (main) | 0.444 / 0.550 | level | 3.69 / 1.91 | 3.91 / 1.79 | 1.080 / 1.002 | the ceiling, and its price |

**The steady state, the spawn harness** (median of 20 repetitions a run, 10 rounds; A8, A10, A10c):
aa 1.039-1.059 of main; spin 20 P 0.956 [0.853-1.097]; spin 20 P + spinsearch 1.052; help-after 10 µs
2.418; steal-next 0 1.116, 1 µs 0.987; no steal-next 1.043; spawn into the ring 1.086; no chain 0.990;
push cap 4 / 2 / 1 1.080 / 1.259 / 2.624; `RIG_WORKERS` 2 0.78-0.81, 4 0.76-0.77. Nothing but fewer
workers moves the warm spawn; every arm that delays wakes (help-after, push cap 1) multiplies the CPU
(3.5-3.7 s user against 0.95 for 20 repetitions), a pathology of the search path when the maker's ring
is left to fill that I did not have time to take apart.

**On the fork record** (A6): every arm within 1-2% of main on psum; awake 4 and backlog 2 slowed qsort
20% and 28%, no steal-next 6%.

## 4. The proof: spin 5 µs on performance cores (`probe-tasks-spin` fb1948c58)

The arm: in `sched.loop`, a worker with nothing to run, on a performance core, looks for work in the
rings, the global queue, its pinned queue and its slots for `idle_spin_ns` (5 µs) before it sleeps;
on an efficiency core it sleeps at once. `aa` is the same source with `idle_spin_ns = 0`, built apart
(the layout and A/A control: same code, a variable that differs). Claims mt-P1 (23:44), mt-P2, mt-P3
(to 23:50); load 2.6-6.9, Chrome's renderer at 88% at P1's end, launchd at 41% at P3's end. Every round
in A11-A15.

| row | main | aa / main [range] | spin / main [range] | rounds spin under main |
|---|---:|---|---|---|
| tasks spawn (16 rounds) | 13.80 ms | 0.982 [0.669-1.120] | **0.727 [0.676-0.942]** | 16 of 16 |
| tasks chain | 0.554 ms | 0.991 [0.952-1.055] | 0.995 [0.958-1.227] | |
| tasks fanout | 74.7 ms | 0.987 [0.863-1.178] | 0.981 [0.840-1.401] | |
| tasks yield | 6.57 ms | 1.004 [0.818-1.492] | 1.035 [0.793-1.423] | |
| tasks hog | 0.011 ms | 1.002 | 0.940 | |
| tasks produce | 5.31 ms | 1.000 [0.960-1.082] | 1.004 [0.987-1.129] | |
| **spawn harness, warm (15 rounds)** | 9.17 ms | 1.016 [0.933-1.072] | **1.263 [1.141-1.363]** | **0 of 15** |
| fork psum / qsort (15 rounds) | 2.86 / 68.8 ms | 0.999 / 1.015 | 0.998 / 0.979 | |
| net ping-pong (15 rounds) | 333 ms | 1.007 [0.926-1.188] | 1.025 [0.950-1.094] | |
| net echo | 826 ms | 0.997 [0.975-1.035] | 1.019 [0.977-1.078] | |
| net connect | 26.9 ms | 0.994 [0.720-1.045] | 1.056 [0.684-1.549] | |
| **http closed loop (15 rounds), req/s** | 132,773 | 0.995 [0.931-1.052] | **0.966 [0.936-0.993]** (128,332) | 0 of 15 over main |

Tokio beside: tasks spawn 1.255 of main, echo 0.761 (main has not the `one` poller change), hyper
1.019 of main on the closed loop. The arm's warm spawn takes 1.38 s user against 0.87 (20 repetitions)
and 35,700 involuntary switches against 19,200; the closed loop's server spends 18.9 µs a request
against 16.3 (user 4.5 against 2.4 µs). It wins one cold row and loses the warm form of the same work and
the closed loop: not a change to build.

## 5. Why the HTTP lesson does not carry over

The Mac HTTP win removed *work that existed only because more workers were awake*: looks at other
workers' pollers (4.6 a round trip) and sockets spread over ten pollers. bench/tasks has no pollers;
what extra workers cost here is steals and sleep/wake cycles on a maker's ring, and a rule can only cut
those by keeping workers asleep, which the rows that need every worker (fanout, yield, produce, the fork
record) pay for at once. The rule that separates them must know how long the queued fibers will run,
which neither the count in a ring (backlog) nor the time it has waited (help-after) tells: spawn's
fibers end in about 20 ns, yield's run 6 ns at a time but forever, fanout's for 60 ms. Spinning keeps
workers awake on the cores where it is cheapest and so helps the scheduler's first waves, but in the
steady state it is more workers awake, which is the opposite of the lesson.

## 6. What I would try next, in order

1. **Helpers that hold a stolen batch count as searching while fibers are short.** A worker that stole
   N fibers keeps the searching count until its batch is down to one, so the maker's pushes wake no
   one while the helpers already awake have work; released at once when its present fiber has run
   20 µs (the closed-loop arm's `long_share` measure, which already reads the clock per fiber on
   workers with descriptors). Spawn should approach the 2-4 worker figure; fanout's first fiber would
   release the count within 20 µs. Needs a clock read per switch on every worker: yield's 6 ns switch
   is the row to watch (the closed loop's two extra loads cost it 3.9% before a one-load test fixed it).
2. **Why delayed wakes multiply the CPU** (help-after 10 µs, push cap 1: 3.7x the user time): a
   searcher loop that keeps waking and finding the maker's slots, probably `stealNext`'s 3 µs wait
   per victim; fixing it is a precondition for any rule that wakes later.
3. **The fork rows' 7-8%** is single-thread code (section 2): the sum loop and the List partition in a
   safe build against Rust's, for the codegen side, not the scheduler.

## Appendix: every board, every round

Tables from `bb/appendix.sh` (ms a run; ratios paired by round to the first-named base; the `#` lines are each board's load and processes over 50% of a core at its start and end).

### A1. bench/tasks re-measured (claim mt-1): raw/c1-tasks.jsonl

```
# 23:24:24 start load { 5.04 6.01 4.86 } over50: none
# 23:24:41 end load { 6.59 6.30 4.98 } over50: none
## spawn (ms)
| arm | median | min | vs rig paired median [range] | rounds |
|---|---:|---:|---|---|
| rig | 14.366 | 11.577 | 1 | 13.465 11.577 14.373 14.698 14.563 14.581 14.988 14.342 15.604 14.358 13.687 13.423 |
| tokio | 17.777 | 17.250 | 1.248 [1.151-1.911] | 25.725 20.895 17.394 17.807 18.323 17.561 17.250 17.747 17.973 18.413 17.723 17.435 |
| go | 22.861 | 22.766 | 1.596 [1.461-2.010] | 27.061 22.909 26.863 22.767 22.834 22.887 22.984 23.039 22.799 22.767 22.766 22.814 |

## chain (ms)
| arm | median | min | vs rig paired median [range] | rounds |
|---|---:|---:|---|---|
| rig | 0.548 | 0.530 | 1 | 0.760 0.538 0.543 0.544 0.547 0.557 0.551 0.530 0.553 0.549 0.611 0.545 |
| tokio | 1.774 | 1.603 | 3.120 [2.594-3.499] | 1.970 1.722 1.796 1.627 1.858 1.752 1.706 1.854 1.603 1.871 1.887 1.662 |
| go | 2.220 | 2.138 | 4.048 [2.861-4.288] | 2.174 2.306 2.248 2.188 2.228 2.212 2.300 2.260 2.167 2.318 2.138 2.169 |

## fanout (ms)
| arm | median | min | vs rig paired median [range] | rounds |
|---|---:|---:|---|---|
| rig | 68.791 | 67.514 | 1 | 71.884 68.442 68.563 67.768 69.019 71.004 70.121 67.514 68.307 69.410 73.007 68.431 |
| tokio | 69.701 | 66.534 | 1.003 [0.933-1.062] | 71.730 72.043 67.705 66.534 69.522 69.879 69.284 71.681 70.377 70.783 68.083 69.427 |
| go | 69.027 | 66.142 | 1.008 [0.947-1.202] | 68.074 67.978 69.664 73.021 68.390 85.325 71.250 68.383 68.545 66.142 69.510 70.406 |

## yield (ms)
| arm | median | min | vs rig paired median [range] | rounds |
|---|---:|---:|---|---|
| rig | 6.121 | 6.018 | 1 | 6.210 6.515 6.213 6.099 6.127 6.037 6.092 6.388 6.115 7.599 6.018 6.079 |
| tokio | 43.798 | 40.865 | 6.958 [5.713-7.579] | 43.991 44.361 41.051 44.903 41.861 45.535 40.865 43.605 43.440 43.411 45.607 44.455 |
| go | 248.588 | 246.589 | 40.616 [32.997-41.416] | 246.589 248.477 251.446 247.612 250.470 248.667 251.200 248.508 248.464 250.737 249.239 247.843 |

## hog (ms)
| arm | median | min | vs rig paired median [range] | rounds |
|---|---:|---:|---|---|
| rig | 0.011 | 0.009 | 1 | 0.010 0.011 0.011 0.009 0.010 0.010 0.012 0.011 0.009 0.011 0.012 0.011 |
| tokio | 211.174 | 146.110 | 18693.934 [16940.246-23064.161] | 200.574 213.078 212.326 146.110 197.792 224.508 214.191 212.289 212.375 206.321 210.060 209.087 |
| go | 215.189 | 202.327 | 19147.819 [17820.786-25011.145] | 215.296 202.327 205.966 215.721 207.724 205.892 215.082 218.571 218.468 214.368 216.826 215.648 |

## produce (ms)
| arm | median | min | vs rig paired median [range] | rounds |
|---|---:|---:|---|---|
| rig | 5.242 | 5.196 | 1 | 5.226 5.212 5.196 5.198 5.197 5.266 5.258 5.221 5.292 5.293 5.342 5.305 |
| tokio | 6.263 | 5.787 | 1.193 [1.101-1.212] | 6.274 6.271 6.288 6.261 6.298 6.261 5.787 6.246 6.264 6.254 6.256 6.296 |
| go | 6.193 | 5.956 | 1.180 [1.143-1.196] | 6.181 5.956 6.216 6.207 6.109 6.211 6.207 6.205 6.243 6.098 6.171 6.131 |
| rayon | 5.323 | 5.284 | 1.014 [0.991-1.528] | 7.986 5.344 5.336 5.332 5.333 5.296 5.284 5.335 5.308 5.288 5.294 5.315 |

## whole process, median per run: real s, user s, sys s, vol csw, invol csw, cycles G, instr G, share of cycles on P-cores (prun)
| arm | real | user | sys | vcsw | icsw | cycles G | instr G | P-core share of cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| rig | 0.320 | 2.987 | 0.016 | 114 | 2709 | 10.51 | 11.34 | 51% |
| tokio | 0.390 | 3.272 | 0.020 | 1 | 6068 | 11.60 | 9.20 | 53% |
| go | 0.590 | 3.458 | 1.033 | 56 | 165176 | 15.95 | 18.78 | 56% |
| rayon | 0.000 | 0.016 | 0.019 | 1 | 1832 | 0.13 | 0.14 | 73% |
```

### A2. the fork record, Rig against Rayon (claim mt-1): raw/c1-fork.jsonl

```
# 23:24:41 start load { 6.59 6.30 4.98 } over50: none
# 23:24:43 end load { 6.14 6.21 4.96 } over50: none
## psum (ms)
| arm | median | min | vs rig paired median [range] | rounds |
|---|---:|---:|---|---|
| rig | 2.649 | 2.596 | 1 | 2.667 2.612 2.659 2.655 2.655 2.605 2.596 2.629 2.710 2.655 2.643 2.638 |
| rayon | 2.475 | 2.445 | 0.934 [0.925-0.961] | 2.492 2.510 2.471 2.478 2.484 2.480 2.464 2.445 2.507 2.471 2.452 2.464 |

## qsort (ms)
| arm | median | min | vs rig paired median [range] | rounds |
|---|---:|---:|---|---|
| rig | 58.372 | 54.789 | 1 | 58.651 58.734 58.093 58.065 56.499 64.741 55.577 54.789 61.372 58.747 59.148 55.788 |
| rayon | 53.953 | 52.141 | 0.938 [0.813-0.972] | 54.140 54.248 54.661 55.376 54.894 52.663 53.766 53.081 52.469 52.141 55.275 53.731 |

## whole process, median per run: real s, user s, sys s, vol csw, invol csw, cycles G, instr G, share of cycles on P-cores (prun)
| arm | real | user | sys | vcsw | icsw | cycles G | instr G | P-core share of cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| rig | 0.090 | 0.284 | 0.089 | 58 | 575 | 1.36 | 4.31 | 62% |
| rayon | 0.080 | 0.316 | 0.110 | 1 | 2401 | 1.52 | 3.75 | 58% |
```

### A3. bench/tasks by worker count, Rig (rN) and Tokio (tN) (claim mt-2): raw/c2-workers.jsonl

```
# 23:25:14 start load { 4.22 5.74 4.83 } over50: none
# 23:26:13 end load { 4.83 5.76 4.90 } over50: none
## spawn (ms)
| arm | median | min | vs r10 paired median [range] | rounds |
|---|---:|---:|---|---|
| r1 | 6.569 | 6.374 | 0.431 [0.403-0.476] | 6.374 6.556 6.582 6.442 6.640 6.679 |
| t1 | 8.255 | 7.973 | 0.549 [0.519-0.615] | 8.197 8.718 7.973 8.313 8.122 9.029 |
| r2 | 5.859 | 5.553 | 0.378 [0.356-0.446] | 5.887 5.775 5.831 6.037 6.124 5.553 |
| t2 | 16.769 | 15.620 | 1.114 [0.989-1.270] | 15.620 16.731 16.396 17.169 16.807 18.104 |
| r4 | 7.718 | 7.098 | 0.499 [0.455-0.581] | 7.742 7.864 7.695 7.850 7.516 7.098 |
| t4 | 18.458 | 18.137 | 1.213 [1.148-1.346] | 18.137 19.481 18.157 18.203 18.712 18.883 |
| r6 | 11.730 | 10.365 | 0.761 [0.665-1.076] | 12.123 11.499 11.960 14.551 11.048 10.365 |
| t6 | 18.989 | 18.325 | 1.222 [1.180-1.355] | 19.275 18.936 18.498 18.325 19.042 19.071 |
| r10 | 15.385 | 13.522 | 1 | 15.798 16.042 15.177 13.522 14.633 15.594 |
| t10 | 17.834 | 17.254 | 1.150 [1.092-1.336] | 17.254 17.941 17.658 18.068 18.331 17.727 |

## chain (ms)
| arm | median | min | vs r10 paired median [range] | rounds |
|---|---:|---:|---|---|
| r1 | 0.553 | 0.537 | 1.023 [0.968-1.032] | 0.537 0.549 0.558 0.555 0.551 0.561 |
| t1 | 0.807 | 0.794 | 1.492 [1.433-1.607] | 0.794 0.833 0.796 0.815 0.799 0.881 |
| r2 | 0.540 | 0.517 | 0.999 [0.932-1.009] | 0.517 0.540 0.545 0.539 0.540 0.548 |
| t2 | 1.826 | 1.449 | 3.367 [2.616-3.447] | 1.449 1.804 1.863 1.848 1.847 1.722 |
| r4 | 0.538 | 0.516 | 0.992 [0.932-1.032] | 0.516 0.531 0.539 0.541 0.565 0.538 |
| t4 | 1.660 | 1.615 | 3.052 [2.915-3.269] | 1.615 1.756 1.649 1.703 1.671 1.627 |
| r6 | 0.554 | 0.528 | 1.011 [0.977-1.035] | 0.560 0.543 0.528 0.559 0.552 0.556 |
| t6 | 1.800 | 1.679 | 3.267 [3.107-3.567] | 1.817 1.916 1.679 1.683 1.851 1.784 |
| r10 | 0.544 | 0.537 | 1 | 0.554 0.537 0.540 0.540 0.547 0.548 |
| t10 | 1.742 | 1.671 | 3.226 [3.015-3.387] | 1.671 1.783 1.746 1.739 1.854 1.734 |

## fanout (ms)
| arm | median | min | vs r10 paired median [range] | rounds |
|---|---:|---:|---|---|
| r1 | 487.091 | 485.567 | 7.039 [6.038-7.190] | 485.567 493.828 491.614 486.967 486.600 487.215 |
| t1 | 482.146 | 481.525 | 6.982 [5.993-7.630] | 481.903 524.074 481.525 482.387 481.906 483.907 |
| r2 | 249.605 | 249.241 | 3.611 [3.101-3.642] | 249.400 249.241 250.421 249.707 249.504 250.079 |
| t2 | 246.880 | 246.122 | 3.568 [3.132-3.602] | 251.845 247.384 246.122 247.164 246.523 246.596 |
| r4 | 133.497 | 133.121 | 1.925 [1.664-1.954] | 133.774 133.121 133.782 133.161 133.893 133.220 |
| t4 | 153.512 | 153.413 | 2.221 [1.908-2.243] | 153.413 153.540 153.484 153.921 153.673 153.414 |
| r6 | 100.550 | 97.548 | 1.424 [1.275-1.513] | 102.523 100.420 100.680 104.566 97.548 98.175 |
| t6 | 110.815 | 109.851 | 1.589 [1.432-1.620] | 115.152 110.952 110.677 110.100 111.004 109.851 |
| r10 | 69.198 | 68.506 | 1 | 80.415 68.687 70.696 69.093 68.506 69.304 |
| t10 | 71.118 | 67.311 | 1.000 [0.965-1.034] | 77.574 68.026 71.443 71.383 70.853 67.311 |

## yield (ms)
| arm | median | min | vs r10 paired median [range] | rounds |
|---|---:|---:|---|---|
| r1 | 56.515 | 53.616 | 9.210 [7.492-9.406] | 53.616 57.483 55.594 56.946 56.084 57.303 |
| t1 | 16.383 | 16.271 | 2.676 [2.312-2.723] | 16.545 16.633 16.282 16.485 16.278 16.271 |
| r2 | 24.939 | 24.553 | 4.081 [3.431-4.282] | 24.553 25.155 24.778 25.921 24.868 25.010 |
| t2 | 19.329 | 19.036 | 3.129 [2.683-3.230] | 19.201 19.066 19.036 19.552 19.543 19.456 |
| r4 | 11.249 | 10.990 | 1.849 [1.536-1.869] | 10.990 11.082 11.237 11.314 11.260 11.589 |
| t4 | 20.192 | 19.759 | 3.283 [2.777-3.367] | 19.876 20.682 19.950 19.759 20.499 20.434 |
| r6 | 8.670 | 8.503 | 1.401 [1.234-1.460] | 8.829 8.628 8.503 8.712 8.892 8.545 |
| t6 | 31.415 | 31.010 | 5.103 [4.494-5.260] | 32.164 31.010 31.968 31.091 31.161 31.669 |
| r10 | 6.121 | 6.054 | 1 | 7.157 6.153 6.078 6.054 6.089 6.223 |
| t10 | 44.135 | 42.501 | 7.148 [6.211-7.422] | 44.448 43.451 44.223 44.934 44.047 42.501 |

## hog (ms)
| arm | median | min | vs r10 paired median [range] | rounds |
|---|---:|---:|---|---|
| r1 | 0.009 | 0.008 | 0.890 [0.797-1.033] | 0.010 0.008 0.010 0.008 0.008 0.010 |
| t1 | 1663.733 | 1662.508 | 165332.330 [145650.893-171233.744] | 1664.254 1696.770 1665.117 1663.212 1662.508 1662.896 |
| r2 | 0.009 | 0.008 | 0.885 [0.766-1.090] | 0.010 0.008 0.010 0.008 0.011 0.009 |
| t2 | 851.142 | 849.574 | 84263.047 [74528.448-87691.051] | 855.851 853.256 849.823 849.574 851.392 850.891 |
| r4 | 0.008 | 0.008 | 0.812 [0.726-0.826] | 0.008 0.008 0.008 0.008 0.008 0.008 |
| t4 | 436.759 | 287.268 | 43144.264 [28254.922-45593.230] | 449.391 287.268 430.976 442.542 442.665 339.011 |
| r6 | 0.011 | 0.009 | 1.078 [0.880-1.273] | 0.013 0.011 0.011 0.011 0.009 0.012 |
| t6 | 313.887 | 199.677 | 30466.348 [19801.414-33423.791] | 199.677 318.612 328.809 297.191 324.512 309.163 |
| r10 | 0.010 | 0.010 | 1 | 0.010 0.010 0.010 0.010 0.010 0.011 |
| t10 | 209.926 | 147.315 | 20483.713 [14669.907-20845.775] | 210.209 211.559 209.643 147.315 198.358 211.470 |

## produce (ms)
| arm | median | min | vs r10 paired median [range] | rounds |
|---|---:|---:|---|---|
| r1 | 9.436 | 9.034 | 1.791 [1.690-1.954] | 9.213 9.444 9.034 9.880 9.428 10.434 |
| t1 | 4.833 | 4.822 | 0.917 [0.888-0.927] | 4.837 4.866 4.829 4.836 4.831 4.822 |
| r2 | 6.229 | 5.893 | 1.186 [1.122-1.231] | 6.114 6.289 6.412 6.169 5.893 6.574 |
| t2 | 4.971 | 4.944 | 0.940 [0.907-0.958] | 4.944 4.989 4.957 4.996 4.969 4.974 |
| r4 | 5.232 | 5.204 | 0.990 [0.962-0.998] | 5.241 5.224 5.249 5.204 5.223 5.242 |
| t4 | 6.256 | 6.226 | 1.182 [1.147-1.203] | 6.252 6.273 6.232 6.277 6.226 6.259 |
| r6 | 5.223 | 5.197 | 0.986 [0.956-1.001] | 5.212 5.223 5.197 5.223 5.240 5.263 |
| t6 | 6.264 | 5.363 | 1.181 [0.984-1.202] | 5.363 6.179 6.272 6.267 6.260 6.285 |
| r10 | 5.288 | 5.216 | 1 | 5.450 5.290 5.287 5.216 5.248 5.341 |
| t10 | 6.247 | 5.423 | 1.183 [0.995-1.195] | 5.423 6.322 6.285 6.210 6.180 6.283 |

## whole process, median per run: real s, user s, sys s, vol csw, invol csw, cycles G, instr G, share of cycles on P-cores (prun)
| arm | real | user | sys | vcsw | icsw | cycles G | instr G | P-core share of cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| r1 | 2.240 | 2.242 | 0.010 | 1 | 3052 | 10.23 | 11.32 | 100% |
| t1 | 2.180 | 2.179 | 0.003 | 1 | 67 | 10.01 | 8.77 | 100% |
| r2 | 1.150 | 2.297 | 0.007 | 57 | 1706 | 10.21 | 11.31 | 100% |
| t2 | 1.140 | 2.268 | 0.011 | 1 | 3009 | 10.20 | 8.83 | 100% |
| r4 | 0.610 | 2.412 | 0.011 | 110 | 1352 | 10.26 | 11.31 | 100% |
| t4 | 0.670 | 2.441 | 0.019 | 1 | 5664 | 10.46 | 8.95 | 100% |
| r6 | 0.460 | 2.689 | 0.011 | 179 | 1812 | 10.34 | 11.33 | 74% |
| t6 | 0.510 | 2.770 | 0.020 | 1 | 5718 | 10.83 | 9.02 | 77% |
| r10 | 0.325 | 2.996 | 0.017 | 106 | 2856 | 10.54 | 11.35 | 51% |
| t10 | 0.390 | 3.269 | 0.020 | 1 | 6068 | 11.61 | 9.19 | 53% |
```

### A4. the fork record by worker count, Rig (rN) and Rayon (yN) (claim mt-2b): raw/c2b-fork-workers.jsonl

```
# 23:28:39 start load { 3.82 5.35 4.89 } over50: none
# 23:28:49 end load { 3.34 5.17 4.83 } over50: none
## psum (ms)
| arm | median | min | vs r10 paired median [range] | rounds |
|---|---:|---:|---|---|
| r1 | 7.970 | 7.798 | 3.093 [3.048-3.280] | 8.151 8.229 7.956 7.798 7.912 7.826 7.984 8.405 |
| y1 | 5.869 | 5.695 | 2.301 [2.218-2.442] | 6.370 6.208 6.029 5.899 5.839 5.695 5.820 5.806 |
| r2 | 5.058 | 4.955 | 1.963 [1.934-2.022] | 5.276 5.167 5.140 5.059 5.030 4.997 5.058 4.955 |
| y2 | 4.188 | 4.013 | 1.609 [1.554-1.747] | 4.179 4.198 4.456 4.445 4.133 4.285 4.013 4.100 |
| r4 | 3.737 | 3.664 | 1.441 [1.416-1.482] | 3.751 3.750 3.761 3.724 3.792 3.708 3.693 3.664 |
| y4 | 3.398 | 3.363 | 1.318 [1.302-1.336] | 3.478 3.477 3.406 3.398 3.399 3.370 3.363 3.378 |
| r6 | 2.971 | 2.894 | 1.148 [1.119-1.206] | 2.977 2.964 3.006 2.999 2.953 3.097 2.894 2.911 |
| y6 | 2.608 | 2.579 | 1.013 [0.996-1.021] | 2.658 2.639 2.598 2.592 2.613 2.604 2.611 2.579 |
| r10 | 2.575 | 2.544 | 1 | 2.609 2.649 2.584 2.544 2.558 2.568 2.582 2.563 |
| y10 | 2.434 | 2.375 | 0.945 [0.925-0.971] | 2.418 2.524 2.391 2.394 2.375 2.495 2.453 2.449 |

## qsort (ms)
| arm | median | min | vs r10 paired median [range] | rounds |
|---|---:|---:|---|---|
| r1 | 191.630 | 188.606 | 3.320 [3.087-3.410] | 191.796 189.516 194.932 191.122 191.465 188.606 192.967 199.346 |
| y1 | 146.845 | 146.099 | 2.503 [2.351-2.655] | 146.099 146.284 147.473 146.829 147.360 146.861 146.527 147.424 |
| r2 | 121.276 | 117.009 | 2.067 [1.883-2.294] | 117.009 119.572 122.681 121.302 122.499 126.880 121.250 119.473 |
| y2 | 91.230 | 90.587 | 1.553 [1.468-1.656] | 91.215 90.587 91.389 91.117 90.781 91.577 91.245 91.249 |
| r4 | 82.033 | 79.753 | 1.391 [1.321-1.464] | 82.065 83.093 84.778 79.901 80.391 79.753 82.001 82.180 |
| y4 | 59.026 | 58.464 | 1.001 [0.950-1.089] | 59.028 58.996 58.464 59.118 59.025 60.236 58.694 59.336 |
| r6 | 73.268 | 69.166 | 1.258 [1.113-1.340] | 69.166 74.885 72.826 73.339 74.750 74.105 69.563 73.197 |
| y6 | 55.539 | 54.654 | 0.954 [0.894-1.001] | 55.524 54.654 55.554 55.892 56.039 55.341 56.667 55.333 |
| r10 | 58.705 | 55.308 | 1 | 62.139 59.518 57.891 57.636 57.369 55.308 59.776 59.984 |
| y10 | 54.700 | 52.611 | 0.931 [0.882-0.988] | 55.966 53.806 54.735 55.881 52.611 54.666 56.618 52.899 |

## whole process, median per run: real s, user s, sys s, vol csw, invol csw, cycles G, instr G, share of cycles on P-cores (prun)
| arm | real | user | sys | vcsw | icsw | cycles G | instr G | P-core share of cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| r1 | 0.230 | 0.182 | 0.051 | 1 | 1166 | 0.99 | 4.26 | 100% |
| y1 | 0.180 | 0.150 | 0.026 | 1 | 32 | 0.76 | 3.20 | 100% |
| r2 | 0.160 | 0.197 | 0.072 | 136 | 1048 | 1.12 | 4.43 | 100% |
| y2 | 0.120 | 0.173 | 0.030 | 1 | 56 | 0.87 | 3.31 | 100% |
| r4 | 0.120 | 0.218 | 0.096 | 327 | 880 | 1.33 | 4.53 | 99% |
| y4 | 0.090 | 0.199 | 0.039 | 1 | 182 | 1.01 | 3.39 | 100% |
| r6 | 0.110 | 0.242 | 0.127 | 637 | 1048 | 1.45 | 4.58 | 79% |
| y6 | 0.080 | 0.245 | 0.056 | 1 | 416 | 1.18 | 3.48 | 79% |
| r10 | 0.095 | 0.284 | 0.091 | 96 | 589 | 1.38 | 4.31 | 62% |
| y10 | 0.080 | 0.318 | 0.110 | 1 | 2384 | 1.53 | 3.74 | 58% |
```

### A5. probe round 1, bench/tasks (claim mt-3): raw/c3-probe.jsonl

```
# 23:29:20 start load { 2.41 4.77 4.70 } over50: none
# 23:30:09 end load { 5.21 5.12 4.83 } over50: none
## spawn (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 14.074 | 13.553 | 1 | 14.026 15.022 14.743 13.553 14.949 14.122 13.949 13.986 16.256 13.607 |
| aa | 17.398 | 11.996 | 1.189 [0.855-1.397] | 11.996 18.034 17.367 18.461 16.932 17.935 15.876 17.430 16.829 19.008 |
| awake4 | 6.950 | 6.582 | 0.481 [0.429-0.571] | 8.013 7.072 6.922 7.396 6.855 6.582 6.845 7.125 6.977 6.743 |
| awake2 | 5.635 | 5.370 | 0.393 [0.345-0.421] | 5.370 5.612 5.611 5.610 5.705 5.694 5.659 5.682 5.608 5.726 |
| backlog2 | 13.795 | 12.374 | 0.996 [0.839-1.119] | 12.991 13.608 12.374 13.610 13.713 14.681 15.602 14.046 16.067 13.876 |
| backlog8 | 11.530 | 10.140 | 0.780 [0.712-1.011] | 11.898 11.351 12.675 13.558 10.648 10.259 14.107 11.242 11.709 10.140 |
| chain4 | 15.927 | 15.370 | 1.130 [0.957-1.225] | 17.116 16.361 15.370 15.724 15.817 15.736 16.120 16.037 15.551 16.676 |
| spread4 | 17.110 | 16.117 | 1.169 [1.106-1.329] | 17.492 16.950 16.306 17.269 16.529 16.744 18.534 16.117 18.191 17.611 |
| qosui | 17.048 | 15.260 | 1.180 [1.049-1.318] | 18.485 15.752 17.390 17.540 16.035 17.001 17.094 15.260 17.190 16.066 |
| spinp20 | 9.800 | 8.806 | 0.688 [0.557-0.747] | 10.480 9.308 10.249 9.912 10.163 10.116 8.806 9.177 9.061 9.687 |
| spin20 | 19.354 | 18.680 | 1.355 [1.195-1.457] | 19.594 19.938 18.977 19.749 18.680 18.938 19.277 19.139 19.432 19.506 |

## chain (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 0.543 | 0.516 | 1 | 0.542 0.516 0.527 0.541 0.536 0.559 0.556 0.549 0.545 0.816 |
| aa | 0.543 | 0.516 | 0.990 [0.696-1.449] | 0.785 0.516 0.521 0.526 0.531 0.552 0.546 0.569 0.541 0.568 |
| awake4 | 0.548 | 0.528 | 1.000 [0.674-1.051] | 0.531 0.528 0.554 0.543 0.542 0.550 0.550 0.547 0.550 0.550 |
| awake2 | 0.553 | 0.541 | 1.006 [0.701-1.091] | 0.547 0.557 0.575 0.548 0.565 0.541 0.558 0.546 0.544 0.572 |
| backlog2 | 0.539 | 0.518 | 0.987 [0.675-1.024] | 0.520 0.520 0.538 0.518 0.537 0.543 0.548 0.562 0.539 0.551 |
| backlog8 | 0.548 | 0.515 | 1.007 [0.671-1.024] | 0.515 0.521 0.526 0.546 0.549 0.554 0.565 0.560 0.548 0.547 |
| chain4 | 0.541 | 0.516 | 0.999 [0.666-1.014] | 0.523 0.516 0.526 0.519 0.540 0.548 0.560 0.552 0.553 0.543 |
| spread4 | 0.539 | 0.527 | 0.992 [0.694-1.030] | 0.527 0.532 0.532 0.536 0.551 0.549 0.535 0.548 0.541 0.566 |
| qosui | 0.543 | 0.533 | 0.986 [0.669-1.071] | 0.533 0.553 0.545 0.534 0.545 0.541 0.542 0.541 0.545 0.546 |
| spinp20 | 0.553 | 0.515 | 1.014 [0.676-1.041] | 0.515 0.531 0.549 0.558 0.554 0.557 0.560 0.551 0.556 0.552 |
| spin20 | 0.562 | 0.525 | 1.029 [0.685-1.091] | 0.525 0.532 0.575 0.566 0.563 0.561 0.559 0.564 0.562 0.559 |

## fanout (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 69.906 | 67.113 | 1 | 67.113 68.985 67.765 69.950 67.338 69.863 82.448 71.428 70.417 73.099 |
| aa | 68.778 | 67.163 | 0.987 [0.924-1.063] | 71.326 69.225 67.202 69.955 68.864 68.691 76.194 67.436 67.163 68.186 |
| awake4 | 111.840 | 106.148 | 1.600 [1.355-1.702] | 114.197 113.946 111.649 111.841 113.864 111.840 111.683 113.750 106.148 109.799 |
| awake2 | 202.189 | 151.415 | 2.839 [2.249-3.564] | 191.400 198.300 156.727 249.284 151.415 206.103 206.078 206.339 188.750 206.612 |
| backlog2 | 78.443 | 76.728 | 1.133 [0.944-1.181] | 78.565 78.677 80.015 77.943 77.843 76.728 77.810 81.126 79.597 78.321 |
| backlog8 | 79.082 | 76.642 | 1.149 [0.947-1.693] | 77.953 110.943 79.045 79.120 113.977 76.642 78.091 76.703 94.502 83.078 |
| chain4 | 70.972 | 67.297 | 1.007 [0.868-1.070] | 71.825 70.388 67.297 68.674 69.177 72.339 71.555 73.291 69.093 71.816 |
| spread4 | 68.774 | 66.148 | 0.970 [0.880-1.053] | 70.656 66.148 69.406 72.425 68.484 66.915 72.550 68.566 68.966 68.582 |
| qosui | 69.308 | 66.457 | 0.997 [0.806-1.040] | 69.361 71.772 69.255 68.975 69.737 68.718 66.457 68.690 71.037 69.510 |
| spinp20 | 69.579 | 67.440 | 1.004 [0.822-1.068] | 70.236 73.695 71.426 71.656 69.941 67.440 67.809 67.785 69.211 69.216 |
| spin20 | 68.870 | 66.791 | 0.972 [0.812-1.048] | 68.309 69.716 69.547 67.989 70.545 66.791 66.931 69.430 67.505 69.941 |

## yield (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 6.130 | 5.962 | 1 | 6.387 6.077 6.070 6.201 6.166 6.130 5.962 6.071 6.130 6.530 |
| aa | 6.310 | 6.149 | 1.039 [0.946-1.488] | 6.149 6.330 6.290 9.227 7.444 6.269 6.747 6.172 6.627 6.175 |
| awake4 | 12.895 | 12.600 | 2.105 [1.973-2.167] | 12.600 12.896 12.977 13.046 12.840 13.019 12.920 12.790 12.795 12.894 |
| awake2 | 28.412 | 27.655 | 4.637 [4.304-4.819] | 29.591 28.794 28.348 27.655 28.615 28.476 28.732 27.909 28.303 28.104 |
| backlog2 | 6.317 | 6.112 | 1.038 [0.964-1.140] | 6.905 6.315 6.297 6.194 6.508 6.990 6.112 6.487 6.319 6.294 |
| backlog8 | 11.926 | 9.385 | 1.948 [1.509-2.486] | 9.641 12.091 14.373 13.797 11.761 9.521 14.822 9.385 12.652 10.394 |
| chain4 | 6.479 | 6.208 | 1.048 [0.981-1.292] | 6.263 6.943 6.398 6.514 6.444 6.224 7.704 6.208 7.294 6.569 |
| spread4 | 6.336 | 6.058 | 1.028 [0.928-1.221] | 6.363 6.526 6.271 6.247 6.310 6.241 7.282 6.618 7.016 6.058 |
| qosui | 6.350 | 6.180 | 1.038 [0.946-1.219] | 6.654 6.819 6.235 6.360 7.519 6.272 6.207 6.490 6.340 6.180 |
| spinp20 | 6.585 | 6.336 | 1.086 [1.002-1.375] | 6.398 6.433 8.345 6.336 6.650 6.735 6.519 7.913 6.498 7.526 |
| spin20 | 7.072 | 6.264 | 1.161 [1.000-1.309] | 6.385 7.026 7.118 7.233 6.264 7.346 7.192 7.949 6.759 7.009 |

## hog (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 0.012 | 0.011 | 1 | 0.011 0.011 0.011 0.012 0.012 0.012 0.012 0.011 0.012 0.015 |
| aa | 0.011 | 0.008 | 0.852 [0.661-1.254] | 0.012 0.009 0.010 0.009 0.011 0.012 0.010 0.014 0.008 0.011 |
| awake4 | 0.010 | 0.009 | 0.841 [0.616-0.876] | 0.010 0.010 0.010 0.010 0.010 0.009 0.009 0.010 0.010 0.009 |
| awake2 | 0.009 | 0.009 | 0.805 [0.608-0.926] | 0.010 0.009 0.009 0.011 0.009 0.010 0.009 0.010 0.009 0.009 |
| backlog2 | 0.011 | 0.010 | 0.964 [0.699-1.223] | 0.010 0.012 0.011 0.012 0.012 0.011 0.014 0.010 0.011 0.011 |
| backlog8 | 0.010 | 0.008 | 0.874 [0.641-1.102] | 0.009 0.011 0.010 0.013 0.012 0.010 0.008 0.009 0.011 0.010 |
| chain4 | 0.010 | 0.009 | 0.850 [0.581-2.081] | 0.010 0.023 0.010 0.010 0.010 0.010 0.011 0.009 0.012 0.009 |
| spread4 | 0.012 | 0.010 | 0.999 [0.666-1.193] | 0.012 0.013 0.010 0.013 0.010 0.012 0.012 0.010 0.014 0.010 |
| qosui | 0.011 | 0.008 | 0.904 [0.676-1.300] | 0.010 0.014 0.014 0.012 0.008 0.009 0.011 0.009 0.012 0.011 |
| spinp20 | 0.012 | 0.009 | 1.019 [0.685-1.841] | 0.010 0.021 0.015 0.014 0.011 0.009 0.021 0.021 0.009 0.010 |
| spin20 | 0.017 | 0.008 | 1.436 [0.698-2.311] | 0.008 0.026 0.010 0.018 0.018 0.016 0.017 0.017 0.021 0.017 |

## produce (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 5.262 | 5.210 | 1 | 5.362 5.271 5.222 5.260 5.210 5.230 5.233 5.263 5.265 5.269 |
| aa | 5.249 | 5.202 | 1.001 [0.982-1.007] | 5.267 5.251 5.237 5.210 5.209 5.248 5.202 5.291 5.302 5.277 |
| awake4 | 5.229 | 5.181 | 0.999 [0.974-1.005] | 5.221 5.181 5.246 5.262 5.221 5.240 5.221 5.288 5.237 5.203 |
| awake2 | 6.142 | 5.994 | 1.167 [1.138-1.181] | 6.103 6.156 6.166 6.070 6.135 6.088 5.994 6.153 6.162 6.149 |
| backlog2 | 6.100 | 5.714 | 1.164 [1.085-1.184] | 5.977 6.198 6.141 6.058 6.149 6.189 6.177 5.847 5.809 5.714 |
| backlog8 | 6.114 | 5.975 | 1.164 [1.123-1.211] | 6.024 6.121 6.089 6.108 6.250 6.331 6.225 6.001 6.192 5.975 |
| chain4 | 5.255 | 5.115 | 0.999 [0.978-1.013] | 5.298 5.155 5.115 5.288 5.191 5.218 5.239 5.334 5.271 5.306 |
| spread4 | 5.223 | 5.180 | 0.992 [0.973-1.032] | 5.219 5.223 5.388 5.208 5.238 5.223 5.180 5.198 5.232 5.324 |
| qosui | 5.277 | 5.166 | 1.003 [0.976-1.011] | 5.235 5.327 5.166 5.265 5.205 5.200 5.288 5.290 5.312 5.311 |
| spinp20 | 5.226 | 5.195 | 0.997 [0.982-1.014] | 5.265 5.195 5.219 5.230 5.219 5.202 5.299 5.222 5.287 5.345 |
| spin20 | 5.264 | 5.207 | 1.002 [0.987-1.010] | 5.293 5.228 5.266 5.264 5.264 5.276 5.255 5.250 5.207 5.281 |

## whole process, median per run: real s, user s, sys s, vol csw, invol csw, cycles G, instr G, share of cycles on P-cores (prun)
| arm | real | user | sys | vcsw | icsw | cycles G | instr G | P-core share of cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 0.320 | 2.987 | 0.016 | 131 | 2785 | 10.50 | 11.35 | 51% |
| aa | 0.330 | 3.022 | 0.016 | 120 | 2786 | 10.63 | 11.39 | 51% |
| awake4 | 0.600 | 2.478 | 0.016 | 102 | 2644 | 10.30 | 11.58 | 93% |
| awake2 | 1.130 | 2.346 | 0.010 | 42 | 2498 | 10.25 | 11.56 | 100% |
| backlog2 | 0.340 | 2.960 | 0.014 | 120 | 2721 | 10.47 | 11.39 | 52% |
| backlog8 | 0.455 | 2.790 | 0.014 | 80 | 2509 | 10.48 | 11.67 | 66% |
| chain4 | 0.330 | 3.002 | 0.016 | 102 | 2803 | 10.57 | 11.39 | 51% |
| spread4 | 0.330 | 3.018 | 0.016 | 121 | 2750 | 10.62 | 11.38 | 51% |
| qosui | 0.330 | 3.014 | 0.016 | 118 | 2749 | 10.61 | 11.38 | 51% |
| spinp20 | 0.320 | 2.947 | 0.019 | 113 | 3467 | 10.39 | 11.46 | 51% |
| spin20 | 0.330 | 3.079 | 0.010 | 108 | 1773 | 10.81 | 11.78 | 51% |
```

### A6. probe round 1, the fork record (claim mt-3): raw/c3-fork.jsonl

```
# 23:30:09 start load { 5.21 5.12 4.83 } over50: none
# 23:30:21 end load { 4.56 4.99 4.78 } over50: none
## psum (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 2.669 | 2.612 | 1 | 2.720 2.657 2.655 2.702 2.614 2.741 2.681 2.804 2.633 2.612 |
| aa | 2.656 | 2.566 | 1.002 [0.969-1.030] | 2.802 2.649 2.664 2.723 2.650 2.656 2.657 2.840 2.633 2.566 |
| awake4 | 2.645 | 2.615 | 0.998 [0.942-1.011] | 2.688 2.672 2.646 2.703 2.615 2.644 2.631 2.640 2.662 2.632 |
| backlog2 | 2.648 | 2.597 | 0.995 [0.950-1.044] | 2.642 2.646 2.698 2.821 2.650 2.655 2.642 2.663 2.637 2.597 |
| chain4 | 2.670 | 2.633 | 0.999 [0.964-1.024] | 2.689 2.663 2.646 2.639 2.678 2.644 2.727 2.702 2.689 2.633 |
| spread4 | 2.678 | 2.603 | 0.990 [0.957-1.163] | 2.674 2.682 2.702 2.639 3.040 2.629 2.631 2.683 2.707 2.603 |
| qosui | 2.650 | 2.624 | 0.994 [0.966-1.074] | 2.655 2.854 2.666 2.625 2.624 2.650 2.650 2.709 2.632 2.627 |
| spinp20 | 2.650 | 2.636 | 0.997 [0.940-1.026] | 2.651 2.653 2.641 2.774 2.648 2.653 2.648 2.636 2.647 2.681 |
| spin20 | 2.649 | 2.585 | 0.995 [0.944-1.035] | 2.672 2.751 2.650 2.683 2.609 2.644 2.742 2.648 2.632 2.585 |
| nostealnext | 2.709 | 2.619 | 1.009 [0.948-1.042] | 2.720 2.763 2.685 2.772 2.619 2.639 2.698 2.659 2.723 2.721 |
| rayon | 2.471 | 2.432 | 0.927 [0.869-0.972] | 2.511 2.454 2.476 2.517 2.432 2.506 2.441 2.438 2.559 2.466 |

## qsort (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 58.833 | 56.002 | 1 | 60.728 57.713 58.914 56.354 57.001 59.648 56.002 60.685 58.752 59.514 |
| aa | 59.548 | 57.225 | 1.016 [0.971-1.045] | 61.370 58.541 57.225 57.954 59.543 60.697 57.265 59.705 60.989 59.552 |
| awake4 | 69.892 | 66.087 | 1.200 [1.088-1.288] | 66.087 69.384 68.426 70.561 68.975 71.466 68.506 70.400 75.647 70.915 |
| backlog2 | 75.526 | 69.761 | 1.275 [1.194-1.414] | 74.463 78.593 74.635 74.217 80.611 71.224 69.761 76.736 78.917 76.418 |
| chain4 | 57.680 | 55.091 | 0.990 [0.923-1.101] | 56.082 63.539 55.091 59.353 56.825 56.909 59.360 60.750 57.799 57.561 |
| spread4 | 58.660 | 56.465 | 1.002 [0.949-1.069] | 57.633 59.534 59.929 60.260 58.700 56.890 58.289 59.901 56.465 58.621 |
| qosui | 57.411 | 56.651 | 0.990 [0.958-1.019] | 58.185 57.218 56.651 57.437 57.384 57.133 57.090 58.883 59.258 58.836 |
| spinp20 | 58.917 | 56.746 | 1.008 [0.960-1.057] | 58.310 58.878 56.746 59.586 58.957 59.440 57.566 59.181 60.231 57.660 |
| spin20 | 58.243 | 56.279 | 0.998 [0.944-1.042] | 58.773 57.491 57.284 58.114 58.907 56.279 58.371 60.626 57.560 59.988 |
| nostealnext | 62.899 | 60.146 | 1.061 [1.022-1.144] | 63.802 63.154 61.678 64.455 60.146 62.643 61.941 64.779 64.612 60.811 |
| rayon | 53.609 | 52.548 | 0.911 [0.870-0.978] | 53.803 52.557 53.678 55.086 53.133 53.541 54.660 52.771 56.187 52.548 |

## whole process, median per run: real s, user s, sys s, vol csw, invol csw, cycles G, instr G, share of cycles on P-cores (prun)
| arm | real | user | sys | vcsw | icsw | cycles G | instr G | P-core share of cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 0.090 | 0.283 | 0.091 | 54 | 538 | 1.37 | 4.31 | 62% |
| aa | 0.095 | 0.285 | 0.095 | 60 | 528 | 1.38 | 4.34 | 62% |
| awake4 | 0.110 | 0.251 | 0.102 | 665 | 890 | 1.37 | 4.46 | 78% |
| backlog2 | 0.110 | 0.276 | 0.121 | 611 | 1026 | 1.48 | 4.53 | 70% |
| chain4 | 0.090 | 0.281 | 0.090 | 60 | 511 | 1.34 | 4.30 | 63% |
| spread4 | 0.095 | 0.282 | 0.092 | 65 | 532 | 1.37 | 4.32 | 62% |
| qosui | 0.090 | 0.282 | 0.093 | 78 | 574 | 1.37 | 4.32 | 62% |
| spinp20 | 0.090 | 0.283 | 0.086 | 59 | 554 | 1.35 | 4.30 | 63% |
| spin20 | 0.090 | 0.285 | 0.092 | 86 | 605 | 1.38 | 4.32 | 62% |
| nostealnext | 0.100 | 0.282 | 0.094 | 108 | 788 | 1.37 | 4.29 | 61% |
| rayon | 0.080 | 0.313 | 0.107 | 1 | 2316 | 1.51 | 3.73 | 59% |
```

### A7. probe round 2, bench/tasks (claim mt-4): raw/c4-probe.jsonl

```
# 23:34:55 start load { 2.12 4.02 4.46 } over50: none
# 23:35:30 end load { 7.31 5.05 4.82 } over50: none
## spawn (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 13.934 | 12.229 | 1 | 12.229 16.043 14.633 14.098 12.279 15.831 13.542 14.794 13.770 13.678 |
| aa | 16.968 | 12.363 | 1.162 [1.011-1.436] | 12.363 18.549 17.511 16.810 17.631 17.126 16.086 17.273 15.727 15.171 |
| spinp5 | 9.926 | 8.844 | 0.712 [0.563-0.910] | 8.844 9.027 10.597 10.010 10.502 10.907 9.330 9.647 9.842 12.451 |
| spinp20 | 9.885 | 9.288 | 0.725 [0.591-0.800] | 9.547 9.486 10.208 9.288 9.824 9.926 9.968 10.935 9.843 10.737 |
| spinp50 | 18.015 | 15.343 | 1.297 [1.003-1.521] | 17.804 16.090 18.604 16.463 18.672 16.027 19.012 15.343 18.225 18.365 |
| sspinp20 | 8.914 | 7.582 | 0.664 [0.473-0.737] | 8.745 7.582 9.615 9.083 8.315 8.411 9.083 9.983 8.383 10.076 |
| sspin20 | 18.678 | 17.182 | 1.307 [1.177-1.610] | 18.603 18.884 17.961 19.043 19.768 21.056 17.182 17.986 18.754 17.557 |
| help10 | 21.896 | 12.167 | 1.544 [0.991-1.670] | 19.788 21.458 24.056 20.136 12.167 23.280 22.333 20.083 22.754 22.848 |
| help30 | 26.191 | 23.376 | 1.875 [1.459-2.080] | 23.376 23.402 26.844 27.163 25.538 28.032 24.883 23.422 27.922 28.188 |
| sspinp20h10 | 8.197 | 7.435 | 0.584 [0.463-0.709] | 8.346 7.435 7.825 8.084 8.707 8.210 8.184 8.767 8.660 7.873 |

## chain (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 0.552 | 0.540 | 1 | 0.847 0.551 0.541 0.779 0.550 0.540 0.554 0.552 0.564 0.552 |
| aa | 0.565 | 0.527 | 1.018 [0.697-1.047] | 0.775 0.527 0.554 0.543 0.565 0.566 0.579 0.558 0.566 0.577 |
| spinp5 | 0.552 | 0.523 | 0.994 [0.618-1.035] | 0.523 0.531 0.534 0.546 0.570 0.558 0.562 0.552 0.552 0.560 |
| spinp20 | 0.558 | 0.549 | 1.003 [0.662-1.060] | 0.561 0.549 0.573 0.574 0.558 0.558 0.558 0.551 0.556 0.559 |
| spinp50 | 0.562 | 0.535 | 1.010 [0.632-1.075] | 0.535 0.557 0.570 0.575 0.554 0.581 0.562 0.550 0.563 0.564 |
| sspinp20 | 0.636 | 0.599 | 1.136 [0.771-1.954] | 0.652 0.619 0.636 0.629 0.635 1.056 0.599 0.611 0.647 0.654 |
| sspin20 | 0.646 | 0.551 | 1.164 [0.771-1.546] | 0.653 0.551 0.660 0.626 0.646 0.642 0.646 0.854 0.655 0.641 |
| help10 | 0.547 | 0.515 | 0.989 [0.608-1.104] | 0.515 0.530 0.536 0.557 0.574 0.545 0.550 0.609 0.557 0.543 |
| help30 | 0.549 | 0.524 | 0.989 [0.629-1.045] | 0.533 0.530 0.524 0.536 0.567 0.548 0.565 0.555 0.549 0.577 |
| sspinp20h10 | 0.630 | 0.555 | 1.126 [0.768-1.220] | 0.650 0.621 0.612 0.625 0.651 0.555 0.642 0.573 0.635 0.673 |

## fanout (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 70.603 | 67.509 | 1 | 70.659 68.418 68.966 67.509 73.598 71.173 70.547 79.436 69.426 72.001 |
| aa | 69.648 | 67.921 | 1.003 [0.879-1.056] | 69.317 68.597 69.264 67.921 76.548 71.311 72.100 69.816 69.480 76.037 |
| spinp5 | 69.455 | 66.712 | 0.984 [0.871-1.154] | 67.307 66.712 67.590 68.216 71.830 82.103 69.718 69.192 71.780 74.313 |
| spinp20 | 70.223 | 68.892 | 1.009 [0.948-2.465] | 68.892 69.744 69.798 73.207 181.406 69.704 70.604 75.272 69.842 73.029 |
| spinp50 | 71.660 | 67.192 | 1.003 [0.913-1.279] | 70.188 67.192 71.192 68.188 73.299 68.747 72.128 72.564 88.818 75.169 |
| sspinp20 | 70.671 | 65.941 | 1.012 [0.896-1.073] | 66.631 68.690 66.650 66.369 65.941 72.653 75.718 83.013 72.925 76.848 |
| sspin20 | 70.976 | 65.706 | 1.004 [0.949-1.106] | 71.039 65.706 70.913 67.913 71.444 71.295 69.993 85.074 76.761 68.306 |
| help10 | 72.366 | 67.755 | 1.032 [0.959-1.142] | 67.755 68.449 68.143 76.151 78.203 79.908 68.162 90.751 75.094 69.638 |
| help30 | 71.617 | 69.930 | 1.038 [0.925-1.043] | 70.760 71.371 69.930 70.323 76.763 74.194 73.612 73.456 71.863 70.936 |
| sspinp20h10 | 71.050 | 67.120 | 1.009 [0.977-1.167] | 69.052 70.181 68.899 67.120 75.076 69.851 71.919 78.644 80.987 81.520 |

## yield (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 6.172 | 5.998 | 1 | 6.098 5.998 6.128 6.162 6.513 6.182 6.210 6.108 6.279 6.843 |
| aa | 6.456 | 6.261 | 1.048 [0.985-1.166] | 6.461 6.261 6.451 6.339 6.675 7.207 6.813 6.432 6.442 6.744 |
| spinp5 | 6.505 | 6.284 | 1.045 [0.988-1.191] | 6.411 6.441 6.284 6.569 6.586 7.361 6.693 6.343 6.330 6.763 |
| spinp20 | 6.936 | 6.192 | 1.084 [1.010-4.879] | 7.137 6.223 6.192 9.103 31.777 6.656 6.539 7.023 6.853 7.018 |
| spinp50 | 6.512 | 6.330 | 1.058 [1.025-1.614] | 6.338 6.330 6.482 6.515 6.929 6.509 6.860 9.859 6.437 7.856 |
| sspinp20 | 6.642 | 6.364 | 1.072 [0.998-1.362] | 6.761 6.586 6.528 6.364 6.499 6.411 6.698 8.318 7.120 7.213 |
| sspin20 | 6.686 | 6.436 | 1.093 [0.971-1.157] | 6.730 6.487 7.029 6.505 6.628 6.436 6.883 7.066 7.208 6.643 |
| help10 | 6.504 | 6.251 | 1.060 [0.955-1.576] | 6.352 6.469 6.251 9.714 7.051 6.321 6.335 6.853 6.935 6.539 |
| help30 | 6.384 | 6.260 | 1.041 [0.915-1.373] | 6.382 6.386 8.415 6.316 8.077 6.273 6.654 6.324 6.464 6.260 |
| sspinp20h10 | 6.831 | 6.339 | 1.073 [1.029-1.362] | 6.339 6.548 7.445 6.397 6.771 6.361 6.891 8.320 7.233 7.219 |

## hog (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 0.011 | 0.008 | 1 | 0.011 0.009 0.013 0.013 0.010 0.011 0.008 0.015 0.009 0.010 |
| aa | 0.011 | 0.008 | 1.064 [0.613-1.794] | 0.010 0.010 0.010 0.008 0.011 0.012 0.009 0.013 0.011 0.018 |
| spinp5 | 0.010 | 0.008 | 0.958 [0.566-1.527] | 0.012 0.008 0.010 0.010 0.009 0.012 0.011 0.008 0.014 0.010 |
| spinp20 | 0.012 | 0.009 | 1.363 [0.746-5.732] | 0.009 0.012 0.011 0.022 0.057 0.009 0.019 0.020 0.013 0.010 |
| spinp50 | 0.011 | 0.008 | 1.000 [0.680-2.825] | 0.010 0.012 0.009 0.010 0.011 0.011 0.023 0.018 0.008 0.011 |
| sspinp20 | 0.013 | 0.010 | 1.321 [0.763-2.969] | 0.010 0.014 0.011 0.012 0.027 0.023 0.024 0.011 0.010 0.025 |
| sspin20 | 0.018 | 0.009 | 1.891 [0.661-3.172] | 0.022 0.027 0.012 0.009 0.019 0.021 0.017 0.017 0.021 0.014 |
| help10 | 0.011 | 0.010 | 0.935 [0.783-1.456] | 0.010 0.012 0.011 0.011 0.013 0.010 0.011 0.011 0.010 0.010 |
| help30 | 0.010 | 0.009 | 0.948 [0.732-1.196] | 0.009 0.009 0.013 0.010 0.010 0.009 0.010 0.012 0.010 0.009 |
| sspinp20h10 | 0.014 | 0.010 | 1.219 [0.851-3.333] | 0.014 0.028 0.013 0.011 0.012 0.022 0.014 0.012 0.010 0.014 |

## produce (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 5.310 | 5.195 | 1 | 5.357 5.311 5.195 5.245 5.308 5.410 5.320 5.294 5.285 5.628 |
| aa | 5.290 | 5.219 | 0.998 [0.954-1.057] | 5.233 5.258 5.219 5.234 5.294 5.720 5.286 5.303 5.299 5.370 |
| spinp5 | 5.316 | 5.203 | 1.002 [0.976-1.009] | 5.226 5.249 5.218 5.203 5.332 5.326 5.319 5.343 5.312 5.680 |
| spinp20 | 5.298 | 5.250 | 0.997 [0.942-1.046] | 5.250 5.283 5.261 5.271 5.293 5.323 5.306 5.539 5.305 5.303 |
| spinp50 | 5.301 | 5.232 | 0.996 [0.942-1.024] | 5.250 5.232 5.306 5.333 5.266 5.301 5.315 5.422 5.285 5.301 |
| sspinp20 | 5.262 | 5.182 | 0.989 [0.937-1.016] | 5.251 5.182 5.188 5.197 5.238 5.278 5.300 5.377 5.272 5.274 |
| sspin20 | 5.280 | 5.202 | 0.996 [0.941-1.094] | 5.218 5.202 5.233 5.242 5.809 5.287 5.295 5.290 5.273 5.296 |
| help10 | 5.297 | 5.163 | 0.997 [0.943-1.029] | 5.278 5.290 5.163 5.234 5.464 5.315 5.320 5.304 5.285 5.305 |
| help30 | 5.303 | 5.240 | 0.996 [0.945-1.096] | 5.317 5.251 5.242 5.240 5.252 5.290 5.332 5.370 5.790 5.316 |
| sspinp20h10 | 5.268 | 5.220 | 0.993 [0.936-1.005] | 5.220 5.258 5.220 5.222 5.268 5.282 5.281 5.295 5.282 5.267 |

## whole process, median per run: real s, user s, sys s, vol csw, invol csw, cycles G, instr G, share of cycles on P-cores (prun)
| arm | real | user | sys | vcsw | icsw | cycles G | instr G | P-core share of cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 0.340 | 2.973 | 0.021 | 114 | 4355 | 10.52 | 11.36 | 51% |
| aa | 0.340 | 3.007 | 0.018 | 118 | 3454 | 10.61 | 11.40 | 51% |
| spinp5 | 0.330 | 2.937 | 0.022 | 112 | 4674 | 10.40 | 11.45 | 52% |
| spinp20 | 0.330 | 2.930 | 0.025 | 100 | 5105 | 10.40 | 11.49 | 52% |
| spinp50 | 0.330 | 2.981 | 0.027 | 108 | 5470 | 10.56 | 11.63 | 52% |
| sspinp20 | 0.320 | 2.935 | 0.021 | 102 | 4260 | 10.37 | 11.47 | 51% |
| sspin20 | 0.335 | 3.070 | 0.013 | 123 | 2744 | 10.79 | 11.82 | 51% |
| help10 | 0.340 | 3.043 | 0.016 | 122 | 3030 | 10.75 | 11.40 | 51% |
| help30 | 0.350 | 3.074 | 0.019 | 99 | 4042 | 10.87 | 11.42 | 51% |
| sspinp20h10 | 0.330 | 2.924 | 0.017 | 110 | 3518 | 10.33 | 11.45 | 51% |
```

### A8. probe round 2, the spawn harness, median of 20 samples a run (claim mt-4): raw/c4-spawn.jsonl

```
# 23:35:30 start load { 7.31 5.05 4.82 } over50: none
# 23:35:45 end load { 6.12 4.90 4.77 } over50: none
## spawn (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 9.977 | 9.115 | 1 | 9.115 9.555 9.603 10.296 10.417 10.017 11.061 9.937 10.095 9.907 |
| aa | 10.722 | 9.205 | 1.059 [0.952-1.226] | 9.577 9.205 10.911 9.877 11.111 11.426 10.534 12.184 11.547 10.222 |
| spinp20 | 9.577 | 9.366 | 0.956 [0.853-1.097] | 10.000 9.906 9.692 9.828 9.366 9.585 9.434 9.517 9.569 9.450 |
| sspinp20 | 10.311 | 9.620 | 1.052 [0.870-1.100] | 9.990 10.047 10.072 11.326 10.801 10.549 9.620 10.860 10.769 9.982 |
| help10 | 23.119 | 20.449 | 2.418 [1.990-2.521] | 22.733 20.449 23.505 22.046 21.426 24.971 22.006 23.734 24.720 24.979 |
| w2 | 7.782 | 7.647 | 0.782 [0.703-0.852] | 7.770 7.869 7.844 7.770 7.647 7.794 7.779 7.786 7.877 7.764 |

## whole process, median per run: real s, user s, sys s, vol csw, invol csw, cycles G, instr G, share of cycles on P-cores (prun)
| arm | real | user | sys | vcsw | icsw | cycles G | instr G | P-core share of cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 0.220 | 1.059 | 0.094 | 2 | 19160 | 4.31 | 2.36 | 74% |
| aa | 0.250 | 1.413 | 0.103 | 2 | 20040 | 5.62 | 2.45 | 68% |
| spinp20 | 0.190 | 1.103 | 0.216 | 8 | 38070 | 4.74 | 3.83 | 67% |
| sspinp20 | 0.210 | 1.181 | 0.232 | 7 | 40093 | 5.11 | 4.41 | 68% |
| help10 | 0.455 | 3.485 | 0.120 | 2 | 20690 | 12.79 | 2.61 | 55% |
| w2 | 0.150 | 0.280 | 0.007 | 1 | 2312 | 1.20 | 1.88 | 100% |
```

### A9. probe round 3, bench/tasks (claim mt-5): raw/c5-tasks.jsonl

```
# 23:51:23 start load { 5.58 6.65 5.80 } over50: none
# 23:52:08 end load { 5.07 6.41 5.75 } over50: none
## spawn (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 14.025 | 12.273 | 1 | 14.194 12.639 16.095 13.960 13.550 15.201 15.245 13.873 14.089 12.273 |
| aa | 15.999 | 14.118 | 1.104 [0.926-1.428] | 16.224 17.357 16.459 14.118 15.773 15.511 14.123 14.784 16.240 17.531 |
| sn0 | 15.807 | 14.324 | 1.120 [0.942-1.381] | 17.509 16.816 15.781 15.619 15.946 14.324 15.816 14.815 15.798 16.951 |
| sn1000 | 15.530 | 14.347 | 1.088 [0.941-1.335] | 15.149 15.901 15.858 15.546 14.560 15.408 14.347 17.098 15.513 16.389 |
| nosn | 14.097 | 11.506 | 1.038 [0.811-1.210] | 11.506 15.297 18.027 14.021 15.245 14.174 12.990 13.102 16.178 13.155 |
| ring | 17.344 | 16.172 | 1.236 [1.046-1.459] | 17.877 17.367 16.831 16.977 19.764 17.768 16.172 17.414 17.012 17.321 |
| nochain | 13.657 | 12.488 | 0.983 [0.810-1.075] | 13.879 12.488 13.044 13.875 14.396 13.438 14.191 13.405 15.047 13.197 |
| w2 | 6.160 | 5.996 | 0.444 [0.373-0.497] | 6.274 6.155 5.996 6.198 6.238 6.111 6.073 6.165 6.244 6.097 |
| w4 | 7.689 | 7.072 | 0.550 [0.450-0.641] | 7.668 7.072 7.237 7.640 7.553 8.258 7.709 8.017 7.788 7.863 |

## chain (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 0.562 | 0.548 | 1 | 0.563 0.551 0.581 0.556 0.586 0.550 0.561 0.548 0.565 0.573 |
| aa | 0.561 | 0.543 | 1.005 [0.926-1.045] | 0.572 0.576 0.557 0.562 0.543 0.556 0.560 0.568 0.554 0.563 |
| sn0 | 0.566 | 0.543 | 1.001 [0.942-1.084] | 0.568 0.572 0.568 0.603 0.552 0.565 0.573 0.543 0.554 0.556 |
| sn1000 | 0.568 | 0.545 | 1.009 [0.946-1.075] | 0.573 0.592 0.588 0.558 0.554 0.545 0.580 0.551 0.563 0.593 |
| nosn | 0.563 | 0.546 | 1.002 [0.952-1.387] | 0.781 0.568 0.585 0.555 0.558 0.569 0.548 0.588 0.546 0.554 |
| ring | 1.960 | 1.678 | 3.479 [2.991-4.023] | 1.919 1.940 1.979 1.996 2.050 1.853 1.678 1.896 2.273 2.174 |
| nochain | 0.562 | 0.544 | 1.010 [0.940-1.066] | 0.600 0.558 0.563 0.560 0.551 0.568 0.573 0.564 0.551 0.544 |
| w2 | 0.558 | 0.541 | 0.995 [0.953-1.039] | 0.541 0.549 0.554 0.549 0.584 0.556 0.583 0.562 0.561 0.561 |
| w4 | 0.552 | 0.535 | 0.988 [0.920-1.025] | 0.548 0.565 0.535 0.566 0.551 0.552 0.545 0.557 0.540 0.586 |

## fanout (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 71.267 | 68.187 | 1 | 70.937 76.458 68.187 70.187 71.597 76.390 75.388 69.685 78.435 68.766 |
| aa | 72.720 | 69.637 | 1.025 [0.905-1.110] | 69.637 72.428 75.705 73.011 71.448 79.844 82.334 70.306 71.018 73.549 |
| sn0 | 72.550 | 68.503 | 0.988 [0.934-1.124] | 68.503 71.386 76.625 70.324 71.484 73.854 73.713 73.615 74.485 70.852 |
| sn1000 | 70.359 | 69.075 | 1.001 [0.903-1.304] | 70.592 69.075 69.824 70.310 69.391 69.589 75.460 72.449 102.268 70.408 |
| nosn | 228.602 | 223.615 | 3.181 [2.867-3.374] | 223.615 227.486 228.437 226.156 229.834 228.766 229.604 228.827 224.907 232.013 |
| ring | 72.320 | 69.049 | 1.002 [0.904-1.091] | 72.917 72.282 69.720 70.313 71.719 69.049 74.554 72.358 75.392 75.025 |
| nochain | 72.121 | 70.984 | 1.012 [0.914-1.077] | 74.639 70.984 73.424 71.552 71.868 73.486 72.334 72.432 71.689 71.909 |
| w2 | 263.117 | 262.649 | 3.691 [3.355-3.852] | 263.311 263.077 262.649 263.037 262.715 262.889 263.649 265.113 263.156 263.913 |
| w4 | 136.753 | 135.298 | 1.914 [1.725-1.987] | 137.378 137.256 135.485 135.582 135.746 141.582 140.482 138.002 135.298 136.251 |

## yield (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 6.233 | 6.000 | 1 | 6.264 6.663 6.234 6.504 6.115 6.149 7.220 6.196 6.231 6.000 |
| aa | 6.669 | 6.296 | 1.077 [0.945-1.338] | 6.635 6.296 8.339 6.385 6.475 6.651 9.095 6.750 6.687 6.841 |
| sn0 | 6.477 | 6.267 | 1.025 [0.899-1.167] | 6.326 6.822 6.338 6.464 6.915 7.174 6.489 6.732 6.395 6.267 |
| sn1000 | 6.439 | 6.230 | 1.033 [0.930-1.665] | 6.728 6.230 6.338 6.488 6.360 7.348 6.716 6.358 10.377 6.389 |
| nosn | 6.556 | 6.322 | 1.052 [0.935-1.225] | 6.516 7.155 6.322 6.348 6.597 6.763 6.748 7.590 6.462 6.383 |
| ring | 6.531 | 6.335 | 1.028 [0.911-1.869] | 6.415 6.677 6.562 6.413 11.428 6.347 6.575 6.615 6.335 6.500 |
| nochain | 6.497 | 6.279 | 1.053 [0.892-1.134] | 6.806 6.279 6.855 6.317 6.718 6.455 6.440 6.539 6.400 6.804 |
| w2 | 24.293 | 23.806 | 3.905 [3.367-4.025] | 23.806 23.913 24.400 24.456 24.276 23.955 24.309 24.560 24.500 24.154 |
| w4 | 11.332 | 10.999 | 1.791 [1.695-2.120] | 11.240 11.291 10.999 11.452 11.136 13.038 12.405 11.532 11.138 11.373 |

## hog (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 0.011 | 0.008 | 1 | 0.010 0.014 0.010 0.008 0.014 0.010 0.012 0.009 0.012 0.012 |
| aa | 0.011 | 0.009 | 1.073 [0.727-1.294] | 0.010 0.012 0.009 0.009 0.010 0.012 0.015 0.012 0.010 0.015 |
| sn0 | 0.012 | 0.009 | 1.147 [0.707-1.371] | 0.012 0.010 0.012 0.012 0.012 0.014 0.009 0.010 0.011 0.014 |
| sn1000 | 0.012 | 0.009 | 1.109 [0.614-1.580] | 0.016 0.009 0.012 0.010 0.012 0.010 0.010 0.011 0.012 0.015 |
| nosn | 0.011 | 0.009 | 1.065 [0.721-1.500] | 0.013 0.013 0.010 0.010 0.010 0.012 0.011 0.014 0.013 0.009 |
| ring | 16.549 | 1.901 | 1320.357 [180.719-5564.439] | 1.901 44.610 10.508 34.300 22.590 31.338 8.021 52.862 2.131 10.257 |
| nochain | 0.013 | 0.012 | 1.162 [0.833-1.985] | 0.014 0.013 0.012 0.017 0.012 0.012 0.013 0.012 0.013 0.015 |
| w2 | 0.009 | 0.008 | 0.828 [0.610-1.000] | 0.009 0.009 0.009 0.008 0.009 0.009 0.010 0.009 0.009 0.009 |
| w4 | 0.009 | 0.008 | 0.853 [0.641-1.188] | 0.011 0.009 0.009 0.010 0.012 0.010 0.009 0.008 0.009 0.008 |

## produce (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 5.319 | 5.280 | 1 | 5.328 5.480 5.340 5.292 5.308 5.280 5.363 5.310 5.297 5.348 |
| aa | 5.362 | 5.315 | 1.006 [0.971-1.024] | 5.326 5.323 5.353 5.375 5.315 5.409 5.363 5.361 5.383 5.414 |
| sn0 | 5.279 | 5.256 | 0.993 [0.966-1.019] | 5.431 5.295 5.288 5.278 5.271 5.281 5.263 5.284 5.256 5.256 |
| sn1000 | 5.321 | 5.277 | 0.999 [0.970-1.021] | 5.329 5.313 5.277 5.285 5.289 5.389 5.377 5.333 5.360 5.311 |
| nosn | 5.885 | 5.744 | 1.109 [1.063-1.138] | 5.921 5.823 5.758 5.860 5.744 6.010 5.955 6.000 5.911 5.814 |
| ring | 5.861 | 5.797 | 1.107 [1.070-1.118] | 5.920 5.863 5.932 5.858 5.833 5.845 5.797 5.821 5.891 5.980 |
| nochain | 5.353 | 5.315 | 1.004 [0.976-1.019] | 5.431 5.351 5.421 5.355 5.323 5.347 5.375 5.315 5.322 5.358 |
| w2 | 5.774 | 5.661 | 1.080 [1.045-1.147] | 5.792 5.727 5.869 5.661 5.682 5.982 5.756 5.815 6.077 5.663 |
| w4 | 5.318 | 5.297 | 1.002 [0.986-1.012] | 5.393 5.406 5.322 5.302 5.324 5.314 5.313 5.297 5.303 5.369 |

## whole process, median per run: real s, user s, sys s, vol csw, invol csw, cycles G, instr G, share of cycles on P-cores (prun)
| arm | real | user | sys | vcsw | icsw | cycles G | instr G | P-core share of cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 0.335 | 2.966 | 0.023 | 112 | 4852 | 10.50 | 11.37 | 52% |
| aa | 0.340 | 3.001 | 0.022 | 113 | 4666 | 10.59 | 11.42 | 51% |
| sn0 | 0.340 | 2.994 | 0.022 | 96 | 4574 | 10.58 | 11.40 | 51% |
| sn1000 | 0.335 | 2.994 | 0.022 | 112 | 4558 | 10.57 | 11.41 | 51% |
| nosn | 0.500 | 2.942 | 0.038 | 122 | 9381 | 10.61 | 11.50 | 57% |
| ring | 0.340 | 3.008 | 0.025 | 100 | 5436 | 10.64 | 11.42 | 52% |
| nochain | 0.330 | 2.962 | 0.021 | 112 | 4353 | 10.49 | 11.41 | 52% |
| w2 | 1.210 | 2.398 | 0.016 | 50 | 2688 | 10.24 | 11.33 | 100% |
| w4 | 0.620 | 2.430 | 0.017 | 122 | 3220 | 10.29 | 11.34 | 98% |
```

### A10. probe round 3, the spawn harness (claim mt-5): raw/c5-spawn.jsonl

```
# 23:52:08 start load { 5.07 6.41 5.75 } over50: none
# 23:52:27 end load { 4.54 6.20 5.69 } over50: none
## spawn (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 9.661 | 8.848 | 1 | 9.138 9.852 9.643 8.848 9.790 9.896 10.118 9.541 9.680 9.066 |
| aa | 10.170 | 9.511 | 1.056 [0.941-1.148] | 9.511 10.355 9.693 9.751 10.050 10.491 9.521 10.290 10.321 10.404 |
| sn0 | 10.922 | 10.126 | 1.116 [1.034-1.234] | 10.231 10.955 10.903 10.284 10.126 10.941 11.135 11.451 10.700 11.190 |
| sn1000 | 9.452 | 8.296 | 0.987 [0.928-1.142] | 9.149 9.497 9.145 8.296 10.300 10.046 9.392 10.899 9.407 10.277 |
| nosn | 9.915 | 9.340 | 1.043 [0.950-1.153] | 10.538 10.051 10.342 9.429 9.340 9.397 9.662 10.482 9.779 10.336 |
| ring | 10.555 | 9.884 | 1.086 [0.999-1.263] | 11.400 10.696 10.339 10.415 9.950 9.884 10.984 11.121 10.131 11.447 |
| nochain | 9.550 | 8.668 | 0.990 [0.876-1.075] | 8.764 10.465 10.367 9.031 9.791 8.668 9.906 10.035 9.310 8.777 |
| w2 | 7.811 | 7.653 | 0.808 [0.776-0.886] | 7.653 7.864 7.866 7.841 7.780 7.875 7.853 7.774 7.756 7.705 |
| w4 | 7.357 | 7.228 | 0.760 [0.725-0.855] | 7.313 7.435 7.343 7.561 7.491 7.371 7.331 7.228 7.256 7.473 |

## whole process, median per run: real s, user s, sys s, vol csw, invol csw, cycles G, instr G, share of cycles on P-cores (prun)
| arm | real | user | sys | vcsw | icsw | cycles G | instr G | P-core share of cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 0.200 | 0.904 | 0.091 | 3 | 18836 | 3.80 | 2.35 | 77% |
| aa | 0.220 | 1.176 | 0.097 | 3 | 19460 | 4.77 | 2.45 | 71% |
| sn0 | 0.220 | 1.066 | 0.089 | 2 | 18400 | 4.39 | 2.32 | 74% |
| sn1000 | 0.220 | 1.192 | 0.099 | 2 | 19986 | 4.79 | 2.39 | 69% |
| nosn | 0.205 | 1.019 | 0.098 | 3 | 19706 | 4.18 | 2.34 | 71% |
| ring | 0.255 | 1.505 | 0.104 | 2 | 19771 | 5.87 | 2.32 | 63% |
| nochain | 0.200 | 0.900 | 0.079 | 2 | 17170 | 3.80 | 2.39 | 79% |
| w2 | 0.150 | 0.281 | 0.007 | 1 | 2408 | 1.20 | 1.88 | 100% |
| w4 | 0.150 | 0.468 | 0.039 | 6 | 12717 | 2.08 | 2.17 | 99% |
```

### A10b. probe round 4, RIG_P_PUSHCAP, bench/tasks (claim mt-6): raw/c6-tasks.jsonl

```
# 23:56:19 start load { 2.28 4.36 5.01 } over50: none
# 23:56:43 end load { 5.24 4.91 5.20 } over50: none
## spawn (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 13.999 | 12.980 | 1 | 14.858 13.410 13.234 14.649 14.315 14.149 13.954 14.043 12.980 13.438 |
| aa | 15.242 | 14.504 | 1.094 [0.990-1.213] | 15.228 16.228 14.646 14.504 16.890 15.000 15.255 15.363 15.743 14.689 |
| pc4 | 16.889 | 13.968 | 1.235 [0.954-1.427] | 15.608 19.135 18.291 13.968 17.309 14.171 16.347 18.067 16.822 16.956 |
| pc2 | 20.274 | 18.326 | 1.396 [1.350-1.599] | 20.064 18.326 21.159 20.641 19.783 19.131 20.714 19.197 20.610 20.484 |
| pc1 | 27.083 | 25.319 | 1.921 [1.786-2.139] | 26.608 27.001 25.319 26.168 27.361 27.296 25.821 27.404 27.769 27.165 |
| w4 | 7.643 | 7.335 | 0.544 [0.517-0.625] | 7.707 8.383 7.716 7.580 8.026 7.501 7.335 7.362 7.829 7.500 |

## chain (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 0.563 | 0.518 | 1 | 0.518 0.569 0.576 0.549 0.571 0.545 0.577 0.557 0.702 0.554 |
| aa | 0.568 | 0.559 | 1.004 [0.813-1.190] | 0.616 0.562 0.559 0.583 0.570 0.566 0.561 0.562 0.571 0.577 |
| pc4 | 0.557 | 0.542 | 0.981 [0.825-1.298] | 0.573 0.542 0.563 0.713 0.557 0.553 0.544 0.556 0.579 0.545 |
| pc2 | 0.559 | 0.547 | 1.000 [0.803-1.083] | 0.560 0.547 0.590 0.547 0.574 0.557 0.563 0.549 0.564 0.556 |
| pc1 | 0.568 | 0.546 | 1.038 [0.968-1.159] | 0.546 0.566 0.569 0.580 0.559 0.561 0.559 0.583 0.813 0.587 |
| w4 | 0.551 | 0.543 | 0.996 [0.776-1.053] | 0.545 0.575 0.557 0.556 0.585 0.560 0.547 0.546 0.545 0.543 |

## fanout (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 70.753 | 67.794 | 1 | 70.554 74.361 70.436 70.952 67.794 69.561 79.894 69.200 72.991 74.906 |
| aa | 72.574 | 68.356 | 1.010 [0.897-1.075] | 69.495 73.792 72.409 69.989 72.855 72.740 71.650 72.862 68.356 77.739 |
| pc4 | 75.044 | 68.990 | 1.042 [0.864-2.401] | 94.251 69.183 169.135 71.504 76.781 82.261 68.990 73.628 72.215 76.460 |
| pc2 | 71.045 | 68.001 | 1.009 [0.881-1.242] | 71.443 70.160 81.521 72.848 70.648 68.001 70.424 85.953 73.359 70.353 |
| pc1 | 71.725 | 68.863 | 0.997 [0.889-1.183] | 70.778 73.725 77.011 69.815 69.499 72.405 71.045 81.896 68.863 73.418 |
| w4 | 136.387 | 134.811 | 1.914 [1.707-2.034] | 134.811 138.936 136.414 136.044 137.882 139.381 136.359 135.773 136.005 136.960 |

## yield (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 6.539 | 6.074 | 1 | 6.142 6.730 6.074 6.475 6.643 6.474 6.663 6.262 6.602 6.726 |
| aa | 6.471 | 6.192 | 1.007 [0.929-1.111] | 6.572 7.474 6.512 6.406 6.687 6.430 6.192 6.314 6.420 6.805 |
| pc4 | 6.564 | 6.075 | 1.032 [0.903-1.130] | 6.607 6.075 6.317 6.632 6.986 6.505 7.147 6.329 6.521 7.598 |
| pc2 | 6.751 | 6.309 | 1.041 [0.939-1.156] | 6.737 6.844 6.589 6.765 6.650 6.772 6.309 7.238 6.852 6.317 |
| pc1 | 6.711 | 6.430 | 1.043 [0.956-1.128] | 6.448 7.122 6.850 6.752 6.546 6.986 6.768 6.527 6.669 6.430 |
| w4 | 11.247 | 11.044 | 1.726 [1.673-1.875] | 11.156 11.589 11.391 11.203 11.283 11.212 11.146 11.379 11.044 11.351 |

## hog (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 0.012 | 0.009 | 1 | 0.009 0.012 0.012 0.018 0.010 0.011 0.011 0.010 0.015 0.015 |
| aa | 0.011 | 0.009 | 1.010 [0.709-1.349] | 0.009 0.012 0.010 0.014 0.011 0.014 0.011 0.013 0.011 0.015 |
| pc4 | 0.010 | 0.008 | 0.903 [0.452-1.240] | 0.011 0.012 0.011 0.008 0.008 0.012 0.013 0.009 0.009 0.010 |
| pc2 | 0.010 | 0.009 | 0.901 [0.593-1.228] | 0.010 0.011 0.009 0.011 0.009 0.010 0.014 0.010 0.011 0.009 |
| pc1 | 0.011 | 0.010 | 0.988 [0.607-1.245] | 0.011 0.012 0.010 0.011 0.011 0.011 0.011 0.010 0.014 0.011 |
| w4 | 0.009 | 0.008 | 0.820 [0.506-1.093] | 0.009 0.010 0.009 0.009 0.008 0.009 0.010 0.010 0.009 0.011 |

## produce (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 5.349 | 5.271 | 1 | 5.384 6.792 5.271 5.383 5.307 5.333 5.300 5.334 5.550 5.363 |
| aa | 5.309 | 5.263 | 0.992 [0.795-1.007] | 5.263 5.398 5.277 5.332 5.314 5.294 5.335 5.304 5.284 5.320 |
| pc4 | 5.320 | 5.291 | 0.998 [0.786-1.029] | 5.293 5.336 5.426 5.304 5.324 5.378 5.311 5.317 5.291 5.361 |
| pc2 | 5.338 | 5.299 | 0.999 [0.790-1.019] | 5.299 5.366 5.369 5.401 5.406 5.317 5.340 5.336 5.306 5.322 |
| pc1 | 5.353 | 5.290 | 0.997 [0.797-1.012] | 5.341 5.413 5.327 5.301 5.326 5.383 5.366 5.290 5.493 5.375 |
| w4 | 5.328 | 5.274 | 0.996 [0.784-1.010] | 5.334 5.322 5.274 5.374 5.359 5.309 5.342 5.315 5.338 5.288 |

## whole process, median per run: real s, user s, sys s, vol csw, invol csw, cycles G, instr G, share of cycles on P-cores (prun)
| arm | real | user | sys | vcsw | icsw | cycles G | instr G | P-core share of cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 0.335 | 2.973 | 0.022 | 119 | 4606 | 10.51 | 11.37 | 51% |
| aa | 0.340 | 2.986 | 0.023 | 104 | 4864 | 10.56 | 11.42 | 51% |
| pc4 | 0.340 | 3.003 | 0.022 | 102 | 4720 | 10.61 | 11.41 | 51% |
| pc2 | 0.345 | 3.035 | 0.021 | 102 | 4451 | 10.72 | 11.41 | 51% |
| pc1 | 0.350 | 3.081 | 0.023 | 112 | 4783 | 10.89 | 11.41 | 52% |
| w4 | 0.620 | 2.427 | 0.017 | 107 | 3352 | 10.28 | 11.34 | 98% |
```

### A10c. probe round 4, the spawn harness (claim mt-6): raw/c6-spawn.jsonl

```
# 23:56:43 start load { 5.24 4.91 5.20 } over50: none
# 23:57:00 end load { 5.19 4.92 5.19 } over50: none
## spawn (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 9.790 | 9.245 | 1 | 9.990 10.316 9.703 10.290 9.245 10.130 9.374 9.827 9.754 9.476 |
| aa | 10.321 | 9.193 | 1.039 [0.947-1.171] | 10.213 9.923 9.193 10.626 10.826 10.851 10.973 10.271 9.904 10.370 |
| pc4 | 10.350 | 9.680 | 1.080 [0.969-1.806] | 9.680 10.236 11.691 11.261 10.302 16.842 9.940 17.743 10.398 10.056 |
| pc2 | 11.782 | 10.134 | 1.259 [0.985-1.980] | 11.389 19.493 19.211 10.134 11.703 19.387 11.010 12.509 10.846 11.860 |
| pc1 | 26.240 | 23.443 | 2.624 [2.404-2.843] | 25.744 27.068 25.454 26.193 26.286 26.736 26.571 25.484 23.443 26.753 |
| w4 | 7.353 | 7.189 | 0.768 [0.698-0.827] | 8.261 7.200 7.459 7.309 7.411 7.285 7.189 7.268 7.609 7.396 |

## whole process, median per run: real s, user s, sys s, vol csw, invol csw, cycles G, instr G, share of cycles on P-cores (prun)
| arm | real | user | sys | vcsw | icsw | cycles G | instr G | P-core share of cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 0.205 | 0.954 | 0.093 | 2 | 19073 | 3.98 | 2.35 | 75% |
| aa | 0.230 | 1.168 | 0.099 | 2 | 19713 | 4.70 | 2.45 | 68% |
| pc4 | 0.235 | 1.374 | 0.090 | 2 | 17628 | 5.39 | 2.44 | 66% |
| pc2 | 0.260 | 1.471 | 0.088 | 2 | 17460 | 5.76 | 2.41 | 66% |
| pc1 | 0.510 | 3.686 | 0.125 | 1 | 21182 | 13.51 | 2.52 | 55% |
| w4 | 0.150 | 0.469 | 0.040 | 3 | 13111 | 2.08 | 2.18 | 98% |
```

### A11. PROOF, bench/tasks (claim mt-P1): raw/p1-tasks.jsonl

```
# 23:44:01 start load { 2.64 4.31 4.69 } over50: none
# 23:44:26 end load { 6.22 5.01 4.93 } over50: none
## spawn (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 13.801 | 12.120 | 1 | 12.131 18.274 13.409 14.713 14.915 13.572 13.512 14.133 14.215 14.271 14.215 12.938 12.774 13.784 13.819 12.120 |
| aa | 13.611 | 10.235 | 0.982 [0.669-1.120] | 10.235 12.225 13.880 13.522 13.975 14.098 13.166 12.947 14.146 14.114 13.437 13.766 13.653 15.010 13.075 13.570 |
| spin | 10.527 | 8.716 | 0.727 [0.676-0.942] | 11.422 12.348 9.344 9.940 12.164 12.178 10.546 10.113 10.508 9.823 10.167 10.687 8.716 9.782 10.598 11.083 |
| tokio | 17.680 | 17.031 | 1.255 [0.991-1.966] | 23.843 18.114 18.054 17.707 18.061 20.467 17.769 17.031 17.181 17.202 17.581 17.653 17.804 17.531 17.110 17.525 |

## chain (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 0.554 | 0.540 | 1 | 0.551 0.561 0.543 0.570 0.543 0.575 0.547 0.553 0.568 0.552 0.550 0.540 0.567 0.558 0.556 0.556 |
| aa | 0.551 | 0.543 | 0.991 [0.952-1.055] | 0.579 0.545 0.573 0.552 0.554 0.547 0.551 0.544 0.545 0.550 0.543 0.558 0.556 0.548 0.557 0.557 |
| spin | 0.552 | 0.543 | 0.995 [0.958-1.227] | 0.654 0.552 0.550 0.546 0.666 0.576 0.543 0.549 0.557 0.551 0.546 0.547 0.557 0.549 0.554 0.560 |
| tokio | 1.704 | 1.562 | 3.034 [2.847-4.157] | 2.292 1.598 1.562 1.700 1.737 1.709 1.673 1.751 1.832 1.672 1.653 1.740 1.724 1.637 1.725 1.631 |

## fanout (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 74.659 | 71.749 | 1 | 73.053 84.821 78.888 81.398 71.779 71.749 74.913 74.405 75.292 73.755 75.542 84.514 74.307 72.601 72.178 77.131 |
| aa | 73.572 | 71.214 | 0.987 [0.863-1.178] | 77.857 78.265 77.599 72.623 72.404 84.493 72.858 71.214 73.506 74.344 75.500 72.952 73.637 71.854 73.978 73.235 |
| spin | 75.582 | 70.879 | 0.981 [0.840-1.401] | 76.847 77.429 74.729 75.248 100.581 72.308 71.649 70.879 72.599 75.916 71.702 70.985 79.131 83.610 76.919 76.890 |
| tokio | 75.874 | 73.235 | 1.004 [0.887-1.118] | 81.647 75.246 76.944 75.907 75.842 75.004 77.560 74.521 74.476 73.933 75.924 78.546 78.315 77.032 74.037 73.235 |

## yield (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 6.574 | 6.192 | 1 | 6.754 6.669 7.879 6.736 6.192 6.390 6.750 6.611 6.212 6.286 6.404 7.989 6.270 6.619 6.536 6.480 |
| aa | 6.560 | 6.276 | 1.004 [0.818-1.492] | 7.085 6.833 6.835 6.276 6.809 6.320 6.615 6.523 9.265 6.373 6.790 6.531 6.435 6.414 6.589 6.475 |
| spin | 6.626 | 6.335 | 1.035 [0.793-1.423] | 6.623 6.971 6.709 6.542 8.809 6.618 6.368 6.996 6.620 6.529 6.629 6.335 6.664 6.597 6.708 6.894 |
| tokio | 43.615 | 41.938 | 6.619 [5.502-7.141] | 43.540 43.015 43.744 44.047 44.221 43.592 43.467 43.697 42.503 44.318 43.264 43.961 42.284 43.878 43.637 41.938 |

## hog (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 0.011 | 0.008 | 1 | 0.010 0.010 0.012 0.008 0.012 0.009 0.010 0.012 0.011 0.010 0.012 0.010 0.012 0.012 0.010 0.012 |
| aa | 0.011 | 0.008 | 1.002 [0.649-1.424] | 0.011 0.010 0.012 0.011 0.010 0.012 0.008 0.008 0.011 0.010 0.014 0.012 0.012 0.010 0.013 0.010 |
| spin | 0.010 | 0.008 | 0.940 [0.663-1.418] | 0.009 0.015 0.008 0.012 0.014 0.009 0.009 0.010 0.012 0.008 0.008 0.010 0.011 0.013 0.008 0.008 |
| tokio | 224.481 | 152.940 | 19623.081 [15358.476-32595.130] | 210.596 233.549 228.122 266.172 222.972 222.254 222.633 224.789 215.029 231.405 224.173 152.940 230.136 218.180 228.564 226.101 |

## produce (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 5.308 | 5.276 | 1 | 5.512 5.338 5.512 5.282 5.303 5.331 5.320 5.323 5.305 5.282 5.308 5.283 5.308 5.299 5.276 5.322 |
| aa | 5.312 | 5.239 | 1.000 [0.960-1.082] | 5.375 5.676 5.294 5.332 5.736 5.494 5.305 5.270 5.318 5.295 5.319 5.239 5.292 5.292 5.332 5.290 |
| spin | 5.336 | 5.263 | 1.004 [0.987-1.129] | 6.224 5.360 5.443 5.263 5.334 5.318 5.339 5.367 5.304 5.290 5.282 5.341 5.339 5.407 5.319 5.307 |
| tokio | 6.033 | 5.854 | 1.132 [1.088-1.173] | 6.061 5.995 5.999 6.054 6.217 6.254 5.854 6.107 5.984 6.068 5.939 6.112 6.024 6.042 5.952 5.973 |

## whole process, median per run: real s, user s, sys s, vol csw, invol csw, cycles G, instr G, share of cycles on P-cores (prun)
| arm | real | user | sys | vcsw | icsw | cycles G | instr G | P-core share of cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 0.350 | 2.956 | 0.030 | 108 | 6634 | 10.51 | 11.39 | 53% |
| aa | 0.350 | 2.946 | 0.029 | 94 | 6334 | 10.51 | 11.38 | 53% |
| spin | 0.350 | 2.923 | 0.030 | 98 | 6871 | 10.42 | 11.42 | 53% |
| tokio | 0.410 | 3.200 | 0.033 | 1 | 9656 | 11.52 | 9.22 | 55% |
```

### A12. PROOF, the spawn harness (claim mt-P1): raw/p1-spawn.jsonl

```
# 23:44:26 start load { 6.22 5.01 4.93 } over50: none
# 23:44:36 end load { 6.03 5.01 4.93 } over50: none
## spawn (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 9.165 | 8.922 | 1 | 9.566 9.584 9.374 9.662 9.165 8.922 9.050 9.113 9.080 9.004 9.371 9.874 9.822 9.004 9.106 |
| aa | 9.274 | 8.927 | 1.016 [0.933-1.072] | 9.426 9.008 9.366 9.832 9.821 9.081 9.274 9.368 9.430 8.964 9.030 10.519 9.162 8.927 9.256 |
| spin | 11.705 | 11.208 | 1.263 [1.141-1.363] | 11.517 11.781 11.329 11.958 11.857 11.852 11.564 11.988 11.470 12.272 11.705 11.849 11.208 11.538 11.500 |

## whole process, median per run: real s, user s, sys s, vol csw, invol csw, cycles G, instr G, share of cycles on P-cores (prun)
| arm | real | user | sys | vcsw | icsw | cycles G | instr G | P-core share of cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 0.190 | 0.873 | 0.092 | 4 | 19214 | 3.64 | 2.35 | 75% |
| aa | 0.190 | 0.860 | 0.091 | 4 | 18913 | 3.62 | 2.35 | 75% |
| spin | 0.240 | 1.384 | 0.193 | 12 | 35663 | 5.64 | 3.34 | 63% |
```

### A13. PROOF, the fork record (claim mt-P1): raw/p1-fork.jsonl

```
# 23:44:36 start load { 6.03 5.01 4.93 } over50: none
# 23:44:41 end load { 6.91 5.23 5.01 } over50: 88% Google Chrome Helper (Aperitif Renderer)
## psum (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 2.858 | 2.385 | 1 | 2.919 2.504 2.474 2.755 3.076 3.288 3.287 2.858 3.350 2.385 2.471 3.558 7.186 2.786 2.706 |
| aa | 2.752 | 2.394 | 0.999 [0.463-1.202] | 3.508 2.527 2.626 3.169 3.074 2.752 2.689 2.674 3.195 2.738 2.394 2.524 3.329 2.900 2.965 |
| spin | 2.805 | 2.381 | 0.998 [0.397-1.232] | 2.800 2.533 2.453 3.394 3.364 3.177 2.646 3.400 3.211 2.381 2.516 2.405 2.854 2.805 3.132 |

## qsort (ms)
| arm | median | min | vs main paired median [range] | rounds |
|---|---:|---:|---|---|
| main | 68.830 | 55.601 | 1 | 71.521 59.110 58.591 74.990 69.521 65.375 70.027 68.704 67.036 55.601 57.587 68.830 69.411 119.773 77.334 |
| aa | 66.834 | 57.511 | 1.015 [0.618-1.253] | 70.267 61.062 65.550 66.752 73.626 66.749 66.834 66.297 67.727 57.799 57.511 69.885 86.962 74.007 78.598 |
| spin | 65.991 | 56.562 | 0.979 [0.603-1.070] | 60.887 62.007 57.504 69.255 66.788 67.948 68.536 65.940 65.991 59.077 56.562 59.510 74.291 72.261 74.605 |

## whole process, median per run: real s, user s, sys s, vol csw, invol csw, cycles G, instr G, share of cycles on P-cores (prun)
| arm | real | user | sys | vcsw | icsw | cycles G | instr G | P-core share of cycles |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 0.110 | 0.322 | 0.089 | 58 | 1148 | 1.48 | 4.29 | 59% |
| aa | 0.100 | 0.320 | 0.089 | 58 | 1051 | 1.48 | 4.30 | 60% |
| spin | 0.100 | 0.317 | 0.085 | 43 | 1083 | 1.47 | 4.26 | 61% |
```

### A14. PROOF, bench/net (claim mt-P2): raw/p2-net.jsonl

```
# 2026-11-17 23:45:18 load { 4.72 4.88 4.89 } cpu_all 74% over20: 25.2% WindowServer
# 2026-11-17 23:46:40 load { 5.84 5.27 5.04 } cpu_all 45% over20: 21.8% WindowServer (end)
| row | main ms median (fastest) | aa ms median (fastest) | spin ms median (fastest) | tokio ms median (fastest) | aa / main [range] | spin / main [range] | tokio / main [range] |
|---|---:|---:|---:|---:|---|---|---|
| pingpong | 333.36 (319.63) | 335.25 (332.73) | 341.99 (339.83) | 330.63 (322.98) | 1.007 [0.926-1.188] | 1.025 [0.950-1.094] | 0.987 [0.912-1.390] |
| echo | 826.34 (791.93) | 819.89 (798.49) | 844.16 (809.93) | 621.90 (613.95) | 0.997 [0.975-1.035] | 1.019 [0.977-1.078] | 0.761 [0.741-0.932] |
| connect | 26.89 (25.98) | 26.59 (25.96) | 28.03 (26.78) | 33.00 (32.24) | 0.994 [0.720-1.045] | 1.056 [0.684-1.549] | 1.227 [0.822-1.404] |
- pingpong main: 319.63 333.74 333.69 332.91 335.43 360.18 322.29 334.35 332.19 333.36 332.88 333.30 330.91 334.52 337.25
- pingpong aa: 339.22 337.39 334.76 335.18 398.60 333.38 334.17 336.78 332.73 338.86 335.25 334.68 362.11 334.30 354.04
- pingpong spin: 344.32 341.72 341.20 342.10 341.22 341.99 343.91 342.74 340.61 339.83 341.30 354.60 361.88 341.51 350.24
- pingpong tokio: 335.89 325.07 331.79 323.31 330.34 328.46 350.83 331.84 461.83 371.26 322.98 330.63 326.65 325.62 330.86
- echo main: 826.34 791.93 831.53 812.90 810.62 828.74 833.12 822.63 834.83 820.92 828.23 829.06 814.02 813.14 831.07
- echo aa: 824.14 819.89 810.44 828.45 798.49 829.50 832.17 835.25 829.01 811.25 813.18 816.35 823.25 811.66 815.45
- echo spin: 822.45 854.08 853.01 840.86 820.95 809.93 849.33 865.76 847.56 851.28 885.64 844.16 830.21 810.67 840.43
- echo tokio: 672.92 619.58 620.30 620.16 624.36 626.78 638.04 620.70 777.87 616.46 613.95 621.90 625.70 619.08 632.42
- connect main: 26.96 26.12 26.04 26.49 25.98 27.96 26.89 39.91 26.11 26.31 27.28 27.03 30.35 26.47 39.43
- connect aa: 26.20 26.59 26.31 26.40 27.14 26.64 26.45 28.76 25.96 26.30 26.28 27.16 26.74 26.75 28.39
- connect spin: 27.61 28.03 28.08 27.97 26.78 27.87 30.17 27.30 40.44 27.98 30.06 28.03 28.84 29.86 28.89
- connect tokio: 32.27 32.24 32.62 33.15 33.94 33.35 33.00 32.81 36.68 32.87 33.48 33.00 33.40 32.79 33.30
```

### A15. PROOF, bench/http closed loop (claim mt-P3): raw/p3-closed.jsonl

```
# 2026-11-17 23:47:11 load { 4.74 5.04 4.96 } cpu_all 89% over20: none
# 2026-11-17 23:50:52 load { 8.60 7.25 5.97 } cpu_all 89% over20: 40.8% launchd; 29.5% WindowServer (end)
| arm | n | req/s median | range | best | p50 / p99 µs | /main paired [range] | server µs (user/sys) | server cores | cycles k | P % | csw | intwk | syscalls | busiest thread % | threads >5% | gen µs | gen cores | gen P % |
|---|---:|---:|---|---:|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 15 | 132773 | 131101-134838 | 134838 | 469 / 686 | 1.000 [1.000-1.000] | 16.3 (2.4/13.8) | 2.17 | 59.1 | 63 | 0.54 | 0.047 | 4.33 | 31 | 4 | 24.1 | 3.20 | 53 |
| aa | 15 | 132057 | 123584-138085 | 138085 | 475 / 679 | 0.995 [0.931-1.052] | 16.5 (2.5/14.0) | 2.13 | 59.2 | 62 | 0.56 | 0.051 | 4.41 | 30 | 4 | 24.1 | 3.17 | 53 |
| spin | 15 | 128332 | 125260-132234 | 132234 | 489 / 708 | 0.966 [0.936-0.993] | 18.9 (4.5/14.3) | 2.41 | 68.8 | 65 | 0.47 | 0.044 | 4.24 | 28 | 4 | 24.7 | 3.18 | 48 |
| hyper | 15 | 136515 | 129985-138413 | 138413 | 459 / 675 | 1.019 [0.979-1.044] | 16.2 (2.9/13.4) | 2.21 | 58.7 | 63 | 0.47 | 0.002 | 2.93 | 11 | 10 | 23.3 | 3.18 | 54 |

Every round (k req/s), in round order:
- main: 134.7 131.2 134.3 132.6 133.9 134.5 134.8 131.9 132.8 131.1 131.6 132.6 132.8 132.6 133.5
- aa: 134.4 138.1 128.7 134.9 133.3 132.1 134.5 132.0 130.2 126.4 126.6 131.4 123.6 134.5 136.5
- spin: 127.8 127.9 125.7 130.9 130.6 130.4 130.0 128.4 128.3 130.2 125.3 127.3 127.4 125.3 132.2
- hyper: 136.5 136.4 136.5 138.4 137.8 137.1 137.8 134.4 133.0 135.8 137.0 133.0 130.0 135.0 137.5
```

### A16. Rig's counters, the spawn harness 200 rounds under sample (claim mt-4): raw/prof-*.err

```
== w10
rig: worker 0: ran 2024842, pinned 0, stole 218437, slept 24729
rig: worker 1: ran 2019913, pinned 0, stole 226051, slept 25383
rig: worker 2: ran 2040230, pinned 0, stole 227066, slept 25320
rig: worker 3: ran 2035484, pinned 0, stole 222032, slept 25154
rig: worker 4: ran 2009051, pinned 0, stole 217998, slept 24674
rig: worker 5: ran 1973863, pinned 0, stole 216315, slept 24751
rig: worker 6: ran 2008214, pinned 0, stole 218547, slept 24645
rig: worker 7: ran 1988838, pinned 0, stole 217053, slept 24735
rig: worker 8: ran 1971700, pinned 0, stole 219759, slept 24922
rig: worker 9: ran 1966337, pinned 0, stole 215066, slept 24630
== w2
rig: worker 0: ran 10090649, pinned 0, stole 17019, slept 10046
rig: worker 1: ran 9986276, pinned 0, stole 16115, slept 10030
== sspinp20
rig: worker 0: ran 2321436, pinned 0, stole 619841, slept 41883
rig: worker 1: ran 2414454, pinned 0, stole 629953, slept 40063
rig: worker 2: ran 2179622, pinned 0, stole 575439, slept 46333
rig: worker 3: ran 2081775, pinned 0, stole 557292, slept 47884
rig: worker 4: ran 1960743, pinned 0, stole 521163, slept 50368
rig: worker 5: ran 1758197, pinned 0, stole 487212, slept 54193
rig: worker 6: ran 1760377, pinned 0, stole 493938, slept 55319
rig: worker 7: ran 1985631, pinned 0, stole 550082, slept 49843
rig: worker 8: ran 1752595, pinned 0, stole 486082, slept 54071
rig: worker 9: ran 1799333, pinned 0, stole 503611, slept 53355
```

### A17. sample, top of stack, the spawn harness (claim mt-4): raw/sample-*.txt

```
== w10
Sort by top of stack, same collapsed (when >= 5):
        kevent64  (in libsystem_kernel.dylib)        4431
        __ulock_wait2  (in libsystem_kernel.dylib)        700
        rig.sched.next  (in main-spawnlong)        608
        rig.sched.switchNaked  (in main-spawnlong)        310
        rig.sched.fiberStartNaked  (in main-spawnlong)        273
        rig.sched.search  (in main-spawnlong)        254
        rig.sched.spawnIn__func_397.Full.start  (in main-spawnlong)        144
        rig.sched.wakeIn  (in main-spawnlong)        132
        rig.sched.spawnApart__func_396  (in main-spawnlong)        102
        rig.sched.runFiber  (in main-spawnlong)        99
        rig.sched.me  (in main-spawnlong)        83
        mach_absolute_time  (in libsystem_kernel.dylib)        80
        _tlv_get_addr  (in libdyld.dylib)        74
        rig.sched.loop  (in main-spawnlong)        68
        rig.alloc.Heap.alloc  (in main-spawnlong)        63
== w2
Sort by top of stack, same collapsed (when >= 5):
        __ulock_wait2  (in libsystem_kernel.dylib)        1116
        rig.sched.fiberStartNaked  (in main-spawnlong)        523
        rig.sched.spawnApart__func_396  (in main-spawnlong)        198
        rig.sched.next  (in main-spawnlong)        194
        rig.sched.switchNaked  (in main-spawnlong)        186
        kevent64  (in libsystem_kernel.dylib)        179
        rig.sched.spawnIn__func_397.Full.start  (in main-spawnlong)        141
        rig.sched.runFiber  (in main-spawnlong)        120
        _tlv_get_addr  (in libdyld.dylib)        119
        rig.alloc.Heap.alloc  (in main-spawnlong)        110
        rig.runtime.inCode__func_359  (in main-spawnlong)        100
        rig.sched.me  (in main-spawnlong)        60
        rig.sched.wakeIn  (in main-spawnlong)        52
        rig.sched.Done.finishApart  (in main-spawnlong)        47
        rig.sched.currentOf  (in main-spawnlong)        37
== sspinp20
Sort by top of stack, same collapsed (when >= 5):
        kevent64  (in libsystem_kernel.dylib)        3676
        rig.sched.search  (in probe-spawnlong)        872
        __ulock_wait2  (in libsystem_kernel.dylib)        720
        rig.sched.switchNaked  (in probe-spawnlong)        427
        mach_absolute_time  (in libsystem_kernel.dylib)        361
        rig.sched.loop  (in probe-spawnlong)        356
        rig.sched.next  (in probe-spawnlong)        231
        rig.sched.wakeIn  (in probe-spawnlong)        219
        _tlv_get_addr  (in libdyld.dylib)        151
        rig.sched.spawnApart__func_399  (in probe-spawnlong)        134
        rig.sched.fiberStartNaked  (in probe-spawnlong)        119
        rig.sched.runFiber  (in probe-spawnlong)        105
        rig.sched.notify  (in probe-spawnlong)        95
        rig.sched.spawnIn__func_400.Full.start  (in probe-spawnlong)        86
        rig.sched.Done.finishApart  (in probe-spawnlong)        42
```
