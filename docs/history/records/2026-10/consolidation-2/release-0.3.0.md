# v0.3.0's newly rejected forms (consolidation round 2, track 7, 2026-10-24)

How the 42 forms in CHANGELOG's "Upgrading from v0.2.9" were found and
confirmed, and what the migration guide (docs/MIGRATING-0.3.md) rests on.

## Method

1. `v0.2.9`'s compiler built from the tag (its tracked `src/parser.zig`)
   and `main`'s at 725e2bb9d (#646 and #647 included).
2. Every program `v0.2.9` carried: test/behavior, test/corpus, examples,
   and each plain ```` ```rig ```` block of its docs, 8,711 in all.
   `v0.2.9`'s `rig check` accepts 4,836 of them; those are the set.
3. `main`'s `rig check` on the set: 1,095 accepted as written. After
   `tools/migrate-0.3.py apply --force` on every file and the five
   spelling scripts removed in 8969d452b (receiver, labels,
   labels-dollar, builtins, fixedbind), restored from history for the
   count only: 3,391 accepted, 1,445 rejected.
4. The 1,445 grouped by message, every error of each file: 80 classes,
   each read from its program. A class that the migration's own text
   caused (a `self` local made `@`) is left out; the rest are the 42
   forms, some classes joined into one form.
5. A program in `v0.2.9`'s spelling for each form where the corpus had
   none or one only (fixtures: panic as a name, `@size`, `const`, a
   Cell's `replace`, `replace(!a, v)`, `[N: Int]`, `[t]`, `*g`, a
   closure never called, `e == f` of caught errors, a type named
   `Task`, `lib.Cell(1)`, a method parameter named as a module
   function, `time.sleep` unhandled): `v0.2.9` accepts each, and
   `main` rejects each, after the renames, with the form's message.

## The largest classes (files whose first error is it)

| Files | Form | Example |
|---|---|---|
| 1,475 | self is `@` (before the receiver pass) | behavior/emit/branch_receiver_copy_not_dropped.rig |
| 358 | a value holding a Cell lives behind `*` | behavior/emit/cell_holder_generic_vec_element.rig |
| 190 | a write call whose value is used is parenthesized | behavior/emit/assign_value_first_pop.rig |
| 167 | `!T` as a field's type | behavior/emit/assign_value_first.rig |
| 175 | a Cell changed with `!`, or through a read view | behavior/emit/cell_holder_generic_handle_id.rig |
| 122 | `:outer` labels (before the labels pass) | behavior/emit/labeled_loop_continue.rig |
| 94 | `-x` as a drop | behavior/emit/drop_value_payload.rig |
| 101 | a `pub` generic's bounds (`Copy`, `Ord`, `Num`, ...) | behavior/modules/alias_across_modules/lib.rig |
| 61 | `replace(!p, v)` (40); `catch` handler precedence (12) | behavior/types/replace_and_swap.rig |
| 54 | `const` (before the fixedbind pass) | behavior/emit/match_range_pattern.rig |
| 38 | a closure's `)` on its body's last line | behavior/modules/closure_args_across_modules/main.rig |
| 27 | `w.upgrade()` | behavior/runtime/weak_owned_closure.rig |
| 26 | a method's view of self bound without `?` | behavior/emit/clone_viewed_handle_result.rig |
| 24 | a variant named `none` | behavior/emit/generic_enum_drop_glue.rig |

## Forms that were never in a release

`v0.2.9` had no tasks, APIs, `std.json`, `std.hash`, byte literals, or
iterators: `Moves`/`Shares`, `use std.hash`, `Symbols`, `rarely fun`,
`b'A'`, `within:`, `wait_all`, `task.both`, `for x in it` of a place,
and #647's public generic through an API are rejected forms of
programs written against `main` between the releases, not of 0.2.9's.
The guide's last section and CHANGELOG's closing paragraph cover them.
`tools/rename-task-bounds.py` rewrites the task bounds.

`std.json`'s `JsonError` needs no script: `load`, failing with it, was
added beside `parse`, which still answers a `Bool` (errors-r4/design.md
§5), and no public name of std.json was renamed. A 0.2.9 program has no
std.json.

## Open for the owner

The scripts for self, labels, built-in calls, and `const` were removed
in 8969d452b, which kept `tools/migrate-0.3.py` as the release's
upgrade. A 0.2.9 program needs all four (1,475 of the 4,836 programs
use `self`), and the guide gives them as hand rewrites. Folding the
four removed scripts into `migrate-0.3.py` as passes would make Step 2
mechanical.

## The four passes in `tools/migrate-0.3.py`

The removed scripts came back as passes of `tools/migrate-0.3.py`,
written for today's spellings: `builtin` (`@size(T)` to `$size(T)`,
also `@ size(T)`), `label` (`:outer for` to `$outer: for`, and a jump
to a label the program declares), `self` (a method's `?self`, `!self`,
`<self`, or `self: P` naming its own type, and `self` in its body;
a `self` elsewhere stays, which the old receiver script got wrong),
and `const` (`x =! e`; `X = e` at the module's level, where
fixedbind wrote a rejected `X =! e`). Each reads code only and
rewrites only what 0.3 rejects, so a second run changes nothing.

Measured with `main` at af68624f5 on the 4,836 programs, in
`v0.2.9`'s spelling (copies of the tag's files): 1,094 accepted as
written. After `migrate-0.3.py apply --force` on every file,
`tools/state-bounds.py` (one run per module directory, so two runs do
not race on a shared file), and the four scripts for programs written
between the releases (which change nothing here): 3,495 accepted,
1,341 rejected, and none that was accepted before. No rejection left
is a self, label, built-in call, or `const` form. The migration prints
`MANUAL` for 34 sites: 16 `!String`, 9 a bare or handle self (none in
an accepted program), 7 a `Box` it cannot rewrite, and 2 `const` as a
member's name.

The 1,341, by the form of their first error (CHANGELOG's numbers):

| Form | Files |
|---|---|
| 26 a value holding a Cell lives behind `*` | 361 |
| 24 a write call whose value is used is parenthesized | 191 |
| 27 a Cell changed with `!`, or through a read view | 180 |
| 28 `!T` as a field's or element's type | 167 |
| 10 `-x` as a drop | 99 |
| 9 `replace` | 58 |
| 23 a closure's `)` on its body's last line | 39 |
| 29 one heap holding | 29 |
| 11 `w.upgrade()` | 27 |
| 32 a method's view of self bound without `?` | 26 |
| 17 a variant named `none` | 24 |
| 25 a lend of a path's base | 21 |
| 31 `!x` where the callee reads | 18 |
| 19 an operator's spacing | 17 |
| 33 `keeps` | 14 |
| 20 a bracket, `.`, or `?` that does not touch | 12 |
| 30 a byte order on a one-byte read | 11 |
| 22 a `catch` handler that chooses | 9 |
| 42 a view of text lent to write, `!String` | 9 |
| 16 a type named as a built-in | 6 |
| 15 `panic` as a name | 5 |
| 21 `not a == b` | 4 |
| 36 `time.sleep` unhandled | 3 |
| 40 a method parameter named as a module declaration | 3 |
| 12, 13, 14, 34, 37 | 1 each |
| 18 a `pub` generic's bounds: a chain 1,100 calls deep, past `state-bounds.py`'s rounds | 1 |
| not among the 42: a write view kept by a loop's `break` value (behavior/ownership/write_view_result_binding_holds_view.rig), a view re-pointed at a `match` payload that ends first (corpus/review-assign-desugar-n33_repoint_at_outer_payload.rig) | 2 |

## The form that changes meaning: a loop's write view

A binding with no type of a loop's value that is a write view at every
`break` holds the view on `main` (384290706) and copied it in `v0.2.9`,
so a program can compile under both and write where it read.
`tools/migrate-0.3.py` reports it (`MANUAL`, the pass `loopview`) from
the text: a `break` or `else` value counts as a write view where it is
a lend of a path or a call of a function declared returning `!T` by the
file, the files of its directory module, or a module it uses.

On the 4,836 programs, each read alone, it reports 2 sites in 2
programs: behavior/emit/view_result_values.rig:135 and
behavior/ownership/write_view_result_binding_holds_view.rig:33, both
`l = while true` then `break F(!x)` with `F` returning `!Int`, both
read by hand and right. No site is missed: no other `break` in the
4,836 lends a path or calls a function its file declares returning
`!T`. Read as one directory, as the copies sit, a third program was
reported through a function of another program of that directory;
the pass therefore reads the files beside a program only when no file
there declares `main` (SPEC §14, directory modules), and then it
reports the 2. The compiler could not confirm them: `rig check
--facts=sema` records a binding's type (`types leaf ... "l" !Int`), but
only for a program it accepts, and `main` rejects both programs for
other forms; of the 675 accepted programs with a loop, none binds a
loop's write view.
