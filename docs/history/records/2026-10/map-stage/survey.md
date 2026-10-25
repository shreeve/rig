# The Map/Set stage: a survey of the fastest hash maps, 2026-10-24

What the industry's best hash tables do, measured where their authors
published numbers, and what of it applies to Rig's one ordered Map.
Read with [design.md](design.md) (the candidates) and
[bench-plan.md](bench-plan.md) (how they are judged).

Sources are primary: the designers' posts and docs, and the source code
where a post leaves a constant out. Numbers are theirs, on their
machines; none is a Rig measurement. Where a source gave no number, this
says so rather than quoting a secondary one.

## 0. Where Rig's Map stands (main 0068bfa3b)

`std/__rig_builtin.rig`, one ordered Map and Set in safe Rig over Lists:

| Part | Today |
|---|---|
| Header | 104 bytes: `len` and four Lists (`es`, `hs`, `tags`, `at`) |
| Entries | `es: List[Entry[K, V]]`, dense, insertion order; `Entry` is `key: K, value: V?`; a taken entry's value is `none` until compaction |
| Hashes | `hs: List[U64]` beside the entries, only for keys over 8 bytes |
| Small | up to `SMALL` = 8 entries, no table: a scan of the keys (8 bytes or less) or of `hs` |
| Index | `tags: List[U8]` (top 7 hash bits, high bit set; 0 = free) and `at: List[U32]` (entry index), linear probing one tag at a time, back-shift deletion, no tombstones |
| Growth | grows when the next entry would pass 4/5 full; `table_size` then picks a size at most 2/5 full |
| Hash | the runtime's `rig.hash`: an integer by one multiply, an object by mixing its fields' hashes, text by Wyhash |

One finding from reading it for this survey: **the table always grows
four times over, not twice.** `insert` grows when `(len + 1) * 5 >
slots * 4`, and `table_size(len + 1, slots)` then doubles until
`want * 5 <= n * 2`; the first doubling fails the same test that
triggered the growth, so it doubles again. A simulation of the code
gives tables of 32, 128, 512, 2,048, ... slots, built at 9, 26, 103,
410, ... entries, so a table runs between 20% and 80% full, not the 40%
to 80% its comment describes. At Trig's sizes: a 223k-entry relation
cache sits in 524,288 slots (43% full, 2.6 MB of index), and a
421k-entry instantiation cache, just past the 419,431 boundary, in
2,097,152 slots (20% full, 10.5 MB of index where 2.6 MB would do at
7/8). The comment says "double"; the code quadruples. Whether that was
meant (short linear probes) or not, it is part of the RSS story below.

A hit in a map with a table waits on memory twice: `tags[i]` and
`at[i]` load together (both addresses come from the hash), then
`es[j]` (its address comes from `at[i]`). The backlog's "entries in
the table slots" experiment cut that to one wait and measured cold
lookups at 92-95 ns against 152-156 ns, but Trig ran 12% slower with
41% more RSS; [design.md](design.md) §1 explains why from its numbers.

## 1. The designs

### 1.1 Abseil SwissTable (`absl::flat_hash_map`)

