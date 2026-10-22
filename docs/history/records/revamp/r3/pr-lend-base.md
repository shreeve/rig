## Summary
A lend of a place is never the base of a path. Each of these is rejected wherever it stands:
- `(!p).x`, `(?arr)[0]`, `(!v)[0..2]`, `(!mk()).r`;
- the lend moved, `(<(!p)).x`;
- a field holding a function, called: `(?t).f(1)`, `(!t).ops[1](5)`.

The contexts include an assignment, `op=`, a header, a receiver's path, an argument, a closure's or a function's last value, and a call of a function field. Each form has a plainer one, because the lend goes on the whole path, or the assignment already shows the write. Several of these forms used to be accepted with Zig that did not compile (`&arr[0] = 7`, `&t.f(3)`).

| Written | Write instead |
|---|---|
| `(!arr)[i] += 7`, `(!p).x = 5`, `(<(!p)).x = 5` | `arr[i] += 7`, `p.x = 5` |
| `if !(!arr)[0] as v`, `match (!p).e`, `for x in (!p).items` | `if !arr[0] as v`, `match !p.e`, `for x in !p.items` |
| `(!p).items.push(3)`, `print((!p).s.insert(1))` | `!p.items.push(3)`, `print((!p.s).insert(1))` |
| `bump((!p).x)` with `bump(n: !Int)`, `w: !Int = (!p).x` | `bump(!p.x)`, `w: !Int = !p.x` |
| `x = (?p).items`, `W(r: (?p).items)`, a `?Vec` result `(?p).items` | `x = ?p.items`, `W(r: ?p.items)`, `?p.items` |
| `f = (!p).x`, `count((?p).items)`, `(?t).f(1)` | `f = p.x`, `count(p.items)`, `t.f(1)` |
| `own((?p).items)`, `b: Vec[Int] = (?p).items` (an owned value goes there) | `own(+p.items)`, `b: Vec[Int] = +p.items` |
| `ys = [(?p).items, (?p).items]`, `w: (?Vec[Int])? = (?p).items` | `ys = [?p.items, ?p.items]`, `w: (?Vec[Int])? = ?p.items` |
| `print((?t)[1..3])`, `sum((?p).arr)` with `sum(xs: []Int)`, `(?p).arr[0..2][1]` | `print(?t[1..3])`, `sum(?p.arr)`, `(?p.arr[0..2])[1]` |
| `(!mkh()).r = "lit"`, `match (!mk()).e` | bind it first: `tmp = mkh()`, then `tmp.r = "lit"` |
| `y = (!arr[..])[0]` (a written `!` only read) | `y = (?arr[..])[0]` |

**Not this rule's:**
- a method's receiver: `(!s).insert(k)`, `(!w).put[2](3)`, `(!t.pickw()).b = 20`;
- a value that branches, whose lends pick the place written: `(!a if c else !b)[0] = 5`;
- a lend of a slice, which makes the view the path indexes: `(?t[..])[0]`.

**The error is always reported.** A rewrite is the source line the path is on, never cut to the path. There is no rewrite where none compiles. Where it can, the message says why:
- "and a read lend is not written through" (`(?p).x = 5`, `y = <(?p).items`);
- "and nothing is written through a shared handle";
- "and `<` takes out only an optional field or element" (`y = <(!p).items`);
- "bind the temporary first, in a statement of its own" (a temporary changed inside a closure or a match arm).

There is also no rewrite for:
- a path that draws another error of its own, in its lend or after it (`(?p).nope`, `(?p).arr[5]`, `(?p).v.len()`);
- a statement spread over lines, or a module-level value;
- a branch's path walked by `for` or sliced;
- a value the context cannot take.

Every other diagnostic names a place by its plain path (`plainText`), so none suggests a form this rule rejects: "write `p.v.len`", "`p.o ?? fallback`", "lend it as a String with `?p.name`". A method a call does not find on a lend (`(!arr).sort()`) is the call's to report, not also a path.

