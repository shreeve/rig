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

The `for` rewrite consumes the source's sigil into a child mode Tag
per SPEC §"Semantic IR Nodes" — `(for mode binding collection body)`:

  `(for u _ (read xs) body)`  → `(for read u xs body)`
  `(for u _ (write xs) body)` → `(for write u xs body)`
  `(for u _ (move xs) body)`  → `(for move u xs body)`
  `(for u _ source body)`     → `(for _ u source body)`

Mode is `_` (nil) when there's no sigil — matching the existing IR
convention for "absent slot" (e.g., `(sub main () _ block)` already
uses `_` for the missing returns position). Single `for` head Tag,
no `none` Tag noise, downstream passes switch on one head.

`move_assign` desugars to `(set target (move expr))` so M2 sees the
move semantics explicitly without a special-case head.

`(fixed_bind name e)` and `(shadow name e)` keep their semantic Tag
heads — they're already binding-classified.

`(propagate x)` is preserved; M3 lowers it to Zig `try x`.

## M2 — Ownership checker

- [x] `src/ownership.zig` implements SPEC §"Ownership Checker V1"
- [x] All 7 SPEC §"V1 Test Cases" pass/fail as specified
- [x] Source-pointed sigil-aware diagnostics with `note:` lines
- [x] Goldens in `test/golden/errors/` (9 examples; 5 with diagnostics)
- [x] `bin/rig check <file.rig>` works (exit 0 clean, 1 with errors)
- [x] Test runner extended (38/38), unit tests added (24 passing, no leaks)
- [ ] M2 commit landed

### M2 design notes

**Per-scope binding tables.** A stack of scopes; each scope holds a list
of binding indices into a flat `bindings` array. `lookup` walks parent
scopes; `lookupCurrent` is for shadow-collision detection.

**Path borrows lock the root** (V1 conservative per SPEC). `(read (member
user name))` increments `user.read_borrows`; the root binding is what
the checker tracks. Future precision can refine this to per-path.

**Temporary vs bound borrows.** Per SPEC §"Borrow Lifetime":

- Temporary borrows (`print ?user`) end at statement end. Tracked via a
  `temp_borrows` stack pushed by `walkBorrow` and drained by `walkStmt`.
- Bound borrows (`r = ?user`) live until `r`'s scope exits. The set/bind
  walker detects RHS borrows, claims (removes) the corresponding entry
  from `temp_borrows`, and records `borrow_root_index` on the binder.
  Scope-pop releases all borrows owned by departing bindings.

**RHS-first evaluation.** Per GPT-5.5: `(set x (move y))` evaluates RHS
first (move `y`), then binds/reassigns `x`. This is correct for
ownership-flow semantics.

