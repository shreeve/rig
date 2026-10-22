# PR #128 (setorder): one recorded order for every assignment

Branch `setorder` (worktree `../rig-setorder`), from `origin/main` at
facc5e672.

## The bug, on main

INTERNALS ("Assignments") documents `place op= value` as value first,
then the target, then the store, and the ownership checker walks that
order. Emit only hoisted the value and the indexes, and only when one of
*them* could act; a call, method, `?`, `!`, or branch the target's path
starts from (its base) was emitted in place, and Zig ran it first.

Sanitizer-visible failures on main (all fixed, all now tests):

- **Use of freed memory:** `take(<x, !a[..])[0] = x[0]` emits
  `rig.elemPtr(take(rig.take(&alive, x), ...), 0).* = x.at(0)`: `take`
  frees `x`, then the value reads it. The checker accepts it, since it
  walks the value before the move.
- **Leaks:** an owned value made first (`__rig_new`) leaked when a later
  step of the target left: `pick(!h, fail)?.l = <v`, `a[slot(fail)!] = <v`.
- **Wrong results / index panic:** rev126's `pick(!t, !i)[0] = s[i]`
  read `s[i]` after `pick` bumped `i` (out-of-bounds panic); compound,
  field, method-receiver, `?`/`!` roots, `while` steps, and `defer`
  assignments all printed values computed in the wrong order.

Dangling-view probes (a target lending `!v` while the value holds a view
into `v`; a base whose view an index then grows) are rejected by the
checker's loans on main: the base's write loan stays live while the
indexes run, which is exactly the order the fix now emits.

## Step 1: the class, form by form

| Form | Emit vs checker order on main |
|---|---|
| `=` / compound to a name | same (value hoisted when it acts) |
| `=` / compound to a field/element of a name | same |
| ... whose base is a call, method, `?`, `!`, branch | **diverged** (base before value; base after held indexes) |
| owned value + target step that leaves | **leaked** |
| `while c : step` assignment, `defer` assignment | **diverged** (same code path) |
| method receiver vs arguments | same (receiver, then args) |
| named arguments | same (`hoists_args`; `named.` grid) |
| `match` / `if … as` / `for` subjects | same (evaluated once, first) |
| `!` / `?` in an argument | same (guarded `defer` of hoisted args) |

## The fact

`storage.SetOrder` (decision `set_order`, `storage.setOrder(ctx, set)`,
read by emit as `Facts.setOrder`), a packed struct over the steps
`storage.eachSetStep` lists (value; base; indexes from the base out,
range bounds left to right):

- `held`: the value or an index can act (`setActs`), or the base can and
  the value is not pure: the value (unless pure) goes to `__rig_new`,
  then each non-pure index to `__rig_ix`, before the place is found.
- `base`: held, an index after the base is held, and the base does not
  stay (`baseStays`: a name or a lend of a name/field path): the base
  goes to `__rig_base` (new storage kind `base`) in its turn.
- `guard`: the value owns and a target step can leave (`setLeaves`):
  `var __rig_new` with a live flag and a guarded `defer` drop.

Readers:

1. the storage plan (`Planner.assignment`, `targetSteps`): records
   `new_value`, `base`, `index`, `slot`;
2. emit (`openAssign`, `openSetValue`, `hoistTarget`, `hoistBase`,
   `emitPlaceAssign`, `emitCompound`); `Pending.actsBeforeStore` is gone
   (pending budget 7 -> 4);
3. the ownership checker (`walkSet` walks `eachSetStep`; `walkFieldAssign`
   is now only the store);
4. the check-elimination redesign (PR #126, `proofs`) should read
   `setOrder` + `eachSetStep` to know which indexes are evaluated before
   the place is found and what each step may have changed by then.

Documented in docs/INTERNALS.md "Assignments" (the desugaring and the
fact), the storage-facts table, the decisions list; SPEC §4 sentence.

## Tests

- `test/behavior/emit/assign_target_root_after_value.rig` (call, method,
  slice, `?`, `!`, branch roots; `=`, `+=`, `-=`, `<<=`, `%=`)
- `test/behavior/emit/assign_target_root_in_step_and_defer.rig`
- `test/behavior/emit/assign_step_leaves_after_value.rig` (leaks)
- `test/behavior/ownership/assign_target_root_takes_value_read.rig` (UAF)
- `test/corpus/review-rev126-call_target_order{,_compound}.rig`
- `test/matrix.py` `order.` grid: 7 roots x 3 paths x 3 ops x 3 values
  + 8 leave cells (188 programs, debug and `--release`); on main 70 fail
  (12 of them use of freed memory, 4 leaks).

## Review

The independent review found two problems, both now fixed with tests.
First, a Cell-list target emitted its held base a second time, so Zig
rejected the unused `__rig_base` (`emitCellPtr` now reads the hoisted
base). Second, a pre-existing bug: a held index read through `!Int` was
typed as the view.

## Gates (at 038b02cb5)

Mac: suite --delta 3261/0, corpus 10034/0, order grid 188/188. The
matrix, unit and oracle gates are waiting for the pup gate slot. On a
loaded pup, cli/results_cache timed out and then failed again when run
alone (595s). It passes on the Mac. Check it in the pup slot.
equiv: 12,688 programs, 9 differ, in these categories:

1. value made before a target base that acts (`__rig_new` before a
   call / method / `?` / `!` base): the new tests, rev126 probes, and
   two sites of `test/behavior/ownership/store_into_unnamed_receiver.rig`;
2. base held before an acting index (`__rig_base`): one site;
3. guarded owned value when a target step leaves (`var` + live flag);
4. a held index typed as the number it reads (programs that did not compile before).