## Design
- **One walk.** `Checker.checkLendBases` runs once over each typed declaration, after typing. It visits every field, element, and slice node exactly once, so no typing routine can route a path around the rule. No typing routine calls the decider.
- **One fact for the base.** `Checker.lendOf(obj)` says which lend a path's object is: what it hands over (`handsOver`), a `lend`, or a `<` of one. It is recorded once.
- **The non-cases are positive facts:**
  - a member that `synthMemberCall` resolved as a method (`Checker.methods`, with the receiver mode and the result type) is a receiver, so a called function field, never resolved as a method, is a path;
  - a branch is no lend, by `lendOf`;
  - a lend of a slice is a view. A written `!` on one that the path only reads goes to `writeLendRead`, the one decider for reads of a written lend.
- **Hints come from what the context takes.** `LendBaseFix` rewrites the path's source line, removing every lend that is a path's base. The whole path gets the sigil its context takes, from the facts typing recorded:
  - the type each expression was checked against (`Checker.expected`), optionals looked through:
    - a write view gives `!`;
    - a read view gives `?`, except as a `?T` argument, which lends it implicitly;
    - a slice or a String gives `?` for a path that is not one already;
    - a value gives no sigil if it copies, `+` if it does not, and no rewrite if it is not the value expected;
  - a slice of an array, a Vec, or a Text is a lend, `?` (`!` where a write view goes). A slice below the top is lent as a whole: `(?p.arr[0..2])[1]`;
  - a value taken where no type is expected (a binding, an element) keeps the lend's sigil when it does not copy;
  - a method's receiver mode, with `(!…)` where a `Bool` result is used, also as a value tail (`Checker.value_tails`);
  - a header's subject takes the lend's sigil;
  - a leaf of a branch takes its sibling leaves' sigil;
  - a part of a temporary that is assigned, taken, or bound by a header is bound to a name first, one the module's code nowhere uses.
- **The suite enforces the hints.** `test/hints.py` runs on every reject test whose check has such a diagnostic. It applies each hint alone, and fails if the program then draws any error it did not draw before, at the same place with the same text. The rewritten line's columns are mapped through the rewrite.
- **Emit parenthesizes a moved compound base** (`movesCompound`, `emitBaseExpr`): anything but a name, a field, an element, or a call. A gap in the decider can then fail only as a Rig rejection, never as Zig that does not compile. The sites are `emitMemberBase`, `emitIndexBase(.expr)`, and `emitSlice`'s Vec and Text bases.

## Removed
- **#89's path machinery:** `noteReachedLend`, `checkReachedLends`, `reached_lends`, `written_paths`, `ReachedLend`, the checker's `markWritten`, `SemContext.placeInOrder`, and the deferred pass. `ViewRead.path` stays, now serving the slice read only.
- **This PR's first designs:**
  - the decider calls in `memberOf`, `indexInto`, `synthSlice`, and `writeSlice`;
  - the error-suppression spans (`inLendBase`, `lend_bases`, `dropped_at`);
  - the quiet re-typing of paths (`typeLendBase`, `typing_lend_base`), `namesMethod`, and `lendsPlace`.

  An error a path draws as a place or a receiver is now reported, not hidden, so a reject test's `# errors:` counts it.

## Also fixed
- `x = <(!c if k else !d)[1]` and `(<(!p if c else !q)).x = 5` passed `rig check` on main but emitted Zig that did not compile. The fixes:
  - a `<` that takes an element no longer passes its delimited-position flag to the place it addresses;
  - a moved compound base is parenthesized.

