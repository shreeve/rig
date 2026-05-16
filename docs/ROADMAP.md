# Rig Roadmap (V1)

A new systems language that transpiles to Zig.

## Mission

Build the language we'd want to write systems code in: **Zig-fast, Rust-safe, Ruby-elegant**, with explicit ownership, visible effects, and a Lisp-clean intermediate representation.

## Architecture

```
Rig source
  → Parser                 (rig.grammar + src/rig.zig)
       BaseLexer  + Lexer  (token rewriter)
       BaseParser + Parser (sexp rewriter)
  → semantic IR            (S-expressions; the grammar emits the
                            normalized shape directly via Nexus
                            tag-literal-at-child support)
  → effects checker        (src/effects.zig — fallibility visibility)
  → ownership checker      (src/ownership.zig — borrow / move / drop)
  → Zig emitter            (src/emit.zig — Zig 0.16 backend)
  → zig build              (Zig 0.16 toolchain)
```

Rig owns lexing, parsing, normalization, semantic checking, and lowering. Zig owns the optimizer, codegen, linker, and platform support.

## Milestones

### M0 — Parser online ✅
- `rig.grammar`, `src/rig.zig`, `build.zig` written.
- `bin/rig parse examples/hello.rig` emits raw S-expression.
- Golden snapshots locked for hello + SPEC §V1 test cases + spacing/sigils.
- Conflict count: 34 (after pruning unused pointer-type forms in M4.5b).

### M1 — Parser sexp rewriter ✅
- `Parser` (rewriter wrapper) in `src/rig.zig` produces normalized semantic IR.
- After Nexus 0.10.x+ tag-literal-at-child support, the grammar emits the
  normalized shape directly for nearly every form; the rewriter handles
  only one inspection-requiring transform (for-source ownership wrapper
  promotion).
- `docs/SEMANTIC-SEXP.md` documents the IR.

### M2 — Ownership checker ✅
- `src/ownership.zig`: implements SPEC §"Ownership Checker V1".
- Errors are source-pointed and sigil-aware.

### M3 — Zig emitter ✅
- `src/emit.zig`: semantic IR → Zig 0.16 source (Juicy Main, `std.Io`).
- Emitted Zig passes `zig ast-check` for every supported example.

### M4 — `rig` binary ✅
- `rig parse | tokens | normalize | check | build | run` all functional.
- `bin/rig run examples/hello.rig` prints "hello, rig".

### M4.5 — Semantic correctness hardening ✅
After the GPT-5.5 audit surfaced semantic-drift bugs (auto-`try`, hidden
fallibility, plain-use holes, shadow-lookup direction, etc.), an
intermediate hardening milestone landed:

- **M4.5a:** New `src/effects.zig` (fallibility checker). `build`/`run`
  run the full checker pipeline. Plain `.src` value-use now checks
  move/drop/write-borrow. Bound borrows release on drop/reassign. Shadow
  lookup scans reverse. Emitter is dumb (no auto-`try`, no signature
  mutation). `pub pub fn` fixed. `bindingKindOf` errors on unknown.
- **M4.5b:** Branch snapshot/merge for `if`. Recursive borrow-escape walk
  (catches nested `View(?user)`). Pointer-type prune. Lexer hygiene
  (`suffix_bang` in value-end, `pending_close_bar` cleared on structural
  tokens). Emitter `name_arena` for shadow names (no test-allocator leak).
  Single-quoted strings lower to Zig double-quoted. Doc refresh.

### M5 — Real type checking ✅
Landed across 6 sub-commits, each with a GPT-5.5 design checkpoint:

- **M5(1/n):** `src/types.zig` foundation. `SemContext`, `TypeStore`
  interner, `Symbol` / `Scope`, stable `SymbolId` / `ScopeId` /
  `TypeId`. Symbol resolution pass populates module-scope and nested
  scopes (fn body, block, for, catch, arm) with all declarations.
