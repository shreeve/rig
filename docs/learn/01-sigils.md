# Sigils: a line that says what it does

Here is a line from a program you have never seen:

```text
process(orders)
```

What does it do to `orders`? It might read the list. It might add to
it, sort it, or empty it. It might keep it somewhere and change it
later, or free it, so that the next use of `orders` reads freed memory.
In Python, Go, or JavaScript you open `process` to find out. In C you
open it and hope the comment is right.

Rust answers part of the question on the line: `process(&orders)`
reads, `process(&mut orders)` writes, and `process(orders)` gives the
list away. The rest of the story is told in words: `Rc::new`,
`Rc::clone`, `Box::new`, `.upgrade()`, `.await`, `tokio::spawn`.

Rig answers all of it on the line, with one character each. Each
character is a **sigil**, and a sigil means the same thing wherever it
appears. This chapter introduces them in the order a program needs
them: naming a value, lending it, giving it away, holding it, failing,
and running work at the same time. At the end they fit in one table.

Every program here runs with `bin/rig run FILE.rig`, and prints what
the `output` block below it shows.

## A name for a value

A binding has no keyword. The first `x = e` in a scope declares `x`,
and later ones assign it:

```rig
sub main()
  total = 0
  total = total + 30
  limit =! 100
  print(total, limit)
```

```output
30 100
```

`limit =! 100` binds `limit` for good. Read the `!` as "for real": the
name never changes, and the compiler holds you to it.

```rig reject
sub main()
  limit =! 100
  limit = 101
  print(limit)
```

```error
cannot reassign fixed binding `limit`
```

That is the first sigil, and the only one about names. Every other
sigil is about values: who may read one, who may change it, and who is
responsible for it.

## Reading is unmarked

Most calls only look at their arguments, so looking costs nothing to
write. A parameter of type `?List[Int]` is a **read view**: the
function may read the list, and nothing more.

```rig
fun sum(xs: ?List[Int]) -> Int
  total = 0
  for x in xs
    total += x
  total

sub main()
  orders = List([30, 12, 58])
  print(sum(orders), sum(?orders))
  print(orders.len)
```

```output
100 100
3
```

`?orders` lends `orders` to read. Where the parameter is a read view,
the bare name means the same, so `sum(orders)` and `sum(?orders)` are
one call. The list is not copied, and `orders` is still the owner when
`sum` returns.

Three words keep this straight. The owner **lends**. The function gets
a **view**. What stays behind with the owner is a **loan**, and while
it lasts the owner may not change, move, or drop what it lent. A view
passed to a call ends when the call returns. A view kept in a binding
lasts as long as the binding is used, so that is where `?` is written:

```rig reject
sub main()
  orders = List([30, 12, 58])
  first = ?orders[0]
  !orders.push(5)
  print(first)
```

```error
cannot lend `orders` to write while a read loan is live
```

`first` views an element of the list. Pushing might move the list's
storage, and `first` would point at nothing. The compiler follows each
view back to the owner it came from, so there is no lifetime syntax to
write: the error names the line that made the loan.

## Writing is marked

A change is never silent. `!x` lends `x` to write, and a parameter of
type `!List[Int]` is a **write view**:

```rig
sub add_fee(xs: !List[Int], fee: Int)
  for x in !xs
    x += fee

sub main()
  orders = List([30, 12, 58])
  add_fee(!orders, 2)
  !orders.push(7)
  last = (!orders).pop() ?? 0
  print(orders[0], orders.len, last)
```

```output
32 3 7
```

Each of the three lines in `main` that changes `orders` says so.
`for x in !xs` walks the list with a write view of each element. A
method that changes its value takes the same mark, `!orders.push(7)`,
even though `main` owns the list. When the result of a write call is
used, the `!` goes in parentheses with its value, `(!orders).pop()`, so
it never reads as anything else.

Leave the mark off and the program does not compile. The error says
what to write:

```rig reject
sub add_fee(xs: !List[Int], fee: Int)
  for x in !xs
    x += fee

sub main()
  orders = List([30, 12, 58])
  add_fee(orders, 2)
```

```error
lend it to write: `!orders`
```

