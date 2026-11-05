# Crystal 1.23.0-dev through a Go lens: concurrency, and what Rig should take

Read-only review of `~/Data/Code/rig/misc/crystal/src` (paths below are relative to it), against Rig's origin/main docs (concurrency.md, scheduler.md, SPEC §18, std/task.rig, std/par.rig, bench/tasks/PROGRESS.md) and the 2026-11-04 concurrency SYNTHESIS. Nothing was built or timed; every memory figure for Crystal is an estimate from the code.

## 1. Scores

| Area | Score | Why |
|---|---|---|
| Syntax | 8 | Ruby's readability with static types: blocks, `&.method` shorthand, `when` / `select when`; `end` noise and macro syntax are the cost. |
| Operators | 7 | Overloadable, `&+` wrapping vs checked `+` is the right default, `===` in `case` is powerful but hidden dispatch. |
| Type system | 7 | Union types with flow typing make nil safety natural; but whole-program inference with no required signatures is what kills compile speed and modularity, and nothing models ownership or sharing. |
| Object system | 7 | `class` (reference, GC) vs `struct` (value) is a clear cost split; modules as mixins are good; open classes and monkey-patching make every program's meaning global. |
| Grammar | 5 | 6,621-line hand parser plus 2,884-line lexer (compiler/crystal/syntax/parser.cr, lexer.cr), whitespace-sensitive in surprising places (`foo [1]` vs `foo[1]`, `a -1`), macros interpolate into syntax: hard for tools and for AIs. |
| Concurrency | 5 | The engine is serious, the model is not: unstructured `spawn`, exceptions printed and swallowed, no race checking, and the default context still runs with parallelism 1 for compatibility. |
| Channels and select | 6 | `select when x = ch.receive ... when timeout(1.second) ... else` reads beautifully; but arms are tried in written order (unfair), `Channel(Nil)` is ambiguous with closed, and a blocking select heap-allocates. |
| Scheduler and engine | 7 | A faithful port of Go's runq/globrunq, `schedtick % 61`, spinning threads and sysmon syscall handoff; missing preemption, one locked event loop per context, and a GC read lock around every switch. |
| Memory per fiber | 4 | 8 MiB mapping per fiber, a fixed 4 KiB guard with no probes, dirty pages kept on reuse; at rest at least one page (4 KiB Linux, 16 KiB Mac) plus a GC'd `Fiber` object and its scan cost. |
| Tooling (formatter, compile speed) | 5 | Formatter 8: one canonical style, no options, `--check` (gofmt culture done right). Compile speed 3: the semantic pass reruns over the whole program on every build; only codegen is cached per unit. |

## 2. Area by area

### Execution contexts vs Go's GMP and Rig's engine

`Fiber::ExecutionContext` (fiber/execution_context.cr:10-99) splits the runtime into named pools: `Concurrent` (one fiber at a time, any thread), `Parallel` (work stealing, resizable) and `Isolated` (one fiber owns one thread). A fiber never leaves its context (execution_context.cr:27-29).

Inside `Parallel` the design is Go's, ported almost line for line:
- per-scheduler ring of 256, "a port of Go's `runq*` functions" (fiber/execution_context/runnables.cr:1-8), overflow of half to a global queue (global_queue.cr:1-3);
- every 61st tick the global queue first, Go's `schedtick % 61` (parallel/scheduler.cr:132);
- spinning before parking, four rounds (parallel/scheduler.cr:311-320), random-victim stealing (parallel.cr:278-289);
- a SYSMON thread (monitor.cr:31) that hands a scheduler stuck in a syscall to another thread (monitor.cr:139-155), grows parallelism at most twofold per 100 ms (monitor.cr:164-203), and returns pooled stacks (monitor.cr:209-219).

So a Crystal "scheduler" is Go's P, a `Thread` is the M, and contexts are a layer Go does not have: user-visible partitions of Ps.

