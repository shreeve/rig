# Inherited from Zag

Rig V1 inherits Zag's grammar surface and rewriter machinery as the bedrock systems-language plumbing. SPEC.md is authoritative for the **novel** Rig layer (sigils, bindings, `pre`, propagation, ownership-aware iteration, ownership/effects checking). Everything below comes from Zag unless SPEC contradicts it.

If a construct here ever conflicts with SPEC, SPEC wins; we'll patch it and update this doc.

## Lexer

- Indentation tracking (indent stack, `handleIndent`, blank-line skipping, comment-line handling)
- Token shape (8-byte zero-copy via Nexus)
- Comments: `# ...\n`
- Strings: double-quoted with `\` escapes; single-quoted with `''` doubling
  - Single-quoted strings lower to Zig double-quoted strings via the emitter (`'hello'` → `"hello"`); Zig's `'X'` is a `u8` char literal, not a string
- Numbers: hex `0x`, binary `0b`, octal `0o`, decimal int, real
- Identifiers: `[a-zA-Z_][a-zA-Z0-9_]*` (Zag allowed a trailing `?` for boolean predicates; **Rig dropped this** because it would collide with `Bool?` optional-Bool — convention is `is_valid` for booleans)
- Multi-char operators (longest match): `** == != <= >= && || =! += -= *= /= -> => |> ?? .. << >>`
  - **Rig adds:** `<-` (move-assign)
- Single-char operators: `+ - * / % < > ! ? | & ^ ~ @ = ( ) { } [ ] , : .`
- Rewriter-classified tokens (mirrored from Zag): `bar_capture`, `dot_lbrace`, `post_if`, `ternary_if`
- Rewriter-classified tokens (Rig-specific): `move_pfx`, `read_pfx`, `write_pfx`, `clone_pfx`, `share_pfx`, `pin_pfx`, `raw_pfx`, `drop_stmt`, `suffix_q`, `suffix_bang`, `kwarg_name`, `dot_lit`

## Parser surface

### Top-level
- `use NAME` — module import
- `pub`, `extern`, `export`, `packed`, `callconv NAME` — declaration prefixes
- `extern const NAME : TYPE`, `extern NAME : TYPE` — extern variables
- `zig STRING` — raw Zig escape hatch (V1 keeps; checker treats as `(unsafe-zig ...)`)
- `: NAME stmt` — labeled statements

### Declarations
- `fun NAME params returns block` — value-returning function
- `sub NAME params block` — procedure (no return)
- `type NAME = TYPE` — type alias
- `type NAME(T, ...) = ...` — generic type declaration
- `enum NAME INDENT members OUTDENT`
- `struct NAME INDENT members OUTDENT`
- `error NAME INDENT members OUTDENT`
- `opaque NAME`
- `test STRING block`

### Members
- `name`, `name : TYPE`, `name : TYPE align ATOM`, `name : TYPE = EXPR`
- `pre name : TYPE` (was `comptime name : TYPE` in Zag)
- `name = EXPR` (valued enum/error variant)

### Types

The `?` / `!` triangle (Rig-specific cleanup of Zag's overloaded `?`/`!`):

- `?T` — read-borrowed type (`(borrow_read T)`); Rig replaces Zag's `? TYPE` for "optional"
- `!T` — write-borrowed type (`(borrow_write T)`); Rig replaces Zag's `! TYPE` for "error union"
- `T?` — optional type (`(optional T)`)
- `T!` — fallible type / error union (`(error_union T)`)

Other type forms inherited from Zag:

- `name`
- `(TYPE)` — parens for grouping (e.g., `([]T)?` is "optional slice of T")
- `[] TYPE`, `[: ATOM] TYPE` — slices
- `[INTEGER] TYPE` — array
- `fn ( L(TYPE) ) TYPE`, `fn () TYPE` — function type

**Pruned from Zag's grammar in M4.5b** (broken/unused):

- `* TYPE`, `* const TYPE`, `* volatile TYPE` — raw pointer types
- `[*] TYPE`, `[* : ATOM] TYPE` — many-pointer types

These tokenized incorrectly under Rig's `share_pfx` rewriter (which requires an operand-start char after `*`) and weren't part of Rig V1's surface anyway. Real pointer types come back in M5+ via the stdlib (e.g., `Box(T)`).

### Control flow
- `if`, `while`, `for`, `match` — block forms
- `if cond block else block`, `if cond block else if`, `if cond block else as name block`
- `while cond block else block`, `while cond : EXPR block else block`
- `for [*] name [, name] in EXPR block else block`
  - Rig adds: source can carry sigil prefix `?xs / !xs / <xs`
  - Unified IR: `(for <mode> binding1 binding2-or-_ source body else?)`, `mode ∈ {iter, read, write, move, ptr}`
- `match EXPR INDENT arms OUTDENT`
- `return [EXPR] [if EXPR]`, `break [: NAME] [EXPR] [if EXPR]`, `continue [: NAME] [if EXPR]`

### Statement modifiers
- `defer` (statement or block)
- `errdefer` (statement or block)
- `inline EXPR`
- `pre EXPR` / `pre block` (was `comptime` in Zag)

### Bindings (Rig)

All binding forms collapse into a single `(set <kind> name type-or-_ expr)` IR shape (emitted directly by the grammar via Nexus tag-literal-at-child support). See `docs/SEMANTIC-SEXP.md`.

- `name = expr` — bind/assign (`<kind>` = `_`, default)
- `name =! expr` — fixed (immutable) bind (`<kind>` = `fixed`)
- `name <- expr` — move-assign (`<kind>` = `move`)
- `new name = expr` — explicit shadow (`<kind>` = `shadow`; statement-only at statement head)
- `name += expr`, `-=`, `*=`, `/=` — compound assigns (`<kind>` = the op tag)
- Typed forms: `name: T = expr`, `name: T =! expr` — same kinds, type slot populated

### Expressions

- Literals: `INTEGER`, `REAL`, `STRING_SQ`, `STRING_DQ`, `true`, `false`, `null`, `undefined`, `unreachable`
- Records: `Type { name: expr, ... }` and constructor sugar `Type(name: expr, ...)`
  - Both lower to the same `(call T (kwarg ...) ...)` IR
- Anonymous init: `.{ name = expr, ... }` and `.{ expr, ... }`
- Arrays: `[expr, ...]`
- Lambdas: `fn params block`, `fn block`
- Builtins: `@name(args)` — Zig builtin call (lexer's `pin_pfx` only fires on `@name` NOT followed by `(`)
- Calls: `f(args)`, `f arg1, arg2` (paren-less, Ruby/Zag style)
- Member: `expr.name`, deref `expr.*`, index `expr[expr]`
- Unary: `not x` (logical not — keyword form), `! x` (write borrow when tight), `~ x` (weak), `& x` (addr-of), `try x`
- Infix table: `|> || && | ^ & == != < > <= >= .. << >> + - * / % **` (precedence per Zag)
- Postfix: `expr!` propagation; `expr if cond [else expr]` — postfix-if and ternary
- Enum literals: `.name` at expression-start context (`dot_lit`)

### Patterns (in `match`)
- `atom`, `.name`, `pattern .. pattern`
- `pattern as name => expr`, `pattern as name block`, `pattern => expr`, `pattern block`

### Rig novel surface (NOT inherited)

- 9 ownership sigil prefixes — see SPEC.md
- `pre` (replaces `comptime`)
- `<-` move-assign
- `new` explicit shadow
- Suffix `!` for error propagation (`expr!`)
- Suffix `?` reserved for future optional-propagation
- `?T` / `!T` borrowed-type prefixes; `T?` / `T!` optional/fallible suffixes
- Value-yielding `try INDENT body OUTDENT [catch BAR_CAPTURE name BAR_CAPTURE INDENT body OUTDENT]`

## Stripped from Zag

- `var` / `const` (binding) / `let` / `:=` paths — never existed in Zag's grammar but called out in SPEC as removed concepts; we don't add them.
- `comptime` keyword spelling — replaced by `pre` (no alias).
- Trailing-`?` predicate identifiers (`valid?`) — collides with `T?` optional suffix.
- Raw pointer type forms (`*T`, `* const T`, `* volatile T`, `[*]T`, `[*:s]T`) — pruned in M4.5b.

## Things to revisit during M5+

These come from Zag and need typed-flow / ownership / lowering attention:

- `defer` / `errdefer` lifetimes interacting with ownership states (M5/M6 typed flow)
- `volatile`, `extern`, `callconv`, `packed` — flag as `(unsafe ...)` in IR
- `@builtin(...)` — depends on which builtin; some are pure (`@sizeOf`), some bypass ownership
- `zig "..."` — ultimate escape hatch; flag as `(unsafe-zig ...)`
- `match` lowering (currently emits `@compileError` in M3)
- `try_block` lowering (currently emits `@compileError` in M3)
- Generic type declaration lowering (`type Box(T)` parses but doesn't emit)
