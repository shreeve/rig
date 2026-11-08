# The concurrency model: its reviews and decisions

The history behind [docs/design/concurrency.md](../../../design/concurrency.md),
moved here from it on 2026-11-07, when [docs/CONCURRENCY.md](../../../CONCURRENCY.md)
became the overview and the design doc the reference for the rules.
Each section is as the design doc had it; the rules it states are still
in the design doc, and what is planned is in
[docs/ROADMAP.md](../../../ROADMAP.md), "Concurrency".

## The reviews behind the model

It draws on three expert reviews, which an adversarial review then
attacked:
- Tokio's runtime source;
- the models of Go, Erlang/BEAM, Java Loom, .NET, and JavaScript;
- Zig 0.17's `std.Io`, structured-concurrency theory, scheduling theory,
  and soundness.

The reports reviewed earlier drafts and are not kept: their findings are
folded into the model below, and a few of their proposals were set aside
here. Decisions are listed at the end.

## Rig and Tokio, as first written

Tokio, Rust's async runtime, is the measure of a fast one. Rig's tasks
go further than it in six ways, each following from the model, and
aim to match it in the rest.

**Where Rig goes further:**

- **One kind of function.** There is no `async` or `await`, no second
  kind of function, no `Pin`, no `'static` bound, and no `Arc` around
  data a task only reads. Any function runs as a task with `&`, and a
  function that waits on a socket is an ordinary function, called as
  any other.
- **Tasks view in place.** `score(?d)&` reads `d` where it is, with
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
  yield check in every loop and on every cycle of recursive calls of a
  program that makes tasks, so a task waiting behind one waits for a
  slice of it, not all of it. Tokio never stops a running task, and Go
  stops one after 10 ms.
- **Errors stay the call's own.** `Task[Page!]` gives back the error
  the call failed with, from the call's own error set; a canceled task
  fails with `Stop.canceled`, an ordinary member of that set. A Tokio
  `JoinHandle` gives a `JoinError` around a panic or a cancellation.

**Where Tokio is still ahead:**

- **I/O.** Tokio's engine for sockets, files and timers (epoll, kqueue,
  io_uring) is tuned by years of real load. Rig's is newer: a poller for
  each worker, kqueue or epoll ([the scheduler](../internals/scheduler.md)).
- **Memory for a task at rest.** A Tokio task can be a few hundred
  bytes; a Rig task holds a page of its stack, 17 KiB on the Mac and
  5.2 KiB on Linux. Closing that gap, with smaller committed stacks, is
  measured work ([the scheduler](../internals/scheduler.md), "Stacks").
- **Maturity.** Its ecosystem, its tooling, and its years in
  production.

`bench/tasks` times Rig's tasks against Tokio's and Go's on starting,
waiting, spreading work over cores, switching, and waiting behind a
long computation, and measures the memory a task takes. Rig is ahead
of Tokio wherever the scheduler is what is measured, and behind in
memory ([docs/launch/benchmarks.md](../launch/benchmarks.md)), and
`bench/tasks/PROGRESS.md` records each step of the scheduler
([docs/internals/scheduler.md](../internals/scheduler.md)).

## What a program writes, as first written

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
  time.within(2 * time.SECOND, |<ts| >ts!)!
```

The first error, or the deadline, cancels the rest and waits for them.

Two different calls at once:

```text
u, o = task.all(user(id)&, orders(id)&)!
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
captures must sync, as `par.map`'s do.

## One `&` for every kind of task, as first written

**One `&` for every kind of task.** A connection handler, an actor's
method, a pipeline's stage, and a divide-and-conquer split are all
`f()&` and `>t` on one scheduler. Rust needs two runtimes for these,
Tokio's state machines and Rayon's thread stacks, which do not mix.
*Planned:* fork-join at no cost under the same `&`. An unstarted task
that its maker waits for, with no deadline, runs on the waiter's stack
with its record in the maker's frame, as `rayon::join` runs its closure;
a task taken by a thief, or waited for later, is a fiber as now
([ROADMAP](../ROADMAP.md), "Tasks as small and as cheap as the best
runtimes'").

## Why Rig has its own scheduler

Zig 0.17's own evented backends are not a foundation:
- each fiber reserves 60 MiB with no guard page;
- their scheduling is a prototype;
- network streams are unfinished on Linux and macOS;
- the kqueue backend cannot cancel.

So Rig has its own scheduler. Zig code that a program calls runs on a
`Threaded` instance of `std.Io` on the calling thread, which runs no
tasks. The first step of the order of work (decision 15) ran on that
backend alone, which is complete and preemptive: it proved the language
rules, and measured nothing.

## What else this needs

- **No new keywords or forms.** `Actor`, `Chan`, and `Tasks`
  are types, shared with the `*` Rig already has. `async` and `await`
  stay reserved and unused.
- **Unwinding.** Zig has none, so a boundary abandons the frames
  between it and the panic (see "Failure") and runs none of their
  drops. Nothing is paid on the normal path, and a program whose only
  boundary is `main` ends where the panic stands.
- **The runtime's global state lives in each task's context**
  (`TaskState`), as described under "What may cross cores".

## Decisions

Each item gives the answer the model takes.

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
   principles 4 and 6 of [formal-plan.md](formal-plan.md). *Yes.*
6. **Cancellation:**
   - sticky, and delivered only at fallible waits;
   - `Stop.canceled` and `Stop.timeout` are ordinary errors of `std`'s `Stop` set,
     carried by the operations that raise them, with no exempt `match`
     arms;
   - infallible waits pass it on;
   - cleanup is shielded, within a grace deadline *(planned: until
     then every waiting point after a cancel fails, cleanup's too, as
     SPEC §18 says)*;
   - compiler checks only yield, and `task.check()!` is the written stop.

   *Yes.*
7. **Crossing:** the fact table. The checker types `par.map`, `par.each`,
   `par.workers`, and `http.serve` itself, reading what they need of the
   closure passed and checking it where it is called, with no mark on
   the function's type. A general rule that reads the requirement from
   a library's body is not built. *Yes.*
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
    - a panic stops at the nearest boundary: `main`, `task.isolate`
      (which `http.serve` uses for each request), or an actor;
    - a dead actor's waiting caller panics too;
    - supervisors restart actors and functions;
    - a program whose only boundary is `main` ends where the panic stands.

    *Yes.*
13. **Local tasks**, pinned to one thread, so that `*T`, `Cell`, and
    `Signal` code (GUI programs) can use `&`; the checker makes a task
    local when what it is passed stays on one thread. *Yes* (built).
14. **The engine:** Rig's own scheduler, as described in
    [docs/internals/scheduler.md](../internals/scheduler.md). *Yes.*

