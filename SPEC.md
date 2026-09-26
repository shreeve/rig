# The Rig Language Reference

This is the reference for Rig as the compiler implements it today. Every
rule here is enforced by `rig check`, and every example is run by
`./test/run`: a program followed by an `output` block must print exactly
that output with no leaks, and a program marked as rejected must fail
with the error shown. For the reasons behind the rules, see
[docs/DESIGN.md](docs/DESIGN.md); for what is not built yet, see
[docs/ROADMAP.md](docs/ROADMAP.md).

```rig
sub main
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
that runs declares its entry point as `sub main`, with no parameters.
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
sub main
	print(1)
```

```error
tab in indentation; indent with spaces
```

### Line joining

Inside `( )` and `[ ]` a newline is plain whitespace, so arguments,
expressions, and method chains can span lines at any indentation. An
array, a call's arguments, a parameter list, a closure's bar list, a
variant pattern's bindings, a list of compile-time parameters, and a
list of compile-time arguments may end with a comma. A
backslash at the end of a line joins the next line anywhere.

```rig
fun add3(a: Int, b: Int, c: Int) -> Int
  a + b + c

sub main
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

These words are reserved:

```text
and  as  break  catch  continue  defer  drop  else  enum  errdefer
error  extern  false  for  fun  if  in  match  not  or  pub  raw
return  struct  sub  test  true  try  type  use  while  zig
```

A keyword may still name a member, where it cannot be mistaken for
the keyword: a struct field, a method, or a payload field. It reads as
a name right after `.` (`t.type`, `t.error()`), before `:` inside
parentheses (a keyword argument or payload field: `Token(type: 1)`),
and in a member list before `:` (a field) or after `fun` / `sub` (a
method). `drop(!self)` is still a drop body; `drop: Bool` is a
field. Everywhere else a keyword cannot name anything: a local, a
parameter, a top-level declaration, or an enum variant.

```rig
struct Token
  type: Int
  drop: Bool

  fun error(?self) -> Bool
    self.type < 0

sub main
  t = Token(type: -1, drop: false)
  print(t.type, t.drop, t.error())
```

```output
-1 false true
```

```rig reject
fun f(in: Int) -> Int
  1
