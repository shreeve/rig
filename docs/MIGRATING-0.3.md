# Migrating to Rig 0.3

Rig 0.3.0 renames several of 0.2's types and spellings and rejects some
forms 0.2.9 accepted. This page takes a program written for `v0.2.9` to
0.3.0, in order: the scripts first, then the spellings no script
rewrites, then the forms the compiler now asks you to write another
way. [CHANGELOG](../CHANGELOG.md) ("Upgrading from v0.2.9") lists every
form 0.2.9 accepted that 0.3.0 rejects; a later section covers
programs written against `main` between the two releases, and the last
takes a 0.3.0 program to [0.3.1](#from-030-to-031).

Commit first: each script rewrites text in place. Run them from the
checkout of Rig whose `bin/rig` you will use, and run `rig check` on
your program after each step.

## Step 1: the renames, `tools/migrate-0.3.py`

```sh
python3 tools/migrate-0.3.py --dry-run src/   # the diff of what would change
python3 tools/migrate-0.3.py apply src/       # rewrite in place
```

It rewrites every `.rig` file under the path, the cases of its
`.rig.test` files, and the ```` ```rig ```` blocks of its Markdown:

| 0.2.9 | 0.3.0 |
|---|---|
| `struct Point` | `obj Point` |
| `Box[T]`, `Box(v)` | `^T`, `^v` |
| `Vec[T]`, `Vec()` | `List[T]`, `List()` (a type of your own named `List` becomes `Chain`) |
| `Text`, the owned text | `String` |
| `String`, the read view of text | `?String` (`String?` is `(?String)?`) |
| `fun get(?self)`, `!self`, `<self` | `fun get(?@)`, `!@`, `<@` |
| a typed self, `self: ?Self`, `self: P` in `P` | `?@`, `<@` |
| `self.x`, `self.m()`, `self` in a method | `@x`, `@m()`, `@` |
| `:outer for`, `break :outer`, `continue :outer` | `$outer: for`, `break $outer`, `continue $outer` |
| `@size(T)`, `@name(T)`, `@intCast(x)` under `raw` | `$size(T)`, `$name(T)`, `$intCast(x)` |
| `const x = e`, `new const x = e` | `x =! e`, `new x =! e` |

A file that spells none of `Vec[`, `Vec(`, `Box[`, `Box(`, or `Text` is
taken as 0.3 already for the first renames; name such a 0.2 file after
`--force` (`apply src/ --force src/greet.rig`) to rename its `String`
too. Self, labels, built-in calls, `const`, and `struct` are renamed in
every file: 0.3 rejects each old spelling, so the rename is safe on any
file, and a second run changes nothing. Strings and comments keep
their words. The script prints `MANUAL path:line` for each thing it
cannot decide: a self with no type or a handle's (`self`,
`self: *Self`), a label after `=>`, `defer`, or `errdefer`, a
`!String`, a ```` ```rig reject ```` block, which may show the old
spelling rejected on purpose, and a loop's write view that 0.3 holds
where 0.2.9 copied it (below, "A loop's write view is held, not
copied").

```rig reject
struct Point
  x: Int
```

```error
Rig has no `struct`; write `obj Name`
```

```rig
obj Point
  x: Int
  name: String

fun label(s: ?String) -> ?String
  s

sub main()
  xs: List[Int] = List()
  !xs.push(3)
  b = ^Point(x: 1, name: String("p"))
  print(label("a"), xs.len, b.x, b.name)
```

```output
a 1 1 p
```

A method declares self `?@`, `!@`, or `<@`, with no type, and its body
names it `@`; `self` is an ordinary name now.

```rig reject
obj P
  x: Int

  fun get(?self) -> Int
    self.x
```

```error
sigil-prefixed parameter is only allowed for self, `@`
```

```rig
obj P
  x: Int

  fun get(?@) -> Int
    @x

  sub bump(!@)
    @x += 1

sub main()
  p = P(x: 1)
  !p.bump()
  print(p.get())
```

```output
2
```

A label is `$outer:` where it is declared and `$outer` after `break`
or `continue`; it was `:outer` in both places.

```rig reject
sub main()
  :outer for i in 0..3
    print(i)
```

```error
unexpected keyword `for`
```

```rig
sub main()
  $outer: for i in 0..3
    for j in 0..3
      break $outer if j == 1
      print(i, j)
```

```output
0 0
```

The compiler's own functions, `@size(T)`, `@align(T)`, `@name(T)`, and
Zig's under `raw` (`@truncate(x)`, `@intCast(x)`, ...), are `$size(T)`,
`$truncate(x)`: `@` is self.

```rig reject
sub main()
  print(@size(Int))
```

```error
use of unbound name `@`
```

```rig
sub main()
  x: U64 = 300
  raw
    a: U8 = $truncate(x)
    print($size(Int), a)
```

```output
8 44
```

A fixed binding is `x =! e`, and a module-level binding needs neither:

```rig reject
sub main()
  const lim = 10
  print(lim)
```

```error
Rig has no `const`; write `x =! e`
```

```rig
LIMIT = 10

sub main()
  lim =! 10
  print(lim + LIMIT)
```

```output
20
```

## Step 2: the spellings no script rewrites

Rewrite these by hand; each is rejected with the new spelling in its
message.

### `swap` replaces `replace`

`replace(!place, v)`, which stored `v` and gave back the old value, is
`swap(!place, v)`; `swap(!a, !b)` still exchanges two places. A Cell's
`c.replace(v)` is `(!c).swap(v)`.

```rig reject
sub main()
  a = 1
  old = replace(!a, 10)
  print(old, a)
```

```error
use of unbound name `replace`
```

```rig
sub main()
  a = 1
  old = swap(!a, 10)
  c = *Cell(5)
  was = (!c).swap(6)
  print(old, a, was, c.get())
```

```output
1 10 5 6
```

### A drop is `<x`

A statement `-x` dropped `x` in 0.2; `<x` alone on a line drops it now,
and `-x` negates.

```rig reject
sub main()
  s = String("a")
  -s
  print(1)
```

```error
this expression does nothing as a statement; to drop `s` now, write `<s`
```

### Smaller renames

| 0.2.9 | 0.3.0 |
|---|---|
| `w.upgrade()` of a weak handle | `*w` (`if *w as h`) |
| `[N: Int]`, a compile-time value parameter | `[n: Int]`; a type parameter starts with a capital letter, `[t]` is `[T]` |
| `text.valid_utf8(bytes)` | `utf8.is_valid(s)` (`use std.utf8`) |
| `lib.Vec[Int]()`, `lib.Cell(1)`: a built-in named through a module | `List[Int]()`, `Cell(1)` (#646) |
| a function named `panic` | another name: `panic` is a keyword |
| a type named `Task`, `Tasks`, `Chan`, `Actor`, `Frozen`, `Simd`, `Symbol`, `Static`, `Int`, `Float`, `Bool`, or a sized number | another name: each is a built-in type |
| an enum variant named `none` | another name |

## Step 3: public generics state their bounds, `tools/state-bounds.py`

A `pub` generic names, by bounds, everything its body does with each
type parameter, and the `Print` of one it passes to a generic that
prints it. 0.2.9 checked each instance instead.

```sh
python3 tools/state-bounds.py --dry-run src/main.rig   # print the diff
python3 tools/state-bounds.py src/main.rig             # write the bounds
```

Run it once for each module directory, one run at a time: two runs over
the files of one directory race on the module they share.

```rig reject
pub fun twice[T](x: T) -> T
  x + x
```

```error
`pub fun twice[T]` adds `T`s: write `[T: Num]`
```

```rig
pub fun twice[T: Num](x: T) -> T
  x + x

sub main()
  print(twice(2), twice(1.5))
```

```output
4 3.0
```

## Step 4: the standard library's renames, `tools/migrate-std-0.3.py`

```sh
python3 tools/migrate-std-0.3.py --dry-run src/   # what would change
python3 tools/migrate-std-0.3.py src/             # rewrite in place
```

It rewrites the `.rig` and `.rig.test` files under the path and the
```` ```rig ```` blocks of its Markdown, finding a module used under
another name (`use std.text as stdtext`) by that name:

| 0.2.9 | 0.3.0 |
|---|---|
| `doc = json.new_doc()`, then `if not (!doc).parse(s)` and a block that leaves | `doc = json.parse(s) catch \|_\|` and the block |
| `return x if not (!doc).parse(s)` after `json.new_doc()` | `doc = json.parse(s) catch return x` |
| `json.new_doc()` | `json.Doc()`, filled by `(!doc).load(s)!` |
| `doc.size()`, `doc.get_int(i)`, `get_str`, `get_bool`, `get_float` | `doc.len`, `doc.int(i)`, `string`, `bool`, `float` |
| `text.compare(a, b) < 0`, a BigInt's `a.compare(b) > 0` | `a.order(?b) == .less`, `a.order(b) == .greater`: each comparison with 0 has its `Order` |
| `c = a.compare(b)`, every use of `c` comparing it with 0 | `c = a.order(b)`, with each use's `Order` |
| a BigInt's `a.equals(b)`, `not a.equals(b)`, `a.to_f64()` | `a == b`, `a != b`, `a.to_float()` |
| `math.powf(x, y)`, `math.powf(2, -1)` | `math.pow(x, y)`, `math.pow(2.0, -1.0)`: an integer literal powf took as a Float is written as one |
| `iter.count(!it)`, `iter.sum(!it) ?? 0` | `(!it).count()`, `(!it).sum()`; `use std.iter` goes |
| `slices.contains(xs, <s)`, `+s`, `a if c else b`, and the same in `index_of`, `sort.search`, `sort.lower_bound` | `slices.contains(xs, ?s)`, `?(a if c else b)` |

It prints `MANUAL path:line` for what it leaves: a `compare` result used
as an `Int` (returned, passed on, or added), a parse whose `Bool` is
used otherwise, a Doc's `error` and `error_pos`, `json.error_name`, an
`iter.sum` whose `none` is used or whose `?? 0` has more after it, a
`powf` of arguments not visibly Floats (`pow` of two `Int`s is an
Int's), a `-` before a `compare`, and a ```` ```rig reject ```` block.
Write `a.order(?b)` and compare it with `.less`, `.equal`, or
`.greater`, or `<`; a failure of `json.parse` or `load` is a member of
`JsonError` carrying its offset, `JsonError.eof(at: 5)`, which prints
so and which `match` takes apart. On Trig's sources it rewrites 38
sites and leaves 22: 20 `compare` results used as an `Int`, a `powf` of
two `Number`s, and one test's parse.

```rig reject
use std.json

sub main()
  doc = json.new_doc()
  print(doc.size())
```

```error
no member `new_doc` in module `json`; an empty Doc is `json.Doc()`, and `json.parse(?src)!` parses into a new one
```

```rig
use std.bigint
use std.json

sub main()
  doc = json.parse("{\"n\": 12345678901234567890}") catch |e|
    print(e)
    return
  print(doc.len, doc.kind(2), doc.float(2))
  a = bigint.parse("12345678901234567890") catch bigint.from_int(0)
  b = bigint.from_int(1).shl(64)
  print(a < b, a == b, a.order(?b), b.to_float())
  _ = json.parse("[1,") catch |e|
    match e
      .eof(at) => print("cut short at", at)
      _ => print(e)
    json.Doc()
```

```output
4 .float 12345678901234567000.0
true false .less 18446744073709552000.0
cut short at 3
```

`random.int` draws by Lemire's method, one multiply in place of two
divisions, so a seeded generator's `int`, and the `shuffle` built on
it, give other numbers than 0.2.9's for the same seed; `next` and
`float` give the same. A test that pins a seeded `int` or `shuffle`
records the new ones.

## Step 5: what the compiler now asks for

### A loop's write view is held, not copied

One form changes meaning rather than failing. A binding with no type of
a loop's value that is a write view at every `break` holds the write
view, as a binding of an `if` does, so assigning the binding writes
through. 0.2.9 copied the value. `tools/migrate-0.3.py` prints a
`MANUAL` line for each such binding and rewrites none: a value counts
as a write view where it is a lend of a path (`!x`, `!x.f`, `!x[i]`) or
a call of a function the program, or a module it uses, declares
returning `!T`. 2 of the 4,836 v0.2.9 programs have the shape, at one
site each. Give the binding its value's type to copy, as before, or
keep the view where writing through is what you want:

```rig
fun slot(a: !Int) -> !Int
  a

sub main()
  n = 12
  copy: Int = loop
    break slot(!n)
  copy = 1
  held = loop
    break slot(!n)
  held = 5
  print(n, copy)
```

```output
5 1
```

### A write view is not re-pointed at an arm's payload

A write view re-pointed inside a `match` arm at the payload the arm
binds is rejected, since the binding ends with the arm. Write through
the binding inside the arm:

```rig
enum Bx
  has(v: List[Int])
  nothing

sub main()
  v = List[Int]()
  !v.push(7)
  o = Bx.has(<v)
  match !o
    .has(p) => p[0] = 3
    .nothing => pass
  match o
    .has(p) => print(p[0])
    .nothing => pass
```

```output
3
```

What is left the compiler reports with the form to write. The common
ones:

### A value that holds a Cell lives behind `*`

An object, enum, or List element holding a `Cell` or a `Signal` is made
behind a shared handle, `*C(...)`, and every call that changes a Cell
or a Signal is marked with `!`: `!c.set(v)`, `(!c).swap(v)`,
`!s.subscribe(f)`, `(!b.c)[i] = e`. A read view of a Cell no longer
changes it.

```rig reject
obj C
  c: Cell[Int]

sub main()
  x = C(c: Cell(1))
  x.c.set(2)
  print(x.c.get())
```

```error
`C(c: Cell(1))` makes a `C`, which holds a Cell, so it lives only behind a shared handle: write `*C(c: Cell(1))`
```

```rig
obj C
  c: Cell[Int]

sub main()
  x = *C(c: Cell(1))
  !x.c.set(2)
  print(x.c.get())
```

```output
2
```

### A write call whose `Bool` value is used is parenthesized

`!v.push(x)` and `x = !v.pop()` are written short; where a call's `Bool`
value is used, the `!` and its place go in parentheses, so it never
reads as `not`.

```rig reject
sub main()
  seen = Set[Int]()
  if !seen.add(1)
    print("new")
```

```error
write `(!seen).add(1)`: a write call whose `Bool` value is used puts its `!` in parentheses, so it never reads as `not`
```

```rig
sub main()
  seen = Set[Int]()
  if (!seen).add(1)
    print("new")
  v = List([1, 2])
  x = !v.pop()
  print(x ?? 0, v.len)
```

```output
new
2 1
```

### A sigil before a `for` source's method call lends its self

`for x in <b.items()` took the List `items` made, with `<` as the loop's
mode. A sigil before a method call lends the call's self, in a `for`
header as anywhere, so `<` there is checked against the method, and one
that does not consume `self` is rejected. The loop consumes a List the
call makes without it, and `!b.drain()` lends `b` to write.

```rig reject
obj Bag
  xs: List[Int]

  fun items(?@) -> List[Int]
    +@xs

sub main()
  b = Bag(xs: List([1, 2]))
  for x in <b.items()
    print(x)
```

```error
`items` does not consume `self`; remove the `<`: a call's result moves without it
```

```rig
obj Bag
  xs: List[Int]

  fun items(?@) -> List[Int]
    +@xs

  fun drain(!@) -> List[Int]
    swap(!@xs, List())

sub main()
  b = Bag(xs: List([1, 2]))
  for x in b.items()
    print(x)
  for x in !b.drain()
    print(x * 10)
  print(b.xs.len)
```

```output
1
2
10
20
0
```

### Spacing decides an operator

An operator has the same spacing on both sides, and a bracket, a call's
parenthesis, a member's `.`, and a postfix `?` touch what they follow:
`x -1`, `a <b`, `a *b`, `steps= 1`, `n.. 3`, `a [1]`, `obj Wrap [T]`,
`xs .len`, `. red`, and `f(x) ?` are each rejected with the two
spellings they could mean (`x - 1`, or `x, -1`).

```rig reject
sub main()
  x = 3
  print(x -1)
```

```error
`x -1`: an operator has the same spacing on both sides; write `x - 1` to subtract, or `x, -1` to negate `1` as a value of its own
```

### `not` before a comparison, and a `catch` handler that chooses

`not a == b` is written `a != b` or `not (a == b)`. `catch` binds as `??`
does, so a handler that compares, joins with `and` or `or`, or chooses
with `if` is parenthesized.

```rig reject
error E
  bad

fun g() -> Int!
  return E.bad

sub main()
  x = g() catch |e| 1 if e == E.bad else 2
  print(x)
```

```error
use of unbound name `e`
```

```rig
error E
  bad

fun g() -> Int!
  return E.bad

sub main()
  a = 1
  x = g() catch |e| (1 if e == E.bad else 2)
  print(x, not (a == 2))
```

```output
1 true
```

### A closure's last line keeps its `)`

A closure body written below its bar list ends with the line; the `)`
that closes the call goes on the next line, at the indentation of the
line that opened it.

```rig reject
fun apply(f: ?fun(Int, Int) -> Bool) -> Bool
  f(1, 2)

sub main()
  print(apply(|a, b|
    a < b))
```

```error
a closure body below its bar list ends with `)` on a line of its own
```

```rig
fun apply(f: ?fun(Int, Int) -> Bool) -> Bool
  f(1, 2)

sub main()
  print(apply(|a, b|
    a < b
  ))
```

```output
true
```

### `time.sleep` can fail

It fails with `task.Stop` when its task is canceled: write
`time.sleep(d)!` in a function that can fail, or catch it.

```rig
use std.time

sub main()!
  time.sleep(ns: 1)!
  print("slept")
```

```output
slept
```

### A float provides no `Ord`

A NaN is neither below nor above a number, so a float provides no
`Ord` (SPEC "Floats in order"), and what 0.2.9 ordered by it panicked
on a NaN or, under `--release=fast`, did anything. `<` on two floats
stays. `tools/migrate-float-min.py RIG main.rig` (or `RIG --tests
src/pkg` for a directory module) rewrites each `math.min`, `math.max`,
and `math.clamp` of floats the compiler rejects as the float's own
method, running `rig check` until none is left, and prints the other
rejections as MANUAL lines:

| 0.2.9 accepted | 0.3.0 asks for |
|---|---|
| `math.min(a, b)`, `math.max(a, b)`, `math.clamp(x, lo, hi)` of floats | `a.min(b)`, `a.max(b)`, `x.clamp(lo, hi)`, where a NaN loses to a number (the script) |
| `sort.sort(!xs)` of floats | `sort.sort_by(!xs, \|a, b\| a.total_order(?b) == .less)` |
| `sort.sort_by_key(!xs, key)` with a float key | `sort.sort_by` comparing `key(a).total_order(?key(b))` |
| `sort.lower_bound`, `sort.search` of floats | a search written with `total_order`, or integer keys |
| `obj V: Ord` or `enum E: Ord` with a float field | its own `fun order(?@, other: ?V) -> Order`, with `total_order` for the float |
| `x.order(?y)` of floats | `x.total_order(?y)` |
| `[T: Ord]` of a program's own at `Float` | a `T: Num` bound where the body uses only `<` and arithmetic |

### A pattern is tested with `matches`

`as` names a value, and `matches` tests a pattern (SPEC "Testing a
pattern: `matches`"), so `if s as .circle(r)` is `if s matches
.circle(r)`, and `x as .p` is rejected with that fix.
`tools/migrate-matches.py PATH...` rewrites each `as` before a `.` and
a name, in `.rig` and `.rig.test` files and in a Markdown file's code;
`as` that names a value (`if o as x`, `use m as n`) stays.

### A pattern binds fields by name

A pattern binds a variant's fields by name (SPEC "match"): `:w` binds
the field `w` under its own name, `w: width` binds it as `width`, and a
variant with one field binds it by position too, `.circle(r)`. Binding
by position over several fields is rejected, since a reorder of the
fields would rebind it without a word, and so are the second spellings:

| 0.2.9 accepted | 0.3.0 asks for |
|---|---|
| `.rect(w, h)`, `.rect(h, w)` | `.rect(:w, :h)`, `.rect(w: h, h: w)` |
| `.between(_, close, _)` | `.between(:close)` |
| `.run(_?, none)` | `.run(id: _?, note: none)` |
| `.rect(w: w)`, `.ready(note: note?)` | `.rect(:w)`, `.ready(:note?)` |
| `.rect(_, _)`, `.circle(_)`, `.rect(w: _)`, `.dot()` | `.rect`, `.circle`, `.rect`, `.dot` |
| `.rect(w: _, h: tall)` | `.rect(h: tall)` |

`tools/migrate-patterns.py PATH...` rewrites each, after `matches` and
in a `match` arm, in `.rig` and `.rig.test` files and in Markdown's
```` ```rig ```` blocks, keeping each pattern's meaning: it reads each
variant's fields from the `enum` and `error` declarations of the files
it is given and of std. A pattern it cannot be sure of (a variant it
finds no declaration of, or two declarations of with different fields,
or a pattern Rig rejected already) it leaves, and prints as `MANUAL`.
Inside a pattern's parentheses `:x` names a field, never a symbol.

```rig
enum Region
  tag(name: Static, lang: Static)
  between(open: Static, close: Static, lang: Static)

fun closer(r: ?Region) -> U8
  match r
    .tag => '<'
    .between(:close) => close[0]

sub main()
  print(closer(.between(open: "(", close: ")", lang: "lisp")))
```

```output
41
```

### The rest

| 0.2.9 accepted | 0.3.0 asks for |
|---|---|
| `!T` as a field's or an element's type | hold the value, or pass `!x` to each call that writes it |
| `peek(!x)` where `peek` only reads | `peek(?x)`, or `x` where a copy goes |
| `r = b.first()`, binding a method's result that views self | `r = ?b.first()` |
| a function storing a view of a parameter in what its caller reaches | `keeps t` on its signature |
| `Box[Box[T]]`, `Box[*T]`, `*~T`, `Box(f)` of a function | one holding: `^T`, `*T`, or `~T`; a function is passed as it is |
| `BI(5)` where `type BI = Box[Int]` | `^5` |
| `b.read[U8, .big](i)`, a byte order on a one-byte type | `b.read[U8](i)` |
| `(?v).len`, `<(!s).o`: a lend of a path's base | `v.len`, `<s.o` |
| a method parameter named as a module-level declaration | another name |
| two files in one directory, used as two modules, declaring one name | a directory of its own for one of them: a directory's files are one module |
| `w = !s` of a `?String` | a `String`, to change text in place |
| `e == f` of two caught errors | `match` one, or compare it with a member (`e == E.bad`) |
| `_ = \|x\| x + 1`, a closure never called | call it, or remove it |
| `*g` of a function where a `*fun` goes | `*\|\| g()` |
| a lend of a branch that may be a named value, `(a if c else b)[0].m()` | lend each branch: `(?a if c else ?b)[0].m()` |
| a `defer` that changes what its scope's value views (`defer !@xs.clear()` before a last value `!@xs[0]`), or uses a write view `s` the scope returns | change it before the value is formed, or let the defer leave the value and `s` alone |
| `fun eq(?@, other: ?P) -> Bool` on an `obj P` whose header names no `Eq` (and `order`, `hash_into`, `print` with the signatures `Ord`, `Hash`, and `Print` fix) | `obj P: Eq`, so `==` calls it, or another name |
| a parameter `?^T`, a read view of a box | `?T`, which takes a `^T` too |
| `peek(+w)` where `peek` takes a read view, or `(+w).len()` of a `?@` method | `peek(?w)`, `w.len()` |
| a move or a take in the right side of `and` or `or`, or in a later part of `if a and b as x`, where a value it leaves alive views what is dropped after (`no() and take(<g)` then `<a`) | rejected (*unsound*: a drop body read freed memory); move it where it always runs, or drop the viewed value after the viewer |
| a store through more than 16 write views in a chain | "too complex for the ownership checker": lend fewer write views in a chain |

## Programs written against `main` between releases

A program that followed `main` after `v0.2.9` may use spellings that
changed again before 0.3.0. Each has a script or a one-line fix:

| Was on `main` | 0.3.0 | Rewritten by |
|---|---|---|
| `use std.hash`, `hash.Map[K, V]`, `hash.Set[K]` | `Map[K, V]`, `Set[K]`, built in | `tools/migrate-builtin-map.py PATH` |
| `Symbols()`, the string interner | `text.Interner()` (`use std.text`) | `tools/rename-interner.py PATH` |
| `rarely fun f()` | `rarely` as the body's first line | `tools/rarely-body.py FILE...` |
| `[T: Moves]`, `[T: Shares]`, `api Job: Moves` | `Sends`, `Syncs` | `tools/rename-task-bounds.py PATH` |
| `for x in it` over an iterator held in a place | `for x in !it` | by hand, as the compiler says |
| `b'A'`, `b"\n"` | `'A'`, `"\n"` where a `U8` or a `[N]U8` goes | by hand |
| `within:` on a set's wait, `wait_all`, `task.both` | `time.within(d, \|\| ...)`, `>ts`, `task.all` | by hand, as the compiler says |
| a public generic that nests itself through a call through an API on ever deeper instances | reported where it is declared, though nothing calls it (#647) | by hand |
| `.got(_) =>`, or a `_ =>` that covers nothing else, after `.got(v?)` and `.got(none)` of an enum | remove it: the two arms cover `.got` | by hand, as the compiler says |
| `task.select((!a).on_recv(\|v\| f(v)), (!b).on_send(<x, \|\| 0))!`, arms of closures | still accepted; `match task.select(a: !a.on_recv(), b: !b.on_send(<x))!` with arms `.a(v) => f(v)` and `.b => 0`, which goes in the next release | `tools/migrate-select.py PATH` (`MANUAL` for a closure over several lines, a copy captured in (`\|+k, v\|`) that another arm names, a `catch` after the select, a select in an expression) |
| `for x in !(!b).items()` | `for x in (!b).items()`, which walks the `!List` the call gives for writing | by hand, as the compiler says |
| a sigil before a chain in a `for` header that the chain dropped: `<xs.filter(f)`, `?mk().filter(f)`, `<mk().filter(f)`, `!b.each().filter(f)` of a `?@` `each`, `?it.filter(f)` of an iterator | `(<xs).filter(f)` to take `xs` or `xs.filter(f)` to walk it; no sigil; `(!it).filter(f)` | by hand, as the compiler says |
| a chain whose result keeps its source lent, bound or returned unmarked: `vs = names.filter(f).collect()`, `f = names.find(g)`, `y = ps.min_by(k) ?? return` | `vs = ?names.filter(f).collect()`, `?names.find(g)`, `?ps.min_by(k)` | by hand, as the compiler says |
| a view escaping a block that holds a chain or a padded closure (`best = ?qs[0]` beside `xs.filter(f).count()`) | rejected, as in any block (*unsound*: it read freed memory); keep the viewed value alive as long as the view | by hand |
| `x += 10` in `for x in xs.filter(f)`, which changed a copy | `for x in !xs` to change the elements, or `new y = x` for a copy | by hand, as the compiler says |
| `z = <x` in `for x in src` of a read view `src = ?a`, or of a view in a field | as in `for x in ?a`: clone what the loop view reaches, or loop over `<a` to take the elements | by hand, as the compiler says |
| an arm of `task.select` that reads, takes, or writes what another arm's closure or channel uses: `<s` beside `\|?s, v\|`, `n` sent beside `\|!n, v\|`, two arms' `\|!n, v\|`, `<a` beside `(!a).on_recv(...)`, `<chs` beside `(!chs[0])` | rejected: every arm is made before the select runs one; bind what the arms share before the select, or give each its own | by hand |
| a task in a Cell, `*Cell(<t)`, or a value holding one there; `break t` of a task lent to write | rejected: wait for the task, and keep what it gives | by hand, as the compiler says |
| a value holding a task (a local object, a `Task[T]?`, a `*Job`, a `time.within` closure's result), then its source written or dropped before the wait | rejected (*unsound*: the task read the source after it changed or was dropped): wait for the task first | by hand, as the compiler says |
| a `-> Task[T]` function lent a parameter its task does not read, then that parameter's owner written before the wait; `b.spawn()` of a `?@` method that gives a task | the caller keeps the lend until the wait: wait first, or take the parameter away; write `?b.spawn()` | by hand, as the compiler says |

A program that used `(!doc).load(?src)` and `JsonError.bad(kind:,
at:)` on `main` matches the reason itself, `.eof(at)`, and drops
`json.error_name`; the rest of std.json is Step 4's.

```rig
api Job: Sends
  fun run(?@) -> Int

obj Add: Job
  n: Int

  fun run(?@) -> Int
    @n + 1

fun hand[T: Sends + Clone](x: T) -> T
  +x

sub main()
  print(hand(3), Add(n: 1).run())
```

```output
3 2
```

## From 0.3.0 to 0.3.1

0.3.1 changes what a duration means: a bare number is seconds, where
0.3.0 read nanoseconds, so `time.sleep(5)` sleeps five seconds. Any
other unit is written with its keyword, and the value of each form may
be an `Int` or a `Float` ([SPEC "Durations"](../SPEC.md#durations)):

```rig
use std.time

sub main()!
  time.sleep(0.001)!       # a millisecond, in seconds
  time.sleep(ms: 1)!
  time.sleep(us: 40)!
  time.sleep(ns: 40)!
  print("slept")
```

```output
slept
```

`tools/migrate-durations.py` rewrites every duration a 0.3.0 program
writes so that it means what it meant. Run it once, on 0.3.0 sources:
a bare number it wrote cannot be told from one written for 0.3.1.

```sh
python3 tools/migrate-durations.py --dry-run src/   # what would change
python3 tools/migrate-durations.py src/             # rewrite in place
```

| 0.3.0 | 0.3.1 |
|---|---|
| `time.sleep(40 * time.MS)`, `time.sleep(time.MS)` | `time.sleep(ms: 40)`, `time.sleep(ms: 1)` |
| `time.sleep(5 * time.US)` | `time.sleep(us: 5)` |
| `time.sleep(2 * time.SECOND)`, `3 * time.MINUTE` | `time.sleep(2)`, `180` |
| `time.sleep(1_000_000)`, a literal | `time.sleep(ms: 1)`, the largest unit that counts it whole |
| `time.sleep(d)`, any other value | `time.sleep(ns: d)` |
| `time.within(d, work)` | `time.within(ns: d, f: work)`: an argument after a keyword is named |
| `late: time.after(50 * time.MS)` | `late: time.after(ms: 50)` |
| `time.Instant.at(5)`, `t.add(3 * time.SECOND)` | `time.Instant.at(ns: 5)`, `t.add(3)` |
| `task.supervise(f, per: time.MINUTE)`, `per: 1000` | `per: 60`, `per: 0.000001`: `per:` is seconds |

It rewrites `.rig` and `.rig.test` files and the ```` ```rig ```` blocks
of Markdown, and prints each rewrite. Two it cannot settle it prints
for you to look at: `MANUAL` for a `per:` whose seconds it cannot count
as written (`per: n`: write `per: Float(n) / 1e9`, or better, keep the
seconds in `n`), and `CHECK` for an `.add(...)` it took for an
Instant's because its argument names a constant of std.time. An
Instant's `add` of a value with no constant in it, `t.add(n)`, it does
not find: write `t.add(ns: n)` by hand.

The compiler rejects the forms that would change meaning silently: a
bare duration that names one of std.time's constants, which count
nanoseconds (`time.sleep(5 * time.MS)`, rejected for `ms: 5`), and
`per: time.MINUTE`. What a clock gives back is still an `Int` of
nanoseconds, so `t.elapsed() < 5 * time.MS` stays as it was, and a
duration taken from one is passed on with `ns:`, `t.add(ns:
t.since(u))`.

### `loop` for `while true`, and no loop `else`

`loop` is a keyword: the loop that repeats until a `break`, and the one
that gives a value, `r = loop` ... `break v`. A `for` or `while` gives
no value, a `break` in one carries none, and no loop has an `else`.
`tools/migrate-loops.py` rewrites each `while true` to `loop`, and
flags, without rewriting, each loop `else`, each `for` or `while` used
as a value, and each `break v` outside a `loop`, with a suggested
rewrite:

```sh
python3 tools/migrate-loops.py --dry-run src/   # what it would rewrite, and what it flags
python3 tools/migrate-loops.py src/             # rewrite in place
```

| 0.3.0 | 0.3.1 |
|---|---|
| `while true` | `loop` |
| `for x in xs` ... `else` (no `break` was taken) | `if not xs.any(f)`, or a name set before the `break` and tested after |
| `r = for x in xs` ... `break x if f(x)` ... `else d` | `r = xs.find(f) ?? d`, or a function that returns from its loop |
| `i = for x, j in xs` ... `break j if x == t` ... `else -1` | `i = xs.index_of(t) ?? -1` on a List |
| a name `loop`, `file.FileError.loop` | another name, `file.FileError.link_loop` |
