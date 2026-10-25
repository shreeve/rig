# The Map/Set stage: candidate designs, 2026-10-24

Design only; nothing here is built. The survey behind it is
[survey.md](survey.md), and how a candidate is judged is
[bench-plan.md](bench-plan.md). Every estimate below is reasoning from
sizes and op mixes, to be replaced by the replay of Trig's traces
before anything is built into std.

## 0. Summary

- **Top candidate: packed slots (Candidate 2).** A Map whose entries
  are small (at most 32 bytes) and whose key is plain data keeps each
  key and value in its table slot, where the hash puts it, with Swiss
  control bytes probed 16 at a time and the order kept as a List of
  4-byte slot numbers. Every other Map keeps its dense entries behind
  the same SIMD index (Candidate 1). It is F14Fast's rule, with order
  kept on both sides. A hit waits on memory once instead of twice; Trig's
  four hot workloads all have small plain keys.
- **It needs little from the language.** It can be written in safe Rig
  today, over the four Lists the Map already has, with one new
  compile-time question (whether a key type is plain data). Neither Core rule now being built is on its critical path; the
  first (a write view returned through a write-view binding) lifts the
  separate 1.3-1.9% ceiling of Map's internal checks, for every candidate.
- **Why it should not repeat the slots experiment** (§1): that
  experiment's slots were 40 bytes because a free slot held optional
  keys and values, and its tables grew four times over, so it carried
  slots 20-80% full. Here a control byte says a slot is free, so the
  slot is 24 bytes for a `CacheKey` and a `U32`; tables double at 7/8;
  the index lives in the slots, so there is no separate entry List.
  At Trig's two big caches that is 7.6 MB and 19.4 MB, against 11.0 and
  31.5 today.
- **The small path matters as much** (§2.4): a map of up to 8 entries
  compares keys directly, with no hash, so the 4M one-entry mapper-cache
  lookups do a length test and a two-word compare.
- **Expected effect:** about 220-350M of the 523M-cycle map gap on
  ts-pattern (§6), 4-7% of its cycles. That is an estimate, bounded by
  the trace replay first, and kept only if real Trig agrees.

## 1. Why the slots experiment lost

The backlog records it: keys and values in the slots, the order as a
List of slot indexes; cold lookups 92-95 ns against 152-156, but real
Trig 12% slower on ts-pattern with 41% more RSS (646 MB against 459),
`bench/hash` inserts 40-70% slower and iteration about 16 times as slow.

Reading the Map's code for this stage explains most of it:

1. **The slots were 40 bytes, not 24.** A free slot held no key and no
   value, so both were optional (`CacheKey?` and `U32?`), as the backlog
   says. A control byte that marks the slot free removes the need: a free
   slot holds a default key and `none`, which nothing reads.
2. **The tables quadrupled.** Today's growth rule ([survey.md](survey.md)
   §0) builds tables of 32, 128, 512, ... slots, 20% to 80% full. With a
   5-byte index slot that costs 1-4 bytes an entry beyond the ideal; with
   a 40-byte slot it costs 10-40. A 223k-entry relation cache at
   524,288 slots of 40 bytes is 21 MB against today's 11; a 421k-entry
   instantiation cache, past the 419,431 boundary, sits in 2,097,152
   slots: 84 MB or more against today's 31.5. Those two maps alone
   account for a large share of the 187 MB.
3. **Inserts moved the big slots, four times over.** Every growth
   rewrote 40-byte slots; today's growth rewrites 5-byte index slots and
   copies the entry List once as it doubles.
