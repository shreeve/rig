# Linux, one core at 120k: why hyper leads, and what beats it (2026-11-17)

Working notes of the scheduler expert on the 120k row (bench/mixed on pup, server on one
P-core's two threads, CPUs 0 and 5; on-time generator on 1-4,6-11; 1 request in 4 hashes
for 30 µs; 10,000 idle connections). Every table and every probe, the losers too.
Raw data: `linux-120k-data/` beside this file (pup: `/zfs/trig-pup/hyper-1116/l120`).
Worktree `~/Data/Code/worktrees/rig/linux-120k`; probe branches `probe-120k-*` on origin.

Status: stopped by the owner's time box at 21:31 (pup time), after two probe boards and
before the third. Nothing here is a merge candidate; one probe is measured, its
successor is written and unmeasured.

## Summary

**What explains the row (§1).** Not cost, not wake latency, not wasted calls: where
the idle worker sleeps. At 120k a 30 µs hash is running on one worker nearly all the
time. hyper's other worker parks on the one driver, so every arrival wakes it: it
sleeps 0.28 times a request, 80% of those sleeps end within 8 µs, and 81% of trivial
requests are read within 8 µs of becoming readable. Rig's other worker sleeps in its
own poller, and the hashing worker's connections (the 128 are split between the two
pollers, differently each run) wait for the hash to end or for the sleeper's next own
event: it sleeps 0.17 times a request, a third to a half of those sleeps last 16-64 µs,
and only 61% of trivial requests are read within 8 µs (39% wait longer, hyper 19%;
mean 10.4 µs against 8.7). Per request at 120k: epoll calls 1.88 (1.03 return nothing)
against 0.85; socket reads and writes 1.000 each in both; kicks 0.05 against hyper's
0.02 futex wakes; one fiber in ten reaches its worker by a steal. At 80k both servers
have the same hole (hyper's first-parked worker holds the driver and takes the hash),
which is why they are level there at a median of 31-33 µs, half of it waiting.

**No probe beats hyper at 120k without costing another row.** The best measured:

| board 2, 7 rounds (§5) | main | layout control | `l4` (b1fe3f347) | hyper |
|---|---|---|---|---|
| 40k p50 / p99 / p99.9 | 18 / 53 / 116 | 18 / 53 / 93 | 18 / 50 / 61 | 18 / 54 / 145 |
| 80k | 31 / 50 / 68 | 31 / 50 / 66 | **16** / 51 / 64 | 33 / 51 / 71 |
| **120k** | 23 / 63 / 80 | 23 / 62 / 74 | **17 / 56 / 91** | 17 / 56 / 128 |
| 140k, no idle connections | 21 / 63 / 174 | 21 / 64 / 105 | 17 / 61 / 111 | 21 / 71 / 239 |
| ceiling 160k / 200k | 152,909 / 143,905 | 153,326 / 145,212 | 152,708 / 145,352 | 149,987 / 142,141 |
| cycles a request, trivial / mix | 30,617 / 65,804 | 30,546 / 67,136 | 31,087 / **71,249** | 32,945 / 69,171 |
| closed loop, median of 7 (range), k req/s | 732 (585-789) | 729 (526-785) | 698 (594-755) | 342 (339-345) |
| net pinned 6,7: connect / echo / ping-pong (min), 15 rounds | 29.51 / 3.55 / 4.85 (4.78) | 29.43 / 3.55 / 4.86 (4.79) | 29.74 / 3.58 / 4.85 (4.78) | |
| net on 0-11: connect / echo / ping-pong | 26.32 / 1.04 / 5.03 | 26.66 / 1.03 / 4.99 | **28.05** / 1.06 / 4.99 | |

`l4`: the HTTP server announces a handler whose path ran long the last times, and the
busy worker has a sleeping worker watch its poller for the handler's length (§4.3).
It **ties** hyper at 120k (p99.9 better), halves the median at 80k, and is better at
40k and 140k; it costs 6-8% of the mix's cycles (Rig goes from 3-5% under hyper to 3%
over), 5-6% on connect over twelve workers, 1 µs of p99 at 80k, and perhaps 1.5% of a
trivial request's cycles (inside its three runs' spread). bench/net at 30 rounds was
not run. The shared sleep (`d7`, §3) does beat hyper at 120k (median 15 against 17) and
loses five rows.

**Why `l4` only ties, found in its counters (§5):** the kernel refuses a poller nested
in one that it nests itself, so after the first watch only one of the two workers
could ever watch the other: half the hashes were uncovered.

**What I would try next (§6):** `l6` (bb58fc63c on `probe-120k-lend`: written, checked
to compile for Linux, never built on pup, never run). It lets either worker watch the
other, makes two calls a hash where `l4` made three to five, and puts one load on the
sleep path of a program with no long handler, which should give connect back. Whether
the mix's cycles can come back under main's is doubtful: a second worker woken for an
event costs about 11,000 cycles, and main's mix row is low because it does not wake
one.

## 1. The row, explained with counts (slot 560, 18:29-18:37, quiet honoured)

