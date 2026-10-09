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
| `*` `~` | `*<x` moves `x` into a counted box; `~h` is a weak handle | `*T`, `~T` |

After a type, `T?` may be `none` and `T!` may fail; after an
expression, `e?` passes `none` up and `e!` passes a failure up.

**Reading is unmarked; writing is marked.** A bare argument is lent to
read where its parameter is a read view: `size(v)` is `size(?v)` for
`size(xs: ?Vec[Int])`. Where the parameter owns its value, a bare owner
is rejected: write `<v` to move it or `+v` to pass a clone (plain data
such as an `Int` just copies). A write is always written: `grow(!v)`, or
`!v.push(3)` for a method that changes `v`. A write call whose result
is used puts its `!` in parentheses, `x = (!v).pop()`. A value has any
number of read views or one write view, never both.

**A lend in a binding lasts.** `r = ?v[0]` keeps a view of `v[0]`;
while `r` is used later, `v` may not change, move, or drop. `for x in
?v` reads each element in place, and `for x in !v` lets the body change
it.

**Receivers.** A method declares how it takes `self`, and its call says
the same: `?self` reads (`a.balance()`), `!self` changes
(`!a.pay(30)`), and `<self` consumes (`<a.close()`).

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

**`not`** negates: `not done`. A comparison under it takes parentheses,
`not (a > b)`, or is flipped, `a <= b`. `not a and b` is `(not a) and
b`. `!` never negates.

**Builtins.** `print(a, b)` prints values separated by spaces;
`Text(a, b)` builds text the same way; `@size(T)`, `@align(T)`, and
`@name(T)` describe a type.

```rig
struct Account
  cents: Int

  fun balance(?self) -> Int
    self.cents

  sub pay(!self, amount: Int)
    self.cents -= amount

  fun close(<self) -> Int
    self.cents

  drop(!self)
    print("closed")

fun size(xs: ?Vec[Int]) -> Int
  xs.len

sub main()
  a = Account(cents: 100)
  !a.pay(30)
  v: Vec[Int] = Vec()
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
