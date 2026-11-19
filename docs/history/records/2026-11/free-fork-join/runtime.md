# Free fork-join, the build round: the runtime (expert B)

Read at origin/main ee994781b: src/sched.zig (`Fiber`, `Worker`, `Ring`, `wakeIn`, `spread`,
`handoff`, `Header`, `Done`, `spawnIn`, `prepare`, `fiberMain`, `finishFiber`, `abandon`,
`watchSlices`, `queuedHere`, `workWaits`, `tick`, `next`, `search`, `workPending`, `hasWork`,
`notify`, `block`, `interruptForCancelIn`, `takeStack`, `mapStacks`, `onWorkerStack`), src/tasks.zig
(`Task`, `Control`, `Isolate`, `panicked`, `actorsDie`, `panicStops`, `roomInline`, `Actor.callAs`),
src/runtime.zig (`TaskState`, the program's stack, `passPanicFrom`, `stopPanic`, `panicBoundary`),
src/inlining.zig (`denseDepths`), emit's `spawn` paths; origin/early-start's `startAhead`;
formal/Models/Ring.lean, Sleep.lean, Checks.lean, formal/LambdaRig/Wait.lean; rayon-core 1.13
`join_context`, `WorkerThread::push`, `Sleep::new_internal_jobs`, crossbeam-deque `Worker::pop`,
`Stealer::steal`; the 11-15 round (SYNTHESIS, runtime, semantics, measurement); psum-gap/runtime.md;
docs/internals/scheduler.md; and Expert C's language.md in this folder. I built and timed nothing:
every count of bytes or instructions below is read from the code, and every time is an estimate
for Expert A's ceiling to settle.

## Answers in brief

1. **Recursion.** One rule, exact, and no depth proof: a task runs on its waiter's stack when the
   room left there is at least what its own stack would give it. A large stack reserves the 64 MiB
   SPEC promises plus a headroom `H` of address space (1 MiB), so a waiter that has used no more
   than `H` has a whole task stack left and inlines any task, recursive or not. psum's inline chain
   at 2^25 is 12 levels of about 1 KB, qsort's at 2^22 about 10: both 1% of `H`. Past `H` the wait
   hands off as today, so a stack never runs short. Expert C reached the same rule independently
   (language.md §1, option f); I take its fact (a proven depth per site, else a whole stack) as the
   runtime's `need`.
2. **The queue.** A separate Chase-Lev deque of forks per worker (`Forks`), not the ring with a fork
   kind. The ring's push must be a full fence for the sleep handshake, its thieves take half, its
   newest is taken back only while no woken fiber was pushed after it, and the monitor counts it.
   The deque's push needs no fence on x86, its join takes one (the pop's), thieves take the oldest
   one at a time, and its wake-up is lossy as Rayon's is, recovered at four points. An unstolen fork
   and its join cost one full fence against today's five, no allocation, no stack, and no switch.
3. **Forks and the monitor.** Forks leave the monitor's two-look rule (the 50 µs signals) and stay in
   its slice rule (10 ms). The monitor kicks a sleeper for a fork it sees waiting at two looks, with
   no signal. A yield check yields to its own forks only once the oldest has stayed through 16
   checks. So SPEC's "Taking turns" holds at one worker, which answers C's blocking finding.
4. **The build.** Lean first (Ring with `takeLast`, which no model covers today, then a Deque model,
   Sleep with forks, and the cancel bit), then five runtime commits, each alone measurable and
   revertible: the record in the frame, `S + H` stacks, the inline run on today's queue, the deque,
   the monitor.

## 1. The room rule (question 1)

### What must hold

A task on its own stack has `S` = 64 MiB of room (SPEC §1, §18). Run inline, it must have no less,
or a program that runs today could overflow tomorrow (North Star 1). Each nested `>u` inside the
inline task checks again at its own wait, so the rule must bound only what the task takes between
its entry and its waits. In psum that is the plain recursion `a = psum(xs[..mid])`, which sits
between the fork and the wait and recurses to the leaf, with no wait on the way down. Its depth is
the data's, so no static bound covers it (C's options a to c).

Two facts settle it:
- **The plain chain costs the same bytes either way.** Inline or not, `t`'s plain chain is the same
  frames; only where they start differs. So `t` is safe inline exactly when the room at the start is
  at least the room its own stack would give.
