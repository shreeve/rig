# Go's concurrency against Rig's: mechanism, memory, usability, speed

Sources: Go 1.27.3 `src/runtime` (paths below are relative to it); Rig
`origin/main` (27010375f). Rig numbers are bench/tasks/PROGRESS.md and
docs/launch/benchmarks.md; nothing was built or timed for this report
except one `bin/rig emit` of the fanout loop. Estimates are marked as such.

## 1. Go's design in brief

**G/M/P.** A G is a goroutine (record plus stack), an M an OS thread, a P a
processor token (GOMAXPROCS of them) that owns a run queue, an mcache, and
a stack cache. An M runs Go code only while it holds a P.

**Run queues and stealing.** Each P has a 256-slot ring (`runtime2.go:805-807`)
and a `runnext` slot (`runtime2.go:820`; `runqput` CASes it, `proc.go:7529-7548`).
`findRunnable` (`proc.go:3404`) takes the global queue every 61st tick for
fairness (`proc.go:3458`), then the local queue, then polls the network
non-blockingly (`proc.go:3510-3511`), then steals half of a victim's ring
(`stealWork` `proc.go:3843`, `runqgrab` `proc.go:7713`, `runqsteal`
`proc.go:7781`), with a bounded number of spinning Ms (`wakep` `proc.go:3227`,
`resetspinning` `proc.go:4036`). Rig's ring of 256, run-next slot, steal-half,
"at most half searching", and every-61-turns poll are the same design, and
`scheduler.md` says so.

**Netpoller.** One process-wide epoll/kqueue. Each fd's `pollDesc` holds
`rg`/`wg` words that are `pdReady`, `pdWait`, or the parked G
(`netpoll.go:54-67,100-101`). It is polled by an M about to go idle,
blocking (`proc.go:3769`), non-blocking in `findRunnable` and `stealWork`
(`proc.go:3511,3828`), and by sysmon every 10 ms (`proc.go:6622`). Rig instead
has a poller per worker plus one sleeping "watcher" that looks at all of
them every 1 ms; Rig's is better for locality (a connection's events wake
its own worker) and Go's is simpler (no watcher needed).

**Syscall handoff.** `entersyscall` (`proc.go:4776`) leaves the P attached
but marked; sysmon's `retake` takes it if the call lasts more than one sysmon
tick, at least 20 µs (`proc.go:6743`), and `handoffp` (`proc.go:3146`) starts
another M on it. `entersyscallblock` (`proc.go:4830`) hands off at once.
So every blocking call, cgo included, costs Go a thread but never a P's
worth of parallelism. Rig routes calls it knows block to its pool and runs
the rest (`rt.io`, a write to a full pipe) on the worker, which then holds
that core (scheduler.md "The boundary").

**Stacks.** A goroutine starts with `stackMin = 2048` bytes
(`stack.go:78`), adapted to the average scanned stack each GC
(`startingStackSize`, `gcComputeStartingStackSize`, `stack.go:1415-1450`).
Small stacks come from a per-order free list carved out of 32 KiB heap
spans (`_StackCacheSize`, `malloc.go:136`; `stackpoolalloc` `stack.go:200-212`;
the per-P cache `stackcacherefill` `stack.go:279`; `stackalloc` `stack.go:344-420`).
They are ordinary heap memory: eight 2 KiB stacks share one 16 KiB page.
Every non-leaf function's prologue compares SP with `g.stackguard0`;
on failure `morestack` → `newstack` (`stack.go:1055`) doubles the size
(`stack.go:1179`, more if the frame needs it, `stack.go:1185-1189`) and
`copystack` (`stack.go:929`) moves it: memmove the used part, then adjust
every pointer into the old range. It finds them exactly: the unwinder walks
every frame and `adjustframe`/`adjustpointers` (`stack.go:701,652`) use the
compiler's per-PC stack maps (a bitvector of pointer slots) and rewrite
each word that lies in `[old.lo, old.hi)` by `delta`; it also fixes saved
frame pointers, `ctxt`, defers, panics, and sudogs (`stack.go:805-878`),
using CAS for channel slots another G may write (`stack.go:661,686`). GC
halves a stack using less than a quarter (`shrinkstack` `stack.go:1286-1330`).
Dead Gs keep a starting-size stack for reuse (`gfput`, `proc.go:5516`).
This only works because Go has exact stack maps and forbids pointers to
the stack from the heap (escape analysis). The linker separately proves
that chains of `NOSPLIT` functions fit the guard (`stack.go:66-67`).

