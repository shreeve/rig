# Step 2 design: array sizes from compile-time values, and value parameters on generic types

Written by the design agent on 2026-09-26 against main e917c1d. The user's decisions on the open questions are recorded at the end, under "Decisions".

## 0. Foundation
- One representation for compile-time integers, kept in the type store. Add two `Type` variants in `src/sema.zig`:
  - `ct_value: CtValue`, with `CtValue = union(enum){ int: i128 }`, for a folded constant (such as `4`). Bool and enum arms can come later.
  - `ct_param: SymbolId`, for a value parameter used symbolically, the way `type_var` is used for types.
- Instance args (`Ring[Int, 4]`), array lengths, `FnInstance.args` and `GenericCall.type_args` all hold these TypeIds, so the existing `TypeSubst` (SymbolId→TypeId) substitutes them.
  - These need no new paths: `membersOf`, `typeItem`, `receiverArgs`, `expandInstantiations`, `checkRequirements` and interning.
  - Interning is structural. `Ring[Int, 2 + 2]` and `Ring[Int, 4]` therefore get the same TypeId, and so do `[LIMIT]Int` and `[4]Int`.
- The array length becomes a TypeId: `ArrayType{ elem, len: TypeId }`, where the length is a `ct_value` or a `ct_param`.
  - About 8 places read `a.len` today. Give them a helper, `sema.arrayLen(ctx, a) ?u64`.
  - `TypeChildren` reports `len` as child 1, so `has_type_var`, `usesParams` and poisoning stay generic.
- Prerequisite: a fill literal. Nothing can build a `[n]Int` whose length is symbolic, so add `[x, ..]`.
  - It fills the array whose length and element type come from the expected type: `a: [n]Int = [0, ..]`, `buf: [256]U8 = [0, ..]`.
  - It requires an expected type. The element must be plain data.
  - It lowers to `@as([n]i64, @splat(x))`.

## 1. Grammar
- Add `dim = INTEGER | name | name "." name → (member)`. Then:
  - the `type` rule's `"[" size:dim "]" type:inner`
  - `inner`'s `LBRACKET_INDEX size:dim "]" type:inner`
  - the schema `array_type size type`, where `size` was `size:leaf`
- Type args: `targ = type | INTEGER`, and `types` uses `targ`. `Ring[Int, n]` parses `n` as a type-name leaf, and sema reinterprets it by slot.
- No arithmetic in type positions in v1 (reduce/reduce conflict with `type`). Name the result with a constant instead: `DOUBLE =! LIMIT * 2`, then `[DOUBLE]Int`.
  - Expression-position instances (`Ring[Int, LIMIT * 2](...)`) already parse, since their args are expressions. Sema folds them.
  - A later `dim | name LPAREN_CALL args ")"` alternative, for compile-time functions, should add no conflict.
- Fill literal: `atom | "[" elems:exprs "," ".." "]" → (array_fill ...elems)`. Sema rejects more than one element.
- `src/rig.zig`'s `skipType` already allows ident, integer and dot inside brackets.

## 2. sema.zig (~160 LOC)
- `TypeInfo`:
  - `ct_param` sets `has_type_var`.
  - `ct_value` and `ct_param` are plain: no glue, cell or borrows, and depth 0.
  - `holdsIn`, `cellEdges`, `borrowEdges`, `byValueTargets` and `heldTypeVars` skip them.
- `substituteType`: `.ct_param` looks itself up in the substitution, keeping its own id when absent. `.array` substitutes both `elem` and `len`, and `usesParams` matches `.ct_param`.
- `importType`: copy a `ct_value`; a `ct_param` becomes invalid.
- `formatType`: print `4`, `n`, `[n]Int`, and `Ring[Int, 4]`.
- `FunctionType.ct_syms: []const SymbolId`, one per compile-time slot, with `symbol_invalid` for type slots. It takes part in `typeEqual`.
- A generic type's `type_params` holds type and value param symbols in declared order. A value param is kind `.param` with `comptime_known`, and `makeNominalContext` builds a `ct_param(sym)` for it.
- `Requirement.array_len` is checked per instance: the arg must be a `ct_value` with 0 <= v <= cap. It describes itself as "an array length".
- `moduleConstInt(ctx, sym) ?i128` folds a module `=!` constant on demand at resolve time. It uses a `const_values` map (SymbolId→Sexp) recorded in `walkSet`, and caches results in `const_ints`. Constants may only reference earlier ones.

