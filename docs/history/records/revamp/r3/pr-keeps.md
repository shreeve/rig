A call now keeps only what its signature shows (Trig NEEDS 11, owner decisions 2a-2f). A view lent to a call (a `?T`, `!T`, `[]T`, `![]T`, `?String`, an optional of one, or a `?self` / `!self` receiver) is kept only when the function names that parameter in `keeps`:

```rig
obj Parser
  src: ?String
  errors: Int

  sub watch(!self, s: ?String) keeps s
    self.src = s

  sub note(!self, msg: ?String)
    if msg.len > self.src.len
      self.errors += 1
```

`!p.note(?m)` no longer keeps `m` lent while `p` lives, and a `!self` method that only reads its argument is no longer treated as a setter. A value passed by value keeps today's type rule, a function called as a value keeps what its type could hold, and the built-in generics' methods keep every argument. Each body is checked against its `keeps`.

## The rule as built

- **Core sentence 7** gains the approved text, and sentence 4's written lends gain "a lend to a parameter the callee keeps (`!p.watch(?t)`)". Both *(built)*.
- **Desugaring** (docs/INTERNALS.md "Call origins"): none new. `f(e1..en)` is `t1 = e1; ...; tn = en; f(t1..tn)`; the write arguments' owners hold the loans of the `ti` the call keeps (the lent parameters `keeps` names, and the by-value ones whose type fits); every other `ti`'s loans end with the statement.
- **Spelling**: a clause at the end of the header, after `-> T` and any `from`, and after a failing `sub`'s `!`: `keeps s`, `keeps s, self`. `keeps` is a contextual word, like `from`.

## The fact and its classifier

