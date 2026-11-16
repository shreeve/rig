# Free fork-join: design round brief (2026-11-15)

The owner approved free fork-join on 2026-11-15 ("I love everything you
suggested here to fix. All of the concurrency items"), after his
direction of 2026-11-07 (docs/history/records/2026-11/fork-join/decisions-2026-11-07.md):
"One `&` for every kind of task. Free fork-join is a fast path inside it,
not a second pool", which he called "INCREDIBLY POWERFUL and simplifying";
"`par` splits its work by what is left", in the same round; and a design
round of three before code. Fixed points, never reopened: one model,
`f()&` and `>t` on real stacks; no async, no colored functions, no
state-machine tasks; Rig never adds threads; one preemption way per
target.

## Where it stands (Mac, `--release`, 2026-11-15)
Fork-join is 18% behind Rayon on a parallel sum and 53% behind on a
quicksort (docs/history/records/2026-11/concurrency-bench-remeasure/,
with the harness and a new Rayon twin in `fork/`). `sched.handoff`
already runs an unstarted task the moment it is awaited, on the task's
own stack. Dense stacks are built (docs/internals/scheduler.md,
"Stacks"). A measurement of what Rig's checks cost on these benches,
against what the design costs, is in progress
(records/2026-11/concurrency-checks-cost/ when it lands).

## The idea (from the 2026-11-04 review, records/2026-11/concurrency-review/SYNTHESIS.md §B)
An awaited task that has not started runs on the waiter's own stack, as
`rayon::join` runs `b`: its record lives in its maker's frame (a task
never outlives the scope that made it), so a fork nobody steals costs a
queue push and a plain call. It is taken only when the task has not
started, its maker waits for it, the wait has no deadline, and the
task's frames fit. Every other task stays a fiber. The program still
writes `f()&` and `>t`.

## Read
AGENTS.md (North Star; "A speed feature pays for its lines"; vocabulary:
tasks and cores, never threads; self, never receiver), docs/CORE.md
(sentence 6, tasks), docs/CONCURRENCY.md, docs/design/concurrency.md
("Loans and structure", "Failure", "The engine"),
docs/internals/scheduler.md, SPEC §18, the fork-join decisions record,
the 2026-11-04 review (SYNTHESIS and rayon-tokio.md in
~/Data/Code/Claude/rig/rig/concurrency-review/), src/sched.zig
(`handoff`, run-next slots, stealing), src/tasks.zig, src/emit.zig's
task paths, src/inlining.zig (`denseDepths`), and Rayon's `join` source
if available (~/.cargo/registry).

## Open questions for the round
1. Where the task's record lives and who frees it, so a task run inline
   costs no allocation; what emit and the checkers must record (a fact,
   never an emit decision).
2. How the waiter runs the task inline: on its own stack, with what
   bound on the task's frames (the stack-depth facts dense stacks use),
   and what happens when no bound is proven (recursion: quicksort).
3. Stealing: run-next slots versus a per-worker deque of forks; whether
   a thief takes one task or half; `RIG_SCHED_STATS` on psum to decide.
4. Failure: a panic in an inline task ends only that task and reaches
   its waiter at `>t`; cancellation and `Stop` stay as they are; defer
   and drop order unchanged.
5. `par` splitting by what is left (Rayon's adaptive splitting), and
   loops free of yield checks where signals preempt.
6. What is measured, and the bar: psum and qsort against Rayon on the
   Mac and pup, a `bench/fork` row; no other row slower (bench/tasks,
   actors, net, http, Trig).
7. What, if anything, changes a rule the owner must see (CORE, SPEC,
   a visible behavior). The default is nothing visible changes.

Each report: at most 400 words, to this folder; Rig vocabulary;
timeless prose; end with your recommended defaults as a numbered list.
Read-only: no code changes, no builds, nothing on pup or burst.
