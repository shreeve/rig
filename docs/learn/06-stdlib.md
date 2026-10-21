# The standard library: a tool in an afternoon

Here is a Python script that reads a file of orders and reports who
ordered the most:

```python
import json, os, random, sys, time
from collections import Counter

start = time.time()
path = sys.argv[1] if len(sys.argv) > 1 else "orders.json"
units = Counter()
for o in json.load(open(path)):
    units[o["who"]] += o["qty"]
for who, n in units.most_common():
    print(who, n)
print(random.sample(sorted(units), 2), time.time() - start)
```

It imports five modules and says little about any of them. `open` may
fail, and nothing marks the line. Nothing says which call waits on the
disk, or what `random.sample` does on the second run.

Rig ships what such a script needs, under `std/`, written in Rig and
checked like your own code. This chapter builds the same tool, one
module at a time: arguments, a file, JSON, counting, sorting, timing, a
random sample, big numbers, color, and a web page. The first steps add
to one program. From the counting step on, the four orders are a list in
the program, so each step stays short. The last step serves the result
and is only checked, since a test cannot wait for a request. The
chapter ends on how a library uses the sigils of [the first
chapter](01-sigils.md).

## Arguments and the environment

A tool starts with what it was given:

```rig
use std.os

sub main()
  args = os.args()
  dir = args[1] if args.len > 1 else "tally-data"
  title = os.env("ORDERS_TITLE") ?? "Orders"
  print(title, "from", dir)
```

```output
Orders from tally-data
```

`os.args()` gives every argument, the program's own path first, so
`args.len > 1` asks whether the caller passed one. The text is
`Static`: it lives as long as the program and borrows from nothing, as a
literal does. That is why `args[1]` and `"tally-data"` can be the two
arms of one `if`. `os.env(name)` gives a `Static?`, which is `none` when
the variable is not set, and `??` supplies the default, as in [Errors
and optionals](03-errors.md). `rig run tally.rig -- /tmp/orders` passes
the directory.

## A file to write and read back

The tool needs a file of orders. This step writes one, looks at it,
reads it back, and removes it:

```rig
use std.file
use std.os

fun orders_json() -> String
  String(
    '[{"who": "ada", "item": "pen", "qty": 3}, {"who": "bob", "item": "ink", "qty": 1}, ',
    '{"who": "ada", "item": "ink", "qty": 2}, {"who": "cy", "item": "pen", "qty": 5}]',
  )

sub main()!
  args = os.args()
  dir = args[1] if args.len > 1 else "tally-file"
  title = os.env("ORDERS_TITLE") ?? "Orders"
  path = String(dir, "/orders.json")
  src = orders_json()
  file.write(?path, ?src, parents: true)!
  if file.stat(?path)! as s
    print(title, "file is", s.kind, s.size, "bytes")
  back = file.read(?path)! ?? String()
  print(back == src)
  _ = file.read(dir) catch |e|
    print(e)
    none
  print(file.remove(?path)!, file.remove(dir)!, file.remove(dir)!)
  print(file.read(?path)! == none)
```

```output
Orders file is .file 163 bytes
true
FileError.is_directory
true true false
true
```

Single quotes make a raw string, so the JSON needs no escapes.
With `parents: true`, `file.write` makes the missing directory, then the
file; without it, a missing directory is an error. Every call that
reaches the disk can fail, so `main` ends in `!` and each call does too:
the errors of [chapter three](03-errors.md).

**`none` means nothing is there; every other failure is an error.** `stat` and `read` give `none` for a
missing path, so `file.read(path)! ?? String()` treats a missing file as
empty and still reports one it may not read. Reading the directory is
a `FileError.is_directory`. `remove` says whether it removed anything,
and removes a directory only when it is empty. A task waiting on the
disk leaves the other tasks running.

## Orders from JSON

Next the orders must become values. `std.json` reads a document into a
tape, a flat list with one entry per value, in document order:

