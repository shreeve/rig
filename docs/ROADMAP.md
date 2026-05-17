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
- `src/runtime_zig.zig`: V1 runtime as a Zig string constant.
  `RcBox(T)` carries `allocator` + `strong: usize` + `weak: usize`
  (implicit `+1` while strong > 0) + `value: T`. `WeakHandle(T)`
  wraps `?*RcBox(T)`. Explicit API names: `cloneStrong`, `dropStrong`,
  `weakRef`, `cloneWeak`, `dropWeak`, `upgrade` (per GPT-5.5: avoids
  ambiguity with library-defined `clone`/`drop` patterns; makes
  emitted Zig readable). `rcNew(anytype)` is the constructor helper.
- Driver (`src/main.zig`): `emitProjectToTmp` writes `_rig_runtime.zig`
  to the same tmpdir as the module .zig files. Single-file and
  multi-file `run` / `build` both get the runtime co-located so the
  per-module `@import("_rig_runtime.zig")` resolves uniformly.
- Emitter (`src/emit.zig`): prelude includes `const rig =
  @import("_rig_runtime.zig");` unconditionally (top-level unused
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
module-scope creation, runtime-baked in `src/runtime_zig.zig`
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
- `src/runtime_zig.zig`: new `rig.Cell(T)` type with
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
