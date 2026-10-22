# Panel A: typed ids into append-only stores, and counters that only count up

Design only. Read: AGENTS.md, docs/CORE.md (§1-2, §5, §10), SPEC (generic
types, §16 compile-time parameters, List, Bounds, Own meanings, module
privacy), src/proofs.zig's header, INTERNALS "Proven checks",
src/runtime.zig (`List.at`, `indexOf`, `atProven`), src/alloc.zig, and
Trig's src/checker/store_generated.rig, constructors.rig, types.rig,
docs/WASM.md, and panel B's measurements (B-proof-ranges.md §0).

## 0. Summary

`store[id]` can lose its check only when three facts hold at the access:
the id was minted by a store, the store has not shrunk since, and **it is
the same store**. Push-only minting and append-only storage give the
first two cheaply. The third is the hard one, because Trig runs several
checkers at once, each with its own `Store`. No rule Rig has today can
tell two `Store` values of the same type apart.

There are two sound ways to get the third fact:

- **Prove it statically** with generative brands, as GhostCell and
  `compact_arena` do (option A). This needs rank-2 scopes and erased
  phantom parameters, both new to Rig. It also spreads a brand parameter
  through every Trig type that holds an id.
- **Make it unnecessary** (option B, recommended). A `Table[T, n]` has
  all n slots from the start, and an id is a `Slot[n]`, a number below n
  that only the standard library can make. Any `Slot[n]` is in range of
  any `Table[_, n]`, so an id from another table is memory-safe: it names
  a slot that exists. The check is gone because nothing remains to check.
  This is how WebAssembly engines drop their memory bounds checks (they
  reserve 4 GiB plus guard pages), and how Zig needs no check to index a
  `[256]T` with a `u8`.

Option B adds no syntax: two library words, `Table` and `Slot`. Option B
changes no ownership rule: a Table is an owner like a List, and a Slot
is plain data. A large `Table` costs only address space, because the OS
supplies zero pages lazily. On wasm32, and wherever the OS cannot reserve
the space, the same meaning falls back to a test.

**Gate:** build nothing until a throwaway Trig build with List index
tests removed (`indexOf` returns `index` unchecked) sets the upper bound.
Panel B found today's 470 proven sites worth 0.5%. Per the rule
"measure share first", only build B if the bound clears the speed bar.

For counters, no compiler rule is needed. `+%=` already exists and is
well defined. A 64-bit counter that adds 1 cannot wrap within centuries.
`Table.push` returns the new `Slot`, so the 35 mint sites
(`TypeId(@store.types.len - 1)`) lose their subtract and narrowing tests.

## 1. The problem, exactly

What Trig does today:

```rig
pub type TypeId = U32                  # 0 is nil; slot 0 of every list is made by Store.new
t = TypeId(@store.types.len - 1)       # mint: a checked subtract, a checked narrowing
@store.literals[Int(@store.types[Int(t)].data)].value   # two tests, one per hop
```

- **Ids are plain `U32`.** They live everywhere: in records inside the
  store (`resolved_base_constraint: TypeId`), in `Map`s, in local
  objects, and as literals (`mapped: TypeId = 0`).
- **`Type.data` is polymorphic.** It indexes `intrinsics`, `literals`,
  `references`, and the rest, depending on `kind`.
- **Paged link tables are sparse tables by id.** The `List[List[XLinks]]`
  tables are paged by `id / 256`, with `_has` and `_ensure` helpers
  (38 page lookups).
- **The element types are plain data.** Every store element is numbers,
  enums, and spans of `U32`, with no List, String, or handle (checked
  across all 60 record objects). `TypeKind` starts at `Intrinsic = 1`.

What the current test catches: an id at or past `len`. An id from
another checker's store is usually *smaller* than this store's `len`,
because ids are dense from 1. So the test today almost never catches
cross-store misuse. It only keeps memory safe. Option B keeps exactly
that property and drops the test.

## 2. Options

### Option A: generative brands (static identity)

**Idea.** The store's identity is a type. `Table[T, B]` and `Id[B]`
carry a brand `B` that is new for each store and exists only at compile
time. An `Id[B]` can index only a `Table[_, B]`. The table has existed
since the id was minted and never shrinks, so the test can go.

**Spelling.** This is the least new syntax that can work, but it is
not zero:

```rig
obj Checker[B: Fresh]                 # Fresh: a built-in bound word, like Moves
  types: Table[Type, B]
  ...
sub check_file(program: ?Program) -> Diagnostics
  Table.scope(|[B] types: !Table[Type, B]| run(types, program))   # rank-2: NEW
```