What it lacks that Go and Rig have:
- **Preemption.** None, cooperative only; monitor.cr:44-51 is a TODO for a cooperative "maybe yield". Rig's compiler-inserted yield checks already beat Go's async preemption on `hog` (77 µs against 3.2 ms).
- **A poller per worker.** Each context has one event loop; a scheduler takes it with `@event_loop.lock?`, and any other idle scheduler parks on a condition variable (parallel/scheduler.cr:238-269). This is Go's single netpoller, made worse by a lock. Rig's per-worker kqueue/epoll is ahead.
- **No GC on the switch path.** Every `swapcontext` takes `GC.lock_read` (fiber/execution_context/scheduler.cr:64-71), because Boehm must stop the world and scan every fiber stack. Rig has none of this.
- **A global fiber list.** Every `Fiber.new` pushes onto `Fiber.fibers` (fiber.cr:127), a `Thread::LinkedList` under one mutex (crystal/system/thread_linked_list.cr:10), and every end takes it again (fiber.cr:168). Spawn throughput on many cores pays for it.

Where Crystal's design shows something Rig should copy is the syscall handoff (idea 1 below).

### Memory per fiber

- `StackPool::STACK_SIZE = 8 * 1024 * 1024` (fiber/stack_pool.cr:6), one `mmap` each (crystal/system/unix/fiber.cr:10), `MADV_NOHUGEPAGE` on Linux (:14), and a guard of exactly 4096 bytes (:18). With no stack probes, a frame larger than 4 KiB can jump the guard; Rig's guard sized to the program's largest frame (scheduler.md "Stacks") is safer.
- `reset_stack` does nothing on Unix (crystal/system/unix/fiber.cr:24): a reused stack keeps every page it ever dirtied. The pool is trimmed by half every 5 s and cleared when the process goes idle (stack_pool.cr:34, monitor.cr:209-219).
- At rest: `makecontext` writes the top page, and a parked fiber's frames (`Fiber#run`, the proc, the event-loop wait) usually stay within one or two pages. Estimate: 4-8 KiB on Linux, 16 KiB on the Mac, the same as Rig's 16.6 KiB, plus a `Fiber` object on the GC heap (a couple hundred bytes) and a page table for each 8 MiB mapping, the same hidden cost the earlier Go review found in Rig.
- It cannot grow or move stacks for the same reason Rig cannot: raw pointers into frames (Crystal: conservative GC and `pointerof`; Rig: views into frames). Crystal's answer, a huge lazily committed reservation, is Rig's answer today. The approved plan's small stacks with a proven bound and non-moving segments are better than both Crystal and Go's copying for a language whose tasks view their parent's frame.

**This confirms plan A3** and says nothing better exists in Crystal.

### Channels and select

- One `SpinLock` per channel (channel.cr:29); waiting `Sender`/`Receiver` records live on the waiting fiber's stack (channel.cr:51-80), so a blocking send or receive allocates nothing.
- `select` is a desugaring (compiler/crystal/semantic/literal_expander.cr:711-760): each `when x = ch.receive` becomes `ch.receive_select_action`, gathered into a tuple, and `Channel.select` returns `{index, value}` for a `case`. Any type that defines a `foo_select_action` method and implements the `SelectAction` module (channel/select/select_action.cr) becomes a select arm. In practice the module is `:nodoc:`, and only channels and `timeout` implement it.
- Locks are taken in a sorted order to avoid deadlock between selects (channel/select.cr:92-96), as Go's `lockorder` does.
- **Arms are tried in written order** (channel/select.cr:98-111). Go randomizes `pollorder` for exactly this reason; Crystal's first arm can starve the rest. Rig already turns the order ("an order that turns, so none starves", SPEC §18 Channels).
- A blocking select heap-allocates its shared state (channel/select.cr:118-122) and the contexts.
- `Channel(Nil)` or `Channel(T?)` are documented as indistinguishable from closed through `receive?` (channel.cr:22-24).
- `close` wakes everyone (channel.cr:108-121); a send on a closed channel raises `ClosedError`.

