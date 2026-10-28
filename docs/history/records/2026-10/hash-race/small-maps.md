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
773978d1d and by this branch. Output identical every round. Main's
kernel cycles (0.25G on ts-pattern) match a quiet pup; `/proc/buddyinfo`
before and after is in `trig-pup-buddyinfo.txt` (order 9: 20 then 75;
order 10: 0). Medians:

| | ts-pattern main | new | new / main | zod3 main | new | new / main |
|---|---:|---:|---:|---:|---:|---:|
| peak RSS, KB | 277,200 | 267,448 | 0.9648 | 92,628 | 88,604 | 0.9566 |
| user cycles | 3,973,896,722 | 3,942,405,272 | 0.9921 | 735,716,096 | 733,130,980 | 0.9965 |
| kernel cycles | 253,269,154 | 238,207,219 | 0.9405 | 90,747,480 | 87,624,901 | 0.9656 |
| instructions | 9,271,080,160 | 9,228,501,740 | 0.9954 | 1,683,930,994 | 1,676,189,622 | 0.9954 |
| L3 load misses | 548,580 | 522,211 | 0.9519 | 133,028 | 123,888 | 0.9313 |
| page faults | 15,460 | 14,924 | 0.9653 | 8,046 | 7,872 | 0.9784 |

Peak memory is 3.5% lower on ts-pattern (9.8 MB) and 4.3% on zod3
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
main and the branch, is built in three layouts from the same package
(`rig build`'s Zig, compiled by `layout-build.sh` with
`-Ofast -fomit-frame-pointer` as `rig build --release=fast` does; the
branch's package differs from main's only in `rig/ordered.zig`): as is,
and with 8 and 24 `nop`s in a cold function (`tooMany`). All six run
interleaved, fastest of 5 each (`layout-time.sh`). A row is slower only
when the branch's fastest layout is more than 2% over main's slowest,
and faster the other way round; the median of each arm's three layouts
gives the ratio. The Mac under `tools/low`, pup on core 8.

### The remove loop

The emitted Zig of bench/hash is the same on main and the branch but
for `rig/ordered.zig`: the difference is in how LLVM fits the table's
inlined take into the program's loop. In `random`'s remove loop the
branch kept two more address registers, reloaded the key List's length
and pointer from the stack each step, and built a constant again each
step: 4 more instructions a take. The cause was `reset`, run when a take
empties the table, inlined into the loop: its memset and its gone-bit
sizing (`goneWords(cap)`, where main read a count) took the registers.
Out of line (`emptied`, and the cut-off of the last entries, `cutOff`),
the Mac's rnd16, rnd24 and big16 removes are level with main's or
faster (1.008, 1.022, 1.003 in one pair; no int, rnd or big remove row slower under the
layout protocol on either machine). Main's own loop does not gain from
the same change (main with `reset` out of line: within noise of main).

### What is still slower

Under the layout protocol (`bench-hash-*-layouts.txt`):

- **Mac:** int16 insert 6%, rnd1000 miss 11%, rnd150000 miss 4%,
  rnd3000000 hit 5% and iterate 42%, rnd4000000 hit 9%.
- **pup:** str16 hit 7%, string `ensure_with` miss 7%, int1000 hit 4%,
  str1000 remove 4%, str16 remove 3%. str16 insert, 38-56% slower in
  single pairs before, is level (0.999): it was the loaded machine.

These rows share functions with the rest of their group (`random`,
`sized`, `strings_sized`), and the table's code for them is unchanged.
Taken out alone (`miss-alone.rig`, the rnd1000 and rnd3000000 miss loops
each in a function of their own), the branch is level with main or
faster: rnd1000 miss 4.06-4.07 ms against 4.11-4.13, rnd3000000 11.1-11.7
against 11.4-11.7. What moves them is how LLVM allocates registers in
the whole function the row sits in, which a change of the table's size
moves. Getting every row within 2% would take either a bench whose rows
are each a function of their own, so a row measures its own loop, or
finding, row by row, which inlined path takes the registers, as `reset`
did for the removes.

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
protocol's `layout-build.sh`, `layout-time.sh` and
`bench-hash-*-layouts.txt`, `miss-alone.rig`, and the first design's
`bench-hash-*-one-block.txt`).

## Gates

At c79299b07: Rig's full suite (10,792 cases) green on the Mac, the
oracle quiet (proofs green at e680b48fb, before the take's rare paths
went out of line); bench/hash's guard within 2% (text-miss 1.5% more
instructions); Trig's light gate GREEN (49 s, built by
`zig build` from the commit on pup, as `tools/pup-rig` builds, since
another session held `rig-next`); loco's light gate GREEN.
