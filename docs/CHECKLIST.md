# Rig Checklist

Living checklist. Tick as we go. Source of truth for milestone progress.

## M0 — Parser online

- [x] `docs/ROADMAP.md`, `docs/CHECKLIST.md`, `docs/INHERITED-FROM-ZAG.md` exist
- [x] `build.zig` builds `bin/rig`
- [x] `zig build parser` regenerates `src/parser.zig` via Nexus
- [x] `src/rig.zig` defines `Tag`, `KeywordId`, `keywordAs`, `Lexer` rewriter
- [x] Lexer rewriter classifies the 9 ownership sigils + `prop_q` + `kwarg_name` + `dot_lit`
- [x] `rig.grammar` parses Rig V1 surface
- [x] Conflict count = 20 (Zag baseline 19; +1 for kwarg/callarg split)
- [x] `src/main.zig` wires `rig parse | tokens | normalize | check | build | run`
- [x] `examples/{hello,move,borrow,drop,fixed,shadow,escape,showcase,spacing}.rig` exist
- [x] `test/run` passes (20/20); goldens locked in `test/golden/raw_sexp/`
- [ ] M0 commit landed
- [ ] GPT-5.5 fresh-review pass on grammar + goldens

### M0 design notes (for posterity)

**Sigil tokenization strategy.** Six rewriter tokens carry context that the
grammar can't see in one-token lookahead:

| token       | from   | when                                                     |
|-------------|--------|----------------------------------------------------------|
| `move_pfx`  | `<`    | tight prefix, expression-start context                   |
| `clone_pfx` | `+`    | tight prefix, expression-start context                   |
| `share_pfx` | `*`    | tight prefix, expression-start context (excl. `.*`)      |
| `read_pfx`  | `?`    | tight prefix, expression-start context                   |
| `write_pfx` | `!`    | tight prefix, expression-start context                   |
| `pin_pfx`   | `@`    | tight prefix, ident-followed, NOT followed by `(`        |
| `raw_pfx`   | `%`    | tight prefix, expression-start context                   |
| `drop_stmt` | `-`    | tight prefix, statement-start, ident operand             |
| `prop_q`    | `?`    | postfix, value-ender preceding, no space before          |
| `kwarg_name`| IDENT  | inside parens, immediately followed by `:`               |
| `dot_lit`   | `.`    | expression-start context, ident-followed                 |

The "tight prefix" rule mirrors Zag's `classifyMinus`: no space after AND
either expression-start context OR (value-ender preceding with space-before).
This makes `f <x` (Ruby-style arg in a paren-less call) classify the same
as `<x` (statement-start), without breaking `a < b` (infix lt).

`~x` (weak) and `&x` (addr-of) need no rewriter token — `~` has no infix
role in Rig V1 (we drop Zag's bit-not), and `&` is handled by Zag's
existing `unary = "&" unary → (addr_of 2)` rule.

**Block continuation.** Indent-handler's "skip newline before continuing
keyword" trick (Zag's `nextTokenIsElse`) was extended to also recognize
`catch`, so multi-line `try` block / `catch |err|` block parses cleanly.

**Closing `|` in `|name|`.** Zag's `bar_capture` only classified the
opening `|`; Rig adds a `pending_close_bar` flag so the closing `|` is
also classified, which the grammar requires for the value-yielding
try/catch block.

**Typed bindings out of expr.** `typed_assign` and `typed_fixed` are now
stmt-only (not in `expr`), eliminating the `name : type =` vs
`name : expr` (kwarg) collision in call args.

## M1 — Semantic normalizer

- [x] `docs/SEMANTIC-SEXP.md`
- [x] `src/normalize.zig` implements every SPEC §"Semantic IR Nodes" form
- [x] Goldens in `test/golden/semantic_sexp/` (9 examples, all stable)
- [x] `bin/rig normalize <file.rig>` works
- [x] Test runner extended; 29/29 tests passing
- [ ] M1 commit landed

### M1 design notes

Per GPT-5.5 review, **`=` normalizes to `set`** (neutral term) instead of
`assign` — M2 is the right place to decide bind-vs-rebind. Other
cosmetic renames make the IR self-documenting:

- `(. obj name)` → `(member obj name)`
- `(pair name expr)` → `(kwarg name expr)`
- `(? T)` → `(optional T)`

The `for` rewrite consumes the source's sigil into the head Tag:

  `(for u _ (read xs) body)` → `(for_read u xs body)`
  `(for u _ (write xs) body)` → `(for_write u xs body)`
  `(for u _ (move xs) body)` → `(for_move u xs body)`

`move_assign` desugars to `(set target (move expr))` so M2 sees the
move semantics explicitly without a special-case head.

`(fixed_bind name e)` and `(shadow name e)` keep their semantic Tag
heads — they're already binding-classified.

`(propagate x)` is preserved; M3 lowers it to Zig `try x`.

## M2 — Ownership checker

- [ ] `src/ownership.zig` implements SPEC §"Ownership Checker V1"
- [ ] All SPEC §"V1 Test Cases" pass/fail as specified
- [ ] Source-pointed sigil-aware diagnostics
- [ ] Goldens in `test/golden/errors/`
- [ ] M2 commit landed

## M3 — Zig emitter

- [ ] `src/emit.zig` targets Zig 0.16 (Juicy Main, std.Io)
- [ ] Goldens in `test/golden/emitted_zig/`
- [ ] `zig ast-check` clean on every emitted file
- [ ] M3 commit landed

## M4 — `rig` binary

- [ ] `bin/rig run examples/hello.rig` prints "hello"
- [ ] M4 commit landed

## SPEC-aligned vs inherited-pending-review

Constructs Zag provides that Rig should validate against SPEC during M1/M2:

- `defer` / `errdefer` interaction with ownership lifetimes
- `extern` / `callconv` / `volatile` / `align` / `packed` — ABI escapes; should normalize as `(unsafe ...)` so the checker can fence/warn
- `inline` distinct from `pre` (inline at call site vs evaluate at compile time)
- `@builtin(...)` — keep as-is; document the set Rig vendors
- raw `zig "..."` escape — keep as ultimate hatch; normalize as `(unsafe-zig ...)`

## Nexus suggestions (do not modify Nexus; surface to user)

(empty — log here as we discover them)
