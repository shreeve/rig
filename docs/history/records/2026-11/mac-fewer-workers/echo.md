# bench/net `echo` on the Mac: the ceiling, where the time goes, and the change that passes Tokio (2026-11-17)

Measured first; nothing is committed and no pull request is open. The scheduler's owner session builds
what this proves. Machine: Apple M5, 4 performance and 6 efficiency cores, macOS 27.2.1; Tokio 1.54.1
from `misc/tokio`, Rust 1.99.1, Go 1.27.3. The diagnosis ran on main 39830dcc9; the final boards
(section 6) on main f03ef5199, fast-forwarded into the worktree, whose `src/sched.zig` and bench/net are
the same as 39830dcc9's.

- Worktree, left in place: `/Users/shreeve/Data/Code/worktrees/rig/mac-echo` (branch `mac-echo`, at
  f03ef5199, no commit of its own). `src/sched.zig` holds the arm's diff, `bb/arm.patch`, with both
  switches off. Everything else is in its `bb/` folder (untracked): binaries, scripts, `raw/` (every
  run), the patches.
- A copy of the scripts, patches and raw runs: `/Users/shreeve/Data/Code/Claude/rig/rig/fable-review/mac-echo/`.
- Every timed or counted run held the Mac's claim (`tools/mac-claim`, 15 claims; one was
  stopped at its limit with a board unfinished, A6), every build ran through `tools/heavy`, `~/Data/Code/mumps-compare/.mac-quiet` was absent throughout; no
  pup, no burst, no `pkill`.
- **Scope.** This began as two rows, echo and bench/http's closed loop. Midway the closed loop went to
  another expert; what was already measured for it is kept in section 9, as found, and not taken
  further.

## The answer in short

