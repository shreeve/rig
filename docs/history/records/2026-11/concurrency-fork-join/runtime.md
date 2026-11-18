# Free fork-join: the runtime and the scheduler (expert 1)

**1. The record.** A `&` whose `Task` stays in its maker's frame (only waited, canceled, dropped or viewed, out of scope before its site reruns) keeps its record, `sched.spawnIn`'s `Full`, in a frame slot: a storage fact, its bytes in the owner's reach, emitted as `spawnAt(&slot, ...)`. Its `Header.destroy` does nothing; `waitInto` and `__rig_drop` stay. `Done` already promises that no waker touches a record after its waiter reads `ended`; an isolate stops its tasks before a panic leaves their stack.

**2. Inline.** One rule: the task runs on its waiter's stack when the waiter has the room the task's own stack would give. `need` is `inlining.denseDepths`'s bound per site, kept as a number (`task_depths` replaces `dense_calls`), plus `frame_slack`. With no bound (psum and qsort recurse) it is a whole stack: large stacks reserve 128 MiB, so a recursive task inlines while its waiter has used under half, never with less room than today.

`Header.waitEndIn` tries a new `sched.runHere` before `handoff`. It claims the task, swaps in its `TaskState` (all but `stack_guard`), points `Control.fiber` at the waiter (`interruptForCancel` sets each flag of the inline chain), and unblocks the waiter for the deadlock walk. It saves a catch point (twenty stores) that `abandon` returns to, calls `fiber.run`, restores, and stores `ended`: no allocation, stack, or switch.

**3. Stealing.** These tasks go on a Chase-Lev deque per worker. The owner pushes and pops the bottom, with a compare-and-swap only on the last task. Thieves take the oldest, the largest piece, one at a time, as Rayon's do. `>t` pops the bottom when it is `t` (Rayon's id check), else waits as now. A push onto a deque that is not empty wakes an idle worker.

**Costs.** An unstolen fork: 51 ns (`chain`) to about 10–15 ns. Yet psum's 4,095 forks cost about 21 µs a core, under 1%. The gaps lie elsewhere (the ramp, parks above the slots' four levels, the loop, qsort's appends): measure each.

**Defaults**
1. Frame record by a storage fact; `destroy` does nothing.
2. One room rule, needing 64 MiB when no bound is proven; large stacks reserve 128 MiB (SPEC's "64 MiB" becomes "at least", the owner's).
3. A catch point for panics.
4. A fork deque: its owner takes the newest, a thief one.
5. `RIG_SCHED_STATS` counts inline runs, parks and stolen forks; `bench/fork` gains GRAIN 256.
