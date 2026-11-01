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
  never blocks on another process; every `std.file` call that may wait
  does so. A read of a regular file and the calls that only look at a
  path (`exists`, `stat`, `realpath`, `read_dir`) run in the task, on
  its worker: on a local disk each takes less than the pool's two
  wakes, and none can wait on a writer or a device. The read looks at
  the path, opens a regular file with O_NONBLOCK, and reads it only if
  the descriptor's own stat says regular; anything else is opened on the
  pool, so no FIFO is opened twice. `rig.blockingStop` makes
  such a call a fallible waiting point: a cancel or the task's deadline
  ends the wait, and the call runs on to its end on its thread, which
  drops its result, unless it waits in a system call that its waiter's
  wake ends ("Waiting", below); its arguments live in the call's own
  state, a byte slice among them copied, so nothing it reads is freed under it; an
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
  next" slot keeps a just-woken task in cache, at most 3 in a row.
  Filling the slot wakes no worker (`sched.wake`); the task it pushes
  out to the ring does, when none is looking. A worker runs the task
  next when it woke the task itself: from its poller or a timer as it
  looks for work, at a task's end, or at a yield check, which then
  yields to it. A task that wakes another and goes on running either
  stops soon, as one that sends and waits for the answer does, or
  reaches a yield check, loop or recursive, which hands the woken task
  on (`sched.waiting`). So two tasks that answer each other, over a
  socket or a channel, stay on one worker with no system call to wake
  another; a chain of tasks each made and waited for at once runs by
  handoff on its maker's worker; and fork-join (`t = f()&; g(); >t`)
  spreads at `g`'s first yield check, where `g` yields to `f` and a
  worker woken for `g` takes it. A worker with nothing else to steal
  also takes a task left in another's slot 3 µs (`sched.stealNext`), as
  Go takes a `runnext`. A global queue takes overflow and work from
  outside the workers.
- **Cache lines.** Each worker begins a cache line and fills whole
  lines, so no line holds two workers' fields, and the fields each
  writes at every switch never slow another's (`sched.Worker`).
- **Cheap until it runs.** A task gets its stack when it first runs,
  from the worker that runs it. A waiter whose task has not started and
  is next on its worker hands the worker straight to it, on the task's
  own stack, and the task switches straight back when it ends, past the
  queues (`sched.handoff`). Running the task on the waiter's own stack
  would be faster still, but is safe only for a task whose stack use is
  proven to fit, which Rig does not prove.
- **Idle workers** steal from a random victim, at most half of them
  searching at once; one that finds work wakes one more; workers with no
  work sleep in their poller (below). A worker about to sleep lists
  itself as asleep, then, when none searches, looks once more at the
  global queue and every ring; one that finds work there counts itself
  as searching again, so taking it wakes another for the rest
  (`sched.sleep`, checked in formal/Models/Sleep.lean as `relook`).

## Stacks

A task's stack is 64 MiB of address space, as `main`'s is, since a
frame may keep up to 13 MiB of values, committed only as the task
touches it. Stacks never move, since loans point into them. They are
carved 16 at a time from one reservation, whose stacks stay untouched,
holding no page, until a task runs on each; each worker keeps up to 64
that tasks have ended on for the next, returning more to the system.
A task that waits on another task or an actor touches little of its
stack: `sched.block` reserves under a page, and its deadlock walk, which
few waits run, has a frame of its own (`walkFrom`, about 15 KiB). Each
thread's alternate signal stack, on which a fault's handler runs, is a
mapping of its own, untouched until a signal runs on it (`rt.AltStack`):
the root turns off Zig's, a 256 KiB thread-local array every worker and
pool thread would keep resident (`test/cli/thread_memory.sh`).

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
A cancel passes only down: a waiter takes none from the task it waits
on, so canceling the tasks it owns (`par.map`'s helpers after a
failure) leaves its own `Control` as it was.

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
calls look at the flag then; Zig's own calls would only restart. Every
retry of a blocking system call in the runtime and std asks one helper,
`rt.checkStop`, whether the task is canceled or past its deadline:
`tasks.sleepHere`, `net.waitFor` and the socket and file reads and
writes, and std.file's opens, reads, and writes, which make their own
system calls for that reason.

