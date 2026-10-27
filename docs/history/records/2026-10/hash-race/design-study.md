# Hash race: what the fastest hash tables do, and the map Rig should build (2026-10-26)

A study of five hash tables, read from their source, and of Rig's two
maps, to choose a design that starts in first place on arm64 (the Mac)
and x86-64 (pup). Nothing here is built or benchmarked; another session
builds the harness. Every claim about a design cites the code; every
number is someone's measurement and says whose.

Read with [map-stage/survey.md](../map-stage/survey.md) (the survey of
2026-10-24), [map-stage/design.md](../map-stage/design.md) (its
candidates) and [map-stage/build.md](../map-stage/build.md) (Candidate 2,
packed slots with the order kept as a List of slot numbers, built and
not taken: million-key inserts 70-96% slower and the walk of a million
keys 10.7 times as slow). This study differs from that survey in two
ways: it reads the code rather than the posts, and it adds the 2026
redesign of ankerl::unordered_dense, a dense map with a group index and
overflow counters, which is the closest thing in the field to what
Rig's ordered Map must be.

## Sources

| Table | Version read | Where |
|---|---|---|
| abseil `flat_hash_map` | commit `76a21a99b8c4` (2026-10-26) | `misc/abseil-cpp/absl/container/internal/{raw_hash_set.h,raw_hash_set.cc,hashtable_control_bytes.h,container_memory.h}`, `absl/hash/internal/hash.h` |
| hashbrown | 0.17.1, commit `00c175652a71` | `misc/hashbrown/src/{raw.rs,control/}`; foldhash 0.2.0 from the cargo registry (`foldhash-0.2.0/src/{fast.rs,lib.rs}`) |
| Go `map` | Go 1.27.1 | `$(go env GOROOT)/src/internal/runtime/maps/{map,table,group,runtime_fast64,runtime_faststr}.go` |
| boost `unordered_flat_map` (FOA) | commit `636164f1357c` (2026-06-17), shallow clone | `misc/boost-unordered/include/boost/unordered/detail/{foa/core.hpp,mulx.hpp}` |
| ankerl `unordered_dense` | 5.3.3, commit `7c58a8b7a48e` (2026-10-22), shallow clone | `misc/unordered_dense/include/ankerl/unordered_dense.h`, `doc/design.md`, `doc/benchmarks.md`, `notes/index-design.md` |
| Rig built-in Map | the `hash-race` worktree | `std/__rig_builtin.rig`, `src/runtime.zig` |
| Rig `std.hash` (#685) | `origin/std-hash`, commit `fc964bf5b974` | `std/hash.rig`; the PR body's pup and Mac numbers |

Paths below are relative to those roots. `misc/` is
`/Users/shreeve/Data/Code/rig/misc/`.

## 1. The designs

### 1.1 abseil `flat_hash_map` (SwissTable)

- **Control bytes.** `kEmpty = 0x80`, `kDeleted = 0xFE`, `kSentinel =
  0xFF`, full = `0hhhhhhh` (7 hash bits), each value chosen for one SSE
  instruction (`hashtable_control_bytes.h:170-206`).
- **Group width.** 16 on x86 with SSE2: `Match` is `pcmpeqb` +
  `pmovmskb`, `MaskEmpty`, with SSSE3, is `psignb` + `pmovmskb` because
  `kEmpty` is -128 (`hashtable_control_bytes.h:276-357`). 8 on arm64: `vceq_u8` on a
  64-bit register and one `fmov` to a general register, a mask with one
  `0x80` byte per lane, iterated with `ctz >> 3`
  (`hashtable_control_bytes.h:362-438`). On arm64 the empty, full, and
  empty-or-deleted masks use the portable SWAR group instead of NEON,
  to skip the vector-to-register crossing where no tag compare is needed
  (`hashtable_control_bytes.h:505-517`).
- **H1/H2.** H2 is the top 7 bits; H1 is the whole hash, masked by the
  capacity (`raw_hash_set.h:1032-1037`). A table that is not given
  `absl::Hash` XORs a per-table seed into the hash
  (`container_memory.h:539-552`).
- **Capacity and load.** A capacity is `2^m - 1` and doubles as
  `2n + 1` (`raw_hash_set.h:473-502`). Growth is 7/8 of capacity; up to
  63 slots one slot is left empty (`raw_hash_set.h:510-531`).
- **Probe.** Triangular over groups from H1, in slot units
  (`raw_hash_set.h:1903-1935`). Control bytes are cloned past the end
  (`NumClonedBytes`) so a group read at any slot is 16 bytes.
- **Lookup.** `find_large` loads the group, then prefetches the slot
  array at the group's offset before matching, so the control-byte miss
  and the slot miss overlap; the first match is predicted to hit and the
  first empty to end the probe (`raw_hash_set.h:3640-3668`). Insert is
  the same loop returning the first empty group's mask
  (`raw_hash_set.h:3918-3955`).
- **Erase.** A slot becomes `kEmpty` when no 16-byte window through it
  can have been full (`WasNeverFull`, two group loads and two masks),
  else `kDeleted` (`raw_hash_set.cc:695-713`, `880-897`). A table full
  of tombstones is rehashed in place while it is at most 25/32 full
  (`raw_hash_set.cc:2091-2100`).
- **Small tables.** One slot lives inside the table object (SOO,
  `raw_hash_set.h:457-459`); a capacity-1 table never hashes. A table
  that fits in one group grows by shuffling its control bytes with no
  hashing (`raw_hash_set.cc:1344`, `1955-1975`).
- **Growth.** Allocates `2n + 1`; walks the old groups in order; an
  element found in its first probe group goes to `old_index` or
  `old_index + old_capacity + 1` with no probe and no control-byte read
  of the new table (`TryFindNewIndexWithoutProbing`,
  `raw_hash_set.h:1955-1970`; the walk at `4230-4275`); only probed
  elements are inserted afterwards. The new table is written in order,
  a streaming pattern.
- **Layout.** One allocation: growth info, control bytes, then the slot
  array, keys and values together in each slot.
- **Hash.** Integers: two CRC32 instructions on the seed's halves where
  the target has CRC32 (SSE4.2 on x86-64, which the default x86-64
  target lacks; `__ARM_FEATURE_CRC32` on arm64, which Apple cores have),
  else one folded 64x64 multiply `Mix(state ^ v, kMul)`
  (`hash.h:1051-1056`, `1118-1162`, availability `101-135`). Strings of
  up to 32 bytes: two CRC32 chains and one `Mix` (`hash.h:1234-1295`).
  The seed is the address of a global, so it varies per process under
  ASLR (`hash.h:1555-1565`).
- **Iteration.** Group by group over the control bytes; at 7/8 to 7/16
  load it walks 1.1 to 2.3 slots per element, 16 bytes or more each.

### 1.2 hashbrown 0.17.1 (Rust's `HashMap`)

- **Control bytes.** `EMPTY = 0xFF`, `DELETED = 0x80`, full = top 7
  bits with the high bit clear (`control/tag.rs:9-48`).
- **Group width.** 16 with SSE2 (`pcmpeqb` + `pmovmskb`,
  `control/group/sse2.rs:72-121`); no AVX, because a match is almost
  always in the first 16 slots (`control/group/mod.rs:9-15`). 8 with
  NEON: `vceq_u8`/`vcltz_s8`/`vcgez_s8` on a `uint8x8_t` and one
  `vget_lane_u64`, mask stride 8 (`control/group/neon.rs:5-98`); a
  generic SWAR group elsewhere.
- **H1/H2.** H1 is the hash's low bits (`raw.rs:61-63`); H2 the top 7
  (`tag.rs:34-48`).
- **Probe.** Triangular over groups, in slot units
  (`raw.rs:76-91`).
- **Load.** 7/8; tables under 8 buckets keep one slot free; a small
  table is 4, 8 or 16 buckets (`raw.rs:104-170`, `182-194`).
- **Lookup.** `find_inner` loads a group, walks `match_tag`, predicts
  the compare to succeed and `match_empty` to end the probe
  (`raw.rs:2015-2050`). No prefetch anywhere in the crate.
- **Insert.** One probe finds the key or the first `EMPTY`/`DELETED`
  slot (`find_or_find_insert_index_inner`, `raw.rs:1802-1860`); a table
  under one group may find a slot in the cloned tail and fixes it with a
  second group read (`fix_insert_index`, `raw.rs:1716-1745`).
- **Erase.** The rule abseil has: `EMPTY` when the empty bytes before
  and after the slot leave no full 16-byte window, `DELETED` otherwise
  (`raw.rs:3231-3290`).
- **Growth.** At most half full after counting tombstones out:
  rehash in place (`raw.rs:2991`); otherwise a new table at least
  twice as large, every element hashed again and placed with no
  equality test (`raw.rs:2746-2800`, `2892-2955`).
- **Layout.** One allocation: the buckets, in reverse, then the control
  bytes and `Group::WIDTH` cloned bytes (`raw.rs:219-238`). An empty
  table points at a static group of `EMPTY` bytes, so a lookup in it
  needs no branch (`raw.rs:1505`).
- **Hash.** foldhash `fast`: an integer goes into a 128-bit sponge and
  `finish` does one folded multiply (`foldhash fast.rs:35-47`,
  `114-121`); bytes of up to 16 do two overlapping loads and one folded
  multiply (`lib.rs:240-262`). Per-table random seed.
- **Iteration.** Aligned group loads, `match_full`, a bitmask walk
  (`raw.rs:3654-3680`).

### 1.3 Go 1.27.1 `map`

- **Control word.** A group is 8 slots and an 8-byte control word in
  the same block (`map.go:24-36`; `group.go:246-268`, with keys and
  values interleaved or, under `GOEXPERIMENT=mapsplitgroup`, split).
  `ctrlEmpty = 0x80`, `ctrlDeleted = 0xFE`, full = H2
  (`group.go:20-28`).
- **H1/H2.** H2 is the low 7 bits, H1 the upper 57 (`map.go:202-212`).
- **Group scan.** SWAR on 8 bytes (`group.go:161-176`), an SSE
  intrinsic on amd64 (`cmd/compile/internal/ssagen/intrinsics.go:1413`).
- **Probe.** Triangular over whole groups (aligned, so no cloned bytes)
  (`table.go:1337-1355`).
- **Load.** 7 of 8 slots per group on average (`group.go:20`).
- **Erase.** Empty if the group still has an empty slot, else a
  tombstone (`table.go:478-540`); tombstones go only when a table grows
  (`table.go:1208-1231`) or by a best-effort prune past 10%
  (`table.go:566`).
- **Small maps.** Up to 8 entries are one group with no table; a 64-bit
  key lookup there compares keys directly with no hash
  (`runtime_fast64.go:40-63`); a string lookup compares lengths and the
  first and last 8 bytes before deciding to hash
  (`runtime_faststr.go`, `getWithoutKeySmallFastStr`).
- **Growth.** Extendible hashing: a directory of tables, each at most
  1024 slots (`table.go:20`); a table doubles up to that, then splits
  in two (`table.go:1242-1290`). Growth is incremental in size, so no
  single insert rehashes more than 1024 slots, at the cost of a
  directory load on every operation.
- **Hash.** AES rounds where the CPU has AES, a wyhash-style fallback
  otherwise (`runtime_fast64.go:70-77`), seeded per map.

### 1.4 boost `unordered_flat_map` (FOA)

- **Groups of 15.** A 16-byte metadata word holds 15 reduced hashes and
  an overflow byte (`foa/core.hpp:150-217`). A reduced hash is the
  hash's low byte with 0 and 1 mapped to 8 and 9, so 0 means free, 1
  the end sentinel, and occupied slots keep almost 8 bits:
  a false match is 1 in 254 per slot, against 1 in 128 for 7-bit tags
  (`foa/core.hpp:392-395`, `542-560`).
- **Position.** The group is the hash's *high* bits, `hash >> shift`,
  uncorrelated with the low-byte tag (`foa/core.hpp:815-852`). A hash
  not marked avalanching is mixed with `mulx` first, a folded multiply
  by the golden ratio (`foa/core.hpp:894-913`; `mulx.hpp:106-118`).
- **Overflow byte, not tombstones.** An insert that passes a full group
  sets bit `hash % 8` of its overflow byte (`foa/core.hpp:282-285`,
  `2366-2385`). A lookup stops at the first group whose bit for this
  hash is clear (`foa/core.hpp:275-280`, `1745-1749`), so a miss
  usually ends in its home group even at high load. An erase writes 0
  to the slot's byte and nothing else; when the slot's group shows an
  overflow for its class, the maximum load drops by one, so repeated
  churn rehashes before probes drift long (`foa/core.hpp:2259-2267`;
  the rehash sizing that counters the drift, `2120-2135`).
- **Scan.** SSE2: `pcmpeqb` + `pmovmskb` & `0x7FFF`
  (`foa/core.hpp:220-410`). NEON: a 16-byte `vceqq_u8`, then a movemask
  emulation copied from SIMDe: AND with lane weights, `vzip`, `vaddvq`
  (`foa/core.hpp:423-610`, the emulation at `571-586`).
- **Probe.** Triangular over groups (`foa/core.hpp:867-890`).
- **Load.** 0.875 (`foa/core.hpp:1260`).
- **Lookup.** Match, then prefetch the group's elements (the first line
  on x86, half the group on ARM) before the first key compare; compares
  are predicted to hit, overflow checks to stop
  (`foa/core.hpp:95-127`, `1714-1755`).
