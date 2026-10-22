# Audit: ct-sizes, front end (grammar, checker, diagnostics, docs)

Reviewer R8b, 2026-09-26. Diff: `git diff main..ct-sizes` (9976ff2, 3e5383a).
Compiler: the checked-in `bin/rig` (built from ct-sizes HEAD). A scratch build of
`main` was used to tell new behaviour from old.

Repros are in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R8b/repro/`
(called `repro/` below). Every finding was run twice, and the outputs quoted here are
from the second run.

## Findings

| # | Sev | Area | Summary | Repro | Suspected code |
|---|---|---|---|---|---|
| F1 | **High** | checker | Exponential module-constant folding while signatures resolve: the compiler hangs on a valid 24-line program | `repro/F1_hang_const_fold.rig`, `repro/F1_slow14.rig` | `src/resolve.zig:583-595` (`ConstNames.name`: no memo, depth cap 32) |
| F2 | **High** | diagnostics | A poisoned value argument leaks `invalid` into later messages: "`[invalid]Int` needs `invalid`", "expected `?Ring[Int, invalid]`" | `repro/F2_invalid_leak.rig` | `src/resolve.zig:1646-1649` (`any_bad` computed, instance still interned); `src/typecheck.zig:3032` |
| F3 | **High** | diagnostics | An out-of-range value argument to a type (`Ring[Int, -1]`, `Ring[Int, 5000000000]`) reports a false "`[0; 2]` has length `2`; `[-1]Int` needs `-1`" first, then the real error | `repro/F3_range_cascade.rig` | `src/resolve.zig:1424` (`.arg` checks only `intFits`); `src/typecheck.zig:3032` |
| F4 | **High** | diagnostics | `[0; 2.5]`, `[0; true]`, `[0; "x"]`, `[0; none]` say "use of unbound name `2.5`" | `repro/F4_fill_literal_kinds.rig` | `src/resolve.zig` `ctIntOf` (~1455-1462) |
| F5 | Medium | diagnostics | "compile-time arguments touch the name: `f[1, 2, 3](...)`" misfires on `f([1, 2, 3])` whenever `n` is not inferable, including right after a signature error | `repro/F5_touch_name.rig` | `src/typecheck.zig:3505-3515` |
| F6 | Medium | diagnostics | "cannot infer `T`/`n`" follows a bad array size (`[T]Int`, `a: [nope]Int = zeros()`) | `repro/F6_infer_cascade.rig` | inference-failure path in `instantiateCall` (typecheck.zig) |
| F7 | Medium | checker | Folding ignores a constant's declared type: (a) an alias-typed constant can't size an array in a signature; (b) `I8`/`Int` overflow is accepted in type-position sizes and args but rejected everywhere else; (c) `Ring[Int, N]` with `N: I8` is accepted in a type and rejected in an expression | `repro/F7a_alias_const.rig`, `repro/F7b_typed_const_fold.rig` vs `repro/F7b_same_exprs_rejected.rig`, `repro/F7c_typed_const_positions.rig` | `src/resolve.zig:593` (`isIntTypeName` on the alias's name); `src/sema.zig:2481-2537` (`constIntBy` in i128, untyped) |
| F8 | Medium | checker | A chain of more than 32 constants can't size an array in a signature ("`C33` is not" known at compile time) | `repro/F8_const_chain.rig` | `src/resolve.zig:591` (`depth > 32`) |
| F9 | Medium | diagnostics | "must be known at compile time; `X` is not" for a non-`pub` `lib.N`, a missing `lib.nope`, an unknown `nolib.X`, a type `lib.S`, and a Float or Bool constant (which *is* known) | `repro/F9_module_names/main.rig` | `src/resolve.zig:598-606` (`ConstNames.member` returns `.not_constant` for everything); `ctIntOf` fall-through |
| F10 | Medium | grammar | `[(A + B)]Int` and `Ring[Int, (A + B)]` don't parse ("unexpected `]`"). A conflict-free fix is below, and the suite is green with it | `repro/F10_paren_size.rig` | `rig.grammar` `cexp` |
| F11 | Medium | diagnostics | The Rust spelling `a: [Int; 3]` and a trailing `x = 1;` get a bare "unexpected `;`" with no hint | `repro/F11_rust_array.rig` | parser error hook in `src/rig.zig` |
| F12 | Low | grammar | `[-1]Int` gives "unexpected `-`", while `Ring[Int, -4]` and `[0; -1]` get range messages; `Ring[Int, -N]` gives "expected an integer" | `repro/F12_neg_size.rig` | `rig.grammar` `dim` |
| F13 | Low | diagnostics | `[N -1]Int`, `[N *2]Int`, and `Ring[Int, N *2]` give "unexpected `-`/`*`" without naming the spacing rule | `repro/F13_spacing.rig` | parser error hook |
| F14 | Low | diagnostics | Wording: "a `I8`" should be "an `I8`"; the `[Int]Int` message's list omits arithmetic, which the other message includes; "use a parameter" vs "pass a parameter" for the same mistake in a type and in an expression; `Ring[Int, f()]` lists the allowed forms without arithmetic | see body | `resolve.zig` / `typecheck.zig` messages |
| F15 | Low | diagnostics | A transitive `array_len` failure (`wrap[-2]()` → `zeros[-2]`) names `zeros[-2]` at the `wrap` call, with no note for the path | `test/reject/types/ct_array_len_range.rig:19` | `checkRequirements` |
| F16 | Low | docs | Claims no test checks, a stale test comment, and an undocumented rejection | see body | docs/tests |
| F17 | Low (pre-existing) | diagnostics | Two diagnostics for one mistake: `Ring[4, Int]` gets one per slot; `make(Vec[Int]())` over `[x; 3]` gets both "keeps in an array" and "copies a `T`", as `[x, x, x]` does on main | — | — |

---

### F1 (High): exponential folding, then a hang

`repro/F1_hang_const_fold.rig`:
```
C0 =! 1
C1 =! C0 + C0 - C0
... (up to C20)
fun f(xs: [C20]Int) -> Int
  xs.len
