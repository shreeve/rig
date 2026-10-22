## Summary
v0.2.1 is v0.2.0 plus round C (#52) and this hotfix. v0.2.0 has six live bugs; round C fixed one, and this PR fixes the other five and adds tests for that one.

- **A generic match copies a `T` out of a value that is no place.** `match get(o)` with `.some(v) => v`, where `get` returns a view, passes `rig check` for `peek3[Text]` and frees the Text twice. The same happens for a branching subject, a lend of a call, a field or element of either, a guarded match, a nested match, and a catch-all binding. A catch-all copy also forks a Cell.
- **A box of a handle.** `bh: Box[*S]` then `bh.n` passes `rig check`, but the emitted Zig fails to compile. `Box[Box[*S]]` and `Box[*Box[S]]` fail too, and writes through these boxes weren't rejected.
- **Weak upgrade hint.** A field or method on a `Box[~S]` got a hint that repeated the rejected line.
- **A handle of a closure type.** A generic `h: *T` (or `~T`) instantiated with a function type passes `rig check`, but the emitted Zig fails to compile.
- **`*none`.** `x = *none` passes `rig check` and crashes the emitter.
- **A write loan dropped at a call** (`both(!b.firstw(), ?b)`). Fixed in round C (#52); this PR adds a constructor case and a behavior test.

## Cause and fix
- **Generic payload copies.**
  - **Cause:** the ownership checker took a payload binding to view its subject only when the subject resolved to a var, so for any other subject the binding counted as owned.
  - **Fix:** one fact, `Var.payload_view`, records that a binding does not own what it binds. It's decided from `storage.matchMode` (what emit uses) and a positive list over `handsOver` (`readsInPlace`).
  - **Sites:** every site that read `alias_of` to mean "doesn't own" now reads `payload_view`: move, drop, tail return, reassign, lend, liveness, drop order, and a nested match's `via`.
  - **Cell copies:** `readBinding` records `no_cell` for payloads and catch-alls.
  - **Oracle:** it reads a bare generic subject from a call through the view, as it reads a place's.
- **Box of handle.**
  - **Emit:** `writeReach` dereferences the box before a handle's value.
  - **Typecheck:** `sema.accessThroughShared` blocks writes, write methods, write lends and `match !b` through any box of a handle.
- **Weak upgrade hint.** The hint now lends the handle first: `w: ?~S = ?a`, then `if w.upgrade() as s`.
- **Handle of a closure type.** A new generic requirement, `not_function`, rejects an instance whose `T` is a function type, and the message points to `T = *fun(...)`.
- **`*none`.** It's rejected wherever no `*(T?)` is expected, with a hint to write `none`.

**Programs v0.2.0 accepts that are now rejected:**
- the forms above, at an owning instance;
- `return v`, `<v` and `-v` of a payload of a match whose subject is not a place, at any instance (a tail `v` still works with a per-instance requirement);
- writes through `Box[*S]`;
- `*none` where no `*(T?)` is expected;
- from round C, `both(!b.firstw(), ?b)` and its siblings.

**Newly accepted:** a nested `match inner` of a call-view payload with a tail `v` at a plain instance. v0.2.0's hint for it led to a use of freed memory.

## Tests
- **Reject tests:**
  - `generic_payload_copy_any_subject.rig` (19 forms; v0.2.0 rejects 6);
  - `generic_payload_view_moved.rig`;
  - `generic_catch_all_copy_of_cell_holder.rig`;
  - `box_of_handle_write.rig`;
  - `weak_in_box_upgrade_hint.rig`;
  - `generic_handle_of_function_type.rig`;
  - `share_of_none.rig`;
  - `argument_write_loan_held.rig`, with a constructor case added.
- **Behavior tests:**
  - `generic_payload_copy_plain.rig`;
  - `box_of_handle_access.rig`;
  - `weak_in_box_upgrade.rig`;
  - `generic_holds_owned_closure.rig`;
  - `optional_handle_none.rig`;
  - `argument_write_view_value_read.rig`.
- **Matrix:** new generic payload subjects and escapes. On v0.2.0 these cells give 45 uses of freed memory or double frees.
- **Corpus:** nine probes.
- **Docs:** SPEC and INTERNALS.

## Verification
- **Gates under `RIG_SANITIZE=1`:**
  - suite: 2,639 passed, 7 pending;
  - corpus: 6,031 passed;
  - matrix: 3,427 programs, 0 failed;
  - unit: 124 of 125 passed, 1 skipped;
  - `oracle doc vocab`: 322 passed.
- **Equivalence against main (0128c295):** 17 of 8,299 programs differ, all new tests or probes.
- **Independent review:**
  - no Critical, High or Medium finding;
  - its Low 1 (the nested match) is fixed here;
  - it confirmed four more v0.2.0 use-after-frees closed by this fix (capture, nested take, returned write view, closure) and a lost Cell change.

## Core conformance
- **Payload copies:** sentence 1 and §3. A read match views what it matches; a binding copies a `T` only for plain instances, and giving the copy away from a value the match doesn't own would duplicate it.
- **Box of handle:** sentence 4. Nothing is written through a shared handle, however it's reached.
- **Write loan:** sentence 5. A write view and a read view of `b` can't be live together in one call.
- **Handle of a closure type and `*none`:** AGENTS rule 2, accept means correct. A rejection in sema replaces a Zig error or an emitter crash.