A deadline has no handler to wake a system call, so a blocking call
makes one. With no scheduler, `rt.blockingStop` under a deadline sets
an alarm (`ITIMER_REAL`, SIGALRM, whose handler does nothing and is
installed without `SA_RESTART`) to fire at the deadline and every 10 ms
after until the call returns; the repeat wakes a call the first signal
reached just before it entered the kernel. On the scheduler the call
runs on the blocking pool, and a waiter that stops waiting for it, by a
cancel, a deadline, or the interrupt's cancel of `main`, cancels the
call through its thread's `Waker`, a `Control` that thread's task state
points to, and sends that thread SIGALRM (`rt.wakeThread`); the call's
retry loop sees the cancel and ends, its result is dropped, and its
thread goes back to the pool. The thread publishes its waker before it
reads the call's state, and the waiter reads the waker after it marks
the call left, so either the waiter wakes the thread or the call never
runs; the thread does not leave a left call until its waiter has woken
it, so the signal never reaches a thread that has ended. Each retry
loop asks `rt.checkStop` before its first system call too, so a wake
lands unseen only in the few instructions between that check and the
call. As the program ends, before its leak check, `rt.finish` waits
for every left call to end and drop what it holds (`Pool.left_calls`,
`sched.settleLeftCalls`), waking the threads still running one each
millisecond (`Pool.wakers`), for up to a second. The second
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
  yields. A turn is counted as it ends and the next begins, in a Zig
  `while`'s continue expression, so a turn that leaves its loop counts
  nothing: a probe of a `Map` that finds its key at once, or a scan
  that returns at its first element, pays no check. Zig's own `for`,
  which has no continue expression, counts as each turn's body starts. The task yields when work waits for its worker (in its "run
  next" slot, its ring, or the global queue) or for another busy one
  (the flag below).
- **Recursion.** Every cycle of calls passes through a function that
  starts by reading one flag, `sched.waiting`, on a cache line of its
  own. The compiler picks those functions once, as a feedback vertex
  set of the program's calls (`inlining.Pass.cutCycles`): every
  function that calls itself, then, while cycles remain among the
  rest, the largest function on one, since a large body runs longest
  each call and so checks least often; a function picked whose cycles
  the others' checks already cover is dropped. Each instance of a
  function whose compile-time parameters are all values is a function
  of its own there, calling what its values leave it: a call in an
  `if` branch its values rule out is no call, so `at[true]` calling
  `at[false]`, whose own call of `at` is under `if t`, is no cycle and
  `at` does not check. A function with an instance picked checks in
  all of them, since Zig writes one function for them all; one whose
  instances are not all known (a compile-time argument the compiler
  does not compute, a call by name) is one function, as before. So a task that
  recurses reaches a check on every turn of any cycle, and between
  two checks it makes at most one chain of calls that repeats no
  function. In Trig's checker 387 of the 2,812 functions on cycles
  check, and they take under a third of the calls a check in every
  one of them did. Work woken or made while every worker is busy sets it, and so
  does a fiber that fills its worker's "run next" slot and runs on. The
  first check to see it clears it and yields to that work: its own
  worker's, or half of another busy worker's ring, stolen. A worker
  that finds no work and sleeps clears it too. The flag is one bit for
  many notices, and a fiber in a slot is seen by no sleeper and by its
  maker's recursive checks only through it, so whoever clears it, a
  check or a sleeper, sets it again while any other worker's slot holds
  a fiber (`sched.takeWaiting`). Four accesses make that handshake, all
  sequentially consistent: the clearer's swap of the flag to 0 and its
  reads of the slots after it, and the maker's swap into its slot and
  its read of the flag after that. So the clearer sees the fiber, or
  the maker sees the flag clear and sets it (the stores that set it
  need no stronger order). A task that yields only puts itself back in
  line, so it never sets the flag, and busy tasks do not keep yielding
  to each other.

