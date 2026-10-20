# Concurrency in Rig

**A proposal for discussion. Nothing here is built.** It draws on three
expert reviews, which an adversarial review then attacked:
- Tokio's runtime source;
- the models of Go, Erlang/BEAM, Java Loom, .NET, and JavaScript;
- Zig 0.17's `std.Io`, structured-concurrency theory, scheduling theory,
  and soundness.

The reports are in [docs/history/concurrency/](../history/concurrency/):
[the runtime engineers](../history/concurrency/1-runtime-engineers.md),
[the language models](../history/concurrency/2-language-models.md),
[Zig and theory](../history/concurrency/3-zig-and-theory.md),
and [the adversarial review](../history/concurrency/4-adversarial-review.md),
of a draft that git keeps. They
review earlier drafts of this document, so a few of their findings
are already folded in, and a few of their proposals were set aside
here.
Decisions are listed at the end, each with the answer this document
assumes. Once they are settled, the examples become
```` ```rig pending ```` blocks and SPEC gains the rules.

## The model

A programmer learns three things, and the checker enforces a fourth:

1. **A task.** `f(x)&` runs a call at the same time as the code after it
   and gives an owned `Task[T]`; `>t` takes its result.
2. **A task belongs to its owner.** A task never outlives the value
   that holds it. Dropping a task that was not waited for cancels it and
   waits for it. So a scope, or a set of tasks, is the group, and a task
   may read and write its caller's data in place.
3. **An actor.** `*Actor(x)` moves a value into a task of its own and
   gives a shared handle to it. A method called through the handle is a
   message, and the actor runs one at a time, each to its end.
4. **What may cross.** The checker knows, for every type, whether its
   value may move to another core and whether two cores may read it at
   once. A programmer meets these facts only as error messages.

State that many tasks change is shared as Rig already shares state that
changes (CORE sentence 9): it lives behind `*`, each holder has a handle
of its own, made with `+`, and a change is a marked call through a
handle you hold. A read view, `?`, still changes nothing.

Everything else is a library on these four: sets of tasks, timeouts,
channels, atomics, and supervision.

What a programmer never writes:
- threads, fibers, or async functions;
- `await` on every call that waits, `Pin`, or locks: only a task started
  with `&` is waited for, with `>t`;
- cancellation tokens;
- `'static` bounds;
- `Arc` around data a task only needs to read.

A function that waits on a socket is an ordinary function, and calling
it is an ordinary call. Serial code is the default; concurrency is the
marked case, `&`, exactly where it happens.

A task can be stopped early only if its result can fail: cancellation
arrives as `error.Canceled`, so a `Task[Int]` runs to its end and a
`Task[Int!]` can be canceled.

## Rig and Tokio

Tokio, Rust's async runtime, is the measure of a fast one. Rig's tasks
go further than it in six ways, each following from the model, and
aim to match it in the rest.

**Where Rig goes further:**

- **One kind of function.** There is no `async` or `await`, no second
  kind of function, no `Pin`, no `'static` bound, and no `Arc` around
  data a task only reads. Any function runs as a task with `&`, and a
  function that waits on a socket is an ordinary function, called as
  any other.
- **Tasks borrow in place.** `score(?d)&` reads `d` where it is, with
  no copy and no counted handle, because Rig's ownership rules make the
  task end before `d` does ("Loans and structure"). Tokio cannot offer
  this: a future can be leaked, so its `spawn` takes only `'static`
  data, and a task reads its caller's data through a copy or an `Arc`.
- **No task is ever left running.** Dropping a task cancels it and waits
  for it, so every task ends inside the scope that made it. Dropping a
  Tokio `JoinHandle` detaches the task, which runs on with no owner.
- **Switching is cheap.** A Rig task runs on a stack of its own: pausing
  it saves the few registers a call keeps, and resuming restores them. A
  Tokio task is a state machine: each pause returns up through every
  future it is nested in, and each resume calls back down through them.
- **A long computation never holds up the rest.** The compiler puts a
  yield check in every outermost loop and recursive function of a
  program that makes tasks, so a task waiting behind one waits for a
  slice of it, not all of it. Tokio never stops a running task, and Go
  stops one after 10 ms.
- **Errors stay the call's own.** `Task[Page!]` gives back the error
  the call failed with, from the call's own error set; a canceled task
  fails with `Stop.canceled`, an ordinary member of that set. A Tokio
  `JoinHandle` gives a `JoinError` around a panic or a cancellation.

**Where Tokio is still ahead:**

- **I/O.** Tokio's engine for sockets, files and timers (epoll, kqueue,
  io_uring) is tuned by years of real load. Rig's is the plan's fifth
  step ("The engine").
- **Memory for a task at rest.** A Tokio task can be a few hundred
  bytes; a Rig task holds a page of its stack, 17 KiB on the Mac and
  5 KiB on Linux. Closing that gap, by stacks sized to a proven bound
  and stacks smaller still, is measured work ("The engine").
