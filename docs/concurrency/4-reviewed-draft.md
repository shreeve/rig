# Concurrency in Rig: the draft review 4 attacked

The draft of [CONCURRENCY.md](../CONCURRENCY.md) that
[the adversarial review](4-adversarial-review.md) attacked, kept for the
record. The current design is CONCURRENCY.md.

**A proposal for discussion. Nothing here is built.** It draws on three
expert reviews: of Tokio's runtime source; of Go, Erlang/BEAM, Java Loom,
.NET, and JavaScript; and of Zig 0.17's `std.Io`, structured-concurrency
theory, scheduling theory, and soundness. Their full reports are in
this directory. Decisions are listed at the end, each with the answer
this document assumes. Once they are settled, the examples become
```` ```rig pending ```` blocks and SPEC gains the rules.

## The model

A programmer learns three things, and the checker enforces a fourth:

1. **A task.** `f(x)&` runs a call at the same time as the code after it
   and gives an owned `Task[T]`; `<t.wait()` takes its result.
2. **A task belongs to its owner.** A task never outlives the value
   that holds it. Dropping a task that was not waited for cancels it and
   waits for it, so a scope, or a list of tasks, is the group, and a
   task may read and write its caller's data in place.
3. **An actor.** `Actor(x)` moves a value into a task of its own and
   gives a shared handle to it. A method called through the handle is a
   message, and the actor runs one at a time, each to its end.
4. **What may cross.** The checker knows, for every type, whether its
   value may move to another core and whether it may be read from two
   at once. A programmer meets these facts only as error messages.

Everything else is a library on these: waiting for all or the first of
many tasks, timeouts, channels, atomics, and supervision.

What a programmer never writes: threads, fibers, async functions,
`await`, `Pin`, locks, cancellation tokens, `'static` bounds, or `Arc`
around data a task only needs to read. A function that waits on a socket
is an ordinary function, and calling it is an ordinary call. Serial code
is the default; concurrency is the marked case, `&`, exactly where it
happens.

## What a program writes

Score every document in parallel, each task reading its document in
place, with no copy:

```text
docs = load_docs()
tasks = List[Task[Int]]()
for d in ?docs
  !tasks.push(score(?d)&)
scores = <tasks.wait_all()
print(sum(?scores))
```

Fetch pages, failing fast and giving up after two seconds:

```text
fun fetch_all(urls: ?List[String]) -> List[Page]!
  tasks = List[Task[Page!]]()
  for u in urls
    !tasks.push(http.get(?u)&)
  <tasks.wait_all(within: time.seconds(2))!
```

The first error, or the deadline, cancels the rest and waits for them.

A server whose handlers share a counter and a room list:

```text
obj Rooms
  members: Map[String, List[String]]

  fun join(!@, room: String, who: String) -> Int
    list = !@members.entry(<room)
    !list.push(<who)
    list.len

sub main()
  hits = Atomic(0)
  rooms = Actor(Rooms(members: Map()))

  handler = |?hits, ?rooms, req|
    !hits.add(1)
    match req.path
      "/"     => http.text("Hello from Rig!")
      "/hits" => http.json("hits", hits.get())
      "/join" => http.json("size", (!rooms).join(req.arg("room"), req.arg("who")))
      _       => http.not_found()

  http.serve(":8080", handler)!
```

`http.serve` runs each request as a task and waits for all of them before
it returns. So the handler may lend `hits` and `rooms` rather than
counting handles to them. `!hits.add(1)` and `(!rooms).join(...)` mark
changes to shared state, as `!c.set(5)` does on a `Cell`.

## Tasks

**Form.** A `&` touching the `)` of a call, with nothing touching it on
the right, makes the call a task: `parse(f)&`, `(!rooms).join(r, w)&`. It
is a postfix sigil under Rig's spacing rule, so `a & b` stays bitwise
and, and `f()&b` is rejected. Only a call takes `&`.

**Meaning.** The call is guaranteed to run concurrently with what
follows. Its result is a `Task[T]`, an owning value that holds the
result once it is ready:

- `<t.wait()` waits for the task and takes its result. A fallible call
  gives a `Task[T!]`, whose result is passed on with `<t.wait()!` or
  handled with `catch`.
