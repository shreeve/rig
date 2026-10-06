# The Rig Core

This page states Rig's whole ownership model in plain sentences. The
other documents and the compiler derive their ownership rules from it:
[SPEC](../SPEC.md) gives the details, [SYNTAX](../SYNTAX.md) the forms,
and [WELCOME](../WELCOME.md) teaches it. A rule anywhere else that does
not follow from a sentence here is a mistake in one of them.

**Scope:** ownership only. Types, numbers and their conversions,
generics' per-instance checks, modules, FFI, and pure syntax are in
SPEC and SYNTAX.

**Status.** Every rule is marked *(built)*, true of today's compiler, or
*(planned)*, decided but not built yet. Every example here is run by the
test suite. A built rule's example runs, or is rejected, as shown. A
planned rule's example is a `rig pending` block: it shows the decided
behavior, and the suite checks that it does not work yet, so the block
becomes an ordinary example in the change that builds the rule
([test/README.md](../test/README.md#doc-examples)).

**Three words.** *You lend a view; the compiler remembers the loan.*

The sigil is written on the owner's side. In `print(?v)` and `grow(!v)`,
the `?` or `!` sits on `v`, the owner, exactly where the owner hands
something over. So the verb belongs to the owner: `v` **lends**. Each of
the three words belongs to one side of that hand-over, and means one
thing only:

| Word | What it is | Which side | Where you see it |
|---|---|---|---|
| **lend** | the act | the owner's | the sigil: `?x` lends to read, `!x` lends to write |
| **view** | the value handed over | it travels with the receiver: copied, returned, stored | a value of type `?T`, `!T`, `[]T`, `![]T`, or `String` |
| **loan** | the record | it stays with the owner, and limits the owner until every view is done | in the compiler, and in its error messages |

- To **lend** `x` is to let someone use it without taking it. A lend
  happens once, on one line.
- A **view** is what they get. Copying a read view copies the view, not
  what it views, and every copy carries the same loan.
- A **loan** is the compiler's record that views of `x` exist. While it
  is live, `x` may not change, move, or drop in a way a view would
  notice. A loan lasts until the last use of every view that carries it,
  not until the lend's line ends.

One lend makes one loan, which any number of views may carry:

```rig reject
sub main
  v: Vec[Int] = Vec()
  !v.push(1)
  a = ?v[..]
  b = a
  !v.push(2)
  print(a, b)
```

```error
cannot lend `v` to write while a read loan is live
```

The lend is on line 4 (`?v[..]`). The loan stays with `v` while the
views `a` and `b` are still used below, so `!v.push(2)` is rejected.
*Borrow*, the word Rust uses, names the same event from the receiver's
side; Rig names everything from the side the sigil is on.

---

## 1. Four kinds of value

| Kind | Examples | A plain use | Status |
|---|---|---|---|
| **plain** | `Int`, `Bool`, enums, structs whose parts are all plain | copies | built |
| **owning** | `Vec[T]`, `Box[T]`, `Text`, structs holding an owner | moves; one owner; dropped once | built |
| **handle** | `*T` (counted), `~T` (weak), owned closures (`*fun`) | moves; `+h` adds a count | built |
| **view** | `?T`, `!T`, `[]T`, `![]T`, `String` | a read view copies; a write view reads the value it sees where that copies (sentence 1), and otherwise moves with `<w` | built |

**A struct's or enum's kind follows from its parts:** it is owning if
any part is owning or a handle; otherwise a view if any part is a view
(moving, if one is a write view); otherwise plain. *(built)*

```rig
struct Point
  x: Int
  y: Int

sub main
  a = Point(x: 1, y: 2)
  b = a
  b.x = 5
  print(a.x, b.x)
```

```output
1 5
```

**Two kinds the parts can't show:**

- **A type that must not be copied but owns nothing**, such as a random
  generator whose copy would repeat its numbers, says so on the type:
  `struct Random unique`. It moves like an owner. *(built)*
- **A type that holds a `Cell`**, or a bare `Cell[T]`, is unique too,
  because a copy would fork state that should be shared. *(built)*

```rig reject
sub main
  c = Cell(1)
  d = c
  d.set(2)
  print(c.get())
```

```error
use `<c`
```

## 2. The core, in ten sentences

**1. A bare name or place only reads.** It copies plain data and read
views, and reads owners and handles in place; a write view of a number,
`Bool`, `String`, or plain enum, whether a name, a field, or an element
holds it, reads the value it sees, so `x = h.w` with `w: !Int` copies
the Int. It never clones, writes, or drops, and it moves only where the
value leaves for good: `return x`, `break x`, or `x` as the last value
of the function or block that declares `x`. *(built* for copies, `return x`, a function's last value, a
block's last value when the block declares the name, and reading in
place: an argument where a view is expected (`size(v)` for a
`?Vec[Int]` parameter), and a header's subject (a `for` over a `Vec`,
`if o as x`, a `match` on a `Box`, whose payload views are usable within
their arm only, for now); *planned:* `break x` of a name the loop
declares, which takes `<x` today. A name declared outside the block
always takes `<x`.*)*

```rig
fun make -> Vec[Int]
  v: Vec[Int] = Vec()
  !v.push(1)
  v

sub main
  v = make()
  print(v.len)
```

```output
1
```

```rig
sub main
  v: Vec[Int] = Vec()
  !v.push(1)
  !v.push(2)
  for x in v
    print(x)
  print(v.len)
```

```output
1
2
2
```

```rig
struct H
  w: !Int

sub main
  n = 1
  m = 2
  h = H(w: !n)
  g = H(w: !m)
  x = h.w
  h.w = g.w
  x += 10
  print(x, n, m)
```

```output
11 2 2
```

```rig reject
struct H
  v: !Vec[Int]

sub main
  xs: Vec[Int] = Vec()
  h = H(v: !xs)
  y = h.v
  print(y.len)
```

```error
write `y = !h.v` to lend the view on
```

```rig pending
fun first -> Vec[Int]
  e: Vec[Int] = Vec()
  r = while true
    v: Vec[Int] = Vec()
    !v.push(1)
    break v
  else
    <e
  r

sub main
  print(first().len)
```

```output
1
```

**2. `<x` moves, `+x` makes a new owner, `-x` drops now.** `+x` is a
copy, a count bump, or a deep copy, as the type says; a `unique` type,
one with a `drop` body, or one holding a write view has none. *(built;*
a deep copy of a type declared in another module, or of one holding a
`Signal`, is *planned*.*)*

```rig
struct File
  name: String

  drop(!self)
    print("closing", self.name)

sub main
  a = File(name: "a.txt")
  b = <a
  -b
  print("end")
```

```output
closing a.txt
end
```

```rig
sub main
  v: Vec[Int] = Vec()
  !v.push(1)
  w = +v
  !w.push(2)
  print(v.len, w.len)
```

```output
1 2
```

```rig file=bag.rig
pub struct Bag
  pub items: Vec[Int]
```

```rig pending
use bag

sub main
  a = bag.Bag(items: Vec())
  !a.items.push(1)
  b = +a
  !b.items.push(2)
  print(a.items.len, b.items.len)
```

```output
1 2
```

**3. Drop points.** An owner that is not moved is dropped where its
scope ends. *(built)* A value no name holds is dropped where its
statement ends ([§3](#3-temporaries)). *(built)*

**4. `?x` lends `x` to read, and `!x` lends it to write, as whichever
view the context expects** ([§4](#4-one-lend-table)). A read lend may go
unwritten where its view lasts only for the use: an argument, a
method's receiver, or a header's subject (sentence 1). A lend kept in a
binding or a field is written, and so is every write lend. `!` lends any
value to write, named or temporary: `!mk().pop()` lends the value
`mk()` makes, which lives until its statement ends ([§3](#3-temporaries)),
so every change is still marked by `!`. *(built* for the rows of §4
marked built.*)*

```rig
sub grow(v: !Vec[Int])
  !v.push(7)

fun first(v: ?Vec[Int]) -> Int
  v[0]

sub main
  v: Vec[Int] = Vec()
  grow(!v)
  print(first(?v))
```

```output
7
```

```rig
struct Counter
  n: Int

  fun next(!self) -> Int
    self.n += 1
    self.n

fun start -> Counter
  Counter(n: 41)

sub main
  print(!start().next())
```

```output
42
```

**5. A value has any number of read loans, or one write loan, never
both.** This holds for every type, numbers included. *(built)*

```rig reject
sub add(a: !Int, b: ?Int)
  a += b

sub main
  n = 1
  add(!n, ?n)
```

```error
cannot lend `n` to read while a write loan is live
```

**6. A loan lasts until the last use of every view that carries it,**
wherever that view went: a field, an array, an optional, a closure, a
result. Dropping a value uses the views it holds only when its
drop runs a `drop` body, which could read them, so a `Vec[[]Int]`'s
loans end at its last use, not where it is dropped. *(built)*

```rig reject
sub main
  v: Vec[Int] = Vec()
  r = ?v
  !v.push(2)
  print(r.len)
```

```error
cannot lend `v` to write while a read loan is live
```

```rig
sub main
  a = [1, 2, 3]
  v: Vec[[]Int] = Vec()
  !v.push(?a[..2])
  print(v)
  a[0] = 9
  print(a)
```

```output
[[1, 2]]
[9, 2, 3]
```

```rig reject
struct Guard
  items: []Int

  drop(!self)
    print(self.items.len)

sub main
  a = [1, 2, 3]
  g = Guard(items: ?a[..])
  print(g.items[0])
  a[0] = 9
```

```error
cannot assign to `a[...]` while `a` is lent
```

**7. A call passes on only the loans its signature shows.** A function
returns a view only of what it was lent, or of something that lives for
the whole program (literals, module constants, `os.args()`). Its result
carries the loans of the arguments whose types could hold what it views,
or, when the result says `from a`, of `a` alone. A result that holds no
write view carries them as read loans, even one of an argument lent to
write, whose write lend then ends as the call returns unless the call
may store it: after `head(!v)`, in its own statement or through
`r = head(!v)`, `v` may be read, but not written, while the result
lives. A view reached through
a read view that a value holds carries that view's loans, not a loan on
the holder; one reached through a write view the value holds keeps the
holder lent too. The compiler checks each
body against its signature. *(built)*

```rig reject
fun pick(a: ?Vec[Int]) -> ?Vec[Int]
  v: Vec[Int] = Vec()
  ?v
```

```error
which this function was not lent
```

A `Cursor` holds only a view of the items, so an item `next` hands out
views the Vec, not the cursor, which moves on:

```rig
struct Item
  n: Int

struct Cursor
  items: ?Vec[Item]
  i: Int

  fun next(!self) -> ?Item
    self.i += 1
    ?self.items[self.i - 1]

sub main
  v: Vec[Item] = Vec()
  !v.push(Item(n: 1))
  !v.push(Item(n: 2))
  c = Cursor(items: ?v, i: 0)
  a = !c.next()
  b = !c.next()
  print(a.n, b.n)
```

```output
1 2
```

```rig
fun head(v: !Vec[Int]) -> []Int
  !v.push(v.len)
  ?v[..1]

sub main
  v: Vec[Int] = Vec()
  r = head(!v)
  print(v.len, v[0])
  print(r)
  print(head(!v), v.len)
```

```output
1 0
[0]
[0] 2
```

```rig reject
fun head(v: !Vec[Int]) -> []Int
  !v.push(v.len)
  ?v[..1]

sub main
  v: Vec[Int] = Vec()
  r = head(!v)
  !v.push(5)
  print(r)
```

```error
cannot lend `v` to write while a read loan is live
```

```rig
fun first(a: ?Vec[Int], b: ?Vec[Int]) -> ?Vec[Int] from a
  a

sub main
  x: Vec[Int] = Vec()
  y: Vec[Int] = Vec()
  r = first(?x, ?y)
  !y.push(1)
  print(r.len)
```

```output
0
```

**8. `*<x` moves `x` into a counted box, and `*S(...)` boxes a new
value.** Handles only read (a `Cell` inside one still changes: sentence
9). `~h` holds the box weakly, and `h.upgrade()` is the way back.
*(built)*

```rig
struct User
  name: String

sub main
  u = User(name: "ada")
  a = *<u
  w = ~a
  if w.upgrade() as h
    print(h.name)
  -a
  if w.upgrade() as h
    print("still here")
  else
    print("gone")
```

```output
ada
gone
```

**9. Shared storage.** Every change is marked by `!` where it is lent,
with one exception: a `Cell` changes through any path. A name's own
value changes by assigning it. `Cell`, `Signal`, and owned closures
accept only values that carry no loan; a `*T` instead carries its
contents' loans on every handle. *(built)*

```rig
sub main
  c = *Cell(0)
  d = +c
  d.set(5)
  print(c.get())
```

```output
5
```

**10. `e!` propagates a failure, and `e?` propagates an absence.** Every
fallible call says what happens to its failure: `!` or `catch`.
*(built)* Failing is always written: an error value meets a `T!` only as
the operand of `return`. *(built)*

```rig reject
error Bad
  oops

fun half(n: Int) -> Int!
  if n % 2 == 1
    Bad.oops
  else
    n / 2

sub main
  print(half(4) catch 0)
```

```error
return Bad.oops
```

Only code inside `raw` may break these rules. *(built)*

## 3. Temporaries

*(built.* A lend of a branching value that may be a name's,
`?(a if c else b)`, is *planned*; today each branch is lent, `?a if c
else ?b`.*)*

```rig pending
sub main
  a = Text("a")
  b = Text("b")
  c = a.len > 0
  s = ?(a if c else b)
  print(s)
```

```output
a
```

**Taking and reading.** An expression either *takes* its value or only
*reads* it.

- **Taking:** a binding, an argument to a parameter that owns it,
  `return`, a stored field or element, or `<`.
- **Reading:** a `print` or `Text(...)` argument, an `==` operand, `?e`,
  `+e`, a `?self` receiver, or a field or element read.

Reading never moves a name, whatever form reads it: `print(a if c else
b)` moves nothing.

**What counts as a temporary.** A value made where it is only read has
no name: a call's result, a constructor, `+x`, or a block or `match`
value. Its statement is its scope, so it is a *temporary*, dropped when
the statement ends, the last made first, also when the statement fails
or leaves early. A temporary may be lent to read or to write (sentence
4), and a view of it may be used only within its statement.

**Headers are their own statements:** an `if` or `while` condition, a
guard, and the subject of a `match` or `for`. A header's temporaries
end with the header; what the header binds lives through the body. A
value made there that `if … as`, `while … as`, `match`, or `for` binds
is taken, as `<e` would take it: a call's result, or a branching value
whose every branch is made there (`mk() if c else <a`). So
`if starts_with(?Text(a, b), "x")` works, but
`if cut(?Text(a, b), "=") as kv` must bind the `Text` first, because
`kv` outlives the header. *(built* for `if … as`, `while … as`, `match`,
and a `for` over plain elements; *planned* for a `for` over a made Vec
of owners, which is bound to a name first today.*)*

```rig
struct User
  name: String
  tags: Vec[Int]

fun load -> User
  User(name: "ada", tags: Vec())

sub main
  print(load().name)
```

```output
ada
```

```rig
use std.text

sub main
  a = "x"
  b = "yz"
  if text.starts_with(?Text(a, b), "xy")
    print("starts")
```

```output
starts
```

```rig reject
use std.text

sub main
  if text.cut(?Text("k", "=v"), "=") as kv
    print(kv.after)
```

```error
a view of the temporary `Text("k", "=v")` outlives its statement
```

```rig pending
fun names -> Vec[Text]
  v: Vec[Text] = Vec()
  !v.push(Text("ada"))
  v

sub main
  for x in names()
    print(x)
```

```output
ada
```

## 4. One lend table

`?x` and `!x` lend the view the context expects:

| Owner `x` | `?x` lends | `!x` lends | Status |
|---|---|---|---|
| any `T` | `?T` | `!T` | built |
| `[N]T`, `Vec[T]` | `[]T` | `![]T` | built |
| a place `p.f` or `v[i]` | the views of the field or element | its write views | built |
| a held `!T` | `?T` | `!T` (lent on) | built |
| `![]T` | `[]T` | `![]T` (lent on) | built |
| `Text` | `String` (also `String?`) | `!Text` | built |
| `Box[T]` | the views of `T` | the write views of `T` | built |
| `*T` | the read views of `T` | nothing of the value (`!h` lends the handle itself) | built |
| `X?` | `View?` for each view of `X` | `!(X?)`, by the first row | built |
| a function or closure | `?fun` | | built |

A read view of a number, `Bool`, `String`, or plain enum copies, and
carries no loan once copied out, as with a call's `?Int` result.
*(Copying a plain struct, array, or optional out of a read view is
planned; today it is lent on.)* A slice `x[a..b]` is the same lend, of
part of `x`. So `sort.sort(!v)` works on a `Vec` as it does on an array,
and one `fun area(s: ?Shape)` serves a `Shape`, a `Box[Shape]`, and a
`*Shape`.

```rig
use std.sort

sub main
  a = [3, 1, 2]
  sort.sort(!a)
  print(a)
```

```output
[1, 2, 3]
```

```rig pending
struct P
  x: Int
  y: Int

fun copy(p: ?P) -> P
  p

sub main
  a = P(x: 1, y: 2)
  b = copy(?a)
  print(b.x)
```

```output
1
```

A `Text` lends a `String`, which views its bytes, so the `Text` may not
change while the view is used:

```rig
use std.text

fun or_none(s: String?) -> String
  s ?? "none"

sub main
  t = Text("  hi  ")
  print(text.trim(?t), or_none(?t).len)
  !t.add("!")
  print(t)
```

```output
hi 6
  hi  !
```

```rig reject
sub main
  t = Text("abc")
  s = ?t[..2]
  !t.add("d")
  print(s)
```

```error
cannot lend `t` to write while a read loan is live
```

```rig
use std.sort

sub main
  v: Vec[Int] = Vec()
  !v.push(3)
  !v.push(1)
  sort.sort(!v)
  print(v[0], v[1])
```

```output
1 3
```

## 5. Containers and fields hold anything

`Vec`, arrays, `![]T`, and struct fields hold any kind of value. Each
field and element is a place:

- `p.f` and `v[i]` read it (sentence 1);
- `?p.f`, `!p.f`, `?v[i]`, and `!v[i]` lend it;
- `<p.f` and `<v[i]` take an optional one, leaving `none`;
- assigning to it drops the old value.

`<`'s operand is a place or a made value: `<(a if c else b)` is written
`<a if c else <b`. `swap` and `sort_by` work for any element; `sort`
needs `<`. `copy`, `fill`, and `[n of x]` duplicate values, so they
need copyable elements *(built* for elements that hold no `?T`, `!T`, or
slice; *planned* for read-view elements*)*. So `Vec[Text]`,
`Vec[Vec[Int]]`, and a list of records that each own a string just
work. *(built)*

```rig
struct Slot
  item: Box[Int]?

sub main
  s = Slot(item: Box(7))
  if <s.item as b
    print(<b.unbox())
  print(s.item)
```

```output
7
none
```

```rig
sub main
  rows: Vec[Vec[Int]] = Vec()
  r: Vec[Int] = Vec()
  !r.push(5)
  !rows.push(<r)
  print(rows.len, rows[0].len)
```

```output
1 1
```

```rig pending
sub main
  n = 1
  a = [3 of ?n]
  print(a[2])
```

```output
1
```

## 6. Bindings and assignment

**Evaluation order.** `x = e` evaluates `e` first, then the indexes in
`x` from left to right, then finds `x`'s place, then stores. This
matches Rust for `=`. *(built)*

```rig
fun next(i: !Int) -> Int
  i += 1
  i

sub main
  a = [0, 0, 0]
  i = 0
  a[i] = next(!i)
  print(a)
```

```output
[0, 1, 0]
```

A call evaluates its receiver and arguments left to right, then runs. A
value an earlier argument reads stays lent until the call returns, so a
later argument can't change it. A write lend of a method's receiver
acts as a read loan until the call starts, so `!v.push(v.len)` works; a
write lend in any other argument is a write loan at once, so
`grow(!v, v.len)` is rejected. *(built)*

```rig
sub main
  v: Vec[Int] = Vec()
  !v.push(v.len)
  !v.push(v.len)
  print(v)
```

```output
[0, 1]
```

```rig reject
fun grow(v: !Vec[Int]) -> Int
  !v.push(1)
  v.len

sub main
  v: Vec[Int] = Vec()
  print(v, grow(!v))
```

```error
while an earlier argument's read of it is in use
```

**Bindings.** A local binding may be reassigned. Parameters and `const`
bindings may not. *(built)*

```rig
sub main
  const limit = 3
  print(limit)
```

```output
3
```

**View places.** Assigning a view to a place that holds one re-points
it, and assigning a value writes through. This holds for locals and
fields alike. `new` only shadows, and accepts every binding form.
*(built)*

```rig
sub main
  m = 1
  n = 2
  w = !m
  w = !n
  w = 5
  print(m, n)
```

```output
1 5
```

## 7. Closures and defer

**Closures.** A closure captures each name with a sigil: `?x` lends
`x` to read for the closure's life, `!x` lends it to write, `<x` moves it in,
and `+x` captures a copy of plain data or a new count of a handle
*(built)*, or a deep copy of an owner *(planned)*. A stack closure may
be lent (`?fun`) but not stored. An owned closure (`*fun`) may be
stored, and follows sentence 9. *(built)*

```rig
sub main
  total = 0
  add = |!total, k: Int| total += k
  add(2)
  add(3)
  print(total)
```

```output
5
```

```rig pending
sub main
  v: Vec[Int] = Vec()
  !v.push(1)
  f = |+v| v.len
  print(f(), v.len)
```

```output
1 1
```

**Defer.** `defer` and `errdefer` run where their scope ends. They may
read and write what is live there; they never extend a loan past it.
*(built)*

```rig
sub main
  defer print("last")
  print("first")
```

```output
first
last
```

## 8. Outside the core: syntax, not ownership

These are single documented syntax rules, not ownership. Every other
rule in SYNTAX is syntax too.

- **`-x`:** as a statement, `-name` drops; as a value, `-x` negates. A
  statement `-f()`, or `-n` of plain data, is rejected. *(built)*
- **The receiver-sigil rule:** `!v.push(x)` applies `!` to `v`, and
  `!mk().pop()` applies it to `mk()`. *(built)*
- **`const x = e`:** a binding that never changes. *(built)*
- **A write call whose `Bool` value is used** is written
  `(!s).insert(k)`, everywhere. *(built)*
- **Labels**, the `catch` forms, `pass`, and `??`.
- **Habits from other languages that keep Rig's meaning,** documented
  rather than changed: integer `/` and `%` truncate as in C; `u?.n`
  propagates `none` from the function; `break` inside a `match` leaves
  the loop; `e catch a if c else b` groups as `e catch (a if c else b)`.

```rig reject
fun count -> Int
  3

sub main
  -count()
```

```error
a statement `-e` drops a name
```

```rig reject
struct Seen
  items: Vec[Int]

  fun insert(!self, k: Int) -> Bool
    for x in ?self.items
      return false if x == k
    !self.items.push(k)
    true

sub main
  s = Seen(items: Vec())
  added = !s.insert(1)
  print(added)
```

```error
(!s).insert(...)
```

## 9. Inside the compiler

Not visible to programs: the compiler decides each of these once, and
no pass decides them again by looking at syntax.

- **Per type, one fact each:** copyable; unique; needs cleanup; may hold
  a loan; cloneable; how a read view is represented (a copy, or a
  pointer). *(built)*
- **Per expression, one classification** of what it hands over: a
  place, a made value, a lend, branches, or a jump *(built)*; whether it
  is a view, and whether the value lives for the whole program
  *(planned)*.
- **Per path, one exit primitive,** which runs defers, reports any loan
  it would drop, and rewinds when the path goes on. *(built)*

## 10. How a feature earns its way in

- It fits one paragraph on this page, with no exception list.
- Its rules follow the value's type, never where the value came from.
- It is written as a desugaring into forms this page already covers.
- A second round of soundness fixes stops it for redesign.
- It passes the regression corpus, and runs clean under the sanitizer.
- It answers a line that failed in a real program, not parity with Rust
  or Zig.