Static generativity in a language that monomorphizes needs three things.

1. **A scope whose brand is universally quantified.** Rust gets this from
   `for<'id>` closures. Rig has no generic closures, and SPEC §16 says a
   function with compile-time parameters "can only be called, never used
   as a value". A "fresh at each call" type parameter is not enough
   without a scope: `for f in files: c = Checker(...)` gives every
   iteration the same static brand, and pushing them into one List
   mixes them.
2. **One table per brand.** If the scope's body can make a second
   `Table[Type, B]`, the two tables share a brand. This needs a
   consumed key (`Table.make(<key)`), or a scope that makes the one
   table itself. Trig's 35 tables then need 35 nested scopes, or a key
   split by element type, which is typestate.
3. **Erasure.** `B` must never reach Zig. Otherwise every brand
   instantiates the whole checker again.

**CORE fit.** Ownership is untouched: tables are owners, ids are plain
data, and the brand is a type. But the type system gains rank-2 scopes,
erased parameters, and an escape rule (nothing naming `B` leaves the
scope). That fails §10's "one paragraph, no exception list".

**Ids crossing stores.** Rejected at compile time. This is the only
option that also catches cross-checker logic errors.

**Drop, clear, pop, serialize.** The table cannot outlive its scope, and
ids cannot leave it. `pop` or `clear` would break the never-shrinks fact,
so neither is offered. Ids read from data enter by `types.id(n) ->
Id[B]?`, one test at entry.

**Lowering.** `types.slots[id]` through a many-pointer, with no test in
any build. The brand is erased, so the code is identical to an unbranded
build.

**Cost.** Compile time is the type checker's alone. Code size is
unchanged.

**Trig cost.** `Checker[B]`, every one of the ~60 record objects that
holds an id (`Type[B]`, `TypeList[B]`, ...), and every free function or
helper object holding an id gain `[B]`. The generator does most of it,
but the hand-written checker files (inference, relater, ...) change too.
This viral annotation is why GhostCell, `generativity`, `indexing`, and
`compact_arena` stay niche in Rust.

### Option B: a table whose every slot exists (recommended)

**Idea.** Remove the "same store" fact rather than prove it.

- A `Table[T, n]` has `n` slots from the moment it is made. Each holds
  `T()` until written. `len` counts the slots pushed.
- A `Slot[n]` is a number below `n`. Only std makes one, and it can be
  given to any `Table[_, n]`.
- `t[s]` cannot be out of range, whichever table minted `s`.

**Spelling.** Library words only (`Table` and `Slot` are candidate
names; see the decisions). Like `Map`, they are built in, because
indexing is a place and Rig has no user-defined `[]`.

```rig
TYPES = 1 << 26

pub type TypeId = Slot[TYPES]

obj Store
  types: Table[Type, TYPES] = Table()

sub demo()
  s = Store()
  t = !s.types.push(Type(flags: 1))   # a Slot[TYPES]; panics when all n are pushed
  s.types[t].flags = 7                # no test
  nil: TypeId = 0                     # a literal below n is a Slot[n]
  print(s.types[nil].flags)           # 0: slot 0 holds Type() until written
  if Slot[TYPES].of(Int(raw)) as u    # an id from data: one test, at entry
    print(s.types[u].kind)
```

Members:

| Member | Meaning |
|---|---|
| `Table()` | a table of `n` slots, each `T()` |
| `!t.push(x)` | writes slot `len`, adds one to `len`, and returns that slot as a `Slot[n]`; panics when `len == n` |
| `t.len` | the number of slots pushed |
| `t[s]` | a place, as `v[i]` of a List is, with `s: Slot[n]`; no test |
| `t[i]` | with `i: Int`, tested `0 <= i < n` (not `len`) |
| `for x in t` | the pushed slots, `0..len` |
| `Slot[n].of(i)` | `Slot[n]?`: some when `0 <= i < n` |
| `Int(s)` | the number |
| literal `k` | a `Slot[n]` where `0 <= k < n` is checked at compile time ("a literal takes the numeric type its context expects, and must fit it") |

`Slot[n]` provides `Copy`, `Eq`, `Hash`, `Ord`, and `Print` as an
integer, so it works as a `Map` key.

**Element rule.** `T` has a default (`T()`).

- When `T` is plain data with no `drop`, and its default is all zero
  bytes, the table is reserved lazily (below).
