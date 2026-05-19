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

### M20a.2 — Receiver metadata + self validation + decl-time soundness ✅
Hardening pass on M20a before M20b builds on top, prompted by
GPT-5.5's post-implementation audit which surfaced two soundness
holes and several validation gaps. Closes the M20a holes that
would otherwise compound in generic-method dispatch.

**Soundness fixes:**

- **Static-as-instance dispatch (M20a soundness bug).**
  `synthInstanceCall` previously inferred receiver-ness from
  `fn_ty.params.len > 0`, silently dispatching associated/static
  methods called as instance form (`u.make()` where `make` is
  static). Now dispatches on a new `MethodReceiver` enum
  (`.none` / `.read` / `.write` / `.value`) populated at
  decl-time by `resolveNominalMethod` from the syntactic first
  parameter. `synthInstanceCall` errors cleanly for `.none`
  with a targeted diagnostic pointing the user at the
  associated-call form.
- **Consume-through-borrow.** `checkReceiverMode` previously
  classified receiver expressions by syntactic shape only —
  `get_ref().consume()` (where `get_ref` returns `?User`) was
  accepted as `.call` → `rvalue` → `.value`-receiver-OK,
  silently consuming through a read borrow. Fix: new
  `ReceiverTypeKind` (`owned_nominal` / `read_borrow` /
  `write_borrow` / `other`) classifies the receiver's TYPE,
  combined with the shape check. New rules:
  - read receiver: any owned-or-borrowed kind accepted; only
    explicit move rejected
  - write receiver: read-borrowed type rejected; rvalues only
    OK if owned/write-borrowed; explicit `(!u)` always OK
  - value receiver: any borrowed type rejected; rvalues only
    OK if owned; explicit `(<u)` always OK

**Self validation:**

- `self` must be the first parameter of a method (positional).
- `self` receiver type must match the enclosing nominal (or
  `Self` alias).
- `?self` / `!self` sugar only valid at param[0] (was: only
  validated for name).
- Bare untyped `self` (`fun foo(self)`) in first position is
  now a hard error — per GPT-5.5: "once `self` is special
  enough to power receiver metadata, it must not silently
  become an ordinary associated-method param." Users wanting
  a by-value receiver must spell `self: Self` (or
  `self: <Nominal>`) explicitly; bare-`self` sugar is
  deliberately deferred.
- Sigil-prefixed entries in nominal MEMBER position
  (`struct S { ?x }`) now fire a dedicated diagnostic
  (previously dropped silently by `resolveStructFields`'s
  `else` arm).
- `Self` resolution inside method body local annotations now
  works (`ExprChecker.current_nominal` plumbed into the
  on-the-fly `TypeResolver` constructed by `checkSet`).

**Code quality:**

- New `unwrapBorrows(ctx, ty_id) -> TypeId` helper factored
  from four duplicated inline loops (two in types.zig: `synthMember`,
  `synthInstanceCall`; two in emit.zig: `matchExhaustive`, print
  polish). Comment now accurately says "peels borrow wrappers";
  optional/fallible/shared/weak/raw are intentionally NOT peeled.
- New `classifyReceiverShape` helper factored from
  `checkReceiverMode`. Expanded rvalue set per GPT-5.5: added
  `if` / `match` / `ternary` / `catch` / `try` / `try_block` /
  `array` / `anon_init`; removed `raw` and `pin` (not true
  rvalues — `%x` is an unsafe view of existing storage, `@x` is
  V2-deferred). Documented the "false negatives OK; false
  positives unsound" rationale inline.
- `ownership.zig`'s `bindParam` extended to recognize the
  `(read NAME)` / `(write NAME)` sugar shapes (per GPT-5.5's
  param-walker audit), with a length guard against malformed
  Sexp.

**Tests:** 7 new examples covering each new diagnostic and the
defensive two-self test:
- `method_static_as_instance` — the original soundness bug
- `method_self_second_position` — self at non-zero position
- `method_self_wrong_type` — self typed as different nominal
- `method_self_bare_untyped` — bare `self` rejected
- `method_consume_through_borrow` — value receiver applied to
  read-borrowed call result rejected
- `method_sigil_struct_member` — `struct S { ?x }` rejected
- `method_two_self_methods` — defensive: two methods named
  `self` on different nominals returning different types;
  print polish correctly dispatches via object's type, not
  global name scan

432 passed, 0 failed (was 402).