- **Layout.** A metadata array (16 bytes per 15 slots) and an element
  array, keys and values together, in one allocation
  (`foa/core.hpp:933-940`).
- **Growth.** A new pair of arrays; every element hashed again and
  placed with no compare (`foa/core.hpp:2287-2320`). No in-place rehash.
- **Iteration.** Over the metadata, `match_occupied` per group
  (`foa/core.hpp:2059-2073`).

### 1.5 ankerl `unordered_dense` 5.3.3 (a dense map with a group index)

- **Values dense.** All entries live in one `std::vector` in insertion
  order until an erase; iteration walks that vector and never reads the
  index (`doc/design.md`).
- **The index.** One array of 88-byte blocks, each 16 one-byte
  fingerprints, 8 one-byte overflow counters, and 16 `uint32` value
  indices (`unordered_dense.h:828-848`, `1505-1513`). The fingerprint
  is the hash's low byte with 0 mapped to 8; its low 3 bits pick the
  counter (`unordered_dense.h:854-868`, `2282-2287`). The group is
  `hash >> shifts`, the high bits (`unordered_dense.h:2220-2222`).
  Max load 0.8 (`unordered_dense.h:2114`).
- **Counters, not bits.** An insert increments its class's counter in
  every full group it passes (`place_group`,
  `unordered_dense.h:2586-2604`); an erase walks the same path and
  decrements them (`uncount`, `unordered_dense.h:2614-2635`). Unlike
  boost's overflow bits, the filter is exact, so churn leaves no drift
  in the filter, only in where entries sit; a counter saturates at 255.
  A miss stops at the first group whose counter is 0, or after every
  group (`unordered_dense.h:2456-2480`).
