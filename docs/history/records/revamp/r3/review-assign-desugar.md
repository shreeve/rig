# Review: assign-desugar (202b13fd)

"Check and emit an assignment as its value, then its store". Base
e65b2bff; compared against main c0b21e50 (`/Users/shreeve/Data/Code/rig/bin/rig`).
Worktree built at 202b13fd (bin/rig, bin/rig-oracle), removed afterwards.

Probes: `.git/revamp/r3/probes/review-assign-desugar/` (n01-n43, plus
`run.sh`, which runs the branch check, the main check, a debug run under
`RIG_SANITIZE=1`, a `--release` build and run, each with `timeout 20`,
diffed against an `# expect:` block, and the oracle):

    cd .git/revamp/r3/probes/review-assign-desugar && ./run.sh n*.rig

## Verdict

**I found no soundness hole.** Every program the branch accepts ran
sanitizer-clean in debug and printed the same output with `--release`,
and where it had an expected output it matched. The oracle agrees on
every probe (0 differences; n26 is `ref=unknown`, a generic instance at
a view). None of the findings below is Critical, High or Medium.

## What it had to close

| Probe set | Main | Branch |
|---|---|---|
| m42-m46 (the value's last scope re-points the target's view at its local) | accept, use of freed memory | **reject** (`u` does not live long enough) |
| m47, m48 (`w = match` through a `!T` local, re-pointed in the value) | accept, wrong store | accept, correct (`7 201 201`, `7 3`), debug and release |
| l01-l21 (every l-probe) | reject | reject, same diagnostics |
| m51, m50 (an assignment as a block's last line, through a view of that block's local) | accept | **accept**, correct (`5`) |
| m01-m41, m49 | as before | unchanged: the accepted ones run clean and correct, and the rest are rejected the same way |

Emit now gives m48 `{ const __rig_new_N: i64 = switch ...; w.* = __rig_new_N; }`.

## Siblings the branch also closes (live on main)

Each of these is accepted on main and rejected on the branch. I suggest
keeping n04, n22 and n34 in `test/corpus/`, because nothing in the suite
covers their target forms (the matrix has no write-view struct field
target, nested index, or payload re-point).

- **n04_struct_writeview_field_repoint_last_arm.rig**: `h.r = match`
  where `struct H { r: !Int }` is written through, and the last arm does
  `h.r = !u[0]` at an arm-local. On main this is a sanitizer **use of
  freed memory** at `h.r.* = __rig_new_1`. The branch rejects it.
- **n22_target_index_view_repoint_if.rig**: `a[r[0]][r[0]] = if ... else`
  where the else block re-points the read view `r` at its own local. On
  main this is **use of freed memory** in the index. The branch rejects it.
- **n34_repoint_at_subject_payload_last_arm.rig**: `w[0] = match mk()`
  whose last arm re-points `w` at the owned payload `p`. The branch
  rejects it.
- n39 (field compound `w.n +=`, last arm), n40 (name target, catch
  block), n43 (`u[w[0]][w[1]]`, last arm). The branch rejects all three.

## Hunt results

### 1. Target form × nested value × action × scope position

| Target | Probes | Result |
|---|---|---|
| name through a `!T` local | m45, m47, m48, n07, n10, n40, n12 (9 value types), n26 (generic `!T`, Int and String), n27 (owning `!S`), n31 (Cell holder) | Re-point at a local is rejected. Re-point at an outer value then grow the old one is correct. Drop or move of the referent is rejected. |
| name compound | branch test `name_compound`, n09 | correct (`13`, `105`) |
| `!Int` parameter | n08 | rejected earlier: a parameter cannot be re-pointed |
| element, compound element | m42-m44, m46, n16 (loop-body local), n17 (nested assignment in the value), n18 (break out of an inner loop), n21 (while step reads the view) | all rejected |
| field, field compound | n04, n39, n37 (the value moves the owner and makes a new one) | n04 and n39 rejected; n37 accepted and correct (`11 0`) |
| nested index `a[i][j]` | n06 (the value grows the outer Vec), n41 (through a slice, grow: rejected), n42 (re-point the slice at an outer Vec: correct `0 3`) | correct or rejected |
| `u[w[0]]`, `u[w[0]][w[1]]` | m46, n22, n43 | rejected |
| payload binding target | n13, n14 (the value replaces the subject) | rejected |
| Cell[Vec] element | n31 | correct |
| jumps out of the value | n01 (`return`), n02 (`!`), n03 (`break`), n20 (`continue`), n30 (inner break plus outer break) | accepted and correct: pinned targets cause no over-rejection on the error or return path |
| deferred block holding the assignment | n28 (reject), n29 (valid, correct) | correct |

`test/matrix.py -k target.` (402 programs: 177 ran clean, 225 rejected,
0 failed). `--oracle -k target.` gave 0 differences. The two new tests,
and the rest of `./test/run assign_`, gave 95 passed.

### 2. Order

