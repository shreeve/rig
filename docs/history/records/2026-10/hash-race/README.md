# Hash race: where Rig's maps stand against the fastest tables (2026-10-27)

The owner's goal (2026-10-26): "the FASTEST POSSIBLE implementation of
this algorithm. We want Rig to start out in FIRST PLACE", with existing
map code free to change. He wants two families, ordered and unordered
Map and Set. This round built the ruler and took the first reading. No
Rig map changed.

## The ruler

`bench/hash` races the built-in ordered Map (`rig-fast`) and std.hash's
unordered Map from #685 (`hash-fast`, built by #685's `bin/rig` at
fc964bf) against:

- Zig's `std.HashMap`;
- Rust's std `HashMap` with FxHasher (`rust`);
- the hashbrown 0.17.1 and indexmap 2.14.2 crates with foldhash;
- abseil 20260817.0 `flat_hash_map`;
- boost 1.92.0 `unordered_flat_map`;
- ankerl `unordered_dense` 5.3.3;
- Go 1.27.1's built-in map.

Each but Go and Zig also runs with Rig's Int hash (`-mix`), so tables
race on one hash. Rig's builds are `--release=fast`; C++ is clang -O3;
Rust is release with LTO. The `rnd*` rows are new: random 64-bit keys,
with hits looked up in shuffled order, as
[design-study.md](design-study.md) §5 asks.

- Mac: Apple M-series, `tools/low`, fastest of 5, interleaved.
- pup: core 8 with sibling 9 idle, fastest of 5.

Raw reports: [mac-race.txt](mac-race.txt) and [pup-race.txt](pup-race.txt)
(both key sets), and [mac-race-v1.txt](mac-race-v1.txt) and
[pup-race-v1.txt](pup-race-v1.txt) (before the `rnd` rows).
[podium.py](podium.py) prints each row's fastest non-Rig table against
Rig's faster map.

## What the reading says

**The `int` rows mislead.** Their keys are `i * MUL`. FxHash is a
multiply too, so the hashes keep a stride, and the prefetcher follows
it: std's FxHash HashMap is fastest on 13 of the 20 `int` rows on the
Mac, but on 3 of 20 `rnd` rows. The hit loop also reads keys in
insertion order, which hands a dense map its entries in sequence. The
built-in Map's hit at 4M keys is 7.30 ns on `int` and 14.87 on `rnd`
(Mac). From here on, judge by the `rnd` rows.

**The leaders on random keys,** leaving FxHash aside:
- **Removes:** boost from 1k keys up, except ankerl at 100k on pup.
- **Iteration:** ankerl's dense map and indexmap.
- **Misses:** boost on pup from 1k up. On the Mac it varies by size:
  indexmap, Rust std with Rig's hash, ankerl, then hashbrown.
- **Hits:** hashbrown on pup to 100k keys, then abseil at 4M on both;
  on the Mac, Rust's std map with Rig's hash.
- **Inserts:** abseil on pup from 1k up; on the Mac boost at 16 and 4M,
  ankerl in between.

Counting
first places on the 20 `rnd` rows (Mac / pup):

| Contestant | Mac | pup |
|---|---|---|
| boost (and `-mix`) | 4 | 6 |
| ankerl dense (and `-mix`) | 5 | 5 |
| abseil (and `-mix`) | 1 | 3 |
| Rust std + FxHash | 3 | 3 |
| Rust std + Rig's hash | 2 | 0 |
| indexmap | 2 | 0 |
| hashbrown crate (`-mix`) | 1 | 0 |
| Zig | 1 | 0 |
| Rig's Map | 1 | 2 |
| std.hash | 0 | 1 |

**Rig today, `rnd` rows:** Rig's faster map against the fastest other
table, as a time ratio (2.0x is twice as slow):

| Row | Mac | pup |
|---|---|---|
| insert 16 | Map 12% faster | 1.4x |
| insert 1k | 1.0x | 1.0x |
| insert 100k | 1.7x | 2.0x |
| insert 4M | 1.1x | Map 24% faster |
| remove 16 / 1k / 100k / 4M | 2.2x / 1.6x / 3.0x / 1.9x | 1.4x / 2.3x / 2.9x / 1.8x |
| hit 16 / 1k / 100k / 4M | 1.1x / 1.2x / 1.1x / 1.4x | 1.1x / 1.2x / 1.1x / 1.3x |
| miss 16 / 1k / 100k / 4M | 1.3x / 1.5x / 1.1x / 1.5x | level / level / 1.6x / 1.3x |
| iterate 16 / 1k / 100k / 4M | 1.1x / 5.9x / 3.4x / 2.2x | 2.4x / 3.8x / 2.6x / 1.6x |

The built-in Map wins the 4M build on both machines and the 16-key
build on the Mac. std.hash comes
within 10% on hits at 100k. Everything else is behind: removes by 1.4x
to 3.0x, iteration by up to 5.9x (indexmap's dense `Vec` with no holes
sums its values with vector loads; Rig's Map tests each entry's `V?`),
and misses and hits out of cache by 1.3x to 1.6x. Go is last or near
it on every row.

## What comes next

[design-study.md](design-study.md) §4 is the plan:

- (a) the built-in Map keeps dense entries, takes ankerl 5.3's group
  index, and takes entries by a gone bit;
- (b) std.hash takes boost's 15-slot groups with an overflow byte, with
  the arm64 scan done by the nibble mask;
- both need a per-target mask-lane form, `prefetch`, a branch hint, and
  zeroed or huge pages.

Its §6 lists the owner's decisions. Two harness gaps remain from §5:
a dependent-chain latency row, and a churn row.
