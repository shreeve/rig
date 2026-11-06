# Parallel teardown at `os.exit`, on the Mac: design and soundness

2026-11-06. Builds on the Mac exit measurement (Trig `c040e92`; the
report's fix 1 and fix 3) and on the exit panel
([panels/exit/](../panels/exit/)), whose os.md designed this as (c′) and
runtime.md as "design B", both marked MEASURE FIRST.

## What the Mac's exit costs

On the Mac a process's exit is the kernel freeing its page-table pages,
about 12.6-14 µs each, and its resident pages, about 0.008 ms per MiB.
Trig's release build ends by `os.exit` right after its output, so the
whole 1.5-6.2 ms from `_exit` to the parent's `wait4` is that kernel
work, on one core. Most of it is the Tables: each starts in its own
32 MiB span, so each costs one L3 page-table page. The rest is fiber
stacks (one each, touched at its top), the heap's segments, and the
system's own. The C probe showed the same `munmap`s done by 4 threads
take about half as long as one thread or the exit (5.7 against 2.9 ms
for 400 page-table pages); the hook's simulation on Trig saw 3.9 to
2.8 ms on superstruct at 4 checkers and 7.0 to 4.2-4.5 ms at 8.

## Why this is not the exit handoff

The panel dropped every handoff (fork, reparent, exit before the
teardown) because it moves the teardown out of the window the caller
measures: the caller's `wait4` returns before the work is done, the
child's rusage and peak RSS never reach the caller, and back-to-back runs
overlap. This design does none of that:

- the same process does the same work, before it calls `_exit`, so the
  parent's `wait4` returns only after all of it (and after the kernel's
  own remainder);
- the work runs on the process's own threads, its workers, so `time`,
  `getrusage` and cycles count it, contention and all; its CPU time can
  only rise;
- peak RSS is unchanged: nothing is allocated, and memory only goes away;
- nothing is moved earlier into the run, either: it starts when `os.exit`
  is called, after the output is flushed.

It shortens the teardown by splitting it across cores the program
already owns, where the kernel alone would use one. That is the panel's
test for an honest gain (os.md §3, runtime.md §4).

## The change

### Fix 3: one Tables region on the Mac

`alloc.reserveTable` hands release builds on the Mac a range of the
Tables' regions, as on Linux: regions of 256 GiB, each mapped once, a
Table taking the smallest free range that fits, else the newest region's
rest. The Mac's regions are 32 GiB, not Linux's 256 GiB: the Mac's kernel
walks a mapping's whole range as the process ends, touched or not, at
about 2.4 µs a GiB (a C probe, 40 shuffled rounds: an untouched 256 GiB
mapping adds 0.6 ms to the exit, 64 GiB 0.14 ms, 16 GiB nothing
measurable), and the first build, with 256 GiB regions, made every
one-checker run of Trig about 1 ms slower. A Table given back (`unreserveTable`) has its range mapped again in
place (`mmap` with `MAP_FIXED`), which frees its pages and reads as zeros,
the guarantee `MADV_DONTNEED` gives on Linux. Darwin has no huge pages to
ask for, so the madvise calls stay Linux's. Debug builds still map each
Table on its own, so the leak checker and the sanitizer see each.

On its own this saves about 50 `mmap` calls per checker as the checkers
start and does not change the exit (the report's probe: one mapping with
400 sparse pages exits as 400 mappings do). It gives the teardown its
list of ranges: the regions, and how far into each Tables were handed
out.

### Fix 1: the teardown

`os.exit` (`rt.exitNow`) locks and flushes the output as now. Then, on
the Mac in a release build, it calls `sched.tearDown()`, which either
returns having freed what it could in parallel or returns at once, and
then `_exit` runs as now. In outline:

1. **Cheap tests.** The scheduler has started, with at least two
   workers; it is not stopping (`main` has not returned); the caller is a
   worker's fiber; the work to free is worth it (an estimate from the
   Tables handed out, the heap's segments, and the free stacks: at least
   about 0.4 ms of kernel time); and no other worker runs a fiber. Any
   test failing: plain exit.
