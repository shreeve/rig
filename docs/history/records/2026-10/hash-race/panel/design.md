# Hash race panel: the design of the two maps that take first place (2026-10-27)

The hash-table design expert's report. It builds on
[../design-study.md](../design-study.md) (the study) and challenges it
where the newest data disagrees. The data is
[mac-v2-one-round.txt](mac-v2-one-round.txt): one round on the Mac, 15
contestants, `rig-fast` the built-in ordered Map. The five-round file was
still empty when this was written, so every number below is one round
and a gap under about 5% is not a finding. Times are nanoseconds per
operation. "Rust std + Fx" is the `rust` column (FxHasher); the podium
leaves it out, but where it leads, it is the stricter bar and is named.

## 0. What the data says that the study did not

1. **ankerl's merged 88-byte block loses misses at large sizes.** At
   100k keys, dense has the fastest miss (1.83 against boost's 2.42); at
   4M it is 2.3 times as slow as hashbrown-mix (5.44 against 2.37). A
   miss touches only fingerprints, and in a merged block they are 16
   bytes in 88; at 4M the index no longer fits in cache. The study
   adopted the merged block; this report splits it (§1).
2. **A dense map's hit at 4M is a second wait on memory, as the study
   said, and it measures 2 times.** rnd4M hit: absl 6.28, dense 12.52,
   indexmap 13.15, Rig 14.72. lat4M: boost-mix 86.3, dense 153.9,
   indexmap 199.9, Rig 183.4.
3. **boost loses churn near its maximum load.** churn100000: boost 13.06,
   boost-mix 11.95, against Rust std 7.37 and hashbrown-mix 7.43. 100k
   entries fill boost's 8192 groups to 0.81. Its anti-drift rule lowers
   the maximum load on erases, and the rehash it forces asks for
   `size + size/61 + 1` slots (`foa/core.hpp:2120-2135`), which rounds
   to the same 8192 groups: it rehashes the whole table at the same size
   every ~46k erases. At 1k and 4M boost sits near 0.5 load and wins
   (2.92 and 8.38).
4. **boost's element prefetch costs it the big-value hits.** big1000000
   hit: boost 19.89 against Rust std's 6.10 (3.3 times as slow); big100000
   5.72 against 2.11. On arm64 boost prefetches half a group's elements
   before the first compare (study §1.4): with 72-byte elements that is
   eight lines a lookup.
5. **The latency rows at small sizes go to scalar probing, not to SIMD
   groups.** lat16: Zig 4.31, Rig 4.58, absl 6.70, hashbrown 7.88, boost
   8.23, dense 9.78. lat1000 is the same order. Zig's and Rig's tables
   check one predicted slot: the core speculates past the tag compare
   and loads the entry while the tag is still in flight. A SIMD group
   makes the slot a data dependence through compare, vector-to-register
   move and count-trailing-zeros, about 12 cycles a lookup the core cannot
   skip. The study did not foresee this; it is the main risk of §2.
6. **Rig's iteration is slow because of the loop, not the layout.** Rig's
   Map is already dense, yet it walks at 0.42-0.50 at every size, against
   dense's 0.14-0.21 and indexmap's 0.08-0.32. Each entry tests a
   `V?` and goes through `next()`; the C++ and Rust walks vectorize.
7. **Rig's table quadruples.** It grows at 4/5 full and rebuilds to at
   most 2/5 (`table_size`), so each growth is 4 times: 100k keys sit at
   0.76 load and 150k at 0.29. Under linear probing that is the
   difference between rnd100000 miss 9.89 and rnd150000 miss 3.07.
8. **The string rows hide something else.** str100000 miss: Rig 69.65,
   seven times Rig's own Int miss at the same size and load (9.89), and
   13.6 times dense-mix. The table explains the Int number, not the extra
   60 ns. Profile map.rig's `str100000 miss` before building, so that a
   cost outside the table (the String compare, the view's hash, the
   order the texts were made in) is not carried into the new Map.
9. **Small builds are allocation counts.** str16 insert: boost 11.27,
   Rig 35.20. Rig's Map is four Lists (entries, hashes, tags, slots), each
   grown separately. rnd16 insert, where no table is built, Rig leads
   (7.55 against 8.30).
10. **The fold in the integer hash costs about 15% of a hit in L1.**
    rnd16 hit: Rust std + Fx 0.75, the same table with Rig's hash 0.88;
    rnd24 0.78 against 0.91; rnd1000 0.86 against 0.89. hashbrown and
    hashbrown-mix tie (foldhash's integer path is also one folded
    multiply). From 100k up the difference is within one round's noise.

## 1. (a) The ordered Map

### Layout

Three parts, each its own allocation:

- **Entries.** A dense array in insertion order. For plain `K` and `V`
  an entry is `{key, value}` with no optional: 16 bytes for
  `Map[Int, Int]`, against 24 today. For a key over 8 bytes the entry
  also holds the key's 64-bit hash: `{key, value, hash}`, 40 bytes for
  `Map[String, Int]`. The hash lives in the entry, not in a parallel
  List, so a String lookup reads it on the same line as the String's
  header, and the Map is one allocation fewer.
- **Gone bits.** A bitset, one bit an entry, allocated at the first take
  that leaves a hole; a count `dead`. Until then there is none.
- **The index.** One allocation of `G` groups, `G` a power of two, as two
  arrays:
  - **tags**: 16 bytes a group, 15 tag bytes and an overflow byte
    (boost's group);
  - **slots**: 64 bytes a group, 15 `U32` entry indexes and one spare,
    so group `g`'s slots are exactly one cache line.

  Tag: the hash's low byte with 0 mapped to 1 (0 is a free slot; the
  ordered Map never walks the index, so it needs no end sentinel), 255
  values, one false compare in 255 a slot. Group: `h >> shift`, the high
  bits. Overflow class: `tag & 7`.

The split is the change from the study. A miss reads only tags: 16 bytes
per 15 slots, the density boost and hashbrown have, so at 4M (2^19
groups, 0.51 full) a miss reads an 8 MB array, as hashbrown's 8.4 MB of
control bytes. A hit reads a tags line and a slots line whose addresses
both follow from the hash, so the slots line is prefetched with the tags
load and the two misses overlap; then the entry. The merged block costs
a miss its compactness to save a hit a line it can already overlap.

One variant to measure, not the default: **superblocks**, four groups'
tags (one line) followed by their four slot lines, 320 bytes, so a hit's
two lines share a page and one TLB walk. Misses read the same lines;
only their pages spread.

### Find, insert, take

- **Find.** `g = h >> shift`; prefetch `slots[g]` when the index is
  larger than L2 (a size test the predictor learns); match the tag over
  the 15 lanes; for each match, `j = slots[g][lane]`, compare
  `entries[j].key` (for stored hashes, the hash first); stop at the first
  group whose overflow bit for the class is clear; triangular probe
  otherwise.
- **Insert.** Push the entry at `n = entries written`; put `(tag, n)`
  in the first free lane from the home group, setting the overflow bit in
  each full group passed. The lookup and the insert into room are
  inline; growth and the walk past the home group are out of line.
- **Take.** Find; write 0 to the tag; when the group's overflow bit for
  the class is set, lower the maximum load by one (boost's anti-drift);
  set the entry's gone bit; `dead += 1`; move the value out and drop the
  key now. Two shortcuts: taking the last entry written just shortens
  the array (no gone bit), and a take that empties the Map resets it
  (entries written 0, gone bits dropped, tags zeroed, maximum load
  restored).

A take is one probe and three stores: no move of the last entry and no
second probe (ankerl's erase, which also loses the order), no backward
shift (today's, which hashes every later key again).

### Compaction, without a rehash

Takes never compact. Compaction runs only when an insert finds the
entries array full and at least a quarter of it gone (otherwise the
array doubles), and whenever the index grows (below), which compacts for
free.

Compaction at the same index size needs no hashing and no probing:

1. Move the live entries down, in order, 64 at a time by the gone word:
   a word of 0 moves as one block. Record `before[w]`, the gone count
   before word `w`.
2. Walk the index once, in order, and rewrite each full slot's `j` as
   `j - before[j >> 6] - popcount(gone[j >> 6] & ((1 << (j & 63)) - 1))`.
   Tags, overflow bits and positions are unchanged.

Both passes stream. The rank tables are 1/16 of a byte per entry and stay
in L2 at 4M. In churn4M (a take and an insert a step) the entries array
settles at 2 times the live entries and compacts once every ~4.4M steps:
about 26 bytes of streamed traffic a step.

### Iteration with holes

The walk is a run loop: from `j`, find the next gone bit by
count-trailing-zeros over the gone words, walk `entries[j..end]` as a
plain counted loop, skip to the next live bit, repeat. With no gone bits
it is one counted loop over a dense array. The body appears once, inside
a counted loop, so it vectorizes as dense's and indexmap's walks do
(0.08-0.21) and today's (0.47) does not. The cost of holes is a few
cycles a run, bounded by the compaction rule above: holes stay until the
next growth, so a Map that is only taken from walks its holes until
then.

### Growth

The index grows when the live count would pass the maximum load
(0.875 of `15 G`, lowered by anti-drift). The new index is sized so that
the live entries fill at most 0.6 of it, so a growth forced by drift
alone (§2) doubles rather than rehashing at the same size. It is
allocated zeroed (fresh pages, no stores) and filled by walking the
entries in order: the entry reads stream, the hash is the stored one or
the key hashed again (one multiply for an Int), and each target group's
tags and slots lines are prefetched 16 entries ahead once the new index
is larger than L2 (ankerl's pipelined rehash). Gone entries are skipped
and the rest renumbered, so the entries are compacted in the same pass.
The entries array grows by doubling (`realloc`, which moves large blocks
by remapping pages).

### The small path

Up to 8 entries, no index. A key of 8 bytes or fewer is compared
against all of them with no hash and no early exit (the 8 keys, loaded
de-interleaved, compared to a mask, the first match by
count-trailing-zeros); a longer key compares stored hashes first. At the
9th entry the index is built for the entries' capacity (16 entries: 2
groups, 160 bytes), so a 16-entry Map makes three allocations, not
today's six or more. Whether the small path should reach 16 is measured
(step 3), since the rnd16, str16 and big16 rows sit exactly at 16.

### String keys

Stored hash: yes. Growth and the small path then never read text, and a
false tag match (1 in 255) costs a hash compare on a line the lookup
already has. Compaction needs no hash at all. ankerl measured a stored
hash as worth little for its own growth; here it is also what keeps
growth from reading Strings, which are allocated apart.

### Where (a) stands, and the trade

| Rows | Expected | Why |
|---|---|---|
| iterate, every size | first | a counted loop over a dense array |
| insert 16, 24 | first | the small path; one index allocation |
| insert 1k to 150k; str and big inserts | first | dense entries, 5 bytes of index a slot to place, growth that streams |
| insert 3M, 4M | level with boost | memory-bound; huge pages decide it on pup |
| remove, str remove, big remove | first | the rows take keys in insertion order, so the entries are read in sequence; a take is one probe and three stores |
| miss, every size | level with the best flat map | the same 16 bytes a group a flat map reads, 8-bit tags, overflow filter |
| hit up to 1.5k | within 10-20% of Rust std + Fx | one dependent load (slots) more than a flat map, in L1 |
| hit, lat from 100k | 1.5-1.8 times the best flat map | the entry is a second wait on memory |
| churn 4M | level with boost-mix | takes in insertion order stream; compaction is two streaming passes |

**Can an ordered map win hits and misses at 4M?** Misses: yes, or tie,
because a miss never leaves the tags. Hits: no. Every layout that keeps
the entries dense and in order needs the entry's position before it can
load the entry, and that position is in memory; the layouts that put
entries in the slots (map-stage's Candidate 2) lose the walk 10.7 times
and the build 70-96%. The best an ordered map can do is overlap the two
index lines and make the entry the second and last wait: about dense's
12.5 at rnd4M hit, perhaps 10, against abseil's 6.28; about 140-150 at
lat4M against 86. The trade is that wait for iteration 10 times as fast
as a flat map's at 4M (dense 0.21 against boost 2.40), builds and
in-order removes that stream, insertion order kept across removes, and
about 26 bytes an entry at 4M (16 of entries, 8 of slots, 2 of tags) and
about 34 at peak, against today's 39.7 and hashbrown's 71.4. The rows the
ordered Map cannot win are the HashMap's to win.

## 2. (b) The unordered HashMap

boost's FOA, kept where it leads and changed where the data shows it
loses.

- **Layout.** One allocation: tags, 16 bytes a group (15 tags and an
  overflow byte), then the slots, 15 a group. Up to 32 bytes an element,
  key and value together in a slot (one line on a hit). Over 32 bytes,
  keys apart from values: a group's keys in one array, its values in
  another, so a hit compares a key on a dense key line and loads one
  value line whose address it knows from the lane, in parallel; a
  72-byte slot would straddle two lines and its key would share neither.
  Measure both on the big rows; this is the default.
- **Tags and position.** The hash's low byte, 0 mapped to 1: 255 tag
  values. Group `h >> shift`. No end sentinel: iteration counts groups.
- **Miss: the overflow byte, not tombstones.** An insert that passes a
  full group sets bit `tag & 7` of its overflow byte; a lookup stops at
  the first group whose bit is clear. A miss ends in its home group unless
  a key of its class overflowed that group (one class in eight). A
  SwissTable miss ends at a group with an empty byte, which at 7/8 load
  some home groups lack, and tombstones remove more.
- **Remove.** Write 0 to the tag; when the group's overflow bit for the
  class is set, lower the maximum load by one. One byte, no neighbour
  reads, no tombstone. A SwissTable erase loads two groups to choose
  between empty and tombstone, and its tombstones later force a rehash.
- **Load factor.** 0.875 of the slots. Group counts stay powers of two:
  a non-power-of-two count (a multiply-shift reduction) would smooth the
  sawtooth and save memory, but puts a multiply on every lookup's path.
- **Churn.** boost's anti-drift, with one change (§0, 3): a rehash
  forced by drift sizes the table so the live elements fill at most 0.6
  of it. Near full load that doubles once; at half load it rehashes at
  the same size, and then only after more erases than the table has
  slots. boost's rule rehashed churn100000 at the same size every ~46k
  erases. The exact alternative, ankerl's per-class counters, needs 8
  more bytes a group and makes every miss read them; not worth it.
- **Scan.** x86-64: `pcmpeqb`, `pmovmskb`, `& 0x7FFF`. arm64: `cmeq.16b`,
  `shrn #4`, `fmov`, a 60-bit mask, lane `ctz >> 2`: three instructions
  where boost's emulation has five or six. Two variants measured in step
  2, judged on L1 hits and lat16/lat1000: groups of 7 and an overflow
  byte in 8 bytes (`cmeq.8b`, `fmov`, hashbrown's cost), and SWAR on two
  64-bit words, which never crosses to the vector unit and so has the
  shortest latency.
- **Prefetch.** For elements of 16 bytes or fewer, prefetch the group's
  first slot line with the tags load (abseil's order) when the table is
  larger than L2; abseil leads rnd3M and rnd4M hits (4.26 and 6.28,
  against hashbrown's 4.66 and 7.18). For larger elements, no element
  prefetch: boost's half-group prefetch is the 3.3 times it loses on
  big1000000 hit.
- **Insert.** One pass: match the key; remember the first group with a
  free lane; if the key is absent, place it there and set the overflow
  bits of the full groups between home and there (usually none). Inline
  up to the home group; growth out of line.
- **Growth.** New zeroed arrays at twice the groups (or more under the
  0.6 rule); the old groups walked in order, each element placed with no
  compare; with high-bit positions, an element from group `g` lands in
  `2g` or `2g + 1`, so the new arrays fill nearly in order. A key over 8
  bytes keeps its hash in the slot (measured against hashing again:
  str insert at 1M is where flat maps lose to dense by 2.1 times, 39.73
  and 40.61 against 18.61, partly by reading every String again at each
  growth).
- **Small.** No allocation until the first insert; up to 8 entries the
  small path of (a), which is ordered anyway; then one group.
- **Iteration.** Group by group: the full-lane mask (tags not 0), a
  bit loop. It cannot match a dense walk: at 4M a flat table is half
  empty and walks twice the bytes, one branch an element. Its bar is the
  flat maps (boost 2.40, abseil 4.68, hashbrown 1.96 at 4M), not dense.

Where (b) stands: first on hits at every size, misses, mix, removes in
random order, churn, latency from 100k up, and str and big hits; level
with (a) on misses; behind (a) on iteration, on the in-order remove rows,
and on string and big builds. The design's open row is lat16/lat1000
(§4).

## 3. The hash function

**Integers.** `hashWord` is `fold((w ^ seed) * mul)`: a multiply and an
upper multiply in parallel, then an exclusive or, about one cycle more
latency than a bare multiply. It is not a bottleneck from 100k keys up.
In L1 it is about 15% of a hit (§0, 10), which is the margin by which
Rust std + Fx leads rnd16 and rnd24 hits. Both maps take the group from
the high bits, so for integer keys they can use a bare multiply by an
odd constant (Fibonacci hashing): the group from the top bits, the tag
from the byte just below them (`(h >> (shift - 8)) & 0xFF`, the shift
kept in the Map). Every input bit reaches the top bits. What it gives up:
keys that differ only in their top few bits share tags, and only that
costs anything (compares, not correctness). Rig's seed is fixed, so
neither form resists a chosen-key attack; that is not the trade. This
is the table's own hash of an integer key, as boost and ankerl take an
"avalanching" hash as it is; `.hash()` itself is unchanged.

**Strings.** Zig's Wyhash (`hashBytes`, seed 0, so its init folds away):
up to 16 bytes, four 4-byte reads and two multiplies in series; 17 to 48
bytes, three in series. foldhash 0.2: up to 16 bytes one folded multiply
and one more in `finish` (Rust's `str` hash writes a terminator byte);
17 to 31 bytes, two in parallel and one in `finish` (`lib.rs:239-345`,
`fast.rs:52-122`), with its long path out of line. abseil on arm64:
two CRC32 chains and one mix up to 32 bytes (study §1.1). For this bench's
7-27 byte keys Wyhash is one multiply longer from 17 bytes on, and equal
below. It is not the bottleneck in any row: str16 hit is led by Zig's
own table on the same Wyhash (2.87, against hashbrown's 3.10 and abseil's
3.54), and every string row Rig loses, it loses by 1.2 to 13.6 times, far
more than a multiply. After the tables are fixed it is worth one
multiply on keys of 17-32 bytes: a short path as foldhash's (two
overlapping loads and one folded multiply to 16 bytes; two in parallel
to 32), Wyhash above 32. Measure it on str16 and str1000, where the hash
is most of the operation.

## 4. The rows a winner must not lose

Leaders from the one-round Mac data. "Carries" is the family expected to
take the row; Rig's place in a row is its faster map's.

| Rows | Leader today | Carries | Bar |
|---|---|---|---|
| rnd insert 16, 24 | boost-mix 8.30 (Rig 7.55 at 16) | a | under 7.5 and 8.3 |
| rnd insert 1k-150k | dense 6.67-8.60 | a | under dense |
| rnd insert 3M, 4M | boost 8.51, 13.78 | a or b | under boost |
| rnd remove, every size | boost(-mix) 3.14-9.59 | a and b | under boost |
| rnd hit to 1.5k | Rust std + Fx 0.75-0.97 | b | under Rust std + Fx |
| rnd hit 100k-4M | hashbrown 1.68, Rust std 1.24, absl 4.26 and 6.28 | b | under each |
| rnd miss | hashbrown-mix 0.78 to dense 1.48 to hashbrown-mix 2.37 | b, a level | under each |
| rnd iterate | indexmap 0.08-0.32, dense 0.14-0.21 | a | under both |
| lat16, lat1000 | Zig 4.31, 4.57 | open | under Zig |
| lat100k, lat4M | absl 10.91, boost-mix 86.3 | b | under each |
| churn | boost-mix 6.01, 2.92, 8.38; hashbrown-mix 7.43 at 100k | b (a at 4M) | under each |
| mix | hashbrown 0.72, Rust-mix 0.96, boost 5.21, absl 8.40 | b | under each |
| str insert | boost 11.27; dense 13.84-18.61 | a | under each |
| str remove | Zig 8.37, 11.97; boost 14.30; dense 22.79 | a | under each |
| str hit | Zig 2.87, 3.39; hashbrown 7.62; absl-mix 24.85 | b | under each |
| str miss | hashbrown 1.33-4.56; dense-mix 5.12 at 100k | b or a | under each |
| big insert | Rig 9.52 at 16; dense 9.86-16.41 | a | under each |
| big remove | Zig 6.16; boost 5.88; dense 6.91, 7.74 | a | under each |
| big hit | hashbrown-mix and Rust-mix 0.92-6.42 | b | under each |
| big iterate | indexmap 0.16; dense 0.09-0.80 | a | under each |
| memory, 4M | Rig 39.7 bytes an entry | a | at most 34 |

**The one design risk in each family:**

- **(a), the ordered Map: the hit path at 100k to 4M against its own
  class.** If the split index's second line costs a hit more than the
  merged block's (ankerl), the Map loses mid-size hits and lat100k to
  dense and indexmap, the rivals it must lead. The superblock variant
  and the slots prefetch are the answer; step 1 measures them first.
- **(b), the HashMap: latency of the group scan on arm64.** It decides
  L1 hits against Rust std + Fx, mix16, and lat16/lat1000 against Zig's
  scalar probe, which today beats every SIMD group by 35-50% in a
  dependent chain (§0, 5). A "home lane first" check (the hash picks a
  preferred lane, an insert takes it when free, a lookup tests that one
  byte before the group) buys back the speculation, but in a throughput
  loop it mispredicts for every key not in its lane (a quarter to two
  fifths of keys at 0.5-0.875 load), about 3 cycles a lookup on average,
  which would lose the L1 hit rows. So it is measured, not assumed: if
  neither the home-lane check nor the SWAR scan takes lat16/lat1000
  without costing any hit row more than 2%, those two rows go to Zig and
  the record says so.

## 5. The order to build, each step with its bar

Every contestant is one Zig file and one binary (`bench/hash/map-ord.zig`,
`map-foa.zig`, as `map.zig` is), with Rig's `hashWord` and `hashBytes`
copied in and Rig's allocator. Timing waits for quiet machines: fastest
of 5, interleaved, the Mac under `tools/low`, pup on core 8 with 9 idle.

0. **Harness.** Both files print every row of WORKLOADS.md. Bar: every
   checksum equal to `map.rs`'s on both machines.
1. **(a) Int to Int: entries, gone bits, split index, find, insert,
   take, growth, small path.** Bar: ahead of dense and indexmap on every
   rnd, lat, mix and churn row; first overall on rnd iterate at every
   size and on rnd insert from 1k to 150k; remove under boost at every
   size; miss within 5% of the best flat map at every size. Measure the
   superblock variant and the slots prefetch here, on hits and lat.
   Record the hit and lat4M ratios to the best flat map; expected 1.5-1.8.
2. **(b) Int to Int: FOA, nibble scan, overflow bits, 0.6 drift rule,
   inline insert, small path.** Bar: first, or within 2%, against boost,
   abseil, hashbrown, Rust std + Fx and their `-mix` forms on every rnd
   hit, miss and remove row, every mix and churn row, lat100k and lat4M,
   on both machines; no such row more than 5% behind. Measure the 8-lane
   group, the SWAR scan, and the prefetch policy here.
3. **The L1 rows: home lane first, the bare-multiply Int hash, small
   path up to 16.** Each as a variant of steps 1 and 2. Bar: adopt one
   only if it takes the rows it is for (lat16 and lat1000 under Zig; L1
   hits under Rust std + Fx) and no other row is more than 2% slower.
4. **Strings.** Stored hash in (a)'s entry and (b)'s slot (and (b)
   without it), the short text hash against Wyhash. First, profile
   today's str100000 miss (§0, 8). Bar: each str row first for the
   family §4 gives it.
5. **Big values.** (b)'s keys apart from values over 32 bytes, against
   one slot; no element prefetch. Bar: big hit first for (b); big insert,
   remove and iterate first for (a).
6. **Memory and pages.** Zeroed fresh pages for new indexes, and on pup
   `madvise(MADV_HUGEPAGE)` for blocks of 2 MiB or more. Bar: (a) at most
   34 bytes an entry at 4M, (b) under hashbrown's 71.4; no time row
   slower; the 3M and 4M rows on pup recorded with and without.
7. **The podium.** Five rounds on both machines, every contestant. Bar:
   Rig's faster map first on every row of §4, or the row named in the
   record with its gap and reason (lat16 and lat1000 are the candidates).

Only then is Rig taught to emit them. What that needs beyond the study's
§4.3 (a per-target lane mask, `prefetch`, a branch hint, proven indexes,
zeroed pages): a safe form for entries whose liveness is kept apart (the
gone bits), so a taken entry's fields are not read or dropped twice; and
a `for` over a Map lowered to the run loop of §1, with the body once
inside a counted loop, so it vectorizes as the Zig does.

## 6. Owner decisions, with defaults

1. **Scoring.** Rig's place in a row is its faster map's, and each
   family must also lead its own class (the ordered Map ahead of dense
   and indexmap everywhere; the HashMap ahead of every flat map on the
   rows §4 gives it). Default: yes.
2. **The ordered Map's hits from 100k up** trail the best flat map by
   about 1.5-1.8 times, a limit of any dense ordered layout; the HashMap
   carries those rows. Default: accept.
3. **The tables' own integer hash:** a bare multiply, group from the
   top bits, tag from the byte below; `.hash()` unchanged. Default: build
   it as a variant (step 3), adopt only if more than 2% faster on L1 rows
   with nothing slower.
4. **The text hash:** a foldhash-style path up to 32 bytes, Wyhash above.
   It changes the values `.hash()` gives for text. Default: yes if step 4
   measures it faster.
5. **A take drops the key at once** (the gone bit), not at the next
   compaction as today. Default: yes.
6. **`U32` entry indexes:** a Map holds at most 2^32 - 1 entries, and
   traps past that. Default: yes.
7. **Compaction** only when the entries array is full and a quarter gone,
   when the index grows, and when a take empties the Map; until then a
   walk skips holes. No new member. Default: yes.
8. **lat16 and lat1000,** if neither the home-lane check nor the SWAR
   scan takes them without costing a hit row: concede them to Zig's
   scalar probe, recorded. Default: yes.
