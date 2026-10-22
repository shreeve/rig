# Audit: brackets branch, front end and type checker

Scope: `git diff 6df0c48..brackets` (rig.grammar, src/rig.zig rewriter and
parser wrapper incl. the receiver-sigil rewrite, src/resolve.zig,
src/typecheck.zig, src/sema.zig). Lens: parsing, instantiation vs
indexing, inference, compile-time values, diagnostics.

All repros live in
`/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/C2/repro/`
(abbreviated `R/` below). Commands were run with
`RIG_OUT_DIR=<scratch>/C2/out bin/rig check|run R/<file>`, each twice.
The existing `bin/rig` was used; nothing was rebuilt or modified.

## Summary

- 2 critical, 3 high (one pre-existing), 7 medium, 11 low findings.
- Both critical bugs come from one new code path: the field-element
  call `x.f[i](args)` in `synthMemberCall` (src/typecheck.zig:3708-3714)
  skips the two checks the plain field call does (receiver sigil,
  resource temporary), so accepted programs leak and skip `drop`.
- The receiver-sigil rewrite for `!p.handlers[0]()` (src/rig.zig:1296)
  does move the sigil onto `p`, which is wrong for a field of
  functions: `!p.checks[0]()` is now accepted and reads as a negation it
  is not (a regression; the old tree was rejected).
- A type parameter can be called in a generic function body (`T(x)`),
  which passes `rig check` and fails in Zig.
- Fuzzing (~44k mutated and generated programs, including 4.5k run
  through `rig run`) found no crash, panic, or hang.

## Findings

