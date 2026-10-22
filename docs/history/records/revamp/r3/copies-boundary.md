# Design note: where a read view of a value that copies is copied out

**Branch `copies`.** Probes are `test/corpus/review-copies-p45*.rig`, and each runs as the table shows.

## The boundary today

Core sentence 1: "a bare name or place only reads; it copies plain data and read views". Core §4: "a view of a value that copies is copied out where that value is expected".

The branch follows both literally. Where a type is expected, the value is copied out. Where nothing names a type, a read view is copied *as the view*. The exception is a read view of a scalar (number, Bool, String, plain enum), which reads as the scalar, as it did in v0.2.2.

| Form (`a: P`, `r = ?a`, `w = !a`) | Result | Why |
|---|---|---|
| `b = r` | `?P`, `a` stays lent (p45) | no type named: the view is copied |
| `b: P = r`, `f(r)` with `f(p: P)`, `return r` from `-> P` | `P` copy | a `P` is expected |
| `b = r if c else p` | `P` copy (p45b) | the branches meet as `P` |
| `b = r ?? P(...)` with `r: ?P?` | `P` copy (p45f) | the fallback names `P` |
| `b = w` | `P` copy (p45c) | a write view never copies, so it reads (sentence 1) |
| `id(?n)` / `id(?a)` | `Int` / rejected, `T = ?P` (p45d) | inference reads a scalar through, keeps any other view |
| `r == P(x: 1)` | compares values (p45e) | an operator reads through |
| `[3 of r]` / `b: [3]P = [3 of r]` | `[3]?P` / `[3]P` | as `b = r` / `b: P = r` |

The boundary is sound: the reviewer could not break it, and the view binding is an ordinary view with a tracked loan. It is not least-surprise, though. Adding an `else` arm, or writing `!a` for `?a`, changes the binding's type and how long `a` stays lent.

## Options

1. **Keep it, and state it.** Add one SPEC sentence: "With no type named, a bare read view is copied as the view, except a view of a scalar, which reads as the scalar; where a type is expected, or where branches meet a value, the value is copied out." No program changes. The scalar exception remains an exception list in effect (Core §10).
2. **A bare read of a view of a value that copies gives the value, everywhere.** `b = r` binds a `P`, and `id(?a)` infers `T = P`. This is one rule for read and write views, matching sentence 1's write-view clause. Cost: accepted programs change type, and some become rejected:
   - `b = r`, then `H(r: b)` for a field `?P`, needs `?b`;
   - returning `b` as a `?P`, or passing it where `!P` is lent on, fails.

   The equivalence run would list them. A migration hint is needed ("write `b = ?a` to keep the view"; `?r` lends on a held view).
3. **Never read through without a named type, scalars included.** `b = r` with `r: ?Int` binds a `?Int`, inference gives `T = ?Int`, and branches stay views. This is also one rule, but it breaks far more programs (every `x = r` of a scalar view, then `x += 1`) and makes numbers less convenient.

## Recommendation

Option 1 now; it is documentation only. Then option 2 as its own round, with the scalar exception removed: "a bare read of a view gives the value when the value copies; to keep the view, lend it on (`?r`)". That is sentence 1 as already written for write views, extended to read views.

Option 2 needs:
- a Core change first (sentence 1, §4);
- equivalence listing every newly rejected program;
- hints for each.

It also makes the inference row consistent (`id(?a)` gives `P`) and removes `readsAsValue`, the last place that re-decides "copies" with a list.

**Addendum (second review, L4):** a `catch` whose value is a view copies it out at the `catch`, after its handler, while a `??` fallback and a branch arm copy out where they stand. So `v: N = get(?a, false) catch ?N(...)`, or a handler block ending in `?loc`, is rejected, while the same with `??` or `if` is accepted. This is sound, and classified compiler-stricter. Recording the copy-out on each leaf, as `unify` arms do, would make the forms agree. Decide it with the boundary above.
