# The scheduler

How Rig runs tasks fast: the engine under `f(x)&` (docs/CONCURRENCY.md,
"The engine"), measured against Tokio and Go by `bench/tasks`, whose
`PROGRESS.md` records each step. It is built in increments, each its own
pull request; until the last, a program runs on it only when built with
`RIG_SCHEDULER=1` (`__rig_scheduler`), and on Zig's `Threaded` backend
otherwise.

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
- **Cheap until it runs.** A task gets its stack when it first runs; a
  waiter that finds its task not started runs it inline on its own stack
  when there is room.
- **Idle workers** steal from a random victim, at most half of them
  searching at once; one that finds work wakes one more; workers with no
  work sleep on a futex.

## Stacks

A task's stack is carved from one reservation: 64 MiB of address space,
as `main`'s stack has, since a frame may keep up to 13 MiB of values,
committed only as the task touches it, over a 64 KiB guard, with
per-worker free lists. Stacks never move, since loans point into them.
The compiler emits stack probes, so a frame larger than the guard still
faults in it.

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
3. **Stacks**: the reservation, stack probes, and running a waited-for
   task inline.
4. **Waiting without spinning**: futex and timers for fibers,
   cancellation on them, and the blocking pool for the rest of `std.Io`.
5. **Yield checks** in the compiler.
6. **The default**: every program that makes tasks runs on the
   scheduler, and the `Threaded` path goes.

Each must not make `bench/tasks` slower on the benchmarks it touches;
the step is done when `spawn`, `chain`, and `yield` are each within 1.2x
of Tokio's time on the Mac (arm64) and on pup (x86_64).
