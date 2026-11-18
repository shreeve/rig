# sched.zig soundness review: sleep/wake, poller registration, run-next slots

Checkout: `/Users/shreeve/Data/Code/worktrees/rig/http-review`, main at a1742e713.
Scope: `src/sched.zig`, multi-worker path only. Read-only: nothing was built or
run, so every finding is a trace through the code, not a reproduction.
Line numbers are `src/sched.zig` unless a file is named.

Summary: no lost wakeup of a ready fiber in a ring or the global queue, no
double run, no use of a freed `Registration`, no memory-order mistake in a
Dekker pair, and no ABA on the slots were found. What was found is one class
of gap, three times: a duty that one sleeping worker holds for the others (a
deadline, the watch over the pollers, a fiber in a slot) is handed to it once
and is not handed on when that worker leaves its sleep. The scheduler's own
docs promise the cover in each case.

---

## F1. A timer's cover by "a sleeper that wakes by then" lapses when that sleeper leaves its sleep

Severity: medium. A timed wait (`time.sleep`, a wait with a deadline, an HTTP
connection's `Deadline`) overshoots with no bound from the scheduler while
workers sleep idle. Builds with yield checks; a preempted build's monitor
covers the plain case (`serviceDue`, 1405) when the worker is in program code.

Where: `kickForTimer` 2169-2178, `Timers.earlier` 1911-1914, `sleep`
4271-4305 (`sleep_due` at 4274-4276, 4287), `leaveWait` 4312-4319.

The stated argument (2162-2168, docs/internals/scheduler.md 737-743): a busy
worker fires only its own heap (`serviceBusy` 575, `service` 2884), a
recursive call's check fires nothing (`rt.tickCall`, runtime.zig 454, reads
only `waiting`), so such a worker "leaves its timers to the workers that
sleep"; and a timer earlier than any sleeper's wake kicks one sleeper, by a
seq_cst store/load pair on `Timers.due` and `sleep_due`.

Why it does not hold: the pair is sound at the moment the timer is set, but
`kickForTimer` returns as soon as it finds one sleeper with
`sleep_due <= due` (2174), and kicks only the first late one (2175-2177).
Nothing re-establishes the cover when that one sleeper stops sleeping: `sleep`
stores `awake` (4287) and returns, and `leaveWait` passes on only the watch.

Interleaving (workers X, A, S; no preemption):

1. A and S sleep with no timer anywhere: `A.sleep_due = S.sleep_due = no_due`
   (4274-4276), both blocked in `poll(null)`.
2. On X a fiber parks with a deadline T1: `fallAsleep` 1563 -> `Timers.add` ->
   `earlier` -> `kickForTimer(T1)`. A is the first late sleeper: A is kicked,
   S is not.
3. A wakes, loops, stores `sleep_due = T1`, waits until T1. S still has
   `no_due` and no timeout.
4. Before T1, A leaves its sleep. Either way is ordinary:
   a. `notify` pops A (4214) for work made anywhere; A sees `woken`, exits the
      loop, steals the work and runs it; or
   b. A's own `serviceAll` (4272) finds fibers (an earlier timer's, or events
      on a busy worker's poller), so `hasOwnWork` is true and A returns at
      4303-4304. In this variant A may never have stored a `sleep_due` at all.
5. X now runs a fiber with no loop check (recursion, or a long call), A runs
   its work. At T1: X's heap is looked at by no one; S sleeps for good.
   The timer fires only when X's fiber reaches a loop check or stops, or when
   any worker next enters `sleep` (`serviceAll`).

A two-timer form needs no luck with the sleepers' order: X's heap holds t0
(T0) and t1 (T1 > T0). Setting t0 kicked A; setting t1 kicked no one, since it
is not first in its heap (1913). At T0 A fires t0, takes its fiber, and runs
it past T1. t1 is uncovered while S sleeps.

The same lapse reaches a sleeping worker's own heap through `Deadline.cover`
(2084-2085): the timer stays in the heap it was first set in, "wherever the
fiber runs since", so a connection fiber running on C inserts into sleeping
X's heap. If `kickForTimer` then finds A with `sleep_due <= T1` it does not
kick X, whose own `sleep_due` is later or `no_due`; when A leaves early, the
connection's idle or read deadline is held by a heap whose owner sleeps past
it. An HTTP server heals this quickly under load (any event wakes X, any
worker going to sleep fires every heap), but a quiet server beside long
computations does not.

