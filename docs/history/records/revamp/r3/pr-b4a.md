## Summary
Stage B4a of step 10: emit points at a header's subject instead of copying it. This is the code-generation half only. No program changes between accepted and rejected. It makes it possible for B4b to lift two conservative checker rules: the rejection of headers whose subject makes a temporary, and arm-local payload views.

## What changed in emit
- **Header blocks yield an address.** Some headers make a statement temporary and have a subject that reaches a place outside it (`storage.headerPoints`). That subject can be:
  - a place whose path starts at a name, or at a view whose evaluation makes no temporary;
  - a lend of such a place held as a pointer;
  - an `if` value whose every leaf is one of these.

  For these, the block breaks with `&place`. `match`, `if … as`, `while … as` (re-evaluated each pass) and `for` then bind through that pointer, and a guarded match holds it in `__rig_subject`.
- **Copies stay where there is no place.** That means a value made in the header, or a place inside a view of one (`id(?mk()).e`, `(?mk()).e`). `copiesHeader` is now recorded only where emit really copies.
- **Generic subjects are reached in place.**
  - A payload of a type parameter is bound by pointer where its match reads the subject in place (`storage.matchesInPlace`).
  - A generic read view held by a name, field or element on the subject's path is reached as `rig.viewedPtr(T, &view).*`.
  - No `rig.viewed` copy is switched on, and none has its address taken.
- **Storage facts follow emit.** `header_value`, `subject`, `as_value` and `payload` say `pointer` where emit points.

## Tests
- A `sema` unit test checks `headerPoints`, `copiesHeader` and `matchesInPlace` over 11 header shapes.
- `test/reject/ownership/header_place_inside_temporary.rig`: these headers must stay rejected after B4b.
- `test/cli/emit_shapes.sh`: fails on any `&rig.viewed(` or `switch (rig.viewed(`.
- `test/behavior/emit/generic_view_field_subject.rig` and `generic_view_field_guard.rig`: run tests that clobber the stack.
- `test/corpus/review-b4a-g21_view_field_escape.rig`: rejected today; it records the output B4b must produce.

## Verification
- **Gates:** suite, corpus, `oracle doc vocab`, and (before the merge with main) matrix and unit are all green under `RIG_SANITIZE=1`.
- **Equivalence against main 0128c295:** 8,281 programs, 14 differ, in emit and storage only. Generic payloads are bound by pointer or switched on through `viewedPtr`, and one `header_value` fact changed with byte-identical Zig. Parse, normalize, check, facts and sema are identical everywhere.
- **Experiment, never committed:** with the two checker rules switched off where the header points, every reviewer probe for these shapes printed the right values sanitizer-clean. The base build lost writes, lost Cell changes, used freed memory or read poisoned memory on them. The review's x05 shapes stay rejected.
- **Reviews:** an independent review and a re-review found no Critical, High or Medium issue. Their two findings were fixed, test-first, and are guarded by the tests above.

## Core conformance
- Emit's storage now matches what the checker already walks: a construct's bindings view the place itself (Core §2 sentence 1, §3).
- Copies remain only where no place exists: a value made in the header, whose temporaries end with it.
- No acceptance changes. Lifting the header-temporary rejection and arm-local views (CORE's "for now") is B4b's job.
