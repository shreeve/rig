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
| [`std.file`](#stdfile) | reading a whole file |
| [`std.time`](#stdtime) | clocks and sleeping |
| [`std.target`](#stdtarget) | the target the program is compiled for: its architecture |
| [`std.random`](#stdrandom) | a seedable pseudorandom generator |
| [`std.sort`](#stdsort) | sorting slices, and searching sorted ones |
| [`std.slices`](#stdslices) | reversing and linear search |
| [`std.hash`](#stdhash) | Map and Set: hash tables that keep insertion order; Symbols, dense ids for strings |
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
| `abs[T](x: T) -> T` | `x` without its sign, for a signed number type or `Float`; a Float's zero comes back as `+0.0`; panics on a type's minimum integer (`Int.min`) |
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

The Float constants NaN and infinity, and `frexp` (`fraction` and `exponent`), are methods of the number types, not of this module: `Float.nan()`, `Float.inf()`, `x.fraction()`, `x.exponent()` ([SPEC](../SPEC.md#numbers)).

Float functions, from Zig's. They follow IEEE 754: a result out of
range is an infinity, and an undefined one (the square root of a
negative number) is NaN, which equals nothing, itself included.

| Function | Result |
|---|---|
| `sqrt(x: Float) -> Float` | the square root |
| `floor(x: Float) -> Float` | the largest whole number not above `x` |
| `ceil(x: Float) -> Float` | the smallest whole number not below `x` |
| `trunc(x: Float) -> Float` | `x` rounded toward zero, keeping its sign (`trunc(-0.5)` is `-0.0`) |
| `copysign(x: Float, sign: Float) -> Float` | the magnitude of `x` with the sign of `sign`, a zero's or a NaN's included |
| `exp(x: Float) -> Float` | e to the power `x` |
| `ln(x: Float) -> Float` | the natural logarithm |
| `log2(x: Float) -> Float` | the base-2 logarithm |
| `sin(x: Float) -> Float`, `cos(x: Float) -> Float` | the sine and cosine of `x` radians |
| `powf(x: Float, y: Float) -> Float` | `x` to the power `y` |

```rig
use std.math

sub main()
  print(math.sqrt(2.0) > 1.414, math.floor(-2.5), math.ceil(-2.5))
  print(math.exp(0.0), math.ln(math.E))
  print(math.cos(math.PI), math.powf(2.0, 0.5) == math.sqrt(2.0))
  print(Int(math.floor(7.9)))
  print(math.abs(-0.0), math.trunc(-2.7), math.copysign(3.0, -1.0), math.log2(8.0))
```

```output
true -3.0 -2.0
1.0 1.0
-1.0 true
7
0.0 -2.0 -3.0 3.0
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

## std.file

Reading a whole file into a `String`.

| Function | Result |
|---|---|
| `read(path: ?String) -> String?` | the file at `path` as a fresh `String` of exactly its bytes, or `none` when it cannot be read |

A relative `path` starts at the working directory. The bytes are the
file's as they are: none added, and none checked to be UTF-8, so a
binary file reads as well as text. The `String` is the caller's, like
any other, and its buffer holds exactly the file's bytes, with no
spare room past them. A pipe or a device, which has no
size, is read to its end, so one that never ends (`/dev/zero`) is read
until memory runs out, and a pipe with no writer waits, as Go's
`os.ReadFile` does. A file too large for memory panics as any
allocation that fails does.

`read` gives `none` when the file does not exist, when `path` names a
directory, when the program may not read the file, and when reading it
fails partway. It does not say which: the `none` covers them all.

```rig
use std.file
use std.text

sub main()
  if file.read("examples/hello.rig") as source
    end = text.find(source, "\n") ?? source.len
    print(source[..end])
  print(file.read("examples") == none, file.read("no/such/file") == none)
```

```output
# The smallest meaningful Rig program.
true true
```

The suite runs this example from the repository's root, where
`examples/hello.rig` is.

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

## std.target

The target, the machine the program is compiled for, as compile-time
facts. `target.arch` is its processor architecture, a value of the
built-in enum `Arch`, whose variants are Zig's names for every
architecture it compiles for: `.x86_64`, `.aarch64`, `.wasm32`,
`.wasm64`, `.riscv64`, and the rest.

| Constant | Value |
|---|---|
| `arch: Arch` | the target's processor architecture |

Rig knows its type, never its value: Zig sets it when it compiles the
program, so `rig check` gives the same verdict on every machine, and a
choice on it is Zig's, made when it compiles. A constant that branches
on it serves code tuned per target; a place that needs a value when
Rig checks the program, such as an array length, rejects one
([SPEC §3](../SPEC.md#the-target)).

```rig
use std.target

TIER = 0 if target.arch == .x86_64 else 16

sub main()
  print(TIER < 32)
```

```output
true
```

The operating system and the CPU's features are not built yet.

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
`lower_bound`, and `search` order elements with `<` (numbers, plain
enums, and `?String` values), and `search` compares them with `==`; each call is checked
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

## std.hash

`hash.Map[K, V]` and `hash.Set[K]`, hash tables written in Rig over
Lists. Iteration is in the order keys were first put in, as in Python,
Ruby, and JavaScript: `put` on a key already there keeps its place, and
`take` keeps the rest in order. A key is any value `x.hash()` takes
([SPEC §5](../SPEC.md#operators)): what `==` compares, less a `Float`
and what holds one. Text hashes and compares by its bytes, so a
`Map[String, V]` finds `m.get("x")` and `m.get(?t)` alike, and a
`Map[?String, V]` holds views. Each instance is checked for its key
type, as any generic is.

| Member | Signature | Ownership |
|---|---|---|
| `hash.Map[K, V]()`, `hash.Map[K, V].new(capacity: n)` | `fun new(capacity: Int = 0) -> Map[K, V]` | an empty Map, which allocates nothing until the first `put`, or with room for `n` entries |
| `!m.reserve(n)` | `sub reserve(!self, n: Int)` | makes room for `n` more entries at once, sizing the entries and the table for them rather than growing as they are put |
| `m.len` | `pub ?len: Int` | the number of entries: a field other modules read and only `std.hash` writes |
| `m.has(k)` | `fun has(?self, k: ?K) -> Bool` | reads |
| `m.get(k)` | `fun get(?self, k: ?K) -> (?V)? from self` | the view keeps `m` lent to read, not `k` |
| `(!m).edit(k)` | `fun edit(!self, k: ?K) -> (!V)? from self` | keeps `m` lent to write |
| `!m.put(k, v)` | `sub put(!self, k: K, v: V)` | puts `v` under `k`, inserting or overwriting; the old value is dropped, and a key already there keeps its place and `k` is dropped |
| `(!m).replace(k, v)` | `fun replace(!self, k: K, v: V) -> V?` | puts `v` under `k`, inserting or overwriting, and hands back the old value, or `none` when `k` is new |
| `(!m).put_new(k, v)` | `fun put_new(!self, k: K, v: V) -> Bool` | puts `v` under `k` only when `k` is new: true if it did; otherwise `k` and `v` are dropped |
| `(!m).ensure(k, v)` | `fun ensure(!self, k: K, v: V) -> !V from self, k, v` | puts `v` under `k` when `k` is new, and lends the value under `k` to write; otherwise `k` and `v` are dropped. The view keeps `m` lent to write |
| `(!m).ensure_with(k, make)` | `fun ensure_with(!self, k: K, make: ?fun(?K) -> V) -> !V from self, k` | as `ensure`, with the value `make(k)` made only when `k` is new; when `k` is there, `make` is not called and `k` is dropped |
| `w, added = (!m).ensure_added(k, v)` | `fun ensure_added(!self, k: K, v: V) -> (!V, Bool) from self, k, v` | as `ensure`, and also whether `k` was new; `w` keeps `m` lent to write, `added` keeps nothing |
| `if m.at(i) as k, v` | `fun at(?self, i: Int) -> (?K, ?V)? from self` | the entry at index `i` in order, its key and value viewed where the Map holds them, or `none` past the end; both views keep `m` lent to read. One step while no entry was taken since the entries were last compacted; else it counts the entries before |
| `(!m).take(k)` | `fun take(!self, k: ?K) -> V?` | the value back, owned; the key dropped when the entries are next compacted (as the Map grows), or with the Map |
| `!m.clear()` | `sub clear(!self)` | drops every entry |
| `?m.items()` | `fun items(?self) -> Items[K, V] from self` | the iterator keeps `m` lent to read; each `Item[?K, ?V]` (`e.key`, `e.value`) lasts one step of the loop |
| `?m.keys()`, `?m.values()` | `fun keys(?self) -> Keys[K, V] from self` | likewise, each a `?K` or a `?V` |
| `!m.update(f)` | `sub update(!self, f: ?sub(?K, !V))` | writes each value in place; keys stay read-only |
| `!m.retain(f)` | `sub retain(!self, f: ?fun(?K, !V) -> Bool)` | keeps the entries `f` is true for, in order; `f` reads each key and may write its value, in order, and cannot reach `m`; an entry it rejects is dropped then, not left for compaction as `take` leaves a key |

`hash.Set[K]` has `hash.Set[K]()` and `new(capacity: n)`, `reserve(n)`,
the field `len`, `has(k: ?K)`, `(!s).add(k: K) -> Bool` (true when `k`
is new; otherwise `k` is dropped), `(!s).take(k: ?K) -> K?`,
`!s.retain(f)` with `f: ?fun(?K) -> Bool`, `clear()`, and
`?s.items()`, each key a `?K`.

`ensure` takes the value to put even when the key is there, and drops
it then. To make an expensive value only for a new key, use
`ensure_with`, whose `make` runs only then; `edit` first and `put` when
it finds nothing does the same:

```rig
use std.hash

fun twice(k: ?String) -> String
  String(k, k)

sub main()
  made = hash.Map[String, String].new()
  for w in ["ab", "cd", "ab"]
    s = (!made).ensure_with(String(w), twice)
    !s.add("+")
  again = hash.Map[String, String].new()
  for w in ["ab", "cd", "ab"]
    if (!again).edit(w) as s
      !s.add("+")
    else
      !again.put(String(w), String(w, w, "+"))
  counts = hash.Map[String, Int].new()
  for w in ["to", "be", "to"]
    (!counts).ensure(String(w), 0) += 1
  print(made.get("ab"), made.get("cd"), again.get("ab"), counts.get("to"), counts.get("be"))
```

```output
abab++ cdcd+ abab++ 2 1
```

`ensure_added` also says whether the key was new, which `ensure` cannot,
and `at` reads the entries by index, in the order they were put in:

```rig
use std.hash

sub main()
  counts = hash.Map[String, Int].new()
  for w in ["to", "be", "to"]
    c, added = (!counts).ensure_added(String(w), 0)
    c += 1
    print(w, "is new") if added
  i = 0
  while counts.at(i) as k, n
    print(i, k, n)
    i += 1
```

```output
to is new
be is new
0 to 2
1 be 1
```

A compound key is an object of its parts. A key object that owns its
text is looked up with one built the same way, its text owned too: a
lookup takes a view of the Map's own key type, and an object with the
same parts holding a `?String` is another type. A key object that
holds a `?String` looks up with no copy, and its Map holds views, as a
`Map[?String, V]` does.

A view an iterator gives comes from `next`, which takes the iterator
lent to write, so it lasts until the loop takes the next one: it can
be read and passed on in the loop's body, but not kept past it (`keep =
e.value` in the loop is rejected). To keep a value, clone it (`+e.value`),
or look it up again with `get`.

```rig
use std.hash

sub main()
  ages = hash.Map[String, Int].new()
  !ages.put(String("ada"), 36)
  !ages.put(String("bob"), 41)
  !ages.put(String("ada"), 37)
  print(ages.len, ages.get("ada"), ages.get("cy"))
  if (!ages).edit("bob") as a
    a += 1
  print((!ages).take("bob"), ages.has("bob"))
  name = String("cy")
  !ages.put(<name, 5)
  for e in ?ages.items()
    print(e.key, e.value)
  seen = hash.Set[?String].new()
  for w in ["b", "a", "b"]
    if (!seen).add(w)
      print("new", w)
  print(seen.len, seen.has("a"))
```

```output
2 37 none
42 false
ada 37
cy 5
new b
new a
2 true
```

The view `get` returns keeps the Map lent to read, so the Map is not
changed while it lives:

```rig reject
use std.hash

sub main()
  m = hash.Map[String, Int].new()
  !m.put(String("a"), 1)
  r = ?m.get("a")
  !m.put(String("b"), 2)
  print(r)
```

```error
cannot lend `m` to write while a read loan is live
```

Where the value copies, `?? v` with a value `v` gives a copy of it
instead of the view ([SPEC §12](../SPEC.md#the-fallback-of-)), which
keeps no loan:

```rig
use std.hash

sub main()
  m = hash.Map[String, Int].new()
  for w in ["a", "b", "a"]
    n = m.get(w) ?? 0
    !m.put(String(w), n + 1)
  print(m.get("a") ?? 0, m.get("c") ?? 0)
```

```output
2 0
```

A key needs `.hash()`, which a `Float` does not have:

```rig reject
use std.hash

sub main()
  m = hash.Map[Float, Int].new()
  print(m.len)
```

```error
cannot use `K = Float`: the generic body hashes a `K` with `.hash()`, which `Float` does not support
```

`hash.Symbols` holds a set of strings, each with a dense `U32` id from
0 in the order it was first interned. Their text lives in one String,
end to end, so an id costs four bytes and a new string is copied once.

| Member | Signature | Ownership |
|---|---|---|
| `hash.Symbols()` | | an empty one |
| `(!names).intern(s)` | `fun intern(!self, s: ?String) -> U32` | the id of `s`, a new one when `s` is new, whose text is then copied in; nothing is copied otherwise |
| `names.id(s)` | `fun id(?self, s: ?String) -> U32?` | the id of `s`, or `none`; adds nothing |
| `names.text(id)` | `fun text(?self, id: U32) -> ?String from self` | the text of `id`, viewed where the table holds it |
| `names.len` | `pub ?len: Int` | how many strings it holds |
| `!names.reserve(n, bytes: b)` | `sub reserve(!self, n: Int, bytes: Int = 0)` | room for `n` more strings of `b` bytes in all |

```rig
use std.hash

sub main()
  names = hash.Symbols()
  a = (!names).intern("width")
  b = (!names).intern("height")
  w = String("wid", "th")
  print(a, b, (!names).intern(?w), names.id("depth"), names.text(b), names.len)
```

```output
0 1 0 none height 2
```

The entries are kept in one List, in order, each with its key's hash
beside it, so no key is hashed twice: not when the table grows, nor
when an entry is taken. A Map or Set builds a table when it first
holds more than 8 entries, or when `reserve` makes room for more, and
keeps it until `clear`; until then, a lookup compares the stored
hashes in turn, then the key where one matches. The table is
open-addressed and probed linearly, at most four fifths full; each
slot holds a one-byte tag, the top seven bits of its key's hash, and
the index of its entry, so a probe compares a key only when the tag
matches, and a key that is not there is found missing from the tags
alone. A Map's entry holds its key and an optional value (for a
`Map[U32, U32]`, a `U32` and a `U32?`), and its hash, a `U64`, is kept
in a List beside the entries; taking one empties its value in place,
and the next growth drops the entry, key and all, keeping the rest in
order. A Set's key is optional, and taking one hands it back. The seed
of `.hash()` is fixed, so a program that lets others choose many keys
that collide can be made slow.

## List

`List[T]` is built in ([SPEC §10](../SPEC.md)). `!v.reserve(n)` makes room
for `n` more elements without changing the length, so the next `n`
pushes allocate nothing; a negative `n` panics. `!v.keep(n)` keeps the
first `n` elements and drops the rest, so a List can be rewound to a
length saved earlier.

`List.filled(n, x)` makes a List of `n` copies of `x`, and
`!v.resize(n, x)` grows a List to `n` elements with copies of `x`, or
shrinks it to `n` as `keep` does; a negative `n` panics. Each copies
one value into many elements, so the element must copy: plain data,
or a read view whose copies carry its loan. A List of owners is grown
by a loop whose `+x` makes each element.

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

```rig
sub main()
  marks = List.filled(3, 0)
  !marks.resize(5, 1)
  print(marks)
  !marks.resize(1, 0)
  print(marks)
```

```output
[0, 0, 0, 1, 1]
[0]
```

```rig reject
sub main()
  v: List[List[Int]] = List()
  !v.resize(2, List())
```

```error
`resize` copies its value into every element it adds, and a `List[Int]` owns a resource, so it cannot be copied
```

## Text: bytes, runes, units, chars

The whole text API, built and planned, is listed in [TEXT-API](TEXT-API.md).

Every text API is described in four words, each with one meaning:

| Word | What it is | Size |
|---|---|---|
| **byte** | 8 bits, a `U8`: what a `String` stores, and what `s.len`, `s[i]`, and slicing count | 1 byte |
| **rune** | one Unicode code point other than a surrogate (a scalar value): a code point's number, 0 to 0x10FFFF | 1 to 4 bytes in UTF-8 |
| **unit** | one UTF-16 code unit, what JavaScript's string length counts | 2 bytes; a rune above U+FFFF takes 2 |
| **char** | what a reader sees as one character: a Unicode extended grapheme cluster | 1 or more runes |

A char is a grapheme and nothing else: one character, as a person
counts it, however many bytes it takes. The table of one char at 1, 2,
3, 8, and 18 bytes is in [SPEC, Strings](../SPEC.md#strings), and the
whole design, with each unit's module, is [TEXT](TEXT.md).

Counting chars, runes, and units scans the text, so each is a call
that names its unit:

```rig
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

## Enum names

A plain enum's names are built in ([SPEC, Enums](../SPEC.md#enums)):
`e.text` is the name of `e`'s variant, a `Static`, and
`E.from_text(word)` is the variant named `word`, or `none`. Neither
allocates, so a word read from input becomes a value as `text.parse_int`
makes a number, and a value prints back as text. For names that are
not an enum's, known only when the program runs, `hash.Symbols` gives
each one a dense id ([std.hash](#stdhash)).

```rig
use std.text

enum Level
  debug
  info
  warn

sub main()
  for w in text.words("warn info trace debug")
    if Level.from_text(w) as l
      print(l.text, Int(l))
    else
      print("unknown level", w)
```

```output
warn 2
info 1
unknown level trace
debug 0
```

## std.text

Searching, slicing, splitting, and parsing text, which every function
reads as a `?String`: UTF-8 bytes by convention, and nothing here checks
that it is. Every index is a byte index; a count names its unit; and
whitespace and case are ASCII's. A function that returns a `?String`
returns a part of the `?String` it was given, a view of the same bytes,
so nothing here allocates but `format_int`, which returns a new String,
and `edit_distance`, which grows the `row` it is given. A `?String` taken from a `String`
([SPEC §10](../SPEC.md#string)) keeps it lent through every part these
functions return.

| Function | Result |
|---|---|
| `find(s: ?String, pat: ?String) -> Int?` | the index of the first occurrence of `pat` in `s`, or `none`; 0 for `""` |
| `find_last(s: ?String, pat: ?String) -> Int?` | the index of the last occurrence, or `none`; `s.len` for `""` |
| `contains(s: ?String, pat: ?String) -> Bool` | whether `pat` occurs in `s`; every `?String` contains `""` |
| `starts_with(s: ?String, prefix: ?String) -> Bool`, `ends_with(s: ?String, suffix: ?String) -> Bool` | whether `s` begins with `prefix`, or ends with `suffix` |
| `count(s: ?String, pat: ?String) -> Int` | how many times `pat` occurs, counted from the left without overlaps (`count("aaaa", "aa")` is 2); `s.len + 1` for `""` |
| `find_any[set: ?String](s: ?String, i: Int) -> Int?` | the first index at or after `i` whose byte is one of `set`'s, or `none`; `set` is a compile-time string, each byte of it one compare per 16 bytes of `s`, and `""` holds no byte; panics unless `0 <= i <= s.len` |
| `class_end(s: ?String, i: Int, table: ?[256]U8, mask: U8) -> Int` | the first index at or after `i` whose byte's class, `table[b]`, has no bit of `mask`, or `s.len`; the caller's table gives each byte its class bits; panics unless `0 <= i <= s.len` |
| `trim(s: ?String) -> ?String` | `s` without its leading and trailing ASCII whitespace |
| `trim_start(s: ?String) -> ?String`, `trim_end(s: ?String) -> ?String` | `s` without its leading, or its trailing, ASCII whitespace |
| `strip_prefix(s: ?String, prefix: ?String) -> (?String)? from s` | `s` after `prefix`, or `none` when `s` does not begin with it |
| `strip_suffix(s: ?String, suffix: ?String) -> (?String)? from s` | `s` before `suffix`, or `none` when `s` does not end with it |
| `cut(s: ?String, sep: ?String) -> Cut? from s` | `s` around the first `sep`: a `Cut` of the part `before` it and the part `after` it, or `none` when `sep` does not occur |
| `split(s: ?String, sep: ?String) -> Split` | the parts of `s` between the occurrences of `sep`, one more than `count(s, sep)`, some perhaps empty; panics when `sep` is `""` |
| `lines(s: ?String) -> Lines` | the lines of `s`, without their endings, `\n` or `\r\n`; a line ending at the end of `s` adds no empty line, so `""` has none |
| `words(s: ?String) -> Words` | the words of `s`: the nonempty runs of bytes between ASCII whitespace |
| `chars(s: ?String) -> Chars` | the chars of `s`, each a `?String` viewing its bytes in `s` ([below](#chars)) |
| `char_count(s: ?String) -> Int` | how many chars `s` holds |
| `first_chars(s: ?String, n: Int) -> ?String`, `last_chars(s: ?String, n: Int) -> ?String` | the first, or last, `n` chars of `s`, or all of `s` if it has fewer; panics when `n` is negative |
| `char_boundary(s: ?String, i: Int) -> Int` | the char boundary at or before byte `i`: `i` where a char starts and at `s.len`, else the start of the char `i` is inside; panics unless `0 <= i <= s.len` |
| `parse_int(s: ?String, base: Int = 10) -> Int!` | `s` as an `Int` in base `base`, 2 to 36: an optional sign, `+` or `-`, then digits (letters `a` to `z`, in either case, are 10 to 35), and nothing else: no `0x`, no `_`; panics for another base |
| `format_int(n: Int, base: Int = 10, upper: Bool = false) -> String` | `n` in base `base`, 2 to 36: a `-` if negative, then the digits, lower case unless `upper`; an owned `String`; panics for another base |
| `parse_float(s: ?String) -> Float!` | `s` as a `Float`: an optional sign, then digits with an optional `.` and fraction and an optional exponent (`2.5`, `.5`, `1e-3`), or `inf`, `infinity`, or `nan` in any case; the nearest `Float` to the number |
| `parse_bool(s: ?String) -> Bool!` | `true` for `"true"` and `false` for `"false"` |
| `is_digit(b: U8) -> Bool`, `is_alpha(b: U8) -> Bool` | whether `b` is an ASCII digit, or an ASCII letter |
| `is_space(b: U8) -> Bool` | whether `b` is ASCII whitespace: a space, tab, line feed, vertical tab, form feed, or carriage return |
| `to_upper(b: U8) -> U8`, `to_lower(b: U8) -> U8` | `b` in upper, or lower, case when it is an ASCII letter, else `b` |
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
  print(text.find_any[",;"]("a b;c,d", 0) ?? -1, text.find_any[",;"]("a b;c,d", 4) ?? -1, text.find_any[",;"]("a b", 0) ?? -1)
  digits: [256]U8 = [256 of 0]
  for b in 0x30..0x3A
    digits[b] = 1
  print(text.class_end("2026-10-13", 0, digits, 1), text.class_end("2026-10-13", 5, digits, 1))
```

```output
name is Ada Lovelace
1 3 3
true main
false no prefix
3 5 -1
4 7
```

`split`, `lines`, and `words` give an iterator, an object holding the
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

### Chars

A char is an extended grapheme cluster of Unicode's text segmentation
([UAX #29](https://unicode.org/reports/tr29/), rules GB1 to GB13 and
GB999) by the tables of Unicode 15.1.0, the version of `std.unicode`:
one character as a reader sees it, of one rune or several. Text that is
not UTF-8 is read as Go reads it: each byte that starts no well-formed
sequence is one rune, U+FFFD, of one byte. So every byte is in exactly
one char, and the chars of a `?String` tile it: their sizes add up to
`s.len`.

`chars`, `char_count`, and `first_chars` read from the start of the
text; `last_chars` and `char_boundary` read back from the end, or from
`i`, only as far as they need. Each is one pass, and a run of ASCII is
read 32 bytes at a time: two ASCII bytes are two chars, unless they are
CR LF.

```rig
use std.text

sub main()
  s = "cafe\u{301}-\u{1f44b}\u{1f3fd}-\u{1f1eb}\u{1f1f7}!"
  print(s.len, text.char_count(s))
  for c in text.chars(s)
    print(c, c.len)
  print(text.first_chars(s, 4), text.last_chars(s, 2))
  print(s[..text.char_boundary(s, 5)], text.char_count("\xff\xfe\r\n"))
```

```output
25 9
c 1
a 1
f 1
é 3
- 1
👋🏽 8
- 1
🇫🇷 8
! 1
café 🇫🇷!
caf 3
```

The tables are generated: `tools/gen-unicode.py` reads the pinned
GraphemeBreakProperty.txt, emoji-data.txt (Extended_Pictographic), and
DerivedCoreProperties.txt (Indic_Conjunct_Break, for GB9c) and writes
`std/grapheme_tables.zig`, a two-level table of four bits a code point,
20 KB, whose levels each fill the range of the type that indexes them,
so no lookup needs a bounds check. It also writes two tests: every line of Unicode's
GraphemeBreakTest.txt, through each char tool at every byte, and a
census that puts every code point in texts whose char counts tell its
class apart.

## std.utf8

Runes in UTF-8 (RFC 3629). A rune is one Unicode scalar value, an `Int`
from 0 to 0xD7FF or 0xE000 to 0x10FFFF, which UTF-8 writes as one to
four bytes; a valid sequence has no overlong form, encodes no surrogate,
and nothing past U+10FFFF. Every index and size is in bytes. A reader
takes a `?String` and allocates nothing; `push_rune` appends to a
`String`. Each function with a twin in Go's `unicode/utf8` reads every
input, valid or not, as that twin does, so a Go port is a rename; [TEXT](TEXT.md) says
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
| `ascii_end(s: ?String, i: Int) -> Int` | the index of the first byte at or after the cursor `i` that is 0x80 or more, or `s.len`: `s[i..ascii_end(s, i)]` is the run of ASCII from `i`, each byte a whole rune | |
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

`ascii_end` finds where a run of ASCII ends, testing many bytes at
once, so a reader can take the whole run and decode only the runes
after it. `rune_count` and `utf16.unit_count` count in blocks: valid
UTF-8 holds one rune for each byte that is not a continuation byte,
and one more unit for each first byte of a rune of four, so whole
blocks of 64 and then 16 bytes are counted by their bytes, each checked
valid as it is counted. The rest is read rune by rune: everything from
the first block that is not valid, a sequence the last valid block cut
short (from its first byte), and the 15 or fewer bytes after the last
whole block. Either way each bad byte is one rune of one unit, as in
Go.

```rig
use std.utf8
use std.utf16

sub main()
  s = "let caf\u{e9} = 1"
  i = 0
  while i < s.len
    j = utf8.ascii_end(s, i)
    print(i, j, s[i..j])
    i = j + utf8.rune_after(s, j).size if j < s.len else j
  t = "a\u{e9}\u{1f600}\xff"
  print(utf8.rune_count(t), utf16.unit_count(t), utf8.ascii_end(s, s.len))
```

```output
0 7 let caf
9 13  = 1
4 5 13
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
| `is_high_surrogate(u: Int) -> Bool` | whether `0xD800 <= u < 0xDC00`, the first unit of a pair | |
| `is_low_surrogate(u: Int) -> Bool` | whether `0xDC00 <= u < 0xE000`, the second unit of a pair | |
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
  print(utf16.is_high_surrogate(p.hi), utf16.is_low_surrogate(p.hi), utf16.is_low_surrogate(p.lo))
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
true false true
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
| `is_space(r: Int) -> Bool` | whether `r` is one of the 25 runes of White_Space |

```rig
use std.unicode

sub main()
  print(unicode.is_id_start(0x61), unicode.is_id_start(0x30), unicode.is_id_continue(0x30))
  print(unicode.is_id_start(0x2118), unicode.is_id_start(0xB7), unicode.is_id_continue(0xB7))
  print(unicode.is_id_start(0x2E2F), unicode.is_id_continue(0x200C), unicode.is_id_start(0x4E00))
  print(unicode.is_space(0x20), unicode.is_space(0x85), unicode.is_space(0x3000), unicode.is_space(0xFEFF))
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
| `(!doc).parse(src: ?String) -> Bool keeps src` | read all of `src` into `doc`'s tape: `true`, or `false` with `doc.error` and `doc.error_pos` set |
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
