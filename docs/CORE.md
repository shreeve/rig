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
| **view** | the value handed over | it travels with the receiver: copied, returned, stored | a value of type `?T`, `!T`, `[]T`, or `![]T` (the read view of text is `?String`) |
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
sub main()
  v: List[Int] = List()
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
| **plain** | `Int`, `Bool`, `Static`, enums, `Simd[T, n]`, objects whose parts are all plain | copies | built |
| **owning** | `List[T]`, `^T`, `String`, `error`, objects holding an owner | moves; one owner; dropped once | built |
| **handle** | `*T` (counted), `~T` (weak), owned closures (`*fun`) | moves; `+h` adds a count | built |
| **view** | `?T`, `!T`, `[]T`, `![]T` | a read view copies; a write view reads the value it sees where that copies (sentence 1), and otherwise moves with `<w` | built |

**An object is a value; `^` puts it on the heap and `*` shares it.** An object
lives where it is declared, inside whatever holds it, and has no
identity of its own: `b = a` copies a plain object and moves an owning
one. The object itself goes on the heap only behind `^`, with one owner,
and is shared only behind `*`, where `+s` adds a count. *(built)*

```rig
obj Point
  x: Int
  y: Int

sub main()
  a = Point(x: 1, y: 2)
  b = a                    # a copy
  b.x = 5
  h = ^Point(x: 3, y: 4)   # on the heap, one owner
  s = *Point(x: 6, y: 7)   # shared
  t = +s
  print(a.x, b.x, h.x, s.x, t.x)
```

```output
1 5 3 6 6
```

**A `^T` is held like a handle and behaves like an owner:** one owner,
moved by `<b`, with `+b` copying its value into a new box. *(built)*

**An object's or enum's kind follows from its parts:** it is owning if
any part is owning or a handle; otherwise a view if any part is a view;
otherwise plain. No part is a write view (§5). *(built)*

```rig
obj Point
  x: Int
  y: Int

sub main()
  a = Point(x: 1, y: 2)
  b = a
  b.x = 5
  print(a.x, b.x)
```

```output
1 5
```

**A vector is plain data, one value like an `Int`.** A `Simd[T, n]`
holds `n` lanes of a number or `Bool`, so it owns nothing and views
nothing: a bare use copies it, it carries no loan, and nothing moves,
clones, or drops it but the rules of whatever holds it. Its lanes are
parts of its value, not places, as an Int's bits are: `v[i]` reads a
lane, and no lane is assigned, lent, or taken (`v.with(i, x)` makes
the changed copy). `v` itself is a place like any other binding,
field, or element, lent with `?v` and `!v`. Reading a vector out of
bytes copies them, so the vector carries no loan on what it was read
from. *(built)*

```rig
sub bump(v: !Simd[U8, 4])
  v = v + 1

sub main()
  s = String("abcd")
  v = (?s).read[Simd[U8, 4]](0)
  !s.add("e")
  bump(!v)
  w = v.with(0, 0)
  print(v, w, s)
```

```output
[98, 99, 100, 101] [0, 99, 100, 101] abcde
```

```rig reject
sub main()
  v = Simd[U8, 4].splat(1)
  v[0] = 2
```

```error
a lane of `v` is a value, not a place, so it is not assigned: write `v = v.with(0, x)`
```

**Three kinds the parts can't show:**

- **A type that must not be copied but owns nothing**, such as a random
  generator whose copy would repeat its numbers, says so on the type:
  `obj Random unique`. It moves like an owner. *(built)*
- **A type that holds a `Cell`**, or a bare `Cell[T]`, lives only
  behind `*`: see sentence 9. *(built)*
- **`error`**, which holds an error of any set, is owning whatever the
  program's sets hold, so whether it copies never depends on code
  elsewhere: see "A failure moves its error" (§2). *(built)*

```rig reject
sub main()
  c = Cell(1)
  print(c.get())
```

```error
`Cell(1)` makes a `Cell[Int]`, which holds a Cell, so it lives only behind a shared handle: write `*Cell(1)`
```

## 2. The core, in ten sentences

**1. A bare name or place only reads.** It copies plain data and read
views, and reads owners and handles in place; a write view of a value
that copies (§1: plain data, or a read view) reads the value it sees,
so `x = w` with `w: !Int` copies the Int, and with `w: !Point` the
Point. It never clones, writes, or drops, and it moves only where the
value leaves for good: `return x`, alone or as a part of `return x, y`,
`break x`, or `x` as the last value of the function or block that
declares `x`. *(built:* copies, `return x`, a function's last value, a
block's last value when the block declares the name, `break x` of a
name the loop declares, and reading in place: an argument where a view
is expected (`size(v)` for a `?List[Int]` parameter), and a header's
subject (a `for` over a `List`, `if o as x`, a `match` on a `^T`). Write
`<x` when `x` stays in scope after the move: a name declared outside
the block or loop always takes `<x`.*)*

