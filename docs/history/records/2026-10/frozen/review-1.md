# Review: `*Frozen[T]` (branch `frozen`), and its fixes

2026-10-22. One reviewer, as the owner's decision 5 set the CORE
process for this change: the CORE sentence and soundness, with about
50 probe programs run under the sanitizer and `--seeds=20`.

## What held

Field writes, `!@` methods, `<f.s`, `swap`, enum payloads, `List`,
`Map`, and `^T` holding a `*T`, type aliases, imported and imported
generic types, weak handles, equality and hashing by content, and the
last drop on another task (16,000 clone and drop pairs, clean).

## Findings, and how each was fixed

1. **Blocker: `Frozen[T]` by value was accepted** as a field, a
   parameter, a view (`?Frozen[T]`), an optional, or a type argument,
   and Zig then failed. Fixed: a frozen value lives only behind `*`
   (`TypeResolver.misplacedAt` for written types, `typeInstance` for a
   type argument in an expression); `Frozen` is no longer counted with
   the heap built-ins, which hold their value by pointer.
2. **Blocker: a generic body that froze its parameter,** with no
   `Frozen` in its signature, was not checked per instance, so a
   `*Frozen[*N]` could reach `par.map`'s workers. Fixed: the
   requirement `Requirement.frozen` on each type parameter a frozen
   value reaches (`sema.requireFrozen`), checked in every instance,
   bounded or not.
3. **Read methods and indexing did not reach through the handle.**
   Fixed: `sema.unwrapReadAccess` reaches the value a frozen handle
   froze, as member access does.
4. **`?f` lent `?*Frozen[T]`, not `?T`.** Fixed in `sema.lendRows`, and
   `?a == ?b` compares contents (`Checker.sharedContent`).
5. **`Map` and `Set` could not be frozen:** the walk saw the generic's
   declared fields, and rejected a bounded parameter. Fixed: a type
   parameter is decided per instance, by the requirement of point 2.
6. **Minor: freezing a frozen value nests through a generic.** Kept: a
   frozen value may hold frozen values; the direct `*Frozen(<f)` is
   rejected only because `+f` is what was meant.
7. **The CORE sentence** lacked the "lives only behind `*`" clause,
   tasks, and what `?f` lends, and said "nothing writes through its
   handles" where sentence 8 already says so of every handle. Rewritten
   to: lives only behind `*`; no `Cell`, `Signal`, task, closure, view,
   or handle but another frozen value's; nothing it reaches ever
   changes; `?f` lends the frozen value as a `?T`.

Also: freezing a `^T` is rejected as `*` of one is ("would hold it
twice"). A generic whose signature names `*Frozen[T]` and whose body
freezes a `T` reports a bad instance twice, once for each.
