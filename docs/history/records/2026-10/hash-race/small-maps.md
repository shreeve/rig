# Small maps: a Map of one line (2026-10-28)

The owner approved the work on 2026-10-28: make the built-in `Map` and
`Set` hold a small table compactly, so Trig's many small Maps take fewer
cache lines, fewer blocks and less memory. Branch `small-maps`. The
first design (one block, no index up to 48 entries) cut Trig's memory
5%, but bench/hash rows were up to 70% slower on the Mac; the owner
turned it down, and the second design below keeps main's tables and
shrinks the Map. Its numbers are against main 773978d1d.

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

Main's table, its algorithms unchanged, in 56 bytes, so a `Map` is 64,
one cache line (112 before):

- **The small tags share their place with the index.** No table holds
  both: a small table (up to 16 live entries, 32 written) uses its 32
  tag bytes; an indexed one, in the same 32 bytes, its tags and slots
  pointers, its gone bits' pointer, its maximum load and its groups
  (`Held`, an `extern union`). `shift`, 0 in a small table, says which.
  The gone bits' word count became a flag (`has_gone`; they are
  `goneWords(cap)` words). `clear` frees the gone bits with the index,
  since the small tags take their place.
- **The fields are in a fixed order** (`extern struct`): `len` and
  `live`, written by every put and take, have an 8-byte word of their
  own, apart from `cap` and `shift`, which every lookup reads first.
  With `shift` beside `live`, bench/hash's int16 walk was 30-45% slower
  on the Mac.
- **An indexed table's room goes 32, 48, 64** (`nextRoom`), then
  doubles as before, so a table of 33 to 48 entries holds 48 entries'
  room, not 64; every room past 64 is main's.
- `sema.minBytesOf` says 56.

What a `Map[Atom, Sym]` holds (bytes; the rest are blocks the allocator
rounds up to its classes):

| largest length | main | small-maps | first design |
|---|---:|---:|---:|
| 0 | 112 | 64 | 64 |
| 1-4 | 112 + 32 | 64 + 32 | 64 + 48 |
| 9-16 | 112 + 128 | 64 + 128 | 64 + 144 |
| 17-32 | 112 + 256 + 320 | 64 + 256 + 320 | 64 + 288 |
| 33-47 | 112 + 512 + 320 | 64 + 384 + 320 | 64 + 432 |

The first design's saving on the 32-47-entry tables (no index) is gone:
26,500 tables of Trig's keep a 320-byte index. Kept inside one block
with the entries, as the coordinator asked to try, the index saves no
bytes: 320 + 384 = 704 bytes rounds up to a 768-byte class in one
block, where the two blocks are exactly 320 and 384. Its lookups would
be main's either way.

`HashMap` and `HashSet` are unchanged: their table is 48 bytes, and
Trig holds none.

## The first design, and why it went

One block (tags, then entries) and no index up to 48 entries: 35% less
memory in the replay below, 5% less peak memory in Trig, Trig's cycles
level. On the Mac it lost bench/hash rows:

- **Lookups across many tables of 24-48 entries**, 25-70% slower on the
  Mac (level or faster on pup): scanning up to three tag groups costs 9
  more instructions a miss than an index's one group, at a lower IPC, and
  two other forms of the scan (one test of the three groups or'd; a bit
  a lane) were slower still.
- **The 16-key miss rows**, 64-66% slower: main's tags were in the Map,
  a local, and the compiler kept them in registers for the whole loop.
- **In-order takes from tables of 18-48**: a take's tag store, its
  address known only when the search ends, made the next lookup's load
  of that group wait; writing every group fixed it, at a cost to churn16.

## Measurements

### The Zig, replayed

Every operation the trace records on Trig's `U32`-keyed Maps and Sets
(4,817,641 on ts-pattern, 990,151 on zod3), against main's
src/ordered.zig, ReleaseFast on the Mac; peak bytes from Rig's
allocator:

| | main | small-maps | first design |
|---|---:|---:|---:|
| ts-pattern, peak bytes | 39,911,728 | 31,172,784 (22% less) | 25,878,576 |
| zod3, peak bytes | 9,969,904 | 7,991,216 (20% less) | 7,347,280 |
| ts-pattern, time (fastest of 5) | 16.7-16.9 ms | 16.9 ms | 15.0 ms |

### Trig

pup, release builds (slots "10,11 10,11 10,11"), 20 interleaved rounds
on core 8 with sibling 9 idle, one checker; Trig 403a823 built by main
773978d1d and by 8eab1c8c7. Output identical every round. Main's kernel
cycles (0.25G on ts-pattern) match a quiet pup; `/proc/buddyinfo`
before and after is in `trig-pup-buddyinfo.txt`. Medians:

| | ts-pattern main | new | new / main | zod3 main | new | new / main |
|---|---:|---:|---:|---:|---:|---:|
| peak RSS, KB | 277,200 | 267,436 | 0.9648 | 92,630 | 88,592 | 0.9564 |
| user cycles | 3,804,540,378 | 3,771,114,030 | 0.9912 | 718,246,786 | 710,711,589 | 0.9895 |
| kernel cycles | 251,359,839 | 245,202,155 | 0.9755 | 91,986,853 | 89,013,354 | 0.9677 |
| instructions | 9,270,666,322 | 9,218,964,868 | 0.9944 | 1,683,499,754 | 1,673,926,802 | 0.9943 |
| L3 load misses | 245,502 | 215,231 | 0.8767 | 70,175 | 59,053 | 0.8415 |
| page faults | 15,461 | 14,926 | 0.9654 | 8,046 | 7,872 | 0.9783 |

Peak memory is 3.5% lower on ts-pattern (9.8 MB) and 4.4% on zod3
(4.0 MB), against the first design's 5.2% and 4.4%.

### bench/hash

Interleaved, fastest of 11, `rig-fast`, against main 773978d1d. The Mac
under `tools/low` with `.mac-quiet` absent (load 3-4 from other
sessions); pup on core 8 (load 2-3: another session's release builds
ran throughout), timed twice. Rows over 2% slower: the Mac 17 of 133,
pup 24 and 22 of 133.

**Placebo.** Main with 16 `nop`s added to a cold function (`tooMany`),
timed against main the same way on the Mac: 14 rows moved by more than
2%, up to 6% slower (int100000 miss) and 5% faster. Moving code alone
moves rows that far.

Every row more than 2% slower before (first design, on either machine),
new / main:

| row | Mac before | Mac now | pup before | pup now (two runs) |
|---|---:|---:|---:|---:|
| int16 insert | 1.05 | 1.00 | 0.94 | 1.04, 1.03 |
| int16 remove | 1.13 | 1.00 | 0.95 | 0.97, 0.96 |
| int16 hit | 1.01 | 1.00 | 1.04 | 1.08, 1.07 |
| int16 miss | 1.64 | 1.00 | 0.98 | 1.00, 1.00 |
| int16 iterate | 1.24 | 1.01 | 1.00 | 1.00, 0.99 |
| int1000 remove | 0.99 | 0.98 | 1.03 | 0.95, 0.93 |
| int4000000 insert | 1.01 | 1.00 | 1.21 | 1.00, 1.03 |
| int4000000 hit | 1.06 | 1.01 | 1.03 | 0.98, 0.99 |
| int4000000 miss | 1.04 | 0.96 | 1.10 | 0.97, 0.95 |
| rnd16 insert | 1.04 | 0.98 | 0.94 | 1.04, 1.02 |
| rnd16 remove | 1.05 | 1.09 | 0.97 | 0.98, 0.99 |
| rnd16 hit | 1.08 | 1.00 | 0.97 | 1.00, 1.01 |
| rnd16 miss | 1.66 | 1.00 | 1.02 | 0.99, 1.00 |
| rnd24 remove | 1.17 | 1.15 | 1.03 | 0.95, 0.95 |
| rnd24 miss | 0.97 | 1.01 | 1.05 | 1.04, 1.03 |
| rnd24 iterate | 1.17 | 1.16 | 1.00 | 1.00, 1.00 |
| rnd1000 hit | 1.13 | 0.99 | 1.02 | 0.99, 0.99 |
| rnd1000 miss | 1.19 | 1.03 | 1.06 | 1.01, 1.07 |
| rnd1500 hit | 1.09 | 1.05 | 1.02 | 1.05, 1.00 |
| rnd1500 miss | 1.08 | 1.00 | 1.01 | 1.01, 1.00 |
| rnd100000 hit | 0.98 | 0.96 | 1.04 | 1.01, 0.99 |
| rnd100000 miss | 1.06 | 0.83 | 1.05 | 1.02, 1.02 |
| rnd150000 insert | 1.01 | 1.01 | 1.09 | 1.02, 0.99 |
| rnd150000 remove | 1.02 | 1.04 | 1.03 | 0.99, 0.95 |
| rnd150000 hit | 1.06 | 1.01 | 0.99 | 1.01, 0.97 |
| rnd150000 miss | 1.08 | 1.00 | 1.07 | 1.05, 1.07 |
| rnd3000000 insert | 1.01 | 1.00 | 1.05 | 0.97, 1.02 |
| rnd3000000 remove | 1.04 | 1.05 | 0.96 | 0.83, 0.98 |
| rnd3000000 hit | 1.09 | 1.03 | 1.01 | 0.95, 0.97 |
| rnd3000000 miss | 1.09 | 1.03 | 1.10 | 0.95, 1.01 |
| rnd3000000 iterate | 0.95 | 1.02 | 1.05 | 0.99, 0.99 |
| rnd4000000 insert | 1.02 | 1.00 | 1.06 | 0.98, 0.99 |
| rnd4000000 hit | 1.14 | 1.03 | 1.00 | 0.94, 0.95 |
| rnd4000000 miss | 1.08 | 1.01 | 1.02 | 0.94, 0.98 |
| lat16 chain | 1.00 | 1.00 | 1.05 | 1.00, 1.00 |
| lat4000000 chain | 1.01 | 1.00 | 1.03 | 1.00, 1.00 |
| churn16 turnover | 1.32 | 1.02 | 1.16 | 1.00, 1.03 |
| mix16 half | 1.01 | 1.00 | 1.08 | 1.03, 1.00 |
| str16 insert | 1.03 | 1.00 | 1.06 | 1.56, 1.38 |
| str16 remove | 1.02 | 1.00 | 1.05 | 1.01, 1.00 |
| str16 hit | 1.03 | 0.98 | 1.08 | 1.09, 1.08 |
| str1000 insert | 1.00 | 0.99 | 1.03 | 1.04, 1.03 |
| str1000 miss | 0.89 | 1.01 | 1.03 | 1.00, 1.00 |
| str100000 insert | 1.02 | 1.01 | 1.04 | 1.07, 1.06 |
| str100000 remove | 1.01 | 0.99 | 1.05 | 1.03, 1.04 |
| str1000000 remove | 1.02 | 0.94 | 1.19 | 1.03, 0.92 |
| big16 remove | 1.05 | 1.07 | 1.18 | 1.00, 0.99 |
| big16 hit | 1.07 | 1.02 | 0.95 | 0.98, 1.01 |
| big16 iterate | 1.16 | 1.01 | 1.00 | 1.01, 1.00 |
| big1000 remove | 1.01 | 1.03 | 1.03 | 0.99, 0.99 |
| big1000 hit | 1.12 | 1.03 | 1.00 | 0.99, 0.99 |
| big100000 insert | 1.01 | 1.01 | 1.06 | 1.02, 0.98 |
| big100000 iterate | 1.01 | 1.00 | 1.04 | 0.99, 0.99 |
| big1000000 hit | 1.05 | 1.03 | 0.96 | 0.97, 0.98 |
| int insert | 0.99 | 0.99 | 1.03 | 1.05, 1.00 |
| int iterate | 1.03 | 1.00 | 1.06 | 1.02, 1.03 |
| string insert | 1.03 | 0.99 | 0.97 | 1.00, 0.89 |
| string iterate | 0.97 | 1.02 | 1.26 | 0.98, 1.00 |
| pair hit | 1.07 | 0.97 | 0.63 | 1.00, 0.96 |
| triple hit | 1.06 | 1.05 | 0.74 | 0.89, 0.86 |
| small 4 | 1.03 | 0.99 | 1.01 | 1.00, 1.00 |
| string intern | 1.06 | 1.00 | 1.04 | 1.00, 0.99 |
| int ensure_with-miss | 1.00 | 0.99 | 1.07 | 1.05, 1.01 |
| int edit_put-miss | 0.99 | 1.01 | 1.04 | 1.01, 0.97 |
| string ensure-miss | 1.02 | 0.98 | 1.06 | 1.04, 0.99 |
| string edit_put-miss | 0.99 | 0.99 | 1.03 | 0.94, 0.92 |

