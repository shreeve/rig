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
cannot write-borrow `v` while a read borrow is live
```

The lend is on line 4 (`?v[..]`). The loan stays with `v` while the
views `a` and `b` are still used below, so `!v.push(2)` is rejected.
*Borrow*, the word Rust uses, names the same event from the receiver's
side; Rig names everything from the side the sigil is on, and SPEC's
*borrow* means a lend or the view it makes. *(Error messages still say
"borrow"; their wording moves to lend/loan with the SPEC rewrite.)*

---

## 1. Four kinds of value

| Kind | Examples | A plain use | Status |
|---|---|---|---|
| **plain** | `Int`, `Bool`, enums, structs whose parts are all plain | copies | built |
| **owning** | `Vec[T]`, `Box[T]`, `Text`, structs holding an owner | moves; one owner; dropped once | built |
| **handle** | `*T` (counted), `~T` (weak) | moves; `+h` adds a count | built |
| **view** | `?T`, `!T`, `[]T`, `![]T`, `String` | a read view copies; a write view moves | built |

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
  because a copy would fork state that should be shared. *(planned)*

```rig pending
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

**1. A bare name only reads.** It copies plain data and read views, and
reads owners and handles in place. It never clones, writes, or drops,
and it moves only where the value leaves for good: `return x`, `break
x`, or `x` as the last value of a function or block. *(built* for copies,
`return x`, and a function's last value; *planned:* a block's last value
and `break x`, which take `<x` today, and reading in place where `?` is
still required today, as for a `?T` argument, a `for` over a `Vec`,
`if o as x`, or a `match` on a `Box`.*)*

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

```rig pending
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

**2. `<x` moves, `+x` makes a new owner, `-x` drops now.** `+x` is a
copy, a count bump, or a deep copy, as the type says; a `unique` type,
or one with a `drop` body, has none. *(built* for plain data, handles,
closures, `Text`, and `unique` types; *planned* for `Vec`, `Box`, and
structs holding an owner.*)*

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

```rig pending
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

