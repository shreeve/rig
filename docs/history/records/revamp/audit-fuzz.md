# Generative fuzz audit: accept means correct (branch `revamp`, base 5f2bdbc)

Compiler: `bin/rig` built from 5f2bdbc (`zig build`, Debug). No tracked file was changed.
Workspace: `/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/audit-fuzz`
(generators `gen_*.py`, harness `harness.py`, case packer `casepack.py`/`split.py`,
parser fuzzer `fuzz_parse.py`, programs and results under `c/<area>/`, minimal repros under `min/`).

Harness contract: `rig check`; if accepted, `rig run` (Debug, leak-checked). Outcomes: accepted-and-correct
(stdout equal to the generator's model, or the ownership oracle holds), rejected with a `file:line:col`
diagnostic (fine), or a finding: Zig compile error, internal error, compiler crash, wrong output, missing
panic, leak or double free. The ownership oracle (`own_oracle` in `harness.py`): every resource printed
`new N` is released (`rel N`) exactly as many times as it was created, never while not live, and never
used (`use N`) while not live.

## Findings (most severe first)

| ID | category | severity | minimal repro (under `min/`) | command | actual vs expected | suspected location |
|---|---|---|---|---|---|---|
| F02 | accepted, undefined behavior / wrong output | high | `F02_nan_to_int.rig` | `bin/rig run min/F02_nan_to_int.rig` | Converting a NaN `Float` to any integer type does not panic. Prints `0 0 340282366920938463463374607431768211455 0` in Debug and `0 0 4342858646 0` from `rig build --release`: the value differs by build mode, so it is Zig illegal behavior that Zig's own safety check misses. SPEC §3 "Numeric conversions": a float whose integer part does not fit panics. Expected a panic (like `1e300`, which does panic with "integer part of floating point value out of bounds"). 24 of 24 NaN cases in `c/ovf`, every integer type. | `src/emit.zig`, the float-to-int conversion: it emits a bare `@intFromFloat(...)` (e.g. `@as(u128, @intFromFloat(x))`). Needs an explicit `std.math.isNan` check (or a range check written so NaN fails it) before `@intFromFloat`. |
| F01 | accepted, Zig compile error | high | `F01_ternary_literal_plus.rig` | `bin/rig run min/F01_ternary_literal_plus.rig` | `r: U8 = (1 if f else 2) + 1`: `rig check` accepts, and Zig fails with `expected type 'u8', found 'i64'` (emitted `const r: u8 = @as(i64, if (f) 1 else 2) + 1`). Any operator over a ternary whose branches are all literals, in a context that gives a non-`Int` type, fails: `+ - * / % +% << & `, unary `-`, compound `+=`, and every context (typed binding, argument, return, struct field, array element, `T?`, Vec push, Cell.set, enum payload, match arm, generic argument). For `F32`: `expected type 'f32', found 'f64'`; for `U128` with a big branch: `type 'i64' cannot represent integer value ...`; for `Float?` `??` fallback: `incompatible types: 'i64' and 'f64'`. 94 failing cases in `c/ctx_split` + `c/int`, one root cause. A bare ternary `r: U8 = (1 if f else 2)` and one with a typed operand (`v + (100 if f else 1)`) are correct. | `src/typecheck.zig` `adaptLiteral`/`recordAdapted` (≈1143, 6495): an all-literal ternary under a binary or unary operator adapts to the context type for checking, but the operator node and the ternary keep the `Int`/`Float` fact, and `src/emit.zig` (≈3030, arithmetic: `writeAsOpen(self.typeOf(sexp))`) emits that stale type. |
| F05 | compiler crash | high | `F05_crash_callable.rig` | `bin/rig check min/F05_crash_callable.rig` | `thread ... panic: access of union field 'function' while field 'shared' is active` at `sema.zig:2452` (`callableFn`), from `ownership.zig:2539` `keepsCallable` ← `walkCall`. Trigger: a stack closure literal bound to an owned-closure type (`inc: *fun(Int) -> Int = \|x\| x + 1`, which typecheck rejects correctly) then lent to a `?*fun(Int) -> Int` parameter (`apply(?inc, 1)`). Expected: the typecheck diagnostic, no crash. In a release build of `rig` this is a wrong union access (undefined behavior). Found by the mutation fuzzer (1 of 200 000 mutants; no other crash or hang in 240 000 `rig check` runs). | `src/sema.zig:2456` `callableFnTy` returns the `.callable` payload without checking that it is a `.function` (here it is `*fun`, a `.shared`), and `src/sema.zig:2452` `callableFn` then reads `.function`. Also: the ownership pass runs over a program typecheck already rejected. |
| F03 | accepted, Zig compile error | high | `F03_while_step_decl.rig` | `bin/rig run min/F03_while_step_decl.rig` | `while i < 3 : x = i` then `print(x)` in the body: accepted, though the step runs after the body and `x` is not declared before the body's first run. Zig: `use of undeclared identifier 'x'` (and `unused local constant`). With an owning value (`while i < 3 : b = *B(n: i)` and `b.n` in the body), the same. Expected: reject the use (or reject a declaring step). Found by mutating `test/behavior/*` (the `: step` resource test with its first `b = ...` deleted). | `src/typecheck.zig:1328-1336` `checkWhile`: the step is checked with `checkStmt(step)` in the loop scope *before* the body, so a binding the step declares is in scope for the body. |
| F04 | accepted, Zig compile error (and a missed rejection) | medium | `F04_write_receiver_string_get.rig` | `bin/rig run min/F04_write_receiver_string_get.rig` | `s = "hello"` / `print(!s.get(4))`: accepted; Zig: `rig/runtime.zig:422:38: error: type '*[]const u8' does not support indexing`. On an array, `!a.get(1)` is accepted and runs (prints `2`), though a `!` before a method that only reads is a rejection everywhere else (`!v.get(0)` on a Vec: "`get` does not write its receiver"; `!a.read[...]`: "`read` only reads its receiver"). | `src/typecheck.zig:5515` / `sequenceGet` (5806): the array/slice/String `get` path returns before any receiver-sigil check (`misplacedSigil` / `checkReceiverSigil`). |
| FR1 | false rejection, misleading message | low | `FR1_conversion_arg_literal_fit.rig` | `bin/rig check min/FR1_conversion_arg_literal_fit.rig` | `v = id(5)` (an `Int`), `U8(v + 300 - 300)`: rejected, `integer value 300 does not fit in U8`. The literals are `Int` operands (the argument is an `Int` expression); the emitted code would compute in `Int` and convert. Same for `U8(v ^ c)` with a typed local `c: Int = -1` ("`-1` does not fit in `U8`"), `U8(v % -3)`, `U8(v * -1)`. 8 of 300 `c/int` programs. | `src/typecheck.zig:4131` `checkConversion`: `checkLiteralFits(arg, target)` checks the literals inside a typed argument against the conversion target instead of the argument's type. |
| FR2 | false rejection, misleading message | low | `FR2/main.rig` (+ `FR2/util.rig`) | `bin/rig check min/FR2/main.rig` | `util.Byte.max` with `pub type Byte = U8` in `util`: "type `U8` has no field `max`". `Byte.max` works in the same module, and `U8.max` works everywhere; SPEC §3 says limits are named "through the type or an alias of it". | The `T.min`/`T.max` lookup for an alias reached through a module (`mod.Alias.max`), in the resolver or typecheck member access. |

Not findings (checked): all 1 185 runtime-check cases in `c/ovf` other than NaN panic with the right
message (integer overflow, division by zero, `min / -1`, left shift losing bits, out-of-range shift amount,
narrowing conversion, float out of range, index/slice/byte-read bounds); every all-constant variant (67) is
rejected at compile time. `Int.min % -1` prints `0`. Stack overflow from unbounded recursion in two mutants
is not counted (no language guarantee).

## Coverage summary

Programs are small but dense; packed programs hold 12-15 independent cases, and failing packs were split
case by case (`split.py`).

| Area (generator) | programs run | cases | outcome |
|---|---|---|---|
| Integer expression trees, all widths incl. U128/I128: `+ - * / %`, wrapping ops, bitwise, shifts with any-typed amounts, unary minus, conversions between all types, `T.min/max`, module/local constants, array elements, ternaries, compound assignment chains (`gen_int.py`) | 300 | ~1 650 results | 290 ok; 1 Zig error (F01); 8 rejected (FR1, or generator's literal-only `Int` subtrees); 1 generator bug |
| Feature snippets: int match (literals, ranges, alternatives, guards), enums (payloads, methods, `match !e`, `==`, values), structs (defaults, `?self/!self/<self`, `==`), optionals (`?`, `??`, `?? return`, `if a as x and ...`, `<p.f` take), errors (`!`, `catch`, `catch \|e\|` blocks, defer/errdefer order), closures (owned, stack, `?fun`, captures), generics (`[T]`, `[n: Int]`, generic enum/struct), Vec, Cell[Vec], drops and handles, strings/slices/bytes, loops, Box lists and trees, Signal, keyword/default args (`gen_feat.py`) | 200 | ~2 700 lines | all correct (11 early mismatches were a model bug) |
| Expression form × context matrix (22 forms × 24 contexts, 12 numeric types) (`gen_ctx.py`) | 483 (+883 split) | 8 000 checked, 6 817 accepted and run | 94 Zig errors, all F01; everything else correct |
| Literal typing through generic calls/constructors (`gen_lit.py`) | 138 | 3 000 checked, 2 056 run | all correct |
| Ownership random walks: R/`*R`/Box/`R?`/structs/enums/Vec[*R]/owned closures; moves, drops, overwrite-drops, replace, swap, if/else conditional moves, loops, early return, error propagation, defer/errdefer, `match !e`, `<q.o` take, `while <o as` (`gen_own.py`) | 937 | ~10 000 ownership events | all satisfy the oracle, no leak |
| Owned temporaries in nested calls, constructors, consuming receivers, `*`/Box/arrays, with a propagating `!` or `?` at random positions (`gen_tmp.py`) | 400 | | all satisfy the oracle, no leak |
| Generics instantiated with R, `*R`, Box, `R?`, Int, String, payload enum, struct: pick/keep/cycle/wrap/unwrap_or/first_some/must/`(<o)?`/swap/Pair/Shelf/Maybe (`gen_gen.py`) | 400 | | all satisfy the oracle, no leak |
| Runtime and compile-time failures (`gen_ovf.py`) | 500 | | 408 panic correctly, 67 rejected correctly, 24 missing panics (F02) |
| Multi-module dirs (main + lib + util): pub/private fields, private defaults across modules, cross-module constants, generics over local types, enums, error sets, drop glue, closures, name clashes (`gen_mod.py`) | 200 | | all correct |
| Random control flow vs a Python interpreter: if/else-if chains, for/while with steps, labels, guarded break/continue, loop `else`, match (literals/ranges/guards/bindings), defer, early return, loop values, optionals (`gen_cf.py`) | 330 (run stopped early at the coordinator's request; 1 000 accepted) | | all correct |
| Parser/lexer fuzz: token soup (10%) and 1-4 mutations of test, example, doc and generated programs (`fuzz_parse.py`) | 240 000 `rig check` runs | | 1 crash (F05), 0 hangs, 0 diagnostics without a position |
| Accepted mutants that differ from their source, run (`c/mut`) | 799 | | 2 Zig errors (F03, F04); 28 legitimate panics; 5 infinite loops; 9 without `main` |

Total: about 4 700 programs run end to end (over 16 000 generated cases), 240 000 `rig check` runs.
38 886 further accepted mutants in `pf2/accepted/` were not run (stopped at the coordinator's request).

## LANGUAGE QUESTIONS

1. **Literal typing stops at some expression forms** (all rejected with a diagnostic, so not accept-means-correct
   violations, but inconsistent): in a context that expects `U32`, `[0, 20][i]`, `(|| 7)()`, `gid(7)` as an operand
   (`b + gid(7)` with `b: I32`), `gpick(127, 255, c)` as an operand, `Wrap(v: 7).v`, `Wrap.make(7).get()`, and
   `gmax(14, 19)` as a ternary branch beside an `I128` all stay `Int` and are rejected ("type mismatch", "operands have
   different types"), while `gid(7)` as a binding's value or argument adapts. Should literal typing reach operands
   and branches the same way it reaches bindings and arguments?
2. **A `raw` block is not an expression in a binding** (`x: U8 = raw` + block: "unexpected keyword `raw`"), though it
   yields a value as a function's last statement. Intended?
3. **Printed strings inside aggregates are not escaped**: `In(a: none, s: "q"uote\n")` prints a raw quote and newline
   inside the quotes, so the output of `print` for a struct is ambiguous.
4. **`util.Byte.max`** (FR2) and **conversion-argument literal checks** (FR1): intended limits of the rules, or bugs?
   (Listed as low findings above.)