**Deferred** (per GPT-5.5's review):
- Write-receiver mutation runtime test — needs `checkSet`
  member-target support first (separate M20+ item).
- `lookupDataField` / `lookupMethod` helpers + `NominalContext`
  refactor — first patch of M20b, in service of generic
  substitution.
- Emitter scope-aware symbol resolution — long-term cleanup
  for the global-name-scan fragility (M20a.2's two_self_methods
  test pins current behavior).
- `MethodReceiver.invalid` mode to reduce cascaded diagnostics
  on receiver-type errors — minor polish.

### M20b — Real generic-instance member typing + generic methods ✅
Closes the M14-deferred items (#2 and #3 of the M20+ "now-blocking"
list below). After M20b, `b.value` on `b: Box(Int)` types as `Int`
(was: `unknown`), constructor field-type mismatches fire clean
diagnostics, generic types emit their methods (the latent M14 emit
bug), and `b.get()` on a generic receiver runs end-to-end with the
right substituted return type.

Shipped as 5 self-validating sub-commits (M5-style, per GPT-5.5's
design checkpoint). Tests grew 432 → 470 across the milestone.

#### M20b(1/5) — Lookup-helper refactor (pure)
Pre-positioning refactor. New top-level helpers:
- `lookupDataField(ctx, receiver_ty, name) !?ResolvedField`
- `lookupMethod(ctx, receiver_ty, name)    !?ResolvedMethod`
- `hasMethodNamed(ctx, receiver_ty, name)   bool` (const,
  non-allocating existence check for diagnostics).
- `ResolvedField { field, ty, nominal_sym }`,
  `ResolvedMethod { field, receiver, fn_ty, nominal_sym }`.

`synthMember` and `synthInstanceCall` switched to use the helpers.
No semantic change; 432 tests still pass.

#### M20b(2/5) — Type representation scaffolding
- New `Type.parameterized_nominal: ParamNominal { sym, args }` —
  fully-applied generic instantiation (`Box(Int)`). Args owned by
  the SemContext arena; interner deduplicates by structure.
- New `Type.type_var: SymbolId` — references a `.generic_param`
  Symbol. Strict equality (same SymbolId only — never a wildcard,
  per GPT-5.5).
- New `SymbolKind.generic_param`.
- New `NominalContext { sym, self_type, type_params }` replaces
  the M20a `current_nominal: ?SymbolId` on both TypeResolver and
  ExprChecker.
- New `TypeSubst { params, args; .lookup, .isEmpty }` +
  `substituteType(ctx, ty_id, subst) !TypeId` that recurses
  through every Type variant carrying a TypeId. Leaves unbound
  type_vars unchanged (matters for future method-local generics).
- New `makeNominalContext(ctx, sym_id)` + `isSelfTypeId(ctx, ty,
  ctx)` helpers.
- `compatible` / `formatType` / interner equality extended.

#### M20b(3/5) — Generic body walking + symbolic field resolution
- `SymbolResolver.walkGenericType` walks the body: binds each type
  param as a `.generic_param` Symbol, records the IDs on the
  generic type's `Symbol.type_params`, and walks member methods to
  push their body scopes. Duplicate-param diagnostic. (Per
  GPT-5.5's post-implementation review, M20b(5/5) detached these
  symbols from lexical scope; see below.)
- `TypeResolver.resolveDecl` dispatches `.generic_type` →
  `resolveGenericTypeFields`, which populates `.fields` with
  type-var-bearing symbolic types (`value: T` → `type_var(T_sym)`)
  and threads `current_nominal` so `Self` and `T` resolve correctly
  in signatures.
- `resolveType.@".src"` now resolves `Self` via
  `NominalContext.self_type` and bare `T` via
  `NominalContext.type_params` (by-name walk, not lexical-scope-
  only — robust to on-the-fly TypeResolvers).
- Receiver-type validation extended for generics via the
  `isSelfTypeId` helper; `?Self` inside `type Box(T)` now matches
  `borrow_read(parameterized_nominal(Box, [type_var(T)]))`.

#### M20b(4/5) — Generic-instance dispatch
The user-facing payoff:
- `resolveType` handles `(generic_inst Name T1 T2 ...)` →
  `parameterized_nominal`. Arity validation + diagnostic on
  mismatch.
- Lookup helpers extended to handle parameterized receivers: build
  a `TypeSubst` from the receiver's args + the generic's
  `type_params`, then `substituteType` on the matched field/method
  type. T → Int at lookup time.
- `classifyReceiverType` recognizes parameterized nominals whose
  base symbol matches.
- New `checkGenericConstructorCall` + `checkConstructorArgsSubst`:
  `checkExpr` intercepts `(call <name> args...)` where the callee
  resolves to the same `generic_type` as the expected
  `parameterized_nominal`, then drives substitution from the
  expected-type args (per GPT-5.5: "design for expected-type-driven
  generic construction, not inference"). `b: Box(Int) = Box(value:
  5)` works; `b: Box(Int) = Box(value: "hello")` errors cleanly.

#### M20b(5/5) — Emit + post-implementation hardening
**Emit**:
- `emitGenericType` emits `const Self = @This();` + data fields +
  nested `pub fn` methods (parameterized `emitNominalMethods`
  indent). Closes the latent M14 emit bug.
- `current_nominal_name = "Self"` inside generic body, so the
  emit `Self`-substitution is a no-op rename that pairs with the
  alias. Plain nominals (M20a) keep the existing
  `Self → bare-type-name` substitution — inconsistent but
  minimizes golden churn.
- Print polish extended for parameterized fields via the new
  const `typeEqualsAfterSubst` helper (NOT `@constCast(sema)` —
  phase discipline).

**Hardening** (per two rounds of GPT-5.5 review):
- **Detached generic-param symbols** (`addDetachedSymbol`): `T` no
  longer leaks into module scope; lookup goes exclusively through
  `NominalContext.type_params`. Two generics with `T` no longer
  collide. Bare `Box` in type position now errors with
  `"generic type 'Box' requires type arguments"`.
- **Fallible lookup helpers**: `lookupDataField` /
  `lookupMethod` return `!?ResolvedField` / `!?ResolvedMethod`;
  no `catch f.ty` fallback. Allocator-error discipline restored.
- **Unannotated generic construction rejected**: `Box(value: 5)`
  without an LHS type errors with `"generic constructor 'Box'
  requires an expected type; write 'b: Box(T) = Box(...)'"`. V1
  has no inference — by design.
- **`@constCast(sema)` in print polish replaced** with the new
  const `typeEqualsAfterSubst` helper. Emit no longer mutates
  sema's interner.
- **`nominalSymOfReceiver` helper** for diagnostics: `b.missing()`
  on `b: Box(Int)` now fires `"no method 'missing' on type 'Box'"`
  cleanly (was `"(unknown)"` or silent).
- **`type_var` skip removed** from `checkConstructorArgsSubst`
  (round 2): the skip silently hid real symbolic-body errors like
  `b: Self = Box(value: "hello")` inside a generic body. The new
  test `generic_symbolic_body_mismatch` pins this.
- **`typeEqualsAfterSubst` fast-path soundness** (round 2): the
  `ty_id == target` short-circuit is gated on `subst.isEmpty()` —
  otherwise `Box(T) == Box(T)` would short-circuit incorrectly
  when `subst` says `T → Int`.

**Tests across M20b** (6 new examples in M20b(4/5) + M20b(5/5)):

  POSITIVE (EMIT_TARGETS, run end-to-end):
    generic_member_typed             — `b.value` types as Int
    generic_method                   — `b.get()` returns 42 via subst
    generic_string_field             — `Box(String).value` polishes to {s}

  NEGATIVE (sema-error goldens):
    generic_constructor_type_mismatch — `Box(value: "hi")` vs `Box(Int)`
    generic_unannotated               — `b = Box(value: 5)` without LHS
    generic_bare_in_type_position     — `x: Box`
    generic_missing_method            — `b.missing()` on parameterized
    generic_symbolic_body_mismatch    — T vs String inside generic body

470 passed, 0 failed (was 432 at M20a.2).

**Deferred to follow-up M20+ items**:
- Generic enum types (`Option(T)` / `Result(T, E)`) — needs grammar
  work; remains a now-blocking M20+ item below.
- Generic-associated-method inference (`Box.make(5)` inferring
  `T = Int`) — out of M20b scope. Today fires the unannotated-
  construction diagnostic; users must write `b: Box(Int) =
  Box.make(5)` (which currently has no special handling and
  routes through the synth path).
- Plain-nominal Self emitting as bare-type-name (vs `Self =
  @This()` like generics) — minor consistency cleanup; deferred.
- Field-target assignment + write-receiver mutation runtime test
  (separate M20+ item).

### M20c — `Option(T)` / `Result(T, E)` as generic enum types ✅
Closes the M14-deferred item #4 from the M20+ "now-blocking" list.
Generic enum types now declare, instantiate, type-check, and emit
end-to-end. Per GPT-5.5's design checkpoint + post-implementation
review.

Shipped as 3 self-validating sub-commits (M5-style). Tests grew
470 → 496 (+26).

#### M20c(1/3) — Grammar + symbols
- Grammar: `ENUM name params INDENT members OUTDENT →
  (generic_enum 2 3 ...5)` parallel to the M14 `generic_type`
  production. Conflict count unchanged at 34 (verified via
  `zig build parser`). New Tag `generic_enum`.
- Symbol resolver: dispatches both `.@"generic_type"` and
  `.@"generic_enum"` to the shared `walkGenericType` helper —
  same pass-1 work (bind detached params, walk methods). Zero-
  param rejection (`enum Foo()` / `type Box()`) with a diagnostic
  pointing at the dropped `()`.
- `Field` gains `is_variant: bool = false`. Backfilled at all
  three variant-Field append sites in `resolveEnumVariants` (bare,
  valued, payload). `lookupDataField` now filters BOTH `is_method`
  and `is_variant` so enum-typed receivers can no longer match
  variants as data fields (was a latent hazard never tested for).
- Per GPT-5.5: `generic_errors` deferred (Zig error sets don't
  carry payloads; `Result(T, E)` covers the use case).

#### M20c(2/3) — Sema
- `TypeResolver.resolveDecl` dispatches `.@"generic_enum"` to the
  same `resolveEnumVariants` helper (now branches on IR head for
  `variants_start = 3` vs `2`, and sets `current_nominal =
  makeNominalContext(sym_id)` for generic-enum bodies so payload
  field types with bare `T` resolve to `type_var(T_sym)`).
- New `lookupVariant(ctx, receiver_ty, name) !?ResolvedVariant`
  helper, parallel to `lookupDataField`/`lookupMethod`. Handles
  both `nominal` (plain enum) and `parameterized_nominal` (generic
  enum) receivers; substitutes payload field types via TypeSubst
  for parameterized receivers (so `Option(Int).some` returns
  `payload = [value: Int]`, not `[value: T]`).
- Three callers switched from direct `Symbol.fields` walks to
  `lookupVariant`: `checkEnumLit`, `checkPayloadVariantCall`,
  `checkVariantPattern`. Each falls through to a
  `nominalSymOfReceiver`-based diagnostic when the variant doesn't
  exist; silently accepts when receiver isn't a nominal at all.
- Match exhaustiveness for parameterized enums: `enumVariantCount`
  (sema) and `matchExhaustive` (emit) both routed through
  `nominalSymOfReceiver` and now count only `is_variant=true`
  fields.

#### M20c(3/3) — Emit + 5 new examples
- New `emitGenericEnum` parallel to `emitGenericType` but emitting
  `union(enum) { const Self = @This(); ... }` body. Variant
  emission mirrors `emitEnum`'s `has_payloads` branch: bare → `:
  void`; single-field payload → `name: T` (unwrap); multi-field →
  `name: struct { ... }`. Method emission reuses
  `emitNominalMethods(items[3..], 2)` for the two-level indent
  (inside `return union(enum) { ... }`).
- Per GPT-5.5: `current_nominal_name = "Self"` inside the body so
  emit's `Self`-substitution arm is a no-op rename that pairs with
  the `const Self = @This();` alias.
- Two single-payload-detection sites in emit (`single_payload`
  check in `emitPayloadVariantLit`, `lookupVariantPayloadNames`)
  extended to accept `.generic_type` symbols + filter via
  `is_variant`. Without this, generic enum construction emitted
  the verbose form against a `some: T` decl, causing Zig to
  error "type `i32` does not support struct initialization
  syntax."

#### Tests (5 new, all in `examples/generic_enum_*.rig`)

  POSITIVE (in EMIT_TARGETS, run end-to-end):
    generic_enum_option   — `Option(Int)` with match, prints `got it`
    generic_enum_result   — `Result(Int, String)` two-param subst
    generic_enum_method   — `Option(T)` with `is_some` method

  NEGATIVE (sema-error goldens):
    generic_enum_payload_mismatch  — substituted `Int` vs `String`
    generic_enum_zero_params       — `enum Foo()` rejected

GPT-5.5's pre-commit spot-checks all verified clean:
- Payload mismatch fires with substituted type names
- Missing variant fires `no variant 'missing' on enum 'Option'`
- Variant-as-field correctly rejected (`is_variant` filter)
- Value-position non-exhaustive match catches generic enum case

#### Deferred (per GPT-5.5)

- Self consistency for plain nominals (`const Self = @This();` for
  plain structs/enums too, matching the generic-form convention) —
  6-golden churn; deferred as a separate cleanup pass (M20c.1 if
  desired) to keep this milestone focused.
- `T?` / `T!` desugar to `Option(T)` / `Result(T, E)` — strongly
  deferred per the M20c design checkpoint; would touch the
  effects checker, the `?`/`!` triangle, the emitter, the stdlib,
  and the optional propagation reservations. Separate milestone.
- Generic-enum payload caching in `lookupVariant` — premature; no
  evidence of hot path.

### M20d — `*T` / `~T` real `Rc<T>` / `Weak<T>` semantics ✅
Closes M20+ item #6 from the "now-blocking" list. `*T` is now a real
single-threaded reference-counted handle, `~T` is its paired weak
handle, and the M20d alias-footgun rule + read-only auto-deref rules
keep V1 honest about what shared ownership permits.

Shipped as 5 self-validating sub-commits (M5-style, per GPT-5.5's
design checkpoint plus a post-(1/5) refinements round). Tests grew
496 → 544 across the milestone (+48). Joint Q1 decision (Steve
delegated to Claude + GPT-5.5): **Option A — explicit `-x` only for
V1; auto-drop deferred to M20e** (queued below, ordered before #8
closure capture).

#### M20d(1/5) — Grammar + Type variants + sema typing
- Grammar: `SHARE_PFX type → (shared 2)` and `"~" type → (weak 2)`.
  Conflict count 34 → 38 (+4); all four are the expected shift-
  prefer pattern from `*T?` / `~T?` chains.
- New `@"shared"` Tag (distinct from expression-position `@"share"`
  per GPT-5.5 — separate tags so phase walkers don't disambiguate
  by context). `@"weak"` is reused across positions.
- New `Type.shared: TypeId` and `Type.weak: TypeId` variants. Strict
  structural equality: `*User == *User` only; `*User != User`;
  `~User != *User`. No wildcard / coercion behavior.
- `formatType` renders `*T` / `~T`. `substituteType` and
  `typeEqualsAfterSubst` recurse through both.
- `(share x)` at expression position now types as `shared(typeOf(x))`
  (was: silent pass-through). `(weak x)` requires its operand to be
  `shared(T)` and types as `weak(T)`, with a clean diagnostic on
  non-shared operand.

#### M20d(2/5) — Runtime + driver integration
- `src/runtime.zig`: V1 runtime as a Zig string constant.
  `RcBox(T)` carries `allocator` + `strong: usize` + `weak: usize`
  (implicit `+1` while strong > 0) + `value: T`. `WeakHandle(T)`
  wraps `?*RcBox(T)`. Explicit API names: `cloneStrong`, `dropStrong`,
  `weakRef`, `cloneWeak`, `dropWeak`, `upgrade` (per GPT-5.5: avoids
  ambiguity with library-defined `clone`/`drop` patterns; makes
  emitted Zig readable). `rcNew(anytype)` is the constructor helper.
- Driver (`src/main.zig`): `emitProjectToTmp` writes `_runtime.zig`
  to the same tmpdir as the module .zig files. Single-file and
  multi-file `run` / `build` both get the runtime co-located so the
  per-module `@import("_runtime.zig")` resolves uniformly.
- Emitter (`src/emit.zig`): prelude includes `const rig =
  @import("_runtime.zig");` unconditionally (top-level unused
  namespace imports are permitted in Zig 0.16).
- All 38 existing emit goldens regenerated with the new prelude.

#### M20d(3/5) — Operator emit + alias-footgun rule
- Emit dispatches on operand TYPE via a `handleKindOf` classifier:
  - `(share x)`  → `(rig.rcNew(<x>) catch @panic("Rig Rc allocation failed"))`
  - `(clone x)`  → `<x>.cloneStrong()` if shared, `<x>.cloneWeak()` if weak,
                   pass-through otherwise
  - `(weak x)`   → `<x>.weakRef()` (sema invariant: operand is shared)
  - `(drop x)`   → `<x>.dropStrong();` if shared, `<x>.dropWeak();` if weak,
                   `// drop <x>` otherwise (existing V1 no-op)
  - `(move x)`   → pass-through (handle transfer is sema-only)
- `emitType` for `(shared T)` → `*rig.RcBox(<T>)`; `(weak T)` →
  `rig.WeakHandle(<T>)`.
- **Alias-footgun rule** (per GPT-5.5's post-(1/5) call as THE biggest
  M20d footgun): bare `*T`/`~T` on the RHS of a binding or as a call
  argument fires a clean diagnostic suggesting `<rc` (move) or `+rc`
  (clone). Implemented as purely additive `checkSharedHandleAlias`
  helper in `ownership.zig`, called from `walkSet` (RHS) and
  `walkCall` (args). Does not touch `walk` or `checkPlainUse`.
- 3 EMIT_TARGETS: `shared_basic`, `shared_move_into_fn`, `weak_basic`.
- `WeakHandle.dropWeak` takes `Self` by value (not `*Self`) so weak
  bindings emit as `const` Zig; ownership's `walkDrop` already catches
  `-w; -w` so defensive nulling without ownership integration would
  only paper over checker bugs. Trade-off documented in runtime source.

#### M20d(4/5) — Read-only auto-deref + receiver-mode rejections
- New `unwrapReadAccess(ctx, ty_id)` helper that peels `borrow_read`
  + `borrow_write` + `shared` (NOT `weak`, optional, fallible, raw).
  Per GPT-5.5 hazard call: narrow helper instead of broadly extending
  `unwrapBorrows` so write/consume paths don't accidentally compose
  with shared. `lookupDataField` / `lookupMethod` / `hasMethodNamed`
  switched to use it.
- New `ReceiverTypeKind.shared` variant. `classifyReceiverType`
  returns `.shared` when the receiver type unwraps borrows to
  `shared(nominal_sym)` matching the method's enclosing nominal.
- `checkReceiverMode` rejects:
  - `.write` receiver through `.shared` → "cannot call write-
    receiver method through a shared handle (`*T`); other handles
    may exist. Use an interior-mutable type (planned `Cell(T)` in
    M20+ item #7)".
  - `.value` receiver through `.shared` → "method consumes the
    receiver; cannot consume the inner value through a shared
    handle (`*T`)".
- `checkSet` rejects field-target assignment when LHS is
  `(member obj field)` and `typeOf(obj)` unwraps to `shared(_)`.
  Same `Cell(T)`-pointing diagnostic.
- `resolveType` rejects nested shared (`**T`); currently defensive
  (the literal `**` syntax tokenizes as the power operator and so
  is unreachable, but the check fires if a future type alias /
  generic composition produces nested shared).
- Emit: `.@"member"` bridges through `RcBox.value` when
  `handleKindOf(obj) == .shared` so emitted Zig is
  `rc.value.field` / `rc.value.method()` not `rc.field` (Zig sees
  `*rig.RcBox(T)`; field/method access on T requires the `.value`
  hop). Sema's prior rejections ensure the bridging is only ever
  applied to safe read-only accesses.

#### M20d(5/5) — Tests + SPEC + ROADMAP
- 1 new positive example (`shared_auto_deref`): field + method
  through shared, runs end-to-end (prints `42` twice).
- 6 new negative-test goldens pinning each diagnostic:
  - `shared_alias_in_binding`        — bare `rc2 = rc`
  - `shared_alias_in_call`           — bare `f(rc)`
  - `shared_write_method_rejected`   — `rc.write_method()`
  - `shared_consume_method_rejected` — `rc.consume()`
  - `shared_field_assign_rejected`   — `rc.field = X`
  - `weak_of_non_shared`             — `~u` on non-shared `u`
- SPEC §Shared Ownership amended (V1 explicit-drop discipline,
  alias rule, `*T?` vs `(*T)?` precedence, `*expr` move semantics).
- M20e queued below, ordered before #8 closure capture.

**Final test count after M20d arc: 544 passed, 0 failed (was 496 at
the start of the milestone; +48 = 7 examples × 5 golden buckets + 3
EMIT_TARGETS × 1 emit-compile + 10 misc).**

### M20d.1 — post-implementation review follow-up ✅
Small tactical pass after GPT-5.5's post-M20d review surfaced four
items. Tests: 544 → 556 (+12, two new EMIT_TARGETS).

- **Chained field-assign rejection** (`rc.inner.field = X`): the
  M20d(4/5) check only inspected the immediate `(member obj field)`
  target. New recursive `assignmentChainPassesThroughShared` walks
  `.member` / `.index` segments back to a root and rejects if ANY
  obj's type unwraps borrows to `shared(_)`. Pinned by the existing
  `shared_field_assign_rejected.rig` test plus hand-tested chains.
- **`weak.upgrade()` first-class sema** (per GPT-5.5 #6 / SPEC
  promise): `synthMemberCall` intercepts `.upgrade()` on a
  `weak(T)` receiver and returns `optional(shared(T))` (built-in
  optional, NOT user `Option(*T)`). Rejects non-zero arity with a
  targeted diagnostic. New `weak_upgrade.rig` EMIT_TARGET runs the
  full pipeline end-to-end.
- **`formatType` disambiguation**: `optional(shared(T))` and
  `shared(optional(T))` both used to render as `*T?`, making type-
  mismatch diagnostics useless ("expected `*T?`, got `*T?`"). Now
  parenthesizes when the inner is a prefix type:
  - `*T?`   = `shared(optional(T))`
  - `(*T)?` = `optional(shared(T))`
- **Ownership-side scope-aware lookup**: `checkSharedHandleAlias`
  used a flat `sema.symbols` scan that would fire on the wrong
  binding under shadowing (two functions both with param `rc`,
  different types). Now uses the Checker's existing scope-aware
  `lookup` + `(name, decl_pos)` bridge to sema. New
  `shared_alias_shadowing.rig` EMIT_TARGET pins the correct
  behavior.
- **Grammar comment fix** (per GPT-5.5 #7): the `rig.grammar`
  conflict-budget comment said `*T?` parses as `(optional (shared T))`
  but the actual parse is `(shared (optional T))`. Comment now
  matches the SPEC and adds a pointer to SPEC §Shared Ownership
  for the user-facing precedence rule.

**Known fragility documented (not blocking)**: emit's
`handleKindOf` still uses first-match-wins global symbol scan
(would silently mis-bridge under cross-function shadowing).
Failure mode is LOUD (Zig compile error like "no field 'X' on
RcBox"), not silent. The systematic fix needs sema-side use-site
attribution (`pos → SymbolId` table built during type-check),
queued as substrate cleanup. Tracked in HANDOFF §3.

### M20d.2 — formalize `upgrade` as built-in method on `~T` ✅
Second tactical follow-up after Steve raised the `^w` upgrade-
sigil design question. Joint Claude + GPT-5.5 design pass:
**`^w` reserved as a future-sugar candidate but not shipped in
V1.** Method form is the V1 commitment.

Rationale (jointly agreed):
- Every Rig ownership sigil today is **total within its domain**
  (`<x` move, `?x`/`!x` borrows, `+x` clone, `-x` drop, `*x`
  share, `~x` weaken, `%x` raw, `@x` pin). They succeed in normal
  control flow; failures are sema-rejected or environmental (OOM).
- `^w` would be the first sigil whose normal contract includes
  failure (referent may be gone). Spending the totality invariant
  of the sigil family for one ergonomic win is the wrong trade.
- Method form makes the failure mode visible — `(*T)?` return,
  call shape signals "operation with logic, not primitive coercion."
- Sigil reservation is purely additive later: if real Rig code
  proves `.upgrade()` clunky, `^w` can be added as pure sugar
  over `w.upgrade()` with the same runtime call. The reverse
  direction (ship sigil, remove later) breaks user code.

Changes:
- Tightened `synthMemberCall`'s upgrade intercept:
  - Peels borrow wrappers via `unwrapBorrows` so `(?w).upgrade()`
    routes to the built-in path along with `w.upgrade()`.
  - Better arity message: "weak `upgrade` takes no arguments;
    got N".
  - New "wrong-receiver" diagnostic for `rc.upgrade()` (shared
    receiver, no user-defined `.upgrade()` on the underlying `T`):
    `"upgrade is only available on weak handles (~T); receiver
     here is a shared handle (*T). Use ~rc to obtain a weak
     reference, then .upgrade() on the weak."`
  - Auto-deref through shared still dispatches to user-defined
    `.upgrade()` methods when they exist (verified end-to-end
    with a `Stage.upgrade(self: ?Stage) -> Int` hand-test).
- SPEC §Weak Reference: new subsection "Built-in method:
  `upgrade() -> (*T)?`". Formalizes upgrade as a built-in on `~T`
  (status equivalent to array `.len`, future built-in optional
  methods). Includes the "why method, not sigil" rationale in
  prose so future maintainers don't re-derive the decision.
- Two new negative-test examples pinning the new diagnostics:
  - `weak_upgrade_arity` — `w.upgrade(42)` rejected
  - `upgrade_on_shared`  — `rc.upgrade()` rejected (no user method)

**`^w` reserved future-sugar candidate** (HANDOFF only, NOT
SPEC). If it ships in a future ergonomics milestone:
1. Must return `(*T)?` — never panic-on-dead-weak.
2. Must be pure sugar over `w.upgrade()` — same runtime call.
3. Method form stays canonical; sigil is shorthand.
4. Decision gated on evidence from real Rig code (reactive
   substrate validation, stdlib) that the method form is clunky.

Tests: 556 → ~566 (2 new EMIT_TARGETS × ~5 golden buckets).

**Deferred to M20e**:
- Soft scope-exit warning lint (would require a new `warning`
  severity in `ownership.zig`'s diagnostic system + a scope-exit
  walker; M20e needs the same walker for auto-drop synthesis so
  they share infrastructure).
- `weak.upgrade()` sema special-case (V1 hand-test works through
  the runtime; making it first-class via sema requires either a
  synthetic `Field` on `weak(T)` or a `synthMemberCall` intercept
  — neither belongs in the M20d critical path).

### M20e — Auto-drop discipline for `*T` / `~T` ✅
Closes M20+ item #6.5 from the "now-blocking" list. V1's documented
M20d gap — "you must explicitly `-x` or leak" — is gone. Resource
bindings auto-drop at scope exit; explicit `-rc` becomes early-drop
semantics rather than a correctness requirement.

Shipped as 5 self-validating sub-commits with one major design
redirection from GPT-5.5 during the M20e checkpoint. Tests grew
564 → 600 (+36).

#### The design redirection

The original M20e plan (mine): extend `ownership.zig` with a CFG-
aware drop-synthesis pass that walks the scope chain at every exit
point (early return, break, continue, match-arm divergence, try-
catch propagation, labeled blocks), inserts `(drop x)` IR nodes at
the right edges, and handles per-branch convergence with explicit
analysis.

GPT-5.5's intervention (saved the milestone): **don't build a mini-
MIR drop elaborator. Use Zig `defer` guards.**

For every resource binding, emit:

```zig
const rc = rig.rcNew(...) catch @panic("...");
var __rig_alive_rc: bool = true;
defer if (__rig_alive_rc) {
    __rig_alive_rc = false;
    rc.dropStrong();
};
```

Explicit discharges disarm the guard before the defer fires:

```zig
rc.dropStrong(); __rig_alive_rc = false;   // explicit -rc
rig_mv_0: { __rig_alive_rc = false; break :rig_mv_0 rc; }   // explicit <rc
__rig_alive_rc = false; return rc;   // bare return rc
```

This is correct by Zig construction across:
- branch divergence (one arm consumes, other doesn't)
- early `return`
- `break` / `continue` out of nested scopes
- `try` / `catch` propagation (defer fires on error returns)
- loop iteration scopes (each iteration re-arms its own guard)
- labeled-block expressions (M17 `if`-as-expression, M18 match-
  as-expression — defer respects Zig scope nesting)

Drop order is LIFO automatically (each defer queued at binding
site). Path-sensitivity is runtime-flag-driven, not static-
analysis-driven. Rig didn't have to build a CFG drop elaborator.

#### M20e(1/5) — Resource guards + basic discharges
- New emit helpers in `src/emit.zig`:
  - `resourceKindOfBinding(name_node)` — sound under shadowing
    via `decl_pos` lookup (distinct from the known-fragile
    `handleKindOf` name-scan).
  - `resourceKindOfBareUse(name)` — use-site classification
    (inherits the global-scan fragility).
  - `emitResourceGuard(zig_name, kind)` — the var + defer
    preamble. Uses disarm-inside-defer pattern to keep Zig's
    "never mutated" check happy in the pure-auto-drop case
    (no explicit discharge in the body).
  - `emitResourceDisarm(zig_name)` / `emitDisarmIfBareResourceName`.
- New Emitter field `pending_param_guards: ?Sexp` for resource
  parameters; `flushPendingParamGuards` consumes it at the top
  of `emitBlock` / `emitFunBody`. Resource params get the
  guard + defer right after the open brace.
- `emitSetOrBind` (fresh binding branch) installs the guard.
- `emitStmt.@"drop"` appends the disarm after the runtime call.
- `emitExprList.@"move"` for bare resource names emits a
  labeled-block expression `rig_mv_N: { disarm; break :rig_mv_N x; }`
  so the value yields cleanly into expression contexts (call args,
  RHS of bind, etc.).
- 1 new positive EMIT_TARGET: `auto_drop_basic.rig` — runs end-to-
  end without any explicit `-rc`.
- 6 existing resource-bearing EMIT_TARGETS regenerated with the
  new guard preamble (behavior unchanged at runtime — explicit
  drops disarm before defer fires).

#### M20e(2/5) — Return-disarm
- Bare `return rc` of a resource binding emits the disarm
  before the return keyword: `__rig_alive_rc = false; return rc;`
- Both `emitReturn` and `emitFunBody`'s implicit-return path
  use the new `emitReturnDisarmIfResource` helper.
- 1 new EMIT_TARGET: `factory_returns_rc.rig` — `make_counter`
  factory returns `*Counter` via plain `return rc`, runs end-to-
  end without any explicit move ceremony.

#### M20e(3/5) — Reassignment policy
- `rc = *new(...)` (reassignment of an existing resource binding)
  now drops the previous handle and re-arms the guard:
    `if (__rig_alive_rc) rc.dropStrong(); rc = ...; __rig_alive_rc = true;`
- Required a parallel fix in sema: `SymbolResolver.walkSet` was
  adding a fresh symbol on every `rc = X` (M5-era TODO comment:
  "Whether to add or reuse will be revisited when ownership
  consumes sema"). With the orphan-symbol behavior, emit's
  forward-order `handleKindOf` scan picked up the un-typed first
  symbol after a reassignment — `rc.field` failed to install
  the M20d auto-deref `.value` bridge.
  - New `SemContext.lookupInScopeOnly` for scope-local name
    lookup (no parent walk).
  - `SymbolResolver.walkSet`'s `.default` arm dedups: if a same-
    name symbol exists in the current scope, reuse it. `.fixed`
    (`=!`) and `.shadow` (`new x = ...`) still unconditionally
    add (per SPEC: those are explicit fresh declarations).
- 1 new EMIT_TARGET: `reassign_rc.rig` — exercises both the
  drop-and-rearm shape AND the bridge fix via `print(rc.value)`
  after reassignment.

#### M20e(4/5) — Coverage tests (no implementation changes)
- 3 new EMIT_TARGETS pinning M20e behavior across the M20d-
  supported control-flow matrix. No emit changes needed — Zig's
  defer behaves correctly out of the box:
  - `auto_drop_if_else.rig` — branch divergence (one arm drops,
    one reads through). The design hazard GPT-5.5 highlighted;
    runtime alive flag is path-sensitive without static analysis.
  - `auto_drop_early_return.rig` — `return` from inside a
    nested conditional. Zig fires defer on both return paths.
  - `auto_drop_in_loop.rig` — resource declared inside a while
    body. Each iteration enters a fresh scope and the defer
    fires at end-of-iteration. Three allocations, three drops.

#### M20e(5/5) — Docs
- SPEC §Shared Ownership rewrite of the "V1 Drop Discipline"
  subsection: auto-drop is the V1 commitment; explicit `-x` is
  documented as early-drop semantics; discharge marker table;
  panic / unreachable behavior documented.
- ROADMAP M20e milestone entry (this section).
- HANDOFF refresh for the next session: TL;DR points at the
  reactive substrate path (item #7 Cell or #8 closure capture)
  as next; M20e is no longer queued.

#### Coverage gaps (deferred to follow-up)
- **`try_block` lowering with resource locals**: blocked on
  the pre-existing M20+ #14 gap (try-block emit still emits
  `@compileError`). Once try-block lands, defer-guard should
  Just Work — error returns run defers same as success returns.
- **`<-` move-assign LHS reassignment with resource RHS**: the
  M20e(3/5) tests cover `=` reassignment but not the parallel
  `<-` form. The implementation path should be identical (kind
  dispatched in `emitSet`); just not pinned as a golden yet.
- **Compound assignment edge case with non-`+=` syntax inside
  nested blocks** (`i = i + 1`): pre-existing `scanMutations`
  scoping issue, unrelated to M20e but surfaced by the loop
  test. Workaround: use `i += 1`. Document as a separate cleanup.

**Tests across M20e: 564 → 600 (+36). All green.**

### M20e.1 — post-implementation review fixes ✅
Tactical pass after GPT-5.5's M20e post-implementation review
surfaced two correctness bugs and one design debt. Tests grew
600 → 606 (+6).

**Must-fix 1: reassignment double-drop on fallible RHS.**

The M20e(3/5) reassignment lowering was:

```zig
if (__rig_alive_rc) rc.dropStrong();
rc = <rhs>;
__rig_alive_rc = true;
```

If `<rhs>` propagated an error (`expr!`), Zig unwinds the scope
with `__rig_alive_rc == true` but the old handle had already
been dropped — the scope-exit defer would call `dropStrong()` on
a freed box. UAF on the failure path.

Fix: disarm INSIDE the drop-old block, before evaluating RHS:

```zig
if (__rig_alive_rc) { rc.dropStrong(); __rig_alive_rc = false; }
rc = <rhs>;
__rig_alive_rc = true;
```

If RHS propagates, the flag is false and the defer is a no-op
(correct — the new handle never landed).

**Must-fix 2: scoped resource classification.**

M20e(1/5)'s `resourceKindOfBareUse` did first-match-wins on
`sema.symbols.items` — a flat scan. Under cross-function
shadowing (`fun a() { x = ~rc }`, `fun b() -> *U { x = *U(...);
return x }`) the scan could mis-classify `x` and silently skip
the disarm in `b()`'s `return x`. The function defer would then
drop the returned handle, leaving the caller with a dangling
pointer.

Fix: scope-aware resource metadata carried in the emitter's own
scope table. New file-scope `ResourceKind` enum, new
`SymbolEntry.resource_kind` field, new
`declareWithResourceKind(rig_name, zig_name, ?ResourceKind)` +
`lookupResourceKind(rig_name) ?ResourceKind`. Each binding /
param records its kind at declaration time (sound under
shadowing per `decl_pos`); use sites query scope-aware. Both
`resourceKindOfBareUse` AND `handleKindOf`'s `.src` arm rewired
to use the scoped lookup.

**Recommended 3: `<-` move-assign with resource RHS.**

Surfaced during M20e.1's regression-test sweep — actually a
THIRD must-fix. `rc2 <- rc` was emitting a bare pointer copy
without disarming the RHS source, double-dropping at scope exit
(segfault on the second `dropStrong`).

Fix: in `emitSet`, for the `.@"move"` kind, synthesize a
`(move RHS)` wrapper around the RHS Sexp before passing to
`emitSetOrBind`. The resource-aware `(move ...)` emit path then
installs the disarm via the M20e(1/5) labeled-block expression.

**Recommended 4: resource-temporaries SPEC note.**

SPEC §Shared Ownership now documents the named-binding RAII
boundary: M20e auto-drop applies to named bindings and params,
NOT to unbound `*expr` temporaries. Bind to a name and let the
compiler manage it. A future ergonomics milestone may close
this gap with rejection or hidden-temp lowering; the V1
contract is binding-only.

**Recommended 5: outer-scope assignment audit (HANDOFF only).**

The M20e(3/5) `SymbolResolver.walkSet` dedup was scoped to
same-scope only. Outer-scope assignment (`x = ...` in an inner
scope when `x` only exists in an outer) currently still creates
a fresh inner symbol — possibly inconsistent with SPEC's
"implicit shadowing is illegal" rule. Flagged in HANDOFF §8 for
audit; not blocking M20e.

**Tests**: 2 new regression EMIT_TARGETS:
- `auto_drop_shadow_across_fns.rig` — pins the scoped-resource-
  classification fix (would have segfaulted pre-M20e.1).
- `move_assign_rc.rig` — pins the `<-` move-assign fix (would
  have segfaulted pre-M20e.1).

**Tests across M20e + M20e.1: 564 → 606 (+42). All green.**

### M20f — Interior mutability via `Cell(T)` ✅
Closes M20+ item #7 from the "now-blocking" list. The user-facing
escape hatch the M20d diagnostics already promised:

  "cannot call write-receiver method through a shared handle (`*T`);
   use an interior-mutable type (planned `Cell(T)` in M20+ item #7)"

`Cell(T)` is a built-in generic nominal pre-registered in sema at
module-scope creation, runtime-baked in `src/runtime.zig`
parallel to `RcBox` / `WeakHandle`. End-to-end working:

  sub main()
    rc: *Cell(Int) = *Cell(value: 0)
    rc.set(5)
    print(rc.get())     # 5

The whole V1 ownership stack composes through Cell:
M20b parameterized_nominal + M20d shared + M20e auto-drop +
M20d read-only auto-deref + M20f synthetic Cell methods + M20f
Copy-only enforcement. NO new sema dispatch for the shared
case — Cell's `get` / `set` are ordinary read-receiver methods;
M20d's existing `?self`-through-shared rule accepts them.

Shipped as 4 self-validating sub-commits with one GPT-5.5 design
pass at the start. Tests grew 622 → 634 (+12).

#### Design decisions (per GPT-5.5's M20f checkpoint)

1. **Cell is runtime-baked**, not a Rig source file. Parallel to
   `RcBox` / `WeakHandle`. Future stdlib types may live in
   `std/*.rig` once a layout coalesces; Cell is fundamental
   enough that "it's a builtin" is the right mental model.

2. **Synthetic ordinary methods, not ad-hoc sema intercept.** My
   original plan was to special-case Cell's `set` at
   `synthMemberCall` (parallel to M20d.2's `.upgrade()`
   intercept). GPT-5.5 pushed back: Cell is a NOMINAL type,
   modelable via M20b's generic-method machinery. Register Cell
   as a generic_type with synthetic methods whose first param is
   `?Self`; M20d auto-deref then permits them through shared
   naturally. No write-receiver bypass needed. Significantly
   cleaner than the intercept path.

3. **`set(self: *Self)` in runtime, NOT `*const Self` +
   `@constCast`.** My original plan was `@constCast` to mutate
   through a const view. GPT-5.5 vetoed: only valid if the
   underlying storage is actually mutable. Use `*Self` and emit
   Cell bindings as `var`. `=!` (fixed) still prevents
   rebinding at the Rig level — SPEC permits interior mutation
   through fixed bindings.

4. **V1 restriction: `T` must be Copy.** The critical hazard I
   missed. Non-Copy T (`Cell(*User)`, `Cell(NominalStruct)`,
   etc.) is unsound without replace/take/Drop semantics — `set`
   would overwrite the previous value without releasing
   resources. Enforced at sema time via the new
   `isCopyTypeForCell` predicate. Deferred until V1 grows the
   resource-aware replacement substrate.

#### M20f(1/4) — Built-in registration + Copy-only enforcement
- `src/runtime.zig`: new `rig.Cell(T)` type with
  `get(self: Self) T` (value receiver, Zig-copy) and
  `set(self: *Self, value: T)`.
- `src/types.zig`: new `registerBuiltins(ctx, module_scope)`
  step in `check`, runs BEFORE resolver walks user IR. Adds Cell
  as a `.generic_type` symbol with detached `T` param + Cell's
  `type_params = [T]` + synthetic `value: T` data field.
- New `SemContext.cell_sym_id` tracks Cell's SymbolId.
- `resolveType.@"generic_inst"` fires the Copy-only diagnostic
  when the target sym is Cell and the type arg is non-Copy.
- `src/emit.zig`: new `isBuiltinNominalName(name)` predicate;
  `(generic_inst Cell ...)` emit prefixes `rig.` to the name so
  the resolved Zig type is `rig.Cell(T)`.

#### M20f(2/4) — Synthetic methods + var-emit
- `registerBuiltins` extends Cell's `fields` slice with two
  synthetic methods:
  - `get` with `fn_ty = function([borrow_read(Cell(T))],
    returns = T)` and `receiver = .read, is_method = true`
  - `set` with `fn_ty = function([borrow_read(Cell(T)), T],
    returns = Void)` and `receiver = .read, is_method = true`
- M20b's `lookupMethod` machinery picks them up automatically
  for both bare Cell and `*Cell(T)` receivers.
- Emit: new `isInteriorMutableBinding(name_node)` predicate;
  `emitSetOrBind` forces `var` for Cell bindings. `_ = &<name>;`
  pacifies Zig's "never mutated" check for read-only Cell
  usage (`c: Cell(Int) = ...; print(c.value)` with no `.set`).

#### M20f(3/4) — `*Cell(T)` integration (the payoff)
Two emit-side fixes to make the one-step pattern work:

- **Expected-type propagation through `(share x)`**: `checkExpr`
  for `(share x)` with expected `shared(T)` recursively
  `checkExpr(x, T)`. The inner Cell constructor sees the
  expected `Cell(Int)` and drives M20b's substitution machinery
  correctly. Mirrors the M20b(4/5) expected-type-driven
  construction logic for plain bindings.
- **Explicit-typed struct literal for built-in inner**: emit's
  `(share inner)` previously produced
  `rig.rcNew(<inner-emit>)` where `<inner-emit>` for a
  generic_type was an anonymous struct literal `.{ ... }`.
  `rig.rcNew(anytype)` has no type context — Zig inferred a
  synthetic comptime struct mismatching the expected
  `*RcBox(rig.Cell(i32))`. Fix: when inner is a built-in
  nominal call AND the LHS type wraps the same built-in
  (`shouldExplicitTypeShareInner`), emit the inner as
  `rig.Cell(i32){ .value = ... }` (explicit-typed). New
  Emitter field `current_set_type: ?Sexp` threads the LHS type
  Sexp from `emitSetOrBind` saved/restored on entry/exit.

#### M20f(4/4) — Docs
- SPEC §Shared Ownership new "Interior mutability via
  `Cell(T)`" subsection. Documents the API, the V1 Copy-only
  restriction, the diagnostic pointing at the future
  replace/take/Drop substrate.
- ROADMAP M20f milestone entry (this section). M20+ #7 → ✅.
- HANDOFF refresh: next milestone is M20g (closure capture
  modes), the last V1 substrate piece before rig-reactive
  validation (Phase B of REACTIVITY-DESIGN) becomes reachable.

#### Tests across M20f
4 new examples:
- `cell_basic.rig` — type registration + Copy field access
- `cell_non_copy_rejected.rig` — Copy-only diagnostic
- `cell_methods.rig` — bare Cell get/set
- `cell_shared.rig` — the user-facing `*Cell(T)` payoff

**Tests across M20d + M20e + M20f arcs: 496 → 634 (+138).**

### M20f.1 — post-implementation review fixes ✅
GPT-5.5's M20f review surfaced two correctness issues and one
soundness gap. Tests grew 634 → 648 (+14).

**Fix 1: builtin `decl_pos` sentinel.** `registerBuiltins` was
using `decl_pos = 0` for Cell and its generic param T, plus the
synthetic fields. Emit's bridge helpers (`isInteriorMutableBinding`,
`resourceKindOfBinding`) match source bindings to sema symbols
via `decl_pos`. A real user binding starting at byte 0 would
collide with the builtin and the scan would return the wrong
symbol — silently classifying a Cell binding as non-Cell (`const`
emit; Zig errors on `c.set`). Fix: new `builtin_decl_pos =
std.math.maxInt(u32)` sentinel for all built-in registrations;
real source positions can't reach that value. Defense-in-depth:
both bridge helpers also cross-check the symbol name now (was
decl_pos-only).

**Fix 2: `Cell.set` addressability check.** Sema was accepting
`c.set(1)` on:
- Cell-typed function parameters (Zig params are const → Zig
  errors "cast discards const qualifier")
- borrowed Cell receivers (`?Cell(T)` / `!Cell(T)`)
- rvalue temporaries (`make_cell().set(...)`)

Each case was Zig-rejected with a confusing low-level error.
Fix: new `isAddressableCellReceiver` helper in `synthInstanceCall`.
When the method's nominal is Cell and the name is `set`, the
receiver must unwrap to either a bare local binding (sema kind
= `.local`) or `shared(Cell(_))` (heap-allocated, mutable via
pointer). Anything else fires a clear Rig diagnostic suggesting
the two valid shapes. Cell.get is unaffected (it returns a copy
and doesn't need addressability).

**Fix 3: built-in name reservation.** Emit's
`isBuiltinNominalName` is a string-equality check ("Cell"). A
user-declared `type Cell(T)` or `struct Cell` would have
shadowed the builtin in sema (latter declaration wins) and
emit's prefix `rig.` would have been mis-applied to the user
type. Fix: new `isReservedBuiltinName` predicate; `SymbolResolver.
walkGenericType` and `walkNominalType` reject reserved names
with a clean diagnostic.

**Tests** (3 new EMIT_TARGETS):
- `cell_set_on_param_rejected.rig` — pins the addressability
  diagnostic.
- `cell_reservation_rejected.rig` — pins the name-reservation
  diagnostic.
- `cell_shared_move_assign.rig` — pins the M20d+M20e+M20f
  composition under `<-` move-assign (regression test the
  reviewer recommended).

**Tests across M20f + M20f.1: 622 → 648 (+26).**
**Tests across M20d + M20e + M20f arcs: 496 → 648 (+152).**

### M20g — Closure captures with mode-aware ownership effects ✅

The last V1 substrate piece. Lambdas now capture outer bindings
via explicit mode sigils (`|x|` / `|+x|` / `|~x|` / `|<x|`),
lower to anonymous Zig structs with `pub fn invoke(self:
*@This())` methods, and integrate with M20e auto-drop guards at
the closure-instance lifetime. Shipped as 5 sub-commits (+ one
post-review polish) with a locked GPT-5.5 design pass at the
checkpoint.

**Sub-commits**:

- **M20g(1/5)** — Grammar + IR: lambda IR extends from 4 to 5
  children (`(lambda CAPTURES PARAMS RETURNS BODY)`). New tags:
  `captures`, `cap_copy`, `cap_clone`, `cap_weak`, `cap_move`.
  Lexer's `isCapturePipe` probe accepts the `+`/`<`/`~` sigil
  prefix. Conflict count unchanged at 38.
- **M20g(2/5)** — Sema + ownership: new `SymbolKind.capture`;
  `SymbolResolver.walkLambda` binds captures before params (so
  collisions diagnose cleanly); `ExprChecker.synthLambda` walks
  the body and runs the mode-vs-type validation table;
  `Binding.is_closure` on the ownership side; new
  `in_call_callee`/`in_set_rhs` context flags drive the
  non-escaping / non-copyable enforcement; dedicated
  `walkLambda` in ownership.zig applies cap_move's outer-state
  effect.
- **M20g(2.1)** — Polish (per GPT-5.5's review): tailored
  "cannot reassign closure binding" diagnostic instead of the
  generic `=!` fixed-binding message users never wrote.
- **M20g(3/5)** — Emit: lambda binding lowers to `var
  <name> = struct { cap_<n>: T, pub fn invoke(self: *@This())
  RT { ... } }{ .cap_<n> = <init> }; _ = &<name>;`. Capture
  refs inside the body remap to `self.cap_<n>` via a
  scope-frame push, NOT a global name scan. `f()` lowers to
  `f.invoke()` for closure bindings. Return type stashed in
  `SemContext.lambda_return_types` (keyed by lambda first src
  pos) by sema and read by emit.
- **M20g(4/5)** — Auto-drop: per RESOURCE capture, emit an
  M20e-style guard + defer at the closure-instance's
  enclosing scope. Drop expression accesses `<closure>.cap_<n>`
  so it's keyed on closure-binding lifetime, not per-invoke.
  LIFO defer ordering means closure-capture drops fire before
  the outer's bare-binding drops.
- **M20g(5/5)** — Docs: SPEC §Lambdas with capture-mode table;
  ROADMAP M20+ #8 → ✅; HANDOFF refresh.

**Locked design decisions (GPT-5.5)**:

1. Default `|x|` is Copy-only. Resources require explicit mode.
2. NO `|*x|` capture mode (`*expr` already means Rc-construct).
3. V1 closures are strictly non-escaping (no return / store /
   call arg / record field / non-bind RHS).
4. Closure values are non-copyable AND implicitly fixed.
5. Resource captures' guards live at the closure-instance
   enclosing scope (NOT per-invocation).
6. Ownership-side `Binding.is_closure` flag (no `Type.closure`
   variant — would cascade into compatible / formatType /
   emit's type lowering for no V1 benefit).

**Tests** (5 new positive + 6 new negative examples):

Positive (EMIT_TARGETS):
- `closure_capture_copy.rig` — Copy capture; outer Int untouched
- `closure_capture_clone.rig` — clone-capture of `*Cell(Int)`;
  refcount discipline verified end-to-end
- `closure_capture_weak.rig` — weak-capture; multiple invokes
- `closure_capture_move.rig` — move-capture; outer disarmed

Negative (sema/ownership goldens):
- `closure_resource_default_rejected.rig` — visible-effects
  diagnostic for `|rc|` on `*T`
- `closure_copy_rejected.rig` — non-copyable closure
- `closure_escape_return_rejected.rig` — V1 non-escaping
- `closure_escape_arg_rejected.rig` — closure as call arg
- `closure_capture_param_collision_rejected.rig` — name conflict
- `closure_nested_capture_rejected.rig` — nested-lambda capture
- `closure_reassign_rejected.rig` — closure-fixed reassignment

**Tests across M20g (1/5) → (4/5) + (2.1): 648 → 700 (+52).**

**V1 substrate**: COMPLETE. M20a (methods/self) + M20b (generic
instances) + M20c (generic enums) + M20d (shared/weak handles)
+ M20e (auto-drop via defer-guards) + M20f (Cell interior
mutability) + M20g (closure captures) all compose end-to-end.
The next major arc is Phase B of REACTIVITY-DESIGN.md —
rig-reactive validation, where Cell / Memo / Effect demonstrate
the substrate is sufficient for the reactivity stress test.

### M20h — Owned / escaping closures ✅

Closes the biggest M20g-deferred limitation: `*Closure(fn |...|
body)` produces a heap-owned closure handle that escapes its
defining scope. The retained-Effect callback story Phase B's
reactive canary needs is now expressible — store a `*Closure()`
in a struct field, return one from a builder, alias via `+cb`,
weaken via `~cb`, drop the originating handle, invoke through
a surviving clone, all without UAF.

**Locked design (GPT-5.5, entry 17)**:

1. **Surface**: `cb: *Closure() = *Closure(fn |+count| body)`.
   Explicit `*` makes the heap allocation visible; mirrors the
   M20f `*Cell(value: 0)` constructor shape.
2. **Type spelling**: `Closure()` only in M20h (zero arity).
   Arity / return-type variants deferred. Bare `Closure` (no
   parens) and `Closure(Int)` (non-zero args) both fire
   tailored diagnostics.
3. **ABI**: type-erased `rig.Closure0` vtable (`ctx:
   *anyopaque`, `invoke_fn`, `drop_fn`, `allocator`). Each
   closure literal generates a unique anonymous env struct
   matching its capture list; `ctx` is type-erased so all
   `*Closure()` literals share a single surface type
   (`*rig.RcBox(rig.Closure0)`).
4. **Drop model**: `RcBox(T).dropStrong()` gains an
   `@hasDecl(T, "__rig_drop")`-gated hook (wrapped in a
   comptime `hasRigDrop` predicate for non-container payload
   safety). On last strong, `Closure0.__rig_drop` fires →
   per-literal `rigDrop` thunk → capture drops + env free.
   Critically, drop is NOT done from each binding's scope-
   exit defer — the earlier ABI proposal that did so would
   UAF on `cb2 = +cb; -cb; cb2()`.
5. **Ownership**: owned closure is a regular `*T` shared
   handle. Clone/move/weak/return/store all flow through the
   existing `*T` paths. The closure binding is NOT marked
   `is_closure` (that flag is for bare lambdas); a new
   `is_owned_closure` flag triggers only the
   `cb()` → `cb.value.invoke()` call rewrite.
6. **Lambda escape relaxation**: a dedicated ownership flag
   `in_owned_closure_constructor_arg` permits the lambda
   inside `*Closure(...)` to escape its defining scope. The
   M20g non-escaping rules still apply to bare lambdas and
   to lambdas at any other call-arg position.
7. **Grammar**: new narrow `FN captures inline_body` lambda
   form (with `inline_body = call → (block 1)`) so the
   single-call body shape parses inside `(...)` parens.
   Conflict count: 38 → 69 (all benign S/R, prefer-shift).

**Sub-commits**:

- **M20h(1/5)** — Runtime + type spelling. `Closure0` vtable
  + `hasRigDrop` predicate + `RcBox.dropStrong` hook in
  `runtime.zig`. `Closure` registered as zero-arity
  builtin in `types.zig`. Emit lowers `*Closure()` →
  `*rig.RcBox(rig.Closure0)`. Diagnostics for bare `Closure`,
  `Closure(Int)`, and `type Closure(T)` redefinition.
- **M20h(2/5)** — Sema for construction + invocation.
  `detectOwnedClosureConstruction` intercepts the share-call-
  lambda shape in synthExpr; `isOwnedClosureHandleType`
  drives `cb()` typing. Bare `Closure(fn ...)` rejected.
  Grammar extension for inline-call lambda body. Conflict
  count: 38 → 69.
- **M20h(3/5)** — Ownership relaxation.
  `in_owned_closure_constructor_arg` context flag set by a
  new `walkShare` dispatcher when the inner is owned-closure
  construction. `walkLambda` accepts the new flag for the
  escape check; resets it inside the body so nested
  constructions don't inherit. Pre-M20h `return *Closure(fn
  ...)` (rejected by M20g) now passes.
- **M20h(4/5)** — Emit construction + invocation. The
  load-bearing emit work. `emitOwnedClosureConstruction`
  produces a labeled-block expression with an inline
  anonymous env struct (`fn rigInvoke` + `fn rigDrop`
  thunks); env is heap-allocated, captures init via reuse
  of M20g's `emitClosureInit`, wrapped in `Closure0` + fed
  through `rig.rcNew`. `emitCall` adds the M20h
  `cb.value.invoke()` rewrite. `SymbolEntry.is_owned_closure`
  flag set by `emitSetOrBind` via three signals (RHS shape
  / type annotation / sema-inferred type).
- **M20h(5/5)** — Tests + PB1 canary + docs. 4 positive
  examples (in EMIT_TARGETS) + 4 negative (sema goldens).
  `examples/reactive_canary.rig` updated to use a retained
  M20h closure (PB1).

**Tests across M20h (1/5) → (5/5): 706 → 746 (+40).**

**Examples added**:

Positive (EMIT_TARGETS):
- `owned_closure_basic.rig` — stack-local construction +
  invocation; verifies the canonical `cb: *Closure() =
  *Closure(fn |+count| ...)` shape.
- `owned_closure_escape.rig` — factory function returns
  `*Closure()`; counter persists across the local Cell's
  drop.
- `owned_closure_clone.rig` — `cb2 = +cb; -cb; cb2()` —
  the UAF-prevention test that pins the
  `__rig_drop`-on-last-strong design.
- `owned_closure_move.rig` — `fn |<count| ...` move-capture.

Negative (sema goldens):
- `owned_closure_bare_rejected.rig` — `Closure(fn ...)` no `*`
- `owned_closure_no_lambda_rejected.rig` — non-lambda arg
- `owned_closure_args_rejected.rig` — `cb(args)` invocation
- `owned_closure_bare_type_rejected.rig` — bare `Closure` type

**Phase B status after M20h**: PB0 ✅, PB1 effectively
included via the reactive canary refresh, M20i (resource-
aware `Vec(T)`) next when Phase B needs multi-subscriber
notification.

### M20i — Resource-aware `Vec(T)` container ✅

The first user-facing builtin OWNING value type beyond
`*T` / `~T` handles. Vec(T) owns its backing buffer and
correctly cascades drops to its elements when it goes out
of scope. Designed via two GPT-5.5 checkpoints
(conversation `c_5c1d09d53ebe2f62` entries 23 + 24):
**entry 23** locked the scope (M20i alone, subscriber-
shaped regression test mandatory, Cell-non-Copy stays
separate and conditional); **entry 24** locked the design
(`Vec(T)` is a resource value type, write-receiver
methods, Copy-T-only `get`/`pop`, hybrid marker +
`__rig_drop` dispatch).

The biggest GPT-5.5 correction in the design pass: **Vec
is a resource VALUE TYPE**, not just a container with
resource elements. Even `Vec(Int)` (Copy element) owns a
buffer; bare copy is unsafe; move-only transfer; auto-
drop guards at scope exit.

**Sub-commits**:

- **M20i(1/5)** `4675fca` — Runtime + type spelling.
  `rig.Vec(T)` generic struct with allocator / buf / len /
  cap + init / push / length / get / pop / clear /
  `__rig_drop`. `dropElement` helper with hybrid shape +
  marker dispatch. Markers added to RcBox / WeakHandle.
  Sema registers Vec as a one-arg builtin generic_type.
  `isValidVecElementType` enforces V1 element restrictions.
  Emit `Vec(T)` → `rig.Vec(T)`; `*Vec(T)` →
  `*rig.RcBox(rig.Vec(T))`.

- **M20i(2/5)** `b774e8b` — Sema methods + constructor.
  5 methods registered with substituted self-receiver
  types (`?Vec(T)` for read receivers, `!Vec(T)` for
  write). `checkVecConstruction` recognizes `Vec()` and
  `Vec(capacity: N)` against the expected
  `parameterized_nominal{Vec, [T]}`, BEFORE the generic-
  constructor path (Vec has no data fields — `capacity`
  is a constructor hint, not a field-init).

- **M20i(3/5)** `13f079b` — Ownership rules for
  Vec-as-resource-value. `checkSharedHandleAlias`
  extended: bare Vec use in call args or binding RHS fires
  "would copy the buffer pointer and double-free; use
  `<v` to move ownership". Move (`<vec`) and drop (`-vec`)
  semantics work via existing M2 machinery unchanged.

- **M20i(4/5)** `2ef41b6` — Emit. New `ResourceKind.vec_value`
  variant routes Vec stack-locals through a `__rig_drop()`
  scope-exit guard. `tryEmitVecConstruction` lowers
  `Vec()` / `Vec(capacity: N)` to
  `rig.Vec(T).init(allocator)` /
  `initCapacity(allocator, N) catch panic`. `-vec`
  discharge handled by the `.@"drop"` arm extension.
  `isInteriorMutableBinding` extended so Vec stack-locals
  emit as Zig `var` (mutating methods need it).

- **M20i(5/5)** — Tests + examples + docs (this entry).

**Tests across M20i (1/5) → (5/5): 754 → 804 (+50).**

**Examples** (5 positive in EMIT_TARGETS + 5 negative):

Positive:
- `vec_basic.rig` — Vec(Int) push / length, basic Copy case.
- `vec_capacity.rig` — Vec with capacity hint.
- `vec_shared.rig` — `*Vec(Int)` shared variant.
- `vec_move_handle.rig` — Vec(*Cell(Int)) with `<` move push.
- `vec_subscribers.rig` — **the mandatory regression test**
  per GPT-5.5's M20i scoping review. `Vec(*Closure())`
  with `+` clone push; closures invoked separately; scope
  exit cleans up the full chain (Vec → closures → captured
  Cell). Output: `11`.

Negative (sema/ownership goldens only):
- `vec_bad_element_rejected.rig` — `Vec(User)` with a
  custom struct element type.
- `vec_bare_copy_rejected.rig` — `v2 = v1` (double-free).
- `vec_bad_kwarg_rejected.rig` — `Vec(size: 10)` instead
  of `Vec(capacity: 10)`.
- `vec_positional_arg_rejected.rig` — `Vec(10)` (no
  positional args).
- `vec_redefine_rejected.rig` — `struct Vec` (reserved
  builtin name).

**SPEC §"Resource-aware containers via `Vec(T)` (M20i)"**
added with the V1 API, element-type restrictions,
resource-value ownership rules, push-arg visibility, and
auto-drop discipline. V1 deferred features explicitly
called out (get/pop on resource T, insert/remove,
iteration, persistent Vec, Cell-non-Copy interaction).

**Phase B status after M20i**: PB0 ✅, M20h ✅ (PB1 folded),
M20i ✅ (Layer 6 in the substrate ladder). PB2 + PB3 are
the remaining Phase B work, unblocked. Cell-non-Copy
(M20i.x) is conditional — GPT-5.5's observation that PB2
can model Reactor as an owned mutable object means Cell-
non-Copy may never be needed.

### PB2 — Signal: single-subscriber Cell → Effect notification ✅

The minimum viable reactive primitive. `Signal(T)` combines a
Cell-like value slot with one optional retained `*Closure()`
subscriber; `set` updates the value AND invokes the subscriber
synchronously. Proves the load-bearing reactivity claim
("retained closure observes state change") without committing
to multi-subscriber semantics — those land in PB3 once
resource-Vec iteration is designed.

Locked at GPT-5.5 conversation entry 25 (Phase B post-M20i
checkpoint). The locked decisions:

1. **Single-subscriber Signal, not Reactor or Cell extension.**
   GPT-5.5: "PB2 should prove one retained closure can be
   subscribed and invoked by state change. It should not solve
   subscriber-list iteration." The canary discipline (Q1 of
   Phase B) drives this scoping.
2. **`Signal(T)` wrapper, not Cell-extension.** Keeps Cell
   primitive; avoids needing `*Cell(Vec(...))` (which would
   force Cell-non-Copy relaxation).
3. **Read-receiver methods (interior mutability).** Matches
   Cell's pattern: `signal.set(v)` not `(!signal).set(v)`. The
   runtime trusts itself to mutate through `*Self`.
4. **Synchronous push on set.** PB3 will introduce mark-dirty
   + queued flush; PB2 ships the simplest possible
   notification path.

**Sub-commits**:

- **PB2(1/3)** `5918a15` — `Signal(T)` primitive: runtime
  (`pub fn Signal(comptime T)`) + sema registration (one-arg
  generic_type with `get`/`set`/`subscribe` methods +
  synthetic `value` field) + emit (via the existing Cell-
  style construction path). `isInteriorMutableBinding`
  extended for Signal.
- **PB2(2/3)** `ea91145` — Canary extension. New PB2 block
  in `examples/reactive_canary.rig` demonstrating the
  full subscribe-then-set-then-observe chain. Canary now
  outputs `1\n3\n13\n7\n99` across the PB0 + M20g + M20h
  + PB2 layers.
- **PB2(3/3)** — Docs (this entry + SPEC §Signal + HANDOFF
  refresh).

**Tests**: 804/804 still pass (PB2(1/3) added the Signal
primitive without new examples; PB2(2/3) regenerated the
reactive_canary goldens which were already in EMIT_TARGETS).

**PB3 deferred**. Per the joint design pass, PB3 (Memo +
batching + topology) requires multi-subscriber notification,
which requires `Vec(*Closure())` iteration. That's a separate
substrate milestone (M20i.1 / M20j) that should be designed
under real pressure when PB3 forces it. The
`examples/vec_subscribers.rig` regression test already
validates the drop-cascade discipline; the missing piece is
the notify-iteration primitive itself.

**Phase B status after PB2**: PB0 ✅, M20h ✅, PB1 ✅, M20i ✅,
PB2 ✅. PB3 pending (depends on M20i.1 / M20j). The reactive
canary now demonstrates the full single-subscriber chain
end-to-end; multi-subscriber generalization is the only
remaining Phase B work, gated on substrate maturity rather
than design uncertainty.

### M20i.1 — Resource-Vec iteration via `for x in ?vec` ✅

The substrate prerequisite for PB3 (multi-subscriber Signal).
External `for x in vec` walks a `Vec(T)`, with the source mode
discriminator (`iter` for Copy T, `read` for resource T)
driving sema's element-binding shape, the ownership-layer
loop-source borrow + element-as-loop-borrow consume
restrictions, and emit's Shape X (resource: slot alias +
scope-frame rewrite) vs Shape Y (Copy: plain const) lowering.

Locked at the M20i.1 / M20j design checkpoint with GPT-5.5
(conversation `c_5c1d09d53ebe2f62`, entry 26). Steve had
originally proposed an internal `vec.foreach(fn (e) e())`
callback method; GPT-5.5 pushed back hard on **Option B,
external `for` over Vec, read-only** because:

1. External `for` reuses the existing grammar (no conflict-
   count bump from 69) and the language's existing ownership-
   mode vocabulary (`iter` / `read` / `write` / `move` / `ptr`).
2. No new callback ABI or lambda-with-params grammar work.
3. The `?vec` source mode does the borrow enforcement
   naturally — `for cb in ?subs` read-borrows `subs` for the
   loop body, so `(!subs).push(...)` inside fires the standard
   M2 borrow-conflict diagnostic.
4. By-value resource elements would silently copy a strong
   handle pointer without bumping refcount; binding as a
   borrowed view of the Vec slot (`cb : borrow_read(*Closure())`)
   makes the "this isn't owned" semantics visible at both the
   sema and emit layers.

The follow-up checkpoint (entry 27) locked the emit shape
split (Shape X for resource elements with `&__rig_elem_X` slot
alias + scope-frame rewrite to `__rig_elem_X.*`; Shape Y for
Copy elements with a plain `const X = __rig_p[__rig_i]`).

**Sub-commits:**

| Commit | What it shipped |
|---|---|
| `65a3c44` M20i.1(1/4) | Sema: `checkForStmt` recognizes Vec(T) sources, validates mode against element resource-ness (resource T requires `?vec`), binds element as `borrow_read(T)` for resource T / `T` for Copy T. `isOwnedClosureHandleType` peels `borrow_read`/`borrow_write` so a borrowed `*Closure()` (the loop element type) is still recognized as callable. |
| `ee4f9e8` M20i.1(2/4) | Ownership: new `is_loop_borrow` binding flag. `walkFor` installs a scope-bound read borrow on the source + marks the element with `is_loop_borrow=true` + `borrow_root_index` for auto-release at popScope. New `rejectLoopBorrowOp` helper hooks consume-op sites: `+cb` (clone) and `~cb` (weak) in the `.@"clone"`/`.@"weak"` arm; `<cb` (move) in `walkBorrow` op=move_op; `-cb` (drop) in `walkDrop`; `return cb` in `walkReturn`; bare-name alias in `checkSharedHandleAlias`. |
| `7049da3` M20i.1(3/4) | Emit: `emitFor` branches on `vecSourceForEmit` to a new explicit-walk lowering. Shape Y (Copy T): bind by value as `const`. Shape X (resource T): declare `__rig_elem_X = &__rig_p_X[__rig_i_X]` slot alias + install `rig_name → __rig_elem_X.*` mapping in the emit scope frame. For `*Closure()` elements, mark `is_owned_closure=true` so `cb()` lowers to `__rig_elem_X.*.value.invoke()` via the existing M20h call-site rewrite. Generated names allocated in `name_arena`. |
| M20i.1(4/4) | Tests + canary refresh + docs (this entry). |

**Tests across M20i.1 (1/4) → (4/4): 804 → 832 (+28).**

**Examples** (2 positive in EMIT_TARGETS + 4 negative):

Positive:
- `vec_for_copy.rig` — `for n in nums` over `Vec(Int)`. Shape Y.
- `vec_for_notify.rig` — **the mandatory subscriber-shaped
  regression test** (analog of M20i(5/5)'s `vec_subscribers.rig`,
  but exercising the new `for cb in ?subs` primitive). Three
  cloned-into-Vec closures, foreach via `for`, counter advances
  to `111`. Shape X.

Negative (sema/ownership goldens only):
- `vec_for_no_borrow_rejected.rig` — `for cb in subs` without
  `?` over resource Vec.
- `vec_for_write_during_iter_rejected.rig` — `(!subs).push(...)`
  inside `for cb in ?subs` body.
- `vec_for_clone_elem_rejected.rig` — `+cb` on a loop-borrow
  alias.
- `vec_for_drop_elem_rejected.rig` — `-cb` on a loop-borrow
  alias.

**Canary refresh.** `examples/reactive_canary.rig` now ends
with a multi-subscriber Vec notification block:

```rig
notes: *Cell(Int) = *Cell(value: 0)
one:   *Closure() = *Closure(fn |+notes| notes.set(notes.get() + 1))
ten:   *Closure() = *Closure(fn |+notes| notes.set(notes.get() + 10))
cent:  *Closure() = *Closure(fn |+notes| notes.set(notes.get() + 100))
subs: Vec(*Closure()) = Vec()
(!subs).push(+one); (!subs).push(+ten); (!subs).push(+cent)
for cb in ?subs
  cb()
print(notes.get())  # 111
```

Canary output: `1\n3\n13\n7\n99\n111` (PB0 → PB1 → PB2 → M20i.1).

**SPEC §"Vec iteration via `for x in ?vec` (M20i.1)"** added
with the mode table, by-value vs borrowed-slot element binding
shape, the loop-source-borrow / consume-rejection diagnostics,
the Shape X / Shape Y emit lowering, and the PB3 substrate-
role pointer.

**Phase B status after M20i.1**: PB0 ✅, M20h ✅ (PB1 folded),
M20i ✅, PB2 ✅, M20i.1 ✅. PB3 is unblocked — the remaining
work is wiring `for cb in ?self.subs` into a new
multi-subscriber `Signal(T)` shape (and designing the
batching / topology layer in its own checkpoint).

### M20i.1.1 — Post-implementation review fixes ✅

GPT-5.5's M20i.1 post-implementation review (conversation
entry 28) identified one must-fix and three worthwhile
follow-ups. All landed in this single sub-commit per the
M5-style cadence (post-impl fixes are folded into one `.1`
companion when they share a theme).

**The must-fix: emit-side `vecSourceForEmit` global reverse
scan.** The original M20i.1(3/4) implementation scanned
`sema.symbols` reverse-order for a name match to classify the
for-source as Vec or not, gating on `vec_sym_id`. GPT-5.5's
review noted this is the M20e-legacy "first-match-wins"
pattern that mis-classifies under cross-function shadowing —
two same-named Vecs in different functions could pick the
wrong one and produce wrong-Shape emit (Shape X for Copy →
Zig compile error; Shape Y for resource → silent borrow-model
violation that could become dangerous if the body keys off
owned-closure detection downstream).

The fix mirrors M20a.2's `MethodReceiver` / M20e.1's
`declareWithResourceKind` pattern: attribute the Vec source
classification at sema time in a side table, and look up by
source position at emit time.

- New `pub const VecIterInfo` (in `src/types.zig`) holds
  `{elem_ty, is_resource, is_closure}`.
- New `SemContext.for_source_vec_info: std.AutoHashMapUnmanaged
  (u32, VecIterInfo)`, freed in `deinit`.
- `ExprChecker.checkForStmt` populates the table for every
  bare-name Vec source it processes (gated on the same
  `vecElementForIteration` predicate as the type-binding
  decision). `elemIsOwnedClosure(elem_ty)` computes the
  `*Closure()` flag once at sema time.
- `Emitter.vecSourceForEmit` is now a pure hashmap lookup
  keyed by `source.src.pos` — no name scan, no shadowing
  fragility. Returns null for non-bare sources and for sources
  sema didn't classify.

**Worthwhile follow-ups (also in this commit):**

1. **Reject resource Vec iteration over non-bare source.**
   `for cb in ?makeSubs()` and `for cb in ?h.subs` are now
   sema-rejected with a tailored diagnostic
   (`resource Vec(T) iteration in V1 requires a bare local
   Vec binding as the source; got an expression. Bind the
   result to a Vec(T) local first.`). The fix prevents (a)
   iterating over a Vec whose buffer is freed at statement
   end (function-result temporary), and (b) iterating without
   the ownership-layer read-borrow attaching to the source
   (member access leaves the Vec un-borrowed). Copy Vec
   iteration is unaffected by the restriction — only resource
   elements have the memory-safety hazard.

2. **Positive test: post-loop mutation released.**
   `examples/vec_for_post_loop_mutation.rig` proves the
   loop-source read borrow is released at the for-scope's
   popScope, so a subsequent `(!subs).push(...)` succeeds.
   Output: `12` (cb1 × 2 + cb2 × 1).

3. **Negative test: capture loop-borrow in lambda.**
   `examples/vec_for_capture_elem_rejected.rig` exercises
   `for cb in ?subs; f = fn |+cb| cb()`. The M20g
   clone-capture validator fires:
   `clone-capture |+cb| requires a shared *T, weak ~T, or
   Copy type; got ?*Closure()`. Defense-in-depth alongside
   the M20i.1 `rejectLoopBorrowOp` machinery.

**Tests after M20i.1.1: 832 → 846 (+14).** All previously-
passing tests still green; goldens for the three new
examples auto-generated.

**SPEC §"Vec iteration via `for x in ?vec` (M20i.1)"**
extended with the M20i.1.1 source-restriction note + a
reentrancy caveat on the lexical borrow rule (closure
calls can mutate the subscriber list indirectly — PB3
will need a runtime policy for this).

### PB3 — Multi-subscriber `Signal(T)` ✅

The convergence point of Phase B's substrate work. Generalizes
PB2's single-subscriber slot to a `Vec(*RcBox(Closure0))` of
retained subscribers; `signal.set(v)` walks every subscriber
synchronously in subscription order with strict non-reentrant
discipline. Closes Phase B and sets up Phase C (full reactive
library: `Effect` / `Memo` / `Reactor` user-buildable on PB3)
AND Phase D (async, per INFLUENCES §2 — `Future<T>` is
structurally the same shape).

Locked at the PB3 design checkpoint with GPT-5.5 (conversation
`c_5c1d09d53ebe2f62`, entries 29 + 30). Steve initially
proposed R4 (index walk, len snapshot, tolerate shrinks, ignore
late additions) as a low-allocation reentrancy policy; GPT-5.5
pushed back hard on **R2 (strict `notifying` flag + panic)**
because:

1. R4 forces the V1 spec to define recursive semantics that
   should be locked in PB4 once canary pressure exposes the
   use cases.
2. R2 has no allocation, no Vec mutation during iteration, no
   late-subscriber visibility rules to specify.
3. R2 is easy to relax later to queue / snapshot. R4 would
   calcify into "the API contract" once users started
   depending on cascade behavior.
4. R2 generalizes cleanly to `Future<T>` (resolve-once,
   notify-waiters, no recursive resolve semantics).

GPT-5.5 also flagged a critical audit BEFORE PB3 could ship:
closures must be unable to move/drop their captured resource
handles. A retained subscriber is invoked multiple times; if
the body could consume its capture, the second invocation
would be UAF. The audit confirmed the hole existed (sema/
ownership accepted `*Closure(fn |+sig| consume(<sig))` while
emit produced malformed Zig that accidentally caught it);
fixed in PB3(1/5) BEFORE the runtime change.

**Sub-commits:**

| Commit | What it shipped |
|---|---|
| `b0c0861` PB3(1/5) | **Audit fix (must-precede).** New `Binding.is_capture_resource: bool` set by `bindCapturesLocal` for `cap_clone`/`cap_weak`/`cap_move` captures. Unified `rejectLoopBorrowOp` -> `rejectNonConsumableBindingOp` per GPT-5.5 tactical guidance — single helper covering both M20i.1's `is_loop_borrow` and PB3's `is_capture_resource`. Branches diagnostic wording on which flag fired; hooks at the same five sites M20i.1 added. Allowed: `cap()`, `cap.method()`, `+cap`, `~cap`. Rejected: `<cap`, `-cap`, `return cap`, bare-alias. |
| `673de60` PB3(2/5) | **Runtime.** Signal struct gets `subs: Vec(*RcBox(Closure0))` (replacing PB2's optional single slot), `notifying: bool` (R2 guard), `init(value)` constructor (Vec needs allocator — not Zig-default-expressible). `set` checks `notifying` (panic on reentry), sets it true, walks `subs` forwards with `len` snapshot, defers reset. `subscribe` checks `notifying` (panic on reentry), clones + pushes. `__rig_drop` cascades via `subs.__rig_drop()` -> M20i `dropElement`. |
| `e86cfce` PB3(3/5) | **Emit + sema.** New `tryEmitSignalConstruction` parallel to `tryEmitVecConstruction`. Lowers `*Signal(value: V)` to `rig.rcNew(rig.Signal(T).init(V))`. `shouldExplicitTypeShareInner` excludes Signal (matches Vec exclusion). Sema-side `checkSet` rejects stack-local `Signal(T)` bindings per GPT-5.5 entry 29 — Signal owns a Vec that requires the M20e defer-guard machinery; rather than ship that for a use case no canary needs, reject the shape. Diagnostic points at the heap-owned `*Signal(T)` fix. |
| `1788d9d` PB3(4/5) | **Tests + canary + harness.** New `signal_multi_subscriber.rig` (mandatory subscriber-shaped regression: 3 closures driving a shared Cell, 2 `set` calls advance 0 -> 111 -> 222). New `signal_reentrant_set_panics.rig` (informational; not in EMIT_TARGETS — documents the R2 panic). Canary refresh with a PB3 multi-subscriber block; output now `1\n3\n13\n7\n99\n111\n111` (M20i.1 user-written walk + PB3 builtin walk both produce 111). Generalized `End-to-end run` harness into `run_end_to_end <name> <expected>` covering hello + signal_multi_subscriber + reactive_canary. |
| PB3(5/5) | **Docs (this entry).** SPEC §Signal rewritten for multi-subscriber + R2 + stack-rejection + V1 deferrals. ROADMAP PB3 entry. HANDOFF refresh (Phase B complete; PB4 / Phase C / Phase D become the next concrete arcs). |

**Tests across PB3 (1/5) → (5/5): 846 → 876 (+30).**

**Canary chain (Phase B complete)**:

```
1     PB0   Cell + stack-local closure
3     M20g  capture + invoke from stack
13    M20h  retained escaping closure
7     PB2   single-subscriber Signal (first set)
99    PB2   single-subscriber Signal (second set)
111   M20i.1 Vec(*Closure()) + for cb in ?subs (user-written walk)
111   PB3   multi-subscriber Signal (builtin walk, same tally)
```

**Substrate composition note.** The two notification primitives
shipped in Phase B are structurally equivalent:

  - User-written `for cb in ?subs ; cb()` (M20i.1) — explicit
    control over the walk; subscribe / iterate via Rig source.
  - Builtin `signal.set(v)` (PB3) — packages "value cell +
    subscriber list + notify-on-set" with R2 reentrancy guard.

The canary demonstrates both. Users who want full control
(custom iteration order, conditional invoke, error handling
per subscriber) reach for the M20i.1 primitive directly; users
who want the canonical reactive ergonomics reach for the
Signal builtin.

**Phase B status after PB3**: PB0 ✅, M20h ✅ (PB1 folded),
M20i ✅, PB2 ✅, M20i.1 ✅, **PB3 ✅** — Phase B is **complete**.
The next concrete arc is a design decision between three
forward paths (all are unblocked):

  1. **PB4** — Reactor / batching / Memo / Effect lifecycle.
     The full reactive library. Builds entirely on PB3 +
     M20i.1; substrate is solid.
  2. **Phase C** — reactive sugar (`:=` / `~=` / `~>` per the
     original Rip vision). Optional, can be deferred
     indefinitely; the library shape (PB3 + future PB4) is
     ergonomic enough on its own.
  3. **Layer 8** — structured concurrency (scope-bound tasks,
     cancellation discipline). Per INFLUENCES §1, this is the
     prerequisite for safe async. PB3's retained-callback-list
     shape is structurally the same as `Future<T>`'s waiter
     list — async is now substrate-ready, with the
     `Future<T>` design naturally derivable from PB3.

Steve will pick the next arc based on which substrate the
canary discipline forces. Per the Q1-Q5 Phase B lock from
entry 15: "canary first, library never; fix the language not
the library." If/when a canary use case forces Memo or
batching, PB4 wins. If a use case forces concurrency or
async, Layer 8 / Phase D wins. Phase C is luxury.

### PB4 — Reentrant-set queue + library/substrate boundary lock ✅

PB4 was the test of whether the next reactivity arc should
keep pushing in-language reactivity primitives (toward Reactor /
Memo / etc.) or hold the line at "substrate in language, library
in userland." Two cues from Steve reshaped the design:

1. **"Rust and Zig don't ship reactivity"** — implicit
   pushback on accumulating reactive builtins. Rust treats
   reactivity as a library (Leptos / Dioxus on
   `Rc<RefCell<T>>` + closures); Zig has nothing. Rig
   already had 4 reactive-ish builtins (Cell, Vec, Closure,
   Signal); adding a 5th (Reactor) would have gone against
   the "clean succinct powerful elegant" instinct AND
   against the REACTIVITY-DESIGN principle "library is the
   deliverable, substrate is the immediate one."
2. **Type-inference ergonomics observation** — the verbose
   `reactor: *Reactor = *Reactor()` form was unnecessary
   ceremony. Quick test confirmed `rc = *User(name: "Steve")`
   works without annotation for non-generic constructors
   via the existing `rcNew(anytype)` path. Reinforced the
   "minimum surface" preference.

GPT-5.5's entry-32 recommendation (add `*Reactor` builtin for
async/future executor generalization) was superseded by
entry 33: **minimal per-Signal queue relaxation, no new
Reactor builtin.** The reactive library (Reactor / Memo /
Effect / batching / topology) is now explicitly USERLAND
work, not future builtins.

**Locked design (GPT-5.5 entry 33):**

- `Signal(T).set(v)` reentry semantics relaxed from PB3's
  R2 panic to a queued-coalesced drain loop. Same-Signal
  reentrant set queues the new value (latest wins) and
  triggers another notification round after the current
  walk completes. Iterative loop (NOT recursive) avoids
  stack growth on cascade chains.
- `Signal(T).subscribe(cb)` reentry **still panics**. List
  mutation during iteration is subtler than queued value;
  locking that policy would force a mini-Reactor design
  PB4 deliberately defers. Strict-first.
- Document Signal explicitly as a **canary primitive**, not
  Rig's long-term reactive API.

**Sub-commits:**

| Commit | What it shipped |
|---|---|
| `e1b09dc` PB4(1/3) | Runtime: two new fields (`pending_value: T`, `pending_set: bool`); `set` becomes iterative drain loop with `notifying` guard; reentrant `subscribe` still panics. Removed `signal_reentrant_set_panics.rig` (no longer panics — would infinite-loop the test harness; positive PB4 test for queued coalesce isn't expressible from Rig source in V1 because terminating reentrancy requires conditional inline-body grammar). |
| `25405b0` PB4(2/3) | Canary refresh: header milestone table grew PB4 row; trailing TODO PB4 comment rewritten to document the locked position (reactive library is USERLAND work, not future builtins). No behavioral change to the canary — PB4 is backward-compatible. Canary output unchanged: `1\n3\n13\n7\n99\n111\n111`. |
| PB4(3/3) | Docs (this entry). SPEC §Signal rewritten with the canary-primitive disclaimer and the R2-relaxed-for-set policy. HANDOFF refresh. |

**Tests across PB4 (1/3) → (3/3): 885 → 880 (-5).** Reduction
is from the removed `signal_reentrant_set_panics` example +
its goldens; all other tests still pass. The R2 relaxation is
backward-compatible for all non-reentrant uses (which is every
test in the suite).

**What PB4 explicitly does NOT cover** (per the locked
boundary):

- New `*Reactor` builtin. Won't ship. Reactor is userland.
- Cross-Signal batching / `flush()`. Userland. Blocked on
  `Cell`-non-`Copy` for the natural shape.
- `Memo` / `Effect` / dependency-graph topology. Userland.
- Reentrant `subscribe` relaxation. V1 stays strict.
- Reactive sugar (`:=` / `~=` / `~>`). Phase C, deferred.

**What V1 still needs (per GPT-5.5 entry 32 "must-have
before credible V1")**:

- `%T` unsafe / effect boundary (raw pointers, Zig blocks,
  extern, trusted runtime/stdlib).
- `try_block` emit (currently `@compileError` placeholder).
- M15b cross-module signature import.
- Closure-with-args (`Closure1<T>`, `Closure2<A,B>`) beyond
  no-arg.
- Cleanup of legacy global name-scan paths in safety-critical
  code.

These are substrate-cleanup arcs that don't extend the
language but make it usable for real stdlib / library
development. The next concrete arc is a Steve-driven
choice between these substrate-cleanup items vs Layer 8
(structured concurrency) vs Phase C sugar.

### M20h.1 — Tighten `in_set_rhs` to direct lambda RHS ✅

GPT-5.5's M20h post-implementation review caught a
pre-existing M20g ownership leak: `walkSet` set
`in_set_rhs = true` for the ENTIRE RHS walk (not just for
direct lambda literals), so a lambda buried in an aggregate
literal silently passed the escape check. Before this fix,
`xs = [fn |+rc| ...]` and `h = Holder(cb: fn |+rc| ...)`
both compiled without diagnostic — the lambda would have
escaped via the aggregate.

The flag now fires ONLY when the RHS is DIRECTLY a lambda
literal (`isLambdaLiteral(expr)` gate). The
`*Closure(fn ...)` shape is unaffected — its escape
permission flows through the separate M20h(3/5)
`in_owned_closure_constructor_arg` flag set by `walkShare`.

**Implementation** (one-line conceptual change to
`ownership.zig::walkSet`):

```zig
const direct_lambda_rhs = isLambdaLiteral(expr);
const prev_rhs = self.in_set_rhs;
if (direct_lambda_rhs) self.in_set_rhs = true;
try self.walk(expr, false);
self.in_set_rhs = prev_rhs;
```

**Tests** (+8 from two new negative examples):

- `closure_escape_array_rejected.rig` — `xs = [fn |+x| ...]`
  fires "closures cannot escape" diagnostic.
- `closure_escape_record_rejected.rig` — `h = Holder(cb: fn
  |+x| ...)` fires the same.

**Cascade observation**: `owned_closure_bare_rejected.rig`
(bare `Closure(fn ...)` without `*`) now produces BOTH the
sema "must be wrapped with `*`" diagnostic AND the
ownership "cannot escape" diagnostic. Both are correct —
the user's expression is wrong in two distinct ways. Golden
updated to match.

**SPEC §Lambdas** tightened (per GPT-5.5's R6): the
"non-escaping by default" wording was replaced with an
explicit enumeration of the three legitimate lambda
positions (direct bind RHS, call callee, `*Closure(...)`
arg) and a "compiler does not infer escape" disclaimer.

754 tests pass (was 746).

### M21 — Unsafe / Raw effect boundary ✅

*(Shipped as `M19` in commit prefixes for historical
conversation continuity — see GPT-5.5 entry 35. The earlier
`### M19 — Typed Mutable Binding Emission` above is a
small, unrelated arc; this entry's M-number is M21 to
disambiguate.)*

The substrate-cleanup arc Steve picked after Phase B
completion. Per GPT-5.5 entry 31 and entry 32: "highest
strategic importance" within Category A "must-have before
credible V1." Locks the safety bargain that Rig's runtime
+ user code already relies on but had no enforced surface.

Locked at the M21 / `%T` design checkpoint with GPT-5.5
(conversation `c_5c1d09d53ebe2f62`, entries 35 + 36).
Steve's two cues from PB4 (Rust/Zig don't ship reactivity;
minimum-surface ergonomics) reshaped the recommendation
during PB4 and continued shaping M21: stick to the
minimum-viable shape, defer raw Zig blocks and user-
trusted-types to follow-ons.

**Locked design (entries 35 + 36):**

- **Block-only `unsafe`** (no single-statement `unsafe expr`).
  The block IS the audit boundary; visually heavy is the
  point.
- **Prefix `unsafe sub`/`unsafe fun`** (NOT suffix). Matches
  the existing `pub`/`extern`/`packed`/`callconv` modifier
  pattern. Single grammar line; no IR shape change. SPEC
  updated to match.
- **Two distinct IR tags**: `unsafe_decl` (decl-modifier wrap,
  parallel to `(pub decl)`) and `unsafe_block` (statement
  form, parallel to `(defer block)`).
- **Effect model**: unsafe-fn body IS unsafe context by
  default (Rust-style). Unsafe block opens a context; safe
  fn calling an unsafe fn must wrap in `unsafe` block.
- **Default-unsafe builtin classification**: small safe
  whitelist (`@sizeOf`, `@alignOf`, `@TypeOf`, `@typeName`,
  `@hasDecl`, `@hasField`, `@len`, `@This`); everything else
  requires unsafe. Each addition audited.
- **Extern is unsafe-by-default at call sites** even without
  explicit `unsafe` modifier. Extern is the FFI boundary;
  the safety bargain across it requires explicit caller
  acknowledgment.

**Sub-commits:**

| Commit | What it shipped |
|---|---|
| `5859f5e` M19(1/6) | Grammar: `UNSAFE` keyword + `unsafe_decl` / `unsafe_block` tags. Decl-modifier rule `UNSAFE decl -> (unsafe_decl 2)` parallel to `pub`/`extern`/`packed`. Statement-form rule `UNSAFE block -> (unsafe_block 2)` parallel to `defer block`. Conflict count stayed at 69. (Em-dash in grammar comments breaks Nexus parsing — found during dev; ASCII-only in grammar comments going forward.) |
| `64df3bf` M19(2/6) | Effects: `unsafe_depth` + `current_fn_is_unsafe` + `pending_fn_unsafe` state on `Checker`. New `inUnsafeContext()` helper. `(raw X)` outside unsafe context fires tailored diagnostic. New arms for `(unsafe_block ...)` and `(unsafe_decl ...)` wire the audit context. `walkFun` consumes `pending_fn_unsafe`. Existing `spacing.rig` example updated to wrap its `%x` line in `unsafe`. |
| `dadcefb` M19(3/6) | Builtin classification: `isSafeBuiltin(name)` whitelist; `.@"builtin"` dispatcher arm fires diagnostic for non-whitelisted builtins outside unsafe context. Diagnostic lists the safe set so users see options. |
| `2c925b3` M19(4/6) | Unsafe fn calls: `SymbolFlags.is_unsafe` field; SymbolResolver stamps it from `unsafe_decl` wrapper. TypeResolver + ExprChecker get transparent `unsafe_decl` arms. New `lookupIsUnsafe(name)` helper in effects; `walkCall` fires diagnostic for unsafe-fn calls from safe context. |
| `5f1b3aa` M19(5/6) | Extern call enforcement: `lookupIsExtern(name)` checks `Symbol.kind == .@"extern"`. `walkCall` adds extern-call-from-safe diagnostic. Catches the currently-callable extern shape (`extern puts: fn(String) Int`). |
| M19(6/6) | Docs (this entry). SPEC §"Unsafe / Raw (M19)" rewritten end-to-end with syntax, builtin whitelist, extern-FFI-boundary rule, safe-wrapper pattern, trusted-runtime boundary, V1 deferred features. ROADMAP M21 entry. HANDOFF refresh. |

**Tests across M21 (1/6) → (6/6): 880 → 924 (+44).** 8
positive + 5 negative examples covering raw access, builtin
classification, unsafe-fn calls, extern calls. The existing
`spacing.rig` sigil-tokenization test was updated to wrap
its `%x` line in `unsafe` (preserves the tokenization
purpose AND respects the new effect rule).

**What M21 does NOT cover:**

- `zig "..."` raw Zig blocks (parsed but not wired through
  emit; M21+ extension; will inherit the same unsafe-context
  requirement when it lands).
- **Body-less `extern fun`/`extern sub` declarations**
  (`extern fun puts(s: String) -> Int` without a body block).
  Currently the grammar's `fun`/`sub` productions require a
  block, so extern FUNCTION declarations aren't expressible
  — only extern variables with fn-typed annotations
  (`extern puts: fn(String) Int`) are callable today. The
  M21 enforcement is in place; the FFI ergonomics need
  M21.x for body-less extern fn syntax to unlock real
  FFI work.
- Cross-module extern signatures (same M15b gap as
  fallibility checking).
- User-defined `trusted` decoration for writing custom
  trusted-runtime types in Rig source (V1 substitute is the
  safe-wrapper pattern documented in SPEC).
- The "unsafe extern" composition is parseable but
  redundant — extern is already unsafe-by-default at call
  sites, so explicit `unsafe extern` is informational. May
  get its own diagnostic in M21+.

**What this unlocks:**

- **Real stdlib seed work** — `HashMap`, `String`, `File`,
  `IO` can now be written in Rig source with safe public
  contracts wrapping unsafe Zig internals via the safe-
  wrapper pattern.
- **Userland reactive library** — Reactor / Memo / Effect
  (locked as userland work in PB4) can now use `unsafe`
  blocks for the interior-mutability they need. Once
  `Cell`-non-`Copy` lands, the library shape is fully
  expressible.
- **Future async** — FFI / poll/wake / pin / executor
  patterns will all live behind the `unsafe` boundary.
  Substrate prerequisite shipped.

### M21.1 — Post-implementation review fixes ✅

GPT-5.5's M21 post-implementation review (entry 37) identified
one must-fix and a few small improvements. All landed together
as M21.1.

**Must-fix: `pending_fn_unsafe` propagation hazard.**

The M19(2/6) implementation modeled the unsafe-fn marker as a
global mutable state (`pending_fn_unsafe: bool`) that
`(unsafe_decl ...)` set true before walking the inner decl,
and `walkFun` CONSUMED via `self.pending_fn_unsafe = false`
at fn-entry to "reset" it. GPT-5.5 caught the leak: if
`unsafe_decl` wraps a NON-callable decl (e.g., `unsafe struct
S`), no `walkFun` fires to consume the flag, and it could
leak to a sibling fn walked after the wrapper.

Fix: remove the `pending_fn_unsafe = false` mutation from
`walkFun`. The wrapper's own save+restore around
`walk(items[1])` exclusively owns the flag's lifetime.
`walkFun` now READS the flag without mutating it.

Companion fix at the SymbolResolver layer: reject
`unsafe struct` / `unsafe enum` / `unsafe type` / `unsafe
opaque` etc. with a tailored diagnostic. The unsafe modifier
only makes sense on callable decls. The check walks past
benign wrappers (pub / extern / packed / callconv) to find
the actual decl head before classifying.

**Regression tests (M21.1):**

  - `unsafe_struct_rejected.rig`             negative: `unsafe struct S`
                                             fires the new sema rejection.
  - `unsafe_no_leak_to_sibling_fn.rig`       negative + regression:
                                             `unsafe struct S` followed
                                             by `sub main()` with bare
                                             `%x` — BOTH diagnostics
                                             fire (the struct
                                             rejection AND the raw-
                                             access-requires-unsafe
                                             rejection). If the leak
                                             regressed, the raw-access
                                             diagnostic would be
                                             swallowed.

**Optional composition test:**

  - `unsafe_pub_compose_ok.rig`              positive: both
                                             `pub unsafe sub` and
                                             `unsafe pub sub`
                                             orderings compose and the
                                             resulting fn correctly
                                             requires unsafe context
                                             at the call site.

**Tests across M21.1: 924 → 932 (+8).** Three new examples
plus the leak regression. All previously-passing tests still
green.

**Additional ROADMAP note:** body-less `extern fun`/`extern
sub` declarations explicitly added to "What M21 does NOT
cover" — needed for real FFI ergonomics but blocked on a
grammar extension to allow body-less fn declarations.
Deferred to M21.x.

### M22 — Unsafe surface cleanup (`unsafe` → `raw`, drop fn-modifier) ✅

Pure cleanup arc. Steve flagged the M21 `unsafe` keyword as
aesthetically off — heavy, Rust-imported, and shipping a lot
of machinery (fn-modifier + decl-modifier-wrap + Symbol flag
+ global mutable bridge state + parallel walker arms + the
M21.1 reject-unsafe-on-non-fn rule) for a feature with zero
V1 use cases. GPT-5.5 entry 38 confirmed: cleanup is worth
shipping.

**Locked design (GPT-5.5 entry 38):**

- **Rename keyword: `unsafe` → `raw`.** Three letters; matches
  the existing `%x` raw-prefix sigil; reads as a noun
  ("raw context") rather than a Rust-imported scarlet letter.
- **Drop the fn-modifier entirely.** No `unsafe sub`/`unsafe
  fun` (or `raw sub`/`raw fun`) in V1. Users who need a whole
  fn body in a raw context wrap the body in a `raw` block as
  the first statement.
- **Block-only enforcement** — the `raw` block is the
  statement-level audit boundary. No fn-level marker.
- **Two IR tags merged into one.** `(unsafe_decl ...)` deleted;
  `(unsafe_block ...)` renamed to `(raw_block ...)`.

**Why drop the fn-modifier**: it shipped substantial
machinery (`SymbolFlags.is_unsafe`, three transparent walker
arms across SymbolResolver/TypeResolver/ExprChecker,
`pending_fn_unsafe` global mutable bridge, `current_fn_is_unsafe`
checker state, `lookupIsUnsafe` helper, unsafe-fn-call diagnostic,
the M21.1 "reject unsafe on non-fn" sema rule, "unsafe pub vs
pub unsafe" composition test surface) — all to support a
feature (Rust-style `unsafe fn` precondition-marker) that has
zero V1 use cases. The whole class of `pending_fn_unsafe`
leak hazards GPT-5.5 caught in entry 37 ceases to exist
(not just gets patched) by dropping the fn-modifier.

**Sub-commits:**

| Commit | What it shipped |
|---|---|
| `acb367d` M22(1-2/3) | Grammar + lexer rename + sema/effects strip combined. Grammar: dropped `UNSAFE decl` modifier-wrap line; renamed `unsafe = UNSAFE block` to `raw = RAW block`; updated `expr` alternation. Lexer: `UNSAFE` -> `RAW` keyword; `unsafe_decl` + `unsafe_block` tags merged to single `raw_block`. Parser regenerated, conflict count stayed at 69. Sema: `SymbolFlags.is_unsafe` removed; three transparent walker arms removed; M21.1 reject-unsafe-on-non-fn rule removed (became irrelevant). Effects: `unsafe_depth` -> `raw_depth`; `inUnsafeContext` -> `inRawContext`; `current_fn_is_unsafe` + `pending_fn_unsafe` + `lookupIsUnsafe` + unsafe-fn-call diagnostic all removed. The whole global-mutable-bridge hazard class is gone. |
| M22(3/3) | Examples + goldens + docs (this entry). Deleted 7 fn-modifier-only examples + 21 goldens. Renamed 7 examples (`unsafe_*` -> `raw_*`) and updated their `unsafe` keyword + diagnostic strings to the new `raw` shape. Updated `spacing.rig`'s `unsafe` wrap to `raw`. SPEC §"Unsafe / Raw (M19)" rewritten as §"Raw escape (M22)" — trimmed substantially; added explicit "no raw/unsafe function modifier in V1" note (per GPT-5.5 entry 38) to prevent future sessions from accidentally resurrecting the fn-modifier. ROADMAP M22 entry (this one) + HANDOFF refresh. |

**Tests across M22 (1-3/3): 936 → 908 (-28).** The reduction
is from the 7 deleted examples × 3 goldens each + the 7
removed unsafe-fn enforcement tests; no other tests broke.
Canary unchanged at `1\n3\n13\n7\n99\n111\n111`.

**Measured impact of the cleanup:**

- **Source code removed**: ~120 lines across `types.zig` +
  `effects.zig` + `rig.zig` (the deletion side is ~1100
  lines combined with the parser regen; the substantive
  language-side reduction is ~120).
- **Conceptual surface removed:**
  - Two enforcement contexts (block + fn-modifier) → one
    (block only).
  - Two IR tags (`unsafe_decl` + `unsafe_block`) → one
    (`raw_block`).
  - Three transparent walker arms across 3 sema passes → zero.
  - `SymbolFlags.is_unsafe` flag → removed.
  - Global mutable bridge `pending_fn_unsafe` → removed
    entirely (the class of leak hazards GPT-5.5 flagged in
    entry 37 ceases to exist).
  - `lookupIsUnsafe` helper → removed (effects.zig lookup
    helpers reduced from 3 to 2).
  - "Call to unsafe function" diagnostic category → removed.
  - "Unsafe pub vs pub unsafe" composition test surface →
    removed.
  - M21.1's "reject unsafe on non-fn" sema rule → irrelevant.
- **Aesthetic alignment**: `raw` is 3 chars, matches `%x`
  sigil naming. The Rust-imported feel is gone.

**What stays (unchanged enforcement)**:

- Raw `%x` outside `raw` block fires diagnostic.
- Non-whitelisted `@builtin(...)` outside `raw` block fires.
- Extern call outside `raw` block fires.

**What's intentionally lost (per GPT-5.5 entry 38)**:

- `unsafe sub`/`unsafe fun` fn-modifier syntax.
- The Rust-style `unsafe fn slice_get_unchecked(i)` pattern
  (caller-must-uphold-precondition-marker). Can return when
  a real stdlib seed use case forces a fresh design pass.

**Hazards retired**:

- "M19 vs M21 vs M22 naming collision" — collapses into the
  M22 final shape. The historic ROADMAP entries are preserved
  (M19 = old Typed Mutable Binding; M21 = old `unsafe`
  boundary; M22 = current `raw` cleanup) with cross-references
  for the conversation log.

### M22.1 — Fake-surface audit (raise the floor before more features) ✅

Cleanup arc triggered by Steve's "is our syntax clean and
powerful?" high-level review. GPT-5.5 (entry 39) returned a
verdict of "(b) holding up but watch X, Y, Z" with one through-
line: **every concrete hazard was the same shape — accepted
syntax with no enforced semantics**. M22 was the first instance
of this pattern being fixed (`unsafe` keyword removed). M22.1
audits the rest of the surface and applies the same discipline.

**Invariant locked**: every accepted V1 surface form must either
have enforced semantics with a working Rig lowering, OR be
rejected at sema time with a clear Rig diagnostic. No more
parsed-but-not-enforced affordances. No more emit-time
`@compileError`-as-feature-placeholder.

**Hazards closed (one per sub-commit):**

| # | Hazard | Before M22.1 | After M22.1 |
|---|---|---|---|
| H1 | Resource-temp leak | `(*User(...)).field` allocated an Rc with no M20e guard → strong-count-1 leak forever in safe code | Sema rejects fresh-resource rvalues used as member/index/borrow/clone/weak/raw/pin/method-call objects; users bind to a name first |
| H4 | `@x` pin sigil | Lexed, parsed, emit was identity (`@x` lowered to plain `x`) — a no-op sigil in the ownership grid | Sema rejects with "reserved for V2"; lexer disambiguation from `@builtin(...)` preserved |
| H5 | `for *x in v` ptr-mode | Resource Vec rejected; Copy Vec silently emitted same as `for x in v` (silent no-op) | Sema rejects for ALL Vec sources; one spelling per element kind (`for x in v` Copy, `for x in ?v` resource) |
| H7+H8 | `pre <expr>` / `pre INDENT body` | Parsed, walked, emit produced `@compileError("rig: emitter does not yet support pre_block")` | Sema rejects both forms cleanly; `pre_param` (compile-time fn parameters) STAYS — it's wired |
| H2 | `try INDENT body OUTDENT [catch \|e\| ...]` | Parsed, walked, emit produced `@compileError("...does not yet support try_block")` | Sema rejects with "reserved in V1"; `expr!` propagation + `expr catch \|e\| handler` inline form still work |
| H3 | `zig "..."` inline-Zig block | Parsed, walked, emit produced `@compileError("...does not yet support zig")` | Sema rejects with "reserved in V1"; `raw` block + `extern` cover the practical needs |
| H6 | SPEC stale `unsafe` reference | Pre-M22 leftover language in V1-context table | Updated; new §"Reserved surface (M22.1)" + §"Resource-temporary leak rule (M22.1)" sections added |

**Audit holes GPT-5.5 flagged + checked:**

- Emit `@compileError("rig: ...")` paths: only the catch-all
  `else` in `emitExprList` reaches Rig source — closed for
  `try_block`/`zig`/`pre_block`/`pre` via sema. Other paths
  (Vec/Signal type-annotation, value-position empty branch)
  are correctness safety nets for compile-time impossibilities,
  not user-reachable surfaces.
- `@builtin(...)` classification: default-unsafe with explicit
  safe-list (`@sizeOf`, `@alignOf`, `@TypeOf`, `@typeName`,
  `@hasDecl`, `@hasField`, `@len`, `@This`). Non-whitelisted
  builtins outside `raw` block fire — already correct.
- Escaping-closure laundering of raw context: not reachable in
  V1 because closure bodies via `*Closure(fn |...|...)` are
  restricted to single-call inline-body shape; multi-stmt
  closure bodies that could contain `raw` blocks aren't
  expressible.

**Sub-commits:**

| Commit | What it shipped |
|---|---|
| M22.1(1/8) | H1 resource-temp leak fix: structural (`isFreshResourceAlloc`) + type-aware (`isCallExpr` + `isResourceOwningType`) two-tier check in `types.zig`; rejection wired into `synthMember`, `synthIndex`, `synthBorrow`, `.@"clone"/.@"raw"/.@"weak"` arms. Type-aware tier catches `make_user().age` (resource-returning function calls); structural tier gives the precise `*Foo` diagnostic. Method-call receiver covered via `synthMember`. 5 regression examples (`resource_temp_*_rejected.rig`, `resource_call_member_rejected.rig`, `resource_bind_first_ok.rig`). |
| M22.1(2/8) | H4 pin retract: split `.@"pin"` out of the `.@"clone", .@"pin", .@"raw"` group; new arm rejects `(pin x)` with "reserved for V2". `examples/spacing.rig` updated (line + comment); 1 regression example (`pin_sigil_reserved.rig`). |
| M22.1(3/8) | H5 `for *x` retract: lifted ptr-mode rejection out of the resource-only branch so it fires for both resource and Copy Vec. 1 regression example (`for_ptr_binding_reserved.rig`). |
| M22.1(4/8) | H7+H8 `pre` retract: new sema arm for `.@"pre"` + `.@"pre_block"` rejecting both. 2 regression examples (`pre_block_reserved.rig`, `pre_expr_reserved.rig`). |
| M22.1(5/8) | H2 `try_block` retract: new sema arm rejecting `.@"try_block"`. 1 regression example (`try_block_reserved.rig`). |
| M22.1(6/8) | H3 `zig` block retract: new sema arm rejecting `.@"zig"`. 1 regression example (`zig_block_reserved.rig`). |
| M22.1(7/8) | H6 SPEC sweep + ROADMAP/HANDOFF: new §"Reserved surface (M22.1)" + §"Resource-temporary leak rule (M22.1)" in SPEC; ownership sigil grid annotated `@x` as RESERVED; `zig "..."` deferred-feature note updated to "reserved in V1"; this ROADMAP entry. |
| M22.1(8/8) | Regression sweep + final review. |

**Tests across M22.1: 908 → 952 (+44).** 11 new regression
examples × ~4 goldens each (raw_sexp + semantic_sexp + errors
+ deterministic). Canary unchanged at
`1\n3\n13\n7\n99\n111\n111`.

**Measured impact:**

- **Source code added**: ~90 lines (sema rejection arms +
  helpers) in `types.zig`.
- **Hazards eliminated (one real-safety bug)**: H1 was a
  confirmed leak in safe Rig code (verified by `bin/rig build`
  showing the `rcNew` with no `defer` / no `__rig_alive_*` flag
  for the member-access case). Closing this is the only Tier 1
  fix in M22.1.
- **Conceptual surface cleaned**: 5 user-visible constructs
  retracted to clean diagnostics (`@x` pin, `for *x`,
  `pre`/`pre_block`, `try_block`, `zig "..."`). Each one was a
  fake-surface promise where the lexer/grammar accepted the
  form but emit either produced a no-op or `@compileError`.
- **No grammar changes**. All retractions land at sema. This
  preserves the design space for V2+ (when one of these returns
  with real semantics, the lexer/parser doesn't need to change
  — only the sema rejection comes out).

**What's intentionally lost (per GPT-5.5 entry 39)**:

- `@x` as a usable V1 sigil. Reserved for V2 pinning story.
- `for *x in v` as a usable V1 iteration. Reserved; future
  by-reference iteration likely takes `for ?x in v` /
  `for !x in v` (borrow-shaped) instead — `*x` already means
  shared ownership everywhere else in the grid.
- `pre <expr>` and `pre INDENT body` (block + expression
  forms). Reserved; `pre_param` survives.
- `try INDENT body OUTDENT [catch ...]` value-yielding form.
  Reserved; `expr!` propagation + `expr catch |e| handler`
  inline form survive.
- `zig "..."` inline-Zig escape. Reserved; `raw` + `extern`
  cover the practical needs.

**Hazards retired**:

- "Parsed but not enforced" affordances in the surface — the
  M22.1 invariant is now the explicit policy. Future arcs that
  add new syntax must ship the semantics + emit OR ship a
  clean "reserved" sema rejection. The fake-surface
  anti-pattern has a name and a regression suite.

### M15b — Cross-module sema (module honesty) ✅

Lifts the M22.1 fake-surface invariant from single-file scope
to module scope:

> Every accepted cross-module reference carries the same
> checked contract it would have carried in the defining file.

Pre-M15b structural finding (documented in `modules.zig:32-44`
since the M15 era): cross-module sema treated `(member <module>
<name>)` as silently `unknown`-typed. Member access lowered to
literal `foo.bar` Zig syntax and relied on Zig's compiler to
catch type errors — BYPASSING every Rig safety check at the
module boundary (fallibility, arity, kwargs, borrow obligations,
extern FFI obligation, M22.1 resource-temp leak, M20e auto-drop
guards, auto-deref through `*T`).

Audit (`bin/rig check`/`build`/`run` repros) confirmed nine
distinct cross-module hazards, including a Tier-1 safety bug
(cross-module `*T`-returning calls leaked the Rc and silently
skipped auto-deref, printing the entire Container struct
instead of the requested field).

**Architecture (GPT-5.5 entry 39 design checkpoint)**:
Imported nominal types carry canonical origin identity
`{module_id, sym_id}`, NOT structural equality. `a.Box` and
`b.Box` are different types even if their fields are identical.
Re-interned into the importer's local TypeStore via the new
`importType` helper. Three new `SemContext` fields
(`module_id`, `imports`, `foreign_semas`) plus a `module_refs`
side table key the cross-module lookups.

**Sub-commits**:

| Commit | What it shipped |
|---|---|
| M15b(1-2/5) `4da7656` | Substrate (lookup helper + `imported_nominal` Type variant + `importType` recursive re-interner + `checkWithImports` entry + driver wiring through `modules.zig`) merged with full contract wiring (`synthMember` + `synthMemberCall` + `dispatchCrossModuleCall` + effects `walkCrossModuleCall`). All Tier-1 + Tier-2 hazards fixed in one architectural move. Also: `bin/rig check` now uses ModuleGraph (was single-file-only). |
| M15b(3/5) `ad83582` | Visibility enforcement (`pub` is real). New `isCrossModuleVisible` helper consulted by the three cross-module lookup sites. Non-pub names rejected with "X is not public; mark it pub in module M". Updated existing `test/modules/qualified_call/math.rig` to mark `add` as `pub`. |
| M15b(4/5) `7b37e7f` | `use std` reserved diagnostic. Pre-M15b(4/5) silently skipped at `modules.zig:365`. MH9 (sema-time unbound-name detection) deferred to M15b.1 because the initial impl exposed pre-existing branch-scope tracking issues + would require updating ~15 test-placeholder examples (`User`/`rename`/etc. patterns). Inline deferral notes added at both intercept points so M15b.1 picks up cleanly. |
| M15b(5/5) | SPEC + ROADMAP + HANDOFF + this entry. |

**Tests: 952 → 960 (+8).** Seven new cross-module canaries under
`test/modules/`:
- cross_fallible_rejected
- cross_arity_rejected
- cross_extern_rejected
- cross_borrow_rejected
- cross_constructor_rejected
- cross_visibility_rejected
- cross_use_std_reserved
- cross_resource_ok (positive: end-to-end `*T` lifetime + auto-deref through Rc both work cross-module; prints `42`, not `.{ .value = 42 }`)

Canary unchanged at `1\n3\n13\n7\n99\n111\n111`.
signal_multi_subscriber unchanged at `0\n111\n222`.

**Measured impact:**
- Source code added: ~430 lines net (helpers + checker wiring
  in `types.zig`, the cross-module call branch in `effects.zig`,
  the imports plumbing in `modules.zig`, `check`-uses-graph in
  `main.zig`).
- Hazards eliminated: 7 confirmed cross-module contract leaks.
  Tier-1 safety bug (resource lifetime + auto-deref) closed.
- New invariant: "`unknown` may only exist as poison after a
  diagnostic, never as a silent success type" — locked at sema
  level for cross-module returns. Bare-identifier use-site
  enforcement deferred to M15b.1 (see below).

**What's intentionally deferred (M15b.1+):**
- Sema-time unbound-name detection (MH9).
- Legacy global name-scan retirement (M20a.2 + M20e.1 partial).
- Public-API-returning-private-type rejection (the foreign
  module should reject the decl shape, not just the use site).
- Qualified resource types in type position (`b: *a.Box = ...`
  parse-gap).
- Cross-module user-defined generics.

**Hazards retired**:
- "Safe within one file, conventional across files." Cross-
  module references now carry the same checked contracts as
  same-file references. The M22.1 fake-surface invariant scales
  to module scope.

### M15b.1 — sema-time unbound-name detection + scope correctness ✅

Closes the deferred items from M15b(4/5): unbound-name
detection at sema time. Per GPT-5.5 entry 39: "`unknown` may
only exist as poison after a diagnostic, never as a silent
success type." Pre-M15b.1 hazards:

- `print(nonexistent_fn())` exited 0 from `bin/rig check`;
  only Zig caught the missing identifier later with a
  confusing "use of undeclared identifier" message.
- Multi-stmt value-position blocks (`if`-expression arms,
  `match`-expression arms) had their inner local bindings
  silently invisible — `synthBlock` didn't enter the block
  scope created by `SymbolResolver.walkBlock`, so use-site
  lookups walked the wrong scope chain and silently returned
  `unknown`.
- `walkDecl` was missing the `.@"generic_enum"` arm,
  silently skipping ExprChecker processing of generic enum
  method bodies AND desyncing the scope cursor for every
  subsequent top-level decl. Hidden until M15b.1's unbound-
  name detection surfaced the consequence as false-positive
  "use of unbound name `o1`" inside `sub main()` in
  `examples/generic_enum_method.rig` (because main's body
  was being checked at the wrong scope).

**Fixes**:

1. `synthLeafSrc` (value-position bare-name): unresolved
   names always error with "use of unbound name `X`". No
   leaf whitelist per GPT-5.5 post-impl review — bare
   `print` as a value must error.
2. `synthCall` unknown-callee branch: same diagnostic at
   the call site; `isCalleeBuiltinWhitelisted(name)`
   special-cases ONLY direct call shape `print(...)` (the
   one legacy non-symbol-table builtin). Skips the callee
   leaf in the args-synth loop to avoid double-diagnostics.
3. `TypeResolver.resolveType` (type-position unbound):
   `x: NopeType = ...` now errors with "use of unbound type
   `NopeType`" at decl-resolution time. Pre-M15b.1 silently
   returned `invalid_id`; the deferral note ("M5 v1 doesn't
   have a module system; undeclared names common") no
   longer applies post-M15b. Per the M15b.1 hardened
   invariant lifted to the type system.
4. `synthBlock` enters its scope via `enterNextScope` /
   `defer leaveScope` matching `checkStmt`'s `.@"block"`
   arm.
5. `walkDecl` extended with `.@"generic_enum"` ->
   `walkNominalDecl`. `walkNominalDecl`'s `member_start`
   computed for both `.generic_type` and `.generic_enum`.

**Test-fixture sweep**: 13 example files used undeclared
fixtures (`User`, `make`, `Packet`, etc.) for ownership /
borrow / fallibility tests, relying on the pre-M15b.1
silent-`unknown` to type-check past the undeclared names.
Each one updated to add the minimal real declarations the
test needs, keeping the intended diagnostic (use-after-move,
borrow conflict, etc.) as the test's target.

`examples/showcase.rig` and `examples/spacing.rig` are
documentation files whose intentional unbound references
demonstrate language surface; their errors-goldens regen'd
to include the new "use of unbound name" lines.

**Tests: 962 → 982 (+20)**. 5 new regression canaries
(`unbound_call_rejected`, `unbound_value_rejected`,
`if_expr_block_local`, `unbound_type_rejected`,
`print_as_value_rejected`); 13 fixtures updated;
showcase + spacing errors-goldens extended. Updated 1
sema unit test (was pinning the pre-M15b.1 silent
behavior).

**What's NOT in this commit (deferred to M15b.2+):**

- Legacy global name-scan retirement in `emit.zig` (M20a.2 +
  M20e.1 partial; explicitly noted as "acceptable in M20d,
  revisited when emit grows real scope-aware resolution").
  Sema-side unbound is enough to close the user-visible
  hazard; the emit-side scans are an internal cleanup that
  belongs in a dedicated arc.
- Public-API-leaks-private-type (M15b.2's job).

**Hazards retired**:

- "Sema silently passes unresolved names to emit." Closed
  for value-position, bare-call, AND type-position. The
  M22.1 "unknown is poison after a diagnostic" invariant
  now holds at all three sema entry points (synthLeafSrc,
  synthCall, resolveType).
- "Generic enum method bodies aren't type-checked." Closed.
- "Value-position block locals are invisible at their use
  sites." Closed.

### M15b.2 — public-API-leaks-private-type rejection ✅

Closes the highest-priority M15b deferred item per HANDOFF §13
Category A. A `pub fun` / `pub sub` whose signature mentions a
non-`pub` same-module nominal is a category error: importers can
hold the value but cannot construct or destructure it through
any public path. M15b.2 fires a decl-time diagnostic at the
defining module, not the importer's call site, so the module
author sees the leak immediately.

**What's covered:**

- Return type contains a same-module non-`pub` nominal.
- Parameter type contains a same-module non-`pub` nominal.
- `parameterized_nominal{base, args}` recursion: `Box(Secret)`
  where `Box` is `pub` and `Secret` is non-`pub` leaks `Secret`.
- Structural recursion through `optional` / `fallible` /
  `borrow_read` / `borrow_write` / `slice` / `array` /
  `function` / `shared` / `weak`.

**What's exempt (intentionally):**

- `imported_nominal{module, sym}` — already validated visible
  in its origin module by the existing M15b cross-module call
  paths; the importer carries it transparently.
- Built-in nominals (Cell/Closure/Vec/Signal) — visible by
  construction via `registerBuiltins`.
- `type_var` — generic parameter; substituted at use sites.

**Implementation:**

- `TypeResolver.collectPrivateNominalLeaks(ty, leaks)` —
  walks a `TypeId` and appends any non-public same-module
  nominal leaves into `leaks` (deduplicated).
- `TypeResolver.checkPublicSignatureLeaks(fn_sym, pos, ret, params)` —
  invokes the walker for return + each param, fires one
  diagnostic per offending private symbol anchored at the
  function's name position. Distinguishes `function` vs `sub`
  in the diagnostic.
- Wired into `resolveFun` after the fn symbol's `is_public`
  flag and `ty` are stamped — only fires for public decls,
  no overhead for private functions.

**Tests:**

- `examples/pub_leaks_private_rejected.rig` — single-file
  fixture covering all three offender shapes (return type
  leak, param type leak, `Box(Secret)` parameterized leak).
- `test/modules/cross_pub_leaks_private_rejected/` — cross-
  module integration proving the diagnostic propagates
  through `bin/rig run main.rig` when the importer pulls in
  the offending module.
- 982 → 987 tests passing, 0 failing.

**Deferred to later arcs (per the M15b.2 spec scope):**

- `pub extern <name>: <type>` grammar (extern is currently
  not pub-wrappable; private extern + `pub` safe wrapper is
  the V1 idiom).
- Qualified resource types in type position (`b: *a.Box`)
  — parse-gap; users use type inference today.
- Cross-module user-defined generics (`pub type Box(T)` is
  not yet importable as parameterized).

These remain on the M15b.2+ follow-up list in
[`SPEC.md`](../SPEC.md#deferred-to-m15b2-under-active-follow-up).

### M25 — User-defined Drop ✅

Closes the substrate-unlock arc per GPT-5.5's M25 design lock
(conversation `c_5c1d09d53ebe2f62`, M25 checkpoint). Plain-struct
user `drop self: !Self` declarations are now fully wired end-to-
end: sema validation, ownership generalization, and emit produce
a working user-Drop pipeline that maintains the M22.1 fake-surface
invariant at every committed sub-commit.

**Why M25 is the substrate unlock.** Before M25, every struct
that owned a `*Cell`, `Vec(T)`, or `*Closure()` either needed
a manual cleanup call somewhere or silently leaked. The
userland reactive library that Phase B is building toward
(Reactor / Memo / Effect / batching / topology — see
`docs/REACTIVITY-DESIGN.md`) needs structs with retained
subscriber lists. Without user Drop OR auto-generated
structural drop glue, those structs would leak.

GPT-5.5's design correction during the M25 checkpoint named
the structural drop glue specifically as load-bearing: a
"user body only" implementation would not actually unlock the
userland substrate. The combination — user body + compiler-
generated `__rig_drop` that walks resource fields in reverse
declaration order — is what makes M25 a real unlock.

**Sub-commit ordering (locked by GPT-5.5 + shipped):**

| Sub-commit | Scope | Commit |
|---|---|---|
| M25(1/5) | Grammar + IR scaffold (`drop` keyword, `(drop_decl ...)` Tag, parse + reserved-surface sema rejection) | `3dec94f` |
| M25(2-4/5) | Sema validation + drop metadata, ownership generalization, emit (combined to maintain M22.1 invariant during the multi-sub-commit landing) | `5b5b3f8` |
| M25(5/5) | Tests + docs sweep (this entry) | _this commit_ |

**M25(2/5) — sema validation + drop metadata.**

- New `SymbolFlags.has_drop_glue: bool` — substrate-level
  classification. Set on a struct symbol when EITHER it has
  a user `drop` decl OR any field has a resource type
  (`shared`, `weak`, `Vec(T)`, `*Closure()`, or another
  nominal already flagged).
- New `Field.is_drop_method: bool` — distinguishes the user's
  drop body from ordinary methods on the same `fields[]`
  slice.
- New `TypeResolver.resolveDropDecl` — validates the drop
  declaration (exactly one per struct, `self: !Self`, no
  other params, no return, no fallibility, structs only).
- New `SymbolResolver.walkDropDecl` — opens body scope +
  binds `self` so `self.field` reads inside the drop body
  type-check correctly.
- New `ExprChecker.walkDropDecl` — walks the body with
  proper `NominalContext` + void return.
- New `typeHasDropGlue(ctx, ty_id)` helper — recursive
  resource-type predicate covering all the listed cases.
- After resolving fields, set `has_drop_glue` on the struct
  symbol if any field is resource-shaped or a user drop is
  present.

**M25(3/5) — ownership generalization.**

- `Checker.checkSharedHandleAlias` extended: any `nominal`
  or `parameterized_nominal` whose symbol carries
  `has_drop_glue` triggers the bare-alias rejection.
  Generalizes the existing M20d alias-discipline from the
  hardcoded resource set to the substrate-classified set —
  the load-bearing rule per GPT-5.5: "any type with drop
  glue is non-Copy."
- Diagnostic names the user struct and explains the failure
  mode (two bindings would each run the destructor on scope
  exit). Suggests `<x` move (no clone shape for user-Drop
  types in V1; user Clone is its own deferred arc).

**M25(4/5) — emit.**

- `Emitter.emitStruct` calls `emitGeneratedDropIfNeeded`
  after fields and methods. The generated body shape:
  ```zig
  pub fn __rig_drop(self: *Self) void {
      self.__rig_user_drop();      // if user drop_decl
      self.field_n.{drop_method}();  // reverse declaration
      ...                            // order
      self.field_1.{drop_method}();
  }
  ```
- `Emitter.emitNominalMethods` handles `drop_decl` members,
  emitting them as `pub fn __rig_user_drop(self: *Self) void`.
  Body emission auto-discards `self` only when the body
  doesn't reference it (Zig rejects both unused and
  pointless-discarded params).
- `Emitter.resourceKindOfBinding` recognizes nominals with
  `has_drop_glue` and classifies them as `.vec_value` — the
  existing ResourceKind already maps to `__rig_drop()` + the
  M20e auto-drop machinery, so user-Drop structs ride the
  existing path unchanged at the binding level.
- `Emitter.isInteriorMutableBinding` extended so user-Drop
  struct locals emit as `var` (the auto-drop defer takes
  `*Self`, which requires a mutable binding).
- New `dropMethodForResourceType` + `lookupFieldTypeByDeclPos`
  helpers for the generated drop body.

**M25(5/5) — tests + docs.**

End-to-end regression coverage:

| Fixture | Validates |
|---|---|
| `examples/drop_decl_reserved.rig` | User drop with `self.field` read in body |
| `examples/struct_drop_basic.rig` | User drop + 1 resource field; full pipeline |
| `examples/struct_drop_auto_glue.rig` | NO user drop; struct with resource field gets compiler-generated drop |
| `examples/struct_drop_multi_field.rig` | Reverse-order field drops with multiple resources |
| `examples/struct_drop_glue_alias_rejected.rig` | M25(3/5) bare-alias rule fires |
| `examples/drop_decl_invalid_self_rejected.rig` | Receiver shape validation |
| `examples/drop_decl_extra_param_rejected.rig` | Param-count validation |
| `examples/drop_decl_duplicate_rejected.rig` | "Exactly one per struct" rule |
| `examples/drop_decl_on_enum_rejected.rig` | V1-deferred enum Drop |
| `examples/drop_decl_on_generic_rejected.rig` | V1-deferred generic Drop |

Tests: 991 → 1035 passing, 0 failing.

**Cell-non-Copy splits to M26.** Per GPT-5.5's design lock,
`Cell(T)` for non-Copy T (the `Cell.set` replace semantics +
`take` primitive) is its own arc with its own design
checkpoint. M25 covers user-defined Drop on plain structs;
M26 covers the Cell-non-Copy substrate that the userland
reactive library needs alongside Drop.

**V1 deferred from the M25 lock:**

- Drop-body restrictions on consume-of-self / drop-of-resource-
  field / assignment-to-resource-field. Requires ownership.zig
  to walk struct method bodies (which it currently doesn't).
  The load-bearing "any drop glue is non-Copy" rule already
  prevents the most common footgun (cross-binding double-
  drop); the in-body restrictions are a follow-up arc.
- User-defined `Clone`. Lets users opt into a `+x` form for
  their Drop types.
- Optional-resource auto-drop (`Vec.pop() -> T?` for resource
  T, etc.) — separate substrate topic.
- Generic Drop (struct templates with type-var-resource
  fields) — needs bounds analysis.
- Enum / errors Drop — needs per-variant payload drop.
- Auto-deref through member-access in method bodies — calling
  `self.cell.get()` inside a drop body requires manual `.value`
  insertion at the auto-deref point.

**Substrate ladder impact** (`docs/INFLUENCES.md` §1): user
Drop is a cross-cutting infrastructure piece that didn't fit
neatly into the original layer model. Layer 7 (reactivity
substrate) was already complete via `Signal(T)`; Layer 7's
userland LIBRARY (the explicit `Reactor` / `Memo` / `Effect`
work) was blocked on Cell-non-Copy + user Drop. M25 is the
first half of that unblock; M26 (Cell-non-Copy) is the second.

### M29 — Drop `fn` keyword from closure literals ✅

A surface-cleanup arc: closure literals no longer require the
leading `fn` keyword. The bars + capture sigils ARE the marker.

**Why.** Steve flagged that `fn` was a 2-letter outlier in
Rig's 3-letter-keyword family (`fun` / `sub` / `pre` / `raw` /
`new` / `use` / `try` / `for` / `pub`). Per INFLUENCES rule 1
(*"Add features only when they make an existing semantic effect
explicit OR unify multiple ad-hoc mechanisms"*) — the
contrapositive applies: `fn` didn't make anything more explicit
(the bars do), didn't unify anything, and wasn't load-bearing
for the parser (the `isCapturePipe` lexer probe doesn't depend
on it). It was redundant noise in front of every closure literal.

GPT-5.5 evaluated three candidate replacements (`lam` / `pro` /
no keyword); Steve picked no-keyword (Rust-style bare bars).

**Before:**

```rig
body: *Closure() = *Closure(fn |+count| print(count.get()))
add = fn |n|
  n * 2
*Closure(fn |+a, +b| total.set(count.get() * 10))
```

**After:**

```rig
body: *Closure() = *Closure(|+count| print(count.get()))
add = |n|
  n * 2
*Closure(|+a, +b| total.set(count.get() * 10))
```

**Implementation:**

- `rig.grammar`: lambda rule changed from
  `FN captures params block | FN captures block | FN params block | FN block | FN captures inline_body`
  to `captures params block | captures block | captures inline_body`.
  No-capture forms (`FN params block`, `FN block`) dropped — V1
  doesn't use them, and `|| body` (empty captures) would need
  lexer probe work to disambiguate from logical-or. IR shape
  `(lambda CAPTURES PARAMS RETURNS BODY)` unchanged from M20g —
  every downstream walker (sema / ownership / emit) sees the
  exact same tree.
- `src/rig.zig`: NO change to keyword map. The `FN` token stays
  in the lexer because the function-type spelling `fn(Int) Int`
  (used in `extern` declarations) still uses it. Only the
  LAMBDA grammar rule no longer requires it.
- 45 fixtures swept (`fn |` → `|` via mechanical perl). All
  goldens regenerated (positional drift only — IR shape
  unchanged, emit shape unchanged at the Rig surface; columns
  shifted by 3 chars in error messages because source got
  shorter).
- Diagnostic strings in `src/types.zig` (4 sites) updated to
  reference the new bare-bars syntax in their suggested fixes.

**Conflict count.** Went from 69 → 75 (+6). All 6 are
`<context> vs BAR_CAPTURE` shift-prefer conflicts in
expression-start positions (after `return`, `break`,
`unary`, internal `capture`). Shift-prefer means the parser
treats `|` as starting a closure capture list — exactly
what we want. Verified by the full test suite passing
unchanged (1113 → 1113).

**Verified end-to-end.** All three reactive canaries
(`reactive_canary`, `rig_reactive`, `m28_multi_capture_cascade`)
produce identical output to pre-M29 (`1\n3\n13\n7\n99\n111\n111`,
`1\n7`, and `10\n70\n70` respectively).

**The `FN` token is still load-bearing for function types.**
Extern declarations like `extern puts: fn(String) Int` still
parse via the function-type rule. Don't accidentally remove
the `FN` keyword from the lexer.

Tests: 1113 → 1113 (unchanged — pure surface rename).

### M28 — Multi-capture closures ✅

The substrate gap that rrlib v0 surfaced when scaling to a
cross-source cascade canary (`count → total → print`). M20g
shipped single-capture only; M28 lifted the restriction to
comma-separated multi-capture.

**The discovery.** The downstream pipeline was already
multi-capture-ready by design. Reconnaissance found:

- `SymbolResolver.bindCaptures` loops `for (captures.list[1..]) |cap|`
  with a defensive comment noting "V1 grammar is single-capture
  so this only fires under a future multi-capture grammar rev"
  + duplicate-name detection.
- `ExprChecker.validateCaptures` loops + per-capture
  mode-vs-type validation.
- `Emitter.emitClosureFields` / `emitClosureInvoke` /
  `emitClosureInit` / `emitClosureCaptureGuards` (the four
  emit-side iterators) all loop.
- `Checker.applyCaptureEffects` / `bindCapturesLocal`
  (ownership) loop.

The single-capture limitation was purely grammatical.

**Three small fixes:**

- **`rig.grammar`** — `captures` rule changed from
  `BAR_CAPTURE capture BAR_CAPTURE` to
  `BAR_CAPTURE L(capture) BAR_CAPTURE` using the standard
  Nexus comma-separated-list combinator. IR shape unchanged
  (`(captures cap1 cap2 ...)` — just N children instead of 1).
- **`src/rig.zig` lexer** — `isCaptureContentCat` extended
  to accept `.@"comma"` so the multi-capture comma doesn't
  prematurely clear `pending_close_bar`.
- **`src/rig.zig` lexer** — `isCapturePipe` rewritten to
  probe ahead through multiple captures (bounded at 32
  defensively): `[sigil]? ident ( , [sigil]? ident )* |`.

**Conflict count unchanged at 69.** No grammar ambiguities
introduced.

**Verified end-to-end.** `examples/m28_multi_capture_cascade.rig`
chains two IntSources via `fn |+count, +total| ...`:

```rig
body_a: *Closure() = *Closure(fn |+count, +total| total.set(count.get() * 10))
count.subscribe(+body_a)

body_b: *Closure() = *Closure(fn |+total| print(total.get()))
total.subscribe(+body_b)

count.set(1)        # → total becomes 10 → prints 10
count.set(7)        # → total becomes 70 → prints 70
print(total.get())  # → 70
```

Output: `10\n70\n70`.

The emitted env struct correctly carries N capture fields
(`cap_count`, `cap_total`), per-capture clone refcount bumps
at construction, per-capture `dropStrong` in the rigDrop
thunk. M27's auto-deref fires correctly inside the multi-
capture body (`self.cap_count.value.get()` etc.).

**Negative regression**: `examples/m28_capture_duplicate_rejected.rig`
locks the duplicate-name rejection (`fn |+a, ~a|` — same name,
different modes — still rejected by `bindCaptures`). Diagnostic
points at the second occurrence with a note at the first.

Tests: 1103 → 1113 passing.

**Layer 7.x now complete.** With M25 (user Drop) + M25.1
(drop-body restrictions + has_drop_glue fixed-point) + M26
(Cell-non-Copy + replace) + M26.1 (reject discarded resource
expression-statements) + M27 (auto-deref through member-access)
+ M28 (multi-capture) all shipped, the substrate has proven
end-to-end on:

- single-source reactive (rrlib v0 monomorphic IntSource)
- cross-source reactive cascade (M28 canary)

Remaining substrate-completion gaps for full userland reactive
ergonomics:

- **M29: kwarg expected-type-propagation** — workaround
  exists (typed locals before nested constructors).
- **M30: generic `Source(T)` / generic member-chain
  substitution** — workaround is monomorphic structs.

Neither blocks the substrate; both are ergonomic improvements.

### M27 — Auto-deref through member-access in method bodies ✅

The substrate gap that the userland reactive library exposed in
its first compile attempt. Per Phase B Q1 canary discipline:
"the library is the canary; fix the language, not the library."

**The gap.** Method bodies that read shared-handle fields
through `self` failed at emit:

```rig
struct IntSource
  value: *Cell(Int)
  fun get(self: ?IntSource) -> Int
    self.value.get()    # error at Zig: only one auto-deref level
```

For bare-name receivers (`rc.set(5)` where `rc: *Cell(Int)`),
emit's `.@"member"` arm transformed to `rc.value.set(5)` —
inserting the runtime's `.value` field deref through the RcBox.
For member-access receivers (`self.value.set(5)`), the
transformation didn't fire because `handleKindOf` returned
`.other` for `.@"member"` shapes.

**Fix.** Two new emit-side helpers + extended `handleKindOf`:

- `Emitter.handleKindOfMember` — looks up the field on obj's
  nominal Symbol; returns `.shared` for shared-typed fields
  (triggering the existing `.value` insertion path).
- `Emitter.nominalSymForExpr` — recovers the nominal SymbolId
  of an expression's type. Handles bare `self` (via
  `current_nominal_name`), bare locals (via `decl_pos` + name
  lookup, sound under shadowing), and recursive
  `(member <obj> <field>)` chains.
- `Emitter.peelTypeToNominal` — walks `borrow_read` /
  `borrow_write` / `shared` wrappers down to a nominal
  symbol. Crucially does NOT peel `weak` (auto-deref through
  weak would silently dereference a potentially dangling
  handle).

The recursion handles deep chains (`a.b.c.method()` where
multiple links are shared) — each level looks up the next
field on the prior level's nominal.

**Verified end-to-end.** `examples/rig_reactive.rig` —
the smallest userland reactive library — compiles + runs:

```rig
struct IntSource
  value: *Cell(Int)
  subs: *Cell(Vec(*Closure()))

  fun new(initial: Int) -> *IntSource ...
  fun get(self: ?IntSource) -> Int
    self.value.get()         # M27 unblocks this
  sub subscribe(self: ?IntSource, cb: *Closure())
    ...
    current = self.subs.replace(<empty)   # M27 unblocks this
  sub set(self: ?IntSource, v: Int)
    self.value.set(v)        # M27 unblocks this
    ...

sub main()
  count = IntSource.new(0)
  body: *Closure() = *Closure(fn |+count| print(count.get()))
  count.subscribe(+body)
  count.set(1)               # → 1
  count.set(7)               # → 7
```

This is the first userland Rig program that composes M25 +
M26 + M27 substrate into a working reactive library. Per
GPT-5.5's design lock: monomorphic `IntSource` only, no
`Reactor`, no `Effect` wrapper, synchronous notify, no flush.
The library is brutally explicit by design — its job was to
PROVE the substrate composes, not to ship a polished API.

**V1-deferred (revealed by rrlib v0):**

- **M28: kwarg expected-type-propagation.** `*Cell(value: ...)`
  inside an outer constructor's kwarg loses the expected type
  at emit (lowers to anonymous struct literal). Workaround:
  typed locals before the outer constructor (used in
  `IntSource.new`).
- **Multi-capture closures** (`fn |+a, +b| ...`). Parse error
  in V1 grammar — single capture node only. Blocks the
  cross-source cascade canary (`count → total → print`).
- **Generic struct field substitution.** Emit's M27 helpers
  use raw `f.ty` lookup (no substitution). Generic structs
  with `type_var` field types (`Holder(T)` with `value: T`)
  lose precision; userland workaround is monomorphic structs.
  M20b's `lookupDataField` handles substitution via mutable
  sema reference — emit can't use it without const-cast or
  a refactor.
- **Generic `self` resolution.** Inside generic method bodies,
  `current_nominal_name` is "Self" — M27 doesn't try to
  resolve that to a specific instantiation. Userland code in
  generic method bodies that touches shared fields through
  self may need workarounds.

Tests: 1097 → 1103 passing.

### M26.1 — Reject discarded resource-typed expression-statements ✅

Closes the one must-fix from GPT-5.5's M26 post-implementation
review. The hazard: `cell.replace(<new)` ignored at statement
position leaked the old resource — Rig wasn't catching the
leak; only Zig's "value of type X ignored" diagnostic fired
(an M22.1-class fake-surface hazard, since the user-visible
language was silently allowing a leak through to the backend).

**Fix:** `ExprChecker.checkStmt`'s catch-all `else` branch now
synthesizes the expression's type, and if `typeHasDropGlue`
returns true, fires a Rig-level diagnostic naming the type and
suggesting the bind / discharge / move alternatives. The check
is general — covers `cell.replace(<new)`, `make_user()` at
statement position, future `vec.pop() -> T?` for resource T,
and any other discarded-resource hazard.

**Runtime comment** added per GPT-5.5's optional suggestion:
`Cell.replace`'s trusted byte-move now documents that the
copy-then-overwrite is invisible to user code (no drop fires
between the two assignments), and that M26.1 sema enforces the
caller always binds the returned T.

Regression: `examples/m26_1_replace_ignored_rejected.rig`.

Tests: 1093 → 1097 passing.

### M26 — Cell-non-Copy + replace/take ✅

Closes the second half of the userland-Reactor unblock. M25
shipped user Drop on plain structs; M26 shipped `Cell(T)` for
non-Copy resource T plus the `replace` swap primitive. With
both arcs landed, the userland reactive library shape
`*Cell(Vec(*Closure()))` is constructible end-to-end.

Per GPT-5.5's M26 design lock + post-checkpoint refinements
(conversation `c_5c1d09d53ebe2f62`, M26 checkpoint):

**M26(1/5) — sema type classification.**

- New `isValidCellElementType(ctx, ty_id)` — Cell accepts
  Copy primitives OR `typeHasDropGlue(T)`. Bare nominals
  without drop glue are still rejected.
- `typeHasDropGlue` extended to recurse `parameterized_nominal{Cell, [T]}`
  → has drop glue iff T has drop glue. M25.1's fixed-point
  pass propagates the flag through enclosing structs.
- `typeHasDropGlue` made `pub` so ownership.zig and emit.zig
  can dispatch on the same predicate.
- New `cellElementType(ctx, receiver_ty)` helper — extracts T
  from `Cell(T)` / `?Cell(T)` / `!Cell(T)` / `*Cell(T)` shapes
  for the `get` / `value` rejection guards.
- `cell.get()` rejected at the method-call site for Drop T
  (would alias-double-drop). Diagnostic suggests `replace`.
- `cell.value` field access rejected at the member-access
  site for Drop T. Same rationale.
- New synthetic method `replace(self: ?Cell(T), value: T) -> T`
  registered on Cell alongside `get` and `set`.

**M26(2/5) — runtime.**

`_runtime.zig`'s `Cell(T)` updated:

- `set(self: *Self, value: T)` now calls `dropElement(T, &self.value)`
  before storing. For Copy T, `dropElement` is comptime-elided
  to nothing (zero overhead). For Drop T, it cascades to
  `dropStrong` / `dropWeak` / `__rig_drop` via the existing
  M20i hybrid dispatch.
- `replace(self: *Self, value: T) T` byte-moves the old value
  out, stores new, returns old. Caller takes ownership; M20e
  auto-drop fires at the bound `old`'s scope exit.
- `__rig_drop(self: *Self) void` calls `dropElement(T, &self.value)`
  so a stack-local Cell with Drop T cascades cleanup to the
  contained value.

Per GPT-5.5's M26 design correction: use `dropElement(T, &value)`
everywhere, NOT `hasRigDrop(T)` alone. `hasRigDrop` returns
false for pointer types like `*RcBox(U)`; only `dropElement`
correctly dispatches `dropStrong` for shared handles.

**M26(3/5) — ownership.**

- `Checker.checkSharedHandleAlias` extended: `parameterized_nominal`
  receivers route through `types.typeHasDropGlue(sema, ty)` for
  the bare-alias rejection. M25(3/5) covered nominals and
  base-flagged parameterized_nominals; M26(3/5) generalizes to
  any whole type carrying drop glue, so `Cell(*User)` (where
  the BASE Cell symbol isn't itself flagged but the
  INSTANTIATED type is) gets caught.

**M26(4/5) — emit.**

- `Emitter.resourceKindOfBinding`'s `parameterized_nominal`
  branch now dispatches through `types.typeHasDropGlue(sema, sym.ty)`
  to install M20e auto-drop guards on Cell(Drop T) bindings.
  Vec(T), Cell(Drop T), and any future drop-glue parameterized
  type all route through `.vec_value` (the `__rig_drop`-method
  branch).
- `Emitter.isInteriorMutableBinding` already covered Cell-base
  parameterized_nominals (M20f + M25 layered correctly); no
  additional work needed for `var` storage.

**M26(5/5) — tests + docs.**

End-to-end fixtures:

| Fixture | Validates |
|---|---|
| `examples/m26_cell_shared.rig` | `Cell(*User)` with auto-drop cascade |
| `examples/m26_cell_reactor.rig` | `*Cell(Vec(*Closure()))` — userland Reactor target |
| `examples/m26_cell_replace.rig` | `cell.replace(<new) -> T` with caller-binding auto-drop |
| `examples/m26_cell_get_rejected.rig` | `Cell.get` on Drop T rejected |
| `examples/m26_cell_value_rejected.rig` | `cell.value` on Drop T rejected |
| `examples/m26_cell_alias_rejected.rig` | Bare alias of `Cell(Drop T)` rejected |

Tests: 1063 → 1093 passing, 0 failing.

**V1-deferred (per the M26 lock):**

- `Cell.take()` — needs an empty-state representation
  (Optional, default value, sentinel); deferred until a real
  use case appears.
- `cell.borrow()` read-access shape for Drop T — needs
  lifetime rules through `*Cell` interior mutation; deferred.
- User-defined `Clone` for Drop T (would let users opt into a
  `+x` form for their Drop types). Requires its own design pass.
- Optional-resource auto-drop (`Vec.pop() -> T?` for resource
  T, etc.) — separate substrate topic.
- Cell.replace using `std.mem.swap` or a more careful explicit
  move helper. The current byte-copy implementation is correct
  for straight-line code (no drops fire between the two
  assignments); a future polish arc could harden against
  panic-aware drop ordering if it becomes a concern.

### M25.1 — Drop-body restrictions + has_drop_glue fixed-point ✅

Closes the post-implementation review hazards GPT-5.5 flagged
on M25 (entry following the M25 design checkpoint in
conversation `c_5c1d09d53ebe2f62`).

**Hazard 1: drop-body restrictions (ship-blocker).** M25(2-4/5)
shipped without rejecting consume/drop/move-of-self and
move/reassign-of-resource-fields inside drop bodies. Per
GPT-5.5: "M25 is not done until you address drop-body
restrictions. That is a must-fix M25.1, not a nice-to-have."
The reasoning: M25 advertises that fields are auto-dropped
after the user body, so safe Rig syntax (`-self.cell` etc.)
created a direct double-drop path. The fix:
`TypeResolver.enforceDropBodyRestrictions` walks the body
recursively after fields are resolved, matching against:

  - `(drop self)` — `-self`
  - `(move (src self))` — `<self`
  - `(return (src self))`
  - `(move (member self field))` where field has drop glue
  - `(set _ (member self field) _ rhs)` where field has drop glue

Each match produces a tailored diagnostic. Recursion through
all child positions ensures patterns nested inside calls,
conditionals, and other expressions still fire.

Negative tests:
- `examples/m25_1_drop_self_rejected.rig`
- `examples/m25_1_move_self_rejected.rig`
- `examples/m25_1_move_resource_field_rejected.rig`
- `examples/m25_1_reassign_resource_field_rejected.rig`

**Hazard 2: has_drop_glue order-dependence.** The single-pass
`resolveStructFields` flipped `has_drop_glue` based on the
state of referenced nominals AT THAT MOMENT, so a struct
declared BEFORE its Drop-bearing nested-field type missed
the propagation entirely. Concrete example: `struct Outer {
inner: Inner }` declared before `struct Inner { r: *Cell(Int) }`
left `Outer` without drop glue and silently leaked the
nested resource. Fix: a fixed-point pass after
`type_resolver.walk` iterates until quiescence (bounded at
256 rounds defensively), flipping `has_drop_glue` as
referenced nominals get flagged.

Positive regression tests (both pass with reverse-order
nesting now drop-correct):
- `examples/m25_1_nested_struct_basic.rig` (Inner before Outer)
- `examples/m25_1_nested_struct_reversed.rig` (Outer before Inner)

**Tests: 1035 → 1063 passing, 0 failing.**

**What's still V1-deferred (per the M25 lock):**

- User `Clone` (lets users opt into `+x` for Drop types).
- Optional-resource auto-drop (`Vec.pop() -> T?` for
  resource T).
- Generic Drop (struct templates with type-var-resource
  fields).
- Enum / errors Drop (per-variant payload drop).
- Auto-deref through member-access in method bodies.
- M26 Cell-non-Copy + replace/take — separate design arc,
  the natural next milestone post-M25.1.

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
2. ~~**Real generic-instance member typing**~~ ✅ **Landed in M20b**
   above. `b.value` on `b: Box(Int)` now types as `Int` via
   parameterized_nominal + substituteType.
3. ~~**Generic methods on generic types**~~ ✅ **Landed in M20b**.
   `b.get()` on a parameterized receiver dispatches via
   `lookupMethod`'s substituted `fn_ty`; emit produces nested
   `pub fn` inside the Zig generic struct with `const Self =
   @This();`.
4. ~~**`Option(T)` / `Result(T, E)` as generic enum types**~~
   ✅ **Landed in M20c** above. Generic enums declare, type-check,
   and emit as `pub fn Name(comptime T: type) type { return
   union(enum) { ... }; }`. The `T?` / `T!` desugar to these is
   strongly deferred per GPT-5.5's design pass.
5. ~~**Methods on enums**~~ ✅ **Landed in M20a** (resolver +
   emitter both go through the unified `resolveNominalMethod` /
   `emitNominalMethods` paths).
6. ~~**`*T` / `~T` real `Rc` / `Weak` semantics**~~ ✅ **Landed in
   M20d** above. V1 ships with explicit-only drop discipline.
6.5. ~~**Automatic scope-exit drop for `*T` / `~T`**~~ ✅ **Landed in
   M20e** above. Defer-guard strategy per GPT-5.5's design pass;
   explicit `-x` becomes early-drop semantics. The V1 drop story
   is complete.
7. ~~**Interior mutability — `Cell(T)` library type**~~ ✅
   **Landed in M20f** above. Built-in runtime type with
   synthetic `get` / `set` methods; V1 restricts T to Copy
   (Int/Bool/Float/String); non-Copy `Cell(T)` deferred until
   the resource-aware replace/take/Drop substrate lands.
8. ~~**Closure capture mode syntax**~~ ✅ **Landed in M20g** above.
   Default `|x|` is Copy-only (visible-effects rule rejects bare
   resource captures); `|+x|` clones, `|~x|` weaks (from shared),
   `|<x|` moves. V1 closures are strictly non-escaping and
   non-copyable; resource captures get M20e-style guards anchored
   at the closure-instance lifetime.

**Soon (substrate maturity):**

8.5. ~~**Owned/escaping closure values (`*Closure()`)**~~ ✅
   **Landed in M20h** above. Heap-owned, type-erased
   `Closure0` ABI with `__rig_drop`-on-last-strong cleanup.
   PB1 (single retained Effect) folded into M20h(5/5) canary
   refresh.
9. ~~**Resource-aware `Vec(T)`**~~ ✅ **Landed in M20i** above.
   Vec is a resource VALUE TYPE; bare copy rejected; move-only
   transfer; auto-drop guards. Hybrid `dropElement` dispatch
   for Copy / `*T` / `~T` / `*Closure()` elements.
9.1. ~~**Resource-Vec iteration via `for x in ?vec`**~~ ✅
   **Landed in M20i.1** above. External `for` with mode-driven
   sema (Copy element OK in `iter` mode; resource element
   requires `read`) + ownership loop-source borrow + Shape X
   slot-alias emit. PB3 substrate prerequisite shipped.
9.2. ~~**Captured-resource non-consumability audit**~~ ✅
   **Landed in PB3(1/5)** above. Unified `is_loop_borrow` +
   `is_capture_resource` non-consumable-binding helper closed
   the gap where closure bodies could move/drop their captured
   resource handles (UAF on multi-invocation of retained
   subscribers). Must-precede PB3.
9.3. ~~**Multi-subscriber `Signal(T)`**~~ ✅ **Landed in PB3**
   above. Strict R2 (non-reentrant) reactivity primitive. The
   convergence point of Phase B substrate work: heap closures
   (M20h) + resource Vec (M20i) + Vec iteration (M20i.1) +
   captured-resource discipline (PB3(1/5)) compose into Signal.
   Future `Future<T>` async primitive is structurally the same
   shape (resolve-once + waiter list).
9.4. ~~**Reentrant-set queue + library/substrate boundary lock**~~
   ✅ **Landed in PB4** above. Same-Signal reentrant `set`
   relaxed from panic to a queued-coalesced drain loop;
   reentrant `subscribe` stays strict. Locked the position
   that reactive LIBRARIES (`Reactor` / `Memo` / `Effect` /
   batching) are USERLAND work, not future builtins —
   matches Rust/Zig "substrate in language, library in
   userland."
10. ~~`%T` unsafe-effect lattice + `unsafe` block / fn-modifier~~
    ✅ **Landed in M21** above (shipped as `M19` in commits for
    historical conversation continuity per GPT-5.5 entry 35).
    Block-only `unsafe`; prefix `unsafe sub`/`unsafe fun`;
    default-unsafe builtin classification with audited safe
    whitelist; extern call sites are unsafe-by-default at the
    FFI boundary; safe-wrapper pattern documented. SPEC
    §"Unsafe / Raw (M19)" rewritten end-to-end.
11. `pre` AST extraction for derive-style macros
    (REACTIVITY-DESIGN D8)
12. Explicit error sets in `T!E` return types
13. Module path canonicalization (M15b)
14. Guard patterns (`x if cond => body`) — M13-deferred due to
    `if` keyword conflict risk
15. Try-block lowering (still `@compileError`)
16. Expected-type propagation through bindings / calls / returns
17. Opaque types
18. Fold of `effects.zig` into `types.zig` once expression typing
    is rich enough to express "non-fallible expected here" naturally

**Conditional / influence-driven (see `docs/INFLUENCES.md`):**

- **CHAMP-backed persistent collections** (`PersistentVec(T)` /
  `PersistentMap(K, V)`). Architectural target if Phase B's
  notification path demonstrates snapshot-iteration value;
  otherwise indefinitely deferred. Per INFLUENCES.md §7, the
  Nexis project (`/Users/shreeve/Data/Code/nexis`) is the
  Clojure-on-Zig reality check — Rig can borrow architecture
  (CHAMP > HAMT, plain trie, xxHash3, transients) but NOT
  Nexis's GC-backed implementation.
- **Structured concurrency** (scope-bound tasks, automatic
  cancellation propagation). The layer above reactivity and
  below async. Designed before async per INFLUENCES.md §10
  (strategic rules).

**Cross-reference to the substrate ladder** (`docs/INFLUENCES.md` §1):
M20i is **Layer 6** (resource-aware containers). Reactivity
(Layer 7) and structured concurrency (Layer 8) both depend
on it. Async (Layer 9) depends on Layer 5 (already shipped
in M20h) with Layer 8 as a strongly recommended companion.

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

## V1.x — Tooling and semantic-export layer

**Status: documented future work, not actively scheduled.** The
substrate priorities (M26 Cell-non-Copy, then userland reactive
library validation, then Layer 8 / 9) take precedence in V1.
This section captures the design intent so the work is locked
when a real use case pulls it in — Steve's current AI-tooling
workflows go through the existing `bin/rig parse` / `bin/rig
normalize` (S-expression IR) and direct sema inspection without
needing a versioned external schema yet. Land this when an
external tool (editor integration, audit harness, AI peer-review
SDK) materially needs a stable contract.

Once the V1 substrate is locked, the next priority is making the
language's existing semantic facts *consumable* by external tools
(editors, audit harnesses, doc / test / canary generators, AI
peer-review tooling). This layer is a **projection over the
existing `SemContext` + IR Tags** — not a new IR, not a redesign,
not a positioning pivot. The visible-effects thesis (SPEC §Overview
and `docs/SEMANTIC-SEXP.md`) is what makes Rig useful to tooling;
this milestone just exposes those facts cleanly.

### V1.x(1) — `rig sema --json` v0 (stable semantic export)

A versioned, AI/tool-facing JSON projection of `SemContext`. The
exported schema becomes part of Rig's public contract; the internal
S-expression IR remains free to evolve.

**Surface (minimum viable):**

- module / declaration IDs with source spans
- symbol table entries (name, kind, visibility, origin module)
- resolved types (canonical TypeIds + structural rendering)
- effect sets per declaration (fallibility, mutation, raw, pre)
- ownership operations per binding (move / read / write / clone /
  drop / share / weak / raw)
- closure capture lists with mode (`+` / `<` / `~` / value)
- call-graph edges (caller decl → callee decl, kwarg shapes)
- diagnostics carrying semantic IDs, not just line numbers

**Excludes (deliberately):**

- the internal S-expression IR shape (free to evolve; use
  `bin/rig normalize` for the unstable view)
- emit-layer Zig text (use `bin/rig build` for that)
- runtime values / execution traces

**Versioning:** schema version is the contract. Adding fields is
non-breaking; renaming or removing fields requires a version bump.

### V1.x(2) — `rig graph` (derived view, optional)

A dataflow / effect / ownership graph projection over the
`sema --json` export. Introduces no new semantic facts — it
re-renders existing ones into a form better suited for
visualization, dependency analysis, and tool consumption. May
ship experimental at first; hardens once the export schema
proves stable.

### Non-goal: marketing pivot

Rig is **not** "the AI language." The visible-effects thesis is
what makes Rig useful to AI tooling, but the language remains a
systems language with a human-readable surface. Per the
INFLUENCES.md strategic rules: fix the contract, not the
diagram. AI-coding workflows benefit from Rig the same way
editors and static-analysis tools benefit — by reading facts the
language carries explicitly, instead of guessing.

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