4. **Iteration went through the order List** into slots scattered over
   tens of megabytes: one cache miss an entry in `bench/hash`'s million
   keys. That one is inherent to keys in slots, and is why Candidate 2
   keeps dense entries for large and owning entries, and why
   [bench-plan.md](bench-plan.md) weighs iteration by how often Trig does
   it (its hot caches are never iterated: no `items`, `keys`, `values`,
   `at`, `update`, or `retain` on `relation_results`, `instantiations`,
   or the mapper caches in Trig's source today).

## 2. Pieces every candidate shares

### 2.1 Growth: double at 7/8

Grow when the next entry would pass 7/8 full, and double. A table then
runs between 7/16 and 7/8 full, like absl's and hashbrown's. With one-tag
linear probing, 7/8 would mean long probes (about 4.5 slots for a hit,
over 30 for a miss); with 16 tags tested at once, nearly every lookup
reads one group. The cost: twice as many growths as today, each moving
half as much. The quadrupling itself could be fixed alone, first, and
measured: it is a one-line change to `table_size`'s use in `grow`.

### 2.2 Probing: 16 tags at a time

The control bytes stay what `tags` is now (0 free, top 7 hash bits with
the high bit set when full), plus a deleted value (`0x01`) for Candidate
2, and a mirror of the first 15 bytes after the end, so a group read at
any slot needs no wrap. A probe reads `ctrl.read[Simd[U8, 16]](i)` from
the home slot `h & mask`, compares it with the tag, walks the matching
lanes (`bits()`, `trailing_zeros()`), and stops when the group holds a
free byte. It steps 16 slots at a time, linearly, so the back-shift
delete of today still works for Candidate 1.

On x86 the match is `pcmpeqb` and `pmovmskb`. On ARM a 16-lane `bits()`
has no single instruction; hashbrown uses 8-byte groups there for that
reason. Rig's `first()` lowers to one crossing on 16 lanes, and `bits()`
per target ([simd-lowering.md](../../../../internals/simd-lowering.md)), so the
group width is a measured choice per target: 16 lanes, or 8 tags as a
`U64` read with bit tricks (Go's portable form), which needs nothing
but `read[U64]`.

What it buys: today a hit at 43% load walks about 1.4 tags with a
compare and a branch each, a miss about 2.1, each tag compare a branch
that mispredicts at random. A group match is a few instructions with one
predictable branch.

### 2.3 The hash: hash a good hash once

A `CacheKey` is already an xxh3 output; Rig hashes it again (two
integer hashes and two mixes). tsrs uses its low word. Rig's `Hash` API
has `hash_into(h: !Hasher)`, whose `add` still mixes. One small addition
lets a type give its hash whole: a `Hasher` that takes one word as the
result (`!h.set(@lo)`), or a type's own `hash` returning the `U64`. With
it, a Map of such keys needs no stored hash at all (`hs` stays empty), so
Candidate 1 drops 8 bytes an entry too. Without it, the plain keys of
Candidate 2 are hashed again on growth, which for 16-24-byte keys is a
handful of multiplies.

### 2.4 The small path

Trig's workloads here: 106,106 symbol tables `Map[ast.Atom, Sym]`, of
which 3,496 are empty and 70,747 hold 1-8 entries; and mapper caches
`Map[CacheKey, TypeId]`, pooled, looked up 4M times at about one entry.

Today a small Map of `CacheKey` keys hashes the key (several multiplies),
scans `hs` for the hash, then compares the key and tests the value for
`none`, with a bounds test at each index. Its insert pushes to `es` and
to `hs`: two blocks.

The small path proposed:

- Up to `SMALL` = 8 entries, no table, `es` dense in insertion order (as
  now, and in Candidate 2 the same List later becomes the slots).
- A lookup compares **keys**, not hashes, when the key is plain data of
  at most 16 bytes (`Atom`, `Int`, `TypeId`, `CacheKey`): no hash is
  computed at all, and `hs` is never filled. For a one-entry map that is
  a length test, a two-word compare, and the `none` test of the value.
  Larger or owning keys (String) keep today's hash scan, which
  [compact-map](../compact-map/README.md) measured as right for them.
- The hash is computed only when the map builds its table, and on each
  later operation.
- `clear` drops back to the small path without touching the table's
  bytes (as now). hashbrown's `clear` touches every bucket, which cost
  tsrs 1.5% on pooled maps a deep call once grew; Rig must not adopt a
  `clear` that does.

Measured against: the compact-map record's harness (100,000 maps of `k`
entries) and the mapper-cache and symbol-table streams of the traces.
What it does not change: the 104-byte header (§7, "a field chosen at
compile time" would shrink it) and the List's growth from 4 (a list
that starts at 1 or 2 would suit one-entry maps; tsrs grows 1, 2, 4).

### 2.5 `find` hands back the entry

When the first Core rule now being built lands (a write view returned
through a write-view binding), `find` returns a view of the entry (or
slot) instead of an index, and `get`, `edit`, `ensure`, and `replace`
stop re-indexing `es[j]` with a bounds test. That is the separate
1.3-1.9% ceiling on ts-pattern
([len-and-map-notes.md](../safety-checks/len-and-map-notes.md)); it
applies to every candidate and is measured on its own.

## 3. Candidate 1: a Swiss index over dense entries

indexmap's and F14Vector's shape, closest to today.

**Layout, in Rig:**

```
obj Map[K: Hash, V]
  pub ?len: Int = 0
  es: List[Entry[K, V]] = List()   # dense, insertion order (as now)
  hs: List[U64] = List()           # keys over 8 bytes without a whole hash (as now)
  table: Table = Table()           # ctrl: List[U8] (slots + 15 mirrored), at: List[U32]
```

Only the index changes: 16-tag group probes (§2.2), 7/8 and doubling
(§2.1), back-shift delete kept. `take`, compaction, iteration, `at(i)`,
`retain` are unchanged.

**Needs from the language:** nothing new. `Simd[U8, 16]`, `read` from a
byte view, `bits()`, `trailing_zeros()` are on main (std.json uses
them). §2.3's whole hash is a small API addition; §2.5 waits on Core
rule 1.

**Effect on Trig's workloads:**

| Workload | Effect |
|---|---|
| Relation cache, 223k `CacheKey -> U32` | fewer instructions and mispredicts per probe; still two dependent misses per hit (index, then entry); index 2.6 MB -> 1.3 MB |
| Instantiation cache, 421k `InstantiationKey -> TypeId` | as above; index 10.5 MB -> 2.6 MB; total 31.5 MB -> 23.6 MB (19.4 with §2.3) |
| 106k symbol tables | small path unchanged for keys of 8 bytes; the 27,346 tables past 16 entries probe by group; all in cache, so instructions, not misses |
| 4M mapper-cache lookups | the small path (§2.4) |

Against the slots experiment: no entry moves, so inserts and RSS can
only improve.

**Risk:** low. Its ceiling is low too: it keeps the second miss, which
is what tsrs's PackedMap and the 0.57x microbench removed.

## 4. Candidate 2 (top): packed slots, chosen at compile time

**The rule.** `packed[K, V]()`, a generic function the compiler folds,
as `stores_hashes[K]()` is today: true when `K` is plain data (it
copies and owns nothing, so a free slot's default key `K()` needs no
drop and a rebuild copies it) and an `Entry[K, V]` is at most 32 bytes.
True for `Map[CacheKey, U32]` (24), `Map[CacheKey, TypeId]` (24),
`Map[InstantiationKey, TypeId]` (32), `Map[ast.Atom, Sym]` (12),
`Map[Int, Int]` (24); false for String keys, whose compare reads the
text wherever the key is, and for large entries. `V` may own: a free
slot's value is `none`. The threshold (24 like F14Fast, or 32 to
take the instantiation cache) is decided by the replay.

