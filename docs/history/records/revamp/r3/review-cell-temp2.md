# Review: cell-temp2 (543d4e2a, base 5db36f06)

Adversarial review of the second attempt at Cell temporaries: a
temporary whose type holds a Cell may be lent to read, be a `?self`
receiver, and have Cell members called on it, kept in its statement's
slot. One classifier, `storage.leafStep`, is meant to drive typecheck's
slot facts (`madeLeaves` / `keepReached`) and emit's walk
(`emitLeafPtr` / `emitPayloadHolder`), with `refuseHeldCell` as an
unreachable backstop.

Build: worktree `scratchpad/ct2-review` at 543d4e2a, `zig build` (Debug
compiler, as `bin/rig` ships). Main's compiler: `/Users/shreeve/Data/Code/rig/bin/rig`
at c1ed3fd9. Probes: `.git/revamp/r3/probes/review-cell-temp2/`.

## Verdict

- **No soundness hole found.** No accepted program wrote a Cell change
  into a copy, a const or Zig temporary, or read-only memory, or lost
  one, in debug (`RIG_SANITIZE=1`) or `--release`. No leak, no use of
  freed memory, no wrong output among ~9,900 accepted generated
  programs, 23 hand probes, and every earlier round's probe.
- **The emit backstop is still reachable from accepted programs (High,
  H1).** A `none` literal leaf of an optional that branches, reached by
  address, stops emit with "cannot emit a Cell held in storage Zig keeps
  for the expression". It includes read-only programs that main runs
  correctly (a regression).
- **A checker crash is newly reachable (High, H2).** A value made in a
  `catch` handler that the new slot facts keep, under a `?self` method
  returning a view, panics the ownership checker (index out of bounds
  in `mayOwnView`). A ReleaseFast build of the compiler reads freed
  checker state there instead, and accepted the program. Main has the
  same panic on rarer forms. The same root cause gives Medium M1:
  read-only programs that main accepts and runs are now rejected.
- Typecheck's slot facts and emit's walk agree everywhere else I tried,
  including round 2's shapes.

So: **no soundness hole and no wrong output remain; reachable internal
errors (H1) and a reachable compiler panic (H2) do.** The design
requirement "the backstop is unreachable from accepted programs" is not
met. Both findings are the same class: typecheck's slot facts and the
checker's or emit's model of the same leaf disagree.
- H1: `keepReached` filters out `.src` leaves (`leaf == .list`), while
  emit refuses them.
- H2: emit keeps a handler's slot in the statement, while the ownership
  checker scopes it to the handler.

## Method