- **M5(2/n):** Type expression resolution. Each declared type Sexp
  (`(error_union T)`, `(optional T)`, `(borrow_read T)`, etc.) is
  converted to a `TypeId` and written back into the symbol's `ty`
  slot. Functions get a complete `function` Type with param + return
  types. Unknown nominal names silently return `invalid_id` (deferred
  diagnostic — Rig has no module system yet).
- **M5(3/n):** Expression typing. `synthExpr` / `checkExpr` /
  `checkStmt` walk function bodies with statement-vs-value context.
  Literal pseudo-types (`int_literal` / `float_literal`) adapt to
  declared sized numerics. Value-position `if` requires `else` and
  unifies arms; statement-position arms walk independently. Calls
  check arity + arg types against the resolved signature. Returns
  check against the declared return type. Diagnostics with
  `formatType` rendering (e.g., `Int`, `U8`, `String`, `User?`,
  `[]Int`).
- **M5(4/n):** Effects checker consumes `SemContext`. Local
  `FunSig` collection replaced with sema-driven lookup; the same
  M4.5 visibility rules apply via the authoritative symbol table.
- **M5(5/n):** Ownership consumes `SemContext` for Copy/Move
  classification. Copy primitives (`Bool`, `Int`, `Float`, `String`,
  literal pseudo-types) skip the move/drop/write-borrow checks in
  `checkPlainUse`; Move types still follow the conservative M4.5
  rules. Position-based binding-to-symbol matching avoids lockstep
  scope tracking.
- **M5(6/n):** Emitter consumes `SemContext` for constructor
  disambiguation. `Foo(...)` lowers to a struct literal when sema
  resolves `Foo` to a nominal type, a function call when it
  resolves to a function, and falls back to the kwarg-presence
  heuristic only for unresolved names.

Success criteria from the M5 design pass — all met:
```
fun foo() -> Int    # body uses bar()! → effects + sema both fire
fun foo() -> Int!   # OK
x = fallible()      # effects fires (sema lookup confirms fallibility)
x = fallible()!     # OK
x = if cond 1 else 2          # types as Int
x = if cond 1 else "no"       # type error: incompatible if arms
```

Pipeline post-M5:
```
parse → normalize → sema (symbols + types + expr typing)
                 → effects (sema)
                 → ownership (sema, with Copy/Move classification)
                 → emit (sema, with constructor disambiguation)
```

### M6 — Struct field metadata + member typing ✅
Closes the two biggest M5-deferred items: member access now resolves
to declared field types, and constructor invocations are validated
against the field list (names + types + arity + duplicates).

- New `Field` type + `Symbol.fields` slice. `TypeResolver` populates
  it from `(struct Name (: field type) ...)` declarations.
- `synthMember` resolves `obj.name` via the obj's nominal type's field
  list. Unknown fields fire a sourced diagnostic.
- `synthCall` for nominal callees calls `checkConstructorArgs` which
  enforces real-field names, assignability, no-duplicates, and
  no-missing-fields. Now correctly returns `nominal(SymId)` instead
  of `unknown_id` (an M5 oversight that broke member typing on
  user-defined types).
- `emit.emitStruct` lowers `(struct Name (...))` to Zig
  `pub const Name = struct { ... };`. Combined with M5(6/n)'s
  constructor disambiguation, `bin/rig run` works end-to-end on
  struct programs.

### M7 — Enum + error-set typing & lowering ✅
Closes the enum half of M6's deferred list. Enum declarations
populate per-variant fields, enum literals (`.red`) type-check
against the contextually expected enum, and both `enum` and `error`
declarations lower to clean Zig.

- `TypeResolver.resolveEnumVariants` walks `(enum Name v...)` and
  `(errors Name v...)` (same IR shape) and stores variants as fields.
- `checkExpr` intercepts `(enum_lit name)` against an expected
  nominal enum and validates the variant exists. Unknown variant →
  `error: no variant 'purple' on enum 'Color'`.
