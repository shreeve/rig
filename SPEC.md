# The Rig Language Reference

This is the reference for Rig as the compiler implements it today: what
each form means, and the rules `rig check` enforces. How each form is
written (layout, names, literals, operators and their precedence, and
the grammar) is in [SYNTAX.md](SYNTAX.md), and a guided start from
another language is [WELCOME.md](WELCOME.md). For the reasons behind
the rules, see [docs/DESIGN.md](docs/DESIGN.md); for what is not built
yet, see [docs/ROADMAP.md](docs/ROADMAP.md).

Every example is run by `./test/run`: a program followed by an `output`
block must print exactly that output with no leaks, and a program
marked as rejected must fail with the errors shown.

## Contents

1. [Programs](#1-programs)
2. [Types](#2-types)
3. [Declarations](#3-declarations)
4. [Bindings and assignment](#4-bindings-and-assignment)
5. [Expressions](#5-expressions)
6. [Control flow](#6-control-flow)
7. [Ownership](#7-ownership)
8. [Drop and drop glue](#8-drop-and-drop-glue)
9. [Shared and weak handles](#9-shared-and-weak-handles)
10. [Cell, Vec, Box, Text, and Signal](#10-cell-vec-box-text-and-signal)
11. [Closures](#11-closures)
12. [Optionals](#12-optionals)
13. [Errors](#13-errors)
14. [Modules](#14-modules)
15. [Raw code and FFI](#15-raw-code-and-ffi)
16. [Compile-time parameters](#16-compile-time-parameters)
17. [Printing](#17-printing)
18. [Reserved and unsupported forms](#18-reserved-and-unsupported-forms)

The standard library, imported with `use std.NAME`, is described in
[docs/STD.md](docs/STD.md).

---

## 1. Programs

A Rig program is a file of declarations: functions (`fun`, `sub`),
types (`struct`, `enum`, `error`, `type`), constants (`name = value`),
imports (`use`), `extern` declarations, and `test` blocks, written as
[SYNTAX.md](SYNTAX.md) shows. Statements live inside functions. A
program that runs declares its entry point as `sub main`, with no
parameters, or as `fun main -> Int`, whose value is the process's exit
status, from 0 to 255 (another value panics). Either may fail: `main`
may propagate an error with `!`, and `sub main!` or `fun main -> Int!`
may also return one; a failure that leaves `main` prints
`error: Set.name` and ends the program with status 1
([§13](#13-errors)). Everything `main` owns is dropped, its output
flushed, and the leak check run before the program exits. Only the
program calls `main`: Rig code cannot call it or use it as a value. The
program's arguments and environment are read through
[`std.os`](docs/STD.md#stdos).

```rig
fun main -> Int
  print("nothing to do")
  0
```

```output
nothing to do
```

`rig check` checks a program, `rig run` checks, builds, and runs it,
and `rig --help` lists the other commands (see also the
[README](README.md#build-and-run)).

`rig run` builds in Zig's debug mode with a leak-checking allocator: a program
that leaks memory reports it and exits with an error. Built with
`RIG_SANITIZE=1`, it also crashes at any use of freed memory. `--release` builds
in Zig's safe mode, and `--release=fast` in its fast mode. Integer
overflow, out-of-bounds indexing and slicing, and a numeric conversion
whose value does not fit panic in debug and safe builds.
The fast mode is the one outside that guarantee: it drops the
overflow and conversion checks, so there an overflow or an out-of-range
conversion is undefined behavior. Indexing and slicing stay checked in
every mode.

---

## 2. Types

### Primitive types

| Type | Meaning | Zig |
|---|---|---|
| `Int` | 64-bit signed integer, the same type as `I64`; the type of integer literals by default | `i64` |
| `Float` | 64-bit float, the same type as `F64`; the type of float literals by default | `f64` |
| `I8` `I16` `I32` `I64` `I128` | signed integers | `i8` ... `i128` |
| `U8` `U16` `U32` `U64` `U128` | unsigned integers | `u8` ... `u128` |
| `F32` `F64` | floats | `f32`, `f64` |
| `Bool` | `true` or `false` | `bool` |
| `String` | a view of text: bytes, UTF-8 by convention, that it does not own; a Copy value | `[]const u8` |
| `Void` | no value (what a `sub` returns) | `void` |

`Int` is `I64` and `Float` is `F64`: one type under two names. Every
other numeric type is distinct, and there are no implicit conversions.
A literal takes the numeric type its context expects, and must fit it
(a float literal, its range; an integer literal given a float type,
exactly). Constant arithmetic is checked at compile time. Arithmetic on
literals given a float type is computed in that type, so it rounds like
run-time arithmetic and must not overflow it: `x: F32 = 1e38 * 10.0` is
rejected.

A number type's `.min` and `.max` are its least and greatest values,
constants of that type, named through the type or an alias of it
(`type Byte = U8`, `Byte.max`, or another module's `lib.Byte.max`): `U8.max` is `255`, `Int.min` is
`-9223372036854775808`, and `U128.max` is `2^128 - 1`. A float's `.max`
is its greatest finite value and its `.min` the most negative one
(`-F64.max`), as in Rust. Constant arithmetic on them is checked, so
`U8.max + 1` is rejected.

```rig
sub main
  print(U8.max, I8.min, Int.max, U128.max, Float.min < 0.0)
```

```output
255 -128 9223372036854775807 340282366920938463463374607431768211455 true
```

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
`U8(x)`, `Float(n)`, `Int(f)`. An integer type's name also converts a
plain enum value to its integer value ([§3](#enums)). A conversion is checked. An integer that
does not fit the target type panics when the program runs, and so does
a float whose integer part does not fit, or a NaN; a float becomes an
integer by truncating toward zero, and `F32(x)` rounds (to an infinity when `x` is
too large). A constant integer converted to an integer type is
converted at compile time, so it must fit. (Inside `raw`, Zig's
unchecked cast builtins are also available,
[§15](#15-raw-code-and-ffi).)

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

A conversion to a float type rounds to the nearest value the type
holds, for a constant as it does at run time: `F32(16777217)` is
`16777216.0`. A constant assigned to a float type without a conversion
must be exact, so `a: F32 = 16777217` is rejected; write the
conversion to accept the rounding.

```rig
sub main
  n = 16777217
  print(F32(16777217), F32(n))
```

```output
16777216.0 16777216.0
```

```rig reject
sub main
  a: F32 = 16777217
```

```error
integer value `16777217` does not fit exactly in `F32`
```

A `String` has a length `s.len` and can be indexed (`s[0]`, or
`s.get(i)`, a `U8?` that is `none` past the end), and a `for` loop over
it yields its bytes as `U8`. Strings compare with `==` and
`!=` by content, and `<`, `<=`, `>`, `>=` order them by their bytes
([§5](#operators)).

A String is a view: it points at bytes it does not own. Those of a
literal, a module constant, or the program's arguments and environment
([std.os](docs/STD.md)) last as long as the program, so such a String
is free to copy anywhere. One taken from a `Text` (`?t[..]`) is a view
of the Text: the lend makes a loan on the Text, which the String
carries wherever it goes ([§10](#text)). The bytes are UTF-8 by convention, and nothing checks
it: lengths and indexes count bytes, and a slice checks only its
bounds.

### Arrays

`[N]T` is a fixed-size array. Its length is known at compile time: an
integer, a constant (`[LIMIT]T`, `[lib.N]T`), a compile-time integer
parameter (`[n]T` in `fun zeros[n: Int] -> [n]Int`,
[§16](#16-compile-time-parameters)), or arithmetic on integers and
constants with `+`, `-`, `*`, `/`, `%`, and parentheses
(`[LIMIT * 2 + 1]U8`). The arithmetic is checked as constant
arithmetic is, in its constants' type: with `W: U8 = 200`, `[W * 2]T`
overflows `U8`. A length runs from 0 to 4294967295, and one
given by a compile-time parameter is checked at each instance.
Arithmetic on a compile-time parameter (`[n + 1]T`) is rejected, as in
a compile-time argument. The length is a value, however it is written:
with `LIMIT = 4`, `[LIMIT]Int`, `[2 + 2]Int`, and `[4]Int` are one
type.

An array literal `[a, b, c]` takes its element type from its elements
(or from an annotation). `[n of x]` is an array of `n` copies of `x`,
where `n` is any compile-time integer, a compile-time parameter
included; it has the array type expected where it goes, or `[n]T` for
`x`'s type `T`. An array whose length is a compile-time parameter is
built with it. `xs.len` is an array's length, and `xs[i]` reads or
writes an element, with an index of any integer type; an index outside the half-open range `0..xs.len`
panics, and a constant one is rejected where the length is known.
`xs.get(i)` reads one as a `T?`, `none` when `i` is out of range, as a
Vec's does.
An array holds any value, as a Vec does, and drops its elements with
itself; `for x in <a` hands them over one at a time. `[n of x]`
copies `x` into every slot, so it needs a value that copies. An array
of arrays is `[2][3]T`:
two rows of three.

```rig
LIMIT = 4

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
  print(xs.get(1), xs.get(3), "hi".get(0))
```

```output
[5, 20, 30] 3 30 [1, 2] 6
[7, 7, 7, 7] 8 [[0, 0], [0, 0], [0, 0]] []
20 none 104
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
function, for the arrays it makes and, for a type, for itself. A
`Cell` or `Signal` holds its value inline, so it counts at the size of
what it holds. The values a function keeps on its stack take at most 16 MiB together: the
bindings it declares and its by-value parameters, each once, and every
array literal, fill, and call whose value no binding takes directly.
This holds for every function, method, closure (whose captures count
where it is made), test, and `main`, and for each instance of a
generic one. The stack holds 16 MiB, so a function that keeps more
could never run. Larger data belongs in a `Vec`, which keeps its
elements on the heap. A value or function too large is reported once;
a type or function holding a value too large is not reported again.

A program that runs off the end of its stack, by recursing too deeply,
stops before it writes beyond it. A program that cannot set up the
guard that ensures this stops before it runs, with `rig: cannot reserve
the stack guard below the main stack` and exit status 1
([INTERNALS](docs/INTERNALS.md) describes the mechanism).

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
`xs` like any `?` borrow ([§7](#7-ownership)), so `xs` cannot be
written, moved, or dropped while the slice is in use, and the slice
cannot outlive it. A `[]T` has `.len` and `get(i)`, is indexed and
iterated like an array, and is sliced again with `s[a..b]`, which views the same
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

A borrowed array parameter (`xs: ?[N]T`) points at the caller's array,
so a function may return a slice of it (`?xs[1..3]`) or a borrow of an
element, as it may of a `[]T` parameter; the result borrows the
caller's array. An array parameter taken by value (`xs: [N]T`) is the
function's own, so a borrow of it cannot be returned.

An array goes where a slice is expected in three ways. Where a `[]T`
is expected, `?a` of an array means `?a[..]`, and where a `![]T` is
expected, `!a` means `!a[..]`: the sigil shows the borrow, which is the
slice's. A Vec is lent the same way (`sort.sort(!v)`), and so is an
array or Vec in a box (`?b` of a `Box[[3]Int]`) or behind a read view
(a `?Vec[Int]` parameter passed where a `[]Int` is expected). As an
argument the `?` may go unwritten (`total(a)` lends `a` to read, as
`total(?a)` does, [Borrows](#borrows)); anywhere else, such as a
binding or a field, the lend is written. A temporary array, a literal,
a fill, or a call's result, passed as a `[]T` argument is lent as a
temporary of its statement: it lives until the statement ends, so a
call that returns a view of it is rejected where the view outlives the
statement; bind it to a name and pass `?a`.

```rig
fun total(xs: []Int) -> Int
  n = 0
  for x in xs
    n += x
  n

sub zero(s: ![]Int)
  !s.fill(0)

sub main
  a = [1, 2, 3]
  print(total(?a), total([4, 5]), total([3 of 2]))
  !a[..2].copy([7, 8])
  print(a)
  zero(!a)
  print(a)
```

```output
6 9 6
[7, 8, 3]
[0, 0, 0]
```

```rig reject
fun total(xs: []Int) -> Int
  xs.len

fun id(xs: []Int) -> []Int
  xs

sub main
  a = [1, 2, 3]
  print(total(a))
  s: []Int = a
  print(s)
```

```error
type mismatch: expected `[]Int`, got `[3]Int`; write `?a` or `?a[..]`
```

```rig reject
fun id(xs: []Int) -> []Int
  xs

sub main
  r = id([1, 2])
  print(r)
```

```error
a borrow of the temporary `[1, 2]` outlives its statement
```

`!xs[a..b]` is a **writable slice**, of type `![]T`: a write borrow of
the elements, taken of an array or a `Vec` that could be
write-borrowed (`!xs`), or of another `![]T`. A String and a `[]T` are
read-only, and so is what a fixed binding, a loop or pattern binding,
or a parameter other than a `!T` one holds. A `![]T` is a write borrow
like any other ([§7](#write-borrows)): while it is live, what it
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
write-borrowed: `!t` of one is rejected. A slice views any element
type, owning ones included.

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

```rig reject
sub main
  a = [1, 2, 3, 4]
  x = !a[..2]
  y = !a[2..]
  x[0] = y[0]
```

```error
cannot take a second write borrow on `a`
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

A recursive function passes on write slices of its own write slice:

```rig
sub quicksort(s: ![]Int)
  if s.len < 2
    return
  last = s.len - 1
  pivot = s[last]
  i = 0
  j = 0
  while j < last : j += 1
    if s[j] < pivot
      !s.swap(i, j)
      i += 1
  !s.swap(i, last)
  quicksort(!s[..i])
  quicksort(!s[i + 1..])

sub main
  a = [5, 3, 9, 1, 7]
  quicksort(!a[..])
  print(a)
```

```output
[1, 3, 5, 7, 9]
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
  v: Vec[Int] = Vec()
  !v.push(1)
  w = !v[..]
  !v.push(2)
  w[0] = 5
```

```error
use of `v` while a write borrow is live
```

```rig reject
sub main
  s = "text"
  t = !s[1..]
  t[0] = 65
```

```error
cannot write-borrow a slice of a String; a String is read-only
```

### Bytes

Bytes hold fixed-width numbers. `bytes.read[T, e](at)` is the integer
or float `T` stored in the `@sizeOf(T)` bytes from offset `at`, in byte
order `e`, and `!bytes.write[T, e](at, v)` stores `v` there. `T` is any
integer or float type, or a type parameter every instance gives one;
`e` is a compile-time value of the built-in enum
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
| `[]T` | slice: a read-only view of elements | [§2](#slices) |
| `![]T` | writable slice: a write borrow of elements | [§2](#slices) |
| `T?` | optional: a `T` or `none` | [§12](#12-optionals) |
| `T!` | fallible: a `T` or an error; only as a return type, including a function type's | [§13](#13-errors) |
| `?T` | read borrow of a `T` (parameters, returns, locals, fields) | [§7](#7-ownership) |
| `!T` | write borrow of a `T` | [§7](#7-ownership) |
| `*T` | shared handle: reference-counted, single-threaded | [§9](#9-shared-and-weak-handles) |
| `~T` | weak handle to a shared value | [§9](#9-shared-and-weak-handles) |
| `fun(A, B) -> R`, `sub(A)` | function and closure types | [§11](#11-closures) |
| `*fun(A) -> R`, `*sub(A)` | owned closure (a shared handle) | [§11](#11-closures) |
| `?fun(A) -> R`, `?sub(A)` | borrowed callable: a closure, function, or owned closure lent to a call | [§11](#closure-parameters) |
| `Cell[T]`, `Vec[T]`, `Box[T]`, `Signal[T]` | built-in generic types | [§10](#10-cell-vec-box-text-and-signal) |
| `Text` | owned, growable text | [§10](#text) |
| `Endian` | built-in enum: the byte order of `read` and `write` | [§2](#bytes) |
| `Name`, `Name[T]`, `mod.Name` | user types, generic instances, imported types | [§3](#3-declarations), [§14](#14-modules) |

How the sigils of a type combine (`*User?` is an optional handle,
`?User?` a borrow of an optional) is in
[SYNTAX §7](SYNTAX.md#7-types). A handle holds a value, never a
borrow: `*(?User)` is rejected.

### Copy values and owning values

A **Copy** value is plain data: numbers, `Bool`, `String`, plain enums,
and optionals, arrays, and structs that hold only Copy values.
Using one copies it. A copy of a String that views a Text carries the
Text's borrow ([§10](#text)).

An **owning** value holds a resource that must be released exactly
once: a `*T` or `~T` handle, a `Vec`, a `Box`, a `Text`, a `Signal`, an
owned closure, and any struct, enum, or generic instance that contains one or
declares a `drop` body. Owning values have **drop glue**: code the compiler
generates to release them. They move instead of copying, and the
ownership rules of [§7](#7-ownership) apply to them.

A **unique** value owns nothing to release but must not be copied: a
struct declared `unique` (`struct Random unique`, a generator whose
copy would repeat its numbers), a `Cell` (a copy would fork the state
it shares), or any struct, enum, array, or generic instance that holds
one of those inline. It moves like an owning value, has no
clone (`+x`) and no `==`, and nothing copies it out of a place; it has
no drop glue, so an array may hold it and a discarded one is simply
dropped. A loop that reads an array or slice of them binds a view of
each element (`?E`), never a copy.

```rig reject
struct Seed unique
  n: Int

sub main
  a = Seed(n: 1)
  b = a
  print(b.n)
```

```error
would copy a unique value; use `<a` to move it
```

---

## 3. Declarations

### Functions

`fun` declares a function that returns a value, and `sub` one that
does not ([SYNTAX §8](SYNTAX.md#functions)). A `fun` always has a
return type: a `fun` without `->`, or returning `Void`, is rejected in
favor of a `sub`. A `sub` marked `!`, `sub save(n: Int)!`, may fail,
and its type is `sub(Int)!` ([§13](#13-errors)). A function's value is
its last expression, or the value of a `return`. A call always has its
parentheses, `greet()`: the name alone is the function as a value.

Parameters are immutable, except a write-borrowed `!T` parameter, which
can be assigned ([§7](#write-borrows)). A parameter the body ignores
may be named `_`, any number of times. A parameter may have a default
value: a literal or a module constant (`LIMIT`, `lib.LIMIT`,
`U8.max`), which means the same value at every call, in any module. A
call passes arguments by position, by keyword, or both, positional
arguments first ([SYNTAX §11](SYNTAX.md#calls)). Each parameter gets
exactly one argument, and every parameter without a default needs one;
arity, keyword names, and argument types are checked. Arguments are
evaluated in the order written.

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
where a `fun(...)` or `sub(...)` is expected ([§11](#function-types)).

Declarations are only allowed at module level; there are no nested
functions (use a closure). Two module-level declarations may not share a
name.

### Structs

A `struct` lists its fields, then its methods. It is constructed by
naming its fields, `Point(x: 1, y: 2)`, and a struct with exactly one
field also takes it by position: `Meters(3.5)` is
`Meters(value: 3.5)`, as `Box(x)`, `Cell(0)`, and `*Signal(0)` are
([SYNTAX §11](SYNTAX.md#constructors)). A field may have a default
value, and a constructor may omit that field. Like a parameter default,
it is a literal (a number, a string, `true` / `false`, `none`, or
`.variant`) or a module constant, of this module or an imported one
(`LIMIT`, `lib.LIMIT`, `U8.max`); a field's may also be an empty or
literal constructor: `Vec()`, `Vec[T]()`, `Cell(0)`, or `[n of x]` with
a literal or constant `x`. Each value the constructor makes gets a fresh
default, so no two share a `Vec`.

```rig
RETRIES = 3

struct Config
  retries: Int = RETRIES
  name: String = "anon"
  tags: Vec[String] = Vec()
  hits: Cell[Int] = Cell(0)
  verbose: Bool

sub main
  c = Config(verbose: true)
  d = Config(retries: 5, verbose: false)
  !c.tags.push("x")
  c.hits.set(2)
  print(c.retries, c.name, d.retries, c.tags.len, d.tags.len, d.hits.get())
```

```output
3 anon 5 1 0 0
```

A method whose first parameter is `self` is an instance method;
without one it is an associated function, called through the type
(`Point.origin()`). `Self` names the enclosing type. The receiver says
how the method uses the value, and the call site says the same thing:

| Receiver | Meaning | Call |
|---|---|---|
| `?self` (= `self: ?Self`) | reads the value | `p.m()`, or `?p.m()`: the read borrow may be left implicit |
| `!self` (= `self: !Self`) | modifies the value | `!p.m()` |
| `<self` (= `self: Self`) | consumes the value | `<p.m()`, or on a temporary |

Write borrows and moves are never implicit, so calling a `!self` method
as `p.m()` is an error. That holds for a binding that already holds a
write borrow too (a `!T` parameter, `self` in a `!self` method, a local
`w = !p`): it lends that borrow visibly, `!w.m()` and `!self.m()`, as it
lends it to a `!T` parameter or field with `!w`. Lending a write borrow
always shows its sigil; a held read borrow is lent on bare, since
another copy of it changes nothing.

```rig reject
struct Counter
  n: Int

  sub bump(!self)
    self.n += 1

  sub twice(!self)
    !self.bump()
    self.bump()

sub main
  c = Counter(n: 0)
  !c.twice()
```

```error
write `!self.bump()`: the call writes `self`
```

A `?`, `!`, or `<` before a place and a method call marks the receiver:
`!v.push(x)` is `(!v).push(x)` ([SYNTAX §5](SYNTAX.md#receiver-sigils)).
Writing `?` is optional, since a read receiver is lent without it. The
short form is checked against the method: `!` before a method that
does not take `!self` is rejected (it reads as negation, which is
`not`), `<` before one that does not take `<self`, `?` before one that
takes `!self` or `<self`, and any of them before a function with no
receiver (`Point.origin()`). A
write call whose `Bool` value is used is written in the long form,
`(!set).insert(k)`, wherever the value goes (a condition, an operand,
a binding, an argument, a return value), so its `!` never reads as
negation. The short form stays for a call whose value is discarded: a
statement `!set.insert(k)`, alone or under `!` or `catch`.

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
  !t.insert(3)
  print(<t.total())
```

```output
true false
6
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
a write call whose `Bool` value is used is written `(!t).insert(...)`, so its `!` never reads as negation
```

```rig
struct Set
  items: Vec[Int]

  fun insert(!self, k: Int) -> Bool
    for x in ?self.items
      return false if x == k
    !self.items.push(k)
    true

sub main
  set = Set(items: Vec())
  if (!set).insert(1)
    print("new")
  if not (!set).insert(1)
    print("seen")
  print((!set).insert(2))
```

```output
new
seen
true
```

```rig
struct Counter
  n: Int

  sub bump(!self)
    self.n += 1

  sub bump_twice(!self)
    !self.bump()
    !self.bump()

sub add_three(c: !Counter)
  !c.bump()
  !c.bump_twice()

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
  f(!c)
  f(!c)

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

An `enum` lists variants, which may carry an explicit integer value or
payload fields, and may have methods ([SYNTAX §8](SYNTAX.md#enums)). A
variant is named `.name` where the enum type is known, or `Type.name`.
A payload variant is constructed with its fields named, like a struct,
and a variant with exactly one field also takes it by position:
`.circle(2)` is `.circle(radius: 2)`. A pattern binds the fields in
order (`.circle(r) =>`). Enums have no constructor call (`Shape(...)`
is an error), and compare with `==` ([§5](#operators)). A plain enum's variants may take
explicit values (`ok = 200`): constant integers from 0 to 4294967295,
no two the same, where a variant without one takes the value after the
previous variant's (the first, 0). Payload and generic enums take no
values.

An integer type's name converts a plain enum value to its value, as it
converts a number ([§2](#numeric-conversions)): `Int(st)`, `U16(d)`.
The conversion is checked: a variant named through its type
(`Status.missing`) must fit the target at compile time, and any other
value that does not fit panics when the program runs. A payload enum
has no integer values, and neither converts to a float directly.

```rig
enum Status
  ok = 200
  missing = 404

enum Dir
  north
  east

sub main
  st: Status = .missing
  print(Int(st), U16(Status.ok), U8(Dir.east))
```

```output
404 200 1
```

```rig reject
enum Shape
  dot
  circle(r: Int)

sub main
  s: Shape = .dot
  print(Int(s))
```

```error
`Int(x)` takes a plain enum's value; `Shape` has variants with payloads, which have no integer value
```

### Error sets

`error Name` declares a set of error values, which are used like the
variants of a plain enum ([§13](#13-errors)). Each error belongs to its
set: `A.timeout` and `B.timeout` of two sets, or of two modules, are
different errors.

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
([§16](#16-compile-time-parameters)): `struct Ring[T, n: Int]`. A value
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

A value parameter sizes a field's array and reads as a value in a
method; an instance's value argument may be arithmetic on constants,
and a constructor infers it from an array field:

```rig
LIMIT = 2

struct Ring[T, n: Int]
  items: [n]T
  head: Int = 0

  sub put(!self, x: T)
    self.items[self.head % n] = x
    self.head += 1

  fun cap(?self) -> Int
    n

sub main
  r = Ring(items: [3 of 0])
  !r.put(7)
  s: Ring[Int, LIMIT * 2] = Ring[Int, 2 + 2](items: [1, 2, 3, 4])
  print(r.items, r.cap(), s.cap())
```

```output
[7, 0, 0] 3 4
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
([§16](#16-compile-time-parameters)) makes it generic:
`fun max[T](a: T, b: T) -> T`. A `sub`, a method, and an associated
function take them too, and a method's own sit after its type's: a
method `fun map[U](?self, u: U)` of `Wrap[T]` has both.

A call gives every compile-time argument in brackets
(`max[Float](1, 2)`), or none. With none, they are inferred in this
order:

1. **From the arguments.** Each parameter's type is matched against
   its argument's type (`T`, `?T`, `!T`, `*T`, `~T`, `T?`, `[]T`,
   `[N]T`, `Wrap[T]`, `fun(T) -> U`, `?fun(T) -> U`), and a method's
   receiver gives its type's parameters. Every argument must agree, and
   an argument whose type does not have its parameter's shape is a type
   mismatch. An argument that is not a literal keeps the type it gives,
   even where the result is expected to have another.
2. **From closure literals**, matched after the other arguments: a
   closure's parameters take the types the other arguments give its
   parameter's function type, and the type its body returns binds what
   only the result mentions, so `map(?names[..], |s| s.len)` of
   `fun map[T, U](xs: []T, f: ?fun(?T) -> U) -> Vec[U]` is
   `map[String, Int]`.
3. **From the expected result.** A parameter that only literals give a
   type takes one from the type expected of the call's result, where
   there is one (a typed binding, parameter, field, or assigned place,
   a `return` from a function or from a closure whose result type is
   given, and the last expression of either), by matching the declared
   result against it the same way. A result lifted into an expected
   `T?` or `T!` is matched against the `T`, a propagated or caught `T!`
   against its value, and the left of `??` against an optional of the
   expected type. So `z: U8 = max(1, 2)` is `max[U8]`.
4. **Through nested calls.** A generic call that is an argument of
   another, and whose result is a type parameter only literals gave a
   type (directly, or propagated with `!` or `?`), takes the type that
   call gives it: `max(max(1, 2), small)` with `small: U8` is
   `max[U8]` twice. One whose result is an optional that nothing but
   `none` gave a type (`nothing()`, `id(none)`) binds like `none`, so
   `z: Int? = id(nothing())` is `id[Int?]`. A nested call with a result
   of another shape (`Wrap.make(1)`, `Opt.some(1)`) keeps the type its
   own arguments give it; naming the outer call's type arguments
   (`Wrap[Wrap[U8]].make(...)`, `id[Opt[U8]](...)`) passes the expected
   type on.
5. **From literals.** Only then does a literal take its default type,
   and among literals alone a float literal gives `Float`:
   `max(3, 2.5)` is `max[Float]`.

An integer compile-time value that a parameter's or the result's type
holds, as an array length (`[n]T`) or a generic type's value argument
(`Ring[T, n]`), is inferred the same way: `sum([1, 2, 3])` of
`fun sum[n: Int](xs: [n]Int)` is `sum[3]`, and `a: [3]Int = zeros()`
of `fun zeros[n: Int] -> [n]Int` is `zeros[3]`. It takes exactly the
length the argument's type has; arguments that give it different ones
conflict, and the value must fit the parameter's type. Any other
compile-time value is never inferred, so a function that takes one is
always called with brackets, and so is one with a type parameter that
none of these determine (one used only in the result where no type is
expected, or given only `none` or a `.variant`).

A generic function can only be called: it is not a value, and a closure
is never generic. Another module's generic function is called as a
local one is ([§14](#14-modules)).

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

```rig
fun max[T](a: T, b: T) -> T
  a if a > b else b

fun empty[T] -> Vec[T]
  Vec()

fun id[T](a: T) -> T
  a

fun nothing[T] -> T?
  none

fun half[T](x: T) -> T
  x / 2

sub main
  small: U8 = 200
  v: Vec[Int] = empty()
  !v.push(3)
  o: Int? = id(nothing())
  print(v.len, max(max(1, 2), small), o)
  f: Float = half(7)
  print(half(7), f, max(half(7), 2.5))
```

```output
1 200 none
3 3.5 3.5
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

A literal becomes a `T` only as an operand beside one (`x * 3`), and
must fit every instance's `T`; a binding annotated `T` takes a `T`,
not a literal (`y: T = 7` is a mismatch). Beside a `T`, a division of
whole-number literals divides integers, so `x * (3 / 2)` is `x * 1`, and
an instance whose `T` is a float is rejected rather than given `1.5`.

```rig reject
fun scale[T](x: T) -> T
  x * (3 / 2)

sub main
  print(scale(2), scale(2.0))
```

```error
`scale[Float]` cannot use `T = Float`: the generic body gives a `T` the division of whole numbers `3 / 2`, which divides integers, not a `Float`
```

The body is ownership-checked once, for a `T` that may own a resource
and holds no borrow. A `T` that owns a resource moves where the body
moves it, and is dropped where the body lets it go. Where the body
copies a `T`, every instance must be plain data; the same holds where it
takes (moves, drops, or returns) an element of a loop that does not
consume its collection (`for x in ?v`), or unwraps a `T` out of a
borrowed optional with `as`, since the collection or the owner still
holds the value. A type argument cannot be a borrow or hold one, for a
generic function or a generic type with methods: the parameter is
written `?T` or `!T` instead.

```rig
struct Track
  title: String

  drop(!self)
    print("free", self.title)

struct Shelf[T]
  items: Vec[T]

  sub add(!self, x: T)
    !self.items.push(<x)

  fun take(!self) -> T?
    !self.items.pop()

fun pick[T](a: T, b: T, first: Bool) -> T
  if first
    return <a
  <b

sub main
  t = pick(Track(title: "a"), Track(title: "b"), false)
  print("picked", t.title)
  s = Shelf[*Track](items: Vec())
  !s.add(*Track(title: "intro"))
  !s.add(*Track(title: "outro"))
  if !s.take() as last
    print("took", last.title)
  print("left", s.items.len, pick(1, 2, true))
```

```output
free a
picked b
took outro
free outro
left 1 1
free intro
free b
```

A body that calls itself, or builds its own type, with its type
parameters nested deeper each time (`nest[Wrap[T]]` inside `nest[T]`)
would need ever deeper instances, and is rejected rather than expanded
forever: at an instance, or, for a `pub` generic and the generic
methods of a `pub` type, whose instances other modules make, where it
is declared.

```rig reject
struct Point
  x: Int

fun max[T](a: T, b: T) -> T
  a if a > b else b

fun larger[T](a: ?T, b: !T) -> Bool
  a > b

sub main
  n = 3
  m = 4
  print(larger(?n, !m), max(true, false))
  p = max(Point(x: 1), Point(x: 2))
  q = Point(x: 3)
  print(p.x, larger(?p, !q))
```

```error
`max[Bool]` cannot use `T = Bool`: the generic body applies `>` to `T`, which `Bool` does not support
`>` used on `T` here (ordering comparison)
`max[Point]` cannot use `T = Point`: the generic body applies `>` to `T`, which `Point` does not support
`larger[Point]` cannot use `T = Point`: the generic body applies `>` to `T`, which `Point` does not support
```

```rig reject
struct Res
  n: Int

  drop(!self)
    print("drop", self.n)

struct Pair[A, B]
  first: A
  second: B

fun twice[T](x: T) -> Pair[T, T]
  Pair(first: x, second: x)

fun same[T](x: T) -> T
  x

sub main
  p = twice(Res(n: 1))
  r = Res(n: 2)
  q = same(?r)
  print(p.first.n, q.n)
```

```error
`twice[Res]` cannot use `T = Res`: the generic body copies a `T`, which would duplicate the resource `Res` owns
`T` copied here; move it with `<` instead
`same[?Res]` cannot use `T = ?Res`: a generic function is checked for a `T` that holds no borrow
```

### Type aliases

`type Name = T` gives a type a second name. An alias is transparent: it
is the same type as `T`. An alias names its type in every role, in this module or, when `pub`,
in another (`lib.Alias`). An alias of a struct or enum (this module's
or an imported one) constructs values, calls associated functions, and
names variants; one of a generic instance (`Wrap[Int]`, `Vec[Int]`,
`Cell[Int]`) constructs it as naming the instance does; one of a number
type converts to it (`Byte(x)`) and names its limits (`Byte.max`).
An alias is not a value, and an alias of any other type (`String`,
`Int?`) has no constructor.

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
type Byte = U8

fun next(b: Byte) -> Int
  Int(b) + 1

sub main
  p = P(x: 3, y: 4)
  o = P.origin()
  c = C.green
  n = 300
  print(p.x + o.x, c == .green, Byte(n - 100), Byte.max, next(7))
```

```output
3 true 200 255 8
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

A binding at module level is a constant, `name = value` or
`name: T = value`, and `pub` exports it. Its value must be known at
compile time: a literal, `.variant`, an earlier constant, or operators,
ternaries (`a if c else b`), and array literals over them. Every function and type in the module
reads it, wherever it is declared; nothing can reassign or move it,
and a local or parameter may not reuse its name (`new` shadows it on
purpose).
Arithmetic on constants alone is checked at compile time; with a value
known only when the program runs, it is checked then, like any other.

```rig
limit = 10
half = limit / 2
names = ["low", "high"]

fun over(n: Int) -> Bool
  n > limit

sub main
  print(limit, half, names[1], over(12))
```

```output
10 5 high true
```

There are no mutable module-level variables, so a module-level binding
needs no `const`, and one written with it is rejected:

```rig reject
const LIMIT = 4

sub main
  print(LIMIT)
```

```error
a module-level binding is already a constant; write `LIMIT = 4`
```

### Other declarations

`use` imports a module ([§14](#14-modules)), `pub` exports a
declaration ([§14](#14-modules)), and `extern` declares a C symbol
([§15](#15-raw-code-and-ffi)).

---

## 4. Bindings and assignment

The forms are in [SYNTAX §9](SYNTAX.md#9-bindings-and-assignment).
`x = e` binds a new local `x` when no `x` is visible, and otherwise
assigns the visible one: through it, when `x` holds a write borrow
([§7](#write-borrows)). `const x = e` binds a fixed local, which cannot
be reassigned. `_ = e` evaluates `e` and discards it, and an owning value
discarded so is dropped at once. A binding's type comes from its
annotation or its value.

A compound assignment `x op= e` stores `x op e` in `x`, finding the
place `x` once, and keeps its target's type: an arithmetic operator
needs a number, a bitwise operator or shift an integer, and a shift
amount may be any integer. Each behaves like its operator
([§5](#operators)): `/=` truncates, `%=` takes the dividend's sign, and
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

An assignment evaluates its value first, then the indexes of its
target from left to right (the outermost index first), and only then finds the place and stores
into it; a compound assignment reads the place there, combines, and
writes it back. A call on the right that grows the Vec an element is
in, or replaces the value a field is in, is safe: the store lands in
the value as the call left it, and panics if the element is gone.

```rig
fun grow(v: !Vec[Int]) -> Int
  !v.push(v.len)
  v.len

fun at(i: Int, what: String) -> Int
  print(what)
  i

sub main
  v: Vec[Int] = Vec()
  !v.push(0)
  v[0] = grow(!v)
  v[at(1, "index")] += at(10, "value")
  n = 1
  n += grow(!v)
  print(v, n)
```

```output
value
index
[2, 11, 2] 4
```

There is no implicit shadowing. A local may not reuse the name of a
visible local, parameter, or module-level declaration, and `const x =
e` always declares. To reuse a name on purpose, write `new`:

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

`new` takes the other binding forms too: `new x: T = e`, and `new
const x = e`, which shadows with a fixed local.

```rig
sub main
  const limit = 3
  new const limit = limit * 2
  n = 7
  new n: U8 = U8(n)
  print(limit, n)
```

```output
6 7
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
([§8](#8-drop-and-drop-glue)) is read by its own release, so a local
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

## 5. Expressions

### Operators

The operators and their precedence are in
[SYNTAX §6](SYNTAX.md#6-operators-and-precedence). A receiver sigil
applies to a method's receiver ([§3](#structs)); a call of a field
holding functions (`!p.f()`, `!p.fs[0]()`) has no receiver, so a sigil
there is rejected.

Arithmetic needs numeric operands of one type (a literal adapts to the
other operand). Integer `/` truncates toward zero and `%` takes the sign
of the dividend, so `(a / b) * b + a % b == a`. A literal takes the type
its context expects through `+`, `-`, and `*`, so `h: Float = 2 * 3` is
`6.0`, but not through `/` and `%`: a division of whole-number literals
divides integers, `x = 7 / 2` is `3`, and where its value would be a
float (`h: Float = 7 / 2`, `7 / 2 + 1.5`) it is rejected, since it would
silently be `3.0`. A float literal makes it a float division:
`7.0 / 2` is `3.5`. In arithmetic over a type parameter `T`, integer
literals take `T`'s type in each instance, and an instance whose `T` is
a float is rejected where the body gives a `T` a whole-number division
(`self.v + 1 / 2`). Unsigned values cannot be negated.

```rig
sub main
  x = 7 / 2
  h: Float = 7.0 / 2
  k: Float = 2 * 3
  print(x, h, k, -7 % 3)
```

```output
3 3.5 6.0 -1
```

```rig reject
sub main
  h: Float = 7 / 2
  print(h)
```

```error
`7 / 2` divides whole numbers (3); for 3.5 write `7.0 / 2`
```

Bitwise operators need integers; a shift amount may be any
integer, from 0 up to the width of the shifted type. A left shift that
loses bits (or the sign) overflows: a constant one is rejected, and one
computed when the program runs panics, like `+` and `*`.

`+%`, `-%`, and `*%` are wrapping arithmetic, as in Zig: on overflow
the result wraps around in two's complement, keeping the low bits in
the operands' integer type, and never panics. They take integers of
any type; a `Float` is rejected, as is a literal operand that would
take a float type or a type parameter a float fills. The same holds
for the integer operators `&`, `|`, `^`, `<<`, and `>>`. `+%=`, `-%=`, and `*%=` assign the
wrapped result. Constant wrapping arithmetic is computed in its type,
as the program computes it.

```rig
fun fnv1a(s: String) -> U64
  h: U64 = 14695981039346656037
  for b in s
    h ^= U64(b)
    h *%= 1099511628211
  h

sub main
  a: U8 = 250
  i: I8 = 127
  print(a +% 10, a -% 255, i +% 1, fnv1a("rig"))
```

```output
4 251 -128 9948945366585317705
```

```rig reject
sub main
  x = 1.5
  print(x +% 1.0)
```

```error
operator `+%` requires integer operands; got `Float`
```

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
  maybe: Point? = b
  print(a == b, s == .dot(at: Point(x: 2, y: 1)), found == none, [a] == [b], a == maybe)
  print("abc" < "abd", "ab" < "abc", "b" <= "a", "Zoo" < "apple")
```

```output
true false true true true
true true false true
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

`and`, `or`, and `not` take `Bool`s, and `and` and `or` short-circuit:
the right side runs only when the left does not decide. The spellings
`&&` and `||` are rejected with a hint. Prefix `!` is always a write borrow, never
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

A statement `-x` drops `x`; `-x` where a value is expected negates.
A value is expected in an operand, an argument, a binding's value, a
`break` value, and on the last line of a `fun` (the function's value)
or of a branch (a loop's `else` block too) whose value is used, so `-x` there is negation, and one whose `x` is not a
number is rejected with a pointer to dropping it before the last line.
Only a binding is dropped: a statement `-s.f` or `-v[i]` is rejected,
and so is any other statement `-e`, such as `-f()` or `-(a + b)`, which
would negate a value and discard it.

```rig reject
struct S
  r: Vec[Int]

sub main
  s = S(r: Vec())
  -s.r
```

```error
only a binding is dropped with `-x`
```

A statement must have some use. An expression whose value is used (the
last line of a `fun`, a binding, an argument) may be anything, but one
whose value would be thrown away must do something: call, propagate
(`e!`, `e?`), or `catch`. A name, literal, field read, or borrow alone on
a line has no use and is rejected, and a function name alone is taken
for a forgotten call.

```rig
sub greet
  print("hi")

fun pick -> sub()
  greet

sub main
  greet()
  say = pick()
  say()
```

```output
hi
hi
```

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
block ([§15](#15-raw-code-and-ffi)). Rig type names are translated
(`@sizeOf(I64)` is 8).

---

## 6. Control flow

The forms of each statement are in
[SYNTAX §10](SYNTAX.md#10-statements-and-control-flow); this section
says what they do.

### if

Conditions must be `Bool`. `if e as name` tests an optional and binds
its value ([§12](#12-optionals)), and bindings join with `and`
([Joined bindings](#joined-bindings)).

### Guards

A simple statement (a call, a binding or assignment, a drop, `return`,
`break`, or `continue`) that ends with a guard, `if cond`, runs only
when `cond` holds. The guard covers the whole statement, a `catch`
handler included ([SYNTAX §10](SYNTAX.md#guards)).

### while

`while cond` repeats its block. `while cond : step` runs `step`, an
assignment or a call (which may propagate, `f()!`), after each
iteration (including after `continue`). `while e as x` repeats
while the optional `e` has a value. A jump in the condition or the step
(`?? break`, `catch continue`, [§12](#the-fallback-of-)) targets this
loop: `break` leaves it, `continue` in the condition runs the step and
tests again, and `continue` in the step ends the step. An `else` block runs when the loop
ends without `break`, after the loop: a `break` or `continue` in it
leaves the loop around this one. A loop can also yield a value
([Loops as values](#loops-as-values)).

### for

`for x in source` walks an array, a slice, a `String` (bytes), or a
range `a..b` (from `a` up to, not including, `b`; the bounds are
evaluated once). `for x, i in xs` also binds the index (not for
ranges); the element comes first, the reverse of Python's
`enumerate`, and where a loop written index first gives a binding the
other's type, the error says so. An `else` block runs when the loop ends without `break`. A
source that is a place is walked where it stands: `for x in v` is
`for x in ?v`, which lends `v` to read for the whole loop ([§10](#vec)),
so an element of plain data is a copy and any other element a view of
its slot (`?E`). A value the source makes is taken: a Vec a call
returns is consumed, and an array made there whose elements move is
held for the loop, which owns its elements. A part of a value made
there (`mk().items`) is walked in that value, which the loop holds
until it ends.

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
  `v` must own the Vec: through a borrow, loop over `?v` or `!v`.

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

A Vec source is a place, which the loop walks in place, or a value made
there (a call, or a branching value whose every branch is made there),
whose new Vec the loop consumes as `<v` does. A branching value that
may be a name's (`o?`, `a if c else b`) could be a place on one path
and a new Vec on another, so it is bound to a name first:

```rig reject
sub main
  a: Vec[Int] = Vec()
  b: Vec[Int] = Vec()
  for e in ?(a if a.len > 0 else b)
    print(e)
```

```error
a `for` walks a Vec held in a place or made by a call: bind this `Vec[Int]` to a name first
```

### Labels, break, and continue

A loop may be labeled `:name`; `break :name` and `continue :name` then
refer to it from an inner loop. A `match` or `raw` statement may be
labeled too, and `break :name` leaves it. No other statement takes a
label, since no jump could use it, and none takes two. A jump after `??` or `catch`
may name a label too ([§12](#the-fallback-of-)). A label may repeat an
enclosing one's name; the innermost is meant.

```rig reject
sub main
  n = 3
  :done if n > 1
    print(n)
```

```error
a label names a loop, `match`, or `raw` block that `break` or `continue` can leave; `:done` cannot label an `if`
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

### match

`match` runs the first arm whose pattern matches, and no other. It works
on enums, integers, `Bool`, and error values (`catch |err|`,
[§13](#naming-the-error)); [SYNTAX §12](SYNTAX.md#12-patterns) lists
the patterns. A range pattern's bounds are constants. Every match must
cover every value, whether its value is used
or it is a statement: its arms name every variant or value, or a
catch-all (`_`, or a name) covers the rest. Duplicate and unreachable
arms are rejected. An arm with no work to do is `_ => pass`
([pass](#pass)).

A guard `if cond` after a pattern is a `Bool` that may read the
pattern's bindings; when it is false, the later arms are tried, as if
the arm's pattern had not matched. A guard changes nothing it matches:
it moves nothing, and write-borrows neither the matched value nor a
binding of the arm (as Rust's guards do not). A guarded arm covers none
of its values: a later arm may repeat its pattern, and
the match still needs arms for them. Alternatives
are literals, ranges, or variants; since which one matched would decide
what a name held, they bind none (`_` fills a payload field), and none
may be a catch-all.

```rig
enum Shape
  circle(r: Int)
  square(s: Int)
  point

fun describe(s: Shape) -> String
  match s
    .circle(r) if r > 10 => "big circle"
    .circle(_), .square(_) => "small shape"
    .point => "point"

sub main
  print(describe(.circle(r: 20)), describe(.square(s: 1)), describe(.point))
  match 4
    1, 2, 3 => print("low")
    n if n % 2 == 0 => print("even", n)
    _ => print("other")
```

```output
big circle small shape point
even 4
```

A range pattern is half-open like every range, so `0..10` matches 0
through 9, and its end may be one past the type's largest value:
`100..256` covers the rest of a `U8`.

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

The subject takes the sigil of what the arms do with it, as a `for`
source and `if … as` do:

| Subject | Payload bindings |
|---|---|
| `match e`, `match ?e` | read the fields: a copy of plain data, a read view of anything else |
| `match !e` | write borrows of the fields: assigning one writes the field in place |
| `match <e` | own the fields: `e` is consumed, and what an arm does not move on is dropped at the end of the arm |

A bare `match e` of a place only reads it, so moving a payload out of
it is rejected; that takes `match <e`. A call's result is taken, as
`match <e` would take it ([§7](#temporaries)): `match make()` owns its
payloads. Its bindings only read, too, even of a
field or value that is itself a write borrow. A binding of `match <e`
owns what it binds: a resource it holds may be written and lent for
writing. A `Bool` is not matched with `!`: `match !flag` reads as
negation and is rejected, as `!flag` is anywhere a `!Bool` is not
expected. `match !e` needs a place that may be
written, as `!e` does, and while one of its bindings is live `e` cannot
be used otherwise. `match <e` needs a value `e` owns, not a borrow. A
boxed enum is matched where the box holds it, `match b` (as `match ?b`)
or `match !b` ([§10](#box)), and so is the value a handle holds,
`match h`, which reads it. A read binding that is not plain data is a
view (`?F`) of the field where it is, and it is usable within its arm
only: it may be read, lent to a call, and have its `Cell` changed there,
but a view of it is not returned, stored past the arm, or given as the
match's value ("a view of `r` does not outlive the `match` that reads
`e`"); copy what it holds (`+r`, or a plain field), or take the subject
with `match <e`. A match on a part of a value made there (`match mk().e`)
holds that value until the match ends when the part is not plain data,
so its payloads are read where they are; a part of plain data is read
in the header, whose temporaries end with it.

```rig
struct B
  n: Int

  drop(!self)
    print("drop", self.n)

enum Slot
  full(b: *B, uses: Int)
  empty

sub keep(b: *B)
  print("kept", b.n)

sub main
  s: Slot = .full(b: *B(n: 1), uses: 0)
  match !s
    .full(_, uses) => uses += 1
    .empty => print("empty")
  match s
    .full(b, uses) => print(b.n, uses)
    .empty => print("empty")
  match <s
    .full(b, _) => keep(<b)
    .empty => print("empty")
  print("end")
```

```output
1 1
kept 1
drop 1
end
```

```rig reject
struct B
  n: Int

  drop(!self)
    print("drop", self.n)

enum Slot
  full(b: *B)
  empty

sub keep(b: *B)
  print("kept", b.n)

sub main
  s: Slot = .full(b: *B(n: 1))
  match s
    .full(b) => keep(<b)
    .empty => print("empty")
```

```error
cannot move `b` out of `s`: `match s` reads `s`; write `match <s` to take its fields
```

```rig reject
struct Res
  n: Int
  t: Text

enum E
  a(r: Res)
  b(r: Res)

fun inner(e: ?E) -> ?Res
  match e
    .a(r) => ?r
    .b(r) => ?r

fun name(e: ?E) -> String
  match e
    .a(r) => ?r.t
    .b(r) => ?r.t

sub main
  e = E.a(r: Res(n: 1, t: Text("hi")))
  print(name(?e), inner(?e).n)
```

```error
a view of `r` does not outlive the `match` that reads `e`: use it in the arm, copy what it holds (`+r`), or take the subject with `match <e`
```

### pass

`pass` is a statement that does nothing. It stands where a statement
is needed and there is no work: a match arm (`_ => pass`), a loop
body, an `if` branch, or a function body. It has no value, so a match
arm, branch, or block whose value is used cannot end with it.

```rig
sub main
  n = 4
  match n % 2
    0 => print("even")
    _ => pass
  if n > 10
    pass
  else
    print("small")
```

```output
even
small
```

```rig reject
fun sign(n: Int) -> Int
  match n
    0 => pass
    _ => 1

sub main
  print(sign(0))
```

```error
`pass` does nothing and has no value
```

### defer and errdefer

`defer stmt` (or `defer` with a block) runs when the enclosing block
exits, in reverse order of the defers. `errdefer` runs only when the
function exits with an error, so it is written only where one can: in
a `fun ... -> T!`, a `sub f()!`, `sub main`, a closure whose type can
fail, or a test. In a function, closure, or `drop` body that cannot
fail, or inside deferred code, it is rejected: write `defer`. A deferred body may not move or drop
outer bindings, or propagate with `!`. It runs after the values declared
after it are dropped, so it may not read one through a borrow. A
one-line `defer` or `errdefer` cannot declare a name; a deferred block
can.

```rig reject
sub main
  s = 1
  defer t = s
  print(s)
```

```error
a deferred statement runs at scope exit and cannot declare `t`; use an indented `defer` block
```

```rig reject
sub log(n: Int)
  errdefer print("failed")
  print(n)

sub main
  log(1)
```

```error
`errdefer` runs only when the function fails, and `log` cannot fail; use `defer`
```

---

## 7. Ownership

[docs/CORE.md](docs/CORE.md) is the summary this section derives from:
the whole ownership model in ten sentences, with each rule marked built
or planned.

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
| `*x` | share | move `x` into a new shared box ([§9](#9-shared-and-weak-handles)) |
| `~x` | weak | a weak handle to a shared value ([§9](#9-shared-and-weak-handles)) |

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
  id: Int

  drop(!self)
    print("released", self.id)

sub send(p: Packet)
  print("sent", p.id)

fun make(id: Int) -> Packet
  p = Packet(id: id)
  p

sub main
  p = make(1)
  send(<p)
  p = make(2)      # reassigning makes `p` usable again
  q = <p
  print(q.id)
```

```output
sent 1
released 1
2
released 2
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
(the struct would still drop it); clone a shared field with `+p.a`,
move the struct as a whole, or exchange the field with `replace` or
`swap` ([below](#replace-and-swap)). A Copy field can be read or copied
freely.

An optional field or element is the exception (an element only of a
plain optional, since no Vec or array holds one that owns): `<p.f` **takes** the
value out and leaves `none` behind, in one step, so the struct stays
whole and nothing is dropped twice. Taking writes the field, so it
needs a path that may write it (an owned local, a `!T`, not a `?T` or a
`*T`), and no other borrow of the value may be live, and it needs an
owner: a field of a temporary cannot be taken. Whether a field can be
taken is decided by its type where it is named: inside a generic body a
`T?` field can be, a `T` field cannot, whatever `T` is. An `as` binding
that owns a resource moved into it (`if <o as n`) has fields that can
be written and taken, like a local's. A local binding is still moved
whole: `<x` leaves `x` unusable, never `none`. Only a binding or a
field is moved or taken: `<(a if c else b)` and `<o?` are rejected, and
written `<a if c else <b` and `(<o)?`.

```rig
struct Node
  value: Int
  next: Box[Node]?

struct Stack
  top: Box[Node]?

  sub push(!self, v: Int)
    self.top = Box(Node(value: v, next: <self.top))

  fun pop(!self) -> Int?
    if <self.top as n
      self.top = <n.next
      return n.value
    none

  sub reverse(!self)
    cur = <self.top
    prev: Box[Node]? = none
    while <cur as n
      cur = <n.next
      n.next = <prev
      prev = <n
    self.top = <prev

sub main
  s = Stack(top: none)
  for v in [1, 2, 3]
    !s.push(v)
  !s.reverse()
  print(!s.pop(), !s.pop(), !s.pop(), !s.pop())
```

```output
1 2 3 none
```

#### Replace and swap

`replace(!place, v)` stores `v` in a place and hands back the value that
was there, owned; `swap(!a, !b)` exchanges the values of two places of
one type, which may be different fields of one value
(`swap(!t.left, !t.right)`). The places are write-borrowed for the call,
and the values hold no borrow. Like `print`, both are names a
declaration may hide.

```rig
struct Pair
  left: String
  right: String

sub main
  p = Pair(left: "a", right: "b")
  swap(!p.left, !p.right)
  old = replace(!p.left, "c")
  print(p, old)
```

```output
Pair(left: "c", right: "a") b
```

Two elements of one collection are not two places: `swap(!a[i],
!a[j])` write-borrows `a` twice, and is rejected with the collection's
own `swap`, which exchanges them ([§2](#slices)):

```rig reject
sub main
  a = [1, 2, 3]
  swap(!a[0], !a[2])
  print(a)
```

```error
cannot take a second write borrow on `a`: to swap two elements of `a`, write `!a.swap(0, 2)`
```

A payload binding of `match <s` owns its field and may move it on
(`.full(b) => eat(<b)`); a bare `match s` only reads `s`
([match](#match)).

### Borrows

A borrow lends a value without giving it up. `?x` is a read borrow and
`!x` a write borrow, and borrowed parameter types say the same thing:
`b: ?Wrap` reads, `b: !Wrap` writes. A write borrow is always visible
at the call site; a read borrow of an argument may go unwritten: where
a parameter takes a view, a bare argument is lent to read where it is,
as `?x` would lend it, and its owner stays lent for as long as the
view is used (`balance_of(acct)` is `balance_of(?acct)`). A value made
there (`balance_of(open())`) is lent as a temporary of its statement.
A lend kept in a binding or a field is always written.

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
live the owner cannot be used at all, whatever its type: even a number
is not read until the borrow's last use, so `w = !n` then `w += n` is
rejected.

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

**Evaluation order within a call.** A call evaluates its arguments
left to right and uses them all when it runs, so what an earlier
argument holds is still in use while the later ones are evaluated. A
borrow (`?v`) or a slice (`?v[..]`) in an earlier argument keeps its
loan until the call ends. So does an argument that reads a place by
value when that value shares storage the place owns: a Vec, a `Box`, a
`*T` or `~T` handle, a struct holding one, or what a write borrow
reaches, as `print(v)` reads it. A later argument of the same call
(`print` included) cannot write-borrow or move that place, since the
call would see a stale value, or memory already freed. Plain data is
copied whole when it is read, so `print(v.len, grow(!v))` and
`print(p, bump(!p))` for a Copy struct `p` are accepted, and print the
values as they were read. A write receiver's arguments may read it,
`!v.push(v.len)`, since they finish before the call writes.

```rig
struct P
  x: Int

fun grow(v: !Vec[Int]) -> Int
  !v.push(7)
  v.len

fun bump(p: !P) -> Int
  p.x += 1
  p.x

sub main
  v: Vec[Int] = Vec()
  !v.push(v.len)
  print(v.len, grow(!v), v)
  p = P(x: 1)
  print(p, bump(!p), p)
```

```output
1 2 [0, 7]
P(x: 1) 2 P(x: 2)
```

```rig reject
fun grow(v: !Vec[Int]) -> Int
  !v.push(7)
  v.len

sub main
  v: Vec[Int] = Vec()
  print(v, grow(!v))
```

```error
cannot write-borrow `v` while an earlier argument's read of it is in use
```

The same holds wherever a value is read in place before a later
operand of the same form runs: a read receiver that is no place
(`(a if c else b).peek(!a)`), the value a call calls (`h.f(reset(!h))`
for an owned closure in a field), the left operand of `==`, `!=`, or an
ordering operator while its right operand runs, and a value that is no
place while its index runs. A later operand cannot lend that place to
write or move it. `grow(!a) == a` is accepted: the write finishes
before `a` is read.

```rig reject
fun grow(t: !Text) -> Text
  !t.add("more")
  Text("x")

sub main
  a = Text("a")
  print(a == grow(!a))
```

```error
cannot lend `a` to write while the left operand's read of it is in use
```

A borrow of a place (`!v[i]`, `?p.xs[i]`, a slice `!v[i..]`, or the
receiver of a method call) finds the place up to each index before the
index runs, so an index cannot write-borrow or move the place's root:
it could grow or free the memory the place is in. An assignment finds
its target only after the indexes run ([§4](#4-bindings-and-assignment)),
so `v[grow(!v)] = 1` is accepted.

```rig reject
struct P
  a: [4]Int

fun grow(v: !Vec[P]) -> Int
  !v.push(P(a: [0, 0, 0, 0]))
  1

sub set(n: !Int)
  n = 9

sub main
  ps: Vec[P] = Vec()
  !ps.push(P(a: [1, 2, 3, 4]))
  set(!ps[0].a[grow(!ps)])
```

```error
cannot write-borrow `ps` in an index of a place borrowed from it
```

#### Write borrows

A write borrow is assignable, whether a `!T` parameter or a local
holding one: `p.f = v`, `p = v`, and `p += 1` write through to the
borrowed value (the old value is dropped first). Assigning a view
points the place at another place instead: `w = !m`, `w = <w2`, or a
call returning a `!T` re-points a local `w`, which then lends `m`
alone (a `![]T` local alike), and a bare `w = w2` reads the value `w2`
reaches and writes it through `w`. A parameter is never re-pointed:
`w = !m` of a `!T` parameter is rejected, and `new w = !m` binds a new
name instead. A field or element of type `!T` follows the same rule:
`h.w = 5`, `h.w += 1`, `xs[i] += 1`, and `h.w = w2` write the
value the place borrows, while assigning another write borrow,
`h.w = !m`, points the place at `m`. Writing through a borrow held in
a field, or lending it with `!h.w`, needs write access to the struct,
as writing any field does, so a plain parameter `h: H`, a capture, or
a temporary cannot. A write borrow can be
lent on, written `!p` as an owned value's borrow is, or moved into a
local with `<p`, but not copied. A bare `w` of type `!Int` where an
`Int` goes copies the value it reaches (`x = w`), and so does one
assigned to a `!Int` place (`h.w = w`); `h.w = <w` moves the borrow
there instead. One held
in a field is read-only through a `?T` or `*T`, like the rest of what
that path reaches: it cannot be written through or passed on from
there, and a `match` through one cannot bind it. A loop walks elements
whose fields hold write borrows with `for x in !xs`; an element that
is itself a write borrow (in a `[2]!Int`) is written by index,
`xs[i] = v`, since a loop binding cannot hold it.

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

```rig
sub main
  n = 1
  w = !n
  w = 5
  w += 1
  m = 10
  new w = !m
  w *= 2
  print(n, m)
```

```output
6 20
```

```rig
struct Tally
  count: !Int

  sub add(!self, k: Int)
    self.count += k

sub main
  n = 0
  m = 100
  t = Tally(count: !n)
  t.count += 1
  !t.add(2)
  t.count = t.count * 10
  t.count = !m
  t.count += 1
  print(n, m)
  xs = [!n, !m]
  for i in 0..xs.len
    xs[i] += 1
  print(n, m)
```

```output
30 101
31 102
```

```rig reject
struct Tally
  count: !Int

sub peek(t: ?Tally)
  t.count += 1

sub main
  n = 0
  t = Tally(count: !n)
  peek(?t)
```

```error
cannot write through the write borrow held here through a read borrow (`?T`)
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
  The result then borrows from every argument whose type could hold
  what it views, a String argument included: it may view a Text
  ([§10](#text)). An argument that could not (an `Int` key for a
  `?Item` result, a String for a `?Item`) is free again after the call.
- A view reached through another view borrows what that view borrows,
  not what holds it: `?c.items[0]`, with `items: ?Vec[Item]`, borrows
  the Vec, not `c`.
- A struct holding a borrow keeps the borrowed value borrowed while the
  struct is alive. So does a stack closure that captured a borrow, and
  a value a call may have stored a borrow into (its receiver lent to
  write, and what its `!` arguments and other write borrows lead to):
  a borrow of each argument, the receiver among them, whose type could
  be held there.
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
count; for a Copy value it copies; for a Text, a Vec, a box, an
optional, an array, or a struct or enum declared in the module that
holds them, it clones each part the same way: a Text's bytes and a
Vec's elements are copied, a box's value is boxed again, and a handle
inside is counted again (a deep copy). A type with a `drop` body, a
unique type (one holding a `Cell`, or declared `unique`), a `Signal`,
and a type imported from another module have no clone. `+p.a` clones
the value in a field, and `+v[i]` an element. A value holding a write
borrow cannot be cloned or weakly referenced: the borrow is unique.
`+e` only reads `e`: a value made there (`+make()`) is a temporary its
statement drops, and `+(a if c else b)` reads `a` or `b` where it is.

### Drop

`-x` as a statement releases `x` now; afterwards `x` cannot be used.
Every owning local and parameter that is still live is dropped
automatically when its block ends, including on early `return`,
`break`, and `continue`, and on every path through branches. So `-x`
is only needed to release something early, or to end a borrow a
binding holds. A borrowed parameter cannot be dropped: the caller owns
it. Plain data owns nothing, so `-n` of an `Int` or a struct of
numbers drops nothing, and is rejected. A String may view a `Text`
(§10), so `-s` of a String, or of a struct holding one, ends the loan
it carries.

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

An expression either **takes** its value or only **reads** it. A
binding, an argument to a parameter that owns it, `return`, a stored
field or element, and `<` take. A `print` or `Text(...)` argument, an
`==` operand, `?e`, a `?self` receiver, and a field or element read
only read. Reading never moves a name, whatever form reads it: a read
passes through `a if c else b`, `??`, `catch`, `e!`, and `e?` to their
operands, so `print(a if c else b)` reads `a` or `b` where it is and
moves nothing.

A value made where it is only read (a call's result, a constructor's
included, `+x`, `<x`, or a block or `match` value) has no name: its
statement is its scope, so it is a **temporary**. One that owns a
resource is dropped when its statement ends, last made first, also
when the statement fails (`!`) or leaves early (`?? return`). A
temporary that nothing reads or takes (an expression statement, the
receiver of a `!self` method, whose change would be lost) is rejected:
bind it to a name first.

```rig
struct B
  n: Int

  drop(!self)
    print("drop", self.n)

fun size(s: String) -> Int
  s.len

sub main
  a = B(n: 2)
  b = B(n: 3)
  print(B(n: 1), size(?Text("four")))
  print(a if b.n > 5 else b)
  print("next")
```

```output
B(n: 1) 4
drop 1
B(n: 3)
next
drop 3
drop 2
```

```rig
struct Log
  lines: Vec[Int]

  fun count(?self) -> Int
    self.lines.len

fun make -> Log
  Log(lines: Vec())

sub main
  print(make().count(), make().lines.len)
```

```output
0 0
```

A borrow of a temporary (`?S(n: 1)`, `?make()`, `?make()[1..]`), and
any view made from one (a call's result that borrows it), may be used
anywhere in its statement, and nowhere after: held by a binding, a
field, a Vec, or a returned value, it is rejected.

**Headers are their own statements:** an `if` or `while` condition, a
`match` guard, and the subject of a `match` or `for`. A header's
temporaries end with the header, before the body runs; what the header
binds lives through the body. So `if text.starts_with(?Text(a, b),
"x")` works, but `if text.cut(?Text(a, b), "=") as kv` must bind the
Text first, because `kv` outlives the header. A value made there that
`if … as`, `while … as`, `match`, or `for` binds is taken, as `<e`
would take it: a call's result, or a branching value whose every
branch is made there (`make() if c else <a`). An arm of `match make()`
may move a payload out. A lend of a
branching value that may be a name's (`?(a if c else b)`) would copy
that name's value, so it is rejected: lend each branch, `?a if c else
?b`.

```rig
use std.text

sub main
  print(text.trim(?Text("  padded  ")) == "padded")
  n = text.find(?Text("abc"), "b") ?? -1
  if text.starts_with(?Text("x", n), "x1")
    print("starts")
  kv_text = Text("k=v")
  if text.cut(?kv_text, "=") as kv
    print(kv.before, kv.after)
```

```output
true
starts
k v
```

```rig reject
use std.text

struct S
  n: Int

sub main
  r = ?S(n: 1)
  s = text.trim(?Text(" a "))
  if text.cut(?Text("k=v"), "=") as kv
    print(kv.after)
  print(r.n, s)
```

```error
a borrow of the temporary `S(n: 1)` outlives its statement, which drops it; bind the value to a name first
a borrow of the temporary `Text(" a ")` outlives its statement
a borrow of the temporary `Text("k=v")` outlives its statement
```

---

## 8. Drop and drop glue

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

## 9. Shared and weak handles

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

**Access is read-only.** Field reads, element reads (`h[i]` of a
`*[N]T`, `*Vec[T]`, or `*String`), and `?self` methods reach through a
handle automatically, including through fields and loop elements.
`?h` lends the value's read views where one is expected: one
`fun area(s: ?Shape)` takes a `?h` of a `*Shape`, and a `*Text` lends
a String. The loan is on `h`, so `h` may not be dropped, moved, or
reassigned while the view is used. `!h` lends only the handle itself
(a `!*T`), never a write view of the value.
Writing a field, calling a `!self` method, or consuming the value
through a handle is rejected, because other handles share it; shared
mutable state goes in a `Cell` ([§10](#cell)). The built-in `Vec` is no
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
cannot assign through a shared handle
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
[§11](#captures)). Every test and example in this repository runs
leak-free, with no use of freed memory, under the sanitizing allocator.

---

## 10. Cell, Vec, Box, Text, and Signal

These built-in types are part of the language's substrate. Their names
are reserved.

### Cell

`Cell[T]` holds one value that can be replaced through a read-only
path. It is the way to mutate shared state: `*Cell[T]` is a shared,
mutable value.

| Member | Meaning |
|---|---|
| `Cell(v)` | construct |
| `c.get()` | a copy of the value (Copy or plain-data `T` only) |
| `c.set(v)` | store `v`; the old value is dropped |
| `c.replace(v)` | store `v` and return the old value |
| `c.push(x)`, `c.pop()`, `c.clear()`, `c.len` | a `Cell[Vec[T]]`: its Vec's members |
| `c[i]`, `c[i] = x`, `c.get(i)` | a `Cell[Vec[T]]` of Copy `T`: an element, bounds-checked, or `T?` |

`T` is a Copy primitive, plain data (a struct, enum, optional, or array
that owns nothing and holds no borrow), an owning type, or a type
declared `unique`. An owning or unique value is never copied out of a cell: it moves in with `set` / `replace` and moves out
with `replace`. What goes into a cell, by any of its members or
`c[i] = x`, holds no borrow, nor a String that may view a Text
([§10](#text)), since every handle to the cell reaches it.

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
struct holding one, and a shared handle. A value holding a Cell is
unique ([§2](#copy-values-and-owning-values)), so every binding of one is its place: a
by-value parameter owns the value moved into it (`c.hits.set(v)` with
`c: Counter` changes the callee's own), and a loop or match binding is
a view of the element or payload where it is, or owns one a loop or
match takes; only a temporary's Cell has no place.

```rig
struct Counter
  hits: Cell[Int]

  sub hit(?self)
    self.hits.set(self.hits.get() + 1)

sub bump(c: ?Cell[Int])
  c.set(c.get() + 10)

sub main
  count: *Cell[Int] = *Cell(0)
  other = +count
  other.set(other.get() + 5)
  local: Cell[Int] = Cell(1)
  bump(?local)
  k = Counter(hits: Cell(0))
  k.hit()
  k.hit()
  print(count.get(), local.get(), k.hits.get())

  shared: *Cell[Vec[Int]] = *Cell(Vec())
  shared.push(7)
  shared.push(8)
  shared[0] = shared[0] + 1
  print(shared.len, shared[0], shared.get(1), shared.get(2))

  # Anything else: take the value out, use it, and put it back.
  v = shared.replace(Vec())
  sum = 0
  for x in ?v
    sum += x
  shared.set(<v)
  print(sum, shared.len)
  if shared.pop() as last
    print("popped", last, shared.len)
```

```output
5 11 2
2 8 8 none
16 2
popped 8 1
```

### Vec

`Vec[T]` is a growable array that owns its elements. The binding is the
buffer: a `Vec` is an owning value even when its elements are Copy.
Elements are any value that is not a view: Copy primitives (numbers,
`Bool`, `String`), plain data, and owning values (a `Text`, a `Vec`, a
box, a handle, a struct that owns one).

| Member | Meaning |
|---|---|
| `Vec()`, `Vec(capacity: n)` | an empty Vec (typed by context) |
| `!v.push(x)` | append; an owning `x` is moved or cloned in |
| `v.len` | the number of elements |
| `v[i]`, `v[i] = x` | the element at `i`, a place as a field is: read in place, lent with `?v[i]` or `!v[i]`, taken with `<v[i]` when `T` is optional, and assigned, which drops the old value (bounds-checked) |
| `v.get(i)` | a copy of the element as `T?` (a `T` that copies; otherwise read `v[i]` or lend `?v[i]`) |
| `!v.pop()` | remove the last element, as `T?`; a handle is handed over to the caller |
| `!v.insert(i, x)` | put `x` at index `i`, moving the elements from `i` on up by one; `i` may be `v.len`; panics past it |
| `!v.remove(i)` | remove the element at `i` and hand it over, moving the rest down by one; panics out of range |
| `!v.clear()` | drop every element |

A `for` loop lends the Vec to read for the whole loop, so it cannot be
modified inside it: `for x in v` is `for x in ?v`. Each element
of Copy values is a copy; one of owning values is a borrowed slot,
where `v` must be a binding, or a field or element of one: the element can be
read, called, and cloned (`+x` is a new handle), but not moved,
dropped, or stored. `for x in !v` and `for x in <v` write and
consume the elements ([§6](#for)).

```rig
sub main
  total: *Cell[Int] = *Cell(0)
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
sub main
  v: Vec[String] = Vec()
  !v.push("b")
  !v.insert(0, "a")
  !v.insert(v.len, "c")
  gone = !v.remove(1)
  print(gone, v)
```

```output
b ["a", "c"]
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

### Box

`Box[T]` owns one `T` on the heap. A struct or enum can hold itself
through a box (`next: Box[Node]?`), since a box is a pointer whatever
`T` is. A box is the value's one owner: it moves (`<b`), is never
copied or cloned, and dropping it drops the value and frees the memory.
Long chains of boxes are released without deep recursion.

| Member | Meaning |
|---|---|
| `Box(v)` | move `v` into a new box |
| `b.f`, `b.m(...)` | a field or method of the boxed value, reached through the box (and through any boxes it holds): a struct's or enum's, a Vec's (`!b.push(x)`, `b.len`), a Text's (`!b.add(s)`, `b.len`) |
| `?b`, `!b` | lend the box, or, where a view of the value is expected, that view: `?T` or `!T`, a `[]T` of a boxed array or Vec, a `String` of a boxed Text, through any number of boxes |
| `<b.unbox()` | move the value out; the box is freed |
| `<s.f` | take an optional box out of a field, leaving `none` ([§7](#moves)) |
| `match ?b`, `match !b` | match a boxed enum where it is |

The box is reached as it is held: through an owned box or a `!Box[T]`
its value can be written, through a `?Box[T]` only read. A consuming
(`<self`) method of the value, `<b.m()`, takes the value out of the box
first. `T` holds no borrow. A box has no field of its own: `b.value`
of a `Box[Int]` names nothing, and the number is lent (`?b`) or taken
apart. A Vec holds boxes as it holds handles:
walked by borrowed slot and moved out with `pop` ([Vec](#vec)).

A recursive enum holds its children in boxes, and a function reads one
through a borrow of the box:

```rig
enum Expr
  num(n: Int)
  add(l: Box[Expr], r: Box[Expr])

fun eval(e: ?Box[Expr]) -> Int
  match e
    .num(n) => n
    .add(l, r) => eval(?l) + eval(?r)

fun num(n: Int) -> Box[Expr]
  Box(.num(n))

sub main
  e = Box(Expr.add(l: num(2), r: num(3)))
  print(eval(?e))
```

```output
5
```

With `if ?o as x` and `if !o as x` ([§12](#12-optionals)), an optional
box is used where it is:

```rig
struct Node
  key: Int
  left: Box[Node]?
  right: Box[Node]?

sub insert(slot: !Box[Node]?, key: Int)
  if !slot as n
    if key < n.key
      insert(!n.left, key)
    else
      insert(!n.right, key)
  else
    slot = Box(Node(key: key, left: none, right: none))

sub walk(slot: ?Box[Node]?)
  if slot as n
    walk(?n.left)
    print(n.key)
    walk(?n.right)

sub main
  root: Box[Node]? = none
  for k in [5, 2, 8, 1]
    insert(!root, k)
  walk(?root)
```

```output
1
2
5
8
```

### Text

`Text` is owned, growable text: bytes on the heap, UTF-8 by convention,
released when the Text is dropped. It is an owning value, so a bare
name moves nothing: `<t` moves it and `+t` copies its bytes into a new
Text. A `String` is the view of text; a Text is where text is built.

| Member | Meaning |
|---|---|
| `Text()` | an empty Text; nothing is allocated until text is added |
| `Text(a, b, ...)` | a Text holding each value as `print` writes it ([§17](#17-printing)), with no separators |
| `!t.add(a, b, ...)` | append each value the same way; a `U8` is written as a number |
| `!t.push(b)` | append one byte `b`, a `U8`, given by position |
| `!t.clear()` | empty it, keeping its buffer |
| `t.len` | its length in bytes, read-only |
| `?t[a..b]`, `?t[a..]`, `?t[..]` | a String viewing its bytes from `a` up to `b`, bounds-checked like any slice ([§2](#slices)) |
| `?t` where a String or `String?` is expected | `?t[..]` |
| a borrow `p: ?Text` (a name, or a call's result) where a String is expected | its bytes; `p[a..b]` is a view of them, with no further `?` |
| `for b in ?t` | its bytes, as `U8`s |
| `?b[a..b]`, `?b` of a `Box[Text]` | the same, through the box |
| `+t` | a new Text holding the same bytes |
| `t == u`, `t == s` | compares its bytes with a Text's or a String's; a boxed Text too |

Each value is written as `print` writes it at the top level: a String
or a Text as its text, a number as `print` shows it, a struct, enum,
optional, array, or Vec as `print` writes it, with the Strings inside
it quoted. Rig has no `+` on text and no interpolation: text is built
with `Text(...)` and `!t.add(...)`, and every change to a Text is
written with `!`.

```rig
struct Point
  x: Int
  y: Float

sub main
  t = Text("n=", 42, " p=", Point(x: 1, y: 2.5))
  !t.add(" ok=", true, " ", ["a", "b"])
  print(t)
  print(t.len, t == "n=42", ?t[..4])
  u = +t
  !u.clear()
  !u.add("fresh")
  print(u, u.len)
```

```output
n=42 p=Point(x: 1, y: 2.5) ok=true ["a", "b"]
45 false n=42
fresh 5
```

**A String is a view of its Text.** `?t[a..b]` lends the Text as a
slice lends an array, and the String it makes carries the loan: while
the String is in use, the Text cannot be changed, moved, or dropped,
and the String cannot outlive it. The loan goes wherever the String
goes: into a binding, a struct field, a `Vec[String]`, an optional, a
closure's captures, and a call's result, since a function returning a
String may return a view of a String it was passed
([§7](#second-class-borrows)). Once the last use of the String, and of
every value holding it, is past, the Text is free again; a Vec holding
one is in use until it is dropped.

`Text(...)` and `!t.add(...)` only read their arguments, as `print`
does: a place is read where it is when the call runs, after its later
arguments, and a value made there is a temporary its statement drops
([§7](#temporaries)). A String viewing a temporary Text, as in
`text.trim(?Text(a, b))`, may be used within its statement, and within
a header only by the header itself ([§7](#temporaries)); bind the Text
to a name to keep the view longer.

```rig
fun first_word(s: String) -> String
  i = 0
  while i < s.len and s[i] != 32
    i += 1
  s[..i]

struct Entry
  name: String

sub main
  t = Text("hello world")
  w = first_word(?t)
  e = Entry(name: ?t[6..])
  names: Vec[String] = Vec()
  !names.push(w)
  print(w, e, names)
  -names
  !t.add("!")
  print(t)
```

```output
hello Entry(name: "world") ["hello"]
hello world!
```

```rig reject
fun first_word(s: String) -> String
  s[..5]

fun local -> String
  t = Text("gone")
  ?t[..]

sub main
  t = Text("hello world")
  w = first_word(?t)
  !t.add("!")
  print(w, local())
```

```error
cannot write-borrow `t` while a read borrow is live
returned borrow of `t` does not originate from a borrowed parameter
```

A String whose origin a function cannot see, a parameter or a value
built from one, may view a Text, so it stays where borrows are
followed. It cannot be stored in a `Cell` or a `Signal` (by `Cell(v)`,
`set`, `replace`, `push`, or `c[i] = v`), or captured by an owned
closure, since every handle to those reaches what they hold;
nor can a closure store its String parameter through a capture. A
generic body that stores a `T` in a `Cell`, a `Signal`, or an owned
closure cannot be instantiated with a `T` that holds a String, even
when every String passed is a literal. Where a String must outlive the
Text it came from, copy it into a Text of its own: `Text(s)`.

A Text owns its bytes, and a `Vec[Text]` owns its Texts, as
`Vec[Box[Text]]` does through its boxes. A Vec that
holds views keeps their Texts borrowed until it is dropped, since it is
in use until then; drop it early with `-v` to change them sooner.

```rig
sub main
  owned: Vec[Box[Text]] = Vec()
  !owned.push(Box(Text("one")))
  !owned.push(Box(Text("two")))
  t = Text("a b")
  views: Vec[String] = Vec()
  !views.push(?t[..1])
  print(owned, views)
  -views
  !t.add("!")
  print(t)
```

```output
["one", "two"] ["a"]
a b!
```

```rig reject
sub keep(c: ?Cell[String], s: String)
  c.set(s)

sub main
  c = Cell("")
  keep(?c, "a")
```

```error
cannot store a borrow of `s` in a `Cell`
```

### Signal

`Signal[T]` holds a Copy or plain-data value (as a `Cell` does) and a
list of subscribers, owned closures
of type `*sub()`. It lives behind a shared handle: a stack `Signal` is
rejected.

| Member | Meaning |
|---|---|
| `*Signal(v)` | construct |
| `s.get()` | the current value |
| `s.set(v)` | store `v`, then call every subscriber in subscription order |
| `s.subscribe(cb)` | take ownership of the handle `cb` (pass `+cb` to keep yours) |

A `set` from inside a subscriber is queued and delivered after the
current round, with the latest value winning. Subscribing from inside a
subscriber panics. A subscriber that reads its own signal must capture
it weakly, or the signal and its subscriber keep each other alive.

```rig
sub main
  sig: *Signal[Int] = *Signal(0)
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

## 11. Closures

### Bar lists

A closure starts with its bar list, which holds its **captures**, each
with a sigil, and then its **parameters**, bare names
([SYNTAX §11](SYNTAX.md#closures)). A closure reaches the enclosing
function's locals only through its captures. A bare entry that names a visible local is rejected, with the
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
| `\|?x\|` | any | a read borrow `?T`, as `?x` gives it |
| `\|!x\|` | any a write borrow may take | a write borrow `!T`, as `!x` gives it |
| `\|~x\|` | `*T` | a weak handle `~T` |

The closure's environment owns what it captured and releases it once,
when the closure is released, not after each call. The body may use,
call, and clone a captured owning value, but not move, drop, or
reassign it: the closure may be called again, so it cannot be the
closure's value either. A captured borrow may be passed to a call,
which borrows it for the call. A captured read borrow may be the
closure's value, and a call's result then borrows what the closure
captured. Through a captured write borrow the body can write fields,
call `!self` methods (`!w.push(x)`), lend it on for a
call (`!w`), and assign the whole value (`w = v`, `w += 1`), which
writes through to what it borrows. Nothing the closure owns or receives
as a parameter may be stored through it: those last one call at most,
and the captured value outlives them. A name may be captured once per
list.

`|?x|` and `|!x|` borrow `x` for as long as the closure lives, which is
until its last use: `|!x|` is `w = !x` followed by `|<w|`. While the
closure lives, `x` follows the aliasing rule
([§7](#borrows)); after its last call, `x` is free again.

```rig
sub main
  total = 0
  names = ["ada", "bob"]
  add = |!total, ?names, k: Int| total += k * names.len
  add(1)
  add(10)
  print(total)
  total = 0
  print(total)
```

```output
22
0
```

A closure nested in another captures from the scope where it is
created: the outer closure's captures, parameters, and locals. It may
copy or clone an outer capture (`|+x|`) or hold it weakly (`|~x|`), but
not move it (`|<x|`), since the outer closure may run again.

```rig
sub main
  total: *Cell[Int] = *Cell(0)
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

With a type from context, the body is checked against its return type,
and a body whose type can fail may propagate with `!`
([§13](#13-errors)), as one whose type returns an optional may return
`none` with `?` ([§12](#12-optionals)).
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
| `?fun(Int) -> Int`, `?sub()` | a borrowed callable ([below](#closure-parameters)) |

Function types describe closures bound to locals and function names
used as values. A function type writes its result after `->`, as a
declaration does; a suffix belongs to the result, so `fun(Int) -> Int!`
returns an `Int!`, and an optional function is `(fun(Int) -> Int)?`. An owned closure is a
shared handle, so `~f` makes a weak handle to it, which upgrades like
any other ([§9](#weak-handles)).

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
that writes it, so it may not escape. It may be bound to a local
(`f = |...| body`, then called as `f(...)`), called where it is written
(`(|+n| print(n))()`), or lent to a call ([below](#closure-parameters)).
Anywhere else (a field, an array element, a return value) it is
rejected; make it owned instead. A closure binding is fixed and cannot
be copied or moved; `?f` lends it.

```rig reject
fun make -> fun() -> Int
  n = 1
  |+n| n
```

```error
closures cannot escape their defining scope
```

### Closure parameters

A parameter of type `?fun(A) -> R` or `?sub(A)` takes a **borrowed
callable**: a read borrow of something to call. It accepts

- a closure literal written in the argument, without `*`;
- a named stack closure lent as `?f`;
- a function name or a `fun` value, as it is;
- an owned closure lent as `?cb`.

A borrowed callable is a borrow like any `?T` ([§7](#second-class-borrows)):
the callee may call it and forward it, and the caller's values stay
borrowed while it lives. A lent closure literal borrows what it
captures for the call, so its captures conflict with the call's other
borrows, and its environment lives until the call returns, dropping
what it moved in. It costs one indirect call per invocation and
allocates nothing.

```rig
struct Res
  id: Int

  drop(!self)
    print("drop", self.id)

fun apply(f: ?fun(Int) -> Int, x: Int) -> Int
  f(x)

sub each(xs: ?Vec[Int], f: ?sub(Int))
  for x in xs
    f(x)

fun double(n: Int) -> Int
  n * 2

sub main
  v: Vec[Int] = Vec()
  !v.push(1)
  !v.push(2)
  total = 0
  each(?v, |!total, n| total += n)
  k = 10
  add_k = |+k, a: Int| a + k
  cb: *fun(Int) -> Int = *|a| a - 1
  print(total, apply(double, 4), apply(?add_k, 4), apply(?cb, 4))
  r = Res(id: 7)
  n = apply(|<r, a| a + r.id, 1)
  print(n)
```

```output
3 8 14 3
drop 7
8
```

No value holds a borrowed callable: it is only a parameter's, a local's,
or a result's type, never a field's, an element's, a module-level
binding's, or a type argument. A function may return one only where it
returns a borrow its caller lent it, and a closure literal is not lent
to a call whose result could hold it. A call never changes a closure's
environment, so a closure is lent only to read: `!f` is rejected.

Only `?fun(...)` and `?sub(...)` written as such are borrowed callables.
A `?T` whose `T` is a function type, in a generic function, a field, or
a payload, is a read borrow of a function value, and `!fun(...)` a
write borrow of one, which can be reassigned through; a closure is not
lent there (`?f` of a closure where a `?T` goes is rejected).
`*|...|` makes an owned closure, which is not what a `?fun` parameter
takes:

```rig reject
fun apply(f: ?fun(Int) -> Int, x: Int) -> Int
  f(x)

sub main
  print(apply(*|a| a + 1, 2))
```

```error
borrows a closure for the call; write the closure without `*` (drop the `*`)
```

A closure lent to a call is checked with the call's other arguments:

```rig reject
sub each(xs: ?Vec[Int], f: ?sub(Int))
  for x in xs
    f(x)

sub main
  c: Vec[Int] = Vec()
  each(?c, |!c, n|
    !c.push(n))
```

```error
cannot write-borrow `c` while a read borrow is live
```

### Owned closures

`*` before the bar list makes an **owned closure**: its environment is
allocated on the heap behind a shared handle of type `*fun(...) -> R` or
`*sub(...)`, which can be stored, passed, returned, cloned (`+cb`),
held weakly, and dropped like any `*T`.

```rig
fun make_counter(start: Int) -> *fun(Int) -> Int
  count: *Cell[Int] = *Cell(start)
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

---

## 12. Optionals

`T?` holds a `T` or `none`. A plain `T` is accepted where a `T?` is
expected, and `none` needs a known optional type.

| Form | Meaning |
|---|---|
| `a ?? b` | the value inside `a`, or `b` when `a` is `none`; where a `T?` is expected, `b` may be a `T?` too (as may a `catch` handler) |
| `a == none`, `a != none` | test for absence |
| `a == v`, `a != v` | whether `a` holds the value `v`, a `T` |
| `if a as x` | run the block with `x` bound to the value inside `a`; `else` runs when `a` is `none` |
| `if ?a as x`, `if !a as x` | the same, with `x` borrowing the value inside `a` |
| `?a` where a `View?` is expected | a view of the value inside `a`, or `none`: `?a` of an `S?` where a `(?S)?` is expected, of a `Text?` where a `String?` is, of a `Vec[Int]?` where a `([]Int)?` is; `?a` itself is a `?(S?)` |
| `if <a.f as x` | the same, taking the value out of a field and leaving `none` ([§7](#moves)) |
| `while a as x` | repeat while `a` produces a value |
| `if a as x and b as y`, `if a as x and x > 0` | bindings and `Bool` conditions joined by `and`; `else` runs when any fails |
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

`a?` mirrors `e!` ([§13](#13-errors)): it is allowed only in a
function returning `T?` (or `T?!`), or in a closure whose type returns
one ([§11](#parameters-and-results)), and not in deferred code. The early return runs deferred code and drops what the
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
read where it is: `if m as x` is `if ?m as x`. To take its value, move
or clone it: `if <m as x`, `if +m as x`, and it is unwrapped the same
way: `(<m)?`.

To use the value where it is, borrow the optional: `if ?m as x` binds
`x` as a read borrow of the value (`?T`), and `if !m as x` as a write
borrow (`!T`), through which `x.f = v` changes the value in place and
`x = v` replaces it. `m` stays borrowed for the block, as for any
borrow. A `?T?` parameter, or another read borrow of an optional,
lends its value the same way with `if p as x`; a held write borrow is
lent on as `!p`, and a write borrow a call returns is bound as one.
Plain data read through a `?T?` is copied (in a generic body, so is
every `T`); a value holding a Cell is borrowed. A borrow cannot give up
a resource it holds, so `?` and `??` reject one.

```rig
struct Res
  n: Int

  drop(!self)
    print("drop", self.n)

sub grow(o: !Res?)
  if !o as r
    r.n += 10

fun peek(o: ?Res?) -> Int
  if o as r
    r.n
  else
    0

sub main
  m: Res? = Res(n: 1)
  grow(!m)
  print(peek(?m))
  if !m as r
    r = Res(n: r.n + 1)
  print(peek(?m))
```

```output
11
drop 11
12
drop 12
```

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

### Joined bindings

An `if` or `while` condition may join several bindings, and `Bool`
conditions among them, with `and`: `if a as x and b as y`,
`if a as x and x > 3`, `while !q.pop() as n and n > 0`. `as` binds
tighter than `and`, and the parts run in order, each only when the ones
before it held. Each binding is visible to the parts after it and to
the body, not to `else`, which runs when any part fails (and a loop
ends then). Each binding takes its own form: `if ?o as x and !p as y`
borrows from both. A binding made before a part that fails is dropped
before `else` runs. A `while` step may read the bindings (it runs
after the body, before they go) when every binding of the condition is
plain data and no `continue` in the condition can skip one. `as` stands
nowhere else: not under `or` or `not`, not in the condition of a
ternary or a postfix guard (which have no block to see the name), and
not in an expression.

```rig
fun get(k: Int) -> Int?
  k if k > 0 else none

fun sum(a: Int, b: Int) -> Int
  if get(a) as x and get(b) as y and x < y
    x + y
  else
    0

sub main
  print(sum(1, 2), sum(2, 1), sum(0, 2))
  xs: Vec[Int] = Vec()
  for n in 1..6
    !xs.push(n)
  total = 0
  while !xs.pop() as n and n > 2
    total += n
  print(total, xs.len)
```

```output
3 0 0
12 1
```

```rig reject
fun get(k: Int) -> Int?
  k if k > 0 else none

sub main
  if get(1) as x or true
    print(1)
```

```error
`as` binds only in the condition of an `if` or `while` block, alone or joined to the rest by `and`
```

### The fallback of `??`

The fallback of `??` may be a jump: `a ?? return v`, `a ?? return`,
`a ?? break`, `a ?? break v`, or `a ?? continue`. When `a` is `none`
the jump runs, exactly as the statement would: `return` is checked
against the function's result, `break` and `continue` apply to the
innermost loop or name a label (`a ?? continue :outer`), and leaving
drops what the scope owns. In a `while` header the first `:` starts the
step, so a jump there takes no label. The jump takes the rest of the expression as its value,
and the left side of `?? return` is the whole expression before it, as
for `catch` (`a and b ?? return` is `(a and b) ?? return`), except in a
chain of `??`, where the jump belongs to the nearest one, as `??` is
right-associative: `a ?? b ?? return v` is `a ?? (b ?? return v)`.
Where `a ?? b` is only read, it reads the value inside `a`, or `b`,
where it is ([§7](#temporaries)). Where it is taken, it takes from each
side: the optional may hold an owning value when it is made there
(`make(k) ?? return`, `make(k) ?? make(0)`) or moved (`<o ?? return`,
`<h.f ?? return`, which leaves `none`), but not when it is reached
through a borrow, which gives up nothing. Anything
else on the right of `??` is a value of the optional's type, so a bare
error value is no fallback: `?? E.missing` is rejected, and failing is
written `?? return E.missing` in a fallible function.

```rig
error E
  missing

fun find(xs: ?Vec[Int], k: Int) -> Int?
  for x, i in xs
    return i if x == k
  none

fun index_of(xs: ?Vec[Int], k: Int) -> Int!
  i = find(xs, k) ?? return E.missing
  i + 1

sub main
  xs: Vec[Int] = Vec()
  for n in 1..4
    !xs.push(n * 10)
  total = 0
  for k in [10, 15, 30]
    i = find(?xs, k) ?? continue
    total += i
  print(total, index_of(?xs, 20) catch 0, index_of(?xs, 25) catch 0)
```

```output
2 2 0
```

---

## 13. Errors

A function whose return type is `T!` may fail, and so may a `sub`
marked `!` (`sub save(n: Int)!`, of type `sub(Int)!`). A call to it
must say what happens to the failure, visibly:

- `f()!` propagates it: the enclosing function fails with the same
  error. The enclosing function must itself return a `T!`, be a
  fallible `sub`, or be the top-level `sub main` or a `test`. A failure
  that leaves `main` ends the program after `main`'s drops: it writes
  `error: E.name` to stderr and exits with status 1.
- `f() catch fallback` handles it: the value of the call, or `fallback`
  when it fails. The fallback may be a jump, as after `??`
  ([§12](#12-optionals)): `f() catch return -1`, `f() catch |e| return e`,
  `f() catch break`, `f() catch continue`.

A bare call to a fallible function is rejected, and so is `!` on a call
that cannot fail. A `drop` body and a `defer` cannot propagate, and a
closure propagates only when its type can fail: one checked against
`?fun(String) -> Int!`, `?sub(String)!`, or `*fun(String) -> Int!`
sends the failure of its `!` to whoever calls it, as a function does.
A closure whose type cannot fail, or whose type is inferred from its
body, handles failures with `catch`. A fallible type is only allowed as
the return type of a function or of a function type
(`fun(Int) -> Int!`, `sub(Int)!`, `*fun(Int) -> Int!`), and a plain `T`
is accepted where `T!` is expected. `E!` for an error set `E` is
rejected: a failure and a success would both be `E` values. So is a
generic `T!` whose `T` an error set fills.

```rig
error Parse
  empty

fun parse(s: String) -> Int!
  return Parse.empty if s.len == 0
  s.len

sub each(xs: []String, f: ?sub(String)!)!
  for x in xs
    f(x)!

sub main
  total = Cell(0)
  each(["ab", "c"], |!total, l| total.set(total.get() + parse(l)!))!
  each(["ab", ""], |!total, l| total.set(total.get() + parse(l)!)) catch |e| print("failed", e)
  print(total.get())
```

```output
failed Parse.empty
5
```

```rig
error SaveError
  full

sub save(n: Int, used: !Int)!
  return SaveError.full if used >= 2
  used += 1
  print("saved", n)

sub main
  used = 0
  save(1, !used)!
  save(2, !used)!
  save(3, !used) catch |e|
    print("not saved:", e)
```

```output
saved 1
saved 2
not saved: SaveError.full
```

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

A jump as the handler leaves instead of giving a value:

```rig
error E
  bad

fun parse(s: String) -> Int!
  return E.bad if s == "x"
  s.len

fun size(s: String) -> Int
  n = parse(s) catch return -1
  n * 10

sub main
  seen = 0
  for w in ["a", "bb", "x", "dddd"]
    seen += parse(w) catch break
  print(size("abc"), size("x"), seen)
```

```output
30 -1 3
```

### Failing

A fallible function fails by returning an error value: `return E.name`
(a member of an error set, [§3](#error-sets)), a binding of an error
set's type, or an error it caught. The error value may be a branch of
the returned value, of a ternary or a `match` (`return n if ok else
E.bad`), and nowhere deeper: failing is always written, so an error
value anywhere else a `T!` is expected, such as a function's last
expression or a branch block's, is rejected. The failure leaves the
function the way `!` does: every `defer` and `errdefer` of the scopes it
leaves runs. Only a function returning `T!` can fail.

```rig
error Bad
  odd

fun half(n: Int) -> Int!
  return n / 2 if n % 2 == 0 else Bad.odd

sub main
  print(half(4) catch -1, half(3) catch -1)
```

```output
2 -1
```

```rig reject
error Bad
  odd

fun half(n: Int) -> Int!
  if n % 2 == 1
    Bad.odd
  else
    n / 2
```

```error
an error value meets `Int!` only as the operand of `return`: write `return Bad.odd`
```

Failing always names the error set. Where a `T!` is expected, a bare
`.name` is a variant of `T`, even when an error set has a member of the
same name, and it is rejected when `T` has no such variant: in a
`return`, a function's last expression, a branch or arm value, and a
closure whose type can fail.

```rig
enum Color
  red
  missing

error Lookup
  missing

fun pick(n: Int) -> Color!
  return Lookup.missing if n < 0
  return .missing if n == 0
  .red

sub main
  print(pick(1) catch .red, pick(0) catch .red, pick(-1) catch .red)
```

```output
.red .missing .red
```

```rig reject
error Lookup
  missing

fun find(n: Int) -> Int!
  return .missing if n < 0
  n
```

```error
`.missing` is not a value of `Int`; to fail, name the error set: `Lookup.missing`
```

### Naming the error

`f() catch |err| handler` names the error for the handler. Functions do
not declare which errors they fail with, so `err` may be any error: it
is compared with error-set members (`err == E.name`), matched by them
(`E.name =>`, with a `_` arm, since no arms name every error),
printed, and returned from a fallible function. The handler may be a
block.

An error is its set's member: a failure with `Net.timeout` is not
`Disk.timeout`, so `err == Disk.timeout` is false for it and a
`Disk.timeout =>` arm does not match it. A set of another module is
named through the module: `io.IoError.eof`, also as a pattern. A bare
`.name` compared or matched with `err` is the member of the one error
set that may mean it: the module's own sets, private ones included, and
the `pub` sets of the modules it reaches through its imports; another
module's private set never counts. It is rejected when no such set has
a member `name`, and when several do: the error lists each as the
module writes it, saying which module to import to name one it only
reaches, and the comparison or pattern names the set.

```rig
error ParseError
  empty
  too_long

fun parse_len(s: String) -> Int!
  return ParseError.empty if s == ""
  return ParseError.too_long if s.len > 5
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
failed with ParseError.empty
0
```

```rig
error Net
  timeout
  refused

error Disk
  timeout

fun fetch(n: Int) -> Int!
  return Net.timeout if n == 1
  return Disk.timeout if n == 2
  return Net.refused if n == 3
  n

fun describe(n: Int) -> String
  _ = fetch(n) catch |err|
    match err
      Net.timeout => return "network timeout"
      Disk.timeout => return "disk timeout"
      .refused => return "refused"
      _ => return "other"
  "ok"

sub main
  print(describe(1), describe(2), describe(3), describe(4))
  x = fetch(2) catch |err|
    print(err, err == Net.timeout, err == Disk.timeout)
    0
  print(x)
```

```output
network timeout disk timeout refused ok
Disk.timeout false true
0
```

```rig reject
error Net
  timeout

error Disk
  timeout

fun fetch() -> Int!
  return Disk.timeout

sub main
  n = fetch() catch |err| 1 if err == .timeout else 2
  print(n)
```

```error
error sets `Net` and `Disk` both have a member `timeout`; name the set: `Net.timeout` or `Disk.timeout`
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

## 14. Modules

`use name` imports `name.rig` from the directory of the program's root
file, whichever module says it, so a name denotes one file. The file's
name must be exactly `name.rig`, case included, and names starting with
`__rig` are reserved for the compiler. `use std.name` imports the
standard library's module `name` ([STD.md](docs/STD.md)), which ships
with the compiler; it is a different module from a `name.rig` beside
the program. The module's `pub` declarations
are then reached as `name.decl`, and its types are named `name.Type` in
annotations. A type's members are named through the module too:
`name.Type.function(...)` calls an associated function, and
`name.Enum.variant` names a variant. Imports are checked in dependency
order, each module once; a cycle is an error.

```rig file=geo.rig
pub struct Point
  pub x: Int
  pub y: Int

  pub fun at(x: Int, y: Int) -> Point
    Point(x: x, y: y)

  pub fun sum(?self) -> Int
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

`use ... as other` names the module `other` in this file instead. Two
imports may not bind one name, so a program that uses both
`std.math` and its own `math.rig` names one of them with `as`:

```rig file=math.rig
pub fun twice(n: Int) -> Int
  2 * n
```

```rig
use std.math
use math as mine

sub main
  print(math.gcd(12, 18), mine.twice(4))
```

```output
6 8
```

```rig file=math.rig
pub fun twice(n: Int) -> Int
  2 * n
```

```rig reject
use std.math
use math

sub main
  print(math.twice(4))
```

```error
two imports bind the name `math`; name one of them with `as`
```

Only `pub` declarations are visible to importers. A `pub` function may
take or return a private type: importers can hold the value and use its
`pub` fields and methods, though they cannot name the type.

A field or method is private to its module unless it is declared `pub`:
`pub x: Int`, `pub x: Int = 0`, `pub fun sum(?self) -> Int`,
`pub sub push(!self, x: Int)`. Inside the declaring module every member
is visible; another module that reads or writes a private field, or
calls a private method or associated function, is rejected, whichever
way it reaches the member: through a borrow, a `*T` handle, a `Box`, or
an instance of a generic type. Another module constructs a struct only
when every one of its fields is `pub`; a type with a private field is
made by its own module, which can hand it out through a `pub` function.
An enum's variants and their payload fields are always public, since
they are the type's shape; its methods follow the rule above. A `drop`
body is not called by name, so it takes no `pub`.

```rig file=bank.rig
pub struct Account
  pub owner: String
  balance: Int

  pub fun total(?self) -> Int
    self.balance

  sub audit(?self)
    print("audit", self.balance)

pub fun open(owner: String) -> Account
  Account(owner: owner, balance: 100)
```

```rig
use bank

sub main
  a = bank.open("ada")
  print(a.owner, a.total())
```

```output
ada 100
```

Here `audit` and `balance` are private to `bank`:

```rig file=bank.rig
pub struct Account
  pub owner: String
  balance: Int

  pub fun total(?self) -> Int
    self.balance

  sub audit(?self)
    print("audit", self.balance)
```

```rig reject
use bank

sub main
  a = bank.Account(owner: "bo", balance: 5)
  a.audit()
  print(a.balance, a.total())
```

```error
method `audit` of `bank.Account` is private to module `bank`; declare it `pub sub audit` there to call it from here
only module `bank` can construct `bank.Account`: its field `balance` is private
field `balance` of `bank.Account` is private to module `bank`; declare it `pub balance: ...` there to use it from here
```

Another module's `pub` generic types and functions are used as local
ones are: `boxes.Wrap[Int]` names an instance in a type or an
expression, its type arguments are given or inferred, and its methods
and variants are reached through it. Each instance a module makes is
checked where it is made, against what the declaring module's bodies do
with its type parameters ([§3](#generic-bodies)), and a diagnostic
about it has a note at that body's line, in its file. An instance is
one type wherever it is reached from: `boxes.Wrap[Int]` spelled here is
the type another module's function returns as `boxes.Wrap[Int]`, even
through a module that does not import `boxes`. A public signature may
hold an instance of a private generic type, which importers hold and
use as they do a private type.

```rig file=boxes.rig
pub struct Wrap[T]
  pub v: T

  pub fun get(?self) -> T
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

## 15. Raw code and FFI

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

### Zig-backed declarations

The standard library binds declarations to Zig code: a `fun` or `sub`
without a body inside `extern zig "file.zig"` is the function of the
same name in that Zig file, which ships with the library. A call to one
is checked exactly as a call to a Rig function with that signature
(moves, borrows, and the loans its result carries) and needs no `raw`:
the Zig file is trusted as the runtime is, and each function's Zig type
is checked, when the program is compiled, to be the one its Rig
signature lowers to. Such a function takes no compile-time parameters.
Its signature is trusted where the checker cannot see a body: one that
returns a borrow and takes no borrowed parameter, as
`std.os.args() -> []String` does, returns something that lives as long
as the program.

A Zig-backed function may fail, returning `T!` or declared
`sub name(...)!`, when its module declares error sets
([§3](#error-sets)): it fails only with their errors, since its Zig
function's type must name the errors it returns, each one of those
sets' members. Its failures are errors like any other
([§13](#13-errors)), named through the module:

```rig
use std.text

sub main
  n = text.parse_int("12x") catch |err|
    print(err, err == text.ParseError.invalid)
    0
  print(n + text.parse_int("-30")!)
```

```output
ParseError.invalid true
-30
```

Only the standard library may declare a Zig-backed function:

```rig reject
extern zig "fast.zig"
  pub fun twice(n: Int) -> Int

sub main
  print(twice(2))
```

```error
only the standard library binds declarations to Zig code with `extern zig`
```

---

## 16. Compile-time parameters

A declaration lists its compile-time parameters in brackets after its
name, before any run-time parameters: a bare name is a **type
parameter** and `name: Type` a **compile-time value**
([SYNTAX §8](SYNTAX.md#generics-and-compile-time-parameters)).
Functions, `sub`s, methods, and associated functions take both kinds; generic types take type parameters and
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

A call gives the compile-time arguments in brackets after the callee,
before its run-time arguments (`check[.strict](5)`, `s.times[5]()`,
`lib.zeros[3]()`), all of them or none; a type argument, and an integer
value that an array length or a generic type's argument in
the signature holds, may be left to inference
([generic functions](#generic-functions)), any other value never. A
value argument must be known at compile time: a literal
(`none` included), an enum value, a module constant, a compile-time
parameter, a `const` binding of one of these, or a comparison or `and`,
`or`, `not` of them. Arithmetic in a compile-time argument must fold to
a constant (`LIMIT * 2`), which is checked like constant arithmetic;
arithmetic on a compile-time parameter (`n + 1`), directly or through a
`const` binding, is rejected, since each instance would compute it
unchecked. Inside a body, a compile-time value is an ordinary value, and
arithmetic on it is checked when it runs. Whether `x[...]` indexes `x`
or gives it compile-time arguments is decided by what `x` names
([SYNTAX §11](SYNTAX.md#compile-time-arguments)).

The brackets choose an instance and the parentheses call it, so a call
of a function with no run-time parameters is still written `show[3]()`,
and a statement `show[3]` is rejected, as a statement `greet` is. A
function with compile-time parameters can only be called, never used
as a value.

```rig
enum Mode
  strict
  loose

LIMIT = 5

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

---

## 17. Printing

`print(a, b, ...)` writes its values separated by single spaces, then a
newline; `print()` writes an empty line. `print` is only special as a
direct call; it is not a value.

| Value | Printed as |
|---|---|
| numbers, `Bool` | `42`, `-3`, `2.5`, `true`; a whole `Float` keeps its point, `1.0`, and a NaN is `nan` on every platform |
| `String`, `Text` | its text; inside other values, quoted |
| `none` | `none` |
| enum | `.green`, `.circle(r: 2.5)`, `.rect(w: 2, h: 3)`: payload fields by name, however it was built |
| error | `Disk.timeout`: its set and its name, without the module |
| struct | `User(name: "ada", age: 36)` |
| array, slice, `Vec` | `[1, 2]` |
| shared handle | the value it holds |
| `Box` | the value it holds |
| `Cell`, `Signal` | `Cell(value: 5)`, `Signal(value: 5)` |
| weak handle | `~(alive)` or `~(gone)` |
| owned closure | `<closure>` |
| function | `<fun>` |

A value nested more than 64 levels deep prints its deeper parts as
`...`. A temporary printed, `print(Text("n=", n))` or `print(make())`,
is dropped when the statement ends ([§7](#temporaries)). A `[]U8` and a `String` are the same bytes at run time, so
`print` rejects a value that holds a `[]U8`; print its bytes one by one.

```rig
struct User
  name: String
  age: Int

enum Shape
  dot
  circle(r: Float)
  rect(w: Int, h: Int)

sub main
  u = User(name: "ada", age: 36)
  n: Int? = none
  print(u, n, ["a", "b"], 2.5, 2.0)
  print(Shape.dot, Shape.circle(2.5), Shape.rect(w: 2, h: 3))
  h = *User(name: "bob", age: 1)
  w = ~h
  b = Box(User(name: "cy", age: 2))
  print(h, w, b, Cell(5))
```

```output
User(name: "ada", age: 36) none ["a", "b"] 2.5 2.0
.dot .circle(r: 2.5) .rect(w: 2, h: 3)
User(name: "bob", age: 1) ~(alive) User(name: "cy", age: 2) Cell(value: 5)
```

---

## 18. Reserved and unsupported forms

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
| `when`, `yield`, ... as a name | `` unexpected keyword `when` `` (every word held for later: `async` `await` `impl` `trait` `when` `where` `yield`) |
| string and float match patterns | `` a pattern is a name, an integer, `true`, `false`, or an enum variant `` |

The rest parse, and the checker rejects them as not supported yet
([roadmap](docs/ROADMAP.md)):

| Form | Diagnostic |
|---|---|
| `drop` on an enum or a generic struct | `` `drop` bodies are only for non-generic structs `` |
| a stack closure stored or returned | `` closures cannot escape their defining scope `` |
| an owned closure taking or returning an owning value | `` an owned closure takes plain Copy values `` |
| a payload field bound by name, `.rect(w: a, h: b)` | `` binding a payload field by name is not supported yet `` |

```rig reject
sub main
  zig "return;"
```

```error
unexpected keyword `zig`
inline Zig is reserved
```