| ID | Sev | Repro | What happens | Expected | Suspected cause | Fix idea |
|---|---|---|---|---|---|---|
| F01 | critical | `R/F01_move_sigil_field_fn_leak.rig`, `R/F01b_move_sigil_skips_drop.rig` | `x = <p.handlers[0]()` (field holding functions) passes `check`. It is rewritten to `(<p).handlers[0]()`, emitted as `rig.take(&__rig_alive_p, p).handlers[0]()`, and the moved `p` is never dropped. `rig run` prints `1` and then `memory leak detected: 1 allocation (32 bytes)`. F01b: a `drop` body (`drop 7`) never runs. `<(p.handlers[0]())` (the old tree) is accepted and runs clean. | Rejected with the same message as `<p.handler()`: "`handlers` is a field holding a function, not a method with a receiver; drop the `<`" | The rewriter (src/rig.zig:1296) treats the member before a bracket list and a call as a method. In the checker, the field-element branch of `synthMemberCall` (src/typecheck.zig:3708-3714) never calls `misplacedSigil`, which the plain field-call branch does at :3755-3756. | In the `ct != null and resolved_method == null` branch, add `if (self.isReceiverSigil(obj)) try self.misplacedSigil(obj, method, "is a field holding functions, not a method with a receiver")`. |
| F02 | critical | `R/F26_temp_resource_field_elem_call.rig` (control: `R/F26b_nonbracket_control.rig`) | `x = P(v: <v, handlers: [one]).handlers[0]()` passes `check`, and `rig run` reports `memory leak detected`. The same call without brackets (`P(...).handler()`) is rejected: "this `P` is a temporary that owns a resource…". `f = P(...).handlers[0]` (no call) is also rejected. | Rejected, like the non-bracket form | The same branch (src/typecheck.zig:3708-3714) skips `rejectResourceTemporary(obj, obj_ty)`, which the plain field-call path runs (:3757). This path is new in this diff. | Call `rejectResourceTemporary(obj, obj_ty)` in that branch, or route it through the existing data-field logic. |
| F03 | high | `R/F02_write_sigil_field_fn_bool.rig` (old tree: `R/F02_paren_equiv_old_tree.rig`) | `if !p.checks[0]()`, where `checks: [1]fun() -> Bool` and the function returns `true`, passes `check` and prints `negated`. The `!` became a silent write borrow of `p`, so the condition is the un-negated `true`. Before this diff the same source was `!(p.checks[0]())`, which is rejected: "`!` is a write borrow; use `not` for negation". `x = !p.handlers[0]()` is also accepted as a no-op. | Rejected (field, not method; and the Bool rule) | Same as F01: the rewrite at src/rig.zig:1296, plus the missing `misplacedSigil` at src/typecheck.zig:3708. | The F01 fix covers it. The rewriter itself cannot know whether the member is a method, so the checker must reject it. Add a reject test for `!p.fs[0]()` and `<p.fs[0]()`. |
| F04 | high | `R/F03_type_param_called.rig` | `fun f[T](x: T) -> T` with body `T(x)` (also `w = T(1)`, `print(T(x))`, `T(n: 1)`) passes `rig check`. `rig run` then fails in Zig: `error: type 'type' not a function`. Other misuses (`print(T)`, `T.x`, `<T`, `T[0]`) are rejected with "`T` is a type, not a value". | "`T` is a type parameter; it cannot be called or constructed" | `synthCallInner`, src/typecheck.zig:2988: `.generic_param` falls into `else => callValue(callee, sym.ty, …)`. The param's `sym.ty` is poison, so `callValue` calls `skipCall` and reports nothing. In a generic type's method the same code gives "use of unbound name `T`", which is misleading but at least rejects. | Add a `.generic_param` arm that reports the error, and fix the generic-type-method message the same way. |
| F05 | high (pre-existing, in lens) | `R/F04_ct_arith_zig_error.rig`, `R/F04b_ct_div_zero.rig`, `R/F04c_ct_shift.rig` | Arithmetic on a compile-time parameter passed on as a compile-time argument (`inner[n + 1]` with `outer[255]` and `n: U8`; `inner[10 / n]` with `outer[0]`; `inner[1 << n]` with `outer[70]`) passes `check`. Zig then fails at compile time: `overflow of integer type 'u8' with value '256'`, `division by zero here causes illegal behavior`, and `type 'u6' cannot represent integer value '70'`. | A Rig diagnostic at the call site that makes the instance (or reject arithmetic on compile-time params in compile-time arguments) | `isComptimeKnown` (src/typecheck.zig:3554) counts arithmetic over compile-time params as known. Constant folding only checks literal operands, while Zig evaluates the instance's expression at comptime. This logic is unchanged from the `pre` era. | Evaluate compile-time arguments per instance with the concrete values (the same machinery as literal folding) and report overflow, division by zero or shift range there. Or accept only literals, enum values and bare params/`=!` names in compile-time arguments. |
| F06 | medium | `R/F05_xmod_generic_type/main.rig` | With `pub type Box[T]` in `lib`, `lib.Box[Int](v: 3)` reports "`lib.Box` is not a generic type; it takes no type arguments", which is false. `b: lib.Box[Int]` in a type gives a bare "unexpected `[`" with no hint, and `lib.Box(v: 3)` gives "`lib.Box` cannot be called". | "generic types cannot cross module boundaries yet" (SPEC §15/§19) | src/typecheck.zig:2543 maps foreign `.generic_type` to `.not_generic`. The grammar `tatom` has no `module.Name[...]` form. | Give `InstTarget` a foreign-generic variant with the roadmap message. Add a parser hint for `x.Y[` in a type. Consider rejecting `pub type Box[T]` at the declaration. |
| F07 | medium | `R/F06_fn_type_param_named_vec.rig` | `fun f[Vec](x: Vec) -> Vec` (also `Cell`, `Signal`) is accepted and runs. Inside, `Vec[Int]()` then fails with "`Vec` is a type, not a value" plus "use of unbound name `Int`". `type Box[Vec]` is rejected. | Rejected as for generic types: "generic parameter `Vec` has the same name as the module-level declaration `Vec`" (SPEC: "not a built-in type") | `resolveCtParam` (src/resolve.zig:657-669) checks only primitive and numeric names and `Self`. `checkShadowsDeclaration` (:201) skips builtins (`decl_pos == builtin_decl_pos`). `checkTypeParamNames` (:929) covers types only. | Share `checkTypeParamNames`' logic with function type params, and reject built-in generic names. |
| F08 | medium | `R/F07_method_stmt_call.rig` | The statement `s.show[3]` (method `sub show[n: Int](?self)`) reports "method `show` must be called; to pass it as a function that takes the receiver first, name it through its type: `S.show`". `!s.bump[2]` gives the same. `S.hello[4]` (no `self`) works. | Either call it (a statement `f[...]` is a call) or say "call it with `s.show[3]()`"; the `S.show` advice is wrong for a function with compile-time params | `implicitCall` (src/typecheck.zig:2675) returns null for `.value_member`, so the statement falls through `synthIndex` to the method-value error. | In `implicitCall`, handle `.value_member` when the member resolves to a method with no parameters beyond `self`. Otherwise emit the `(...)` hint. |
| F09 | medium | `R/F08_conflict_hint_wrong.rig` (also `max(id(2), 3.5)` → `max[Float](…)`, `apply(inc, 2.5)` → `apply[Float, Int](…)`) | A conflict diagnostic suggests brackets that do not compile: following "give it in brackets: `max[Int](...)`" gives "type mismatch: expected `Int`, got `U8`". | Suggest the bracket list only when every conflicting argument is a literal or converts; otherwise suggest a conversion (`Int(x)`) or say the arguments must agree | `inferCallTypeArgs` (src/typecheck.zig:3475) always suggests the later argument's type. | Check that the suggestion is compatible with each bound argument before offering it. |
| F10 | medium | `R/F09_infer_hides_mismatch.rig` (also `?[3]Int` → `[3]T` via a slice, `?*N` → `?~T`) | `first_of(?xs)` with `xs: [3]Int` and param `[]T` reports "cannot infer `T` … give it in brackets: `first_of[T](...)`". The real problem is a type mismatch (`?[3]Int` vs `[]T`), and the hint is the literal parameter name. | The mismatch, as a concrete function reports it: "expected `[]T`, got `?[3]Int`" | `bindArg` (src/typecheck.zig:3509) binds nothing when the shapes differ, as its doc says, but `inferCallTypeArgs` then reports "cannot infer" before the arguments are checked. | When a parameter is unbound and an argument's pattern mentions it, report a shape mismatch for that argument instead. |
| F11 | medium | `R/F10_ct_arg_cascade.rig`, `R/F17_type_param_name_cascade.rig` | `show[Int]` (a value param) gives two errors: "use of unbound name `Int`" (misleading, since `Int` is a type) and "compile-time argument 1 … must be known at compile time". `show[Mode]()` also gets the extra "must be known" error. F17: after "generic parameter `String` has the name of a built-in type", the call reports two more errors. | One error: "`show` takes a value for `n: Int` here, not a type" | `checkCtArgs` (src/typecheck.zig:3279) and `instantiateCall` (:3330) run `isComptimeKnown` even after `checkExpr` failed. A poisoned type-param slot is treated as a value param. | Skip the comptime check when the argument's type is poison. Treat an invalid slot whose param is a bare name as a (poisoned) type param. |
| F12 | medium | `R/F11_plain_fn_bracket_msg.rig` | `plain[0]`, where `plain` has no compile-time params, reports "`plain[0]` is a function with compile-time arguments; call it with `plain[0](...)`", and following that advice gives "`plain` takes no compile-time arguments". `size[4]` in an expression (no run-time params) also suggests `size[4](...)`. | "`plain` takes no compile-time arguments", or suggest `size[4]()` | `misusedInstance` (src/typecheck.zig:2585) ignores whether the function has compile-time params or run-time params. | Branch on `ct_params.len` and `takes_args`. |
| F13 | low | `R/F12_ct_none_literal.rig` | `sub f[n: Int?]` called as `f[none]` is rejected: "must be known at compile time; pass a literal…", but `none` is a literal. `f[[1, 2]]` for `[2]Int` and `f[inc]` for a `fun` param are rejected the same way. Declaring such params (struct, array, `Vec`, `fun`, `*Int`) is accepted although no call can ever pass them. | Accept `none`. Reject at the declaration a compile-time param type that no argument can have. | `isComptimeKnown` (src/typecheck.zig:3554): `isLiteralText` misses `none`. There is no check at the declaration. | Treat `none` and arrays of known values as known, and reject other param types in `resolveCtParam`. |
| F14 | low | `R/F13_trailing_comma_type_args.rig` | `Pair[Int, String,]` (in a type or an expression) is rejected with "unexpected `]`; expected an expression". Declarations (`type Pair[T, U,]`, `fun f[T,]`), arrays and call args all accept a trailing comma, and multi-line bracket lists encourage one. | Accept it, as elsewhere | The grammar's `targs` and `L(type)` in `tatom` have no `[","]`. | Add an optional trailing comma to `targs` and to the `generic_inst` args. Mind the one-arg `index` case: `xs[0,]` should probably stay rejected, with a hint. |
| F15 | low | `R/F14_spaced_ct_stmt_cascade.rig` | `show [3]` (space) gives two errors: "`show` takes 1 compile-time argument in brackets: `show[...](...)`" and "call to `show` expects 0 arguments, got 1". The hint's `(...)` is wrong for a sub with no run-time params, and nothing mentions the space. | One error: "compile-time arguments touch the name: `show[3]`" | `checkCtArgs` returns and `functionCall` still runs `checkArgs` (src/typecheck.zig:3268-3275). | Return null from `instantiateCall` after a compile-time arity error. Add a spacing hint when the lone argument is a bracket literal. |
| F16 | low | `R/F15_old_paren_type_args_cascade.rig` | The old syntax `Box(Int)(v: 1)` gives "cannot infer `T` for `Box`" plus a cascaded "use of unbound name `Int`". The same happens for `Option(Int).nothing` and `Cell(Int)(value: 1)`. | One error with a migration hint: "type arguments go in brackets: `Box[Int](...)`" | The constructor path checks a type name as a value. | When a positional argument of a generic type's constructor names a type, emit the bracket hint and skip the rest. |
| F17 | low | `R/F16_shadowed_vec_expression_msg.rig` | With a local `Vec = [1, 2, 3]`, `Vec[Int]()` reports "use of unbound name `Int`" and "`expression` has type `Int` and cannot be called" (the placeholder word "expression" shows up in the text). A local may shadow built-in type names (`Vec`, `Int`, `Cell`); type args then still resolve to the type while the object resolves to the local. | Either forbid locals named like built-in types, or give one clear error. Never print "`expression`". | `callValue(…, "expression")` (src/typecheck.zig:2997, :3715). `indexInto` returns the element type even when the index is poison. | Use the callee's source text for messages. Poison the result when the index is poison. |
| F18 | low | `R/F18_closure_arg_cascade.rig` | `apply(|x| x * 2, 4)` gives three errors: cannot infer `U`, the closure param needs a type, and closures cannot escape. The last is the real one. | One error: the escape | Inference runs before the argument's escape check. | Report the escape first and skip inference when an argument is a stack closure. |
| F19 | low | `R/F19_method_tparam_shadow_cascade.rig`, `R/F20_variant_brackets_cascade.rig` | After the declaration error "parameter `T` has the name of the generic parameter `T`", the call site adds "cannot infer `T` for `m` … `m[T](...)`". `Option.some[Int](value: 3)` adds "use of unbound name `Int`" after the correct first error. `s.nope[Int]()` gives "no field" plus "unbound name `Int`". | One error each | A poisoned declaration is still inferred. The bracket list is checked as an index after the object failed. | Poison the method's type on a param-name error. Skip the index expression when the object is poison. |
| F20 | low | `R/F21_generic_alias_expected.rig`, `R/F22_struct_brackets_nohint.rig` | `type A[T] = Vec[T]` reports "expected an indented block, `->` or `(`": `->` and `(` are impossible for a type. `struct Box[T]` and `error E[T]` report only "expected an indented block". | "generic aliases are not supported"; "a generic struct is `type Box[T]`" | The LALR state after `tparams` is shared with `fun`. `bracketHint` has no `struct` or `error` case. | Add hints to `bracketHint` for `struct`, `error`, and `=` after a type's `tparams`. |
| F21 | low | `R/F23_expected_result_type.rig` | `z: U8 = max(1, 2)` gives "type mismatch: expected `U8`, got `Int`". Generic constructors use the expected type, generic functions do not, and the error does not suggest `max[U8](1, 2)`. | Use the expected type when every binding is a literal default, or at least suggest `max[U8](...)` | `inferCallTypeArgs` ignores the expected type. | Pass the expected type as a weak binding for literal-only parameters. |
| F22 | low | `R/F24_paren_free_call_in_parens.rig`, `R/F25_empty_brackets.rig` | `print(id [Int](3))` reports "unexpected `[`" with no hint. `Vec[]()` and `id[](3)` report "unexpected `]`; expected an expression". | "compile-time arguments touch the name: `id[Int]`", "empty brackets: write `Vec[T]()`" | `parenFreeCallHint` and `bracketHint` do not cover these. | Add hints. |
| F23 | low | (perf) `C2/a/perf_ml500.rig` | Nested generic inference grows roughly cubically: `max(max(...), 2)` at depth 200 takes 0.45 s, 400 takes 2.2 s, and 500 takes 3.3 s. The 512-bracket limit bounds it, so it cannot hang. | Linear or close to it | Re-synthesis across nested `argType` or `checkArgs` levels | Low priority; memoize the checked argument types per call. |

