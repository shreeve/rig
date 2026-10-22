# Review 2: arm-temps (45fa39d4, e65b2bff; base main d6b0b6b2)

FAST gate, independent reviewer. Worktree at e65b2bff (`zig build`,
`zig build oracle`). Probes: `.git/revamp/r3/probes/review-arm-temps-2/`
(m01–m51), driven by `run.sh` there (main check, branch check,
`RIG_SANITIZE=1` debug run and `--release` run under `timeout 20`, each
diffed against an `# expect:` block when present, then `bin/rig-oracle -v`).
"main" is `/Users/shreeve/Data/Code/rig/bin/rig` at d6b0b6b2.

## Verdict

**Not safe to land as is: a soundness hole of the class this round fixes
remains (Critical, oracle hard gate). A second, related hole is in emit
(High).** Both are on main too, so the branch does not make anything
worse. Every first-review l-probe now behaves correctly. The branch also
closes several holes that are live on main (m11, m12, m32, m39, m40, m41).

## Critical: the target's uses are recorded where the value's last nested scope ends, so that scope sees them as dead

`indexUses` records a use in a `set` target at `extent(set).hi`. That is the
position of the value's last leaf. It is not past that position.
`popScope` checks the loans of a scope's locals at
`end = extent(scope.node).hi + 1`, and a holder there counts as live only
if `last_use >= end`. For the value's **last** nested scope (the last
`match` arm, an `else` block, a `catch` handler), that scope's
`extent.hi` equals `extent(set).hi`. So a view used only in the target
looks dead when that scope ends. If the scope re-points the target's
view at a local of the scope, the check passes. The scope drops the
local, and the store then writes through the dangling view.

Non-last scopes are fine. The branch rejects m39 (`match`, first arm)
and m40 (`if` block). Main accepts and crashes on both.

| Probe | Form | Branch | Main | Debug `RIG_SANITIZE=1` | Release | Oracle |
|---|---|---|---|---|---|---|
| `m42_catch_block_repoints_to_local.rig` | `w[0] = fail(-1) catch \|_\|` / `u = …; w = !u[0..1]; 3` | accept | accept | **use of freed memory** at `rig.elemPtr(w, 0).* = __rig_new_1`, rc 134 | prints `7`; the store went to freed memory | **DIFF** C5 "`u` does not live long enough" |
| `m43_last_arm_repoints_to_arm_local.rig` | as m39 with the arm last | accept | accept | **use of freed memory** | wrong | **DIFF** |
| `m44_else_block_repoints_to_local.rig` | `if k` / `4` / `else` / `u = …; w = !u[0..1]; 3` | accept | accept | **use of freed memory** | wrong | **DIFF** |
| `m46_last_arm_index_target_view_local.rig` | `t[w[0]] = match …`, last arm re-points the read view `w` to an arm-local | accept | accept | **use of freed memory** in `rig.at(w, 0)` | prints `0 0` | **DIFF** |
| `m45_last_arm_name_target_repointed.rig` | name target `w = match …` (w: `!Int`), last arm re-points `w` to an arm-local | accept | accept | runs and prints `3`, because of the High finding below (emit stores through the old `w`) | same | **DIFF** |

Commands, for example:
`bin/rig check m42…rig` exits 0;
`RIG_SANITIZE=1 timeout 20 bin/rig run m42…rig` gives
`error: rig: use of freed memory … rig.elemPtr(w, 0).* = __rig_new_1`; and
`bin/rig-oracle -v m42…rig` gives `DIFF … prod=accept ref=reject C5`.

**Expected:** rejected, "`u` does not live long enough", as for m39, m40 and m41.

**Root cause.** This is the same class as the first review's finding.
Liveness is measured in positions, and "after the value" is recorded as
the value's own last position. The `while` step does the same thing
correctly: `stepAt` is `body.hi +| 1`, so the body's scope end
(`hi + 1`) still sees the step's uses.

**Fix direction.** I checked one option experimentally and reverted it.
Recording the target's uses at `extent(e).hi +| 1` rejects m42–m46.
But it then rejects a valid program, m51: a `set` that is the last line
of a block, whose target writes through a view re-pointed at that
block's local. The cause is that the enclosing block's end is also
`hi + 1`. Positions have no gap between the value's last scope end and
the enclosing scope end. Even so, the `hi +| 1` variant gives the same
`rig check` exit status as the branch on all 9,536 files under `test/`,
`examples/` and `std/`, so m51's shape appears nowhere in the suite. It
would be an acceptable conservative stopgap. A fact-based fix fits
better, though. Two options:

- Keep the target's roots live while the value is walked. For example,
  pin the vars the target reads as statement temps (`addTemp`;
  `holderLiveDepth` already treats a root in `self.temps` as live), and
  release them when the `set` completes.
- Give scope ends inside a set's value an `end` that `liveFrom` orders
  before the target's use.

Whichever fix is chosen, add m42–m46 as reject tests, plus m50 and m51
as valid ones. The matrix `target.*` axis misses this case because none
of its `nest` forms re-points the target's view at a scope-local. That
is the act missing from the axis: `repoint_local` × `last`/`not last`
nested scope.

## High: emit evaluates a write-view name target before the value (Zig result location); the checker and docs evaluate it after

For an element or field target, emit computes the value first:
`{ const __rig_new_1 = switch …; rig.elemPtr(w, 0).* = __rig_new_1; }`.
For a write-through store to a write-view **name** (`w = …` with
`w: !T`), emit writes `w.* = switch (k) { … }`. Zig takes the pointer
`w` before the switch runs and writes each arm's `break` value into it.
The new rule ("an assignment's target is used after its value") and the
element form (m23: the store goes through the re-pointed view) both say
the store goes through `w` as it is after the value. They differ only
when the value re-points `w`.