**Preemption.** Cooperative: `preemptone` (`proc.go:6917`) sets
`stackguard0 = stackPreempt` (`stack.go:133`), so the next prologue check
fails and `newstack` yields instead of growing: the preempt test costs
nothing beyond the stack check every function already has. Asynchronous
(since 1.14): sysmon (`proc.go:6537`, sleeping 20 µs doubling to 10 ms,
`proc.go:6550-6557`) preempts a G that has run 10 ms
(`forcePreemptNS` `proc.go:6679`, `retake` `proc.go:6715`) by sending SIGURG
(`signal_unix.go:74`, `preemptM` `:369`); the handler checks the PC is an
async safe point (`isAsyncSafePoint` `preempt.go:390`) and injects a call to
`asyncPreempt` (`preempt.go:305`), which saves every register and continues
on the system stack (`asyncPreempt2` `preempt.go:317`). A preempted G goes to
the global queue (`goschedImpl` `proc.go:4350-4353`).

**Channels/select.** `chansend`/`chanrecv` (`chan.go:176,508`) copy directly
into a parked peer's stack (`sendDirect`/`recvDirect` `chan.go:392,405`);
`selectgo` (`select.go:122`) shuffles the cases (`cheaprandn`,
`select.go:191`) and locks channels in address order (`sellock`, `select.go:34`).

## 2. Memory per sleeping task

### Why Go is 2.9 KiB on a 16 KiB-page Mac

Go's stack is not a mapping; it is a 2 KiB object in a heap span, so the OS
page size does not appear in the per-task cost. 2.9 KiB ≈ 2 KiB stack +
the `g` (~0.4-0.5 KiB) + the sleep timer and closure. Contiguous spans
also share page tables. Tokio's 270 B is a stackless future: the state
machine holds exactly the live locals across `.await`.

### Why Rig is 16.6 KiB, and probably more than that

`takeStack` (`src/sched.zig:3351-3380`) gives every task its own span of
`task_guard + 64 MiB + one page` (`rt.task_stack_size`, `rt.task_guard`,
`src/runtime.zig:7178-7179`; at least 16 MiB of guard). A sleeping task
touches the top page: 16 KiB on the Mac, 4 KiB on Linux, plus a record
of ~0.5-1 KiB. That is the 16.6 / 4.5-5.2 KiB in PROGRESS.md.

**Hidden cost (estimate, unmeasured):** the bench reads `ru_maxrss`
(`bench/tasks/bench-tasks:100-123`), which does not count page tables.
Stacks are ~80 MiB apart, so each sleeping task's one touched page sits
in a last-level page table of its own: on arm64 with 16 KiB granules an
L3 table is 16 KiB and spans 32 MiB; on x86-64 a PTE page is 4 KiB and
spans 2 MiB. So the kernel likely spends a further ~16 KiB (Mac) and
~4 KiB (Linux) per task: true cost ~33 KiB and ~9 KiB. Check it with
`VmPTE` in `/proc/PID/status` during `tasks many` on pup, and `footprint`
or `vmmap --summary` on the Mac. Only packing stacks closer than the
table span removes this; copying or `madvise` does not free tables.

**Second leak of residency:** `releaseStack` (`sched.zig:3384-3391`) keeps up
to 64 stacks per worker with every page their last fiber touched; a burst
of deep tasks leaves 64 × high-water resident per worker. Go halves
stacks at GC (`stack.go:1286`).

### What Rig can take, given stacks never move

Rig cannot copy-and-relocate: loans are raw pointers into stacks, emitted
Zig has no stack maps, and a child task views its parent's frames in
place. But the part of Go that makes memory small is not the copying; it
is *stacks as small heap objects sized to need*. Copying is only Go's
answer to "need is unknown". Rig can know need far more often.

