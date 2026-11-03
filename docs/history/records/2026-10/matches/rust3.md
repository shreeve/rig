# Panel round 3: `matches`, the Rust view

Counts are from Trig's `src/` (308 `.rig` files, 194,263 lines) with a
script that finds each `match` and its arms by indentation
(scratch: `count.py`), plus `rg` for `==` chains. "Hand" excludes the
two generated files (`ast_generated.rig`, `options_generated.rig`).
Probes ran with `bin/rig` in worktree `incredible-project-25d019`.

## What Rust learned about alternatives

- **One spelling, every depth.** Rust's `|` was in match arms from 1.0.
  It reached `if let` / `while let` in 1.33 (RFC 2175) because users kept
  hitting the gap, and nested positions (`Some(A | B)`) in 1.53
  (RFC 2535). Each step was the same operator in a new place; nothing
  new to learn. Clippy's `unnested_or_patterns` now nudges
  `Some(A) | Some(B)` to `Some(A | B)`. The 2021 edition widened the
  macro fragment `$p:pat` to take a top-level `|` (old meaning kept as
  `pat_param`).
- **`matches!` is mostly alternatives.** It lived as the `matches` crate
  for years before std took it (1.42). Its typical uses are
  `matches!(c, b' ' | b'\t' | b'\n')`, `matches!(c, 'a'..='z' | '_')`,
  `matches!(k, Kind::Fn | Kind::Method)`: a set of shapes, often with
  ranges, rarely a single variant. A test word without alternatives
  would cover the minority case.
- **Rust uses `|` because its arms end in commas.** The comma was taken.
  Rig's arms end at a newline, which freed the comma for alternatives;
  the moment a pattern stands inside a line (`matches`), Rig meets the
  same clash Rust designed around from the start.
- **Rust's own `|` clash is small and loud.** A top-level or-pattern in
  a closure's parameters needs parentheses, `|(Ok(x) | Err(x))|`,
  because `|` would close the list. The parser rejects the bare form;
  nothing changes meaning silently.
