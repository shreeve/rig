# Free fork-join, the build round: the language (expert C)

Read at origin/main ee994781b: src/storage.zig, facts.zig, emit.zig (`emitTask`), typecheck.zig
(`taskOf`), inlining.zig (`denseDepths`, the `dense_calls` decision), sched.zig (`Header.waitEndIn`,
`handoff`, `Done`, `queuedHere`), tasks.zig (`Isolate`, `roomInline`), runtime.zig (stacks), SPEC §1
and §18, CORE §2, §9, §10, docs/design/concurrency.md, the 11-15 round, and test/rig/concurrency-*.

## Answers in brief

1. **Inline rule.** Any `&` site's task may run on its waiter's stack at a single `>t`, or when it is
   dropped, if it has not started and the waiter's stack has at least as much room left as the
   task's own stack would give it. The compiler records one number per site: the proven depth `d`
   when the site could take a dense stack, otherwise nothing, which means "a whole task stack". The
   runtime compares that with the room left. Sound by construction: an inline task never gets less
   stack than SPEC promises it.
2. **To make psum and qsort inline** under that exact rule, a task stack reserves 64 MiB plus a
   small headroom `H` (default 1 MiB, address space only). A waiter that has used no more than `H`
   then has 64 MiB left, so it inlines even a recursive task. A fork tree is shallow in bytes: psum's
   chain is 12 levels of a few hundred bytes. No depth proof is needed, and SPEC's 64 MiB stays the
   promise.
3. **The record's home** is a storage fact, `task_record`. It holds when a site is the whole value of
   a fresh binding, `t = f(x)&`, and every use of `t` is on a positive list: `>t`, `<t.cancel()`, a
   read lend (`?t`, `?t.on_end()`), or its drop. Anything that takes `t` (a move, return, last value,
   `break`, a set, a field, a `|<t|` capture, or assigning `t` again) leaves the record on the heap.
4. **No ownership change.** CORE stays as it is: no loan, move, drop or order changes, and §10 is not
   triggered. The oracle learns nothing. SPEC §18 changes in one sentence.
5. **A blocking finding on the runtime side, whatever B proposes:** a fork must stay visible to
   "Taking turns" (SPEC §18). If forks are hidden from the monitor's `queuedHere`, a maker that
   computes for a long time starves its unstolen fork at one worker, which SPEC forbids. The cheap
   fix keeps forks visible but slows the monitor's checks, not drops the work from them. B's §3
   answers this.
7. **Unsound in runtime.md as written** (§8): `Control.finish` takes a task off its isolate's list
   before its last writes into the record. So after a maker panics, the isolate can give back a
   stack that still holds a stolen fork's frame record, and the thief then writes into a stack
   another task has taken. The fix is to make the release the last access, in commit 1.
6. **An existing bug of the same class:** an actor's method runs inline when the caller has a
   quarter of its stack left (`tasks.roomInline`: 16 MiB). A method that needs 20 MiB overflows
   inline but not on its actor's own task. The same room rule fixes it, as a separate commit.

## 1. Which sites may run inline, and what the compiler records

### What must hold

A program accepted today must not overflow its stack after the change unless it overflowed before
(North Star 1). SPEC §18 promises each task "a stack of its own as large as main's", 64 MiB. So a task
`t` run on its waiter `W`'s stack must have at least the room its own stack would give it:
`room(W at >t) ≥ need(t)`, where `need(t)` is the most stack `t` can take. Each nested `>u` inside
`t` checks again against the room left at that point, so `need(t)` counts only `t`'s plain calls.

### The options, judged

