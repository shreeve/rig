# Free fork-join: semantics and soundness (expert 2)

**Sound by construction.** `>t` already waits for `t`'s end, even after a cancel or a deadline (`waitInto` cancels, then waits). Inline reorders nothing: loans point down; drops, `defer`s and `errdefer`s keep their order. An overflow stops at the guard.

**Failure.**
- *Waiting.* A parked inline task sleeps the whole fiber, as the waiter at `>t` would. `Blocked` nests, publishing the innermost, so the deadlock walk stays exact.
- *Cancel.* The canceler sets the waiter's flag, ends the fiber's wait, and sets a fiber bit. `t`'s stop check follows its parent link and cancels `t`, as `waitInto` passes it on. No other thread walks the chain, whose frames get reused.
- *Deadlines, isolates.* `t` keeps the `TaskState` it took at spawn. A fallible wait under a deadline never inlines.
- *Panics: no catch point.* Resuming the waiter would overwrite `t`'s abandoned frames, which `t`'s tasks may still view. Every wait passes a panic on, so the panic continues in place, as an inline actor method's does: each level is marked, its actors end, and its "a task this one waited for panicked" line is written.

**Structure.** Only the awaited task runs inline. Running others while waiting, as Rayon does, can deadlock on a channel. Sets, `task.all`, select and actor calls stay fibers. A waiter's pin is restored afterwards. Inline is off under `RIG_SEED`, as handoff already is, so seeds choose the same.

**What changes.** Source, IR and acceptance stay the same, so the oracle learns nothing. Storage records *record in frame*, counted in reach. Each site records a proven depth, or none. Visible: `RIG_SCHED_STATS`, and SPEC §18's "a fiber on a stack of its own".

**On runtime.md and measurement.md.** Agreed: the frame record, the deque's identity take, the `TaskState` swap. Disagreed: the catch point; chain-wide flag setting, which races with reused frames; 128 MiB stacks, a SPEC change for forks that measurement.md puts under 1% of psum. `par`'s failing chunk must stop its siblings itself.

**Defaults**
1. Inline only proven-bounded tasks, with room checked against the bound; unbounded ones keep handoff. SPEC's stack size stays.
2. No catch point.
3. Each inline task passes a cancel on to itself.
4. Single `>t` and drops only.
5. Off under `RIG_SEED`; tested with `RIG_WORKERS=1`.
6. SPEC §18 says "when that stack has room", as the actor idle path does.
