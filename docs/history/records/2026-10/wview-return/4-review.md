# Review: returning a view through a write-view binding

Probes: `probes/rv/` (bin/rig 0.2.9, rig-oracle).

## Holes

1. **A last value skips its scope's defers.** This is a main bug, worse than H1.
   - q1 is accepted: `if c` / `defer !@xs.clear()` / `!@xs[0]`. The caller then writes into a dropped element (q4 leaks). q2, a last value `s` with `defer s = …`, is accepted too.
   - The oracle rejects both. `walkIfBinding` escapes before `popScope` runs the defers, so rule 2's drop would let `!s.items[0]` dangle.
   - **Fix:** hold the value while the defers run.
2. **`return s` and a last value `s` leave `s` usable,** though sentence 1 says they move it. Defers can still use `s` (d1, c1, d3), which is H1. A task holding `!s` passes too (t3, t4, t6), while `<s` is rejected (t7).
   - **Fix:** move `s` as `<s` does.
3. **`match !` payloads are listed under Pass but aren't covered.** Today's `return s` of a payload is rejected (mp.f), and rule 1's guard may skip payloads.
   - **Fix:** include them and test mp.g and mp.h, or list them as a separate limit.
4. **`from @field`:** `checkSelfPaths` must skip `deref` loans.

**Closed already:** a closure in `@` (none hold views), a task on `!s` (t1), a guarded `break` (o1.e), failure paths, and the `x` → `y` chain.

**Drop** the claim that a later iteration may return an earlier binding. The oracle rejects it (o2.d2).

## Rule 3

Rule 3 is the wrong fix: returns already count those uses (d2, p1). Holes 1 and 2 are the fix; ship them first as a hotfix.

## CORE text

Add to sentence 7, after "…not a loan on the holder.":

> A view reached through a write view that a binding holds (`!s.value`,
> `s: !Slot`) carries that view's loans, path for path, and a loan on the
> binding that ends with the binding's scope. So `if !@slots[j] as s` may
> `return !s.value` `from @`, but nothing in that scope, its defers
> included, may use `s` while the view lives. *(planned)*

Add to §7 Defer, after "…never extend a loan past it.":

> What their scope gives back is live while they run.

## Verdict

Approve with fixes 1–4, after the hotfix.