- Otherwise every slot is made eagerly, which is allowed only while
  `n * size(T)` stays under a small limit (say 64 MiB). A larger table
  is rejected with a Rig diagnostic: "a `Table[File, 1048576]` makes
  every slot up front; `File()` is not all zeros, so its 1048576 slots
  would take 200 MiB".

**Why it is sound.**

- A `Slot[n]` value is below `n` in every way one can arise: a push that
  passed `len < n`, `of` that tested it, a literal checked at compile
  time, the default `0` (where `n >= 1`), and copies of these. Its
  representation is private to std, so no safe form makes one from other
  bits. `bytes.read[T, e]` reads numbers only. `raw` is the only escape,
  as for everything else.
- Every `Table[_, n]` has `n` slots, each a valid `T`, for its whole
  life. So `t[s]` reads or writes a live slot.
- A slot past `len`, whether read through another table's id or written
  through one, holds a valid `T`.
  - For plain data, nothing is leaked or double-freed.
  - For owning `T` (the eager case), `t[s] = x` drops the old value as
    any place store does, a later push overwrites with a drop, and the
    table's drop drops all `n` slots.
- Tasks: a Table is an owner, so two tasks reach one only through loans,
  and the Core's one-writer rule holds.

**CORE fit.** No sentence changes; see §4 for the paragraph.

- A Table is an owning value whose slots are places, like a List's
  elements: read in place, lent with `?t[s]` and `!t[s]`, and assigned.
- `push` lends the table to write, so a live view of a slot still
  forbids a push. The slots never move, but relaxing that would be an
  ownership change and is not proposed.
- `Slot[n]` is plain data that carries no loan.

**Ids crossing stores.** Memory-safe: the id names a slot of the other
table that exists. It is a logic error, exactly as an in-range foreign
id is today. If that ever matters, option A can be layered on top later
for correctness. It is not needed for safety.

**Drop, clear, pop, serialize.**

- **Drop** unmaps the reservation. Ids outlive it harmlessly: they are
  numbers below `n`, and any `Table[_, n]` accepts them.
- **No `pop`, `clear`, or `keep` at first** (decision 5). If added,
  `clear` must restore every touched slot to `T()`: re-mapping the
  range, or zero-filling up to the high-water mark. Nothing else is
  needed for safety, since a slot past `len` is allowed to hold any
  valid `T`.
- **Serialize** with `Int(s)`. Read back with `Slot[n].of(i)`, the one
  test, made where the id enters.

**Lowering.**

- `Slot[n]` becomes the smallest Zig unsigned holding `n - 1`, stored as
  `u8`, `u16`, `u32`, or `u64`. Trig's records keep 4-byte ids.
- `Table[T, n]` becomes `rig.Table(T, n)`, a `struct { slots: [*]T, len: u32 }`
  (`u64` when `n > 2^32`).
  - **Reserved** (zero default, plain data): one
    `mmap(n * @sizeOf(T), READ|WRITE, PRIVATE|ANONYMOUS|NORESERVE)`, as
    `src/alloc.zig` already does for its 64 GiB region. The OS supplies
    zero pages on first touch, and untouched slots cost no memory.
  - **Small** (`n * size` under a page or so): a zeroed heap allocation.
  - **Eager**: heap, filled with `T()`.
- `t[s]` becomes `t.slots[s]` through the many-pointer, with no Zig test
  in ReleaseSafe. A debug build asserts `s < n` as an assertion of the
  invariant (it cannot fail), like a proven check. `RIG_NO_PROOFS=1`
  makes it the real test `s < n`.
- `!t.push(x)` becomes `if (len == n) panic; slots[len] = x; len += 1; return len - 1`.
  That is the one compare a List push already makes against capacity,
  and growth never copies.
- **Targets without lazy zero pages** (wasm32, Windows, Linux with
  `overcommit_memory=2`) get the same meaning by materializing on
  demand.
  - The choice is made per target, at build time: never a runtime mode
    flag, which would itself be a test on every access.
  - A read past the committed prefix yields `T()`, and a write grows the
    prefix to cover it.
  - The test returns there, and only there. Trig's wasm32 build pays as
    it does today.

**Cost.**

- Compile time: two built-in types and one element check. Negligible.
- Code size: it shrinks, with no panic edge per access. About 2,750
  accessor call sites in Trig inline it.