- **Merged block.** Fingerprints, counters and indices were two arrays
  until 2026-09-06; merged, lookups measured 5.8-8.1% faster, with 7%
  fewer instructions and 28% fewer dTLB misses at 4M
  (`unordered_dense.h:1542-1560`, ankerl's measurement on a Ryzen 9
  7950X).
- **Scan.** SSE2 `pcmpeqb` + `pmovmskb`; NEON `vceqq_u8`, `vshrn_n_u16`
  by 4, one `fmov`: a 64-bit mask with one bit per lane four bits apart,
  the first lane `ctz / 4` (`unordered_dense.h:2329-2365`). On a
  Neoverse N2 that took lookups from 0.91-1.03 to 1.18-1.62 of the
  previous release (`notes/index-design.md:1771-1793`).
- **Prefetch.** While a probe reads a block's fingerprints, it
  prefetches the block's next line, where the value indices are, so
  that miss overlaps the first (`unordered_dense.h:2384-2415`; measured
  as 3 cycles off a hit).
- **Erase.** Clear the fingerprint, uncount, then move the *last* value
  into the hole and find and repoint its slot: two probes per erase,
  and insertion order is lost (`unordered_dense.h:3158-3198`).
- **Drift.** A hit on a writing path moves an entry back to its home
  group when the home has room (`move_home`,
  `unordered_dense.h:2658-2680`).