| Option | psum, qsort | Sound | Verdict |
|---|---|---|---|
| (a) Inline only a proven depth (`denseDepths`), as the 11-15 synthesis says | never: `psum` is on a cycle of calls | yes | misses the row it exists for |
| (b) "Frames between two waits": cut the call graph at `>` sites, since each nested inline run checks again | never: the plain call `a = psum(xs[..mid])` sits between the fork and its wait and recurses | yes | no gain over (a) for recursion; only refines bodies that are already bounded |
| (c) Frame bound times a proven depth | needs `log2(len)` proven: a size-change analysis | yes, if proven | out of reach, and one-off |
| (d) A heuristic room, such as a quarter of the stack (the actor path's rule) | always | **no**: a task that needs 20 MiB overflows inline | rejected; the actor path is a bug of this class (§5) |
| (e) Reserve twice the stack, `2S` (11-15 runtime.md) | always | yes | sound, but doubles every large stack's reservation to buy what `H` buys |
| (f) **Exact rule, stacks of `S + H`** | always, while the waiter has used `≤ H` | yes | **recommended** |

### The rule (f)

- **The fact.** For each `&` site, `d(site)` is the largest `denseDepths` among the functions the
  call may reach, recorded only when all of them are known and below `sema.dense_depth_limit`. That
  is the condition `dense_calls` checks today. Otherwise the site has no number. The fact replaces
  `SemContext.dense_calls` with `task_depths: FastMap(NodeKey, u32)`, and `Facts.isDenseCall`
  becomes "has a depth". It is decided in inlining.zig only (one classifier per fact).
- **Why only dense-eligible depths.** `denseDepths` uses `reach_factor` 4, which is measured, not
  proven (SPEC §1). A dense task already trusts that factor on a smaller stack, so inlining it with
  `room ≥ d + slack` risks nothing a dense stack does not. A bounded task above the dense limit runs
  today on a 64 MiB stack. Inlining it against an under-counted `d` could overflow where its own
  stack would not, so it counts as unbounded.
- **What emit writes.** The number, verbatim, as a compile-time argument of the spawn
  (`spawn(.{ .depth = 12345 }, f, args)` or `.depth = null`). Emit decides nothing. The record keeps
  it, because the waiter may not be the maker: a task returned from `start()` and waited for by its
  caller carries its own need.
- **What the runtime checks** at `>t`, in `Header.waitEndIn` before `handoff`:
  `need = if (depth) |d| d + frame_slack else task_stack_size`, and it runs `t` inline when
  `@frameAddress() - guard.hi ≥ need + preempt_room`. The waiter's `stack_guard` stays (11-15: the
  task's `TaskState` is swapped in, all but `stack_guard`), so an overflow still faults in the
  waiter's guard. `frame_slack` covers the runtime's own frames between `>t` and `t`'s entry. The
  CLI script `task_frames.sh` already bounds them at under half the guard.
- **The stacks.** A large task stack reserves `S + H`, not `S` (`rt.task_stack_size = stack_size + H`).
  A fresh fiber has `S + H` of room. A waiter that has used `u ≤ H` has `≥ S` left, so it inlines even
  a task with no bound. Past `H`, an unbounded task is handed off as today, so the program is correct
  either way, just not faster. Dense stacks do not change: a waiter on a dense stack inlines a dense
  task while `room ≥ d + slack`, and hands off the rest.
- **What `H` costs.** 1 MiB of address space for each large stack (1.2% of a 16 MiB guard plus
  64 MiB) and nothing committed. psum on one worker inlines everything below `main`'s spine: 12
  levels of about 300 to 600 bytes each (the `psum` frame, `waitEndIn`, `runHere`, the start
  trampoline). qsort is 9 levels. Expert A's ceiling should confirm the bytes per level.
- **The waiter's own `d`** leaves out the tasks it waits for, because each inline run is checked
  against the room left at its wait. If inlining.zig counts a task's call as an edge of its maker
  (`frame_calls`), a maker that forks a recursive helper looks unbounded. That is conservative but
  needless, and the builder should check it.

### `main`'s stack: two ways

- **M1 (default): `main` keeps exactly 64 MiB.** SPEC §1 is untouched. On `main`, an unbounded
  task's `>t` cannot meet `room ≥ S`, so the spine of plain calls that `main` itself walks hands off,
  one fiber per level: psum 12, qsort 9, against today's 4,095 and 4,094 records and about 170
  fresh stacks. Each fiber then inlines its whole subtree. SPEC §18 says a task's stack is "at least
  as large as `main`'s".
- **M2: every stack is `S + H`, `main`'s too.** One rule everywhere, and `main`'s spine inlines too.
  SPEC §1's "a stack of 64 MiB" becomes "at least 64 MiB". Take it if Expert A measures the spine's
  handoffs above 1% of a cold psum.

Either way, whether a task needing between 64 MiB and `64 MiB + H` overflows depends on whether it
ran inline. Every such program overflows today. Under `RIG_SEED` nothing inlines, so seeded runs stay
deterministic.

### What stays a fiber (the runtime decides; the checkers record nothing more)

These follow the 11-15 synthesis, item 3, and I keep them:
- `Tasks` sets, `task.all`, select arms, actor calls, and `time.within`;
- a fallible wait under a deadline;
- any task once a worker has started it;
- everything under `RIG_SEED`.

Only the awaited task runs, never another taken from the deque, which can deadlock on a channel.

## 2. The record in its maker's frame (question 4)

### The fact

storage.zig gains `StorageKind.task_record` (`__rig_task`), `by: .owned`, `life: .block`. It names
the frame slot `emitTask` writes into: `spawnAt(&__rig_task_N, opts, f, args)`. Emit asks for the
slot through `hiddenStorage`, as for every other hidden slot. It never makes one that no fact names.

**When the record stays in the frame.** Two conditions, decided by a positive list (North Star 4):

1. **The site.** The `&` call is the whole value of a binding statement that declares a fresh
   name, `t = f(x)&`, in the block where the slot is declared. A task that is an argument
   (`!ts.add(f()&)`, `task.all(f()&, g()&)`), a field value, a return value, or a header subject keeps
   a heap record.
2. **Every use of `t`** (`Facts.useOf`, the one classifier of uses) is one of:
   - the operand of `>t` (with `!` or `catch` after it);
   - self of `<t.cancel()`, a built-in that waits for the end before it returns;
   - a read lend, `?t`, including `?t.on_end()` in a select;
   - its drop at the end of its scope, or at an early exit (`return`, `!`, `break`, `continue`).

   Anything else takes `t`: `<t`, `return t`, last value, `break t`, an argument by value, a stored
   field or element, `!ts.add(<t)`, a closure capture that moves (`|<t|`, as `time.within` takes
   one), or `t = …` again. Any of these makes the decision false, and the record stays on the heap,
   as today.

**Why this is enough.** The slot lives until its block ends. Under condition 1 the binding lives no
longer than that block. Under condition 2 the task never leaves the binding, so its drop, which waits
(SPEC §18 "Drop"), runs before the block ends on every path. "Out of scope before its site reruns"
follows: a site in a loop body binds a fresh `t` each pass, dropped at that pass's end, and
reassignment is excluded. That rules out an outer `t = f()&` in a loop, whose right side would
overwrite the slot before the old task's drop. Recursion uses a new frame, so a new slot. A `defer`
that waits on `t` lies inside `t`'s scope.

**Size.** The record (header, arguments, result) counts in the maker's reach. That keeps
`denseDepths`, the large-frame marks, and Zig's inlining honest. A record estimated above 1 KiB
stays on the heap: an argument held by value, such as a `[4096]Int`, would multiply a recursive
frame. The header's size is a runtime constant that sema mirrors (`sema.task_record_header`), and a
unit test checks it against `@sizeOf`, as other mirrored constants are checked. frames.zig's
post-link read of the real frames catches an under-count.

**`verifyDecisions`** asks the question again at the plan's end, like every other recorded decision.

**A cross-check in self-check builds** (`-Dself-check=true`, which the suite builds): the ownership
checker asserts that it never sees a `take` of a binding whose site holds `task_record`. This only
checks that the two passes agree. It is not a second decision.

**In the runtime.** The frame record's `Header.destroy` does nothing. `waitInto` and `__rig_drop`
stay. In a sanitized build, the drop of a frame-held task asserts that the record lies above the
current frame on the running fiber's stack.

### Independent of inlining

The record's home and inline runs are separate facts and separate commits. A frame record that is
stolen runs as a fiber with its record in the maker's frame. A heap record waited for by `>t` may run
inline. So the frame record also saves psum's 4,095 allocations under `RIG_SEED`, where nothing
inlines, and the 20 seeds test the record's lifetime across interleavings.

## 3. SPEC, CORE, and the docs after

**CORE: no ownership change.** Sentence 6 says a loan lasts until its value's last use, or its drop
when the type has a `drop` body, and `Task` counts as having one (concurrency.md, "Loans and
structure", rule 1). Free fork-join keeps every loan, move, drop and order:
- `>t` still waits for `t`'s end, and the drop still waits or cancels and waits;
- the record's home is representation, as a box's block is;
- running on the waiter's stack only adds frames below frames that the task's loans point into, so
  loans still point down.

CORE never says where a task's stack or record lives. So CORE §10 is not triggered, and AGENTS
North Star 5 holds without a CORE change. The frame record does *rely on* sentence 6 and rule 1: the
drop that ends the loans is also what frees the slot. INTERNALS should say so where it lists the
storage kinds. CORE stays as it is.

**SPEC §18, "Running".** Today it reads "each is a fiber on a stack of its own as large as `main`'s".
It becomes (M1):

> each is a fiber on a stack of its own at least as large as `main`'s, run by a worker thread per
> core (…), with a guard below it at least twice the program's largest frame. A task that no worker
> has started when it is waited for (`>t`) or dropped may run there, on its waiter's stack, when that
> stack has as much room left as the task's own would give it: it is the same task, with the same
> loans, cancel, deadline and panic.

The actor paragraph's "when that stack has room" becomes "when that stack has as much room left as
the actor's own task would give the method" (§5). Under M2, SPEC §1's "a stack of 64 MiB" becomes
"at least 64 MiB".

**concurrency.md, "The engine".** "Fork-join at no cost … is planned" becomes built, with the room
rule in one sentence. ROADMAP loses the item.

**INTERNALS.** Under "Storage facts": `task_record` and its positive list. Under "The program's
stack": `H` and the room check. scheduler.md: the fork queue, inline runs, and the
`RIG_SCHED_STATS` counters. CHANGELOG and HANDOFF.

**Visible to a program:**
- `RIG_SCHED_STATS` counts;
- overflow in the band from 64 MiB to `64 MiB + H`;
- where a debug build's panic trace points: an inline task's frames lie under its waiter's.

The output of a program does not change.

## 4. The oracle

**It learns nothing.** The oracle is a second ownership checker written from CORE. It judges
acceptance, and acceptance does not change:
- no new rejection, because the record's home and inline runs are never reasons to reject;
- no new acceptance, because the positive list only *selects* among programs already accepted.

Its inputs (source and IR) do not change, and it does not model storage or scheduling. So
`test/oracle/rejections` and `differences` stay as they are. `coverage` can only grow, with the new
doc examples. If a builder finds the oracle has moved, a check was weakened or a rejection added, and
either one is a bug.

## 5. The actor room bug (fix the class)

`tasks.roomInline` lets a method run inline when its caller's stack has `len / 4` left: 16 MiB on a
64 MiB stack. The method's own task would give it 64 MiB, so a method that recurses 20 MiB deep
overflows when it finds the actor idle and succeeds when it does not. That breaks North Star 1, and
it depends on timing.

The fix uses the same rule as tasks: the method's proven depth when it is dense-eligible
(`task_depths` can record it for an actor call site as well), else a whole stack, checked against the
room left. Most methods recurse not at all, so they qualify more often on dense callers and the same
on large ones. A method with no bound inlines only from a caller that has used `≤ H`.

It goes in as its own commit, with `bench/actors` shown not slower (AGENTS: correctness before
features).

## 6. Tests

All in a new `test/rig/concurrency-fork.rig.test`. `seeds: 20` exercises frame records across
schedules, though not inline runs, which are off under seeds. `_ = task.workers(1)` as a case's
first line gives `RIG_WORKERS=1`, which exercises inline runs. Each runs sanitized, as the runner
sets.

**Behavior (`test`):**
1. psum with `GRAIN` 64 over 2^14 Ints. `seeds: 20`, and a twin with `task.workers(1)`.
2. qsort over owned Lists, the same pair.
3. A site in a loop body, waited for in each pass; and one dropped at each pass's end (infallible,
   so the drop waits).
4. Early exits between the fork and the wait:
   - `!` passes an error on, and the frame-held fallible task is canceled and waited for;
   - `return`;
   - `break` from a loop.
5. Waited out of order: `t`, then `u`, then `>t` before `>u`. The task waited for is not the newest
   in the deque, so it is not run inline: the waiter parks and the worker's loop runs both as
   fibers. Run it at one worker and with `seeds: 20`.
6. Room:
   - a task that recurses about 48 MiB deep, waited for at one worker from a waiter that has used
     more than `H` (handoff) and from one that has used nearly nothing (inline): both finish;
   - `bomb … "stack overflow"` for a task that recurses past `64 MiB + H`;
   - `release: true` keeps these fast.
7. A channel between the fork and the wait at one worker: `t` sends what `W` receives before `>t`.
   It must not hang, which proves the worker runs its own deque's forks when the maker parks.
8. **Taking turns** at one worker: `t = setter(+flag)&`, then `W` spins on `flag.get() == 0` with no
   waiting point, then `>t`. It hangs if forks are hidden from preemption (§7). `timeout: 30`.
9. Cancel reaches an inline task. A fallible `W` holds `t` inline, and `t` loops on
   `task.check()!`. `W`'s owner drops `W`. Expect `Stop.canceled` to propagate and every `defer` to
   run, in order. Run both `seeds: 20` and at one worker.

**Panics (`bomb`):**

10. A panic in an inline task at one worker. Expect the message, and the line "a task this one
    waited for panicked" once for each level of the chain.
11. Under `task.isolate`, with the frame-held siblings of the panicking task not yet stolen. Expect
    `Stop.panicked`, each sibling canceled and waited for, and a sanitizer-clean run. `seeds: 20`.
12. A deadlock through an actor whose method waits on `t`, where `t` runs inline and calls the
    actor. The deadlock message is the same as with handoff.

**Emit (`code`):**

13. `spawnAt(&__rig_task` for `t = f(x)&; >t`.
14. Plain `.spawn(` for each of these:
    - a returned task;
    - `!ts.add(f()&)`;
    - `u = <t`;
    - an outer `t` assigned again in a loop;
    - `time.within(d, |<t| >t!)`;
    - a record above the 1 KiB cap.
15. The depth argument: a number for a leaf callee, `null` for a recursive one.

**CLI (`test/cli/fork_facts.sh`):**

16. `rig check --facts=storage` lists `task_record` at the site and nowhere for the excluded forms.
17. psum built `--release` and run with `RIG_WORKERS=1 RIG_SCHED_STATS=1`. Assert at least 4,000
    inline runs, and at most 16 stacks taken (M1) or at most 1 (M2). This keeps "psum inlines" from
    rotting silently.
18. Expert B's race torture runs beside these.

**Doc examples, one for each rule:**
- SPEC §18 "Running": a psum example with its output, at one worker;
- SPEC actor paragraph: unchanged in substance, its example stays;
- INTERNALS "Storage facts": a `rig` example of the site form that keeps its record in the frame,
  which only has to check;
- concurrency.md "The engine": the fork-join sentence and the psum example, with its output.

The facts themselves are tested by items 13 to 17, since an output block cannot show them.

## 7. Build order, the language side (each step measurable and revertible)

Expert B owns the runtime steps and Lean models. My steps interleave:
- **L1, the depth fact.** `task_depths` replaces `dense_calls`, and emit passes the depth.
  Behavior-neutral. The emit diff should show only the new argument, and `bench/check`'s guard should
  not move.
- **L2, the frame record.** `task_record`, `spawnAt`, `destroy` doing nothing, cases 3 to 5, 11, and
  13 to 16. It is measurable alone: psum's 4,095 record allocations, cold and warm, at 1 and 12
  workers. It can go in before any inline run exists.
- **B's commits:** the queue, `runHere`, the cancel link, the panic levels, `S + H` stacks.
- **L3.** Inline turned on against the depth, the SPEC §18 sentence, docs, and cases 1, 2, 6 to 10,
  12 and 17.
- **L4.** The actor room fix (§5), alone, with `bench/actors`.

## 8. On runtime.md

Read in full, as Expert B wrote it at 20:46. B and I reached the room rule (f), `H`, M1, the depth
fact, and the positive list independently, and B takes my facts as the runtime's inputs. I checked
each mechanism against the four rules.

### Agreed, and sound as written

- **The room rule and `roomFor`.** The stack pointer is read where `runHere` stands, and the need is
  the depth plus `frame_slack`, else `S`. The waiter's guard stays.
- **One physical fiber.** This is the right choice and the stronger argument. While `t` runs, the
  waiter is in no wait, so no cancel can resume it on frames above `t`'s live ones. A deadlock's walk
  sees the innermost wait. A preemption stops one fiber whose whole stack moves with it, so nothing
  depends on the thread.
- **Panics, level by level in one loop, with no catch point.** This keeps *loans point down*:
  - each level that does not stop the panic passes it on, so no surviving frame resumes above an
    abandoned one;
  - a level that does stop it is an isolate. Its `f` ran on a stack apart, so every younger level's
    frames lie there, and `leaveApart` returns below none of them;
  - `Isolate.at` closes the runner hazard B found.

  *A panic reaches its waiter*: each level writes its "a task this one waited for panicked" line,
  and its held actors die, as a handoff would.
- **Cancel** through `host`, `cancel_below`, and `passCancelDown`. The walk runs only on the fiber
  that owns the frames. It cancels a level's task only where that level's waiter is canceled, which
  is exactly what `waitInto` passes on. A stale bit after `t` ended cancels nothing, so it is
  harmless.
- **Drops and defers keep their order.** The swap saves `drop_depth`, `print_depth` and
  `unwinding`, and saves `drop_queue` too when a drop chain is under way. `t`'s drops run in `t`,
  before the waiter goes on, which is the order a handoff gives.
- **Taking turns** (my blocking finding) is answered:
  - forks stay in the slice rule (`workWaits` reads the deque);
  - `next` takes the worker's own forks before the global queue;
  - `tick` yields to forks after 16 checks;
  - the monitor kicks a sleeper.

  Only the 50 µs two-look rule loses forks, and SPEC promises nothing faster than the slice. My case
  8 stays the test.
- **A task never outlives its scope.** Only the awaited fork is claimed (`popIf` of the newest). An
  out-of-order join parks, and the worker's loop runs the forks as fibers. That is correct, just not
  inline, so my case 5 tests that path (I have reworded it).
- **The deque.** It is separate from the ring, has no fence on the push, the thieves take the oldest
  one at a time, and its wake is lossy and recovered at four points. The progress argument (a maker
  always reaches its join, its drop, a park, or a slice stop) is sound, and Sleep.lean must check it.

### Unsound as written: the isolate releases a frame record before its last write

`Control.finish` (tasks.zig:374) removes the task from its isolate's list first. Then it stores
`done`, reads `wakeup`, and the worker later runs `Header.end`, whose `Done.finish` stores
`ending`, then `ended`. All of these write into the record. With a heap record that order is
harmless. With a frame record it breaks *a task never outlives its scope*.

The sequence:
1. A maker panics.
2. Its stack is abandoned and kept by the isolate.
3. A stolen fork whose record lies in the abandoned frames ends on a thief.
4. `iso.remove` wakes the isolate's stopper (`first == null`).
5. `isolateWith` gives back the kept stacks (`giveBack`, `giveStack`).
6. Another task takes that stack.
7. The thief still writes `done`, then `Done`'s status, into it.

That is a write into a stack in use, and memory corrupted in safe Rig. B's §4 says the isolate
"keeps that stack until every task under it has ended", but the isolate's notion of "ended" (the
list empty) comes before the record's last write.

