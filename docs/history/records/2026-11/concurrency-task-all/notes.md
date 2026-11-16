# `task.all` of tasks that give no value

The owner, 2026-11-03, for v0.3.1: "let task.all accept tasks that give
no value, so `task.all(f()&, g()&)!` waits for subs". It is the visible
alternative to an implicit wait at a scope's end, which was set aside
because it would hide a failure point at a dedent (North Star 3). The
feature accepts more programs; the review's fixes merged into it
(below) reject two kinds that compiled before.

## What the call gives

When no task gives a value, `task.all` gives nothing, as a `sub` does:
the checker types it `Void`, or `Void!E` when a task can fail, with the
same wait set (`Checker.waitSet`) as a valued wait. It is recorded as a
`sub` call (`is_sub`), as `par.each`'s is, so it stands as a statement,
`!` passes its failure on, and `catch` handles it, each through the
paths every fallible `sub` call already takes. Binding it is rejected
as binding any `Void` ("`x` would be bound to a value of type `Void`"),
and `!` on an infallible one as on any value that cannot fail.

Which of the two the call gives is a fact the checker records once
(`recordTaskJoin(call, values)`, shown by `rig check --facts=sema`),
and emit passes it to `rig.waitTasksInto` as a compile-time flag. The
runtime collects the tasks' values in a tuple (a task that gives
nothing holds a `void`) and returns it when the flag says so, nothing
otherwise; it does not work out from an instance's types which to give.
Cancel on the first failure, the failure's fields passing to the
waiter's slot, and the drops of the others' results are the same code
as before.

## Generic bodies: the review's regression