Sources: the [design note](https://abseil.io/about/design/swisstables)
and [raw_hash_set.h](https://github.com/abseil/abseil-cpp/blob/master/absl/container/internal/raw_hash_set.h).

- **Layout.** One allocation: an array of control bytes, one per slot,
  then the slots (key and value inline, "flat"; `node_hash_map` puts a
  pointer in the slot instead). After the control bytes, a sentinel and
  a copy of the first `Group::kWidth - 1` control bytes, so a group read
  that starts near the end needs no wrap.
- **Control bytes.** Empty, deleted, sentinel, or full; a full byte holds
  H2, the hash's top 7 bits. H1, the rest, picks the start.
- **Probing.** A group is 16 bytes on x86 (SSE2: one compare, one
  `movemask`), 8 elsewhere (portable bit tricks). The probe visits
  groups in triangular steps, `Width * (i^2 + i) / 2`, which visits every
  group once in a power-of-two table. A lookup filters 16 candidates to
  those whose H2 matches, compares keys only there (a false match is
  1/128), and stops at the first group that holds an empty byte.
- **Load factor.** 7/8 (`capacity - capacity / 8`); tiny tables fill
  further. Capacity 1 is kept in the object itself (SOO, at most one
  element).
- **Delete.** A tombstone (deleted), unless the slot would appear in no
  probe sequence: a group with an empty byte was never full, so a slot
  there can become empty again. Tombstones are dropped by a rehash.
- **Memory.** One control byte a slot, plus slack up to 1/8 empty.
- **Speed.** The design note gives no numbers.
- **What makes it fast:** 16 candidates rejected per compare, one
  allocation, a high load factor because probe length barely grows with
  load when 16 slots are tested at once.

### 1.2 Rust hashbrown (`std::collections::HashMap`)

Sources: [the repository](https://github.com/rust-lang/hashbrown) and
its source (`src/raw.rs`, `src/control/`).

- A port of SwissTable. Groups are an SSE2 `__m128i` (16 bytes, a 16-bit
  mask) on x86 and a NEON `uint8x8_t` (8 bytes, a 64-bit mask) on ARM: on
  ARM it uses 8-wide groups, because a 16-byte NEON compare has no cheap
  `movemask`.
- Control bytes: `EMPTY` = `0xFF`, `DELETED` = `0x80`, full = the top 7
  bits of the hash (high bit clear). `EMPTY` is told from `DELETED` by one bit.
- Load factor 7/8 for tables of 8 buckets or more (`buckets / 8 * 7`);
  smaller ones keep one bucket empty. Erase leaves a tombstone only when
  the groups around the slot have no empty byte, as Abseil does.
- An empty map allocates nothing. Default hasher foldhash.
- Measured: the README claims about twice the speed of the HashMap it
  replaced and 1 byte of overhead per entry instead of 8; no table.

### 1.3 Folly F14

Source: [the F14 post](https://engineering.fb.com/2019/04/25/developer-tools/f14/).

- **Chunks.** Slots in chunks, each with 14 7-bit tags (12 for the
  vector variant) filtered by one vector compare, and a 1-byte
  **overflow count**: the keys that wanted this chunk but live further
  along. A lookup stops at a chunk whose count is 0, so F14 needs no
  tombstones; erase decrements the counts along the key's probe. The
  post's argument: tombstones behave like a high load factor for speed
  and a low one for memory.
- **Load factor.** 12/14 for Value and Node, 10/12 for Vector; tables up
  to 14 entries need no special case.
- **Variants.** `F14Value` (entries in the chunks), `F14Node` (a pointer
  per slot), `F14Vector` (entries in a dense array; each chunk slot a
  4-byte index, 12 per chunk so that a chunk is one cache line; erase
  moves the last entry into the hole), and `F14Fast`: Vector when the
  entry is 24 bytes or more, Value below. The post calls F14Fast the most
  used. The object is 24 bytes for Vector, 32 for Value and Node; an empty
  table allocates nothing.
- **Hash.** Low bits pick the chunk, high bits make the tag; a mixer is
  applied unless the hasher is known to spread its bits.
- **Speed.** The post gives no timing numbers, only memory plots.
- **What applies:** F14Fast's rule, a layout chosen at compile time by
  entry size, is exactly the choice [design.md](design.md) makes, with
  order kept in both; the chunk sized to a cache line is how an index of
  tags and 4-byte entry indexes loads in one miss.

### 1.4 Go 1.24 maps

Sources: [the Go blog](https://go.dev/blog/swisstable) and
`src/internal/runtime/maps/map.go`.

- Groups of 8 slots with an 8-byte control word; H1 = the hash's upper
  57 bits, H2 = its low 7. Matching uses SIMD on amd64 and portable bit
  tricks elsewhere; 16-wide groups are listed as future work.
- **Extendible hashing:** a map is a directory of Swiss tables of at most
  1,024 entries each, chosen by the hash's top bits; a full table splits,
  so one insert never copies more than 1,024 entries.
- **Small maps:** a map of at most 8 entries is one group with no table
  or directory: one H2 match and key compares, no probing.
- Deletes leave a tombstone only in a full group; growth clears them.
- **Measured:** map operations up to 60% faster than Go 1.23 in
  microbenchmarks (some regressions), and a geometric mean CPU gain of
  about 1.5% across full applications.
- **What applies:** the one-group small map (Rig's `SMALL` scan already
  does this; Go matches 8 tags at once instead of comparing hashes in
  turn), and the honesty of the 1.5%: a map 60% faster in a microbench
  is a percent or two of a real program.

### 1.5 Boost `unordered_flat_map` (1.81+)

Source: [Joaquín López Muñoz's write-up](https://bannalia.blogspot.com/2022/11/inside-boostunorderedflatmap.html).

- Groups of 15 slots with a 16-byte metadata word: 15 reduced hashes and
  an **overflow byte**. A reduced hash is the hash's low byte, kept in
  2..255 (0 = empty, 1 = the end sentinel), so about 7.99 bits against
  SwissTable's 7.
- On a full group, insert sets bit `h mod 8` of its overflow byte and
  probes on (quadratically over groups); a lookup stops at a group whose
  bit for `h` is 0. No tombstones; an erase in an overflowed group lowers
  the maximum load by one, so a churning table rehashes in time
  ("anti-drift").
- Load factor fixed at 0.875. A post-mixer (`xmx`) is applied unless the
  hash is marked avalanching.
- **Measured** (aggregate ms, GCC 11, Xeon E5-2683): `uint32_t` keys
  4,974 against absl's 6,400 (22% less time); `uint64_t` 5,447 against
  6,530 (17% less); a UUID key 9,223 against 10,559 (13% less);
  `std::string` 14,486 against 13,018 (11% more). Unsuccessful lookups
  take up to 3.2 times fewer comparisons than absl's at high load.
- **What applies:** the overflow bits make misses stop early, which
  matters for Trig's symbol lookups that walk base chains and miss often
  (tsrs found 52% of its symbol lookups rejected by a filter). And the
  numbers say integer and small fixed keys, Trig's keys, are where the
  best map wins.

### 1.6 Python's compact dict (CPython 3.6+, PyPy)

Sources: [Raymond Hettinger's proposal](https://mail.python.org/pipermail/python-dev/2012-December/123028.html),
[PyPy's post](https://www.pypy.org/posts/2015/01/faster-more-memory-efficient-and-more-4096950404745375390.html),
and `Objects/dictobject.c`.

- **Layout.** A sparse index array (`dk_indices`) of entry indexes, whose
  width follows the table: 1 byte to 128 slots, 2 to 2^15, 4 to 2^31, then
  8; and a dense entry array (`dk_entries`) of hash, key, value, in
  insertion order. Text-only tables keep no hash beside the key (the key
  object caches its own).
- Probing: `i = mask & (i*5 + perturb + 1)`, `perturb >>= 5`. The table
  resizes at 2/3 full; growth is `used * 3`.
- **Delete:** the index becomes `DKIX_DUMMY` (never empty again) and the
  entry's key and value become NULL; a resize compacts the entries.
- **Measured:** the proposal's example, 3 entries in 8 slots, is 80 bytes
  against 192; PyPy's 100-entry dict about 2,600 bytes against 4,100
  (37% less), dicts of a few hundred entries built twice as fast, small
  dicts between 20% slower and 20% faster, and its benchmark suite
  "mostly small effect". A cold lookup can cost one more cache miss.
- **What applies:** this is Rig's Map today (dense entries, sparse index,
  deletion by marking, compaction on growth). What Rig does not take
  from it yet: index width by table size, and a key that carries its own
  hash.

### 1.7 indexmap (Rust)

Source: [the README](https://github.com/indexmap-rs/indexmap).

- A hashbrown table of indexes into a `Vec` of entries (hash, key,
  value), "inspired by Python 3.6's new dict". Iteration walks the dense
  entries; lookup uses hashbrown's SIMD tag match on the index and then
  reads the entry, which the README itself calls the slow-ish part.
  `swap_remove` is O(1) and breaks order; `shift_remove` keeps order and
  is O(n). Tried as rustc's map, roughly on par over the whole workload.
- **What applies:** the closest design to Rig's Map that uses a SIMD
  index. Rig keeps order on `take` without a shift by marking and
  compacting later, which indexmap does not offer.

### 1.8 ankerl `unordered_dense` (C++)

Sources: [README](https://github.com/martinus/unordered_dense) and its
[design doc](https://github.com/martinus/unordered_dense/blob/main/doc/design.md).

- Values dense in a `std::vector`; the index is 16-slot groups of 88
  bytes: 16 one-byte fingerprints, 8 overflow counters, and 16 `uint32_t`
  indexes. Erase moves the last value into the hole (so order is not
  kept) and fixes its index with a second lookup.
- **Measured:** iteration about 0.20 ns an element, 5.4 to 13 times the
  flat maps; by `find` alone it is seventh of fourteen maps. The README
  gives the cost of its layout on integer keys as `find` and churn at
  0.73 and 0.59 for boost's flat map, its own time being 1.00: the flat
  map takes about three quarters of the time to find an integer key.
  Probe drift after 200 full turnovers at load 0.80: hits 1.20 groups,
  misses 1.43, against 1.04 and 1.09 fresh.
- **What applies:** the honest price of the dense layout: iteration is
  unbeatable, a hit costs one more miss than a flat map, and that is
  why a flat map wins `find` on integer keys.

### 1.9 Zig's `std.ArrayHashMap` (installed std, 0.17)

- Ordered. Entries in a `MultiArrayList` (keys, values, and hashes in
  separate arrays). No index at all while the capacity is at most a
  cache line's worth of keys or hashes (`linear_scan_max`, 64 bytes over
  the larger); then a robin-hood index whose index width is `u8`, `u16`,
  or `u32` by table size. Removal by swap or by shifting.
- **What applies:** Rig's own toolchain already ships an ordered map with
  narrow indexes and a scan sized to one cache line; bench/hash should
  carry it as a row beside `std.HashMap`.

### 1.10 Tyler Close's deterministic tables (V8's JS `Map`)

Source: [Jason Orendorff's notes](https://wiki.mozilla.org/User:Jorend/Deterministic_hash_tables).

- Bucket heads into an insertion-ordered entry array, each entry chained
  to the next with the same bucket; delete overwrites the key with a
  sentinel. This is how JavaScript's ordered `Map` and `Set` are built.
- Measured there: 1.06 to 2.25 times an open table's memory by size, and
  faster than the open-addressing tables in that test despite longer
  expected chains. Rig's Map is already better than this on memory; it
  is listed because Trig's source language (TypeScript) is ordered the
  same way.

## 2. tsrs, the map Trig races

From the tsrs notes (read-only, the Trig fork's scratchpad):

- hashbrown with FxHash for most maps.
- `PackedMap` for maps keyed by a 128-bit `CacheHashKey`: key and value in
  the slot, packed to 4-byte alignment (20 bytes for the key and a
  4-byte handle, not 24), hashed by the key's own low word (it is already
  an xxh3 output). -0.7% / -1.76% instructions at 1 / 8 checkers.
- Relation cache: one `u64` slot, `key << 6 | result`, for the 99.7% of
  keys that pack into 58 bits; -0.8% instructions.
- Symbol tables: a 24-byte header, 8-byte entries (handle, length, 12
  hash bits) growing 1, 2, 4, ...; a linear search up to 16 entries,
  then a 16- or 32-bit index; a 64-bit Bloom filter in the header that
  rejects 52% of 143M lookups before touching entries.
- hashbrown's `clear` touches every bucket; one deep call made every
  later clear of a pooled map memset its capacity (fixed by
  reallocating; 1.5%).
- Its measurement lesson: hashing was 0.7-1.4% of instructions,
  probing and rehash 2.9-4.7%; misses dominate, not hashing.

Trig's numbers (pup, ts-pattern, one checker, from the Trig fork,
2026-10-24): the Map/Set family is 1,875M self instructions (Map 1,560M,
Set 126M) against tsrs's 842M (hashbrown insert 333M, search 192M,
`reserve_rehash` 91M, plus PackedMap, SymbolMap, and the relation
table): 2.2 times, 1,032M more, the largest Rig-side family. In cycles,
956M against 433M, 28% of the whole gap.

## 3. What makes the fast ones fast

1. **Many candidates per compare.** A 16-byte (x86) or 8-byte (ARM,
   portable) group of tags is matched in one or two instructions; most
   lookups touch one group and compare one key. Rig compares one tag at a
   time, with a branch each.
2. **A high load factor that costs little.** With 16-wide groups,
   probe length grows slowly to 7/8; Rig's linear one-tag probe needs
   its low load (and, by the quadrupling above, gets an even lower one).
3. **One allocation, small header.** absl, hashbrown, boost: one block
   of control bytes and slots; F14Vector's object is 24 bytes. Rig's is
   104 bytes and up to four blocks.
4. **Key and value in the slot for small entries.** A hit is one cache
   line after the tags, whose address the hash gives before the tags
   arrive. F14Fast, boost, hashbrown, and tsrs's PackedMap all do this
   for small entries; indexmap, F14Vector, and Python pay one more miss
   to keep entries dense.
5. **Misses that stop early.** Overflow counts or bits (F14, boost,
   unordered_dense) stop a miss at its home group; tombstones (absl,
   hashbrown, Go) and long linear runs do not.
6. **Small maps without a table.** Go's one-group map, absl's SOO,
   tsrs's 16-entry scan, Zig's cache-line scan.
7. **A hash that is already good is not hashed again.** Boost and F14
   skip their mixers for avalanching hashes; tsrs uses the CacheKey's low
   word as is; CPython reads a string's cached hash.

## 4. What applies to an ordered map

The ordered designs (Python, PyPy, indexmap, Zig's ArrayHashMap,
unordered_dense, Close tables) all keep entries dense in insertion order
and an index beside them: iteration is fast and a hit costs one more
dependent load. The flat designs put entries in the slots, where the
hash puts them, so order needs a separate record.

For Rig's one ordered Map the choice is not either/or, as F14Fast shows:
pick by entry size at compile time. Small entries go in the slots, with
order kept as a List of 4-byte slot numbers; large or owning entries
stay dense, with a SIMD index. Section 1 of [design.md](design.md)
explains why that should not repeat the failed slots experiment.
