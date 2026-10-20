# Review 4: an adversarial review of CONCURRENCY.md

> **History.** This is a review of an early draft of the concurrency design. The design as built is [docs/design/concurrency.md](../../design/concurrency.md), the rules are in [SPEC.md §18](../../../SPEC.md#18-tasks), and the review of the model as built is [docs/design/concurrency-panel](../../design/concurrency-panel/README.md). It is kept as written.

Reviewer: a senior concurrency-runtime engineer and a programming-language
theorist, asked to break the design before it is built. Findings are
ranked by severity. Each has a scenario and a proposed fix. Paths are
relative to the Rig repository.

## A. Soundness

### A1. `Task[T]` hides its loans from a type-based checker (use after free)

The checker decides whether a value carries a loan from its *type*:
`ownership.zig` `mayCarryLoan` calls `sema.mayHoldView`, which is true only for
a type holding a marked view or a `?String`. The no-loan homes check the
same way. SPEC §10 (Cell) says what goes in "holds no `?T`, `!T`, or slice,
nor a `?String`", and owned closures use the same test. `Task[Int]` holds
none of these, yet `sum(?x)&` carries a loan on `x`.

```text
sub run(c: *Cell[Task[Int]?])
  x: List[Int] = List()
  !c.set(sum(?x)&)      # accepted: Task[Int] names no view
# run returns and frees x; the task, still held by c, reads x
```

No cycle is needed. A `*B` whose field is a `Task` passes the same way,
and so does an actor field or an owned-closure capture `|<t|`. Rule 3
("no shared home holds a loan") is sound only if the checker knows a
`Task` may hold a loan. Unless `Task` is taught to the checker as
view-holding, its loans may not be tracked at all.

**Fix.** `Task[T]` always *may hold a view*, as `?String` does. So a task
is never in a Cell, an owned closure, an actor's state, or a Chan. This
also removes the loan-free task leaks through `Cell`/actor cycles, which
makes proof obligation 3 ("no orphans") true instead of false, and makes
rule 5 easy to state. An actor that needs background work owns it in a
method's frame, or later through a separately designed loan-free task type.

### A2. `Chan` and `Atomic` are shared homes missing from rule 3, and the crossing table lets `*T` cross

- The table gives `Chan[T]` and `Atomic[T]` *moves: yes, shares: yes*
  unconditionally. A task can make a `*Node`, clone it, and send one
  clone on a `Chan[*Node]` to a task on another core. Then two cores
  change one non-atomic count, which is a data race.
- `Chan` is interior-mutable and changed through a shared path, but rule 3
  lists only Cell, owned closures, and actors. A Chan can sit in a value
  behind `*` (`*H(ch: ...)`) and receive `+h`, which closes a cycle. If its
  element carries a loan, that is A1's use-after-free again.
- `Atomic[T]` for a non-word `T` (`Atomic[String]`, `Atomic[*T]`) is
  undefined.

**Fix.**
- `Chan[T]` moves and shares only when `T` moves.
- `Atomic[T]` is only for plain, word-sized `T`.
- Restate rule 3 by property: every type that changes through a shared
  path (Cell, Signal, Chan, Atomic, Actor, and any Zig-backed type that
  declares *shares*) is a no-loan home.

### A3. The inline fast paths overflow exact, unguarded stacks

Principle 6 gives proven-bound tasks "an exact slab with no guard page".
Both inline paths run code on a stack whose bound did not count it:

- **Join-inline** runs `T`'s frames on top of the waiter `W`'s stack. `W`'s
  proven bound covers `W`'s own call graph, not `T`'s.
- **Idle-actor-inline** runs the method on the caller's stack. A chain of
  actors of one type is fine as instances, since there is no cycle, so
  deadlock detection never fires. For example, `Node.forward` calls
  `@next.forward()` down a list of 10,000 `Node` actors that are all idle.
  Each call nests on one stack, which is unbounded recursion through a
  handle. With no guard page, it silently corrupts the neighbouring slab.
- **Signal frames** (a profiler, a C library's handler, or the
  sanitizer's) land on the current stack unless the handler uses
  `SA_ONSTACK`. An exact slab has no room for them.

**Fix.**
- Inline only when the stack left is at least the callee's proven bound;
  otherwise switch to the task's own stack or post to the mailbox.
- Treat a call through `Actor[T]` to the same actor type as recursion in
  the stack analysis.
- Give exact slabs a red zone at least the size of the platform's largest
  signal frame, and install a per-worker `sigaltstack`.
- Never inline a task pinned to another thread (decision 12).

### A4. Idle-actor-inline breaks "a started method runs to its end"

An inline method runs on the caller's fiber, with the caller's task
identity. If that caller is canceled, its sticky `Canceled` fails the
method's *own* fallible waits (`!@db.write(...)!`). That interrupts the
method partway, which the design promises never happens. The method also
spends the caller's budget and, for a local task, pins the actor's work to
the GUI thread.

**Fix.** On inline entry, switch the current task's cancel flag, budget,
and wait-for record to the actor's, and restore them on exit. Inline only
for callers that are not local tasks.

### A5. Nothing bounds an actor call or a cleanup (hangs)

- **Actor calls cannot time out.** They are infallible and run to the end,
  and the reply slot lives on the caller's stack, so a caller can never
  give up. A method stuck on a peer that never answers hangs:
  - every caller of that actor;
  - every owner that cancels one of those callers, since cancel waits;
  - finally `main`'s end, under rule 5.
- **Cleanup is shielded with no limit.** A canceled connection whose
  `drop` writes a close frame to a peer that never reads waits forever,
  and so does every owner above it.
- **`within:` and `wait_first` cannot bound `Task[T]`.** An infallible
  task never sees a cancel, so `wait_first` over `Task[T]` costs as much as
  `wait_all`, and the deadline is not met.

**Fix.**
- Add `within:` to actor calls. A timed call that lends nothing keeps its
  reply slot in the message, so it may be abandoned: a not-yet-started
  message is withdrawn, and a started one finishes and its reply is
  dropped.
- Shielding holds off *cancel* but not *deadlines*. A cleanup runs under a
  grace deadline (default chosen by the runtime, settable).
- Make `wait_first` and `within:` over `Task[T]` a lint, or a rejection.

### A6. Sticky cancel does not end tasks, and the checkpoint rule writes failures nobody wrote

- **Sticky cancel can spin forever.** In `while true` with
  `line = read() catch ""`, each read fails at once, forever. The task
  never ends, so its owner's drop hangs. Proof obligation 5 is false as
  stated.
- **"A canceled task with a fallible result fails there" breaks CORE 10.**
  A checkpoint at a loop back-edge would be a failure point that is not
  written ("failing is always written"). It cannot fail at all inside an
  infallible callee such as `sort(!xs)`, which has no error path to fail
  through.

**Fix.**
- Checkpoints only yield.
- Add one std function, `task.check()!`, which yields when the budget is
  spent and fails with `Canceled` once canceled. It is the written
  cooperative point, and it is also `yield`.
- Restate obligation 5 as "after a cancel, every fallible waiting point
  fails".
- In debug builds, a watchdog reports a canceled task still running after
  N ms.

### A7. The existing runtime's globals break task confinement

`src/runtime.zig` keeps process-wide, unsynchronized state:

- `drop_queue` and `drop_depth`, which defer `*T` releases past 256 levels;
- `stdout_buffer` and `print_depth`;
- `stack_guard`, which holds one guard range;
- `sanitizer` and `leak_checker`.

Now that a `drop` body can wait, a deep `*Node` release can suspend with
boxes still in `drop_queue`. Another task on that worker then drains
them: it changes the first task's non-atomic counts while that task
resumes on another core. So "`*T` is confined to one task" is false in
the runtime as it stands. Panel 1 named this ("no runtime TLS held across
suspension"), but the synthesis dropped it.

**Fix.** Move the drop queue, drop depth, and print nesting into the task
context. Make the stdout buffer per-worker, flushed by line under a lock.
Keep one guard range per stack. Audit every global and threadlocal before
step 1.

## B. Contradictions with Rig's rules and syntax

### B1. `!` through a read view

`|?hits, ?rooms, req|` captures read views. Then `!hits.add(1)` and
`(!rooms).join(...)` change state through them. SPEC §10 says:

> "A read view of a handle, or of a value that holds one, is not lent to
> write at all: `?` changes nothing."

It rejects `!c.set(...)` through a `?Cell`. CORE 4 says "`?` promises that
nothing changes".

There is a lowering hazard too. INTERNALS gives `ReadView(T)` as a *copy*
for scalars, so an `Atomic(0)` treated as a plain word is copied, and every
add is lost.

**Fix.** Amend CORE 4 and 9 openly: a *synchronized* type (Atomic, Chan,
Actor) changes only by a marked call, through any view; there the `!`
marks the change and lends to read. Make these types `unique`, never
copied and never lowered by value. Say so in the error text, because
users will ask why `?Cell` differs.

### B2. `Task[Page!]` is not a valid type

SPEC §13: "A fallible type is only allowed as the return type of a
function or of a function type". `Task[Page!]` and `List[Task[Page!]]`
break this.

**Fix.** Make `Task`'s argument the one stated exception.

### B3. A task holds what no Rig value may hold

- `f(!x)&` makes a value holding a write view. CORE §5 says no part is a
  write view, and Lists hold no write views.
- `http.serve` must spawn `f(req)&` with `f: ?fun(Req) -> Resp`, which
  makes a task holding a callable view. SPEC §11 says "no value holds a
  callable view", and "a closure literal is not lent to a call whose
  result could hold it".
- The callee cannot know that `f` *shares*. A `?fun` type is opaque, and
  per-instance checking (FORMAL-RIG principle 2) does not reach inside
  function types. So `http.serve` and `par.map` cannot be written in Rig.
- Panel 1, item 5, asked that a loan-holding task be a second-class view.
  That was dropped.

**Fix.**
- A task carrying a write loan or a callable view is second-class, as a
  stack closure is: it may be bound to a local and waited for, but not put
  in a List, a field, or a result.
- Parallel mutation of disjoint elements goes through
  `par.each(!xs, f)`.
- A function type can say it may be called from many tasks at once, for
  example `?fun&(Req) -> Resp`. That is the one place a programmer writes a
  crossing fact.

### B4. The examples

- `list = !@members.entry(<room)` uses a write call's value, so the long
  form is required: `(!@members).entry(<room)` (SYNTAX §5).
- `Map` is `hash.Map`.
- `!tasks.push(score(?d)&)` puts `)` against the `&`, against the design's
  own rule "nothing touching it on the right". Say "no operand".
- `req.arg("room")` presumably gives a view or an optional, but `join`
  takes an owned `String`.

### B5. Conflicts with FORMAL-RIG

- Principle 6 says concurrency is "tasks and channels".
- The plan made actors "a task and its channel" in `std`, adding "no rule
  to prove".
- Principle 5 caps the Core at 12 rules and 600 words.

The design adds actor rules, five soundness rules, cancellation rules, and
the crossing table, and retires nothing.

**Fix.** Say which principles change, and count the Core budget.

## C. Minimality: what is missing

### C1. A `List` of tasks is not a group

- **It never reaps.** A server loop that keeps background tasks
  accumulates finished ones forever.
- **No fail-fast across different result types.** In
  `u = user()&; o = orders()&; <u.wait()!; <o.wait()!`, an immediate
  failure of `o` waits for all of `u`. Panel 3 flagged this case.
- **Drops add up.** A List's drop glue drops tasks one at a time, so the
  cancel latencies add (panel 1 asked for a two-phase drop).

**Fix.**
- One std set: `!ts.add(f()&)`, which drops finished infallible tasks,
  cancels the rest on the first error, and is waited by `<ts.wait()!`.
- A form over several results: `u, o = task.both(<tu, <to)!`.
- The drop glue of a task container cancels every task first, then waits.

### C2. An `Atomic` or `Chan` cannot be shared past one scope

Actors take no loans, and no thread-safe counted handle is planned. So a
metrics counter used by actors costs a message, which defeats the stated
reason for `Atomic`. A `Chan` cannot connect an actor to a task.

**Fix.**
- Module-level `Atomic` and `Chan` statics, which carry no loan, as
  `Static` does.
- `Chan` as counted `Sender` and `Receiver` handles.

### C3. Other gaps

- **A block deadline** (a cancel scope): `time.within(d, || ...)` covering
  sequential calls. Panel 2 recorded this dissent.
- **Backpressure for `&` loops over unbounded input.** One task per URL
  costs 16 KiB on Apple Silicon. Make `par.each(limit:)` the idiom, and
  lint the unbounded loop.
- **What `&` does when it cannot get a stack or thread.** `Threaded`
  stops at about 8,500 threads on macOS. Make it panic, as running out of
  memory does.
- **Process shutdown.** A SIGINT cancels `main`.

### C4. Deadlock detection is "exact" only in part

- A Chan receive, a `select`, and `wait_first` wait on *any of* several
  things, so a single wait-for pointer cannot see those cycles.
- The design dropped panel 3's protocol (publish the edge seq_cst, then
  walk). Without it, two cores closing a cycle at once each miss it.
- The holder of an actor that is running inline must be recorded.

**Fix.** Scope the claim and obligation 4 to single-target waits, and
state the protocol.

### C5. Memory model

The ordering edges omit user `Atomic`, `Chan`, the acquire of an
idle-inline actor, and delivery of a cancel. "The runtime's own atomics
are the only others" is false once `Atomic` exists.

**Fix.** `Atomic` operations are seq_cst only, so DRF-SC still holds.

### What collapses

- `yield` and an explicit cancellation point become one function,
  `task.check()!` (A6).
- An idle-inline actor *is* a FIFO mutex with deadlock detection. Say so,
  and the "no Mutex" decision needs no further argument.

## D. Performance claims

- **Back-edge checks.**
  - "Bounded loops need none" leaves a 10⁹-iteration bounded loop owning
    a core.
  - A check in an inner loop is an early exit, which stops LLVM's
    vectorizer.
  - Go dropped back-edge checks for signal-based async preemption (1.14).

  **Fix.** Count iterations and check in the outermost loop of a nest,
  or preempt by signal at safe points, with the runtime marking its own
  regions (allocator, scheduler) as not preemptible.
- **Proven-stack density applies where it matters least.** Any task that
  allocates or prints calls through Zig vtables (`Allocator`,
  `Io.Writer`), so a bound needs whole-program resolution of indirect
  calls. The million-idle-connections case parses, allocates, and often
  recurses, so it will not be proven.

  **Fix.** Say "leaf compute tasks", not "near Tokio's density".
- **Work-first.**
  - Under stackful tasks it saves no stack. The child still needs its own
    stack, because stacks never move and the parent's continuation may be
    stolen.
  - The Blumofe–Leiserson space bound holds for fully strict compute
    without blocking waits, not for I/O tasks.
  - Under work-first a task is almost never "not started", so join-inline
    rarely fires. Pick one, or explain how the two interact.
  - Join-inline must be off inside `wait_first` and `within:`.
- **The ring.** "Only stealing takes a compare-and-swap" is not Tokio's
  queue: `queue.rs:390` CASes on the owner's pop. Chase–Lev needs a fence,
  and a CAS on the last element.
- **Idle-inline fairness.**
  - "Idle" must mean not running, not scheduled, and with an empty mailbox,
    or an inline caller barges ahead of queued messages.
  - After an inline method, the caller must not drain other clients'
    messages, which would hurt its tail latency; it wakes the actor's task
    instead.
  - Hot actor state moves between cores' caches.

## E. Ergonomics

1. **Infallible tasks cannot be canceled**, but users will expect
   `<t.cancel()` to stop a `Task[Int]`. Put "a task can be canceled only
   if its result can fail" in the model's first section.
2. **`Canceled` and `Timeout` widen every error set.** With declared sets
   (`-> T!E`), an exhaustive `match err` breaks. Say that both join every
   set of a fallible waiting function, and that `match` needs no arm for
   them.
3. **`!` through `?` for synchronized types only** will puzzle users who
   know `?Cell`. The amended rule (B1) needs its own error text.
4. **Fire-and-forget needs an owner.** `log(e)&` is rejected, and binding
   it cancels it at scope end. The set from C1 is the answer; show it in
   the document.
5. **`<t.wait()!` and `!tasks.push(f(?d)&)`** read densely but follow
   Rig's sigils. Keep them; `par.map` and the set from C1 cover most fan-out
   without them.