- `<t.cancel()` cancels the task, waits for it, and gives what it
  returned, usually `error.Canceled`.
- A list of tasks waits with `<ts.wait_all()`, in order, where the first
  error cancels the rest, or with `<ts.wait_first()`, where the first
  success cancels the rest. Each also has a `within:` deadline.
- A function may return a task. Its signature says so (`-> Task[T]`), and
  the task keeps the loans its signature shows, as any result does.

**Rules the checker adds.**

- A task whose value is thrown away is rejected. `log(e)&` as a
  statement would be canceled at the end of that same statement. Bind
  it, or call without `&`.
- A `Task[T!]` that the normal path drops without waiting is rejected,
  because its error would vanish. On an error path, a `return`, or a
  `break`, the drop is implicit; that is where cancellation is wanted.

## Loans and structure

A task keeps the loans of its arguments until it ends: `score(?d)&`
lends `d` to read for the task's whole life. So a task reads its
caller's data in place, with no copy and no counted handle, and no other
task can change that data meanwhile. Rust cannot offer this to async
tasks, because a future can be leaked; it is why Tokio's `spawn` needs
`'static`.

It is sound because a task holding a loan cannot be leaked, and its drop
always runs before the loan's owner goes. Five rules make that so:

1. **A task's drop uses its loans.** A loan lasts until its value's
   last use, or its drop when the type has a `drop` body (CORE sentence
   6). `Task` counts as having one, and so does any value whose drop
   glue reaches a task, such as a `List[Task[T]]`. So `t = f(?v)&`
   followed by `!v.push(1)` is rejected while `t` lives.
2. **Drops and `defer`s are checked in the order they run.** In
   `t = f(?x)&` followed by `defer clear(!x)`, the `defer` runs before
   `t` drops, so it is rejected.
3. **No shared home holds a loan.** A `Cell`, an owned closure, and now
   an actor take only values that carry no loan. A leak in Rig needs a
   cycle of shared handles, and a cycle needs one of these homes, so a
   value that carries a loan never leaks. Rig has no `forget`.
4. **A panic ends the program**, so no task outlives a frame it borrows
   from by surviving an unwound stack.
5. **The program's end waits for its tasks.** `main` returns only after
   every task the program still holds is canceled and waited for, before
   the leak check runs.

FORMAL-RIG's principle 4, "safety never rests on a drop running", becomes
"safety never rests on dropping a value that carries no loan". The lemma
"no value that carries a loan is leaked" becomes a stated proof
obligation of the formal work.

## Cancellation

**A request, delivered as an error.** Canceling a task asks it to stop.
The task sees the request as `error.Canceled` at its next *fallible*
waiting point: I/O, a channel operation, `sleep`, a timed wait, or a wait
on a `Task[T!]`. Its `errdefer`s and `defer`s then run as for any
failure.

**Sticky.** A canceled task stays canceled. Every fallible waiting point
fails until the task ends, so `x = read() catch ""` cannot swallow the
request and leave the task running forever.

**Infallible waits finish.** Waiting on a `Task[T]`, or calling an actor
method that cannot fail, is not a point where cancellation is delivered.
It passes the request on to what it waits for, and then completes. A
call's type tells whether it can see a cancel.

**Cleanup is shielded.** A `defer`, an `errdefer`, or a `drop` body runs
with cancellation held off, so a canceled connection still writes its
close frame and flushes.

**It follows ownership.** Canceling a task cancels the tasks it owns,
through the same drops. There is no token to pass along.

**Checkpoints.** A task that computes without ever waiting would make
its owner's drop wait forever. In code a task can reach, the compiler
inserts a budget check at loop back-edges and at entry to recursive
functions. Bounded loops and leaf functions need none, and Rig's facts
say which those are. When the budget runs out, the task yields its core,
and a canceled task with a fallible result fails there. This is also how
Rig avoids one task owning a core (see "The engine").

## What may cross cores

A task or an actor may run on another core, so what it takes must be safe
there. The checker derives two facts for every type:

- **moves:** the value can be handed whole to another thread.
- **shares:** another thread may read the value through a view while this
  one also reads it.

