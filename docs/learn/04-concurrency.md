# Concurrency without async

Here is a function that waits on the network, and one that calls it:

```python
async def fetch_user(id):
    return await db.get(id)

def report(id):
    user = fetch_user(id)
    print(user.name)
```

`report` breaks. `fetch_user` is `async`, so calling it gives a
coroutine, not a user. To fix it, `report` must become `async` too,
and then everything that calls `report`. Waiting has split the program
into two kinds of function. Rust, JavaScript, and C# have the same
split.

Threads avoid the split, and bring other trouble. Two threads write one
map, and nothing stops them. A lock forgotten on one path shows up in
production, once a month. Two locks taken in the wrong order hang the
program, and nothing says why.

Rig has no `async` and no locks. This chapter runs work at the same
time with two sigils, shares state through actors, and shows what
happens when it goes wrong. Every program here runs with
`bin/rig run FILE.rig`, and prints what the `output` block below it
shows.

## Send it off, take it back

`&` after a call, the dispatch sigil, runs it as a task. `>`, the wait
sigil, takes its result back:

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

```output
25 7
```

`sq(5)&` starts `sq` and gives at once a `Task[Int]`, which holds the
result when the task ends. `>t` waits for that end and takes the
result. The wait uses the task up, so `t` is gone after it.

`total` and `sq` are ordinary functions. Nothing in their declarations
says they may run as tasks. A function that sleeps or reads a socket is
ordinary too, and calling it is an ordinary call with no mark. Only a
task started with `&` is waited for with `>`.

A task has to be waited for somewhere. One started and forgotten is a
mistake the compiler names:

```rig reject
sub log(n: Int)
  print(n)

sub main()
  log(1)&
```

```error
this task is dropped as soon as it starts
```

## A task belongs to its owner

`total(?xs)&` lends `xs` to the task. The loan lasts until `>u` takes
the result, so the task reads the list in place, with no copy and no
lock. Nothing may change the list meanwhile:

```rig reject
fun total(xs: ?List[Int]) -> Int
  xs.sum()

sub main()
  xs = List([3, 4])
  u = total(?xs)&
  !xs.push(1)
  print(>u)
```

```error
cannot lend `xs` to write while a read loan is live
```

That is the rule for every view, from [Sigils](01-sigils.md). It holds
because a task never outlives the scope that owns it. Dropping a task
that was not waited for waits for it, and cancels it first if it can
fail. So there are no detached tasks, and a task may even write its
caller's data:

```rig
sub fill(xs: !List[Int], n: Int)
  for i in 0..n
    !xs.push(i)

sub main()
  xs = List[Int]()
  t = fill(!xs, 3)&
  >t
  print(xs)
```

```output
[0, 1, 2]
```

A task that can fail carries its error back. One the program forgets
would lose that error, so the compiler asks for the wait:

```rig reject
error Parity
  odd

fun half(x: Int) -> Int!
  return Parity.odd if x % 2 == 1
  x / 2

sub main()
  t = half(3)&
  print("done")
```

```error
the task `t` can fail, and it is dropped where its scope ends without being waited for
```

## Many tasks at once

`Tasks[T]` holds a set of tasks of one type. `>ts` waits for all of
them, and `<ts.wait_first()` takes the first to succeed:

```rig
use std.time

error Mirror
  down

fun fetch(mirror: Int, ms: Int) -> Int!
  time.sleep(ms * time.MS)!
  return Mirror.down if mirror == 1
  mirror * 100

sub main()!
  all = Tasks[Int!]()
  !all.add(fetch(2, 20)&)
  !all.add(fetch(3, 1)&)
  print(>all!)
  any = Tasks[Int!]()
  !any.add(fetch(1, 1)&)
  !any.add(fetch(2, 5)&)
  !any.add(fetch(3, 60_000)&)
  print(<any.wait_first()!)
```

```output
[200, 300]
200
```

`!all.add(...)` moves a task into the set, which keeps its loans as the
task did. `>all` gives the results in the order the tasks were added,
not the order they ended, so mirror 3 finishing first changes nothing.
When a task in the set fails, the rest are canceled and the wait fails
with that error.

`<ts.wait_first()` is a word, not a sigil, because it is a policy: it
takes the set, returns the first success, and cancels the rest. Mirror
1 fails, mirror 2 answers, and mirror 3's minute of sleep is canceled
at once. It works only for tasks that can fail, since the losers must
be stopped.

## A counter many tasks share

A task gets its own view of what it is lent. State that many tasks
change needs one home, behind `*`. A `*Cell` of one word, such as an
`Int`, is the simplest:

```rig
sub work(hits: *Cell[Int])
  for 0..1000
    !hits.add(1)

sub main()
  hits = *Cell(0)
  ts = Tasks[Void]()
  for 0..8
    !ts.add(work(+hits)&)
  >ts
  print(hits.get())
```

```output
8000
```

`+hits` makes another handle to the same cell, one for each task.
Every change is a marked call, `!hits.add(1)`, through a handle the
task holds. When a program makes tasks, each operation on a one-word
cell becomes one atomic instruction, so no count is lost. Rig needs no
separate atomic type: a counter or a flag is a `*Cell` of one word.

## An actor for anything larger

A list cannot change in one instruction. State larger than a word goes
in an actor:

```rig
obj Ledger
  entries: List[Int]

  sub post(!@, n: Int)
    !@entries.push(n)

  fun count(?@) -> Int
    @entries.len

sub work(ledger: *Actor[Ledger])
  for 0..100
    !ledger.post(1)

sub main()
  ledger = *Actor(Ledger(entries: List[Int]()))
  ts = Tasks[Void]()
  for 0..4
    !ts.add(work(+ledger)&)
  >ts
  print(ledger.count())
```

```output
400
```

`*Actor(x)` moves a value into an actor and gives a shared handle to
it. Nothing in `Ledger` changes. Its methods run one at a time, each to
its end, so the ledger is never seen half-changed. A `?@` method is
called bare, `ledger.count()`, and a `!@` method is marked,
`!ledger.post(1)`.

An actor usually means a message, a queue, and a switch for every
call. In Rig, a call that finds the actor idle takes it in one atomic
step and runs the method on the caller's own stack. Only a call that
finds it busy waits, as it would for a mutex, and is then queued. So
an idle actor costs about what a lock does: about 5 ns a call on an
Apple M5, against 3.5 ns for a Go mutex and 135 ns for the usual Tokio
actor. Rig has no `Mutex` type: an idle actor already is one, and its
state can be reached no other way.

## Channels

Tasks that hand values along a line use a channel. `*Chan[T](n)` holds
up to `n` values:

```rig
sub numbers(out: *Chan[Int], n: Int)!
  for i in 1..n + 1
    !out.send(i)!
  !out.close()

sub squares(src: *Chan[Int], out: *Chan[Int])!
  while (!src).recv()! as v
    !out.send(v * v)!
  !out.close()

sub main()!
  a = *Chan[Int](2)
  b = *Chan[Int](2)
  p = numbers(+a, 5)&
  q = squares(+a, +b)&
  while (!b).recv()! as v
    print(v)
  >p!
  >q!
```

```output
1
4
9
16
25
```

`!out.send(i)!` waits for room, then sends. `(!src).recv()!` waits for
a value and gives it as `Int?`, or `none` once the channel is closed
and empty, which ends each `while`. Both change the channel, so both
are marked with `!`, and both can fail, because a canceled task stops
there.

`task.select` waits on several channels and commits exactly one arm:

```rig
use std.task

sub main()!
  jobs = *Chan[Int](4)
  quit = *Chan[Int](1)
  !jobs.send(7)!
  r = task.select(
    (!jobs).on_recv(|v| v ?? 0),
    (!quit).on_recv(|_| -1),
  )!
  print(r)
  !quit.send(1)!
  r = task.select(
    (!jobs).on_recv(|v| v ?? 0),
    (!quit).on_recv(|_| -1),
  )!
  print(r)
```

```output
7
-1
```

The first select finds a job waiting, and the second finds only the
quit. When several arms are ready at once, the select takes them in
turn, so none starves, and an arm that loses never takes its value.

## Deadlocks that report themselves

An actor runs one method at a time. So a method that calls back into
its own actor, directly or through others, waits for itself:

```rig
obj Ledger
  n: Int

  fun post(!@, bank: *Actor[Bank]) -> Int
    @n += 1
    bank.balance()

obj Bank
  money: Int

  fun pay(!@, ledger: *Actor[Ledger], me: *Actor[Bank]) -> Int
    @money -= 1
    (!ledger).post(<me)

  fun balance(?@) -> Int
    @money

sub main()
  bank = *Actor(Bank(money: 10))
  ledger = *Actor(Ledger(n: 0))
  print("paying")
  print((!bank).pay(+ledger, +bank))
```

`Bank.pay` calls `Ledger.post`, which calls `Bank.balance`, which
cannot run while `pay` does. Written with locks, this program would
hang. In Rig it prints `paying`, then panics with the cycle:

```text
panic: deadlock: these calls wait on each other, and none can go on: Bank.pay -> Ledger.post -> Bank.balance
```