Arms: `tc` (8cfec3286, main's scheduler), `lay3` (old layout control), hyper. Clean rows
first (3 rounds, rates 80k/120k/140k in one generator run, 10,000 idle):

| rate | tc p50 / p99 / p99.9 | lay3 | hyper | server cores tc / hyper |
|---|---|---|---|---|
| 80k | 31 / 50 / 67 | 31 / 51 / 68 | 33 / 51 / 87 | 1.11 / 1.16 |
| 120k | 23 / 62 / 73 | 23 / 62 / 74 | 17 / 56 / 75 | 1.66 / 1.77 |
| 140k (third rate of the run, see §1.5) | 22 / 7,231 / 14,368 | 21 / 4,242 / 7,458 | 18 / 4,308 / 6,440 | 1.89 / 1.98 |

The row reproduces: 23 / 62 against 17 / 56.

### 1.1 How long a readable connection waits for its read

bpftrace, `kprobe:sock_def_readable` on the server's port to `kprobe:tcp_recvmsg` by the
server, per socket (`wait.bt`); one 6 s run each with the probes on (a count, not a
timing: under the probes hyper's p99 at 120k read 64, not 56). A request is a hash when
its read-to-write time is 15 µs or more. Share of requests by wait, and the mean:

| arm, rate | kind | < 4 µs | 4-8 | 8-16 | 16-24 | 24-36 | ≥ 36 | mean µs |
|---|---|---|---|---|---|---|---|---|
| tc 80k | trivial | 17.4% | 20.7% | 12.8% | 22.6% | 26.1% | 0.3% | 14.8 |
| tc 80k | hash | 57.8% | 39.8% | 2.1% | 0.1% | 0.0% | 0.2% | 4.0 |
| hyper 80k | trivial | 22.3% | 33.0% | 4.6% | 9.1% | 29.2% | 1.9% | 15.5 |
| hyper 80k | hash | 53.5% | 43.7% | 1.2% | 0.1% | 0.1% | 1.5% | 5.5 |
| **tc 120k** | trivial | 26.4% | 34.9% | **17.3%** | **10.5%** | 10.3% | 0.6% | **10.4** |
| tc 120k | hash | 34.9% | 36.6% | 21.9% | 5.5% | 0.6% | 0.4% | 7.1 |
| **hyper 120k** | trivial | 40.9% | 39.7% | **3.8%** | **3.7%** | 8.6% | 3.3% | **8.7** |
| hyper 120k | hash | 49.4% | 36.6% | 6.8% | 5.6% | 1.1% | 0.5% | 5.9 |
| tc 140k (traced, past its edge) | all | 1.0% | 2.7% | 17.7% | 34.4% | 25.8% | 18.4% | 28.9 |

Read-to-write time (the request itself): a hash 28-32 µs in both servers at every rate
(p99 32-36), a trivial request 1 µs (hyper's p99 2). Each worker reads half the requests
in both servers (357k / 363k of 720k at 120k).

**So the 6 µs are spent before the read.** At 120k, 39% of Rig's trivial requests wait
more than 8 µs to be read against hyper's 19%; the extra is in the 8-24 µs band (27.8%
against 7.5%), which is a request waiting out part of a 30 µs hash. At 80k both servers
are equally bad (61% and 45% of trivial requests wait more than 8 µs, means 14.8 and
15.5 µs): half of a trivial request's 30 µs median there is waiting behind a hash.

### 1.2 Why: who is watching the poller

Rig registers each connection with the poller of the worker that ran the accept loop
when it came. That loop moves between the two workers, so the 128 loaded connections
are split, differently each run: 99 / 29, 74 / 54, 108 / 20, 86 / 42, 71 / 57 in five
runs (`epsplit.py`: /proc/PID/fdinfo of each epoll). A worker with nothing to do looks
once at every poller that holds descriptors, then blocks **in its own poller only**. An
arrival on the poller of the worker that is inside a hash therefore waits for that
hash to end, or for the other worker's next pass through its sleep (its next own
event), whichever is first: the 8-24 µs band.

hyper has one driver for every connection. Whichever worker parks first parks on it;
the other parks on a condition variable. At 120k a hash is running nearly all the time
(one every 33 µs, 30 µs long), so the worker that is not hashing is the only one that
parks, and it always gets the driver: 81% of trivial requests are read within 8 µs.
At 80k both workers are often idle together, the one on the driver takes the hash, the
other stays on its condition variable, and the driver is unattended for the whole
hash: hyper's 24-36 µs band (29%), the same hole Rig has.

### 1.3 System calls a request (bpftrace on the server's system calls, `sys.bt`)

| a request | tc 80k | hyper 80k | tc 120k | hyper 120k | tc 140k | hyper 140k |
|---|---|---|---|---|---|---|
| epoll calls | 2.63 | 0.71 | **1.88** | **0.85** | 0.76 | 0.25 |
| of them looks (timeout 0) | 2.09 | 0.03 | 1.76 | 0.03 | 0.76 | 0.02 |
| of them waits | 0.54 | 0.68 | 0.12 | 0.82 | 0.002 | 0.23 |
| epoll calls that returned nothing | 1.64 | 0.02 | **1.03** | 0.015 | 0.27 | 0.003 |
| returned 1 event / 2 or more | 0.82 / 0.17 | 0.52 / 0.17 | 0.71 / 0.14 | 0.75 / 0.09 | 0.17 / 0.32 | 0.02 / 0.23 |
| socket reads (reads told to wait) | 1.000 (0.001) | 1.000 (0.001) | 1.000 (0.0004) | 1.000 (0.0004) | 1.000 | 1.000 |
| socket writes | 1.000 | 1.000 (writev) | 1.000 | 1.000 | 1.000 | 1.000 |
| kicks: eventfd writes (Rig), futex wakes (hyper) | 0.235 | 0.167 | 0.050 | 0.022 | 0.010 | 0.035 |
| kicks taken: eventfd reads / futex waits | 0.224 | 0.167 | 0.044 | 0.021 | 0.002 | 0.030 |

(Rig's kicks are its write calls less one per request; the direct count of 8-byte
writes lost half its events in bpftrace.) Rig makes one epoll call that returns nothing
for every request at 120k and 1.6 at 80k: each pass through `sleep` looks at both
pollers, and with the connections split one of the two looks is usually empty. hyper
blocks in epoll 0.82 times a request at 120k and looks 0.03 times. No read is wasted
in either (the short-read rule is doing its work).

### 1.4 Sleeps and wakes of each worker (bpftrace on sched_switch and sched_wakeup, board 1's counting runs)

Main here is `mn` (f03ef5199). A sleep is a switch out while not runnable.

| | sleeps a request (worker A + worker B) | how long a sleep lasts | on CPU between two sleeps |
|---|---|---|---|
| main 80k | 0.565 (0.287 + 0.278) | < 8 µs 35-44%, 8-16 21-25%, 16-32 7-9%, 32-64 22-37% | 8-16 µs 33-39%, 32-64 µs 28-37% |
| hyper 80k | 0.500 (0.250 + 0.250) | < 8 µs 41%, 8-16 22%, 32-64 37% | 4-8 µs 31%, 32-64 µs 47% |
| **main 120k** | **0.171** (0.091 + 0.080) | A: < 8 µs 27%, 8-16 16%, **16-32 31%, 32-64 25%**; B: < 8 µs 56%, 8-16 20%, 16-32 18%, 32-64 6% | longer than 64 µs 46-48% |
| **hyper 120k** | **0.283** (0.142 + 0.141) | **< 8 µs 78-80%**, 8-16 14-15%, 32-64 6-7% | 32-64 µs 57%, longer 15% |
| main 140k | 0.046 | < 8 µs 36-61%, 16-32 22-37% | longer than 64 µs 90% |
| hyper 140k | 0.027 | < 8 µs 91% | longer than 64 µs 91% |

Wakes equal sleeps in every run (wakes by the server's own threads are under 600 in 6 s:
the kicks), and a woken worker is running within 2 µs 98-99% of the time in both
servers, so nothing is lost between the wake and the run. At 120k hyper's idle worker
sleeps 0.28 times a request and 80% of those sleeps end within 8 µs: every arrival
wakes it. Rig's idle worker sleeps 0.17 times a request, and a third to a half of its
sleeps last 16 to 64 µs, through the other worker's hash, while that worker's
connections have requests waiting. Steals are in §5 (main's counters need the probe's
SIGUSR1: a server killed by SIGTERM prints none).

### 1.5 A generator artifact found on the way: the third rate of a run

bench-mixed runs its rates one after another in one generator process. In both boards
of this work the **third** rate had millisecond p99s in every arm, hyper included
(140k in slot 560; 120k in slot 561, where 40k and 80k came first: main 67-14,764,
hyper 65-1,167, with the generator's own lateness still 4-5 µs), while 120k as the
second rate (slot 560) was clean in 9 runs of 9. The medians (p50) are not affected.
Boards after this run each rate from its own generator process.

## 2. What the cause rules in and out

- Not cost a request (hyper spends more), not wake latency (2 µs), not wasted reads, not
  the 61-turn look (its share is under 0.03 looks a request). Steals carry one fiber
  in ten (§5), each after a kick at the end of a batch: `steal_next_after` and the
  run-next slots decide how that tenth moves, not how long a request waits to be read.
- It is where the idle worker sleeps. To take an arrival on the hashing worker's
  poller at once, the idle worker has to be woken by it.
- The price of that is in §3: a second worker woken for an event costs about 11,000
  cycles (2.4 µs) for the sleep and the wake around it, and main's cycles a request
  are low because under load it does not wake one: it lets requests wait for the
  busy worker and takes them in a batch.

## 3. Board 1 (slot 561, 19:17-19:47, quiet honoured): the shared sleep, with a gate

Arms (all on main f03ef5199; `mnl` is main with two functions moved, the layout control):

- `d7e`: archive/shared-sleep (6c0416f4f, never boarded) picked onto main: every worker
  with nothing to do waits in one epoll that nests every poller; Linux wakes one waiter
  an event. (Commit ba0281a69 `probe-120k-d4m`; `d7e` is 815d0ab1c with
  `RIG_LAZY_RUN_US=0`, the same behaviour.)
- `d7` (815d0ab1c, `probe-120k-d5`): the same with a lazy gate: one worker at most waits
  in the shared epoll and the others wait alone (ppoll, woken by a signal) unless a
  fiber ran 15 µs or more within the last 2 ms; and a worker about to sleep looks at
  the pollers first, as main does, while none waits in the shared epoll.
- `d7n`: `d7` without those looks (`RIG_LAZY_LOOK=0`).

Rates 40k, 80k, 120k ran in that order in one generator process, 5 rounds (the 120k
p99 column is the third-rate artifact of §1.5: read its p50 only); 140k alone, no idle
connections, 4 rounds.

| row | main | layout | d7 | d7n | d7e | hyper |
|---|---|---|---|---|---|---|
| 40k p50 / p99 / p99.9 | 18 / 53 / 119 | 18 / 53 / 120 | 17 / 50 / 60 | 17 / 50 / 63 | 17 / 49 / 62 | 18 / 54 / 159 |
| 80k p50 / p99 / p99.9 | 31 / 50 / 65 | 31 / 50 / 62 | **17** / 49 / 59 | 17 / 49 / 60 | 17 / 49 / 61 | 33 / 50 / 71 |
| 120k p50 | 24 | 24 | **15** | 17 | 15 | 17 |
| 120k p99, every run | 67 68 75 7,853 14,764 | 77 1,415 3,798 4,752 9,907 | 192 451 648 1,389 39,934 | 52 58 60 722 1,426 | 52 52 53 83 952 | 65 67 691 863 1,167 |
| 140k, no idle: p50 / p99 / p99.9 | 21 / 64 / 111 | 21 / 64 / 229 | 15 / 55 / 96 | 17 / 60 / 159 | 14 / 53 / 181 | 19 / 70 / 389 |
| server cores at 80k / 120k | 1.13 / 1.67 | 1.13 / 1.66 | 1.26 / 1.79 | 1.26 / 1.78 | 1.26 / 1.79 | 1.16 / 1.77 |
| cycles a request, trivial (ctx sw) | 30,706 (0.623) | 29,862 (0.612) | 32,423 (0.599) | 31,769 (0.629) | 36,729 (1.067) | 33,201 (0.675) |
| cycles a request, mix (ctx sw) | 67,134 (0.418) | 66,809 (0.429) | 71,724 (0.827) | 71,109 (0.841) | 71,612 (0.827) | 69,192 (0.576) |
| ceiling 160k, median of 3 | 153,462 | 151,164 | 146,920 | 146,467 | 139,626 | 150,010 |
| ceiling 200k | 143,192 | 144,718 | 137,403 | 140,869 | 139,073 | 142,439 |
| closed loop, median of 7 (range), k req/s | 774 (591-792) | 704 (521-782) | 685 (655-690) | 679 (663-690) | 679 (654-692) | 343 (341-347) |
| net pinned 6,7: connect / echo / ping-pong (median; min) | 29.64 / 3.58 / 4.89 (4.77) | 29.68 / 3.56 / 4.83 (4.78) | 32.91 / 3.64 / 5.33 (5.12) | 32.32 / 3.64 / 5.88 (5.75) | 32.76 / 3.60 / 10.82 (10.63) | |
| net on 0-11: connect / echo / ping-pong | 26.84 / 1.04 / 4.96 | 26.70 / 1.02 / 5.08 | 36.33 / 1.01 / 6.47 | 36.47 / 1.42 / 6.87 | 37.03 / 1.04 / 9.04 | |

Counting runs of `d7`: at 80k, 98.8% of trivial requests are read within 8 µs of
becoming readable (main 38%), mean wait 4.7 µs (main 14.8); sleeps a request at 120k
0.359, 75% under 8 µs and none over 16. Its own counters at 120k: 748k fibers run, 2.0k
stolen, 220k waits ended by an event (15k for nothing), 1,269 waits alone, 183k runs
of 15 µs or more (the hashes, 180k, and a few more).

Reading. A second waiter on a busy worker's events does what §1 says it would: the
median falls from 31 to 17 µs at 80k and from 24 to 15 at 120k, under hyper's at both,
and the 140k row follows. It is paid for everywhere else:

- cycles a request rise 6.7% under the mix (0.42 to 0.83 context switches a request:
  about 11,000 cycles for each switch added), and Rig goes from 3% under hyper to 3.6%
  over; with every sleeper in the shared epoll (`d7e`) trivial requests cost 20% more;
  the gate takes that back to 3.5-5.6% over main, not to main;
- the ceiling falls 4-9% and drops under hyper's;
- connect is 10% slower on two threads and 35% on twelve, ping-pong 9% and 30%: with
  one worker receiving every event, a socket's fiber no longer wakes on the worker
  that holds it;
- `d7` had two runs with a stall (p99 39,934 and, in a counting run, 99,443 µs), which
  `d7e` and `d7n` did not: a lost wake in the probe's gate, not looked for.

So the shared sleep is not the change: it wins the row and loses five others. What it
proves is the size of the prize (14 µs at 80k, 9 µs at 120k at the median) and its
price (a wake).

## 4. Keeping main's sleep, and waking a sleeper only for a long run

The lesson of board 1: main is cheap because a worker's own poller wakes its own worker
and nobody else, and the latency is lost only while a worker is inside a long fiber.
So the next probes leave every sleep and wake of main as it is and add one thing.

### 4.1 A rough model first (`sim.py`, two workers, deterministic service times)

Model µs, before the client's ~8; splits 64/64 and 99/29 of the 128 connections:

| 120k | p50 | p99 | trivial mean wait |
|---|---|---|---|
| main (sleeper in its own poller; looks at both as it goes idle) | 12.6 / 18.6 | 44.6 / 44.2 | 8.2 / 10.5 |
| a sleeper watches the other poller if the other worker has run 8 µs as it goes to sleep | 6.5 / 6.5 | 38.2 / 39.5 | 4.9 / 8.0 |
| a sleeper watches the other poller from the start of a hash | 6.5 / 6.5 | 34.5 / 34.5 | 3.0 / 3.0 |
| any arrival wakes a sleeper (the shared sleep) | 6.5 / 6.5 | 34.5 / 34.5 | 3.0 / 3.0 |
| one driver, first to sleep holds it (Tokio) | 6.5 / 6.5 | 39.5 / 39.5 | 7.1 / 7.1 |

The model has main's and Tokio's order at 120k and says a watch during hashes alone
gets all of the shared sleep's gain. (At 80k it under-states both servers' waits.)

### 4.2 `l2`: a sleeper watches a long-running worker's poller (0f4f779f2, `probe-120k-lend`)

A worker about to wait in its poller nests in it, for one report (EPOLLONESHOT), the
poller of a worker that has run its fiber 8 µs or more (a time-stamp per switch,
rdtsc, written only while the worker's poller holds descriptors); an event there ends
the sleeper's wait and a look takes it. The watched worker takes an unspent watch back
as it switches away from the fiber, so a worker asleep in its own poller is the one
thread its events wake. No other path changes.

On E-cores (a lead, 40k, where a hash is 60 µs) it did nothing: p50 41-47 as main,
watches set 3,712 in 10 s with a 20 µs threshold, 964 ended by an event, the trivial
requests' waits unchanged (61% over 24 µs). Cause: the sleeper decides as it goes to
sleep, and it goes to sleep just after the busy worker handed it part of a batch,
which is just after that worker's hash ended: the busy worker is then at the start of
its next fiber, never 8 µs into it. The idle worker is asleep, unwatching, when the
long run starts.

### 4.3 `l4`: the long run is announced (b1fe3f347, `probe-120k-lend`)

The one who knows a long run is starting is the server: `net.answer` times each
handler by its request's path (a 256-slot table of 2-bit counts, two rdtsc a request)
and, before a handler whose path ran 8 µs or more the last times, calls
`sched.longAhead`: the worker is marked as running long, and its poller is nested, for
one report, in the poller of the sleeper listed last (one epoll_ctl, by the busy worker,
no wake). From the handler's first instruction an event on that poller wakes that
sleeper; when it has run what it took and goes to sleep again it finds the worker
marked and watches again (`l2`'s path); the handler's return takes an unspent watch
back (one epoll_ctl). A handler that returns at once costs a table load and two
time-stamps, and nothing else in the program changes.

E-core lead (40k, threshold 20 µs for those cores, one traced run): p50 19 against
main's 41-47 and the shared sleep's 17; 93.7% of trivial requests read within 8 µs of
becoming readable (main 37-38%, mean wait 8.8 µs against 21.7-26.7). Counters of that
run: worker 0 announced 52,386 long handlers with a sleeper to watch for them, worker
1's watches ended by an event 98,272 times (it set 98,219 itself as it went back to
sleep), and worker 0 took 52,333 unspent watches back. The first build panicked
("the scheduler's code was inlined into the program's"): the server's code is inlined
into the program's own, so the two calls are `noinline` (b1fe3f347).

**A rule slip of mine (20:24-20:25).** An E-core counting run (`l4u20`, 40k) started a
minute after its `slot=none` check, behind an arm build in the same command, and
overlapped another session's slot 547 (opened 20:24:47; its quiet check caught the
load generator on cpu 15, two samples). Since then every E-core run of this work
(`diag.sh`, `quick.sh`, arm builds through `ecore.sh`) takes `/tmp/pup-timing.lock`
without waiting, checks `slot=none` immediately before it starts, and holds the lock
for its length, so no board can open over it.

## 5. Board 2 (slot 562, 20:37-21:07, quiet honoured): `l2` and `l4` against main

`l4` is b1fe3f347; `l2` is the same binary with `RIG_LEND_AHEAD=0` (the watch set at
sleep only). 7 rounds a rate, each rate from its own generator process (p99 is clean
again: the third-rate artifact of §1.5 is confirmed); 140k with no idle connections.

| row | main | layout | l2 | l4 | hyper |
|---|---|---|---|---|---|
| 40k p50 / p99 / p99.9 | 18 / 53 / 116 | 18 / 53 / 93 | 18 / 53 / 99 | 18 / **50** / **61** | 18 / 54 / 145 |
| 80k | 31 / 50 / 68 | 31 / 50 / 66 | 31 / 50 / 67 | **16** / 51 / 64 | 33 / 51 / 71 |
| 120k | 23 / 63 / 80 | 23 / 62 / 74 | 22 / 61 / 78 | **17 / 56** / 91 | 17 / 56 / 128 |
| 120k p50, every run | 23 23 23 23 27 23 24 | 23 ×7 | 22 22 22 22 22 23 24 | 15 17 17 16 17 16 17 | 17 ×7 |
| 120k p99, every run | 62 62 63 63 63 8,227 18,490 | 61 62 62 62 62 63 63 | 60 60 60 61 61 61 2,292 | 50 50 50 56 57 57 20,297 | 56 56 56 56 56 57 60 |
| 140k, no idle | 21 / 63 / 174 | 21 / 64 / 105 | 18 / 64 / 215 | 17 / 61 / 111 | 21 / 71 / 239 |
| server cores 80k / 120k | 1.12 / 1.67 | 1.12 / 1.67 | 1.14 / 1.70 | 1.19 / 1.79 | 1.16 / 1.77 |
| ceiling 160k / 200k (median of 3) | 152,909 / 143,905 | 153,326 / 145,212 | 152,928 / 144,759 | 152,708 / 145,352 | 149,987 / 142,141 |
| cycles a request, trivial (ctx sw) | 30,617 (0.627) | 30,546 (0.630) | 30,624 (0.605) | 31,087 (0.619) | 32,945 (0.686) |
| cycles a request, mix (ctx sw) | 65,804 (0.407) | 67,136 (0.418) | 70,395 (0.460) | 71,249 (0.548) | 69,171 (0.576) |
| closed loop, median of 7 (range), k req/s | 732 (585-789) | 729 (526-785) | 599 (584-727) | 698 (594-755) | 342 (339-345) |
| net pinned: connect / echo / ping-pong (min) | 29.51 / 3.55 / 4.85 (4.78) | 29.43 / 3.55 / 4.86 (4.79) | 29.91 / 3.61 / 4.88 (4.79) | 29.74 / 3.58 / 4.85 (4.78) | |
| net on 0-11: connect / echo / ping-pong | 26.32 / 1.04 / 5.03 | 26.66 / 1.03 / 4.99 | 27.88 / 1.07 / 5.07 | 28.05 / 1.06 / 4.99 | |

A hiccup round (a p99 of 2-20 ms) happens to every arm at 120k, main and hyper too
(main twice in 7): at 1.7-1.8 of 2.0 cores a millisecond lost anywhere is a
queue that takes tens of milliseconds to drain. It is not the probe's.

Reading:

- `l2` (watch a worker 8 µs into its fiber, decided at sleep) gains nothing, as on the
  E-cores, and costs 5% of the mix's cycles (set and taken back at each fiber) and 5%
  on connect over twelve workers (its walk over every worker at each sleep). Dead.
- `l4` (the announced long handler): 80k's median 31 to 16 µs, under half hyper's 33;
  40k's p99 3 µs and p99.9 half; 140k better on all three; the ceiling, ping-pong,
  echo and trivial requests' cycles level with main. At **120k it ties hyper** (17 / 56,
  p99.9 91 against 128), no more, and it costs the mix 6-8% of its cycles and connect
  on twelve workers 5%.

