# `$plain(T)` narrowing: the brief for its panel

## Why
The packed Map (map-stage/design.md, candidate 2, tuned and with no flag) is measured on Trig's real map traces at **4.4% of ts-pattern's cycles** (warm 37M, cold 294M faster). Peak memory for the replayed maps falls from 103.0 to 69.1 MB. Record: docs/history/records/2026-10/map-stage/replay.md and #695.

The dense-only variants lose (1.5% and 3.7% slower), so the gain lives in packed slots.

A packed table's free slots must hold some key and value, and safe std can't make one inside a generic body:
- `K()` is rejected ("`K` is a type, not a value"), and objects like `CacheKey` have no default.
- Filling a free slot with a copy of a real entry fails SPEC's rule that "where the body copies a `T`, every instance must be plain data". `if $size(K) <= 8` doesn't change that: it still rejects `Box[String]`.

## The proposed rule (one sentence, SPEC's generics section)
> Inside `if $plain(T)`, the body is checked for a `T` that is plain data, and only instances where `T` is plain compile that branch.

It's the same move as `if x as y` narrowing a value, and as Zig compiling only the taken compile-time branch. `$plain(T)` is the compile-time question the owner already approved in Map design (c), next to `$size(T)`. It's true for exactly CORE §1's "plain" kind: `Int`, `Bool`, `Static`, enums, `Simd`, and objects whose parts are all plain.

## Questions for the panel
1. **Soundness.** Can a narrowed branch leak a plain assumption into code that every instance runs? Cover:
   - values made in the branch that escape it;
   - closures made in it;
   - `defer` in it;
   - `else` branches;
   - nested generics called from the branch with T;
   - `$plain(T) and ...` conditions;
   - `not $plain(T)`;
   - `$plain(P[T])`;
   - associated types (`S.Item`);
   - bounds.
2. **Scope.** Is `$plain` alone the right narrowing, or should `$copies(T)` (plain, or a read view) be the question instead, since the rule SPEC states is about copying? Keep it to one simple rule, by Rig's least-surprise principle. Don't generalize to arbitrary compile-time conditions.
3. **Where it lives.** CORE's scope line puts generics' per-instance checks in SPEC. Does CORE need any sentence, for example in §1's kinds or in §10? The owner approves the text either way.
4. **The oracle** (test/oracle) is a second checker written from CORE. Does it need to know this, or does it see only instances?
5. **Implementation size,** in typecheck, sema and the per-instance checks, and the tests that show it.

## Bar
- It fits one paragraph and has no exception list (CORE §10).
- Every accepted program runs clean under the sanitizer.
- It's used by the packed Map, the line that failed in a real program.
