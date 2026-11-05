# Swift concurrency against Rig's: mechanism, memory, usability

Read for this: Rig `origin/main` docs/design/concurrency.md,
docs/internals/scheduler.md, SPEC.md §18 (sets of tasks, crossing),
std/task.rig, std/par.rig, src/frames.zig, src/sema.zig (`reach_factor`,
`taskGuard`), bench/tasks/PROGRESS.md. Swift: the runtime headers on
swiftlang/swift `main` (include/swift/ABI/Task.h, MetadataValues.h,
stdlib/public/Concurrency/TaskPrivate.h) and what I know of the runtime
and the LLVM lowering. Nothing was built or timed. Every Swift time
below is an estimate to be measured, not a result.

## 1. How Swift runs a task

**Async functions are split.** An `async` function uses its own
calling convention (`swiftasynccc`, with guaranteed tail calls). LLVM's
CoroSplit pass (the "async" coroutine lowering, `llvm.coro.id.async`)
cuts the function at every `await` into *partial functions*. The values
live across a suspension point, and every local whose address is taken
across one, go into the function's *async context*; everything else
stays in registers or on the thread's stack, as in any function.

- The caller allocates the callee's context. An async function's symbol
  is an `AsyncFunctionPointer`: a relative address and the context size,
  so the caller can `swift_task_alloc` the right number of bytes before
  the call.
