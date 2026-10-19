# The scheduler

How Rig runs tasks fast: the engine under `f(x)&` (docs/CONCURRENCY.md,
"The engine"), measured against Tokio and Go by `bench/tasks`, whose
`PROGRESS.md` records each step. It is built in increments, each its own
pull request; until the last, a program runs on it only when built with
`RIG_SCHEDULER=1` (`__rig_scheduler`), and on Zig's `Threaded` backend
otherwise. It runs one worker per core, or `RIG_WORKERS` of them when
that is set as the program starts.

## Shape

- **Workers.** One thread per core runs tasks. `main`'s thread is worker
  0, and `main` runs as the first task (`sched.runMain`), so a wait in
  `main` is a task's wait.
- **Fibers.** A task is a fiber: a record and a stack of its own. A
  switch saves the registers a call keeps on the stack being left and
  restores those of the stack resumed (`sched.switchTo`, written for
  aarch64 and x86_64).
- **The boundary.** Rig implements Zig's `std.Io` interface. Its task
  functions (start, wait, cancel, cancel protection, futex, sleep) are
  the scheduler's; the rest (files, directories, processes, sockets)
  forward to Zig's `Threaded` backend on a pool of blocking threads,
  while the task waiting on them parks, so a worker never blocks.
  `tasks.zig` calls the scheduler directly (`Handle`), with no call
  through the interface.

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
  work sleep on a futex.

## Stacks

A task's stack is 64 MiB of address space, as `main`'s is, since a
frame may keep up to 13 MiB of values, committed only as the task
touches it. Stacks never move, since loans point into them. They are
carved 16 at a time from one reservation, and each worker keeps up to
64 free for the next tasks, returning more to the system.

Below each stack is a guard that a frame overflowing the stack faults
in. A frame that skips past its guard would land in another's memory,
so the guard is wider than any frame Rig allows: 1 GiB, as today's task
stacks have. It costs address space, not memory, but limits a program
to about 100,000 tasks at once on macOS. A compiler usually emits
*stack probes* instead, touching each page of a large frame in order so
it faults in a small guard; Zig emits none on arm64 macOS. Rig will emit
its own, from the frame sizes it already measures, and then guards of
64 KiB let millions of tasks run at once (increment 7).

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
waiting would hold its worker. The compiler counts down at each outer
loop's back edge and at each recursive function's entry, in programs
that make tasks, and yields when the count runs out; the check never
fails.

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
5. **Yield checks** in the compiler.
6. **The default**: every program that makes tasks runs on the
   scheduler, and the `Threaded` path goes.
7. **Rig's own stack probes**, and 64 KiB guards, before step 5's
   servers with many connections.

Each must not make `bench/tasks` slower on the benchmarks it touches;
the step is done when `spawn`, `chain`, and `yield` are each within 1.2x
of Tokio's time on the Mac (arm64) and on pup (x86_64).