**A. Bounded stacks from a slab (recommended).** For each task entry
function, compute the deepest path of its call graph weighted by real
frame sizes. Rig already has both halves: the frames of the linked binary
(`src/frames.zig`, read from prologues) and the program's cycles
(`inlining.Pass.cutCycles`). The proof must run on the binary's call graph
(direct `bl`/`call` targets), so Zig std and the runtime are included;
indirect calls (allocator vtables, `std.Io`, closures, `fun` values, API
dispatch) take the max over the address-taken set, as a conservative
points-to. This is the analysis Go's linker already does for NOSPLIT
chains. A task whose graph is acyclic, fully resolved, and under a cap
(say 64 KiB) gets a stack of that bound, rounded to a size class, from a
per-worker slab, Go-style (per-worker cache, refill from 32-256 KiB chunks).
Everything else (recursion, unresolved indirect calls, big frames) keeps
today's 64 MiB mapping.
- Soundness: no guard page is possible inside a slab (a guard must be a
  whole page, 16 KiB on the Mac), so the bound must be exact; it is,
  if it is read from the binary. Keep guards in `RIG_SANITIZE=1` and debug
  builds (each slab stack on its own mapping) to catch an analysis bug.
  Signal handlers already run on the alternate stack (`rt.AltStack`).
- Needed first: move rare deep runtime paths off the task's stack, onto
  the worker's own (Go's `systemstack`/`mcall`, `stubs.go:47,67`): the
  deadlock walk (`walkFrom`, ~15 KiB), panic reports, formatting of
  diagnostics. Otherwise every waiting task's bound includes 15 KiB.
- Estimate for the bench's sleeper (entry + `time.sleep` + `sched.block`
  under a page + switch): 1-4 KiB class + ~0.6 KiB record = **~1.6-4.6 KiB
  per task on both OSes, page tables ~0**; on par with Go's 2.9 KiB.
- Bonus: the same proof is what `scheduler.md` ("Cheap until it runs")
  says Rig lacks to run a not-started task on its waiter's own stack,
  so `chain`/`spawn` get faster too.

