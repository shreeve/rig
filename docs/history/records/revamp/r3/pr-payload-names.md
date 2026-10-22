## Summary
A pattern binds a variant's fields either in order, all of them, or by name, any of them; it doesn't mix the two (design owner's decision, rig-questions.md "Payload fields by name"). `.circle(radius: r)` was rejected as "not supported yet"; it now binds `radius` and leaves the other fields with the subject. Under `match <e`, a field the pattern leaves out is dropped at the end of the arm, as a `_` field is.

**Desugaring** (docs/INTERNALS.md): `.rect(h: b)` on `rect(w, h)` is `.rect(_, b)`. Every accepted cell of the grid emits byte-identical Zig for the by-name pattern and its positional desugaring.

## Commits
- **Bind a variant's payload fields by name in a pattern** (4dbc9cab).
  - New fact `payloadBindings(pattern)`: for each payload field of the variant, in field order, the binding leaf, `_`, or `.nil` for a field left out. Typecheck decides it once (`fieldBindings`, in `checkVariantPattern`), and records none for a rejected pattern.
  - Every pass that paired bindings with fields by position now reads the fact:
    - typecheck: binding types, `copied_from`, `owned_bindings`, `armsBind`, `patternBinds` (guard writes), `rejectWriteViewBindings`;
    - storage: the Planner's payload capture (`.payload` pointer/copy);
    - ownership: `bindPattern`;
    - emit: plain arms (captures, `consumedPayload`), `guardBindings`, `armBindings` (guarded read/write/consume), `payloadAliases`;
    - oracle: `bindPattern` (its "a payload bound by field name" abstention is gone).
  - Passes that only need the names a pattern binds (resolve, `checkAlternatives`, the facts coverage walker) use `sema.bindingName`.
  - Diagnostics: mixing (`` `.rect` binds its fields both in order and by name; ... ``), an unknown field (`no field `width` on variant `rect``, with a suggestion), a field bound twice (with a note at the first), and the arity message now suggests binding by name.
  - **Fixes a crash that predates this branch (on main):** a positional pattern of the wrong arity (`.rect(a)` on `rect(w, h)`) was rejected by typecheck, then `storage.plan` panicked ("for loop over objects with non-equal lengths"), so `rig check` crashed instead of printing the error. The planner now reads the fact, which a rejected pattern doesn't have. Sibling sites checked: emit and the ownership checker don't run on a program with type errors; the oracle runs only on checked programs. Test: `test/reject/types/variant_pattern_arity.rig`.
- **Document payload fields bound by name** (9f944a93): SPEC's match section (the sentence, a runnable example, a reject example), the reserved-forms table row removed, SYNTAX's pattern table and text, INTERNALS (the IR note, the facts table row with the desugaring), the grammar comment, HANDOFF's open question removed.
- **Merge origin/main** (#84, B4b) and **merge `fix-view-payload-match`** (f5b0d00d, locally, as the coordinator asked). Its `payload_fields` fact is recorded per binding leaf in the same loop over my mapping, so `payloadByAddress`, `guardBindings`, `payloadAliases` and the Planner read each binding's field through the mapping. The one conflict (storage Planner loop) resolves to iterating `payloadBindings` alone; the Planner no longer needs the field list. It has since landed on main as #85, which is merged in.
- **Test payload fields bound by name across modules** (8d832aaf).
- **Merge origin/main** (bf652b0e): #85, `8f7cf2c6`, the `payload_fields` fact, which f5b0d00d had brought in locally.
- **Read a field a by-name pattern leaves out as a `_` field is read** (76c3dc81): a read match puts the same generic requirement (`readBinding`) on a left-out field as on `_`, so a by-name pattern and its desugaring check alike.

## Grammar / Nexus
`rig.grammar` changed only in a comment (the `pbinds` comment no longer says "reserved for the checker to reject"). `zig build parser` regenerates an identical `src/parser.zig`. **Nexus mirror sync:** copy the comment to Nexus's mirror of `rig.grammar`; `src/rig.zig` and `src/diag.zig` are unchanged.

## Tests
- **Behavior:**
  - `types/payload_by_name.rig` (`# release`): named subsets, a single named field, all fields named out of order, read/write/consuming matches, guards (read and write), a generic enum (consuming and lent), and matches nested in an arm on a field bound by name (read and write).
  - `ownership/match_payload_by_name.rig` (`# release`): Text, Vec and `*B` fields bound by name in a consuming match, with the left-out owning fields dropped exactly once (drop prints, sanitizer); a guarded consuming match; read views of fields bound by name returned past the arm (plain and guarded); a write match on owning fields by name; a consuming match that moves a field out.
  - `modules/payload_by_name_across_modules`: an imported enum and an imported generic instance at a view type (`Pair[?Text, Int]`).
- **Reject:**
  - `types/payload_by_name.rig`: mixing (both orders), an unknown field, a field bound twice, by name on a variant with no payload, alternatives binding by name.
  - `types/variant_pattern_arity.rig`: too few and too many in order (the crash above).
  - `ownership/payload_by_name.rig`: moving out of a read match by name, a guard writing a field bound by name.
  - `ownership/payload_by_name_flow.rig`: use after a consuming by-name match, a returned view of a by-name field outliving a reassignment of the subject, and the subject reassigned in the arm while a by-name view lives.
  - Removed `syntax/match_field_name_pattern.rig` (it checked the old "not supported yet").
- **Variants with unnamed fields:** none exist. Every variant declares its fields by name (`params`), builtin optionals and results aren't variant patterns, and an error has no payload. So there is no reject test for that case.
- **Corpus:** `docs-probes-k1`, `syntax-review-symmetry-p_pattern_kw` and `review-sc3-k1` were rejected as "not supported yet". They now run and print the right values.

## Verification
- **Grid** (scratchpad `grid.py`): 600 cells. The dimensions are 9 variant shapes of 1–3 fields (Int, Text, `*B`, Vec, a Text-holding struct) × every ordered named subset (60) × 10 match kinds:
  - the kinds are read, a lent `?E` parameter, write, consume, the three guarded forms, a temporary subject, a generic enum, and a generic enum at a view instance (`E[?Text]`);
  - each cell is the by-name program and its positional desugaring;
  - checks: same verdict, same messages, byte-identical emitted Zig, and a sanitizer run in debug and `--release`, compared with the positional program on main + f5b0d00d.
  - Results: all 600 cells accepted, with by-name and desugared emit byte-identical (on the head binary bf652b0e). Every cell ran sanitizer-clean in debug and `--release`, with output equal to the positional program on main. 435 cells ran on a binary that differs from the head only by 76c3dc81, which changes no emit; the other 165 ran on the head.
- **Gates** (`--delta`): on pup, at bf652b0e:

  | Gate | Result |
  |---|---|
  | `./test/run --delta` | 2887 passed, 0 failed, 3 pending |
  | corpus `--delta` | 7294 passed, 0 failed |
  | `matrix.py --delta` | 5877 programs, 3213 ran clean, 2664 rejected, 0 failed |
  | unit | 127/129 (2 skipped) |
  | oracle, doc, vocab | 345 passed, 0 failed, 3 pending |
- **Equivalence against main + f5b0d00d:** 9720 programs, 431 differ, and no accepted program is now rejected. emit, storage and pkg are identical everywhere.
  - **418 differ in `--facts=sema` only:** the new `payload_binds` fact printed for each variant pattern.
  - **13 differ in check and facts:**
    - the new tests and the 2 new SPEC examples;
    - 3 corpus probes, rejected before and now accepted, which run sanitizer-clean in the corpus gate;
    - `review-step3-r2-gen04_held_generic.rig`, still rejected with the same first two errors. It loses a third, a follow-on error about an arm binding of a pattern whose subject was already rejected, because a pattern typecheck rejects or poisons records no bindings.

## Known and left open
- A by-name field shorthand (`.rect(w:)` or `.rect(w)` meaning `w: w`) is not part of the decision and isn't built.
- `.rect(w: _)` is accepted and binds nothing (the same as leaving `w` out).