**3. Drop points.** An owner that is not moved is dropped where its
scope ends. *(built)* A value no name holds is dropped where its
statement ends ([§3](#3-temporaries)). *(built)*

**4. `?x` lends `x` to read, and `!x` lends it to write, as whichever
view the context expects** ([§4](#4-one-lend-table)). A read lend may go
unwritten (sentence 1); a write lend is always written. *(built* for
the rows of §4 marked built.*)*

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
cannot read-borrow `n` while a write borrow is live
```

**6. A loan lasts until the last use of every view that carries it,**
wherever that view went: a field, an array, an optional, a closure, a
result. *(built)*

```rig reject
sub main
  v: Vec[Int] = Vec()
  r = ?v
  !v.push(2)
  print(r.len)
```

```error
cannot write-borrow `v` while a read borrow is live
```

**7. A call passes on only the loans its signature shows.** A function
returns a view only of what it was lent, or of something that lives for
the whole program (literals, module constants, `os.args()`). Its result
carries the loans of the arguments whose types could hold what it views,
or, when the result says `from a`, of `a` alone. A view reached through
another view carries that view's loans, not a loan on its holder. The
compiler checks each body against its signature. *(built:* the result
carries the loans of everything it was lent; *planned:* the narrowing
to the arguments that could hold it, and `from`.*)*

```rig reject
fun pick(a: ?Vec[Int]) -> ?Vec[Int]
  v: Vec[Int] = Vec()
  ?v
```

```error
does not originate from a borrowed parameter
```

```rig pending
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
the operand of `return`. *(planned)*

```rig pending
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

**Taking and reading.** An expression either *takes* its value or only
*reads* it.

- **Taking:** a binding, an argument to a parameter that owns it,
  `return`, a stored field or element, or `<`.
- **Reading:** a `print` or `Text(...)` argument, an `==` operand, `?e`, a
  `?self` receiver, or a field or element read.

Reading never moves a name, whatever form reads it: `print(a if c else
b)` moves nothing.

**What counts as a temporary.** A value made where it is only read has
no name: a call's result, a constructor, `+x`, or a block or `match`
value. Its statement is its scope, so it is a *temporary*, dropped when
the statement ends, the last made first, also when the statement fails
or leaves early. A view of a temporary may be used only within its
statement.

**Headers are their own statements:** an `if` or `while` condition, a
guard, and the subject of a `match` or `for`. A header's temporaries
end with the header; what the header binds lives through the body. A
call's result that `if … as`, `while … as`, `match`, or `for` binds is
taken, as `<e` would take it. So `if starts_with(?Text(a, b), "x")`
works, but `if cut(?Text(a, b), "=") as kv` must bind the `Text` first,
because `kv` outlives the header.

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
a borrow of the temporary `Text("k", "=v")` outlives its statement
```

## 4. One lend table

`?x` and `!x` lend the view the context expects:

| Owner `x` | `?x` lends | `!x` lends | Status |
|---|---|---|---|
| any `T` | `?T` | `!T` | built |
| `[N]T`, `Vec[T]` | `[]T` | `![]T` | arrays built; `Vec` planned |
| a place `p.f` or `v[i]` | the views of the field or element | its write views | fields built; elements planned |
| a held `!T` | `?T` | `!T` (lent on) | built |
| `![]T` | `[]T` | `![]T` (lent on) | built |
| `Text` | `String` (also `String?`) | `!Text` | built |
| `Box[T]` | the views of `T` | the write views of `T` | one level built; composing planned |
| `*T` | the read views of `T` | nothing of the value (`!h` lends the handle itself) | planned |
| `X?` | `View?` for each view of `X` | `!(X?)`, by the first row | planned |
| a function or closure | `?fun` | | built |

A read view of plain data copies, and carries no loan once copied out,
as with a call's `?Int` result. A slice `x[a..b]` is the same lend, of
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
cannot write-borrow `t` while a read borrow is live
```

```rig pending
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
`<a if c else <b`. `swap`, and so sorting, work for any element. `copy`,
`fill`, and `[n of x]` duplicate values, so they need copyable elements.
So `Vec[Text]`, `Vec[Vec[Int]]`, and a list of records that each own a
string just work.

*(built* for fields; *planned* for containers, which today hold plain
data, handles, and boxes.*)*

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

```rig pending
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
bindings may not. *(built;* the word `const` is *planned*: today a
binding that never changes is written `x =! 5`.*)*

```rig pending
sub main
  const limit = 3
  print(limit)
```

```output
3
```

**Borrow places.** Assigning a view to a place that holds one re-points
it, and assigning a value writes through. This holds for locals and
fields alike. `new` only shadows, and accepts every binding form.
*(planned)*

```rig pending
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

**Closures.** A closure captures each name with a sigil: `?x` borrows
`x` for the closure's life, `!x` borrows it to write, `<x` moves it in,
and `+x` captures a new owner. A stack closure may be lent (`?fun`) but
not stored. An owned closure (`*fun`) may be stored, and follows
sentence 9. *(built)*

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
- **The receiver-sigil rule:** `!v.push(x)` applies `!` to `v`. *(built)*
- **`const x = e`:** a binding that never changes. *(planned)*
- **A write call whose `Bool` value is used** is written
  `(!s).insert(k)`, everywhere. *(planned;* today only where its `!`
  would start a condition or an operand of `and`, `or`, or `not`.*)*
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

```rig pending
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
  place, a made value, a lend, a view, branches, or a jump, including
  whether the value lives for the whole program. *(planned)*
- **Per path, one exit primitive,** which runs defers, reports any loan
  it would drop, and rewinds when the path goes on. *(planned)*

## 10. How a feature earns its way in

- It fits one paragraph on this page, with no exception list.
- Its rules follow the value's type, never where the value came from.
- It is written as a desugaring into forms this page already covers.
- A second round of soundness fixes stops it for redesign.
- It passes the regression corpus, and runs clean under the sanitizer.
- It answers a line that failed in a real program, not parity with Rust
  or Zig.