A value has any number of read views or one write view, never both.
That one rule is why the program above cannot read freed memory, and
why two parts of a program never change the same value at once.

Rig spells "not" as `not`. A `!` before a value always lends it to
write, so `!done` is a mistake the compiler names:

```rig reject
sub main()
  done = false
  while !done
    done = true
```

```error
use `not` for negation
```

## Giving a value away

Some values own resources: memory, a file, a connection. When such a
value goes to a new owner, the old name can no longer use it. `<x`
**moves** `x`:

```rig
obj Ticket
  id: Int

  drop(!@)
    print("ticket", @id, "closed")

sub file(t: Ticket)
  print("filed", t.id)

sub main()
  a = Ticket(id: 1)
  b = Ticket(id: 2)
  c = Ticket(id: 3)
  file(<a)
  <b
  print("main ends")
```

```output
filed 1
ticket 1 closed
ticket 2 closed
main ends
ticket 3 closed
```

`drop(!@)` runs when a `Ticket`'s owner lets it go. `file(<a)` moves
the first ticket into `file`, which owns it now and closes it when it
returns. `<b` alone on a line moves the second ticket nowhere, so it
drops there. The third ticket drops where its scope ends, at the end of
`main`. There is no garbage collector and no `free`: every release
happens at a point you can see.

After a move, the old name is gone:

```rig reject
sub show(xs: List[Int])
  print(xs.len)

sub main()
  xs = List([1, 2])
  show(<xs)
  print(xs.len)
```

```error
use of `xs` after move
```

A bare name moves a value only where its scope ends anyway: `return
x`, or `x` as the last value of the block that declares it. Anywhere
else the move is written, so a reader never mistakes a move for a
read.

## A copy of your own

`+x` makes a new owner: a copy you may change without touching the
original.

```rig
sub main()
  a = List([1, 2])
  b = +a
  !b.push(3)
  n = 5
  m = n
  print(a.len, b.len, n + m)
```

```output
2 3 10
```

Plain data, such as an `Int` or an object of numbers, copies on its
own: `m = n` needs no mark, because a copy of a number costs nothing
and owns nothing. A `List` owns memory, so copying it allocates, and
the `+` shows where that cost is paid.

## Self

A method names its value `@`, and says how it takes it with the same
sigils: `?@` reads, `!@` writes, and `<@` takes the value and uses it
up.

```rig
obj Order
  id: Int
  items: List[Int]

  fun total(?@) -> Int
    sum = 0
    for x in ?@items
      sum += x
    sum

  sub add(!@, price: Int)
    !@items.push(price)

  fun close(<@) -> Int
    print("closing order", @id)
    @total()

sub main()
  o = Order(id: 7, items: List())
  !o.add(30)
  !o.add(12)
  print(o.total())
  print(<o.close())
```

```output
42
closing order 7
42
```

The call matches the declaration: a read is bare, `o.total()`; a write
is marked, `!o.add(30)`; and a call that consumes `o` moves it,
`<o.close()`. `@items` is a field of self, and `@` is always written,
so a field never hides behind a local's name.

## Where a value lives

An object is a value. It lives where it is declared, on the stack or
inside another value, and `b = a` copies or moves it. Three sigils put
a value somewhere else.

**`^x` boxes it.** A box holds one value on the heap, with one owner.
A note that points to the next note needs one, because a `Note` that
held a `Note` would have no finite size:

```rig
obj Note
  text: ?String
  next: ^Note?

fun count(n: ?^Note?) -> Int
  if n as x
    1 + count(?x.next)
  else
    0

sub main()
  last = Note(text: "pay rent", next: none)
  list: ^Note? = ^Note(text: "buy milk", next: ^<last)
  print(count(?list))
```

```output
2
```

`^<last` moves `last` into a new box. When `list` drops, its box
drops, and so does every note it holds.

**`*x` shares it.** A shared handle is a counted pointer, like Rust's
`Rc`. `+h` makes another handle to the same value, and the value lives
until its last handle goes. What handles share is read-only; state
that changes goes in a `Cell`, and a change is a marked call:

```rig
sub main()
  hits = *Cell(0)
  copy = +hits
  !hits.set(hits.get() + 1)
  !copy.set(copy.get() + 1)
  print(hits.get(), copy.get())
```