- Address space: `n * size(T)` per table, and none of it is RSS until
  touched. For Trig with `types` at 2^26 × 32 B = 2 GiB and smaller
  tables at 2^22-2^24, a checker reserves ~20-40 GiB. Twenty-two
  checkers reserve under 1 TiB, against 128 TiB of user address space
  on x86-64 Linux and about the same on arm64 macOS (still to be checked
  on the Mac).
- Risk: transparent huge pages set to `always` can back each table's
  first touch with 2 MiB. Pass `madvise(NOHUGEPAGE)` until pup shows
  otherwise.

### Option C: masked index (sound, rejected on speed)

**Idea.** A normal growable List whose capacity is a power of two and
whose every capacity slot holds `T()` (any `T`, dropped over the whole
capacity). `t[s]` becomes `slots[s & (cap - 1)]`, which is always in
range.

**Spelling.** A library word. Any target works, with no reservation.

**Ids crossing stores.** An id from another store aliases silently,
modulo `cap`. That is safe, but a strange meaning.

**Why rejected.**

- The AND sits on the address's dependency chain, while a bounds test
  is predicted and off it. In Trig's pointer chases
  (`literals[types[t].data]`), that adds a cycle per hop, and saves
  about one micro-op over a fused compare-and-branch. It is the same
  trade as Spectre masking.
- Growth also fills the new half with defaults.
- Expect it to be no faster, and possibly slower.

### Option D: an instance tag checked at entry (sound, rejected)

**Idea.** Every store gets a runtime tag, and an id carries its store's
tag (`u64 = tag << 32 | index`, or the top bits of a `u32`).

**Why rejected.**

- The "check at entry" is really a tag compare on every use, because an
  id can flow anywhere between uses. That is the same cost as the
  bounds test it replaces, and it doubles the id's size or halves its
  range.
- Its one virtue, catching cross-store misuse at run time, is option
  A's at compile time.

### Option E: proof-pass facts (sound, small for stores)

**Idea.** Extend `src/proofs.zig`:

- `id = !s.push(x)` makes `below(id, 1, len(s))`.
- On a List no unit shrinks, `below(_, _, len(s))` survives pushes.
  This is panel B's §2d, "lengths that only grow", and it needs B's
  effect summaries.
- The sibling class, from B's §1a: an index whose *type* bounds it
  inside an array (`U8` into `[256]T`).

**Spelling.** None. **CORE fit.** Sentences 4 and 9, as today.

**Ids crossing stores.** Not an issue: facts are about this store.

**Payoff for stores: almost none.** Trig's ids come from parameters,
fields, and records (`types[t].data`), not from a push in the same
body. Function-entry facts cannot follow them. Keep this for B's loops;
it does not answer this panel's question.

### Rust and Zig, for comparison

- **GhostCell, `generativity`, `indexing`, `compact_arena`** (`Idx32<'tag>`,
  no bounds test) are option A. All rely on a `for<'id>` closure and
  erased lifetimes, and all make every holder of an id carry `'id`.
- **`typed-index-collections`** gives nominal id types and still tests.
- **Zig's `InternPool.Index`** (`enum(u32)`) gives nominal ids, tested
  in ReleaseSafe. Zig's own check-free case is a `u8` into a `[256]T`,
  a range by type, which is what option B generalizes.
- **WebAssembly engines** (V8, Wasmtime) reserve 4 GiB plus guard pages
  so a 32-bit index never needs a test. That is option B's lineage.

| | A brands | **B Table+Slot** | C mask | D tag | E facts |
|---|---|---|---|---|---|
| Test gone | yes, all targets | yes (fallback targets keep it) | replaced by AND | no | where provable |
| New syntax | rank-2 scope | none (2 words) | none | none | none |
| Ownership change | none | none | none | none | none |
| Foreign id | compile error | safe, wrong slot | safe, aliased | runtime panic | n/a |
| Trig churn | viral `[B]` on ~60 objects and the checker | field types, aliases, generator | field types | id width | none |
| §10 one paragraph | no | yes | yes | yes | yes |

## 3. Recommendation

**Option B: `Table[T, n]` and `Slot[n]`,** built only if the gate
measurement clears the speed bar.

- It dissolves the identity problem instead of proving it: every
  `Slot[n]` is in range of every `Table[_, n]`.
- The proof is a sentence, not a pass.
- It needs no syntax and no ownership change.
- It also dissolves Trig's paged link tables (`_has`, `_ensure`, and the
  38 `id / 256` lookups), and growth never copies a large store.

## 4. CORE §10 paragraph

