# Cheaper yield checks: a study (2026-10-30)

Queue row 10, approved by the owner on 2026-10-30 as "study only; Mac
timing only, through tools/low". This is a record and a recommendation.
No compiler change landed, nothing was committed, and no PR was opened.

**The question.** In a program that makes tasks, every loop counts its
turns and calls the scheduler every 1,024 of them (`rig.turn`), and
every cycle of calls passes a function that reads one flag at its entry
(`rig.tickCall`) (docs/internals/scheduler.md, "Yield checks"). On pup,
Trig's ts-pattern runs 2.5% faster with no loop checks at all, and
PR #782's strips made it 2.6% slower. Is there a cheaper check that
keeps preemption bounded and gets most of that 2.5% back?

**The answer.** Keep the per-loop count. No check measured here is both
sound and cheaper on Trig.

- **On the Mac the ceiling is within the noise.** With no loop checks
  at all, Trig retires 2.5% fewer instructions (section 1). Two
  identical builds differ by up to 2.9% in time, and the ceiling's gain
  is no larger.
- **Moving the check to function entries costs more than it saves**
  (sections 4 and 5).
- **Telling LLVM the check leaves memory alone cannot be said in Zig
  0.17** (section 2).
- **Short counted loops are too rare in Trig to matter** (section 6).
- **Signals cannot be made safe in Rig's runtime** (section 7). Go and
  Erlang pay the same cost in other forms (section 8).

One option is real: **a flag load per turn in place of the count**
(section 3). It is neutral on Trig and recovers all of knucleotide-fast's
9%. But it lets a task queued behind a busy worker wait 6 times as
long, and a 10 ms sleep wait for the whole loop, unless a new monitor
sets the flag. That trade is the owner's (decision 2).

Two findings matter beyond the checks:

- **fannkuchredux-fast takes a third less time** when its flip loop
  happens to store the permutation with one vector store instead of
  lane by lane (section 3). That is codegen, not the check, and it is
  worth its own look (decision 3).
- **With no loop checks at all, a 10 ms sleep still ended in 11 ms**
  behind a spinning task on one worker (section 9). Something other
  than the busy worker's checks fires timers. That path was not traced,
  and the checks at function entry defeat it.

## Method

- **Machine.** The Mac (Apple M5, 10 cores), shared with other sessions.
  `.mac-quiet` was absent at every start. Every timed run went through
  `tools/low`, and every compiler and Trig build through `tools/heavy`.
  The load ran from 3 to 25 during the evening. The final rounds of Trig
  count only when the one-minute load is under 4 before and after them
  (`LOAD_MAX=4`, about one round in six was dropped). The final
  benchmark rounds start only under 4.

  `tools/low` is `nice -n 19`, which macOS may run on efficiency cores.
  Fastest-of-N filters that out, and medians do not, so both are
  given.
- **The variants** come from one compiler, `rig-study`, built in the
  worktree `sched-check-study` from main `3e569f3f5`. `RIG_STUDY` picks
  a variant, and each variant emits plain Zig with no switch at run
  time: the compiler rewrites one `const` line of the runtime it writes
  beside the program, or emits other checks. `study.patch` holds the
  prototype.

| Variant | `RIG_STUDY` | What it emits |
|---|---|---|
| base | (none) | main's checks: a count per outermost loop nest (2,957 in Trig, 3,354 turn sites), and entry flags on the cycle cut (387 functions) |
| none | `turn=1` | no loop checks (the ceiling); entry flags as on main |
| flag | `turn=3` | each turn loads `sched.waiting`, and when it is set calls `sched.tickCall` (claim it, yield); no count |
| callfree | `callfree` | no count in a loop whose body or condition calls a Rig function that is not inlined; entry flags as on main |
| entry-noloops | `entry,turn=1` | an entry flag in every function that is not inlined (4,508 in Trig); no loop checks |
| entry-callfree | `entry,callfree` | entry flags in every function, and counts only in loops that call nothing (1,891 of 3,354 turn sites) |
| (nomem) | `turn=2` | the count, with its `asm` call clobbering no memory: the same machine code as base (section 2) |

