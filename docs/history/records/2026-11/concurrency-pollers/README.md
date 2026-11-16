# Spreading connections over the workers' pollers: measured, not built (2026-11-16, Mac)

The lead from the open-loop board's stall record
([concurrency-mixed/stalls.md](../concurrency-mixed/stalls.md)): `http.serve`
registers every connection with the poller of the worker that accepts
it, so one worker's kqueue carries every connection's events, and under
8 spinning threads Rig's p99 at 120,000 a second rose to 50-55 ms in 2
of 3 rounds where hyper's stayed under 8 ms. The question: does
spreading the connections over the workers' pollers improve Rig's tail
and throughput under load, with no row slower? And if not, what explains
the gap?

**It does not.** The lead holds (worker 0's poller reads 100% of the
events), but neither way of spreading helps: registering from the
connection's own task spreads nothing, and registering by turns spreads
evenly but costs 79-80% more CPU at 60,000 and 100,000 a second, which
loses the 120,000 row outright on a quiet machine, multiplies the tails
under the spinners, and costs 17-18% of HTTP's requests. No arm clears
"no row slower". The gap to hyper under the spinners is CPU per request,
not the poller: with the same system calls, faults and context switches
per request, Rig's server spends 14-15% more cores than hyper's there,
where on a quiet machine it spends 5-10% fewer, and its p50 is 2-3 times
hyper's.

## Setup

