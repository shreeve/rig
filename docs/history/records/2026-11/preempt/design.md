# Preemption by signal: design and prototype (2026-11-04)

The owner approved a design round, Zig ceiling first, for replacing the
polled yield checks (docs/internals/scheduler.md, "Yield checks") with
asynchronous preemption, as Go 1.14 does. The checks cost Trig 0.6 to
3.6% (pup, PGO; Trig's corrected numbers are pending). This record is
the design, each hazard and what settles it, and the prototype on branch
`preempt`, behind `RIG_PREEMPT=signal`, off by default.

## Mechanism

1. **Build option.** `RIG_PREEMPT=signal` at build time, the pattern of
   `RIG_SANITIZE`, for `rig run`, `rig build`, and `rig test`. For a
   program that makes tasks, `bin/rig` writes `pub const __rig_preempt =
   true;` in the root, and emit places every function it writes for Rig
   source, closures' `__rig_invoke` among them, in one section
   (`linksection(rig.preempt_section)`: `rig_text` on ELF,
   `__TEXT,__rig_text` on Mach-O). Unset, nothing differs.
2. **No checks.** Where the build has preemption (`sched.preempt_built`:
   Linux x86-64 with LLVM's backend, so far), `rt.turn` and `rt.tickCall`
   return at compile time. The emitted Zig still names them, so a target
   without preemption keeps its checks unchanged; with preemption, the
   loop counters are dead locals and LLVM deletes them. The spin loop
   of the fairness case is a `lea`/`cmp`/`jne` loop with no counter.
3. **The monitor.** A thread started with the workers. Every period (1
   ms or a quarter of the slice while any worker runs, doubling to 10 ms
   while none does) it reads each worker's count of fibers started
   (`Preempt.runs`) and whether it runs one. A worker that has run one
   fiber for a slice (10 ms, as Go; `RIG_PREEMPT_SLICE_US` for the
   prototype) while work waits (its own queues, the global queue, or
   `sched.waiting`), or that holds a due timer or a poller with events,
   gets SIGURG (`tgkill`, or `pthread_kill` with libc), again every
   period until it switches.
4. **The handler** (`onPreempt`, on the worker's alternate signal
   stack, `SA_ONSTACK | SA_RESTART`) declines unless the thread is a
   worker running a fiber, the interrupted program counter is in the
   section, the worker holds no lock (`Preempt.no_preempt`), the stack
   has 32 KiB above its guard, and the handler is not itself on the
   fiber's stack. Then it writes the interrupted PC 136 bytes below the
   stack pointer (past the 128-byte red zone), points the stack pointer
   there, and the PC at the trampoline.
5. **The trampoline** (`preemptEntry`, naked): `pushfq`, a frame, the
   nine integer registers a call may change, `cld`, a 64-byte-aligned
   area for `xsave64` of x87, SSE, and the AVX and AVX-512 state the
   target has (components 0, 1, 2, 5, 6, 7; `fxsave64` without XSAVE),
   with its header zeroed as `xrstor` needs; it calls `preempted`, then
   restores all of it and returns with `retq $128`, which pops the PC
   and steps back over the red zone. The callee-saved registers are the
   callee's and `switchTo`'s to keep.
6. **`preempted`** does what `tick` did: `serviceBusy` (due timers, the
   poller), then, if work waits for this worker or (`waiting`) for a
   busy one, which it steals as `claimWaiting` does (`stealWaiting`), it
   puts the fiber back in line as `yield` does and switches; a pinned
   fiber is held instead (below).

## Hazards and their answers

**TLS and the worker.** Compiled code may keep a thread-local's
address, or the worker the scheduler's `me` gave, in a register; a
fiber stopped there and resumed on another thread would use the first
thread's. The first prototype held a preempted fiber on its worker
until it ran again, and `bench/tasks` `fanout` (10 spinning tasks on 4
workers) took 2.1 times as long: the held fibers could not be stolen,
and at the end one worker ran two or three in turn while the others had
nothing. So the program's own code is kept free of both, and a
preempted fiber goes back in line as one that yields, where any worker
may steal it:

- No thread-local: the only one the section read (11 reads of `%fs` in
  the fairness case) was `rt.task()`'s fallback outside every fiber,
  which under preemption is a call (`threadTask`). `alloc`'s heap and
  token, and `sched.me`, were calls already.
- No worker: `sched.me` panics when its return address is in the
  section (`mustNotBeInCode`), so scheduler code that reads its worker
  and is inlined into the program's panics the first time it runs,
  before a signal could stop it holding the worker. The check found
  `stop` (through `task.check`'s `yield`) inlined into `bench/tasks`
  in `--release=fast`. So under preemption the scheduler's entry
  points that read their worker are calls never inlined: `current`,
  `stop`, `wake`, `wakeLast`, `pinHere`, `giveStack`, `takeBlock`,
  `giveBlock`, `register`, `spendBudget`, `runApart`, and
  `Header.waitEnd`, each a compile-time alias (`wake = if (preempt)
  wakeApart else wakeIn`), so without preemption the code is as before.
  The rest of the 37 calls of `me` are inside these or the worker's
  own loop, or in the actors' mailbox (`first`, `local`, `send`,
  `receive`, `hop`), reached through calls; the run-time check covers
  the paths a program takes, and the section audit (test plan 4) would
  cover every path.

**Local tasks.** A pinned (local) fiber shares counts that are not
atomic with the other pinned fibers of its worker. A preempted pinned
fiber is held in `Preempt.held`, which the worker runs before any other
pinned fiber (`popPinned`), and a pinned fiber in the "run next" slot
waits in the pinned queue meanwhile. So a preemption lets the worker's
other work run, never a sibling that could see a count half-changed;
siblings wait for the fiber's next waiting point. Today a spinning
local task yields to its siblings every 1,024 turns; under preemption it
does not (question 2).

**No-preempt regions.** The section is a positive list: only the code
emit writes for Rig source, and whatever the optimizer inlines into it.
The scheduler, the allocator (`alloc`/`free` are `noinline`), Zig's
library, and C are outside it, so a signal there declines. What the
optimizer inlines into Rig code is the risk, and the audit of the
fairness case's section (objdump `-l`, every line of sched.zig,
tasks.zig, alloc.zig, net.zig in it) found scheduler code there:
`SpinLock.lock` (the pool's, in `finish`), `beginWait`, `interrupt`,
`join`, `waitEnd`, `destroy`, `sleep`, `cancel`, `made`. Pieces that
touch only a task's own record or do a single compare-and-swap are safe
to stop (a stop between an `interrupt`'s swap and its `wake` call only
delays the wake). Locks are not: a fiber stopped holding a spin lock, or
the output lock, would leave its worker spinning or blocked on it. So
every `SpinLock` and the output lock count themselves on the worker
(`holdOff`/`holdOn`, never inlined, so the count reaches the worker
the lock is taken on; no spin lock is held across a switch), and the
handler declines while the count is not zero. `raw` blocks are Rig code
and are preempted: they may not assume they are not (question 4).
Extern and C calls are outside the section.

**Callbacks the runtime inlines.** The opposite case is safe but costs
preemption: Rig code the optimizer inlines into the runtime's is outside
the section. A task's function was inlined into tasks.zig's wrapper,
which left the ReleaseSafe build of the fairness case with no section at
all and its spinner unstoppable; the runtime now calls a task's function
and `main` through `rt.callCode`, which under preemption is a call, never
inlined, of a function in the section (`inCode`), so the task's code
stays there; without preemption it is a plain call. Still outside:
closures the runtime calls (sort's comparator, a Map's hash and
equality of a program's type, iterator stages), actor methods (calls
through a table), `par`'s element functions. Their share of Trig's time
is below.

**Signal safety.** The handler reads its thread's worker through the
thread-local slot set when the worker started, the fiber's stack bounds,
and the context; it writes one word on the fiber's stack and two in the
context. No lock, no allocation, no call. `SA_RESTART` restarts what can
be restarted; `epoll_wait` and `kevent` return `EINTR`, which the poller
already takes as a wake with no events.

**Determinism.** A deterministic run (`RIG_SEED`) starts no monitor. A
build with `RIG_PREEMPT=signal` has no yield checks, so its seeded runs
yield only at waiting points and its virtual clock moves only there;
`rig test` and the suite never set the option (question 3).

**Timers and the poller.** A busy worker's own checks fired its timers
and looked at its poller every 250 µs. The monitor now signals a busy
worker whose earliest timer is due, or whose poller has events
(`poll(2)` on the epoll descriptor, which reads without taking them),
and `preempted` services them. A due timer waits for the monitor's next
period, 1 ms at most, where the checks took microseconds: on the
fairness case the 5 ms sleeps of a task sharing its one worker with a
spinner end 0.27 to 0.44 ms late (four runs; one of eight runs over all
modes was 3 ms or more late).

**Stacks.** The trampoline takes 152 bytes, the vector area (2,752 bytes
with AVX-512), and `preempted`'s calls; the handler declines with less
than 32 KiB above the guard, and the monitor signals again next period.

## What stays, what is emitted differently

- Without the option: nothing. Emit writes the same Zig for every
  program (tools/emit-diff below). The runtime's new code is behind the
  compile-time `rt.preempt`; a worker's preemption state is an array
  beside the workers, so `Worker` is unchanged; `Task.start` calls
  `rt.callCode`, a plain `@call(.auto)` when preemption is off. The
  release builds of bench/tasks and bench/actors are the same machine
  code as main's (`otool -t`, identical, on the Mac). A split build's
  unit 0 defines one more cell, the preemption array, which no code
  reads.
- With it: `linksection(rig.preempt_section)` on each non-inline
  function and closure, `__rig_preempt` in the root, the checks
  compiled out, the monitor thread, SIGURG's handler, each spin lock
  and the output lock a call longer on each side, `sched.current` a
  call, and `sched.me` two compares longer.
- Debug builds for Linux x86-64 use Zig's own backend, whose assembler
  takes neither `xsave` nor `ret $n`, so they keep their checks.

## Platforms

Built: Linux x86-64 (pup). Planned in this order:

- **macOS arm64.** The context is `DarwinContext` (runtime.zig). arm64
  has no way to branch to an address in memory without a register, and
  every register may be live at an arbitrary instruction, so the
  trampoline cannot return by itself: it restores every register but
  the program counter and ends with `brk`, whose SIGTRAP handler takes
  the saved PC and stack pointer from the frame and returns into the
  interrupted code with every register as it was. Two signals per
  preemption, at most one per slice. Zig 0.17's Mach-O linker defines
  no `section$start$__TEXT$__rig_text` (tried: undefined symbol), so
  the bounds come from `getsectiondata` on the executable's header as
  the monitor starts. A kqueue descriptor cannot be given to `poll(2)`,
  so a busy worker with descriptors is signaled every period. Not
  built in this round. Darwin's red zone is 128 bytes; its
  thread is signaled with `pthread_kill`.
- **Linux aarch64:** the same as macOS arm64, with Linux's `ucontext`
  (no red zone).
- **macOS x86-64:** the Linux trampoline, with Darwin's
  `__darwin_mcontext64`.

## Test plan

1. Fairness ([fair.rig](fair.rig); in test/rig/ under `release: true` when the
   option can be set per case, question 5): on one worker, a spinner
   and a task that sleeps 5 ms twenty times; every sleep ends within
   3 ms. Results above.
2. Slices: bench/tasks `hog` with the option on and off.
3. Locks: a program whose tasks print while others spin, under
   `RIG_SANITIZE=1 --release`, many seeds of the monitor's timing.
4. The section audit as a check: build examples/ and bench/ with the
   option and fail when the section holds a line of sched.zig,
   tasks.zig, alloc.zig, or net.zig outside an allowed list.
5. The suite under the option in release (not the default suite).
6. `zig build test` in debug, safe, and fast on pup (the option off).

## Measurements

**The ceiling** (Trig, measured by Trig's session; main with prebuilt
libs, PGO, Rig 7e78f3acf; `yl-new` has `turn` and `tickCall` return at
once and keeps every other check; pup core 3, 20 interleaved runs,
fastest). Base to no checks, cycles and instructions:

| Project | Cycles | Instructions |
|---|---|---|
| mitt | 34M to 32M, 5.9% fewer | 91M to 81M, 11% fewer |
| neverthrow | 44M to 43M, 2.3% | 105M to 97M, 7.6% |
| tiny-invariant | 213M to 205M, 3.8% | 640M to 607M, 5.2% |
| superstruct | 88M to 84M, 4.5% | 195M to 182M, 6.7% |
| zod3 | 497M to 488M, 1.8% | 1,130M to 1,099M, 2.7% |
| ts-pattern | 3,148M to 3,071M, 2.4% | 7,171M to 6,854M, 4.4% |

This is the most preemption can gain; the monitor, the signals, the
trampoline, and the lock counts come out of it. The bar (AGENTS.md) is
more than 1.5% faster, or at least 1% fewer instructions on one checker.

**The prototype's share of Trig.** Trig (`9cf8bd8`, the copy on pup)
built with the option in `--release` checks ts-pattern with output
byte-identical to a default build's. Sampled by `perf` at 10 kHz on one
checker (1,371 samples): 88.0% of them lie in the section, where a
signal stops it; 5.5% are in the kernel; the rest are the runtime's own
code: the allocator (`alloc`, `free`, `allocSlow`: 1.9%), the out-of-line
probes and rebuilds of `Map` (about 2%), `hashBytes`, `memcpy`. The
callbacks the runtime inlines (sort's comparator, a Map's hash of a
program's type) do not show: Trig's hot loops are in the section.

**bench/tasks and bench/actors**, `--release=fast`, 4 workers on pup's
E-cores 12-15, one run each, not a timing run (pup was busy with
release builds), off and on:

| Benchmark | Off | On (10 ms slice) |
|---|---|---|
| spawn | 7.0 ms | 6.9 ms |
| chain | 1.23 ms | 1.35 ms |
| fanout | 283 ms | 292 ms |
| yield | 12.4 ms | 13.4 ms |
| hog | 9.5 ms | 1,026 ms |
| actors solo / contend / spread | 17.1 / 37.3 / 4.4 ms | 18.4 / 36.1 / 4.8 ms |

Timed in a pup slot (`/tmp/open-slot.sh`, no cpuq holder, no Trig
run), `--release=fast`, 2 workers on P-cores 6 and 8, 9 interleaved
rounds, fastest of each:

| Benchmark | Off | On | On against off |
|---|---|---|---|
| spawn | 5.83 ms | 6.59 ms | 13% slower |
| chain | 0.86 ms | 0.87 ms | level |
| fanout | 296.9 ms | 315.9 ms | 6.4% slower |
| yield | 19.49 ms | 20.75 ms | 6.5% slower |
| hog | 6.19 ms | 1,089.5 ms | 176 times slower |
| actors solo | 11.32 ms | 11.73 ms | 3.6% slower |
| actors contend | 10.58 ms | 11.83 ms | 12% slower |
| actors spread | 5.82 ms | 6.14 ms | 5.5% slower |

The task-heavy rows pay for the scheduler's entry points that are calls
under preemption (`wake`, `stop`, `current`, and the rest) and the lock
counts; fanout, which only spins, should not be slower, and the
monitor thread shared the two cores under `taskset`, so that row wants
a rerun with the monitor on a core of its own before it is believed.

`hog` is the finding. With every core busy with 32 spinning tasks, the
checks give the runnable fibers on a worker turns of about 1,024 loop
turns each, microseconds, so the chain's waits end at once; preemption
gives them turns of a slice, so each of the chain's 100 waits is about
a slice: 1,026 ms at 10 ms, 774 ms at 2 ms, 806 ms at 1 ms, 422 ms at
250 µs (`RIG_PREEMPT_SLICE_US`). This is Go's behavior (scheduler.md
"Yield checks": "Go stops a goroutine after 10 ms, by a signal"), and
it costs nothing when cores are not oversubscribed, as in Trig's
checker pool. The first prototype also held a preempted fiber on its
worker, and fanout took 531 ms (TLS and the worker, above).

## Questions the record does not settle

1. Hog latency. Preemption trades the checks' microsecond turns under
   oversubscription for slices. Default: keep the option off; a
   default-on design adds a short slice for a fiber that was woken
   (the "run next" slot's) and measures hog again before any default
   changes.
2. Local tasks under preemption yield to their siblings only at
   waiting points. Default: accept, and say so in SPEC §18 if the
   option becomes default.
3. `rig test` with the option set runs seeded with no yield checks.
   Default: `rig test` ignores `RIG_PREEMPT` once the option is kept.
4. `raw` code is preempted like any Rig code. Default: yes; a `raw`
   block that must not be stopped takes a lock.
5. The option's form. Default: the environment variable while it is a
   prototype; `rig build --preempt` if it is kept and not the default.
6. Linux debug builds keep their checks (Zig's own backend). Default:
   accept.
7. The section audit (test plan 4) and the macOS arm64 port come before
   any default-on. Default: yes, after Trig's numbers show the gain
   clears the bar.

## The wait trigger (after the first review)

The designer asked that the monitor signal when work has waited, not
when a fiber has run 10 ms, so a woken fiber still gets its core within
microseconds. Built (299a8364a): every period the monitor signals a
worker that has started no fiber since its last look and had work in
its own queues ("run next" slot, ring, pinned) then and now; the period
is `RIG_PREEMPT_WAIT_US` (default 50 µs) while any worker has such work
queued, 1 ms while any runs a fiber. A preempted fiber goes to the
global queue, behind the fibers made or woken, as Go puts it; only the
10 ms slice hurries those. Inside sched.zig its functions call each
other directly; only the entry points other files call (`wake`,
`park`, `yield`, `interrupt`, `pinHere`, `register`, and the rest) are
calls never inlined. On E-cores, 4 workers: hog 14.6 ms with a 50 µs
wait, 42 ms with 100, 34 ms with 200 (off 6.5 ms).

Timed in a pup slot, 2 workers on cores 6 and 8, 9 interleaved rounds,
fastest, against off:

| Benchmark | Off | On, 50 µs | On, 100 µs |
|---|---|---|---|
| spawn | 5.76 ms | 8.5% slower | 9.0% slower |
| chain | 0.85 ms | 1.7% slower | 1.6% slower |
| fanout | 297.1 ms | 6.1% slower | 6.1% slower |
| yield | 20.28 ms | 3.6% slower | level |
| hog | 6.18 ms | 13.5 ms, 2.2 times | 20.3 ms, 3.3 times |
| actors solo | 11.31 ms | 3.5% slower | 3.7% slower |
| actors contend | 10.70 ms | 12% slower | 12% slower |
| actors spread | 5.83 ms | 5.8% slower | 5.5% slower |

Where the per-operation cost comes from, from two builds made only to
measure (same slot, monitor quiet): without the lock counts, spawn is
6.7% slower than off (13.4% with them); without the never-inlined
entry points and `me`'s check, contend is 2.3% slower, solo and spread
level, yield 1.5% faster. So most of it is the calls that are no
longer inlined. Fanout is 6% slower in every build with the option,
quiet ones too: with no check its loop is unrolled eight times, and the
unrolled loop runs slower, a code-layout effect of the spin loop and
not a cost of preemption.

The fix in view moves the never-inlined boundary out to the entry
points of tasks.zig that emitted code calls, one call per operation, so
the scheduler's code inlines into them again; and replaces the lock
counts with a lock that is a call checked to come from outside the
program's code. Both touch tasks.zig and the lock's callers.

## The per-operation cost, second round

The designer asked for one out-of-line call per operation at
tasks.zig's entry points, with the scheduler inlined into them again,
and for a lock call checked to come from outside the program's code in
place of the lock counts. The checked lock was built and run first:
it panicked at once in bench/tasks and bench/actors, both builds,
because a lock *is* taken in code inlined into the program's. The
output lock is taken by `print` (an inline function), by `finish`, by
`printRendered`, `warn`, and `writeStandard`; the actors' mailbox lock
by `Actor.send` (and `takeSlot`, `freeSlot`, `withdraw`, `kill`); the
pool's by `wakeLeft` from `finish`. 51 lines take or let go of a lock in tasks.zig
and runtime.zig. A checked lock needs each of their functions out of
line from the program's code; the count needs nothing of them, so it
stays. Under preemption `sched.current` now reads its slot without
`me`'s check, a single call:

| Benchmark (pup slot, 2 workers, 9 rounds) | Off | On |
|---|---|---|
| spawn | 5.92 ms | 9.8% slower |
| chain | 0.86 ms | level |
| fanout | 297.3 ms | 6.1% slower (the unrolled loop) |
| yield | 19.68 ms | 2.3% slower |
| hog | 6.19 ms | 13.5 ms, 2.2 times |
| actors solo | 11.34 ms | 5.6% slower |
| actors contend | 10.59 ms | 8.6% slower |
| actors spread | 5.84 ms | 7.6% slower |

Not done: moving the never-inlined boundary to tasks.zig's entry points.
The measure-only build without the boundary (above) bounds what it can
win: contend 2.3% slower, solo and spread level. The per-operation
fix does not move hog, which the wait trigger sets.

## Trig, on against off (9d43c237f)

Timed by Trig's session on pup, one checker, Trig built by the Rig at
9d43c237f with and without `RIG_PREEMPT=signal`: 2.2 to 8% fewer
cycles (superstruct 8%, mitt 3.6%, ts-pattern 2.3%), 4.3 to 10% fewer
instructions, 1.5 to 4.1% faster in wall time on four of the six
projects, peak memory level, output identical. Four checkers were
noisy, level to better. That clears the bar (more than 1.5% faster, or
at least 1% fewer instructions on one checker).

The owner approved merging the prototype with the option off by
default, after an independent soundness review, and a later round
toward default-on, in order: the never-inlined boundary at tasks.zig's
entry points (the per-operation costs), the latency of a woken task
(hog), the macOS arm64 port, a static check of the section, and a
quiet rerun at four checkers.

## The soundness review (2026-11-05)

An independent review (read-only, probes on pup in
`/zfs/rig-work/review-952/`) found no memory corruption and these,
fixed here:

1. **A held pinned fiber could be overwritten and lost.** While a
   pinned fiber P was held, the worker still ran unpinned fibers; one
   that made a local task was pinned from then on, and its preemption
   wrote over P, which never ran again: its waiter hung and its stack
   leaked (the review's `hold.rig` with `main`'s two spawns swapped,
   one worker: off it prints its sum, on it hung three times of
   three). Now `preempted` stops a pinned fiber only while no other is
   held, and only for work that is not pinned (its "run next" slot,
   ring, or the global queue): its siblings wait behind it in any
   case, so stopping it for them only cost (21k preemptions, 6.3 s
   against 5.8 s). `hold` panics if one is held already. Each worker
   says whether the fiber it runs is pinned (`pinned_running`, set by
   `runFiber` and `pinHere`), and the monitor counts only work that is
   not pinned for such a worker. test/cli/preempt.sh is the probe: it
   failed with the Rig at 9d43c237f (killed at its 60 s timeout) and
   passes with the fix.
2. **The deadlock detector's lock was not counted**, and its take and
   release were inlined into the program's code (bench/actors,
   `contend`): a holder stopped there would leave `walkFrom` spinning.
   `lockGraph` counts now, as do alloc.zig's spin locks
   (`tables_lock` and the rest) and the profile, map trace, and leak
   checker locks. A unit test (sched.zig, "every lock the runtime
   takes is counted") fails on any spin on a flag or `std.Io.Mutex`
   taken in runtime.zig, sched.zig, tasks.zig, alloc.zig, or net.zig
   without the count within three lines, or a note saying why it needs
   none (a fault's handler, a panic that ends the program, a flag set
   once).
3. **`flushBeforeWait` took the output lock uncounted and let it go
   counted.** It takes it through `tryLockOutput`, counted, now.

Known limits, for the default-on round:

- Thread-locals do appear in the section: each `rt.task()` there
  compiles to a call of `currentOf` and then `%fs`, since LLVM folded
  the never-inlined `threadTask` (a thread-local's address is a
  constant to it). The address is used only when `current()` is null,
  outside every fiber, so no signal stops that code; but "no
  thread-local in the section" does not hold, and `never_inline` is no
  guard for one. `std.heap.SmpAllocator` (debug builds' allocator) is
  inlined there too, with its `thread_index` and per-slot mutex; a
  stopped holder makes others move to another slot. The static audit
  lists every `%fs` site and allows only these.
- The trampoline calls `preempted` with the interrupted x87 and MMX
  state live, where the ABI wants the x87 stack empty: `fninit` and
  `emms` after `xsave` (which `xrstor` undoes) before any target uses
  f80.
- The state saved is the compile-time target's: APX's r16-r31 and AMX
  are not, which a future target needs.
- With libc, `pthread_kill` may be sent to a worker that has exited
  after the monitor read it, and code that reads `errno` after an
  extern call could read another thread's after a migration.
- While work waits, the monitor signals a worker every period even when
  its fiber is in a system call; `SA_RESTART` covers most, and `poll`,
  `epoll_wait`, and `nanosleep`, which return `EINTR`, are outside
  fibers or retried where Rig calls them.

## Local tasks: the redesign question (2026-11-05)

The recheck of cc74753f5 found a liveness hole, the second soundness
fix in this area, so by RIG-MANTRAS the feature stops for redesign:
`starve.rig` (the review's probe), a pinned task that spin-waits on a
`*Cell` a local sibling sets, hangs with the option on and finishes in
1.5 s off, since the monitor no longer stops a pinned fiber for its
siblings.

The design proposed in the recheck, a preempted pinned fiber queued
FIFO behind its siblings, is not sound. concurrency.md, "Local tasks":
local tasks share `*T` and `~T` counts that are not atomic, a `Cell`
of more than one word, a `Signal`, and a function's captures, and
"take turns at their waits and yield checks". Those are points where
no count is half-changed and no `Cell` half-copied. A signal stops a
fiber at any instruction: between the load and the store of a count's
increment, or in the middle of a two-word copy. A sibling run then
changes the count, and the stopped fiber's store undoes it (a use after
free), or reads half of a new value. So a pinned fiber stopped at an
arbitrary instruction may let only unpinned work run before it resumes
(the hold), and its siblings may run only at its waiting points; with
no yield checks there are none in a spin loop, and starve.rig hangs.
Liveness and soundness for local tasks both need the safe points that
the yield checks are.

The design that keeps both: **preemption applies to a program that
makes no local task.** A program whose sema records a local task
(`Facts.local_tasks`, which `rig check --tasks` lists) is built with
its yield checks, whatever `RIG_PREEMPT` says, and its local tasks take
turns as they do today. A program with none has no pinned fiber at all
(`pinHere` is the only thing that sets a home), so the hold, `held`,
`popPinned`, `pinned_running`, and their monitor rules are deleted, and
every preempted fiber goes to the global queue. Trig makes no local
task (`rig check --tasks` on Trig's main lists none), so its measured
gain stands. It takes one fact read in `bin/rig` (main.zig: the root
flag and emit's section, from `local_tasks`), which is outside this
branch's row.

The lock-count scan now also finds a swap to true and a compare-and-
swap from 0, and `Io.Mutex.lock(io)`, in ordered.zig, unordered.zig,
table.zig, and split.zig too; it found no lock there, and three flags
set once, now noted.

**Built (17a33377b), as the designer decided.** `bin/rig` reads
`Facts.local_tasks` of every module the program loads, std modules
among them, once in `emitPackage`. With `RIG_PREEMPT=signal` and a
local task anywhere, it writes neither the root's `__rig_preempt` nor
emit's section, and prints one line on stderr:
`rig: RIG_PREEMPT=signal ignored: this program makes local tasks
(FILE:LINE), which take turns at yield checks`. No std module makes a
local task: a program that uses every std module (std/*.rig) emits no
`spawnLocal`, so a server built on std.net or std.http is preempted.
`rig test` writes its own root, without `__rig_preempt`, so its seeded
runs keep their checks (question 3). The hold, `Preempt.held`,
`popPinned`, `hold`, `pinned_running`, and the monitor's rules for
pinned fibers are deleted; a preempted fiber always goes to the global
queue, and `preempted` never stops a pinned fiber, should one exist.

test/cli/preempt.sh runs, on any machine, `hold.rig`, `starve.rig`,
and `ring.rig` (two local siblings and an unpinned task spin-waiting on
each other in a ring, one worker) with the option and without,
expecting the same output, the note, and an end within 60 s; and a
program with no local task, which gets no note.