| Run | Programs | Result |
|---|---|---|
| Earlier rounds' probes (`test/corpus/review-cell-temp-*`, `-2-*`, `review-cell-mut/*`), debug and release, oracle | 107 | all as expected (corpus outputs hand-checked where no `# expect:`) |
| Grid 1 (`grid/gen.py`, seed 7): random value expressions to depth 3 over names, made values, parts, `if`, `??`, `catch`, `e?`, `e!`; 6 types (`D` drop, `P` const ctor, `WD` part, `V` Cell[Vec]+drop, bare `Cell[Int]`, bare `Cell[Vec]`); all Cell ops, `?self`, `!self`, `look(?X)`, `poke(!X)`; 7 contexts (stmt, arg, if, while, loop, defer, match); each run at all 4 (k, j) | 8000 checked, 5009 accepted | **all 5009 exact in debug and release** (203 programs of 25); 20 checker panics (H2); 13 over-rejections vs main (M1) |
| Grid 2 (`grid/gen2.py`, seed 11): grid 1 plus `none` leaves, `catch \|e\|` handlers, a moved leaf `(<m)`, `G` (Text, no drop), `for` and `+=` contexts | 8000 checked, 4944 accepted | the 4772 without `none`: **all exact in debug and release**; the 172 with `none`: 99 exact, 57 internal errors (H1), 16 Zig compile errors (L1); 17 panics (H2); 14 over-rejections (M1) |
| Round-1 / round-2 grid samples (every 2nd / 30th, `sub main()` fixed) | 100 / 763 | see "Earlier grids" below |
| `rig check` over test/, examples/, std/ with main's and the branch's compilers | 9483 | 70 newly accepted (the branch's own tests and corpus); **1 newly rejected** (L2); no crash |
| Oracle on every probe and grid program | — | 0 differences; it abstains (`unknown`) on every branching Cell holder, and panics with the compiler on H2 |

Coverage of the accepted grid-1 programs: 1354 mix a name's leaf with
made leaves (940 with a change, 414 read-only), 496 have `catch`, 649
`??`, 1645 `e?`, 1208 `e!`, 1955 a part `.t`.

---

## High

### H1. A `none` leaf reaches emit's backstop (and a read main runs regresses)

**Probes** (`hand/`):
- `p12_none_leaf.rig`: `(o if k else none)?.hit()`
- `p13_none_leaf_read.rig`: `print("v", (o if k else none)?.c.get())`
- `p23_none_leaf_read_regression.rig`:
  `print("v", (b if j else (mko(5) if k else none)?).c.get())`. **Main
  prints `v 4 / q 0 / v 5 / q 0 / q -1`; the branch stops at the
  backstop.**
- `p22_all_none_branch.rig`: `((o if j else (none if k else none)) ?? a).n`
  with a type with no Cell. Main gives a Zig compile error; the branch
  gives "internal error: cannot emit a value of this type".

**Command:** `probes/review-cell-temp2/run.sh hand/p12_none_leaf.rig`

**Observed:**

```
44:16: internal error: cannot emit a Cell held in storage Zig keeps for the expression (sema should have rejected it)
```

**Expected:** `v 4 / drop 6 / drop 4 / q -1 / drop 2 / q -1`.

**Scope:**
- Grid 2: 57 accepted programs.
- Every shape with a `none` leaf inside a value reached by address:
  - `(none if k else o)?`
  - `((o if k else none) ?? a)`
  - `((none if k else mko(5)) ?? a)`
  - `(a if k else ((none if k else mko(3)) ?? mk(5)))`
  - the read forms of each
- Main accepts the read forms and fails on most of them with a Zig
  compile error (`'*?T' and '*const @TypeOf(null)'`). That part is
  pre-existing (L1).
- Two grid programs that main ran correctly now stop at the backstop
  (`grid/g2/none_main.txt`, `correct`).
- For a plain type the branch fixes main's Zig error (`p14`, now
  correct). For a Cell holder it refuses instead.

**Root cause:** one fact, decided by two classifiers.
- `storage.madeLeaves` returns `none` as a `.made` leaf. In
  `sema.leafHands`, `none` is `.made`.
- `Checker.keepReached` records the slot only for `leaf == .list`. A
  `.src` node has no slot, so `none` gets none.
- Emit walks to the same leaf (`emitLeafPtr` `.made`, or
  `emitPayloadHolder` `.made`) and finds no `dropsTemp`.
- `refuseHeldCell` then refuses it, because the type `T?` "holds" a
  Cell.

**Fix:** decide it once, in `leafStep`/`madeLeaves`. A `none` literal
(and any `.src` leaf) is a leaf that holds no value, so no change can
reach it. Its address is never captured as a payload: the
`|*v| v else ...` branch is never taken for it. Possible fixes:
- give it its own step (`.empty`), which emit writes as
  `&@as(?T, null)` in a `var` (or as the jump/fallback it implies),
  with no refusal;
- or have typecheck reject it with a diagnostic.

The `leaf == .list` filter in `keepReached` must go either way: it is
a second classification of the same leaves.

**Siblings checked:**
- No other `.src` value of a Cell-holding type is `.made`.
- Literals cannot have such a type.
- Module constants holding a Cell are rejected (`p16`).
- `match`/block/loop values are `.list`.

### H2. Ownership-checker panic: a made value kept in a `catch` handler, under a view-returning `?self` method

**Probes:**
- `hand/c01_catch_handler_me_panic.rig`:
  `print(((mkf(-1) catch mk(5)) if k else a).me().c.get())`
- `hand/c02_catch_handler_me_allmade.rig`:
  `print((mkf(-1) catch mkww(6).t).me().c.get())`. No name is involved.
- `hand/c04_main_panic_min.rig`
- `grid/panics.txt`: 37 grid programs, in every context. Every one has a
  value made in a `catch` handler that the slot facts keep, and `me()`.

**Command:** `bin/rig check hand/c02_catch_handler_me_allmade.rig`

**Observed:**

```
thread … panic: index out of bounds: index 2, len 2
src/ownership.zig:2263:34 in mayOwnView ← carryLoan ← carryAs ← carryResult ← walkCallBody
```

`rig-oracle` panics the same way.

**Expected:** accept and print `6 / 7`, or reject with a diagnostic.