- **Base.** main ea3704772 with `loopback-ceiling` (#1105) and
  `bench-mixed` (#1108) merged, commit b0198c3fd on the branch
  `poller-spread`. Every arm is a scratch patch on it
  ([patches/](patches/)), built as a whole `bin/rig` the same way as main
  (`zig build`, ReleaseSafe), each program then `rig build --release`;
  `src/` is unchanged on the branch. Arms are separate builds, not
  environment switches, except the worker count below, which is the
  runtime's own `RIG_WORKERS`.
- **Machine.** Apple M5, 10 cores. Every run held the Mac's claim
  (`tools/mac-claim`), builds ran through `tools/heavy`, and
  `~/Data/Code/mumps-compare/.mac-quiet` was absent throughout.
- **Boards.** bench/mixed at 60,000, 100,000 and 120,000 a second over
  5,000 idle connections, 1 s warm-up and 5 s counted per rate, quiet
  and under 8 spinning threads (the stall record's `spin.c`); 10 rounds
  each in two claims of 5, the arms' order rotated each round; `base`
  and `base2` are the same executable under two names (the A/A arm), and
  hyper (`tokio`) runs in the same rounds. bench/net (pingpong, echo,
  connect), 20 rounds, and bench/http's load (64 connections, 3 s), 10
  rounds, interleaved and rotated with
  [board.py and http_ab.py](../concurrency-loopback/). Every figure is
  the median over the rounds.

## The arms

- **(a) `own`: the connection registers from its own task.**
  `http.serve` hands the connection's task its descriptor unregistered,
  and the task calls `net.watch` as it starts ([arm-a.patch](patches/arm-a.patch)).
- **(b) `spread`: registration by turns.** `http.serve` registers each
  connection with the next worker's poller in turn
  (`sched.registerSpread`, [arm-b.patch](patches/arm-b.patch)).
- **`nomon`: no preemption monitor** ([arm-nomon.patch](patches/arm-nomon.patch)),
  to see whether its signals and its look at each busy worker's kqueue
  (`serviceDue`) cost the tail under the spinners. Diagnostic only:
  preemption is not optional.
- **`ev256`: a wait takes up to 256 events, not 64**
  ([arm-ev256.patch](patches/arm-ev256.patch)), since under the
  spinners worker 0's kqueue came back full 812 times a second.
- **`w6`, `w4`: 6 and 4 workers** (`RIG_WORKERS`), under the spinners
  only.

## The lead holds: one poller carries every event

A scratch counter ([count.patch](patches/count.patch), then
[count2.patch](patches/count2.patch)) counts, per poller, the events it
returns, who took them, looks that found it locked, and per worker its
waits, looks, sleeps, steals and the monitor's signals, written once a
second to `RIG_POLL_COUNT`'s file. At 120,000 a second, 5,000 idle
connections ([raw/count/](raw/count/), [scripts/countsum.py](scripts/countsum.py)):

| poller of worker 0 | registrations | share of events | taken by worker 0 itself | full returns a second | looks that found it locked a second |
|---|---|---|---|---|---|
| base, quiet | 5,129 | 100% | 58% | 115 | 6,087 |
| base, 8 spinners | 5,000 | 100% | 21% | 2,700 | 3,817 |
| (a) own, quiet | 5,129 | 100% | 54% | 188 | 6,508 |
| (a) own, 8 spinners | 4,999 | 100% | 22% | 2,634 | 3,656 |
| (b) spread, quiet | 514 | 10.3% | 68% | 0 | 24,173 |
| (b) spread, 8 spinners | 501 | 10.3% | 35% | 0 | 3,320 |

The other workers read worker 0's events through their looks as they go
to sleep (42% of them quiet, 79% under the spinners). Arm (a) spreads
nothing: a connection's task first runs on the acceptor's worker, from
its "run next" slot as the acceptor waits for the next connection, so it
registers there too. Arm (b) spreads the registrations and the events
evenly.

## What each arm does to every row

bench/mixed, quiet, median of 10 rounds (5 for `ev256`; [raw/mixed-quiet.jsonl](raw/mixed-quiet.jsonl)):

| offered | arm | req/s | p50 | p99 | p99.9 | server cores |
|---|---|---|---|---|---|---|
| 60,000 | base | 59,999 | 57 µs | 287 µs | 1.05 ms | 1.06 |
| 60,000 | base2 | 59,999 | 57 µs | 361 µs | 1.10 ms | 1.06 |
| 60,000 | spread | 59,999 | 56 µs | 363 µs | 1.10 ms | 1.90 |
| 60,000 | ev256 | 59,999 | 57 µs | 277 µs | 1.05 ms | 1.06 |
| 60,000 | hyper | 59,999 | 55 µs | 278 µs | 1.04 ms | 1.12 |
| 100,000 | base | 99,998 | 94 µs | 753 µs | 1.67 ms | 2.11 |
| 100,000 | base2 | 99,998 | 95 µs | 798 µs | 1.46 ms | 2.12 |
| 100,000 | spread | 99,995 | 133 µs | 2.70 ms | 7.44 ms | 3.80 |
| 100,000 | ev256 | 99,998 | 95 µs | 798 µs | 1.47 ms | 2.13 |
| 100,000 | hyper | 99,998 | 81 µs | 812 µs | 1.53 ms | 2.34 |
| 120,000 | base | 119,994 | 223 µs | 37.96 ms | 43.00 ms | 3.12 |
| 120,000 | base2 | 119,995 | 204 µs | 34.93 ms | 38.67 ms | 3.10 |
| 120,000 | spread | 113,426 | 190 ms | 276 ms | 284 ms | 3.83 |
| 120,000 | ev256 | 119,996 | 211 µs | 34.00 ms | 37.36 ms | 3.12 |
| 120,000 | hyper | 119,995 | 204 µs | 38.85 ms | 41.83 ms | 3.26 |

Today's machine had a stall at 120,000 in every server's windows (p99
35-39 ms with p50 near 200 µs in Rig and hyper alike, where the first
board measured 2.0-2.5 ms): the Mac's stalls of the stall record, under
every server alike.

bench/mixed, 8 spinners, median of 10 rounds (5 for `ev256`; [raw/mixed-spin.jsonl](raw/mixed-spin.jsonl)):

| offered | arm | req/s | p50 | p99 | p99.9 | server cores |
|---|---|---|---|---|---|---|
| 60,000 | base | 59,999 | 75 µs | 6.48 ms | 12.76 ms | 1.16 |
| 60,000 | base2 | 59,999 | 73 µs | 5.36 ms | 11.02 ms | 1.14 |
| 60,000 | spread | 59,999 | 58 µs | 27.45 ms | 67.53 ms | 1.60 |
| 60,000 | nomon | 59,998 | 75 µs | 9.71 ms | 14.63 ms | 1.14 |
| 60,000 | ev256 | 59,999 | 76 µs | 5.27 ms | 9.63 ms | 1.15 |
| 60,000 | hyper | 59,999 | 65 µs | 4.81 ms | 9.18 ms | 1.10 |
| 100,000 | base | 99,996 | 125 µs | 37.98 ms | 46.37 ms | 2.12 |
| 100,000 | base2 | 99,998 | 112 µs | 34.72 ms | 42.73 ms | 2.12 |
| 100,000 | spread | 99,996 | 141 µs | 22.23 ms | 55.75 ms | 3.30 |
| 100,000 | nomon | 99,997 | 110 µs | 28.01 ms | 37.16 ms | 2.02 |
| 100,000 | ev256 | 99,998 | 111 µs | 34.15 ms | 44.09 ms | 2.08 |
| 100,000 | hyper | 99,998 | 63 µs | 27.25 ms | 38.73 ms | 1.84 |
| 120,000 | base | 119,995 | 373 µs | 36.06 ms | 43.22 ms | 2.76 |
| 120,000 | base2 | 119,928 | 286 µs | 51.81 ms | 59.43 ms | 2.73 |
| 120,000 | spread | 119,794 | 15.8 ms | 158 ms | 212 ms | 3.62 |
| 120,000 | nomon | 119,885 | 482 µs | 52.13 ms | 69.72 ms | 2.62 |
| 120,000 | ev256 | 119,996 | 258 µs | 45.74 ms | 52.53 ms | 2.69 |
| 120,000 | hyper | 119,997 | 125 µs | 19.79 ms | 28.63 ms | 2.40 |

Under the spinners the A/A arm's p99 differs by up to 44% (36 against
52 ms at 120,000): a tail there moves with where the spinners land, and
only a difference well past that counts.

bench/net, 20 rounds, median and fastest per round trip or connection
([raw/net-1.txt](raw/net-1.txt)); bench/http's load, 10 rounds
([raw/http-1.txt](raw/http-1.txt)):

| row | base | base2 | own (a) | spread (b) |
|---|---|---|---|---|
| pingpong | 16.42 µs (16.19) | 16.33 (15.99) | 16.38 (16.07) | 16.35 (16.03) |
| echo | 7.39 µs (7.04) | 7.30 (7.17) | 7.34 (7.09) | 7.30 (7.02) |
| connect | 54.04 µs (48.14) | 54.12 (48.31) | 53.79 (48.26) | 53.03 (48.49) |
| HTTP req/s | 141,185 | 139,356 | 133,335 | 115,895 |
| HTTP p50 / p99 | 446 / 619 µs | 452 / 627 µs | 472 / 647 µs | 546 / 730 µs |

bench/net makes no `http.serve` connections, and is level in every arm.

Each arm against the A/A pair:

- **(a) own** spreads nothing in bench/mixed, so it was not timed
  there; in bench/http it served 4-6% fewer requests than either base
  (outside their 1.3% apart), not looked into further.
- **(b) spread** fails every row it touches. Quiet: 79% more server
  CPU at 60,000 (1.90 cores against 1.06) with the tail level; at
  100,000, 80% more CPU, p50 41% slower, p99 3.4-3.6 times and p99.9
  4.5-5.1 times the A/A pair's; at 120,000 it saturates (113,426 a second, 5.5%
  less, p99 276 ms). Under the spinners its p99.9 is 5-6 times the A/A
  pair's at 60,000 and its p99 3-4 times at 120,000 (p50 15.8 ms); its p99 at 100,000 (22 ms
  against 35-38) is the one figure lower, inside the A/A spread, with
  its p99.9 higher. HTTP: 17-18% fewer requests.