**Why 120k only ties: one of the two workers was never watched.** `l4`'s counters at
120k (a counting run): worker 0 announced 14,105 long handlers with a sleeper to watch
for them and worker 1 none; worker 1 set 23,964 watches itself and worker 0 none.
The kernel refuses to nest a poller in one that it nests itself (ELOOP), whether or
not the nested registration reports, and `l4` left each watch registered and switched
it off (EPOLL_CTL_MOD): after the first watch, only that worker could ever watch the
other. So `l4` covered the hashes of one worker, and each run's luck was which
worker held most of the connections (the 15 / 50 runs against the 17 / 57 ones). In
that counting run 64% of trivial requests were read within 8 µs (main 56.5%, hyper
80.6%).

Main's own counters at 120k (`l4` with `RIG_LEND_US=0`, 7 s): worker 0 ran 389,004
fibers, stole 37,519, slept 282,612 times (calls of `sleep`, most of which find work
in their looks and never wait); worker 1 ran 359,700, stole 35,619, slept 267,630. So
about one fiber in ten reaches its worker by a steal after a kick; the rest by the
looks of a worker out of work.

### 5.1 What board 2 changes in the probe (`l6`, bb58fc63c, `probe-120k-lend`)

- **Either worker can watch the other.** The nested poller is registered as the watch
  is set (EPOLL_CTL_ADD) and removed as it is taken back (EPOLL_CTL_DEL), so no
  registration is left to make the reverse nesting a loop.