- **Hash.** `hash_int(x) = mum(x, 0x9E3779B97F4A7C15)`, one folded
  multiply (`unordered_dense.h:302-305`, `498-500`); a hash marked
  avalanching is used as it is (`unordered_dense.h:2202-2218`).
- **Group size.** 11 and 24 slots both lost to 16; the 8 counters and
  16 slots are one choice (`notes/index-design.md:1034-1067`).

### 1.6 Rig's built-in Map (ordered)

`std/__rig_builtin.rig`:

- **Entries.** A `List[Entry[K, V]]` in insertion order, `Entry` holding
  `key: K` and `value: V?` (`:37-39`); emitted as `value:
  rig.Opt(V)`, which is Zig's `?V` for an integer, so a
  `Map[Int, Int]` entry is 24 bytes. Keys over 8 bytes keep their hash
  in a parallel `List[U64]` (`:79-81`).
- **Small path.** Up to 8 entries (`SMALL`, `:43`), no table; a key of
  8 bytes or fewer is compared directly with no hash (`:316-330`).
- **Table.** Two Lists, `tags: List[U8]` and `at: List[U32]` (`:47-49`):
  linear probing one byte at a time, tag `0x80 | h >> 57`, slot from the
  low bits (`:313-347`, `:620-621`). Grown at 4/5 full and rebuilt to
  at most 2/5 (`:353`, `:607-612`), so it runs 40% to 80% full.
- **Take.** The entry's value becomes `none` and the entry stays until
  the next compaction; the slot is freed by backward shift, which finds
  the slot by scanning for `at == j` and recomputes each later key's home
  from `hash_at`, which hashes the key again when no hash is stored
  (`:397-421`).
- **Growth.** Compacts the entries, then rebuilds the table from the
  stored or recomputed hashes (`:365-395`).
- **Hash.** An integer: `fold((w ^ seed) * mul)`, one 64x64 multiply
  (`src/runtime.zig:1970-1974`); an object of integer parts, two words
  per folded multiply (`:1925-1931`); text, Zig's Wyhash
  (`:1945-1947`).

### 1.7 Rig's `std.hash` (#685, unordered)

`std/hash.rig` at `fc964bf5`:

- SwissTable as hashbrown has it: control bytes `EMPTY = 0`,
  `DELETED = 1`, full `0x80 | h >> 57` (`:46-60`); 16 bytes read as
  `Simd[U8, 16]` on both targets (`:39`); triangular probing; 7/8 load
  (`:67-71`); hashbrown's erase rule (`erased_ctrl`, `:118-125`) and
  rehash in place (`p_rehash`, `:602-624`); tables of 1 MiB or more
  grow in place by `mremap` (`:144`, `:565-600`).
- Plain keys and values (`$plain`) keep entries in the slots, a free
  slot holding a copy of some entry (`ps`, `:185`); any other Map keeps
  `List[Bucket[K, V]?]` (`:187`) with out-of-line `find` and `probe`
  (`:634-680`).
- A probe step on arm64 is `(g == tag).bits()` and `(g == EMPTY).any()`:
  `bits()` of 16 lanes lowers to `cmeq`, a constant load, `and`, `ext`,
  `zip1`, `addv.8h`, `fmov` (`src/runtime.zig:4672-4695`,
  `4809-4811`; docs/internals/simd-lowering.md:114, and confirmed for
  this study by disassembling Zig 0.17's `@bitCast` of a 16-lane mask
  for `apple_m1`), and `any()` adds a `umaxv` (`src/runtime.zig:4752-4763`).
  The same compare as a nibble mask is `cmeq`, `shrn`, `fmov`
  (simd-lowering.md:118); 8 lanes are `cmeq.8b`, `fmov`.

## 2. Side by side

| | abseil | hashbrown | Go | boost FOA | ankerl 5.3 | Rig Map | Rig std.hash |
|---|---|---|---|---|---|---|---|
| Ordered | no | no | no | no | until an erase | yes | no |
| Group, x86 | 16 | 16 | 8 | 15 + ofw | 16 | none (scalar) | 16 |
| Group, arm64 | 8 | 8 | 8 (SWAR) | 15 + ofw | 16 | none (scalar) | 16 |
| arm64 scan | cmeq.8b, fmov | cmeq.8b, fmov | SWAR | cmeq, and, zip, addv | cmeq, shrn, fmov | byte loop | cmeq, and, ext, zip1, addv, fmov, + umaxv |
| Tag bits | 7 | 7 | 7 | ~8 | ~8 | 7 | 7 |
| Slot from | low bits | low bits | high 57 | high bits | high bits | low bits | low bits |
| Miss stops at | an EMPTY in the group | an EMPTY | an EMPTY | a clear overflow bit | a zero counter | an EMPTY tag | an EMPTY |
| Erase | EMPTY or tombstone | EMPTY or tombstone | EMPTY or tombstone | one byte, max load drops | uncount, move last | backward shift | EMPTY or tombstone |
| Max load | 7/8 | 7/8 | 7/8 | 0.875 | 0.8 | 0.4-0.8 | 7/8 |
| Bytes a slot of index | 1 | 1 | 1 | 1.07 | 5.5 | 5 | 1 |
| Keys and values | in slots | in slots | in the group | in slots | dense vector | dense List | in slots |
| Prefetch | slots, before match | none | none | elements, after match | index line | none | none |
| Int hash | 2 CRC32 or 1 folded mul | 1 folded mul | AES | 1 folded mul | 1 folded mul | 1 folded mul | 1 folded mul |

