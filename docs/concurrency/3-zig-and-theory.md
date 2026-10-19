# Concurrency panel 3: Zig `std.Io` reality, soundness, and theory

Reviewing `docs/CONCURRENCY.md` (worktree `concurrency-design`) against
CORE.md, SPEC.md, FORMAL-RIG.md, `formal/`, and Zig 0.17's `lib/std/Io*`.
Zig paths below are relative to Zig 0.17's `lib/std/`.

Panel: **(a)** Zig core contributor, **(b)** PL professor, **(c)** systems/OS professor.

---

## Summary of findings

Holes in the draft, most serious first:

1. **Use-after-free when an actor call that lends is canceled.** The draft says a waiting call may lend `?line` "since the caller is suspended until the answer comes". But under the draft's own cancellation rules, a message is a waiting point. A canceled caller then leaves its frame while the actor still reads `line`, or writes the reply into the caller's stack. Fix: once the message is in the mailbox, a waiting call that lends must wait for the answer without being interruptible by cancel.
2. **The safety of loans in tasks depends on a drop running.** FORMAL-RIG principle 4 says "Safety never rests on a drop running" and rules out "guards whose drop keeps the program safe" (#24292). The draft does exactly that. It can still be sound, because Rig's no-loan homes (Cell, owned closures) stop a value that carries a loan from entering a leakable `*T` cycle. But the draft must either state and prove that lemma or narrow where a `Task` may live. Actors are a second shared mutable home and must be made no-loan homes too.
3. **Sentence 6 ends a loan at the last use of a value, not at its drop, unless the type has a `drop` body.** So `Task` (and drop glue reaching a `Task` in a `List`) must count as having a `drop` body that uses its views. Otherwise `t = f(?v)&` followed by `!v.push(1)` is accepted.
4. **Zig's cancellation is edge-triggered** (Io.zig:1301-1309). In Rig, `x = read() catch ""` swallows the cancel, and the next waiting point does not re-signal it. So "drop cancels and waits" can hang forever. Rig needs level-triggered (sticky) cancellation.
5. **Closures lent to concurrent callers.** `http.serve(":8080", handler)` calls one stack closure from many cores. A closure that captures `!x` can be called through a read view, so two tasks would write `x` at once. The *shares* fact for closures must require no write captures. The draft only covers a closure called *as* a task.
6. **The draft's *moves* and *shares* lists leave out views, closures, `Actor`, `Task`, and Zig-backed types.** FORMAL-RIG already says Zig-backed types *declare* both facts, with no default.
7. **A task whose value is thrown away is canceled at once.** `log(x)&` as a statement is a temporary, so it is dropped at the end of its statement, which cancels it. That must be a compile error.
8. **A dropped `Task[T!]` loses its error silently**, which breaks CORE sentence 10.
9. **`std.Io.Evented` cannot run the target workload today.** Fibers get 60 MiB stacks with no guard page, network streams are TODO on Uring and Dispatch, and Kqueue has no cancel or groups.

---

## 1. Zig `std.Io` reality check (lead: a)

**What it provides.** The `Io` interface (Io.zig:51-245) is a vtable that covers all of these:

- `async` and `concurrent`;
- `Future.await` and `Future.cancel`;
- `Group`, `Select`, `Batch`/`operate`, `Queue`, `Mutex`, `Condition`, `Event`, and futexes;
- `recancel`, `swapCancelProtection`, and `checkCancel`;
- files, net, processes, and clocks.

Two spawn verbs matter:

- **`async`** (Io.zig:2514-2550) *may run the function inline*, before it returns. `Group.async` "is not guaranteed to have been called until `await` or `cancel`" (Io.zig:1360-1362).
- **`concurrent`** (Io.zig:2558-2590) guarantees real concurrency, but can fail with `ConcurrencyUnavailable` (Io.zig:2552).

Rig's `&` promises "starts at once", so it must lower to `concurrent`/`Group.concurrent`. Falling back to running inline, as `async` does on failure (Uring.zig:1428-1441, Kqueue.zig:664-676), would turn producer/consumer code into a deadlock. If concurrency is unavailable, treat it as allocation failure: the same policy as out of memory.

**Backends and how mature they are.**

| Backend | Scheduling | Status in 0.17 |
|---|---|---|
| `Threaded` | A pool of detached OS threads behind one global mutex and run queue (Threaded.zig:2071-2170). `concurrent` takes a thread per busy task with no limit (Threaded.zig:1596, 2150-2162). `async` runs inline past `cpu-1` busy threads (Threaded.zig:1643, 2097-2102). | The most complete, including net (`net_read`/`net_write`, Threaded.zig:2585-2591). Preemptive, because the OS schedules it. No work stealing. A million tasks means a million threads. |
| `Uring` (Linux Evented) | One worker per CPU (Uring.zig:815). Each worker has an intrusive LIFO `ready_queue` (Uring.zig:99, 977-1075). New fibers are pushed to an idle thread over `MSG_RING`. An idle worker steals the **whole** ready list of at most **2** other workers (Uring.zig:60, 927-958). | Experimental. `net_send` and `net_read` return `error.NetworkDown // TODO`, and `net_write` is `@panic("TODO")` (Uring.zig:2106-2120). TCP streams do not work. |
| `Kqueue` (BSD) | Similar to Uring: 4-way stealing (Kqueue.zig:28, 263). | Least mature. `cancel` panics TODO (Kqueue.zig:743-755), `cancelRequested` returns `false` (757-760), and `groupAsync`, `groupAwait` and `groupCancel` are TODO (763-810). |
| `Dispatch` (macOS Evented) | Resumes fibers on a concurrent GCD queue (Dispatch.zig:488, 1095). libdispatch's kernel workqueue does the load balancing. | All four net operations `@panic("TODO")` (Dispatch.zig:1713-1716). |

So Evented does a kind of work stealing on Linux and the BSDs, and delegates it to GCD on macOS. It is not Chase-Lev or Blumofe–Leiserson stealing: it takes whole lists from a fixed number of victims in round-robin order, and the per-worker LIFO has no FIFO fallback (see §4).

**Fibers and stacks.**

- Every fiber is one allocation of a fixed size from the backing allocator. The size is a comptime `min_stack_size` of **60 MiB** on Uring and Dispatch (Uring.zig:256, Dispatch.zig:196) and 4 MiB on Kqueue (Kqueue.zig:90).
- No backend calls `mprotect`, so **there is no guard page**. A stack overflow silently corrupts the next heap block.
- Uring keeps per-thread free lists and steals from them (Uring.zig:272-311). Dispatch frees each fiber with `free` (Dispatch.zig:209-215).
- Context is capped at 1024 bytes and results at 512 bytes, enforced by `assert // TODO` (Uring.zig:253-258, 1450-1454).
- There is no public `yield`.

Consequences:

- A million idle tasks reserve 60 TB of address space. On Linux, a separate `mmap` per fiber also runs into `vm.max_map_count` (65,530 by default).
- Rig's plan to size stacks from frame facts is impossible on these backends, because the size is a constant.

**Cancellation.**

- `Future.cancel` sets a request. The *next* cancelation point returns `error.Canceled`, and later ones do not (Io.zig:1301-1309). That is edge-triggered cancellation.
- `recancel` re-arms the request (1434-1441). `CancelProtection` blocks it for a region (1443-1471). `checkCancel` is a pure cancelation point (1475-1487).
- `Future.await` and `cancel` are **not** cancelation points: they return `Result`, not `Cancelable!Result`.
- Uring's `requestCancel` propagates a cancel into an awaited *group*, but not into an awaited single future (Uring.zig:357-366, 1511-1535). It also asserts that cancel was not already requested.
- `Group.await` is cancelable and propagates the cancel to the group's members (Io.zig:1398-1412).

**What a Tokio-class runtime still needs:**

- stacks sized per task, with guard pages, lazy commit, and a slab for statically bounded stacks;
- Chase-Lev deques with randomized stealing, a global injector, and a LIFO slot bounded by a budget;
- `yield`, and a cooperative budget;
- a pool for blocking or FFI calls;
- pinning tasks to a thread, which local tasks and macOS main-thread UI need;
- level-triggered cancellation;
- timers on a wheel;
- an MPSC mailbox that does not take a mutex (`TypeErasedQueue` is mutex-based, Io.zig:2074);
- a waits-for graph, for deadlock detection and priority inheritance;
- finished network operations;
- tracing.

**Recommendation: write Rig's own `std.Io` implementation, its own vtable, beneath the interface.** Rig would own the scheduler. It would fork the operation code of Uring, Kqueue and Dispatch, and contribute fixes upstream. Zig std code and Zig-backed Rig declarations run on it unchanged, because they only see `Io`. For step one, build on `Threaded` exactly as the draft says: it is complete and preemptive. Do not plan step four on 0.17's Evented.

**Lowering.**

- **`t = parse(?text)&`** becomes:
  - a `Task` block that never moves, holding `{ group: Io.Group, result: T, state }`; Rig moves `Task` values freely, but Zig needs a stable `*Group`;
  - a call to `group.concurrent(io, entry, .{ctx_ptr})` that passes a single pointer to an argument frame inside the block, which avoids the 1 KiB and 512 B asserts.

  A group of one is better than a `Future` because `Group.await` propagates the parent's cancellation to the child.
- **`<t.wait()`** becomes `group.await`, then reading `result`.
- **Dropping a task** becomes `group.cancel`, which is uncancelable and waits.
- **`Task` has two forms:** one backed by a fiber, and one backed by a promise (an actor reply). So `!a.m()&` costs no extra fiber.
- **`Actor[T]`** is a block with an atomic count: `{ rc, state: T, mailbox: Queue(Msg), runner: Task }`. `Msg` is a tagged union of method arguments plus a `*Reply` (a result slot and an `Io.Event`). The runner loops on `mailbox.getOne` and switches on the method.
- **A waiting call** puts the message, then waits for the `Reply` *uncancelably* whenever the message lends, or keep the reply on the heap.
- **Backpressure** comes from `Queue.put` blocking (Io.zig:2384-2410), which is FIFO for putters.

---

## 2. Soundness (lead: b, with a)

**2.1 Tasks keep their arguments' loans; drop cancels and waits.** This is `std::thread::scope` with an affine handle. It is sound in Rust only because the handle cannot be forgotten. Rust's `JoinGuard` failed (#24292) because `mem::forget` and `Rc` cycles were safe.

Rig has no `forget`, and its only leak is a `*T` cycle (SPEC.md:6629). Such a cycle needs mutation through shared storage. Cell is a no-loan home, and "a `*T` carries the loans of what it holds" (CORE sentence 9). So a value that carries a loan cannot enter a cycle, and so cannot leak. **The design is sound if four conditions hold:**

- **(i) `Task` counts as having a `drop` body that uses its views.** Without this, CORE sentence 6 ends the loan at the task's last use, which may be the very line that made it.
- **(ii) Actors are no-loan homes.** An actor's fields and `spawn` arguments carry no loan, and methods called through a handle have no `keeps`. Otherwise an actor (shared, mutable, counted, able to form cycles) becomes the leak path.
- **(iii) Drops and `defer`s at a scope's end are checked in their real order.** `t = f(?x)&; defer clear(!x)` must be rejected, because the `defer` runs before `t` drops.
- **(iv) Panic aborts the whole process.** It already does: status 134 and no drops (SPEC.md:9501-9512). Workers should stop at their next scheduling point, so they do no further I/O.

**Escape routes:**

- **Returned or stored tasks** follow CORE sentence 7 and `keeps`, and are fine.
- **Closures:** owned closures are no-loan homes, so only loan-free tasks can enter them.
- **Loan-free tasks can leak** through `Cell`→`*fun`→`Task` cycles or actor-handle cycles. That is not a safety issue, but "no orphans" is then false. Main's end must cancel and wait for a root group before the leak check runs, which Zig needs anyway (Uring.zig:907-910 asserts no pending async).

**FORMAL-RIG principle 4 needs amending to:** "safety never rests on dropping a *loan-free* value." Alternatively, forbid `Task` behind `*`, `Cell` and actor fields altogether. The panel prefers the amendment, with the lemma "no value that carries a loan is ever leaked" as a stated proof obligation.

**2.2 Are *moves* and *shares* enough?** The structure matches Send/Sync:

- `?x` to a task needs `shares` (`&T: Send ⇔ T: Sync`);
- `!x` and `<x` need `moves`.

Missing rules:

- **Views:** `?T` moves and shares iff `T` shares; `!T` moves iff `T` moves and never shares.
- **Closures:** a stack closure shares iff it captures no `!` view and every capture shares. This is the Fn/FnMut distinction, which FORMAL-RIG says Rig doesn't need. It needs it only here, as a fact.
- **`Actor[T]`:** moves and shares.
- **`Task[T]`:** moves iff `T` moves and its loans' views move; never shares.
- **Zig-backed types:** declared, never derived (FORMAL-RIG §4).

On interior mutability:

- `Cell` and `Signal` are the only interior mutability, and neither crosses.
- `*T` reached through a shared view: the *shares* fact of an object that holds a `*T` is false, so the view is rejected.
- Moving a `List` to another core means it is freed there, so the global allocator must be thread-safe (state this).
- Lending disjoint fields to two tasks is fine only while objects are never emitted as Zig `packed struct`s. Otherwise the two "places" are bits of one word.

**2.3 Is `!actor.m()` sound and honest?** It is sound: the actor serializes its methods, so the body's `!@` is exclusive. It is honest in the same way `!c.set()` on a Cell is: the `!` marks a change to shared storage, not a lend.

Two things the mark does not show:

- **The call is a waiting point.** It can be canceled, can deadlock, and lets other tasks interleave. The same is true of a bare `?@` call.
- **A canceled caller may still see the change happen.** Specify it: canceling the caller never cancels a method that has started. A message that has not started is removed from the mailbox.

**The real hole is lending to an actor (finding 1).** The caller has to wait for the reply without being interruptible by cancel, because the actor may still be reading the lent view.

**2.4 Deadlock.** Non-reentrant, one-method-at-a-time actors with synchronous calls deadlock on any cycle, including an actor that calls its own handle. Bounded mailboxes add cycles even with `&` sends.

Swift's answer, reentrancy at every `await`, trades deadlock for broken invariants. The panel recommends keeping Rig non-reentrant, as Erlang's `gen_server` is, with **exact detection at runtime**:

- An actor or task waits on at most one target, so the waits-for graph has out-degree ≤ 1.
- On blocking, publish your edge (seq_cst), then walk the chain. A cycle is found in O(length).
- Publishing before walking means the last party to join a cycle always sees it.
- Report `error.Deadlock`, or panic, at the call that would close the cycle. That is far better than "every task is waiting", which misses partial deadlocks inside a live server.
- Statically, whole-program checking allows a lint over the call graph between actor *types*: A's methods call B's and B's call A's. Prevention by types (Pony: no synchronous replies) costs too much expressiveness.

**2.5 Cancellation, `defer`, `errdefer`.** Stackful tasks remove Rust's cancel-safety problem: there is no future dropped at an arbitrary `.await`. Cancellation is just an error at a waiting point, and `errdefer` cleans up. Three problems remain:

- **Edge triggering (finding 4).** Make cancellation sticky: every waiting point fails while the task is canceled, as Trio's cancel scopes do. Lower this with `recancel` after any `catch` that handles `Canceled`, or with a flag in Rig's own `Io`. Waiting while dropping a task during cleanup must be uncancelable; `Future.cancel` already is.
- **The draft contradicts itself on `wait`.** It calls `wait` a waiting point that fails with `Canceled`, yet `<t.wait()` on a `Task[Int]` gives `Int`. Choose: `wait` is not a cancelation point, but it *propagates* the parent's cancel to the child (the lowering through `Group.await`). The child's result type then carries the cancellation.
- **Actors never see their caller's cancel mid-method.** So an actor's state is left partial only by its own errors, never by cancellation. State this as a guarantee.

---

## 3. Structured concurrency (lead: b)

Trio's nursery gives three properties:

1. **The black-box rule:** when a call returns, its concurrency has ended.
2. **Errors propagate:** a child's failure cancels its siblings and reaches the parent.
3. **Cancel scopes nest, with deadlines.**

"The scope is the group" gives (1) for tasks held in locals. It is Swift's `async let`: un-awaited children are canceled and awaited at the scope's end.

**Returning a `Task`** weakens (1), but visibly: `-> Task[T]` is in the signature, ownership stays a tree, and loans follow `from`. Allow it. It is how a library hands back work in flight.

**Missing: (2) and (3).**

- With `a = f()&; b = g()&; <a.wait()!`, a failure in `b` goes unnoticed until `a` finishes.
- Every fan-out of fallible tasks needs to fail fast. So `std.Group` with `wait_all()!` (cancel the rest on the first error) and `first()` belongs in **the first wave**, not "if programs show a need".
- Timeouts are cancel scopes: `within(d, || ...)`, which `std` can build from `select(sleep, op)`.

**Rules for fallible tasks:**

- Reject a `Task[T!]` dropped unconsumed on the normal path, because its error would vanish.
- Allow the implicit drop on an error path; the first error wins, as in Trio.
- Make cancel consuming and returning, as Zig's does: `<t.cancel()` gives `T!`.
- Reject a discarded `call()&`.
- No `group` keyword is needed.

---

## 4. Scheduling (lead: c)

**Fairness and starvation.**

- Uring's per-worker LIFO with no FIFO fallback lets two tasks that ping-pong stay ahead of older ready fibers indefinitely.
- Tokio bounds its LIFO slot and checks a global queue every 61 ticks. Rig's runtime should do both.
- Blocked senders should be admitted in FIFO order (Zig's `Queue` already does this). Specify it.

**CPU-bound tasks.**

- With N workers, N tasks that compute without waiting starve every I/O task.
- Go was cooperative-only until 1.14 and added signal-based preemption for exactly this reason (tight loops stalled GC and latency).
- Rig controls code generation, so it can insert a cheap budget check at loop back-edges and at the entry of recursive functions in code reachable from a task. That costs one decrement and a predictable branch, and is Go's pre-1.14 safe-point scheme made reliable.
- Add `yield()`, a blocking pool for FFI and CPU work, and a monitor that adds a worker when one is stuck for more than about 10 ms.
- Note that step one on `Threaded` is preemptive, so measurements there will flatter fairness on Evented.

**Work stealing.**

- Blumofe–Leiserson randomized stealing gives T_P ≤ T₁/P + O(T∞) expected time and S_P ≤ P·S₁ space, for *fully strict* computations. Rig's structured tasks, joined by their owner, are fully strict, and returned tasks are still strict.
- The space bound needs **work-first** spawning, where the child runs at once and the parent's continuation becomes stealable.
- Stackful fibers make work-first cheap, since the continuation *is* the parent fiber. It also matches "starts at once" literally.
- Zig's help-first push to an idle thread means a loop of a million `&`s allocates a million stacks eagerly.
- Use Chase-Lev deques with random victims, stealing one task (or half), not the whole list.

**The cost of a stack per task.**

- Rig cannot move stacks, because views and Zig pointers point into frames. So stacks have a fixed size.
- An idle task's floor is one committed page plus guard address space: 4 KiB on x86, **16 KiB on Apple Silicon**, so about 16 GB for a million idle tasks on a Mac. Tokio uses hundreds of bytes per task.
- **Rig's edge is statically bounded stacks.** They need no guard page and can come from a slab at near-Tokio density.
- The bound must come from the *emitted* code: LLVM's `.stack_sizes` section or `-fstack-usage`, checked at link time. Inlining, debug builds, Zig std frames and signal handlers make an estimate from Rig's IR unsafe. A wrong bound with no guard page is memory corruption.
- Everything else gets a lazily committed reservation (64–256 KiB) with a guard page.
- Restate the "million idle tasks" target honestly.

**Priority.** Leave priority out of v1, but make the waits-for graph (§2.4) carry priority inheritance. An actor that a high-priority caller waits on runs at that caller's priority, as with Swift actors and GCD QoS overrides. Otherwise a FIFO mailbox is a textbook priority inversion.

**Memory model.** User code is data-race-free by construction, so by DRF-SC (Adve–Hill) it sees sequential consistency. The happens-before edges to specify are:

- spawn → the task's first step;
- the task's last step → `wait` returning;
- a send → the method it starts;
- the method's return → the caller resuming.

The runtime's release and acquire operations are the only atomics. That is the whole memory model.

**Local tasks.** Rig targets GPUI-style apps full of `*T` and `Cell`. The draft drops FORMAL-RIG's "local group", so no `*T`-holding UI code can use tasks at all. Restore local tasks pinned to their creator's thread; pinning is another reason to own the scheduler. The main thread must stay pinned for AppKit. FFI libraries with thread-local state (OpenSSL's error queue) also break when a fiber migrates.

---

## 5. A minimal core calculus (b and c)

Everything derives from four primitives:

1. **`fork e` → an affine `Task[T]`** with join (`wait`), carrying loans, where drop means cancel and join;
2. **level-triggered cancellation** of a task, with an uncancelable region;
3. **park and unpark** (a futex or one-shot event), with release and acquire;
4. **atomic choice** among events, CML-style: `sync(choose[e1, e2, ...])` commits exactly one.

What derives from them:

- **Channels:** a ring buffer with park and unpark.
- **Actors:** a task, a bounded channel, and one-shot replies.
- **Groups:** a list of tasks plus choice over their completions.
- **Timeouts:** choice with a sleep event.
- **`select`:** choice itself.

Building `select` as a race of tasks, as Zig's `Select` does, loses messages: a loser may already have received one, and `Select.cancel` hands back the completed results (Io.zig:1621-1645). That puts the burden on the user. CML or Go-style commit avoids it.

**In the language:**

- `&` and `Task`;
- the loan rules for tasks;
- the *moves* and *shares* facts;
- cancellation semantics;
- the dispatch rule that a method call through `Actor[T]` is a message.

**In the library:** Channel, Group, select, timeout, supervisors, and arguably actors themselves. Minimality suggests no `actor` or `spawn` keywords: `c = Actor(Counter(hits: 0))` over any `obj` whose type moves, with the compiler giving method calls through `Actor[T]` message semantics. That saves two keywords and a declaration form.

---

## 6. What to formalize (b)

The structure fits λRig (the `formal/` slice proves `accepts_runs` for boxes and views). In order of value:

1. **Data-race freedom of *moves* and *shares*.** Extend `Machine` with thread ids on loan tags and an interleaving semantics where fork is a step. Prove that two threads never touch one cell where either access is a write. This is the theorem FORMAL-RIG stage 3 already lists. With no atomics in user code, sequential consistency suffices, so it needs no weak memory.
2. **No value that carries a loan is leaked.** Prove it from the rules for no-loan homes. This is the lemma that keeps the drop-based scope sound, and it replaces principle 4. FORMAL-RIG already notes that Iris cannot state leaks; Iron or explicit heap accounting can.
3. **No orphans.** At every `wait` and at scope exit, the set of live tasks forms a tree rooted at the live frames. With loans, a child's tag stays live until its join.
4. **Deadlock detection is exact.** In a functional waits-for graph, the walk after publishing finds every cycle. This is a small standalone Lean proof.
5. **Cancellation reaches a dropped task.** With level-triggered cancellation and fuel, a canceled task reaches its end within finitely many waiting points. This is a liveness proof, so do it last.

The runtime's queue, mailbox, and deque are Zig-backed declarations, so they belong to stage 4: iRC11, or model checking with GenMC.

---

## Recommended changes to CONCURRENCY.md

1. **Lending to an actor:** a waiting call that lends must wait for its answer even when canceled. A message that has not started is withdrawn instead. Canceling the caller never cancels a method that has started.
2. **`Task`'s `drop` body uses its loans** (CORE sentence 6), including through drop glue in `List` and `^`. Add the `defer`-order example as a rejected case.
3. **Actors are no-loan homes:** `spawn` arguments are loan-free, and no method with `keeps` or `from` can be called through a handle.
4. **Amend FORMAL-RIG principle 4**, and add "no value that carries a loan is leaked" as a stated lemma.
5. **Cancellation is level-triggered (sticky).** `wait` propagates cancellation and is not itself a cancelation point. Fix the contradiction with `Task[Int]`.
6. **Complete the facts:** views, stack closures (no `!` captures in order to share), `Actor`, `Task`, and Zig-backed types declared.
7. **Reject a discarded `call()&`,** and reject an unconsumed `Task[T!]` on the normal path. Make cancel consuming: `<t.cancel()` gives `T!`.
8. **Move `std.Group` (fail fast, first-of) and timeouts into wave one.**
9. **Deadlock:** exact detection at runtime over the waits-for graph, plus a lint over the call graph between actor types.
10. **Runtime:** Rig's own `std.Io` implementation and scheduler:
    - Chase-Lev work-first stealing, a fair global queue, a budget at back-edges, `yield`, and a blocking pool;
    - pinning;
    - stacks with guard pages, or slab stacks whose bounds are verified from `.stack_sizes`.

    Note in the document that 0.17's Evented lacks network streams, guard pages, and (on Kqueue) cancellation.
11. **Restore local, pinned tasks** for `*T` and `Cell`.
12. **State the happens-before edges**, the thread-safe global allocator, and the program-exit root group.
13. **Consider `Actor(obj)` instead of the `actor` and `spawn` keywords.**