- **The watch lasts the long run.** It is edge-triggered (`RIG_LEND_ET`, 1): set once
  as the handler starts, by the busy worker, taken back once as the handler returns,
  and reporting every event meanwhile. The watching worker makes no call to set it
  again, and as it goes to sleep it does not look at a poller it watches (what lands
  there ends its wait). `l4` set it again at every sleep (EPOLLONESHOT): three to five
  calls a hash where this makes two.
- **Only an announced long run is watched** (`RIG_LEND_TIME=1` brings `l2`'s timed rule
  back): no fiber's start is stamped, and a worker going to sleep reads one count of
  the announced long runs under way, on a line nothing else writes, before it looks at
  any worker. A program with no long handler runs main's sleep path plus that load.
- A handler during which its worker ran other fibers waited (I/O), and is not counted
  as a long run.
- Knobs for the board: `RIG_LEND_KEEP=1` keeps the watch after the handler returns
  while its worker goes on running fibers and takes it back as that worker goes to
  sleep; `RIG_SKIP_OWN_LOOK=1` leaves a sleeping worker's look at its own poller to the
  wait in it that follows (main makes about one epoll call that returns nothing for
  every request at 120k, §1.3).


## 6. Not measured, and what I would do next

Stopped here by the time box; in order:

1. **Board `l6`** (bb58fc63c, §5.1) with `board2.sh` (each rate from its own generator;
   kept in `linux-120k-data/`): arms main (`mn`, f03ef5199), its layout control (`mnl`,
   20aec4a2c), `l6`, `l6` with `RIG_LEND_KEEP=1`, the same with `RIG_SKIP_OWN_LOOK=1`,
   hyper; 7 rounds at 40k/80k/120k/140k; then `net30.sh` for the 30 rounds of bench/net.
   Expect: 120k under hyper at the median (both workers covered; the shared sleep's
   15 / 52 is the mark), connect on twelve workers back to main's, the mix's cycles
   between hyper's 69k and `l4`'s 71k. `l6` has never run: its first step is a
   counting run on the E-cores.