```rig
fun make() -> List[Int]
  v: List[Int] = List()
  !v.push(1)
  v

sub main()
  v = make()
  print(v.len)
```

```output
1
```

```rig
sub main()
  v: List[Int] = List()
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
sub bump(w: !Int, g: !Int)
  x = w
  w = g
  x += 10
  print(x, w, g)

sub main()
  n = 1
  m = 2
  bump(!n, !m)
  print(n, m)
```

```output
11 2 2
2 2
```

```rig reject
sub show(v: !List[Int])
  y = v
  print(y.len)

sub main()
  xs: List[Int] = List()
  show(!xs)
```

```error
bare use of write view `v` in binding would copy a write view, which is unique
```

```rig
fun first() -> List[Int]
  e: List[Int] = List()
  r = while true
    v: List[Int] = List()
    !v.push(1)
    break v
  else
    <e
  r

sub main()
  print(first().len)
```

```output
1
```

**2. `<x` moves, `+x` makes a new owner.** A statement `<x` moves `x`
nowhere, so it drops now. `+x` is a copy, a count bump, or a deep
copy, as the type says; a `unique` type or one with a `drop` body
has none; `+s` of a `?String` is a new `String`. *(built;*
a deep copy of a type declared in another module, or of one holding a
`Signal`, is *planned*.*)*

```rig
obj File
  name: ?String

  drop(!self)
    print("closing", self.name)

sub main()
  a = File(name: "a.txt")
  b = <a
  <b
  print("end")
```

```output
closing a.txt
end
```

```rig
sub main()
  v: List[Int] = List()
  !v.push(1)
  w = +v
  !w.push(2)
  print(v.len, w.len)
```

```output
1 2
```

```rig file=bag.rig
pub obj Bag
  pub items: List[Int]
```

```rig pending
use bag

sub main()
  a = bag.Bag(items: List())
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
view the context expects** ([§4](#4-one-lend-table)). `?` promises that
nothing changes. A read lend may
go unwritten where its view lasts only for the use: an argument, a
method's receiver, or a header's subject (sentence 1), and `print` and
`String` read their arguments the same way. A lend is written wherever
its view may outlast its statement: when it is kept in a binding or a
field, kept by the call it is lent to (`!p.watch(?t)`), or kept by a
call's result that is stored in a binding, a field, or a return, or
handed to a call that keeps it (`r = head(?v)`, `xs = ?b.all()`,
`!xs.push(head(?v))`). So is every write lend. A result used within its
statement (`print(head(v).len)`) leaves it unwritten. `!` lends any
value to write, named or temporary: `!mk().pop()` lends the value
`mk()` makes, which lives until its statement ends ([§3](#3-temporaries)),
so every change is still marked by `!`. *(built* for the rows of §4
marked built.*)* A written `!` must lend to write: `!x` is rejected
wherever `x` is only read: an operand, an index, `print`, a copy, or an
argument the callee only reads. Write `x` to copy it, `?x` to lend it to
read, or `!T` in the type to keep the write view. *(built)*

```rig
sub grow(v: !List[Int])
  !v.push(7)

fun first(v: ?List[Int]) -> Int
  v[0]

sub main()
  v: List[Int] = List()
  grow(!v)
  print(first(?v))
```

```output
7
```

```rig
obj Counter
  n: Int

  fun next(!self) -> Int
    self.n += 1
    self.n

fun start() -> Counter
  Counter(n: 41)

sub main()
  print((!start()).next())
```

```output
42
```

**5. A place has any number of read loans, or one write loan, never
both.** A loan on a place covers every place inside it, so two
places conflict when one holds the other: `p` and `p.a`, `p.a` and
`p.a.b`, but not `p.a` and `p.b`. This holds for every type, numbers
included. *(built)*

```rig reject
sub add(a: !Int, b: ?Int)
  a += b

sub main()
  n = 1
  add(!n, ?n)
```

```error
cannot lend `n` to read while a write loan is live
```

**6. A loan lasts until the last use of every view that carries it,**
wherever that view went: a field, an array, an optional, a closure, a
result. Dropping a value uses the views it holds only when its
drop runs a `drop` body, which could read them, so a `List[[]Int]`'s
loans end at its last use, not where it is dropped. *(built)*

```rig reject
sub main()
  v: List[Int] = List()
  r = ?v
  !v.push(2)
  print(r.len)
```

```error
cannot lend `v` to write while a read loan is live
```

```rig
sub main()
  a = [1, 2, 3]
  v: List[[]Int] = List()
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
obj Guard
  items: []Int

  drop(!self)
    print(self.items.len)

sub main()
  a = [1, 2, 3]
  g = Guard(items: ?a[..])
  print(g.items[0])
  a[0] = 9
