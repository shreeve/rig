# std.hash Map and Set against Trig's ordered map (NEEDS 42)

Branch `worktree-agent-adc0963a77122a1d4`, commit 88bd9852b, with origin/main merged (a42da8961). Not pushed and no PR: the coordinator asked me to hold while the owner decides on a reset.

## Cause

Measured with Trig's phase, Set and pw benches and its A/B programs (m, md), at n = 8, 40, 300 and 1000.

1. **Three arrays per probe.** Main keeps a U8 tag and a U32 index for each slot, plus a List of stored U64 hashes beside the entries. A hit reads a tag, an index, a stored hash and then the entry. Trig keeps one U64 per slot, so a hit reads one slot and then the entry.
2. **Small maps.** At 8 entries or fewer, main scans the stored hashes. This makes misses at n=8 twice as slow as Trig's.
3. **Delete.** Trig's delete is take + retain(true). On main that compacts and then renumbers every slot. The renumbering branches on index > j for each slot, and that branch mispredicts. At n=1000, delete is about 10 times as slow as Trig's.

## Change

- **One U64 per slot.** A slot holds 31 hash bits, then TOP, then the entry index; 0 means free.
- **Load and size.** The table is at most half full, with at least 16 slots.
- **Home slot.** The two halves of the hash are swapped (`mix`), so the low bits of the runtime hash pick the home slot.
- **Removed.** The stored hashes, the tags and the small-map path are gone.
- **Growth** places each slot again from its own bits, so no key is hashed again.
- **shift_down** has no branch: `s -%= ((s & LOW) +% (LOW - j)) >> 32`. It vectorizes.
- **Public API:** unchanged.

## Results

Units:
- 0.1 ns per key for the map and Set columns.
- 0.01 ns per key for the Map miss and Map walk rows, which come from the pw bench.

Each value is the median of 5 interleaved rounds:
- pup: from res/pup-base.txt. Each range is within about ±3% of its median.
- Mac: under a load of about 4.8. Each range is within about ±5% of its median. Trig and this PR come from res/mac-r4.txt, and main comes from the earlier res/mac-r1.txt.

All result files are in the session scratchpad, under res/.

### pup (x86, leased exclusive, CPU 2; 5 rounds, medians)

| op | n | Trig | main | main vs Trig | this PR | this PR vs Trig |
|---|---|---|---|---|---|---|
| Map build | 8 | 29.60 | 31.90 | 8% slower | 26.20 | 11% faster |
| Map build | 40 | 22.70 | 32.90 | 45% slower | 21.20 | 7% faster |
| Map build | 1000 | 40.90 | 47.00 | 15% slower | 34.70 | 15% faster |
| Map hit | 8 | 10.60 | 14.30 | 35% slower | 9.60 | 9% faster |
| Map hit | 40 | 9.70 | 14.40 | 48% slower | 9.40 | 3% faster |
| Map hit | 1000 | 21.80 | 26.30 | 21% slower | 14.40 | 34% faster |
| Map miss | 8 | 30.40 | 60.90 | 100% slower | 26.70 | 12% faster |
| Map miss | 40 | 31.60 | 50.10 | 59% slower | 27.60 | 13% faster |
| Map miss | 1000 | 44.10 | 60.80 | 38% slower | 35.90 | 19% faster |
| Map delete | 8 | 4.90 | 16.30 | 233% slower | 4.90 | tied |
| Map delete | 40 | 9.40 | 61.90 | 559% slower | 8.10 | 14% faster |
| Map delete | 1000 | 228.50 | 2504.50 | 996% slower | 122.90 | 46% faster |
| Map walk | 8 | 5.40 | 5.40 | tied | 5.60 | 4% slower |
| Map walk | 40 | 7.90 | 7.20 | 9% faster | 7.20 | 9% faster |
| Map walk | 1000 | 5.40 | 5.30 | 2% faster | 5.40 | tied |
| Set add | 8 | 29.60 | 32.00 | 8% slower | 25.60 | 14% faster |
| Set add | 40 | 22.30 | 32.20 | 44% slower | 21.00 | 6% faster |
| Set add | 1000 | 37.50 | 40.80 | 9% slower | 32.50 | 13% faster |
| Set has hit | 8 | 6.90 | 8.30 | 20% slower | 6.90 | tied |
| Set has hit | 40 | 5.90 | 7.50 | 27% slower | 5.90 | tied |
| Set has hit | 1000 | 6.80 | 8.50 | 25% slower | 6.30 | 7% faster |
| Set has miss | 8 | 4.90 | 7.90 | 61% slower | 4.70 | 4% faster |
| Set has miss | 40 | 3.90 | 5.30 | 36% slower | 3.80 | 3% faster |
| Set has miss | 1000 | 8.70 | 8.20 | 6% faster | 4.80 | 45% faster |
| Set delete | 8 | 4.40 | 3.30 | 25% faster | 3.70 | 16% faster |
| Set delete | 40 | 6.60 | 2.70 | 59% faster | 2.30 | 65% faster |
| Set delete | 1000 | 139.60 | 2.50 | 98% faster | 1.90 | 99% faster |

