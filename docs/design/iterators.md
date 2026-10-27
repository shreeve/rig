# Iterator chains: `map`, `filter`, and a consumer, as one loop

*Approved (2026-10-27); not built.* Chains are built after the
Swisstable Map and Set lands. This page says how Rig writes Rust's
`nums.iter().map(|n| n * n).sum()`, gives the reasons and the
measurements, and ends with the owner's decisions. Its `rig pending`
examples show the decided rules; each turns into an ordinary example
as it is built.

## Today

A List, array, or slice has `sum()` and `reduce(start, f)`, and
std.iter has `count` and `sum` over any iterator. There is no `map` or
`filter`, so a pipeline is a `reduce` or a loop:

```rig
fun by_reduce(nums: []U64) -> U64
  nums.reduce(U64(0), |total, n| total + n * n)

fun by_loop(nums: []U64) -> U64
  total: U64 = 0
  for n in nums
    total += n * n
  total

sub main()
  xs = List[U64]([1, 2, 3, 4])
  print(by_reduce(xs), by_loop(xs))
```

```output
30 30
```

Both are as fast as Rust's chain, but neither reads as one. A
pipeline of three or four steps (filter, map, take, sum) becomes a
loop whose steps are interleaved with its bookkeeping.

## Two ways to build it

**Adapter objects**, as Rust has them: `xs.iter()` gives an iterator,
`.map(f)` wraps it in an object that holds the iterator and the
closure, and `.sum()` drives the outermost one. A chain is a value: it
can be bound, passed, and returned. Rig cannot write one today, for two
reasons that are rules, not missing code:

1. **A closure cannot be a field.** "No value holds a callable view"
   (SPEC "Callable views"): a stack closure lives in its frame, and a
   field of type `?fun(...)` is refused. Holding one means a view field
   that may be a closure, a change to CORE §7's second-class views, or
   an owned closure `*fun`, which allocates and counts on every chain.
2. **An adapter whose items are views cannot be bounded.** `from
   @field`'s rule 4 judges a field of a type variable at the
   declaration. A `Take[I: Iter]` over a Map's keys builds and runs,
   but `iter.count(!t)` of it, or a `Take` of a `Take`, is refused:
   "`I.Item = ?Int`: a `?Int` may view memory `Take[Keys[Int, Int]]`
   owns". ROADMAP lists judging it per instance.

**A fused chain**: `xs.map(f).filter(g).sum()` is one loop. The
compiler rewrites it as the `for` it means, before any checker runs, and
checks and emits that loop. A chain is not a value; it ends in a
consumer (`sum`, `count`, `collect`, ...) in the same expression, or it
is a `for` loop's source, whose body is the consumer. Neither rule
above is touched: no object holds the closures, which are lent to the
statement as any closure argument is, and no generic body walks the
items.

## Measured

Each form summed the squares of 20 million `U64`s, built with `rig
build --release` on the Mac. Each time is the fastest of eight
interleaved runs of seven passes each, through `tools/low`. The adapter objects were written by
hand in today's Rig over a slice source (`Elems`, an object of a `[]U64`
and an index).

| Form | Time | Against the loop |
|---|---|---|
| `for` loop | 4.76 ms | |
| `reduce` with a closure | 4.90 ms | 3% slower |
| adapter object holding a `fun` value, summed by `iter.sum` | 4.89 ms | 3% slower |
| adapter object with the function fixed in `next`, summed by `iter.sum` | 5.98 ms | 26% slower |