sub main()
  print(f([0; 1]))
```
```
$ gtimeout 20 bin/rig check F1_hang_const_fold.rig   → exit 124 after 20.00s
$ bin/rig check F1_slow14.rig   (same, 14 levels)     → 4.08s   (3^14 evaluations)
```
The same constants run in 1.1 s on both main and HEAD when they are used in a body
(`a: [C20]Int` in `main`) or as `show[C20]()`. There `const_ints` is already filled.
Only signature (and field) resolution folds through `ConstNames.name`. That function
re-folds each referenced declaration from source, with no cache, and gives up at
depth 32.
**Fix:** memoize results by `SymbolId` (a mutable cache on the resolver, or fill
`const_ints` from here). Better still, fold the module's `=!` constants once, in
declaration order, before signatures resolve. That also fixes F8.

### F2 (High): `invalid` in user-facing messages

```
F2_invalid_leak.rig:3:21: error: compile-time argument 2 of `Ring` is a value of type `Int`, not a type
F2_invalid_leak.rig:6:16: error: use of unbound name `nope`
F2_invalid_leak.rig:6:36: error: `[0; 2]` has length `2`; `[invalid]Int` needs `invalid`
F2_invalid_leak.rig:8:14: error: type mismatch: expected `?Ring[Int, invalid]`, got `?Ring[Int, 2]`
```
`resolveGenericInst` sets `any_bad` but still interns `Ring[Int, invalid]`. That type
is not `invalid_id`, so `isPoison` checks (identity only) let it through. It is also
reachable through `Ring[Int, lib.N]` when `N` isn't `pub`. The same root causes the
reported `?Box[invalid]` cascade. That one is pre-existing (`?Box[Nope]` does it on
main), but this branch adds many new ways to reach it (`Box[3]`, `Ring[Int, Int]`,
`Ring[Int, nope]`).
**Fix:** return `t.invalid_id` from `resolveGenericInst` when `any_bad`. Also, in
`checkArrayFill`'s final comparison, skip when `sema.containsPoison(ctx, ex)`.

### F3 (High): a false first error for an out-of-range value argument

```
F3_range_cascade.rig:4:28: error: `[0; 2]` has length `2`; `[-1]Int` needs `-1`
F3_range_cascade.rig:4:7: error: `Ring[Int, -1]` cannot use `n = -1`: the generic body uses `n` as an array length, which runs from 0 to 4294967295
F3_range_cascade.rig:2:11:   note: `n` used as an array length here
```
The first message shows a type, `[-1]Int`, that cannot exist, and it comes before
the real one. `test/reject/types/generic_value_param_args.rig:16` hides it: that test
passes `[0; 0]`, and the runner only checks that the expected errors are present.
**Fix:** substitution into `ArrayType.len` should give `invalid` for a `ct_value`
outside 0..max. Alternatively, `checkArrayFill`/`checkArray` can treat such an
expected length as poison. Then tighten the test so it would catch the extra
message.

### F4 (High): a non-integer size is called an unbound name

```
F4_fill_literal_kinds.rig:2:11: error: use of unbound name `2.5`
F4_fill_literal_kinds.rig:3:11: error: use of unbound name `true`
F4_fill_literal_kinds.rig:4:11: error: use of unbound name `"x"`
F4_fill_literal_kinds.rig:5:11: error: use of unbound name `none`
```
`ctIntOf` treats any `.src` leaf that isn't an integer literal as a name. **Fix:**
check that the leaf is an identifier first. Otherwise say "an array length is an
integer; `2.5` is a `Float`", as `zeros[2.5]()` already does ("expected `Int`, got
`Float`").

### F5 (Medium): the "touch the name" heuristic misfires

```
F5_touch_name.rig:3:20: error: an array length `n + 1` does arithmetic on a compile-time parameter, ...
F5_touch_name.rig:6:9: error: compile-time arguments touch the name: `f[1, 2, 3](...)`
F5_touch_name.rig:6:23: error: compile-time arguments touch the name: `g[1, 2](...)`
```
The heuristic predates this branch. It fires when the single argument is an array
literal and `n` must be given in brackets. Array-literal arguments are now the normal
way to call `sum([1, 2, 3])`, so it misfires whenever `n` can't be inferred: `n: Bool`
used as a size, `[n + 1]`, or a parameter typed `[3]Int`. The `g` line is also a
cascade.
**Fix:** use the hint only when the function takes no run-time parameters
(`f.params.len == skip`). Suppress it when any parameter type is poison.

### F6 (Medium): an inference cascade after a bad size

```
F6_infer_cascade.rig:1:15: error: `T` is a type; an array length is an integer, a constant, or a compile-time parameter
F6_infer_cascade.rig:6:7: error: use of unbound name `nope`
F6_infer_cascade.rig:6:18: error: cannot infer `n` for `zeros` from its arguments or the type expected of its result; ...
F6_infer_cascade.rig:7:9: error: cannot infer `T` for `f` from its arguments or the type expected of its result; ...
```
**Fix:** don't report an inference failure when a parameter type, or the expected
type, is poisoned.

### F7 (Medium): folding ignores a constant's type

(a) `repro/F7a_alias_const.rig` (`type Size = Int`, `N: Size =! 4`, `fun f(xs: [N]Int)`):
```
F7a_alias_const.rig:3:12: error: an array length must be known at compile time; `N` is not: ...
```
The same `[N]Int` in a body works. `ConstNames.name` checks
`isIntTypeName(identAt(ty))`, and an alias's name is not an integer type's name.
This is the reported gap. The message is also misleading, since `N` is known at
compile time.

(b) `repro/F7b_typed_const_fold.rig` (`N: I8 =! 100`, `A =! 9223372036854775807`)
runs and prints `200 200 1` for `[N + N]Int`, `Ring[Int, N + N]`, and
`[A + 1 - A]Int`. The same expressions as constants
(`repro/F7b_same_exprs_rejected.rig`) are rejected:
```
error: integer value `200` does not fit in `I8` (-128..127)
error: integer value `9223372036854775808` does not fit in `Int` (...)
```
So are `Ring[Int, N + N](...)` and `zeros[N + N]()`. SPEC §17 says compile-time
arithmetic "is checked like constant arithmetic".

(c) `repro/F7c_typed_const_positions.rig`: `r: Ring[Int, N]` is accepted, but
`s = Ring[Int, N](...)` fails with "type mismatch: expected `Int`, got `I8`". The
same type is accepted spelled one way and rejected spelled the other.

**Fix:** have `resolveCtInt` fold with the checker's typed constant arithmetic:
resolve the declared type, alias included, then check each intermediate result and
the result against it. Also require the result's type to equal the parameter's
type, as the expression path does.

### F8 (Medium): a chain deeper than 32 constants

`repro/F8_const_chain.rig` (C0..C33, each `Ci =! Ci-1 + 1`):
```
F8_const_chain.rig:35:12: error: an array length must be known at compile time; `C33` is not: ...
```
The same fix as F1 applies.

### F9 (Medium): misleading "not known at compile time"

`repro/F9_module_names/main.rig`: every line below gets "an array length must be
known at compile time; `X` is not". The message each one should get:
- `lib.N` (not `pub`) should say "`lib.N` is not public; mark it `pub`", as a value
  use does.
- `lib.nope` should say the module has no `nope`.
- `nolib.X` should say "use of unbound name `nolib`".
- `lib.S` (a type) should say "`lib.S` is a type".
- `lib.F` (a Float) should say "an array length is an integer; `lib.F` is a `Float`".

The local Float case gets the same misleading message, and
`test/reject/types/ct_array_len_not_constant.rig:14` locks it in ("`HALF` is not"),
so that expectation should change as well.

### F10 (Medium): a parenthesized size. Fix verified

`repro/F10_paren_size.rig`: `F10_paren_size.rig:6:14: error: unexpected `]``.
The fix is one rule:
```diff
 cexp     = cmulop
          | caddop
