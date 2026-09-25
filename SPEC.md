# The Rig Language Reference

This is the reference for Rig as the compiler implements it today. Every
rule here is enforced by `rig check`, and every example is run by
`./test/run`: a program followed by an `output` block must print exactly
that output with no leaks, and a program marked as rejected must fail
with the error shown. For the reasons behind the rules, see
[docs/DESIGN.md](docs/DESIGN.md); for what is not built yet, see
[docs/ROADMAP.md](docs/ROADMAP.md).

```rig
sub main()
  print("hello, rig")
```

```output
hello, rig
```

## Contents

1. [Programs](#1-programs)
2. [Lexical structure](#2-lexical-structure)
3. [Types](#3-types)
4. [Declarations](#4-declarations)
5. [Bindings and assignment](#5-bindings-and-assignment)
6. [Expressions](#6-expressions)
7. [Control flow](#7-control-flow)
8. [Ownership](#8-ownership)
9. [Drop and drop glue](#9-drop-and-drop-glue)
10. [Shared and weak handles](#10-shared-and-weak-handles)
11. [Cell, Vec, and Signal](#11-cell-vec-and-signal)
12. [Closures](#12-closures)
13. [Optionals](#13-optionals)
14. [Errors](#14-errors)
15. [Modules](#15-modules)
16. [Raw code and FFI](#16-raw-code-and-ffi)
17. [Compile-time parameters](#17-compile-time-parameters)
18. [Printing](#18-printing)
19. [Reserved and unsupported forms](#19-reserved-and-unsupported-forms)

---

## 1. Programs

A Rig program is a file of declarations: functions (`fun`, `sub`),
types (`struct`, `enum`, `error`, `type`), constants (`name =! value`),
imports (`use`), `extern` declarations, and `test` blocks. Statements
live inside functions. The file's name ends in `.rig`, and a program
that runs declares its entry point as `sub main()`, with no parameters.
Only the program calls it: Rig code cannot call `main` or use it as a
value.
`rig check` checks a program, `rig run` checks, builds, and runs it,
and `rig --help` lists the other commands (see also the
[README](README.md#build-and-run)).

`rig run` builds in Debug mode with a leak-checking allocator: a program
that leaks memory reports it and exits with an error. `--release` builds
with Zig's ReleaseSafe, and `--release=fast` with ReleaseFast. Integer
overflow, out-of-bounds indexing and slicing, and a numeric conversion
whose value does not fit panic in Debug and ReleaseSafe builds.
ReleaseFast is the one mode outside that guarantee: it drops the
overflow and conversion checks, so there an overflow or an out-of-range
conversion is undefined behavior. Indexing and slicing stay checked in
every mode.

---

## 2. Lexical structure

### Source text

A source file is UTF-8 text. Lines end in `\n` or `\r\n`; a carriage
return without a line feed is an error. A byte order mark at the start
of the file is skipped.

### Comments

A comment runs from `#` to the end of the line.

### Indentation

Blocks are marked by indentation, with spaces only. A line indented
deeper than the one before it opens a block; coming back to an
enclosing line's indentation closes it. A tab in indentation is an
error, and so is a dedent to a column that matches no enclosing block.

```rig reject
sub main()
	print(1)
```

```error
tab in indentation; indent with spaces
```

### Line joining

Inside `( )` and `[ ]` a newline is plain whitespace, so arguments,
expressions, and method chains can span lines at any indentation. An
array, a call's arguments, a parameter list, a closure's bar list, and a
variant pattern's bindings may end with a comma. A
backslash at the end of a line joins the next line anywhere.

```rig
fun add3(a: Int, b: Int, c: Int) -> Int
  a + b + c

sub main()
  total = add3(
    1,
    2,
    3
  )
  more = (total +
      10)
  last = 1 + \
    2
  print(total, more, last)
```

```output
6 16 3
```

The one exception is a closure whose bar list ends a line inside
brackets: its body below is laid out in blocks as usual
([§12](#multi-line-closure-bodies)).

### Keywords

These words are reserved and cannot name anything:

```text
and  as  break  catch  continue  defer  drop  else  enum  errdefer
error  extern  false  for  fun  if  in  match  not  or  pre  pub  raw
return  struct  sub  test  true  try  type  use  while  zig
```

`new` is a keyword only at the start of a statement (`new x = ...`), so
a method may be named `new`. `none` is a reserved name for the absent
optional. Words that are keywords in Zig but not in Rig (`var`, `fn`,
`const`) are ordinary names.

```rig reject
fun f(in: Int) -> Int
  in
```

```error
unexpected keyword `in`
```

### Literals

| Literal | Examples | Notes |
|---|---|---|
| Integer | `42`, `1_000`, `0xff`, `0b1010`, `0o17` | `_` may separate digits; radix prefixes are lowercase; no leading zeros or suffixes |
| Float | `3.14`, `1.0e10`, `2e-3`, `1.5E+2` | a digit sequence with a `.` or an exponent |
| String | `"tab\tnewline\n"`, `'it''s'` | double quotes take Zig escapes (`\n`, `\t`, `\\`, `\"`, `\x41`, `\u{e9}`); single quotes take none, and `''` is one `'`; neither holds a control character (a raw tab or newline) |
| Bool | `true`, `false` | |
| Absent optional | `none` | see [§13](#13-optionals) |
| Array | `[1, 2, 3]` | see [§3](#arrays) |
| Enum variant | `.red`, `.circle(radius: 2)` | typed by context |

There is no string interpolation; `print` takes several values instead.

```rig
sub main()
  print(0xff, 0b101, 0o17, 1.5E+2, 2e-3)
  print('single: "no escapes\n"', "double: 'x'\ty")
```

```output
255 5 15 150.0 0.002
single: "no escapes\n" double: 'x'	y
```

### The spacing rule

Several characters are both operators and prefixes: `<` `+` `-` `*` `?`
`!` `~`. One rule decides which, and it also governs `(`, `[`, and `.`:

> A character that touches its operand and not the value before it is
> a prefix. Otherwise it is an infix operator, or it continues the value
> before it.

| Source | Reads as |
|---|---|
| `a < b`, `a<b` | comparison |
| `f <x` | `f(<x)`: a paren-free call passing `x` moved |
| `a - b`, `a-b` | subtraction |
| `f -x` | `f(-x)` |
| `f(x)`, `a[i]`, `a.b` | call, index, member access |
| `f (x)`, `f [1, 2]`, `f .red` | paren-free call with the argument `(x)`, `[1, 2]`, `.red` |
| `f()!`, `x?` | propagate a failure ([§14](#14-errors)) or `none` ([§13](#13-optionals)) |
| `-x` alone on a line | drops `x` ([§8](#drop)), except where the line's value is used |

Two values may not touch with no operator between them: `t.5` and
`print"hi"` are rejected, since neither is a call. Nor may `=!` and
`<-` touch the operand after them (`x =!y`, `a <-b`), which could as
well be `x = !y` and `a < -b`.

The rule is uniform, so it has one sharp edge worth knowing: `a -1`
calls `a` with `-1`.

```rig reject
sub main()
  a = 5
  b = a -1
```

```error
`a` has type `Int` and cannot be called
```

---

## 3. Types

### Primitive types

| Type | Meaning | Zig |
|---|---|---|
| `Int` | 64-bit signed integer, the same type as `I64`; the type of integer literals by default | `i64` |
| `Float` | 64-bit float, the same type as `F64`; the type of float literals by default | `f64` |
| `I8` `I16` `I32` `I64` | signed integers | `i8` ... `i64` |
| `U8` `U16` `U32` `U64` | unsigned integers | `u8` ... `u64` |
| `F32` `F64` | floats | `f32`, `f64` |
| `Bool` | `true` or `false` | `bool` |
| `String` | immutable UTF-8 bytes; a Copy value | `[]const u8` |
| `Void` | no value (what a `sub` returns) | `void` |

`Int` is `I64` and `Float` is `F64`: one type under two names. Every
other numeric type is distinct, and there are no implicit conversions.
A literal takes the numeric type its context expects, and must fit it
(a float literal, its range).
Constant arithmetic is checked at compile time.

```rig
sub main()
  small: U8 = 200
  sum = small + 55          # 55 is a U8 here
  big = 9223372036854775807
  print(sum, big, @sizeOf(Int), 0.1 + 0.2)
```

```output
255 9223372036854775807 8 0.30000000000000004
```

```rig reject
sub main()
  a: U8 = 250
  b = a + 10
```

```error
`260` does not fit in `U8`
```

```rig reject
sub main()
  a: I32 = 1
  b: I64 = 2
  print(a + b)
```

```error
operands have different types `I32` and `Int`
```

### Numeric conversions

A numeric type's name converts a number to that type: `I32(x)`,
`U8(x)`, `Float(n)`, `Int(f)`. A conversion is checked. An integer that
does not fit the target type panics when the program runs, and so does
a float whose integer part does not fit; a float becomes an integer by
truncating toward zero, and `F32(x)` rounds (to an infinity when `x` is
too large). A constant integer is converted at compile time, so it
must fit. (Inside `raw`, Zig's unchecked cast builtins are also
available, [§16](#16-raw-code-and-ffi).)

```rig
fun average(total: Int, count: Int) -> Float
  Float(total) / Float(count)

sub main()
  big = 300
  print(U8(big - 100), Int(-7.9), average(7, 2), I32(U8(255)) + 1)
```

```output
200 -7 3.5 256
```

```rig reject
sub main()
  b = U8(256)
```

```error
integer value `256` does not fit in `U8`
```

A `String` has a length `s.len` and can be indexed (`s[0]`), and a `for`
loop over it yields its bytes as `U8`. Strings compare with `==` and
`!=`; they have no ordering.

### Arrays

`[N]T` is a fixed-size array. An array literal `[a, b, c]` takes its
element type from its elements (or from an annotation), `xs.len` is its
length, and `xs[i]` reads or writes an element; an index outside the
half-open range `0..xs.len` panics. Arrays hold plain data only; a
collection of resources is a `Vec`.

```rig
sub main()
  xs = [10, 20, 30]
  xs[0] = 5
  ys: [2]U8 = [1, 2]
  print(xs, xs.len, xs[2], ys)
```

```output
[5, 20, 30] 3 30 [1, 2]
```

### Slices

`xs[a..b]` is the part of `xs` from index `a` up to, not including,
`b`. Of a `String` it is a `String`. Of an array or a `Vec` of plain
data it is written `?xs[a..b]`: a `[]T`, a read-only view that borrows
`xs` like any `?` borrow ([§8](#8-ownership)), so `xs` cannot be
written, moved, or dropped while the slice is in use, and the slice
cannot outlive it. A `[]T` has `.len`, is indexed and iterated like an
array, and is sliced again with `s[a..b]`, which views the same
elements. The bounds must satisfy `0 <= a <= b <= len`; constant bounds
are checked at compile time, others when the slice is taken, which
panics when they do not.

```rig
fun total(xs: []Int) -> Int
  n = 0
  for x in xs
    n += x
  n

sub main()
  s = "hello, world"
  print(s[0..5], s[7..s.len])
  a = [1, 2, 3, 4]
  mid = ?a[1..3]
  print(mid, mid.len, mid[0], total(mid), total(?a[0..4]))
```

```output
hello world
[2, 3] 2 2 5 10
```

A borrowed array parameter (`xs: ?[N]T`) is the function's own copy of
the caller's array, so a slice of it cannot be returned; a function
that returns part of its argument takes `xs: []T`.

### Composite and handle types

| Type | Meaning | Section |
|---|---|---|
| `[]T` | slice: a read-only view of elements | [§3](#slices) |
| `T?` | optional: a `T` or `none` | [§13](#13-optionals) |
| `T!` | fallible: a `T` or an error; only as a return type, including a function type's | [§14](#14-errors) |
| `?T` | read borrow of a `T` (parameters, returns, locals, fields) | [§8](#8-ownership) |
| `!T` | write borrow of a `T` | [§8](#8-ownership) |
| `*T` | shared handle: reference-counted, single-threaded | [§10](#10-shared-and-weak-handles) |
| `~T` | weak handle to a shared value | [§10](#10-shared-and-weak-handles) |
| `fun(A, B) R`, `sub(A)` | function and closure types | [§12](#12-closures) |
| `*fun(A) R`, `*sub(A)` | owned closure (a shared handle) | [§12](#12-closures) |
| `Cell(T)`, `Vec(T)`, `Signal(T)` | built-in generic types | [§11](#11-cell-vec-and-signal) |
| `Name`, `Name(T)`, `mod.Name` | user types, generic instances, imported types | [§4](#4-declarations), [§15](#15-modules) |

Suffixes bind tighter than prefixes: `*User?` is a shared handle to an
optional `User`, and an optional shared handle is written `(*User)?`.
Prefixes compose right to left: `?*Box` is a read borrow of a shared
handle, and `*Cell(Vec(*sub()))` is a shared cell holding a list of
owned closures.

### Copy values and owning values

A **Copy** value is plain data: numbers, `Bool`, `String`, plain enums,
arrays of Copy values, and structs whose fields are all Copy. Using one
copies it.

An **owning** value holds a resource that must be released exactly
once: a `*T` or `~T` handle, a `Vec`, a `Signal`, an owned closure, and
any struct, enum, or generic instance that contains one or declares a
`drop` body. Owning values have **drop glue**: code the compiler
generates to release them. They move instead of copying, and the
ownership rules of [§8](#8-ownership) apply to them.

---

## 4. Declarations

### Functions

`fun` declares a function that returns a value; `sub` declares one that
does not. The return type follows `->`. A function's value is its last
expression, or the value of a `return`.

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

Parameters are immutable, except a write-borrowed `!T` parameter, which
can be assigned ([§8](#write-borrows)). A parameter the body ignores
may be named `_`, any number of times. A parameter may have a default
value, which must be a literal; arguments can be passed by keyword, in
any order, and are evaluated in the order written.

```rig
fun scaled(n: Int, by: Int = 10, _: Bool = false) -> Int
  n * by

sub main()
  print(scaled(3), scaled(3, 2), scaled(by: 4, n: 5))
```

```output
30 6 20
```

A function name is a value of its function type, so it can be passed
where a `fun(...)` or `sub(...)` is expected ([§12](#function-types)).

Declarations are only allowed at module level; there are no nested
functions (use a closure). Two module-level declarations may not share a
name.

### Structs

A `struct` lists its fields, then its methods. It is constructed by
naming its fields: `Point(x: 1, y: 2)`. A field may have a default
value, which, like a parameter default, must be a literal (a number, a
string, `true` / `false`, `none`, or `.variant`); a constructor may omit
that field.

```rig
struct Config
  retries: Int = 3
  name: String = "anon"
  verbose: Bool

sub main()
  c = Config(verbose: true)
  d = Config(retries: 5, verbose: false)
  print(c.retries, c.name, d.retries)
```

```output
3 anon 5
```

```rig
struct Point
  x: Int
  y: Int

  fun origin() -> Self
    Point(x: 0, y: 0)

  fun plus(?self, other: ?Point) -> Point
    Point(x: self.x + other.x, y: self.y + other.y)

  sub shift(!self, dx: Int)
    self.x += dx

sub main()
  p = Point.origin()
  q = Point(x: 1, y: 2)
  r = p.plus(?q)
  (!r).shift(10)
  print(r, r.x)
```

```output
Point(x: 11, y: 2) 11
```

A method whose first parameter is `self` is an instance method;
without one it is an associated function, called through the type
(`Point.origin()`). `Self` names the enclosing type. The receiver says
how the method uses the value, and the call site says the same thing:

| Receiver | Meaning | Call |
|---|---|---|
| `?self` (= `self: ?Self`) | reads the value | `p.m()`: the read borrow is implicit |
| `!self` (= `self: !Self`) | modifies the value | `(!p).m()` |
| `self: Self` | consumes the value | `(<p).m()`, or on a temporary |

Write borrows and moves are never implicit, so calling a `!self` method
as `p.m()` on an owned `p` is an error. A binding that already holds a
write borrow (a `!T` parameter, `self` in a `!self` method, a local
`w = !p`) calls it directly, `w.m()`: the borrow it holds is lent to the
call.

```rig
struct Counter
  n: Int

  sub bump(!self)
    self.n += 1

  sub bump_twice(!self)
    self.bump()
    self.bump()

sub add_three(c: !Counter)
  c.bump()
  c.bump_twice()

sub main()
  c = Counter(n: 0)
  add_three(!c)
  (!c).bump()
  print(c.n)
```

```output
4
```

Inside a `!self` method, `self.field = v` and
`self = v` write through to the caller's value. The sigil shorthand
`?self` / `!self` is only for `self`; other parameters put the sigil on
the type (`other: ?Point`).

A method named through its type, `Type.method`, is a function value
whose first parameter is the receiver, as the method declares it:
`Counter.bump` has type `sub(!Counter)`. Named through a value, `c.bump`
must be called, since a value would have to capture its receiver
unseen; write a closure instead. Methods of generic types cannot be
named as values.

```rig
struct Counter
  n: Int

  sub bump(!self)
    self.n += 1

  fun get(?self) -> Int
    self.n

sub twice(f: sub(!Counter), c: !Counter)
  f(c)
  f(c)

sub main()
  c = Counter(n: 0)
  twice(Counter.bump, !c)
  get = Counter.get
  print(get(?c))
```

```output
2
```

### Enums

An `enum` lists variants. A variant may carry an explicit integer value
or payload fields, and an enum may have methods. A variant is written
`.name` where the enum type is known, or `Type.name`.

```rig
enum Shape
  circle(radius: Int)
  rect(w: Int, h: Int)
  point

  fun area(?self) -> Int
    match self
      .circle(r) => 3 * r * r
      .rect(w, h) => w * h
      .point => 0

enum Status
  ok = 200
  missing = 404

sub main()
  s: Shape = .rect(w: 2, h: 5)
  c: Shape = Shape.point
  print(s.area(), c.area(), s)
  st: Status = .missing
  print(st == .missing)
```

```output
10 0 .rect(w: 2, h: 5)
true
```

A payload variant is constructed with keyword fields
(`.circle(radius: 2)`) or positionally, in field order (`.circle(2)`). Enums have no constructor call (`Shape(...)` is an
error); plain enums compare with `==`. A plain enum's variants may take
explicit values (`ok = 200`): constant integers from 0 to 4294967295,
no two the same, where a variant without one takes the value after the
previous variant's. Payload and generic enums take no values.

### Error sets

`error Name` declares a set of error values, which are used like the
variants of a plain enum ([§14](#14-errors)).

```rig
error NetworkError
  timeout
  refused

sub main()
  e: NetworkError = .timeout
  match e
    .timeout => print("timed out")
    .refused => print("refused")
```

```output
timed out
```

### Generic types

`type Name(T, ...)` declares a generic struct and `enum Name(T, ...)` a
generic enum. An instance names its type arguments (`Box(Int)`). A
constructor takes them from the expected type when there is one, and
otherwise infers them from the values that fill it: a constructor's
fields (`Pair(first: 1, second: "x")` is a `Pair(Int, String)`), a
payload variant's fields (`Option.some(value: 7)`), or an associated
function's arguments (`Pair.make(1, 2)`). A literal takes its default
type. A parameter nothing fills, as in `Vec()`, needs the annotation. A
generic body may only do with a `T` what every instantiation allows:
operations on `T` are checked for each instantiation, inferred or
spelled, and methods cannot be called on a type parameter. A generic
type may hold `Vec(T)`, `Cell(T)`, `Signal(T)`, or `[N]T`; their element
rules apply to each instance. A generic parameter needs a name of its
own: not a built-in type or `Self`, a module-level declaration, or a
method of the type, and locals and parameters inside the type cannot
reuse it.

```rig
type Pair(T, U)
  first: T
  second: U

  fun left(?self) -> T
    self.first

enum Option(T)
  some(value: T)
  nothing

sub main()
  p = Pair(first: 42, second: "answer")
  o: Option(Int) = .some(value: p.left())
  match o
    .some(v) => print(v, p.second)
    .nothing => print("none")
  q = Option.some(value: 2.5)
  print(q)
```

```output
42 answer
.some(2.5)
```

There are no generic functions yet.

### Type aliases

`type Name = T` gives a type a second name. An alias is transparent: it
is the same type as `T`.

```rig
type UserId = Int

fun next(id: UserId) -> Int
  id + 1

sub main()
  x: UserId = 5
  print(next(x))
```

```output
6
```

An alias of a struct or enum declared in the same module is that type
in every role: it constructs values, calls associated functions, and
names variants.

```rig
struct Point
  x: Int
  y: Int

  fun origin() -> Point
    Point(x: 0, y: 0)

enum Color
  red
  green

type P = Point
type C = Color

sub main()
  p = P(x: 3, y: 4)
  o = P.origin()
  c = C.green
  print(p.x + o.x, c == .green)
```

```output
3 true
```

### Tests

`test "name"` (or `test 'name'`) declares a block that is checked like
a function body that may fail: `f()!` in a test fails the test with
that error. `rig test file.rig` runs every test block of the file and
of the modules it imports: it prints
`ok    test "name"` for each one that finishes, or
`FAIL  test "name": ...` with the reason, and then `N passed, M failed`.
`rig run` ignores test blocks.

```rig
fun area(w: Int, h: Int) -> Int
  w * h

test "area"
  print(area(2, 3))
```

### Constants

A binding at module level is a constant, `name =! value` or
`name: T =! value`, and `pub` exports it. Its value must be known at
compile time: a literal, `.variant`, an earlier constant, or operators
and array literals over them. Every function in the module reads it,
wherever it is declared; nothing can reassign or move it, and a local
or parameter may not reuse its name (`new` shadows it on purpose).
Arithmetic on constants alone is checked at compile time; with a value
known only when the program runs, it is checked then, like any other.

```rig
limit =! 10
half =! limit / 2
names =! ["low", "high"]

fun over(n: Int) -> Bool
  n > limit

sub main()
  print(limit, half, names[1], over(12))
```

```output
10 5 high true
```

A plain `name = value` at module level is rejected: there are no
mutable module-level variables.

### Other declarations

`use` imports a module ([§15](#15-modules)), `pub` exports a
declaration ([§15](#15-modules)), and `extern` declares a C symbol
([§16](#16-raw-code-and-ffi)).

---

## 5. Bindings and assignment

| Form | Meaning |
|---|---|
| `x = e` | bind a new local `x`, or assign to the visible `x` |
| `x: T = e` | bind with a type annotation |
| `x =! e`, `x: T =! e` | bind a fixed local, which cannot be reassigned |
| `new x = e` | bind a new `x` that shadows the visible one; `e` may read the old `x` |
| `x <- y` | move-assign: `x = <y` |
| `x += e` (`-=` `*=` `/=` `%=` `<<=` `>>=` `&=` `\|=` `^=`) | compound assignment: `x = x op e`, with `x` evaluated once |
| `p.f = e`, `xs[i] = e` | assign a field or an element |
| `_ = e` | evaluate `e` and discard it; an owning value is dropped at once |

A compound assignment keeps its target's type: an arithmetic operator
needs a number, a bitwise operator or shift an integer, and a shift
amount may be any integer. Each behaves like its operator
([§6](#operators)): `/=` truncates, `%=` takes the dividend's sign, and
`<<=` panics when bits are lost.

```rig
sub main()
  x = 100
  x %= 7
  x <<= 3
  x ^= 5
  print(x)
```

```output
21
```

A binding's type comes from its annotation or its value. Rig has no
`var`, `let`, or `const`: the compiler emits a Zig `const` unless the
binding is reassigned or written through.

There is no implicit shadowing. A local may not reuse the name of a
visible local, parameter, or module-level declaration, and `x =! e`
always declares. To reuse a name on purpose, write `new`:

```rig
sub main()
  x = 1
  new x = x + 10
  new x = "now a string"
  print(x)
```

```output
now a string
```

```rig reject
fun total() -> Int
  0

sub main()
  total = 5
```

```error
local `total` has the same name as the module-level declaration `total`
```

A binding cannot refer to itself in its own initializer. Parameters,
loop bindings, and names bound by patterns and `as` are immutable.

---

## 6. Expressions

### Operators

From lowest to highest precedence:

| Operators | Notes |
|---|---|
| `a if c else b`, `e catch f` | ternary and error fallback; right-nested |
| `or` | Bool; short-circuit |
| `and` | Bool; short-circuit |
| `not` | Bool |
| `==` `!=` `<` `>` `<=` `>=` | not chainable |
| `??` | optional fallback; right-associative |
| `..` | half-open range: a `for` source or a match pattern |
| `\|` | bitwise or |
| `^` | bitwise xor |
| `&` | bitwise and |
| `<<` `>>` | shifts |
| `+` `-` | |
| `*` `/` `%` | |
| `-x` and the ownership sigils | prefix |
| `f(x)` `a[i]` `a.b` `e!` | postfix: call, index, member, propagate |

Arithmetic needs numeric operands of one type (a literal adapts to the
other operand). Integer `/` truncates toward zero and `%` takes the sign
of the dividend, so `(a / b) * b + a % b == a`. Integer literals in
float arithmetic are floats, so `h: Float = 7 / 2` is `3.5`. In
arithmetic over a type parameter `T` they take `T`'s type in each
instance: `self.v + 1 / 2` adds `0.5` when `T` is `Float` and `0` when
it is `Int`. Unsigned values cannot be negated. Bitwise operators need integers; a shift amount may be any
integer, from 0 up to the width of the shifted type. A left shift that
loses bits (or the sign) overflows: a constant one is rejected, and one
computed when the program runs panics, like `+` and `*`.

`==` and `!=` compare two values of the same type: numbers, `Bool`,
`String` (by content), and enums (with each other or with a `.variant`),
and optionals of these, where `none` equals only `none`. Structs have
no `==`. Ordering comparisons need numbers.

`and`, `or`, and `not` take `Bool`s; `not` binds looser than comparisons,
so `not a == b` is `not (a == b)`. The spellings `&&` and `||` are
rejected with a hint.

```rig
sub main()
  a = 7
  print(-7 / 2, -7 % 2, a & 3, a << 2, a ^ 1)
  print(not a == 3, a > 3 and a < 10, false or true)
  print(1 if a > 5 else 2)
```

```output
-3 -1 3 28 6
true true true
1
```

```rig reject
sub main()
  a = true
  b = a && false
```

```error
`&&` is not a Rig operator; use `and`
```

### Calls

`f(a, b)` calls `f`. A **paren-free call** takes the rest of the line
as its arguments, and a nested paren-free call can be its last
argument: `print add 1, 2` is `print(add(1, 2))`. Paren-free calls read
well for simple statements; use parentheses when nesting.

```rig
fun add(a: Int, b: Int) -> Int
  a + b

sub main()
  print add 1, 2
  print (1 + 2) * 3
  print add(1, 2), add 3, 4
```

```output
3
9
3 7
```

Keyword arguments name parameters (`scaled(by: 4, n: 5)`), and
constructors always use them. Arity, keyword names, and argument types
are checked.

### Block expressions

`if` and `match` are expressions when their value is used: as a
function's last expression, a binding's value, or a `return` value.
Every branch must then produce a value of one type (a branch may also
leave with `return`), so an `if` needs an `else` and a `match` must
cover every value. The inline ternary `a if c else b` is the one-line
form.

```rig
fun classify(x: Int) -> String
  if x > 0
    "positive"
  else if x < 0
    "negative"
  else
    "zero"

sub main()
  n = 5
  label = if n > 3
    doubled = n * 2
    doubled + 1
  else
    0
  print(classify(-2), label)
```

```output
negative 11
```

`-x` as a whole line drops `x`, except where the line's value is used
(the last line of a `fun`, or of a branch whose value is used): there
it is negation.

### Builtins

`@name(args)` calls a Zig builtin. `@sizeOf`, `@alignOf`, `@TypeOf`,
and `@typeName` are safe anywhere; every other builtin needs a `raw`
block ([§16](#16-raw-code-and-ffi)). Rig type names are translated
(`@sizeOf(I64)` is 8).

---

## 7. Control flow

### if

```rig
sub main()
  x = 5
  if x > 10
    print("big")
  else if x > 3
    print("medium")
  else
    print("small")
```

```output
medium
```

Conditions must be `Bool`. `if e as name` tests an optional and binds
its value ([§13](#13-optionals)).

### Guards

A simple statement (a call, binding, `return`, `break`, or `continue`)
may end with `if cond`: it runs only when `cond` holds.

```rig
fun first_over(limit: Int) -> Int
  i = 0
  while i < 100
    i += 1
    break if i > limit
  return i

sub main()
  x = 5
  print(x) if x > 3
  print(first_over(3))
```

```output
5
4
```

A guard ends a statement; inside an expression, write the ternary
`a if c else b`.

### while

`while cond` repeats its block. `while cond : step` runs `step`, an
assignment or a call (which may propagate, `f()!`), after each
iteration (including after `continue`). `while e as x` repeats
while the optional `e` has a value. An `else` block runs when the loop
ends without `break`, after the loop: a `break` or `continue` in it
leaves the loop around this one. A loop can also yield a value
([Loops as values](#loops-as-values)).

```rig
sub main()
  i = 0
  while i < 3 : i += 1
    continue if i == 1
    print(i)
  else
    print("done")
```

```output
0
2
done
```

### for

`for x in source` walks an array, a `Vec` of Copy values, a `String`
(bytes), or a range `a..b` (from `a` up to, not including, `b`; the
bounds are evaluated once). `for x, i in xs` also binds the index (not
for ranges). An `else` block runs when the loop ends without `break`.
A `Vec` of owning values is walked with `for x in ?v` ([§11](#vec)).

```rig
sub find(xs: ?[4]Int, target: Int)
  for x, i in xs
    if x == target
      print("found at", i)
      break
  else
    print("not found")

sub main()
  total = 0
  for i in 0..5
    total += i
  print(total)
  xs = [3, 1, 4, 1]
  find(?xs, 4)
  find(?xs, 9)
```

```output
10
found at 2
not found
```

Loop bindings are immutable, and may not reuse a visible name. Two
source sigils change that:

- `for x in !xs` borrows each element of a `Vec` or array for writing:
  assigning `x` (or a field of it) writes the element in place, and a
  resource element that is replaced is dropped. `xs` must be a binding
  or a field of one.
- `for x in <v` consumes the Vec: each element is handed to `x`, which
  owns it for one iteration and may move it on. Elements a `break` or
  `return` leaves behind are dropped with the buffer, and `v` is moved.

```rig
struct B
  n: Int

  drop self: !B
    print("drop", self.n)

sub keep(b: *B)
  print("kept", b.n)

sub main()
  xs = [1, 2, 3]
  for x in !xs
    x *= 10
  print(xs)
  v: Vec(*B) = Vec()
  for i in 0..3
    (!v).push(*B(n: i))
  for b, i in <v
    if i == 1
      keep(<b)
      continue
    print("saw", b.n)
  print("after")
```

```output
[10, 20, 30]
saw 0
drop 0
kept 1
drop 1
saw 2
drop 2
after
```

### Labels, break, and continue

A loop may be labeled `:name`; `break :name` and `continue :name` then
refer to it from an inner loop. A `match` or `raw` statement may be
labeled too, and `break :name` leaves it. A label may repeat an
enclosing one's name; the innermost is meant.

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

A loop that `break` leaves with a value (`break v`, or `break :name v`
from an inner loop) is an expression. Its value is the value of the
`break` that leaves it, or, when the loop ends without one, the value
of its `else` block, which it therefore needs (only `while true` can do
without). Every `break` leaving it carries a value, and they and the
`else` value meet in one type. A `break` value is consumed like a
returned value: an owning binding is moved out with `<x`, and a borrow
may not outlive what it borrows. The value must be used; a `break`
cannot carry a value out of a loop whose value is not.

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

`match` selects the first arm whose pattern matches. It works on
enums, integers, and `Bool`.

| Pattern | Matches |
|---|---|
| `.name` | an enum variant |
| `.name(a, b)` | a payload variant, binding its fields in order |
| `42`, `-1`, `true` | a literal |
| `lo..hi` | an integer from `lo` up to, not including, `hi` (constant bounds) |
| `else`, `_`, or any other name | everything else |

An arm is `pattern => statement` or a pattern followed by an indented
block. A match whose value is used must cover every value; a statement
match need not, and then runs no arm for the rest. Duplicate and
unreachable arms are rejected. A range pattern is half-open like every
range, so `0..10` matches 0 through 9, and its end may be one past the
type's largest value: `100..256` covers the rest of a `U8`.

```rig
fun size(n: U8) -> String
  match n
    0..10 => "small"
    10..100 => "medium"
    100..256 => "large"

sub main()
  print(size(5), size(42), size(200))
  match 7
    1 => print("one")
    other => print("something else")
```

```output
small medium large
something else
```

### defer and errdefer

`defer stmt` (or `defer` with a block) runs when the enclosing block
exits, in reverse order of the defers. `errdefer` runs only when the
function exits with an error. A deferred body may not move or drop
outer bindings, or propagate with `!`. It runs after the values declared
after it are dropped, so it may not read one through a borrow.

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

---

## 8. Ownership

Every owning value has exactly one owner, and the owner decides when it
is released. The sigils make each ownership effect visible where it
happens:

| Sigil | Name | Effect |
|---|---|---|
| `<x` | move | ownership passes on; `x` is unusable until reassigned |
| `?x` | read borrow | a temporary read-only view; `x` keeps ownership |
| `!x` | write borrow | a temporary exclusive, writable view |
| `+x` | clone | a new owner: a refcount bump for a handle, a copy for a Copy value |
| `-x` | drop | release `x` now |
| `*x` | share | move `x` into a new shared box ([§10](#10-shared-and-weak-handles)) |
| `~x` | weak | a weak handle to a shared value ([§10](#10-shared-and-weak-handles)) |

A Copy value can be used freely: a bare use copies it. `<x` always
means "done with `x`", whatever its type: a Copy value or a borrow is
copied out, and `x` is unusable until it is assigned again. (`<p.f` of a
Copy field copies the field and leaves `p` whole.) The rest of this
section is about owning values.

```rig reject
sub main()
  n = 1
  m = <n
  print(n)
```

```error
use of `n` after move
```

### Moves

A value moves when it is passed to a parameter of owning type, bound to
another name, stored in a field, or returned. The move is written
`<x`; only a bare name returned directly (`return x`, or `x` as the
last expression) moves without it. After a move the name cannot be
used until it is reassigned.

```rig
struct Packet
  payload: Int

  drop self: !Packet
    print("released", self.payload)

sub send(p: Packet)
  print("sent", p.payload)

sub main()
  p = Packet(payload: 42)
  send(<p)
  p = Packet(payload: 7)     # reassigning makes `p` usable again
  print(p.payload)
```

```output
sent 42
released 42
7
released 7
```

```rig reject
struct Packet
  payload: Int

  drop self: !Packet
    print("released")

sub send(p: Packet)
  print(p.payload)

sub main()
  p = Packet(payload: 42)
  send(<p)
  print(p.payload)
```

```error
use of `p` after move
```

Writing a bare name where an owning value would be copied is an error,
because two owners would release it twice. Write `<x` to move it or
`+x` to clone it:

```rig reject
struct Box
  n: Int

sub main()
  a = *Box(n: 1)
  b = a
```

```error
bare use of shared (`*T`) handle `a` in binding would alias the handle
```

The checker follows every path. A value moved in one branch of an `if`
or `match` is moved after it; a value moved inside a loop is moved at
the top of the next iteration, unless the loop is left or the value is
reassigned first.

```rig reject
struct Box
  n: Int

sub eat(b: *Box)
  print(b.n)

sub main()
  b = *Box(n: 1)
  i = 0
  while i < 2 : i += 1
    eat(<b)
```

```error
use of `b` after move
```

Only whole bindings move. Moving a field out of a struct is rejected
(the struct would still drop it); clone a shared field with `+p.a`, or
move the struct as a whole. A Copy field can be read or copied freely.
A `match` payload binding views the matched value; moving it out
(`.full(b) => eat(<b)`) consumes the matched value, which must then be
an owned local whose variant has no other owning field.

### Borrows

A borrow lends a value without giving it up. `?x` is a read borrow and
`!x` a write borrow, and borrowed parameter types say the same thing:
`b: ?Box` reads, `b: !Box` writes. Every borrow is visible at the call
site.

```rig
struct Account
  balance: Int

fun balance_of(a: ?Account) -> Int
  a.balance

sub deposit(a: !Account, n: Int)
  a.balance += n

sub main()
  acct = Account(balance: 100)
  deposit(!acct, 50)
  print(balance_of(?acct))
```

```output
150
```

**The aliasing rule.** At any point a value may have any number of read
borrows or one write borrow, not both. While a read borrow is live the
owner cannot be written, moved, or dropped; while a write borrow is
live the owner cannot be used at all.

```rig reject
struct User
  name: String

sub main()
  u = User(name: "ada")
  r = ?u
  w = !u
  print(r.name)
```

```error
cannot write-borrow `u` while a read borrow is live
```

**How long a borrow lives.** A borrow passed to a call ends when the
call returns, so two calls in one statement may each write-borrow the
same value. A method call borrows its receiver for the whole call, so
`rc.show(<rc)` is rejected. A borrow stored in a binding, or in a view
([below](#second-class-borrows)), lasts until its last use. Every later
use counts: a use further on, a use anywhere in a loop around it that
the binding was declared outside of (the next iteration runs it again),
a closure that captured it (and every use of that closure), a binding
that borrows the view in turn, deferred code, and the drop at scope
exit of a value whose type has drop glue. The binding's block ending,
`-r`, or reassigning it also end the borrow.

```rig
struct Box
  n: Int

  sub bump(!self)
    self.n += 1

struct View
  box: ?Box

sub main()
  x = Box(n: 1)
  r = ?x
  print(r.n)
  (!x).bump()
  v = View(box: ?x)
  print(v.box.n)
  x = Box(n: 7)
  print(x.n)
```

```output
1
2
7
```

```rig reject
struct Box
  n: Int

  sub bump(!self)
    self.n += 1

sub main()
  x = Box(n: 1)
  r = ?x
  i = 0
  while i < 2 : i += 1
    print(r.n)
    (!x).bump()
```

```error
cannot write-borrow `x` while a read borrow is live
```

#### Write borrows

A `!T` parameter is assignable: `p.f = v` and `p = v` write through to
the caller's value (the old value is dropped first). A write borrow can
be passed on, or moved into a local with `<p`, but not copied. One held
in a field is read-only through a `?T` or `*T`, like the rest of what
that path reaches: it cannot be passed on from there, and a `match`
through one cannot bind it. A loop walks elements holding write borrows
with `for x in !xs`.

```rig
struct Counter
  hits: Int

sub bump(c: !Counter)
  c.hits += 1

sub reset(c: !Counter)
  c = Counter(hits: 0)

sub main()
  c = Counter(hits: 5)
  bump(!c)
  print(c.hits)
  reset(!c)
  print(c.hits)
```

```output
6
0
```

A `!x` borrow needs a binding that may change: a parameter (other than
`!T`), a fixed binding, a capture, or a loop binding cannot be
write-borrowed.

#### Second-class borrows

Borrows are values the checker follows, not types you annotate: there
is no lifetime syntax. A borrow can be held by a parameter, a local, a
struct field (a **view**), or a function's result, and the checker
tracks where every one came from.

- A function may return a borrow only of something its caller lent it.
  The result then borrows from every borrowed argument of the call.
- A struct holding a borrow keeps the borrowed value borrowed while the
  struct is alive. So does a stack closure that captured a borrow, and
  a value a call may have stored a borrow into (its receiver, and what
  its `!` arguments and other write borrows lead to).
- A borrow may not outlive the value it borrows: not past the end of
  its block, not through `break`, and not out of the function.

```rig
struct Box
  payload: Int

struct View
  box: ?Box

fun pick(a: ?Box, b: ?Box, first: Bool) -> ?Box
  if first
    a
  else
    b

sub main()
  x = Box(payload: 1)
  y = Box(payload: 2)
  r = pick(?x, ?y, false)
  v = View(box: ?x)
  print(r.payload, v.box.payload)
```

```output
2 1
```

```rig reject
struct User
  name: String

fun make() -> ?User
  u = User(name: "ada")
  ?u
```

```error
returned borrow of `u` does not originate from a borrowed parameter
```

```rig reject
struct Box
  payload: Int

  drop self: !Box
    print("drop")

fun first(a: ?Box, b: ?Box) -> ?Box
  a

sub main()
  x = Box(payload: 1)
  y = Box(payload: 2)
  r = first(?x, ?y)
  -y
  print(r.payload)
```

```error
cannot drop `y` while borrows are live
```

A borrowed parameter can be forwarded (`g(?b)` with `b: ?B`), and a
borrow of a Copy value reads as the value. The caller still owns a
borrowed value: a borrowed parameter cannot be dropped or move-captured,
and a field cannot be moved out of it.

### Clone

`+x` makes a new owner. For a shared or weak handle it bumps the
count; for a Copy value it copies. A struct with drop glue has no
clone. `+p.a` clones the handle in a field. A value holding a write
borrow cannot be cloned or weakly referenced: the borrow is unique.

### Drop

`-x` as a statement releases `x` now; afterwards `x` cannot be used.
Every owning local and parameter that is still live is dropped
automatically when its block ends, including on early `return`,
`break`, and `continue`, and on every path through branches. So `-x`
is only needed to release something early. A borrowed parameter cannot
be dropped: the caller owns it.

```rig
struct Noisy
  id: Int

  drop self: !Noisy
    print("drop", self.id)

sub run(early: Bool)
  a = Noisy(id: 1)
  b = Noisy(id: 2)
  if early
    -b
    print("dropped b early")
  print("end of run")

sub main()
  run(true)
  run(false)
```

```output
drop 2
dropped b early
end of run
drop 1
end of run
drop 2
drop 1
```

Automatic drops at the end of a block run in reverse order of
declaration. So a value whose drop runs a `drop` body may not borrow a
value declared after it: that value is dropped first.

### Temporaries

A value that owns a resource must have an owner. It may be bound,
returned, passed to a call (which takes ownership), discarded with
`_ = e` (which drops it), used as the receiver of a consuming method,
or compared with `none`. Anywhere else (a field read, a borrow, a
method receiver, a `print` argument, an expression statement) nothing
would release it, so it must be bound to a name first.

```rig reject
struct User
  age: Int

sub main()
  print((*User(age: 5)).age)
```

```error
bind it to a name first
```

---

## 9. Drop and drop glue

A struct may declare one `drop` body, which runs when a value of the
type is released. It takes exactly `self: !Self`.

```rig
struct File
  fd: Int

  drop self: !File
    print("closing", self.fd)

sub main()
  f = File(fd: 3)
  print("using", f.fd)
```

```output
using 3
closing 3
```

**Drop glue** is generated for every type that owns something: a
struct with a `drop` body or an owning field, an enum with an owning
payload, and a generic instance with an owning argument. Releasing a
value runs its `drop` body first, then releases its owning fields in
reverse declaration order, recursively. Glue does not depend on the
order of declarations in the file.

```rig
struct Noisy
  id: Int

  drop self: !Noisy
    print("noisy", self.id)

struct Pair
  a: *Noisy
  b: *Noisy

  drop self: !Pair
    print("pair")

sub main()
  p = Pair(a: *Noisy(id: 1), b: *Noisy(id: 2))
  print("built")
```

```output
built
pair
noisy 2
noisy 1
```

A drop body may read and assign fields, call methods on `self`
(including `!self` methods), and use `raw`. It may not move, drop, or
reassign `self` directly, since a replaced `self` would be dropped,
running the body again. A `!self` method that replaces its receiver
recurses the same way, as it would in Rust. No field can be moved out,
because the fields are released after the body returns.
`drop` bodies are only for structs; enums and generic types get
structural glue only.

---

## 10. Shared and weak handles

### Shared handles

`*T` is a shared handle: a reference-counted box holding a `T`,
single-threaded, like Rust's `Rc<T>`. `*expr` moves a value into a new
box; for a named owning value, write the move: `*<x`. `+h` makes
another handle to the same box, and the value is released when the last
strong handle goes.

```rig
struct User
  name: String

  drop self: !User
    print("released", self.name)

sub main()
  a = *User(name: "ada")
  b = +a
  -a
  print(b.name)
  print("end")
```

```output
ada
end
released ada
```

Releasing a long chain of handles, such as the head of a 200,000-node
list, does not exhaust the stack: past 256 nested releases, a release
is queued, and the queue runs, in the order the nested releases would
have, once the releases in progress finish.

Handles are owning values: a bare copy (`b = a`, `f(a)`) is rejected;
write `<a` or `+a`. Sharing a value that is already a shared handle
(`*a` with `a: *T`, or the type `*(*T)`) is rejected; clone it instead.

**Access is read-only.** Field reads and `?self` methods reach through
a handle automatically, including through fields and loop elements.
Writing a field, calling a `!self` method, or consuming the value
through a handle is rejected, because other handles share it; shared
mutable state goes in a `Cell` ([§11](#cell)). The built-in `Vec` is no
exception: `(!h).push(x)` through a `*Vec(T)` is rejected, and a shared
Vec is a `*Cell(Vec(T))`.

```rig reject
struct User
  age: Int

sub main()
  u = *User(age: 1)
  u.age = 2
```

```error
cannot assign through shared handle
```

### Weak handles

`~h` makes a weak handle `~T` from a shared one. A weak handle does not
keep the value alive. `w.upgrade()` returns an optional strong handle
`(*T)?`: a new owner while the value is alive, `none` after.

```rig
struct Node
  id: Int

  drop self: !Node
    print("drop", self.id)

sub show(w: ?~Node)
  if w.upgrade() as n
    print("alive", n.id)
  else
    print("gone")

sub main()
  rc = *Node(id: 7)
  w = ~rc
  show(?w)
  -rc
  show(?w)
```

```output
alive 7
drop 7
gone
```

### Cycles

A cycle of strong handles is never released: it leaks, as in Rust and
Swift. This is the one leak the compiler does not prevent. Break cycles
with weak handles: a child holds its parent weakly, and a callback
that refers back to its owner captures it weakly (`|~owner|`,
[§12](#captures)). Every test and example in this repository runs
leak-free under the checking allocator.

---

## 11. Cell, Vec, and Signal

These built-in generic types are part of the language's substrate.
Their names are reserved.

### Cell

`Cell(T)` holds one value that can be replaced through a read-only
path. It is the way to mutate shared state: `*Cell(T)` is a shared,
mutable value.

| Member | Meaning |
|---|---|
| `Cell(value: v)` | construct |
| `c.get()` | a copy of the value (Copy `T` only) |
| `c.value` | the same (Copy `T` only) |
| `c.set(v)` | store `v`; the old value is dropped |
| `c.replace(v)` | store `v` and return the old value |

`T` is a Copy primitive or an owning type. An owning value is never
copied out of a cell: it moves in with `set` / `replace` and moves out
with `replace`. What goes into a cell holds no borrow, since every
handle to the cell reaches it.

A Cell is interior-mutable: `set` and `replace` change it through any
path to it, including a read borrow (`?Cell(T)`), a `?self` method of a
struct holding one, and a shared handle. A by-value parameter is
immutable, and a loop or match binding is only a copy, so neither can
be changed (or lent to something that could change it).

```rig
struct Counter
  hits: Cell(Int)

  sub hit(?self)
    self.hits.set(self.hits.get() + 1)

sub bump(c: ?Cell(Int))
  c.set(c.get() + 10)

sub main()
  count: *Cell(Int) = *Cell(value: 0)
  other = +count
  other.set(other.get() + 5)
  local: Cell(Int) = Cell(value: 1)
  bump(?local)
  k = Counter(hits: Cell(value: 0))
  k.hit()
  k.hit()
  print(count.get(), local.get(), k.hits.get())

  shared: *Cell(Vec(Int)) = *Cell(value: Vec())
  v = shared.replace(Vec())
  (!v).push(7)
  shared.set(<v)
```

```output
5 11 2
```

### Vec

`Vec(T)` is a growable array that owns its elements. The binding is the
buffer: a `Vec` is an owning value even when its elements are Copy.
Elements are Copy primitives (numbers, `Bool`, `String`), plain data
(structs, enums, and optionals that own nothing and hold no borrow),
shared handles (including owned closures), or weak handles.

| Member | Meaning |
|---|---|
| `Vec()`, `Vec(capacity: n)` | an empty Vec (typed by context) |
| `(!v).push(x)` | append; an owning `x` is moved or cloned in |
| `v.length()` | the number of elements |
| `v[i]`, `v[i] = x` | read or write an element, or a field of one (Copy `T`; bounds-checked) |
| `v.get(i)` | the element as `T?` (Copy `T`) |
| `(!v).pop()` | remove the last element, as `T?`; a handle is handed over to the caller |
| `(!v).clear()` | drop every element |

A `for` loop borrows the Vec for the whole loop, so it cannot be
modified inside it. A Vec of Copy values may be walked by value
(`for x in v`). A Vec of owning values is walked by borrowed slot with
`for x in ?v`, where `v` must be a binding or a field of one: the
element can be read, called, and cloned (`+x` is a new handle), but not
moved, dropped, or stored. `for x in !v` and `for x in <v` write and
consume the elements ([§7](#for)).

```rig
sub main()
  total: *Cell(Int) = *Cell(value: 0)
  steps: Vec(*sub()) = Vec()
  (!steps).push(*|+total| total.set(total.get() + 1))
  (!steps).push(*|+total| total.set(total.get() + 10))
  for step in ?steps
    step()
  nums: Vec(Int) = Vec()
  (!nums).push(3)
  (!nums).push(4)
  while (!nums).pop() as n
    total.set(total.get() + n * 100)
  print(total.get(), steps.length())
```

```output
711 2
```

```rig
struct P
  x: Int
  y: Int

struct B
  n: Int

  drop self: !B
    print("drop", self.n)

sub main()
  ps: Vec(P) = Vec()
  (!ps).push(P(x: 1, y: 2))
  ps[0].y = 5
  print(ps[0], ps.length())
  bs: Vec(*B) = Vec()
  (!bs).push(*B(n: 1))
  (!bs).push(*B(n: 2))
  if (!bs).pop() as last
    print("popped", last.n)
  print("left", bs.length())
```

```output
P(x: 1, y: 5) 1
popped 2
drop 2
left 1
drop 1
```

### Signal

`Signal(T)` holds a Copy value and a list of subscribers, owned closures
of type `*sub()`. It lives behind a shared handle: a stack `Signal` is
rejected.

| Member | Meaning |
|---|---|
| `*Signal(value: v)` | construct |
| `s.get()` | the current value |
| `s.set(v)` | store `v`, then call every subscriber in subscription order |
| `s.subscribe(cb)` | take ownership of the handle `cb` (pass `+cb` to keep yours) |

A `set` from inside a subscriber is queued and delivered after the
current round, with the latest value winning. Subscribing from inside a
subscriber panics. A subscriber that reads its own signal must capture
it weakly, or the signal and its subscriber keep each other alive.

```rig
sub main()
  sig: *Signal(Int) = *Signal(value: 0)
  sig.subscribe(*|~sig|
    if sig.upgrade() as s
      print("now", s.get()))
  sig.set(7)
  sig.set(9)
```

```output
now 7
now 9
```

Signal is deliberately minimal: richer reactive libraries are built in
Rig from `Cell`, `Vec`, and owned closures (see
`examples/memo_canary.rig`).

---

## 12. Closures

### Bar lists

A closure starts with its bar list and has no keyword. The list holds
the closure's **captures** and its **parameters**, captures first:

- an entry with a sigil captures an outer local: `+x` copies a Copy
  value or clones a handle, `<x` moves the binding in, `~x` holds a
  shared handle weakly;
- a bare name is a parameter, optionally annotated (`a`, `a: Int`);
- `||` is an empty list.

The body is an expression on the same line or an indented block.

```rig
sub main()
  n = 10
  cell: *Cell(Int) = *Cell(value: 0)
  plus_n = |+n, a: Int| a + n
  bump = |+cell| cell.set(cell.get() + 1)
  hello = || print("hello")
  bump()
  bump()
  hello()
  print(plus_n(5), cell.get())
```

```output
hello
15 2
```

A closure reaches the enclosing function's locals only through its
captures. A bare entry that names a visible local is rejected, with the
sigils that would capture it, because the spelling alone decides what
an entry is:

```rig reject
sub main()
  n = 1
  f = |n| n + 1
```

```error
closure parameter `n` has the name of the local `n`
```

### Captures

| Capture | Outer value | Inside the closure |
|---|---|---|
| `\|+x\|` | Copy value | a copy |
| `\|+x\|` | `*T` or `~T` | a clone of the handle |
| `\|<x\|` | any | the value, moved in; the outer `x` is gone |
| `\|~x\|` | `*T` | a weak handle `~T` |

The closure's environment owns what it captured and releases it once,
when the closure is released, not after each call. The body may use,
call, and clone a captured owning value, but not move, drop, or
reassign it: the closure may be called again, so it cannot be the
closure's value either. A captured borrow may be passed to a call,
which borrows it for the call. A captured read borrow may be the
closure's value, and a call's result then borrows what the closure
captured. Through a captured write borrow the body can write fields and
call `!self` methods, but not write-borrow it again with `!w`. A name
may be captured once per list.

A closure nested in another captures from the scope where it is
created: the outer closure's captures, parameters, and locals. It may
copy or clone an outer capture (`|+x|`) or hold it weakly (`|~x|`), but
not move it (`|<x|`), since the outer closure may run again.

```rig
sub main()
  total: *Cell(Int) = *Cell(value: 0)
  add = |+total, k: Int|
    step = |+total, +k| total.set(total.get() + k)
    step()
    step()
  add(3)
  add(4)
  print(total.get())
```

```output
14
```

### Parameters and results

A bare parameter takes its type from the type the context expects: a
binding annotation, the parameter of the function being called, a
`Vec`'s element type, a struct field, or a function's return type. An
annotation is allowed anywhere and must agree with the context; with no
context, every parameter must be annotated. A closure takes exactly the
parameters its type passes, and may ignore one by naming it `_`.

With a type from context, the body is checked against its return type.
Otherwise the closure returns the type of its last expression, or of
its `return`s when it ends in one; a body ending in any other statement,
or in an `if` without `else`, returns nothing. `return` inside a closure
leaves the closure.

```rig
fun apply(f: fun(Int) Int, x: Int) -> Int
  f(x)

fun twice(n: Int) -> Int
  n * 2

sub main()
  add: fun(Int, Int) Int = |a, b| a + b
  clamp = |x: Int|
    return 100 if x > 100
    x
  print(add(2, 3), clamp(700), apply(twice, 4))
```

```output
5 100 8
```

### Function types

| Type | Meaning |
|---|---|
| `fun(Int, Int) Int` | takes two `Int`s, returns an `Int` |
| `sub(String)` | takes a `String`, returns nothing |
| `*fun(Int) Int`, `*sub()` | an owned closure of that shape |
| `~fun(Int) Int`, `~sub()` | a weak handle to an owned closure |

Function types describe closures bound to locals, function names used
as values, and `extern` function variables. Declarations write their
return type after `->`; type expressions do not. An owned closure is a
shared handle, so `~f` makes a weak handle to it, which upgrades like
any other ([§10](#weak-handles)).

```rig
sub main()
  f: *fun(Int) Int = *|a| a + 1
  w: ~fun(Int) Int = ~f
  if w.upgrade() as g
    print(g(1))
  -f
  print(w.upgrade() == none)
```

```output
2
true
```

### Stack closures

A closure literal without `*` lives in the stack frame of the function
that writes it, so it may not escape. It may only be bound to a local
(`f = |...| body`, then called as `f(...)`) or called where it is
written (`(|+n| print(n))()`). Anywhere else (an argument, a field, an
array element, a return value) it is rejected; make it owned instead. A
closure binding is fixed and cannot be copied, moved, or passed on.

```rig reject
fun make() -> fun() Int
  n = 1
  |+n| n
```

```error
closures cannot escape their defining scope
```

### Owned closures

`*` before the bar list makes an **owned closure**: its environment is
allocated on the heap behind a shared handle of type `*fun(...) R` or
`*sub(...)`, which can be stored, passed, returned, cloned (`+cb`),
held weakly, and dropped like any `*T`.

```rig
fun make_counter(start: Int) -> *fun(Int) Int
  count: *Cell(Int) = *Cell(value: start)
  *|+count, step|
    count.set(count.get() + step)
    count.get()

sub main()
  next = make_counter(100)
  print(next(1), next(10))
  handlers: Vec(*fun(Int) Int) = Vec()
  (!handlers).push(<next)
  (!handlers).push(*|x| x * 10)
  for h in ?handlers
    print(h(3))
```

```output
101 111
114
30
```

An owned closure is type-erased at run time, so its parameters and
result are plain Copy values: numbers, `Bool`, `String`, plain enums,
and optionals of these. Pass owning values in as captures. An owned
closure can be stored anywhere, so it cannot capture a borrow or a
value holding one; a stack closure can. `*` applies only to a closure
literal, not to a function name or a closure binding.

### Multi-line closure bodies

A closure's body may be an indented block wherever the closure is
written. When the bar list ends a line inside `( )`, the body below is
laid out in blocks as anywhere else; it ends where the bracket closes,
or where a line comes back to the indentation of the line the closure
started on. A paren-free call takes a trailing closure the same way.

```rig
sub each(n: Int, f: *sub(Int))
  for i in 0..n
    f(i)

sub main()
  total: *Cell(Int) = *Cell(value: 0)
  each(3, *|+total, i|
    total.set(total.get() + i)
    print("saw", i))
  each 2, *|i|
    print("trailing", i)
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

---

## 13. Optionals

`T?` holds a `T` or `none`. A plain `T` is accepted where a `T?` is
expected, and `none` needs a known optional type.

| Form | Meaning |
|---|---|
| `a ?? b` | the value inside `a`, or `b` when `a` is `none`; where a `T?` is expected, `b` may be a `T?` too (as may a `catch` handler) |
| `a == none`, `a != none` | test for absence |
| `a == v`, `a != v` | whether `a` holds the value `v`, a `T` |
| `if a as x` | run the block with `x` bound to the value inside `a`; `else` runs when `a` is `none` |
| `while a as x` | repeat while `a` produces a value |
| `a?` | the value inside `a`; when `a` is `none`, the enclosing function returns `none` |

Fields and methods are not reachable through an optional; take the
value out first (`a?.name` does). The name bound by `as` is visible only in its block,
and `as _` tests without binding.

```rig
fun positive(n: Int) -> Int?
  if n > 0
    n
  else
    none

fun describe(m: Int?) -> Int
  if m as v
    v * 2
  else
    0

sub main()
  print(positive(3) ?? 0, positive(-1) ?? 0)
  print(describe(4), describe(none), positive(-5) == none)
```

```output
3 0
8 0 true
```

`a?` mirrors `e!` ([§14](#14-errors)): it is allowed only in a
function returning `T?` (or `T?!`), and not in a closure body or
deferred code. The early return runs deferred code and drops what the
function owns, including values already computed for the same call.

```rig
struct User
  name: String
  boss: Int?

fun find(id: Int) -> User?
  return User(name: "ada", boss: 2) if id == 1
  return User(name: "grace", boss: none) if id == 2
  none

fun boss_name(id: Int) -> String?
  find(find(id)?.boss?)?.name

sub main()
  print(boss_name(1), boss_name(2), boss_name(3))
```

```output
grace none none
```

An optional of an owning value (such as `(*T)?` from `upgrade()`) owns
what it holds. `if e as x` over a temporary gives `x` ownership, and it
is dropped at the end of the block. An optional held in a binding is
bound by moving or cloning it: `if <m as x`, `if +m as x`, and
unwrapped the same way: `(<m)?`.

```rig reject
struct User
  name: String

sub main()
  u: User? = none
  print(u.name)
```

```error
`User?`
```

---

## 14. Errors

A function whose return type is `T!` may fail. A call to it must say
what happens to the failure, visibly:

- `f()!` propagates it: the enclosing function fails with the same
  error. The enclosing function must itself return a `T!`, or be
  the top-level `sub main` or a `test`.
- `f() catch fallback` handles it: the value of the call, or `fallback`
  when it fails.

A bare call to a fallible function is rejected, and so is `!` on a call
that cannot fail. A closure body, a `drop` body, and a `defer` cannot
propagate. A fallible type is only allowed as the return type of a
function or of a function type (`fun(Int) Int!`, not for an owned
closure), and a plain `T` is accepted where `T!` is expected. `E!` for an error
set `E` is rejected: a failure and a success would both be `E` values.

```rig
fun parse_len(s: String) -> Int!
  s.len

fun double_len(s: String) -> Int!
  parse_len(s)! * 2

sub main()
  print(double_len("four")!)
  print(parse_len("abc") catch 0)
```

```output
8
3
```

```rig reject
fun parse_len(s: String) -> Int!
  s.len

sub main()
  n = parse_len("abc")
```

```error
must be wrapped with `!` (propagate) or `catch` (handle)
```

### Failing

A fallible function fails by producing an error value where its `T` is
expected: `return E.name` (a member of an error set,
[§4](#error-sets)), a binding of an error set's type, an error it
caught, or `.name` when `T` has no variant of that name. The failure
leaves the function the way `!` does: every `defer` and `errdefer` of
the scopes it leaves runs. Only a function returning `T!` can fail.

### Naming the error

`f() catch |err| handler` names the error for the handler. Functions do
not declare which errors they fail with, so `err` may be any error: it
is compared with error-set members (`err == E.name`, `err == .name`),
matched by their names (`.name =>`, with a default arm where the match
gives a value), printed, and returned from a fallible function. Every
`.name` it is compared or matched with must be a member of some error
set the module can see. The handler may be a block. An error is
identified by its name alone: `A.timeout` and `B.timeout` of two error
sets are the same error, so `err == B.timeout` holds for a failure with
`A.timeout`.

```rig
error ParseError
  empty
  too_long

fun parse_len(s: String) -> Int!
  return ParseError.empty if s == ""
  return .too_long if s.len > 5
  s.len

fun describe(s: String) -> String
  n = parse_len(s) catch |err|
    match err
      .empty => return "empty"
      else => return "too long"
  "length ok" if n > 2 else "short"

sub main()
  print(parse_len("abc") catch -1, parse_len("") catch -1)
  print(describe(""), describe("abcdefg"), describe("abcd"))
  x = parse_len("") catch |err|
    print("failed with", err)
    0
  print(x)
```

```output
3 -1
empty too long length ok
failed with .empty
0
```

```rig reject
error ParseError
  empty

fun plain(n: Int) -> Int
  return ParseError.empty if n < 0
  n
```

```error
type mismatch: expected `Int`, got `ParseError`
```

---

## 15. Modules

`use name` imports `name.rig` from the directory of the program's root
file, whichever module says it, so a name denotes one file. The file's
name must be exactly `name.rig`, case included, and names starting with
`__rig` are reserved for the compiler. The module's `pub` declarations
are then reached as `name.decl`, and its types are named `name.Type` in
annotations. A type's members are named through the module too:
`name.Type.function(...)` calls an associated function, and
`name.Enum.variant` names a variant. Imports are checked in dependency
order, each module once; a cycle is an error.

```rig file=geo.rig
pub struct Point
  x: Int
  y: Int

  fun at(x: Int, y: Int) -> Point
    Point(x: x, y: y)

  fun sum(?self) -> Int
    self.x + self.y

pub enum Dir
  north
  east

pub fun origin() -> Point
  Point(x: 0, y: 0)
```

```rig
use geo

fun total(p: ?geo.Point) -> Int
  p.sum()

sub main()
  p: geo.Point = geo.Point(x: 1, y: 2)
  q = geo.Point.at(3, 4)
  d = geo.Dir.east
  print(total(?p), geo.origin().sum(), q.sum(), d)
```

```output
3 0 7 .east
```

Only `pub` declarations are visible to importers. A `pub` function may
take or return a private type: importers can hold the value and use its
fields and methods, though they cannot name the type. A struct's fields
and methods are visible wherever the struct is. Generic types cannot
cross module boundaries yet, so no instance of one declared in the
module may appear in its public surface, including in the fields of the
private types that surface reaches. Every check (types, arity, keyword
arguments, borrow modes, fallibility, ownership) applies across modules
exactly as within one, and a type is identified by the module that
declares it: `a.Point` and `b.Point` are different types. A module
whose import has errors is not checked; the import's errors are
reported.

---

## 16. Raw code and FFI

A `raw` block is the boundary of what the checker guarantees. Inside
it, and only there, a program may:

- call a builtin outside the safe list (`@intCast`, `@bitCast`, ...);
- call an `extern` function.

An `extern` function can only be called; it cannot be bound, passed,
or stored as a value, even inside `raw`. Rig has no raw pointers yet ([roadmap](docs/ROADMAP.md)).

Everything else inside a `raw` block is still checked. A `raw` block
can yield a value, and a safe function may wrap raw code, which is the
intended pattern: its callers need no `raw`.

```rig
extern fun abs(n: I32) -> I32

fun safe_abs(n: I32) -> I32
  raw
    abs(n)

sub main()
  x: Int = 300
  raw
    small: U8 = @intCast(x - 100)
    print(small, x)
  print(safe_abs(-5))
```

```output
200 300
5
```

`extern fun name(params) -> R` and `extern sub name(params)` declare C
functions; `extern name: fun(A) R` declares a function variable. Only
integers, floats, and `Bool` cross the C boundary, and a C function
cannot return a Rig error union. An `extern` is visible to importers
only through `pub` wrappers.

```rig reject
extern fun abs(n: I32) -> I32

sub main()
  print(abs(-5))
```

```error
call to extern function `abs` requires `raw` block
```

---

## 17. Compile-time parameters

A parameter marked `pre` is known at compile time; it lowers to a Zig
`comptime` parameter. The argument must be a literal, an enum value, a
`pre` parameter, or a `=!` binding of one. A function with a `pre` parameter can
only be called, not used as a value.

```rig
enum Mode
  strict
  loose

fun check(pre mode: Mode, n: Int) -> Bool
  if mode == .strict
    n > 10
  else
    n > 0

sub main()
  print(check(.strict, 5), check(.loose, 5))
```

```output
false true
```

`pre` expressions and `pre` blocks are reserved.

---

## 18. Printing

`print(a, b, ...)` writes its values separated by single spaces, then a
newline; `print()` writes an empty line. It also takes the paren-free
form `print a, b`. `print` is only special as a direct call; it is not
a value.

| Value | Printed as |
|---|---|
| numbers, `Bool` | `42`, `-3`, `2.5`, `true`; a whole `Float` keeps its point: `1.0` |
| `String` | its text; inside other values, quoted |
| `none` | `none` |
| enum | `.green`, `.rect(w: 2, h: 3)` |
| struct | `User(name: "ada", age: 36)` |
| array, slice, `Vec` | `[1, 2]` |
| shared handle | the value it holds |
| weak handle | `~(alive)` or `~(gone)` |
| owned closure | `<closure>` |
| function | `<fun>` |

A value nested more than 64 levels deep prints its deeper parts as
`...`. A `[]U8` and a `String` are the same bytes at run time, so
`print` rejects a value that holds a `[]U8`; print its bytes one by one.

```rig
struct User
  name: String
  age: Int

sub main()
  u = User(name: "ada", age: 36)
  n: Int? = none
  print(u, n, ["a", "b"], 2.5)
```

```output
User(name: "ada", age: 36) none ["a", "b"] 2.5
```

---

## 19. Reserved and unsupported forms

These forms are rejected, with a diagnostic that says what to write
instead; each is proven by a test in `test/reject/`. The first group do
not parse, and their words and sigils stay reserved:

| Form | Diagnostic |
|---|---|
| `&&`, `\|\|`, `**` | `` `&&` is not a Rig operator; use `and` `` |
| `@x` (pin) | `` the pin sigil `@x` is reserved `` |
| `for *x in v` | `` `for *x in` is reserved `` |
| `pre expr`, `pre` blocks | `` `pre` marks compile-time parameters only `` |
| `try` blocks | `` `try` blocks are reserved `` |
| `zig "..."` | `` inline Zig is reserved `` |
| string and float match patterns | `` a pattern is a name, an integer, `true`, `false`, or an enum variant `` |

The rest parse, and the checker rejects them as not supported yet
([roadmap](docs/ROADMAP.md)):

| Form | Diagnostic |
|---|---|
| generic functions (`pre T: type`) | `` generic functions are not supported yet `` |
| `drop` on an enum or a generic type | `` `drop` bodies are only for structs `` |
| a stack closure passed, stored, or returned | `` closures cannot escape their defining scope `` |
| a generic instance in a module's public surface | `` generic types cannot cross module boundaries yet `` |
| an array of owning values | `` arrays cannot hold values that own resources ``; use a `Vec` |
| an owned closure taking or returning an owning value | `` an owned closure takes plain Copy values `` |

```rig reject
sub main()
  zig "return;"
```

```error
unexpected keyword `zig`
inline Zig is reserved
```
