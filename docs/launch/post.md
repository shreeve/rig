# Concurrency without async

Concurrent code has long meant choosing between two kinds of pain.
Threads and locks let anything run beside anything, and leave the data
races and deadlocks for production to find. Async and await made
waiting cheap, and split every codebase in two: functions that can wait
and functions that cannot, with `Pin`, cancellation tokens, and
`'static` bounds in between.

Rig takes neither path. It has two marks:

```rig
fun total(xs: ?List[Int]) -> Int
  xs.sum()

fun sq(x: Int) -> Int
  x * x

sub main()
  xs = List([3, 4])
  t = sq(5)&
  u = total(?xs)&
  print(>t, >u)
```

`&` after a call sends the work off as a task. `>` takes its result
back. There is no `async fn`, no `await` on every call, and no executor
to set up. `total` and `sq` are ordinary functions, and so is any
function that sleeps, reads a socket, or waits on another task.
Serial code is the default; concurrency is marked exactly where it
happens.

## A family of sigils

Rig is a compiled language with ownership, like Rust, with fewer rules.
Its mechanics are sigils and its libraries are words: how a value is
bound, taken, lent, held, failed, or run at the same time is a
one-character mark that means the same thing wherever it appears.

| Mechanic | Sigils |
|---|---|
| Binding | `x = e` binds, `x =! e` binds for good |
| Taking and copying | `<x` moves (alone on a line, drops), `+x` copies or makes another handle |
| Lending | `?x` lends to read, `!x` to write; as types, `?T` and `!T` |
| Holding | `*x` shared (`*w` upgrades a weak handle), `^x` boxed, `~x` weak, `@` self |
| Failure and absence | `T?` may be absent, `T!` may fail; `e?` and `e!` pass them on |
| Concurrency | `f(x)&` sends work off, `>t` takes its result back |

Concurrency is the last row, built on the same rules as the rest. A
policy a library chooses stays a word: `<t.cancel()`,
`<ts.wait_first()`.

## A task belongs to its owner

`total(?xs)&` lends `xs` to the task to read, and the task keeps that
loan until `>u` takes its result. The task reads the list in place,
with no copy and no reference count, and nothing may change it
meanwhile:

```rig
sub main()
  xs = List([3, 4])
  u = total(?xs)&
  !xs.push(1)
  print(>u)
```

```text
error: cannot lend `xs` to write while a read loan is live
```

That is the same rule Rig applies to any view, and it holds because a
task never outlives the scope that owns it: dropping a task that was
not waited for cancels it, if it can fail, and waits for it. There are
no detached tasks and no `'static` bounds. The compiler also knows, for
every type, whether a value may move to another core or be read from
two at once, and picks where each task may run. A programmer meets
those facts only as error messages, or not at all.

## Shared state, marked

State that many tasks change lives behind `*`, and every change is a
call marked `!` through a handle you hold. A one-word `*Cell`, such as
a counter, becomes atomic instructions. Anything larger goes in an
actor:

```rig
obj Ledger
  entries: List[Int]

  sub post(!@, n: Int)
    !@entries.push(n)

  fun count(?@) -> Int
    @entries.len

sub work(l: *Actor[Ledger])
  for 0..100
    !l.post(1)

sub main()
  l = *Actor(Ledger(entries: List[Int]()))
  ts = Tasks[Void]()
  for 0..4
    !ts.add(work(+l)&)
  >ts
  print(l.count())
```

`*Actor(x)` moves the value into the actor; nothing in `Ledger`
changes. Its methods run one at a time, each to its end, so the ledger
is never seen half-changed. `>ts` waits for every task of the set.

An actor usually means a message, a queue, and a switch for every call.
In Rig, a call that finds the actor idle takes it in one atomic step
and runs the method on the caller's own stack. Only a call that finds
it busy waits a moment, as a mutex would, and is then queued. So an
actor nobody else is using costs about what a lock does: about 5 ns a
call on an Apple M5, against 3.5 ns for a Go mutex and 135 ns for the
usual Tokio actor, a task serving a channel. Rig has no `Mutex` type,
because it does not need one.

## When it goes wrong

**Deadlocks are reported, not suffered.** An actor runs one method at a
time, so a call back into it, directly or through others, can never be
answered. Every wait records what it waits on, and the wait that closes
a cycle finds it and panics with the calls:

```text
panic: deadlock: these calls wait on each other, and none can go on: Bank.pay -> Ledger.post -> Bank.balance
```

The program does not hang. Waits on tasks and on sets count too.

**A panic stops at a boundary.** `task.isolate(f)` runs `f`, and a panic
in it, or in any task it started, fails the call with
`task.Stop.panicked` while the program goes on. A panic in an actor's
method ends that actor, whose state is never served again, and every
later call panics, naming the method that killed it.
`*Actor.supervised(make)` starts a fresh value instead.

## A small server, three ways

A server with a hit counter every request shares, rooms that people
join, and one route that panics:

