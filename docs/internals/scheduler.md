# The scheduler

How Rig runs tasks fast: the engine under `f(x)&` (docs/design/concurrency.md,
"The engine"), measured against Tokio and Go by `bench/tasks`, whose
`PROGRESS.md` records each step. It is built in increments, each its own
pull request. Every program that makes tasks runs on it, with one worker
per core, or as many as the program asks for with `task.workers(n)`
before its first task, or else `RIG_WORKERS` of them when that is set;
a program that makes none starts no workers.

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
  never blocks; every `std.file` call does so. `rig.blockingStop` makes
  such a call a fallible waiting point: a cancel or the task's deadline
  ends the wait, and the call runs on to its end on its thread, which
  drops its result; its arguments live in the call's own state, a byte
  slice among them copied, so nothing it reads is freed under it; an
  argument it could write through (`[]u8`, `*T`) does not compile, since
  the waiter may leave while it still writes, so it reads into memory it
  owns and returns it. `rig.blocking`'s waiter waits for the call, which
  takes its arguments as they are, a buffer to read into among them. Sockets are registered
  with the workers' pollers and wait there (`net.zig`, increment 8).
  Other system calls go through a `Threaded` instance of Zig's `std.Io`
  (`rt.io`) on the calling thread, which runs no tasks; a write to a
  full pipe holds its worker until it returns.

## Speed

- **One atomic word per task** holds its state and reference count:
  waking is one compare-and-swap, and a task is queued at most once.
- **Queues.** Each worker owns a ring of 256 ready tasks, pushed with
  one store; other workers steal half with one compare-and-swap. A "run
  next" slot keeps a just-woken task in cache, at most 3 in a row. A
  worker with nothing else to steal takes a task left in another's slot
  3 µs (`sched.stealNext`), as Go takes a `runnext`: long enough that a
  task made and waited for at once still runs by handoff on its maker's
  worker, and a task made while its maker computes runs beside it.
  Filling the slot wakes a sleeping worker when none is looking, until
  a worker so woken finds the slot emptied by its owner first, as when
  each task made is waited for at once: from then, until a worker takes
  one, filling the slot sets `sched.waiting` instead, and the maker's
  next yield check hands the task on (`sched.next_quiet`), so a chain of
  tasks pays no system call to wake a worker that finds nothing. A
  global queue takes overflow and work from outside the workers.
- **Cheap until it runs.** A task gets its stack when it first runs,
  from the worker that runs it. A waiter whose task has not started and
  is next on its worker hands the worker straight to it, on the task's
  own stack, and the task switches straight back when it ends, past the
  queues (`sched.handoff`). Running the task on the waiter's own stack
  would be faster still, but is safe only for a task whose stack use is
  proven to fit, which Rig does not prove.
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
and 5.2 KiB on pup's Linux, where Tokio's task holds about 300 bytes and
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

A cancel is a handshake of two steps on each side: the canceler sets the
task's flag and then looks at its wait, and the waiting fiber begins its
wait and then looks at the flag. All four are sequentially consistent,
so at least one side sees the other: a cancel that lands after the
fiber last looked, but before its wait began, finds no wait to end, and
the fiber, looking once more, sees the flag and goes on. Every waiting
point a cancel ends looks so after it begins its wait: a wait on a
task's end, on a set, a select, an actor's answer, a sleep, a
descriptor (`sched.waitReady`), and a handoff to the task waited on.
A poller that wakes a fiber waiting on a descriptor holds that waiter
until it is done (`Registration.Waiter`), so the fiber, which takes
itself back only after, never goes on and ends under it.

An interrupt is a cancel whose canceler is a signal handler, which may
run between any two instructions of any thread and so may not wake a
fiber. A `main` that can fail has a `Control` of its own
(`rt.cancelOnInterrupt`); the handler sets its flag, which is the
first half of the handshake, sets `rt.interrupt_pending`, and kicks
every worker's poller, one system call each. The worker that next
services its poller and timers, awake or woken by the kick, takes the
pending flag and ends `main`'s wait (`sched.deliverInterrupt`), the
second half. A program without the scheduler has one thread: its
handler is installed without `SA_RESTART`, so the system call `main`
blocks in fails with EINTR, and the waiting points that make their own
calls (`tasks.sleepHere`, `net.waitFor` and its reads and writes) look
at the flag then; Zig's own calls would only restart. The second
signal, or a failure out of `main` with the cancel it sent, ends the
process by the signal itself, its default put back (`rt.endBy`), so a
shell sees it end as by the signal.

## Yield checks

A fiber yields only at a waiting point, so a task that computes without
waiting would hold its worker, and the work queued behind it would wait
until it ends. In a program that makes tasks, the compiler adds yield
checks where a computation can run long without waiting. A check never
fails, and yields only when other work waits.