- **Maturity.** Its ecosystem, its tooling, and its years in
  production.

`bench/tasks` times Rig's tasks against Tokio's and Go's on starting,
waiting, spreading work over cores, switching, and waiting behind a
long computation, and measures the memory a task takes. Rig is ahead
of Tokio wherever the scheduler is what is measured, and behind in
memory ([bench/tasks/README.md](../../bench/tasks/README.md), "Where it
stands"), and `bench/tasks/PROGRESS.md` records each step of the
scheduler ([docs/internals/scheduler.md](../internals/scheduler.md)).

## What a program writes

Score every document in parallel, each task reading its document in
place, with no copy:

```text
docs = load_docs()
ts = Tasks[Int]()
for d in ?docs
  !ts.add(score(?d)&)
scores = >ts
print(sum(?scores))
```

Fetch pages, failing fast and giving up after two seconds:

```text
fun fetch_all(urls: ?List[String]) -> List[Page]!
  ts = Tasks[Page!]()
  for u in urls
    !ts.add(http.get(?u)&)
  <ts.wait_all(within: time.seconds(2))!
```

The first error, or the deadline, cancels the rest and waits for them.

Two different calls at once:

```text
u, o = task.both(user(id)&, orders(id)&)!
```

A server whose handlers share a counter and a room list (built):

```text
use std.http
use std.net

obj Rooms
  members: List[String]

  fun join(!@, who: String) -> Int
    !@members.push(<who)
    @members.len

sub main()!
  hits = *Cell(0)
  rooms = *Actor(Rooms(members: List[String]()))
  l = net.listen(":8080")!
  http.serve(<l, |+hits, +rooms, req|
    !hits.add(1)
    match req.path
      "/"     => http.text("Hello from Rig!")
      "/hits" => http.json(String("{\"hits\":", hits.get(), "}"))
      "/join" => http.json(String("{\"size\":", (!rooms).join(req.arg("who") ?? String("someone")), "}"))
      _       => http.not_found()
  )!
```

The handler captures handles of its own to the counter and the room list
(`+hits`, `+rooms`). `http.serve` runs each connection as a task and
calls the handler for each request, so every request changes `hits` and
`rooms` through the handles the handler holds: `!hits.add(1)` and
`(!rooms).join(...)` are marked changes to shared state, as `!c.set(5)`
is on a `*Cell`. Every connection's task calls the one handler, so its
captures must share, as `par.map`'s do.

## Tasks

**Form.** A `&` touching the `)` of a call, with no operand touching it
on the right, makes the call a task: `parse(f)&`,
`(!rooms).join(r, w)&`. It is a postfix sigil under Rig's spacing rule,
so `a & b` and `f()&b` stay bitwise and. Only a call takes `&`.

**Meaning.** The call is guaranteed to run concurrently with what
follows. Its result is a `Task[T]`, an owning value that holds the
result once it is ready. `T` may be fallible: `Task[Page!]` is the one
place a fallible type stands as a type argument.

- `>t` waits for the task and takes its result. A fallible
  result is passed on with `>t!` or handled with `catch`.
- `<t.cancel()` cancels a fallible task, waits for it, and gives what it
  returned, usually `error.Canceled`.
- `task.both(a, b)` and `task.all(a, b, c)` wait for several tasks of
  different types at once. The first error cancels the others.
- A function may return a task (`-> Task[T]`). The task keeps the loans
  its signature shows, as any result does.

**Where a task may go.** A task holds the loans of its arguments, so it
goes only where a value holding those views may go:
- a task with read loans only may be bound, held in a `Tasks` set or
  another owned value, and returned with `from`;
- a task with a write loan may only be bound to a local and waited for,
  since no value holds a write view;
- no task, whatever its loans, is ever placed in a shared home (below).
  So a task cannot be leaked, and there are no orphans.

**When a task can't be made.** If the runtime cannot get a stack or a
thread for a task, the program panics, as it does when memory runs out.

**Misuse the checker rejects:**
- A task whose value is thrown away. `log(e)&` as a statement would be
  canceled at the end of that statement: bind it, add it to a set, or
  call without `&`.
- A fallible task that the normal path drops without waiting, since its
  error would vanish. On an error path, a `return`, or a `break`, the
  drop is implicit; that is where cancellation is wanted.
- A deadline or a `wait_first` over tasks that cannot fail, since they
  cannot be stopped.

## Sets of tasks

`Tasks[T]` is the one group type. It is built in, as `Task` is, and needs
no syntax:

- `!ts.add(f()&)` adds a task. With no result (`Tasks[Void]`), a task that
  has finished is removed at once, so a long-running server loop never
  piles up finished work.
- `>ts` waits for all and gives their results in the order
  added. `<ts.wait_first()` gives the first success. Both take
  `within:`.
- The first error of a fallible set cancels the rest.
- Dropping a set cancels every task first, then waits for them all, so
  the costs of cancelling do not add up.
- `par.map(?xs, f, limit: n)` and `par.each(!xs, f, limit: n)` run a
  function over a list's elements, at most `n` at once. Use them in
  place of a loop of `&` over input of unbounded size.

## Loans and structure

A task keeps the loans of its arguments until it ends: `score(?d)&`
lends `d` to read for the task's whole life. So a task reads its
caller's data in place, with no copy and no counted handle, and no other
task can change that data meanwhile. Rust cannot offer this to async
tasks, because a future can be leaked; it is why Tokio's `spawn` needs
`'static`.

It is sound because a task's drop always runs before the owner of its
loans goes. Five rules make that so:

1. **A task's drop uses its loans.** A loan lasts until its value's
   last use, or until its drop when the type has a `drop` body (CORE
   sentence 6). `Task` counts as having one, and so does every value
   whose drop glue reaches a task. So after `t = f(?v)&`, `!v.push(1)`
   is rejected while `t` lives.
2. **Drops and `defer`s are checked in the order they run.** In
   `t = f(?x)&` followed by `defer clear(!x)`, the `defer` runs before
   `t` drops, so it is rejected.
3. **No shared home holds a loan.** A *shared home* is a type whose value
   changes through a shared path: `Cell`, `Signal`, an owned closure,
   `Chan`, `Actor`, and any Zig-backed type that declares
   *shares*. None holds a value that may carry a loan, and `Task` always
   may. A leak in Rig needs a cycle through a shared home, so a value
   that carries a loan never leaks. Rig has no `forget`.
4. **A panic unwinds frame by frame** (see "Failure"). Each frame
   cancels and waits for the tasks it owns before it goes, as on any
   other exit, so no task outlives a frame it borrows from.
5. **The program's end waits for its tasks.** `main` returns only after
   every task it still holds is canceled and waited for, before the leak
   check runs. An interrupt (SIGINT) cancels `main`.

FORMAL-RIG's principles change in three places:
- principle 4, "safety never rests on a drop running", becomes "safety
  never rests on dropping a value that carries no loan";
- principle 6 names tasks and actors as the concurrency, with channels
  in `std`;
- the Core gains the task and crossing rules within its budget,
  counted in the change that adds them.

## Cancellation

**A request, delivered as an error.** Canceling a task asks it to stop.
The task sees the request as `error.Canceled` at its next *fallible*
waiting point:
- I/O;
- a channel operation;
- `sleep`;
- a timed wait;
- a wait on a fallible task;
- `task.check()!`.

Its `errdefer`s and `defer`s then run as for any failure.

**Ordinary errors.** `Canceled` and `Timeout` are errors like any other,
with no special rule:
- `std` declares them once, `error Stop = canceled | timeout`;
- each waiting operation that can be canceled or timed out has them in
  its set, as a network set already has `.timeout`
  (`error Net = refused | reset | Stop`);
- a function whose set is inferred (`T!`) picks them up from the calls
  it makes, with nothing to write;
- a function that declares its set (`-> Page!(Http | Stop)`) names them,
  as it names any error its calls can raise;
- an exhaustive `match` handles them as it handles any member, and `_`
  or passing the error on with `!` stay the short forms.

A caller that matches every error by name is the caller who should
decide what cancellation means, so the set shows it.

**Sticky.** A canceled task stays canceled: every fallible waiting point
fails until the task ends. So `x = read() catch ""` cannot swallow the
request once and carry on.

**Infallible waits finish.** Waiting on a task that cannot fail, or
calling an actor method that cannot fail, is not a point where
cancellation is delivered. It passes the request on to what it waits
for, and then completes.

**Cleanup is shielded, within a grace period.** A `defer`, an
`errdefer`, or a `drop` body runs with cancellation held off, so a
canceled connection still writes its close frame and flushes. Shielding
holds off the cancel, not deadlines: cleanup runs under a grace deadline
that the runtime sets and a program may change.

**It follows ownership.** Canceling a task cancels the tasks it owns,
through the same drops. There is no token to pass along.

**Yielding.** A task that computes without waiting would hold its core,
and would make its owner's drop wait. So the compiler counts iterations
in loops a task can reach, and checks the count once per loop nest, in
its outer loop, so inner loops still vectorize. Recursive functions
check on entry. A check only yields: it never fails, because a failure
in Rig is always written. A long computation that should stop when
canceled writes `task.check()!` where stopping is safe. That one call
both yields and delivers a cancel. In a debug build, a watchdog reports
a canceled task still running after a while.

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
| `*T` and `~T` of a type that is not synchronized, `Cell[T]`, `Signal[T]` | never | never |
| a stack closure | when its captures move | when it captures no `!` view and its captures share |
| `*Cell[T]`, for a one-word plain `T` | yes | yes |
| `*Chan[T]` | when `T` moves | when `T` moves |
| `*Actor[T]` | yes | yes |
| `Task[T]` | when `T` and its loans' views move | never |
| a Zig-backed type | as declared | as declared |

A task's argument is given to it, moved (`<x`) or copied, when its type
moves. Otherwise it is lent: to read (`?x`) when its type shares, and to
write (`!x`) when its type moves. A closure called as a task follows the
same rules for its captures.

A function a library calls from many tasks at once needs no mark on its
type. The checker reads the requirement from the library's body, as it
reads what a generic function needs of its type parameters, and checks
the closure where the library is called, with the closure in hand:
- `par.map`'s body lends `f` to several tasks at once, so the closure
  passed to `par.map` must share: its captures share, and it captures
  nothing with `!`;
- `http.serve` takes its handler by value and gives each task a copy, so
  the handler's captures must move.

A closure that breaks the rule is rejected where it is passed:

```text
par.map(?docs, |!counts, d| tally(!counts, d))
# error: `par.map` calls the closure on several tasks at once, and
#   `|!counts|` lends `counts` to write, which no two tasks may hold at once
```

Today `par.map` and `par.each` are typed by the checker itself, and take
a closure written in the call, whose captures it sees, or a function's
name; reading the requirement from a library's body comes with
`http.serve`.

A function value stored in a field and called from many tasks later is
checked where it is stored, as a closure placed in an owned home is
today.

A `*T` of a type that is not synchronized never crosses, because its
count is not atomic. It is confined
to one task, not one thread, so the runtime may move a whole task
between cores. That requires the runtime to hold no per-thread state
across a point where a task may wait. Its drop queue, drop depth, and
print nesting move into each task's context. Moving a `List` to another
core frees it there, so the program's allocator is thread-safe.

## Local tasks

A task given or lent a value that does not cross, where it would
otherwise be rejected, is *local*: it is pinned to the thread of the
task that makes it, and that task is pinned there too, from then on.
What stays on one thread is then shared by tasks that run on that one
thread only, so the `*T` and `~T` counts, a `Cell` of more than one
word, a `Signal`, and a function's captures are never touched by two
cores at once. The tasks take turns at their waits and yield checks, as
any tasks on one worker do. So a GUI program's `*T`, `Cell`, and
`Signal` code can use `&`.

- **Implicit.** The checker makes a task local when its arguments or
  self hold such a value (`sema.localBlocker`), and records it; nothing
  marks it in the source, as nothing marks how a `Cell` is kept safe.
- **What still stops it.** A set of tasks, a task or a write view lent
  to read, and a function lent to read, which may lend what it captures
  to write, are not held by two tasks at once even on one thread. A
  channel's elements go to any task that holds a handle of it, so they
  must cross whoever holds the channel.
- **The scheduler.** A pinned fiber has a home worker. When it is ready
  it waits in that worker's pinned queue, never in a ring or the global
  queue, so no other worker steals it; the worker takes its pinned
  fibers and its ring by turns. A wake from another worker or thread
  puts the fiber in its home's queue and kicks the home's poller if it
  sleeps. A local task waited for at once still runs by handoff, on the
  same worker.
- **The cost.** Local tasks share one core: they give concurrency, not
  parallelism. A task that should run on another core is passed values
  that cross: a `*Cell` of one word, a `Chan`, an actor, or a copy.

## Synchronized types

A `Cell` of one word, `Chan[T]`, and `Actor[T]` are *synchronized*:
they are changed by many tasks at once. They follow CORE sentence 9 as
any `Cell` does, with one difference. (A separate `Atomic[T]` was folded
into `Cell`: a counter or a flag is a Cell of one word.)

- **The same as any `Cell`:**
  - each lives only behind `*`: `*Cell(0)`, `*Chan[Job](64)`,
    `*Actor(Rooms(...))`;
  - each holder has a handle of its own, made with `+`;
  - a change is a marked call through a handle you hold: `!hits.add(1)`,
    `!jobs.send(<j)!`, `(!rooms).join(r, w)`;
  - a read view, `?hits`, only reads: `hits.get()`. `?` changes nothing
    here as everywhere.
- **The difference:** a `*` over a synchronized value counts its handles
  atomically, so the handle may cross cores. A `*Cell` of more than one
  word stays confined to one task.

So CORE sentence 9's list of what may be shared gains `Chan` and
`Actor`, and no rule changes.

A synchronized value is never a local, a parameter, or an element by
value, as a `Cell` isn't. Lowering never copies a Cell of one word into
a read view. Each of its operations is sequentially consistent, so user
code still has no data races and sees sequential consistency.

A module-level `*Cell` of one word or `*Chan` carries no loan, so actors
and tasks anywhere may use it, through a handle of their own.

## Actors

**Making one** (built). `*Actor(Counter(hits: 0))` moves the value into a task
of its own and gives a `*Actor[Counter]`, a handle to it. Any object
whose fields move and carry no loan can be an actor; nothing in its
declaration changes.

The handle is counted atomically:
- `+rooms` makes another, for a task or core of its own;
- `?rooms` lends one to read, to tasks that end before it;
- `~rooms` is a weak handle.

The actor lives until its last handle is dropped and it has answered
every message it took: the task draining its mailbox holds a handle of
its own. Its value then drops where that last handle goes.

**Calling one** (built). A method called through the handle is a
message, and the call waits for the answer.

- A `?@` method is called bare, through a handle or a read view of one:
  `rooms.count()`.
- A `!@` method is marked, and needs a handle you hold:
  `!rooms.leave(r, w)`, or `(!rooms).join(r, w)` where the value is used.
  Through `?rooms` it is rejected, since `?` changes nothing.
- A `<@` method cannot be called through a handle.
- A method whose signature has `keeps` or `from` cannot be called through
  a handle: the actor holds no loan, and a result never views its state.
- With `&`, the call gives a `Task` and the caller does not wait.
- `time.within` around the call, or the task making it, sets its
  deadline; a call has no deadline of its own.

**Arguments.** An argument moves or is copied. A call may also lend a
value that shares, `rooms.log(?line)`. A call of a method that can fail
is withdrawn when it has not started and its caller is canceled or its
deadline passes, and fails with `Stop.canceled` or `Stop.timeout`. A
method that has started runs to its end, and its caller waits for it.

Canceling a caller never interrupts a method partway. An actor's state
is left half-changed only by that method's own error, which its
`errdefer`s restore.

**Order.** An actor runs one method at a time, each to its end. So its
state between two lines of one method is never seen by anyone else, but
its state between two calls from a client can change: check-then-act
across two messages is a race, and belongs in one method. Messages from
one sender run in the order sent.

**Mailbox.**
- A waiting call needs no bound, because its suspended caller is the
  backpressure. Its message and reply slot live in the caller's frame.
- A call made with `&` takes a slot of the actor's bounded mailbox when
  its `Task` is made, and waits for one if none is free.

**The idle path** (built). When an actor is idle (not running, not
scheduled, and with an empty mailbox), a caller takes it with one atomic
step and runs the method on its own core, with no queue and no switch.
The method still runs as the actor:
- its cancel state, deadline, and isolate are the actor's, not the
  caller's, so a canceled caller cannot interrupt it;
- the call is made only when the caller's stack has room: a quarter of
  a task's stack left above its guard, until stack bounds are proven
  per method;
- a call through a handle to the same actor type counts as recursion in
  the stack analysis, once there is one.

Afterwards the caller hands any messages that arrived to the actor's
own task rather than serving them itself. An idle actor called this way
is a fair mutex with deadlock detection, so Rig needs no `Mutex`.

**Deadlock** (built). Actors are not reentrant: a `!@` method holds its
write view while it waits, so a call back into the same actor cannot
run. A cycle of waiting calls is a deadlock.
- Every waiter publishes the one thing it waits on, with a sequentially
  consistent store, and then walks the chain from there. An actor whose
  method's fiber blocks leads on to that fiber's wait.
- So the call that would close a cycle finds it, even when two cores
  close it at once, and panics naming it:
  `Bank.pay -> Ledger.post -> Bank.balance`. A deadlock is a bug, and
  Rig's bugs panic, so actor calls stay infallible. The panic unwinds
  to the nearest boundary, so it fails one request, not the server,
  once a panic in an actor's method fails its caller (Failure).
- This is exact for waits on one thing: a task, an actor call, or a
  set's next result, which is stuck only when every task left in the
  set is. A wait on any of several channels is not covered; a debug
  dump of what every task waits on covers those.
- Only a program that makes actors is watched: the tasks a task waits
  on are its own, so every cycle passes through an actor.
- A lint over which actor types call each other warns before the
  program runs.

## Failure

**Errors stay values.** `Task[T!]` gives back exactly the call's error
set, with no wrapping: no `AggregateException`, no `ExecutionException`.
`Canceled` and `Timeout` are in that set when the call can meet them, as
ordinary members (see "Cancellation").

**A panic is a bug, and it ends the smallest part of the program that
holds the damage.** A panic stops at the nearest *boundary*. The
frames between stop where they stand: the tasks started under the
boundary are canceled and waited for, since they may point into those
frames, and what the frames own stays allocated, since a value one of
them moved into a shared `Cell` must stay valid. Their drops and
`defer`s do not run: Zig, which Rig compiles to, has no unwinding, and
running them would cost every owned value a record on the normal path.
A task's panic passes to its owner, at its wait or drop, up to the
boundary. Three things are boundaries:

- **`main`.** A panic that reaches it ends the program, as today, with
  status 134. A program with no other boundary keeps today's behaviour
  exactly: the program ends where the panic stands, with no unwinding.
- **`task.isolate(f)`** (built) runs `f` and gives `T!` with
  `task.Stop.panicked` in the set; its message and location go to
  stderr, and become the error's data once errors carry data. Nothing outside
  `f` may be lent to it to write, so everything a panic in `f` could
  have half-changed is `f`'s own, and is abandoned: what survives is
  either untouched or was only read. `http.serve` runs each request
  this way, so a bug fails that request with a 500, stops its tasks and
  closes its files, leaving only its memory, and leaves every other
  request running.
- **An actor** (built). An actor owns its state, so a panic in one of
  its methods kills that actor: its state, possibly half-changed, is
  abandoned, not dropped, and never served again. The caller waiting on
  that method panics too, as an Erlang link does, failing the caller's
  own request rather than handing it an error it cannot reason about.
  A method run on the actor's own task stops the panic there; one run
  inline panics in the caller as it stands, ending every actor the
  caller runs a method of. A queued or later call to an actor that has
  died panics in its caller, naming the method that ended it.

Why this is sound without a runtime that knows the heap: loans point only
from tasks into their owners, never the other way. So when a boundary's
frames unwind, nothing that survives points into them, and anything
outside the boundary that the dead code touched was only read.

**Supervision** restarts what died. `*Actor.supervised(*|| Rooms(...))`
(built) makes an actor that starts again from the function when it
dies; the function is an owned closure, since the actor keeps it.
Calls that had not started wait for the new actor; the call that was
running when it died panics in its caller. `restarts: n, per: ns`
limits the restarts in a window, past which the actor dies for good.
`task.supervise(f, restarts: n, per: ns)` (built) does the same for a
function: it runs `f` isolated, restarts it on an error or a panic, and
gives up past a limit of restarts in a window.

**What this does not protect.** A task that panics between two related
`!hits.add(...)` calls leaves them out of step, as in any concurrent
system. An invariant that spans several values belongs in an actor,
which a panic cannot leave half-changed.

**A panic during unwinding**, in a `drop` body or a `defer`, ends the
program, as in Rust.

**Bad input needn't panic.** Every operation that panics on bad input
(an index, an overflow, a division) has a form that returns an optional
or an error, so a server never needs to panic on input it does not
trust. `std.http`'s pre-fork mode (several processes on one port,
restarted by a small parent) remains, as defence in depth.