```output
2 2
```

Here `+` does what it always does, make a new owner, and for a handle
the new owner is a second handle to the same cell.

**`~h` holds it weakly.** A weak handle does not keep the value alive.
`*w` upgrades it: a strong handle while the value lives, `none` after.

```rig
obj Printer
  name: ?String

  drop(!@)
    print("printer", @name, "off")

sub status(w: ?~Printer)
  if *w as p
    print(p.name, "is on")
  else
    print("no printer")

sub main()
  office = *Printer(name: "lobby")
  desk = +office
  watch = ~office
  <office
  status(?watch)
  <desk
  status(?watch)
```

```output
lobby is on
printer lobby off
no printer
```

Dropping `office` leaves the printer on, because `desk` still holds
it. Dropping `desk` turns it off, and `watch` sees that. Two strong
handles that point at each other would keep each other alive forever;
a weak handle is how a child points at its parent without that leak.

The same characters write types: `^Note` is a box, `*Cell[Int]` a
shared handle, `~Printer` a weak one, and `?T` and `!T` the two
views.

## Absent, and failed

Two sigils come after a type. `T?` may be absent, and holds a `T` or
`none`. `T!` may fail, and holds a `T` or an error. After an
expression, the same two characters pass the absence or the failure up
to the caller: `e?` returns `none` if `e` is `none`, and `e!` returns
the error if `e` failed.

```rig
error Stock
  empty

fun first(xs: ?List[Int]) -> Int?
  return none if xs.len == 0
  xs[0]

fun take(xs: !List[Int]) -> Int!
  return Stock.empty if xs.len == 0
  (!xs).pop() ?? 0

fun next_price(xs: ?List[Int]) -> Int?
  first(?xs)? + 1

fun take_two(xs: !List[Int]) -> Int!
  take(!xs)! + take(!xs)!

sub main()
  shelf = List([4, 9, 6])
  print(next_price(?shelf))
  print(take_two(!shelf) catch -1)
  print(take_two(!shelf) catch -1)
  print(first(?shelf) ?? 0)
```

```output
5
15
-1
0
```

`??` gives an optional a fallback, and `catch` handles a failure. The
first `take_two` takes the 6 and the 9. The second takes the 4, then
fails on the empty shelf, so it gives `-1`, and `first` finds nothing
and gives the fallback, `0`.
Every call that may fail says what happens to the failure, on the line:
it is passed up with `!` or handled with `catch`. There is no
exception that crosses five functions unseen.

Rust readers will reach for `?` on a failure. In Rig, `?` is about
absence only, and the compiler says which one you meant:

```rig reject
fun parse(s: ?String) -> Int!
  s.len

fun twice(s: ?String) -> Int!
  parse(s)? * 2
```

```error
propagate the failure with `parse(s)!`
```

## Running at the same time

The last two sigils run work concurrently. `f(x)&`, the **dispatch
sigil**, runs the call as a **task**, and `>t`, the **wait sigil**,
waits for the task and takes its result:

```rig
fun sq(x: Int) -> Int
  x * x

fun sum(xs: ?List[Int]) -> Int
  total = 0
  for x in xs
    total += x
  total

sub main()
  orders = List([30, 12, 58])
  t = sq(9)&
  u = sum(?orders)&
  print(>t, >u)
```

```output
81 100
```

`sq` and `sum` are ordinary functions. Nothing in their declarations
says they may run as tasks, and nothing in a function that waits says
so either. The `&` and the `>` are written where the concurrency
happens, and nowhere else.

The task also follows the rules you have already met. `sum(?orders)&`
lends `orders` to the task, and the loan lasts until `>u` takes the
result. So the task reads the list in place, with no copy and no lock,
and nothing may change it meanwhile:

```rig reject
fun sum(xs: ?List[Int]) -> Int
  total = 0
  for x in xs
    total += x
  total

sub main()
  orders = List([30, 12, 58])
  u = sum(?orders)&
  !orders.push(1)
  print(>u)
```

```error
cannot lend `orders` to write while a read loan is live
```

