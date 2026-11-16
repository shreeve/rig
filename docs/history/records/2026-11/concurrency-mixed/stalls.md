# The 54-63 ms stalls: the Mac's, not the scheduler's (2026-11-16)

The first open-loop board ([README.md](README.md), "Possible scheduler
problems") found two single stalls of 54-63 ms in 56 Rig runs, both at
60,000 a second, and asked whether they were a scheduler defect (a lost
or late wake, a poller not looked at, a worker asleep while work waits,
the monitor, preemption, a timer) or the machine. They are the
machine's: each stall, in Rig, hyper and Go alike, is a moment when
macOS runs none of the threads that are ready, in every process at once.
Nothing in Rig needs fixing for them, and nothing was changed.

## How

From main ea3704772 with `bench-mixed` merged (91b2ee3ef), on the M5,
each board under `tools/mac-claim`:

- **The server's side.** A scratch patch to the runtime
  ([stalls/trace.patch](stalls/trace.patch), never committed to `src/`)
  keeps a ring of 512 Ki events per thread, each with the wall clock:
  every poller wait and its return, every event it reads (with the
  descriptor), every look at another worker's poller and every one that
  found it locked, sleeps and wakes, kicks, fibers run, steals,
  preemption stops and declined signals, the monitor's ticks and
  signals, trims, and, in `std.http`'s server, each accept (with the
  client's port), request read and answer written. On SIGUSR1 it records
  300 ms more, then writes the last 2 s to a file. It is on only with
  `RIG_STALL_TRACE=DIR`; traced, Rig's p99.9 stayed at 0.9-1.4 ms in
  58 of its 60 windows (3.3 ms in one, and the stall below).
- **The generator's side.** The load generator logs every request over
  20 ms: when it was meant to go, when it went, when the first byte of
  the answer came, and when the last did, with its connection's local
  port, and sends Rig's server SIGUSR1 at the first in a second. A
  goroutine sleeping 1 ms logs every wake over 5 ms late, and each GC
  pause over 0.5 ms is logged.
- **A canary,** a C program of two threads in a process of its own
  ([stalls/canary.c](stalls/canary.c)): every 1 ms one wakes from
  `nanosleep` and pings the other over loopback TCP, logging a wake late
  by over 2 ms or a round trip over 2 ms. It touches nothing the
  servers do: when it stalls with a server, the machine stalled.
- **top,** once a second, in board 2.

[stalls/analyze.py](stalls/analyze.py) groups the generator's slow
requests into stalls and puts the canary, the generator's own lateness,
top and the server's trace beside each.

## The stalls reproduce, in every server, with the canary

| board | windows a server | over 20 ms: Rig | hyper | Go | canary over 20 ms |
|---|---|---|---|---|---|
| 1: 7 rounds at 40k, 60k, 80k, 60k, 60k | 35 | 1 (65 ms) | 1 (58 ms) | 1 (89 ms), and 22 ms once | 5, worst 35 ms |
| 2: 5 rounds, the same rates | 25 | 0 (worst 2 ms) | 1 (44 ms) | 1 (100 ms) | 3, worst 26 ms |

Each of the six stalls over 20 ms ([stalls/b1/analysis.txt](stalls/b1/analysis.txt),
[stalls/b2/analysis.txt](stalls/b2/analysis.txt)) has the same shape:

- **Every connection at once.** 3,500-13,000 requests over 20 ms, over
  140-280 ms, not one connection's.
- **The generator stalled too.** Its requests went late: the worst left
  41-98 ms after its time. Its 1 ms ticker woke 28-33 ms late in the
  stalls where it ran (board 1). No GC pause over 0.5 ms came near one.
- **The canary stalled with it,** in another process doing nothing but
  sleeping and pinging: within 8-36 ms of each stall's start it woke
  22-35 ms late, or took 20 ms for a round trip that takes 0.2.

So it stalls hyper as often as Rig (2 against 1 in 60 windows), and Go
about as often, and Go's are the longest only because its generator
side and server both wait.

## Rig's stall from inside

The traced Rig stall (board 1, 40,000 a second, worst 65 ms;
[stalls/b1/rig-stall-trace.txt](stalls/b1/rig-stall-trace.txt) has every
event of the 40 ms before the freeze) shows ready threads not run, and
no work left waiting by the scheduler:

- **Worker 0** read a request at -28.2 ms and wrote its answer at -2.7:
  25.5 ms for a handler of microseconds, with no event between. A fiber
  in the middle of its own code went 25 ms without the CPU.
- **The monitor,** asking the kernel for a 1 ms wait, woke 17.3 ms late.
- **Worker 3,** the watcher, asking for a 1 ms wait in its kqueue, woke
  6.6 ms late; it then read 3 events, woke worker 2 (a kick, at -20.7
  ms), took a fiber, and went 15.6 ms without an event before the
  fiber's read.
- **Worker 2,** asleep in its kqueue, was kicked at -20.7 ms and
  returned from `kevent` at -2.7: the kernel had its wake for 18 ms
  before it ran it.
- Each delayed request's event was read by a worker and its fiber run
  there next; none waited in a queue while a worker looked or slept.

A kick the kernel holds for 18 ms, a 1 ms timeout that ends 7 to 17 ms
late, and a running fiber stopped mid-handler, in the same 20 ms, while
an unrelated process's threads stop too: the kernel ran none of them.
No scheduler of Rig's can make a thread in `kevent` or a monitor in a
futex wait late; a lost wake would show as an event read with its fiber
not run, or a kick with no sleeper, and neither appears.

## What the machine does

- **Unloaded,** the canary alone for 240 s (board 2's first 4
  minutes, no server, no generator) stalled 4 times over 10 ms, worst
  25 ms, as Spotlight (`corespotlightd`) took 194% of a core; under the
  boards it stalls 10-14 times over 10 ms in 15 minutes.
- **At the stalls** top shows nothing but the benchmark over 20% of a
  core in board 2's first (hyper's), and the generator, the server, a
  Claude helper at 110% and `duetexpertd` at 38% in its second (Go's);
  `corespotlightd` ran over 20% of a core in 92 of board 2's seconds.
  Which kernel work stops every thread for 20-100 ms needs a kernel
  trace (`spindump`, `ktrace`), which needs root; it is the Mac's, and
  it lies under every server alike.

## The overload drop, under a controlled load

The exploratory run on a busy machine (load 9, test suites) had Rig fall
from 93,000 to 66,000 a second at 160,000 offered. Board 3 ran 8 threads
spinning on the 10 cores ([stalls/spin.c](stalls/spin.c)) as a fixed
background ([stalls/b3/](stalls/b3/), not traced):

| offered | | Rig | hyper | Go |
|---|---|---|---|---|
| 120,000 | quiet, 2 rounds | 120.0k, p99 1.6-1.8 ms | 120.0k, p99 1.4-1.8 ms | 118-119k, p99 45-83 ms |
| 120,000 | 8 spinners, 3 rounds | 118.9-120.0k, p99 4.6-55 ms | 119.9-120.0k, p99 1.4-7.2 ms | 117.6-120.0k, p99 10-91 ms |
| 160,000 | quiet | 114k, 121k | 121k, 122k | 110k, 111k |
| 160,000 | 8 spinners | 111k, 116k, 124k | 123k, 127k, 128k | 114k, 116k, 122k |

No collapse to 66,000 reproduced: under 8 spinners Rig's throughput at
160,000 offered fell to the level of Go's, 9% below hyper's median
(116,000 against 127,000), and its p99 at 120,000 rose to 50-55 ms in 2
rounds of 3, where hyper's stayed under 8 ms. A `sample` of each server
at 160,000 under the spinners
([stalls/b3/sample-rig-safe.txt.gz](stalls/b3/sample-rig-safe.txt.gz))
shows Rig's workers in `kevent`, `read`, `write` and the handler, with
no spin lock or search among the stacks of 5 samples or more: they do
not burn the shared cores spinning.

A traced board of Rig and hyper at 120,000 under the spinners
([stalls/board4.sh](stalls/board4.sh), [stalls/b4/](stalls/b4/)) fell
behind in later windows in both (Rig to 112,900-117,400 in 3 of 6,
hyper to a 42 ms p50 in 1), with the canary stalling up to 62 ms. What
the trace shows of Rig there, and leaves open:

- **One poller carries every connection.** Each is registered with the
  poller of the worker that accepts it, and `http.serve`'s accept loop
  stayed on worker 0: worker 0's kqueue gave 99-100% of the events in
  every dump. On the quiet board worker 0 read 93% of them itself;
  under the spinners, 18-25%, the rest read by other workers' looks as
  they went to sleep, which found it locked (a worker waiting in it,
  or another looking) 2,500 to 9,500 times a second, and in one 1.5 s
  span 1,755 of its returns came back full (64 events). The
  connections' readiness goes through one kqueue that one thread at a
  time reads. This fits the backlog of the later windows under
  contention; it is not shown to cause it, and spreading connections
  over the pollers is a design question, not a stall fix.
- **Every answer costs a write edge.** Each connection is registered for
  both reading and writing, edge-triggered, so each answer's drained
  send buffer is an event that wakes no one: half the events read
  (120,000 read edges and 120,000 write edges a second at 120,000
  requests). Go and mio register both filters the same way.

## Files

In [stalls/](stalls/):

- `trace.patch`: the runtime's trace, the generator's logging and
  freeze signal, and bench-mixed's options for them (scratch; `src/` is
  unchanged on this branch).
- `st.py`, `analyze.py`: read a dump and a board; `canary.c`, `spin.c`;
  `board.sh` (boards 1 and 2, `CONTROL=240` for board 2's canary
  alone), `board3.sh`, `board4.sh`.
- `b1/`, `b2/`: each board's rows (`raw.jsonl`), its output, the
  canary's log over its span, the generator's log of every stalled
  run (gzipped), the analysis, and for board 1 the decoded trace of
  Rig's stall; board 2's `control.log` and top's log.
- `b3/`: the overload board, quiet and under spinners, and the two
  `sample`s; `b4/`: the traced board under spinners (its 27 dumps, 10 MB
  each, and generator logs of 15-55 MB stayed in the scratch directory).
