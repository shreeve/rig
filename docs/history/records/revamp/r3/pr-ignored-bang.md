## Summary
A written `!` must lend to write. `!x` is rejected wherever `x` is only read: a slot that stores or takes a plain value, an operand, an index, `print`, a copy, a read view the callee only reads, a leaf of a value that branches or loops, and the base of a field or element that is only read. These are the design owner's decisions (rig-questions.md, "A `!` that would be ignored", and the follow-ups that extend it to read views). Held write views (`w`, `h.w`, a `!T` parameter) have no `!` written, and read and lend as before.

| Written | Where it goes | Write instead |
|---|---|---|
| `bump(!n)` | `bump(x: !Int)` | kept: `bump` may write `n` |
| `!n + 1`, `arr[!i]`, `print(!n)` | read as a value | `n` |
| `Opt.some(v: !n)` | an `Opt[Int]` | `n`, or `Opt[!Int]` to keep the view |
| `rd(!n)` | `rd(x: ?Int)`, which only reads | `rd(?n)` |

The diagnostics:
```
`!n` here is read, not held: `Opt.some` stores an `Int`. Write `Opt[!Int].some(v: !n)` to keep a write view of `n`, or `Opt.some(v: n)` to store a copy
`!n` here is read, not held: `get` takes an `Int`. Write `get(n)` to pass a copy; to lend `n` to write, the parameter must be a `!T`
`!n` here is read, not held: only its `Int` is read here. Write `n`
`!n` here is read, not held: `rd` only reads `n`; write `rd(?n)`
`!p` here is read, not held: `get` only reads `p`; write `p.get()`
`!p` here is read, not held: `(!p).x` only reads the place it reaches. Write `p.x`
`!n` here is read, not held: `?` lends it on to read. Write `?n`
```

**Release note.** An untyped binding of a loop used as a value, each of whose values hands over a write view (`l = while true` / `break slot(!n)`, where `slot` returns a `!Int`), now holds the view, as an `if` with such branches does. So `l += 5` now writes `n`; on main, `l` was a copy. No file in the tree changes meaning: emit over every program both compilers accept is identical.

## One decider
`Checker.writeLendRead` (typecheck.zig) decides whether a written `!x` lends to write. `Checker.writtenWriteLend` is its classifier: `handsOver` = `.lend` of type `!T`, or a `<` of one. Every place a written `!x` can meet a context asks it:
- **Reads that are recorded.** `Checker.readOf` is the one place type checking records a read through a view (`recordRead`). It asks the decider first, for these reads:
  - `recordAdapted`'s copy-out into a slot;
  - `readThrough`: operands, comparisons, indexes, bounds, conversions, `??`, `?`, `+x`, compound assignment.

  `reachThrough` (`.reach`) records a read that reaches a place without asking the decider: the element of a viewed slice or String, and a header's optional. `.narrow` is a held write view passed where a read view of a copy goes, with no `!` written.
- **A read view's slot.** `checkExpr` asks the decider with `.read_view` where the expected type (lifted through optionals) is a `?T`, a `[]T` or a String holding no write view. This covers arguments, fields, typed bindings and array elements.
- **A `?self` receiver:** `checkReceiverMode`.
- **Values that record nothing:** `print`/`Text` values (`checkFormatArgs`) and `?!x` (`synthLend`).
- **A field or element whose base is a written lend** (`(!p).x`, `(!arr)[0]`, `(!s).len`):
  - `memberOf` and `indexInto` note it;
  - an access that writes it (`requireAccess`), a `<` (`synthMove`) or an `as` header (`checkOptionalBinding`) marks it written;
  - `checkReachedLends` rejects what is only read;
  - a read slice (`?(!arr)[0..1]`) is rejected where it is synthesized.
- **Leaves.** A value that branches or loops is decided at each leaf, through `sema.yieldedLeaves`:
  - that is the one walk of what a value may be: `valueParts`'s tails and operands, plus a loop's `break` values and `else` (`sema.loopValues`);
  - `yieldsWriteView` (whether an untyped binding holds the view) uses the same walk, and the checker's `view_loops` map is gone;
  - `sema.handsOver` still calls a loop value `.made`, as it does a `match` and a block, whose tails `valueParts` also walks. A loop is now classified exactly as a `match` is. Making both `.branches` would change what emit, storage and ownership do for every match and loop, so I left that to its own change.