- **Trig** (`~/Data/Code/trig` at 2ba0719) was built for each variant as
  the census builds it: `rig build --release -o trig src/main.rig` in a
  copy of `src/`, with `tools/trig/main.rig` as `src/main.rig`. It ran
  in `misc/projects/{ts-pattern,zod3}` as `trig -p tsconfig.trig.json
  --noEmit`, and again with `--singleThreaded`: one checker shows the
  checks' cost without the workers' timing.

  Every variant printed the same output (`time-trig.py` checks).
  Variants ran interleaved, the order reversing each round. Instructions
  retired and cycles come from `/usr/bin/time -l`. `mainrig` is the same
  Trig built by unpatched main's `bin/rig`, with the base's machine
  code, so its distance from base is the noise floor.
- **The small benchmarks** were built with `--release=fast`:
  - knucleotide-fast, with fasta 25M on stdin;
  - fannkuchredux-fast at 12;
  - `bench/tasks`, its `hog` per step and its `fanout`.

  The two compute programs ran on one worker (`RIG_WORKERS=1`). On all
  ten cores, under that evening's load, their times swung by a fifth.
- **`latency.rig`** is new. On one worker, `main` queues a task, or
  starts one that sleeps 10 ms, and then spins for 400 million turns in
  a loop that calls nothing, or in one that calls a `called` function
  each turn. It prints how long the queued task waited to start, or how
  long the sleep took.

## 1. What the count costs on the Mac

Trig, `--singleThreaded`, 30 rounds kept (`data/trig-single-quiet*`):

| | base | mainrig (same code) | none (ceiling) |
|---|---:|---:|---:|
| ts-pattern, fastest | 545.8 ms | 2.9% faster | 3.2% faster |
| ts-pattern, median | 591.9 ms | 0.6% slower | 1.1% faster |
| ts-pattern, instructions | 9.702G | 0.1% fewer | 2.5% fewer |
| zod3, fastest | 112.4 ms | 0.8% slower | 0.4% faster |
| zod3, median | 124.7 ms | 0.4% slower | 2.3% faster |
| zod3, instructions | 1.887G | 0.3% fewer | 2.3% fewer |

With Trig's own checkers, 20 rounds kept (`data/trig-default-quiet*`),
none is 2.0% and 1.6% faster at the fastest. mainrig is 0.2% and 1.2%
faster, and its medians are up to 3.8% away. An earlier run of 30
rounds at a load of about 4 (`data/trig-single*`, `trig-default*`)
agrees: the ceiling is 0.3% to 0.8% faster at the fastest, with 2.5%
fewer instructions.

So on the Mac the loop checks cost Trig 2.5% of its instructions and
about 1% of its time, which the Mac cannot resolve. That is less than
pup's 2.5%, as the loop-hoist record also found: the count's `subs`
and `b.eq` fuse and predict, and a wide core absorbs them. Any gain
measured below on Trig is an instruction count, with time inside the
noise.

knucleotide-fast is where the count costs time. On one worker, 15
rounds (`data/bench-knuc-1worker*`), base takes 1,845.7 ms at the
fastest (1,997.5 ms median), and none is 8.9% faster (9.4% at the
median). Its count loop, `(!counts).ensure(mix(code), 0) += 1` over
the sequence, calls nothing that is not inlined, so every sound design
below must still check it. fannkuchredux-fast moves 1.7% (3 rounds,
`data/bench-1worker-3rounds*`).

## 2. Telling LLVM the check leaves memory alone

The cold call in every loop is an `asm volatile` that clobbers memory
(`callKeeping`). So LLVM reloads anything the loop reads through a
pointer after each turn, and it will not hoist such a load out of the
loop (records/2026-10/perf-stage/loop-hoist.md). The tick does not need
that clobber. A yield check is not a point of synchronization in Rig:
no task may write memory that another task reads without a wait, an
atomic, or a lock between them, and each of those is its own call or
atomic. So no program can see memory change across a check.

**It cannot be said in Zig 0.17.** In `micro/hoist.zig`, the same loop
was compiled three ways: with the check's `asm` clobbering memory, with
it clobbering none, and as a non-volatile `asm` with an output. All
three give the same machine code (`micro/hoist.s`). The slice's pointer
is reloaded every turn (`ldr x12, [x0]`), and its length after each
call. With no check at all, the loop hoists both and unrolls by four.
Zig marks every inline `asm` as touching memory, whatever its clobbers
say. The `turn=2` build of `bench/tasks` disassembles to the base's
code, symbol names aside, so it was not built for Trig.