**Main:** rejects these at typecheck, but panics the same way on 3 grid
programs (`hand/c03_main_panic_while.rig` =
`grid/single/s01905_WD_me_while.rig`, and `g2/single/s05051…`,
`s05711…`: `.inner.me()` on a part of a branch with a handler-made
leaf). So the bug is pre-existing; the branch makes it reachable from
many more forms (37 vs 3 in the grids).

**ReleaseFast compiler:** `zig build -Doptimize=ReleaseFast` (copy at
`scratchpad/rf/rig-releasefast`) has no bounds check there. It reads
past the end of the checker's var list:
- **c02 is accepted**, and runs correctly (`6 7`): emit's code is right.
- c01 is rejected with a different message.

Whether such a program is accepted therefore depends on undefined
behaviour in the checker.

**Root cause:** the checker does not check what emit emits (AGENTS:
"The checker checks exactly what is emitted").
- `keepReached` now records slots on values made in a `catch` handler
  (`madeLeaves` walks into `tailOf(handler)`).
- Emit declares such a slot with the statement's slots: in c02,
  `__rig_tmp_3: WW` is declared at the statement and dropped at its end.
- The ownership checker walks the handler in its own block scope
  (`walkCatch`: `pushScopeFor(.block, handler)`). So `holdTemp` adds the
  hidden var to the handler's scope.
- That var is popped when the handler ends. A loan rooted at it, carried
  through `me()`'s returned view (`carryResult` → `mayOwnView`), indexes
  a var that no longer exists.
