# Errors and optionals: failure you can see

Here is a Python function that reads one line of a config file:

```python
def port(line):
    key, value = line.split("=")
    return int(value.strip())
```

Two lines of work, and at least two ways to fail. A line with no `=`
raises `ValueError` on the first. A value that is not a number raises
`ValueError` on the second. Neither shows on the page. The caller
sees `port(line)` and cannot tell that it might not return. The
exception may travel up five functions before anything catches it, or
end the program.

The other half of the problem is "nothing". In Java, `map.get(key)`
returns `null` when the key is missing, and the type says nothing about
it. The program fails three calls later, with a `NullPointerException`
far from the line that made the `null`.

Rig has neither exceptions nor `null`. A value that may be absent has
a type of its own, `T?`. A call that may fail has one too, `T!`. Every
use of either says, on the line, what happens when the value is not
there. This chapter builds a parser for lines such as `port = 8080`,
one step at a time, and fails on bad input with errors that have
names.

## Nothing has a type

`std.text` finds one text inside another. When it is not there, the
answer is `none`:

```rig
use std.text

sub main()
  for line in ["port = 8080", "# a comment"]
    at = text.find(line, "=")
    print(at, at ?? -1, at == none)
```

```output
5 5 false
none -1 true
```

`text.find` returns an `Int?`: an `Int`, or `none`. `at ?? -1` is the
value inside `at`, or `-1` when there is none. `at == none` tests for
absence.

An `Int?` is not an `Int`. Nothing about it can be used as a number
until the program says what happens when it is `none`:

```rig reject
use std.text

sub main()
  at = text.find("port = 8080", "=")
  print(at + 1)
```

```error
requires numeric operands; got `Int?`
```

That is the whole cure for the null pointer. A value that might be
missing has a different type from one that is not, and the compiler
keeps the two apart.

## Taking the value out

The parser's first step finds a line's key, the text before its `=`.
A line without one has no key:

```rig
use std.text

fun key_of(line: ?String) -> (?String)? from line
  text.trim(text.cut(line, "=")?.before)

sub show_key(line: ?String)
  k = key_of(line) ?? return
  print("key:", k)

sub main()
  for line in ["port = 8080", "# a comment", "name = rig"]
    if key_of(line) as k
      print(k, "is set")
    else
      print("skipped:", line)
  show_key("debug = 1")
  show_key("debug")
```

```output
port is set
skipped: # a comment
name is set
key: debug
```

`text.cut` splits a text around its first `=` and returns `none` when
there is no `=`. The `?` after the call passes that `none` up:
`key_of` returns `none` at once, and otherwise goes on with the value.
`key_of` returns a `(?String)?`, an optional view of text, and
`from line` says the view is of `line`. [Ownership without a
collector](02-ownership.md) covers views that a function returns.

There are three ways to take a value out, one for each thing a program
may want to do with `none`:

- `e?` gives up: the function returns `none` too.
- `if e as v` branches: the block runs with `v` bound to the value,
  and `else` runs when there is none.
- `e ?? fallback` gives a default. The fallback may also be a jump:
  `?? return`, `?? break`, or `?? continue`.

`show_key` uses the jump. `k = key_of(line) ?? return` binds `k` or
leaves the function, so the rest of it has a plain `?String`.

`e?` works only where `none` has somewhere to go:

```rig reject
use std.text

fun key_len(line: ?String) -> Int
  text.cut(line, "=")?.before.len
```

```error
use of `?` requires the enclosing function `key_len` to return an optional
```

## Failure with a name

A missing key is not always fine. In a config file, a line that says
`port` and nothing else is a mistake, and the program should say so.
That is a failure, not an absence:

```rig
use std.text

error Config
  missing
  empty_key

fun value_of(line: ?String) -> Int!
  c = text.cut(line, "=") ?? return Config.missing
  return Config.empty_key if text.trim(c.before).len == 0
  text.parse_int(text.trim(c.after))!

sub main()
  print(value_of("port = 8080")!)
  for line in ["port", "= 3", "port = eighty"]
    value_of(line) catch |e| print(line, "failed:", e)
```

```output
8080
port failed: Config.missing
= 3 failed: Config.empty_key
port = eighty failed: ParseError.invalid
```

`error Config` declares an **error set**: a set of named errors, used
like the variants of an enum. `Int!` is the type of a call that gives
an `Int` or fails with an error.

A function fails by returning an error: `return Config.missing`. The
`??` turns an absence into a failure, because its fallback may be a
jump, and the jump is `return Config.missing`. `text.parse_int` is
fallible too, and the `!` after its call passes its failure up:
`value_of` fails with the same error. That error belongs to
`std.text`'s own set, `ParseError`, and an error prints as its set and
its name.

Every call to a fallible function says what happens to the failure.
`!` passes it up, and `catch` handles it. A call with neither does not
compile:

```rig reject
use std.text

sub main()
  n = text.parse_int("8080")
  print(n)
```

```error
must be wrapped with `!` (propagate) or `catch` (handle)
```

