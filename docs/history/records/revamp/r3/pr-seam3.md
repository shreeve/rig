# Seam 3: a box, an optional, and a generic T hold a read view of an owner

Branch `seam3`, from main ecce07f7. No PR opened.

## What it does

A value that holds a read view keeps the viewed thing lent while it is
used, for every holder but `Cell`, `Signal` and an owned closure. Before,
`Box(?v)`, `id(?v)` (a generic function's `T = ?Vec[Int]`) and a generic
type with methods at a view were rejected by type; `Vec[?Vec]`, `(?Vec)?`
and a generic struct without methods already worked. Now all of them do,
for an owner too (`Vec`, `Text`, a struct, a `Box`, a `*T` handle).

## The decider (one place)

`sema.mayHoldView` (the `Views` bits that `SemContext.holds` computes by a
positive list of type forms: a view, a slice, a String, and every
optional, array, field, payload, handle, Box, Vec and generic argument
that holds one; a Cell's or Signal's value holds none). The ownership
checker's loan flow reads only that: a value of such a type carries the
loans of every view it was made from. The two rejections that said "a
Box/generic holds no view" are gone (`resolve.builtinElementError` for
`Box`, `Checker.checkInstantiations` for a generic function and for a
generic type with methods). No pass has a list of holders.

## Desugaring (INTERNALS, "A holder of a read view")

`h = Box(?v)`, `h = same(?v)`, `h: (?T)? = ?v` mean `view = ?v;
h = Box(view)` and so on: the loan on `v` lasts to the last use of `h`, of
a copy of `h`, or of a view `h` gave out (`?h.get()`; a bare `h.get()` is
the existing "lasting lend must be written" error).

## What stays rejected

- A write view as a type argument (`Box(!v)`, `id(!v)`): the "never
  stored" rule, now stated by `checkInstantiations` for an instance too.
- A generic body that stores its `T` in a Cell, Signal or owned closure,
  at a view (`checkViews`; its String-only guard is gone), and `Cell(?v)`.
- An owned closure that captures a holder of a view (already the case).
- `?bs` of a `Box[?Shape]` as a `?Shape` argument: type mismatch, as
  before (sound, not built).

## Emit

Two accept-means-correct bugs surfaced by the matrix, fixed with the
feature: a view held in a box is a pointer the box's pointer reaches
(`writeReach`, `writeMatchReach`, `textReach`), so field access, `match`
and Text calls through a `Box[?T]` dereference it.

## Tests

- Behavior (debug and `--release`): box, generic function, optional and
  generic struct (with a method) holding views of Vec, Text, a struct.
- Reject: owner written, moved or dropped while a holder is live (box,
  generic result, optional, generic struct); a holder returned past its
  owner; a generic body storing a view in a closure; a Cell/Signal.
- Removed: generic_fn_view_arg, generic_with_methods_view_arg (the
  rejections are gone); box_value_access, foreign_instance_ownership and
  a SPEC example lose their view cases.
- Matrix family `holder.` (owner x holder x change x live/done, 220
  programs): live must be rejected, done must print and run clean in
  debug and `--release`.
- Corpus: every probe of probes/cellstr as `seam3-cellstr-*`, plus
  `seam3-holder-*` (put, stack, method result, moved box, Text, write
  view, Cell).
- Oracle: it agrees on every program (0 prod-accepts). Its new decided
  rejections are listed in test/oracle/rejections; the allowlisted
  difference R11a-g1 is gone (prod now accepts it, as the oracle does).

## Gates (cpuq, Mac)

- `./test/run`: 3166 passed, 0 failed, 3 pending.
- `./test/run corpus` (all): 9842 passed.
- `test/matrix.py`: 6698 programs, 3402 ran clean, 3296 rejected, 0 failed.
- `zig build test` fresh cache: green.
- equiv against ecce07f7 (12406 programs): 48 differ, all in `check
  --facts`; 16 are programs the old compiler rejected and this accepts
  (each runs clean in the corpus/suite), 30 are programs both reject
  whose diagnostics changed; none accepted before is rejected now. Every
  program both accept emits identical Zig and an identical package.

## Decisions to confirm

CORE needs no change to stay true (section 5: "`Vec`, arrays, and fields
hold any value but a write view"). Proposed addition to section 5, after
its first paragraph, so `Box`, optionals and generics are named:

> `Box`, optionals, and a generic `T` hold any value but a write view,
> as a `Vec` does. A holder of a read view carries its loan: `Box(?v)`
> keeps `v` lent while the box, or a view it gave out, is used. *(built)*

Not done here: lending `?bs` of a `Box[?T]` as a `?T` argument (a lend
row for a view held in a box).

## Round 2 (review-seam3-1: S1)

A generic body that put its `T` inside `Vec[T]`, `*Hold[T]`, `~Hold[T]`
(or a struct holding one) and stored that in an owned closure or Cell
kept no loan: `heldTypeVars` is a by-value walk. The view requirement now
uses `sema.reachedTypeVars`, one walk through every constructor that holds
its arguments (optional, fallible, array/slice element, view, `*`, `~`,
and every argument of a generic instance, `Vec` and `Box` included).
That also closes the String hole on main (probes e12-e14: old accepts,
new rejects). All 95 review probes are in test/corpus as
`seam3-review1-*`; the matrix has `nest.` (8 wrappers x Cell/closure x 4
owners, 64 cells, all rejected for the right message). Gates: suite
3166, corpus 9937, matrix 6762 (0 failed), unit green, oracle green;
equiv: no previously accepted program is rejected but the three String
probes.
