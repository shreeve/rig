# On the Mac, fewer workers awake: echo past Tokio, HTTP past hyper (2026-11-17)

Three experts took the three rows where Rig trailed hyper or Tokio after the
review ([http-review](../http-review/README.md),
[concurrency-standings](../concurrency-standings/README.md)): the Mac's
bench/net echo, the Mac's bench/http closed loop, and pup's p50 and p99 at
120,000 requests a second on one core. This page says what they found and
why; the three reports beside it hold every table and probe, the losers too:
[echo.md](echo.md), [closed-loop.md](closed-loop.md),
[linux-120k.md](linux-120k.md).

## The finding

**On this Mac, Rig kept too many workers awake, and the Mac makes that
expensive.** Each socket waited in the poller of the worker that opened it,
so in a program with many sockets every worker was woken by its own, all
ten stayed in play, and each, as it went to sleep, looked at every other
worker's poller for events no one was waiting in. Echo made 9.0 system calls
a round trip: the two reads and two writes the work needs, then 4.5 looks at
other pollers at about 2.8 µs each, and a quarter of a wait and a kick. Rig
kept 8.6 cores busy where Tokio kept 5.1.

The Mac (an M5, 4 performance and 6 efficiency cores) charges for that twice:
each extra look is a system call, and each extra worker awake puts work on an
efficiency core, where a socket read took 8.5 µs against 2.1 µs with three
workers. Both runtimes are fastest at three workers (about 3.7 µs a round
trip), and a hand-written Zig ceiling runs 3.80 µs on three threads, 31%
under Tokio, with 4 to 5.5 calls a round trip.

pup's cores are all of one kind, and there Rig's per-worker pollers are why
it leads echo (1.10 µs against Tokio's 1.29); the changes below are the
Mac's alone.

## The two changes, as measured

**One poller for every socket** (`one`: one line in `sched.registerIn`, on
the Mac only; every descriptor waits in worker 0's poller, as `http.serve`'s
connections already wait in their acceptor's). One worker takes the events,
40 to 59 at a call, and the others are woken only for work: echo makes 4.5
calls a round trip (Tokio 5.4). Plain builds on main f03ef5199, 15
interleaved rounds:

| echo, µs a round trip | median | against main, paired [range] | against Tokio |
|---|---:|---|---|
| main | 6.38 | 1 | 16.5% slower |
| main, a layout copy | 6.39 | 1.004 [0.936-1.019] | |
| one | 5.16 | 0.810 [0.748-0.909] | 6% faster, 14 of 15 rounds |
| Tokio | 5.48 | | |

Ping-pong (1.000), connect (0.971) and bench/tasks' spawn, chain, fanout,
yield, hog and produce stay within the layout copy's spread.

**Idle workers leave a busy worker's connections alone** (`final2`, on the
Mac only: while under a tenth of a descriptor-holding worker's fibers run
20 µs or longer, a worker going to sleep does not look at its poller, and a
batch's later fibers wake no other worker for 50 µs; otherwise main's rules).
With `one`, on a Mac under other load (read the paired ratios, not the
absolutes), 15 rounds:

| bench/http closed loop | main | A/A | one | final2 + one | hyper |
|---|---|---|---|---|---|
| against hyper, paired | 0.990 | 0.991 | 1.016 | **1.143** [0.991-1.200] | 1 |
| server cycles a request | 59.6k | 56.9k | 52.6k | **36.2k** | 58.3k |

final2 + one beat hyper in 14 of 15 rounds. Echo 0.733 of main; connect,
ping-pong, spawn, wake and yield within the A/A spread. Open when this was
written: whether final2 adds stalls (every arm, hyper included, had rounds
over 10 ms on that machine), bench/mixed's p50 at 100k (75 against 70 µs),
and the gates.

**What did not matter**, each within 0.5% of main on echo: the kick (a
`kevent64` trigger wakes a thread as fast as a condition variable or
`__ulock_wake`, about 5.0 µs each way), `settle_wait` and `brief_wait`, the
3 µs wait before a "run next" slot is stolen, and waking a worker for a short
ring. A rule with no looks at other pollers at all (`nl`) took echo further
(4.95 µs) but raised bench/mixed's p50 at 100k from 57 to 68 µs; it is the
archived `sched-solo` rule, which lost on pup.

**Why the closed loop's rounds varied so much** (158.6k to 175.0k): the
accept loop's task moves, so each run splits the 64 connections over the
workers' pollers differently (44/9/10/3, 32/34, ...), and round by round the
rate follows the system calls a request (rank correlation -0.86). One poller
removes the split.

## Linux, 120k on one core

Rig trails hyper by 6 µs at p50 and p99 at 120,000 a second (23 / 62 against
17 / 56), level or ahead at every other rate. The cause, by counts: at that
load a 30 µs hash keeps one worker busy nearly all the time, and the other
sleeps in its own poller while the busy worker's connections wait (39% of
trivial requests wait more than 8 µs to be read, against hyper's 19%;
hyper's idle worker parks on its one driver, so every arrival wakes it). The
best probe that ties hyper there (`l4`) costs 6-8% of the mix's cycles and
5-6% on connect over twelve workers, trading a win for a tie; its successor
(`l6`) was being measured when this was written ([linux-120k.md](linux-120k.md)).

## The lesson

A scheduler's cost on a machine of mixed cores is not only its code but how
many workers it keeps awake and how often one worker reaches into another's
work. Count system calls and busy cores a request, not just throughput, and
start from a hand-written ceiling: the tuning that seemed likely (how a worker
is woken, how long it waits) moved nothing, and the counts pointed at the
structure.