- A context starts with `Parent` (the caller's context) and
  `ResumeParent` (the partial function to continue the caller in).
  Returning is a tail call of `ResumeParent(Parent)`; the callee's
  context is freed first.
- So the chain of contexts *is* the task's stack, kept in the heap, and
  only async functions have a frame in it. A synchronous callee runs on
  the thread's stack and is gone before any suspension, because a sync
  function cannot suspend. This is what coloring buys: the compiler
  knows, from the type, which frames can be alive at a suspension.

**The task allocator is a segmented stack.** `TaskAllocator` is a
`StackAllocator` (LIFO bump allocation in slabs). `SlabCapacity` is
`1024 - 8 - slabHeaderSize()`, so slabs are about 1 KiB, malloc'd as
needed; freeing is LIFO, a pointer decrement. A new task's first slab
can be carved from the tail of the task's own allocation, and an
`async let` child is allocated *in its parent's task allocator*, with a
640-byte preallocated buffer (`NumWords_AsyncLet = 80`, "640 bytes ought
to be enough for anyone") holding the child task and its first slab, so
a small `async let` costs no malloc at all. Its refcount is marked
immortal for that reason.

**The task object.** `Job` is 8 words (64 B, including the 16 B heap
header: scheduler links, flags, id, voucher, run/resume function).
`AsyncTask` adds `ResumeContext`, a reserved word, and
`OpaquePrivateStorage` (the exclusivity access set, the atomic
`ActiveTaskStatus` of 16 B, the task allocator's 2 words and 4 bytes,
the task-local chain head of one word, id, base priority, dependency
record, a recursive mutex). That is roughly 200 B, plus optional
fragments placed before it: a future fragment holding the result (sized
by `T`), a child fragment, a group fragment. A task group is 32 words, a
default actor 12 words beyond the heap header.

**Suspension.** At an `await` that really suspends (the callee is on
another executor, a continuation is not yet resumed, a sleep), the
partial function stores the next partial function and its context in
`task->ResumeTask` / `ResumeContext`, hands the task to whatever will
wake it, and *returns* to the executor's drain loop. The thread's stack
is then empty of the task. Resuming is one indirect call of
`ResumeTask(ResumeContext)`. Unlike Rust's futures, no chain of `poll`
calls descends again: the innermost continuation is called directly,
and each frame continues its parent by a tail call. An `await` on a
call that does not suspend costs a context allocation, a tail call, and
a tail call back: a few nanoseconds more than a sync call, and the loss
of inlining across the split (estimate).

**Executors.** Every job runs on an executor. The global concurrent
executor on Darwin is libdispatch's *cooperative* pool: one thread per
CPU per QoS band, no overcommit. Actors are serial executors: a default
actor has a lock-free job queue and, when it has work, a processing job
on the global pool that drains it. `swift_task_switch` to an actor that
is idle runs the job *inline on the current thread* (take the actor,
run, give it back), the same idea as Rig's idle path. Custom executors
(SE-0392) and task executor preference (SE-0417) let a program run tasks
on, say, a NIO event loop. Swift 6.2 made `nonisolated async` functions
run on the caller's executor by default (`nonisolated(nonsending)`,
SE-0461; `@concurrent` asks for the pool), which removed many needless
hops.

**The no-blocking rule.** The pool has exactly one thread per core, so
a thread blocked on a semaphore, a lock held across an await, a
synchronous read, or `DispatchQueue.sync` onto work that needs the pool
takes a core away; enough of them deadlock the pool. In exchange there
is no thread explosion, which old GCD code suffered when every blocked
block spawned a thread. Swift offers no blocking pool: the rule is
"don't" (with `LIBDISPATCH_COOPERATIVE_POOL_STRICT=1` to find
violators), and blocking work goes to a separate `DispatchQueue` or
thread the program manages, bridged with a continuation.

**Priority inversion.** Tasks have priorities (QoS). A higher-priority
task awaiting a lower one's `value` or an `async let` *escalates* it
(the status word records the max priority; the job is re-enqueued at
the higher QoS, and Dispatch overrides the thread). An actor that has a
high-priority job queued escalates its drainer. This is the price of
priorities; without them there is no inversion to handle.

**What it costs, roughly (estimates; to measure).** Spawn of a `Task {}`
on the global executor is a malloc of the task plus a Dispatch enqueue,
likely several hundred ns to around 1 µs; a hop to an actor that is
busy is an enqueue and a later dequeue on possibly another thread,
hundreds of ns; a hop to an idle actor is tens of ns. A suspended
task's memory is its task object, its result fragment, and the
contexts on its chain: a few hundred bytes for a shallow sleeper, a
couple of KiB with a slab or two. Rig's 95 ns spawn, 45 ns chain, and
5 ns yield are very likely ahead on time; Swift is very likely ahead
on memory by an order of magnitude.

## 2. The memory question

Rig's 16.6 KiB per sleeping task on the Mac is one 16 KiB page of stack
plus a ~0.6 KiB record; on Linux the same design gives 4.5 KiB. The
floor is the *page*, not Rig's frames: any design where each task has
its own guarded, page-committed stack pays at least one page. Swift
pays per byte because (a) only frames that can be alive at a suspension
are kept, (b) they are kept in 1 KiB slabs, not pages, and (c) the
contexts hold only what is live across the suspension.

There are three ways for Rig to get there. They differ in what they
break.

### A. Stackless lowering without coloring (Swift's design, inferred)

The compiler sees the whole program, so it can compute the set of
functions that *may wait* (the transitive callers of every waiting
point: I/O, sleep, `>t`, an actor call, a channel operation,
`task.check`) and lower exactly those as resumable functions with heap
frames, with no mark in the source. Every function outside the set
stays a plain Zig function on the worker's stack.

What it needs and what it breaks:

- **Yield checks.** Rig puts a yield check in every outer loop and on
  every recursive cycle of a program that makes tasks. A yield check is a
  suspension point, so nearly every function with a loop would join the
  may-wait set, and the program would become whole-program CPS. The way
  out is *stack promotion*: a yield check inside a plain callee, which
  has frames on the worker's stack, detaches the worker's stack and
  gives it to the task as its stack (the task becomes a fiber until
  those frames return), and the worker takes a fresh stack. Stacks never
  move, so views into those frames stay valid. That works, but it is a
  second mechanism beside the first.
- **Loans into frames.** Fine, as in Swift: heap frames come from a
  LIFO slab and never move (Rust needs `Pin` only because its futures
  are values that move). Every local lent across a waiting point, and
  every local a child task views (`score(?d)&`), must live in the frame,
  which is a storage fact: `src/storage.zig` decides it once, and emit
  reads it. This fits "one classifier per fact".
- **Recursion.** Fine: each call allocates a frame from the slab, so
  recursion through a waiting function needs no big stack at all.
- **Indirect calls.** A function value or closure that may hold a
  waiting function must be called with the resumable convention. Either
  every function of that signature whose address is taken gets a
  resumable entry (code size), or the function type carries an inferred
  may-wait bit, which is coloring hidden in types and leaks into errors
  ("cannot store a waiting closure here").
- **FFI and Zig shims.** Zig and C code cannot suspend. Every runtime
  wait written in Zig (net, file, channel, sched) must be rewritten in
  the resumable form, and a Rig callback that waits, called from C,
  must run on a fiber anyway.
- **Zig.** Zig 0.17 has no stackless coroutines (async was removed in
  0.11, and std.Io's stackless backend is not built), so Rig would emit
  each frame as a Zig struct and each function as a `switch` on its
  state, the way Rust lowers generators in MIR, with `@call(.always_tail,
  ...)` for continuations. LLVM optimizes such code less well than
  straight-line code: values across waits go through memory, and calls
  of waiting functions do not inline unless Rig inlines them first.
- **Costs.** Switch: about as cheap as a fiber switch (one indirect
  call; no callee-saved registers to save). A call of a waiting function:
  a slab bump and a tail call, a few ns. Code size: the may-wait set's
  functions roughly double where both forms are needed (indirect
  calls). Debugging and panic traces need a walk of the context chain.
- **Gain.** A sleeping task would hold its record and the live state of
  its chain: likely 0.3 to 2 KiB, Swift's range.

This is the largest change Rig could make to its engine, touching emit,
storage, the runtime, and std's shims, for one row (memory) where Rig is
already ahead everywhere else. Not recommended first.

### B. Small, non-moving, growable stacks (recommended)

Swift's task allocator is a segmented stack that holds only async
frames. Rig can have a segmented stack that holds all frames, checked
only where it must be, and keep fibers, the 5 ns switch, and every
loan rule.

- **Small first segments.** A task starts on a stack carved from a
  per-worker slab in size classes (1, 2, 4, 8 KiB…), several to a 16 KiB
  page, with no guard page between them.
- **Checks where depth is unknown.** A guard page is what makes a big
  stack safe without checks; a small one needs a check before any call
  that could pass its end. Rig already has the points: every recursive
  cycle passes a function picked by `inlining.Pass.cutCycles`, which
  already reads `sched.waiting` on entry. Add one compare of the stack
  pointer against the segment's limit there, and before each indirect
  call and each call into Zig whose depth is unknown. Between two
  checks a task makes at most one chain of calls that repeats no
  function, and that chain's depth is bounded by the frames on it.
- **Growing.** When a check finds too little room, the call runs on a
  new segment: a trampoline switches the stack pointer to it (Rig's
  `switchTo` already does this), calls, and switches back. Existing
  frames never move, so every view into them stays valid. To avoid
  Go's old "hot split" (a call at the boundary in a loop allocating and
  freeing a segment each turn), the task keeps its last freed segment
  until it parks or ends.
- **Bounds.** The threshold at each check is the deepest acyclic chain
  below it. Rig already bounds every frame it emits (`reach_factor`
  times its reach) and already trusts that bound for memory safety
  (the 16 MiB guard is sized from it, and `test/cli/frame_reach.sh`
  checks it against what Zig reserves). `src/frames.zig` already reads
  every function's real frame from the executable; adding direct call
  edges from the same machine code would let `rig build` verify each
  threshold against the binary and fall back, for any function it
  cannot verify, to today's 64 MiB stack.
- **Exact fit.** A task whose entry's call tree is bounded and acyclic
  (no recursion, no unknown indirect call) gets one segment of exactly
  its bound and never checks. That bound also unlocks two things the
  docs already want: running a task on its waiter's stack ("safe only
  for a task whose stack use is proven to fit"), and the idle actor
  path's "a quarter of the stack left" rule, which becomes exact.
- **The runtime's frames.** At a park the stack holds the chain to the
  wait plus the runtime's park path. `sched.block` reserves under a
  page; the deadlock walk (`walkFrom`, ~15 KiB) must run on the
  worker's own stack, switched to before the walk, so it does not size
  every task's segment.
- **Cost.** A compare and a branch at checks that already exist, plus
  one at indirect and unknown calls; nothing on the switch. Memory at
  rest: the frames on the chain (full frames, not only the values live
  across the wait, so likely 2 to 4 times Swift's contexts) plus the
  record. A guess for bench/tasks' sleeper: 1.5 to 3 KiB on the Mac,
  against 16.6 KiB today, Go's 2.9 KiB, and Tokio's 270 B.
- **What it breaks.** Nothing in the language. Debug backtraces must
  follow the trampoline frame (it saves the frame pointer, so the chain
  links). x86_64's 128-byte red zone needs margin in each threshold. A
  frame larger than any segment (Rig accepts frames up to 13 MiB) gets
  a segment of its own at its call's check.

The record can shrink too: Rig's ~600 B against Swift's ~200 B task
object.

### C. Give pages back when a task parks long (a stopgap)

A task's stack keeps every page it ever touched. A worker could
`madvise` (`MADV_FREE_REUSABLE` on macOS, `MADV_DONTNEED` on Linux) the
pages below a long-parked task's stack pointer: a system call per park,
so only for parks past a few milliseconds, swept lazily by an idle
worker. It helps a handler that went deep and then waits; it does not
break the one-page floor on the Mac. Worth it only if B is far off.

## 3. Usability

**Actors.** Swift's actors are reentrant at every `await` (SE-0306
chose reentrancy to avoid deadlocks): while a method waits, other
messages run, so state checked before an `await` may be false after it.
The canonical bug (check a balance, `await` a call, debit) is the most
cited pitfall of Swift concurrency, and the fix is manual: re-check
after every await, or keep a task in the actor's state to serialize.
Rig's actors run each method to its end, so a method's invariant holds
across its waits, and a cycle of waiting calls is caught at the call
that closes it and panics naming it. Rig's choice is the better default:
a deadlock is found and reported; a reentrancy race is silent. The cost
is throughput when a method waits on slow I/O while holding the actor;
the pattern is to start the slow part as a task outside the actor and
send its result back as a second message. That pattern deserves a
paragraph in the docs. Rig also orders messages from one sender, which
Swift does not promise for `Task {}` enqueues.

**Sendable and regions against send/sync facts.** Swift 6 needs
`Sendable` conformances (inferred only for non-public value types),
`@unchecked Sendable` to opt out, `sending` parameters (SE-0430), and
region-based isolation (SE-0414), which lets a non-Sendable value cross
when its region is provably disconnected. The Swift 6 migration showed
the cost: annotations on every public type, and errors that name
regions and isolation domains the programmer never wrote. Rig dissolves
most of this. Ownership gives what regions approximate: a moved value
(`<x`) is disconnected by construction, so `sending` is just a move;
facts are derived for every type, with no conformances; a task views
its caller's data in place because it cannot outlive it, where Swift
needs `Sendable` captures for any `Task {}`. What Rig should copy is
the diagnostics work Swift had to do: each crossing error should name
the path to the part that does not cross (`List[*Node]`: `*Node` is
counted, not synchronized) and the fix (pass `<x`, `+h` of a `*Cell`,
an actor, a copy).

**`async let` and task groups against `&` and `Tasks`.** `async let`
is a structured child that is implicitly canceled and awaited at scope
end if not awaited: the same rule as Rig's drop of a task. Rig's `&`
is more general (bind it, add it to a set, return it with `from`) and
needs no keyword. Task groups are closure-scoped
(`withThrowingTaskGroup { group in ... }`), give results in completion
order (`for try await r in group`, `next()`), and have discarding
groups (SE-0381) for servers, the counterpart of `Tasks[Void]`. Rig's
`>ts` gives results in the order added and `<ts.wait_first()` the
first success; it has no way to take results *as they end*, which a
crawler, a pipeline, or a "first N of M" needs. That is the one gap.

**Cancellation.** Both are cooperative and sticky. Swift's is a flag:
`Task.isCancelled`, `try Task.checkCancellation()`, and `Task.sleep`
throwing `CancellationError`; much code never checks, and nothing makes
it. Dropping an unstructured `Task {}`'s handle does not cancel it,
which is Swift's (and Tokio's) orphan problem; Rig's drop cancels and
waits. Rig is stronger: cancellation is an ordinary error, in the set,
at every fallible waiting point, and only fallible tasks can be
canceled, so the type says it. Swift has one tool Rig's library writers
need: `withTaskCancellationHandler`, a callback run *at once* on
cancel, so a wait in foreign code (a URLSession, a C library) can be
woken. Rig has this inside the runtime (`Waker`, `rt.wakeThread`), not
as an API a Zig shim can use. A cancellation shield is pitched for
Swift and planned for Rig (decision 6); neither has it.