**Fix (pick one, in commit 1):**
- for a frame record, take the task off the isolate's list as the *last* touch of the record, after
  `Done`'s final store, and have `Header.end` call it; or
- have `Isolate.stop` wait, for each listed record, until `Done` reads `ended`, before
  `giveBack`.

Either way, the rule to write down is: *the release that lets a frame record's stack go, the waiter's
read of `ended` or the isolate's last removal, is the last access to the record.* The same holds for
the stolen fork's `Fiber`, which lives inside the record. After `Header.end`, no worker reads or
writes `f.*`.

Add case 11b: under `task.isolate`, the maker panics while a stolen fork with a frame record runs on.
Use `seeds: 20` and `RIG_SANITIZE`, and give the isolate's caller other tasks that take stacks at
once. Then repeat it in the race torture.

### Unproven, and owed before code

- **`runHere` must read its worker again after the call.** A preemption may move the physical fiber
  to another worker partway through `t`. So after `h.fiber.run` returns, `runHere` must re-read
  `me()` for `inlined`, the deque, and every per-worker field, as `handoff` re-reads `now = me()`.
  The `w` it held before is stale. A unit test should preempt an inline task at two workers.
- **arm64 orders.** The Deque model checks sequential consistency and a TSO variant. arm64 is weaker
  than TSO, and the argument for it rests on `stlr` followed by `ldar` being ordered (RCsc) in
  `popIf` and in `steal`. Say so in the model, and run the race torture on the Mac as well as pup.
  The Zig must use seq_cst for exactly the accesses B lists. If one is relaxed for speed, the model
  must be redone first.
