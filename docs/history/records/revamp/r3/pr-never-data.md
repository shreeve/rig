# Mutation is never data

Branch `never-data` (from main 0fc49541), PR #97.

## What it does

The four approved rules, each decided once, by a positive list:

1. **A Cell lives only behind `*`.** A type holding a Cell by value may be a
   struct or enum field, but a value of it stands only behind `*`/`~` or a
   view. Rejected as a local, parameter (a by-value `<self` too), result,
   type argument, element, or optional; a call that makes one is accepted
   only as the operand of `*`, a user constructor's field argument, or a
   field default. Deciders: `sema.misplaced` (types, asked by
   `TypeResolver.misplacedAt` for every spelled type and by
   `checkGenericInstantiations` for every instance's arguments) and
   `Checker.cellMadeAway` (made values).
2. **A write view is never stored inside a value.** `!T`, `(!T)?`, `(!T)!`
   only as a parameter, receiver, result, or local/header binding:
   `sema.writeViewMisplaced` (structural, so a type is rejected where it is
   written).
3. **Rule 3p**, and
4. **the branch redesign:** every in-place use of a branching value (or a
   path from one) as a view is a lend decided by `lendsBranch`: a sigil, a
   slice, `for x in ?S`/`!S` (closes header-paths-2 C1), a bare header
   subject that does not copy (`headerLendsBranch`, replacing
   `headerCopiesWriteView`), and a value checked against a view type
   (`checkExpr` → `lentInPlace`: a write view passed or bound, rule 3p; a
   write view narrowed or an owner lent implicitly to a read view, closes
   C2). A function's result is exempt. A branch of read views copies.

Also fixed here, from the group-1 helper (all three were on main too):
- an implicit slice lend of a temporary array of owners leaked; it is now
  held and dropped as `?[...]` is (`lendTempArray`);
- a pointer to a handle (a hoisted receiver of a `*T` element with
  reordered named arguments; a branch of `?h` lends followed by a field)
  is dereferenced before the handle's value is reached (`derefToHandle`).

And two more accept-means-correct bugs on main, found by running every
review probe (payload-loan-4 i01/i02/i04/i05/i07): a loop over a
`Vec[?P]` bound a pointer to each view (a field then failed in Zig; the
element, itself a view, is now copied), and a generic closure's `|?x|`
capture of a write-view binding stored the pointer where a
`rig.ReadView(T)` goes. Both fixed in emit, with
`test/behavior/emit/view_reached_through_pointer.rig`. A read lend of a
handle's Cell-holding value (`bump(c)` for `?Cell[Int]`) is now the mutable
pointer itself rather than `rig.lend`, which no longer special-cases Cells.

## Review round (review-never-data-1)

- **F1 (use-after-free, also on main): a branch of Cell-holding places was
  copied by value.** `print(a.s if k else b.s, grow(?a2.s))` copied `S`
  out of the branch while another handle reallocated its Cell. Class: a
  value holding a Cell made outside `*` by a branching form. `cellMadeAway`
  now decides branching values (`sema.yieldsPart`: `if`, block, `match`,
  `??`, `catch`, `e!`, `e?`) as well as calls: by a positive list of leaves
  (made, lend, jump, constant), a branch with a leaf a name holds is
  rejected unless read in place (`Checker.in_place`: a member or method
  receiver, a lend's operand, a `match` subject), with the hint "lend each
  branch: `?a.s if k else ?b.s`". Siblings checked: `Text(...)`, a closure
  call, `a.s.c if k else b.s.c`, block `if`, `match`, bindings, `take`
  arguments. Tests: `test/reject/ownership/branch_copies_cell_holder.rig`,
  the matrix family `cellbranch.<form>.<context>.<leaf>` (18 reject cells),
  `test/behavior/ownership/branch_of_lent_cell_holders.rig`.
- **F2 (Zig failed to compile, also on main): a generic closure's captured
  `?f` was called with the wrong argument form.** A capture `|?f|` has the
  type `?fun(...)`, whose parameters `storage.fnType` did not read, so
  `f(w)` emitted `rig.viewed(T, cap_w)`. Class: emit and checker reading a
  callee's parameters differently. `sema.calledFn` is now the one reader
  (checker's `callValue` and `storage.fnType`), and it also covers owned
  closures. Tests: `test/behavior/emit/generic_closure_*.rig` (4; debug
  sanitizer and `--release`).
- All 147 review probes are kept in `test/corpus/review-never-data-1-*`;
  the oracle's 14 rejections of them are listed.
- CORE text approved by the owner is a separate commit (80079692), with
  the SPEC and INTERNALS references updated.

## Deleted (each unreachable once the rules hold)

| What | Why unreachable |
|---|---|
| per-instance interior mutability: `sema.interiorMutable`'s `.depends`, `rig.ReadPtr`, `rig.ReadSlice`, runtime `interiorMutable`, `__rig_interior_mutable`, `emitInteriorMutable` | no type argument holds a Cell (`misplaced(.type_arg)`), so every instance answered no; `interiorMutable` itself became `holdsCellByValue` |
| Cell temporaries: `cell_temps`, `recordCellTemp`, `lendsCellTemp`, storage `cell_slot`/`cell_copy`, emit's three sites | a value holding a Cell is made only under `*` or as a field of one (`cellMadeAway`) |
| `refuseHeldCell`, `emitCellAddress`'s made-leaf loop, `storage.madeLeaves` | same |
| `requireCellPlace`, `keepsCellChange`, `keepReached`, `ownsBinding`, `Access.set_cell`, `cell_place` | every Cell is reached through a handle or a view |
| `as` over an optional of a Cell holder (TC14/15), the `no_cell` requirement, `readBinding`, a local holding a Cell is `var`, `[]` of Cell holders, element-in-place for Cells | no binding, optional, element or type argument holds a Cell |
| `Access.write_through`, `recordThroughWrite`/`writesThrough`, emit/storage/ownership write-through-a-field paths | no field or element holds a write view |
| `Access.lend_on`, `Access.pass_write`, requireAccess's held-write-view messages, `checkLendsVisibly`'s field path | same |
| `loopHoldsWriteView`, `payloadReadsThroughWrite`, ownership's "bare use of a field holding a write view", `viewInstance` hint | same |
| `sema.headerCopiesWriteView`, `reportHeaderWriteViewCopy`, `HeaderKind` | replaced by `headerLendsBranch` → `lendsBranch` |

(A branch leaf holding a Cell, read in place as a receiver or a lend's
operand, keeps its write loan in ownership. A branch of such places read by
value is now rejected in typecheck, below.)

src: 817 lines deleted, 545 added (net −272), incl. the new deciders and a
structural unit test pinning them ("where a Cell and a write view stand, and
a branch lent in place, are each decided once").

Kept, still reached: `makesWriteView`'s leaf loop (made-leaf branches stay),
`readOnlyStep`'s branch walk and `writeMatchAdvice`'s branch hint (branches of
read views), `viewGivesUp`/`movesBecause` write-view wording (`(!T)?`
locals), `storage.genericReadView`'s Cell exclusion (a generic struct with a
`Cell[T]` field).

## Migration

| Before | After |
|---|---|
| `c = Cell(0)` | `c = *Cell(0)` |
| `k = Counter(hits: Cell(0))` | `k = *Counter(hits: Cell(0))` (field defaults `hits: Cell[Int] = Cell(0)` unchanged) |
| `sub f(k: Counter)`, `-> Counter` | `?Counter` (given the handle `k`), or `*Counter` |
| `Vec[Cell[Int]]`, `Box[Counter]` | `Vec[*Cell[Int]]`, `*Counter` |
| `\|!total, l\|` capturing a bare Cell | `total = *Cell(0)`, `\|+total, l\|` |
| `fresh(0).hit()` (a Cell temporary; `fresh` returns a `Counter`) | `fresh` returns `*Counter` (`*Counter(...)`), then `fresh(0).hit()` |
| `struct H { w: !Int }`, `Vec[!Int]`, `Opt[!Int]` | pass `!v` to each call (a parameter), or a local `w = !n` |
| `inc(a if c else b)` with `a`, `b: !Int` | `inc(!a if c else !b)` |
| `sl(a if c else b)` narrowing `!Vec` to `?Vec` | `sl(?a if c else ?b)` |
| `for x in ?(a if c else b).v` | `for x in ?(?a if c else ?b).v` |
| `match (a if c else b)` of `!E` names | `match (?a if c else ?b)` (or `!`) |

## Fallout

- examples/, std/: none. README, WELCOME, STD, DESIGN, FAQ: none.
- test/behavior: 128 programs flipped. About 100 were rewritten in place
  (the Cell or write view was incidental), 6 became reject tests of the new
  rule, and 19 that tested only a removed form were removed (Cell
  temporaries, Cell holders by value, write views in fields, payloads and
  elements; each is covered by `test/reject/types/cell_by_value.rig`,
  `cell_made_outside_shared.rig` or `write_view_stored_in_value.rig`). A few
  Cell tests are weaker: a wrong copy behind `*` would now show as a leak or
  sanitizer crash, not as wrong output.
- test/reject: 100 expected different diagnostics; 64 keep their subject,
  36 now expect the new rule's diagnostic.
- matrix: `cell.` 342→3, `cellmut.` 131→17, `celltemp.` 103→3 (reject cells,
  plus an accepted `cellmut.` slice behind `*`); `hdr.` 156→96, `lendw.`
  1368→768, `viewpay.` 142→122, `sliceview.` 160→144, `store.` 72→64.
- corpus: 655 probes of the removed forms are now rejected (allowed by the
  corpus contract); the stated `# oracle:` verdicts of 288 functions in 134
  probes whose module is now rejected were removed. Oracle: 4 new listed
  rejections, 6 allowlisted differences gone; every floor still holds.
- equiv against 0fc49541 (12,007 programs): no program flips from rejected
  to accepted; 695 flip to rejected, all in test/corpus (655) and
  test/reject (40); every behavior test, example, std module and doc
  example the tree keeps is accepted by both. 2,797 accepted programs emit
  differently (no `__rig_interior_mutable` marker, `[]const` slices, the
  emit fixes above); every package differs because the runtime changed.
- Review probes (payload-loan-1..5, header-paths-1/2, syntax-b-2; 2,312
  programs): 2,061 rejected, 251 run sanitizer-clean.
- docs: CORE (separate commit, below), SPEC, SYNTAX, INTERNALS.

## Gates (head ecce09ef, on the Mac through cpuq, cores 2-6, after merging main with #98)

- suite `--delta`: 3,103 passed (1,402 carried over), 0 failed, 3 pending
  (the one style failure of a reviewer probe was fixed and the style,
  oracle and probe tests rerun: 153 passed).
- corpus `--delta`: 9,649 passed, 0 failed.
- matrix `--delta`: 6,418 programs, 3,255 ran clean, 3,163 rejected, 0 failed.
- `zig build test`: passed.
- every review-never-data-1 probe is rejected or runs sanitizer-clean.
- Earlier (head 7d224dab, pup): suite, corpus, matrix and unit passed; equiv
  against 0fc49541 and the review probes, above.

## Follow-ups

- Generic inference through a handle: `peek[T](c: ?Cell[T])` given a
  `*Cell[Int]` fails ("expected `Cell[T]`, got `*Cell[Int]`"); the concrete
  `?Cell[Int]` accepts it. On main too; a wrong rejection, now more visible.
- `Box(Cell(3))` reports the Cell twice (the made value and the type
  argument).

## Decisions to confirm (owner approves CORE text)

1. **Sentence 9** (replaces "Every change is marked by `!` where it is lent,
   with one exception: a `Cell` changes through any path"):
   > You change what you were lent with `!`, or what you share with `*`. A
   > name's own value changes by assigning it. A `Cell` is what handles
   > share: a value that holds one lives only behind a shared handle
   > (`*Cell[T]`, or `*S` where a field of `S` holds one), and changes
   > through any path from it, a read view included. A write view is never
   > stored inside a value: `!T` (also `(!T)?` and `(!T)!`) is only a
   > parameter's, a receiver's, a result's, or a local or header binding's
   > type, never a field's, an element's, or a type argument.
2. **§1, Cell bullet** (was "is unique too, because a copy would fork
   state"): "lives only behind a shared handle (sentence 9), so a value of
   it is never copied or moved: it is made under `*`, as a field of a value
   made there, or as a field's default."
3. **§1 kinds**: "otherwise a view if any part is a view; otherwise plain.
   No part is a write view (sentence 9)." (drops "moving, if one is a
   write view").
4. **Sentence 1**: "a write view of a value that copies ... reads the value
   it sees, so `x = w` with `w: !Int` copies the Int" (drops "whether a
   name, a field, or an element holds it").
5. **Sentence 4**: "`?` promises that nothing changes but a `Cell`, which
   lives behind a shared handle (sentence 9)."
6. **§3, new built paragraph**: "A branch is a value, never a place.
   Wherever a branching value, or a path from one, is used where it stands
   as a view (a sigil, a `for`'s `?` or `!`, a header's subject, an argument
   where a view goes, or a write view passed or bound), it is lent there,
   and a leaf a name holds is rejected: each branch is lent instead. A
   branch of read views copies the view it takes, and is only read."
7. **§5 title and first sentence**: "Containers and fields hold values":
   any kind of value but a write view, and a value that holds a Cell only as
   a field.
