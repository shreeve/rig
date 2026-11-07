# Fork-join and preemption: the owner's direction (2026-11-07)

## Where it started
The fork-join row against Rayon (Apple M5, `--release=fast`, best of 10 interleaved runs, under some load):

| row | Rig | Rayon |
|---|---|---|
| psum, 2^25 Ints in pieces of 8,192 | 15.2 ms | 2.7 ms |
| qsort, 2^22 Ints, halves in owned Lists | 125.5 ms | 69.4 ms |

**What psum pays that Rayon does not:**
- A fiber, a 16 KiB stack and two switches for each of its 4,096 tasks, even one its maker takes straight back.
- A yield check on every element of the summing loop, which probably keeps LLVM from vectorizing it.
- Steals of the newest tasks one at a time from the run-next slots.

**What qsort pays:**
- An element-by-element append where Rayon copies with `extend_from_slice`.
- No in-place form: that needs two tasks holding write views of one List's halves, which SPEC lists as pending.

A rerun with a build that preempts by signal, and so has no yield checks, separates the first two of psum's costs.

## Decided
1. **One way to stop a long computation per target, chosen by the compiler, with no option** (ROADMAP, "Concurrency"):
   - a signal wherever a thread can be interrupted: Linux x86-64 and arm64 macOS now, then Linux arm64, and Windows by suspending the thread;
   - yield checks where none can, as in WebAssembly and freestanding code;
   - yield checks on every target for seeded test runs and for a program that makes local tasks;
   - turning preemption on by default still waits for the owner's yes.
2. **One `&` for every kind of task.** Fork-join at no cost is a path inside the same `&`, not a second pool or a second syntax.
3. **`par` splits by what is left**, as `par_iter` does, in the same round as the fork-join. That splitting, together with loops free of yield checks, is the half of Rayon's speed that fork-join alone does not give.
4. **The fork-join design round starts once #1001 lands**, with a panel of three (the owner: "YES").

## Why Rig can offer this
- **Tasks are owned by their scope.** A task cannot outlive the frame that made it, so its record can live in that frame. Rayon gets this from closure lifetimes, and Go cannot get it.
- **The fast path is half built.** `sched.handoff` already runs an unstarted task the moment it is awaited, on the task's own stack. The new step runs it on the waiter's stack and drops the allocation.
- **One model.** Every task is a fiber on one work-stealing scheduler that also does I/O. Rust needs Tokio's state machines and Rayon's thread stacks, which do not mix.

The free path is taken only when the task has not started, its maker waits for it, the wait has no deadline, and the task's frames fit. Every other task stays a fiber, as now: connection handlers, actors, channel stages, waits with deadlines.

## For the design round
- A panic in a task run inline must end only that task and reach its waiter at `>t`.
- A recursive task, whose stack use no bound proves, needs room: stacks that grow by segments (ROADMAP, small stacks).
- Stealing: whether a thief should take more than one task from the run-next slots, or fork-join should use a deque, decided by `RIG_SCHED_STATS` on psum.
- `par`'s splitting by what is left.
- The targets: psum and qsort against Rayon, kept as a `bench/fork` row on the Mac and pup.
