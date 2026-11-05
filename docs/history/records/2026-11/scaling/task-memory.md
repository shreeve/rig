# A finished task's memory, and faulting in ahead for busy workers (2026-11-04)

**Question.** Trig's NEEDS 73 and 74, from its concurrency panel of
2026-11-04 (changes 2 and 7; the owner approved them that day):

- **73.** Release a finished task's memory in one step, with no drops
  run, while other tasks still run, so that Trig can end each checker
  on its own idle core and the exit tears down only the slowest.
- **74.** Idle workers fault pages in ahead for busy ones: each checker
  pays `MADV_POPULATE_WRITE` inline, 1.6-2.0% of cycles
  ([investigation.md](investigation.md), section 2).

Each lands only if Trig's timing clears the bar: more than 1.5% faster,
or at least 1% fewer instructions on one checker, with peak memory no
higher. Measure first.

**Answer.**

- **74 is not worth building.** On the critical path, the populate
  calls are 1.1% of the wall on ts-pattern at four checkers and 0.45%
  on zod3, before any loss to predicting what a busy heap fills next.
  With one worker per core, as Trig's runs pin them, there is no idle
  worker at one checker, and at four only in the tail.
- **73 without drops needs a rule.** Nothing in the Core makes a
  task's memory the task's alone. A release in one step is sound only
  under a new boundary whose values cannot leave it but by a visible
  copy. That is a rule change, for the owner (below).
