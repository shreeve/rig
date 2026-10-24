# Compiler implementer: Stage 5 buildability (main 86bca420b)

**Today.**
- `Weak(T)` points only at `Shared(T)`, so a frozen value has no weak handle (A1 holds).
- A frozen last drop runs `drop` on any worker; a plain one on its task.
- `blockerIn` already rejects every object, local tasks too (#614): A3 is SPEC wording.
- Every crossing path reaches `blockerIn`: one walk.
- `.weak` carries `.shared`'s loans by type: A4 is free.

**Rules 1–6 are buildable, and rule 1 shrinks the work.**
- The holding follows from the braces: `*{A}` is plain, `*{A + Syncs}` frozen. Atomicity is never checked per instance.
- `Owned`, `Sends`, and `Syncs` of a `T` go by its bounds.
- **A Stage 4 hole, found by reading:** `holdsTask(type_var)` is false, so `[T: Shape]` erasing `^T` with `T` holding a `Task` passes. Add `Requirement.no_task`.

**Passes.**
- `sema.objectBounds` (braces plus API supers) is the one classifier for resolve, `blockerIn`, `erasable`, and `objectMeets`.
- In `blockerIn`, `.api_object` is null when the bound for `how` is there. `.shared(object)` is decided before `atomicHandle`, and `.weak(object)` is always a blocker.
- **Second-classifier bug:** `lacks` gives `Sends`/`Syncs` of an object false, so `[T: Sends]` rejects a `^{Job + Sends}` a task takes. Route through `blockerOf`.
- `eraseShared`, beside `eraseBox`, takes a value of type `*T` or `*Frozen[T]` where `*{A}` goes. That covers `*S(...)`, `*<x`, `<h`, `+h` (rule 5), and nothing under a view (A5).
- `?s` lends `?{A}` by the `.handle` row.

**Table.**
- `_of(T, W, holding)`: `__rig_drop` and `__rig_clone` per holding (`+s` is `cloneStrong`).
- New slots `__rig_weak`, `__rig_weak_drop`, `__rig_upgrade`, plain holding only, by `@fieldParentPtr`.
- `ApiShared` must not queue drops; `dropStrong` does.
- 3 words per table; a `*{A}` is 16 bytes.

**Cost.** Phase 1 about 1,000 lines; phase 2 about 1,400, not 1,800; `no_task` about 60.

**Phase 4 vs A7: compatible** if phase 4 changes only lowering. Sema keeps `.shared(.function)`, so crossing stays "never". Make it its own performance PR.

**CORE edits.**
1. "A `*T` moves into a `*{A}`, a frozen value's handle only into a `*{A + Syncs}`; neither becomes the other."
2. "`+s` adds a count, atomic exactly when it syncs."
3. "`~{A}`, weak handle of a `*{A}` that does not sync, carries its loans."
4. "…checked where erased, a type parameter's by its bounds."
5. SPEC §18: a local task never takes an object without its bound.

Under `api Shape: Syncs`, every `*{Shape}` is frozen-only.