```

```error
cannot assign to `a[0]` while `a` is lent
```

**7. A call passes on only the loans its signature shows.** A function
returns a view only of what it was lent, or of something that lives for
the whole program: a `Static` (a text literal is one), a module
constant, or `os.args()`. Its result carries the loans of the arguments
whose types could hold what it views, or, when the result says
`from a`, of `a` alone. A result that holds no write view carries its
loans as read loans, even one of an argument lent to write, whose write
lend then ends as the call returns unless the call keeps it: after
`head(!v)`, in its own statement or through `r = head(!v)`, `v` may be
read, but not written, while the result lives. A view reached through a
read view that a value holds carries that view's loans, not a loan on
the holder. What a call stores in what a write view lent to it sees
carries, in the same way, the loans of the arguments whose types could
hold it; for a lent parameter (a view, an optional of one, or the
receiver), a declared function narrows this to the parameters its
signature names in `keeps` (`sub watch(!self, s: ?String) keeps s`). A
kept loan lasts while the holder is used, though the holder's own write
lend ends as the call returns; a lend the call does not keep lasts no
longer than the call and its result. A function called as a value is
known only by its type, which names no `from` or `keeps`, so nothing
narrows its result or its stores. The compiler checks each body against
its signature, `from` and `keeps` included: a body that stores a lent
parameter, on any path, directly or through a call that keeps it, names
it in `keeps`. *(built)*

```rig reject
fun pick(a: ?List[Int]) -> ?List[Int]
  v: List[Int] = List()
  ?v
```

```error
which this function was not lent
```

A `Cursor` holds only a view of the items, so an item `next` hands out
views the List, not the cursor, which moves on:

```rig
obj Item
  n: Int

obj Cursor
  items: ?List[Item]
  i: Int

  fun next(!self) -> ?Item
    self.i += 1
    ?self.items[self.i - 1]

sub main()
  v: List[Item] = List()
  !v.push(Item(n: 1))
  !v.push(Item(n: 2))
  c = Cursor(items: ?v, i: 0)
  a = (!c).next()
  b = (!c).next()
  print(a.n, b.n)
```

```output
1 2
```

```rig
fun head(v: !List[Int]) -> []Int
  !v.push(v.len)
  ?v[..1]

sub main()
  v: List[Int] = List()
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
fun head(v: !List[Int]) -> []Int
  !v.push(v.len)
  ?v[..1]

sub main()
  v: List[Int] = List()
  r = head(!v)
  !v.push(5)
  print(r)
```

```error
cannot lend `v` to write while a read loan is live
```

```rig
fun first(a: ?List[Int], b: ?List[Int]) -> ?List[Int] from a
  a

sub main()
  x: List[Int] = List()
  y: List[Int] = List()
  r = first(?x, ?y)
  !y.push(1)
  print(r.len)
```

```output
0
```

`watch` keeps the text it is lent, so `text` stays lent while `p` is
used, yet `p` may be written again at once; `note` keeps nothing, so
`m` may be dropped as soon as it returns:

```rig
obj Parser
  src: ?String
  errors: Int

  sub watch(!self, s: ?String) keeps s
    self.src = s

  sub note(!self, msg: ?String)
    if msg.len > self.src.len
      self.errors += 1

sub main()
  p = Parser(src: "", errors: 0)
  text = String("let x")
  !p.watch(?text)
  m = String("a long message")
  !p.note(?m)
  <m
  print(p.src, p.errors)
```

```output
let x 1
```

```rig reject
obj Parser
  src: ?String

  sub watch(!self, s: ?String) keeps s
    self.src = s

sub main()
  p = Parser(src: "")
  text = String("let x")
  !p.watch(?text)
  !text.add(";")
  print(p.src)
```

```error
cannot lend `text` to write while a read loan is live
```

A body that stores a lent parameter without naming it is rejected at
the store:

```rig reject
obj Binder
  src: ?String

  sub set_src(!self, s: ?String)
    self.src = s

sub main()
  pass
```

```error
`set_src` stores a view of `s` in `self`, which its caller reaches, but its signature does not keep `s`; say so: `keeps s`
```

**Several results.** A function may give several results, `-> (A, B)`,
with `return a, b`; each is a result as described above. The results
never form a value (§5), so the call stands only where each result is
bound at once (`a, b = f()`, `if f() as a, b`, `while f() as a, b`),
where they are returned whole (`return f()`), or where all are
discarded, as one result is. Until its target takes it, each result is
a temporary of the call's statement (§3). The targets take theirs left
to right, by the rule `x = e` has, so a name cannot be bound while a
result not yet taken views it. A result that `_` discards drops at the
statement's end, the last made first, and keeps what it views lent
until then only when its drop runs a `drop` body (sentence 6). Each
result carries the loans its own type could hold, so a `Bool` beside a
view carries none, and a result may be a write view, as `-> !T` is,
beside results whose types could view nothing it views (sentence 5).
When no result holds a write view, every write lend of the call ends as
it returns, as for one result. *(built; two write-view results are
planned)*

```rig
obj Counter
  n: Int
  m: Int

  fun bump(!self, k: Int) -> (!Int, Bool)
    self.n += k
    return !self.m, self.n > 3