## The library

**First wave, shipped with tasks:**
- `Tasks[T]`, `task.both`, `task.all`, `par.map`, and `par.each`;
- `time.sleep`, deadlines, and `time.within(d, || ...)`, a deadline over
  a block of calls;
- `task.check()!` and `task.isolate`;
- a `*Cell` of one word, because a counter should cost an atomic add,
  not a message.

**Second wave:**
- `*Chan[T]`, a bounded channel, shared through handles as a `*Cell` of
  one word is (built);
- `select` over channel operations, which commits exactly one arm
  atomically, CML-style, so a message is never taken by an arm that then
  loses (built: `task.select((!a).on_recv(|v| ...), (!b).on_send(<x, || ...))`);
- `std.supervise` and `*Actor.supervised`.

**Not planned:** a `Mutex`, which an idle actor already is, and a
thread-safe counted handle. Each is added only if a program shows the
need.

## The engine

The reviews agree on what makes a runtime fast and solid. Tokio is fast
because of its scheduler, not because its tasks are stackless. Each
principle below names the mechanism that carries it.

1. **Keep work on the core that made it.**
   - Each worker owns a bounded ring of ready tasks. Its owner pushes
     with one store, and pops and steals use a compare-and-swap.
   - A slot runs the task just woken next, while its data is still in
     cache. It is capped at three in a row, and can be stolen once its
     owner overruns its budget.
