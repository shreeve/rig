# Grammar conflicts

`rig.grammar` has **0** LALR(1) conflicts (`@conflicts = 0`), and uses no
`<` / `>` resolution hints. Nexus fails the parser build if the count
changes, so a new conflict is a deliberate decision recorded here.

The grammar previously had 75. None of them was needed; each class went
away by moving a decision to where the information is:

| Former conflicts | Cause | Resolution |
|---|---|---|
| 27 S/R `inline_body` vs every operand token | A closure was an `atom`, so after `\|x\| f` the parser could not tell `f(...)` (body) from `(\|x\| f)(...)` (call of the closure) | A closure is a lowest-precedence expression (`expr` / `tail`), never an operand, so nothing follows its body |
| 18 S/R `type` vs `T?` / `T!` | One `type` rule mixed prefixes (`?T`, `*T`, `[]T`) and suffixes | Types are stratified: prefixes over `tsuffix` over `tatom`; suffixes bind tighter (`*User?` = shared optional) |
| 4 R/R `fname` vs `atom` | `\|k\| (k)`: `(k)` could be a parameter list or a parenthesized body | Closure parameters are typed (`(a: Int)`); the rewriter makes `a` a `KWARG_NAME`, which no expression starts with |
| 11 S/R `return` / `break` / `continue` vs `POST_IF`, `:`, `\|` | Flow statements were expressions, so they could appear in conditions | `return` / `break` / `continue` are statements (`simple`); a guard `stmt if c` applies to a whole simple statement |
| 8 S/R dangling `else` (if, while ×2, for ×4, postif) | `postif` and ternary forms put an `if ... else` inside expressions that could also be conditions | Conditions are `value` (no block forms); the ternary uses the rewriter's `TERNARY_IF`; an `else` can only follow a block |
| 3 S/R `callarg` / `args` vs `)` `]` `}` | Paren-free juxtaposition calls (`call L(arg)`) inside argument lists; `.{}` / record literals | Paren-free calls are `cmd`, allowed only in tail positions; `.{}` and `Name{}` removed |
| 4 S/R `arg` vs `TERNARY_IF`, `capture` / `unary` vs `BAR_CAPTURE` | Juxtaposed arguments and capture bars probed without spacing | The rewriter classifies `\|` by spacing and closes capture lists by position |

## Where the ambiguity went

The ambiguities are real; they are resolved in the lexer rewriter
(`src/rig.zig`), which can see spacing and look ahead on the line, and
hands the parser distinct tokens:

| Source | Tokens | Rule |
|---|---|---|
| `f(x)`, `a[i]` vs `f (x)`, `f [1]` | `LPAREN_CALL`, `LBRACKET_INDEX` vs `(`, `[` | touching the preceding value continues it |
| `a.b` vs `.red`, `f .red` | `.` vs `DOT_LIT` | `.name` touching a value is member access |
| `a - b`, `a-b` vs `-x`, `f -x` | `MINUS` vs `MINUS_PREFIX` / `DROP_STMT` | a sigil touching its operand and not the value before it is a prefix; `-name` as a whole statement is a drop |
| `a \| b` vs `\|a, +b\| body` | `BAR` vs `BAR_CAPTURE` | same rule; the closing bar is the one the opening probe found |
| `if c` / `stmt if c` / `a if c else b` | `IF` / `POST_IF` / `TERNARY_IF` | after a value (or `return`/`break`/`continue`): ternary when `else` follows on the logical line, otherwise a guard |
| `name:` inside `( )` | `KWARG_NAME` | keyword argument or typed parameter |
| keywords | one token each | every keyword is reserved; `new` only at statement start |

## Nexus notes

* `L(X)` lists are greedy: an internal prefer-shift keeps consuming
  `, X`, and the resulting conflicts are not reported. A rule like
  `L(expr) "," cmd` therefore never reaches `cmd`. Lists followed by a
  comma and something else are written out as left-recursive rules
  (`exprs`, `callargs`).
* A nested S-expression in an action (`(if 3 (block 1))`) is emitted as a
  tag named `(block`; wrap the inner node in its own rule instead
  (`guarded`, `ebody`, `cbody`).
* An empty alternative on the start rule is generated without the start
  marker and never matches; an empty file is handled in `rig.Parser`.
