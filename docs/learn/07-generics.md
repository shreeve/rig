# Write it once, for every type

Every programmer has written this function: the largest item of a list.
The trouble starts when the list holds a second type. C copies the
function per type, or hides it in a macro. Go once took `interface{}`
and checked the type at run time. C++ templates accept anything and
answer a mistake with a page of errors from inside the library. Rust
asks you to name, up front, everything the body does:

```rust
fn largest<T: PartialOrd + Copy>(xs: &[T]) -> Option<T> {
    let mut best = *xs.first()?;
    for &x in xs {
        if x > best { best = x; }
    }
    Some(best)
}
```

Rust's signature must be right before anything compiles. Rig lets you
start without one: a generic body is checked against every type the
program uses it with. When you want the signature to state the
contract, a bound says it in the same brackets.

## One body for many types

A name in brackets after a function's name is a type parameter:

```rig
fun largest[T](xs: []T) -> T?
  return none if xs.len == 0
  best = xs[0]
  for x in xs
    best = x if x > best else best
  best

sub main()
  print(largest([3, 9, 4]), largest([2.5, 0.5]), largest(["fig", "pear", "apple"]))
  empty: [0]Int = []
  print(largest(empty))
  print(largest[Float]([1, 2]))
```

```output
9 2.5 pear
none
2.0
```

`[T]` makes `largest` generic: `T` stands for any type, and `[]T` is
a slice of them. Brackets after a name hold what is known when
compiling, and parentheses what is known when running. The return type
`T?` covers the empty list, as journey 03 showed.

Each call infers `T` from its arguments: `Int`, then `Float`, then text.
`largest[Float]([1, 2])` names the type instead, so the literals become
floats. Naming it is for when nothing else settles it.

## What the compiler makes

A generic function costs nothing at run time. `rig emit` shows the Zig
the program above becomes, cut to the lines that matter:

```zig
pub fn largest(comptime T: type, xs: []const T) rig.Opt(T) {
    ...
}

    rig.print(.{ largest(i64, &[_]i64{ 3, 9, 4 }), " ", largest(f64, &[_]f64{ @as(f64, 2.5), @as(f64, 0.5) }), "\n" });
```

The body is written once, with `T` as a compile-time parameter, and Zig
makes one instance per type: one `largest` for `i64` and one for
`f64`. Each is as fast as the function written out by hand for its
type, with nothing boxed. The price is code size: each type a program
uses gets its own copy.

## Values known when compiling

A type can take a number as well as a type. Here is a buffer of the
last few readings, its size fixed when compiling:

```rig
obj Recent[T, n: Int]
  items: [n]T
  count: Int = 0

  sub add(!@, x: T)
    @items[@count % n] = x
    @count += 1

  fun full(?@) -> Bool
    @count >= n

fun sum[n: Int](xs: [n]Int) -> Int
  total = 0
  for x in xs
    total += x
  total

sub main()
  r = Recent[Int, 3](items: [3 of 0])
  for t in [21, 23, 22, 25]
    !r.add(t)
  print(r.items, r.full(), sum(r.items))
  w = Recent(items: [2 of 0.0])
  !w.add(1.5)
  print(w.items, w.full(), $size(Recent[Int, 3]), $size(Recent[Int, 64]))
```

```output
[25, 23, 22] true 70
[1.5, 0.0] false 32 520
```

`n: Int` is a value parameter. It sizes the array `[n]T` and reads as
a number in the methods, `@count % n`. A type parameter starts with a
capital letter and a value parameter with a lowercase one, so the two
read apart.

`Recent[Int, 3]` names both arguments. `Recent(items: [2 of 0.0])`
infers both from the array it is given: a `Recent[Float, 2]`. `sum`
infers its `n` from the array's length. `$size` shows the array stored
inline: three `Int`s and a count are 32 bytes, and 64 of them are 520.
No allocation is hidden in a `Recent`.

The number is part of the type, so `Recent[Int, 3]` and
`Recent[Int, 4]` are two types, and one is never assigned to the
other.

## Functions the compiler runs

Brackets mean compile time, so a function written with brackets alone,
and no parentheses, runs while the program compiles. Its value is a
constant wherever it is used, a type included:

```rig
obj Recent[T, n: Int]
  items: [n]T

fun slots[n: Int] -> Int
  if n < 1
    panic("need at least one slot")
  size = 1
  while size < n
    size *= 2
  size

fun squares[n: Int] -> [n]Int
  t = [n of 0]
  for i in 0..n
    t[i] = i * i
  t

SQUARES = squares[8]

sub main()
  r = Recent[Int, slots[3]](items: [4 of 0])
  print(slots[3], slots[100], SQUARES[7], r.items.len)
```

```output
4 128 49 4
```

`slots[3]` is 4 before the program runs: the compiled program holds the
number, not the loop, and `squares[8]` becomes a table of eight numbers.
A compile-time function takes integers, `Bool`, and plain enums, and
gives one of those or a fixed array of them. Its body may bind locals,
do arithmetic, branch, loop, fill arrays, and call compile-time
functions, itself included; it cannot print, allocate, or call a
function that runs when the program does.

A mistake in it is found when compiling, and reported where it was
asked:

```rig reject
fun slots[n: Int] -> Int
  if n < 1
    panic("need at least one slot")
  n

EMPTY = slots[0]

sub main()
  print(EMPTY)
```

```error
compile-time call `slots[0]` panics: need at least one slot
```

Overflow, an index out of range, and a loop that never ends are found
the same way: the compiler stops after ten million steps and says so.

## What a body may do with a `T`

`largest` compares with `>` and copies with `best = x`. Neither works
for every type. Rig does not ask the signature to list them. It records
what the body does with a `T`, then checks each type the program uses:

```rig reject
obj Point
  x: Int
  y: Int

fun largest[T](xs: []T) -> T?
  return none if xs.len == 0
  best = xs[0]
  for x in xs
    best = x if x > best else best
  best

sub main()
  print(largest([Point(x: 1, y: 2), Point(x: 2, y: 1)]))
```

```error
`largest[Point]` cannot use `T = Point`: the generic body applies `>` to `T`, which `Point` does not support
```

The error is at the call, on the line you wrote, and it names the
instance, `largest[Point]`. A note under it points at the body line
that needs the operation, `x > best`. A `Point` has no order, so the
call is wrong, not the function.

Copying is checked the same way. A `String` owns its bytes, and a
copy would leave two owners of one allocation:

```rig reject
fun largest[T](xs: []T) -> T?
  return none if xs.len == 0
  best = xs[0]
  for x in xs
    best = x if x > best else best
  best

sub main()
  names: List[String] = List()
  !names.push(String("fig"))
  print(largest(?names[..]))
```

```error
`largest[String]` cannot use `T = String`: the generic body copies a `T`, which would duplicate the resource `String` owns
```

Ownership is checked once, in the body, as if `T` owned a resource. So
moves, drops, and lends are right for every instance. A body that
copies a `T` works only with types that copy, and the error says which
line copies.

This is the model of Zig's `comptime`, but the error is a Rig
diagnostic at the call, never one from inside the generated code.

## Calling a `T`'s methods

A generic body may call a method on a `T`. Each instance's type must
have it:

```rig
obj Square
  side: Float

  fun area(?@) -> Float
    @side * @side

obj Circle
  r: Float

  fun area(?@) -> Float
    3.14159 * @r * @r

fun total_area[T](shapes: []T) -> Float
  t = 0.0
  for s in shapes
    t += s.area()
  t

sub main()
  print(total_area([Square(side: 2.0), Square(side: 3.0)]), total_area([Circle(r: 1.0)]))
```

```output
13.0 3.14159
```

`s.area()` calls whatever `area` the instance's type declares.
`Square` and `Circle` share no declaration. Each merely has an `area`
that reads self and gives a `Float`. The call is a direct call in each
instance, as if written by hand.

The body is checked once, before any instance exists. So the call's
result takes its type from where the call stands. In `t += s.area()`,
`t` is a `Float`, so `area` must give one. A typed binding, an
argument, or the other operand of `>` would say the same. Where nothing
says, the body cannot know:

```rig reject
obj Square
  side: Float

  fun area(?@) -> Float
    @side * @side

sub show[T](s: ?T)
  print(s.area())

sub main()
  sq = Square(side: 2.0)
  show(?sq)
```

```error
`s.area()` calls a method on a `T`, whose result type the body cannot know; give it one: `a: Float = s.area()`, then `print(a)`
```

A type without the method is rejected at the call that makes the
instance, as `Point` was. The call's sigil says how it takes self, as
at any call: `s.area()` reads, `!s.grow()` writes, `<s.close()`
consumes. A type whose method takes self another way is rejected at
the call too.

## Saying what `T` must do

Checking each instance needs no signature, but it leaves the reader of
`largest` guessing what a `T` must support. A **bound** says it, after
a colon in the brackets:

```rig
fun largest[T: Ord + Copy](xs: []T) -> T?
  return none if xs.len == 0
  best = xs[0]
  for x in xs
    best = x if x > best else best
  best

obj Version: Ord
  major: Int
  minor: Int

enum Size: Ord
  small
  medium
  large

sub main()
  print(largest([3, 9, 4]), largest(["fig", "pear"]))
  v = largest([Version(major: 1, minor: 9), Version(major: 1, minor: 10)]) ?? return
  print(v.major, v.minor, largest([Size.medium, Size.large, Size.small]))
```

```output
9 pear
1 10 .large
```

`T: Ord + Copy` reads "any `T` that can be ordered and copied". `Ord`
and `Copy` are two of the built-in APIs, the named sets of
capabilities a type provides. `+` joins them.

Numbers and text are ordered already. An object or an enum is ordered
only when its header names `Ord`: `obj Version: Ord` orders by its
fields in the order they are declared, so `1.10` is above `1.9`.
`enum Size: Ord` orders by its variants. A `Point` that does not name
`Ord` is now rejected by the bound, with the fix:

```rig reject
obj Point
  x: Int
  y: Int

fun largest[T: Ord + Copy](xs: []T) -> T?
  return none if xs.len == 0
  best = xs[0]
  for x in xs
    best = x if x > best else best
  best

sub main()
  print(largest([Point(x: 1, y: 2)]))
```

```error
`largest[Point]` cannot use `T = Point`: `Point` cannot be ordered; name `Ord` on its header: `obj Point: Ord`
```

The bound also limits the body. A bounded `T` is checked against its
bounds alone, so the body may do what they name and nothing more. Drop
`Copy`, and `best = xs[0]` is an error in the function, not at a call:

```rig reject
fun largest[T: Ord](xs: []T) -> T?
  return none if xs.len == 0
  best = xs[0]
  for x in xs
    best = x if x > best else best
  best

sub main()
  print(largest([1, 2]))
```

```error
`T` is bounded by `Ord`, which does not give a copy; add `Copy` to its bounds: `[T: Copy + Ord]`
```

`Copy`, `Clone`, `Owned`, `Sends`, and `Syncs` are facts of a type's
parts, which no type declares. `Eq`, `Hash`, `Ord`, and `Print` are
capabilities a type may give its own meaning, and `Num` is arithmetic.
Bounds are optional: a parameter with none keeps the per-instance
check. A bound may also be an API a program declares itself, the
subject of the next journey.

## A failure as a parameter

A helper that runs a function it is given fails however that function
fails. Its error set is a parameter, `E`, written after `!`:

```rig
use std.text

error Config
  missing
  not_a_number

fun value_of(line: ?String) -> Int!Config
  c = text.cut(line, "=") ?? return Config.missing
  text.parse_int(text.trim(c.after)) catch return Config.not_a_number

fun width(line: ?String) -> Int!
  return Config.missing if line.len == 0
  line.len

fun sum[E](lines: []?String, f: ?fun(?String) -> Int!E) -> Int!E
  n = 0
  for line in lines
    n += f(line)!
  n

sub main()
  for lines in [["a = 1", "b = 2"], ["a = 1", "b"]]
    v = sum(lines, value_of) catch |e|
      match e
        .missing => -1
        .not_a_number => -2
    print(v)
  print(sum(["ab", "cde"], width) catch -1)
```

```output
3
-1
5
```