2. **Make a task cheap until it runs.**
   - `&` places a small task record in the ring. Its fiber stack is taken
     only when the task first runs.
   - A waiter that finds its task not yet started runs it on its own
     stack, with one compare-and-swap, when the stack has room for the
     task's proven bound. This keeps fine-grained fan-out nearly free.
   - It is never done inside `wait_first` or under a deadline, where
     the waiter must stay free to give up.
3. **Touch shared memory only to balance load.**
   - An idle worker steals half of a random victim's ring.
   - A global queue takes work from outside the runtime, and each worker
     checks it at a self-tuning interval.
   - At most half the workers search for work at once.
   - A worker that finds work wakes one more, so wakeups spread in a
     chain, not a herd.
4. **One atomic word per task.** The task's state flags and its
   reference count share one word, so waking a task is one
   compare-and-swap, and a task is queued at most once.
5. **No task owns a core.**
   - Every waiting point that completes at once spends from a budget of
     about 128.
   - The compiler's loop-nest checks catch computation that never waits.
   - A monitor thread flags a task that runs for more than about 10 ms.
   - Preemption by signal at safe points is held in reserve, if
     measurement shows the checks cost too much.
6. **Ready work never starves I/O.**
   - A worker polls for I/O and timers every 61 tasks, even under load
     (built).
   - Timers sit in a heap per worker, as Go keeps them, with one kernel
     timeout per sleeping worker for the earliest deadline (built).