sub main()
  c = Counter(n: 0, m: 0)
  w, big = (!c).bump(5)
  w += 10
  print(big, c.m)
```

```output
true 10
```

**8. `*<x` moves `x` into a counted handle, and `*S(...)` makes a new
value there; `^<x` and `^S(...)` put a value alone in a box.** A box has
one owner and no count: it moves, and `+b` copies its value into a new
box. A value is held one way on the heap, as `^T`, `*T`, or `~T`, so a
holding sigil over a held value (`^*T`, `**T`, `*~T`) is rejected. Handles only
read (a `Cell` inside one changes by a marked call: sentence 9). `~h`
holds the counted value weakly, and `*w` is the way back: a new handle
while the value lives, `none` after. *(built)*

```rig
obj User
  name: ?String

sub main()
  u = User(name: "ada")
  a = *<u
  w = ~a
  if *w as h
    print(h.name)
  <a
  if *w as h
    print("still here")
  else
    print("gone")
```

```output
ada
gone
```

**9. Shared storage.** You change what you were lent with `!`, or what
you share with `*`. A name's own value changes by assigning it. What
you share is a `Cell`, and it changes only by a marked call: `!c.set(5)`.
A value that holds a `Cell` lives only behind `*` (`*Cell(0)`, or a
field of a value made with `*`); it is never a local, parameter,
element, or type argument by value. `Cell`, `Signal`, and owned
closures are no-loan homes: they hold no view that carries a loan, so
they keep text only as a `Static`; a `*T` carries the loans of what it
holds. *(built)*

```rig
sub main()
  c = *Cell(0)
  d = +c
  !d.set(5)
  print(c.get())
```

```output
5
```

A `Cell` keeps text as a `Static`, so a literal goes in and a `String`'s
bytes do not:

```rig
sub main()
  c = *Cell("one")
  !c.set("two")
  print(c.get())
```

```output
two
```

```rig reject
sub main()
  t = String("abc")
  c = *Cell("one")
  !c.set(?t)
```

```error
expected `Static`, got `?String`
```

```rig reject
obj Edit
  w: !Int

sub main()
  print(1)
```

```error
a write view is never stored inside a value, and `!Int` cannot stand here
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

sub main()
  print(half(4) catch 0)
```

```error
return Bad.oops
```

**A failure moves its error.** An error set's member may carry fields,
as an enum's variant does, but never a view, and every field clones.
*(planned)* An error is plain or owning by the enum rule (§1), and
`error`, which holds an error of any set, is owning. *(built)*
`return E.name(...)` moves the error out of the function, `e!` passes
the same error to the caller, and `catch |err|` makes it the handler's
own binding, which drops when the handler ends unless the handler moves
it on (`return err`, `<err`). *(built)* A `catch` that names no error
drops it before its handler runs. *(planned)* Reading, matching,
printing, storing, and cloning an error follow its type, as for any
value. *(built)*

```rig reject
error E
  bad

fun f() -> Int!
  return E.bad

sub main()
  n = f() catch |err|
    keep = <err
    print(err, keep)
    0
  print(n)
```

```error
use of `err` after move
```

```rig pending
error ParseError
  empty
  bad(pos: Int, msg: String)

fun parse(s: ?String) -> Int!ParseError
  return ParseError.empty if s.len == 0
  return ParseError.bad(pos: 0, msg: String("not a digit: ", s)) if s[0] < 0x30 or s[0] > 0x39
  s.len

fun twice(s: ?String) -> Int!ParseError
  parse(s)! * 2

sub main()
  print(twice("42") catch -1, twice("") catch -1)
  n = twice("x1") catch |err|
    print(err)
    match err
      .empty => -1
      .bad(pos, msg)
        print("at", pos, msg)
        -2
  print(n)
```

```output
4 -1
ParseError.bad(pos: 0, msg: "not a digit: x1")
at 0 not a digit: x1
-2
```

Only code inside `raw` may break these rules. *(built)*

## 3. Temporaries

*(built.* A lend of a branching value that may be a name's,
`?(a if c else b)`, is *planned*; today each branch is lent, `?a if c
else ?b`.*)*

**A branch is a value, never a place.** Wherever a branching value, or
a path from one, is used where it stands as a view (a sigil, a `for`'s
`?` or `!`, a header's subject, an argument where a view goes, or a
write view passed or bound), it is lent there, and a leaf a name holds
is rejected: each branch is lent instead, `?a if c else ?b` or
`!a if c else !b`. A branch of read views copies the view it takes, and
is only read. *(built)*

```rig
sub inc(w: !Int)
  w += 1