| Type | moves | shares |
|---|---|---|
| plain data, `String`, `List[T]`, `^T`, objects and enums | when every part moves | when every part shares |
| `?T` (a read view) | when `T` shares | when `T` shares |
| `!T` (a write view) | when `T` moves | never |
| `*T`, `~T`, `Cell[T]`, `Signal[T]` | never | never |
| a stack closure | when its captures move | when it captures no `!` view and its captures share |
| `Atomic[T]`, `Chan[T]`, `Actor[T]` | yes | yes |
| `Task[T]` | when `T` and its loans' views move | never |
| a Zig-backed type | as declared | as declared |

A task's argument is given to it (moved with `<x`, or copied) when its
type moves, or lent: to read (`?x`) when its type shares, and to write
(`!x`) when its type moves. A closure called as a task follows the same
rules for its captures. A closure lent to many tasks at once, such as a
server's handler, must share, which rules out a `!` capture.

A `*T` never crosses because its count is not atomic. It is confined to
one task, not one thread, so the runtime may move a whole task between
cores safely. Moving a `List` to another core frees it there, so the
program's allocator is thread-safe.

## Actors

**Making one.** `Actor(Counter(hits: 0))` moves the value into a task of
its own and gives an `Actor[Counter]`. Any object whose fields move and
carry no loan can be an actor; nothing in its declaration changes. The
handle is counted atomically: `+rooms` makes another, `?rooms` lends one
to tasks that end before it, and `~Actor[T]` is the weak form. The actor
lives until its last handle is dropped and it has answered every message
it took; its `drop` body then runs in its own task.

**Calling one.** A method called through the handle is a message, and
the call waits for the answer.

- A `?@` method is called bare: `rooms.count()`.
- A `!@` method is marked as on a `Cell`: `!rooms.leave(r, w)`, or
  `(!rooms).join(r, w)` where the value is used. The `!` marks the change
  and lends nothing, since the actor alone runs its methods.
- A `<@` method cannot be called through a handle.
- A method whose signature has `keeps` or `from` cannot be called through
  a handle: the actor holds no loan, and a result never views its state.
- With `&`, the call gives a `Task` and the caller does not wait.

**Arguments.** An argument moves or is copied. A waiting call may also
lend a value that shares, `rooms.log(?line)`. Once its message is in the
mailbox, such a call waits for the answer even if its caller is canceled:
a message that has not started is withdrawn, and a method that has
started runs to its end. Canceling a caller never interrupts a method
partway, so an actor's state is left half-changed only by that method's
own error, which its `errdefer`s restore.

**Order.** An actor runs one method at a time, each to its end, so its
state between two lines of one method is never seen by anyone else. Its
state between two calls from a client can change: check-then-act across
two messages is a race, and belongs in one method. Messages from one
sender run in the order sent.

**Mailbox.** A waiting call needs no bound, because its suspended caller
is the backpressure, and its message and reply slot live in the
caller's frame. A call made with `&` takes a slot of the actor's bounded
mailbox when its `Task` is made, and waits for one if none is free.
When the actor is idle, a call runs the method directly on the caller's
core with one atomic step, with no queue and no switch.

**Deadlock.** Actors are not reentrant: a `!@` method holds its write
view while it waits, so a call back into the same actor cannot run. A
cycle of waiting calls is a deadlock. Every waiter records the one thing
it waits on, so the call that would close a cycle walks the chain, finds
it, and panics, naming it: `Bank.pay -> Ledger.post -> Bank.balance`. A
deadlock is a bug, and Rig's bugs panic, so actor calls stay infallible.
A lint over which actor types call each other warns before the program
runs.

## Failure

Errors stay values. `Task[T!]` gives back exactly the call's error set,
plus `Canceled`, and `Timeout` from a timed wait, with no wrapping: no
`AggregateException`, no `ExecutionException`.

A panic ends the program. A task's stack is pointed into: its child
tasks hold loans of its locals, and it holds loans of its parent's.
Cutting one task out without running its drops would free memory its
children still read, and running them means unwinding, which Rig does
not have. So a server isolates failure the way the operating system
already does: `std.http` offers a pre-fork mode (several processes on
one port, restarted by a small parent). Every operation that can panic
on bad input (an index, an overflow, a division) has a form that returns
an optional or an error, so a server never needs to panic on input it
does not trust.