7. **Stacks are cheap and safe.**
   - Fiber stacks are carved from one large reservation, with per-worker
     free lists, never an `mmap` per task.
   - A task whose stack bound is proven gets an exact slab. The bound
     comes from the emitted code (`.stack_sizes`), so it counts Zig,
     runtime, and inlined frames. It includes a red zone the size of the
     platform's largest signal frame, and each worker installs an
     alternate signal stack. In practice this applies to leaf compute
     tasks: a task that allocates or does I/O calls through Zig's
     interfaces, which the bound cannot see through.
   - Any other task gets a lazily committed stack. Its guard is at
     least as large as the largest frame, or the compiler emits stack
     probes, because a large frame could otherwise jump a small guard.
   - A call into C switches to the worker's own system stack.
   - Stacks never move, because loans point into them.
8. **Blocking is isolated.** A call that blocks the thread (C code, DNS,
   a large file) runs on a blocking pool, or hands the worker's core to
   another thread for its duration.
9. **Know what every task waits on.** One pointer per task gives:
   - deadlock detection;
   - a dump of what every task waits on;
   - later, priority inheritance, so an actor that a high-priority
     caller waits on runs at that priority.
10. **Tests are deterministic** (built). `rig test` runs on a single-thread
    backend with virtual time and a seed, so a concurrent test fails the
    same way twice.