- **nomon** and **ev256** are level with the A/A pair in every row,
  quiet and under the spinners.

No arm clears "no row slower", so none was confirmed as a plain build
against a plain build: each arm already was one.

## Why spreading costs CPU

The counts at 60,000 a second, quiet, a second ([raw/count2/](raw/count2/),
[scripts/count2sum.py](scripts/count2sum.py)), summed over the workers:

| | events | kqueue waits | looks at own poller | looks found locked | sleeps | fibers run | steals | monitor signals |
|---|---|---|---|---|---|---|---|---|
| base | 120k | 35k | 40k | 0 | 61k | 60k | 7k | 0 |
| spread | 119k | 111k | 124k | 346k | 59k | 59k | 4k | 0 |

With one poller, worker 0 takes several connections' events in each
wait and the others take its surplus by stealing. Spread over ten, each
event wakes the one worker whose kqueue holds it, so the kqueue waits
triple (35,000 to 111,000 a second) for the same requests, each a thread
woken and put back to sleep; and every worker going to sleep tries the
nine other pollers, finding them held by their sleeping owners 346,000
times a second. Spreading trades one poller's batching for a wake per
event. The monitor sends almost no signals in either (at most 2,000 a
second under the spinners, and no stops), so it is not the cost; the
`nomon` arm agrees.