```rig
use std.file
use std.json

obj Order
  who: ?String
  item: ?String
  qty: Int

fun orders_json() -> String
  String(
    '[{"who": "ada", "item": "pen", "qty": 3}, {"who": "bob", "item": "ink", "qty": 1}, ',
    '{"who": "ada", "item": "ink", "qty": 2}, {"who": "cy", "item": "pen", "qty": 5}]',
  )

fun read_orders(doc: ?json.Doc) -> List[Order]
  orders = List[Order]()
  i = 1
  while doc.kind(i) == .object
    o = Order(who: "", item: "", qty: 0)
    i += 1
    while doc.kind(i) != .object_end
      key = doc.get_str(i)
      i += 1
      if key == "who"
        o.who = doc.get_str(i)
      else if key == "item"
        o.item = doc.get_str(i)
      else if key == "qty"
        o.qty = doc.get_int(i)
      i = doc.next(i)
    !orders.push(o)
    i += 1
  orders

sub main()!
  path = "tally-json/orders.json"
  file.write(path, orders_json(), parents: true)!
  src = file.read(path)! ?? String()
  doc = json.new_doc()
  if not (!doc).parse(?src)
    print("bad JSON:", json.error_name(doc.error), "at byte", doc.error_pos)
    return
  orders = read_orders(?doc)
  print(orders.len)
  for o in ?orders
    print(o.who, o.item, o.qty)
  bad = json.new_doc()
  if not (!bad).parse("[1, 2")
    print(json.error_name(bad.error), "at byte", bad.error_pos)
  _ = file.remove(path)!
  _ = file.remove("tally-json")!
```

```output
4
ada pen 3
bob ink 1
ada ink 2
cy pen 5
eof at byte 5
```

`parse` checks the whole text before it returns, and fills the tape. It
answers `true`, or `false` with `doc.error` and `doc.error_pos` set; a
bad document never reaches the walk. `doc.kind(i)` says what entry `i`
is, `doc.get_str(i)` and `doc.get_int(i)` read it, and `doc.next(i)`
gives the entry after the value at `i`, so it skips an array or an object
whole.

A string without escapes is a view of `src`, so an `Order` holds
`?String` views and copies no text. The chain of loans is the one of
[chapter two](02-ownership.md): `read_orders(?doc)` lends the document,
the orders keep `doc` lent, and `doc` keeps `src` lent. None of the
three can be changed or dropped while the orders live.

## Counting with a Map and a Set

From here the four orders are a list in the program. `hash.Map` counts
units for each customer, and `hash.Set` remembers each item once:

```rig
use std.hash

obj Order
  who: ?String
  item: ?String
  qty: Int

sub main()
  orders = [
    Order(who: "ada", item: "pen", qty: 3), Order(who: "bob", item: "ink", qty: 1),
    Order(who: "ada", item: "ink", qty: 2), Order(who: "cy", item: "pen", qty: 5),
  ]
  units = hash.Map[?String, Int].new()
  items = hash.Set[?String].new()
  for o in orders
    (!units).ensure(o.who, 0) += o.qty
    if (!items).add(o.item)
      print("first order of", o.item)
  print(units.len, items.len, units.get("ada"), units.get("dee"), items.has("ink"))
  for e in ?units.items()
    print(e.key, e.value)
```

```output
first order of pen
first order of ink
3 2 5 none true
ada 5
bob 1
cy 5
```

`(!units).ensure(o.who, 0)` puts `0` under a customer the first time,
and lends the value under that key to write, so one line counts every
order. `(!items).add(o.item)` says whether the item was new. Both change
their table, so both carry the `!` of chapter one. `get` and `has` only
read. `items()` walks the entries in the order they were first put in,
each a pair `e.key`, `e.value` for one step of the loop.

`get` gives a view, `(?V)?`, and a view keeps the map lent. The map
cannot change while the view lives:

```rig reject
use std.hash

sub main()
  units = hash.Map[?String, Int].new()
  !units.put("ada", 5)
  top = ?units.get("ada")
  !units.put("bob", 5)
  print(top)
```

```error
cannot lend `units` to write while a read loan is live
```

A `put` can move every value, as a push moves a list's storage. To keep
a count, copy it: `units.get("ada") ?? 0`.

## Putting them in order

The report lists customers by units. `std.sort` orders a slice in place,
and works on arrays and Lists alike:

```rig
use std.hash
use std.sort

obj Order
  who: ?String
  item: ?String
  qty: Int

obj Total
  who: ?String
  units: Int

sub main()
  orders = [
    Order(who: "ada", item: "pen", qty: 3), Order(who: "bob", item: "ink", qty: 1),
    Order(who: "ada", item: "ink", qty: 2), Order(who: "cy", item: "pen", qty: 5),
  ]
  units = hash.Map[?String, Int].new()
  for o in orders
    (!units).ensure(o.who, 0) += o.qty
  totals = List[Total]()
  for e in ?units.items()
    !totals.push(Total(who: e.key, units: e.value))
  sort.sort_by(!totals, |a, b| a.units > b.units)
  for t in ?totals
    print(t.who, t.units)

  sizes = List[Int]()
  for o in orders
    !sizes.push(o.qty)
  sort.sort(!sizes)
  print(sizes, sort.search(?sizes, 3), sort.search(?sizes, 9), sort.lower_bound(?sizes, 4))
```

```output
ada 5
cy 5
bob 1
[1, 2, 3, 5] 2 none 3
```

`sort_by(!totals, less)` takes the list lent to write, and `less(a, b)`
says whether `a` belongs before `b`. The sort is stable, so `ada` and
`cy`, tied at 5, stay in the order the map gave them. `sort(!sizes)`
uses `<`. On a sorted slice, `search` finds an index by binary search, or
`none`, and `lower_bound` gives the index where a value belongs.

`sort` orders with `<`, so it refuses an element that has none. The word
`sort_by` is how you give the order yourself:

```rig reject
use std.sort

obj Total
  who: ?String
  units: Int

sub main()
  totals = [Total(who: "ada", units: 5)]
  sort.sort(!totals)
```

```error
`sort.sort[Total]` cannot use `T = Total`: the generic body applies `<` to `T`
```

## How long it took

A tool that is slow should say so. `time.now()` reads the monotonic
clock, and `elapsed()` is the time since a reading:

```rig
use std.hash
use std.time

fun tally(qtys: ?List[Int]) -> Int
  counts = hash.Map[Int, Int].new()
  for q in qtys
    (!counts).ensure(q, 0) += 1
  counts.len

fun slow_audit(ms: Int) -> Int!
  time.sleep(ms * time.MS)!
  ms

sub main()
  qtys = List([3, 1, 2, 5, 4, 1])
  start = time.now()
  kinds = tally(?qtys)
  took = start.elapsed()
  print(kinds, took >= 0, took < time.SECOND)
  print(time.within(time.SECOND, || slow_audit(1)!) catch -1)
  r = time.within(5 * time.MS, || slow_audit(60_000)!) catch |e|
    print(e)
    -1
  print(r)
```

```output
5 true true
1
Stop.timeout
-1
```

A duration is an `Int` of nanoseconds, and `time.MS` and `time.SECOND`
write one. A reading is an `Instant`, which only gives the time between
two readings, so it cannot be mixed up with the wall clock. A timing
differs on every run, so this program prints facts about it. A tool
would print `took / time.MS`.

`time.within(ns, f)` is the deadline of [chapter four](04-concurrency.md).
The audit that sleeps a minute is cut short at 5 ms and fails with
`Stop.timeout`, and `catch` turns that into `-1`. `slow_audit` knows
nothing about deadlines.

## A sample at random

The tool picks two customers for a free pen. `std.random` is a
splitmix generator, and a seed fixes its sequence on every platform:

```rig
use std.random

sub main()
  a = random.Random.seeded(7)
  b = random.Random.seeded(7)
  names = ["ada", "bob", "cy", "dee", "eli", "flo"]
  twin = ["ada", "bob", "cy", "dee", "eli", "flo"]
  !a.shuffle(!names)
  !b.shuffle(!twin)
  print("winners:", names[0], names[1], names[0] == twin[0] and names[1] == twin[1])
  roll = (!a).int(1, 7)
  print(roll >= 1 and roll <= 6, (!a).float() < 1.0)
```

```output
winners: bob flo true
true true
```

`random.Random.seeded(7)` gives the same winners each run, which is
what a test needs. `random.Random.new()` seeds from the operating
system instead, so each run differs. `!a.shuffle(!names)` writes both
the generator and the slice, so it carries two marks. `int(1, 7)` is
from 1 up to but not including 7.

