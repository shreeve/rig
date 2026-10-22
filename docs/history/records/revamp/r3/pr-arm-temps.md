# Keep a match arm's temporaries in the arm, and count an assignment target's uses after its value

## Summary

Two commits, one round (patch release: the second closes a live hole).

1. **A `match` arm's body is a statement of its own** (45fa39d4), as
   each line of a block is. A temporary made there is dropped where the
   arm ends, while the arm's bindings are still in scope, so it may view
   them. Before, `sema.stmtTemps` gave an arm's temporaries to the whole
   `match` statement:
   - the checker rejected a temporary that views the arm's binding
     ("`x` does not live long enough"), a regression from #76 (review
     M1, q07);
   - on main before #76, emit kept that slot past the prong, so a
     `drop` that read the view read a prong-local copy after its scope
     ended: undefined behaviour in Zig (q12).
2. **An assignment's target is used after its value** (e65b2bff). A
   use of a symbol in a `set` target now counts, for liveness, at the
   assignment's end. Before, a statement nested in the value (a `match`
   arm, a block arm, an `if` block, a `catch` block) took its own start
   as "now". So the views in the target (`w[0]`, `w.n`, `u[w[0]]`, or
   `w` written through) looked dead there, and the value could grow,
   move, or read what they view before the store went through them.
   - Block arms, `if` blocks, and `catch` blocks: **live on main**
     (use of freed memory under `RIG_SANITIZE=1`; review l13, l14, l16,
     plus a simple-name write-view target found here).
   - `pat => s` arms: opened by commit 1 (review l09–l12, l17, l18,
     l21). Commit 2 closes them.

**What this fixes, against main (d6b0b6b2):**
- **Use of freed memory that main accepts.** These are now rejected:
  - review l13 (block arm), l14 (`if` block), l16 (`catch` block);
  - review-2 m11 (compound assignment on a write-view name);
  - m12 (owner reassigned inside the value);
  - m32 (mixed view/value arms);
  - m39–m41 (re-pointing the target's view at a local of a value's
    nested scope that is *not* the last one).
- **The q07 regression from #76**, rejected on main, is accepted and
  correct. So are q06, q12, review a01, and review p11.
- **q12's undefined behaviour from before #76**, a drop reading a
  prong-local copy after the prong, is gone. Emit's slot is now the
  arm's own.

**What this does not fix.** The review-2 holes of the same class are
listed below. They are pre-existing, and this branch does not make them
worse. Under AGENTS ("a second soundness round stops the feature"), they
are left to a redesign that specifies assignment as a desugaring: the
value goes into a temporary first, then the store, and the checker and
emit treat it the same way.

Head after merging origin/main (d6b0b6b2): 81b7d7ad.

## 1. Arm temporaries

**Desugaring** (docs/INTERNALS.md): an arm is a block of one
statement. `pat => s` is `pat` followed by the block `s`, so
`.has(x) => f(?mk(?x))` is `.has(x)`, `_t = mk(?x)`, `f(?_t)`, `-_t`.
`_t` is dropped where the arm ends, inside `x`'s scope.

**One decision.** `sema.sharesStmtTemps` now stops at an arm's body
(`sema.isArmBody`), as it already stops at blocks, closures, headers,
and a `while` step.
- **Emit** needed no change. Its prong code (`emitBodyWith`,
  `emitYieldBlock`) already declares slots for whatever `stmtTemps`
  leaves to the arm statement.
- **Checker.** `walkMatch` no longer calls `holdPartTemps` for arms. It
  walks each body with `walkTailStmt`, which `walkBlock` now shares for
  its last line, so `pat => s` and a block arm are checked the same
  way. `holdPartTemps` is now for `catch` handlers only.

**Siblings:**
- **`if`/`else`, loop bodies, the `while` step:** each is already a
  block, or the step is already its own statement. A ternary's branches
  are values, part of the statement.
