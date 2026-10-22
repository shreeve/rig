# Step 3c design summary (Plan agent, 2026-09-26, read-only vs main ff9aa85)
Full text is in the lead session transcript (cd00b9f1). Key points:

1. Closure ARGUMENTS (non-escaping): the parameter type is `?fun(A) -> R` / `?sub(A)`, a read borrow of a callable that reuses the second-class borrow rules. `fun(A)->R` already means a first-class function pointer, so it cannot also mean a closure.
   - Accepts: a bare closure literal, `?f` of a named stack closure, a function name, or `?cb` of an owned closure. Rejects `*|..|` (with a hint) and `!fun`.
   - Captures: `|?x|` / `|!x|` (1b).
   - Lowering: fat pointer `rig.FnRef` `{ctx, call_fn}`, 16 bytes, one indirect call, no allocation. The monomorphized `anytype` alternative stays possible later with no source change.
   - Generic inference: two-phase (non-literal args, then closure literals, then leftover params from the literal's result).
   - Size: ~560 LOC.
2. Unique box `Heap[T]` (`Box` is taken: 217 structs in tests and docs).
   - Owning, never Copy. Move `<h`; `+h` is rejected.
   - Auto-deref for fields and methods; `?Heap[T]` coerces to `?T`, `!Heap[T]` to `!T`; `<h.take() -> T`.
   - Constructor `Heap(value: <x)`.
   - `T` holds no borrow; `*Heap[T]` is rejected.
   - Needs companions: a borrowing `as` (`if ?o as x` / `if !o as x`) and `Vec[Heap[T]]` elements.
   - Lowering: `*rig.HeapBox(T)`; deep drop is queued like RcBox.
   - Size: ~640 LOC.
3. Bytes (~550 LOC):
   - writable slices `![]T` / `!xs[a..b]`;
   - open ranges `xs[a..]`, `xs[..b]`, `xs[..]` (a `DOTDOT_OPEN` rewriter mark);
   - `buf.read[U16, .big](4)` / `!b.write[U32, .little](0, v)` over a builtin `Endian`;
   - `!dst.copy(src)`, `!s.fill(v)`, `!s.swap(i, j)`.
4. Struct `==` (~200 LOC): structural over equatable types. Handles, Vec, Cell, Signal, functions, views and drop-glue types are rejected. `rig.eql`. Generic `==` then admits String and structs.
5. Ordering (~100 LOC): `< <= > >=` on String and `[]U8`, lexicographic. `.ordered` admits String, so `max("a", "b")` works.
PR order: 3c-1 (items 4+5) -> 3c-2 (item 3; grammar first) -> 3c-3 (item 1) -> 3c-4 (item 2) -> capstone examples (sort, tree), then swap/replace and Vec insert/remove.

## Lead decisions (not user-facing)
- A closure literal is written bare at the call site; accept the indirect-call cost for now.
- Reserve `Endian`; `copy_within` later.
- `==` on handles is rejected for now (no implicit identity).
- `<` covers String and `[]U8` only for now (extending to `[]T` of ordered `T` is easy later).
- `take` as Heap's unwrap method; swap/replace and Vec insert/remove as a small follow-up.

## USER DECISIONS (2026-09-26)
- Closure parameter spelling: `?fun(A) -> R` / `?sub(A)` (a borrowed callable). APPROVED.
- Byte I/O: `buf.read[U32, .little](at)` / `!b.write[U32, .little](at, v)` with builtin `Endian`. APPROVED.
- Capture shorthands `|?x|` and `|!x|`: APPROVED.
- Unique box name: user wants 3 letters and likes `Own[T]`, asked why `Heap`. Lead recommends `Box[T]`, reserving it and renaming the 217 test/doc `struct Box` definitions (e.g. to `Wrap`); `Own` is workable but misleading, since every Rig value already has one owner and the new type adds indirection. USER CHOSE `Box[T]` (2026-09-26). Existing Box uses renamed to `Wrap` in PR #10 (branch rename-box, worktree ../rig-rename-box).
