# Iterator panel: the Ruby view

Probe files (all run against this worktree's `bin/rig`) are in
`/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-incredible-project-25d019/61e6bc21-7c82-43f3-8978-0dbbd8206817/scratchpad/ruby/`
(`lib6.rig` is the working library-only `min_by`; `dream.rig` and
`dream_full.rig` are the dream version).

## What Ruby would write, and what it hides

```ruby
def trim
  while entries.size > MAX_ENTRIES || bytes > MAX_CACHE_BYTES
    key, = entries.select { |_, e| e.state in Ready }.min_by { |_, e| e.touched }
    break unless key
    entry = entries.delete(key)
    self.bytes -= entry.bytes
    retired << entry.state.rendered.image if entry.state in Ready(rendered: Rendered)
  end
end
```

This is why Ruby is loved: the line says *what* (the ready entries, the
least recently touched one, its key) and nothing about *how*. Enumerable
is a mixin keyed on one method (`each`), and every collection gets
`select`, `min_by`, `find`, `each_with_object` for free. Ruby 3's
`expr in pattern` is a Bool anywhere, which is exactly the missing
`matches!`.

What the beauty costs, every line of it hidden:

- `Hash#select` builds a whole new Hash of the ready entries: an
  allocation sized to the cache, per eviction, inside a `while`.
- `min_by` on a Hash yields a fresh two-element `[k, v]` Array per entry.
- `key` is a shared reference, so the question "may I mutate the map
  while I hold its key?" never comes up. The GC answers it. In Rig it is
  the central question (the trap in Q4).
- `min_by` on nothing returns `nil`; `key, = nil` quietly binds nil, and
  forgetting `break unless key` is a `NoMethodError` three lines later.
- Blocks capture every local silently, and `break`/`return` inside a
  block leave the *enclosing method call*: non-local control flow, the
  opposite of "no silent control flow".
- Three spellings of a block parameter (`|x|`, `_1`, `it`) and alias
  pairs (`select`/`filter`, `find`/`detect`, `map`/`collect`): many ways
  to say one thing.

Rig should take the *shape* (a pipeline of plain verbs, one per line) and
refuse every hidden item above.

## 1. The dream version

```rig
sub trim(!@)
  while @entries.len > MAX_ENTRIES or @bytes > MAX_CACHE_BYTES
    oldest = ?@entries.items()
      .filter(|e| e.value.state as .ready(_))
      .min_by(|e| e.value.touched) ?? break
    key = +oldest.key
    entry = !@entries.take(key) ?? break
    @bytes -= entry.bytes
    if entry.state as .ready(r) and r as rendered
      !@retired.push(+rendered.image)
```

Read aloud it is Ruby's line: lend the entries to read, keep the ready
ones, take the least touched, or stop. Every Rig mark is still there:
`?@entries` (the lend that the whole chain lives under), `?? break` (the
empty case, visible and local, not a nil three lines later), `+oldest.key`
(the one clone, on its own line), `!@entries.take` (the write).

**What parses today:** all of it. `bin/rig parse dream.rig` succeeds, and
`bin/rig normalize` already moves the `?` onto `@entries` (`(read (member
@ entries))`) so the lend covers the chain, and the deeper `.` lines
continue the statement. `bin/rig check` on the full program reports exactly
two errors, the two gaps: `no method 'filter' on type 'Items'`, and `as
binds only in the condition of an if or while`.

Choices made and refused, from the Ruby side:

- **`filter`, not `select`.** Ruby itself added `filter` as an alias (2.6)
  because Python, JS, Rust, and Java all say filter. One word per idea:
  take the one everyone knows, and no aliases.
- **`|e|`, not `it` or `_1`.** Ruby 3.4's `it` is lovely, but in Rig the
  bar list is where captures are marked (`|?@now, e| e.value.touched <
  @now`); a parameterless closure would need a second rule for where its
  captures go. `it` is also a live name in std (`count(it: !I)`). `|e|` is
  four characters; the bar list is Rig's visible-capture mechanism and
  should stay the only one.
- **No `&:touched`.** Rig already has the honest analogue, `Type.method`
  as a value (`Counter.bump`). Here it would not help: the item is a
  generic `Item[?K, ?V]` (whose methods cannot be named as values) and
  the key is a path, `e.value.touched`. Ruby has the same wall on Hash
  pairs (`min_by(&:touched)` does not work on `[k, v]`). Skip it.
- **No destructuring `|k, e|`** in the block. `e.key` / `e.value` already
  read well, and a pair binding would need a rule for which half is a
  view of what.

## 2. Features needed

1. **Language, small:** `x as .pattern` with no bound names (only `_`)
   is a `Bool` expression anywhere (Ruby 3's `expr in pattern`). The
   binding form stays condition-only. The normalizer already lowers it to
   `as_match`; sema rejects it.
2. **Language:** a stack closure held by value in a generic object field
   (`obj Filter[I: Iter, F]` with `keep: F`), the holder becoming
   second-class as a view-holding object is today. Probed: a `?fun` field
   is rejected ("a callable view ... no value can hold one"), and a
   `fun` field rejects the closure ("cannot be moved, returned, stored,
   or copied"); only `*|...|`, a heap handle, can be stored, which is not
   zero-cost.
3. **Language, small:** item provenance passes through a generic
   adaptor: `Filter[I, F]`'s items view what `I`'s items view (a
   `next(!@) -> I.Item? from I.Item`-style rule), so a Map's items still
   "view no base". Probed: a generic `Select` wrapper makes `min_by`
   reject its items as viewing memory the wrapper owns.
4. **Language, small:** defaults on the built-in `Iter` (or `Iter`
   declared in the prelude as an API with defaults, still structural), so
   every iterator gets `.filter` and `.min_by` as Enumerable gives
   every `each`. API defaults are built for declared APIs already.
5. **Library:** `std.iter` adaptors as those defaults: lazy `filter`,
   `map`, `take_while`; terminal `min_by`, `max_by`, `find`, `any`,
   `all`, `first`. One name each, no aliases.

## 3. Would adaptors alone get most of the way?

Terminal ops, yes, and they work **today** as free functions. `lib6.rig`
defines

```rig
fun min_by[I: Iter, K: Ord + Copy](it: !I, key: ?fun(?I.Item) -> K) -> I.Item?
```

and `all = ?@entries.items()` / `oldest = min_by(!all, |e|
e.value.touched) ?? break` / `key = +oldest.key` / `!@entries.take(key)`
runs correctly under `RIG_SANITIZE=1`. The closure takes its parameter
type from the signature; no annotation needed.

The gap is everything lazy, and the method spelling:

- `filter` must hold its closure between `next` calls (feature 2).
  That is the real gap; `min_by`, `find`, and `any` only borrow the
  closure for one call and need nothing new.
- An adaptor wrapper loses the Map items' "views no base" fact
  (feature 3).
- A free-function chain reads inside out (`min_by(!filter(!it, f), g)`)
  and needs a named temporary today (`min_by(!(?@entries.items()), ...)`
  is rejected: "a view of the temporary ... outlives its statement").
  Method form on a moved temporary (`<@`) fixes both (feature 4).
- The filter predicate needs feature 1, or a `match` with two arms in a
  block closure.

So: adaptors as a library get the terminal half; the lazy half is one
real language step (closures stored by value), plus two small ones.

## 4. Ownership traps

The trap is real and the checker already catches it. Probed:

- `!@entries.take(oldest.key)`: rejected, "cannot lend `@entries` to
  write while a read loan is live", with a note at `?@entries.items()`.
- `!@entries.take(+oldest.key)`: rejected, "lend `oldest.key` instead: a
  clone into a read view is only read, then dropped". So the clone
  cannot hide inside the call; it must be its own line.

The dream version therefore makes it visible by construction:

- `?@entries` at the head of the chain is the lend, and it lives while
  `oldest` lives. `oldest` is an `Item` viewing the map, nothing more.
- `key = +oldest.key` is the one place memory is made, and it is where
  `oldest`'s life (and the read loan) ends.
- `!@entries.take(key)` is the write, legal because the loan ended on the
  line above.

Ruby needs none of this because the GC keeps the key alive; Rust needs
`.map(|(k, _)| k.clone())` inside the chain. Rig's version is better than
both: the clone is outside the chain, once, after the minimum is known.
The "Rig today" hand-written loop actually clones the key **every time a
new minimum is found** (`oldest = +e.key` inside the `for`), an
allocation and drop per improvement. The chain clones once per eviction.

Captures stay explicit too: a predicate that reads self is written
`|?@now, e| ...`, so the chain also keeps `@now` lent, visibly. Ruby's
silent capture and non-local `break` from a block are both impossible:
`?? break` sits outside every closure.

## 5. Zero cost

`filter(<@, f)` returns `Filter[Items[String, Entry], F]`, a stack struct
of the map iterator (a map pointer and an index) and the closure's
environment, which here captures nothing (zero bytes). `min_by(<@, key)`
is a generic, `inline` function; the emitted Zig for `lib6.rig`'s
`min_by` is already `pub inline fn min_by(comptime I: type, comptime K:
type, ...)` with the key closure called directly. After Zig
monomorphizes `Filter.next` and `min_by` and inlines both:

- `Filter.next` is `while (src.next()) |x| if (keep(x)) return x;`,
- the `as .ready(_)` test is one tag compare,
- `min_by` keeps `best` (an item: two pointers into the map's entry
  array) and `best_k` (an Int),

which is the hand-written `for` / `if` / `if` loop, with no allocation
and no indirect call. One difference, in Rig's favour: no key clone
inside the loop. The only allocation in the whole `trim` is
`+oldest.key`, written by hand, once.

The guarantee to write into the design: adaptors are `inline` generics
over a closure's own type, never over `?fun` stored in a field and never
over `*fun`, so no adaptor can introduce an indirect call or a heap
handle; a `code` test on the emitted Zig for this chain pins it.
