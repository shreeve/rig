# Row 33D: a statement's loans end at their last use (CORE sentence 6): draft 1

Rig - Swiss, 2026-11-01, against main ad5d9b043 (33C merged as #848). The owner accepted the
direction in the compiler review (2026-10-31, decision 4: "end statement-long loans at their last
use, which CORE allows and the oracle accepts"). This is the draft for the CORE change process:
experts revise it, a final pass follows, and the owner approves before any code. Brief:
`handoff.md` beside this file. Probes and their output on main: the scratchpad listed at the end.

## The problem

CORE sentence 6 (*built*): "A loan lasts until the last use of every view that carries it." The
ownership checker measures "last use" a statement at a time. Inside a statement every loan it
can see lives to the statement's end. The handoff names one place this happens; probes on main
show three, and the handoff's mechanism alone fixes only one of its twelve expected gains.

- **(A) Loans no binding holds** (`Checker.temps`, ownership.zig:749): kept until `walkStmtValue`
  (2539) shrinks them, with two narrower exits, `endWriteLends` (3413) and `keepViewTemps`
  (3425). `print(firstw(!v).n, v.len)` is rejected (write_result_whole); main and the oracle
  disagree (prod=reject ref=accept).
- **(B) Loans a binding holds whose last use is in this statement.** `holderLiveDepth` (2222)
  calls a binding live when `last_use[sym] >= liveFrom(decl)`, and `liveFrom` is the statement's
  first position. So a binding used anywhere in the statement holds its loans to the end of the
  statement. This one is the most common:

  ```rig
  x = ?v[0]
  !v.push(Item(n: x.n))      # main rejects; the oracle accepts (b1)
  ```

  It also covers `print(w == a)` with `w = !a` (the 8 `*.eq.*` lines), `if o as it` followed by
  `!v.push(Item(n: it.n))` (c1), and `v, s = mk(?s)` (review-results-v07).
- **(C) A value a header holds.** `walkMatch` holds a taken subject's loans in a hidden var
  (7029), and `holderLiveDepth` calls every hidden var live. So `match find(!v)` keeps `v` lent
  through every arm, even one whose binding the arm never reads, or reads only in an earlier
  statement (c2, c3; match_arm_writes). The `for` header in `review-header-paths-1-t05` looks the
  same: the loop's held copy of a plain `[3]Int` part keeps the branch's write views lent.

## The rule (CORE: no new rule; one clause makes sentence 6's order explicit)

> **Within a statement, a use is a point in the order it runs.** An operand read as its value (a
> view of a value read where a value is expected, sentence 1) is used where it stands. Any other
> operand, argument, or self is used until its operation finishes: a call until it returns (§6),
> an operator until it yields. A value that carries the view on (a call's result as sentence 7
> says, a constructor, a branch, a binding) uses it for as long as that value is used. A
> binding's views are used until its last use in that order, or through a loop it was declared
> outside of. A value a header holds is used by its header, guards, and patterns, and then only
> by its drop, which uses its views only through a `drop` body (sentence 6).

What stays as it is:
- **An earlier argument's read keeps its owner lent until the call returns** (§6): a view
  argument is used until the call returns. The `*.arg_then_write.*` lines (`ref-gap`, the
  compiler right) stay rejected, as does `print(first(?v), bump(!v))` (a2).
- **Where emit reads is the point.** A view of a scalar or plain enum is read at its operand
  (`sema.readsAsValue`). A view of a plain object, array, or optional is kept as a view, so `==`
  reads it at the operator. So `r = ?a; print(r == bump(!a))` with `a: [3]Int` stays rejected
  (d3; the oracle accepts it).
- **What a callee stores** (`stored`, `keeps`) is carried by what holds it, as now.
- **An owning temporary whose drop runs a `drop` body** keeps its views lent to the statement's
  end (`dropStmtTemps`). A view of a temporary is still used only within its statement (§3), and
  33C's `headerTempLoan` self-check in `walkFor` still holds.

CORE text: sentence 6 gains "within a statement too, in the order it runs (§6)". Nothing else
changes; §3 and sentence 6's examples still read true.

## Which pass records what

Only the ownership checker changes. No fact is added for emit: loans belong to the checker.
- **One consumption rule, not a third exit.** `walk` already returns each node's `Value`, which
  is the loans it carries. When a node finishes, the `temps` taken since its start shrink to what
  its value carries, plus what something else holds: a stored lend, a `drop`-body temporary's
  views, or the structural entries (`place_hold`, `held_read`, a self's `reserved`). This
  generalizes `keepViewTemps`, and it and `endWriteLends` fold into it. A call holds its
  arguments' and self's loans in `temps` until it returns, whether or not a binding carries them.
  Today the binding's statement-long life does that for `print(r, poke(!a))`; under (B) it must
  be explicit.
- **Use points by walk, not by source position.** `indexUses` records every use position of each
  symbol, not just the last. Within the statement being walked, a binding is live while one of
  its uses there has not been walked, or it has a use after the statement (or a loop around it
  started after its declaration, `loopStartFrom`). A set of walked positions makes this hold
  under reordered walks: an assignment's target walked after its value (`after_value` already),
  `stmt if cond`, a `while` step (`step_at`), a `catch` handler, and an operand walked twice.
  An earlier draft idea, "dead once its last source position is walked", accepts
  `print(w.n) if poke(!a) ...`, since the condition, at a later position, is walked first.
- **The operand read point** comes from `sema.readsAsValue` and `sema.copies`, as emit uses them.
  The checker does not decide it a second time.
- **A header's held value** (`walkMatch`'s taken subject, a `for`'s held copy) is treated as
  `holdsPastDrop` treats a statement temporary.

## Programs

**Newly accepted** (each prod=reject, ref=accept on main): b1, c1, c2, c3, write_result_whole,
match_arm_writes, the 8 `*.eq.write_view` / `*.eq.destructure_write` lines, review-results-v07,
and probably t05. The handoff's gain list holds.

**Nothing accepted today is rejected.** The change only removes loans from the live set earlier,
and a conflict needs a live loan. The two ways to fail are internal: a self-check assertion that
compares the checker's loans with a recorded fact (33C's `headerTempLoan`, `verifyDecisions`), and
a diagnostic that names a loan which is no longer there. The suite with `-Dself-check` and
`tools/emit-diff` (expected identical) show it.

**Still rejected (guards):** a2 and the `arg_then_write` matrix (§6); b2, `print(w == a)` with
`a: String`; d3, the array `==`; d1, a binding read in a loop it was declared outside of; a
stored lend; a `drop`-body temporary's views; a view of a temporary used past its statement.

## The oracle

It accepts every newly accepted program already, so it learns nothing for them. It is no guard
for the class most at risk, though: it copies a read view out at a call argument, so it accepts
a2 and the `arg_then_write` matrix (its `ref-gap`) and d3. If the change ends an argument's loan
early, the oracle will not notice. Proposed: teach it §6 (a view argument is used until the call
returns) and the operator read point, from CORE alone, in this change. About 30 `ref-gap` lines
would then leave `differences`.

## Emit

Nothing new to decide. The risk is order: until now a mismatch between the checker's walk and
emit's evaluation order was masked by statement-long loans (weak-spots, "Evaluation order versus
what is emitted"). A spot check shows emit keeps a later operand's temporary in place
(`rig.keep(&__rig_tmp, ..., mk(&v))` inline), not hoisted ahead of an earlier operand. The
compiler expert should audit `catch`, `??`, branches, `String(...)`, and `print`.

## Tests

From each class: (A) a call result's field copied out, then the owner read in the same
statement. (B) a binding read as a value, then its owner written later in the statement: `+`,
`==`, a field copy-out, `??`, `catch`, a branch, a `print` argument. (C) a `match`, `if ... as`,
and `for` over a held value whose arm writes the owner. Each FIXED line in `differences` becomes
an accepting `test`. Every guard above becomes a `fail` case. No `seeds:` are needed.

## Size

About 150–250 lines in ownership.zig, plus 60–100 in the oracle if it learns §6. About 12
differences lines go (40 or more with the oracle's §6), and about 20 cases are added. Risk is
moderate to high: every statement's liveness moves, and a wrong early end accepts a program that
corrupts memory.

## Open questions for the experts

1. Is "the order the statement runs" the order the checker walks, everywhere emit evaluates?
2. Does (C) belong in this row, or in a row of its own?
3. Should the oracle learn §6 here, as the guard for this change?
4. Should the sentence 6 clause go into CORE, or is CORE already enough as it reads?

Probes: `/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-incredible-project-25d019/61e6bc21-7c82-43f3-8978-0dbbd8206817/scratchpad/p/`
(a1–a3, b1–b2, c1–c3, d1–d4, t05, e1). Main's binaries: `~/Data/Code/worktrees/rig/core-33d-read/bin/{rig,rig-oracle}`.
