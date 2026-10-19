# Panel 1: Runtime engineers on Rig's concurrency engine

Panel: (a) a Tokio core maintainer, (b) a Rust async and language-design
expert, (c) a C systems engineer (io_uring, kqueue, epoll, libuv,
libdispatch).

Path prefixes used in citations:
- `T/` = `tokio/src/runtime/` in the Tokio repository
- `TS/` = `tokio/src/` in the Tokio repository
- `Z/` = `lib/std/Io/` in Zig 0.17
- `C` = `docs/CONCURRENCY.md`, as drafted when reviewed

Byte and nanosecond figures are the panel's estimates from the code's
layout. Nothing was run.

---

## 1. Tokio's scheduler, mechanism by mechanism

**(a) Per-worker local queue.** Each worker owns a fixed ring of 256
slots (`T/scheduler/multi_thread/queue.rs:56,63`). Only the owner pushes.
Any thread may pop or steal. A push is a plain `Release` store of `tail`
with no read-modify-write (`queue.rs:236-251`). The owner's `pop` needs a
CAS on `head`, because stealers race it (`queue.rs:361-395`). `head`
packs two indices, `steal` and `real` (`queue.rs:36-50`), so a queue has
at most one stealer at a time, and a stealer can claim a whole batch
with one CAS. When the ring is full, the owner moves half of it (128
tasks) plus the new task to the global queue in one batch
(`queue.rs:253-316`). So overflow costs one lock per 129 tasks, not one
per task.

Why it matters: the hot path for spawning or waking from a worker is one
uncontended store. Nearly all scheduling happens without touching shared
cache lines.

**(a) The LIFO slot.** When a running task wakes or spawns another, the
new task goes into `core.lifo_slot`. The slot's previous occupant moves
to the back of the queue (`worker.rs:1386-1416`). After the current poll,
the worker runs the slot's task at once, while the message the two tasks
share is still in L1 (`worker.rs:712-781`). Two guards keep it fair:
- at most `MAX_LIFO_POLLS_PER_TICK = 3` in a row, which stops two tasks
  ping-ponging forever (`worker.rs:270,764-767`);
- the LIFO task inherits the parent's coop budget (`worker.rs:737-750`).

Weakness: the slot cannot be stolen (`worker.rs:480-482`). If the current
task runs long, the task in the slot waits behind it. That is a known
tail-latency bug, which is why `disable_lifo_slot` exists.

**(a) The global inject queue.** It is a `Mutex`-guarded intrusive list,
linked through the task header's `queue_next`, with an atomic length so
"is it empty?" takes no lock (`T/scheduler/inject/shared.rs:12`,
`inject/rt_multi_thread.rs:48-75`). Spawns and wakes from outside the
runtime land here (`worker.rs:1374`). A worker checks it first once every
`global_queue_interval` ticks (`worker.rs:1092-1099`). That interval
tunes itself: about 200 µs divided by the EWMA of poll time, clamped to
[2, 127] (`stats.rs:31-37,56-68`). A worker that runs out of local work
pulls a fair share from it: `len / num_workers + 1`, capped at half its
ring (`worker.rs:1106-1157`). I/O and timers are polled every
`event_interval = 61` ticks, even under load (`builder.rs:283-295`,
`worker.rs:810-825`).

**(a) Work stealing, half at a time.** A worker starts at a random victim
(`worker.rs:1176-1195`) and takes `n - n/2` tasks (`queue.rs:487-488`). It
copies them into its own ring before publishing them with one `Release`
store (`queue.rs:417-470`). It falls back to the inject queue last.
Stealing half balances load in O(log n) rounds and keeps every queue from
moving back and forth.

**(a) Throttling searching workers.** A worker may enter "searching" only
while `2 * num_searching < num_workers` (`idle.rs:108-118`). A waker
unparks a sleeper only if nobody is searching (`idle.rs:51-80`), checked
with a `SeqCst` RMW (`idle.rs:157-162`). A searcher that finds work wakes
one more worker (`worker.rs:1498`), so wakeups spread in a chain rather
than a herd. The last searcher to park rechecks every queue
(`worker.rs:1232-1257`, `1484-1496`), which closes the lost-wakeup race.

Without this throttle, an 8-core box burns most of its cores spinning on
each other's queue heads whenever one task arrives.

