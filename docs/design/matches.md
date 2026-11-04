# `matches`: test a pattern, and bind its fields

*Built.* SPEC §12 ("Testing a pattern: `matches`") states the rules;
this page gives the reasons. Its examples run in the test suite.

`x matches P` asks whether `x` matches the pattern `P`, a `match` arm's
pattern, and is a `Bool`. In an `if` or `while` condition the names the
pattern binds are bound in the body:

```
if s matches .circle(r)
  print("circle of radius", r)
else
  print("something else")

live = e.state matches (.ready, .start, .frozen)
```

It reads as "if `s` matches a circle, call its radius `r`". It is a
`match`: with one arm that falls to `else` in a condition, and with
`P => true` and `_ => false` anywhere else. It costs what that `match`
costs.

`as` names a value (`if o as v`, `if f() as a, b`), and `matches`
tests a pattern. A test written with `as` would read as a cast and
could not stand outside a condition; `matches` reads as what it is and
can stand anywhere.

## Why

Testing a value and then using it is two steps in most languages, and
the gap between them is where bugs live. The usual C++ shape calls the
producer twice and trusts the second call to agree with the first:

```
if (bar().has_value()) {
    foo(bar().value());   // a second call; nothing ties it to the test
}
```

Rust closes the gap with `if let`, which tests and binds at once, and
`matches!`, which tests anywhere:

```
if let Shape::Circle(r) = s { area(r); }
let live = entries.iter().filter(|e| matches!(e.state, Ready | Start));
```

Rig writes both with one word, in the order a `match` reads, value
first. A chain of `x == .A or x == .B` evaluates `x` again for each
test, and calls a function again if `x` is a call; `x matches (.A, .B)`
reads the value once.

## The form

| Form | Example |
|---|---|
| one pattern | `x matches .ready(r)` |
| an optional inside | `x matches .ready(rendered?)` |
| alternatives | `x matches (.a, .b, .c)` |
| alternatives that bind | `x matches (.failed(c), .timed_out(c))` |
| a full match, unchanged | `match x` / `.a, .b => ...` / `_ => pass` |

- **A `Bool` anywhere.** In an `if` or `while` condition, the names the
  pattern binds are bound in the body and after `and`; in a ternary's,
  in the value before `if` (`r * r if s matches .circle(r) else 0`),
  as `as` binds there. Anywhere else
  they flow right through `and` and only there, so
  `x matches .ready(s) and s matches (.done, .cached)` works in a
  closure too.
- **Alternatives in parentheses,** after a space. Rig has no tuples, so
  the list cannot be read as one, and it needs no rule of its own inside
  a call. The list may end with a comma, and newlines inside it join.
- **No `|`.** A match arm lists alternatives with commas, `.a, .b =>`,
  and `matches` lists them in parentheses: one separator.
- **No nested alternatives.** `.ready((.done, .cached))` is written
  `x matches .ready(s) and s matches (.done, .cached)`.
- **Alternatives that bind** bind the same names, each with one type,
  in every alternative; anything else is rejected, naming the name or
  type that differs. The same holds for a match arm:
  `.failed(c), .timed_out(c) => report(c)`.
- **`name?` and `none`** in a payload: `name?` matches when the
  optional field holds a value and binds it; `none` matches when it
  holds none; `_?` tests that it holds one.
- **Negation** follows the comparison rule: `not x matches (.a, .b)` is
  `not (x matches (.a, .b))`, as `not s == .ready` is
  `not (s == .ready)`.

```rig
enum Shape
  circle(r: Int)
  rect(w: Int, h: Int)
  point

fun area(s: Shape) -> Int
  if s matches .circle(r)
    3 * r * r
  else
    0

fun kind(s: Shape) -> ?String
  if s matches .circle(r) and r > 10
    return "big circle"
  if s matches .rect(h: tall) and tall > 3
    return "tall rect"
  if s matches (.point, .rect(_, _))
    return "flat"
  "other"

sub main()
  print(area(.circle(r: 2)), area(.rect(w: 2, h: 3)), area(.point))
  print(kind(.circle(r: 20)), kind(.rect(w: 1, h: 5)), kind(.point), kind(.circle(r: 1)))
  shapes: List[Shape] = List()
  !shapes.push(.point)
  !shapes.push(.circle(r: 3))
  round = |s: ?Shape| s matches .circle(r) and r > 2
  n = 0
  for s in ?shapes
    n += 1 if round(s)
  print(n, not shapes[0] matches (.circle(_), .rect(_, _)))
```

```output
12 0 0
big circle tall rect flat other
1 true
```

## Ownership

One sigil on the subject sets how every binding is held, as it does
for a `match` subject:

| Rig | The bindings | Rust |
|---|---|---|
| `if s matches .circle(r)` | read the fields where they are: a copy of plain data, a view of anything else | `if let Circle(r) = &s` |
| `if !s matches .rect(label: l)` | write views: `l = …` changes the field in place | `if let Rect { label: l, .. } = &mut s` |
| `if <s matches .rect(label: l)` | own the fields; the rest is dropped at the end of the block | `if let Rect { label: l, .. } = s` |
| `if make() matches .circle(r)` | own the fields of the temporary | `if let Circle(r) = make()` |