Failing is written, too. An error value is never the quiet last line
of a function:

```rig reject
error Config
  missing

fun size(line: ?String) -> Int!
  if line.len == 0
    Config.missing
  else
    line.len
```

```error
an error value meets `Int!` only as the operand of `return`
```

So a reader finds every place a function can fail by looking for two
things: `return` with an error, and `!` after a call.

## Handling a failure

`catch` gives a fallback, as `??` does. With a name in bars, the
handler sees the error, and a `match` tells the errors apart:

```rig
use std.text

error Config
  missing
  empty_key

fun value_of(line: ?String) -> Int!
  c = text.cut(line, "=") ?? return Config.missing
  return Config.empty_key if text.trim(c.before).len == 0
  text.parse_int(text.trim(c.after))!

fun explain(line: ?String) -> ?String
  n = value_of(line) catch |e|
    match e
      .missing => return "no `=`"
      .empty_key => return "no key"
      text.ParseError.invalid => return "not a number"
      _ => return "something else"
  "ok" if n >= 0 else "negative"

sub main()
  for line in ["port = 8080", "port", "= 3", "port = eighty"]
    print(value_of(line) catch -1, explain(line))
```

```output
8080 ok
-1 no `=`
-1 no key
-1 not a number
```

`value_of(line) catch -1` is the value, or `-1` when the call fails.
In `explain`, the handler is a block that names the error `e`. Each
arm of its `match` returns, so `n` is bound only when the call
succeeded.

A bare `.missing` in an arm means the member of the one error set that
has it, here `Config`. An error from another module is named through
the module, `text.ParseError.invalid`. An error belongs to its set, so
`Config.missing` and another set's `missing` are different errors.

The `_` arm is required. A function does not declare which sets it
fails with, so `e` may be any error, and no list of arms names them
all:

```rig reject
error Config
  missing
  empty_key

fun value_of(n: Int) -> Int!
  return Config.missing if n < 0
  n

fun code(n: Int) -> Int
  value_of(n) catch |e|
    match e
      .missing => -1
      .empty_key => -2
```

```error
`match` on `error` is not exhaustive; add `_ =>`
```

## Several results

A config line has two parts worth keeping. A function can give both at
once, and fail as a whole:

```rig
use std.text

error Config
  missing
  empty_key

fun setting(line: ?String) -> (?String, Int)! from line
  c = text.cut(line, "=") ?? return Config.missing
  key = text.trim(c.before)
  return Config.empty_key if key.len == 0
  return key, text.parse_int(text.trim(c.after))!

sub main()
  count = 0
  for line in ["port = 8080", "debug", "workers = 4", "= 1"]
    key, n = setting(line) catch continue
    print(key, n)
    count += 1
  print(count, "settings")
  key, n = setting("timeout = 30")!
  print(key, "is", n)
```

```output
port 8080
workers 4
2 settings
timeout is 30
```

`-> (?String, Int)!` gives a key and a number, or fails. `return key,
n` gives both. The caller binds each by name, `key, n = setting(line)`,
as Go does.

The failure is dealt with before anything is bound. `!` passes it up,
and `catch continue` skips the line. A fallback that is a value cannot
stand for two results, so here the handler must jump. Unlike Python's
tuple, the pair is never a value of its own: a group that lives on is
an object.

## Cleanup on every path

Some work must be undone if a function fails partway. `defer` runs
when a scope ends, however it ends. `errdefer` runs only when the
function fails:

```rig
use std.text

error Config
  missing

fun value_of(line: ?String) -> Int!
  c = text.cut(line, "=") ?? return Config.missing
  text.parse_int(text.trim(c.after))!

fun load(lines: []?String) -> Int!
  print("open")
  defer print("close")
  errdefer print("discard partial load")
  total = 0
  for line in lines
    total += value_of(line)!
  total

sub main()
  print(load(["a = 1", "b = 2"]) catch -1)
  print(load(["a = 1", "b"]) catch -1)
```

```output
open
close
3
open
discard partial load
close
-1
```

The first load succeeds, so only `close` runs. The second fails on
`b`, and the `!` leaves `load` at once. Both cleanups run, in reverse
order of their declarations: the `errdefer`, then the `defer`.

There is no `try`, `finally`, or `ensure` block. Each cleanup is
written next to the work it undoes, and the `!` marks each place the
function may leave. Owned values drop on the same paths, as journey 02
shows.

`errdefer` is only for a function that can fail. Anywhere else it
could never run, and the compiler says what to write instead:

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

## When main fails

A failure that nobody handles reaches `main`. `main` may pass it on
with `!` too, and then the program ends:

```rig
use std.text

error Config
  missing

fun value_of(line: ?String) -> Int!
  c = text.cut(line, "=") ?? return Config.missing
  text.parse_int(text.trim(c.after))!

sub main()
  defer print("main ends")
  print(value_of("port = 8080")!)
  print(value_of("debug")!)
  print("not reached")
```

```output
8080
main ends
```

```stderr exit=1
error: Config.missing
```

