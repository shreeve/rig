# Rayon, Tokio, and Rig's tasks: a source-level comparison

Sources read: `misc/rayon` (rayon-core, `src/iter/plumbing`), `misc/tokio`
(multi-thread scheduler, task layout), crossbeam-deque 0.8.6 (from
`~/.cargo/registry`), and Rig at `origin/main` (023838ba7): `src/sched.zig`,
`src/tasks.zig`, `src/runtime.zig`, `docs/design/concurrency.md`,
`docs/internals/scheduler.md`, SPEC §18, `bench/tasks`. Rig line numbers
are `git show origin/main:PATH` line numbers.

One empirical step, not a benchmark: I built a 15-line copy of `fanout`
with the main checkout's `bin/rig build --release=fast` (private Zig
cache and `RIG_OUT_DIR` in the scratchpad) and disassembled the loop, and
compiled Tokio's `spin` with `rustc -O` to assembly, to compare the two
loops (section 4). Nothing was timed.

---

## 1. How Rayon really works

### join: a job on the caller's stack

`join_context` (rayon-core/src/join/mod.rs:132-173):

1. `StackJob::new(call_b(oper_b), SpinLatch::new(worker_thread))`
   (:136). The job is a local of `join`'s own frame: the closure B, a
   `JobResult<RB>` slot, and a latch (job.rs:72-81). **No allocation.**
2. `worker_thread.push(job_b_ref)` (:139). A `JobRef` is two words, a
   data pointer and an `execute` function pointer (job.rs:33-36), pushed
   on the worker's Chase-Lev deque (LIFO for the owner,
   registry.rs:250-254). The push is a buffer write, a Release fence and
   a store (crossbeam-deque deque.rs:395-418), then
   `sleep.new_internal_jobs` (registry.rs:728-732), which reads the
   sleep counters and wakes a thread only if some sleep
   (sleep/mod.rs:242-272).
3. Run A on the same stack, catching a panic (:142).
4. Pop local jobs until B's latch is set (:153-169). If the popped job
   is B (`job_b_id == job.id()`, :161), B runs **inline as a plain
   call**, `run_inline` (:165, job.rs:101-103): the closure is taken out
   of the cell and called, with no latch, no result slot traffic. If
   another job is on top (pushed by A and not yet popped), it is
   executed here first (:168). If the deque is empty, B was stolen:
   `wait_until(&job_b.latch)` (:157).

The owner's pop is a store of `back`, a **SeqCst fence**, a load of
`front`, and a CAS only when it takes the last element (deque.rs:482-510).
So an un-stolen join costs a push, a fenced pop, a couple of loads of
the sleep counters, and two direct calls: on the order of 10 ns, with no
atomic read-modify-write and no allocation (estimate from the code; I
did not time it).

### Stolen: latches and helping

The thief executes `StackJob::execute` (job.rs:116-125): run B, store
the result, `Latch::set`, all under `AbortIfPanic` (a panic inside the
protocol aborts). `SpinLatch::set` (latch.rs:194-224) swaps the state to
SET with SeqCst (latch.rs:126-129) and, only if the owner had gone to
SLEEPING, wakes that one thread (`notify_worker_latch_is_set`). The
comment at latch.rs:215-221 is the key invariant: after `set` the owner
may return and free the job, so the setter reads nothing from it after.
Rig's `Done.finish` (sched.zig:3023-3028) is the same protocol.

While B is stolen, the owner does not idle: `wait_until_cold`
(registry.rs:780-817) runs local jobs, then `find_work` = local, steal,
injected (:835-844), **nested on the same stack** above `join`'s frame.
Stealing picks a random start and walks every victim
(registry.rs:875-908). This "help while waiting" is what keeps cores
busy, and also Rayon's hazard: a waiting frame can be buried under an
unrelated stolen job, and a job that blocks (a mutex, I/O) blocks the
thread and everything nested under it.

