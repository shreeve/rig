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