**Borrow-escape rule (SPEC §V1 #7).** A function whose return type is
outer-`(optional T)` (treated as borrowed return) has each implicit-
return statement checked: returned `(read X)` / `(write X)` must root
in a parameter that was also typed `(optional T)`. The check runs
inside `walkFun` BEFORE the body's scope is popped, so the parameter
binding is still in scope.

**Diagnostic format.**

  `<file>:<line>:<col>: error: <message>`
  `<file>:<line>:<col>:   note: <message>`

Compatible with editor jump-to-error. Goldens are byte-diffed.

**Detected violations** (with sample diagnostics):

| Rule | Source                         | Diagnostic                                                              |
|------|--------------------------------|-------------------------------------------------------------------------|
| #1   | `send <packet; log ?packet`    | `use of \`packet\` after move` + note pointing at `<packet`             |
| #2   | `r = ?user; rename !user`      | `cannot write-borrow \`user\` while a read borrow is live`              |
| #3   | `w = !user; print ?user`       | `cannot read-borrow \`user\` while a write borrow is live`              |
| #4   | `-user; print ?user`           | `use of \`user\` after drop` + note pointing at the drop                |
| #5   | `x = 1; new x = 2`             | (no error; explicit shadow allowed)                                     |
| #6   | `user =! foo; user = bar`      | `cannot reassign fixed binding \`user\``                                |
| #7   | `fun bad() -> ?String { ... }` | `returned borrow of \`user\` does not originate from a borrowed parameter` |
| bonus| `-x; -x`                       | `cannot drop \`x\` twice`                                               |
| bonus| `-x` then read of `x`          | `cannot drop \`x\` while borrows are live`                              |
| bonus| reference to unbound name      | `use of unbound name \`x\``                                             |

## M3 — Zig emitter

- [x] `src/emit.zig` targets Zig 0.16 (plain `pub fn main() !void`, `std.debug.print` for V1)
- [x] Goldens in `test/golden/emitted_zig/` (hello, shadow)
- [x] `zig ast-check` clean on every emitted file
- [x] Per-fn pre-scan for mutation (chooses `var` vs `const`) and fallibility (`!T` only when body has `propagate`)
- [x] Auto-prefix `try` at call sites of fallible functions (per GPT-5.5 advice)
- [x] Shadow renames: `new x` becomes `x_1` with `_ = x;` to silence Zig's unused-local check
- [x] `try_block` and complex if/match-as-expression emit `@compileError(...)` for V1
- [x] 4 new emit unit tests pass
- [ ] M3 commit landed

## M4 — `rig` binary

- [x] `bin/rig run examples/hello.rig` spawns `zig run` on emitted Zig and prints "hello, rig"
- [x] End-to-end test in `test/run` verifies hello output
- [ ] M4 commit landed

### M3/M4 design notes

**Per-function pre-scan.** Before emitting each fn body:

  1. `containsPropagate(body)` decides if the fn is fallible (`!T`).
  2. `scanMutations(body)` collects names that are `set` more than once;
     these get `var`, others get `const` (Zig's strict rule).

**`print x` lowering.**

  - String literals → `std.debug.print("{s}\n", .{x})`
  - Other args → `std.debug.print("{any}\n", .{x})`
  - V1 supports a single arg.

**Implicit return.** `fun add(a,b) -> Int { a + b }` rewrites the last
expression-statement to `return a + b;`. `sub` (no return) doesn't.

**Constructor sugar.** `User(name: "Steve")` emits `User{ .name = "Steve" }`
(Zig struct literal) when ANY arg is a `(kwarg ...)`, else regular call.

**Auto-`try`.** A bare call to a fallible function gets `try` prefixed
unless we're already in a `try` / `propagate` context (tracked by
`in_try_context`). This makes `result = add(1, 2)` work even when
`add` is `!i32`.

**End-to-end pipeline.** `rig run examples/hello.rig`:

  1. Parse Rig source via the Nexus-generated parser.
  2. Normalize to semantic IR.
  3. Emit Zig 0.16 source to `/tmp/rig_<basename>.zig`.
  4. Spawn `zig run /tmp/rig_<basename>.zig` with inherited stdio.
  5. Pass through exit code.

`hello.rig` → `hello, rig` end to end, validated by `test/run`'s
"End-to-end run" section.

## IR uniformity refactors (post-V1 polish)

- [x] `for_read` / `for_write` / `for_move` / `for_none` collapsed into `(for mode binding source body)` per SPEC.
- [x] `for` mode uses `_` (nil) for "no mode" (matches existing IR convention; no `none` Tag needed).
- [x] `typed_set` / `typed_fixed` collapsed into `set` / `fixed_bind` with a type slot. All bind forms now use uniform 4-child shape `(<head> name type-or-_ expr)`.
- [x] `extern_var` / `extern_const` collapsed into `(extern_decl <kind> name type)`.

Future candidates (not yet pursued):

- decoration wrappers (`pub`/`extern`/`export`/`packed`/`callconv`) could become a uniform `(decorate <kind> child)` with `(callconv "C")` carrying its name. Low priority — current wrappers are clear.

## SPEC-aligned vs inherited-pending-review

Constructs Zag provides that Rig should validate against SPEC during M1/M2:

- `defer` / `errdefer` interaction with ownership lifetimes
- `extern` / `callconv` / `volatile` / `align` / `packed` — ABI escapes; should normalize as `(unsafe ...)` so the checker can fence/warn
- `inline` distinct from `pre` (inline at call site vs evaluate at compile time)
- `@builtin(...)` — keep as-is; document the set Rig vendors
- raw `zig "..."` escape — keep as ultimate hatch; normalize as `(unsafe-zig ...)`

## Nexus suggestions (do not modify Nexus; surface to user)

(empty — log here as we discover them)
