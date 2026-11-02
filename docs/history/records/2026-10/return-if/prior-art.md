# `return if`: prior art (reviewer 3 of 3)

## (a) Postfix guard and value `if` after `return` in one language

| Language | Postfix guard | Value `if` after `return` | How it is resolved |
|---|---|---|---|
| Perl | `return if $x;` | none | only the guard exists |
| Ruby | `return if x` | `return (if x then a else b end)` | **Lexically, always a guard.** After `return`/`break`/`next` the lexer is not at expression start, so `if` is the modifier keyword. Verified on Ruby 4.0.9: `return if x > 0` with an indented `"positive" / else / end` below is a syntax error; the parenthesized form works. |
| Crystal | as Ruby | as Ruby | as Ruby: always a guard |
| CoffeeScript | `return if x` | `return if x` + indented block | **By lookahead**, as #871 does: the rewriter's `tagPostfixConditionals` scans from each `IF` to the line's end; reaching a terminator makes it `POST_IF`, reaching an INDENT keeps a block `if`. CoffeeScript is the only language I know with #871's rule, and "the next line or a space changes the parse" is its best-known complaint (implicit calls, `a ?b`); |
| Elixir | none (no `return`) | n/a | no early return at all |
| Rust | none | `return if c { a } else { b };` | braces delimit; no guard form to clash with (guards are `let … else`, `if c { return }`) |
| Kotlin | none | `return if (c) a else b` | parentheses delimit; no guard form |
| Swift | none (`guard c else { return }`) | `return if c { a } else { b }` (5.9, SE-0380; verified) | braces; the guard is a separate keyword |
| Scala | none | `return if (c) a else b` | parentheses; `return` itself discouraged |
| Nim | none | `return (if c: a else: b)` | `result`/last expression preferred |
| Python | none | `return a if c else b` | postfix `if` is the ternary, and needs `else` |

Finding: every language with a postfix guard (Perl, Ruby, Crystal) makes
`return if` a guard, always, decided by the token alone. Every language
with a value `if` after `return` has no postfix guard, or delimits the
condition with braces or parentheses. Only CoffeeScript lets the following
line decide, and it is the cautionary example, not the model.

## (b) A needless `return` in tail position

| Language | Treatment |
|---|---|
| Ruby | allowed; RuboCop `Style/RedundantReturn` flags it, enabled by default, autocorrected |
| Crystal | allowed; Ameba `Style/RedundantReturn` flags it |
| Rust | allowed; clippy `needless_return`, warn by default (style group) |
| Kotlin | required in block bodies; IDE offers "lift return out of if" and expression bodies (`= if …`) |
| Swift | allowed; no lint by default (implicit return for single expressions, SE-0255) |
| CoffeeScript, Nim, Python | allowed, no diagnostic |

No compiler rejects it; every rejection is a linter's, and opt-out. The
community consensus (RuboCop, clippy) is that tail `return` is poor style,
and it is enforced by tools that can be silenced, which Rig does not have
(errors only).

## Judgment for Rig

1. **Undo #871's lookahead.** Ruby's rule (the token decides, the next line
   never does) is the one users of postfix guards already know; Rig's
   SYNTAX says "like Ruby's statement modifier". #871 adopts
   CoffeeScript's rule, the weakest prior art.
2. **Reject a guard followed by a deeper block,** with a Rig diagnostic
   naming both fixes. Ruby rejects it too, but with an unhelpful
   "unmatched end"; Rig can do better. This keeps `return if c` on its
   own line exactly as now.
3. A value after `return` stays possible delimited, as in Ruby/Kotlin:
   the ternary `return a if c else b`.
4. **Add no rule against tail `return`.** No compiler in this set rejects
   it; only linters warn, and Rig has no warnings. Rejecting it would
   break the "add `return` and it still works" property users expect
   from every language above. Show the idiom (drop `return`) in SYNTAX
   and let a future `rig fmt`/STYLE.md carry the preference, as RuboCop
   and clippy do.