### Notes on the `!p.handlers[0]()` question

The phase-A statement is accurate about the tree:
`rig normalize` shows `(call (index (member (write p) checks) 0))`.
That rewrite is wrong for a field of functions, and the checker does
not recover. `!v.put[2](x)` and `<b.eat[Float](2)`, where the member is a
real method, work correctly, and so do the negation guards
(`!b.peek[Int](3)` → "does not write its receiver"; a Bool result →
"written `(!b).check(...)`"). Only the field-element path is unguarded
(F01 to F03).

## Attacks that came out clean

Instantiation or index:
- A local, parameter or loop binding named like a user generic function
  or type (`max = [...]`, `Box = [...]`, a param `max`, nested blocks)
  is rejected ("same name as the module-level declaration").
- Locals named `Vec`, `Cell`, `Int`, `Signal` or `String` (including loop,
  closure-param and match bindings) index correctly and run (see F17
  for the only rough edge).
- `m.f[2](x)`, `m.f[2]`, and `m.f[2, 3]` across modules run or give the
  right arity diagnostics. A private `m.hidden[2]` gives "not public".
- `Type.method[U](...)`, `Box[Int].make[String](...)`,
  `Box.make[Bool](...)`, `value.method[U](x)`, `value.method(x)` inferred,
  `Box.conv[Float](?b, 2)`, `Box[Int].scaled[1](?b)`, and generic methods
  mixing type and value params (`b.mix[String, 4]("s")`) all run
  correctly.
