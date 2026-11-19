# Free fork-join, the deque: the Mac board (2026-11-19)

The fourth build commit of [runtime.md](runtime.md) §6: forks wait on a
Chase-Lev deque of their worker's own (`sched.Forks`), not the "run next"
slots or the ring, on [inline.md](inline.md)'s inline run. Heap tasks,
local tasks and woken fibers keep the slots and the ring. The orders are
those formal/Models/Deque.lean checks (#1162).

## What was built

- **The deque.** 256 slots, `bottom` written by its owner alone, `top`
  moved by compare-and-swap, each on a cache line of its own. The push
  stores the slot monotonic and `bottom` release; a take (`popIf` at the
  join, `popNewest` in the worker's loop) stores `bottom` back seq_cst
  and loads `top` seq_cst, and settles the last fork by a
  compare-and-swap of `top`; a thief loads `top`, then `bottom`, then
  the slot's pointer, and owns it only once its compare-and-swap wins.
  Each order's comment in sched.zig names the model's failing variant
  it answers (`pushOrd := .rlx` under `Arch.arm`, `popOrd := .rel` under
  `Arch.tso`, `lastNoCas`, `blindSteal`, `loadsSwapped`, `readThrough`).
- **Who takes a fork.** Its maker at the join, inline (`runHere`), or by
  a handoff when the room is short; its worker's loop, newest first,
  after the slots and before the pinned queue, the ring and the global
  queue, when the maker parked or was stopped; an idle worker's search,
  after every ring, the oldest, one at a time. A local fork, which no
  thief may take, and one made as the deque is full take the slots,
  counted for the monitor as before (`queued_forks`).
- **Waking.** A push onto a deque that held forks wakes a sleeper when
  none searches, by plain loads (`forkWake`), as Rayon's; lost wakes are
  recovered by the sleeper's and last searcher's looks at every deque
  (`hasWork`, `workPending`), by a switch that leaves forks waiting
  (`spread`), by the monitor, and by a yield check (`leftToIdle`).
- **The monitor.** Forks on a deque are out of the two-look rule's
  `queuedHere`. While a worker sleeps or searches, a deque holding forks
  at two looks gets a sleeper kicked (`notify`), with no signal, and the
  monitor looks every 50 µs meanwhile: #1168's rule that forks count as
  waiting while a worker is idle, kept by a kick rather than a stop of
  the maker. Forks still count for the slice (`workWaits`), and a take
  from the deque counts as a fiber started, as a take from the ring did,
  so a fork-join is not stopped for its own forks while a maker spinning
  on a flag its fork sets is. A yield check (`tick`) wakes an idle worker
  for forks and yields to them after a slice (`ownWorkWaits`).

- **A join out of order.** Chase-Lev takes back only the newest fork. A
  join of a fork below it, as `a = f()&; b = g()&; >a; >b` joins, moves
  the forks above it, up to four, to the "run next" slots (`spillNewer`),
  so the fork joined is the newest and runs inline (or by a handoff on
  `main`'s stack), and each moved fork is taken back from its slot when
  it is joined. None runs on the maker's stack ahead of its join: a fork
  run there before the maker goes on could wait for what the maker does
  next, a deadlock. bench/tasks' `hog` found this: without the move its
  `>a; >b` parked the maker each turn behind every core's 10 ms hogs,
  21.8 ms against main's 0.011.

## The board

Arms, each a `rig build --release` of the same source, run under
`tools/mac-claim` on a shared Mac (load 5-12 between claims), with
[board.py](deque/board.py), summed by [sum.py](deque/sum.py) (each arm's
placements pooled; ratios are paired medians per round, interquartile
range in brackets):

- `main`: origin/main 07d3b06c5; `inl`: ffj-inline 4b14d6213 (#1175);
- `deq`: this branch's first commit, 9e8b91132, at three code
  placements ([build.sh](deque/build.sh): 0, 3 and 6 never-taken prints
  at the end of `main`); `aa`: a copy of `deq`'s placement 0;
- `fast`: `deq` with the push and the join inlined, unsound
  ([arm-inline.sh](deque/arm-inline.sh)), at two placements;
- `rayon`, `rayon3`: fork-order's and the ceiling round's Rayon twins.

The `hog` fix came after; the boards below ran before it. It changes
only joins out of order, which fork.rig and fork3.rig do not make.

### fork3.rig: warm passes and `nil` (b, 10 rounds)

| row | main | inl | deq | fast | Rayon |
|---|---:|---:|---:|---:|---:|
| nil, 1 worker, ns a join | 66.4 | 28.9 | 26.3 (0.92 of inl) | 26.5 | 9.9 |
| nil, 10 workers, ns a join | 22.9 | 15.3 | 14.9 | 14.4 | 11.5 |
| psum, 1 worker, warm, ms | 4.59 | 3.66 | 3.79 (0.99 [0.92-1.01] of Rayon) | 3.66 | 3.79 |
| psum, 10 workers, warm, ms | 2.12 | 2.05 | 2.09 (0.99 [0.90-1.07]) | 2.08 | 2.17 |
| qsort, 1 worker, ms | 148.6 | 132.1 | 132.0 (0.89 [0.84-0.92]) | 133.7 | 151.1 |
| qsort, 10 workers, ms | 56.1 | 51.4 | 51.8 (0.97 [0.78-1.09]) | 53.8 | 54.6 |

`nil` at one worker: deq0, deq1, deq2 26.3, 26.3, 26.3 ns, `aa` 26.1;
placements move it by nothing.

### fork.rig: one psum and one qsort a process, cold (a, 16 rounds)

| row | main | inl | deq | fast | Rayon |
|---|---:|---:|---:|---:|---:|
| psum, 1 worker, ms | 8.45 | 8.06 | 8.47 (0.97 [0.78-1.21] of Rayon) | 10.26 | 8.83 |
| qsort, 1 worker, ms | 182.5 | 148.0 | 149.5 (0.91 [0.87-0.95]) | 149.3 | 167.6 |
| psum, 10 workers, ms | 2.99 | 2.93 | 2.90 (0.93 [0.90-1.03]) | 2.82 | 2.99 |
| qsort, 10 workers, ms | 67.2 | 63.8 | 62.9 (0.96 [0.90-1.03]) | 64.8 | 66.0 |
| peak, 1 / 10 workers, MiB | 782 / 696 | 502 / 676 | 502 / 669 | 502 / 670 | 585 / 761 |

The cold psum cell moves 20-40% from run to run here (its A/A arm, `aa`
against `deq`'s placement 0, reads 0.96 [0.74-1.12] of Rayon against
0.96 [0.84-1.27]): no claim on it either way. Its first pass at 10
workers, which on pup decides the 12-worker board through #1168's
spread, is 0.93 of Rayon here and level with `inl` (0.96 [0.82-1.09]).

### Each piece's share of a join (nil, 1 worker)

| from | to | ns a join |
|---|---|---:|
| main | #1171's record in the frame, #1175's inline run (`inl`) | 66.4 to 28.9 |
| `inl` | the deque (`deq`) | 28.9 to 26.3: 2.6 ns, 9% |
| `deq` | the push and the join inlined into the program (`fast`) | 26.3 to 26.5: nothing |
| `deq` | Rayon | 26.3 against 9.9 |

The deque takes off the slot's swap and its compare-and-swap at the
take, about what runtime.md §3 counted (one full fence of five). What
is left above Rayon is not the call into the runtime (the `fast` arm
removes it and gains nothing) but what a join does there: the state
swap and `Inline` record of `runHere`, `Control.finish`, the `host`
stores a cancel needs, and `tasks.waitInto`'s looks at the waiter's
cancel and deadline, each a call that reads the worker (`me()`).

## The inlined fast path under signal preemption

In a build preempted by signal, `spawn`, `startAt` and the wait are
never inlined into the program's code (`mustNotBeInCode`), because the
handler may stop a fiber at any instruction there and the fiber may
resume on another worker. The question: can the push and the join's
`popIf` be inlined soundly, with a flag the handler declines on as it
declines in runtime code?

**Not as plain Zig.** The deque has one owner: a push or a take reads
the worker (`me()`, a thread-local) and then writes its `bottom`. If a
stop lands between the read and the write and the fiber resumes on
another worker, it writes the first worker's `bottom` as if it owned it,
while that worker's new fiber pushes and takes there too: two owners,
which Chase-Lev does not survive (a fork taken twice, or lost). A flag
would have to be set on the thread the fiber runs on, atomically with
that read, and plain code cannot do so:
- the flag's address is a thread-local's, which LLVM treats as fixed
  within a function and may compute once and keep across a stop, or
  across a call that parks and resumes on another thread; this is why
  every read of the worker goes through `me()`, never inlined. Set
  through a kept address, the flag lands on the old thread;
- on arm64 the address takes at least two instructions (`mrs
  tpidrro_el0` and a load, or the TLV thunk on macOS), and a stop
  between them moves the fiber with the old thread's pointer in a
  register;
- a flag in the fiber instead moves with it, but the fiber is found
  only through the worker (`current`), the same read.

**What would be sound** is a restartable sequence: the push's and the
take's owner steps written as one inline `asm` block, which LLVM cannot
split or cache across, reading the worker from the thread register
inside it (`%fs:` with the initial-exec offset on x86-64 Linux, one
instruction; `tpidrro_el0` and a pthread TSD slot on arm64 macOS), and
marked so the handler, on finding the program counter inside such a
block, declines the stop and leaves it owed, as it declines in runtime
code. That is per-target assembly and a change to the handler's
decision on both targets, its own reviewed change.

**What it would buy** is measured by an unsound arm, `fast`: this branch
with `startAt` and the wait inlined as a build with yield checks has them
(`startAtIn`, `waitEndIn`) and `me()`'s check removed, built only to be
timed: nothing (`nil` 26.5 ns a join against 26.3; psum and qsort level,
above). The two calls a fork and its join make into the runtime cost
less than this board resolves; the restartable sequence would not pay
for its assembly, and is left out.

## What is left, and what next

- psum at one worker is a tie with Rayon on the Mac (0.99 warm, the cold
  cell in noise), not yet a win. The join's 16 ns above Rayon's is about
  65 µs of a 3.7 ms pass, under 2%. What remains is the work `runHere`
  and `tasks.waitInto` do at a join (above), not the queue.
- pup: psum's first pass at 12 workers, against main's 3.79-4.00 ms and
  Rayon's 4.65, with #1168's spread now made by the push's wake and the
  monitor's kick rather than a stop of the maker (the Rig session).
  With forks in the slots, #1168 found that waking one idle worker a
  look left that pass 37-44% slower on pup than stopping the maker; with
  the deque the push onto a deque that holds forks wakes a thief, which
  steals the oldest and whose own pushes wake the next, so the kick is
  only recovery. The Mac's 10-worker cold psum, 0.93 of Rayon and level
  with #1175, says the spread holds there; pup must say so for 12.
- Trig's light gate (pup).