- **A fork tree is shallow in bytes.** Each inline level adds the waiter's frame, the record in it,
  and the runtime's frames between `>t` and `t`'s entry: about 1 KB. Twelve levels are 12 KB.

### The rule

- A large stack reserves `S + H`: `rt.task_stack_size` stays `S` (the promise), and `takeStack` and
  `mapStacks` carve `len = S + H`. `H` = 1 MiB, address space only; no page is touched.
- `roomFor(f, h)`: `stackPointer() - f.state.stack_guard.hi >= need(h)`, read where `runHere` stands
  before it calls the task. `need(h)` is `h.need` when the site has a proven depth (C's `task_depths`
  fact, plus a constant `frame_slack` for `runHere` and the start trampoline), else `S`.
- The waiter's `stack_guard` is never swapped: an overflow still faults in the guard of the stack the
  frames are on.
- A fresh task stack has `S + H` of room. A waiter that has used `u <= H` has at least `S` left, so it
  inlines a task with no bound. A dense stack (1 MiB on the Mac, 256 KiB on Linux) never has `S`
  left: it inlines only a task with a proven `need` that fits, and hands off the rest.
- When the room is short, `runHere` declines before it claims anything, and the wait goes on as
  today: a handoff to the task on a stack of its own, or a park. A stack never runs short, and the
  task always has its 64 MiB.
- An inline task's own forks check again at their waits against the room left, so a deep or fat tree
  hands off once every `H` of chain and inlines below each handoff.

### How much room psum and qsort take inline