**Task-locals.** `@TaskLocal` values are bound with
`$value.withValue(v) { ... }`, inherited by structured children through
a linked chain (no copy), copied by `Task {}`, and not by detached
tasks. They carry trace ids, loggers, request ids. They are ambient
state, which Rig's "effects stay visible" rejects, and Rig already
inherits the one ambient value that matters to correctness, a task's
deadline, through `time.within`. Recommend not adding them, unless
tracing (an `std.trace` span) shows the need; then one typed, read-only
context, never a general mechanism.

**Main actor and UI.** `@MainActor` is a global actor: types and
functions are isolated to the main thread, checked at compile time, and
calls from elsewhere hop with `await`. Swift 6.2 lets an app module
default every declaration to `@MainActor` (SE-0466). Rig's local tasks
give GUI code `*T`, `Cell`, and `Signal` with `&`, pinned to the thread
that makes them, but nothing says "this runs on the OS main thread",
which Cocoa and most toolkits require. An actor homed on the main
thread (worker 0, pinned; calls from other cores are messages) would
cover it with no new mechanism, if `main` itself is pinned there.

**Blocking.** Swift's no-blocking rule is its pool's weak point, and
it gives the programmer no blocking pool. Rig is ahead: std's file
calls go to a blocking pool that grows when calls wait, as Go's does.
The remaining hole is the same as Swift's: a foreign call that blocks
(the docs note "a write to a full pipe holds its worker") takes a core.
Go's answer is a monitor that notices a thread stuck in a system call
and hands its work to a spare thread; Rig's watcher, which already
looks at every worker each millisecond, could notice a worker that has
not switched in, say, 10 ms while work waits, and start a spare.