sub main()
  a = 1
  b = 2
  c = a < b
  inc(!a if c else !b)
  print(a, b)
```

```output
2 2
```

```rig pending
sub main()
  a = String("a")
  b = String("b")
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
- **Reading:** a `print` or `String(...)` argument, an `==` operand, `?e`,
  `+e`, a `?self` receiver, a field or element read, or the value a
  call calls.

Reading never moves a name, whatever form reads it: `print(a if c else
b)` moves nothing.

**What counts as a temporary.** A value made where it is only read has
no name: a call's result, a constructor, `+x`, or a block or `match`
value. Its statement is its scope, so it is a *temporary*, dropped when
the statement ends, the last made first, also when the statement fails
or leaves early. A temporary may be lent to read or to write (sentence
4), and a view of it may be used only within its statement. A value
made to be called (`(+h.f)(x)`) is a temporary too *(planned)*.

**Headers are their own statements:** an `if` or `while` condition, a
guard, and the subject of a `match` or `for`. A header's temporaries
end with the header; what the header binds lives through the body. A
value made there that `if … as`, `while … as`, `match`, or `for` binds
is taken, as `<e` would take it: a call's result, or a branching value
whose every branch is made there (`mk() if c else <a`). So
`if starts_with(?String(a, b), "x")` works, but
`if cut(?String(a, b), "=") as kv` must bind the `String` first, because
`kv` outlives the header. *(built* for `if … as`, `while … as`, `match`,
and a `for` over plain elements; *planned* for a `for` over a made List
of owners, which is bound to a name first today.*)*

```rig
obj User
  name: ?String
  tags: List[Int]

fun load() -> User
  User(name: "ada", tags: List())

sub main()
  print(load().name)
```

```output
ada
```

```rig
use std.text

sub main()
  a = "x"
  b = "yz"
  if text.starts_with(?String(a, b), "xy")
    print("starts")
```

```output
starts
```

```rig reject
use std.text

sub main()
  if text.cut(?String("k", "=v"), "=") as kv
    print(kv.after)
```

```error
a view of the temporary `String("k", "=v")` outlives its statement
```

```rig pending
fun names() -> List[String]
  v: List[String] = List()
  !v.push(String("ada"))
  v

sub main()
  for x in names()
    print(x)
```

```output
ada
```

## 4. One lend table

`?x` and `!x` lend the view the context expects; where the context
takes none of the views in `!x`'s column, `!x` is rejected (sentence 4):

| Owner `x` | `?x` lends | `!x` lends | Status |
|---|---|---|---|
| any `T` | `?T` | `!T` | built |
| `[N]T`, `List[T]` | `[]T` | `![]T` | built |
| a place `p.f` or `v[i]` | the views of the field or element | its write views | built |
| a held `!T` | `?T` | `!T` (lent on) | built |
| `![]T` | `[]T` | `![]T` (lent on) | built |
| `String` | `?String` (also `(?String)?`) | `!String` | built |
| `^T` | the views of `T` | the write views of `T` | built |
| `*T` | the read views of `T` | nothing of the value (`!h` lends the handle itself) | built |
| `X?` | `View?` for each view of `X` | `!(X?)`, by the first row | built |
| a function or closure | `?fun` | | built |

A view of a value that copies (§1) is copied out where that value is
expected, a plain object, array, or optional as a number is, and the
copy carries no loan but those of the views it holds, as with a call's
`?Int` result. `a ?? b` is `v` when `a` holds a view `v`, and `b`
otherwise; `a catch b` is the same over a failure (§8). So when `b` is
a `T`, the type the view sees, `v` is copied out to match it, as above:
`m.get(k) ?? 0` is an `Int`, and `m` stays free to change. A fallback
that is a view or a jump leaves the view, and so does `none` where an
optional view is expected. When the viewed type does not copy, a `T`
fallback is rejected: lend the fallback and clone the result, as in
`+(m.get(k) ?? ?String("none"))`. *(built)*

```rig
use std.hash

sub main()
  m = hash.Map[String, Int]()
  for k in ["a", "b", "a"]
    !m.put(String(k), (m.get(k) ?? 0) + 1)
  print(m.get("a") ?? 0, m.get("b") ?? 0)
```

```output
2 1
```

```rig reject
use std.hash

sub main()
  m = hash.Map[String, String]()
  s = m.get("a") ?? String("none")
  print(s)
```

```error
only a value that copies is copied out of a view, and a `String` owns a resource: lend the fallback, so the result is the view, and clone that for a `String` of its own: `+(m.get("a") ?? ?String("none"))`
```

