# `task.all` of tasks that give no value

The owner, 2026-11-03, for v0.3.1: "let task.all accept tasks that give
no value, so `task.all(f()&, g()&)!` waits for subs". It is the visible
alternative to an implicit wait at a scope's end, which was set aside
because it would hide a failure point at a dedent (North Star 3). It
accepts more programs and rejects none.

## What the call gives

When no task gives a value, `task.all` gives nothing, as a `sub` does:
the checker types it `Void`, or `Void!E` when a task can fail, with the
same wait set (`Checker.waitSet`) as a valued wait. It is recorded as a
`sub` call (`is_sub`), as `par.each`'s is, so it stands as a statement,
`!` passes its failure on, and `catch` handles it, each through the
paths every fallible `sub` call already takes. Binding it is rejected
as binding any `Void` ("`x` would be bound to a value of type `Void`"),
and `!` on an infallible one as on any value that cannot fail.

The runtime's `waitTasksInto` was already generic over its tasks'
types: a task giving nothing gives Zig's `void`, which it stores in a
tuple slot and drops as nothing. `TaskValues`, its result type, now
gives `void` (or `E!void`) when no task gives a value, and the wait
collects into a `[n]void` that it does not return. Cancel on the first
failure, the failure's fields passing to the waiter's slot, and the
drops of the others' results are the same code as before. Emit is
unchanged: it reads the `task_joins` fact as before and writes the same
`rig.waitTasksInto(...)` call.

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