```

```error
`in` is a keyword and cannot name a parameter
```

`new` is a keyword only at the start of a statement (`new x = ...`), so
a method may be named `new`. `of` is a keyword only after a value
directly inside `[ ]`, where it separates a fill literal's count from
its element (`[n of x]`); anywhere else it is an ordinary name. `none`
is a reserved
name for the absent optional. Words that are keywords in Zig but not in
Rig (`var`, `fn`, `const`) are ordinary names.

### Literals

| Literal | Examples | Notes |
|---|---|---|
| Integer | `42`, `1_000`, `0xff`, `0b1010`, `0o17` | `_` may separate digits; radix prefixes are lowercase; no leading zeros or suffixes |
| Float | `3.14`, `1.0e10`, `2e-3`, `1.5E+2` | a digit sequence with a `.` or an exponent |
| String | `"tab\tnewline\n"`, `'it''s'` | double quotes take Zig escapes (`\n`, `\t`, `\\`, `\"`, `\x41`, `\u{e9}`); single quotes take none, and `''` is one `'`; neither holds a control character (a raw tab or newline) |
| Bool | `true`, `false` | |
| Absent optional | `none` | see [§13](#13-optionals) |
| Array | `[1, 2, 3]` | see [§3](#arrays) |
| Enum variant | `.red`, `.circle(2)`, `.rect(w: 2, h: 3)` | typed by context |

There is no string interpolation; `print` takes several values instead.

```rig
sub main
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
| `f <x` | `f(<x)`: a paren-free call passing `x` moved ([§6](#calls)) |
| `a - b`, `a-b` | subtraction |
| `f -x` | `f(-x)`, as a paren-free call |
| `f(x)`, `a[i]`, `a.b` | call, index or compile-time arguments ([§17](#17-compile-time-parameters)), member access |
| `f (x)`, `f [1, 2]`, `f .red` | paren-free call with the argument `(x)`, `[1, 2]`, `.red` |
| `f()!`, `x?` | propagate a failure ([§14](#14-errors)) or `none` ([§13](#13-optionals)) |
| `-x` alone on a line | drops `x` ([§8](#drop)), except where the line's value is used |

The brackets of compile-time parameters and arguments touch the name
before them (`struct Wrap[T]`, `show[3]()`); a declaration with a space
there (`struct Wrap [T]`) is rejected.

Two values may not touch with no operator between them: `t.5` and
`print"hi"` are rejected, since neither is a call. Nor may `=!` and
`<-` touch the operand after them (`x =!y`, `a <-b`), which could as
well be `x = !y` and `a < -b`.

A paren-free call is a command, never a value ([§6](#calls)), so
where a value is expected `a -1` is neither a call nor a subtraction,
and it is rejected:

```rig reject
sub main
  a = 5
  b = a -1
```

```error
unexpected `-`; a sigil touching its operand is a prefix: to subtract, write `a - 1`; to call `a`, write `a(-1)`
```

As a command's argument, where a paren-free call is legal, `print a -1`
is `print(a(-1))`. When `a` cannot be called, the checker says so and
names the fix:

```rig reject
sub main
  a = 5
  print a -1
```

```error
`a` has type `Int` and cannot be called; a sigil touching its operand is a prefix: to subtract, write `a - 1`
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
(a float literal, its range; an integer literal given a float type,
exactly). Constant arithmetic is checked at compile time. Arithmetic on
literals given a float type is computed in that type, so it rounds like
run-time arithmetic and must not overflow it: `x: F32 = 1e38 * 10.0` is
rejected.

```rig
sub main
  small: U8 = 200
  sum = small + 55          # 55 is a U8 here
  big = 9223372036854775807
  print(sum, big, @sizeOf(Int), 0.1 + 0.2)
```

```output
255 9223372036854775807 8 0.30000000000000004
```

```rig reject
sub main
  a: U8 = 250
  b = a + 10
```

```error
`260` does not fit in `U8`
```

```rig reject
sub main
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

sub main
  big = 300
  print(U8(big - 100), Int(-7.9), average(7, 2), I32(U8(255)) + 1)
```

```output
200 -7 3.5 256
```

```rig reject
sub main
  b = U8(256)
```

```error
integer value `256` does not fit in `U8`
```

A `String` has a length `s.len` and can be indexed (`s[0]`), and a `for`
loop over it yields its bytes as `U8`. Strings compare with `==` and
`!=` by content, and `<`, `<=`, `>`, `>=` order them by their bytes
([§6](#operators)).

### Arrays

`[N]T` is a fixed-size array. Its length is known at compile time: an
integer, a constant (`[LIMIT]T`, `[lib.N]T`), a compile-time integer
parameter (`[n]T` in `fun zeros[n: Int] -> [n]Int`,
[§17](#17-compile-time-parameters)), or arithmetic on integers and
constants with `+`, `-`, `*`, `/`, `%`, and parentheses
(`[LIMIT * 2 + 1]U8`). The arithmetic is checked as constant
arithmetic is, in its constants' type: with `W: U8 =! 200`, `[W * 2]T`
overflows `U8`. A length runs from 0 to 4294967295, and one
given by a compile-time parameter is checked at each instance.
Arithmetic on a compile-time parameter (`[n + 1]T`) is rejected, as in
a compile-time argument. The length is a value, however it is written:
with `LIMIT =! 4`, `[LIMIT]Int`, `[2 + 2]Int`, and `[4]Int` are one
type.

An array literal `[a, b, c]` takes its element type from its elements
(or from an annotation). `[n of x]` is an array of `n` copies of `x`,
where `n` is any compile-time integer, a compile-time parameter
included; it has the array type expected where it goes, or `[n]T` for
`x`'s type `T`. An array whose length is a compile-time parameter is
built with it. `xs.len` is an array's length, and `xs[i]` reads or
writes an element; an index outside the half-open range `0..xs.len`
panics, and a constant one is rejected where the length is known.
Arrays hold plain data only, and `[n of x]` copies `x` into every slot; a
collection of resources is a `Vec`. An array of arrays is `[2][3]T`:
two rows of three.

```rig
LIMIT =! 4

fun zeros[n: Int] -> [n]Int
  [n of 0]

sub main
  xs = [10, 20, 30]
  xs[0] = 5
  ys: [2]U8 = [1, 2]
  grid: [2][3]Int = [[1, 2, 3], [4, 5, 6]]
  print(xs, xs.len, xs[2], ys, grid[1][2])
  a: [LIMIT]Int = [LIMIT of 7]
  b: [4]Int = a
  c = zeros[LIMIT * 2]()
  d = [3 of [2 of 0]]
  e: [0]Int = []
  print(b, c.len, d, e)
```

```output
[5, 20, 30] 3 30 [1, 2] 6
[7, 7, 7, 7] 8 [[0, 0], [0, 0], [0, 0]] []
```

```rig reject
fun grow[n: Int](xs: [n + 1]Int) -> Int
  1

fun zeros[n: Int] -> [n]Int
  [0, 0]

sub main
  k = 3
  a: [k]Int = [1, 2, 3]
  b = [-1 of 0]
  c = [2 of Vec[Int]()]
```

```error
an array length `n + 1` does arithmetic on a compile-time parameter
an array of compile-time length `n` is built with `[n of x]`
an array length must be known at compile time; `k` is not
array length -1 is out of range
`[n of x]` copies its element into every slot; `Vec[Int]` owns a resource
```

A value takes at most 8 MiB (8388608 bytes, a `[1048576]Int`): an
array, a struct or an enum, and each instance of a generic type or
function, for the arrays it makes and, for a type, for itself. The
values a function keeps on its stack take at most 16 MiB together: the
bindings it declares and its by-value parameters, each once, and every
array literal, fill, and call whose value no binding takes directly.
This holds for every function, method, closure (whose captures count
where it is made), test, and `main`, and for each instance of a
generic one. The stack holds 16 MiB, so a function that keeps more
could never run. Larger data belongs in a `Vec`, which keeps its
elements on the heap. A value or function too large is reported once;
a type or function holding a value too large is not reported again.

A program that runs off the end of its stack stops before it writes
beyond it. On x86_64, Zig touches each page of a new frame in turn,
so any frame stops at the guard page below the stack. On aarch64 it
does not, and a frame steps as far below the stack as its size: at
most 16 MiB of counted values, plus Zig's own temporaries. At least
64 MiB below the stack stays unmapped, four times the counted limit,
so every overflowing frame lands there: on macOS the program reserves
it when it starts; Linux maps nothing within 128 MiB of the top of the
stack, and the program holds its stack to 16 MiB. A program that
cannot do so stops before it runs, with `rig: cannot reserve the stack
guard below the main stack` and exit status 1.

```rig reject
struct Grid
  cells: [1024][1024]Int
  more: [8]Int

fun sums(k: Int) -> Int
  a = [800000 of k]
  b = [800000 of k]
  c = [800000 of k]
  a[0] + b[0] + c[0]

sub main
  big = [2000000 of 0]
  print(big.len, sums(1))
```

```error
`Grid` takes 8388672 bytes; a value takes at most 8388608 (8 MiB)
`sums` keeps 19200008 bytes of values on its stack; a function keeps at most 16777216 (16 MiB)
`[2000000]Int` takes 16000000 bytes
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
panics when they do not. A side may be left open: `xs[a..]` runs to the
end, `xs[..b]` starts at 0, and `xs[..]` is the whole. Only a slice
leaves a side open; a `for` range or a range pattern needs both ends.

```rig
fun total(xs: []Int) -> Int
  n = 0
  for x in xs
    n += x
  n

sub main
  s = "hello, world"
  print(s[0..5], s[7..s.len])
  a = [1, 2, 3, 4]
  mid = ?a[1..3]
  print(mid, mid.len, mid[0], total(mid), total(?a[0..4]))
  print(s[7..], s[..5], ?a[2..], total(?a[..]))
```

```output
hello world
[2, 3] 2 2 5 10
world hello [3, 4] 10
```

```rig reject
sub main
  for i in 0..
    print(i)
```

```error
a range needs an end; only a slice leaves a side open
```

A borrowed array parameter (`xs: ?[N]T`) is the function's own copy of
the caller's array, so a slice of it cannot be returned; a function
that returns part of its argument takes `xs: []T`.

`!xs[a..b]` is a **writable slice**, of type `![]T`: a write borrow of
the elements, taken of an array or a `Vec` of plain data that could be
write-borrowed (`!xs`), or of another `![]T`. A String and a `[]T` are
read-only, and so is what a fixed binding, a loop or pattern binding,
or a parameter other than a `!T` one holds. A `![]T` is a write borrow
like any other ([§8](#write-borrows)): while it is live, what it
borrows cannot otherwise be used, so two live write slices of one
array, or a `push` to a Vec while a slice of it is live, are rejected;
it cannot be copied or cloned (`<s` moves it), a call reborrows it, and
it is returned only when it borrows from a `!` parameter. Its elements
are assigned (`s[i] = v`, `s[i] += 1`), write-borrowed (`!s[i]`), and
written in a loop (`for x in !s`); `!s[a..b]` reslices it, and
`?s[a..b]` takes a read slice, which keeps `s` from being written while
it lives (a bare `s[a..b]`, which would borrow `s` unseen, is
rejected). A `![]T` is accepted wherever a `[]T` is expected; as an
argument it is then lent to read, like `?s[..]`, so `sum2(w, w)` with
two `[]T` parameters reads `w` twice, and `w` can be read, but not
written, while a view returned from it lives. A `[]T` is never
write-borrowed: `!t` of one is rejected. A slice's
elements are plain data: `[]T` and `![]T` with a `T` that owns a
resource are rejected.

```rig
fun total(xs: []Int) -> Int
  n = 0
  for x in xs
    n += x
  n

sub scale(s: ![]Int, k: Int)
  for x in !s
    x *= k

fun rest(s: ![]Int) -> ![]Int
  !s[1..]

sub main
  a = [1, 2, 3, 4]
  scale(!a[2..], 10)
  w = !a[..]
  w[0] = 7
  r = rest(!w[..])
  r[0] += 1
  print(total(w))
  print(a)
```

```output
80
[7, 3, 30, 40]
```

Three methods write the elements of a `![]T`, an array, or a Vec,
whose receiver is written `!xs` (or is a `![]T` binding):
`!dst.copy(src)` copies a `[]T` of the same length into them, and
panics in every build mode when the lengths differ; `!s.fill(v)` sets
every element to `v`; `!s.swap(i, j)` exchanges two elements, with both
indexes checked. `copy` and `fill` copy values in, so, as in
`[n of x]`, the elements are plain data: they own no resource and hold
no borrow, which a copy would duplicate. `swap` also moves the handles
of a `Vec` of them. `copy`'s
receiver and argument never overlap: the write borrow of the receiver
excludes a read of the same value.

```rig
sub main
  a = [1, 2, 3, 4, 5, 6]
  b = [9, 8, 7]
  !a[..3].copy(?b[..])
  !a[3..].fill(0)
  !a.swap(0, 5)
  print(a)
```

```output
[0, 8, 7, 0, 0, 9]
```

```rig reject
sub main
  a = [1, 2, 3, 4]
  !a[..2].copy(?a[2..])
```

```error
cannot write-borrow `a` while a read borrow is live
```

```rig reject
sub main
  s = "text"
  v: Vec[Int] = Vec()
  !v.push(1)
  w = !v[..]
  !v.push(2)
  w[0] = 5
  t = !s[1..]
```

```error
use of `v` while a write borrow is live
cannot write-borrow a slice of a String; a String is read-only
```

### Bytes

Bytes hold fixed-width numbers. `bytes.read[T, e](at)` is the integer
or float `T` stored in the `@sizeOf(T)` bytes from offset `at`, in byte
order `e`, and `!bytes.write[T, e](at, v)` stores `v` there. `T` is any
integer or float type; `e` is a compile-time value of the built-in enum
`Endian`, `.little` or `.big` (a literal, `Endian.big`, a constant, or
a compile-time parameter; there is no native order). `read` works on a
`[]U8`, an `![]U8`, a `[N]U8`, a `Vec[U8]`, and a String; `write` on
the writable ones, written `!bytes` (or an `![]U8` binding). Every byte
must be in range, `0 <= at` and `at + @sizeOf(T) <= len`: a constant
offset into an array is checked at compile time, and any other when the
program runs, which panics in every build mode when it is not. A float
is read and written by its bits, so a NaN's payload survives. `Endian`
is a built-in name, like `Vec`, and is reserved.

```rig
sub main
  page: [4096]U8 = [4096 of 0]
  !page.write[U32, .little](0, 0x52494721)
  !page.write[U16, .big](4, 4088)
  print(page[0], page[1], page[4], page[5])
  print(page.read[U32, .little](0), page.read[U16, .big](4), page.read[U16, .little](4))
  body = !page[8..]
  !body.write[F64, .big](0, 2.5)
  print(page.read[F64, .big](8))
```

```output
33 71 15 248
1380534049 4088 63503
2.5
```

```rig reject
sub main
  b: [8]U8 = [8 of 0]
  print(b.read[U32, .little](6))
  print(b.read[U16, .native](0))
```

```error
`read` of a `U32` at `6` runs past the end of an array of length 8: it needs 4 bytes
no variant `native` on enum `Endian`
```

### Composite and handle types

| Type | Meaning | Section |
|---|---|---|
| `[]T` | slice: a read-only view of elements | [§3](#slices) |
| `![]T` | writable slice: a write borrow of elements | [§3](#slices) |
| `T?` | optional: a `T` or `none` | [§13](#13-optionals) |
| `T!` | fallible: a `T` or an error; only as a return type, including a function type's | [§14](#14-errors) |
| `?T` | read borrow of a `T` (parameters, returns, locals, fields) | [§8](#8-ownership) |
| `!T` | write borrow of a `T` | [§8](#8-ownership) |
| `*T` | shared handle: reference-counted, single-threaded | [§10](#10-shared-and-weak-handles) |
| `~T` | weak handle to a shared value | [§10](#10-shared-and-weak-handles) |
| `fun(A, B) -> R`, `sub(A)` | function and closure types | [§12](#12-closures) |
| `*fun(A) -> R`, `*sub(A)` | owned closure (a shared handle) | [§12](#12-closures) |
| `Cell[T]`, `Vec[T]`, `Signal[T]` | built-in generic types | [§11](#11-cell-vec-and-signal) |
| `Endian` | built-in enum: the byte order of `read` and `write` | [§3](#bytes) |
| `Name`, `Name[T]`, `mod.Name` | user types, generic instances, imported types | [§4](#4-declarations), [§15](#15-modules) |

The handle sigils `*` and `~` bind to the type they touch, tighter than
the suffixes: `*User?` is an optional shared handle and `~User?` an
optional weak handle, while a handle to an optional `User` is written
`*(User?)`. A borrow applies to the whole type after it, suffixes
included: `?User?` and `!User?` borrow an optional `User`, and
`?*User?` borrows an optional handle. The element of a slice or array
takes the suffixes (`[]Int?` is a slice of optionals), so an optional
slice, array, or function type is written in parentheses: `([]Int)?`,
`(*sub())?`, and so is an optional of an optional, `(User?)?` (`??` is
an operator). A handle holds a value, never a borrow: `*(?User)` is
rejected. Prefixes compose right to left: `?*Wrap` is a read borrow
of a shared handle, and `*Cell[Vec[*sub()]]` is a shared cell holding a
list of owned closures.

```rig
struct User
  name: String

fun named(u: ?*User?) -> Bool
  u != none

sub main
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

sub main
  c: *(User?) = none
```

```error
`none` needs an optional type; `*(User?)` is not optional (write `*(User?)?`)
```

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
expression, or the value of a `return`. A function with no parameters
may leave out the empty `()`: `sub main` and `sub main()` are the same
declaration, and this reference writes the shorter one. A call always
has its parentheses, `greet()`: the name alone, `greet`, is the function
as a value.

```rig
fun area(w: Int, h: Int) -> Int
  w * h

fun sign(n: Int) -> Int
  return 1 if n > 0 else -1 if n < 0 else 0

sub report(label: String, n: Int)
  print(label, n)

sub main
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
value, which must be a literal. A call passes arguments by position, in
parameter order (`scaled(3, 2)`); by keyword, in any order
(`scaled(by: 4, n: 5)`); or both, positional arguments first
(`scaled(3, by: 2)`). A parameter with a default may be left out
(`scaled(3)`). Each parameter gets exactly one argument, and every
parameter without a default needs one. Arguments are evaluated in the
order written.

```rig
fun scaled(n: Int, by: Int = 10, _: Bool = false) -> Int
  n * by

sub main
  print(scaled(3, 2), scaled(by: 4, n: 5), scaled(3, by: 2), scaled(3))
```

```output
6 20 6 30
```

```rig reject
fun scaled(n: Int, by: Int = 10) -> Int
  n * by

sub main
  print(scaled(n: 3, 2))
  print(scaled(3, n: 4))
```

```error
positional arguments must come before keyword arguments
parameter `n` of `scaled` is given twice
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

sub main
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

  fun origin -> Self
    Point(x: 0, y: 0)

  fun plus(?self, other: ?Point) -> Point
    Point(x: self.x + other.x, y: self.y + other.y)

  sub shift(!self, dx: Int)
    self.x += dx

sub main
  p = Point.origin()
  q = Point(x: 1, y: 2)
  r = p.plus(?q)
  !r.shift(10)
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
| `!self` (= `self: !Self`) | modifies the value | `!p.m()` |
| `<self` (= `self: Self`) | consumes the value | `<p.m()`, or on a temporary |

Write borrows and moves are never implicit, so calling a `!self` method
as `p.m()` on an owned `p` is an error. A binding that already holds a
write borrow (a `!T` parameter, `self` in a `!self` method, a local
`w = !p`) calls it directly, `w.m()`: the borrow it holds is lent to the
call.

**Receiver sigils.** `!` or `<` directly before a *place* (a name
followed by any `.field` or `[index]` steps) that is followed by a
method call applies to that place: `!P.m(args)` is `(!P).m(args)` and
`<P.m(args)` is `(<P).m(args)`, with or without parentheses around the
arguments (`!v.push 3`). Postfixes after that call apply to its result:
`!v.pop()?`, and `!a.b().c(x)` is `(!a).b().c(x)`. Every other prefix
sigil (`?`, `+`, `-`, `*`, `~`), and `!` or `<` with no method call
after the place, applies to the whole expression as before:
`*Point.origin()` shares the result, `+n.first()` clones it, `-a.len`
negates it, `!x.v` borrows the field, `<p.f` moves the field, and
`?xs[0]` borrows the element. With parentheses, `!(v.pop())` borrows
the call's result.

The short form is checked against the method: `!` before a method that
does not take `!self` is rejected (it reads as negation, which is
`not`), and so is `<` before one that does not take `<self`, or
either before a function with no receiver (`Point.origin()`). A
write-borrowing call whose value is a `Bool` is written in the long
form, `(!set).insert(k)`, so it is never read as negation.

```rig
struct Tally
  seen: Vec[Int]

  fun insert(!self, k: Int) -> Bool
    for x in ?self.seen
      return false if x == k
    !self.seen.push(k)
    true

  fun total(<self) -> Int
    sum = 0
    for x in ?self.seen
      sum += x
    sum

sub main
  t = Tally(seen: Vec())
  !t.seen.push(1)
  added = (!t).insert(2)
  print(added, (!t).insert(2))
  print(<t.total())
```

```output
true false
3
```

```rig reject
struct Queue
  items: Vec[Int]

  fun is_empty(?self) -> Bool
    self.items.len == 0

sub main
  q = Queue(items: Vec())
  if !q.is_empty()
    print("items")
```

```error
`is_empty` does not write its receiver; for negation use `not`
```

```rig reject
struct Stack
  items: Vec[Int]

  fun top(?self) -> Int?
    self.items.get(0)

sub main
  s = Stack(items: Vec())
  print(<s.top() ?? 0)
```

```error
`top` does not consume its receiver; drop the `<`
```

```rig reject
struct Tally
  seen: Vec[Int]

  fun insert(!self, k: Int) -> Bool
    !self.seen.push(k)
    true

sub main
  t = Tally(seen: Vec())
  if !t.insert(1)
    print("added")
```

```error
a write-borrowing call that returns `Bool` is written `(!t).insert(...)`, so it is never read as negation
```

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

sub main
  c = Counter(n: 0)
  add_three(!c)
  !c.bump()
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

sub main
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

sub main
  s: Shape = .rect(w: 2, h: 5)
  c: Shape = Shape.point
  d = Shape.circle(1)
  print(s.area(), c.area(), d.area(), s)
  st: Status = .missing
  print(st == .missing)
```

```output
10 0 3 .rect(w: 2, h: 5)
true
```

A payload variant is constructed with keyword fields, like a struct:
`.rect(w: 2, h: 5)`, `Shape.rect(w: 2, h: 5)`. A variant with exactly
one field also takes it by position, as a pattern binds it:
`.circle(2)` is `.circle(radius: 2)`. A variant with more fields sets
them by name, and a struct's constructor always does. A pattern binds
the fields in order (`.circle(r) =>`). Enums have no constructor call
(`Shape(...)` is an error); enums compare with `==` ([§6](#operators)). A plain enum's variants may take
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

sub main
  e: NetworkError = .timeout
  match e
    .timeout => print("timed out")
    .refused => print("refused")
```

```output
timed out
```

### Generic types

`struct Name[T, ...]` declares a generic struct and `enum Name[T, ...]`
a generic enum; `error Name[T]` is rejected, and so is a struct declared
with `type`, which only names an [alias](#type-aliases). Their
parameters are type parameters and compile-time integers
([§17](#17-compile-time-parameters)): `struct Ring[T, n: Int]`. A value
parameter is named in the type's fields and methods, as an array length
(`items: [n]T`) or as a value in a method's body.
An instance names its compile-time arguments in brackets, in a type
(`Pair[Int, String]`, `Ring[Int, LIMIT * 2]`) or in an expression:
`Wrap[Int](value: 3)`, `Vec[Int]()`, `Option[Int].some(7)`,
`Pair[Int, String].make(1, "x")`, `Ring[Int, 4].new(0)`. A value
argument is a compile-time integer, as an array length is, that the
parameter's type holds; the same value names the same type, so
`Ring[Int, 2 + 2]` is `Ring[Int, 4]`. Without them, a constructor takes them
from the expected type when there is one, and otherwise infers them
from the values that fill it: a constructor's fields
(`Pair(first: 1, second: "x")` is a `Pair[Int, String]`, and
`Ring(items: [1, 2, 3])` a `Ring[Int, 3]`), a payload
variant's fields (`Option.some(7)`), or an associated function's
arguments (`Pair.make(1, 2)`), as a generic function's call infers its
own ([generic functions](#generic-functions)). A parameter nothing
fills, as in `Vec()`, needs its type named (`Vec[Int]()`) or given
where the value goes (`v: Vec[Int] = Vec()`). A generic type may hold
`Vec[T]`, `Cell[T]`, `Signal[T]`, or `[N]T`; their element rules apply
to each instance, and so does the range of an array length a value
parameter gives. Its body follows the rules of
[generic bodies](#generic-bodies).

```rig
struct Pair[T, U]
  first: T
  second: U

  fun make(a: T, b: U) -> Pair[T, U]
    Pair(first: a, second: b)

  fun left(?self) -> T
    self.first

enum Option[T]
  some(value: T)
  nothing

sub main
  p = Pair(first: 42, second: "answer")
  o: Option[Int] = .some(p.left())
  match o
    .some(v) => print(v, p.second)
    .nothing => print("none")
  q = Option.some(2.5)
  v = Vec[Int]()
  !v.push(3)
  r = Pair[Int, String].make(1, "x")
  n = Option[Int].nothing
  log = Cell[Vec[*Pair[Int, String]]](value: Vec())
  print(q, v[0], r.second, n, log.len)
```

```output
42 answer
.some(value: 2.5) 3 x .nothing 0
```

```rig reject
struct Flag[on: Bool]
  first: Int

sub main
  v = Vec[Int, Int]()
```

```error
a compile-time value parameter of a type is an integer; `on` has the type `Bool`
generic type `Vec` expects 1 type argument, got 2
```

### Generic functions

A type parameter among a function's compile-time parameters
([§17](#17-compile-time-parameters)) makes it generic:
`fun max[T](a: T, b: T) -> T`. A `sub`, a method, and an associated
function take them too, and a method's own sit after its type's: a
method `fun map[U](?self, u: U)` of `Wrap[T]` has both.

A call gives every compile-time argument in brackets
(`max[Float](1, 2)`), or none, and then its type arguments are
inferred by matching each parameter's type against its argument's type
(`T`, `?T`, `!T`, `*T`, `~T`, `T?`, `[]T`, `[N]T`, `Wrap[T]`,
`fun(T) -> U`). A method's receiver gives its type's parameters. Every
argument must agree, and an argument whose type does not have its
parameter's shape is a type mismatch. A parameter no argument other
than a literal gives a type takes one from the type expected of the
call's result, where there is one (a typed binding, parameter, field,
or assigned place, a `return` from a function or from a closure whose
result type is given, and the last expression of either), by matching
the declared result against it the same way; a result lifted into an
expected `T?` or `T!` is matched against the `T`, a propagated or
caught `T!` against its value, and the left of `??` against an optional
of the expected type. So `z: U8 = max(1, 2)` is `max[U8]`. A generic
function call that is an argument of another, and whose result is a
type parameter only literals gave a type (directly, or propagated with
`!` or `?`), takes the type that call gives it: `max(max(1, 2), small)`
with `small: U8` is `max[U8]` twice. One whose result is an optional
that nothing but `none` gave a type (`nothing()`, `id(none)`) binds
like `none`, so `z: Int? = id(nothing())` is `id[Int?]`. A nested call
with a result of another shape (`Wrap.make(1)`, `Opt.some(1)`)
keeps the type its own arguments give it; naming the outer call's type
arguments (`Wrap[Wrap[U8]].make(...)`, `id[Opt[U8]](...)`) passes the
expected type on. Only then does a literal take its default type, and
among literals alone a float literal gives `Float`: `max(3, 2.5)` is
`max[Float]`. An argument that is not a literal keeps
the type it gives, even where the result is expected to have another.
An integer compile-time value that a parameter's or the result's type
holds, as an array length (`[n]T`) or a generic type's value argument
(`Ring[T, n]`), is inferred the same way: `sum([1, 2, 3])` of
`fun sum[n: Int](xs: [n]Int)` is `sum[3]`, and `a: [3]Int = zeros()`
of `fun zeros[n: Int] -> [n]Int` is `zeros[3]`. It takes exactly the
length the argument's type has; arguments that give it different ones
conflict, and the value must fit the parameter's type. Any other
compile-time value is never inferred, so a function that takes one is
always called with brackets, and so is one with a type parameter
neither its arguments nor the expected type determine (one used only in
the result where no type is expected, or given only `none` or a
`.variant`).

A generic function can only be called: it is not a value, and a closure
is never generic. Another module's generic function is called as a
local one is ([§15](#15-modules)).

```rig
struct Res
  n: Int

  drop(!self)
    print("drop", self.n)

struct Wrap[T]
  v: T

  fun with[U](?self, u: U) -> U
    u

fun max[T](a: T, b: T) -> T
  a if a > b else b

fun sum[n: Int](xs: [n]Int) -> Int
  total = 0
  for x in xs
    total += x
  total

fun zeros[n: Int] -> [n]Int
  [n of 0]

fun pick[T](a: T, b: T, first: Bool) -> T
  if first
    return <a
  <b

sub main
  small: U8 = 200
  z: U8 = max(1, 2)
  print(max(3, 7), max(small, 9), max(3, 2.5), max[Float](1, 2), z)
  print(Wrap(v: 1).with("s"), Wrap(v: 1).with[Bool](true))
  r = pick(Res(n: 1), Res(n: 2), true)
  print("kept", r.n)
  a: [3]Int = zeros()
  print(sum([1, 2, 3]), sum(a), a)
```

```output
7 200 3.0 2.0 2
s true
drop 2
kept 1
6 0 [0, 0, 0]
drop 1
```

```rig reject
fun max[T](a: T, b: T) -> T
  a if a > b else b

fun make[T](n: Int) -> Int
  n

fun both[n: Int](a: [n]Int, b: [n]Int) -> Int
  n

sub main
  n: I32 = 1
  print(max(n, 2.5), make(3))
  z: U8 = max(n, 2)
  f = max
  print(both([1, 2], [1, 2, 3]))
```

```error
conflicting types for `T` in the call to `max`: `I32` (argument 1) and `Float` (argument 2)
cannot infer `T` for `make` from its arguments or the type expected of its result
type mismatch: expected `U8`, got `I32`; `max` takes `T = I32` from argument 1
`max` takes compile-time parameters, so it can only be called, not used as a value
conflicting values for `n` in the call to `both`: `2` (argument 1) and `3` (argument 2)
```

### Generic bodies

A generic type's methods and a generic function's body are checked
once, with each type parameter standing for any type. There are no
traits or bounds. What the body does with a `T` that only some types
support (arithmetic, ordering, `==`, a literal beside a `T`, a copy of a
`T`) is recorded, a borrowed operand (`?T`, `!T`) as the `T` it
reaches, and every instance the program makes, spelled or
inferred, directly or through other generic bodies, in any module, is
checked against it. On a `T`, `==` compares whatever `==` compares
outside a generic body, and ordering compares numbers and Strings. A
failure is reported at the call or type that makes the instance, with a
note at the body line that needs the operation, in the module that
declares the body. A body cannot call a method on a `T`, read a field
of one, or call `T` itself.

The body is ownership-checked once, for a `T` that may own a resource
and holds no borrow. A `T` that owns a resource moves where the body
moves it, and is dropped where the body lets it go. Where the body
copies a `T`, every instance must be plain data; the same holds where it
takes (moves, drops, or returns) an element of a loop that does not
consume its collection (`for x in v`), or unwraps a `T` out of a
borrowed optional with `as`, since the collection or the owner still
holds the value. A type argument cannot be a borrow or hold one, for a
generic function or a generic type with methods: the parameter is
written `?T` or `!T` instead.

A body that calls itself, or builds its own type, with its type
parameters nested deeper each time (`nest[Wrap[T]]` inside `nest[T]`)
would need ever deeper instances, and is rejected rather than expanded
forever: at an instance, or, for a `pub` generic and the generic
methods of a `pub` type, whose instances other modules make, where it
is declared.

```rig reject
struct Res
  n: Int

  drop(!self)
    print("drop", self.n)

struct Pair[A, B]
  first: A
  second: B

fun max[T](a: T, b: T) -> T
  a if a > b else b

fun twice[T](x: T) -> Pair[T, T]
  Pair(first: x, second: x)

fun same[T](x: T) -> T
  x

sub main
  print(max(true, false))
  p = twice(Res(n: 1))
  r = Res(n: 2)
  q = same(?r)
```

```error
`max[Bool]` cannot use `T = Bool`: the generic body applies `>` to `T`, which `Bool` does not support
`>` used on `T` here (ordering comparison)
`twice[Res]` cannot use `T = Res`: the generic body copies a `T`, which would duplicate the resource `Res` owns
`T` copied here; move it with `<` instead
`same[?Res]` cannot use `T = ?Res`: a generic function is checked for a `T` that holds no borrow
```

### Type aliases

`type Name = T` gives a type a second name. An alias is transparent: it
is the same type as `T`.

```rig
type UserId = Int

fun next(id: UserId) -> Int
  id + 1

sub main
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

  fun origin -> Point
    Point(x: 0, y: 0)

enum Color
  red
  green

type P = Point
type C = Color

sub main
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
and array literals over them. Every function and type in the module
reads it, wherever it is declared; nothing can reassign or move it,
and a local or parameter may not reuse its name (`new` shadows it on
purpose).
Arithmetic on constants alone is checked at compile time; with a value
known only when the program runs, it is checked then, like any other.

```rig
limit =! 10
half =! limit / 2
names =! ["low", "high"]

fun over(n: Int) -> Bool
  n > limit

sub main
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
sub main
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
sub main
  x = 1
  new x = x + 10
  print(x)
  new x = "now a string"
  print(x)
```

```output
11
now a string
```

```rig reject
fun total -> Int
  0

sub main
  total = 5
```

```error
local `total` has the same name as the module-level declaration `total`
```

A binding cannot refer to itself in its own initializer. Parameters,
loop bindings, and names bound by patterns and `as` are immutable.

Every local must be read. Any use counts: an argument, an operand, a
borrow `?x` or `!x`, a move `<x`, a clone, a field access, a closure
capture, a drop `-x`. Assigning does not: a local that is only ever
assigned, like a misspelled `totl = 5`, is rejected. A name bound by
`for`, a match pattern, `as`, or `catch |e|` must be read too, or be
`_`. Discard a value on purpose with `_ = e`. A value with drop glue
([§9](#9-drop-and-drop-glue)) is read by its own release, so a local
held only for its `drop` at the end of the scope is fine. Parameters
are exempt.

```rig reject
sub main
  total = 0
  totl = 5
  print(total)
```

```error
`totl` is assigned but never read
```

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
| `..` | half-open range: a `for` source, a match pattern, or a slice's index, where a side may be open ([§3](#slices)) |
| `\|` | bitwise or |
| `^` | bitwise xor |
| `&` | bitwise and |
| `<<` `>>` | shifts |
| `+` `-` | |
| `*` `/` `%` | |
| `-x` and the ownership sigils | prefix |
| `f(x)` `a[i]` `a.b` `e!` | postfix: call, index, member, propagate |

Postfixes bind tighter than prefixes, so `-a.len` is `-(a.len)` and
`+n.first()` clones the result. The one exception is a receiver sigil:
`!` or `<` before a place followed by a method call applies to the
place, `!v.push(x)` is `(!v).push(x)` and `!v.put[2](x)` is
`(!v).put[2](x)` ([§4](#structs)). A call of a field holding functions
(`!p.f()`, `!p.fs[0]()`) has no receiver, so a sigil there is rejected.

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

`==` and `!=` compare two values of the same type, by content. The
equatable types are numbers, `Bool`, `String`, errors, and plain enums,
and, when everything they hold is equatable: optionals, where `none`
equals only `none` and a value compares with an optional as its value;
arrays and `[]T` slices, element by element; structs, field by field;
and payload enums, by variant and then payload. A variant literal,
`.red` or `.dot(at: p)`, takes its enum type from the other operand, on
either side. A bare `.variant` tests only which variant a value holds,
so it compares with any enum, or optional of one, whatever its payloads
hold; a payload literal compares the payload too, so the enum must have
`==`. Floats compare as IEEE numbers wherever they are, so a
struct holding a NaN is not equal to itself. A borrowed operand (`?P`,
`!P`) compares as the value it reaches. A method named `eq` is never
called by `==`.

A handle `*T` or `~T` has no `==`, since it could compare identity or
content; nor does a function or closure, a Vec, Cell, or Signal, a
struct that declares `drop`, or a view (a struct or payload that holds a
borrow). Neither does a type that holds one of these, and the
diagnostic names the field that does.

Ordering comparisons (`<`, `<=`, `>`, `>=`) take two numbers, or two
`String`s or two `[]U8` slices, ordered by their bytes: the first byte
that differs decides, and a prefix sorts before the longer string.
Structs, enums, and other slices have no ordering.

```rig
struct Point
  x: Int
  y: Int

enum Shape
  dot(at: Point)
  empty

sub main
  a = Point(x: 1, y: 2)
  b = Point(x: 1, y: 2)
  s: Shape = .dot(at: a)
  found: Point? = none
  print(a == b, s == .dot(at: Point(x: 2, y: 1)), found == none, [a] == [b])
  print("abc" < "abd", "ab" < "abc", "b" <= "a")
```

```output
true false true true
true true false
```

```rig reject
struct Node
  n: Int

struct Link
  id: Int
  to: *Node

sub main
  a = Link(id: 1, to: *Node(n: 1))
  print(a == a, a < a)
```

```error
`==` is not defined for `Link`: field `to` is a handle `*Node`, which could compare by identity or by content
operator `<` orders numbers, Strings, and `[]U8` slices; got `Link`
```

```rig
struct Node
  n: Int

enum Slot
  held(to: *Node)
  empty

sub main
  s: Slot = .held(to: *Node(n: 1))
  print(s == .empty, s != .empty)
```

```output
false true
```

```rig reject
struct Node
  n: Int

enum Slot
  held(to: *Node)
  empty

sub main
  s: Slot = .empty
  print(s == .held(to: *Node(n: 1)))
```

```error
`==` is not defined for `Slot`: field `held.to` is a handle `*Node`
```

`and`, `or`, and `not` take `Bool`s; `not` binds looser than comparisons,
so `not a == b` is `not (a == b)`. The spellings `&&` and `||` are
rejected with a hint. Prefix `!` is always a write borrow, never
negation: a `!x` whose `Bool` value would be read (a condition, an
operand, a binding, an argument) is rejected. It is valid only where a
`!Bool` is expected, as for an argument to a `flag: !Bool` parameter.

```rig reject
sub main
  done = false
  if !done
    print("working")
```

```error
`!` is a write borrow; use `not` for negation
```

```rig
sub main
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
sub main
  a = true
  b = a && false
```

```error
`&&` is not a Rig operator; use `and`
```

### Calls

`f(a, b)` calls `f`. A line that does something may drop its call
parentheses; anywhere a value is expected, a call takes parentheses.
A **paren-free call** is a command: it takes the rest of the line as
its arguments, and it may stand as a statement, a match arm's body, a
closure's body, or the last argument of another paren-free call:
`print add 1, 2` is `print(add(1, 2))`.

Everywhere else a call takes its parentheses: the right side of a
binding or an assignment, `return` and `break` values, `if` and `while`
conditions, `for` sources, `match` subjects, and every argument inside
parentheses: `x = twice(5)`, `if ready(3)`, `print(1, twice(-3), 5)`.
Only a closure body, which is a statement of its own, may be a
paren-free call inside parentheses (`each(3, *|i| print i)`).

```rig
fun add(a: Int, b: Int) -> Int
  a + b

fun twice(n: Int) -> Int
  n * 2

sub main
  print add 1, 2
  print (1 + 2) * 3
  print add(1, 2), add 3, 4
  x = twice(5)
  if twice(x) > 10
    print twice x
```

```output
3
9
3 7
20
```

```rig reject
fun twice(n: Int) -> Int
  n * 2

sub main
  x = twice 5
```

```error
unexpected `5`; a call where a value is expected takes parentheses: `twice(5)`
```

```rig reject
fun twice(n: Int) -> Int
  n * 2

sub main
  print(1, twice -3, 5)
```

```error
a call inside parentheses needs its own parentheses: `twice(...)`
```

Keyword arguments name parameters (`scaled(by: 4, n: 5)`), and
constructors always use them. Arity, keyword names, and argument types
are checked. Compile-time arguments go in brackets before the
parentheses: `check[.strict](5)` ([§17](#17-compile-time-parameters)).

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

sub main
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

A statement must have some use. An expression whose value is used (the
last line of a `fun`, a binding, an argument) may be anything, but one
whose value would be thrown away must do something: call, propagate
(`e!`, `e?`), or `catch`. A name, literal, field read, or borrow alone on
a line has no use and is rejected, and a function name alone is taken
for a forgotten call.

```rig reject
sub greet
  print("hi")

sub main
  greet
```

```error
`greet` is a function; call it with `greet()`
```

### Builtins

`@name(args)` calls a Zig builtin. `@sizeOf`, `@alignOf`, `@TypeOf`,
and `@typeName` are safe anywhere; every other builtin needs a `raw`
block ([§16](#16-raw-code-and-ffi)). Rig type names are translated
(`@sizeOf(I64)` is 8).

---

## 7. Control flow

### if

```rig
sub main
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

sub main
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
sub main
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

sub main
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

  drop(!self)
    print("drop", self.n)

sub keep(b: *B)
  print("kept", b.n)

sub main
  xs = [1, 2, 3]
  for x in !xs
    x *= 10
  print(xs)
  v: Vec[*B] = Vec()
  for i in 0..3
    !v.push(*B(n: i))
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
sub main
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

sub main
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
| `_` | everything else |
| any other name | everything else, binding the value to the name |

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

sub main
  print(size(5), size(42), size(200))
  match 7
    1 => print("one")
    other => print("something else:", other)
```

```output
small medium large
something else: 7
```

### defer and errdefer

`defer stmt` (or `defer` with a block) runs when the enclosing block
exits, in reverse order of the defers. `errdefer` runs only when the
function exits with an error. A deferred body may not move or drop
outer bindings, or propagate with `!`. It runs after the values declared
after it are dropped, so it may not read one through a borrow.

```rig
sub main
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
sub main
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

  drop(!self)
    print("released", self.payload)

sub send(p: Packet)
  print("sent", p.payload)

sub main
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

  drop(!self)
    print("released")

sub send(p: Packet)
  print(p.payload)

sub main
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
struct Wrap
  n: Int

sub main
  a = *Wrap(n: 1)
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
struct Wrap
  n: Int

sub eat(b: *Wrap)
  print(b.n)

sub main
  b = *Wrap(n: 1)
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
`b: ?Wrap` reads, `b: !Wrap` writes. Every borrow is visible at the call
site.

```rig
struct Account
  balance: Int

fun balance_of(a: ?Account) -> Int
  a.balance

sub deposit(a: !Account, n: Int)
  a.balance += n

sub main
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

sub main
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
struct Wrap
  n: Int

  sub bump(!self)
    self.n += 1

struct View
  box: ?Wrap

sub main
  x = Wrap(n: 1)
  r = ?x
  print(r.n)
  !x.bump()
  v = View(box: ?x)
  print(v.box.n)
  x = Wrap(n: 7)
  print(x.n)
```

```output
1
2
7
```

```rig reject
struct Wrap
  n: Int

  sub bump(!self)
    self.n += 1

sub main
  x = Wrap(n: 1)
  r = ?x
  i = 0
  while i < 2 : i += 1
    print(r.n)
    !x.bump()
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

sub main
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
write-borrowed. Nor can a temporary, such as a call's result or a
struct literal, since the change would be lost with it.

```rig reject
struct Wrap
  n: Int

sub grow(b: !Wrap)
  b.n += 1

sub main
  grow(!Wrap(n: 1))
```

```error
cannot write-borrow a temporary: the change would be lost; bind it to a name first
```

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
struct Wrap
  payload: Int

struct View
  box: ?Wrap

fun pick(a: ?Wrap, b: ?Wrap, first: Bool) -> ?Wrap
  if first
    a
  else
    b

sub main
  x = Wrap(payload: 1)
  y = Wrap(payload: 2)
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

fun make -> ?User
  u = User(name: "ada")
  ?u
```

```error
returned borrow of `u` does not originate from a borrowed parameter
```

```rig reject
struct Wrap
  payload: Int

  drop(!self)
    print("drop")

fun first(a: ?Wrap, b: ?Wrap) -> ?Wrap
  a

sub main
  x = Wrap(payload: 1)
  y = Wrap(payload: 2)
  r = first(?x, ?y)
  -y
  print(r.payload)
```

```error
cannot drop `y` while borrows are live
```

A borrowed parameter can be forwarded (`g(?b)` with `b: ?B`), and a
borrow of a number, `Bool`, `String`, or plain enum reads as the value
wherever the value is expected, whether a name holds the borrow or an
expression yields it (`f(!x) + 1`, `take(f(!x))`, `if flag(!b)`); the
borrow taken to reach it ends there. Other values, which may own
resources, are not copied out of a borrow. The caller still owns a
borrowed value: a borrowed parameter cannot be dropped or move-captured,
and a field cannot be moved out of it.

```rig
fun slot(a: !Int) -> !Int
  a

sub main
  n = 4
  m: Int = slot(!n)
  print(slot(!n) + slot(!n), Float(slot(!n)), m)
```

```output
8 4.0 4
```

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

  drop(!self)
    print("drop", self.id)

sub run(early: Bool)
  a = Noisy(id: 1)
  b = Noisy(id: 2)
  if early
    -b
    print("dropped b early")
  print("end of run")

sub main
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

sub main
  print((*User(age: 5)).age)
```

```error
bind it to a name first
```

---

## 9. Drop and drop glue

A struct may declare one `drop` body, which runs when a value of the
type is released. It takes exactly one parameter, its write-borrowed
receiver, spelled as a method's: `drop(!self)`, or `drop(self: !Self)`.

```rig
struct File
  fd: Int

  drop(!self)
    print("closing", self.fd)

sub main
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

  drop(!self)
    print("noisy", self.id)

struct Pair
  a: *Noisy
  b: *Noisy

  drop(!self)
    print("pair")

sub main
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
`drop` bodies are only for non-generic structs; enums and generic
structs get structural glue only.

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

  drop(!self)
    print("released", self.name)

sub main
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
exception: `!h.push(x)` through a `*Vec[T]` is rejected, and a shared
Vec is a `*Cell[Vec[T]]`.

```rig reject
struct User
  age: Int

sub main
  u = *User(age: 1)
  u.age = 2
```

```error
cannot assign through shared handle
```

### Weak handles

`~h` makes a weak handle `~T` from a shared one. A weak handle does not
keep the value alive. `w.upgrade()` returns an optional strong handle
`*T?`: a new owner while the value is alive, `none` after.

```rig
struct Node
  id: Int

  drop(!self)
    print("drop", self.id)

sub show(w: ?~Node)
  if w.upgrade() as n
    print("alive", n.id)
  else
    print("gone")

sub main
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

`Cell[T]` holds one value that can be replaced through a read-only
path. It is the way to mutate shared state: `*Cell[T]` is a shared,
mutable value.

| Member | Meaning |
|---|---|
| `Cell(value: v)` | construct |
| `c.get()` | a copy of the value (Copy `T` only) |
| `c.set(v)` | store `v`; the old value is dropped |
| `c.replace(v)` | store `v` and return the old value |
| `c.push(x)`, `c.pop()`, `c.clear()`, `c.len` | a `Cell[Vec[T]]`: its Vec's members |
| `c[i]`, `c[i] = x`, `c.get(i)` | a `Cell[Vec[T]]` of Copy `T`: an element, bounds-checked, or `T?` |

`T` is a Copy primitive or an owning type. An owning value is never
copied out of a cell: it moves in with `set` / `replace` and moves out
with `replace`. What goes into a cell holds no borrow, since every
handle to the cell reaches it.

A `Cell[Vec[T]]` answers its Vec's members as `set` does, without `!`:
`push` moves or clones an owning element in (`<x`, `+x`), `pop` hands
the last one out as `T?`, and `clear` drops them all. No user code runs
while the cell's Vec is in use: `clear` leaves the cell holding an empty
Vec before it drops the elements, so a `drop` body that reaches back
into the cell finds a valid Vec. For the same reason an element is a
copy: `c[i]` and `c.get(i)` read one and `c[i] = x` writes one only
when `T` is Copy, an element cannot be borrowed, and a field of one is
not written in place. The elements of a Vec of handles are taken out
with `pop`, or by taking the whole Vec out with `replace`.

A Cell is interior-mutable: `set` and `replace` change it through any
path to it, including a read borrow (`?Cell[T]`), a `?self` method of a
struct holding one, and a shared handle. A by-value parameter is
immutable, and a loop or match binding is only a copy, so neither can
be changed (or lent to something that could change it).

```rig
struct Counter
  hits: Cell[Int]

  sub hit(?self)
    self.hits.set(self.hits.get() + 1)

sub bump(c: ?Cell[Int])
  c.set(c.get() + 10)

sub main
  count: *Cell[Int] = *Cell(value: 0)
  other = +count
  other.set(other.get() + 5)
  local: Cell[Int] = Cell(value: 1)
  bump(?local)
  k = Counter(hits: Cell(value: 0))
  k.hit()
  k.hit()
  print(count.get(), local.get(), k.hits.get())

  shared: *Cell[Vec[Int]] = *Cell(value: Vec())
  shared.push(7)
  shared.push(8)
  shared[0] = shared[0] + 1
  print(shared.len, shared[0], shared.get(1), shared.get(2))

  # Anything else: take the value out, use it, and put it back.
  v = shared.replace(Vec())
  sum = 0
  for x in v
    sum += x
  shared.set(<v)
  print(sum, shared.len)
```

```output
5 11 2
2 8 8 none
16 2
```

### Vec

`Vec[T]` is a growable array that owns its elements. The binding is the
buffer: a `Vec` is an owning value even when its elements are Copy.
Elements are Copy primitives (numbers, `Bool`, `String`), plain data
(structs, enums, and optionals that own nothing and hold no borrow),
shared handles (including owned closures), or weak handles.

| Member | Meaning |
|---|---|
| `Vec()`, `Vec(capacity: n)` | an empty Vec (typed by context) |
| `!v.push(x)` | append; an owning `x` is moved or cloned in |
| `v.len` | the number of elements |
| `v[i]`, `v[i] = x` | read or write an element, or a field of one (Copy `T`; bounds-checked) |
| `v.get(i)` | the element as `T?` (Copy `T`) |
| `!v.pop()` | remove the last element, as `T?`; a handle is handed over to the caller |
| `!v.clear()` | drop every element |

A `for` loop borrows the Vec for the whole loop, so it cannot be
modified inside it. A Vec of Copy values may be walked by value
(`for x in v`). A Vec of owning values is walked by borrowed slot with
`for x in ?v`, where `v` must be a binding or a field of one: the
element can be read, called, and cloned (`+x` is a new handle), but not
moved, dropped, or stored. `for x in !v` and `for x in <v` write and
consume the elements ([§7](#for)).

```rig
sub main
  total: *Cell[Int] = *Cell(value: 0)
  steps: Vec[*sub()] = Vec()
  !steps.push(*|+total| total.set(total.get() + 1))
  !steps.push(*|+total| total.set(total.get() + 10))
  for step in ?steps
    step()
  nums: Vec[Int] = Vec()
  !nums.push(3)
  !nums.push(4)
  while !nums.pop() as n
    total.set(total.get() + n * 100)
  print(total.get(), steps.len)
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

  drop(!self)
    print("drop", self.n)

sub main
  ps: Vec[P] = Vec()
  !ps.push(P(x: 1, y: 2))
  ps[0].y = 5
  print(ps[0], ps.len)
  bs: Vec[*B] = Vec()
  !bs.push(*B(n: 1))
  !bs.push(*B(n: 2))
  if !bs.pop() as last
    print("popped", last.n)
  print("left", bs.len)
```

```output
P(x: 1, y: 5) 1
popped 2
drop 2
left 1
drop 1
```

### Signal

`Signal[T]` holds a Copy value and a list of subscribers, owned closures
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
sub main
  sig: *Signal[Int] = *Signal(value: 0)
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
sub main
  n = 10
  cell: *Cell[Int] = *Cell(value: 0)
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
sub main
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
sub main
  total: *Cell[Int] = *Cell(value: 0)
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
its `return`s when it ends in one, and these give each other no type: a
`return max(3, 4)` beside a `return x` of a `U8` is still an `Int`. A
body ending in any other statement, or in an `if` without `else`,
returns nothing. `return` inside a closure
leaves the closure.

```rig
fun apply(f: fun(Int) -> Int, x: Int) -> Int
  f(x)

fun twice(n: Int) -> Int
  n * 2

sub main
  add: fun(Int, Int) -> Int = |a, b| a + b
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
| `fun(Int, Int) -> Int` | takes two `Int`s, returns an `Int` |
| `sub(String)` | takes a `String`, returns nothing |
| `*fun(Int) -> Int`, `*sub()` | an owned closure of that shape |
| `~fun(Int) -> Int`, `~sub()` | a weak handle to an owned closure |

Function types describe closures bound to locals and function names
used as values. A function type writes its result after `->`, as a
declaration does; a suffix belongs to the result, so `fun(Int) -> Int!`
returns an `Int!`, and an optional function is `(fun(Int) -> Int)?`. An owned closure is a
shared handle, so `~f` makes a weak handle to it, which upgrades like
any other ([§10](#weak-handles)).

```rig
sub main
  f: *fun(Int) -> Int = *|a| a + 1
  w: ~fun(Int) -> Int = ~f
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
fun make -> fun() -> Int
  n = 1
  |+n| n
```

```error
closures cannot escape their defining scope
```

### Owned closures

`*` before the bar list makes an **owned closure**: its environment is
allocated on the heap behind a shared handle of type `*fun(...) -> R` or
`*sub(...)`, which can be stored, passed, returned, cloned (`+cb`),
held weakly, and dropped like any `*T`.

```rig
fun make_counter(start: Int) -> *fun(Int) -> Int
  count: *Cell[Int] = *Cell(value: start)
  *|+count, step|
    count.set(count.get() + step)
    count.get()

sub main
  next = make_counter(100)
  print(next(1), next(10))
  handlers: Vec[*fun(Int) -> Int] = Vec()
  !handlers.push(<next)
  !handlers.push(*|x| x * 10)
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

sub main
  total: *Cell[Int] = *Cell(value: 0)
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

sub main
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

sub main
  print(boss_name(1), boss_name(2), boss_name(3))
```

```output
grace none none
```

An optional of an owning value (such as `*T?` from `upgrade()`) owns
what it holds. `if e as x` over a temporary gives `x` ownership, and it
is dropped at the end of the block. An optional held in a binding is
bound by moving or cloning it: `if <m as x`, `if +m as x`, and
unwrapped the same way: `(<m)?`. A borrow of an optional (`?m`, a
`?T?` parameter) cannot give up a resource it holds, so `as`, `?`, and
`??` reject it.

```rig reject
struct User
  name: String

sub main
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
function or of a function type (`fun(Int) -> Int!`, not for an owned
closure), and a plain `T` is accepted where `T!` is expected. `E!` for an error
set `E` is rejected: a failure and a success would both be `E` values.

```rig
fun parse_len(s: String) -> Int!
  s.len

fun double_len(s: String) -> Int!
  parse_len(s)! * 2

sub main
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

sub main
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
matched by their names (`.name =>`, with a `_` arm where the match
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
      _ => return "too long"
  "length ok" if n > 2 else "short"

sub main
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

pub fun origin -> Point
  Point(x: 0, y: 0)
```

```rig
use geo

fun total(p: ?geo.Point) -> Int
  p.sum()

sub main
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
and methods are visible wherever the struct is.

Another module's `pub` generic types and functions are used as local
ones are: `boxes.Wrap[Int]` names an instance in a type or an
expression, its type arguments are given or inferred, and its methods
and variants are reached through it. Each instance a module makes is
checked where it is made, against what the declaring module's bodies do
with its type parameters ([§4](#generic-bodies)), and a diagnostic
about it has a note at that body's line, in its file. An instance is
one type wherever it is reached from: `boxes.Wrap[Int]` spelled here is
the type another module's function returns as `boxes.Wrap[Int]`, even
through a module that does not import `boxes`. A public signature may
hold an instance of a private generic type, which importers hold and
use as they do a private type.

```rig file=boxes.rig
pub struct Wrap[T]
  v: T

  fun get(?self) -> T
    self.v

pub fun larger[T](a: T, b: T) -> T
  a if a > b else b
```

```rig
use boxes

fun unbox(b: ?boxes.Wrap[Int]) -> Int
  b.get()

sub main
  b = boxes.Wrap[Int](v: 3)
  s = boxes.Wrap(v: "s")
  print(unbox(?b), s.get(), boxes.larger(2, 7), boxes.larger[Float](1, 2))
```

```output
3 s 7 2.0
```

```rig file=stats.rig
pub fun mean[T](a: T, b: T) -> T
  (a + b) / 2
```

```rig reject
use stats

sub main
  print(stats.mean(4, 6), stats.mean("a", "b"))
```

```error
`stats.mean[String]` cannot use `T = String`: the generic body applies `+` to `T`, which `String` does not support
`+` used on `T` here (arithmetic)
```

Every check (types, arity, keyword
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

sub main
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
functions; `extern name: T` declares C data, which is an integer, a
float, or a `Bool`. Only integers, floats, and `Bool` cross the C boundary, and a C function
cannot return a Rig error union. An `extern` is visible to importers
only through `pub` wrappers.

```rig reject
extern fun abs(n: I32) -> I32

sub main
  print(abs(-5))
```

```error
call to extern function `abs` requires `raw` block
```

---

## 17. Compile-time parameters

Square brackets hold everything known at compile time, and
parentheses what is known when the program runs. A declaration lists
its compile-time parameters in brackets touching its name, before any
run-time parameters. In the list, a bare name is a **type parameter**
and `name: Type` a **compile-time value**:
`fun check[mode: Mode](n: Int) -> Bool`, `fun max[T](a: T, b: T) -> T`,
`sub rep[T, n: Int](x: T)`. Functions, `sub`s, methods, and associated
functions take both kinds; generic types take type parameters and
integer values ([generic types](#generic-types)); `main` takes none.
Each lowers to a Zig `comptime` parameter, a type parameter as
`comptime T: type`.

A type parameter needs a name of its own: not a built-in type (`Int`,
`Vec`, `Self`, ...), a module-level declaration, another parameter, or,
on a generic type, a method of the type; no local or parameter inside
the declaration may reuse it, and the same holds for a generic type's
value parameters. A compile-time value's type is a number, `Bool`,
`String`, an enum whose variants carry nothing, or an optional of one
of these, and it cannot mention a type parameter; on a generic type it
is an integer. An integer compile-time value sizes arrays
([arrays](#arrays)).

A call gives the compile-time arguments in brackets touching the
callee, before its run-time arguments: `check[.strict](5)`,
`rep[String, 3]("hi")`, `s.times[5]()`, `Scale.unit[6]()`,
`lib.scaled[3](5)`, `lib.zeros[3]()`. It gives all of them or none; a type argument, and
an integer value that an array length or a generic type's argument in
the signature holds, may be left to inference
([generic functions](#generic-functions)), any other value never. A
value argument must be known at compile time: a literal
(`none` included), an enum value, a module constant, a compile-time
parameter, a `=!` binding of one of these, or a comparison or `and`,
`or`, `not` of them. Arithmetic in a compile-time argument must fold to
a constant (`LIMIT * 2`), which is checked like constant arithmetic;
arithmetic on a compile-time parameter (`n + 1`), directly or through a
`=!` binding, is rejected, since each instance would compute it
unchecked. Inside a body, a compile-time value is an ordinary value, and
arithmetic on it is checked when it runs.

A function with no run-time parameters may leave out its parentheses in
its declaration (`sub show[n: Int]`), but a call always has them: the
brackets choose the instance and the parentheses call it,
`show[3]()`. A statement `show[3]` is rejected, as a statement `greet`
is. A function with compile-time parameters can only be called, never
used as a value.

```rig
enum Mode
  strict
  loose

LIMIT =! 5

fun check[mode: Mode](n: Int) -> Bool
  if mode == .strict
    n > 10
  else
    n > 0

fun either[mode: Mode](a: Int, b: Int) -> Bool
  check[mode](a) or check[mode](b)

sub show[n: Int]
  print(n * 2)

sub tag[T, loud: Bool](x: T)
  print(x, loud)

sub main
  print(check[.strict](5), check[.loose](5), either[.strict](3, 12))
  show[4]()
  show[LIMIT * 2]()
  tag[String, LIMIT > 3]("x")
```

```output
false true true
8
20
x true
```

```rig reject
sub show[n: Int]
  print(n)

sub outer[n: Int]
  show[n + 1]()

sub main
  k = 3
  show[k]()
  outer[1]()
```

```error
compile-time argument 1 of `show` must be known at compile time
compile-time argument 1 of `show` does arithmetic on a compile-time parameter
```

### Reading `x[...]`

The parser cannot tell `xs[0]` from `Vec[Int]` or `check[.strict]`, so
the checker decides by what `x` names. When it names a generic type or
a function, directly, through its module, through its type, or as a
method of a value, the brackets are compile-time arguments; otherwise
they index `x`. A bracket list of two or more is never an index, and
empty brackets are rejected. Written with a space, `show [3]` is a
paren-free call whose argument is the array `[3]`
([§2](#the-spacing-rule)).

In an expression, a type argument is written as a type that is also an
expression: a name, `module.Type`, `*T`, `~T`, `?T`, `!T`, `T?`, or an
instance (`Cell[Vec[Int]]()`). A slice, array, or function type has no
such spelling: name it with a type alias, or give the type where the
value goes (`b: Wrap[[3]Int] = Wrap(v: [4, 5, 6])`).

```rig
struct Wrap[T]
  v: T

type Row = [3]Int

fun double(n: Int) -> Int
  n * 2

sub main
  xs = [10, 20, 30]
  ops = [double, double]
  a = Wrap[Row](v: [1, 2, 3])
  print(xs[1], ops[0](4), a.v[2])
```

```output
20 8 3
```

```rig reject
struct Pair[T, U]
  a: T
  b: U

fun plain(n: Int) -> Int
  n

sub main
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
sub main
  v = Vec[[]Int]()
```

```error
a slice or array type has no expression spelling
```

In an expression, `*T?` as a type argument is an optional handle, as
in a type (`Cell[*Node?](value: none)`), and so is a chain of handles
such as `*~T?`. A handle to an optional,
`*(T?)`, has no expression spelling; name it with a `type` alias:

```rig
struct Node
  value: Int

type Held = *(Node?)

sub main
  a = Cell[*Node?](value: none)
  b = Cell[Held](value: *none)
  print(a.replace(none) == none)
  old = b.replace(*none)
  -old
```

```output
true
```

```rig reject
struct Node
  value: Int

sub main
  b = Cell[*(Node?)](value: *none)
```

```error
a handle to an optional has no expression spelling
```

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
| enum | `.green`, `.circle(r: 2.5)`, `.rect(w: 2, h: 3)`: payload fields by name, however it was built |
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

sub main
  u = User(name: "ada", age: 36)
  n: Int? = none
  print(u, n, ["a", "b"], 2.5)
```

```output
User(name: "ada", age: 36) none ["a", "b"] 2.5
```

```rig
enum Shape
  dot
  circle(r: Float)
  rect(w: Int, h: Int)

sub main
  print(Shape.dot, Shape.circle(2.5), Shape.rect(w: 2, h: 3))
```

```output
.dot .circle(r: 2.5) .rect(w: 2, h: 3)
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
| `try` blocks | `` `try` blocks are reserved `` |
| `zig "..."` | `` inline Zig is reserved `` |
| string and float match patterns | `` a pattern is a name, an integer, `true`, `false`, or an enum variant `` |

The rest parse, and the checker rejects them as not supported yet
([roadmap](docs/ROADMAP.md)):

| Form | Diagnostic |
|---|---|
| `drop` on an enum or a generic struct | `` `drop` bodies are only for non-generic structs `` |
| a stack closure passed, stored, or returned | `` closures cannot escape their defining scope `` |
| an array of owning values | `` arrays cannot hold values that own resources ``; use a `Vec` |
| an owned closure taking or returning an owning value | `` an owned closure takes plain Copy values `` |

```rig reject
sub main
  zig "return;"
```

```error
unexpected keyword `zig`
inline Zig is reserved
```
