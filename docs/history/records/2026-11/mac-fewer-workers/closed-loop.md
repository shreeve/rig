# bench/http's closed loop on the Mac: a rule that passes hyper, and what it costs (2026-11-17)

A diagnosis and a probe, measured. Nothing here is for merge, no pull request is open, nothing was
pushed. Main is f03ef5199 (#1139). Machine: Apple M5, 4 performance cores (CPUs 6-9) and 6 efficiency
cores (CPUs 0-5), macOS 27.2; hyper 1.12 on Tokio 1.54.1, Go 1.27.3 (the mac-echo session's builds of
bench/http and bench/mixed, copied; the bench sources have not changed since).

- Worktree, left in place: `/Users/shreeve/Data/Code/worktrees/rig/mac-closed-loop`. Branches, each one
  commit on the last, each message saying it is a probe arm and not for merge:
  `probe-closed-c1` 62144fdb3, `probe-closed-c2` 9ccb0a7a3, `probe-closed-c3` 7bba55531 (the switched
  probes, on each other), **`probe-closed-final` c9b42cb9d** (the arm every proof board ran, on main, 97
  lines of `src/sched.zig`), and `probe-closed-final2` 9969c559a (the arm with two repairs section 6
  names; written, never built or measured). The worktree is left on that last branch.
- Scratch (scripts, every raw run, every claim's log, the builds):
  `/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/45a7b8df-588d-46f9-ab76-f1ed2a2c6a62/scratchpad/mcl/`
  (`board.py` closed loop, `open.py` open loop, `prog.py` bench/net and bench/tasks, `summ.py`,
  `osumm.py`, `psumm.py`, `corr.py`, `reg.py`, `stats.py`, `appendix.sh`, `claim*.sh`, `raw/`,
  `arms/`, `rigs/`).
- Every timed run held the Mac's claim (`tools/mac-claim`, claims `mcl-smoke`, `mcl-S1` to `S3`, `T1`,
  `T2`, `U1`, `U2`, `P1` to `P5`; each under its limit); every build ran through `tools/heavy`;
  `~/Data/Code/mumps-compare/.mac-quiet` was absent at each start (the drivers refuse to run with it);
  no pup, no burst, no `pkill`.
- Not repeated, by the coordinator's word: the mac-echo diagnosis's measurements of this row
  (`mac-echo-diagnosis.md` sections 4, 5 and 9, appendix A3, A7-A9, A20-A22): the row re-measured (Rig
  3.2% under hyper), the server's worker count from 1 to 10, the generator's `GOMAXPROCS`, the calls a
  request, the `nl` look rule and the look gap. They are quoted where used.

## The answer in short

**What explains the gap** (the mac-echo counts, and section 2 here). The closed loop is bound by the
Mac's four performance cores, which the generator (3.3-3.7 cores), the kernel's loopback thread and the
server share; the server that uses the least CPU, on the fewest threads, wins. A request costs Rig's
server 5.2 µs of CPU on one worker and 16 µs on ten (hyper: 5.1 and 15), and Rig at ten makes 4.1
system calls a request to hyper's 2.7: 1.0-1.3 looks at other workers' pollers and 0.22 kicks beyond
the read and the write.

**What explains the spread** (new). `http.serve`'s 64 connections do not all sit in worker 0's poller.
Each is registered with the worker the accept loop runs on when it takes it, and the loop's task moves
between workers as the first connections arrive, so a run begins with them split, differently every
run: 44/9/10/3, 52/5/5/4, 53/5/2/6, 32/34, 38/28 (A6, A10). Every worker that got some is then woken by
its own sockets and stays in play, and every sleeper looks at each such poller. Run by run, Rig's
requests a second follow its system calls a request (rank correlation -0.86; 3.6 a request in a 171k
round, 4.5 in a 163k round) and its share of cycles on performance cores (+0.74; A2). hyper has one
driver and makes 2.72-2.80 calls a request in every round, hence its tight range. With every
descriptor in worker 0's poller (the mac-echo arm, `one`) Rig's range closes to hyper's and the row
gains 4% (2.0-4.7% on three boards), level with or just past hyper.

**The trade, and the rule that escapes it on the boards asked for.** Every rule that keeps work on
fewer workers raises the closed loop and raises bench/mixed's p50 at 100,000 a second together, about
1% of requests for 3 µs: waking for work only once it has waited 20 or 50 µs, taking only such work,
no looks, a look gap, one helper at once and the rest late, and three rules keyed on efficiency cores
(section 3: 22 arms). The reason is one fact: at 100,000 a second with one request in four hashing,
worker 0 is inside a 31 µs hash most of the time, and what serves the requests that land meanwhile is
exactly the other workers' eagerness that the closed loop pays for. What tells the two loads apart is
the length of the fibers, so the arm switches on that: **while fewer than a tenth of the fibers of a
worker that holds descriptors run 20 µs or longer, (1) no worker going to sleep looks at its poller
(unless its present fiber has run 20 µs; the watcher still looks every millisecond), and (2) the fibers
a batch of its events makes ready, past the first, wake no worker and are taken by none until they
have waited 50 µs. While a tenth or more run long, every rule is main's.** Mac only, as `settle_wait`
is.

**Its numbers** (plain builds; the Mac was in a slower state for every proof board than for the
standings, with the owner at work on it: main reads 134k where the standings read 166k; section 1):

| row | main | A/A | hyper | **fin** (the arm) | `one` (mac-echo's) | **finone** (both) |
|---|---:|---:|---:|---:|---:|---:|
| closed loop, 15 rounds, median k req/s | 134.2 | 133.5 | 138.3 | **149.7** | 141.4 | **159.6** |
| range | 104.4-139.8 | 106.3-140.1 | 107.0-140.1 | 111.7-157.8 | 107.1-142.6 | 107.6-161.0 |
| against main, paired [range] | 1 | 1.021 [0.911-1.258] | 1.031 | **1.108** [0.940-1.237] | 1.042 | **1.175** [1.007-1.296] |
| against hyper, paired [range] | 0.975 | 0.985 | 1 | **1.074** [0.969-1.134] | 1.018 | **1.151** [0.808-1.187] |
| server CPU a request, µs; cores | 16.5; 2.14 | 16.4; 2.18 | 16.0; 2.22 | 11.2; 1.66 | 14.4; 2.02 | 8.8; 1.39 |
| bench/mixed 100k: cycles a request | 76.4k | 1.005 | 87.4k | 1.005 [0.964-1.027] | | 1.004 |
| bench/mixed 100k: p50 / p99 µs (8 rounds) | 69 / 958 | 70 / 1,012 | 78 / 1,209 | 71 / 1,054 | | 70 / 1,039 |
| bench/mixed 55k, 2 workers: p50 / p99 µs | 42 / 359 | 42 / 369 | 44 / 387 | 42 / 353 | | 42 / 354 |
| bench/mixed 55k, 2 workers: cycles | 62.4k | 1.000 | 64.5k | 1.000 | | 0.997 |
| bench/http open loop 100k: cycles | 32.3k | 1.012 | 35.6k | **0.915** [0.838-0.956] | | 0.934 |
| bench/http open loop 100k: p50 / p99 µs | 23 / 200 | 23 / 343 | 23 / 185 | 22 / **267** | | 23 / 290 |
| bench/net echo | 1 | 1.016 | | **0.881** [0.753-0.941] | 0.750 | 0.728 |
| bench/net ping-pong / connect | 1 | 0.997 / 0.994 | | 1.003 / 0.981 | 1.005 / 0.982 | 1.006 / 0.988 |
| bench/tasks spawn / wake (chain) / yield | 1 | 0.929 / 0.989 / 1.003 | | 0.908 / 0.947 / **1.039** | | 0.889 / 0.949 / 1.023 |

The arm passes hyper by 7.4% alone and by 15.1% with `one`, on a third less server CPU a request;
bench/mixed at 100,000 and at 55,000 on two workers reads as main in cycles, p50 and p99 (there the arm
runs main's rules by construction: a quarter of the fibers are long); the trivial open loop spends 8.5%
fewer cycles; echo is 12% faster; ping-pong and connect are level.

**What it costs, plainly.** (a) The trivial open loop's p99 at 100,000 a second: 250-300 µs in five of
eight rounds against main's 104-299 (median 267 against 200), p50 level; the A/A arm's own rounds
spread 102-2,133 µs, so this is inside the spread and still probably real: a burst waits for its own
worker up to 50 µs before another may take it (section 5, with the shorter waits tried). (b) Two
of fin's 8 rounds and three of finone's on that board had a p99 of 2.7-196 ms against 0 of main's 8,
3 of aa's (1.4-2.1 ms) and 2 of hyper's; this Mac stalls every arm on every board (section 1), but
section 6 names a mechanism by which the arm could add to it, and the guard for it. (c) bench/tasks'
yield is 3.9% slower at the median (A/A 0.3%, its range 0.82-1.19): the arm adds two loads to every
switch; one would do. (d) A program between the two loads (1-10% long fibers) gets the kept rules and
with them a share of the trade measured in section 3. (e) Not run: the unit tests, the core suite,
the light gates, Linux. formal/Models/Sleep.lean's "no worker sleeps while a ring holds work" no
longer holds for a kept batch.

## 1. How quiet the Mac was

Each claim's own wait (all other processes under 150% of a core for 30 s), then the load averages and
every process over 20% of a core as each board began and ended (the `#` lines above each table in the
appendix). The machine was shared all evening with other sessions' claims, builds and gates, and from
about 19:48 with the owner at work on it (VMware Fusion, VS Code, Chrome):

| claim | when | what else ran | main, closed loop |
|---|---|---|---|
| mcl-S1 | 19:09-19:17 | nothing over 20% | 168.0k (hyper 173.8k) |
| mcl-S2, S3 | 19:17-19:28 | `corespotlightd` at 180% as S2 ended | |
| mcl-T1 | 19:38-19:43 | a `zig test` at 100% of a core throughout | 164.0k (hyper 164.4k) |
| mcl-T2 | 20:07-20:12 | WindowServer 29-41%, a VM starting; the generator late (p99 380-540 µs) | |
| mcl-U1, U2 | 20:25-20:36 | `vmware-vmx` at 23%, WindowServer 36-48% | 134.5k (hyper 138.0k) |
| mcl-P1 | 20:46-20:51 | a `zig` at 100% in the first two rounds, `bfs` at 488% in the last | 134.2k (hyper 138.3k) |
| mcl-P5, P2, P3, P4 | 20:52-21:17 | `corespotlightd` at 38% once; otherwise nothing over 20% | |

From U1 on, every arm, hyper included, ran a fifth lower than in S1, with the generator at 23.4-24.4 µs
of CPU a request where it had been 21.3-21.8: the machine, not a server (no thermal or power warning
recorded; a VM was up). So the proof's absolute numbers are not the standings' row; its ratios are
paired by round on one machine state, and S1, on the quiet machine, gives the same ordering for the
probe's forms of the same rules (section 3). Run by run in P1, main's requests a second follow the
share of its cycles on performance cores (rank correlation 0.98) and the generator's (0.91): the two
rounds at 104-109k are the ones `bfs` took the performance cores (24% and 37% of main's cycles on them
against 63-67%; A13).

## 2. The gap and the spread: what the counts add

The mac-echo diagnosis has the calls a request (Rig 3.88, hyper 2.66; looks 1.32 against 0.02), the
worker sweep (one worker: Rig 194.8k, hyper 190.5k; ten: 168.7k, 173.1k) and the generator's
(`GOMAXPROCS` 4: both 4% higher). New here:

**Where the connections wait** (the probe's count of registrations per worker's poller, `reg.py`, A6
and A10). `http.serve` registers each connection "with this worker's poller", the worker its accept
loop is running on, and docs/internals/scheduler.md says they "share the acceptor's poller". They do
not: the loop's task is woken by whichever worker reads the listener's event, a sleeper's look
included, and runs there. Five runs of main's behaviour: `[53 5 0 0 0 0 0 0 2 6]`,
`[55 7 0 0 0 0 0 0 4 0]`, `[44 9 10 3 0 0 0 0 0 0]`, `[52 0 0 5 5 0 0 0 0 4]`, `[53 0 0 0 2 0 0 0 0 11]`
(66 registrations: the listener, a probe connection, 64). The workers that got some run 14-22% of the
fibers each, worker 0 28-31%, and the rest 3-5% each. In bench/mixed the connections are opened one at
a time and all land in worker 0's poller, which is why `one` changes nothing there (A3: cycles 70.2k
against 70.3k, p50 57 and 57).

**Round by round** (A2: the 15 runs of S1 that behave as main, quiet machine):

| | slowest round | | fastest round | rank correlation with req/s |
|---|---:|---|---:|---:|
| requests a second | 162.7k | ... | 171.2k | |
| server CPU a request, µs | 17.6 | | 14.8 | -0.79 |
| server cycles a request | 62.0k | | 53.5k | -0.78 |
| system calls a request | 4.46 | | 3.59 | -0.86 |
| context switches a request | 0.440 | | 0.384 | -0.85 |
| interrupt wake-ups a request | 0.046 | | 0.028 | -0.65 |
| server cycles on performance cores | 54.8% | | 61.1% | +0.74 |
| the busiest thread's share of them | 22.8% | | 29.0% | +0.40 |
| generator CPU a request, µs | 21.9 | | 21.6 | -0.72 |

hyper's five rounds on that board: 2.72-2.80 calls and 14.9-15.2 µs a request in every one, 172.8-174.0k
in four and 167.1k in one. So a 175k Rig round is one where the connections happened to land in few
pollers and worker 0 did more of the work on a performance core; a 159k round is one where four or
five workers each hold some, each is woken by its own, and every sleeper looks at each.

**The scheduler's counters a request** (main's behaviour, probe c2, 164.0k; A7): fibers run 1.00, of
them stolen 0.40; sleeps 0.55, each after a search that found nothing (0.55); kicks 0.224 (0.199 to wake
for work, 0.056 to pass the watch); waits in a poller 0.437, of which 0.272 ended with nothing to run
and 0.122 were the 20 µs settle wait; `kevent64` calls on pollers 1.85, of which 0.77 found events,
2.9 events each; write events 1.00.

**kqueue's write edges: nothing** (loser). Every request brings one `EVFILT_WRITE` event beside its
read event, for Rig and hyper alike (events 2.21 and 2.01 a request, A22): an edge each time the
answer's bytes are acknowledged. Registering for reads only (`RIG_P_NOWRITE=1`, a measurement, not a
design): 168.2k against main's 168.0k, paired 1.001 [0.979-1.031] (A1). The edge arrives with the next
request's read event and costs nothing that shows.

## 3. The probes: every arm

