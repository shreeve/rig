# A callable storing a view into a generic body's value (2026-10-27)

The problem the owner's expert panel is to solve, and the probes it rests on. Rig main `cb88b163a`; #736 has since merged as `36422da59`, and #737 (branch `closure-view-fix`) is about to.

## The bug
Map's `update` (std/prelude.rig: `pub sub update(!@, f: ?sub(?K, !V))`, a generic body over the Map's own storage) calls `f(?key, !value)` for each entry. Each value is a `V` held by value inside the table. SPEC "Generic bodies" says: "A `T` the body holds by value carries no loans it tracks."

At an instance whose `V` can hold a view, a callable that stores the key's view in the value does so unseen. When the entry is later taken, the key is dropped, and the value's view dangles: use of freed memory under `RIG_SANITIZE=1`.

The known cases, `test/rig/ownership-generic.rig.test` on `closure-view-fix`, both `known: true`, each expecting "stores a view of `k`":
```
m = Map[String, (?String)?]()  ...  !m.update(|k, v| v = k)
m = Map[String, List[?String]]() ...  !m.update(|k, v| !v.push(k))
```
The backlog entry is "A closure stores a view in a generic body's value" in `docs/internals/backlog.md`. #737 already rejects the `V = ?String` case by a type rule: "No parameter is a `!?String`, whether written so or given by the type a closure is checked against" (`sema.writesTextView`).

## What the checker does today (probes, main cb88b163a)
1. **A non-generic function that calls a callable with a view and a write view must keep the view.** This is rejected:
   ```
   sub apply(k: ?String, v: !(?String)?, f: ?sub(?String, !(?String)?))
     f(k, !v)
   ```
   with "`apply` stores a view of `k` in `v`, which its caller reaches, but its signature does not keep `k`; say so: `keeps k`". The same error comes for `v: !List[?String]`, and for a generic `apply[K, V](k: ?K, v: !V, f: ?sub(?K, !V))`, since `v` is a write-view parameter. So a callable call is already treated as possibly storing any view argument in any write-view argument (SPEC: "a call that writes self may store in it what any argument views").
2. **`update` escapes that** because its `!V` is not a parameter: it reaches an element of the Map's own storage, a `T` held by value, whose loans the generic body does not track.
3. **A named function with `keeps` passes as a callable that keeps nothing.** This is accepted:
   ```
   sub put_view(k: ?String, v: !(?String)?) keeps k
     v = k
   ...  !m.update(put_view)        # m: Map[String, (?String)?]
   ```
   So a fix at the closure alone leaves the same hole through a function value.
4. **Owned values are fine.** `Map[String, String]` with `update(|k, v| v = +k)` runs, as it should.

## Candidate rules (starting points, not decisions)
- **R1, refuse the instance.** This extends SPEC "Generic bodies"' "an instance whose method keeps an argument's view in one (`keeps`) is refused". Where a generic body passes a write view of a `T` it holds by value to a callable along with a view argument, an instance whose `T` can hold a view is refused, at the call that makes the instance. Simple and decided once per instance, but it refuses harmless uses: `Map[String, (?String)?].update(|k, v| v = none)`.
- **R2, check the callable.** A callable view type (`?fun`, `?sub`, `*fun`) carries no `keeps`. So a closure literal checked against one may not store one parameter's view in another, or in a capture (CORE sentence 7, as for any function body). A function value whose signature keeps something is not accepted where a callable type that keeps nothing goes. Precise: only the closures that store are refused. But it must hold at every way a callable reaches the type: literals, named functions, `*fun` values, and forwarding.
- Or a better third.

## Constraints (AGENTS.md North Star)
- Accept means correct; safe code cannot corrupt memory.
- One classifier per fact.
- An ownership change fits docs/CORE.md in a paragraph (CORE §10), or changes CORE first, as its own reviewed change the owner agrees to.
- The oracle (`test/oracle/`) must agree.
- A change that rejects programs a release accepted lists them in the release notes, with a migration note for Trig. Check whether Trig or std would be rejected (`~/Data/Code/trig`, `std/`).