## 3. Who leads where, and why

The measured numbers come from two places. #685's `bench/hash` (Rig's
harness; pup is x86-64 Linux, the Mac an Apple M-series; Rust is
hashbrown with FxHasher; keys are `i * c`; hits look keys up in
insertion order). And ankerl's `doc/bench_readme.csv` (Ryzen 9 7950X,
1M entries, each map with its own default hash, random key order).
The reasons are from the code.

| Operation | 16 keys | 1k keys | 100k keys | 4M keys |
|---|---|---|---|---|
| Insert, from empty | **dense or small-array maps**: no table until 9 entries and no chain of rehashes 4, 8, 16, 32 slots (Rig Map 13.0 ns, hashbrown 26.6 on pup); abseil's SOO and hash-free single-group growth come next | mixed: the Rig Map on pup (15.3 ns against hashbrown's 18.1), hashbrown on the Mac (5.6 against 10.5) | **abseil**: growth places home-group entries without probing (ankerl's 1M build: abseil 0.90, boost 1.02, ankerl 1.00) | memory-bound: hashbrown and the Rig Map tie on pup (35.2 ns), hashbrown leads on the Mac (9.3 against 15.9); huge pages are the largest lever (ankerl: 1.7x faster on its integer build) |
| Erase | **boost**, by the code: one byte store, no neighbour reads; hashbrown reads two groups (9.1 ns on pup, the Rig Map 12.5) | **boost** | **boost** (ankerl's churn at 1M: boost 0.59, abseil 0.86, ankerl 1.00) | **boost** |
| Hit | **hashbrown, abseil**: hash, one group, one compare, all in L1 (hashbrown 1.30 ns on pup) | **hashbrown, abseil, boost** | **abseil, boost**: the slot line is in flight with the control line; dense maps wait for the index before the entry | **abseil, boost** (ankerl's 1M find: boost 0.73, abseil 0.75 of the dense map) |
| Miss | **hashbrown** | **hashbrown, boost** | **boost, ankerl**: the overflow filter ends a miss in its home group; 8-bit tags halve false compares | **boost**: 16 bytes of metadata per 15 slots stay in cache longest |
| Iterate | close at this size | dense ties hashbrown | **dense**: a straight walk with no metadata | **dense** (ankerl 0.20 ns an element against boost 1.77 and abseil 2.53 at 1M; Rig Map 1.10 against hashbrown 1.98 at 4M on pup) |

Why, operation by operation:

- **Insert.** From empty, the cost is growth. hashbrown and abseil
  rehash at every doubling; abseil writes its new table in order and
  skips the probe for every element still in its first group, which is
  most of them. A dense map grows its value vector by `memcpy` and
  rebuilds a small index; with string keys it frees in insertion order,
  which ankerl measured as most of its 2.1-2.6x lead on a string build
  and teardown. At 16 keys the winner builds no table at all.
- **Erase.** SwissTable reads 32 control bytes to decide between empty
  and tombstone, and tombstones later cost a rehash. boost writes one
  byte. ankerl walks its counters and then moves the last value and
  re-finds its slot: two probes.
- **Hit, in cache.** All flat designs are a hash, a group compare and
  one key compare; the cheapest hash and the fewest instructions win.
  On arm64, the 8-wide NEON compare (abseil, hashbrown) crosses to a
  general register in two instructions; boost's 16-wide emulation takes
  five or six.
- **Hit, out of cache.** A flat map needs the control line and the slot
  line; abseil issues both at once (prefetch before the match), so a
  hit waits on memory about once. A dense map needs the index block,
  and only then knows which entry line to load: two waits in series.
  ankerl measured that as boost and abseil taking 25-27% less time per
  find at 1M. Go's group keeps control and slots together, one wait,
  but pays a directory load and its type-generic paths.
- **Miss.** SwissTable stops at a group with an empty byte; at 7/8 load
  some home groups have none, and tombstones make it worse. boost's
  overflow bit, and ankerl's counter, stop a miss at its home group
  unless a key of the same class (1 in 8) overflowed it.
- **Iterate.** A flat table walks every slot's metadata and 1.1-2.3
  slots per element. A dense map walks a packed array.

So no one design leads every cell: boost leads erase and misses,
abseil and boost lead hits out of cache, hashbrown and abseil hits in
cache, a dense map iteration and small inserts.

## 4. The design for Rig

### 4.1 (a) The ordered Map: dense entries over a group index

The built-in Map stays dense and ordered and takes ankerl's index,
with one change ankerl cannot make: an order-keeping take, which is
cheaper than ankerl's erase.

- **Entries.** `es: List[Entry[K, V]]` in insertion order. When `K` and
  `V` are plain data (`$plain`), `Entry` holds `key` and `value` with no
  optional: 16 bytes for `Map[Int, Int]`, against 24 today. A taken
  entry is marked in a `gone: List[U64]` bitset, one bit an entry, made
  only at the first take, with a count `dead`. Iteration walks `es`
  straight while `dead == 0` and skips set bits 64 at a time otherwise.
  An owning `K` or `V` keeps today's `V?` value (its key and value must
  be dropped at take time), until the compiler gives owning types a
  niche so `Entry?` costs nothing (§4.3).
- **Stored hashes.** Kept for keys over 8 bytes, as today, so growth
  and compaction rebuild the index without hashing text. (ankerl
  measured a stored hash as worth little for its own growth; the Rig
  Map's String inserts, 40.7 ns against std.hash's 137.7 on pup, say it
  matters here. Measure both.)
- **Small path.** Up to 8 entries, no index; keys of 8 bytes or fewer
  compared directly, with no hash. This path already leads at 16 keys.
- **Index.** An array of 88-byte blocks: 16 fingerprint bytes, 8
  overflow counters, 16 `U32` entry indexes, as one object
  `Block` so the index of slot `i` sits beside its fingerprint. The
  fingerprint is the hash's low byte with 0 mapped to 8; the counter is
  `fingerprint & 7`; the block is `h >> shift`. 16 slots on both
  targets: on arm64 the nibble mask (`cmeq`, `shrn`, `fmov`) makes 16
  lanes cost one instruction more than 8, and 16-slot groups overflow
  far less often (ankerl: 11 and 24 both lost).
- **Probe.** Triangular over blocks. A lookup matches the fingerprint,
  loads `es[idx]` for each candidate, compares, and stops at the first
  block whose counter is zero, or after every block.
- **Insert.** Push the entry; place its index in the first free slot
  from home, incrementing the class counter in each full block passed.
  Inlined into the caller up to the home block; the walk past home and
  growth out of line (`rarely`).
- **Take.** Find; clear the fingerprint; decrement the counters from
  home to the block it was in; set the entry's `gone` bit; drop the
  key and value. No second probe, no move, no rehash of neighbours.
  This is fewer steps than ankerl's erase (which moves the last value
  and re-finds its slot) and close to boost's one-byte erase.
- **Load and growth.** Index at most 0.8 full (ankerl's sweep: above
  0.8 costs, below buys 0.8% for 6.7% more index). When the entries
  List is full and `dead > 0`, compact (keeping order) and rebuild the
  index at the same size; otherwise double the index and rebuild it by
  walking the entries in order, prefetching each target block 16
  entries ahead once the index passes 256 KiB (ankerl's pipelined
  rehash, `unordered_dense.h:2050-2100`).
- **Hash.** Unchanged for integers (one folded multiply). For text, a
  short-string path in place of Wyhash for 16 bytes or fewer: two
  overlapping loads and one folded multiply, as foldhash does
  (`lib.rs:240-262`); Wyhash above that.
- **Prefetch.** As a probe loads a block's fingerprints, prefetch the
  block's second line (the indexes).

Where (a) should stand: first on iteration at every size, on inserts
at 16 keys and on string builds, on misses up to 100k (index only, one
line, filtered), and on take (one probe). It cannot take first place on
hits out of cache: a dense map waits for the index before the entry,
and no layout that keeps the entries dense and ordered removes that
wait (map-stage's packed slots removed it and lost the walk and the
inserts). At 4M, boost's metadata (16 bytes per 15 slots) also stays in
cache longer than an 88-byte block per 16 slots, so boost leads misses
there. So (a) cannot win every cell, and (b) is needed.

### 4.2 (b) The unordered map: FOA groups with a per-target scan

`hash.Map` takes boost's design, which leads erase and misses and ties
abseil on hits, and fixes boost's arm64 scan and prefetch order.

- **Layout.** A metadata array of 16-byte groups (15 tag bytes and an
  overflow byte) and a slot array of 15 entries a group, `{key, value}`
  together, one allocation. For plain `K` and `V` a free slot holds a
  copy of some entry, as #685 does; the tag byte alone says whether it
  is full.
- **Tags.** The hash's low byte with 0 and 1 mapped to 8 and 9: 0
  free, 1 the end sentinel, 2 to 255 full. 1 false compare in 254 per
  slot.
- **Position.** `h >> shift` (high bits), so the tag and the group are
  independent bits of one folded multiply.
- **Overflow.** An insert sets bit `h % 8` of every full group it
  passes; a lookup stops at the first group whose bit is clear.
- **Erase.** Write 0 to the tag; when the group's overflow bit for the
  slot's class is set, lower the maximum load by one (boost's
  anti-drift); size a rehash forced by drift one step up.
