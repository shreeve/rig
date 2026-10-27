# Hash race panel: the hardware view (2026-10-27)

What the two machines reward and punish in a hash table, row by row,
and what that means for the two Zig contestants (the ordered `Map` and
the unordered `HashMap`) and for what Rig must learn to emit. It builds
on [../design-study.md](../design-study.md) (cited as "the study") and
says where it disagrees (§6).

The numbers are from
[mac-v2-one-round.txt](mac-v2-one-round.txt) (one round, the Mac, all
15 contestants, with the `lat`, `churn` and `mix` rows) and
[../pup-race.txt](../pup-race.txt) (the first round's pup run, fastest
of 5, no `lat`/`churn`/`mix` rows). The five-round Mac run
(`scratchpad/v2-mac/result.txt`) was still empty when this was written,
so one-round Mac figures carry one round's noise: read gaps under 5% as
ties. Nothing was benchmarked for this report. Three things were
checked by hand: the machines' cache and page facts (`sysctl`, and one
`ssh pup` read of `/sys` and `lscpu`), the CPU Zig targets on the Mac,
and the code Zig 0.17 makes for four group-match kernels (§2).

## 0. The two machines

| | Mac (Apple M5, a P-core) | pup (Core Ultra 9 185H, a P-core) |
|---|---|---|
| Cache line | 128 bytes (`hw.cachelinesize`) | 64 bytes (the L2 spatial prefetcher fetches 128-byte-aligned pairs) |
| L1 data | 128 KiB (`hw.perflevel0.l1dcachesize`) | 48 KiB |
| L2 | 16 MiB, shared by the 4 P-cores | 2 MiB per core |
| Last level | a system cache, size not published | 24 MiB L3 |
| Base page | 16 KiB | 4 KiB |
| Huge pages | none I know a program can ask for on Apple silicon (worth a ten-minute probe of `mmap` with `VM_FLAGS_SUPERPAGE_SIZE_ANY`) | THP `[madvise]`, defrag `[madvise]`, 2 MiB, kernel 7.0, glibc 2.43 |
| TLB reach | M1's published L2 TLB is about 3,072 entries, about 48 MiB at 16 KiB; M5's is not published | the Golden Cove family's shared STLB is about 2,048 entries: 8 MiB at 4 KiB, 4 GiB at 2 MiB |
| What Zig targets for Rig | `apple_m5`, with CSSC (one-instruction `ctz`) and CRC32 (checked: `builtin.cpu.model.name`) | `meteorlake` native: AVX2, BMI1/2, POPCNT, LZCNT |
| What the C++ and Rust contestants target | Apple clang's and rustc's default, `apple-m1`: no CSSC, so `ctz` is `rbit` + `clz` | `bench-hash` passes only `-O3` (`bench/hash/bench-hash:110`) and rustc no `target-cpu`: baseline x86-64, SSE2 only |

Two consequences before any design talk:

1. **The race is not ISA-matched.** Rig and Zig build for the native
   CPU; C++ and Rust build for a baseline. On pup that takes SSSE3
   away from abseil's `MaskEmpty` (`psignb`, `hashtable_control_bytes.h:276-357`)
   and SSE4.2 from its CRC32 hash. The effect on a probe is small (a
   cycle here and there), but a first place must not rest on it.
   Decision 1 below.
2. **Rig's 4M insert lead on pup is page faulting, not the table.**
   `src/alloc.zig:80-88` faults a new large block in with one
   `madvise(MADV_POPULATE_WRITE)`; every other contestant takes one
   fault per 4 KiB page. A 4M build touches about 250 MB of fresh
   pages, some 60,000 faults, on the order of 10 ns an insert. That is
   why Rig's Map wins `rnd4000000 insert` on pup (33.27 ns against
   abseil's 41.26) and loses it on the Mac (17.55 against boost's 13.78),
   where nothing populates pages ahead. It is a real gain for Rig's
   users and the new maps keep it, but it says nothing about the
   table.

## 1. What each row costs, and who wins it

### 1.1 Where each size lives

For `Map[Int, Int]`-shaped tables (16-byte entries), the footprints at
the four sizes, from each table's sizing rule:

| Keys | boost FOA | abseil / hashbrown | ankerl dense | Rig Map today | Lives in |
|---|---|---|---|---|---|
| 16 | one group | 16-32 slots | one block | 16-32 slots | L1, both machines |
| 1k | 128 groups: 2 KiB metadata, 30 KiB slots | 2,048 slots, load 0.49 | 16 KiB values, 1 KiB-ish index | tags 2 KiB, `at` 8 KiB, entries 24 KiB, load 0.49 | L1 on the Mac; at the edge of pup's 48 KiB |
| 100k | 8,192 groups, load 0.81: 128 KiB metadata, 1.9 MiB slots | 131,072 slots, load 0.76: 128 KiB control, 2 MiB slots | 1.6 MB values, 704 KiB index, load 0.76 | 131,072 slots, load 0.76: tags 128 KiB, `at` 512 KiB, entries 3 MiB | Mac L2; pup L2 spilling to L3 |
| 4M | 2^19 groups, load 0.51: 8 MiB metadata, 120 MiB slots | 2^23 slots, load 0.48: 8 MiB control, 128 MiB slots | 64 MiB values, 44 MiB index | 2^23 slots, load 0.48: tags 8 MiB, `at` 32 MiB, entries 96 MiB | DRAM and TLB misses on both; the small metadata arrays fit the Mac's L2 and pup's L3 |

So the four columns are four different machines: at 16 and 1k the
row measures instructions and branch prediction; at 100k, load-to-use
latency of L2 (Mac) or L3 (pup) and how many loads are in series; at
4M, DRAM latency, TLB walks, and how many misses one core keeps in
flight. A design can win one column and lose the next, and the data
shows it doing so.

### 1.2 Lines touched and loads in series, per operation, at 4M

| | Hit | Miss | Remove | Iterate |
|---|---|---|---|---|
| abseil | control group and slot line issued together (prefetch before the match, `raw_hash_set.h:3653-3657`): 2 lines, 1 wait | control, plus the same slot prefetch, wasted: 2 lines | find, then 2 more group reads to choose empty or tombstone | every control byte, and 2.1 slots read per element at load 0.48 |
| hashbrown | control, then slot: 2 lines, 2 waits (no prefetch anywhere) | control only: 1 line | as abseil | as abseil |
| boost | metadata (16 aligned bytes, 1 line), match, then slot: 2 lines, 2 waits, but the metadata is cache-resident (8 MiB) | metadata only, ends at the overflow bit: 1 line, about 1 in 254 slots a false compare | find, one byte stored to a line already in L1 (`recover_slot`, `foa/core.hpp:2260-2268`) | metadata plus 2 slots per element |
| ankerl | block (88 bytes, 1-3 lines), then `values[idx]`: 2 waits | block only, ends at a zero counter | find, uncount, move the last value, re-find its slot: 2 probes | the dense vector only: 16 bytes an element, streamed |
| indexmap | control, then the index slot, then the entry: 3 waits | control only | find, swap-remove, re-find | the dense vector |
| Rig Map | `tags` and `at` in parallel (both addresses from the hash), then `es[j]`: 3 lines, 2 waits | `tags` by linear probe, one byte and one branch a step | backward shift that hashes each later key again, reading its entry: several dependent misses | 24-byte entries, each tested for `none` |
| Zig std | metadata, then key and value lines in parallel: 3 lines, 2 waits | metadata | tombstone | metadata, keys, values |

### 1.3 Why the leaders lead

**boost wins misses and removes** because its metadata is the smallest
in the field, 16 bytes a group of 15 (1.07 bytes a slot), always
aligned so a group is one line, and a miss reads nothing else: the
overflow bit stops it in its home group (`is_not_overflowed`,
`foa/core.hpp:275-280`), and its almost-8-bit tags make half as many
false key compares as 7-bit ones (a false compare at 4M is a DRAM
miss). At 4M its 8 MiB of metadata sits in the Mac's L2 and pup's L3,
so a miss costs a cache hit, not a memory access: `rnd4000000 miss` is
5.75 ns on pup against hashbrown's 6.72 and abseil's 9.80. An erase is
one byte written to a line the find just loaded, with no neighbour
reads and no tombstone to clean up later: `rnd100000 remove` 3.56 ns
on the Mac against hashbrown's 7.09 and Rig's 22.21.

