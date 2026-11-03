# Panel round 2: the one-armed match, the Rust view

Probes run with `bin/rig` in worktree `incredible-project-25d019` (main at
122d523bf), `RIG_SANITIZE=1`, `RIG_OUT_DIR` in a scratch folder. Files
beside this one: `rust2-today.rig` (today's one-arm form, runs clean,
prints `0 1 1 img`), `rust2-grammar.diff` (the grammar change below,
which Nexus generates with no LALR conflicts).

## What Rust learned (the short version)

- **`if let` reads backwards.** `if let PAT = EXPR` puts the pattern
  first and borrows `let`, a binding word, for a test. It took Rust from
  2018 (RFC 2497) to 1.88 in 2025 to get `if let ... && let ...` chains,
  and an `is` operator (`if expr is Some(x) && x > 0`, RFC 3573) was
  proposed because the subject-first order reads better and composes
  with `&&`. Rig already has the right shape: subject first, joined by
  `and`. Only the word after the subject is wrong.
- **`matches!` exists because `if let` is not an expression.** It is
  among Rust's most used macros, mostly for ranges and variant tests
  (`matches!(b, b'0'..=b'9')`, `matches!(s, State::Ready(_))`). A test
  word that is a `Bool` anywhere removes the need.
- **`let-else` (1.65) exists for early exit.** Rig's `?? break` /
  `?? return` already covers the optional case, which is most of it.
- **Nested patterns are used everywhere** (`Some(State::Ready(Some(x)))`,
  `Ok(Some(x))`). Their real value is not depth but that one pattern
  takes one binding mode for every name it binds.
- **Binding modes were Rust's mistake to hide.** Match ergonomics
  (RFC 2005) infers move-vs-ref from the subject's type; with `ref`,
  `ref mut`, `&` inside patterns, it confused enough people that the
  2024 edition had to forbid mixing them (RFC 3627). And Rust's
  `if let State::Ready(Some(r)) = entry.state` moves out of `entry`
  with no mark at all. Rig's subject sigil (`<`, `?`, `!`) is the
  explicit version of Rust's default binding mode; keep it, and let it
  reach every name in a nested pattern.

## 1. The ideal one-arm spelling

```rig
if <entry.state is .ready(rendered?)
  !@retired.push(<rendered.image)
```

It need not say `match`. The one-arm form is a *condition*: it joins
with `and` (`if s is .circle(r) and r > 10`), drives `while`
(`while q.next() is .item(x)`), and should be a `Bool` in a closure
(`.filter(|e| e.value.state is .ready(_))`). `match` is a statement that
opens a block of arms; inside a condition it reads as nothing English
(`if s match .ready(r)`), and `matches` is the only grammatical variant
(seven letters, second choice). `is` is the word other languages already
use for exactly this: C# `x is Ready r`, Kotlin's `is` smart cast,
TypeScript's `x is T`, Swift's `is`, Rust's own `is` RFC, and Python's
`x is None`, which means the same thing in Rig if `none` is a pattern.

It *is* the full match: the parser already rewrites the one-arm form
into `match S` with the arm `P` and a hidden `_ => pass`
(`Parser.asMatch`, src/rig.zig:3738). Teach it that way: "`x is P` is a
`match` with the one arm `P`; true when it matches." Same subject, same
sigil, same pattern as the full match, so the two read as one idea:

```rig
match <entry.state
  .ready(rendered?) => !@retired.push(<rendered.image)
  _ => pass
```

Today the first form fails at `is` (`unexpected name 'is'`) and the
second at `?` (`unexpected '?'; expected ',' or ')'`).

## 2. Swiss's narration as code

"If the entry we just removed was ready and holds a rendered result,
move that result's image onto the retired list."

```rig
entry = !@entries.take(key) ?? break
if <entry.state is .ready(rendered?)
  !@retired.push(<rendered.image)
```

Phrase to token: *the entry we just removed* `entry = !@entries.take`;
*was ready* `is .ready`; *holds a rendered result* `rendered?`; *move*
`<`; *onto the retired list* `!@retired.push`. The `<` on the subject
says the state is consumed, which the sentence implies ("removed").

## 3. Nested patterns: yes, a small set

Worth adding, in two pieces, both inside a payload and at a `match`
arm's top:

- `x?`: the optional holds a value, bound to `x`; and `none`. This
  matches the expression meaning of postfix `?` ("the value inside, if
  there is one") and Swift's `let x?`. It also makes `match` work on an
  optional, rejected today ("cannot `match` on a value of type
  `Rendered?`").
- `.variant(...)` inside a payload: `.ready(.done(x))`.

Grammar, one line (the `pbind` rule):

```
pbind = psub | KWARG_NAME ":" psub ;  psub = name | name "?" | "." name ["(" pbinds ")"]
```

plus `| name "?"` in `pattern` and `| value:cmp IS pattern:pattern →
(is_pattern)` in `neg`. Nexus builds it with no conflicts (2,098 states,
`rust2-grammar.diff`). Not built into `bin/rig`: the wrapper and the
checkers would need the two new node kinds.

Cost is in the checker, not the grammar: exhaustiveness and unreachable
arms over nested patterns need the matrix (usefulness) algorithm Rust
uses, not today's flat check. Optionals add only {`none`, `x?`} per
level, so stage 1 (`x?` and `none`, any depth) is small; full nested
variants can follow. Measured demand: Rig and Trig have 11 places where
a match arm binds a payload and the next line is `if xs as list`
(e.g. Trig `commandlineoption.rig:199`, `.Strings(xs)` then
`if xs as list ... else .Strings(xs: none)`), which become
`.Strings(list?)` and `.Strings(none)` arms. Trig's AST is kinds over
node ids, so deeper nesting is rarely needed there; it has 854 `match`es
and no `as .pattern` at all.

Not proposed: object patterns (`Rendered(image: img)`, Rust's struct
patterns). Moving the field out is one `<rendered.image` at the use,
which is clearer.

## 4. Where the moves go

One `<` on the subject, and one where the value actually changes hands:

```rig
if <entry.state is .ready(rendered?)      # the state is consumed: every binding is owned
  !@retired.push(<rendered.image)         # the image moves into the list
```

The subject's sigil sets the mode of every name the pattern binds,
nested ones included: `<` owned, bare or `?` read views, `!` write
views. No sigil ever stands inside a pattern; that is Rust's
`ref`/`ref mut`/`&`-in-patterns trap, which Rig avoids by construction.
Fields a `<` pattern leaves out drop at the end of the block, as today.

Today the same code needs three `<`, because the inner `as` has its own
subject: `if <entry.state as .ready(r) and <r as rendered`. With only
the outer one (`and r as rendered`), `rendered` is a view and
`<rendered.image` is rejected ("`rendered` is a view"), so nesting is
what removes the middle `<`. The second `<` is not noise: it is a
second move, from `rendered` into the list; Rust hides both.

A diagnostic to fix on the way: with `rendered` owned,
`!@retired.push(rendered.image)` says only "write `+rendered.image` to
pass a clone". It should offer the move first, as the `=` error already
does ("write `<x` to move it, `+x` to clone it"). An AI that reads the
hint clones, which is exactly the needless `.clone()` in the Rust
original.

## 5. What `as` becomes

**Kept, for naming only; patterns move to `is`.** `as` names a value:
an optional's (`if o as x`), several results (`if f() as a, b`), a
module (`use m as n`): the meaning people know from Python's
`with ... as f`, `except E as e`, `import x as y`, and SQL. `is` tests a
shape and may bind the pattern's names. One word per idea: `as` names,
`is` tests.

Rules for `is`:

- Takes any refutable pattern: variants, literals, ranges
  (`c is 'a'..='z'`, the commonest `matches!`), constants, `x?`,
  `none`. A bare name (always matches) is rejected, as Rust warns on an
  irrefutable `if let`.
- Binds names only in an `if` or `while` condition joined by `and`
  (as `as` today); elsewhere, under `or`/`not`, and in a closure body,
  its pattern binds nothing and the whole is a `Bool`.
- One pattern, no alternatives: the comma would clash with arguments
  (`f(x is .a, .b)`); several variants take a `match`.
- `o is x?` at the top is the long spelling of `o as x`; reject it
  with "write `if o as x`" so each idea has one spelling.
- `x as .pattern` is rejected with "write `x is .pattern`". Migration:
  about 87 lines in Rig's docs and tests, 0 in Trig, `s/ as \./ is ./`
  in conditions; a release-notes entry and a one-line Trig note.

`is` is not a keyword today, and no Rig or Trig code uses it as a
name (checked by grep: only prose in strings and comments).

## What works today, what does not

| Form | Today |
|---|---|
| `match <entry.state` / `.ready(r)` / `if <r as rendered` / `_ => pass` | runs clean |
| `if <entry.state as .ready(r) and <r as rendered` + `<rendered.image` | runs clean |
| `if <entry.state as .ready(r)` / `rendered = <r ?? return` | runs clean |
| outer `<` only (`and r as rendered`) + `<rendered.image` | rejected: `rendered` is a view |
| `.ready(rendered?)` in a `match` arm | parse error at `?` |
| `if <entry.state is .ready(rendered?)` | parse error at `is` |
| `ok = entry.state as .ready(_)` | rejected: `as` binds only in an `if`/`while` condition |
| `match <r` on a `Rendered?` with `none =>` | rejected: no match on optionals |
| grammar with `is` + `x?` + nested payload patterns | Nexus: no conflicts |
