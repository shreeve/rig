## Summary

In released Rig, a view of a read-`match` payload could escape the match and dangle: `?r` returned from `.a(r) => ?r`, or stored with `saved = ?r`. Emit binds a read payload from a copy of the subject: a prong-local `const r = payload.r`, a guarded match's `var __rig_subject_N`, or a generic body's `rig.borrowed(...)`. The ownership checker treated the binding as an alias of the subject, so a view of it outlived the copy. The sanitizer can't see this, because the copy lives on the stack.

A view of a read-`match` binding is now usable only inside its arm.

## Cause and fix

- **Checker (`src/ownership.zig`).** A read-`match` binding (payload or catch-all, guarded or not, generic too) is marked `arm_view`. A view of it (`?r`, `?r.f`, `?r.xs[..]`) holds a frame loan on the binding, so the existing scope-exit and return checks reject returning it, storing it in an outer binding or field, or yielding it as the match's value.
  - A view into heap memory the payload owns (a String of a Text, a slice of a Vec, a box's value) still leaves the match, held by the loan on the subject as before.
  - `match !e`, `match <e`, copied primitives, and payload fields that are themselves borrows are unaffected.
- **Diagnostic:** "a view of `r` does not outlive the `match` that reads `e`", with a hint: copy it (`+r`), take the subject (`match <e`), or use it in the arm.
- **Emit (`src/emit.zig`).** A catch-all binding of a lent subject (`?E`) is captured by pointer (`|*x|`). It used to be captured by value, which failed in Zig (`expected *const E, found E`).
- **Docs.** SPEC §match gains the rule and a `rig reject` example; INTERNALS gains the checker rule and the emit captures.

## Tests

- `test/reject/ownership/match_payload_view_escapes.rig`: 17 escape shapes, including place, box, a lent call, guarded, catch-all, generic, an array view, and stores into a binding, a field, or a match value.
- `test/behavior/ownership/match_payload_view_in_arm.rig`: in-arm views still work and print correctly after a stack clobber.
- `test/behavior/ownership/match_write_payload_views.rig`: writes through `match !e` land in the subject.
- `test/cli/emit_shapes.sh`: the emitted capture shapes.
- `test/matrix.py`: new `payload.<type>.<subject>.<use>` cells. A cell that runs must also print the payload's value.

## Verification

- All four gates pass: suite 2325/0, full corpus 4281/0, matrix 0 failed, `zig build test` with a fresh cache.
- Equivalence against `main` over 6342 programs: 5 differ, all explained.
  - The 3 new test files.
  - 2 corpus probes that were already rejected and now carry the new message.
- Every round-2 review probe that applies on main is now rejected.

## Core conformance

Core sentence 6: a loan lasts until the last use of every view that carries it. A view of a read-`match` binding carries a loan on the binding, which is the arm's copy and ends with the arm, so the view can't outlive the arm. No exception list is needed. Where emit binds in place (`match !e`) or by ownership (`match <e`), there is no frame loan and the existing rules apply.

## Not in this PR

The `if … as` Cell-holder copy (a lost update, not a memory error) and the over-strict rejection of nested payloads are left for later fixes.