**To build it:** an LLVM-level call with
`memory(inaccessiblemem: readwrite)`. Zig has no syntax for that, so it
needs a Zig change upstream or Rig emitting LLVM IR itself. It would
also be a CORE paragraph: an assumption the compiler makes about every
safe program. What it could buy on Trig is bounded by section 1, and
the loop-hoist record found that Trig's index tests also keep its loads
in their loops.

## 3. A flag load per turn, against the count

**What it guarantees.** A turn reads `sched.waiting` and yields when it
is set. The scheduler sets it when work is made while every worker is
busy, or when a fiber fills its worker's "run next" slot and runs on.
So queued work is still taken within a turn. `latency.rig`'s queued
task waits 0.02 ms behind either loop, as on main (section 9).

What the flag loses is the busy worker's own service. The count's tick
also fires its worker's due timers and polls its descriptors
(`sched.serviceBusy`). Nothing sets the flag for those, so a 10 ms
sleep waited 1,237 ms, the whole spin. Keeping that service needs a
monitor that sets the flag when a busy worker has a timer due or
descriptors to poll, as Go's sysmon does, at most every 250 µs.
`hog` also gets worse with the one global flag: a queued step waits
552 µs at the fastest (818 µs median), against base's 91 µs (119 µs),
and `fanout` is 5.3% slower. The flag fires on any worker's need, and
the first check to see it may belong to a worker that cannot take the
work.

**What it costs.** One load and one branch per turn, against a decrement
and a branch, with no count to keep live across the loop.

| | Trig instructions | Trig time | knucleotide-fast, 1 worker |
|---|---|---|---|
| flag | 0.2% to 0.3% fewer | within the noise (2.6% faster to 0.2% slower at the fastest) | 9.5% faster (8.9% median): all of the ceiling |

**fannkuchredux-fast's flag build takes 33% less time** (11.58 s,
against base's 17.25 s, on one worker), while none takes only 1.7%
less. The flag is not the cause. In the base and none builds, LLVM
writes the 16-byte permutation to the stack lane by lane before each
flip's `p[head]`: about 30 instructions a turn. The flag build happens
to write it with one `str q24` in 12 instructions
(`data/fannkuch-flip-loop.txt`). That is a codegen accident of a
vector indexed by a value known only at run time. It is a lead for its
own look, unrelated to yield checks.

**To build it:** about two days, and the runtime's gates on pup.

- `rig.turn` becomes the flag load. Emit loses the count's local.
- A monitor sets the flag for timers and pollers. Either a new runtime
  thread, or the timer or pool thread if one fits.
- The flag needs a per-worker request bit, so the check that sees it
  can tell whose work waits; otherwise `hog` stays 6 times worse.
- Deterministic runs must still advance their virtual clock and offer
  the seed a yield at each check (`sched.tick`, deterministic branch).
  A test run could hold the flag set, so every turn reaches the
  scheduler, at a cost to test time alone.

## 4. A check at every function entry

**What it guarantees.** An entry check bounds the work between checks
only for code that calls. A loop that calls nothing never reaches one,
so entry checks alone let it starve every task queued behind it:
1,231 ms in `latency.rig`, the whole spin. The entry check is a flag
read, so it does not service timers either.

**What it costs.** Checking all 4,508 of Trig's functions that are not
inlined, instead of the cycle cut's 387, and dropping every loop check
(entry-noloops): 2.2% to 2.7% more instructions. That is more than the
loop checks it replaces cost. Time is within the noise (2.7% faster to
1.8% slower at the median). knucleotide-fast gains its ceiling (12.9%
faster), but only because its count loop is no longer checked.

**To build it:** an hour (`inlining.decide` marks every function). It
is not worth building: it is unsound alone, and costlier than the count.

## 5. Calls check; only call-free loops count

**What it guarantees.** It combines section 4 with counts in only the
loops that call nothing: a loop whose turns call a function relies on
that function's entry check. For queued work that bounds every loop:
0.02 ms behind either `latency.rig` loop. It still loses the timer
service in loops with calls (1,150 ms for the sleep), as section 3
does.

The precise rule is stricter than the one measured. A loop can rely on
its calls only when **every** turn makes one, on every path through
the body. The prototype dropped the count whenever the body held a
call anywhere, so it overstates the gain.