- **Scan, x86-64.** `pcmpeqb`, `pmovmskb`, `& 0x7FFF`.
- **Scan, arm64.** `cmeq.16b`, `shrn #4`, `fmov`, `& 0x1111_1111_1111_111`
  (15 lanes), lane = `ctz >> 2`. Build an 8-wide variant (7 slots and
  an overflow byte in 8 bytes: `cmeq.8b`, `fmov`, stride 8) beside it
  and keep whichever the Mac measures faster; the 16-wide form is the
  default because its groups overflow far less.
- **Probe.** Triangular over groups. Max load 0.875.
- **Prefetch.** The slot line's address (`slots + 15 * group`) is known
  from the hash alone: issue the prefetch together with the metadata
  load (abseil's order), not after the match (boost's).
- **Small.** No allocation until the first insert; then one group (15
  slots), doubling. Up to 8 entries with keys of 8 bytes or fewer, the
  hash-free dense scan of 4.1 (Go and the Rig Map both measure this
  path fastest).
- **Growth.** New arrays at twice the groups; walk the old groups in
  order and place each element with no compare. With high-bit
  positions, an element in its home group `g` lands in `2g` or `2g+1`,
  so the new arrays are written nearly in order. Keep #685's in-place
  growth by `mremap` for tables of 1 MiB or more, if it still pays
  peak memory without costing time.
