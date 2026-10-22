# Survey: `<` on a place that is neither ended nor emptied (move-done)

Base: main c169ec89 (v0.2.4), worktree `rig-move-done`.

## Method

The compiler classified, not grep. A temporary patch to
`src/ownership.zig` logged one line (`SURVEY|line|col|category|type|...`)
at every `<` whose source is left as it was:

- `movePath`, at its two early returns that accepted a part silently: a
  field or element whose type copies (`sema.copies`), or holds a read
  view. Category by the place the checker resolved: `field` (a binding's
  field), `elem` (an element), `view` (through a view binding),
  `handle` (through a `*T`), `via` (through a view value: `(!s).n`,
  `(?s).n`, `wrap(!s).f`).
- `walkMove`'s fallback, which walks the operand as a value: a field or
  element of a value made there (`temp`, `<mk().n`), a path rooted at
  something no var holds (`other`: a module's constant, `geo.K`,
  `geo.KP[0]`), and a bare name no var holds (`name`: a function,
  `<one`).

Then `bin/rig check` ran over every program `test/equiv.py` covers:
every tracked `.rig` file (test/, examples/, std/, the corpus, multi-file
tests by their `main.rig`) and every ```` ```rig ```` block in the
Markdown docs, 9172 programs. Raw log: `survey-move-done.tsv` beside
this file.

The sibling forms were probed by hand first (`return <s.n`, `show(<s.n)`,
`match <s.n`, `for x in <s.arr`, `<mk().n`, `<geo.K`, `<geo.KP`, `<one`,
`<geo.mk`): each reaches the same two sites, so the log covers them.

## Result: 14 sites in 13 programs; 11 accepted programs become rejected

| Category | Sites | Programs |
|---|---|---|
| field of a binding, value copies (Int) | 3 | test/behavior/ownership/copy_field_move.rig (`<p.n`), test/behavior/ownership/move_copies_plain_field.rig (`<s.n`), test/behavior/ownership/move_ends_copy_value.rig (`<p.n`) |
| field of a binding, plain struct | 1 | test/behavior/ownership/move_copies_plain_field.rig (`<s.p`) |
| field of a binding, String | 2 | test/behavior/syntax/sigils_before_calls.rig (`<pair.name`), test/corpus/audit-fuzz-pf1-accepted-ef0d28d8d2.rig (`<pair.name`) |
| element of a Vec (Int, String, plain struct) | 4 | test/behavior/ownership/move_copies_plain_element.rig (`eat(<v[0])`, Vec[P]), test/corpus/t-mv1.rig (Vec[String]), test/corpus/t-mv2.rig (Vec[Int]), test/corpus/t-mv4.rig (Vec[P]) |
| field through a lend value, `(!s).n` | 2 | test/behavior/ownership/take_through_lend.rig (`<(!s).n`); test/corpus/review-seam2-c12_move_elem.rig (`<(!mk(3)).n`, already rejected for `<(!mkv())[0]`) |
| field through a `*T` handle | 1 | test/corpus/audit-ownership-l07_defer_nested_scope_return.rig (`return <b.n`, `b: *Tok`) |
| element of another module's constant | 1 | test/corpus/review-place-b6-u012_mod_const_take/main.rig (`<geo.KP[0]`, already rejected: unused `x`) |
| element of an array or slice, read-view field, part of a temporary, module constant, function name | 0 | none |

By location: test/behavior 6 programs (7 sites), test/corpus 7 programs
(7 sites; 2 already rejected). examples/: 0. std/: 0. Doc examples: 0
(no ```` ```rig ```` block in any Markdown file uses `<` on such a
place). test/matrix.py: its only move form is `<a`, a name.

Accepted today and rejected under the rule (11): the 6 behavior tests
and the corpus probes audit-fuzz-pf1-accepted-ef0d28d8d2,
audit-ownership-l07_defer_nested_scope_return, t-mv1, t-mv2, t-mv4.
Already rejected, gaining the new error (2): review-seam2-c12_move_elem,
review-place-b6-u012_mod_const_take.

## What each program became

- copy_field_move, move_copies_plain_field, move_copies_plain_element:
  removed. They documented the old copy; their cases (`<p.n`, `<s.p`,
  `<s.n`, `eat(<v[0])` of a `Vec[P]`) are in the new
  test/reject/ownership/move_part_that_copies.rig, and the plain read
  that replaces them is in test/behavior/ownership/move_leaves_source_done.rig.
- move_ends_copy_value: its field case (`m = <p.n`) is dropped; the test
  is about `<n` on a local.
- take_through_lend: `n = <(!s).n` became `n = (!s).n`; the take stays.
- sigils_before_calls: `Pair.name` became `String?`, so
  `name = <pair.name` still shows `<` before a place with no call, now a
  take that leaves `none`.
