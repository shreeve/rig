# Errors and optionals: failure you can see

Here is a Python function that reads one line of a config file:

```python
def port(line):
    key, value = line.split("=")
    return int(value.strip())
```

Two lines of work, and two ways to fail: a line with no `=`, and a
value that is not a number. Neither shows on the page. The caller sees
`port(line)` and cannot tell that it might not return.

The other half of the problem is "nothing". In Java, `map.get(key)`
returns `null` when the key is missing, and the type says nothing about
it. The program fails three calls later, far from the line that made
the `null`.

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

That is the cure for the null pointer: a value that might be missing
has a type of its own, which the compiler keeps apart.

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
`(?String)? from line` is an optional view of `line`, as
[journey 02](02-ownership.md) showed.

There are three ways to take a value out, one for each thing a program
may want to do with `none`:

- `e?` gives up: the function returns `none` too.
- `if e as v` branches: the block runs with `v` bound to the value,
  and `else` runs when there is none.
- `e ?? fallback` gives a default. The fallback may also be a jump:
  `?? return`, `?? break`, or `?? continue`.

`show_key` uses the jump. `k = key_of(line) ?? return` binds `k` or
leaves the function, so the rest of it has a plain `?String`.

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

A function fails by returning an error, and `?? return
Config.missing` turns an absence into one. The `!` after
`text.parse_int` passes its failure up as it is: `ParseError.invalid`,
from `std.text`'s own set. An error prints as its set and its name.

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

Failing is written too: an error value stands only after `return`. So
a reader finds every place a function can fail by looking for two
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
has it, here `Config`, and another module's is named through it,
`text.ParseError.invalid`. An error belongs to its set, so
`Config.missing` and another set's `missing` are different errors.

The `_` arm is required here. `value_of` is declared `-> Int!`, which
may fail with any error, so `e` may be any error, and no list of arms
names them all:

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

## Naming the set

A function may name the set it fails with, `-> Int!Config`. Then the
handler knows every error it can see:

```rig
use std.text

error Config
  missing
  empty_key
  not_a_number

fun value_of(line: ?String) -> Int!Config
  c = text.cut(line, "=") ?? return Config.missing
  return Config.empty_key if text.trim(c.before).len == 0
  text.parse_int(text.trim(c.after)) catch return Config.not_a_number

fun explain(line: ?String) -> ?String
  _ = value_of(line) catch |e|
    match e
      .missing => return "no `=`"
      .empty_key => return "no key"
      .not_a_number => return "not a number"
  "ok"

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

`Int!Config` is an `Int`, or an error of `Config`. In `explain`, `e`
has the type `Config`, so a `match` that names its three members is
complete and needs no `_`. Add a member to `Config`, and every `match`
that misses it stops compiling.

The set is a promise. `text.parse_int` may fail with any error, which
`!` cannot pass into `Config`, so the `catch` turns it into a member.
Written with `!`, it is rejected:

```rig reject
use std.text

error Config
  missing

fun value_of(line: ?String) -> Int!Config
  c = text.cut(line, "=") ?? return Config.missing
  text.parse_int(text.trim(c.after))!
```

```error
`text.parse_int` may fail with any error, and `value_of` declares `Int!Config`: catch it, or declare `-> Int!`
```

A function that calls into several sets names their union.
`error LoadError = Config | Limit` lists no members of its own; it
holds every member of both:

```rig
use std.text

error Config
  missing
  not_a_number

error Limit
  too_many(count: Int)

error LoadError = Config | Limit

fun value_of(line: ?String) -> Int!Config
  c = text.cut(line, "=") ?? return Config.missing
  text.parse_int(text.trim(c.after)) catch return Config.not_a_number

fun load(lines: []?String) -> Int!LoadError
  return Limit.too_many(count: lines.len) if lines.len > 3
  total = 0
  for line in lines
    total += value_of(line)!
  total

sub report(lines: []?String)
  n = load(lines) catch |e|
    match e
      c: Config => print("bad line:", c)
      Limit.too_many(count) => print(count, "lines are too many")
    -1
  print(n)

sub main()
  report(["a = 1", "b = 2"])
  report(["a = 1", "b"])
  report(["a = 1", "b = x"])
  report(["a", "b", "c", "d"])
```

```output
3
bad line: Config.missing
-1
bad line: Config.not_a_number
-1
4 lines are too many
-1
```

`value_of(line)!` passes a `Config` error into `load` as it is,
because `LoadError` holds `Config`. In `report`, the arm `c: Config =>`
matches any member of `Config`, and the arm after it names `Limit`'s
one member, so the `match` covers `LoadError`.

`-> T!`, any error, suits a quick program. A declared set suits a
library, whose callers want to know what can go wrong.

## Errors that say more

An error can say which line failed. A member may carry fields, as an
enum's variant does:

```rig
use std.text