Supervision restarts *functions that fail*, not actors that panic:
`std.supervise` runs a function as a task, restarts it on an error, and
gives up past a limit of restarts in a window.

## The library

**First wave, shipped with tasks:**

- `wait_all`, `wait_first`, and their `within:` forms, on lists of tasks;
- `par.map(?xs, f, limit: n)`;
- `Atomic[T]`, because a counter should cost an atomic add, not a
  message;
- `time.sleep` and deadlines.

**Second wave:**

- `Chan[T]`, a bounded channel, changed with `!` like a `Cell`;
- `select` over channel operations. It commits exactly one arm
  atomically, CML-style, so a message is never received by an arm that
  then loses.
- `std.supervise`.

**Not planned:** a `Mutex`, which would be the first construct that can
deadlock without a message, and a thread-safe counted handle. Each is
added only if a program shows the need.

## The engine

The reviews agree on what makes a runtime fast and solid. Tokio is fast
because of its scheduler, not because its tasks are stackless. Each
principle below names the mechanism that carries it.

1. **Keep work on the core that made it.**
   - Each worker owns a bounded ring of ready tasks. A push is a single
     store, and only stealing takes a compare-and-swap.
   - A slot runs the task just woken next, while its data is still in
     cache. It is capped at three in a row, and can be stolen once its
     owner overruns its budget.
   - Spawning is work-first: the new task runs at once, and the parent's
     rest becomes stealable. Stackful tasks make this cheap, and it
     bounds memory the way Blumofe–Leiserson scheduling proves.
2. **Touch shared memory only to balance load.**
   - An idle worker steals half of a random victim's ring.
   - A global queue takes work from outside the runtime, and each worker
     checks it at a self-tuning interval.
   - At most half the workers search for work at once.
   - A worker that finds work wakes one more, so wakeups spread in a
     chain, not a herd.
3. **One atomic word per task.** The task's state flags and its
   reference count share one word, so waking a task is one
   compare-and-swap, and a task is queued at most once.
4. **No task owns a core.**
   - Every waiting point that completes at once spends from a budget of
     about 128.
   - The compiler's checkpoints catch loops that never wait.
   - A monitor thread flags a task that runs for more than about 10 ms.
5. **Ready work never starves I/O.**
   - A worker polls for I/O and timers every 61 tasks, even under load.
   - Timers sit in per-worker hierarchical wheels, with one kernel
     timeout per worker for its next deadline.
6. **Tasks are cheap, and stacks are safe.**
   - Fiber stacks are carved from one large reservation, with per-worker
     free lists, never an `mmap` per task.
   - A task whose stack bound is proven gets an exact slab with no guard
     page, near Tokio's density. The bound comes from the emitted code
     (`.stack_sizes`), so it counts Zig, runtime, and inlined frames.
   - Any other task gets a lazily committed stack. Its guard is at
     least as large as the largest frame, or the compiler emits stack
     probes, because a large frame could otherwise jump a small guard.
   - A call into C switches to the worker's own system stack.
   - Stacks never move, because loans point into them.
7. **Fast paths for the case with no contention.**
   - Waiting on a task that has not started runs it inline on the
     waiter's stack, with one compare-and-swap.
   - A call to an idle actor runs inline.
   - Replies live on the caller's stack.
8. **Blocking is isolated.** A call that blocks the thread (C code, DNS,
   a large file) runs on a blocking pool, or hands the worker's core to
   another thread for its duration.
9. **Know what every task waits on.** One pointer per task gives exact
   deadlock detection, a dump of what every task waits on, and later,
   priority inheritance.
10. **Tests are deterministic.** `rig test` runs on a single-thread
    backend with virtual time and a seed, so a concurrent test fails the
    same way twice.

**The substrate.** Rig writes its own implementation of Zig's `std.Io`
interface, and its own scheduler, beneath it. Zig code and Zig-backed
Rig declarations run on it unchanged, because they see only `Io`. It
takes the system-call code of Zig's backends (io_uring on Linux, kqueue
on macOS and the BSDs) and binds them statically, with no vtable call per
operation. Zig 0.17's own evented backends are not a foundation:
- each fiber reserves 60 MiB with no guard page;
- their scheduling is a prototype;
- network streams are unfinished on Linux and macOS;
- the kqueue backend cannot cancel.