The second call fails, and `!` passes the failure out of `main`.
`main`'s `defer` runs and its values drop, as in any function. Then
the program writes `error: Config.missing` to stderr and exits with
status 1, so a shell script sees the failure.

`sub main()` may pass a failure on with `!`. To fail with an error of
its own, `return Config.missing`, it is declared fallible, `sub
main()!`. A program that wants another exit status returns it from
`fun main() -> Int`.

## A panic is not an error

An error is something a caller can handle: a missing file, a bad line.
A bug is different. When the program reaches a state it cannot go on
from, it panics:

```rig
fun digit(b: U8) -> Int
  return Int(b) - 48 if b >= 48 and b <= 57
  panic("digit called on byte", b)

sub main()
  defer print("not reached")
  line = "port = 80"
  print(digit(line[7]), digit(line[8]))
  print(digit(line[0]))
```

```output
8 0
```

```stderr exit=134
main.rig:3:3: panic: digit called on byte 112
```

`digit` expects a digit, and its caller checks first. Passing it `p`
is a bug in the caller, not bad input, so `digit` does not return
`Int!`. The panic writes out what `print` buffered, then its place and
message on stderr, and ends the program with status 134.

Nothing else runs. No `defer`, no `errdefer`, no drop. A panic is not
passed up, and no caller can catch it, because a program in a state
it did not expect has no safe code left to run. An index out of range
and an integer overflow panic the same way.

So the line between them is a question about the caller. If a caller
could do something sensible, return an error. If the only fix is to
change the program, panic.

## Reading the types

The marks combine, and a type reads left to right. Here a lookup may
fail on a bad line, and may also find nothing:

```rig
use std.text

error Config
  missing

fun value_of(line: ?String) -> Int!
  c = text.cut(line, "=") ?? return Config.missing
  text.parse_int(text.trim(c.after))!

fun port(lines: []?String) -> Int?!
  for line in lines
    c = text.cut(line, "=") ?? continue
    return value_of(line)! if text.trim(c.before) == "port"
  none

sub show(owner: ?String?)
  if owner as o
    print("owner:", o)
  else
    print("no owner")

sub main()
  print(port(["name = rig", "port = 80"]) catch none)
  print(port(["name = rig"]) catch none)
  print(port(["port = x"]) catch none)
  me: String? = String("ada")
  show(?me)
  nobody: String? = none
  show(?nobody)
```

```output
80
none
none
owner: ada
no owner
```

`Int?!` is an `Int?` that may fail: `catch` handles the failure, and
what is left is an `Int?`. The order matters. A port that is not set
is `none`, and a port that is set badly is an error.

A view applies to the whole type after it. `?String?` is a view of a
`String?`: `show` reads an optional that `main` owns. Parentheses
group the other way: `(?String)?`, which `key_of` returned earlier, is
an optional view of a `String`.

A fallible type stands only as a call's result, never inside another
type. So `!` comes last: `Int?!` is a type, and `Int!?` is not:

```rig reject
fun f(n: Int) -> Int!?
  n
```

```error
a fallible type `Int!` stands only where a call's result is named
```

## Absence and failure, side by side

The two ideas run in parallel, with one mark each:

| | absence | failure |
|---|---|---|
| the type | `T?`, a `T` or `none` | `T!`, a `T` or an error |
| make one | `none`, or `return none` | `return Config.missing` |
| pass it up | `e?` | `e!` |
| give a fallback | `e ?? v` | `e catch v` |
| leave instead | `e ?? return`, `?? continue` | `e catch return`, `catch continue` |
| look inside | `if e as v` | `e catch \|err\| ...`, `match err` |
| cleanup | `defer` | `defer` and `errdefer` |
| out of `main` | | `error: Set.name`, status 1 |

A panic is in neither column. It is a bug, it ends the program where
it stands, and nothing runs after it.

**Absence and failure are types, and every use says what it does with
them.**

## What is not there yet

Three parts of the error design are decided and not built. A function
will name the set it fails with, `-> Int!Config`. Sets will join by a
named union, `error L = A | B`. And a member
will carry fields, so `Config.missing` could say which line failed
([SPEC §13, "Declared sets and fields"](../../SPEC.md#declared-sets-and-fields)).
Until then, `catch |e|` sees any error, a `match` on it needs a `_`
arm, and an error is only its name.

## Where to go next

- [Concurrency without async](04-concurrency.md) runs work as tasks.
  A task that fails gives its error to whoever waits for it, `>t!`.
  Canceling a task is a failure too, and `task.isolate` stops a panic
  at a boundary.
- [SPEC §12](../../SPEC.md#12-optionals) and [§13](../../SPEC.md#13-errors)
  give every rule for optionals and errors,
  [§17](../../SPEC.md#panic) the panic, [defer and
  errdefer](../../SPEC.md#defer-and-errdefer) the cleanups, and
  [Several results](../../SPEC.md#several-results) the full rules for
  `-> (A, B)`.
- [WELCOME.md](../../WELCOME.md) lists the habits from other languages,
  such as Rust's `?` on a failure, and the error each one gets.
