# PR notes: closures as values, round 1 (`closures`)

Design: `.git/revamp/r3/proposal-closures.md`, approved 2026-10-12 with
all 11 decisions as recommended. This is §7's Round 1 (`owned-sigs`).
Round 2 (`temp-callee`, Q8B) is not here. Branch `closures` from
origin/main d9e738783.

## What is built

- **Signatures (Q1C).** An owned closure's parameters and result are
  anything a function's may be. `TypeResolver.ownedClosureSignature`
  replaces the deferred `checkOwnedClosureType`. It asks `misplacedAt`
  for each parameter and the result at `Home.signature`, so a Cell by
  value is rejected as it is in any signature. `misplaced` keeps its one
  caller per pass, as the unit test checks. Also deleted: the two
  plain-data checks in `typecheck.checkLambdaGiven` (the parameter and
  the inferred result), `sema.isClosureValue` / `isClosureResult`, and
  `checkLambda`'s `owned` flag.
- **Generic bodies.** A `T` in an owned closure's signature records no
  requirement. A `T` in its captures still records `PlainRequirement.view`
  (`checkViews`), as before.
- **Ownership.** There is no new rule and no classifier change. Every
  `*fun` call already took its type's origins (`result`, `stores`), and
  the callee hold already covered every form. The grid confirms both.
  The callee-hold conflict now has the Q7 hint as a note
  (`noteCloneCallee`): "clone the handle first: `f = +self.hook`, then
  `f(!self)`".
- **Emit.** No change was needed. `rig.Closure` carries any parameter
  tuple, and `Env.__rig_invoke` is the body emitted as a function's, so
  it already drops owned arguments once: on success, on failure, and
  when the parameter is omitted. A caller does not drop a moved
  argument, and an owning result is a temporary. All of this is checked
  under the sanitizer.
- **Docs.**
  - CORE §7 has the approved text: the Closures paragraph and the new
    owned-closure paragraph, both marked *built*, with an example, a
    reject (`self.hook(!self)`), and the pending temporary callee.
  - CORE §5 has the function-type sentence, *built*.
  - CORE §3 adds "the value a call calls" to Reading (*built*), and "A
    value made to be called is a temporary too" (*planned*, Round 2).
  - SPEC §11 "Owned closures" is rewritten from the §4 desugaring, with
    the Mapper, resolver, and shout/sum examples. Its §18 row is gone.
  - INTERNALS has a new "Owned closures" section (the desugaring), and
    `isPlainData`'s row is corrected.
  - The ROADMAP line is gone, and HANDOFF notes the change.

## Tests

- New reject tests: `test/reject/ownership/owned_closure_stores_env_view`,
  `owned_closure_call_stores_arg`, `owned_closure_result_views_env`, and
  `owned_closure_callee_write_self`. The last covers a field, an
  element, a `?*fun` view binding, an `as` binding, a generic `H[T]`
  field, a `^T` box, and a local write view, with the hint pinned and
  `# errors: 7`.
- New behavior tests:
  - `runtime/owned_closure_owning_values`: the programs of the deleted
    `reject/types/owned_closure_resource_values`.
  - `runtime/owned_closure_failure_drops`: success, failure, omission,
    and a later argument that fails.
  - `runtime/owned_closure_write_param_reentrant`: three levels deep;
    the innermost call replaces the stored handle while the outer calls
    run.
  - `types/owned_closure_in_generic`.
  - `runtime/owned_closure_signatures`: a `!` result, a `?fun` param,
    and a `*fun` param.
- All of them failed on main with the plain-data message, except
  `result_views_env`, which is the Q9 guard and passed already.
- New matrix grid `clos.`: callee {local, field, element, asbind,
  view, generic, temp} x argument {`!h`, `?h`, String, `?String`} x
  result {Int, String, `?String`} x {use, conflict}. That is 168 cells,
  94 run clean and 74 are rejected, all as the model predicts.

## Equivalence (emit_equiv, main ad195ccff bin/rig vs this branch)

