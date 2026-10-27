# zig-hash: the unordered HashMap's Zig prototype (2026-10-27)

`bench/hash/hash.zig`, the design Rig's unordered `HashMap` will take:
`foa.zig` (boost's FOA) changed where bench/hash measured it losing.
Every change is an `Options` field, so each experiment below can be
built again (`HashMapWith(K, V, Ctx, .{ ... })`); the defaults are the
winners. foa.zig's tests pass for it in Debug and ReleaseSafe on arm64
and x86-64, with tests added for each option. Checksums match every
contestant's on both machines.

Times are ns per operation, fastest of 5 interleaved runs (3 where
noted), from a copy of `map.zig` that runs chosen rows (the same code).
pup timed on core 0 only. Both machines were shared: the Mac ran other
agents' suites (load 2 to 12) and pup ran Trig's full suite once (those
runs are thrown out), so a gap under about 5% is not a finding. The
competitors' numbers are one bench-hash run of each machine, 3 rounds.

## What changed from foa.zig

| Change | Why |
|---|---|
| arm64: groups of 7 slots and 8 bytes (`cmeq.8b`, `fmov`), max load 0.8, at least 4 groups. x86-64 keeps 15 and 16. | Fewer instructions a probe: L1 hits 10-18% faster, lat 10% faster. 0.8 because 7-slot groups overflow often near full (at 0.875, 100k keys sit at 0.87 and the miss is 2.48 against 1.64); 4 groups so a map of 16 grows once. |
| The table hashes an Int key with one multiply (`0x4b33a62ed433d4a3`), a text key with folded multiplies up to 32 bytes (Wyhash above), text compared by words. | Decisions 7 and 8; see below. The golden ratio is not the multiplier: the int rows' keys are its multiples, and its square sends 100k of them into a few groups (miss 3.6x as slow). |
| Hash rotated left a byte: tag the top byte, home group the bits below. | A one-multiply hash's low byte is weak (keys that are multiples of 256 share it). The tag from the byte below the group bits (a second variable shift) cost hits 5-25%; the rotation costs one instruction. |
| The tag broadcast by a load from a 256-entry table (`vpbroadcastd`, `ld1r`), the overflow class bit from an 8-entry table. | An arithmetic tag went through `vmovd` + `vpbroadcastb`: pup's L1 hits about 25% slower. |
| arm64: a 16-byte slot's address is the group's plus `ctz << 1` (masks keep bit 0 of each lane). | One shift less a probe: about 8% on L1 hits. |
| Prefetch: none for slots over 32 bytes; for smaller, the home group's first line inside the branch a tag match takes. | boost's half-group prefetch made big hits 2.7-3.2x slow. Prefetching from the hash before the branch (abseil's place) cost misses 30-50% at 3M-4M on both machines. Inside the branch, a loop of misses predicts it not taken: pup rnd4M hit 17.5 against 23.1 with none, misses unchanged. |
| A text key keeps its full hash in its slot (not compared on lookup). | Growth never reads a key: pup str1M insert 60 against 108 without. Comparing it on lookup cost small maps' hits 10-14%. |
| One pass an insert. | Not timed apart from the rest. |
| A rehash forced by drift sizes the table to at most 0.6 full. | churn100000: Mac 2.3 against 10.7, pup 4.4 against 15.0. |

## Experiments dropped

- **Home lane and scalar first probe** (the lat rows): pup lat16 4.77 /
  lat1000 4.43 (Zig's std 4.41 / 4.55), but rnd100000 hit 6.52 against
  2.95 and every insert 10-20% slower: the first-probe branch
  mispredicts for a key not in its lane. Home placement without the
  first probe still slowed hits. Conceded (decision 3).
- **Stride 16** (slot address by shift, not multiply): no gain on either
  machine; big inserts 1.6-2.3x slower on pup.
- **Two prefetched lines** (`matched2`): pup rnd3M/4M hit 12-14% slower.
- **Tag from the low byte** (boost's): 3-8% faster on hits than the
  rotation, but unsafe for a one-multiply hash (above).
- **Groups of 7 on x86** (pup, same 0.8 and 4): hits 10-17% faster,
  misses faster (100k 1.23 against 2.66; 4M 3.80 against 4.80), but inserts 1.6-2.1x slower at 24, 1500, 100k and 3M (larger
  tables to fault in), lat100000 28% slower, mix1000 20% slower. Left
  off; an owner's choice if misses count more than inserts.
- **No stored hash for text**: removes 25-30% faster at 100k (32-byte
  slots cost cache), inserts 30-80% slower at 100k-1M. Kept the hash;
  str insert and remove are the ordered Map's rows (panel §4).

## Where it stands: the HashMap's rows

The rows panel §4 gives the HashMap (hit, miss, remove, lat, churn, mix,
big hit), against every non-Rig, non-Zig contestant. zig-foa won or
tied 19 of these 44 on the Mac and 5 on pup; zig-hash 31 and 23.

**Mac, lost:** rnd16 hit 0.80 / 0.76 (rust), rnd16 miss 0.76 / 0.63
(hashbrown), rnd24 hit 0.83 / 0.79, rnd1000 hit 0.95 / 0.85, rnd150000
hit 1.66 / 1.30, rnd3M hit 5.19 / 4.83, mix16 0.77 / 0.71, big16-1M hit
1.05-1.12x (all `rust`), mix1000 1.01 / 0.98 (hashbrown-mix), lat4M
103.8 / 100.7 (absl; zig-foa 91.5 in the same run, so noise),
big100000 remove 8.33 / 7.65 (dense). Won: every other hit and miss
(rnd100000 hit 1.31 against rust 1.54; rnd4M miss 2.02 against 2.53;
rnd4M hit 7.17 level with absl's 7.12), lat16-lat100000, churn, mix100000 and 4M.

**pup, lost:** every rnd hit to `rust` by 7-31% (rnd1000 1.28 / 1.05,
rnd100000 2.56 / 1.96, rnd3M 11.49 / 9.04), rnd4M hit 15.63 / 14.34
(hashbrown), rnd3M and 4M remove 6% (boost), churn16 6% (hashbrown),
mix16, mix1000 and mix4M by 30% (rust), big hits by 16-20% (rust), big
removes (dense). Won: misses, lat, churn 100k and up, mix100000.

**Why `rust` (std HashMap with FxHash) leads hits:** about 18
instructions a lookup against our 21-24 (x86 keeps 16-lane groups and
a 15-slot multiply; the prefetch and the overflow class add one each).
At 100k-4M it is memory parallelism, not latency: fewer instructions a
lookup keep more lookups in the reorder window. `rust-mix`, the same
table with Rig's hash, is 25% slower than `rust` at rnd3M hit on pup
(11.95 against 9.04), and zig-hash beats it. The 16-lane layout cannot
reach 18; groups of 7 on x86 trade inserts for it (above).

**Conceded:** lat16 and lat1000 to Zig's std (Mac 6.39 against 5.24, pup
5.65 against 4.41; decision 3).

## The text rows and a harness difference

map.zig makes its texts in a different order from map.rs, the
reference: it allocates `put[i]` and `take[i]` in one loop, and `hit[i]`
and `miss[i]` in one loop, so each array's texts are interleaved with
another's; map.rs makes each array in its own pass. Every Zig
contestant then streams twice the lines. With map.rs's order (a copy of
map.zig, nothing else changed), on the Mac:

| Row | zig-foa | zig-hash | zig-hash, map.rs's order | best other |
|---|---|---|---|---|
| str16 insert | 23.07 | 28.81 | 9.45 | 12.36 boost |
| str1000 insert | 32.69 | 32.47 | 14.36 | 18.04 dense-mix |
| str1000000 insert | 54.18 | 36.48 | 21.75 | 24.87 dense |
| str100000 miss | 8.74 | 6.66 | 2.63 | 5.61 dense-mix |
| str1000000 miss | 17.13 | 13.24 | 4.45 | 4.89 hashbrown |
| str1000000 hit | 41.37 | 35.93 | 28.81 | 28.27 absl-mix |

On pup (glibc) the order moves only misses (str100000 miss 16.5 to
11.6). **The harness should make each text array in its own pass.**
Under the fair order, the text rows the HashMap still loses are str
removes (C++ keeps keys of up to 22 bytes inline, so its remove reads
and frees nothing; Rust's heap strings lose them too) and str100000 hit
(12.4 against hashbrown's 9.1).

## Decision 7: one multiply against Rig's hash

zig-hash with `.int_mul = false` (Rig's `hashWord`) against the
default. Mac: one multiply faster on every small row (rnd16 hit 15%,
rnd24 14%, rnd1000 4%, mix16 19%, mix1000 15%). pup: faster on rnd16,
rnd24 and rnd1000 hits (10-28%), slower on mix16 (2%) and mix1000 (5%).
So "nothing slower" fails narrowly on pup's two mix rows.

## The Rig-shaped cost (`.checked = true`)

A bounds test on every slot index `pos * S + lane` and tag read by lane
(the group index is masked, so it needs none):

| | Mac | pup |
|---|---|---|
| L1 hits (16-1500 keys) | 17-34% slower | 16-48% slower |
| hits at 100k-4M | 5-8% | 16-19% |
| inserts | 5-15% | 10-16% |
| misses | 0-2% | 6-37% |
| lat16 | 8% | 9% |

`.checked_fold` keeps the folded address and adds only the test: lat
back to unchecked, hits still about 28% slower at 16 keys. The test is
far over decision 10's 2%: the slot index needs a proof (a lane below
`S` from a masked `ctz`, and the slot List's length fixed at `groups *
S` by the table's invariant) or a `raw` read.

## What Rig would need beyond the panel's list

1. A layout chosen by target: groups of 7 on arm64, 15 on x86-64.
2. A broadcast from memory (`Simd.splat` of a table read lowered to
   `ld1r` / `vpbroadcastd`), not through a general register.
3. A slot addressed by a byte offset made from the mask (`ctz << 1`):
   index arithmetic Rig would have to prove, or emit, itself.
4. `prefetch` placed inside the tag-match branch, not before it.
5. The table's own hash for Int and text keys (`.hash()` unchanged for
   users), and word-wise text equality over overlapping reads.

## Round 2: instructions a lookup (2026-10-27, night)

The harness now makes each text array in its own pass, as map.rs does;
every binary here is built on it. The target was the hit and mix rows,
where Rust std with FxHash (`rust`) led.

### Instructions on a hit at home

Counted from the disassembly of an exported `get` on `HashMap(i64, i64)`
(`zig build-obj -OReleaseFast`, native arm64 and `-mcpu=meteorlake`),
from the key to the value, leaving out what a loop of lookups hoists:
constants and the map's three fields.

| Build | arm64 (Mac) | x86-64 (pup) |
|---|---|---|
| zig-foa | 28 | 25 |
| zig-hash, round 1 (probe loop) | 21 | 24 |
| zig-hash, round 2 | **19** | **20** |
| `rust` (std + FxHash), its hit loop | about 18 | |

arm64 round 2: `mul ror lsr add ld1r add ldr cmeq fmov ands b.eq madd prfm
ctz add ldr cmp b.ne ldr`. x86-64: `imul rorx shrx movzx vpbroadcastd mov
shl vpcmpeqb vpmovmskb and je imul lea prefetcht0 tzcnt shl cmp jne add
mov`. What is left above `rust`'s: the prefetch (one, and it pays at
3M-4M), the overflow lane's `and 0x7fff` on x86, and the slot multiply
by 15 or 7 (`rust`'s slots are a bucket each).

### What changed, kept

- **The home group peeled from the probe loop.** The first matching
  lane is tested with no loop; the other lanes and the other groups
  follow inline. With them out of line (`peel_inline = false`), the
  calls cost more than the loop: pup rnd1000 hit 1.53 against 1.30
  unpeeled. Inline, pup rnd1000 hit 1.26, mix16 1.04, mix1000 1.02
  (unpeeled 1.32, 1.09, 1.06); Mac rnd1000 hit 0.85 against 1.15,
  misses 25-40% faster at every size.
- **The overflow byte read volatile,** so it is loaded on the way to a
  miss, not extracted from the group (`umov`, `vpextrb`) ahead of the
  tag branch, where every hit paid for it.
- **The slow path makes the home again from the hash.** Passing it
  spilled five fields to the stack on every lookup.
- **Groups of 7 rehash a drifted table to 0.5 full,** not 0.6: at 0.6,
  churn1000 rehashed at its own size (Mac 3.27 against foa's 2.47); at
  0.5, 1.68, and churn16 3.71 against 5.13.

### Tried, dropped

- **x86 byte offsets** (group and slot addresses from one shift and a
  mask): one instruction more, as LLVM makes the multiply by 15 two
  `lea`s. Kept as `byte_home`, off.
- **A size gate on the prefetch** (none below 8 MiB of slots): the test
  stayed in the loop and cost small maps' hits 10%.
- **Prefetching both ends of a 7-slot group**: Mac rnd3M/4M hit 3-6%
  slower.

### Decision 7, rerun

Interleaved, fastest of 7, on pup core 0, zig-hash against itself with
`.int_mul = false`: mix16 1.03 against 1.18, mix1000 1.02 against 1.17,
so one multiply is 15% faster on both, and faster on every small row
(rnd16 hit 10%, rnd24 36%, rnd1000 17%; Mac mix16 17%, mix1000 19%). The
round-1 gap on the mix rows was the unpeeled probe. **Adopted.**

### Where it stands

The HashMap's 44 rows (as in round 1), against the competitors' runs of
this afternoon; both machines were shared (Mac load 4-8, pup's other
cores busy), so read gaps under 5% as ties.

- **Mac: won or level 29 of 40 timed** (the remove and churn rows from
  the full run: 31 of 44). Every mix row is won now, and every miss.
  Lost: rnd16 and rnd24 hit by 3% (rust), rnd4M hit by 3% (absl), level
  by the noise rule; rnd150000 hit by 11% and rnd3M hit by 8% (rust);
  big16 to big1M hit by 7-20% (rust); lat100000 by 5% and lat4M by 10%
  (absl); big100000 remove by 10% (dense).
- **pup: won or level 24 of 44** (round 1: 23). Mix16 and mix1000 within
  5% of `rust` (round 1: 30% behind); rnd16 hit by 10%, rnd1000 20%,
  rnd1500 15%, rnd100000 43%, rnd150000 18%, rnd3M 24% (rust), rnd4M 5%
  (hashbrown); mix4M 29% (rust); big hits 5-17% (rust); big removes
  (dense, the ordered Map's rows); lat4M 6% (absl). The rnd100000 and
  rnd150000 remove rows moved with the neighbours' load this run (foa
  9.7 and 13.6, against 6.0 and 6.8 this afternoon); against foa in the
  same run zig-hash is 28% faster on both.
- **x86 hits.** Our 20 against `rust`'s about 18 leaves 10-20% at L1
  sizes; from 100k up the gap is memory parallelism (more lookups in the
  reorder window). Groups of 7 on x86 (round 1) win those hits and lose
  inserts.
