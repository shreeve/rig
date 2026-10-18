# `as` with a pattern: test a variant and bind its fields

*Planned.* The design below is decided and not yet built. Its examples
are ```` ```rig pending ```` blocks: the test suite runs each one, and
each must fail until the rule is built, when it must pass instead and
its block becomes ```` ```rig ````.

`if a as x` already tests an optional and binds its value in one step.
The same `as` takes a `match` pattern on its right, so a single test
can ask which variant an enum value is and bind that variant's fields:

```
if s as .circle(r)
  print("circle of radius", r)
else
  print("something else")
```

It reads as "if `s` is a circle, call its radius `r`". It is a `match`
with one arm that falls to `else`: no new keyword, no new pattern
grammar, and the same ownership sigils as `match`.

## Why

Testing a value and then using it is two steps in most languages, and
the gap between them is where bugs live. The usual C++ shape calls the
producer twice and trusts the second call to agree with the first:

```
if (bar().has_value()) {
    foo(bar().value());   // a second call; nothing ties it to the test
}
```

Rust closes the gap with `if let`, which tests and binds at once:

```
if let Some(v) = bar() { foo(v); }
if let Shape::Circle(r) = s { area(r); }
```

Rig closes it for optionals already, with less to write and with
ownership spelled where the value is taken (SPEC §12):

| Rig today | Meaning |
|---|---|
| `if bar() as v` | a temporary: `v` owns the value, dropped at the end of the block |
| `if m as v` | an optional held in a binding is read where it is |
| `if !m as v` | a write view: `v.f = x` changes the value in place, `v = x` replaces it |
| `if <m as v` | the value is moved out |
| `if <a.f as v` | taken out of a field, which is left `none` |
| `if +m as v` | a clone |
| `while a as v` | repeat while `a` produces a value |
| `if a as x and x > 0` | bindings and conditions joined by `and` |
| `if f() as q, r` | several results bound at once |

What Rust's `if let` has beyond this is a pattern on any enum. In Rig
today that takes a `match`, with an arm for the rest even when only one
variant matters. This design gives `as` the pattern too.

## The form

After `as` comes either a name, as today, or a pattern, which starts
with a dot:

- `as x` binds the value inside an optional (or several results).
- `as .variant(fields)` tests that the value is that variant and binds
  its fields.

The pattern is exactly a `match` arm's pattern (SYNTAX §12), so the
forms a `match` arm takes are the forms `as` takes:

```
if s as .rect(w, h, _)            # fields in order, every one of them
if s as .rect(h: tall)            # or by name, any of them
if s as .point                    # a variant with no fields: a test alone
if s as .circle(_)                # `_` tests without binding

if s as .circle(r) and r > 10     # a guard, joined with `and`
if m as s and s as .circle(r)     # the optional first, then the variant

while next(i) as .item(x)         # repeat while the variant matches
```

`else` runs when the value is another variant. The names a pattern binds
are visible only in its block, as names bound by `as` are today.

```rig pending
enum Shape
  circle(r: Int)
  rect(w: Int, h: Int)
  point

fun area(s: Shape) -> Int
  if s as .circle(r)
    3 * r * r
  else
    0

fun kind(s: Shape) -> ?String
  if s as .circle(r) and r > 10
    return "big circle"
  if s as .rect(h: tall) and tall > 3
    return "tall rect"
  if s as .point
    return "point"
  "other"

sub main()
  print(area(.circle(r: 2)), area(.rect(w: 2, h: 3)), area(.point))
  print(kind(.circle(r: 20)), kind(.rect(w: 1, h: 5)), kind(.point), kind(.circle(r: 1)))
```

```output
12 0 0
big circle tall rect point other
```

## Ownership

The subject takes the sigils a `match` subject takes, with the same
meaning, so what a pattern binds is as plain as it is in `if m as x`:

| Rig | The bindings | Rust |
|---|---|---|
| `if s as .circle(r)` | read the fields where they are | `if let Circle(r) = &s` |
| `if !s as .rect(label: l)` | write views: `l = …` changes the field in place | `if let Rect { label: l, .. } = &mut s` |
| `if <s as .rect(label: l)` | own the fields; the rest is dropped at the end of the block | `if let Rect { label: l, .. } = s` |
| `if make() as .circle(r)` | own the fields of the temporary | `if let Circle(r) = make()` |

`<s` hands the whole value to the test, matched or not, as `match <s`
does: when it matches, the fields the pattern leaves out are dropped at
the end of the block; when it does not, the value is dropped at the end
of `else` (or of the `if`, without one). `s` is moved either way.