Rig's `match task.select(got: !a.on_recv(), late: time.after(ms: 50))!` is already the better design: named arms, a checked `match`, bodies in the enclosing scope, CML commit of one arm, fair order. Crystal's sugar is a little lighter to read, and nothing more.

### Unstructured spawn and leaks

- `spawn { ... }` returns a `Fiber` that nobody has to keep (concurrent.cr:79-89). An exception that escapes is printed and dropped (fiber.cr:156-165): the program goes on with the work silently missing.
- The block captures locals by reference, so a loop `spawn { print(i) }` prints `55555` and the docs teach the `spawn print(i)` macro to copy arguments (concurrent.cr:96-125). This is Go's pre-1.22 loop-variable bug, kept by design.
- The closest thing to structure is `WaitGroup.wait { |wg| wg.spawn { ... } }` (wait_group.cr:44-48), and it is not structured: with no `ensure`, an exception in the block skips `wait`, and the spawned fibers run on, orphaned.
- No cancellation exists at all.

Rig's owned `Task[T]`, cancel-and-wait on drop, and `Tasks[T]` already settle all of this.

### Races without ownership

Crystal moved to threads late and the docs show the cost. The `Concurrent` context exists so that code which assumes one thread can keep doing so; its own example says the unsynchronized `result += value` is "safe, but only for this example" (fiber/execution_context/concurrent.cr:24-47). `Array`, `Hash` and `String::Builder` are not thread-safe, and nothing tells you when a `Parallel` context shares one. The answer was library types: `Sync::Exclusive(T)` and `Sync::Shared(T)` (sync/exclusive.cr:34, sync/shared.cr:35), a lock that owns its value as Rust's `Mutex<T>`, with checked (relock raises) as the default (sync/type.cr). Good ideas, unenforced.

Rig's local tasks are Crystal's `Concurrent` context, inferred and proven by the compiler instead of chosen by the programmer and trusted (SPEC §18, "Local tasks").

### The event loop

`Crystal::EventLoop` has backends for epoll, kqueue, io_uring, IOCP, libevent and WASI (crystal/event_loop/). The polling backends are well made:
- edge-triggered, registered once per fd and kept until close (crystal/event_loop/epoll.cr:86, kqueue.cr:120);
- a generational arena maps fds to poll descriptors so the kernel never holds a GC pointer and a stale event is detected (polling.cr:62-80);
- wait events live on the waiting fiber's stack (polling.cr:131-141, 520-551) and timers sit in an intrusive pairing heap (timers.cr);
- an fd moves between loops on demand, but not with waiters (polling.cr:23-28).

Rig has the same shape (edge counts, per-worker deadline heaps, wait records that reserve under a page), with one poller per worker instead of per context. Nothing here for Rig to take, beyond the io_uring backend existing as a reference for the "io_uring buffer rings" the design lists as measured work.

### What Crystal's move to threads taught it

1. **Thread safety cannot be retrofitted.** `-Dpreview_mt` existed from 2019; in 1.23 the default context still starts at parallelism 1 "for backwards compatibility reasons" (execution_context.cr:71-78). The ecosystem assumed one thread, and no checker can now find where. Rig having send and share facts from the start is the whole difference.
2. **Partition rather than share.** Contexts that fibers never leave are how Crystal isolates unsafe code. Rig does this per task, automatically.
3. **A lock should own its data, and check by default.** `Sync::Exclusive`, `Sync::Type::Checked`. Rig's actors and `*Cell` already embody this.
4. **A sysmon thread is needed** for syscalls and housekeeping, even without preemption.
5. **GC is the tax on every switch** (`GC.lock_read`), and on every fiber's stack at scan time.

## 3. Ideas for Rig, ranked

### 1. A Go-style syscall handoff instead of a pool hop, for foreign calls that are usually short