The first step runs on Zig's `Threaded` backend, which is complete and
preemptive. It proves the language rules, and measures nothing.

**The memory model.** User code has no data races, so it sees
sequential consistency. The edges that order it are:
- a task's start after the call that made it;
- a task's end before the `wait` that returns its result;
- a message's send before the method it starts;
- a method's return before its caller resumes.

The runtime's own atomics are the only others.

**The target.** It is measured, not assumed, on Linux and macOS, against
Tokio and Go:
- an HTTP server's requests per second and p99 latency;
- an actor round trip;
- fan-out and fan-in of CPU-bound work;
- memory for a million idle tasks.

That last one is stated honestly: a task with an unproven stack costs at
least a page (4 KiB on x86, 16 KiB on Apple Silicon), against Tokio's
hundreds of bytes; a task with a proven stack costs about what Tokio's
does.

## What else this needs

- **String patterns in `match`** (`"/hits" =>`), rejected today. The
  server example needs them, and they are worth having on their own.
- **No new keywords.** `Actor(x)` is a type; `async` and `await` stay
  reserved and unused.
- **Assignment stays a statement.**

## Proof obligations

These fit the existing λRig work in `formal/`, in this order:

1. data-race freedom of the *moves* and *shares* discipline, with
   threads in the machine and fork as a step;
2. no value that carries a loan is leaked;
3. no orphans: live tasks form a tree rooted in live frames;
4. deadlock detection over the wait-for chain is exact;
5. a canceled task reaches its end in finitely many waiting points.

## Decisions

Each item gives the answer this document assumes.

1. **The model:** task (`f(x)&`), ownership of tasks, actors, and the
   crossing facts, with everything else in `std`. *Yes.*
2. **Tasks:** `Task[T]` is owned; `<t.wait()` and `<t.cancel()` consume
   it, and dropping an unwaited task cancels and waits. *Yes.*
3. **Checked misuse:** a discarded `f()&` and an unwaited `Task[T!]` on
   the normal path are rejected. *Yes.*
4. **Loans in tasks**, with the five soundness rules and the amended
   FORMAL-RIG principle 4. *Yes.*
5. **Cancellation:**
   - sticky;
   - delivered only at fallible waits;
   - infallible waits pass it on;
   - cleanup shielded;
   - compiler checkpoints at back-edges.

   *Yes.*
6. **Crossing:** the fact table above, with Zig-backed types declaring
   theirs. *Yes.*
7. **Actors:** `Actor(x)` over any object whose fields move, with no
   `actor` or `spawn` keyword. *Yes.*
8. **Actor calls:**
   - `!` marks a change and lends nothing;
   - no `<@`, `keeps`, or `from` method through a handle;
   - a lending call waits through cancellation;
   - a started method finishes.

   *Yes.*
9. **Mailbox:** waiting calls unbounded, `&` calls bounded, and an idle
   actor runs inline. *Yes.*
10. **Deadlock:** exact detection at the closing call, which panics with
    the cycle, plus a lint. *Yes.*
11. **Failure:** errors as values, and a panic ends the program.
    Supervision restarts failing functions, and servers isolate by
    process. *Yes.*
12. **Local tasks**, pinned to one thread so that `*T`, `Cell`, and
    `Signal` code (GUI programs) can use `&`. *Designed now, built in
    the second wave; until then such a task is rejected.*
13. **The engine:** Rig's own `std.Io` implementation and scheduler, on
    the ten principles above. *Yes.*
14. **The library:** the first and second waves as listed. *Yes.*
15. **Order of work**, each step its own pull request:
    1. `&`, `Task`, the loan and cancellation rules, and `wait_all` and
       `wait_first`, on `Threaded`;
    2. the crossing facts and `Atomic`;
    3. actors;
    4. the scheduler core, benchmarked with no I/O;
    5. I/O, timers, `http.serve`, and the benchmarks against Tokio and
       Go;
    6. local tasks, channels, and `select`.

    *Yes.*