- **`catch` handlers stay statement-scoped (#76), and the difference is
  deliberate.** A handler is part of an expression whose rest may view
  its value or a temporary it makes (`(f() catch mk()).me()`). A `match`
  stands only where its value is taken whole: a statement, a binding's
  value, `return`, `break`, an arm, or a block's last line. Layout
  rejects `(match …)` and `f(match …)`. So nothing past an arm can view
  what the arm made. A `catch` inside an arm is now that arm statement's
  (q06, review p10/p11).

**One accept change from liveness.** Liveness now counts from the arm's
own statement, as it already did for a block arm. So
`match ?x[0]` / `.circle(_) => print(grow(!v))`, where `x = !v` is not
used after the header, is accepted. The block-arm form already was.
- This was line 39 of `reject/ownership/match_subject_lent_through_arms`.
  That line now uses `x` in the arm (`print(grow(!v), x.len)`), so it is
  still rejected.
- The accepted form is a new behavior test,
  `match_arm_statement_liveness`.

## 2. Assignment target liveness

**The class:** a construct whose source order differs from its
evaluation order, and which can hold a nested statement. Liveness is
textual: "now" is the innermost statement's start, and a var is live if
it is used at or after "now". For a top-level statement, every use in
the statement counts, so source order does not matter. A nested
statement starts after the target, though, and the target runs after
the value.

**Fix, once, in `Checker.indexUses`:** a use in a `set` target
(`isSetTarget`) is recorded at `extent(set).hi`, as a `while` step's
uses already are at `stepAt`. This covers every assignment form: `=`,
compound `op=`, element, field, index (`u[w[0]]`), and a simple name
written through a write view. The checker still walks the target after
the value, as emit evaluates it, so a move in the value is still seen
by the target (review l20). Desugaring in docs/INTERNALS.md:
`w[0] = match …` is `_n = match …`, `w[0] = _n`.

**Sites checked for the same class:**
- **Compound assignment:** covered, since it is a `set` with an op.
- **Multiple targets:** none in the grammar.
- **`swap` and `replace` targets:** these are call arguments, which are
  values. Layout allows no `match`, `if`, or `catch` block inside a
  call's parentheses, so no nested statement can occur there.
  Whole-statement liveness already covers them.
- **A call's receiver evaluated before its arguments:** the arguments
  are values (the same layout rule). A closure literal in an argument
  captures at the literal, inside the statement (probed: `w[0] =
  call(|!v| …)` is rejected on main and on the branch).
- **Ternary, `??`, inline `catch`:** their parts are values, so they
  are checked at statement level (review l15).
- **`return`/`break` values:** nothing runs after the value.
- **`while` step:** already `stepAt`.
- **Loop `else`:** runs after the body, which is also source order.

## Tests

- Behavior:
  - `ownership/arm_temporary_views_binding`: q07 plus guarded, valued,
    tail, `return`, nested, `catch`-in-arm, and loop/`continue` arms.
  - `ownership/arm_temporary_drop_reads_binding` (`# release`): q12,
    drops that read the binding, Cell holders, value and `return` arms.
  - `ownership/match_arm_statement_liveness`.
  - `ownership/assign_target_nested_statement` (`# release`): the valid
    siblings, where the nested statement lends another value, or moves
    one the target does not view.
- Reject: `ownership/assign_target_live_through_value`. It has 11 cases
  (match arm, block arm, `if` block, `catch` block, ternary, compound,
  field, index, read, move, and a write-view name target). Main misses
  4 of them.
- Corpus:
  - review-cell-temp2-2 q06, q07, q12;
  - every review-arm-temps probe (41). l07 stays rejected: an
    over-rejection, below.
- Docs:
  - SPEC "Temporaries" states that an arm is its own statement, with a
    running example;
  - SPEC "Core 6" lists the target use, with a `rig reject` example;
  - INTERNALS has both desugarings.
- **New matrix axis `target.<place>.<nest>.<act>`** (120 cells): place
  `elem`/`compound`/`field`/`index`/`name` × nest
  `arm`/`block_arm`/`if_block`/`catch_block`/`ternary`/`plain` × act
  `grow`/`read`/`move`/`other`.
  - An `other` cell must print the value stored.
  - Branch: 0 failed. The oracle reports 0 differences over the axis.
  - Main: **18 failed**, every one a use of freed memory.

## Gates

- 45fa39d4, pup, -j 12, all green:
  - suite 2845 passed, 4 pending;
  - corpus 7043;
  - matrix 5333 programs, 0 failed;
  - unit 127/129 (2 skipped);
  - oracle/doc/vocab 340 passed, 4 pending.
- e65b2bff, Mac, -j 5 (pup was held exclusively), all green:
  - suite 2851 passed, 4 pending;
  - corpus 7084;
  - matrix 5453 programs, 0 failed;
  - unit 128/129 (1 skipped).
  - Logs: `.git/revamp/r3/logs/arm-temps/mac-e65b2bff.*`.
- 81b7d7ad merges origin/main (d6b0b6b2). The merge touches only
  `AGENTS.md`, `HANDOFF.md`, and the version in `build.zig`, and no
  compiler source. After it, the build and this round's tests plus
  `style` and `cli` pass (57).

## Targeted grid (arm temporaries)

**Design:** 1,350 cells, each written twice: as `pat => s` and as a
block arm.
- **Payload type:** Int, an owning struct with a `drop`, a Cell holder
  with a `drop`.
- **Holder kind:** `drop` reads the view, owns a Text, plain.
- **Form of the temporary viewing the binding:** lent, method receiver,
  `catch` handler, `??` fallback, ternary, lent `catch`.
- **Arm context:** statement, value, guard, `return`, loop with
  `continue`.
- **Subject:** place, `?b`, `!b`, `<b`, made.

**Check, 2,700 programs:**
- The branch accepts every one.
- Main rejects 744, all of them `pat => s` forms. Main accepts every
  block form.
- 0 panics.

**Run, 45 grouped programs.** Four runs of each:
- simple form, branch, debug with `RIG_SANITIZE=1`;
- simple form, branch, `--release`;
- block form, branch, debug;
- block form, main, debug.

All four outputs are identical in 39 groups. In the other 6 groups,
**main and the branch fail the same way**: the emitted Zig does not
compile. That is a pre-existing bug, below. Those 180 cells were rerun
one by one:
- 144 are identical and sanitizer-clean;
- 36 fail to compile in Zig, on main and the branch alike. Every one
  is a guard arm.

## Equivalence against main (test/equiv.py)

- Commit 1 (45fa39d4): 9,444 programs, 15 differ, all explained.
  - 7 are this round's new tests, corpus copies, and the SPEC example:
    `check`/facts differ because main rejects them.
  - 7 differ only in emit and pkg: an arm's temporary slot moved from
    before the `switch` into the prong:
    - `write_lend_temporary_branches`;
    - `review-seam2b-fixes-fuzz-pc-match__{branch__at,call__incrarr,catch__repl,coal__sortarr2}`;
    - `review-step45-r2-c12_match_value_subject_temp`;
    - `review-text2-a3`.
  - `reject/ownership/receiver_view_of_temporary_leaves_tail`: the same
    error, `mk(49).me()` at 39:10, is reported where the arm ends. It
    has no "`m` still holds it" note and comes in a different order.
    The error count is unchanged.
- Head (e65b2bff): 9,488 programs, 29 differ. That is commit 1's 15,
  plus programs added in commit 2, all explained.
  - **Accept to reject (the live hole), 3:** review-arm-temps l13, l14,
    l16. Main accepts them and frees memory still in use.
  - **Reject to accept (arm temporaries), 9:**
    - the new behavior tests `arm_temporary_drop_reads_binding`,
      `arm_temporary_views_binding`, `match_arm_statement_liveness`;
    - corpus probes q06, q07, q12;
    - review-arm-temps a01 and p11;
    - the SPEC example.
    All run sanitizer-clean.
  - **Rejected by both, with diagnostics that differ:** review-arm-temps
    p01, p02, p03, `receiver_view_of_temporary_leaves_tail`, and
    `assign_target_live_through_value`. The first four give the same
    error, reported where the arm ends. The last has 11 errors on the
    branch and 7 on main (main misses the block arm, the `if` block,
    the `catch` block, and the write-view name target).
  - **Emit only:** an arm's temporary slot moved into the prong.
    - The 7 corpus and behavior programs listed for commit 1.
    - review-arm-temps f01, h02, p07, p09, p10.
  - No program other than this round's own tests and probes changes
    from accept to reject.

## Known remaining (pre-existing, fixed next by the assignment desugaring)

Each item is on main too. The branch makes none of them worse. Probes:
`.git/revamp/r3/probes/review-arm-temps-2/`, `review-arm-temps/`.

- **Critical: the value's last nested scope re-points the target's view
  at its own local** (m42, m43, m44, m45, m46).
  - Examples: `w[0] = fail(-1) catch |_|` / `u = …; w = !u[0..1]; 3`,
    the last `match` arm, an `else` block, and an index target
    `t[w[0]] = match …`.
  - `indexUses` records the target's use at `extent(set).hi`. That is
    the same position at which `popScope` checks the last nested scope's
    locals (`hi + 1` is the bound, and the use is not past it). So the
    view looks dead there.
  - Accepted; use of freed memory under `RIG_SANITIZE=1`. The oracle
    reports DIFF (C5).
  - Non-last scopes (m39–m41) are rejected on this branch.
  - Moving the use to `hi + 1` is not a fix: it rejects m51, which is
    valid, because positions leave no gap before the enclosing block's
    end.
- **High: emit takes a write-view name target's pointer before the
  value** (m47, m48).
  - `w = match …` with `w: !T` is emitted as `w.* = switch …`. Zig
    takes the pointer `w` before the arms run.
  - If an arm re-points `w`, the store goes to the old referent. m48
    prints the wrong values. m47 writes into a freed buffer.
  - The checker, the docs, and the element form (m23) all store after
    the value. The oracle is silent on both probes.
- **High: Zig compile error from accepted code.** A guard of a consuming
  `match` that changes a Cell through a view of the binding fails to
  compile (`expected type '*D', found '*const D'`): the binding is a
  `const` in the guard's selection block. Found by this round's grid:
  36 of its 1,350 cells. Minimal:

  ```rig
  struct D
    c: Cell[Int]

  struct H
    v: ?D

    fun get(?self) -> Int
      self.v.c.set(self.v.c.get() + 1)
      self.v.c.get()

  enum Bx
    has(p: D)
    nothing

  sub main()
    b = Bx.has(D(c: Cell(3)))
    match <b
      .has(x) if H(v: ?x).get() > 100 => print("big")
      .has(x) => print(x.c.get())
      .nothing => pass
  ```

- **Low: over-rejections**, all shared with main:
  - **l07:** a later arm's guard keeps a view live in an earlier arm's
    body (`x = ?v[0..1]`; `0 => grow(!v)` / `_ if x[0] > 0 => 1`).
    Liveness is textual, and that guard never runs after the earlier
    arm.
  - **m15:** reassigning a read-view local from a value whose nested
    statement lends its old referent (`r = ?v` … `r = match k` / `0` /
    `  grow(!v)` …). Only a write-view local is re-pointed early
    (`repoints`).
  - **m21:** the old holder views the Vec itself, not a slice, so its
    drop is safe after the growth. The oracle accepts it.
- **Low, oracle gap (m33, m34):** the oracle accepts a reassignment
  whose old value's `drop` reads a slice that the right side
  reallocates. The compiler rejects both correctly. The oracle does not
  model the old value's drop running after the right side.
- **Matrix gap, for the redesign:** the `target.*` axis has no act that
  re-points the target's view at a scope-local. It needs
  `repoint_local` × last / not-last nested scope.
