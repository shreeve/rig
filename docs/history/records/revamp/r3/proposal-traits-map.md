# OWNER DECISIONS (2026-10-13, via the Trig session) — these override the text below

1. **One keyword, `trait`.** Methods may later carry default bodies a conforming type keeps or overrides (v1 may ship without; adding later breaks nothing). No `mixin` (word held in reserve).
2. **Conformance is a colon:** `obj Circle: Shape`, `obj Point: Show and Hash`, likewise `enum`; a generic type `obj Sorted[T: Ordered]: Show and Hash`. It reads as the bound `fun f[T: Show and Hash](x: ?T)` and as `x: Int`: the colon means "is a". Not `is`; `isa`, `uses`, `impl` rejected.
3. **Several traits join with `and`, everywhere** (option B), never commas.
4. **Hashing is `x.hash()`**, not `@hash(x)`: a built-in method on exactly the types `==` compares (not Float), as `x.to_bits()` is; semantics as §6. In R2 the `Hash` bound means "has `.hash()`". Every `@hash` below reads `.hash()`.
5. Mantra (PR #175): every Rig `@` builtin is a compile-time question about a type; work on a value is a method or function.

# Proposal: traits, then generic Map and Set (Trig NEEDS 2)

For the design owner. Status: proposal; no code changed. Evidence:
`.git/revamp/r3/traits-map-probes/` (each probe ran on `main` 34ffed549,
`RIG_SANITIZE=1`, through `cpuq run --cores 2`).

## 0. The recommendation

1. Map and Set need no traits: a builtin `@hash(x)`, defined where `==`
   is (less `Float`), and `std.hash` written in Rig, first (R1).
2. Traits are nominal (`trait Shape`, `obj Circle is Shape`): a body's
   ownership is checked once, which needs the method's signature.
3. Static bounds `[S: Shape]` next (R2); trait values `?Shape`,
   `^Shape`, `*Shape` (the existing sigils, no `dyn`) last (R3).
4. CORE gains one trait paragraph, one lend-table row, and one paragraph
   showing Map follows from sentences 1, 4, and 7.

## 1. The problem, with evidence

- SPEC "Generic bodies": "A body cannot call a method on a `T`".
  `src/typecheck.zig:8842` rejects `k.hash()` in the body, before any
  instance exists. Trig hand-wrote a `Text`-keyed map (`05-rig-prototype.md`).
- ts-rust (`02-rust-census.md`): 120 traits; `dyn` by trait: Fn/FnMut
  527 (closures: NEEDS 5, not here), `Fs` 192, `AnyValue` 116, `Any` 67,
  `System` 56, `Project` 47. "User traits are Go interfaces … 5 are in
  the checker. Generics are light. The main bound is `ChildVisitor`."
  Derives `PartialEq` 1,233, `Eq` 997, `Hash` 763; `HashMap` 1,305,
  `HashSet` 659, `IndexMap`/`IndexSet` 599 (TS relies on order).
- So Trig needs structural hashing and equality, static bounds for
  visitors, and dynamic dispatch for a few host interfaces. Downcasts
  (`Any`, `AnyValue`) become enums; out of scope.

## 2. What works today (measured)

| Probe | Result |
|---|---|
| `p1` generic `k.hash()`; `p2` passing `k: K` to `hash_int(Int)` | rejected in the body ("`K` has no methods"; "expected `Int`, got `K`") |
| `p3`, `p8` generic `==` on `?String`, `String`, structs holding one; `p9` a field `f: fun(?K) -> U64` called generically | work |
| `p4b`, `map_today.rig` a full generic, insertion-ordered Map (put, replace, get `from self`, edit, take, items, rehash, `String`/`?String`/`Int` keys) with a function-valued hash | **runs, sanitizer-clean**; 100 lines of Rig |
| `p13` generic `?xs[i]` where `(?T)?` is expected, and `<xs[i]` of a `T?` element | works for an owning `T` |
| `p10` generic `if ?o as x` over an owning `T` | rejected per instance ("moves out of a view"); avoidable as in `p13` |
| `p17` `get(?self, k: ?K) -> (?V)? from self` | the key's temporary ends at once; `r = ?m.get(?k)` keeps only `m` lent |
| `p5`, `p6` dispatch through `*fun` fields | plain data only: an owned closure cannot return a `String` |
| assigning `self.vals[j] = <v` over an owning generic element | rejected per instance (`no_cleanup`); `push`+`swap`+`pop` works |

**So a per-instance `k.hash()` does not already work.** Zig would accept
it (it duck-types); Rig cannot, because the body's single ownership
check must know whether `k.hash()` lends `k` to read or write or takes
it, what its result views (`from`), whether it fails, and whether it
stores an argument. That decides question 1.

**Three bugs found** (each gets a failing test and its own fix):

- **B1, accept-means-correct:** generic `a == k` with `a: ?K?`, `k: ?K`
  is accepted, and at `K = String` the emitted Zig fails to compile
  (`runtime.zig:236`). The concrete `String? == ?String` is rejected,
  though SPEC §5 implies it compares. `bug1*.rig`.
- **B2, contradictory hints:** `for x in b.each()` (iterator viewing
  `b`) says "write `?b.each()`"; that then says "write `!b.each()`",
  which lends `b` to write. The loop reads `?b.each()` as `?it`; by the
  receiver-sigil rule it is a made value. `bug2_for_hint.rig`.
- **B3, over-rejection:** `show(s)` of a `List[^Circle]` loop view, for
  `show(c: ?Circle)`, is rejected; `show(?s)` works. `p20_analog_dyn.rig`.

## 3. Question 1: do we need nominal traits?

| Option | Verdict |
|---|---|
| **N0** Zig model: per-instance method requirements, nothing declared | **No.** Ownership is checked once per body; without the method's signature it cannot be. Checking it per instance moves ownership errors into library bodies at importers' instances and multiplies check time (Trig: ~600K lines). |
| **N1** structural traits (Go): signatures declared, conformance implicit | Accidental conformance, errors at use sites, and a renamed method silently leaves a trait. |
| **N2** nominal traits: a type says `is Tr` | **Recommended.** Errors at the declaration; one conformance per (type, trait), so no coherence or orphan rules. |

**Static or dynamic?** Both. Static is a per-instance call of the
conformer's method. Dynamic (different types behind one interface, in
fields and Lists) is needed for Trig's hosts, and is the only part that
touches ownership classification, so it is its own round (R3). A trait
value is the existing sigil over a trait name, with no `dyn`:

| Type | Kind (CORE §1) | Made from | Drop |
|---|---|---|---|
| `?Tr`, `!Tr` | view | `?x`, `!x` where `x: C`, `C is Tr` | none |
| `^Tr` | owning | a `^C` (`^C(...)`, `^<x`) where `^Tr` is expected | the vtable's `drop`: `C`'s drop glue, then free |
| `*Tr`, `~Tr` | handle | a `*C` / `~C` where expected | count in the shared header; the last release calls the vtable's `release` |
| bare `Tr` | no type | | |

Two rules close what erasure opens. **Owned trait values are no-loan
homes** (as `Cell` and `*fun`, sentence 9): otherwise `^Tr`'s "may hold
a loan" fact is "maybe", barring it from Cells and widening every
result's origins; a conformer holding a view is lent as `?Tr` instead.
**`^Tr` has no `+`:** sentence 2 gives `+` "as the type says", and the
type is not known. `*Tr` has `+` (a count).

## 4. Question 2: syntax

Rules applied: brackets are compile time, parentheses run time; a
sigil shows ownership; words over symbols (`and`, `or`, `not`).

| | **S-A (recommended)** | S-B (Rust-like) | S-C (Go-like) |
|---|---|---|---|
| declare | `trait Shape` + body-less `fun`/`sub` lines | same | same |
| conform | `obj Circle is Shape` (contextual `is`, as `unique` is) | `impl Shape for Circle` block | implicit |
| bound | `fun f[S: Shape](x: ?S)` (ROADMAP keeps `[T: Trait]` free; told from a value parameter by what `Shape` denotes) | `fun f[S](x: ?S) where S: Shape` | `[S: Shape]` |
| several | `[T: Show and Hash]`, `obj P is Show and Hash` | `S: Show + Hash` | interface embedding |
| value | `?Shape`, `^Shape`, `*Shape` | `?dyn Shape`, `^dyn Shape` | `Shape` |
| verdict | one contextual word, every other form reused; a trait name under a sigil is unambiguous (no `impl Trait` argument form) | spends `impl` and `where`, splits methods from the type, `dyn` repeats what the sigil says | nowhere to report a missing method |

