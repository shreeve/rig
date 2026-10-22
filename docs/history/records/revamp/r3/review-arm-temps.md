# Review: arm-temps (45fa39d4, base main b0f156c9)

FAST gate, independent reviewer. Worktree built at 45fa39d4 (`zig build`,
`zig build oracle`). Probes: `.git/revamp/r3/probes/review-arm-temps/`,
driven by `run.sh` there (branch check + main check, `RIG_SANITIZE=1`
debug run and `--release` run under `timeout 20`, each diffed against an
`# expect:` block if present, then `bin/rig-oracle -v`). The full suite
was not rerun: the 1-minute load was ~25 throughout.

## Verdict

**Not safe to land as is. One soundness hole is opened by this commit
(Critical), and it is a widening of a pre-existing hole of the same class
on main (High).** Everything the round set out to do (arm temporaries
live and drop in the arm; q06/q07/q12) works and is consistent between
`pat => s` and block arms.

## Critical — an arm's write lend/move is checked as if the enclosing assignment's target were dead

The new rule counts liveness from the arm's own statement
(`Checker.liveFrom` uses `stmtStart()` of `cur_stmt`, now the arm body).
When the `match` is the value of an assignment to a place, the target
place (`w[0]`, `w.n`, `u[w[0]]`) is used *after* the value is computed,
both in the source semantics and in emit
(`{ const __rig_new_5 = switch (k) {...}; rig.elemPtr(w, 0).* = __rig_new_5; }`),
but textually *before* the arm. So a view used only in the target has
`last_use < stmtStart(arm)` and is treated as dead inside the arm; an arm
may then lend its owner to write, reallocate or move it, and the store
writes through the stale view.

Main rejected every one of these; the branch accepts them:

| Probe | Branch | Debug `RIG_SANITIZE=1` | Release | Oracle |
|---|---|---|---|---|
| `l10_assign_target_slice_grow.rig` (`w = !v[0..1]`; `w[0] = match k` / `0 => grow(!v)`) | accept | **use of freed memory**, rc 134 | prints `7 201` (store lost into freed buffer) | DIFF: ref rejects C4 |
| `l11_compound_target_grow.rig` (`w[0] += match ...`) | accept | **use of freed memory** | wrong output | DIFF |
| `l12_field_target_grow.rig` (`w = !v[0]`; `w.n = match ...`) | accept | **use of freed memory** | wrong output | DIFF |
| `l18_assign_target_match_move.rig` (`0 => sink(<v)`, v moved and freed) | accept | **use of freed memory** | — | DIFF: ref "cannot move `v` while a write loan of it is live" |
| `l21_assign_target_index_view.rig` (view read in the target's index, `u[w[0]] = match ...`) | accept | **use of freed memory** | wrong output | DIFF |
| `l09_assign_target_view_grow.rig` (`w = !v`; `w[0] = match ...`) | accept | runs (`201 201`) | ok | DIFF (C4) |
| `l17_assign_target_match_view_read.rig` (arm reads `?v` while `w = !v[0..1]` is live for the store) | accept | runs | ok | DIFF (C4: read while write loan live) |

Commands, e.g.:
`run.sh l10_assign_target_slice_grow.rig` or by hand
`bin/rig check l10…rig` (0) and
`RIG_SANITIZE=1 timeout 20 bin/rig run l10…rig` → `error: rig: use of freed memory … rig.elemPtr(w, 0).* = __rig_new_5`.

Expected: rejected, as main does: `cannot lend 'v' to write while a write loan is live` (note: `w = !v[0..1]`).

All seven are compiler-accepts / oracle-rejects: hard-gate findings
independent of the sanitizer result.

Simple-name targets are not affected (`l20_assign_field_of_moved_owner`
correctly rejects use after move of the target's owner, because the target
is walked after the value and the move is seen there); only views used in
a place target (base or index) whose loans are checked by liveness.

## High — the same class already exists on main for every block nested in an assignment value

This commit gives `pat => s` the liveness of a block line; block lines
already had the hole. All of these are accepted **by main and the branch**,
crash with use of freed memory under `RIG_SANITIZE=1`, and the oracle
rejects them (DIFF, C4):

- `l13_assign_target_view_grow_block.rig`: block-bodied arm, `w[0] = match k` / `0` / `  grow(!v)`.
- `l14_assign_target_if_block_grow.rig`: `w[0] = if k` / `  grow(!v)` / `else` / `  3`.
- `l16_assign_target_catch_block.rig`: `w[0] = f(-1) catch |_|` / `  grow(!v)`.

The ternary form (`l15`, `w[0] = grow(!v) if k else 3`) is rejected,
because its branches are part of the statement.

**Root cause (the class):** `liveFrom` takes the *innermost* statement's
start as "now", and a use is live only if `last_use(sym) >= now`. That is
right for a top-level statement, but an assignment to a place uses its
target after its value, so any nested statement inside the value (block
line, if-branch block, catch-handler block, and now a `match` arm) sees
the target's views as dead. The commit's claim that "nothing past an arm
can view what the arm made" is true for the arm's *temporaries*, but the
liveness half of the change rests on "nothing past an arm uses what was
live at the statement's start", which `place = match …` breaks.

**Fix direction (one fact, not per-site):** make the target's uses count
as at the end of the enclosing statement, e.g. walk the target's base and
index views before the value and keep their loans as statement temps
(`addTemp`; `holderLiveDepth` already treats a root in `self.temps` as
live, and `walkStmtValue` only trims temps added after its own start), or
have `liveFrom` take the outermost enclosing assignment's end when the
var is read in that assignment's target. Add `l10`, `l13`, `l14`, `l16`,
`l18`, `l21` as reject tests (and `test/matrix.py` should grow a
"place target × nested statement form × write lend/move/read" axis, which
would catch the siblings).

## Low — over-rejection: a later arm's guard keeps a view live in an earlier arm

`l07_subject_viewed_by_guard_after.rig`: `x = ?v[0..1]`; `r = match k`
/ `0 => grow(!v)` / `_ if x[0] > 0 => 1`. Rejected by branch and main;
oracle accepts (a guard of a later arm never runs after an earlier arm's
body). Pre-existing, textual `last_use`; not a soundness issue.

## What was checked and holds

All accepted ones run sanitizer-clean in debug and release with the
expected output, and the oracle agrees (or is `unknown` only for
"a branching value holding a Cell").

1. Arm temporaries referenced after the arm:
   - Value of the match viewing an arm temporary is rejected, simple and
     block arms: `p01` (`0 => mk(5).me()`), `p02` (`?mkww(5).t`), `p06`.
   - `return` (`p03`) and `break` (`p04`) of a view of one: rejected;
     `break` of an owned value built from one (`p07`) runs clean.
   - Owned field moved out of an arm temporary (`p05`): rejected.
   - Assigning a view of an arm temporary to an outer var: rejected,
     both forms (`c02`, `c03`).
   - Nested matches, `if`/`else` inside arms, Cell holders changed through
     `?self` (`a01`): changes land in the arm's slot, which is dropped at
     the arm's end with the changed value (`drop hc 12 5`, ...).
   - Inner match subject/guards making temporaries inside an arm (`h02`):
     each dropped at its header's end. A header viewing a temporary is
     rejected (`h01`).
   - `catch` inside an arm (`p10`, `p11`): the handler's temps are now the
     arm statement's; emit's slot is the arm's and the checker's hidden
     var ends there. `p11` (handler builds `HC(v: x)` viewing the arm
     binding) was rejected on main and is now accepted and correct.
   - `defer` in an arm (`p08`, `p09`): the deferred statement's temps are
     its own; order correct.
   - Closures: captured arm bindings or names viewing arm temporaries
     cannot leave the arm (`c01`, `c06` rejected); a closure called in the
     arm (`c04`) runs clean.
   - Function-tail match with arm temps, block arm and `return` arm (`f01`).
2. Liveness: subject write view used later in the arm through a payload
   binding (`l01` simple, `l02` block, `l03` place subject) rejected; view
   used after the match (`l04`), in an earlier arm across loop iterations
   (`l05`, `l06`), in a `while` step (`l08`): all rejected. The only hole
   found is the Critical/High class above.
3. Consistency: block vs `pat => s` agree on every probe pair
   (`c02`/`c03`, `l01`/`l02`, `l10`/`l13` — the last pair agrees by both
   being unsound).
4. Oracle: run on every probe. Differences only in `l09`–`l18`, `l21`
   (above) and the over-rejection `l07`.

## Soundness hole remaining?

**Yes.** With this commit, `place = match …` (and `place op= match …`)
whose arm lends, moves, or reads the owner of a view used in `place` is
accepted and writes through freed memory (`l10`, `l11`, `l12`, `l18`,
`l21`). The same hole exists on main for block arms, `if` blocks and
`catch` blocks in an assignment value (`l13`, `l14`, `l16`), so the fix
belongs to the liveness rule, not to `walkMatch`.