`f: ?fun(?String) -> Int!E` is a view of a function that fails with
the set `E`. `sum(lines, value_of)` binds `E` to `Config`, so its
`match` names both members and needs no `_`, as journey 03 showed for a
declared set. `sum(..., width)` binds `E` to `error`, any error. In the
body, `!` passes on only `E`.

## Folding with `reduce`

Many generic loops walk a list and carry one value along. `reduce`
writes that loop: `xs.reduce(start, f)` passes the running value,
`start` first, and each element to `f`, and keeps what `f` gives:

```rig
obj Square
  side: Float

  fun area(?@) -> Float
    @side * @side

obj Circle
  r: Float

  fun area(?@) -> Float
    3.14159 * @r * @r

fun total_area[T](shapes: []T) -> Float
  shapes.reduce(0.0, |sum, s| sum + s.area())

fun largest[T: Ord + Copy](xs: []T, first: T) -> T
  xs.reduce(first, |best, x| x if x > best else best)

sub main()
  print(total_area([Square(side: 2.0), Square(side: 3.0)]), total_area([Circle(r: 1.0)]))
  print(largest([3, 9, 4], 0), largest(["fig", "pear", "apple"], ""))
  words = ["generic", "once", "many"]
  print(words.reduce(0, |n, w| n + w.len))
```

```output
13.0 3.14159
9 pear
15
```

`total_area` is the loop from before, in one line. Each element is
lent to the closure as a read view, so `reduce` never copies one, and
`s.area()` reaches each instance's own method. `largest` is this
chapter's first function, in one line too: `x` is a `?T`, and the bound
`Copy` lets the closure hand back a `T` copied out of it. `reduce` works
on a slice, an array, or a `List`, and an empty one gives `start`.

The running value moves through each call, so it may own what it
holds, such as a `String` built up a piece at a time. A closure written
at the call is inlined in a release build, so the loop costs what the
loop written out costs.

When the closure can fail, so can `reduce`, and its call says what
happens to the failure:

```rig
use std.text

fun total(lines: []?String) -> Int!
  lines.reduce(0, |sum, l| sum + text.parse_int(l)!)!

sub main()
  print(total(["1", "2", "3"])!)
  print(total(["1", "x", "3"]) catch -1)
```

```output
6
-1
```

The first failure ends the fold, and `!` after `reduce` passes it up.

## The whole idea, on one table

| You write | It means |
|---|---|
| `fun largest[T](xs: []T)` | one body; each type it meets is checked against what the body does |
| `largest[Float](...)` | the type named; otherwise it is inferred from the arguments |
| `obj Recent[T, n: Int]` | a value known when compiling, part of the type |
| `fun slots[n: Int] -> Int`, `slots[3]` | a function the compiler runs; its value is a constant |
| `s.area()` on a `T` | the instance's own method, a direct call, typed where it stands |
| `[T: Ord + Copy]` | a bound: the body may use only that, and each call must provide it |
| `fun sum[E](f: ?fun() -> Int!E) -> Int!E` | an error set as a parameter |
| `xs.reduce(start, f)` | a fold over a slice, an array, or a List, inlined in a release build |

**A generic body is written once and checked against every type it
meets; a bound moves that check into the signature.**

## What is not there yet

A value parameter of a generic type or function is an integer, and a
compile-time function cannot yet be called with one: `[slots[n]]T`
inside a generic body, text parameters, and objects are on the
[roadmap](../ROADMAP.md).

## Where to go next

- [Many types, one contract](08-apis.md) is the next journey: APIs of
  a program's own, and values of many types in one list.
- [SPEC, Generic types](../../SPEC.md#generic-types),
  [Generic functions](../../SPEC.md#generic-functions), and
  [Generic bodies](../../SPEC.md#generic-bodies) state the rules for
  instances and inference, [Bounds](../../SPEC.md#bounds) every
  built-in API, and [Generic sets](../../SPEC.md#generic-sets) a set
  as a parameter.
- [DESIGN, Per-instance checking](../DESIGN.md#per-instance-checking-instead-of-traits)
  gives the reasons for checking each instance.
- [STD, reduce](../STD.md#reduce) and `std.sort` show the generic
  functions the standard library offers.
