# Migrating to Rig 0.3

Rig 0.3.0 renames several of 0.2's types and spellings and rejects some
forms 0.2.9 accepted. This page takes a program written for `v0.2.9` to
0.3.0, in order: the scripts first, then the spellings no script
rewrites, then the forms the compiler now asks you to write another
way. [CHANGELOG](../CHANGELOG.md) ("Upgrading from v0.2.9") lists every
form 0.2.9 accepted that 0.3.0 rejects; the last section here covers
programs written against `main` between the two releases.

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
type parameter. 0.2.9 checked each instance instead.

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

## Step 4: what the compiler now asks for

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
  copy: Int = while true
    break slot(!n)
  copy = 1
  held = while true
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

### A write call whose value is used is parenthesized

`!v.push(x)` stands alone as a statement; where the call's value is
used, the `!` and its place go in parentheses.

```rig reject
sub main()
  v = List([1, 2])
  x = !v.pop()
  print(x ?? 0)
```

```error
write `(!v).pop()`: a write call whose value is used puts its `!` in parentheses
```

```rig
sub main()
  v = List([1, 2])
  x = (!v).pop()
  print(x ?? 0, v.len)
```

```output
2 1
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
`time.sleep(ns)!` in a function that can fail, or catch it.

```rig
use std.time

sub main()!
  time.sleep(1)!
  print("slept")
```

```output
slept
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
| `within:` on a set's wait, `wait_all`, `task.both` | `time.within(ns, \|\| ...)`, `>ts`, `task.all` | by hand, as the compiler says |
| a public generic that nests itself through a call through an API on ever deeper instances | reported where it is declared, though nothing calls it (#647) | by hand |

`std.json` needs no change: `(!doc).parse(?src)` still answers a
`Bool`, and `(!doc).load(?src)`, which fails with
`JsonError.bad(kind:, at:)`, is new beside it.

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