2. **Claim.** One compare-and-swap of `exit_phase` from `idle` to
   `gathering`. A second `os.exit` racing the first loses it and exits
   plainly, as two racing `os.exit`s do today. From here the caller holds
   off preemption (`holdOff`).
3. **Stop the workers.** A worker waiting in its poller marks itself
   `waiting` (`Poller.parked`) just before the `kevent` call and swaps
   the mark back to `awake` as the call returns, before it reads a single
   event. The caller compare-and-swaps each other worker's mark from
   `waiting` to `claimed`: a worker claimed so is stopped at once, and
   when it wakes it sees `claimed` and stops there. A worker not waiting
   in its poller stops at the top of its loop, which checks `exit_phase`
   before it takes any fiber to run, and in `sleep`, which checks it as
   it checks `stopping`. Every other worker is kicked, so it wakes to
   help. A stopped worker never returns to the loop: it waits for `go`,
   does its share, and then sleeps until the process ends. The caller
   waits until every other worker is stopped; if instead it sees one
   running a fiber (`current` set), or 2 ms pass, it exits plainly,
   leaving those that stopped asleep.
4. **Freeze the pool.** With every other worker stopped, no fiber can
   run, so none can make a pool call. The caller takes the pool's lock and
   never lets it go, and tests again that no call is queued, running, or
   finishing and no call a task left is in flight. Otherwise: plain exit.
   An idle pool thread, and the pool's monitor, then wait for the lock
   forever, touching only the `Pool` global.
5. **Go.** The caller sets `go`. Up to four workers that are awake, the
   caller first (more gain nothing on the Mac's kernel: Trig at 8
   checkers tears down in 4.6 ms on one thread, 3.2 on two, 3.3 on four,
   3.1 on ten), each unmap the free stacks on their own lists, then take
   pieces from one shared counter until none is left: the written part
   of the heap's segment region, a page-table page's span (32 MiB) each,
   and the rest of it and each Tables region, whole (the kernel walks
   even untouched address space), cut into about four pieces per helper,
   all on 32 MiB boundaries, so no two threads free the same page-table
   page. Each piece unmapped is counted.
6. **End.** The caller waits until every piece is unmapped, then returns
   to `endProcess`, which calls `_exit`. A worker past the four, or one
   claimed that has not woken by then, takes no piece and leaves its free
   stacks to the kernel.

`main`'s normal return keeps today's path. By the time `main` has
returned the scheduler has joined its workers, so there is no idle core
to help, and the code after it (the scheduler's own teardown, Zig's start
code, libc's `exit` and its atexit handlers) still runs; a teardown there
would have to come before all of it, which it cannot do soundly. Trig's
release build ends by `os.exit`, which is the path that counts.

Linux keeps its behavior. The same gate would apply there, but the
panel's Linux question (whether parallel `MADV_DONTNEED` or `munmap`
scales under the lruvec and zone locks) is still unmeasured, so the
teardown is Mac-only (`tearDown` is compiled only for Darwin).

Left to the kernel, as before: stacks of fibers that are parked, the
caller's own stack, `main`'s stack, the heaps' large blocks (mapped one by
one and not listed), and everything that is not Rig's.

## Soundness

The claim: no code touches memory after the teardown unmaps it, so the
teardown cannot turn an `os.exit` into a crash, a wrong write, or a wrong
status. The memory unmapped is the Tables' regions, the heap's segment
region, and the stacks on the workers' free lists. Who could touch it,
and why none does:

