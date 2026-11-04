# Pattern rules under change: an evolution review

Reviewer's angle: robustness under change, and comparison with other
languages. Rig at `dd355f669` (`.git/rig-baseline/dd355f669a06…/rig`).
Everything here was run; nothing in `~/Data/Code` was edited.

Files, all under `scratchpad/pattern-review/evolution/`:

- `gen.py`: field-level matrix (17 pattern forms x 9 changes to `rect`), cells in `cells/`, results in `rect.txt` and `rect.json`
- `gen2.py`: variant-level matrix (10 forms x 7 changes) and the reorder of fields of different types, cells in `cells2/`, results in `variant.txt` and `variant.json`
- `census.py`: counts payload pattern forms in a tree of `.rig` files
- `q/a.rig` to `q/g.rig`: single probes quoted below

Method: each cell is one program. The pattern is written against the
base enum and left alone. The enum is changed, and the values are rebuilt
for the new enum, as the change's author must do (a variant with more
than one field is built by name, and payload fields take no defaults, so
every constructor is forced to update). Then the cell either fails to
compile (E), prints what the base printed (=), or prints something else
(S, a silent change of meaning). T means the binding took the field's new
type and the output changed only because the type did (`2.0` became `2`).

## Verdict

1. **One rule causes nearly every silent change: positional binding.**
   When two fields of one type swap places, every positional pattern
   (full, with `_`, in alternatives, in arms, in an `and` chain) binds the
   swapped values without a word. The by-name form and the bare variant
   never change meaning under a reorder. Construction is already by name
   for multi-field variants, so the constructors survive the reorder
   untouched and the patterns are the only sites that go wrong, with
   nothing to point at them.
2. **Positional patterns also break where nothing changed for them.** A
   field added anywhere breaks `.rect(w, _)` and `.rect(_, _)`, though
   neither one reads the new field. `.rect(_, _)` reads nothing at all, so
   every error it raises is churn.
3. **Variant-level changes are mostly well guarded.** A `match` with no
   `_ =>` reports a new variant, and a removed or renamed variant is an
   error wherever it is named. Two forms stay silent, as they are in every
   language: a `_ =>` arm and a negated list (`not s matches (...)`) take
   the new variant.
4. **Rule (1), "a bare variant tests the variant only", is the most
   robust form there is.** It survives every change except removing or
   renaming the variant.
5. Recommendation, in short: reject every payload pattern that binds and
   tests nothing (a), add no `h:` shorthand (b), and replace positional
   binding of multi-field variants with "a bare name binds the field it
   names" (c). That last change removes `.rect(w, _)`, closes both reorder
   holes, and gives the pun for free. Details in Task 3.

## Task 1: the evolution matrix

### Field-level changes to `rect(w: Float, h: Float)`

Column key:

| Column | Change |
|---|---|
| +first, +last, +mid | a field `d: Float` added first, last, or in the middle |
| reord | `rect(h: Float, w: Float)`: same types, new order |
| reord≠ | `tag(name: String, n: Int)` becomes `tag(n: Int, name: String)` |
| ren | `w` renamed `width` |
| ren↔ | the names swapped over: the first field is now `h` |
| type | `h: Float` becomes `h: Int` (and both become Int, in `rect.txt`) |
| none | `rect` loses its fields |