- Corpus probes t-mv1, t-mv2, t-mv4, audit-fuzz-pf1-accepted-ef0d28d8d2,
  audit-ownership-l07_defer_nested_scope_return: kept, now rejected, each
  with `# oracle: <fn> reject C3` and an `# error:` line giving the
  diagnostic (pf1's stale `# expect:` block replaced by them).
  review-seam2-c12_move_elem and review-place-b6-u012_mod_const_take are
  unchanged (still rejected, one more error each).

## Found while building (no program in the tree uses either)

- **A part of a branching value** (`<(a if c else b).v`): `sema.handsOver`
  calls it a part of a made value, so `walkMove` walked it as a value. On
  main, with `v: Vec[Int]`, it bit-copies `a.v` out and both `w` and `a`
  drop it: a use of freed memory under `RIG_SANITIZE=1`; the reference
  checker already rejected it (C3). With an `Int` field it copied and
  left `a.n` usable. Both are now `MoveSource.part` (rejected).
- **Another module's constant** (`<geo.K`): copied, while `<K` of the
  module's own constant was already rejected. Now rejected with the same
  message as `<K`; `<geo.KP[0]` with the part message.
- Left alone, by decision: `<mk().n` (a part of a value made in the
  statement, done with it), `<one` and `<geo.mk` (a function is not a
  binding), `<Color.red` (a value). The survey's `temp` and `name`
  categories counted these: 0 programs.

## Equivalence (test/equiv.py, base main c169ec89)

- Over main's tree: 9172 programs, 13 differ, exactly the 13 survey
  programs above (`check` and `facts` only; no `emit` or `pkg` change).
- Over the branch's tree: 9174 programs, 11 differ: the 7 corpus probes
  above, the 3 new reject tests, and SPEC's new reject example.

---

# Round 2 (after review-move-done.md), at c1a7d3f4

The class closed in round 2: every `<` source is classified by one fact,
`sema.moveSource` (a binding, an optional part of a place, a part, a part
of a branching value, a part of a made value, something that lives for
the whole program, a made value, or a branching value), for `<e`, a
`for x in <e` source, and each leaf of a branching operand
(`sema.moveLeaves`). Also: `<` on any non-optional part of a made value
is rejected (`<mk().n`), a function too (`<one`), a consuming method
takes a copy of a receiver that copies (`s.p.into()`), and sigil hints
say "remove the `<`", not "drop".

## Equivalence over main's tree (c169ec89 vs c1a7d3f4)

9172 programs, 49 differ (`logs/move-done/equiv2-base-tree.{out,classified}`):

- **accepted -> rejected: 12.** The 11 of round 1, and
  **test/corpus/review-take-p109.rig** (`r = <s.a?` with `s: !S`, a
  copying leaf: `s.a` was neither emptied nor rejected).
- **rejected -> accepted: 1.** test/reject/types/method_consume_without_move.rig
  (`u.consume()` with a `User` whose only field is a String: the
  receiver copies, so the call takes a copy). The test now uses a
  `Text` field, which moves, and is rejected as before.
- **rejected -> rejected, other messages: 36.**
  - 29 only reword "drop the `<`/`!`/`*`/`:`/`;`" to "remove the ...";
    3 of them are doc examples.
  - review-place-b6-u012_mod_const_take and review-seam2-c12_move_elem
    gain the round-1 error.
  - final-review-a5e-for-take-made-items gains "cannot move a part out of
    the temporary `mk()`" (`for x in <mk().items`).
  - review-take-p72 and p76 (`<o?.a`): the take through `o?` is now
    "cannot take out of `o?.a`: `o?` reads a binding where it stands",
    which replaces "cannot take out of a temporary".
  - audit-ownership-m11_consuming_method_on_field: the
    consuming-receiver hint for an owning field now names `replace`.
  - R13-s-t1: two consuming calls on copying receivers no longer report
    (it stays rejected for its `print` errors).

## Equivalence over the branch's tree

9227 programs, 86 differ (`logs/move-done/equiv2-branch-tree.{out,classified}`):
30 accepted -> rejected (the new reject tests and review probes, the 5
round-1 corpus probes, review-take-p109, and SPEC's two new reject
examples), 2 rejected -> accepted (consume_receiver_copies.rig and probe
p70, the M1 rule), 54 rejected -> rejected (wording and new tests).

---

# Round 3 (after review-move-done-2.md), at 19bec64d

- **Captures:** `sema.moveSource` has a `capture` case; `<` of any
  capture is rejected (a copy capture `|+n|` was left as it was).
- **Takes through a lent temporary:** an optional part reached through a
  lend or a call's view result of a value made in the statement
  (`<(!mk()).o`, `<gw(!mk()).o`) is `made_part`: "cannot take out of a
  temporary". A non-optional part reached that way is still rejected as a
  part through a view.
- **Consuming receivers through a view** of a value that copies take a
  copy (`p.into()` with `p: ?P`).
- **Oracle:** a branch whose type is a write view is a write view.

## Equivalence over main's tree (c169ec89 vs 19bec64d)

9172 programs, 51 differ (`logs/move-done/equiv3-base-tree.out`): the
49 of round 2, plus

- test/corpus/review-seam2-r2-w03_opt_take_temp.rig: rejected ->
  rejected; `x = <(!mk(1)).o` is now rejected too ("cannot take out of a
  temporary"), and `<(?mk(2)).o` says so instead of "through a read view";
- test/reject/types/method_consume_through_view.rig (main's version, a
  `User` of one `String`, which copies): rejected -> accepted (it takes a
  copy); the branch's test uses a `Text` field and stays rejected.

No other accepted -> rejected program: still the 12 of round 2.

## The reviewer's grid (grid.py, 28,815 cells), at 19bec64d

`logs/move-done/grid-19bec64d.{tsv,sum}`: base acc -> branch acc 3618,
acc -> rej 9666, rej -> acc 67, rej -> rej 15464; **0 oracle
differences** (was 126); **3685 / 3685 sanitized runs clean**; no cell's
branch verdict changed since c1a7d3f4.