**Priorities.** Rig has none, so it has no inversion to escalate. Keep
it so until a latency-sensitive program shows the need.

## 4. Recommendations, ranked

1. **Small, growable, non-moving stacks (2.B).** First segments of 1 to
   8 KiB from a slab, a stack-limit compare at the recursion checks that
   exist and at indirect and unknown calls, segments added by
   trampoline and never moved, exact-fit segments for bounded tasks,
   thresholds verified against the binary by `src/frames.zig` with a
   fallback to today's stacks. Expected: memory per sleeping task on
   the Mac from 16.6 KiB to about 1.5 to 3 KiB (below Go), switch time
   unchanged, no language change. Zig ceiling first: a hand-written Zig
   bench/tasks `memory` and `chain` on 2 KiB segments.
2. **A task's record (and first segment) in its maker's frame**, as
   Swift's `async let` does (640 B preallocated in the parent): for a
   task bound to a local and waited for or dropped in scope (`t =
   f()&; ...; >t`, `task.all`), no allocation at spawn. With 1, the
   bounded task can also run on its waiter's stack. Lowers `spawn` and
   `chain`.
3. **Measure Swift in bench/tasks on the Mac** (spawn, chain, yield,
   memory, actor round trip). It is the Mac's native competitor, and its
   memory row is the one Rig's claims must face.
4. **Results as they end from a set:** a `Tasks` method or iteration
   that gives each result in completion order (Swift's `next()` / `for
   await`). Naming is the owner's.
5. **Keep run-to-end actors.** Do not copy Swift's reentrancy. Document
   the "start the slow part outside the actor" pattern.
6. **A cancellation callback for Zig shims** (Swift's
   `withTaskCancellationHandler`): let `extern zig` code register a wake
   that runs at once on cancel or deadline, using the `Waker` the runtime
   already has.
7. **A spare worker for a worker stuck in a foreign call,** from the
   existing 1 ms watcher.
8. **A main-thread actor** for GUI toolkits and other main-thread-only
   APIs.
9. **Crossing diagnostics that name the path** to the part that does not
   cross, and the fix.
10. **Not now:** stackless lowering (2.A; only if 1 falls short, and
    then with stack promotion), task-locals, priorities and escalation.