> **Tables.** A `Table[T, n]` is an owning value, like a List. It holds
> `n` slots from the moment it is made, each `T()` until written. A
> `Slot[n]` is plain data: a number below `n` that only `push`, `of`,
> and literals make. A slot is a place, like a List's element: read in
> place, lent with `?t[s]` or `!t[s]`, assigned (dropping the old
> value). `!t.push(x)` lends the table to write, assigns slot `len`, and
> returns it. It desugars to the forms above: `t[s]` is the element `s`
> of an array of `n` elements the table owns, and `!t.push(x)` is
> `t[len] = x; len += 1` after a test that `len < n`. No rule here
> changes for it.

## 5. Migration of Trig's store (tools/checker/gen-store.py)

1. **Sizes.** Constants in one generated block: `TYPES = 1 << 26`,
   `KINDS = 1 << 24` (all tables a `data` indexes share one `n`),
   `STRUCTURED`, `SIGS`, `MAPPERS`, and so on.
2. **Ids.**
   - `pub type TypeId = Slot[TYPES]` (and `SigId`, `MapperId`, ...).
   - `Type.data` becomes `Slot[KINDS]`, so one field indexes every kind
     table, as now. `structured` becomes `Slot[STRUCTURED]`.
   - Literal defaults (`= 0`) stay as written.
3. **Fields.** `List[X]` becomes `Table[X, N]`.
   - `Store.new` keeps pushing slot 0 so that `len` and 0-is-nil stay
     as they are (or drops it, since slot 0 already reads as `X()`).
   - `TypeKind` gains a zero variant (`None = 0`), or `Type.kind`
     defaults to it, so that `Type()` is all zeros. This is the one
     semantic edit, and the compiler names it if missed.
4. **Accessors.** `@store.types[Int(t)]` becomes `@store.types[t]`, and
   `i = Int(@store.types[Int(t)].data)` becomes
   `i = @store.types[t].data`.
5. **Minting.** `alloc_X` returns `!@store.X.push(X())`. In
   `new_type`, `t = !@store.types.push(Type(...))`. The 35
   `U32(... .len - 1)` sites disappear.
6. **Link pages.** `List[List[XLinks]]` and `X_has`/`X_ensure` become
   `Table[XLinks, N]`. `has` becomes a test of the record against its
   zero, where the Go semantics allow it; check each of the ~8 link
   kinds.
7. **Spans** (`TypeList` and the others: `start`/`count`) stay
   Int-indexed and tested. 644 accessor call sites go through them
   (`type_at` 291, `new_type_list` 209). A later `Span` that std mints
   could cover them; that is a separate decision.
8. **Rest of Trig.** `Int(t)` where an Int is needed stays. Arithmetic
   on ids (rare) goes through `Slot[n].of`. Maps keyed by `TypeId` are
   unchanged.
9. **Phase 2, not now:** `program.files` (1,530 source sites, 737 of
   them `files[Int(d.file) - 1]`).
   - Its `File` owns text, so it would be an eager table, and `FILES`
     must stay small (2^16 × ~200 B ≈ 13 MiB).
   - Node headers' `file` would become `Slot[FILES]`. That touches the
     parser and binder, and Trig owns that plan.
10. **Note to Trig** before landing: a migration script (the generator
    rerun, plus a sed for `[Int(t)]` and the like) and a one-line note,
    per "warn Trig before breaking".

## 6. Tests

New file `test/rig/table.rig.test`, plus SPEC §10 examples.

- **test:**
  - push returns slots 0, 1, ...; `t[s]` reads and writes.
  - Unpushed slot reads `T()`: `print(t[Slot[8].of(5)!].x)` gives `0`.
  - A slot from another table of the same `n` reads that table's slot.
  - Literal ids; `Slot` as a `Map` key; `for x in t` covers only the
    pushed slots.
  - An eager table of Strings drops every slot; runs clean under
    `RIG_SANITIZE=1`, with no leak.
  - Moving a Table into a task (`seeds: 20`).
- **bomb:**
  - Push into a full `Table[Int, 2]`: "a table of 2 slots is full".
  - `t[i]` with an `Int` past `n`.
- **fail:**
  - `Slot[8](raw: 3)` (private).
  - A literal `9` as a `Slot[8]`.
  - `Table[Type, 1 << 26]` whose `Type()` is not zeros and too large to
    make eagerly.
  - `Table[?String, 4]` (a view element).
  - `Slot[0]`.
  - `!t.push(x)` while `a = ?t[s]` is still used.
  - A `Slot[8]` given to a `Table[_, 16]` (decision 3's default: exact
    `n`).
