# Iterator panel: the Swift view

Panelist: Swift. Checked against the worktree at `122d523bf`
(`bin/rig parse`, `normalize`, `check`, `run` with `RIG_SANITIZE=1`);
probes are in the session scratchpad. The approved design
`docs/design/iterators.md` (fused chains, no `.iter()`, `collect()`) is
assumed; this answer says what Swift adds to it and what Swift warns
against.

## Swift's best idiom, and what it costs

```swift
func trim() {
    while entries.count > maxEntries || bytes > maxCacheBytes {
        guard let key = entries.lazy
            .filter({ if case .ready = $0.value.state { true } else { false } })
            .min(by: { $0.value.touched < $1.value.touched })?.key
        else { break }
        let entry = entries.removeValue(forKey: key)!
        bytes -= entry.bytes
        if case .ready(let r?) = entry.state { retired.append(r.image) }
    }
}
```

What it reads like is good: one expression finds the key, `guard ... else
{ break }` leaves, `if case .ready(let r?)` binds through an enum and an
optional in one pattern. What it costs, honestly:

1. **Eager by default.** Without `.lazy`, `Dictionary.filter` returns a
   new `Dictionary`: a heap table, every surviving key rehashed, every
   key and value copied. This is Swift's best-known iterator trap, and
   `.lazy` is opt-in, so the slow form is the short one.
2. **Elements by value.** Iterating a `Dictionary` yields `(key: String,
   value: Entry)` tuples by copy: a retain (atomic) of the key's buffer
   and of every class reference or array inside `Entry`, per element,
   per pass of the `while`. The optimizer removes much of this, not all,
   and nothing in the source says which.
3. **Closures.** `min(by:)`'s closure is non-escaping (stack context),
   but `lazy.filter`'s is stored in `LazyFilterSequence`, so it is
   escaping: its context may be heap-allocated and reference-counted
   unless specialization inlines it, which fails across a resilient
   module boundary.
4. **Implicit copies.** `?.key` copies the String (a retain) and
   `r.image` another; neither is marked. Swift is safe here because the
   copy is silent, which is exactly what Rig refuses.
5. **Exclusivity.** On a class `Cache`, each `self.entries` access may
   pay a dynamic `swift_beginAccess` check.
