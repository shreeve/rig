# Audit: `main..followups` (nested arrays, borrowed operands, expected-type inference)

Reviewer: independent adversarial pass (R7). Branch `followups` at 9ccfeb4, compared
against `main` at bb8f608 built in a scratch worktree. `bin/rig` was built before
54023dc, whose `src/` change is comments only, so it matches HEAD.

Repros are in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R7/find/`
(written `find/<file>` below). Each repro was run twice with `bin/rig check` and
`bin/rig run` on the branch, and once on `main`, with `RIG_OUT_DIR=<scratch>/R7/out`.

## Summary

- **New regression (High):** a generic body can now apply a compound assignment
  whose right side is a call that yields `!T`, such as `a += wr(!b)`. Sema accepts
  it, but the Zig it emits adds a pointer, so the Zig does not compile. `main`
  rejected this in sema.
- **Incomplete fix (High, also on `main`):** commit ce4c8dd fixes `wr(!x) + 1`. It
  does not fix `not`, `and`/`or`, `??`, String `==`/`!=`, compound right sides, or
  any value position (binding, argument, index, range, conversion, condition,
  `if … as`). In all of these, a call yielding `!T` emits a pointer where Zig wants
  a value.
- **Nested arrays:** clean. Nothing went wrong in any position I tried.
- **Borrowed operands with a named `?T`/`!T` parameter:** clean for every operator.
- **Expected-type inference:** correct and leak-free for every direct case. Nested
  cases are weaker: a nested variant or associated-function call, a nested call
  under `!`, or a nested call that returns `T?` does not re-bind to the outer
  type, and the resulting diagnostics are misleading. SPEC claims that nested
  re-binding works in general.
- **Performance:** no exponential re-checking. Check time grows quadratically with
  nesting depth, the same as on `main`, and wide argument lists are linear.

## Findings

| ID | Severity | Repro path | What happens | Expected | Suspected cause (file:line) | Fix idea |
|---|---|---|---|---|---|---|
| F1 | **High** (new regression) | `find/f1_generic_compound_wr.rig`, `find/f1b_generic_compound_shift_div.rig` | In a generic body, `a += wr(!b)` (and `<<=`, `/=`, `%=` with a call yielding `!T` on the right) passes `rig check` and emits `a.* += wr(T, b);` or `@shlExact(a.*, @intCast(wr(T, c)))`. Zig fails: `expected type 'i64', found '*i64'`. `main` rejected this: "type mismatch: expected `T`, got `!T`". | The emitted Zig compiles and reads through the borrow, or sema rejects the program. | `src/typecheck.zig:713` now uses `operandValue` for a compound right side, so `!T` is admitted as `T`. `src/emit.zig:1223` and `:1231` (`emitCompound`) still call `emitBare(value)`, not the new `emitOperand`. | Use `emitOperand(value, true)` in `emitCompound`, in both the builtin branch and the plain branch. Add `a += wr(!b)`, `a <<= wr(!b)` and `a /= wr(!b)` to `generic_fn_borrowed_operands.rig`. |
| F2 | **High** (also on `main`; in the scope of ce4c8dd) | `find/f2a_ops_missed.rig` (`not wb(!b)`), `find/f2b_string_eq.rig` (`ws(!s) == "hi"`), `find/f2c_and.rig` (`wb(!b) and true`), `find/f2d_coalesce.rig` (`wo(!o) ?? 1`), `find/f2e_value_positions.rig` (`take(wr(!y))`), `find/f2f_binding.rig` (`z: Int = wr(!y)`), `find/f2g_compound_nongeneric.rig` (`x += wr(!y)`), `find/f2h_condition.rig` (`if wb(!b)`) | Each passes `rig check`, and the Zig does not compile (`expected type 'bool', found '*bool'`, `expected optional type, found '*?i64'`, and so on). The same failure occurs for `a[wr(!y)]`, `0..wr(!y)`, `Float(wr(!y))`, `x <<= wr(!z)`, `while wb(!b)`, `if wo(!o) as v`, `ws(!s)[0]`, and `x = wb(!b)` followed by `not x`. The commit message says operators on "an expression that yields a borrow" are fixed, but only arithmetic, comparison, bitwise and shift operands, and unary `-`, go through `emitOperand`. | Every accepted read of a `!T` a call yields (T a Copy type) dereferences it, or sema rejects it. | Sema: `readValue` (`src/typecheck.zig:5159`) makes `!T` of a Copy type compatible with `T` in every position. Emit dereferences only in `emitOperand` (`src/emit.zig:2347`). Unfixed sites: `.not` at `src/emit.zig:2202`; `and`/`or` at `:2211` and `:2213`; `??` left at `:2236`; String equality at `:2318` and `:2320`; compound right side at `:1223` and `:1231`; and generic value coercion in checkExpr/emitValue. | Record an adaptation in `checkExpr` (or `recordAdapted`) whenever a pointer-held borrow of a Copy value is used where the value is expected, and dereference it in `emitValue`. Short of that, route `not`, `and`/`or`, `??` left, the String `==` path and `emitCompound` through `emitOperand`. Add a behavior test for each position. |
| F3 | Medium (docs overclaim; wrong reject) | `find/f3a_nested_assoc.rig` (`c: Box[Box[U8]] = Box.make(Box.make(1))`), `find/f3b_nested_variant.rig` (`Opt.some(value: Opt.some(value: 1))` as `Opt[Opt[U8]]`; `id(Opt.some(value: 1))` as `Opt[U8]`), `find/f3c_nested_propagate.rig` (`z: U8 = max(parse(true, 1)!, 2)`) | Each is rejected: "expected `Box[Box[U8]]`, got `Box[Box[Int]]`". For f3c the error says "`max` takes `T = Int` from argument 1; convert its result…", but argument 1 is itself literal-only. `a: U8 = parse(true, 1)!` on its own is accepted. | SPEC §Generic functions says "a generic call that is an argument of another takes the type that call gives it". That should hold for associated functions, variants, and calls under `!`/`?`/`catch`, or the SPEC should narrow the claim. | Re-binding from a literal result happens only when the declared result is a bare type parameter (`src/typecheck.zig:3702`). `argType` looks up `literal_results` by the argument node itself (`:3617`), not by `resultCall(arg)`, so a call under `!` never matches. Variants and associated functions do not go through `noteResultBinding` at all. | Key `literal_results` by `resultCall(arg)`. Extend it to results shaped like `Box[T]` or `Opt[T]`: treat such an argument as "literal-shaped", bind the outer parameter from the other sources, then re-check the argument with that type. Otherwise, reword SPEC to "a generic function call whose result is its type parameter". |
| F4 | Medium (wrong reject; bad diagnostic) | `find/f4a_nested_optional.rig` (`z: Int? = id(nothing())`), `find/f4b_nested_none.rig` (`z: Int? = id(id(none))`) | f4a: "type mismatch: expected `Int`, got `Int?`", although the user wrote `Int?`. f4b: "`none` needs an optional type; `Int` is not optional (write `Int?`)", although it is written `Int?`. `id(none)` and `nothing()` each work alone. `z: Int? = id(opt(none))` fails the same way. | `id[Int?]`, with the inner call checked against `Int?`. | The outer `id` lifts the expected `Int?` to `Int` (`resultMatch`, `src/typecheck.zig:3552`; used in `bindExpected`, `:3572`), because a nested generic call gives no tentative type. The lifted binding is then pushed into the inner call as its expected type. | When an argument that fills the parameter is an unresolved generic call whose declared result is optional (or `none` at any depth), use the exact binding, as `b.none` already does. At minimum, name the lifted type in the diagnostic. |
| F5 | Low (hint suggests code that does not compile) | `find/f5_hint_array_brackets.rig`, and following the hint: `find/f5_followed_hint.rig` | The hint is "give `U` in brackets: `pair[[2][2]Int, ...](...)`". Writing it (`pair[[2][2]Int, Int](g)`) is rejected: "a slice or array type has no expression spelling". The same happens with `[2]Int` on `main`; nested arrays make it more common. The `...` placeholder is also not valid code. | A hint that works: `q: Vec[Int] = pair(g)` now compiles, thanks to this branch. | `bracketHint` (`src/typecheck.zig`, used at the "cannot infer" and "conflicting types" errors in `inferCallTypeArgs`) prints any type. | When a shown type has no expression spelling, or when the missing parameter appears in the result, suggest annotating where the value goes (`x: Vec[...] = pair(...)`), as the constructor diagnostic already does. |
| F6 | Low (cascade; also on `main`) | `find/f6_poison_cascade.rig` (`z: Vec[Foo] = empty()` with `Foo` unbound) | A second error follows: "cannot infer `T` for `empty` from its arguments or the type expected of its result". The expected type was given, only misspelled. Also `id(id(id(empty())))` gives 4 errors, with the root cause last. | Only "use of unbound type `Foo`". | `bindExpected` skips a poisoned expected type silently, so the call reports that it cannot infer. | When the expected type contains `invalid`, mark the parameter poisoned and suppress the diagnostic. |
| F7 | Low (docs imprecise; wrong reject; also on `main`) | `find/f7_closure_return.rig` | In a closure with an inferred result, `return x` (`x: U8`) followed by `return max(3, 4)` gives "this closure returns `U8`, but this `return` gives `Int`", while `return 3` there is accepted. SPEC lists `return` among the places whose type is expected. | `max[U8]`, or a SPEC restricted to function returns and annotated closure results. | Closure `return`s are synthesized, then reconciled (`reconcileReturns`, `src/typecheck.zig` ~5030). No expected type flows into them. | Reword SPEC, or check later `return` values against the result type once it is known. |
| F8 | Low (docs accuracy) | n/a (DESIGN rationale) | DESIGN "Closures are not generic" says "the languages that have them (Swift, TypeScript) box or erase their closures". Swift closure expressions cannot be generic. C++14 generic lambdas exist and are monomorphized with no boxing, which weakens the cost-model argument. | An accurate rationale. | `docs/DESIGN.md` §Closures are not generic | Drop Swift. Cite C++ generic lambdas and say why they still do not fit: a template per use, and the call-only rule. |
| F9 | Low (misleading diagnostic; also on `main`) | `find/f9_string_eq_generic.rig` | `same[String]` reports "the generic body applies `==` to `T`, which `String` does not support", but SPEC says `==` compares Strings by content, and `"a" == "a"` works. The same message appears for `T = Int?`. | Support String and optional `==` in generic bodies, or reword to "`==` on a `T` needs a number, `Bool`, or plain enum". | Requirement check for `==` on a type parameter. | Reword the requirement message, or lower `==` on `T` through a runtime helper that handles slices and optionals. |
| F10 | Info (a semantic surprise the docs describe) | `find/f10_sibling_literal.rig` | Prints `3 3.5 3`. `half(7)` is 3, but `max(half(7), 2.5)` is 3.5, because the float sibling makes the inner integer division a float division. `f: Float = half(7)` is also 3.5. `main` rejected all of these, so no accepted program changed meaning. | This follows the documented rule, and matches `h: Float = 7 / 2` being 3.5. | n/a | Consider an example in SYNTAX §14 so the change of division is visible. |
| F11 | High (also on `main`; outside this diff) | `find/f12_catch_vec.rig` (`v = h(false) catch Vec()`, with `h` returning `Vec[U8]!`) | Passes `rig check`; the emitted Zig is `h(false) catch .empty`, which fails: "incompatible types: 'rig.runtime.Vec(u8)' and '@EnumLiteral()'". The same happens for a generic `g(false, 3) catch Vec()`. `v: Vec[U8] = … catch Vec()` works. | The handler takes the caught expression's value type, or sema asks for an annotation. | The emitter writes `Vec()` as `.empty` without a result type when the binding is not annotated. | Emit the typed constructor (`Vec(u8).empty`) when the context gives no result type. |

### Smaller issues found on the way, also on `main`, outside this diff

- `r = wr(!x)` followed by `r += 1` reports "`r` is assigned but never read", although the write goes through the borrow.
- A `!Int` field cannot be written: `v.w += 1` gives "`+=` requires a numeric target; this place has type `!Int`".
- `s: []Int = []` and `g: [2][]Int = [[], []]` say "an empty array literal needs a type annotation (`xs: [0]Int = []`)", even though the binding is annotated.
- `H: [2]U8 =! G`, with `G` an earlier constant, is rejected with "a module-level constant needs … an earlier constant".
- `z: U8 = max(n, 2)!` reports "`!` needs a fallible operand" and then a second type mismatch. The branch did improve the second message, which now has a working conversion hint.
- `K: U8 = max(1, 2)` at module level reports "write `K =! value`", then "`K` is used before it has a value" at each use.

## Attacks that came up clean

**Nested array types** (repros `na1`–`na6.rig`, `sl1`–`sl9.rig`, `df3.rig`, `mod1/`)
- Positions tried: parameters (`g: [2][3]Int`, `?[2][3]Int`, `![2][3]Int`), fields, returns, `type` aliases (`Grid`, `G2 = [3]Row`), module constants, fields in another module, and `fun([2][2]Int) -> [2][2]Int`.
- Wrappers tried: `([2][2]Int)?`, `*[2][2]Int`, `[2][2]Int?` (optional elements, since suffixes bind tighter), `Box[[2][3]Int]`, `[2][2]Box[Int]`, and `[2][2]P` with struct elements.
- Generic inference into nested arrays works: `ident(g)`, `firstn`, and `zeros[T] -> [2][2]T` with expected `[2][2]U8` and `[2][2]Float`.
- Indexing and writes work: `g[1][2] = 9`, `g[0] = row`, `g[0][1] += 5`, `g[i][i] = 0`, and writes through `!self` (`self.cells[r][c] = v`, `self.cells[1] = row`, `self.cells[0][0] += 100`).
- Copies are value copies (`h = g`, then `h[0][0] = 9` leaves `g` unchanged); `h[0] = g[1]` works; `r = !g[0]` writes through.
- Iteration and slicing work: `for` over rows, over `?g`, and with an index; `?g[0..1]`, `?g[1][0..2]`, and `[][2]Int` parameters.
- Printing works (including `[2][3]U8`, `[0][3]Int`, `[2][0]Int`, `[1][1][1][1][1]Int`), and so does `@sizeOf`.
- Rejected with good diagnostics: element count mismatches at either level, U8 overflow in an inner literal, a constant index out of bounds, `[2][2]Vec[Int]` (both levels reported), `[2][2]Int!`, ragged `[[1, 2], [3]]`, and `Vec[[2][3]Int]`.
- Arrays of slices (`[2][]Int`) keep correct borrow tracking: returning one or a struct holding one, dropping or mutating the source while it lives, and a source in an inner scope are all rejected.
- `[2] [3]Int` with a space still parses. Expression indexing is unchanged (`[[1, 2], [3, 4]][1][0]`).
- Regenerating the parser with Nexus reproduces `src/parser.zig` byte for byte, with no conflicts.

**Borrowed operands in generic bodies** (`bo1`–`bo9`, `bs1`–`bs6`, `tb1`–`tb3`, `go1`, `ca3`, `pe1`–`pe3`, `bf1`)
- `/`, `%`, `/=`, `<<=`, `>>=` and `-a` on negative Int and Float values match the non-generic results (truncating division).
- Borrowed-operand calls agree with non-borrowed ones, including calls yielding `?T`/`!T` inside generic bodies (`wr(!c) + rd(a)` and every operator in `go1.rig`).
- Runtime overflow panics as specified: U8 via `+=` on `!T`, `-` on U8, `<<=` losing bits, `<<=` by 9 at runtime.
- Constant checks are recorded per instance: U8 negation, literal 300 beside a `?T`, and a constant shift by 9.
- Equality works for Bool and plain enums. Aliasing is rejected: `addto(!x, ?x)` and `md(?f, !f)`.
- `a += b` on a `?T` target is rejected. Types without the operation are rejected at the call with a note: String, `*N`, `Int?`, `[2]Int`, payload enums, owning enums.
- `T` bound to a borrow (`add(?x, ?y)` with `a: T`) works, as does re-borrowing a `?T` through another generic call.
- Non-generic borrow-yielding operands work for arithmetic, comparison, bitwise, shifts, float and U8 values, `(rd(?x))`, `rd(?y) if c else …`, `match`, method calls returning `?Int`, and borrow fields (`v.r + 1`, `-v.w`).

**Expected-type inference** (`et1`, `et2`, `rs1`, `rs2`, `pn`, `sh1`, `ov1`, `pre3`–`pre13` probes, `lv`, `cl5`, `hint`, `df`)
- Expected type is used in: typed bindings; parameters, including keyword arguments and defaults; methods; functions in another module; fields; assigned places (`h.n =`, `arr[0] =`, `v[0] =`, `u +=`); `return`; a function's last expression; `if`/`match` arms; `for … break` values; parentheses; array literal elements; annotated closure results.
- Result shapes tried: `T?`, `T!`, `*T`, `Vec[T]`, `[3]T`, `[2][2]T`, `Vec[T]!`.
- Through wrappers: `!`, `?`, `catch` (left side, and right side: `h() catch empty()`), `??` (left side, right side, and chains like `x: U8 = some(1) ?? nothing() ?? 4`).
- `none` arguments with an expected optional: `two(none, 3)`, `wrap(none)` as `Vec[Int?]`, `opt(none)`, `opt(id(none))`.
- Owning results are leak-free: `Vec[*R]` with drop glue through `!` and `catch`, `*Vec[*R]`, `Box.new()`, `pick2(empty(), one(*R))`, `Opt[Vec[*R]]`, `sh()`. All drops run with no leaks.
- When `T` is driven to a type the body cannot handle, it is rejected at the call: `max[Bool]` via `x: T = max(1, 2)` in a generic body, `max[U8?]`, `max[[2]Int]`, and literal 300 or -1 into U8.
- Runtime overflow for `z: I32 = sq(100000)` panics, as specified.
- Requirement checks survive the tentative pass: `max(p, q)` on a struct is reported inside `id(...)`, `id(id(...))`, `Box(v: …)`, variants, `if` arms, `two(...)`, `fk(p) catch p`, and in closures and owned closures used as arguments.
- Semantics against `main`: every program that `main` accepted and I tried gives the same output (`z: Int? = half(7)`, `z: Float = third(1.0)`, `sq(100000)`, `Box(v: max(1, 2))`, `Pair(first: max(1, 2), second: s)`). Only programs `main` rejected changed.
- The conversion hints compile: `U8(max(n, 2))` into `U8?`, `Int(max(f, 2.0))`, `F32(...)`, `Float(...)`, `I32(id(n))`.

**Performance** (`gen.py`, `gen2.py`, `w_*.rig`)
- Chains up to depth 200–400 check in under 1 s, growing quadratically; `main` takes the same time at the same depth.
- Nested `if`, arrays, `??` chains, boxes and variants at depth 20 each take 0.01 s.
- Wide calls with 800 arguments, each a nested literal-only generic call, take 0.09 s.

**Docs**
- These run and match their claims: SPEC Arrays (`grid[1][2]` printing 6); SPEC Generic functions (the example and its errors, the claims about lifting into `T?`/`T!`, propagated and caught `T!`, and the `??` left side); SPEC Generic bodies; SYNTAX §14 (all examples; emitted code confirms `max(max(1, 2), small)` is `max(u8, max(u8, 1, 2), small)`); SYNTAX §22.
- DESIGN: a closure in a generic function may use `T`, per instance (`cl1`, `cl3`); a requirement inside a closure body is recorded (`big[P]` is rejected).
- INTERNALS: `result_expected`, `tentative`, `literal_results` and `bindExpected` match the code; the new table row matches the grammar.
- ROADMAP: `[n]Int` with a compile-time `n` is still rejected ("expected `]` or an integer"); `[T: P]` is rejected today (so "kept free" holds).
- The exceptions are F3, F7 and F8.
