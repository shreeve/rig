# Beyond Rust

Rig takes Rust's central idea, ownership checked at compile time with
no garbage collector, and keeps Rust's guarantees. It changes how that
idea is named, what the checker reasons about, and how the checker
itself is tested. This page collects those differences for readers who
know Rust. The rules themselves are in [CORE](CORE.md); the reasons for
the sigils are in [DESIGN](DESIGN.md).

## 1. One word for each side of a hand-over

Rust's *borrow* names three things at once: the act (`&v`), the
reference it makes, and the checker's record that keeps the owner from
changing. Rig names each from where it sits
([DESIGN](DESIGN.md#lend-view-loan-naming-from-the-owners-side)):

| Rust | Rig | What it is | Where it lives |
|---|---|---|---|
| borrow `v` (`&v`, `&mut v`) | `v` **lends** (`?v`, `!v`) | the act | the owner's side, where the sigil is written |
| a reference, a slice, a `&str` | a **view** (`?T`, `!T`, `[]T`, `![]T`, `String`) | the value handed over | travels with the receiver |
| "`v` is borrowed" | a **loan** of `v` | the record | stays with the owner, and limits it until every view is done |

The sigil is written on the owner in both languages, at the place where
the owner hands something over. Rust names that act from the receiver's
side; Rig names it from the owner's, where the code shows it. So an
error can say exactly which act meets which record: *cannot lend `v` to
write while a read loan is live*.

The words stay inside Rust's conversation. *Loan* is the term Rust's own
checker uses internally: Polonius, the formal model behind Rust's
next-generation checker, states its rules as loans that are issued,
killed, and invalidated. A Rust programmer needs one line of
translation, and nothing to unlearn.

**One word for every view.** Rust's `&T`, `&mut T`, `&[T]`, and `&str`
are four ideas to learn. In Rig they are one: a view, read or write,
of a value, of part of an array or `Vec`, or of a `Text`'s bytes. The
same rules cover all of them ([CORE §4](CORE.md#4-one-lend-table)).

**A drop is a move.** Rust's `drop(x)` moves `x` into a function that
does nothing with it. Rig says the same with no function: `<x` alone on
a line moves `x` nowhere, so it drops now
([CORE sentence 2](CORE.md#2-the-core-in-ten-sentences)).

**Precise words show where the model is not yet uniform.** In Rust's
vocabulary, a rule that treats two kinds of reference differently goes
unnoticed. In Rig's, it stands out as "a view that is not like the
others", which is a prompt to unify it.

## 2. Loans without lifetimes

Rust reasons about lifetimes: regions such as `'a`, written in
signatures and solved across a whole function. Rig has none. Each value
carries the set of loans it holds, the checker follows each path of a
function on its own, and loan sets meet where paths join. What a result
views comes from the signature alone: it carries the loans of every
argument whose type could hold what it views, or of only those its
signature names with `from a`, which the compiler proves from the body
([CORE sentence 7](CORE.md#2-the-core-in-ten-sentences)). There is no
lifetime variable to declare and none to thread through a struct.

The difference shows in the case Rust's non-lexical lifetimes RFC lists
as *problem case #3*: take a view, return it on one path, and change the
owner on the other.

```rust
fn get_or_add(b: &mut Bag) -> &Item {
    let r = &b.items[0];
    if r.n > 0 {
        return r;
    }
    b.items[0] = Item { n: 7 }; // error[E0506] under NLL
    &b.items[0]
}
```

Rust's current checker rejects this, because the returned reference's
lifetime must hold on every path, including the one that writes `b`.
Polonius was designed to accept it. Rig accepts it today: the path that
returns `r` ends there, so its loan never reaches the path that writes.

```rig
struct Item
  n: Int

struct Bag
  items: [4]Item

fun get_or_add(b: !Bag) -> ?Item
  r = ?b.items[0]
  if r.n > 0
    return r
  b.items[0] = Item(n: 7)
  ?b.items[0]

sub main()
  b = Bag(items: [4 of Item(n: 0)])
  r = get_or_add(!b)
  print(r.n)
```

```output
7
```

The same write is rejected on a path where the view is still live:

```rig reject
struct Item
  n: Int

struct Bag
  items: [4]Item

fun get_and_add(b: !Bag) -> ?Item
  r = ?b.items[0]
  b.items[0] = Item(n: 7)
  r
```

```error
cannot assign to `b.items[0]`
```

The trade: Rust can say with explicit lifetimes which argument a
result views, and Rig cannot. A function lent two values whose result
views only one of them keeps both lent while the result lives. Rig
accepts that cost so a reader never solves lifetime equations ([DESIGN](DESIGN.md#views-without-lifetimes)).

## 3. A checker that is tested, not trusted

An ownership checker is only as sound as its last bug. Rig holds its
compiler to one rule, *accept means correct* ([AGENTS](../AGENTS.md)):
a program `rig check` accepts compiles, runs, and does what it says,
with no leak and no use of freed memory. The test suite checks that
rule from several independent directions ([test/README](../test/README.md)):

- **A sanitizing allocator.** Every program the suite runs gets pages
  of its own for each block, made inaccessible when the block is freed,
  and no address is handed out twice, so a use after free crashes at the
  spot instead of printing a stale value.
- **A corpus of reviewer probes.** Every adversarial program a reviewer
  writes is kept, and must be rejected with a diagnostic or run clean.
- **A form × context × type matrix.** Generated programs place each
  expression form (a name, a ternary, `o?`, `??`, a call, `<x`, ...) in
  each context (an argument, a binding, a receiver, a block's tail, a
  `match` subject, ...) for each kind of type.
- **An equivalence check.** `test/equiv.py` runs two compilers over
  every program and doc example and compares the parse tree, the
  semantic IR, the diagnostics, sema's facts, and the emitted Zig, so a
  refactor proves it changed nothing.

**Direction: a reference checker.** A small, deliberately simple
ownership checker, written straight from CORE's sentences and sharing
no code with the production checker, would run beside it in the test
suite only. Where the two disagree on a program, one of them has a bug:
if the production checker accepts what the reference rejects, that is a
likely soundness hole, found at check time rather than when a program
happens to touch freed memory. It would never run in `rig check`, and
it would add nothing to compiled programs.
