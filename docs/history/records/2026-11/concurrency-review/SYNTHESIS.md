# Rig's concurrency against Rayon, Tokio, Go, Swift, and Erlang

This review was read-only, on 2026-11-04. Four experts read Rig's design (docs/design/concurrency.md, docs/internals/scheduler.md, SPEC §18, src/sched.zig, src/tasks.zig) and each other runtime's source. The full reports are beside this file: rayon-tokio.md, go.md, swift.md, erlang.md.

Nothing was timed. Every number below that the benchmarks did not record is an estimate.

## 1. Where Rig stands

Rig is already a fusion of the five models:

| Idea | From | Rig |
|---|---|---|
| One kind of function: no async/await | Go | built (`f()&`, `>t`) |
| Structured lifetimes: no orphans, no leaks | Swift, Trio | built (dropping a task cancels it and waits) |
| A task views its caller's data in place | Rayon's `join`/`scope` | built, more general: no `'static` bound, no `Arc` |
| Types that may cross cores, checked | Rust (Send/Sync), Swift (Sendable) | built (send and share facts) |
| Actors that run each message to its end | Erlang (Swift's actors re-enter at each await) | built, plus deadlock detection |
| Fair time slices | Erlang (reductions), Go (preemption) | built (yield checks): hog 77 µs against Go's 3.2 ms and Tokio's 2.9 ms |
| Work stealing, a run-next slot, steal-half | Go, Tokio | built: the same design as Go's |
| A poller per worker | Tokio | built: better than Go's single poller |

Mac numbers from bench/tasks:

| Benchmark | Rig | Tokio | Go | Note |
|---|---|---|---|---|
| spawn | 95 ns | 171 ns | 232 ns | |
| chain | 45 ns | 167 ns | 223 ns | |
| yield | 5 ns | 40 ns | 233 ns | |
| hog | 77 µs | 2.9 ms | 3.2 ms | |
| fanout | 85 ms | 69 ms | 70 ms | Rig behind |
| memory per sleeping task | 16.6 KiB | 270 B | 2.9 KiB | Rig far behind |

**On memory, the owner is right.** The 16.6 KiB is one page that each task's separate, guarded stack touches. It is a consequence of Rig's design, not of the hardware: Go and Tokio run on the same 16 KiB pages.
- Go carves 2 KiB stacks out of 32 KiB heap spans, eight to a page.
- Tokio keeps a task as a few hundred bytes of state machine on the heap.
- Swift keeps a waiting task's frames in a small slab: a few hundred bytes to about 2 KiB.
- Erlang keeps a process at about 327 words, roughly 2.6 KiB.

The Go expert estimates, without measuring, that the true cost is about twice what the benchmark reports. Each stack sits in its own mapping about 80 MiB from the next, so every sleeping task likely needs a page table of its own as well: about 16 KiB more on the Mac and 4 KiB on Linux. `ru_maxrss` does not count page tables.

## 2. Rayon against Tokio

**Rayon** is fork-join for computation. `join(a, b)` keeps `b`'s job in `join`'s own frame, with no allocation, and pushes a two-word handle onto its worker's deque. It runs `a`, then pops `b` and runs it as a plain call if nobody stole it: about 10 ns. Its jobs must never block.

**Rayon's splitter** starts with as many pieces as threads and halves them each level. A stolen piece resets the count, so splitting follows demand, not size.

**Tokio** is for I/O. Its tasks are stackless futures on the heap, and they must be `'static` because a future can be leaked.

Rust needs both because neither runtime can do the other's job. Rig removes both reasons:
- A task has a stack, so it may block.
- Yield checks keep a long computation fair.
- A task cannot be leaked, so it can view its caller's data in place.

Rig can therefore be one model for both jobs. What it still lacks from Rayon is its cost: a fork that nobody steals should cost a queue push and nothing more.

## 3. The proposals, by impact

### A. Memory at rest: from 16.6 KiB toward 1–4 KiB

Every expert rejects stackless state machines (Swift-style lowering). Yield checks make nearly every function a point where it may pause, Zig 0.17 has no coroutines, and Zig removed this exact design in 0.11.

A plan in steps, each measured before the next:

1. **Measure first.**
   - the live stack of a task at the moment it parks;
   - the page-table cost (`footprint` on the Mac, `VmPTE` on pup), added to bench/tasks' memory row;
   - add Swift to bench/tasks.
2. **Cheap fixes with no design change.**
   - Move the deadlock walk's frame of about 15 KiB, and the panic paths, onto the worker's own stack, as Go's `systemstack` does.
   - Release the dead pages of the 64 free stacks each worker keeps.
   - Release the pages below the stack pointer of a task parked for a long time.
3. **Small stacks with a proven bound.** Go, Swift, Erlang, and Rayon/Tokio all recommend this.
   - A task starts on a 1–8 KiB stack from a per-worker slab, several to a page, with no guard page between them.
   - The bound is proven on the linked executable: `src/frames.zig`'s real frame sizes, plus the recursion cycles the compiler already finds, as Go's linker proves its NOSPLIT chains fit.
   - A task with unbounded recursion or unknown calls gets a stack-limit compare folded into the recursion check Rig already emits, as Go folds preemption into `stackguard0`. When room runs out, it grows by a new segment that never moves, so every loan into a frame stays valid. One spare segment avoids the hot-split problem.
   - The experts' estimates: 1.5–4.6 KiB per sleeping task on both OSes, below Go's 2.9 KiB at the low end, with switches unchanged.
4. **Actor-shaped connections** (Erlang). A mode in std.net and std.http calls an actor's method when its socket is ready, so an idle connection holds no stack at all. This is the only route the experts see toward Tokio's 270 B, and it needs no compiler change.
5. **Copying a long sleeper's stack out** (disputed; decide on numbers).
   - Rayon/Tokio would copy the live part of a parked task's stack to the heap and back to the same address, for about 1–2 KiB at rest.
   - Go would not: other tasks read and write a parked task's stack (children viewing their parent's frame), each park costs microseconds, and the page tables stay.
   - Only worth considering after step 1 shows how much stack is live at a park.

