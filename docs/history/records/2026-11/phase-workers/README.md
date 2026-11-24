# Phase-aware worker count: a design note, parked (2026-11-23)

Rig - Final, for Rig (foreman), with the owner's approval. A design only: nothing is built. It answers one question.
Can a Rig program run one phase (Trig's load) on every hardware thread, then narrow to one worker per physical core
for the next phase (the check), without slowing the check or using more memory?

## 1. What is measured already

- **The gap.** tsrs's load keeps 7.2–9.5 of pup's 12 hyperthreads busy and binds inside it. Trig's 6 workers keep
  4.5–6.7 busy and bind afterwards. Trig's load plus bind is 13–19 ms behind tsrs per project at every count
  (slot 734, front-speed.md).
- **A fixed 12 (slot 731, RIG_WORKERS=12), summed over nuxt, webpack and next-root:**

| | wall | parse | bind | check | peak RSS |
|---|---|---|---|---|---|
| c2 | 1989 → 1970 ms (1.0% faster) | 184 → 169 | 46 → 39 | 1647 → 1652 | 6.6% higher |
| c4 | 1399 → 1395 (0.2%) | 180 → 169 | 45 → 38 | 1063 → 1077 | 5.8% higher |
| c8 | 1235 → 1233 (0.1%) | 173 → 169 | 41 → 38 | 904 → 914 | 2.5% higher |

- **Wide, then narrowed (W′, slot 424, 2026-11-14; dropped).** Rig branch lower-workers (26f90d6c7) let
  `task.workers(n)` lower the count, and Trig narrowed to `task.fast_cores()` before the check.
  - The front end gained (supabase c4 parse plus bind went from 276 to 248 ms).
  - Check still rose (formbricks c4 went from 0.917 to 0.984 s).
  - Peak RSS rose by 4.4–10.7%.
  - Hyperthreads made the bind's work 1.5 times larger (231 to 349 worker-ms).
  - The record's reading: the load's data, spread over 12 workers' heaps, is what the checkers read and grow from.
    Narrowing cannot give it back (target-b1.md, "W′ verdict").

**Ceiling.** If the check and RSS stayed level, the gain would be W's front-end saving. That is 22, 18 and 7 ms over
the three projects: **1.1%, 1.3% and 0.6% of wall** at c2, c4 and c8. With only the load wide (the bind narrow) it
is 0.8%, 0.8% and 0.3%. Both are under Trig's 1.5% bar. Even closing tsrs's whole front-end gap would be about 3% of
c4 wall.

**Narrowing is the easy part, and it was built and raced. The hard part is the memory left in the wide workers'
heaps.** The design below covers both, and stages them so the memory question is answered before any API is built.

## 2. The API

The phase is owned by a value. Its scope is the phase, its drop ends the phase, and it stays in the task that made it.

```rig fragment
use std.task

fun new_program(...) -> Program
  wide = task.widen()           # every hardware thread of the fast cores runs tasks
  files = load(...)             # par.each over the file queue
  <wide                         # back to one worker per fast physical core
  bind(files)
```

- **Who ends the phase:** the program, by dropping the value (`<wide` or the end of its scope), not the last task
  of a group. Trig's load is a queue the coordinator feeds, not one group.
- **Why a value, not `task.workers(n)` called twice:** the drop runs on every path, including early returns and
  failures, so the narrowing cannot be forgotten. Only the task that widened can narrow, so two libraries cannot
  fight over the count.
- **Rules.**
  - A widen inside a widen does nothing.
  - A deterministic run, a run on one worker, and `--singleThreaded` make no thread; the drop then does nothing.
  - The value cannot be sent to another task.
- **The width.** "Wide" is every hardware thread of the fast cores: 12 on pup, 10 on the Mac (no SMT, so no change
  there). "Narrow" is what the program had before, Trig's `fit_workers`. No other width is offered.
- **Weighed and kept as the fallback:** a task-group option, `Tasks(width: .threads)`, whose extra workers run only
  that group's tasks. It isolates the check perfectly, but Trig's load is not one group, and it adds a second kind
  of worker.

## 3. Idle workers, stacks and heaps (RSS)

1. **Drain.** The drop lowers `workers_len`, and thieves stop seeing the retiring workers. Each one finishes its
   current fiber and pushes its slots and ring to the global queue. The drop does not wait for this.
2. **Sleep.** A drained worker sleeps on its own futex, off the sleepers' list, never woken by `notify`. The next
   `widen` wakes it rather than starting a thread.
3. **Give back memory. This step decides the design.**
   - **Stacks:** a retiring worker's pooled fiber stacks get `madvise(DONTNEED)`, as idle-heap trimming does now.
   - **Heap adoption (new):** each retiring worker's heap is adopted by the worker on the same physical core (on
     pup, worker k+6 by worker k). Its segments, span lists and pending remote frees move to the adopter. The check's
     allocations then reuse the free space the load left instead of growing new segments, which is the RSS rise W
     and W′ measured.
   - **What adoption cannot fix:** where the load's live trees sit. If W′'s check rise comes from reading data
     scattered over 12 heaps, adoption does not help. Trig's proposed capability, allocation into a chosen arena
     from a task, attacks the same scatter from the other side and may be the better first lever.

