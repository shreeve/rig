# Small maps: one block and no index up to 48 entries (2026-10-28)

The owner approved the work on 2026-10-28: make the built-in `Map` and
`Set` hold a small table compactly, so Trig's many small Maps take fewer
cache lines, fewer blocks and less memory. Branch `small-maps`, against
main 373b6aed3.

## What Trig's small Maps are

From a Map trace (`RIG_MAP_TRACE=1`) of Trig main 403a823, ts-pattern at
one checker, and a heap profile by site (`RIG_HEAP_PROFILE=sites`):

- **They are symbol tables**, `Map[Atom, Sym]`, a `Map(u32, u32)` in Zig:
  the binder's tables and the checker's `tabs`, each a `List` of Maps.
  There are 118,931 of them, against 17,858 `Map[U32, Int]`, 68,612
  short-lived `Map[InferenceKey, I32]` and 2,327 `Set[U32]`.
- **Their largest lengths:** 1,733 stay empty; 30,345 reach 1 entry and
  38,538 reach 2 (58% of all); 11,602 reach 3 or 4; 8,000 reach 5 to 15;
  about 1,000 reach 16 to 31; 26,533 reach 32 to 47 (the peaks are 32,
  with 6,462, and 41, with 10,367, the members of instantiated generic
  types); 369 go past 63.
- **They are filled once and read:** 2,486,301 lookups (45% hit) and
  1,301,031 puts, 99.8% of new keys; 14 takes and 205 clears.
- **Where the lookups land:** 23% in tables of at most 2 entries, 26.5%
  in tables of 32 to 47 entries, and 14% in tables past 63.
- **What each held on main**, for `Map(u32, u32)` (an entry is 8 bytes):
  - the Map itself, 112 bytes in its List (the table is 96 bytes, 32 of
    them its small tags, on a 16-byte line), two cache lines;
  - up to 16 entries, one block of entries, room for 4, 8 or 16;
  - from the 17th entry, an index of 4 groups (320 bytes) and entries
    room for 32, then 64: a table of 41 entries held 112 + 512 + 320 =
    944 bytes, in two blocks and the List.
- **The heap profile at ts-pattern's peak** (125.5 MiB live): Map(u32,
  u32) objects 16.1 MiB (the checker's `tabs` List alone 14 MiB),
  their entries 15.4 MiB in 116,478 blocks, and index blocks (`u64`)
  17.4 MiB in 27,547 blocks averaging 663 bytes. The sites confirm the
  `u64` blocks are Map indexes (`newIndex` under `reserveOne`): a few
  large ones of the relation and instantiation caches, and about 26,500
  of 320 bytes, the symbol tables of 32 to 47 entries.

## The design

- **The table is 56 bytes, a Map 64, one cache line.** The 32 tag bytes
  left the object; the gone bits' word count became a flag (they are
  `goneWords(cap)` words while they exist). `sema.minBytesOf` says 56.
- **A small table is one block:** its tags, a byte an entry in whole
  groups of 16 (0 when gone or not written), then its entries. A lookup
  matches the first group and each group `len` reaches, each by code of
  its own (unrolled), and compares a key only where a tag matches.
- **No index up to 48 entries written.** The room starts at 4 and
  doubles to 48 (4, 8, 16, 32, 48); a full small table compacts when a
  quarter of it is gone, grows while its room is under 48, and else
  builds its index. 48 is three groups: every symbol table of up to 47
  entries, 99.7% of them, stays small.
- **The index, when built, is sized for the live entries**
  (`groupsFor(live + 1)`, 8 groups at the 49th entry), and the entries
  move to a block of their own of the next power of two above twice the
  room (128), so a table that keeps growing has main's sizes.
- **A take from a small table of more than one group writes every
  group** `len` reaches, the entry's group changed, out of line
  (`unlinkWide`); one of one group writes its group, inline, as main
  did. See "Apple cores" below; out of line, because inline it made
  bench/hash's takes from large tables (64-byte values) 15-28% slower on
  pup, by the code it added to every take.