**Layout, in Rig:** the same four Lists, read differently, so no new
field form and the same 104-byte header:

```
es     the slots: es[s] is slot s, Entry(key, value); a free slot holds K() and none
hs     unused (the hash is recomputed from the key, or whole, §2.3)
ctrl   control bytes, as in §2.2, plus 0x01 = taken
at     the order: at[i] is the slot of the i-th entry put in
```

In the small path (§2.4) `es` is dense and in order and `ctrl` and `at`
are empty. When the ninth entry comes, the map builds 16 slots, moves
each entry to its slot, and records the slots in `at` in order.

**Operations:**

- `find`: one group of `ctrl` from the home slot and `es[home]`; both
  addresses come from the hash, so the two loads go out together, and a
  hit usually lies in the home group's slots, a line or two from
  `es[home]`. One wait on memory, where Candidate 1 and today wait twice.
  `get` and `edit` view `es[s].value` in place: `if !@es[s].value as v`,
  `return v` is accepted today, because the slot is a plain place, not
  an optional of a slot.
- Insert of a new key: the first free slot in the probe, the entry
  written there, the tag and its mirror, and `at.push(s)`.
- `take`: the value moves out (`<@es[s].value`, leaving `none`), the
  control byte becomes taken (`0x01`), and the slot is **not reused**
  until the next rebuild, so `at` never names a slot that a later key
  took over. Iteration and `at(i)` skip slots whose value is `none`,
  exactly as they skip taken entries today. The key stays until the
  rebuild, as it does in `es` today.
