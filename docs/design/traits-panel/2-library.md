# Panel 2, standard library and migration

Read against origin/main 59a8c9a18: std/*.rig, docs/STD.md, SPEC §3 "Generic bodies", §5 `.hash()`, §6
iterators, §10 String, §17 printing, §18 crossing, DESIGN "Per-instance checking", and panel 1's three
reports. The census is a heuristic over the source, described under Q3.

## Q1. Which traits std defines, and how a type opts in

Two kinds, split as panel 1 (types) proposes, with one naming rule that keeps them apart. A fact the
compiler derives is never declared. A trait with methods is declared, or derived when its header names it.

| Trait | Method a type writes | Without writing it |
|---|---|---|
| `Copy`, `Clone`, `Owned`, `Moves`, `Shares` | none, ever | facts of the type's parts (CORE §9, SPEC §18) |
| `Eq` | `fun eq(?@, other: ?Self) -> Bool` | derived from the parts, as `==` is today |
| `Hash: Eq` | `sub hash_into(?@, h: !hash.Hasher)` | derived from the parts, but only when `Eq` is derived too |
| `Ord: Eq` | `fun order(?@, other: ?Self) -> Order` | numbers, plain enums and text; an object only when its header says `: Ord`, then in field order |
| `Print` | `sub print(?@, out: !Printer)` | derived, as §17's table |
| `Iter` | `fun next(!@) -> Item?`, `type Item` | from the shape `for` already accepts |
| `Num`, `Integer: Num`, `Signed: Num` | none (built-in numbers only) | arithmetic; `%`, bits and shifts; negation |

Rules a library author relies on:

1. **Conformance is written on the header to change a capability.** `obj Name: Eq + Hash` with the two
   methods. A method merely named `eq` or `hash` stays an ordinary method, as it is today (three tests
   have such methods, and `==` ignores them). This removes SPEC §5's trap, where a type's own `hash`
   is called concretely and the built-in one is called in `hash.Map`.
2. **Naming a built-in trait without its method derives it.** `obj Version: Ord` with no `order` gets
   field-order lexicographic ordering. Ord is the only one that needs this, since field order is a
   choice. Eq, Hash and Print stay derived without being named, as today.
3. **A declared `Eq` turns off the derived `Hash`.** A type with its own `==` and the derived hash is the
   classic broken Map key. It is rejected at `Map[Name, V]`: "`Name` declares its own `==`, so it needs
   its own `hash_into`".
4. **The user hash feeds a hasher. It does not return a U64.** `hash_into` names which parts count, and
   std's hasher mixes them. Users never XOR U64s together. `x.hash()` stays the built-in U64 and calls
   `hash_into` for a user type. (Swift's `hash(into:)`; Rust's `Hash`/`Hasher`.)
5. **`Order` is a built-in enum** (`less`, `equal`, `greater`) with `then`. `bigint.compare` moves to it.
   Whether BigInt then conforms to `Ord` (and gets `<`) is its owner's call, since STD says it has no `<`
   on purpose. Default: it does not, in this work.

**Print and formatting.** `print`, `warn`, `panic`, `String(...)` and `!t.add(...)` all use `Print`.
A user `print` gets a `Printer`, not a String, so `print` keeps writing to stdout's buffer and allocates
nothing. `!out.text(...)` writes text as it is. `!out.value(x)` writes a value in the nested form: text
quoted, the 64-level limit applied. One trait is enough because Rig has one printed form, where only
nesting decides the quoting. That is a Printer state, not a second trait like Rust's Debug and
Display. No format mini-language: widths and radix come from printable wrappers that bounds now allow
(`text.pad[T: Print]`, `text.hex[T: Integer]`).

**std bounds** (all `pub`):

| Declaration | Bound |
|---|---|
| `hash.Map[K: Hash, V]`, `hash.Set[K: Hash]` | on the header, **implied** wherever the type is named, so `Items`, `Keys`, `Values` and `Members` (which hold `?Map[K, V]`) need not repeat it |
| `sort.sort`, `lower_bound`, `search` | `T: Ord`; `sort_by` unbounded; add `sort_by_key[T, K: Ord](xs, key: ?fun(?T) -> K)` |
| `slices.contains`, `index_of` | `T: Eq` |
| `math.min`, `max`, `clamp` / `math.abs` | `T: Ord` / `T: Signed + Ord` |
| `par.map`, `par.each`, `task.all` | later: `Shares`/`Moves` let them become ordinary signatures instead of checker special cases |
| `Item`, `Entry`, `shuffle`, `reverse`, `within`, `sort_by` and helpers | none |

## Q2. What real programs gain

**1. A Map keyed by a user type with its own hash.** Today `Map[Name, V]` is rejected once `Name`
declares `hash`, so a case-blind key becomes a lowered String copy at every lookup.

```rig
obj Name: Eq + Hash                       # after
  text: String
  fun eq(?@, other: ?Name) -> Bool
    text.same_fold(?@text, ?other.text)
  sub hash_into(?@, h: !hash.Hasher)
    for b in ?@text
      !h.add(text.to_lower(b))

seen = hash.Map[Name, Int]()              # finds "Ada" from "ADA", no copy
```

**2. Sort by a user order.** Today it is a hand-written `sort_by` closure, and `search`, `max` and
`lower_bound` are unusable on the type.

```rig
# before
sort.sort_by(!vs, |a, b| a.major < b.major or (a.major == b.major and a.minor < b.minor))
# after
obj Version: Ord                           # field order: major, minor, patch
  major: Int
  minor: Int
  patch: Int
sort.sort(!vs)
i = sort.search(?vs, want)
newest = math.max(a, b)
sort.sort_by_key(!players, |p| p.score)   # the common case, no `<` closure
```

**3. A generic container that prints its elements its own way.**

```rig
obj Money: Print
  cents: Int
  sub print(?@, out: !Printer)
    !out.text("$", @cents / 100, ".", text.pad(@cents % 100, 2, "0"))

obj Grid[T]: Print where T: Print
  w: Int
  cells: List[T]
  sub print(?@, out: !Printer)
    for x, i in ?@cells
      !out.text("\n") if i > 0 and i % @w == 0
      !out.value(?x)
      !out.text(" ")

print(prices)                 # before: [Money(cents: 150)]; after: [$1.50, $3.00]
```

**4. One function for every iterator.** Today `for` walks any `next(!@)` type, but no generic body
can call `next`, so std cannot offer `count` or `sum` over `text.lines` or `m.keys()`.

```rig
pub fun count[I: Iter](it: !I) -> Int
  n = 0
  for _ in !it
    n += 1
  n

pub fun sum[I: Iter](it: !I) -> I.Item where I.Item: Num
  ...
print(iter.count(text.lines(src)), iter.sum(squares(10)))
```

`collect` is harder. An item from `next(!@)` lasts one step (STD §hash), so collecting needs
`I.Item: Owned` or a clone. The ownership panel settles that.

**5. A plugin list of different types.** Today it is a closed enum with a `match` in every method, or
an object of `*fun` fields.

```rig
trait Plugin
  fun name(?@) -> ?String from @
  sub run(!@, req: ?Request)

plugins: List[^Dyn[Plugin]] = List()
!plugins.push(^Logger(...))
!plugins.push(^Metrics(...))
for p in !plugins
  !p.run(?req)
```

## Q3. Migration

**Census method.** For each declaration with a type parameter, the script reads its body by indentation,
finds the names typed with the parameter (parameters, fields, `for` and `as` bindings), and looks for
ordering, `==`/`!=` (not against `none`), `.hash()`, printing and text building, arithmetic, and `+x`
on them. It misses copies and needs that come from calling another generic, and it counts some
arithmetic on fields that are not a `T`. Checked by hand on std and examples: it found 9 of 11 and 4
of 6. So read the test numbers as a floor, about 1.5x low.

| | std | examples | test/rig, hand-written | test/rig, generated depth grid (probes-08) |
|---|---|---|---|---|
| declarations with a type parameter | 25 (20 pub) | 14 (0 pub) | 2,128 (595 pub) | 1,600 |
| need bounds if every operation must be named (panel 1 types, phase 2) | 11 | 6 (Tree, place, find, show, max; Ring for Copy) | ≥218 found; about 300–500 | 0 |
| need bounds under ownership C / backend phase 1 (unbounded keeps per-instance checking) | 0 required; 11 adopted by choice | 0 | 0 | 0 |
| need bounds if only `pub` generics must state them (recommended) | 11 | 0 | ≥19 found; about 30–60 | 0 |

Operations found in test/rig: ordering 97, `==` 50, arithmetic 40, printing 28, clone 4, hash 3. On top
of the declarations, a full phase 2 rewrites 81 test assertions of "`cannot use `T = …``", 7 SPEC error
blocks and 2 STD error blocks. (The 2 STD ones change in phase 1 anyway, once std adopts bounds.) The
prose about per-instance checking in DESIGN, SPEC §3 and §16, FAQ and WELCOME is rewritten under any
option.

**Is phase 2 worth it?** Not in full. The case for bounds is DESIGN's own: "the recorded requirements
are an unwritten contract". That contract crosses a *module* boundary. Inside one module the author
sees every instance and every error at once, and requiring `T: Print` on a private helper that prints
while debugging is churn with no reader to serve. So:

- **Phase 1** (as panel 1 types proposes): traits land. A method call on `T` needs a bound. std adopts
  the bounds above. Nothing else breaks.
- **Phase 2, narrowed**: a `pub` generic must state what it does with each type parameter. The error
  carries a fix-it, and `rig fix` applies it. That is 11 std declarations, no examples, and a few dozen
  tests.
- **Private generics keep per-instance checking for good.** The line between the two models is a word
  the reader already sees, `pub`. A parameter that has any bound is held to its bounds alone (panel 1
  ownership's rule C), so a bound is never a partial promise.
- The literal-range check (`x * 300` with `T = U8`) stays the one per-instance check everywhere.

## Q4. Where panel 1 disagrees

1. **Conformance site. Pick the header, with `impl` only for retroactive conformance.** `obj Square:
   Shape` reads as `[T: Shape]` does ("is a"). One header tells a user everything the type is. Methods
   stay ordinary methods, in the body or beside it (SPEC §3). Conditional conformance fits the same
   place (`obj Grid[T]: Print where T: Print`). `impl Shape for geo.Circle` is kept for the case that
   really differs, adding to someone else's type, and is allowed only in the trait's module. The
   backend's `obj Circle impl Shape` spends the reserved word where a colon reads better. The ownership
   report's `impl` blocks for every type split a type's methods across blocks.
2. **Marker names. Pick `Copy`, `Clone`, `Owned`, `Moves`, `Shares`.** `Owned` is needed: storing a
   `T` in a Cell, Signal, owned closure or actor needs "holds no loan", and panel 1 types has no name
   for it. `Moves` over `Move` because every owner moves inside its task, so `[T: Move]` would wrongly
   suggest that other `T`s do not. "When `T` moves" is SPEC §18's own phrase for crossing. `Copy` and
   `Clone` are not overloaded, so they keep the familiar names.
3. **Trait objects. Pick `Dyn[Plugin]`.** It needs no new keyword. Brackets already mean "a compile-time
   argument" (FAQ), and the argument here is a trait. It joins `List`, `Cell` and `Simd` as a built-in
   type. Bounds group without parentheses: `^Dyn[Job + Moves]`, where Rust needs `&(dyn A + B)`. A bare
   `^Plugin` (panel 1 ownership) reads as a concrete type, and the erasure is the cost a reader must
   see. A `Dyn` by value is rejected, since its size is unknown. It sits behind `?`, `!`, `^` or `*`.
4. **Capitalization. Adopt it as a rule**: a type parameter starts with a capital letter, a value
   parameter with a lowercase one. In the repo, 3,831 type parameters are capitalized. The 25 that are
   not are name-grid tests that probe names like `type` and `none`. 213 value parameters are lowercase,
   and the 2 that are not sit in one reject test. std and examples change nothing. The rule makes both
   mistakes diagnosable: `[T: Int]` gets "a bound must be a trait; a value parameter is lowercase", and
   `[n: Ord]` gets the reverse. Resolution still goes by what the name after `:` denotes (ROADMAP); the
   rule is for readers.

## Recommended defaults

1. std defines `Eq`, `Hash: Eq`, `Ord: Eq`, `Print`, `Iter` (associated `Item`), `Num`, `Integer`,
   `Signed`, and the derived markers `Copy`, `Clone`, `Owned`, `Moves`, `Shares`, plus a built-in
   `Order` enum.
2. Capabilities change only through the header (`obj Name: Eq + Hash`). A header naming `Ord` with no
   `order` derives field order. A declared `Eq` turns off the derived `Hash`.
3. `Hash` takes `hash_into(?@, h: !Hasher)`. `Print` takes `print(?@, out: !Printer)` with `text` and
   `value`. There is no format mini-language.
4. std bounds: `Map[K: Hash, V]`, `Set[K: Hash]` (implied where named), `sort`/`search`/`lower_bound`
   `T: Ord`, `contains`/`index_of` `T: Eq`, `min`/`max`/`clamp` `T: Ord`, `abs` `T: Signed + Ord`. Add
   `sort_by_key`, and `iter.count`/`sum`.
5. Migration: phase 1 as panel 1 types proposes. Phase 2 only for `pub` generics, mechanized. Private
   generics keep per-instance checking.
6. Conformance on the header. `impl Tr for X` only in the trait's module.
7. `Moves`/`Shares`, plus `Owned`. `Dyn[Tr]` behind a sigil. Capitalization becomes a rule.