### The layout protocol

One binary pair is not a verdict: moving code moves rows. Each arm,
main and the branch, is built in four layouts from the same package
(`rig build`'s Zig compiled by `layout-build.sh` with `-Ofast
-fomit-frame-pointer`, as `rig build --release=fast` does): as is, and
with 5, 13 and 29 `nop`s in `placePast`, a cold function each Map type's
code lays among the program's, so the row functions after it move by 0,
16 and 32 bytes. (Nops in `tooMany`, the first try, moved none of the
row functions on pup.) All eight run interleaved, fastest of 5 each
(`layout-time.sh`). A row is slower only when the branch's fastest
layout is more than 2% over main's slowest, and faster the other way
round; each arm's median gives the ratio. The Mac under `tools/low`,
pup on core 8.

### bench/hash, each row in a function of its own

bench/hash now runs each row's timed loop in a function of its own, for
every contestant (#763). With the rows of a group in one function, the
Map's new size moved rows of the group by 5-40% on the Mac though their
loops had not changed. Under the layout protocol, at 8eab1c8c7, three
Mac runs and four pup runs (`bench-hash-mac-rows*.txt`,
`bench-hash-pup-rows*.txt`): no row is slower in two runs. Four rows
were flagged once each and not again (Mac big100000 hit 5%; pup
int100000 remove 4%, big1000000 remove 4%); int100000 remove's median
sits 1-4% over main's in all four pup runs. Faster: the Mac's
int4000000, rnd24 and rnd4000000 removes and int `ensure` hits (4-6%);
pup's str16 remove (4%).

A single run of the protocol over 133 rows flags about one row by
chance, so a row counts as slower only when two runs flag it.

Four layout changes came out of the rows:

- **The Map's table first.** With the table 8 bytes into the Map, a loop
  over a List of Maps kept a pointer to each Map and one to its table
  and spilled one: pup's int16 inserts 8-10% slower (a Zig
  micro-benchmark showed it too: puts into reserved tables level, the
  growths slower). The prelude's Map and Set put `t` first.
- **The small tags 16 bytes into the Map.** At 24, a 16-byte group of
  them straddled two cache lines wherever the Map sat 16 bytes into one,
  as churn16's did on pup (`map-address.sh` prints a Map's address mod
  64: 16 on the branch, 48 on main, whose tags the type aligned to 16):
  churn16 3-5% slower. At 16, in a Map 16-aligned, as a List's and the
  stack's are, no group straddles, and churn16 is level (0.98).
- **The index's pointers after its counts in their place.** With the
  tags and slots pointers first, a loop of `edit` hits kept them in
  registers it needed for its hash constants, which it built again each
  step: the Mac's int edit_put-hit 3-5% slower. Gone bits, maximum load
  and group count come first.
- **An indexed table's reset out of line** (below).

### The remove loop

The emitted Zig of bench/hash is the same on main and the branch but
for `rig/ordered.zig`: the difference is how LLVM fits the table's
inlined take into the program's loop. In `random`'s remove loop the
branch kept two more address registers, reloaded the key List's length
and pointer from the stack each step, and built a constant again each
step: 4 more instructions a take. The cause was `reset`, run when a take
empties the table, inlined into the loop: its memset and its gone-bit
sizing took the registers. Out of line (`emptied`, for an indexed table;
a small table's needs only its length cleared, inline), the removes are
level with main's or faster. Taking the cut-off of the last entries out
of line as well, as tried, put a call in the loop that cost the small
tables' takes their vector constant (rnd16 and big16 removes 6%
slower); it stays inline. Main's own loop does not gain from the
change. Two field orders were tried and dropped: the small tags first
in the table and the table first in the Map (so a Map's address finds
the tags) fixed rnd16 on the Mac but made pup's string removes 20-60%
slower.

### What is still slower

- **pup, int100000 remove:** flagged once in four runs, its median 1-4%
  over main's in each; not flagged twice.
- **rnd3000000 iterate (42% on the Mac before the per-row bench).** Not
  the table. Taken into a program of `random(3000000)` alone, or in its
  own function, the branch is level (0.20-0.22 ns against 0.22). In the
  whole program, walking the 3,000,000 entries four times in a row
  (`iterate-passes.rig`) shows the first pass 22% slower (0.262 ns
  against 0.215) and the next three equal (0.147-0.149): the row timed
  one pass, the first walk of entries the heap's history had placed
  differently. Under the per-row bench it is not slower.
- **pup str1000000 remove** swung 30-60% in single pairs; in a program of
  the string rows alone, with the field order kept, it is level.

### Guards

bench/hash's guard: every row within 2% of main's baseline (text-miss
1.5% more instructions, int-churn 4.8% fewer). std.json's guard:
0.1-0.8% fewer instructions per byte.

## Data

[small-maps-data/](small-maps-data/): the trace's size tables
(`sizes.py`, `sizes-*.txt`); the heap profile by site at main's peak
(`heap-sites-ts-pattern.txt`); the replay (`compact.py` makes its input
from a trace, `replay.zig` runs it); the micro-benchmark (`micro.zig`);
the Trig scripts (`trig-build.sh`, `trig-time.sh`, `trig-report.py`),
rounds (`trig-pup.txt`, with `trig-pup-buddyinfo.txt`) and the first
design's (`trig-pup-one-block.txt`, `trig-pup-take-inline.txt`,
`trig-pup-clear-keeps-index.txt`); bench/hash's runs (`bench-hash.sh`,
`bench-hash-rerun.sh`; `bench-hash-mac.txt`, `bench-hash-pup.txt`,
`bench-hash-pup-rerun.txt`, `bench-hash-mac-placebo.txt`, the layout
protocol's `layout-build.sh`, `layout-time.sh`,
`bench-hash-*-layouts.txt` (the old bench, `tooMany` layouts) and
`bench-hash-*-rows*.txt` (the per-row bench), `map-address.sh`,
`miss-alone.rig`,
`iterate-passes.rig`, and the first design's
`bench-hash-*-one-block.txt`).

## Gates

At 8eab1c8c7, on the per-row bench (#763): Rig's full suite and proofs
green on the Mac, the oracle quiet; bench/hash's guard within 2%
(text-miss 1.5% more instructions, int-churn 3.5% fewer); Trig's light
gate GREEN (37 s, built from the commit on pup with `zig build`, as
`tools/pup-rig` builds, since another session held `rig-next`); loco's
light gate GREEN.