- `sema.lentParam(ty)`: a view (`sema.isViewType`, moved from `src/ownership.zig`, which now reads it) or an optional of one. One classifier, recorded as `Origins.lent`.
- `sema.declKeeps` narrows `Origins.stores`, decided once per declaration: by-value parameters by type (as before), lent parameters only where `keeps` names them. Function types keep `defaultOrigins` (`lent` empty).
- The ownership checker reads `stores` (unchanged call rule) and `lent` (the body check's message); typecheck reads `stores & lent` for the written-`?` rule; the oracle reads `keeps` from the IR (`declaredKeeps`) and classifies lent types itself, and checks bodies (C6).

## Diagnostics

Per Trig's proposal-notes "Diagnostics":

- **The body check**, at the store, with the clause to write (all lent parameters the body stores, in order):
  ```error
  `set_src` stores a view of `s` in `self`, which its caller reaches, but its signature does not keep `s`; say so: `keeps s`
  ```
- **A kept lend at the caller**: the conflict's note names the call, the parameter, and the holder:
  ```error
  cannot drop `t` while it is lent
  ```
  note: lent to read here, and `watch` keeps it in `b` (its signature says `keeps s`), so the loan lasts while `b` is used
- **The declaration errors**, at the name in the clause, as `from`'s are: `` `keeps s`: `s` is taken by value, so the callee owns it already``; `` `keeps s`: `size` takes nothing to write that could hold it``; `` `a` has no parameter `t`; `keeps` names lent parameters, `self` among them``; `` `keeps s`: `s` is named twice``.
- **2e, a written `?`**: `` `b.watch(t)` keeps `t` lent in what `watch` stores; write `!b.watch(?t)` `` (and `?a.register(!out)` for a kept `?self` receiver).

Trig's expected positions differ in three places, by convention: a drop error is at the dropped name (`<t` col 4, not 3), and the two declaration errors are at the name in the clause, as every `from` error is, not at the `fun`/`sub` keyword.

## A soundness class found on the way: what a generic body's `T` carries

A generic body tracks no loan in a value of type `T`, so the body check is blind to loans that flow through one. On `main` that hid a use of freed memory with `from` (fixed separately in #215, `gtloans`, which this branch is on). With `keeps` it hid stores: corpus `rev166-l2`/`l11` (`run[T](f: ?*sub(!T, ?String), k: !T, s: ?String)` calling `f(!k, s)`) became uses of freed memory once `s` was no longer kept by type. Fix (commit "Count what reaches a type parameter's value in a generic body as stored where it is"): a store into what a parameter leads to whose type holds a type parameter is noted (`noteGenericStore`), the tracked loans of what is stored there are recorded for the parameters they reach (`genericStoreIn`, no loan taken, so no new conflicts), and every parameter #215 records as reaching a `T` counts as stored there. Coarse: one read of a `[]T` element counts it as stored wherever the body stores a `T`. Tests: `test/reject/ownership/keeps_generic_body_values.rig` (a function value storing through `!T`, a field's function, elements of a `[]T`), `test/behavior/ownership/keeps_generic_body_values.rig` (a sort that moves `T`s within `xs` and reads a lent comparator needs no `keeps`).

## Grammar

`keeps` joins `@keywords ctx` (as `from`); `keeps = KEEPS onames → 2`; a `[keeps:keeps]` slot on `fun`, `sub`, the method forms, `extern fun`, `extern sub`, and Zig-backed `fun`/`sub` (after `-> T`, any `from`, and a failing `sub`'s `!`). The schema gains `keeps:group?` on `fun`, `sub`, `extern_fun`, `extern_sub`; the IR snapshots gain the slot (`_`). **Zero new conflicts** (the grammar still has none). Parser: 495 → 626 rules, 915 → 1143 states (the optional slots expand). Nexus re-sync: copy `rig.grammar` to `nexus/grammars/rig/rig.grammar` after merge; the diff is in `.git/revamp/r3/nexus-sync-keeps.diff`.

## Migration

Mechanical, from the compiler's suggested clause (a script applied the body check's `say so` and 2e's `write ...`):

- std: `std.json`'s `Doc.parse(!self, src: ?String) -> Bool keeps src` (its doc line and docs/STD.md's table say so; every call site already wrote `?src`). No Zig-backed declaration takes a write parameter, so none needs a trusted `keeps`.
- examples: none needed.
- tests: 13 behavior tests and 42 reject tests gain `keeps` on 76 declarations (`origin_*`, `param_store_*`, `store_*`, `write_lend_temporary_*`, `vec_of_views`, `replace_swap_generic`'s `sw[T](a: !T, b: !T)` → `keeps a, b`, ...); 5 call sites gain a `?` (receivers `?s.put(!h)` in two reject tests, whose columns moved by one).
- corpus: 136 probes gain `keeps` (most of the `review-seam2b-fixes-hold-*` family, the `r3-or-*` store probes) or a written `?` (`review-syntax-b-1-s35`, `s97`-`s99`), keeping each probe's meaning.
- `test/reject/syntax/sub_with_return_type.rig`: the parser's expected list now names `keeps`.
- `test/oracle/rejections`: 124 added (the new tests, the `keeps.` grid, a CORE doc example), 6 removed: `r3-or-fit-f5*`, `r3-or-formal-store`, `r3-or-power-logger` `main` are accepted now, correctly (their callees read their argument without keeping it); each runs sanitizer-clean.

## Tests

- **Trig's 19**, imported as `test/behavior/ownership/keeps_*` (9) and `test/reject/ownership/keeps_*` (10). On the base: 8 of the 9 accepts fail (`keeps_union_copies_in` passes and still does), and every reject either fails to parse `keeps` or is rejected for the wrong reason. After: all 19 as Trig's `verdicts` expects (run on the PR's `bin/rig`: 9 accepted, 10 rejected with the expected messages). `keeps_own_field_kept` is rejected here by the plain conflict (`cannot lend p to write while a read loan is live`); A's self-view message is the combined A+B expectation.
- Rig's own: `keeps_receiver_into_write_argument`, `keeps_with_from`, `keeps_by_value_by_type`, `keeps_lent_kinds` (slice, write slice, optional, `?T`, transitive), `modules/keeps_across_modules`; rejects `keeps_clause_names`, `keeps_argument_unwritten`, `keeps_kept_loan_conflicts`, `keeps_body_store_forms` (closure, local write view, local moved in, box, `defer`, function value, `as` payload, loop, through another lent parameter, receiver into a write argument), plus the generic pair above. CORE gains a `rig` and a `rig reject` example.
- `src/rig.zig`: `keeps` is a keyword only at the end of a header. `src/sema.zig`: the origins unit test covers a `keeps` clause and a function that keeps nothing.
- **The B grid** (`test/matrix.py`, `keeps.<kind>.<store>.<said>.<then>`): 9 kinds (`?T`, `!T`, `[]T`, `?String`, `(?String)?`, a `?T` of a generic, a `?self` receiver, a by-value `Token` holding a `?String`, a call through a function value) × 5 stores (into `self`, into a write argument, through a keeping call, on some paths, none) × with/without `keeps` × read or change the owner: 168 programs (12 cells cannot stand), 57 run clean (debug and `--release`), 111 rejected, 0 failed. The store grid (`store.`) now writes `keeps` where it stores.

## Gates

(filled in below)
