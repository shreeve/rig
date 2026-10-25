# Returning a view through a write-view binding: the combined draft (Rig (OG), from 1-design.md and 2-adversary.md)

## CORE, sentence 7, after "…not a loan on the holder."

> A view reached through a write view a binding holds (`!s.value`,
> `s: !Slot`) carries that view's loans, on their exact paths, and a
> loan on the binding. The loan on the binding guards the binding until
> its scope ends, its defers, the closures they call, and the tasks it
> waits for included, and nothing past that scope reaches it. So the
> view may outlive the binding: `if !@slots[j] as s` may `return
> !s.value` `from @`, but no defer may use `s` once a view lent through
> it is returned. *(planned)*

## The rules
1. **Lending through a write-view binding** (`if … as`, `=`, a `for` element, a `match !` payload) carries the binding's own loans on exact paths (H3: `from @o` returning a view of `@p` stays rejected), plus a `deref` loan on the binding.
2. **The `deref` loan guards the binding while it's in scope** (H2: `r = !s.value` then `s = Slot(...)` stays rejected). It is skipped by `checkEscape` and dropped silently by `escapeVarsFrom`, so the view may outlive the binding.
3. **Uses after the return count as uses in scope (H1, a bug today):** a defer, a closure a defer calls, a task the scope waits for, and a drop body. So `return s` or `return !s.items[0]` with `defer s = …` is rejected. This also fixes today's `return s` + defer bug.
4. **Subjects that aren't lent places stay rejected (H4):** hidden held vars, temporaries, `arm_of`/`erased_of`, and a local's view (`s = !x`, then `!s.value`: "cannot return a view of `x`, which this function was not lent").
5. **Several results (H5):** sentence 5 is checked among the results first.
6. **Guarded returns (H6):** the loan starts on the returning edge only.

## Cases
- **Pending, then ordinary:** m1 prints `42`.
- **Stay rejected:**
  - r1: assigning `@slots[j]` while `v` lives;
  - m4: a local's view;
  - H1's defer, deferred closure, and waited task;
  - H2;
  - H3.
- **Pass:** for `s`, `match !` payloads, call results, and Polonius #3 (a conditional return, then `@` reused on the `none` path).

## Build
- About 25 lines in ownership.zig: `Loan.deref`, `lendOn`, `checkEscape`, `escapeVarsFrom`, plus H1's use-after-return check for defers and waited tasks.
- The oracle already models it. Remove the differences entries that now agree; no prod-accepts.

## Unlocks
- Map and Set `find` returning `(!Entry[K, V])? from @`, with `edit`/`ensure` on top, removing the index re-tests behind the 1.3–1.9% ceiling.
- The generic read form over `Slot[K, V]?` (h5/h6) is a separate gap, to fix alongside it in the build.