**(a) Park and unpark.** The parker has states `EMPTY`, `PARKED_CONDVAR`,
`PARKED_DRIVER` and `NOTIFIED` (`park.rs:45-48`). There is one I/O and
timer driver, behind a `TryLock`. The first worker to park takes it and
sleeps in `epoll_wait`. The rest sleep on condvars (`park.rs:85-104`).
Events the driver dispatches land in that worker's local queue, and
stealing spreads them (`worker.rs:830-839`). While the driver runs,
notifications are batched until the park ends (`worker.rs:1412-1416`).

Weakness: one thread does all `epoll_wait` and dispatch. At high core
counts that is Tokio's I/O bottleneck.

**(a) Cooperative budget (coop).** Each poll gets a budget of 128
(`TS/task/coop/mod.rs:115-116`). Every Tokio resource spends a unit
before it reports ready: mpsc, oneshot, semaphore, sleep, I/O
registration and JoinHandle (call sites found by grepping
`poll_proceed`). When the budget runs out, the resource returns
`Pending` and defers the waker (`coop/mod.rs:343-365,396-398`). The task
yields even though its I/O was ready.

This exists because "ready" I/O otherwise never yields
(`coop/mod.rs:15-28`). A task reading a socket that always has data, or a
channel that always has messages, would own the worker forever.

**(a) Task state in one atomic word.** Six flag bits (RUNNING, COMPLETE,
NOTIFIED, JOIN_INTEREST, JOIN_WAKER, CANCELLED) and the reference count
share one `usize` (`T/task/state.rs:17-49`). A task starts with
refcount 3: the owned list, the first `Notified`, and the JoinHandle
(`state.rs:51-61`). Each transition is one CAS loop that updates the
flags and the count together:
- `transition_to_running`, `state.rs:117-145`;
- `transition_to_idle`, `state.rs:151-181`;
- `transition_to_notified_by_val`, `state.rs:215-250`.

So "wake" and "take a reference for the queue" are one atomic, not two.
The rule that a task is enqueued at most once falls out of the NOTIFIED
bit.

**(a) Memory per task.** `Cell<T,S>` is laid out as
`Header | Core | Trailer` (`T/task/core.rs:126-135`), aligned to 128 bytes
on x86_64 and aarch64 so tasks never share a line pair
(`core.rs:64-71`).
- Header: state, `queue_next`, vtable and `owner_id` (`core.rs:169-191`),
  32 B.
- Core: an `Arc` to the scheduler, the task id, and the future or its
  output (`core.rs:149-165`).
- Trailer: the owned-list pointers and the join waker (`core.rs:205-212`),
  about 32-48 B.

So a trivial task takes 128 B, and a typical small task 256-512 B.
Futures larger than 16 KiB in release builds (2 KiB in debug) are boxed
separately (`T/mod.rs:653-657`, `TS/task/spawn.rs:179-181`). A JoinHandle
is one pointer.

**(a) Atomics per spawn, from a worker.**

| Step | Atomic operations | Where |
|---|---|---|
| Task id | 1 `fetch_add` on one global counter, contended across workers | `T/id.rs:81` |
| Owned-list shard | lock and unlock, about 2 RMW | `T/task/list.rs:137-146` |
| Push to the LIFO slot or the ring | 0 RMW | `worker.rs:1395-1408` |
| Notify a parked worker, if the slot was occupied | 1 `SeqCst` RMW | `idle.rs:161` |
| Drop the JoinHandle (fast path) | 1 CAS | `state.rs:360-379` |

Total: one allocation and about 3-5 RMWs.

**Atomics per poll cycle:**

| Step | Atomic operations |
|---|---|
| Queue pop | 1 CAS |
| Transition to running | 1 CAS |
| Transition to idle | 1 CAS |

**Atomics per wake:** 1 CAS (`state.rs:253-282`). A waker clone or drop
is one `fetch_add` or `fetch_sub` (`T/task/waker.rs:70-91`). A waker
passed by reference costs nothing (`waker.rs:16`).

**Atomics per completion:** a `fetch_xor` (`state.rs:184-193`), the join
waker's wake, a `fetch_sub` (`state.rs:198-208`), and the shard lock to
unlink the task.

**(b) JoinHandle semantics.** Dropping a JoinHandle *detaches* the task;
it does not cancel it (`T/task/join.rs:18,35,357-364`). Rust has no async
drop, so a drop cannot wait. Detaching is the only sound choice that
never blocks, and it is why unstructured `spawn` is Tokio's default.

---

## 2. I/O, timers and the blocking pool