**The substrate.** Rig writes its own implementation of Zig's `std.Io`
interface, and its own scheduler, beneath it. Zig code and Zig-backed
Rig declarations run on it unchanged, because they see only `Io`. It
takes the system-call code of Zig's backends (io_uring on Linux, kqueue
on macOS and the BSDs) and binds them statically, with no vtable call per
operation.

Zig 0.17's own evented backends are not a foundation:
- each fiber reserves 60 MiB with no guard page;
- their scheduling is a prototype;
- network streams are unfinished on Linux and macOS;
- the kqueue backend cannot cancel.

Tasks run on Rig's own scheduler (docs/internals/scheduler.md). The
first step was built on Zig's `Threaded` backend, which is complete and
preemptive: it proved the language rules, and measured nothing.

**The memory model.** User code has no data races, and the operations
of a Cell of one word are sequentially consistent, so a program sees sequential
consistency. The edges that order it:
- a task's start after the call that made it;
- a task's end before the `wait` that returns its result;
- a message's send before the method it starts;
- a method's return before its caller resumes;
- taking an idle actor before its method runs inline;
- a cancel request before the `Canceled` it causes.

**The target.** It is measured, not assumed, on Linux and macOS, against
Tokio and Go (built: bench/tasks, bench/actors, bench/net, bench/http):
- an HTTP server's requests per second and p99 latency;
- an actor round trip;
- fan-out and fan-in of CPU-bound work;
- memory for a million idle connections.