The first build (d0f6177a9) let the runtime decide from the instance's
types: `TaskValues` gave `void` when no task of the instance gave a
value. A generic body is checked and emitted once, so
`sub both[T](a: Task[T], b: Task[T])` with `x, y = task.all(<a, <b)`
was typed as giving two `T`s, and `both[Void](say(1)&, say(2)&)` then
failed in Zig ("type 'void' does not support indexing"), where main
built and ran it. The fix is the recorded fact above. In a generic body
a task of a type parameter's type counts as giving a value, a `T`,
whatever an instance binds it to, as on main; SPEC §18 says so. So
`both[Void, Int](say(1)&, sq(3)&)` through `task.all(<a, <b)` of a
`Task[T]` and a `Task[U]` waits for both, where the same tasks written
out are rejected as a mix: the body cannot know, and the rule is the
body's. The review's probes are cases ("sets all generic bound",
"sets all generic statement", "sets all generic mixed", "sets all
generic fun").

## Why a mix stays rejected

`u, o = task.all(user()&, log()&, orders()&)!` would need several
results with a hole where `log` gives nothing, a shape of its own, or
a rule that skips positions, which would make a result's position
differ from its task's. Neither exists today, and the brief said not to
invent one. A mix is rejected, naming the first task of each kind:

> `task.all` gives each task's value, or nothing when none gives one,
> and `say(1)&` gives none while `sq(2)&` gives one: wait for the tasks
> that give none in a `task.all` of their own, or each on its own, `>t`

The question for the owner is whether a mixed call should one day give
the values alone, in order, skipping the tasks that give none; its
gain is that the first failure among all of them cancels the rest.

## Ownership and the reference checker

Nothing changed in either. The ownership checker treats `task.all` as
an ordinary call whose arguments are tasks, whatever they give: each
task keeps its call's loans until the call returns, and a task lent to
write is rejected in `task.all` (T2: it stays where it is bound), for
tasks that give nothing exactly as for tasks that give values (the case
"sets all subs write"). The reference checker (`bin/rig-oracle`) has no
rule of its own for `task.all`; its records did not change.

## Cases

In `test/rig/concurrency-sets.rig.test`, all with `seeds: 20`:

- "sets all subs": two subs that read `?xs`, waited together as a
  statement; `!xs.push` after the wait shows their loans ended.
- "sets all subs fail": the first to fail cancels a sleeping sub (its
  `defer` prints), and `!` passes the error to the caller's `catch`.
- "sets all subs catch": `catch` on the wait as a statement, for one
  that succeeds and one that fails.
- "sets all subs fail fields": a failure's fields pass on.
- "sets all subs write" (fail): a task lent to write stays rejected.
- "sets all mixed" (fail): the mix, with its message.

SPEC §18 gains an example (a `catch` over two subs' wait), so the doc
suite runs it too. No `rig pending` example existed.

## Docs

SPEC §18, STD's std.task table, CONCURRENCY.md ("Tasks, as in Go" and
the styles table), design/concurrency.md, CHANGELOG, HANDOFF; the
IDEAS.md entry is removed now that it is built. learn/04 does not
mention `task.all`.

## Gates (Mac, 2026-11-16)

- Core suite, `tools/heavy --class correctness swarm test/rig.rip -w 4
  -q`: 12,068 jobs, none died (765 s).
- `tools/emit-diff` against the merge base: the programs' own Zig is
  identical in all 36; only the runtime file `rig/tasks.zig` written
  beside 34 of them differs (+23 -11), the comptime types above.
- Guards, under `tools/mac-claim`: json within 0.0% of its baseline on
  all six files; hash within 0.0% on every row but `map int-churn`
  (0.7% fewer instructions) and `map text-churn` (1.2% fewer); text
  within 0.1%; check 0.1% more instructions (2,158,935,349 against
  2,157,462,149), its scaling exponents 1.00 to 1.02.
- The Trig and loco light gates are not run here (nothing on pup); the
  change touches the compiler and the runtime, so they remain before
  merge.

## The review's older findings (branch `task-all-fixes`, merged here)

Found by the independent review of d0f6177a9, on main before this
change; each a commit with its failing case first.

1. **A leak in a generic body.** `heldTypeVars`, which finds the type
   parameters a value holds, did not walk several results, though
   `holdsIn` does, so a generic body that discarded `(T, T)` (a
   statement `task.all(<a, <b)`, or a call of `-> (T, T)` alone) put no
   requirement on `T`, and `both[String](...)` leaked both values. Now
   it is rejected as discarding one `T` is ("the generic body discards
   a value that holds a `T`"). Case: types-generic, "generic body
   discards results".
2. **A task that cannot fail, canceled by `task.all`.** SPEC §18 and
   design/concurrency.md say a task that cannot fail cannot be canceled
   and runs to its end; the audit (revamp-runtime/audit-concurrency.md)
   kept "Only a fallible task can be canceled". Yet when one task of a
   `task.all` fails, the wait cancels every other, and an infallible
   sibling's `time.sleep(...) catch` sees `Stop.canceled`; the sibling
   still runs to its end and gives its value, which is dropped. A
   task's drop does the same only when the dropper is itself canceled
   (`__rig_drop`). Whether the docs or the behavior is meant is not
   settled by the record, so neither changed: an owner question.
3. **The hint for a task lent to write** dropped self's `!` (`t =
   b.bump()&`, itself rejected); it writes `t = !b.bump()&`. Case:
   concurrency-task, "task write loan bound self".
4. **A fallible `sub` returned a value that gives nothing**:
   `return say(1)!`, `return ok()`, `return f() catch ...` were
   accepted in a `sub` marked `!`, rejected in one that cannot fail.
   Now rejected alike. A scan found no such `return` in the repository,
   std, examples, Trig (its src modules checked with the fixed Rig), or
   loco, so the rejection is listed in CHANGELOG's "Upgrading" with no
   migration script. Cases: effects-misc, "fallible sub returns no
   value", and concurrency-sets, "sets all subs return".

## Gates after the review (Mac, 2026-11-16)

- `task-all-fixes`: core suite 12,067 jobs, none died; emit-diff
  identical in all 36 programs; guards: json 0.0% on all six files,
  hash 0.0% to 0.1% but `map int-churn` (0.6% fewer instructions) and
  `map text-churn` (1.2% fewer), text within 0.1%, check 0.4% fewer
  instructions.
- `task-all-subs` with it merged: core suite 12,079 jobs, none died;
  emit-diff: the programs' own Zig identical in all 36, the runtime's
  `rig/tasks.zig` beside 34 differs (+27 -17); guards: json 0.0%, hash
  0.0% to 0.1% but `map int-churn` (0.7% fewer) and `map text-churn`
  (1.2% fewer), text within 0.1%, check 0.4% fewer instructions.
- The Trig and loco light gates remain before merge (nothing on pup).