## 3. resolve.zig (~180 LOC)
- `walkGenericType`:
  - Accept `name: Type` and drop the rejection.
  - Open a scope around the members (`ScopeKind.generic_type`) and declare the value params there.
  - Put their symbols into `type_params`.
- `resolveNominal`: resolve value param types before fields. v1 allows integer types only: "a compile-time value parameter of a type is an integer".
- `resolveType .src`: a value param used as a type gives "`n` is a compile-time value, not a type".
- `resolveArrayLen(size) TypeId`, handling each kind of size:
  - an INTEGER: range-check it, then `ct_value`
  - an integer ct param: `ct_param(sym)`, plus a `generic_requirements{param, .array_len, pos, "uses as an array length"}`
  - a module constant, local `=!` constant, or `lib.NAME`: `ct_value`
  - a type name: "`Int` is a type; an array length is an integer, a constant, or a compile-time parameter"
  - anything else: "array length `k` must be known at compile time"
  - `k =! n` is followed to `ct_param(n)`; record that alias in `checkSet`.
- `resolveFunction`: resolve ct params before the return type, so `-> [n]Int` sees `n`. Fill `ct_syms`.
- `resolveGenericInst`: slot-aware args.
  - A type slot is resolved as a type. An INTEGER there gives "`4` is a value; `T` takes a type".
  - A value slot takes an INTEGER, constant or param through the `resolveArrayLen` helper, and the value must fit the param's type. A type name there gives "compile-time argument 2 of `Ring` is a value of type `Int`, not a type".
  - Arity errors say "expects N compile-time arguments".

## 4. typecheck.zig (~260 LOC)
- `instantiateCall`:
  - `own` = type params + integer value params.
  - A given value arg goes through `checkCtValue` and then `ctIntArg`, which folds it or produces a `ct_param` (or follows a `=!` alias).
  - Remove the early return for value-only calls, so `zeros[3]()` has type `[3]Int` and records an `FnInstance`.
  - Keep the bracket-required error for non-integer value params, and for integer params that appear in no param or result type.
- Inference (`bindArg` / `inferBindings`):
  - The `.array` arm matches `len`. A `ct_param` pattern binds exactly to the actual `ct_value` (no literal defaulting).
  - The `parameterized_nominal` arm pairs value args the same way.
  - Conflicts: "conflicting values for `n` in the call to `sum`: `3` (argument 1) and `4` (argument 2)".
  - `bindExpected` covers `a: [4]Int = zeros()`. A bound value must fit the param's type.
- `typeInstance` / `typeArg`: value slots take `ctIntArg`, which folds `LIMIT * 2`.
- `inferTypeArgs`: constructors infer `n` from `items: [n]T`.
- `checkArray` / `synthArray`: a literal against a symbolic `[n]T` gives "an array of compile-time length `n` is built with `[x, ..]`".
- `checkArrayFill`: needs an expected array type, checks its one element against `elem`, and allows exactly one element.
- `indexInto` / `synthSlice`: check constant bounds only when `arrayLen` is known; otherwise bounds are checked at run time.
- `checkRequirements`, `.array_len` case: "`zeros[-1]` cannot use `n = -1`: the body uses `n` as an array length", with a note at `[n]`.
- Arithmetic on ct params stays forbidden, which also prevents `f[n+1]` from expanding forever.

## 5. emit.zig (~90 LOC), ownership.zig (~15 LOC)
- `emitTypeTy`:
  - `.ct_value` prints the integer; `.ct_param` prints the Zig name.
  - `.array` prints `[` + `emitTypeTy(len)` + `]`.
  - `Ring[Int, 4]` becomes `Ring(i64, 4)`.
- Int to usize: `comptime n: i64` in `[n]i64` should coerce. Test it; the fallback is `[@intCast(n)]`.
- `emitGenericHead`:
  - Emit `comptime n: i64` for value params, with an `_ = n;` discard via `mentions`.
  - Make them `Local`s, wrapped in `rig.rt(n)` under `rt_names`.