Latch kinds (latch.rs): `CoreLatch` with four states, UNSET, SLEEPY,
SLEEPING, SET (:58-69); `SpinLatch` for workers (:148-224); `LockLatch`,
a mutex and condvar for threads outside the pool (:230-271); `CountLatch`
for scopes (:325-435). A call from outside the pool injects a
`StackJob` and blocks on a thread-local `LockLatch`
(registry.rs:515-538); from another pool, it injects and the calling
worker keeps working (`in_worker_cross`, :541-563).

### Sleep and wake

`sleep/mod.rs`: an idle worker yields its thread 32 rounds
(`ROUNDS_UNTIL_SLEEPY`, :56-57, :88-108), announces itself sleepy by
bumping the jobs event counter (JEC), yields once more, then sleeps on a
per-worker mutex and condvar, but only after checking the JEC has not
moved since it got sleepy (:118-194) and a last look for injected jobs
behind a SeqCst fence (:170-176). A new job wakes sleepers only when
the counters say none is awake and idle (:242-272). The waker decrements
the sleeping count itself, so others do not wake a thread already woken
(:288-311). This is the same lost-wakeup problem Rig's `sleep`/`relook`
solves (scheduler.md "Idle workers", formal `Sleep.lean`), with condvars
instead of a poller.

### The splitter (adaptive splitting)

`Splitter` (src/iter/plumbing/mod.rs:251-283): `splits` starts at
`current_num_threads()`. Each split halves it; when the job was
**stolen** (it runs on another thread than its parent, `migrated`), it
resets to `max(threads, splits/2)`. So with no stealing a range splits
into `next_power_of_two(threads)` leaves (16 pieces on 10 threads), and
each steal buys another `log2(threads)` levels of splitting where the
work moved: splitting follows demand, not size. `LengthSplitter`
(:289-332) adds a floor (`with_min_len`) and a minimum count of splits
from `with_max_len` (len / max). `bridge_producer_consumer`'s `helper`
(:393-436) is just: if `try_split`, split the producer and consumer at
`len/2` and `join_context` the halves, passing `context.migrated()`
down; else fold sequentially. Every level of the recursion is a join, so
the whole iterator rides on the zero-allocation join above.

### scope and spawn

`scope` (scope/mod.rs:306-315) makes a `ScopeBase` on the caller's stack:
a registry handle, a first-panic slot, a `CountLatch` (:36-54).
`Scope::spawn` (:566-577) **allocates** a `HeapJob` (`Box::new`,
job.rs:145-147; scope/mod.rs:645-666), increments the latch (:684-693),
and pushes to the local deque if on a worker of the pool, else injects
(`inject_or_push`, registry.rs:412-421). `complete` runs the scope body,
then waits on the count (helping meanwhile), then rethrows the first
panic (:696-703, :759-768). A spawned job's panic is caught and the
first one kept (`job_panicked`, :735-757). So `scope` is Rig's `Tasks`
set: one allocation per spawned job, a count, wait-all, first panic
wins.

### Panics

A panic in A still waits for B before unwinding
(`join_recover_from_panic`, join/mod.rs:178-186), because B may hold
references into the frame. A panic in a stolen B is stored as
`JobResult::Panic` (job.rs:222-228) and resumed in the owner by
`into_result` (job.rs:234-240). This is exactly Rig's rule 4 ("a panic
stops at a boundary, which cancels and waits for every task under it
before it gives back the stacks they may point into").

### Costs per join, summarized

| Path | Cost |
|---|---|
| not stolen | deque push (Release fence), fenced pop, two calls; no allocation, no RMW; ~10 ns order |
| stolen | thief CAS on `front`, cache-line transfer of the job and its result, a SeqCst swap of the latch, and a condvar wake only if the owner slept |
| `scope.spawn` | one `Box` per job, a counter increment, a push or an inject |

---

## 2. Rayon versus Tokio

