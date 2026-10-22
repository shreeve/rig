A soundness fix: a generic body's `from` check now sees the loans that reach a value of a type parameter's type.

## The hole, on `main`

A generic body is checked once, and it tracks no loan in a value of type `T` (SPEC "Generic bodies"). In an instance a `T` may hold a view, so a `T` made from a parameter views what that parameter's argument views. The body check of a `from` clause read only the tracked loans, so it never saw one reach the result through a `T`. Accepted on `main`, and a use of freed memory under the sanitizer:

```rig
fun pick[T](f: ?fun(?String) -> T, a: ?String, b: ?String) -> T from b
  f(a)

sub main()
  g = |s: ?String| K(s: s)
  t = String("abc")
  u = String("u")
  k = pick(?g, ?t, ?u)     # the caller keeps only `u` lent
  <t
  print(k.s)               # reads freed `t`
```

Likewise `-> T from ys` returning `xs[0]` of `xs: []T`, `o ?? d` and `if <o as v` of `o: T?` taken by value, `self.f(s)` through a function a field holds (`H[T]` with `f: *fun(?String) -> T`), a `match` payload of type `T` viewing a `?Opt[T]` subject, and a result that holds a `T` beside a view (`-> P[T] from c` with `P[T]` holding `s: ?String` and `v: T`, built from `x: T`).

## The fix

Class: *a generic body drops the loans of a value whose type holds a type parameter, so the origins body check cannot see them*. Where the checker drops those loans it now records the parameters they are on (`taintGeneric`, `ownership.zig`): a call's result, a field or element read, a binding (and a reassignment), a loop element, a copy a `match` binds, a `<` take, a `replace`'s result, a clone, a view a header reads through, a variable of such a type that is read (a `match` payload's view of its subject: its loans), and a parameter taken by value that is read. `checkOrigins` counts each recorded parameter as returned wherever the body returns a value whose type holds a type parameter, beside its views or not (`P[T]`). No loan changes, so nothing else the checker decides moves; only bodies whose `from` leaves out a parameter that reaches a `T` result are newly rejected.

- `sema.holdsTypeParam(ty)`: a type parameter or a type built from one (`List[T]`, `T?`, `Bag[T]`), but no function type and no compile-time value (`Simd[U8, n]`).
- A call through a function a field holds records the receiver's and arguments' loans, not the holder's, which the function does not reach.

It is coarser than a loan: one read of a `[]T` parameter's element counts it as returned wherever the body returns a `T`. A body that hits that is told to name the parameter in `from`. Known strictness, from the review: `if o == none` on a `T?` taken by value (f03), a `for` that only counts a `[]T`'s elements (f02), and `_ = xs[0]` (f04) each count that parameter as returned. Making them precise needs the loans themselves to ride on `T` values, a change to the generic body model, not this fix.

The oracle accepts every generic body (it abstains or decides without loans through a `T`), so it cannot check this class; teaching it generic loans is a follow-up.

Siblings checked: the `stores` half of the same class (a `T` stored where the caller reaches it) is safe on `main`, where a call keeps by type every argument a `T` could hold; it matters only once `keeps` narrows that, so it lands with `keeps` (the keeps PR). Local loans dropped into a `T` are unchanged (a generic body's model, SPEC "Generic bodies").

## Review round 1

The adversarial review found two more shapes of the class, both accepted on `main`: a result type holding a view beside a `T` (only results of exactly `T`-holding types were counted), and a `match` payload of type `T` viewing its subject (a `T` variable's own loans were dropped on read). Both are fixed in the commit "Count a T variable's loans, and every result that holds a T"; siblings checked: `if … as` and `for` bindings (taken where they are bound), closure parameters of type `T` (taken by value, recorded on read), fields through `T`-typed locals (a `T` has none; fields of a `P[T]` are recorded where read). The review's probes a01, a04, a12, a13, a14, a19, a23 are in `test/corpus/rev215-*`.

## Tests

- `test/reject/ownership/generic_value_from.rig`: the seven shapes above, each rejected at its return; accepted on `main` (the test commits fail there).
- `test/behavior/ownership/generic_value_from.rig`: a `from` that names the parameter its `T` comes from still runs, with the other argument dropped while the result lives.
- `test/matrix.py`: `gen.<form>.<said>.<then>`, 28 cells: seven forms (a callable's result, a `[]T` element, `??` and `as` on an owned `T?`, a closure's result, a field's function, a `match` payload of a viewed `Opt[T]`) × `from` naming the source or not × read or drop what it views. Named and read: runs, in debug and `--release`; the rest rejected. On `main`, the unnamed cells fail (they run).

## Gates

- Mac fast gate at the tests and fix commits: suite 3716 passed, 2 failed (the oracle rejected the first `as` form, `if o as v` / `return v` of a generic owned optional, as copying a resource, a pre-existing oracle limit; the cells now take the subject, `if <o as v`), then `./test/run oracle` 5/5. The `gen.` grid: 24 programs, 6 ran clean (debug and `--release`), 18 rejected, 0 failed; on `main`, 12 fail.
- After the review fixes, Mac fast gate: suite 3718 passed, 0 failed; unit 174/176 (2 skipped); `gen.` grid 28 programs, 7 ran clean, 21 rejected, 0 failed; `rev215` corpus 7/7.
- Full gates (burst, `--delta`, with Nexus built in the spilled tree): suite at a12b6c594: 3716 passed, 2 failed (`vocab` and `style`, which need `.git`; both pass on the Mac at the same commit, with `unit`); corpus 10076 passed, 0 failed; matrix at 5534ba13f: 11409 programs, 6840 ran clean, 4569 rejected, 0 failed (32 cores, about 46 minutes, the host oversubscribed). The oracle sets pass inside the suite.
- 5534ba13f renames three `rev215` probes from "struct" to "object" (owner's vocabulary); `rev215` 7/7 rerun.
