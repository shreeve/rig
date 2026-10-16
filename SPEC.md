# The Rig Language Reference

This is the reference for Rig as the compiler implements it today: what
each form means, and the rules `rig check` enforces. How each form is
written (layout, names, literals, operators and their precedence, and
the grammar) is in [SYNTAX.md](SYNTAX.md), and a guided start from
another language is [WELCOME.md](WELCOME.md). For the reasons behind
the rules, see [docs/DESIGN.md](docs/DESIGN.md); for what is not built
yet, see [docs/ROADMAP.md](docs/ROADMAP.md).

**The Core.** [docs/CORE.md](docs/CORE.md) states the whole ownership
model in ten sentences, and every ownership rule here follows from one
of them. Each ownership subsection opens with the one it follows: *Core
4* is sentence 4 of [CORE §2](docs/CORE.md#2-the-core-in-ten-sentences),
and *Core §3* is CORE's section 3. Where CORE marks a rule *planned*,
this reference states today's rule.

**Three words.** *You lend a view; the compiler remembers the loan.*
`?x` **lends** `x` to read and `!x` to write; the receiver gets a
**view**, and the owner keeps a **loan**, which limits it while it is
live.

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
10. [Cell, List, Box, String, and Signal](#10-cell-list-box-string-and-signal)
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
types (`obj`, `enum`, `error`, `type`), constants (`name = value`),
imports (`use`), `extern` declarations, and `test` blocks, written as
[SYNTAX.md](SYNTAX.md) shows. Statements live inside functions. A
program that runs declares its entry point as `sub main()`, with no
parameters, or as `fun main() -> Int`, whose value is the process's exit
status, from 0 to 255 (another value panics). Either may fail: `main`
may propagate an error with `!`, and `sub main()!` or `fun main() -> Int!`
may also return one; a failure that leaves `main` prints
`error: Set.name` and ends the program with status 1
([§13](#13-errors)). Everything `main` owns is dropped, its output
flushed, and the leak check run before the program exits. Only the
program calls `main`: Rig code cannot call it or use it as a value. The
program's arguments and environment are read through
[`std.os`](docs/STD.md#stdos).

A source file holds at most 16 MiB. A token in it, such as a string
literal, a name, or a comment, may be of any length up to that.

```rig
fun main() -> Int
  print("nothing to do")
  0
```

```output
nothing to do
```

`rig check` checks a program, `rig run` checks, builds, and runs it,
and `rig --help` lists the other commands (see also the
[README](README.md#build-and-run)). `rig check` and `rig test` also
accept a directory module as the root. The root's imports are its
sibling modules, found in the directory's real parent, with symlinks
resolved, whatever the path is spelled.

`rig run` builds in Zig's debug mode with a leak-checking allocator: a program
that leaks memory reports it and exits with an error. Built with
`RIG_SANITIZE=1`, it also crashes at any use of freed memory. `--release` builds
in Zig's safe mode, and `--release=fast` in its fast mode. Integer
overflow, out-of-bounds indexing and slicing, and a numeric conversion
whose value does not fit panic in debug and safe builds.
The fast mode is the one outside that guarantee: it drops the
overflow and conversion checks, so there an overflow or an out-of-range
conversion is undefined behavior. That holds for the lanes of a vector
as for a scalar: `+ - * -v` and `<<` on vectors are checked in debug and
safe builds and unchecked in fast. Indexing and slicing stay checked in
every mode; a test the compiler proves already passed (a guard or an
earlier check made it on every path, and nothing it tested changed
since) is not repeated.

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
| `String` | owned, growable text: bytes on the heap, UTF-8 by convention ([§10](#string)) | `rig.String` |
| `?String` | a read view of text: bytes, UTF-8 by convention, that it does not own ([strings](#strings)) | `[]const u8` |
| `Static` | text that lives for the whole program: a string literal, or text derived only from literals; plain data that carries no loan ([Static](#static)) | `[]const u8` |
| `Void` | no value (what a `sub` returns) | `void` |
| `error` | an error of any set, owning ([§13](#any-error)) | `anyerror` |

Every named type is an owner, and a view is never a name: it is written
`?T` or `!T`, or is a slice `[]T`, so the read view of text is `?String`.

`Int` is `I64` and `Float` is `F64`: one type under two names. Every
other numeric type is distinct, and there are no implicit conversions.
A length read as an `Int` is below 2^62; a longer one panics (no target
holds one).
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
sub main()
  print(U8.max, I8.min, Int.max, U128.max, Float.min < 0.0)
```

```output
255 -128 9223372036854775807 340282366920938463463374607431768211455 true
```

```rig
sub main()
  small: U8 = 200
  sum = small + 55          # 55 is a U8 here
  big = 9223372036854775807
  print(sum, big, @size(Int), 0.1 + 0.2)
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

A conversion to a float type rounds to the nearest value the type
holds, for a constant as it does at run time: `F32(16777217)` is
`16777216.0`. A constant assigned to a float type without a conversion
must be exact, so `a: F32 = 16777217` is rejected; write the
conversion to accept the rounding.

```rig
sub main()
  n = 16777217
  print(F32(16777217), F32(n))
```

```output
16777216.0 16777216.0
```

```rig reject
sub main()
  a: F32 = 16777217
```

```error
integer value `16777217` does not fit exactly in `F32`
```

A number type's name also has functions, which name how they convert.
`I32.wrap(x)`, for any integer type, converts an integer by keeping its
low bits: the value modulo 2^(the target's bit count), read in the target's
signedness, and it never panics. A narrower target keeps the low bits; a
wider one gets the value, sign-extended when the source is signed. It
takes an integer, not a float: convert a `Float` with `Int(x)` first.
`Float.from_bits(u)` is the float whose IEEE 754 bits are the unsigned
integer `u`, a `U64` (a `U32` for `F32`), and `f.to_bits()` reads those
bits from a float, as the unsigned integer of its size. They convert the
representation, where `U64(f)` converts the value.
`Float.nan()` and `Float.inf()` (also `F32.nan()`, `F32.inf()`) are the
NaN and the positive infinity; `-Float.inf()` is the negative one.
`f.fraction()` and `f.exponent()` are what C, Python, and Go call
`frexp`: `f` is `f.fraction()` times 2 to the power `f.exponent()`, the
fraction in [0.5, 1) in magnitude and of `f`'s type, the exponent an
`Int`. A zero gives `(±0, 0)` and an infinity or a NaN gives itself and
exponent 0, as Go's `Frexp` does; a subnormal is normalized.

```rig
sub main()
  big = 5000000000
  print(I32.wrap(big), U8.wrap(-1), U64.wrap(I32(-1)), I8.wrap(U8(200)))
  x = 1.5
  b = x.to_bits()
  print(b, Float.from_bits(b), Float.from_bits(0x8000000000000000))
  y: F32 = 1.5
  print(y.to_bits(), F32.from_bits(0x3FC00000))
  print(x.fraction(), x.exponent(), Float.inf(), -F32.inf(), Float.nan() != Float.nan())
```

```output
705032704 255 18446744073709551615 -56
4609434218613702656 1.5 -0.0
1069547520 1.5
0.75 1 inf -inf true
```

```rig reject
sub main()
  print(I32.wrap(2.5))
```

```error
`I32.wrap(x)` takes an integer; convert a Float with `Int(x)` first
```

```rig reject
sub main()
  n = 5
  print(n.to_bits())
```

```error
type `Int` has no method `to_bits`
```

### Strings

A `?String` has a length `s.len` and can be indexed (`s[0]`, or
`s.get(i)`, a `U8?` that is `none` past the end), and a `for` loop over
it yields its bytes as `U8`. `s.is_empty()` is `s.len == 0`; it works
the same on a List, an array, a slice, and a `Cell[List[T]]`, and a
type's own `is_empty` method wins on that type.

```rig
sub main()
  s = ""
  v: List[Int] = List()
  !v.push(1)
  print(s.is_empty(), "ab".is_empty(), v.is_empty())
```

```output
true false false
```

`?String` values compare with `==` and
`!=` by content, and `<`, `<=`, `>`, `>=` order them by their bytes
([§5](#operators)).

A `?String` is a read view of bytes it does not own. A `Static`'s last as
long as the program ([Static](#static)); one taken from a `String`
(`?t[..]`) carries the String's loan ([§10](#string)). The bytes are
UTF-8 by convention, and nothing checks it: lengths and indexes count
bytes, and a slice checks only its bounds.

Text is measured in four units, each with one name
([TEXT](docs/TEXT.md)): a **byte**,
what `s.len` counts; a **rune**, one code point; a **unit**, one UTF-16
code unit, what JavaScript's string length counts; and a **char**, what
a reader sees as one character. A char is a grapheme and nothing else:
one character, as a person counts it, however many bytes it takes.
Other languages spend "char" on a byte (C), a UTF-16 unit (Java,
JavaScript), or a code point (Rust); Rig names those byte, unit, and
rune. Each of these is one char:

| Text | Written as | Bytes | Runes | Units | Chars |
|---|---|---:|---:|---:|---:|
| `a` | U+0061 | 1 | 1 | 1 | 1 |
| `é` | U+00E9, one rune | 2 | 1 | 1 | 1 |
| `é` | `e` U+0065, then a combining acute U+0301 | 3 | 2 | 2 | 1 |
| `👋🏽` | waving hand U+1F44B, then skin tone U+1F3FD | 8 | 2 | 4 | 1 |
| `👨‍👩‍👧` | man, zero-width joiner, woman, joiner, girl | 18 | 5 | 8 | 1 |

The two `é`s look the same and are one char each, but take 2 and 3
bytes. A `String` holds UTF-8 by convention: a byte from 0 to 127 is
ASCII and a whole rune on its own; every other rune takes 2 to 4 bytes,
each from 128 to 255, none of them a rune by itself. `s.len` counts
bytes:

```rig
sub main()
  s = "\u{e9}"
  print(s.len, s[0], s[1])
  print("e\u{301}".len, "\u{1f44b}\u{1f3fd}".len)
  print("\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}".len)
```

```output
2 195 169
3 8
18
```

There is one view of text, `?String`. The read view of a `String` is its
bytes: `?t`, a loop or pattern binding of a `String` element, and a
generic `?T` at `T = String` are all `?String` values, and a read view of
a `?String` is that `?String` (`?s`). `+s` of a `?String` copies its
bytes into a new `String`. A `?String` is a view, so nothing lends a
`?String` place to write, `swap` and `replace` of one included: assign
to the place to point it at other text, or hold a `String` to change text
in place.

#### Static

A `Static` is a `?String` known to view only bytes that live for the
whole program. It is plain data: it copies, it carries no loan, and it
has the same bytes and operations as a `?String` (`len`, indexing,
slicing, `for`, `==` and `<`). Where a `Static` comes from is one list;
nothing else has the type:

- a string literal (`"hello"`, so a constant made of literals too);
- a name, field, element, or call whose declared type is `Static` or
  holds one (`os.env`, `os.args`, [std.os](docs/STD.md));
- a slice `k[a..b]` of a `Static`, which views the same bytes;
- a branch (`a if c else b`, `if`, `match`), a `??`, or a list literal
  whose every value is a `Static`.

A `?String` that may view a `String` (a parameter, `?t[..]`, the result of
a function over `?String` values such as `text.trim("  a  ")`) is not one, and
nothing turns a `?String` into a `Static`. A `Static` is read as a
`?String` where the text is only read: an argument or a field of type
`?String`, a returned or bound `?String`, a `Static?` as a `(?String)?`, a
`[]Static` as a `[]?String` (so an array or a List of `Static`, lent to read, is one), and in a branch, a `??`, or a list literal
that mixes the two (their type is `?String`). A generic `T` that a
`Static` and a `?String` both bind is the `?String` (unless a place that
holds it exactly, such as a `Cell[T]`, gives the type). `@name(Static)`
is `"Static"`, but a type parameter bound to a `Static` is named
`"?String"`, since both are one Zig type. It never converts
where the text can be written: a place of type `Static` holds only a
`Static`, a `?String` is not written into one, and a binding that holds a
literal is a `Static` (`s = "a"`), so a `?String` is assigned to it only
when it is declared `s: ?String = "a"`.

Because a `Static` carries no loan, it goes where no loan is tracked:
in a `Cell`, a `Signal`, an owned closure, and in an object field or a
generic `T` kept there. A `?String` there is rejected by its type, with
a hint that points to a `?String` parameter for text that is only read.

```rig
obj Tag
  name: Static
  n: Int

fun later(who: Static) -> *sub()
  *|+who| print(who)

sub keep(c: !Cell[Static], s: Static)
  !c.set(s)

sub main()
  c = *Cell("idle")
  keep(!c, "busy")
  tag: *Cell[Tag] = *Cell(Tag(name: "a", n: 1))
  !tag.set(Tag(name: "b", n: 2))
  f = later("hi")
  f()
  print(c.get(), tag.get().name, "x" if tag.get().n > 1 else "y")
```

```output
hi
busy b x
```

```rig reject
sub keep(c: !Cell[Static], s: Static)
  !c.set(s)

sub main()
  t = String("abc")
  c = *Cell("a")
  keep(!c, ?t[..])
```

```error
type mismatch: expected `Static`, got `?String`
```

### Arrays

`[N]T` is a fixed-size array. Its length is known at compile time: an
integer, a constant (`[LIMIT]T`, `[lib.N]T`), a compile-time integer
parameter (`[n]T` in `fun zeros[n: Int]() -> [n]Int`,
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
List's does.
An array holds any value, as a List does, and drops its elements with
itself; `for x in <a` hands them over one at a time. `[n of x]`
copies `x` into every slot, so it needs a value that copies. An array
of arrays is `[2][3]T`:
two rows of three.

```rig
LIMIT = 4

fun zeros[n: Int]() -> [n]Int
  [n of 0]

sub main()
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

fun zeros[n: Int]() -> [n]Int
  [0, 0]

sub main()
  k = 3
  a: [k]Int = [1, 2, 3]
  b = [-1 of 0]
  c = [2 of List[Int]()]
```

```error
an array length `n + 1` does arithmetic on a compile-time parameter
an array of compile-time length `n` is built with `[n of x]`
an array length must be known at compile time; `k` is not
array length -1 is out of range
`[n of x]` copies its element into every slot, and a `List[Int]` owns a resource
```

A value takes at most 8 MiB (8388608 bytes, a `[1048576]Int`): an
array, an object or an enum, and each instance of a generic type or
function, for the arrays it makes and, for a type, for itself. A
`Cell` or `Signal` holds its value inline, so it counts at the size of
what it holds. The values a function keeps on its stack take at most 13 MiB together:
the bindings it declares and its by-value parameters, each once, every
array literal and fill whose value no binding takes directly, and every
call of a function or method (twice when a binding takes its result,
since a debug build holds it in a temporary first). The frames of the
small functions inlined into it count too, and a call that would take
the frame over the limit is not inlined; a call of a function marked
`inline` ([Function markers](#function-markers)) is, with the values it
keeps at the instance the call makes, and the frame over the limit is an
error. This holds for every frame the program has: every function,
method, closure (whose captures count where it is made), test, `drop`
body, and `main`, and each instance of a generic one; a `defer` body, a
match arm, or a loop is part of the frame around it. A small method of
a generic type is inlined or not for all its instances, as its largest
frame at any of them allows. The limit keeps large
data on the heap: the error names the largest locals; keep large data
in a box (`^T`) or a `List`, which holds its elements on the heap.
`^[n of x]` fills the box's memory itself, never making the array on the
stack first, and a fill that declares or reassigns a local array is made
in the local. A value or function too large is reported once; a type or function
holding a value too large is not reported again.

A build may hold each value a function's code makes or copies (an
argument passed by value, a copy of a place, the value of an `if`, `??`,
or `catch`, a constructor's) in a temporary of its own, so a function's
code may take more stack than the values it keeps. Its *reach*, the
values it keeps and every value its code makes or copies (a `defer` or
`errdefer` body once for each exit it covers, a receiver taken by value
at each call, and a function inlined into it, small or marked `inline`,
at each call and at each copy of a `defer` body that calls it), times 4
is at most 512 MiB, and a function, closure, or `drop` body whose reach
times 4 is 1 MiB or more is never inlined, so no two such frames merge
into one; a function marked `inline` is inlined still, and its caller's
reach holds it, so the caller is the frame kept out of line. The factor
4 is measured, not proven: the frames each form takes are checked
against it, and a form the compiler does not yet model could take more.

A program runs on a stack of 64 MiB, with a guard of 64 GiB of address
space below it, or 1 GiB where 64 GiB cannot be reserved. A program that
runs out of stack, through deep recursion or a frame no larger than the
guard, stops with a stack-overflow error (`error: rig: stack overflow`)
before writing beyond the stack, in every build mode. A program that
cannot reserve its stack and the guard stops before it runs, with `rig:
cannot reserve the program's stack and the guard below it` and exit
status 1 ([INTERNALS](docs/INTERNALS.md#the-programs-stack) describes the
mechanism).

```rig reject
obj Grid
  cells: [1024][1024]Int
  more: [8]Int

fun sums(k: Int) -> Int
  a = [800000 of k]
  b = [800000 of k]
  c = [800000 of k]
  a[0] + b[0] + c[0]

sub main()
  big = [2000000 of 0]
  print(big.len, sums(1))
```

```error
`Grid` takes 8388672 bytes; a value takes at most 8388608 (8 MiB)
`sums` keeps 19200008 bytes of values on its stack; a function keeps at most 13631488 (13 MiB)
`[2000000]Int` takes 16000000 bytes
```

### Slices

`xs[a..b]` is the part of `xs` from index `a` up to, not including,
`b`. Of a `?String` it is a `?String`. Of an array or a `List` it is
written `?xs[a..b]`, or with no `?` as an argument, as `xs` itself is
lent: a `[]T`, a read view of the elements, which lends
part of `xs` ([§7](#lending)), so `xs` cannot be
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

sub main()
  s = "hello, world"
  print(s[0..5], s[7..s.len])
  a = [1, 2, 3, 4]
  mid = ?a[1..3]
  print(mid, mid.len, mid[0], total(mid), total(?a[0..4]))
  print(s[7..], s[..5], a[2..], total(?a[..]))
```

```output
hello world
[2, 3] 2 2 5 10
world hello [3, 4] 10
```

```rig reject
sub main()
  for i in 0..
    print(i)
```

```error
a range needs an end; only a slice leaves a side open
```

A viewed array parameter (`xs: ?[N]T`) points at the caller's array,
so a function may return a slice of it (`?xs[1..3]`) or a view of an
element, as it may of a `[]T` parameter; the result views the
caller's array. An array parameter taken by value (`xs: [N]T`) is the
function's own, so a view of it cannot be returned.

Where a `[]T` is expected, `?a` of an array or a List means `?a[..]`,
and where a `![]T` is expected, `!a` means `!a[..]`, also through a box
or a read view ([§7](#lending) has every lend). As an argument the `?`
may go unwritten (`total(a)` is `total(?a)`), and a slice is lent the
way its name is (`total(a[1..])` is `total(?a[1..])`); anywhere else,
such as a binding or a field, the lend is written. A slice argument
whose parameter takes no read view is rejected: `!a[1..]` lends it to
write where a `![]T` goes, and a parameter that owns its value takes a
copy (`String(?t[1..])`). A temporary array, a literal,
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

sub main()
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

```rig
fun total(xs: []Int) -> Int
  n = 0
  for x in xs
    n += x
  n

fun size(s: ?String) -> Int
  s.len

sub main()
  a = [1, 2, 3, 4]
  t = String("hello")
  print(total(a[1..3]), total(?a[1..3]), size(t[1..]))
```

```output
5 5 4
```

```rig reject
sub zero(s: ![]Int)
  !s.fill(0)

sub main()
  a = [1, 2, 3]
  zero(a[1..])
  print(a)
```

```error
`zero` writes the elements of `a[1..]`, and a slice is lent to read unless it is written `!`; write `zero(!a[1..])`
```

```rig reject
fun total(xs: []Int) -> Int
  xs.len

fun id(xs: []Int) -> []Int
  xs

sub main()
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

sub main()
  r = id([1, 2])
  print(r)
```

```error
a view of the temporary `[1, 2]` outlives its statement
```

`!xs[a..b]` is a **writable slice**, of type `![]T`: a write view of
the elements, taken of an array or a `List` that could be
lent to write (`!xs`), or of another `![]T`. A `?String` and a `[]T` are
read-only, and so is what a fixed binding, a loop or pattern binding,
or a parameter other than a `!T` one holds. A `![]T` is a write view
like any other ([§7](#write-views)): while it is live, what it
views cannot otherwise be used, so two live write slices of one
array, or a `push` to a List while a slice of it is live, are rejected;
it cannot be copied or cloned (`<s` moves it), a call lends on it, and
it is returned only when it views from a `!` parameter. Its elements
are assigned (`s[i] = v`, `s[i] += 1`), lent to write (`!s[i]`), and
written in a loop (`for x in !s`); `!s[a..b]` reslices it, and
`?s[a..b]` takes a read slice, which keeps `s` from being written while
it lives (a bare `s[a..b]`, which would lend `s` unseen, is
rejected). A `![]T` is accepted wherever a `[]T` is expected; as an
argument it is then lent to read, like `?s[..]`, so `sum2(w, w)` with
two `[]T` parameters reads `w` twice, and `w` can be read, but not
written, while a view returned from it lives. A `[]T` is never
lent to write: `!t` of one is rejected. A slice views any element
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

sub main()
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
sub main()
  a = [1, 2, 3, 4]
  x = !a[..2]
  y = !a[2..]
  x[0] = y[0]
```

```error
cannot lend `a` to write while a write loan is live
```

Three methods write the elements of a `![]T`, an array, or a List,
whose receiver is written `!xs` (or is a `![]T` binding):
`!dst.copy(src)` copies a `[]T` of the same length into them, and
panics in every build mode when the lengths differ; `!s.fill(v)` sets
every element to `v`; `!s.swap(i, j)` exchanges two elements of any
type, with both indexes checked. `copy` and `fill` duplicate values, as
`[n of x]` does, so their elements are values that copy
([§2](#kinds-of-value)): plain data or read views, each copy of a view
carrying its loan. `copy`'s receiver and argument never overlap:
the write view of the receiver excludes a read of the same value.

```rig
sub main()
  a = [1, 2, 3, 4, 5, 6]
  b = [9, 8, 7]
  !a[..3].copy(?b[..])
  !a[3..].fill(0)
  !a.swap(0, 5)
  t: List[String] = List()
  !t.push(String("x"))
  !t.push(String("y"))
  !t.swap(0, 1)
  print(a, t)
```

```output
[0, 8, 7, 0, 0, 9] ["y", "x"]
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

sub main()
  a = [5, 3, 9, 1, 7]
  quicksort(!a[..])
  print(a)
```

```output
[1, 3, 5, 7, 9]
```

```rig reject
sub main()
  a = [1, 2, 3, 4]
  !a[..2].copy(?a[2..])
```

```error
cannot lend `a` to write while a read loan is live
```

```rig reject
sub main()
  v: List[Int] = List()
  !v.push(1)
  w = !v[..]
  !v.push(2)
  w[0] = 5
```

```error
use of `v` while a write loan is live
```

```rig reject
sub main()
  s = "text"
  t = !s[1..]
  t[0] = 65
```

```error
cannot lend a slice of a `?String` to write; a `?String` is read-only
```

### Bytes

Bytes hold fixed-size numbers. `bytes.read[T, e](at)` is the integer
or float `T` stored in the `@size(T)` bytes from offset `at`, in byte
order `e`, and `!bytes.write[T, e](at, v)` stores `v` there. `T` is any
integer or float type, a vector of them ([Vectors](#reading-bytes-into-a-vector)),
or a type parameter every instance gives one of the first;
`e` is a compile-time value of the built-in enum
`Endian`, `.little` or `.big` (a literal, `Endian.big`, a constant, or
a compile-time parameter; there is no native order). A one-byte `T`
(`U8`, `I8`) has no byte order and takes no `e`: `read[U8](at)`,
`write[U8](at, v)`. `read` works on a
`[]U8`, an `![]U8`, a `[N]U8`, a `List[U8]`, and a `?String`; `write` on
the writable ones, written `!bytes` (or an `![]U8` binding). Every byte
must be in range, `0 <= at` and `at + @size(T) <= len`: a constant
offset into an array is checked at compile time, and any other when the
program runs, which panics in every build mode when it is not. A float
is read and written by its bits, so a NaN's payload survives. `Endian`
is a built-in name, like `List`, and is reserved. A String appends a
number's bytes with `!t.push[T, e](v)` ([String](#string)).

```rig
sub main()
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
sub main()
  b: [8]U8 = [8 of 0]
  print(b.read[U32, .little](6))
  print(b.read[U16, .native](0))
```

```error
`read` of a `U32` at `6` runs past the end of an array of length 8: it needs 4 bytes
no variant `native` on enum `Endian`
```

### Vectors

`Simd[T, n]` is a vector: `n` lanes of one number type or `Bool` `T`,
held and operated on together, as the target's vector registers hold
them. `n` is a power of two from 2 to 64, a constant or a compile-time
integer parameter (`fun f[n: Int](v: Simd[U8, n])`), which each
instance checks. A vector is plain data, one value like an `Int`
([Core §1](docs/CORE.md#1-four-kinds-of-value)): a bare use copies it,
and a field, an element, an optional, a `Cell`, or a closure holds a
copy. A **mask** is `Simd[Bool, n]`, what a lane-wise comparison gives.
`Simd` is a built-in name, like `List`, and is reserved; a program
names the vectors it uses with an alias, `type Block = Simd[U8, 64]`.

A vector is made from one value for every lane, `Simd[T, n].splat(x)`,
from an array of its lanes, `Simd[T, n](a)` with `a` a `[n]T`, or from
bytes ([below](#reading-bytes-into-a-vector)). It prints as the array of
its lanes.

**Operators work lane by lane.** `+`, `-`, `*`, their wrapping forms
`+%`, `-%`, `*%`, their saturating forms `+|`, `-|`, `&`, `|`, `^`, and
`-v` give a vector of the same type, and `==`, `!=`, `<`, `<=`, `>`, and
`>=` give a mask. Each lane follows the scalar rule for its type: `+`,
`-`, `*`, and `-v` panic when any lane overflows in debug and safe
builds, and in `--release=fast` are unchecked (an overflowing lane is
undefined behavior, as a scalar's is), the wrapping forms wrap, and the saturating forms stop at the lane
type's limits; the integer operators take integer lanes, `&`, `|`, and
`^` also a mask's, the orderings number lanes, and `-v` signed or float
lanes. A scalar of the lane type, or a literal that fits it, stands for
every lane, on either side: `v < 0x20`, `v == quote`, `1 + v`. The
shifts `v << c`, `v <<% c`, and `v >> c` move every integer lane by one
amount `c`, an integer, below the lane's bit count, with the scalar rules: a
constant `c` at or over it is rejected and a run-time one
panics, `<<` panics where a lane loses bits (or its sign) under the same rule
(fast does not check), `<<%` drops them, and `>>` is arithmetic on signed lanes. The compound forms
(`v += 1`, `m |= v == q`, `v >>= 4`) assign the result. `/` and `%`
take no vector. A vector's lanes are computed only when the program
runs, even from constants: where a constant scalar that overflows is
rejected (`x: I8 = -128` then `x * -1`), a lane that overflows panics
when the program runs (`Simd[I8, 4].splat(-128) * -1`). Both stop the
program before it uses a wrong value. Precedence is unchanged, so masks are combined in
parentheses: `(v == 0x22) | (v == 0x5C)`.

**Masks.** `m.bits()` is a `U64` whose bit `i` is lane `i`, the higher
bits 0, for every lane count, so `m.bits().count_ones()` counts the true
lanes. `m.first()` is the index of the first true lane, an `Int?`: `none`
when no lane is true. It is the way to find a lane after a test, and the
one to write: `if hits.first() as k` tests and locates in one step, where
`hits.any()` then `hits.bits()` reduces the mask twice. On a 16-lane mask
it is a single crossing from the vector to a register on ARM. `m.any()` and
`m.all()` reduce a mask to a `Bool`, `m.not()` flips every lane (as
`v.not()` flips every bit of an integer vector), and `m.select(a, b)`
is the vector whose lane `i` is `a`'s where `m`'s is true and `b`'s
where it is false; `a` and `b` are vectors with as many lanes, or
scalars standing for every lane. A mask is not a `Bool`, so a condition,
`and`, `or`, `not`, and a ternary reject it, with the form that reduces
it or combines it.

**Tables and neighbours.** `t.lookup(idx)` looks bytes up in a table:
`t` is a `Simd[U8, 16]`, `Simd[U8, 32]`, or `Simd[U8, 64]`, `idx` a
`Simd[U8, n]` of any lane count, and lane `i` of the result, a
`Simd[U8, n]`, is `t[idx[i]]`, or 0 where `idx[i]` is past the table.
It lowers to the target's table instruction (`tbl` on ARM, `pshufb` on
x86, `i8x16.swizzle` on WASM), 16 indexes at a time, and to a loop where
there is none. `cur.lag[k](prev)` is the vector whose lanes are those of
`prev` then `cur`, `k` lanes back from the end: lane `i` is `cur[i - k]`
for `i >= k` and `prev[n - k + i]` below, so each lane sees the lane `k`
before it in a stream of vectors. `k` is a constant from 1 to `n - 1`,
checked when the program is checked, and `prev` is of `cur`'s type,
whose lanes may be any. A module constant may hold a vector made of
constants: `Simd[T, n](array)` or `Simd[T, n].splat(x)`.

```rig
type Block = Simd[U8, 16]

HEX = Block([0x30, 0x31, 0x32, 0x33, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x61, 0x62, 0x63, 0x64, 0x65, 0x66])

sub main()
  v = Block([0xC3, 0xA9, 0x41, 0xE2, 0x82, 0xAC, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xF0])
  high = HEX.lookup(v >> 4)
  low = HEX.lookup(v & 0x0F)
  print(high[0], low[0], HEX.lookup(Block.splat(16))[0])
  before = v.lag[1](Block.splat(0x20))
  print(before[0], before[1], (v -| 0xBF)[1], (v +| 0x40)[0])
  print(((v.lag[1](Block.splat(0)) >= 0xC0) & (v < 0xC0)).bits())
```

```output
99 51 0
32 195 0 255
18
```

```rig reject
sub main()
  v = Simd[U8, 16].splat(1)
  print(v.lag[16](v), v >> 8, Simd[U16, 16].splat(1).lookup(v))
```

```error
`lag` of a `Simd[U8, 16]` takes 1 to 15 lanes; got `16`
shift amount `8` is out of range for `U8` (0..7)
`lookup` looks up bytes in a table of 16, 32, or 64 of them
```

**Lanes are values, not places**, as an `Int`'s bits are. `v[i]` reads
lane `i`, its index checked as an element's is (a constant one when the
program is checked). `v.with(i, x)` is a copy of `v` whose lane `i` is
`x`, and `v.array()` the lanes as a `[n]T`, which a `for` walks. A lane
is never assigned, lent, or taken: `v[i] = x` is written
`v = v.with(i, x)`.

```rig
type Block = Simd[U8, 16]

QUOTE: U8 = 0x22
BACKSLASH: U8 = 0x5C

# The index of the first `"` or `\` from `at` on, or `s.len`: 16 bytes
# at a time, then the bytes after the last whole block.
fun find_quote(s: ?String, at: Int) -> Int
  i = at
  while i + 16 <= s.len : i += 16
    v = s.read[Block](i)
    hits = (v == QUOTE) | (v == BACKSLASH)
    if hits.first() as k
      return i + k
  while i < s.len : i += 1
    return i if s[i] == QUOTE or s[i] == BACKSLASH
  s.len

sub main()
  s = "say \"hi\" \\ there, then plain text"
  print(find_quote(s, 0), find_quote(s, 5), find_quote(s, 8), find_quote(s, 10))
  v = Simd[I32, 4]([1, -2, 3, -4])
  m = v < 0
  print(v * 2, v +% 1, m, m.bits(), m.select(-v, v))
  print(v[1], v.with(0, 9), (v == 3).any(), (v != 0).all())
```

```output
4 7 9 33
[2, -4, 6, -8] [2, -1, 4, -3] [false, true, false, true] 10 [1, 2, 3, 4]
-2 [9, -2, 3, -4] true true
```

```rig reject
sub main()
  v = Simd[U8, 16].splat(0x20)
  if v == 0x20
    print("blank")
  v[0] = 0x41
  print(v + 300)
```

```error
`v == 0x20` is a mask, `Simd[Bool, 16]`, not a `Bool`: write `(v == 0x20).any()` or `(v == 0x20).all()`
a lane of `v` is a value, not a place, so it is not assigned: write `v = v.with(0, x)`
integer value `300` does not fit in `U8` (0..255)
```

#### Reading bytes into a vector

`read` and `write` ([Bytes](#bytes)) take a vector of number lanes:
`bytes.read[Simd[T, n], e](at)` is the `n` values of type `T` held one
after another from `at`, lane `i` at `at + i * @size(T)`, each in byte
order `e`, and `!bytes.write[Simd[T, n], e](at, v)` stores them. As a
one-byte `T` does, a vector of one-byte lanes takes no byte order:
`s.read[Simd[U8, 64]](at)`. A read or write is checked once, for every
byte it touches, and loads or stores the vector whole: the program
reads no byte past `at + n * @size(T)`.

**A vector is one value.** It has no `==` of its own beyond its lanes',
so an object, enum, array, or optional that holds one has none, and a
generic `T` that is one cannot be compared. Its size and alignment are
the target's, so `@size` and `@align` take no type that holds one
inline (a `List` of vectors holds them on the heap, and has a size). A
generic body applies to a vector `T` only what it applies to plain data:
it copies, moves, prints, and stores one, but arithmetic and comparisons
on a `T` take a number.

```rig reject
obj Lexer
  ahead: Simd[U8, 16]

sub main()
  a = Lexer(ahead: Simd[U8, 16].splat(0))
  print(a == a, @size(Lexer))
```

```error
`==` is not defined for `Lexer`: field `ahead` is a `Simd[U8, 16]`, whose `==` compares lane by lane
`@size` takes no type that holds a vector
```

### Composite and handle types

| Type | Meaning | Section |
|---|---|---|
| `[]T` | slice: a read-only view of elements | [§2](#slices) |
| `![]T` | writable slice: a write view of elements | [§2](#slices) |
| `T?` | optional: a `T` or `none` | [§12](#12-optionals) |
| `T!` | fallible: a `T` or an error; only as a return type, including a function type's | [§13](#13-errors) |
| `?T` | read view of a `T` (parameters, returns, locals, fields) | [§7](#7-ownership) |
| `!T` | write view of a `T` (parameters, receivers, returns, locals) | [§7](#write-views) |
| `^T` | box: one `T` alone on the heap, with one owner | [§10](#box) |
| `*T` | shared handle: reference-counted, single-threaded | [§9](#9-shared-and-weak-handles) |
| `~T` | weak handle to a shared value | [§9](#9-shared-and-weak-handles) |
| `fun(A, B) -> R`, `sub(A)` | function and closure types | [§11](#11-closures) |
| `*fun(A) -> R`, `*sub(A)` | owned closure (a shared handle) | [§11](#11-closures) |
| `?fun(A) -> R`, `?sub(A)` | callable view: a closure, function, or owned closure lent to a call | [§11](#callable-views) |
| `Cell[T]`, `List[T]`, `^T`, `Signal[T]` | built-in generic types | [§10](#10-cell-list-box-string-and-signal) |
| `String` | owned, growable text | [§10](#string) |
| `Endian` | built-in enum: the byte order of `read` and `write` | [§2](#bytes) |
| `Arch` | built-in enum: the target's processor architecture, `target.arch` | [§3](#the-target) |
| `Simd[T, n]` | vector: `n` lanes of a number or `Bool`, operated on together; `Simd[Bool, n]` is a mask | [§2](#vectors) |
| `Name`, `Name[T]`, `mod.Name` | user types, generic instances, imported types | [§3](#3-declarations), [§14](#14-modules) |

How the sigils of a type combine (`*User?` is an optional handle,
`?User?` a view of an optional) is in
[SYNTAX §7](SYNTAX.md#7-types). A handle holds a value, never a
`?T`, `!T`, or slice: `*(?User)` is rejected.

Two kinds of type stand only in some places (Core §5 and sentence 9):

- A write view, `!T` or `![]T` (also as `(!T)?` and `(!T)!`), is only a
  parameter's, a receiver's, a result's, or a local or header binding's
  type. It is never a field's, an element's, a type argument, or what
  an optional, a read view, or a handle holds
  ([Write views](#write-views)).
- A type that holds a `Cell` by value (a `Cell[T]`, or an object or enum
  a field of which holds one) is a field's type, or stands behind `*`,
  `~`, or a read view. It is never a local's, a parameter's, or a
  result's type by value, a type argument, an element, or an optional
  ([Cell](#cell)).

### Kinds of value

> **Core §1:** An object's or enum's kind follows from its parts.

Every type is one of four kinds, which decide what a bare name does
where its value is taken ([§7](#reading)):

| Kind | Types | A bare name where the value is taken |
|---|---|---|
| **plain** | numbers, `Bool`, plain enums, vectors (`Simd[T, n]`), and optionals, arrays, objects, and enums of them | copies it |
| **owning** | `List`, `^T`, `String`, `Signal`, `error`, and any type that holds an owner or a handle, or declares a `drop` body | moves it only as `return x`, or the last value of the function or block that declares it; anywhere else it is rejected: `<x` moves it, `+x` makes a new owner |
| **handle** | `*T`, `~T`, and owned closures | the same: `<h` moves it, `+h` adds a count |
| **view** | `?T`, `!T`, `[]T`, `![]T`, `?String`, `?fun(...)`, and any type that holds one | copies a read view; a write view is rejected: `<w` moves it |

An object, enum, optional, or array is owning if any part is owning or a
handle; otherwise a view if any part is a view; otherwise plain. No
part is a write view ([Write views](#write-views)). Copying a read view copies the view, not
what it views, and every copy carries the same loan. Owning values and
handles have **drop glue** ([§8](#8-drop-and-drop-glue)): code the
compiler generates to release them.

**Plain data**, in this reference, is a value that owns nothing and
holds no `?T`, `!T`, or slice: a plain value, a `?String`, or an
optional, array, object, or enum of them. It copies freely. A `?String` in
it is still a view, which may carry a String's loan ([strings](#strings)).

A **unique** value owns nothing to release but must not be copied: a
object declared `unique` (`obj Random unique`, a generator whose
copy would repeat its numbers), or any object, enum, array, or generic
instance that holds one inline. It moves like an owning value, has no
clone (`+x`) and no `==`, and nothing copies it out of a place; it has
no drop glue, so a discarded one is simply dropped. A loop that reads
an array or slice of them binds a view of each element (`?E`), never a
copy. A value that holds a `Cell` is never copied either, since a copy
would fork the state it shares: it lives only behind a shared handle,
which is what is copied, moved, or cloned ([Cell](#cell)).

```rig reject
obj Seed unique
  n: Int

sub main()
  a = Seed(n: 1)
  b = a
  print(b.n)
```

```error
`a` is a unique `Seed`, which can't be copied by `=`: write `<a` to move it or `?a` to view it
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

Parameters are immutable; assigning a `!T` parameter writes through to
the value it views ([§4](#view-places)). A parameter the body ignores
may be named `_`, any number of times. A parameter may have a default
value: a literal or a module constant (`LIMIT`, `lib.LIMIT`, `U8.max`),
which means the same value at every call, in any module. A call passes
arguments by position, by keyword, or both, positional arguments first
([SYNTAX §11](SYNTAX.md#calls)). Each parameter gets exactly one
argument, and every parameter without a default needs one; arity,
keyword names, and argument types are checked. Arguments are evaluated
in the order written.

```rig reject
fun scaled(n: Int, by: Int = 10) -> Int
  n * by

sub main()
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

### Several results

A function may give several results at once, written as a list of types
after `->`: `-> (Int, Int)`, two or more. Each result is a type one
result may have, a view included, and the list may fail or be absent as
a whole: `-> (A, B)!`, `-> (A, B)?`. `return a, b` gives them, and a
call's results are bound by name, each where it stands:

```rig
fun divmod(a: Int, b: Int) -> (Int, Int)
  return a / b, a % b

fun again(a: Int, b: Int) -> (Int, Int)
  return divmod(a, b)

sub main()
  q, r = divmod(17, 5)
  print(q, r)
  _, r = divmod(9, 4)
  new q, r = again(1, 1)
  a, b =! divmod(8, 3)
  print(q, r, a, b)
```

```output
3 2
1 0 2 2
```

The results never form a value: a call that gives several stands only
where each result is bound at once (`q, r = f()`, `if f() as q, r`, and
`while f() as q, r`), or where the function returns them whole
(`return f()`, to a function that gives the same results), or where
they are all discarded, as one result is: a call alone on its line
discards results that own nothing, and `_ = f()` discards any. Anywhere
else, as an argument, an operand, or a single binding, it is rejected,
and so is `(Int, Int)` as the type of a value: a group of values that
lives past its statement is an object.

```rig reject
fun divmod(a: Int, b: Int) -> (Int, Int)
  return a / b, a % b

sub main()
  p = divmod(17, 5)
```

```error
`divmod` gives 2 results; bind each: `a, b = divmod(17, 5)`
```

```rig reject
fun divmod(a: Int, b: Int) -> (Int, Int)
  return a / b, a % b

sub main()
  print(divmod(17, 5))
```

```error
a call that gives several results stands only where each result is bound
```

```rig reject
sub main()
  xs: List[(Int, Int)] = List()
```

```error
`(Int, Int)` is a function's results, not a type a value can have: name an object for a stored pair
```

**Binding.** `q, r = f()` binds the results left to right, each name by
the rule `x = e` has (§4): it declares the name, or assigns the visible
one, writing through a `!T` local given a value and re-pointing it
given a write view; an assigned name drops its old value. `new q, r =
f()` declares new names, and `q, r =! f()` fixed ones. `_`
discards a result, which is dropped at the statement's end, after the
bindings, the last first. Every result is bound or discarded: the names match the
results in number. Each target is a name or `_`, each named once; a
field or element is assigned on its own line. The parentheses of a
result type are not written on the left.

```rig reject
fun divmod(a: Int, b: Int) -> (Int, Int)
  return a / b, a % b

sub main()
  q, r, s = divmod(17, 5)
```

```error
`divmod` gives 2 results, but 3 names are bound
```

```rig reject
fun divmod(a: Int, b: Int) -> (Int, Int)
  return a / b, a % b

sub main()
  xs = [0, 0]
  i = 0
  i, xs[i] = divmod(1, 2)
  print(xs)
```

```error
each result is bound to a name, and `xs[i]` reads `i`, which this statement binds
```

```rig reject
fun divmod(a: Int, b: Int) -> (Int, Int)
  return a / b, a % b

sub main()
  (q, r) = divmod(17, 5)
```

```error
write `q, r = divmod(17, 5)`; parentheses aren't needed on the left
```

Rig has no parallel assignment: the right side is one call. Two places
are exchanged with `swap` (§7, "Replace and swap").

```rig reject
sub main()
  a = 1
  b = 2
  a, b = b, a
  print(a, b)
```

```error
Rig has no parallel assignment: write `swap(!a, !b)` to exchange two places
```

**Failing and absent results.** `q, r = f()!` and `q, r = f()?` pass
the failure or the `none` on before anything is bound, and so does a
fallback that jumps: `q, r = f() ?? return`, `q, r = f() catch break`.
A fallback that is a value is not taken. `if f() as q, r` and `while
f() as q, r` bind the results inside an optional to new names over the
body, as `as` binds one value. Each is named there: a header's
temporaries end before its body runs, so `as` takes no `_`; a result
the body does not need is discarded there with `_ = name`. A `while`
step cannot read the names its condition binds this way, which live
only in the body.

```rig
fun cut(s: ?String, sep: U8) -> (?String, ?String)? from s
  i = 0
  while i < s.len
    return s[..i], s[i + 1..] if s[i] == sep
    i += 1
  none

fun pair(s: ?String) -> (?String, ?String)? from s
  k, v = cut(s, 61)?
  return v, k

sub main()
  if cut("key=value", 61) as key, value
    print(key, value)
  if pair("a=b") as v, k
    print(v, k)
  k, v = cut("none here", 61) ?? return
  print(k, v)
```

```output
key value
b a
```

**Giving them.** `return a, b` gives each part as `return x` gives `x`,
left to right: a bare owner moves out, and so does a bare write view
given as a write view, which a later part may not use again; one read
as a value that copies is a copy. A part's loans are judged by its own
result's type: a view must be of what the function was lent. A bare last line `a, b` is no statement: results are
given with `return`. A part that fails after an earlier one was made
drops the earlier one on the way out.

```rig reject
fun f(a: Int) -> (Int, Int)
  a, a
```

```error
results are written `return a, a`
```

**Loans.** Each result carries the loans its own type could hold of
what the call was lent (§7, "How long a loan lasts"), so a `Bool` beside
a view carries none. One result may be a write view, which keeps its
owner lent to write as a `!T` result does, beside results that hold no
view of what it views: a function that gives two write views, or a
write view and another result that could view the same parameter, is
rejected where it is declared. While a result may hold a write view,
every lend the call made lasts to the statement's end, as for a `!T`
result, and an `if … as` part's to its end, as a header is its own
statement: the first version decides this per call, not per argument,
though the write view carries only the arguments its signature names. A
target is bound only while no result still waiting for its own target
views it, nor a result `_` discards whose drop runs a `drop` body,
which drops at the statement's end; a discarded result whose drop runs
none reads none of its views (§7), and keeps nothing lent.

```rig
obj Counter
  n: Int
  m: Int

  fun bump(!self, k: Int) -> (!Int, Bool)
    self.n += k
    return !self.m, self.n > 3

sub main()
  c = Counter(n: 0, m: 0)
  w, big = (!c).bump(5)
  w += 10
  print(big, c.m)
```

```output
true 10
```

```rig reject
obj M
  a: Int

  fun two(!self) -> (!Int, ?Int)
    return !self.a, ?self.a
```

```error
`two` gives a write view and another result, `?Int`, that could both view `self`
```

```rig reject
fun two(s: ?String) -> (String, ?String)
  return String(s), s

sub main()
  s = String("ab")
  s, v = two(?s)
  print(v)
```

```error
cannot bind `s` while `v` views it
```

A function type takes several results as a function does: `?fun(Int) ->
(Int, Int)`. Named results, a `for` that binds several results a step,
and several results nested in a type argument are not Rig's.

At most one result is a write view in this first version, a limit of
its own rather than a rule of the ownership model: two write views of
different arguments are disjoint, and will be allowed.

```rig pending
fun both(a: !Int, b: !Int) -> (!Int, !Int)
  return a, b

sub main()
  x = 1
  y = 2
  p, q = both(!x, !y)
  p += 10
  q += 20
  print(x, y)
```

```output
11 22
```

### Function markers

A function may be marked, before its `fun` or `sub`, with one of three
words that ask for a speed and never change what the program means:

- `inline fun` inlines the function at every call: its body is compiled
  into each caller, whatever its size. A call means what it means
  without the marker: its arguments are evaluated in order, a check on
  them panics when the program runs (never when it compiles), and an
  owned argument is moved in and dropped as in a call.
- `called fun` keeps every call of the function a real call: it is
  never inlined, and stays as hot as any function. Each instance of one
  with compile-time parameters is a function of its own, so two
  specialized copies of a large function stay apart, each called.
- `rarely fun` says the function is rarely called, so the code that
  calls it is laid out for the case that does not: the function stays
  out of line, as `called` keeps it, and is also cold.

Without a marker the compiler decides which small functions to inline
([INTERNALS](docs/INTERNALS.md), "Inlining"). A marker applies to every
instance of a function with compile-time parameters, and a method
takes one as any function does, in its type's body or outside it.

```rig
inline fun clamp(x: Int, lo: Int, hi: Int) -> Int
  lo if x < lo else hi if x > hi else x

rarely fun report(n: Int) -> Int
  print("out of range:", n)
  0

called fun scan[strict: Bool](xs: ?List[Int]) -> Int
  total = 0
  for x in xs
    if x > 99
      total += report(x) if strict else clamp(x, 0, 99)
    else
      total += clamp(x, 0, 99)
  total

sub main()
  xs = List[Int]()
  !xs.push(5)
  !xs.push(-3)
  !xs.push(120)
  print(scan[true](xs), scan[false](xs))
```

```output
out of range: 120
5 104
```

An `inline` function has no address, so it is only called: naming it
as a value is an error, and a closure that calls it is a value. One
that calls itself, directly or through other `inline` functions, cannot
be inlined into itself, and is an error; a cycle through a function
that is not `inline` is a call there, and so is a call in a closure,
which is a function of its own. A function's frame counts the `inline`
functions inlined in it, each at the instance its call makes, however
the call names the function (through a module, a type, or an alias of
either), and one over the limit ([§2](#arrays)) is an error. A call
whose values the check cannot count is an error too, never counted as
none. Calls of `inline` functions nest at most 256 deep, each inlined
into the one around it; a deeper chain is an error.

```rig reject
inline fun count(n: Int) -> Int
  0 if n == 0 else 1 + count(n - 1)

inline fun next(n: Int) -> Int
  n + 1

sub main()
  f = next
  print(count(3), f(1))
```

```error
`next` is `inline`, inlined at every call, so it can only be called, not used as a value
```

A function takes one marker: `inline` and `called` contradict each
other, and `rarely` already keeps every call a call, so any two are an
error (`inline rarely fun`, `rarely called fun`). A `called` or `rarely`
function is a function value as any other. The
program's `main`, which the program calls once, takes none, and neither
does an `extern zig` function, whose body is Zig's.

```rig reject
inline rarely fun f() -> Int
  1

sub main()
  print(f())
```

```error
a function takes one marker
```

### Objects

**An object is a value; `^` puts it on the heap and `*` shares it.** An object lives
where it is declared and has no identity of its own
([Core §1](docs/CORE.md#1-four-kinds-of-value)).

An `obj` lists its fields, then its methods. It is constructed by
naming its fields, `Point(x: 1, y: 2)`, and an object with exactly one
field also takes it by position: `Meters(3.5)` is
`Meters(value: 3.5)`, as `^x`, `*Cell(0)`, and `*Signal(0)` are
([SYNTAX §11](SYNTAX.md#constructors)). A field may have a default
value, and a constructor may omit that field. Like a parameter default,
it is a literal (a number, a string, `true` / `false`, `none`, or
`.variant`) or a module constant, of this module or an imported one
(`LIMIT`, `lib.LIMIT`, `U8.max`); a field's may also be an empty or
literal constructor: `List()`, `List[T]()`, `String()`, `Cell(0)`, `[n of x]` with
a literal or constant `x`, or `T()` of an object whose every field has a
default (`Bag()`, `lib.Bag()`, `Stack[Int]()`). Each value the
constructor makes gets a fresh default, so no two share a `List`. An object with a `Cell` field lives
only behind a shared handle, so it is made under `*`
([§10](#cell)).

```rig
RETRIES = 3

obj Config
  retries: Int = RETRIES
  name: ?String = "anon"
  tags: List[?String] = List()
  verbose: Bool

obj Stats
  hits: Cell[Int] = Cell(0)

sub main()
  c = Config(verbose: true)
  d = Config(retries: 5, verbose: false)
  !c.tags.push("x")
  s = *Stats()
  !s.hits.set(2)
  print(c.retries, c.name, d.retries, c.tags.len, d.tags.len, s.hits.get())
```

```output
3 anon 5 1 0 2
```

A method whose first parameter is `self` is an instance method;
without one it is an associated function, called through the type
(`Point.origin()`). `Self` names the enclosing type. The receiver says
how the method uses the value, and the call site says the same thing:

| Receiver | Meaning | Call |
|---|---|---|
| `?self` (= `self: ?Self`) | reads the value | `p.m()`, or `?p.m()`: the read view may be left implicit |
| `!self` (= `self: !Self`) | modifies the value | `!p.m()` |
| `<self` (= `self: Self`) | consumes the value | `<p.m()`, or on a temporary; `p.m()` takes a copy of a value that copies |

A write lend and a move are always written ([§7](#lending)), so
calling a `!self` method as `p.m()` is an error, also on a binding that
already holds a write view (a `!T` parameter, `self` in a `!self`
method, a local `w = !p`), which lends it on visibly: `!w.m()`,
`!self.m()`. A held read view is lent on bare.

```rig reject
obj Counter
  n: Int

  sub bump(!self)
    self.n += 1

  sub twice(!self)
    !self.bump()
    self.bump()

sub main()
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
write call whose value is used, whatever its type, is written in the
long form, `(!set).insert(k)`, wherever the value goes (a condition, an
`as` header, an operand, a binding, an argument, a return value, a
function's or a closure's last line, a `match` subject, `??`), so its
`!` never reads as negation: `x = (!v).pop()`, `while (!it).next() as
x`. The short form stays for a call whose value is discarded: a
statement `!set.insert(k)`, alone or under `!`, `?`, or `catch`, and
`_ = !v.pop()`, since `_ =` discards.

```rig
obj Tally
  seen: List[Int]

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

sub main()
  t = Tally(seen: List())
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
obj Queue
  items: List[Int]

  fun is_empty(?self) -> Bool
    self.items.len == 0

sub main()
  q = Queue(items: List())
  if !q.is_empty()
    print("items")
```

```error
`is_empty` does not write its receiver; for negation use `not`
```

```rig reject
obj Stack
  items: List[Int]

  fun top(?self) -> Int?
    self.items.get(0)

sub main()
  s = Stack(items: List())
  print(<s.top() ?? 0)
```

```error
`top` does not consume its receiver; remove the `<`
```

```rig reject
obj Tally
  seen: List[Int]

  fun insert(!self, k: Int) -> Bool
    !self.seen.push(k)
    true

sub main()
  t = Tally(seen: List())
  if !t.insert(1)
    print("added")
```

```error
write `(!t).insert(1)`: a write call whose value is used puts its `!` in parentheses
```

```rig reject
sub main()
  v: List[Int] = List()
  !v.push(1)
  x = !v.pop()
  print(x)
```

```error
write `(!v).pop()`: a write call whose value is used puts its `!` in parentheses
```

```rig
obj Set
  items: List[Int]

  fun insert(!self, k: Int) -> Bool
    for x in ?self.items
      return false if x == k
    !self.items.push(k)
    true

sub main()
  set = Set(items: List())
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
obj Counter
  n: Int

  sub bump(!self)
    self.n += 1

  sub bump_twice(!self)
    !self.bump()
    !self.bump()

sub add_three(c: !Counter)
  !c.bump()
  !c.bump_twice()

sub main()
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
obj Counter
  n: Int

  sub bump(!self)
    self.n += 1

  fun get(?self) -> Int
    self.n

sub twice(f: sub(!Counter), c: !Counter)
  f(!c)
  f(!c)

sub main()
  c = Counter(n: 0)
  twice(Counter.bump, !c)
  get = Counter.get
  print(get(?c))
```

```output
2
```

### Methods outside the body

A method may also be declared outside its type's body, in any file of
the type's module ([§14](#directory-modules)): `fun T.m(...)` or `sub
T.m(...)`, written as it is called. It is the member it names, the same
declaration written as `T`'s last member: `pub` exports it, `Self` is
`T`, and `?self`, `!self`, and `<self` mean what they mean in the body.
A generic type's method names the type's parameters exactly as its
declaration does (`Wrap[T]` for `obj Wrap[T]`, `Ring[T, n]` for `obj
Ring[T, n: Int]`), and any of its own follow its name. A `drop` body
stays in the body, since it decides the type's kind.

```rig
obj Point
  x: Int
  y: Int

obj Wrap[T]
  v: T

fun Point.origin() -> Self
  Point(x: 0, y: 0)

sub Point.shift(!self, dx: Int)
  self.x += dx

fun Wrap[T].map[U](?self, f: fun(T) -> U) -> Wrap[U]
  Wrap(v: f(self.v))

fun double(n: Int) -> Int
  2 * n

sub main()
  p = Point.origin()
  !p.shift(3)
  print(p.x, Wrap(v: 4).map(double).v)
```

```output
3 8
```

A method is declared in the module that declares its type: an `obj`
or `enum` of this module, named as declared, not through an alias, a
built-in type, or another module's type (methods a type gains from
elsewhere are what traits are for, [ROADMAP](docs/ROADMAP.md)).

```rig reject
obj Point
  x: Int

type P = Point

fun P.norm(?self) -> Int
  self.x

fun List.first2(?self) -> Int
  0

sub main()
  print(Point(x: 1).x)
```

```error
`P` is an alias of `Point`; declare the method as `fun Point.norm`
`List` is a built-in type; a method is declared on a type of this module
```

### Enums

An `enum` lists variants, which may carry an explicit integer value or
payload fields, and may have methods ([SYNTAX §8](SYNTAX.md#enums)). A
variant is named `.name` where the enum type is known, or `Type.name`.
A payload variant is constructed with its fields named, like an object,
and a variant with exactly one field also takes it by position:
`.circle(2)` is `.circle(radius: 2)`. A pattern binds the fields in
order (`.circle(r) =>`). Enums have no constructor call (`Shape(...)`
is an error), and compare with `==` ([§5](#operators)). A plain enum's variants may take
explicit values (`ok = 200`): constant integers from 0 to 4294967295,
no two the same, where a variant without one takes the value after the
previous variant's (the first, 0). Payload and generic enums take no
values.

No variant is named `none`, in any enum: `.none` would read as `none`,
the absent value of an optional ([§12](#12-optionals)), and in a `K?`
could be taken for it. `some` is an ordinary name, since an optional
has no `.some`, and so is a name Zig reserves (`.fn`, `.null`).

```rig reject
enum Reply
  yes
  none
```

```error
a variant cannot be named `none`: `none` is the absent value of an optional, and `.none` would read as it; choose another name
```

An integer type's name converts a plain enum value to its value, as it
converts a number ([§2](#numeric-conversions)): `Int(st)`, `U16(d)`.
The conversion is checked: a variant named through its type
(`Status.missing`) must fit the target at compile time, and any other
value that does not fit panics when the program runs. A payload enum
has no integer values, nor does a built-in enum (`Endian`, `Arch`,
whose variants are Zig's), and no enum converts to a float directly.

```rig
enum Status
  ok = 200
  missing = 404

enum Dir
  north
  east

sub main()
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

sub main()
  s: Shape = .dot
  print(Int(s))
```

```error
`Int(x)` takes a plain enum's value; `Shape` has variants with payloads, which have no integer value
```

`<`, `<=`, `>`, and `>=` order two values of one plain enum by those
values: `a < b` is `Int(a) < Int(b)`, so explicit values order the
variants whatever order they are declared in, and without them the
order is the declaration's. A `.variant` on either side takes its type
from the other, as beside `==`. A plain enum meets a generic body's
ordering, so `std.math.max` and `std.sort.sort` take one
([Generic bodies](#generic-bodies)). Two different enums, an enum and a
number, an enum with a payload variant, a built-in enum (`Endian`,
`Arch`), and an error set have no order.

```rig
use std.math

enum Target
  es2015 = 2015
  es5 = 5
  es2020 = 2020

sub main()
  t: Target = .es2015
  print(t >= .es2015, .es2020 < t, Target.es5 < t)
  print(math.max(Target.es2020, Target.es5))
```

```output
true false true
.es2020
```

```rig reject
enum Shape
  dot
  circle(r: Int)

sub main()
  s: Shape = .dot
  print(s < .dot)
```

```error
operator `<` orders a plain enum's values; `Shape` has variants with payloads, which have no integer value
```

```rig reject
enum Color
  red

enum Size
  small

sub main()
  print(Color.red < Size.small)
```

```error
operator `<` operands have different types `Color` and `Size`
```

`Status.from_int(n)` is the other way: the variant of a plain enum
whose value is the integer `n`, of any integer type, or `none` when no
variant has it. `from_int` is built into every plain enum, so an enum
cannot declare a variant or method of that name. `@variants(T)` is every
variant of a plain enum, in declaration order, as a constant `[N]T`; it
can be a module constant, and it asks about a type as `@size(T)` does.
A payload enum has neither, and nor does a built-in enum.

```rig
enum Status
  ok = 200
  missing = 404

all = @variants(Status)

sub main()
  print(Status.from_int(404), Status.from_int(500), Status.from_int(U16(200)))
  for s in all
    print(s, Int(s))
  print(@variants(Status).len)
```

```output
.missing none .ok
.ok 200
.missing 404
2
```

```rig reject
enum Status
  ok = 200

  fun from_int(n: Int) -> Int
    n
```

```error
`from_int` is built into every plain enum
```

```rig reject
enum Shape
  dot
  circle(r: Int)

sub main()
  print(@variants(Shape))
```

```error
`@variants(T)` takes a plain enum; `Shape` has variants with payloads
```

A plain enum's values have names. `e.text` is the name of `e`'s
variant, a `Static` (`dark_red`), and `Color.from_text(word)` is the
variant named `word`, or `none`. `word` is any text a parameter
`?String` takes: a `Static`, a String, or a view or slice of one. The
name must match whole and byte for byte, so a prefix, another case, or
an integer value's digits find nothing. Neither allocates:
`from_text` hashes `word` once and looks it up in a table of the
enum's names, which the compiler builds for each enum the program
calls it on. The built-in enums `Endian` and `Arch` have both too.

`.text` is a member, not a method: `e.text`, not `e.text()`. It is
read as it is, never written or lent: the name belongs to the enum's
type, not to `e`, so `?e.text` is rejected, and `e.text` is passed
where a `?String` is expected. A plain enum cannot declare a variant or method named
`from_text`, nor a method named `text`; a variant named `text` is
`Kind.text`, which clashes with neither. A payload enum has neither:
`from_text` could not build a payload. (A name for a payload variant,
`s.text`, may be added later.)

```rig
enum Color
  red
  dark_red

enum Status
  ok = 200
  missing = 404

fun code(word: ?String) -> Int
  s = Status.from_text(word) ?? return 0
  match s
    .ok => 1
    .missing => 2

sub main()
  c: Color = .dark_red
  print(c.text, Color.red.text.len)
  print(Color.from_text("red"), Color.from_text("Red"), Color.from_text("dark"))
  print(code("missing"), code("404"))
  for v in @variants(Color)
    print(Color.from_text(v.text) == v)
```

```output
dark_red 3
.red none none
2 0
true
true
```

```rig reject
enum Shape
  dot
  circle(r: Int)

enum Color
  red

  fun text(?self) -> Static
    "red"

sub main()
  s: Shape = .dot
  print(s.text, Shape.from_text("dot"))
```

```error
`text` is built into every plain enum: `e.text` is the name of `e`'s variant; give the method another name
`.text` is the name of a plain enum's variant; `Shape` has variants with payloads
`from_text` gives a plain enum's variant by its name; `Shape` has variants with payloads, which a name cannot build
```

### Error sets

`error Name` declares a set of error values, which are used like the
variants of a plain enum ([§13](#13-errors)). Each error belongs to its
set: `A.timeout` and `B.timeout` of two sets, or of two modules, are
different errors. The type `error` holds an error of any set
([Any error](#any-error)). As with a variant, no error is named `none`.

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

`obj Name[T, ...]` declares a generic object and `enum Name[T, ...]`
a generic enum; `error Name[T]` is rejected, and so is an object declared
with `type`, which only names an [alias](#type-aliases). Their
parameters are type parameters and compile-time integers
([§16](#16-compile-time-parameters)): `obj Ring[T, n: Int]`. A value
parameter is named in the type's fields and methods, as an array length
(`items: [n]T`) or as a value in a method's body.
An instance names its compile-time arguments in brackets, in a type
(`Pair[Int, ?String]`, `Ring[Int, LIMIT * 2]`) or in an expression:
`Wrap[Int](value: 3)`, `List[Int]()`, `Option[Int].some(7)`,
`Pair[Int, ?String].make(1, "x")`, `Ring[Int, 4].new(0)`. A value
argument is a compile-time integer, as an array length is, that the
parameter's type holds; the same value names the same type, so
`Ring[Int, 2 + 2]` is `Ring[Int, 4]`. Without them, a constructor takes them
from the expected type when there is one, and otherwise infers them
from the values that fill it: a constructor's fields
(`Pair(first: 1, second: "x")` is a `Pair[Int, ?String]`, and
`Ring(items: [1, 2, 3])` a `Ring[Int, 3]`), a payload
variant's fields (`Option.some(7)`), or an associated function's
arguments (`Pair.make(1, 2)`), as a generic function's call infers its
own ([generic functions](#generic-functions)). A parameter nothing
fills, as in `List()`, needs its type named (`List[Int]()`) or given
where the value goes (`v: List[Int] = List()`). A generic type may hold
`List[T]`, `Cell[T]`, `Signal[T]`, or `[N]T`; their element rules apply
to each instance, and so does the range of an array length a value
parameter gives. Its body follows the rules of
[generic bodies](#generic-bodies).

```rig
obj Pair[T, U]
  first: T
  second: U

  fun make(a: T, b: U) -> Pair[T, U]
    Pair(first: a, second: b)

  fun left(?self) -> T
    self.first

enum Option[T]
  some(value: T)
  nothing

sub main()
  p = Pair(first: 42, second: "answer")
  o: Option[Int] = .some(p.left())
  match o
    .some(v) => print(v, p.second)
    .nothing => print("none")
  q = Option.some(2.5)
  v = List[Int]()
  !v.push(3)
  r = Pair[Int, ?String].make(1, "x")
  n = Option[Int].nothing
  log = *Cell[List[*Pair[Int, ?String]]](value: List())
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

obj Ring[T, n: Int]
  items: [n]T
  head: Int = 0

  sub put(!self, x: T)
    self.items[self.head % n] = x
    self.head += 1

  fun cap(?self) -> Int
    n

sub main()
  r = Ring(items: [3 of 0])
  !r.put(7)
  s: Ring[Int, LIMIT * 2] = Ring[Int, 2 + 2](items: [1, 2, 3, 4])
  print(r.items, r.cap(), s.cap())
```

```output
[7, 0, 0] 3 4
```

```rig reject
obj Flag[on: Bool]
  first: Int

sub main()
  v = List[Int, Int]()
```

```error
a compile-time value parameter of a type is an integer; `on` has the type `Bool`
generic type `List` expects 1 type argument, got 2
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
   `fun map[T, U](xs: []T, f: ?fun(?T) -> U) -> List[U]` is
   `map[?String, Int]`.
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
of `fun zeros[n: Int]() -> [n]Int` is `zeros[3]`. It takes exactly the
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
obj Res
  n: Int

  drop(!self)
    print("drop", self.n)

obj Wrap[T]
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

fun zeros[n: Int]() -> [n]Int
  [n of 0]

fun pick[T](a: T, b: T, first: Bool) -> T
  if first
    return <a
  <b

sub main()
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

fun empty[T]() -> List[T]
  List()

fun id[T](a: T) -> T
  a

fun nothing[T]() -> T?
  none

fun half[T](x: T) -> T
  x / 2

sub main()
  small: U8 = 200
  v: List[Int] = empty()
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

sub main()
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
`T`) is recorded, a viewed operand (`?T`, `!T`) as the `T` it
reaches, and every instance the program makes, spelled or
inferred, directly or through other generic bodies, in any module, is
checked against it. On a `T`, `==` compares whatever `==` compares
outside a generic body, and ordering compares numbers, plain enums, and
`?String` values. A failure is reported at the call or type that makes the instance, with a
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

sub main()
  print(scale(2), scale(2.0))
```

```error
`scale[Float]` cannot use `T = Float`: the generic body gives a `T` the division of whole numbers `3 / 2`, which divides integers, not a `Float`
```

The body is ownership-checked once, for a `T` that may own a resource.
A `T` that owns a resource moves where the body
moves it, and is dropped where the body lets it go. Where the body
copies a `T`, every instance must be plain data; the same holds where it
takes (moves, drops, or returns) an element of a loop that does not
consume its collection (`for x in ?v`), or unwraps a `T` out of a
viewed optional with `as`, since the collection or the owner still
holds the value. A type argument may be a read view, of an owner too
(`same(?v)` is `same[?List[Int]]`): the result holds what `?v` lent, so
`v` stays lent while the result is used. It cannot be a write view,
which is never stored in a value ([Write views](#write-views)), and a
body that stores its `T` in a Cell, a Signal, or an owned closure cannot
be instantiated with a view, since those carry no loan; write `?T`
in the signature to take a view that is only read. In an instance a `T`
may hold a view, so the check of a body against its signature counts a
parameter whose loans reach a value of a type that holds a type
parameter (an element of `xs: []T`, `f(s)` with `f` returning a `T`, a
`T` taken by value, a `match` payload of type `T` that views its
subject) as returned wherever the body returns such a value, or a value
that holds one (`P[T]`), and as stored in what a parameter leads to
wherever the body stores one there: `fun pick[T](f: ?fun(?String) -> T,
a: ?String, b: ?String) -> T from b` cannot return `f(a)`, and `sub
run[T](f: ?*sub(!T, ?String), k: !T, s: ?String)` that calls `f(!k, s)`
says `keeps s`.

```rig
fun same[T](x: T) -> T
  x

sub main()
  v: List[Int] = List()
  !v.push(1)
  b = ^?v
  r = same(?v)
  print(b.len, r.len)
```

```output
1 1
```

The box and the result keep `v` lent for as long as they are used:

```rig reject
fun same[T](x: T) -> T
  x

sub main()
  v: List[Int] = List()
  b = ^?v
  r = same(?v)
  !v.push(1)
  print(b.len, r.len)
```

```error
cannot lend `v` to write while a read loan is live
```

A declaration that makes a shared or weak
handle of a parameter (`*T`, `~T`) cannot be instantiated with a
function type, since `*fun(Int) -> Int` is an owned closure, not a
handle of a function: an owned closure is held as a `T`, with
`T = *fun(Int) -> Int`.

```rig
obj Track
  title: ?String

  drop(!self)
    print("free", self.title)

obj Shelf[T]
  items: List[T]

  sub add(!self, x: T)
    !self.items.push(<x)

  fun take(!self) -> T?
    (!self.items).pop()

fun pick[T](a: T, b: T, first: Bool) -> T
  if first
    return <a
  <b

sub main()
  t = pick(Track(title: "a"), Track(title: "b"), false)
  print("picked", t.title)
  s = Shelf[*Track](items: List())
  !s.add(*Track(title: "intro"))
  !s.add(*Track(title: "outro"))
  if (!s).take() as last
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
obj Point
  x: Int

fun max[T](a: T, b: T) -> T
  a if a > b else b

fun larger[T](a: ?T, b: !T) -> Bool
  a > b

sub main()
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
obj Res
  n: Int

  drop(!self)
    print("drop", self.n)

obj Pair[A, B]
  first: A
  second: B

fun twice[T](x: T) -> Pair[T, T]
  Pair(first: x, second: x)

sub main()
  p = twice(Res(n: 1))
  print(p.first.n)
```

```error
`twice[Res]` cannot use `T = Res`: the generic body copies a `T`, which would duplicate the resource `Res` owns
`T` copied here; move it with `<` instead
```

### Type aliases

`type Name = T` gives a type a second name. An alias is transparent: it
is the same type as `T`. An alias names its type in every role, in this module or, when `pub`,
in another (`lib.Alias`). An alias of an object or enum (this module's
or an imported one) constructs values, calls associated functions, and
names variants; one of a generic instance (`Wrap[Int]`, `List[Int]`,
`Cell[Int]`) constructs it as naming the instance does; one of a number
type converts to it (`Byte(x)`) and names its limits (`Byte.max`).
An alias is not a value, and an alias of any other type (`?String`,
`Int?`) has no constructor.

```rig
obj Point
  x: Int
  y: Int

  fun origin() -> Point
    Point(x: 0, y: 0)

enum Color
  red
  green

type P = Point
type C = Color
type Byte = U8

fun next(b: Byte) -> Int
  Int(b) + 1

sub main()
  p = P(x: 3, y: 4)
  o = P.origin()
  c = C.green
  n = 300
  print(p.x + o.x, c == .green, Byte(n - 100), Byte.max, next(7))
```

```output
3 true 200 255 8
```

The type an alias names nests at most 200 deep, counting each type it
is built from (`List[A]`, `A?`, `[2]A`, `fun(A) -> Int`): aliases, each
naming the next inside another type, would otherwise nest one in another
without end. An alias that names a deeper type is rejected.

### Tests

`test "name"` (or `test 'name'`) declares a block that is checked like
a function body that may fail: `f()!` in a test fails the test with
that error. `rig test X` runs the tests of `X` itself and no others, as
Go's `go test pkg` does: the test blocks of the file `X`, or, when `X` is a
directory module, those of its files and its `*_test.rig` files
([§14](#directory-modules)). The test blocks of the modules `X` imports,
the standard library's included, are checked and not run. It prints
`ok    test "name"` for each test that finishes, or
`FAIL  test "name": ...` with the reason, and then `N passed, M failed`.
`rig run` ignores test blocks. `rig check --tests X` checks what
`rig test X` builds, without building or running it.

```rig
fun area(w: Int, h: Int) -> Int
  w * h

test "area"
  print(area(2, 3))
```

### Constants

A binding at module level is a constant, `name = value` or
`name: T = value`, and `pub` exports it. Its value must be known at
compile time: a literal, `.variant`, a constant, or operators,
ternaries (`a if c else b`), and array literals over them. Every function, type, and constant in the module
reads it, wherever it is declared; nothing can reassign or move it,
and a local or parameter may not reuse its name (`new` shadows it on
purpose).
Arithmetic on constants alone is checked at compile time; with a value
known only when the program runs, it is checked then, like any other.
Only a constant scalar is folded: an element of a constant array
(`table[0]`), a field of a constructed value, and a payload are read
when the program runs, so `table[0] + 1` with `Int.max` in `table[0]`
is a panic there, in every build mode, not a compile error.
A module constant's integer arithmetic is computed when Rig checks the
program, so each of its operands must be a value Rig computes. A
constant that branches on something other than integers (an enum
constant, or `target.arch`, [The target](#the-target)) has none, and
arithmetic on it in another constant is rejected; in a function it is
checked when it runs.

```rig
limit = 10
half = limit / 2
names = ["low", "high"]

fun over(n: Int) -> Bool
  n > limit

sub main()
  print(limit, half, names[1], over(12))
```

```output
10 5 high true
```

Constants are folded in the order they name each other, not the order
they are written, so a constant that depends on itself is rejected:

```rig reject
A = B + 1
B = A * 2

sub main()
  print(A)
```

```error
constant `A` depends on itself (`A` → `B` → `A`)
```

There are no mutable module-level variables, so a module-level binding
needs no `=!`, and one written with it is rejected:

```rig reject
LIMIT =! 4

sub main()
  print(LIMIT)
```

```error
a module-level binding is already a constant; write `LIMIT = 4`
```

### The target

`use std.target` names facts about the target, the machine the program
is compiled for ([STD.md](docs/STD.md#stdtarget)). `target.arch` is its
processor architecture, a value of the built-in enum `Arch`, whose
variants are Zig's names for every architecture Zig compiles for
(`std.Target.Cpu.Arch`): `.x86_64`, `.aarch64`, `.wasm32`, `.wasm64`,
`.riscv64`, and the rest. `Arch` lowers to that Zig enum, all of it, so
every target has a name and each name means what it means to Zig.
`Arch` is a built-in name, like `Endian`, and is reserved.

`target.arch` is known at compile time and stands wherever a constant
can: in a module constant's initializer, as a compile-time argument of
type `Arch`, and in ordinary code, where `==` and `!=` compare it with
a variant. Rig never knows its value: Zig sets it when it compiles the
program for a target, so `rig check` gives a program the same verdict
on every machine. Rig checks both branches of `a if target.arch ==
.x86_64 else b`, and Zig keeps the one the target picks, when it
compiles. A constant whose value names `target.arch` is set by the
target too.

```rig
use std.target

TIER = 0 if target.arch == .x86_64 else 16

fun lanes(a: Arch) -> Int
  match a
    .x86_64 => 32
    _ => 16

sub main()
  print(TIER == 0 or TIER == 16, lanes(target.arch) >= 16)
```

```output
true true
```

Where Rig needs a value when it checks the program, a value the target
sets is rejected: an array length, a vector's lane count, a compile-time
integer argument, the lanes `lag` takes, a range pattern's bounds, an
enum's value, and the operands of a module constant's arithmetic, which
Rig computes when it checks the program and Zig computes again when it
compiles (`100 / TIER` divides by zero on x86_64 alone). Write each
branch's value instead: `DOUBLE = 0 if target.arch == .x86_64 else 32`.
In a function, arithmetic on such a constant is checked when it runs,
as on any value Rig does not know.

```rig reject
use std.target

TIER = 0 if target.arch == .x86_64 else 16
RATIO = 100 / TIER

sub main()
  a: [TIER]U8 = [4 of 0]
  print(RATIO, a)
```

```error
the operands of a module constant's arithmetic must be known when Rig checks the program; the value of `TIER` is chosen for each target when Zig compiles the program, so Rig does not know it
an array length must be known when Rig checks the program; the value of `TIER`
```

`std.target` has only `arch`: the operating system and the CPU's
features are not built.

### Other declarations

`use` imports a module ([§14](#14-modules)), `pub` exports a
declaration ([§14](#14-modules)), and `extern` declares a C symbol
([§15](#15-raw-code-and-ffi)).

---

## 4. Bindings and assignment

The forms are in [SYNTAX §9](SYNTAX.md#9-bindings-and-assignment). `x =
e` binds a new local `x` when no `x` is visible, and otherwise assigns
the visible one: through it, when `x` holds a write view
([View places](#view-places)). `x =! e` binds a fixed local, which
cannot be reassigned. `_ = e` evaluates `e` and discards it, and an
owning value discarded so is dropped at once. A binding's type comes
from its annotation or its value.

A compound assignment `x op= e` stores `x op e` in `x`, finding the
place `x` once, and keeps its target's type: an arithmetic operator
needs a number, a bitwise operator or shift an integer, and a shift
amount may be any integer. Each behaves like its operator
([§5](#operators)): `/=` truncates, `%=` takes the dividend's sign, and
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

An assignment evaluates its value first, then its target from left to
right: the value its path starts from (a call, `pick(!t, !i)[0] = s[i]`,
runs after `s[i]` is read), then its indexes (the outermost index
first), and only then finds the place and stores into it; a compound assignment reads the place there, combines, and
writes it back. A call on the right that grows the List an element is
in, or replaces the value a field is in, is safe: the store lands in
the value as the call left it, and panics if the element is gone.
So `place op= value` is `{ __v = value; place op= __v }`: the value
runs to its end, every block, arm, and handler in it and the drops
that end them included, before the target is evaluated, so a store
through a view goes where the value left the view, and the view may
not point at anything the value's own scopes dropped. A temporary the
value makes outside those scopes lives until after the store, as every
statement's temporaries do.

```rig
fun grow(v: !List[Int]) -> Int
  !v.push(v.len)
  v.len

fun at(i: Int, what: ?String) -> Int
  print(what)
  i

sub main()
  v: List[Int] = List()
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
visible local, parameter, or module-level declaration, and `x =! e`
always declares. To reuse a name on purpose, write `new`:

```rig
sub main()
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

`new` takes the other binding forms too: `new x: T = e`, and `new x =!
e`, which shadows with a fixed local.

```rig
sub main()
  limit =! 3
  new limit =! limit * 2
  n = 7
  new n: U8 = U8(n)
  print(limit, n)
```

```output
6 7
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
loop bindings, and names bound by patterns and `as` are immutable,
though one that holds a write view writes through it
([View places](#view-places)).

Every local must be read. Any use counts: an argument, an operand, a
view `?x` or `!x`, a move `<x`, a clone, a field access, a closure
capture, a drop `<x`. Assigning does not: a local that is only ever
assigned, like a misspelled `totl = 5`, is rejected. A name bound by
`for`, a match pattern, `as`, or `catch |e|` must be read too, or be
`_`. Discard a value on purpose with `_ = e`. A value with drop glue
([§8](#8-drop-and-drop-glue)) is read by its own release, so a local
held only for its `drop` at the end of the scope is fine. Parameters
are exempt.

```rig reject
sub main()
  total = 0
  totl = 5
  print(total)
```

```error
`totl` is assigned but never read
```

### View places

> **Core §6:** Assigning a view to a place that holds one re-points it, and assigning a value writes through.

A write view is assignable, whether a `!T` parameter or a local
holding one: `p.f = v`, `p = v`, and `p += 1` write through to the
viewed value (the old value is dropped first). Assigning a view
points the place at another place instead: `w = !m`, `w = <w2`, or a
call returning a `!T` re-points a local `w`, which then lends `m`
alone (a `![]T` local alike), and a bare `w = w2` reads the value `w2`
reaches and writes it through `w`. A new local holds a write view the
same way, with or without a type: `w = slot(!n)`, a call returning a
`!Int`, holds the view, as `w: !Int = slot(!n)` does, so `w = 5`
writes `n`, and so does a branching value or a loop used as a value
each of whose values hands one over (`l = while true` with `break
slot(!n)`); a bare name, or a value that branches among them, binds
the value it reaches. A parameter is never re-pointed:
`w = !m` of a `!T` parameter is rejected, and `new w = !m` binds a new
name instead. A bare name only reads (Core sentence 1): a bare `w` of
type `!Int` where a value is taken copies the value it reaches (`x = w`,
an argument, an operand, a branching value of them); `x = <w` moves the
view instead, and `x = !w` lends it on. A write view of a value that
does not copy (an owner or a unique value) is never read out this way,
and one bound with a `!T` type (`x: !Int = w`) would copy the view, so
both are rejected. A write view of a plain object, array, or optional
reads it as one of a number does (`q = p` with `p: !Point`).

A write view a call returns is assigned through, with no binding to
hold it: `slot(!v, 0) = 5`, `slot(!v, 0) += 1`, and `(!b).first() *=
2` write the value the view reaches, the old value dropped first. So is
the write view a call's `!` or `?` gives (`get(!v)! += 1` for a
`(!Int)!`, `(!m).edit(k)? += 1` for a `(!Int)?`). `f(x) op= e` is
`__v = e`, then `w = f(x)`, then `w op= __v`: the value runs first,
then the call, as a field's or element's base does, so
`slot(!v, 0) += v.len` reads `v.len` before `slot` runs. Nothing else
is assigned through: not a call that returns a value, a read view, or
a `![]T` (a `![]T`'s elements are: `all(!v)[0] = 5`), and not `?` or
`!` around anything but a call.

```rig
obj Bag
  items: List[Int]

  fun first(!self) -> !Int
    !self.items[0]

fun slot(v: !List[String], i: Int) -> !String from v
  !v[i]

sub main()
  b = Bag(items: List())
  !b.items.push(5)
  (!b).first() += 1
  (!b).first() *= 2
  names: List[String] = List()
  !names.push(String("ada"))
  slot(!names, 0) = String("bob")
  print(b.items, names)
```

```output
[12] ["bob"]
```

```rig reject
fun count(v: ?List[Int]) -> Int
  v.len

sub main()
  v: List[Int] = List()
  count(?v) += 1
```

```error
cannot assign to a call's result, an `Int`; only a write view (`!T`) a call returns is assigned through
```

```rig reject
fun bump(w: (!Int)?) -> Int?
  w? += 1
  0

sub main()
  n = 1
  print(bump(!n))
```

```error
cannot assign to `w?`: only a call that returns a write view (`!T`), or that call's `!` or `?`, is assigned through
```

A write view is never stored inside a value (Core §5): `!T`,
also as `(!T)?` and `(!T)!`, is only a parameter's, a receiver's, a
result's, or a local or header binding's type, never a field's, an
element's, or a type argument. To change a value from another one,
pass `!x` to each call that changes it, or hold the value itself.

```rig
obj Counter
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

```rig
sub main()
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
fun slot(a: !Int) -> !Int
  a

sub main()
  n = 1
  w = slot(!n)
  w = 5
  print(n)
```

```output
5
```

```rig reject
obj Tally
  count: !Int

sub main()
  n = 0
  m = 100
  xs = [!n, !m]
  print(n, m)
```

```error
a write view is never stored inside a value, and `!Int` cannot stand here
```

---

## 5. Expressions

### Operators

The operators and their precedence are in
[SYNTAX §6](SYNTAX.md#6-operators-and-precedence), and how they are
spaced in [SYNTAX §5](SYNTAX.md#5-prefixes-infixes-and-suffixes): an
infix operator has the same spacing on both sides, and a sigil touches
what it marks. A receiver sigil
applies to a method's receiver ([§3](#objects)); a call of a field
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
sub main()
  x = 7 / 2
  h: Float = 7.0 / 2
  k: Float = 2 * 3
  print(x, h, k, -7 % 3)
```

```output
3 3.5 6.0 -1
```

```rig reject
sub main()
  h: Float = 7 / 2
  print(h)
```

```error
`7 / 2` divides whole numbers (3); for 3.5 write `7.0 / 2`
```

Bitwise operators need integers; a shift amount may be any
integer, from 0 up to the bit count of the shifted type. A left shift that
loses bits (or the sign) overflows: a constant one is rejected, and one
computed when the program runs panics, like `+` and `*`.

`+%`, `-%`, and `*%` are wrapping arithmetic, as in Zig: on overflow
the result wraps around in two's complement, keeping the low bits in
the operands' integer type, and never panics. They take integers of
any type; a `Float` is rejected, as is a literal operand that would
take a float type or a type parameter a float fills. The same holds
for the integer operators `&`, `|`, `^`, `<<`, `<<%`, and `>>`. `+%=`, `-%=`, and `*%=` assign the
wrapped result. Constant wrapping arithmetic is computed in its type,
as the program computes it.

On a vector, an operator works lane by lane, and a scalar of its lane
type stands for every lane ([Vectors](#vectors)).

`+|` and `-|` are saturating arithmetic, as in Zig: a result past the
limits of the operands' integer type stops at the limit it passes, so
`U8(250) +| 10` is 255 and `I8(-100) -| 100` is -128, and never panics
or wraps. They bind as `+` and `-` do, take integers as the wrapping
forms do, and `+|=` and `-|=` assign the result. Constant saturating
arithmetic is computed in its type.

```rig
sub main()
  a: U8 = 250
  i: I8 = -100
  n: U8 = 3
  n -|= 5
  print(a +| 10, a -| 251, i -| 100, i +| 100 -| 100, n)
```

```output
255 0 -128 -100 0
```

`<<%` is the wrapping left shift: the high bits it shifts out are
dropped, where `<<` panics. It binds as `<<` does, and its amount is
checked as `<<`'s is: it must be below the bit count of the shifted type,
and one at or over it is rejected if constant and panics when the
program runs, never masked. `<<%=` assigns the shifted result.

```rig
sub main()
  a: U8 = 0b1100_0001
  n = 4
  a <<%= 1
  print(a, a <<% n, 255 <<% 60)
```

```output
130 32 -1152921504606846976
```

```rig reject
sub main()
  a: U8 = 1
  print(a <<% 8)
```

```error
shift amount `8` is out of range for `U8` (0..7)
```

```rig
fun fnv1a(s: ?String) -> U64
  h: U64 = 14695981039346656037
  for b in s
    h ^= U64(b)
    h *%= 1099511628211
  h

sub main()
  a: U8 = 250
  i: I8 = 127
  print(a +% 10, a -% 255, i +% 1, fnv1a("rig"))
```

```output
4 251 -128 9948945366585317705
```

```rig reject
sub main()
  x = 1.5
  print(x +% 1.0)
```

```error
operator `+%` requires integer operands; got `Float`
```

`x.not()` is the bitwise complement of an integer of any type: it
flips every bit, so `0.not() == -1` and, for a `U8`, `5.not() == 250`. On
a `Bool` it equals `not b`. `not x` on an integer is rejected, since
`not` takes a `Bool`.

```rig
sub main()
  a: U8 = 5
  s: I32 = 0
  b: U128 = 0
  print(a.not(), s.not(), b.not(), true.not())
```

```output
250 -1 340282366920938463463374607431768211455 false
```

```rig reject
sub main()
  x = 5
  print(not x)
```

```error
`not` takes a Bool; for the bitwise complement write `x.not()`
```

The other methods of an integer's bits take no arguments and work on
its bit pattern, so a negative value counts as its two's complement.
`x.leading_zeros()`, `x.trailing_zeros()`, and `x.count_ones()` give
an `Int`: the zero bits above the highest set bit, the zero bits below
the lowest, and the set bits. For `0` both zero counts are the bit count of
its type, and `(-1).count_ones()` is 64. `x.swap_bytes()` reverses the
bytes, in the integer's own type. A receiver that is not an integer is
rejected.

```rig
sub main()
  m: U64 = 0x0000_0080_0000_8000
  b: I8 = -128
  z: U16 = 0
  print(m.trailing_zeros() / 8, m.leading_zeros(), m.count_ones())
  print(b.leading_zeros(), b.trailing_zeros(), b.count_ones())
  print(z.leading_zeros(), z.count_ones())
  w: U32 = 0x1234_5678
  print(w.swap_bytes() == 0x7856_3412)
```

```output
1 24 2
0 7 1
16 0
true
```

```rig reject
sub main()
  x = 1.5
  print(x.count_ones())
```

```error
type `Float` has no method `count_ones`
```

`==` and `!=` compare two values of the same type, by content. The
equatable types are numbers, `Bool`, `?String`, errors, and plain enums,
and, when everything they hold is equatable: optionals, where `none`
equals only `none` and a value compares with an optional as its value;
arrays and `[]T` slices, element by element; objects, field by field;
and payload enums, by variant and then payload. A variant literal,
`.red` or `.dot(at: p)`, takes its enum type from the other operand, on
either side. A bare `.variant` tests only which variant a value holds,
so it compares with any enum, or optional of one, whatever its payloads
hold; a payload literal compares the payload too, so the enum must have
`==`. Floats compare as IEEE numbers wherever they are, so a
object holding a NaN is not equal to itself. A viewed operand (`?P`,
`!P`) compares as the value it reaches. A method named `eq` is never
called by `==`.

A handle `*T` or `~T` has no `==`, since it could compare identity or
content; nor does a function or closure, a List, Cell, or Signal, a
object that declares `drop`, or an object or payload that holds a `?T`,
`!T`, or slice. Neither does a type that holds one of these, and the
diagnostic names the field that does. Two handles' contents compare
through views: `?a == ?b`.

Ordering comparisons (`<`, `<=`, `>`, `>=`) take two numbers, two
values of one plain enum, ordered by their variants' values
([Enums](#enums)), or two `?String` values or two `[]U8` slices,
ordered by their bytes: the first byte that differs decides, and a
prefix sorts before the longer string. Objects, enums with payload
variants, and other slices have no ordering.

```rig
obj Point
  x: Int
  y: Int

enum Shape
  dot(at: Point)
  empty

sub main()
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
obj Node
  n: Int

obj Link
  id: Int
  to: *Node

sub main()
  a = Link(id: 1, to: *Node(n: 1))
  print(a == a, a < a)
```

```error
`==` is not defined for `Link`: field `to` is a handle `*Node`, which could compare by identity or by content
operator `<` orders numbers, plain enums, Strings, and `[]U8` slices; got `Link`
```

```rig
obj Node
  n: Int

enum Slot
  held(to: *Node)
  empty

sub main()
  s: Slot = .held(to: *Node(n: 1))
  print(s == .empty, s != .empty)
```

```output
false true
```

```rig reject
obj Node
  n: Int

enum Slot
  held(to: *Node)
  empty

sub main()
  s: Slot = .empty
  print(s == .held(to: *Node(n: 1)))
```

```error
`==` is not defined for `Slot`: field `held.to` is a handle `*Node`
```

`x.hash()` is a `U64` computed from a value's content, on exactly the
types `==` compares less a `Float` and what holds one, since `==` calls
`0.0` and `-0.0` equal and a NaN equal to nothing (hash a float's bits,
`x.to_bits().hash()`). Values `==` calls equal hash equal: text hashes
its bytes whatever its type (`String`, `?String`, `Static`, or a boxed
String), an optional holding a value hashes as that value, an integer
as its value, and the rest by their parts, as `==` compares them. The
seed is fixed, so a value hashes the same in every run. `x.hash()` reads
`x` where it is, as `==` does. A type that declares a method `hash`
gets its own; in a generic body, `k.hash()` on a type parameter's value
is checked at each instance, as `==` is, and an instance whose type
declares its own `hash` is rejected, since the body calls the built-in
one. `std.hash`'s Map and Set ([docs/STD.md](docs/STD.md#stdhash)) key
on it.

```rig
obj P
  x: Int
  name: String

sub main()
  a = P(x: 1, name: String("q"))
  b = P(x: 1, name: String("q"))
  t = String("q")
  print(a == b, a.hash() == b.hash(), t.hash() == "q".hash())
```

```output
true true true
```

```rig reject
obj Reading
  at: Int
  value: Float

sub main()
  r = Reading(at: 1, value: 2.5)
  print(r.hash())
```

```error
`.hash()` does not take a `Reading`: field `value` is a `Float`
```

`and`, `or`, and `not` take `Bool`s, and `and` and `or` short-circuit:
the right side runs only when the left does not decide. The spellings
`&&` and `||` are rejected with a hint. Prefix `!` always lends to write, never
negation: a `!x` whose `Bool` value would be read (a condition, an
operand, a binding, an argument) is rejected. It is valid only where a
`!Bool` is expected, as for an argument to a `flag: !Bool` parameter.

`not` binds looser than a comparison and tighter than `and` and `or`:
`not a and b` is `(not a) and b`. Since `not a > b` could be read as
`(not a) > b`, a comparison directly under `not` is written in
parentheses, `not (a > b)`, or flipped: the diagnostic offers `a <= b`
where that means the same, for integers, plain enums, text, and any
`==` or `!=`, though not for a `Float`, which may be NaN.

```rig reject
sub main()
  done = false
  if !done
    print("working")
```

```error
`!` lends to write; use `not` for negation
```

```rig
sub main()
  a = 7
  print(-7 / 2, -7 % 2, a & 3, a << 2, a ^ 1)
  print(not (a == 3), a > 3 and a < 10, false or true)
  print(1 if a > 5 else 2)
```

```output
-3 -1 3 28 6
true true true
1
```

```rig reject
obj Item
  qty: Int

sub main()
  it = Item(qty: 4)
  if not it.qty > 3
    print("few")
```

```error
write `it.qty <= 3`, or `not (it.qty > 3)`: `not` applies to the whole comparison
```

```rig reject
sub main()
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
fun classify(x: Int) -> ?String
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

A statement `<e` moves `e` nowhere, so what it takes is dropped now
([Drop](#drop)): `<x` drops the binding `x`, `<s.f` and `<v[i]` take an
optional field or element and drop it, leaving `none`, and `<mk()`
drops the value `mk()` makes. Where a value is expected, `<e` moves it
there: in an operand, an argument, a binding's value, a `return` or
`break` value, and on the last line of a `fun` or a closure (its value)
or of a branch, arm, or loop `else` block whose value is used. A
closure whose type returns nothing (from the parameter it is passed to,
or a typed binding) treats its last line as a statement, as a `sub`
does, so `<x` drops there and a value on it does nothing, which is
rejected. An untyped closure (`f = || ...`) takes its last line as its
value, and so does the last line of a branch that ends it, so it drops
there with `_ = <x`. A statement `<?x` or `<!x` moves a view nowhere, and a view
owns nothing to drop, so it does nothing, and is rejected. `-x` always
negates: a statement `-e` does nothing, and is rejected, with the drop
to write where `e` holds something `<e` drops: not a view parameter,
a closure's capture, or a `for` element that views a slot of the List it
walks, which `<` rejects.

```rig
obj F
  n: Int

  drop(!self)
    print("drop", self.n)

obj S
  f: F?

sub main()
  s = S(f: F(n: 1))
  <s.f
  print(s.f == none)
```

```output
drop 1
true
```

```rig reject
sub main()
  v: List[Int] = List()
  -v
```

```error
to drop `v` now, write `<v`
```

A statement must have some use. An expression whose value is used (the
last line of a `fun`, a binding, an argument) may be anything, but one
whose value would be thrown away must do something: call, propagate
(`e!`, `e?`), or `catch`. A name, literal, field read, or lend alone on
a line has no use and is rejected, and a function name alone is taken
for a forgotten call.

```rig
sub greet()
  print("hi")

fun pick() -> sub()
  greet

sub main()
  greet()
  say = pick()
  say()
```

```output
hi
hi
```

```rig reject
sub greet()
  print("hi")

sub main()
  greet
```

```error
`greet` is a function; call it with `greet()`
```

### Builtins

`@builtin(args)` calls a compiler builtin. Rig's own work anywhere:
`@size(T)` and `@align(T)` are a type's size and alignment in bytes,
`@name(T)` is its name, and `@type(x)`, only as the argument of one of
these three, is the type of `x`. `@variants(T)` is the variants of a
plain enum ([§3](#enums)). A type argument is written as one is
in an expression (`List[Int]`, `?P`, `Int?`; a slice, array, or function
type through a `type` alias).

```rig
obj P
  a: I32
  b: I64

sub main()
  x: I16 = 5
  print(@size(I64), @align(P), @size(@type(x)), @name(Int))
```

```output
8 8 2 Int
```

`@name(T)` is the type as Rig writes it, the spelling the diagnostics
print: `Int` (also for `I64`, the same type), `List[Int]`, `Int?`,
`?P`, `*P`, `fun(Int) -> Int!`. An alias is the type it names (`type
Byte = U8` gives `U8`), and another module's type is qualified the way
this module names that module (`geo.Point`, or `g.Point` after `use
geo as g`). In a generic body, a type parameter is named for each
instance, as the generic's module writes it:

```rig
obj Pair[A, B]
  a: A
  b: B

fun name[T]() -> ?String
  @name(T)

type Byte = U8

sub main()
  print(@name(List[Int]), @name(Byte), name[Pair[Int, String]](), name[*Pair[U8, Bool]?]())
```

```output
List[Int] U8 Pair[Int, String] *Pair[U8, Bool]?
```

An instance is spelled as the printer spells that type, parentheses
included: `T?` with `T = Int?` is `(Int?)?`, and `*T` is `*(Int?)`. A
type parameter is named from the program's own type for it, where a
read view of a number is the number and a `[]U8` is the bytes a
`?String` is, so an instance that holds a view or a slice, but a
`?String`, cannot be named, and is rejected where it is made:

```rig reject
fun name[T](x: T) -> ?String
  @name(T)

sub main()
  n = 5
  v: (?Int)? = ?n
  print(name(v))
```

```error
`name[(?Int)?]` cannot use `T = (?Int)?`
```

Every other builtin is Zig's, keeps its Zig name, and works only
inside a `raw` block ([§15](#15-raw-code-and-ffi)): the casts
`@bitCast`, `@intCast`, `@floatCast`, `@truncate`, `@trunc`,
`@floatFromInt`, and `@fromBackingInt`, and Zig's names for Rig's
four, `@sizeOf`, `@alignOf`, `@typeName`, and `@TypeOf`, which mean
what Rig's do, except that `@typeName(T)` is the name the emitted Zig
gives the type (`i64` for `Int`). Rig's names work inside `raw` too.
Outside it, Zig's name for one of Rig's is rejected, with the call to
write:

```rig reject
sub main()
  print(@sizeOf(I64))
```

```error
write `@size(I64)`: Rig's builtin is `@size`; Zig's `@sizeOf` works only inside `raw`
```

---

## 6. Control flow

The forms of each statement are in
[SYNTAX §10](SYNTAX.md#10-statements-and-control-flow); this section
says what they do.

**Headers.** An `if` or `while` condition, a `match` guard, and the
subject of a `match` or `for` are each a statement of their own
([§7](#temporaries)). A bare place there is read where it is, `?` and
`!` lend it, and `<`, or a value made there, is taken
([§7](#reading)).

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
tests again (so a step that reads a binding of the condition cannot be
paired with one, which would leave the binding unbound), and `continue`
in the step ends the step. An `else` block runs when the loop
ends without `break`, after the loop: a `break` or `continue` in it
leaves the loop around this one. A loop can also yield a value
([Loops as values](#loops-as-values)).

The step runs after the body, so a view it reads, whether the
condition binds it or a name declared before the loop holds it, is in
use through the body, and its loan lasts until the step
([How long a loan lasts](#how-long-a-loan-lasts)):

```rig reject
fun all(v: ?List[Int]) -> ([]Int)?
  if v.len < 40
    return ?v[..]
  none

sub main()
  v: List[Int] = List()
  !v.push(1)
  k = 0
  while all(?v) as s: k += s[0]
    !v.push(2)
  print(k, v.len)
```

```error
cannot lend `v` to write while a read loan is live
```

### for

`for x in source` walks an array, a slice, a `?String` (bytes), a
`List`, an iterator (below), or a range `a..b` (from `a` up to, not
including, `b`; the bounds are evaluated once). `for x, i in xs` also binds the index (not for
ranges); the element comes first, the reverse of Python's
`enumerate`, and where a loop written index first gives a binding the
other's type, the error says so. An `else` block runs when the loop ends without `break`. A
source that is a place is walked where it stands: `for x in v` is
`for x in ?v`, which lends `v` to read for the whole loop ([§10](#list)),
so an element of plain data is a copy and any other element a view of
its slot (`?E`). A value the source makes is taken: a List a call
returns is consumed, and an array made there whose elements move is
held for the loop, which owns its elements. A part of a value made
there (`mk().arr`) is walked in that value, which the loop holds until
it ends.

`for source`, with no variable, is `for _ in source` and nothing else:
the same sources, sigils, checks and lowering, with no binding. The
parser takes `for NAME in` and `for NAME, NAME in` as the binding form
and anything else as the bare one. `it` is not special.

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

- `for x in !xs` views each element of a `List` or array for writing:
  assigning `x` (or a field of it) writes the element in place, and a
  resource element that is replaced is dropped. `xs` must be a binding
  or a field of one.
- `for x in <v` consumes the List: each element is handed to `x`, which
  owns it for one iteration and may move it on. Elements a `break` or
  `return` leaves behind are dropped with the buffer, and `v` is moved.
  `v` must own the List: through a view, loop over `?v` or `!v`.

```rig
obj B
  n: Int

  drop(!self)
    print("drop", self.n)

sub keep(b: *B)
  print("kept", b.n)

sub main()
  xs = [1, 2, 3]
  for x in !xs
    x *= 10
  print(xs)
  v: List[*B] = List()
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

A List source is a place, which the loop walks in place. A List of plain
data may also be a value made there (a call, or a branching value whose
every branch is made there), whose new List the loop consumes as `<v`
does. A branching value that may be a name's (`a if c else b`) is a
value, never a place, so walking it in place would lend it, which is
rejected ([§7](#lending)): lend each branch, `for e in ?a if c else ?b`.
A List whose elements move (a `List[String]`, a List of
owners) is walked only where a name holds it, or a field or element of
one, so a call's result, or a part of a value made there (`mk().items`),
is bound to a name first:

```rig reject
obj H
  items: List[String]

fun mk() -> H
  H(items: List())

sub main()
  a: List[Int] = List()
  b: List[Int] = List()
  for e in ?(a if a.len > 0 else b)
    print(e)
  for t in mk().items
    print(t)
```

```error
cannot lend `a if a.len > 0 else b`: it may be `a`, a value a name holds, which lending the branching value would copy; lend each branch: `?a if a.len > 0 else ?b`
a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `mk()` to a name first
```

An iterator is a value whose type declares `next(!self) -> T?`. A
`for` over one is the loop `while (!it).next() as x`, so each `x` is
what `as` binds over the `T?` the call gives, the loop ends when `next`
gives `none`, and `else`, `break` values, labels, and loop values
([Loops as values](#loops-as-values)) work as they do for a `while`.
The loop advances the iterator where it stands, so the iterator must be
writable, and one a `break` leaves is there to resume. How the source is
written decides what the loop does with it:

| Source | The loop is |
|---|---|
| `!it`: a name, or a field path from one (`a.b`); a bare `it` is rejected | `while (!it).next() as x` |
| `mk()`: a value made there | `h = mk()` held for the loop, then `while (!h).next() as x`; `h` ends with the loop |
| `<it`: a name or field path the loop takes | `h = <it` held for the loop, then `while (!h).next() as x`; `it` is moved |
| `?b.each()`: a method call whose `?` reaches its receiver, as before any call | `h = (?b).each()` held for the loop, then `while (!h).next() as x`; `b` stays lent to read while the loop holds `h` |
| `?it` | rejected: reading an iterator cannot advance it |

A type with a `next` of another shape (`next(?self)`, one that takes
more than `self`, or one that gives no optional) is not an iterator, and
a `for` over it is rejected with the shape to write. An element
(`xs[i]`), whose index the body could change, is bound to a name first.
An iterator has no index binding. The `List`, array, slice, `?String`, and range sources
keep the meanings above.

```rig
use std.text

obj Count
  lo: Int
  hi: Int

  fun next(!self) -> Int?
    return none if self.lo >= self.hi
    self.lo += 1
    self.lo - 1

fun upto(n: Int) -> Count
  Count(lo: 0, hi: n)

sub main()
  c = upto(5)
  for n in !c
    break if n == 1
  for n in !c
    print("then", n)
  first = for w in text.words("a bb ccc")
    break w if w.len > 1
  else
    "none"
  print(first)
  for n in upto(2)
    print("made", n)
  for n in <c
    print("rest", n)
```

```output
then 2
then 3
then 4
bb
made 0
made 1
```

An iterator a method returns may view the value the method was called
on. `?b.each()` lends `b` to read for the call, as before any call, so
the loop holds the iterator and keeps `b` lent while it walks it:

```rig
obj Cur
  xs: ?List[Int]
  i: Int

  fun next(!self) -> Int?
    return none if self.i >= self.xs.len
    self.i += 1
    self.xs[self.i - 1]

obj Bag
  xs: List[Int]

  fun each(?self) -> Cur from self
    Cur(xs: ?self.xs, i: 0)

sub main()
  b = Bag(xs: List())
  !b.xs.push(4)
  !b.xs.push(5)
  for x in ?b.each()
    print(x)
  !b.xs.push(6)
  print(b.xs)
```

```output
4
5
[4, 5, 6]
```

```rig reject
obj Reads
  n: Int

  fun next(?self) -> Int?
    none

obj Count
  lo: Int

  fun next(!self) -> Int?
    none

sub main()
  r = Reads(n: 0)
  for x in r
    print(x)
  c = Count(lo: 0)
  for x in ?c
    print(x)
  for x in c
    print(x)
```

```error
cannot iterate over `Reads`: a `for` walks a type with `next(!self) -> T?`, but its `next` takes `?self`
`for x in ?c` would only read an iterator, which `next` cannot advance; write `for x in !c` to advance it in place
write `for x in !c`: the loop advances `c`
```

### Labels, break, and continue

A loop may be labeled `@name`; `break @name` and `continue @name` then
refer to it from an inner loop. A `match` or `raw` statement may be
labeled too, and `break @name` leaves it. No other statement takes a
label, since no jump could use it, and none takes two. A jump after `??` or `catch`
may name a label too ([§12](#the-fallback-of-)), also in a `while`
header (`while more() ?? break @outer : i += 1`). A label may repeat an
enclosing one's name; the innermost is meant. A `for` source is
evaluated before its loop is entered, as a loop's `else` runs after it
ends, so a jump in either (`for j in 0..(n ?? break v)`) leaves or
continues the loop around that `for`, and a `break` value there is that
loop's value.

A label is `@` and a name, which the `@` touches. It stands before a
statement that starts a line (or another label), or right after `break`
or `continue`; the statement after `=>`, `defer`, or `errdefer` takes
none. `@name(...)`, with the `(` touching the name, is a builtin call
([Builtins](#builtins)) instead, except right after a jump, where
`@name` is always a label: `break @outer (x)` leaves `outer` with the
value `(x)`, and `break @outer(x)` is rejected. A jump's value stands
apart from its label (`break @outer -1`, not `break @outer-1`). A
keyword is not a label name, and the old spelling, `:name`, is rejected
with a hint.

```rig reject
sub main()
  n = 3
  @done if n > 1
    print(n)
```

```error
a label names a loop, `match`, or `raw` block that `break` or `continue` can leave; `@done` cannot label an `if`
```

### Loops as values

A loop that `break` leaves with a value (`break v`, or `break @name v`
from an inner loop) is an expression. Its value is the value of the
`break` that leaves it, or, when the loop ends without one, the value
of its `else` block, which it therefore needs (only `while true` can do
without). Every `break` leaving it carries a value, and they and the
`else` value meet in one type. A `break` value is consumed like a
returned value: a name the loop declares moves out bare (`break x`),
since its scope ends with the move, an owning name from outside the
loop is moved with `<x`, and a view may not outlive what it views. The
value must be used; a `break` cannot carry a value out of a loop whose
value is not.

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
it moves nothing, and lends to write neither the matched value nor a
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

fun describe(s: Shape) -> ?String
  match s
    .circle(r) if r > 10 => "big circle"
    .circle(_), .square(_) => "small shape"
    .point => "point"

sub main()
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

A pattern binds a variant's fields either in order, all of them, or by
name, any of them; it doesn't mix the two. A field a pattern leaves out
is not bound: it stays with the subject, or under `match <e` it is
dropped at the end of the arm, as a `_` field is.

```rig
enum Shape
  rect(w: Int, h: Int, label: String)
  point

sub main()
  s: Shape = .rect(w: 3, h: 4, label: String("box"))
  match s
    .rect(h: tall) if tall > 3 => print("tall", tall)
    .rect(w, h, _) => print(w * h)
    .point => pass
  match !s
    .rect(label: l, w: w)
      w = 30
      l = String("wide")
    .point => pass
  match <s
    .rect(label: l) => print(l)
    .point => pass
```

```output
tall 4
wide
```

```rig reject
enum Shape
  rect(w: Int, h: Int)

sub main()
  match Shape.rect(w: 1, h: 2)
    .rect(w, h: b) => print(w, b)
```

```error
`.rect` binds its fields both in order and by name
```

A range pattern is half-open like every range, so `0..10` matches 0
through 9, and its end may be one past the type's largest value:
`100..256` covers the rest of a `U8`.

```rig
fun size(n: U8) -> ?String
  match n
    0..10 => "small"
    10..100 => "medium"
    100..256 => "large"

sub main()
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
| `match !e` | write views of the fields: assigning one writes the field in place |
| `match <e` | own the fields: `e` is consumed, and what an arm does not move on is dropped at the end of the arm |

A bare `match e` of a place only reads it, so moving a payload out of
it is rejected; that takes `match <e`. So does a match of a view a call
returns, of a branching value, or of a field or element of either. A call's result is taken, as
`match <e` would take it ([§7](#temporaries)): `match make()` owns its
payloads. A binding of `match <e`
owns what it binds: a resource it holds may be written and lent for
writing. A `Bool` is not matched with `!`: `match !flag` reads as
negation and is rejected, as `!flag` is anywhere a `!Bool` is not
expected. `match !e` needs a place that may be
written, as `!e` does, and while one of its bindings is live `e` cannot
be used otherwise. `match <e` needs a value `e` owns, not a view. A
boxed enum is matched where the box holds it, `match b` (as `match ?b`)
or `match !b` ([§10](#box)), and so is the value a handle holds,
`match h`, which reads it. A write view the subject makes, a call's
result (`match get(!h)`) or a branch whose every leaf is a write lend,
a call's result, or a write view taken with `<w`
(`match (!a if c else !b)`, `match optw(!e) ?? !d`), is
lent on, as `if … as` lends one on: its bindings write, as under
`match !e`. A branch is a value, never a place, so a header that reads
one where it stands lends it there: a subject that branches, or a path
through one (`match (a if c else b)` of `!E` names,
`for x in (a if c else b).v` of objects that own a List), is lent by
its sigil or, bare, to read, and a leaf a name holds is rejected, for
`match`, `if … as`, and `for` alike: lend each leaf, to read (`?a`) or
to write (`!a`). A bare subject the header copies (plain data) or a
branch of read views is read as a value. A part of a branch of lends is
matched to write once the branch has a name: `t = (!a if c else !b)`,
then `match !t.e`. Any other read match never writes through its
bindings: write `match !e` to write through them, and for a part of a
value made in the header, bind that value to a name first. A read
binding that is not plain data is a view (`?F`) of the field where it
is, so it carries the subject's loan:
a view of it may be returned, stored past the arm, or given as the
match's value, for as long as the subject may be viewed. The subject may
not change, move, or end while such a view is used; to keep what a
binding holds past that, copy it (`+r`, or a plain field), or take the
subject with `match <e`. A match on a part of a value made there (`match mk().e`)
holds that value until the match ends when the part is not plain data,
so its payloads are read where they are; a part of plain data is read
in the header, whose temporaries end with it.

```rig
obj B
  n: Int

  drop(!self)
    print("drop", self.n)

enum Slot
  full(b: *B, uses: Int)
  empty

sub keep(b: *B)
  print("kept", b.n)

sub main()
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
obj B
  n: Int

  drop(!self)
    print("drop", self.n)

enum Slot
  full(b: *B)
  empty

sub keep(b: *B)
  print("kept", b.n)

sub main()
  s: Slot = .full(b: *B(n: 1))
  match s
    .full(b) => keep(<b)
    .empty => print("empty")
```

```error
cannot move `b` out of `s`: `match s` reads `s`; write `match <s` to take its fields
```

```rig
obj Res
  n: Int
  t: String

enum E
  a(r: Res)
  b(r: Res)

fun inner(e: ?E) -> ?Res
  match e
    .a(r) => ?r
    .b(r) => ?r

fun name(e: ?E) -> ?String
  match e
    .a(r) => ?r.t
    .b(r) => ?r.t

sub main()
  e = E.a(r: Res(n: 1, t: String("hi")))
  print(name(?e), inner(?e).n)
```

```output
hi 1
```

```rig reject
obj Res
  n: Int
  t: String

enum E
  a(r: Res)
  b

sub main()
  e = E.a(r: Res(n: 1, t: String("hi")))
  k = Res(n: 0, t: String("k"))
  saved = ?k
  match e
    .a(r) => saved = ?r
    .b => pass
  e = E.b
  print(saved.n)
```

```error
cannot reassign `e` while it is lent
```

### pass

`pass` is a statement that does nothing. It stands where a statement
is needed and there is no work: a match arm (`_ => pass`), a loop
body, an `if` branch, or a function body. It has no value, so a match
arm, branch, or block whose value is used cannot end with it.

```rig
sub main()
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

sub main()
  print(sign(0))
```

```error
`pass` does nothing and has no value
```

### defer and errdefer

`defer stmt` (or `defer` with a block) runs when the enclosing block
exits, in reverse order of the defers. `errdefer` runs only when the
function exits with an error, so it is written only where one can: in
a `fun f() -> T!`, a `sub f()!`, `sub main()`, a closure whose type can
fail, or a test. In a function, closure, or `drop` body that cannot
fail, or inside deferred code, it is rejected: write `defer`. A deferred body may not move or drop
outer bindings, or propagate with `!`. It runs after the values declared
after it are dropped, so it may not read one through a view. A
one-line `defer` or `errdefer` cannot declare a name; a deferred block
can.

```rig reject
sub main()
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

sub main()
  log(1)
```

```error
`errdefer` runs only when the function fails, and `log` cannot fail; use `defer`
```

---

## 7. Ownership

Every owning value and handle has exactly one owner, which decides when
it is released. The sigils mark ownership effects where they happen; a
read lend may go unwritten where its view lasts only for the use, and a
value that is not moved is dropped where its scope ends, with no mark:

| Sigil | Name | Effect |
|---|---|---|
| `<x` | move | ownership passes on; `x` is unusable until reassigned |
| `?x` | lend to read | a read view; `x` keeps ownership |
| `!x` | lend to write | a write view, the only view while it lives |
| `+x` | clone | a new owner, as the type says ([Clone](#clone)) |
| `<x` (a statement) | drop | release `x` now |
| `^x` | box | move `x` into a new box with one owner ([§10](#box)) |
| `*x` | share | move `x` into a new shared handle ([§9](#9-shared-and-weak-handles)) |
| `~x` | weak | a weak handle to a shared value ([§9](#9-shared-and-weak-handles)) |

Plain data and read views copy, so they are used freely
([§2](#kinds-of-value)). `<x` always means "done with `x`", whatever its
type: a value that copies is copied out, and `x` is unusable until it
is assigned again. Of a field or element, `<` takes an optional one and
rejects any other ([Moves](#moves)).

```rig reject
sub main()
  n = 1
  m = <n
  print(n)
```

```error
use of `n` after move
```

### Reading

> **Core 1:** A bare name only reads.

An expression either **takes** its value or only **reads** it. A
binding, an argument to a parameter that owns it, `return`, a stored
field or element, and `<` take. A `print` or `String(...)` argument, an
`==` operand, `?e`, a `?self` receiver, and a field or element read
only read. Reading never moves a name, whatever form reads it: a read
passes through `a if c else b`, `??`, `catch`, `e!`, and `e?` to their
operands, so `print(a if c else b)` reads `a` or `b` where it is and
moves nothing.

Where its value is taken, a bare name copies plain data and read views
([§2](#kinds-of-value)). It never clones, so a bare owner or handle
there is an error, because two owners would release it twice: write
`<x` to move it or `+x` to make a new owner. It moves only where the
value leaves for good: `return x`, or `x` as the last value of the
function or block that declares it. As
an argument where a parameter takes a view, or as a header's subject,
it is lent to read where it is ([Lending](#lending)).

```rig reject
obj Wrap
  n: Int

sub main()
  a = *Wrap(n: 1)
  b = a
```

```error
`a` is a `*Wrap` handle, which can't be copied by `=`: write `<a` to move it, `+a` for another handle, or `?a` to view it
```

A view of a value that copies ([§2](#kinds-of-value)) is copied out
wherever the value is expected, whether a name holds the view or an
expression yields it (`f(!x) + 1`, `take(f(!x))`, `if flag(!b)`,
`p: Point = r` with `r: ?Point`); the loan taken to reach it ends
there, and the copy carries only the loans of the views it holds. An
operator, and a binding with no type, read a view of a number, `Bool`,
`?String`, or plain enum as the value; a binding with no type copies a
read view of anything else as the view. A bare name or place only
reads, so a binding with no type reads the value a name's write view
sees when that value copies (`x = w`), and holds
a write view a call yields, which is a value, not a place ([View
places](#view-places)). A value that does not copy is not copied out of
a view: lend it on, as `?T` or `!T`. A write lend written where its
view would only be read, `!x`, is rejected instead
([Lending](#lending)).

```rig
fun slot(a: !Int) -> !Int
  a

sub main()
  n = 4
  m: Int = slot(!n)
  print(slot(!n) + slot(!n), Float(slot(!n)), m)
```

```output
8 4.0 4
```

### Moves

> **Core 2:** `<x` moves, `+x` makes a new owner. A statement `<x` moves `x` nowhere, so it drops now.

A value moves when it is passed to a parameter of owning type, bound to
another name, stored in a field, or returned. Write `<x` when `x`
stays in scope after the move; where `x`'s scope ends with the move,
the move is plain: `return x`, `x` as the last value of the function
or block that declares it, and `break x` of a name the loop declares.
After a move the name cannot be used until it is reassigned.

```rig
obj Packet
  id: Int

  drop(!self)
    print("released", self.id)

sub send(p: Packet)
  print("sent", p.id)

fun make(id: Int) -> Packet
  p = Packet(id: id)
  p

sub main()
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
obj Packet
  payload: Int

  drop(!self)
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

The checker follows every path. A value moved in one branch of an `if`
or `match` is moved after it; a value moved inside a loop is moved at
the top of the next iteration, unless the loop is left or the value is
reassigned first.

```rig reject
obj Wrap
  n: Int

sub eat(b: *Wrap)
  print(b.n)

sub main()
  b = *Wrap(n: 1)
  i = 0
  while i < 2 : i += 1
    eat(<b)
```

```error
use of `b` after move
```

`<` always leaves its source done: a name is ended, an optional field
or element is emptied to `none` ([Places](#places)), and `<` on any
other place is rejected, as on a function or a module's constant, which
lives for the whole program. So only whole bindings move. Moving a field
that moves out of an object is rejected (the object would still drop
it); clone a shared field with `+p.a`, move the object as a whole, take
an optional field, or exchange the field with `replace` or `swap`
([Places](#places)). A field or element that copies would stay as it
was, so `<p.n` is rejected too, and a plain read, `m = p.n`, copies it.
A part of a value made in the statement (`<mk().n`, `<mk().v`) is
dropped with it, so nothing would see it ended or emptied: it is
rejected too, and the value is bound to a name first. A branching value
gives up only its leaves made there, so a leaf that is a name or a
part is moved where it is: `<a if c else <b`, `(<o)?`.

```rig reject
obj P
  n: Int

sub main()
  p = P(n: 1)
  m = <p.n
  print(m, p.n)
```

```error
cannot move out of `p.n`: it copies, so `<` would leave it as it was; remove the `<` to copy it
```

```rig reject
fun first(o: Int?) -> Int?
  x = <o?
  print(o)
  x
```

```error
`<` here would copy `o` out without moving it; move it before the `?` or `!`: `(<o)?`
```

### Clone

`+x` makes a new owner. For a shared or weak handle it bumps the
count; for plain data it copies; for a String, a List, a box, an
optional, an array, or an object or enum declared in the module that
holds them, it clones each part the same way: a String's bytes and a
List's elements are copied, a box's value is boxed again, and a handle
inside is counted again (a deep copy). A type with a `drop` body, a
unique type (one holding a `Cell`, or declared `unique`), a `Signal`,
and a type imported from another module have no clone. `+p.a` clones
the value in a field, and `+v[i]` an element.
`+e` only reads `e`: a value made there (`+make()`) is a temporary its
statement drops, and `+(a if c else b)` reads `a` or `b` where it is.

### Drop

> **Core 3:** An owner that is not moved is dropped where its scope ends.

A statement `<x` moves `x` nowhere, so it releases `x` now; afterwards
`x` cannot be used. Every owning local and parameter that is still live
is dropped automatically when its block ends, including on early
`return`, `break`, and `continue`, and on every path through branches.
So a drop is only needed to release something early, or to end a view
a binding holds. A view parameter cannot be dropped: the caller owns
what it views. Plain data owns nothing, so `<n` of an `Int` or an object
of numbers drops nothing, and is rejected. A `?String` may view a `String`
(§10), so `<s` of a `?String`, or of an object holding one, ends the loan
it carries.

```rig
obj Noisy
  id: Int

  drop(!self)
    print("drop", self.id)

sub run(early: Bool)
  a = Noisy(id: 1)
  b = Noisy(id: 2)
  if early
    <b
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
declaration. So a value whose drop runs a `drop` body may not view a
value declared after it: that value is dropped first.

### Lending

> **Core 4:** `?x` lends `x` to read, and `!x` lends it to write, as whichever view the context expects.

A lend hands over a view of a value without giving it up, and view
parameter types say the same thing: `b: ?Wrap` reads, `b: !Wrap`
writes. `?` promises that nothing changes: no field, element, or
`Cell` changes through a read view, and a method that changes a `Cell`
takes `!self` ([Changes and shared storage](#changes-and-shared-storage),
[§10](#cell)). A write lend is always written. A read lend may go unwritten
where its view lasts only for the use: an argument to a view parameter
(`balance_of(acct)` is `balance_of(?acct)`, and a slice is lent the
way its name is: `total(w[1..3])` is `total(?w[1..3])`), a method's receiver
([§3](#objects)), the subject of a `for`, `if … as`, or `match`
([§6](#6-control-flow)), and a held view or a function name lent on to
read ([§11](#callable-views)). `print(...)` and `String(...)` read their
arguments, so a slice there goes unwritten too (`print(w[1..3])`). A
lend kept in a binding or a field is always written: `r = ?x`. So is a
lend whose view a call's result keeps, when that result is kept in a
binding, a field, a return, or a call that stores it:
`r = head(?v)`, `xs = ?b.all()`, `!xs.push(head(?v))`. A result
used within its statement (`print(head(v).len)`) lends implicitly, since
its loan ends with the statement. The owner stays lent for as long as the view
is used, and a value made there (`balance_of(open())`) is lent as a
temporary of its statement.

```rig
obj Account
  balance: Int

fun balance_of(a: ?Account) -> Int
  a.balance

sub deposit(a: !Account, n: Int)
  a.balance += n

sub main()
  acct = Account(balance: 100)
  deposit(!acct, 50)
  print(balance_of(?acct), balance_of(acct))
```

```output
150 150
```

A variant literal whose enum comes from the view it goes to
(`.table(...)` where a `?Val` goes) is that value, `Val.table(...)`,
made there and lent the same way; where `Val.table(...)` is rejected (a
view kept or returned, a `!Val`), so is the literal. A plain enum's read
view holds a copy of the value, so `.red` goes wherever a `?Color` does.

```rig
enum Val
  num(n: Int)
  table(m: List[Int])

sub show(v: ?Val)
  match v
    .num(n) => print(n)
    .table(m) => print(m.len)

sub main()
  show(.table(m: List()))
  show(.num(n: 3))
```

```output
0
3
```

```rig reject
enum Val
  num(n: Int)
  table(m: List[Int])

fun made() -> ?Val
  return .num(n: 3)
```

```error
type mismatch: expected `?Val`, got `Val`
```

A constant (a literal, `none`, a function, a module's constant, an
enum variant that holds no payload or an error value, a number type's
limit such as `Int.max`, or a type's function such as `P.origin`, of
any module, an operator applied to constants, or a value that
branches, every value of which is a constant) lives for the whole
program and never changes, so it is never lent to write:
`setb(!false)`, `setc(!Color.red)`, `inc(!Int.max)`, and `setf(!f)`
are rejected. A local binding is no constant, whatever it holds:
`g = f` may be lent to write.

`?x` and `!x` lend the view the context expects:

| Owner `x` | `?x` lends | `!x` lends |
|---|---|---|
| any `T` | `?T` | `!T` |
| `[N]T`, `List[T]` | `[]T` | `![]T` |
| a place `p.f` or `v[i]` | the views of the field or element | its write views |
| a held `!T` | `?T` | `!T` (lent on) |
| `![]T` | `[]T` | `![]T` (lent on) |
| `String` | `?String` (also `(?String)?`) | `!String` |
| `^T` | the views of `T`, through any number of boxes | the write views of `T` |
| `*T` | the read views of `T` | `!*T`, the handle itself, never a view of the value |
| `X?` | `View?` for each view of `X` | `!(X?)`, by the first row |
| a function or closure | `?fun` | |

So `sort.sort(!v)` works on a List as it does on an array, and one `fun
area(s: ?Shape)` takes `?s` of a `Shape`, a `^Shape`, and a
`*Shape` ([§9](#shared-handles), [§10](#box)). A slice `x[a..b]` is the
same lend, of part of `x` ([§2](#slices)), and as an argument it goes
unwritten where `x` does.

A written `!` must lend to write
([Core 4](docs/CORE.md#2-the-core-in-ten-sentences)): `!x` is kept only
where the type it goes to is a write view (a `!T` parameter, a write
receiver, a type spelled or expected with one, or a value
whose type it gives: a binding with no type, an array literal, or an
`if`, `match`, or loop each of whose values is one), and rejected
wherever `x` is only read. A written `!x` binds a generic's `T` to the
value it reaches where that copies, so `Opt.some(v: !n)` would store an
`Int`, and is rejected: write `Opt.some(v: n)` to store a copy. No
value keeps a write view ([write views](#write-views)), so `Opt[!Int]`
is rejected too. A value that branches
or loops is decided at each of its leaves. A held write view (`w`,
a `!T` parameter) has no `!` written, and is read, or lent where a read
view goes, as a bare name is.

| Written | Where it goes | Write instead |
|---|---|---|
| `bump(!n)` | `bump(x: !Int)` | kept: `bump` may write `n` |
| `!n + 1`, `arr[!i]`, `print(!n)` | read as a value | `n` |
| `Opt.some(v: !n)` | an `Opt[Int]` | `n` |
| `rd(!n)` | `rd(x: ?Int)`, which only reads | `rd(?n)` |

```rig reject
enum Opt[T]
  some(v: T)
  nothing

sub main()
  n = 1
  o = Opt[!Int].some(v: !n)
  print(n)
```

```error
a write view is never stored inside a value, and `!Int` cannot stand here
```

```rig reject
enum Opt[T]
  some(v: T)
  nothing

sub main()
  n = 1
  o = Opt.some(v: !n)
  match !o
    .some(v) => v += 1
    .nothing => pass
  print(n)
```

```error
`!n` here is read, not held: `Opt.some` stores an `Int`. Write `Opt.some(v: n)` to store a copy
```

```rig reject
sub main()
  n = 1
  print(!n + 1)
```

```error
`!n` here is read, not held: only its `Int` is read here. Write `n`
```

```rig reject
fun rd(x: ?Int) -> Int
  x

sub main()
  n = 1
  print(rd(!n))
```

```error
`!n` here is read, not held: `rd` only reads `n`; write `rd(?n)`
```

A `!x` view needs a binding that may change: a parameter (other than
`!T`), a fixed binding, a capture, or a loop binding cannot be
lent to write. `!` lends any value to write, named or temporary
([Core 4](docs/CORE.md#2-the-core-in-ten-sentences)): a temporary, such
as a call's result or an object literal, or a field or element of one,
is kept in its statement's slot until the statement ends
([Temporaries](#temporaries)), where the change is seen, and a view of
it may be used only within the statement. A branching value that may
be a name's (`!(a if c else b)`), or a field, element, or method
receiver reached through one (`!(a if c else b).w`), would be lent as a
copy, which the change would miss, so it is rejected: lend each branch,
`!a if c else !b`. A constant is no temporary, and is never lent to write (above).

```rig
obj Wrap
  n: Int

  fun next(!self) -> Int
    self.n += 1
    self.n

sub grow(b: !Wrap)
  b.n += 1
  print(b.n)

sub main()
  grow(!Wrap(n: 1))
  print((!Wrap(n: 5)).next())
```

```output
2
6
```

```rig reject
obj Wrap
  n: Int

fun first(b: !Wrap) -> !Int
  !b.n

sub main()
  w = first(!Wrap(n: 1))
  print(w)
```

```error
a view of the temporary `Wrap(n: 1)` outlives its statement, which drops it; bind the value to a name first
```

A lend of a place is never the base of a path: `(!p).x`, `(?arr)[0]`,
`(!v)[0..2]`, the lend moved, `(<(!p)).x`, and a field holding
functions, `(!t).ops[1](5)`, are rejected wherever they stand, a
closure's or a function's last value included. The lend goes on the
whole path (`!p.items.push(3)`, `if !arr[0] as v`, `match !p.e`,
`?arr[0..1]`, `x = ?p.items`), and an assignment or a read needs none
(`p.x = 5`, `arr[i] += 7`, `v.len`). A part of a temporary is not
assigned to or bound by a header: bind the value to a name first. A
read lend is not written through, `(?p).x = 5`. Three forms are not this
rule's: a method's receiver, `(!s).insert(k)`
([SYNTAX §5](SYNTAX.md#receiver-sigils)); a value that branches,
`(!a if c else !b).x`, whose lends pick the place its path reaches; and
a lend of a slice, `(?t[..])[0]`, which makes the view the path
indexes. A written `!` on such a slice the path only reads,
`(!arr[..])[0]`, is rejected as any `!` only read is: write
`(?arr[..])[0]`.

```rig
obj P
  x: Int
  o: Int?

sub main()
  p = P(x: 1, o: 2)
  q = P(x: 3, o: none)
  arr = [1, 2]
  p.x = 5
  arr[1] += 7
  if !p.o as v
    v += 1
  c = true
  (!p if c else !q).x += 1
  print(p.x, p.o, q.x, arr)
  t = String("abc")
  print((?t[1..])[0], (?arr[1..]).len)
```

```output
6 3 3 [1, 9]
98 1
```

```rig reject
sub main()
  arr = [1, 2]
  (!arr)[0] += 7
  print(arr)
```

```error
`(!arr)[0]`: write a lend on the whole path, not its base: `arr[0] += 7`
```

#### Write views

A write view is the only view of what it views while it lives. It can be
lent on, written `!p` as an owned value's view is, or moved into a local
with `<p`, but not copied; assigning it writes through
([View places](#view-places)). It is never stored inside a value (Core
§5): a field, an element, a type argument, and what a read view
or a handle reaches never hold one.

```rig reject
sub peek(w: ?(!Int))
  print(w)

sub keep(ws: List[!Int])
  print(ws.len)
```

```error
a write view is never stored inside a value, and `!Int` cannot stand here
```

### One writer or many readers

> **Core 5:** A place has any number of read loans, or one write loan, never both.

While a read loan is live the place cannot be written, moved, or
dropped; while a write loan is live the place cannot be used at all,
whatever its type: even a number is not read until the view's last use,
so `w = !n` then `w += n` is rejected. A loan on a place covers every
place inside it, and a field is a place of its own, so `p.a` and `p.b`
may be lent apart, while `p` and `p.a` may not ([Paths](#paths)).

```rig reject
obj User
  name: ?String

sub main()
  u = User(name: "ada")
  r = ?u
  w = !u
  print(r.name)
```

```error
cannot lend `u` to write while a read loan is live
```

### How long a loan lasts

> **Core 6:** A loan lasts until the last use of every view that carries it.

A view passed to a call ends when the call returns, so two calls in one
statement may each lend the same value to write. A method call lends
its receiver for the whole call, so `rc.show(<rc)` is rejected. A view
stored in a binding, or in a view ([below](#second-class-views)), lasts
until its last use. Every later use counts: a use further on, a use
anywhere in a loop around it that the binding was declared outside of
(the next iteration runs it again), a use in a `while` step, which
counts after the body, where the step runs ([while](#while)), a closure that captured it (and
every use of that closure), a binding that views the view in turn,
deferred code, and the drop at scope exit of a value whose drop runs a
`drop` body (its own, or one of a value it holds and drops), which could
read the view. Any other drop only releases memory, so a `List[?T]`, or
an object holding views without a `drop` body, keeps their loans only
until its last use. The binding's block ending, `<r`, or reassigning it
also end the view.

```rig
obj Wrap
  n: Int

  sub bump(!self)
    self.n += 1

obj View
  box: ?Wrap

sub main()
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
obj Wrap
  n: Int

  sub bump(!self)
    self.n += 1

sub main()
  x = Wrap(n: 1)
  r = ?x
  i = 0
  while i < 2 : i += 1
    print(r.n)
    !x.bump()
```

```error
cannot lend `x` to write while a read loan is live
```

```rig reject
fun grow(v: !List[Int]) -> Int
  !v.push(1)
  v.len

sub main()
  v: List[Int] = List()
  !v.push(7)
  w = !v[0..1]
  k = 0
  w[0] = match k
    0 => grow(!v)
    _ => 3
  print(v[0])
```

```error
cannot lend `v` to write while a write loan is live
```

**Evaluation order within a call.** A call evaluates its arguments left
to right and uses them all when it runs, so what an earlier argument
holds is still in use while the later ones are evaluated. A view (`?v`)
or a slice (`?v[..]`) in an earlier argument keeps its loan until the
call ends. So does an argument that reads a place by value when that
value shares storage the place owns: a List, a `^T`, a `*T` or `~T`
handle, an object holding one, or what a write view reaches, as
`print(v)` reads it. A later argument of the same call (`print`
included) cannot lend that place to write or move it, since the call
would see a stale value, or memory already freed: `print(v, grow(!v))`
is rejected ([CORE §6](docs/CORE.md#6-bindings-and-assignment)). Plain
data is copied whole when it is read, so `print(v.len, grow(!v))` and
`print(p, bump(!p))` for a plain object `p` are accepted, and print the
values as they were read. A write receiver's arguments may read it,
`!v.push(v.len)`, since they finish before the call writes.

```rig
obj P
  x: Int

fun grow(v: !List[Int]) -> Int
  !v.push(7)
  v.len

fun bump(p: !P) -> Int
  p.x += 1
  p.x

sub main()
  v: List[Int] = List()
  !v.push(v.len)
  print(v.len, grow(!v), v)
  p = P(x: 1)
  print(p, bump(!p), p)
```

```output
1 2 [0, 7]
P(x: 1) 2 P(x: 2)
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
fun grow(t: !String) -> String
  !t.add("more")
  String("x")

sub main()
  a = String("a")
  print(a == grow(!a))
```

```error
cannot lend `a` to write while the left operand's read of it is in use
```

A view of a place (`!v[i]`, `?p.xs[i]`, a slice `!v[i..]`, or the
receiver of a method call) finds the place up to each index before the
index runs, so an index cannot write lend or move the place's root:
it could grow or free the memory the place is in. A place that is read
or taken (`<v[i]`) is found up to each index before the index runs too.
Its index may write lend or move the root only where the element is
read from an array held in place or from a List's buffer, which is read
after the index runs, and what is indexed lies in the root's own
storage, reached through fields of objects and elements of arrays:
`vs[grow(!vs)]` and `p.v[grow(!p)]` find `vs` and `p.v` where they were
and read the element after. So may an index of a slice root
(`xs[partition(!xs)]` for `xs: ![]Int`): a lend of a slice writes the
elements it views but never moves or frees them. Anywhere else, past a List's buffer, a box,
a handle, or a Cell, the index could free what the place is in, so
`v[0][grow(!v)]`, `p.bx.vals[rebox(!p)]`, and `h[reh(!h)]` for a
handle `h: *List[Int]` are rejected. An
assignment finds its target only after the indexes run
([§4](#4-bindings-and-assignment)), so `v[grow(!v)] = 1` is accepted.

```rig reject
obj P
  a: [4]Int

fun grow(v: !List[P]) -> Int
  !v.push(P(a: [0, 0, 0, 0]))
  1

sub set(n: !Int)
  n = 9

sub main()
  ps: List[P] = List()
  !ps.push(P(a: [1, 2, 3, 4]))
  set(!ps[0].a[grow(!ps)])
```

```error
cannot lend `ps` to write in an index of a place it is lending
```

```rig reject
fun grow(v: !List[List[Int]]) -> Int
  !v.push(List())
  0

sub main()
  v: List[List[Int]] = List()
  !v.push(List())
  !v[0].push(5)
  print(v[0][grow(!v)])
```

```error
cannot lend `v` to write in an index of a place it is lending
```

### Second-class views

> **Core 7:** A call passes on only the loans its signature shows.

Views are values the checker follows, not types you annotate: there is
no lifetime syntax. A view can be held by a parameter, a local, an object
field (which makes the object a view too), or a function's result, and
the checker tracks where every one came from.

- A function may return a view only of something its caller lent it, or
  of something that lives for the whole program (literals, module
  constants, `std.os.args()`): a view of its own local is rejected
  ([CORE 7](docs/CORE.md#2-the-core-in-ten-sentences)). The result then
  views from every argument whose type could hold what it views, a
  `?String` argument included: it may view a String ([§10](#string)). An
  argument that could not (an `Int` key for a `?Item` result, a `?String`
  for a `?Item`) is free again after the call.
- A result that holds no write view only reads what it views, so the
  loans it carries are read loans, even of an argument lent to write,
  whose write lend ends as the call returns unless the call may store
  it (a generic callee, whose `T` could hold anything, may): after
  `r = head(!v)`, `v` may be read while `r` lives, but not written,
  moved, or dropped, and so it may in the call's own statement (`print(head(!v), v.len)`), the
  body of `for x in head(!v)`, and the arms of a `match` on such a call. A result that is a write view (`-> !Int`, `-> (!Int)?`)
  keeps the argument lent to write.
- A result may say which parameters it views: `-> ?Item from a` (also
  `from a, b`, `from self`, and `from static`, for only what lives for
  the whole program). The result then views from those arguments
  alone, and the compiler checks the body against the clause: a body
  that returns a view of a parameter it does not name is rejected. A
  name must be a parameter whose type could hold what the result
  views. A function lent as a value (`?first`) is called with what its
  type says, as if it had no clause.
- A view reached through another view views what that view views,
  not what holds it: `?c.items[0]`, with `items: ?List[Item]`, views
  the List, not `c`.
- A call keeps only what its signature shows. A view lent to it (a
  `?T`, `!T`, `[]T`, `![]T`, `?String`, an optional of one, or a `?self`
  or `!self` receiver) it keeps only when the signature names that
  parameter in `keeps`: `sub watch(!self, s: ?String) keeps s` (also
  `keeps s, t` and `keeps self`, after the result type and any `from`).
  It may then store what the view sees in what its write receiver and
  write arguments lead to, and the loan lasts while that holder is used;
  every other lend ends when the call returns. A value passed by value
  is the callee's, which may keep it, and its loans, wherever its type
  fits; `keeps` does not name it. A function called as a value
  (`?watch`) keeps what its type could hold, as if every lent parameter
  were named, and so does a method of a built-in generic (`!v.push(x)`,
  a Cell's `set`). The compiler checks each body against its `keeps`: a body
  that stores a lent parameter where its caller reaches it, on any path
  (into `self`, a write argument, or through a call that keeps it),
  without naming it, is rejected at the store with the clause to write.
  `keeps` names lent parameters, each once, that something the function
  writes could hold. A place lent to a kept parameter is lent with `?`
  written: `!b.watch(?t)`, `?a.register(!out)`.
- An object holding a view keeps the viewed value lent while the
  object is alive. So does a stack closure that captured a view, and
  a value a call may have stored a view into (its receiver lent to
  write, and what its `!` arguments and other write views lead to):
  a view of each argument the call keeps, as above.
- A view may not outlive the value it views: not past the end of
  its block, not through `break`, and not out of the function.

```rig
obj Wrap
  payload: Int

obj View
  box: ?Wrap

fun pick(a: ?Wrap, b: ?Wrap, first: Bool) -> ?Wrap
  if first
    a
  else
    b

sub main()
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
obj Wrap
  payload: Int

  drop(!self)
    print("drop")

fun first(a: ?Wrap, b: ?Wrap) -> ?Wrap
  a

sub main()
  x = Wrap(payload: 1)
  y = Wrap(payload: 2)
  r = first(?x, ?y)
  <y
  print(r.payload)
```

```error
cannot drop `y` while it is lent
```

```rig
obj Bag
  items: List[Int]
  taken: Int

  fun take(!self) -> []Int
    self.taken += 1
    ?self.items[..1]

sub main()
  b = Bag(items: List(), taken: 0)
  !b.items.push(4)
  r = (!b).take()
  print(b.taken, b.items.len)
  print(r)
```

```output
1 1
[4]
```

A view parameter can be forwarded (`g(?b)` with `b: ?B`). The caller
still owns a viewed value: a view parameter cannot be dropped or
move-captured, and a field cannot be moved out of it.

### Temporaries

> **Core §3:** A view of a temporary may be used only within its statement.

A value made where it is only read (a call's result, a constructor's
included, `+x`, `<x`, or a block or `match` value) has no name: its
statement is its scope, so it is a **temporary**. One that owns a
resource is dropped when its statement ends, last made first, also
when the statement fails (`!`) or leaves early (`?? return`). A
temporary that nothing reads or takes (an expression statement) is
rejected: bind it to a name first. A temporary may be lent to read or
to write; it lives until its statement ends, and any change made
through the view lands in it and is dropped with it. So a temporary
lent to write (`!make().bump()`, `grow(!make())`) is kept in its
statement's slot, where the change is seen, and dropped when the
statement ends ([Lending](#lending)). A value that holds a Cell is
never a temporary: it lives only behind a shared handle
([Cell](#cell)).

```rig
obj B
  n: Int

  drop(!self)
    print("drop", self.n)

fun size(s: ?String) -> Int
  s.len

sub main()
  a = B(n: 2)
  b = B(n: 3)
  print(B(n: 1), size(?String("four")))
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

A `match` arm's body is a statement of its own, as each line of a
block is: a temporary made there is dropped where the arm ends, while
the arm's bindings are still in scope, so it may view them.

```rig
obj Tag
  n: ?Int

  drop(!self)
    print("drop tag", self.n)

fun show(t: ?Tag) -> Int
  t.n + 1

sub main()
  for i in 0..2
    match i
      0 => print("zero")
      m => print("m", show(?Tag(n: ?m)))
    print("after", i)
```

```output
zero
after 0
m 2
drop tag 1
after 1
```

```rig
obj Log
  lines: List[Int]

  fun count(?self) -> Int
    self.lines.len

fun make() -> Log
  Log(lines: List())

sub main()
  print(make().count(), make().lines.len)
```

```output
0 0
```

A `!self` method called on a temporary, or on a field or element of
one, lends it to write, and every change is marked by `!`: without one
the call is rejected, with the hint to add it. `!Counter(n: 1).bump()`
is `(!Counter(n: 1)).bump()` ([SYNTAX §5](SYNTAX.md#receiver-sigils)).
The method sees the temporary in its statement's slot, and its result
may be used, or not:

```rig reject
obj Counter
  n: Int

  sub bump(!self)
    self.n += 1

sub main()
  Counter(n: 1).bump()
```

```error
`bump` changes its receiver, a temporary no name holds; add `!`: `!Counter(n: 1).bump()`
```

```rig
obj Counter
  n: Int
  log: List[Int]

  fun bump(!self) -> Int
    self.n += 1
    !self.log.push(self.n)
    self.n

  fun at(!self) -> !Int
    !self.n

fun counter() -> Counter
  Counter(n: 1, log: List())

sub add(n: !Int, k: Int)
  n += k

sub main()
  !counter().bump()
  print((!counter()).bump(), counter().log.len)
  add((!counter()).at(), 10)
  print((!counter()).at() + 1)
```

```output
2 0
2
```

A view of a temporary (`?S(n: 1)`, `?make()`, `?make()[1..]`), and
any view made from one (a call's result that views it), may be used
anywhere in its statement, and nowhere after: held by a binding, a
field, a List, or a returned value, it is rejected.

**Headers are their own statements:** an `if` or `while` condition, a
`match` guard, and the subject of a `match` or `for`. A header's
temporaries end with the header, before the body runs; what the header
binds lives through the body. So `if text.starts_with(?String(a, b),
"x")` works, but `if text.cut(?String(a, b), "=") as kv` must bind the
String first, because `kv` outlives the header. A value made there that
`if … as`, `while … as`, `match`, or `for` binds is taken, as `<e`
would take it: a call's result, or a branching value whose every
branch is made there (`make() if c else <a`). An arm of `match make()`
may move a payload out. A lend of a
branching value that may be a name's (`?(a if c else b)`), or of a
path through one (`?(a if c else b).items`), would copy that name's
value, so it is rejected: lend each branch, `?a if c else ?b`.

```rig
use std.text

sub main()
  print(text.trim(?String("  padded  ")) == "padded")
  n = text.find(?String("abc"), "b") ?? -1
  if text.starts_with(?String("x", n), "x1")
    print("starts")
  kv_text = String("k=v")
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

obj S
  n: Int

sub main()
  r = ?S(n: 1)
  s = text.trim(?String(" a "))
  print(r.n, s)
```

```error
a view of the temporary `S(n: 1)` outlives its statement, which drops it; bind the value to a name first
a view of the temporary `String(" a ")` outlives its statement
```

A header that makes a temporary is evaluated before that temporary
ends. When its subject is a place reached from outside the header's
temporaries (from a name, or from a view whose evaluation makes none),
through an index or an argument that makes one, the header binds the
place's own, as it would with no temporary: a write through what it
binds reaches the place.

```rig
fun idx(s: ?String) -> Int
  s.len - 1

sub main()
  arr: [1]Int? = [1]
  if !arr[idx(?String("a"))] as n
    n = 50
  print(arr)
```

```output
[50]
```

Any other subject that makes a temporary, a value made in the header or
a part of one, has no place that outlives the header, so what the header
binds would be a copy of it, which a write through the binding would
miss: it is rejected, whatever it binds, unless it takes
the value made there (`match parse(?String(s))`, `if find(?String(s)) as
i`) or binds plain data of it. Bind the value, the index, or the
argument to a name first.

```rig reject
obj P
  o: Int?

fun mk(s: ?String) -> P
  P(o: s.len)

sub main()
  if mk(?String("a")).o as n
    print(n)
```

```error
this header binds a copy of its subject, since a temporary it makes ends with the header
```

A `?self` or `!self` receiver is lent as `?e` or `!e` would be when the
method may keep a view of it, in its result or through a write
argument. A temporary receiver, plain data included, then lives until
its statement ends, so the view may be used there and nowhere after (a
`!self` method's temporary receiver is written `!e`:
[Temporaries](#temporaries)). A
receiver that branches lends each leaf where it is:
`(a if c else b).name()` keeps a loan on `a` and on `b`, so neither may
change while the view lives.

```rig
obj S
  t: String

  fun name(?self) -> ?String
    ?self.t

sub main()
  a = S(t: String("aa"))
  b = S(t: String("bb"))
  n = (a if a.t.len > 1 else b).name()
  print(n, S(t: String("cc")).name())
```

```output
aa cc
```

```rig reject
obj S
  t: String

  fun name(?self) -> ?String
    ?self.t

sub main()
  a = S(t: String("aa"))
  b = S(t: String("bb"))
  n = (a if a.t.len > 1 else b).name()
  a.t = String("zz")
  print(n)
```

```error
cannot assign to `a.t` while `a` is lent
```

A temporary handle to a value that holds a Cell changes the value it
shares, whose `drop` sees the change when its last handle goes, here
when the statement ends; a branch that takes a name's handle changes
the value that name shares:

```rig
obj Counter
  hits: Cell[Int]

  drop(!self)
    print("drop", self.hits.get())

  sub hit(!self)
    !self.hits.set(self.hits.get() + 1)

fun fresh(n: Int) -> *Counter
  *Counter(hits: Cell(n))

sub bump(c: !Counter)
  !c.hits.set(c.hits.get() + 10)

sub main()
  !fresh(0).hit()
  !fresh(1).hits.set(5)
  bump(!fresh(2))
  k = fresh(3)
  !(k if k.hits.get() > 5 else fresh(4)).hit()
  !(k if k.hits.get() < 5 else fresh(6)).hit()
  print(k.hits.get())
```

```output
drop 1
drop 5
drop 12
drop 5
4
drop 4
```

### Places

> **Core §5:** Each field and element is a place.

A field `p.f` or an element `v[i]` is read bare ([Reading](#reading)),
lent with `?` and `!` ([Lending](#lending)), and assigned, which drops
its old value. An optional field or element is also **taken**: `<p.f`
takes the value out and leaves `none` behind, in one step, so the object
stays whole and nothing is dropped twice. Taking writes the place, so it
needs a path that may write it (an owned local, a `!T`, not a `?T` or a
`*T`), and no other view of the value may be live, and it needs an
owner: a field of a temporary cannot be taken. Whether a field can be
taken is decided by its type where it is named: inside a generic body a
`T?` field can be, a `T` field cannot, whatever `T` is. An `as` binding
that owns a resource moved into it (`if <o as n`) has fields that can be
written and taken, like a local's. A local binding is still moved whole:
`<x` leaves `x` unusable, never `none`. A field or element that is not
optional is neither ended nor emptied, so `<` on it is rejected
([Moves](#moves)). `<`'s operand is a place or a value made there:
`<(a if c else b)` and `<o?` are rejected, and written
`<a if c else <b` and `(<o)?`. A path that passes through a value of a
view type (`!T`, `?T`, a slice) or a handle reaches its place through
it, whatever its syntax: `w.f` of a held `w: !T`, `(?a if c else ?b).f`,
and `wrap(!p).f` of a call returning a `!T`. Through a write view an
optional is taken there; through a `?T` or a handle nothing is, since
the take writes the place. Nothing else is moved out through any of
them (`replace(!p.f, v)` exchanges it).

```rig
obj Node
  value: Int
  next: ^Node?

obj Stack
  top: ^Node?

  sub push(!self, v: Int)
    self.top = ^Node(value: v, next: <self.top)

  fun pop(!self) -> Int?
    if <self.top as n
      self.top = <n.next
      return n.value
    none

  sub reverse(!self)
    cur = <self.top
    prev: ^Node? = none
    while <cur as n
      cur = <n.next
      n.next = <prev
      prev = <n
    self.top = <prev

sub main()
  s = Stack(top: none)
  for v in [1, 2, 3]
    !s.push(v)
  !s.reverse()
  print((!s).pop(), (!s).pop(), (!s).pop(), (!s).pop())
```

```output
1 2 3 none
```

#### Paths

> **Core §5:** A field is a place of its own.

A place is named by a **path**: a name and the fields after it. The
path goes on through a struct's fields, through what a write view the
name holds sees (`self.a` in a `!self` method, `p.a` of `p: !P`), and
through a box (`b.a` of `b: ^T`, which has one owner). It stops at an
element (`p.items[i]` is a place of `p.items`: an index is a value the
program computes, and a push may move the buffer), a handle (`p.h.a`
with `h: *T` is a place of `p.h`, whose contents other handles reach),
a read view (what `p.v.a` with `v: ?T` reaches is what the view views,
and a lend of it keeps the view's loans, not a loan on `p`), and an
optional's value. A loan is on the path so far.

Two places conflict when one path is a prefix of the other. A use
touches the path it names: `?p.a`, `!p.a`, `<p.a`, `p.a = x`,
`(!p.a).m()`, `!p.a.m()`, and `swap(!p.a, !p.b)` touch `p.a` (and
`p.b`); a bare `p`, `<p`, `p = x`, `(!p).m()`, and `!p.m()` touch all of
`p`. A closure captures a name, so `|?p|` lends all of `p`. So a write
of one field may stand beside a view of another:

```rig
obj Scanner
  text: String
  flags: Int

  sub tag(!self)
    t = ?self.text[0..2]
    self.flags |= 1
    print(t, self.flags)

sub main()
  s = Scanner(text: String("abcd"), flags: 0)
  !s.tag()
```

```output
ab 1
```

A method lends all of its receiver: its signature says `!self`, and a
caller does not look into its body. To lend only the fields a step
writes, lend them, `(!self.ast).add(...)`, or make the step a function
of those fields, which a caller gives disjoint paths:

```rig reject
obj Parser
  value: String
  count: Int

  sub bump(!self, t: ?String)
    self.count += t.len

  sub step(!self)
    (!self).bump(self.value)

sub main()
  p = Parser(value: String("id"), count: 0)
  !p.step()
```

```error
cannot lend `self` to write while a read loan on `self.value` is live
lend the fields it writes
```

```rig
sub bump(count: !Int, t: ?String)
  count += t.len

obj Parser
  value: String
  count: Int

  sub step(!self)
    bump(!self.count, self.value)

sub main()
  p = Parser(value: String("id"), count: 0)
  !p.step()
  print(p.count)
```

```output
2
```

A value never holds a view of itself: storing in a part of `p` a value
that carries a loan on a part of `p`, by assignment, through a write
view, or by a call that stores its argument, is rejected.

```rig reject
obj Holder
  t: ?String

  sub keep(!self, t: ?String) keeps t
    self.t = t

obj P
  a: Holder
  b: String

sub main()
  p = P(a: Holder(t: ""), b: String("x"))
  (!p.a).keep(?p.b)
  print(p.a.t)
```

```error
cannot let this call store a view of `p.b` in `p.a`: a value never holds a view of itself
```

A method's view result carries a loan on all of its receiver, where
the receiver's type could hold what it views (here `value`). Saying
which part of the receiver it views (`-> ?String from self.text`) is
planned, and would let the caller write the receiver's other fields
while the result lives:

```rig pending
obj Scanner
  text: ?String
  pos: Int
  value: String

  fun digits(!self) -> ?String
    start = self.pos
    while self.pos < self.text.len and self.text[self.pos] >= 0x30 and self.text[self.pos] <= 0x39
      self.pos += 1
    self.text[start..self.pos]

  sub number(!self)
    whole = (!self).digits()
    self.pos += 1
    frac = (!self).digits()
    print(whole, frac)

sub main()
  s = Scanner(text: "12.50", pos: 0, value: String())
  !s.number()
```

```output
12 50
```

#### Replace and swap

`replace(!place, v)` stores `v` in a place and hands back the value that
was there, owned; `swap(!a, !b)` exchanges the values of two places of
one type, which may be different fields of one value
(`swap(!t.left, !t.right)`), two places neither of which holds the
other ([Paths](#paths)). The places are lent to write for the call,
and the values hold no `?T`, `!T`, or slice. A place that holds a view, a
`?String` among them, is not lent to write: assign to it to point it at
other text. Like `print`, both are names a declaration may hide.

```rig
obj Pair
  left: String
  right: String

sub main()
  p = Pair(left: String("a"), right: String("b"))
  swap(!p.left, !p.right)
  old = replace(!p.left, String("c"))
  print(p, old)
```

```output
Pair(left: "c", right: "a") b
```

`replace(!p, v)` takes the old value out and stores `v`, as
`t = <p; p = v` would. What it hands back is no view of `p`: it views
what `p`'s value viewed, so `p` may be lent again while it lives, and
the value may be put back:

```rig
obj Scanner
  text: ?String
  value: String

sub main()
  src = "abc"
  s = Scanner(text: ?src, value: String())
  taken = replace(!s, Scanner(text: "", value: String()))
  _ = replace(!s, <taken)
  print(s.text)
```

```output
abc
```

Two elements of one collection are not two places: `swap(!a[i],
!a[j])` lends `a` to write twice, and is rejected with the collection's
own `swap`, which exchanges them ([§2](#slices)):

```rig reject
sub main()
  a = [1, 2, 3]
  swap(!a[0], !a[2])
  print(a)
```

```error
cannot lend `a` to write while a write loan is live: to swap two elements of `a`, write `!a.swap(0, 2)`
```

### Changes and shared storage

> **Core 9:** You change what you were lent with `!`, or what you share with `*`.

A name's own value changes by assigning it
([§4](#4-bindings-and-assignment)). A `Cell` is what handles share: a
value that holds one lives only behind a shared handle, and the Cell
changes only by a marked call, `!c.set(5)` ([§10](#cell)). The mark lends
the handle `c`, as `!v.push(x)` lends `v`; it is not exclusive over the
Cell, since another handle to it is another name, and the loan rules need
no case for it: `c` is a binding like any other, so a view of `c` held
across the mark conflicts with it, and a view of another handle does
not. A write view of a value that holds a Cell changes its Cells and
nothing else.
A write view is never stored inside a value
([Write views](#write-views)). A `Cell`, a `Signal`, and an owned
closure accept only values that carry no loan ([§10](#string),
[§11](#owned-closures)).

---

## 8. Drop and drop glue

An object may declare one `drop` body, which runs when a value of the
type is released. It takes exactly one parameter, its receiver
lent to write, spelled as a method's: `drop(!self)`, or `drop(self: !Self)`.

```rig
obj File
  fd: Int

  drop(!self)
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
object with a `drop` body or an owning field, an enum with an owning
payload, and a generic instance with an owning argument. Releasing a
value runs its `drop` body first, then releases its owning fields in
reverse declaration order, recursively. Glue does not depend on the
order of declarations in the file.

```rig
obj Noisy
  id: Int

  drop(!self)
    print("noisy", self.id)

obj Pair
  a: *Noisy
  b: *Noisy

  drop(!self)
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
`drop` bodies are only for non-generic objects; enums and generic
objects get structural glue only.

---

## 9. Shared and weak handles

### Shared handles

> **Core 8:** `*<x` moves `x` into a counted box, and `*S(...)` boxes a new value.

`*T` is a shared handle: a reference-counted box holding a `T`,
single-threaded, like Rust's `Rc<T>`. `*expr` moves a value into a new
box; for a named owning value, write the move: `*<x`. `+h` makes
another handle to the same box, and the value is released when the last
strong handle goes.

```rig
obj User
  name: ?String

  drop(!self)
    print("released", self.name)

sub main()
  a = *User(name: "ada")
  b = +a
  <a
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

A handle is its own kind ([§2](#kinds-of-value)): a bare copy (`b = a`,
`f(a)`) is rejected; write `<a` or `+a`. Sharing a value that is already
a shared handle (`*a` with `a: *T`, or the type `*(*T)`) is rejected;
clone it instead.

**Access is read-only.** Field reads, element reads (`h[i]` of a
`*[N]T`, `*List[T]`, or `*?String`), and `?self` methods reach through a
handle automatically, including through fields and loop elements. `?h`
lends the value's read views ([§7](#lending)), a `?Shape` of a `*Shape`
and a `?String` of a `*String`, with the loan on `h`, so `h` may not be
dropped, moved, or reassigned while the view is used. `!h` lends only
the handle itself (a `!*T`), never a write view of the value. Writing a
field, calling a `!self` method, or consuming the value through a handle
is rejected, because other handles share it, so `!h.push(x)` through a
`*List[T]` is rejected too. Shared state that changes goes in a `Cell`
([§10](#cell)): a shared List is a `*Cell[List[T]]`.

```rig reject
obj User
  age: Int

sub main()
  u = *User(age: 1)
  u.age = 2
```

```error
cannot assign through a shared handle
```

### Weak handles

`~h` makes a weak handle `~T` from a shared one. A weak handle does not
keep the value alive. `*w` upgrades it: it reads `w`, which stays
usable, and gives an optional strong handle `*T?`, a new count while
the value is alive and `none` after. `w` may be a `~T` or a view of one
(`?~T`), a name, a field, or an element. A weak handle reaches nothing
else: its fields and methods are reached only through `*w`, and one
held in a box or behind a handle is lent out first (`u: ?~T = ?c`, then
`*u`).

```rig
obj Node
  id: Int

  drop(!self)
    print("drop", self.id)

sub show(w: ?~Node)
  if *w as n
    print("alive", n.id)
  else
    print("gone")

sub main()
  rc = *Node(id: 7)
  w = ~rc
  show(?w)
  <rc
  show(?w)
```

```output
alive 7
drop 7
gone
```

`*` of a weak handle always upgrades it. `*w` reads `w`; `*<w` takes
it, so `w` is moved and its weak count dropped once upgraded, and a
later use of `w` is a use after move. A weak handle made there (`*~h`,
`*f()`) is taken the same way. So no counted handle holds a weak one:
`*~T` is rejected, as every holding sigil over a held value is
([§10](#box)). A suffix binds tighter than a prefix, so
`*w?` is `*(w?)`; to return `none` from the function once the value is
gone, write `(*w)?`. In a generic body, `*x` of a `T` copies `x` into a
new handle, whatever `T` an instance gives it, so a `T` that is a weak
handle does not suit it ([§3](#generic-bodies)).

```rig
obj Node
  id: Int

fun id_of(w: ?~Node) -> Int?
  n = (*w)?
  n.id

sub main()
  rc = *Node(id: 3)
  w = ~rc
  p = *w
  print(id_of(?w), p != none)
  <p
  <rc
  print(id_of(?w) ?? -1, *w == none)
```

```output
3 true
-1 true
```

### Cycles

A cycle of strong handles is never released: it leaks, as in Rust and
Swift. This is the one leak the compiler does not prevent. Break cycles
with weak handles: a child holds its parent weakly, and a callback
that refers back to its owner captures it weakly (`|~owner|`,
[§11](#captures)). Every test and example in this repository runs
leak-free, with no use of freed memory, under the sanitizing allocator.

---

## 10. Cell, List, Box, String, and Signal

These built-in types are part of the language's substrate. Their names
are reserved.

### Cell

`Cell[T]` holds one value that can be replaced through any handle to it,
by a marked call: it is what shared handles share
([§7](#changes-and-shared-storage)), and `*Cell[T]` is a shared value
that changes. A value that holds a Cell (a `Cell[T]`, or an object or
enum a field of which holds one) lives only behind a shared handle
(Core sentence 9): `*Cell[T]`, or `*S`. Its type may be a field's, of a
value itself so held, or stand behind `*`, `~`, or a read view; a
parameter takes a `?Cell[T]` or `?S`, to which a handle is passed. It
is never a local's, a parameter's, or a result's type by value, a type
argument (`List[Cell[Int]]`: write `List[*Cell[Int]]`), an element, or an
optional. A constructor call that makes one stands only as the operand
of `*` (`*Cell(0)`, `*Counter(hits: Cell(0))`), as a field argument of
a constructor of an object or enum that stands so, or as a field's
default (`hits: Cell[Int] = Cell(0)`).

| Member | Meaning |
|---|---|
| `*Cell(v)` | construct, behind a shared handle |
| `c.get()` | a copy of the value (a `T` of plain data only) |
| `!c.set(v)` | store `v`; the old value is dropped |
| `(!c).replace(v)` | store `v` and return the old value |
| `!c.push(x)`, `(!c).pop()`, `!c.keep(n)`, `!c.clear()`, `c.len` | a `Cell[List[T]]`: its List's members |
| `c[i]`, `(!c)[i] = x`, `c.get(i)` | a `Cell[List[T]]` of plain data: an element, bounds-checked, or `T?` |

`T` is plain data ([§2](#kinds-of-value)), an owning type, or a type
declared `unique`. An owning or unique value is never copied out of a
cell: it moves in with `set` / `replace` and moves out with `replace`.
What goes into a cell, by any of its members or `c[i] = x`, carries no
loan: it holds no `?T`, `!T`, or slice, nor a `?String` that may view a
String ([String](#string)), since every handle to the cell reaches it.

A `Cell[List[T]]` answers its List's members as `set` does, each a marked
call: `push` moves or clones an owning element in (`<x`, `+x`), `pop`
hands the last one out as `T?`, `keep(n)` drops all but the first `n`, and
`clear` drops them all. No user code runs while the cell's List is in use:
`clear` leaves the cell holding an empty List before it drops the
elements, and `keep` pops each element before it drops it, so a `drop`
body that reaches back into the cell finds a valid List. For the same reason an element is a
copy: `c[i]` and `c.get(i)` read one and `c[i] = x` writes one only
when `T` is plain data, an element cannot be lent, and a field of one is
not written in place. The elements of a List of handles are taken out
with `pop`, or by taking the whole List out with `replace`.

Every call that changes a Cell is marked: `set`, `replace`, `push`,
`pop`, `keep`, `clear`, `c[i] = x` (written `(!c)[i] = x`), and a `Signal`'s `set`
and `subscribe`. They take `!self`, so the receiver-sigil rule enforces
the mark, and a read view (`?Cell[T]`, a `?self` method of an object
holding one) cannot change a Cell. `!c` where `c` is a handle lends the
handle: `bump(!local)` with `local: *Cell[Int]`, and `bump(!k.hits)` with
`k: *Counter`. A closure or a `Signal` subscriber marks the handle it
captured, `|+c| !c.set(1)`. Reading (`c.get()`, `c.len`, `c[i]`) is
unmarked.

```rig reject
sub main()
  c: *Cell[Int] = *Cell(0)
  c.set(5)
```

```error
method `set` needs its receiver lent to write; write `!c.set(5)`: changing a shared Cell is marked with `!`
```

```rig reject
sub bump(c: ?Cell[Int])
  !c.set(c.get() + 1)
```

```error
cannot lend to write through a read view `?Cell[Int]`
```

A write view of a value that holds a Cell changes its Cells and nothing
else, since the value lives only behind a handle and a handle's other
fields only read: `swap` and `replace` do not exchange it whole. A
handle is lent as itself, `!*C`, which a callee may point elsewhere, only
where the handle may be written (an owned mutable local, a `!*C` parameter,
a handle field of a write view); anywhere else (a `=!` binding, a parameter that
is not a `!` view, a capture, a field of a value another handle shares) `!h`
lends what it holds, a `!C`, and a `!*C` parameter is a type mismatch whose
hint is to pass `+h` for a handle of your own. A read view of a handle, or
of a value that holds one, is not lent to write at all: `?` changes nothing.

```rig reject
obj S
  n: Int
  c: Cell[Int]

obj O
  a: S
  b: S

sub main()
  o = *O(a: S(n: 1, c: Cell(1)), b: S(n: 2, c: Cell(2)))
  swap(!o.a, !o.b)
```

```error
`swap` moves values whole, and `S` holds a Cell, so it lives only behind a shared handle, whose other fields only read
```

```rig reject
obj C
  n: Cell[Int]

obj W
  h: *C

sub repoint(h: !*C, other: *C)
  h = <other

sub main()
  w = *W(h: *C(n: Cell(0)))
  repoint(!w.h, *C(n: Cell(1)))
```

```error
type mismatch: expected `!*C`, got `!C`
```

```rig
obj Counter
  hits: Cell[Int]

  sub hit(!self)
    !self.hits.set(self.hits.get() + 1)

sub bump(c: !Cell[Int])
  !c.set(c.get() + 10)

sub main()
  count: *Cell[Int] = *Cell(0)
  other = +count
  !other.set(other.get() + 5)
  local: *Cell[Int] = *Cell(1)
  bump(!local)
  k = *Counter(hits: Cell(0))
  !k.hit()
  !k.hit()
  print(count.get(), local.get(), k.hits.get())

  shared: *Cell[List[Int]] = *Cell(List())
  !shared.push(7)
  !shared.push(8)
  (!shared)[0] = shared[0] + 1
  print(shared.len, shared[0], shared.get(1), shared.get(2))

  # Anything else: take the value out, use it, and put it back.
  v = (!shared).replace(List())
  sum = 0
  for x in ?v
    sum += x
  !shared.set(<v)
  print(sum, shared.len)
  if (!shared).pop() as last
    print("popped", last, shared.len)
```

```output
5 11 2
2 8 8 none
16 2
popped 8 1
```

```rig reject
sub main()
  c = Cell(0)
  v: List[Cell[Int]] = List()
  print(c.get(), v.len)
```

```error
`Cell(0)` makes a `Cell[Int]`, which holds a Cell, so it lives only behind a shared handle: write `*Cell(0)`
a value of `Cell[Int]` holds a Cell, so it lives only behind a shared handle: write `*Cell[Int]`
```

### List

`List[T]` is a growable array that owns its elements. The binding is the
buffer: a `List` is an owning value whatever its elements are, and they
are of any type but a write view or a value that holds a Cell
([CORE §5](docs/CORE.md#5-containers-and-fields-hold-values)): plain
data, owning values (a `String`, a `List`, a box, a handle, an object that
owns one), and read views.

| Member | Meaning |
|---|---|
| `List()`, `List(capacity: n)` | an empty List (typed by context) |
| `List.filled(n, x)`, `List[T].filled(n, x)` | a List of `n` copies of `x` (typed by `x`, by context, or by brackets); `x` must copy (below); panics when `n` is negative |
| `!v.push(x)` | append; an owning `x` is moved or cloned in |
| `v.len` | the number of elements |
| `v.is_empty()` | `v.len == 0`; it only reads, so `!v.is_empty()` is rejected (negate with `not`) |
| `v[i]`, `v[i] = x` | the element at `i`, a place as a field is: read in place, lent with `?v[i]` or `!v[i]`, taken with `<v[i]` when `T` is optional, and assigned, which drops the old value (bounds-checked) |
| `v.get(i)` | a copy of the element as `T?` (a `T` that copies; otherwise read `v[i]` or lend `?v[i]`) |
| `!v.pop()` | remove the last element, as `T?`; a handle is handed over to the caller |
| `!v.keep(n)` | keep the first `n` elements and drop the rest, last first; `n == v.len` changes nothing, `n == 0` drops every element; panics unless `0 <= n <= v.len` |
| `!v.resize(n, x)` | grow to `n` elements with copies of `x`, or shrink to `n` as `keep` does; `n == v.len` changes nothing; `x` must copy (below); panics when `n` is negative |
| `!v.insert(i, x)` | put `x` at index `i`, moving the elements from `i` on up by one; `i` may be `v.len`; panics past it |
| `!v.remove(i)` | remove the element at `i` and hand it over, moving the rest down by one; panics out of range |
| `!v.clear()` | drop every element |

`keep`'s count is the length that remains, as `!t.push(v, keep: k)` keeps
the first `k` bytes of `v` ([String](#string)): a rewind saves
`mark = v.len` and later calls `!v.keep(mark)`.

```rig
obj Step
  name: String

  drop(!self)
    print("undo", self.name)

sub main()
  steps: List[Step] = List()
  !steps.push(Step(name: String("open")))
  mark = steps.len
  !steps.push(Step(name: String("read")))
  !steps.push(Step(name: String("parse")))
  !steps.keep(mark)
  print(steps.len, steps[0].name)
  nums: List[Int] = List()
  for i in 1..8
    !nums.push(i)
  !nums.keep(2)
  print(nums)
```

```output
undo parse
undo read
1 open
[1, 2]
undo open
```

**`List.filled` and `resize` copy one value into many elements,** as
`fill` and `[n of x]` do, so the element must copy
([CORE §5](docs/CORE.md#5-containers-and-fields-hold-values)): plain
data or a read view, each copy carrying the view's loan. A call that
is handed one owner never makes several: a List of Strings, Lists,
boxes, handles, or objects that own one is grown by a loop whose `+x`
makes each element, and shrunk with `keep`. `n` is evaluated first,
then `x`, once, even when nothing is added.

```rig
sub main()
  seen = List.filled(4, false)
  depth: List[Int] = List.filled(3, 0)
  seen[2] = true
  !depth.resize(5, 7)
  print(seen, depth)
  !depth.resize(2, 0)
  print(depth)
  s = String("ab")
  names = List.filled(2, ?s)
  print(names)
```

```output
[false, false, true, false] [0, 0, 0, 7, 7]
[0, 0]
["ab", "ab"]
```

```rig reject
sub main()
  rows = List.filled(3, String("row"))
  print(rows.len)
```

```error
`List.filled` copies its value into every element, and a `String` owns a resource, so it cannot be copied: write a loop that makes each element with `+x` (`for 0..n` with `!xs.push(+x)`)
```

```rig
sub main()
  rows: List[String] = List(capacity: 3)
  base = String("row")
  for 0..3
    !rows.push(+base)
  print(rows)
```

```output
["row", "row", "row"]
```

A `for` loop lends the List to read for the whole loop ([§6](#for)), so
it cannot be modified inside it. An element that owns a resource is a
view of its slot, where `v` must be a binding, or a field or element of
one: it can be read, called, and cloned (`+x` is a new handle), but not
moved, dropped, or stored.

```rig
sub main()
  total: *Cell[Int] = *Cell(0)
  steps: List[*sub()] = List()
  !steps.push(*|+total| !total.set(total.get() + 1))
  !steps.push(*|+total| !total.set(total.get() + 10))
  for step in ?steps
    step()
  nums: List[Int] = List()
  !nums.push(3)
  !nums.push(4)
  while (!nums).pop() as n
    !total.set(total.get() + n * 100)
  print(total.get(), steps.len)
```

```output
711 2
```

```rig
sub main()
  v: List[?String] = List()
  !v.push("b")
  !v.insert(0, "a")
  !v.insert(v.len, "c")
  gone = (!v).remove(1)
  print(gone, v)
```

```output
b ["a", "c"]
```

```rig
obj P
  x: Int
  y: Int

obj B
  n: Int

  drop(!self)
    print("drop", self.n)

sub main()
  ps: List[P] = List()
  !ps.push(P(x: 1, y: 2))
  ps[0].y = 5
  print(ps[0], ps.len)
  bs: List[*B] = List()
  !bs.push(*B(n: 1))
  !bs.push(*B(n: 2))
  if (!bs).pop() as last
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

`^T` is a box: one `T` alone on the heap, with one owner. An object or
enum can hold itself through a box (`next: ^Node?`), since a box is a
pointer whatever `T` is. A box moves (`<b`), is never copied, `+b`
boxes a clone of its value ([§7](#clone)), and dropping it drops the
value and frees the memory. Long chains of boxes are released without
deep recursion. The sigil binds tighter than a suffix: `^Node?` is an
optional box, and a box of an optional is `^(Node?)`.

| Member | Meaning |
|---|---|
| `^Node(...)` | a box of a new `Node` |
| `^<x` | move the owner `x` into a new box |
| `^x` | copy the plain value `x` into a new box |
| `b.f`, `b.m(...)` | a field or method of the boxed value, reached through the box (and through any boxes it holds): an object's or enum's, a List's (`!b.push(x)`, `b.len`), a String's (`!b.add(s)`, `b.len`) |
| `?b`, `!b` | lend the box, or, where a view of the value is expected, that view: `?T` or `!T`, a `[]T` of a boxed array or List, a `?String` of a boxed String, through any number of boxes |
| `<b.unbox()` | move the value out; the box is freed |
| `<s.f` | take an optional box out of a field, leaving `none` ([§7](#places)) |
| `match b`, `match !b` | match a boxed enum where it is |

The box is reached as it is held: through an owned box or a `!^T`
its value can be written, through a `?^T` only read. A consuming
(`<self`) method of the value, `<b.m()`, takes the value out of the box
first. `T` may be a read view (`^?v`, a `^?List[Int]`): the box keeps
`v` lent while it is used. `T` holds no write view. A box has no field
of its own: `b.value` of a `^Int` names nothing, and the number is lent
(`?b`) or taken apart. A List holds boxes as it holds handles: walked by
viewed slot and moved out with `pop` ([List](#list)).

**A value is held one way on the heap:** `^T` with one owner, `*T`
counted, or `~T` weak. A holding sigil over a held value (`^^T`, `^*T`,
`*^T`, `^~T`, `**T`, `*~T`), or over an optional of one (`*(~T?)`,
`^(*T?)`), is rejected: in a written type or an alias, in the type of a
value (`*<o` of an `o: (~T)?`), and in the fields and signatures of
every generic instance the program makes, written or named in an
expression (`W[~S](h: none)` where `W[T]` holds a `(*T)?`). `^none`
boxes nothing (an optional box with no value is `none`), and a
function has no box: `^fun` is rejected and reserved, and an owned
closure is `*|...| body`.

```rig reject
obj Holder
  inner: ^*Int
  twice: ^^Int
  weak: *~Int
  maybe: *(~Int?)
```

```error
`^*Int` stacks one heap holding on another
`^^Int` stacks one heap holding on another
`*~Int` stacks one heap holding on another
`*(~Int?)` stacks one heap holding on another
```

A generic body's own holding of a `T` (`*<x`, `List[*T]`) at an instance
whose `T` is held is decided and not yet built: it will be rejected at
that instance, as the generic per-instance requirements are.

```rig pending
obj N
  n: Int

fun hold[T](x: T) -> Int
  h = *<x
  <h
  1

sub main()
  s = *N(n: 1)
  print(hold(~s))
```

```error
`*~N` stacks one heap holding on another
```

A recursive enum holds its children in boxes, and a function reads one
through a view of the box:

```rig
enum Expr
  num(n: Int)
  add(l: ^Expr, r: ^Expr)

fun eval(e: ?^Expr) -> Int
  match e
    .num(n) => n
    .add(l, r) => eval(?l) + eval(?r)

fun num(n: Int) -> ^Expr
  ^.num(n)

sub main()
  e = ^Expr.add(l: num(2), r: num(3))
  print(eval(?e))
```

```output
5
```

With `if ?o as x` and `if !o as x` ([§12](#12-optionals)), an optional
box is used where it is:

```rig
obj Node
  key: Int
  left: ^Node?
  right: ^Node?

sub insert(slot: !^Node?, key: Int)
  if !slot as n
    if key < n.key
      insert(!n.left, key)
    else
      insert(!n.right, key)
  else
    slot = ^Node(key: key, left: none, right: none)

sub walk(slot: ?^Node?)
  if slot as n
    walk(?n.left)
    print(n.key)
    walk(?n.right)

sub main()
  root: ^Node? = none
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

### String

`String` is owned, growable text: bytes on the heap, UTF-8 by convention,
released when the String is dropped. It is an owning value, so a bare
name moves nothing: `<t` moves it and `+t` copies its bytes into a new
String. A `?String` is the view of text; a String is where text is built.

| Member | Meaning |
|---|---|
| `String()` | an empty String; nothing is allocated until text is added |
| `String(a, b, ...)` | a String holding each value as `print` writes it ([§17](#17-printing)), with no separators |
| `!t.add(a, b, ...)` | append each value the same way; a `U8` is written as a number |
| `!t.push(b)` | append one byte `b`, a `U8`, given by position |
| `!t.push[T, e](v)` | append the `@size(T)` bytes of the integer `v`, a `T`, in byte order `e` (`.little` or `.big`), in one write; a one-byte `T` takes no `e`, and `push[U8](b)` is `push(b)` |
| `!t.push(v, keep: k)`, `!t.push[T, e](w, keep: k)` | append the first `k` bytes of `v`, a `Simd[U8, n]`, or of the integer `w` in byte order `e`; `0 <= k <= size of v`, else it panics (a constant `k` out of range is an error); with no `keep:`, `push[T, e]` keeps every byte |
| `!t.reserve(n)` | make room for `n` more bytes, so the next `n` bytes of `push` allocate nothing; the length is unchanged |
| `!t.clear()` | empty it |
| `t.len` | its length in bytes, read-only |
| `?t[a..b]`, `?t[a..]`, `?t[..]` | a `?String` viewing its bytes from `a` up to `b`, bounds-checked like any slice ([§2](#slices)) |
| `?t`, with or without a `?String` or `(?String)?` expected | `?t[..]`; a bare `t` argument too ([§7](#lending)) |
| a view `p: ?String` (a name, or a call's result) | a `?String`: `p[a..b]` is a view of its bytes, with no further `?` |
| a write view `w: !String` (also of a `*String` or a `^String`) | `?w[a..b]`, which lends `w`, as a slice of the String itself does: `w` may add to the String or replace it |
| `for b in t`, `for b in ?t` | its bytes, as `U8`s |
| `?b[a..b]`, `?b` of a `^String` | the same, through the box |
| `+t`, `+s` of a `?String` | a new String holding the same bytes |
| `t == u`, `t == s` | compares its bytes with a String's or a `?String`'s; a boxed String too |

Each value is written as `print` writes it at the top level: a `?String`
or a String as its text, a number as `print` shows it, an object, enum,
optional, array, or List as `print` writes it, with the `?String` values inside
it quoted. Rig has no `+` on text and no interpolation: text is built
with `String(...)` and `!t.add(...)`, and every change to a String is
written with `!`.

```rig
obj Point
  x: Int
  y: Float

sub main()
  t = String("n=", 42, " p=", Point(x: 1, y: 2.5))
  !t.add(" ok=", true, " ", ["a", "b"])
  print(t)
  print(t.len, t == "n=42", t[..4])
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

`push[T, e]` is the writing side of `bytes.read[T, e](at)` ([Bytes](#bytes)):
`T` is an integer type (or a type parameter every instance gives one),
`e` a compile-time `Endian`, and a multi-byte `T` without `e` is an
error. `reserve(n)` is amortized: it grows the buffer at least
geometrically, so reserving a little at a time stays linear.

`keep: k` appends only the first `k` bytes of a vector of bytes, or of an
integer's bytes in order `e`, for text copied a block at a time while it
is scanned. `k` is an `Int`, `0 <= k <= size of v`; outside that it
panics in every build mode (when `k` is a constant, the program is
rejected). It desugars to `reserve(size)`, one unaligned store of all
`size` bytes after the length, and a length of `len + k`. The bytes
stored past the new length are spare capacity: `len`, indexing, slices,
`read`, printing, and `clone` never reach them, and the next push
overwrites them. A vector is appended only with `keep:`; its lanes must be
one-byte (`U8`).

```rig
sub main()
  src = String("abcdefghijklmnopqrstuvwxyz")
  v: ?String = ?src
  block = v.read[Simd[U8, 16]](0)
  t = String()
  !t.push(block, keep: 5)
  !t.push[U32, .big](0x2d2d2d2d, keep: 2)
  !t.push(block, keep: 0)
  print(t, t.len)
```

```output
abcde-- 7
```

```rig reject
sub main()
  t = String("abcdefghijklmnop")
  v: ?String = ?t
  block = v.read[Simd[U8, 16]](0)
  !t.push(block, keep: 17)
  !t.push(block, keep: -1)
```

```error
`keep: 17` is more than the 16 bytes pushed
`keep: -1` is negative; `push` keeps 0 up to the size of the value
```

```rig
sub main()
  t = String()
  !t.reserve(16)
  !t.push[U16, .big](0x4869)
  !t.push[U8](33)
  !t.push[U32, .little](0x2e2e2e2e)
  v: ?String = ?t
  print(t, t.len, v.read[U16, .big](0), v.read[U32, .little](3))
```

```output
Hi!.... 7 18537 774778414
```

```rig reject
sub main()
  t = String()
  !t.push[U16](1)
  !t.push[F32, .big](1.5)
```

```error
`push` of a `U16` takes a byte order too: `push[U32, .little](value)`
`push` appends an integer type; got `F32`
```

**A `?String` is a view of its String.** `?t[a..b]` lends the String as a
slice lends an array, and the `?String` it makes carries the loan: while
the `?String` is in use, the String cannot be changed, moved, or dropped,
and the `?String` cannot outlive it. The loan goes wherever the `?String`
goes: into a binding, an object field, a `List[?String]`, an optional, a
closure's captures, and a call's result, since a function returning a
`?String` may return a view of a `?String` it was passed
([§7](#second-class-views)). Once the last use of the `?String`, and of
every value holding it, is past, the String is free again; a List holding
one is in use until its last use, since dropping it reads no `?String`
([§7](#how-long-a-loan-lasts)).

`String(...)` and `!t.add(...)` only read their arguments, as `print`
does: a place is read where it is when the call runs, after its later
arguments, and a value made there is a temporary its statement drops
([§7](#temporaries)). A `?String` viewing a temporary String, as in
`text.trim(?String(a, b))`, may be used within its statement, and within
a header only by the header itself ([§7](#temporaries)); bind the String
to a name to keep the view longer.

```rig
fun first_word(s: ?String) -> ?String
  i = 0
  while i < s.len and s[i] != 32
    i += 1
  s[..i]

obj Entry
  name: ?String

sub main()
  t = String("hello world")
  w = first_word(?t)
  e = Entry(name: ?t[6..])
  names: List[?String] = List()
  !names.push(w)
  print(w, e, names)
  <names
  !t.add("!")
  print(t)
```

```output
hello Entry(name: "world") ["hello"]
hello world!
```

```rig reject
fun first_word(s: ?String) -> ?String
  s[..5]

fun local() -> ?String
  t = String("gone")
  ?t[..]

sub main()
  t = String("hello world")
  w = first_word(?t)
  !t.add("!")
  print(w, local())
```

```error
cannot lend `t` to write while a read loan is live
cannot return a view of `t`, which this function was not lent
```

A `?String` whose origin a function cannot see, a parameter or a value
built from one, may view a String, so it stays where views are
followed. It cannot be stored in a `Cell` or a `Signal` (by `Cell(v)`,
`set`, `replace`, `push`, or `c[i] = v`), or captured by an owned
closure, since every handle to those reaches what they hold;
nor can a closure store its `?String` parameter through a capture. A
generic body that stores a `T` in a `Cell`, a `Signal`, or an owned
closure cannot be instantiated with a `T` that holds a `?String`, even
when every `?String` passed is a literal. A `Static` carries no loan, so
it can be stored there ([Static](#static)): a `Cell[Static]`, a
`Signal[Static]`, an owned closure that captures one, and a generic
body's `T = Static`. Where a `?String` must outlive the String it came from,
copy it into a String of its own: `String(s)`.

A String owns its bytes, and a `List[String]` owns its Strings, as
`List[^String]` does through its boxes. A List that
holds views keeps their Strings lent until its last use, not until it is
dropped, since dropping it reads none of them.

```rig
sub main()
  owned: List[^String] = List()
  !owned.push(^String("one"))
  !owned.push(^String("two"))
  t = String("a b")
  views: List[?String] = List()
  !views.push(?t[..1])
  print(owned, views)
  !t.add("!")
  print(t)
```

```output
["one", "two"] ["a"]
a b!
```

```rig reject
sub keep(c: !Cell[?String], s: ?String)
  !c.set(s)

sub main()
  c: *Cell[?String] = *Cell("")
  keep(!c, "a")
```

```error
cannot store a view of `s` in a `Cell`
```

### Signal

`Signal[T]` holds a value of plain data and a list of subscribers, owned
closures of type `*sub()`. It lives behind a shared handle: a stack
`Signal` is rejected.

| Member | Meaning |
|---|---|
| `*Signal(v)` | construct |
| `s.get()` | the current value |
| `!s.set(v)` | store `v`, then call every subscriber in subscription order |
| `!s.subscribe(cb)` | take ownership of the handle `cb` (pass `+cb` to keep yours) |

Both are marked calls, as a Cell's are. A `set` from inside a subscriber is queued and delivered after the
current round, with the latest value winning. Subscribing from inside a
subscriber panics. A subscriber that reads its own signal must capture
it weakly, or the signal and its subscriber keep each other alive.

```rig
sub main()
  sig: *Signal[Int] = *Signal(0)
  !sig.subscribe(*|~sig|
    if *sig as s
      print("now", s.get())
  )
  !sig.set(7)
  !sig.set(9)
```

```output
now 7
now 9
```

Signal is deliberately minimal: richer reactive libraries are built in
Rig from `Cell`, `List`, and owned closures (see
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
| `\|+x\|` | a value that copies, or a view of one | a copy of the value |
| `\|+x\|` | `*T` or `~T`, or a view of one | a clone of the handle |
| `\|+x\|` | an owner, or a view of one | a deep copy, as `+x` makes ([§7](#moves)) |
| `\|<x\|` | any | the value, moved in; the outer `x` is gone |
| `\|?x\|` | any | a read view `?T`, as `?x` gives it |
| `\|!x\|` | any a write view may take | a write view `!T`, as `!x` gives it |
| `\|~x\|` | `*T` | a weak handle `~T` |

The closure's environment owns what it captured and releases it once,
when the closure is released, not after each call. The body may use,
call, and clone a captured owning value, but not move, drop, or
reassign it: the closure may be called again, so it cannot be the
closure's value either. For the same reason `<` of any capture is
rejected, a copy (`|+n|`) too: `<n` would leave the closure's `n` as
it was for the next call, and a plain `n` copies it. A captured view
may be passed to a call, which views it for the call. A captured read view may be the
closure's value, and a call's result then views what the closure
captured. Through a captured write view the body can write fields,
call `!self` methods (`!w.push(x)`), lend it on for a
call (`!w`), and assign the whole value (`w = v`, `w += 1`), which
writes through to what it views. Nothing the closure owns or receives
as a parameter may be stored through it: those last one call at most,
and the captured value outlives them. A name may be captured once per
list.

`|?x|` and `|!x|` lend `x` for as long as the closure lives, which is
until its last use: `|!x|` is `w = !x` followed by `|<w|`. While the
closure lives, `x` follows the aliasing rule
([§7](#one-writer-or-many-readers)); after its last call, `x` is free
again.

```rig
sub main()
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
sub main()
  total: *Cell[Int] = *Cell(0)
  add = |+total, k: Int|
    step = |+total, +k| !total.set(total.get() + k)
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
`List`'s element type, an object field, or a function's return type. An
annotation is allowed anywhere and must agree with the context; with no
context, every parameter must be annotated. A closure may ignore a
parameter by naming it `_`, and, where its type is known, may leave out
the trailing parameters it does not use: it is the same closure with a
`_` for each one it omits. Only trailing parameters can be left out
(`|_, c|` skips the second, `|c|` binds it), a closure never takes more
parameters than its type passes, and an untyped closure (`f = || ...`)
keeps the parameters it declares. An argument passed for an omitted
parameter is handled as one passed to `_`: a lend ends as it does for
any lend, and an owned argument nothing binds is dropped when the closure
returns, after its body, in reverse order of the parameters. A
capture list is unaffected: entries with a sigil are captures, and bare
names are parameters, so `|+count, a|` still captures `count`.

```rig
obj Gone
  n: Int

  drop(!self)
    print("drop", self.n)

sub each(f: ?sub(Int, Gone))
  f(1, Gone(n: 2))

sub main()
  each(|| print("none"))
  each(|i| print("i", i))
  each(|_, g| print("g", g.n))
```

```output
none
drop 2
i 1
drop 2
g 2
drop 2
```

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

sub main()
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
| `sub(?String)` | takes a `?String`, returns nothing |
| `*fun(Int) -> Int`, `*sub()` | an owned closure of that shape |
| `~fun(Int) -> Int`, `~sub()` | a weak handle to an owned closure |
| `?fun(Int) -> Int`, `?sub()` | a callable view ([below](#callable-views)) |

Function types describe closures bound to locals and function names
used as values. A function type writes its result after `->`, as a
declaration does; a suffix belongs to the result, so `fun(Int) -> Int!`
returns an `Int!`, and an optional function is `(fun(Int) -> Int)?`. An owned closure is a
shared handle, so `~f` makes a weak handle to it, which upgrades like
any other ([§9](#weak-handles)).

```rig
sub main()
  f: *fun(Int) -> Int = *|a| a + 1
  w: ~fun(Int) -> Int = ~f
  if *w as g
    print(g(1))
  <f
  print(*w == none)
```

```output
2
true
```

### Stack closures

A closure literal without `*` lives in the stack frame of the function
that writes it, so it may not escape. It may be bound to a local
(`f = |...| body`, then called as `f(...)`), called where it is written
(`(|+n| print(n))()`), or lent to a call ([below](#callable-views)).
Anywhere else (a field, an array element, a return value) it is
rejected; make it owned instead. A closure binding is fixed and cannot
be copied or moved; `?f` lends it.

```rig reject
fun make() -> fun() -> Int
  n = 1
  |+n| n
```

```error
closures cannot escape their defining scope
```

### Callable views

A parameter of type `?fun(A) -> R` or `?sub(A)` takes a **callable
view**: a read view of something to call. It accepts

- a closure literal written in the argument, without `*`;
- a named stack closure lent as `?f`;
- a function name or a `fun` value, as it is;
- an owned closure lent as `?cb`.

A callable view is a view like any `?T` ([§7](#second-class-views)):
the callee may call it and forward it, and the caller's values stay
viewed while it lives. A lent closure literal views what it
captures for the call, so its captures conflict with the call's other
views, and its environment lives until the call returns, dropping
what it moved in. It costs one indirect call per invocation and
allocates nothing.

```rig
obj Res
  id: Int

  drop(!self)
    print("drop", self.id)

fun apply(f: ?fun(Int) -> Int, x: Int) -> Int
  f(x)

sub each(xs: ?List[Int], f: ?sub(Int))
  for x in xs
    f(x)

fun double(n: Int) -> Int
  n * 2

sub main()
  v: List[Int] = List()
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

No value holds a callable view: it is only a parameter's, a local's,
or a result's type, never a field's, an element's, a module-level
binding's, or a type argument. A function may return one only where it
returns a view its caller lent it, and a closure literal is not lent
to a call whose result could hold it. A call never changes a closure's
environment, so a closure is lent only to read: `!f` is rejected.

Only `?fun(...)` and `?sub(...)` written as such are callable views.
A `?T` whose `T` is a function type, in a generic function, a field, or
a payload, is a read view of a function value, and `!fun(...)` a
write view of one, which can be reassigned through; a closure is not
lent there (`?f` of a closure where a `?T` goes is rejected).
`*|...|` makes an owned closure, which is not what a `?fun` parameter
takes:

```rig reject
fun apply(f: ?fun(Int) -> Int, x: Int) -> Int
  f(x)

sub main()
  print(apply(*|a| a + 1, 2))
```

```error
views a closure for the call; write the closure without `*` (remove the `*`)
```

A closure lent to a call is checked with the call's other arguments:

```rig reject
sub each(xs: ?List[Int], f: ?sub(Int))
  for x in xs
    f(x)

sub main()
  c: List[Int] = List()
  each(?c, |!c, n| !c.push(n))
```

```error
cannot lend `c` to write while a read loan is live
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
    !count.set(count.get() + step)
    count.get()

sub main()
  next = make_counter(100)
  print(next(1), next(10))
  handlers: List[*fun(Int) -> Int] = List()
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

An owned closure is a method on its own environment: `*|<a, +b, p, q|`
checked against `*fun(P, !Q) -> R` is a value `*Env(a: <a, b: +b)` of
a type whose fields are the captures and whose one method is
`fun invoke(?self, p: P, q: !Q) -> R`, and `h(x, !y)` is
`h.invoke(x, !y)`. So the body reads its captures, and a re-entrant
call is one more read of them. Its parameters and result are any a
function's may be, and follow a function's rules
([Core sentences 4 and 7](docs/CORE.md#2-the-core-in-ten-sentences)): a view it is given,
read or write, lasts the call; what it is given to own, it drops,
returns, or stores through a write parameter, once, also when its body
fails or leaves the parameter out; and its result views only what the
call lent it, never its environment. A function type's parameters and
result are not parts of a value of that type, so a
`List[*sub(!Checker)]` holds no write view.

A stored closure takes a write view as an argument, for one call:

```rig
obj Mapper
  f: *fun(!Checker, Int) -> Int

obj Checker
  calls: Int
  mappers: List[Mapper]

  fun map(!self, m: Int, t: Int) -> Int
    f = +self.mappers[m].f
    f(!self, t)

sub main()
  c = Checker(calls: 0, mappers: List())
  double: *fun(!Checker, Int) -> Int = *|k, t|
    k.calls += 1
    t * 2
  !c.mappers.push(Mapper(f: <double))
  r = (!c).map(0, 21)
  print(r, c.calls)
```

```output
42 1
```

Calling a closure reads what holds it until the call returns, so a
closure held in `self` is not called with `!self`: the call could
replace it there and free the environment it runs in. Clone the handle
first, as `map` does above, `f = +self.mappers[m].f`, which adds one
count.

State that changes between calls lives in a captured `*Cell`, and
what the closure owns it captures with `<`:

```rig
obj Checker
  lookups: Int

  fun global_type(!self, name: ?String) -> Int
    self.lookups += 1
    name.len

fun resolver(name: ?String) -> *fun(!Checker) -> Int
  owned = String(name)
  cache: *Cell[Int?] = *Cell(none)
  *|<owned, <cache, c|
    if cache.get() as v
      return v
    n = (!c).global_type(?owned)
    !cache.set(n)
    n

sub main()
  c = Checker(lookups: 0)
  array = resolver("Array")
  a = array(!c)
  b = array(!c)
  print(a, b, c.lookups)
```

```output
5 5 1
```

A closure takes a view or an owner, and returns an owner:

```rig
sub main()
  shout: *fun(?String) -> String = *|s| String(s, "!")
  sum: *fun(List[Int]) -> Int = *|v|
    t = 0
    for x in v
      t += x
    t
  v: List[Int] = List()
  !v.push(2)
  !v.push(3)
  print(shout("hi"), sum(<v))
```

```output
hi! 5
```

An owned closure can be stored anywhere, so its environment carries no
loan ([§7](#changes-and-shared-storage)): it cannot capture a `?T`,
`!T`, or slice, or a value holding one, nor a `?String` that may view a
String ([§10](#string)); a stack closure can. `*` applies only to a
closure literal, not to a function name or a closure binding: write
`*|a| f(a)`.

---

## 12. Optionals

`T?` holds a `T` or `none`. A plain `T` is accepted where a `T?` is
expected, and `none` needs a known optional type.

| Form | Meaning |
|---|---|
| `a ?? b` | the value inside `a`, or `b` when `a` is `none`; where a `T?` is expected, `b` may be a `T?` too (as may a `catch` handler); where `a` holds a view of a value that copies and `b` is that value, the value the view reaches, copied out ([The fallback of `??`](#the-fallback-of-)) |
| `a == none`, `a != none` | test for absence |
| `a == v`, `a != v` | whether `a` holds the value `v`, a `T` |
| `if a as x` | run the block with `x` bound to the value inside `a`; `else` runs when `a` is `none` |
| `if ?a as x`, `if !a as x` | the same, with `x` a view of the value inside `a` |
| `?a` where a `View?` is expected | a view of the value inside `a`, or `none`: `?a` of an `S?` where a `(?S)?` is expected, of a `String?` where a `(?String)?` is, of a `List[Int]?` where a `([]Int)?` is; `?a` itself is a `?(S?)` |
| `if <a.f as x` | the same, taking the value out of a field and leaving `none` ([§7](#places)) |
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

sub main()
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
obj User
  name: ?String
  boss: Int?

fun find(id: Int) -> User?
  return User(name: "ada", boss: 2) if id == 1
  return User(name: "grace", boss: none) if id == 2
  none

fun boss_name(id: Int) -> (?String)?
  find(find(id)?.boss?)?.name

sub main()
  print(boss_name(1), boss_name(2), boss_name(3))
```

```output
grace none none
```

An optional of an owning value (such as the `*T?` `*w` gives) owns
what it holds. `if e as x` over a temporary gives `x` ownership, and it
is dropped at the end of the block. An optional held in a binding is
read where it is: `if m as x` is `if ?m as x`. To take its value, move
or clone it: `if <m as x`, `if +m as x`, and it is unwrapped the same
way: `(<m)?`.

To use the value where it is, lend the optional: `if ?m as x` binds
`x` as a read view of the value (`?T`), and `if !m as x` as a write
view (`!T`), through which `x.f = v` changes the value in place and
`x = v` replaces it. `m` stays lent for the block, as for any
lend. A `?T?` parameter, or another read view of an optional,
lends its value the same way with `if p as x`; a held write view is
lent on as `!p`, and a write view a call returns is bound as one.
Plain data read through a `?T?` is copied (in a generic body, so is
every `T`). A view cannot give up
a resource it holds, so `?` and `??` reject one.

```rig
obj Res
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

sub main()
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
obj User
  name: ?String

sub main()
  u: User? = none
  print(u.name)
```

```error
`User?`
```

### Joined bindings

An `if` or `while` condition may join several bindings, and `Bool`
conditions among them, with `and`: `if a as x and b as y`,
`if a as x and x > 3`, `while (!q).pop() as n and n > 0`. `as` binds
tighter than `and`, and the parts run in order, each only when the ones
before it held. Each binding is visible to the parts after it and to
the body, not to `else`, which runs when any part fails (and a loop
ends then). Each binding takes its own form: `if ?o as x and !p as y`
views from both. A binding made before a part that fails is dropped
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

sub main()
  print(sum(1, 2), sum(2, 1), sum(0, 2))
  xs: List[Int] = List()
  for n in 1..6
    !xs.push(n)
  total = 0
  while (!xs).pop() as n and n > 2
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

sub main()
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
innermost loop or name a label (`a ?? continue @outer`), and leaving
drops what the scope owns. In a `while` header the first `:` starts the
step, even after a jump (`while a ?? break : i += 1`), and a jump there
may name a label (`while a ?? break @outer : i += 1`). The jump takes the rest of the expression as its value,
and the left side of `?? return` is the whole expression before it, as
for `catch` (`a and b ?? return` is `(a and b) ?? return`), except in a
chain of `??`, where the jump belongs to the nearest one, as `??` is
right-associative: `a ?? b ?? return v` is `a ?? (b ?? return v)`.
Where `a ?? b` is only read, it reads the value inside `a`, or `b`,
where it is ([§7](#temporaries)). Where it is taken, it takes from each
side: the optional may hold an owning value when it is made there
(`make(k) ?? return`, `make(k) ?? make(0)`) or moved (`<o ?? return`,
`<h.f ?? return`, which leaves `none`), but not when it is reached
through a view, which gives up nothing. Anything
else on the right of `??` is a value of the optional's type, or of the
value it views (below), so a bare error value is no fallback:
`?? E.missing` is rejected, and failing is written
`?? return E.missing` in a fallible function.

```rig
error E
  missing

fun find(xs: ?List[Int], k: Int) -> Int?
  for x, i in xs
    return i if x == k
  none

fun index_of(xs: ?List[Int], k: Int) -> Int!
  i = find(xs, k) ?? return E.missing
  i + 1

sub main()
  xs: List[Int] = List()
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

When `a` holds a view, `?T` or `!T` (a `(?T)?`, such as `get` returns),
and the fallback is no view of the value but the value itself, `a ?? b`
is the value: what the view reaches, copied out when `a` has one, and
`b` when it is `none`. It is `if a as v` then `v` else `b`, with `v`
copied ([Reading](#reading)), so it needs a `T` that copies: a number,
a plain object or enum, or an optional of one. The copy keeps no loan
but those of the views it holds, so `n = m.get(k) ?? 0` leaves `m` free
to change. A fallback that is a view (`?? ?d`), a jump, or `none` where
an optional view is expected keeps the view instead, and a binding
with no type then reads a view of a number as the number. `catch` does
the same for a fallible view (`(?T)!`). A `T` that does not copy, such
as a `String` or a `List`, is not copied out: lend the fallback, which
gives the view, and clone that for a value of its own. Nor is a type
parameter `T` in a generic body, which may not copy in every instance,
as a view read where its `T` is expected is not.

```rig
use std.hash

obj Point
  x: Int
  y: Int

sub main()
  counts = hash.Map[String, Int]()
  for w in ["a", "b", "a"]
    n = counts.get(w) ?? 0
    !counts.put(String(w), n + 1)
  print(counts.get("a") ?? 0, counts.get("z") ?? 0)
  at = hash.Map[String, Point]()
  !at.put(String("home"), Point(x: 1, y: 2))
  p = at.get("home") ?? Point(x: 0, y: 0)
  !at.put(String("home"), Point(x: 5, y: 5))
  print(p.x, (at.get("away") ?? Point(x: 0, y: 0)).y)
  names = hash.Map[String, String]()
  !names.put(String("a"), String("ada"))
  s = +(names.get("b") ?? ?String("nobody"))
  print(s)
```

```output
2 0
1 0
nobody
```

```rig reject
use std.hash

sub main()
  names = hash.Map[String, String]()
  s = names.get("a") ?? String("nobody")
  print(s)
```

```error
only a value that copies is copied out of a view, and a `String` owns a resource: lend the fallback, so the result is the view, and clone that for a `String` of its own: `+(names.get("a") ?? ?String("nobody"))`
```

---

## 13. Errors

> **Core 10:** `e!` propagates a failure, and `e?` propagates an absence.

A function whose return type is `T!` may fail, and so may a `sub`
marked `!` (`sub save(n: Int)!`, of type `sub(Int)!`). A call to it
must say what happens to the failure, visibly:

- `f()!` propagates it: the enclosing function fails with the same
  error. The enclosing function must itself return a `T!`, be a
  fallible `sub`, or be the top-level `sub main()` or a `test`. A failure
  that leaves `main` ends the program after `main`'s drops: it writes
  `error: E.name` to stderr and exits with status 1.
- `f() catch fallback` handles it: the value of the call, or `fallback`
  when it fails. The fallback may be a jump, as after `??`
  ([§12](#12-optionals)): `f() catch return -1`, `f() catch |e| return e`,
  `f() catch break`, `f() catch continue`.

A bare call to a fallible function is rejected, and so is `!` on a call
that cannot fail. A `drop` body and a `defer` cannot propagate, and a
closure propagates only when its type can fail: one checked against
`?fun(?String) -> Int!`, `?sub(?String)!`, or `*fun(?String) -> Int!`
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

fun parse(s: ?String) -> Int!
  return Parse.empty if s.len == 0
  s.len

sub each(xs: []?String, f: ?sub(?String)!)!
  for x in xs
    f(x)!

sub main()
  total = *Cell(0)
  each(["ab", "c"], |+total, l| !total.set(total.get() + parse(l)!))!
  each(["ab", ""], |+total, l| !total.set(total.get() + parse(l)!)) catch |e| print("failed", e)
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

sub main()
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
fun parse_len(s: ?String) -> Int!
  s.len

fun double_len(s: ?String) -> Int!
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
fun parse_len(s: ?String) -> Int!
  s.len

sub main()
  n = parse_len("abc")
```

```error
must be wrapped with `!` (propagate) or `catch` (handle)
```

A jump as the handler leaves instead of giving a value:

```rig
error E
  bad

fun parse(s: ?String) -> Int!
  return E.bad if s == "x"
  s.len

fun size(s: ?String) -> Int
  n = parse(s) catch return -1
  n * 10

sub main()
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
expression or a branch block's, is rejected
([CORE 10](docs/CORE.md#2-the-core-in-ten-sentences) shows it). The
failure leaves the function the way `!` does: every `defer` and
`errdefer` of the scopes it leaves runs. Only a function returning `T!`
can fail.

```rig
error Bad
  odd

fun half(n: Int) -> Int!
  return n / 2 if n % 2 == 0 else Bad.odd

sub main()
  print(half(4) catch -1, half(3) catch -1)
```

```output
2 -1
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

sub main()
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
not declare which errors they fail with, so `err` may be any error: its
type is `error` ([Any error](#any-error)). It is compared with
error-set members (`err == E.name`), matched by them (`E.name =>`,
with a `_` arm, since no arms name every error), printed, and returned
from a fallible function. It is the handler's own: `<err` or `return
err` moves it on, and `+err` clones it. The handler may be a block.

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

fun parse_len(s: ?String) -> Int!
  return ParseError.empty if s == ""
  return ParseError.too_long if s.len > 5
  s.len

fun describe(s: ?String) -> ?String
  n = parse_len(s) catch |err|
    match err
      .empty => return "empty"
      _ => return "too long"
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

fun describe(n: Int) -> ?String
  _ = fetch(n) catch |err|
    match err
      Net.timeout => return "network timeout"
      Disk.timeout => return "disk timeout"
      .refused => return "refused"
      _ => return "other"
  "ok"

sub main()
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

sub main()
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

### Any error

> **Core §2:** A failure moves its error.

The type `error` holds an error of any set, wherever a type goes: a
parameter, a field, a result, an optional, a List's element. A member of
any set is accepted where an `error` is expected. `error` is owning in
every program ([kinds](#kinds-of-value)): a bare use where its value is
taken is rejected, `<e` moves it, `+e` clones it, and `?e` lends it. It
is compared, matched, and printed as `err` is above, and a fallible
function fails with it by `return e`. `error!` is rejected, as `E!` is.

```rig
error Net
  timeout

error Disk
  full

fun fetch(n: Int) -> Int!
  return Net.timeout if n == 1
  return Disk.full if n == 2
  n

sub main()
  seen: List[error] = List()
  for n in [1, 2, 3]
    v = fetch(n) catch |e|
      !seen.push(<e)
      0
    print(v)
  for e in seen
    print(e)
```

```output
0
0
3
Net.timeout
Disk.full
```

```rig reject
error E
  bad

fun f() -> Int!
  return E.bad

sub main()
  n = f() catch |err|
    a = err
    print(a)
    0
  print(n)
```

```error
`err` owns an `error`, which can't be copied by `=`: write `<err` to move it, `+err` to clone it, or `?err` to view it
```

### Declared sets and fields

These are decided and not built yet ([CORE §2](docs/CORE.md#2-the-core-in-ten-sentences),
"A failure moves its error"). A function may declare the set it fails
with, `-> T!E` or `sub f()!E`, and `T!` stays any error. Sets combine by
a named union, `error L = A | B`. `catch |err|` gives `err` the type of
the callee's set, a `match` on a set needs no `_`, and a `g: E =>` arm
narrows an `error` to a set. A member may carry fields, as an enum's
variant does, which are never views and always clone; the error moves
up through `!` and the handler owns it.

```rig pending
error GlobError
  bad_range
  star_star

fun error_text(err: GlobError) -> Static
  match err
    .bad_range => "bad range"
    .star_star => "star star"

fun parse(p: ?String) -> Int!GlobError
  return GlobError.star_star if p == "a**"
  return GlobError.bad_range if p == "["
  p.len

fun loose(p: ?String) -> Int!
  parse(p)!

sub main()
  for p in ["ab", "[", "a**"]
    n = parse(p) catch |e|
      print(error_text(e))
      0
    print(n)
  m = loose("[") catch |e|
    match e
      g: GlobError => print(error_text(g))
      _ => print("other")
    -1
  print(m)
```

```output
2
bad range
0
star star
0
bad range
-1
```

```rig pending
error Net
  timeout

error Disk
  full(path: String)

fun fetch(n: Int) -> Int!
  return Net.timeout if n == 1
  return Disk.full(path: String("/tmp")) if n == 2
  n

sub main()
  seen: List[error] = List()
  for n in [1, 2, 3]
    v = fetch(n) catch |e|
      !seen.push(<e)
      0
    print(v)
  for e in seen
    print(e)
```

```output
0
0
3
Net.timeout
Disk.full(path: "/tmp")
```

```rig pending
error IoError
  closed

error ParseError
  bad(pos: Int)

error LoadError = IoError | ParseError

fun read(n: Int) -> Int!IoError
  return IoError.closed if n < 0
  n

fun parse(n: Int) -> Int!ParseError
  return ParseError.bad(n) if n > 9
  n

fun load(n: Int) -> Int!LoadError
  parse(read(n)!)!

sub main()
  for n in [3, -1, 12]
    v = load(n) catch |e|
      match e
        IoError.closed => -1
        ParseError.bad(pos) => -100 - pos
    print(v)
```

```output
3
-1
-112
```

```rig pending
error A
  x

fun loose() -> Int!
  1

fun narrow() -> Int!A
  loose()!
```

```error
`loose` may fail with any error, and `narrow` declares `Int!A`: catch it, or declare `-> Int!`
```

```rig pending
error A
  x

error B
  y

fun f() -> Int!A
  return B.y
```

```error
`B.y` is not in `A`, the error set `f` declares
```

```rig pending
error P
  bad(text: ?String)
```

```error
an error's field is never a view: hold a `String` or a `Static`
```

```rig pending
obj Random unique
  seed: Int

error U
  bad(r: Random)
```

```error
an error's fields must clone, and `Random` is unique
```

```rig pending
error A
  x

error L = A
  extra
```

```error
a union of error sets lists no members of its own; declare a set for `extra` and join it
```

```rig pending
error E
  bad(msg: String)

fun f() -> Int!E
  return E.bad(msg: String("x"))

sub main()
  n = f() catch |err|
    keep = <err
    print(err)
    0
  print(n)
```

```error
use of `err` after move
```

---

## 14. Modules

A module is a file or a directory, named by its path from the directory
of the program's root file, whichever module says it: `use name`
imports `name.rig` or the directory `name/` (a program may not have
both), and `use a.b.c` the directory `a/b/c/`. The import binds the
path's last name, so `use a.b.c` names the module `c`. Each name of the
path is spelled as on disk, case included, and names starting with
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
pub obj Point
  pub x: Int
  pub y: Int

  pub fun at(x: Int, y: Int) -> Point
    Point(x: x, y: y)

  pub fun sum(?self) -> Int
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

sub main()
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

sub main()
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
way it reaches the member: through a view, a `*T` handle, a `^T`, or
an instance of a generic type. Another module constructs an object with
its fields given only when every one of its fields is `pub`; a type with
a private field is made by its own module, which can hand it out
through a `pub` function. `T()`, with no fields given, makes an object
whose every field has a default, from any module, private fields
included, since it sets only the values the type itself chose; it is a
field's default too ([§3](#objects)), as `List()` is, and works for a
generic object (`boxes.Stack[Int]()`). An enum's variants and their
payload fields are always public, since they are the type's shape; its
methods follow the rule above. A `drop` body is not called by name, so
it takes no `pub`.

A field declared `pub ?name: T` (also `pub ?name: T = v`) is public to
read and private to write: any module reads it, lends it to read, and
walks it, and only its own module writes it. Another module that
assigns it or a part of it, lends it to write (a `!` lend, a call of a
method that writes it, `swap`, `replace`, a `for` or header that writes
it), or takes it out with `<`, is rejected, through a view, a `^T`, or
an instance alike. The `?` is the read sigil: other modules get a read
view. It needs `pub`, since a private field is read by no other module,
and it is not an optional type: `pub ?len: Int` is a read-only `Int`,
and `pub len: Int?` an optional one anyone writes. Read-only stops at a
shared handle: with `pub ?h: *Cell[Int]`, another module cannot point
`h` at another Cell, but `!t.h.set(5)` changes the shared Cell, since a
handle is only read and a Cell changes by a marked call.

```rig file=bank.rig
pub obj Account
  pub owner: ?String
  balance: Int

  pub fun total(?self) -> Int
    self.balance

  sub audit(?self)
    print("audit", self.balance)

pub fun open(owner: ?String) -> Account
  Account(owner: owner, balance: 100)
```

```rig
use bank

sub main()
  a = bank.open("ada")
  print(a.owner, a.total())
```

```output
ada 100
```

Here `audit` and `balance` are private to `bank`:

```rig file=bank.rig
pub obj Account
  pub owner: ?String
  balance: Int

  pub fun total(?self) -> Int
    self.balance

  sub audit(?self)
    print("audit", self.balance)
```

```rig reject
use bank

sub main()
  a = bank.Account(owner: "bo", balance: 5)
  a.audit()
  print(a.balance, a.total())
```

```error
method `audit` of `bank.Account` is private to module `bank`; declare it `pub sub audit` there to call it from here
only module `bank` can construct `bank.Account`: its field `balance` is private
field `balance` of `bank.Account` is private to module `bank`; declare it `pub balance: ...` there to use it from here
```

```rig file=tally.rig
pub obj Tally
  pub ?count: Int = 0
  marks: List[Int] = List()

  pub sub add(!self, n: Int)
    !self.marks.push(n)
    self.count += 1
```

```rig
use tally

obj Report
  votes: tally.Tally = tally.Tally()

sub main()
  r = Report()
  !r.votes.add(7)
  !r.votes.add(9)
  print(r.votes.count)
```

```output
2
```

```rig file=tally.rig
pub obj Tally
  pub ?count: Int = 0
  marks: List[Int] = List()
```

```rig reject
use tally

sub main()
  t = tally.Tally()
  t.count = 5
```

```error
cannot assign to `t.count`: field `count` of `tally.Tally` is read-only outside module `tally`, which declares it `pub ?count`
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
pub obj Wrap[T]
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

sub main()
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

sub main()
  print(stats.mean(4, 6), stats.mean("a", "b"))
```

```error
`stats.mean[Static]` cannot use `T = Static`: the generic body applies `+` to `T`, which `Static` does not support
`+` used on `T` here (arithmetic)
```

Every check (types, arity, keyword
arguments, lend modes, fallibility, ownership) applies across modules
exactly as within one, and a type is identified by the module that
declares it: `a.Point` and `b.Point` are different types. A module
whose import has errors is not checked; the import's errors are
reported.

### Directory modules

A directory is a module made of its `.rig` files, as a Go package is.
Its files share one namespace: a declaration of any file, private or
`pub`, is visible in every other, a constant may name a constant of
any file, and a method may be declared outside its type's body
([§3](#methods-outside-the-body)) in any file of the type's module.
Every `.rig` file in a subdirectory belongs to that directory's
module, so a module beneath another is a directory of its own:
`checker/binder.rig` is part of module `checker`, and
`checker/binder/` is the module `checker.binder`. Each file closes its
own blocks and brackets, and a diagnostic names the file it is in.

Files that call each other belong in one module: modules may not
import each other in a cycle, so mutual recursion across files lives
inside a directory. A `use` binds its name in its own file only, and
each file uses the modules it names. Two files may bind one name to
different modules, and a name another file binds is free in this one,
for a parameter or a local. In the file that binds it, the name is
taken: a parameter of that name needs the module imported under
another (`use ast as a`), and a local can also hide the module for the
rest of its scope with `new ast = ...`.

```rig file=checker/expr.rig
pub obj Checker
  pub depth: Int

  pub fun expr(?self, n: Int) -> Int
    0 if n == 0 else self.stmt(n - 1)
```

```rig file=checker/stmt.rig
use checker.binder

pub fun Checker.stmt(?self, n: Int) -> Int
  binder.bump(self.expr(n))
```

```rig file=checker/binder/bump.rig
pub fun bump(n: Int) -> Int
  n + 1
```

```rig
use checker

sub main()
  print(checker.Checker(depth: 0).expr(3))
```

```output
3
```

```rig file=m/a.rig
use std.math

pub fun a() -> Int
  math.abs(-1)
```

```rig file=m/b.rig
pub fun b() -> Int
  math.abs(-2)
```

```rig reject
use m

sub main()
  print(m.a() + m.b())
```

```error
`math` is imported by another file of module `m`; add `use std.math` to this file
```

A file whose name ends in `_test.rig` belongs to its directory's module
only when that module is the root of `rig test X` (`X` is the directory),
so its tests see the module's private names. `rig run`, `rig check`, and
a `use` of the module leave it out, and `rig check --tests X` checks the
module with it.

---

## 15. Raw code and FFI

A `raw` block is the boundary of what the checker guarantees. Inside
it, and only there, a program may:

- call one of Zig's builtins (`@intCast`, `@bitCast`, ...;
  [§5](#builtins));
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
functions; `extern name: T` declares C data, which is an integer, a
float, or a `Bool`. Only integers, floats, and `Bool` cross the C boundary, and a C function
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

C links a name only as it is spelled, so a C declaration cannot take a
name the Zig that Rig writes uses itself: `std`, `rig`, `panic`,
`main`, a name starting with `__rig`, or a name Zig's standard library
looks for in a program (`debug`, `os`, `std_options`, `_start`, and
the like). A name Zig reserves (`var`, `fn`, `u8`) links as spelled.

```rig reject
extern fun panic(code: Int) -> Int

sub main()
  print(1)
```

```error
a C declaration cannot be named `panic`
```

### Zig-backed declarations

The standard library binds declarations to Zig code: a `fun` or `sub`
without a body inside `extern zig "file.zig"` is the function of the
same name in that Zig file, which ships with the library. A call to one
is checked exactly as a call to a Rig function with that signature
(moves, lends, and the loans its result carries) and needs no `raw`:
the Zig file is trusted as the runtime is, and each function's Zig type
is checked, when the program is compiled, to be the one its Rig
signature lowers to. Such a function takes no compile-time parameters.
A constant `name: T` inside the block, of type `Bool`, an integer, or a
built-in enum, is the Zig constant of that name, which Zig sets for the
target it compiles for: Rig knows its type and never its value
([The target](#the-target)).
Its signature is trusted where the checker cannot see a body: one that
returns a view and takes no view parameter, as
`std.os.args() -> []?String` does, returns something that lives as long
as the program.

A Zig-backed function may fail, returning `T!` or declared
`sub name(...)!`, when its module declares error sets
([§3](#error-sets)): it fails only with their errors, since its Zig
function's type must name the errors it returns, each one of those
sets' members. Its failures are errors like any other
([§13](#13-errors)), named through the module:

```rig
use std.text

sub main()
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

sub main()
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
`List`, `Self`, ...), a module-level declaration, another parameter, or,
on a generic type, a method of the type; no local or parameter inside
the declaration may reuse it, and the same holds for a generic type's
value parameters. A compile-time value's type is a number, `Bool`,
`?String`, an enum whose variants carry nothing, or an optional of one
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
parameter, a `=!` binding of one of these, or a comparison or `and`,
`or`, `not` of them. Arithmetic in a compile-time argument must fold to
a constant (`LIMIT * 2`), which is checked like constant arithmetic;
arithmetic on a compile-time parameter (`n + 1`), directly or through a
`=!` binding, is rejected, since each instance would compute it
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

sub show[n: Int]()
  print(n * 2)

sub tag[T, loud: Bool](x: T)
  print(x, loud)

sub main()
  print(check[.strict](5), check[.loose](5), either[.strict](3, 12))
  show[4]()
  show[LIMIT * 2]()
  tag[?String, LIMIT > 3]("x")
```

```output
false true true
8
20
x true
```

```rig reject
sub show[n: Int]()
  print(n)

sub outer[n: Int]()
  show[n + 1]()

sub main()
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
| `?String`, `String` | its text; inside other values, quoted |
| `none` | `none` |
| enum | `.green`, `.circle(r: 2.5)`, `.rect(w: 2, h: 3)`: payload fields by name, however it was built |
| error | `Disk.timeout`: its set and its name, without the module |
| object | `User(name: "ada", age: 36)` |
| array, slice, `List` | `[1, 2]` |
| shared handle | the value it holds |
| `^T` | the value it holds |
| `Cell`, `Signal` | `Cell(value: 5)`, `Signal(value: 5)` |
| weak handle | `~(alive)` or `~(gone)` |
| owned closure | `<closure>` |
| function | `<fun>` |

A value nested more than 64 levels deep prints its deeper parts as
`...`. A temporary printed, `print(String("n=", n))` or `print(make())`,
is dropped when the statement ends ([§7](#temporaries)). A `[]U8` and a `?String` are the same bytes at run time, so
`print` rejects a value that holds a `[]U8`; print its bytes one by one.

```rig
obj User
  name: ?String
  age: Int

enum Shape
  dot
  circle(r: Float)
  rect(w: Int, h: Int)

sub main()
  u = User(name: "ada", age: 36)
  n: Int? = none
  print(u, n, ["a", "b"], 2.5, 2.0)
  print(Shape.dot, Shape.circle(2.5), Shape.rect(w: 2, h: 3))
  h = *User(name: "bob", age: 1)
  w = ~h
  b = ^User(name: "cy", age: 2)
  print(h, w, b, *Cell(5))
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
| `const x = e`, `new const x = e` | `` Rig has no `const`; write `x =! e` for a binding that never changes `` |
| `x =!y` | `` `=!` needs a space after it: write `x =! y` for a fixed binding, or `x = !y` to lend `y` to write `` |
| `when`, `yield`, ... as a name | `` unexpected keyword `when` `` (every other word held for later: `async` `await` `impl` `trait` `when` `where` `yield`) |
| string and float match patterns | `` a pattern is a name, an integer, `true`, `false`, or an enum variant `` |

The rest parse, and the checker rejects them as not supported yet
([roadmap](docs/ROADMAP.md)):

| Form | Diagnostic |
|---|---|
| `drop` on an enum or a generic object | `` `drop` bodies are only for non-generic objects `` |
| a stack closure stored or returned | `` closures cannot escape their defining scope `` |
| `/`, `%`, or a shift of a vector; a vector's lanes summed, converted, or shuffled | `` operator `/` does not take a `Simd` ``, `` type `Simd[U8, 16]` has no method `sum` `` |
| a module constant holding a vector | `` a module-level constant needs a value known at compile time `` |
| two write views among a function's results | `` at most one of a function's results is a write view `` |
| a field or element bound by several results, `i, xs[i] = f()` | `` each result is bound to a name `` |
| named results, `-> (q: Int, r: Int)` | `` results are not named `` |
| `for` over an iterator whose `next` gives several results | `` a `for` binds one value each step `` |

```rig reject
sub main()
  zig "return;"
```

```error
unexpected keyword `zig`
inline Zig is reserved
```