- **Hash.** As 4.1.
- **Hot path.** Lookup and an insert into room inlined; growth and the
  walk past the home group out of line.

Where (b) should stand: level with boost on x86-64, and ahead of it on
arm64, where boost's scan is five or six vector instructions to the
nibble mask's three. Against abseil and hashbrown: ahead on erase and
misses, level on hits. Ahead of every flat map would need the details:
the single-multiply hash with no per-table seed, the prefetch order,
the inlined insert, and huge pages (§4.3).

### 4.3 What Rig's compiler and runtime need

In order of what they likely cost the designs above:

1. **A mask iterated by lane, per target.** A form that lowers to
   `pmovmskb` on x86 and to `cmeq`, `shrn`, `fmov` on NEON, with the
   stride (1 or 4) known when the program compiles: for example
   `for i in m.lanes()` over a 16-lane mask, or a `bits()` with a
   stride. Today a 16-lane `bits()` on arm64 is six instructions and a
   constant load (simd-lowering.md:114), and `first()` alone uses the
   nibble form (`src/runtime.zig:4697-4728`). Every probe step of both
   designs pays this.
2. **Prefetch.** `prefetch` of a List element or slice position
   (Zig's `@prefetch`). Rig has none. Both designs use it on the hot
   path, and the rehash pipeline needs it.
3. **A branch hint inside a function.** `rarely` marks a function cold;
   the probe loop needs "this branch is rare" for the walk past the home
   group and the full-group case, as abseil's `ABSL_PREDICT_*`,
   hashbrown's `likely` and boost's `BOOST_LIKELY` do (for example
   `rarely` as the first statement of an `if` body, lowering to
   `@branchHint(.unlikely)`). A naming question for the owner.
4. **Proven indexes.** An entry index read from the index block, and
   `i & (len - 1)` for a power-of-two length, should need no bounds
   test; #685 works around the second with loop guards. In a safe
   release build the first costs a test per hit. Trig's measurements
   (records/2026-10/safety-checks) put such tests at a few percent.
5. **Free slots for owning types.** A niche in `String` (and objects
   that hold one) so `Bucket[String, V]?` and `Entry?` are the size of
   the bucket, or a safe "slot the tag says is free" form, so owning
   maps get the plain layout.
6. **Zeroed and huge pages.** `List.filled(n, 0)` from fresh zeroed
   pages (`calloc`, or `mmap` for large blocks), so a new table of
   `EMPTY = 0` costs no stores; and `madvise(MADV_HUGEPAGE)` for blocks
   of 2 MiB or more on Linux in `src/alloc.zig`. ankerl measured huge
   pages as its largest gain: integer build 1.7x faster, churn 1.25x,
   find 1.1x.
7. **`ctz` on arm64** is two instructions (`rbit`, `clz`) on cores
   without CSSC; the nibble mask's `>> 2` and a 64-bit mask are free on
   top of that. Nothing to build, but the reason the arm64 group width
   must be measured, not assumed.

### 4.4 What today's code does differently, ranked by the gap it likely costs

The Rig Map against hashbrown, from #685's numbers (time per
operation; "N times as slow" is Rig's time over hashbrown's):

1. **Scalar linear probing with no group compare and no overflow
   filter.** Each slot is a load, two compares and a branch that
   mispredicts at random, and a miss runs to an empty tag. A miss at
   100k keys is 7.8 times as slow on pup (14.33 ns against 1.84) and
   17 times on the Mac (9.88 against 0.57).
2. **Three dependent arrays per hit.** `tags`, then `at`, then `es`,
   each its own List and no prefetch: three waits on memory where a
   flat map has one and ankerl's merged block two. A hit at 100k keys
   is 4.2 times as slow on pup (8.52 against 2.05) and 3.8 times on the
   Mac (4.55 against 1.21).
3. **Take by backward shift.** Finding the slot by scanning for
   `at == j`, then hashing every later key again to find its home
   (no stored hash for keys of 8 bytes or fewer). A remove at 100k
   keys is 3.9 times as slow on pup (39.96 against 10.23) and 8.3 times
   on the Mac (20.05 against 2.41).
4. **`V?` in every entry.** 24 bytes for `Map[Int, Int]` where 16
   would do: growth, compaction and iteration move half again as many
   bytes, and iteration tests each value. It still leads iteration at
   4M (1.10 ns against 1.98 on pup) because it is dense.
5. **An index 40-80% full.** Rebuilt at 2/5 (`table_size`), so the
   index is up to twice the size 0.8 needs; small next to the
   entries, but it is the part a miss touches.

