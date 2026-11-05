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
   holds the fiber on its worker and switches.

## Hazards and their answers

**TLS.** Compiled code may keep a thread-local's address in a register.
A fiber stopped mid-function resumes on its own worker: `preempted`
gives an unpinned fiber that worker as its home while it is held and
queues it with the worker's pinned fibers, which no other worker takes;
it clears the home when it resumes. From its next ordinary waiting
point it moves as any fiber does, which is safe for the reason it is
today: no Rig code keeps a thread-local's address across a call that
may switch (`sched.me` and `alloc.threadToken` are never inlined).
Evidence: the section of the fairness case's ReleaseSafe build holds 11
reads of `%fs`, all the fallback of `rt.task()` that runs outside every
fiber (runtime.zig, `thread_task()`); on a fiber none runs.

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
  program (tools/emit-diff below); the runtime's new code is behind the
  compile-time `rt.preempt`, its fields `void`. Two changes reach the
  default build's source: `claimWaiting` calls a new `stealWaiting`
  (the same loops), and `Task.start` calls `rt.callCode`, a plain
  `@call(.auto)` when preemption is off.
- With it: `linksection(rig.preempt_section)` on each non-inline
  function and closure, `__rig_preempt` in the root, the checks
  compiled out, the monitor thread, SIGURG's handler, and each spin lock
  and the output lock a call longer on each side.
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
  preemption, at most one per slice. Darwin's red zone is 128 bytes; its
  thread is signaled with `pthread_kill`.
- **Linux aarch64:** the same as macOS arm64, with Linux's `ucontext`
  (no red zone).
- **macOS x86-64:** the Linux trampoline, with Darwin's
  `__darwin_mcontext64`.

## Test plan

1. Fairness (`fair.rig`, test/rig/ under `release: true` when the
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

(Filled in below as they were taken.)