- `dropStmtTemps` already skips such stale ids ("One whose scope already
  ended … was released there"). `carryLoan` does not.

**Fix:** hold a handler's statement temporaries in the statement's
scope, where emit puts them. Do this in `holdTemp`, or by walking the
handler's tail outside the pushed scope. A stale loan root should also
be an internal error, not an out-of-bounds read.

**Siblings checked:**
- `??` right operands are not scoped and do not show this.
- `if` branches are released "there", per `dropStmtTemps`.
- `match` arms are not branching forms here.

---

## Medium

### M1. Read-only programs main runs are rejected when a made leaf sits in a `catch` handler

**Probes:**
- `hand/p03_catch_handler_read_nodrop.rig`:
  `print((a if k else (mkf(-1) catch mk(5))).c.get())`. Main prints
  `1 6 1 5 6 7`.
- `hand/p01`, `p02`, and the enum form in `p10`'s first version.
- `grid/overreject_vs_main.txt`: 27 grid programs, all read-only (`get`,
  `geti`) on types without drop glue (`P`, `B`, `BV`, `G`).

**Observed:**

```
a view of the temporary `mk(5)` outlives its statement, which drops it; bind the value to a name first
```

**Root cause:** the same as H2. The slot that `keepReached` now records
for a no-drop Cell holder is held, in the checker, by the handler's
scope. `checkValueEscapesScope` then reports the in-place view as
escaping it.

Round 2 reported this as Low 1 ("over-rejection"), and it is still
present. It also blocks every change form through such a branch
(`(a if k else (mkf(-1) catch mk(9))).hit()`, `p02`). The H2 fix fixes
it too.

---

## Low

### L1. `none` leaves: Zig compile errors (pre-existing)

16 grid-2 programs fail to compile in Zig (`grid/g2/res_none/*.dbg`).
Examples:
- `'*const @TypeOf(null)' and '*?rig.runtime.Cell(i64)'`
- `value with comptime-only type '@TypeOf(null)' depends on runtime
  control flow` (in `poke(!…)`)

These are mostly on bare `Cell[Int]`/`Cell[Vec]` and in
`(if (k) null else o) orelse return null`. Main accepts 5 of them and
fails the same way. This is the same `none`-leaf class as H1, on the
by-value path. It is an accept-means-correct failure that predates the
branch, and should be fixed with H1.

### L2. Newly rejected corpus program

`test/corpus/review-place-b11-z5.rig`
(`for c in cs` / `(<c).push(1)`):
- main accepts it and runs it clean;
- the branch rejects it: "method `push` takes its receiver as a read
  view; cannot move" (the new `move_explicit` check in `cellVecCall`).

This is consistent with `(<x).set(5)` and `(<x).get()`, which main
already rejects. It is a safe tightening, and the corpus rule (reject
or run clean) still holds. It is the only verdict change over
test/, examples/ and std/ in that direction.

### L3. A `continue` in an argument after a name's leaf is reached

Probes `hand/p18_continue_arg_named_leaf.rig`, `hand/p17`.

In a loop, `(a if k else mk(10)).hitn(maybe(i - 1) ?? continue)` is
rejected: "use of `a` while a write loan is live". The same holds for
`.c.set(… ?? continue)`, `.c.replace(…)` and a bare `Cell[Vec]`
`.push(…)`. With `?? 0` or `?? break` it is accepted. The loan of the
receiver, held as the leaf's address, is carried around the loop's
back edge. Main rejects all of these for other reasons. This is safe.

### L4. The oracle gives no independent check of this feature

It abstains on every branching Cell holder (`ref=unknown`), and panics
with the compiler on H2.

---

## Things that hold (all exact in debug and release, sanitizer-clean)

- **Slot facts and emit's walk.** In every nested order, both grids
  matched for:
  - all-made sub-branches beside a name;
  - `mko() ?? M`, `mkf()!`, `mko()?`;
  - branching operands of `?`, `!`, `??` and `catch`;
  - parts (`.t`, `.inner`) of every shape;
  - moved leaves.

  Round 2's H1 shapes (`b01`, `b02`, `b05`–`b08`) all pass.
- **Views of slots never escape.** Each of these is rejected:
  - `x = (a if k else mk(5)).me()`, and the same for a `??` leaf, an
    all-made sub-branch, a part leaf, `.me().me()`, a struct field
    `HV(v: …)`, `!v.push(…)`, reassigning an existing view, a closure
    returning one, and a ternary of views.
  - Lends of a branch with a part-of-temporary leaf, in every form, `?`
    and `!`. The diagnostic is "a part of a temporary, which lending
    the branching value would copy".
- **Named leaves of every kind:**
  - view and write-view parameters, with `?mk()` and `!mk()` leaves;
  - by-value parameters, loop bindings and Vec elements (`p04`);
  - optional fields of named and made structs (`p11`);
  - enum payloads (`p10`);
  - closure captures `|?a|` and `|<b|` (`p05`).
- **Jumps.** `?? continue`, `catch break`, `?? return` and `!`
  propagation after a slot, in `for` and `while`, inside handlers and
  nested branches (`p05`, corpus `f01`/`f02`).
- **`defer` and closures** (`p05`, grid `defer` context).
- **Generics at Cell and plain types, including `.depends`:**
  - `H[X]` `?self` on all-made, `??` and `e!` shapes at `N` and at `Int`
    (`p07`, corpus `g01`);
  - instances at view types are rejected (`p15`);
  - instances at `Text` and `D` are rejected, as on main ("leaves a
    temporary…") (`p20`).
- **Array literals lent as slices** (`p09`). Each element's change
  reaches its `drop`.
- **Unique non-Cell types** (`p21`). A whole-branch lend is rejected,
  and `?r if k else ?mkr()` works.
- **Headers over branching Cell holders** are rejected as on main
  (`p19`).

## Earlier grids

Earlier rounds' grids, sampled with `sub main()` fixed (`grid/r1sample`,
`grid/r2sample`):

| Sample | Checked | Accepted | Rejected | Debug and release |
|---|---|---|---|---|
| Round 1 (every 2nd) | 100 | 96 | 4, all rejected by main too | **96 exact** |
| Round 2 (every 30th) | 763 | 520 (206 accepted by main) | 243, all rejected by main too | **520 exact** |

Round 2's sampled H1 (backstop) and M1 (`Cell[Vec]` named leaf) shapes
now run, and none regresses against main.

## Files

- `run.sh f.rig…` runs `rig check` on main and on the branch, a
  `RIG_SANITIZE=1` debug run, a `--release` build and run, and the
  oracle. Each run is diffed against `# expect:`, or, without one,
  release is diffed against debug.
- `par.sh logdir f.rig…` is `run.sh` in parallel.
- `hand/`:
  - hand probes `p01`–`p23` and `c01`–`c04`;
  - `t.sh` and `one.sh` write a one-statement program and check it on
    both compilers;
  - `pre.rig` is the shared prelude.
- `grid/gen.py`, `grid/gen2.py`: generators.
  - `single N SEED` writes the single programs;
  - `multi` groups the accepted ones.
- `grid/check_results.txt`, `grid/g2/check_results.txt`: per program,
  the branch's rc, main's verdict and the oracle.
- `grid/results_multi.txt`, `grid/g2/results_multi.txt`,
  `grid/g2/results_none.txt`: runs.
- `grid/panics.txt` (H2), `grid/overreject_vs_main.txt` (M1),
  `grid/g2/none_main.txt` (H1 and L1 against main).
- `logs-prev/`, `logs-corpus/`: the earlier rounds' probes.
