# BEAM/OTP and Rig's concurrency: what Rig should take

Sources: docs/design/concurrency.md, docs/internals/scheduler.md, SPEC.md §18,
std/task.rig, src/tasks.zig (Actor), src/sched.zig (Stack) on origin/main;
the Erlang Efficiency Guide ("Processes"); OTP's erts design as I know it
(erl_process.h, erl_gc.c, erl_message.c). Nothing was built or measured.

## Summary

Rig is already ahead of BEAM in the places a type system decides:
no orphans (Erlang's `spawn` without a link is the classic leak),
back-pressure by default (a waiting call holds its caller; `&` calls take
one of 64 slots), moves instead of copying messages, typed errors with no
`{'EXIT', Reason}` tuples, handles that survive a supervised restart (no
stale pids, no registry race), and deadlock detection that names the
cycle. An idle Rig actor holds no fiber at all (the runner task starts
only when mail arrives), which is Erlang's `hibernate` made the default.

BEAM is ahead in four places: (1) memory of a *waiting computation*
(about 2.6 KiB against Rig's 16.6 KiB on the Mac); (2) crash recovery
that reclaims everything, where Rig's boundary abandons and leaks the
dead state; (3) a supervision vocabulary (monitors, strategies, restart
kinds, shutdown order, sane restart-intensity defaults); (4) live
observability (observer, recon, `process_info`, `sys:get_state`).
Fairness by reductions is roughly matched, with one gap: Rig's slice is
counted in loop turns, not in work.

## 1. Memory at rest

**How BEAM does it.** The Efficiency Guide gives a new process as 327
words (OTP releases quote 326 to 338), of which 233 words are the heap
*and* the stack: one block, heap growing up, stack growing down toward
it. The rest, about 94 words (750 B), is the process control block
(`struct process` in erl_process.h: registers, reductions, mailbox
pointers, links/monitors tree roots, flags, heap pointers).

- When heap meets stack, the process runs a copying generational GC
  (Cheney, minor then major "fullsweep"). The new block is sized from a
  Fibonacci-like table, then by 20% steps for large heaps; live data
  *and the stack* are copied into it, and the old block is freed. After
  a GC that finds little live data, the heap shrinks. So a process pays
  for its peak only until its next GC.
- `erlang:hibernate(M, F, A)` throws the stack away entirely, runs a
  full GC into a heap of exactly the live size, and resumes at `M:F(A)`
  on the next message. gen_server's `hibernate` return uses this; an idle
  hibernated process is a few hundred bytes plus its live state.
- Binaries over 64 bytes live off-heap, counted (`refc` binaries), so big
  payloads are not copied by messages or GC. Messages are otherwise
  copied into the receiver (heap fragments, or an off-heap queue with
  `message_queue_data = off_heap`).

All of this rests on moving memory, which is why it is cheap: start at
1.8 KiB, grow by copying, shrink by copying, discard the stack.

**Why Rig cannot copy it.** Loans point into stacks: `score(?d)&` reads
`d` in the caller's frame. Stable stack addresses are the price of the
best feature Rig has over Tokio and BEAM (tasks view caller data in place,
no copy, no Arc). So Rig must start small *by proof*, shrink *by
releasing pages*, and discard stacks *where no loan points in*.

**What Rig can take:**

1. **Start small by proof (sub-page stacks).** The compiler already
   bounds every frame it emits (`sema.reach_factor`, checked by
   `test/cli/frame_reach.sh`) and finds every recursion cycle
   (`inlining.Pass.cutCycles`). For a task entry whose reachable call
   graph is acyclic and whose extern Zig callees declare a bound, the
   whole stack need is a static number. Such a task can run on a stack
   slot from a slab of size classes (1, 2, 4, 8 KiB), several per page,
   with no guard needed because the bound is proven. On the Mac's 16 KiB
   pages this is the only way below 16.6 KiB per parked task; on Linux it
   takes 5.2 KiB toward 1 to 2 KiB. Tasks that recurse, or call unbounded
   code, keep the 64 MiB reservation. Two prerequisites: the runtime's
   own deep frames must not run on task stacks (the deadlock walk
   `walkFrom` is about 15 KiB: run it on the worker's own stack, as
   `sched.block` already stays under a page), and the per-method stack
   bound the idle path waits for ("until stack bounds are proven per
   method") is the same analysis, so it pays twice. It also unlocks the
   handoff note's "running the task on the waiter's own stack ... safe
   only for a task whose stack use is proven to fit".
2. **Shrink after a peak (stack trimming).** BEAM's heap shrinks at its
   next GC. Rig's equivalent: a fiber that parks for a long wait (accept,
   recv, sleep, a channel) keeps every page its deepest call touched.
   Pages below the stack pointer hold nothing live (keep the red zone),
   so they can be released with `MADV_FREE`/`MADV_DONTNEED`. Do it
   lazily: a sleeping worker sweeps fibers parked longer than some
   milliseconds, and a stack going back to a worker's free list keeps
   only its top page. Check whether the free list today keeps dirty pages
   of ended tasks' peaks; if so, that is resident memory a long server
   keeps for nothing.
3. **Discard the stack where nothing points in (hibernate).** Rig already
   has hibernate by construction: an idle actor is its record (about 20
   words in `Actor(T)`) plus `T`, with no fiber. So the cheapest idle
   connection is actor-shaped, not a parked task. A `net`/`http` mode
   that calls an actor's method on readiness (the reactor style; BEAM's
   `{active, once}` sockets deliver a message, not a blocked read) would
   make an idle connection cost its object, below BEAM's 2.6 KiB and
   near Tokio's 270 B, with no compiler change. A compiler-made
   "spill at a tail wait" (save the few live locals, free the stack,
   resume in a continuation) is possible only where no loan points into
   the frame; it is a stackless transform in disguise and not worth its
   lines before (1) and (3) are measured.
4. **Not segmented stacks.** Chained stack segments do not move and so
   suit loans, but Go and Rust both dropped them for the hot-split cost
   at a segment boundary; Rig's proven bounds give the benefit without a
   prologue check in every function.

Where Rig wins: a message moves in O(1) where BEAM copies in O(size), and
`*T` frozen values play refc binaries' role for every type, not only
bytes.

## 2. Failure and supervision

**BEAM.** Links are bidirectional: an abnormal exit sends an exit signal
that kills the linked process unless it traps exits (`process_flag(
trap_exit, true)`), which turns the signal into an `{'EXIT', Pid, Reason}`
message. Monitors are one-way and stackable: `{'DOWN', Ref, process, Pid,
Reason}`. Supervisors are processes that trap exits and apply a strategy:
`one_for_one`, `one_for_all`, `rest_for_one`, and `simple_one_for_one`
(dynamic children, now `one_for_one` with `start_child`). Each child spec
has a restart kind (`permanent`: always; `transient`: only after an
abnormal exit; `temporary`: never), a shutdown (`brutal_kill`, a
timeout in ms then kill, or `infinity` for supervisors), and children
start in order and stop in reverse. Intensity `MaxR` in `MaxT` (default 1
in 5 s) escalates: past it the supervisor itself dies, and its parent
decides. "Let it crash" works because a process's whole heap is its own:
death frees all of it, closes its ports, and fires its links and
monitors. Nothing in the language checks any of it: a child spec is a
map, a reason is any term, a pid is untyped.

**Rig today.** Structured tasks are links downward, automatic and
total: a task's panic passes to its owner at its wait or drop. Actors are
gen_servers; a dead actor's waiting caller panics, as a caller of a dead
gen_server exits. `*Actor.supervised(make, restarts:, per:)` is a
one-for-one permanent child whose handle survives restarts (Erlang needs
registered names because the pid changes). `task.supervise(f, ...)`
restarts a function on an error or a panic. `task.isolate` is a boundary
that statically guarantees nothing outside it was lent to write: Erlang
gets that from isolation at run time, Rig from the checker at no cost.

**Gaps against BEAM:**

- **A crash leaks.** A boundary abandons the dead frames' memory and a
  dead actor's value ("abandoned, not dropped"). A supervised actor that
  crashes once a minute in a long-running server leaks its state once a
  minute; BEAM frees it. This is the one place "let it crash" does not
  yet hold in Rig. The fix that fits ownership is a region per actor (and
  per isolate): the actor's allocations come from a heap of its own
  (alloc.zig already keeps a heap per thread), so a death frees the
  region wholesale, without walking a half-changed value. What crosses
  out (a method's result, a value moved to another actor) must leave the
  region: either copied at the boundary, as BEAM copies every message, or
  moved by re-homing its allocation, which needs the allocator to know
  owners. This touches ownership and allocation, so it is a design round
  for the owner; first measure bytes leaked per crash on a supervised
  `http.serve` handler and actor.
- **No monitor.** Only a caller learns that an actor died. A supervisor
  of several actors, or a registry, needs to watch without calling: an
  `on_down` arm on a weak handle, `match task.select(down: ~a.on_down(),
  ...)`, alongside the existing `?t.on_end()`, gives Erlang's monitor
  with a typed reason (`Stop.panicked`, carrying the panic's data once
  errors carry data).
- **Restart defaults.** `task.supervise` with no `restarts:` restarts
  forever; Erlang's default is 1 in 5 s and escalation, because an
  unbounded restart loop hides a deterministic bug and spins a core. Rig
  should default to a bound (say 3 in 5 s) and fail upward past it.
- **No strategies.** Actors that share an invariant (a cache and its
  index) must restart together: `one_for_all` and `rest_for_one`.
- **No forced stop.** Erlang's shutdown timeout ends in `brutal_kill`.
  Rig cannot kill a task that never reaches a fallible wait (its stack
  may hold loans its owner relies on), so the planned grace deadline for
  cleanup and the debug watchdog for canceled tasks still running are
  the honest substitute; say so in the supervision docs.

**A supervision library on Rig's model** (all `std`, no syntax):

```text
sup = Supervisor(strategy: .rest_for_one, restarts: 3, per: 5)
db    = !sup.actor(*|+cfg| Db(cfg))              # permanent
cache = !sup.actor(*|+db| Cache(+db))            # restarted after db
jobs  = !sup.task(|| run_jobs()!, restart: .transient)
```

- Children start in the order written and stop in reverse, which is the
  drop order of the `Supervisor` object: ownership gives Erlang's
  shutdown ordering for free.
- Restart kind follows the type: `.transient` restarts on a panic or an
  error but not a normal return; a child whose function cannot fail
  cannot be `.transient` on errors, and the checker says so.
- `make` closures must send and capture nothing that carries a loan,
  already required; they could also be required to capture only frozen
  or copied config, so a restart rebuilds from the same inputs.
- Child handles are typed (`*Actor[Db]`) and stable across restarts;
  a supervisor tree is an ordinary owned value, so a whole tree is
  stopped by dropping it.
- Escalation: past its intensity a supervisor fails as an error of its
  own set (`Sup.gave_up`), which its parent's supervisor sees.

## 3. Mailboxes

**BEAM.** One unbounded queue per process; `send` never blocks. `receive`
scans for the first message matching any clause, leaving the others
(selective receive). It serves three needs: waiting for the reply to my
own call (made O(1) by the reference trick and receive markers), handling
messages in an order the state needs (gen_statem's `postpone`), and
system messages. Its costs: an O(n) scan when a large queue holds no
match, and unbounded queues that grow until the node dies, the most
common BEAM outage. Defences are manual (`max_heap_size`, load shedding,
`message_queue_len` polling, libraries like `gen_stage` for demand).
OTP 28 added priority messages to an alias (EEP 76), for the control
plane.

**Rig.** A method call is a typed, checked message whose reply slot lives
in the caller's frame, so need one dissolves. Each waiting caller holds
at most one message, so the mailbox is bounded by the number of callers:
back-pressure with nothing to write. `&` calls take one of `mailbox: n`
slots. Cancellation is a flag, not a message, so the control plane is
already out of band.

**Recommendations:**

- **No `receive` form, no priorities.** A receive would bring untyped
  dispatch back. Priorities add starvation; two actors, or a `select`
  over channels, cover the real cases.
- **No fire-and-forget cast.** BEAM's unbounded `cast` is where its
  outages start; Rig's `&` call, held in a `Tasks[Void]` that removes
  finished tasks, is a bounded cast. Keep it.
- **Deferral, the one thing selective receive gives that Rig lacks:** a
  method that cannot proceed in the actor's current state (pop from
  empty, a state machine's event that belongs to a later state) cannot
  wait inside the method, since it holds the actor. Ada's protected
  entries with barriers (`entry Get when Count > 0`) and gen_statem's
  `postpone` solve this: the call stays queued until a condition on the
  state holds, re-evaluated after each method. A guarded method is a
  design round (it interacts with deadlock detection: a call waiting on
  a guard is a wait on the actor), not a quick add; until then a `Chan`
  is the answer.

## 4. Fairness and latency

**Reductions.** A BEAM process runs for a budget of reductions (4000 per
slice since OTP 20): roughly one per function call, more for BIFs and
GC, and every loop is a recursive call, so every iteration checks. NIFs
must report work (`enif_consume_timeslice`) and stay under about 1 ms, or
go to dirty schedulers (CPU: one per core; IO: 10 by default). Four
priority levels; per-scheduler run queues with stealing plus a periodic
balancer; schedulers spin before sleeping (`+sbwt`), which burns CPU, and
can compact load onto fewer schedulers (`+scl`).

**Rig's yield checks** are comparable and cheaper: a countdown of 1024
loop turns per outermost loop, a flag read on each function in a cycle's
feedback vertex set, and a yield only when work waits. The `hog` result
(under 0.1 ms behind a long loop, against 2 to 3 ms for Tokio and Go) is
better than BEAM's typical slice. The gap: **a slice is counted in
turns, not work.** A loop whose body calls a large non-recursive function
taking 50 µs a turn yields every 51 ms. BEAM counts every call. Fix with
no change to a check's cost: decrement the countdown by a static weight
per turn (the compiler knows the body's reach and its callees' sizes), so
a slice targets a time (say 20 to 50 µs) rather than a count. Add a `hog`
variant with heavy bodies to measure it.

**Extern Zig calls are Rig's NIFs.** A long computation in a Zig shim
(hashing a large buffer, a sort) has no yield check and holds its
worker. Either the shim calls the turn check itself (an `enif_consume_
timeslice` analogue exposed to std's Zig), or an extern declaration marks
a call as long so it runs on the pool. The blocking pool also mixes
CPU-bound and blocking calls in one set of threads; BEAM separates them
for good reason (a CPU job should not delay a file read). Low priority.

**GC versus ownership.** BEAM's per-process GC has no global pause, but a
process with a large heap pauses for its own GC (milliseconds at 100 MB),
a long mailbox makes GC slower, and refc binaries held by long-lived
processes leak memory until a GC that may not come. Rig has none of this:
no pause, deterministic drops, and memory proportional to live data. Its
analogue is the cost of a drop: dropping a 10-million-entry `Map` in a
request handler is O(n) on that request. If it shows in p99, an explicit
`task.drop_later(<big)` in std keeps the effect visible; the compiler
should never move a drop off the path by itself.

## 5. Distribution and hot code loading

**Hot code loading** (two versions of a module, fully qualified calls to
switch, `code_change/3` to convert state, appup/relup releases) fits a
dynamically typed VM with late-bound calls. Rig inlines across modules,
monomorphizes, and checks ownership program-wide; per-function swap
would undo all of it. What is worth having is **upgrade by handoff**: a
new binary takes the listening sockets (fd passing or `SO_REUSEPORT`, as
std.http's pre-fork mode already starts), the old one stops accepting,
drains, and ends. Actor state that must survive a restart is written out
and read back with a typed serializer, which is `code_change` done
honestly at the type level. A small std library, not a language feature.

**Distribution** (location-transparent pids, the distribution protocol,
`global`) makes a remote call look local, which hides latency, partial
failure, and a full mesh that scales poorly. Rig's loans cannot cross
machines, and its send/sync facts describe cores, not networks. If Rig
ever offers it, it should be a typed RPC library over `api` shapes, with
a third derived fact ("wires": the value has a wire form) and every
remote call fallible with network errors. Not before the rest.

## 6. Ranked recommendations

1. **Proven-bound small stacks.** Slab stacks of 1 to 8 KiB for tasks
   whose reachable calls are acyclic and bounded; move the deadlock walk
   and other deep runtime frames off task stacks. Closes most of the one
   gap Rig admits (16.6 KiB to 1 to 4 KiB on the Mac) and reuses the
   per-method bound the idle path wants.
2. **Actor-shaped idle connections.** A readiness-driven mode in
   std.net/std.http that calls an actor's method, so an idle connection
   holds no stack: below BEAM and near Tokio, with no compiler change.
3. **Stack trimming.** Release pages below the stack pointer of long
   parked fibers and of stacks back on a free list.
4. **Supervision library:** monitors (`~a.on_down()` in `select`),
   strategies (`one_for_one`, `one_for_all`, `rest_for_one`), restart
   kinds keyed to the function's type, start and stop order from
   ownership, escalation as an error, and a bounded default intensity
   (no infinite restarts by default).
5. **Reclaim on crash:** a region per actor and isolate so a panic frees
   the dead state. Measure the leak per crash first; owner's design
   round, since it touches ownership and allocation.
6. **Work-weighted yield countdown**, plus a turn check or a "long" mark
   for extern Zig calls, so a slice is bounded in time as reductions
   bound it.
7. **Observability:** a live view (`rig top` or a signal-triggered
   dump) of each actor's mailbox length, each task's wait (the deadlock
   walk already records it), touched stack, and restarts: BEAM's
   observer/recon is a large part of why teams trust it in production.
8. **Guarded methods** (deferral) as a design round, in place of
   selective receive; no receive form, no priorities, no unbounded cast.
9. **Upgrade by handoff** in std (socket passing, drain, typed state
   handoff); no hot code loading; distribution only later, as typed RPC
   over `api` with a "wires" fact.