## What explains the gap to hyper under the spinners

Per request, at 120,000 a second, from a library interposing the
socket, poller, memory and condition-variable calls
([scripts/count.c](scripts/count.c), the loopback record's
[count.c](../concurrency-loopback/count.c) with those added; four rounds
in two runs, [raw/syscalls/](raw/syscalls/),
[scripts/mixprof2.py](scripts/mixprof2.py)):

| | read | write | kevent: change / look / wait | cond var | poll, mmap, madvise | involuntary switches | minor faults |
|---|---|---|---|---|---|---|---|
| Rig, quiet | 1.00 | 1.00 | 0.27-0.36 / 0.16-0.21 / 0.27-0.34 | | ≤ 0.001 | 0.40-0.47 | 0 |
| hyper, quiet | 1.00 | 1.00 (writev) | 0.00 / 0.02 / 0.29-0.32 | 0.29-0.32 | 0 | 0.50-0.55 | 0 |
| Rig, spinners | 1.00 | 1.00 | 0.09-0.14 / 0.14-0.17 / 0.08-0.12 | | 0.02 poll | 0.38-0.44 | 0 |
| hyper, spinners | 1.00 | 1.00 (writev) | 0.00 / 0.02 / 0.06-0.22 | 0.06-0.14 | 0 | 0.24-0.53 | 0 |