That is the error from the section on reading, word for word. A task
is not a new kind of thing with new rules; it is a call whose loan
lasts until its result is taken. [Concurrency without
async](04-concurrency.md) follows that idea to actors, deadlocks, and
tests that replay.

## `?` and `!`, one idea each

By now `?` and `!` have each appeared in four places. They carry one
idea each:

| | before a value | before a type | after a type | after an expression |
|---|---|---|---|---|
| `?` "maybe, just look" | `?x` lend to read | `?T` read view | `T?` optional | `e?` pass `none` up |
| `!` "for real, act" | `!x` lend to write | `!T` write view | `T!` can fail | `e!` pass a failure up |

`!` means "act": write, or fail, or bind for real. As in Ruby's
`sort!` and Scheme's `set!`, it marks something that changes things.
`?` means "maybe": a look that changes nothing, or a value that may not
be there.

The position tells you which. A sigil before a value or a type says
how the value is held. A `?` or `!` after a type or an expression is
about absence and failure. And a sigil always touches what it marks:
`?v`, `Int?`, `first(?xs)?`, `take(!xs)!`. Spacing is never what
decides, so `a < b` is a comparison and `f(<b)` a move.

## Reading a line

Put together, the sigils let a program be read without opening what it
calls. Here four tasks post to one ledger at once:

```rig
obj Ledger
  entries: List[Int]

  sub post(!@, n: Int)
    !@entries.push(n)

  fun count(?@) -> Int
    @entries.len

sub work(ledger: *Actor[Ledger], n: Int)
  for 0..n
    !ledger.post(1)

sub main()
  ledger = *Actor(Ledger(entries: List()))
  ts = Tasks[Void]()
  for 0..4
    !ts.add(work(+ledger, 100)&)
  >ts
  print(ledger.count())
```

```output
400
```

Read the busiest line from the inside out. `+ledger` makes another
handle to the shared ledger. `work(...)&` runs `work` as a task that
owns that handle. `!ts.add(...)` changes the task set `ts` by adding
the task to it. Then `>ts` waits for every task in the set.

`*Actor(...)` is the one new thing: a shared value whose methods run
one at a time, so four tasks can call `!ledger.post(1)` and no entry is
lost. It is still written with `*`, because it is still a shared
handle, and each change is still marked with `!`. Nothing is copied
that the program does not show, nothing changes that it does not mark,
and nothing runs concurrently but the calls with an `&`.

## The whole family

Here are all of them, grouped by what they do:

| Mechanic | Sigils |
|---|---|
| Binding | `x = e` binds, `x =! e` binds for good |
| Taking and copying | `<x` moves (alone on a line, drops), `+x` copies or makes another handle |
| Lending | `?x` lends to read, `!x` to write; as types, `?T` and `!T` |
| Holding | `*x` shared (`*w` upgrades a weak handle), `^x` boxed, `~x` weak, `@` self |
| Failure and absence | `T?` may be absent, `T!` may fail; `e?` and `e!` pass them on |
| Concurrency | `f(x)&` sends work off, `>t` takes its result back |

The table is short on purpose. Each row is a mechanic: something every
program does, on almost every line, whose meaning never changes. Those
earn a single character, because a reader sees them constantly and
must never have to look them up twice.

Everything else is a word. Logic is `not`, `and`, and `or`. Handling a
failure is `catch`. Canceling a task is a method, `<t.cancel()`, and so
is waiting for the first of several, `<ts.wait_first()`. Those are
choices a program or a library makes, and a library can add more
without the language growing a character. Note that even the words
take sigils: `<t.cancel()` moves the task into `cancel`, because
canceling uses it up.

That is the principle behind the whole design:

**Sigils are the language's mechanics; words are its libraries.**

## Where to go next

- [Ownership without a collector](02-ownership.md) follows the loan
  from one call to whole programs: containers, fields, closures, and
  the one leak the compiler does not prevent.
- [Errors and optionals](03-errors.md) shows `T?` and `T!` at the
  scale of a parser.
- [WELCOME.md](../../WELCOME.md) translates each sigil to Rust and
  Zig, and [SYNTAX.md](../../SYNTAX.md) lists every position a sigil
  may take.