**Crystal.** `Fiber.syscall { LibC.flock(fd, flags) }` (crystal/system/unix/file_descriptor.cr:188; addrinfo.cr:52). On entry, one atomic add sets a flag and bumps an ABA counter; on return, one CAS clears it (fiber/execution_context/scheduler.cr:100-133). SYSMON sees a flag still set on its next 10 ms tick and moves the whole scheduler (ring, queue position) to a fresh thread from the pool (monitor.cr:139-155). The returning thread finds itself detached, re-enqueues its fiber and goes back to the pool. The common, fast call costs two atomics and no thread switch; only a slow one pays.

**Rig today.** A call that may block runs on the blocking pool while its task parks (scheduler.md "Shape", `rig.blocking`): every such call pays a hop, even a `flock` that returns in a microsecond. Plan C3 ("hand off a stuck worker in a blocking foreign call; the 1 ms watcher already exists") covers the idea; Crystal supplies the protocol.

**Rig form.** No new syntax. A Zig shim or `extern` call that may block is marked in std (`rt.syscall(...)`); emit wraps it in enter/leave; the watcher detaches the worker's identity (ring, poller, deadline heap) to a spare thread.

**Guarantees.** It keeps them, with one rule Crystal does not need: **local tasks stay with the blocked OS thread**, since their non-atomic counts must not change on two cores. Only the crossable part of the ring moves, or the handoff is skipped when local tasks are pinned there. This needs a short design note against SPEC §18 "Local tasks"; it is engine-only otherwise. Keep the pool for calls known to be long (file I/O on slow disks, DNS).

### 2. One internal select-arm protocol, so std adds arms without compiler cases

**Crystal.** `select` is sugar over the `SelectAction` module (channel/select/select_action.cr): `execute` (try now), `wait`/`unwait` (enqueue and dequeue a waiter), `lock`/`unlock`/`lock_object_id` (global lock order), `result`. Channels and `timeout` are just two implementers.

**Rig today.** The arms are a fixed list the checker knows: `on_recv`, `on_send`, `on_end`, `time.after` (SPEC §18 Channels). Plan D1 wants `~a.on_down()` in select; a readable socket, a `Signal` change or a process exit would each be another special case.

**Rig form.** An internal shape (later an `api`) that an arm-making method returns, recognized by type rather than by name: `down: ~a.on_down()`, `ready: ?sock.on_readable()`. The checker's rule is unchanged: an arm's lends and takes are those its signature shows, held until the select returns.

**Guarantees.** It keeps them if the arm type stays a positive list in one classifier (North Star 4), the protocol's commit is the same CML two-phase commit, and order still turns. Do not copy Crystal's name-mangling (`receive` to `receive_select_action`, literal_expander.cr:762-771): it is a hidden rewrite.

### 3. The pool-trimming policy for idle stacks

**Crystal.** Pooled stacks are trimmed by half every 5 s, and all of them freed once the process has been idle for the longest watcher interval (monitor.cr:7-10, 209-219; stack_pool.cr:34-50). The watcher's own interval doubles while idle, up to 10 s, then it sleeps until woken (monitor.cr:77-122), so an idle server burns no wakeups.

**Rig today.** Plan A2 releases the dead pages of each worker's 64 free stacks; the 1 ms watcher exists. Crystal adds two details worth taking: decay by halves on a timer, not all at once (a burst is followed by another burst), and **a watcher that backs off when idle** (check whether Rig's 1 ms watcher sleeps when every worker is parked; on a laptop a 1 ms tick forever is a battery cost).

**Guarantees.** Engine-only; unaffected.

### 4. Bound the spinning, and grow parallelism by at most double

**Crystal.** Spinners are counted (parallel/scheduler.cr:322-334); only one thread waits in the poller and the rest park; SYSMON wakes at most twice the active count per 100 ms (monitor.cr:180-183). Go caps spinning Ms at half the busy Ps for the same reason.

**Rig today.** Idle workers steal from a random victim; scheduler.md does not say whether the number of spinning workers is capped. Worth checking under `fanout` and on pup's 22 cores: uncapped spinning shows up as wasted cycles on mostly idle servers, not in throughput rows. Engine-only.

### 5. A main-thread context: confirms plan D3