```rig pending
enum Shape
  rect(w: Int, h: Int, label: String)
  point

sub main()
  s: Shape = .rect(w: 3, h: 4, label: String("box"))
  if s as .rect(w, h, _)
    print(w * h)
  if !s as .rect(label: l)
    l = String("wide")
  if <s as .rect(label: l)
    print(l)
```

```output
12
wide
```

A loop over a value that changes variant, and an optional unwrapped
before its variant is tested:

```rig pending
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
  if m as s and s as .circle(r)
    r
  else
    0

sub main()
  i = 0
  while next(i) as .item(x)
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

1. **One pattern.** A `match` arm separates alternatives with commas,
   but after `as` a comma already means several results
   (`if f() as q, r`), and alternatives bind nothing anyway. To test
   several variants, write a `match`.
2. **No `if` guard inside the pattern.** A condition joins with `and`,
   as it does for `as` today, so a guard has one spelling.
3. **A real test.** On an enum with one variant the pattern always
   matches, and the form is rejected with a hint to bind the fields with
   `match`, as an unreachable `match` arm is rejected today.
4. **Not exhaustive.** Unlike `match`, the form is a test, and anything
   else falls to `else`, as `if m as x` does. Where every variant
   matters, `match` remains the form, and it checks that every one is
   covered.
5. **Scoped bindings.** The names a pattern binds are visible only in
   its block. `.v(_)` and a variant with no fields test without binding.
6. **No implicit unwrapping.** On a `Shape?`, `as .circle(r)` is
   rejected rather than letting `none` silently fail to match: take the
   value out first (`if m as s and s as .circle(r)`), so every step is
   written. Matching through the optional may come later, as a
   deliberate convenience.

```rig pending
enum Wrap
  only(n: Int)

sub main()
  w: Wrap = .only(n: 1)
  if w as .only(n)
    print(n)
```

```error
`.only` is the only variant of `Wrap`, so this test always holds; bind its fields with `match`
```

```rig pending
enum Shape
  circle(r: Int)
  point

fun radius(m: Shape?) -> Int
  if m as .circle(r)
    r
  else
    0

sub main()
  print(radius(none))
```

```error
`m` is a `Shape?`: take the value out first (`if m as s and s as .circle(r)`)
```

## Against Rust

| | Rust | Rig |
|---|---|---|
| a variant | `if let Shape::Circle(r) = s` | `if s as .circle(r)` |
| an optional | `if let Some(v) = bar()` | `if bar() as v` |
| a guard | `if let Circle(r) = s && r > 10` (let chains, Rust 1.88) | `if s as .circle(r) and r > 10` |
| a loop | `while let Item(x) = next(i)` | `while next(i) as .item(x)` |
| ownership | inferred from the subject's type and binding modes | written on the subject: `s`, `!s`, `<s` |
| order | pattern, then value | value, then pattern, as in `match` |

Rig drops the `let`, the `=`, the type prefix, and the reversed order;
spells ownership where the value is taken instead of inferring it; and
adds no keyword and no grammar. It completes the feature Rig has rather
than adding a second one: `as` is the one way to test and bind, whether
the value is an optional, several results, or a variant.

## Building it

- **Parser** (`rig.grammar`, regenerated with Nexus): after `as`, a
  leading `.` starts a pattern, parsed by the rule `match` arms use.
  `as x`, `as q, r`, and `as _` are unchanged.
- **Checker**: the subject is an enum (rule 6 rejects an optional); the
  pattern is checked exactly as a `match` arm against the subject's
  type; rules 1 and 3 reject the forms above; bindings are scoped to the
  block, as `as` bindings are now.
- **Ownership**: the subject's sigils and the bindings follow `match`
  (`match s`, `match !s`, `match <s`), including what `<s` drops on
  either branch. The reference ownership checker (`test/oracle/`)
  lowers the form as the one-arm `match` it is.
- **Emit**: lower to the one-arm `match` with `else` as its other arm,
  and `while … as .v(x)` to a loop around that test.
- **Tests**: `fail`, `test`, and `bomb` cases beside the `match` cases
  (`test/rig/types-match.rig.test`, `ownership-match.rig.test`) for
  each form, sigil, and rule above; this page's examples turn from
  ```` ```rig pending ```` to ```` ```rig ````.
- **Docs**: SPEC §12 (Optionals) and the `match` section, SYNTAX §12
  (Patterns), and WELCOME's tour gain the form.

## Later, not now

- Matching through an optional (`if m as .circle(r)` on a `Shape?`),
  once rule 6 has shown whether the explicit form reads well in real
  code.
- `as` with a pattern as a `Bool` outside a condition (Rust's
  `matches!`): `if s as .point` covers the test today.
- A form that binds into the rest of the function and leaves early when
  the pattern fails (Rust's `let … else`).
