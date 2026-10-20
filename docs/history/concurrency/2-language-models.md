# Panel 2: language concurrency models, reviewing CONCURRENCY.md

> **History.** This is a review of an early draft of the concurrency design. The design as built is [docs/design/concurrency.md](../../design/concurrency.md), the rules are in [SPEC.md §18](../../../SPEC.md#18-tasks), and the review of the model as built is [docs/design/concurrency-panel](../../design/concurrency-panel/README.md). It is kept as written.

Panel: (a) Go runtime and language, (b) Erlang/BEAM, (c) Java Loom and
structured concurrency, (d) .NET TPL, async/await and Orleans, (e)
TypeScript/JavaScript. Sources read: the draft
(`docs/design/concurrency.md`, as drafted when reviewed), `docs/DESIGN.md`,
`SYNTAX.md` (sigils, receivers, closures, defer), and Tokio's `task/` and
`sync/` docs for contrast.

**The panel's verdict in brief.** The draft's core, an owned task whose drop
cancels and waits, carrying its argument loans, is the strongest idea on the
table: it is StructuredTaskScope with nothing to write, scoped threads that
Rust's async world cannot have, and Go's ease without its leaks. Four things
need work before it is world-class: (1) cancellation is underspecified and
interacts badly with infallible waits and `defer`; (2) a task discarded at once
is a silent no-op, and an unwaited fallible task loses its error; (3) "every
task is waiting" deadlock detection is useless for servers; (4) the actor
surface carries one keyword too many, and the flagship example breaks Rig's own
rule on a `!` call whose value is used. Fail-fast, race, and timeout belong in
the first `std`, not "if programs show a need".

---

## 1. The five models

### (a) Go: goroutines, channels, select, context, errgroup

*Concepts:* `go f()`, channels (buffered and not, close, range), `select`,
`sync.Mutex`/`WaitGroup`, `context.Context`, and in practice `errgroup`.

*Pleasant:* no coloring; a blocking call is a call. The GMP scheduler with
work stealing, and handing off the P on a blocking syscall (sysmon), make
"just block" cheap. Growable 2 KB stacks make a million goroutines normal.
`select` with a timer arm is the cleanest timeout story in any language.

*Footguns:* **Goroutine leaks** are the number one production bug: a goroutine
blocked forever on a channel nobody reads, invisible until memory grows. `go f()`
returns nothing, so **errors vanish** unless you build errgroup. **Cancellation
is manual**: `ctx` must be threaded through every signature and checked; forget
once and the work runs on. **Deadlock detection** is "all goroutines are
asleep", which never fires in a server because the listener is always alive.
Channels have sharp edges: send on closed panics, double close panics, a nil
channel blocks forever, and unbuffered-versus-buffered choices change
semantics. **Shared mutable state** is unchecked: the race detector is a
runtime test, not a guarantee. **Blocking the scheduler**: until Go 1.14 a tight
loop without function calls could starve GC and the scheduler; async
preemption by signal was added because cooperative preemption at function
prologues was not enough in practice. That lesson applies directly to Rig.

*On the draft:* `f()&` is `go f()` with a handle, which fixes leaks and lost
errors at the root. Channels and `select` are what Go programmers will reach
for in pipelines; they can be `std`, but `select` must be atomic (choosing an
arm consumes exactly one message) or it reintroduces Tokio's cancel-safety bug.

### (b) Erlang/BEAM: processes, mailboxes, links, supervisors

*Concepts:* process, `spawn`, pid, `!` send, `receive` (selective, with
`after`), links and monitors, exit signals, `gen_server` call/cast,
supervisors with restart strategies.

*Pleasant:* per-process heaps and immutable data make **isolation real**, so
"let it crash" is sound: a crashed process cannot leave shared state broken,
and its supervisor restarts it into a known-good state. Reductions-based
preemption makes fairness automatic: no process can hog a scheduler. Links
make failure propagation a graph you declare.

*Footguns:* **unbounded mailboxes** are the classic BEAM killer: a slow
gen_server's queue grows until the node dies. **Selective receive** scans the
mailbox, so a large mailbox makes every receive O(n). **`gen_server:call`
cycles deadlock**, rescued only by the 5-second default timeout, which then
crashes the caller. Messages are copied (except large binaries), so big state
crossing processes is costly. Untyped messages mean protocol mistakes are found
at run time. Restart storms hide bugs.

*On the draft:* Rig's ownership gives the isolation that BEAM gets from
copying: an actor's state is moved in and owned exclusively, so nothing else
can see it half-updated. That is the precondition for supervision. What Rig
lacks is unwinding, so a *panicking* actor cannot be cut out safely (see
section 3). The draft wisely has no selective receive: method dispatch is a
typed `gen_server`, which is what most Erlang code wants anyway.

### (c) Java: Loom, StructuredTaskScope, ScopedValue

*Concepts:* virtual thread (just a `Thread`), `StructuredTaskScope` with
`fork`/`join` and a joiner policy, `ScopedValue`, interruption.

*Pleasant:* Loom removed coloring from Java without changing APIs: blocking
I/O in a virtual thread unmounts it from its carrier. StructuredTaskScope makes
the call tree the task tree: a scope cannot close while children run, and
"shut down on failure" is errgroup built in. ScopedValue gives children
read-only context without thread-locals.

*Footguns:* **pinning**: a virtual thread inside `synchronized` or a native
frame holds its carrier, so a blocking call there starves the pool (fixed for
`synchronized` only in JDK 24). **No time-slice preemption**: a CPU-bound
virtual thread holds its carrier. **Interruption is unreliable**: libraries
swallow `InterruptedException`. StructuredTaskScope spent five preview rounds
settling joiner policies, deadlines, and what happens when a fork escapes its
owner; the lesson is that "wait all, fail fast" and "first success" are the two
policies people need, and deadlines belong to the scope. Thread-local-heavy
libraries multiply memory by a million threads.

*On the draft:* the draft *is* StructuredTaskScope, made implicit by
ownership: the scope is the `try`-with-resources, the drop is `close()`, and
the loans are ScopedValues with compile-time checking. Rig's analogue of
pinning is a `raw` block calling blocking C; it needs a documented escape. Rig
must not repeat Loom's cooperative-only bet without the compiler inserting
checkpoints, because Rig's drop *waits*, so a task that never reaches a
waiting point makes a scope's exit hang, not merely unfair.

### (d) .NET: TPL, async/await, CancellationToken, Channels, Orleans

*Concepts:* `Task<T>`/`ValueTask<T>`, `async`/`await`, `CancellationToken`,
`Task.WhenAll`/`WhenAny`, `System.Threading.Channels`, and for actors, Orleans
grains.

*Pleasant:* `await` reads like sequential code; `WhenAll`/`WhenAny` compose;
Channels are excellent (bounded, with a full-mode policy); Orleans virtual
actors remove lifecycle management entirely.

*Footguns:* **coloring** spreads `async` through every caller. **Sync over
async deadlocks** (`.Result` under a SynchronizationContext) were the worst
.NET bug class for a decade, and `ConfigureAwait(false)` everywhere is the
scar. `async void` crashes the process on an exception. **Unobserved task
exceptions** vanish. **AggregateException** wraps errors so nobody handles
them. **CancellationToken plumbing** is pervasive boilerplate and often
forgotten. `ValueTask` awaited twice is undefined. Orleans grains are
non-reentrant by default, so A calls B calls A deadlocks; Orleans added
call-chain reentrancy to escape it, which is only sound because grains have no
exclusive borrows.

*On the draft:* no SynchronizationContext is a gift, but decision 6 ("no
single-thread task") will hurt any GUI built on gpui-style main-thread state:
Rig's own idioms (`*T`, `Cell`, `Signal`) do not cross cores, so such a
program cannot use `&` at all. And Rig's `!@` exclusivity *forbids* Orleans'
reentrancy escape: an actor waiting inside a `!@` method holds the write view,
so a nested call into it cannot run. Non-reentrancy is forced; deadlock
handling must therefore be detection.

### (e) TypeScript/JavaScript: event loop, promises, AbortController

*Concepts:* one thread, run to completion between `await`s, promises,
`async`/`await`, `Promise.all/race/any/allSettled`, `AbortController`.

*Pleasant:* no data races, ever, because only one thing runs at a time, and
every interleaving point is a visible `await`. That is the real reason JS
concurrency *feels* easy: you can reason about state between awaits.

*Footguns:* **floating promises** (forgotten `await`) and **unhandled
rejections**; accidental serialization (`await a(); await b();`);
`Promise.all` does not cancel the losers; `AbortController` is opt-in plumbing
that most libraries ignore; a CPU loop blocks everything; microtask
starvation; and "async all the way down".

*On the draft:* Rig's defaults are right where JS's are wrong: serial is the
default and parallel is the marked case (`&`), and data races are excluded by
the checker rather than by having one thread. The JS lesson Rig must keep is
the **floating-promise lint**, made a rule: a task expression whose value is
discarded is an error. And the run-to-completion mental model should be stated
for actors: one method runs to its end before the next, so state between two
lines of one method is never seen by anyone else, while state *between two
calls* from a client can change (check-then-act across two messages is a race;
put it in one method).

### Tokio, for contrast

`JoinHandle` drop *detaches* (orphans); `JoinSet` drop aborts without waiting;
`spawn` needs `'static + Send`, so tasks cannot borrow (the scoped-async
problem, caused by leakable futures); a 128-op coop budget patches starvation;
`select!` cancellation drops in-flight futures, losing data unless each branch
is "cancel safe"; std versus Tokio `Mutex` confuses everyone; and errors from a
spawned task are lost unless the handle is awaited. The draft fixes the first
four by construction. The last two it must fix by rules (sections 4 and 5).

---

## 2. The minimal concept set

**Tasks: yes, core.** Everything else is built on them.

**Actors: core, but smaller.** An actor is a task that owns a value and serves
method calls on it one at a time. Could a library do it? Only as
`counter.call(|!c| c.visit())`, a closure mailbox, which loses the method-call
surface, the per-method checks (arguments move or share; results do not view
the actor), and the `!` mark. Rig's principle says the language then gains a
*general* feature, not `actor`: the general feature is a built-in handle,
`Actor[T]`, alongside `Cell`, `Signal`, `List`, whose method calls become
messages. Nothing about the *type* changes: any `obj` whose fields move can
become an actor, checked where it is made, in the same spirit as per-instance
generics. So the panel recommends **dropping the `actor` declaration**:
`Actor(Counter())` moves a `Counter` into a task of its own and gives the
handle. That means no new keywords at all (`spawn` also goes; it would collide
with every Tokio and Go reader's meaning of "start a task", which in Rig is
`&`). Dissent (b): an `actor` declaration documents intent; the majority
answers that a type comment does too, and an object that is sometimes an actor
and sometimes a plain local value is a feature.

**Channels and select: `std`, not core.** All five agree no syntax is needed.
`Chan[T]` (bounded only; Go has no unbounded channel and nobody misses it) is a
built-in-backed `std` type that shares across cores, changed with `!` like a
`Cell`. `select` is a `std` function over channel operations that commits
exactly one arm atomically; racing *tasks* covers every other "first of"
case, because a losing task is simply dropped, which cancels and waits for it.
Dissent (a): pipelines are so common that channels deserve first-class
iteration; the answer is that `while (!rx).recv()! as x` already reads well,
and a `for` over an iterator protocol comes free when Rig has one.

**Shared counters: `std.Atomic[T]`.** The draft's flagship is an actor counter,
which costs a message round trip (hundreds of nanoseconds) for what an atomic
does in five. "No loss of performance" requires `Atomic[Int]` in the first
`std`. Generalize the draft's own rule: on a type whose change is safe under
sharing (`Cell` on one thread, `Atomic` and `Actor` across cores), `!` marks
the change and lends nothing, so a read view `?hits` captured by many tasks
can still do `!hits.add(1)`. A `Mutex` is deferred: actors plus atomics cover
the space, and a lock would be the first construct that can deadlock without
any message.

**Converged core: four concepts.**

1. **Task.** `f(x)&` runs a call at the same time and gives an owned
   `Task[T]`; `<t.wait()` takes its result.
2. **Structure.** A task never outlives its owner: dropping an unwaited task
   cancels it and waits, so scopes and lists are the groups, and a task may
   lend the caller's data in place.
3. **Actor.** `Actor(x)` moves a value into a task of its own and gives a
   shared handle; calls through it are messages, run one at a time, to their
   end.
4. **Crossing.** The checker's *moves* and *shares* facts decide what may go to
   another core; a user meets them only as error messages.

Cancellation, timeouts, channels, atomics, and supervision are rules or `std`
on top of these four.

---

## 3. Failure and isolation

**Errors as values** stay the mechanism: `Task[T!]` gives back exactly the
call's error set plus `Canceled` (and `Timeout` from a timed wait), with no
wrapping (no AggregateException, no ExecutionException). This is a real
advantage over Java and .NET; state it.

**Panic fatal: right, for a reason the draft should write down.** BEAM can let
a process crash because its heap is private and nothing points into it. A Rig
task's fiber stack *is* pointed into: its child tasks hold loans of its locals,
and it holds loans of its parent's. Cutting one task out on a panic without
running its drops would free memory children still read; running its drops
means unwinding, which Zig does not have and Rig has rejected. So a panic must
end the program. Erlang's expert accepts this, with two conditions:

- **Servers isolate at the process level.** The `std` server should support a
  pre-fork mode (N processes on `SO_REUSEPORT`, restarted by a small parent),
  which is let-it-crash one level up, and works with systemd or Kubernetes.
- **Panics must be rare and named.** Every panicking operation (index, unwrap,
  overflow, division) should have an optional-returning form, so a server can
  avoid panics on input it does not trust.

**A failed actor.** A `!@` method that returns an error goes back to its
caller; the actor lives on with whatever state the method left, and its
`errdefer`s are responsible for restoring invariants, exactly as for a `!@`
method on a local object. No "poisoned" flag: Rust's mutex poisoning is widely
regarded as a mistake, and Rig's errors are values with `errdefer`, so a
method that fails partway is a bug in that method, not a state of the actor.

**Supervision** belongs in `std` and restarts *functions that fail*, not
actors that panic: `supervise(restart, max, within, f)` calls `f` as a task,
restarts it on an error, and gives up (returning the last error) past the
intensity limit. A supervised actor is a supervised function that builds the
actor and serves it; the handle the supervisor gives out forwards to the
current incarnation. Links and monitors are unnecessary for tasks: ownership
already is the link, in both directions (a parent's drop cancels the child; a
child's error reaches the parent's `wait`).

---

## 4. Cancellation

The panel compared four mechanisms:

| Mechanism | Strength | Weakness |
|---|---|---|
| Go `context`, .NET `CancellationToken` | explicit, composable deadlines | plumbing in every signature; forgotten checks |
| Java StructuredTaskScope + interrupt | tree-shaped; scope deadline | interrupt swallowed; checked only at blocking calls |
| Erlang exit signals + links | immediate, no cooperation needed | needs isolated heaps; brutal (`kill`) or trapped |
| Drop cancels and waits (Trio, Kotlin, the draft) | no plumbing; follows ownership; no orphans | needs precise delivery rules and checkpoints |

All five choose **drop cancels and waits**: it is the only one that needs no
code to be correct, and it maps exactly onto Zig's `defer future.cancel(io)`
idiom. But the draft leaves four rules unstated, and each is a real bug:

1. **Where it is delivered.** The draft says at "an I/O call, a wait, a
   message", which makes every actor call and every `wait` fallible, so
   `http.json("visits", !counter.visit())` would not type-check. The rule
   should be: **cancellation is delivered only as `error.Canceled` at a
   fallible waiting operation** (I/O, `Chan` operations, a timed wait, `sleep`,
   a wait on a `Task[T!]`). An infallible wait (a `Task[T]`, an infallible
   actor method) passes the cancel down to what it waits on and then completes
   normally. Cancellation is a request; the type of each call says whether it
   can observe it.
2. **Cleanup is shielded.** A `defer` or `errdefer` body that runs because of a
   cancel must not be canceled again at its first I/O, or no connection ever
   closes gracefully (Trio's shield, Kotlin's `NonCancellable`). Defer bodies
   run shielded, always.
3. **Checkpoints exist.** Because drop *waits*, a CPU loop that never waits
   makes the dropping scope hang. The compiler should insert a budget check at
   loop back-edges and non-leaf calls in code reachable from a task (BEAM's
   reductions; Go's pre-1.14 prologue checks plus a back-edge counter); when
   the budget runs out, the task yields, and a canceled task with a fallible
   result fails there. Go measured this class of check at about 1 to 2
   percent; Rig's frame facts let it skip leaf functions and bounded loops.
   This also answers "should the runtime preempt": yes, at compiler-placed
   points, with no signals.
4. **Propagation follows ownership.** Canceling a task cancels the tasks it
   owns, through the same drops; no token exists.

Deadlines are the one thing tokens did well; Rig gives them as a timed wait,
`<t.wait(within: d)`, and on lists, `<ts.wait_all(within: d)`, which on
timeout drop (cancel and wait) the stragglers.

---

## 5. The surface, decision by decision

**`&` postfix.** Keep. It is the shell's "run in the background", it is free
in Rig (no address-of), it is two keystrokes at exactly the place the effect
happens, and it inherits the spacing rule. Add two rules: **a task whose value
is discarded is rejected** (`log(e)&` as a statement would be canceled at once:
"a task dropped where it starts is canceled where it starts; bind it, or call
without `&`"); and **a task that is never waited for on its normal path is
rejected** unless released explicitly with `<t` (implicit drop stays on early
exits: `!` propagation, `return`, `break`, which is exactly where cancel is
wanted). This is the floating-promise lint and Go's lost-error fix as one
rule, and it keeps Rig's promise that effects are visible: the hidden wait and
cancel in a drop happen only where control already leaves.

**`<t.wait()`.** Keep. It is two characters of honesty that Rig already asks
for every consuming method, and it reads well in `<a.wait()!`. The noise is in
lists, so give lists the methods: `<ts.wait_all()`, `<ts.wait_first()`. The
panel considered `t.join()`, a postfix wait sigil, and `wait t`, and rejected
each: a new sigil for something written once per task is not worth it.

**`Actor[T]` handles.** Keep the type; drop the `actor` and `spawn` keywords
(section 2): `Actor(Counter())`. The handle is an atomically counted handle,
cloned with `+`, and lendable with `?counter` to tasks that end before it, so
`http.serve` handlers need no count at all. State that an actor whose handles
form a cycle leaks (as any `*T` cycle does) and that `~Actor[T]` is the weak
form.

**`!counter.visit()`.** Keep the mark: an actor's state is shared through its
handles exactly as a `Cell`'s is, so a change is marked the same way. But the
draft's own example is invalid Rig: a `!` call whose value is used must be
written `(!counter).visit()` (SYNTAX section 5), so the flagship line is
`http.json("visits", (!counter).visit())`. Fix it, and lead with an example
whose value is discarded or that uses an `Atomic`.

**`+counter` capture.** Keep, and prefer `?counter` where the handler cannot
outlive the owner (which `http.serve` guarantees, since it waits for its
tasks). That is a second showcase of loans in tasks.

**No group keyword.** Agree, and go further: no `std.Group` either for the
common cases. `List[Task[T]]` with `wait_all` (first failure cancels and waits
for the rest), `wait_first` (first success; the rest canceled), and the
`within:` forms covers errgroup, `Promise.any`, StructuredTaskScope's two
joiners, and timeouts. A bounded-parallel map (`par.map(?xs, f, limit: n)`)
covers the remaining need. These must ship with tasks, not later: without
`wait_all`, the obvious loop `for t in <ts: <t.wait()!` waits for slow task 1
before it sees fast task 2's failure.

**Bounded mailboxes.** Agree, firmly (b). Note that since every message is a
call that waits, in-flight messages are bounded by waiting callers anyway; the
capacity matters only for `&` calls. An actor calling itself through its own
handle deadlocks at once; detect it (below).

**Deadlock reporting.** Replace. "Every task is waiting" never fires in a
server. Instead keep a **wait-for edge** per waiter (a task or actor waits on
one thing at a time, or a list for `wait_all`); when an actor call or a task
wait adds an edge, follow the chain from the target. Since actors are
non-reentrant and tasks form a tree, a cycle can only close through an actor
call, and the call that closes it finds it: **panic with the cycle**
(`Bank.pay -> Ledger.post -> Bank.balance`), because a deadlock is a bug, and
Rig's bugs panic. Panic rather than an error, so actor calls stay infallible.
Channel deadlocks cannot be found exactly; give a debug dump of every task and
what it waits on (Go's SIGQUIT dump), on a signal or a watchdog.

**Also:** decision 6 should reserve an inferred **local task**: a task whose
arguments do not cross cores runs on the caller's thread instead of being
rejected, so GUI and reactive programs can do concurrent I/O. Default for v1:
reject, as drafted, with the local form planned. And document a `blocking`
escape for `raw` calls into blocking C (or a sysmon-style handoff), the Loom
pinning lesson.

**Soundness rule to state.** Loans in tasks are sound only because a task
cannot be leaked. A `Task` carrying a loan already cannot enter a `Cell` or a
`*T` (they take only loan-free values); say so, and never add a `forget`.

---

## 6. Converged recommendation and examples

Core: **Task, Structure, Actor, Crossing** (section 2). Everything below uses
only those plus `std`.

**Parallel map, in place, no copies.**

```text
fun score(d: ?Doc) -> Int
  ...

sub main()
  docs = load_docs()
  tasks = List[Task[Int]]()
  for d in ?docs
    !tasks.push(score(?d)&)      # each task reads its doc in place
  scores = <tasks.wait_all()     # in order; docs is free again after this
  print(sum(?scores))

  # many small items: chunk and limit
  totals = par.map(?docs, score, limit: 64)
```

**Fan-out with a deadline, fail fast.**

```text
fun fetch_all(urls: ?List[String]) -> List[Page]!
  tasks = List[Task[Page!]]()
  for u in urls
    !tasks.push(http.get(?u)&)
  <tasks.wait_all(within: time.seconds(2))!   # first error or timeout cancels the rest
```

**First answer wins (hedged request).**

```text
fun quote(sym: ?String) -> Price!
  a = ask(?primary, ?sym)&
  b = ask(?mirror, ?sym)&
  <[<a, <b].wait_first()!       # the slower one is canceled and waited for
```

**A server with shared state: an atomic and an actor, both lent.**

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
  http.serve(":8080", handler)!   # waits for every request task, so lending is safe
```

**A pipeline over bounded channels.**

```text
fun read_lines(path: ?String, out: ?Chan[String]) -> Int!
  defer !out.close()              # runs shielded, even when canceled
  n = 0
  for line in file.lines(path)!
    !out.send(<line)!             # waits while the channel is full
    n += 1
  n

fun count_words(input: ?Chan[String], out: ?Chan[Int]) -> Int!
  defer !out.close()
  while (!input).recv()! as line
    !out.send(words(?line))!
  0

sub main()
  lines = Chan[String](64)
  counts = Chan[Int](64)
  a = read_lines("big.txt", ?lines)&
  b = count_words(?lines, ?counts)&
  total = 0
  while (!counts).recv()! as n
    total += n
  <a.wait()!
  <b.wait()!
  print(total)
```

**A supervisor.**

```text
fun ingest(feed: ?String) -> Int!
  conn = net.connect(feed)!
  defer <conn.close()
  ...

sub main()
  n = supervise(restart: .on_error, max: 5, within: time.minutes(1),
                |?feed| ingest(feed))!
  print("ingested", n)
```

**Cancellation and cleanup.**

```text
fun handle(conn: Conn) -> Int!
  defer <conn.close()             # shielded: a graceful close still happens
  req = conn.read_request()!      # error.Canceled arrives here
  ...

sub main()
  log_event(e)&                   # rejected: a task dropped where it starts
                                  # is canceled where it starts
```

**A deadlock, found where it closes.**

```text
obj Bank
  ledger: Actor[Ledger]
  fun pay(!@, amt: Int)
    (!@ledger).post(amt)          # Ledger.post calls back into this Bank

# panic: actor call cycle: Bank.pay -> Ledger.post -> Bank.balance
#   at bank.rig:4 and ledger.rig:12
```

---

## Dissents recorded

- (a) Go: wants `select` as syntax eventually; agrees `std` first.
- (b) Erlang: would prefer actor-level panic isolation if Rig ever gains
  unwinding; accepts process-level isolation now; would keep an `actor`
  declaration for intent.
- (c) Java: wants scope-level deadlines (a block form) rather than only timed
  waits; agreed to revisit after `within:` is used.
- (d) .NET: presses for the local-task form sooner, for GUI programs.
- (e) JS: wants the "check-then-act across two actor calls" race in the
  document's first actor section, not a footnote.