| | Rayon | Tokio (multi-thread) |
|---|---|---|
| Purpose | CPU-bound data parallelism | I/O-bound concurrency |
| Unit | a closure run to completion (`JobRef`, two words) | a future polled until `Ready`, in a heap `Cell` |
| Where it runs | on whatever stack the worker is on, nested | in `poll`, on the worker's stack, unwound at every `Pending` |
| Blocking inside | blocks the thread and everything nested under it | blocks the worker (must use `spawn_blocking`/`block_in_place`) |
| Local queue | Chase-Lev deque, owner LIFO, thieves FIFO | LIFO slot of one + FIFO ring of 256 (queue.rs:63), owner pops with a CAS |
| Steal | one job | half the ring (queue.rs:417-460, `n - n/2` at :488), only while under half the workers search (worker.rs:1156-1189) |
| Overflow | deque grows | half the ring to the global inject queue (queue.rs:253-316) |
| Fairness | none needed: jobs finish | global queue every `global_queue_interval` ticks (worker.rs:1084-1087), LIFO slot at most 3 in a row (worker.rs:270, :726-765), coop budget of 128 per poll (task/coop/mod.rs:115-117) |
| Data from the caller | non-`'static` references (join and scope block until done) | `'static` only: a future can be leaked (`mem::forget`), so a scoped spawn is unsound |
| Idle | spin-yield 32 rounds, then a condvar | park in the I/O driver or a condvar |
| Timers, I/O | none | driver, timer wheel |
| Task memory | the job, in the caller's frame | `Cell`: Header + Core (future or output) + Trailer, aligned to 128 bytes on x86_64/aarch64 (task/core.rs:60-68, :124-210) |

**Why Rust needs both.** Rust's async functions are a second kind of
function: CPU work in a Tokio task holds the worker, since Tokio never
preempts (the coop budget only acts at resource polls), so heavy compute
goes to Rayon or `spawn_blocking`. And Rayon's model works only because
a job never suspends: a join's waiting frame can host other jobs nested
on top of it because each finishes before returning. A job that waited
on I/O would hold the thread and everything under it. The split is
forced by two Rust facts: futures are stackless values that can move and
be leaked (hence `Pin` and `'static`), and threads are the only
preemptible, stackful unit. Rayon gets non-`'static` data by blocking a
thread; Tokio cannot block, so it cannot lend.

Rig's design removes both reasons: every task is stackful (any function
waits), every loop and cycle of calls has a yield check (compute does
not hold a worker), and the checker proves a task ends before its owner
(no `forget`, drop cancels and waits, no shared home holds a task), so a
task views its caller's data in place the way a Rayon job does, and
suspends the way a Tokio task does. In the terms of the "scoped task
trilemma" (concurrency, parallelism, lending: pick two in Rust), Rig gets
all three by giving up leaking.

---

## 3. Where Rig sits

### What `&` already does like `join`

- **Views in place.** `score(?d)&` reads `d` where it lies, like a
  Rayon closure capturing `&d`, because the task's drop waits
  (concurrency.md, "Loans and structure", rules 1-5).
- **Run the unstarted task at the wait.** `Header.waitEnd`
  (sched.zig:3108-3126): if the task has not started and sits in this
  worker's run-next slot, `handoff` (:3171-3205) switches straight to it
  and it switches straight back at its end, past the queues. This is
  Rayon's pop-and-run-inline, except that it runs **on the task's own
  stack**.
- **Work-first locality.** The run-next slot (`wake`, :252-275) keeps the
  newest task next on its maker's worker, like the top of Rayon's LIFO
  deque, and fork-join spreads at the first yield check of the code
  between `&` and `>` (scheduler.md, "Queues").
- **Panic waits for children** (rule 4), as `join_recover_from_panic`.
- **Waiting does not bury.** A Rig waiter suspends its fiber; the worker
  runs other fibers on their own stacks. Rayon's waiter runs other jobs
  nested on its stack and cannot return until they do. This is a real
  Rig advantage, and the reason blocking inside a Rig task is fine.

### What it does not do

- **A heap record per task.** `sched.spawn` calls
  `std.heap.smp_allocator.create(Full)` for every task (:3228) and
  `destroy` at the end: Header (Fiber with its `TaskState`, `Done`),
  result, `Control`, arguments. Rayon's join allocates nothing.