Suggested fix (either, both cheap beside a sleep's system calls):
- On every exit from the wait in `sleep` (beside `leaveWait`), after
  `sleep_due` is `awake`: `const d = earliestDue(); if (d != no_due)
  kickForTimer(d);`. The pair stays sound: a setter that saw this worker's
  old `sleep_due` published its deadline before this worker's read.
- And for `Deadline`: when the insert is into another worker's heap, kick
  that heap's owner if it sleeps later than the deadline
  (`@fieldParentPtr("timers", t)`), or set a timer that is out of every heap
  in the running worker's heap instead of the first one's.

A test: N >= 3 workers, a task that naps 5 ms and then recurses for a second,
a task that naps 10 ms and records when it woke, both parked on a worker that
then recurses; assert the second woke within a few ms.

Confidence: CONFIRMED by trace (not run).

---

## F2. The watch over the pollers is dropped when the kicked sleeper leaves without watching, and is never set up by a registration

Severity: low to medium. Latency only, bounded by the busy fibers' own stops,
but it breaks the documented 1 ms bound (2469-2478; scheduler.md 160-170:
"so a busy worker's sockets wait no longer than that even when its own yield
checks do not come (in recursion, say)").

Where: `leaveWait` 4312-4319, `passWatch` 2550-2557, `sleepIn` 2533-2544,
`Poller.add` 2296, `registerIn` 2670.

The stated argument (2529-2532): a worker that wakes marks itself awake, then
looks for a watcher; the watcher lets go, then reads `idle`; all seq_cst, so
either the waker kicks a sleeper or the watcher sees it awake. That pair is
sound. The gap is after it: `passWatch` kicks one sleeper once, and that
sleeper takes the watch only if it reaches `sleepIn`.

a. Interleaving (B holds descriptors; C and A hold none; C is top of
   `sleepers`):
   1. All asleep, `watcher == null`. An event wakes B; `leaveWait(B)`:
      `idle = 0`, no watcher, `passWatch(B)` kicks C (2556).
   2. C wakes, loops, `serviceAll` (4272) looks at B's poller and finds the
      next connection's event (or a due timer), so `hasOwnWork(C)` is true and
      C returns at 4303-4304 without calling `sleepIn`. `leaveWait(C)`: C does
      not hold the watch and holds no descriptors, so it passes nothing
      (4315). The same happens if `notify` pops C first, or C leaves by the
      last look at 4244-4253, which has no `leaveWait` at all.
   3. B and C run fibers with no loop check. A sleeps with no timeout and no
      watch. Events on B's poller wait until B or C stops.
   Under HTTP load step 2 is the usual case, since the kicked sleeper's first
   look is at the busy accepting worker's poller.

b. A busy worker whose `poller.count` goes from 0 to 1 (`Poller.add`) kicks no
   one. Sleepers that judged `watchWanted` false while its count was 0 stay in
   waits with no timeout. No worker watches until that worker next sleeps and
   wakes.

Suggested fix: in `leaveWait`, pass the watch whenever no worker holds it and
a busy worker holds descriptors, whatever the leaver holds: drop the
`held or w.poller.count != 0` condition around `passWatch` (keep it for the
early `idle = 0`), and call `leaveWait` on the 4249 path too. For (b), have
`registerIn` call `passWatch` when its worker's count was 0 and
`watcher == null`.

Confidence: CONFIRMED by trace (not run).

---

## F3. A fiber put in a slot quietly, whose worker then runs another fiber, is in no one's sight in a build with yield checks

Severity: low. A ready fiber waits behind a fiber with no loop check while a
worker sleeps; bounded by that fiber's stop. formal/Models/Sleep.lean's header
names the hole and gives the monitor as its only cover; a build with yield
checks has no monitor, and the recursion check does not see it.

Where: `wakeIn` 379 (returns before `waiting` is set when
`w.current == null`), `spread` 4032-4036, `notify` 4212, `hasWork` 4389-4393,
`takeWaiting` 4331, `rt.tickCall` (runtime.zig 454).

Interleaving (workers W and S):
1. S searches, has looked at W's slots (`stealNext`, empty), and has not yet
   stopped counting itself.
2. W, between fibers (`w.current == null`), gets a fiber f in a slot with no
   notice: a batch's first from `service` at a 61st turn (4075), or one of two
   fibers a task's end or an `After` wakes. `waiting` is not set (379).
3. W runs a different fiber g: `global.pop()` at 4076, or the newer of two
   slots. `spread` -> `notify` returns at once: `searching != 0` (4212).
4. S finds nothing, uncounts itself, sleeps: `takeWaiting` returns at 4331
   (flag clear), `hasWork` reads no slot. S sleeps.
5. g's loop checks would see the slot (`hasOwnWork`), but g only recurses:
   `tickCall` reads `waiting == 0`. f waits for g to stop while S sleeps.

Suggested fix: in `spread`, when a slot holds a fiber, set `waiting` if clear
(one load on that path). Then S's `takeWaiting` re-sets it for the slot, or
g's recursion check takes the notice and `leftToIdle` wakes S.

Confidence: PLAUSIBLE (each step read in the code; needs global-queue work at
a 61st turn or a double quiet wake, and a recursion-only fiber).

---

## Hardening, not reachable today

H1. `Poller.add` on kqueue (2285-2290) passes two changes with room for no
events. kevent stops at the first change that fails, so if the read filter is
added and the write filter is refused, `add` returns false, `registerIn` frees
`r` (2676), and the read knote stays with `udata` pointing at freed memory; the
next read event calls `r.ready` on it. Only sockets are registered
(`net.watch`), and a socket takes both filters, so this needs ENOMEM today; a
pipe whose other end has closed refuses the write filter (EPIPE), so it
becomes real the day a pipe is registered (the tests already register pipes).
`remove` (2312-2317) has the mirror: a failed read delete skips the write
delete. Fix: on a failed add, send both deletes before returning; or pass
`EV_RECEIPT` with room for two receipts.

H2. `notify` may pop a worker that is inside `trimIdle` (4295-4297; it stays
listed). It is then the counted searcher, so every other `notify` returns at
4212 until its trim ends, though other workers sleep. Bounded by one trim.
The docs record the poller side of this, not this one.

---

## Checked and found sound

- Sleep and wake for ring and global work: the maker's push then its reads of
  `searching` and `sleepers.count`, against the sleeper's listing then its
  reads of `searching` and `hasWork`, are all seq_cst; the last searcher
  re-looks in `sleep` (4244) or wakes another (`workPending`, 3997).
  `hasOwnWork`'s monotonic load of `global.count` in the sleep loop is not
  load-bearing: the last-look and last-searcher checks cover the global queue.
- `woken`: cleared before the worker is listed; a waker pops it only while
  listed; every exit after a failed `sleepers.remove` waits in `waitWoken`.
  `w.searching`, written by the waker before `woken`, is read only after it.
- `Poller.kick` / `kicked`: every condition is set before its kick and
  re-read after the wait clears `kicked`. Checked: a kick between
  `kicked.store(false)` and the eventfd drain on Linux (the flag stands, the
  next wait only looks); a look taking the event; two kicks merged into one
  event; a kick absorbed by a wake in progress.
- `removers`: the owner never blocks while one waits; a remover's kick
  either precedes the owner's `kicked.swap(false)` (it only looks) or follows
  it (its event ends the wait). No lock is held across it.
- `Registration`: `ready` runs only under the poller's lock, `remove` takes
  that lock before the kernel delete and `deregister` frees after, so no event
  carries a freed pointer. `waiting`/`seen` is a seq_cst pair on both sides.
  `short_not_empty` (monotonic) is published by the seq_cst add to `seen`.
  `drained`/`readCame` hold for stream sockets, the only kind registered.
- `pinned`/`idle` (`wakeHome` against `sleep`, and the trim's re-idle): seq_cst
  pair on both sides.
- Slots: every write of a slot is a swap or compare-and-swap whose old value
  is taken, so no fiber is lost or run twice. A thief's delayed
  compare-and-swap that succeeds after the fiber left and came back takes a
  fiber that is ready in that slot: harmless. `handoff`'s `sp == 0` test
  cannot go stale, since only the worker's own thread refills its slots.
- `Batch`: opened and closed only on the worker's own stack with no fiber
  running; the rest of a quiet batch is in the ring, which `spread` and the
  last look see.
- `takeWaiting` against `wakeIn`: slot swap then `waiting` load, against
  `waiting` swap then slot loads, all seq_cst.

---

## Dead or duplicated code in scope

- `Timers.fire`'s own `beginBatch`/`endBatch` (1930-1932): every caller on the
  multi-worker path already holds a batch (`serviceBusy` 581, `service` 2886,
  `serviceAll` 2898); the deterministic caller never reads it.
- `park` and `parkApart` (3585-3589): no caller. `parkIn` (3591) is `stopIn`
  under another name, called once (1554).
- `wakeLast` and `wakeLastApart` (420-426): no caller; only `wakeLastIn` is
  used. `stop`/`stopApart` (3595-3601): one caller, a test (8675).
- `stealNext` (4153) and `takeNext` (4178) differ only in the 3 µs wait.
- `nextHolds` (1476): a one-line wrapper with one caller.
- `notifyNew` then `notify` reads `searching` and `sleepers.count` twice each.
- `leaveWait` (4313-4314) and `sleepIn` (2535-2536) repeat the watch release.
- Five near-copies of "is there work": `hasOwnWork` 676, `queuedHere` 1393,
  `othersWait` 669, `workPending` 4381, `hasWork` 4389, each with its own
  subset and orders; F3 sits in the difference between two of them.

---

## formal/Models/Sleep.lean against the code (not an audit)

- Not modeled, as its header says: timers (`sleep_due`, `kickForTimer`), the
  watch, the trim, `waiting`, a running fiber's fill of its slot. F1 and F2
  are wholly in the unmodeled part; F3 is the hole the header names, which the
  model closes only with `Config.monitor`.
- `kicked` in the model is one flag only the owner's poll takes. The code has
  the flag and a kernel event, looks by other workers that take the event and
  leave the flag, and kicks from timers, removers, the watch and interrupts.
- The model's fiber makes work into its ring; the code's `wake` fills a slot
  and tells no one.
- `sleep` in the code clears `waiting` and counts `slept` before it lists
  itself, and `loop` trims spare stacks between uncounting and sleeping; the
  model goes straight from `.none` to `.clearWoken`.
- `stealNext` is one step in the model; the code reads the slot, waits 3 µs,
  and compare-and-swaps the pointer it read.
- A listed worker in the code may be out of its poller (trimming); in the
  model a listed worker past its last look is in `.checkWoken`..`.poll`.
