# Review: PR #904, `rv-tasks` (concurrency runtime, C1-C7, C9, C11, C13, C15, C17-C22)

Reviewed 2026-11-03 at `76cb40e31` (merge base `7cdd87e0b`), Zig 0.17.0,
macOS arm64. Read in full: the diff of `src/sched.zig`, `src/tasks.zig`,
`src/net.zig`, `src/runtime.zig`, `src/emit.zig`, `std/`, the tests, and
the docs; and the unchanged code each change leans on (`Wait`,
`beginWait`/`commitWait`/`interrupt`, `Header`, `Message`, `Poller`,
`finishFiber`/`runFiber`/`releaseStack`, `Isolate`, `selectArms`).

Probes are in `$TMPDIR/rv904/` (built with the branch's `bin/rig`; base
runs with `tools/baseline 7cdd87e0b`). Test areas run, all green:
every concurrency-* area (actor, cancel, chan, deadlock, errors,
isolate, par, sets, supervise, task, wait, within) and std-net, none
died.

## Verdict

One regression must be fixed before merge (R1: C22's stack `Wakeup` in
`task.all` is written after its frame is gone when a waited task
panics). The rest of the waiting rework is sound: I found no lost or
double wakeup in `Waiters`/`sleepOn`, the takeSlot/freeSlot Dekker pair
is correct, `Wakeup.list` is ABA-free, and every slot path frees exactly
once. R2 and R3 are pre-existing holes in the same "nothing left after a
panic" class this PR sets out to close; R2 is a one-line fix that fits
here, R3 is a new finding for the ledger. R4-R7 are small.

| ID | file:line | severity | new? |
|---|---|---|---|
| R1 | src/tasks.zig:508, 370-377 | high | regression (C22) |
| R2 | src/tasks.zig:2258-2259 | medium | pre-existing, C5's sibling |
| R3 | src/tasks.zig:1337-1350; src/sched.zig:2135-2139 | high (soundness) | pre-existing; docs now claim the opposite |
| R4 | docs/design/concurrency.md:639-640, 278-280 | low | new text |
| R5 | src/sched.zig:1220-1236 | low | new (several waiters) |
| R6 | src/tasks.zig:1972-1977 | low (perf) | new (C5) |
| R7 | CHANGELOG.md | low | new |

## R1. `task.all`'s `Wakeup` on the stack is written after a panic leaves the frame (high, regression)

`waitTasksWith` now keeps `var w: Wakeup = .{}` on the stack
(tasks.zig:508), on the grounds that "every task is taken or waited for
before this returns". It is not so on the panic path: `ts[i].job.join()`
(tasks.zig:532) passes a waited task's panic on (`rt.passPanic`), and the
frame is abandoned while the untaken tasks still hold `&w` in their
`Control.wakeup`. Each of them, as it ends, runs `Control.finish`, which
swaps out `&w`, then `w.list(self)` (a CAS on `w.ended_list`) and
`w.tick()` (a `fetchAdd` on `w.ticks`, then a load of `w.waiter` and an
`interrupt` on whatever fiber pointer it finds there).

Two ways the frame is gone first:

1. **The waiter is a task under an isolate.** `panicked` (tasks.zig:1337)
   cancels the isolate's tasks, then `abandon()`s the fiber, and
   `runFiber` releases its stack at once (sched.zig:2135-2139): onto the
   worker's free list, where the next fiber started there reuses it, or
   unmapped once the worker keeps 64. A sibling that does not see the
   cancel at once (a loop without `task.check()`, an infallible wait, an
   actor call that started) ends later and writes into that stack.
2. **The waiter is the isolate's own fiber.** `Control.finish` removes
   the task from the isolate (`iso.remove`, tasks.zig:371) *before* it
   lists and ticks `w` (374-376). The last task's `remove` wakes
   `Isolate.stop(true)`, whose fiber may leave the stack apart
   (`leaveApart`) while that task is still between line 371 and 376.

The same holds at an actor's runner (`abandonDetached`).

**Shown:** probe `allpanic2.rig`: a task under an isolate runs
`task.all(spin(1)&, bad(9)&, spin(2)&)!`, where `spin` computes for a few
ms and `bad` indexes out of bounds. Built from the emitted Zig with
`keep_free = 0` (released stacks unmapped at once) and a print in
`finish`:

```text
panicked frame 705f047400
unmap 705a048000..705f048000
panicked frame 705a043770
finish wakeup 705f0477c0
Segmentation fault at address 0x705f0477c0
```

