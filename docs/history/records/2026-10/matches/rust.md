# Iterator panel: the Rust view

Probes in this answer were run with `bin/rig` in the worktree
`incredible-project-25d019` (main at 122d523bf). The working prototype is
`rust-proto.rig` beside this file (`RIG_SANITIZE=1 bin/rig run` prints
`2 60 3 4`, correct and clean).

## 1. The dream `trim`

```rig
sub trim(!@)
  while @entries.len > MAX_ENTRIES or @bytes > MAX_CACHE_BYTES
    old = ?@entries.items()
      .filter(|e| e.value.state as .ready(_))
      .min_by(|e| e.value.touched) ?? break
    key = +old.key
    entry = !@entries.take(key) ?? break
    @bytes -= entry.bytes
    if <entry.state as .ready(r) and <r as rendered
      !@retired.push(<rendered.image)
```

Nine lines against Rust's eleven and today's thirteen. Line by line, the
Rust it borrows from and what it drops:

| Rust | Dream Rig | Why it is better in Rig |
|---|---|---|
| `self.entries.iter()` | `?@entries.items()` | the sigil says "lent to read"; no `iter` / `iter_mut` / `into_iter` trio to choose from |
| `.filter(\|(_, entry)\| matches!(entry.state, State::Ready(_)))` | `.filter(\|e\| e.value.state as .ready(_))` | no tuple destructuring of `&(&K, &V)`, no `&&` auto-deref puzzle, no macro: the item has named fields, and `as` is the one test word |
| `.min_by_key(\|(_, entry)\| entry.touched)` | `.min_by(\|e\| e.value.touched)` | one word; Rust's `min_by` (comparator) vs `min_by_key` split is a wart |
| `.map(\|(key, _)\| key.clone())` | `key = +old.key` | the clone is a sigil on its own line, where the loan visibly ends |
| `let Some(key) = oldest else { break };` | `?? break` | Rig already has this, better than `let-else` |
| `self.entries.remove(&key).unwrap()` | `!@entries.take(key) ?? break` | no `&key`, no `unwrap` panic path |
| `if let State::Ready(Some(rendered)) = entry.state` | `if <entry.state as .ready(r) and <r as rendered` | moves, visibly |
| `self.retired.push(rendered.image.clone())` | `!@retired.push(<rendered.image)` | Rust's clone here is needless (the entry is owned after `remove`); Rig's `<` moves it. Today's Rig version clones it too (`+rendered.image`) |