6. **No pattern test as an expression.** Swift still has no
   `x is case .ready`; the filter needs `if case ... { true } else {
   false }` (5.9's if-expressions) or a hand-written `var isReady`.
7. **`$0`/`$1`.** Short, but `$0.value.touched < $1.value.touched` is a
   comparator, easy to get backwards, and says nothing about ownership.
8. **Key paths.** `\.value.touched` works as a function (SE-0249) only
   where `(Root) -> Value` is expected; `min(by:)` wants a comparator, so
   the key path does not fit without a custom `min(by keyPath:)`.

## 1. The dream Rig version

```rig
sub trim(!@)
  while @entries.len > MAX_ENTRIES or @bytes > MAX_CACHE_BYTES
    oldest = ?@entries.items()
      .filter(|e| e.value.state as .ready)
      .min_by_key(|e| e.value.touched) ?? break
    key = +oldest.key
    entry = !@entries.take(key) ?? break
    @bytes -= entry.bytes
    if <entry.state as .ready(r) and <r as rendered
      !@retired.push(<rendered.image)
```

It **parses today** (`bin/rig parse`), and `rig normalize` already moves
the `?` onto `@entries`, the receiver of `items()`. What does not check
today: `filter` and `min_by_key` (no stages), and `x as .ready` outside
an `if`/`while` condition (rejected: "`as` binds only in the condition
of an `if` or `while` block"). The last three lines **run today,
sanitizer-clean**: moving the state out (`<entry.state`, `<r`) moves the
image into `retired` with no clone, where Rust's code, and the brief's
Rig, clone it. (`r as rendered` without `<` gives a view, and the move
is rejected: "cannot move out of `rendered.image`: `rendered` is a
view".)

How Swift shaped it:

- `guard let ... else { break }` is Rig's `?? break`, already, and
  shorter. Keep it; nothing to add.
- Swift's protocol-extension algorithms (one `filter` for every
  `Sequence`) are the approved "stages are methods on every `for`
  source". Good.
- Swift's `?.key` is *not* borrowed: Rig's `a?` returns `none` from the
  function, and giving `?.` Swift's local meaning would give `?` a
  second meaning. Two lines (`?? break`, then `+oldest.key`) say more:
  where the loop ends, and where the one clone is.
- `$0` is *not* borrowed: `$` is Rig's label and builtin mark (the lexer
  says so: "`$` touches the name after it: a builtin call is written
  `$size(T)`, a label `$outer:`"), and a closure's bar list is where its
  captures and their sigils live; `$0` would have nowhere to put `|+n|`.
  `|e| e.value.touched` is four characters longer than a key path and
  names its parameter.
- Key paths are *not* borrowed: the leading dot is Rig's enum-variant
  mark (`.ready`), and a key path would hide whether the key is a copy
  or a view.
- `lazy` is *not* borrowed: every Rig chain is fused, so lazy, and
  `collect()` is its one allocation. Swift's lesson is to never make
  the allocating form the default; the approved design already got this
  right.
- `if case .ready(let r?)` (a nested optional pattern) is the one Swift
  pattern Rig lacks; `.ready(r?)` fails to parse today ("unexpected
  `?`"). I do not recommend it now: `and <r as rendered` is clear, one
  mechanism, and works.

A no-language-change variant, for comparison, replaces the `as`
expression with a method (it runs today; a method may not be named
`ready`, which is a variant: "duplicate member `ready` in `State`"):

```rig
fun State.is_ready(?@) -> Bool
  if @ as .ready
    return true
  false
```

and the filter becomes `.filter(|e| e.value.state.is_ready())`. That is
Swift's `var isReady` workaround, one declaration per variant tested: the
cost of not having the expression.

## 2. Features needed

| Feature | Kind |
|---|---|
| `filter(f)` stage on a `for` source, an iterator a method makes included (`?@entries.items()`) | library (approved set) |
| `min_by_key(key)` consumer: the item with the least key, the first of equals, `none` when none; key called once per item | library (new; mirrors std.sort's `sort_by_key`) |
| a consumer's result that views the source keeps it lent while it lives, as `get`'s does | rule for the chain rewrite (no new syntax; today's `get` rule) |
| `x as .variant` / `x as .variant(_)` as a `Bool` expression when the pattern binds no name | language (checker only: the grammar already parses it) |
| `?? break`, `+x`, `<x`, `and <r as v` | built today |

Naming: Swift's `min(by:)` takes a comparator. Rig should take a key,
as `sort_by_key` does: a key cannot be written backwards, and the
comparator form can wait for a program that needs it. If the owner
prefers one word, `min(key)` (with `min()` for `Ord` items) is the
alternative; `min_by_key` keeps std.sort's vocabulary. `max_by_key`
gives the first of equals too, unlike Rust's (last), so the pair is
symmetric.

## 3. Do adaptors alone get most of the way?

Most, not all. With `filter` and `min_by_key` and nothing else, the
search is three lines with a `is_ready` helper. The gap:

1. **A pattern test is not an expression.** Every `filter` over an enum
   hits this, which is why Rust has `matches!` and Swift users write
   `isX` properties. Allowing `as` with a binding-free pattern anywhere
   a `Bool` goes keeps one word for "test this pattern" (the brief's
   "one word, one mechanism"), and needs no grammar change. A new word
   `is` would be a second word for the same test; Swift's `is` means a
   type test, which would mislead.
2. **The approved `min()`/`max()` need `Ord` items**; a Map's items are
   `Item[?K, ?V]`, so the task needs the key form.
3. **A consumer's result views the source.** `find`, `min`, and
   `min_by_key` hand back an item, here a view into the map. The
   approved design lends the source "for the statement"; it must say
   that the loan lasts while the result lives, as `?@entries.get(k)`'s
   does. Today's checker already does exactly this for `get` (probe d:
   the loan ends at the last use of the view; a use after `take` is
   rejected).
4. **Optional `.map`** is not needed: `?? break` then `+oldest.key`.

## 4. Ownership: the view and the `take`

The chain yields `Item[?String, ?Entry]` views of the map, and the
consumer's result is one of them, so `oldest` keeps `@entries` lent to
read. Visible in three marks:

- `?@entries.items()`: the source is lent to read; the `?` is required,
  as the checker requires it on `get` today ("`@entries.get("a")` keeps
  `@entries` lent while `e` lives; write `?@entries.get("a")`").
- `+oldest.key`: the one clone, of the winner only, after the search.
  The loan ends there, at `oldest`'s last use.
- `!@entries.take(key)`: the write lend, legal because no view is live.

Writing the Swift shape, `!@entries.take(oldest.key)`, is rejected; the
same mistake in today's Rig gives "cannot lend `@entries` to write while
a read loan is live", with a note at the read lend (probe b). So does
any use of `oldest` after the `take` (probe d2). Swift makes this
correct by copying silently; Rig makes it correct by refusing the
uncopied form and making the copy a mark.

Cloning inside the chain (`.map(|e| +e.key).min...`) would clone every
key; the design's rule that items stay views until a consumer keeps
them pushes the clone to the right place. This is also cheaper than the
brief's hand loop, which clones a key each time a new minimum appears.

## 5. Zero cost

The chain is rewritten, before ownership and storage run, into the loop
it means (approved design, "Where it lives"):

```rig fragment
oldest: Item[?String, ?Entry]? = none
best = 0
for e in ?@entries.items()
  if e.value.state as .ready
    k = e.value.touched
    if oldest == none or k < best
      oldest = e
      best = k
oldest = oldest ?? break
```

So there is no adapter object, no stored closure, no optional per stage:
the closures are lent to the statement and inlined, as `reduce`'s are
in a release build (STD "reduce"), the item is a pair of pointers into
the map's entries, the key is computed once per item and kept, and the
`as` test is the tag compare an `if` would make. The checkers check
that loop, and emit writes it, so it is the hand-written loop minus the
per-improvement clone. Against Swift: no `Dictionary` copy (point 1),
no retain per element (2), no closure context (3), one visible clone
(4), and no dynamic exclusivity check (5); the borrow is proved at
compile time.

## Probes (all on this worktree's `bin/rig`)

| Probe | Result |
|---|---|
| brief's Rig `trim` | runs: `2 80 1` |
| dream version | parses; `normalize` gives `(read (member @ entries))` as `items`'s receiver |
| `b = s as .ready(_)` | rejected: `as` only in an `if`/`while` condition |
| `!@entries.take(e.key)` inside the loop | rejected: write lend while read loan live |
| view from `?@entries.get` used before `take`, not after | runs; used after, rejected |
| `<entry.state as .ready(r) and <r as rendered`, `push(<rendered.image)` | runs sanitizer-clean, no clone |
| same without `<r` | rejected: `rendered` is a view |
| `.ready(rendered?)` nested optional pattern | does not parse |
| `$0` | lexer rejects: `$` is labels and builtins |
| `fun State.is_ready(?@)` with `if @ as .ready` | runs; naming it `ready` collides with the variant |