**B. Segmented stacks at cycle points (recommended as A's fallback).**
Segments do not move, so they fit Rig's loans; Go and Rust dropped them
for the hot split (a call at a segment boundary in a loop allocating and
freeing a segment each time). Rig can make them cheap:
- Check only where Rig already checks: the feedback-vertex-set functions
  that read `sched.waiting`. Between two such checks a task makes at most
  one acyclic chain (scheduler.md "Recursion"), whose depth the post-link
  analysis bounds. So each checking function tests `sp - bound < limit`.
- Fold the yield flag into the limit exactly as Go folds preemption into
  `stackguard0` (`proc.go:6936-6939`): to ask a task to yield, the
  scheduler sets its limit to "always fails". One compare does both jobs,
  so the recursion check costs what it costs today.
- On failure, call the function on a new segment (Rig already has
  `rig.onOwnStack`); on return keep the segment as a spare (hysteresis),
  so a hot split costs a few instructions per crossing, not an
  allocation. Free spares at park or when the task ends.
- Memory: a recursive task starts at a slab first segment (8-16 KiB class)
  and grows by 64 KiB+ segments; sleeping cost ~2-5 KiB if shallow at
  rest. Unresolved indirect calls get the same check in the callee's
  prologue (address-taken functions only).
With A and B together the 64 MiB mapping survives only for frames over the
cap and code the analysis cannot read.

**C. Copy at rest to the same address (not recommended as the main fix).**
At a long park, copy the used bytes (often < 1 KiB) to the heap and
`madvise` the page away; copy back before resuming. Addresses never change,
so loans stay valid, but only if nothing touches the stack while parked,
and much does: children view the parent's frames; actor answers, pool
calls and failure fields are written into the waiter's slots
(`tasks.zig` `waitInto`/`ErrSlot`, `sched.poolCall`). It costs two system
calls and a fault per park (~2-5 µs, against a 45 ns chain), and leaves
the page table. Estimate: ~1-3 KiB RSS but ~17 KiB/5 KiB true cost.
Its cheap cousin is worth doing: **release the dead part below SP**
(`madvise` everything below the top page) when a stack goes back to the
free list after a deep run, and at a long park of a big-stack task; no
copy, no exclusions, since memory below SP is dead.

## 3. Usability

Go gets right: one kind of function (no async colouring); `go f()` is
two characters; channels and `select` are in the language; the runtime
hides blocking syscalls; tooling: goroutine dump on SIGQUIT, `pprof`,
`runtime/trace`, the race detector, "all goroutines are asleep".
Go gets wrong: `go` returns nothing, so results and errors travel by
hand-built channels/WaitGroups/errgroup; no structured lifetime, so a G
blocked on a forgotten channel leaks forever; cancellation is a `context`
argument threaded by hand and ignored by default; data races are found
only at run time under `-race` (or a fatal concurrent map write); a panic
in any goroutine kills the process; nil channels block forever; `select`
is random (`select.go:191`), with no priority.

Rig keeps Go's one kind of function (stackful fibers) and its short start
(`f(x)&`), and fixes each wrong: `Task[T]` carries the value and failure,
dropping cancels and waits (no leaks), cancel and deadlines are built in
and reach every waiting point, the checker rules out races, a task views
its caller's data in place without copies or counts, `task.isolate`
stops a panic. Rig's costs are more concepts (Task, Tasks, local tasks,
actors, isolates); keep them few. Worth taking from Go: an all-tasks dump
on SIGQUIT/`RIG_DUMP` (each task's stack and what it waits on; the
deadlock walk's `Blocked` records already exist), and a trace like
`runtime/trace` beyond `RIG_SCHED_STATS`.

## 4. Performance

**fanout (Rig 78-88 ms, Go 70, Tokio 69 on the Mac; pup 108/93/103).**
`bench/tasks/README.md` calls the gap "the compiled loop's", but no record
backs it, and the emitted Zig (`bin/rig emit`) is Go's loop plus
`rig.turn` in the continue expression: `total = rig.rem(total + i*7, 1000003)`,
with `rig.rem`'s `b == -1` folded away at compile time. Tokio, also LLVM,
matches Go on the Mac, so LLVM's instruction selection is not the cause
there. Candidates, to measure in this order:
1. One task, one worker, Rig against `GOMAXPROCS=1` Go: settles loop or
   scheduling.
2. `rig.tick_turns` ×16: the check calls `sched.tick` through
   `callKeeping` (saving every vector register) once per ~2.5-3.5 µs of
   this loop; estimate 1-4%.
3. Loop placement: AGENTS.md notes code moves shift Apple loops 5-7%.
4. Spread: each task's own elapsed and worker (`RIG_SCHED_STATS=1`). The
   run's time is its slowest task; on a P/E-core part, Go's 10 ms
   preemption rotates Gs through the global queue (`proc.go:4350-4353`).
   Tokio does not rotate and still matches, so this is the weakest suspect
   unless Rig's worker threads get a different QoS.

**Yield checks against async preemption.** The checks win where they
apply: `hog` 77 µs against 3.2 ms, `yield` 5 ns against 233 ns, no
signals, no safe-point tables. Go's 10 ms slice exists because a signal
costs microseconds and must hit a safe point. The checks' gaps: Zig shims,
C, and long std kernels written in Zig have no checks; and a recursive
check does not service timers. A Go-style backstop (a monitor that, after
~10 ms without a tick, signals the worker and injects a call that saves
every register and yields, only at PCs in Rig-emitted code) would close
them at no cost to checked code. Low priority.

## 5. Ranked recommendations

1. **Measure the hidden page-table cost** (`VmPTE`, `footprint`) and add it
   to bench/tasks' memory row. Likely doubles the Mac figure. Cheap.
2. **Bounded stacks from a per-worker slab**, proved on the linked
   binary's call graph (frames.zig + cycles), fallback to 64 MiB. Move
   the deadlock walk and panic paths onto the worker's stack first.
   Estimate 1.6-4.6 KiB per sleeping task on both OSes, no page tables;
   enables running not-started tasks on the waiter's stack.
3. **Fold the recursion yield check into a stack-limit check** (Go's
   `stackguard0` trick) and use it for **segmented growth at cycle points**
   with a spare-segment cache: shrinks the fallback for recursive tasks
   at no added cost per call.
4. **Release dead stack pages**: below the top page when a stack returns
   to the free list after a deep run, and at long parks of big-stack tasks.
5. **Diagnose fanout** by the four measurements above before changing code.
6. **Syscall handoff**: a monitor that, when a worker is stuck in an
   unannounced blocking call for >20 µs-1 ms, starts a spare worker
   thread to keep every core busy (Go's `retake`/`handoffp`).
7. **All-tasks dump** on a signal, from the existing `Blocked` records.
8. **Async preemption backstop** for code without checks; keep the
   compiler's yield checks as the primary mechanism.
Not to take: unstructured `go`, moving stacks, a single global netpoller.