- `v.fs[0](x)` and `t.ops[1](5)` read (without sigils or temporaries)
  run correctly.
- `f[Int][0]`, `max[Int, Int][0](1)`, and `max[Int][0][1]` are rejected
  as uncalled functions. `arr[Int](3)[1]`, `arr(4)[0]`, and `g[1][0]`
  run correctly.
- `.red[0]` gives a clear enum-literal error. `Box[Int]`, `Box`, and
  `id[Int]` used as values are rejected clearly.
- Assignment, sigils, `for`, `match`, `defer`, `!`, and `?` on
  `xs[1, 2]` give clear errors. `(max)[Float](1, 2)` and
  `max[(Int)](3, 4)` mean what they say.
- Bracket lists in `for` sources, `while` conditions, `match` subjects,
  `defer`, guards and ternary statements run correctly. Field and param
  defaults and module constants reject calls.

Spacing and lexing:
- `f[ x ]`, newlines inside a bracket list (statement, index, type args),
  and `fun id[T] (x: T)` work. `type Box [T]` and `fun id [T]` get good
  hints. `Vec[if]` is rejected.
- `pre` works as a variable, field, param, kwarg, method name,
  compile-time param, and type param. The old `pre n: Int` gets the
  migration hint.
- `print Vec[Int]().len` is only rejected for the owning temporary,
  which is correct. Paren-free calls with brackets (`sum [1, 2]`,
  `sum[Float] [1, 2]`, `show[Float] y`) are right.
