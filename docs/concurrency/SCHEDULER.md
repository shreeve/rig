# The scheduler

How Rig runs tasks fast: the engine under `f(x)&` (docs/CONCURRENCY.md,
"The engine"), measured against Tokio and Go by `bench/tasks`, whose
`PROGRESS.md` records each step. It is built in increments, each its own
pull request. Every program that makes tasks runs on it, with one worker
per core, or `RIG_WORKERS` of them when that is set as the program
starts; a program that makes none starts no workers.

## Shape

- **Workers.** One thread per core runs tasks. `main`'s thread is worker
  0, and `main` runs as the first task (`sched.runMain`), so a wait in
  `main` is a task's wait.
- **Fibers.** A task is a fiber: a record and a stack of its own. A
  switch saves the registers a call keeps on the stack being left and
  restores those of the stack resumed (`sched.switchTo`, written for
  aarch64 and x86_64).
- **The boundary.** `tasks.zig` calls the scheduler directly (`Handle`,
  `Control`, `Wakeup`) for everything a task does: start, wait, cancel,
  sleep, and yield. A call that blocks its thread runs on the blocking
  pool (`rig.blocking`) while the task waiting on it parks, so a worker
  never blocks; `std.file.read` does so today. Other system calls go
  through a `Threaded` instance of Zig's `std.Io` (`rt.io`) on the
  calling thread, which runs no tasks; a write to a full pipe holds its
  worker until it returns. Rig's own `std.Io`, with the rest of I/O on
  the pool or an event loop, comes with step 5 of the plan.

## Speed

- **One atomic word per task** holds its state and reference count:
  waking is one compare-and-swap, and a task is queued at most once.
- **Queues.** Each worker owns a ring of 256 ready tasks, pushed with
  one store; other workers steal half with one compare-and-swap. A "run
  next" slot keeps a just-woken task in cache, at most 3 in a row. A
  global queue takes overflow and work from outside the workers.
- **Cheap until it runs.** A task gets its stack when it first runs,
  from the worker that runs it. A waiter whose task has not started and
  is next on its worker hands the worker straight to it, on the task's
  own stack, and the task switches straight back when it ends, past the
  queues (`sched.handoff`). Running the task on the waiter's own stack
  would be faster still, but is safe only for a task whose stack use is
  proven to fit, which Rig does not yet prove.
- **Idle workers** steal from a random victim, at most half of them
  searching at once; one that finds work wakes one more; workers with no
  work sleep in their poller (below).

## Stacks

A task's stack is 64 MiB of address space, as `main`'s is, since a
frame may keep up to 13 MiB of values, committed only as the task
touches it. Stacks never move, since loans point into them. They are
carved 16 at a time from one reservation, and each worker keeps up to
64 free for the next tasks, returning more to the system.

Below each stack is a guard that a frame overflowing the stack faults
in. A frame that skipped past its guard would land in another's memory,
so the guard is wider than any frame the program has. The compiler
already bounds each frame it emits (`sema.reach_factor` times its
reach, which `test/cli/frame_reach.sh` checks against the frames Zig
really reserves), so `bin/rig` sizes the guard of each program's tasks
from its largest frame: at least twice it, and at least 16 MiB, room
for sixteen frames under `sema.noinline_reach` merged into one by Zig's
inlining (`sema.taskGuard`, `__rig_task_guard`). Most programs take
16 MiB, and one with frames as large as the compiler accepts takes
1 GiB. The runtime's and the Zig library's frames, which the compiler
does not count, stay under half the smallest guard
(`test/cli/task_frames.sh`). A guard costs address space, not memory:
with 16 MiB guards, about 1.6 million tasks fit at once on macOS.

A compiler usually emits *stack probes* instead, touching each page of
a large frame in order so it faults in a small guard. Zig emits none on
aarch64, and a probe Rig emitted would have to know the frame's real
size, which only Zig does: probing the compiler's bound reports an
overflow for frames that fit.

A free stack's link in its worker's list is kept at its top, on the page
the next fiber touches anyway, so a sleeping task holds one page of its
stack and its record: about 17 KiB on the Mac, whose pages are 16 KiB,
and 5 KiB on pup's Linux, where Tokio's task holds about 300 bytes and
Go's about 3 KiB (`bench/tasks`, `memory`).

## Waiting

Every wait that something else ends (a task's end, a set's count, a
timer, a cancel, a call on the blocking pool) follows one protocol
(`sched.Wait`). The waiting fiber begins a numbered wait, tells its
waker the number, looks once more at what it waits for, and switches
away; only then does its worker mark it asleep. A waker moves the wait
to woken, for its number only, with one compare-and-swap: exactly one
waker wins, a waker that comes before the switch leaves the wait woken
so the fiber goes straight back on a queue, and a stale waker finds a
later number and does nothing. A cancel ends only a wait a cancel may
end, and a task waiting on another passes its cancel on itself, hand
over hand, so no cancel reaches a task through a chain another may free.

## Yield checks

