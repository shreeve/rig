# One "copies" fact (ownership lane B)

Branch `copies` at e240073f, on main 0a10f99c (seam 2 #58 and the while-step hotfix #59 merged in).

## What changes

`sema.copies` (formerly `copyable`: does not move, holds no write view) is now the only test for "this value is duplicated by a bit copy with no owner involved". It covers numbers, Bool, String, function values, plain enums, structs, arrays, and optionals of values that copy, and read views. Every site that kept its own list now asks it:

| Site | Before | Now |
|---|---|---|
| Copy out of a view where the value is expected (`p: P = r`, `f(r)`, a result, a branch) | `readsAsValue` (primitive or plain enum) | `sema.copiedThrough` (a view of a value that copies) |
| Bare write view read as its value (`x = w`, `x = h.w`, `x = ws[i]`), typecheck and ownership (`readsThroughWriteView`) | `readsAsValue` | `copiedThrough` |
| `[n of x]`, `fill`, `copy` | `moves` + `holdsMarkedView` ("plain data") | `copies`; read-view elements are accepted, and each copy keeps its loan |
| `\|+x\|` | `isPlainData`, or a handle | `cloneCapture`: what `+x` gives, read through a view (copy, count bump, deep clone) |
| `Cell.get`, `Vec.get`, sequence `get`, and `??`/`?`/`as` through a view | `moves` (`cannotCopy`) | `copies` |
| Generic requirement | `no_move` (`moves != yes`) | `Requirement.copies` (`copies != no`) |
| Cell/Signal element; owned closure params and results | `isCopyElement`, `isClosureValue` (two lists) | `isPlainData`, the plain kind (Core §1), for all three |

Ownership: `copy`'s stored value carries what its source's elements carry, not a loan on the source. A `|+x|` through a view carries what the copied value holds, not the view's loan on its holder.

Emit: `|+x|` follows `cloneable`, as `+x` does (count bump, `cloneOptional`, `cloneValue`).

## Fixed in passing (a soundness hole live in v0.2.2)

`x = r ?? W(...)` and `x = r?`, with `r: ?W?` and `W` holding a write view, copied the write view out of a read view, then wrote through it (corpus copies-hole-*). The fact rejects both, since a value holding a write view does not copy. These are the only accepted→rejected programs.

## Boundary kept (owner question)

An operator, generic inference, and a binding with no type still read a *read* view of a scalar as the scalar (`readsAsValue`), but keep `x = r` with `r: ?Point` as a `?Point`. Copying it out there would change the binding's type in accepted programs and reject some (storing `x` in a `?P` field without `?`, returning it as a view). Where a type is expected, every value that copies is copied out. Recorded in HANDOFF.

## Planned rules now built (CORE)

- §4: a plain struct, array, or optional is copied out of a view (example promoted).
- §5: `fill`, `copy`, and `[n of x]` take read-view elements (`[3 of ?n]` promoted).
- §7: `|+x|` deep-copies an owner (`|+v|` of a Vec promoted). This followed from `+x`'s existing `cloneable`, plus the closure environment's existing drop.
- Sentence 1: a write view of any value that copies reads its value (`x = h.w` with `w: !Point`).
- §9: the fact is named `copies`.

## Core conformance

- **One paragraph, no exception list:** "a value copies when it owns nothing, is not unique, and holds no write view". Every duplication asks this.
- **Rules follow the type:** each site asks the fact of the value's type.
- **Desugaring:** INTERNALS "Copies": the copy-out is a read-through (`recordRead`), as for `?Int`; `[n of e]` is `n` copies of one value; `fill`/`copy` are element stores; `|+x|` is `c = +x`, then `|<c|`.
- **One classifier per fact:** `copies`/`copiedThrough` for copying, `isPlainData` for the plain kind, `moves` for taking. One mix-up surfaced in the pup corpus: a match's made subject is taken only when it moves (bc176613, guarded by `copies_match_made_write_view`).
- **Sanitizer-clean:** all new tests and 70 corpus probes, under RIG_SANITIZE.

## Fixes from the independent review (review-copies.md)

Each fix has a test that fails without it.

- **H1 (new on the branch):** `c: P = o ?? ?b` with `o: (?P)?` was accepted and the Zig failed. The `??`/`catch` arm checked `compatible` but never recorded the adaptation. It now calls `recordAdapted`, as every `compatible` site that admits a value now does:
  - `checkExpr`;
  - closure returns;
  - `??` and `catch`.

  The owned-closure site and the builtin-cast site cannot meet a view. Test: `copies_coalesce_catch_views`.
- **M1 (new):** `checkStepUses` asked `copies` where the question is whether the body owns the binding. It now asks `mustTake` (`moves`), as `match` does since bc176613. Test: `copies_loop_step_write_view_holder`. With the while-step hotfix merged, p47 is rejected for the right reason (`cannot reassign 'n' while it is lent`) and is in the corpus.
- **M2 (in v0.2.2):** a function returning `(?P)!`, `(!P)!`, or `(?P)?!` emitted `r.*`. Emit's return of a view held as a pointer now looks through a fallible result, and an error value stays itself. This also unblocks `catch` of a fallible view. Test: `copies_coalesce_catch_views`.
- **L1:** `sema.cloneable` answered `.copy` for a value holding a write view. It now answers `.no` (Core sentence 2), so typecheck rejects `+h` and `|+h|` again, with a write-view reason. Test: `copies_clone_write_view_holder`.
- **L3 (in v0.2.2):** `Q(p: w, o: w)` is a second write lend. Classified prod-strict in `test/oracle/differences`; the rule is unchanged.
- **Probes:** the review's probes are in `test/corpus/review-copies-*`, except the p49/p50 family and p47, which the hotfix keeps.
- **Boundary:** the p45 probes record today's behavior. The design note is `.git/revamp/r3/copies-boundary.md`.

## Fixes from the second review (review-copies-2.md)

- **H2:** a `??` or `catch` whose value is a view, where an optional of the value is expected (`f: P? = i ?? ?b`, `catch` into `P?`, `P?` arguments and fields), was accepted and the Zig did not compile. `fallbackType` widened to the expected optional through `compatible`, which admits copy-out, so the left side was never read through. It now widens only as itself (`meets`) or for a view held by value, which is its value. A view held by address stays the view, and the whole `??`/`catch` is copied out by the outer `recordAdapted`. This also fixes main's `(!Int)?` case (q09h). Tests:
  - `copies_fallback_into_optional`;
  - `copies_fallback_none_view`: `?? none` with a view held by address is rejected, since `none` cannot be its fallback.
- **Reviewer's grid** (224 programs, through heavy.sh): 219 run with the expected output, and 5 are rejected (`Cell` of a `?Vec` holder). None fail in Zig, and the oracle is silent.
- **L4/L5:** q05g, q06a, q06f (a `catch` copies out after its handler) and q07l are classified prod-strict in `test/oracle/differences`. One line is added to `copies-boundary.md`.
- **Probes:** in `test/corpus/review-copies-2-*`: all 96 hand-written probes, 64 grid programs (the optional contexts and a sample), and q10a, q10d and the first review's p47. With the hotfix merged, the last three are rejected.

## Accepted → rejected (against main 0a10f99c)

- `copies-hole-coalesce-write-view-holder`, `copies-hole-propagate-write-view-holder`: the v0.2.2 soundness hole. A value holding a write view was copied out of a read view by `??` and `?`, then written through.
- `review-copies-p60` (L2): `print((r ?? W(w: !b)).w.len)` with `r: ?W?`. The fallback gives up a value holding a write view, which does not copy. It is rejected now, as `(r ?? Vec()).len` already was for an owner.
- `review-copies-2-q09h`: `f: Int? = <i ?? none` with `i: (!Int)?`. Main accepted it and its Zig did not compile; it is now rejected, as in H2.

## Proof

- **Equivalence against main 0a10f99c** (pup, lease-gated, 9049 programs, 341 differ):
  - accepted→rejected: only the four programs above;
  - accepted by both, with differing sema facts or emitted Zig:
    - 25 programs that return a fallible view (M2's class). Main fails to compile 24 of them. The other, q07f, emitted `return r.*` in a function Zig never analyzed;
    - 17 programs whose sema facts changed (the grid's E rows and p51b): a `??`/`catch` of a view held by value now records its copy-out, and emit is unchanged;
    - p24's facts;
  - everything else is diagnostic text or a newly accepted program.
- **Newly accepted (133):**
  - the new tests and probes (122);
  - CORE L711, L824, L945, the promoted examples;
  - owned_closure_plain_data;
  - R15-p-v3, r3-s36-docs-p08, r3-s36-loans-o01, r3-s36-reads-v01, review-lang4-b1, sc5-t, syntax-review-designer-p11.
- **pup gates at e240073f:** suite 2737/0, corpus 6731/0, matrix 4899 programs with 0 failed, unit ok, odv 329/0.
- **Mac via heavy.sh with `-j "$CPUQ_CORES"`:** suite 2737/0, oracle + doc + vocab + every copies probe 648/0, unit ok.

## Merge notes

- Main (seam 2) merged cleanly except for `test/oracle/coverage`. I took main's floors and kept this branch's matrix floor of 23361.
- `checkStepUses` (typecheck) changes one line, now merged with the while-step hotfix.
- `test/oracle/differences` conflicted with the hotfix's entries; both sets are kept.
- No `src/rig.zig`, grammar, or parser change, so the Nexus mirror is unaffected.