2. **If the mix's cycles decide it:** the wake is the cost, and only fewer wakes lower
   it. `RIG_LEND_REARM` in `l4`/`l6` (with `RIG_LEND_ET=0`) limits the watches of one long
   run; a watch that reports no sooner than some microseconds after the last would
   batch two or three requests a wake at 150k. Both trade the median back.
3. **For a real build, not the probe's shortcuts:**
   - EPOLL_CTL_ADD of a poller takes a mutex the whole kernel shares; a worker's second
     epoll that only ever nests pollers (which nest nothing) can keep every watch
     registered and switch it with EPOLL_CTL_MOD, with no loop possible. The price is
     that a sleeper must wait in that epoll to be watched for, one more look a wake, so
     only while long handlers are about.
   - with more than two workers the watch should pass to a sleeping worker when its
     holder is busy (`l6` leaves it with the holder);
   - the announcement is the server's (`net.answer`, by the request's path); other
     long fibers need their own (a task's own history, or a call the program makes);
   - the time-stamp is rdtsc (x86-64) and timed at start by a 200 µs spin; the Mac
     has no part of it (a kqueue nested in a kqueue reported correctly in the holder
     probe);
   - no handshake of sleep and wake changes (a watch only adds a look, which any
     worker may make at any time), so formal/Models/Sleep.lean stands; what needs
     tests is the watch's own life: set, spent, taken back, the handler that waits,
     the fiber that moves.
4. **Independent of all this, on main:** a worker going to sleep looks at its own
   poller and then waits in it; the look returns nothing about once a request at
   120k and 1.6 times at 80k (§1.3). `RIG_SKIP_OWN_LOOK=1` in `l6` leaves it out
   unless the looks at the other pollers found work: worth a board of its own
   (expected about 1% of a trivial request's cycles, nothing else).
5. Recorded for the Rig session, found on the way: bench-mixed's third rate in one
   generator process has millisecond p99s in every arm, hyper included (§1.5): run a
   rate a process; a server killed by SIGTERM prints no `RIG_SCHED_STATS`; and the
   128 loaded connections split between the two workers' pollers differently every
   run (20 to 108 on one), which is part of main's run-to-run spread at 120k.

## 7. Every probe, in one table

| arm | commit, branch | what | measured | verdict |
|---|---|---|---|---|
| `d4m` / `d7e` | ba0281a69 `probe-120k-d4m`; 815d0ab1c `RIG_LAZY_RUN_US=0` | archive/shared-sleep on main: every sleeper in one epoll | board 1 | wins 40k-140k medians; loses cycles (20% trivial, 7% mix), ceiling 4-9%, connect 10-35%, ping-pong 2x |
| `d7`, `d7n` | 815d0ab1c `probe-120k-d5` | the same with a lazy gate (one waiter unless a run was long), with and without main's looks | board 1 | as above with trivial cycles 3.5-5.6% over; two stalled runs in `d7` |
| `d7l` | 815d0ab1c `RIG_LAZY_RUN_US=1000000000` | the gate always shut (one driver, as Tokio) | E-cores only | p50 51-52 at 40k against main's 41-47: worse than main |
| `gs` | 3eda58ef4 `probe-120k-gs` | descriptors registered with the shared epoll itself, records checked by a count | E-cores only (p50 16 at 40k) | built, never boarded |
| `l2` | b1fe3f347 `RIG_LEND_AHEAD=0` | a sleeper watches a worker 8 µs into its fiber | board 2 | no gain; 5% of the mix's cycles, 5% on connect over twelve |
| `l4` | b1fe3f347 `probe-120k-lend` | the announced long handler | board 2 | the best trade measured (summary) |
| `l6` | bb58fc63c `probe-120k-lend` | `l4` with either worker watched, two calls a hash, one load on the sleep path | none | next |
| layout control | 20aec4a2c `probe-120k-lay` | main with two functions moved | boards 1, 2 | the spread: under 1 µs at every percentile but p99.9; 0.2-2.8% on cycles; 0.3-1.5% on the ceiling |

Left in place: the worktree `~/Data/Code/worktrees/rig/linux-120k` and the six
`probe-120k-*` branches on origin; on pup the arms `mn mnl d4m d5 d7 gs l2 l4` (and
their wrappers) under `/zfs/trig-pup/hyper-1116/arms`, the Rig builds
`/zfs/trig-pup/rig-{f03ef5199,20aec4a2c,ba0281a69,aec9a8fdb,4c9157c65,5cf1e22b4,815d0ab1c,0f4f779f2,3eda58ef4,6837ebe56,f6ac9ce3e,b1fe3f347}`,
and the work folder `/zfs/trig-pup/hyper-1116/l120`. No slot of this work is open and
no process of it runs on pup (the queued build of bb58fc63c was stopped by PID and its
half-built folder removed). Slots used: 560, 561, 562, each closed early, quiet
honoured in all three.

## 8. Board 3 (slot 563, 22:19-, quiet to be read below): `l6` fails, and why

Asked for by the coordinator after the time box: board `l6` (bb58fc63c) against main,
its layout control and hyper; `l6o` is the same binary with `RIG_LEND_ET=0` (a
one-shot watch set again at each sleep, as `l4`).

| row | main (`mn`) | layout (`mnl`) | l6 | l6o | hyper |
|---|---|---|---|---|---|
| 120k p50 / p99 / p99.9 (7 rounds) | 23 / 63 / 85 | 23 / 63 / 78 | **154 / 432 / 608** | 150 / 404 / 592 | 17 / 56 / 115 |
| 120k server cores | 1.66 | 1.67 | **1.99** | 1.98 | 1.77 |
| 80k p50 / p99 / p99.9 | 31 / 50 / 67 | 30 / 50 / 70 | 134 / 393 / 507 | 137 / 272 / 450 | 33 / 51 / 77 |
| 80k server cores | 1.12 | 1.12 | **1.89** | 1.81 | 1.16 |
| cycles a request, trivial (ctx sw) | 30,555 (0.625) | 30,363 (0.624) | 30,659 (0.630) | 30,999 (0.640) | 33,258 (0.692) |
| cycles a request, mix (ctx sw) | 66,883 (0.412) | 67,049 (0.421) | **74,052** (0.571) | 74,601 (0.501) | 69,383 (0.572) |

(Remaining rows: §8.1 once the board ends.)

**Why.** `l6` registers the watched poller with the watcher's (EPOLL_CTL_ADD) at each
watch and removes it after, so that either worker can watch the other. Adding an epoll
to an epoll makes the kernel check for loops and wake-up paths through every item of
the added epoll (`ep_loop_check`), and a worker's poller holds 10,000 and more sockets
here: tens of µs of kernel time for each long handler. At 80k that is 0.7 of a core
more than main, and the server saturates (medians of 134-154 µs). The trivial-only
row, which has no long handler, is level with main (30.7k against 30.6k cycles):
the cost is all in the watches. `l4` paid the walk once a direction and switched the
watch with EPOLL_CTL_MOD, which is why it lost half the coverage (ELOOP for the
reverse) but not the CPU.

**`l7` (5819dd804, `probe-120k-lend2`, not boarded):** no poller is registered with
another. A worker going to sleep while another runs an announced long handler waits
on both pollers with one poll(2), then takes its own events with a look and the other
poller's with a look of it: one extra call a wake and no registration. The watch starts
at the sleeper's next wait. Its compile check was queued behind other sessions' suites
on the Mac when the box ended.

## `l7` on the board (board AG, 2026-11-18)

`l7`, ported onto main c014f5e3f (8ec62a7e7, kept as the tag `archive/120k-l7`), on
pup in slot 550, with the spinning generator. The arms: main, an A/A copy of main,
`l7`, `l7` with `RIG_LEND_US=0` (`l7·0`), and hyper. One core (0,5), 10,000 idle
connections, 7 rounds; cycles a request at 150k, 3 rounds. Before the board, a count
on E-cores (server 12,13; load 14-19; 80k) showed both workers setting watches
(45,228 and 46,639), the coverage `l4` lacked.

| | main | A/A | `l7` | `l7·0` | hyper |
|---|---:|---:|---:|---:|---:|
| 120k p50 / p99 / p99.9 (µs) | 23 / 63 / 89 | 23 / 63 / 108 | **17 / 58 / 75** | 23 / 63 / 82 | 17 / 56 / 89 |
| 120k p99, slowest round | 736 | 19,664 | 59 | 47,035 | 63 |
| 120k server cores | 1.66 | 1.67 | 1.76 | 1.67 | 1.77 |
| 80k p50 / p99 / p99.9 | 31 / 49 / 61 | 31 / 49 / 62 | 29 / 50 / 61 | 31 / 49 / 60 | 33 / 50 / 66 |
| cycles a request, trivial (ctx sw) | 30,593 (0.626) | 30,306 (0.635) | 30,419 (0.623) | 30,553 (0.624) | 33,467 (0.691) |
| cycles a request, mix (ctx sw) | 66,523 (0.421) | 67,015 (0.426) | **70,818** (0.577) | 67,327 (0.429) | 69,293 (0.575) |
| closed loop on 0-11, median of 7 (req/s) | 700.5k | 745.5k | 666.5k | 711.4k | 346.3k |

bench/net on 0-11 was level in every arm.

**Verdict: dropped** (the owner: "Drop l7, keep main"). `l7` closes 5 of the 7 µs at
120k, matches hyper's p50 and passes its p99.9, and has no stalled round. It pays for
that with a wake per event, as `l4` did: 6.5% more cycles a request on the mix than
main, 2.2% more than hyper, where main spends 4% fewer than hyper. Main keeps the CPU
lead and loses the 120k p99 by 7 µs.