std.hash (#685) against hashbrown:

1. **The arm64 scan.** `bits()` and `any()` on 16 lanes, two reductions
   a group, about nine vector instructions where hashbrown has two:
   a miss at 100k keys is 4.5 times as slow on the Mac (2.56 against
   0.57) and a hit 48% slower (1.79 against 1.21).
2. **Insert and growth.** `p_probe` makes three reductions a group
   (tag, free, empty); growth places every element through
   `insert_slot` with two control-byte writes; small tables start at 4
   slots and rehash at 8, 16, 32. Inserting 1k keys is 3.6 times as
   slow on the Mac (20.17 against 5.58), 46% slower on pup; 16 keys
   2.4 times the Rig Map's time on pup.
3. **SwissTable erase.** Two group loads and two reductions to choose
   empty or tombstone, and tombstones that later force a rehash: a
   remove at 100k keys is 2.2 times as slow on pup and 4.9 times on the
   Mac.
4. **7-bit tags and empty-terminated misses**, where FOA has about 8
   bits and an overflow filter: twice the false compares, and misses
   that walk on from a home group with no empty byte.
5. **Owning keys.** `Bucket?` slots, out-of-line `find`, and no stored
   hash, so growth hashes every String again: a million String inserts
   take 137.7 ns each against the Rig Map's 40.7 on pup.

## 5. A fair benchmark: the table apart from the hash

1. **Time the table with the hash taken out.** Give every table the
   same hash, written the same way in each harness: Rig's `hashWord`
   (one folded multiply) as a Rust `Hasher`, a C++ functor, and Rig's
   own. Mark it avalanching for boost and ankerl, which otherwise mix
   it again (`foa/core.hpp:1429-1433`; `unordered_dense.h:2202-2218`).
   abseil XORs a per-table seed into any hash not `absl::Hash`
   (`container_memory.h:551`), one instruction; say so. Go's hash
   cannot be replaced: Go belongs only in the default-hash panel. For a
   table-only panel, also run keys that are already random 64-bit
   values with an identity hash, so no hash is computed at all.
2. **A second panel with each table's own default hash**, and a third
   that times the hashes alone on the same keys (integers, and strings
   of 4 to 64 bytes in mixed lengths). The table time is never the
   default-hash time minus the hash time: the two overlap in the
   pipeline.
3. **Keys that scatter.** Random 64-bit keys, not `i * c`: FxHash of an
   arithmetic progression is an arithmetic progression, which a
   prefetcher follows (the #685 README says so). Add small sequential
   integers as a second set, hashed.
4. **Lookups in random order.** Today's hit loop walks keys in
   insertion order, which hands a dense map its entries in sequence:
   that is likely why the Rig Map's hit at 4M (19.0 ns) beats std.hash's
   (23.5) on pup. Shuffle the lookup keys once, outside the timing.
5. **Throughput and latency both.** Independent lookups (what the
   loops measure today) let the core overlap misses; a dependent chain
   (the next key comes from the value found) measures one wait on
   memory, where dense and flat maps rank differently (ankerl's
   `doc/benchmarks.md` reports the ranking changes in a dependent
   chain at 1M entries).
6. **Hit rates that vary.** 0%, 50% and 100% hits, mixed at random, so
   a branch predictor cannot learn the outcome.
7. **Sizes inside each octave.** A load factor is a sawtooth between
   doublings and maps double at different sizes; ankerl measured one
   point per octave as moving a cross-family ratio by up to 26%. Time
   several sizes per doubling (16, 1k, 100k, 4M and points between) or
   compare at matched load.
8. **Churn.** Erase-then-insert at a fixed size for many turnovers,
   since tombstones and drift appear only after several.
9. **Build with and without `reserve`, with teardown counted.** A
   dense map frees owning keys in insertion order, which is most of its
   string-build lead.
10. **Larger values.** An 8-byte value hides what a dense map buys; add
    a 64-byte value.
11. **Same allocator and pages.** Rig release builds use Rig's
    allocator; Rust, C++ and Go use theirs. Either give each the same
    allocator or report it, and run every table with the same
    transparent huge page setting.
12. **Hygiene.** One binary per table (moving code shifts a hot loop
    by 5-7% on Apple cores, and ankerl found a binary holding a dozen
    maps moves more than the differences it measures); a pinned core with its sibling
    idle on pup; runs interleaved; fastest of N; the same LLVM major
    version where it can be had; no PGO; memory as peak RSS and as
    bytes requested.

## 6. Owner questions, with defaults

1. **Build (a) into the built-in Map?** Default: yes, behind the same
   members, with Trig's light gate and std.json's guard as the bar.
2. **Build (b) into `std.hash` in place of #685's SwissTable?**
   Default: yes, on the same branch, keeping #685's members and tests.
3. **The mask-lane form (§4.3, 1).** Default: `for i in m.lanes()` on a
   mask, with no stride in the source; the compiler picks it per target.
4. **A branch hint inside a function (§4.3, 3).** Default: `rarely` as
   the first statement of a branch.
5. **`prefetch` (§4.3, 2).** Default: `xs.prefetch(i)` on a List or
   slice, a no-op where a target has none.
6. **Huge pages for large blocks (§4.3, 6).** Default: on, Linux only,
   for blocks of 2 MiB or more, measured on Trig's peak memory first.