There is no observable change from main. n38 prints the same sequence on
both (`arm, i, j, value, i2, j2, w-arm, w-value`). `openAssign` already
evaluated an element or field target's value first and then its indexes,
outermost first. The only change in emit is that a name store through a
`!T` local now makes `__v` before it dereferences the local. That is
what SPEC §4 has always said ("evaluates its value first, then the
indexes of its target from left to right"), and the new paragraph in
SPEC §4 and the INTERNALS "Assignments" section document it. A target
index may not be pure while the value is a mutable name (`a[bump(!x)] = x`):
`isPureArg` treats a non-fixed local as impure, so the value is still
hoisted, which is correct.

### 3. Value temporaries

- **Copies and Cell holders.** n12 (Int, Float, enum literal, optional
  `none`, String, Bool, struct, through `!T`) and n31 (unique
  Cell-holding values: moved into a plain local, into a `!C`, into an
  element, and a `Cell[Vec]` element) are all correct and leak-free.
  `__v` is a move or a fresh value, never a fork of a Cell. An owning
  `!T` still goes through `openNewValue` (drop the old value, then
  store), as n27 and n26 show.
- **Result-location aliasing with a pure value.** n23 (`if`/ternary,
  `match`, an array literal, and `!T`, each reading the place it
  replaces) and n24 (a match on the place being assigned, rebuilding it
  from its payload) are correct.
- **View value.** n11: a view made in `__v` and stored into a struct
  keeps its loan afterwards (a later `grow(!v)` is rejected). n15: a
  view value followed by a target index that grows the viewed Vec is
  rejected (the loan is held by the temporary through the index).

### 4. Over-rejection versus main

I ran `rig check` with both compilers over every `.rig` in test/,
examples/ and std/ (branch tree). The only differences are the five
corpus files m42-m46, which main accepts and the branch rejects as
intended. Nothing that main accepts is newly rejected.

### 5. Oracle

On every n-probe the oracle shows 0 differences. On the l and m probes
it shows only the pre-existing "stricter" differences (l07, m15, m21,
m33, m34), which are identical on main.

## Findings

**Low 1: the desugaring's text versus a statement temporary in the
value.** INTERNALS says the value runs to its end, "every scope it
opens, and the drops and defers that end them", and gives the form
`{ __v = value; place op= __v }`. But a temporary the value makes at its
own top level, outside any nested scope, lives to the end of the whole
assignment, after the store. n25 (`v[at(0, "index")] = mk(5).n`) prints
`index` before `drop 5`. Inside an arm the temporary drops at the arm's
end (`drop 6` before `index2`). Main does the same. The checker models
this consistently: n36 is rejected because the temporary's write loan
is live at the store, and the oracle agrees. So this is a gap in the
text, not in soundness. Suggest one sentence in INTERNALS "Assignments"
and SPEC §4: a temporary the value makes outside its nested scopes
lives to the end of the assignment, as every statement's temporaries
do. Otherwise a reader takes `__v = value;` as a statement that ends
them.

**Low 2: conservative over-rejections (pre-existing, not new).**
- n05 re-points a write-view struct field (`h.r = !u[0]`) inside the
  value and then grows the old referent. It is rejected because `h`
  still carries the loan of `v` after only its field is re-pointed. It
  is safe, but rejected on main too.
- m15 is still rejected: positional liveness sees `r`'s later use even
  though the assignment overwrites `r`. This is unchanged and already
  recorded.

**Low 3: robustness nit in `walkJump`.** The restore is
`defer self.after_value.appendSliceAssumeCapacity(kept)` after a
`shrinkRetainingCapacity`. It depends on nothing appending to
`after_value` while the jump is processed. That holds today, because no
assignment is walked there, but if a future append lands in that window
the restore overflows the capacity: an assertion in a safe build, and
undefined behaviour in a fast build. A plain `appendSlice` with `try`,
or restoring by saving the length, would remove the assumption. This is
not a correctness issue now.

## Code read

- `ownership.zig`: `useAfterValue` / `useAfterValueIn` pin every name
  in a field or element target. For a name target they pin the binding
  only when the store combines with it or writes through it; a
  re-pointed or plainly reassigned name reads nothing, and an old value
  whose drop runs a body stays live through `dropRunsBody`.
- `holderLive` consults the pins after the parameter, hidden and global
  checks.
- `walkJump` drops the pins of the assignments the jump leaves, using
  `encloses`; pins are ordered by nesting, so the first match is
  correct. `return` and `!` keep the pins, which only over-approximates
  liveness, and n01 and n02 show it causes no rejection.
- `cur_stmt` is restored with `defer`, so the target's uses (recorded at
  their own position now that `isSetTarget` is gone) are live during the
  target walk and the store.
- `storage.storesAfterValue`, `Planner.assignment` and the new
  `emitRebind` branch agree: `storageOf(value, .new_value)`. `__v` has
  the pointee type (`peelViews`), and the owning and generic paths still
  go through `openNewValue`.