- **Bindings in alternatives:** allowed when every alternative binds the
  same names, with the same types and the same binding mode (E0408 "not
  bound in all patterns", E0409 "bound inconsistently").
  `Ok(x) | Err(x)` and `Add(l, r) | Sub(l, r)` are common in compilers.
  Cost: exhaustiveness must expand the alternatives (the usefulness
  matrix grows with them), and codegen duplicates or joins the arms.
- **Guards inside the test.** `matches!(x, Some(n) if n > 0)` exists
  because a macro's pattern cannot flow into `&&`. RFC 3573's `is`
  operator (`x is Some(n) && n > 0`) proposes letting bindings flow
  right through `&&` in any expression, which removes the guard form.
- **The `or`-word cautionary tale is C#.** C# 9 spells pattern
  alternatives with `or` / `and` / `not` after `is`. `x is not A or B`
  parses as `(not A) or B`, a bug common enough that the compiler later
  added a warning for redundant patterns. Using the Boolean word inside
  patterns invites exactly this.

## Trig: how much are alternatives used?

| Shape | Count |
|---|---|
| `match` statements (hand / generated) | 669 / 55 |
| arms (not `_`) / of them with 2+ alternatives, hand | 1,877 / 217 (12%) |
| alternatives per such arm, hand | 2: 84, 3: 41, 4: 28, 5: 14, 6-9: 29, 10+: 21 (max 58) |
| one-real-arm matches (`P => ...` then `_ => ...`), hand | 141 |
| ... whose `P` lists 2+ alternatives | 80 (57%) |
| ... that are `=> true` / `_ => false` (a pure test) | 42, 39 of them with alternatives |
| ... same, in the generated AST guards | 33, 32 with alternatives |
| ... that bind a payload name | 23 (all one variant; none with alternatives) |
| `x == .A or x == .B ...` on one line, same left side | 276 (2: 217, 3: 37, 4+: 22, max 16) |
| `x != .A and x != .B ...` | 44 |
| arms whose alternatives bind names | 0 |
| `x as .pattern` anywhere | 0 |

The chains are a lower bound (one line, identical left side). Where
they sit: 148 in `if`, 25 `return`, 3 `while`, and assignments such as
`is_js = f.script_kind == .JS or f.script_kind == .JSX`
(`compiler/program.rig:453`). Examples:

```
parser/parser.rig:3788   if @token == .ColonToken or @token == .CommaToken or @token == .QuestionToken or @token == .EqualsToken
ast/utilities.rig:1489   while @kind(n) == .QualifiedName or @kind(n) == .Identifier
ast/ast.rig:633          match kind / .FunctionDeclaration, .CallSignature, ... (14) => true / _ => false
```

So: 75 Bool `match`es (42 hand, 33 generated) and 276+ `==` chains are a set
membership test on an enum. Alternatives are the main use of `matches`,
not an extra. One-variant tests are already served by `==` on a plain
enum; what `==` cannot do is a set, a payload variant (`.ready(_)`),
or a range.

## 1. Alternatives: `|`, in `matches` and in match arms

Recommend (e): `|` between alternatives, everywhere a pattern stands.

```rig
.filter(|e| e.value.state matches .ready | .start | .frozen)
```

Why not the others:

- **(a) parens around the test, comma inside.** The bare form is not an
  error, it is a different program: `print(x matches .a, .b)` prints two
  values, `assert(k matches .a, .b)` may type-check. The same text
  means different things in a call and in an `if`. That is the worst
  kind of surprise, and no diagnostic can catch it, since each reading
  is valid.
- **(b) `matches(...)`.** Breaks Rig's rule that `()` after a name is a
  run-time call; reads as calling a function `matches`.
- **(c) `matches (.a, .b)`.** Same look-alike problem, and `( , )`
  reads as several values.
- **(d) `or`.** `x matches .a or ready`: is `ready` a pattern (a
  constant, a binding) or a Bool? The parser must pick, and the reader
  cannot tell. C#'s `is not A or B` is the record of where that goes.
- **(f) none.** Contradicted by the counts above: 57% of one-arm
  matches and every `==` chain list several variants.

**The decisive point is nesting.** Round 2 adopted nested patterns.
A comma cannot separate alternatives inside a payload, because there it
separates fields: `.pair(.a, .b)` is two fields. `|` works at every
depth: `.ready(.done | .cached)`, `.Strings(none)`, `c matches
'a'..='z' | '_'`. The comma is a dead end; `|` is the one mechanism
that scales.

**One spelling, so arms change too:** `.a | .b => ...` replaces
`.a, .b => ...`. Keeping the comma in arms and `|` after `matches`
would be two spellings for one idea. The change is mechanical: Trig 264
arm heads (217 hand, 47 from `tools/ast/gen.py`), Rig about 245 lines in
std, tests, docs, and bench; a script rewrites top-level commas before
`=>` in arm heads. The old form is rejected with "write `.a | .b`".
Per the working rules: release notes, a one-line Trig note, the script.

Why `|` fits Rig's taste ("no punctuation doing a keyword's job"):
`or` joins Bools; `|` already means union for integers (bitwise or);
in a pattern it is the union of shapes. It is the spelling Rust, OCaml,
F#, Scala, and Python's `match` all use, so an AI writes it unprompted.

Grammar: after `matches` (and at an arm's head) the parser is in the
pattern nonterminal, where `|` has no expression meaning, so
`x matches .a | .b` is unambiguous; `1 | 2` there means alternatives,
never 3 (Rust's rule too). Today's tree already has the node:
`.a, .b =>` parses to `(alt_pattern (enum_lit a) (enum_lit b))`, so
only the separator token changes. Closures: Rig's `|e|` holds names,
not patterns, so Rust's parenthesis rule never arises. Not built or
run through Nexus this round.

## 2. Do we need alternatives? Yes

The data answers it: the set test is the common case (above). It
replaces 39 + 32 Bool functions written as `match`, and 276+ `==`
chains, each shorter and naming the subject once:

```rig
if @token matches .ColonToken | .CommaToken | .QuestionToken | .EqualsToken
```

## 3. Bindings: yes, flowing right through `and`

Needed: 23 one-arm matches in Trig bind a payload
(`match v / .Text(s) => !result.push(String(s)) / _ => pass`), plus
round 2's 11 `if xs as list` cases. Rust's `if let Some(x)` is its most
common `if let` by far.

Scope, Rust's lesson: the useful rule is RFC 3573's, not "only in `if`
and `while`". Names bound by `matches` are in scope to the right
through `and`, in any expression, and in the body of an `if`/`while`
whose condition binds them. Under `or` or `not` they are not bound.
That is what Trig's 9 test functions want, which today are a match
ending `_ => false`:

```rig
b matches .Boolean(y) and x == y                     # harnessutil.rig:480, 8 alike
value matches .Text(path) and starts_with_config_dir_template(path)
```

It also covers `matches!`'s guard, so `matches` needs no `if` guard,
and closures lose their special case (`|e| e.state matches .ready(r)
and r.size > 0`).

Alternatives bind no names for now (Trig: 0 arms want it). With `|`,
Rust's rule (every alternative binds the same names, same types; one
mode from the subject's sigil) can come later with no new syntax; with
the comma it could not.

## The spelling I would ship

```rig
# an if that binds (one < on the subject sets every binding's mode)
if <entry.state matches .ready(rendered?)
  !@retired.push(<rendered.image)

# a filter with three alternatives
oldest = ?@entries.items()
  .filter(|e| e.value.state matches .ready | .start | .frozen)
  .min_by(|e| e.value.touched) ?? break

# a while
while @token matches .WhitespaceTrivia | .NewLineTrivia
  (!@).next_token()

# an assignment
is_js = f.script_kind matches .JS | .JSX

# the full match, same patterns
match <entry.state
  .ready(rendered?) => !@retired.push(<rendered.image)
  .start | .frozen => pass
  _ => pass
```

Precedence: `matches` sits with the comparisons (not chainable), so
`a matches .x and b` is `(a matches .x) and b`, and `not` takes
parentheses as with `==`: `not (k matches .a | .b)`.

## Decisions (defaults)

1. Alternatives are `|`, in `matches` and in match arms; the comma form
   is rejected with "write `.a | .b`", migrated by script (Trig 264
   arms incl. its generator, Rig ~245 lines). Default: yes.
2. Keep alternatives in `matches`. Default: yes (Trig: 80 of 141
   one-arm matches, 276+ `==` chains).
3. `matches` binds; names flow right through `and` in any expression,
   and into the body of an `if`/`while`. Default: yes.
4. Alternatives bind no names now; Rust's same-names rule later if a
   program needs it. Default: yes.