A slice `x[a..b]` is the same lend, of
part of `x`, and goes unwritten as an argument where `x` does:
`total(w[1..3])` is `total(?w[1..3])`. *(built)* So `sort.sort(!v)` works on a `List` as it does on an array,
and one `fun area(s: ?Shape)` serves a `Shape`, a `^Shape`, and a
`*Shape`. A `String` lends a `?String`, its bytes, and that is its only
read view: `?t`, a loop or pattern binding of a `String`, and a generic
`?T` at `T = String` are all `?String` values, and a read view of a read
view is that read view. A `?String` is a view, so nothing lends a
`?String` place to write: assign to it to point it at other text, or hold
a `String`. A `Static` is read as a `?String` where the text is only read;
it never converts where the text can be written, and nothing converts a
`?String` to a `Static`. *(built)*

```rig
use std.sort

sub main()
  a = [3, 1, 2]
  sort.sort(!a)
  print(a)
```

```output
[1, 2, 3]
```

```rig
obj P
  x: Int
  y: Int

fun copy(p: ?P) -> P
  p

sub main()
  a = P(x: 1, y: 2)
  b = copy(?a)
  print(b.x)
```

```output
1
```

A `String` lends a `?String`, which views its bytes, so the `String` may not
change while the view is used:

```rig
use std.text

fun or_none(s: (?String)?) -> ?String
  s ?? "none"

sub main()
  t = String("  hi  ")
  print(text.trim(?t), or_none(?t).len)
  !t.add("!")
  print(t)
```

```output
hi 6
  hi  !
```

```rig reject
sub main()
  t = String("abc")
  s = ?t[..2]
  !t.add("d")
  print(s)
```

```error
cannot lend `t` to write while a read loan is live
```

```rig
use std.sort

sub main()
  v: List[Int] = List()
  !v.push(3)
  !v.push(1)
  sort.sort(!v)
  print(v[0], v[1])
```

```output
1 3
```

## 5. Containers and fields hold values

`List`, arrays, and fields hold any value but a write view; only a
object field may hold a `Cell`. Each field and element is a place:

- `p.f` and `v[i]` read it (sentence 1);
- `?p.f`, `!p.f`, `?v[i]`, and `!v[i]` lend it;
- `<p.f` and `<v[i]` take an optional one, leaving `none`;
- assigning to it drops the old value.

**A field is a place of its own.** A path is a name and the fields
after it, through what a write view the name holds sees, and through
a box. It stops at an element, a handle, or an optional's value, and
the loan is on the path so far: `?v[i]` and `!v[j]` are both loans on
`v`, and `?h.f` with `h: *T` is a loan on `h`. A use touches the path
it names: `?p.a`, `!p.a`, `<p.a`, `p.a = x`, `(!p.a).m()`, and
`swap(!p.a, !p.b)` touch `p.a` (and `p.b`); `p`, `<p`, `p = x`,
`(!p).m()`, and `!p.m()` touch all of `p`. A value never holds a view
of itself: storing in a part of `p` a value that carries a loan on a
part of `p` is rejected. *(built)*

```rig
obj Arena
  names: List[String]

  sub add(!self, t: ?String)
    !self.names.push(String(t))

obj Parser
  a: Arena
  t: String

  sub step(!self)
    (!self.a).add(self.t)

sub main()
  p = Parser(a: Arena(names: List()), t: String("id"))
  !p.step()
  (!p.a).add(p.t)
  print(p.a.names.len)
```

```output
2
```

```rig reject
obj P
  name: String
  n: Int

  sub bump(!self)
    self.n += 1

sub main()
  p = P(name: String("a"), n: 0)
  r = ?p.name
  !p.bump()
  print(r)
```

```error
cannot lend `p` to write while a read loan on `p.name` is live
```

```rig reject
obj P
  s: String
  v: ?String

sub main()
  p = P(s: String("abc"), v: "")
  p.v = ?p.s
  print(p.v)
```

```error
cannot store in `p.v` a view of `p.s`: a value never holds a view of itself
```

**Write views are not stored.** A `!T` (also `![]T`, `(!T)?`, `(!T)!`)
is a parameter, a receiver, a result, or a local. It is never a field,
an element, a type argument, or what a `?`, an optional, or a handle
holds. `^T`, optionals, and a generic `T` hold any value but a write view,
as a `List` does. A holder of a read view carries its loan: with `^?v`,
`v` stays lent while the box, or a view it gave out, is used.
A function type's parameters and result are not parts of a value of
that type: `List[*sub(!Checker)]` holds no write view. *(built)*

`<` always leaves its source done: a name is ended, an optional place
is emptied to `none`, and any other place is rejected, a part of a
value made there too, so a field or element that copies is copied with
no `<` (`m = p.n`). `<`'s operand is a place or a made value:
`<(a if c else b)` is written `<a if c else <b`. *(built)*