- **`clear` keeps a small table's block; an indexed table frees its
  index and entries and keeps room for 48.** Keeping the index, as
  taking the last entry does, made Trig's pooled mapper caches (2.44
  million clears on ts-pattern) clear an index each time: 1.7% of
  ts-pattern's instructions went to `memset`, and Trig took 1.5% more
  instructions than main. Main freed the index and kept the entries,
  which a small table in one block cannot hold.
- **A clone of a small table copies its tags**, hashing no key.

What a `Map[Atom, Sym]` holds:

| largest length | main | small-maps |
|---|---:|---:|
| 0 | 112 | 64 |
| 1-4 | 112 + 32 | 64 + 48 |
| 5-8 | 112 + 64 | 64 + 80 |
| 9-16 | 112 + 128 | 64 + 144 |
| 17-32 | 112 + 256 + 320 | 64 + 288 |
| 33-47 | 112 + 512 + 320 | 64 + 432 |

The Map sits in its List; the rest are blocks, which the allocator
rounds up to its size classes (144 to 160, 288 to 320, 432 to 448).

`HashMap` and `HashSet` are unchanged: their table is 48 bytes already,
Trig holds none, and a small form for them (their least table is two
groups of 15 slots) is a design of its own.

## What was tried and dropped

- **64 lanes:** tables of 33 to 47 entries grew to 64 entries' room,
  640 bytes against 448.
- **Room rounded up to the allocator's size class**, so a block filled
  its class: it saved 128 bytes on tables of 33 or 34 entries (3,480 in
  Trig), but rooms then crossed group bounds (16 Int pairs grew to 37
  entries, three groups) for nothing else. Plain doubling.
- **A small table's gone bits in the object** (a take writes no tag;
  its bit is a word in the object): takes 25-55% faster than main, but
  every hit then reads its bit, and hits in tables of 16 to 24 were 10%
  slower in a Zig micro-benchmark on the Mac.
- **One test for a miss in a table of 48:** the three groups' compares
  or'd and tested once. On the Mac it was slower than a test a group.
- **A bit a lane** (`@bitCast` of the compare to `u16`, the groups in
  one word, one loop over the candidates): slower on the Mac than a
  narrowing a group.
- **A first room of 2:** it would save 16 bytes on each of the 69,000
  tables of 1 or 2 entries (1.1 MB), but every table of 3 or more takes
  one more growth, which bench/hash's 16-key insert rows would pay.
- **No index past 16 entries, as main, in this layout:** the Trig
  replay below took 41% longer than with 48 on the Mac and 17% longer on
  pup, and 36% more memory: a table of 17 to 47 entries builds an index
  at 17 (sized for its live entries, it is rebuilt at 27 and 53).

## Apple cores: a take's tag store

With a take writing only its entry's tag group, in-order takes from a
table of 18 to 48 entries took twice as long as main's on the Mac (rnd24
remove 8.1 ns against 4.1), and not on pup. The jump is between 17 and
18 entries: from the second take in the second group. That store's
address depends on the search's result, and the next lookup's load of
the group does not, so it runs ahead of the store. Writing every group
`len` reaches, at addresses known before the search ends, brings the
takes back to main's (rnd24 remove 4.0 against 3.9 in a Zig
micro-benchmark). A probe of loads and stores alone, with the store's
address known early, shows no cost from the neighbouring group, so it is
the late address.

## Measurements

### The Zig, replayed (step 1)

The table is the runtime's own Zig, called by the prelude's `Map` and
`Set` as before, so the prototype is src/ordered.zig itself, measured
against main's copy of it. A replay of every operation the trace
records on Trig's `U32`-keyed Maps and Sets (4,817,641 on ts-pattern,
990,151 on zod3), the tables' objects in one array a type as Trig's
Lists hold them, ReleaseFast, fastest of 7; peak bytes from Rig's
allocator:

| | main | small-maps | |
|---|---:|---:|---|
| ts-pattern, peak bytes | 39,911,728 | 25,878,576 | 35% less |
| zod3, peak bytes | 9,969,904 | 7,347,280 | 26% less |
| ts-pattern, allocations | 313,205 | 282,820 | 10% fewer |
| ts-pattern, Mac | 16.9 ms | 15.0 ms | 11% faster |
| ts-pattern, pup core 8 | 25.0 ms | 22.7 ms | 9% faster |
| zod3, pup core 8 | 5.16 ms | 4.82 ms | 7% faster |