A pattern never clones. `<s` hands the whole value to the test,
matched or not, as `match <s` does: when it matches, the fields the
pattern leaves out are dropped at the end of the block; when it does
not, the value is dropped as the test fails, before `else` runs, as
Rust 2024 drops an `if let`'s temporaries before its `else`. `s` is
moved either way. When a field of a read binding is passed where a
value is owned, the diagnostic offers `<` on the subject before `+`.
A ternary's condition holds its bindings the same way, for the value
before `if`: `<note if <e matches .ready(note?) else String("none")`.

```rig
obj Rendered
  image: String

enum State
  loading
  ready(rendered: Rendered?)

sub main()
  retired: List[String] = List()
  e: State = .ready(rendered: Rendered(image: String("pic")))
  if e matches .ready(_?)
    print("has an image")
  if <e matches .ready(rendered?)
    !retired.push(<rendered.image)
  print(retired.len)
```

```output
has an image
1
```

A loop over a value that changes variant, and an optional unwrapped
before its variant is tested:

```rig
enum Token
  item(n: Int)
  done

enum Shape
  circle(r: Int)
  point

fun next(i: Int) -> Token
  if i < 3
    .item(n: i * 10)
  else
    .done

fun radius(m: Shape?) -> Int
  if m as s and s matches .circle(r)
    r
  else
    0

sub main()
  i = 0
  while next(i) matches .item(x)
    print(x)
    i += 1
  print(radius(.circle(r: 5)), radius(.point), radius(none))
```

```output
0
10
20
5 0 0
```

## Rules

These edges are each rejected with the plain form in the message:

1. **Parentheses.** `x matches .a, .b` is rejected outside brackets
   with "put alternatives in parentheses: `matches (.a, .b)`"; inside a
   call, a `matches` operand followed by `, .name` gets the same note.
2. **Two or more.** A list of one, `(.a)`, is rejected: "write
   `x matches .a`".
3. **A real test.** `_` or a bare name, alone or in a list, matches
   everything and is rejected; to compare with a constant, use `==`.
   `none` is rejected too, with "write `x == none`", the test of an
   optional.
4. **No call.** `matches(` with no space is rejected: "write
   `matches (`". It is never read as a call.
5. **An arm's alternatives** take no parentheses: `(.a, .b) =>` is
   rejected with "write `.a, .b =>`".
6. **Patterns after `matches`.** The parser reads patterns there, so a
   parenthesized list is never the rejected tuple form.
7. **Names flow right through `and`** in any expression; elsewhere a
   pattern binds only in the condition of an `if`, a `while`, or a
   ternary.
8. **A name nothing reads** where a `Bool` goes (`ok = x matches
   .a(r)`) is rejected: "write `.a(_)`".
9. **`not`** takes the whole test: `not x matches (...)` means
   `not (x matches (...))`.

Besides these: no `if` guard in the pattern (the condition joins with
`and`); an enum with one variant always matches, so testing it with a
pattern that binds is rejected for a `match`; an optional subject is
rejected rather than failing to match on `none` (take its value out
first, or test a payload's optional with `name?`); alternatives of an
error bind no names; and an arm that tests a payload's optional, like a
guarded arm, covers none of its variant's values.

```rig reject
enum S
  a(n: Int)
  b

sub main()
  s: S = .b
  if s matches .a(n), .b
    print(1)
```

```error
put alternatives in parentheses: `matches (.a, .b)`
```

```rig reject
enum S
  a(n: Int)
  b

sub main()
  s: S = .b
  if s matches .a(n) if n > 0
    print(1)
```

```error
a pattern after `matches` takes no `if` guard: join the condition with `and`, `if s matches .circle(r) and r > 10`
```

```rig reject
enum S
  failed(code: Int)
  timed_out(after: String)

sub main()
  s: S = .failed(code: 1)
  if s matches (.failed(c), .timed_out(c))
    print(c)
```

```error
`c` is an `Int` in `.failed(c)` and a `String` in `.timed_out(c)`: alternatives bind each name with one type
```

```rig reject
enum S
  a(n: Int)
  b

sub main()
  s: S = .b
  if s as .a(n)
    print(n)
```

```error
write `s matches .a(n)`: `as` names a value, and `matches` tests a pattern
```

```rig reject
enum Shape
  circle(r: Int)
  point

fun radius(m: Shape?) -> Int
  if m matches .circle(r)
    r
  else
    0

sub main()
  print(radius(none))
```

```error
`m` is a `Shape?`: take the value out first (`if m as s and s matches .circle(r)`)
```

## Against Rust

| | Rust | Rig |
|---|---|---|
| a variant | `if let Shape::Circle(r) = s` | `if s matches .circle(r)` |
| a test | `matches!(s, A \| B)` | `s matches (.a, .b)` |
| an optional | `if let Some(v) = bar()` | `if bar() as v` |
| an optional field | `if let Ready(Some(r)) = s` | `if s matches .ready(r?)` |
| a guard | `if let Circle(r) = s && r > 10` | `if s matches .circle(r) and r > 10` |
| a loop | `while let Item(x) = next(i)` | `while next(i) matches .item(x)` |
| ownership | inferred from the subject's type and binding modes | written on the subject: `s`, `!s`, `<s` |

## How it is built

Each pass's part is in [INTERNALS](../internals/INTERNALS.md#how-matches-is-built).

## Later, not now

- Coverage across tests of one optional field: `.ready(r?)` with
  `.ready(none)` covering `.ready`.
- Matching through an optional subject (`if m matches .circle(r)` on a
  `Shape?`).
- A form that binds into the rest of the function and leaves early when
  the pattern fails (Rust's `let … else`).