That last one is stated honestly: a task with an unproven stack costs at
least a page (4 KiB on x86, 16 KiB on Apple Silicon), against Tokio's
hundreds of bytes per task. An HTTP connection that waits for its next
request holds no buffer (its worker lends it one per request), so an
idle connection costs 8.6 KiB on x86 and 16.6 KiB on Apple Silicon,
below Tokio's 10.8 and 18.6 with hyper, and Go's (bench/http).
Smaller committed stacks and io_uring buffer rings are measured work
beyond that, not a promise.

## What else this needs

- **No new keywords or forms.** `Actor`, `Chan`, and `Tasks`
  are types, shared with the `*` Rig already has. `async` and `await`
  stay reserved and unused.
- **Unwinding.** Zig has none. Inside a boundary, a panic travels as a
  hidden error that nothing can catch, and the drops Rig already emits
  as Zig `defer`s run on the way up. The price is an error-union return
  at the Zig level, one branch after each call, which the scheduler-core
  step measures. A program whose only boundary is `main` keeps today's
  immediate exit, so it pays nothing.
- **The runtime's global state moves into each task's or worker's
  context** before the first step, as described under "What may cross
  cores".

## Proof obligations

These fit the existing λRig work in `formal/`, in this order:

1. data-race freedom of the crossing facts and synchronized types, with
   threads in the machine and fork as a step;
2. no value that carries a loan is leaked;
3. no orphans: live tasks form a tree rooted in live frames;
4. deadlock detection is exact for waits on one thing;
5. after a cancel, every fallible waiting point fails;
6. unwinding to a boundary frees nothing a surviving task can reach, and
   nothing outside the boundary that its code could change.

The first slice is proved (formal/README.md, "Tasks and waits"), over
a machine of tasks apart from λRig's expressions:

- **3, no orphans** (`Tasks.no_orphans`, `main_last`): every task is
  held by a running task, directly or through results not yet taken,
  as handles pass to new tasks and back through results;
- **1, for what stays on one thread** (`Tasks.confined`, `pin_kept`):
  two tasks that hold such a value are pinned to one core and stay
  there, which is what local tasks rely on. It needs the rule that a
  task's result moves unless the task is local;