A fiber yields only at a waiting point, so a task that computes without
waiting would hold its worker, and the work queued behind it would wait
until it ends. In a program that makes tasks, the compiler adds yield
checks where a computation can run long without waiting. A check never
fails, and yields only when other work waits.

- **Loops.** Each outermost loop keeps a count of its turns, a local of
  its own, and every 1,024 turns calls the scheduler (`rig.turn`,
  `sched.tick`). The task yields when work waits for its worker (in its
  "run next" slot, its ring, or the global queue) or for another busy
  one (the flag below). A loop inside another
  is not counted, so the inner loops that do the most work stay as
  tight as they were.
- **Recursion.** A function on a cycle of calls (`inlining.decide`)
  starts by reading one flag, `sched.waiting`, on a cache line of its
  own. Work woken or made while every worker is busy sets it. The first
  check to see it clears it and yields to that work: its own worker's,
  or half of another busy worker's ring, stolen. A worker that finds no
  work and sleeps clears it too. A task that yields only puts itself
  back in line, so it never sets the flag, and busy tasks do not keep
  yielding to each other.

The loop check costs a decrement and a branch per turn of an outermost
loop: within noise on `bench/tasks`. The recursion check is a load and
a branch per call: free in any function that does work, but a
function as small as `fib` runs about 1.5x slower with it.

With every core busy with long loops, a task queued behind one on its
worker waits for one slice of that loop, not all of it (`bench/tasks`
`hog`): under 0.1 ms on the Mac and on pup, where Tokio and Go wait 2
to 3 ms, the whole loop. Go stops a goroutine after 10 ms, by a
signal; Tokio never does.

## Deterministic runs

A program started with `RIG_SEED` set, as `rig test` starts one, runs
deterministically (`sched.deterministic`, SPEC §3 "Tests"):

- **One thread.** No other worker starts, and no timer or pool thread:
  a blocking call runs in place. The ready fibers sit in one list, and
  the seed (splitmix64, then xorshift64*) picks the next to run, and
  whether a yield check yields. `par` still splits its elements among
  four tasks, so the seed tries their interleavings.
- **A virtual clock.** `sched.nowNs` reads it. Before each pick, the
  timers it has reached wake their fibers; when none is ready, it jumps
  to the earliest timer. Each yield check and `task.check()` moves it
  1 µs, so a fiber that computes without waiting still reaches its
  deadline, and fibers waiting on a timer behind it still wake.
- **Deadlock.** With no fiber ready and no timer set, every task waits
  on another, and the program panics.

The same seed makes the same choices, so a run prints the same thing
every time; the suite runs each concurrency case again under seeds 1 to
20 (`seeds: 20`, docs/RIG-TESTS.md).

## Increments

1. **Fibers on one worker**: the switch, start, wait, yield, and the
   waiting points (`task.check`, `time.sleep`, waits on sets), which
   yield until they can go on. `main` is the first fiber.
2. **Many workers**: the rings, stealing, the global queue, workers that
   sleep and wake, a fiber queued or recorded as waiting only once it has
   switched away, and the two fast paths many workers need to keep up
   with one: a stack taken when a fiber first runs, from the worker that
   runs it, and the "run next" slot.
3. **Stacks and handoff**: stacks carved from reservations and returned
   when a worker keeps enough, handoff to a waited-for task, one
   allocation per task, and a shared count ticked only by tasks of sets
   that can fail.
4. **Waiting without spinning**: one protocol for every wait that
   something else ends (`sched.Wait`): a timer thread with a heap of
   deadlines, a cancel that wakes the wait it ends, a waiter that passes
   its cancel on to the task it waits on, and the blocking pool, which
   `std.file` reads through.
5. **Yield checks**: a countdown in each outermost loop, and a flag
   read on entry to each recursive function, in programs that make
   tasks (above).
6. **The default**: every program that makes tasks runs on the
   scheduler, and Zig's `Threaded` backend no longer runs tasks.
7. **Guards sized to the program**: each program's task guard from its
   largest frame, 16 MiB for most in place of 1 GiB, so a million tasks
   fit at once, and a sleeping task holding one stack page in place of
   two.
8. **Pollers and timers per worker**: each worker sleeps in a poller of
   its own, kqueue on macOS and epoll on Linux, which a waker kicks, and
   keeps a heap of the deadlines its fibers set, as Go keeps one per
   processor, in place of the timer thread. A worker that runs fibers
   looks at both every 61 turns; one about to sleep wakes the fibers
   whose timers are due on any worker, polls the pollers no worker
   sleeps in, and sleeps until the earliest deadline any worker holds.
   A file descriptor registered with a poller (`sched.Registration`)
   reports when it becomes ready to read or write, edge-triggered, and a
   fiber waits for that (`sched.waitReady`), spending from a budget of
   128 when it need not wait, so a descriptor always ready cannot keep
   it on its worker. A round of 10,000 tasks that sleep 5 ms ends about
   40% sooner than with the timer thread on the Mac.

Each must not make `bench/tasks` slower on the benchmarks it touches;
the step is done when `spawn`, `chain`, and `yield` are each within 1.2x
of Tokio's time on the Mac (arm64) and on pup (x86_64).
