# The Rig standard library

The standard library ships with the compiler. A program imports one of
its modules with `use std.NAME`, which names it `NAME`
([SPEC §14](../SPEC.md#14-modules)):

```rig
use std.math

sub main()
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
| [`std.text`](#stdtext) | searching, slicing, splitting, and parsing text |
| [`std.utf8`](#stdutf8) | runes: reading, writing, counting, and checking UTF-8 |
| [`std.utf16`](#stdutf16) | units: UTF-16 lengths and positions, and surrogate pairs |
| [`std.unicode`](#stdunicode) | rune properties: identifier classes and white space |
| [`std.json`](#stdjson) | a JSON parser (experimental) |

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

sub main()
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

sub main()
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

`shortest(f: Float) -> Decimal?` is the shortest decimal that reads back
as exactly `f`: a `Decimal` with `neg` (the sign bit), `digits: U64`
without a trailing zero (0 for a zero), and `exp: Int`, so that `|f|` is
`digits * 10^exp`. It is `none` for NaN and the infinities, and allocates
nothing. Formatting, such as an exponent form, is built above it.

```rig
use std.math

sub show(f: Float)
  if math.shortest(f) as d
    print(d.neg, d.digits, d.exp)
  else
    print("none")

sub main()
  show(5e-324)
  show(-0.1)
  show(123.45)
  show(0.0)
  show(math.sqrt(-1.0))
```

```output
false 5 -324
true 1 -1
false 12345 -2
false 0 0
none
```

## std.os

The arguments and environment the program started with. Their text
lives as long as the program, as a literal's does, and views no `String`,
so both are a `Static` ([SPEC §2](../SPEC.md#static)). They hold the
bytes the operating system gave, which are not checked to be UTF-8.
A `Static` carries no loan, so a result can be kept, returned, and
stored anywhere, in a `Cell` too, whatever `name` is.

| Function | Result |
|---|---|
| `args() -> []Static` | every argument, the program's name first |
| `env(name: ?String) -> Static?` | the value of the environment variable `name`, or `none` when it is not set |

`rig run file.rig -- a b` passes `a` and `b` to the program, and a
built executable takes its arguments as usual. The first argument is
the path the program was started by: under `rig run`, that of the
executable `rig` built in its cache. With `fun main() -> Int`
([SPEC §1](../SPEC.md#1-programs)), a program also reports an exit
status:

```rig
use std.os

fun main() -> Int
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

sub main()
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

sub main()
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
`!self`. A `Random` is unique (`obj Random unique`): it moves (`a = <r`)
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

sub main()
  r = random.Random.seeded(2024)
  again = random.Random.seeded(2024)
  print((!r).next() == (!again).next())
  roll = (!r).int(1, 7)
  print(roll >= 1 and roll <= 6, (!r).float() < 1.0)
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
they work on arrays and on Lists alike (`!a`, `?a`, `!v`, `?v`). The elements are plain data, as a slice's are. `sort`,
`lower_bound`, and `search` order elements with `<` (numbers and
`?String` values), and `search` compares them with `==`; each call is checked
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

obj Player
  name: ?String
  score: Int

sub main()
  scores = [30, 10, 20, 10]
  sort.sort(!scores)
  print(scores, sort.search(?scores, 20), sort.search(?scores, 5))
  print(sort.lower_bound(?scores, 15), sort.lower_bound(?scores, 99))

  v: List[Player] = List()
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

sub main()
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

obj Player
  name: ?String
  score: Int

sub main()
  team = [Player(name: "ann", score: 7)]
  sort.sort(!team)
```

```error
`sort.sort[Player]` cannot use `T = Player`: the generic body applies `<` to `T`
```

## std.slices

Linear operations on slices, written in Rig, on arrays and on Lists
through a slice. `contains` and `index_of` compare elements with `==`.

| Function | Result |
|---|---|
| `reverse(xs: ![]T)` | reverse the order of `xs` in place |
| `contains(xs: []T, x: T) -> Bool` | whether some element equals `x` |
| `index_of(xs: []T, x: T) -> Int?` | the index of the first element equal to `x`, or `none` |

```rig
use std.slices

sub main()
  names = ["cy", "ann", "bob"]
  slices.reverse(!names)
  print(names, slices.index_of(?names, "ann"), slices.contains(?names, "dee"))
```

```output
["bob", "ann", "cy"] 1 false
```

## List

`List[T]` is built in ([SPEC §10](../SPEC.md)). `!v.reserve(n)` makes room
for `n` more elements without changing the length, so the next `n`
pushes allocate nothing; a negative `n` panics. `!v.keep(n)` keeps the
first `n` elements and drops the rest, so a List can be rewound to a
length saved earlier.

```rig
sub main()
  v: List[Int] = List()
  !v.reserve(3)
  for i in 0..3
    !v.push(i * i)
  print(v.len, v)
  !v.keep(1)
  print(v)
```

```output
3 [0, 1, 4]
[0]
```

## Text: bytes, runes, units, chars

Every text API is described in four words, each with one meaning:

| Word | What it is | Size |
|---|---|---|
| **byte** | 8 bits, a `U8`: what a `String` stores, and what `s.len`, `s[i]`, and slicing count | 1 byte |
| **rune** | one Unicode code point other than a surrogate (a scalar value): a character's number, 0 to 0x10FFFF | 1 to 4 bytes in UTF-8 |
| **unit** | one UTF-16 code unit, what JavaScript's string length counts | 2 bytes; a rune above U+FFFF takes 2 |
| **char** | what a reader sees as one character: a Unicode extended grapheme cluster | 1 or more runes |

A char is a grapheme and nothing else: one character, as a person
counts it, however many bytes it takes. The table of one char at 1, 2,
3, 8, and 18 bytes is in [SPEC, Strings](../SPEC.md#strings), and the
whole design, with each unit's module, is [TEXT](TEXT.md).

Counting chars, runes, and units scans the text, so each is a call
that names its unit:

```rig pending
use std.text
use std.utf8
use std.utf16

sub main()
  s = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}"
  print(text.char_count(s), utf8.rune_count(s), utf16.unit_count(s), s.len)
```

```output
1 5 8 18
```

## String

`String` is built in ([SPEC §10](../SPEC.md#string)). Besides `add` and
`push(b)`, it takes two methods for building binary text: `!t.reserve(n)`
makes room for `n` more bytes without changing the length, and
`!t.push[T, e](v)` appends the bytes of the integer `v` in byte order `e`
in one write, as `bytes.read[T, e](at)` reads them back.
`!t.push(v, keep: k)` appends only the first `k` bytes of a `Simd[U8, n]`
(or `!t.push[T, e](w, keep: k)` of an integer's bytes), `0 <= k <= n`:
it stores the whole block after the length in one write, and keeps `k`
bytes, so text is copied a block at a time while it is scanned
([SPEC §10](../SPEC.md#string)).

```rig
sub main()
  t = String()
  !t.reserve(8)
  !t.push[U32, .big](0x52696721)
  !t.push[U16, .little](0x2121)
  print(t, t.len)
```

```output
Rig!!! 6
```

## std.text

Searching, slicing, splitting, and parsing text, which every function
reads as a `?String`: UTF-8 bytes by convention, and nothing here checks
that it is. Every index and length is in bytes, and whitespace and case
are ASCII's. A function that returns a `?String` returns a part of the
`?String` it was given, a view of the same bytes, so nothing here
allocates. A `?String` taken from a `String`
([SPEC §10](../SPEC.md#string)) keeps it lent through every part these
functions return.

| Function | Result |
|---|---|
| `find(s: ?String, pat: ?String) -> Int?` | the index of the first occurrence of `pat` in `s`, or `none`; 0 for `""` |
| `find_last(s: ?String, pat: ?String) -> Int?` | the index of the last occurrence, or `none`; `s.len` for `""` |
| `contains(s: ?String, pat: ?String) -> Bool` | whether `pat` occurs in `s`; every `?String` contains `""` |
| `starts_with(s: ?String, prefix: ?String) -> Bool`, `ends_with(s: ?String, suffix: ?String) -> Bool` | whether `s` begins with `prefix`, or ends with `suffix` |
| `count(s: ?String, pat: ?String) -> Int` | how many times `pat` occurs, counted from the left without overlaps (`count("aaaa", "aa")` is 2); `s.len + 1` for `""` |
| `trim(s: ?String) -> ?String` | `s` without its leading and trailing ASCII whitespace |
| `trim_start(s: ?String) -> ?String`, `trim_end(s: ?String) -> ?String` | `s` without its leading, or its trailing, ASCII whitespace |
| `strip_prefix(s: ?String, prefix: ?String) -> (?String)? from s` | `s` after `prefix`, or `none` when `s` does not begin with it |
| `strip_suffix(s: ?String, suffix: ?String) -> (?String)? from s` | `s` before `suffix`, or `none` when `s` does not end with it |
| `cut(s: ?String, sep: ?String) -> Cut? from s` | `s` around the first `sep`: a `Cut` of the part `before` it and the part `after` it, or `none` when `sep` does not occur |
| `split(s: ?String, sep: ?String) -> Split` | the parts of `s` between the occurrences of `sep`, one more than `count(s, sep)`, some perhaps empty; panics when `sep` is `""` |
| `lines(s: ?String) -> Lines` | the lines of `s`, without their endings, `\n` or `\r\n`; a line ending at the end of `s` adds no empty line, so `""` has none |
| `words(s: ?String) -> Words` | the words of `s`: the nonempty runs of bytes between ASCII whitespace |
| `parse_int(s: ?String, base: Int = 10) -> Int!` | `s` as an `Int` in base `base`, 2 to 36: an optional sign, `+` or `-`, then digits (letters `a` to `z`, in either case, are 10 to 35), and nothing else: no `0x`, no `_`; panics for another base |
| `format_int(n: Int, base: Int = 10, upper: Bool = false) -> String` | `n` in base `base`, 2 to 36: a `-` if negative, then the digits, lower case unless `upper`; an owned `String`; panics for another base |
| `parse_float(s: ?String) -> Float!` | `s` as a `Float`: an optional sign, then digits with an optional `.` and fraction and an optional exponent (`2.5`, `.5`, `1e-3`), or `inf`, `infinity`, or `nan` in any case; the nearest `Float` to the number |
| `parse_bool(s: ?String) -> Bool!` | `true` for `"true"` and `false` for `"false"` |
| `is_digit(b: U8) -> Bool`, `is_alpha(b: U8) -> Bool` | whether `b` is an ASCII digit, or an ASCII letter |
| `is_space(b: U8) -> Bool` | whether `b` is ASCII whitespace: a space, tab, line feed, vertical tab, form feed, or carriage return |
| `to_upper(b: U8) -> U8`, `to_lower(b: U8) -> U8` | `b` in upper, or lower, case when it is an ASCII letter, else `b` |
| `valid_utf8(bytes: []U8) -> Bool` | whether `bytes` is well-formed UTF-8 |
| `compare(a: ?String, b: ?String) -> Int` | -1, 0, or 1 as `a` sorts before, with, or after `b` in the order of `<`, by bytes |
| `edit_distance(a: ?String, b: ?String, row: !List[Int], max: Int = -1) -> Int` | the Levenshtein distance between `a` and `b` over runes (insert, delete, and substitute cost 1); `row` is the caller's scratch; with `max >= 0`, `max + 1` once the distance passes `max` |

```rig
use std.text

sub main()
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
rest of the `?String`, whose `next` gives each part in turn, and `none`
after the last. A `for` walks one ([SPEC §6](../SPEC.md#for)): a call's
result is held for the loop, and a name is advanced in place, so a loop
that `break`s leaves the rest to resume. The same loop is
`while (!fields).next() as field`.

```rig
use std.text

sub main()
  for field in text.split("ann,,bob", ",")
    print("[", field, "]")
  rows = text.lines("x 1\r\ny  2\n")
  for row in !rows
    for w in text.words(row)
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
when the `?String` is not written as the table says (including when it
has whitespace around it, which `trim` removes), and `overflow` when
the number is too large for its type: an `Int` outside `Int.min` to
`Int.max`, or a `Float` whose magnitude is beyond `Float.max`. A
`Float` too small to hold is 0.

```rig
use std.text

fun total(xs: []?String) -> Int!
  sum = 0
  for x in xs
    sum += text.parse_int(text.trim(x))!
  sum

sub main()
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

`compare` orders `?String` values in one pass over their bytes, for a sort by a
key that is a `?String`:

```rig
use std.sort
use std.text

obj City
  name: ?String
  pop: Int

sub main()
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

`parse_int` and `format_int` take a base from 2 to 36, and `edit_distance` counts
the edits between two names over a scratch `row` the caller reuses, so the loop
that compares one name with many candidates allocates once:

```rig
use std.text

sub main()
  print(text.parse_int("ff", 16)!, text.parse_int("-101", 2)!, text.parse_int("zz", 36)!)
  print(text.parse_int("12", 2) catch -1)
  print(text.format_int(255, 16), text.format_int(255, 16, upper: true), text.format_int(-8, 8))
  row: List[Int] = List()
  print(text.edit_distance("kitten", "sitting", !row), text.edit_distance("", "abc", !row))
  print(text.edit_distance("\u{e9}a", "ea", !row), text.edit_distance("kitten", "sitting", !row, max: 2))
```

```output
255 -5 1295
-1
ff FF -10
3 3
1 3
```

## std.utf8

Runes in UTF-8 (RFC 3629). A rune is one Unicode scalar value, an `Int`
from 0 to 0xD7FF or 0xE000 to 0x10FFFF, which UTF-8 writes as one to
four bytes; a valid sequence has no overlong form, encodes no surrogate,
and nothing past U+10FFFF. Every index and size is in bytes. A reader
takes a `?String` and allocates nothing; `push_rune` appends to a
`String`. Each function reads every input, valid or not, as its twin in
Go's `unicode/utf8` does, so a Go port is a rename; [TEXT](TEXT.md) says
how runes fit with bytes, units, and chars.

| Name | Meaning | Go |
|---|---|---|
| `Decoded` | a rune read from a `?String`: its `rune: Int`, and the `size: Int` in bytes it took there | |
| `REPLACEMENT` | 0xFFFD, read in place of a byte that is not UTF-8, and written in place of a value that is not a rune | `RuneError` |
| `RUNE_SELF` | 0x80: a byte below it is a whole rune | `RuneSelf` |
| `rune_after(s: ?String, i: Int) -> Decoded` | the rune just after the cursor `i`, whose sequence starts at `i` | `DecodeRuneInString(s[i:])` |
| `rune_before(s: ?String, i: Int) -> Decoded` | the rune just before the cursor `i`, whose sequence ends at `i` | `DecodeLastRuneInString(s[:i])` |
| `runes(s: ?String) -> Runes` | each rune of `s`, a plain `Int`, in order, as `rune_after` reads it | `for _, r := range s` |
| `rune_size(s: ?String, i: Int) -> Int?` | the size in bytes, 1 to 4, of the valid rune that starts at `i`, or `none` when the bytes there are not valid UTF-8 or `i` is `s.len` | |
| `size(r: Int) -> Int?` | the bytes, 1 to 4, that `r` takes in UTF-8, or `none` when `r` is not a rune: a negative, a surrogate, or past 0x10FFFF | `RuneLen` |
| `rune_count(s: ?String) -> Int` | the runes of `s`, each bad byte counted as one | `RuneCountInString` |
| `is_valid(s: ?String) -> Bool` | whether `s` is well-formed UTF-8 | `ValidString` |
| `is_ascii(s: ?String) -> Bool` | whether every byte of `s` is below 0x80 | |
| `push_rune(out: !String, r: Int)` | append the bytes of `r`, or of `REPLACEMENT` when `r` is not a rune | `AppendRune` |

`test/behavior/std/utf8_go.rig` runs Go's own test tables, and
`test/cli/text_go.sh` compares every function with Go's on generated
text when `go` is installed.

- **Size 1:** where the bytes are not valid UTF-8 (a stray continuation
  byte, a truncated or overlong sequence, an encoded surrogate, or
  anything past U+10FFFF), the result is `Decoded(rune: 0xFFFD, size: 1)`,
  so a reader steps over one byte.
- **Size 0:** where there is nothing to read, `rune_after(s, s.len)`
  and `rune_before(s, 0)`, the empty `?String` included, the result is
  `Decoded(rune: 0xFFFD, size: 0)`.
- `rune_before` gives size 1 when the bytes behind `i` do not form one
  valid rune ending at `i`.
- An index outside 0 to `s.len` panics, as indexing does.

A valid U+FFFD in the text reads with its size, 3, so the size tells it
from an error, while `utf8.size(REPLACEMENT)` is always 3:

```rig
use std.utf8

sub main()
  for s in ["", "\u{fffd}", "\xe2\x82", "\xed\xa0\x80", "\x80\x80\x80\x80\x80"]
    a = utf8.rune_after(s, 0)
    b = utf8.rune_before(s, s.len)
    print(s.len, a.rune, a.size, b.rune, b.size, utf8.rune_count(s), utf8.is_valid(s))
```

```output
0 65533 0 65533 0 0 true
3 65533 3 65533 3 1 true
2 65533 1 65533 1 2 false
3 65533 1 65533 1 3 false
5 65533 1 65533 1 5 false
```

`rune_after` and `rune_before` read in either direction. Bad bytes read
one at a time, so a reader always moves; here reading back from the end
gives the runes read forward:

```rig
use std.utf8

sub main()
  s = "a\u{e9}\u{20ac}\xff\u{1f600}"
  i = 0
  while i < s.len
    d = utf8.rune_after(s, i)
    print(d.rune, d.size)
    i += d.size
  while i > 0
    d = utf8.rune_before(s, i)
    print(d.rune, d.size)
    i -= d.size
  print(utf8.rune_after(s, s.len).size, utf8.rune_size(s, 1) ?? 0, utf8.rune_size(s, 2) ?? 0, utf8.rune_size(s, 6) ?? 0)
```

```output
97 1
233 2
8364 3
65533 1
128512 4
128512 4
65533 1
8364 3
233 2
97 1
0 2 0 0
```

`runes` gives an iterator whose `next` gives each rune, as `lines` does
in `std.text`, and `push_rune` writes runes back, a value that is not a
rune as U+FFFD:

```rig
use std.utf8

sub main()
  out = String()
  for r in utf8.runes("\u{e9}t\u{e9}\x80")
    utf8.push_rune(!out, r)
  utf8.push_rune(!out, 0xD800)
  print(out, out.len, ?out == "\u{e9}t\u{e9}\u{fffd}\u{fffd}", utf8.is_ascii(?out))
  for r in [0x41, 0xe9, 0x20ac, 0x1f600, 0xd800, 0x110000, -1]
    print(r, utf8.size(r) ?? -1)
```

```output
été�� 11 true false
65 1
233 2
8364 3
128512 4
55296 -1
1114112 -1
-1 -1
```

## std.utf16

Units: the 16-bit code units of UTF-16, for code that must agree with
JavaScript and the languages built on it, whose string `length` and
positions count units. A rune below U+10000 is one unit; a rune from
U+10000 up is two, a high surrogate (0xD800 to 0xDBFF) and then a low one
(0xDC00 to 0xDFFF). Surrogates are units, never runes, so their
parameters are named `u`, `hi`, and `lo`. Text is UTF-8, as a `String`
holds it, and each byte that is not UTF-8 counts as one unit (U+FFFD),
as Go reads it; a JavaScript decoder may merge a run of bad bytes into
one U+FFFD.

| Name | Meaning | Go |
|---|---|---|
| `Pair` | the two units of a rune from U+10000 up: `hi: Int` and `lo: Int` | |
| `size(r: Int) -> Int?` | the units `r` takes, 1 or 2, or `none` when `r` is not a rune | `utf16.RuneLen` |
| `unit_count(s: ?String) -> Int` | the units of the UTF-8 text `s`: JavaScript's `length` of the same text | |
| `byte_index(s: ?String, units: Int) -> Int` | the byte where `units` units into `s` falls; a unit inside a pair lands after its rune, 0 or less gives 0, and a count past the end gives `s.len` | |
| `is_surrogate(u: Int) -> Bool` | whether `0xD800 <= u < 0xE000` | `utf16.IsSurrogate` |
| `rune_from_pair(hi: Int, lo: Int) -> Int` | the rune a pair encodes, or 0xFFFD when `hi` is not a high surrogate or `lo` not a low one | `utf16.DecodeRune` |
| `pair_from_rune(r: Int) -> Pair` | the pair that encodes `r`, or `Pair(hi: 0xFFFD, lo: 0xFFFD)` when `r` needs none | `utf16.EncodeRune` |

`byte_index` undoes `unit_count`: at each rune boundary `i`,
`byte_index(s, unit_count(s[..i]))` is `i`.

```rig
use std.utf16

sub main()
  s = "\u{1f468}\u{200d}\u{1f469}\u{200d}\u{1f467}"
  print(s.len, utf16.unit_count(s), utf16.unit_count("a\xffb"))
  for u in [0, 1, 2, 3, 8, 20]
    print(u, utf16.byte_index(s, u))
  print(utf16.size(0x41) ?? 0, utf16.size(0x1f600) ?? 0, utf16.size(0xd800) ?? 0)
  p = utf16.pair_from_rune(0x1f600)
  q = utf16.pair_from_rune(0x41)
  print(p.hi, p.lo, q.hi, q.lo, utf16.is_surrogate(p.hi))
  print(utf16.rune_from_pair(0xd83d, 0xde00), utf16.rune_from_pair(0xde00, 0xd83d))
```

```output
18 8 3
0 0
1 4
2 4
3 7
8 18
20 18
1 2 0
55357 56832 65533 65533 true
128512 65533
```

`test/behavior/std/utf16_go.rig` runs Go's `unicode/utf16` test tables.

## std.unicode

Properties of one rune, from the Unicode Character Database of the
version in `unicode.VERSION`, 15.1.0, the version of TypeScript's
scanner. The identifier classes are those of
[UAX #31](https://unicode.org/reports/tr31/): `is_id_start(r)` is
ID_Start (letters, letter numbers, and Other_ID_Start) and
`is_id_continue(r)` is ID_Continue (ID_Start, marks, decimal digits,
connector punctuation, and Other_ID_Continue). They are exactly the
Unicode classes: a language that begins identifiers with `$` or `_` adds
those itself. (Unicode 15.1 put the joiners U+200C and U+200D into
ID_Continue, as Other_ID_Continue.) White space is the White_Space
property of `PropList.txt`, which is Go's `unicode.IsSpace`; it is not
JavaScript's white space, which adds U+FEFF. A value that is not a rune
has no property.

| Name | Meaning |
|---|---|
| `VERSION` | the Unicode version of every property, `"15.1.0"` |
| `is_id_start(r: Int) -> Bool`, `is_id_continue(r: Int) -> Bool` | whether `r` may begin an identifier, or continue one |
| `is_space_rune(r: Int) -> Bool` | whether `r` is one of the 25 runes of White_Space |

```rig
use std.unicode

sub main()
  print(unicode.is_id_start(0x61), unicode.is_id_start(0x30), unicode.is_id_continue(0x30))
  print(unicode.is_id_start(0x2118), unicode.is_id_start(0xB7), unicode.is_id_continue(0xB7))
  print(unicode.is_id_start(0x2E2F), unicode.is_id_continue(0x200C), unicode.is_id_start(0x4E00))
  print(unicode.is_space_rune(0x20), unicode.is_space_rune(0x85), unicode.is_space_rune(0x3000), unicode.is_space_rune(0xFEFF))
  print(unicode.VERSION)
```

```output
true false true
true false true
false true true
true true true false
15.1.0
```

The identifier tables are generated: `tools/gen-unicode.py` reads the
pinned `DerivedCoreProperties.txt` of the Unicode Character Database
(checking its sha256, and fetching it when absent) and writes
`std/unicode_tables.zig`, a two-level bitmap of about 11 KB with an
ASCII fast path. To move to a newer Unicode, change the pinned version
and hashes, run the generator, and review the diff of the census test it
also writes. `tools/verify-unicode.py` compares every code point with the
database and with Python's `unicodedata`, the identifier classes and
White_Space both; the deep gate runs both with `RIG_UCD` naming a
directory of the database.

## std.json

**Experimental:** the names and shapes below will change, to idiomatic
fallible `!` functions, once errors can carry data. Use it to read JSON
fast today, not as a settled API.

A JSON parser (RFC 8259) in safe Rig, written for speed: it validates
the whole document in one pass and builds a tape, a flat list with one
entry for each value in document order. On Apple silicon it runs at 1.9 to 7.0 GB/s on the standard
benchmark files ([docs/json/](json/RESULTS.md)), 3 to 11 times Zig's `std.json`, with
every bounds and overflow check kept in `--release`. Nothing is lazy:
`parse` decodes every escape, checks all UTF-8, and converts every number
before it returns.

| Name | Meaning |
|---|---|
| `new_doc() -> Doc` | an empty `Doc`; each `parse` reuses its lists, so a parse allocates only when a list must grow |
| `(!doc).parse(src: ?String) -> Bool` | read all of `src` into `doc`'s tape: `true`, or `false` with `doc.error` and `doc.error_pos` set |
| `doc.error: Error`, `doc.error_pos: Int` | the first error, and the byte offset of the byte that cannot be read |
| `error_name(e: Error) -> Static` | the name of an `Error`: `ok`, `empty`, `unexpected`, `eof`, `number`, `range`, `escape`, `surrogate`, `control`, `utf8`, `trailing`, `depth`, or `too_large` |
| `doc.size() -> Int` | the number of tape entries |
| `doc.kind(i: Int) -> Kind` | the entry at `i`: `null`, `bool`, `int`, `float`, `string`, `array`, `array_end`, `object`, or `object_end` |
| `doc.get_bool(i: Int) -> Bool`, `doc.get_int(i: Int) -> Int`, `doc.get_float(i: Int) -> Float` | the value of a `bool`, `int`, or `float` entry |
| `doc.get_str(i: Int) -> ?String` | a `string` entry, an object's key included: its decoded UTF-8 bytes |
| `doc.next(i: Int) -> Int` | the index just past the value at `i`, past its closing entry for an array or object, to skip it |

An object's entries are its keys and values, alternating, between its
`object` and `object_end` entries. A string without escapes is a view of
`src`, so a `Doc` keeps `src` lent while it is in use. An integer literal
that fits an `Int` is an `int`; any other number is the nearest `Float`
(`-0` is a `Float`), and one beyond `Float.max` is a `range` error.
`NaN` and `Infinity` are errors, as are an unpaired surrogate in a `\u`
escape, bytes that are not UTF-8, and nesting deeper than 1024.
Duplicate keys are kept, in order. `parse` reads the whole document or
fails; a failed parse leaves an empty tape. An input over 4 GiB, or a
string longer than 2^27 - 1 bytes, is a `too_large` error (no test
reaches these sizes).

Every reader takes an index `0 <= i < doc.size()`, and each value getter
an entry of its own kind: out of range a reader panics, and on another
kind a getter returns an unspecified value or panics.

```rig
use std.json

sub main()
  src = "{\"name\": \"Ada\", \"langs\": [\"en\", \"fr\"], \"born\": 1815, \"pi\": 3.5}"
  doc = json.new_doc()
  if (!doc).parse(?src)
    for i in 0..doc.size()
      match doc.kind(i)
        .object => print("{")
        .object_end => print("}")
        .array => print("[")
        .array_end => print("]")
        .string => print("string", doc.get_str(i))
        .int => print("int", doc.get_int(i))
        .float => print("float", doc.get_float(i))
        _ => print("other")
  else
    print("error", doc.error)
  bad = "[1, 2"
  again = json.new_doc()
  if not (!again).parse(?bad)
    print(json.error_name(again.error), "at byte", again.error_pos)
```

```output
{
string name
string Ada
string langs
[
string en
string fr
]
string born
int 1815
string pi
float 3.5
}
eof at byte 5
```

`./test/run json` checks it against Python's `json` module on 10,511
inputs, sanitizer-clean (`test/json/README.md`); the design and the
measurements are in [json/DESIGN.md](json/DESIGN.md) and
[json/RESULTS.md](json/RESULTS.md).