Examples: §9's pending blocks (`total[S: Shape]` static, `show(s: ?Shape)` dynamic).

**v1 traits:** methods take `?self` or `!self` only (no `<self`,
associated functions, or compile-time parameters), so every trait works
both ways; `Self` stands only as the receiver; type parameters follow
the bracket rule (`trait Source[T]`, `obj Lines is Source[?String]`,
`[S: Source[Int]]`, `^Source[Int]`); no default bodies, supertraits, or
conditional conformance (`obj Wrap[T: Show] is Show` bounds the type).

**Conformance:** `is` stands only on an `obj` or `enum` declaration, so
built-in types conform to no user trait (methods outside the body,
NEEDS 1, may later carry `is` in the declaring module). Each trait
method needs a method of its name with exactly its signature, `Self`
replaced: receiver, parameters, result, `from`, fallibility,
`fun`/`sub`. A method meeting a `pub` trait is `pub`. Traits joined by
`and` may share a method name only with the same signature.

## 5. Question 3: Map and Set

Options: **M1** built into the runtime like `List` (against "libraries
in userland"); **M2, recommended:** std Rig over `List` with `@hash`,
~200 lines, no CORE rule, no traits; **M3** std Rig with a
function-valued hash (works today; a fn pointer per map, a hash named at
every construction, nothing tying it to `==`; Trig's interim); **M4**
wait for a `Hash` trait (couples Map to the largest design).

`use std.hash` gives `hash.Map[K, V]` and `hash.Set[K]` (not prelude
names: 692 test files declare their own `obj Set` or `obj Map`).
Iteration is in insertion order, as in Python, Ruby, and JS: `put` on a
present key keeps its place, and `take` keeps the rest in order (its
slot becomes `none`, compacted on growth). Output is deterministic, and
it covers `IndexMap` (599 uses).

| Member | Signature | Ownership |
|---|---|---|
| `hash.Map[K, V].new()` | `fun new() -> Map[K, V]` | |
| `m.len()` | `fun len(?self) -> Int` | a method: a Rig type has no read-only field |
| `m.has(k)` | `fun has(?self, k: ?K) -> Bool` | reads |
| `m.get(k)` | `fun get(?self, k: ?K) -> (?V)? from self` | the view keeps `m` lent to read, not `k` |
| `(!m).edit(k)` | `fun edit(!self, k: ?K) -> (!V)? from self` | keeps `m` lent to write |
| `!m.put(k, v)` | `sub put(!self, k: K, v: V)` | takes `k` and `v`; an old value is dropped; an existing key stays and `k` is dropped |
| `(!m).replace(k, v)` | `fun replace(!self, k: K, v: V) -> V?` | as `put`, handing the old value back (the builtin `replace`'s meaning) |
| `(!m).take(k)` | `fun take(!self, k: ?K) -> V?` | the value back, owned; the key dropped |
| `!m.clear()` | `sub clear(!self)` | drops every entry |
| `?m.items()`, `?m.keys()`, `?m.values()` | `fun items(?self) -> Items[K, V] from self` | an iterator; each `Item[?K, ?V]` (`e.key`, `e.value`), `?K`, or `?V` views `m` |
| `!m.update(f)` | `sub update(!self, f: ?sub(?K, !V))` | writes each value in place; keys stay read-only |

`Set[K]`: `new`, `len`, `has(k: ?K)`, `(!s).add(k: K) -> Bool` (true
when new), `(!s).take(k: ?K) -> K?`, `clear`, `?s.items()` giving `?K`.

`put` returns nothing because a statement discarding an owning result
is rejected (measured), which would force `_ = (!m).put(k, v)`. Keys go
out only as `?K`, and a `?String` key's text stays lent (sentence 6), so
no key changes under the map; changing it while iterating is rejected by
the loan `items` keeps. Text hashes and compares by bytes, so
`Map[String, V]` finds `m.get("x")` and `m.get(?t)` (`?K` is `?String`),
and `Map[?String, V]` holds views (a view of a view is that view).

## 6. Question 4: hashing and equality

Recommended: **built in, structural, following `==`.** `@hash(x) -> U64`
is a builtin beside `@size` and `@name`, defined on exactly the types
`==` compares (SPEC §5), by the same parts, less `Float` and what holds
one (NaN, and `0.0 == -0.0`). Values `==` calls equal hash equal; text
hashes its bytes whatever its type. In a generic body it records a
`hashable` requirement, checked per instance like `equatable`. Fixed
seed, so deterministic. No user-written hash in v1 (Go has none); a
custom key is a struct of the fields that matter.

In R2, `Eq`, `Order`, and `Hash` become **built-in bounds** naming those
requirements (`fun max[T: Order](a: T, b: T)`, `obj Map[K: Hash, V]`),
met by a type's parts, never by `is`, and hideable by a declaration as
`print` is, so no existing program breaks. They are not trait values.

Rejected: derived impls (`obj P is Hash`): a declaration nobody
customizes in the census, inviting a `hash` that disagrees with `==`.

## 7. Semantics and desugaring

**Map and Set** need none: std code, walked as any module's. `@hash(x)`
reads `x` (an unwritten read lend, as `print`'s) and returns a `U64`.

**Static dispatch.** With `[T: Tr]`, `x.m(a)` on a `T` is checked once
against `Tr.m`'s signature (`Self = T`); at `T = C` it is `C.m(x, a)`,
whose signature is the same with `Self = C` and whose body was checked
against it at `obj C is Tr`. Sentence 7 alone covers every instance;
operator requirements stay per instance. Emit writes `x.m(a)` as now.

**Trait values** are an enum, over the program's types that are `Tr`,
of each type under the value's sigil (Rig compiles whole programs, so
the set is closed):

```rig fragment
enum ShapeView            # ?Shape; ^Shape is ShapeBox with ^C payloads,
  circle(v: ?Circle)      # *Shape and ~Shape *C and ~C, and !Shape !C,
  square(v: ?Square)      # held as `(!T)?` is: never stored (CORE §5)

show(?sq)                 # is  show(ShapeView.square(?sq))
s.area()                  # is  match s
                          #       .circle(v) => v.area()
                          #       .square(v) => v.area()
```

Every arm has `Tr.m`'s signature, so the `match` passes on what it
shows, and every rule follows from enums: kind from the parts (§1),
lends of `^Shape`/`*Shape` from their rows (§4), the drop the enum's.
§3's rules are this enum's: owned payloads hold no view, and the enum is
`unique` (its `+` would depend on every conformer in the program).

**Emit** writes the enum as a data pointer and a vtable pointer (each
payload is one pointer; the vtable is the tag) and the `match` as one
indirect call: same calls, order, and drops, no temporary. Each (type,
trait) pair gets a `comptime` table: methods, `drop` (`^`), `release`
(`*`); counts stay in the shared header. `print` prints the held value,
as for `^T`; `==` and `@hash` are rejected (view payloads have no `==`).
The conversion is one recorded fact (`handsOver` gains no category),
and each call records `dispatch: static | table` for emit (`facts.zig`).

## 8. The CORE wording

Added to §1, after the `^T` paragraph:

> **A trait names methods by their signatures, and a type that says `is
> Tr` has each of them with exactly that signature.** A call through a
> trait, on a type parameter bounded by it (`[T: Tr]`) or on a trait
> value, is checked against the trait's signature, as every call is
> checked against its callee's (sentence 7), so it passes on only the
> loans that signature shows. A trait value holds a value of some type
> that is `Tr`, behind the sigil that says how: `?Tr` and `!Tr` are
> views, `^Tr` an owner, and `*Tr` and `~Tr` handles, each lent, moved,
> counted, and dropped as that sigil is over the value it holds, whose
> own drop runs when it goes; a bare `Tr` is no type. What `^Tr`, `*Tr`,
> or `~Tr` holds holds no view, as a `Cell` holds none (sentence 9), and
> a `^Tr` has no `+`, since its value's type is not known (sentence 2).
> *(planned)*

Added to the §4 lend table:

> | a `C` that is `Tr`, where a `Tr` view is expected | `?Tr` | `!Tr` | planned |

Added to the end of §5:

> **A container written in Rig follows its signatures.** `hash.Map[K,
> V]` and `hash.Set[K]` are std code with no rule of their own: `!m.put(k,
> v)` takes `k` and `v` as any owning parameter does; `m.get(k)` returns
> a `(?V)?` view `from self`, which keeps `m` lent and not `k` (sentence
> 7); `(!m).edit(k)` returns a `(!V)?` that keeps `m` lent to write; and
> `(!m).take(k)` hands the value back owned and drops the key. *(planned)*

## 9. The failing tests

**Pending doc examples** (land now; each fails today on `use std.hash`,
`@hash`, `trait`, or `is`).

docs/STD.md, `std.hash` (R1):

```rig pending
use std.hash

sub main()
  ages = hash.Map[String, Int].new()
  !ages.put(String("ada"), 36)
  !ages.put(String("bob"), 41)
  !ages.put(String("ada"), 37)
  print(ages.len(), ages.get("ada"), ages.get("cy"))
  if (!ages).edit("bob") as a
    a += 1
  print((!ages).take("bob"), ages.has("bob"))
  name = String("cy")
  !ages.put(<name, 5)
  for e in ?ages.items()
    print(e.key, e.value)
  seen = hash.Set[?String].new()
  for w in ["b", "a", "b"]
    if (!seen).add(w)
      print("new", w)
  print(seen.len(), seen.has("a"))
```

```output
2 37 none
42 false
ada 37
cy 5
new b
new a
2 true
```

(The Map lines ran today, `map_today.rig`, with a function-valued hash and,
until B2 is fixed, the iterator bound first: `it = ?ages.items()`.)

SPEC §5 Builtins (R1):

```rig pending
obj P
  x: Int
  name: String

sub main()
  a = P(x: 1, name: String("q"))
  b = P(x: 1, name: String("q"))
  t = String("q")
  print(a == b, @hash(a) == @hash(b), @hash(t) == @hash("q"))
```

```output
true true true
```

SPEC, new section "Traits" (R2):

```rig pending
trait Shape
  fun area(?self) -> Float
  sub grow(!self, by: Float)

obj Circle is Shape
  r: Float

  fun area(?self) -> Float
    3.0 * self.r * self.r

  sub grow(!self, by: Float)
    self.r += by

fun total[S: Shape](xs: ?List[S]) -> Float
  sum = 0.0
  for x in xs
    sum += x.area()
  sum

sub main()
  cs: List[Circle] = List()
  !cs.push(Circle(r: 1.0))
  !cs.push(Circle(r: 2.0))
  for c in !cs
    !c.grow(1.0)
  print(total(?cs))
```

```output
39.0
```

docs/CORE.md §1, under the new paragraph (R3):

```rig pending
trait Shape
  fun area(?self) -> Float

obj Circle is Shape
  r: Float

  fun area(?self) -> Float
    3.0 * self.r * self.r

obj Square is Shape
  s: Float

  fun area(?self) -> Float
    self.s * self.s

  drop(!self)
    print("drop", self.s)

sub show(s: ?Shape)
  print(s.area())

sub main()
  shapes: List[^Shape] = List()
  !shapes.push(^Circle(r: 1.0))
  !shapes.push(^Square(s: 2.0))
  for s in shapes
    show(?s)
  sq = Square(s: 3.0)
  show(?sq)
  <sq
  shared: *Shape = *Circle(r: 2.0)
  other = +shared
  print(other.area())
```

```output
3.0
4.0
9.0
drop 3.0
12.0
drop 2.0
```

**Reject tests** (land with their round; each fails today on its
message). Shared header for R2/R3 files: the `trait Shape` with `fun
area(?self) -> Float` above.

| File | Body (after the header) | `# error:` |
|---|---|---|
| `test/reject/types/trait_bound_unmet.rig` (R2) | `obj Rock` / `w: Float`; `fun total[S: Shape](x: ?S) -> Float` / `x.area()`; `print(total(?Rock(w: 1.0)))` | `` `total[Rock]` cannot use `S = Rock`: `Rock` is not `Shape` `` |
| `…/trait_method_missing.rig` (R2) | `obj Blob is Shape` / `n: Int` | `` `Blob` is `Shape` but has no method `area` `` |
| `…/trait_signature_mismatch.rig` (R2) | `obj Blob is Shape` with `fun area(!self) -> Float` | `` `Blob.area` takes `!self`, but `Shape.area` takes `?self` `` |
| `…/trait_consuming_method.rig` (R2) | `trait Eat` / `sub eat(<self)` | `` a trait's method takes `?self` or `!self` `` |
| `…/trait_self_outside_receiver.rig` (R2) | `trait Same` / `fun same(?self, o: ?Self) -> Bool` | `` `Self` stands in a trait only as the receiver `` |
| `…/generic_method_without_bound.rig` (R2, replaces today's text) | `fun h[K](k: ?K) -> U64` / `k.hash()` | `` `K` has no methods: bound it with a trait that declares `hash`, `[K: …]` `` |
| `…/trait_bare_type.rig` (R3) | `sub f(s: Shape)` / `print(1)` | `` `Shape` is a trait, so it is held as `^Shape` or `*Shape`, or lent as `?Shape` `` |
| `test/reject/ownership/trait_box_holds_view.rig` (R3) | `obj Named is Shape` with `name: ?String` and `area`; `t = String("x")`; `b: ^Shape = ^Named(name: ?t)` | `` what a `^Shape` holds holds no view; lend it as `?Shape` `` |
| `…/trait_box_clone.rig` (R3) | `b: ^Shape = ^Circle(r: 1.0)`; `c = +b` | `` a `^Shape` has no `+`: share it as `*Shape` `` |
| `…/trait_write_view_stored.rig` (R3) | `obj Holder` / `s: !Shape` | `` a write view is never stored inside a value `` |
| `…/trait_view_keeps_lent.rig` (R3) | `c = Circle(r: 1.0)`; `views: List[?Shape] = List()`; `!views.push(?c)`; `c.r = 2.0`; `print(views.len)` | `` cannot assign to `c.r` while `c` is lent `` |
| `test/reject/std/hash_get_keeps_lent.rig` (R1) | `m = hash.Map[String, Int].new()`; `r = ?m.get("a")`; `!m.put(String("b"), 1)`; `print(r)` | `` cannot lend `m` to write while a read loan is live `` |
| `test/reject/std/hash_items_then_put.rig` (R1) | `for e in ?m.items()` / `!m.put(String("c"), 2)` | `` cannot lend `m` to write while a read loan is live `` |
| `test/reject/std/hash_key_no_eq.rig` (R1) | `hash.Map[List[Int], Int].new()` | `` cannot use `K = List[Int]` `` |
| `test/reject/types/hash_float.rig` (R1) | `print(@hash(1.5))`; `m = hash.Map[Float, Int].new()` | `` `@hash` does not take a `Float` ``; `` cannot use `K = Float`: the generic body hashes a `K` with `@hash`, which `Float` does not support `` |

**Bug tests** (R0, from §2): `test/behavior/types/generic_eq_optional_view.rig`
(`bug1_eq_opt_view.rig` printing `true`, plus the concrete `o == ?t`),
`test/behavior/syntax/for_lent_made_iterator.rig` (`bug2_for_hint.rig`
printing `4`), and `test/behavior/ownership/loop_box_view_argument.rig`
(`show(s)` of a `List[^Circle]` loop view).

## 10. Implementation plan

| Round | Content | Touches | Effort |
|---|---|---|---|
| **R0** hotfixes | B1, B2, B3, each with its failing test | typecheck (`==` at instances), iterator-loop classification (B2 is a classifier: alone) | 1–2 days each |
| **R1a** `@hash` | builtin in typecheck beside `@size`; `hashable` requirement (`equatable` less `Float`); `rig.hash(T, v)` in `src/runtime.zig` (Wyhash over bytes for text, a mix for integers, field by field); SPEC §5 | typecheck, runtime, emit; no ownership change | 2–3 days |
| **R1b** `std.hash` | `std/hash.rig` (Map, Set, Items, Keys, Values, Item); STD.md; the R1 pending and reject tests; a `bench/` micro-benchmark against Zig's `std.HashMap` | std only | 2–3 days |
| **R2** static traits | grammar: `trait` declarations of body-less signatures, contextual `is` after an `obj`/`enum` name, `and` in a bound (Nexus re-sync of `rig.grammar`); resolve: trait symbols, conformance check; typecheck: method lookup on a bounded `type_var` through the trait, bounds checked at instances, built-in bounds `Eq`/`Order`/`Hash`; ownership: none new (a call with a signature); emit; oracle learns bounded calls; SPEC "Traits", SYNTAX, DESIGN, FAQ, README, ROADMAP; `std.hash` gains `[K: Hash]` | grammar, resolve, typecheck, emit, docs | 1.5–2 weeks |
| **R3** trait values | type kinds `?Tr`…`~Tr`; the conversion fact; lend-table row; no-loan and no-`+` rules; vtables, `drop`/`release`, shared-header counts in the runtime; `print`; CORE paragraph built; oracle | ownership classification (alone, full matrix), facts, emit, runtime | 2–3 weeks |

Order: R0 and R1 now (Trig's maps; independent of traits). R2 when
Trig ports visitors. R3 when Trig reaches the host layer (native CLI,
LS); its design is fixed now so R2's syntax leaves room for it.
Trig's interim until R1 lands: `map_today.rig`'s function-valued hash.

## 11. Risks

- **R3 is a soundness round:** alone, full matrix, and AGENTS's stop
  rule after a second soundness round. The enum desugaring keeps it to
  existing rules.
- **Strict conformance:** `-> Static` does not meet `-> ?String`; the
  cost of a one-line soundness argument.
- **No-loan owned trait values** bar boxing a conformer that holds a
  view (Trig's hosts own their data; others may not).
- **Code size:** per-type instances and per-(type, trait) vtables;
  Trig's build size is unmeasured (NEEDS "Scale").
- **Fixed-seed `@hash`** is open to collision flooding; a per-map seed
  can come later without changing output (order is by insertion).
- **Warts left:** `m.len()` beside `v.len`; `for e in ?m.items()` needs
  its `?` (sentence 4: the loop's hidden binding keeps the lend); generic
  element assignment needs `no_cleanup`, so std uses `push`/`swap`/`pop`;
  `use std.hash` binds the name `hash`; built-in bounds are structural
  beside nominal traits.

## 12. Decisions for the owner

1. Split NEEDS 2: R1 (`@hash`, `std.hash`) before and apart from traits.
2. `@hash(x) -> U64` on exactly the types `==` compares, less `Float`;
   text by bytes; fixed seed; no user-written hash in v1.
3. Map and Set in Rig: `use std.hash`, `hash.Map[K, V]`, `hash.Set[K]`,
   insertion-ordered, the §5 API (`put` returns nothing, `replace` and
   `take` hand values back, `get`/`edit` are `from self`, `len()`).
4. Nominal traits (N2): static dispatch in R2, trait values in R3.
5. Spelling S-A: `trait Name`, `obj C is Tr`, `[T: Tr]`, joined by
   `and`; `impl` and `where` stay held.
6. Trait values are the sigils over a trait name, no `dyn`; conversion
   is implicit where the trait type is expected.
7. v1 limits: `?self`/`!self` methods, `Self` only as receiver, type
   parameters allowed; no default bodies, supertraits, conditional
   conformance, or conformance of built-in types.
8. `^Tr`, `*Tr`, `~Tr` are no-loan homes; `^Tr` has no `+`.
9. `Eq`, `Order`, `Hash` as built-in bounds in R2, met by parts,
   hideable.
10. The three CORE additions of §8 land as *(planned)*, with their
    pending examples, in their own reviewed change before R1.
11. R0's three bug fixes land first, each its own round.
