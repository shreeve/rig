# The Rig standard library

The standard library ships with the compiler. A program imports one of
its modules with `use std.NAME`, which names it `NAME`
([SPEC §14](../SPEC.md#14-modules)):

```rig
use std.math

sub main
  print(math.gcd(12, 18))
```

```output
6
```

Its modules are Rig code, under `std/` in the repository, checked like
any other module. What Rig cannot do itself, a module declares in an
`extern zig` block: functions with full Rig signatures, implemented by
a small Zig file beside the module on Zig's standard library
([SPEC §15](../SPEC.md#zig-backed-declarations)). A call to one is
checked like any call. The standard library is new: this page lists
everything it has.

| Module | What it offers |
|---|---|
| [`std.math`](#stdmath) | integer helpers, and Float functions |
| [`std.os`](#stdos) | the program's arguments and environment |
| [`std.time`](#stdtime) | clocks and sleeping |
| [`std.random`](#stdrandom) | a seedable pseudorandom generator |
| [`std.sort`](#stdsort) | sorting and searching slices |

## std.math

Integer helpers, written in Rig. Like the operators, they panic on
overflow.

| Function | Result |
|---|---|
| `abs(n: Int) -> Int` | `n` without its sign; panics on `Int.min` |
| `clamp(x: Int, lo: Int, hi: Int) -> Int` | `lo` when `x < lo`, `hi` when `x > hi`, else `x` |
| `gcd(a: Int, b: Int) -> Int` | the greatest common divisor, never negative; `gcd(0, 0)` is 0 |
| `pow(base: Int, exp: Int) -> Int` | `base` to the power `exp`; a negative `exp` gives 1 divided by `base` to the power `-exp`, truncated as `/` truncates |
| `mod(a: Int, b: Int) -> Int` | the floored remainder, with the sign of `b`; panics when `b` is 0 |
| `PI`, `E` | the Float constants |

```rig
use std.math

sub main
  print(math.abs(-7), math.clamp(15, 0, 10), math.clamp(-3, 0, 10))
  print(math.gcd(-12, 18), math.gcd(0, 0))
  print(math.pow(3, 4), math.pow(2, -1), math.pow(-1, -3))
  print(-7 % 3, math.mod(-7, 3), math.mod(7, -3))
  print(math.PI > 3.14, math.E < 2.72)
```

```output
7 10 0
6 0
81 0 -1
-1 2 -2
true true
```

Float functions, from Zig's. They follow IEEE 754: a result out of
range is an infinity, and an undefined one (the square root of a
negative number) is NaN, which equals nothing, itself included.

| Function | Result |
|---|---|
| `sqrt(x: Float) -> Float` | the square root |
| `floor(x: Float) -> Float` | the largest whole number not above `x` |
| `ceil(x: Float) -> Float` | the smallest whole number not below `x` |
| `exp(x: Float) -> Float` | e to the power `x` |
| `ln(x: Float) -> Float` | the natural logarithm |
| `sin(x: Float) -> Float`, `cos(x: Float) -> Float` | the sine and cosine of `x` radians |
| `pow_f(x: Float, y: Float) -> Float` | `x` to the power `y` |

```rig
use std.math

sub main
  print(math.sqrt(2.0) > 1.414, math.floor(-2.5), math.ceil(-2.5))
  print(math.exp(0.0), math.ln(math.E))
  print(math.cos(math.PI), math.pow_f(2.0, 0.5) == math.sqrt(2.0))
  print(Int(math.floor(7.9)))
```

```output
true -3.0 -2.0
1.0 1.0
-1.0 true
7
```

## std.os

The arguments and environment the program started with. Their Strings
live as long as the program, as a literal's do, so they can be kept,
returned, and stored anywhere.

| Function | Result |
|---|---|
| `args() -> []String` | every argument, the program's name first |
| `env(name: String) -> String?` | the value of the environment variable `name`, or `none` when it is not set |

`rig run file.rig -- a b` passes `a` and `b` to the program, and a
built executable takes its arguments as usual. With `fun main -> Int`
([SPEC §1](../SPEC.md#1-programs)), a program also reports an exit
status:

```rig
use std.os

fun main -> Int
  args = os.args()
  if args.len < 2
    print("usage: greet NAME")
    return 0
  for name in args[1..]
    print("hello", name)
  0
```

```output
usage: greet NAME
```

```rig
use std.os

sub main
  home = os.env("RIG_EXAMPLE_UNSET") ?? "nowhere"
  print(home)
```

```output
nowhere
```

## std.time

Time as an `Int` of nanoseconds, with the constants `NS`, `US`, `MS`,
`SECOND`, and `MINUTE` to write durations: `250 * time.MS`.

| Function | Result |
|---|---|
| `now() -> Int` | the monotonic clock, in nanoseconds since an unspecified moment: it never goes back, so the difference of two readings is the time between them |
| `elapsed(start: Int) -> Int` | the nanoseconds since `start`, a reading of `now()` |
| `sleep(ns: Int)` | wait at least `ns` nanoseconds; not at all when `ns` is not positive |
| `unix() -> Int` | the wall clock, in nanoseconds since 1970-01-01 00:00 UTC; it can be set, so it may jump |

```rig
use std.time

sub main
  start = time.now()
  time.sleep(5 * time.MS)
  print(time.elapsed(start) >= 5 * time.MS)
  print(time.unix() / time.SECOND > 1_700_000_000)
```

```output
true
true
```

## std.random

`Rng` is a small, fast pseudorandom generator (splitmix64), written in
Rig. Its state is one `U64`, which its methods change, so they take
`!self`. An `Rng` moves (`a = <r`) and is never copied, since a copy
would draw the same numbers as the original; `fork` makes a second
generator on purpose. A seeded `Rng` gives the same sequence on every
platform. It is not for cryptography.

| Member | Result |
|---|---|
| `Rng.seeded(seed: U64) -> Rng` | a generator whose sequence `seed` fixes |
| `Rng.new() -> Rng` | a generator seeded from the operating system's entropy, different on each run |
| `!r.next() -> U64` | the next 64 random bits |
| `!r.fork() -> Rng` | a new generator, seeded from `r`'s next number |
| `!r.int(lo: Int, hi: Int) -> Int` | an `Int` from `lo` up to but not including `hi`, each equally likely, for any range up to `Int.min` to `Int.max`; panics unless `lo < hi` |
| `!r.float() -> Float` | a `Float` from 0 up to but not including 1 |
| `!r.shuffle(!xs)` | put the elements of the slice `xs` in a random order, each order equally likely |

```rig
use std.random

sub main
  r = random.Rng.seeded(2024)
  again = random.Rng.seeded(2024)
  print(!r.next() == !again.next())
  roll = !r.int(1, 7)
  print(roll >= 1 and roll <= 6, !r.float() < 1.0)
  deck = [1, 2, 3, 4, 5]
  !r.shuffle(!deck)
  total = 0
  for card in deck
    total += card
  print(total)
```

```output
true
true true
15
```

## std.sort

Sorting and searching, written in Rig over slices, so they work on
arrays (`!a`, `?a`) and on Vecs (`!v[..]`, `?v[..]`) alike. The
elements are plain data, as a slice's are. `sort` and `search` order
elements with `<` (numbers and Strings), and `contains` and `index_of`
compare them with `==`; each call is checked for its element type, as
any generic call is.

| Function | Result |
|---|---|
| `sort(xs: ![]T)` | sort `xs` in place, in the order of `<`, keeping equal elements in the order they had; allocates nothing |
| `sort_by(xs: ![]T, less: ?fun(?T, ?T) -> Bool)` | the same, in the order `less` gives: `less(a, b)` says whether `a` belongs before `b` |
| `reverse(xs: ![]T)` | reverse the order of `xs` in place |
| `search(xs: []T, x: T) -> Int?` | in `xs` sorted by `<`, the index of the first element equal to `x`, by binary search; `none` when there is none |
| `contains(xs: []T, x: T) -> Bool` | whether some element equals `x` |
| `index_of(xs: []T, x: T) -> Int?` | the index of the first element equal to `x`, or `none` |

`sort` sorts runs of 20 elements by insertion, then merges them in
place by rotations, so it takes O(n log² n) comparisons and no memory.

```rig
use std.sort

struct Player
  name: String
  score: Int

sub main
  scores = [30, 10, 20, 10]
  sort.sort(!scores)
  print(scores, sort.search(?scores, 20), sort.contains(?scores, 5))

  v: Vec[Player] = Vec()
  !v.push(Player(name: "ann", score: 7))
  !v.push(Player(name: "bob", score: 9))
  !v.push(Player(name: "cy", score: 7))
  sort.sort_by(!v[..], |a, b| a.score > b.score)
  for p in ?v
    print(p.name, p.score)

  names = ["cy", "ann", "bob"]
  sort.reverse(!names)
  print(names, sort.index_of(?names, "ann"))
```

```output
[10, 10, 20, 30] 2 false
bob 9
ann 7
cy 7
["bob", "ann", "cy"] 1
```

`sort` needs `<` on its elements:

```rig reject
use std.sort

struct Player
  name: String
  score: Int

sub main
  team = [Player(name: "ann", score: 7)]
  sort.sort(!team)
```

```error
`sort.sort[Player]` cannot use `T = Player`: the generic body applies `<` to `T`
```
