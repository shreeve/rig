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

### M6+ — Beyond V1
Generics lowering (parsed in M0, type-checked in M5, not yet emitted),
match/try-block lowering (currently `@compileError` placeholders),
stdlib seed (Vec, HashMap, String, Result, Option), module system,
LSP, async/coroutines, and the eventual fold of `effects.zig` into
`types.zig` once expression typing is rich enough to express
"non-fallible expected here" naturally.

## Beyond V1 (deferred per SPEC §V2/V3)

Async, advanced shared ownership, allocator traits, reflection, full trait/interface system, advanced lifetime inference, richer pre-metaprogramming.

Parsed-but-lightly-enforced for V1: shared, weak, pin, unsafe/raw.

## Non-goals

- LLVM backend (Zig handles it)
- Garbage collection (ownership instead)
- Macro system (favor `pre` + library design)
- Trait system V1 (deferred)