12,849 programs were compared. No accepted program's Zig changed. Eleven
programs differ:

- 2 messages in `test/reject/ownership/callee_*_then_written.rig`, which
  gained the Q7 hint note.
- 5 corpus probes changed message: `R11a-n1-lib`, `R11a-n1/main`,
  `R11a-n1l`, `review-text-gc`, and `seam3-review1-d06_gen_closure_getter`.
  They were rejected for "an owned closure returns plain data". Each is
  now rejected for its real fault: a capture returned by value ("a
  return value can't take it"), and for the generic ones the instance's
  `?String` or view `T` stored in captures (`checkViews`).
- 4 corpus probes are now accepted and run sanitizer-clean with the
  right output: `R16-oc1` (a `?fun` param), `docs-probes-rm-clo_own`
  (`List[Int]` param), `purity-designer-s15_owned_closure_owning`
  (`drop` runs once), and `syntax-review-designer-p08_owned_cb_view`
  (`?Event` param).
- 9 new doc blocks have no old pair: CORE ×3, SPEC ×3, INTERNALS ×1,
  plus SPEC #99 and SYNTAX #16. Those last two are unchanged text that
  the tool's rewrite pairing misses in both trees.

## Oracle

The oracle agrees on every probe it decides, and differs on none. It
already modeled owned-closure calls through function-value origins. Its
`unknown`s here are existing gaps: "an unusual callee" for an element
callee, "a method reached through a handle", and generic instances at
views.

## Soundness probes (all rejected or sanitizer-clean)

These go beyond the grid:

- Calling the closure through `g = ?self.hook`, `self.get()(!self)`
  with a `?*sub` result, a `match !e` payload, `cs[i].hook(!cs[0])`,
  `hc.hook(!hc)` with a `!*Checker` param, or `call(?c.hook, !c)` is
  rejected.
- With a cloned handle, the body may replace its holder's handle (it
  even frees the holder's closure), and this runs clean.
- A closure reached through a `*Cell[List[*sub()]]` element is rejected
  by the existing Cell rule.
- `*fun(String) -> ?String = *|s| ?s` is rejected. So is a view through
  a captured `*User`.
- `*fun(?fun) -> ?fun` given a literal is rejected by the existing
  callable rule.
- A `!Int` result keeps its write loan.
- `*sub(Cell[Int])` is rejected by the signature rule.

No hole was found in the design.

## Gates (pup, a310c08d2 = branch + origin/main 741526cb1, --delta)

- Suite: 3454 passed, 4 pending, 2 failed: `cli/inline_grid` (a 900 s
  timeout) and `cli/test_prune` ("kept the oldest builds over the cap").
  Both fail the same way on pup for `modules` and `matchperf` today
  (pup's load and store), and neither touches closures. Rerun alone:
  see below.
- Corpus: 10046 passed, 0 failed.
- Matrix: the FULL grid. 9504 programs, 5830 ran clean and 3674
  rejected, 0 failed. This includes the new `clos.` grid: 168 cells, 94
  clean and 74 rejected.
- Unit (fresh cache): 162/164, 2 skipped.
- oracle, doc, and vocab: 407 passed, 0 failed.
- An earlier round caught a unit-test failure (a second `sema.misplaced`
  caller in resolve). It is fixed by `ownedClosureSignature`, which goes
  through `misplacedAt`.
- 41 new oracle rejections are listed in `test/oracle/rejections`: the
  new reject tests, the `clos.` reject cells, and the five corpus probes
  whose message changed. All of these are functions the compiler also
  rejects. No new `stricter` difference appeared.

## In-flight branches

There is no shared fact or classifier. Ownership changes only in
`conflicts`, which gains a diagnostic note, near line 880. `matchperf`
edits ownership near 5052–5092 and 5991 (the match merges). Typecheck
changes only in `checkLambda*` and its callers. `simd2`, `trigfix`, and
`modules` touch other typecheck regions. `b123` does not change
`ownership.zig`.