With the stock runtime the write lands in a recycled stack: silent
corruption of whichever fiber took it, and `interrupt` on a stale word
read as a `*Fiber`. Base keeps the `Wakeup` on the heap and only leaks
it on this path, as a `Tasks` set's `Wakeup` still does.

**Fix:** put the `Wakeup` back on the heap (`Wakeup.create`, destroyed
on the normal paths, leaked on the panic path, as before). R3's fix would
also cover it, but R1 should not wait for R3. A case that catches the
class: R3's suggestion of a sanitizer mode that unmaps released stacks
turns this into a crash under `RIG_SANITIZE=1`, which the runner sets.

## R2. A supervised actor whose remake panics on the runner never answers the message it took (medium, pre-existing)

`runner` takes `m` off the mailbox (`m.started = true`), then remakes a
stale value, and only then sets `self.running = m` (tasks.zig:2258-2259).
A panic in `remake` reaches `kill` with `self.running == null`, so `m` is
answered neither `panicked` nor `died`: its caller waits forever, and a
`&` call's slot is never given back (the leak C5 fixed, by another door).

**Shown:** probe `remake.rig`: a supervised actor whose `make` panics on
its second run; task A holds it inline in a long method, B's call (which
panics, under an isolate) and C's call queue behind. B's panic restarts
the actor with C queued; the new runner takes C, `remake` panics, and C
never returns. Unseeded: hangs until killed. `RIG_SEED=1`: "every task is
waiting on another, and none can run: a deadlock". Same on base.

