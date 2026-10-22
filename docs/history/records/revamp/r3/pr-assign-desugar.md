# Check and emit an assignment as its value, then its store

## Summary

Two review rounds of arm-temps found the same class twice: an
assignment's target is used **after** its value, and the checker and
emit disagreed about that order.

- Round 1 (l-probes): the target's views were treated as dead inside
  statements nested in the value. e65b2bff patched it by recording the
  target's uses at `extent(set).hi`.
- Round 2 (m-probes), live on main too:
  - **Critical (m42–m46):** the value's *last* nested scope (the last
    `match` arm, an `else` block, a `catch` handler) ends at the same
    position as the patched use. It could point the target's view at
    its own local; the store then wrote through freed memory.
  - **High (m47, m48):** a write-view name target `w = match …` was
    emitted as `w.* = switch …`. Zig takes the pointer before the value
    runs, so a value that re-points `w` stored to the old place (wrong
    output, or use of freed memory).

Instead of a third patch, assignment is now one desugaring, which both
the checker and emit follow:

```text
place op= value   ==>   { __v = value; place op= __v }
```

The value runs to its end first, with every statement and scope in it
and the drops and defers that end them. Only then is the target
evaluated and the store made.

## The checker

- `walkSet` walks the value, then the target, as before. While the
  value is walked, what the target reads is pinned live
  (`Checker.after_value`, `useAfterValue`; `holderLive` consults it).
  That is the liveness the desugared form gives: in
  `{ __v = value; place = __v }`, the target's uses are in the next
  statement, so they are ahead of every point in the value, its last
  scope's end included.
  - A field or element target pins every name in it.
  - A name target pins its binding only when the store reads it: a
    compound (`x op= v`), or a `!T` local given a value (written
    through). A re-pointed view or a plain reassignment reads nothing.
- **Jumps.** A jump out of the value never reaches the target, so
  `walkJump` drops the pins of every assignment it leaves (each pin
  records the loop around its assignment).