A generator is *unique*: it moves and is never copied. A copy would
draw the same numbers as the original, so `b = a` is refused. Make a
second generator on purpose with `(!a).fork()`:

```rig reject
use std.random

sub main()
  a = random.Random.seeded(7)
  b = a
  print((!a).next() == (!b).next())
```

```error
`a` is a unique `random.Random`, which can't be copied by `=`: write `<a` to move it or `?a` to view it
```

## Numbers past 64 bits

Suppose the orders carry ids from another system, 20 digits long. They
do not fit an `Int`. `std.bigint` parses and adds them:

```rig
use std.bigint

sub main()!
  ids = ["18446744073709551615", "36893488147419103232", "7"]
  sum = bigint.from_int(0)
  best = bigint.parse(ids[0])!
  for s in ids
    n = bigint.parse(s)!
    sum = sum.add(n)
    if n.compare(best) > 0
      best = n.clone()
  print(sum.text(), best.text(), best.bit_len())
  print((bigint.parse("12x") catch bigint.from_int(-1)).text())
```

```output
55340232221128654854 36893488147419103232 66
-1
```

`bigint.parse` fails with `ParseError.invalid` on text that is not a
number, and `catch` gives a fallback. A `BigInt` owns its limbs on the
heap, so it moves, and `n.clone()` makes the second one that `best` keeps.
`compare` returns -1, 0, or 1, and `bit_len` counts the bits of the
magnitude.

There is no `<` on a `BigInt`, since it would hide a walk over limbs.
`compare` and `equals` name the work:

```rig reject
use std.bigint

sub main()
  print(bigint.from_int(1) < bigint.from_int(2))
```

```error
operator `<` orders values of one type that provides `Ord`, and `bigint.BigInt` cannot be ordered
```

## Color on a terminal

A tool that prints color should check that its escape codes mean what
it thinks. `std.terminal` is a terminal emulator as a library: bytes go
in through `feed`, and the screen comes out of `dump`. It draws
nothing and reads no keys; it is the program at the other end of the
pipe.

```rig
use std.terminal

fun paint(code: ?String, word: ?String) -> String
  String("\x1b[", code, "m", word, "\x1b[0m")

sub main()
  t = terminal.Terminal.new(20, 3)
  !t.feed(paint("1;32", "ada"))
  !t.feed(" 6\r\n")
  !t.feed(paint("31", "bob"))
  !t.feed(" 5")
  print(t.dump())
```

```output
|ada 6
|bob 5
|
~0 0-2 bold fg=2
~1 0-2 fg=1
cursor 1 5
```

A line `~0 0-2 bold fg=2` says that row 0, columns 0 to 2, has the bold
flag and palette color 2, green. The last line is the cursor's row and
column. `1;32` is bold green and `31` is red; the reset `0` ends each
word, so the digits stay plain. The emulator follows xterm, so a test
can pin what a user would see.

## Serving the result

The last step shows the report over HTTP. It is checked and not run, since
a test cannot wait for a request:

```rig
use std.hash
use std.http
use std.net
use std.os

obj Order
  who: ?String
  qty: Int

fun report(orders: []Order) -> String
  units = hash.Map[?String, Int].new()
  for o in orders
    (!units).ensure(o.who, 0) += o.qty
  out = String()
  for e in ?units.items()
    !out.add(String(e.key, " ", e.value, "\n"))
  out

sub main()!
  orders = [Order(who: "ada", qty: 3), Order(who: "bob", qty: 1), Order(who: "ada", qty: 2)]
  body = report(?orders)
  args = os.args()
  addr = args[1] if args.len > 1 else "127.0.0.1:8080"
  hits = *Cell(0)
  l = net.listen(addr)!
  print("listening on", l.port())
  http.serve(<l, |+body, +hits, req|
    match req.path
      "/" => http.text(body)
      "/hits" => http.text(String("hits ", (!hits).add(1)))
      _ => http.not_found()
  )!
```

`net.listen(addr)!` opens a socket; port 0 lets the system pick one. `http.serve(<l, f)` takes the listener, so
the `<`. Each connection is a task, and each request runs `f` isolated,
as in chapter four: a panic in the handler answers 500 and the server goes on.