- **Inference (`argType`).** A written `!x` binds `T` to the value it reaches where that is copied out (`copiedThrough`), and the slot then rejects it. Where no copy can be made (a `Vec`), `T` is the view.
- **Structural unit test.** It fails if `ctx.recordRead(` appears anywhere in typecheck.zig but `readOf`, if `readOf` stops asking `writeLendRead`, or if emit, ownership, storage or resolve records a read. A second unit test checks a slot, an operand and `print`.

## Commits (since main)
- da4cf0b3, c5565ea1, 596161e4: round 1: value slots, the hp31 probe, docs.
- 293a3098: merge main 1d356a09 (#86).
- 38429070 **Decide every read of a written write lend as a value in one place:**
  - operands, indexes, `print`, `+!x`, `?!x`, `<!x`;
  - inference;
  - untyped loops keep the view;
  - hint fixes (siblings' `!` stripped, `!!n`, `!T` named as declared, a keep instance only for a type that can take it, no outer-call splice);
  - one report for `takeo(Opt.some(v: !n))`.
- fa946b00: SPEC/INTERNALS for that. It also restores CORE to main's text, so CORE's net change is only the last commit.
- 48aa499e: `view_result_values`: a typed loop binding, emit equal to main's.
- d1635e32: merge main 53cbff4f (#87, one-decider). The merge was clean.
- c293f2ff **Reject a written write lend where only a read view goes, at a leaf, or as a path's base.**
  - The owner's read-view decision, re-review High 1 (leaves), Medium 2 (`yieldedLeaves` replaces `view_loops`), and Low 1 (paths).
  - Tree fixes, each to `?x`, the place, or a held view. Each runs as main's original did, unless noted:
    - **behavior:**
      - `write_view_lent_as_copied_read` (held views `wx`, `wn`, `wk`);
      - `take_through_lend` (`s.n`);
      - `box_lent_as_value` (`rd(?w)`);
      - `write_lend_kept` (`read(?n)`);
    - **reject:** `text_hints`, whose `f(!t)` to a String now gets the read-view message;
    - **corpus probes with oracle lines:**
      - `p04` (`?p if k else ?mk(7)`), `a15` (a held `w = !d` in the `catch`), `p73` (`s.n`);
      - `d02` (the branch bare), `l03`, `m02`, `q02`, `t01` (`(?…)`);
      - `p74`: `(!s).n` becomes `bump(!s)`, which keeps the probe's documented core gap (prod rejects, the oracle accepts). Its `test/oracle/differences` entry is updated to the new form.
- fad35ac1: SPEC Lending gets the owner's table, with the `rd(!n)` reject example and its exact error. INTERNALS: the Copies row.
- d4cd3085 **CORE sentence 4,** the owner's approved text, its own commit. The §4 lead-in now reads "where the context takes none of the views in `!x`'s column, `!x` is rejected (sentence 4)".
- 90bbc714 **Final review Medium:** an `as` header no longer marks its path written, so `if (!p).o as v`, `while (!p).o as v` and `if (!arr)[0] as v` are rejected. `!` and `<` still mark the paths they write or take.
- db64483a **Final review Low 2:** a repeated label's `break` goes to the innermost loop (`sema.breaksOut`, `sema.breakValues`, through `shadows`). This fixes probe e07 and two older over-rejections ("must end with a value", "the value of this loop is not used").
  - Through those two, `loopValues`, `yieldedLeaves`, `hasValueBreaks`, `loopsForever` and emit's `hasValueBreaks` are fixed.
  - `checkBreak`, `walkJump`/`walkLabeled`, emit's `jumpTarget` and the oracle's `findLoop` already resolve the innermost loop first.
- 7792d89e **Final review Low 3:** a path error is reported once (none after an earlier error in the same statement part) and in source order (`SemContext.placeInOrder`).
- cfdf670e, 24fca219 **Final review Low 4 and 5:** the doc comments are back on their declarations, and SPEC states plainly that `Opt.some(v: !n)` is rejected.
- fb906d05, 309a3e5c: a pinned element base in an `as` header; a lint no longer hides a write lend's path error.
- 3af64e45: merge main 39d0e4b2 (#88, one-decider stage 2). The merge was clean.

## Tests
- `reject/ownership/ignored_write_lend.rig` (28 errors): every value slot.
- `ignored_write_lend_read.rig` (16 errors): every value-read path.
- `ignored_write_lend_read_view.rig` (7 errors): `rd(!n)`, `h: ?Int = !n`, `G[?Int](r: !n)`, `total(!arr[0..2])`, `total(!arr)`, `len(!t)`, `(!p).get()`. A held `w` passes.
- `ignored_write_lend_leaves.rig` (12 errors):
  - `print(!n if c else !m)`, `(!n if c else !m) + 1`, `a = w if c else !m`;
  - a loop mixing `break w` and `break !m`, an `if` with a `break !n` loop branch, a `match` arm;
  - `(!p).x`, `(!arr)[0]`, `(!s).len`, `?(!arr)[0..1]`.
- `ignored_write_lend_once.rig`.
- `behavior/ownership/write_lend_kept.rig` (`# release`):
  - `Opt[!Int].some(v: !n)`, expected `Opt[!Int]`, `G[!Int]`;
  - `!T` parameters, generic `!T`, a write receiver;
  - `[!n]`, `!n if c else !m`, `h: !Int`;
  - untyped `while` and `for … else` loops.
- Two unit tests (above).

## Survey (main 53cbff4f vs branch, `rig check` over every tracked `.rig` in test/, examples/, std/)
- Newly rejected: the round's reject tests, plus corpus probes left rejected because each probes exactly this form:
  - p40 and p40b, two copies each; lang4-g3; audit-fuzz-pf2;
  - fix-s2f, a_34-bad1, a_34-bad2, a_44-bad2, p6-z3, p6-z4, sc4-rw: all `peek(!x)` passed to a `?T`.

  None of these has an oracle line for the rejected function.
- No example, std file or doc example changes.

## Verification
- **Grid** (scratchpad `ib/grid.py`, base main 53cbff4f): 60 slot kinds × 5 lend forms = 300 cells, 0 bad.
  - New kinds this round:
    - read-view slots: parameter, binding, a `?Int` field; plus a held view passed to a `?Int` (kept);
    - leaves: printed `if`, operand `if`, held-and-lend `if`, a mixed loop, an `if` over a loop, a `match`;
    - paths: field, index, `.len`, read slice; plus a written path `(!p).x = 2` (kept).
  - 207 reject cells are rejected with this diagnostic where main read silently. 12 more and 1 other are rejected by main too, for other reasons: ownership, or name clashes in the grid's own programs.
  - 66 keep cells run sanitizer-clean in debug and `--release`. 58 equal main's output; 8 are the untyped-loop cells, which main read silently.
  - 14 cells hold a temporary's view and are rejected by both compilers.
- **Matrix verdicts:** `rig check` agrees with main on all 5877 programs.
- **Gates on the merged head 309a3e5c** (`--delta`, through cpuq via heavy.sh):
  - suite 2904 passed, 0 failed, 3 pending;
  - corpus 7294 passed;
  - matrix 5877 programs, 3213 ran clean, 2664 rejected, 0 failed;
  - unit 134, 1 skipped.

  The oracle shows 0 differences over the new tests.
- **Equivalence** (`test/equiv.py`, base 53cbff4f, through cpuq): 9731 programs, 27 differ, all in `check`/`facts` only:
  - the 5 reject tests and 3 SPEC reject examples;
  - `text_hints`, whose message changed;
  - `write_lend_kept` and `write_view_result_binding_holds_view`, which main rejects;
  - the corpus probes above;
  - m31 and m32, rejected by both;
  - q09f, already rejected on main, now with one more error.

  Every program both compilers accept emits identical Zig and an identical package.

## Follow-ups
- **Oracle (re-review Low 2):** the oracle does not model a loan carried out of a loop by a `break` value. All 23 "stricter" verdicts on the review probes are of this kind, and since untyped loops now keep views, it now covers ordinary scalar code. Not a prod soundness issue.
- **Pre-existing on main, not this branch: `(!arr)[0] = 7` miscompiles.** Emit writes `&arr[0] = 7`, and Zig rejects it. The same holds for `(!arr)[i] += 7`, `(!v)[0] = 9` on a Vec, and `if !(!arr)[0] as v`. `(!p).x = 5` works. These need their own round: the suite cannot hold a known miscompile, and whether they should run or be rejected is a design decision.
- **Hint nits (re-review Low 3), cosmetic:**
  - `G(r: !n)` for a generic `G` with methods says "the field's type must be `!Int`";
  - `G(r: G(r: !n))` uses the generic "the type here" form;
  - a leaf beside a write-view sibling (`… catch !d` read by `+`) is told to write `d`, which would mismatch; a held view is the working form.