**Crystal.** `Fiber::ExecutionContext::Isolated.new("Gtk") { Gtk.main }` (fiber/execution_context/isolated.cr:31-36): one fiber owns one thread, blocking freely, while `spawn` inside it goes to the default context.

**Rig.** Plan D3, "a main-thread actor for GUI toolkits", is the same idea, and an actor is the better form (its messages are the only way in). Note that **the word "isolate" is taken** in Rig (`task.isolate`, a panic boundary), so Crystal's name cannot be reused for it.

### 6. Category tracing, as a step toward plan D5

**Crystal.** `Crystal.trace :sched, "stole", from: other, size: ...` throughout the scheduler (parallel/scheduler.cr:105), enabled per category by an environment variable at run time, compiled out otherwise.

**Rig.** D5 plans a task dump and counters. A `RIG_TRACE=sched,poll` event stream from the same points is cheap to add alongside, and is what one wants when a `seeds: 20` case fails only on pup. Engine-only.

### Already in Rig, or covered, so not proposed

- Wait records on the waiter's stack (Rig's `sched.block` reserves under a page).
- Go's runq, steal-half, global queue: built.
- Edge-triggered registration and per-worker timer heaps: built.
- `CRYSTAL_WORKERS`: Rig has `RIG_WORKERS` and `task.workers(n)`.
- `WaitGroup`: `Tasks[T]` and `task.all` are strictly better.
- `Sync::Exclusive`: actors and `*Cell`.
- Small stacks: plan A3, and Crystal does worse.

## 4. What Rig should not take

- **Unstructured `spawn` that returns an ignorable fiber** and prints-and-drops its exceptions (concurrent.cr:79, fiber.cr:160-165). It breaks "effects stay visible" and leaks work.
- **Blocks that capture by reference across a spawn** (the `55555` example, concurrent.cr:96-125). Rig's loans already decide this.
- **User-chosen contexts as the safety mechanism.** `Concurrent` is safe only by convention (concurrent.cr:24-47). Rig infers local tasks; asking the programmer to pick a context would be a second, unchecked way to say the same thing.
- **A WaitGroup scope without `ensure`** (wait_group.cr:44-48): an error skips the wait. Rig's drop already cancels and waits.
- **Select arms tried in written order** (channel/select.cr:98): starvation.
- **One locked event loop per context** (parallel/scheduler.cr:238-269): Rig's per-worker poller is better.
- **A fixed 4 KiB guard with no probes** (crystal/system/unix/fiber.cr:18): a large frame skips it.
- **Dirty pages kept on stack reuse** (crystal/system/unix/fiber.cr:24): a single deep task leaves its high-water mark resident on every reuse.
- **A global mutex-protected list of all fibers** (fiber.cr:127): a dump can be built from per-worker records instead.
- **A nilable element type that collides with "closed"** (channel.cr:22-24). Rig's `recv` gives `T?`: make sure `*Chan[Int?]` cannot be confused the same way (it would give `Int??`; check how SPEC treats a nested optional there).
- **Whole-program type inference** without signatures: it is why Crystal cannot compile modules separately and reruns the whole semantic pass each build. Rig's required signatures are the right call.
- **Open classes, monkey-patching and macros as a second language**: they make one file's meaning depend on every other's, against "consistent and clear, ideal for AIs".

## 5. Effect on the approved plan

- **Confirms A3** (small stacks with a proven bound, non-moving segments): Crystal shows the end state of "reserve big, commit lazily", the same 16 KiB on the Mac, plus the reuse leak.
- **Confirms C3** (hand off a stuck worker) and supplies its protocol; add the local-task rule.
- **Confirms D3** (main-thread actor); avoid the name "isolate".
- **Adds to A2**: decay by halves on a timer and a watcher that backs off when idle.
- **Adds a check**: whether spinning workers are capped.
- **Adds a design item for D1**: one arm protocol, so `on_down` and later arms are not each a compiler case.
- Nothing in Crystal argues for stackless tasks, moving stacks, or unstructured spawn.