Every connection's task calls the same closure, so it may capture only
what can be shared. `+body` gives it a copy of the report and `+hits` a
handle to the one counter. A local named in the closure without a
capture is refused:

```rig reject
use std.http
use std.net

sub main()!
  seen = List[Int]()
  l = net.listen("127.0.0.1:0")!
  http.serve(<l, |req|
    !seen.push(1)
    http.text("ok")
  )!
```

```error
`seen` is a local of the enclosing function; capture it to use it inside the closure
```

`curl localhost:8080/` then prints `ada 5` and `bob 1`.

## How a library is shaped

Look back at the marks in this chapter: `!m.put(k, v)`, `<name`, `?doc`,
`+body`, `<l`. Each is a sigil of chapter one, in the place chapter one
gave it. A library never invents a mark. What it adds is words. This
program writes one map four ways:

```rig
use std.hash

sub main()
  m = hash.Map[String, Int].new()
  !m.put(String("ada"), 1)
  print((!m).put_new(String("ada"), 2), m.get("ada"))
  print((!m).replace(String("ada"), 3), m.get("ada"))
  print((!m).take("ada"), m.len)
  name = String("bob")
  !m.put(<name, 4)
  print(m.get("bob"))
```

```output
false 1
1 3
3 0
4
```

All four calls write the map, and all four say so with `!`. The word
says the policy, which is what happens when the key is there already.
`put` overwrites. `put_new` keeps the old value and says whether it
put. `replace` hands back the old value, and `take` removes the key and
hands back its value. `ensure` is one more answer.

The mechanics come from the signature in `std/hash.rig`: `sub put(!@, k:
K, v: V)`. The `!@` is why the call is `!m.put(...)`, and `k: K` takes
its argument, which is why a named `name` is written `<name`. Leave out
the mark and the error says what to write:

```rig reject
use std.hash

sub main()
  m = hash.Map[String, Int].new()
  m.put(String("ada"), 1)
```

```error
method `put` needs `self` lent to write; write `!m.put(String("ada"), 1)`
```

The same split runs through std. `file.read` is `String?!`: the type
holds the policy for a missing file (`none`) and for a broken one (an
error). `<ts.wait_first()` and `<t.cancel()` of chapter four are the
same: the `<` consumes the set or the task, and the word names the
policy. **Words name the policy; sigils mark the mechanics.**

## Summary

| To | Write |
|---|---|
| read arguments and variables | `os.args()`, `os.env("NAME") ?? "x"` |
| write, read, remove a file | `file.write(p, s)!`, `file.read(p)!`, `file.remove(p)!` |
| read JSON | `(!doc).parse(?src)`, then `doc.kind(i)`, `doc.get_str(i)`, `doc.next(i)` |
| count by key | `(!m).ensure(k, 0) += 1` |
| keep each key once | `(!s).add(k)` |
| put in order | `sort.sort(!xs)`, `sort.sort_by(!xs, less)` |
| time a step | `time.now()`, `t.elapsed()`, `time.within(ns, f)` |
| draw at random | `random.Random.seeded(n)`, `!r.shuffle(!xs)` |
| count past 64 bits | `bigint.parse(s)!`, `a.add(b)`, `a.compare(b)` |
| check color | `terminal.Terminal.new(c, r)`, `!t.feed(s)`, `t.dump()` |
| serve | `http.serve(<l, f)!` |

## What is not there yet

`std.json` is experimental: its names and shapes will change, to
fallible `!` functions, once errors can carry data. `std.terminal` is an
emulator, and the standard library lists no call to read standard input
or to ask whether output is a terminal. `std.net` is TCP, and host names
are not looked up. `std.http` is an HTTP/1.1 server with no TLS and no
client. `BigInt` has no division.

## Where to go next

- [Text done right](05-text.md) covers `std.text` and the four units
  of text.
- [Tests that fail the same way twice](08-tests.md) tests a tool like
  this one, concurrent parts included.
- [STD](../STD.md) documents every module in this chapter, and the rest:
  `std.math`, `std.slices`, `std.par`, and `hash.Symbols`.
- [SPEC §14](../../SPEC.md#14-modules) states how `use std.NAME` names a
  module.