Every wait records what it waits on, and the wait that would close a
cycle walks the chain and finds it. Waits on tasks and on sets count
too: a method that waits on a task that calls its own actor is the
same cycle. Waits on channels are not followed, since any task holding
the channel could end them; a cycle through a channel hangs, as it
would in Go.

## A panic stops at a boundary

A deadlock is a bug, and a bug in Rig panics. A panic ends the program,
unless a boundary stops it first. `task.isolate(f)` is one:

```rig
use std.task

fun pick(xs: ?List[Int], i: Int) -> Int
  xs[i]

sub main()
  xs = List([10, 20, 30])
  print(task.isolate(|?xs| pick(?xs, 1)) catch -1)
  r = task.isolate(|?xs| pick(?xs, 7)) catch |e|
    print("stopped:", e)
    -1
  print(r)
  print("still running")
```

```output
20
stopped: Stop.panicked
-1
still running
```

The panic's report still goes to stderr, and the isolate fails with
`task.Stop.panicked`. The tasks started inside are canceled and waited
for. Nothing outside `f` may be lent to it to write, so all a panic
could have half-changed is `f`'s own, and that is abandoned.
`http.serve` runs each request this way: a bug answers that request
with a 500, and every other request goes on.

An actor is a boundary too. A panic in one of its methods ends the
actor, since its state may be half-changed, and every later call
panics, naming the method that killed it:

```text
panic: Seats.book: the actor died from a panic in Seats.seat
```

`*Actor.supervised(make)` starts a fresh value instead:

```rig
use std.task

obj Seats
  taken: List[Int]

  fun book(!@, row: Int) -> Int
    !@taken.push(row)
    @taken.len

  fun seat(?@, i: Int) -> Int
    @taken[i]

sub main()
  hall = *Actor.supervised(*|| Seats(taken: List[Int]()))
  print((!hall).book(4))
  print((!hall).book(9))
  print(task.isolate(|+hall| hall.seat(5)) catch -1)
  print((!hall).book(2))
```

```output
1
2
-1
1
```

`seat(5)` panics, and the isolate around the call stops it there. The
actor calls `make` again, so the next booking is the first in a new,
empty hall. `restarts: n, per: ns` limits how often it may start again.

## Stopping a task

Only a task that can fail can be canceled, because cancellation arrives
as an error, `task.Stop.canceled`. It arrives at the task's next
waiting point, such as `time.sleep`, `task.check()`, or a wait on a
task:

```rig
use std.task
use std.time

fun nap() -> Int!
  defer print("nap stops")
  time.sleep(10 * time.SECOND)!
  1

fun stubborn() -> Int!
  time.sleep(10 * time.SECOND) catch print("caught once")
  task.check()!
  2

sub main()
  u = nap()&
  v = stubborn()&
  print(<u.cancel() catch -1)
  print(<v.cancel() catch -2)
```

```output
nap stops
-1
caught once
-2
```

`<t.cancel()` takes the task, cancels it, waits for it, and gives what
it gave. `nap` fails in its sleep, and its `defer` runs as for any
failure. `stubborn` catches the first failure and tries to carry on,
but the cancel stays: its next waiting point, `task.check()`, fails
too. A `catch` cannot swallow a cancel.

A task that cannot fail runs to its end, and the compiler says so:

```rig reject
fun sq(x: Int) -> Int
  x * x

sub main()
  t = sq(3)&
  print(<t.cancel())
```

```error
`Task[Int]` cannot fail, so it cannot be canceled: it runs to its end; wait for it, `>t`
```

## Deadlines

`time.within(ns, f)` runs `f` with a deadline. Every waiting point
reached past the deadline fails with `task.Stop.timeout`, in `f` and in
every task `f` starts:

```rig
use std.time

error Mirror
  down

fun fetch(mirror: Int, ms: Int) -> Int!
  time.sleep(ms * time.MS)!
  return Mirror.down if mirror == 1
  mirror * 100

fun both(slow: Int) -> List[Int]!
  ts = Tasks[Int!]()
  !ts.add(fetch(2, 20)&)
  !ts.add(fetch(3, slow)&)
  >ts!

sub main()
  print(time.within(time.SECOND, || both(1)!) catch List[Int]())
  r = time.within(50 * time.MS, || both(60_000)!) catch |e|
    print(e)
    List[Int]()
  print(r)
```

```output
[200, 300]
Stop.timeout
[]
```

`both` knows nothing about deadlines. The second call's slow fetch
sleeps only until the deadline, then fails, and the set's wait fails
with it. There is no context object to pass down, and no token to
check by hand. Inside another deadline, the earlier one holds. A loop
that reaches no waiting point is not stopped, so a long computation
calls `task.check()!` where stopping is safe.

