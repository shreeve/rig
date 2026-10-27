# Map and Set as compiler built-ins: what was measured (2026-10-27)

The design is [map-builtin-design.md](map-builtin-design.md): `Map` and
`Set` stay declared in std/prelude.rig and hold their entries in the
compiler built-ins `OrderedMap[K, V]` and `OrderedSet[K]`, which are
bench/hash's `zig-ordered` ported into the runtime (src/ordered.zig).
Branch `map-builtin`; "main" below is f7edd5cb5 (#735, the Map written
in Rig).

## What differs from the prototype, and why

- **Rig's hash and `==`** (`rig.hash`, `rig.eql`; Zig's `==` for an
  integer key). An Int key already hashes with one folded multiply
  (`hashWord`), which is decision 7.
- **The first put makes room for 4 entries**, doubling to 32 while
  small, as main does for Trig's peak memory (the prototype: 16). It
  costs the 16-key insert rows against the prototype.
- **A small table keeps no gone bits**; its tags say which entries are
  gone, as main's did. An indexed table makes its gone bits at the
  first take that leaves a hole, in a block of their own, so the
  entries' block is a whole number of entries and the index 80 bytes a
  group, sizes Rig's allocator holds exactly.
- **The index's slots come first in its block**, so on x86 a group's
  slots are one 64-byte line and the lookup's prefetch fetches all of
  them. With the tags first the slots straddled two lines.
- **A tag is written by writing its 16 tags whole from a register**
  (`writeLane`), as main writes a lane. A byte's store into the tags
  stalled the next lookup's 16-byte load of them: on the Mac rnd16
  remove took 4.6 ns against 3.65 in a micro-benchmark, and on pup,
  built without frame pointers as `rig build` builds, the rnd removes
  took 1.5 to 3 times main's (rnd4000000 remove 76.6 ns against 34.1).
- **A new index is made after the old is freed**: on the Mac a Map of
  4,000,000 Int keys peaked at 33.0 bytes an entry with both alive, and
  30.7 without.
- **Drops** run the last entry first, its value before its key, as a
  List and an object drop.
- **Decision 10, the entry index's bounds test, is left out of release
  builds.** The table is trusted runtime code, as a List is, and
  zig-ordered.md §12 measured the test at 2-7% of the lookup rows, past
  decision 10's 2%. Every read of an entry the index, a small table's
  tags, or the prelude names goes through `entryOf`, which in a debug
  build (`rig run`, and most of the suite) tests that the entry was
  written and, for the prelude's reads, is not gone, and panics if
  not; in a release build it is the read alone, so the release rows
  above are unchanged by it.
- **`reserve` tests the 2^32 - 1 entry limit first**, before it builds
  an index: `Map.new(5000000000)` panics with nothing allocated
  (`test/rig/std-hash.rig.test`, "hash reserve past the entry limit").

## Trig, pup, 20 interleaved rounds, one checker

Release builds on slot 10-11, timed on core 8 (sibling 9 idle); the
new build against main f7edd5cb5. Output identical every round.

| | ts-pattern main | ts-pattern new | new / main | zod3 main | zod3 new | new / main |
|---|---|---|---|---|---|---|
| cycles (median) | 4,016,117,286 | 3,898,552,300 | 0.9707 | 741,775,736 | 714,845,176 | 0.9637 |
| instructions (median) | 9,494,533,722 | 9,281,654,985 | 0.9776 | 1,731,466,216 | 1,678,254,866 | 0.9693 |
| seconds (median) | 0.93 | 0.91 | 0.98 | 0.19 | 0.18 | 0.95 |
| peak RSS, KB | 278,948 | 280,472 | 1.0055 | 88,816 | 88,096 | 0.9919 |

ts-pattern takes 2.9% fewer cycles and 2.2% fewer instructions, zod3
3.6% and 3.1%: over the bar (more than 2% faster, or 1% fewer
instructions). ts-pattern's peak memory is 0.55% higher (1.5 MB),
zod3's 0.8% lower.

## Memory, one Map of 4,000,000 Int keys

Peak bytes an entry (`bench-hash --mem`): Mac 30.7 (main 30.6,
zig-ordered 37.1); pup 29.9 (main 30.9, zig-ordered 26.7).

## std.json's guard

0.1-0.7% fewer instructions per byte on all six files.

## bench/hash

Times in ns an operation, fastest of 5, interleaved; "zo" is
zig-ordered. Mac: Apple M5 (tools/low). pup: Core Ultra 9 185H, core 3.