**The change: on the Mac, every socket waits in one poller** (the arm `one`: one line in
`sched.registerIn`, worker 0's poller for every descriptor, as `http.serve`'s connections already share
their acceptor's). On main f03ef5199, plain builds, 15 interleaved rounds, the layout control beside:

| echo, µs a round trip | median | fastest | against main, paired [range] | against Tokio, paired [range] |
|---|---:|---:|---|---|
| main | 6.38 | 6.31 | 1 | 1.165 [1.142-1.233] |
| aa (the arm's source, switched off) | 6.39 | 6.30 | 1.004 [0.936-1.019] | 1.164 |
| **one** | **5.16** | 5.08 | 0.810 [0.748-0.909] | 0.938 [0.923-1.060] |
| **arm** (one, and no looks at other workers' pollers) | **4.95** | 4.84 | 0.771 [0.739-0.819] | 0.898 [0.874-0.984] |
| nl (no looks, alone) | 5.75 | 5.27 | 0.896 [0.824-0.930] | 1.046 |
| Tokio | 5.48 | 5.32 | 0.858 | 1 |
| Go | 5.96 | 5.82 | 0.932 | 1.085 |

`one` is 19% faster than main and 6% faster than Tokio (under Tokio in 14 of 15 rounds); `arm` is 23%
faster than main and 10% faster than Tokio (under it in all 15). Ping-pong and connect do not move
(one: 1.000 [0.898-1.089] and 0.971 [0.946-1.036] of main; the layout control 0.997 [0.879-1.043] and
0.993 [0.875-1.035]). bench/tasks: spawn, chain, fanout, yield, hog and produce
are within 4% of main at the median for `one` and `arm`, as the layout control is (section 6).

**Why.** The Zig ceiling, run again today: one thread 5.51 µs, three threads each owning whole
connections 3.80 µs (31% faster than Tokio's 5.53), ten threads 5.42 µs. It makes 2 reads, 2 writes and
0.02 to 1.5 waits a round trip, 4.0 to 5.5 calls. Rig's main makes 9.0 calls a round trip: the ceiling's
2 reads and 2 writes, and then 4.5 looks at pollers (2.8 µs each under this load), 0.25 waits and 0.26
kicks. Each connection's
socket sits in the poller of the worker that made it, so every worker is woken by its own sockets, all
ten stay in play (8.6 cores busy against Tokio's 5.1 on a machine with four performance cores: 44% of
its cycles run on them, and a read or write takes 8.5 µs against 2.1 µs at three workers), and each, as it goes to sleep, looks at every
other's poller. With one poller, one worker takes the events, 40 to 59 at a call, the others are woken
only for work, and a trip makes 4.5 calls (Tokio 5.4).

**What it is not.** The kick (a `kevent64` trigger wakes a thread as fast as a condition variable or
`__ulock_wake`: 5.0 µs each way of doing it), `settle_wait` and `brief_wait`, the 3 µs steal from a "run
next" slot, and waking a worker for a short ring: each within 0.5% of main, inside the A/A spread.

**What is left.** Both runtimes are fastest at three workers, 3.7 µs, and `one` with at most three
workers awake runs 3.8 µs: the row is bound by the Mac's four performance cores and the kernel's
loopback thread. A cap is this machine's shape, not a rule; section 8 says what a rule might be.

## 1. The row, measured again (on 39830dcc9)

How quiet the Mac was: each claim's own wait (all other processes under 150% of a core for 30 s), then
the load averages and every process over 20% of a core as each board began and ended, in each table's
first lines (appendix). `corespotlightd` held 65% of a core before the first claim and `mediaanalysisd`
35-92% during the confirm claims; no build ran inside any of these claims.

**bench/net** (the whole program, 15 rounds interleaved and rotated, 16:54-16:56, load 3.8; `rigB` is the
same executable, the A/A arm; µs a round trip or connection, median and fastest; every round in A1):

| row | Rig | Rig again (A/A) | Tokio | Go | Tokio / Rig, paired median [range] | A/A |
|---|---:|---:|---:|---:|---|---|
| echo | 6.36 (6.27) | 6.38 (6.26) | 5.45 (5.15) | 5.96 (5.80) | 0.854 [0.810-0.874] | 1.006 [0.973-1.085] |
| ping-pong | 15.63 (15.20) | 15.60 (14.55) | 15.04 (14.79) | 16.14 (15.57) | 0.962 [0.896-1.059] | 0.993 [0.930-1.094] |
| connect | 50.86 (49.71) | 51.15 (49.53) | 62.18 (60.96) | 61.64 (58.93) | 1.227 [1.132-1.321] | 0.998 [0.949-1.043] |

Echo: Rig is 17% slower a round trip than Tokio at the median (22% by the fastest runs) and 7% slower
than Go. The other session's 23% was 6.35 against 5.17 µs: Rig's echo is the same there and here (6.3-6.5
in all but three rounds of every board today), and Tokio's moves between 5.15 and 5.5 with the machine. Ping-pong
is 4% behind Tokio, inside the A/A range; connect is 18% faster than Tokio.


## 2. Echo: where the time goes

**By worker count** (5 rounds each, `RIG_WORKERS` and `TOKIO_WORKER_THREADS`; A4):

| workers | Rig µs | Rig CPU µs a trip | Rig cores | Tokio µs | Tokio CPU µs a trip | Tokio cores | Rig against Tokio |
|---:|---:|---:|---:|---:|---:|---:|---|
| 1 | 6.07 | 6.2 | 1.02 | 6.14 | 6.2 | 1.00 | 1% faster |
| 2 | 4.23 | 8.5 | 2.01 | 4.54 | 8.8 | 1.94 | 7% faster |
| 3 | 3.70 | 11.0 | 2.97 | 3.76 | 10.4 | 2.76 | 2% faster |
| 4 | 4.49 | 18.0 | 4.01 | 5.12 | 19.2 | 3.75 | 14% faster |
| 6 | 5.87 | 34.9 | 5.94 | 5.63 | 27.2 | 4.85 | 4% slower |
| 8 | 6.32 | 49.0 | 7.77 | 5.52 | 28.2 | 5.12 | 14% slower |
| 10 | 6.39 | 55.2 | 8.63 | 5.48 | 28.1 | 5.14 | 17% slower |

Both are fastest at three workers, 3.7 µs, and slower with every worker more: three workers and the
kernel's loopback thread fill the four performance cores. Past four, Tokio stops at about five busy
threads however many it has; Rig keeps every worker busy, and the CPU a trip grows ninefold from one
worker to ten for the same reads and writes. So the gap at ten workers is not what Rig's workers do for a
round trip, which at equal counts is level or better, but how many of them do it.

**Calls a round trip at ten workers**, by a library interposing libSystem's calls (`bb/src/count.c`, the
loopback record's `count.c` with each call timed and the process's cycles and P-core share added; two runs
each, A5). "µs each" is the wall time of the call, which for a call that does not block is its CPU
unless the thread is switched out:

| | Rig | Tokio |
|---|---:|---:|
| reads (of them told to wait) | 2.0 (0) | 3.0 (1.0) |
| writes | 2.0 | 2.0 |
| waits in a poller | 0.23-0.27 | 0.064 |
| looks at a poller (of them with events) | 4.5-4.7 (1.3-1.5) | 0.03 |
| kicks / condition-variable signals | 0.25 | 0.21 |
| condition-variable waits | | 0.21 |
| all calls | 9.0-9.2 | 5.5 |
| a read, µs each | 8.4 | 4.3 |
| a write, µs each | 8.7 | 6.4 |
| a look, µs each | 3.1 | 12 |
| a kick or signal, µs each | 3.3 | 1.2 |
| in reads and writes, µs a trip | 34.2 | 25.6 |
| in looks, µs a trip | 14.4 | 0.4 |
| in kicks or signals, µs a trip | 0.8 | 0.2 |
| user / system CPU, µs a trip | 6.3 / 48.4 | 2.2 / 26.5 |
| cycles / instructions a trip | 186k / 94k | 103k / 80k |
| cycles on performance cores | 43% | 59% |
| involuntary context switches a trip | 0.23-0.26 | 0.30 |
| Rig's counters a trip: fibers run / stolen / sleeps | 2.01 / 1.32 / 0.70 | |

Call by call against the loopback record's 11.6 to 6.1: the reads told to wait are gone (2.0 against
Tokio's 3.0), the kicks are down to Tokio's signals (0.25 against 0.21), and what is left of the
difference is the looks, 4.6 a trip against 0.03. A worker goes to sleep 0.70 times a trip, and each turn
of a sleep (0.87 a trip, the probe's count) looks at every poller no worker sleeps in, five or six of
them (`serviceAll`). Two in three find nothing. Since #1127 a look that finds nothing costs 0.16 µs on an
idle machine, but here each costs 3.1 µs: ten workers call `kevent64` on kqueues the kernel is posting
socket events to. A trip takes four times the cycles it takes at three workers (186k against 46k) for
1.3 times the instructions (94k against 71k), which is waiting, in the kernel and on slower cores, not
work. The looks are 14.4 of
Rig's 55 µs of CPU a trip, and they keep more workers awake, so more of the reads and writes run on
efficiency cores: 43% of Rig's cycles are on performance cores against Tokio's 59%, and a read or write
takes 8.4-8.7 µs against 2.1 at three workers (99% on performance cores).

The same counts at 6, 4, 3, 2 and 1 workers are in A5: at four workers or fewer Rig makes 4.1-5.4 calls
a trip to Tokio's 5.1, and its reads and writes cost what Tokio's do.

**By connections** (one round only: the claim's limit came first; A6): 10 connections 6.99 against 5.62
µs, 30 connections 6.48 against 5.42, 100 connections 6.36 against 5.50. The gap is wider with fewer
connections (24% at ten), where there is less work for the same ten workers.

**`sample`** (1 ms, 3 s; `bb/raw/sample-*.txt`) puts 74% of Rig's samples in `kevent64` and 79% of
Tokio's in the condition variable's wait, but it counts blocked threads with running ones, so it does not
split a wait from a look; the timed calls above do.

## 3. The Zig ceiling today

The loopback record's `ceiling.zig`, unchanged, built `-OReleaseFast -lc`, beside Rig's builds and
Tokio in one board (claim echo-final-ceiling, 18:43-18:44, load 4.0, 9 rounds interleaved and rotated;
`+` is "a short read drains", the form Rig's reads take; every round in A24):

| shape | µs a trip, median (fastest) | against Tokio, paired [range] | CPU µs a trip | cores |
|---|---:|---|---:|---:|
| one thread, reads until told to wait (`echo1`) | 5.82 (5.72) | 1.053 [1.034-1.124] | 5.8 | 1.00 |
| one thread (`echo1+`) | 5.51 (5.39) | 0.996 [0.964-1.090] | 5.5 | 1.00 |
| 2 threads, each owning 50 whole connections (`echoN+ 2`) | 4.15 (3.98) | 0.753 [0.705-0.904] | 8.2 | 1.98 |
| **3 threads** (`echoN+ 3`) | **3.80** (3.68) | 0.686 [0.665-0.727] | 10.5 | 2.75 |
| 4 threads | 4.76 (4.62) | 0.864 [0.830-0.899] | 18.4 | 3.85 |
| 5 threads | 5.05 (4.88) | 0.908 [0.869-1.075] | 20.0 | 3.93 |
| 10 threads | 5.42 (5.29) | 0.961 [0.936-1.386] | 21.8 | 4.04 |
| 1 client thread and 1 server thread (`echoS+ 1`) | 4.09 (4.02) | 0.740 [0.712-0.985] | 8.1 | 1.97 |
| 2 and 2 | 4.59 (4.55) | 0.828 [0.811-1.132] | 17.7 | 3.84 |
| 3 and 3 | 4.93 (4.78) | 0.895 [0.863-1.025] | 19.9 | 3.99 |
| Rig main | 6.42 (6.37) | 1.160 [1.132-1.197] | 50.5 | 7.94 |
| Rig `one` | 5.21 (5.10) | 0.945 [0.917-1.082] | 25.0 | 4.74 |
| Rig `arm` | 5.05 (4.87) | 0.909 [0.864-0.981] | 20.7 | 4.09 |
| Rig `arm`, `RIG_WORKERS=3` | 3.91 (3.77) | 0.705 [0.682-0.747] | 10.7 | 2.73 |
| Rig `arm`, `RIG_WORKERS=4` | 4.78 (4.46) | 0.868 [0.806-0.983] | 17.1 | 3.51 |
| Tokio | 5.53 (5.50) | 1 | 27.4 | 4.96 |
| Tokio, 3 threads | 4.05 (3.87) | 0.733 [0.701-0.812] | 11.1 | 2.76 |

The record's ceiling (2026-11-15) was fastest on two threads, 4.50 µs, 24% under Tokio's 5.85. Today the
best shape is three threads, 3.80 µs, 31% under Tokio's 5.53, and the two-thread shapes are 4.09-4.15.
More threads are slower in the ceiling as in the runtimes: four threads lose 25% to three, and ten
threads, the shape nearest ten workers, run 5.42 µs, Tokio's speed. So the ceiling is a number of
threads: three, with the kernel's loopback thread on the fourth performance core.

**Call by call** (one counted run each, A25; "µs each" is the call's wall time):

| a round trip | ceiling, 1 thread | ceiling, 3 threads | ceiling, 10 threads | Rig main | Rig `one` | Rig `arm` | Rig `arm`, 3 workers | Tokio |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| reads (told to wait) | 2.00 (0) | 1.98 (0) | 2.00 (0) | 2.00 (0) | 2.00 (0) | 2.00 (0) | 2.00 (0) | 3.00 (1.0) |
| writes | 2.00 | 1.98 | 2.00 | 2.00 | 2.00 | 2.00 | 2.00 | 2.00 |
| waits in a poller | 0.024 | 0.89 | 1.49 | 0.245 | 0.209 | 0.210 | 0.062 | 0.052 |
| looks at a poller (with events) | 0 | 0 | 0 | **4.52** (1.26) | 0.089 (0.081) | 0.072 (0.071) | 0.074 | 0.031 |
| kicks, or signals and condition waits | 0 | 0 | 0 | 0.26 | 0.19 | 0.21 | 0.06 | 0.175 and 0.175 |
| all calls | 4.03 | 4.85 | 5.49 | **9.04** | 4.49 | 4.50 | 4.20 | 5.43 |
| a read / a write, µs each | 1.35 / 1.38 | 2.50 / 2.61 | 5.10 / 5.11 | 8.42 / 8.66 | 5.24 / 5.38 | 4.50 / 4.62 | 2.32 / 2.40 | 4.27 / 6.36 |
| a look / a kick, µs each | | | | 2.79 / 3.12 | 8.5 / 1.70 | 7.6 / 1.64 | 7.9 / 0.79 | 12.6 / 1.26 |
| cycles / instructions | 23.6k / 60.3k | 42.8k / 63.0k | 81.6k / 74.9k | 173k / 93.2k | 89.2k / 73.2k | 76.7k / 73.1k | 43.4k / 67.9k | 98.0k / 79.0k |
| cycles on performance cores | 98% | 94% | 63% | 44% | 64% | 71% | 95% | 58% |
| threads that read or wrote | 1 | 3 | 10 | 10 | 10 | 10 | 3 | 10 |

What Rig's main does beyond the ceiling, call by call: the reads and writes are the ceiling's (2 and 2;
Tokio makes a third read to be told to wait); its waits are fewer than the three-thread ceiling's (0.25
against 0.89, since it takes several events a call); and it adds **4.5 looks** and 0.26 kicks. The looks
are 4.5 of the 5.0 calls between Rig's 9.04 and the one-thread ceiling's 4.03, and at 2.8 µs each they
are 12.6 µs of CPU a trip. With one poller they are gone (0.09), and Rig makes 4.5 calls, fewer than the three-thread ceiling
and one fewer than Tokio. At three workers the arm is the ceiling: 4.20 calls, 43.4k cycles a trip
against 42.8k, 3.91 µs against 3.80.

What is then left at ten workers is not a call. The same read costs 1.35 µs on one thread, 2.5 on three,
5.1 on ten in the ceiling, and 5.2 in Rig's `one` and 8.4 in Rig's main: the more threads take part, the
more of them run on efficiency cores (the share of cycles on performance cores falls from 98% to 63% in
the ceiling, and is 44% for Rig's main), and the more they wait on one another in the kernel. `one` cuts
the busy cores from 7.9 to 4.7 and `arm` to 4.1, where Tokio sits at 5.0, and that is the gain.

## 4. The probes (on 39830dcc9)

One probe build, `p1` (`bb/probe-p1.patch`), switched by environment variables read as the workers
start, with per-worker counters that `RIG_SCHED_STATS=1` prints (`rig: probe N: ...`). With no switch set
it is main: echo 0.999 [0.969-1.014] and 0.994 [0.969-1.006] of main, closed loop 1.012 [0.989-1.037].

| switch | what it does |
|---|---|
| `RIG_P_NOLOOKS=1` | `serviceAll` looks at its own worker's poller only (the watcher's too) |
| `RIG_P_NOLOOKS=2` (`p2`, `nl`) | the same, but the watcher's look each `watch_every` still takes every poller |
| `RIG_P_ONEPOLLER=1` | `registerIn` puts every descriptor in worker 0's poller |
| `RIG_P_MAXAWAKE=N` | `notify` wakes no sleeper while N workers are awake |
| `RIG_P_SPREAD=N` | `spread` wakes a worker only when the ring holds N fibers |
| `RIG_P_SETTLE=us`, `RIG_P_BRIEF=us` | `settle_wait` and `brief_wait` |
| `RIG_P_NOSTEALNEXT=1` | a searching worker takes nothing from another's "run next" slots |

**Echo** (7 rounds each, two claims, paired with main's plain build; A11, A12; A/A is the `p` arm above):

| arm | µs a trip | against main, paired [range] | CPU µs a trip | cores |
|---|---:|---|---:|---:|
| main | 6.36-6.40 | 1 | 54-55 | 8.6 |
| settle 0 / settle 50 with brief 200 | 6.34 / 6.34 | 0.995 [0.906-1.008] / 0.996 [0.965-1.011] | 54 | 8.5-8.6 |
| spread 4 / spread 999 | 6.35 / 6.38 | 0.998 / 1.003 | 54-55 | 8.6 |
| awake 2 / awake 4 (alone) | 6.31 / 6.34 | 0.995 / 1.000 | 50-51 | 7.9-8.1 |
| no steal from slots | 6.33 | 0.996 [0.940-1.003] | 54 | 8.5 |
| **no looks** | 5.72-5.78 | 0.895 [0.867-0.945], 0.909 [0.854-0.941] | 31 | 5.4 |
| no looks, awake 3 / awake 4 | 5.49 / 5.68 | 0.860 / 0.883 | 28-29 | 5.0-5.1 |
| no looks, spread 4 / settle 0 | 5.63 / 5.55 | 0.882 / 0.865 | 29 | 5.2 |
| **one poller** | 5.09 (4.76-5.30) | 0.774 [0.749-0.844] | 24.9 | 4.9 |
| **one poller, no looks** | 4.82 | 0.750 [0.732-0.767] | 19.2 | 4.0 |
| one poller, awake 2 / 3 / 4 | 4.26 / 3.82 / 4.77 | 0.670 / 0.598 / 0.750 | 9.9 / 11.6 / 19.3 | 2.3 / 3.0 / 4.0 |
| one poller, no looks, awake 3 / 4 | 3.93 / 4.72 | 0.615 / 0.739 | 10.4 / 16.5 | 2.6 / 3.5 |
| `RIG_WORKERS` 3 / 4 | 3.78 / 4.51 | 0.595 / 0.699 | 11.2 / 18.1 | 3.0 / 4.0 |
| Tokio / Tokio at 3 | 5.29-5.46 / 3.72 | 0.832-0.851 / 0.582 | 26-28 / 10.3 | 5.0-5.2 / 2.8 |

What the calls became (one counted run each, A14, A17):

| a trip | main | no looks | one poller | one poller, no looks | Tokio |
|---|---:|---:|---:|---:|---:|
| looks (with events) | 4.62 (1.51) | 1.77 (0.70) | 0.11 (0.09) | 0.07 (0.07) | 0.03 |
| waits | 0.19 | 0.89 | 0.24 | 0.21 | 0.064, and 0.21 on the condition |
| kicks | 0.22 | 0.40 | 0.21 | 0.21 | 0.21 signals |
| all calls | 9.0 | 7.1 | 4.6 | 4.5 | 5.5 |
| a read / a write, µs each | 8.65 / 8.92 | 5.34 / 5.54 | 5.34 / 5.49 | 4.13 / 4.26 | 4.27 / 6.38 |
| cycles | 187.5k | 109.7k | 93.5k | 73.7k | 102.9k |
| cycles on performance cores | 43% | 60% | 65% | 75% | 59% |
| fibers stolen / sleeps | 1.25 / 0.69 | 0.75 / 1.22 | 0.60 / 0.31 | 0.51 / 0.27 | |

Reading it:

- **The looks** are worth 9-11% of echo by themselves: without them a trip's CPU falls from 55 to 31 µs
  and the busy cores from 8.6 to 5.4, Tokio's figures.
- **One poller** is worth 23%: the events of all 200 sockets come to one worker, 59 to a look, the others
  are woken only for work and steal it, and a trip makes 4.5 calls to Tokio's 5.5. With the looks gone
  too, echo is 4.82 µs, 12% faster than Tokio.
- **The awake cap** takes one poller to 3.8-3.9 µs, the three-worker figure, but only with one poller
  (alone it does nothing: each worker is woken by its own sockets, not by `notify`), and its best value
  is this machine's shape, three workers beside the kernel's loopback thread on four performance cores.
- **Not the wake.** `bb/src/wl.c` (A10): a thread parked in `kevent64` and woken by an `EVFILT_USER`
  trigger, in `pthread_cond_wait` woken by a signal, and in `__ulock_wait` woken by `__ulock_wake`,
  3,000 wakes each, the waker 50 µs apart: the waker's call 375, 334 and 292 ns, and the sleeper running
  again 5.04, 5.04 and 4.92 µs later (500 µs apart: 5.88, 5.67, 5.63). A kick costs what Tokio's signal
  costs, and Rig makes as many (0.25 against 0.21 a trip).
- **Not `settle_wait` or `brief_wait`, the slot steal, or `spread`:** every one within 0.5% of main, inside
  the A/A range.

**The whole of bench/net** for the arms that moved echo (7 rounds, A13): ping-pong 15.66 (main), 15.63
(no looks), 15.53 (one poller), 15.76 (both); connect 51.54, 51.14, 51.51, 51.13. Level, A/A 0.997 and
1.003.

**Closed loop** (`p1`'s server, 6 rounds, paired with main's plain build, 166.6k; A15):

| arm | req/s | against main [range] | server µs a request |
|---|---:|---|---:|
| probe, no switch (A/A) | 168,567 | 1.012 [0.989-1.037] | 16.1 |
| **no looks** | 176,402 | 1.057 [1.025-1.079] | 13.3 |
| spread 2 / 4 / 8 / 999 | 169,485 / 173,223 / 174,386 / 171,886 | 1.011 / 1.045 / 1.040 [1.010-1.058] / 1.032 | 15.2 / 14.5 / 13.8 / 14.5 |
| awake 2 / 3 / 4 | 187,837 / 181,996 / 175,581 | 1.124 / 1.085 / 1.056 | 9.5 / 11.2 / 13.0 |
| no steal from slots | 168,438 | 1.001 [0.981-1.026] | 15.8 |
| hyper | 173,192 | 1.045 [0.990-1.071] | 15.1 |

## 5. The look rule confirmed as a plain build (on 39830dcc9)

`nl` is a build of its own (`bb/rig-nl`; `bb/probe-p2.patch` with `own_look_default` 2): no switch set, a
worker going to sleep looks at its own poller only, and the watcher's look each millisecond takes every
poller, as on main. `nl-off` is the same executable with the looks switched back on, which must read as
main does. 15 rounds each, interleaved and rotated, main twice.

**bench/net** (17:44-17:46, load 1.8; A16):

| row | main | main again | nl | nl, one poller | nl-off | Tokio | Go |
|---|---:|---:|---:|---:|---:|---:|---:|
| echo µs | 6.37 | 6.37 | **5.66** | **4.82** | 6.40 | 5.45 | 5.94 |
| against main [range] | 1 | 1.002 [0.987-1.009] | 0.888 [0.876-0.904] | 0.759 [0.729-0.764] | 1.001 [0.992-1.031] | 0.854 [0.818-0.864] | 0.934 |
| ping-pong µs | 15.55 | 15.48 | 15.43 | 15.48 | 15.47 | 14.99 | 16.16 |
| against main | 1 | 0.999 [0.908-1.018] | 1.003 [0.918-1.133] | 1.004 [0.904-1.078] | 0.995 | 0.967 | 1.039 |
| connect µs | 51.03 | 51.26 | 51.45 | 51.40 | 50.92 | 62.81 | 62.00 |
| against main | 1 | 1.001 [0.965-1.077] | 1.005 [0.949-1.050] | 0.997 [0.924-1.063] | 1.010 | 1.231 | 1.223 |

Echo with `nl` is 11.2% faster than main in every round (worst round 9.6%), 3.9% behind Tokio and 4.7%
ahead of Go; with one poller as well it is 24.1% faster than main and 11.6% faster than Tokio. Ping-pong
and connect do not move.

**bench/http, closed loop** (17:47-17:53, load 5.3, `mediaanalysisd` at 92% of a core by the end; A18):

| | main | main again | nl | nl-off | nl, spread 8 | hyper |
|---|---:|---:|---:|---:|---:|---:|
| req/s, median | 167,854 | 167,404 | **176,172** | 167,098 | 182,415 | 172,999 |
| best | 173,199 | 171,914 | 178,776 | 175,876 | 183,770 | 176,456 |
| against main [range] | 1 | 0.995 [0.939-1.027] | 1.048 [1.015-1.069] | 0.999 [0.972-1.041] | 1.085 [1.037-1.112] | 1.033 [1.010-1.068] |
| p50 / p99 µs | 375 / 573 | 377 / 576 | 357 / 538 | 377 / 572 | 343 / 537 | 364 / 568 |
| server µs a request | 16.25 | 16.6 | 13.3 | 16.4 | 11.7 | 15.15 |
| server cores | 2.74 | 2.78 | 2.35 | 2.75 | 2.13 | 2.62 |

`nl` serves 4.8% more than main, above it in all 15 rounds, and 1.8% more than hyper; a request makes
0.46-0.59 looks (its own worker's) where main makes 1.32, and costs 49-50k cycles where main's costs 57k
and hyper's 54k.

## 6. The arm on main f03ef5199: final boards

The arm is `bb/arm.patch`, 59 lines, two comptime switches, both `false` in the worktree:

- `arm_one`: `registerIn` takes worker 0's poller for every descriptor (one line).
- `arm_nl`: `serviceAll` looks at its own worker's poller only, unless the watcher calls it as it wakes
  each `watch_every` (the look rule of section 5).

Five whole builds of `bin/rig`, each with the bench programs built by it (`bb/buildfinal.sh`): `main`
(f03ef5199, the patch stashed), `aa` (the patch, both switches off: the layout control), `one`, `arm`
(both on), `nl` (the look rule alone).

**bench/net, the whole program** (claim echo-final-net, 18:34-18:37, load 2.4, 15 rounds interleaved and
rotated; µs, median (fastest); every round in A23):

| row | main | aa | one | arm | nl | Tokio | Go |
|---|---:|---:|---:|---:|---:|---:|---:|
| echo | 6.38 (6.31) | 6.39 (6.30) | **5.16** (5.08) | **4.95** (4.84) | 5.75 (5.27) | 5.48 (5.32) | 5.96 (5.82) |
| against main [range] | 1 | 1.004 [0.936-1.019] | 0.810 [0.748-0.909] | 0.771 [0.739-0.819] | 0.896 [0.824-0.930] | 0.858 [0.811-0.875] | 0.932 |
| ping-pong | 15.78 (15.30) | 15.71 (15.04) | 15.61 (14.66) | 15.66 (15.14) | 15.72 (15.00) | 15.17 (14.91) | 16.44 (15.49) |
| against main | 1 | 0.997 [0.879-1.043] | 1.000 [0.898-1.089] | 0.996 [0.888-1.083] | 0.997 [0.900-1.090] | 0.970 | 1.048 |
| connect | 52.14 (49.96) | 51.94 (46.03) | 51.22 (49.15) | 51.70 (49.26) | 52.23 (50.70) | 63.15 (56.94) | 62.99 (61.73) |
| against main | 1 | 0.993 [0.875-1.035] | 0.971 [0.946-1.036] | 0.995 [0.942-1.066] | 0.997 [0.959-1.055] | 1.214 | 1.204 |

Echo's rounds, in order (µs): main 6.38 6.85 6.38 6.37 6.47 6.44 6.32 6.31 6.36 6.38 6.36 6.33 6.47 6.39
6.39; aa 6.50 6.41 6.43 6.39 6.43 6.38 6.32 6.36 6.39 6.40 6.41 6.38 6.41 6.38 6.30; one 5.15 5.12 5.27
5.16 5.33 5.13 5.10 5.11 5.17 5.19 5.09 5.17 5.17 5.08 5.81; arm 4.88 5.06 4.90 4.97 4.95 5.03 4.90 4.89
4.84 4.89 4.84 4.95 4.98 5.24 5.16; nl 5.67 5.81 5.62 5.69 5.80 5.84 5.71 5.79 5.63 5.79 5.75 5.88 5.70
5.27 5.90; Tokio 5.58 5.55 5.48 5.53 5.47 5.48 5.48 5.47 5.45 5.53 5.42 5.47 5.55 5.32 5.48.

`one` passes Tokio by 6% (paired 0.938 [0.923-1.060], one round of 15 over it) and `arm` by 10% (0.898
[0.874-0.984], none over). Ping-pong and connect are inside the layout control's range for every arm.

**bench/tasks** (claim echo-final-tasks, 18:45, 15 rounds interleaved and rotated; Chrome held 48% of a core
as it began; ms a run, median (fastest); `chain` is the wake row, start one task and wait for it; every
round in A26):

| row | main | aa | one | arm | aa / main [range] | one / main [range] | arm / main [range] |
|---|---:|---:|---:|---:|---|---|---|
| spawn | 15.24 (12.32) | 15.68 (11.39) | 15.95 (10.62) | 15.77 (12.45) | 1.024 [0.917-1.175] | 1.020 [0.708-1.184] | 1.039 [0.769-1.231] |
| chain | 0.59 (0.57) | 0.58 (0.57) | 0.58 (0.57) | 0.58 (0.57) | 0.990 [0.855-1.032] | 1.001 [0.757-1.045] | 0.994 [0.924-1.020] |
| fanout | 72.42 (67.08) | 72.30 (67.66) | 72.03 (68.45) | 71.25 (66.61) | 1.029 [0.730-1.118] | 1.010 [0.713-1.193] | 0.975 [0.728-1.062] |
| yield | 6.29 (6.03) | 6.26 (5.96) | 6.15 (5.96) | 6.30 (6.00) | 0.987 [0.570-1.160] | 0.984 [0.578-1.146] | 1.011 [0.550-1.111] |
| hog (µs) | 10.4 (8.8) | 10.5 (8.3) | 11.3 (8.3) | 10.5 (8.2) | 0.996 [0.681-1.498] | 1.028 [0.592-1.438] | 0.986 [0.782-1.436] |
| produce | 5.33 (5.30) | 5.33 (5.25) | 5.32 (5.26) | 5.33 (5.29) | 1.001 [0.964-1.063] | 0.993 [0.965-1.055] | 1.000 [0.985-1.021] |

No row of `one` or `arm` is outside the layout control's range, and none is further from main at the
median than the control's worst (spawn, 2.4% for the control, 2.0% for `one`, 3.9% for `arm`; spawn runs
in two modes on the Mac, 10-12 and 15-17 ms, and every arm has runs in both). bench/tasks registers no
descriptor, so neither switch's code runs in it: `registerIn` is never called, and `serviceAll` skips a
poller that holds none.

## 7. Risks, and what the owner session should weigh

**`one`: every socket in one poller, on the Mac.**

- It is where a socket waits, which docs/internals/scheduler.md states as a rule ("a socket is registered
  with the poller of the worker that makes or accepts it"), so it needs the designer's word. The pollers
  record (concurrency-pollers) measured the other direction for `http.serve` on the Mac, spreading its
  connections over the workers' pollers, and found 79% more CPU and 17% fewer requests: echo's sockets
  are in that spread shape today, and this takes them out of it.
- **Linux must keep a poller a worker.** Rig leads Tokio on echo there (1.10 against 1.29 µs) with the
  workers' own pollers, and the same look rule lost there. The arm is gated to Darwin at compile time, as
  `settle_wait` is; nothing here was run on Linux.
- **One reader.** Whoever looks at the one poller takes up to 64 events a call; the probes took 40 to
  59. A program with many more sockets ready at once than echo's 200 reads them 64 at a time from one
  kqueue. Not measured beyond echo, bench/http (which already has this shape) and bench/mixed (the same).
- **Worker 0 busy.** Worker 0 is `main`'s thread. While it computes, its poller's events wait for the
  other workers' looks as they go to sleep (kept in `one`), the watcher's look each millisecond, and the
  monitor's signal: what `http.serve`'s connections get today when their acceptor's worker is busy.
  With `arm_nl` as well, only the last two are left, which is the cost section 9 measures on bench/mixed
  (p50 at 100,000 a second 57 to 68 µs). So `one` alone carries no new latency risk; `arm` does.
- **Which poller.** The probe uses worker 0's. The first worker to register a socket, or a poller that
  belongs to no worker and is waited in by whichever worker sleeps first (Tokio's driver), are the other
  shapes; the last needs a worker to be woken wherever it sleeps, and was not built here.
- Not run: the unit tests, the core suite, Trig's and loco's light gates, the bench guards. The arm is a
  probe.

**The look rule (`arm_nl`)** adds 4% on echo on top of `one` (5.16 to 4.95 µs) and belongs with the
closed loop, where it is worth 4.8% (section 9): its cost is bench/mixed's p50. A rule between the two,
a look at another's poller only once its own worker has left it alone for G µs, was tried at 10, 20 and
50 µs (probe `p3`, A20-A22): it moves between main and `nl` on both sides at once (echo 2%, 5% and 9%
faster; bench/mixed's p50 at 100,000 a second 62, 67 and 74 µs against main's 60 and `nl`'s 72 on that
board), so no gap keeps both.

## 8. What is left above the ceiling

`one` at ten workers runs 5.16-5.21 µs and `arm` 4.95-5.05; the ceiling's best shape and both runtimes
at three workers run 3.7-3.9. The difference is how many workers take the work, and these probes bound it
(section 4, 7 rounds each on 39830dcc9):

| one poller, and | µs a trip | cores |
|---|---:|---:|
| no cap (`one`) | 5.09 | 4.9 |
| at most 4 workers awake | 4.77 | 4.0 |
| at most 3 awake | 3.82 | 3.0 |
| at most 2 awake | 4.26 | 2.3 |
| `RIG_WORKERS=3` (final board, `arm`) | 3.91 | 2.7 |

A cap of three is the M5's four performance cores less one for the kernel's loopback thread, which a
runtime cannot know: with the other end in another process the best count differs (the closed loop is
fastest at one worker, 9.1). Tokio does not cap either and sits at five. A cap alone, without one
poller, does nothing (6.31-6.34 µs: each worker is woken by its own sockets, not by `notify`).

What might be a rule rather than a number, none of it built or measured here:

- **Wake by backlog.** With one poller the reader takes 59 events a look and the chain of wakes (`spread`,
  then each searcher that finds work waking the next) reaches every worker. A searcher that wakes the
  next only while the ring it stole from still holds more than a worker runs in one wake (5 µs, two or
  three of echo's fibers) would stop the chain at about the count the backlog needs. `RIG_P_SPREAD`
  gated only the owner's wake, not the chain's, and moved echo by nothing.
- **Performance cores.** Workers ask for no cores today (scheduler.md, "Which cores"), and the QoS probe
  of the hyper work found the class capped for command-line programs. Waking no sleeper for socket work
  while as many workers as performance cores are awake is the cap of four above, worth 6% over `one`.

Either is a scheduler design question for the owner session, and neither is needed to pass Tokio.

## 9. The closed loop, as measured before the scope change (for the closed-loop expert)

Everything in this section was measured on 39830dcc9 before the closed loop moved to another expert. It
is recorded as found and not taken further.

### 9.0 The row, measured again

bench/http, closed loop (64 connections, 3 s, 15 rounds interleaved and rotated, 17:23-17:27, load 1.7;
every round in A3):

| | Rig | Rig again (A/A) | hyper | Go |
|---|---:|---:|---:|---:|
| requests a second, median | 167,473 | 169,006 | 173,057 | 154,556 |
| best | 172,466 | 173,758 | 176,116 | 160,432 |
| p50 / p99 | 378 / 582 µs | 373 / 575 | 363 / 570 | 398 / 980 |
| against Rig, paired median [range] | 1 | 1.005 [0.957-1.078] | 1.033 [0.963-1.090] | 0.929 [0.899-0.987] |

Rig serves 3.2% fewer requests than hyper at the median (2.3% by the A/A arm) and 2.1% fewer by the best
round.

### 9.1 Where the time goes

**A request's calls and CPU** at the default worker counts (two runs each, `bb/httpcount.py`; A9):

| a request | Rig | hyper |
|---|---:|---:|
| read / write | 1.00 / 1.00 | 1.00 / 1.00 |
| waits in a poller | 0.35 | 0.195 |
| looks at a poller (with events) | 1.32 (0.43) | 0.019 |
| kicks / signals, condition waits | 0.21 | 0.224, 0.224 |
| all calls | 3.88 | 2.66 |
| a read / a write, µs each | 5.55 / 5.69 | 5.38 / 5.62 |
| a look / a kick or signal, µs each | 0.96 / 1.84 | 7.75 / 1.69 |
| in looks, µs | 1.27 | 0.15 |
| user / system CPU, µs | 2.6 / 13.4 | 2.9 / 12.3 |
| cycles / instructions | 57.3k / 47.3k | 54.1k / 48.0k |
| cycles on performance cores | 58% | 57% |
| involuntary context switches | 0.38 | 0.33 |
| interrupt wake-ups | 0.033 | 0.001 |
| events a poller call that found any | 2.9 | 10.3 |

In the closed loop Rig's server spends 6% more cycles a request than hyper's, not 12% fewer as in the
open loop at 100,000 a second, where the workers have idle time between requests: here its system time
is 1.1 µs over hyper's, and its looks cost 1.27 µs where hyper's cost 0.15. Every connection sits in
worker 0's poller, and every other worker looks at it each time it goes to sleep; 68% of those looks
find nothing. Where the reads ran: Rig's worker 0 made 27% of them, three more workers 11%, 19% and 21%,
and six workers 3.3-3.6% each; hyper's ten threads made 9.0-10.5% each.

**Is the generator the limit?** Yes, with the server, on four performance cores. The generator (Go, 64
goroutines, `GOMAXPROCS` 10) spends 21.7 µs of CPU a request, 3.65 cores, and is switched out once a
request; the server spends 15-16 µs, 2.6-2.75 cores (9.0's board, A3). Together 6.3-6.4 cores:

| generator's `GOMAXPROCS` (5 rounds, A8) | Rig req/s | hyper req/s | generator cores | server cores |
|---|---:|---:|---:|---:|
| 4 | 179,246 | 182,900 | 2.6-2.7 | 2.8-2.9 |
| 6 | 172,464 | 176,445 | 3.1-3.2 | 2.7-2.8 |
| 10 (the row) | 168,715 | 173,142 | 3.7 | 2.6 |
| 16 | 163,462 | 166,627 | 4.2-4.3 | 2.6-2.65 |

**Does `RIG_WORKERS` below 10 raise throughput?** Yes, and so does hyper's (5 rounds, A7):

| server's workers | Rig req/s | Rig server µs a request / cores | hyper req/s | hyper server µs a request / cores |
|---:|---:|---:|---:|---:|
| 1 | 194,846 | 5.2 / 1.01 | 190,502 | 5.1 / 0.98 |
| 2 | 189,101 | 9.0 / 1.71 | 187,968 | 9.2 / 1.74 |
| 3 | 181,540 | 10.9 / 1.98 | 178,470 | 12.4 / 2.19 |
| 4 | 175,290 | 13.3 / 2.34 | 175,235 | 13.9 / 2.43 |
| 6 | 167,054 | 15.9 / 2.66 | 172,944 | 14.9 / 2.55 |
| 10 (the row) | 168,715 | 15.4 / 2.60 | 173,142 | 15.0 / 2.60 |

At one worker Rig serves 15.5% more than at ten, and 2.3% more than hyper at one. A request costs the
server 5.2 µs of CPU on one worker and three times that on ten, in both servers: the same reads and
writes, on more cores, half of them efficiency cores. Rig is level with or ahead of hyper up to four
workers and behind from six.

### 9.2 The look rule's cost: bench/mixed, open loop

One request in four computes for 31 µs and 5,000 idle connections stay open (bench/mixed's own driver, 4
rounds, 17:54-17:58; `rig-nl8` is `nl` with `RIG_P_SPREAD=8`; median, fastest in brackets; A19):

| | p50 | p99 | p99.9 | server cores |
|---|---:|---:|---:|---:|
| **60,000 a second** | | | | |
| main | 45 µs | 115 (107) | 882 | 0.9 |
| main again | 45 | 117 (116) | 871 | 0.9 |
| nl | 44 | 180 (115) | 846 | 0.9 |
| nl, spread 8 | 41 | 189 (183) | 931 | 0.8 |
| hyper | 45 | 192 (130) | 908 | 1.0 |
| **100,000 a second** | | | | |
| main | 57 µs (55) | 287 (265) | 929 | 1.9 |
| main again | 57 (56) | 484 (289) | 1,044 | 1.9 |
| nl | **68** (68) | 345 (315) | 968 | 1.7 |
| nl, spread 8 | **96** (96) | 466 (312) | 1,027 | 1.5 |
| hyper | 61 (60) | 404 (354) | 1,006 | 2.2 |

One round of `nl` at 60,000 and one of `main again` at 100,000 had a p99 of 14-15 ms, the Mac's stalls
that every arm of every earlier board shows. Without the looks the p50 at 100,000 rises from 57 to 68 µs
in every round (hyper's is 61), with the p99 inside the A/A pair's spread and 10% fewer cores: a request
that lands while worker 0 computes waits for worker 0, where on main a worker on its way to sleep takes
it. Waking no worker for a ring under eight (`spread 8`) costs more, 96 µs: it is not a change to build as
it is, and it would also keep fork-join tasks waiting for the monitor.

### 9.3 What it comes to

- The closed loop's probe arms are in section 4 ("Closed loop") and the look rule's confirm in section 5:
  with no looks at other workers' pollers Rig serves 4.8% more (176.2k against 167.9k, above main in all
  15 rounds, A/A 0.5% apart) and passes hyper by 1.8%, on 18% less server CPU a request.
- Its cost is 9.2's p50. The look-gap rule does not escape it (A20-A22; on that busier board the closed
  loop read `nl` 1.027, gaps of 10 and 20 µs 0.985, 50 µs 1.006 of main).
- It is in effect the rule of `archive/sched-solo` (the hyper work's arm S and its fix), which measured
  the same direction on the Mac on 2026-11-16 (closed loop 4-8% more, 16% fewer cycles a request on the
  trivial open loop) and lost on pup (closed loop 24% fewer, connect 14% slower), so it would be a
  Mac-only rule.
- Fewer workers raise the row more than anything else (one worker: 15.5% more), in hyper too; a cap on
  awake workers gave 5.6-12.4% (4, 3, 2 awake), and a threshold on `spread` 3-4%, at bench/mixed's p50
  (96 µs with a threshold of 8).

## Files

In `bb/` of the worktree (scripts, patches and raw runs copied to `fable-review/mac-echo/`):

- **The diff to build from:** `arm.patch` (against f03ef5199, 59 lines; what `src/sched.zig` in the
  worktree holds, both switches `false`). `arm_one` is the change; `arm_nl` the look rule.
- Probe patches against 39830dcc9 (they apply to f03ef5199 too), none committed: `probe-p1.patch` (the
  switches and counters of section 4), `probe-p2.patch` (`RIG_P_NOLOOKS=2`: the watcher keeps its look;
  section 5's `nl` is this with `own_look_default` 2), `probe-p3.patch` (the look gap, `RIG_P_NOLOOKS=3`
  with `RIG_P_LOOKGAP`).
- Programs: `src/echo.rig` and `src/tokio-echo/` (echo alone: `CONNS TRIPS REPEATS`), `src/count.c` (the
  counting library: the loopback record's, with each call timed, and the process's cycles, instructions
  and performance-core share from `proc_pid_rusage`), `src/wl.c` (wake latency three ways). The ceiling is
  the record's `docs/history/records/2026-11/concurrency-loopback/ceiling.zig`, unchanged.
- Boards: `netboard.py`, `netsum.py`, `httpboard.py`, `httpsum.py`, `httpcount.py`, `countrun.sh`,
  `countsum.py`, `state.sh`; `claim1.sh` to `claim12.sh` and `claimF1.sh` to `claimF3.sh` are what each
  claim ran; `alltables.sh` prints the appendix below.
- Builds: `build.sh`, `buildprobe.sh`, `build2.sh`, `build3.sh` (the probes), `buildarm.sh` and
  `buildfinal.sh` (the final arms). Whole `bin/rig`s: `rig-main` (39830dcc9), `rig-p1`, `rig-p2`,
  `rig-nl`, `rig-p3`, and on f03ef5199 `rig-main2`, `rig-aa`, `rig-one`, `rig-arm`, `rig-nl2`; the benches
  each built are under `net/`, `http/`, `mixed/` and, for the final boards, `f/`.
- `raw/`: every run as JSON lines, each claim's log, the counts (`raw/count/`), the `sample` outputs.

Pitfalls met: `/usr/bin/env` drops `DYLD_INSERT_LIBRARIES`, so a counted run sets its variables in the
shell (`countrun.sh`); `sample` counts blocked threads with running ones, so it cannot split a wait from
a look; bench-net's `--out` must be an absolute path (cargo runs in bench/net/tokio, and a relative
`--target-dir` lands there and moves its Cargo.lock, restored here).

## Appendix: every board and count

`bb/alltables.sh` printed what follows from `bb/raw/`. Each board's first lines give the time, the load
averages and every process over 20% of a core as it began and ended. Rows are µs a round trip or
connection unless the table says otherwise; "rounds" lists every round in order.

### A1. bench/net re-measured, the whole program (claim echo-remeasure): raw/net1.jsonl

start 2026-11-17 16:54:45 state 16:54:45 load { 3.81 3.61 4.03 }
end 2026-11-17 16:56:05 state 16:56:05 load { 5.05 3.99 4.13 }

## pingpong (µs each)
| arm | median | min | max | /rig paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| rig | 15.63 | 15.20 | 16.51 | 1.000 [1.000-1.000] | 15.65 15.20 15.36 15.59 15.63 16.06 15.59 16.02 15.58 15.73 15.46 15.20 16.51 15.66 15.68 |
| rigB | 15.60 | 14.55 | 16.63 | 0.993 [0.930-1.094] | 14.55 15.06 15.40 15.48 15.46 15.46 15.77 15.68 15.60 15.60 15.50 16.63 16.19 15.61 15.66 |
| tokio | 15.04 | 14.79 | 16.41 | 0.962 [0.896-1.059] | 15.07 14.93 15.04 15.00 14.95 14.98 16.41 15.23 15.05 15.05 15.07 16.10 14.79 15.02 14.86 |
| go | 16.14 | 15.57 | 17.44 | 1.034 [0.972-1.147] | 16.65 15.57 15.98 16.09 16.35 17.23 17.20 16.35 16.11 16.09 16.15 17.44 16.05 16.14 16.08 |

## echo (µs each)
| arm | median | min | max | /rig paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| rig | 6.36 | 6.27 | 6.61 | 1.000 [1.000-1.000] | 6.33 6.37 6.33 6.40 6.33 6.31 6.47 6.46 6.61 6.27 6.37 6.34 6.40 6.36 6.36 |
| rigB | 6.38 | 6.26 | 6.80 | 1.006 [0.973-1.085] | 6.38 6.39 6.37 6.45 6.36 6.40 6.60 6.38 6.43 6.80 6.35 6.37 6.26 6.32 6.41 |
| tokio | 5.45 | 5.15 | 5.54 | 0.854 [0.810-0.874] | 5.45 5.45 5.47 5.46 5.46 5.49 5.39 5.51 5.46 5.28 5.44 5.54 5.35 5.44 5.15 |
| go | 5.96 | 5.80 | 6.37 | 0.936 [0.900-0.986] | 6.00 5.92 5.96 5.97 5.92 5.99 6.19 6.37 5.94 5.80 5.99 5.89 5.91 5.95 5.96 |

## connect (µs each)
| arm | median | min | max | /rig paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| rig | 50.86 | 49.71 | 54.24 | 1.000 [1.000-1.000] | 49.71 50.03 51.28 51.04 51.41 50.05 49.94 50.81 51.72 50.81 51.03 54.24 51.99 50.86 50.59 |
| rigB | 51.15 | 49.53 | 52.78 | 0.998 [0.949-1.043] | 49.53 49.95 50.74 51.15 51.48 51.54 51.27 49.77 50.63 50.34 52.23 51.45 50.18 51.16 52.78 |
| tokio | 62.18 | 60.96 | 68.34 | 1.227 [1.132-1.321] | 61.83 60.96 62.30 63.66 63.06 64.58 62.06 61.80 68.34 61.52 63.56 61.42 62.88 61.94 62.18 |
| go | 61.64 | 58.93 | 64.63 | 1.207 [1.090-1.291] | 59.03 63.84 59.64 61.64 62.06 64.63 58.93 59.49 61.85 61.34 62.69 59.09 60.95 62.70 62.19 |

### A2. echo alone, with the process's CPU and context switches (same claim): raw/echo1.jsonl

start 2026-11-17 16:56:05 state 16:56:05 load { 5.05 3.99 4.13 }
end 2026-11-17 16:56:33 state 16:56:33 load { 6.83 4.49 4.31 }

## echo (µs each)
| arm | median | min | max | /rig paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| rig | 6.40 | 6.26 | 6.50 | 1.000 [1.000-1.000] | 6.43 6.26 6.29 6.39 6.43 6.32 6.40 6.39 6.42 6.36 6.49 6.41 6.50 6.38 6.41 |
| rigB | 6.38 | 6.31 | 6.55 | 1.000 [0.986-1.020] | 6.37 6.35 6.31 6.41 6.41 6.34 6.38 6.31 6.42 6.35 6.40 6.54 6.55 6.39 6.35 |
| tokio | 5.47 | 5.30 | 5.93 | 0.855 [0.835-0.924] | 5.48 5.30 5.45 5.47 5.50 5.41 5.44 5.42 5.36 5.47 5.55 5.93 5.56 5.47 5.44 |

## per trip, whole process (median): user µs, system µs, CPU µs, cores, voluntary csw, involuntary csw
| arm | user | sys | cpu | cores | vcsw | ivcsw |
|---|---:|---:|---:|---:|---:|---:|
| rig | 5.79 | 49.23 | 55.01 | 8.61 | 0.000 | 0.217 |
| rigB | 5.75 | 48.83 | 54.57 | 8.54 | 0.000 | 0.200 |
| tokio | 1.96 | 26.24 | 28.24 | 5.14 | 0.000 | 0.295 |

### A3. bench/http closed loop re-measured (claim http-remeasure): raw/http1.jsonl

start 2026-11-17 17:23:27 state 17:23:27 load { 1.68 2.52 4.04 }
end 2026-11-17 17:27:03 state 17:27:03 load { 12.32 8.10 6.14 }

| arm | median req/s | best | min | /rig paired median [min-max] | p50 µs | p99 µs | rounds (k req/s) |
|---|---:|---:|---:|---|---:|---:|---|
| rig | 167473 | 172466 | 161145 | 1.000 [1.000-1.000] | 378 | 582 | 165.0 169.9 172.5 168.0 167.5 168.9 165.8 165.6 163.6 161.1 170.2 167.7 166.2 168.2 163.9 |
| rigB | 169006 | 173758 | 157889 | 1.005 [0.957-1.078] | 373 | 575 | 157.9 164.9 169.1 166.7 168.2 169.7 169.0 170.3 167.9 173.8 169.6 170.4 170.8 166.1 167.6 |
| hyper | 173057 | 176116 | 161223 | 1.033 [0.963-1.090] | 363 | 570 | 165.5 175.2 173.9 176.1 161.2 174.5 173.1 171.7 172.5 175.7 169.8 172.8 173.3 173.1 172.8 |
| go | 154556 | 160432 | 152694 | 0.929 [0.899-0.987] | 398 | 980 | 154.3 152.7 155.0 155.4 159.8 153.5 155.3 154.6 160.4 159.1 154.0 154.1 154.4 154.6 153.6 |

| arm | server user µs/req | server sys | server cores | server vcsw/req | server ivcsw/req | load user µs/req | load sys | load cores | load vcsw/req | load ivcsw/req | all cores |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rig | 2.54 | 13.69 | 2.73 | 0.000 | 0.408 | 3.75 | 17.92 | 3.64 | 0.000 | 1.002 | 6.36 |
| rigB | 2.44 | 13.26 | 2.64 | 0.000 | 0.390 | 3.75 | 17.84 | 3.65 | 0.000 | 0.999 | 6.29 |
| hyper | 2.80 | 12.15 | 2.60 | 0.000 | 0.330 | 3.74 | 17.26 | 3.65 | 0.000 | 0.963 | 6.25 |
| go | 8.98 | 18.02 | 4.17 | 0.003 | 0.932 | 3.87 | 18.45 | 3.45 | 0.000 | 1.017 | 7.62 |

### A4. echo by worker count (claim echo-shares): raw/echo-workers.jsonl

start 2026-11-17 17:07:08 state 17:07:08 load { 2.93 4.93 4.93 }
end 2026-11-17 17:07:45 state 17:07:45 load { 3.82 4.92 4.93 }

## echo (µs each)
| arm | median | min | max | /rig-w10 paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| rig-w1 | 6.07 | 5.98 | 6.34 | 0.949 [0.934-0.993] | 6.34 6.06 5.98 6.07 6.09 |
| tokio-w1 | 6.14 | 6.08 | 6.21 | 0.961 [0.952-0.969] | 6.08 6.14 6.21 6.14 6.14 |
| rig-w2 | 4.23 | 4.22 | 4.24 | 0.662 [0.660-0.663] | 4.22 4.24 4.23 4.23 4.24 |
| tokio-w2 | 4.54 | 4.53 | 4.62 | 0.710 [0.706-0.723] | 4.56 4.54 4.54 4.62 4.53 |
| rig-w3 | 3.70 | 3.66 | 3.87 | 0.579 [0.574-0.604] | 3.73 3.70 3.87 3.66 3.70 |
| tokio-w3 | 3.76 | 3.65 | 4.22 | 0.588 [0.572-0.660] | 3.70 3.65 4.22 3.76 3.80 |
| rig-w4 | 4.49 | 4.41 | 4.60 | 0.703 [0.690-0.718] | 4.52 4.49 4.60 4.41 4.45 |
| tokio-w4 | 5.12 | 5.10 | 5.17 | 0.801 [0.797-0.809] | 5.16 5.12 5.10 5.17 5.11 |
| rig-w6 | 5.87 | 5.84 | 5.99 | 0.918 [0.910-0.939] | 5.99 5.87 5.88 5.87 5.84 |
| tokio-w6 | 5.63 | 5.59 | 6.70 | 0.878 [0.874-1.047] | 5.60 5.59 6.70 5.74 5.63 |
| rig-w8 | 6.32 | 6.27 | 6.37 | 0.988 [0.982-0.995] | 6.32 6.31 6.37 6.27 6.32 |
| tokio-w8 | 5.52 | 5.49 | 5.76 | 0.861 [0.861-0.899] | 5.49 5.50 5.76 5.55 5.52 |
| rig-w10 | 6.39 | 6.38 | 6.41 | 1.000 [1.000-1.000] | 6.38 6.39 6.40 6.39 6.41 |
| tokio-w10 | 5.48 | 5.45 | 5.79 | 0.858 [0.853-0.904] | 5.45 5.54 5.79 5.48 5.47 |

## per trip, whole process (median): user µs, system µs, CPU µs, cores, voluntary csw, involuntary csw
| arm | user | sys | cpu | cores | vcsw | ivcsw |
|---|---:|---:|---:|---:|---:|---:|
| rig-w1 | 0.71 | 5.50 | 6.20 | 1.02 | 0.000 | 0.072 |
| tokio-w1 | 0.62 | 5.53 | 6.16 | 1.00 | 0.000 | 0.001 |
| rig-w2 | 0.87 | 7.64 | 8.50 | 2.01 | 0.000 | 0.051 |
| tokio-w2 | 0.79 | 8.00 | 8.78 | 1.94 | 0.000 | 0.022 |
| rig-w3 | 1.78 | 9.21 | 11.01 | 2.97 | 0.000 | 0.053 |
| tokio-w3 | 0.92 | 9.44 | 10.35 | 2.76 | 0.000 | 0.049 |
| rig-w4 | 1.38 | 16.66 | 18.02 | 4.01 | 0.000 | 0.060 |
| tokio-w4 | 1.21 | 17.95 | 19.16 | 3.75 | 0.000 | 0.057 |
| rig-w6 | 4.33 | 30.52 | 34.89 | 5.94 | 0.000 | 0.070 |
| tokio-w6 | 1.89 | 25.26 | 27.21 | 4.85 | 0.000 | 0.241 |
| rig-w8 | 5.39 | 43.45 | 48.99 | 7.77 | 0.000 | 0.119 |
| tokio-w8 | 1.94 | 26.32 | 28.25 | 5.12 | 0.000 | 0.291 |
| rig-w10 | 5.83 | 49.28 | 55.16 | 8.63 | 0.000 | 0.206 |
| tokio-w10 | 1.95 | 26.15 | 28.10 | 5.14 | 0.000 | 0.295 |

### A5. echo's calls per round trip by worker count (claim echo-counts): raw/count/{rig,tokio}-wN-R.*

| run | read | EAGAIN | write | kq wait | wait woke | wait t/o | no deadline | look | look hit | change | kick | events | user ev | cond sig | cond wait | calls | µs/read | µs/write | µs/look | µs/change | µs/cond sig | µs/kq wait | µs/cond wait | vcsw | ivcsw | user µs | sys µs | cycles k | instr k | P-core cycles % | intwk | threads active | ran | stole | slept |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rig-w10-1 | 2.002 | 0.001 | 2.000 | 0.269 | 0.244 | 0.024 | 0.000 | 4.708 | 1.463 | 0.254 | 0.250 | 4.253 | 0.250 | 0.000 | 0.000 | 9.23 | 8.40 | 8.68 | 3.05 | 3.28 | 0.00 | 43.6 | 0.0 | 0.000 | 0.258 | 6.32 | 48.41 | 185.9 | 94.0 | 43 | 0.0405 | 10 | 2.01 | 1.32 | 0.70 |
| rig-w10-2 | 2.002 | 0.001 | 2.000 | 0.230 | 0.214 | 0.016 | 0.000 | 4.478 | 1.314 | 0.258 | 0.254 | 4.257 | 0.253 | 0.000 | 0.000 | 8.97 | 8.39 | 8.66 | 3.14 | 3.28 | 0.00 | 44.8 | 0.0 | 0.000 | 0.226 | 6.21 | 48.26 | 185.0 | 92.6 | 42 | 0.0339 | 10 | 2.01 | 1.34 | 0.66 |
| tokio-w10-1 | 3.001 | 1.000 | 4.000 | 0.064 | 0.064 | 0.000 | 0.064 | 0.030 | 0.030 | 0.001 | 0.000 | 4.013 | 0.001 | 0.207 | 0.207 | 7.51 | 4.27 | 3.19 | 12.08 | 0.00 | 1.18 | 11.6 | 154.4 | 0.000 | 0.295 | 2.20 | 26.47 | 102.9 | 79.5 | 59 | 0.0003 | 10 |  |  |  |
| tokio-w10-2 | 3.001 | 1.000 | 4.000 | 0.065 | 0.065 | 0.000 | 0.065 | 0.031 | 0.030 | 0.002 | 0.000 | 4.013 | 0.002 | 0.210 | 0.209 | 7.52 | 4.26 | 3.18 | 12.01 | 0.00 | 1.19 | 11.6 | 151.7 | 0.000 | 0.299 | 2.23 | 26.44 | 102.9 | 79.6 | 59 | 0.0002 | 10 |  |  |  |
| rig-w6-1 | 2.002 | 0.001 | 2.000 | 0.043 | 0.043 | 0.000 | 0.000 | 3.507 | 1.614 | 0.160 | 0.156 | 4.159 | 0.156 | 0.000 | 0.000 | 7.71 | 6.09 | 6.33 | 1.64 | 2.20 | 0.00 | 9.8 | 0.0 | 0.000 | 0.062 | 4.79 | 29.92 | 125.5 | 84.0 | 58 | 0.0151 | 6 | 2.01 | 1.21 | 0.71 |
| tokio-w6-1 | 3.001 | 1.000 | 4.000 | 0.049 | 0.049 | 0.000 | 0.049 | 0.031 | 0.031 | 0.002 | 0.000 | 4.013 | 0.002 | 0.150 | 0.150 | 7.38 | 4.10 | 3.09 | 11.18 | 0.00 | 1.10 | 15.6 | 78.9 | 0.000 | 0.229 | 2.14 | 25.47 | 100.6 | 78.3 | 61 | 0.0000 | 6 |  |  |  |
| rig-w4-1 | 2.002 | 0.001 | 2.000 | 0.007 | 0.007 | 0.000 | 0.000 | 0.230 | 0.164 | 0.013 | 0.009 | 4.012 | 0.009 | 0.000 | 0.000 | 4.25 | 3.89 | 4.04 | 2.85 | 1.34 | 0.00 | 8.3 | 0.0 | 0.000 | 0.057 | 1.60 | 16.16 | 69.8 | 68.9 | 80 | 0.0444 | 4 | 2.01 | 0.24 | 0.08 |
| tokio-w4-1 | 3.001 | 1.000 | 4.000 | 0.022 | 0.022 | 0.000 | 0.022 | 0.029 | 0.029 | 0.001 | 0.000 | 4.012 | 0.001 | 0.037 | 0.036 | 7.13 | 2.91 | 2.18 | 14.12 | 0.00 | 0.81 | 10.2 | 176.4 | 0.000 | 0.058 | 1.37 | 17.64 | 74.5 | 74.6 | 80 | 0.0001 | 4 |  |  |  |
| rig-w3-1 | 2.003 | 0.002 | 2.000 | 0.028 | 0.028 | 0.000 | 0.000 | 1.306 | 0.902 | 0.074 | 0.070 | 4.073 | 0.069 | 0.000 | 0.000 | 5.41 | 2.08 | 2.16 | 0.76 | 0.68 | 0.00 | 5.7 | 0.0 | 0.000 | 0.037 | 1.84 | 9.10 | 46.2 | 71.0 | 99 | 0.0118 | 3 | 2.01 | 0.76 | 0.54 |
| tokio-w3-1 | 3.001 | 1.000 | 4.000 | 0.027 | 0.027 | 0.000 | 0.027 | 0.028 | 0.028 | 0.000 | 0.000 | 4.012 | 0.000 | 0.038 | 0.038 | 7.13 | 1.51 | 1.10 | 10.57 | 0.00 | 0.74 | 9.6 | 119.0 | 0.000 | 0.043 | 1.01 | 9.12 | 42.6 | 72.0 | 100 | 0.0000 | 3 |  |  |  |
| rig-w2-1 | 2.003 | 0.002 | 2.000 | 0.009 | 0.009 | 0.000 | 0.000 | 0.133 | 0.102 | 0.013 | 0.009 | 4.012 | 0.009 | 0.000 | 0.000 | 4.16 | 1.82 | 1.90 | 3.20 | 0.58 | 0.00 | 5.7 | 0.0 | 0.000 | 0.048 | 1.00 | 7.61 | 36.5 | 66.1 | 100 | 0.0414 | 2 | 2.01 | 0.04 | 0.07 |
| tokio-w2-1 | 3.001 | 1.000 | 4.000 | 0.022 | 0.022 | 0.000 | 0.022 | 0.031 | 0.031 | 0.000 | 0.000 | 4.011 | 0.000 | 0.018 | 0.018 | 7.09 | 1.35 | 0.99 | 8.44 | 0.00 | 0.73 | 7.5 | 272.4 | 0.000 | 0.022 | 0.88 | 8.03 | 37.5 | 71.2 | 100 | 0.0004 | 2 |  |  |  |
| rig-w1-1 | 2.002 | 0.001 | 2.000 | 0.000 | 0.000 | 0.000 | 0.000 | 0.063 | 0.063 | 0.004 | 0.000 | 4.002 | 0.000 | 0.000 | 0.000 | 4.07 | 1.39 | 1.37 | 3.94 | 0.44 | 0.00 | 149.0 | 0.0 | 0.000 | 0.070 | 0.75 | 5.55 | 25.5 | 66.6 | 100 | 0.0692 | 1 | 2.01 | 0.00 | 0.03 |
| tokio-w1-1 | 3.000 | 0.999 | 4.000 | 0.004 | 0.004 | 0.000 | 0.004 | 0.033 | 0.033 | 0.000 | 0.000 | 4.011 | 0.000 | 0.000 | 0.000 | 7.04 | 0.99 | 0.67 | 9.94 | 0.00 | 0.09 | 1.1 | 309403.3 | 0.000 | 0.001 | 0.67 | 5.53 | 25.9 | 71.3 | 100 | 0.0000 | 1 |  |  |  |

### A6. echo by connections, one round only before the claim's limit (claim echo-counts): raw/echo-conns.jsonl

start 2026-11-17 17:15:09 state 17:15:09 load { 5.41 7.03 6.10 }

## echo (µs each)
| arm | median | min | max | /rig-c100 paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| rig-c10 | 6.99 | 6.99 | 6.99 | 1.099 [1.099-1.099] | 6.99 |
| tokio-c10 | 5.62 | 5.62 | 5.62 | 0.883 [0.883-0.883] | 5.62 |
| rig-c30 | 6.48 | 6.48 | 6.48 | 1.019 [1.019-1.019] | 6.48 |
| tokio-c30 | 5.42 | 5.42 | 5.42 | 0.851 [0.851-0.851] | 5.42 |
| rig-c100 | 6.36 | 6.36 | 6.36 | 1.000 [1.000-1.000] | 6.36 |
| tokio-c100 | 5.50 | 5.50 | 5.50 | 0.864 [0.864-0.864] | 5.50 |

## per trip, whole process (median): user µs, system µs, CPU µs, cores, voluntary csw, involuntary csw
| arm | user | sys | cpu | cores | vcsw | ivcsw |
|---|---:|---:|---:|---:|---:|---:|
| rig-c10 | 6.82 | 39.67 | 46.49 | 6.65 | 0.000 | 0.444 |
| tokio-c10 | 2.36 | 15.44 | 17.80 | 3.17 | 0.000 | 0.670 |
| rig-c30 | 6.13 | 49.96 | 56.10 | 8.66 | 0.000 | 0.220 |
| tokio-c30 | 1.86 | 18.93 | 20.79 | 3.84 | 0.000 | 0.377 |
| rig-c100 | 5.90 | 49.17 | 55.08 | 8.66 | 0.000 | 0.221 |
| tokio-c100 | 1.98 | 26.55 | 28.53 | 5.19 | 0.000 | 0.295 |

### A7. bench/http closed loop by the server's worker count (claim http-shares): raw/http-workers.jsonl

start 2026-11-17 17:08:25 state 17:08:25 load { 2.32 4.39 4.73 }
end 2026-11-17 17:12:01 state 17:12:01 load { 8.85 7.00 5.79 }

| arm | median req/s | best | min | /rig paired median [min-max] | p50 µs | p99 µs | rounds (k req/s) |
|---|---:|---:|---:|---|---:|---:|---|
| rig | 168715 | 174928 | 164427 | 1.000 [1.000-1.000] | 375 | 567 | 164.4 164.7 168.7 169.4 174.9 |
| hyper | 173142 | 174171 | 172404 | 1.029 [0.990-1.058] | 364 | 584 | 172.6 174.2 173.6 172.4 173.1 |
| rig-w1 | 194846 | 198404 | 193361 | 1.149 [1.126-1.205] | 321 | 464 | 194.8 198.4 193.4 194.6 197.0 |
| hyper-w1 | 190502 | 194370 | 184655 | 1.125 [1.089-1.180] | 336 | 469 | 193.5 194.4 189.8 184.7 190.5 |
| rig-w2 | 189101 | 190641 | 180239 | 1.121 [1.064-1.159] | 332 | 493 | 190.6 186.5 189.1 180.2 190.1 |
| hyper-w2 | 187968 | 192558 | 185691 | 1.105 [1.075-1.169] | 332 | 563 | 188.9 192.6 186.4 185.7 188.0 |
| rig-w3 | 181540 | 182772 | 178232 | 1.074 [1.042-1.112] | 348 | 521 | 182.8 178.2 181.3 181.5 182.2 |
| hyper-w3 | 178470 | 179537 | 171387 | 1.054 [1.020-1.092] | 352 | 556 | 179.5 171.4 179.1 178.4 178.5 |
| rig-w4 | 175290 | 176505 | 173689 | 1.042 [1.007-1.066] | 361 | 541 | 175.3 175.1 173.7 176.5 176.1 |
| hyper-w4 | 175235 | 176449 | 174738 | 1.036 [0.999-1.072] | 359 | 561 | 175.3 176.4 174.7 175.2 174.8 |
| rig-w6 | 167054 | 171564 | 165649 | 0.995 [0.947-1.043] | 377 | 578 | 171.6 167.1 166.6 168.6 165.6 |
| hyper-w6 | 172944 | 173421 | 171916 | 1.024 [0.983-1.052] | 364 | 566 | 172.9 173.0 172.8 173.4 171.9 |

| arm | server user µs/req | server sys | server cores | server vcsw/req | server ivcsw/req | load user µs/req | load sys | load cores | load vcsw/req | load ivcsw/req | all cores |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rig | 2.33 | 13.04 | 2.60 | 0.000 | 0.399 | 3.83 | 18.14 | 3.71 | 0.000 | 1.026 | 6.31 |
| hyper | 2.78 | 12.24 | 2.60 | 0.000 | 0.336 | 3.81 | 17.63 | 3.71 | 0.000 | 1.000 | 6.31 |
| rig-w1 | 0.61 | 4.54 | 1.01 | 0.000 | 0.069 | 3.81 | 15.27 | 3.71 | 0.000 | 1.223 | 4.72 |
| hyper-w1 | 0.68 | 4.43 | 0.98 | 0.000 | 0.009 | 3.94 | 15.06 | 3.64 | 0.000 | 1.287 | 4.63 |
| rig-w2 | 1.17 | 7.86 | 1.71 | 0.000 | 0.119 | 3.83 | 17.01 | 3.97 | 0.000 | 1.063 | 5.67 |
| hyper-w2 | 1.59 | 7.64 | 1.74 | 0.000 | 0.074 | 3.87 | 16.95 | 3.90 | 0.000 | 1.054 | 5.63 |
| rig-w3 | 1.63 | 9.31 | 1.98 | 0.000 | 0.210 | 3.69 | 17.56 | 3.85 | 0.000 | 0.960 | 5.84 |
| hyper-w3 | 2.35 | 10.07 | 2.19 | 0.000 | 0.163 | 3.87 | 17.23 | 3.78 | 0.000 | 1.051 | 5.97 |
| rig-w4 | 2.04 | 11.28 | 2.34 | 0.000 | 0.278 | 3.65 | 17.79 | 3.77 | 0.000 | 0.926 | 6.11 |
| hyper-w4 | 2.60 | 11.26 | 2.43 | 0.000 | 0.242 | 3.88 | 17.62 | 3.77 | 0.000 | 1.040 | 6.20 |
| rig-w6 | 2.48 | 13.42 | 2.66 | 0.000 | 0.378 | 3.81 | 17.97 | 3.64 | 0.000 | 1.016 | 6.31 |
| hyper-w6 | 2.74 | 12.11 | 2.55 | 0.000 | 0.315 | 3.88 | 17.79 | 3.72 | 0.000 | 1.037 | 6.28 |

### A8. bench/http closed loop by the generator's GOMAXPROCS (claim http-shares): raw/http-loadprocs.jsonl

start 2026-11-17 17:12:01 state 17:12:01 load { 8.85 7.00 5.79 }
end 2026-11-17 17:13:48 state 17:13:48 load { 8.60 7.62 6.18 }

| arm | median req/s | best | min | /rig-g4 paired median [min-max] | p50 µs | p99 µs | rounds (k req/s) |
|---|---:|---:|---:|---|---:|---:|---|
| rig-g4 | 179246 | 182885 | 178511 | 1.000 [1.000-1.000] | 351 | 486 | 179.0 180.7 178.5 182.9 179.2 |
| hyper-g4 | 182900 | 183290 | 181829 | 1.020 [0.994-1.023] | 344 | 514 | 183.2 183.3 182.1 181.8 182.9 |
| rig-g6 | 172464 | 175270 | 168118 | 0.954 [0.941-0.979] | 366 | 513 | 175.3 172.5 168.1 172.1 174.7 |
| hyper-g6 | 176145 | 176861 | 174987 | 0.979 [0.963-0.988] | 359 | 529 | 176.9 176.7 175.0 176.1 175.5 |
| rig-g16 | 163462 | 165322 | 158592 | 0.916 [0.867-0.922] | 384 | 629 | 164.9 160.7 163.5 158.6 165.3 |
| hyper-g16 | 166627 | 167322 | 166024 | 0.926 [0.915-0.933] | 376 | 637 | 166.9 166.6 166.5 167.3 166.0 |

| arm | server user µs/req | server sys | server cores | server vcsw/req | server ivcsw/req | load user µs/req | load sys | load cores | load vcsw/req | load ivcsw/req | all cores |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| rig-g4 | 2.67 | 13.67 | 2.93 | 0.000 | 0.431 | 2.36 | 11.81 | 2.55 | 0.000 | 0.445 | 5.48 |
| hyper-g4 | 2.97 | 12.30 | 2.80 | 0.000 | 0.391 | 2.47 | 12.18 | 2.68 | 0.000 | 0.445 | 5.47 |
| rig-g6 | 2.59 | 13.56 | 2.79 | 0.000 | 0.426 | 3.04 | 14.80 | 3.08 | 0.000 | 0.674 | 5.86 |
| hyper-g6 | 2.92 | 12.39 | 2.70 | 0.000 | 0.376 | 3.13 | 14.92 | 3.18 | 0.000 | 0.698 | 5.88 |
| rig-g16 | 2.44 | 13.77 | 2.65 | 0.000 | 0.399 | 4.61 | 21.23 | 4.21 | 0.000 | 1.432 | 6.87 |
| hyper-g16 | 2.80 | 12.73 | 2.58 | 0.000 | 0.298 | 4.63 | 20.95 | 4.27 | 0.000 | 1.403 | 6.85 |

### A9. bench/http's calls per request (claims http-shares, http-confirm): raw/count/h-*

| run | read | EAGAIN | write | kq wait | wait woke | wait t/o | no deadline | look | look hit | change | kick | events | user ev | cond sig | cond wait | calls | µs/read | µs/write | µs/look | µs/change | µs/cond sig | µs/kq wait | µs/cond wait | vcsw | ivcsw | user µs | sys µs | cycles k | instr k | P-core cycles % | intwk | threads active | ran | stole | slept |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| h-rig-1 | 1.000 | 0.000 | 1.000 | 0.350 | 0.322 | 0.028 | 0.000 | 1.324 | 0.426 | 0.206 | 0.206 | 2.206 | 0.206 | 0.000 | 0.000 | 3.88 | 5.55 | 5.69 | 0.96 | 1.84 | 0.00 | 144.6 | 0.0 | 0.000 | 0.377 | 2.61 | 13.44 | 57.3 | 47.3 | 58 | 0.0332 | 10 |  |  |  |
| h-rig-2 | 1.000 | 0.000 | 1.000 | 0.354 | 0.326 | 0.028 | 0.000 | 1.317 | 0.394 | 0.209 | 0.209 | 2.209 | 0.209 | 0.000 | 0.000 | 3.88 | 5.53 | 5.65 | 0.95 | 1.83 | 0.00 | 144.4 | 0.0 | 0.000 | 0.382 | 2.64 | 13.37 | 57.1 | 47.4 | 58 | 0.0336 | 10 |  |  |  |
| h-hyper-1 | 1.000 | 0.000 | 1.000 | 0.195 | 0.195 | 0.000 | 0.195 | 0.019 | 0.017 | 0.003 | 0.000 | 2.004 | 0.003 | 0.224 | 0.224 | 2.66 | 5.38 | 5.62 | 7.75 | 0.00 | 1.69 | 10.7 | 217.6 | 0.000 | 0.335 | 2.92 | 12.30 | 54.1 | 48.0 | 57 | 0.0012 | 11 |  |  |  |
| h-hyper-2 | 1.000 | 0.000 | 1.000 | 0.194 | 0.194 | 0.000 | 0.194 | 0.018 | 0.017 | 0.003 | 0.000 | 2.004 | 0.003 | 0.223 | 0.223 | 2.66 | 5.40 | 5.64 | 7.55 | 0.00 | 1.69 | 10.9 | 218.6 | 0.000 | 0.333 | 2.91 | 12.30 | 54.2 | 48.0 | 58 | 0.0011 | 11 |  |  |  |
| h-nl-1 | 1.000 | 0.000 | 1.000 | 0.343 | 0.325 | 0.017 | 0.000 | 0.461 | 0.236 | 0.238 | 0.238 | 2.238 | 0.238 | 0.000 | 0.000 | 3.04 | 4.99 | 5.09 | 1.18 | 1.90 | 0.00 | 146.9 | 0.0 | 0.000 | 0.390 | 1.97 | 11.54 | 49.0 | 44.6 | 63 | 0.0246 | 10 |  |  |  |
| h-nl-2 | 1.000 | 0.000 | 1.000 | 0.375 | 0.352 | 0.023 | 0.000 | 0.588 | 0.271 | 0.239 | 0.239 | 2.239 | 0.239 | 0.000 | 0.000 | 3.20 | 5.04 | 5.15 | 1.02 | 1.91 | 0.00 | 136.2 | 0.0 | 0.000 | 0.423 | 2.09 | 11.76 | 50.0 | 45.5 | 62 | 0.0296 | 10 |  |  |  |

### A10. wake latency three ways (claim echo-probes): raw/wl.txt

```
kq    gap   50 us: waker's call p10/p50/p90   333   375   834 ns; to sleeper running p10/p50/p90   4791   5042   7458 ns
cond  gap   50 us: waker's call p10/p50/p90   333   334   708 ns; to sleeper running p10/p50/p90   4958   5042   6084 ns
ulock gap   50 us: waker's call p10/p50/p90   291   292   583 ns; to sleeper running p10/p50/p90   4833   4917   5833 ns
kq    gap  500 us: waker's call p10/p50/p90   333   375  3708 ns; to sleeper running p10/p50/p90   4959   5875  10042 ns
cond  gap  500 us: waker's call p10/p50/p90   333   375  3584 ns; to sleeper running p10/p50/p90   4958   5667   9917 ns
ulock gap  500 us: waker's call p10/p50/p90   291   334  3708 ns; to sleeper running p10/p50/p90   4833   5625  10500 ns
```

### A11. echo, probe arms round 1 (claim echo-probes): raw/echo-probe1.jsonl

start 2026-11-17 17:30:19 state 17:30:19 load { 4.32 6.47 5.85 }
end 2026-11-17 17:31:20 state 17:31:20 load { 10.50 7.77 6.37 } |  20.5% /System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/Metadata.framework/Versions/A/Support/corespotlightd

## echo (µs each)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 6.36 | 6.28 | 6.58 | 1.000 [1.000-1.000] | 6.58 6.34 6.36 6.38 6.28 6.31 6.38 |
| p | 6.36 | 6.32 | 6.39 | 0.999 [0.969-1.014] | 6.38 6.36 6.35 6.32 6.37 6.39 6.34 |
| one | 5.09 | 4.76 | 5.30 | 0.774 [0.749-0.844] | 5.09 4.76 4.76 4.79 5.30 5.26 5.17 |
| one-a2 | 4.26 | 4.23 | 4.31 | 0.670 [0.647-0.676] | 4.26 4.25 4.26 4.31 4.24 4.26 4.23 |
| one-a3 | 3.82 | 3.74 | 3.90 | 0.598 [0.585-0.617] | 3.85 3.75 3.80 3.82 3.74 3.90 3.89 |
| one-a4 | 4.77 | 4.75 | 4.88 | 0.750 [0.742-0.765] | 4.88 4.75 4.77 4.76 4.80 4.77 4.79 |
| a2 | 6.31 | 6.26 | 6.36 | 0.995 [0.967-1.001] | 6.36 6.34 6.30 6.26 6.29 6.31 6.35 |
| a4 | 6.34 | 6.31 | 6.40 | 1.000 [0.971-1.013] | 6.39 6.34 6.40 6.32 6.36 6.34 6.31 |
| spread4 | 6.35 | 6.27 | 6.37 | 0.998 [0.967-1.012] | 6.36 6.33 6.35 6.27 6.35 6.37 6.31 |
| spread999 | 6.38 | 6.29 | 6.40 | 1.003 [0.970-1.011] | 6.38 6.38 6.29 6.35 6.35 6.38 6.40 |
| nolooks | 5.78 | 5.62 | 6.00 | 0.909 [0.854-0.941] | 5.62 5.66 5.78 5.73 5.80 5.84 6.00 |
| settle0 | 6.34 | 5.72 | 6.35 | 0.995 [0.906-1.008] | 6.34 6.35 6.35 6.34 6.33 5.72 6.35 |
| settle50 | 6.34 | 6.30 | 6.35 | 0.996 [0.965-1.011] | 6.35 6.34 6.33 6.34 6.35 6.32 6.30 |
| nostealnext | 6.33 | 5.93 | 6.36 | 0.996 [0.940-1.003] | 6.34 6.34 6.33 6.33 6.30 5.93 6.36 |
| tokio | 5.29 | 5.10 | 5.61 | 0.832 [0.776-0.889] | 5.11 5.20 5.10 5.31 5.29 5.61 5.40 |

## per trip, whole process (median): user µs, system µs, CPU µs, cores, voluntary csw, involuntary csw
| arm | user | sys | cpu | cores | vcsw | ivcsw |
|---|---:|---:|---:|---:|---:|---:|
| main | 5.72 | 48.27 | 53.99 | 8.58 | 0.000 | 0.212 |
| p | 5.69 | 47.99 | 53.69 | 8.43 | 0.000 | 0.224 |
| one | 2.37 | 22.47 | 24.85 | 4.88 | 0.000 | 0.270 |
| one-a2 | 1.07 | 8.79 | 9.87 | 2.33 | 0.000 | 0.073 |
| one-a3 | 1.32 | 10.28 | 11.60 | 3.04 | 0.000 | 0.100 |
| one-a4 | 1.69 | 17.60 | 19.29 | 4.03 | 0.000 | 0.131 |
| a2 | 5.61 | 44.35 | 49.89 | 7.90 | 0.000 | 0.301 |
| a4 | 5.66 | 45.51 | 51.17 | 8.10 | 0.000 | 0.276 |
| spread4 | 5.69 | 48.31 | 53.93 | 8.55 | 0.000 | 0.203 |
| spread999 | 5.72 | 48.93 | 54.65 | 8.55 | 0.000 | 0.201 |
| nolooks | 4.18 | 27.20 | 31.36 | 5.46 | 0.000 | 1.081 |
| settle0 | 5.59 | 48.74 | 54.45 | 8.59 | 0.000 | 0.206 |
| settle50 | 5.73 | 48.13 | 53.88 | 8.51 | 0.000 | 0.201 |
| nostealnext | 4.39 | 49.63 | 53.97 | 8.51 | 0.000 | 0.128 |
| tokio | 1.87 | 24.11 | 25.96 | 5.00 | 0.000 | 0.295 |

### A12. echo, probe arms round 2 (claim echo-probes2): raw/echo-probe2.jsonl

start 2026-11-17 17:27:34 state 17:27:34 load { 7.81 7.41 5.96 }
end 2026-11-17 17:28:29 state 17:28:29 load { 8.04 7.50 6.08 }

## echo (µs each)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 6.40 | 6.35 | 6.58 | 1.000 [1.000-1.000] | 6.58 6.40 6.39 6.35 6.42 6.38 6.45 |
| p | 6.36 | 6.36 | 6.39 | 0.994 [0.969-1.006] | 6.38 6.36 6.36 6.39 6.37 6.36 6.36 |
| nolooks | 5.72 | 5.54 | 6.07 | 0.895 [0.867-0.945] | 5.79 5.75 5.72 5.70 6.07 5.54 5.66 |
| nolooks-a3 | 5.49 | 5.45 | 5.82 | 0.860 [0.847-0.884] | 5.82 5.60 5.48 5.45 5.63 5.49 5.46 |
| nolooks-a4 | 5.68 | 5.46 | 5.74 | 0.883 [0.841-0.900] | 5.54 5.54 5.68 5.71 5.68 5.74 5.46 |
| one-nolooks | 4.82 | 4.79 | 4.89 | 0.750 [0.732-0.767] | 4.82 4.89 4.79 4.87 4.82 4.81 4.80 |
| one-nolooks-a3 | 3.93 | 3.88 | 4.16 | 0.615 [0.589-0.645] | 3.88 3.98 3.93 3.88 3.95 3.90 4.16 |
| one-nolooks-a4 | 4.72 | 4.64 | 4.84 | 0.739 [0.719-0.751] | 4.73 4.64 4.75 4.70 4.71 4.72 4.84 |
| nolooks-spread4 | 5.63 | 5.51 | 5.77 | 0.882 [0.838-0.902] | 5.51 5.77 5.66 5.67 5.59 5.63 5.63 |
| nolooks-settle0 | 5.55 | 5.52 | 5.58 | 0.865 [0.843-0.874] | 5.55 5.57 5.52 5.55 5.53 5.54 5.58 |
| w3 | 3.78 | 3.68 | 3.91 | 0.595 [0.559-0.609] | 3.68 3.72 3.69 3.78 3.91 3.84 3.90 |
| w4 | 4.51 | 4.43 | 4.54 | 0.699 [0.684-0.707] | 4.50 4.43 4.51 4.44 4.54 4.51 4.51 |
| nolooks-w4 | 4.49 | 4.47 | 4.56 | 0.704 [0.681-0.708] | 4.48 4.49 4.53 4.47 4.48 4.52 4.56 |
| tokio | 5.46 | 5.45 | 5.49 | 0.851 [0.830-0.864] | 5.46 5.45 5.47 5.49 5.46 5.49 5.45 |
| tokio-w3 | 3.72 | 3.63 | 4.01 | 0.582 [0.552-0.621] | 3.63 3.72 3.64 3.67 3.85 3.92 4.01 |

## per trip, whole process (median): user µs, system µs, CPU µs, cores, voluntary csw, involuntary csw
| arm | user | sys | cpu | cores | vcsw | ivcsw |
|---|---:|---:|---:|---:|---:|---:|
| main | 5.86 | 49.31 | 55.17 | 8.62 | 0.000 | 0.202 |
| p | 5.79 | 49.79 | 55.58 | 8.73 | 0.000 | 0.195 |
| nolooks | 3.89 | 26.78 | 30.67 | 5.37 | 0.000 | 0.987 |
| nolooks-a3 | 3.46 | 24.17 | 27.58 | 5.03 | 0.000 | 0.903 |
| nolooks-a4 | 3.77 | 25.44 | 29.21 | 5.14 | 0.000 | 0.971 |
| one-nolooks | 1.57 | 17.63 | 19.20 | 3.97 | 0.000 | 0.280 |
| one-nolooks-a3 | 1.06 | 9.31 | 10.36 | 2.64 | 0.000 | 0.144 |
| one-nolooks-a4 | 1.35 | 15.11 | 16.46 | 3.48 | 0.000 | 0.195 |
| nolooks-spread4 | 3.76 | 25.60 | 29.45 | 5.20 | 0.000 | 0.991 |
| nolooks-settle0 | 3.69 | 25.18 | 28.85 | 5.21 | 0.000 | 0.897 |
| w3 | 1.83 | 9.36 | 11.19 | 2.97 | 0.000 | 0.053 |
| w4 | 1.35 | 16.70 | 18.06 | 4.01 | 0.000 | 0.059 |
| nolooks-w4 | 1.32 | 16.49 | 17.78 | 3.96 | 0.000 | 0.075 |
| tokio | 1.96 | 26.27 | 28.22 | 5.16 | 0.000 | 0.294 |
| tokio-w3 | 0.94 | 9.35 | 10.29 | 2.76 | 0.000 | 0.048 |

### A13. bench/net whole, probe arms (claim echo-probes2): raw/net-probe2.jsonl

start 2026-11-17 17:28:29 state 17:28:29 load { 8.04 7.50 6.08 }
end 2026-11-17 17:29:21 state 17:29:21 load { 6.91 7.25 6.07 }

## pingpong (µs each)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 15.66 | 15.37 | 16.72 | 1.000 [1.000-1.000] | 15.63 15.68 15.56 16.72 15.66 15.71 15.37 |
| p | 15.59 | 15.43 | 16.88 | 0.997 [0.987-1.080] | 16.88 15.64 15.55 16.55 15.59 15.50 15.43 |
| nolooks | 15.63 | 15.49 | 16.73 | 1.001 [0.991-1.008] | 15.65 15.55 15.57 16.73 15.63 15.67 15.49 |
| one | 15.53 | 15.45 | 16.20 | 0.992 [0.969-1.019] | 15.45 15.65 15.47 16.20 15.53 15.50 15.66 |
| one-nolooks | 15.76 | 15.55 | 16.72 | 0.999 [0.992-1.082] | 15.76 15.61 15.55 16.68 16.72 15.59 16.63 |
| tokio | 15.07 | 14.89 | 16.43 | 0.967 [0.955-1.050] | 15.11 15.07 14.89 16.19 16.43 15.00 15.03 |

## echo (µs each)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 6.37 | 6.28 | 6.42 | 1.000 [1.000-1.000] | 6.41 6.37 6.34 6.32 6.42 6.39 6.28 |
| p | 6.36 | 6.31 | 6.40 | 0.999 [0.992-1.005] | 6.40 6.36 6.37 6.31 6.38 6.34 6.31 |
| nolooks | 5.64 | 5.59 | 5.71 | 0.886 [0.875-0.902] | 5.68 5.62 5.60 5.64 5.71 5.59 5.67 |
| one | 5.11 | 4.81 | 5.12 | 0.800 [0.761-0.814] | 5.08 5.12 5.11 4.81 5.04 5.11 5.11 |
| one-nolooks | 4.83 | 4.75 | 4.85 | 0.758 [0.750-0.770] | 4.83 4.82 4.75 4.84 4.81 4.85 4.84 |
| tokio | 5.49 | 5.44 | 5.51 | 0.861 [0.849-0.877] | 5.44 5.48 5.51 5.50 5.46 5.49 5.51 |

## connect (µs each)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 51.54 | 50.71 | 56.54 | 1.000 [1.000-1.000] | 50.99 50.71 51.57 52.29 51.54 51.26 56.54 |
| p | 51.46 | 50.68 | 51.90 | 1.003 [0.906-1.015] | 51.47 51.46 51.90 51.79 50.68 51.41 51.24 |
| nolooks | 51.14 | 50.14 | 51.71 | 0.992 [0.903-1.020] | 50.21 51.71 51.44 50.14 51.14 51.51 51.07 |
| one | 51.51 | 50.54 | 51.93 | 1.005 [0.906-1.021] | 51.22 51.79 51.51 50.54 51.93 51.80 51.22 |
| one-nolooks | 51.13 | 49.86 | 52.47 | 0.992 [0.922-1.007] | 51.34 51.04 50.83 52.47 51.13 49.86 52.15 |
| tokio | 63.36 | 62.30 | 64.90 | 1.229 [1.113-1.259] | 62.30 63.24 64.90 63.65 63.36 63.76 62.95 |

### A14. echo's calls per round trip, probe arms: raw/count/p-*

| run | read | EAGAIN | write | kq wait | wait woke | wait t/o | no deadline | look | look hit | change | kick | events | user ev | cond sig | cond wait | calls | µs/read | µs/write | µs/look | µs/change | µs/cond sig | µs/kq wait | µs/cond wait | vcsw | ivcsw | user µs | sys µs | cycles k | instr k | P-core cycles % | intwk | threads active | ran | stole | slept |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| p-plain | 2.002 | 0.001 | 2.000 | 0.189 | 0.176 | 0.013 | 0.000 | 4.620 | 1.509 | 0.226 | 0.222 | 4.225 | 0.222 | 0.000 | 0.000 | 9.04 | 8.65 | 8.92 | 3.16 | 3.42 | 0.00 | 44.1 | 0.0 | 0.000 | 0.191 | 6.14 | 48.99 | 187.5 | 92.8 | 43 | 0.0301 | 10 | 2.01 | 1.25 | 0.69 |
| p-one | 2.003 | 0.002 | 2.000 | 0.235 | 0.234 | 0.001 | 0.019 | 0.109 | 0.094 | 0.217 | 0.213 | 4.216 | 0.213 | 0.000 | 0.000 | 4.56 | 5.34 | 5.49 | 7.25 | 1.64 | 0.00 | 112.4 | 0.0 | 0.000 | 0.278 | 2.63 | 22.80 | 93.5 | 73.7 | 65 | 0.0101 | 10 | 2.01 | 0.60 | 0.31 |
| p-one-a2 | 2.003 | 0.002 | 2.000 | 0.032 | 0.028 | 0.003 | 0.017 | 0.073 | 0.071 | 0.039 | 0.035 | 4.036 | 0.033 | 0.000 | 0.000 | 4.15 | 2.10 | 2.17 | 6.35 | 0.93 | 0.00 | 1059.0 | 0.0 | 0.000 | 0.074 | 1.20 | 8.87 | 41.3 | 67.1 | 94 | 0.0429 | 9 | 2.01 | 0.09 | 0.08 |
| p-one-a4 | 2.002 | 0.001 | 2.000 | 0.076 | 0.073 | 0.003 | 0.041 | 0.069 | 0.067 | 0.081 | 0.077 | 4.079 | 0.076 | 0.000 | 0.000 | 4.23 | 4.23 | 4.36 | 8.88 | 1.29 | 0.00 | 383.6 | 0.0 | 0.000 | 0.142 | 1.89 | 17.54 | 74.5 | 70.3 | 75 | 0.0345 | 10 | 2.01 | 0.34 | 0.13 |
| p-a4 | 2.002 | 0.001 | 2.000 | 0.288 | 0.261 | 0.027 | 0.000 | 4.783 | 1.516 | 0.155 | 0.151 | 4.154 | 0.151 | 0.000 | 0.000 | 9.23 | 8.06 | 8.30 | 2.85 | 3.20 | 0.00 | 43.4 | 0.0 | 0.000 | 0.276 | 6.27 | 46.39 | 179.7 | 94.0 | 44 | 0.0437 | 10 | 2.01 | 1.26 | 0.70 |
| p-spread999 | 2.002 | 0.001 | 2.000 | 0.220 | 0.204 | 0.016 | 0.000 | 4.661 | 1.411 | 0.245 | 0.241 | 4.244 | 0.241 | 0.000 | 0.000 | 9.13 | 8.51 | 8.75 | 3.14 | 3.15 | 0.00 | 42.6 | 0.0 | 0.000 | 0.214 | 6.24 | 49.09 | 188.0 | 93.1 | 43 | 0.0333 | 10 | 2.01 | 1.27 | 0.69 |
| p-nolooks | 2.002 | 0.001 | 2.000 | 0.886 | 0.808 | 0.078 | 0.000 | 1.766 | 0.698 | 0.406 | 0.401 | 4.404 | 0.401 | 0.000 | 0.000 | 7.06 | 5.34 | 5.54 | 1.20 | 1.77 | 0.00 | 32.7 | 0.0 | 0.000 | 0.970 | 4.24 | 26.39 | 109.7 | 90.4 | 60 | 0.0862 | 10 | 2.01 | 0.75 | 1.22 |
| p-settle0 | 2.002 | 0.001 | 2.000 | 0.187 | 0.187 | 0.000 | 0.000 | 4.571 | 1.544 | 0.228 | 0.223 | 4.227 | 0.223 | 0.000 | 0.000 | 8.99 | 8.59 | 8.83 | 3.33 | 3.39 | 0.00 | 47.1 | 0.0 | 0.000 | 0.178 | 6.16 | 49.85 | 190.3 | 92.5 | 42 | 0.0169 | 10 | 2.01 | 1.24 | 0.71 |
| p-nostealnext | 2.002 | 0.001 | 2.000 | 0.119 | 0.109 | 0.010 | 0.000 | 4.458 | 1.584 | 0.170 | 0.166 | 4.169 | 0.166 | 0.000 | 0.000 | 8.75 | 8.91 | 9.15 | 3.52 | 3.50 | 0.00 | 65.2 | 0.0 | 0.000 | 0.123 | 4.92 | 50.82 | 189.4 | 86.5 | 42 | 0.0278 | 10 | 2.01 | 1.16 | 0.71 |
| p-nolooks-a3 | 2.003 | 0.002 | 2.000 | 0.765 | 0.652 | 0.113 | 0.000 | 1.479 | 0.598 | 0.161 | 0.157 | 4.160 | 0.157 | 0.000 | 0.000 | 6.41 | 5.01 | 5.15 | 1.11 | 1.52 | 0.00 | 38.8 | 0.0 | 0.000 | 0.854 | 3.72 | 23.52 | 98.8 | 86.2 | 64 | 0.1210 | 10 | 2.01 | 0.71 | 0.99 |
| p-one-nolooks | 2.003 | 0.002 | 2.000 | 0.209 | 0.206 | 0.003 | 0.116 | 0.071 | 0.071 | 0.210 | 0.206 | 4.209 | 0.206 | 0.000 | 0.000 | 4.49 | 4.13 | 4.26 | 6.58 | 1.54 | 0.00 | 145.4 | 0.0 | 0.000 | 0.280 | 1.78 | 17.47 | 73.7 | 72.4 | 75 | 0.0097 | 10 | 2.01 | 0.51 | 0.27 |
| p-one-nolooks-a3 | 2.003 | 0.002 | 2.000 | 0.113 | 0.110 | 0.003 | 0.088 | 0.071 | 0.071 | 0.113 | 0.109 | 4.112 | 0.109 | 0.000 | 0.000 | 4.30 | 2.21 | 2.23 | 6.85 | 0.76 | 0.00 | 260.7 | 0.0 | 0.000 | 0.145 | 1.12 | 9.35 | 42.8 | 68.6 | 97 | 0.0247 | 5 | 2.01 | 0.29 | 0.17 |

### A15. bench/http closed loop, probe arms (claim http-probes): raw/http-probe1.jsonl

start 2026-11-17 17:32:02 state 17:32:02 load { 5.82 6.93 6.13 }
end 2026-11-17 17:36:21 state 17:36:21 load { 10.78 8.95 7.22 }

| arm | median req/s | best | min | /main paired median [min-max] | p50 µs | p99 µs | rounds (k req/s) |
|---|---:|---:|---:|---|---:|---:|---|
| main | 166611 | 171816 | 164568 | 1.000 [1.000-1.000] | 379 | 574 | 171.8 166.4 164.6 166.8 168.2 165.1 |
| p | 168567 | 171192 | 166364 | 1.012 [0.989-1.037] | 375 | 567 | 171.2 168.0 167.0 169.1 166.4 171.1 |
| spread2 | 169485 | 173729 | 165381 | 1.011 [0.990-1.050] | 369 | 573 | 173.7 168.1 170.8 165.4 166.4 173.3 |
| spread4 | 173223 | 178198 | 170220 | 1.045 [0.991-1.060] | 363 | 557 | 170.2 171.2 173.0 173.4 178.2 174.5 |
| spread8 | 174386 | 175992 | 169884 | 1.040 [1.010-1.058] | 360 | 550 | 176.0 176.0 170.6 174.1 169.9 174.6 |
| spread999 | 171886 | 178968 | 168774 | 1.032 [1.003-1.084] | 366 | 553 | 175.3 171.7 170.6 172.1 168.8 179.0 |
| a2 | 187837 | 189399 | 178615 | 1.124 [1.040-1.148] | 335 | 502 | 178.6 186.3 188.9 188.2 187.4 189.4 |
| a3 | 181996 | 182528 | 176654 | 1.085 [1.061-1.104] | 347 | 521 | 182.2 182.5 176.7 181.8 181.7 182.2 |
| a4 | 175581 | 178313 | 174230 | 1.056 [1.020-1.072] | 359 | 548 | 175.2 178.3 176.0 174.2 175.2 176.3 |
| nolooks | 176402 | 178858 | 175112 | 1.057 [1.025-1.079] | 356 | 538 | 176.1 178.9 177.6 175.1 176.7 175.6 |
| nostealnext | 168438 | 170786 | 163656 | 1.001 [0.981-1.026] | 373 | 559 | 169.9 168.1 168.8 163.7 170.8 163.9 |
| hyper | 173192 | 178729 | 166426 | 1.045 [0.990-1.071] | 363 | 567 | 173.2 173.3 172.7 178.7 166.4 173.2 |

| arm | server user µs/req | server sys | server cores | server vcsw/req | server ivcsw/req | load user µs/req | load sys | load cores | load vcsw/req | load ivcsw/req | all cores |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 2.60 | 14.08 | 2.78 | 0.000 | 0.417 | 3.82 | 18.20 | 3.66 | 0.000 | 1.023 | 6.44 |
| p | 2.53 | 13.60 | 2.71 | 0.000 | 0.417 | 3.78 | 18.07 | 3.69 | 0.000 | 1.017 | 6.40 |
| spread2 | 2.32 | 12.92 | 2.59 | 0.000 | 0.367 | 3.71 | 17.75 | 3.65 | 0.000 | 0.989 | 6.24 |
| spread4 | 2.06 | 12.06 | 2.45 | 0.000 | 0.336 | 3.70 | 17.78 | 3.72 | 0.000 | 0.978 | 6.17 |
| spread8 | 1.97 | 11.85 | 2.41 | 0.000 | 0.301 | 3.69 | 17.75 | 3.74 | 0.000 | 0.966 | 6.15 |
| spread999 | 2.15 | 12.28 | 2.46 | 0.000 | 0.332 | 3.71 | 17.83 | 3.72 | 0.000 | 0.978 | 6.18 |
| a2 | 1.24 | 8.22 | 1.78 | 0.000 | 0.135 | 3.75 | 17.06 | 3.92 | 0.000 | 1.024 | 5.70 |
| a3 | 1.66 | 9.54 | 2.04 | 0.000 | 0.225 | 3.65 | 17.41 | 3.83 | 0.000 | 0.942 | 5.87 |
| a4 | 1.95 | 11.06 | 2.29 | 0.000 | 0.285 | 3.61 | 17.64 | 3.74 | 0.000 | 0.930 | 6.02 |
| nolooks | 1.78 | 11.51 | 2.34 | 0.000 | 0.386 | 3.81 | 17.71 | 3.80 | 0.000 | 1.035 | 6.14 |
| nostealnext | 2.30 | 13.54 | 2.67 | 0.000 | 0.427 | 3.79 | 18.10 | 3.67 | 0.000 | 1.044 | 6.34 |
| hyper | 2.82 | 12.33 | 2.62 | 0.000 | 0.342 | 3.78 | 17.62 | 3.69 | 0.000 | 0.991 | 6.31 |

### A16. confirm, bench/net whole, plain builds, 15 rounds (claim net-confirm): raw/net-confirm.jsonl

start 2026-11-17 17:44:02 state 17:44:02 load { 1.84 4.94 6.04 }
end 2026-11-17 17:46:27 state 17:46:27 load { 4.24 4.70 5.77 } |  35.3% /System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd

## pingpong (µs each)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 15.55 | 15.11 | 17.00 | 1.000 [1.000-1.000] | 15.49 15.49 15.55 15.11 15.34 15.20 15.57 15.19 15.54 16.08 15.61 15.55 17.00 16.73 15.61 |
| mainB | 15.48 | 14.23 | 16.44 | 0.999 [0.908-1.018] | 14.23 14.85 15.53 14.93 15.49 15.48 15.78 15.34 15.48 15.07 15.68 15.65 15.43 16.44 15.73 |
| nl | 15.43 | 14.81 | 17.64 | 1.003 [0.918-1.133] | 14.88 14.95 15.35 15.27 15.43 15.36 17.64 15.32 15.81 14.81 15.69 15.60 15.62 15.67 15.55 |
| nl-one | 15.48 | 14.43 | 16.76 | 1.004 [0.904-1.078] | 14.43 15.17 15.35 15.55 15.40 15.44 16.12 15.45 15.51 16.39 16.20 16.76 15.37 16.74 15.48 |
| nl-off | 15.47 | 14.55 | 17.42 | 0.995 [0.939-1.093] | 14.55 15.19 15.47 16.52 15.10 15.53 16.33 15.41 15.34 15.14 16.84 15.69 16.76 17.42 15.41 |
| tokio | 14.99 | 13.99 | 16.30 | 0.967 [0.871-1.069] | 14.99 14.97 14.90 16.15 14.85 15.08 16.13 15.66 13.99 15.01 16.30 14.92 14.81 16.05 14.98 |
| go | 16.16 | 15.09 | 17.37 | 1.039 [0.957-1.112] | 15.09 15.74 16.07 16.28 16.00 16.90 16.12 16.08 17.26 15.87 17.17 16.16 16.27 17.37 16.30 |

## echo (µs each)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 6.37 | 6.33 | 6.41 | 1.000 [1.000-1.000] | 6.38 6.34 6.37 6.33 6.38 6.39 6.36 6.38 6.34 6.35 6.36 6.37 6.41 6.39 6.39 |
| mainB | 6.37 | 6.30 | 6.44 | 1.002 [0.987-1.009] | 6.41 6.31 6.39 6.37 6.40 6.44 6.30 6.31 6.40 6.37 6.33 6.33 6.33 6.41 6.38 |
| nl | 5.66 | 5.60 | 5.76 | 0.888 [0.876-0.904] | 5.60 5.66 5.76 5.62 5.68 5.61 5.68 5.62 5.61 5.62 5.69 5.66 5.66 5.67 5.76 |
| nl-one | 4.82 | 4.62 | 4.88 | 0.759 [0.729-0.764] | 4.88 4.82 4.84 4.80 4.84 4.80 4.81 4.85 4.84 4.62 4.71 4.82 4.83 4.81 4.87 |
| nl-off | 6.40 | 6.33 | 6.54 | 1.001 [0.992-1.031] | 6.36 6.35 6.34 6.43 6.36 6.40 6.38 6.41 6.54 6.35 6.41 6.44 6.41 6.33 6.41 |
| tokio | 5.45 | 5.19 | 5.48 | 0.854 [0.818-0.864] | 5.44 5.48 5.38 5.46 5.47 5.47 5.45 5.35 5.41 5.19 5.41 5.46 5.46 5.45 5.48 |
| go | 5.94 | 5.90 | 6.07 | 0.934 [0.923-0.956] | 5.94 5.92 5.91 5.92 5.92 5.90 5.94 5.97 6.00 6.07 5.98 5.90 5.95 5.96 6.04 |

## connect (µs each)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 51.03 | 48.99 | 53.50 | 1.000 [1.000-1.000] | 49.88 51.17 51.03 50.70 49.94 51.19 51.53 51.57 48.99 49.98 51.40 50.43 50.12 53.41 53.50 |
| mainB | 51.26 | 48.73 | 57.51 | 1.001 [0.965-1.077] | 50.30 49.58 49.25 51.58 50.49 51.26 51.42 51.38 51.96 48.73 50.93 52.84 50.60 57.51 52.27 |
| nl | 51.45 | 48.56 | 52.41 | 1.005 [0.949-1.050] | 49.47 48.56 51.17 51.90 51.42 50.64 52.41 51.54 51.45 50.23 51.82 51.66 51.38 52.31 52.21 |
| nl-one | 51.40 | 47.50 | 52.57 | 0.997 [0.924-1.063] | 48.90 50.16 52.04 52.57 49.97 50.44 51.44 51.40 52.09 48.69 47.50 51.38 51.57 52.06 51.85 |
| nl-off | 50.92 | 50.47 | 52.47 | 1.010 [0.947-1.047] | 50.47 50.92 51.41 52.47 50.84 51.92 50.79 50.89 51.29 50.49 50.95 51.91 51.58 50.66 50.66 |
| tokio | 62.81 | 61.69 | 63.87 | 1.231 [1.175-1.292] | 62.24 62.75 62.81 62.33 62.50 63.28 62.58 62.87 63.29 61.69 62.83 63.15 63.56 62.75 63.87 |
| go | 62.00 | 59.13 | 63.88 | 1.223 [1.149-1.256] | 61.68 62.78 63.88 62.00 59.22 61.67 60.41 62.12 61.18 59.13 62.90 62.51 62.93 61.39 62.28 |

### A17. echo's calls per round trip, the nl build: raw/count/nl*

| run | read | EAGAIN | write | kq wait | wait woke | wait t/o | no deadline | look | look hit | change | kick | events | user ev | cond sig | cond wait | calls | µs/read | µs/write | µs/look | µs/change | µs/cond sig | µs/kq wait | µs/cond wait | vcsw | ivcsw | user µs | sys µs | cycles k | instr k | P-core cycles % | intwk | threads active | ran | stole | slept |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| nl | 2.002 | 0.001 | 2.000 | 0.864 | 0.776 | 0.088 | 0.000 | 1.992 | 0.751 | 0.391 | 0.386 | 4.389 | 0.386 | 0.000 | 0.000 | 7.25 | 5.60 | 5.82 | 1.25 | 1.83 | 0.00 | 33.3 | 0.0 | 0.000 | 0.958 | 4.46 | 27.85 | 114.5 | 91.3 | 59 | 0.0968 | 10 | 2.01 | 0.85 | 1.10 |
| nl-one | 2.003 | 0.002 | 2.000 | 0.242 | 0.241 | 0.001 | 0.012 | 0.080 | 0.078 | 0.245 | 0.241 | 4.245 | 0.241 | 0.000 | 0.000 | 4.57 | 4.60 | 4.75 | 7.34 | 1.58 | 0.00 | 114.7 | 0.0 | 0.000 | 0.320 | 1.98 | 19.46 | 79.5 | 73.5 | 68 | 0.0084 | 10 | 2.01 | 0.59 | 0.30 |

### A18. confirm, bench/http closed loop, plain builds, 15 rounds (claim http-confirm): raw/http-confirm.jsonl

start 2026-11-17 17:47:50 state 17:47:50 load { 5.28 5.27 5.91 }
end 2026-11-17 17:53:13 state 17:53:13 load { 10.50 8.84 7.39 } |  91.7% /System/Library/PrivateFrameworks/MediaAnalysis.framework/Versions/A/mediaanalysisd

| arm | median req/s | best | min | /main paired median [min-max] | p50 µs | p99 µs | rounds (k req/s) |
|---|---:|---:|---:|---|---:|---:|---|
| main | 167854 | 173199 | 165294 | 1.000 [1.000-1.000] | 375 | 573 | 171.1 167.3 167.1 167.8 166.8 166.8 169.3 170.8 167.5 169.4 169.2 165.3 168.2 167.9 173.2 |
| mainB | 167404 | 171914 | 162552 | 0.995 [0.939-1.027] | 377 | 576 | 168.0 167.4 168.2 166.7 166.4 166.0 167.1 167.4 171.9 168.6 167.9 164.8 164.1 169.7 162.6 |
| nl | 176172 | 178776 | 171998 | 1.048 [1.015-1.069] | 357 | 538 | 175.5 178.8 175.2 176.5 174.2 174.7 177.3 176.8 176.2 177.6 178.5 172.0 177.5 176.0 175.7 |
| nl-off | 167098 | 175876 | 162632 | 0.999 [0.972-1.041] | 377 | 572 | 167.1 162.6 173.4 174.6 165.8 166.7 167.0 174.5 167.8 166.5 169.7 168.1 166.1 166.4 175.9 |
| nl-spread8 | 182415 | 183770 | 178997 | 1.085 [1.037-1.112] | 343 | 537 | 181.7 183.7 182.7 182.1 182.3 182.8 180.7 182.4 179.0 180.1 183.5 183.8 182.4 182.6 179.7 |
| hyper | 172999 | 176456 | 171324 | 1.033 [1.010-1.068] | 364 | 568 | 175.0 173.0 173.0 172.6 172.8 172.4 172.7 173.5 174.9 171.5 171.3 176.5 174.3 174.0 174.9 |

| arm | server user µs/req | server sys | server cores | server vcsw/req | server ivcsw/req | load user µs/req | load sys | load cores | load vcsw/req | load ivcsw/req | all cores |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 2.54 | 13.71 | 2.74 | 0.000 | 0.414 | 3.78 | 18.10 | 3.68 | 0.000 | 1.022 | 6.41 |
| mainB | 2.63 | 13.99 | 2.78 | 0.000 | 0.415 | 3.79 | 18.07 | 3.64 | 0.000 | 1.018 | 6.42 |
| nl | 1.79 | 11.55 | 2.35 | 0.000 | 0.371 | 3.79 | 17.65 | 3.78 | 0.000 | 1.031 | 6.13 |
| nl-off | 2.58 | 13.85 | 2.75 | 0.000 | 0.422 | 3.79 | 18.01 | 3.68 | 0.000 | 1.032 | 6.42 |
| nl-spread8 | 1.40 | 10.34 | 2.13 | 0.000 | 0.231 | 3.70 | 17.29 | 3.84 | 0.000 | 0.990 | 5.97 |
| hyper | 2.83 | 12.32 | 2.62 | 0.000 | 0.340 | 3.79 | 17.57 | 3.70 | 0.000 | 0.986 | 6.32 |

### A19. bench/mixed open loop, the risk row (claim mixed-risk): raw/mixed.jsonl

```

60000 req/s offered
          runs                req/s                  p50                  p99                p99.9                  max                / p99            /hash p99            srv cores
rig-main     4        59999 (59999)        45 us (45 us)      115 us (107 us)      882 us (796 us)    1231 us (1217 us)       101 us (92 us)      132 us (118 us)            0.9 (0.9)
rig-mainB    4        59999 (59999)        45 us (45 us)      117 us (116 us)      871 us (830 us)    1192 us (1142 us)      101 us (101 us)      133 us (133 us)            0.9 (0.9)
rig-nl       4        59999 (59999)        44 us (44 us)      180 us (115 us)      846 us (808 us)    1258 us (1112 us)       168 us (98 us)      212 us (131 us)            0.9 (0.9)
rig-nl8      4        59999 (59999)        41 us (41 us)      189 us (183 us)      931 us (897 us)    1242 us (1181 us)      178 us (176 us)      214 us (208 us)            0.8 (0.8)
tokio        4        59999 (59999)        45 us (45 us)      192 us (130 us)      908 us (866 us)    1310 us (1268 us)      183 us (124 us)      224 us (141 us)            1.0 (1.0)

100000 req/s offered
          runs                req/s                  p50                  p99                p99.9                  max                / p99            /hash p99            srv cores
rig-main     4        99998 (99999)        57 us (55 us)      287 us (265 us)      929 us (907 us)    1520 us (1481 us)      272 us (255 us)      327 us (297 us)            1.9 (1.8)
rig-mainB    4        99998 (99999)        57 us (56 us)      484 us (289 us)     1044 us (925 us)    2160 us (1477 us)      472 us (277 us)      519 us (320 us)            1.9 (1.8)
rig-nl       4        99998 (99999)        68 us (68 us)      345 us (315 us)      968 us (946 us)    1469 us (1465 us)      334 us (306 us)      371 us (340 us)            1.7 (1.7)
rig-nl8      4        99998 (99998)        96 us (96 us)      466 us (312 us)     1027 us (978 us)    1573 us (1553 us)      457 us (301 us)      494 us (345 us)            1.5 (1.4)
tokio        4        99998 (99999)        61 us (60 us)      404 us (354 us)     1006 us (958 us)    1721 us (1630 us)      389 us (342 us)      440 us (386 us)            2.2 (2.2)
```

### A20. the look-gap arms, bench/net whole, 7 rounds (claim look-gap; a busier Mac): raw/net-gap.jsonl

start 2026-11-17 18:11:25 state 18:11:25 load { 2.27 4.17 5.40 } |  28.7% /Applications/Visual |  23.2% /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
end 2026-11-17 18:12:34 state 18:12:34 load { 5.13 4.75 5.52 }

## pingpong (µs each)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 15.84 | 15.47 | 28.17 | 1.000 [1.000-1.000] | 16.31 15.84 15.74 28.17 15.84 15.89 15.47 |
| nl | 15.97 | 14.53 | 26.92 | 1.014 [0.891-1.116] | 14.53 15.82 15.97 26.92 17.68 16.33 15.72 |
| g10 | 15.92 | 15.66 | 17.88 | 1.004 [0.563-1.156] | 16.50 15.77 15.66 15.85 15.92 15.95 17.88 |
| g20 | 15.85 | 15.56 | 17.37 | 0.995 [0.577-1.086] | 17.37 15.56 15.67 16.25 15.85 15.71 16.80 |
| g50 | 16.06 | 15.64 | 18.26 | 1.003 [0.613-1.160] | 15.64 15.88 18.26 17.28 15.90 16.06 17.22 |
| p3off | 15.95 | 15.73 | 17.84 | 1.007 [0.604-1.133] | 15.90 15.95 17.84 17.01 15.90 16.02 15.73 |
| tokio | 15.34 | 15.07 | 16.55 | 0.963 [0.537-1.044] | 15.69 15.50 15.07 15.14 16.55 15.30 15.34 |

## echo (µs each)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 6.45 | 6.35 | 6.85 | 1.000 [1.000-1.000] | 6.35 6.49 6.40 6.85 6.43 6.45 6.45 |
| nl | 5.84 | 5.44 | 6.35 | 0.901 [0.846-0.983] | 5.72 5.84 5.84 6.14 5.44 6.35 5.85 |
| g10 | 6.28 | 6.21 | 6.64 | 0.981 [0.963-0.989] | 6.28 6.28 6.28 6.64 6.33 6.38 6.21 |
| g20 | 6.19 | 6.09 | 6.28 | 0.954 [0.906-0.988] | 6.28 6.19 6.14 6.21 6.26 6.09 6.12 |
| g50 | 5.90 | 5.76 | 6.13 | 0.909 [0.894-0.940] | 5.96 5.89 5.90 6.13 5.76 5.84 6.06 |
| p3off | 6.49 | 6.41 | 7.07 | 1.014 [1.001-1.077] | 6.41 6.99 6.49 7.07 6.43 6.46 6.56 |
| tokio | 5.51 | 5.37 | 5.93 | 0.854 [0.783-0.934] | 5.93 5.39 5.47 5.37 5.53 5.51 5.54 |

## connect (µs each)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 53.54 | 51.55 | 130.73 | 1.000 [1.000-1.000] | 51.55 53.26 53.54 130.73 53.76 52.04 56.74 |
| nl | 52.43 | 50.37 | 54.58 | 0.977 [0.401-1.020] | 50.37 52.03 54.58 52.43 52.10 52.92 54.19 |
| g10 | 52.35 | 51.78 | 75.25 | 0.994 [0.398-1.326] | 52.73 52.08 53.22 52.07 52.35 51.78 75.25 |
| g20 | 52.05 | 51.43 | 54.18 | 0.966 [0.407-1.013] | 52.23 51.43 52.05 53.24 51.94 51.63 54.18 |
| g50 | 52.99 | 50.79 | 77.40 | 0.967 [0.592-1.071] | 50.79 51.52 57.34 77.40 51.76 52.99 54.65 |
| p3off | 53.00 | 50.92 | 57.95 | 0.990 [0.411-1.078] | 52.93 52.81 53.00 53.79 57.95 50.92 53.95 |
| tokio | 63.62 | 62.53 | 64.92 | 1.195 [0.484-1.234] | 62.53 63.62 64.46 63.22 63.30 64.20 64.92 |

### A21. the look-gap arms, bench/http closed loop, 6 rounds (claim look-gap): raw/http-gap.jsonl

start 2026-11-17 18:12:34 state 18:12:34 load { 5.13 4.75 5.52 }
end 2026-11-17 18:14:43 state 18:14:43 load { 10.63 6.99 6.31 } |  24.2% /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer

| arm | median req/s | best | min | /main paired median [min-max] | p50 µs | p99 µs | rounds (k req/s) |
|---|---:|---:|---:|---|---:|---:|---|
| main | 164891 | 168319 | 160517 | 1.000 [1.000-1.000] | 380 | 614 | 168.3 163.5 166.2 163.6 160.5 167.3 |
| nl | 168135 | 174597 | 163649 | 1.027 [0.994-1.064] | 368 | 606 | 174.6 174.0 167.0 169.2 163.6 166.4 |
| g10 | 163545 | 166683 | 152671 | 0.985 [0.933-1.024] | 381 | 651 | 163.8 163.3 161.1 152.7 164.4 166.7 |
| g20 | 163469 | 170396 | 153015 | 0.985 [0.930-1.022] | 379 | 667 | 165.6 161.4 154.6 167.2 153.0 170.4 |
| g50 | 165909 | 168877 | 162191 | 1.006 [0.977-1.031] | 375 | 613 | 168.3 162.2 168.9 168.6 162.6 163.6 |
| hyper | 165563 | 168194 | 156119 | 0.997 [0.939-1.038] | 375 | 693 | 164.8 161.6 156.1 166.3 166.7 168.2 |

| arm | server user µs/req | server sys | server cores | server vcsw/req | server ivcsw/req | load user µs/req | load sys | load cores | load vcsw/req | load ivcsw/req | all cores |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 2.35 | 13.10 | 2.56 | 0.000 | 0.399 | 3.79 | 17.66 | 3.57 | 0.000 | 1.022 | 6.13 |
| nl | 1.84 | 11.73 | 2.30 | 0.000 | 0.387 | 3.79 | 17.39 | 3.60 | 0.000 | 1.022 | 5.90 |
| g10 | 2.21 | 12.71 | 2.43 | 0.000 | 0.379 | 3.77 | 17.40 | 3.47 | 0.000 | 0.978 | 5.90 |
| g20 | 2.07 | 12.25 | 2.38 | 0.000 | 0.373 | 3.73 | 17.14 | 3.39 | 0.000 | 0.960 | 5.77 |
| g50 | 1.97 | 12.02 | 2.32 | 0.000 | 0.384 | 3.79 | 17.34 | 3.53 | 0.000 | 0.996 | 5.85 |
| hyper | 2.85 | 12.38 | 2.51 | 0.000 | 0.345 | 3.80 | 17.22 | 3.48 | 0.000 | 0.978 | 5.99 |

### A22. the look-gap arms, bench/mixed, 3 rounds (claim look-gap): raw/mixed-gap.jsonl

```

60000 req/s offered
          runs                req/s                  p50                  p99                p99.9                  max                / p99            /hash p99            srv cores
rig-main     3        59999 (59999)        46 us (45 us)      635 us (526 us)    1137 us (1028 us)    1569 us (1515 us)      620 us (512 us)      676 us (575 us)            1.0 (1.0)
rig-nl       3        59999 (59999)        48 us (47 us)      751 us (694 us)    1270 us (1176 us)    2721 us (1889 us)      736 us (683 us)      786 us (732 us)            1.0 (1.0)
rig-g10      3        59999 (59999)        46 us (46 us)      684 us (605 us)    1110 us (1047 us)    1637 us (1478 us)      672 us (590 us)      719 us (645 us)            1.0 (0.9)
rig-g20      3        59998 (59999)        47 us (45 us)     2372 us (441 us)    20.6 ms (1004 us)    29.8 ms (1513 us)     2292 us (430 us)     2456 us (472 us)            1.0 (1.0)
rig-g50      3        59999 (59999)        52 us (46 us)     7344 us (523 us)    27.8 ms (1069 us)    31.0 ms (2206 us)     7314 us (512 us)     7424 us (553 us)            1.0 (1.0)
tokio        3        59999 (59999)        47 us (47 us)      671 us (642 us)    1152 us (1117 us)    2036 us (1708 us)      660 us (633 us)      713 us (676 us)            1.0 (1.0)

100000 req/s offered
          runs                req/s                  p50                  p99                p99.9                  max                / p99            /hash p99            srv cores
rig-main     3        99998 (99998)        60 us (57 us)      882 us (804 us)    1698 us (1188 us)    2323 us (2100 us)      869 us (789 us)      918 us (840 us)            1.9 (1.8)
rig-nl       3        99999 (99999)        72 us (70 us)     1030 us (969 us)    3831 us (2031 us)    5500 us (3125 us)     1018 us (959 us)     1057 us (994 us)            1.8 (1.7)
rig-g10      3        99999 (99999)        62 us (60 us)      903 us (778 us)    1412 us (1240 us)    5321 us (2312 us)      890 us (763 us)      946 us (814 us)            1.9 (1.8)
rig-g20      3        99999 (99999)        67 us (65 us)      951 us (747 us)    1279 us (1118 us)    2547 us (1542 us)      937 us (734 us)      985 us (787 us)            1.9 (1.8)
rig-g50      3        99998 (99998)        74 us (72 us)    94.7 ms (1057 us)     105 ms (6825 us)     121 ms (8470 us)    94.7 ms (1046 us)    94.7 ms (1094 us)            1.8 (1.8)
tokio        3        99998 (99999)        62 us (59 us)      856 us (672 us)    1451 us (1114 us)    3006 us (1778 us)      844 us (659 us)      898 us (709 us)            2.2 (2.2)
```

### A23. FINAL on main f03ef5199: bench/net whole, plain builds, 15 rounds (claim echo-final-net): raw/final-net.jsonl

start 2026-11-17 18:34:40 state 18:34:40 load { 2.41 3.85 4.72 }
end 2026-11-17 18:37:06 state 18:37:06 load { 4.99 4.47 4.83 } |  45.0% /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer

## pingpong (µs each)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 15.78 | 15.30 | 17.34 | 1.000 [1.000-1.000] | 15.80 15.30 15.78 15.88 15.65 16.87 15.58 15.45 17.34 17.07 15.79 15.77 15.54 16.80 15.50 |
| aa | 15.71 | 15.04 | 16.76 | 0.997 [0.879-1.043] | 16.43 15.04 15.90 15.71 15.88 15.40 15.54 15.44 15.24 16.76 15.65 15.78 15.67 16.59 16.16 |
| one | 15.61 | 14.66 | 16.93 | 1.000 [0.898-1.089] | 15.49 14.66 15.22 15.49 16.46 16.88 16.77 15.45 15.56 15.80 15.61 16.71 15.58 16.93 16.88 |
| arm | 15.66 | 15.14 | 17.18 | 0.996 [0.888-1.083] | 15.48 15.14 15.71 15.66 15.61 15.82 16.56 15.49 15.40 15.43 16.70 15.41 16.83 17.18 16.00 |
| nl | 15.72 | 15.00 | 16.94 | 0.997 [0.900-1.090] | 15.31 15.00 15.35 16.91 15.25 15.64 16.39 15.53 16.91 15.37 16.64 15.72 16.94 16.82 15.89 |
| tokio | 15.17 | 14.91 | 16.45 | 0.970 [0.881-1.046] | 15.04 14.91 15.09 16.45 15.28 15.17 16.31 14.98 16.40 15.04 16.25 15.22 15.12 16.32 14.91 |
| go | 16.44 | 15.49 | 17.54 | 1.048 [0.939-1.135] | 15.58 15.49 16.78 16.80 16.44 16.15 16.30 17.54 16.28 16.11 17.49 16.77 16.28 17.41 16.48 |

## echo (µs each)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 6.38 | 6.31 | 6.85 | 1.000 [1.000-1.000] | 6.38 6.85 6.38 6.37 6.47 6.44 6.32 6.31 6.36 6.38 6.36 6.33 6.47 6.39 6.39 |
| aa | 6.39 | 6.30 | 6.50 | 1.004 [0.936-1.019] | 6.50 6.41 6.43 6.39 6.43 6.38 6.32 6.36 6.39 6.40 6.41 6.38 6.41 6.38 6.30 |
| one | 5.16 | 5.08 | 5.81 | 0.810 [0.748-0.909] | 5.15 5.12 5.27 5.16 5.33 5.13 5.10 5.11 5.17 5.19 5.09 5.17 5.17 5.08 5.81 |
| arm | 4.95 | 4.84 | 5.24 | 0.771 [0.739-0.819] | 4.88 5.06 4.90 4.97 4.95 5.03 4.90 4.89 4.84 4.89 4.84 4.95 4.98 5.24 5.16 |
| nl | 5.75 | 5.27 | 5.90 | 0.896 [0.824-0.930] | 5.67 5.81 5.62 5.69 5.80 5.84 5.71 5.79 5.63 5.79 5.75 5.88 5.70 5.27 5.90 |
| tokio | 5.48 | 5.32 | 5.58 | 0.858 [0.811-0.875] | 5.58 5.55 5.48 5.53 5.47 5.48 5.48 5.47 5.45 5.53 5.42 5.47 5.55 5.32 5.48 |
| go | 5.96 | 5.82 | 6.01 | 0.932 [0.875-0.948] | 6.00 5.99 5.96 6.01 6.00 5.94 5.95 5.94 5.89 5.97 5.92 6.00 5.97 5.96 5.82 |

## connect (µs each)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 52.14 | 49.96 | 54.73 | 1.000 [1.000-1.000] | 52.29 51.82 53.36 52.48 52.01 49.96 51.49 51.06 52.14 52.74 51.96 52.58 52.00 54.21 54.73 |
| aa | 51.94 | 46.03 | 52.98 | 0.993 [0.875-1.035] | 50.46 51.94 52.65 52.12 51.91 50.55 50.98 52.83 51.63 52.98 51.82 46.03 52.12 52.11 52.02 |
| one | 51.22 | 49.15 | 53.72 | 0.971 [0.946-1.036] | 49.48 53.23 51.38 50.47 50.35 51.27 53.32 51.17 50.16 51.22 49.15 51.05 53.39 53.72 53.29 |
| arm | 51.70 | 49.26 | 57.80 | 0.995 [0.942-1.066] | 49.26 50.50 51.20 52.98 52.58 51.13 52.17 50.78 53.41 51.65 51.53 53.16 51.70 57.80 52.96 |
| nl | 52.23 | 50.70 | 56.31 | 0.997 [0.959-1.055] | 50.79 51.43 56.31 52.34 52.28 51.35 52.06 52.23 52.32 51.83 50.70 51.10 52.75 53.22 52.49 |
| tokio | 63.15 | 56.94 | 65.23 | 1.214 [1.051-1.257] | 62.61 61.91 65.23 63.77 63.15 62.81 63.17 62.84 63.16 59.39 64.19 63.09 63.93 56.94 63.66 |
| go | 62.99 | 61.73 | 64.49 | 1.204 [1.137-1.291] | 61.73 62.38 63.90 62.62 62.36 64.49 62.99 61.77 63.61 63.52 64.03 62.33 63.47 63.02 62.25 |

### A24. FINAL: the Zig ceiling's shapes today beside the arms, echo alone, 9 rounds (claim echo-final-ceiling): raw/final-ceiling.jsonl

start 2026-11-17 18:42:58 state 18:42:58 load { 3.99 5.41 5.21 } |  20.2% /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
end 2026-11-17 18:44:17 state 18:44:17 load { 5.63 5.61 5.31 }

## echo (µs each)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| c1 | 5.82 | 5.72 | 6.18 | 0.907 [0.895-0.958] | 6.02 5.82 6.18 6.04 5.99 5.75 5.80 5.72 5.80 |
| c1+ | 5.51 | 5.39 | 6.03 | 0.857 [0.829-0.943] | 5.63 5.56 5.92 5.51 5.46 5.46 5.39 6.03 5.50 |
| cN2+ | 4.15 | 3.98 | 5.00 | 0.641 [0.620-0.783] | 3.99 3.98 4.01 4.32 4.34 4.20 4.00 5.00 4.15 |
| cN3+ | 3.80 | 3.68 | 4.02 | 0.592 [0.571-0.629] | 3.80 3.68 3.68 4.02 3.80 4.01 3.78 3.84 3.89 |
| cN4+ | 4.76 | 4.62 | 4.97 | 0.737 [0.721-0.779] | 4.70 4.85 4.79 4.90 4.72 4.74 4.62 4.97 4.76 |
| cN5+ | 5.05 | 4.88 | 5.95 | 0.783 [0.751-0.931] | 4.91 5.01 5.05 5.00 5.14 5.06 4.88 5.95 5.18 |
| cN10+ | 5.42 | 5.29 | 7.70 | 0.846 [0.817-1.158] | 5.30 5.43 5.29 7.70 5.42 5.67 5.30 6.16 5.29 |
| cS1+ | 4.09 | 4.02 | 5.48 | 0.638 [0.627-0.823] | 4.03 4.25 4.09 5.48 4.19 4.06 4.02 4.30 4.07 |
| cS2+ | 4.59 | 4.55 | 6.22 | 0.716 [0.709-0.964] | 4.59 4.55 6.22 4.92 4.59 4.56 4.58 4.57 5.57 |
| cS3+ | 4.93 | 4.78 | 5.65 | 0.775 [0.749-0.872] | 5.09 4.99 4.92 5.28 4.89 4.93 4.93 4.78 5.65 |
| main | 6.42 | 6.37 | 6.65 | 1.000 [1.000-1.000] | 6.42 6.42 6.45 6.65 6.41 6.37 6.40 6.39 6.48 |
| one | 5.21 | 5.10 | 5.97 | 0.813 [0.787-0.937] | 5.19 5.17 5.25 5.66 5.19 5.97 5.21 5.26 5.10 |
| arm | 5.05 | 4.87 | 5.55 | 0.773 [0.760-0.864] | 5.55 4.96 5.08 5.05 4.89 5.10 4.87 5.06 5.01 |
| arm-w3 | 3.91 | 3.77 | 4.12 | 0.611 [0.587-0.647] | 3.91 3.77 4.11 3.91 4.01 4.12 4.10 3.90 3.88 |
| arm-w4 | 4.78 | 4.46 | 5.57 | 0.751 [0.694-0.868] | 4.99 4.46 4.97 4.74 5.57 4.78 4.58 5.04 4.76 |
| tokio | 5.53 | 5.50 | 5.66 | 0.862 [0.836-0.883] | 5.66 5.53 5.50 5.56 5.66 5.51 5.52 5.53 5.51 |
| tokio-w3 | 4.05 | 3.87 | 4.51 | 0.632 [0.603-0.678] | 3.97 3.87 4.09 4.51 4.22 3.94 4.05 4.24 4.04 |

## per trip, whole process (median): user µs, system µs, CPU µs, cores, voluntary csw, involuntary csw
| arm | user | sys | cpu | cores | vcsw | ivcsw |
|---|---:|---:|---:|---:|---:|---:|
| c1 | 0.53 | 5.28 | 5.80 | 1.00 | 0.001 | 0.012 |
| c1+ | 0.36 | 5.16 | 5.50 | 1.00 | 0.001 | 0.012 |
| cN2+ | 0.38 | 7.86 | 8.24 | 1.98 | 0.001 | 0.021 |
| cN3+ | 0.50 | 9.99 | 10.48 | 2.75 | 0.001 | 0.172 |
| cN4+ | 0.51 | 17.92 | 18.43 | 3.85 | 0.001 | 0.072 |
| cN5+ | 0.64 | 19.33 | 19.97 | 3.93 | 0.001 | 0.347 |
| cN10+ | 0.84 | 20.95 | 21.78 | 4.04 | 0.001 | 1.119 |
| cS1+ | 0.38 | 7.68 | 8.05 | 1.97 | 0.001 | 0.029 |
| cS2+ | 0.49 | 17.27 | 17.74 | 3.84 | 0.001 | 0.094 |
| cS3+ | 0.70 | 19.18 | 19.88 | 3.99 | 0.001 | 0.566 |
| main | 5.57 | 45.12 | 50.54 | 7.94 | 0.000 | 0.280 |
| one | 2.41 | 22.54 | 24.95 | 4.74 | 0.000 | 0.290 |
| arm | 1.73 | 18.90 | 20.65 | 4.09 | 0.000 | 0.306 |
| arm-w3 | 1.05 | 9.68 | 10.72 | 2.73 | 0.000 | 0.120 |
| arm-w4 | 1.51 | 15.62 | 17.14 | 3.51 | 0.000 | 0.170 |
| tokio | 1.88 | 25.50 | 27.39 | 4.96 | 0.000 | 0.293 |
| tokio-w3 | 0.98 | 10.14 | 11.12 | 2.76 | 0.000 | 0.070 |

### A25. FINAL: calls a round trip, the ceiling's shapes and the arms: raw/count/{c*,f-*}

| run | read | EAGAIN | write | kq wait | wait woke | wait t/o | no deadline | look | look hit | change | kick | events | user ev | cond sig | cond wait | calls | µs/read | µs/write | µs/look | µs/change | µs/cond sig | µs/kq wait | µs/cond wait | vcsw | ivcsw | user µs | sys µs | cycles k | instr k | P-core cycles % | intwk | threads active | ran | stole | slept |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| c1p | 2.000 | 0.000 | 2.000 | 0.024 | 0.024 | 0.000 | 0.024 | 0.000 | 0.000 | 0.002 | 0.000 | 2.000 | 0.000 | 0.000 | 0.000 | 4.03 | 1.35 | 1.38 | 0.00 | 0.00 | 0.00 | 8.5 | 0.0 | 0.001 | 0.011 | 0.43 | 5.29 | 23.6 | 60.3 | 98 | 0.0000 | 1 |  |  |  |
| cN3p | 1.980 | 0.000 | 1.980 | 0.888 | 0.888 | 0.000 | 0.888 | 0.000 | 0.000 | 0.002 | 0.000 | 1.980 | 0.000 | 0.000 | 0.000 | 4.85 | 2.50 | 2.61 | 0.00 | 0.00 | 0.00 | 1.6 | 0.0 | 0.001 | 0.133 | 0.70 | 10.15 | 42.8 | 63.0 | 94 | 0.0000 | 3 |  |  |  |
| cN10p | 2.000 | 0.000 | 2.000 | 1.491 | 1.491 | 0.000 | 1.491 | 0.000 | 0.000 | 0.002 | 0.000 | 2.000 | 0.000 | 0.000 | 0.000 | 5.49 | 5.10 | 5.11 | 0.00 | 0.00 | 0.00 | 22.9 | 0.0 | 0.001 | 1.072 | 1.20 | 21.53 | 81.6 | 74.9 | 63 | 0.0000 | 10 |  |  |  |
| cS1p | 2.001 | 0.000 | 2.000 | 0.221 | 0.221 | 0.000 | 0.221 | 0.000 | 0.000 | 0.002 | 0.000 | 2.001 | 0.000 | 0.000 | 0.000 | 4.22 | 1.92 | 2.04 | 0.00 | 0.00 | 0.00 | 1.9 | 0.0 | 0.001 | 0.029 | 0.48 | 7.81 | 33.9 | 60.7 | 99 | 0.0000 | 2 |  |  |  |
| f-main | 2.002 | 0.001 | 2.000 | 0.245 | 0.228 | 0.017 | 0.000 | 4.523 | 1.262 | 0.264 | 0.260 | 4.263 | 0.260 | 0.000 | 0.000 | 9.04 | 8.42 | 8.66 | 2.79 | 3.12 | 0.00 | 49.8 | 0.0 | 0.000 | 0.320 | 6.07 | 44.75 | 173.2 | 93.2 | 44 | 0.0360 | 10 | 2.01 | 1.29 | 0.67 |
| f-one | 2.002 | 0.001 | 2.000 | 0.209 | 0.208 | 0.002 | 0.000 | 0.089 | 0.081 | 0.193 | 0.189 | 4.192 | 0.189 | 0.000 | 0.000 | 4.49 | 5.24 | 5.38 | 8.52 | 1.70 | 0.00 | 129.3 | 0.0 | 0.000 | 0.281 | 2.56 | 21.78 | 89.2 | 73.2 | 64 | 0.0113 | 10 | 2.01 | 0.55 | 0.27 |
| f-arm | 2.002 | 0.002 | 2.000 | 0.210 | 0.208 | 0.002 | 0.021 | 0.072 | 0.071 | 0.213 | 0.208 | 4.212 | 0.208 | 0.000 | 0.000 | 4.50 | 4.50 | 4.62 | 7.60 | 1.64 | 0.00 | 138.9 | 0.0 | 0.000 | 0.320 | 1.93 | 18.48 | 76.7 | 73.1 | 71 | 0.0095 | 10 | 2.01 | 0.53 | 0.27 |
| f-arm-w3 | 2.003 | 0.002 | 2.000 | 0.062 | 0.062 | 0.000 | 0.000 | 0.074 | 0.073 | 0.065 | 0.061 | 4.064 | 0.061 | 0.000 | 0.000 | 4.20 | 2.32 | 2.40 | 7.86 | 0.79 | 0.00 | 18.4 | 0.0 | 0.000 | 0.130 | 1.16 | 9.70 | 43.4 | 67.9 | 95 | 0.0280 | 3 | 2.01 | 0.18 | 0.09 |
| f-tokio | 3.001 | 1.000 | 4.000 | 0.052 | 0.052 | 0.000 | 0.052 | 0.031 | 0.030 | 0.001 | 0.000 | 4.012 | 0.001 | 0.175 | 0.175 | 7.43 | 4.27 | 3.18 | 12.63 | 0.00 | 1.26 | 13.3 | 186.7 | 0.000 | 0.296 | 2.07 | 25.29 | 98.0 | 79.0 | 58 | 0.0003 | 10 |  |  |  |

### A26. FINAL: bench/tasks' program, plain builds, 15 rounds, ms a run (claim echo-final-tasks): raw/final-tasks.jsonl

start 2026-11-17 18:45:04 state 18:45:04 load { 3.37 5.02 5.10 } |  48.1% /Applications/Google |  32.2% /System/Library/PrivateFrameworks/SkyLight.framework/Resources/WindowServer
end 2026-11-17 18:45:26 state 18:45:26 load { 7.29 5.81 5.38 }

## spawn (ms a run)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 15.24 | 12.32 | 16.68 | 1.000 [1.000-1.000] | 12.43 16.68 15.68 14.33 16.00 15.54 14.50 15.67 16.68 12.32 15.01 14.73 14.69 15.24 16.58 |
| aa | 15.68 | 11.39 | 16.97 | 1.024 [0.917-1.175] | 11.39 16.22 14.82 15.73 16.86 16.80 14.15 15.31 15.68 14.48 14.14 15.80 15.35 16.46 16.97 |
| one | 15.95 | 10.62 | 17.44 | 1.020 [0.708-1.184] | 10.95 17.14 15.95 16.91 15.87 16.83 17.04 15.97 11.92 12.43 10.62 17.44 15.60 16.00 15.69 |
| arm | 15.77 | 12.45 | 18.48 | 1.039 [0.769-1.231] | 12.45 15.77 17.43 15.18 15.83 17.77 15.11 16.59 13.78 12.79 18.48 13.74 17.19 15.81 12.74 |

## chain (ms a run)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 0.59 | 0.57 | 0.78 | 1.000 [1.000-1.000] | 0.78 0.58 0.59 0.59 0.58 0.58 0.60 0.58 0.59 0.59 0.59 0.59 0.57 0.58 0.58 |
| aa | 0.58 | 0.57 | 0.66 | 0.990 [0.855-1.032] | 0.66 0.59 0.58 0.60 0.58 0.58 0.60 0.57 0.58 0.58 0.58 0.58 0.57 0.57 0.60 |
| one | 0.58 | 0.57 | 0.61 | 1.001 [0.757-1.045] | 0.59 0.59 0.61 0.60 0.58 0.58 0.57 0.58 0.58 0.59 0.58 0.58 0.58 0.58 0.57 |
| arm | 0.58 | 0.57 | 0.72 | 0.994 [0.924-1.020] | 0.72 0.59 0.58 0.58 0.57 0.59 0.61 0.58 0.58 0.58 0.57 0.57 0.59 0.58 0.58 |

## fanout (ms a run)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 72.42 | 67.08 | 109.03 | 1.000 [1.000-1.000] | 74.24 74.21 75.65 67.08 69.71 71.23 72.42 71.14 109.03 73.75 79.31 74.93 69.14 71.23 68.71 |
| aa | 72.30 | 67.66 | 79.64 | 1.029 [0.730-1.118] | 71.89 76.47 70.35 71.63 75.35 79.64 71.88 67.66 79.62 76.17 72.30 77.14 71.26 69.50 75.33 |
| one | 72.03 | 68.45 | 83.33 | 1.010 [0.713-1.193] | 83.33 68.89 71.02 80.02 74.21 72.03 76.33 68.45 77.74 76.85 72.84 69.96 69.85 71.65 69.81 |
| arm | 71.25 | 66.61 | 79.39 | 0.975 [0.728-1.062] | 71.26 72.00 66.61 71.25 68.00 69.80 70.29 70.73 79.39 72.30 72.64 75.56 71.80 67.10 69.52 |

## yield (ms a run)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 6.29 | 6.03 | 11.45 | 1.000 [1.000-1.000] | 7.15 6.65 6.14 6.44 6.29 6.09 6.03 6.24 11.45 7.36 6.54 6.45 6.09 6.17 6.14 |
| aa | 6.26 | 5.96 | 7.48 | 0.987 [0.570-1.160] | 6.53 6.34 6.24 6.26 6.42 6.01 6.95 6.16 6.52 6.23 7.12 7.48 5.96 6.15 6.03 |
| one | 6.15 | 5.96 | 7.43 | 0.984 [0.578-1.146] | 6.11 6.55 6.69 6.03 6.40 6.13 6.91 6.15 6.62 6.63 7.43 6.12 6.10 6.04 5.96 |
| arm | 6.30 | 6.00 | 6.83 | 1.011 [0.550-1.111] | 6.00 6.28 6.22 6.33 6.10 6.55 6.29 6.47 6.30 6.76 6.61 6.80 6.17 6.15 6.83 |

## hog (ms a run)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 0.01 | 0.01 | 0.01 | 1.000 [1.000-1.000] | 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 |
| aa | 0.01 | 0.01 | 0.01 | 0.996 [0.681-1.498] | 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 |
| one | 0.01 | 0.01 | 0.01 | 1.028 [0.592-1.438] | 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 |
| arm | 0.01 | 0.01 | 0.01 | 0.986 [0.782-1.436] | 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 |

## produce (ms a run)
| arm | median | min | max | /main paired median [min-max] | rounds |
|---|---:|---:|---:|---|---|
| main | 5.33 | 5.30 | 5.53 | 1.000 [1.000-1.000] | 5.53 5.30 5.31 5.41 5.33 5.35 5.33 5.30 5.32 5.39 5.38 5.31 5.32 5.37 5.34 |
| aa | 5.33 | 5.25 | 5.65 | 1.001 [0.964-1.063] | 5.32 5.36 5.33 5.25 5.34 5.36 5.33 5.32 5.65 5.31 5.34 5.32 5.33 5.31 5.30 |
| one | 5.32 | 5.26 | 5.61 | 0.993 [0.965-1.055] | 5.33 5.32 5.32 5.31 5.29 5.34 5.29 5.26 5.30 5.31 5.27 5.33 5.61 5.32 5.32 |
| arm | 5.33 | 5.29 | 5.44 | 1.000 [0.985-1.021] | 5.44 5.34 5.33 5.36 5.44 5.35 5.30 5.31 5.33 5.41 5.29 5.34 5.33 5.32 5.33 |