## 4. Fit with CORE and the scheduler

- **No ownership rule changes.** The value is a library object with a drop, visible in the IR as `<wide` or the
  scope's end. CORE needs no change.
- **One preemption way per target.** Wide workers are ordinary workers under the same monitor and yield checks.
- **Tasks, not threads.** The program asks for width for a phase; it never names a thread.
- **The scheduler already grows** (`growWorkers`). Narrowing adds the drain, the sleep and heap adoption. The only
  hot-path change is one index check at the top of a worker's idle loop; nothing runs per task.

## 5. How Trig would use it

Trig's answer: a scope in `src/execute/tsc.rig` around `compiler.new_program(...)`, after `fit_workers`. Because of
W′'s 1.5-times bind inflation, this note recommends Trig's second point instead: widen inside `new_program` and drop
at `drop_loader` (`src/compiler/fileloader.rig`), so the load runs wide and the bind narrow. That is two lines.

## 6. Naming candidates

1. **`task.widen()` → `Wide`** (recommended: a known word for what it means, one mechanism)
   - Declaration: `pub fun widen() -> Wide`.
   - Error: `tsc.rig:301:3: a task.Wide stays in the task that made it; '>t' would send it away`.
   - Sentence: "The load runs wide: `wide = task.widen()` puts every hardware thread to work until `<wide`."
2. **`task.burst()` → `Burst`**
   - Declaration: `pub fun burst() -> Burst`.
   - Error: `tsc.rig:301:3: a task.Burst stays in the task that made it; '>t' would send it away`.
   - Sentence: "Trig loads in a burst: `b = task.burst()` widens, and `<b` narrows back."
   - Weakness: "burst" already names the scheduler's burst of spawns.
3. **A lowering `task.workers(n)` plus `task.threads()`**
   - Declaration: `pub fun threads() -> Int`.
   - Error: none is possible; the call returns `false` in a deterministic run.
   - Sentence: "Trig calls `task.workers(task.threads())` before the load and `task.workers(task.fast_cores())`
     after it."
   - The fewest new words, but an early return skips the narrowing. This is what W′ did.

## 7. Risks and gates

- **c1:** on one worker `widen` does nothing. Gate: c1 instructions identical for tasks, actors and Trig.
- **tasks and actors benchmarks:** only the idle-loop check is shared. Gate: instruction guards, plus Mac and pup
  E-core rows within 2%.
- **RSS:** W and W′ both broke this (2.5–10.7% higher). Gate: summed peak RSS over 17 projects at c2/c4/c8 within
  the A/A, and no project over 1% higher.
- **Check:** W′ broke this too. Gate: check within the A/A on every project at c2/c4 (paired rounds, sign test).
- **The ceiling is under the bar:** 1.1–1.3% at best, 0.8% with the load alone. The coordinator, not the workers,
  ends the load on P-cores (slot 733), so extra width has little to speed up.

**Staging:**

1. A ceiling arm with no API: W′'s branch plus heap adoption, load-only narrowing, switched by an environment
   variable in one binary. Three projects at c2/c4 in one pup slot, with an A/A arm. Go on only if check and RSS stay
   level.
2. Only then build `task.widen()`, with docs and gates.
3. If the check still slows, park this behind Trig's arena capability.

**Recommendation:** run stage 1 alone (one pup slot) and decide from it. The best gain is about 1% of wall, and both
earlier tries failed on memory.

## Decision (2026-11-23)

The owner, through Rig: parked, with no slot. Its ceiling is under the bar, and W′ already failed. Revisit it only
alongside allocation into an arena a task chooses. If it is ever built, its name is `task.widen()`.

Sources: slot 731's 12-worker rows (pup `/zfs/trig-pup/c8-check/slot-c8fix-w12/runs`); W′'s verdict (slot 424,
`target-b1.md`, "W′ verdict", in the Trig revamp inputs); Trig's front-speed notes (slots 733 to 735).

## Measured (2026-11-24)

The owner then approved one race of the scratch build, [race-754.md](race-754.md):
- Summed wall is level in every arm (0.994-1.002 of main).
- The front end is 3-7% faster and the check about as much slower.
- Peak memory is 2.6-6.1% higher at c2 to c8.

It is a measured negative, the shape of W′. The scratch is kept as `archive/phase-wide`.