- `isSelfInstance`: also accept a `ct_param` of the type's own params.
- `emitIndex`: for a symbolic length, emit `rig.index(i, <n>)`.
- `emitArray`: an `array_fill` becomes `@as(T, @splat(x))`.
- `emitCtArgs` already calls `emitTypeTy`.
- Ownership: walk `array_fill` like `.array`; the element is consumed.
- Drop glue is unchanged, because `[n]T` forces a plain `T`.

## 6. Tests
- **Behavior:**
  - `ct_array_len`
  - `ct_array_infer`: `sum([1, 2, 3])`, `sum(?a)`, `a: [3]Int = zeros()`, and a generic body passing `n` on
  - `ct_array_const`: `[LIMIT]Int`, `[DOUBLE]Int`, `[lib.N]Int`, `[0]Int`, and a U8 param used as a size
  - `generic_value_param`: `struct Ring[T, n: Int]` with `items: [n]T` and methods; `Ring[Int, 4].new()`; inference; `Ring[Int, 2 + 2]` interchangeable with `Ring[Int, 4]`; printing; a Ring holding a Vec field, leak-checked
  - `array_fill`
  - a symbolic out-of-bounds index, as an `expect-panic`
- **Reject:**
  - `zeros[-1]()`, called directly and through a generic body
  - a `NEG =! -1` constant used as a size
  - a run-time local as a size
  - `[Int]Int`
  - `[n + 1]Int`
  - a Float constant as a size
  - `[300]` against a U8 param
  - conflicting lengths
  - `[1, 2]` where `[n]Int` is expected
  - `[1, 2, ..]`
  - `[0, ..]` with no expected type
  - `Ring[Int, Int]`, `Ring[4, Int]`, `Ring[Int]`
  - a non-integer value param on a type
  - a value param used as a type
  - an overflowing constant
- **Existing tests to update:** `generic_type_value_param.rig`, `ct_call_diagnostics.rig`, `generic_fn_undetermined.rig`.
- **IR snapshots:** `array_type` with a name size, `array_fill`, and `generic_inst` with an INTEGER arg.

## 7. Docs
- SPEC §3 Arrays: size forms, zero length, and the fill literal.
- SPEC §4 Generic types: value params. Generic functions: the value-inference rule.
- SPEC §17 and §19.
- SYNTAX §14, §22, and appendix C.
- INTERNALS: Generics, the IR node list, and Emit.
- ROADMAP: remove the two items this step delivers.
- `examples/generics.rig`: add Ring.

## 8. Risks
- More `FnInstance`s, one per distinct integer value.
- Total size across nested generic arrays is unchecked; file that separately.
- Land this after `syntax-cleanups` (it uses the `struct Ring[...]` spelling).
- Estimated ~720 src LOC, plus about 30 tests and 200 doc lines.

## Decisions
- The lead decided: sizes are capped at 2^32−1, and value params on types are integers only in v1 (Bool and enums later).
- USER DECISIONS (2026-09-26), these OVERRIDE the design above where they differ:
  1. Infer integer value params from `[n]T` and `X[.., n]` shapes: YES (as in the design; update the SPEC rule "never inferred").
  2. Fill literal is Rust style `[x; n]` (NOT `[x, ..]`): a new `;` token used only here; `n` is any compile-time-known integer expression (literal, constant, ct param, folded constant arithmetic like `LIMIT * 2`); element plain data; works with no annotation (`a = [0; n]` is `[n]Int`); lowers to `@as([n]T, @splat(x))` (or `[_]T{x} ** n`). `[x, ..]` is NOT added.
  3. Arithmetic IS allowed in array sizes and in type-position compile-time arguments now (no named-constant workaround). Grammar prototyped conflict-free by the lead (scratchpad/cexpr/rig.grammar): `dim = INTEGER | name | name.name | cexp`; `targ = type | INTEGER | MINUS_PREFIX INTEGER | cexp`; `cexp` is a constant expression with at least one operator (+ - * / %, parentheses), so a lone name stays a type and the checker reads it by slot. Sema folds cexp like compile-time arguments; arithmetic on a compile-time PARAMETER stays rejected (existing rule) unless it folds to a constant.
