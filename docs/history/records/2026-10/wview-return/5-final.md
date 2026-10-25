# Returning a view through a write-view binding: the final CORE text for the owner

The panel was a designer, an adversary and a reviewer, and accepted it with the reviewer's four fixes. It lands after the hotfix (defers vs a returned result) that the reviewer found on main.

## CORE sentence 7, after "…not a loan on the holder."

> A view reached through a write view that a binding holds (`!s.value`,
> `s: !Slot`) carries that view's loans, path for path, and a loan on the
> binding that ends with the binding's scope. So `if !@slots[j] as s` may
> `return !s.value` `from @`, but nothing in that scope, its defers
> included, may use `s` while the view lives. *(planned)*

## CORE §7 (Defer), after "…never extend a loan past it."

> What their scope gives back is live while they run.

## What it means
- **Accepted:** `if !@slots[j] as s` / `return !s.value` with `from @`, the same through `s = !@a`, a `for s in !@xs` element, and call results, and Polonius problem case #3.
- **Still rejected:**
  - writing `@slots[j]` while the returned view lives;
  - a view of a local (`s = !x`, then `!s.value`);
  - `from @o` returning a view of `@p`;
  - any defer, deferred closure, waited task or drop body using `s` while the view lives;
  - returning an earlier iteration's binding in a later one.
- **`match !` payloads:** tested, or recorded as a separate limit.
- **`from @field`:** `checkSelfPaths` skips the binding-only loan.

## Build
- About 25 lines in the ownership pass: a binding-only `deref` loan, skipped by `checkEscape`, `escapeVarsFrom` and `checkSelfPaths`.
- The oracle already models it; remove its now-agreeing differences.

## Unlocks
Map and Set `find` hand back the entry (`(!Entry[K, V])? from @`), removing the re-lookups behind the 1.3–1.9% ceiling on ts-pattern.

Reports: 1-design.md, 2-adversary.md, 3-draft.md, 4-review.md.