- **A stack per task, even when its own waiter runs it.** `handoff`
  still calls `prepare` (:2242-2251): `takeStack` pops a free stack
  (:3350-3383) whose top page lives in its own 64 MiB + guard span, a
  likely TLB miss and cache miss, then two full register switches (160
  bytes saved each way on aarch64). Rayon's un-stolen B is a call.
- **The local ring is FIFO for its owner.** `Ring.pop` takes from the
  head with a CAS (:2537-2546), the same end thieves take (`stealFrom`,
  :2549-2565). Only the single run-next slot is LIFO. For recursive
  fork-join this matters (below).
- **`par` is flat.** `parRun` (tasks.zig:920-966) starts `workers - 1`
  helper tasks (:954-956) that take chunks of `n / (count * 8)`
  (:927) from a shared counter. It balances well for one flat list, but
  a `par.map` nested inside another's closure starts another
  `workers - 1` fibers each time, and nothing like Rayon's thief
  splitting decides granularity by demand.

### Can Rig get zero-allocation lazy fork-join with no second API?

Yes. Rayon's `join(a, b)` is already spelled in Rig: `t = b()&; x = a();
y = >t`, or `task.all(a()&, b()&)`. Two changes make it cost what
Rayon's does, both invisible in the source:

**(i) The record in the maker's frame.** When the `Task` value never
leaves the frame that makes it (bound to a local and waited or dropped
there; every task with a write loan is already forced into this shape by
SPEC §18), emit can place the `Job` in a frame slot instead of the heap,
as Rayon's `StackJob`. It is sound for the same reason the task's loans
are: the task's drop waits for it before the frame goes, and a panic's
boundary waits for it before giving back the stack (rule 4). This is a
new storage fact (`src/storage.zig` decides hidden storage; "never take
the address of a Zig temporary no storage fact names"), recorded once.
A `Tasks` set can hold its tasks' records in blocks it owns, one
allocation per block rather than per task.

**(ii) Run it on the waiter's stack.** Generalize `handoff`: at `>t`,
if the task is unstarted and in this worker's slot (or ring tail, see
below), and there is room, call its body **on the waiter's own stack**,
not on a stack of its own. If it waits partway, the waiter's fiber
suspends with the task's frames on top; that changes nothing observable,
because the waiter was about to wait for exactly that task. The
"guaranteed to run concurrently" rule (SPEC §18) still holds: until the
waiter reaches `>t`, the task is an ordinary ready fiber that any worker
may steal and run apart; only the waiter's own blocking point decides to
run it in place, which is what handoff already does.

What must be handled, and how:

| Concern | Resolution |
|---|---|
| Stack room | The actor idle path already runs a method inline only when a quarter of a task stack is left (`roomInline`, tasks.zig:2461-2471). Reuse it; otherwise hand off as today. An overflow still lands in the guard, so a mistake is a crash, never corruption. |
| Task state | Swap in the task's `TaskState` fields (control, own, deadline, isolate) for the inline run, as an inline actor method runs "as the actor" (concurrency.md, "The idle path"). |
| Cancellation | A cancel of the waiter passes down to the task (it already does). `interruptForCancel` must reach the waiter's fiber while it runs the task: point the task's `Control.fiber` at it for the run. |
| Drop of an unwaited task | Same path: a drop of an unstarted infallible task runs it inline then. (Optional, the owner's call: withdraw an unstarted *fallible* task on cancel without running it, as an actor message is withdrawn, SPEC "is withdrawn". That changes which side effects happen, so it is a semantic decision.) |
| Deadlines, selects | `>t` under `time.within`, and `?t.on_end()` in a select, may stop waiting while the task goes on: never inline them. Handoff already skips a wait with a deadline (:3121). |
| Deadlock walk | The walk goes from a waiter to the task's fiber's `blocked`. While inline, the Header must name the fiber that runs it, so the walk follows the waiter's own `blocked`. |
| Yield checks | A yield inside the inline task yields the waiter's fiber; the fiber may be stolen and resumed elsewhere, frames and all. No change. |
| Local tasks | A pinned task run inline pins the waiter, which `pinHere` already does to a task's maker. |
| Panics | The task's frames sit above the waiter's `>t`; a panic is recorded as the task's and passes to the waiter as now (`rt.passPanic`). The boundary abandons the frames where they stand either way. |
| Running unrelated work inline | Never: run only the task being waited for (or tasks of the set being waited for). Running arbitrary local work inline is what buries Rayon's waiters and deadlocks it under blocking. |

**Ring order.** For recursive divide and conquer (`a = f(lo)&; b =
f(hi); >a`, and a recursive `par`), the owner should take its newest
work and thieves its oldest, as Chase-Lev does: Cilk's space bound
(live stacks at most S1 times the workers) depends on it. Rig's slot
covers one level; deeper, the owner's FIFO pop runs the *oldest* (and
largest) piece while the small piece it waits for sits at the tail,
which keeps more fibers, and so more stacks, alive at once. A
Chase-Lev ring (owner pops the tail, no CAS unless one element is left)
or at least "pop the tail if it is the task I wait for" (Rayon's id
check, join/mod.rs:161) fixes it. This should come with (ii).

**Rough gain** (unmeasured, to be measured): `chain` is 45 ns on the
Mac; most of it is the record's allocation and free, the stack take and
release, and two switches. With (i) and (ii) an un-stolen
`t = f()&; >t` is a slot swap, a CAS, a call and a `Done` finish: I
expect 10-15 ns. `spawn` (bulk `Tasks`) gains from (i) only.

**What it would enable:** Rayon-style `par` (recursive halving with
thief splitting, Splitter above) costs nothing at the levels nobody
steals, so a `par.map` inside a `par.map` costs nothing when the cores
are already busy, and granularity follows demand. Without (i) and (ii),
recursive splitting would pay a heap record and a stack per level, which
is why the flat counter design is right today.

---

## 4. Why `fanout` is behind

`fanout` runs 10 tasks, each a 20-million-turn loop of
`total = (total + i * 7) % 1000003` (bench/tasks/tasks.rig). The M5 has
4 performance and 6 efficiency cores (`sysctl hw.perflevel0/1`), so the
run takes as long as the slowest core's task in every runtime; no
scheduler can split an indivisible task, and Rayon could not do better
with 10 items either. The README already says the gap "is the compiled
loop's, not the scheduler's", and the code confirms it.

Rig emits (via `bin/rig emit`):

```zig
while (i < end) : ({ rig.turn(&turns); i += 1; }) {
    total = rig.rem(total + (i * 7), 1000003);
}
```

`rig.rem` is `@rem` (runtime.zig:5797-5804), the same as Rust's `%`;
`rig.turn` decrements a counter and every 1,024 turns calls the
scheduler through `callKeeping` (runtime.zig:425-440). The counter lives
in the loop's continue expression, so the loop's latch has two
successors (the tick path rejoins mid-body), and LLVM's loop
strength reduction rewrites the induction variable onto the loop-carried
chain. The disassembled release-fast loop:

```
loop: mov  x13, x14
      subs w11, w11, #1 ; b.eq tick      <- the turn counter
      add  x14, x13, x9
      umulh x15, x14, x12
      sub  x14, x14, x15
      add  x14, x15, x14, lsr #1
      lsr  x14, x14, #19
      msub x14, x14, x10, x13
      add  x14, x8, x14                  <- on the dependency chain
      add  x14, x14, #7                  <- on the dependency chain
      add  x8, x8, #7 ; add x9, x9, #7 ; subs x20, x20, #1 ; b.ne loop