**(c) Readiness vs completion.**
- Tokio is readiness-based. Each fd has one cache-padded `ScheduledIo`
  that holds:
  - a readiness word packed with the driver tick (which defeats ABA on
    stale readiness);
  - a mutex-guarded intrusive list of waiters, nodes that live inside
    the waiting future (`T/io/scheduled_io.rs:101-129`).

  Waking drains up to 32 wakers per lock hold and wakes them outside the
  lock (`scheduled_io.rs:251-300`). `turn()` maps each epoll or kqueue
  event to its `ScheduledIo` through the token-as-pointer
  (`T/io/driver.rs:185-225`).

  The key memory property: **an idle connection holds no buffer**.
- io_uring is completion-based. A pending read pins its buffer until the
  read completes. With a million idle connections, that is a million
  pinned buffers, unless you use provided-buffer rings and multishot
  recv.

Zig's Uring backend issues plain `READ` or `READV` with the caller's
buffer (`Z/Uring.zig:5687`). It uses no buffer rings.

**(c) The timer wheel.** It has 6 levels of 64 slots each, with 1 ms
resolution at level 0. Each level's `u64` occupancy bitmap finds the next
slot with one `trailing_zeros` (`T/time/mod.rs:63-76`,
`time/wheel/level.rs:17-20,109-125`). Insert and cancel are O(1) and
need no syscall. It sits behind one global `Mutex<InnerState>`
(`time/mod.rs:96-98,469-471`), a known contention point. The unstable
`time_alt` moves to per-worker wheels (`worker.rs:899-911`).

Zig Uring instead sends a kernel `IORING_OP_TIMEOUT` per sleep
(`Uring.zig:4918`) and `TIMEOUT_REMOVE` to cancel (`Uring.zig:2295`).
Dispatch creates a `dispatch_source` per timer (`Z/Dispatch.zig:1963`).
That is fine for a few timers and wrong for a server that resets an idle
timeout on every request.

**(c) The blocking pool.** It allows 512 threads by default, each kept
alive 10 s (`T/builder.rs:324`, `T/blocking/pool.rs:231`), and it is
sharded to cut lock contention (`T/blocking/sharded.rs:1-13`). It exists
because some work cannot be made non-blocking:
- regular files are always "ready" to epoll;
- `getaddrinfo` blocks;
- foreign libraries block;
- CPU-heavy work hogs a worker.

`block_in_place` instead hands the worker's core to a new thread
(`worker.rs:365`). Rig will need both, especially for `extern` calls.

---

## 3. Tokio's weaknesses and footguns

**(a)(b) No preemption.** Coop only counts Tokio's own resources. A tight
loop, a `serde` parse of 50 MB, or a third-party future that never hits a
Tokio resource holds the worker indefinitely. The LIFO slot and the
single driver make it worse: the stuck worker may be holding the I/O
driver.

**(b) Cancellation by dropping a future at any `.await`.** A future can
be dropped at any suspension point, with no cleanup await. This causes:
- "cancellation-safety" bugs in `select!` loops (data read but lost);
- half-written protocol frames;
- no `async Drop`.

Rig's choice, cancellation as an error delivered only at waiting points
with `defer` running, is strictly better. But it requires *shielding*
(see §6).

**(b) `Send + 'static`.** `spawn` requires `F: Send + 'static` and
`Output: Send + 'static` (`TS/task/spawn.rs:174-178`). The `'static`
bound forces `Arc<…>`, clones of every borrowed input, or
`Arc<Mutex<…>>`. The `Send` bound bites whenever an `Rc` or a
`MutexGuard` lives across an `.await`. In practice this is the most
common complaint from Tokio users.