- `self` and `Self` as type args: `Vec[Self]()` in a method works.
  `Vec[self]` is rejected ("`self` is not a type" / "unbound type").

Type arguments in expressions:
- `Vec[*Node]()`, `Vec[~Node]()`, `Vec[Int?]()`, `Box[Box[Int]]`,
  `Vec[lib.S]()`, and `Vec[T]()` / `Vec[Box[T]]()` in generic bodies all
  run.
- `Vec[Int!]` (fallible), `[]Int`, `[3]Int`, and `fun(Int) -> Int` get
  the documented hints. `**Int`, literals, `.red`, `1 + 2`, `p.n`, `P.n`,
  bare `Vec`, and `main` get clear errors.

Inference:
- Literal defaults, `U8` with a literal (`max(x, 200)`, and an overflow
  such as `max(x, 300)` is caught), nested generic calls (`id(max(1, 2))`,
  `pair(id(1), id("s"))`), and a generic call's result fed to another
  are all correct.
- Inference through `?T`, `!T`, `*T`, `~T`, `T?`, `[]T`, `[N]T`,
  `Vec[T]`, `Cell[T]`, `Box[T]`, and `fun(T) -> U` with a named function
  works. Explicit-bracket arity errors and "not a type" errors are
  clear.
- A function with a value param requires brackets
  (`g(3)` → "takes 2 compile-time arguments in brackets"). The known
  `f(3)` double-arity cascade is fixed: it now gives one error.