**Fix:** set `self.running = m` before `if (self.stale) self.remake(...)`
(the runner's own `held.doing` already names the remake). `kill` then
answers `m` as panicked, and frees its slot. Add `remake.rig` as a case
(`seeds: 20`, `timeout: 10`).

## R3. A task under an isolate that panics frees its stack while the tasks it started still read it (high, pre-existing)

This is R1's general form, and a North Star 2 hole in safe Rig. A task
lends its frames to the tasks it starts (`sum(?d)&` reads `d` in place).
When such a task panics under an isolate (not on the isolate's own
fiber), `panicked` cancels the isolate's tasks and `abandon()`s at once;
its stack is released (`runFiber` → `releaseStack`) while its children,
which a cancel need not stop at once, still run and read it. At an
actor's runner, tasks the method started are not even canceled.

**Shown:** probe `lend.rig`:

```text
fun sum(xs: ?[64]Int) -> Int      # 2,000 passes over 64 ones: 128000
fun inner() -> Int
  d: [64]Int = [64 of 1]
  t = sum(?d)&
  x = pick([1, 2, 3], 9)          # panics
  x + >t
```

run as `task.isolate(|| (inner()&) waited)`: every iteration, unseeded
and under `RIG_SEED=1..5`, the child panics with "integer overflow": it
summed a recycled stack. With the `pick` replaced by `0`, it prints
128000. Base behaves the same. `par.map`/`par.each`/`par.workers`
(`parRun`'s `state` and `ctx`, tasks.zig:985-987, 1166) are further
instances.

**Fix (a design item, for the ledger):** a fiber that panics under a
boundary does not give its stack back until the boundary has waited for
its tasks: `abandon` hands the stack to the isolate (a list on
`Isolate`), whose fiber releases those stacks after `stop(true)`
returns; a runner's goes to its actor's death the same way, and a
runner's panic cancels and waits for the tasks its method started. Under
`RIG_SANITIZE=1`, released stacks are unmapped rather than kept
(`keep_free = 0`), so any later write faults. This PR should at least not
claim the opposite (R4).

## R4. concurrency.md claims what does not run (low)

- concurrency.md:639-640, new: "A panic while a boundary stops its
  tasks, in a task it waits for, ends the program." It does not: probe
  `panicstop.rig` (a task whose `time.sleep` fails with the cancel and
  then `panic`s) prints both reports and then "after -9"; the program
  goes on. Neither SPEC §18 nor the code says it ends. Strike the
  paragraph, or say what happens: that panic is reported and the task
  ends where it stands.
- concurrency.md:278-280, rule 4, new: "which cancels and waits for every
  task started under it before the frames those tasks may point into are
  left". True for the isolate's own frames; false for a task's under it
  (R3). Until R3 is fixed, say so, or mark the whole rule *(planned)* for
  tasks under the boundary.

## R5. Several waiters on one direction: a woken waiter can clear an edge meant for another (low)

`waitReady` clears the direction's bit whenever it returns `.ready`
(sched.zig:1220, 1234), and a waiter woken by an earlier edge clears it
whenever it next runs. With several acceptors on one listener: A and B
asleep; edge E1 wakes both; A accepts, loops, gets `EAGAIN`; before A
takes the lock, E2 brings two connections and finds no one listed (B is
already off the list); B now runs, clears E2's bit, accepts one, and
does not accept again; A looks, sees no bit, sleeps. The second
connection waits for the next edge. Not reproduced: 900 rounds of 8
acceptors and of 1+1+1+13 acceptors against 8 and 16 bursts (probes
`acceptN`, `acceptQ`) were all clean; it needs a woken-but-unrun waiter
and a coalesced edge in one window. A server that loops on `accept`
drains it, since `accept` tries the call before waiting.

**Fix, if wanted:** a per-direction generation count bumped on each edge,
read by the caller before its call, and waited on only while unchanged,
instead of a bit cleared by whoever runs next. Or note the limit in
scheduler.md.

## R6. A call made with `&` gives its slot back after it wakes its caller (low, perf)

`Actor.answer` (tasks.zig:1972-1977) answers, then frees the slot. The
woken caller may spawn its next `&` call before the decrement and find
the mailbox full, so with `mailbox: 1` each call in a pipeline sleeps
and is woken once more. Freeing first is safe (`slotted` is read before
either, and the actor outlives both). Worth a `bench/actors` row before
deciding.

## R7. Behavior changes the CHANGELOG does not name (low)

- A deterministic yield check (`sched.tick`) now fires due timers
  (sched.zig:319-322), and `task.check()` yields with the seed's coin
  rather than always: a seeded run's interleavings change, so
  `rig test --seeds` output that depends on timing may change.
- `Tasks[Void]` and `Tasks[Void!]` sets now allocate a `Wakeup` at their
  first `add` (none before, for the infallible one).
- SPEC §18's channel list (SPEC.md:13332) still says only "a later send
  panics"; it should say that a send waiting when the channel closes
  panics in its own task, as the CHANGELOG does.

## Checked and sound

- `sleepOn`: the node is listed and the epoch begun under the caller's
  lock; a waker removes and interrupts under the same lock; the sleeper
  removes itself under the lock before it returns, so no waker touches
  its frame after. A cancel before the wait is caught by the
  `isCanceled` look after `beginWait` (seq_cst on both sides). A waker
  whose `interrupt` loses to a timer still takes the node off, and the
  sleeper then reports "woken": `wakeOne` moves on to the next waiter,
  so no wakeup is lost; the sleeper's callers all look again.
- `takeSlot`/`freeSlot`: `slot_waiting` up then `pending` read, against
  `pending` down then `slot_waiting` read, all seq_cst, with listing
  under `lock`: one side always sees the other. Each slot is freed once
  on every path (inline return, `dieInline`, answer, withdraw, dead
  actor, canceled before the call). `answer` and `freeSlot` are never
  called under the actor's lock.
- `Registration`: lock order poller lock → `r.lock`, never the reverse;
  a woken fiber blocks on `r.lock` until `ready` is done, and
  `deregister` needs the poller lock, so `r` outlives every wake.
- `Isolate.stop(true)` sleeps under `iso.lock` with no lost wakeup
  (`remove` wakes under the same lock when the list empties).
- `Wakeup.list` is a push-only Treiber stack drained by `swap(null)`: no
  ABA; release/acquire covers `next_ended`. `watch`'s CAS against
  `finish`'s swap lists each task exactly once. `dropEnded`'s
  `swapRemove` keeps `index` right, including for an entry later in the
  same drained list.
- `selectArms`, `Chan.close`, `SendArm.finish`: no panic under a channel
  lock; the gave-up CAS is the only exit that can race a claim.
- `panicWith`: no lock held while program code renders the report;
  `lockStderr` is released before `stopPanic`.
- `Poller.remove`'s `tryLock` keeps the `removers` handshake for the
  contended case.

## Probe runs

| probe | unseeded (3 runs) | `RIG_SEED=1..20` |
|---|---|---|
| `accept2` (C1) | 2, 2, 2 | 2 on every seed |
| `actorslot` (C6) | 4, 4, 4 | 4 on every seed |
| `allpanic2` (R1), stock runtime | `4 -9` (silent) | `4 -9` |
| `allpanic2`, stacks unmapped on release | SIGSEGV in `finish` | n/a |
| `remake` (R2) | hangs (base too) | deadlock panic |
| `lend` (R3) | child reads a recycled stack (base too) | same, seeds 1-5 |
| `panicstop` (R4) | program goes on | n/a |
| `acceptN`, `acceptQ` (R5) | 0 bad of 300 rounds, x3 each | n/a |