+         | "(" cexp ")"                             → 2
```
`nexus check` reports no conflicts. As a control, adding `"(" dim ")"` to `dim`
instead gives a shift/reduce conflict, and Nexus reports it. I regenerated
`src/parser.zig` in a scratch copy (`R8b/head`) and rebuilt. There,
`[(A + B)]`, `[((A + B))]`, `[((A + B)) * 2]`, `[A * (B + 1)]`,
`Ring[Int, (A + B)]`, and `Ring[(Int), (A * B)]` all run correctly, and the full
`./test/run` gives **1324 passed, 0 failed, 0 known**, parser check and IR snapshots
included.

Optionally, `(4)` and `(N)` could parse too (`Ring[Int, (4)]` and `[(N)]Int` fail
today). Adding `"(" INTEGER ")" → 2` to `targ`, and `"(" INTEGER ")" → 2` and
`"(" name ")" → 2` to `dim`, is also conflict-free (checked with `nexus check`, not
built). With the fix, SYNTAX appendix C's `cexp` line should gain `| "(" cexp ")"`.

### F11 (Medium): Rust spellings get no hint

```
F11_rust_array.rig:2:10: error: unexpected `;`        (a: [Int; 3])
```
`x = 1;` also gives a bare "unexpected `;`". On main it said "invalid character".
SYNTAX is written for Rust programmers, and they will type `[i64; N]`. **Fix:** when
`;` follows a type inside `[`, say "an array type is `[3]Int`; `[x; n]` is a fill
literal". For a statement-final `;`, say "Rig has no `;` between statements".

### F12 / F13 (Low)
- `a: [-1]Int` gives `2:7: error: unexpected `-``. Adding
  `MINUS_PREFIX operand:INTEGER → (neg)` to `dim` is conflict-free (checked with
  `nexus check`), and then the range message applies. `Ring[Int, -N]` gives
  "unexpected name `N`; expected an integer".
- `[N -1]Int` and `[N *2]Int` give "unexpected `-`" and "unexpected `*`". These
  follow from the spacing rule, but the message doesn't mention it. The expression
  side at least says "`N` ... cannot be called".

### F14 (Low): wording
- "which a `I8` cannot hold" should be "an `I8`".
- "`Int` is a type; an array length is an integer, a constant, or a compile-time
  parameter" omits arithmetic, which the other message includes.
- A type and an expression use different messages for the same arithmetic on a
  parameter: "a compile-time argument `n * 2` does arithmetic … use a parameter"
  versus "compile-time argument 2 of `Ring` does arithmetic … pass a parameter".
- `Ring[Int, f()](...)`: "pass a literal, an enum value, a module constant, …"
  leaves out arithmetic, which is allowed.

### F16 (Low): docs
- SPEC §17 says the naming rules hold "for a generic type's value parameters" too.
  The behaviour is right: `struct R[T, Int: Int]`, a clash with a module declaration,
  a duplicate, a method named `n`, and a local or parameter named `n` are all
  rejected. No test covers any of them.
- SYNTAX §14 Limits says a size may "not call a function". `[0; f()]` is rejected,
  but no test covers it, and the message doesn't mention functions.
- A method of a `pub` struct whose value parameter sizes an array is rejected
  ("public method `zeros` sizes an array …"). SPEC, SYNTAX, and INTERNALS say only
  "public function", and no test covers methods.
- Stale comment: `test/reject/types/generic_fn_explicit_arity.rig:3` still says
  "since a value is never inferred".

---

## Attacks that came up clean

**Lexing and grammar**
- `;` in strings (`"a;b"`, `'x;'`) and in comments.
- `[1;3]`, `[2 ; 3]`, a newline after `;`, and a newline before `;`, all inside brackets.
- `[;]`, `[1;]`, `[;3]`, `[1; 2; 3]`, `[1, 2; 3]`, `[0; 3,]`: each gets one clear parse error.
- `[N-1]`, `[N*2]`, and `[2 + 3 * 4]` give 14, `%`, `/`, left associativity (`10 - 2 - 3`, `24 / 4 / 2`), and `(2 + 3) * 4`.
- Folded `/` and `%` on negative constants match run-time `/` and `%`.
- `Ring[(Int), 4]` and `Box[[N * 2]Int]`.
- `print [0; 3]` (a paren-free call), `for x in [7; 3]`, and `[0; N if N > 2 else 1]`.
- The closure bar list with sizes (`|xs: [L - 1]Int, r: ?Ring[Int, L % 3]|`, `[(L / 2) * 3]`).
- Deep nesting (50k-term sums, 5k parentheses): the "nested too deeply" diagnostics fire and nothing crashes.
- **Fuzzing:** 1,200 mutants checked only, then 1,400 more checked and, when accepted, run. The mutations were brackets, `;`, operators, and the tokens `n`, `[0; n]`, `4294967296`, and 23-digit integers, applied to the 13 new tests. No crash, hang, or exit other than 0/1. No error without `file:line:col`, and no `invalid` in the output. One run segfaulted, but that mutant was user-level infinite recursion.

**Checker**
- Inference works from `[n][2]`, `[3][m]`, `[n][m]`, `?[n]T`, `![n]T`, `[n]Int?`, `([n]Int)?`, `?Ring[T, n]`, and `Ring[Int, n]`.
- A slice isn't inferred from. `?v[0..2]` against `?[n]Int` is a mismatch.
- Conflicts are named with both arguments (`[n]` against `?Ring[Int, n]`, and `[n][n]`).
- An explicit size that disagrees gives one precise error (`len[3]([1, 2])`, `a: [3]Int = zeros[4]()`, `Ring[Int, 3]` with two items).
- Fit errors for `U8`, `I8`, and `U64`.
- The `array_len` requirement's message and note, called directly and through a generic enum `Slot[-1]`.
- A constant defined after its use folds, in a signature and in a body.
- Alias-typed constants fold in bodies. `type R = [T]Int` works with `T =! 3` declared after it.
- `new N = 10` shadowing a constant is rejected as a size. `N = 10` is "cannot reassign".
- Value parameters in the type's methods, in `fun new(x: T) -> Ring[T, n]`, and in `Ring.make(5)` with an expected type.
- **`pub` fixpoint.** No false positives: the parameter passed to a type whose value parameter sizes nothing, used as an element (`[n; 3]`), or used as an index. No false negatives: sizing through a private function, `k =! n`, a non-generic type's method, a generic type's method with its own parameter, a type's value parameter used in a method body, and a function's return type (`mk[n]()` → `Tag[m]`). Another module's `lib.Ring[Int, -3]` is rejected as a cross-module generic type.
- Symbolic index out of bounds panics at run time. A constant index into a `[LIMIT]Int` is rejected.

**Docs**
- Nothing still says "compile-time values are never inferred" (SPEC now says "any other compile-time value is never inferred") or "`type Ring[n: Int]` is rejected".
- No `[x, ..]` anywhere in SPEC, SYNTAX, docs, examples, tests, or `src`.
- The ROADMAP items were removed or rewritten.
- The claims in SPEC Arrays, Generic types, Generic functions, §17, and §19, SYNTAX §4/§14/§22 and appendices A/B/C/D, the INTERNALS generics and emit paragraphs, and `examples/generics.rig` all check out by program.
- The emitted Zig matches the docs: `Ring(i64, 4)`, `comptime n: i64`, and `@as([n]T, @splat(x))`.
- All doc examples pass in the suite.
