# The socket-pair scheduler test under load (2026-11-15)

The backlog item: `src/sched.zig`'s "two tasks that answer each other
over a socket stay on one worker" counted the answers a side read on a
worker other than the one that wrote them and expected fewer than
trips/4 (500 of 4,000 reads). On pup, with another release build's load,
`zig build test -Doptimize=debug` failed it in 3 of 4 runs (2026-10-27);
safe and fast passed.

## Method

The test was instrumented, uncommitted: each wake recorded which look
at a poller woke the side (a worker's own look before it sleeps, its
look at another worker's poller then, its blocking sleep in its own
poller, the watcher's look, the busy worker's look every 61 turns or at
a yield check), whether the side was then taken from that worker (a
`stealNext`, `takeNext`, or ring steal), how many sleepers `notify`
woke, and how many sleeping workers turned searching. A read with no
wait was marked as such. Runs on the Mac (10 cores, already at load 6
to 9 from other sessions), debug unless said, through `tools/heavy`;
load from bounded hogs (`nice`, `timeout`).

Both descriptors are registered by `main`, on worker 0, so every event
lands in worker 0's poller; worker 1 sees one only by looking at that
poller.

## What moves the pair

| Run | Crossings of 4,000 | Longest run of crossings | By path |
|---|---|---|---|
| debug, no added load (20 runs) | 12-34 | 2-4 | half the watcher's look at worker 0's poller, half worker 0's blocking sleep in its poller taking the side back; a few looks by worker 1 going to sleep |
| debug, 14 hogs at nice 20 | 16-54 | 2 | the same |
| debug, 12 hogs at nice 5 | 8-70 | 2 | the same |
| ReleaseSafe | 18-22 | 2-4 | the same |
| debug, 10 µs of work after each send | 2,421-3,306 (fails) | 542-1,352 | the two workers' looks as they go to sleep, about equally |
| debug, 30 µs after each send | 3,218-3,672 (fails) | 544-1,220 | the same |
| debug, 20-100 µs before each send | 52-128 | 2-6 | as without |

In every run: no side was taken from another worker's slot or ring,
`notify` woke no worker, and no sleeping worker turned searching. No
wake moved the pair; the poller looks did.

A crossing without added work is an excursion of two: the watcher looks
at worker 0's poller while worker 0 is between its side's send and its
own look, wakes the other side onto itself, and that side's answer then
wakes worker 0 in its poller, which takes the side back.

With work after a send the pair splits and stays split: while one side
computes after its send, the other worker, its side just gone to wait,
looks at worker 0's poller as it goes to sleep and finds the answer;
each worker then finds the answer for the side it already runs. That
placement is right for such tasks: the runs were faster split (41-49 ms
for 2,000 trips with 40 ms of work in all) than the pair takes on one
worker without the work (33 ms). The path a side takes after its send in
a debug build (its failed read, the switch, the worker's loop, its
search, the start of its sleep) is that work: slow code between a send
and the worker's own look. That is why debug failed where safe and fast
passed under the same load, with the scheduler's code the same. The Mac
did not reproduce the pup failure at the debug build's own speed; the
forced 10 µs window did. The instrumented test, built for x86-64 Linux,
can show the counts on pup.

## Decision

The test asserted a timing property: which worker looks first. The wake
itself is what holds regardless: it leaves the side in the waking
worker's run-next slot and wakes no worker. The test now counts that,
through a test-only hook in `wakeIn` (`WakeCount`, `countWake`,
`countQuiet`, and a check in `Poller.kick` for a kick made during a
counted wake), compiled only in tests: every wake of either side must
fill the waking worker's slot quietly (no fiber displaced to wake a
worker for, no `waiting` notice, no poller kicked), and there must be
some (about 3,990 a run). Checked against two mutations: `notify()` on
every wake failed it (1,368 of 3,998 quiet), and a wake to the ring with
`notifyNew` failed it (0 of 3,981). With 10 µs of work after each send,
where the old test failed, it passes (3,952-3,989 wakes, all quiet). No
scheduler behavior changed.

## The class

An audit of every unit test in src/sched.zig, src/tasks.zig, src/net.zig,
src/runtime.zig, and src/alloc.zig for timing or placement asserts.
Fixed:

- A test that leaves work to an idle worker napped 20 ms and assumed the
  other worker slept by then; a worker just started may not have
  (8 tests). They now nap until every other worker sleeps
  (`testNapUntilOthersSleep`, at most 2 s).
- "a run-next fiber made as the other worker goes to sleep": a round
  missed when the fiber had not run in 50 ms, but once the other worker
  is woken for it, the maker's checks leave it to that worker, which a
  loaded system may not run for that long. A fiber the checks lose never
  runs in the loop, so the bound is 2 s.
