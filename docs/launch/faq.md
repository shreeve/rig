# Questions and answers

Answers to what readers of [post.md](post.md) are likely to ask. Each
points at where the repository says more.

## Why is waiting a sigil, not a keyword?

Because in Rig the mechanics of the language are sigils, and the words
are its libraries. Moving a value is `<x`, lending it is `?x` or `!x`,
and running a call at the same time is `f(x)&`. Taking that work back
is the same kind of act, so it is the same kind of mark: `>t`. The two
read as a pair, `&` sending the work off and `>` taking it back, and
`print(>t, >u)` says in two characters what other languages say in
words:

| Language | Start | Take the result |
|---|---|---|
| Rig | `t = f(x)&` | `>t` |
| Rust (Tokio) | `let t = tokio::spawn(f(x));` | `t.await?` |
| Go | `go func() { ch <- f(x) }()` | `<-ch` |
| Java | `var t = executor.submit(() -> f(x));` | `t.get()` |
| Swift | `async let t = f(x)` | `await t` |

Only a task started with `&` is waited for with `>`. An ordinary call
that waits, on a socket or a timer, is just a call, with no mark at
all. Policies stay words: `<t.cancel()`, `<ts.wait_first()`.

## Isn't this just Go?

Go got the most important thing right: a function that waits is an
ordinary function. Rig keeps that and adds what Go leaves to the
programmer. Go lets two goroutines write the same map; its runtime may
catch that and abort, and most other races show up only when the race
detector is on. Rig's compiler rejects them, because a task keeps the
loans of what it is given and only values that are safe to move or share
may cross cores. A goroutine can outlive everything that started it; a
Rig task cannot outlive its owner: dropping one waits for it,
canceling it first when it can fail. Go's `context.Context` is passed by hand to every call that
should stop; Rig's cancel and deadline reach every waiting point on
their own. And Go's mutex is a lock you must remember to take; Rig's
actor is the only way to reach the state, and an idle one costs about
what the lock does.

## How is it different from Java's virtual threads?

Virtual threads, like Go's goroutines, remove `async`. They keep
everything else of threads: shared mutable objects, locks, and data
races the compiler cannot see. Rig's tasks are cheap in the same way,
and also checked.

## How is it different from Rust's async?

Rust rules out data races at compile time, as Rig does, but it does it
with `async fn`, futures that must be pinned, `Send` and `'static`
bounds on spawned work, and cancellation that happens by dropping a
future at any `.await`. Rig has no second kind of function: any function
may wait, and only a task started with `&` is waited for, with `>t`. A task may borrow its caller's data, since it cannot outlive
its caller. Cancellation arrives only at waiting points, as an error,
never in the middle of an expression, and it stays: every later waiting
point fails too, so a `catch` cannot swallow it and carry on.

## How is it different from Swift's actors and structured concurrency?

Swift is the closest relative. It has structured tasks, actors, and
data-race checking. It also has `async` and `await`, and every call to
an actor is an `await`, with the actor's executor deciding when it
runs; Swift actors are reentrant, so an actor's state can change across
an `await` in its own method. Rig has no `await`: a call that waits is
an ordinary call, and a task is taken back with `>t`. A call to an idle
actor runs at once on the caller's stack; and Rig's actors are not
reentrant, so a method runs to its end with no one else inside, and a
call that would need reentrance is a deadlock that Rig reports.

## How is it different from Erlang?

Erlang has the best story for failure: processes that die and
supervisors that restart them. Rig takes that, for actors
(`*Actor.supervised`) and for functions (`task.supervise`). Erlang
copies every message and has no shared memory; Rig's tasks can read
their caller's data in place, and its actors run on the caller's stack
when idle, so most calls cost nanoseconds, not a message.

## How is it different from Pony?

Pony also rules out data races in the type system, with reference
capabilities, and runs actors. Its capabilities are a rich vocabulary to
learn (`iso`, `val`, `ref`, `box`, `trn`, `tag`); Rig's model is the
four ownership marks it already has, plus facts the compiler infers
about each type. Pony's actors only send asynchronous messages; Rig's
calls can wait for an answer.

## How is it different from Trio's nurseries?

Trio showed that a task should never outlive the block that started it.
Rig makes that the default for every task, with no nursery object: the
scope that holds the task is the group, and the compiler knows what the
task borrowed from it.

## Are data races impossible?

That is the design: a task keeps the loans of what it is given, a value
crosses cores only when its type says it may, and shared state that
changes is a one-word `*Cell` (atomic) or an actor (one method at a
time). The proofs so far cover parts of this, not all of it:
ownership soundness for a core of the language, the wait protocol, and
that tasks never outlive their owners and that values bound to one
thread stay there ([formal/README.md](../../formal/README.md)). A proof
of data-race freedom for the full model is still to come.

## What does a task cost in memory?

A task is a fiber with a stack of its own. Its stack reserves a large
range of address space, but only the pages it touches are real memory,
and it touches at least one: 16 KiB on Apple Silicon, 4 KiB on x86-64
Linux. That puts a task at about 17 KiB on the Mac and 5.2 KiB on Linux,
against about 300 bytes for a Tokio task, whose state machine is sized
by the compiler. For a server, the number that matters is an idle
connection, and there Rig holds no buffers while a connection waits, so
it costs 17.0 KiB on the Mac and 9.2 KiB on Linux, less than Tokio or Go
([benchmarks.md](benchmarks.md)).

## Why is the HTTP number on Linux so much higher than hyper's?

We are not sure yet, which is why the post asks for it to be
reproduced. The benchmark is a loopback one: the load generator, written
in Go and the same for every server, shares the machine with the server,
so a server that uses less CPU leaves more for the load. On the Mac,
hyper is a little ahead of Rig, and Go a little behind both. The method and
the scripts are in `bench/http`.

## Are there channels?

Yes: `*Chan[T](n)` is a bounded channel, and `task.select` waits on
several and commits exactly one arm, rotating among those ready so none
starves. Send and receive are waiting points, so a cancel or a deadline
stops them like any other wait.

## What about I/O?

Each worker thread sleeps in a kqueue or epoll poller of its own, and a
task that waits for a socket simply waits. `std.net` has TCP listeners
and connections, and `std.http` has an HTTP/1.1 server. There is no TLS
and no HTTP client yet, and files are read on a blocking pool.

## What platforms does it run on?

The scheduler runs on macOS and Linux, on arm64 and x86-64. Rig
compiles to Zig, which compiles to native code.

## What happens when two tasks deadlock?

When the deadlock involves actors, the wait that closes the cycle
panics and names the calls, such as `Bank.pay -> Ledger.post ->
Bank.balance`, so the program does not hang. Waits on tasks and on sets
of tasks count too. A wait on a channel, in a send, a receive, or a
`select`, is not followed, since any task holding the channel could end
it; a cycle through one hangs as it would in Go.

## What happens when a panic happens inside an actor?

The actor dies: its state, possibly half-changed, is never served again,
and is not dropped. The caller waiting on that method panics too, and so
does every later call, naming the method that killed the actor. Inside
`task.isolate`, or inside `http.serve`'s handler, the panic stops there:
one call fails, and the program goes on. A supervised actor makes a
fresh value instead, within a restart limit.

## Can I use it today?

Yes, for experiments. The language, its standard library, and the
concurrency model are young and still changing. Everything described in
the post is built and documented, in SPEC.md section 18 and
docs/STD.md, and its concurrency tests run again under 20 seeded
schedules.