### Mac (arm64, cpuq one core, load about 4.8; Trig and this PR from one run, main from an earlier run)

| op | n | Trig | main | main vs Trig | this PR | this PR vs Trig |
|---|---|---|---|---|---|---|
| Map build | 8 | 14.40 | 16.90 | 17% slower | 12.90 | 10% faster |
| Map build | 40 | 15.10 | 20.20 | 34% slower | 14.20 | 6% faster |
| Map build | 1000 | 21.30 | 25.30 | 19% slower | 24.90 | 17% slower |
| Map hit | 8 | 7.50 | 11.10 | 48% slower | 7.10 | 5% faster |
| Map hit | 40 | 7.10 | 8.90 | 25% slower | 6.40 | 10% faster |
| Map hit | 1000 | 9.60 | 11.40 | 19% slower | 7.90 | 18% faster |
| Map miss | 8 | 23.30 | 50.90 | 118% slower | 22.10 | 5% faster |
| Map miss | 40 | 25.20 | 32.40 | 29% slower | 23.20 | 8% faster |
| Map miss | 1000 | 37.50 | 42.70 | 14% slower | 32.70 | 13% faster |
| Map delete | 8 | 3.00 | 9.50 | 217% slower | 3.10 | 3% slower |
| Map delete | 40 | 7.60 | 47.50 | 525% slower | 5.20 | 32% faster |
| Map delete | 1000 | 197.60 | 1451.80 | 635% slower | 72.70 | 63% faster |
| Map walk | 8 | 4.80 | 4.40 | 8% faster | 4.40 | 8% faster |
| Map walk | 40 | 4.10 | 4.00 | 2% faster | 4.80 | 17% slower |
| Map walk | 1000 | 4.20 | 4.20 | tied | 4.30 | 2% slower |
| Set add | 8 | 14.30 | 28.90 | 102% slower | 11.50 | 20% faster |
| Set add | 40 | 15.00 | 18.90 | 26% slower | 14.20 | 5% faster |
| Set add | 1000 | 20.60 | 25.00 | 21% slower | 24.30 | 18% slower |
| Set has hit | 8 | 4.80 | 6.00 | 25% slower | 5.00 | 4% slower |
| Set has hit | 40 | 4.80 | 5.50 | 15% slower | 4.50 | 6% faster |
| Set has hit | 1000 | 5.80 | 6.70 | 16% slower | 5.20 | 10% faster |
| Set has miss | 8 | 2.80 | 6.20 | 121% slower | 2.60 | 7% faster |
| Set has miss | 40 | 2.70 | 3.40 | 26% slower | 2.40 | 11% faster |
| Set has miss | 1000 | 3.90 | 4.40 | 13% slower | 3.50 | 10% faster |
| Set delete | 8 | 3.20 | 2.60 | 19% faster | 2.60 | 19% faster |
| Set delete | 40 | 5.00 | 1.50 | 70% faster | 1.30 | 74% faster |
| Set delete | 1000 | 120.50 | 1.70 | 99% faster | 1.40 | 99% faster |

### Trig's A/B programs (ns per round; Trig / this PR)

- **pup m:**
  - n=8: 423 / 399, 6% faster.
  - n=40: 1847 / 1800, 3% faster.
  - n=1000: 67184 / 65482, 3% faster.
- **pup md:**
  - n=8: 453 / 411, 9% faster.
  - n=40: 2101 / 2031, 3% faster.
  - n=1000: 227385 / 188146, 17% faster.
- **Mac m:**
  - n=8: 237 / 215, 9% faster.
  - n=40: 1265 / 1208, 5% faster.
  - n=1000: 42190 / 39552, 6% faster.
- **Mac md:**
  - n=8: 251 / 223, 11% faster.
  - n=40: 1483 / 1358, 8% faster.
  - n=1000: 182387 / 113260, 38% faster.

## Where the 5-10% aim is missed