Where boost loses misses, it loses on the scan, not the layout: on the
Mac its 16-lane NEON match is SIMDe's movemask emulation (`vandq`,
`vzip`, `vaddvq`, `foa/core.hpp:571-588`), five vector instructions
before the general register, and ankerl's nibble mask beats it while
both fit in cache (`rnd100000 miss` 1.83 ns against 2.42;
`rnd150000` 1.48 against 1.78). On pup, with `pmovmskb`, boost wins the
same rows (3.00 against ankerl's 3.24 at 100k).

**ankerl and indexmap win iteration** because they walk one packed
array of 16- or 24-byte entries in order, reading no metadata. The
hardware prefetcher streams it and LLVM vectorizes the sum: 0.08 ns an
element for indexmap at 1k (about a third of a cycle), 0.21 ns for
ankerl at 4M, which is 16 bytes every 0.21 ns, about 76 GB/s, the
Mac's streaming bandwidth for one core. At 4M iteration is a bandwidth
row: the winner is whoever moves the fewest bytes per element. Rig's
Map walks 24-byte entries and tests each `V?`, so it runs 0.47-0.50 ns
an element at every size, scalar: 2.3 times ankerl's time at 4M and
5.9 times indexmap's at 1k. A flat table walks 1/load slots per
element plus the metadata: abseil 4.68 ns at 4M.

**abseil wins hits at 4M** (`rnd4000000 hit` 6.28 ns on the Mac against
hashbrown's 7.18 and boost's 8.27; 16.17 on pup against hashbrown's
17.28) because its slot prefetch is issued from the hash alone, before
the control bytes arrive (`raw_hash_set.h:3653-3657`), and its probe
starts at the key's own slot (`seq.offset()` is slot-granular), where
an insert puts the key whenever that slot is free. At load 0.48 most
keys sit in or near their home slot, so the prefetched line is usually
the right one: the slot miss starts as early as the control miss and
one wait covers both. The same prefetch is the reason abseil loses
misses at 4M: it fetches a slot line for a key that is not there,
42% more time than hashbrown on the Mac (3.51 against 2.48) and 46%
more on pup (9.80 against 6.72). **Prefetching before the match buys
hits and costs misses, at the same size.** §3.1 takes this up.

### 1.4 Two findings the study did not have

**The latency rows in cache go to scalar probing.** `lat16` and
`lat1000` are won by Zig's `std.HashMap` (4.31 and 4.57 ns) with Rig's
Map next (4.58, 4.75); abseil takes 6.70-6.72, hashbrown 7.0-9.0, boost
8.2-8.5, and ankerl 9.1-9.8, twice Rig's time. The reason is what sits
on the critical path. A SIMD group puts a data dependence there: load
the group, compare, move the mask to a general register, `ctz`, form
the slot address, load the slot. A byte probe puts a control
dependence there: the branch "this tag matches" is predicted, so the
core loads `at[i]` and `es[j]` speculatively while the tag is still
arriving. A predicted branch costs nothing on the chain; a
vector-to-general move and a `ctz` cost several cycles each, every
step. In throughput rows the same branches mispredict at random and
the SIMD designs win (`rnd1000 hit`: Rust std 0.86, Rig 1.26). Caveat:
at 16 keys the chain repeats every 16 steps, so a long-history
predictor learns every outcome; `lat16` and the other 16-key rows
partly measure a trained predictor.

This matters for the ordered Map: the study's ankerl index would trade
Rig's 4.75 ns `lat1000` for ankerl's 9.14, a row Rig nearly wins today.

**Rig's miss cliff is linear probing's arithmetic.** Linear probing
expects ½(1 + 1/(1 − α)²) probes for a miss and ½(1 + 1/(1 − α)) for a
hit. Rig's table at 100k keys is 0.76 full (9.2 probes a miss), at 150k
0.57 (3.2), at 4M 0.48 (2.3). Measured misses: 9.89 ns, 3.07 ns, 10.01
ns (the last one memory-bound). The 3.2x between 100k and 150k is the
formula's 2.9x. Every step is a byte compare and a branch that
mispredicts at its exit. No layout tweak fixes this; group probing with
an overflow stop does.

### 1.5 Each row, each size: what the winner must do

| Row | 16 | 1k | 100k | 4M |
|---|---|---|---|---|
| hit | fewest instructions; hash-free scan of small maps | fewest instructions, one predictable branch per lookup | one wait: the slot load must not wait on the match more than an L2 latency | one DRAM wait; slot line requested with the metadata |
| miss | as hit | one group read, an exact stop | metadata small enough for L1/L2; overflow stop; 8-bit tags | metadata that stays cached (16 bytes a group); no slot prefetch on a miss |
| insert | no table, no allocation chain | inline insert into room | growth that writes the new table in order (high-bit positions) | page faults (prefault, huge pages) and growth that streams |
| remove | a byte store | a byte store | a byte store, no neighbour reads | find plus a byte store; no tombstones, no shift |
| iterate | dense, vectorizable | dense, vectorizable | dense | bytes per element: 16, not 24 |
| lat | predicted scalar first probe | predicted scalar first probe | fewest loads in series | 1 DRAM miss (flat); 2 is the ordered floor |
| churn | byte-store erase | byte-store erase, anti-drift | no tombstone buildup (Zig's std collapses: 101,850 ns at 100k) | find plus a byte store, appends that stream |

## 2. Group width and scan, per architecture

### 2.1 What the instructions are

Compiled by Zig 0.17 `-OReleaseFast` for this question (the kernels
are a 16- or 8-byte load, a compare against a broadcast tag, the first
matching lane):

- **arm64, 16 lanes, `@bitCast` of the mask** (what Rig's `bits()` is
  today): `ldr q`, `cmeq.16b`, `adrp` + `ldr q` (a constant), `and.16b`,
  `ext.16b`, `zip1.16b`, `addv.8h`, `fmov`, `ctz`. Seven vector
  instructions, one of them a constant load, and `addv` is a reduction.
- **arm64, 16 lanes, nibble mask**: `ldr q`, `cmeq.16b`, `shrn.8b #4`,
  `fmov x, d`, `ctz`, `lsr #2`. Three vector instructions.
- **arm64, 8 lanes, NEON**: `ldr d`, `cmeq.8b`, `fmov x, d`, `ctz`,
  `lsr #3`. Two vector instructions.
- **arm64, 8 lanes, SWAR in a general register**: `ldr x`, `eor`, `add`
  (of the -0x0101... constant), `bic`, `and` (0x8080...), `ctz`, `lsr
  #3`. No vector register at all; the broadcast tag and the constants
  are hoisted out of a loop. The "zero byte" trick gives false
  positives only in bytes above a true one, so the first lane is exact
  and "is any lane free" is exact.
- **x86-64, 16 lanes**: `vpcmpeqb` (with the load folded in),
  `vpmovmskb`, `tzcnt`. On the baseline target, `pcmpeqb`, `pmovmskb`,
  `bsf`, the same latency on Intel cores.
- **x86-64, nibble form**: `vpcmpeqb`, `vpsrlw`, `vpshufb` (with a
  constant), `vmovq`, `tzcnt`. Worse than `pmovmskb`: the lane form
  must be chosen per target, never written once.
- On `apple_m1` every `ctz` above is `rbit` + `clz`; on `apple_m5`
  (what Rig builds here) it is one `ctz`. The study's §4.3 item 7
  assumed two.

### 2.2 How to weigh them

The vector forms pay a crossing from the vector file to the general
file (`fmov`) on every probe, and the crossing has latency the general
form does not. hashbrown says its 16-lane NEON attempt lost to the
generic SWAR group because "most NEON instructions have multi-cycle
latency" (`control/group/mod.rs:14-16`), and it settled on the 8-lane
NEON form (`neon.rs:67-70`). Go uses SWAR. ankerl measured the nibble
form as its largest arm64 gain (the study, §1.5). The data agrees with
all three in its own way:

- In throughput rows in cache, the fewer instructions, the better, and
  the 16-lane nibble mask is cheap enough: ankerl's misses beat boost's
  emulation on the Mac (§1.3).
- At high load, an 8-lane group ended by an empty byte is bad:
  hashbrown on the Mac misses in 4.92 ns at 100k keys (load 0.76) and
  1.54 at 150k (0.57), 3.2 times as slow, while boost's 15-lane
  overflow-ended groups go from 1.78 to 2.42. A first-order estimate
  (Poisson occupancy, no cascade) says an overflow-ended group of 7
  sends 6.8% of misses past home at load 0.875, against 7.4% for a
  group of 15: with an overflow byte, 8-byte groups are not the
  problem; empty-terminated 8-byte groups are. The cascade (overflowed
  keys filling the neighbour) makes small groups somewhat worse than
  the estimate, which is why it must be measured.
- In the latency rows the crossing is on the chain; the SWAR form has
  none, and its four ALU operations run on cores with many integer
  pipes.

On x86-64 there is nothing to weigh: 16 lanes, `pmovmskb`, `& 0x7FFF`
for a 15-slot group. AVX2's 32 lanes buy nothing at these loads
(hashbrown's note, `control/group/mod.rs:9-12`), and pup's cores have no
AVX-512.

**My default:** the boost layout (15 tags and an overflow byte in 16
bytes) on both targets, scanned with `pmovmskb` on x86-64 and the
nibble mask on arm64, so one layout and one source serve both and
only the mask function differs. Switch arm64 to 7-slot groups (8 bytes,
SWAR or `cmeq.8b`) only if they win the throughput rows by more than
5%, since a second layout is a second set of bugs.

### 2.3 What to measure first

Before either map is written: a pointer chase through the match
kernel alone, in L1, on the Mac. A 4 KiB array of groups; each step
loads a group, matches, and uses the lane to form the next address.
Cycles a step, for the four arm64 kernels above. Then the same kernels
in a throughput loop (independent groups). Seconds to run, and it
answers the question that decides arm64's group width: how much the
vector-to-general crossing costs on M5 against SWAR's ALU chain.
Apple publishes no latencies, and I would not guess them.

Then experiment 1 (§5) puts the winners in a table.

## 3. Prefetch, pages, alignment, and one miss per lookup

### 3.1 Prefetch

- **In a lookup.** The only prefetch that shortens a lookup is one whose
  address is known from the hash alone, issued before the metadata
  arrives: abseil's (`raw_hash_set.h:3656`). boost prefetches after the
  match (`foa/core.hpp:1733`), when the demand load of `p[n]` is
  one instruction away; on x86 it fetches the group's first line, which
  is not the matched slot's line for most of a 15-slot group (240
  bytes, four x86 lines), and on ARM it fetches half the group at a
  64-byte step (`foa/core.hpp:106-126`), two prefetches to one Apple
  line. That is close to no prefetch at all.
- **The conflict at 4M.** Prefetch first wins hits and the half-hit
  mix (`mix4000000`: abseil 8.40, hashbrown 9.00, boost 9.90 on the
  Mac) and loses misses (§1.3). Both rows are at the same size, so a
  size gate cannot separate them, and the map cannot know a lookup's
  outcome before it is done. The choice is a measurement (experiment
  2). My expectation: prefetch-first wins more 4M rows than it loses
  (hit, mix, and at 100k `lat`: abseil's 10.91 against hashbrown's
  13.04), but it hands the miss rows to hashbrown and boost. If the
  owner counts rows, the measurement decides; if he wants no row
  given up, the API can say what the caller expects (`has` on a
  table known to miss often), which is a design question, not a
  hardware one.
- **Placement that makes the prefetch land.** A prefetch from the hash
  helps only if the key is usually in the line it names. With boost's
  fill-from-slot-0 placement it is not; with a start slot chosen by
  hash bits and a fill that wraps within the group, the home slot's
  line holds the key most of the time at load 0.5 and often at 0.875
  (on the Mac, 8 slots share a 128-byte line). Worth one arm of
  experiment 2.
- **In growth and bulk work.** ankerl's 16-deep lookahead ring for its
  rehash, gated to indexes of 256 KiB or more
  (`unordered_dense.h:2050-2100`), is the right shape for both maps'
  rebuilds; boost uses the same depth for bulk visits.
- **On the Apple cores** the hardware prefetchers follow strides well;
  that is why the `int` rows misled (README). They do nothing for a
  random probe, so a software prefetch there is all-or-nothing.

### 3.2 Huge pages

On pup at 4M, a flat table of about 130 MiB is about 33,000 4-KiB pages
against a shared STLB of about 2,048 entries, so nearly every random
access walks the page table; with 2-MiB pages it is 65 entries, which
all stay resident. Walks cost on the chain (the PTE line is itself a
cache access) and, in throughput rows, they cap the misses in flight
at the number of page walkers (four on recent Intel cores). ankerl
measured huge pages as its largest single gain: integer build 1.7x,
churn 1.25x, find 1.1x (the study, §4.3). pup runs THP in `madvise`
mode, so today **no contestant has huge pages**: glibc's `malloc` does
not ask for them, and neither does Rig's allocator.

What to build: in `src/alloc.zig`, for large blocks of 2 MiB or more on
Linux, map 2 MiB more than asked, align the start to 2 MiB, trim, and
`madvise(MADV_HUGEPAGE)` before the existing `MADV_POPULATE_WRITE`.
Caveats: defrag `madvise` means a fault in such a region may compact
memory directly, a stall when memory is fragmented; RSS rounds up to
2 MiB per block, so Trig's peak memory is the bar (the study's
decision 6). For a fair table panel, the C, C++ and Rust contestants
run once more with `GLIBC_TUNABLES=glibc.malloc.hugetlb=1`, which makes
glibc ask for THP on its own large blocks (glibc 2.35 or later; pup has
2.43). Decision 2.

On the Mac, 16-KiB pages already give four times x86's reach, and I
know of no huge pages a program can ask for. The Mac's lever is
footprint: the smaller the arrays a lookup touches, the more of them
the L2 and the TLB hold.

### 3.3 Alignment

- **Metadata groups aligned to 16 bytes**, probed group by group (boost,
  Go), so a group never splits a line. abseil probes in slot units and
  reads 16 bytes at any offset; on x86 15 in 64 of those reads split two
  lines.
- **Slots fetched by the matched lane, not by the group's start.** A
  15-slot group's slots start at `240 * g`, not on a line; once the
  lane is known, load that slot's line and nothing else.
- **ankerl's 88-byte index block** straddles a 128-byte Apple line
  whenever its start falls more than 40 bytes into a line, 10 of the 16 eight-byte offsets (62% of blocks), and touches three
  64-byte lines on x86 for a quarter of them (ankerl's own comment,
  `unordered_dense.h:2378-2383`). On the Mac, a 128-byte block, aligned,
  is one line and one TLB entry; on pup it is one aligned pair, which
  the L2 spatial prefetcher completes. It costs 45% more index memory.
  The alternative that shrinks instead: a 64-byte block of 12
  fingerprints, 4 counters (2-bit classes) and 12 `U32` indexes, one x86
  line, half an Apple line, the counters in the same 16-byte vector as
  the fingerprints (masked off as boost masks its overflow byte). ankerl
  found 11 slots lost to 16, but not for an aligned 64-byte block. Both
  are one arm of experiment 2.
- **Large Lists aligned to the line** (64 on x86, 128 on Apple): the
  runtime's large blocks are page-aligned already; a small table's
  arrays need a List alignment the runtime can give.

### 3.4 Tags and slots: one line or apart

Apart, as boost and abseil have them. Together (Go's group: a control
word and 8 slots) has one appeal on the Mac: 8 bytes of metadata and 7
slots of 16 bytes are 120 bytes, one 128-byte line and one TLB entry a
probe. But a miss then reads a whole slot line instead of 16 bytes of
cached metadata, so the miss rows at 4M would cost what hits cost
(about 8 ns against boost's 2.84 on the Mac, three times as slow), and
iteration reads every slot. It wins only the latency row, and the
latency row is already at the floor apart (§3.5). Keep them apart.

### 3.5 The latency row at 4M: getting to one miss

`lat4000000`: abseil 86.41 ns, boost 86.30, hashbrown 95.88-101.29,
Zig 96.32, Go 102.44, ankerl 153.94-185.76, Rig 183.37, indexmap
195.80-199.88. The flat maps cluster at about 86 ns and the dense maps
at about 1.8 to 2.3 times that: the row counts DRAM misses in series.

- **The flat maps are already at one miss.** The 8 MiB of metadata
  mostly hits the Mac's 16 MiB L2; the slot line is the one DRAM miss,
  plus a page walk. abseil and boost tie at 86 although only abseil
  prefetches first, which says the match is short next to DRAM. 86 ns
  is close to this Mac's floor for one random DRAM access with a TLB
  miss; there are perhaps 5-10% left on the Mac (the hash, the scan
  and the crossing on the chain, the metadata kept small enough to stay
  in L2), and more on pup, where 2-MiB pages remove the walk. The
  `HashMap` should take this row by being boost's layout with a
  cheaper chain, not by a new idea.
- **Rig's Map is at two misses and three arrays.** `tags` and `at` load
  in parallel from the hash, then `es[j]` waits for `at`. Its `at`
  array alone is 32 MiB at 4M, so both waits are DRAM, and three arrays
  are three TLB entries a step.
- **Any ordered dense map is at two.** The entry's address is in the
  index, so the entry cannot be fetched before the index arrives; that
  is the second miss, and no layout that keeps entries dense and in
  insertion order removes it (the study, §4.1; map-stage's packed
  slots removed it and lost iteration by 10.7x). What the ordered Map
  can do: make the index wait short (index small enough to stay in L2
  or L3: 5.5 bytes a slot or less; its second line prefetched with the
  first, ankerl's 3 cycles), take huge pages on pup, and keep 16-byte
  entries. Its bar on `lat4000000` is first among ordered maps (under
  ankerl's 154 ns), not first overall. Decision 3.

## 4. What Rig can emit, and how safe each technique is

| Technique | Zig | Rig today | Class |
|---|---|---|---|
| Load 16 or 8 metadata bytes from a List | `@Vector` load | `bytes.read[Simd[U8, 16]](at)`, checked once (SPEC §2) | safe by construction; the check goes away **once Rig gains a proof** that `h >> shift < groups` (a shift fixed by the table size) or that `i & (n - 1) < n` for a power-of-two `n` |
| Compare to a broadcast tag | `==` on vectors | `==` on `Simd`, `Simd.splat` | safe by construction |
| First matching lane | `@ctz` of a per-target mask | `m.first()`, already the nibble form on NEON (`src/runtime.zig:4697-4728`) | safe by construction |
| Every matching lane, in order | the mask, `ctz`, `m &= m - 1` | `m.bits()`, which on NEON is the seven-instruction form of §2.1 | **needs a form Rig lacks**: `m.lanes()` or a strided `bits`, lowered to `pmovmskb` on x86 and `shrn` on NEON with the stride known when the program compiles (the study's decision 3); safe by construction |
| SWAR on 8 bytes | `u64` arithmetic | `read[U64, little]`, `^`, `-%`, `&`, `trailing_zeros()` | safe by construction, today |
| Prefetch | `@prefetch` (`prfm pldl1keep`, `prefetcht0`) | none | **missing**; safe by construction: a prefetch never faults and changes no value, and the index it is given is the masked index the probe uses anyway |
| A branch hint inside a function | `@branchHint(.likely / .unlikely)` | `rarely` on a whole function (`@branchHint(.cold)`, `src/emit.zig:1947`) | **missing**; safe by construction (a hint only) |
| Hot path inline, slow path out of line | `inline fn`, a cold function | `inline fun`, `rarely` | safe, today |
| Entry index read from the index, then `es[idx]` | an unchecked index | a checked index | keep the check: it is a compare and a predicted branch, off the chain (the load issues speculatively), so it should cost under a cycle; measure in `--release` before building a type for it. **Safe once Rig gains a type** (an index branded by its List) if it ever shows |
| Free slots holding stale copies of plain entries | plain arrays | done in #685 for `$plain` | safe by construction for plain `K` and `V` |
| Uninitialized slots for owning `K` or `V` | `undefined` | not expressible | **raw-only** today; **safe once Rig gains a type**: a niche in `String` and the objects that hold one, so a slot's `?` costs no byte (the study §4.3 item 5) |
| Lines-aligned arrays | `alignedAlloc` | page-aligned large blocks; no alignment for small Lists | runtime work; safe by construction |
| Huge pages, prefaulted and zeroed pages | `madvise`, `mmap` | prefault yes (`src/alloc.zig:80-88`); huge pages no | runtime work in `src/alloc.zig`; safe by construction |
| CRC32 hash on arm64 | `@"llvm.aarch64.crc32cx"` as the runtime already calls `umaxv` | not exposed | safe; not recommended: one folded multiply is as short on the chain |
| Non-temporal stores for rehash | inline asm or LLVM metadata | none | not needed: a rehashed table is read right after |
| Inline asm | `asm` | none | **nothing in either design needs it** |

So the only language-level gaps are three, all safe by construction:
a per-target lane walk over a mask, `prefetch`, and a branch hint
inside a function. Two proofs remove bounds checks (`h >> shift` and a
power-of-two mask), and one type (a niche for owning types) gives
owning maps the plain layout. The rest is runtime work.

## 5. The first two Zig experiments

Both use one Zig source per variant, one binary per variant (code
placement moves Apple loops by 5-7%), the `bench/hash` rows and
checksums, Rig's integer hash, `Map[Int, Int]`-shaped keys and values,
and both machines, interleaved, fastest of N.

### Experiment 1: the probe on the core (arm64 width, scan, and first probe)

One `HashMap(u64, u64)` with boost's layout (metadata groups, high-bit
group index, low-byte tag with 0 and 1 remapped, overflow bits,
byte-store erase, separate slot array), varied only in the match and
the first probe:

- arm64: (a) 15+1 lanes, nibble mask; (b) 15+1 lanes, Rig's current
  `bits()` form, as the baseline that shows what the `lanes()` form is
  worth; (c) 7+1 lanes in 8 bytes, `cmeq.8b` + `fmov`; (d) 7+1 lanes,
  SWAR in a general register; (e) the winner of (a)-(d) with a scalar
  first probe: insert prefers a hash-chosen home slot, and a lookup
  compares the home slot's tag byte and key directly, by a predicted
  branch, before the group match.
- x86-64: (a') 15+1, `pmovmskb`; (d') 7+1 SWAR; (e') (a') with the
  scalar first probe.

Rows: `rnd1000` and `rnd1500` hit and miss, `mix1000`, `lat16`,
`lat1000`, `rnd100000` and `rnd150000` miss, `mix100000`, `churn1000`.
All in L1 or L2, so each run takes seconds.

What it proves: which group width and scan both maps are built on, per
target (§2.2's default holds, or arm64 gets its own layout); what the
`lanes()` form is worth, which tells the owner how much the language
change buys; and whether a predicted scalar first probe can take the
in-cache latency rows from Zig's `std.HashMap` without costing the
throughput rows, which decides whether the ordered Map keeps a scalar
first probe on top of ankerl's index.

### Experiment 2: the probe against memory (prefetch, pages, blocks)

The experiment-1 winner, varied in what it asks of memory:

- prefetch: (i) none (load the matched slot after the match), (ii) the
  home slot's line from the hash, issued right after the metadata load
  (abseil's order), (iii) as (ii) with the hash-chosen home slot of
  experiment 1's (e), so the prefetched line is usually the key's;
- pages, on pup: (p0) as today, (p1) 2-MiB-aligned `MADV_HUGEPAGE`
  blocks; the C++ and Rust contestants run beside both with and
  without `GLIBC_TUNABLES=glibc.malloc.hugetlb=1`;
- and for the ordered Map's prototype, the same two prefetch choices
  with three index blocks: ankerl's 88 bytes, 128 bytes aligned, and 64
  bytes of 12 slots.

Rows: `rnd3000000` and `rnd4000000` insert, remove, hit, miss;
`mix4000000`, `lat100000`, `lat4000000`, `churn4000000`, and `mem`.

What it proves: whether the `HashMap` prefetches before the match
(trading miss rows for hit and mix rows) or not; how much of the 4M
rows on pup are page walks, and so whether huge pages are worth the
allocator change; which index block the ordered Map uses on each
target; and how close the Map comes to ankerl's 154 ns on
`lat4000000` with a two-miss floor.

## 6. Where I disagree with the study

1. **Prefetch order (§4.2).** The study says issue the slot prefetch
   with the metadata load, abseil's order, as a plain win. The data
   says it wins hits and loses misses at the same size (abseil's 4M
   misses are 42% slower than hashbrown's on the Mac, 46% on pup).
   Measure it (experiment 2); do not assume it.
2. **`ctz` on arm64 (§4.3 item 7).** On this Mac Rig builds for
   `apple_m5`, which has CSSC: `ctz` is one instruction (checked in the
   disassembly). Only the C++ and Rust contestants, built for
   `apple-m1`, pay `rbit` + `clz`.
3. **ankerl's block on Apple lines (§4.1).** The 88-byte block and its
   "prefetch the second line" are x86 reasoning. On 128-byte lines most
   blocks straddle two lines; test a 128-byte aligned and a 64-byte
   block (§3.3).
4. **The ordered Map in the latency rows (§4.1).** The study expects
   (a) to lead iteration, small inserts, misses to 100k and take; I
   agree, but the ankerl index costs the in-cache latency rows the
   current Map nearly wins (ankerl 9.14 ns on `lat1000` against Rig's
   4.75). Keep a predicted scalar first probe if experiment 1 shows it
   is free in throughput.
5. **The bar (§5).** Add ISA parity and huge-page parity to §5's
   hygiene list; today Rig builds native and its rivals build baseline,
   and on pup only Rig prefaults pages.
6. **Group width (§4.2).** Agreed on 16 lanes and the nibble mask as
   the default, but with a reason the study does not give: the 8-lane
   groups lose at high load because they are ended by an empty byte,
   not because they are 8 lanes (hashbrown's 100k misses on the Mac,
   §2.2). With an overflow byte, 8-lane SWAR groups are a real
   candidate on arm64, and the only one with nothing vector on the
   latency chain.

## 7. Decisions for the owner

1. **ISA parity in the race.** Default: build every contestant for the
   native CPU (`-march=native` or `-mcpu=native` for C++, `-C
   target-cpu=native` for Rust, `GOAMD64=v3` for Go on pup), so a first
   place is never an instruction-set difference.
2. **Huge pages.** Default: Rig's allocator asks for them on Linux for
   blocks of 2 MiB or more (aligned, before prefaulting), measured on
   Trig's peak memory first, and the race reports the 4M rows once more
   with glibc's huge-page tunable for the C++ and Rust contestants, so a
   first place does not rest on a setting the others could turn on.
3. **The ordered Map's bar on out-of-cache hits and `lat4000000`.**
   Default: first among ordered maps (beat ankerl and indexmap), with
   the unordered `HashMap` carrying first place on those rows; an
   ordered dense map waits for its index before its entry, and no
   layout that keeps the order removes that wait.