- **What 73 asks for with drops needs no rule, and works today.** A
  checker dropped in its own task gives its Tables back then. Rig's
  remaining share is the heap pages the drop leaves resident, a few
  milliseconds at most. Measure it once Trig drops its checkers in
  their tasks (the panel's change 1), before building anything.

## 74: faulting in ahead

**Where it is paid.** `alloc.zig`'s `prefault`: a heap that does much of
the program's work (`faultsAhead`) faults in each 1 MiB stretch of a
segment as it reaches it (`newPage`), and the likely-filled part of
each large block, with one `MADV_POPULATE_WRITE` each. The call is the
cheap form of the faults it replaces: one trap for a stretch rather than
one per 4 KiB page.

**Measured.** Trig's PGO build of [investigation.md](investigation.md)
(`/zfs/trig-pup/runs/eq-new`, Rig 3fe58d632; `alloc.zig` and
`table.zig` are unchanged on main since). Every `madvise` call was timed
from its entry to its exit by tracepoint, with CPU time per thread from
`task-clock` samples. Ten runs per arm on pup's E-cores 16-19, outside a
timing slot, with no timing job running and builds on other cores
([prof74.sh](task-memory-data/prof74.sh),
[m74.py](task-memory-data/m74.py), [m74.txt](task-memory-data/m74.txt)).
The critical thread is the one whose last event is latest: `main`'s,
which runs the serial head, a checker, and the end. Medians:

| | ts-pattern, 1 checker | ts-pattern, 4 | zod3, 1 | zod3, 4 |
|---|---:|---:|---:|---:|
| wall, ms | 1,301 | 522 | 321 | 170 |
| populate, all threads, ms | 17.0 | 17.6 | 9.6 | 8.9 |
| populate calls, all threads | 220 | 309 | 151 | 137 |
| populate on the critical thread, ms | 17.0 | 5.6 (3.7-10.2) | 9.6 | 0.7 (0-8.4) |
| of the wall | 1.3% | 1.1% | 3.0% | 0.45% |
| the critical thread's time after the first other checker ends, ms | | 184 | | 62 |

(The `task-clock` samples were capped by perf's rate limit of 1,000 a
second, so CPU times read low. The table divides by the wall, which is
exact.)

- **The ceiling is below the bar at four checkers**: if every populate
  on the critical thread moved to an idle worker, ts-pattern would gain
  1.1% and zod3 0.45%. A helper cannot know exactly which stretch a busy
  heap fills next, nor be sure to reach it first, so a real build gets
  less.
- **One checker has the largest share and no idle worker.** On a pinned
  core the program has one worker. Unpinned, the ceiling is 1.3% on
  ts-pattern and 3.0% on zod3. Trig's races and benches pin.
- **At four checkers on four cores there are idle workers only in the
  tail**, after the first checker ends (184 ms of ts-pattern's 506, 62
  of zod3's 163), and only for the stretches of the serial head that
  run on `main` alone (2.3-2.9 ms of populate a run on ts-pattern).
- The packed Tables were not taken
  ([table-arena.md](table-arena.md)), so these are the numbers on main
  too.

Not prototyped.

## 73: a finished task's memory

**What the Core says.** Nothing in CORE.md or concurrency.md makes a
task's memory the task's alone, and the allocator has no such thing:

- **Ownership moves; memory stays where it was made.** A heap is a
  thread's (`alloc.zig`), shared by every task its worker runs. A block
  belongs to the heap that made it. A value that moves to another task
  keeps its blocks there, and a free from another thread goes back on
  the owning heap's remote list.
- **Values leave a task in several ways:** its result; a send on a
  channel or a call to an actor; a write through a `!` view of a value
  outside it; a task it starts that outlives it; and a `*Frozen` handle,
  counted atomically, which goes to any task (CORE §9).
- **What makes boundaries sound today** is concurrency.md's "loans
  point only from tasks into their owners, never the other way". That
  covers views, not owned values: a task's result is an owned value
  whose blocks the task made.

So "nothing outlives the task" is not a fact the compiler knows.
Freeing a task's blocks wholesale is sound only for blocks nothing
reachable holds.

**The form with no drops needs a rule.** A sketch:

- `task.arena(f)` runs `f` with a heap of its own, and gives back
  `+f()`, the result cloned into the caller's heap. The clone is the
  visible copy that lets the result leave. It then gives the heap's
  segments and large blocks back to the system at once.
- It is sound only if no block of that heap is reachable afterwards.
  So `f` would take only plain data and read views of values that hold
  no channel, actor, `Cell`, task, or handle, and would start no task
  that outlives it. That extends `task.isolate`'s rule ("nothing
  outside `f` may be lent to it to write") with a rule on what may
  leave.
- The runtime would switch a thread's current heap whenever a fiber
  of `f` resumes or pauses, in `sched.zig`.

That is a new ownership rule, so it goes to the owner first (CORE §10).
Its gain over the rule-free form below is the drops' own CPU, about 3-4
ms a checker ([scaling.md](../../2026-10/perf-stage/scaling.md): 15-20
ms to drop the program and four checkers). That time is spent on cores
that would otherwise idle, so it does not show in the wall.

**The form with drops needs no rule, and works today.** A checker
dropped at the end of its own task:

- runs its drops on that task's worker, which would otherwise idle;
- gives back its Tables' ranges with `MADV_DONTNEED` (`table.zig`'s
  `unreserve`), the source of most of its mappings and 4 KiB pages
  (1,304 mappings at eight checkers; [investigation.md](investigation.md),
  section 3);
- leaves its small blocks on its heap's free lists, their pages
  resident, and its large blocks kept and resident (`keep_resident`):
  "Segments are never returned to the system".

So after Trig's change 1, the exit still tears down three things:

- the finished checkers' heap pages;
- the page tables of the Tables' ranges they gave back, which stay
  until a range is used again;
- the slowest checker and the program, as now.

The panel estimates 3-6 ms for the first two at four checkers on
ts-pattern, inferred, not measured. That is 0.6-1.2% of a 510 ms run,
below the bar unless more is found. The Rig change it would call for,
a heap whose worker goes idle giving back its kept large blocks and the
pages of segments that hold nothing live, is `alloc.zig`'s alone. But
whole free segments need live counts the heap does not keep today,
which would cost every free.

## What this leaves

- **74:** closed at the ceilings above. Look again only if a run's
  critical path shows populate above 1.5%, for instance unpinned at one
  checker, where zod3 reaches 3.0%.
- **73, with drops:** Trig's change 1 needs nothing new from Rig. Once
  it lands, measure its exit (`exit_group` to reaped, with
  [exit.py](data/exit.py)), and split the rest into heap pages and
  page tables. Build the idle heap's release only if that rest clears
  the bar.
- **73, without drops:** the owner's call: the rule sketched above, or
  not now.