| Form | +first | +last | +mid | reord | reord≠ | ren | ren↔ | type | none |
|---|---|---|---|---|---|---|---|---|---|
| `.rect` (bare) | = | = | = | = | = | = | = | = | = |
| `.rect(w, h)` (positional, the fields' names) | E | E | E | **S** | **S** / E | = | = | T | E |
| `.rect(width, height)` (positional, new names) | E | E | E | **S** | **S** / E | = | = | T | E |
| `.rect(w, _)` | E | E | E | **S** | **S** | = | = | = | E |
| `.rect(_, _)` | E | E | E | = | = | = | = | = | E |
| `.rect(h: tall)`, `.rect(h: h)` | = | = | = | = | = | = | **S** | T | E |
| `.rect(w: w, h: h)` | = | = | = | = | = | E | **S** | T | E |
| `s matches .rect(w, h) and w > h` | E | E | E | **S** | n/a | = | = | E | E |
| `s matches .rect(w: w, h: h) and w > h` | = | = | = | = | n/a | E | **S** | E | E |
| `(.rect(n, _), .square(n))` | E | E | E | **S** | n/a | = | = | = / E | E |
| `(.rect(w: n), .square(side: n))` | = | = | = | = | n/a | E | **S** | = / E | E |
| `match`, every arm, positional | E | E | E | **S** | n/a | = | = | T | E |
| `match`, every arm, by name | = | = | = | = | n/a | E | **S** | T | E |
| `match` with `_ =>`, positional | E | E | E | **S** | n/a | = | = | T | E |
| `match` with `_ =>`, by name | = | = | = | = | n/a | = | **S** | T | E |
| `match` with `_ =>`, bare `.rect =>` | = | = | = | = | n/a | = | = | = | = |

"S / E" under reord≠: silent where the uses accept both types
(`print(name, n)` printed `7 abc`; `a == a` compiled and ran), an error
where they do not (`name.len + n`: "type `Int` has no field `len`").

The error texts, as Rig gives them:

- field added: "variant `rect` has 3 payload fields, pattern destructures 2; bind them all in order, or the ones you need by name: `.rect(d: x)`"
- field renamed, by name: "no field `w` on variant `rect`"
- fields removed: "variant `rect` has no payload to destructure"
- type changed, typed use: "operator `>` operands have different types `Float` and `Int`"; in alternatives: "`n` is an `Int` in `.rect(n, _)` and a `Float` in `.square(n)`: alternatives bind each name with one type"

### Variant-level changes to `Shape`

Every value of the new enum is run through each form; this column
reports what the changed or new value does.

| Form | variant added | removed | renamed | `dot` gains a field | `circle` loses its field | variants reordered |
|---|---|---|---|---|---|---|
| `s matches .dot`, `.square`, `(.circle, .square)` | = (false) | E | E | = | = | = |
| `not s matches (.circle, .square, .rect)` | **S**: the new variant counts as "the dot" | E | E | = | = | = |
| `s matches .square(x)` | = | E | E | = | = | = |
| `(.circle(n), .square(n))` | = | E | E | = | E | = |
| `match`, every arm, no `_` | E: "`match` is not exhaustive: it misses `.tri`; add an arm for it, or `_ =>` for the rest" | E | E | = | E | = |
| `match`, bare arms (`.circle, .square =>`) | E (the same) | E | E | = | = | = |
| `match` with `_ =>` | **S**: the new variant takes the `_` arm | = | = | = | E | = |
| `(.dot, .circle)` | = | = | = | = | = | = |

Error for a removed or renamed variant: "no variant `square` on enum `Shape`".
The bare `.dot` keeps working when `dot` becomes `dot(size: Float)`, as
rule (1) promises. Only its constructors break.

### Every change that alters meaning without an error

| # | Change | Forms hit | Form that avoids it |
|---|---|---|---|
| S1 | fields of one type reordered | every positional pattern: `.rect(w, h)`, `.rect(a, b)`, `.rect(w, _)`, positional alternatives, positional arms (with or without `_ =>`), `and` chains | by name; bare |
| S2 | fields of different types reordered, where the uses accept both types (`print`, `==`, generic calls) | positional patterns | by name; bare |
| S3 | a field renamed to another field's former name (names swapped, or a new field given an old name) | by-name patterns | none; positional follows the place instead. Every language with named fields shares this; it takes a deliberate act |
| S4 | a variant added | `_ =>` arms; negated lists `not s matches (...)`; the `else` of a positive test when it stands for "the rest" | a `match` with no `_ =>`; positive lists |
| S5 | a field's type changed | any binding whose uses accept both types | none (types flow, as in every language with inference); typed uses report it |
| S6 | a field added that changes what the others mean (a `unit` beside `w`) | by-name and bare patterns, which do not mention it | positional patterns, which break and force a look; the compiler cannot tell this case from a harmless addition |

S1 and S2 are the only ones that Rig's own rules choose. S3 to S5 are
the same in every language. S6 is the price of partial by-name
patterns, which the owner chose on 2026-10-08.

### Other findings from the probes

1. **`.rect(h, w)` on `rect(w, h)` is accepted and binds `h` to the `w`
   field** (`q/b.rig` prints `1.0 2.0` for `w: 1.0, h: 2.0`). The names
   say the opposite of what the code does. This is S1 written by hand:
   nothing in the program has to change for it to happen.
2. **Six spellings for "this variant, any payload"**, all accepted:
   `.rect`, `.rect(_, _)`, `.rect(w: _)`, `.rect(h: _)`,
   `.rect(w: _, h: _)`, and for a variant with no payload `.dot()`
   (`q/g.rig`, `q/b.rig`). `.rect()` is rejected with the arity message
   (`q/a.rig`), but `.dot()` is not, which is inconsistent.
3. **`field: _` in a by-name pattern is a second spelling of leaving the
   field out**: `.rect(w: _, h: h)` is `.rect(h: h)`.
4. **The hints point at the forms in question.** An unread name in a
   `Bool` test is told "write `.rect(_, _)`" (`q/d.rig`), and matches.md
   rule 8 gives "write `.a(_)`". An unread by-name binding, `.rect(w: w, h: h)`,
   is told "name it `_` to ignore the value", which yields `w: _` where
   the fix is to leave `w` out (`q/f.rig`).
5. **Construction and destructuring disagree.** A variant with more than
   one field is built only by name ("a variant with more than one field
   sets them by name: `.rect(w: ...)`", `q/c.rig`), and payload fields
   take no defaults ("variant payload fields cannot have defaults"). So
   Rig already decided that field order must not matter at the
   construction site. Patterns are the one place where it still matters.

### Corpus: how the forms are used today

`census.py` counts the payload patterns in arms and `matches` tests:

| Tree | Patterns | One field | Multi-field positional, names | with `_` | all `_` | by name |
|---|---|---|---|---|---|---|
| Rig std + examples | 7 | 6 | 1 | 0 | 0 | 0 |
| Trig | 5 | 3 | 2 | 0 | 0 | 0 |
| loc (loco) | 17 | 10 | 2 | 3 | 2 | 0 |

loco's patterns are the case under review, on real data:
`enum Region` has `tag(name: Static, lang: Static)` and
`between(open: Static, close: Static, lang: Static)`. The arms are
`.tag(_, lang) => lang`, `.between(_, _, lang) => lang`,
`.tag(_, _) => '<'`, and `.between(_, close, _) => close[0]`. All three
fields are `Static`, so swapping `open` and `close` in the declaration
would make `close[0]` read the opener with no error (S1). Under the
proposal below these arms read `.tag(lang)`, `.between(lang)`, `.tag`,
and `.between(close)`.

The corpus is small, which makes a change cheap now. Most payload
patterns bind the only field of a one-field variant, and the rule below
leaves those alone.

## Task 2: how other languages chose

| Language | Partial positional | Rest marker | Punning | All-wildcard payload, variant only |
|---|---|---|---|---|
| Rust, tuple variant `Rect(f64, f64)` | rejected (E0023, wrong number of fields) | `..`: `Rect(w, ..)`, `Rect(..)` | none (no names) | `Rect(_, _)` and `Rect(..)` both accepted; bare `Rect` rejected (E0532, "expected unit struct, unit variant or constant, found tuple variant") |
| Rust, struct variant `Rect { w, h }` | no positional form at all | `..` required to leave fields out (E0027, "pattern does not mention field `h`") | `Rect { w, .. }`; `Rect { w: w }` draws the warn-by-default lint `non_shorthand_field_patterns` | `Rect { .. }`; Clippy's `unneeded_field_pattern` (restriction group) flags `h: _` in favor of `..` |
| Swift | rejected: the pattern is a tuple of every associated value | none | none; labels are optional in a pattern and checked against the declaration when written | `case .rect:` matches any payload; `.rect(_, _)` also accepted |
| OCaml | rejected (arity) | inline records: `Rect {w; _}`, where `; _` marks the rest (warning 9 when missing, off by default) | `{w}` for `{w = w}` | `Rect _`: one `_` stands for all of the arguments |
| Scala 3 | rejected: an extractor has all its positions (`_*` only for varargs) | none for case classes | none | `case _: Rect` (a type test) or `Rect(_, _)`; named field patterns came with named tuples in recent 3.x, as I understand it |
| Kotlin | `when` has no payload patterns (`is Rect ->` with a smart cast, then `s.w`); destructuring `val (w) = rect` may stop early (by `componentN`) | none | none | `is Rect` |
| Python 3.10+ | **allowed**: `Rect(w)` binds the first of `__match_args__` | none | none: `Rect(h=h)` | `Rect()` tests the class only |
| Gleam | rejected without `..` | `..`: `Rect(w, ..)`, `Rect(h: h, ..)` | `Rect(h:, ..)` (label shorthand, Gleam 1.4) | `Rect(..)` |
| Elixir | tagged tuples `{:rect, w, _}`: every element, no rest | maps and structs are always partial: `%Rect{h: h}` | none in core (proposed often, declined for explicitness) | `%Rect{}`; `{:rect, _, _}` |
| Haskell (for reference) | rejected | record syntax is partial: `Rect{h = h}` | `Rect{h}` (NamedFieldPuns); `Rect{..}` binds every field (RecordWildCards) | `Rect{}` matches any arity |
| Zig (Rig's target) | n/a: `.rect => \|r\| r.h` captures the payload whole and reads it by name | n/a | n/a | `.rect =>` |

Why each chose so:

- **Rust** makes the author pick at the declaration: a tuple variant is
  positional only, and a struct variant is named only. In a struct
  pattern, `..` is the mark for "I have not looked at every field". The
  point is that adding a field breaks every pattern that claimed to see
  them all. That is S6's review point, paid for with a sigil, and
  `#[non_exhaustive]` forces `..` across crates. Punning is the only
  sanctioned spelling, and the long form is linted.
- **Swift** treats associated values as a tuple, so patterns follow tuple
  patterns. `case .rect:` exists for convenience. New cases are handled
  by library evolution (`@frozen`, `@unknown default`, which warns when a
  known case is not handled: the S4 remedy).
- **OCaml** gives constructor arguments a tuple shape. `C _` is the
  shortcut for all of them. Records are partial with `; _`, and warning 4
  (fragile match) flags a `_` that would absorb future constructors
  (S4 again).
- **Python** builds class patterns on `__match_args__`. It allows a
  positional prefix and keyword subsets, mixed. It is the most permissive
  design, and with it a field reorder is silent.
- **Gleam** puts labels on fields. Patterns may mix positional and
  labelled fields but must say `..`, so changes to arity stay visible. The
  `h:` shorthand was added because `h: h` repeated itself.
- **Elixir** keeps two shapes: tuples (positional and exact) and maps
  (by key and open). It declined punning to keep every binding explicit.
- **Kotlin**: positional destructuring by `componentN` is the classic
  reorder bug. As I understand it, JetBrains' recent destructuring
  proposal moves parenthesized destructuring to names and keeps
  positional behind a distinct bracket. That is the direction argued here.

The pattern: languages whose payloads have names give a partial by-name
form, and most of them pun the field's own name. Positional with `_` is
universal only where the payload has no names (tuples). Rig's variants
always have names, and Rig already insists on them when building a
variant. Rust is the closest match, and in Rust a named payload
(a struct variant) has no positional pattern at all.

## Task 3: judgment

The owner's taste, applied: short plain words; a mark for a mechanic;
no punctuation doing a keyword's job; one spelling per idea; least
surprise.

### (a) Reject `.rect(_, _)`: right, and widen it

- **One spelling per idea.** Six spellings test "the variant, any
  payload" today. `.rect` is the shortest, and it is the one rule (1)
  already defines.
- **Robust.** `.rect(_, _)` breaks on any field added or removed (E in
  five columns) though it reads nothing, so none of those breaks can ever
  flag a real problem. `.rect` survives all of them.
- **Widen the rule** to every payload pattern that binds and tests
  nothing: `.rect(_, _)`, `.circle(_)`, `.rect(w: _)`, `.rect(w: _, h: _)`,
  and `.dot()`. Also reject a lone `field: _` beside other fields
  (`.rect(w: _, h: h)` means `.rect(h: h)`). Keep `_?` and `none`: they
  test something.
- **Fix the hints and docs that teach the old forms.** "write
  `.rect(_, _)`" (unread name in a `Bool`), matches.md rule 8's
  "write `.a(_)`", and the by-name "name it `_`" hint. Also change the
  examples `.circle(_), .square(_) =>` (SPEC `match`), `(.point, .rect(_, _))`
  (SPEC §12, matches.md), and `.circle(_), .rect(_, _)` (matches.md).

Message: ``.rect(_, _)` binds nothing: write `.rect``

### (b) A shorthand for `h: h`: not as `h:`

`.rect(h:)` is Gleam's spelling. Against the taste:

- It is punctuation with nothing after it. It reads as an unfinished
  label, and `:` before a name already means a symbol (`:name`).
- It adds a second spelling for `h: h` unless `h: h` is then rejected.
- To be consistent it would have to reach calls and constructors too
  (Gleam's does).

The pun Rig wants needs no new mark. Let the bare name mean its field.
That is (c).

### (c) `.rect(w, _)`: not as is

It is the form the owner finds ugly. It is also the least robust form
in the matrix: silent under a reorder (S1, S2), and an error under any
added field it never reads. Its reason to exist is that positional
patterns must list every position. Remove that and the form goes with it.

### The candidate: a bare name binds the field it names

**The rule.** A payload pattern names the fields it binds:

- `.rect(h)` binds the field `h`;
- `.rect(h: tall)` binds it as `tall`;
- the fields it leaves out stay with the subject, or drop at the end of
  the arm under `<s`, exactly as today's by-name fields do;
- a variant with one field binds it under any name (`.circle(radius)`,
  `.item(x)`): with one field, order cannot be wrong.

Rules (1), (4) and (5) are unchanged. Rule (3) stays. Rule (2), "every
field, in order", ends for variants of more than one field, and the ban
on mixing goes with it, since everything is by name.

In a declaration and patterns:

```
enum Region
  tag(name: Static, lang: Static)
  between(open: Static, close: Static, lang: Static)

fun closer(r: ?Region) -> U8
  match r
    .tag => '<'
    .between(close) => close[0]

fun lang(r: ?Region) -> Static
  match r
    .tag(lang), .between(lang) => lang

  if s matches .rect(h) and h > 1.0
  if s matches .rect(w, h: tall) and w < tall
  .text(label, bytes: n) => tally(!@text, <label, 1, n)
```

Error messages:

- ``.rect` has no field `height`: bind a field under another name, `.rect(h: height)``
- `` `_` stands for no field in `.rect(w, _)`: leave the field out, `.rect(w)` ``
- ``.rect(_, _)` binds nothing: write `.rect``
- ``.rect(h: h)` repeats the name: write `.rect(h)`` (one spelling per idea; Rust lints the same form)

A sentence of prose, for SPEC: "A pattern binds a variant's fields by
name, any of them: `.rect(h)` binds the field `h`, `.rect(h: tall)`
binds it as `tall`, and a field left out stays with the subject; a
variant with one field binds it under any name."

**What it does to the matrix:**

| Change | Today, positional | Candidate |
|---|---|---|
| fields reordered, any types (S1, S2) | silent | no effect |
| field added | E, even where nothing changed for the pattern | no effect (S6 remains, as for today's by-name form) |
| field renamed | = (follows the place) | E for a field the pattern names; one-field variants unaffected |
| one-field variant gains a field | E | E, unless the binding's name is the new field's name (`.circle(d)` when `d` is added: it binds the new field silently; rare, and it takes a name collision) |
| `.rect(h, w)` written by hand | binds the opposite of what it says | binds what it says |

**Why it fits the taste.** It adds no mark and no word. There is one
spelling for each idea: `.rect` for the variant, `.rect(h)` for a field,
`.rect(h: tall)` for a field under another name. It reads the way the
variant is built, by name. It is least surprise for readers of Rust
struct patterns, OCaml records, Haskell puns, and JS destructuring, and
of the names themselves. It dissolves (a), (b) and (c) together rather
than patching each one.

**Cost.**

- It replaces the owner's 2026-10-08 sentence "in order, all of them, or
  by name, any of them". That decision is his.
- Readers from Swift, Scala or Python may expect `.rect(a, b)` to be
  positional. They get an error naming the fix, never a wrong binding.
- Building it is cheap. Typecheck's `fieldBindings` already turns a
  by-name pattern into the `payloadBindings` fact. A bare name becomes
  `name: name`, and the r3 review showed that by-name and positional emit
  byte-identical Zig.
- Migration is mechanical from the declaration. Positional patterns are
  rewritten by name, and the permuted case (`.rect(h, w)`) is rewritten
  to keep today's meaning (`.rect(w: h, h: w)`). Affected today: loco 7
  patterns, Trig 2, plus Rig's docs and tests. Trig gets its one-line
  note and script first.

**Fallback if the owner keeps positional.** Reject a positional binding
that is named after a different field of the variant:
``h` binds the field `w` of `.rect`: write `.rect(w: h)`, or bind by name`.
That turns S1 into an error whenever the names are field names (both
`.rect(w, h)` and `.rect(w, _)` after a reorder, and `.between(_, close, _)`
after open and close swap). It leaves positional patterns under other
names (`.rect(a, b)`) silent.

### The owner's two candidates

Both were probed against today's Rig (`q/h.rig`). Today every one of
`.rect(:w)`, `.key(name: :enter)`, `.key(:enter, c)`, `.rect(w:)`, and
`Shape.rect(w:, h:)` is a parse error ("unexpected `:`; expected a
name", "unexpected `)`; expected a name", "unexpected `,`; expected an
expression"). So nothing accepted today would change meaning; the
question is what each would mean, and what it blocks.

On robustness, both are by-name forms. Each is immune to S1 and S2,
each is an error when its field is renamed, and each shares S3 and S6
with `.rect(w: w)`. The matrix cannot separate them from the explicit
form, so the judgment rests on the taste rules and on collisions.

**(A) `.rect(:w)`, a symbol naming the field to pluck**

```
enum Shape
  rect(w: Float, h: Float)
  circle(r: Float)

if s matches .rect(:w) and w > 1.0
```

Error: ``.rect` has no field `width`: `.rect(:w)` plucks a field by name`.
Prose: "A symbol in a payload pattern names the field to bind, under its
own name: `.rect(:w)` binds `w`."

- **It collides with what `:w` is.** SPEC "Symbols" says a symbol is a
  `Symbol` value "wherever it stands", and the lexer makes any `:`
  touching a name at an operand's start a symbol token. A match arm
  already reads `:a =>` as "equals the symbol `:a`". Inside a payload,
  `:w` would be the only place where a symbol is not a value but a
  binder, and where it introduces a local name that is not written as a
  name.
- **It blocks the natural literal payload pattern.** If Rig later
  accepts a literal inside a payload, `.key(:enter, c)` and
  `.key(name: :enter)` mean "the field equals `:enter`", exactly as
  `:enter =>` does in an arm. With (A) in place, `.cmd(:quit)` on
  `cmd(name: Symbol)` has two readings: test the field against `:quit`,
  or bind a field called `quit`. A positional literal and a pluck would
  sit in the same slot, so one of them would have to be given up.
- **Rails' `pluck(:w)` is a different thing.** It passes column names as
  data to a method, which returns values; it binds no variable. In a
  pattern, the symbol would have to do a keyword's job: declare a name.
- Verdict: **no**.

**(B) `.rect(w:)`, Ruby 3.1's value omission**

```
enum Shape
  rect(w: Float, h: Float)

if s matches .rect(w:) and w > 1.0
shape = Shape.rect(w:, h:)        # constructor: w: w, h: h from scope
draw(at:, scale: 2)               # keyword argument
```

Error: ``.rect(w:)` binds `w`; `.rect` has no field `width``.
Prose: "A field name with no value after its colon stands for itself:
`.rect(w:)` binds `w`, and `Shape.rect(w:)` passes the local `w`."

- **The grammar has room for it.** Here the `:` follows a value (the
  name), so by SYNTAX's table it is the keyword colon, never a symbol.
  The omitted value is always followed by `,` or `)`, which a single
  token of lookahead tells apart from a value. `w: :h` (a symbol value)
  is still distinct. The one trap: inside brackets a newline is a space,
  so `f(w:` on one line and `h)` on the next reads as `w: h`. It takes
  a dropped comma as well to misread anything, so the trap is small.
- **It can hold for calls and constructors too**, as in Ruby and Gleam.
  There it reads well: `w:` passes the `w` in scope, a use of a name
  that is already visible.
- **In a pattern it is a definition with no name written.** The owner's
  objection ("says grab the w field but doesn't supply a name") is right
  on the merits. The name a pattern introduces is the one thing a reader
  scans for, and here it hides behind a label. That is the unfinished
  look of the punctuation, and it breaks one spelling per idea unless
  `w: w` is then rejected.
- Verdict: **not for patterns**. For calls and constructors it is
  defensible, but it is a separate question about calls, not about
  patterns.

**A spelling that avoids both: `.rect(w)`**

The name is written, it is a name (no symbol), and nothing is left
unfinished. This is the candidate above: a bare name binds the field
it names. The four tests are in that section:

- declaration `between(open, close, lang)`;
- pattern `.between(close) => close[0]`;
- error ``.rect` has no field `height`: bind a field under another name, `.rect(h: height)``;
- the prose sentence for SPEC.

It is open only if positional binding of multi-field variants ends
(path item 2). With positional kept, a bare `.rect(w)` cannot also mean
"by name" without the hybrid hazard: a field rename silently turns a
by-name `.rect(h, w)` into a positional swap. In that case the
explicit form is best. **`.rect(w: w)` is the right spelling if
positional patterns stay**, and it is as robust as any shorthand.

### `:w` under the owner's rule

The rule: inside a variant's parentheses in a pattern, `:x` always names
a field, never a symbol value. A literal symbol in a payload is written
only by name, `field: :sym`. A `:x` that names no field is an error.

```
enum Key
  key(name: Symbol, code: Int)
  idle

match k
  .key(name: :enter) => submit()
  .key(:name, code: c) if c > 0 => print(name, c)
  _ => pass

if s matches .rect(:h) and h > 1.0
```

Error: ``.key` has no field `enter`: `:enter` names a field here; to
test the value, write `.key(name: :enter)``.

Prose: "Inside a pattern's parentheses, `:w` binds the field `w` under
its own name, and `w: tall` binds it as `tall`; a symbol value is
written after a field's name, `name: :enter`."

1. **Grammar and lexer: no ambiguity.**
   - The lexer already emits `:x` as a symbol token at an operand's
     start, and a payload slot is an operand's start. The parser decides
     by slot: a symbol that starts a payload slot is a field, and one
     after `field:` is a value. Both are fixed contexts, so no LALR
     conflict is needed.
   - Symbol spellings that cannot be field names (`:content-type`,
     `:a.b`, `:if`) get "`:content-type` is no field name".
   - The cost is in reading, not parsing. One token has two roles,
     decided by where it stands. In adjacent arms, `.key(name: :enter)`
     is a value and `.key(:name)` is a binder.
2. **No silent change under evolution.**
   - `:w` is a by-name binder. Under every change in the matrix it
     behaves like `w: w`: immune to reorder (S1, S2), an error when the
     field is renamed, and S3 and S6 shared.
   - The misreading case is a field that shares a symbol's name. Take
     `run(quit: Symbol)`: `c matches .run(:quit)` meant as "equals
     `:quit`" binds `quit`, and Rig's existing rule rejects it, because
     a bound name nobody reads is an error (probed: `q/f.rig`). It goes
     wrong silently only if the program reads a local `quit` in the body
     as well.
   - The one place where patterns stop mirroring construction is a
     one-field variant. Construction is positional there, so
     `Cmd.run(:quit)` stores the value `:quit`, while the pattern
     `.run(:quit)` plucks a field. The error above covers it.
   - A positional literal payload pattern (`.key(:enter, c)`) is ruled
     out for good. That is consistent: construction of a multi-field
     variant is by name only.
3. **In arms, alternatives, and `_ =>`.**
   - `(.circle(:r), .square(side: r)) => print(r)` reads cleanly: one
     pluck and one rename, both by name, binding one `r`.
   - `.rect(:h) => ...` / `_ => ...` reads as well as today's by-name arm.
   - `(.circle(:r), .square(r: r))` would be two spellings of one act.
     So with `:w` in, `w: w` should be rejected ("write `:w`").
   - `:w` counts as by name for the no-mixing rule: `.rect(:w, h)` is
     rejected, and `.rect(:w, h: tall)` is accepted.
4. **Taste.**
   - For: it is short, the name is written (which meets the objection to
     `w:`), and `:` becomes the visible mark of by-name binding, so
     `.rect(w, h)` (positional) and `.rect(:w, :h)` (by name) show their
     mode at a glance.
   - Against: `:` is already the mark of another mechanic, the symbol,
     so the mark carries two mechanics, told apart by position.
   - On balance it is acceptable and safe, and better than `w:`.
   - `.rect(w)` (a bare name binds its field) needs no mark at all. It
     is the cleaner end state only if positional binding ends. If
     positional stays, `:w` is the best short spelling, and it is
     better than leaving `.rect(w: w)` alone.

**If `:w` is taken, a package that also closes most of S1.**

- Reject `_` in a multi-field positional pattern. A positional pattern
  then names every field, and anything partial is by name:
  `.between(_, close, _)` becomes `.between(:close)`, and `.rect(w, _)`
  becomes `.rect(:w)`.
- Add the fallback check: a positional binding named after another
  field is rejected.
- Together these leave S1 silent only for positional patterns under
  names that are not the fields' names (`.rect(a, b)`).

**Not a language change: S4.** A `match` with no `_ =>` is the form that
reports a new variant, and SPEC can say so. Swift's `@unknown default` and
OCaml's fragile-match warning are the precedents if this is ever wanted.

## The path, for the owner (defaults first)

1. Reject every payload pattern that binds and tests nothing
   (`.rect(_, _)`, `.circle(_)`, `.rect(w: _)`, `.dot()`), and a lone
   `field: _`; fix the three hints and the doc examples. **Default: yes,
   now.** It is small, it stands alone, and loco changes 2 arms.
2. Replace positional binding of multi-field variants with "a bare name
   binds the field it names", with a migration script. **Default: yes, as
   its own reviewed change.**
3. No pattern shorthand by `:w` (it collides with symbols and with
   literal payload patterns) or by `w:` (a binding with no name
   written). **Default: yes.** With item 2, `.rect(w)` is the short
   form, and `w: w` is either rejected for one spelling per idea or kept
   (the owner's lean). **Default: reject.** Without item 2, keep
   `.rect(w: w)`.
4. Only if item 2 is declined: reject a positional binding named after
   another field. **Default: hold, pending item 2.**
5. S4 (`_ =>` and negated lists): docs only. **Default: yes.**
6. If the owner keeps positional and takes `:w`, which he favors: `:x`
   in a payload always names a field; a symbol value goes only after a
   field's name; `w: w` is rejected for `:w`; `_` is rejected in
   multi-field positional patterns; and item 4's check is built. **Default:
   yes, as one reviewed change, in place of item 2.**

## Commands

```
D=scratchpad/pattern-review/evolution
python3 $D/gen.py  > $D/rect.txt      # field-level matrix, about 3 minutes
python3 $D/gen2.py > $D/variant.txt   # variant-level matrix
python3 $D/census.py ~/Data/Code/loc ~/Data/Code/trig/src ~/Data/Code/rig/std ~/Data/Code/rig/examples
RIG_OUT_DIR=$D/out $R run $D/q/b.rig  # `.rect(h, w)` binds the opposite of its names
```

(`gen2.py`'s `T-interp` probe used a string form Rig does not have and
is not counted.)