**What it costs.** Trig: 3.4% to 3.9% more instructions (the entry
checks' 2.2% to 2.7%, plus the counts kept) and up to 5.0% slower at
the median. Dropping the counts alone, without the entry checks
(callfree, which is unsound: a loop calling `step` starved its queued
task for 1,151 ms), saves 0.8% to 1.3% of the instructions. That is
under half of the ceiling, and less than the entry checks cost.
knucleotide-fast is unchanged at the median, since its count loop
calls nothing.

Restricting entry checks to the functions called from loops would not
rescue it: those functions are called from everywhere else too, and
each call there would pay.

**To build it:** about a day. It needs a storage fact for "every turn
calls a function that checks", which emit reads. It loses on Trig, so
it is not recommended.

## 6. Skipping counted loops known to be short

Of Trig's 905 range loops, 10 have a constant end, and 9 of those end
at 64 or less. Its 1,545 Zig `for` walks go over slices whose length is
known only at run time. Dropping the check from loops with a small
constant bound keeps the guarantee: an outer loop's count still bounds
them, at K turns of the short loop to each counted turn. But on Trig
that touches about 1% of its loops, so it is not worth a rule.

The other route, counting a loop known only at run time to be short
ahead of its turns, is PR #782's. On pup it made ts-pattern 0.9% to 2.8%
slower: its setup costs more than the few turns it saves, and it gives
LLVM an opaque entry. Nothing on the Mac contradicts that, so it was
not rebuilt here.

## 7. Signals or a timer that preempt at safe points

**What it guarantees.** A monitor would send a signal to a worker that
has run one task too long, as Go's sysmon does with SIGURG after 10 ms.
The handler would point the interrupted context at a trampoline that
saves every register and yields (Rig's `Keeping` is already one). It
costs nothing on the hot path, and no loop starves anyone for longer
than the monitor's period.

**Why Rig cannot build it soundly.** A fiber may resume on another
worker after any switch, and the runtime keeps per-thread state that
assumes a switch comes only at known calls:

- The allocator's heap of each thread has no lock (`alloc.zig`,
  `my_heap`), and its fast paths are inlined into user code. A signal
  taken partway through an update would resume on another thread's
  heap, or let a second fiber on the same worker into the same heap
  halfway through.
- The scheduler, the timers, and the poller have the same property, as
  do the Zig library functions that are not async-signal-safe.

Go makes this safe with maps of unsafe points that its compiler emits:
write barriers, a live `uintptr` derived from a pointer, past-the-end
pointers in range loops, and the runtime's own code. Zig and LLVM emit
no such maps, and Rig cannot mark which instructions of an inlined
runtime path are safe.

A monitor that only **sets a flag** is buildable, but it still needs a
check that reads the flag: section 3.

**To build it:** a monitor thread, signal handling on both platforms,
and a soundness argument the code cannot give. Not recommended.

## 8. What Go and Erlang do

- **Go** gets a check at every function entry for free. Its stacks
  grow, so every prologue already compares the stack pointer with
  `g.stackguard0`, and the scheduler preempts by poisoning that bound,
  so the next call takes the slow path. Rig's stacks never move, since
  loans point into them, so there is no prologue check to share.
  Section 4 measures what adding one costs.

  Go's loops that call nothing could not be preempted until Go 1.14,
  which added section 7's signals. Its proposal
  (golang/proposal, 24543-non-cooperative-preemption.md) found that
  explicit back-edge checks caused "unacceptable slow-downs in tight
  loops". A cheaper check that faults, one instruction a loop, cost
  7.8% geomean on its benchmark suite. So Go took the signals, with the
  unsafe-point maps its compiler and garbage collector already had.
  What it pays is latency: its scheduler preempts after 10 ms, and
  `hog` waits 2 to 3 ms in Go (scheduler.md), where it waits 0.09 to
  0.12 ms in Rig.
- **Erlang** counts reductions. Every function call costs one, and a
  process yields after about 4,000. Every Erlang loop is a call, since
  loops are tail recursion, so its count per call is a count per turn,
  kept in a register of the emulator and of its JIT. Built-in functions
  charge reductions in proportion to their work, and native code must
  yield by hand or run on a dirty scheduler. Its cost is a decrement
  and a branch on every call, which is what Rig pays on every turn.

Neither escapes the cost. Go's hot path costs nothing because growable
stacks and a garbage collector built the checks and maps it reuses.
Erlang pays what Rig pays.

## 9. Preemption: what each option keeps

`latency.rig` on one worker, `main` spinning about 1.2 s, the fastest
of three runs in ms (`data/latency.txt`):

| Variant | queued task, behind a loop that calls nothing | queued task, behind a loop with calls | 10 ms sleep, behind a loop that calls nothing | 10 ms sleep, behind a loop with calls |
|---|---:|---:|---:|---:|
| base (main) | 0.020 | 0.025 | 10.003 | 10.002 |
| none | 1,230 | 1,144 | 11.01 | 11.01 |
| flag | 0.018 | 0.016 | 1,237 | 1,155 |
| callfree (unsound) | 0.017 | 1,151 | 10.003 | 11.01 |
| entry-callfree | 0.023 | 0.017 | 10.003 | 1,149 |
| entry-noloops | 1,231 | 0.015 | 10.58 | 1,148 |

`bench/tasks` `hog` on all ten cores, 10 rounds (`data/bench-tasks*`),
fastest and median per step: base 91 µs and 119 µs; flag 552 µs and
818 µs; callfree 86 µs and 117 µs; entry-callfree 84 µs and 132 µs;
none 4.5 ms and 6.0 ms.

Only the count keeps all four bounds: queued work and the worker's
timers, behind every kind of loop. The worst case between two checks
stays what scheduler.md gives: 1,024 turns of the loops in a nest, plus
in each turn at most one chain of calls that repeats no function.

The sleep that ends in 11 ms with no loop checks shows that another
path fires timers on a busy worker at about 1 ms. It was not traced
here. The entry checks defeat that path: they clear `waiting` without
servicing timers, so the sleep then waits for the whole spin. Any
design that keeps entry checks and drops loop counts must service
timers in them, which means reading the clock or a count: section 3's
monitor again.

## Recommendation

**Keep the per-loop count, and do not build a replacement now.** It is
the only check measured that keeps every bound. On the Mac it costs
Trig about 1% of its time, which the Mac cannot separate from noise,
and 2.5% of its instructions. Each alternative either costs Trig more
(sections 4 and 5), cannot be expressed in Zig (section 2), touches too
few loops (section 6), or cannot be made safe (section 7).

The flag (section 3) is the one design worth a decision. It costs the
same on Trig and frees knucleotide-fast's 9%. In exchange it takes a
monitor in the runtime, a per-worker request bit to win back `hog`'s
latency, and rework of deterministic runs. Whether it gets Trig any of
pup's 2.5% can only be measured on pup, where the ceiling is large
enough to see.

## Decisions for the owner

The owner approved all four defaults on 2026-10-31: #782 closed and kept
as `archive/loop-tick`.


1. **Keep the count, and close PR #782 unmerged.** Default: yes.
2. **Fund a flag-plus-monitor prototype, timed on pup** (Trig, hog,
   knucleotide), about two days. It may recover knucleotide's 9% and
   whatever of Trig's 2.5% the flag can, at some cost in preemption
   latency. Default: not now; revisit if knucleotide-fast's gap to Rust
   matters more than `hog`'s latency.
3. **Queue a separate study of fannkuchredux-fast's flip loop.** One
   vector store instead of a store per lane took a third off its time
   on one worker. It is codegen, not checks. Default: yes, study only.
4. **Ask upstream for a memory-effects attribute on Zig calls or
   `asm`.** Default: no, record only. Trig would gain little while its
   index tests keep its loads in their loops.

## Files

Kept here: the summaries in `data/` (each `*-summary.md` and `*.md` is
fastest and median from its raw runs), `builds.txt`, `latency.txt`, and
`fannkuch-flip-loop.txt`. Records keep no bulk data, so the rest is in
the owner's session folder, `~/Data/Code/Claude/rig/rig/sched-check-study/`:

- `study.patch`: the prototype (`RIG_STUDY` in runtime.zig, emit.zig,
  main.zig), against main 3e569f3f5.
- `build-trigs.sh`, `build-benches.sh`, `time-trig.py`, `time-bench.py`
  (interleaved, fastest of N, `LOAD_MAX` gating), `summarize.py` and
  `benchsum.py`.
- `bins/`: every compiler and Trig build timed.
- `data/*.raw` and the build logs. The runs named `flagstuck`, and the
  flag rows of `trig-single*`, `trig-default*` and `trig-prelim`, come
  from a first flag build that never cleared the flag; they are kept,
  not used.
- `micro/hoist.zig` and `hoist.s`: the clobber experiment.
- `bench/src/`: the benchmark sources and `latency.rig`.
