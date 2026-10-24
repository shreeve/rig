# Oracle: a plain `fun` value is plain data

Consolidation round 2, track 3, step 2. Measured 2026-10-24.

- Rig: main e6e96b266, worktree ~/Data/Code/worktrees/rig/oracle-fun (built with
  `tools/heavy zig build` and `tools/heavy zig build oracle`).
- Trig: ~/Data/Code/trig main d090e97, its `src/*` copied flat beside `main.rig`
  (tools/trig/main.rig) and `all.rig` (a root that `use`s all 34 modules) in
  /private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-incredible-project-25d019/e969f22a-9df2-4b7d-be7d-d73f157fafcd/scratchpad/oraclefun/.
  Counts are of `all=all.rig`, Trig's 9,861 functions, as in oracle-triage.md.
- Probes: /private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-incredible-project-25d019/e969f22a-9df2-4b7d-be7d-d73f157fafcd/scratchpad/funprobes/

## Result

| | decided | abstained | disagreements (compiler accepts, oracle rejects) |
|---|---|---|---|
| Trig, main | 5,251 | 4,610 (46.7%) | 0 |
| Trig, the kinds change alone | 9,618 | 243 (2.5%) | 44 |
| Trig, with the two fixes | 9,618 | 243 (2.5%) | 0 |

The suite: `tests` 22,767 → 22,778 decided by the kinds change (+11, as the earlier trial
measured), 22,796 with this change's six new cases; `docs` 1,077 and `matrix` 71,930
unchanged. No rejection was lost. **No compiler hole was found**: the 44 disagreements are two
oracle imprecisions, each reproduced in a probe that the compiler accepts and that runs clean
under `RIG_SANITIZE=1`, each with an unsafe sibling both checkers reject.

| Shape | Count | Verdict | Fix |
|---|---|---|---|
| A. A view reached through a read-view field of a write view lends `@` | 43 | imprecision | lower.zig `place`: a step through a read view under a write view reads the write view's place up to the stored view, and makes no loan on it |
| B. A function value held behind a read view "views anything" | 1 | imprecision | kinds.zig `Reach.anything`: a function type held in a value points nowhere |

## The kinds change

kinds.zig `Scan.walk` marked every `fun` type inside a type "a function or closure value" and
abstained. CORE §7, "A function value is an address": "`fun(A) -> R` or `sub(A)`, as a value,
is the address of a named function and holds nothing ... A closure is never such a value: a
stack closure stays in its binding and is lent only as a callable view `?fun`". So a `fun`
held in a type holds nothing; a `?fun` (`.callable`) still abstains, and a closure binding's
own kind (`callableInfo`) is unchanged. Trig's abstentions were 4,448 of this one reason,
almost all from `vfs.Host`'s five `fun` fields, which every `Checker` reaches through
`program: ?compiler.Program`.

## A. A path through a read-view field (43: 40 through `@`, 3 through a `c: !Checker`)

**Rejection.** `C4 cannot write \`@\` while a read loan of it is live (L0, carried by
\`tree\`)`, e.g. checker/contextual.rig:605 `Checker.get_contextual_type_for_argument_at_index`:

```
pub fun Checker.get_contextual_type_for_argument_at_index(!@, call_target: NodeRef, arg_index: Int) -> TypeId
  tree = ?@program.files[Int(call_target.file) - 1].ast
  if tree.is_import_call(call_target.node)
    ...
      return (!@).get_global_import_call_options_type()
```

`program` is `?compiler.Program` (checker/checker.rig:35). The other 42 are the same:
`tree = ?@program.files[f].ast` (or `dtree`, or a value made from `tree`, such as
`declarations = tree.nodes_or_empty(...)`) live across a `(!@)` call, and in transformers and
the emit resolver `options = ?c.program.options` or `ctree` across a `(!c)` call.

**Ruling (CORE settles it).** Sentence 7: "A view reached through a read view that a value
holds carries that view's loans, not a loan on the holder." §5, "A field is a place of its
own": "A path is a name and the fields after it, through what a write view the name holds
sees, and through a box" (a path does not continue through a read view). Sentence 7 on `from`
paths agrees: "When the path is a field declared as a read view ..., the result carries the
loans self holds and none on self, so self may be lent again, even to write, while the result
lives." So `?@program.files[i].ast` lends from what `@program` views, carrying the loans `@`
holds, never a loan on `@`.