## Commits
- 990aa499, 299d7f8e, 38ece273: the rule, the corpus probes written plain, and the docs.
- e73f7390, 8942347a: the two emit fixes.
- 9cff6f39, bb46d1a0: review 1's fixes and docs.
- afb90d3a Decide lend bases in one walk over the typed tree.
- 812aa936 Parenthesize any moved compound value used as a path's base.
- 5f637678 Check in the suite that every lend-base hint compiles.
- 8623ba83 Keep review 2's lend-base probes in the corpus.
- f395daef Describe the lend-base walk in INTERNALS.
- 6bb01556 Merge main d32cb723 (#92, syntax-a). It merged cleanly. `rewrite.py scan` finds nothing to rewrite in the merged tree, before and after review 3's probes, so there is no separate rewrite commit.
- 912be18e Give each lend-base hint the sigil its context takes, or none: review 3's M1, M2 and lows.
- 3d506a51 Excuse a hint's error only at the same place with the same text.
- 7e93d4c7 Keep review 3's lend-base probes in the corpus.
- 5bf6400e State in INTERNALS when a lend-base error gives no rewrite.
- 693e3dc3 Give no rewrite for a branch's path walked or sliced.

## Tests
- **Reject tests** in `reject/ownership/`:
  - `lend_path_base.rig`: every context;
  - `lend_path_base_temporary.rig`: temporaries, and parenthesized operands;
  - `lend_path_base_contexts.rig`: closure bodies, block and function values, moved lends, slice reads, read lends and shared handles;
  - `lend_path_base_function_field.rig`: `(!t).f(1)`, `(?t).f(1)`, `(<(?t)).f(3)`, `(<(!t)).f(1) + 1`, `if (<(!t)).g(1)`, elements, a handle, an owned-closure field, an index, `(!t).ops[1](5)`;
  - `lend_path_base_view_context.rig`: each hint in a context that takes a view: `!T` and `?T` arguments, typed bindings, an array of views, a constructor's field, results, `return`, and a branch;
  - `lend_path_base_hints.rig`: review 3's hint contexts. These are:
    - owned and generic arguments, a typed `Vec` binding, and array elements;
    - `<` of a field that is no optional, and an optional read view;
    - Text slices, and an array where `[]Int` goes;
    - a temporary in a closure and in a match arm;
    - a read lend written, and a missing method and `.len()` (each with its own error);
    - a `Cell[Vec]` through a read lend, and a `String` binding;
    - a long line, a path spread over lines, and `((!p)).x`.
- **Behavior tests** in `behavior/`:
  - `ownership/lend_path_plain_forms.rig` and `ownership/lend_path_function_field.rig` (`# release`): the plain and kept forms;
  - `emit/take_element_through_branch.rig` and `emit/moved_branch_path_base.rig` (`# release`): the emit fixes.
- **Corpus:**
  - review 2's 825 probes (`review-lend-base-2-*`);
  - review 3's 269, deduplicated and laid out to the style (`review-lend-base-3-*`, with the module probes as directories).

  Each is rejected, or runs sanitizer-clean.
  - One more probe, `gen/mheld__slice__stmt`, is left out: `(?(<w).a[..])[1]` with `w` a held `!S`. Main miscompiles it too. It is not this rule's (`<w` is no lend), and it is listed under Follow-ups.

## Survey
Every file whose meaning or verdict changed:
- **Rewritten to the plain form, with the same output:**
  - behavior: `move_leaves_source_done`, `read_view_branch_value_keeps_owner`, `take_through_lend`, `write_lend_as_header`;
  - corpus: `review-cell-temp-m01`, `-r01`, `review-move-done-p73`, `review-revamp-rest-mut-a_41-m`, `review-seam2-l03`, `-m02`, `-q02`, `-t01`.
- **Meaning changed:**
  - `write_lend_temporary_assign` uses `!mkh().set("lit")`; the `?mk(1).t` line is dropped, because a receiver is made before its argument;
  - `store_into_unnamed_receiver` drops `(!a).r = ?t`;
  - corpus `review-move-done-p74` reaches its core gap through `id(?s).n`, and its `test/oracle/differences` entry says so.
- **Reject tests whose other cases stay checked:** these had their lend-base lines moved to held views, calls, or bare paths:
  - `move_through_lend`, `move_through_lent_handle`, `move_part_that_copies`, `move_part_of_made_value`;
  - `store_into_unnamed_receiver`, `write_lend_temporary_stores`;
  - `header_place_inside_temporary`, `ifas_write_view_header_temp`, `vec_len_read_only`;
  - `ignored_write_lend_leaves`.
- **Deleted, folded into the new tests:** `ignored_write_lend_as`, `ignored_write_lend_path_once`, `ignored_write_lend_path_once_for`, and the source-order case in `test/cli/diagnostics.sh`.
- **Now rejected, kept as probes of exactly this form:**
  - 13 accepted on main: `review-place-b9-x026`; `review-seam2-r2-w01`, `w14`, `z05`, `z12`, `z14`; and the seven `review-seam2b-fixes-fuzz-p-*` temporary-assignment probes;
  - 23 already rejected on main for another reason.
- No example or std file changes.

## Verification
- **Grid** (`.git/revamp/r3/lend-base-tools/grid.py`), 240 cells.
  - The cells:
    - bases: an array, a Vec, a field, a nested path, and a `!` parameter;
    - operations: `=`, `+=`, a read, `as` via `!` and `<`, a write method, and `match !`;
    - each base three ways: the lend, the lend moved, and a lend of the moved lend;
    - each read in a statement, a closure, a block value, and a function's last value;
    - function fields and owned-closure fields called through five wrappers, in the same four contexts;
    - the kept forms (a slice, a branch, a moved branch), and temporaries.
  - Result: 164 rejected, each with a hint that, applied, runs in debug and `--release`, sanitizer-clean, printing what the plain form prints; 76 ran clean, with the oracle silent.
- **Review probes** (1118: review 2's and review 3's):
  - none is accepted that main d32cb723 rejects;
  - every hint passes the tightened `test/hints.py`.
- **Gates on 693e3dc3**, merged with main d32cb723 (`--delta`, through cpuq via heavy.sh):
  - suite 2987 passed, 0 failed, 3 pending;
  - corpus 8388 passed;
  - matrix 5877 programs, 3213 ran clean, 2664 rejected, 0 failed;
  - unit 135, 1 skipped.
- **Equivalence** (`test/equiv.py`, base main d32cb723): 10854 programs, 648 differ.
  - 92 differ in `emit` and `pkg`, every one a moved compound value used as a path's base:
    - the 2 emit fix tests;
    - 80 review probes whose Zig on main does not compile;
    - 10 review probes that run on main. They differ only in the parentheses around the base, and print the same.
  - 556 differ in `check`/`facts` only:
    - the 6 reject tests and SPEC's reject example;
    - 37 earlier corpus probes;
    - 512 of review 2's and review 3's probes.

  Every other program both compilers accept emits identical Zig.

## Follow-ups
- **Ownership diagnostics that may now be unreachable.** These are for a `<` through a lend of a place, which typecheck now rejects first. A lend of a slice may still reach them.
  - In `src/ownership.zig`, the move-through-view diagnostics: the `lent_handle` branch ("reached through the shared handle `h`"), and the "A lend of a place" branch.
- **A moved held write view as a slice's base** (`(?(<w).a[..])[1]`) emits `rig.keep(..., w.*)` into a `*S` slot, and Zig rejects it. Main does the same. It is not this rule's.
- **A branch of write lends that is only read** (`y = (!p if c else !q).x`) is accepted, as on main. The branch is no lend.

## Decisions to confirm
- **CORE.** The rule is stated in SPEC and SYNTAX, and CORE is unchanged. Proposed, for the owner, as one bullet in Core §8 ("Outside the core: syntax, not ownership"):

  > - **A lend of a place is never a path's base:** `(!p).x` is written `!p.x` where the path is lent and `p.x` where it is read or assigned; a method's receiver, a branch that picks a place, and a lend of a slice are no lend of a place. *(built)*

  A written `!` that is only read stays sentence 4's rule; this one is about where the sigil is written.