On the Mac 108 of 130 rows are faster than main; of the 104 rows
zig-ordered times, 73 are within 3% of it or faster. The rows over 3%
slower than main: big16 insert (1.15: 64-byte values copied through
the small table's growth), and text misses and the 1M-key text walk,
0.04-0.1 ns over main. On pup 109 of 114 rows are faster than main;
84 of 104 within 3% of zig-ordered or faster. Over 3% slower than main:
str1000000 remove (1.43; at the commit before the table's layout
changes it was 1.2, and the row is noisy on pup, 36-48 ns across
builds), rnd3000000 and rnd4000000 miss (1.12, 1.09; zig-ordered
trails main there by as much), the 1M-key Int walk (1.04), and text
`ensure_with` misses (1.08). The rows that trail zig-ordered are text
keys (a Rig String is a heap List of bytes, hashed and compared through
calls, and a take frees its key, decision 4), the 16-key inserts (the
first room of 4), and 64-byte values.

Main before #735's in-cache hits are passed: Mac rnd16 hit 0.86
(1.26 then), rnd1000 hit 1.07 (1.25); pup rnd1000 hit 1.48 (1.57).
The latency chains of 16 and 1,000 keys stay where #735 left them,
level with zig-ordered (decision 3).

### Mac

| row | new | main | zo | new / zo | new / main |
|---|---|---|---|---|---|
| int16 insert | 3.25 | 3.36 | 2.43 | 1.34 | 0.97 |
| int16 remove | 3.75 | 4.03 | 3.76 | 1.00 | 0.93 |
| int16 hit | 0.88 | 0.95 | 0.87 | 1.01 | 0.93 |
| int16 miss | 0.51 | 0.55 | 0.49 | 1.04 | 0.93 |
| int16 iterate | 0.09 | 0.10 | 0.13 | 0.69 | 0.90 |
| int1000 insert | 6.67 | 8.08 | 8.86 | 0.75 | 0.83 |
| int1000 remove | 2.40 | 3.22 | 3.06 | 0.78 | 0.75 |
| int1000 hit | 1.23 | 1.46 | 1.23 | 1.00 | 0.84 |
| int1000 miss | 1.04 | 1.00 | 1.04 | 1.00 | 1.04 |
| int1000 iterate | 0.08 | 0.08 | 0.08 | 1.00 | 1.00 |
| int100000 insert | 6.03 | 6.72 | 5.88 | 1.03 | 0.90 |
| int100000 remove | 4.21 | 5.11 | 4.17 | 1.01 | 0.82 |
| int100000 hit | 1.51 | 1.95 | 1.61 | 0.94 | 0.77 |
| int100000 miss | 1.44 | 1.57 | 1.39 | 1.04 | 0.92 |
| int100000 iterate | 0.13 | 0.13 | 0.13 | 1.00 | 1.00 |
| int4000000 insert | 14.00 | 15.63 | 13.66 | 1.02 | 0.90 |
| int4000000 remove | 11.25 | 12.17 | 13.46 | 0.84 | 0.92 |
| int4000000 hit | 5.30 | 5.50 | 6.16 | 0.86 | 0.96 |
| int4000000 miss | 3.46 | 3.66 | 3.68 | 0.94 | 0.95 |
| int4000000 iterate | 0.21 | 0.21 | 0.21 | 1.00 | 1.00 |
| rnd16 insert | 2.88 | 3.20 | 2.21 | 1.30 | 0.90 |
| rnd16 remove | 4.06 | 4.20 | 3.74 | 1.09 | 0.97 |
| rnd16 hit | 0.86 | 0.96 | 0.86 | 1.00 | 0.90 |
| rnd16 miss | 0.50 | 0.57 | 0.54 | 0.93 | 0.88 |
| rnd16 iterate | 0.09 | 0.12 | 0.12 | 0.75 | 0.75 |
| rnd24 insert | 6.52 | 6.78 | 8.87 | 0.74 | 0.96 |
| rnd24 remove | 3.92 | 7.73 | 5.03 | 0.78 | 0.51 |
| rnd24 hit | 1.06 | 1.34 | 1.05 | 1.01 | 0.79 |
| rnd24 miss | 0.82 | 0.90 | 0.88 | 0.93 | 0.91 |
| rnd24 iterate | 0.08 | 0.11 | 0.12 | 0.67 | 0.73 |
| rnd1000 insert | 6.56 | 8.12 | 8.95 | 0.73 | 0.81 |
| rnd1000 remove | 2.39 | 3.51 | 3.13 | 0.76 | 0.68 |
| rnd1000 hit | 1.07 | 1.42 | 1.16 | 0.92 | 0.75 |
| rnd1000 miss | 0.96 | 0.94 | 1.06 | 0.91 | 1.02 |
| rnd1000 iterate | 0.08 | 0.08 | 0.08 | 1.00 | 1.00 |
| rnd1500 insert | 5.89 | 6.99 | 7.50 | 0.79 | 0.84 |
| rnd1500 remove | 3.47 | 4.67 | 3.75 | 0.93 | 0.74 |
| rnd1500 hit | 1.24 | 1.54 | 1.28 | 0.97 | 0.81 |
| rnd1500 miss | 0.91 | 0.99 | 0.96 | 0.95 | 0.92 |
| rnd1500 iterate | 0.08 | 0.08 | 0.08 | 1.00 | 1.00 |
| rnd100000 insert | 5.89 | 6.75 | 5.92 | 0.99 | 0.87 |
| rnd100000 remove | 4.29 | 5.31 | 4.41 | 0.97 | 0.81 |
| rnd100000 hit | 2.15 | 2.32 | 2.05 | 1.05 | 0.93 |
| rnd100000 miss | 1.38 | 1.42 | 1.59 | 0.87 | 0.97 |
| rnd100000 iterate | 0.13 | 0.13 | 0.13 | 1.00 | 1.00 |
| rnd150000 insert | 5.91 | 6.77 | 6.07 | 0.97 | 0.87 |
| rnd150000 remove | 2.89 | 3.49 | 3.76 | 0.77 | 0.83 |
| rnd150000 hit | 1.82 | 2.05 | 1.91 | 0.95 | 0.89 |
| rnd150000 miss | 1.31 | 1.35 | 1.36 | 0.96 | 0.97 |
| rnd150000 iterate | 0.13 | 0.13 | 0.13 | 1.00 | 1.00 |
| rnd3000000 insert | 8.17 | 8.70 | 7.48 | 1.09 | 0.94 |
| rnd3000000 remove | 5.08 | 6.05 | 6.18 | 0.82 | 0.84 |
| rnd3000000 hit | 7.58 | 8.13 | 7.90 | 0.96 | 0.93 |
| rnd3000000 miss | 2.79 | 3.12 | 2.85 | 0.98 | 0.89 |
| rnd3000000 iterate | 0.15 | 0.24 | 0.18 | 0.83 | 0.62 |
| rnd4000000 insert | 13.90 | 15.38 | 13.17 | 1.06 | 0.90 |
| rnd4000000 remove | 12.29 | 13.10 | 14.92 | 0.82 | 0.94 |
| rnd4000000 hit | 10.65 | 11.47 | 11.01 | 0.97 | 0.93 |
| rnd4000000 miss | 3.90 | 4.31 | 3.99 | 0.98 | 0.90 |
| rnd4000000 iterate | 0.21 | 0.20 | 0.20 | 1.05 | 1.05 |
| lat16 chain | 7.20 | 7.14 | 7.21 | 1.00 | 1.01 |
| lat1000 chain | 8.42 | 8.83 | 8.42 | 1.00 | 0.95 |
| lat100000 chain | 15.39 | 15.93 | 15.82 | 0.97 | 0.97 |
| lat4000000 chain | 149.69 | 150.79 | 148.88 | 1.01 | 0.99 |
| churn16 turnover | 3.50 | 4.16 | 3.25 | 1.08 | 0.84 |
| churn1000 turnover | 3.84 | 4.64 | 3.89 | 0.99 | 0.83 |
| churn100000 turnover | 3.55 | 4.27 | 3.66 | 0.97 | 0.83 |
| churn4000000 turnover | 13.25 | 15.40 | 12.65 | 1.05 | 0.86 |
| mix16 half | 0.66 | 0.67 | 0.69 | 0.96 | 0.99 |
| mix1000 half | 1.00 | 1.19 | 1.00 | 1.00 | 0.84 |
| mix100000 half | 4.90 | 5.40 | 5.30 | 0.92 | 0.91 |
| mix4000000 half | 10.89 | 11.44 | 11.53 | 0.94 | 0.95 |
| str16 insert | 7.06 | 7.25 | 4.44 | 1.59 | 0.97 |
| str16 remove | 18.19 | 18.30 | 13.80 | 1.32 | 0.99 |
| str16 hit | 3.80 | 3.78 | 3.23 | 1.18 | 1.01 |
| str16 miss | 1.76 | 1.70 | 1.36 | 1.29 | 1.04 |
| str1000 insert | 9.40 | 11.42 | 13.01 | 0.72 | 0.82 |
| str1000 remove | 19.64 | 20.40 | 9.70 | 2.02 | 0.96 |
| str1000 hit | 4.60 | 4.90 | 3.42 | 1.35 | 0.94 |
| str1000 miss | 2.37 | 2.23 | 2.25 | 1.05 | 1.06 |
| str100000 insert | 9.63 | 12.00 | 9.26 | 1.04 | 0.80 |
| str100000 remove | 23.83 | 25.05 | 12.71 | 1.87 | 0.95 |
| str100000 hit | 13.74 | 13.78 | 7.86 | 1.75 | 1.00 |
| str100000 miss | 4.30 | 4.34 | 4.18 | 1.03 | 0.99 |
| str1000000 insert | 13.66 | 17.73 | 11.97 | 1.14 | 0.77 |
| str1000000 remove | 30.52 | 33.55 | 15.53 | 1.97 | 0.91 |
| str1000000 hit | 42.62 | 43.28 | 34.61 | 1.23 | 0.98 |
| str1000000 miss | 7.62 | 7.78 | 4.60 | 1.66 | 0.98 |
| big16 insert | 5.26 | 4.57 | 4.40 | 1.20 | 1.15 |
| big16 remove | 4.08 | 4.43 | 3.74 | 1.09 | 0.92 |
| big16 hit | 0.89 | 0.96 | 0.91 | 0.98 | 0.93 |
| big16 iterate | 0.10 | 0.11 | 0.10 | 1.00 | 0.91 |
| big1000 insert | 8.15 | 9.15 | 10.94 | 0.74 | 0.89 |
| big1000 remove | 2.58 | 3.49 | 2.60 | 0.99 | 0.74 |
| big1000 hit | 1.11 | 1.45 | 1.21 | 0.92 | 0.77 |
| big1000 iterate | 0.08 | 0.08 | 0.08 | 1.00 | 1.00 |
| big100000 insert | 8.95 | 9.34 | 9.81 | 0.91 | 0.96 |
| big100000 remove | 4.66 | 5.61 | 4.05 | 1.15 | 0.83 |
| big100000 hit | 2.69 | 2.76 | 2.79 | 0.96 | 0.97 |
| big100000 iterate | 0.50 | 0.50 | 0.50 | 1.00 | 1.00 |
| big1000000 insert | 17.49 | 17.83 | 14.54 | 1.20 | 0.98 |
| big1000000 remove | 5.33 | 5.80 | 4.74 | 1.12 | 0.92 |
| big1000000 hit | 10.17 | 10.41 | 9.56 | 1.06 | 0.98 |
| big1000000 iterate | 0.83 | 0.84 | 0.83 | 1.00 | 0.99 |
| int insert | 8.39 | 9.87 | - | - | 0.85 |
| int hit | 1.84 | 2.17 | - | - | 0.85 |
| int miss | 1.76 | 1.94 | - | - | 0.91 |
| int iterate | 0.19 | 0.19 | - | - | 1.00 |
| string insert | 18.12 | 20.24 | - | - | 0.90 |
| string hit | 8.25 | 8.55 | - | - | 0.96 |
| string miss | 5.53 | 5.32 | - | - | 1.04 |
| string iterate | 0.62 | 0.55 | - | - | 1.13 |
| pair insert | 8.67 | 10.26 | - | - | 0.85 |
| pair hit | 2.31 | 2.62 | - | - | 0.88 |
| pair miss | 1.75 | 1.91 | - | - | 0.92 |
| small 4 | 1.25 | 1.29 | - | - | 0.97 |
| small 8 | 1.29 | 1.32 | - | - | 0.98 |
| string intern | 6.91 | 7.33 | - | - | 0.94 |
| int ensure-miss | 9.06 | 11.00 | - | - | 0.82 |
| int ensure-hit | 2.25 | 2.96 | - | - | 0.76 |
| int ensure_with-miss | 9.31 | 11.16 | - | - | 0.83 |
| int ensure_with-hit | 2.20 | 2.89 | - | - | 0.76 |
| int edit_put-miss | 8.77 | 10.14 | - | - | 0.86 |
| int edit_put-hit | 2.18 | 2.49 | - | - | 0.88 |
| string ensure-miss | 16.90 | 21.10 | - | - | 0.80 |
| string ensure-hit | 10.40 | 9.92 | - | - | 1.05 |
| string ensure_with-miss | 18.35 | 20.32 | - | - | 0.90 |
| string ensure_with-hit | 9.63 | 11.13 | - | - | 0.87 |
| string edit_put-miss | 18.02 | 19.14 | - | - | 0.94 |
| string edit_put-hit | 9.99 | 10.98 | - | - | 0.91 |

### pup

| row | new | main | zo | new / zo | new / main |
|---|---|---|---|---|---|
| int16 insert | 5.85 | 7.29 | 6.06 | 0.97 | 0.80 |
| int16 remove | 5.03 | 6.45 | 7.09 | 0.71 | 0.78 |
| int16 hit | 1.22 | 1.51 | 1.24 | 0.98 | 0.80 |
| int16 miss | 0.85 | 0.94 | 0.86 | 1.00 | 0.91 |
| int16 iterate | 0.20 | 0.20 | 0.20 | 0.98 | 0.99 |
| int1000 insert | 10.08 | 11.37 | 12.25 | 0.82 | 0.89 |
| int1000 remove | 4.74 | 5.58 | 5.09 | 0.93 | 0.85 |
| int1000 hit | 1.55 | 1.90 | 1.59 | 0.97 | 0.82 |
| int1000 miss | 1.48 | 1.66 | 1.53 | 0.97 | 0.89 |
| int1000 iterate | 0.20 | 0.20 | 0.20 | 0.98 | 0.99 |
| int100000 insert | 10.68 | 11.42 | 8.45 | 1.26 | 0.94 |
| int100000 remove | 6.40 | 7.11 | 6.58 | 0.97 | 0.90 |
| int100000 hit | 2.58 | 3.11 | 2.76 | 0.94 | 0.83 |
| int100000 miss | 3.24 | 3.42 | 3.18 | 1.02 | 0.95 |
| int100000 iterate | 0.20 | 0.20 | 0.20 | 0.99 | 1.00 |
| int4000000 insert | 26.38 | 31.90 | 31.33 | 0.84 | 0.83 |
| int4000000 remove | 23.51 | 32.94 | 24.76 | 0.95 | 0.71 |
| int4000000 hit | 14.37 | 17.14 | 15.77 | 0.91 | 0.84 |
| int4000000 miss | 8.16 | 8.92 | 9.67 | 0.84 | 0.91 |
| int4000000 iterate | 0.64 | 0.64 | 0.69 | 0.93 | 1.00 |
| rnd16 insert | 5.53 | 6.82 | 5.18 | 1.07 | 0.81 |
| rnd16 remove | 5.04 | 6.81 | 7.23 | 0.70 | 0.74 |
| rnd16 hit | 1.05 | 1.11 | 1.19 | 0.89 | 0.95 |
| rnd16 miss | 0.72 | 0.78 | 0.77 | 0.93 | 0.92 |
| rnd16 iterate | 0.20 | 0.20 | 0.20 | 0.99 | 1.00 |
| rnd24 insert | 9.09 | 10.47 | 9.37 | 0.97 | 0.87 |
| rnd24 remove | 4.57 | 6.14 | 6.63 | 0.69 | 0.74 |
| rnd24 hit | 1.52 | 2.00 | 1.54 | 0.98 | 0.76 |
| rnd24 miss | 1.25 | 1.37 | 1.31 | 0.95 | 0.91 |
| rnd24 iterate | 0.20 | 0.20 | 0.20 | 0.99 | 0.99 |
| rnd1000 insert | 9.59 | 10.89 | 12.01 | 0.80 | 0.88 |
| rnd1000 remove | 5.07 | 5.81 | 5.41 | 0.94 | 0.87 |
| rnd1000 hit | 1.48 | 1.93 | 1.51 | 0.98 | 0.77 |
| rnd1000 miss | 1.26 | 1.43 | 1.31 | 0.96 | 0.88 |
| rnd1000 iterate | 0.20 | 0.20 | 0.20 | 0.98 | 1.01 |
| rnd1500 insert | 8.98 | 10.08 | 10.25 | 0.88 | 0.89 |
| rnd1500 remove | 5.57 | 6.51 | 6.14 | 0.91 | 0.86 |
| rnd1500 hit | 1.68 | 2.17 | 1.75 | 0.96 | 0.78 |
| rnd1500 miss | 1.49 | 1.63 | 1.55 | 0.96 | 0.91 |
| rnd1500 iterate | 0.20 | 0.20 | 0.20 | 0.99 | 0.99 |
| rnd100000 insert | 10.70 | 11.64 | 8.66 | 1.24 | 0.92 |
| rnd100000 remove | 6.65 | 7.45 | 6.94 | 0.96 | 0.89 |
| rnd100000 hit | 3.38 | 4.11 | 3.46 | 0.98 | 0.82 |
| rnd100000 miss | 3.07 | 3.33 | 3.21 | 0.96 | 0.92 |
| rnd100000 iterate | 0.20 | 0.20 | 0.20 | 1.01 | 1.01 |
| rnd150000 insert | 11.47 | 12.65 | 8.80 | 1.30 | 0.91 |
| rnd150000 remove | 5.43 | 6.16 | 5.31 | 1.02 | 0.88 |
| rnd150000 hit | 3.34 | 4.03 | 3.48 | 0.96 | 0.83 |
| rnd150000 miss | 2.00 | 2.10 | 2.12 | 0.94 | 0.95 |
| rnd150000 iterate | 0.20 | 0.20 | 0.20 | 0.99 | 1.00 |
| rnd3000000 insert | 13.66 | 15.37 | 16.40 | 0.83 | 0.89 |
| rnd3000000 remove | 7.91 | 9.45 | 12.79 | 0.62 | 0.84 |
| rnd3000000 hit | 17.65 | 21.61 | 19.31 | 0.91 | 0.82 |
| rnd3000000 miss | 6.72 | 6.02 | 6.45 | 1.04 | 1.12 |
| rnd3000000 iterate | 0.47 | 0.47 | 0.49 | 0.95 | 1.01 |
| rnd4000000 insert | 25.31 | 30.26 | 31.71 | 0.80 | 0.84 |
| rnd4000000 remove | 24.48 | 34.00 | 25.45 | 0.96 | 0.72 |
| rnd4000000 hit | 25.00 | 30.48 | 26.87 | 0.93 | 0.82 |
| rnd4000000 miss | 10.03 | 9.16 | 9.68 | 1.04 | 1.09 |
| rnd4000000 iterate | 0.63 | 0.63 | 0.67 | 0.93 | 1.00 |
| lat16 chain | 4.78 | 4.92 | 4.74 | 1.01 | 0.97 |
| lat1000 chain | 6.73 | 7.23 | 6.69 | 1.01 | 0.93 |
| lat100000 chain | 16.71 | 16.33 | 17.24 | 0.97 | 1.02 |
| lat4000000 chain | 249.16 | 245.53 | 264.12 | 0.94 | 1.01 |
| churn16 turnover | 4.03 | 4.96 | 4.99 | 0.81 | 0.81 |
| churn1000 turnover | 5.23 | 6.52 | 5.31 | 0.98 | 0.80 |
| churn100000 turnover | 5.21 | 6.57 | 5.53 | 0.94 | 0.79 |
| churn4000000 turnover | 24.78 | 27.20 | 25.38 | 0.98 | 0.91 |
| mix16 half | 0.97 | 0.95 | 0.92 | 1.06 | 1.02 |
| mix1000 half | 1.33 | 1.83 | 1.33 | 1.00 | 0.73 |
| mix100000 half | 7.28 | 8.40 | 7.35 | 0.99 | 0.87 |
| mix4000000 half | 23.68 | 27.73 | 23.19 | 1.02 | 0.85 |
| str16 insert | 18.10 | 18.23 | 13.36 | 1.35 | 0.99 |
| str16 remove | 16.53 | 16.95 | 14.13 | 1.17 | 0.97 |
| str16 hit | 4.65 | 5.20 | 4.73 | 0.98 | 0.89 |
| str16 miss | 2.47 | 2.57 | 2.67 | 0.92 | 0.96 |
| str1000 insert | 16.94 | 17.60 | 24.47 | 0.69 | 0.96 |
| str1000 remove | 17.96 | 17.93 | 18.17 | 0.99 | 1.00 |
| str1000 hit | 6.31 | 7.47 | 6.19 | 1.02 | 0.84 |
| str1000 miss | 3.23 | 3.65 | 3.36 | 0.96 | 0.89 |
| str100000 insert | 22.39 | 23.19 | 20.94 | 1.07 | 0.97 |
| str100000 remove | 21.78 | 22.21 | 21.38 | 1.02 | 0.98 |
| str100000 hit | 41.31 | 44.33 | 19.50 | 2.12 | 0.93 |
| str100000 miss | 8.35 | 8.62 | 6.47 | 1.29 | 0.97 |
| str1000000 insert | 31.95 | 32.96 | 37.52 | 0.85 | 0.97 |
| str1000000 remove | 42.70 | 29.88 | 26.92 | 1.59 | 1.43 |
| str1000000 hit | 99.43 | 108.75 | 94.96 | 1.05 | 0.91 |
| str1000000 miss | 14.28 | 15.12 | 11.17 | 1.28 | 0.94 |
| big16 insert | 12.24 | 13.79 | 8.04 | 1.52 | 0.89 |
| big16 remove | 5.87 | 7.27 | 9.00 | 0.65 | 0.81 |
| big16 hit | 1.08 | 1.26 | 1.41 | 0.76 | 0.85 |
| big16 iterate | 0.20 | 0.20 | 0.20 | 1.00 | 1.00 |
| big1000 insert | 13.09 | 15.05 | 15.08 | 0.87 | 0.87 |
| big1000 remove | 7.18 | 7.57 | 5.54 | 1.30 | 0.95 |
| big1000 hit | 1.60 | 2.03 | 1.63 | 0.98 | 0.79 |
| big1000 iterate | 0.24 | 0.24 | 0.25 | 0.98 | 0.99 |
| big100000 insert | 22.13 | 23.49 | 14.85 | 1.49 | 0.94 |
| big100000 remove | 9.16 | 9.89 | 8.46 | 1.08 | 0.93 |
| big100000 hit | 4.90 | 5.60 | 5.26 | 0.93 | 0.87 |
| big100000 iterate | 0.77 | 0.77 | 0.77 | 1.00 | 1.00 |
| big1000000 insert | 30.97 | 34.21 | 43.33 | 0.71 | 0.91 |
| big1000000 remove | 12.37 | 12.70 | 11.75 | 1.05 | 0.97 |
| big1000000 hit | 20.88 | 25.72 | 22.81 | 0.92 | 0.81 |
| big1000000 iterate | 2.61 | 2.58 | 2.65 | 0.98 | 1.01 |
| int insert | 16.24 | 19.15 | - | - | 0.85 |
| int hit | 5.20 | 5.59 | - | - | 0.93 |
| int miss | 3.78 | 3.96 | - | - | 0.95 |
| int iterate | 0.76 | 0.73 | - | - | 1.04 |
| string insert | 29.76 | 31.81 | - | - | 0.94 |
| string hit | 15.49 | 16.58 | - | - | 0.93 |
| string miss | 9.52 | 9.86 | - | - | 0.97 |
| string iterate | 1.66 | 1.98 | - | - | 0.84 |
| pair insert | 21.17 | 21.61 | - | - | 0.98 |
| pair hit | 6.29 | 6.99 | - | - | 0.90 |
| pair miss | 3.89 | 3.97 | - | - | 0.98 |
| small 4 | 1.92 | 2.01 | - | - | 0.95 |
| small 8 | 1.92 | 2.01 | - | - | 0.95 |
| string intern | 10.17 | 10.06 | - | - | 1.01 |
| int ensure-miss | 14.94 | 18.49 | - | - | 0.81 |
| int ensure-hit | 4.85 | 6.39 | - | - | 0.76 |
| int ensure_with-miss | 16.04 | 19.05 | - | - | 0.84 |
| int ensure_with-hit | 4.73 | 5.89 | - | - | 0.80 |
| int edit_put-miss | 15.31 | 18.30 | - | - | 0.84 |
| int edit_put-hit | 4.79 | 6.04 | - | - | 0.79 |
| string ensure-miss | 27.61 | 31.06 | - | - | 0.89 |
| string ensure-hit | 26.98 | 28.02 | - | - | 0.96 |
| string ensure_with-miss | 33.95 | 31.43 | - | - | 1.08 |
| string ensure_with-hit | 31.72 | 32.27 | - | - | 0.98 |
| string edit_put-miss | 30.12 | 31.88 | - | - | 0.94 |
| string edit_put-hit | 27.14 | 27.87 | - | - | 0.97 |
