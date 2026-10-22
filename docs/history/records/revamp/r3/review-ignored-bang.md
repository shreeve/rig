# Review: `ignored-bang` at 596161e4 (impl da4cf0b3)

Reviewer: independent fast-gate review. Base for comparison: 8f7cf2c6
(the branch's merge base), built in its own worktree; branch built at
596161e4 (`zig build`, `zig build oracle`). Probes:
`.git/revamp/r3/probes/review-ignored-bang/`. Runner per probe: base
`rig check`, branch `rig check`, branch `RIG_SANITIZE=1 rig run` when
accepted, branch `bin/rig-oracle`.

Note: main has moved to 1d356a09 (payload-names, #86, touches
typecheck/sema/emit). `git merge-tree` of 1d356a09 and 596161e4 is
clean, but the AGENTS.md "one branch at a time" rule still wants the
full gates on main+this branch before merge.

## Verdict

**No memory-soundness hole found.** Every accepted probe runs
sanitizer-clean, emitted Zig is unchanged for every accepted program,
and the oracle reports no difference on any probe except one
pre-existing "stricter" (prod rejects, oracle accepts) case unrelated to
this branch. The decision is implemented correctly for call arguments,
constructor/variant fields, typed bindings, assignments, results,
`??`/`if`/`match` arms and array elements. It is **not** decided in
exactly one place: an untyped loop value still reads `!x` silently
(High), and several other value positions read `!x` through other
paths (design notes). One adjacent pre-existing accept-means-correct
bug (`?!n`) is in the same class.

## Findings

### High 1: an untyped loop value reads `break !n` silently

- Probes: `r07_loop_break_view.rig`, `r10_for_break.rig`,
  `r11_while_two_breaks.rig`.
- `a = while true` / `break !n` / `a += 10` / `print(n, a)`: accepted on
  base and branch, prints `1 11`. The `!` is ignored: the write never
  reaches `n`. Same for `for ... break !n ... else !m` and a `while
  true` with two `break !x`.
- Expected per the decision: rejected (or the view kept, as `b = !n if c
  else !m` and a `match` whose arms are all `!x` keep it, `r09`).
- The typed form `a6: Int = while true / break !m` IS rejected
  (`r05`), and so is an untyped loop mixing `break !n` with `break m`
  (`r13`, via unify), so only the all-lend untyped loop slips.
- Root cause: `checkLoopValue` with no expected type records the loop's
  type as `!Int` and does not adapt its break values; the binding path
  (typecheck.zig ~866) then reads the whole loop through
  `readThrough(rhs, ..., bindingValue(...))` because `yieldsWriteView`
  lists `if`/`match`/`??`/`catch`/blocks but not `while`/`for`/`labeled`.
  That is a second decider for "a write view read where a value goes",
  outside `recordAdapted`. Relatedly, `sema.handsOver` calls a loop's
  value `.made` even when every break is a lend, while an `if` with lend
  leaves is `.branches` — two classifiers disagree on what a loop value
  hands over.
- Fix (either): give loops value leaves in `yieldsWriteView` (keep the
  view, like `if`), or reject a `break !x` whose loop value is then read
  by the binding, from the same `ignoredWriteLend`.
- The reject test's header claims "each arm of a value that branches";
  add a loop case.

### High 2 (pre-existing, same class): `?!n` in an `Int` slot emits `&n`

- Probe: `r17_read_of_write_lend.rig`.
- `f(?!n)` with `f(x: Int)`, and `b: Int = ?!n`: accepted on base and
  branch; emit writes `const a: i64 = f(&n);` and Zig fails ("expected
  type 'i64', found pointer"). Accept-means-correct violation.
  (`c = ?!n` alone binds and runs, `r18`; `f(?(?n))` works.)
- Root cause: typecheck reads the read-lend through (`recordAdapted` /
  `recordRead` on the outer `?`), but emit strips one sigil and emits the
  inner `!n` as an address. Under this round's rule the `!` here is
  ignored anyway, so rejecting `?!x` where a value goes (or everywhere
  outside a `!T` slot) would close it. Not introduced by this branch,
  but it is the same "write lend meeting a value slot" class and the
  branch's checker does not see it because the outer node's type is a
  read view, not `.write_view`.

### Medium 1: docs overclaim the rule's reach

- CORE §4 (new sentence) and SPEC "Lending" say `!x` "where a plain value
  goes" is rejected. Still accepted (base and branch): `!n + 1`,
  `!n == 1`, `-!n`, `arr[!i]`, `0..!i`, `print(!n)` (`r19`); `+!n`,
  `<!n`, `b3 = +!n` (`r16`, runs `1 1 1 1 1 11 -1`); `?!n` (High 2);
  the loop (High 1). Either narrow the doc sentence to the slots built
  ("a parameter, a field, an element, a typed binding, a result") or
  extend the rule (see design notes). Rule 1: docs make no claims the
  suite does not check.

### Low 1: hints that offer a form that is itself rejected or wrong

- `G(r: G(r: !n))` (`r01` line 43): hint "Write `G[!Int](r: G(r: !n))`",
  the outer call spliced. Cause: `fieldSlot` falls back to
  `self.current_call`, which is the enclosing call when the inner
  constructor is checked contextually (not via `synthCall`).
- `Cell(!n)` (`r04` line 35): offers `Cell[!Int](!n)`, which is rejected
  (`r06`: `Cell[T]` requires a T that copies...). `viewInstance` should
  not offer a view instance a type cannot take.
- `f(!!n)` (`r15`): "Write `f(!n)` to pass a copy" — still rejected;
  strip every `!`.
- `pair(!n, !m)` (`r01` line 46): each hint keeps the other `!`, so
  neither suggested line compiles.
- `math.max(!n, 3)` (`r14`): "parameter must be a `!Int`" though it is
  declared `T` (module-qualified calls don't pass `.declared`; `get(!n)`
  says `!T`). `!gi.set(!m)` on `G[Int]` likewise says `!Int` for `x: T`.
- `takeo(Opt.some(v: !n))` with `takeo(o: Opt[!Int])` (`l01_double_report.rig`):
  now two errors (the new one, plus the old "expected `Opt[!Int]`, got
  `Opt[Int]`"). The new one's hint is right; the mismatch is redundant.

### Low 2 (oracle, pre-existing): loop-value loans

- `r23_loop_break_view_noncopy.rig`: `w = while true / break !v` (Vec),
  then `!v.push(2)` while `w` is used. prod rejects (correct: "use of
  `v` while a write loan is live"); oracle accepts ("stricter ... prod=
  reject ref=accept"). The oracle does not model a loan carried by a
  loop's break value. Not a soundness issue for prod.

## Hunt results by item

1. **Still silently read (should reject):** untyped loop value (High 1);
   `?!n` (High 2, also miscompiles); `+!n`, `<!n` in an `Int` slot
   (r16); operators/index/range/print (design notes). Everything else
   I tried is rejected: constructors (positional and keyword, explicit
   `Opt[Int]`, contextual `.some`), nested generics
   (`Opt.some(v: Opt.some(v: !n))`, `Opt[Opt[Int]]` expected), generic
   calls with one or two `!` args in either order, methods (`set`,
   `push`, `insert`, `Cell.set`), std (`math.max`, `math.sqrt`,
   `slices.contains`), function values and closures called with `!n`,
   `apply(f, !n)`, keyword args to defaulted params, closure result
   (`run(|!m| !m)`), `[3, !n]`, `[!n, !m, 3]`, `[!p, P(x:1)]`,
   `!arr.fill(!n)`, typed `Int?`/`Int`/parenthesized bindings,
   reassignment `k = !n`, `p.x = !n`, `arr[0] = !n`, `t += !n`, results
   `Int`, `Int?`, `Int!`, `return !x`, `catch !n`, untyped `if`/`match`/
   `??` with one `!n` leaf (r12), module-qualified calls (r22).
   (`[3 of !n]` and `if !c` were already rejected.)
2. **Valid forms:** none newly rejected. Accepted and correct: `!T`
   params (generic too), `?T` params (`read(!n)`, `rd[T](?T)`),
   `[!n, !m]` to `[2]!Int` and a typed `[2]!Int`, `!n if c else !m`,
   `G[!Int](r: !n)`, `g: G[!Int] = G(r: !m)`, `H(w: !n)` for a `!Int`
   field, `(!Int)?` param, `.some(v: !n)` to `Opt[!Int]`, write
   receivers, `!arr[0..2]` to `[]Int`, re-lend `inc(!x)` (v01, v02).
   `Opt.some(v: !p)` for a struct `P` that copies infers `Opt[!P]` and
   keeps the view (r02, prints `4 2`): inference uses `readValue`
   (scalars only), so the doc line "inference binds T to the value the
   view reaches" holds for scalars, not for every type that copies. Not
   a bug — the `!` is honored — but the owner may want the rule stated
   as "the reached value for a scalar, the view otherwise".
   **Sweep** (`rig check` over test/, examples/, std/, 9811 files, base
   vs branch, on the branch's tree): newly rejected are exactly
   `test/reject/ownership/ignored_write_lend.rig` (intended) and five
   corpus probes that are this very shape (`r3-review1-p40_generic_wview`,
   `r3-review1-p40b_generic_wview2`, `review-step1-p40_generic_wview`,
   `review-step1-p40b_generic_wview2`, `review-lang4-g3`). Corpus allows
   rejection, so the suite stays green. Plus the two files the branch
   edited (`write_view_copy_element.rig`, `hp31`), whose old forms are
   now rejected by design. No example or std file changes.
3. **One decider:** `recordAdapted` is the decider for checked slots,
   but these paths also read a write lend as a value without it:
   - the untyped binding's `readThrough(..., bindingValue)` for loop
     values (High 1);
   - `synthValue`/`readThrough`/`readValue` for operator operands,
     index, range bounds, `print` arguments;
   - `+`/`<` operands and `?!` (High 2);
   - inference's `bindArg` uses `readValue`, so whether `!x` becomes a
     rejected read or a kept view depends on the type (scalar vs
     struct), decided there, not in `recordAdapted`.
   Emit and ownership add no decider of their own for these: emit
   follows `recordRead`, ownership's lend kinds are unchanged, and no
   accepted program's Zig changed.
4. **Emitted Zig:** `rig emit` with base and branch on every file under
   test/behavior and test/corpus that the branch accepts (4766 files),
   plus examples and probes (204): 0 differences.
5. **Design notes** — see below.
6. **Oracle:** run on all 26 probes: 0 differences except r23 (Low 2).

## Design notes for the owner

- **`!n + 1`, `!n == 1`, `arr[!i]`, `0..!i`:** the `!` is ignored exactly
  as in `f(!n)`; the operand slot is a plain value. Not consistent with
  the decision's spirit. A consistent rule: a `!x` written directly
  (hands kind `lend`) is accepted only where the slot's type holds a
  write view (`!T`, a type containing one, or an inferred/untyped slot
  that then keeps it); everywhere a value is read — operands, index,
  bounds, `print`, `+`/`<`/`?` operands — it is rejected with the same
  diagnostic. A held view (`w`, `h.w`, a `!T` parameter) keeps reading
  silently (Core sentence 1), since no `!` is written there.
- **`print(!n)`:** same case. `print` reads a value; reject `!n` there by
  the same rule (it already differs from `print(w)` only by the
  written `!`).
- **`rd(!n)` with `rd(x: ?Int)`:** the `!` is narrowed to a read. Rust
  allows `&mut x` where `&T` goes, but in Rig the written sigil is the
  claim, and for a scalar `?Int` is passed by value, so `!n` here is
  exactly as ignored as in `f(!n)` (it also takes a stronger loan than
  needed). Consistent rule: same as above — a written `!x` meets only a
  slot that holds a write view; where `?T` goes, write `?x` (hint:
  "the call only reads `n`: write `rd(?n)`"). If the narrowing is kept
  on purpose, Core §4 should say so and say why it differs from `f(!n)`.
  `G[?Int](r: !n)` and `h: ?Int = !n` (d01) are the same case.
- **`+!n`, `<!n`, `?!n`:** each composes a write lend with an operator
  that only reads it; under the same rule all three are rejected, which
  also removes High 2's miscompile.