Rig makes the same reads and writes, 0.05-0.25 more kevent calls a
request than hyper makes kevent and condition-variable calls together
(a microsecond or less of a request's 23-26 µs of CPU), no more
context switches, and no faults. Yet its CPU, read as user and
system time over the counted window (3 rounds, [raw/usersys.txt](raw/usersys.txt)):

| at 120,000 | user | system |
|---|---|---|
| Rig, quiet | 1.45 cores | 1.65-1.66 |
| hyper, quiet | 1.50-1.51 | 1.77-1.82 |
| Rig, spinners | 1.45-1.55 | 1.53-1.57 |
| hyper, spinners | 1.28-1.41 | 1.00-1.36 |

Quiet, Rig spends 5-10% fewer cores than hyper. Under the spinners
hyper's system time falls by a quarter to nearly half, with its kqueue
waits and condition-variable waits falling 1.4 to 5 times as its workers
find work waiting rather than park; Rig's system time hardly moves,
though its kevent waits fall about as much. In these three rounds Rig
fell behind under the spinners (115,784-118,859 a second, p50 5-89 ms)
where hyper kept up, and in the boards its p50 was 2-3 times hyper's
(286-373 against 125 µs at 120,000, 112-125 against 63 µs at 100,000)
on 14-15% more cores. That is the gap: CPU per request under
contention, so Rig nears its saturation sooner when the cores are
shared, and a tail at saturation is long. Which kernel work keeps Rig's
system time up with the same calls needs a kernel profile (`ktrace` or
dtrace, which need root); the calls themselves, faults, switches, the
monitor and the poller's batch size are ruled out.

Two leads it leaves, neither measured here:

- **Spin locks under preemption.** Rig's `SpinLock` never yields
  (`sched.SpinLock`), and a worker asleep in its kqueue holds its
  poller's lock for the whole wait. A holder the OS deschedules leaves
  its waiters spinning for its quantum; with spinners on every core that
  is likelier, and it would show as user time and latency.
- **Where a request's events and its fiber run.** Under the spinners 79%
  of worker 0's events are read by other workers' looks, and 44,000
  fibers a second are stolen: a socket's kernel state moves between cores
  more than in a runtime whose I/O thread hands work to parked workers.

The worker-count board below tests whether fewer workers, crowding the
spinners less, would help: they do not.

## Fewer workers under the spinners

The same executable with 6 and 4 workers (`RIG_WORKERS`), 8 spinners, 6
rounds ([raw/mixed-workers.jsonl](raw/mixed-workers.jsonl)):

| offered | arm | p50 | p99 | p99.9 | server cores |
|---|---|---|---|---|---|
| 100,000 | 10 workers | 111 µs | 29.37 ms | 37.52 ms | 2.00 |
| 100,000 | 6 workers | 110 µs | 30.84 ms | 39.01 ms | 2.00 |
| 100,000 | 4 workers | 113 µs | 37.05 ms | 44.14 ms | 1.92 |
| 100,000 | hyper | 66 µs | 29.93 ms | 39.94 ms | 1.86 |
| 120,000 | 10 workers | 204 µs | 27.23 ms | 37.78 ms | 2.69 |
| 120,000 | 6 workers | 313 µs | 45.34 ms | 56.79 ms | 2.63 |
| 120,000 | 4 workers | 666 µs | 74.18 ms | 82.02 ms | 2.34 |
| 120,000 | hyper | 119 µs | 23.65 ms | 28.31 ms | 2.35 |

Fewer workers are no better and at 120,000 worse, so workers crowding the
spinners are not the cause. This board's rounds split in two in every
server: at 120,000 Rig's p99 was 5-7 ms in three rounds and 47-91 ms in
the others, hyper's 2-3 ms and 44-54 ms, as a stall of the machine's
fell in a window or did not. Over the ten rounds of the main spinner
board, every Rig run at 120,000 had a p99 of 21 ms or more (median 36
and 52 ms for the A/A pair) and 8 of hyper's 10 had 23 ms or less
(median 20 ms); at 100,000 and 60,000 the medians are within the A/A
spread of each other.

## What I would build

Nothing from these arms. Spreading by turns is ruled out by its CPU,
and spreading from the connection's task spreads nothing. A spread that
kept the one-poller batching (each poller's events taken in batches by
whichever worker is idle, as Tokio's one driver does) would be a
scheduler design, not a registration change, and the evidence here does
not point at the poller as the cause of the gap.

## Files

- [patches/](patches/): every arm and both counters (scratch; `src/` is
  unchanged).
- [scripts/](scripts/): `buildarm.sh` (a `bin/rig` with patches
  applied), `board-mixed.sh`, `board-nethttp.sh`, `board-workers.sh`,
  `count.sh`, `count2.sh`, `countsum.py`, `count2sum.py`, `msum.py`,
  `mixprof.py`/`.sh` and `mixprof2.py`/`.sh` with `count.c` (the call
  counts), `usersys.py`/`.sh`, `profile.sh` (the `sample`s). They name the
  scratch directory they ran from; `S=` at the top of each sets it.
- [raw/](raw/): every board's rows (`*.jsonl`) and output (`*.txt`), the
  counter files, the call counts, user and system time, and `sample`s of
  each server (`sample/`, taken mid-window; sampling stalls the server,
  so those windows' latencies are not data).
