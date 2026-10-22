Rig 0.2.2 fixes memory-safety holes found in 0.2.1. `rig check` accepted programs that then read freed memory, or emitted Zig that didn't compile. **Everyone on 0.2.1 or earlier should upgrade.**

## Fixed
- **A view stored through a write lend was forgotten when nothing named the target.** In `wrap(!h).keep(?s.t)`, `(!a if c else !b).keep(…)` and `(!h).r = ?s.t`, `h` kept a view of a value that was then freed. One rule now records every store reached through a write lend, for calls and assignments alike, so these are rejected when the stored view would outlive what it points at.
- **A part was moved out through a view.** `<(!s).items`, `<(?s if c else ?t).items`, `<wrap(!s).items`, `<(?v)[0]` and `<(?h).items` moved a value out of something the code only borrowed, and it was freed twice. Whether a path passes through a view or a shared handle is now decided by type, so all of these are rejected, as `<v.items` through a view always was. Taking an optional through a write view, `<(!s).o`, still works.
- **Constants lent to write emitted Zig that didn't compile.** `!false`, `!Color.red`, `!E.bad`, `!Int.max`, `!f` (a function), `!P.origin`, and the same forms from another module, are now rejected with one message: "cannot lend constant `X` to write". A local variable holding a function can still be lent to write.

## Programs 0.2.1 accepts that are now rejected
The forms above. Each was unsafe or failed to compile on 0.2.1. A comparison over 8,311 programs shows no other change.

## Verification
- New reject and behavior tests for every form.
- The full suite, the reviewer corpus, the program matrix and the unit tests pass under the sanitizing allocator.
- An independent review found no remaining soundness issue, and no regressions across 877 programs.
- CI passed on Linux and macOS.

## Requirements
Zig 0.17.0. Nexus 2.0.0 is needed only to change the grammar.

Full change: #56 (fixes), and the version bump PR.