**Cause.** lower.zig `place` turned a step through a read view into a read through it only
when the path was still the root's own (`via == .own`). After `@` (a write view, `via ==
.write`) the `?Program` step kept `.write`, so the lend made a loan on `@`. A local holder
(`?c.program.files[0].ast` with `c` owned) was already right; the rule failed only under a write
view. The suite had no such case.

**Fix.** A step through a read view under a write view reads through it (`via = .read`), as a
slice stored there already did (`under_write`), and the read of the write view's place stops at
the stored view (`cut`), so a write loan on a sibling field does not conflict. The first try
read all of the write view, which made seven new disagreements in Trig (e.g.
`Transforms.shim_or_rewrite_import_or_require_call`: `!c.builder.tree` lent and
`c.program.options.jsx` read in one call); stopping at the stored view clears them. A clone
through such a path reads the same place through the write view.

**Probes.** `s1_readfield.rig` (compiler accepts, sanitizer clean, prints `8 6`; oracle
before: DIFF `Checker.look` C4), `s1_nohook.rig` (the same with no `fun` field: the imprecision
predates the kinds change, masked by abstention), `s2_disjoint.rig` (the shim shape). Controls,
rejected by both: `c1_owned.rig` (`program: Program` owned: a loan on `@program.files`),
`c2_local.rig` (`tree = ?c.program.files[0].ast`, then `!p.files.clear()`: the view carries
the loan on `p`), `c4_wholewrite.rig` (reading `@program` while `k = (!@).count()`, a write
loan on all of `@`, is live).

**Tests.** test/rig/ownership-field.rig.test: "a view through a read-view field of self
outlives a write of self" (`Checker.look`, `look_param`, `emit_from` accept), and the three
controls as `fail` cases with `# oracle: ... reject C4`.

## B. A function value behind a read view (1)

**Rejection.** checker/inference.rig:410 `Checker.invoke_once`: `C4 cannot write \`n\` while
a write loan of it is live (L14, carried by \`@\`)`, after `action(!@, !n, source, target)`
with `action: ?sub(!Checker, !InferenceState, TypeId, TypeId)`.

**Ruling.** Sentence 7: "A function called as a value is known only by its type, which names no
`from` or `keeps`, so nothing narrows its result or its stores", and "What a call stores in what
a write view lent to it sees carries ... the loans of the arguments whose types could hold it".
So the question is whether a `Checker` could hold a view into an `InferenceState`. Its only
view fields that could are behind `program: ?Program`, and the oracle's reach walks what a
`?Program` views into `vfs.Host`'s `fun` fields, which `Reach.anything` counted as pointing
anywhere. A function value holds nothing (§7), so it points nowhere: the call can leave
nothing in `@` that carries the loan on `n`.

**Fix.** `Reach.anything` counts a function type as anything only where it is not held in a
value (`Node.held`, set on every part `parts` yields): a closure binding's own type still
points anywhere, since its environment carries what it captured. The first try dropped `fun`
from `anything` everywhere; the suite caught it (LOST `closure_capture_view_rules_ownership.rig
go`, two `|!total|` closures alive at once, and a learn-02 doc example that reads `count`
while `bump = |!count|` lives), because a stack closure's binding has a function type too.

**Probes.** `s9_fun_behind_view.rig` (compiler accepts, sanitizer clean, prints `2 2`; oracle
before: DIFF `Checker.run` C4). Control `c5_stack.rig`: with `names: ?List[Int]` beside a
`stack: List[Int]`, both reject (`run` stores a view of `n` in `@` ... `keeps n`).

**Tests.** test/rig/ownership-closure.rig.test: "a function value held behind a read view
views nothing" (accept) and "a call through a sub value may store a view of its write
argument" (`fail`, `# oracle: Checker.run reject C4`).

## The compiler stricter than the Core (no hole)

`s7_fun_reach.rig`: a `fun` field held directly in the object a write view sees (`Checker {
hook: fun(Int) -> Int, names: ?String }`, with an `InferenceState`-like `State { p: Int, stack:
List[Int] }`). The compiler rejects `n.p += 1` after `action(!@, !n, 1)`: sema's `TargetWalk`
counts a held `.function` as a view that may point anywhere, so a slot past the write view
"may get" a view of anything. Per §7 it holds nothing. The oracle now accepts it (`stricter`);
it is not in the suite, so nothing is allowlisted. Whether to narrow the compiler's walk is for
track 2.

## Not changed

- `rejections` gains four lines (the controls above) and loses none.
- `coverage`: `tests` 22,767 → 22,796; `docs` and `matrix` unchanged.
- 19 Trig functions still abstain on "a bare function value" (a local `fun` used bare, which
  `callableInfo` still kinds as a closure environment), the remaining `fun`-shaped reason.
- A known abstention, accepted (row 29, #662): the oracle gives no verdict on an instance whose
  generic body hands its iterator to another generic body, so those calls are not counted as
  decided. An abstention is no difference, so test/oracle/differences does not list it.
