# Rig on one page

Rig's sigils show who owns a value and who may change it. [CORE](CORE.md)
states the ownership model in full; [SYNTAX](../SYNTAX.md) and
[SPEC](../SPEC.md) give every form.

| Sigil | Before a value | Before a type |
|---|---|---|
| `?` | `?x` lends `x` to read | `?T`, a read view |
| `!` | `!x` lends `x` to write | `!T`, a write view |
| `<` | `<x` moves `x`; alone on a line, drops it now | |
| `+` | `+x` clones: a new owner, or another handle | |
| `^` `*` `~` | `^<x` moves `x` into a box; `*<x` moves `x` into a counted handle; `~h` is a weak handle, and `*w` upgrades it to a `*T?` | `^T`, `*T`, `~T` |

After a type, `T?` may be `none` and `T!` may fail; after an
expression, `e?` passes `none` up and `e!` passes a failure up.

**An object is a value; `^` puts it on the heap and `*` shares it.** `b = a`
copies a plain object and moves an owning one; the object itself is
never on the heap or shared unless a sigil says so.

**After a name, `[]` is compile time and `()` is run time.** Indexing is
the one familiar exception: `max[Float](1, 2)` passes a type, `xs[i]`
indexes a value.

**Reading is unmarked; writing is marked.** A bare argument is lent to
read where its parameter is a read view: `size(v)` is `size(?v)` for
`size(xs: ?List[Int])`. Where the parameter owns its value, a bare owner
is rejected: write `<v` to move it or `+v` to pass a clone (plain data
such as an `Int` just copies). A write is always written: `grow(!v)`, or
`!v.push(3)` for a method that changes `v`. A write call whose result
is used puts its `!` in parentheses, `x = (!v).pop()`. A value has any
number of read views or one write view, never both.

**A lend in a binding lasts.** `r = ?v[0]` keeps a view of `v[0]`;
while `r` is used later, `v` may not change, move, or drop. `for x in
?v` reads each element in place, and `for x in !v` lets the body change
it. The same holds for a call whose result keeps its argument lent:
`r = head(?v)`, `xs = ?b.all()`, and `!xs.push(head(?v))` are written, while `print(head(v).len)`
needs no mark, since its loan ends with the statement.

**A call keeps only what it says.** A view lent to a call ends when the
call returns, unless the function names that parameter in `keeps`:
`sub watch(!self, s: ?String) keeps s` may store `s` in `self`, so its
call is written `!b.watch(?t)`, and `t` stays lent while `b` is used. A
body that stores a lent parameter without saying so is rejected.

**Receivers.** A method declares how it takes `self`, and its call says
the same: `?self` reads (`a.balance()`), `!self` changes
(`!a.pay(30)`), and `<self` consumes (`<a.close()`).

**Shared state.** What handles share is a `Cell`, and it changes only by
a marked call: `!c.set(5)`, which lends the handle `c`. Reading,
`c.get()`, is unmarked, and a read view never changes a `Cell`.

```rig
sub main()
  c: *Cell[Int] = *Cell(1)
  d = +c
  !d.set(5)
  print(c.get())
```

```output
5
```

**Moves, clones, drops.** `b = <a` moves `a`, which is unusable after,
and `f(<a)` hands it to `f`. `b = +a` is a new owner, or another handle
of a `*T`. `<a` alone on a line drops `a` now; anything not moved is
dropped where its block ends, running its `drop(!self)` body. A name
moves with no `<` only where its scope ends: `return x`, or `x` as the
function's last value.

**Optionals and failure.** `if o as x` binds `x` when `o` is not
`none`, and `o ?? d` gives `d` instead. A `T!` function fails with
`return E.name`; each call to it says `f()!`, to pass the failure up,
or `f() catch d`.

**Several results.** `fun divmod(a: Int, b: Int) -> (Int, Int)` gives
two, with `return a / b, a % b`, and `q, r = divmod(17, 5)` binds each
by name; `_` discards one. They never form a value: a group of values
kept past its statement is an object. One result may be a write view,
`w, added = (!m).ensure_added(k, 0)`, which keeps `m` lent to write as
`w` lives, while `added` keeps nothing.

**`not`** negates: `not done`. A comparison under it takes parentheses,
`not (a > b)`, or is flipped, `a <= b`. `not a and b` is `(not a) and
b`. `!` never negates. On an integer, `x.not()` flips every bit
(`0.not() == -1`); `not x` is rejected. `x.count_ones()`,
`x.leading_zeros()`, and `x.trailing_zeros()` count bits, `x.swap_bytes()` reverses bytes, and `x <<% n`
shifts left, dropping the bits that fall off. `a +| b` and `a -| b`
saturate, stopping at the type's limits.

**Vectors.** `Simd[U8, 16]` holds 16 lanes, operated on together:
`v + 1` and `v == q` work lane by lane, a comparison gives a mask
(`Simd[Bool, 16]`), and `m.first()` (the first true lane, `Int?`), `m.bits()`, `m.any()`, or `m.all()` reduce it.
A vector copies like an `Int`, and `v[i]` reads a lane. `v >> 4` shifts
every lane, `t.lookup(idx)` looks each lane of `idx` up in a table `t`
of 16, 32, or 64 bytes, and `cur.lag[1](prev)` sees each lane's neighbour one lane
back, across from `prev`.

**Builtins.** `print(a, b)` prints values separated by spaces and reads them like a
read parameter (`print(w[1..3])`);
`String(a, b)` builds text the same way; `@size(T)`, `@align(T)`, and
`@name(T)` describe a type.

```rig
obj Account
  cents: Int

  fun balance(?self) -> Int
    self.cents

  sub pay(!self, amount: Int)
    self.cents -= amount

  fun close(<self) -> Int
    self.cents

  drop(!self)
    print("closed")

fun size(xs: ?List[Int]) -> Int
  xs.len

sub main()
  a = Account(cents: 100)
  !a.pay(30)
  v: List[Int] = List()
  !v.push(a.balance())
  w = +v
  print(size(v), (!w).pop() ?? 0, w.len, not (a.balance() > 50))
  print(<a.close())
```

```output
1 70 0 false
closed
70
```