- **Map build and Set add at n=1000 on the Mac** are 17-18% slower than Trig. They are about as fast as main, so nothing regressed. On pup the same ops are 13-15% faster than Trig.
  - The k13 variant adds a U8 tag per slot. It closes this gap on the Mac (4% faster than Trig), but its hits are 6-10% slower on both machines.
  - In a direct std benchmark of a 1000-key build from empty, k12 is faster than k13. The gap may come from how the code is laid out in Trig's program. I have not confirmed that.
- **Some gaps are smaller than 0.1 ns per key:**
  - Map walk at n=40 on the Mac: 0.07 ns per key, inside its range of 3.9-5.0.
  - Map delete and Set hit at n=8: tied to 4% slower.
- **Map hit at n=40 on pup** is only 3% faster. The probe is already one slot and one compare. What remains is the cost of the Wyhash of the string key.

## Large maps (outside Trig's sizes): the owner must decide

bench/hash at 1M keys on pup, ns per op, main / this PR (5 runs, noisy, up to ±40%):

| op | main | this PR | change |
|---|---|---|---|
| int insert | 33.7 | 39.6 | 18% slower |
| int hit | 10.06 | 10.12 | tied |
| int miss | 10.98 | 13.72 | 25% slower |
| string insert | 56.7 | 66.9 | 18% slower |
| string hit | 44.1 | 43.1 | 2% faster |
| string miss | 22.4 | 28.2 | 26% slower |
| int ensure-miss | 30.5 | 39.0 | 28% slower |
| int ensure-hit | 10.07 | 15.41 | 53% slower |
| small 4 / small 8 | 3.55 / 3.66 | 2.26 / 2.63 | 36% / 28% faster |

- **Focused rerun** (gr/eh.rig, 3 runs, ns per op):
  - ensure-miss: 33 on main, 38-40 here, so 15-20% slower.
  - ensure-hit: 11-15 on main, 11-18 here, within noise.
  - get-hit: 9 on both.
- **perf stat for that rerun, main / this PR:**
  - cycles: 536M / 587M
  - instructions: 828M / 604M
  - cache misses: 3.17M / 4.96M
  - dTLB misses: 2.54M / 3.77M
- **Cause: memory footprint.** At 1M keys:
  - This PR's table is 2M slots of 8 B, which is 16 MB.
  - Main's tags are 4M slots of 1 B, which is 4 MB. A miss on main reads only the tags, and 4 MB stays in L3.
- **Int sweep from 1k to 1M keys** (gr/sweep.rig):
  - Hit and miss are faster than main at 1k-10k and at 100k-300k.
  - Insert is faster at 1k and 30k, and slower at 10k and from 100k up.

Options:
1. (default) Ship this layout. Trig's sizes gain, and so do most maps below about 100k keys. Maps of 1M keys are 15-25% slower to fill and to miss. A follow-up could add a U8 tag array only for tables larger than 2^17 slots.
2. Hold until that hybrid is built and measured, about a day.

## Memory (Map[String, Int], 64-bit)

| | per entry | per slot | slots per entry | smallest table |
|---|---|---|---|---|
| Trig | 56 B | 8 B | 1.3-2.7 | 64 B |
| main | about 40 B, plus 8 B stored hash | 5 B (tag + index) | 2.5-5 | no table at 8 entries or fewer |
| this PR | 48 B | 8 B | 2-4 | 128 B (16 slots) |

At 1000 entries:
- This PR: 48 KB of entries + 16 KB of slots = 64 KB.
- Main: 48 KB + 20 KB = 68 KB.
- Trig: 56 KB + 16 KB = 72 KB.

## Separate finding (possible runtime task)

Zig's SmpAllocator moves to another Thread struct when a size class has no free block and no bump space. As a result, a run's timing depends on where its large Lists land. This made A/B timings on the Mac jump between runs. It is not changed here.

## Tests

- **New: test/behavior/std/hash_edges.rig.**
  - Covers Map, Set and Symbols.
  - Sizes: 0, 1, 7, 8, 9, 15, 16, 17, 31, 32, 33, 64, 65 and 300, each with no reserve and with reserve n.
  - Steps: takes before and after growth, retain rejecting one entry and many, clear, and the walk and at(i) order, with at(-1) and at(len) giving none.
  - It is sanitizer-clean on k9, k12 and k13.
- **hash_churn.rig** now also covers ensure and reserved room.
- **Passing with this std:** the std area and doc/STD (364 + 40 tests), and cli/inline. Style and vocab have not been rerun.
- **Not finished:**
  - The full `./test/run --delta` on the Mac was stopped by the coordinator (Mac full runs are not allowed).
  - `tools/check 10` has not run yet.