- Generic functions with closures in their bodies, and closures
  calling generic functions, work.

Compile-time values:
- Literal, enum literal, compile-time param, `=!` binding of one, a
  module constant, arithmetic on literals and constants, and Bool
  operators are all accepted and run.
- A literal that overflows the param type, division or remainder by a
  literal zero, and an out-of-range shift (literal operands) are
  rejected in Rig.
- `table[1]` of a constant array is rejected as not compile-time known.
- Compile-time params forwarded through generic functions and generic
  methods (`gfwd[Int, 7]`, `self.scaled[m + 1]()`) run correctly (see
  F05 for the overflow edge).

Receiver sigils:
- `!b.put[2](5)`, `<c.take[Int](4)`, `!b.add[Int](3)`, `!b.add("x")`, and
  `<b.eat[Float](2)` are correct. Negation misuse is caught when the
  member is a method.

Paren-free statement calls:
- `show[3]`, `show[4]()`, `lib.banner[40]`, `S.hello[4]`, `hello[Int]`,
  `show[3] if c`, statements in match arms, `defer show[9]`, and
  paren-free calls with brackets all work.
- The fallible statement form gives the `risky[6]()!` hint.
  `x = size[4]` and closure bodies are rejected (consistent with "a
  whole statement").

Modules:
- A `pub` generic function, a generic method of a `pub` type, and one
  reached through a public field are rejected at the declaration. A
  private generic function serving public ones works.

Parser robustness and fuzzing:
- Deep nesting (`Vec[` ×2000, `xs[` ×2000, `id[Int](` ×2000) is bounded
  by "brackets are nested too deeply" or "expression is nested too
  deeply", with no crash.
- Mutational fuzzing of every single-file test, example and scratch
  program: drop, duplicate and swap `[ ] ( ) ,`, insert sigils and
  newlines, replace names, and add `[Name]`. That was 36,200 `check`
  runs plus 3,000 mutants whose accepted cases were run through
  `rig run`, all under `gtimeout 10`. Grammar-based generation of
  bracket-heavy expressions added 4,500 more (1,500 run-checked). Result:
  0 crashes, 0 panics, 0 hangs, and 0 Zig compile errors or leaks on
  accepted mutants. The only flagged cases were false positives from the
  literal string "unreachable" in a test. The fuzzers are
  `C2/fuzz/fuzz.py`, `fuzz2.py`, and `gen.py`.