From the structs at ee994781b (not measured; A's ceiling should read the stack pointer at a leaf):

| piece | bytes |
|---|---|
| `Fiber` (with `TaskState`, about 128) | about 272 |
| `Header` (`Fiber`, `Done`, `panicked`, `destroy`) | about 304 |
| record `Full` for psum: `Header`, result, `Control`, args (deadline, slice) | about 480 |
| psum's own frame without the record | about 100 |
| `waitInto` + `waitEndIn` + `runHere` (with its `Inline` record, below) | about 300-400 |
| the start trampoline (`Full.start`, `Task.start`'s `run`) | about 100 |
| one inline level | about 1 KB |

- **psum, 2^25 Ints, GRAIN 8,192:** 4,096 leaves, 12 levels: about 12 KB at the deepest leaf.
- **qsort, 2^22 Ints, GRAIN 8,192:** 512 leaves; the values repeat (`% 1000`) and the partition is
  three-way, so about 9 to 10 levels; its frame holds three Lists, so about 1.1 KB a level: about
  11 KB.
- Both are about 1% of `H`. A tree with 64 KB of locals a level would hand off once every 16 levels.

### `main`'s stack

`main`'s stack is mapped in runtime.zig (`mapStack`, 64 MiB under a 64 GiB guard). C's M1 keeps it
at exactly `S`: `main` then never meets `room >= S`, so the spine of plain calls `main` itself walks
hands off once a level (psum 12 handoffs, qsort 9, against today's 4,095 and 4,094), and each handed
fiber inlines its whole subtree. M2 gives `main` `S + H` too and inlines the spine. From the
scheduler's side M1 costs 12 stacks and 24 switches a run, under 0.1 ms; I agree with C's default M1,
with M2 taken only if A measures the spine above 1% of a cold psum.

### Why not the alternatives

- **A proven depth only** (the 11-15 synthesis, item 2): psum and qsort are on cycles, so never.
- **Frame bound times a proven depth:** needs a size-change proof (`log2(len)` for psum); qsort's
  partition is not halving. Out of reach.
- **A room heuristic** (the actor path's quarter of a stack, `tasks.roomInline`): unsound; a method
  that needs 20 MiB overflows inline and succeeds on its own task. This is a live bug of the same
  class; the fix is the same `roomFor` (C §5), its own commit.
- **Twice the stack** (11-15 runtime.md, 128 MiB): sound, but reserves 64 MiB more per stack to buy
  what 1 MiB buys.
- **Split stacks** (continue a recursive call on a new stack when room runs short): exact without
  `H`, but every function on a cycle would pay a stack check in builds preempted by signal, which
  have no checks today, and emit would wrap recursive calls. Rejected.

## 2. `runHere`: running the task on the waiter's stack

### Which fiber runs

One physical fiber: the waiter's. While `t` runs inline, `w.current` stays the waiter's `Fiber`, and
`t`'s own `Fiber` (in its `Header`) is never run. That choice settles everything else:
- `rt.task()` reads `current().state`, so `t`'s code sees its state once it is swapped in;
- a wait in `t` records the physical fiber as the waiter, so whatever ends it resumes `t`'s code;
- a deadlock's walk from any other fiber reaches the physical fiber's `blocked`, which the innermost
  wait publishes;
- the pin and the monitor see one fiber, as with a slot handoff.

The other choice, making `t`'s own `Fiber` current on the waiter's stack, fails on a cancel: the
waiter would sit in a wait a cancel may end, and a cancel would wake it on frames that lie above
`t`'s live ones. In this design the waiter is in no wait at all while `t` runs.

### The functions

- **`Header.waitEndIn`** tries `runHere` first, before `block`, when `deadline == null` and the
  task is unstarted (`h.fiber.sp == 0`). A fallible wait under a deadline never inlines (11-15,
  semantics).
- **`runHere(w, h, cancel) bool`** (new, in sched.zig):
  1. If `cancel` is set, return false (the wait goes on, cancels `t` and waits, as `handoff` does).
  2. `roomFor(f, h)` or return false.
  3. Claim `h`, newest first: `w.forks.popIf(&h.fiber)`, else today's claims, `takeFromNext` or
     `w.ring.takeLast`. A task that is not the newest is not claimed (only the awaited task runs
     inline, never another: 11-15, item 3). On a failed claim, return false.
  4. Push an `Inline` record in its own frame: `parent` (`f.inline_top`), `header`, the waiter's
     saved state, `held` (`f.held`), `home` (`f.home`). Point `h.fiber.host` at `f` (seq_cst, for
     cancels, below). Set `f.inline_top`.
  5. Swap the state: save `control`, `own`, `deadline`, `isolate`, `runner`, `unwinding`,
     `drop_depth`, `print_depth`, and clear them; `stack_guard` stays. A waiter whose `drop_depth`
     is not 0 (a task dropped inside a drop chain) swaps `drop_queue` too, so `t`'s drops run in
     `t`, in order, not queued for after it.
  6. `w.inlined += 1` (`RIG_SCHED_STATS`). The run stays on the waiter's count for the monitor, as
     a slot handoff does, so a fiber that forks and joins is stopped as one that computes when other
     work waits a slice.
  7. Call `h.fiber.run(&h.fiber)`: `Full.start`, `Task.start`'s `run` (which writes `t`'s
     `control`, `own`, `deadline`, `isolate`), the call, `Control.finish`.
  8. Restore the state, `f.home = in.home`, `f.inline_top = in.parent`; return true. `waitEndIn`
     returns true at once: no `Done` store, no `block`, no `unblock`. `Job.taken` reads `panicked`.
- **`Job.free`** skips `destroy` for a frame record (§4).

`runHere` holds no lock and no hold-off when it calls the task, so a signal stops `t`'s code as it
stops any program code: the stop saves the physical fiber's registers below `t`'s frames, and the
fiber may resume on another worker unless pinned, which a stack shared by its frames allows.

### Pin

A pinned waiter keeps its `home` through the run, so `t`, run inline, resumes only there: the
waiter's frames above require it. A `t` that pins the fiber (it makes a local task) is unpinned as
the run ends (`f.home = in.home`): its local tasks have ended with it. A local `t` (made by
`spawnLocal`) is already on its maker's worker, whose fiber the spawn pinned.

### Deadlock's walk

`block` publishes on `current()`, the physical fiber, so the walk sees the innermost wait of the
chain, and every actor the chain holds (`f.held`) names it: they are all suspended under it. No
fiber but `t`'s holder waits on `t`, and the holder is the physical fiber, so no walk reaches `t`'s
unused `Fiber`. The walk itself runs on the worker's stack (`onWorkerStack`), unchanged.

### The monitor and the signal

The monitor sees `w.current` (the physical fiber) and `runs`, which `runHere` does not bump: an
inline chain is one fiber computing. The handler stops it only at a program counter in `rig_text`,
which `runHere`'s own code is not. Nothing new is owed.

### Cancel: a fiber bit and the parent links (11-15, item 5)

- **`Fiber.cancel_below`** (new, atomic): set by `interruptForCancelIn(f)` on `f.host orelse f`,
  before it reads the wait word. `Fiber.host` (new, atomic) is set by `runHere` before `t`'s code
  runs, so a cancel of `t` (its isolate stopping) reaches the physical fiber's present wait, which
  belongs to `t` or to a level below it.
- **`passCancelDown(f)`** (new): called from `beginWait` and `rt.checkStop` when `f.inline_top !=
  null` and the bit is set. It clears the bit, then walks the `Inline` records from the outermost
  in: where a level's waiter is canceled (its saved `control`), it cancels that level's task (sets
  its flag, through `Header.cancel`, a pointer to `Control.canceled` set at spawn), as that waiter's
  `waitInto` would have. Then the wait's own flag check sees it.
- The walk runs only on the fiber itself, over frames that are live above it: no other thread
  walks a chain whose frames the next fork reuses (the 11-15 semantics objection to chain-wide
  flags).
- **Order.** The canceler stores the flag, then the bit, then reads the wait word; the waiter begins
  its wait, then reads its flag and the bit. All seq_cst, so one side sees the other, as the
  four-access handshake today (scheduler.md, "Waiting"); this is the fifth access, and Wait.lean's
  steps on the word do not change.
- A cancel that came before the run began is seen by `waitInto`'s first `canceledHere()`, which
  cancels `t` before running it (`stop`). An actor's method run inline runs under no cancel
  (`control` null), and the walk passes nothing through it, as today.

### Panics: continue in place, one level at a time (11-15, item 4)

No catch point. A panic on a fiber with `inline_top != null` is decided level by level, in one loop
in one frame, so a deep chain takes no stack per level (`sched.endInlineLevels`, called from
`rt.stopPanic` and `tasks.panicked`):

- A boundary on *this level* is an isolate made at this level: `iso.fiber == f` and `iso.at ==
  f.inline_top`. `Isolate` gains `at`, the `inline_top` as it began. The three tests that compare
  `iso.fiber` with the running fiber (`tasks.panicked`, `actorsDie`'s mark, `panicStops`) use it.
- The panic ends the program at a level where today it would: no boundary, as `panicEnds` says.
- With a boundary on this level, it stops there as today (`iso.stop`, `leaveApart`): every inline
  level younger than the isolate has already ended.
- Otherwise the level ends as a task that panicked on its own fiber: the actors it holds since it
  began die (`f.held` down to `in.held`), its `Control` finishes (out of its isolate's list, so
  `Isolate.stop`'s wait ends), its record is marked `panicked`, the waiter's state comes back, and
  the waiter passes the panic on (`passPanicFrom("a task this one waited for panicked")`), next turn
  of the loop.
- When the outermost level abandons (`tasks.panicked` with an isolate on another fiber), the
  physical fiber's stack goes to that isolate, holding every level's frames, and `abandon` marks the
  physical fiber's own `Header`: by then `inline_top` is null, so it is the right one.

Without the level test, a task inlined in an actor's runner would see the runner's isolate as its own
(`iso.fiber == current`) and jump to its `home`, which a runner's isolate never set: the one hazard
the swap creates, closed by `at`.

### Off under `RIG_SEED`

A deterministic run takes the `ready` list at spawn and never calls `runHere`, so a seed chooses the
same. `RIG_WORKERS=1` tests the inline path.

## 3. The queue (question 2)

### A separate deque, not the ring

| | the ring with a fork kind | a fork deque (`Forks`) |
|---|---|---|
| push | `tail` stored seq_cst: a full fence, which the sleep handshake needs for every entry | `bottom` stored release: no fence on x86, `stlr` on the Mac |
| join's take | `takeLast`: only while the fork is the newest; a woken fiber pushed out of a slot after it breaks that | `popIf`: forks alone, so the awaited one is the newest unless the program joins out of order |
| thieves | take half (a deep psum deque gives one thief 63/64 of the work); the `stealing` flag lets one in at a time | take the oldest, one at a time, as Rayon's; no flag |
| owner's take race | the #1157 race lived here (a thief's half against two owner takes) | one CAS on the last fork settles it (Chase-Lev) |
| monitor | in `queuedHere`: 50 µs signals while a fork waits | its own rule (below) |
| stolen bit | a tag the thief reads | set by the thief that adopts it |

Woken fibers and heap tasks keep the slots and the ring, unchanged. Only a task whose record is in
its maker's frame (C's `task_record` fact) is a fork. A local task is not: it stays in its worker's
slots and pinned queue, where no thief looks.

### `Forks`

```zig
const Forks = struct {
    const size = 256;
    slots: [size]std.atomic.Value(?*Fiber),
    top: std.atomic.Value(u32),     // thieves take here, by CAS
    bottom: std.atomic.Value(u32),  // only its owner writes it
};
```

Zig 0.17 has no `@fence`; as the ring does, the store-load order comes from seq_cst accesses:
- **`push(f)`** (the owner, at the fork): `b = bottom` (monotonic), `t = top` (acquire); full when
  `b - t == size`, then the fork goes to today's path (slot and ring, still claimable); else
  `slots[b] = f` (monotonic), `bottom = b + 1` (release). Then the wake check (below).
- **`popIf(f) bool`** (the owner, at the join): `b = bottom - 1`; `slots[b] != f` returns false
  untouched; `bottom = b` (seq_cst); `t = top` (seq_cst). If `t < b`, taken. If `t == b`, CAS `top`
  from `t` to `t + 1` (seq_cst), restore `bottom`, taken when the CAS won. If `t > b`, restore,
  false. On x86 the seq_cst store is the one `xchg`; on the Mac `stlr` then `ldar`, which ARMv8
  orders without a `dmb`.
- **`popNewest() ?*Fiber`** (the owner's loop): the same, for whatever is newest.
- **`steal() ?*Fiber`** (a thief): `t = top` (seq_cst), `b = bottom` (seq_cst); if `t < b`,
  `x = slots[t]` (monotonic, the pointer only, never read through), CAS `top` from `t` to `t + 1`
  (seq_cst); `x` is the thief's only if the CAS won.

Every access to `top` and `bottom` is seq_cst but the push's release store, so the protocol is
sequentially consistent but for that one store, which only delays when a thief sees a new fork:
the Lean model checks the SC interleavings and the release store is argued apart (§5). These are
the orders of Lê, Pop, Cohen and Zappa Nardelli (PPoPP 2013) with the fences folded into the
accesses beside them.

### Waking: lossy, as Rayon's, and recovered

`rayon-core`'s `push` reads its sleep counters after the push with no fence between, and says so:
"under certain race conditions, the function may fail to wake any new threads; in that case the
existing thread should eventually pop the job." A fork has a maker that always reaches its join,
its drop, or a park, so a lost wake costs parallelism for a while, never progress. A store-load
fence on every fork would cost what the deque saves.

- **At the push:** when the deque held another fork already (`b != t`), and a worker sleeps
  (`sleepers.count`) and none searches, `notify()`. Plain loads. A fork pushed onto an empty deque
  wakes no one: a chain (`t = f()&; >t`) never wakes, as a slot fill never does today, and psum's
  second fork wakes the first thief, whose own forks wake the rest.
- **The searcher's `workPending`** and the **sleeper's last look** (`hasWork`) read every deque, so
  a searcher that finds a fork wakes one more while more wait, and a sleeper finds a fork whose push
  it can see.
- **The monitor** (preempted builds and all others alike): a deque whose oldest fork is the same at
  two looks, while a worker sleeps and none searches, gets a sleeper kicked (`notify`), with no
  signal. The period is the short one (50 µs) only while such a fork and a sleeper both exist; with
  every worker busy, forks do not shorten it.
- **A yield check** (`tick`): forks pending with a sleeper and no searcher wake one and run on
  (`leftToIdle`'s rule).

### Taking turns (C's blocking finding)

SPEC §18 promises that a long loop or recursion lets waiting tasks run. A fork is a task. So:
- **The slice counts forks.** `workWaits` reads the deque, so a fiber that runs 10 ms with a fork
  waiting, its own or not, is stopped (preempted builds). The stop puts it in the global queue, and
  `next` takes the worker's own forks (newest first) before the global queue, so the fork runs, on
  its own stack. A maker spinning on a flag its fork sets (C's case 8) goes on after one slice.
- **The two-look rule does not.** `queuedHere` leaves the deque out: a fork-join tree that runs for
  seconds gets no 50 µs signal for its own forks (psum-gap saw 20-55 stops a warm pass).
- **A yield check** treats forks as its worker's work only once the oldest has stayed through 16
  checks (`Worker.fork_seen`, about 16K loop turns); else a psum leaf's loop would yield to its own
  forks every 1,024 turns and undo the inline join.

### Who takes a fork

- **Its maker,** at the join (`popIf`), inline.
- **Its worker's loop,** when the maker parked or was stopped: `next` takes `popNewest` after the
  slots, pinned fibers and ring, before the global queue, and runs it as a fiber on a stack of its
  own. So a maker that waits on a channel for its fork (C's case 7) never hangs.
- **A thief,** in `search`: each victim's ring first (woken fibers, which wait on latency), then its
  deque's oldest. The thief adopts the fork (§4) and sets `TaskState.stolen`, the bit `par`'s
  splitting reads (11-15 measurement, "`par` splits by what is left").

A fork whose maker migrated (it parked on one worker and resumed on another) is not the newest in
the new worker's deque; its join waits, and the old worker's loop or a thief runs it.

### Cost per unstolen fork and join

Read from the code (x86 locked instructions are the full fences; psum has no actors, so `block` and
`unblock` cost nothing):

| | today: spawn, slot, handoff | free fork-join | Rayon `join` |
|---|---|---|---|
| allocation | record from the thread's heap, freed after | none: the record is in the frame | none: `StackJob` on the stack |
| stack | taken, its top written (`initialFrame`), given back | none | none |
| switches | two (each 6 registers saved, 6 restored) | none | none |
| full fences | 5: the slot swap, the slot's take (CAS), `fiberMain`'s mark of the waiter (CAS), `Control.finish`'s store, `finishFiber`'s claim (CAS); a sixth, the ring's push, past four slots | 1: `popIf`'s store of `bottom` (and `Control.finish`'s, kept seq_cst for heap tasks only) | 1: `pop`'s `fence(SeqCst)` |
| other stores | the record, about 480 bytes, every field | about 15 into the record and the args (§4), about 16 saved and restored by the swap, 6 in `Inline` | about 6 |
| per join, measured | 71 ns pup (after #1152), 60 Mac | estimate 15-25 ns | 14 ns pup, 10 Mac |

What remains above Rayon: the state swap, `Control`, and a call into the runtime for the push and
for the join (in a preempted build, `spawn` and `waitEnd` are never inlined into the program's
code). A's ceiling says how much those cost.

## 4. The record in the frame

- **What the slot holds:** today's `Full` (`Job` with `Header` and result, `Control`, args), emitted
  as a frame slot that C's storage fact names, filled by `spawnAt(&slot, ...)`.
- **What the maker writes at the fork:** `run`, `done`, `dense`; `Done.status` running;
  `panicked` false; `need` and `in_frame`; `Header.cancel`; `Control`'s flags, `fiber`, `isolate`;
  the args. About 15 stores and the args. The rest of the `Fiber` (its `TaskState`, `wait`,
  `blocked`, `held`, `budget`, `home`) is written by whoever runs it as a fiber, a thief or the
  owner's loop (`adopt`), and never on the inline path. That keeps 270 bytes of stores off every
  fork.
- **`destroy` does nothing:** `Header.in_frame`, read by `Job.free`, a load and a branch, not an
  indirect call.
- **What `Done` already promises** is what a frame record needs on the stolen path: the waiter goes
  on only once it reads `ended`, and no waker touches the record after. The thief's worker reads
  the fiber's stack before it publishes the end (`runFiber`: `endStack`, then `Header.end`), and a
  deque slot keeps only a pointer no thief reads through without winning its CAS. So the frame may
  go the moment `waitInto` returns.
- **A panic** leaves the maker's frame where it is; an isolate keeps that stack until every task
  under it has ended (today's rule for loans), so a stolen fork's record stays valid.
- **Later, measured:** a fork record of about 64 bytes, its `Fiber` built at the top of the thief's
  stack, as a free stack keeps its link there, and `Header` holding a pointer to it. It would take
  most of the record out of every recursive frame. Not first.

The frame record alone takes psum's 4,095 record allocations off the pass, and with them the
worker heap's first segment, whose huge page faulted inside the cold pass on pup (psum-gap, about
1.2 ms). Draft #1156 removes that fault another way; measure commit 1 with and without it.

## 5. The Lean models, before the code

`formal/Models/Explore.lean` checks sequentially consistent interleavings within bounds. #1157 fixed
a race in `Ring.takeLast` that no model covered: Ring.lean has push, pop and steal, not `takeLast`
or the `stealing` flag. So, in order:

1. **Ring.lean: `takeLast` and `stealing`.** The owner's take of a named newest fiber, the flag's
   read, the restore; the thief's flag. Checks as today (no fiber taken twice, head never past
   tail, none lost). A seeded failure, `noFlag`, is the code before #1157 and must report "a fiber
   was taken twice". It verifies shipped code before anything is built on it.
2. **Deque.lean (new): `Forks`.** The owner's push, `popIf` of a named fork, `popNewest`, and the
   overflow to the ring; thieves' `steal`. Checks: no fork taken twice; no claimed slot empty;
   every pushed fork taken once or left once; `popIf` takes only the named fork. Seeded failures:
   the last fork taken with no CAS; a thief that claims with a plain store; `popIf` that reads `top`
   before it stores `bottom` (the fence missing, written as the reordered steps). A variant with a
   store buffer for the owner (TSO) shows the push's release store is enough and the pop's must be
   seq_cst: with the pop's store made release, TSO lets the load of `top` pass it and a fork is
   taken twice.
3. **Sleep.lean: forks.** A deque per worker; the push's wake check as a step that may read a stale
   count (a lost wake, chosen nondeterministically); `workPending` and the last look reading the
   deques; the monitor's kick at two looks; the slice's stop; `next` taking own forks before the
   global queue. Checks: today's no lost wakeup for rings, slots, pinned and global; for forks, from
   every state some run reaches done, so no fork waits forever, including a maker that spins
   forever at one worker. Seeded failures: no monitor kick with a spinning maker and the thief
   asleep (a fork waits for good); `next` taking the global queue before own forks (the stopped
   maker runs again, its fork never).
4. **The cancel bit.** Wait.lean's steps on the wait word stay; the bit is a fifth access. A small
   explicit-state model (`Models/InlineCancel.lean`): a canceler of any level (flag, bit, wait
   word), the physical fiber in a chain of two or three inline levels beginning and committing waits
   and running `passCancelDown`. Check: a cancel of any level that comes while the innermost sleeps
   in a wait a cancel may end wakes it, and that level's task and every one below are canceled.
   Seeded failure: the bit set after the wait word is read.

test/cli/wait_sync.sh, which ties Wait.lean's numbers to sched.zig, gets the bit's step.

## 6. The commits, in order

Each lands alone, behind its gates, and each reverts alone. Every one keeps level, Mac and pup:
bench/tasks (chain, spawn, fanout, yield, hog, produce, memory), bench/actors, bench/net,
bench/http, Trig's and loco's light gates, std.json's guard, the hash and text guards, and, for a
commit that touches the compiler, `bench/check`'s. Each runtime commit runs `zig build test` on pup
in debug, safe and fast. The new row is C's `bench/fork` (psum, qsort, cold and warm, 1 and all
workers) against Rayon; "moves" below is the share each should take alone.

| # | commit | alone it should move | watch |
|---|---|---|---|
| 0 | Lean: Ring `takeLast`, Deque, Sleep forks, InlineCancel (§5) | nothing (models only) | `lake build` green, each seeded failure fails |
| 1 | **The record in the frame** (C's L1 and L2 facts; `spawnAt`, `in_frame`, lazy `adopt`) | per join: the allocation and free (nil on pup, perhaps 71 to 60 ns); the cold pass: the heap's first-segment fault, unless #1156 took it | frames grow about 480 bytes per `&` site: `denseDepths` may push a task off dense stacks (http idle footprint, bench/tasks memory); `bench/check` |
| 2 | **`S + H` stacks** | nothing; address space 1.2% more a large stack | bench/tasks memory; tasks that fit at once |
| 3 | **The inline run** on today's claims (`runHere`, `Inline`, the swap, `host`, `cancel_below`, `passCancelDown`, `endInlineLevels`, `Isolate.at`, `RIG_SCHED_STATS` inline count) | per join: two switches, a stack, `fiberMain`'s and `finishFiber`'s CASes (nil perhaps 60 to 30 ns); psum one worker about 0.15-0.25 ms; the cold pass touches a stack per stolen task, not per fork | chain gets faster (it is a handoff today); actors, net, http, Trig level |
| 4 | **The deque** (`Forks`, `popIf` first in `runHere`, `adopt`, `stolen`, the push's lossy wake, `workPending`, `hasWork`, `next`, `search`); forks still in `queuedHere` | the slot swap's fence per fork; thieves take the oldest one; the 12-worker warm pass (steals, spread) | spawn, fanout (heap tasks, unchanged path) level; chain level |
| 5 | **The monitor** (forks out of the two-look rule, in the slice; the monitor's kick; `tick`'s rule, `fork_seen`) | the 50 µs stops during a fork-join (psum-gap's 20-55 a warm pass); the monitor's wake-ups | hog (a slice still stops a loop), http (latency) level |

After these, outside the runtime: `par` splitting by what is left (reads `stolen`), C's actor room
fix with `roomFor` (its own commit, bench/actors), and the lean record.

Commit 3 before 4 keeps inline's share apart from the queue's: on today's slots and ring,
`runHere` claims what `handoff` claims. Commit 5 apart from 4 keeps the monitor's share apart.

## 7. Tests on the runtime side

C's language.md §6 lists the language cases; these add to them:
- **sched.zig unit tests:** "a fork deque's owner takes back its newest fork, and a thief and the
  owner never both take one", as the ring's; `popIf` of a fork that is not the newest leaves the
  deque as it was; the push of a full deque goes to the ring; `next` takes own forks before the
  global queue; `runHere` declines on a stack with less than `S` left (a waiter that has used `H +
  1` bytes) and the wait hands off.
- **test/cli/fork_race.sh** (the race torture): a tree sum with GRAIN 1 over 2^16 at every worker
  count from 2 to the cores, 200 runs, release and safe builds, `RIG_SANITIZE=1`, checking every sum
  and that `RIG_SCHED_STATS` shows inline runs and stolen forks both nonzero; and the same with a
  second task waking fibers into the ring all the while, so slots, ring and deque race together.
- **Cancel into an inline chain:** an isolate stops while a task three levels inline sleeps 1 hour;
  it must end at once. Without `host` it waits the hour.
- **Panic in a runner's inline task:** an actor's method forks `t`, `t` runs inline and panics: the
  actor dies, the caller gets the panic, the program goes on. Without `Isolate.at` it jumps to a
  `home` of 0.
- **Room:** at one worker, a chain whose levels each hold 256 KiB of locals: inline for four levels,
  then a handoff, then inline again (`RIG_SCHED_STATS`).
- **The drop path:** a task dropped inside a drop chain (`drop_depth` above 0) runs inline and its
  drops run in it, in order.

## 8. On language.md

- **Agreed:** the rule (f), `H` = 1 MiB, the fact (`task_depths`: a proven depth only for
  dense-eligible sites, else a whole stack), the positive list for `task_record`, M1 as default, no
  CORE change, the oracle learning nothing, the actor bug and its own commit.
- **The blocking finding (§5 there):** answered by §3 here: forks stay in the slice and gain the
  monitor's kick; only the two-look rule loses them.
- **The record carries `need`:** agreed; the waiter may not be the maker. It also carries
  `Header.cancel` and `in_frame`.
- **A heap record may run inline** (C §2, "Independent of inlining"): yes; `runHere` claims from the
  slots and the ring as `handoff` does, so a returned task waited by `>t` inlines too.

## Recommended defaults

1. Room rule (f): inline when room ≥ the task's need (a proven depth, else a whole stack), large
   stacks `S + H`, `H` = 1 MiB; `main` stays exactly 64 MiB (M1).
2. One physical fiber: `runHere` swaps the task's state into the waiter's fiber, keeps its pin and
   guard, and stays on its count for the monitor.
3. Cancel through `Fiber.host`, `cancel_below` and `passCancelDown`; panics level by level in one
   loop, with `Isolate.at`.
4. A separate Chase-Lev `Forks` deque per worker for frame records; heap and local tasks keep the
   slots and ring; thieves take the oldest, one at a time.
5. Lossy wake at the push, recovered by `workPending`, the last look, the monitor's kick, and `tick`.
6. Forks in the slice, out of the two-look rule; `next` takes own forks before the global queue;
   `tick` yields to them after 16 checks.
7. Lean first: Ring `takeLast` (retroactive for #1157), Deque, Sleep with forks, InlineCancel.
8. Commits: frame record, `S + H`, inline on today's claims, deque, monitor; each against
   `bench/fork` and level on tasks, actors, net, http, Trig, loco and the guards.