### B. Rayon's free fork-join behind the same `&`

There is no new syntax and no second API. Three changes:
- **The task record in its maker's frame,** when the `Task` never leaves it. This is a new storage fact, as Swift does for `async let`.
- **An unstarted task runs on its waiter's stack** at `>t`, behind the room check the actor path already uses. Rig's handoff already runs an unstarted task at the wait, but on a stack of its own.
- **A worker takes its own newest task first,** as Rayon's does; thieves keep taking the oldest.

Expected: chain from 45 ns to about 10–15 ns (the expert's estimate).

On top of this, std.par gets Rayon's adaptive splitter, so a nested `par` costs nothing when nobody steals.

The first change touches storage, the second the deadlock checks and loans. Both need a design round that shows each fits CORE.

### C. Throughput

1. **fanout: strip-mine counted loops.**
   - The yield check's counter sits on the chain of adds each turn depends on, about 15–20% per turn, which fits 85 ms against Tokio's 69 ms. The safe build's 69.5 ms row shows the loop can match.
   - The fix: a clean inner loop of 1,024 turns, then one check, as HotSpot does. This is emit-only.
2. **Weight the yield countdown by work, not loop turns** (Erlang). Today a loop whose turns each take 50 µs yields only every 51 ms.
3. **Hand off a stuck worker** (Go, Swift). When a worker is stuck in a blocking foreign call, start a spare one; the 1 ms watcher already exists.

### D. Usability: libraries, no new rules

1. **Supervision vocabulary** (Erlang):
   - a monitor, `~a.on_down()` in `select`;
   - the three restart strategies, with restart kinds set by the function's type;
   - start and stop order taken from drop order;
   - **a bounded default restart limit**, where Rig now restarts forever.
2. **A set's results in the order tasks end** (Swift's `for await` over a group). The name is the owner's.
3. **A main-thread actor** for GUI toolkits (Swift's `@MainActor`).
4. **A cancellation callback for Zig shims,** built on the existing `Waker`.
5. **Observability:** a dump of all tasks on a signal, built from the `Blocked` records; mailbox lengths, stack touched, restarts.
6. **Guarded methods** (an actor call that waits until a condition on the actor's state holds), as a design round. No selective receive, no priorities, no unbounded one-way send.
7. **Errors about crossing cores** that name the path to the part that does not cross, and the fix (from Swift's diagnostics).
8. **Shared read-modify-write cells** (`fetch_min`, `fetch_add`) for a parallel search that wants other workers' results mid-run (Rayon's FAQ). Check what Rig's synchronized types offer, then decide.

### E. A crash frees what it held

A panic abandons the dead frames' memory and a dead actor's value; it does not drop them. This is documented in concurrency.md, "Failure", as the price of having no unwinding. It is not a compiler bug. Erlang frees everything on a crash, so a supervised Rig actor that crashes once a minute leaks its state once a minute.

The fix proposed is a memory region per actor and per isolate. It touches ownership and allocation, so it needs an owner design round. Measure the bytes leaked per crash first.

## 4. What not to take

- Stackless async lowering (Swift, Tokio).
- Unstructured `go` and moving stacks (Go).
- Actors that re-enter at each await (Swift).
- Unbounded mailboxes, selective receive, and hot code loading (Erlang).
- Built-in distribution. Upgrading by handing sockets to a new binary does the same job; any later distribution should be typed calls over `api` shapes.

## 5. The owner's decisions, each with a default

1. **Scope.** Default: all of this is v0.3.1 or later. v0.3.0 is frozen.
2. **Order.** Default: A1 and A2 (measure, cheap fixes), then C1 (strip-mining), then A3 (small stacks), then B (free fork-join), then A4 (actor-shaped connections). Libraries D1 and D2 run in parallel when an agent slot is free.
3. **Design rounds before code.** Default: needed for A3 (bounds and segments), B (storage fact, stack handoff), and E (regions). C1 and A2 are engine or emit changes under the usual gates.
4. **The memory goal.** Default: below Go on the Mac (under 2.9 KiB per sleeping task), and a Tokio-class idle connection through A4. Every step records a row in bench/tasks/PROGRESS.md on the Mac and on pup.
5. **The docs' framing of memory.** Default: concurrency.md and scheduler.md say plainly that the page is Rig's design cost, not the hardware's, when A1 lands.

## The owner's decision (2026-11-04)

The owner approved all five defaults above ("Approve the defaults"), and set three conditions later the same day:
- The Rig session stays in charge of this work and assigns its implementation; the session that ran this review offered to build it.
- The measurements (step A1, with bench/tasks' scaling against Tokio, Rayon, and Go) may start at once, but only where they cannot clobber work in flight.
- Everything else is v0.3.1, started when the Rig session says the work is free to begin.
