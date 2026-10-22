# Review: cell-mut (head 4c521b6a, against main 0cd9f3e3)

Reviewer: independent adversarial review. Nothing committed or pushed.
Probes: `.git/revamp/r3/probes/review-cell-mut/` (runner `run.sh`: check,
`RIG_SANITIZE=1 rig run`, `rig build --release` + run, each against the
file's `# expect:` block, then `rig-oracle -v`; `pup-run.sh` is the same
without the oracle, for pup; `main-release.sh` builds a probe with main's
compiler in `--release`). Main's compiler was built from `git archive
0cd9f3e3` in the session scratchpad.

## Verdict

**No write through const memory or a const pointer remains** that I could
find, in debug or `--release`, on the Mac (aarch64, LLVM) or on pup
(x86_64). The structural argument holds: emit.zig contains no
`@constCast`, `@ptrCast`, `@alignCast`, `@ptrFromInt` or `@intFromPtr`;
the runtime's single `@constCast` erases a function pointer that is only
called; every runtime `@ptrCast` starts from a mutable `*anyopaque`; and
std's Zig files have no casts and take no Cell-holding views. So a missed
site is now a Zig compile error, never undefined behaviour. Every
accepted probe that compiles prints the right output, sanitizer-clean, in
debug and release, and the oracle reports 0 differences on all of them.

**But "accept means correct" does not hold.** The fact the PR adds is
decided twice, by sema (`interiorMutable`) and by the runtime
(`holdsCell`, behind `ReadPtr`, `ReadSlice`, `ReadView`, `constSlot` and
`rig.slice`), and the two disagree. Ordinary programs that main compiles
and runs correctly now fail with a Zig compile error (H1, a regression).
Separately, sema's new and old Cell-receiver checks ignore `.depends`, so
generic code still accepts forms the concrete checks reject, which now
fail in Zig (M1; on main they compiled to a write through a const
temporary, which is UB).

No wrong-output program and no memory-safety hole remain among the
probes. What remains are accepted programs that do not compile.

## High

### H1. Regression: a generic instance whose type argument holds a Cell, but only behind a pointer, gets `*G(C)` from sema and `*const G(C)` from the runtime, so accepted programs fail to compile

Probes (all accepted by `rig check`, and all fail with Zig's "expected
type '*T', found '*const T'" / "'[]T', found '[]const T'" / FnRef
mismatch in debug and release, Mac and pup; all run correctly on main):

| Probe | Form | User generics? |
|---|---|---|
| `x03_overapprox_constslot.rig` | `fun first(v: ?Vec[G[C]]) -> Int` calls `look(?v[0])`: `constSlot` gives `ReadPtr(G(C))` = `*const` | no |
| `x05_overapprox_slice.rig` | `tot(?arr[0..2])` with `fun tot(xs: []G[C])`: `rig.slice` gives `ReadSlice` = `[]const` | no |
| `x02_generic_overapprox_sort.rig` | `sort.sort_by(!v, less)` with `fun less(a: ?G[C], b: ?G[C])`: `FnRef(&.{*G(C),...})` vs std's `FnRef(&.{*const G(C),...})` | std only |
| `x01_generic_overapprox.rig` | `look(id(?g))`, `fun id[T](x: ?T) -> ?T`: `ReadView(G(C))` is `*const` | yes |
| `x04_overapprox_stored_view.rig` | `look(r.r)`, `struct R[T] { r: ?T }` | yes (struct) |
| `x06_overapprox_substitution.rig` | `look(pick(?a, ?b, false))`, `fun pick[T](a: ?G[T], ...) -> ?G[T]` emits `*const G(T)` | yes |

Here `G` is `struct G[T] { h: *T }` (x01, x04, x05, x06) or
`struct G[T] { items: Vec[T] }` (x02, x03), and `C` is `struct C { c:
Cell[Int] }`. A generic container that keeps its elements in a `Vec`, a
`Box`, or behind a handle, instantiated at a type with a Cell, is common:
a tree, a graph, a list of observers.

```
cd .git/revamp/r3/probes/review-cell-mut
./run.sh x0*.rig                      # all: DEBUG rc=125, RELEASE BUILD FAIL
M=<main build> ./main-release.sh x0*.rig   # main: all print the expected output
```

Observed (x03): `error: expected type '*T', found '*const T'` at
`return look(&v.*.constSlot(0).*);`, `T = G(C)`, `pub fn look(g: *G(C))`.
Expected: `21` / `22`, as main prints.

**Root cause.** `sema.reachOf` gives a generic instance the full reach of
every type argument, whether or not the generic holds that parameter by
value:

```zig
// sema.zig, reachOf, .parameterized_nominal
for (pn.args) |a| r = r.with(try reachOf(ctx, a, m, into));
```

So `interiorMutable(G[C])` is `.yes`. But:

- in G's own generic code, `interiorMutable(G[T])` is `.no` (`holdsIn`
  does use `Contents.held`, so `holds_type_var` is false), so the fact is
  not stable under substitution (x06);
- the runtime's mirror, `holdsCell(G(C))`, walks the Zig fields, finds
  only a pointer or a slice, and says no, so `ReadPtr`, `ReadSlice`,
  `ReadView`, `constSlot`, and `rig.slice` give `*const`/`[]const`
  (x01–x05).

The PR describes `holdsCell` as "the mirror of `sema.interiorMutable`",
and emit now leans on it for concrete types too (`constSlot` at
emit.zig:4139, `rig.slice`). That makes two classifiers for one fact,
against "One classifier per fact". Before this PR the over-approximation
only made sema more conservative (`holdsCellByValue` is used for
rejections). Now it chooses a Zig type, and any disagreement is a compile
error.

**Fix direction.** Decide `interiorMutable` from what a value holds by
value, counting a type argument only where `Contents.held[i]` is set, the
rule `holdsIn` already uses for glue. Then sema, the generic body, and
`holdsCell` all agree. Leave `Reach.cell`'s over-approximation for the
rejection rules if they need it, or audit those too: they reject valid
programs in this class, e.g. a "temporary that holds a Cell" for a `G[C]`
that holds C only behind a `*`. Alternatively, make one side the only
classifier, e.g. emit every concrete read view as `rig.ReadPtr(T)`. Add a
`cellmut.` type such as `struct G[T] { h: *T }` at a Cell holder, plus
accesses that cross the generic or runtime boundary: a generic function
returning `?T`, a std.sort comparator, `?v[i]` through a `?Vec`, and a
subslice. The current family's "generic" type is `G[Int]` holding
`Cell[T]`, where all three classifiers agree, which is why the grid is
green.

## Medium

### M1. In generic code, `?self` calls on a temporary, a part of one, or a part of a branch with an unslotted made leaf are accepted at an instance holding a Cell, and fail in Zig

| Probe | Form (inside `sub f[X](x: X, f: ?sub(?X))`) | Concrete equivalent |
|---|---|---|
| `r04a_generic_temp.rig` | `mkh(<x).run(f)` | rejected: "cannot call `run` on a temporary that holds a Cell" |
| `r04b_generic_temp.rig` | `mkp(<x).h.run(f)` | accepted via a cell-temp copy |
| `r02_branch_generic.rig` | `(p if k else mkp(<x)).h.run(f)` | rejected by the new `constLeaf` rule |

(`H[X]` holds `x: X` and has `sub run(?self, f: ?sub(?X))`; instantiated
at `T { c: Cell[Int] }` with `bump(t: ?T)` changing the Cell.) Mac and
pup: debug `ZIGERR`, release `BUILDFAIL`; for example, r02 fails with
`(if (k) &p else &@as(P(X), mkp(X, ...))).h.run(f)`: "expected type '*T',
found '*const T'", `T = H(T)`. On main all three compile and print the
expected text, but only because `@constCast` writes into a Zig const
temporary, which is UB. So this is not a regression in acceptance: the
branch turned silent UB into a compile error. It still breaks Rule 2,
and the PR's claim that "Sema now rejects them instead" covers only
concrete types.

**Root cause.** typecheck.zig:7098 gates all three checks (the existing
temporary and cell-temp rules and the new `constLeaf` rule) on
`sema.holdsCellByValue(obj_ty)`, which is `.yes` only. For `H[X]` it is
`.depends`. **Fix direction:** treat `.depends` as `.yes` for these
checks. A generic body that does this would then be rejected, or better,
recorded as an instance constraint, like the existing "`each[C]` cannot
use `T = C`: the generic body copies…". Or give the receiver a mutable
slot (`recordCellTemp`) whenever `interiorMutable != .no`, which accepts
the program and makes it correct. `r04c_generic_temp.rig` (a read lend
`?mkh(<x)` in generic code) and `r05_generic_temp_lend.rig` (`?mkh(<x).x`)
compile and run correctly, so the lend path already handles `.depends`.

## Low

### L1. The new rejection also rejects read-only `?self` methods, inconsistently with the non-branch form

`r07_readonly_method_rejected.rig`: `print((w if i == 0 else
mk(5)).t.score())`, where `score(?self)` only reads. It is now rejected
with "…holding a Cell the method may change". Main accepted it and it is
safe. `mk(5).t.score()` without the branch is still accepted, because it
gets a cell-temp copy (`recordCellTemp`). The rule is minimal for what
emit can do today: `emitLeafPtr` reaches an unslotted made leaf only as
an rvalue, and every `?self` method of an interior-mutable type now takes
`*T`. The principled fix, which the PR names as the cell-temp redesign,
is to give the made leaf the same mutable slot the non-branch form gets.
Then both forms are accepted and correct, and `constLeaf` goes away.

`constLeaf` itself matches `emitLeafPtr` leaf for leaf on the forms I
tried. It descends `if`/`??`/`!`/`?`/`catch` only when `handsOver` is
`.branches`. It rejects a made leaf unless `dropsTemp`, and a
non-place payload holder unless slotted. It treats `part_of_made` by its
base. The forms that stay accepted run correctly in release:
`r03_branch_safe_forms.rig` (slotted leaves with drop glue, all-name
leaves, `o ?? d` over names). b08 and a01 are rejected as the PR says.
The one miss is the `.depends` case in M1.

### L2. The `cellmut.` matrix family passes a program that is rejected

`run_one` returns `("rejected", …)` for any program `rig check` rejects
with a position, and only `fail` fails the run. A cellmut program applies
all of its operations, so a future change that makes one of them rejected
would silently drop that type × access cell (every operation and both
builds) from the release grid. Today all 82 are accepted: I generated
them with `matrix.cellmut_program` and ran `rig check` on each. Suggest
requiring `ok` for `cellmut.` cells, as an expected-accept set.

### L3. Comments claim an exact mirror

runtime.zig's `ReadPtr` ("The mirror of sema's `interiorMutable`") and
`holdsCell` ("the mirror of sema's `holdsCellByValue`"), and the
INTERNALS "Interior mutability" paragraph, claim the runtime and sema
agree. They do not (H1). They also differ on `T!`: sema's `reachOf` looks
through `.fallible`, and `holdsCell` has no `.error_union` arm. I found
no form that exposes the `T!` difference, since a fallible type appears
only as a return type.

## Checked and sound

**Places probed, all right in debug (sanitized) and `--release` on the
Mac and pup, oracle silent:**

- `m01_match_payload.rig`: `match e`, `match ?e`, and `match !e` payloads
  in a loop with `?? continue`; a guarded arm; `match <e`.
- `m02_if_as_forms.rig`: `if o as`, `if ?o as`, `if !o as`, `if <o as`;
  `if mko() as`; `while !v.pop() as`; `if arr[0] as`; `if ?arr[0] as`.
- `m03_by_value_param.rig`: by-value parameters, a returned value, and
  `|<c|` stack and owned closures, each changing their Cell.
- `m04_match_catchall.rig`: catch-all bindings in read, write, and
  consume modes; consuming alternatives.
- `g01_generic_std.rig`: `sort.sort_by` with a comparator that changes
  Cells; `slices.reverse`; a generic holder's callback; generic `[]T`,
  `?T`, and returned `?T`; `Box[C]` lent generically; `Hold[Box[C]]`.
- `f01_misc_forms.rig`: `for x in <arr`, a `Box` field, an optional field
  via `if as`, `~T` upgrade, `?*C`, `raw`, an enum's own `?self` method
  matching on `self`, nested arrays and their subslices, a rebound `?C`
  local, and `!C`.
- `f02_cell_of_holder.rig`: `Cell[Vec[C]]` pop, `Cell[C]` replace, and
  `|?x|` and `|!x|` captures.
- `f03_header_temps.rig`: `match mke()`, `match <mke()`, and
  `for x in mka()` over values made in the header.
- `mod01/main.rig`: Cell holders declared in another module, held by this
  module's types, and that module's generic instantiated here, including
  `for x in ?gs`.
- `v01_var_never_mutated.rig`: new `var`s that are only read, and generic
  locals at plain instances. No "never mutated" Zig errors.

Before the fix, m01, m02, and m03 print wrong values when built with
`--release` on main (for example, m02 prints `0 0` for `9 9`; m03 prints
`10` for `32`). The branch fixes these programs too.

**Rejected as they should be:** module-level constants holding a Cell
(c01: "needs a value known at compile time"); `|+x|` of a Cell holder
("has no clone"); `?(w if k else mk()).t` (r01: lending a branch copies);
in-place `cv[0]` of `Cell[Vec[C]]`; and `Cell.get` of a unique `T`.
`extern zig` outside std is rejected, and no std Zig-backed function takes
a view of a Cell holder, so passing a `*T` where std Zig declares
`*const T` cannot arise.

**Old probes** (review-cell-temp-2, run with `run.sh`; I changed their
`sub main` to `sub main()` in place for the new parameter-list rule): z01, z03, z04,
z06, and z07 run correctly in debug and release. z02, z05, z08, and b08
are rejected. b04 (an internal error) and l01 (a leak) are unchanged
from main, as the PR says.

**One classifier, by grep.**

- emit's remaining `*const`s are the `.no` arm of `emitViewPtrTy`, and
  `*const fn` for function pointers.
- `[]const` appears only in the `.slice` arm's `.no` case.
- `constSlot` is chosen at emit.zig:4139 and returns the runtime's
  `ReadPtr`.
- storage.zig hard-codes no pointer mutability.
- The bindings and `needs_ptr_self` use `interiorMutable`.
- Hidden `const` storage (`__rig_new_N`, `__rig_ix_*`, match `whole`) is
  only copied out or read, so a missed write there would be a Zig compile
  error, not UB.

The real second classifier is the runtime's `holdsCell` (H1).

**Harness.**

- `# release` works. I copied the branch's `test/run` into a scratch
  root, used main's `bin/rig` and a `ZIG` shim that skips `zig build`,
  and ran `behavior/emit/cell_view_counter_loop`. It fails with
  "--release: … Bus error … in set", logged under `=== --release`, while
  `cell_view_forms` passes. The release run uses `smp_allocator`, not the
  sanitizer (`leak_checked` is debug-only), so allocator-dependent damage
  (z04's double free) shows.
- `cellmut.` compares release stdout with `cellmut_output`: `run_built`
  with `["--release"]` and the same `expect`. With main's compiler,
  `cellmut.plain.param` and `cellmut.drop.method` print wrong output in
  release (`diff` against the model); on the branch both match, on the
  Mac and on pup.

## Commands

```
B=/Users/shreeve/Data/Code/rig-cell-mut/bin
cd .git/revamp/r3/probes/review-cell-mut
./run.sh *.rig mod01/main.rig                 # Mac: check, debug sanitized, release, oracle
(cd ../review-cell-temp-2 && ../review-cell-mut/run.sh *.rig)
./main-release.sh m0*.rig x0*.rig             # main's compiler, --release
pup.sh cell-mut "...; bash pup-run.sh <dir>"  # probes shipped base64; results in the table below
```

pup results (x86_64, branch 4c521b6a; x06 and r07 were written after this run, Mac only; the two cellmut programs are
matrix cells with the model's trace appended as `# expect:`):

    cellmut__drop__method.rig: debug=ok release=ok
    cellmut__plain__param.rig: debug=ok release=ok
    f01_misc_forms.rig: debug=ok release=ok
    f02_cell_of_holder.rig: debug=ok release=ok
    f03_header_temps.rig: debug=ok release=ok
    g01_generic_std.rig: debug=ok release=ok
    m01_match_payload.rig: debug=ok release=ok
    m02_if_as_forms.rig: debug=ok release=ok
    m03_by_value_param.rig: debug=ok release=ok
    m04_match_catchall.rig: debug=ok release=ok
    r01_branch_part_forms.rig: REJECT
    r02_branch_generic.rig: debug=ZIGERR release=BUILDFAIL
    r03_branch_safe_forms.rig: debug=ok release=ok
    r04_generic_temp_receiver.rig: debug=ZIGERR release=BUILDFAIL
    r04a_generic_temp.rig: debug=ZIGERR release=BUILDFAIL
    r04b_generic_temp.rig: debug=ZIGERR release=BUILDFAIL
    r04c_generic_temp.rig: debug=ok release=ok
    r05_generic_temp_lend.rig: debug=ok release=ok
    v01_var_never_mutated.rig: debug=ok release=ok
    x01_generic_overapprox.rig: debug=ZIGERR release=BUILDFAIL
    x02_generic_overapprox_sort.rig: debug=ZIGERR release=BUILDFAIL
    x03_overapprox_constslot.rig: debug=ZIGERR release=BUILDFAIL
    x04_overapprox_stored_view.rig: debug=ZIGERR release=BUILDFAIL
    x05_overapprox_slice.rig: debug=ZIGERR release=BUILDFAIL
    z01_release_named_local_bus.rig: debug=ok release=ok
    z02_release_read_view_param.rig: REJECT
    z03_release_stale_header_free.rig: debug=ok release=ok
    z04_release_double_free_alias.rig: debug=ok release=ok
    z05_release_lent_temp_loop.rig: REJECT
    z06_release_part_continue.rig: debug=ok release=ok
    z07_release_counter_bus.rig: debug=ok release=ok
    z08_release_slot_drop_stale.rig: REJECT
    mod01/main.rig: debug=ok release=ok
