# zig-ordered: the ordered Map's Zig prototype (2026-10-27)

`bench/hash/ordered.zig`, the design Rig's built-in `Map` will take:
the panel's design (a) ([panel/design.md](panel/design.md) §1), built,
then tuned row by row. Each experiment below is recorded with its
numbers, kept or dropped. Times are ns per operation, the fastest of N
interleaved runs. Other agents shared both machines most of the day:
the Mac's load ran from 3 to 23, and on pup another agent's benchmarks
ran on core 0, which shares L3 with core 1. Read a gap under about 5%
in one run as a tie.

## Summary

- **Leads every ordered map** (Rig's current Map, ankerl in C++ and
  Zig, indexmap) on 42 of 84 rows on the Mac and 26 of 84 on pup, and
  is first of the whole field on 19 and 18. It wins outright at 16
  keys on both machines (insert, miss, churn, big values), churn100000
  on both, every big-value remove on the Mac, and the 3M insert on pup.
  (Memory on pup is from the discarded 04:39 run; contention does not
  change peak memory.)
- **Memory:** 37.1 bytes an entry at 4M Int keys on the Mac (Rig's
  current Map 39.7, ankerl 55.8) and 26.6 on pup (38.3, 30.7).
- **The Rig-shaped variant** costs 2-7% on most lookup rows, up to 13%
  in cache, under 1% by geometric mean over all rows (experiment 12).
