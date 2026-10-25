# The Map/Set stage: how a candidate is judged, 2026-10-24

A candidate ([design.md](design.md)) is kept only if real Trig is faster
with it. A microbenchmark finds the candidates; Trig's own op stream
filters them; Trig itself decides. The slots experiment is why: it was
faster on cold lookups and 12% slower on ts-pattern.

## 1. Trig's traces

The Trig fork will record the map operations of ts-pattern with one
checker, for the four workloads: the relation cache
(`relation_results`, `Map[CacheKey, U32]`), the instantiation cache
(`instantiations`, `Map[InstantiationKey, TypeId]`), the symbol tables
(`tabs`, `Map[ast.Atom, Sym]`), and the mapper caches
(`active_type_mappers_caches`, `Map[CacheKey, TypeId]`, pooled).

### The format (proposed to Trig)

One binary file per run, little-endian, written by a recording build of
Trig (a flag on the Map wrapper Trig owns, or an env var in a Trig-side
shim; no Rig change):

```
header   "RIGMAPT1", then a U16 count of kinds
kind     U8 id, U8 key bytes, U8 value bytes, U16 name length, name
         ("relation", "instantiation", "symbols", "mapper")
record   U8 op, U8 kind, U32 map, key (the kind's bytes), U64 value, U8 result
```

`map` is a number per map value, stable for its life (a pooled mapper
cache keeps its number through `clear`). `op` is one of `new`, `drop`,
`get`, `has`, `edit`, `put`, `put_new`, `replace`, `ensure`,
`ensure_with`, `take`, `clear`, `reserve` (value = n), and `iter`
(value = entries walked). `result` is 1 for a hit (or a key already
there), 0 for a miss (or a new key). Keys are the real bytes: a
`CacheKey`'s two words, an `InstantiationKey`'s three, an `Atom`'s
number, so the hash sees the real distribution. A text dump (`op map key
value result`, one a line) is for reading, not timing.

Trig sends with it, per kind: the op counts, the hit rate by op, the
maps' final sizes as a histogram, and whether any map of that type is
ever iterated.

### The replay program

`bench/hash/replay.rig`, beside `map.rig`, and driven by `bench-hash`
like the other variants:

- Reads the whole trace into Lists before the clock starts, and builds
  the key objects (`CacheKey`, `InstantiationKey`, `U32` atoms) there.
- Runs the records in order on real `Map[K, V]` values, one List of
  maps per kind indexed by `map`, so lifetimes, pooling, `clear`, and
  the mix of sizes are Trig's.
- Checks every `result` against the trace and fails on the first
  difference: a candidate that answers differently is wrong, whatever
  its time.
- Times each kind alone and all four interleaved as recorded, and
  reports per kind and per op family (lookups, inserts, writes, clear,
  growth), plus peak RSS and the bytes the maps hold at the end.
- `--stats` prints the trace's own shape without timing: op mix, hit
  rate, size histogram, how often a lookup is for a key put in recently
  (the locality the dense layout has and packed slots lose), and how many
  entries each map holds when it grows.

A replay has a warmer cache than Trig, which does checker work between
map operations. It filters; it does not decide. A `--pollute KB` option
reads that many kilobytes of a separate buffer between records, to bound
how much a candidate's win depends on a warm cache; the default is off.

The same trace is replayed by small programs over the maps the survey
names, so "within 5% of the best map in any language" is judged on
Trig's operations, not on each author's benchmark:

| Program | Maps |
|---|---|
| `replay.rig` | the candidate's built-in Map |
| `replay.zig` | Zig's `std.HashMap` and `std.ArrayHashMap` (ordered), as bench/hash has Zig's |
| `replay.rs` (outside the suite) | hashbrown with FxHash, indexmap, and tsrs's PackedMap shape |
| `replay.cpp` (outside the suite) | `boost::unordered_flat_map`, `absl::flat_hash_map` |

Ordered maps are compared with ordered maps (indexmap, ArrayHashMap)
and all maps with the fastest; both rows are reported.

## 2. bench/hash

Its rows stay the guard for maps Trig does not exercise: a million
`Int` and `String` keys, insert, hit, miss, iterate, the three
write-or-insert forms, and the small maps of 4 and 8. A candidate may not
make a row slower beyond noise except as recorded and accepted by the
owner (design.md §8, question 4: iteration of a huge packed map).

Two lessons carried from earlier records:

- Rows of many small maps measure the allocator's placement as much as
  the Map ([compact-map](../compact-map/README.md): one row moved 28%
  slower or 27% faster by whether the harness reserved its List of
  maps). Run them both ways.
- bench/hash swings 20% between runs of the same binaries on a loaded
  Mac ([len-and-map-notes.md](../safety-checks/len-and-map-notes.md)).
  Use pup's quiet P-core for anything under 5%.

## 3. How every run is taken

- **Both machines.** pup (x86, Core Ultra 9 185H) on P-core 6 with its
  sibling 7 idle, release builds through Trig's slot lock with 12 GB
  free; the Mac (arm64) for the NEON group width, its load noted. Never
  burst.
- **Interleaved, fastest of N.** Baseline and candidate alternate, order
  rotated each round; N at least 11 for the replay and bench/hash, 10 to
  15 for Trig; the fastest of each counts, and the paired per-round
  differences and their median are reported beside it.
- **Exclusive time.** Nothing else heavy on the machine (the census rule);
  a run whose sibling core was busy is dropped, and the share dropped is
  reported.
- **Counters first on pup.** `perf stat -e instructions:u,cycles:u` for
  every Trig run; instructions are deterministic to well under 1%, cycles
  and time confirm. Two builds of identical source differ by up to 2% in
  time from layout alone (R4's 32-byte shift), so a time difference
  under 2% without an instruction or cycle difference is noise.
- **Peak RSS** from `/usr/bin/time -v` (pup) and `-l` (Mac), and the
  maps' own bytes from the replay, both sides.
- **Same source directory, same profile** for both sides, built by the
  same `bin/rig` but for the std file under test, so only the Map
  differs.
- **Output identical.** Every Trig run's output is compared with the
  baseline's, byte for byte.

## 4. Order of judgment for each step

Each step of design.md §7 goes through these gates in order, and stops
at the first it fails; a stopped step is recorded under
`docs/history/records/` as tried and not landed, with its numbers:

1. **Replay, `--stats` first:** the share the step targets is above the
   bar (measure the share first). A step whose targeted ops are under 1%
   of the map family's cycles is not built.
2. **Replay, timed:** faster on the workloads it targets on both
   machines, and no workload slower beyond noise.
3. **bench/hash:** no row slower beyond noise but those the owner
   accepted.
4. **Real Trig:** ts-pattern, zod3, tiny-invariant, and superstruct on
   pup, fastest of 10 or more, output identical: kept when it meets
   Trig's speed bar (more than 2% faster in time, or at least 1% fewer
   single-thread instructions) with peak RSS no higher; then Trig's light
   gate (release build, 6 projects identical). The Mac confirms the
   direction.
5. **Correctness:** the suite green under `RIG_SANITIZE=1`, the oracle
   with no new disagreement on Trig, and the Map's doc examples.
6. **After merge:** the speed baseline and census on main, per "no late
   slowdowns"; a regression over 2% anywhere is bisected before more
   lands.

## 5. What is asked of Trig

1. The four traces of ts-pattern with one checker, in the format above
   (or one Trig prefers, with the same fields), and the per-kind counts.
2. The same for zod3, smaller, as a second shape.
3. A Trig build against a candidate's std when a step reaches gate 4,
   timed by Trig on its slot as Trig times its own changes.
