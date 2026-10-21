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
checked like any call. This page lists everything it has.

`RIG_STD=dir` makes `rig` read the standard library from `dir` in
place of the copy built into it. It is a setting for developing the
library, whose modules may bind Zig files; a program's own modules are
never read as the library's.

| Module | What it offers |
|---|---|
| [`std.math`](#stdmath) | number helpers, and Float functions |
| [`std.bigint`](#stdbigint) | integers of any size: parsing, printing, arithmetic, shifts, powers, and the nearest Float |
| [`std.os`](#stdos) | the program's arguments and environment |
| [`std.file`](#stdfile) | reading and writing files, whole or open, making, moving, and removing them, and asking what is at a path |
| [`std.io`](#stdio) | copying bytes between files and sockets: `copy` |
| [`std.time`](#stdtime) | clocks and sleeping |
| [`std.task`](#stdtask) | stopping a task, waiting for several, and isolating a panic: `Stop`, `check`, `all`, `isolate`, `workers` |
| [`std.par`](#stdpar) | calling a function on each element on several tasks: `map`, `each` |
| [`std.net`](#stdnet) | TCP connections: listening, accepting, connecting, reading, and writing |
| [`std.http`](#stdhttp) | an HTTP/1.1 server: `serve`, requests, and responses |
| [`std.target`](#stdtarget) | the target the program is compiled for: its architecture |
| [`std.random`](#stdrandom) | a seedable pseudorandom generator |
| [`std.sort`](#stdsort) | sorting slices, and searching sorted ones |
| [`std.slices`](#stdslices) | reversing and linear search |
| [`std.hash`](#stdhash) | Map and Set: hash tables that keep insertion order; Symbols, dense ids for strings |
| [`std.text`](#stdtext) | searching, slicing, splitting, and parsing text |
| [`std.utf8`](#stdutf8) | runes: reading, writing, counting, and checking UTF-8 |
| [`std.utf16`](#stdutf16) | units: UTF-16 lengths and positions, and surrogate pairs |
| [`std.unicode`](#stdunicode) | rune properties: widths, white space, and identifier classes |
| [`std.json`](#stdjson) | a JSON parser (experimental) |
| [`std.terminal`](#stdterminal) | a terminal emulator as a library: bytes in, screen out (experimental) |

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

The Float constants NaN and infinity, and `frexp` (`fraction` and `exponent`), are methods of the number types, not of this module: `Float.nan()`, `Float.inf()`, `x.fraction()`, `x.exponent()` ([SPEC](../SPEC.md#numeric-conversions)).

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

## std.bigint

`BigInt` is an integer of any size, written in Rig: a sign and a
magnitude of 64-bit limbs on the heap, kept normalized, so zero has no
limbs and is never negative. A BigInt owns its limbs, so it moves
(`b = <a`) and `clone` makes a second one. Its fields are private: a
BigInt is made by `parse` or `from_int`, or by an operation on others.

Every operation that makes a BigInt allocates one List for its limbs,
even when the result is zero, and `pow` one more List of the result's
size while it works. `text` allocates the String it returns,
and for a number of more than 8 limbs (about 154 digits) a copy of the
limbs to divide and a List of the 19-digit groups. `compare`, `equals`,
`sign`, `bit_len`, and `to_f64` only read, and allocate nothing.

| Member | Result |
|---|---|
| `bigint.parse(s: ?String, base: Int = 0) -> BigInt!` | the integer `s` writes, or `ParseError.invalid`; panics unless `base` is 0 or from 2 to 36 |
| `bigint.from_int(n: Int) -> BigInt` | `n` as a BigInt |
| `a.text() -> String` | the number in base 10: a `-` when it is negative, no leading zeros |
| `a.clone() -> BigInt` | a second BigInt of the same value |
| `a.compare(b: ?BigInt) -> Int` | -1, 0, or 1, as `a` is below, equal to, or above `b` |
| `a.equals(b: ?BigInt) -> Bool` | whether the two are equal |
| `a.sign() -> Int` | -1, 0, or 1 |
| `a.bit_len() -> Int` | the bits of the magnitude: 0 for zero, 64 for 2^63 |
| `a.add(b)`, `a.sub(b)`, `a.mul(b)` | the sum, difference, and product |
| `a.shl(n: Int) -> BigInt` | `a` times 2^n; panics when `n` is negative |
| `a.shr(n: Int) -> BigInt` | `a` divided by 2^n, rounded toward minus infinity as `>>` rounds, so -1 at the least for a negative number; panics when `n` is negative |
| `a.pow(e: Int) -> BigInt` | `a` to the power `e`, 1 when `e` is 0; panics when `e` is negative |
| `a.to_f64() -> Float` | the nearest `Float`, ties to even, and infinite past the largest |

`parse` reads Go's `Int.SetString` syntax: an optional sign, then
digits in `base`, upper or lower case. Base 0 reads the base from a
prefix, `0x`, `0o`, `0b`, or a bare `0` for octal, else 10, and allows
one `_` after the prefix or a digit; any other base reads no prefix
and no `_`. Anything else, an empty text or a space included, is
`invalid`.

```rig
use std.bigint

sub main()!
  a = bigint.parse("123456789012345678901234567890")!
  b = bigint.from_int(-42)
  print(a.mul(b).text())
  print(a.add(b).text(), a.sub(b).text(), a.compare(b), a.equals(a.clone()))
  print(bigint.parse("0xffff_ffff_ffff_ffff")!.add(bigint.from_int(1)).text())
  print(bigint.from_int(1).shl(100).text(), b.shr(4).text())
  print(bigint.from_int(3).pow(50).text(), bigint.from_int(10).pow(400).to_f64())
  print(bigint.parse("9007199254740993")!.to_f64(), (bigint.parse("1_000", 10) catch bigint.from_int(-1)).text())
```

```output
-5185185138518518513851851851380
123456789012345678901234567848 123456789012345678901234567932 1 true
18446744073709551616
1267650600228229401496703205376 -3
717897987691852588770249 inf
9007199254740992.0 -1
```

`9007199254740993` is 2^53 + 1, halfway between two `Float`s, and
rounds to the even one, 2^53; `"1_000"` in base 10 is `invalid`, as a
set base reads no `_`. A BigInt has no `==` or `<`, which would
hide a walk over the limbs; `equals` and `compare` name it.

```rig reject
use std.bigint

sub main()
  print(bigint.from_int(1) < bigint.from_int(2))
```

```error
operator `<` orders numbers, plain enums, Strings, and `[]U8` slices; got `bigint.BigInt`
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
| `cwd() -> String!` | the working directory, as an absolute path, its links resolved; fails with a `file.FileError` ([std.file](#stdfile)) when it was removed or cannot be read |

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

Files, and what is at a path. A relative `path` starts at the working
directory.

| Function | Result |
|---|---|
| `read(path: ?String) -> String?!` | the file at `path` as a fresh `String` of exactly its bytes; `none` when nothing is there |
| `write(path: ?String, data: ?String, parents: Bool = false)!` | writes `data` as the whole file at `path`, creating it or replacing what it holds |
| `append(path: ?String, data: ?String, parents: Bool = false)!` | writes `data` at the end of the file at `path`, creating it when it is not there |
| `exists(path: ?String) -> Bool!` | whether anything is at `path`, following symbolic links: a link that names nothing is not |
| `stat(path: ?String) -> Stat?!` | what is at `path`: its `kind`, whether it is a `link`, its `size`, and when it was `modified`; `none` when nothing is there |
| `read_dir(path: ?String) -> List[Entry]?!` | the entries of the directory at `path`, sorted by name, each with its `name`, `kind`, and `link`; `none` when nothing is there |
| `realpath(path: ?String) -> String?!` | the absolute path `path` names, every symbolic link in it resolved; `none` when nothing is there |
| `mkdir(path: ?String, parents: Bool = false)!` | makes the directory `path`; a directory there already is fine |
| `rename(from: ?String, to: ?String)!` | moves what is at `from` to `to`, replacing a file there |
| `remove(path: ?String) -> Bool!` | removes the file, or empty directory, at `path`: `true`, or `false` when nothing was there |
| `open(path: ?String) -> File?!` | the file at `path`, to read; `none` when nothing is there |
| `create(path: ?String, parents: Bool = false) -> File!` | the file at `path`, created or emptied, to write |

**`parents: true` makes the missing directories on the way.** `write`,
`append`, `create`, and `mkdir` take it, with one default everywhere,
as Python's `Path.mkdir(parents=False)` does: without it, a directory
on the way that is missing fails with `FileError.not_found`, so a typo
in a path is reported rather than made into a directory.

**`none` means nothing is there; every other failure is an error.** A
call that looks for something gives `none` only when nothing is at the
path (nothing by its name, or a file where a directory on the way to it
would be), and fails with a `FileError` for anything else: a path that may
not be read, a directory where a file is wanted, an I/O error. So
`file.read(p)! ?? String()` treats a missing file as empty and still
reports a file it may not read.

| Error | When |
|---|---|
| `not_found` | nothing is at the path, or at a directory on the way to it (an empty path), for a call that needs something there; a missing directory on the way without `parents: true` |
| `exists` | something is at the path already: `mkdir` where a file is |
| `denied` | the system does not allow it: permissions, or a read-only file system |
| `not_directory` | the path given `read_dir` names a file, or a file stands where a call that makes something needs a directory on the way |
| `is_directory` | the path names a directory, where a file is wanted |
| `not_empty` | `remove` of a directory that holds entries |
| `failed` | anything else: no space left, too many open files, an I/O error |

**Each call is a fallible waiting point.** It runs on the blocking pool
while its task waits, so other tasks go on; to do several at once, make
them tasks and wait with `>`, as for any call. Like a socket's calls
([std.net](#stdnet)), it fails with `task.Stop.canceled` in a canceled
task and with `task.Stop.timeout` past the task's deadline
(`time.within`): before it starts, and while it waits, so a cancel or a
deadline ends the wait for a call that blocks (a read of a pipe no one
writes). The call itself runs on to its end on the pool, and what it
gives is dropped: a write may still happen, and a file it opened is
closed.

A `File` reads and writes from where its last read or write ended, with
the methods a `net.Stream` has, and closes when it is dropped:

| Method | Result |
|---|---|
| `f.read(!@, into: !String, max: Int) -> Int!` | reads up to `max` bytes onto the end of `into`: how many, or 0 at the end of the file |
| `f.write(!@, bytes: ?String)!` | writes all of `bytes` |

```rig
use std.file

# Copy the file at `from` to `to`, a block at a time.
sub copy(from: ?String, to: ?String)!
  if file.open(from)! as src
    dst = file.create(to, parents: true)!
    buf = String()
    while (!src).read(!buf, 65536)! > 0
      (!dst).write(buf)!
      buf = String()

sub main()!
  copy("examples/hello.rig", "out/hello.rig")!
```

A `kind` is `Kind.file`, `Kind.directory`, or `Kind.other` (a device,
a pipe, a socket). `stat` and `read_dir` follow a symbolic link to give
the kind of what it names, and say with `link` that the path itself is
one; a link that names nothing is a link of kind `other`, so
`file.stat(p)! != none` asks whether anything is at `p`, a broken link
included, as Go's `os.Lstat` does, and `file.exists(p)!` whether what
is there leads anywhere, a broken link not, as Python's
`os.path.exists` and Go's `os.Stat` do. A `kind` of `Kind.file` asks
whether a file is there to read. `modified` is when the contents last
changed, in nanoseconds since 1970-01-01 00:00 UTC, of what a link
names. `read_dir` leaves out `.` and `..`, and sorts by the names'
bytes.

```rig
use std.file

sub main()!
  if file.stat("examples")! as s
    print(s.kind, s.link, s.modified > 0)
  if file.read_dir("examples")! as entries
    print(entries.len > 0, entries[0].kind)
  print(file.stat("no/such/file")! == none, file.realpath("no/such/file")! == none)
```

```output
.directory false true
true .file
true true
```

`read`'s bytes are the file's as they are: none added, and none checked
to be UTF-8, so a binary file reads as well as text. The `String` is
the caller's, like any other, and its buffer holds exactly the file's
bytes, with no spare room past them. A pipe or a device, which has no
size, is read to its end, so one that never ends (`/dev/zero`) is read
until memory runs out, and a pipe with no writer waits, as Go's
`os.ReadFile` does. A file too large for memory panics as any
allocation that fails does.

```rig
use std.file
use std.text

sub main()!
  if file.read("examples/hello.rig")! as source
    end = text.find(source, "\n") ?? source.len
    print(source[..end])
  print(file.read("no/such/file")! == none)
  _ = file.read("examples") catch |e|
    print(e)
    none
```

```output
# The smallest meaningful Rig program.
true
FileError.is_directory
```

The suite runs these examples from the repository's root, where
`examples/hello.rig` is.

`write` creates the file, or replaces what it holds; with
`parents: true` it first makes each directory on the way to it that is
missing, as Go's `os.MkdirAll` and `os.WriteFile` do together. None of
`write`, `append`, and `create` is atomic: a reader at the same time may see part of the bytes.
To replace a file whole, write another beside it and `rename` it over
the first.

```rig
use std.file

sub main()
  file.write("out/gen/main.zig.tmp", "pub fn main() void {}\n", parents: true) catch |e|
    print("cannot write:", e)
    return
  file.rename("out/gen/main.zig.tmp", "out/gen/main.zig") catch |e|
    print("cannot rename:", e)
```

## std.io

Moving bytes between what reads and what writes. A `file.File`
([std.file](#stdfile)) and a `net.Stream` ([std.net](#stdnet)) read and
write with the same two methods, `read(!@, into, max) -> Int!` and
`write(!@, bytes)!`, and `io.copy` takes either at each end.

| Function | Result |
|---|---|
| `copy(!from, !to) -> Int!` | reads `from` to its end, writing all of it to `to`, 64 KiB at a time: how many bytes |

It fails as the reads and writes fail, with a `file.FileError`, a
`net.NetError`, or a `task.Stop`, once what it read before has been
written. Rig has no interfaces, so the checker types the call, as it
does `http.serve`: each end must be a `file.File` or a `net.Stream`,
lent to write.

```rig
use std.file
use std.io
use std.net

# Send the file at `path` to the next client of `l`.
fun send_file(l: ?net.Listener, path: ?String) -> Int!
  c = l.accept()!
  if file.open(path)! as f
    return io.copy(!f, !c)!
  0
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
| `sleep(ns: Int)!` | wait at least `ns` nanoseconds; not at all when `ns` is not positive. In a canceled task it fails with `task.Stop.canceled` ([std.task](#stdtask)), and past a deadline with `task.Stop.timeout`, sleeping only until the deadline |
| `within[R](ns: Int, f: once ?fun() -> R!) -> R!` | run `f` with a deadline `ns` nanoseconds from now, and give what it gives: every fallible waiting point `f` reaches after the deadline fails with `task.Stop.timeout`, and the tasks it starts keep the deadline. `f` is called once, so it may move in a task, or a set, started before it and wait for it: `time.within(d, \|<t\| >t!)`. Inside another deadline, the earlier one holds ([SPEC §18](../SPEC.md#deadlines)) |
| `unix_ns() -> Int` | the wall clock, in nanoseconds since 1970-01-01 00:00 UTC; it can be set, so it may jump |

```rig
use std.time

sub main()!
  start = time.now()
  time.sleep(5 * time.MS)!
  print(start.elapsed() >= 5 * time.MS)
  print(time.now().since(start) > 0)
  print(time.unix_ns() / time.SECOND > 1_700_000_000)
```

```output
true
true
true
```

## std.task

Canceling a task ([SPEC §18](../SPEC.md#18-tasks)) asks it to stop. The
request reaches it as `Stop.canceled` at its next fallible waiting
point: `task.check()`, `time.sleep`, or a wait on a task that can fail.
It stays: every fallible waiting point the task reaches after it fails
too, so a `catch` cannot swallow it and carry on. Everything else the
task does finishes as it would. Past a deadline (`time.within`), the
same waiting points fail with `Stop.timeout`.

| Member | Result |
|---|---|
| `error Stop` | `canceled`, the request to stop, `timeout`, and `panicked` |
| `check()!` | a waiting point that waits for nothing: fail with `Stop.canceled` when this task is canceled, or `Stop.timeout` past its deadline, and otherwise give other threads a turn |
| `workers(n: Int) -> Bool` | run tasks on `n` workers, at most 64, in place of one per core or `RIG_WORKERS`: a program sets it from its own arguments, say. It takes effect only before the program makes its first task, which starts the workers, and gives whether it did; a deterministic run (`rig test`) runs on one thread whatever it asks |
| `all(a, b, ...)` | wait for two tasks or more, of any types, and give each one's value as several results; it can fail when any task can, and then the first to fail cancels the others |
| `isolate(f)` | run `f`, which takes nothing, and give what it gives; a panic in it, or in a task it started, stops here: its tasks are canceled, and it fails with `Stop.panicked` ([SPEC §18](../SPEC.md#isolating-a-panic)) |
| `supervise(f, restarts: n, per: ns)` | run `f` isolated, and again each time it fails or panics, at most `n` times within `ns` nanoseconds; past that, fail as its last run failed ([SPEC §18](../SPEC.md#isolating-a-panic)) |
| `select(arm, ...)` | wait until one arm, `(!ch).on_recv(f)` or `(!ch).on_send(<v, f)`, can complete, commit it alone, and give what its `f` gives ([SPEC §18](../SPEC.md#channels)) |

A long computation calls `task.check()!` where stopping is safe:

```rig
use std.task
use std.time

fun count() -> Int!
  n = 0
  while true
    task.check()!
    n += 1
  n

sub main()!
  t = count()&
  time.sleep(time.MS)!
  n = <t.cancel() catch |e|
    print(e)
    -1
  print(n)
```

```output
Stop.canceled
-1
```

## std.par

Calling a function on each element of a List, an array, or a slice, on
several tasks at once ([SPEC §18](../SPEC.md#each-element-on-several-tasks)).
The tasks take chunks of the elements in turn. `f` is a closure written
in the call, whose captures must share, or a function's name.

| Member | Result |
|---|---|
| `map(?xs, f, limit: n)` | a `List` of `f(x)` for each element, in the order of `xs`; `f` takes each as `?T` |
| `each(!xs, f, limit: n)` | call `f` on each element, as `!T`, which it may write |

`limit` is how many tasks run at once, by default one per worker; it
comes after `f`, or before a closure written last. When
`f` can fail, so can the call: the first failure cancels the rest, and
the call fails with its error.

```rig
use std.par

sub main()
  xs = List([1, 2, 3, 4])
  print(par.map(?xs, |x| x * x, limit: 2))
  par.each(!xs, limit: 2, |x| x *= 10)
  print(xs.sum())
```

```output
[1, 4, 9, 16]
100
```

## std.net

TCP connections. `listen` takes connections on an address, and
`connect` makes one; a `Stream` reads and writes bytes. Accepting,
connecting, reading, and writing are fallible waiting points
([SPEC §18](../SPEC.md#18-tasks)): a task waiting on one lets its
worker run others, and in a canceled task they fail with
`task.Stop.canceled`, past a deadline (`time.within`) with
`task.Stop.timeout`. A program that makes no tasks waits on its own
thread.

An address is `host:port`. The host is an IPv4 address, an IPv6
address in brackets (`[::1]:8080`), `localhost`, or nothing for every
address of the machine (`:8080`); port 0 lets the system choose one.
Host names are not looked up yet.

| Member | Result |
|---|---|
| `error NetError` | `address` (it does not parse, or names no host this can reach), `in_use`, `refused`, `reset`, `closed`, and `failed` (anything else the system reports) |
| `listen(addr)!` | a `Listener` taking connections on `addr` |
| `connect(addr)!` | a `Stream` connected to `addr`, once the connection is made |
| `l.accept()!` | the next connection, a `Stream`, once one comes; tasks that share the listener may each wait for one |
| `l.port()` | the port it listens on, the one the system chose for port 0 |
| `(!s).read(!into, max)!` | read up to `max` bytes onto the end of the String `into`, once any come: how many, or 0 once the other end has closed |
| `!s.write(bytes)!` | write all of `bytes`, a `?String` |

A `Listener` or `Stream` closes when it is dropped. Each connection is
usually a task of its own:

```rig
use std.net

fun echo(l: net.Listener) -> Int!
  c = l.accept()!
  buf = String()
  total = 0
  while true
    n = (!c).read(!buf, 4096)!
    if n == 0
      break
    total += n
    (!c).write(?buf)!
    buf = String()
  total

sub main()!
  l = net.listen("127.0.0.1:0")!
  port = l.port()
  t = echo(<l)&
  c = net.connect(String("127.0.0.1:", port))!
  (!c).write("hello")!
  got = String()
  while got.len < 5
    _ = (!c).read(!got, 100)!
  print(got)
  _ = <c
  print(>t!)
```

```output
hello
5
```

## std.http

An HTTP/1.1 server. `http.serve(<listener, f)` takes connections on a
`net.Listener` ([std.net](#stdnet)), which it takes, each a task of its
own, and answers each request on them with the `Response` that `f`
gives for it, keeping a connection open between requests unless the
client asks to close it. It runs until its task is canceled, or the
listener fails, and fails then; the connections' tasks end before it
returns. The checker types it, as it does `par.map`: `f` is a closure
written in the call, or a function's name, of type
`fun(?http.Request) -> http.Response`, and every connection's task
calls it, so each capture must share, and none is a write view. Each
request runs isolated (`task.isolate`): a panic in `f` answers 500, and
the server goes on.

| Member | Result |
|---|---|
| `serve(<l, f)!` | serve `f`'s answers on the listener `l`, until canceled |
| `Request` | `method`, `path` (the target before any `?`), `query` (after it), `head` (the request line and headers as they came), and `body` |
| `req.arg(name)` | the value of query parameter `name`, as written, or `none` |
| `req.header(name)` | the value of header `name`, any case, or `none` |
| `Response` | `status`, `type` (its content type), and `body` |
| `text(body)`, `json(body)`, `html(body)` | a 200 response of plain text, JSON written already, or HTML |
| `status(code, body)` | a response of status `code` and plain text `body` |
| `not_found()` | 404 |

```rig
use std.http
use std.net

fun serve(l: net.Listener) -> Int!
  http.serve(<l, |req|
    match req.path
      "/" => http.text("Hello from Rig!")
      _ => http.not_found()
  )!
  0

sub main()!
  l = net.listen("127.0.0.1:0")!
  port = l.port()
  t = serve(<l)&
  c = net.connect(String("127.0.0.1:", port))!
  (!c).write("GET / HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")!
  got = String()
  while true
    n = (!c).read(!got, 4096)!
    if n == 0
      break
  print(?got[..15])
  _ = <t.cancel() catch -1
```

```output
HTTP/1.1 200 OK
```

The server guards itself against clients that send too much, too
slowly, or too many at once, with limits read from the environment
when `serve` starts:

| Limit | Default | Setting |
|---|---|---|
| A connection waiting for its next request, or for a read of a body or a write of a response to make progress, is closed after | 60 s | `RIG_HTTP_IDLE_MS` |
| A request's head must arrive whole, from its first byte, within | 10 s | `RIG_HTTP_HEAD_MS` |
| A body larger than this is answered 413, and its connection closed | 16 MiB | `RIG_HTTP_MAX_BODY` (bytes) |

A body over the limit is refused before any of it is read when its
`Content-Length` says so, and once the limit is passed when it comes
chunked. A client that sends `Expect: 100-continue` is asked for the
body (`100 Continue`) only once its length is within the limit; any
other expectation is answered 417. Once the process has run out of
file descriptors, `serve` pauses, from 5 ms doubling to 1 s, and
accepts again, as Go's server does, so the connections it holds can
close; the listener stays open. In a deterministic run (`RIG_SEED`,
`rig test`) the timeouts count on its virtual clock, so a test of one
takes no time. Arguments to `http.serve` that set
these limits per server are planned; the environment sets them for the
whole process.

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
`!@`. A `Random` is unique (`obj Random unique`): it moves (`a = <r`)
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

`hash.Map[K, V, ordered: false]` keeps no order: its walks (`items`,
`keys`, `values`, `at`) meet each entry once in an order of their own,
which changes as the Map grows. It has the same members and the same
ownership, and keeps each key and value in its table's slot, beside the
slot's tag, so a lookup reads one tag and, when it matches, that slot,
where an ordered Map reads a tag, the index beside it, then the entry.
For lookups that do not follow the order keys were put in, it is about
twice as fast with `Int` keys and a fifth faster with `String` keys; its
`put` of a new key grows the table by hashing each key again, so filling
one is slower, and its table, at most three quarters full, holds each
key and value with its slot.

| Member | Signature | Ownership |
|---|---|---|
| `hash.Map[K, V]()`, `hash.Map[K, V].new(capacity: n)` | `fun new(capacity: Int = 0) -> Map[K, V]` | an empty Map, which allocates nothing until the first `put`, or with room for `n` entries |
| `!m.reserve(n)` | `sub reserve(!@, n: Int)` | makes room for `n` more entries at once, sizing the entries and the table for them rather than growing as they are put |
| `m.len` | `pub ?len: Int` | the number of entries: a field other modules read and only `std.hash` writes |
| `m.has(k)` | `fun has(?@, k: ?K) -> Bool` | reads |
| `m.get(k)` | `fun get(?@, k: ?K) -> (?V)? from @` | the view keeps `m` lent to read, not `k` |
| `(!m).edit(k)` | `fun edit(!@, k: ?K) -> (!V)? from @` | keeps `m` lent to write |
| `!m.put(k, v)` | `sub put(!@, k: K, v: V)` | puts `v` under `k`, inserting or overwriting; the old value is dropped, and a key already there keeps its place and `k` is dropped |
| `(!m).replace(k, v)` | `fun replace(!@, k: K, v: V) -> V?` | puts `v` under `k`, inserting or overwriting, and hands back the old value, or `none` when `k` is new |
| `(!m).put_new(k, v)` | `fun put_new(!@, k: K, v: V) -> Bool` | puts `v` under `k` only when `k` is new: true if it did; otherwise `k` and `v` are dropped |
| `(!m).ensure(k, v)` | `fun ensure(!@, k: K, v: V) -> !V from @, k, v` | puts `v` under `k` when `k` is new, and lends the value under `k` to write; otherwise `k` and `v` are dropped. The view keeps `m` lent to write |
| `(!m).ensure_with(k, make)` | `fun ensure_with(!@, k: K, make: ?fun(?K) -> V) -> !V from @, k` | as `ensure`, with the value `make(k)` made only when `k` is new; when `k` is there, `make` is not called and `k` is dropped |
| `w, added = (!m).ensure_added(k, v)` | `fun ensure_added(!@, k: K, v: V) -> (!V, Bool) from @, k, v` | as `ensure`, and also whether `k` was new; `w` keeps `m` lent to write, `added` keeps nothing |
| `if m.at(i) as k, v` | `fun at(?@, i: Int) -> (?K, ?V)? from @` | the entry at index `i` in order, its key and value viewed where the Map holds them, or `none` past the end; both views keep `m` lent to read. One step while no entry was taken since the entries were last compacted; else it counts the entries before |
| `(!m).take(k)` | `fun take(!@, k: ?K) -> V?` | the value back, owned; the key dropped when the entries are next compacted (as the Map grows), or with the Map |
| `!m.clear()` | `sub clear(!@)` | drops every entry |
| `?m.items()` | `fun items(?@) -> Items[K, V] from @` | the iterator keeps `m` lent to read; each `Item[?K, ?V]` (`e.key`, `e.value`) lasts one step of the loop |
| `?m.keys()`, `?m.values()` | `fun keys(?@) -> Keys[K, V] from @` | likewise, each a `?K` or a `?V` |
| `!m.update(f)` | `sub update(!@, f: ?sub(?K, !V))` | writes each value in place; keys stay read-only |
| `!m.retain(f)` | `sub retain(!@, f: ?fun(?K, !V) -> Bool)` | keeps the entries `f` is true for, in order; `f` reads each key and may write its value, in order, and cannot reach `m`; an entry it rejects is dropped then, not left for compaction as `take` leaves a key |

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
| `(!names).intern(s)` | `fun intern(!@, s: ?String) -> U32` | the id of `s`, a new one when `s` is new, whose text is then copied in; nothing is copied otherwise |
| `names.id(s)` | `fun id(?@, s: ?String) -> U32?` | the id of `s`, or `none`; adds nothing |
| `names.text(id)` | `fun text(?@, id: U32) -> ?String from @` | the text of `id`, viewed where the table holds it |
| `names.len` | `pub ?len: Int` | how many strings it holds |
| `!names.reserve(n, bytes: b)` | `sub reserve(!@, n: Int, bytes: Int = 0)` | room for `n` more strings of `b` bytes in all |

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

## print, warn, and panic

`print`, `warn`, and `panic` are built in
([SPEC §17](../SPEC.md#17-printing-and-stopping)), and need no `use`.
`print(a, b)` writes a line to stdout, `warn(a, b)` the same line to
stderr, and `panic(a, b)` the line to stderr after the file, line, and
column it stands at, then ends the program with status 134. Each writes
out what `print` buffered first, so the two streams read in order.

```rig
sub main()
  print("total", 3)
  warn("slow:", 2.5, "s")
  panic("lost", ["a\tb"])
```

```output
total 3
```

```stderr exit=134
slow: 2.5 s
main.rig:4:3: panic: lost ["a\tb"]
```

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

Every text API is described in four words, each with one meaning: a
**byte**, what a `String` stores; a **rune**, one Unicode scalar value;
a **unit**, one UTF-16 code unit; and a **char**, what a reader sees as
one character. The units, the table of one char at 1, 2, 3, 8, and 18
bytes, how a measure is spelled, and each unit's module are in
[TEXT](TEXT.md#four-units-four-words).

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

## Symbol names

A symbol, `:width`, is a value of the builtin type `Symbol`
([SPEC, Symbols](../SPEC.md#symbols)), and needs no `use`. `s.text` is
its name, a `Static`, and `Symbol.from_text(word)` is the program's
symbol spelled `word`, or `none`; neither allocates. The symbols are
exactly the names the program writes, so `from_text` finds a name
written anywhere in the program, std included: a word read from input
is checked by a `match` whose `_ =>` arm rejects it. A symbol is a key
of a `hash.Map` or a `hash.Set` ([std.hash](#stdhash)). A name known
only when the program runs is no symbol; `hash.Symbols` gives it a
dense id.

```rig
use std.hash
use std.text

sub main()
  counts = hash.Map[Symbol, Int]()
  for w in text.words("get put get drop")
    s = Symbol.from_text(w) ?? :other
    k = :other
    match s
      :get, :put => k = s
      _ => pass
    n = (!counts).ensure(k, 0)
    n += 1
  for e in ?counts.items()
    print(e.key, e.key.text, e.value)
```

```output
:get get 2
:put put 1
:other other 1
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
| `char_width(c: ?String) -> Int` | the terminal columns the first char of `c` takes, 0, 1, or 2 ([below](#chars)); 0 for `""` |
| `CharBreak.new(tailored: Bool = false) -> CharBreak` | where chars start in text that comes a rune at a time: `!b.next(r) -> Bool` is whether a char starts at rune `r`, then reads it; `!b.reset()`. With `tailored`, Ghostty's rules ([below](#chars)) |
| `width(s: ?String) -> Int` | the terminal columns `s` takes: `char_width` summed over its chars |
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
GB999) by the tables of Unicode 17.0.0, the version of `std.unicode`:
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
`std/char_tables.zig`, a two-level table of four bits a code point,
20 KB, whose levels each fill the range of the type that indexes them,
so no lookup needs a bounds check. It also writes two tests: every line of Unicode's
GraphemeBreakTest.txt, through each char tool at every byte, and a
census that puts every code point in texts whose char counts tell its
class apart.

A char's width is the terminal columns it takes, as Ghostty counts
them: `char_width(c)` is the `unicode.width` of its first rune; then a
later rune that takes a column of its own (a spacing mark, say) makes it
2, and a variation selector after a rune that may take one makes it 2
(U+FE0F, emoji style) or 1 (U+FE0E, text style). `width(s)` sums the
widths of its chars.

```rig
use std.text

sub main()
  print(text.char_width("e\u{301}"), text.char_width("\u{2764}"), text.char_width("\u{2764}\u{fe0f}"), text.char_width("\u{1f44b}\u{1f3fd}"))
  print(text.width("h\u{e9}llo"), text.width("\u{65e5}\u{672c}\u{8a9e}"), text.width("\u{1f1fa}\u{1f1f8}!"), text.width(""))
```

```output
1 1 2 2
5 6 3 0
```

`CharBreak` finds the same chars a rune at a time, for text that comes
in pieces, as a terminal reads it. With `tailored` its rules are
Ghostty's, which tailor UAX #29 two ways: as UTS #51 has emoji modifier
sequences, a skin tone joins only an emoji modifier base just before it;
and a rune of class Control other than CR and LF (DEL, the soft hyphen,
the zero-width space) joins as any rune does, since a terminal acts on
the controls before they reach a char.

```rig
use std.text
use std.utf8

fun starts(tailored: Bool, s: ?String) -> Int
  b = text.CharBreak.new(tailored)
  n = 0
  for r in utf8.runes(s)
    n += 1 if (!b).next(r) else 0
  n

sub main()
  print(starts(false, "a\u{1f3fd}"), starts(true, "a\u{1f3fd}"))
  print(starts(false, "\u{1f44d}\u{1f3fd}"), starts(true, "\u{1f44d}\u{1f3fd}"))
```

```output
1 2
1 1
```

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
| `Decoder.new() -> Decoder` | a streaming decoder, fed a byte at a time, for text that arrives in pieces; an ill-formed sequence reads as one `REPLACEMENT` per maximal subpart, as Unicode recommends and terminals do (Ghostty's DFA), where `rune_after` reads one per bad byte, as Go does | |
| `(!d).next(b: U8) -> Int?` | the rune byte `b` completes, `REPLACEMENT` where a sequence is ill-formed, or `none` while one is under way; after a `REPLACEMENT` with `d.retry` true, feed `b` again, as the start of what follows | |
| `d.pending() -> Bool` | whether a sequence is under way | |

The case `utf8 go` of `test/rig/std-misc.rig.test` runs Go's own test tables, and
`test/rig/std-text-go.rig.test` compares every function with Go's answers
on generated text, recorded by `tools/text_go.py` (`TEXT_GO_FULL=1
test/cli/text_go.sh` asks Go again, when it is installed).

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

The case `utf16 go` of `test/rig/std-misc.rig.test` runs Go's `unicode/utf16` test tables.

## std.unicode

Properties of one rune, from the Unicode Character Database of the
version in `unicode.VERSION`, 17.0.0. `width(r)` is the columns `r`
takes in a terminal, by the rules of Ghostty's tables: 0 for a control,
a line or paragraph separator, a surrogate, a nonspacing or enclosing
mark, a Hangul vowel or trailing consonant, and a default-ignorable rune
but the soft hyphen; 2 for an East Asian Wide or Fullwidth rune
([UAX #11](https://unicode.org/reports/tr11/)), a regional indicator,
and the two- and three-em dashes; else 1. The identifier classes are of
`unicode.ID_VERSION`, 15.1.0, the version of TypeScript's scanner, so a
scanner built on them reads the identifiers tsc reads. They are those of
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
| `VERSION` | the Unicode version of every property but the identifier classes, `"17.0.0"` |
| `ID_VERSION` | the Unicode version of the identifier classes, `"15.1.0"` |
| `width(r: Int) -> Int` | the columns `r` takes in a terminal, 0, 1, or 2; 0 for a value that is not a rune |
| `is_id_start(r: Int) -> Bool`, `is_id_continue(r: Int) -> Bool` | whether `r` may begin an identifier, or continue one |
| `is_space(r: Int) -> Bool` | whether `r` is one of the 25 runes of White_Space |

```rig
use std.unicode

sub main()
  print(unicode.is_id_start(0x61), unicode.is_id_start(0x30), unicode.is_id_continue(0x30))
  print(unicode.is_id_start(0x2118), unicode.is_id_start(0xB7), unicode.is_id_continue(0xB7))
  print(unicode.is_id_start(0x2E2F), unicode.is_id_continue(0x200C), unicode.is_id_start(0x4E00))
  print(unicode.is_space(0x20), unicode.is_space(0x85), unicode.is_space(0x3000), unicode.is_space(0xFEFF))
  print(unicode.width(0x61), unicode.width(0x4E00), unicode.width(0x301), unicode.width(0x1F600), unicode.width(0x200B))
  print(unicode.VERSION, unicode.ID_VERSION)
```

```output
true false true
true false true
false true true
true true true false
1 2 0 2 0
17.0.0 15.1.0
```

The tables are generated: `tools/gen-unicode.py` reads the pinned files
of the Unicode Character Database (checking each one's sha256, and
fetching it when absent) and writes `std/unicode_tables.zig`, a
two-level bitmap of about 11 KB with an ASCII fast path, and
`std/width_tables.zig`, a two-level table of a byte a code point,
36 KB, in the shape of the char table, which holds each code point's
char class beside its width so a terminal finds both in one lookup. To
move to a newer Unicode, change the pinned version and hashes, run the
generator, and review the diff of the census tests it also writes. `tools/verify-unicode.py`
compares every code point with the database and with Python's
`unicodedata`, the identifier classes and White_Space both; run both
with `RIG_UCD` naming a directory that holds a directory of each
version's files (the default is `~/.cache/rig-ucd`).

## std.terminal

A terminal emulator as a library, experimental and growing: bytes a
program writes go in through `feed`, and the screen and cursor come out.
It reads and writes nothing itself; a caller owns the pty, the keyboard,
and the drawing. Its behavior is xterm's, as Ghostty implements it: the
cases of `test/rig/std-terminal-ghostty.rig.test` are Ghostty's answers,
recorded by `tools/terminal_ghostty.py`. So far it takes printable ASCII,
autowrap with a pending wrap, and the C0 controls BS, HT, LF, VT, FF,
and CR; escape and control sequences, parsed by the DEC state machine
(https://vt100.net/emu/dec_ansi_parser), for cursor movement (CUU, CUD,
CUF, CUB, CNL, CPL, CHA, HPA, HPR, VPA, VPR, CUP, HVP), tab stops (HT,
CHT, CBT, HTS, TBC), IND, NEL, RI, DECSC/DECRC, scroll margins (DECSTBM,
SU, SD), erasing (ED, EL, ECH, DECALN, and the selective DECSED and
DECSEL, which with SPA, EPA, and DECSCA leave protected cells as
Ghostty does), inserting and deleting lines and
cells (IL, DL, ICH, DCH), styles (SGR: the flags, underline styles, 16,
256, and RGB colors, and underline colors; an erased cell keeps the
background), the modes IRM, LNM, DECOM, DECAWM, and DECTCEM (and XTSAVE
and XTRESTORE of the private ones), REP, `CSI s` and `CSI u`, RIS, and
character sets (SCS into G0 to G3 of ASCII, British, and DEC Special
Graphics, with SO, SI, SS2, SS3, LS2, and LS3), and the alternate screen
(modes 47, 1047, and 1049, as xterm switches them). `dump` shows the
history, then the screen in use. It answers DA (primary, secondary, tertiary, and DECID),
DSR 5 and 6, DECRQM of every mode Ghostty knows (which SM, RM, DECSET,
DECRST, XTSAVE, and XTRESTORE keep), XTVERSION, and the kitty keyboard
flags (pushed, popped, and set per screen). In the ground state bytes
are UTF-8, read by `utf8.Decoder`, so a rune may be cut between two feeds
and each ill-formed subpart shows as one U+FFFD; in a sequence a byte from
0x80 to 0x9F is a C1 control. Strings (OSC, DCS, SOS, PM, and APC) are
read to their end and ignored. A rune takes the columns `unicode.width`
gives it: a wide one takes a cell and a spacer after it, wraps whole
(leaving a spacer at the end of the row it leaves), and is emptied whole
when a write or an edit cuts it. A cell holds a whole char: a rune of
width 0 joins the char before it, as Ghostty adds it (a variation
selector only after an emoji), and the char's runes move, scroll, and
erase with its cell. In mode 2027 runes join as Ghostty clusters them (a
tailored `text.CharBreak`): an emoji ZWJ sequence, a flag, or a Hangul
syllable is one char, and a char's width is its runes' together, so
VS16 or a spacing mark makes it wide and VS15 narrow; a wide char at the
last column wraps whole.

The primary screen keeps a history (scrollback) of up to `scrollback`
rows, as Ghostty does: a row goes into it when it scrolls off the top
of the screen, by a line feed, IND, NEL, a wrap, or SU, while the scroll
region starts at the top row. The row keeps its text, styles, wide
runes, joined runes, and wrap. When the history is full, its oldest row
is dropped for each new one. The alternate screen keeps none. ED 3
(`CSI 3 J`) erases the history; ED 22 (`CSI 22 J`) scrolls the screen,
down to its last row that is not empty, into it; RIS erases it. A
scroll costs the same with history as without: rows are not copied.

| Member | Result |
|---|---|
| `Terminal.new(cols: Int, rows: Int, scrollback: Int = 10000) -> Terminal` | an empty terminal, the cursor at the top left, keeping up to `scrollback` rows of history (0 for none) |
| `!t.feed(bytes: ?String)` | take `bytes` as a program's output, in order |
| `t.replies` | a `String`: the bytes the terminal answers with (DA, DSR and CPR, DECRQM, XTVERSION, the kitty keyboard flags), in order, for the caller to send to the program and then `!t.replies.clear()` |
| `t.history_len() -> Int` | the rows in the history |
| `t.history_row(i: Int) -> String` | row `i` of the history, from 0 (the oldest) to `history_len() - 1`, as `dump` shows its text; empty for any other `i` |
| `t.dump(history: Bool = true) -> String` | a line per row of the history, oldest first, `^` and its text (left out without `history`); a line per row of the screen, `\|` and its text, with trailing blanks dropped and the spacer of each wide rune left out; a line `~ROW FIRST-LAST STYLE` per run of cells with the same style other than the plain one (its flags, then `ul=`, `fg=`, `bg=`, `ulc=`, a color a palette index or `#rrggbb`), the history's rows numbered from -1, the newest, up; a line `reply BYTES` when there are replies (ESC as `\e`, other controls as `\xNN`); then `cursor ROW COL`, with ` wrap` when the next rune wraps first |

```rig
use std.terminal

sub main()
  t = terminal.Terminal.new(8, 3)
  !t.feed("hello,\r\nterminal!")
  print(t.dump())
```

```output
|hello,
|terminal
|!
cursor 2 1
```

```rig
use std.terminal

sub main()
  t = terminal.Terminal.new(8, 2, scrollback: 2)
  !t.feed("one\r\ntwo\r\nthree\r\nfour\r\nfive")
  print(t.history_len(), t.history_row(0), t.history_row(1))
  print(t.dump())
  !t.feed("\x1b[3J")
  print(t.history_len())
```

```output
2 two three
^two
^three
|four
|five
cursor 1 4
0
```

## std.json

**Experimental:** the names and shapes below will change, to idiomatic
fallible `!` functions, once errors can carry data. Use it to read JSON
fast today, not as a settled API.

A JSON parser (RFC 8259) in safe Rig, written for speed: it validates
the whole document in one pass and builds a tape, a flat list with one
entry for each value in document order. On Apple silicon it runs at 1.9 to 7.0 GB/s on the standard
benchmark files ([docs/history/json-results.md](history/json-results.md)), 3 to 11 times Zig's `std.json`, with
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

`bench/json/check/compare.py` checks it against Python's `json` module on 10,511
inputs, sanitizer-clean (`bench/json/check/README.md`); the design and the
measurements are in [docs/design/json.md](design/json.md) and
[docs/history/json-results.md](history/json-results.md).