```rig
obj Slot
  item: ^Int?

sub main()
  s = Slot(item: ^7)
  if <s.item as b
    print(<b.unbox())
  print(s.item)
```

```output
7
none
```

**A list of owners works as a list of plain data does.** `List[String]`, `List[List[Int]]`, and a `List` of objects that each own a string take their elements by move and drop each one once. `swap` and `sort_by` only move elements, so they work for any element; `sort` also needs `<`. *(built)*

**Only a value that copies is duplicated without `+`.** An operation that writes copies of a value it leaves in place, as `copy`, `fill`, `[n of x]`, `List.filled`, and `resize` do, needs an element type that copies (§1). A read view copies, and each copy carries its loan. Anything else is rejected, since each copy would be a clone no `+x` wrote (sentences 1 and 2): write a loop that makes each element with `+x`. The element type decides, so `resize` needs one that copies even when it only shrinks; `!xs.keep(n)` shrinks any list. *(built)*

```rig reject
sub main()
  rows = List.filled(3, String("a"))
  print(rows)
```

```error
`List.filled` copies its value into every element, and a `String` owns a resource, so it cannot be copied: write a loop that makes each element with `+x` (`for 0..n` with `!xs.push(+x)`)
```

```rig
sub main()
  s = String("ab")
  views = List.filled(2, ?s)
  print(views)
```

```output
["ab", "ab"]
```

```rig
sub main()
  rows: List[List[Int]] = List()
  r: List[Int] = List()
  !r.push(5)
  !rows.push(<r)
  print(rows.len, rows[0].len)
```

```output
1 1
```

```rig
sub main()
  n = 1
  a = [3 of ?n]
  print(a[2])
```

```output
1
```

**A container written in Rig follows its signatures.** `hash.Map[K,
V]` and `hash.Set[K]` are std code with no rule of their own: `!m.put(k,
v)` takes `k` and `v` as any owning parameter does; `m.get(k)` returns
a `(?V)?` view `from self`, which carries the loan on `m` and not on
`k` (sentence 7); `(!m).edit(k)` returns a `(!V)?` that carries a write
loan on `m`; and
`(!m).take(k)` hands the value back owned and drops the key. *(built)*

## 6. Bindings and assignment

**Evaluation order.** `x = e` evaluates `e` first, then the indexes in
`x` from left to right, then finds `x`'s place, then stores. This
matches Rust for `=`. *(built)*

```rig
fun next(i: !Int) -> Int
  i += 1
  i

sub main()
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
sub main()
  v: List[Int] = List()
  !v.push(v.len)
  !v.push(v.len)
  print(v)
```

```output
[0, 1]
```

```rig reject
fun grow(v: !List[Int]) -> Int
  !v.push(1)
  v.len

sub main()
  v: List[Int] = List()
  print(v, grow(!v))
```

```error
while an earlier argument's read of it is in use
```

**Bindings.** A local binding may be reassigned. Parameters and fixed
bindings (`x =! e`) may not. *(built)*

```rig
sub main()
  limit =! 3
  print(limit)
```

```output
3
```

**View places.** Assigning a view to a place that holds one re-points
it, and assigning a value writes through. A field that holds a read
view re-points the same way. A `!T` a call returns, or that the call's
`!` or `?` gives, is a place too: assigning to it writes through, as it
would through a binding of it. The call finds the place, so it runs
after the value, as an index does. `new` only shadows, and accepts
every binding form.
*(built)*

```rig
sub main()
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

```rig
fun slot(v: !List[Int], i: Int) -> !Int from v
  !v.push(7)
  !v[i]

sub main()
  v: List[Int] = List()
  !v.push(1)
  slot(!v, 0) += v.len
  print(v)
```

```output
[2, 7]
```

## 7. Closures and defer

**Closures.** A closure captures each name with a sigil: `?x` lends
`x` to read for the closure's life, `!x` lends it to write, `<x` moves
it in, and `+x` captures what `+x` gives, read through a view: a copy
of a value that copies, a new count of a handle, or a deep copy of an
owner. Captures are fixed: the body reads them, and writes only
through a captured write view. A closure's life ends at its last use,
so a closure literal lent to a call lends its captures for that call.
A stack closure may be lent (`?fun`) but not stored. *(built)*

```rig
sub main()
  total = 0
  add = |!total, k: Int| total += k
  add(2)
  add(3)
  print(total)
```

```output
5
```

```rig
sub main()
  v: List[Int] = List()
  !v.push(1)
  f = |+v| v.len
  print(f(), v.len)