- **Loops.** Each outermost loop keeps a count of turns, a local of its
  own, which it and every loop inside it count down, and every 1,024
  turns of any of them calls the scheduler (`rig.turn`, `sched.tick`).
  So an inner loop that runs long between its outer loop's turns still
  yields. The task yields when work waits for its worker (in its "run
  next" slot, its ring, or the global queue) or for another busy one
  (the flag below).
- **Recursion.** A function on a cycle of calls (`inlining.decide`)
  starts by reading one flag, `sched.waiting`, on a cache line of its
  own. Work woken or made while every worker is busy sets it. The first
  check to see it clears it and yields to that work: its own worker's,
  or half of another busy worker's ring, stolen. A worker that finds no
  work and sleeps clears it too. A task that yields only puts itself
  back in line, so it never sets the flag, and busy tasks do not keep
  yielding to each other.

A loop's check also keeps its worker's timers and descriptors going
while it computes (`sched.serviceBusy`): it wakes the fibers whose
timers are due on its worker, and looks at its worker's poller at most
every 250 µs, a system call. It reads the clock only when its worker
holds a timer or a descriptor. A 10 ms sleep of a task whose worker
spins in `main` takes 10 ms, with one worker or eight, where it waited
for the whole spin; a round trip on a socket registered with that
worker takes about 1 ms, where it took 1.5 s. A recursive call's check
reads only its flag, so a worker deep in recursion leaves its timers to
the workers that sleep.

The loop check costs a decrement and a branch per turn of any loop:
within noise on `bench/tasks`. The recursion check is a load and
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
- **Descriptors.** A fiber waiting on a file descriptor wakes once it
  is ready, at whatever virtual time. With no fiber ready, the poller is
  looked at first. Before the clock jumps to a timer, a run with
  descriptors registered waits, in real time, while any registered
  socket still has bytes its other end has not taken (`SO_NWRITE` on
  macOS, `SIOCOUTQ` on Linux) and they move, then 1 ms more: bytes
  written to a socket may still be on their way, which macOS delivers on
  loopback later, the busier the machine the later, and a jump past a
  wait's deadline would end it spuriously. Bytes that stand still for
  half a second, in a buffer whose reader waits on the clock, do not
  hold it.
- **Deadlock.** With no fiber ready and no timer set, every task waits
  on another, and the program panics.

The same seed makes the same choices, so a run prints the same thing
every time; the suite runs each concurrency case again under seeds 1 to
20 (`seeds: 20`, docs/internals/tests.md).

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
9. **Pinned fibers**: a local task, and the task that makes it, are
   pinned to its worker (`Fiber.home`, `sched.pinHere`). A pinned fiber
   that is ready waits in its worker's pinned queue, never a ring or the
   global queue, so no worker steals it; the worker takes its pinned
   fibers and its ring by turns. A wake from elsewhere queues it at
   home, and kicks the home's poller while that worker sleeps
   (`Worker.idle`).

10. **Busy workers keep their timers and pollers going**: a loop's yield
    check wakes its worker's due timers and looks at its poller (above,
    "Yield checks"). A timer set earlier than any sleeping worker wakes
    kicks one (`sched.kickForTimer`): the timer's worker publishes the
    deadline, then reads when each sleeper wakes, and a worker about to
    sleep notes that it may sleep for good, then reads the deadlines,
    all sequentially consistent, so one of the two sees the other.

11. **Fork-join in parallel**: every loop's turns count toward a yield
    check, and a task left in a busy worker's run-next slot is taken by
    an idle worker, so `t = f()&; g(); >t` runs `f` and `g` at once
    (`test/cli/sched_forkjoin.sh`).

12. **Every poller watched, and the pool's threads counted**: while a
    worker that does not sleep holds descriptors, one sleeping worker at
    a time watches every poller (`sched.sleepIn`): it sleeps at most
    1 ms, and as it wakes looks at every worker's poller, so a busy
    worker's sockets wait no longer than that even when its own yield
    checks do not come (in recursion, say), and it passes the watch on
    as it goes back to work. A look at another worker's poller leaves the
    kick it finds there, which that worker, about to sleep, needs. The
    blocking pool counts a thread busy as it hands it a call, starts
    threads outside its lock, up to `RIG_BLOCKING_THREADS` (64 by
    default), and ends a thread idle 10 s; a cancel or a deadline ends a
    wait on it (`rig.blockingStop`).

13. **Checks of where work runs**: with `RIG_SCHED_STATS=1` set, a
    program prints, as `main` ends, what each worker did, to stderr:

    ```
    rig: worker 0: ran 1203, pinned 1, stole 0, slept 4
    ```

    the fibers it ran (by handoff too), of them pinned ones, the fibers
    it stole, and the times it slept, so a test can check where work ran
    without timing it (`test/cli/sched_stats.sh`). A safe or debug build
    panics when a pinned fiber resumes on a worker other than its home
    (`sched.checkHome`), a load and a branch per switch.

14. **A wait for a mailbox slot counts in deadlock detection**: it
    blocks on the actor as a call does (`tasks.actorSpawn`), so a
    deadlock's walk finds a method waiting for a slot in its own actor's
    mailbox. A wait on channels alone that nothing can end is reported
    in deterministic runs only (above, "Deadlock"): elsewhere an
    interrupt may still end it.

Each increment is held to the gate in `bench/tasks/README.md`
(`bench-tasks --gate`), which fails a benchmark more than 1.5 times
slower than the last recorded row. The
numbers against Tokio and Go are in
[docs/launch/benchmarks.md](../launch/benchmarks.md), and
`bench/tasks/PROGRESS.md` has a row for each increment.