- **5, delivery** (`Wait.cancel_delivered`, `one_waker`, `queued_once`,
  `woken_queued`): the wait protocol queues a waiting fiber exactly
  once when a waker or a cancel ends its wait, and loses no wakeup;
  a cancel is never taken back (`Tasks.cancel_sticky`).
  `test/cli/wait_sync.sh` keeps Wait.lean's word and steps in step
  with src/sched.zig.

The runtime's handshakes are model-checked before more hand proofs
(formal/README.md, "Model checks of the runtime"): the ring's steal,
and how workers search, sleep, and are woken, with the pinned queue's
`idle` flag. Every interleaving within the bounds checked loses no
fiber and takes none twice. One gap shows: work into the global queue,
made while a worker searches, can wait while another sleeps, until
the first worker's next yield check.

The proofs take each step of the wait protocol as sequentially
consistent, so the runtime makes every step of a handshake that has
two sides so: a canceler's store of the flag and load of the wait, and
a waiting fiber's store that begins its wait and load of the flag
(docs/internals/scheduler.md, "Waiting"). A weaker load there lets
the two pass each other on arm64, where both would miss.

Sets, actors, channels, dropping a handle (cancel and wait), the
deadlock walk, and unwinding are the next slices.

## Decisions

Each item gives the answer this document assumes.

1. **The model:** tasks (`f(x)&`), ownership of tasks, actors, and the
   crossing facts, with everything else in `std`. *Yes.*
2. **Tasks:**
   - `Task[T]` is owned, and `>t` and `<t.cancel()` consume it;
   - dropping an unwaited task cancels it and waits;
   - only a fallible task can be canceled;
   - `Task[T!]` is allowed as a type argument.

   *Yes.*
3. **Where tasks go:** by their loans, like a view, and never into a
   shared home. *Yes.*
4. **Checked misuse:** reject a discarded `f()&`, an unwaited fallible
   task on the normal path, and a deadline over tasks that cannot fail.
   *Yes.*
5. **Loans in tasks:** the five soundness rules, and the changes to
   FORMAL-RIG principles 4 and 6. *Yes.*
6. **Cancellation:**
   - sticky, and delivered only at fallible waits;
   - `Canceled` and `Timeout` are ordinary errors in `std`'s `Stop` set,
     carried by the operations that raise them, with no exempt `match`
     arms;
   - infallible waits pass it on;
   - cleanup is shielded, within a grace deadline;
   - compiler checks only yield, and `task.check()!` is the written stop.

   *Yes.*
7. **Crossing:** the fact table. A library that calls a function from
   many tasks at once has the requirement read from its body and checked
   where it is called, with no mark on the function's type. *Yes.*
8. **Synchronized types:** a `Cell` of one word, `Chan`, and `Actor`
   live behind `*`, counted atomically, and change by a marked call
   through a handle you hold, as any `Cell` does. A read view only reads, so CORE needs no
   amendment. *Yes.*
9. **Actors:**
   - made with `*Actor(x)`, with no keywords;
   - `!` marks a change;
   - no `<@`, `keeps`, or `from` method through a handle;
   - deadlines from `time.within`, with no `within:` on calls;
   - a call not yet started is withdrawn on a cancel or deadline, and a
     started method finishes while its caller waits.

   *Yes* (built).
10. **Mailbox and idle path:**
    - waiting calls unbounded, `&` calls bounded;
    - an idle actor runs inline, as the actor, when the stack has room.

    *Yes.*
11. **Deadlock** (built): detection at the closing call, which panics with the
    cycle, and a lint. *Yes.*
12. **Failure:**
    - errors as values;
    - a panic unwinds to the nearest boundary: `main`, `task.isolate`
      (which `http.serve` uses for each request), or an actor;
    - a dead actor's waiting caller panics too;
    - supervisors restart actors and functions;
    - a program whose only boundary is `main` keeps today's exit.

    *Yes.*
13. **Local tasks**, pinned to one thread, so that `*T`, `Cell`, and
    `Signal` code (GUI programs) can use `&`; the checker makes a task
    local when what it is passed stays on one thread. *Yes* (built).
14. **The engine:** Rig's own `std.Io` implementation and scheduler, on
    the ten principles above. *Yes.*
15. **Order of work**, each step its own pull request:
    1. moving the runtime's global state into task context, then `&`,
       `Task`, `Tasks`, the loan and cancellation rules, and
       `task.both`, on `Threaded`;
    2. the crossing facts, a `*Cell` of one word across tasks, and `par`;
    3. actors, unwinding, `task.isolate`, and supervised actors;
    4. the scheduler core, benchmarked with no I/O;
    5. I/O, timers, `http.serve`, and the benchmarks against Tokio and
       Go;
    6. local tasks, `Chan`, `select`, and `supervise`.

    *Yes.*
