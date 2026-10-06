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

`RIG_STD=dir` makes `rig` read the standard library from `dir` in
place of the copy built into it. It is a setting for developing the
library, whose modules may bind Zig files; a program's own modules are
never read as the library's.

| Module | What it offers |
|---|---|
| [`std.math`](#stdmath) | number helpers, and Float functions |
| [`std.os`](#stdos) | the program's arguments and environment |
| [`std.time`](#stdtime) | clocks and sleeping |
| [`std.random`](#stdrandom) | a seedable pseudorandom generator |
| [`std.sort`](#stdsort) | sorting slices, and searching sorted ones |
| [`std.slices`](#stdslices) | reversing and linear search |
| [`std.text`](#stdtext) | searching, slicing, splitting, and parsing Strings |

## std.math

Number helpers, written in Rig. Like the operators, they panic on
overflow. `abs`, `min`, `max`, and `clamp` are generic: each call is
checked for its type, as any generic call is.

| Function | Result |
|---|---|
| `abs[T](x: T) -> T` | `x` without its sign, for a signed number type or `Float`; panics on a type's minimum integer (`Int.min`) |
| `min[T](a: T, b: T) -> T`, `max[T](a: T, b: T) -> T` | the smaller or larger of `a` and `b`, by `<`; `a` when they are equal |
| `clamp[T](x: T, lo: T, hi: T) -> T` | `lo` when `x < lo`, `hi` when `x > hi`, else `x`; panics when `hi < lo` |
| `gcd(a: Int, b: Int) -> Int` | the greatest common divisor, never negative; `gcd(0, 0)` is 0; panics when `a` or `b` is `Int.min` |
| `pow(base: Int, power: Int) -> Int` | `base` to the power `power`; a negative `power` gives 1 divided by `base` to the power `-power`, truncated as `/` truncates: 1 for `base` 1, 1 or -1 for `base` -1, and 0 for any other but 0, which panics as dividing by 0 does |
| `mod(a: Int, b: Int) -> Int` | the floored remainder, with the sign of `b`; panics when `b` is 0 |
| `PI`, `E` | the Float constants |

```rig
use std.math

sub main
  print(math.abs(-7), math.abs(-0.5), math.clamp(15, 0, 10), math.clamp(-3, 0, 10))
  print(math.min(4, 2), math.max(1.5, 2.5), math.min("pear", "fig"))
  print(math.gcd(-12, 18), math.gcd(0, 0))
  print(math.pow(3, 4), math.pow(2, -1), math.pow(-1, -3))
  print(-7 % 3, math.mod(-7, 3), math.mod(7, -3))
  print(math.PI > 3.14, math.E < 2.72)
```

```output
7 0.5 10 0
2 2.5 fig
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
| `powf(x: Float, y: Float) -> Float` | `x` to the power `y` |

```rig
use std.math

sub main
  print(math.sqrt(2.0) > 1.414, math.floor(-2.5), math.ceil(-2.5))
  print(math.exp(0.0), math.ln(math.E))
  print(math.cos(math.PI), math.powf(2.0, 0.5) == math.sqrt(2.0))
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
live as long as the program, as a literal's do, and view no `Text`.
They hold the bytes the operating system gave, which are not checked
to be UTF-8. `env` says so in its signature (`from static`,
[SPEC §7](../SPEC.md#second-class-views)), so its result views
nothing its caller lent: it can be kept, returned, and stored anywhere,
whatever `name` is.

| Function | Result |
|---|---|
| `args() -> []String` | every argument, the program's name first |
| `env(name: String) -> String? from static` | the value of the environment variable `name`, or `none` when it is not set |

`rig run file.rig -- a b` passes `a` and `b` to the program, and a
built executable takes its arguments as usual. The first argument is
the path the program was started by: under `rig run`, that of the
executable `rig` built in its cache. With `fun main -> Int`
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

The monotonic clock, the wall clock, and sleeping. A duration is an
`Int` of nanoseconds, with the constants `NS`, `US`, `MS`, `SECOND`,
and `MINUTE` to write one: `250 * time.MS`. A reading of the monotonic
clock is an `Instant`, which only gives the time between readings, so
it cannot be mixed up with the wall clock's nanoseconds.

| Member | Result |
|---|---|
| `now() -> Instant` | the monotonic clock now: it never goes back |
| `t.since(earlier: Instant) -> Int` | the nanoseconds from `earlier` to `t`; negative when `earlier` is the later one |
| `t.elapsed() -> Int` | the nanoseconds from `t` to now |
| `sleep(ns: Int)` | wait at least `ns` nanoseconds; not at all when `ns` is not positive |
| `unix_ns() -> Int` | the wall clock, in nanoseconds since 1970-01-01 00:00 UTC; it can be set, so it may jump |

```rig
use std.time

sub main
  start = time.now()
  time.sleep(5 * time.MS)
  print(start.elapsed() >= 5 * time.MS)
  print(time.now().since(start) > 0)
  print(time.unix_ns() / time.SECOND > 1_700_000_000)
```

```output
true
true
true
```

## std.random

`Random` is a small, fast pseudorandom generator (splitmix64), written in
Rig. Its state is one `U64`, which its methods change, so they take
`!self`. A `Random` is unique (`struct Random unique`): it moves (`a = <r`)
and is never copied, since a copy would draw the same numbers as the
original; `fork` makes a second generator on purpose. A seeded `Random` gives the same sequence on every
platform. It is not for cryptography.

| Member | Result |
|---|---|
| `Random.seeded(seed: U64) -> Random` | a generator whose sequence `seed` fixes |
| `Random.new() -> Random` | a generator seeded from the operating system's entropy, different on each run |
| `!r.next() -> U64` | the next 64 random bits |
| `!r.fork() -> Random` | a new generator, seeded from `r`'s next number |
| `!r.int(lo: Int, hi: Int) -> Int` | an `Int` from `lo` up to but not including `hi`, each equally likely, for any range up to `Int.min` to `Int.max`; panics unless `lo < hi` |
| `!r.float() -> Float` | a `Float` from 0 up to but not including 1 |
| `!r.shuffle(!xs)` | put the elements of the slice `xs` in a random order, each order equally likely |

```rig
use std.random

sub main
  r = random.Random.seeded(2024)
  again = random.Random.seeded(2024)
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

Sorting, and searching sorted slices, written in Rig over slices, so
they work on arrays and on Vecs alike (`!a`, `?a`, `!v`, `?v`). The elements are plain data, as a slice's are. `sort`,
`lower_bound`, and `search` order elements with `<` (numbers and
Strings), and `search` compares them with `==`; each call is checked
for its element type, as any generic call is.

| Function | Result |
|---|---|
| `sort(xs: ![]T)` | sort `xs` in place, in the order of `<`, keeping equal elements in the order they had; allocates nothing |
| `sort_by(xs: ![]T, less: ?fun(?T, ?T) -> Bool)` | the same, in the order `less` gives: `less(a, b)` says whether `a` belongs before `b` |
| `lower_bound(xs: []T, x: T) -> Int` | in `xs` sorted by `<`, the index where `x` belongs: the first element not less than `x`, or `xs.len` |
| `search(xs: []T, x: T) -> Int?` | in `xs` sorted by `<`, the index of the first element equal to `x`, by binary search; `none` when there is none |

`sort` sorts runs of 20 elements by insertion, then merges them in
place by rotations: O(n log n) comparisons, O(n log² n) swaps, and
O(log n) stack, with no other memory.

```rig
use std.sort

struct Player
  name: String
  score: Int

sub main
  scores = [30, 10, 20, 10]
  sort.sort(!scores)
  print(scores, sort.search(?scores, 20), sort.search(?scores, 5))
  print(sort.lower_bound(?scores, 15), sort.lower_bound(?scores, 99))

  v: Vec[Player] = Vec()
  !v.push(Player(name: "ann", score: 7))
  !v.push(Player(name: "bob", score: 9))
  !v.push(Player(name: "cy", score: 7))
  sort.sort_by(!v, |a, b| a.score > b.score)
  for p in ?v
    print(p.name, p.score)
```

```output
[10, 10, 20, 30] 2 none
2 4
bob 9
ann 7
cy 7
```

A NaN is not ordered by `<`: no comparison with one is true, so `sort`
leaves Floats that may be NaN in no particular order. Sort them with
`sort_by` and a comparator that orders every value, here putting NaN
last:

```rig
use std.sort

sub main
  zero = 0.0
  xs = [2.0, zero / zero, 1.0]
  sort.sort_by(!xs, |a, b| a == a and (b != b or a < b))
  print(xs)
```

```output
[1.0, 2.0, nan]
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

## std.slices

Linear operations on slices, written in Rig, on arrays and on Vecs
through a slice. `contains` and `index_of` compare elements with `==`.

| Function | Result |
|---|---|
| `reverse(xs: ![]T)` | reverse the order of `xs` in place |
| `contains(xs: []T, x: T) -> Bool` | whether some element equals `x` |
| `index_of(xs: []T, x: T) -> Int?` | the index of the first element equal to `x`, or `none` |

```rig
use std.slices

sub main
  names = ["cy", "ann", "bob"]
  slices.reverse(!names)
  print(names, slices.index_of(?names, "ann"), slices.contains(?names, "dee"))
```

```output
["bob", "ann", "cy"] 1 false
```

## std.text

Searching, slicing, splitting, and parsing Strings. A String is UTF-8
bytes by convention, and nothing here checks that it is: every index
and length is in bytes, and whitespace and case are ASCII's. A function
that returns a String returns a part of the String it was given, a
view of the same bytes, so nothing here allocates. A String taken from
a `Text` ([SPEC §10](../SPEC.md#text)) keeps it lent through every
part these functions return.

| Function | Result |
|---|---|
| `find(s: String, pat: String) -> Int?` | the index of the first occurrence of `pat` in `s`, or `none`; 0 for `""` |
| `find_last(s: String, pat: String) -> Int?` | the index of the last occurrence, or `none`; `s.len` for `""` |
| `contains(s: String, pat: String) -> Bool` | whether `pat` occurs in `s`; every String contains `""` |
| `starts_with(s: String, prefix: String) -> Bool`, `ends_with(s: String, suffix: String) -> Bool` | whether `s` begins with `prefix`, or ends with `suffix` |
| `count(s: String, pat: String) -> Int` | how many times `pat` occurs, counted from the left without overlaps (`count("aaaa", "aa")` is 2); `s.len + 1` for `""` |
| `trim(s: String) -> String` | `s` without its leading and trailing ASCII whitespace |
| `trim_start(s: String) -> String`, `trim_end(s: String) -> String` | `s` without its leading, or its trailing, ASCII whitespace |
| `strip_prefix(s: String, prefix: String) -> String? from s` | `s` after `prefix`, or `none` when `s` does not begin with it |
| `strip_suffix(s: String, suffix: String) -> String? from s` | `s` before `suffix`, or `none` when `s` does not end with it |
| `cut(s: String, sep: String) -> Cut? from s` | `s` around the first `sep`: a `Cut` of the part `before` it and the part `after` it, or `none` when `sep` does not occur |
| `split(s: String, sep: String) -> Split` | the parts of `s` between the occurrences of `sep`, one more than `count(s, sep)`, some perhaps empty; panics when `sep` is `""` |
| `lines(s: String) -> Lines` | the lines of `s`, without their endings, `\n` or `\r\n`; a line ending at the end of `s` adds no empty line, so `""` has none |
| `words(s: String) -> Words` | the words of `s`: the nonempty runs of bytes between ASCII whitespace |
| `parse_int(s: String) -> Int!` | `s` as a base-10 `Int`: an optional sign, `+` or `-`, then digits, and nothing else |
| `parse_float(s: String) -> Float!` | `s` as a `Float`: an optional sign, then digits with an optional `.` and fraction and an optional exponent (`2.5`, `.5`, `1e-3`), or `inf`, `infinity`, or `nan` in any case; the nearest `Float` to the number |
| `parse_bool(s: String) -> Bool!` | `true` for `"true"` and `false` for `"false"` |
| `is_digit(b: U8) -> Bool`, `is_alpha(b: U8) -> Bool` | whether `b` is an ASCII digit, or an ASCII letter |
| `is_space(b: U8) -> Bool` | whether `b` is ASCII whitespace: a space, tab, line feed, vertical tab, form feed, or carriage return |
| `to_upper(b: U8) -> U8`, `to_lower(b: U8) -> U8` | `b` in upper, or lower, case when it is an ASCII letter, else `b` |
| `valid_utf8(bytes: []U8) -> Bool` | whether `bytes` is well-formed UTF-8 |
| `compare(a: String, b: String) -> Int` | -1, 0, or 1 as `a` sorts before, with, or after `b` in the order of `<`, by bytes |

```rig
use std.text

sub main
  line = "  name = Ada Lovelace  "
  if text.cut(text.trim(line), " = ") as kv
    print(kv.before, "is", kv.after)
  print(text.find("banana", "an"), text.find_last("banana", "an"), text.count("banana", "a"))
  print(text.starts_with("main.rig", "main"), text.strip_suffix("main.rig", ".rig") ?? "?")
  print(text.contains("banana", "nab"), text.strip_prefix("banana", "x") ?? "no prefix")
```

```output
name is Ada Lovelace
1 3 3
true main
false no prefix
```

`split`, `lines`, and `words` give an iterator, a struct holding the
rest of the String, whose `next` gives each part in turn, and `none`
after the last. It is advanced by lending it to write:

```rig
use std.text

sub main
  fields = text.split("ann,,bob", ",")
  while !fields.next() as field
    print("[", field, "]")
  rows = text.lines("x 1\r\ny  2\n")
  while !rows.next() as row
    ws = text.words(row)
    while !ws.next() as w
      print(w, text.is_digit(w[0]))
```

```output
[ ann ]
[  ]
[ bob ]
x false
1 true
y false
2 true
```

A parser fails with the module's error set, `ParseError`: `invalid`
when the String is not written as the table says (including when it
has whitespace around it, which `trim` removes), and `overflow` when
the number is too large for its type: an `Int` outside `Int.min` to
`Int.max`, or a `Float` whose magnitude is beyond `Float.max`. A
`Float` too small to hold is 0.

```rig
use std.text

fun total(xs: []String) -> Int!
  sum = 0
  for x in xs
    sum += text.parse_int(text.trim(x))!
  sum

sub main
  print(total(["12", " -3 ", "+4"]) catch -1, total(["1", "one"]) catch -1)
  print(text.parse_float("-2.5e3") catch 0.0, text.parse_bool("false") catch true)
  n = text.parse_int("9223372036854775808") catch |err|
    print(err, err == text.ParseError.overflow)
    0
  print(n)
```

```output
13 -1
-2500.0 false
ParseError.overflow true
0
```

`compare` orders Strings in one pass over their bytes, for a sort by a
key that is a String:

```rig
use std.sort
use std.text

struct City
  name: String
  pop: Int

sub main
  cities = [City(name: "Oslo", pop: 7), City(name: "Bern", pop: 1), City(name: "Lima", pop: 10)]
  sort.sort_by(!cities, |a, b| text.compare(a.name, b.name) < 0)
  for c in cities
    print(c.name, c.pop)
```

```output
Bern 1
Lima 10
Oslo 7
```