- **Fibers (tasks, actors, `main`).** A fiber runs only on a worker,
  started from the worker's loop. Every other worker stops either at the
  top of its loop, before taking a fiber, or in its poller, before
  handling what woke it; once stopped it never runs one again: the stop
  is a function that does not return. A worker is claimed in its poller
  only by a compare-and-swap that finds it `waiting`, inside the system
  call or about to enter it with nothing between; its own swap as it
  wakes and the caller's compare-and-swap are ordered, so either the
  caller finds it `awake` (and waits for it to stop at its loop's top) or
  the worker finds itself `claimed`. Unmapping begins only once every
  other worker has stopped, so no fiber but the caller's can be running,
  and none can start. A fiber that was running when the caller
  looked keeps its worker from stopping; the caller then sees its
  `current` set, or the 2 ms pass, and exits plainly, as today, without
  unmapping anything.
- **A woken timer task.** A worker's sleep can fire due timers and make
  their fibers ready (`serviceAll`) before it reaches the top of its loop,
  which writes to fibers and queues in the heap. That happens before the
  worker stops, so before anything is unmapped. Once stopped, it runs
  none of them. So a timer due during the teardown wakes no task that
  runs.
- **The caller.** It runs on its own fiber's stack (never on a free list:
  it is running) or on `main`'s stack (a mapping of its own, not listed).
  Between `go` and `_exit` it runs only the teardown code: atomics on
  globals, `munmap`, its own free list (read before any piece is
  unmapped, and stacks are never in a piece's range), and `_exit`. It
  calls no allocator and reads no task state. Preemption is held off from
  before the claim, so no signal switches it away.
- **The other workers.** After stopping, each touches only globals, the
  `Worker` array (Zig's `smp_allocator`, not Rig's heap), its own free
  list's stacks, and its thread's stack (a pthread stack, or for worker 0
  the process's main stack); one claimed in its poller still holds that
  poller's lock, which no stopped thread wants. Afterwards it sleeps in
  `nanosleep` until the process ends. A helper still unmapping when the
  caller calls `_exit` is harmless: the kernel ends the call with the
  process.
- **The blocking pool.** A pool thread runs a call that may read or write
  the heap or a Table. The pool is frozen only once no fiber can make a
  call, and only if no call is queued, running or finishing and no left
  call is in flight; its lock is then never let go. An idle pool thread
  wakes only to take that lock (it touches `Pool`, a global), so it never
  runs a call or retires (`threadExit` would touch its `Heap`, which is
  mapped apart from the segments anyway).
- **The preemption monitor.** It reads the `Worker` array and the
  preemption states (globals) and signals threads. Its handler,
  `onPreempt`, returns before reading a fiber on a worker whose `current`
  is null (every stopped worker) or whose preemption is held off (the
  caller).
- **Signal handlers.** The interrupt handler writes globals and kicks the
  workers' pollers (system calls on descriptors). A second interrupt ends
  the process by the signal, as now. The broken-pipe handler does nothing.
  The fault and overflow handlers run only on a fault, on alternate signal
  stacks that are mappings of their own.
- **The kernel.** On the Mac nothing writes to the process's memory
  asynchronously: kqueue writes events only during a `kevent` call, and no
  worker is in one into memory being unmapped (a stopped worker is not in
  `kevent`; a blocked pool call would have failed the test).
- **Other threads.** Rig starts none but the workers, the pool's threads
  and its monitor, and the preemption monitor; safe Rig cannot start a
  thread. A thread a C library starts through `extern` code uses its own
  memory, never Rig's segments or Tables (`raw` code that hands such
  memory to C is outside the guarantee, as it is today).
- **Reused addresses.** Every range unmapped is one Rig mapped and never
  gave back: the regions are never unmapped while the program runs, and a
  stack on a free list is mapped by definition. So no `munmap` can hit a
  mapping that reused an address, such as a thread's stack or libc's
  memory.

Liveness: the caller waits at most 2 ms for the workers to stop, then
exits plainly; once all stopped, the teardown is bounded by the pieces.
An `os.exit` never hangs on it.

What the program observes does not change: `os.exit` already runs no
drop, `defer` or leak check, and its other tasks already end where they
are. Its output is flushed before the teardown starts, and its status is
the same.

## Cases

- `os.exit` with tasks parked (on a channel, a `Done`, a sleep): the
  teardown runs, the status and output are right.
- With a timer due during the teardown (a task asleep for less than the
  teardown takes): the task does not run.
- With a task still running (a loop with no waiting point): the plain
  path, the same status.
- Each in debug (plain path: the teardown is release-only), release, and
  under `RIG_SANITIZE=1`, which the runner sets.

`RIG_SCHED_STATS=1` prints which path `os.exit` took, so the CLI test
can see it.

## Measured

Trig `origin/main` 9802432, release build (`rig build --release`, Zig's
safe mode, no PGO), `-p tsconfig.trig.json --noEmit --checkers N` in each
of misc/projects, on the Mac (arm64, 10 cores, load 4-6). Three arms:
main (Rig 14a0e754b, this branch's base), the branch, and an A/A copy of
main's binary; every arm, project and checker count shuffled within each
of 20 rounds; wall from launch to reaping, and cycles, instructions and
peak RSS from `/usr/bin/time -l`. Output is identical to main's on all
1080 runs. Medians of 20, ms:

| project | c | main | A/A | branch | branch against main |
|---|---|---:|---:|---:|---|
| mitt | 1 | 10.4 | 10.3 | 10.5 | level |
| mitt | 4 | 12.3 | 12.1 | 11.2 | 9% faster |
| mitt | 8 | 15.7 | 15.6 | 12.8 | 18% faster |
| neverthrow | 1 | 11.8 | 11.9 | 12.0 | level |
| neverthrow | 4 | 12.9 | 13.2 | 11.6 | 10% faster |
| neverthrow | 8 | 16.3 | 16.5 | 13.3 | 18% faster |
| superstruct | 1 | 18.6 | 18.5 | 18.5 | level |
| superstruct | 4 | 15.1 | 15.0 | 13.7 | 9% faster |
| superstruct | 8 | 17.8 | 17.8 | 14.7 | 17% faster |
| tiny-invariant | 1 | 38.1 | 37.4 | 37.6 | level |
| tiny-invariant | 4 | 37.4 | 37.7 | 36.0 | 3.7% faster |
| tiny-invariant | 8 | 41.3 | 41.4 | 38.5 | 6.8% faster |
| zod3 | 1 | 77.5 | 77.4 | 77.5 | level |
| zod3 | 4 | 43.2 | 43.1 | 42.8 | level (1%) |
| zod3 | 8 | 44.2 | 43.2 | 42.9 | level (3%, A/A 2.3%) |
| ts-pattern | 1 | 417.9 | 418.2 | 416.4 | level |
| ts-pattern | 4 | 172.9 | 172.5 | 175.0 | level (1.2% slower) |
| ts-pattern | 8 | 154.9 | 156.0 | 157.7 | level (1.8% slower) |

- **One checker** takes the plain path (Trig makes no tasks there), so it
  measures fix 3 alone: level.
- **ts-pattern and zod3** are within the noise in every run: two earlier
  runs of 20 rounds put ts-pattern at 8 checkers 2.2% and 0.8% faster,
  and at 4 0.5% slower. Their exits are mostly resident pages in large
  blocks, which the teardown leaves to the kernel, and the dropped
  checkers have already given their Tables back.
- **Peak RSS** is level: medians within 1.5 MiB of main's on every row,
  as the A/A's are, and maxima within the A/A's spread.
- **Cycles and instructions rise** at four and eight checkers (for
  example superstruct at 8, 317 to 402 M instructions): the kernel's
  unmapping, which main's exit does after the process's accounting ends,
  now runs inside it, on its threads. That is the honesty the panel
  asked for, and it means the instruction half of the bar is not met; the
  time half is, on four of the six projects.
- **In-process cost**, from `RIG_SCHED_STATS=1`: stopping the workers
  takes 8-20 µs; the teardown 1.6-1.9 ms at four checkers and about 3 ms
  at eight.
- **Two findings on the way.** The first build used Linux's 256 GiB
  regions and made every one-checker run about 1 ms slower: the Mac's
  kernel walks a mapping's whole range at exit (the C probe above), so
  the Mac's regions are 32 GiB and the teardown unmaps them whole. A
  dropped Table's range mapped again in place (`MAP_FIXED`) frees its
  page tables as `munmap` does (C probe: 400 such drops 4.3 ms against
  4.2, and the exit after them the same).

Data and scripts (not kept): `ab.py` and `sum.py`, the harness and its
summary, and the C probes `reg.c`, `sz.c` and `drop.c`.

## Fix 2

Reusing fiber stacks from one shared free list (so fewer distinct stacks
are ever touched) is left out: it changes the scheduler's stack
ownership, which the teardown relies on being per worker, for at most
0.4 ms on ts-pattern at 4 checkers.