- **code:**
  - `t[s]` emits `.slots[` and no `rig.index` / `indexPanic`.
  - `!t.push(x)` emits one compare.
- **Doc examples** in SPEC §10 and STD. An oracle entry if the oracle
  learns Tables (they are List-shaped for loans, so it should accept
  them unchanged).
- **CLI:** a `run` on Linux and macOS that makes 22 tables of 2 GiB
  each and touches one slot of each, checking RSS stays small.
- **Fallback:** the same `test` cases with the materializing Table
  forced on (an env flag at build time), so both lowerings share the
  suite.

## 7. Expected payoff (counts; the share must be measured)

| Group | Count |
|---|---|
| Store index expressions in Trig's checker sources | 567 |
| …of which covered (by id, `data`, `structured`, page lookups) | ~543 |
| …of which spans, still tested | 24 |
| Accessor call sites outside the generated file, id-indexed | 1,642 generated + 1,112 hand-written |
| …span-indexed, not covered | 644 |
| Mint sites losing subtract and narrowing tests | 35 |
| Paged link lookups dissolved | 38 (`id / 256`) |
| Phase 2 `program.files` sites | 1,530 |

- Each id accessor makes one or two hops (`types[t]`, then the kind's
  table), so each covered call removes one or two compare-and-branch
  pairs and a `len` load.
- Panel B's emitted-Zig census has 2,532 unproven List index sites in
  the checker; `@store.types` alone is 236 of them.
- Removing the tests also stops the re-test after every call that LLVM
  must otherwise make, because it cannot know that `len` is unchanged
  (panel B, §0).
- **No percentage until the gate build measures one.**

## 8. Counters that only count up

Trig's pure counters (`@type_count`, `@symbol_count`, `@signature_count`,
`@instantiation_count`, `@flow_invocation_count`, `@reason_count`,
`@next_symbol_id`, ...) are about 25 sites, all off the hot path. `@pos
+= 1` (65 sites) is a position, not a counter: it is bounded by
`@pos < @src.len` guards, which is panel B's field-term work (§1a, `d.f`
terms).

- **C1 (recommended): use the operator Rig has.** `@type_count +%= 1` is
  defined (it wraps) and memory-safe. For a 64-bit count that adds 1,
  the wrap is out of reach (2^63 adds take 292 years at one per
  nanosecond). This needs no compiler work, only a sentence in STD or
  SPEC's `+%` section saying so.
- **C2 (recommended, comes with B):** `Table.push` returns the slot. The
  `len - 1` and `U32(...)` tests at the 35 mint sites go. The full test
  is the compare that push already makes.
- **C3: a std `Counter` word** (`!c.up() -> Int`, `pub ?n`). It is sound
  by module privacy plus `+%`, but it adds a word for what C1 says in
  one operator.
- **C4 (rejected): a proof rule** for "a field whose every write in the
  program is `+= 1`". It needs whole-program write facts on fields,
  rests on a time argument rather than a test the program made, and
  saves an `add`/`jo` pair on cold paths.

## 9. Owner decisions (defaults)

1. **Build option B** (`Table` and `Slot`) after the gate shows the
   index tests are worth at least the speed bar. *Default: yes,
   gated.*
2. **Names.** *Default: `Table[T, n]` and `Slot[n]`.*
   - Declaration: `types: Table[Type, TYPES]`, `pub type TypeId = Slot[TYPES]`.
   - Error: "a table of 2 slots is full".
   - Prose: "a `Slot[n]` names one of a table's `n` slots".
   - Alternatives: `Id[n]` or `Below[n]` for the id; `Slots` or `Store`
     for the table.
3. **A slot type indexes only a table of exactly its `n`.** *Default:
   exact `n`* (no `Slot[8]` into a `Table[_, 16]`; convert with `of`).
4. **Unpushed slots read `T()` in every build, with no debug-only test
   against `len`.** *Default: yes*, one meaning in every build.
   - The alternative, a debug test that catches foreign ids, would make
     debug and release differ for one program.
5. **Append-only.** *Default: no `pop`/`clear`/`keep` at first.*
6. **Fallback targets** (wasm32, Windows, strict overcommit) keep the
   test with the same meaning, chosen at build time. *Default: yes.*
7. **Counters:** document `+%=` for pure counters (C1). No `Counter`
   word, and no proof rule. *Default: yes.*
8. **Option A (brands)** is recorded as the path if cross-checker
   misuse is ever to be caught at compile time, and is not built now.
   *Default: not now.*