- Growth: allocate twice the slots, walk `at` in order, move each live
  entry to its new slot and push the new slot number; `at` comes out
  compacted, as `compact` does now. Takes count toward the load (taken
  slots are not free), so a churning map rebuilds at the same size when
  most of its full bytes are taken (absl's in-place rehash).
- Iteration: `at` in order, `es[at[i]]`. Sequential for maps that fit
  in cache (symbol tables); one miss an entry for huge maps (§1.4).

**Memory at Trig's sizes** (power-of-two slots, List growth by doubling):

| Map | Today | Candidate 1 | Candidate 2 |
|---|---|---|---|
| relation cache, 223k entries of 24 bytes | 11.0 MB | 9.7 MB (7.6 with §2.3) | 7.6 MB (262,144 slots, 85% full) |
| instantiation cache, 421k of 32 bytes | 31.5 MB | 23.6 MB (19.4) | 19.4 MB (524,288 slots, 80% full) |

Averaged over sizes, a packed map carries 24 bytes over a load of about
2/3, a control byte, and 4-5 bytes of order: about 43 bytes an entry of
24, against about 50 today (40 for Candidate 1 with §2.3). Just after a
growth it is worse (7/16 full), so the replay reports peak RSS, not
just the end.

**Needs from the language:**

| Need | Status |
|---|---|
| `Simd[U8, 16]`, `read`, `bits()`, `trailing_zeros()` | on main |
| `packed[K, V]()`: whether `K` is plain data, as a compile-time question (`$plain(K)` beside `$size`) | new, small; `$size` exists |
| A whole hash (§2.3) | new, small, optional |
| Core rule 1, a write view returned through a write-view binding | not needed for the layout; lifts the 1.3-1.9% check ceiling (§2.5) |
| Core rule 2, partial moves | not needed; would let a rebuild move a slot's key and value apart, and is the half of a slot with no `V?` that the other half (a slot that holds no value at all) would still lack |
| `Table`/`Slot` | not used: a Table's size is fixed when it is made, and a Map's table grows. Its idea, an index only its maker can make, is what §2.5's entry view replaces |
| A field whose type a compile-time function picks | not needed; would drop the unused `hs` (24 bytes) from packed maps and let a plain `V` drop its `?` |

**Trig-side choices that help it** (Trig's to make, not Rig's):
`TypeId` and `Sym` as objects that name their none (`none id == 0`,
SPEC §12), so a `V?` is 4 bytes, and a `CacheKey` of four `U32` words, so
it aligns to 4: then a `CacheKey -> TypeId` slot is 20 bytes, tsrs's
PackedMap exactly, and a symbol-table slot 8.

**Effect on Trig's workloads:**

| Workload | Effect |
|---|---|
| Relation cache | one wait per hit instead of two: the 0.57x lookup time of the Trig fork's microbench applies here; RSS 11.0 -> 7.6 MB |
| Instantiation cache | the same; RSS 31.5 -> 19.4 MB |
| Symbol tables | small path as today for 70,747 of them; the 27,346 larger ones probe by group, in cache; no new allocations |
| Mapper caches | the small path (§2.4); they never reach a table |

**Why it should beat the slots experiment:** 24-byte slots, not 40
(§1.1); 7/16 to 7/8 full, not 20% to 80% (§1.2); RSS at or below today's
at both caches by the arithmetic above; growth moves 24-32-byte slots
twice as often as today's 5-byte index slots, which is the one insert
cost that rises, against an insert that no longer pushes to `hs` or
writes a separate index slot.

**Risk:** medium.

- Two layouts in one std file: every method branches on `packed[K, V]()`,
  folded per instance as `stores_hashes` is. More code to review and
  sanitize; the oracle checks Map by its signatures, which do not change.
- Iteration of huge packed maps is slower than today (one miss an
  entry). bench/hash's iteration row on a million `Int` keys will lose,
  as it did in the experiment; a `prefetch` of `es[at[i + 8]]` would
  recover part of it and needs an intrinsic Rig does not have.
- Lookups of keys put in in order (bench/hash's pattern) lose today's
  locality, where the entries a sequential walk finds are adjacent in
  `es`. The experiment's "hits about twice as slow" in bench/hash was
  partly that; Trig's caches are not looked up in insertion order, which
  only the traces can show.
- The 32-byte threshold is a guess between F14Fast's 24 and Trig's
  instantiation key.

## 5. Candidate 3: order on demand

Candidate 2, with the order List left out of any Map instance whose
order the program never reads.

The order is observable only through `items`, `keys`, `values`, `at`,
`update`, `retain`, printing, and anything generic that iterates a Map
(an `Iter` bound, an API object). The compiler knows, for a whole
program, which `Map[K, V]` instances reach any of those. An instance
that reaches none keeps no `at`: an insert is the slot write and the
tag, nothing more, and the map is hashbrown's layout exactly. The
language's meaning is unchanged: one ordered Map, whose order costs
nothing where nobody reads it. Trig's hot caches qualify today.

**Needs from the language:** a program-wide fact per generic instance,
recorded once (one classifier per fact) and read by emit, as inlining's
decisions are; a field present or absent by that fact, or the empty List
it is today.

**Effect:** small over Candidate 2: one 4-byte push per insert and 4-5
bytes an entry (1.0 MB and 2.1 MB at the two caches).

**Risk:** high for the gain. The fact is per instance type, not per
map: `Map[CacheKey, TypeId]` serves about ten Trig caches, and one of
them printed while debugging puts the order back in all of them, changing
speed and memory far from the edit. That is the kind of surprise Rig's
syntax rules exist to avoid. Not recommended unless the traces show the
order upkeep above 1% of the map family.

## 6. Expected effect on ts-pattern

From the Trig fork's numbers: the Map/Set family is 956M cycles against
tsrs's 433M (1,875M against 842M self instructions); the tsrs review
attributes 269M cycles to Trig's `Map[CacheKey, U32]` instances and 208M
to the instantiation map; Map and Set are 18.8% of ts-pattern's samples,
which puts ts-pattern near 5.1G cycles.

| Piece | Reasoning | Estimate |
|---|---|---|
| Packed slots on the two big caches (477M) | lookups at 0.57-0.7x, inserts about even | 140-200M cycles |
| Small path on mapper caches | about 20 instructions less per lookup x 4M, plus no `hs` push per insert | 30-50M |
| Group probing, 7/8, whole hash on the rest (479M) | fewer instructions and mispredicts; mostly cache-resident | 50-100M |
| Total for Candidate 2 | | **220-350M of the 523M gap; 4-7% of ts-pattern** |
| Candidate 1 alone | no second-miss removal | 100-180M |

Each row is a hypothesis for the replay to confirm or cut ("measure the
share first"); the tsrs lesson is that a map 60% faster in a microbench
was 1.5% of Go's applications.

## 7. Order of work

Each step measured on its own with the replay, then on Trig, then kept
or recorded as not landed:

1. The growth rule (§2.1's doubling, and quadrupling fixed alone).
2. The small path (§2.4), with the whole hash (§2.3) if the owner takes
   the API addition.
3. Group probing (§2.2): Candidate 1.
4. Packed slots: Candidate 2, at 24 and at 32 bytes.
5. `find` returning the entry (§2.5), when Core rule 1 lands.

Candidate 3 only if step 4's profile shows the order upkeep above 1%.

## 8. Owner questions, with defaults

1. Candidate 2 as the target, built in the steps of §7. Default: yes.
2. A whole hash for keys that are already hashes (§2.3): `!h.set(word)`
   on `Hasher`. Default: yes, as a small API addition with its own review.
3. `packed[K, V]()`'s compile-time question: a `$plain(T)` beside
   `$size(T)`. Default: yes.
4. Iteration of a huge packed map may be slower than today's (bench/hash
   `iterate`, a million `Int` keys) while Trig is faster. Default: accept
   it for the packed layout only, recorded, since the rule "never
   slower" would otherwise forbid the layout every flat map uses.
5. Candidate 3. Default: no.