- `emit.emitEnum` lowers to `pub const X = enum { ... };`. When any
  variant has an explicit value, falls back to `enum(u32)` so
  Zig accepts the explicit tag.
- `emit.emitErrorSet` lowers to `pub const X = error { ... };` so
  future fallible signatures compose naturally with `try`.
- `print` polish: when sema knows the arg's type is `String` (bare
  identifier OR struct member access), emit uses `{s}` instead of
  `{any}`. `struct_basic.rig` now prints `Steve` not byte codes.

### M8 — Match expression typing & lowering ✅
Closes the biggest remaining `@compileError` placeholder. Match on
enum scrutinees type-checks each arm pattern against the scrutinee's
enum and lowers cleanly to a Zig `switch`.

- `ExprChecker.checkMatchStmt` reuses M7's `checkEnumLit` to validate
  `.variant` patterns against the scrutinee's enum.
- `emit.emitMatch` lowers to `switch (scrutinee) { .X => ..., }`.
  Consults sema to count the enum's variants — only appends
  `else => unreachable` when arms are non-exhaustive (Zig errors on
  redundant else).
- Bodies are auto-wrapped in `{ ... }` for statement-shaped arm
  bodies so Zig's expression-position arm syntax accepts them.
- Bare-ident catch-all arms (`other =>`) lower to Zig `else =>`.

### M9 — Payload-bearing enum variants ✅
Closes the biggest stdlib precursor. Enums can now carry per-variant
payloads (`circle(radius: Int)`), and instances can be constructed
with kwarg or positional syntax (`.circle(radius: 5)` /
`.triangle(3, 4)`). Lowering produces clean Zig `union(enum)`.

- New grammar `member → name params → (variant 1 2)` for payload-
  variant declarations.
- `Field.payload: ?[]const Field` carries per-variant payload field
  list; `TypeResolver.resolveEnumVariants` populates it.
- `emit.emitEnum` lowers to `union(enum)` when any variant has
  payload; single-payload variants unwrap to bare types,
  multi-payload variants get anonymous structs.
- `ExprChecker.checkExpr` intercepts
  `(call (enum_lit name) args)` against an expected enum; validates
  args against the variant's payload (arity, names, types,
  duplicates, missing fields).
- `emit.emitCall` lowers `.variant(args)` to Zig's anonymous
  tagged-union literal `.{ .variant = ... }` — the surrounding
  type context coerces it.

Match destructuring of the payload (`.circle => |c| use(c)`) is
M10+ alongside pattern-binding propagation.

### M10 — Match destructuring + pattern bindings + value-position + exhaustiveness ✅
Closes the post-M9 candidate item #1 plus all M8-deferred match
items in one focused milestone. Match expressions are now
feature-complete for the M5 v1 surface.

- Grammar: `.circle(r)` / `.triangle(a, b)` / `.nullary()`
  payload-destructure patterns via new `Tag.variant_pattern`.
- Sema: `bindPatternNames` extracts every name a pattern
  introduces and binds it (initially `unknown_id`) in the arm
  scope; `checkArmPattern` then refines those bindings via the
  variant's `Field.payload` field types.
- Sema: value-position `match` via `synthMatchExpr` walks arms
  with `unifyOrErr` to a single result type. Statement-position
  match keeps the M8 permissive behavior.
- Sema: real exhaustiveness via per-match `StringHashMap` of
  covered variants — catches `duplicate arm for variant 'X'`,
  rejects unhandled variants in value position, and tracks
  default-arm coverage correctly.
- Diagnostics: `no variant 'X' on enum 'Shape'`, `variant 'X'
  has no payload to destructure`, `variant 'X' has N payload
  field(s), pattern destructures M`, `value-position 'match'
  is not exhaustive`.