Three builds, each switched by environment variables read as the workers start, each reading as main
with none set (`p`, `p2`, `p3`: closed loop 0.980 [0.951-1.011], 1.000 [0.930-1.020], 1.016
[0.997-1.017] of main; the first carries the mac-echo probe's counters at about 2%). The closed loop is
5 rounds an arm, bench/mixed 3 or 4: screening, not proof.

**Probe c1: wake only for work that has waited** (`RIG_P_AGE=T`: a worker wakes another, at a switch
or as the last searcher, only once work has waited T µs behind what it runs; `s`, `RIG_P_AGESTEAL=1`: a
worker with nothing to do takes only such work and sleeps past the rest; `nl`, `gap20`: the mac-echo
look rules). Quiet machine (A1, A3, A4):

| arm | closed loop, / main [range] | server µs a request | bench/mixed 100k: p50, p99, cycles / main | 55k on 2 workers: p50, cycles / main |
|---|---|---:|---|---|
| main | 168.0k | 16.3 | 57, 341, 1 | 42, 1 |
| aa (layout) | | | 57, 519, 0.997 | 41, 0.994 |
| hyper | 1.034 [0.976-1.052] | 15.0 | 60, 424, 1.144 | 42, 1.013 |
| `one` (every descriptor in worker 0's poller) | 1.041 [0.996-1.064] | 13.7 | 57, 362, 0.995 | 40, 0.985 |
| nowrite | 1.001 [0.979-1.031] | 16.3 | | |
| age 10 | 1.026 [1.013-1.046] | 13.5 | | |
| age 20 | 1.034 [1.012-1.068] | 13.0 | **70**, 362, 0.850 | 38, 0.914 |
| age 50 | 1.082 [1.042-1.102] | 11.9 | **85**, 459, 0.815 | 38, 0.915 |
| age 20, s | 1.024 [0.984-1.065] | 14.3 | **74**, 418, 0.867 | 38, 0.915 |
| age 50, s | 1.097 [1.047-1.122] | 10.8 | **87**, 417, 0.816 | 38, 0.917 |
| gap 20, age 20 | 1.051 [0.988-1.073] | 12.7 | | |
| gap 20, age 20, s | 1.066 [1.046-1.102] | 12.4 | **79**, 411, 0.873 | 38, 0.914 |
| nl | 1.044 [1.020-1.070] | 13.7 | **69**, 390, 0.940 | 42, 1.019 |
| nl, age 20, s | 1.100 [1.077-1.116] | 10.7 | **86**, 443, 0.849 | 40, 0.924 |
| awake 2 (a cap, for reference) | 1.106 [1.071-1.144] | 9.4 | | |

The closed loop rises up to 10% and bench/mixed's p50 at 100,000 rises with it in every arm, with 13-18%
fewer cycles a request; on two workers at 55,000 the same rules lower p50 by 4 µs and cycles by 8.5%.
The p99s are inside the A/A pair's spread (341 and 519).

**Probe c2: rules for a worker on an efficiency core, one helper at once, a look by the owner's run
time** (`eM-T`: `RIG_P_ECORE=6 RIG_P_EMODE=M RIG_P_AGE=T`, the rules holding for a worker while
`pthread_cpu_number_np` puts it on CPUs 0-5: 1, it takes only work that has waited T; 2, going to
sleep it looks at its own poller only; 4, wakes wait T while the last worker woken for work landed on
an efficiency core. `freeK`: K-1 helpers come at once, the rest for work that has waited. `run10`: a
worker going to sleep looks at another's poller only once its worker has run one fiber 10 µs). T1 ran
beside a `zig test` holding one core, T2 with a late generator (A5, A8):

| arm | closed loop, / main [range] | server µs | bench/mixed 100k: p50, p99, cycles / main |
|---|---|---:|---|
| main | 164.0k | 14.9 | 69, 957, 1 |
| aa | | | 71, 1,061, 1.000 |
| hyper | 1.008 [0.992-1.038] | 15.3 | |
| p2 | 1.000 [0.930-1.020] | 15.9 | 69, 967, 0.997 |
| `one` | 1.020 [0.976-1.051] | 14.1 | |
| e1-50 | 0.998 [0.973-1.038] | 14.8 | 70, 984, 0.982 |
| e3-50 | 1.045 [1.020-1.055] | 12.7 | 72, 913, 0.919 |
| e7-50 | 1.062 [1.038-1.086] | 10.6 | **95**, 1,037, 0.818 |
| e7-20 | 1.032 [0.995-1.064] | 11.8 | **82**, 992, 0.866 |
| one, e7-50 | 1.055 [0.982-1.088] | 10.6 | **97**, 952, 0.820 |
| free2, age 50, s | 1.030 [0.988-1.056] | 12.4 | **78**, 998, 0.878 |
| free2, age 50 | 1.018 [0.932-1.026] | 12.4 | 70, 5,589 (2 rounds of 3 over 5 ms), 0.880 |
| free3, age 50, s | 1.003 [0.963-1.010] | 13.9 | **81**, 1,123, 0.977 |
| run10 | 0.993 [0.972-1.011] | 14.3 | 74, 980, 0.991 |
| age 50, s | 1.022 [0.993-1.040] | 12.2 | **99**, 1,016, 0.868 |

Which kind of core a woken worker lands on does not tell the loads apart: in the closed loop 60% of
wakes for work landed on an efficiency core (0.04-0.05 a request against 0.03), and at 100,000 a second
in bench/mixed enough do that the gate holds there too (e7: p50 95). `e3-50`, the two rules that only
restrain a worker while it is itself on an efficiency core, is the one arm before the last that moved
the closed loop (4.5% here, 8.9% in A9) with p50 near the pair (72 against 69 and 71; 80 against 72-79
in A11) and 6-8% fewer cycles: the best trade short of the run-length rule, and it stacks to nothing on
top of it (A9: 1.121 with, 1.136 without).

**Probe c3: the rules only while the fibers are short** (`rL`: `RIG_P_R=1 RIG_P_AGE=50
RIG_P_RLONG=L`: age 50 with s, and no looks at another's poller, only while fewer than a tenth of the
fibers run on descriptor-holding workers ran L µs or longer). The machine in its slower state, and for
U2 with a VM at 23% of a core and stalls in most arms (A9, A11):

| arm | closed loop, / main [range] | server µs | bench/mixed 100k: p50, cycles / main, context switches a request |
|---|---|---:|---|
| main | 134.5k | 16.1 | 72, 1, 0.607 |
| aa | | | 76, 1.007, 0.599 |
| hyper | 1.033 [0.991-1.041] | 15.7 | |
| p3 | 1.016 [0.997-1.017] | 15.4 | 79, 1.019, 0.586 |
| `one` | 1.047 [1.032-1.055] | 13.9 | 74, 1.008, 0.596 |
| r20 | 1.136 [1.077-1.150] | 10.6 | 80, 1.024, 0.588 |
| r10 | 1.021 [1.007-1.033] | 15.3 | 75, 1.010, 0.599 |
| r20, age 20 | 1.123 [1.068-1.144] | 11.5 | 76, 1.013, 0.589 |
| one, r20 | 1.159 [1.145-1.181] | 9.0 | 79, 1.024, 0.596 |
| e3-50 | 1.089 [0.972-1.099] | 11.5 | 80, 0.942, 0.551 |
| one, e3-50 | 1.099 [1.089-1.102] | 11.3 | 80, 0.937, 0.554 |
| r20, e3 | 1.121 [1.104-1.123] | 10.3 | 80, 0.927, 0.556 |
| one, r20, e3 | 1.175 [1.156-1.200] | 8.7 | |
| age 50, s | 1.112 [1.103-1.159] | 10.3 | |

`r20` gains what age 50 with s gains, and at 100,000 a second in bench/mixed it makes main's context
switches and cycles: the rules are off there, as meant. That board's p50s cannot tell arms apart (the
three arms that are main read 72, 76 and 79); the proof's board can (section 5). At `RLONG` 10 the
closed loop's own fibers count as long too often (read, parse, answer, write: 5 µs on a quiet
performance core, more beside nine other workers) and the rule is mostly off: 20 µs is the measure,
between those and the 31 µs hash.

## 4. The arm

`probe-closed-final` c9b42cb9d, on main: 97 lines of `src/sched.zig`, everything under a comptime
`keeps_short` (Darwin), with `arm_one` (the mac-echo arm's one line) beside it, off. Three builds from
that source: `fin` (`keeps_short`), `finone` (both), `one` (`arm_one` alone).

- **The measure.** A worker whose poller holds descriptors reads the clock as it switches to a fiber and
  as the fiber switches back (`runFiber`), and keeps the share of its fibers that ran `long_run` (20 µs)
  or longer, each fiber moving it a 32nd of the way (`Worker.long_share`); a worker "runs short" while
  that is under a tenth (`runsShort`). A worker with no descriptors reads no clock.
- **Rule 1, the looks.** A worker going to sleep (`serviceAll`) skips the poller of another worker that
  runs short, unless that worker has run its present fiber for `long_run` (`Worker.run_since`). The
  watcher's look each `watch_every` takes every poller, as on main.
- **Rule 2, the batch.** When a look or a wait reads a poller whose worker runs short, the fibers its
  events make ready past the first go to the reader's ring as on main, and the ring is marked kept
  from then (`Worker.held_since`): for `help_after` (50 µs) `spread` wakes no worker for it, a
  searching worker passes it by (`search`), a worker going to sleep does not count it as work
  (`hasWork`), and the last searcher wakes no other for it (`workPending`). The mark ends when the
  ring empties, when 50 µs pass, or when any other work joins the ring (a task made, a fiber that
  yields, a fiber pushed out of a "run next" slot), so a task made and waited for is woken for exactly
  as on main.
- Nothing else changes: the kick, `settle_wait`, the watcher, the steal from a "run next" slot, timers.

The reason in one paragraph: a wake costs the waker a system call (1.8 µs under this load) and the
woken worker about 5 µs before it runs, and on this machine it then often runs on an efficiency core,
where the same read and write take two to three times as long; a worker whose fibers each end in about
5 µs reaches the next fiber of its batch, and the next event in its poller, sooner than a woken worker
would. Linux weighs the same thing when a CPU goes idle (it skips pulling work when the CPU's average
idle time is under the cost of migrating). A worker whose fibers run long cannot promise that, so
there help comes at once, as today.

## 5. Proof

Plain builds, no switch, no counters: `main` (f03ef5199), `aa` (main plus a referenced dead function in
`src/sched.zig`, built separately: the layout control), `hyper`, `fin`, `one`, `finone`.

**Closed loop** (64 connections, 3 s, 15 rounds interleaved and rotated, 20:46-20:51; every round in
A12, every run's counters in A13):

| | main | aa | hyper | **fin** | one | **finone** |
|---|---:|---:|---:|---:|---:|---:|
| requests a second, median | 134,178 | 133,487 | 138,294 | **149,698** | 141,377 | **159,571** |
| range | 104,416-139,762 | 106,282-140,127 | 107,041-140,125 | 111,744-157,803 | 107,123-142,591 | 107,556-161,004 |
| against main, paired [range] | 1 | 1.021 [0.911-1.258] | 1.031 [0.912-1.276] | 1.108 [0.940-1.237] | 1.042 [0.930-1.151] | 1.175 [1.007-1.296] |
| against hyper, paired [range] | 0.975 [0.784-1.096] | 0.985 [0.956-1.005] | 1 | 1.074 [0.969-1.134] | 1.018 [0.804-1.183] | 1.151 [0.808-1.187] |
| p50 / p99 µs | 470 / 639 | 470 / 648 | 455 / 636 | 419 / 590 | 445 / 621 | 390 / 575 |
| server CPU a request, µs (user / system) | 16.5 (2.3 / 14.3) | 16.4 (2.4 / 13.9) | 16.0 (2.8 / 13.2) | 11.2 (1.6 / 9.8) | 14.4 (1.9 / 12.5) | 8.8 (1.0 / 7.7) |
| server cores | 2.14 | 2.18 | 2.22 | 1.66 | 2.02 | 1.39 |
| cycles a request | 57.5k | 58.5k | 58.2k | 42.3k | 52.7k | 34.1k |
| of them on performance cores | 64% | 64% | 64% | 73% | 68% | 84% |
| context switches / system calls a request | 0.51 / 4.07 | 0.52 / 4.26 | 0.46 / 2.93 | 0.33 / 3.00 | 0.42 / 3.01 | 0.15 / 2.43 |
| the busiest thread's share of the cycles; threads over 5% | 32%; 5 | 31%; 4 | 11%; 10 | 52%; 3 | 38%; 10 | 70%; 1 |

Rounds, in order (k req/s): main 125.9 136.8 122.8 134.3 134.1 138.8 139.8 137.3 131.6 126.6 137.2 136.0
132.6 104.4 109.4; aa 125.5 124.6 133.5 135.8 139.7 132.6 132.8 135.6 137.4 131.8 133.5 140.1 138.3 131.4
106.3; hyper 124.9 124.8 138.3 139.2 140.1 136.6 135.0 139.6 139.5 137.9 139.6 139.5 139.2 133.2 107.0;
fin 138.5 128.6 150.1 146.8 154.4 153.0 151.2 157.8 149.7 156.4 149.9 149.2 147.8 129.1 111.7; one 129.2
127.2 141.4 141.4 142.3 141.8 142.0 137.6 141.9 135.3 142.6 142.0 139.1 107.1 126.6; finone 139.5 137.8
159.2 158.2 159.4 159.8 160.3 158.6 161.0 160.9 160.9 160.6 160.7 107.6 113.0. The first two rounds ran
beside a `zig` at 100% and the last two beside `bfs` at up to 488%. fin is over hyper in 14 rounds of
15 and over main in 14; finone over hyper in 14 and over main in all 15; `one` over hyper in 11. In the
eleven rounds between (3 to 13) finone reads 158.2-161.0k, a range of 1.8%, fin 146.8-157.8k, hyper
135.0-140.1k, main 122.8-139.8k.

**bench/mixed, open loop** (1 in 4 hashing, 5,000 idle connections, the on-time generator; 8 rounds
each, 20:55-21:06; A16, A17). The generator's lateness column is its own p99 lateness, the floor under
every p99: read it first.

| 100,000 a second, 10 workers | main | aa | hyper | fin | finone |
|---|---:|---:|---:|---:|---:|
| cycles a request | 76.4k | 76.8k | 87.4k | 76.9k | 76.7k |
| against main, paired [range] | 1 | 1.005 [0.974-1.109] | 1.144 [1.098-1.170] | 1.005 [0.964-1.027] | 1.004 [0.973-1.070] |
| p50 µs (rounds) | 69 (64 70 72 69 71 89 67 67) | 70 (65 68 70 71 103 76 71 66) | 78 | 71 (65 70 78 69 79 73 73 67) | 70 (66 70 70 71 77 76 73 67) |
| p99 µs [range] | 958 [751-82,409] | 1,012 [883-173,155] | 1,209 [897-68,243] | 1,054 [843-80,971] | 1,039 [847-3,686] |
| p99.9 µs | 1,272 | 1,977 | 2,024 | 1,717 | 1,945 |
| rounds with p99 over 5 ms | 2 | 1 | 2 | 1 | 0 |
| the generator's lateness, p99 µs | 382 | 393 | 508 | 465 | 456 |
| context switches a request; server cores | 0.599; 2.08 | 0.604; 2.10 | 0.784; 2.46 | 0.603; 2.10 | 0.597; 2.10 |

| 55,000 a second, 2 workers | main | aa | hyper | fin | finone |
|---|---:|---:|---:|---:|---:|
| cycles a request | 62.4k | 62.4k | 64.5k | 62.3k | 62.2k |
| against main, paired [range] | 1 | 1.000 [0.955-1.005] | 1.034 [0.989-1.052] | 1.000 [0.954-1.030] | 0.997 [0.952-1.006] |
| p50 µs | 42 | 42 | 44 | 42 | 42 |
| p99 µs [range] | 359 [333-467] | 369 [246-661] | 387 [255-916] | 353 [276-437] | 354 [261-482] |
| p99.9 µs | 952 | 956 | 986 | 949 | 955 |
| the generator's lateness, p99 µs | 21 | 18 | 16 | 17 | 14 |

Both read as main in every column, inside the A/A pair: there the arm is main's rules, plus two clock
reads a fiber on the workers that hold descriptors, which do not show in the cycles.

**bench/http's server, open loop at 100,000 a second** (every request trivial, no idle connections, 10
workers, 8 rounds, 21:07-21:16; A18):

| | main | aa | hyper | fin | finone |
|---|---:|---:|---:|---:|---:|
| cycles a request [range] | 32.3k [30.4-34.8] | 32.4k [30.3-33.9] | 35.6k [33.6-37.0] | **29.2k** [28.8-30.9] | 29.4k [28.6-34.5] |
| against main, paired [range] | 1 | 1.012 [0.917-1.045] | 1.105 [1.018-1.174] | **0.915** [0.838-0.956] | 0.934 [0.847-1.044] |
| server cores; cycles on performance cores | 0.81; 87% | 0.81; 87% | 0.89; 86% | 0.71; 94% | 0.72; 92% |
| p50 µs | 23 | 23 | 23 | 22 | 23 |
| p99 µs, the 8 rounds | 104 229 143 234 244 166 171 299 | 1,510 102 441 2,133 1,395 199 245 175 | 2,406 121 170 184 173 207 186 5,415 | 136 2,722 301 250 276 258 49,028 212 | 116 196,427 80,034 255 237 325 1,781 214 |
| p99 µs, median | 200 | 343 | 185 | 267 | 290 |

8.5% fewer cycles, under main in all eight rounds. The p99: fin's undisturbed rounds sit at 212-301 µs
where main's sit at 104-299, and fin and finone took the three worst rounds of the board (49, 80 and
196 ms), with aa and hyper taking five between 1.4 and 5.4 ms. Section 6 on both.

**bench/net and bench/tasks** (15 and 12 rounds, the whole programs, 20:52-20:54; A14, A15; ms a run,
median, and against main paired by round):

| row | main | aa / main [range] | fin / main [range] | one / main | finone / main [range] |
|---|---:|---|---|---|---|
| net echo | 812.5 | 1.016 [0.933-1.035] | **0.881** [0.753-0.941] | 0.750 [0.727-0.820] | 0.728 [0.691-0.774] |
| net ping-pong | 328.3 | 0.997 [0.938-1.082] | 1.003 [0.937-1.088] | 1.005 [0.932-1.084] | 1.006 [0.932-1.087] |
| net connect | 26.19 | 0.994 [0.956-1.057] | 0.981 [0.934-1.041] | 0.982 [0.915-1.073] | 0.988 [0.932-1.011] |
| tasks spawn | 16.71 | 0.929 [0.812-1.072] | 0.908 [0.784-1.021] | | 0.889 [0.790-1.038] |
| tasks chain (the wake row) | 0.59 | 0.989 [0.754-1.371] | 0.947 [0.529-1.002] | | 0.949 [0.714-1.023] |
| tasks fanout | 72.02 | 0.997 [0.884-1.419] | 0.966 [0.927-1.078] | | 0.958 [0.874-1.064] |
| tasks yield | 6.27 | 1.003 [0.824-1.193] | **1.039** [0.870-1.181] | | 1.023 [0.802-1.151] |
| tasks hog | 0.01 | 0.948 [0.738-1.482] | 0.936 [0.730-1.466] | | 0.944 [0.671-1.829] |
| tasks produce | 5.32 | 0.997 [0.994-1.007] | 0.998 [0.979-1.039] | | 1.001 [0.993-1.018] |

Echo is 12% faster with the arm alone (the looks: the same 11% the mac-echo `nl` measured) and 27%
with `one` as well (mac-echo's `arm`: 23%); echo ran 28% slower in every arm than in the mac-echo
boards (812 against 638 ms), the machine's state. Ping-pong and connect are level. bench/tasks holds no
descriptor, so no rule of the arm runs in it and no clock is read; what it pays is the test for that at
each switch (`runFiber` loads `deterministic` and the poller's count, `spread` loads `held_since`),
and yield, a switch every 6 ns, reads 3.9% slower at the median, inside the pair's range.

**Not measured.** The closed loop at 16 and at 256 connections and the arm's calls a request under the
counting library (claim `mcl-P6`), and the trivial tail against shorter waits (claim `mcl-V1`: 50, 20
and 10 µs, and a ring of four waking at once) were written and queued behind other sessions' claims
when the owner's time box ended the work; `claimP6.sh` and `claimV1.sh` in the scratch folder run them
as they are (an addendum at the end of this file gives their tables if they ran before the box
closed).

## 6. Risks to other rows, and what is not shown

1. **The trivial open loop's p99 at 100,000 a second** rises by about 60-90 µs (267 against 200 at the
   median of rounds; five of fin's eight rounds at 250-301 against main's 104-299), p50 level, cycles
   8.5% lower. That is rule 2: a burst's fibers wait for their own worker up to 50 µs before another
   may take them. Whether a shorter wait keeps the closed loop's gain was screened once on the
   closed loop only (A9: 20 µs 1.123 of main against 50 µs 1.136); its effect on this tail is the
   queued claim `mcl-V1`, not run.
2. **Stalls.** fin and finone had the three rounds of the trivial board with a p99 over 49 ms, and on
   bench/mixed at 100,000 fin had one of 81 ms beside main's two (21 and 82 ms), aa's one (173 ms) and
   hyper's two. Every arm of every board on this Mac has such rounds, so 3 of 16 against 0 of 24 on one
   board is not shown to be the arm; but there is a way the arm can add to them. A worker the kernel
   switches out between two fibers, a batch kept in its ring, is no longer covered: on main `spread`
   had already woken a worker for the batch; here every other worker may be asleep, `hasWork` passes a
   kept ring by, and nothing looks again when the 50 µs end, since the watcher looks at pollers and not
   at rings. The batch then waits until its worker runs again. The guard is small: the watcher, as it
   wakes each millisecond, also counts a ring kept past `help_after` as work and searches. Written, as
   `probe-closed-final2` 9969c559a (with the one-load test of risk 3), and neither built nor measured:
   the time box came first.
3. **bench/tasks' yield:** 3.9% slower at the median (finone 2.3%; A/A 0.3% with a range of 0.82-1.19).
   Two loads at each switch that a build could make one (a flag on the worker, set as its first
   descriptor registers). To re-measure with at least 20 rounds before it is believed either way.
4. **Programs between the two loads.** With 1-10% of fibers long the kept rules hold, and the trade of
   section 3 returns in part: a request that lands while its worker is inside a long fiber is seen by a
   worker going to sleep only once that fiber has run 20 µs, else by the watcher within a millisecond;
   a batch's later fibers wait up to 50 µs behind a long first one. bench/mixed with 1 request in 16
   hashing (6% long) would show it and was not run.
5. **A threshold on a measured share** can flap near a tenth; each fiber moves the share a 32nd, so
   about 30 short fibers in a row leave the long mode. Not seen on any board (bench/mixed's context
   switches a request are main's to the third digit), not tested near the edge.
6. **Mac only.** Gated at compile time as `settle_wait` is, with the same kind of reason (what a wake
   costs there, and the efficiency cores); Linux was not run and is not touched. The mac-echo look rule,
   which rule 1 contains, lost on pup when tried for every worker.
7. **Not run:** `zig build test`, the core suite, Trig's and loco's light gates, the bench guards. The
   arm changes when a worker may sleep past a ring that holds work, which formal/Models/Sleep.lean
   states as never: a model change, and `test/cli/sched_stats.sh` and the unit tests that count spreads
   and steals on the Mac may read differently.
8. **The proof's machine state.** Every proof board ran a fifth below the standings' numbers with the
   owner at work on the Mac. The ordering matches the quiet board's for the probe's form of the same
   rules (A1: age 50 with s 1.097 of main and 1.060 of hyper), but the arm itself has no quiet-machine
   row.

## 7. What I would build

1. **`one` first** (the mac-echo arm, or its finding applied to `http.serve` alone: register every
   connection with the listener's poller, which is what the doc already says happens). It is worth
   2-5% on this row by itself, closes Rig's range to hyper's, costs bench/mixed nothing (its connections
   are already there), and is what the run-length rule works best on (one worker reads every event:
   finone's 70% of cycles on one thread, 84% on performance cores).
2. **The run-length rule on top**, with the watcher's guard of risk 2 and the one-load test of risk 3,
   after a quiet-machine board of the closed loop and of the trivial tail, and a bench/mixed run at 1
   in 16. Expected from the proof: 7% over hyper alone and 15% with `one`, a third to a half less
   server CPU a request, 8.5% fewer cycles on the trivial open loop, echo 12% faster, bench/mixed
   unchanged at 55,000 and 100,000.
3. If the run-length switch is judged one mechanism too many: **`e3`** (a worker on an efficiency core
   takes only work that has waited 50 µs and looks at its own poller only) is the best plain trade
   found, 4.5-9% on the closed loop for 1-3 µs of bench/mixed's p50 at 100,000 (inside that board's
   pair) and 6-8% fewer cycles there. It reads `hw.perflevel1.logicalcpu` and
   `pthread_cpu_number_np`, and holds only on machines with two kinds of core.

Not to build: registering for reads only (nothing); a wake gate keyed on the woken worker's core
(`e7`: p50 95); `free2`/`free3` (the p50 without the gain); a plain age gate or the look rules without
the run-length switch (the trade).

## 8. The confirming round (owner's go-ahead; 2026-11-17 22:13-22:33)

The arm with its stall guard and the mac-echo `one` change: branch **`probe-closed-one`
ada0252905025ae8cc912b95aad3a5d7ef8f65f9**, pushed to origin (`probe-closed-final2` 9969c559a with
`arm_one` on; `arm_one` is the same line as `mac-echo/bb/arm.patch`, `arm_nl` not taken). Five arms,
interleaved and rotated in every board: `main` (f03ef5199), `aa` (main plus a referenced dead
function, built apart: the layout A/A), `one` (`arm_one` alone), **`f2one`** (the arm, its guard, and
`one`), `hyper`. Two claims: `mcl-X1` (22:15-22:25: closed loop, bench/net, bench/tasks, bench/mixed at
55k) and `mcl-X2` (bench/http open loop, bench/mixed at 100k). The build waited 25 minutes behind the
`mac-one` session's claims and builds.

**How quiet the Mac was.** X1 began with load 2.59 and nothing else over 20% of a core
(`cpu_all` 36%); by the closed loop's end `PerfPowerServices` held 92% of a core and WindowServer 27%
(load 9.33), and Chrome 37% at bench/tasks' end. The machine was in the same slower state as the proof
boards (main 134k), not the standings' (166k). bench/mixed's generator was late at 55k this time (p99
lateness 283-324 µs in every arm, against 14-21 µs on the P3 board), so that board's p99s are the
generator's floor plus a little.

**Closed loop** (15 rounds, 64 connections, 3 s; A25, A26):

| | main | aa | one | **f2one** | hyper |
|---|---:|---:|---:|---:|---:|
| requests a second, median | 134,039 | 135,852 | 140,731 | **155,864** | 137,032 |
| range | 131,047-139,203 | 130,382-138,291 | 130,387-142,250 | 134,706-160,589 | 121,572-139,953 |
| against main, paired [range] | 1 | 1.012 | 1.040 [0.978-1.081] (12 rounds: 1.040) | 1.171 [1.010-1.213] (12 rounds) | 1.012 [0.990-1.064] (12 rounds) |
| against hyper, paired [range] | 0.990 [0.940-1.096] | 0.991 [0.936-1.117] | 1.016 [0.964-1.073] | **1.143 [0.991-1.200]** | 1 |
| rounds over hyper / over main | 5 / - | 5 / 7 | 13 / 12 | **14 / 15** | - |
| p50 / p99 µs | 464 / 670 | 465 / 680 | 447 / 668 | 394 / 659 | 457 / 679 |
| server CPU a request, µs (user / system) | 16.3 (2.5 / 13.7) | 15.8 | 14.3 (1.9 / 12.4) | **9.4 (1.1 / 8.3)** | 16.0 (2.8 / 13.2) |
| server cycles a request | 59.6k | 56.9k | 52.6k | **36.2k** | 58.3k |
| of them on performance cores | 64% | 65% | 67% | 79% | 63% |
| context switches / system calls a request | 0.56 / 4.47 | 0.53 / 4.05 | 0.42 / 3.01 | 0.18 / 2.46 | 0.47 / 2.91 |

Rounds (k req/s): main 135.2 131.4 132.6 133.9 137.4 131.0 139.2 135.8 138.7 132.2 136.2 134.0 133.2 132.2
134.5; aa 137.7 130.6 136.3 138.3 138.1 130.6 136.4 134.4 133.8 132.7 135.9 137.1 135.9 130.4 132.4; one
141.7 140.8 140.5 138.7 140.7 141.6 140.8 141.8 142.1 142.2 137.4 131.1 130.4 137.5 133.6; f2one 160.6
149.1 155.7 157.9 138.7 155.9 159.9 159.9 160.0 160.4 159.1 148.3 144.7 151.8 134.7; hyper 133.8 131.3
137.5 138.2 136.3 139.5 139.2 139.2 140.0 139.0 136.6 135.9 121.6 137.0 135.9. f2one's rounds follow
the share of its cycles on performance cores (85% at 160.6k, 65% at 134.7k: A26), which fell as
`PerfPowerServices` took a core in the last rounds; its one round under hyper (134.7k against 135.9k)
is the last.

**bench/net** (12 rounds, the whole program; A27):

| row, ms a run | main | aa / main | one / main | f2one / main | Tokio / main |
|---|---:|---|---|---|---|
| echo | 817.8 | 1.006 [0.950-1.084] | 0.747 [0.700-0.875] | **0.733** [0.648-0.919] | 0.754 [0.712-0.941] |
| connect | 26.66 | 1.004 [0.884-1.313] | 0.996 [0.938-1.055] | 1.014 [0.891-1.654] | 1.237 |
| ping-pong | 340.9 | 1.003 [0.907-1.021] | 0.989 [0.925-1.109] | 0.996 [0.936-1.083] | 0.977 |

Echo 27% faster than main and past Tokio (586 against 620 ms); connect and ping-pong level.

**bench/tasks** (12 rounds; A28): spawn 0.942 [0.711-1.050] of main (aa 0.988), wake (chain) 0.965
(aa 0.984), **yield 1.006 [0.824-1.160]** (aa 0.996): the one-load test removed the 3.9% the proof
board read; fanout 0.999, produce 0.999.

**bench/mixed at 55,000 a second on 2 workers** (5 rounds; A29; the generator late, see above):

| | main | aa | one | f2one | hyper |
|---|---:|---:|---:|---:|---:|
| cycles a request; against main | 62.0k; 1 | 62.7k; 1.011 | 61.9k; 0.998 | 61.8k; 0.998 | 63.9k; 1.033 |
| p50 µs | 43 | 44 | 42 | 42 | 45 |
| p99 µs, median [range] | 880 [701-3,370] | 815 [669-5,423] | 762 [721-868] | 724 [708-1,517] | 724 [700-952] |
| p99.9 µs | 4,158 | 1,875 | 1,190 | 1,158 | 1,208 |
| rounds with p99 over 10 ms | 0 | 0 | 0 | 0 | 0 |

**bench/http's load, open loop at 100,000 a second** (bench/mixed's server, which answers the
generator's one `/hash` request, so no connection fails and p99.9 is valid; 10 workers, no idle
connections; 5 rounds, 22:26-22:29; A30). **The machine was disturbed throughout this board**: main's
p99 was 1.9-12 ms in every round, the generator's own p99 lateness 300 µs against main, and the A/A arm
read 0.855 of main in cycles. Its cycles and tails cannot separate arms; they are listed as found:

| | main | aa | one | f2one | hyper |
|---|---:|---:|---:|---:|---:|
| cycles a request; against main [range] | 39.2k; 1 | 34.5k; 0.855 [0.779-1.025] | 33.5k; 0.934 [0.731-1.084] | 30.0k; 0.869 [0.737-0.881] | 44.8k; 1.144 [1.008-1.301] |
| p50 / p99 / p99.9 µs (medians) | 29 / 6,752 / 14,316 | 24 / 2,382 / 7,205 | 24 / 5,473 / 11,289 | 23 / 3,511 / 9,757 | 44 / 989 / 1,866 |
| p99 each round | 4,675 6,752 11,269 11,935 1,857 | 20,545 2,382 1,566 1,727 3,556 | 15,071 290 9,866 86 5,473 | 3,511 323 21,350 7,964 209 | 11,286 109 30,142 989 568 |
| rounds with p99 over 10 ms | 2 | 1 | 1 | 1 | 2 |

f2one has the lowest cycles a request of the five (30.0k; under main in all five rounds, and under
aa in four), as on the proof board (0.915 there, A/A 1.012).

**bench/mixed at 100,000 a second, 10 workers** (1 in 4 hashing, 5,000 idle; 5 rounds, 22:29-22:33;
A31):

| | main | aa | one | f2one | hyper |
|---|---:|---:|---:|---:|---:|
| cycles a request; against main [range] | 76.3k; 1 | 76.4k; 0.999 [0.979-1.017] | 75.8k; 0.991 [0.982-1.103] | 78.0k; 1.001 [0.986-1.146] | 87.6k; 1.136 |
| p50 µs (rounds) | 70 (70 70 74 68 68) | 69 (70 69 69 68 66) | 67 (67 1,326 70 67 66) | 75 (67 13,670 75 77 65) | 76 |
| p99 µs (rounds) | 1,635 (1,635 1,006 13,132 1,004 15,621) | 979 (13,918 961 5,166 979 964) | 1,116 (878 57,545 6,360 996 1,116) | 5,836 (898 99,304 5,836 18,167 1,365) | 1,046 (936 4,521 1,046 1,711 1,016) |
| p99.9 µs | 8,228 | 1,341 | 6,454 | 9,800 | 2,095 |
| rounds with p99 over 10 ms | 2 | 1 | 1 | **2** | 0 |
| the generator's lateness, p99 µs | 486 | 476 | 444 | 583 | 575 |

The worst run of the board, f2one's second (p50 13.7 ms, p99 99 ms), ran straight after `one`'s
second (p50 1.3 ms, p99 58 ms) in the rotation, the two back to back, which reads as one event of the
machine across both; f2one's third and fourth rounds (p99 5.8 and 18.2 ms, p50 75-77) are its own.
Cycles a request are level in every arm but hyper.

**What the round says.**

- **Closed loop: yes, beyond noise.** f2one 155.9k against hyper's 137.0k, paired 1.143 [0.991-1.200],
  over hyper in 14 rounds of 15 and over main in all 15; the A/A pair is 1.012 apart. The proof board
  read 1.151 for the same pair of changes without the guard.
- **CPU a request: yes.** 9.4 µs against hyper's 16.0 and main's 16.3 (41% less than hyper); 36.2k
  cycles against 58.3k; 0.18 context switches against 0.47; 2.46 system calls against hyper's 2.91.
- **Stalls: not gone.** Rounds with a p99 over 10 ms, over the two open-loop boards: main 4, aa 2, one
  2, f2one 3, hyper 2; at 55k on 2 workers none in any arm. Every arm stalls on this Mac, Rig's and
  hyper's alike, so the guard is not shown to have removed anything the arm added, nor the arm to add
  any; bench/mixed at 100k is the row where f2one's tail looks worst (two rounds over 10 ms, p50 75 in
  its other rounds against main's 68-70), and it needs a quiet board of at least 10 rounds to decide.
- **p99 costs that remain:** none shown beyond the A/A spread at 55k (f2one's p99 724 µs, the best of
  the Rig arms, on a late generator); at 100k in bench/mixed f2one reads p50 75 against 70 and p99 1.4-18
  ms in its undisturbed rounds against main's 1.0-1.6 ms; the trivial open loop could not be read.
- **Other rows:** echo 27% faster than main and 6% faster than Tokio; connect and ping-pong level;
  bench/tasks level (yield 1.006, A/A 0.996): the one-load test fixed the proof board's 3.9%.


## 9. What I would try next, in order

1. **A quiet-machine board of the closed loop** (main, aa, hyper, fin, one, finone; 15 rounds): the arm
   has no row on the machine state the standings were taken in. `claimP1.sh` is that board.
2. **Build and measure `probe-closed-final2`** (the watcher's guard, one load at a switch): the trivial
   open loop at 100,000 a second for at least 20 rounds, counting the rounds with a p99 over 5 ms an
   arm, and bench/tasks' yield for at least 20 rounds. `claimW1.sh` is written for it.
3. **The wait against the tail** (`claimV1.sh`): `help_after` 50, 20 and 10 µs, and a ring of four
   fibers waking at once, on the trivial open loop's p99 and on the closed loop. If 20 µs keeps the
   closed loop (it read 1.123 against 1.136 once) and gives back the 60-90 µs of p99, 20 is the number.
4. **The middle loads**: bench/mixed at 1 in 8 and 1 in 16 hashing, at 100,000 and at 55,000 on two
   workers, to see where the switch flips and what the kept rules cost just below it; and the share's
   threshold (a tenth) and step (a 32nd) against that.
5. **Other shapes of the row** (`claimP6.sh`): 16 and 256 connections, and the arm's calls a request.
6. **`http.serve`'s registrations, as a change of its own**: register each connection with the
   listener's poller, which is what the doc says and what `one` does for every socket. It needs
   neither arm, it is the whole of the row's spread, and Linux should be measured before it is taken
   there (on pup the split may be helping).
7. Then the gates the arm has not seen: the unit tests, the core suite, the Lean model's sleep
   invariant restated for a kept batch.

## Files

In the scratch folder named at the top: `probe/probe-c1.patch` (the first probe as a diff against
main), `aa/lay.patch` (the layout control), `build-arm.sh`, `build-final.sh`, `chain.sh`, the drivers
and summaries, `claim*.sh` (what each claim ran), `raw/*.jsonl` (every run, one JSON line each, with
each board's state lines), `raw/claim-*.log`, `appendix.sh` (prints the appendix below from `raw/`).
The probes' sources are the branches in the worktree.

## Appendix: every board

Each table's first lines are the Mac's state as the board began and ended (load averages, all other
processes' CPU, every process over 20% of a core).

### A1. Closed loop, screening probe c1 (claim mcl-S1, 5 rounds): raw/s1-closed.jsonl

# 2026-11-17 19:09:42 load { 3.27 5.28 5.39 } cpu_all 41% over20: none
# 2026-11-17 19:17:16 load { 7.57 6.97 6.23 } cpu_all 9% over20: none (end)
| arm | n | req/s median | range | best | p50 / p99 µs | /main paired [range] | server µs (user/sys) | server cores | cycles k | P % | csw | intwk | syscalls | busiest thread % | threads >5% | gen µs | gen cores | gen P % |
|---|---:|---:|---|---:|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 5 | 168038 | 165505-171160 | 171160 | 374 / 560 | 1.000 [1.000-1.000] | 16.3 (2.6/13.7) | 2.73 | 58.0 | 58 | 0.40 | 0.035 | 4.14 | 25 | 4 | 21.8 | 3.67 | 49 |
| hyper | 5 | 173801 | 167107-174040 | 174040 | 362 / 554 | 1.034 [0.976-1.052] | 15.0 (2.8/12.2) | 2.61 | 53.7 | 58 | 0.34 | 0.001 | 2.74 | 11 | 10 | 21.3 | 3.69 | 50 |
| p | 5 | 164677 | 162744-167368 | 167368 | 382 / 578 | 0.980 [0.951-1.011] | 17.4 (2.8/14.6) | 2.87 | 61.8 | 57 | 0.44 | 0.046 | 4.46 | 23 | 5 | 22.0 | 3.63 | 48 |
| one | 5 | 174787 | 170558-176064 | 176064 | 360 / 539 | 1.041 [0.996-1.064] | 13.7 (1.9/11.8) | 2.39 | 49.5 | 62 | 0.33 | 0.013 | 2.83 | 34 | 10 | 21.5 | 3.76 | 49 |
| nowrite | 5 | 168221 | 167298-170922 | 170922 | 374 / 570 | 1.001 [0.979-1.031] | 16.3 (2.4/13.8) | 2.72 | 57.8 | 57 | 0.39 | 0.043 | 3.99 | 24 | 4 | 21.9 | 3.68 | 49 |
| age10 | 5 | 174363 | 169477-175806 | 175806 | 363 / 552 | 1.026 [1.013-1.046] | 13.5 (2.0/11.5) | 2.37 | 48.8 | 62 | 0.31 | 0.029 | 3.22 | 32 | 5 | 21.6 | 3.68 | 49 |
| age20 | 5 | 174753 | 170132-176734 | 176734 | 361 / 544 | 1.034 [1.012-1.068] | 13.0 (1.9/11.2) | 2.30 | 47.5 | 63 | 0.29 | 0.034 | 3.24 | 29 | 3 | 21.2 | 3.70 | 50 |
| age50 | 5 | 179676 | 175253-185303 | 185303 | 351 / 529 | 1.082 [1.042-1.102] | 11.9 (1.8/10.1) | 2.13 | 43.6 | 67 | 0.25 | 0.034 | 3.12 | 34 | 3 | 20.8 | 3.74 | 50 |
| age20s | 5 | 172099 | 168371-178833 | 178833 | 365 / 543 | 1.024 [0.984-1.065] | 14.3 (2.2/12.1) | 2.46 | 51.4 | 61 | 0.38 | 0.050 | 3.96 | 28 | 4 | 21.6 | 3.73 | 50 |
| age50s | 5 | 184260 | 179235-185726 | 185726 | 340 / 516 | 1.097 [1.047-1.122] | 10.8 (1.5/9.3) | 1.99 | 40.1 | 69 | 0.24 | 0.029 | 3.11 | 38 | 3 | 20.7 | 3.85 | 50 |
| gap20-age20 | 5 | 175912 | 169185-180225 | 180225 | 357 / 531 | 1.051 [0.988-1.073] | 12.7 (1.8/10.9) | 2.23 | 46.2 | 64 | 0.31 | 0.037 | 3.07 | 31 | 3 | 21.2 | 3.74 | 50 |
| gap20-age20s | 5 | 179493 | 175863-182338 | 182338 | 350 / 519 | 1.066 [1.046-1.102] | 12.4 (1.8/10.6) | 2.22 | 45.1 | 64 | 0.32 | 0.038 | 3.10 | 36 | 3 | 21.0 | 3.79 | 50 |
| nl | 5 | 175459 | 174547-177127 | 177127 | 358 / 530 | 1.044 [1.020-1.070] | 13.7 (1.9/11.8) | 2.39 | 49.3 | 63 | 0.40 | 0.028 | 3.08 | 34 | 3 | 21.5 | 3.78 | 49 |
| nl-age20s | 5 | 184905 | 181087-187434 | 187434 | 337 / 528 | 1.100 [1.077-1.116] | 10.7 (1.4/9.3) | 1.99 | 40.2 | 72 | 0.24 | 0.022 | 2.59 | 48 | 3 | 20.9 | 3.85 | 48 |
| awake2 | 5 | 189139 | 179903-189304 | 189304 | 332 / 499 | 1.106 [1.071-1.144] | 9.4 (1.2/8.1) | 1.77 | 36.1 | 78 | 0.14 | 0.020 | 2.68 | 48 | 2 | 20.7 | 3.90 | 49 |

Every round (k req/s), in round order:
- main: 171.2 165.5 168.2 168.0 167.9
- hyper: 167.1 174.0 174.0 173.8 172.8
- p: 162.7 167.4 166.0 164.7 164.2
- one: 170.6 176.1 174.6 176.0 174.8
- nowrite: 167.6 170.6 167.3 168.2 170.9
- age10: 175.6 169.5 174.4 175.8 170.1
- age20: 175.4 176.7 173.9 170.1 174.8
- age50: 185.3 179.0 175.3 179.7 185.0
- age20s: 168.4 175.4 171.3 172.1 178.8
- age50s: 179.2 185.7 182.6 184.3 185.7
- gap20-age20: 169.2 174.0 175.9 180.2 176.4
- gap20-age20s: 179.5 182.3 175.9 179.2 182.2
- nl: 174.5 177.1 174.6 175.5 176.2
- nl-age20s: 187.4 184.6 181.1 184.9 186.3
- awake2: 189.2 189.3 184.5 179.9 189.1

### A2. Runs that behave as main in A1 (main, p, nowrite), each with its counters


**mainlike**, runs sorted by req/s:

| rps_k | srv_us | srv_cyc_k | srv_P% | top_thr% | top_thr_P% | thr>5% | csw | intwk | sysc | gen_us | gen_cores | gen_P% | gen_csw | round |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 162.7 | 17.6 | 62.0 | 54.8 | 22.8 | 58.7 | 5 | 0.440 | 0.046 | 4.463 | 21.9 | 3.6 | 47.4 | 1.030 | 0 |
| 164.2 | 17.7 | 62.6 | 56.6 | 22.0 | 60.3 | 5 | 0.438 | 0.047 | 4.488 | 22.1 | 3.6 | 48.2 | 1.047 | 4 |
| 164.7 | 17.4 | 61.8 | 56.9 | 23.5 | 61.6 | 5 | 0.447 | 0.047 | 4.489 | 22.0 | 3.6 | 48.3 | 1.055 | 3 |
| 165.5 | 16.8 | 59.5 | 57.3 | 23.9 | 61.7 | 4 | 0.441 | 0.044 | 4.254 | 22.2 | 3.7 | 48.1 | 1.076 | 1 |
| 166.0 | 16.3 | 58.2 | 57.6 | 25.0 | 62.0 | 4 | 0.439 | 0.042 | 4.180 | 22.0 | 3.7 | 48.9 | 1.066 | 2 |
| 167.3 | 16.3 | 57.8 | 56.2 | 26.0 | 60.9 | 4 | 0.407 | 0.043 | 3.991 | 22.6 | 3.8 | 48.2 | 1.065 | 2 |
| 167.4 | 16.5 | 58.9 | 58.0 | 26.0 | 63.8 | 5 | 0.415 | 0.036 | 4.229 | 21.6 | 3.6 | 46.8 | 1.014 | 1 |
| 167.6 | 17.3 | 61.1 | 55.7 | 22.0 | 60.5 | 5 | 0.382 | 0.047 | 4.154 | 21.9 | 3.7 | 49.4 | 0.961 | 0 |
| 167.9 | 16.3 | 58.0 | 58.6 | 24.2 | 62.4 | 4 | 0.417 | 0.040 | 4.137 | 21.8 | 3.7 | 48.8 | 1.012 | 4 |
| 168.0 | 16.7 | 59.5 | 57.7 | 25.8 | 63.5 | 5 | 0.400 | 0.035 | 4.185 | 21.9 | 3.7 | 48.3 | 1.014 | 3 |
| 168.2 | 16.1 | 57.2 | 57.9 | 25.3 | 63.2 | 4 | 0.391 | 0.035 | 3.930 | 21.8 | 3.7 | 49.5 | 1.004 | 2 |
| 168.2 | 17.0 | 60.3 | 57.2 | 22.5 | 61.3 | 5 | 0.399 | 0.045 | 4.171 | 21.9 | 3.7 | 47.9 | 1.028 | 3 |
| 170.6 | 15.9 | 56.9 | 58.7 | 24.1 | 63.5 | 4 | 0.386 | 0.043 | 3.916 | 21.6 | 3.7 | 48.6 | 0.984 | 1 |
| 170.9 | 15.6 | 55.9 | 58.3 | 25.0 | 62.7 | 4 | 0.380 | 0.039 | 3.858 | 21.4 | 3.7 | 49.8 | 0.984 | 4 |
| 171.2 | 14.8 | 53.5 | 61.1 | 29.0 | 68.2 | 4 | 0.384 | 0.028 | 3.590 | 21.6 | 3.7 | 49.1 | 1.018 | 0 |
| rank correlation with req/s | -0.79 | -0.78 | 0.74 | 0.40 | 0.69 | 0.10 | -0.85 | -0.65 | -0.86 | -0.72 | 0.60 | 0.56 | -0.64 | 0.21 |

**hyper**, runs sorted by req/s:

| rps_k | srv_us | srv_cyc_k | srv_P% | top_thr% | top_thr_P% | thr>5% | csw | intwk | sysc | gen_us | gen_cores | gen_P% | gen_csw | round |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 167.1 | 15.0 | 53.2 | 57.0 | 10.6 | 56.5 | 10 | 0.345 | 0.001 | 2.756 | 21.1 | 3.5 | 49.3 | 0.995 | 0 |
| 172.8 | 14.9 | 53.4 | 58.6 | 10.5 | 59.6 | 10 | 0.333 | 0.001 | 2.740 | 21.3 | 3.7 | 49.6 | 0.982 | 4 |
| 173.8 | 15.2 | 54.2 | 58.2 | 10.6 | 58.6 | 10 | 0.337 | 0.001 | 2.795 | 21.4 | 3.7 | 49.8 | 0.982 | 3 |
| 174.0 | 15.1 | 53.7 | 57.9 | 10.9 | 57.1 | 10 | 0.337 | 0.001 | 2.733 | 21.3 | 3.7 | 50.2 | 0.987 | 2 |
| 174.0 | 15.0 | 53.7 | 58.9 | 10.8 | 58.8 | 10 | 0.326 | 0.001 | 2.720 | 21.1 | 3.7 | 50.2 | 0.953 | 1 |
| rank correlation with req/s | 0.50 | 0.70 | 0.60 | 0.80 | 0.30 | 1.00 | -0.60 | -0.40 | -0.70 | -0.30 | 0.30 | 0.90 | -0.70 | 0.00 |

### A3. bench/mixed at 100,000 a second, 10 workers, probe c1 (claim mcl-S2, 3 rounds): raw/s2-mix100.jsonl

# 2026-11-17 19:17:47 load { 4.96 6.39 6.04 } cpu_all 38% over20: none rate 100000 mix 4 idle 5000 workers None
# 2026-11-17 19:23:00 load { 6.34 6.12 6.00 } cpu_all 186% over20: 180.4% corespotlightd (end)
| arm | n | achieved | cycles k [range] | /main paired [range] | user / sys µs | cores | P % | csw | intwk | p50 | p99 [range] | p99.9 | lateness p99 | rounds p99 > 5 ms | rounds p99 > 10 ms |
|---|---:|---:|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|
| main | 3 | 99998 | 70.3 [70.2-70.5] | 1.000 [1.000-1.000] | 10.30 / 8.47 | 1.88 | 77 | 0.645 | 0.014 | 57 | 341 [308-453] | 974 | 42 | 0 | 0 |
| aa | 3 | 99999 | 70.2 [69.9-70.8] | 0.997 [0.996-1.004] | 10.18 / 8.31 | 1.85 | 77 | 0.640 | 0.015 | 57 | 519 [350-530] | 1006 | 103 | 0 | 0 |
| hyper | 3 | 99999 | 80.7 [80.4-81.4] | 1.144 [1.143-1.160] | 11.62 / 10.37 | 2.18 | 70 | 0.865 | 0.000 | 60 | 424 [351-519] | 993 | 95 | 0 | 0 |
| p | 3 | 99999 | 70.1 [69.5-70.2] | 0.996 [0.990-0.997] | 10.21 / 8.36 | 1.86 | 77 | 0.647 | 0.014 | 57 | 363 [309-420] | 1011 | 41 | 0 | 0 |
| one | 3 | 99999 | 70.2 [69.4-70.2] | 0.995 [0.989-0.998] | 10.22 / 8.38 | 1.86 | 77 | 0.645 | 0.014 | 57 | 362 [346-483] | 975 | 39 | 0 | 0 |
| age20 | 3 | 99998 | 59.8 [59.1-60.2] | 0.850 [0.841-0.853] | 9.42 / 5.85 | 1.53 | 86 | 0.307 | 0.019 | 70 | 362 [352-381] | 996 | 58 | 0 | 0 |
| age50 | 3 | 99998 | 57.4 [55.8-58.0] | 0.815 [0.795-0.823] | 9.31 / 5.41 | 1.47 | 85 | 0.210 | 0.024 | 85 | 459 [403-650] | 1399 | 58 | 0 | 0 |
| age20s | 3 | 99998 | 61.1 [59.9-61.7] | 0.867 [0.854-0.877] | 9.57 / 6.23 | 1.58 | 84 | 0.350 | 0.022 | 74 | 418 [405-494] | 1149 | 65 | 0 | 0 |
| age50s | 3 | 99998 | 57.4 [55.9-57.8] | 0.816 [0.797-0.819] | 9.37 / 5.44 | 1.48 | 85 | 0.228 | 0.031 | 87 | 417 [361-608] | 1131 | 62 | 0 | 0 |
| one-age50s | 3 | 99998 | 57.5 [56.8-59.4] | 0.815 [0.809-0.844] | 9.37 / 5.45 | 1.48 | 85 | 0.234 | 0.031 | 88 | 458 [368-715] | 1042 | 43 | 0 | 0 |
| gap20-age20s | 3 | 99998 | 61.6 [60.0-61.6] | 0.873 [0.855-0.876] | 9.67 / 6.37 | 1.60 | 83 | 0.356 | 0.024 | 79 | 411 [345-469] | 1057 | 54 | 0 | 0 |
| nl | 3 | 99998 | 66.1 [66.0-66.2] | 0.940 [0.937-0.941] | 9.85 / 7.39 | 1.72 | 83 | 0.589 | 0.015 | 69 | 390 [355-409] | 1020 | 39 | 0 | 0 |
| nl-age20s | 3 | 99997 | 59.6 [59.5-59.9] | 0.849 [0.843-0.851] | 9.36 / 5.81 | 1.52 | 88 | 0.355 | 0.024 | 86 | 443 [365-513] | 1076 | 55 | 0 | 0 |
- main: 70.2k/56/453 70.3k/57/341 70.5k/58/308
- aa: 69.9k/56/530 70.2k/57/350 70.8k/58/519
- hyper: 81.4k/59/519 80.4k/60/351 80.7k/61/424
- p: 69.5k/55/309 70.1k/57/420 70.2k/58/363
- one: 69.4k/55/346 70.2k/57/483 70.2k/58/362
- age20: 59.1k/68/352 59.8k/70/381 60.2k/71/362
- age50: 55.8k/83/403 57.4k/85/459 58.0k/86/650
- age20s: 59.9k/71/405 61.7k/74/494 61.1k/74/418
- age50s: 55.9k/87/361 57.4k/86/608 57.8k/89/417
- one-age50s: 56.8k/87/458 59.4k/88/715 57.5k/88/368
- gap20-age20s: 60.0k/75/345 61.6k/79/411 61.6k/79/469
- nl: 66.0k/68/390 66.2k/70/355 66.1k/69/409
- nl-age20s: 59.6k/83/443 59.9k/87/513 59.5k/86/365

### A4. bench/mixed at 55,000 a second, 2 workers, probe c1 (claim mcl-S3, 3 rounds): raw/s3-mix55w2.jsonl

# 2026-11-17 19:23:36 load { 4.54 5.72 5.86 } cpu_all 31% over20: none rate 55000 mix 4 idle 5000 workers 2
# 2026-11-17 19:28:48 load { 4.34 4.72 5.32 } cpu_all 94% over20: 31.4% WindowServer (end)
| arm | n | achieved | cycles k [range] | /main paired [range] | user / sys µs | cores | P % | csw | intwk | p50 | p99 [range] | p99.9 | lateness p99 | rounds p99 > 5 ms | rounds p99 > 10 ms |
|---|---:|---:|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|
| main | 3 | 54999 | 61.0 [60.7-62.7] | 1.000 [1.000-1.000] | 9.56 / 5.80 | 0.84 | 95 | 0.832 | 0.013 | 41 | 306 [174-674] | 941 | 19 | 0 | 0 |
| aa | 3 | 54999 | 61.2 [60.9-61.7] | 1.003 [0.984-1.004] | 9.59 / 5.84 | 0.85 | 94 | 0.833 | 0.013 | 42 | 293 [162-395] | 961 | 18 | 0 | 0 |
| hyper | 3 | 54999 | 62.6 [62.4-63.5] | 1.031 [0.994-1.042] | 9.81 / 5.93 | 0.87 | 96 | 0.875 | 0.004 | 42 | 379 [158-550] | 967 | 18 | 0 | 0 |
| p | 3 | 54999 | 61.6 [60.5-61.7] | 0.997 [0.983-1.011] | 9.49 / 5.98 | 0.85 | 95 | 0.828 | 0.013 | 43 | 488 [140-537] | 961 | 128 | 0 | 0 |
| one | 3 | 54999 | 60.8 [60.7-62.2] | 0.999 [0.970-1.020] | 9.45 / 5.81 | 0.84 | 95 | 0.833 | 0.012 | 40 | 190 [120-630] | 899 | 8 | 0 | 0 |
| age20 | 3 | 54999 | 56.4 [56.4-57.0] | 0.930 [0.899-0.935] | 9.15 / 4.94 | 0.77 | 97 | 0.639 | 0.027 | 38 | 212 [161-611] | 933 | 8 | 0 | 0 |
| age50 | 3 | 54999 | 56.6 [56.3-56.7] | 0.928 [0.902-0.930] | 9.18 / 4.91 | 0.77 | 97 | 0.640 | 0.027 | 38 | 222 [141-581] | 892 | 8 | 0 | 0 |
| age20s | 3 | 54999 | 56.5 [56.4-56.5] | 0.927 [0.901-0.929] | 9.18 / 4.90 | 0.77 | 97 | 0.642 | 0.027 | 38 | 607 [133-10854] | 1099 | 8 | 1 | 1 |
| age50s | 3 | 54999 | 56.6 [56.6-58.8] | 0.932 [0.903-0.965] | 9.18 / 4.94 | 0.78 | 96 | 0.646 | 0.028 | 39 | 409 [242-794] | 966 | 21 | 0 | 0 |
| one-age50s | 3 | 54999 | 56.6 [56.5-59.2] | 0.933 [0.926-0.944] | 9.40 / 4.97 | 0.79 | 94 | 0.638 | 0.028 | 41 | 620 [274-23037] | 1122 | 165 | 1 | 1 |
| gap20-age20s | 3 | 54999 | 56.5 [56.3-57.2] | 0.930 [0.898-0.939] | 9.27 / 4.91 | 0.77 | 96 | 0.623 | 0.027 | 39 | 593 [213-730] | 1053 | 217 | 0 | 0 |
| nl | 3 | 54999 | 62.5 [60.6-65.2] | 1.025 [0.998-1.039] | 9.92 / 6.26 | 0.89 | 91 | 0.848 | 0.014 | 45 | 635 [141-810] | 1126 | 197 | 0 | 0 |
| nl-age20s | 3 | 54999 | 56.5 [56.0-57.5] | 0.918 [0.917-0.930] | 9.29 / 4.95 | 0.77 | 97 | 0.625 | 0.027 | 39 | 386 [243-57819] | 959 | 25 | 1 | 1 |
- main: 60.7k/40/174 62.7k/45/674 61.0k/41/306
- aa: 60.9k/40/162 61.7k/42/293 61.2k/42/395
- hyper: 62.6k/41/158 62.4k/42/379 63.5k/44/550
- p: 60.5k/40/140 61.6k/43/488 61.7k/43/537
- one: 60.7k/40/120 60.8k/40/190 62.2k/44/630
- age20: 56.4k/38/161 56.4k/38/212 57.0k/40/611
- age50: 56.3k/38/141 56.6k/38/222 56.7k/40/581
- age20s: 56.4k/38/133 56.5k/38/10854 56.5k/39/607
- age50s: 56.6k/38/242 56.6k/39/409 58.8k/57/794
- one-age50s: 56.6k/38/274 59.2k/48/23037 56.5k/41/620
- gap20-age20s: 56.5k/38/213 56.3k/39/593 57.2k/41/730
- nl: 60.6k/40/141 65.2k/45/635 62.5k/45/810
- nl-age20s: 56.5k/38/243 57.5k/42/57819 56.0k/39/386

### A5. Closed loop, probe c2 (claim mcl-T1, 5 rounds; a zig test held one core throughout): raw/t1-closed.jsonl

# 2026-11-17 19:38:53 load { 2.39 3.14 4.08 } cpu_all 118% over20: 100.0% zig
# 2026-11-17 19:43:26 load { 12.02 7.90 5.97 } cpu_all 163% over20: 99.0% zig; 36.3% WindowServer (end)
| arm | n | req/s median | range | best | p50 / p99 µs | /main paired [range] | server µs (user/sys) | server cores | cycles k | P % | csw | intwk | syscalls | busiest thread % | threads >5% | gen µs | gen cores | gen P % |
|---|---:|---:|---|---:|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 5 | 164032 | 156649-165394 | 165394 | 383 / 636 | 1.000 [1.000-1.000] | 14.9 (2.2/12.7) | 2.44 | 52.1 | 53 | 0.36 | 0.028 | 3.53 | 30 | 4 | 20.9 | 3.45 | 44 |
| hyper | 5 | 164419 | 162546-167667 | 167667 | 380 / 622 | 1.008 [0.992-1.038] | 15.3 (2.8/12.4) | 2.51 | 52.8 | 49 | 0.31 | 0.001 | 2.65 | 11 | 10 | 20.5 | 3.38 | 46 |
| p2 | 5 | 159778 | 153673-164772 | 164772 | 384 / 617 | 1.000 [0.930-1.020] | 15.9 (2.5/13.3) | 2.51 | 54.4 | 53 | 0.39 | 0.034 | 3.84 | 27 | 4 | 21.3 | 3.45 | 44 |
| one | 5 | 166448 | 161324-167618 | 167618 | 378 / 631 | 1.020 [0.976-1.051] | 14.1 (2.0/12.1) | 2.35 | 49.7 | 55 | 0.32 | 0.015 | 2.83 | 33 | 10 | 20.9 | 3.44 | 43 |
| e1-50 | 5 | 163416 | 159495-165305 | 165305 | 381 / 667 | 0.998 [0.973-1.038] | 14.8 (2.3/12.5) | 2.43 | 52.6 | 56 | 0.37 | 0.033 | 3.76 | 28 | 3 | 21.0 | 3.41 | 42 |
| e3-50 | 5 | 170532 | 165343-171513 | 171513 | 367 / 606 | 1.045 [1.020-1.055] | 12.7 (1.9/10.8) | 2.17 | 47.1 | 68 | 0.36 | 0.031 | 3.26 | 33 | 3 | 21.2 | 3.62 | 38 |
| e7-50 | 5 | 171831 | 166381-178112 | 178112 | 357 / 585 | 1.062 [1.038-1.086] | 10.6 (1.4/9.3) | 1.87 | 39.8 | 68 | 0.20 | 0.027 | 2.63 | 43 | 2 | 20.6 | 3.56 | 38 |
| e7-20 | 5 | 170396 | 161654-174520 | 174520 | 365 / 611 | 1.032 [0.995-1.064] | 11.8 (1.6/10.2) | 2.02 | 43.3 | 66 | 0.26 | 0.024 | 2.77 | 38 | 3 | 20.7 | 3.49 | 40 |
| one-e7-50 | 5 | 174460 | 160901-178405 | 178405 | 355 / 631 | 1.055 [0.982-1.088] | 10.6 (1.3/9.2) | 1.83 | 39.2 | 70 | 0.18 | 0.021 | 2.40 | 47 | 10 | 20.1 | 3.53 | 37 |
| free2-age50s | 5 | 169955 | 161969-173220 | 173220 | 369 / 614 | 1.030 [0.988-1.056] | 12.4 (1.8/10.7) | 2.05 | 43.5 | 58 | 0.25 | 0.027 | 3.07 | 35 | 2 | 20.4 | 3.47 | 44 |
| free2-age50 | 5 | 166913 | 152709-169651 | 169651 | 378 / 611 | 1.018 [0.932-1.026] | 12.4 (1.7/10.7) | 2.09 | 43.9 | 56 | 0.22 | 0.021 | 2.81 | 33 | 3 | 20.5 | 3.46 | 43 |
| free3-age50s | 5 | 164689 | 150842-167055 | 167055 | 382 / 631 | 1.003 [0.963-1.010] | 13.9 (2.1/11.7) | 2.26 | 47.8 | 54 | 0.33 | 0.033 | 3.79 | 32 | 4 | 20.5 | 3.40 | 43 |
| run10 | 5 | 162798 | 152198-167169 | 167169 | 379 / 645 | 0.993 [0.972-1.011] | 14.3 (2.1/12.2) | 2.35 | 50.6 | 55 | 0.41 | 0.031 | 3.21 | 33 | 4 | 21.0 | 3.42 | 44 |
| age50s | 5 | 168951 | 155542-170463 | 170463 | 367 / 761 | 1.022 [0.993-1.040] | 12.2 (1.7/10.2) | 2.00 | 42.1 | 57 | 0.22 | 0.030 | 2.83 | 39 | 2 | 19.9 | 3.38 | 43 |

Every round (k req/s), in round order:
- main: 164.0 156.6 165.3 165.4 163.9
- hyper: 162.8 162.5 164.4 166.8 167.7
- p2: 164.0 159.8 153.7 154.5 164.8
- one: 167.6 164.7 161.3 166.4 167.2
- e1-50: 165.3 162.6 165.1 163.4 159.5
- e3-50: 171.5 165.3 170.5 168.7 171.4
- e7-50: 178.1 166.4 171.6 175.6 171.8
- e7-20: 174.5 161.7 170.4 174.2 163.1
- one-e7-50: 178.4 163.5 174.5 176.9 160.9
- free2-age50s: 173.2 164.4 170.3 170.0 162.0
- free2-age50: 166.9 157.7 169.0 169.7 152.7
- free3-age50s: 164.7 150.8 167.1 165.9 162.8
- run10: 162.6 152.2 166.1 167.2 162.8
- age50s: 169.2 155.5 169.0 167.4 170.5

### A6. A5's runs: descriptors registered per worker's poller, each worker's share of the fibers run, and counters a request

```
p2 r2  153.7k reg[53 5 0 0 0 0 0 0 2 6] ran%[31 18 3 4 3 3 3 3 14 18] kicks 0.208 sleeps 0.502 waits 0.384 polls 1.623 hits 0.679 ev/hit 3.3 young 0.000 wokeE/P 0.000/0.000 srv 16.3us
p2 r3  154.5k reg[55 7 0 0 0 0 0 0 4 0] ran%[29 20 5 4 5 5 4 5 18 5] kicks 0.179 sleeps 0.426 waits 0.308 polls 1.169 hits 0.564 ev/hit 3.9 young 0.000 wokeE/P 0.000/0.000 srv 14.4us
p2 r1  159.8k reg[44 9 10 3 0 0 0 0 0 0] ran%[28 20 20 14 3 3 3 3 3 3] kicks 0.214 sleeps 0.556 waits 0.440 polls 1.888 hits 0.810 ev/hit 2.7 young 0.000 wokeE/P 0.000/0.000 srv 16.3us
p2 r0  164.0k reg[52 0 0 5 5 0 0 0 0 4] ran%[30 3 3 18 18 3 3 3 3 16] kicks 0.224 sleeps 0.552 waits 0.437 polls 1.850 hits 0.769 ev/hit 2.9 young 0.000 wokeE/P 0.000/0.000 srv 15.9us
p2 r4  164.8k reg[53 0 0 0 2 0 0 0 0 11] ran%[31 4 4 4 16 5 4 5 4 22] kicks 0.215 sleeps 0.497 waits 0.367 polls 1.329 hits 0.655 ev/hit 3.4 young 0.000 wokeE/P 0.000/0.000 srv 15.0us
one r2  161.3k reg[66 0 0 0 0 0 0 0 0 0] ran%[37 7 8 7 6 7 7 7 7 7] kicks 0.234 sleeps 0.446 waits 0.310 polls 0.606 hits 0.494 ev/hit 4.5 young 0.000 wokeE/P 0.000/0.000 srv 14.6us
one r1  164.7k reg[66 0 0 0 0 0 0 0 0 0] ran%[37 8 6 7 7 6 8 7 7 7] kicks 0.228 sleeps 0.438 waits 0.304 polls 0.593 hits 0.484 ev/hit 4.6 young 0.000 wokeE/P 0.000/0.000 srv 14.3us
one r3  166.4k reg[66 0 0 0 0 0 0 0 0 0] ran%[38 8 7 7 7 7 8 6 6 7] kicks 0.214 sleeps 0.414 waits 0.285 polls 0.555 hits 0.457 ev/hit 4.8 young 0.000 wokeE/P 0.000/0.000 srv 14.0us
one r4  167.2k reg[66 0 0 0 0 0 0 0 0 0] ran%[37 6 7 7 8 7 7 7 7 7] kicks 0.214 sleeps 0.409 waits 0.283 polls 0.550 hits 0.452 ev/hit 4.9 young 0.000 wokeE/P 0.000/0.000 srv 14.0us
one r0  167.6k reg[66 0 0 0 0 0 0 0 0 0] ran%[38 7 7 7 7 6 7 7 7 8] kicks 0.228 sleeps 0.440 waits 0.304 polls 0.592 hits 0.485 ev/hit 4.6 young 0.000 wokeE/P 0.000/0.000 srv 14.1us
e1-50 r4  159.5k reg[35 4 0 0 0 0 0 3 0 24] ran%[26 16 3 3 3 3 3 15 3 23] kicks 0.196 sleeps 0.508 waits 0.376 polls 1.818 hits 0.776 ev/hit 2.8 young 0.000 wokeE/P 0.000/0.000 srv 15.3us
e1-50 r1  162.6k reg[56 5 0 0 0 0 0 0 0 5] ran%[34 20 4 3 4 4 4 3 4 20] kicks 0.229 sleeps 0.503 waits 0.379 polls 1.465 hits 0.681 ev/hit 3.3 young 0.000 wokeE/P 0.000/0.000 srv 14.6us
e1-50 r3  163.4k reg[57 8 0 0 0 0 0 0 0 1] ran%[33 23 4 3 5 4 5 4 4 14] kicks 0.220 sleeps 0.479 waits 0.348 polls 1.330 hits 0.634 ev/hit 3.5 young 0.000 wokeE/P 0.000/0.000 srv 14.2us
e1-50 r2  165.1k reg[46 5 0 0 0 0 0 0 0 15] ran%[30 18 4 4 4 4 3 4 4 24] kicks 0.220 sleeps 0.518 waits 0.384 polls 1.527 hits 0.746 ev/hit 3.0 young 0.000 wokeE/P 0.000/0.000 srv 15.0us
e1-50 r0  165.3k reg[49 8 0 0 0 0 0 0 0 9] ran%[30 21 3 4 4 4 3 4 4 22] kicks 0.228 sleeps 0.527 waits 0.396 polls 1.572 hits 0.756 ev/hit 2.9 young 0.000 wokeE/P 0.000/0.000 srv 14.8us
e3-50 r1  165.3k reg[50 9 0 0 0 0 0 0 0 7] ran%[36 25 3 3 3 2 3 2 2 21] kicks 0.234 sleeps 0.513 waits 0.401 polls 1.150 hits 0.674 ev/hit 3.3 young 0.000 wokeE/P 0.000/0.000 srv 13.1us
e3-50 r3  168.7k reg[51 6 0 0 0 0 0 0 0 9] ran%[35 21 3 3 3 3 3 2 3 24] kicks 0.216 sleeps 0.467 waits 0.361 polls 1.033 hits 0.607 ev/hit 3.6 young 0.000 wokeE/P 0.000/0.000 srv 12.8us
e3-50 r2  170.5k reg[61 0 0 0 0 0 0 5 0 0] ran%[39 5 5 5 5 4 5 23 4 5] kicks 0.240 sleeps 0.447 waits 0.332 polls 0.784 hits 0.533 ev/hit 4.2 young 0.000 wokeE/P 0.000/0.000 srv 12.4us
e3-50 r4  171.4k reg[56 3 0 0 0 0 0 0 0 7] ran%[38 18 3 3 3 3 3 3 3 23] kicks 0.226 sleeps 0.465 waits 0.358 polls 1.018 hits 0.589 ev/hit 3.8 young 0.000 wokeE/P 0.000/0.000 srv 12.7us
e3-50 r0  171.5k reg[54 4 0 0 8 0 0 0 0 0] ran%[36 19 3 3 23 3 3 3 3 3] kicks 0.230 sleeps 0.490 waits 0.378 polls 1.091 hits 0.630 ev/hit 3.5 young 0.000 wokeE/P 0.000/0.000 srv 12.7us
e7-50 r1  166.4k reg[58 8 0 0 0 0 0 0 0 0] ran%[44 29 3 3 4 4 4 3 3 3] kicks 0.085 sleeps 0.278 waits 0.174 polls 0.528 hits 0.360 ev/hit 5.8 young 0.498 wokeE/P 0.039/0.027 srv 11.3us
e7-50 r2  171.6k reg[58 7 0 0 0 0 0 0 0 1] ran%[46 28 2 2 2 2 1 1 2 14] kicks 0.079 sleeps 0.289 waits 0.190 polls 0.650 hits 0.382 ev/hit 5.4 young 0.540 wokeE/P 0.034/0.019 srv 11.1us
e7-50 r4  171.8k reg[66 0 0 0 0 0 0 0 0 0] ran%[55 6 4 5 5 5 5 4 6 5] kicks 0.097 sleeps 0.208 waits 0.130 polls 0.270 hits 0.240 ev/hit 8.8 young 0.464 wokeE/P 0.052/0.034 srv 10.6us
e7-50 r3  175.6k reg[59 0 0 0 0 0 0 0 0 7] ran%[48 3 3 3 2 3 3 2 3 30] kicks 0.080 sleeps 0.278 waits 0.174 polls 0.538 hits 0.361 ev/hit 5.8 young 0.538 wokeE/P 0.037/0.024 srv 10.6us
e7-50 r0  178.1k reg[63 3 0 0 0 0 0 0 0 0] ran%[52 25 3 3 3 3 3 3 3 3] kicks 0.087 sleeps 0.263 waits 0.166 polls 0.492 hits 0.328 ev/hit 6.4 young 0.540 wokeE/P 0.042/0.027 srv 10.6us
e7-20 r1  161.7k reg[54 11 0 0 0 0 0 0 0 1] ran%[38 28 3 3 3 3 3 3 3 14] kicks 0.127 sleeps 0.354 waits 0.247 polls 0.774 hits 0.462 ev/hit 4.6 young 0.340 wokeE/P 0.059/0.034 srv 12.5us
e7-20 r4  163.1k reg[50 9 0 0 0 0 0 0 0 7] ran%[36 22 3 2 3 3 3 3 3 23] kicks 0.109 sleeps 0.369 waits 0.261 polls 0.895 hits 0.513 ev/hit 4.1 young 0.304 wokeE/P 0.040/0.033 srv 11.8us
e7-20 r2  170.4k reg[61 5 0 0 0 0 0 0 0 0] ran%[43 26 4 4 4 4 3 4 4 4] kicks 0.136 sleeps 0.333 waits 0.227 polls 0.611 hits 0.409 ev/hit 5.2 young 0.343 wokeE/P 0.066/0.044 srv 11.8us
e7-20 r3  174.2k reg[63 3 0 0 0 0 0 0 0 0] ran%[44 23 4 4 4 4 5 4 4 4] kicks 0.143 sleeps 0.334 waits 0.230 polls 0.606 hits 0.403 ev/hit 5.3 young 0.334 wokeE/P 0.068/0.052 srv 11.7us
e7-20 r0  174.5k reg[62 4 0 0 0 0 0 0 0 0] ran%[45 24 4 4 4 4 3 4 4 4] kicks 0.139 sleeps 0.340 waits 0.231 polls 0.623 hits 0.415 ev/hit 5.2 young 0.328 wokeE/P 0.063/0.051 srv 11.5us
one-e7-50 r4  160.9k reg[66 0 0 0 0 0 0 0 0 0] ran%[51 5 5 6 4 5 5 6 5 7] kicks 0.100 sleeps 0.216 waits 0.134 polls 0.283 hits 0.249 ev/hit 8.4 young 0.423 wokeE/P 0.046/0.043 srv 10.5us
one-e7-50 r1  163.5k reg[66 0 0 0 0 0 0 0 0 0] ran%[52 5 6 6 5 6 5 5 4 6] kicks 0.098 sleeps 0.200 waits 0.126 polls 0.254 hits 0.228 ev/hit 9.2 young 0.456 wokeE/P 0.055/0.032 srv 11.1us
one-e7-50 r2  174.5k reg[66 0 0 0 0 0 0 0 0 0] ran%[57 5 4 5 5 5 4 5 5 5] kicks 0.100 sleeps 0.218 waits 0.134 polls 0.281 hits 0.250 ev/hit 8.4 young 0.495 wokeE/P 0.054/0.035 srv 10.6us
one-e7-50 r3  176.9k reg[66 0 0 0 0 0 0 0 0 0] ran%[57 5 5 5 5 5 5 4 4 5] kicks 0.100 sleeps 0.216 waits 0.134 polls 0.279 hits 0.248 ev/hit 8.5 young 0.500 wokeE/P 0.054/0.035 srv 10.6us
one-e7-50 r0  178.4k reg[66 0 0 0 0 0 0 0 0 0] ran%[59 5 4 5 4 4 5 5 5 4] kicks 0.098 sleeps 0.224 waits 0.135 polls 0.292 hits 0.258 ev/hit 8.1 young 0.508 wokeE/P 0.052/0.036 srv 10.3us
free2-age50s r4  162.0k reg[45 0 15 0 0 0 0 0 0 6] ran%[32 3 25 2 3 3 3 4 3 22] kicks 0.095 sleeps 0.374 waits 0.229 polls 1.155 hits 0.583 ev/hit 3.6 young 0.495 wokeE/P 0.000/0.000 srv 12.6us
free2-age50s r1  164.4k reg[32 34 0 0 0 0 0 0 0 0] ran%[37 37 4 3 3 3 3 3 3 3] kicks 0.121 sleeps 0.361 waits 0.214 polls 0.864 hits 0.540 ev/hit 3.9 young 0.524 wokeE/P 0.000/0.000 srv 12.4us
free2-age50s r3  170.0k reg[52 1 0 0 0 0 0 0 0 13] ran%[39 15 2 2 3 3 2 3 2 30] kicks 0.127 sleeps 0.388 waits 0.240 polls 1.128 hits 0.562 ev/hit 3.8 young 0.523 wokeE/P 0.000/0.000 srv 12.6us
free2-age50s r2  170.3k reg[50 16 0 0 0 0 0 0 0 0] ran%[39 34 4 3 3 3 4 4 3 3] kicks 0.127 sleeps 0.372 waits 0.220 polls 0.883 hits 0.534 ev/hit 4.0 young 0.533 wokeE/P 0.000/0.000 srv 12.2us
free2-age50s r0  173.2k reg[50 16 0 0 0 0 0 0 0 0] ran%[41 35 3 3 3 3 3 2 3 3] kicks 0.129 sleeps 0.384 waits 0.228 polls 0.922 hits 0.556 ev/hit 3.8 young 0.535 wokeE/P 0.000/0.000 srv 11.9us
free2-age50 r4  152.7k reg[53 13 0 0 0 0 0 0 0 0] ran%[34 27 5 4 4 6 4 6 5 5] kicks 0.085 sleeps 0.257 waits 0.145 polls 0.551 hits 0.344 ev/hit 6.1 young 0.518 wokeE/P 0.000/0.000 srv 12.4us
free2-age50 r1  157.7k reg[43 9 0 0 0 0 0 0 1 13] ran%[25 22 2 2 2 3 2 3 16 23] kicks 0.072 sleeps 0.295 waits 0.192 polls 0.983 hits 0.445 ev/hit 4.7 young 0.503 wokeE/P 0.000/0.000 srv 12.5us
free2-age50 r0  166.9k reg[52 7 0 0 0 0 0 0 7 0] ran%[35 25 2 2 2 2 2 2 25 2] kicks 0.097 sleeps 0.370 waits 0.245 polls 1.062 hits 0.526 ev/hit 4.0 young 0.549 wokeE/P 0.000/0.000 srv 13.2us
free2-age50 r2  169.0k reg[53 13 0 0 0 0 0 0 0 0] ran%[39 34 3 4 3 3 3 4 4 3] kicks 0.104 sleeps 0.320 waits 0.194 polls 0.698 hits 0.429 ev/hit 4.9 young 0.569 wokeE/P 0.000/0.000 srv 12.4us
free2-age50 r3  169.7k reg[54 12 0 0 0 0 0 0 0 0] ran%[40 34 3 4 4 3 4 3 3 3] kicks 0.103 sleeps 0.316 waits 0.189 polls 0.685 hits 0.423 ev/hit 5.0 young 0.571 wokeE/P 0.000/0.000 srv 12.4us
free3-age50s r1  150.8k reg[56 1 0 0 0 0 0 0 2 7] ran%[35 14 2 2 1 3 2 2 16 23] kicks 0.173 sleeps 0.464 waits 0.320 polls 1.603 hits 0.648 ev/hit 3.4 young 0.392 wokeE/P 0.000/0.000 srv 13.9us
free3-age50s r4  162.8k reg[30 4 0 0 0 0 4 0 0 28] ran%[29 17 1 2 2 1 17 2 2 27] kicks 0.152 sleeps 0.487 waits 0.347 polls 1.806 hits 0.775 ev/hit 2.8 young 0.399 wokeE/P 0.000/0.000 srv 14.0us
free3-age50s r0  164.7k reg[38 5 0 0 0 0 0 21 2 0] ran%[31 19 1 2 2 1 1 27 14 1] kicks 0.165 sleeps 0.504 waits 0.354 polls 1.849 hits 0.793 ev/hit 2.7 young 0.404 wokeE/P 0.000/0.000 srv 14.1us
free3-age50s r3  165.9k reg[46 7 0 0 0 0 0 0 0 13] ran%[34 24 2 2 3 2 3 2 2 27] kicks 0.173 sleeps 0.471 waits 0.313 polls 1.481 hits 0.714 ev/hit 3.0 young 0.421 wokeE/P 0.000/0.000 srv 13.4us
free3-age50s r2  167.1k reg[52 5 0 0 0 0 0 0 0 9] ran%[35 23 3 2 3 3 2 2 2 25] kicks 0.183 sleeps 0.477 waits 0.321 polls 1.481 hits 0.692 ev/hit 3.2 young 0.414 wokeE/P 0.000/0.000 srv 13.5us
run10 r1  152.2k reg[62 4 0 0 0 0 0 0 0 0] ran%[41 20 5 6 5 5 4 4 6 5] kicks 0.215 sleeps 0.410 waits 0.294 polls 0.654 hits 0.472 ev/hit 4.7 young 0.000 wokeE/P 0.000/0.000 srv 14.0us
run10 r0  162.6k reg[55 4 0 0 2 0 5 0 0 0] ran%[37 17 2 3 13 2 19 3 3 3] kicks 0.231 sleeps 0.505 waits 0.405 polls 1.117 hits 0.625 ev/hit 3.6 young 0.000 wokeE/P 0.000/0.000 srv 14.7us
run10 r4  162.8k reg[55 6 0 0 0 0 0 0 0 5] ran%[35 20 3 4 4 4 4 4 4 19] kicks 0.225 sleeps 0.486 waits 0.371 polls 0.974 hits 0.598 ev/hit 3.7 young 0.000 wokeE/P 0.000/0.000 srv 14.3us
run10 r2  166.1k reg[55 11 0 0 0 0 0 0 0 0] ran%[38 25 5 5 5 4 5 5 4 5] kicks 0.235 sleeps 0.479 waits 0.341 polls 0.775 hits 0.565 ev/hit 4.0 young 0.000 wokeE/P 0.000/0.000 srv 14.1us
run10 r3  167.2k reg[55 6 0 0 0 0 0 0 0 5] ran%[35 20 4 3 4 3 4 4 4 19] kicks 0.237 sleeps 0.507 waits 0.389 polls 1.006 hits 0.620 ev/hit 3.6 young 0.000 wokeE/P 0.000/0.000 srv 14.5us
age50s r1  155.5k reg[38 0 0 0 0 0 0 0 0 28] ran%[38 3 3 3 3 3 3 3 3 38] kicks 0.073 sleeps 0.338 waits 0.191 polls 0.806 hits 0.517 ev/hit 4.0 young 0.542 wokeE/P 0.000/0.000 srv 12.2us
age50s r3  167.4k reg[61 0 5 0 0 0 0 0 0 0] ran%[43 4 27 4 3 4 3 4 3 4] kicks 0.082 sleeps 0.289 waits 0.167 polls 0.653 hits 0.384 ev/hit 5.4 young 0.568 wokeE/P 0.000/0.000 srv 12.3us
age50s r2  169.0k reg[60 6 0 0 0 0 0 0 0 0] ran%[45 29 4 2 3 3 4 3 3 4] kicks 0.083 sleeps 0.316 waits 0.184 polls 0.729 hits 0.429 ev/hit 4.9 young 0.577 wokeE/P 0.000/0.000 srv 11.8us
age50s r0  169.2k reg[59 2 0 0 0 0 0 0 5 0] ran%[44 17 2 2 2 2 2 2 25 2] kicks 0.083 sleeps 0.347 waits 0.218 polls 1.029 hits 0.487 ev/hit 4.3 young 0.569 wokeE/P 0.000/0.000 srv 12.3us
age50s r4  170.5k reg[60 0 0 0 0 0 0 0 0 6] ran%[44 3 3 3 4 3 3 4 4 29] kicks 0.082 sleeps 0.306 waits 0.178 polls 0.702 hits 0.415 ev/hit 5.0 young 0.575 wokeE/P 0.000/0.000 srv 11.6us
```

### A7. The scheduler's counters a request, per worker, one run of main's behaviour (p2, round 0 of A5)

```
round 0 p2: 164004 req/s
  worker ran stole slept notify spread kick_made kick_notify kick_watch kick_timer kick_home waits waits_empty waits_settle service_all capped young pend_young search_empty polls poll_hits poll_events poll_noany ev_write registered woke_e woke_p
  0: 0.303 0.071 0.153 0.062 0.141 0.067 0.062 0.012 0.000 0.000 0.108 0.035 0.067 0.189 0.000 0.000 0.000 0.153 0.456 0.211 0.819 0.049 0.403 0.000 0.000 0.000
  1: 0.027 0.016 0.020 0.008 0.009 0.008 0.008 0.001 0.000 0.000 0.016 0.015 0.000 0.024 0.000 0.000 0.000 0.020 0.060 0.027 0.058 0.018 0.020 0.000 0.000 0.000
  2: 0.031 0.019 0.022 0.009 0.011 0.009 0.009 0.002 0.000 0.000 0.018 0.017 0.000 0.027 0.000 0.000 0.000 0.022 0.068 0.030 0.066 0.020 0.024 0.000 0.000 0.000
  3: 0.181 0.076 0.094 0.030 0.065 0.036 0.030 0.012 0.000 0.000 0.079 0.048 0.020 0.125 0.000 0.000 0.000 0.094 0.348 0.134 0.358 0.053 0.162 0.000 0.000 0.000
  4: 0.178 0.073 0.092 0.030 0.066 0.036 0.030 0.012 0.000 0.000 0.077 0.047 0.020 0.122 0.000 0.000 0.000 0.092 0.341 0.131 0.354 0.052 0.160 0.000 0.000 0.000
  5: 0.029 0.017 0.020 0.008 0.010 0.008 0.008 0.001 0.000 0.000 0.016 0.016 0.000 0.025 0.000 0.000 0.000 0.020 0.063 0.028 0.061 0.019 0.022 0.000 0.000 0.000
  6: 0.031 0.019 0.022 0.008 0.011 0.009 0.008 0.002 0.000 0.000 0.018 0.017 0.000 0.027 0.000 0.000 0.000 0.022 0.067 0.029 0.064 0.020 0.023 0.000 0.000 0.000
  7: 0.030 0.018 0.021 0.008 0.010 0.009 0.008 0.001 0.000 0.000 0.017 0.016 0.000 0.026 0.000 0.000 0.000 0.021 0.065 0.029 0.062 0.020 0.022 0.000 0.000 0.000
  8: 0.032 0.020 0.023 0.009 0.011 0.009 0.009 0.002 0.000 0.000 0.018 0.017 0.000 0.028 0.000 0.000 0.000 0.023 0.069 0.031 0.066 0.021 0.023 0.000 0.000 0.000
  9: 0.160 0.072 0.084 0.028 0.056 0.034 0.028 0.011 0.000 0.000 0.070 0.044 0.015 0.111 0.000 0.000 0.000 0.084 0.314 0.120 0.316 0.050 0.141 0.000 0.000 0.000
  all: ran 1.000 stole 0.401 slept 0.552 notify 0.199 spread 0.389 kick_made 0.224 kick_notify 0.199 kick_watch 0.056 kick_timer 0.000 kick_home 0.000 waits 0.437 waits_empty 0.272 waits_settle 0.122 service_all 0.704 capped 0.000 young 0.000 pend_young 0.000 search_empty 0.552 polls 1.850 poll_hits 0.769 poll_events 2.224 poll_noany 0.320 ev_write 1.000 registered 0.000 woke_e 0.000 woke_p 0.000
```

### A8. bench/mixed at 100,000 a second, probe c2 (claim mcl-T2, 3 rounds; the generator late, a VM running): raw/t2-mix100.jsonl

# 2026-11-17 20:07:22 load { 2.65 4.06 5.21 } cpu_all 75% over20: 28.9% WindowServer rate 100000 mix 4 idle 5000 workers None
# 2026-11-17 20:12:35 load { 6.84 5.90 5.72 } cpu_all 71% over20: 41.1% WindowServer (end)
| arm | n | achieved | cycles k [range] | /main paired [range] | user / sys µs | cores | P % | csw | intwk | p50 | p99 [range] | p99.9 | lateness p99 | rounds p99 > 5 ms | rounds p99 > 10 ms |
|---|---:|---:|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|
| main | 3 | 99998 | 76.5 [75.7-77.7] | 1.000 [1.000-1.000] | 10.49 / 10.20 | 2.07 | 72 | 0.608 | 0.016 | 69 | 957 [896-4028] | 1201 | 449 | 0 | 0 |
| aa | 3 | 99998 | 76.8 [75.7-78.2] | 1.000 [0.988-1.023] | 10.53 / 10.31 | 2.08 | 71 | 0.606 | 0.016 | 71 | 1061 [893-1224] | 2136 | 493 | 0 | 0 |
| p2 | 3 | 99998 | 76.2 [75.4-76.7] | 0.997 [0.980-1.003] | 10.46 / 10.14 | 2.06 | 73 | 0.609 | 0.016 | 69 | 967 [953-1109] | 1271 | 431 | 0 | 0 |
| e1-50 | 3 | 99999 | 75.1 [74.5-75.6] | 0.982 [0.972-0.984] | 10.44 / 9.79 | 2.02 | 74 | 0.597 | 0.017 | 70 | 984 [892-15527] | 1479 | 378 | 1 | 1 |
| e3-50 | 3 | 99996 | 69.9 [69.6-71.6] | 0.919 [0.899-0.936] | 9.73 / 8.16 | 1.79 | 86 | 0.559 | 0.017 | 72 | 913 [898-1047] | 1279 | 419 | 0 | 0 |
| e7-50 | 3 | 99997 | 63.1 [61.9-63.3] | 0.818 [0.814-0.826] | 9.36 / 6.79 | 1.62 | 87 | 0.258 | 0.026 | 95 | 1037 [970-2969] | 2206 | 427 | 0 | 0 |
| e7-20 | 3 | 99998 | 66.0 [65.5-66.6] | 0.866 [0.850-0.871] | 9.52 / 7.38 | 1.69 | 86 | 0.372 | 0.020 | 82 | 992 [981-996] | 1346 | 426 | 0 | 0 |
| one-e7-50 | 3 | 99997 | 62.8 [62.7-64.3] | 0.820 [0.809-0.849] | 9.30 / 6.69 | 1.60 | 87 | 0.262 | 0.026 | 97 | 952 [929-1022] | 1257 | 406 | 0 | 0 |
| free2-age50s | 3 | 99998 | 66.9 [66.5-71.0] | 0.878 [0.875-0.913] | 9.71 / 7.74 | 1.74 | 82 | 0.384 | 0.028 | 78 | 998 [994-41475] | 2454 | 447 | 1 | 1 |
| free2-age50 | 3 | 99978 | 67.7 [66.4-68.4] | 0.880 [0.868-0.894] | 9.67 / 7.88 | 1.73 | 80 | 0.367 | 0.019 | 70 | 5589 [927-62690] | 13103 | 470 | 2 | 1 |
| free3-age50s | 3 | 99999 | 75.3 [74.0-79.1] | 0.977 [0.969-1.034] | 10.39 / 9.92 | 2.03 | 72 | 0.557 | 0.026 | 81 | 1123 [867-1191] | 1763 | 520 | 0 | 0 |
| run10 | 3 | 99998 | 75.7 [75.2-75.8] | 0.991 [0.973-0.994] | 10.35 / 9.97 | 2.03 | 74 | 0.599 | 0.016 | 74 | 980 [924-1054] | 1376 | 484 | 0 | 0 |
| age50s | 3 | 99998 | 65.9 [65.7-67.4] | 0.868 [0.859-0.871] | 9.68 / 7.65 | 1.73 | 79 | 0.300 | 0.034 | 99 | 1016 [977-1093] | 1413 | 428 | 0 | 0 |
- main: 75.7k/66/896 76.5k/69/957 77.7k/73/4028
- aa: 75.7k/66/893 78.2k/76/1224 76.8k/71/1061
- p2: 75.4k/66/1109 76.7k/71/967 76.2k/69/953
- e1-50: 74.5k/66/892 75.1k/70/15527 75.6k/70/984
- e3-50: 69.6k/69/898 71.6k/79/1047 69.9k/72/913
- e7-50: 61.9k/95/1037 63.1k/98/2969 63.3k/95/970
- e7-20: 65.5k/80/996 66.6k/85/992 66.0k/82/981
- one-e7-50: 64.3k/99/1022 62.7k/97/952 62.8k/97/929
- free2-age50s: 66.5k/75/994 66.9k/78/998 71.0k/88/41475
- free2-age50: 67.7k/70/62690 66.4k/67/927 68.4k/73/5589
- free3-age50s: 74.0k/75/867 79.1k/102/1191 75.3k/81/1123
- run10: 75.2k/73/924 75.8k/74/1054 75.7k/74/980
- age50s: 65.9k/99/1016 65.7k/99/977 67.4k/102/1093

### A9. Closed loop, probe c3 (claim mcl-U1, 5 rounds; the machine in its slower state): raw/u1-closed.jsonl

# 2026-11-17 20:25:34 load { 3.90 6.87 6.96 } cpu_all 88% over20: 37.0% WindowServer
# 2026-11-17 20:29:48 load { 8.61 7.73 7.31 } cpu_all 89% over20: 47.7% WindowServer (end)
| arm | n | req/s median | range | best | p50 / p99 µs | /main paired [range] | server µs (user/sys) | server cores | cycles k | P % | csw | intwk | syscalls | busiest thread % | threads >5% | gen µs | gen cores | gen P % |
|---|---:|---:|---|---:|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 5 | 134462 | 133535-139538 | 139538 | 469 / 656 | 1.000 [1.000-1.000] | 16.1 (2.5/13.6) | 2.16 | 58.3 | 66 | 0.52 | 0.049 | 4.28 | 31 | 4 | 23.7 | 3.21 | 55 |
| hyper | 5 | 138007 | 134675-139986 | 139986 | 457 / 657 | 1.031 [0.989-1.041] | 15.7 (2.8/12.9) | 2.16 | 56.5 | 65 | 0.46 | 0.002 | 2.90 | 11 | 10 | 22.8 | 3.14 | 56 |
| p3 | 5 | 135714 | 133573-136752 | 136752 | 465 / 662 | 1.016 [0.957-1.019] | 15.4 (2.3/13.1) | 2.10 | 56.0 | 67 | 0.52 | 0.046 | 4.02 | 31 | 3 | 23.6 | 3.20 | 56 |
| one | 5 | 140352 | 139831-141824 | 141824 | 447 / 650 | 1.047 [1.012-1.055] | 13.9 (1.9/12.0) | 1.96 | 51.1 | 69 | 0.42 | 0.020 | 3.01 | 38 | 10 | 22.9 | 3.22 | 56 |
| r20 | 5 | 146310 | 146167-153606 | 153606 | 411 / 652 | 1.094 [1.048-1.150] | 10.8 (1.5/9.3) | 1.64 | 40.8 | 73 | 0.33 | 0.045 | 3.04 | 53 | 3 | 21.0 | 3.10 | 59 |
| r10 | 5 | 136825 | 134283-137944 | 137944 | 459 / 648 | 1.007 [0.965-1.033] | 15.5 (2.5/13.0) | 2.13 | 57.1 | 67 | 0.52 | 0.046 | 4.31 | 31 | 4 | 23.5 | 3.18 | 56 |
| r20-age20 | 5 | 145812 | 142573-153779 | 153779 | 431 / 622 | 1.072 [1.045-1.144] | 12.4 (1.8/10.6) | 1.79 | 45.4 | 71 | 0.40 | 0.044 | 3.27 | 46 | 3 | 21.7 | 3.18 | 58 |
| one-r20 | 5 | 157546 | 152877-158837 | 158837 | 394 / 609 | 1.159 [1.133-1.181] | 9.0 (1.1/7.9) | 1.40 | 34.1 | 82 | 0.16 | 0.024 | 2.43 | 67 | 1 | 20.2 | 3.17 | 59 |
| e3-50 | 5 | 146794 | 130717-148021 | 148021 | 429 / 622 | 1.089 [0.972-1.103] | 11.7 (1.8/9.9) | 1.73 | 45.2 | 79 | 0.43 | 0.034 | 3.38 | 38 | 4 | 23.2 | 3.40 | 52 |
| one-e3-50 | 5 | 147827 | 144367-149739 | 149739 | 424 / 618 | 1.089 [1.064-1.102] | 11.3 (1.6/9.7) | 1.66 | 43.3 | 82 | 0.37 | 0.021 | 2.92 | 44 | 8 | 23.1 | 3.40 | 51 |
| r20-e3 | 5 | 151465 | 148426-156750 | 156750 | 412 / 606 | 1.121 [1.085-1.173] | 10.3 (1.5/8.9) | 1.56 | 39.0 | 77 | 0.33 | 0.048 | 2.96 | 56 | 3 | 21.0 | 3.16 | 59 |
| one-r20-e3 | 5 | 158037 | 154311-163030 | 163030 | 393 / 589 | 1.168 [1.142-1.200] | 8.7 (1.1/7.6) | 1.37 | 33.2 | 84 | 0.16 | 0.024 | 2.43 | 69 | 1 | 20.3 | 3.21 | 58 |
| age50s | 5 | 151184 | 147258-155852 | 155852 | 414 / 604 | 1.112 [1.074-1.159] | 10.3 (1.4/8.9) | 1.53 | 38.1 | 76 | 0.24 | 0.031 | 2.96 | 52 | 3 | 21.2 | 3.18 | 59 |

Every round (k req/s), in round order:
- main: 135.9 134.5 133.5 133.7 139.5
- hyper: 134.7 140.0 138.0 137.8 138.1
- p3: 135.5 136.8 135.7 136.3 133.6
- one: 140.3 141.8 139.8 140.4 141.2
- r20: 146.3 152.7 153.6 146.2 146.2
- r10: 136.8 137.3 137.9 134.3 134.7
- r20-age20: 152.7 153.8 142.6 143.3 145.8
- one-r20: 157.5 158.8 152.9 156.3 158.1
- e3-50: 148.0 130.7 146.8 147.4 143.9
- one-e3-50: 149.7 147.8 145.4 144.4 148.4
- r20-e3: 152.6 148.4 149.7 156.8 151.5
- one-r20-e3: 163.0 158.0 154.3 156.1 159.4
- age50s: 151.2 155.9 147.3 151.4 149.8

### A10. A9's runs: registrations, shares, counters

```
p3 r4  133.6k reg[44 8 0 0 0 0 0 8 0 6] ran%[31 19 2 2 2 2 2 19 2 17] kicks 0.241 sleeps 0.628 waits 0.528 polls 2.194 hits 0.886 ev/hit 2.5 young 0.000 wokeE/P 0.000/0.000 srv 16.4us
p3 r0  135.5k reg[49 0 0 0 0 0 0 0 3 14] ran%[35 4 3 3 4 3 3 2 16 26] kicks 0.255 sleeps 0.623 waits 0.488 polls 1.750 hits 0.826 ev/hit 2.7 young 0.000 wokeE/P 0.000/0.000 srv 15.5us
p3 r2  135.7k reg[51 5 0 0 0 0 0 10 0 0] ran%[35 19 3 3 3 3 3 24 3 3] kicks 0.252 sleeps 0.616 waits 0.490 polls 1.759 hits 0.816 ev/hit 2.8 young 0.000 wokeE/P 0.000/0.000 srv 15.4us
p3 r3  136.3k reg[56 3 0 0 0 0 0 0 7 0] ran%[37 17 3 3 4 3 4 4 22 4] kicks 0.247 sleeps 0.571 waits 0.446 polls 1.569 hits 0.724 ev/hit 3.1 young 0.000 wokeE/P 0.000/0.000 srv 15.1us
p3 r1  136.8k reg[42 5 19 0 0 0 0 0 0 0] ran%[34 19 28 3 3 3 2 3 3 3] kicks 0.245 sleeps 0.637 waits 0.503 polls 1.840 hits 0.876 ev/hit 2.6 young 0.000 wokeE/P 0.000/0.000 srv 15.2us
one r2  139.8k reg[66 0 0 0 0 0 0 0 0 0] ran%[43 7 6 7 6 6 7 6 7 5] kicks 0.262 sleeps 0.530 waits 0.371 polls 0.749 hits 0.583 ev/hit 3.9 young 0.000 wokeE/P 0.000/0.000 srv 14.0us
one r0  140.3k reg[66 0 0 0 0 0 0 0 0 0] ran%[42 6 7 6 5 6 7 6 7 7] kicks 0.259 sleeps 0.524 waits 0.367 polls 0.740 hits 0.577 ev/hit 3.9 young 0.000 wokeE/P 0.000/0.000 srv 14.1us
one r3  140.4k reg[66 0 0 0 0 0 0 0 0 0] ran%[43 6 6 6 6 6 6 6 8 7] kicks 0.250 sleeps 0.505 waits 0.351 polls 0.708 hits 0.554 ev/hit 4.1 young 0.000 wokeE/P 0.000/0.000 srv 13.9us
one r4  141.2k reg[66 0 0 0 0 0 0 0 0 0] ran%[42 8 6 5 7 7 6 7 7 6] kicks 0.256 sleeps 0.516 waits 0.360 polls 0.726 hits 0.566 ev/hit 4.0 young 0.000 wokeE/P 0.000/0.000 srv 13.9us
one r1  141.8k reg[66 0 0 0 0 0 0 0 0 0] ran%[42 7 5 7 6 7 6 6 7 7] kicks 0.260 sleeps 0.526 waits 0.369 polls 0.742 hits 0.577 ev/hit 3.9 young 0.000 wokeE/P 0.000/0.000 srv 13.9us
r20 r4  146.2k reg[56 5 0 0 0 0 0 0 5 0] ran%[63 15 1 1 1 1 1 1 15 1] kicks 0.114 sleeps 0.425 waits 0.319 polls 1.001 hits 0.548 ev/hit 3.9 young 0.434 wokeE/P 0.000/0.000 srv 11.6us
r20 r3  146.2k reg[56 8 0 0 0 0 1 0 0 1] ran%[61 19 1 1 1 1 7 1 1 7] kicks 0.126 sleeps 0.439 waits 0.328 polls 1.114 hits 0.573 ev/hit 3.7 young 0.421 wokeE/P 0.000/0.000 srv 11.7us
r20 r0  146.3k reg[66 0 0 0 0 0 0 0 0 0] ran%[73 3 4 2 3 3 3 3 4 3] kicks 0.108 sleeps 0.279 waits 0.149 polls 0.370 hits 0.317 ev/hit 6.6 young 0.548 wokeE/P 0.000/0.000 srv 10.4us
r20 r1  152.7k reg[54 1 0 0 0 0 0 0 0 11] ran%[65 6 1 1 1 1 1 1 1 22] kicks 0.099 sleeps 0.427 waits 0.289 polls 0.925 hits 0.548 ev/hit 3.8 young 0.469 wokeE/P 0.000/0.000 srv 10.8us
r20 r2  153.6k reg[64 2 0 0 0 0 0 0 0 0] ran%[76 11 2 2 2 2 2 1 2 1] kicks 0.096 sleeps 0.320 waits 0.182 polls 0.562 hits 0.384 ev/hit 5.5 young 0.568 wokeE/P 0.000/0.000 srv 9.6us
r10 r3  134.3k reg[51 3 0 0 0 0 0 0 10 2] ran%[35 15 2 2 2 2 2 2 23 13] kicks 0.249 sleeps 0.620 waits 0.507 polls 2.057 hits 0.831 ev/hit 2.7 young 0.003 wokeE/P 0.000/0.000 srv 15.9us
r10 r4  134.7k reg[45 14 0 0 0 0 0 0 3 4] ran%[33 24 2 2 2 2 2 2 14 16] kicks 0.245 sleeps 0.618 waits 0.505 polls 2.088 hits 0.854 ev/hit 2.6 young 0.001 wokeE/P 0.000/0.000 srv 16.2us
r10 r0  136.8k reg[63 2 0 0 0 0 0 0 1 0] ran%[40 17 4 4 4 3 4 4 14 4] kicks 0.261 sleeps 0.547 waits 0.414 polls 1.380 hits 0.649 ev/hit 3.5 young 0.001 wokeE/P 0.000/0.000 srv 15.0us
r10 r1  137.3k reg[39 24 0 0 0 0 0 0 2 1] ran%[33 30 2 2 2 2 2 3 13 11] kicks 0.248 sleeps 0.645 waits 0.509 polls 2.081 hits 0.889 ev/hit 2.5 young 0.003 wokeE/P 0.000/0.000 srv 15.5us
r10 r2  137.9k reg[49 17 0 0 0 0 0 0 0 0] ran%[37 29 5 4 4 4 4 5 5 4] kicks 0.247 sleeps 0.595 waits 0.438 polls 1.310 hits 0.764 ev/hit 2.9 young 0.003 wokeE/P 0.000/0.000 srv 14.6us
r20-age20 r2  142.6k reg[54 7 0 0 0 0 0 0 5 0] ran%[54 19 1 1 2 1 2 1 16 2] kicks 0.173 sleeps 0.519 waits 0.403 polls 1.234 hits 0.666 ev/hit 3.3 young 0.296 wokeE/P 0.000/0.000 srv 13.0us
r20-age20 r3  143.3k reg[56 3 0 0 0 0 0 0 0 7] ran%[56 13 2 2 2 1 1 1 2 20] kicks 0.168 sleeps 0.491 waits 0.371 polls 1.132 hits 0.620 ev/hit 3.5 young 0.314 wokeE/P 0.000/0.000 srv 12.5us
r20-age20 r4  145.8k reg[58 0 0 0 0 0 4 4 0 0] ran%[57 2 2 1 2 2 16 16 1 2] kicks 0.172 sleeps 0.476 waits 0.358 polls 1.084 hits 0.594 ev/hit 3.7 young 0.320 wokeE/P 0.000/0.000 srv 12.4us
r20-age20 r0  152.7k reg[66 0 0 0 0 0 0 0 0 0] ran%[71 4 3 3 4 3 3 4 3 4] kicks 0.156 sleeps 0.356 waits 0.203 polls 0.451 hits 0.399 ev/hit 5.4 young 0.451 wokeE/P 0.000/0.000 srv 10.5us
r20-age20 r1  153.8k reg[66 0 0 0 0 0 0 0 0 0] ran%[71 3 3 2 3 3 3 3 4 3] kicks 0.157 sleeps 0.359 waits 0.203 polls 0.453 hits 0.402 ev/hit 5.4 young 0.454 wokeE/P 0.000/0.000 srv 10.4us
one-r20 r2  152.9k reg[66 0 0 0 0 0 0 0 0 0] ran%[80 3 2 2 2 3 2 2 2 2] kicks 0.086 sleeps 0.259 waits 0.120 polls 0.335 hits 0.298 ev/hit 7.0 young 0.628 wokeE/P 0.000/0.000 srv 9.2us
one-r20 r3  156.3k reg[66 0 0 0 0 0 0 0 0 0] ran%[80 2 2 2 2 2 2 3 2 2] kicks 0.084 sleeps 0.254 waits 0.115 polls 0.326 hits 0.291 ev/hit 7.2 young 0.631 wokeE/P 0.000/0.000 srv 9.0us
one-r20 r0  157.5k reg[66 0 0 0 0 0 0 0 0 0] ran%[79 2 2 3 2 3 2 2 2 3] kicks 0.088 sleeps 0.265 waits 0.123 polls 0.345 hits 0.302 ev/hit 6.9 young 0.609 wokeE/P 0.000/0.000 srv 9.1us
one-r20 r4  158.1k reg[66 0 0 0 0 0 0 0 0 0] ran%[82 2 2 2 2 1 2 2 2 2] kicks 0.079 sleeps 0.249 waits 0.110 polls 0.320 hits 0.287 ev/hit 7.3 young 0.646 wokeE/P 0.000/0.000 srv 8.7us
one-r20 r1  158.8k reg[66 0 0 0 0 0 0 0 0 0] ran%[81 2 2 3 2 2 2 2 2 2] kicks 0.084 sleeps 0.254 waits 0.115 polls 0.326 hits 0.291 ev/hit 7.2 young 0.645 wokeE/P 0.000/0.000 srv 8.8us
e3-50 r1  130.7k reg[40 11 12 0 0 0 0 0 3 0] ran%[34 23 24 1 1 1 1 1 13 1] kicks 0.248 sleeps 0.629 waits 0.532 polls 1.792 hits 0.875 ev/hit 2.6 young 0.000 wokeE/P 0.000/0.000 srv 14.8us
e3-50 r4  143.9k reg[55 0 0 0 0 0 0 0 0 11] ran%[41 4 3 4 4 4 4 4 3 29] kicks 0.259 sleeps 0.568 waits 0.426 polls 1.126 hits 0.706 ev/hit 3.2 young 0.000 wokeE/P 0.000/0.000 srv 12.1us
e3-50 r2  146.8k reg[66 0 0 0 0 0 0 0 0 0] ran%[48 6 3 4 8 7 6 7 5 7] kicks 0.259 sleeps 0.492 waits 0.348 polls 0.654 hits 0.543 ev/hit 4.2 young 0.000 wokeE/P 0.000/0.000 srv 11.3us
e3-50 r3  147.4k reg[66 0 0 0 0 0 0 0 0 0] ran%[47 2 7 6 7 5 6 7 6 7] kicks 0.254 sleeps 0.484 waits 0.342 polls 0.643 hits 0.533 ev/hit 4.2 young 0.000 wokeE/P 0.000/0.000 srv 11.1us
e3-50 r0  148.0k reg[51 15 0 0 0 0 0 0 0 0] ran%[40 30 4 4 3 4 1 4 4 5] kicks 0.249 sleeps 0.565 waits 0.419 polls 1.127 hits 0.716 ev/hit 3.1 young 0.000 wokeE/P 0.000/0.000 srv 11.7us
one-e3-50 r3  144.4k reg[66 0 0 0 0 0 0 0 0 0] ran%[47 7 5 5 5 7 8 4 6 5] kicks 0.253 sleeps 0.475 waits 0.337 polls 0.627 hits 0.522 ev/hit 4.3 young 0.000 wokeE/P 0.000/0.000 srv 11.5us
one-e3-50 r2  145.4k reg[66 0 0 0 0 0 0 0 0 0] ran%[47 7 6 5 5 6 5 7 6 6] kicks 0.259 sleeps 0.489 waits 0.347 polls 0.648 hits 0.539 ev/hit 4.2 young 0.000 wokeE/P 0.000/0.000 srv 11.4us
one-e3-50 r1  147.8k reg[66 0 0 0 0 0 0 0 0 0] ran%[48 7 5 6 7 6 6 5 5 6] kicks 0.259 sleeps 0.492 waits 0.348 polls 0.655 hits 0.543 ev/hit 4.2 young 0.000 wokeE/P 0.000/0.000 srv 11.2us
one-e3-50 r4  148.4k reg[66 0 0 0 0 0 0 0 0 0] ran%[47 6 5 6 6 5 7 5 6 8] kicks 0.266 sleeps 0.504 waits 0.358 polls 0.673 hits 0.556 ev/hit 4.1 young 0.000 wokeE/P 0.000/0.000 srv 11.3us
one-e3-50 r0  149.7k reg[66 0 0 0 0 0 0 0 0 0] ran%[47 7 4 6 5 6 7 6 5 6] kicks 0.268 sleeps 0.505 waits 0.362 polls 0.677 hits 0.558 ev/hit 4.1 young 0.000 wokeE/P 0.000/0.000 srv 11.3us
r20-e3 r1  148.4k reg[57 2 0 0 0 0 0 2 5 0] ran%[65 8 0 1 1 1 1 9 14 0] kicks 0.114 sleeps 0.427 waits 0.345 polls 1.038 hits 0.563 ev/hit 3.8 young 0.470 wokeE/P 0.000/0.000 srv 11.0us
r20-e3 r2  149.7k reg[56 0 9 0 0 0 0 1 0 0] ran%[69 1 20 1 1 1 0 6 1 1] kicks 0.091 sleeps 0.414 waits 0.283 polls 0.856 hits 0.531 ev/hit 3.9 young 0.500 wokeE/P 0.000/0.000 srv 10.3us
r20-e3 r4  151.5k reg[58 4 0 0 0 0 0 0 0 4] ran%[70 12 1 1 1 1 1 1 1 12] kicks 0.097 sleeps 0.399 waits 0.295 polls 0.865 hits 0.512 ev/hit 4.1 young 0.508 wokeE/P 0.000/0.000 srv 10.4us
r20-e3 r0  152.6k reg[54 1 0 0 0 0 0 0 0 11] ran%[67 6 0 1 0 1 1 1 1 22] kicks 0.085 sleeps 0.413 waits 0.277 polls 0.841 hits 0.529 ev/hit 3.9 young 0.503 wokeE/P 0.000/0.000 srv 10.2us
r20-e3 r3  156.8k reg[66 0 0 0 0 0 0 0 0 0] ran%[83 2 2 1 2 2 1 2 2 2] kicks 0.076 sleeps 0.244 waits 0.105 polls 0.309 hits 0.281 ev/hit 7.4 young 0.659 wokeE/P 0.000/0.000 srv 8.6us
one-r20-e3 r2  154.3k reg[66 0 0 0 0 0 0 0 0 0] ran%[82 2 2 2 2 2 2 2 2 1] kicks 0.083 sleeps 0.257 waits 0.115 polls 0.327 hits 0.295 ev/hit 7.1 young 0.647 wokeE/P 0.000/0.000 srv 8.9us
one-r20-e3 r3  156.1k reg[66 0 0 0 0 0 0 0 0 0] ran%[80 2 2 2 3 2 2 3 2 2] kicks 0.086 sleeps 0.253 waits 0.116 polls 0.320 hits 0.289 ev/hit 7.2 young 0.635 wokeE/P 0.000/0.000 srv 8.9us
one-r20-e3 r1  158.0k reg[66 0 0 0 0 0 0 0 0 0] ran%[82 2 2 2 2 2 2 2 2 2] kicks 0.083 sleeps 0.254 waits 0.113 polls 0.323 hits 0.292 ev/hit 7.1 young 0.649 wokeE/P 0.000/0.000 srv 8.7us
one-r20-e3 r4  159.4k reg[66 0 0 0 0 0 0 0 0 0] ran%[82 2 2 2 2 1 2 3 2 1] kicks 0.081 sleeps 0.244 waits 0.108 polls 0.307 hits 0.279 ev/hit 7.4 young 0.655 wokeE/P 0.000/0.000 srv 8.6us
one-r20-e3 r0  163.0k reg[66 0 0 0 0 0 0 0 0 0] ran%[84 2 2 2 2 2 2 2 2 1] kicks 0.074 sleeps 0.243 waits 0.102 polls 0.307 hits 0.279 ev/hit 7.4 young 0.672 wokeE/P 0.000/0.000 srv 8.3us
age50s r2  147.3k reg[65 1 0 0 0 0 0 0 0 0] ran%[67 16 2 2 2 2 2 2 2 2] kicks 0.073 sleeps 0.304 waits 0.156 polls 0.614 hits 0.369 ev/hit 5.6 young 0.621 wokeE/P 0.000/0.000 srv 10.3us
age50s r4  149.8k reg[60 0 4 0 0 0 0 0 2 0] ran%[55 1 23 1 1 1 1 1 16 1] kicks 0.059 sleeps 0.379 waits 0.237 polls 1.088 hits 0.513 ev/hit 4.0 young 0.582 wokeE/P 0.000/0.000 srv 10.4us
age50s r0  151.2k reg[55 0 0 0 0 0 0 0 5 6] ran%[49 1 1 1 1 0 1 1 22 24] kicks 0.054 sleeps 0.413 waits 0.275 polls 1.270 hits 0.588 ev/hit 3.5 young 0.555 wokeE/P 0.000/0.000 srv 10.7us
age50s r3  151.4k reg[63 2 0 0 0 0 0 0 0 1] ran%[59 19 1 1 1 1 1 1 1 13] kicks 0.065 sleeps 0.332 waits 0.190 polls 0.877 hits 0.426 ev/hit 4.8 young 0.610 wokeE/P 0.000/0.000 srv 10.1us
age50s r1  155.9k reg[66 0 0 0 0 0 0 0 0 0] ran%[76 3 2 1 2 3 3 3 3 3] kicks 0.065 sleeps 0.272 waits 0.115 polls 0.378 hits 0.314 ev/hit 6.6 young 0.657 wokeE/P 0.000/0.000 srv 9.2us
```

### A11. bench/mixed at 100,000 a second, probe c3 (claim mcl-U2, 4 rounds; a VM at 23% of a core, stalls in most arms): raw/u2-mix100.jsonl

# 2026-11-17 20:30:21 load { 5.61 7.08 7.09 } cpu_all 124% over20: 48.4% WindowServer; 23.4% vmware-vmx rate 100000 mix 4 idle 5000 workers None
# 2026-11-17 20:36:15 load { 9.69 7.75 7.31 } cpu_all 99% over20: 36.0% WindowServer (end)
| arm | n | achieved | cycles k [range] | /main paired [range] | user / sys µs | cores | P % | csw | intwk | p50 | p99 [range] | p99.9 | lateness p99 | rounds p99 > 5 ms | rounds p99 > 10 ms |
|---|---:|---:|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|
| main | 4 | 99998 | 77.3 [75.3-82.5] | 1.000 [1.000-1.000] | 10.50 / 10.39 | 2.09 | 70 | 0.607 | 0.016 | 72 | 2319 [1034-183984] | 6042 | 603 | 1 | 1 |
| aa | 4 | 99998 | 78.0 [75.7-80.3] | 1.007 [0.974-1.010] | 10.73 / 10.74 | 2.15 | 68 | 0.599 | 0.016 | 76 | 9049 [1141-17122] | 12685 | 594 | 2 | 2 |
| p3 | 4 | 99997 | 79.2 [76.3-81.9] | 1.019 [0.964-1.056] | 10.92 / 11.11 | 2.21 | 66 | 0.586 | 0.017 | 79 | 8741 [1069-82702] | 10665 | 656 | 2 | 2 |
| one | 4 | 99998 | 77.7 [76.9-78.0] | 1.008 [0.939-1.020] | 10.67 / 10.54 | 2.12 | 69 | 0.596 | 0.016 | 74 | 1229 [1084-4129] | 4719 | 584 | 0 | 0 |
| r20 | 4 | 99998 | 78.2 [77.2-80.0] | 1.024 [0.940-1.031] | 10.87 / 10.80 | 2.17 | 68 | 0.588 | 0.016 | 80 | 3861 [1284-74871] | 7998 | 695 | 2 | 1 |
| r10 | 4 | 99998 | 77.8 [76.5-78.7] | 1.010 [0.928-1.038] | 10.75 / 10.67 | 2.14 | 69 | 0.599 | 0.016 | 75 | 1137 [965-1313] | 2130 | 559 | 0 | 0 |
| r20-age20 | 4 | 99998 | 78.0 [77.6-84.0] | 1.013 [1.005-1.037] | 10.90 / 10.74 | 2.16 | 69 | 0.589 | 0.016 | 76 | 1157 [1074-212613] | 3003 | 577 | 1 | 1 |
| one-r20 | 4 | 99999 | 78.7 [78.0-80.2] | 1.024 [0.957-1.041] | 10.80 / 10.99 | 2.19 | 67 | 0.596 | 0.016 | 79 | 11169 [1017-30582] | 13226 | 598 | 2 | 2 |
| e3-50 | 4 | 99998 | 71.7 [70.8-77.2] | 0.942 [0.859-0.995] | 10.08 / 8.84 | 1.90 | 82 | 0.551 | 0.019 | 80 | 2340 [1031-63316] | 5583 | 688 | 1 | 1 |
| one-e3-50 | 4 | 99998 | 72.0 [71.2-75.6] | 0.937 [0.878-0.974] | 10.12 / 8.80 | 1.89 | 82 | 0.554 | 0.019 | 80 | 2770 [1015-11089] | 6530 | 622 | 1 | 1 |
| r20-e3 | 4 | 99997 | 71.8 [71.0-73.7] | 0.927 [0.894-0.946] | 9.97 / 8.75 | 1.88 | 82 | 0.556 | 0.019 | 80 | 2002 [969-3732] | 3629 | 585 | 0 | 0 |
- main: 75.3k/67/1034 77.0k/71/3479 82.5k/96/183984 77.6k/73/1160
- aa: 75.7k/68/1223 77.6k/76/1141 80.3k/89/17122 78.3k/76/16875
- p3: 76.3k/72/1069 78.9k/77/1133 79.5k/81/16349 81.9k/98/82702
- one: 76.9k/74/1095 78.0k/78/1363 77.5k/73/1084 77.8k/75/4129
- r20: 77.2k/79/5943 78.8k/81/74871 77.5k/72/1284 80.0k/85/1779
- r10: 78.2k/80/1283 77.4k/72/991 76.5k/69/965 78.7k/78/1313
- r20-age20: 78.1k/79/1182 77.6k/73/1074 84.0k/4059/212613 77.9k/74/1132
- one-r20: 78.4k/79/1134 78.0k/74/1017 78.9k/79/30582 80.2k/86/21204
- e3-50: 71.9k/83/1513 71.6k/78/3168 70.8k/75/1031 77.2k/110/63316
- one-e3-50: 71.2k/82/1145 71.5k/77/1015 72.4k/79/4395 75.6k/96/11089
- r20-e3: 71.2k/81/1151 71.0k/74/969 73.7k/86/3732 72.4k/80/2853

### A12. PROOF, closed loop, plain builds (claim mcl-P1, 15 rounds): raw/p1-closed.jsonl

# 2026-11-17 20:46:14 load { 2.29 5.00 6.18 } cpu_all 124% over20: 100.0% zig
# 2026-11-17 20:51:45 load { 11.53 8.17 7.23 } cpu_all 497% over20: 488.4% bfs (end)
| arm | n | req/s median | range | best | p50 / p99 µs | /main paired [range] | server µs (user/sys) | server cores | cycles k | P % | csw | intwk | syscalls | busiest thread % | threads >5% | gen µs | gen cores | gen P % |
|---|---:|---:|---|---:|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 15 | 134052 | 104416-139762 | 139762 | 471 / 643 | 1.000 [1.000-1.000] | 16.5 (2.3/14.2) | 2.13 | 57.0 | 63 | 0.51 | 0.043 | 4.06 | 32 | 5 | 24.1 | 3.26 | 54 |
| aa | 15 | 133485 | 106282-140127 | 140127 | 471 / 649 | 1.011 [0.911-1.258] | 16.5 (2.4/14.0) | 2.18 | 58.4 | 64 | 0.51 | 0.044 | 4.20 | 32 | 4 | 24.2 | 3.24 | 54 |
| hyper | 15 | 138294 | 107041-140125 | 140125 | 455 / 636 | 1.026 [0.912-1.276] | 16.0 (2.8/13.2) | 2.22 | 58.2 | 64 | 0.46 | 0.002 | 2.93 | 11 | 10 | 23.4 | 3.25 | 55 |
| fin | 15 | 149698 | 111744-157803 | 157803 | 419 / 590 | 1.102 [0.940-1.237] | 11.2 (1.6/9.8) | 1.66 | 42.3 | 73 | 0.33 | 0.051 | 3.00 | 52 | 3 | 21.8 | 3.28 | 57 |
| one | 15 | 141377 | 107123-142591 | 142591 | 445 / 621 | 1.045 [0.930-1.157] | 14.4 (1.9/12.5) | 2.02 | 52.7 | 68 | 0.42 | 0.020 | 3.01 | 38 | 10 | 23.5 | 3.30 | 55 |
| finone | 15 | 159381 | 107556-161004 | 161004 | 390 / 580 | 1.173 [1.007-1.296] | 8.8 (1.0/7.7) | 1.40 | 34.2 | 84 | 0.15 | 0.024 | 2.43 | 69 | 1 | 21.0 | 3.35 | 57 |

Every round (k req/s), in round order:
- main: 125.9 136.8 122.8 134.3 134.1 138.8 139.8 137.3 131.6 126.6 137.2 136.0 132.6 104.4 109.4
- aa: 125.5 124.6 133.5 135.8 139.7 132.6 132.8 135.6 137.4 131.8 133.5 140.1 138.3 131.4 106.3
- hyper: 124.9 124.8 138.3 139.2 140.1 136.6 135.0 139.6 139.5 137.9 139.6 139.5 139.2 133.2 107.0
- fin: 138.5 128.6 150.1 146.8 154.4 153.0 151.2 157.8 149.7 156.4 149.9 149.2 147.8 129.1 111.7
- one: 129.2 127.2 141.4 141.4 142.3 141.8 142.0 137.6 141.9 135.3 142.6 142.0 139.1 107.1 126.6
- finone: 139.5 137.8 159.2 158.2 159.4 159.8 160.3 158.6 161.0 160.9 160.9 160.6 160.7 107.6 113.0

The same against hyper:

| arm | n | req/s median | range | best | p50 / p99 µs | /hyper paired [range] 
|---|---:|---:|---|---:|---|---
| main | 15 | 134052 | 104416-139762 | 139762 | 471 / 643 | 0.975 [0.784-1.096] 
| aa | 15 | 133485 | 106282-140127 | 140127 | 471 / 649 | 0.985 [0.956-1.005] 
| hyper | 15 | 138294 | 107041-140125 | 140125 | 455 / 636 | 1.000 [1.000-1.000] 
| fin | 15 | 149698 | 111744-157803 | 157803 | 419 / 590 | 1.074 [0.969-1.134] 
| one | 15 | 141377 | 107123-142591 | 142591 | 445 / 621 | 1.018 [0.804-1.183] 
| finone | 15 | 159381 | 107556-161004 | 161004 | 390 / 580 | 1.151 [0.808-1.187] 

### A13. A12's runs of main and of fin, sorted by requests a second, with their counters


**main**, runs sorted by req/s:

| rps_k | srv_us | srv_cyc_k | srv_P% | top_thr% | top_thr_P% | thr>5% | csw | intwk | sysc | gen_us | gen_cores | gen_P% | gen_csw | round |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 104.4 | 16.9 | 53.6 | 23.8 | 30.9 | 19.7 | 5 | 0.355 | 0.037 | 3.622 | 20.0 | 2.1 | 20.1 | 0.628 | 13 |
| 109.4 | 16.2 | 53.4 | 36.9 | 33.0 | 35.2 | 4 | 0.384 | 0.034 | 3.518 | 20.4 | 2.2 | 31.6 | 0.762 | 14 |
| 122.8 | 16.5 | 56.7 | 52.1 | 34.6 | 62.9 | 7 | 0.432 | 0.035 | 3.445 | 24.9 | 3.1 | 43.2 | 1.191 | 2 |
| 125.9 | 16.5 | 58.4 | 55.6 | 33.6 | 65.4 | 3 | 0.467 | 0.038 | 3.797 | 24.6 | 3.1 | 47.0 | 1.250 | 0 |
| 126.6 | 17.8 | 62.9 | 56.2 | 27.9 | 63.4 | 5 | 0.590 | 0.066 | 4.890 | 24.0 | 3.0 | 49.3 | 1.286 | 9 |
| 131.6 | 18.2 | 65.8 | 62.9 | 24.9 | 68.7 | 5 | 0.663 | 0.080 | 5.252 | 24.7 | 3.3 | 54.3 | 1.365 | 8 |
| 132.6 | 17.4 | 62.9 | 63.3 | 28.3 | 71.1 | 5 | 0.587 | 0.063 | 4.905 | 24.6 | 3.3 | 54.3 | 1.340 | 12 |
| 134.1 | 17.3 | 62.6 | 63.3 | 28.5 | 71.6 | 5 | 0.556 | 0.056 | 4.765 | 24.4 | 3.3 | 54.3 | 1.282 | 4 |
| 134.3 | 17.2 | 62.5 | 64.1 | 28.8 | 72.2 | 5 | 0.557 | 0.056 | 4.771 | 24.5 | 3.3 | 54.8 | 1.320 | 3 |
| 136.0 | 15.6 | 56.6 | 65.0 | 32.3 | 73.2 | 3 | 0.513 | 0.044 | 4.017 | 24.0 | 3.3 | 54.2 | 1.296 | 11 |
| 136.8 | 15.6 | 57.0 | 66.2 | 32.4 | 73.7 | 3 | 0.525 | 0.043 | 4.077 | 24.3 | 3.3 | 54.1 | 1.355 | 1 |
| 137.2 | 15.8 | 57.9 | 66.1 | 32.3 | 74.6 | 4 | 0.499 | 0.040 | 4.202 | 24.1 | 3.3 | 55.1 | 1.303 | 10 |
| 137.3 | 15.6 | 57.0 | 65.8 | 31.8 | 73.8 | 3 | 0.517 | 0.046 | 4.060 | 24.1 | 3.3 | 55.3 | 1.309 | 7 |
| 138.8 | 14.9 | 55.0 | 66.9 | 33.1 | 74.7 | 6 | 0.475 | 0.035 | 3.605 | 24.0 | 3.3 | 55.4 | 1.286 | 5 |
| 139.8 | 14.8 | 54.3 | 67.5 | 32.7 | 74.7 | 6 | 0.483 | 0.036 | 3.645 | 23.8 | 3.3 | 55.5 | 1.265 | 6 |
| rank correlation with req/s | -0.65 | -0.04 | 0.98 | 0.07 | 0.99 | 0.12 | 0.24 | 0.06 | 0.12 | -0.13 | 0.95 | 0.91 | 0.45 | -0.23 |

**fin**, runs sorted by req/s:

| rps_k | srv_us | srv_cyc_k | srv_P% | top_thr% | top_thr_P% | thr>5% | csw | intwk | sysc | gen_us | gen_cores | gen_P% | gen_csw | round |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 111.7 | 15.0 | 48.5 | 32.9 | 45.1 | 28.3 | 3 | 0.295 | 0.037 | 2.849 | 20.8 | 2.3 | 29.4 | 0.785 | 14 |
| 128.6 | 14.5 | 51.0 | 57.6 | 44.7 | 70.5 | 3 | 0.408 | 0.054 | 3.373 | 24.0 | 3.1 | 44.9 | 1.227 | 1 |
| 129.1 | 12.9 | 45.2 | 52.9 | 49.4 | 62.1 | 2 | 0.280 | 0.029 | 2.737 | 21.6 | 2.8 | 41.3 | 1.062 | 13 |
| 138.5 | 11.2 | 41.7 | 69.6 | 61.5 | 86.0 | 1 | 0.201 | 0.025 | 2.517 | 22.9 | 3.2 | 40.7 | 1.110 | 0 |
| 146.8 | 11.9 | 44.2 | 72.0 | 49.0 | 84.1 | 4 | 0.433 | 0.068 | 3.423 | 22.1 | 3.2 | 57.0 | 1.280 | 3 |
| 147.8 | 11.9 | 44.7 | 72.0 | 48.4 | 83.7 | 4 | 0.430 | 0.067 | 3.422 | 22.3 | 3.3 | 56.9 | 1.313 | 12 |
| 149.2 | 11.5 | 43.1 | 72.6 | 50.2 | 84.2 | 3 | 0.410 | 0.064 | 3.264 | 22.1 | 3.3 | 58.0 | 1.302 | 11 |
| 149.7 | 11.5 | 43.4 | 73.0 | 50.6 | 84.9 | 4 | 0.418 | 0.067 | 3.363 | 21.9 | 3.3 | 57.7 | 1.280 | 8 |
| 149.9 | 11.2 | 42.3 | 73.3 | 53.1 | 85.7 | 3 | 0.363 | 0.056 | 3.137 | 21.8 | 3.3 | 57.2 | 1.260 | 10 |
| 150.1 | 11.0 | 41.1 | 75.0 | 55.1 | 87.3 | 3 | 0.360 | 0.059 | 3.126 | 21.9 | 3.3 | 57.1 | 1.284 | 2 |
| 151.2 | 10.9 | 41.0 | 74.1 | 51.6 | 83.9 | 2 | 0.325 | 0.040 | 2.954 | 21.7 | 3.3 | 58.0 | 1.277 | 6 |
| 153.0 | 10.5 | 39.9 | 76.2 | 57.1 | 88.3 | 3 | 0.320 | 0.051 | 3.004 | 21.6 | 3.3 | 57.5 | 1.260 | 5 |
| 154.4 | 10.1 | 38.8 | 78.0 | 58.8 | 90.4 | 2 | 0.283 | 0.044 | 2.825 | 21.5 | 3.3 | 57.3 | 1.286 | 4 |
| 156.4 | 9.7 | 37.6 | 79.6 | 61.6 | 91.6 | 3 | 0.273 | 0.046 | 2.875 | 21.3 | 3.3 | 57.4 | 1.275 | 9 |
| 157.8 | 9.3 | 36.3 | 80.9 | 64.4 | 92.5 | 2 | 0.232 | 0.040 | 2.694 | 21.2 | 3.3 | 57.7 | 1.271 | 7 |
| rank correlation with req/s | -0.96 | -0.94 | 0.99 | 0.80 | 0.86 | 0.13 | -0.29 | 0.04 | -0.23 | -0.44 | 0.90 | 0.71 | 0.40 | -0.14 |

**hyper**, runs sorted by req/s:

| rps_k | srv_us | srv_cyc_k | srv_P% | top_thr% | top_thr_P% | thr>5% | csw | intwk | sysc | gen_us | gen_cores | gen_P% | gen_csw | round |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 107.0 | 16.6 | 53.0 | 26.2 | 10.9 | 27.2 | 10 | 0.260 | 0.002 | 2.448 | 19.9 | 2.1 | 25.4 | 0.685 | 14 |
| 124.8 | 17.5 | 60.0 | 50.8 | 11.3 | 50.5 | 10 | 0.432 | 0.003 | 2.858 | 24.0 | 3.0 | 45.7 | 1.193 | 1 |
| 124.9 | 17.4 | 60.5 | 50.9 | 10.9 | 50.6 | 10 | 0.442 | 0.003 | 2.856 | 23.9 | 3.0 | 45.8 | 1.213 | 0 |
| 133.2 | 16.1 | 57.6 | 59.6 | 11.0 | 59.1 | 10 | 0.450 | 0.002 | 2.901 | 22.8 | 3.0 | 53.5 | 1.176 | 13 |
| 135.0 | 16.0 | 57.9 | 63.7 | 11.0 | 63.7 | 10 | 0.468 | 0.002 | 2.921 | 23.4 | 3.2 | 54.4 | 1.240 | 6 |
| 136.6 | 16.2 | 58.4 | 63.3 | 10.6 | 63.7 | 10 | 0.487 | 0.002 | 2.955 | 23.5 | 3.2 | 54.6 | 1.277 | 5 |
| 137.9 | 16.1 | 58.3 | 62.7 | 11.3 | 61.7 | 10 | 0.468 | 0.002 | 2.950 | 23.5 | 3.2 | 53.7 | 1.274 | 9 |
| 138.3 | 16.0 | 58.2 | 64.0 | 10.8 | 64.2 | 10 | 0.468 | 0.002 | 2.935 | 23.6 | 3.3 | 54.7 | 1.259 | 2 |
| 139.2 | 16.1 | 58.8 | 64.2 | 10.9 | 63.9 | 10 | 0.462 | 0.002 | 2.925 | 23.7 | 3.3 | 54.9 | 1.253 | 12 |
| 139.2 | 15.9 | 57.9 | 64.4 | 11.2 | 64.8 | 10 | 0.458 | 0.002 | 2.926 | 23.3 | 3.2 | 55.0 | 1.229 | 3 |
| 139.5 | 16.0 | 58.4 | 64.7 | 10.9 | 64.6 | 10 | 0.470 | 0.002 | 2.938 | 23.5 | 3.3 | 54.9 | 1.251 | 8 |
| 139.5 | 15.9 | 58.0 | 64.8 | 11.2 | 64.9 | 10 | 0.457 | 0.002 | 2.928 | 23.4 | 3.3 | 55.0 | 1.227 | 11 |
| 139.6 | 16.0 | 58.3 | 64.7 | 11.0 | 64.9 | 10 | 0.468 | 0.002 | 2.949 | 23.4 | 3.3 | 55.1 | 1.227 | 10 |
| 139.6 | 15.9 | 58.0 | 65.1 | 11.8 | 64.7 | 10 | 0.463 | 0.002 | 2.942 | 23.3 | 3.2 | 55.1 | 1.214 | 7 |
| 140.1 | 15.9 | 58.1 | 64.9 | 11.0 | 65.3 | 10 | 0.467 | 0.002 | 2.934 | 23.2 | 3.2 | 55.2 | 1.220 | 4 |
| rank correlation with req/s | -0.84 | -0.04 | 0.97 | 0.26 | 0.95 | 1.00 | 0.42 | -0.32 | 0.62 | -0.23 | 0.80 | 0.98 | 0.27 | 0.05 |

### A14. PROOF, bench/net (claim mcl-P5, 15 rounds): raw/p5-net.jsonl

# 2026-11-17 20:52:37 load { 6.10 7.25 6.95 } cpu_all 28% over20: none
# 2026-11-17 20:54:20 load { 5.05 6.64 6.74 } cpu_all 52% over20: 38.1% corespotlightd (end)
| row | main ms median (fastest) | aa ms median (fastest) | fin ms median (fastest) | one ms median (fastest) | finone ms median (fastest) | aa / main [range] | fin / main [range] | one / main [range] | finone / main [range] |
|---|---:|---:|---:|---:|---:|---|---|---|---|
| pingpong | 328.33 (323.63) | 327.34 (323.87) | 329.14 (322.37) | 329.11 (325.74) | 330.78 (326.58) | 0.997 [0.938-1.082] | 1.003 [0.937-1.088] | 1.005 [0.932-1.084] | 1.006 [0.932-1.087] |
| echo | 812.52 (780.81) | 813.10 (747.51) | 716.64 (613.21) | 601.61 (596.30) | 585.41 (561.88) | 1.016 [0.933-1.035] | 0.881 [0.753-0.941] | 0.750 [0.727-0.820] | 0.728 [0.691-0.774] |
| connect | 26.19 (25.20) | 26.24 (24.98) | 25.90 (24.58) | 25.75 (23.73) | 25.89 (24.95) | 0.994 [0.956-1.057] | 0.981 [0.934-1.041] | 0.982 [0.915-1.073] | 0.988 [0.932-1.011] |
- pingpong main: 343.32 328.33 329.73 328.60 328.94 354.77 327.59 326.65 326.96 324.99 348.49 326.02 327.73 329.75 323.63
- pingpong aa: 325.01 327.34 328.57 331.55 331.24 334.35 333.69 323.87 324.04 351.64 327.00 325.64 328.42 326.88 326.28
- pingpong fin: 327.32 329.44 329.14 330.05 322.37 332.41 329.98 326.74 330.71 352.45 327.25 327.11 328.82 327.16 352.17
- pingpong one: 329.11 327.24 325.74 331.28 353.91 330.76 329.74 346.83 328.69 351.38 327.63 328.06 328.32 327.98 350.72
- pingpong finone: 336.41 328.35 326.58 330.26 330.45 330.78 329.54 333.66 333.02 334.54 326.86 328.88 352.09 350.87 351.71
- echo main: 812.52 806.41 809.42 819.01 799.29 828.43 817.44 813.59 789.49 813.45 800.82 814.37 789.43 820.01 780.81
- echo aa: 825.39 822.80 794.07 840.13 788.68 818.62 795.24 828.33 808.00 831.30 747.51 842.68 807.78 813.10 786.79
- echo fin: 715.65 703.59 752.90 747.44 716.64 737.28 718.20 679.06 743.08 720.76 649.79 613.21 667.96 665.33 721.38
- echo one: 599.50 601.18 664.12 600.51 613.05 602.09 609.13 631.19 599.83 602.40 600.32 618.03 597.32 596.30 601.61
- echo finone: 581.22 589.98 583.34 600.06 582.01 634.08 586.01 561.88 595.49 611.30 580.20 584.77 570.62 634.93 585.41
- connect main: 25.20 25.57 25.94 26.40 26.15 26.19 27.78 25.65 26.23 26.65 26.50 25.97 26.40 26.55 25.69
- connect aa: 24.98 25.05 25.97 27.91 26.18 26.00 26.55 26.64 25.99 26.47 26.35 25.91 26.24 26.88 26.76
- connect fin: 24.58 25.00 25.90 26.05 27.22 25.26 25.95 25.72 25.59 26.15 26.19 26.72 25.85 26.04 25.13
- connect one: 24.78 25.01 23.73 25.75 28.05 26.14 25.75 24.98 26.07 24.70 26.02 26.66 26.62 25.72 26.34
- connect finone: 24.95 25.24 25.39 25.99 25.86 25.76 25.89 25.36 26.52 26.79 25.35 25.89 26.10 26.14 25.95

### A15. PROOF, bench/tasks (claim mcl-P5, 12 rounds): raw/p5-tasks.jsonl

# 2026-11-17 20:54:20 load { 5.05 6.64 6.74 } cpu_all 52% over20: 38.1% corespotlightd
# 2026-11-17 20:54:37 load { 7.10 7.02 6.88 } cpu_all 10% over20: none (end)
| row | main ms median (fastest) | aa ms median (fastest) | fin ms median (fastest) | finone ms median (fastest) | aa / main [range] | fin / main [range] | finone / main [range] |
|---|---:|---:|---:|---:|---|---|---|
| spawn | 16.71 (14.50) | 15.74 (11.78) | 15.19 (13.72) | 15.32 (11.83) | 0.929 [0.812-1.072] | 0.908 [0.784-1.021] | 0.889 [0.790-1.038] |
| chain | 0.59 (0.57) | 0.58 (0.57) | 0.56 (0.54) | 0.56 (0.55) | 0.989 [0.754-1.371] | 0.947 [0.529-1.002] | 0.949 [0.714-1.023] |
| fanout | 72.02 (69.38) | 71.47 (67.50) | 70.04 (68.76) | 69.66 (66.56) | 0.997 [0.884-1.419] | 0.966 [0.927-1.078] | 0.958 [0.874-1.064] |
| yield | 6.27 (6.08) | 6.25 (6.01) | 6.52 (6.20) | 6.35 (6.10) | 1.003 [0.824-1.193] | 1.039 [0.870-1.181] | 1.023 [0.802-1.151] |
| hog | 0.01 (0.01) | 0.01 (0.01) | 0.01 (0.01) | 0.01 (0.01) | 0.948 [0.738-1.482] | 0.936 [0.730-1.466] | 0.944 [0.671-1.829] |
| produce | 5.32 (5.28) | 5.30 (5.27) | 5.30 (5.23) | 5.32 (5.24) | 0.997 [0.994-1.007] | 0.998 [0.979-1.039] | 1.001 [0.993-1.018] |
- spawn main: 14.50 17.39 18.79 17.16 17.50 16.47 15.34 16.95 14.62 17.79 16.07 15.54
- spawn aa: 11.78 14.98 16.23 14.18 15.33 15.55 16.43 16.51 14.80 16.27 15.93 16.09
- spawn fin: 14.81 16.04 14.73 15.58 15.66 14.45 13.93 13.72 14.22 15.97 16.01 15.79
- spawn finone: 12.83 15.50 14.84 15.21 16.21 14.22 15.91 15.68 11.83 14.98 15.52 15.44
- chain main: 1.09 0.59 0.57 0.58 0.59 0.58 0.61 0.64 0.60 0.57 0.59 0.59
- chain aa: 0.82 0.59 0.58 0.57 0.59 0.79 0.58 0.59 0.58 0.57 0.57 0.58
- chain fin: 0.58 0.56 0.57 0.56 0.54 0.57 0.56 0.56 0.56 0.55 0.56 0.56
- chain finone: 0.78 0.56 0.56 0.59 0.56 0.55 0.55 0.55 0.56 0.55 0.58 0.55
- fanout main: 71.02 72.81 76.50 70.34 72.84 70.11 75.31 69.48 73.46 71.22 76.36 69.38
- fanout aa: 72.33 72.31 70.80 67.54 72.14 70.64 68.37 77.35 104.24 72.60 67.50 69.38
- fanout fin: 76.55 70.31 73.22 70.29 69.79 69.76 69.78 72.82 68.76 68.76 72.03 69.54
- fanout finone: 73.81 66.89 66.90 74.83 69.72 72.51 69.48 70.57 69.60 68.15 76.24 66.56
- yield main: 6.36 6.59 7.62 6.64 6.18 6.12 6.42 6.08 6.53 6.11 6.09 6.08
- yield aa: 6.30 6.15 6.28 6.04 6.46 6.67 6.01 7.26 6.15 6.59 6.22 6.17
- yield fin: 6.20 7.78 6.63 6.25 6.78 6.62 7.37 6.41 6.53 6.26 6.50 6.22
- yield finone: 6.75 6.21 6.11 6.43 6.70 6.33 6.10 6.16 6.25 6.38 6.53 7.00
- hog main: 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01
- hog aa: 0.01 0.01 0.01 0.01 0.01 0.02 0.01 0.01 0.01 0.01 0.01 0.01
- hog fin: 0.01 0.01 0.02 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01
- hog finone: 0.01 0.01 0.01 0.01 0.01 0.01 0.02 0.01 0.01 0.01 0.01 0.01
- produce main: 5.30 5.34 5.32 5.31 5.36 5.28 5.32 5.32 5.31 5.28 5.28 5.33
- produce aa: 5.27 5.31 5.34 5.31 5.34 5.31 5.30 5.29 5.30 5.30 5.29 5.31
- produce fin: 5.28 5.23 5.31 5.28 5.30 5.31 5.32 5.35 5.29 5.29 5.49 5.31
- produce finone: 5.32 5.33 5.30 5.32 5.45 5.24 5.36 5.32 5.30 5.31 5.36 5.31

### A16. PROOF, bench/mixed at 100,000 a second, 10 workers (claim mcl-P2, 8 rounds): raw/p2-mix100.jsonl (rounds: cycles/p50/p99)

# 2026-11-17 20:55:07 load { 4.90 6.49 6.69 } cpu_all 33% over20: none rate 100000 mix 4 idle 5000 workers None
# 2026-11-17 21:00:28 load { 7.10 7.01 6.87 } cpu_all 24% over20: none (end)
| arm | n | achieved | cycles k [range] | /main paired [range] | user / sys µs | cores | P % | csw | intwk | p50 | p99 [range] | p99.9 | lateness p99 | rounds p99 > 5 ms | rounds p99 > 10 ms |
|---|---:|---:|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|
| main | 8 | 99998 | 76.4 [75.0-80.1] | 1.000 [1.000-1.000] | 10.58 / 10.26 | 2.08 | 71 | 0.599 | 0.015 | 69 | 958 [751-82409] | 1272 | 382 | 2 | 2 |
| aa | 8 | 99998 | 76.8 [75.6-85.0] | 1.005 [0.974-1.109] | 10.64 / 10.37 | 2.10 | 70 | 0.604 | 0.016 | 70 | 1012 [883-173155] | 1977 | 393 | 1 | 1 |
| hyper | 8 | 99998 | 87.4 [85.9-89.6] | 1.144 [1.098-1.170] | 12.19 / 12.37 | 2.46 | 63 | 0.784 | 0.001 | 78 | 1209 [897-68243] | 2024 | 508 | 2 | 2 |
| fin | 8 | 99998 | 76.9 [75.4-78.8] | 1.005 [0.964-1.027] | 10.62 / 10.40 | 2.10 | 70 | 0.603 | 0.016 | 71 | 1054 [843-80971] | 1717 | 465 | 1 | 1 |
| finone | 8 | 99998 | 76.7 [75.3-82.0] | 1.004 [0.973-1.070] | 10.60 / 10.38 | 2.10 | 70 | 0.597 | 0.016 | 70 | 1039 [847-3686] | 1945 | 456 | 0 | 0 |
- main: 75.0k/64/765 76.3k/70/945 77.2k/72/20767 76.5k/69/944 76.7k/71/972 80.1k/89/82409 75.8k/67/751 76.0k/67/1024
- aa: 75.6k/65/883 76.4k/68/984 76.4k/70/1023 77.2k/71/1001 85.0k/103/173155 78.0k/76/1088 77.2k/71/1068 75.6k/66/938
- hyper: 85.9k/70/913 86.2k/71/897 86.7k/75/1004 89.5k/85/14856 89.6k/86/1873 88.0k/80/1095 88.7k/86/1324 86.8k/76/68243
- fin: 75.4k/65/874 76.6k/70/1023 78.2k/78/80971 76.1k/69/924 78.8k/79/1320 77.3k/73/1085 77.5k/73/3817 75.9k/67/843
- finone: 75.3k/66/948 76.6k/70/1189 76.5k/70/990 76.8k/71/1042 82.0k/77/1104 77.9k/76/3686 77.4k/73/1036 75.7k/67/847

### A17. PROOF, bench/mixed at 55,000 a second, 2 workers (claim mcl-P3, 8 rounds): raw/p3-mix55w2.jsonl

# 2026-11-17 21:00:59 load { 4.69 6.43 6.67 } cpu_all 35% over20: none rate 55000 mix 4 idle 5000 workers 2
# 2026-11-17 21:06:19 load { 3.60 4.63 5.74 } cpu_all 27% over20: none (end)
| arm | n | achieved | cycles k [range] | /main paired [range] | user / sys µs | cores | P % | csw | intwk | p50 | p99 [range] | p99.9 | lateness p99 | rounds p99 > 5 ms | rounds p99 > 10 ms |
|---|---:|---:|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|
| main | 8 | 54999 | 62.4 [61.9-65.3] | 1.000 [1.000-1.000] | 9.54 / 6.17 | 0.86 | 95 | 0.838 | 0.013 | 42 | 359 [333-467] | 952 | 21 | 0 | 0 |
| aa | 8 | 54999 | 62.4 [62.1-62.8] | 1.000 [0.955-1.005] | 9.53 / 6.16 | 0.86 | 95 | 0.838 | 0.013 | 42 | 369 [246-661] | 956 | 18 | 0 | 0 |
| hyper | 8 | 54999 | 64.5 [64.2-65.8] | 1.034 [0.989-1.052] | 9.89 / 6.28 | 0.89 | 96 | 0.859 | 0.004 | 44 | 387 [255-916] | 986 | 16 | 0 | 0 |
| fin | 8 | 54999 | 62.3 [61.9-65.1] | 1.000 [0.954-1.030] | 9.52 / 6.14 | 0.86 | 95 | 0.837 | 0.013 | 42 | 353 [276-437] | 949 | 17 | 0 | 0 |
| finone | 8 | 54999 | 62.2 [61.7-63.2] | 0.997 [0.952-1.006] | 9.51 / 6.12 | 0.86 | 96 | 0.837 | 0.013 | 42 | 354 [261-482] | 955 | 14 | 0 | 0 |
- main: 62.2k/41/368 61.9k/41/372 63.2k/43/467 62.6k/42/351 62.1k/42/339 62.3k/42/333 62.4k/42/375 65.3k/43/346
- aa: 62.1k/41/281 62.2k/41/246 62.8k/43/661 62.7k/43/496 62.4k/42/389 62.4k/42/378 62.4k/42/360 62.4k/42/361
- hyper: 64.3k/44/306 64.2k/43/255 64.7k/44/410 65.8k/46/729 64.4k/45/916 64.5k/45/430 64.3k/44/355 64.6k/45/365
- fin: 62.0k/41/276 61.9k/41/313 65.1k/44/435 62.2k/41/312 62.5k/42/366 62.3k/42/351 62.5k/42/355 62.3k/42/437
- finone: 62.1k/41/261 61.7k/41/433 63.2k/43/482 62.3k/41/366 62.5k/42/395 62.2k/42/339 62.1k/42/324 62.2k/42/342

### A18. PROOF, bench/http's server, open loop at 100,000 a second, every request trivial (claim mcl-P4, 8 rounds): raw/p4-triv100.jsonl

# 2026-11-17 21:06:50 load { 2.56 4.28 5.58 } cpu_all 42% over20: none rate 100000 mix 1000000000 idle 0 workers None
# 2026-11-17 21:15:16 load { 3.97 3.55 4.50 } cpu_all 94% over20: 32.0% WindowServer (end)
| arm | n | achieved | cycles k [range] | /main paired [range] | user / sys µs | cores | P % | csw | intwk | p50 | p99 [range] | p99.9 | lateness p99 | rounds p99 > 5 ms | rounds p99 > 10 ms |
|---|---:|---:|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|
| main | 8 | 99218 | 32.3 [30.4-34.8] | 1.000 [1.000-1.000] | 1.50 / 6.67 | 0.81 | 87 | 0.930 | 0.012 | 23 | 200 [104-299] | 4360320 | 20 | 0 | 0 |
| aa | 8 | 99218 | 32.4 [30.3-33.9] | 1.012 [0.917-1.045] | 1.49 / 6.72 | 0.81 | 87 | 0.933 | 0.012 | 23 | 343 [102-2133] | 4360320 | 20 | 0 | 0 |
| hyper | 8 | 99218 | 35.6 [33.6-37.0] | 1.105 [1.018-1.174] | 1.96 / 7.04 | 0.89 | 86 | 0.885 | 0.000 | 23 | 185 [121-5415] | 4360320 | 19 | 1 | 0 |
| fin | 8 | 99218 | 29.2 [28.8-30.9] | 0.915 [0.838-0.956] | 1.32 / 5.86 | 0.71 | 94 | 0.888 | 0.013 | 22 | 267 [136-49028] | 4360320 | 17 | 1 | 1 |
| finone | 8 | 99217 | 29.4 [28.6-34.5] | 0.934 [0.847-1.044] | 1.33 / 5.95 | 0.72 | 92 | 0.862 | 0.013 | 23 | 290 [116-196427] | 4360320 | 19 | 2 | 2 |
- main: 30.4k/22/104 33.0k/23/229 31.8k/23/143 32.1k/23/234 33.1k/23/244 31.6k/23/166 32.5k/23/171 34.8k/23/299
- aa: 31.3k/22/1510 30.3k/22/102 33.2k/23/441 31.7k/23/2133 33.9k/23/1395 32.1k/23/199 32.8k/23/245 32.6k/23/175
- hyper: 35.7k/23/2406 33.6k/23/121 35.4k/23/170 36.4k/24/184 36.3k/24/173 35.5k/23/207 35.2k/24/186 37.0k/25/5415
- fin: 29.0k/22/136 28.8k/22/2722 29.2k/22/301 29.3k/22/250 29.5k/23/276 29.5k/23/258 30.9k/23/49028 29.2k/23/212
- finone: 28.6k/21/116 34.5k/24/196427 30.0k/23/80034 29.2k/22/255 28.8k/22/237 29.4k/23/325 30.5k/23/1781 29.5k/23/214

### A19. Closed loop at 16 connections (claim mcl-P6, 4 rounds): raw/p6-conns16.jsonl

Not run: queued behind other sessions' claims when the time box closed.

### A20. Closed loop at 256 connections (claim mcl-P6, 4 rounds): raw/p6-conns256.jsonl

Not run: queued behind other sessions' claims when the time box closed.

### A21. System calls a request, closed loop at 64 connections, under count.dylib (claim mcl-P6, 2 rounds): raw/p6-count.jsonl

Not run: queued behind other sessions' claims when the time box closed.

### A22. The smoke run (claim mcl-smoke, one run of 1 s each; a check of the scripts, with a first count of the calls)

| hyper | 1 | 160421 | 160421-160421 | 160421 | 372 / 1006 | 0.965 [0.965-0.965] | 15.1 (2.9/12.2) | 2.42 | 53.0 | 54 | 0.35 | 0.001 | 2.68 | 11 | 10 | 20.1 | 3.23 | 49 |

| a request | main | hyper |
|---|---:|---:|
| read | 1.001 | 2.001 |
| read-EAGAIN | 0.000 | 0.000 |
| write | 1.000 | 1.000 |
| writev | 0.000 | 1.000 |
| kevent-wait | 0.334 | 0.169 |
| kevent-wait-woke | 0.311 | 0.169 |
| kevent-wait-timedout | 0.024 | 0.000 |
| kevent-look | 1.040 | 0.018 |
| kevent-look-hit | 0.389 | 0.017 |
| kevent-kick-sent | 0.206 | 0.000 |
| events | 2.206 | 2.005 |
| ev-read | 1.000 | 1.001 |
| ev-write | 1.000 | 1.001 |
| user-kicks-seen | 0.206 | 0.002 |
| cond-signal | 0.000 | 0.193 |
| cond-wait | 0.000 | 0.193 |
| a read µs | 5.79 | 3.07 |
| a write µs | 5.91 | 6.34 |
| a look µs | 0.94 | 10.62 |
| events a poll that found any | 3.2 | 10.8 |

### A23. The trivial open loop at 100,000 a second against how long a kept batch waits, probe c3 (claim mcl-V1, 5 rounds): raw/v1-triv100.jsonl

Not run: queued behind other sessions' claims when the time box closed.

### A24. The same arms on the closed loop (claim mcl-V1, 4 rounds): raw/v1-closed.jsonl

Not run: queued behind other sessions' claims when the time box closed.

### A25. CONFIRMING ROUND, closed loop (claim mcl-X1, 15 rounds): raw/x1-closed.jsonl

# 2026-11-17 22:15:43 load { 2.59 3.65 4.00 } cpu_all 36% over20: none
# 2026-11-17 22:20:19 load { 9.33 6.93 5.41 } cpu_all 191% over20: 91.8% PerfPowerServices; 26.8% WindowServer (end)
| arm | n | req/s median | range | best | p50 / p99 µs | /main paired [range] | server µs (user/sys) | server cores | cycles k | P % | csw | intwk | syscalls | busiest thread % | threads >5% | gen µs | gen cores | gen P % |
|---|---:|---:|---|---:|---|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| main | 15 | 134039 | 131047-139203 | 139203 | 464 / 670 | 1.000 [1.000-1.000] | 16.3 (2.5/13.7) | 2.21 | 59.6 | 64 | 0.56 | 0.055 | 4.47 | 30 | 4 | 24.0 | 3.23 | 54 |
| aa | 15 | 135852 | 130382-138291 | 138291 | 465 / 680 | 0.998 [0.965-1.032] | 15.8 (2.3/13.5) | 2.12 | 56.9 | 65 | 0.53 | 0.048 | 4.05 | 31 | 4 | 24.1 | 3.22 | 55 |
| one | 15 | 140731 | 130387-142250 | 142250 | 447 / 668 | 1.035 [0.978-1.081] | 14.3 (1.9/12.4) | 2.01 | 52.6 | 67 | 0.42 | 0.020 | 3.01 | 37 | 10 | 23.4 | 3.27 | 55 |
| f2one | 15 | 155864 | 134706-160589 | 160589 | 394 / 659 | 1.154 [1.001-1.213] | 9.4 (1.1/8.3) | 1.46 | 36.2 | 79 | 0.18 | 0.024 | 2.46 | 65 | 1 | 21.0 | 3.29 | 56 |
| hyper | 15 | 137032 | 121572-139953 | 139953 | 457 / 679 | 1.010 [0.913-1.064] | 16.0 (2.8/13.2) | 2.20 | 58.3 | 63 | 0.47 | 0.002 | 2.91 | 11 | 10 | 23.3 | 3.20 | 54 |

Every round (k req/s), in round order:
- main: 135.2 131.4 132.6 133.9 137.4 131.0 139.2 135.8 138.7 132.2 136.2 134.0 133.2 132.2 134.5
- aa: 137.7 130.6 136.3 138.3 138.1 130.6 136.4 134.4 133.8 132.7 135.9 137.1 135.9 130.4 132.4
- one: 141.7 140.8 140.5 138.7 140.7 141.6 140.8 141.8 142.1 142.2 137.4 131.1 130.4 137.5 133.6
- f2one: 160.6 149.1 155.7 157.9 138.7 155.9 159.9 159.9 160.0 160.4 159.1 148.3 144.7 151.8 134.7
- hyper: 133.8 131.3 137.5 138.2 136.3 139.5 139.2 139.2 140.0 139.0 136.6 135.9 121.6 137.0 135.9

Against hyper:

| arm | n | req/s median | range | best | p50 / p99 µs | /hyper paired [range] 
|---|---:|---:|---|---:|---|---
| main | 15 | 134039 | 131047-139203 | 139203 | 464 / 670 | 0.990 [0.940-1.096] 
| aa | 15 | 135852 | 130382-138291 | 138291 | 465 / 680 | 0.991 [0.936-1.117] 
| one | 15 | 140731 | 130387-142250 | 142250 | 447 / 668 | 1.016 [0.964-1.073] 
| f2one | 15 | 155864 | 134706-160589 | 160589 | 394 / 659 | 1.143 [0.991-1.200] 
| hyper | 15 | 137032 | 121572-139953 | 139953 | 457 / 679 | 1.000 [1.000-1.000] 

### A26. A25's runs sorted by requests a second, with their counters


**f2one**, runs sorted by req/s:

| rps_k | srv_us | srv_cyc_k | srv_P% | top_thr% | top_thr_P% | thr>5% | csw | intwk | sysc | gen_us | gen_cores | gen_P% | gen_csw | round |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 134.7 | 11.9 | 43.2 | 64.9 | 47.1 | 79.2 | 10 | 0.287 | 0.022 | 2.571 | 21.1 | 2.8 | 51.7 | 1.164 | 14 |
| 138.7 | 10.1 | 38.0 | 72.2 | 60.5 | 86.4 | 2 | 0.209 | 0.025 | 2.475 | 21.2 | 2.9 | 53.8 | 1.228 | 4 |
| 144.7 | 10.3 | 38.3 | 72.8 | 61.0 | 87.1 | 1 | 0.204 | 0.024 | 2.475 | 21.5 | 3.1 | 51.2 | 1.211 | 12 |
| 148.3 | 10.8 | 40.4 | 71.8 | 56.7 | 86.3 | 4 | 0.233 | 0.024 | 2.528 | 21.8 | 3.2 | 53.0 | 1.236 | 11 |
| 149.1 | 10.5 | 39.6 | 72.6 | 58.0 | 86.9 | 2 | 0.222 | 0.023 | 2.509 | 21.5 | 3.2 | 53.7 | 1.219 | 1 |
| 151.8 | 10.0 | 38.1 | 76.1 | 61.3 | 89.8 | 1 | 0.207 | 0.023 | 2.494 | 21.4 | 3.3 | 54.8 | 1.246 | 13 |
| 155.7 | 9.5 | 36.8 | 78.2 | 63.1 | 91.0 | 1 | 0.192 | 0.023 | 2.477 | 20.9 | 3.3 | 56.2 | 1.243 | 2 |
| 155.9 | 9.4 | 36.2 | 78.7 | 64.8 | 91.0 | 1 | 0.179 | 0.023 | 2.457 | 21.1 | 3.3 | 55.6 | 1.252 | 5 |
| 157.9 | 9.3 | 36.2 | 80.0 | 64.8 | 92.5 | 1 | 0.182 | 0.023 | 2.462 | 21.0 | 3.3 | 56.4 | 1.254 | 3 |
| 159.1 | 8.7 | 33.8 | 83.6 | 69.7 | 94.3 | 1 | 0.156 | 0.024 | 2.421 | 20.8 | 3.3 | 57.8 | 1.266 | 10 |
| 159.9 | 8.8 | 34.5 | 82.6 | 67.7 | 93.9 | 1 | 0.165 | 0.023 | 2.444 | 20.8 | 3.3 | 57.7 | 1.268 | 7 |
| 159.9 | 8.8 | 34.6 | 83.2 | 68.2 | 94.4 | 1 | 0.161 | 0.024 | 2.434 | 21.0 | 3.4 | 57.2 | 1.263 | 6 |
| 160.0 | 8.7 | 33.9 | 84.3 | 70.0 | 95.1 | 1 | 0.153 | 0.024 | 2.424 | 21.0 | 3.4 | 57.2 | 1.262 | 8 |
| 160.4 | 8.6 | 33.7 | 84.1 | 71.0 | 95.0 | 1 | 0.148 | 0.024 | 2.406 | 20.9 | 3.4 | 57.3 | 1.258 | 9 |
| 160.6 | 8.4 | 33.4 | 84.8 | 71.6 | 95.3 | 1 | 0.146 | 0.024 | 2.407 | 20.8 | 3.3 | 57.5 | 1.257 | 0 |
| rank correlation with req/s | -0.96 | -0.93 | 0.97 | 0.96 | 0.97 | -0.11 | -0.95 | 0.33 | -0.89 | -0.72 | 0.96 | 0.88 | 0.86 | -0.34 |

**hyper**, runs sorted by req/s:

| rps_k | srv_us | srv_cyc_k | srv_P% | top_thr% | top_thr_P% | thr>5% | csw | intwk | sysc | gen_us | gen_cores | gen_P% | gen_csw | round |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 121.6 | 16.8 | 58.2 | 54.8 | 10.9 | 54.0 | 10 | 0.453 | 0.002 | 2.851 | 23.4 | 2.8 | 48.1 | 1.187 | 12 |
| 131.3 | 15.9 | 57.7 | 62.5 | 10.9 | 62.6 | 10 | 0.465 | 0.002 | 2.860 | 22.7 | 3.0 | 54.6 | 1.212 | 1 |
| 133.8 | 16.3 | 58.4 | 60.5 | 10.7 | 61.0 | 10 | 0.482 | 0.002 | 2.893 | 23.3 | 3.1 | 52.6 | 1.259 | 0 |
| 135.9 | 16.3 | 58.8 | 62.2 | 11.1 | 62.3 | 10 | 0.477 | 0.002 | 2.910 | 23.6 | 3.2 | 53.4 | 1.265 | 14 |
| 135.9 | 16.2 | 58.7 | 62.1 | 10.5 | 62.0 | 10 | 0.490 | 0.002 | 2.923 | 23.7 | 3.2 | 53.7 | 1.295 | 11 |
| 136.3 | 16.1 | 58.3 | 62.3 | 10.7 | 62.4 | 10 | 0.478 | 0.002 | 2.903 | 23.4 | 3.2 | 53.7 | 1.275 | 4 |
| 136.6 | 16.0 | 57.9 | 62.6 | 11.1 | 63.8 | 10 | 0.452 | 0.002 | 2.882 | 23.1 | 3.2 | 53.7 | 1.213 | 10 |
| 137.0 | 16.1 | 58.3 | 62.9 | 11.4 | 62.5 | 10 | 0.457 | 0.002 | 2.925 | 23.3 | 3.2 | 53.9 | 1.211 | 13 |
| 137.5 | 16.1 | 58.3 | 63.2 | 11.2 | 63.3 | 10 | 0.458 | 0.002 | 2.904 | 23.3 | 3.2 | 54.2 | 1.224 | 2 |
| 138.2 | 15.9 | 57.9 | 63.5 | 11.2 | 63.4 | 10 | 0.467 | 0.002 | 2.913 | 23.2 | 3.2 | 54.6 | 1.246 | 3 |
| 139.0 | 15.7 | 57.4 | 65.0 | 10.8 | 65.3 | 10 | 0.464 | 0.002 | 2.912 | 22.8 | 3.2 | 55.7 | 1.205 | 9 |
| 139.2 | 15.8 | 57.7 | 64.5 | 11.0 | 64.6 | 10 | 0.460 | 0.002 | 2.940 | 23.2 | 3.2 | 55.2 | 1.246 | 6 |
| 139.2 | 16.0 | 58.4 | 64.5 | 11.1 | 64.2 | 10 | 0.471 | 0.002 | 2.971 | 23.8 | 3.3 | 54.8 | 1.292 | 7 |
| 139.5 | 15.8 | 57.7 | 64.9 | 10.7 | 64.7 | 10 | 0.466 | 0.002 | 2.943 | 23.2 | 3.2 | 55.6 | 1.246 | 5 |
| 140.0 | 16.0 | 58.5 | 64.7 | 10.9 | 64.4 | 10 | 0.462 | 0.002 | 2.925 | 23.5 | 3.3 | 55.1 | 1.233 | 8 |
| rank correlation with req/s | -0.64 | -0.16 | 0.92 | 0.13 | 0.86 | 1.00 | -0.13 | -0.66 | 0.83 | 0.00 | 0.78 | 0.84 | 0.10 | -0.06 |

**main**, runs sorted by req/s:

| rps_k | srv_us | srv_cyc_k | srv_P% | top_thr% | top_thr_P% | thr>5% | csw | intwk | sysc | gen_us | gen_cores | gen_P% | gen_csw | round |
|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 131.0 | 15.3 | 55.2 | 63.1 | 33.8 | 71.7 | 8 | 0.485 | 0.033 | 3.504 | 24.0 | 3.1 | 52.6 | 1.295 | 5 |
| 131.4 | 17.0 | 61.2 | 62.0 | 25.2 | 65.9 | 4 | 0.587 | 0.059 | 4.599 | 24.3 | 3.2 | 53.7 | 1.318 | 1 |
| 132.2 | 16.7 | 60.4 | 61.8 | 29.9 | 69.5 | 4 | 0.567 | 0.056 | 4.467 | 24.1 | 3.2 | 53.4 | 1.296 | 13 |
| 132.2 | 17.6 | 63.8 | 63.3 | 27.0 | 69.8 | 5 | 0.604 | 0.065 | 4.955 | 24.7 | 3.3 | 54.4 | 1.389 | 9 |
| 132.6 | 16.9 | 61.2 | 63.0 | 27.6 | 69.6 | 4 | 0.582 | 0.060 | 4.584 | 24.3 | 3.2 | 53.8 | 1.323 | 2 |
| 133.2 | 15.1 | 54.5 | 63.0 | 33.8 | 71.4 | 9 | 0.471 | 0.032 | 3.444 | 23.3 | 3.1 | 52.9 | 1.242 | 12 |
| 133.9 | 16.6 | 60.1 | 63.8 | 28.5 | 70.1 | 4 | 0.574 | 0.058 | 4.530 | 24.0 | 3.2 | 54.4 | 1.293 | 3 |
| 134.0 | 16.5 | 59.9 | 63.6 | 29.5 | 71.0 | 4 | 0.561 | 0.055 | 4.469 | 24.0 | 3.2 | 54.4 | 1.284 | 11 |
| 134.5 | 15.5 | 56.5 | 63.3 | 31.8 | 71.3 | 3 | 0.505 | 0.039 | 3.883 | 24.0 | 3.2 | 53.2 | 1.306 | 14 |
| 135.2 | 16.4 | 59.8 | 64.8 | 29.7 | 73.0 | 4 | 0.560 | 0.057 | 4.522 | 24.2 | 3.3 | 54.9 | 1.315 | 0 |
| 135.8 | 16.3 | 59.6 | 65.9 | 30.0 | 73.1 | 4 | 0.571 | 0.056 | 4.575 | 24.0 | 3.3 | 54.5 | 1.318 | 7 |
| 136.2 | 16.0 | 58.4 | 64.9 | 31.4 | 73.7 | 4 | 0.519 | 0.046 | 4.290 | 23.9 | 3.3 | 55.6 | 1.285 | 10 |
| 137.4 | 15.5 | 56.7 | 66.1 | 29.3 | 72.5 | 3 | 0.519 | 0.043 | 4.049 | 24.0 | 3.3 | 55.1 | 1.312 | 4 |
| 138.7 | 15.3 | 56.1 | 66.7 | 33.6 | 76.0 | 3 | 0.492 | 0.037 | 3.917 | 23.8 | 3.3 | 55.3 | 1.277 | 8 |
| 139.2 | 14.8 | 54.4 | 67.2 | 31.5 | 73.8 | 7 | 0.474 | 0.035 | 3.619 | 23.9 | 3.3 | 55.5 | 1.293 | 6 |
| rank correlation with req/s | -0.57 | -0.51 | 0.91 | 0.26 | 0.82 | -0.14 | -0.42 | -0.33 | -0.29 | -0.47 | 0.83 | 0.81 | -0.29 | 0.04 |

### A27. CONFIRMING ROUND, bench/net (claim mcl-X1, 12 rounds; Tokio beside): raw/x1-net.jsonl

# 2026-11-17 22:20:19 load { 9.33 6.93 5.41 } cpu_all 191% over20: 91.8% PerfPowerServices; 26.8% WindowServer
# 2026-11-17 22:21:40 load { 5.14 6.14 5.24 } cpu_all 34% over20: none (end)
| row | main ms median (fastest) | aa ms median (fastest) | one ms median (fastest) | f2one ms median (fastest) | tokio ms median (fastest) | aa / main [range] | one / main [range] | f2one / main [range] | tokio / main [range] |
|---|---:|---:|---:|---:|---:|---|---|---|---|
| pingpong | 340.86 (332.37) | 344.83 (332.21) | 339.79 (332.68) | 343.51 (332.75) | 333.23 (307.62) | 1.003 [0.907-1.021] | 0.989 [0.925-1.109] | 0.996 [0.936-1.083] | 0.977 [0.840-1.019] |
| echo | 817.78 (761.98) | 825.25 (800.84) | 598.77 (573.04) | 585.88 (537.89) | 620.16 (587.59) | 1.006 [0.950-1.084] | 0.747 [0.700-0.875] | 0.733 [0.648-0.919] | 0.754 [0.712-0.941] |
| connect | 26.66 (26.27) | 27.02 (25.52) | 26.92 (26.05) | 27.10 (26.59) | 33.10 (32.33) | 1.004 [0.884-1.313] | 0.996 [0.938-1.055] | 1.014 [0.891-1.654] | 1.237 [1.091-1.273] |
- pingpong main: 357.59 342.25 339.47 363.47 337.91 366.37 337.95 332.37 339.00 360.40 360.78 338.75
- pingpong aa: 349.61 348.64 346.60 350.03 343.06 332.21 333.36 333.65 340.01 361.80 362.33 336.36
- pingpong one: 337.13 339.18 343.75 340.39 374.78 338.97 333.31 332.68 334.48 361.73 347.78 363.63
- pingpong f2one: 354.18 348.08 336.46 344.09 365.96 342.94 335.23 332.75 357.70 360.55 339.78 338.56
- pingpong tokio: 333.35 340.58 328.39 358.83 337.16 307.62 321.97 329.27 345.41 332.01 333.12 344.73
- echo main: 844.40 865.81 819.05 761.98 816.44 816.50 816.27 830.73 795.18 829.90 821.14 793.22
- echo aa: 826.70 822.44 841.74 826.03 800.84 829.31 825.02 831.76 813.37 825.49 808.27 823.35
- echo one: 738.64 751.61 690.52 589.52 653.09 622.04 598.36 599.17 574.31 590.13 574.67 573.04
- echo f2one: 776.11 740.50 589.26 582.50 614.48 610.38 573.97 572.85 597.18 538.16 537.89 538.17
- echo tokio: 794.61 635.67 605.11 652.01 624.69 625.85 621.09 619.23 596.56 590.87 587.59 600.30
- connect main: 26.29 26.67 26.65 30.46 27.73 28.45 26.27 26.28 27.09 27.30 26.32 26.64
- connect aa: 27.03 25.52 27.42 26.92 27.22 28.98 26.41 34.50 26.42 27.38 27.00 26.71
- connect one: 26.05 26.27 26.06 28.58 28.57 27.35 26.30 26.38 28.58 26.94 27.42 26.90
- connect f2one: 26.69 44.10 27.24 27.14 27.70 27.05 26.85 26.59 29.20 27.16 26.74 26.82
- connect tokio: 33.47 32.34 33.06 33.24 33.58 32.33 33.15 32.92 33.27 33.92 32.48 33.05

### A28. CONFIRMING ROUND, bench/tasks (claim mcl-X1, 12 rounds): raw/x1-tasks.jsonl

# 2026-11-17 22:21:41 load { 5.14 6.14 5.24 } cpu_all 44% over20: none
# 2026-11-17 22:21:57 load { 6.65 6.43 5.36 } cpu_all 67% over20: 36.7% Google Chrome Helper (Aperitif Renderer) (end)
| row | main ms median (fastest) | aa ms median (fastest) | one ms median (fastest) | f2one ms median (fastest) | aa / main [range] | one / main [range] | f2one / main [range] |
|---|---:|---:|---:|---:|---|---|---|
| spawn | 15.32 (14.04) | 15.55 (13.21) | 14.30 (11.81) | 14.36 (10.81) | 0.988 [0.892-1.084] | 0.912 [0.777-1.060] | 0.942 [0.711-1.050] |
| chain | 0.59 (0.57) | 0.59 (0.58) | 0.56 (0.55) | 0.56 (0.55) | 0.984 [0.909-1.043] | 0.955 [0.849-1.023] | 0.965 [0.880-1.233] |
| fanout | 70.98 (67.99) | 70.91 (68.33) | 72.17 (67.97) | 72.08 (68.15) | 1.001 [0.881-1.075] | 1.026 [0.882-1.188] | 0.999 [0.901-1.520] |
| yield | 6.41 (6.09) | 6.27 (6.01) | 6.45 (6.20) | 6.54 (6.27) | 0.996 [0.834-1.287] | 1.008 [0.878-1.133] | 1.006 [0.824-1.160] |
| hog | 0.01 (0.01) | 0.01 (0.01) | 0.01 (0.01) | 0.01 (0.01) | 1.094 [0.715-1.197] | 0.984 [0.710-2.310] | 0.970 [0.727-1.263] |
| produce | 5.33 (5.23) | 5.35 (5.29) | 5.33 (5.27) | 5.34 (5.23) | 1.002 [0.994-1.095] | 0.998 [0.980-1.228] | 0.999 [0.972-1.030] |
- spawn main: 15.20 14.32 14.87 16.79 15.44 14.04 14.54 16.40 14.68 15.77 17.22 16.52
- spawn aa: 15.60 15.50 13.96 16.36 14.98 14.77 13.21 16.40 15.92 16.63 15.36 16.13
- spawn one: 11.81 14.79 14.12 14.34 14.05 14.89 14.27 14.48 14.03 13.56 15.43 15.11
- spawn f2one: 10.81 14.30 14.64 14.88 13.82 13.21 15.27 15.68 14.42 14.86 14.23 13.86
- chain main: 0.64 0.60 0.58 0.59 0.57 0.60 0.58 0.60 0.65 0.58 0.60 0.57
- chain aa: 0.58 0.58 0.59 0.59 0.59 0.58 0.60 0.58 0.59 0.60 0.58 0.58
- chain one: 0.56 0.59 0.55 0.56 0.56 0.56 0.57 0.58 0.55 0.59 0.55 0.56
- chain f2one: 0.78 0.55 0.58 0.56 0.56 0.56 0.56 0.74 0.57 0.56 0.56 0.56
- fanout main: 70.69 69.64 78.44 73.46 67.99 71.98 73.66 69.62 68.88 70.91 71.06 72.46
- fanout aa: 68.67 69.47 69.13 70.76 71.05 68.33 74.05 71.33 73.78 73.52 76.37 69.10
- fanout one: 81.34 72.31 69.18 67.97 71.73 68.30 72.74 82.71 79.79 73.68 72.02 70.46
- fanout f2one: 73.25 73.02 70.70 72.16 72.88 71.30 71.99 105.85 68.25 71.37 74.73 68.15
- yield main: 6.58 6.19 6.09 6.34 6.78 6.49 6.58 6.31 6.24 7.61 6.11 6.64
- yield aa: 6.21 6.29 6.08 6.43 6.26 6.01 6.54 8.12 6.28 6.35 6.13 6.22
- yield one: 6.23 6.74 6.50 6.40 6.20 6.52 6.71 7.15 6.25 6.68 6.24 6.37
- yield f2one: 6.34 6.88 6.54 6.31 6.70 6.39 6.39 7.32 6.54 6.27 6.55 6.75
- hog main: 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01
- hog aa: 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01
- hog one: 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.03 0.01 0.01 0.01 0.01
- hog f2one: 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01 0.01
- produce main: 5.30 5.33 5.34 5.33 5.34 5.33 5.53 5.38 5.38 5.36 5.23 5.33
- produce aa: 5.32 5.39 5.32 5.34 5.32 5.29 6.05 5.35 5.38 5.36 5.37 5.39
- produce one: 5.28 5.30 5.33 5.34 5.27 5.33 5.42 5.38 5.33 5.30 5.29 6.54
- produce f2one: 5.31 5.36 5.39 5.38 5.32 5.30 5.39 5.23 5.44 5.31 5.39 5.30

### A29. CONFIRMING ROUND, bench/mixed at 55,000 a second, 2 workers (claim mcl-X1, 5 rounds): raw/x1-mix55w2.jsonl

# 2026-11-17 22:21:57 load { 6.65 6.43 5.36 } cpu_all 66% over20: 36.7% Google Chrome Helper (Aperitif Renderer) rate 55000 mix 4 idle 5000 workers 2
# 2026-11-17 22:25:17 load { 3.77 5.14 5.03 } cpu_all 56% over20: 22.6% WindowServer (end)
| arm | n | achieved | cycles k [range] | /main paired [range] | user / sys µs | cores | P % | csw | intwk | p50 | p99 [range] | p99.9 | lateness p99 | rounds p99 > 5 ms | rounds p99 > 10 ms |
|---|---:|---:|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|
| main | 5 | 54999 | 62.0 [61.8-62.9] | 1.000 [1.000-1.000] | 9.49 / 6.06 | 0.86 | 96 | 0.818 | 0.013 | 43 | 880 [701-3370] | 4158 | 288 | 0 | 0 |
| aa | 5 | 54999 | 62.7 [61.9-66.2] | 1.011 [1.001-1.052] | 9.55 / 6.22 | 0.87 | 95 | 0.820 | 0.013 | 44 | 815 [669-5423] | 1875 | 324 | 2 | 0 |
| one | 5 | 54999 | 61.9 [61.7-62.2] | 0.998 [0.986-0.999] | 9.49 / 6.07 | 0.86 | 96 | 0.815 | 0.013 | 42 | 762 [721-868] | 1190 | 283 | 0 | 0 |
| f2one | 5 | 54999 | 61.8 [61.7-62.0] | 0.998 [0.985-1.001] | 9.50 / 6.02 | 0.85 | 96 | 0.815 | 0.013 | 42 | 724 [708-1517] | 1158 | 296 | 0 | 0 |
| hyper | 5 | 54999 | 63.9 [63.9-64.7] | 1.033 [1.017-1.044] | 9.86 / 6.18 | 0.88 | 97 | 0.872 | 0.004 | 45 | 724 [700-952] | 1208 | 285 | 0 | 0 |
- main: 62.9k/44/3370 62.3k/43/940 62.0k/43/701 62.0k/42/840 61.8k/42/880
- aa: 66.2k/52/5348 65.2k/48/5423 62.7k/44/815 62.2k/43/746 61.9k/42/669
- one: 62.0k/42/770 62.2k/43/732 61.9k/42/762 61.8k/42/868 61.7k/42/721
- f2one: 62.0k/42/773 61.8k/42/708 62.0k/43/1517 61.8k/42/721 61.7k/42/724
- hyper: 63.9k/45/724 64.4k/45/772 64.7k/45/952 63.9k/45/700 63.9k/45/719

### A30. CONFIRMING ROUND, the trivial open loop at 100,000 a second, bench/mixed's server (claim mcl-X2, 5 rounds): raw/x2-triv100.jsonl

# 2026-11-17 22:26:15 load { 2.73 4.61 4.84 } cpu_all 92% over20: 26.8% WindowServer rate 100000 mix 1000000000 idle 0 workers None
# 2026-11-17 22:29:27 load { 5.87 5.19 5.02 } cpu_all 48% over20: none (end)
| arm | n | achieved | cycles k [range] | /main paired [range] | user / sys µs | cores | P % | csw | intwk | p50 | p99 [range] | p99.9 | lateness p99 | rounds p99 > 5 ms | rounds p99 > 10 ms |
|---|---:|---:|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|
| main | 5 | 99998 | 39.2 [34.0-40.8] | 1.000 [1.000-1.000] | 1.78 / 9.05 | 1.09 | 68 | 0.800 | 0.013 | 29 | 6752 [1857-11935] | 14316 | 300 | 3 | 2 |
| aa | 5 | 99999 | 34.5 [31.0-34.8] | 0.855 [0.779-1.025] | 1.54 / 7.33 | 0.89 | 81 | 0.867 | 0.012 | 24 | 2382 [1566-20545] | 7205 | 56 | 1 | 1 |
| one | 5 | 99999 | 33.5 [29.8-37.4] | 0.934 [0.731-1.084] | 1.54 / 7.21 | 0.87 | 83 | 0.858 | 0.012 | 24 | 5473 [86-15071] | 11289 | 51 | 3 | 1 |
| f2one | 5 | 99999 | 30.0 [28.9-35.0] | 0.869 [0.737-0.881] | 1.34 / 6.24 | 0.76 | 90 | 0.810 | 0.013 | 23 | 3511 [209-21350] | 9757 | 51 | 2 | 1 |
| hyper | 5 | 99999 | 44.8 [34.2-47.8] | 1.144 [1.008-1.301] | 2.54 / 9.86 | 1.24 | 64 | 0.801 | 0.001 | 44 | 989 [109-30142] | 1866 | 189 | 2 | 2 |
- main: 34.5k/23/4675 34.0k/24/6752 39.8k/37/11269 40.8k/37/11935 39.2k/29/1857
- aa: 34.5k/23/20545 34.8k/24/2382 31.0k/23/1566 34.7k/24/1727 33.5k/24/3556
- one: 37.4k/25/15071 33.5k/23/290 33.1k/24/9866 29.8k/23/86 36.6k/25/5473
- f2one: 30.0k/22/3511 29.6k/23/323 35.0k/30/21350 31.5k/25/7964 28.9k/23/209
- hyper: 44.9k/45/11286 34.2k/24/109 47.8k/74/30142 42.6k/34/989 44.8k/44/568

### A31. CONFIRMING ROUND, bench/mixed at 100,000 a second, 10 workers (claim mcl-X2, 5 rounds): raw/x2-mix100.jsonl

# 2026-11-17 22:29:27 load { 5.87 5.19 5.02 } cpu_all 48% over20: none rate 100000 mix 4 idle 5000 workers None
# 2026-11-17 22:32:48 load { 7.32 6.29 5.53 } cpu_all 41% over20: none (end)
| arm | n | achieved | cycles k [range] | /main paired [range] | user / sys µs | cores | P % | csw | intwk | p50 | p99 [range] | p99.9 | lateness p99 | rounds p99 > 5 ms | rounds p99 > 10 ms |
|---|---:|---:|---|---|---|---:|---:|---:|---:|---:|---|---:|---:|---:|---:|
| main | 5 | 99999 | 76.3 [76.2-78.0] | 1.000 [1.000-1.000] | 10.46 / 10.13 | 2.06 | 72 | 0.605 | 0.016 | 70 | 1635 [1004-15621] | 8228 | 486 | 2 | 2 |
| aa | 5 | 99998 | 76.4 [75.5-77.5] | 0.999 [0.979-1.017] | 10.45 / 10.15 | 2.06 | 72 | 0.616 | 0.016 | 69 | 979 [961-13918] | 1341 | 476 | 2 | 1 |
| one | 5 | 99999 | 75.8 [75.5-84.1] | 0.991 [0.982-1.103] | 10.40 / 9.98 | 2.04 | 73 | 0.606 | 0.016 | 67 | 1116 [878-57545] | 6454 | 444 | 2 | 1 |
| f2one | 5 | 99998 | 78.0 [75.2-87.4] | 1.001 [0.986-1.146] | 10.60 / 10.71 | 2.13 | 68 | 0.604 | 0.016 | 75 | 5836 [898-99304] | 9800 | 583 | 3 | 2 |
| hyper | 5 | 99998 | 87.6 [86.4-87.7] | 1.136 [1.123-1.152] | 12.02 / 12.22 | 2.43 | 64 | 0.793 | 0.001 | 76 | 1046 [936-4521] | 2095 | 575 | 0 | 0 |
- main: 76.5k/70/1635 76.3k/70/1006 78.0k/74/13132 76.2k/68/1004 76.2k/68/15621
- aa: 76.5k/70/13918 76.2k/69/961 76.4k/69/5166 77.5k/68/979 75.5k/66/964
- one: 75.7k/67/878 84.1k/1326/57545 76.6k/70/6360 75.8k/67/996 75.5k/66/1116
- f2one: 75.7k/67/898 87.4k/13670/99304 78.0k/75/5836 78.4k/77/18167 75.2k/65/1365
- hyper: 86.4k/73/936 87.7k/77/4521 87.6k/76/1046 87.7k/80/1711 86.6k/72/1016