A fused chain is the loop, so it costs what the loop costs. The adapter
objects cost what LLVM recovers from a `next` that gives an optional
per item, and the gap moves with what LLVM happens to see (the `fun`
value's version was the faster of the two here). Adapter values would
need that protocol tuned before they could promise Rust's cost.

Fusion also fits two of Rig's rules that adapter values would fight.
Several results never form a value, so `zip` and `enumerate` would need
a pair object as their item; in a fused chain they pass two values to
the next closure, as `for x, i in xs` binds two names. And a chain's
allocation is its `collect`, whose result is a `List`.

## The proposal

### A chain

A chain starts at any `for` source: a List, an array, a slice, a
`?String`, a range, or an iterator. Its stages are methods written
directly on the source, with no `.iter()`, and it ends in a consumer.

```rig pending
fun sum_of_squares(nums: []U64) -> U64
  nums.map(|n| n * n).sum()

sub main()
  print(sum_of_squares(List[U64]([1, 2, 3, 4])))
```

```output
30
```

It runs as the loop it means: for each item of the source, each stage
in order, then the consumer. A stage that drops an item (`filter`) or
stops the source (`take`, `find`, `any`) calls nothing after it, as
Rust's lazy adapters do, so a closure's effects happen in that order.

```rig pending
sub main()
  xs = List([3, 8, 1, 9, 4, 7])
  big = xs.filter(|x| x > 3).map(|x| x * 10).take(2).collect()
  print(big, xs.filter(|x| x % 2 == 1).count())
```

```output
[80, 90] 4
```

### Stages and consumers

| Stage | Gives each item |
|---|---|
| `map(f)` | `f(x)` |
| `filter(f)` | `x` where `f(x)` is true |
| `take(n)`, `skip(n)` | the first `n`, or all but them |
| `enumerate()` | `x, i`, two values, as `for x, i in xs` binds them |
| `zip(ys)` | `x, y`, until either source ends |

| Consumer | Result |
|---|---|
| `sum()`, `count()` | a number, as `xs.sum()` and `iter.count` give |
| `reduce(start, f)` | as `xs.reduce` |
| `collect()` | a new `List` of the items: the chain's one allocation |
| `any(f)`, `all(f)` | a `Bool`, stopping at the first that decides |
| `find(f)` | the first item where `f` is true, or `none` |
| `min()`, `max()` | an item, or `none` when there are none |

A stage after `enumerate` or `zip` takes a closure of two parameters:

```rig pending
sub main()
  a = [1, 2, 3]
  b = [4, 5, 6]
  print(a.zip(b).map(|x, y| x * y).sum())
```

```output
32
```

### What it holds, and when

A chain is checked as the loop it is, so the rules are the `for`
loop's and a closure argument's. Nothing is new:

- **The source is lent for the statement**, as a `for` source is lent
  for its loop: read, with no mark, for a List, array, slice, or
  string. An iterator advances, so it is lent to write, with the mark
  in parentheses, as for any write call whose result is used:
  `(!it).map(f).sum()`.
- **Each closure is lent to the statement**, as one lent to `reduce`
  is: its captures conflict with the statement's other views, so
  `xs.map(|!xs, x| ...)` is rejected.
- **Items are what `for` gives:** a plain value copies, and an owner
  element is lent, `?T`, as `reduce` lends it. A value a stage makes
  (`map(|s| s.len)`) is owned by the step, and dropped at the end of
  its item unless a consumer keeps it.
- **`collect()` owns what it keeps.** It moves made values into its
  List, and copies plain ones; a view item is rejected, with the fix:
  `.map(|s| +s).collect()` clones each.
- **A closure that can fail makes the consumer fallible**, ending at
  the first failure, as `reduce` does; the call says `!` or `catch`.

### A chain is not a value

A chain bound to a name, passed, or returned is rejected, with the
three ways to end it:

```rig pending
sub main()
  xs = List([1, 2, 3])
  evens = xs.filter(|x| x % 2 == 0)
  print(evens.count())
```

```error
a chain is not a value: end it with a consumer (`.count()`, `.collect()`), or make it a `for` loop's source
```

A `for` over a chain is its own consumer, and its body may `break`:

```
for name in names.filter(|n| n.len > 3).take(10)
  print(name)
```

A fused chain is still lazy: it takes one item at a time from its
source and stops as soon as a stage or the consumer is done, so `take`
and `find` end an endless source. What it cannot do is wait: it runs
where it is written. The day a program needs a chain as a value, the
adapter objects above can make one, after the two rules they need
change; the source text of every chain stays the same.

### Where it lives

One classifier (North Star 4): sema decides that a call chain is an
iterator chain (a stage method on a `for` source, not a method the
source's type declares) and records it as a fact. The rewrite that
turns a `for` over an iterator into a `while` after the module's first
check then turns the chain into its loop, before ownership and storage
run, so the
checkers check exactly what emit writes, and `rig normalize` shows it.
A type's own method of the same name wins: `Wrap.map` stays `Wrap`'s.

### The Core

It fits in a paragraph (CORE §10): *a chain over a source is the `for`
loop over that source whose body applies each stage in order and then
the consumer; it is checked and emitted as that loop.* No sentence of
CORE changes. SPEC gains a section after "`for`", STD lists the stages
and consumers, and docs/learn gets an example.

## Decisions

The owner approved each on 2026-10-27.

1. **Fused chains, not adapter values.** Build chains as loops now; make
   a chain a value only when a program needs one. *Approved.*
2. **No `.iter()`.** Stages are methods on every `for` source.
   *Approved.*
3. **The first set.** Stages `map`, `filter`, `take`, `skip`,
   `enumerate`, `zip`; consumers `sum`, `count`, `reduce`, `collect`,
   `any`, `all`, `find`, `min`, `max`. *Approved: that set.*
4. **The consumer that makes a List.** Candidates, each shown in a
   declaration, an error message, and a sentence of prose:
   - `collect()`, Rust's and Java's word: `fun collect(chain) -> List[T]`,
     "end it with a consumer (`.collect()`)", "`collect` makes the one
     List".
   - `list()`, a short plain word: `fun list(chain) -> List[T]`, "end
     it with a consumer (`.list()`)", "`list` makes the one List".
   - `to_list()`, the conversion spelled out: `fun to_list(chain) ->
     List[T]`, "end it with a consumer (`.to_list()`)", "`to_list`
     makes the one List".

   *Approved: `collect()`.*
5. **Read chains first.** A chain whose source is written (`for x in
   !xs.filter(f)`) or moved (`<xs.map(f)`) waits for a program that
   needs it. *Approved.*
6. **Rule 4 per instance is its own change.** It is needed by any
   adapter a program writes, not by chains. *Approved: build it when
   a program writes one, with the `from @field` review's tests.*
7. **When.** After the Swisstable Map and Set lands, as the next
   language feature (one at a time). *Approved.*
