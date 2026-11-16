# Loopback round trips: where the time goes, the Zig ceiling, and what Rig now does (2026-11-15)

The release re-measure ([concurrency-bench-remeasure](../concurrency-bench-remeasure/README.md))
found Rig's loopback round trips slower than Tokio's on the Mac:
ping-pong 20%, echo 47%. This record counts what each runtime does per
round trip, writes the fastest Zig for the same work, and closes the
gap in the runtime by the owner's method: the fastest Zig first, then
make Rig produce it.

Apple M5, 10 cores, macOS (Darwin 27.2), base main 7a2efd0f3. Rig
`--release`; Tokio from the `misc/tokio` clone, `cargo build --release`
with LTO; the ceiling `zig build-exe -OReleaseFast -lc`. The Mac was
shared with other sessions' builds: every timed board ran under
`tools/mac-claim`, interleaved and rotated, fastest of N.

Files: [ceiling.zig](ceiling.zig) (the ceiling, every shape below),
[count.c](count.c) (the counting library), [board.py](board.py) (the
interleaved board), [http_prof.py](http_prof.py) and
[http_ab.py](http_ab.py) (HTTP per request, and A/B), [med.py](med.py)
(a board's fastest and median), and `raw/`, every board's runs and every
count. In `raw/`, `main` is 7a2efd0f3, `f1` the first change, `f2` the
first two, `f5` all three (the branch); `f3` and `f4` are the dropped
arm below (`f3` no look at its own poller, `f4` that and the look gap).
`*.count` are count.c's output, one benchmark a run; `h-*.count` HTTP.
`f6` is the dropped EVFILT_EXCEPT try at urgent data, `f7` the kept fix
(raw/board9.txt to board11.txt).

## The outcome: two changes, not three (2026-11-16)

Measured on Linux (pup), the third change, a worker going to sleep
leaving recently taken pollers to their own worker (00d2fb066), made
connect 9-11% slower and served 15% fewer HTTP requests on 12 P-cores.
A split board, main against each change alone (raw/linux/split/,
pup 2026-11-16, medians of 20 net rounds and 7 HTTP rounds, A/A beside),
put the whole cost on it:

| row (pup) | main | A/A | short read | kick | skip | all three |
|---|---:|---:|---:|---:|---:|---:|
| connect, cores 6,7 (µs) | 29.05 | 28.89 | 28.95 | 28.37 | **31.56** | **31.20** |
| connect, cores 0-11 | 26.57 | 26.47 | 26.40 | 26.27 | **29.41** | **28.76** |
| echo, cores 6,7 | 3.75 | 3.75 | **3.50** | 3.77 | 3.76 | 3.52 |
| ping-pong, cores 6,7 | 5.17 | 5.15 | **4.83** | 5.22 | 5.14 | 4.91 |
| ping-pong, cores 0-11 | 5.50 | 5.44 | **5.11** | 5.50 | 5.41 | 5.14 |
| HTTP req/s, cores 0-11 | 621k | 690k | 713k | 683k | **551k** | **572k** |

It is reverted (a0375e5fa); the short read and the kick stay. The short
read alone gives Linux its gains (echo 6.7% and ping-pong 6.6% faster
pinned, ping-pong 7.1% on 12 cores) and 40% fewer system calls in
bench/net (raw/linux/, strace); the kick is level everywhere.

The Mac again, at a0375e5fa against main ea3704772 and an A/A copy of
main, under `tools/mac-claim`, medians of 20 net rounds and 7 HTTP
rounds (raw/mac-final/):

| row (Mac) | main | A/A | branch | branch against main |
|---|---:|---:|---:|---|
| echo (µs) | 8.75 | 8.73 | 8.28 | 5.4% faster (A/A 0.2% faster) |
| ping-pong | 16.60 | 16.45 | 16.25 | 2.1% faster (A/A 0.9% faster) |
| connect | 54.27 | 54.78 | 54.79 | level (A/A 0.9% slower) |
| HTTP req/s | 128,308 | 126,996 | 129,693 | level (1.1% more; A/A 1.0% fewer) |

So the Mac keeps a smaller gain than the three changes gave (echo 22%
faster with the skip, most of it the skip's): the skip's gain on the
Mac, where looks at other workers' pollers were most of echo's extra
calls, was a loss on Linux. The sections below describe all three
changes as first built and measured.

## How it was counted

`count.c` is a library loaded with `DYLD_INSERT_LIBRARIES` that wraps
libSystem's `read`, `recv`, `recvfrom`, `write`, `send`, `sendto`,
`kevent`, `kevent64` and the condition variables, per thread, and
reads `getrusage` for context switches. Rust's `recv` reaches
`recvfrom` through a stub too, so Tokio's reads show twice in the raw
counts; the tables give each call once. A `kevent` with no room for
events is a change (a registration, or a kick); one with a zero timeout
is a look; any other a wait. dtruss needs SIP off, which the Mac does
not have. Each count is one run of the one benchmark, divided by its
round trips.

## The profile (a)

System calls per round trip, before the changes:

| | read (of them EAGAIN) | write | kevent: wait / look / change | cond var | all | where |
|---|---|---|---|---|---|---|
| pingpong, Tokio | 3 (1) | 2 | 2.8 / 0.07 / 0 | 0 | 7.9 | both tasks on one worker |
| pingpong, Rig main | 4 (2) | 2 | 0.5 / 2.2 / 0.2 | | 9.1 | client on worker 0, server on worker 9 |
| pingpong, Zig, two threads | 4 (2) | 2 | 2 / 0 / 0 | | 8 | |
| pingpong, Zig, two threads, short read drains | 2 (0) | 2 | 2 / 0 / 0 | | 6 | |
| echo, Tokio | 3 (1) | 2 | 0.24 / 0.03 / 0.005 | 0.85 | 6.1 | ten workers |
| echo, Rig main | 4 (2) | 2 | 0.2 / 3.2 / 2.2 | | 11.6 | ten workers, each stole about 11,000 tasks |
| echo, Zig, one thread | 4 (2) | 2 | 0.03 / 0 / 0 | | 6 | |
| echo, Zig, one thread, short read drains | 2 (0) | 2 | 0.04 / 0 / 0 | | 4 | |

Where the time goes:

- **The kernel's loopback.** On macOS a byte written to a loopback
  socket reaches its peer a few microseconds later, not within the
  write: the Zig ceiling on one thread waits in `kevent` on every half
  trip (2 waits a trip, each waking). One round trip costs about 13 µs
  however few the calls; Linux's is under 5.
- **Reads told to wait (pingpong, echo, HTTP).** Rig read again after
  every short read and was told EAGAIN: 4 reads a trip where 2 do.
  Tokio clears a socket's readiness after a short read and reads 3.
- **Kicks bounced from look to look (echo).** A worker going to sleep
  looked at every poller no worker slept in, and a look that found a
  kick put it back with a second call, so one kick passed from worker
  to worker: probes counted 2.36 re-kicks a round trip against 0.28
  real ones (0.12 waking a worker for new work, 0.16 passing the watch).
- **Looks that find nothing (echo).** Ten workers answering sockets go
  to sleep tens of thousands of times a second, and each looked at every
  awake worker's poller: 3.2 looks a trip, most finding nothing. Tokio
  has one poller and parks idle workers on a condition variable, 0.42
  wakes a trip.
- **Context switches.** Involuntary switches a trip: Tokio 3.0 in
  pingpong, 0.73 in echo; Rig 2.3 and 1.0. No voluntary ones: kqueue
  waits count as neither.
- **Which worker.** Rig's pingpong runs the client on worker 0 and the
  server on worker 9, so each answer is read on another worker than the
  one that wrote its request; Tokio runs both on one worker. The ceiling
  shows the two shapes cost the same (one thread 13.01 µs, two 12.99,
  fastest of 7).

HTTP, per request, under bench/http's load (64 connections, 3 s; a
loaded Mac, so the rates are only a guide):

| | read (EAGAIN) | write | kevent | cond var | all |
|---|---|---|---|---|---|
| hyper | 1 (0) | 1 (writev) | 0.25 | 0.46 | 2.7 |
| Rig main | 2 (1) | 1 | 0.48 | | 3.5 |
| Rig, this branch | 1 (0) | 1 | 0.5 | | 2.5 |

The pup run the coordinator sent (Linux, main 3f4564a4b) puts Rig's
HTTP CPU at 5.9 to 6.1 µs a request against hyper's 5.1 to 5.2: the
EAGAIN read between requests was one of the extra calls, and is gone.

## The ceiling (b)

Fastest of 7, the same board as Rig and Tokio (raw/board1.txt):

| Shape | pingpong | echo |
|---|---|---|
| Tokio | 13.73 µs | 5.85 µs |
| Rig main | 14.94 µs | 8.63 µs |
| Zig, one thread (pp1, echo1) | 13.78 | 5.98 |
| Zig, one thread, short read drains | 13.01 | 5.67 |
| Zig, two threads, kqueue each, drains (pp2+) | 12.99 | |
| Zig, two threads, blocking sockets (pp2b) | 12.90 | |
| Zig, 2 threads each owning 50 whole connections | | 4.50 |
| Zig, 1 client thread and 1 server thread | | 4.47 |
| Zig, 5 threads each owning 20 connections | | 4.75 |
| Zig, 10 threads each owning 10 connections | | 5.97 |

The ceiling is faster than Tokio: pingpong by 6%, echo by 24%. Echo is
fastest on two threads and slower on ten, where the threads contend in
the kernel's loopback; a scheduler that kept 100 connections on two
cores would beat Tokio's ten-worker spread, which is left for later
(below).

## What Rig now does (c)

Three changes, each in the file that owns the decision, each its own
commit:

1. **net: a read after a short one waits for the next edge before it
   calls** (e2d4b866a). A short read took all there was, so the next read
   waits on the poller for an edge past the count read before it, unless
   the poller has seen the end of reading or urgent data, either of which
   it marks before it counts that edge (`sched.drained`,
   `Registration.short_not_empty`). The HTTP server's wait between
   requests does the same. Reads a trip: 4 to 2; EAGAIN reads: 2 to 0.

   An independent review found that, as first committed, it stalled a
   connection whose peer sent urgent data: a read stops at the urgent
   mark, short with bytes behind it, and no edge comes for them, so the
   next read waited until the peer sent more or closed (20 of 20
   connections timed out at 10 s, where main echoed them in 0.10 s;
   Tokio clears readiness the same way and shares it). The fix keeps
   the short-read wait and makes urgent data end it the way the end of
   reading does, at no cost per connection or per trip: on macOS the
   read filter is added with NOTE_OOB, and its event then carries
   NOTE_OOB in its fflags while urgent data waits; on Linux the
   registration's mask has EPOLLPRI, which TCP raises only for urgent
   data. Either marks `short_not_empty` before the edge is counted, so
   a read already waiting wakes, and from then on no read on that
   socket waits first. A case in src/sched.zig ("a read after a short
   one that stopped at urgent data does not wait for an edge") failed
   before and passes; the review's repro echoes 100 of 100 connections
   in 0.11 s. A first try, a third filter (EVFILT_EXCEPT with NOTE_OOB),
   does not work on macOS: that filter fires on every arrival of data,
   urgent or not ([oob.c](oob.c) shows both), so it turned the
   short-read wait off for every socket and cost echo 4.8% against the
   branch (raw/board10.txt). Against the branch before the fix, 20
   rounds (raw/board11.txt, `f7` the fix): echo 6.97 against 6.91 µs,
   connect 50.92 against 50.04, pingpong 15.73 against 15.65, all
   within 2%; echo 17% faster than main (8.44 µs).
2. **sched: a kick that stands makes no system call, and a look leaves
   it standing** (9017a3932). `Poller.kicked` holds a kick not yet taken;
   a look leaves it set, a kick while it is set makes no call, and the
   worker takes it under the poller's lock before it waits. Echo's
   changes a trip: 2.9 to 0.16.
3. **sched: a worker going to sleep leaves another's poller taken from
   lately to that worker** (00d2fb066). Each poller notes when its events were
   last taken (`Poller.taken_at`); a worker going to sleep skips another
   worker's poller taken in the last 50 µs. Its own it still looks at
   before it waits (below). Echo's looks a trip: 3.3 to 1.8, waits 0.5.

After all three, a round trip makes: pingpong 2 reads, 2 writes, 2.2
kevent calls (6.2, the ceiling's 6); echo 2 reads, 2 writes, 2.7 kevent
calls (6.7, Tokio's 6.1, main's 11.6).

### Tried and dropped

- **Not looking at its own poller before it waits.** One call instead
  of two when nothing is there, and pingpong 10% faster and echo 8%
  faster again than the kept change (raw/board5.txt: 14.74 and 6.45
  µs), but `connect` 23% slower (59.52 against 48.29 µs): a connect's
  handshake on loopback lands within the look, and without it the
  worker sleeps and is woken. It fails "no row slower", so the kept
  change looks first. It is the owner's call whether connect (where Rig
  leads Tokio by 20%) may give that up for the other two.
- **Watching sockets for writing only while a writer waits.** Rig's
  poller watches both filters; the write edge comes in the same
  `kevent` as the read edge, so it costs no call. Not pursued.

## Measured (4)

Interleaved and rotated, fastest of 20, under `tools/mac-claim`
(raw/board5.txt; f2 is the first two changes, f5 all three):

| | main | first two | all three | all three against main |
|---|---|---|---|---|
| pingpong | 16.39 µs | 15.42 | 15.24 | 7% faster (medians 16.72, 16.55: level) |
| echo | 8.49 µs | 8.13 | 6.98 | 22% faster |
| connect | 48.29 µs | 48.73 | 47.12 | level |

Each change alone, fastest of 12 (raw/board2.txt): the short read,
echo 3.3% faster than main (8.30 against 8.58 µs), pingpong level; the
standing kick, echo 2% faster again (8.13). Both are small alone; most of
the gain is the third, which the first two make possible: with
re-kicks still bouncing, fewer looks would leave kicks unseen longer.

Against Tokio (board 4, fastest of 12): echo 7.23 against 6.01 µs
(Rig 1.2× slower, was 1.44×), pingpong 16.08 against 12.73 (a noisy
row: Tokio's fastest over the boards ran 12.73 to 14.55), connect 50.82
against 59.89 (Rig 1.18× faster).

The other rows, main against all three (raw/board6.txt, board7.txt,
board8.txt: bench/tasks and bench/actors, interleaved, 20 and 30
rounds; raw/http1.txt: bench/http's load, best of 5):

| Row | main | all three | |
|---|---|---|---|
| HTTP req/s | 134,108 | 141,041 | 5% more (hyper 138,601: Rig now 1.8% ahead) |
| HTTP p50 / p99 | 470 / 632 µs | 446 / 616 µs | |
| chain, fanout, yield, produce, hog | | | level (medians within 2%; fanout 3% faster) |
| actors solo, contend, spread | | | level |
| spawn | 16.73 / 17.88 ms | 15.72 / 18.62 ms | unsettled: fastest 6% faster, median 4% slower (board 8) |

Spawn on the Mac runs in two modes, about 10 and about 18 ms, and which
one a run lands in moves with the machine. Board 6 put main mostly in
the fast mode and the branch mostly in the slow (medians 11.3 against
17.8 ms); boards 7 and 8 put both in the slow mode (medians 18.74
against 18.44, and 17.88 against 18.62). Over boards 7 and 8 the
branch's median is 1.2% over main's, inside the noise, but board 6 is
why spawn is among the pup runs below. The second change adds a flag
to each worker's poller that other workers write (`kicked`), and the
third a time its worker writes (`taken_at`): the scheduler's notes say
a field moved near the workers' hot lines can cost spawn, so pup's
x86 numbers decide.

## What is left

- **Echo on fewer cores.** The ceiling's 4.5 µs comes from keeping the
  connections on two threads; Rig and Tokio spread them over ten, and
  the kernel's loopback contends. Keeping a connection's task on the
  worker whose poller holds its socket, and waking fewer workers for
  socket work, is the next step, a scheduler design question.
- **Pingpong.** Rig makes the ceiling's calls now (6.2 against 6); what
  is left is the wake path and the two workers, about 1 µs a trip, and
  the board's noise is of that size.
- **Linux.** Every number here is the Mac's; the pup runs are below.

## Linux runs needed (pup)

The branch is `loopback-ceiling` at 00d2fb066; main is 7a2efd0f3.

1. Build both Rigs (from a Trig checkout): `tools/pup-rig 00d2fb066`
   and `tools/pup-rig 7a2efd0f3`, giving `B=/zfs/trig-pup/rig-00d2fb066.../bin/rig`
   and `M=/zfs/trig-pup/rig-7a2efd0f3.../bin/rig`.
2. Unit tests of the runtime, on E-cores, in the branch's folder:
   `taskset -c 12-19 zig build test -Doptimize=debug`, then `-Doptimize=safe`,
   then `-Doptimize=fast`.
3. Builds, on E-cores, outside the timing slot (`D=/zfs/<scratch>/loopback`):
   `RIG=$M bench/net/bench-net --out $D/net-main --build-only`,
   `RIG=$B bench/net/bench-net --out $D/net-branch --build-only`, the same
   for `bench/tasks/bench-tasks`, `bench/actors/bench-actors` and
   `bench/http/bench-http` into `$D/{tasks,actors,http}-{main,branch}`.
4. Timing, in one ab slot (`tools/pup-slot open NN 15 ab loopback`), on
   P-core 6, from the branch's folder (`R=docs/history/records/2026-11/concurrency-loopback`):
   `taskset -c 6,7 python3 $R/board.py 20 $D/net.txt main=$D/net-main/rig-safe branch=$D/net-branch/rig-safe tokio=$D/net-main/tokio`,
   `taskset -c 6,7 python3 $R/board.py 30 $D/tasks.txt main=$D/tasks-main/rig-safe branch=$D/tasks-branch/rig-safe`,
   `taskset -c 6,7 python3 $R/board.py 20 $D/actors.txt main=$D/actors-main/rig-safe branch=$D/actors-branch/rig-safe`,
   then `python3 $R/med.py` on each for medians. The net and tasks
   programs use every core they are given; the pin is for a fair A/B,
   and a second run without `taskset` shows the ten-worker shape.
   HTTP: `python3 $R/http_ab.py 5 $D/http.txt $D/http-main/load main=$D/http-main/rig-safe branch=$D/http-branch/rig-safe hyper=$D/http-main/tokio`.
5. System calls per round trip on Linux, for the profile (no slot needed):
   `strace -f -c -e trace=read,write,recvfrom,sendto,writev,epoll_wait,epoll_ctl,futex,eventfd2 $D/net-main/rig-safe`
   and the same for `$D/net-branch/rig-safe` and `$D/net-main/tokio`
   (all three benchmarks in one run; divide by 20,000 + 100,000 + 500).
6. The light gates (a runtime change): Trig's `tools/light` with
   `PUP_RIG=$B`, and loco's `rig/tools/light RIG=...` on the Mac.

What would settle it: net echo faster and pingpong and connect level
on Linux, where Rig's echo already led Tokio (1.10 against 1.29 µs);
spawn level; HTTP at least level.