- **Cannot win here:** lat16 and lat1000 (Rig's predicted byte probe),
  the out-of-cache hits and chain against flat maps, iteration on x86
  (a Zig toolchain gap), the 4M miss (the slot prefetch's price).
- **Harness:** the text rows are mostly the harness's: with each text
  allocated once, zig-ordered's text rows roughly halve and it leads
  most of them (experiment 6).
- **Open:** inserts at 1,000-150,000 (8-17% behind zig-dense), in-cache
  hits and misses on x86 (7-20% behind ankerl and indexmap), mix100000.

## What was built

- **Entries.** One allocation: `cap` entries in first-put order,
  `{key, value}` with no optional (16 bytes for Int to Int), then one
  gone bit an entry. A key over 8 bytes also keeps its 64-bit hash in
  its entry (32 bytes for a `[]const u8` key and an Int).
- **Index.** One allocation: `G` groups of 16 tag bytes (15 tags and
  boost's overflow byte), then, on a 64-byte line, 16 `u32` entry
  indexes per group. The group is `h >> shift` and the tag is the low
  byte, 0 made 1. A lookup prefetches its slot line along with its tags. The home
  group is probed inline; the walk past it is out of line in a lookup
  and inline in a take.
- **Take.** One probe; the tag is cleared, the gone bit set, and the
  maximum load lowered when the overflow bit for the tag's class is set
  (boost's anti-drift). Taking the last entry cuts it off along with any
  gone entries before it; taking the last live entry empties the map
  and keeps its memory.
- **Compaction.** When an append finds the array full and at least a
  quarter gone: live entries move down by gone words, and every slot
  is renumbered by a rank (gone entries below it), with no hash and no
  probe. When the index grows, the rebuild drops gone entries in the
  same pass. A drift-forced rebuild sizes the index at most 0.6 full.
- **Small maps (up to 16 entries).** No index: a 16-byte tag vector
  in the map itself, whose lane `i` is entry `i`'s tag (0 when gone or
  unwritten). A lookup is one 16-lane match and a direct entry read. A
  take clears the lane and sets the gone bit. A full small map with one
  gone entry shifts the rest down by one (entries and tags), and with
  several gone it compacts. At the 17th live key the index is built,
  sized for the entries' next capacity.
- **Iteration.** A cursor of runs: with no gone entries, one counted
  loop over the array (LLVM unswitches the hole test out of the loop);
  otherwise runs of live entries found by count-trailing-zeros over the
  gone words.
- **`Ordered(K, V, Ctx, .{ .checked = true })`**, the Rig-shaped
  variant: each entry index read from the index is tested against the
  entries written, each prefetch is range-tested, the home group is
  masked (`& (G - 1)`, which Rig's planned proof covers), each step of
  a walk tests its index, each small-map lane is tested against `len`,
  and the walk past the home group stays inline (experiment 12).

Tests (`zig test bench/hash/ordered.zig`, Debug and ReleaseSafe, both
pass): random operations against a model that keeps the live keys in
first-put order and checks the whole order every few thousand steps,
with Rig's Int hash and with a hash that crowds keys into a few groups
and classes; the small path at 8 and 16 entries and back from empty; a
re-put keeping its place; churn at 16, 1,000 and 50,000 keys (index and
array stay bounded, order holds) for both variants; churn with random
victims under the crowding hash; growth to 200,000 big values, every
third taken, the array filled until it compacts in place (index size
and capacity unchanged), order and values checked; text keys owned by
the map, found by equal texts made apart, freed through `keyIterator`
with none freed twice (the test allocator checks); and walks over runs
of holes of every length. `verify()` checks counts, gone bits, one
lane per live entry, tags, and the overflow bit of every group a key
walked past.

## Experiments

### 1. The slot prefetch (kept: always)

Issue `prefetch(slots[g])` with the tags load never, only when the
index is over 1 MiB ("far"), or always.

| row | Mac far | Mac always | Mac never | pup always | pup far | pup never |
|---|---|---|---|---|---|---|
| lat100000 | 19.02 | 17.00 | 19.13 | 16.51 | 19.46 | 19.24 |
| rnd100000 hit | 2.51 | 2.23 | 2.42 | 3.91 | 4.19 | 4.23 |
| rnd4000000 hit | 12.79 | 12.51 | 15.28 | 34.37 | 34.44 | 41.20 |
| rnd4000000 remove | 27.07 | 25.01 | 42.06 | 26.22 | 25.77 | 29.47 |
| rnd4000000 miss | 4.55 | 4.34 | 3.93 | 10.26 | 10.45 | 8.65 |
| rnd1000 hit | 1.28 | 1.29 | 1.24 | 1.75 | 1.77 | 1.70 |

Always wins hits, removes and the 100k chain at every size it matters,
costs the 4M miss 10-19%, and is free in L1.

### 2. The small path (kept: flat tags to 16)

The panel's small path compares the keys themselves, with no hash: up
to 8 entries (`base`), 16 compared at once into a mask (`s16m`), or one
at a time to the first match (`s16s`). Replaced by a 16-byte tag
vector whose lane `i` is entry `i` (`t16`). Mac, quick harness:

| row | base (8 keys) | s16m | s16s | t16 |
|---|---|---|---|---|
| rnd16 insert | 10.55 | 4.29 | 4.26 | 2.73 |
| rnd16 hit | 1.15 | 2.05 | 2.59 | 0.94 |
| rnd16 miss | 0.98 | 2.13 | 4.60 | 0.54 |
| mix16 | 1.12 | 2.03 | 3.50 | 0.73 |
| lat16 | 8.98 | 5.10 | 2.55 | 8.27 |
| big16 insert | 15.02 | - | 7.77 | 6.39 |
| big16 hit | 1.26 | - | 2.95 | 0.93 |

Comparing 16 keys costs more than hashing once and matching 16 tags.
The scalar scan takes lat16 (a branch predictor that learns the
16-step cycle) and loses every throughput row by 2-8 times; dropped.

### 3. The walk past the home group out of line (kept)

With the whole probe inlined, x86 ran out of registers in the lookup
loop and spilled the shift, tags and slots bases. Moving the walk past
home into a cold, out-of-line call (as ankerl does for slice keys)
gave pup, quick harness:

| row | inline | out of line | zig-dense |
|---|---|---|---|
| rnd1000 hit | 1.78 | 1.55 | 1.66 |
| rnd100000 hit | 4.04 | 3.69 | 3.77 |
| rnd150000 hit | 4.66 | 3.97 | 4.27 |
| rnd150000 remove | 7.27 | 6.56 | 7.37 |

### 4. Maximum load 0.8 (dropped; 0.875 kept)

At 100,000 keys the index is 0.81 full (just under 0.875 of 8,192
groups), ankerl's 0.76. At 0.8 it doubles to 16,384 groups. pup:

| row | 0.875 | 0.8 | zig-dense |
|---|---|---|---|
| rnd100000 miss | 3.32 | 1.99 | 2.77 |
| rnd100000 hit | 3.69 | 3.50 | 3.77 |
| mix100000 | 7.86 | 6.64 | 7.79 |
| rnd100000 remove | 7.85 | 10.89 | 6.97 |
| rnd100000 insert | 14.01 | 16.10 | 14.43 |
| rnd150000 insert | 14.10 | 12.74 | 14.83 |

It moves the cost from misses to removes and inserts at that one size,
and it changes the table only between the bench's sizes.

### 5. A short-text hash (inconclusive; Wyhash kept)

Decision 8's candidate: up to 16 bytes, two overlapping reads and two
folded multiplies; 17 to 32 bytes, two folded multiplies in parallel
and one to combine; Wyhash above. pup, quick harness:

| row | Wyhash | short hash |
|---|---|---|
| str16 insert | 28.84 | 24.46 |
| str1000 hit | 7.39 | 6.66 |
| str1000 remove | 25.05 | 27.03 |
| str100000 miss | 19.12 | 15.14 |
| str1000000 miss | 28.29 | 22.50 |

Under today's harness the text rows are dominated by where the texts
lie (experiment 6). Measure it again after that is fixed.

### 6. The harness's texts (a harness change, asked of the prover)

`map.zig`'s `text()` builds each text with `allocPrint`, which
allocates the format's 7 bytes, grows, and shrinks, so each text takes
several allocations and the texts end up scattered among freed chunks.
`texts()` also fills `put` and `take` (and `hit` and `miss`)
alternately. `map.rs` allocates each `String` once and fills each
array in turn. A scratch copy of map.zig with
`gpa.dupe(u8, bufPrint(...))` and the arrays filled apart, on pup:

| row | zig-ordered | same, texts fixed | zig-dense | same, texts fixed |
|---|---|---|---|---|
| str16 insert | 27.77 | 13.57 | 39.93 | 21.53 |
| str100000 hit | 57.94 | 25.17 | 52.02 | 23.84 |
| str100000 miss | 19.16 | 6.88 | 12.93 | 6.11 |
| str100000 remove | 47.58 | 25.47 | 49.04 | 27.44 |
| str1000000 miss | 26.65 | 10.69 | 23.16 | 13.57 |

The same on the Mac, fastest of 3:

| row | zig-ordered | same, texts fixed | zig-dense | same, texts fixed |
|---|---|---|---|---|
| str16 insert | 17.09 | 5.24 | 37.08 | 12.55 |
| str1000 insert | 27.07 | 13.83 | 31.07 | 13.33 |
| str100000 insert | 23.62 | 9.98 | 31.14 | 11.59 |
| str100000 hit | 15.64 | 8.08 | 14.90 | 8.56 |
| str100000 miss | 7.36 | 4.27 | 7.46 | 4.04 |
| str1000000 miss | 15.87 | 5.46 | 17.15 | 6.58 |

Every Zig contestant's text rows roughly halve; today they race the
Rust and C++ programs with a handicap the tables do not cause. Against
the final Mac run's rivals (below), zig-ordered with the texts fixed
would lead str16, str1000 and str100000 insert (dense-mix 14.49, 15.36,
13.77), str100000 hit (hashbrown-mix 8.16, indexmap-mix 10.46) and
str100000 miss (dense-mix 5.14).

### 7. Iteration on x86 (a toolchain gap)

Zig 0.17's LLVM does not vectorize or split the reduction of even
`for (xs) |x| t += x` over `[]i64` at `-mcpu=meteorlake` or
`x86_64_v3`: one serial add a cycle, eight unrolled. Every Zig map
walks at 0.21 ns an entry on pup (zig-dense too); clang 21 vectorizes
`dense`'s walk to 0.11. Neither a pointer cursor nor separate key and
value arrays changed the code. On the Mac the same loop runs four
accumulators, and the walk ties dense and indexmap at 0.08-0.09.

### 8. The latency chain at 16 and 1,000 (conceded to Rig's current Map)

Rig's current Map takes lat16 and lat1000 (Mac 2.3-2.9 and 4.7; pup
4.3 and 4.3) with a byte-at-a-time probe whose tag compare is a
predicted branch: the core loads the slot and the entry while the tag
is still in flight. Any group match puts the vector compare, the move
to a general register and the count-trailing-zeros on the chain (Mac
7.8-9.2; zig-foa and zig-dense 8.4-9.6). The only form that won lat16
here, the scalar scan, lost every throughput row (experiment 2).

### 9. Turnover in a small map (kept: 32 written, 16 live)

A full 16-entry small map compacted on every turnover step: churn16
6.23 on the Mac, against zig-dense's 5.82. A shortcut for exactly one
gone entry (shift the rest down one, the tags as a 128-bit shift) made
it 14.29: a 16-byte tag write followed by the next lookup's vector read
of the same bytes. Dropped. Kept: a small map may write up to 32
entries (two tag vectors) while it holds at most 16, so a turnover
appends and compacts once every 16 takes. A lookup matches the second
vector only when more than 16 are written; that test needs
`@branchHint(.unlikely)` or LLVM puts the second match on every miss's
path. Mac, quick harness, fastest of 5:

| row | 16 lanes | 32 lanes | 32 lanes, unlikely |
|---|---|---|---|
| churn16 | 6.25 | 3.42 | 3.56 |
| rnd16 remove | 4.70 | 3.93 | 3.97 |
| rnd16 miss | 0.49 | 0.84 | 0.50 |
| rnd16 hit | 0.87 | 0.87 | 0.88 |
| mix16 | 0.69 | 0.70 | 0.70 |

### 10. The index built at the 17th key (kept: sized for 32)

Built for the 17 entries it then held, the index had 2 groups, 0.8
full at 24 keys, and a lookup often walked past home: rnd24 miss 0.92
against zig-dense's 0.81 (Mac, full run). Built for the entries' next
capacity (32), it has 4 groups: rnd24 miss 0.87, hit 1.07.

### 11. Memory

Peak bytes an entry for one map of 4,000,000 Int keys (`--mem`), Mac:
zig-ordered 37.1, Rig's current Map 39.7, dense 55.8, indexmap 60.1,
boost 67.1, hashbrown 71.4. At 4M the entries take 16 bytes (a 2^22
array, 4.19M slots), the index 10 bytes (2^19 groups: 8 MiB of tags,
32 MiB of slots), the gone bits 1/8 byte; the peak comes when the index
grows at 3.44M keys while the old one is still held. The panel's 34
would need the index's spare `u32` a group dropped (60-byte slot
lines) or a smaller index peak; neither was tried.

### 12. The Rig-shaped variant's cost

First measured with the walk past home out of line, as the plain
variant has it, the checked variant cost 20-31% on lookups (Mac,
rnd1000 hit 1.28 to 1.53, rnd4000000 hit 12.33 to 16.13). The tests
themselves were not the cost: the out-of-line walk can now panic, so
LLVM no longer infers it only reads memory, and after it the loop
reloaded the map's six fields and kept the small/index test, on every
lookup. With the walk inline in the checked variant (its panics are
no-return exits, which do not block hoisting), what remains is the
mask and one compare a candidate. Mac, quick harness, fastest of 5:

| row | plain | checked, walk out of line | checked, walk inline |
|---|---|---|---|
| rnd16 hit | 0.89 | 0.95 | 0.94 |
| rnd16 miss | 0.51 | 0.84 | 0.52 |
| rnd1000 hit | 1.13 | 1.40 | 1.21 |
| rnd1000 miss | 1.01 | 1.14 | 1.06 |
| rnd150000 hit | 1.91 | 2.23 | 1.94 |
| rnd4000000 hit | 11.47 | 15.18 | 11.92 |
| rnd4000000 miss | 4.27 | 4.88 | 4.28 |
| big1000 hit | 1.16 | - | 1.31 |
| lat100000 | 16.60 | - | 16.79 |

So the tests safe Rig keeps cost 2-7% on most lookup rows and up to 13%
(big1000 hit), over decision 10's 2%. A lesson for the emitter: a cold
helper that can panic, called from a hot loop, costs more than the
tests do.

### 13. Superblocks (dropped)

Four groups' tags on one line, then their four slot lines (320 bytes),
so a hit's two index lines share a page. Mac, quick harness:

| row | split | superblocks |
|---|---|---|
| rnd1000 hit | 1.23 | 1.49 |
| rnd1000 miss | 1.10 | 1.36 |
| rnd150000 hit | 2.14 | 2.53 |
| rnd4000000 hit | 12.37 | 14.78 |
| rnd4000000 miss | 5.04 | 6.27 |
| rnd4000000 remove | 27.88 | 27.08 |
| lat4000000 | 211.32 | 209.27 |

The extra address arithmetic costs more than the shared page gives, and
misses read tags spread over five times the bytes.

### 14. No separate live count (dropped)

Keeping only `len` and `dead` (live = `len - dead`) saves a store an
insert. Mac, quick harness, fastest of 5: every row within noise
(rnd1000 insert 9.69 and 9.73, rnd100000 hit 2.21 and 2.12, churn16
3.62 and 3.68). Not worth the change.

## The Mac, final (2026-10-27 04:10)

`bench-hash --reps 5 --mem`, every Zig contestant on libc malloc; the
ordered rivals are Rig's current Map (`rig-fast`), `zig-dense`,
`dense` and `dense-mix` (ankerl), and `indexmap(-mix)`. The rest are
`boost-mix`, `zig-foa`, `hashbrown-mix`, `rust` (std + Fx) and
`absl-mix`. The `int` rows, strided keys, are left out as bench-hash's
scoreboard leaves them out. A tie counts as a lead. Load 3.4-3.6.

| row | zig-ordered | best ordered rival | best of the rest | place |
|---|---|---|---|---|
| rnd16 insert | 2.30 | rig-fast 7.59 | zig-foa 7.29 | first |
| rnd16 remove | 4.03 | zig-dense 6.44 | zig-foa 4.33 | first |
| rnd16 hit | 0.94 | rig-fast 0.98 | rust 0.75 | leads ordered |
| rnd16 miss | 0.59 | indexmap 0.60 | indexmap 0.60 | first |
| rnd16 iterate | 0.13 | zig-dense 0.10 | zig-dense 0.10 | +30% to zig-dense |
| rnd24 insert | 9.70 | dense-mix 9.54 | zig-foa 7.24 | +2% to dense-mix |
| rnd24 remove | 5.12 | zig-dense 6.69 | zig-foa 5.14 | first |
| rnd24 hit | 1.18 | indexmap-mix 1.11 | rust 0.78 | +6% to indexmap-mix |
| rnd24 miss | 0.92 | zig-dense 0.86 | zig-dense 0.86 | +7% to zig-dense |
| rnd24 iterate | 0.12 | zig-dense 0.09 | zig-dense 0.09 | +33% to zig-dense |
| rnd1000 insert | 9.87 | zig-dense 8.43 | zig-dense 8.43 | +17% to zig-dense |
| rnd1000 remove | 3.52 | zig-dense 4.38 | zig-foa 3.05 | leads ordered |
| rnd1000 hit | 1.21 | indexmap 1.11 | rust 0.85 | +9% to indexmap |
| rnd1000 miss | 1.20 | indexmap-mix 0.97 | absl-mix 0.96 | +24% to indexmap-mix |
| rnd1000 iterate | 0.09 | indexmap 0.08 | indexmap 0.08 | +12% to indexmap |
| rnd1500 insert | 8.12 | zig-dense 7.52 | zig-dense 7.52 | +8% to zig-dense |
| rnd1500 remove | 4.11 | zig-dense 4.77 | zig-foa 3.06 | leads ordered |
| rnd1500 hit | 1.45 | indexmap 1.26 | rust 0.91 | +15% to indexmap |
| rnd1500 miss | 1.00 | indexmap-mix 1.19 | zig-foa 1.06 | first |
| rnd1500 iterate | 0.09 | indexmap 0.08 | indexmap 0.08 | +12% to indexmap |
| rnd100000 insert | 6.31 | zig-dense 6.72 | zig-dense 6.72 | first |
| rnd100000 remove | 5.09 | dense-mix 5.90 | zig-foa 3.43 | leads ordered |
| rnd100000 hit | 2.34 | zig-dense 2.24 | rust 1.55 | +4% to zig-dense |
| rnd100000 miss | 1.67 | zig-dense 1.87 | zig-foa 1.80 | first |
| rnd100000 iterate | 0.15 | zig-dense 0.14 | zig-dense 0.14 | +7% to zig-dense |
| rnd150000 insert | 6.97 | zig-dense 6.42 | zig-dense 6.42 | +9% to zig-dense |
| rnd150000 remove | 4.60 | dense-mix 5.04 | zig-foa 2.96 | leads ordered |
| rnd150000 hit | 2.04 | indexmap 2.08 | rust 1.27 | leads ordered |
| rnd150000 miss | 1.42 | dense 1.57 | zig-foa 1.37 | leads ordered |
| rnd150000 iterate | 0.15 | dense-mix 0.14 | dense-mix 0.14 | +7% to dense-mix |
| rnd3000000 insert | 8.69 | dense-mix 12.44 | zig-foa 7.97 | leads ordered |
| rnd3000000 remove | 7.77 | dense-mix 8.02 | zig-foa 6.71 | leads ordered |
| rnd3000000 hit | 8.34 | dense 9.38 | rust 4.62 | leads ordered |
| rnd3000000 miss | 3.15 | dense-mix 3.78 | zig-foa 2.60 | leads ordered |
| rnd3000000 iterate | 0.17 | zig-dense 0.16 | zig-dense 0.16 | +6% to zig-dense |
| rnd4000000 insert | 15.11 | rig-fast 15.69 | zig-foa 13.11 | leads ordered |
| rnd4000000 remove | 18.45 | dense-mix 20.61 | boost-mix 9.65 | leads ordered |
| rnd4000000 hit | 11.64 | dense 13.04 | absl-mix 7.08 | leads ordered |
| rnd4000000 miss | 4.60 | indexmap 4.11 | hashbrown-mix 2.74 | +12% to indexmap |
| rnd4000000 iterate | 0.21 | dense 0.21 | dense 0.21 | first |
| lat16 chain | 7.73 | rig-fast 2.29 | rig-fast 2.29 | +238% to rig-fast |
| lat1000 chain | 9.06 | rig-fast 4.73 | rig-fast 4.73 | +92% to rig-fast |
| lat100000 chain | 16.97 | rig-fast 17.98 | absl-mix 11.59 | leads ordered |
| lat4000000 chain | 187.13 | rig-fast 184.74 | zig-foa 104.17 | +1% to rig-fast |
| churn16 turnover | 3.52 | zig-dense 5.94 | zig-foa 5.73 | first |
| churn1000 turnover | 4.05 | dense-mix 4.87 | zig-foa 2.52 | leads ordered |
| churn100000 turnover | 3.90 | zig-dense 7.79 | rust 7.47 | first |
| churn4000000 turnover | 15.73 | indexmap-mix 20.58 | zig-foa 9.14 | leads ordered |
| mix16 half | 0.73 | rig-fast 0.87 | rust 0.67 | leads ordered |
| mix1000 half | 1.11 | zig-dense 1.06 | rust 0.97 | +5% to zig-dense |
| mix100000 half | 5.62 | dense 4.82 | dense 4.82 | +17% to dense |
| mix4000000 half | 12.60 | indexmap-mix 13.10 | rust 8.59 | leads ordered |
| str16 insert | 18.92 | dense-mix 14.49 | boost-mix 11.41 | +31% to dense-mix |
| str16 remove | 19.31 | rig-fast 13.05 | boost-mix 10.63 | +48% to rig-fast |
| str16 hit | 3.53 | rig-fast 3.32 | hashbrown-mix 3.08 | +6% to rig-fast |
| str16 miss | 1.59 | zig-dense 2.09 | hashbrown-mix 1.46 | leads ordered |
| str1000 insert | 26.57 | dense-mix 15.36 | dense-mix 15.36 | +73% to dense-mix |
| str1000 remove | 11.66 | indexmap 16.74 | boost-mix 12.45 | first |
| str1000 hit | 4.43 | rig-fast 4.39 | hashbrown-mix 3.81 | +1% to rig-fast |
| str1000 miss | 2.57 | zig-dense 2.61 | hashbrown-mix 2.24 | leads ordered |
| str100000 insert | 23.82 | dense-mix 13.77 | dense-mix 13.77 | +73% to dense-mix |
| str100000 remove | 22.47 | dense 20.22 | boost-mix 14.89 | +11% to dense |
| str100000 hit | 17.11 | indexmap-mix 10.46 | hashbrown-mix 8.45 | +64% to indexmap-mix |
| str100000 miss | 8.40 | dense-mix 5.14 | dense-mix 5.14 | +63% to dense-mix |
| str1000000 insert | 28.16 | dense-mix 20.68 | dense-mix 20.68 | +36% to dense-mix |
| str1000000 remove | 30.36 | dense-mix 23.55 | dense-mix 23.55 | +29% to dense-mix |
| str1000000 hit | 53.85 | dense-mix 39.26 | absl-mix 29.28 | +37% to dense-mix |
| str1000000 miss | 16.23 | dense-mix 6.98 | hashbrown-mix 4.79 | +133% to dense-mix |
| big16 insert | 5.20 | rig-fast 9.37 | zig-foa 9.34 | first |
| big16 remove | 4.08 | zig-dense 6.44 | zig-foa 5.31 | first |
| big16 hit | 0.95 | rig-fast 0.98 | rust 0.80 | leads ordered |
| big16 iterate | 0.12 | zig-dense 0.10 | zig-dense 0.10 | +20% to zig-dense |
| big1000 insert | 11.69 | zig-dense 11.39 | zig-dense 11.39 | +3% to zig-dense |
| big1000 remove | 2.77 | zig-dense 4.06 | zig-dense 4.06 | first |
| big1000 hit | 1.33 | rig-fast 1.16 | rust 0.83 | +15% to rig-fast |
| big1000 iterate | 0.09 | zig-dense 0.09 | zig-dense 0.09 | first |
| big100000 insert | 10.96 | zig-dense 9.81 | zig-dense 9.81 | +12% to zig-dense |
| big100000 remove | 4.36 | zig-dense 5.92 | zig-dense 5.92 | first |
| big100000 hit | 2.83 | indexmap 2.52 | rust 2.13 | +12% to indexmap |
| big100000 iterate | 0.54 | zig-dense 0.53 | zig-dense 0.53 | +2% to zig-dense |
| big1000000 insert | 15.69 | dense-mix 16.83 | dense-mix 16.83 | first |
| big1000000 remove | 5.72 | zig-dense 7.04 | zig-dense 7.04 | first |
| big1000000 hit | 11.34 | dense-mix 11.55 | rust 6.77 | leads ordered |
| big1000000 iterate | 0.85 | dense 0.85 | dense 0.85 | first |

Leads every ordered map on 42 of 84 rows; first of all on 19.

The `zo-checked` column of this run was built before experiment 12
and is not the Rig-shaped cost; experiment 12 is.

## pup

pup was shared all day: other agents' benchmarks, the Trig suite's
cron run, and release builds through `slot.sh`, which are not pinned
and were seen running on core 1 itself. Two full runs were discarded:
one (03:43) overlapped another agent's benchmark on core 0, and one
(04:39) overlapped a release build on core 1, which made every
malloc-based contestant 1.7-2 times as slow as the first while Rig's
own did not move. The A/Bs above, interleaved on core 1 against
zig-dense (the same compiler and harness), are the x86 evidence that
held across repeats.

### pup, final (2026-10-27 05:06, guarded)

`bench-hash --reps 3` on core 1, after a minute with nothing else on
cores 1 and 2; a monitor logged every other process seen on cores 1
and 2 during the run and saw none. The other contestants' rows agree
with the 03:43 run within a few percent. Twelve contestants: the
ordered rivals and `boost-mix`, `zig-foa`, `hashbrown-mix`,
`rust-mix`, `absl-mix`. The rows that lose here as on the Mac are
explained above. Particular to x86: every walk (experiment 7); inserts
of big values from 100,000 up, which tie zig-dense when the row runs
alone (31.4 both) and trail it after the earlier rows have shaped
glibc's heap; and in-cache misses, where the second index line costs
more on 64-byte lines.

| row | zig-ordered | best ordered rival | best of the rest | place |
|---|---|---|---|---|
| rnd16 insert | 5.40 | dense 8.99 | zig-foa 7.38 | first |
| rnd16 remove | 7.52 | dense-mix 7.79 | boost-mix 6.54 | leads ordered |
| rnd16 hit | 1.16 | rig-fast 1.50 | rust-mix 1.33 | first |
| rnd16 miss | 0.83 | indexmap 1.08 | indexmap 1.08 | first |
| rnd16 iterate | 0.21 | zig-dense 0.21 | zig-dense 0.21 | first |
| rnd24 insert | 9.74 | dense 9.75 | zig-foa 6.89 | leads ordered |
| rnd24 remove | 6.89 | dense 7.92 | boost-mix 6.25 | leads ordered |
| rnd24 hit | 1.71 | zig-dense 1.65 | rust-mix 1.43 | +4% to zig-dense |
| rnd24 miss | 1.39 | indexmap 1.32 | indexmap 1.32 | +5% to indexmap |
| rnd24 iterate | 0.21 | zig-dense 0.21 | zig-dense 0.21 | first |
| rnd1000 insert | 12.53 | zig-dense 12.37 | absl-mix 11.79 | +1% to zig-dense |
| rnd1000 remove | 6.17 | dense 4.93 | dense 4.93 | +25% to dense |
| rnd1000 hit | 1.59 | indexmap 1.57 | rust-mix 1.36 | +1% to indexmap |
| rnd1000 miss | 1.45 | indexmap 1.27 | indexmap 1.27 | +14% to indexmap |
| rnd1000 iterate | 0.21 | dense 0.11 | dense 0.11 | +91% to dense |
| rnd1500 insert | 10.41 | zig-dense 9.58 | zig-dense 9.58 | +9% to zig-dense |
| rnd1500 remove | 7.30 | dense 5.19 | boost-mix 4.63 | +41% to dense |
| rnd1500 hit | 1.89 | zig-dense 1.70 | rust-mix 1.47 | +11% to zig-dense |
| rnd1500 miss | 1.65 | indexmap 1.38 | hashbrown-mix 1.33 | +20% to indexmap |
| rnd1500 iterate | 0.21 | dense 0.11 | dense 0.11 | +91% to dense |
| rnd100000 insert | 9.41 | zig-dense 9.08 | zig-dense 9.08 | +4% to zig-dense |
| rnd100000 remove | 8.40 | dense 6.20 | dense 6.20 | +35% to dense |
| rnd100000 hit | 3.77 | dense 3.51 | rust-mix 2.68 | +7% to dense |
| rnd100000 miss | 3.25 | dense 2.74 | dense 2.74 | +19% to dense |
| rnd100000 iterate | 0.23 | dense 0.18 | dense 0.18 | +28% to dense |
| rnd150000 insert | 9.75 | zig-dense 9.07 | zig-dense 9.07 | +7% to zig-dense |
| rnd150000 remove | 7.40 | dense 6.58 | dense 6.58 | +12% to dense |
| rnd150000 hit | 3.95 | dense 3.91 | boost-mix 2.60 | +1% to dense |
| rnd150000 miss | 2.20 | indexmap 2.14 | boost-mix 1.74 | +3% to indexmap |
| rnd150000 iterate | 0.29 | dense 0.21 | dense 0.21 | +38% to dense |
| rnd3000000 insert | 19.21 | rig-fast 24.14 | boost-mix 19.33 | first |
| rnd3000000 remove | 20.94 | dense 18.27 | boost-mix 16.58 | +15% to dense |
| rnd3000000 hit | 21.48 | dense 19.93 | absl-mix 11.36 | +8% to dense |
| rnd3000000 miss | 8.03 | rig-fast 6.08 | boost-mix 4.91 | +32% to rig-fast |
| rnd3000000 iterate | 0.53 | dense 0.49 | dense 0.49 | +8% to dense |
| rnd4000000 insert | 35.82 | rig-fast 31.22 | rig-fast 31.22 | +15% to rig-fast |
| rnd4000000 remove | 29.62 | dense 33.11 | boost-mix 23.54 | leads ordered |
| rnd4000000 hit | 28.32 | dense 29.44 | absl-mix 16.33 | leads ordered |
| rnd4000000 miss | 12.42 | indexmap 11.65 | boost-mix 5.65 | +7% to indexmap |
| rnd4000000 iterate | 0.71 | dense-mix 0.66 | dense-mix 0.66 | +8% to dense-mix |
| lat16 chain | 4.79 | rig-fast 4.38 | rig-fast 4.38 | +9% to rig-fast |
| lat1000 chain | 6.74 | rig-fast 4.49 | rig-fast 4.49 | +50% to rig-fast |
| lat100000 chain | 17.50 | dense-mix 18.41 | boost-mix 11.62 | leads ordered |
| lat4000000 chain | 289.05 | rig-fast 283.98 | boost-mix 158.00 | +2% to rig-fast |
| churn16 turnover | 5.09 | dense 6.74 | rust-mix 5.69 | first |
| churn1000 turnover | 5.65 | dense 4.93 | zig-foa 3.62 | +15% to dense |
| churn100000 turnover | 5.93 | dense 9.04 | hashbrown-mix 7.92 | first |
| churn4000000 turnover | 28.96 | dense-mix 31.22 | boost-mix 22.17 | leads ordered |
| mix16 half | 1.02 | rig-fast 1.18 | hashbrown-mix 1.12 | first |
| mix1000 half | 1.42 | dense 1.30 | boost-mix 1.17 | +9% to dense |
| mix100000 half | 7.79 | dense 7.44 | boost-mix 7.20 | +5% to dense |
| mix4000000 half | 24.81 | dense 23.98 | rust-mix 15.06 | +3% to dense |
| str16 insert | 27.85 | rig-fast 26.23 | rig-fast 26.23 | +6% to rig-fast |
| str16 remove | 28.90 | rig-fast 20.42 | rig-fast 20.42 | +42% to rig-fast |
| str16 hit | 4.86 | dense 4.94 | absl-mix 4.41 | leads ordered |
| str16 miss | 2.66 | zig-dense 3.00 | zig-foa 2.98 | first |
| str1000 insert | 39.37 | zig-dense 23.50 | zig-dense 23.50 | +68% to zig-dense |
| str1000 remove | 25.35 | dense 24.54 | dense 24.54 | +3% to dense |
| str1000 hit | 7.09 | dense-mix 5.88 | hashbrown-mix 4.89 | +21% to dense-mix |
| str1000 miss | 3.83 | rig-fast 2.64 | rig-fast 2.64 | +45% to rig-fast |
| str100000 insert | 35.32 | dense 22.29 | dense 22.29 | +58% to dense |
| str100000 remove | 34.35 | dense-mix 33.07 | dense-mix 33.07 | +4% to dense-mix |
| str100000 hit | 58.50 | dense-mix 21.90 | absl-mix 21.35 | +167% to dense-mix |
| str100000 miss | 15.07 | dense-mix 6.68 | dense-mix 6.68 | +126% to dense-mix |
| str1000000 insert | 57.21 | dense 47.97 | dense 47.97 | +19% to dense |
| str1000000 remove | 65.12 | dense 46.20 | dense 46.20 | +41% to dense |
| str1000000 hit | 111.09 | dense 85.11 | hashbrown-mix 62.05 | +31% to dense |
| str1000000 miss | 20.69 | dense 15.66 | hashbrown-mix 11.73 | +32% to dense |
| big16 insert | 10.72 | zig-dense 14.02 | boost-mix 13.92 | first |
| big16 remove | 8.71 | dense-mix 10.28 | dense-mix 10.28 | first |
| big16 hit | 1.23 | zig-dense 1.49 | rust-mix 1.45 | first |
| big16 iterate | 0.21 | zig-dense 0.21 | zig-dense 0.21 | first |
| big1000 insert | 15.53 | zig-dense 16.05 | zig-dense 16.05 | first |
| big1000 remove | 5.90 | zig-dense 6.68 | zig-dense 6.68 | first |
| big1000 hit | 1.70 | zig-dense 1.67 | absl-mix 1.59 | +2% to zig-dense |
| big1000 iterate | 0.26 | zig-dense 0.26 | zig-dense 0.26 | first |
| big100000 insert | 29.51 | zig-dense 18.10 | zig-dense 18.10 | +63% to zig-dense |
| big100000 remove | 10.68 | dense-mix 11.37 | dense-mix 11.37 | first |
| big100000 hit | 6.96 | zig-dense 5.27 | absl-mix 4.75 | +32% to zig-dense |
| big100000 iterate | 0.86 | dense 0.79 | dense 0.79 | +9% to dense |
| big1000000 insert | 47.39 | zig-dense 35.09 | zig-dense 35.09 | +35% to zig-dense |
| big1000000 remove | 17.56 | dense 17.20 | dense 17.20 | +2% to dense |
| big1000000 hit | 23.29 | dense 23.15 | rust-mix 18.91 | +1% to dense |
| big1000000 iterate | 2.77 | dense-mix 2.74 | dense-mix 2.74 | +1% to dense-mix |

Leads every ordered map on 26 of 84 rows; first of all on 18.

The Rig-shaped variant in this run (experiment 12's): 0.8% slower by
geometric mean over the 84 rows; its worst rows are misses (rnd24 miss
1.39 to 1.72, rnd1000 miss 1.45 to 1.77) and in-cache hits (rnd1000
hit 1.59 to 1.76, rnd4000000 hit 28.32 to 31.57, 11%), while some
remove rows ran faster, because its walk was inline (experiment 15).

### 15. The walk past home inline in a take (kept)

The Rig-shaped variant removed faster than the plain one on pup (its
walk past home inline). `fetchRemove` is a call of its own, and a call
inside it costs its prologue more saved registers than the walk costs.
With the walk inline in a take alone (lookups keep it out of line):

| row | Mac before | Mac after | pup before | pup after | pup zig-dense |
|---|---|---|---|---|---|
| rnd1000 remove | 3.88 | 3.46 | 5.68 | 5.69 | 5.35 |
| rnd1500 remove | 4.24 | 4.05 | 7.26 | 6.68 | 5.55 |
| rnd100000 remove | 5.25 | 5.05 | 8.91 | 8.45 | 6.90 |
| rnd3000000 remove | 11.79 | 10.76 | 18.61 | 20.91 | 19.63 |

The final runs above were made just before this change.

## The rows an ordered map cannot win here, and why

- **lat16, lat1000** (Rig's current Map, 2.3 and 4.7 on the Mac): a
  predicted byte probe, experiment 8. Any group match is several
  cycles longer on a dependent chain.
- **Out-of-cache hits and the 4M chain against flat maps** (decision
  2): two waits on memory, the slot line and the entry. On the Mac
  zig-ordered is level with the ordered maps there (rnd4000000 hit
  11.94 against dense's 11.76; lat4000000 187 against Rig's 185).
- **Iteration on x86 against clang's dense**: experiment 7, a Zig
  toolchain gap. On the Mac iteration ties dense and indexmap.
- **The 4M miss** (indexmap 4.11, hashbrown 2.5 on the Mac, against
  4.60): the slot prefetch issued with every lookup costs misses
  10-19% (experiment 1). It is kept because it wins hits, removes and
  the 100k chain.
- **Text rows against dense**: ankerl's C++ keeps texts of 22 bytes or
  fewer inside `std::string`; a Rig String's bytes are on the heap. The
  rest of the text gap is the harness's (experiment 6).
- **Open, not understood:** inserts from 1,000 to 150,000 keys trail
  zig-dense by 8-17% on both machines, with the same number of
  rebuilds and allocations. In-cache hits at 1,000-1,500 trail
  indexmap by 9-15% on the Mac: hashbrown's NEON groups are 8 lanes
  (`cmeq.8b`, `fmov`, no `shrn`), one instruction fewer a probe. That
  is the group-width question the hash.zig builder is measuring;
  `mix100000` and the 100k miss trail by 17% at the index's 0.81 load
  (experiment 4).

## What Rig would need that the panel's list does not have

1. **Gone bits in the entries' own allocation.** Kept apart, as the
   panel drew them ("allocated at the first take"), the first take in
   each map costs an allocation; the 16- and 24-key remove rows would
   pay it once a map. Rig would need a List whose block ends in a
   bitset, or `List.with_bits`, or two Lists and that cost.
2. **A fixed array inside the Map object**, `[32]U8` of small tags,
   read at a lane from `m.lanes()` with the lane-range fact
   (compiler.md §2) proving the read. Small maps make 1 allocation, not
   2 or 3 (rnd16 insert 2.2 against Rig's 7.4).
3. **`rarely` in a branch as `.unlikely`** (compiler.md step 1), now
   measured: the test for the second tag vector cost rnd16 miss 0.50 to
   0.84 without the hint (experiment 9).
4. **A cold helper that cannot panic, or none.** A hot loop that calls
   an out-of-line function that may panic reloads the map's fields on
   every iteration (experiment 12: 20-31%). Rig's checked code should
   keep such walks inline, or its emitter should mark a panic-free
   helper read-only.
5. **A zeroed block** for the index (the panel's item 4): the
   prototype uses `calloc` when the allocator is libc's.
6. **Over 2% for the retained tests** (decision 10's trigger): 2-7% on
   most lookup rows, 13% on big1000 hit. A proven or `raw` read of the
   entry index read from the index is in play.

## What the harness should change (asked of the prover)

1. `map.zig`'s `text()`: one allocation a text (`bufPrint` into a stack
   buffer, then `gpa.dupe`), and `texts()` filling `put` before `take`
   and `hit` before `miss`, as `map.rs` does (experiment 6).
2. A `zig-ordered-checked` variant (a `table_ordered_checked.zig` with
   `Ordered(K, V, Ctx, .{ .checked = true })`), so the Rig-shaped cost
   is tracked in every run.