- **The record's `Fiber` beside the maker's live frame.** A thief's switches write the `Fiber`'s
  `sp` and wait word into the maker's frame while the maker computes nearby. That is sound, since the
  addresses are distinct, but it may share cache lines. Expert A's ceiling should look for false
  sharing. B's later "lean record" (the `Fiber` on the thief's stack) also removes it.
- **The waiter's `held` actors during an inline run.** A `t` that calls an actor the waiter holds
  spins (`claimSpinning`), then queues and waits. The walk finds waiter → actor → waiter as one
  fiber. My case 12 must show the same deadlock message, naming the same calls.

### What the Lean models must show

B's four models (Ring `takeLast`, Deque, Sleep with forks, InlineCancel) are the right ones, and Ring
`takeLast` first is right, since it is shipped code no model covers. Add:

5. **Record lifetime** (`Models/FrameRecord.lean`, small explicit state).
   - The parties: the maker or waiter, a thief that ends the fork, and an isolate that stops and
     gives the stack back.
   - The check: no write to a record after the step that lets its stack go.
   - Seeded failure: today's `Control.finish` order, which must report the write after give-back.
6. **An inline run is a schedule.** One lemma beside formal/LambdaRig/Wait.lean. Running `t` to its
   end while its waiter is blocked at `>t` is a trace of the existing task semantics, since the
   waiter is blocked either way. So no orphans, a loan's end at the wait, and an exact deadlock walk
   carry over unchanged. Only the stack is new, and the room rule covers it outside λRig.

### On B's build order

Agreed, and it meets my L1 to L4: my L1 and L2 are B's commit 1, then the stacks, the inline run
on today's claims, the deque, and the monitor. Add two things:
- the lifetime fix and case 11b go into commit 1, because that is where frame records first exist;
- FrameRecord.lean goes in with commit 0.

`bench/check` must stay level at commit 1, since the storage plan walks every use of a task binding
once.