| Probe | Branch / main | Expected | Debug `RIG_SANITIZE=1` | Release | Oracle |
|---|---|---|---|---|---|
| `m47_name_target_repointed_then_grows_old.rig` (`w = !v[0]`; `w = match k` / `0` / `w = !u[0]; grow(!v)`) | accept / accept | `7 201 201` | **use of freed memory**: `break :__rig_blk_5 grow(&v)` writes into the old `w`, inside `v`'s freed buffer | `7 8 201` (wrong) | accepts (silent) |
| `m48_name_target_repointed_no_grow.rig` (same, no grow) | accept / accept | `7 3` | `3 8` (wrong, both modes) | `3 8` | accepts |

This breaks accept-means-correct (m48) and memory safety (m47) in
accepted programs, and the oracle does not see it. The oracle models
the source order, as the checker does. The divergence is in emit. This
breaks "the checker checks exactly what is emitted".

**Fix direction:** emit a write-through name store as
`{ const __rig_new = value; w.* = __rig_new; }` whenever the value can
hold a statement, as the element form does. The simpler fix is to do
that always. Struct values that read the target already come out
correctly in Zig 0.17 (m49), so the hoist costs nothing in correctness.

## Medium: none

## Low

- **Oracle gap, pre-existing (not this round).** The oracle accepts a
  reassignment whose old value's `drop` reads a slice that the right
  side reallocates:
  - `m33_slice_holder_drop_reads.rig` (nested arm);
  - `m34_slice_holder_drop_reads_plain.rig`: `h = H(v: ?v[0..1])`,
    `h = growh(!v, ?u)`, where `H.drop` reads `self.v[0]`.

  The compiler correctly rejects both. The oracle reports them as
  "stricter", but they are real use-after-free shapes. So the oracle
  cannot catch a future compiler regression of this shape: it does not
  model the old value's drop running after the right side.
- **Over-rejections, all shared with main:**
  - `m15` (read-view re-point, already listed in the PR);
  - `m21` (the old holder views the Vec itself, not a slice, so its
    drop is safe after growth; the oracle accepts);
  - `l07` (from the first review).

## What was checked and holds

1. **First-review l-probes** (`run.sh l*.rig` in
   `probes/review-arm-temps/`): every unsafe one is rejected by the
   branch, with the oracle agreeing (`0 differences`). That covers
   l09–l14, l16–l18, l20 and l21, including l13, l14 and l16, which
   main accepts. l01–l06, l08 and l15 stay rejected. l07 is the known
   over-rejection. None of the l-probes is a valid program the branch
   should run.
2. **The class beyond assignments.** Layout rejects a block-bearing
   form wherever source order could differ from evaluation order. I
   probed each of these (the parse errors were confirmed and the probes
   then removed):
   - a binary operand (`w[0] + match …` and `+ if …`: "expected an
     operand");
   - call arguments (`add(?v, if k …)`);
   - a method argument (`w.fill(match …)`);
   - a struct literal field and an array literal element;
   - `return w[0] + if …`.

   A block `catch` cannot sit under an operator (m05: its left side
   must be the call itself). `swap`/`replace` take their targets as call
   arguments, so no block fits there either. Rig has no string
   interpolation. `defer w[0] = match …` (m17) is rejected
   conservatively, because a deferred var is always live. Loops
   (m18, m20) and `for` sources (m26) are rejected correctly.
3. **Siblings that now hold on the branch:**
   - name target moved (m01), dropped with `-s` (m03), or moved in an
     `if` block (m28) or a `catch` block (m27) inside the value: drops
     are correct, sanitizer-clean in debug and release;
   - field partial move (m02): rejected;
   - an owner reassigned inside the value (m12, live on main): rejected;
   - compound on a write-view name (m11, live on main): rejected;
   - mixed view/value arms (m31, m32; m32 is live on main): rejected;
   - outer view of the name target taken in an arm (m25): rejected;
   - write-view re-point (m16, m38) and an element target re-pointed
     inside the value (m23): correct;
   - the owner's own place, `self.v[0]`, and the target's index lending
     after the value (m35, m36, m29): accepted and correct;
   - a nested `set` in an arm (m30): accepted and correct.
4. **Over-rejection against main.** `rig check` with main and the
   branch over every `.rig` under `test/`, `examples/` and `std/` (9,536
   files):
   - newly rejected: only `corpus/review-arm-temps-l13`, `-l14` and
     `-l16`, which are unsafe and correctly rejected;
   - newly accepted: the round's 3 behavior tests, plus corpus a01,
     p11 and q06/q07/q12;
   - no valid program is newly rejected.
5. **Matrix and oracle.** `test/matrix.py -k target.`: 120 programs,
   36 ran clean, 84 rejected, 0 failed. Its `--oracle` pass found
   0 differences.
6. **Oracle over every m-probe:**
   - DIFF (compiler accepts, oracle rejects) only on m42–m46: the
     Critical finding;
   - "stricter" on m15, m21, m33 and m34: Low;
   - silent on m47 and m48: the High finding.

## Soundness hole remaining?

**Yes, two:**

1. A view used only in an assignment's target is treated as dead at the
   end of the value's *last* nested scope: the last `match` arm, an
   `else` block, or a `catch` handler. Re-pointing it there at a
   scope-local is accepted and writes through freed memory (m42, m43,
   m44, m46; oracle DIFF).
2. Emit stores to a write-view name through its pointer as it was
   *before* the value, so re-pointing it in the value writes to the
   wrong place, or to freed memory (m47, m48; oracle silent).

Both holes are pre-existing on main. Both are in the class this round
names: "a construct whose source order differs from its evaluation
order".