What parses today: all of it (`bin/rig parse`), including the chain
broken over indented `.` lines, and `rig normalize` puts the `?` on
`@entries`, not on the chain's result. What is rejected today: `.filter`
and `.min_by` (no such methods), and `as` outside an `if`/`while`
condition ("`as` binds only in the condition of an `if` or `while`
block"). The last two lines (`<entry.state as .ready(r) and <r as
rendered`, `<rendered.image`) compile and run today, so the image is
never cloned.

## 2. What it needs

1. **Library: `Iter` defaults.** `filter`, `map`, `min_by`, `max_by`,
   `find`, `any`, `all`, `first`, as default methods of the built-in
   `Iter` API, declared in the prelude, the way Rust's `Iterator` trait
   carries its adaptors. APIs already have default methods (apis.md
   Stage 3); the compiler work is letting the built-in `Iter` take
   defaults from the prelude.
2. **Language (checker rule): a callable view in an object field.**
   `keep: ?fun(?I.Item) -> Bool` makes the object a view, as a `?T`
   field already does (SPEC "Second-class views"). Today it is rejected:
   "a callable view `?fun(?I.Item) -> Bool` is only a parameter's, a
   local's, or a result's type; no value can hold one". Without it
   there is no lazy `Filter`.
3. **Language (checker rule): `x as .pattern(_)` that binds nothing is
   a `Bool` anywhere.** It parses everywhere today; only the checker
   rejects it. No new word: not `is`, not `matches`.
4. **Compiler, no syntax: closures monomorphized in generic code.**
   Lower a `?fun` parameter or field of a generic body as the closure's
   environment type at compile time, so the call is direct by
   construction (section 5).

Not needed: `let-else` (`?? break`), `if let` (`if ... as`), tuple
patterns (items have named fields), nested patterns (`.ready(r)` then
`r as rendered` reads fine), turbofish, `.cloned()` (`+`).

## 3. Would adaptors alone do it?

Terminal functions alone get half the way, and they work today: the
prototype's `min_by[I: Iter](it: !I, key, keep)` is ten lines of Rig,
and `trim` with it runs clean. The gaps, in order of size:

- **Lazy adaptors need item 2.** `filter` is an object holding the
  iterator and the predicate; Rig cannot hold a `?fun` in a field, so
  every predicate would have to be folded into each terminal function
  (`min_by(key, where:)`), which is the combinatorial API Rust avoided.
- **The predicate needs item 3.** Without `as` as a `Bool`, the filter
  closure is a four-line block (`if e.value.state as .ready(_)` /
  `true` / `false`) or a helper function: most of the noise comes back.
- **Chaining needs item 1** (defaults on `Iter`); free functions read
  inside out: `iter.min_by(!iter.filter(...), ...)`.

So: adaptors plus the two small checker rules (2 and 3). Neither adds
syntax.

## 4. Ownership traps

The chain yields `Item[?String, ?Entry]`, views of the map. In Rust the
trap is the same (`remove(&key)` with `key` borrowed from the map is
E0502), and Rust buries the fix in `.map(|(k, _)| k.clone())` inside the
chain. In the dream:

- `old` views `@entries` and keeps it lent to read. That `old` survives
  the temporary adaptor chain is already a SPEC rule: items that view
  only what the iterator views (`next(!@) -> Item[?K, ?V]? from @map`)
  view no base, so `Filter`'s `next` returning `I.Item` passes the map
  loan through, not a loan on the dead `Filter`. This is Rust's
  `Iter<'a>` lifetime, with no lifetime written.
- `key = +old.key` is the clone, a visible sigil, and the last use of
  `old`, so the read loan ends on that line.
- `!@entries.take(key)` then writes. Writing `!@entries.take(old.key)`
  instead is rejected by the ownership checker (the map lent to read
  while lent to write), with the fix to write.
- A capturing predicate (`|?now, e| e.value.touched < now`) stored in
  `Filter` keeps `now` lent for the chain's life, as SPEC §11 already
  says for `|?x|`.
- Better than today's Rig: the hand loop clones the key every time it
  finds a new minimum (`oldest = +e.key`, up to n clones per pass); the
  chain clones once. Rust and the dream both still clone a key that
  `take` drops at once. Removing that (an index from `items`, then a
  `take_at`) is a separate Map question, not an iterator one.

## 5. Zero cost

Today a generic function is emitted as a Zig `inline fn`, and a `?fun`
as `rig.FnRef` (a context pointer and a function pointer). Verified in
the prototype's emit: `pub inline fn min_by(comptime I: type, ...,
__rig_in_key: rig.FnRef(...), __rig_in_keep: rig.FnRef(...))`. After
inlining into `trim`, the function pointer is a constant and LLVM
devirtualizes it, so `min_by` already becomes the hand loop: one
`best: Item?` (a nullable pointer pair) and one `low: Int`.

For lazy adaptors that is not enough as a guarantee: `Filter`'s
predicate sits in a struct field, and the direct call then depends on
LLVM scalarizing the struct and propagating the pointer. Rust does not
rely on that: every closure has its own type, `Filter<I, F>` is
monomorphized on `F`, and the call is direct before LLVM sees it. Rig
should do the same invisibly (item 4): in a generic body or a generic
object, emit a `?fun` as `comptime Env: type` plus `*Env`, and call
`Env.__rig_invoke` directly; non-generic code keeps `FnRef`. Each chain
then compiles to one loop: `items.next()`, the inlined predicate, the
inlined key compare, exactly the hand-written loop, with no allocation
and no indirect call. The cost is the one Rust pays: an instance per
closure literal, which `inline` already pays today.

To confirm before landing: `rig build` the dream and the hand loop and
compare instructions and time on a Map of 10^6 entries (the hand loop
should lose slightly, by its repeated key clones).