error Config
  missing(line: Int)
  not_a_number(line: Int, found: String)

fun value_of(n: Int, line: ?String) -> Int!Config
  c = text.cut(line, "=") ?? return Config.missing(line: n)
  v = text.trim(c.after)
  text.parse_int(v) catch return Config.not_a_number(line: n, found: String(v))

sub main()
  lines = ["port = 80", "debug", "workers = four"]
  bad: List[Config] = List()
  for line, i in lines
    n = value_of(i + 1, line) catch |e|
      !bad.push(<e)
      continue
    print("value", n)
  for e in bad
    print(e)
    match e
      .missing(line) => print("  line", line, "has no `=`")
      .not_a_number(line, found) => print("  line", line, "has", found)
  print(bad[0] == Config.missing)
```

```output
value 80
Config.missing(line: 2)
  line 2 has no `=`
Config.not_a_number(line: 3, found: "four")
  line 3 has four
true
```

`Config.missing(line: n)` makes the error with its field. An error
prints with its fields, and a pattern binds them,
`.missing(line) =>`. `bad[0] == Config.missing` tests which member an
error is and compares no fields.

A failure moves its error up through each `!` to the `catch` that
handles it, and the handler owns it: here `<e` moves it into the list.
A field holds no view, so an error never keeps anything lent, and
`+e` copies one. A moved error is gone, as any moved value is:

```rig reject
error Config
  missing(line: Int)

fun value_of(n: Int) -> Int!Config
  return Config.missing(line: n) if n > 9
  n

sub main()
  bad: List[Config] = List()
  v = value_of(12) catch |e|
    !bad.push(<e)
    print(e)
    0
  print(v, bad.len)
```

```error
use of `e` after move
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

`-> (?String, Int)!` gives a key and a number, or fails, and the
caller binds each by name, as Go does. The failure is dealt with before
anything is bound: `!` passes it up, and `catch continue` skips the
line. A value cannot stand for two results, so the handler must jump.

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

The second call's failure leaves `main` through `!`. Its `defer` runs
and its values drop, then the program writes `error: Config.missing`
to stderr and exits with status 1, so a shell script sees the failure.

A `main` that returns an error of its own is declared `sub main()!`,
and one that chooses its exit status is `fun main() -> Int`.

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

Passing `digit` a `p` is a bug in its caller, not bad input, so
`digit` does not return `Int!`. The panic writes its place and message
to stderr and ends the program with status 134.

Nothing else runs: no `defer`, no `errdefer`, no drop, and no `catch`
stops it, because a program in a state it did not expect has no safe
code left to run. An index out of range and an integer overflow panic
the same way.

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

sub main()
  print(port(["name = rig", "port = 80"]) catch none)
  print(port(["name = rig"]) catch none)
  print(port(["port = x"]) catch none)
```

```output
80
none
none
```

`Int?!` is an `Int?` that may fail: a port not set is `none`, and one
set badly is an error. `catch` handles the failure and leaves the
`Int?`.

A view applies to the whole type after it: `?String?` is a view of a
`String?`, and `(?String)?`, which `key_of` returned, an optional view.

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
| name what can fail | | `-> T!E`, `error L = A \| B` |
| say more | | `bad(line: Int)`, `.bad(line) =>` |
| out of `main` | | `error: Set.name`, status 1 |

A panic is in neither column. It is a bug, it ends the program where
it stands, and nothing runs after it.

**Absence and failure are types, and every use says what it does with
them.**

## Where to go next

- [Concurrency without async](04-concurrency.md) runs work as tasks.
  A task that fails gives its error to whoever waits for it, `>t!`.
  Canceling a task is a failure too, and `task.isolate` stops a panic
  at a boundary.
- [SPEC §12](../../SPEC.md#12-optionals) and [§13](../../SPEC.md#13-errors)
  give every rule for optionals and errors,
  [Declared sets and fields](../../SPEC.md#declared-sets-and-fields)
  and [Generic sets](../../SPEC.md#generic-sets) the rules for naming
  a set,
  [§17](../../SPEC.md#panic) the panic, [defer and
  errdefer](../../SPEC.md#defer-and-errdefer) the cleanups, and
  [Several results](../../SPEC.md#several-results) the full rules for
  `-> (A, B)`.
- [WELCOME.md](../../WELCOME.md) lists the habits from other languages,
  such as Rust's `?` on a failure, and the error each one gets.