- "a fiber waiting on a pipe wakes": the writer napped 2 ms and the test
  needed the reader's first read to find nothing; it now writes once the
  reader has found nothing.
- The blocking pool's tests timed two 100 or 200 ms sleeps against
  180 and 350 ms. They now count the calls inside at once
  (`TestCalls`): 1 at most with one thread, 2 when the pool starts a
  thread or grows. The cancel and deadline test holds its calls until it
  lets them go, so neither ends before its wait does, and waits for the
  call that runs on rather than napping 400 ms; it asserts the wait ended
  no earlier than its deadline. The idle-thread test waits until the
  thread ends (at most 5 s) rather than 300 ms.
- "a fiber that allocates, moves to another worker": it needed some
  worker to steal a fiber that had already run, which four busy workers
  may never do. The moves are now made (`testMove`, pinned to the next
  worker for one yield).
- The full-buffer socket tests: room made by bytes that land after the
  fill is real; the shutdown test fills again and waits again when a
  write gets through, and the close test writes until a write fails
  rather than once.

Judged sound under load: the cancel handshakes (the 2 s and 1 s bounds
are over a thousand times what they wait for), the edge before a
deadline, the timer that wakes a sleeper and the lone worker's checks
(10 ms against 2 s), the fork-join and local-task tests (pass on either
worker, 2 s guards), the watcher's 1 ms look against 2 s, the poller
kick, the seeded socket tests, and the stats test's lower bounds.
src/tasks.zig, src/runtime.zig, and src/alloc.zig assert nothing timed;
src/net.zig has no tests.

## Eight binaries at once

Rig ran the debug test binary of the change above on x86-64 Linux,
oversubscribed (8 at once, pinned to 8 cores, 16 runs each way,
interleaved with main): the pair test passed 48 of 48 (main failed it 1
in 32), but "an idle worker wakes for the descriptors of a busy one"
failed 3 of 48 at its 2 s limit, where main never failed it in 32. That
test registered the pipe, made the reader, and then napped until the
other worker slept, where it had napped 20 ms; with the other worker
listed asleep already it does not nap at all, so whether that worker
watches the busy one's poller came down to timing. Not reproduced on
the Mac: 8 copies of the change's binary at once, 6 rounds, failed none
of 48 there. They failed "a task's maker that computes keeps its worker
while an idle worker runs what it made" once instead.

What changed, in src/sched.zig:

- "an idle worker wakes for the descriptors of a busy one" naps after
  registering until the reader waits (`Registration.waiting`, which the
  reader counts under the lock before it parks, and which the poller
  reads before it wakes one), always at least once: the busy worker
  sleeps holding the descriptor and wakes, which hands a sleeper the
  watch (`passWatch`). It asserts that the other worker was listed
  asleep as the byte was written, and that the reader ran on it; 10 s
  only ends a broken run. The reader does not inherit the pin of the
  fiber that made it: only `spawn`'s `local` sets a fiber's home.
- "a timer set earlier than a sleeping worker's wakes it" asserts the
  same: the other worker asleep once the timer was set, and the napper
  run on it.
- "keeps its worker" and "runs beside it": a check leaves the task to an
  idle worker only while one is asleep or searching (`leftToIdle`); one
  between the end of its search and its sleep is neither, so the check
  yields, and the task runs on its maker's worker or the maker moves.
  Each test now repeats, up to ten rounds, until a round finds the
  other worker asleep and shows the task beside its maker.

Each test fails when the mechanism it names is broken, in a copy of
src/sched.zig built with `zig test src/sched.zig --test-filter NAME`:

| Broken | Test | Result |
|---|---|---|
| `passWatch` returns at once | descriptors | fails, 11 s |
| `sleepIn` never watches | descriptors | fails, 10 s |
| `serviceAll` looks only at its own poller | descriptors | fails, 10 s |
| `kickForTimer` kicks no one | timer | fails, 10 s |
| `leftToIdle` always false | keeps its worker, runs beside it | both fail |

An event log of a variant meant to put the other worker to sleep before
the register found it first sleeping only after: the workers start at
the first `register`, so `testNapUntilOthersSleep` before it returns at
once. From its first sleep it watched every 1.3 ms, and woke for the
byte 0.9 ms after the write.

Runs of the change's whole sched test binary (debug) on the Mac, through
`tools/heavy`: 8 copies at once, 6 rounds, 48 of 48; 20 in a row with 8
CPU hogs at nice 5, 20 of 20. `zig build test -Doptimize=Debug` passes.
