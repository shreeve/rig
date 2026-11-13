# Concurrency in Rig: an overview

How Rig's concurrency works behind its two operators: `f(x)&` starts a
task, and `>t` waits for it and takes its result. This is the short
version. The full model is [design/concurrency.md](design/concurrency.md),
the engine is [internals/scheduler.md](internals/scheduler.md), the
rules are [SPEC §18](../SPEC.md#18-tasks), and
[learn/04-concurrency.md](learn/04-concurrency.md) teaches it.

## The idea

Rig has one kind of function and one task mechanism: no `async` or
`await`, and no thread a program starts. A program says what may
overlap, with `&` after a call, and where it needs a result, with `>t`.
The runtime picks the machinery: which core runs a task, when it
pauses, how it waits on a socket or a timer. A function that sleeps or
reads a socket is an ordinary function. Serial code is the default, and
concurrency is marked where it happens. `t = sq(5)&` gives at once a
`Task[Int]`, an owned value that holds the result once the task ends;
`>t` waits for that end, takes the result, and uses the task up.

## Seven styles, one mechanism

Other languages offer each style as a library or a runtime of its own.
Rig gives each through the same `&` and `>t`, on one scheduler.

| Style | Known from | What a Rig program writes |
|---|---|---|
| Threads and preemption | OS threads, Go | nothing: the runtime runs a worker per core |
| Async I/O | Tokio | an ordinary call that reads a socket |
| Compute | Rayon | `t = f()&`, `g()`, `>t`; `par.map`, `par.each` |
| Tasks | Go | `f()&`, `Tasks[T]`, `<t.cancel()`, `time.within` |
| Actors | Erlang | `*Actor(x)`, and its methods called through the handle |
| Structured concurrency | Swift | nothing more: a task belongs to its scope |
| Channels and select | Go's CSP | `*Chan[T](n)`, `task.select(...)` |

### 1. Threads and preemption

**The program writes** nothing; it never names a thread.

**Underneath,** a program that makes tasks starts one worker thread per
core (or `task.workers(n)`, or `RIG_WORKERS`); one that makes none
starts no workers. A later `task.workers(n)` raises or lowers the
number: the workers past `n` park until it rises again. `main`'s thread is worker 0, and `main` runs as the
first task. Each worker keeps its ready tasks in a ring and a few "run
next" slots, and an idle worker steals from a busy one.

A task pauses only where it waits, so a long computation would hold its
core. On x86-64 Linux and arm64 macOS, a program that makes tasks is
preempted by signal and its loops have no checks: a monitor thread
sends SIGURG to a worker whose task has run a slice (10 ms by default)
while other work waits, and the handler stops the task only in the
program's own code and only while its worker holds no lock. Elsewhere
the compiler adds a yield check to every loop nest, which calls the
scheduler every 1,024 turns, and to every cycle of recursive calls,
where one function reads a flag on entry. A check never fails, and
yields only when other work waits. Either way a task queued behind a
long computation waits for a slice of it, not all of it. Seeded test
runs, Linux debug builds, and a program that makes local tasks keep the
yield checks ([ROADMAP](ROADMAP.md), "Concurrency").

### 2. Async I/O, as in Tokio

**The program writes** ordinary calls:

```rig
use std.net

fun echo(l: net.Listener) -> Int!
  c = l.accept()!
  buf = String()
  n = !c.read(!buf, 4096)!
  !c.write(?buf)!
  n

sub main()!
  l = net.listen("127.0.0.1:0")!
  port = l.port()
  t = echo(<l)&
  c = net.connect(String("127.0.0.1:", port))!
  !c.write("ping")!
  got = String()
  while got.len < 4
    _ = !c.read(!got, 100)!
  print(got, >t!)
```

```output
ping 4
```

`echo` waits on `accept` and `read` with no mark and no future to poll.
`net.listen` and `write` take a `?String`, and a literal is fixed text,
lent with no allocation. `net.connect(String("127.0.0.1:", port))`
builds its address from parts, since Rig has no `+` on text: an owned
`String`, allocated where the reader sees it and lent for the call.

**Underneath,** each worker sleeps in a poller of its own, kqueue on
macOS and epoll on Linux, which also serves its tasks' timers. A socket
is registered with the poller of the worker that makes or accepts it. A
task whose read would block parks: it records what it waits for and
switches away, and its worker runs other tasks until the poller reports
the socket ready, so a wait on a socket never holds a worker. A call
that would block its thread, such as a file system call that may wait,
runs on a blocking pool while its task parks.

### 3. Compute, as in Rayon

**The program writes** fork-join with the same `&`, or a word of
`std.par`:

```rig
use std.par

fun count(lo: Int, hi: Int) -> Int
  n = 0
  for i in lo..hi
    n += i % 7
  n

sub main()
  t = count(0, 500_000)&
  b = count(500_000, 1_000_000)
  a = >t
  print(a + b)
  xs = List([1, 2, 3, 4])
  print(par.map(?xs, |x| x * x))
```

```output
2999997
[1, 4, 9, 16]
```

**Underneath,** `count(...)&` puts the task in its worker's run-next
slot, and `main` goes on with the second half. An idle worker takes
the task, so the halves run on two cores: on x86-64 Linux and arm64
macOS, which have no yield checks, once the preemption monitor sees the
task waiting, within about a millisecond; elsewhere, at `main`'s first
yield check. A worker that switches to a task wakes an idle one at once
while more wait behind it, so several tasks made and then waited for
spread with no such delay. If no worker took the task, `>t` runs it at
once by handoff (below).
`par.map(?xs, f)` and `par.each(!xs, f)` run a function over a list on
one task per worker, or `limit:` of them, and
`par.workers(!states, ?items, f)` gives each task a state of its own.
Results come in the order of the input, and every task calls the one
closure, so it may capture nothing lent to write.

### 4. Tasks, as in Go

**The program writes** `f(x)&` for each piece of work, and a set to
hold many:

```rig
use std.time

error Mirror
  down

fun fetch(mirror: Int, ms: Int) -> Int!
  time.sleep(ms: ms)!
  return Mirror.down if mirror == 1
  mirror * 100

sub main()
  ts = Tasks[Int!]()
  !ts.add(fetch(1, 1)&)
  !ts.add(fetch(2, 5)&)
  !ts.add(fetch(3, 60_000)&)
  print(<ts.wait_first() catch -1)
```

```output
200
```

`<ts.wait_first()` gives the first success and cancels the rest, so
mirror 3's minute of sleep ends at once; `>ts` waits for them all.

**Underneath,** a task is a fiber: a record and a stack of its own,
switched by saving and restoring the few registers a call keeps. It is
one allocation, and starts faster than a goroutine ("Where it stands").

**It guarantees** cancellation with no token: `<t.cancel()` cancels a
task, waits for it, and gives what it returned. The cancel arrives as
`Stop.canceled` at the task's next fallible waiting point (a sleep, I/O,
a channel, a wait on a fallible task, `task.check()!`), so only a `Task[T!]` can be
canceled, and it stays canceled. Past a `time.within(d, f)` deadline,
every waiting point fails with `Stop.timeout`.