```

```output
1 1
```

**An owned closure is a function with its own environment.** `*|...|`
moves or clones its captures into a value behind a counted handle,
`*fun(A) -> R` or `*sub(A)`, which is stored, returned, cloned, and
dropped like any `*T`. The environment holds no loan (sentence 9), so
an owned closure captures owners, handles, and plain data, never a
view. Its parameters and result are any a function's may be, and
follow sentences 4 and 7 as a function's do: of a view it is given,
read or write, it keeps what its type could hold (sentence 7); what it
is given to own, it drops, returns,
or stores through a write parameter; its result views only what the
call lent it. So a write view reaches a stored closure only as an
argument, for one call: mutation is never data. Calling a closure
reads what holds it until the call returns (§6), so a closure held in
`x` is not called with `!x`: clone its handle first, `f = +x.f`, then
`f(!x)`. *(built)*

```rig
obj Checker
  n: Int

sub main()
  c = Checker(n: 1)
  step = 10
  bump: *fun(!Checker, Int) -> Int = *|+step, k, t|
    k.n += step
    k.n + t
  a = bump(!c, 1)
  b = bump(!c, 2)
  print(a, b, c.n)
```

```output
12 23 21
```

```rig reject
obj Checker
  n: Int
  hook: *sub(!Checker)

  sub run(!self)
    self.hook(!self)

sub main()
  bump: *sub(!Checker) = *|k| k.n += 1
  c = Checker(n: 0, hook: <bump)
  (!c).run()
```

```error
cannot lend `self` to write while the callee's read of `self.hook` is in use
```

A value made to be called is a temporary of its statement (§3):

```rig pending
obj Hooks
  on: *fun(Int) -> Int

sub main()
  h = Hooks(on: *|x| x + 1)
  print((+h.on)(1))
```

```output
2
```

**Defer.** `defer` and `errdefer` run where their scope ends. They may
read and write what is live there; they never extend a loan past it.
*(built)*

```rig
sub main()
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

- **`-x`** always negates. A statement `-x` does nothing and is
  rejected; a drop is written `<x` (sentence 2). *(built)*
- **The receiver-sigil rule:** `!v.push(x)` applies `!` to `v`, and
  `!mk().pop()` applies it to `mk()`. *(built)*
- **`x =! e`:** a local binding that never changes. *(built)*
- **The sigil leads the whole path.** Write `!p.x` to lend a field,
  `p.x` to read it, and `p.x = 4` to assign it. `(!p).x`, `(?arr)[0]`
  and `(!v)[0..2]` are rejected. Parentheses around a lend are only for
  calling on it: `(!s).insert(k)`. A branch of lends,
  `(!a if c else !b).x`, and a slice lend, `(?t[..])[0]`, are values,
  not lends of a place. *(built)*
- **A write call whose value is used** is written `(!s).insert(k)`,
  everywhere: a condition, an `as` header, an operand, a binding, an
  argument, a result. The short form `!s.insert(k)` stands only where
  the value is discarded. *(built)*
- **Labels**, the `catch` forms, `pass`, and `??`.
- **Habits from other languages that keep Rig's meaning,** documented
  rather than changed: integer `/` and `%` truncate as in C; `u?.n`
  propagates `none` from the function; `break` inside a `match` leaves
  the loop; `e catch a if c else b` groups as `e catch (a if c else b)`.

```rig reject
fun count() -> Int
  3

sub main()
  -count()
```

```error
`-count()` negates a value and discards it
```

```rig reject
obj Seen
  items: List[Int]

  fun insert(!self, k: Int) -> Bool
    for x in ?self.items
      return false if x == k
    !self.items.push(k)
    true

sub main()
  s = Seen(items: List())
  added = !s.insert(1)
  print(added)
```

```error
write `(!s).insert(1)`: a write call whose value is used puts its `!` in parentheses
```

## 9. Inside the compiler

Not visible to programs: the compiler decides each of these once, and
no pass decides them again by looking at syntax.

- **Per type, one fact each:** copies; unique; needs cleanup; may hold
  a loan; cloneable; how a read view is represented (a copy, or a
  pointer). *(built)*
- **Per expression, one classification** of what it hands over: a
  place, a made value, a lend, branches, or a jump *(built)*; whether it
  is a view, and whether the value lives for the whole program
  *(planned)*.
- **Per path, one exit primitive,** which runs defers, reports any loan
  it would drop, and rewinds when the path goes on. *(built)*
- **Per check, one fact:** whether an index, byte read, or integer
  `+` is known to pass. It is, when a guard or check made the same
  test on every path to it and nothing it tested was written in
  between. A binding changes only where an assignment or a `!` says so
  (sentences 4 and 9), so the compiler sees every write. *(built)*

## 10. How a feature earns its way in

- It fits one paragraph on this page, with no exception list.
- Its rules follow the value's type, never where the value came from.
- It is written as a desugaring into forms this page already covers.
- A second round of soundness fixes stops it for redesign.
- It passes the regression corpus, and runs clean under the sanitizer.
- It answers a line that failed in a real program, not parity with Rust
  or Zig.
