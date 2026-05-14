# Inherited from Zag

Rig V1 inherits Zag's grammar surface and rewriter machinery as the bedrock systems-language plumbing. SPEC.md is authoritative for the **novel** Rig layer (sigils, bindings, `pre`, propagation, ownership-aware iteration, ownership checker). Everything below comes from Zag unless SPEC contradicts it.

If a construct here ever conflicts with SPEC, SPEC wins; we'll patch it and update this doc.

## Lexer

- Indentation tracking (indent stack, `handleIndent`, blank-line skipping, comment-line handling)
- Token shape (8-byte zero-copy via Nexus)
- Comments: `# ...\n`
- Strings: double-quoted with `\` escapes; single-quoted with `''` doubling
- Numbers: hex `0x`, binary `0b`, octal `0o`, decimal int, real
- Identifiers: `[a-zA-Z_][a-zA-Z0-9_]* '?'?` (trailing `?` allowed for boolean predicate names)
- Multi-char operators (longest match): `** == != <= >= && || =! += -= *= /= -> => |> ?? .. << >>`
  - **Rig adds:** `<-` (move-assign)
- Single-char operators: `+ - * / % < > ! ? | & ^ ~ @ = ( ) { } [ ] , : .`
- Rewriter-classified tokens (mirrored from Zag): `bar_capture`, `dot_lbrace`, `post_if`, `ternary_if`
- Rewriter-classified tokens (Rig-specific): `move_pfx`, `read_pfx`, `write_pfx`, `clone_pfx`, `share_pfx`, `weak_pfx`, `pin_pfx`, `raw_pfx`, `drop_stmt`, `prop_q`

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
- `name`
- `! TYPE` — error union
- `? TYPE` — optional
- `* TYPE`, `* const TYPE`, `* volatile TYPE` — pointers
- `[] TYPE`, `[: ATOM] TYPE` — slices
- `[INTEGER] TYPE` — array
- `[*] TYPE`, `[* : ATOM] TYPE` — many-pointer
- `fn ( L(TYPE) ) TYPE`, `fn () TYPE` — function type

### Control flow
- `if`, `while`, `for`, `match` — block forms
- `if cond block else block`, `if cond block else if`, `if cond block else as name block`
- `while cond block else block`, `while cond : EXPR block else block`
- `for [*] name [, name] in EXPR block else block` — Rig adds: source can carry sigil prefix `?xs / !xs / <xs`
- `match EXPR INDENT arms OUTDENT`
- `return [EXPR] [if EXPR]`, `break [: NAME] [EXPR] [if EXPR]`, `continue [: NAME] [if EXPR]`

### Statement modifiers
- `defer` (statement or block)
- `errdefer` (statement or block)
- `inline EXPR`
- `pre EXPR` / `pre block` (was `comptime` in Zag)

### Bindings (Rig)
- `expr = expr` — bind/assign
- `expr =! expr` — fixed bind (Tag: `fixed_bind`; was Zag `const_assign`)
- `expr <- expr` — move-assign (sugar for `expr = <expr`)
- `new name = expr` — explicit shadow (Rig keyword `new`, statement-only at statement head)
- `expr += expr`, `-=`, `*=`, `/=` — compound assigns

### Expressions
- Literals: `INTEGER`, `REAL`, `STRING_SQ`, `STRING_DQ`, `true`, `false`, `null`, `undefined`, `unreachable`
- Records: `Type { name: expr, ... }` and constructor sugar `Type(name: expr, ...)` (per SPEC)
- Anonymous init: `.{ name = expr, ... }` and `.{ expr, ... }`
- Arrays: `[expr, ...]`
- Lambdas: `fn params block`, `fn block`
- Builtins: `@name(args)` — Zig builtin call
- Calls: `f(args)`, `f arg1, arg2` (paren-less, Ruby/Zag style)
- Member: `expr.name`, deref `expr.*`, index `expr[expr]`
- Unary: `! x` (not), `~ x` (bit-not), `& x` (addr-of), `try x`
- Infix table: `|> || && | ^ & == != < > <= >= .. << >> + - * / % **` (precedence per Zag)
- Postfix: `expr ?` propagation (Rig `prop_q`); `expr if cond [else expr]` — postfix-if and ternary

### Patterns (in `match`)
- `atom`, `.name`, `pattern .. pattern`
- `pattern as name => expr`, `pattern as name block`, `pattern => expr`, `pattern block`

### Rig novel surface (NOT inherited)
- 9 ownership sigil prefixes — see SPEC.md
- `pre` (replaces `comptime`)
- `=!` Tag renamed `fixed_bind` (was `const_assign`)
- `<-` move-assign
- `new` explicit shadow
- Value-yielding `try INDENT body OUTDENT [catch BAR_CAPTURE name BAR_CAPTURE INDENT body OUTDENT]`

## Stripped from Zag

- `var` / `const` (binding) / `let` / `:=` paths — never existed in Zag's grammar but called out in SPEC as removed concepts; we don't add them.
- `comptime` keyword spelling — replaced by `pre` (no alias).

## Things to revisit during M1/M2

These come from Zag and likely need ownership/normalization care:

- `defer` / `errdefer` lifetimes interacting with ownership states
- `*T` / `*const T` raw pointers — ownership escape hatch
- `volatile`, `extern`, `callconv`, `packed` — flag as `(unsafe ...)` in IR
- `@builtin(...)` — depends on which builtin; some are pure (`@sizeOf`), some bypass ownership
- `zig "..."` — ultimate escape hatch; flag as `(unsafe-zig ...)`