- **No patched positions.** The `indexUses` special case
  (`isSetTarget`, uses recorded at `extent(set).hi`) is removed. The
  target's uses are recorded where they stand, so a scope that ends
  after the assignment does not see them as live. That is why m50 and
  m51 (an assignment as a block's last line, through a view pointed at
  that block's local) stay accepted.

## Emit

A name store that writes a value, whether to a plain local or through a
`!T` local, now makes `__v` first whenever the value can act
(`storage.storesAfterValue`, recorded as the `new_value` storage fact):

```zig
{ const __rig_new_N: T = switch ...; w.* = __rig_new_N; }
```

Field, element and compound stores already did this (`openAssign`), and
so did reassigned resources (`openNewValue`).

## Other forms

`return value`, `break value`, and a new binding's initializer have no
place to evaluate after the value. Layout rejects a block in an
operand, an argument, a receiver, an index, and a struct or array
literal field; I probed the index and receiver here, and the reviewer
probed the rest. `defer w[0] = match …` stays rejected.

Jumps: a jump out of the value never reaches the target, so the
pins of the assignments it leaves are dropped on its path. Before, the
patched position over-rejected a labeled `break` out of the value whose
view was never used again; `assign_value_jump_leaves_target` (behavior
and reject) covers both sides.

## Docs

- docs/INTERNALS.md: a new "Assignments" section (the desugaring, the
  checker's and emit's sides, the other forms), plus the Liveness
  paragraph and the Emit "Assignments" bullet.
- SPEC §4: the desugaring in one sentence, plus one more (review Low 1):
  a temporary the value makes outside its nested scopes lives until
  after the store, as every statement's temporaries do. INTERNALS says
  the same.

## Tests

- **Reject** `test/reject/ownership/assign_target_after_value_scope.rig`:
  10 shapes, each with `errors: 10` at the re-point:
  - first arm, last arm;
  - `if` block, `else` block, `catch` block;
  - compound, field;
  - name in the first arm and in the last arm;
  - index target's read view.
- **Behavior** `test/behavior/ownership/assign_value_before_target.rig`
  (`# release`):
  - the name target re-pointed (m48);
  - re-pointed and then growing the old referent (m47);
  - a compound name;
  - an element (m38);
  - a field;
  - struct swaps through a plain local and a write view (m49);
  - the m51 shape.
- **Corpus:** every m-probe as
  `test/corpus/review-arm-temps-2-m*.rig`. The l-probes are already in
  the corpus and in `reject/ownership/assign_target_live_through_value.rig`.
- **Matrix `target.*`:**
  - targets: elem, compound, field, index, name, and the new
    `name_compound`;
  - nests: the new `last_arm`, `else_block` and `nested_last` (an
    `else` in a last arm), and `in_block` (the m51 shape);
  - acts: the new `drop`, `local`, `repoint_local`, `repoint_outer`
    and `repoint_grow`.

  Every valid cell must be accepted and print the stored value in debug
  and with `--release`. That is 402 programs (138 cells cannot stand).
  On the base (e65b2bff), 36 cells fail: use of freed memory, or wrong
  output for name targets. On this branch, 0 fail.

- **Corpus:** the fast-gate review's probes n01–n43, as
  `test/corpus/review-assign-desugar-n*.rig`. n04 (a write-view struct
  field target), n22 (a nested index whose view is re-pointed in an
  `else` block) and n34 (re-pointing at the subject's payload in the
  last arm) are live on main and covered nowhere else.
- **Oracle:** the oracle's five "stricter" verdicts on the arm-temps
  probes are now classified in `test/oracle/differences`:
  - l07, m15, m21: prod-strict;
  - m33, m34: ref-gap (real use-after-free shapes the oracle does not
    model: the old value's `drop` runs after the value).

## Results

Heads:
- 202b13fd: the fix;
- b1b1200d: merge of origin/main c0b21e50;
- ae0078d1: the jump tests;
- 9fc5359f: the review items (probes, oracle classification, docs, and
  a checked `appendSlice` in `walkJump`, Low 3).

**Gates:**
- Mac, 202b13fd, -j 2: all green.
  - suite: 2858 passed, 4 pending;
  - corpus: 7125 passed;
  - matrix: 5735 programs, 2784 ran clean, 2951 rejected, 0 failed;
  - unit: 128/129 (1 skipped).
- pup, ae0078d1, -j 16: all green.
  - suite: 2860 passed;
  - corpus: 7125 passed;
  - matrix: 0 failed;
  - unit: 127/129 (2 skipped);
  - oracle, doc, vocab: 341 passed.
- Mac, 9fc5359f, -j 3: all green.
  - suite: 2860 passed, 4 pending;
  - corpus: 7168 passed;
  - matrix: 5735 programs, 0 failed;
  - unit: 128/129.

**Probes:**
- m42–m46 are rejected ("`u` does not live long enough").
- m47 and m48 are accepted and correct in debug and `--release`
  (`7 201 201`, `7 3`).
- m50 and m51 are accepted and correct.
- Every other m-probe behaves as before.
- The oracle shows no DIFF on any m-probe. It is stricter only on m15,
  m21, m33 and m34, now classified.

**Targeted grid** (scratch generator, 783 programs):
- Axes:
  - 9 targets: elem, compound, field, field compound, index, name, name
    compound, plain local, plain compound;
  - 11 nests: arm, first and last block arm, `if`, `else`, `catch`,
    nested first and last, ternary, plain, and as the last line of a
    block;
  - 11 acts: lend another, grow, move, drop, a held read, re-point at a
    local, re-point at an outer value, re-point at an outer value then
    grow, re-point at a local then back, lend a local, a nested
    assignment.
- Each cell is decided up front: 503 must run and print an exact value,
  in debug under `RIG_SANITIZE=1` and with `--release`; 280 must be
  rejected.
- Branch: **0 failures**. The oracle agrees on all 783.
- `rig check` on the base and on main:
  - base e65b2bff accepts 28 of the 280 that must be rejected;
  - main d6b0b6b2 accepts 238 of them;
  - both accept all 503 valid cells.

**Equivalence against main c0b21e50** (`test/equiv.py`, 9533 programs,
at ae0078d1): 142 differ.
- `check`/`facts`: 7 programs, and nothing else changes. These are
  m42–m46 and the new reject test, newly rejected, and the jump
  behavior test, newly accepted.
- `storage emit pkg`: 100 programs; `pkg` only: 35. I read every emit
  difference: each is the new `__rig_new_N` hoist of a name store whose
  value can act, plus the hidden names it renumbers. The 35 pkg-only
  programs differ through std modules, for example `std.random`'s
  `x = self.next()`, which is now
  `{ const __rig_new_4: u64 = self.next(); x = __rig_new_4; }`.
- No program main accepts is newly rejected beyond m42–m46.
- **Rerun at 9fc5359f** (9576 programs): 152 differ. The new
  differences are the review's probes only:
  - n04, n22, n34, n39, n40 and n43: `check`, newly rejected, all live
    holes on main;
  - n12, n23, n24 and n38: emit, the same hoist;
  - two SPEC doc examples whose line numbers moved.

## Known items (not fixed here)

Review Low 2: conservative over-rejections, the same on main:
- **n05:** re-pointing a write-view struct field (`h.r = !u[0]`) in
  the value, then growing its old referent. `h` keeps the old loan,
  because loans are kept per var, not per field.
- **m15:** a read view re-pointed by the assignment keeps its old loan
  through the value (textual liveness).
- **m21:** the old value's `drop` reads a `?Vec[Int]` the value grew,
  which is safe.
- **l07:** a later arm's guard keeps the subject's view live in an
  earlier arm.