**A check costs the code around it no registers.** In an optimized
build for x86_64 (System V) or aarch64, both checks call the scheduler
through a function that saves every register a call may change,
calls it, and restores them (`rig.callKeeping`, `Keeping`): the
integer registers, and every vector register the target has. A plain
call, rare as it is, made the code around it keep each value live
across the check in a register a call preserves, saved on entry and
restored on return, or on the stack: a small function with a search
loop saved and restored four registers on every call on x86_64, six on
aarch64, and now saves none. The `asm` that
makes the call steps over the red zone and still tells LLVM that the
call may read and write any memory, as it may, since other tasks run;
it changes only which registers survive it. A debug build, and any
other target, calls the scheduler plainly.

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

The loop check costs a decrement and a branch per turn of any loop
after its first: within noise on `bench/tasks`. The recursion check is
a load and a branch per call of a function that checks: free in any
function that does work, but a function as small as `fib` runs about
1.5x slower with it. On Trig (ts-pattern, one checker, on pup) the two
take 5% fewer instructions than a check in every turn and every
function on a cycle did, and the run is 2% faster.

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
   `std.file`'s calls that may wait go through.
5. **Yield checks**: a countdown in each outermost loop, and a flag
   read on entry to the functions that cut every cycle of calls, in
   programs that make tasks (above).
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
   fiber waits for that (`sched.waitReady`). An end is readiness only
   for the waits it ends: the end of reading (the other end's
   half-close, EOF on kqueue's read filter or RDHUP) wakes the reader,
   the end of writing (this side's half-close, EOF on the write filter)
   the writer, and a hang-up or failure both, so a split stream's
   reader sleeps on after its writer closes. A wait spends from a budget of
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

11. **Fork-join in parallel, and partners on one worker**: every loop's
    turns count toward a yield check, and a task left in a busy worker's
    run-next slot is handed on at its maker's next yield check, so
    `t = f()&; g(); >t` runs `f` and `g` at once
    (`test/cli/sched_forkjoin.sh`); filling the slot wakes no worker, so
    two tasks that answer each other over a socket stay on one worker
    (the unit test "two tasks that answer each other over a socket stay
    on one worker").

12. **Every poller watched, and the pool's threads counted**: while a
    worker that does not sleep holds descriptors, one sleeping worker at
    a time watches every poller (`sched.sleepIn`): it sleeps at most
    1 ms, and as it wakes looks at every worker's poller, so a busy
    worker's sockets wait no longer than that even when its own yield
    checks do not come (in recursion, say), and it passes the watch on
    as it goes back to work. It keeps the watch from one look to the next
    while such a worker is awake or has slept since the watch began, and
    lets it go only once every one has slept through a whole watch, so a
    worker that sleeps and wakes many times a millisecond, as one
    answering a socket does, finds the watch held and kicks no one. A
    look at another worker's poller leaves the kick it finds there, which
    that worker, about to sleep, needs. The
    blocking pool counts a thread busy as it hands it a call, and counts
    a thread on its way back from one (`finishing`), which takes the next
    call queued without sleeping. A call that finds neither starts a
    thread, outside the lock, up to one fewer than the performance cores
    (`soft`: on macOS `hw.perflevel0.physicalcpu`, elsewhere the cores,
    at most 8; at least 2), so a stream of short calls keeps a few threads busy
    rather than waking a sleeping one for each. Past `soft`, a monitor
    thread starts one more each millisecond while the oldest queued call
    has waited that long, up to 64, so calls that block for long (a pipe,
    a slow disk) still run. `RIG_BLOCKING_THREADS` sets both bounds. A
    thread idle 10 s ends; a cancel or a deadline ends a wait on the pool
    (`rig.blockingStop`). A call's thread wakes its waiter before it
    marks the call done, and the waiter that finds it not yet done spins
    64 times, then yields its thread (`sched.poolCall`): on one core the
    wake can preempt the call's thread, which a waiter that only spun
    held off until the kernel took the core back, about 0.6 ms a call
    (2.4 ms a run of Trig pinned to one core).

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