A task started before the deadline gets one too. `time.within` calls
its closure once, so the closure may move the task in, `|<t|`, and
wait for it:

```rig
use std.time

fun fetch(ms: Int) -> Int!
  time.sleep(ms * time.MS)!
  ms

sub main()
  t = fetch(60_000)&
  print(time.within(20 * time.MS, |<t| >t!) catch -1)
```

```output
-1
```

Past the deadline the wait cancels `t` and fails. A closure is
otherwise kept for every call, so it cannot give up what it holds;
`within` declares that it calls its closure once, `f: once ?fun() ->
R!`, and only a closure passed to such a parameter may move a capture
out.

## Each element on several tasks

`par.map` and `par.each` of `std.par` spread a loop over the cores:

```rig
use std.par

fun square(n: Int) -> Int
  n * n

sub main()
  xs = List([1, 2, 3, 4])
  k = 10
  print(par.map(?xs, |+k, x| x * k))
  print(par.map(?xs, square, limit: 2))
  par.each(!xs, |x| x += 1)
  print(xs)
```

```output
[10, 20, 30, 40]
[1, 4, 9, 16]
[2, 3, 4, 5]
```

`par.map` gives its results in the order of `xs`, and `par.each` hands
each task a write view of its own elements. `limit:` caps how many
tasks run at once. Every task calls the same closure, so what it
captures must be safe to read from all of them. A capture lent to
write is not:

```rig reject
use std.par

sub main()
  xs = List([1, 2, 3])
  total = 0
  par.each(!xs, |!total, x| total += x)
```

```error
`par.each` calls the closure on several tasks at once, and `|!total|` lends `total` to write
```

The rest of that message names the two ways out: gather with
`par.map`, or count with a `*Cell[Int]`.

## Tasks that stay on one core

The compiler knows, for each type, whether its value may move to
another core, and whether two cores may read it at once. A plain `*T`
handle may do neither, because its count is not atomic. A task given
one still runs:

```rig
obj Node
  v: Int

fun val(n: ?*Node) -> Int
  n.v

sub main()
  n = *Node(v: 1)
  t = val(?n)&
  print(>t)
```

```output
1
```

This task is *local*: it runs on the thread of the task that made it,
which stays there too, so no count changes on two cores at once. Local
tasks take turns on one core, at their waits. They give concurrency,
not parallelism, which is what a GUI program's `*T`, `Cell`, and
`Signal` code needs. Nothing marks a local task; the compiler picks.
To run on another core, pass what crosses: a one-word `*Cell`, a
channel, an actor, or a copy.

## Tests that replay

`bin/rig run --seed=N FILE.rig`, and `rig test`, run concurrent code
on one thread with a virtual clock. The seed picks which ready task
runs next, so the same seed runs the same way again, and sleeps take
no time. The suite runs every program in this chapter that way too,
and each prints the same output. Journey 08, Tests that fail the same
way twice, shows how to find a race with one seed and replay it.

## Summary

| To | Write |
|---|---|
| run a call as a task | `t = f(x)&` |
| take its result | `>t`, or `>t!` when it can fail |
| run many, take them all | `!ts.add(f(x)&)`, then `>ts` |
| take the first success | `<ts.wait_first()` |
| count across tasks | `*Cell(0)`, `!c.add(1)` |
| share larger state | `*Actor(x)`, `!a.method()` |
| pass values along | `*Chan[T](n)`, `!ch.send(<v)!`, `(!ch).recv()!`, `task.select` |
| stop a bug at a boundary | `task.isolate(f)`, `*Actor.supervised(make)` |
| stop a task | `<t.cancel()` |
| give work a deadline | `time.within(ns, f)` |
| spread a loop over cores | `par.map(?xs, f)`, `par.each(!xs, f)` |

A task is a call whose loan lasts until its result is taken. Everything
else follows from the rules of the earlier chapters: views and loans
keep tasks from racing, and a task's owner is where it ends.

**Concurrency is marked where it happens, and nowhere else.**

## What is not there yet

The scheduler runs on macOS and Linux, on arm64 and x86-64. A task holds
at least one page of stack, so it costs about 17 KiB on the Mac and 5.2
KiB on Linux, against about 300 bytes in Tokio. A cycle through a
channel, or through a full mailbox, is not yet reported. Networking is
TCP and an HTTP/1.1 server, with no TLS or HTTP client yet. Proofs in
Lean cover models of the wait protocol and of task ownership, but not
yet data-race freedom for the full model.

## Where to go next

- [SPEC §18](../../SPEC.md#18-tasks) states every rule of tasks, sets,
  isolates, deadlines, actors, channels, and `par`.
- [The launch post](../launch/post.md) measures what tasks and actors
  cost against Tokio and Go.