```rig
use std.hash
use std.http
use std.net

obj Rooms
  members: hash.Map[String, Int]

  fun join(!@, room: String) -> Int
    n = (@members.get(?room) ?? 0) + 1
    !@members.put(<room, n)
    n

fun pick(xs: ?List[Int], i: Int) -> Int
  xs[i]

sub main()!
  hits = *Cell(0)
  rooms = *Actor(Rooms(members: hash.Map[String, Int]()))
  l = net.listen("127.0.0.1:8080")!
  http.serve(<l, |+hits, +rooms, req|
    match req.path
      "/hit" => http.text(String("hits ", (!hits).add(1)))
      "/join" => http.text(String("members ", (!rooms).join(req.arg("room") ?? String("lobby"))))
      "/boom" => http.text(String(pick(List([1, 2, 3]), 7)))
      _ => http.not_found()
  )!
```

Each connection is a task, and the compiler checks that what the
closure captures is safe to share. Each request runs isolated, so
`/boom` answers 500 and the server goes on.

The same server in Go, and in Rust with Tokio and hyper, is in
[examples/](examples/). All three give the same answers and count 1,000
concurrent hits exactly. Go needs an atomic, a mutex held by hand, and
a wrapper of its own to answer a panic with a 500, since `net/http`
closes the connection instead. Rust needs an `Arc`, a `Mutex`, an
`async fn`, and `catch_unwind` for the same reason. Neither is long.
The difference is what the reader keeps in mind: in Rig, there is no
lock to forget, no future to pin, and no panic that takes a connection
down with it.

## Stopping, and the rest

Only a task that can fail can be canceled, because cancellation arrives
as an error, `task.Stop.canceled`, at the task's next waiting point. It
stays, so a `catch` cannot swallow it and carry on. Deadlines work the
same way: `time.within(ns, f)` makes every wait past the deadline fail
with `task.Stop.timeout`, in `f` and in the tasks it starts. There is
no context object to pass down, and no token to check by hand.

`Tasks[T]` holds a set of tasks, and `task.both(a, b)` waits for two of
different types. `par.map` and `par.each` spread a loop over the cores,
and the compiler checks that the function is safe to call from several
tasks at once. `*Chan[T](n)` is a bounded channel, and `task.select`
commits exactly one of its arms.

## Tests that fail the same way twice

`rig test` runs concurrent code on one thread, with a virtual clock and
a seed that picks which task runs next. The same seed gives the same
interleaving, so a race that fails once fails every time, and the test
prints the seed that replays it. `--seeds=20` runs the tests under
twenty schedules, and sleeps take no time.

## What it costs

Tasks are fibers on a worker thread per core, with work stealing, and
each worker waits on its own kqueue or epoll poller. Long loops yield
to the tasks waiting behind them. Against Tokio and Go, on an Apple M5
and a 22-core Linux machine ([benchmarks.md](benchmarks.md)):

- **Start a task and wait for it:** 44 to 80 ns, against 118 to 250 ns
  in Tokio and 188 to 271 ns in Go.
- **Switch between tasks:** 8 to 10 ns, against 42 to 47 ns in Tokio.
- **Wait behind a long computation:** 77 to 80 µs, against 2.3 to 4.3 ms
  in Tokio and 2.0 to 4.3 ms in Go.
- **Actors under contention:** 8 tasks calling one actor cost 31 to
  35 ns a call, against 65 to 79 ns for a Go mutex.
- **HTTP:** on the Mac, about as many requests as hyper (169,000 a
  second against 179,000). On Linux, 830,000 a second against hyper's
  297,000 and Go's 235,000, with the load generator on the same
  machine. We would like others to reproduce that one.
- **Memory:** a task holds at least one page of stack, so it costs
  17 KiB on the Mac and 5.2 KiB on Linux, against about 300 bytes in
  Tokio. An idle HTTP connection holds no buffers, though, and costs
  17.0 KiB on the Mac and 9.2 KiB on Linux, less than Tokio's or Go's.

## What is new, and what is not

None of these ideas is new on its own. Go and Java's virtual threads
wait without `async`. Rust and Pony rule out data races at compile
time. Trio and Swift keep tasks inside their scope. Erlang and Swift
have actors, and Erlang has supervisors. What Rig adds is all of them
at once, in two marks and no new kind of function; an actor that costs
what a lock does; deadlocks that name their cycle; and tests that
replay exactly.

Some of it is machine-checked. Proofs in Lean show, for a small core of
the language, that a program the ownership checker accepts runs without
a memory fault; and, for models of the runtime, that a wait is ended by
at most one waker, that a cancel reaches a task sleeping in a wait it
may end, and that no task outlives its owner. They cover models, not the compiler
itself, and grow slice by slice.

## What is not there yet

Rig is young. Its scheduler runs on macOS and Linux, on arm64 and
x86-64. Its networking is TCP and an HTTP/1.1 server, with no TLS or
HTTP client yet. A task's stack page makes many idle tasks costlier
than Tokio's, and CPU-heavy work spread over the cores trails Tokio and
Go by 5 to 16 percent, in the compiled loops rather than the scheduler.
Opening a connection on Linux is slower than Tokio's, 36 µs against
31.

The code, the specification (SPEC.md, section 18), the design and its
reviews (docs/CONCURRENCY.md), and every benchmark are in the
repository. If a number here does not hold up on your machine, we want
to know.