Rig's loans-into-tasks (`C` §Loans) remove the `'static` problem
outright. That is only sound because drop waits; see the leak caveat in
§6.

**(b) Colored functions.** `async fn` splits the ecosystem: blocking and
async variants of everything, `block_on` inside async panics, and trait
objects need boxing. Rig's uncolored stackful design removes this. The
price is that *any call may suspend*, and that has runtime consequences
(TLS, C stacks), covered in §4.

**(b) State-machine size.** Nested futures compose by embedding, and
the compiler's overlap of sub-future states is imperfect. Real handlers
reach 10-100 KiB. That is why the box threshold exists
(`T/mod.rs:653-657`). Memory is exact, but bloated and copied on move.

**(a) Blocking the executor.** It is the most common production incident:
a sync mutex, `std::fs` or a DNS lookup inside a task. It is detectable
only by metrics.

**(a) Unstructured spawn.** Detached tasks outlive their requests and
leak on errors. `JoinSet` aborts on drop but does not wait.

**(a) Fairness.** The things that hurt fairness:
- the non-stealable LIFO slot;
- the global queue is only polled every N ticks;
- the single I/O driver can strand events on a busy worker until
  `event_interval` comes around;
- no priorities;
- the global task-id `fetch_add` and the owned-list shard lock are
  shared lines on every spawn.

---

## 4. Stackful fibers (Zig `std.Io.Evented`) vs stackless futures

**(c) What the Zig 0.17 backends actually are.**

| | Uring (Linux) | Dispatch (macOS) | Kqueue (BSD) |
|---|---|---|---|
| Stack per fiber | 60 MiB VA (`Uring.zig:256`) | 60 MiB VA (`Dispatch.zig:196`) | 4 MiB (`Kqueue.zig` Fiber) |
| Guard page | none (no `mprotect` anywhere) | none | none |
| Fiber reuse | per-thread free list, with stealing (`Uring.zig:271-311`) | **none: alloc and free per spawn** (`Dispatch.zig:209-215`) | alloc per spawn |
| Run queue | per-thread intrusive **LIFO stack** (`Uring.zig:1066-1074`) | GCD concurrent queue (`Dispatch.zig:488-492,1101`) | per-thread, like Uring |
| Stealing | takes the **whole** queue, probes 2 peers (`Uring.zig:59,936-954`) | GCD's own | probes 4 |
| Waking an idle thread | `MSG_RING` to 1 candidate (`Uring.zig:977-1013`) | GCD | — |
| I/O harvest | only when the ready queue is empty (`Uring.zig:1145-1163`) | a `dispatch_source` **created per read** (`Dispatch.zig:1727-1736`) | — |
| Ring size | 8 SQEs by default (`Uring.zig:800`) | — | — |
| Argument and result limits | context ≤1 KiB, result ≤512 B | the same, asserted "TODO" (`Dispatch.zig:1059-1062`) | result ≤64 B |
| Maturity | 19 TODOs | 20 TODOs | 54 TODOs, `@panic("TODO")` (`Kqueue.zig:754,776,792`) |

The context switch (`Z/fiber.zig:28-210`) saves only sp, fp and pc. It
declares every other register clobbered, so the compiler spills only
what is live. That is a few nanoseconds, comparable to Tokio's
return-from-`poll` plus 2-3 CAS.

Verdict: the switch primitive is good. **The scheduler is a prototype.**
It has:
- LIFO order with no fairness;
- whole-queue stealing, which ping-pongs queues;
- no searching throttle and no global queue;
- no budget;
- completions harvested only when idle, so under steady local wakeups the
  CQ starves;
- per-thread rings with `SINGLE_ISSUER` (`Uring.zig:1022-1026`), so a
  busy thread's completions cannot be reaped by an idle one;
- a vtable `Io` (`Z/../Io.zig:25-26`): every operation is an indirect
  call.

The Dispatch backend allocates 60 MiB per spawn and frees it on exit. At
that size, that is an `mmap`/`munmap` per task, with TLB-shootdown IPIs
across cores. It also builds a dispatch source per read, and it hands
all scheduling to GCD. It cannot approach Tokio on macOS as written.

**(c) Memory per task.** The minimum resident cost of a fiber is the
pages it touches: one 4 KiB page on x86_64, and **16 KiB on Apple
Silicon**, for the header and the top of the stack. A million idle tasks:

| Runtime | Per task | Million idle tasks |
|---|---|---|
| Tokio | 0.25-2 KiB | 0.25-2 GiB |
| Page-granular fibers, x86_64 | ≥4-8 KiB | ≥4-8 GiB |
| Page-granular fibers, macOS arm64 | ≥16 KiB | ≥16 GiB |

Address space: 1M × 60 MiB = 60 TiB, close to x86-64's 128 TiB user
limit. With a guard page, each fiber becomes two VMAs. Linux's default
`vm.max_map_count` of 65,530 then caps you near 32k fibers, unless the
stacks are carved from one reservation.

**(b)(c) Exact stack sizing: Rig's real advantage, with conditions.**
Rig computes each function's frame "reach" and whether it recurses
(`SPEC.md:575-583`). Its overflow safety today comes from a 64 GiB guard
below a 64 MiB stack, because Zig emits no stack probes. Frames may reach
512 MiB (`docs/INTERNALS.md` "the program's stack").

Therefore:
- **The `C` plan, "a default with a guard page", is unsound under Rig's
  own model.** Any frame larger than the guard jumps it and silently
  corrupts the neighbouring fiber. This breaks SPEC's promise that "a
  program that runs out of stack… stops… in every build mode". Unbounded
  fibers need either a guard at least as large as the largest frame, or
  compiler-emitted probes or a prologue limit check for frames larger
  than the guard.
- When the bound is proven, a fiber can come from a slab of exact size
  (rounded to 64 B), with no guard and not page-granular. That beats
  Tokio for small handlers: a 1-3 KiB stack against a 1-2 KiB future,
  but with no state copying. The bound must include the frames of the
  runtime and of `std.Io`. Those are Zig code behind a vtable, invisible
  to Rig's analysis, so they need a measured constant.
- `extern` and C calls must switch to the worker's own system stack, as
  Go's cgo does: glibc needs more than 256 KiB (`Uring.zig:54-56`).
- Loans point into fiber stacks (`C` §Loans), so stacks can never move.
  Go-style copying growth is ruled out. Sizing must be right up front.

**(b) What stackful gains.**
- No coloring.
- `drop` can wait, which enables structured concurrency and borrowing.
- Cheap *preemption* at compiler-inserted safe points.
- Replies and messages can live on the waiting caller's stack, with no
  allocation.
- Stack traces across waits.
- Rig's ownership makes preemption semantically invisible: tasks share
  only "shares" types and actor messages.

**(b) What it loses.**
- Per-task memory is page-granular unless the size is proven.
- Context-switch cache locality is worse for deep stacks.
- Thread-local storage becomes a hazard. LLVM caches TLS addresses across
  calls, and any call may now migrate the fiber. Zig works around this
  with `noinline fn current()` (`Uring.zig:110`, `Dispatch.zig:83`).
  Rig's codegen and runtime, such as the release queue for nested drops
  (`INTERNALS.md` RcBox), must never hold TLS state across a call that
  may suspend.
- TSan and ASan need fiber-switch annotations, which `fiber.zig` lacks.
  The plan's "every benchmark run under the sanitizer" needs those
  annotations first.

---

## 5. Ranked mechanisms for Tokio-class throughput and p99

**MUST** (in order):
1. **A bounded per-worker FIFO ring with steal-half.** One owner pushing,
   many stealers, a packed steal/real head, a random first victim, and
   batch overflow to a global queue. This replaces Zig's LIFO
   whole-list stealing.
2. **Searching throttle and lost-wakeup-free parking.** At most half the
   workers searching, notify only when nobody searches, chained wakes,
   and a last-searcher recheck.
3. **Bounded I/O and global-queue polling under load.** Harvest the CQ
   or epoll every ~61 ticks and pull from the inject queue every
   ~200 µs worth of polls, so completions never strand behind ready
   work. With per-thread rings, also hand a busy worker's ring off, or
   wake it with `MSG_RING`.
4. **Budget plus preemption.** A per-task budget of about 128 spent at
   every waiting point that completes immediately (I/O, channel, actor
   call, `wait`). Plus a sysmon thread that flags a fiber running more
   than about 10 ms, checked at compiler-inserted loop back-edges and
   function prologues not proven bounded. This is what lets CPU fan-out
   (`parse(f)&`) share one runtime with servers.
5. **A fiber stack allocator.** One large VA reservation carved into
   slots, per-worker free lists, `MADV_FREE` when trimming, never
   `mmap` per spawn. Guards plus probes for unbounded tasks, exact slabs
   for proven ones, and a switch to the system stack for `extern`.
6. **One atomic state word per task.** Flags plus a refcount, with
   Tokio's transitions. Wake is 1 CAS. Enqueue happens at most once,
   through the NOTIFIED bit. `Task[T]` is one pointer, and the result
   slot lives in the fiber header.
7. **A blocking pool and core handoff** for `extern` and blocking calls,
   and DNS.
8. **Per-worker hierarchical timer wheels** (6×64, 1 ms) with lazy
   cancel, and one kernel timeout per worker for its next deadline.
9. **A LIFO slot capped at 3**, stealable once the owner overruns its
   budget.
10. **Join-inline.** `<t.wait()` on a task not yet started claims it with
   one CAS and runs it on the waiter's stack. This is Cilk/ForkJoin
   "tryUnfork", and it makes fine-grained fan-out nearly free.

**OPTIONAL:**
- io_uring provided-buffer rings and multishot accept and recv: needed
  for the million-idle-connections memory target, not for throughput;
- SQPOLL and `DEFER_TASKRUN`;
- thread-per-core and non-migrating local tasks;
- NUMA-aware stealing;
- priorities;
- eager driver handoff;
- task dumps and poll-time metrics. These are close to required for
  production.

---

## 6. Critique of CONCURRENCY.md from the runtime side

1. **The guard-page plan is unsound** (§4). State the overflow strategy
   for fibers: guard at least as large as the largest frame, or probes or
   prologue checks; proven bounds also cover Zig, `std` and runtime
   frames; `extern` switches stacks.
2. **"Scheduling is cooperative… a question for measurement" is the
   wrong default.** Tokio needed coop even with no CPU-bound tasks,
   because ready I/O never yields. Rig adds CPU fan-out to the same
   pool. Make the budget a decision now, and make back-edge preemption
   the planned answer. Rig can afford it; Tokio cannot.
3. **`std.Io.Evented` is not a runtime to build on as-is** (§4 table).
   Decision 12 should read: Rig ships its own scheduler, with a Tokio
   queue, parking and budget, and uses `std.Io` backends only for
   syscalls, or forks Uring. On macOS, use kqueue directly, not the
   Dispatch backend. Bind the backend statically; no vtable.
4. **Drop-cancels-and-waits** is the right semantics, but it needs four
   additions:
   - **Shielding.** `defer`, `errdefer` and `drop` in a canceled task run
     with cancellation blocked. Zig has `CancelProtection` for this.
     Without it, cleanup I/O such as a flush or a close frame fails at
     once.
   - **Two-phase list drop.** Dropping `List[Task]` cancels all, then
     waits for all. Done one by one, the latencies add up.
   - **No silent errors.** Dropping an unwaited `Task[T!]` swallows its
     error. Require the error to be handled, or make dropping it
     explicit.
   - **Unbounded drops.** A child in a CPU loop or a blocking `extern`
     makes the parent's scope exit unbounded. Preemption fixes the
     first; document the second.
5. **Loans plus waiting drop is only sound if a loaning `Task` cannot
   leak.** Rust's scoped-task "trilemma" applies: no `forget`, no `*T`
   cycles, no escape into longer-lived containers. State that a task
   holding loans is a second-class view, including inside `List`.
6. **`*T` across cores.** The moves/shares facts are right, and the
   deeper argument should be written down: `*T` is *task-confined*, not
   thread-confined, so migrating the whole fiber is safe. That argument
   requires:
   - actor fields must *move*, since `spawn Counter(...)` builds the
     value in the caller;
   - no module-level shared handles;
   - no runtime TLS held across suspension.
7. **Bounded mailboxes.** Full-mailbox blocking deadlocks cycles even
   without mutual result-waiting (A full ↔ B full), and it deadlocks an
   actor that sends to itself. Proposed rules:
   - A waiting call needs no bound: the suspended caller *is* the
     backpressure, and its message and reply slot can live in its own
     frame, as an intrusive node like Tokio's `Waiter`.
   - Bound only `&` calls, by taking the permit when the `Task` is
     created.
   - Replies never use mailbox capacity.
   - Add an uncontended fast path: if the actor is idle, the caller takes
     it with one CAS and runs the method inline on its own fiber. The
     actor round trip then costs about one CAS, not two context switches
     and a queue hop.
8. **"The call starts at once, before the next statement"** promises
   something unobservable and unenforceable. Say "may start at once".
   Then specify `&` as `concurrent`, not `async`. On `Io.Threaded`,
   `async` may run inline, and Dispatch's `async` falls back to running
   synchronously (`Dispatch.zig:1034-1047`). That deadlocks
   producer/consumer pairs and actors. Define what `&` does when
   concurrency is unavailable (`error.ConcurrencyUnavailable`).
9. **One global `Io`.** Fine for programs, bad for tests. Provide a
   seedable, deterministic single-thread backend with virtual time
   (Tokio's `current_thread` plus paused time), and let `rig test` pick
   it.
10. **Deadlock reporting.** "Every task is waiting" only catches total
    quiescence, and pending sockets hide even that. Record a
    `waiting_on` pointer per task (cheap) and detect cycles on demand.
11. **Order of work.** Step one on `Io.Threaded` gives one OS thread per
    concurrent task and one mutex-guarded run queue
    (`Threaded.zig:31-46,1798-1808`). That is fine for semantics, but no
    performance conclusion before step four should be drawn from it.
    Add a step 3½: the scheduler core (items 1-6 of §5), benchmarked with
    no I/O, before `http.serve`.