```

Rust's (`rustc -O`, Tokio's `spin`):

```
loop: add  x12, x0, x9
      smulh x13, x12, x10
      add  x13, x13, x12
      asr  x14, x13, #19
      add  x13, x14, x13, lsr #63
      msub x0, x13, x11, x12
      add  x9, x9, #7 ; subs x8, x8, #1 ; b.ne loop
```

The loop is latency-bound on `total`; Rig's chain carries two extra adds
(and a register move) per turn, about 2 cycles on a chain of about 12:
15-20% slower, which matches 85 ms against 69 ms (and `rig-safe` at
69.5-75 ms in PROGRESS.md, where the overflow checks happen to give
LLVM a different shape, shows the loop can match). Tokio and Rayon put
nothing in the loop; Go puts nothing either, since it preempts by
signal (it can stop a goroutine at any instruction because it keeps
precise register and stack maps; Rig cannot switch from a signal
handler, which may land inside the allocator or a runtime lock).

**Fix: strip-mine counted loops**, as HotSpot C2 does for its safepoint
polls (loop strip mining, JDK 10):

```zig
while (i < end) {
    const stop = @min(end, i + 1024);   // after the first block, 1024 left of the count
    while (i < stop) : (i += 1) { body }
    rig.tick();                          // one check per block, outside the inner loop
}
```

The inner loop is exactly Rust's; the check moves outside it. It keeps
the guarantee (a check at most every 1,024 turns), keeps "a turn that
leaves its loop counts nothing", and vectorizes better too. For
`while` loops with no trip count, a counter remains, but it can be the
inner loop's second exit condition rather than a call in the latch. Where
`proofs.zig` bounds a loop's trip count low, the check can go entirely.
This should move `fanout` to Tokio's number, and every compute loop of
every task-making program, Trig included, by the same mechanism.

A benchmark that would show the scheduler (not codegen) on this
machine: a splittable fanout (`par.map` over 200 items of 1M turns).
With 4 fast and 6 slow cores, dynamic chunking (Rig's counter, Rayon's
thief splitting) wins over a static split, and that is where Rig and
Rayon can be compared.

---

## 5. Memory at rest

### Why Rig pays a page

A sleeping Rig task holds its record (about 0.5 KiB: the Fiber with its
`TaskState`, runtime.zig:5929-5949, the `Done`, the `Control`, the
arguments) plus **every page its stack has touched**: at least the top
page, since a frame is there. A page is 16 KiB on macOS arm64 and
4 KiB on Linux x86, hence 16.6 KiB and 5.2 KiB. Tokio's task is a heap
`Cell` holding just the future's live state (task/core.rs:124-210), and
Go's stacks are 2 KiB pieces of heap spans, packed several per page,
because Go checks the stack in every prologue and can move stacks (it
has precise pointer maps). So the owner is right: the page is the cost
of "each task owns a separately mapped stack with a guard", not of the
hardware. Only three things get under a page: no stack (a), stacks
packed together (b), or the live part of the stack moved off its page
while the task sleeps (c).

What must survive any option: **stacks never move while anything points
into them.** Loans point from child tasks into their owners' frames
(concurrency.md: "loans point only from tasks into their owners"), an
actor call's message and reply slot live in the caller's frame, a
`rig.blocking` call writes into its waiter's buffer, and runtime records
on the stack are published to other threads (`Blocked` in
`Header.waitEnd`, sched.zig:3110-3112; waiter list entries).

### (a) Stackless tasks compiled to state machines

- **At rest:** the frame's live state only: could match or beat Tokio
  (no waker or vtable needed per task).
- **Switch:** a resume is a jump into a state; with whole-program
  frames nested inline (as Zig's old async did) it is O(1), not Tokio's
  poll down the nest of futures.
- **Loans:** fine. The frame lives in the task record, which never
  moves, so Rig needs no `Pin`: the user never holds the future as a
  value.
- **Why not:** every yield check is a suspension point, and Rig puts one
  in every loop and on every cycle of calls. So nearly every function of
  a task-making program, std included, would need the transform, with
  values live across checks kept in the frame. Recursion needs a heap
  frame per call, and calls through function values, closures, and API
  objects need frames of unknown size (boxed, like Rust's `dyn
  Future`). Zig 0.17 has no coroutines ("async/await keywords and
  `@frameSize` are gone", ZIG-0.17.md:764), so Rig's emitter would do the
  whole coroutine split itself. Zig shipped inferred, colorless async
  (0.6-0.10) and removed it in 0.11 over exactly these problems: frame
  sizes through function pointers, recursion, and backend bugs. It
  would also undo "Switching is cheap" and the one-kind-of-function
  model's simplicity in the compiler. **Not recommended.**

### (b) Exact-size small stacks from a slab, no guard

- **At rest:** the bound B per task, packed several per page: with B =
  4 KiB, four to a 16 KiB page, so about 4.5 KiB on the Mac and Linux
  alike. It also shrinks running tasks and packs stacks so a spawn no
  longer touches a fresh page per task.
- **Switch:** unchanged.
- **Loans:** fine; stacks still never move.
- **What it needs:** a *sound* bound per task entry, since with no
  guard a wrong bound silently corrupts the next stack (North Star 2).
  Today Rig bounds frames, not depth: `frames.zig` reads each prologue
  of the linked binary, and the guard covers one frame (`sema.taskGuard`,
  sema.zig:318; `reach_factor` 4, :287). A depth bound needs the
  binary's call graph too (decode `bl`/`call` targets beside the
  prologues; treat `blr`/indirect calls as the most any address-taken
  function can reach, or as an escape point), and recursion excluded.
  Deep runtime paths would move off the task stack, as Go's
  `systemstack` does: the deadlock walk (`walkFrom`, ~15 KiB), panic
  reporting, the allocator's slow path.

**(b') the practical form: small stacks with an escape at the existing
cycle checks.** Rig already places a check on every cycle of calls
(`inlining.Pass.cutCycles`), so between two checks a task makes "at most
one chain of calls that repeats no function" (scheduler.md, "Yield
checks"). Make that check also compare the stack pointer with the
fiber's limit: when less than D is left (D = the deepest acyclic chain
between checks, computed after linking from frames and direct call
edges), run that call on a large stack instead, like Rust's `stacker`
crate or Rig's own `runApart` (sched.zig:3581-3591), kept with the fiber
for later calls. Frames never move, so loans are untouched. Recursion
and deep calls get the big stack; a task that sleeps in shallow code (an
idle connection, a timer) keeps only its small one. Indirect call sites
become check points too. The hot-split problem that killed segmented
stacks in Go and Rust came from allocating and freeing a segment at a
boundary in a hot loop; a big stack kept on the fiber makes a crossing a
few nanoseconds. A canary at each small stack's base, checked at
switches in safe builds, and guard-paged stacks under `RIG_SANITIZE=1`,
catch a wrong D in testing.

### (c) Copy the live part out while it sleeps, back to the same address

- **At rest:** record + live bytes (`top - sp` at the park: plausibly
  0.5-2 KiB for `nap()`; measure first), on any page size: about
  1-2.5 KiB, under Go's 2.9 KiB, still above Tokio's 270 B.
- **Switch:** unchanged on every hot wait. A compacted task pays on
  resume a page fault (zero-fill of a 16 KiB page, about 1-2 µs) and a
  copy of its live bytes (tens of ns), and the release costs an
  `madvise` (`MADV_DONTNEED` on Linux, `MADV_FREE_REUSABLE` on macOS).
  So compact only tasks asleep a while (a timer far off, a socket idle
  past a threshold), in batches, by a worker about to sleep anyway:
  then the cost lands where nothing waits.
- **Loans:** the task keeps its own reserved range and resumes at the
  same address, so its own internal pointers, frame pointers, and views
  of its own locals stay valid with no pointer maps. What is not allowed
  is anyone *else* pointing into the region while it is copied out. The
  conditions are cheap to know:
  - runtime records move into the Fiber record or the heap (`Blocked`,
    the waiter-list entry; a fiber has one wait at a time; a select's
    arms either get heap nodes or make the wait not compactable);
  - the wait kind is one nobody writes into the stack during: sleep,
    descriptor, channel, task or set end; not an actor call (its
    message is in the caller's frame) and not a `rig.blocking` call;
  - no live child task holds a loan into this stack: a per-fiber count
    of live children that took a view (the checker knows at each `&`
    which arguments are lent), incremented at spawn and decremented at
    end, on the fiber's own field.
  The 10,000 `nap()` tasks of `bench/tasks` `many` and an idle HTTP
  connection meet all three. A parent waiting on children it lent to
  does not, and keeps its page, which is right.
- This is greenlet's and libco's stack copying without their shared
  stacks: libco's shared-stack mode would make two tasks of one stack
  unable to run at once, and a parent that lends to its child (the core
  Rig pattern) would deadlock against that child, so a private address
  range per task, released and restored page by page, is the version
  that fits Rig.

### (d) Better or complementary

- **(b') + (c) together** is the best memory result reachable without
  stackless code: small packed stacks for every task (running ones
  included, and denser spawn), plus compaction of long sleepers down to
  their live bytes. (c) needs no new proof obligation beyond "nothing
  points in", which is checkable at run time; (b') needs a post-link
  depth bound, so it is the riskier half.
- **Shallower parking.** Whatever the scheme, the at-rest cost is the
  record plus the frames from `fiberMain` down to the switch. Keeping
  the waiting path short (no large locals in `sched.block`, the walk in
  its own frame as today, `TaskState`'s `drop_queue` lazily allocated)
  shrinks (c) directly.
- **Hardware tags.** The M5 has memory tagging (EMTE). Tagging each
  small stack differently would give a 16-byte guard between packed
  stacks for free, making (b) safe without a proof. Apple-only and not
  exposed to Zig today, so a note, not a plan.
- **Not useful:** Go-style stack growth by copying needs precise
  pointer maps that Zig and LLVM do not give, and moving a stack breaks
  the views children hold into it; (c) gets the same memory at rest
  without moving anything.

---

## 6. Recommendations, ranked

1. **Strip-mine loop yield checks** (emit only). Inner loop free of the
   check, one check per 1,024-turn block, counter kept only for
   `while` loops. Closes `fanout` (85 ms against Tokio's 69) and speeds
   every compute loop in task programs, Trig's included. Low risk,
   small change, measurable at once.
2. **Compact long sleepers** (option c): move the runtime's on-stack wait
   records into the Fiber, count children holding loans, mark wait
   kinds, and let a worker about to sleep copy out and release the
   pages of tasks asleep past a threshold. 16.6 KiB to about 1-2 KiB
   per sleeping task on the Mac, 5.2 KiB to about 1-2 KiB on Linux.
   Measure `top - sp` at parks first (a `RIG_SCHED_STATS` histogram) to
   bound the gain before building.
3. **Lazy fork-join** without new syntax: the task record in the maker's
   frame when the `Task` stays there (a storage fact), records in blocks
   for `Tasks`, and running an unstarted task on its waiter's stack at
   `>t` (handoff generalized, with the room check of the actor idle
   path), plus owner-LIFO order in the ring. Expected: `chain` from
   45 ns toward 10-15 ns, no allocation per un-stolen join.
4. **Rayon-style `par`** on top of 3: recursive halving with thief
   splitting, so nested `par` is free when nobody steals and granularity
   follows demand on asymmetric cores. Keep the flat counter until 3
   makes a level cost a few nanoseconds.
5. **Small packed stacks with an escape at the cycle checks** (option
   b'): densest stacks for running tasks too, but needs a post-link
   depth bound (call edges in `frames.zig`) and deep runtime paths on
   the worker's stack. After 2, when 2's numbers show what remains.
6. **Not stackless state machines** (option a): the yield checks make
   nearly every function a suspension point, recursion and function
   values need boxed frames, Zig 0.17 has no coroutines, and Zig removed
   the same design in 0.11.

Usability needs nothing new: Rayon's `join` is `task.all(a()&, b()&)`
or `t = a()&; ...; >t`, Rayon's `scope` is `Tasks`, and Tokio's
`spawn` is `&` with views allowed. The work is making those forms cost
what Rayon's cost, which 1, 3 and 4 do, and making a sleeping task cost
what Go's does or less, which 2 does.