### Trig (step 2)

pup, release builds (slot 10-11), 20 interleaved rounds on core 8 with
sibling 9 idle, one checker; Trig main 403a823, Rig main 373b6aed3.
Output identical every round. Medians:

| | ts-pattern main | ts-pattern new | new / main | zod3 main | zod3 new | new / main |
|---|---:|---:|---:|---:|---:|---:|
| peak RSS, KB | 266,580 | 252,588 | 0.9475 | 85,956 | 82,160 | 0.9558 |
| user cycles | 3,984,008,397 | 3,979,919,159 | 0.9990 | 752,444,758 | 750,825,502 | 0.9978 |
| kernel cycles | 341,791,408 | 331,477,857 | 0.9698 | 95,692,230 | 92,826,329 | 0.9701 |
| instructions | 9,270,520,297 | 9,242,489,650 | 0.9970 | 1,684,107,844 | 1,674,424,796 | 0.9943 |
| L3 load misses | 518,740 | 489,210 | 0.9431 | 146,000 | 137,825 | 0.9440 |
| page faults | 40,160 | 39,624 | 0.9867 | 9,765 | 9,591 | 0.9822 |
| seconds | 0.94 | 0.93 | 0.99 | 0.19 | 0.19 | 1.00 |

Peak memory is 5.2% lower on ts-pattern (14.0 MB) and 4.4% on zod3
(3.8 MB); kernel cycles 3% fewer, from fewer pages touched; L3 load
misses 6% fewer; user cycles and instructions within noise. With
`clear` keeping the index (the build before), ts-pattern took 1.5% more
instructions and user cycles, its peak memory the same.

### bench/hash

Interleaved, fastest of 9, `rig-fast`; Mac under `tools/low`, pup on
core 8. Neither machine was quiet: on pup other release builds ran
throughout (load 2.4 to 5.4), and on both, main's large-table rows
moved by 5-20% between runs while the table's code for them did not
change.

- **Small tables, pup:** the 16-key inserts 6% faster, removes 3-5%
  faster, hits and misses within 4%; rnd24 inserts 31% faster and hits
  27% faster (no index), misses 5% slower; churn16 16% slower, str16
  5-8% slower, big16 removes 18% slower.
- **Small tables, Mac:** rnd24 inserts 46% faster and hits 7% faster;
  the 16-key misses 64-66% slower, churn16 32% slower, removes 5-17%
  slower. The miss rows look one Map up in a loop; main kept its tags
  in the Map, a local, and the compiler held them in registers for the
  whole loop (`ldp q0, q1, [sp, ...]` before it), which a table whose
  tags are in its block cannot get. Behind a pointer, as a Map in a List
  is, the 16-key misses are level (Zig micro-benchmark: 0.57-0.59 ns
  against main's 0.54-0.59).
- **In-order lookups across many tables of 24 to 48 entries** (a Zig
  micro-benchmark, a million keys) are 25-70% slower on the Mac than
  main's indexed tables, and on pup level or faster (misses at 40
  entries: 18.1 cycles against 19.2, with more branch misses from three
  groups of tags). The Trig replay above, whose tables of 32 to 47
  entries take a quarter of its symbol-table lookups, is faster on both.
- **The guard** (instructions): every row within 2% but small-hit, 7.3%
  fewer; the baseline is updated for it.

### std.json's guard

0.1-0.8% fewer instructions per byte on all six files.

## Data

[small-maps-data/](small-maps-data/): the trace's size tables
(`sizes.py`, `sizes-*.txt`), the heap profile by site at main's peak
(`heap-sites-ts-pattern.txt`), the replay (`compact.py` makes its input
from a trace, `replay.zig` runs it beside src/ordered.zig and a copy of
main's), the micro-benchmark (`micro.zig`), the Trig scripts
(`trig-build.sh`, `trig-time.sh`, `trig-report.py`) and rounds
(`trig-pup.txt`; `trig-pup-clear-keeps-index.txt` for the build whose
`clear` kept the index), and bench/hash's runs (`bench-hash.sh`,
`bench-hash-mac.txt`, `bench-hash-pup.txt`).