### M11 — Qualified enum access (`Color.red`) ✅
Closes the post-M10 candidate item #2. `Color.red` type-checks
as `nominal(Color)` (instead of silently `unknown`) and bad
variants in qualified position now fire a sourced diagnostic.

- Sema: `synthMember` distinguishes type-qualified access (obj
  is a `.src` resolving to a `nominal_type` symbol) from value
  member access (obj's TYPE is `nominal(SymId)`).
- Type-qualified access returns `nominal(Color)`; unknown
  variant fires `error: no variant 'purple' on enum 'Color'`
  with a decl-site note.
- Emit unchanged — `(member Color red)` already lowered to
  Zig's `Color.red` syntax. Sema-only change.

### M12 — Struct methods (namespaced) + qualified method calls ✅
Closes the post-M11 candidate item #3. Methods declared as `fun`
/ `sub` members of a struct are tracked by sema, lower to `pub
fn` inside the Zig struct, and are callable via
`Type.method(args)`.

- `Field` gains `is_method: bool`. `TypeResolver.
  resolveStructFields` recognizes `(fun ...)` / `(sub ...)`
  members and appends their function `Type` to the struct's
  field list via `resolveStructMethod`.
- `synthMember` dispatches data-vs-method on type-qualified
  access.
- `emitStruct` does a second pass for `fun`/`sub` members and
  emits each via `emitFun` with one extra indent — nested as
  `pub fn` inside `pub const X = struct { ... };`.
- `print(User.greet())` recognizes call-to-String via sema and
  emits `{s}` formatting.

**Explicitly deferred (M20 work):** instance methods with
implicit `self` (`u.greet()` receiver-style), method body sema
checking (requires `self` typing), methods on enums (parsed but
not emitted), generic methods on generic types.

### M13 — Range patterns in match arms ✅
Closes one of the M10-deferred items. `1..3 => body` type-
checks (bounds must be assignable to the scrutinee) and lowers
to Zig's inclusive switch range `1...3 => body`.

- `checkArmPattern` learns about `(range_pattern lo hi)`; each
  bound is checked against the scrutinee's type via `checkExpr`.
- Range patterns DON'T contribute to enum exhaustiveness
  coverage — integer scrutinees only in V1.
- Emit: `emitMatch` arm dispatch handles `(range_pattern lo hi)`.
  `..` is inclusive on the high end in V1.

**Deferred:** guard patterns (`x if cond => body`) need grammar
work that risks `if` keyword conflicts.

### M14 — Generic types (struct-shape) ✅
Closes the post-M13 candidate item #1 (partial — struct-shape
generics only via `type Name(...)`; generic enums need grammar
work that's deferred). End-to-end `bin/rig run` works on generic
struct programs.

- Grammar: type expression gains `name "(" L(type) ")"` →
  `(generic_inst Name T...)`. So `Box(Int)`, `Pair(Int, String)`
  parse as type expressions. Conflict count unchanged at 34.
- Sema: `generic_type` symbols (from M5) get no new generic-
  param scope yet; generic params resolve silently as
  `invalid_id` (M5 v1 deferred-diagnostic behavior). Generic
  instances in type position resolve to opaque `unknown`; emit
  handles substitution at the Zig template level.
- Emit: `emitGenericType` lowers `(generic_type Name (T...)
  members...)` to `pub fn Name(comptime T: type, ...) type {
  return struct { ... }; }`. `emitType` lowers `(generic_inst
  Name T1 T2 ...)` to `Name(T1, T2)`. `emitCall` learns a third
  constructor-disambiguation arm: emit `.{ ... }` (anonymous
  tagged literal) for `generic_type` callees, since the named
  identifier is a Zig fn, not a type.

**Explicitly deferred (M20 work):** generic enum types
(`Option(T)` / `Result(T, E)`) — grammar conflict with bare
`Name(...)` member declarations; generic methods on generic
types; real generic-instance member typing (`b.value` on
`b: Box(Int)` currently types as `unknown`, works in emit
because Zig figures it out).

### M15 — Module system ✅
Multi-file projects via `use foo` (same-dir lookup). Each module
parses + sema-checks + emits to its own `.zig` in a generated
output directory; `bin/rig run` works end-to-end on multi-module
projects.

- New `src/modules.zig` with `ModuleGraph` + recursive `loadByPath`
  + cycle detection via the standard tri-state walk + same-string
  dedup for diamond imports.
- Driver (in `main.zig`): `loadProjectOrExit` builds the graph and
  aborts on errors before emit; `emitProjectToTmp` writes each
  module's `.zig` to `/tmp/rig_<root>/`.
- Sema marks `use foo` symbols as `.module`-kinded; cross-module
  type checking deferred to M15b (currently Zig handles the
  cross-file signature check).
- `(use foo)` lowers to `const foo = @import("foo.zig");`
- Test infrastructure: `test/modules/` subdirs with `expected.txt`
  / `expected_error.txt` for output / error checks.

### M16 — Compiler Robustness ✅
No-panic contract: `bin/rig` MUST NEVER segfault, panic, or hit
`unreachable` on any input — well-formed or malformed. Every input
produces either valid Zig output or a clean Rig diagnostic.

- `ModuleState` (`loading`/`loaded`/`failed`) + fail-safe slot
  construction: every `Module` gets a valid `SemContext` BEFORE
  parsing, so diagnostic walks are safe on failed modules. Fixes
  the SIGSEGV that prompted the milestone (failed parse left
  `Module.sema = undefined`, segfaulted in `writeDiagnostics`).
- `writeDiagnostics` hardened against empty path / empty source /
  empty messages / out-of-range pos.
- Grep audit removed two dead `unreachable` arms (`Mode.help`,
  `emitCompoundAssign` duplicate switch) and verified all `.?`
  sites are guarded. No `@panic` / `catch unreachable` /
  `orelse unreachable` anywhere.
- `test/torture/` corpus (18 entries) + `test/run` torture
  section enforces the contract for every bad input — exit
  non-zero, stderr non-empty, no panic phrases. Adding a new
  bad-input regression test = drop a `*.rig` in `test/torture/`.

### M17 — `if`-as-Expression Lowering ✅
Closes a major idiomatic-code hole. Before M17, any `if` used in
expression position lowered to `@compileError("rig: emitter does
not yet support `if`")`. Now:

- Single-expression branches lower inline (`if (c) a else b`).
- Multi-statement branches lower to labeled blocks with
  `rig_blk_N: { ...; break :rig_blk_N <expr>; }`. Labels are
  unique per emitter so nested if-expressions never shadow.
- Branches that terminate (`return`/`break`/`continue`) skip the
  label — Zig errors on "unused block label" and the `noreturn`
  branch type coerces to the other branch's type.
- Missing-else in value position is a sema diagnostic
  (`ExprChecker.synthIfExpr`); the emitter has a `@compileError`
  safety net for defense in depth.
- 6 new examples (basic, chain, block, binding, early-return,
  enum-variant) cover the lowering shapes; one new torture entry
  pins the missing-else diagnostic.

### M18 — `match`-as-Expression Multi-Statement Arms ✅
Closes the symmetry hole between `if`-as-expression (M17) and
`match`-as-expression. Multi-statement arm bodies in value
position now lower to `pattern => rig_blk_N: { ...; break
:rig_blk_N <expr>; }`. Statement-position match is unchanged.

- `emitMatch` now takes a `value_position: bool` flag plumbed
  from `emitStmt` / `emitExpr`.
- `emitArmBody` dispatches to `emitBranchExpr` (M17 recipe) for
  value position, falls back to the legacy void-block wrap
  otherwise.
- Pre-existing `scanMutations` scoping bug exposed and fixed:
  each `(block ...)` opens its own `seen` scope so the same
  binding name in sibling arms isn't mis-classified as
  reassignment. Compound assigns (`+= -= *= /=`) and move-assign
  (`<-`) are always mutations regardless of seen-state.
- 4 new examples + 1 torture entry. 340 passed, 0 failed.

### M19 — Typed Mutable Binding Emission ✅
Closes the daily-annoyance hole that `var i = 0` failed to
compile in Zig (`comptime_int` can't be a mutable variable).
Emitter now consults sema's inferred type for any mutable
binding without a source-level annotation and emits the Zig
type automatically.

- `emitSetOrBind` looks up the binding's symbol via `decl_pos`.
- For numeric / bool / literal pseudo-types, emits the Zig
  spelling (`int_literal` → `i32`, `float_literal` → `f32`,
  `int{bits}` → `iN`/`uN`, etc.).
- Falls through to bare `var x = expr;` for non-numeric inferred
  types and parser-only mode (no sema).
- 2 new examples (`typed_counter`, `typed_accumulator`). No
  existing emit goldens changed. 352 passed, 0 failed.

### M20a — Instance methods + `self` semantics + receiver-style calls ✅
Closes the M12-deferred half of the method-syntax story. Methods
declared with a `self` first param are callable as `u.method(args)`
(instance), body-type-checked with `self` bound to the declared
receiver type, and validated against the receiver-mode rules at
the call site. Enum methods get the same machinery.

- **`SymbolResolver.walkNominalType`** now walks `fun`/`sub`
  members of struct/enum/errors bodies via the new `walkMethod`
  helper, opening each method's body scope and binding its
  params (including `self`). Methods are NOT added as
  module-scope function symbols — they live on the nominal's
  `Symbol.fields` slice with `is_method = true`.
- **`TypeResolver`** gains `current_nominal: ?SymbolId` for `Self`
  resolution. `resolveStructFields` / `resolveEnumVariants` now
  take + return `scope_cursor`, and the shared
  `resolveNominalMethod` (renamed from `resolveStructMethod`)
  writes each param's resolved type back into its body-scope
  symbol — without this, `self.name` inside a body typed as
  `unknown.name` and collapsed silently. `resolveType` resolves
  bare `Self` to `nominal(enclosing)`.
- **`ExprChecker`** gains `walkNominalDecl` + `walkMethod`,
  descending into struct/enum bodies in lockstep with the
  resolver's scope-push order. Method bodies are now type-checked
  against the declared return type — closes the M12 gap where
  body type errors were silently accepted.
- **`synthCall`** dispatches on `(call (member obj name) args)`
  callees with three cases (per GPT-5.5's M20a design pass):
  module-qualified (intentional `unknown` until M15b lands),
  associated/static (`Type.method(args)` — return type
  propagates), and instance (`value.method(args)` — receiver-mode
  validation + `params[1..]` check).
- **`synthMember`** unwraps one level of `borrow_read` /
  `borrow_write` so `self.name` on `self: ?User` reaches User's
  fields. Does NOT unwrap optional — `maybe.name` on `User?`
  stays an error per GPT-5.5's null-deref guidance. Method
  pseudo-fields and data fields are separate lookup branches;
  bare method reference (`user.greet` without a call) fires a
  targeted diagnostic.
- **Receiver-mode rules** (per GPT-5.5, visible-effects thesis):
  `?Self` auto-borrows from bare lvalue / rvalue; `!Self`
  requires explicit `(!receiver)` (write borrow is dramatic
  enough to deserve visibility); by-value `Self` requires
  explicit `(<receiver)` for named lvalues (consumption deserves
  visibility). Rvalues (calls / records / propagation) coerce
  freely.
- **Emitter** gains `current_nominal_name` for `Self` →
  enclosing-type-name substitution in type position. New
  `emitNominalMethods` helper unifies the method-emission pass
  used by `emitStruct` (M12) and `emitEnum` (M20a — closes the
  silent-drop bug where enum methods never reached emitted Zig).
  Print polish (`{s}` for String) and `matchExhaustive` now
  unwrap borrow types so `self.name` / `match self` work in
  method bodies. `enumVariantCount` and several variant-lookup
  paths filter out `is_method` fields so methods don't
  pollute exhaustiveness counts or variant searches.
- 8 new examples: 5 positive (`method_self_read` /
  `method_self_write` / `method_self_consume` /
  `method_associated_return` / `method_enum`), 3 negative
  (`method_write_missing_bang` / `method_consume_missing_lt` /
  `method_body_type_error`). 394 passed, 0 failed (was 352).

**Out of scope (deferred):** generic methods (M20b — requires
real generic-instance substitution machinery first); receiver-
type validation (`fun bad(self: ?Order)` inside `struct User`
currently silent — minor hole); explicit diagnostic for
`maybe.name` on `User?` (today returns silent `unknown`);
field-target assignment (`self.name = new_name` — `checkSet`
enhancement).

### M20a.1 — `?self` / `!self` sigil-on-name sugar ✅
Tiny ergonomic follow-up to M20a. The common borrow-receiver
case gets a sigil-on-name shorthand that desugars during sema:

```rig
fun greet(?self) -> String     # sugar for `self: ?Self`
sub modify(!self, n: String)   # sugar for `self: !Self`
sub consume(self: Self)        # by-value still uses the long form
```

- **Grammar** (`rig.grammar`): two new `field` productions emit
  `(read NAME)` / `(write NAME)` at param position. Conflict
  count unchanged at 34. Both spellings remain valid; the sugar
  is purely an alternative for the common case.
- **Sema** (`src/types.zig`):
  - `paramName` recognizes the new shapes for name extraction.
  - `SymbolResolver.bindParam` accepts `(read NAME)` /
    `(write NAME)` and marks the symbol as a borrowed param.
  - `TypeResolver.resolveParamType` validates: name must be
    literally `self`, and the enclosing `current_nominal` must
    be set (i.e., we're inside a method body). Returns
    `borrow_read(nominal(self))` / `borrow_write(nominal(self))`.
  - Two new diagnostics: "sigil-prefixed parameter is only
    allowed for `self`" (for `?xs`, `!other`, etc.); "`?self`
    is only allowed in a method body" (for `?self` at module
    scope).
- **Emit** (`src/emit.zig`):
  - `emitParam` lowers `(read NAME)` / `(write NAME)` to
    `NAME: EnclosingType` using `current_nominal_name` (set
    by `emitStruct` / `emitEnum`).
  - Emitter's `bindParam` also recognizes the shapes.
- **No new tags, no new IR shapes** — reuses the existing
  `read` / `write` Tags. Position-based disambiguation
  (param-position vs expression-position).
- Existing M20a examples updated to use the sugar; emitted Zig
  is byte-identical to the explicit form (the desugared sema
  resolves to the same `borrow_read(nominal(...))` type).
- 2 new negative examples (`method_sugar_bad_name`,
  `method_sugar_outside_nominal`) pin the two diagnostics.
- 402 passed, 0 failed (was 394).

### M20+ — V1 Substrate (reactivity-driven ordering)

The remaining V1 substrate work is sequenced by the design note
[`docs/REACTIVITY-DESIGN.md`](REACTIVITY-DESIGN.md), which uses
Rip-style reactivity (`Cell` / `Memo` / `Effect`) as a
multi-feature stress test. Each blocking item below is required
regardless of reactivity — reactivity just exposes the seams.

**Already-landed substrate** (M12 + M14 partial — completed in
the M20+ items below):

- Namespaced struct methods (`User.greet()`) — M12
- Generic struct declaration + instantiation + construction — M14

**Now-blocking (required for any non-trivial library):**

1. ~~**Instance methods + `self` semantics + receiver-style calls**~~
   ✅ **Landed in M20a** above.
2. **Real generic-instance member typing** (completes M14).
   Today `b.value` on `b: Box(Int)` types as `unknown`; needs
   per-instance field-type substitution in sema so member access
   resolves to the substituted type.
3. **Generic methods on generic types** (M14-deferred). Depends
   on item 2 and the M20a self-binding machinery (already in
   place).
4. **`Option(T)` / `Result(T, E)` as generic enum types**
   (M14-deferred). Needs grammar work — `enum Name INDENT ...`
   doesn't yet accept `params`, and adding it conflicts with
   bare `Name(...)` member declarations. The `T?` / `T!` suffix
   types desugar to these once they exist.
5. ~~**Methods on enums**~~ ✅ **Landed in M20a** (resolver +
   emitter both go through the unified `resolveNominalMethod` /
   `emitNominalMethods` paths).
6. `*T` / `~T` real `Rc` / `Weak` semantics (SPEC §Shared
   Ownership, §Weak Reference — text landed; runtime
   implementation TBD).
7. Interior mutability — `Cell(T)` library type
   (REACTIVITY-DESIGN D6, option A for V1). Depends on items
   2 + 4 + 6.
8. Closure capture mode syntax (REACTIVITY-DESIGN D7) — `|name|`
   strong, `|~name|` weak, `|<name|` move, etc.

**Soon (substrate maturity):**

9. `%T` unsafe-effect lattice + `unsafe` block / fn-modifier
   (SPEC §Unsafe / Raw — text landed; checker enforcement TBD)
10. `pre` AST extraction for derive-style macros
    (REACTIVITY-DESIGN D8)
11. Explicit error sets in `T!E` return types
12. Module path canonicalization (M15b)
13. Guard patterns (`x if cond => body`) — M13-deferred due to
    `if` keyword conflict risk
14. Try-block lowering (still `@compileError`)
15. Expected-type propagation through bindings / calls / returns
16. Opaque types
17. Fold of `effects.zig` into `types.zig` once expression typing
    is rich enough to express "non-fallible expected here" naturally

**Deferred to V2 or later** (per SPEC §V2/V3):

18. `@T` pinning as a real `Pin<P>` discipline
19. Scoped-context language mechanism (Reactor / Allocator / Span
    passed implicitly; REACTIVITY-DESIGN D9)
20. Multi-threaded shared ownership (`Arc<T>` / `Send` / `Sync`)
21. Reactive sugar (`:=` / `~=` / `~>` — Phase C of
    REACTIVITY-DESIGN, optional)
22. Stdlib seed (Vec, HashMap, String) — depends on items 1–8
23. LSP
24. Async / coroutines
25. Real fuzzing of the robustness contract

**Validation milestone — Phase B of REACTIVITY-DESIGN.md.** Once
items 1–8 land, build `rig-reactive` in a branch as a ~500-line
library that exercises the substrate end-to-end. If anything in
1–8 doesn't compose, fix the language, not the library.

## Beyond V1 (deferred per SPEC §V2/V3)

Multi-threaded shared ownership (`Arc<T>` / `Send` / `Sync`),
pinning (`@T`) as a real `Pin<P>` discipline, async, allocator
traits, reflection, full trait/interface system, advanced
lifetime inference, richer pre-metaprogramming, scoped context
syntax for ambient parameters, effect annotations on methods.

V1 `*` and `~` are real `Rc<T>` / `Weak<T>` (single-threaded, no
atomics) per SPEC §Shared Ownership and §Weak Reference. V1 `@T`
parses but is not enforced; deferred to V2 per SPEC §Pin. V1 `%x`
/ `zig "..."` / dangerous `@builtin(...)` require unsafe context
per SPEC §Unsafe / Raw.

## Non-goals

- LLVM backend (Zig handles it)
- Garbage collection (ownership instead)
- Macro system (favor `pre` + library design)
- Trait system V1 (deferred)
