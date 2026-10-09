# Rig Syntax

This document shows how every form of Rig is written: the layout of a
source file, names and literals, operators, types, declarations,
statements, expressions, and patterns, each with a short example. It
answers "how do I write this?". What a form means, and what the
compiler accepts, is in the [language reference](SPEC.md); a guided
start from Rust, Zig, C, Python, or another language is
[WELCOME.md](WELCOME.md).

Every `rig` example here is compiled and run by the test suite. A
program followed by an `output` block prints exactly that, with no
leaks; a program marked as rejected fails with the errors shown.

## Contents

1. [Source files](#1-source-files)
2. [Layout](#2-layout)
3. [Names and keywords](#3-names-and-keywords)
4. [Literals](#4-literals)
5. [Prefixes, infixes, and suffixes](#5-prefixes-infixes-and-suffixes)
6. [Operators and precedence](#6-operators-and-precedence)
7. [Types](#7-types)
8. [Declarations](#8-declarations)
9. [Bindings and assignment](#9-bindings-and-assignment)
10. [Statements and control flow](#10-statements-and-control-flow)
11. [Expressions](#11-expressions)
12. [Patterns](#12-patterns)
- [Appendix: grammar summary](#appendix-grammar-summary)

---

## 1. Source files

A source file is UTF-8 text whose name ends in `.rig`. Lines end in
`\n` or `\r\n`; a carriage return without a line feed is an error. A
byte order mark at the start of the file is skipped.

A file is a list of declarations: functions, types, constants,
imports, `extern` declarations, and `test` blocks
([§8](#8-declarations)). Statements live inside functions. A program
that runs declares its entry point, `sub main()`, or `fun main() -> Int`
for an exit status.

```rig
# A comment runs from `#` to the end of the line.
sub main()
  x = 1   # after code, too
  print(x)
```

```output
1
```

There are no block comments and no doc-comment syntax.

## 2. Layout

**Indentation** makes blocks. A line indented deeper than the one
before it opens a block, and coming back to an enclosing line's
indentation closes it. Anything that takes a block (a function, a
type, `if`, `while`, `for`, `match`, `defer`, `raw`, a closure) takes
the indented lines after its header, and a header ends without a `:`.
Indent with spaces: a tab in indentation is an error, and so is a
dedent to a column that matches no enclosing block.

```rig reject
sub main()
	print(1)
```

```error
tab in indentation; indent with spaces
```

**Statements** are one per line, and there is no `;`: a statement ends
at the end of its line.

**Line joining.** Inside `( )` and `[ ]` a newline is plain whitespace,
so a call, an array, a parenthesized expression, or a method chain can
span lines at any indentation. A `\` at the end of a line joins the
next line anywhere. A list may end with a comma: an array, a call's
arguments, a parameter list, a list of compile-time parameters or
arguments, a closure's bar list, and a variant pattern's bindings.

```rig
fun volume(
  w: Int,
  h: Int,
  d: Int,
) -> Int
  w * h * d

sub main()
  v = volume(
    2,
    3,
    4,
  )
  more = (v +
      10)
  total = v + \
    1
  print(v, more, total, [
    1,
    2,
  ])
```

```output
24 34 25 [1, 2]
```

**Closure bodies inside brackets.** A closure's body may be an indented
block wherever the closure is written ([§11](#closures)). When its bar
list ends a line inside `( )` or `[ ]`, the body below is laid out in
blocks as anywhere else, and it ends with the bracket around it on a
line of its own, at the indentation of the line that opened the
bracket: the closure is the last thing the bracket holds. A one-line
body stays on the bar list's line.

```rig
sub each(n: Int, f: *sub(Int))
  for i in 0..n
    f(i)

sub main()
  total: *Cell[Int] = *Cell(0)
  each(3, *|+total, i|
    total.set(total.get() + i)
    print("saw", i)
  )
  each(2, *|i| print("trailing", i))
  print(total.get())
```

```output
saw 0
saw 1
saw 2
trailing 0
trailing 1
3
```

A bracket that ends the body's last line is rejected, with the layout
to write:

```rig reject
sub each(n: Int, f: *sub(Int))
  for i in 0..n
    f(i)

sub main()
  each(2, *|i|
    j = i * 2
    print(j))
```

```error
a closure body below its bar list ends with `)` on a line of its own: end this line before the `)`, and write `)` on the next line at the indentation of the line that opened it (column 3)
```

## 3. Names and keywords

**Names** are ASCII: a letter or `_`, then letters, digits, and `_`.
Types are conventionally `CamelCase` and everything else `snake_case`.
`_` alone discards: `_ = f()`, or a parameter or pattern binding that is
not used.

**Keywords** are reserved:

| Role | Keywords |
|---|---|
| declarations | `fun` `sub` `struct` `enum` `error` `type` `use` `pub` `extern` `test` `drop` |
| bindings | `const` |
| control | `if` `else` `while` `for` `in` `match` `break` `continue` `return` `defer` `errdefer` `pass` |
| expressions | `and` `or` `not` `as` `catch` `true` `false` |
| boundaries | `raw` `zig` (in `extern zig`) |
| reserved forms | `try`, and `zig` elsewhere |
| held for later | `async` `await` `impl` `trait` `when` `where` `yield` |

A keyword may still name a member, where it cannot be mistaken for the
keyword: a struct field, a method, or a payload field. It reads as a
name right after `.` (`t.type`, `t.error()`), before `:` inside
parentheses (a keyword argument or payload field, `Token(type: 1)`),
and in a member list before `:` (a field) or after `fun` / `sub` (a
method). `drop(!self)` is still a drop body, and `drop: Bool` a field.
Everywhere else a keyword names nothing: not a local, a parameter, a
top-level declaration, or an enum variant.

```rig
struct Token
  type: Int
  in: Bool
  drop: Bool

  fun error(?self) -> Bool
    self.type < 0

sub main()
  t = Token(type: -1, in: true, drop: false)
  print(t.type, t.in, t.drop, t.error())
```

```output
-1 true false true
```

```rig reject
fun f(in: Int) -> Int
  1
```

```error
`in` is a keyword and cannot name a parameter
```

Six words are keywords only in one position. `new` is a keyword at
the start of a statement (`new x = ...`, `new const x = ...`), so a
method may be named `new`. `of` is a keyword only after a value directly inside `[ ]`,
where it separates a fill literal's count from its element
(`[n of x]`). `unique` is a keyword only after a struct's name or type
parameters (`struct Random unique`). `from` is a keyword only after a
function's result type (`-> ?Item from a`), and `static` only right
after that `from`; a parameter or a local may be named either. `none`
is a reserved name, the absent optional. The words
held for later start no form yet. Words that are keywords elsewhere but
not in Rig, such as Zig's `var` and `fn`, are ordinary names.

The built-in types `Cell`, `Vec`, `Box`, `Text`, `Signal`, and
`Endian` are reserved names. The built-in functions `print`, `replace`, and `swap`
are names a declaration may hide.

## 4. Literals

| Literal | Examples | Notes |
|---|---|---|
| integer | `42`, `1_000_000`, `0xff`, `0b1010`, `0o17` | `_` separates digits; radix prefixes are lowercase; no leading zero and no type suffix |
| float | `3.14`, `.5`, `1e10`, `2.5e-3`, `1.5E+2` | a `.` or an exponent; the digits before `.` may be left out |
| string | `"tab\t, newline\n"`, `'it''s raw'` | double quotes take Zig's escapes (`\n`, `\t`, `\\`, `\"`, `\x41`, `\u{e9}`); single quotes take none, and `''` is one `'` |
| bool | `true`, `false` | |
| absent optional | `none` | |
| array | `[1, 2, 3]`, `[]` | |
| fill | `[4 of 0]`, `[n of x]` | `n` copies of `x`, count first as in the type `[n]T` |
| enum variant | `.red`, `.circle(2)`, `.rect(w: 2, h: 3)` | the enum comes from context |

A string holds no control character: a tab or newline in it is written
`\t` or `\n`. There is no string interpolation; `print` takes several
values. A literal's type comes from its context
([SPEC §2](SPEC.md#primitive-types)).

```rig
sub main()
  print(0xff, 0b101, 0o17, 1_000, .5, 1e3, 1.5E+2, 2e-3)
  print("tab\there", 'it''s raw: \n', "quote: 'x'")
  print([3 of 7], [2 of [2 of 0]])
```

```output
255 5 15 1000 0.5 1000.0 150.0 0.002
tab	here it's raw: \n quote: 'x'
[7, 7, 7] [[0, 0], [0, 0]]
```

## 5. Prefixes, infixes, and suffixes

The characters `<` `+` `-` `*` `?` `!` `|` are both operators and
prefixes, and `(`, `[`, and `.` both continue a value and start a new
one. Whitespace never decides which: a character's position does, and
spacing that would read as the other form is rejected.

> After a value (a name, a literal, `)`, `]`, or a `?` or `!` suffix), a
> character continues that value: it is an infix operator, a suffix, a
> call, an index, or member access. Anywhere else it starts an operand,
> as a prefix.

| Source | Reads as |
|---|---|
| `a < b`, `a<b` | comparison |
| `x = <y`, `f(<y)` | a move |
| `a - 1`, `a-1` | subtraction |
| `f(-x)`, `-x` | negation |
| `f(x)`, `f (x)`, `a[i]`, `a.b` | a call, an index or compile-time arguments ([§11](#compile-time-arguments)), member access |
| `(x)`, `[1, 2]`, `.red` | grouping, an array literal, an enum literal |
| `T?`, `T!`, `f()!`, `x?` | suffixes: optional, fallible, propagate a failure or `none` |
| `a \| b`, `\|x\| x + 1` | bitwise or, and a closure's bar list |

A prefix sigil says how a value is held, and a suffix `?` or `!` is
control flow: Rig has no `!` for "not" (that is `not`), so `!v.pop()`
lends `v` to write ([WELCOME](WELCOME.md#the-central-idea)).

So a sigil touches what it marks, and spacing shows how a line reads:

- An infix operator has the same spacing on both sides, `a < b` or
  `a<b`, never `a <b` or `a< b`. This holds for every operator between
  two values: arithmetic, comparisons, `??`, `..`, the bitwise
  operators, and `=` and the compound assignments.
- A prefix sigil (`<` `+` `-` `*` `?` `!` `~`) touches its operand, in
  an expression and in a type: `-b`, `<x`, `*T`, `[]?T`.
- A postfix `?` or `!` touches what it follows: `f()!`, `x?`, `T?`.
- A member `.` touches both sides, `w.get()`; inside brackets a chain
  may go on at the start of the next line. An enum literal's `.`
  touches its name, `.red`, and a range with one bound touches it,
  `xs[a..]`, `xs[..b]`.

Spacing that breaks one of these is rejected, with the text to write,
so `a <b` (a comparison, or a forgotten comma before a move?) and
`a <- b`, which Rig does not have, never pass for something else.
Around a call's or an index's bracket, spacing changes nothing.

```rig
fun twice(n: Int) -> Int
  n * 2

sub main()
  a = 5
  b = 3
  print(a - b, a-b, twice(-b), twice (a) - b)
```

```output
2 2 -6 7
```

```rig reject
sub main()
  a = 5
  b = 3
  print(a -b)
```

```error
`a -b`: an operator has the same spacing on both sides; write `a - b` to subtract, or `a, -b` to negate `b` as a value of its own
```

```rig reject
sub main()
  a = 1
  b = 2
  print(a <- b)
```

```error
a prefix `-` touches its operand: write `-b`
```

Tokens split by the longest match, as in C and Zig, so `a == b` is not
`a = = b`. `=!` is one token and no operator: `x =! y` and `x =!y` are
rejected, so `x =!y` never passes for `x = !y`, a write lend. A sigil
after the `]` of an array or slice type starts its element type: in
`[2]?Int`, each element is a read view.

Postfixes bind tighter than prefixes: `-a.len` is `-(a.len)`, and
`+n.first()` clones what `first` returns. The one exception is a
receiver sigil.

### Receiver sigils

`?`, `!`, or `<` directly before a *place* (a name, then any `.field`
or `[index]` steps) that a method call follows applies to the place,
the method's receiver. Postfixes after the call apply to its result.
In a chain, it reaches the receiver of the first method call
(`!a.b().c(x)` is `(!a).b().c(x)`). `!` lends any value to write
([CORE](docs/CORE.md) sentence 4), so it also reaches a receiver no
name holds, and the fields and elements after it: the value a call
that is no method call makes (`!mk().pop()`), a literal
(`![a, b][0].bump()`), or a parenthesized expression (`!(+s).bump()`).
A call of a call's value is walked through to the first call:
`!a.b(x)(y).g()` is `(!a).b(x)(y).g()`. A function called through a
module or a type reads as a method of a value, so `!lib.mk().bump()`
reaches `lib`: the checker says so, and the call in parentheses,
`!(lib.mk()).bump()`, lends the value it makes.

| Long form | Short form | Meaning |
|---|---|---|
| `(!v).push(x)` | `!v.push(x)` | lend `v` to write, then push |
| `(!self.items).push(k)` | `!self.items.push(k)` | a field of `self` in a `!self` method |
| `(!grid[r]).bump()` | `!grid[r].bump()` | an element, changed in place |
| `(!v).put[2](x)` | `!v.put[2](x)` | a method with compile-time arguments |
| `(!mk()).pop()` | `!mk().pop()` | lend the value `mk()` makes to write, a temporary |
| `(!mk().items).push(k)` | `!mk().items.push(k)` | a field of that temporary |
| `(!(+s)).bump()` | `!(+s).bump()` | a parenthesized receiver |
| `((!v).pop())?` | `!v.pop()?` | the suffix applies to the result |
| `(<conn).close()` | `<conn.close()` | move `conn` into `close` |
| `(?p).dist(q)` | `?p.dist(q)` | lend `p` to read; the same as `p.dist(q)` |

Only `?`, `!`, and `<` reach the receiver, since they are the modes a
method declares (`?self`, `!self`, `<self`). Every other prefix, and
`?`, `!`, or `<` with no method call after the place, applies to the
whole expression: `*Point.origin()` shares the new `Point`, `-a.len`
negates the length, `!x.v` lends the field, `<p.f` takes the optional
field, and `?xs[0]` lends the element. A `?` or `<` before a value a call
makes applies to the whole expression too: `?f(x).g()` lends what `g`
returns, since a made receiver is read or taken without a sigil. With
parentheses around the call, `?(p.m())` and `!(p.m())` lend its
result. The long form is valid everywhere; it is
required for a write call whose value is used, whatever its type:
`if (!set).insert(k)`, `x = (!v).pop()`, `while (!it).next() as x`,
so that its `!` never reads as negation. The short form stands only
where the value is discarded: a statement, alone or under `!`, `?`, or
`catch` ([SPEC §3](SPEC.md#structs) has the checks).

```rig
struct Stack
  items: Vec[Int]

  sub push(!self, k: Int)
    !self.items.push(k)

  fun pop(!self) -> Int?
    (!self.items).pop()

  fun total(<self) -> Int
    sum = 0
    for k in ?self.items
      sum += k
    sum

sub main()
  s = Stack(items: Vec())
  !s.push(1)
  !s.push(2)
  !s.items.push(3)
  print((!s).pop() ?? 0)
  print(<s.total())
```

```output
3
3
```

## 6. Operators and precedence

From lowest to highest precedence:

| Operators | Notes |
|---|---|
| `a if c else b`, `e catch f` | ternary and error fallback, right-nested; `e catch return v` and `a ?? return v` take a jump at this level |
| `or` | |
| `and` | |
| `not` | |
| `==` `!=` `<` `>` `<=` `>=` | not chainable |
| `??` | optional fallback, right-associative |
| `..` | half-open range: a `for` source, a match pattern, or a slice's index, where a side may be open (`xs[a..]`) |
| `\|` | bitwise or |
| `^` | bitwise xor |
| `&` | bitwise and |
| `<<` `>>` | shifts |
| `+` `-` `+%` `-%` | `+%` and `-%` wrap |
| `*` `/` `%` `*%` | `*%` wraps |
| `-x` and the sigils | prefix |
| `f(x)` `a[i]` `a.b` `e!` `e?` | postfix: call, index, member, propagate |

`not` binds looser than a comparison, so a comparison under it is
written in parentheses, `not (a == b)`, never `not a == b`, which
could read as `(not a) == b` ([SPEC §5](SPEC.md#operators)). `not a
and b` is `(not a) and b`. `as` binds tighter than `and`, in a condition that
binds ([§10](#conditions-that-bind)). There is no `&&`, `||`, `**`,
`++`, or `--`, and prefix `!` lends to write, never "not". What each
operator does, and which types it takes, is in
[SPEC §5](SPEC.md#operators).

## 7. Types

| Form | Written | Meaning |
|---|---|---|
| a named type | `Int`, `Point`, `geo.Point` | a built-in, local, or imported type |
| a generic instance | `Vec[Int]`, `Pair[Int, String]`, `Ring[Int, 4]`, `lib.Wrap[Int]` | [SPEC §3](SPEC.md#generic-types) |
| optional | `T?` | a `T` or `none` |
| fallible | `T!` | a `T` or an error; a return type only |
| read view | `?T` | [SPEC §7](SPEC.md#lending) |
| write view | `!T` | |
| shared handle | `*T` | [SPEC §9](SPEC.md#9-shared-and-weak-handles) |
| weak handle | `~T` | |
| array | `[4]Int`, `[LIMIT * 2]U8`, `[n]T` | a length known at compile time |
| slice | `[]T` | a read-only view |
| writable slice | `![]T` | |
| function | `fun(Int, Int) -> Int`, `sub(String)`, `sub(Int)!` | [SPEC §11](SPEC.md#function-types) |
| owned closure | `*fun(Int) -> Int`, `*sub()` | |
| weak closure | `~fun(Int) -> Int` | |
| callable view | `?fun(Int) -> Int`, `?sub(Int)` | a parameter's, a local's, or a result's type |

The primitive types are `Int` (the same as `I64`), `I8` `I16` `I32`
`I128`, `U8` `U16` `U32` `U64` `U128`, `Float` (the same as `F64`),
`F32`, `Bool`, `String`, and `Void`; [SPEC §2](SPEC.md#2-types) lists
what each holds. `Text`, owned text, is a built-in type
([SPEC §10](SPEC.md#text)).

**How the sigils combine.** The handle sigils `*` and `~` bind to the
type after them, tighter than the suffixes: `*User?` is an optional
shared handle and `~User?` an optional weak handle, while a handle to
an optional is written `*(User?)`. A view sigil applies to the whole
type after it, suffixes included: `?User?` and `!User?` view an
optional, and `?*User?` views an optional handle. Prefixes compose right
to left: `?*Node` is a read view of a shared handle, and
`*Cell[Vec[*sub()]]` a shared cell holding a list of owned closures.
The element of a slice or array takes the suffixes (`[]Int?` is a slice
of optionals), and a function type takes none, so an optional slice,
array, or function type is written in parentheses: `([]Int)?`,
`(*sub())?`. So is an optional of an optional, `(User?)?`, since `??`
is an operator. Suffixes read left to right: `S?!` is an `S?` that may
fail, and `(?S)?` an optional read view of an `S`.

```rig
struct User
  name: String

fun named(u: ?*User?) -> Bool
  u != none

sub main()
  a: *User? = none
  b: *User? = *User(name: "ada")
  print(named(?a), named(?b))
```

```output
false true
```

```rig reject
struct User
  name: String

sub main()
  c: *(User?) = none
```

```error
`none` needs an optional type; `*(User?)` is not optional (write `*(User?)?`)
```

**Array lengths.** An array's length is an integer, a constant
(`[LIMIT]T`, `[lib.N]T`), a compile-time parameter (`[n]T`), or
arithmetic on integers and constants with `+`, `-`, `*`, `/`, `%`, and
parentheses (`[LIMIT * 2 + 1]U8`). `[2][3]Int` is two arrays of three.

**Function types** write the result after `->`, as the declaration they
describe does: `fun area(w: Int, h: Int) -> Int` has the type
`fun(Int, Int) -> Int`. A suffix belongs to the result, so
`fun(Int) -> Int!` returns an `Int!`, and a fallible `sub` type ends in
`!`: `sub(Int)!`.

## 8. Declarations

A declaration lives at module level; there are no nested functions or
types. `pub` before a declaration exports it to importing modules
([SPEC §14](SPEC.md#14-modules)). By convention, which the test suite
checks of Rig's own code, one blank line separates top-level
declarations, though one-line ones (`use`, constants, `extern`,
`type`) may stand together.

### Functions

```rig
fun area(w: Int, h: Int) -> Int
  w * h

fun sign(n: Int) -> Int
  return 1 if n > 0 else -1 if n < 0 else 0

sub report(label: String, n: Int)
  print(label, n)

sub main()
  report("area", area(3, 4))
  report("sign", sign(-7))
```

```output
area 12
sign -1
```

- `fun name(params) -> R` returns an `R`, and `sub name(params)`
  returns nothing. The first word says which.
- A `sub` that may fail ends its header with `!`:
  `sub save(p: Page)!`. A `fun` that may fail returns `T!`.
- A parameter is `name: Type`, and may have a default:
  `by: Int = 10`. A parameter the body ignores may be named `_`.
- A function always writes its parameter list, even when empty, as
  its calls (`f()`) and its type (`sub()`) do: `sub main()`,
  `fun answer() -> Int`.
- The body's last expression is its value; `return e` leaves early.
- A result that holds a view may say which parameters it views, after
  its type: `-> ?Item from a`, `-> String from a, b`, `-> ?T from
  self`, or `-> String from static` for only what lives for the whole
  program ([CORE sentence 7](docs/CORE.md#2-the-core-in-ten-sentences)).
- Compile-time parameters go in brackets after the name:
  `fun max[T](a: T, b: T) -> T`, `sub show[n: Int]()`
  ([Generics](#generics-and-compile-time-parameters)).

A definition without its parameter list is rejected, with the header
to write:

```rig reject
sub main
  print(1)
```

```error
write `sub main()`: a function's parameter list is always written, even when empty
```

### Structs

A `struct` lists its fields, then its methods and at most one `drop`
body. A field is `name: Type`, with an optional default value
(`y: Int = 0`).

```rig
struct Point
  x: Int
  y: Int = 0

  fun origin() -> Self
    Point(x: 0)

  fun length2(?self) -> Int
    self.x * self.x + self.y * self.y

  fun plus(?self, other: ?Point) -> Point
    Point(x: self.x + other.x, y: self.y + other.y)

  sub shift(!self, dx: Int)
    self.x += dx

sub main()
  p = Point.origin()
  q = Point(x: 3, y: 4)
  r = p.plus(?q)
  !r.shift(10)
  print(r, q.length2())
```

```output
Point(x: 13, y: 4) 25
```

A method whose first parameter is the receiver is an instance method;
one without is an associated function, called through the type
(`Point.origin()`). `Self` names the enclosing type.

| Receiver | Long form | Called as |
|---|---|---|
| `?self` | `self: ?Self` | `p.m()`, or `?p.m()` |
| `!self` | `self: !Self` | `!p.m()` |
| `<self` | `self: Self` | `<p.m()`, or on a temporary |
| (none) | | `Point.origin()` |

The sigil shorthand is only for `self`; other parameters put the sigil
on the type (`other: ?Point`). A drop body is written like a method
with the receiver `!self` and no name: `drop(!self)`. `pub` before a
field or method exports it: `pub x: Int`, `pub fun sum(?self) -> Int`.

`unique` after the name (or the type parameters) declares a unique
struct, whose values move instead of copying
([SPEC](SPEC.md#kinds-of-value)):

```rig
struct Ticket unique
  id: Int

sub main()
  t = Ticket(id: 7)
  u = <t
  print(u.id)
```

```output
7
```

### Enums

An `enum` lists variants, then methods. A variant is a name, a name
with an integer value (`ok = 200`), or a name with payload fields
(`circle(radius: Int)`).

```rig
enum Status
  ok = 200
  missing = 404

enum Shape
  circle(radius: Int)
  rect(w: Int, h: Int)
  point

  fun area(?self) -> Int
    match self
      .circle(r) => 3 * r * r
      .rect(w, h) => w * h
      .point => 0

sub main()
  s: Shape = .rect(w: 2, h: 5)
  c = Shape.circle(2)
  st: Status = .missing
  print(s.area(), c.area(), s, st == .missing)
```

```output
10 12 .rect(w: 2, h: 5) true
```

A variant is written `.name` where its enum is known from context, or
`Type.name`. A payload variant is built with its fields named,
`.rect(w: 2, h: 5)`, and one with a single field also takes it by
position: `.circle(2)` is `.circle(radius: 2)`.

### Error sets

`error Name` lists the error values a fallible function may fail with.
A function fails with one by naming its set, `return NetError.timeout`,
and each error belongs to its set: another set's `timeout` is a
different error.

```rig
error NetError
  timeout
  refused

sub main()
  e: NetError = .timeout
  print(e, e == NetError.timeout)
```

```output
NetError.timeout true
```

### Type aliases

`type Name = T` gives a type a second name.

```rig
type UserId = Int

struct Point
  x: Int

type P = Point

sub main()
  id: UserId = 5
  p = P(x: id)
  print(p.x + 1)
```

```output
6
```

### Generics and compile-time parameters

Square brackets hold everything known at compile time, and parentheses
what is known when the program runs. In a bracket list after a declared
name, a bare name is a type parameter and `name: Type` a compile-time
value. There is no `<T>` and no `comptime` keyword.

| | Declared | Used |
|---|---|---|
| generic type | `struct Pair[T, U]`, `enum Option[T]` | `Pair[Int, String]`, `Pair(first: 1, second: "x")`, `Option[Int].some(7)` |
| generic function | `fun max[T](a: T, b: T) -> T` | `max(3, 7)`, `max[Float](1, 2)` |
| generic method | `fun map[U](?self, f: fun(T) -> U) -> Wrap[U]` | `b.map(label)` |
| compile-time value | `fun check[mode: Mode](n: Int)` | `check[.strict](5)` |
| both | `sub rep[T, n: Int](x: T)` | `rep[String, 3]("hi")` |
| a length | `fun sum[n: Int](xs: [n]Int)` | `sum([1, 2, 3])`, `sum[3](xs)` |
| a type with a value | `struct Ring[T, n: Int]` | `Ring[Int, 4]`, `Ring(items: [4 of 0])` |

A method's own parameters sit beside its type's: inside `Wrap[T]`,
`fun map[U]` has both `T` and `U`. A call gives every compile-time
argument in brackets, or none and lets them be inferred
([SPEC §3](SPEC.md#generic-functions)). A function with no run-time
parameters writes `()` after its brackets, in its declaration as in a
call: `sub show[n: Int]()` is called `show[3]()`.

```rig
struct Wrap[T]
  v: T

  fun map[U](?self, f: fun(T) -> U) -> Wrap[U]
    Wrap(v: f(self.v))

fun max[T](a: T, b: T) -> T
  a if a > b else b

sub rep[T, n: Int](x: T)
  for i in 0..n
    print(i, x)

fun label(n: Int) -> String
  "big" if n > 9 else "small"

sub main()
  b = Wrap(v: 12)
  print(b.map(label).v, max(3, 7), max[Float](1, 2))
  rep[String, 2]("hi")
```

```output
big 7 2.0
0 hi
1 hi
```

### Constants

A binding at module level is a constant: `LIMIT = 10`,
`names = ["low", "high"]`, `pub unit: U8 = 10`. It is written with `=`,
never `const` ([SPEC §3](SPEC.md#constants)).

### Tests

`test "name"` (or `test 'name'`) declares a block that `rig test` runs.

### Imports and extern

`use name` imports the module `name.rig`, whose `pub` declarations are
then named `name.decl` and `name.Type`
([SPEC §14](SPEC.md#14-modules)). `use std.name` imports a module of
the standard library ([STD.md](docs/STD.md)), named `name` here, and
`as` names a module otherwise: `use geo as g`, `use std.os as o`. `extern fun name(params) -> R`,
`extern sub name(params)`, and `extern name: T` declare C functions and
data ([SPEC §15](SPEC.md#15-raw-code-and-ffi)). In the standard library,
`extern zig "file.zig"` holds an indented list of `fun` and `sub`
declarations without bodies, which that Zig file implements
([SPEC §15](SPEC.md#zig-backed-declarations)).

## 9. Bindings and assignment

| Form | Meaning |
|---|---|
| `x = e` | declare `x`, or assign the visible `x` (through it, when `x` holds a write view) |
| `x: T = e` | declare with a type |
| `const x = e`, `const x: T = e` | declare a fixed `x`, which cannot be reassigned |
| `new x = e`, `new x: T = e`, `new const x = e` | declare a new `x` shadowing the visible one; `e` may read the old |
| `x = <y` | move `y` into `x` |
| `x += e`, and `-=` `*=` `/=` `%=` `+%=` `-%=` `*%=` `&=` `\|=` `^=` `<<=` `>>=` | compound assignment |
| `p.f = e`, `xs[i] = e` | assign a field or an element |
| `_ = e` | evaluate `e` and discard it |

There is no `let` or `var`. The first `x = e` in a scope declares `x`,
and later ones assign it. `const x = e` declares a binding that never
changes, in a function body; at module level every binding is already
constant.

```rig
sub main()
  x = 1
  x = x + 1
  const limit = 10
  new x = "now a string"
  total = 0
  total += limit
  print(x, total)
```

```output
now a string 10
```

A local may not reuse a visible name without `new`, and every local
must be read; [SPEC §4](SPEC.md#4-bindings-and-assignment) has the
rules.

## 10. Statements and control flow

A statement is one of:

- an expression: a call, a propagation (`f()!`), a `catch`, or a block
  form (`if`, `while`, `for`, `match`);
- a binding or assignment ([§9](#9-bindings-and-assignment));
- a drop, `<x`: a move to nowhere, which drops what it takes now
  (`<x`, `<s.f`); where a value is used (a `fun`'s last line, a closure's,
  a branch whose value is used), `<x` moves the value there;
- `pass`, which does nothing;
- `return`, `return e`, `break`, `break e`, `break :label`,
  `continue`, `continue :label`;
- `defer` or `errdefer` with a statement or block (a one-line
  statement may not declare a name);
- a `raw` block ([SPEC §15](SPEC.md#15-raw-code-and-ffi));
- a labeled loop, `match`, or `raw` block, `:name stmt`.

### if

`if cond` takes an indented block, `else if` chains, and `else` ends
the chain. Where its value is used, `if` is an expression, and the
one-line form is `a if c else b` (Python's order, not C's `c ? a : b`).

```rig
sub main()
  x = 5
  if x > 10
    print("big")
  else if x > 3
    print("medium")
  else
    print("small")
  print("odd" if x % 2 == 1 else "even")
```

```output
medium
odd
```

### Guards

A simple statement (a call, a binding or assignment, a drop, `return`,
`break`, or `continue`) may end with `if cond`, and then runs only when
`cond` holds, like Ruby's statement modifier.

```rig
fun first_over(limit: Int) -> Int
  i = 0
  while true
    i += 1
    return i if i > limit

sub main()
  x = 5
  print("big") if x > 3
  x += 1 if x < 10
  print(first_over(3), x)
```

```output
big
4 6
```

A guard ends a statement and covers all of it: in
`n = parse(s) catch |e| f(e) if ready`, the guard covers the whole
binding, `catch` included, not the handler alone. Inside an expression,
write the ternary.

```rig
error E
  bad

fun parse(s: String) -> Int!
  return E.bad if s == "x"
  s.len

sub main()
  n = 5
  n = parse("x") catch |e| (-1 if e == E.bad else -2) if false
  print(n)
  n = parse("x") catch |e| (-1 if e == E.bad else -2) if true
  print(n)
```

```output
5
-1
```

### while

```rig
sub main()
  i = 0
  while i < 5 : i += 1
    continue if i == 1
    break if i == 4
    print(i)
  else
    print("never: the loop broke")
  n = 3
  while n > 0
    n -= 1
  else
    print("done")
```

```output
0
2
3
done
```

`while cond : step` runs `step`, an assignment or a call, after each
iteration. An `else` block runs when the loop ends without `break`.
`while e as x` loops while the optional `e` has a value
([Conditions that bind](#conditions-that-bind)).

### for

`for x in source` walks a range `a..b`, an array, a slice, a `String`
(its bytes), or a `Vec`. `for x, i in xs` also binds the index, after
the element. A sigil on the source says how the loop holds it.

```rig
sub main()
  total = 0
  for i in 0..5
    total += i
  for c, i in ["a", "b"]
    print(i, c)
  print(total)
  xs = [1, 2, 3]
  for x in !xs
    x *= 10
  print(xs)
```

```output
0 a
1 b
10
[10, 20, 30]
```

| Loop | Element |
|---|---|
| `for x in xs`, `for x in ?xs` | each element read in place: a copy of plain data, a view of anything else |
| `for x in !xs` | a write view of each element |
| `for x in <v` | each element of a Vec, owned; `v` is consumed |

A source made there (`for x in mk()`) is taken; [SPEC §6](SPEC.md#for)
has the rules. An `else` block runs when the loop ends without `break`.

### Labels, break, and continue

`:name` before a loop labels it, and `break :name` or `continue :name`
names it from an inner loop. A `match` or `raw` statement may be
labeled too, and `break :name` leaves it; no other statement takes a
label, and none takes two. A jump after `??` or `catch`
names a label the same way, `v = next() ?? continue :outer`, except in a
`while` header, where the first `:` starts the step.

```rig
sub main()
  :outer for i in 0..3
    for j in 0..3
      continue :outer if j > i
      break :outer if i == 2
      print(i, j)
```

```output
0 0
1 0
1 1
```

### Loops as values

A loop that `break`s with a value is an expression, and its `else`
block gives the value when it ends without breaking (`while true` needs
none).

```rig
fun index_of(xs: ?[4]Int, target: Int) -> Int
  for x, i in xs
    break i if x == target
  else
    -1

sub main()
  xs = [3, 1, 4, 1]
  print(index_of(?xs, 4), index_of(?xs, 9))
  n = 27
  steps = 0
  last = while true
    break steps if n == 1
    n = n / 2 if n % 2 == 0 else 3 * n + 1
    steps += 1
  print(last)
```

```output
2 -1
111
```

### match

`match subject` takes an indented list of arms. An arm is
`pattern => statement`, or a pattern followed by an indented block. A
pattern may list alternatives (`0, 1 =>`) and end with a guard
(`k if k < 0 =>`); [§12](#12-patterns) lists the patterns. The first
arm that matches runs, and there is no fallthrough.

```rig
fun kind(n: Int) -> String
  match n
    0, 1 => "unit"
    k if k < 0 => "negative"
    2..10 => "small"
    _ => "large"

sub main()
  print(kind(1), kind(-4), kind(7), kind(99))
  match 7
    1 => print("one")
    other
      print("got", other)
```

```output
unit negative small large
got 7
```

Every value the subject can have needs an arm, so an arm with nothing
to do is written `_ => pass`. `pass` is a statement that does nothing,
for a match arm, loop body, branch, or function body with no work; it
has no value, so an arm or branch whose value is used cannot be `pass`.

```rig
enum Light
  red
  amber
  green

sub stop(l: Light)
  match l
    .red => print("stop")
    _ => pass

sub later()
  pass

sub main()
  stop(.red)
  stop(.green)
  later()
```

```output
stop
```

The subject takes a sigil the way a `for` source does: `match e` and
`match ?e` read the payloads, `match !e` binds write views of them,
and `match <e` consumes `e` ([SPEC §6](SPEC.md#match)).

### defer and errdefer

`defer` takes a statement or a block, and runs it when the enclosing
block exits, in reverse order. `errdefer` runs only when the function
fails, so it goes only in a function that can fail.

```rig
sub main()
  defer print("cleanup 1")
  defer
    print("cleanup 2")
  print("body")
```

```output
body
cleanup 2
cleanup 1
```

### Conditions that bind

An `if` or `while` condition binds the value inside an optional with
`as`, and joins bindings and `Bool` conditions with `and`
([SPEC §12](SPEC.md#12-optionals)):

| Form | Binds |
|---|---|
| `if a as x` | the value inside `a`; `else` runs for `none` |
| `if ?a as x`, `if !a as x` | a read or write view of the value inside `a` |
| `if <p.f as x` | the value taken out of a field, which is left `none` |
| `while a as x` | each value `a` produces |
| `while (!q).pop() as x` | what a call that lends its receiver to write returns |
| `if a as x and x > 0 and b as y` | in order, each part only when the ones before it held |
| `if a as _` | nothing: a test for a value |

`as` stands nowhere else: not under `or` or `not`, and not in a
ternary's or a guard's condition.

## 11. Expressions

### Calls

Every call has parentheses, wherever it stands, and a space before
them changes nothing: `f (x)` is `f(x)`. A name alone never runs code:
`greet` is the function, a value, and `greet()` calls it.

```rig
fun add(a: Int, b: Int) -> Int
  a + b

sub main()
  print(add(1, 2))
  print(add(1, 2), add (3, 4))
  print((1 + 2) * 3)
  total = add(1, 2)
  if add(total, 1) > 3
    print(total)
```

```output
3
3 7
9
3
```

```rig reject
fun twice(n: Int) -> Int
  n * 2

sub main()
  x = twice 5
  print(x)
```

```error
unexpected `5`
```

Arguments go by position, in parameter order, or by keyword,
`name: value`, in any order. Positional arguments come first, and a
parameter with a default may be left out.

```rig
fun scaled(n: Int, by: Int = 10, _: Bool = false) -> Int
  n * by

sub main()
  print(scaled(3, 2), scaled(by: 4, n: 5), scaled(3, by: 2), scaled(3))
```

```output
6 20 6 30
```

A closure whose body is an assignment (`|!total, n| total += n`) is the
last argument of a call. A method is called on a value, `p.m(args)`,
with a receiver sigil when it writes or consumes the receiver
([§5](#receiver-sigils)); an associated function through its type,
`Point.origin()`; and a builtin with `@`: `@size(Int)`.

### Function values

A function's name, or a method named through its type, is a value of a
function type. A method's first parameter is then its receiver.

```rig
fun twice(n: Int) -> Int
  n * 2

fun apply(f: fun(Int) -> Int, x: Int) -> Int
  f(x)

struct Counter
  n: Int

  sub bump(!self)
    self.n += 1

sub main()
  g = twice
  print(apply(g, 5), apply(twice, 1))
  c = Counter(n: 0)
  bump = Counter.bump
  bump(!c)
  bump(!c)
  print(c.n)
```

```output
10 2
2
```

### Constructors

A struct is built by calling its name with its fields named,
`Point(x: 1, y: 2)`, leaving out fields that have defaults. A struct
with exactly one field also takes it by position: `Meters(3.5)`, and
the built-ins `Box(x)`, `Cell(0)`, and `*Signal(0)`. A payload variant
is built the same way, `.rect(w: 2, h: 5)` or `Shape.circle(2)`, and a
generic type's arguments may be given in brackets:
`Pair[Int, Float](first: 1, second: 2.5)`, `Vec[Int]()`,
`Option[Int].some(7)`. A `Vec` is built empty, `Vec()` or
`Vec(capacity: 16)`. A `Text` is built from any values, each written
as `print` writes it: `Text("n=", n)`, or `Text()` for an empty one.

### Members, indexes, and slices

| Form | Meaning |
|---|---|
| `p.x`, `p.m()` | a field (a field read never runs code), a method call |
| `xs[i]` | an element, bounds-checked |
| `s[a..b]` | a slice of a String, itself a String |
| `?xs[a..b]`, `!xs[a..b]` | a read or write slice of an array or Vec |
| `?t[a..b]` | a lend of part of a Text: a String viewing it |
| `f(xs[a..b])` | `f(?xs[a..b])` where `f` takes a `[]T` or a String: a slice argument is lent as its name is |
| `xs[a..]`, `xs[..b]`, `xs[..]` | a slice with an open side |
| `?a` where a `[]T` is expected | `?a[..]`; `!a` where a `![]T` is |
| `?t` where a String is expected | `?t[..]` of a Text |
| `xs.len`, `s.len`, `v.len` | a length, a field |
| `mod.name`, `mod.Type.name` | a module's declaration or a type's member |

A lend of a place is never the base of a path: `(!p).x`, `(?xs)[0]`,
and `(<(!p)).x` are rejected, and written `p.x` where the path is read
or assigned, and `!p.x` or `?xs[0]` where it is lent
([SPEC](SPEC.md#lending)). A
method's receiver, `(!s).insert(k)`, a value that branches,
`(!a if c else !b).x`, and a lend of a slice, `(?t[..])[0]`, are not
this rule's.

### Compile-time arguments

`x[...]` after `x` indexes, unless `x` names a generic type or a
function: then the brackets hold compile-time arguments. What the name
denotes decides, whether it is named directly, through a module
(`lib.scaled[3]`), through a type (`Scale.unit[6]()`), or as a method
(`s.times[5]()`). A bracket list of two or more is never an index, and
empty brackets are rejected.

A type argument in an expression is written as a type that is also an
expression: a name, `mod.Type`, `*T`, `~T`, `?T`, `!T`, `T?`, an
instance, or `*T?` (an optional handle, as in a type). A slice, array,
or function type, and a handle to an optional (`*(T?)`), have no such
spelling: name them with a `type` alias, or write the type where the
value goes.

```rig
struct Wrap[T]
  v: T

type Row = [3]Int

fun double(n: Int) -> Int
  n * 2

sub show[n: Int]()
  print(n)

sub main()
  xs = [10, 20, 30]
  ops = [double, double]
  v = Vec[Int]()
  !v.push(xs[2])
  show[2]()
  a = Wrap[Row](v: [1, 2, 3])
  b: Wrap[[3]Int] = Wrap(v: [4, 5, 6])
  print(xs[1], ops[0](4), v[0], a.v[2], b.v)
```

```output
2
20 8 30 3 [4, 5, 6]
```

```rig reject
struct Pair[T, U]
  a: T
  b: U

fun plain(n: Int) -> Int
  n

sub main()
  n = 5
  print(n[Int, Int])
  p = Pair[Int](a: 1, b: 2)
  print(plain[3](4))
```

```error
an index is one value with no trailing comma; a list in brackets gives compile-time arguments
generic type `Pair` expects 2 type arguments, got 1
`plain` takes no compile-time arguments
```

```rig reject
sub main()
  v = Vec[[]Int]()
```

```error
a slice or array type has no expression spelling
```

```rig
struct Node
  value: Int

type Held = *(Node?)

sub main()
  a = Cell[*Node?](none)
  b = Cell[Held](*none)
  print(a.replace(none) == none)
  old = b.replace(*none)
  <old
```

```output
true
```

```rig reject
struct Node
  value: Int

sub main()
  b = Cell[*(Node?)](*none)
```

```error
a handle to an optional has no expression spelling
```

### Ownership sigils

Each ownership effect is a prefix sigil on the value it acts on, and
the same sigil means the same thing in every position:

| Position | Read | Write | Move | Clone | Weak |
|---|---|---|---|---|---|
| expression | `?x` | `!x` | `<x` | `+x` | `~x` |
| type | `?T` | `!T` | | | `~T` |
| receiver | `?self` | `!self` | `<self` | | |
| method call | `p.m()` | `!p.m()` | `<p.m()` | | |
| `for` source | `for x in v` | `for x in !v` | `for x in <v` | | |
| `match` subject | `match e` | `match !e` | `match <e` | | |
| closure capture | `\|?x\|` | `\|!x\|` | `\|<x\|` | `\|+x\|` | `\|~x\|` |
| assignment | | | `a = <b` | | |
| statement (drop now) | | | `<x` | | |

`*x` moves a value into a new shared handle (`*<x` for a named owning
value, `*Point(x: 1)` for a new one). `<x` alone on a line drops `x`
now; where a value is expected, it moves it there. A sigil may reach
into a place: `+p.a` clones the handle in a field, `<p.f` takes an optional
field, and `?xs[0]` lends an element. [SPEC §7](SPEC.md#7-ownership)
says what each does.

### Closures

A closure is a bar list and a body, with no keyword. The bar list holds
the **captures**, each with a sigil, then the **parameters**, bare
names with optional types:

| Entry | Meaning |
|---|---|
| `+x` | capture a copy of plain data, or a clone of a handle |
| `<x` | move `x` in |
| `?x`, `!x` | lend `x` to read or write |
| `~x` | hold a shared handle weakly |
| `a`, `a: Int` | a parameter |
| `\|\|` | an empty list |

A name with a sigil is a capture and a bare name a parameter. Captures
come before parameters, and a parameter may not reuse a local's name,
so the spelling alone decides what an entry is:

```rig reject
sub main()
  n = 10
  add = |n| n + 1
  print(add(1))
```

```error
closure parameter `n` has the name of the local `n`; to capture the local, give it a sigil (`|+n|` copies or clones it, `|<n|` moves it, `|?n|` or `|!n|` lends it, `|~n|` holds it weakly), or name the parameter differently
```

The body is an expression or an assignment on the same line
(`|!total, n| total += n`), or an indented block. `*` before the bar
list makes an owned closure: `*|+count, step| ...`.

```rig
sub main()
  n = 10
  cell: *Cell[Int] = *Cell(0)
  add_n = |+n, a: Int| a + n
  bump = |+cell| cell.set(cell.get() + 1)
  hello = || print("hello")
  hello()
  bump()
  bump()
  print(add_n(5), cell.get())
  clamp = |x: Int|
    return 100 if x > 100
    x
  print(clamp(700), clamp(7))
```

```output
hello
15 2
100 7
```

A parameter's type, and the result's, may come from context;
[SPEC §11](SPEC.md#11-closures) has the rules.

### Optionals and errors

| Form | Meaning |
|---|---|
| `a ?? b` | the value in `a`, or `b` when `a` is `none` |
| `a ?? return v`, `a ?? break`, `a ?? continue :outer` | the value in `a`, or leave |
| `a?` | the value in `a`, or return `none` from the function |
| `f()!` | the value of `f()`, or propagate its failure |
| `f() catch v` | the value of `f()`, or `v` when it fails |
| `f() catch return -1`, `f() catch break` | the value, or leave |
| `f() catch \|err\| handler` | the handler names the error; it may be a block |
| `a == none` | a test for absence |

The suffix names the kind of early exit: `?` for `none`, `!` for a
failure, so a line shows which one it can take. Note the direction:
`?x` (prefix) lends, and `x?` (suffix) unwraps.

### Blocks as values

`if`, `match`, and a loop that breaks with a value are expressions
where their value is used: as a binding's value, a function's last
expression, or a `return` value. A `raw` block may yield a value too.

## 12. Patterns

| Pattern | Matches |
|---|---|
| `.name` | an enum variant, or an error value |
| `E.name`, `m.E.name` | a member of error set `E` (of module `m`); a variant of an enum is written `.name` |
| `.name(a, b)` | a payload variant, binding its fields in order |
| `.name(_, b)` | a payload variant, ignoring a field |
| `.name(f: a)` | a payload variant, binding the fields it names, in any order; the rest are not bound |
| `42`, `-1`, `true` | a literal |
| `lo..hi` | an integer from `lo` up to, not including, `hi` |
| `_` | everything else |
| any other name | everything else, bound to the name |
| `p, q` | any of the alternatives, which bind no names |
| `p if cond` | what `p` matches, when the guard `cond` holds |

A pattern is one of these, never a string or a float, and never a
module's constant (`lib.LIMIT`), which an arm compares with in a guard:
`x if x == lib.LIMIT =>`. A pattern binds a variant's fields either in
order, all of them, or by name, any of them: `.rect(w, h)` or
`.rect(h: tall)`, never `.rect(w, h: tall)`.

---

## Appendix: grammar summary

A condensed view of [rig.grammar](rig.grammar), the grammar the parser
is generated from. `[x]` is optional, `x*` repeats, `x, ...` is a
comma-separated list (which may end with a comma), `tail-closure` is a
closure whose body assigns, and `INDENT` / `DEDENT` are the block
structure. The checker narrows a few forms the grammar accepts: a `fun`
needs `->`, a `drop` body takes `!self`, a module-level binding
takes no `const`, and a label goes only on a loop, `match`, or `raw`
block. The grammar also parses a definition without its parameter list,
so that the rejection can show the header with it.

```text
program   = decl*
decl      = ["pub"] (fun | sub | struct | enum | errors | typedef | test | constant)
          | use | extern
use       = "use" ["std" "."] name ["as" name]
fun       = "fun" name [tparams] params "->" type [from] block
from      = "from" (name, ... | "static")
sub       = "sub" name [tparams] params ["!"] block
tparams   = "[" (name | name ":" type), ... "]"    # a type, or a compile-time value
params    = "(" [param, ...] ")"
param     = name [":" type ["=" expr]] | ("?" | "!" | "<") "self"
struct    = "struct" name [tparams] ["unique"] INDENT member* DEDENT
enum      = "enum" name [tparams] INDENT member* DEDENT
member    = ["pub"] (field | fun | sub) | variant | "drop" params block
field     = name ":" type ["=" expr]
variant   = name | name "=" expr | name params
errors    = "error" name INDENT name* DEDENT
typedef   = "type" name "=" type
constant  = name [":" type] "=" tail
test      = "test" string block
extern    = "extern" "fun" name params ["->" type [from]]
          | "extern" "sub" name params
          | "extern" name ":" type
          | "extern" "zig" string INDENT (["pub"] zdecl)* DEDENT
zdecl     = "fun" name [tparams] params ["->" type [from]]
          | "sub" name [tparams] params ["!"]

type      = ("?" | "!") type | ptype | tsuffix
ptype     = ("*" | "~")* ("[" [dim] "]" type
          | "fun" "(" [type, ...] ")" "->" type | "sub" "(" [type, ...] ")" ["!"])
tsuffix   = tsuffix ("?" | "!") | ("*" | "~")* tatom
tatom     = tname | tname "[" targ, ... "]" | "(" type ")"
tname     = name | name "." name
targ      = type | ["-"] integer | "(" integer ")" | cexp
dim       = ["-"] integer | "(" integer ")" | name | "(" name ")" | name "." name | cexp
cexp      = cunit (("+" | "-" | "*" | "/" | "%") cunit)+ | "(" cexp ")"
cunit     = integer | name | name "." name | "(" cexp ")"

block     = INDENT stmt* DEDENT
stmt      = decl | ":" name stmt | simple ["if" value]
simple    = tail | assign
          | name ":" type "=" tail | "const" name [":" type] "=" tail
          | "new" ["const"] name [":" type] "=" tail | "-" name | "pass"
          | "return" [tail] | "break" [":" name] [tail] | "continue" [":" name]
          | ("defer" | "errdefer") (simple | block) | "raw" block
assign    = postfix ("=" | "+=" | "-=" | "*=" | "/=" | "%=" | "+%=" | "-%="
                     | "*%=" | "&=" | "|=" | "^=" | "<<=" | ">>=") tail
tail      = expr | ["*"] bars assign                # a closure whose body assigns

expr      = value | if | while | for | match | closure
          | logic "catch" "|" name "|" block
if        = "if" value block ["else" (block | if)]
while     = "while" value [":" step] block ["else" block]
step      = assign | ["?" | "!" | "<"] postfix
for       = "for" name ["," name] "in" value block ["else" block]
match     = "match" value INDENT arm* DEDENT
arm       = pattern, ... ["if" value] ("=>" simple | block)
pattern   = patom [".." patom]
patom     = name | ["-"] integer | "true" | "false"
          | "." name ["(" [(name | name ":" name), ...] ")"]
          | [name "."] name "." name
closure   = ["*"] bars (expr | block)
bars      = "|" (name [":" type] | ("+" | "<" | "~" | "?" | "!") name), ... "|" | "||"

value     = logic "if" logic "else" value
          | logic "catch" ["|" name "|"] (value | jump)
          | logic "??" jump | logic
jump      = "return" [value] | "break" [":" name] [value] | "continue" [":" name]
logic     = logic "or" conj | conj
conj      = conj "and" neg | neg
neg       = "not" neg | infix "as" name | infix
infix     = unary (op unary)*                       # the table in section 6
unary     = ("-" | "<" | "+" | "?" | "!" | "*" | "~") unary | postfix
postfix   = postfix ("." name | "[" expr "]" | "[" [expr] ".." [expr] "]"
          | "[" expr, expr, ... "]" | "(" args ")" | "!" | "?") | atom
args      = [(name ":" expr | expr), ...] | (name ":" expr | expr), ..., tail-closure
atom      = name | integer | float | string | "true" | "false" | "." name
          | "@" name "(" args ")" | "[" [expr, ...] "]" | "[" expr "of" expr "]"
          | "(" expr ")"
```

The grammar reads `!v.push(x)` as `!` applied to `v.push(x)`, like any
prefix; the compiler then moves a `?`, `!`, or `<` before a place and a
method call onto the place, giving the tree of `(!v).push(x)`
([§5](#receiver-sigils)). A `x[...]` with one expression in it is an
index or compile-time arguments by what `x` names
([§11](#compile-time-arguments)).