### 5. Actors, as in Erlang

**The program writes** `*Actor(x)` around any object, and calls its
methods through the handle:

```rig
obj Ledger
  entries: List[Int]

  sub post(!@, n: Int)
    !@entries.push(n)

  fun total(?@) -> Int
    @entries.sum()

sub work(ledger: *Actor[Ledger], n: Int)
  for 0..100
    !ledger.post(n)

sub main()
  ledger = *Actor(Ledger(entries: List[Int]()))
  ts = Tasks[Void]()
  for n in 1..5
    !ts.add(work(+ledger, n)&)
  >ts
  print(ledger.total())
```

```output
1000
```

Nothing in `Ledger` changes. A method that changes self, `!@`, is
called marked, `!ledger.post(n)`; one that reads self, `?@`, is called
bare. `+ledger` makes another handle for each task.

**Underneath,** the actor is a task with a mailbox, and a call is a
message whose caller waits for the answer. When the actor is idle, the
caller takes it with one atomic step and runs the method on its own
stack, as the actor, with no message and no switch. So an idle actor
costs about what a lock does, and Rig has no `Mutex`.

Every call takes the actor, a read as much as a write, so a table many
tasks read is no actor's: `shared.Map`
([STD](STD.md#stdshared)) keeps the first value put under each key, so
a lookup takes nothing and writes nothing, and only a put of a new key
locks, one shard of 64.

An object that holds a Cell, and whose every field is plain data, a
Cell of one word, or another such object, is shared the same way, with no actor: its handles go to other tasks,
and each Cell operation lands at once in one order every task sees
(SPEC, "Cell"). Each operation is one change, so a `get` then a `set`
are two, and a change another task makes between them is lost: count
with `!c.add(n)`, and replace a value with `(!c).compare_swap(old,
new)` or `!c.swap(v)`.

**It guarantees** that an actor runs one method at a time, each to its
end, so no one sees its state half-changed. A call that would close a
cycle of waiting calls panics, naming it (`Bank.pay -> Ledger.post ->
Bank.balance`). A panic in a method ends the actor and its waiting
caller, as an Erlang link does; `*Actor.supervised(make)` restarts it.

### 6. Structured concurrency, as in Swift

**The program writes** nothing more. Every task is structured:

```rig
use std.time

error Job
  broken

fun nap(ms: Int) -> Int!
  defer print("nap of", ms, "ends")
  time.sleep(ms: ms)!
  ms

fun broken() -> Int!
  time.sleep(ms: 5)!
  return Job.broken

fun both() -> Int!
  slow = nap(60_000)&
  bad = broken()&
  b = >bad!
  b + >slow!

sub main()
  r = both() catch |e|
    print(e)
    -1
  print(r)
  print(time.within(ms: 20, || nap(60_000)!) catch -1)
```

```output
nap of 60000 ends
Job.broken
-1
nap of 60000 ends
-1
```

**Underneath,** a `Task` is an owned value whose drop cancels it, if it
can fail, and waits for it. In `both`, `>bad!` fails and returns, so
`slow` drops on the error path: it is canceled, its `defer` runs, and
`both` returns once it ends. A deadline passes down with no context
object, to every task its closure starts. `task.isolate(f)` stops a
panic in `f` as the error `Stop.panicked`, once the tasks started inside
are canceled and waited for; `http.serve` runs each request so.

**It guarantees** that no task outlives the scope that made it. There
are no detached tasks, and `main` returns only after every task it
still holds is canceled and waited for.

### 7. Channels and select, as in Go's CSP

**The program writes** a bounded channel, shared through handles, and a
select over named arms:

```rig
use std.task
use std.time

sub numbers(out: *Chan[Int], n: Int)!
  for i in 1..n + 1
    !out.send(i)!
  !out.close()

sub main()!
  ch = *Chan[Int](2)
  p = numbers(+ch, 3)&
  open = true
  while open
    match task.select(got: !ch.on_recv(), late: time.after(1))!
      .got(v?) => print(v)
      .got(none) => open = false
      .late => open = false
  >p!
```

```output
1
2
3
```

**Underneath,** a send waits for room and a receive for a value, each by
parking its task. A select makes every arm, waits until one can
complete, and commits that one alone, so no arm takes a value and then
loses; ready arms are taken in a turning order, so none starves. An arm
may also wait for a task's end, `done: ?t.on_end()`. A send and a
receive are marked changes (`!`) and fallible waiting points, where a
canceled task stops.

## What happens on `f()&` and on `>t`

**The task record.** `f(x)&` evaluates the arguments where it is
written, then makes one allocation: the task's record, holding its
fiber, its completion (`sched.Done`), its cancel state, its arguments,
and a slot for its result. Its state and reference count share one
atomic word, so a wake is one compare-and-swap and a task is queued at
most once. The first task a program makes starts the workers.

**The stack.** A task gets a stack only when it first runs, from the
worker that runs it. A stack is 64 MiB of address space, committed only
as the task touches it, so a sleeping task holds about a page of it.
Each worker keeps 32 free ones and shares up to 32 more on a spare list,
returned to the system in runs once the workers are idle, and no stack
moves, since loans point into it. Below each is a guard wider than the program's largest
frame, by the compiler's bound on each frame, so an overflow faults.

**The run-next slots and the ring.** The new task goes into one of its
worker's four run-next slots, the one after the newest, by one swap; the
oldest task there moves to the worker's ring of 256. The slots hold work
just made or just woken, still in cache, and filling one wakes no
worker, so a task made and waited for at once costs no system call. The
worker runs the newest slot, at most 3 in a row, then its ring.

**Stealing.** A worker with nothing to run steals half of a random
worker's ring with one compare-and-swap; at most half the workers search
at once, and one that finds work wakes another. A task left in another
worker's slots for 3 µs may be taken too. Work made while every worker
is busy sets a flag that the next yield check acts on.

**Handoff.** If the task has not started and still sits in this
worker's slot when `>t` comes, the waiter hands its worker straight to
it, switching onto the task's stack past every queue, and the task
switches straight back when it ends (`sched.handoff`). A chain of tasks,
each made and waited for at once, runs on its maker's worker at 47 ns a
task on the Mac (`chain`, below).

**Parking on I/O and on timers.** A task that must wait begins a
numbered wait, tells its waker the number, looks once more, and switches
away; only then is it marked asleep. On a socket it sleeps until the
descriptor's count of ready edges, read before its call, changes, so no
waiter consumes another's readiness. A timer's deadline goes into its
worker's heap, which bounds the worker's sleep in its poller.

**The waiter woken.** A task that ends marks its record ending, wakes
its one recorded waiter, and only then marks it ended, so the waiter may
free the record at once. The wake is one compare-and-swap for that
wait's number, so a stale wake does nothing, and puts the waiter in the
waking worker's run-next slot, so two tasks that answer each other stay
on one worker. `>t` takes the result and ends the task's loans; a
task's panic passes on to its waiter there.

**What crosses cores.** Any worker may run a task, so the checker
derives two facts for every type: whether its value *sends* (may be
handed whole to another thread) and whether it *syncs* (two threads may
read it through views at once). A task's argument is moved or copied
when its type sends, lent to read when it syncs, and lent to write when
it sends. Plain data sends and syncs; a `*Cell` of one word, `*Chan`,
`*Actor`, and `*Frozen` are counted atomically and go to any task. A
plain `*T`'s count is not atomic, so a task given one is *local*: pinned
with its maker to one thread, where local tasks take turns.
`rig check --tasks` lists each local task and what pins it.

## Safety

**Ownership.** A task is a call whose loans last until it ends.
`score(?d)&` lends `d` to the task for its whole life, so the task reads
`d` in place, with no copy and no counted handle, and nothing changes
`d` meanwhile. This is sound because a task's drop always runs before
the owner of its loans goes: the drop counts as a use of the loans,
drops and `defer`s are checked in the order they run, no shared home (a
`Cell`, a channel, an actor, an owned closure) holds a task, a panic
stops at a boundary that waits for the tasks under it, and `main` waits
for its tasks: the five rules of the design doc's "Loans and
structure", on [CORE](CORE.md#2-the-core-in-ten-sentences)'s sentence 6.

**What the compiler rejects:** a write to a value a live task was lent
("cannot lend `xs` to write while a read loan is live"); a task thrown
away as it starts ("this task is dropped as soon as it starts"); a
fallible task the normal path drops unwaited, whose error would vanish;
a cancel or a deadline over a task that cannot fail; a task with a write
loan moved, returned, or put in a set; an API object without `Sends`,
`^{Job}`, given to a task; and a closure given to `par.map`, `par.each`,
`par.workers`, or `http.serve` that captures something lent to write.

**Deterministic tests.** With `RIG_SEED` set, as `rig test` sets it, a
program runs on one thread: the seed picks the next task and
whether each yield check yields, on a virtual clock. A failing
interleaving replays; the suite runs every concurrency case under seeds
1 to 20.

**Deadlock detection.** Every waiter publishes the one thing it waits
on and walks the chain from there, so the call that would close a cycle
of actor calls finds it, even when two cores close it at once, and
panics naming it. It is exact for waits on one thing (a task, an actor
call, a set's next result); a seeded run with no task ready and no
timer set panics too, which covers waits on channels.

## Where it stands

**Built:** the design doc's whole model, every style above, and
`std.net` and `std.http` on a poller per worker. On x86-64 Linux and
arm64 macOS a long computation is stopped by signal, and a stop
switches to the worker's own stack before the scheduler decides
anything, so a task keeps about 3 KiB free below its stack pointer
for a stop (`preempt_room` in src/sched.zig). Other targets keep the
yield checks.

**Measured** on an Apple M5 with 10 cores, interleaved, best of 5
(2026-11-08, main 0d1c64647; `bench/tasks/PROGRESS.md`):

| `bench/tasks` | Rig | Tokio | Go |
|---|---|---|---|
| spawn, per task | 151 ns | 176 ns | 227 ns |
| chain (start one, wait), per task | 42 ns | 182 ns | 226 ns |
| yield, per yield | 4 ns | 41 ns | 248 ns |
| fanout, 10 CPU-bound tasks | 81.1 ms | 66.5 ms | 67.0 ms |
| hog, a task waiting behind a long computation | 162 ns | 4.0 ms | 4.2 ms |
| produce, tasks made while others take them | 6.7 ms | 5.6 ms | 6.1 ms |
| resident memory, per sleeping task | 16.6 KiB | 262 B | 2.9 KiB |

Starting a task costs less than Tokio's and Go's; a chain is 4.3 times
as fast as Tokio's, and a yield 9 times. `fanout` is 22% slower than
Tokio's, a gap in the compiled loop ([launch/benchmarks.md](launch/benchmarks.md)).
A task behind a long computation waits for a slice of it, not all of it:
162 ns, against Tokio's 4.0 ms and Go's 4.2 ms.

The memory row counts resident pages only. The kernel also keeps a page
table for each task's stack, which a Tokio or Go task does not need, so
counted as the kernel counts it (`footprint` on macOS, VmRSS plus VmPTE
on Linux; [bench/tasks/SCALING.md](../bench/tasks/SCALING.md)) a
sleeping task holds 32.7 KiB on the Mac, 16.1 KiB of it page tables,
against Tokio's 267 B and Go's 2.9 KiB; and 8.9 KiB on pup (x86-64
Linux), 4.3 KiB of it page tables, against Tokio's 388 B and Go's
2.9 KiB.

Divide and conquer with `f()&` and `>t`, fastest of 20 on ten workers
on the Mac: a parallel sum takes 2.74 ms, against Rayon's 2.43 ms, and
a quicksort 85.8 ms, against Rayon's 48.7 ms.

`bench/actors/PROGRESS.md` has a counter called from one task at 5.2
ns a call, against 3.7 ns behind Go's `sync.Mutex` and 134 ns for a
Tokio actor; `bench/http/PROGRESS.md` has `http.serve` at 163,212
requests a second (p99 786 µs), 9.5% fewer than hyper's 180,339 (p99
614 µs) and about Go's 163,675 (p99 1,071 µs), and 16.8 KiB per idle
connection against hyper's 18.6 KiB and Go's 18.5 KiB, in resident
memory. Counted with its page tables, as the kernel counts a process,
Rig's idle connection holds 17.2 KiB on the Mac, since it waits on a
dense stack. Its load
generator is closed-loop, which understates p99, so no claim against
Tokio or Go rests on these before the mixed-workload benchmark.

**The gaps,** from the [ROADMAP](ROADMAP.md)'s "Concurrency":

- **Task memory:** a sleeping task's 32.7 KiB brought to Go's 2.9 KiB
  or under, first by stacks placed closer together (one page table for
  many), then by small stacks packed into shared pages, sized by a
  proven bound
  ([records/2026-11/task-memory/](history/records/2026-11/task-memory/small-stacks.md)).
- **Free fork-join,** for the quicksort's gap: an awaited unstarted
  task run on the waiter's own stack, its record in the maker's frame,
  as `rayon::join` does, where its frames are proven to fit, and `par`
  splitting its work by what is left; the program still writes `f()&`
  and `>t`.
- **Files and I/O:** one `read`/`write` shape for files, sockets, and
  HTTP bodies; then DNS, TLS, and an HTTP client, which `std` lacks;
  and connections shaped as actors, so an idle one holds no stack.
- **A mixed-workload benchmark,** open-loop, with requests that compute
  and thousands of idle connections, before any claim against Tokio or Go.
- **Preemption by signal on Linux arm64 and on Windows**, where the
  yield checks run today.

## Where to read more

- [design/concurrency.md](design/concurrency.md): the full model and its reasons.
- [internals/scheduler.md](internals/scheduler.md): the engine, function by function.
- [SPEC §18](../SPEC.md#18-tasks): every rule of tasks, actors, channels, and `par`.
- [learn/04-concurrency.md](learn/04-concurrency.md): the journey that teaches it.
- [launch/benchmarks.md](launch/benchmarks.md) and each `PROGRESS.md` under [bench/](../bench/): the numbers.
