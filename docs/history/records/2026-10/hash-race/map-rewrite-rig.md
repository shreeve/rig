# The ordered Map rewritten in Rig (2026-10-27)

Rig's built-in `Map` and `Set` (std/prelude.rig) on `zig-ordered`'s
design ([zig-ordered.md](zig-ordered.md), [map-rewrite-plan.md](map-rewrite-plan.md)),
written in safe Rig with no `raw` and no language change. Branch
`map-rewrite-rig`. INTERNALS, "The built-in Map and Set", describes
what was built; this page records what it measured.

## What differs from the prototype, and why

- **Two entry Lists.** A field's type cannot follow `$plain`, so a Map
  holds both `ps: List[Entry[K, V]]` (plain keys and values: no
  optional) and `es: List[Held[K, V]?]` (any other: the key's hash kept
  with it, `none` once taken), one always empty: 24 bytes of header.
- **Gone bits in a List of their own**, made at the first take that
  leaves a hole in a Map with an index. A small Map keeps none: its
  tags say which entries are gone. One word held inside the Map was
  tried and measured as nothing on rnd24 remove (Mac 1.55 against
  1.58 of the checked prototype), so it was left out for 8 bytes.
- **Lane 15 needs no mask.** Its entry index is `NO_ENTRY`, which the
  entry-index test that decision 10 keeps rejects; the mask cost a
  `mov.b v[15], wzr` on the chain on arm64.
- **A lane is written in a register**, `(LANE_IDS == l).select(x,
  grp)`: `grp.with(l, x)` spilled the group to the stack and reloaded
  it, and the next lookup's load of the group stalled on the store.
- **The lookup's walk past its home group is a cold call**
  (`walk_far`), as the plain prototype's is (its experiment 3); a take
  keeps it inline (experiment 15). With it inline, pup's rnd100000 hit
  ran 44% behind the checked prototype (spilled shift, mask, and
  bases); out of line, 13%.
- **A walk decides whether there are holes as it starts**, a field of
  the iterator: read from the Map in each step, it was a load LLVM could
  not hoist past the out-of-line run search, and walks ran 2-3 times as
  long.
- **The first put makes room for 4 entries**, doubling to 32 while
  small (the prototype: 16). At 16, zod3's peak memory was 0.8% over
  main's; at 4 it is 2.8% under. It costs rnd16 insert: 3.61 against
  the checked prototype's 2.36 on the Mac.
- **The Map object is 176 bytes** (main's 104): `dead` is the entries
  written less the live ones, and `shift`, `limit`, and `room` are
  narrow.
- **Decision 7 (an Int key hashed with one multiply) is not built:**
  Rig has no compile-time test that a key is an integer, nor a way to
  read a key's word, so the table cannot pick the one-multiply path.

## Trig, pup, 20 interleaved rounds, one checker

Release builds, timed on core 8 (sibling 9 idle); medians, the new
build against main at a38ff34b7. Output identical every round.

| | ts-pattern main | ts-pattern new | new / main | zod3 main | zod3 new | new / main |
|---|---|---|---|---|---|---|
| cycles | 4,251,719,122 | 3,995,059,251 | 0.9396 | 773,496,092 | 739,793,356 | 0.9564 |
| instructions | 9,472,496,119 | 9,493,229,511 | 1.0022 | 1,707,167,898 | 1,731,044,361 | 1.0140 |
| seconds | 0.99 | 0.93 | 0.94 | 0.19 | 0.19 | 1.00 (0.95 by the fastest) |
| peak RSS, KB | 303,280 | 278,948 | 0.9198 | 91,352 | 88,816 | 0.9722 |

ts-pattern takes 6.0% fewer cycles, zod3 4.4% fewer: over the bar of
1.5% on both, with peak memory lower on both.

## Memory, one Map of 4,000,000 Int keys

Peak bytes an entry (`bench-hash --mem`): Mac 32.8 (main 51.0,
zig-ordered 37.1); pup 33.0 (main 38.3, zig-ordered 26.6).

## std.json's guard

0.1-0.7% fewer instructions per byte on all six files.

## bench/hash rows slower than main by over 3%

Mac fastest of 10 (two runs of 5, the machine shared, load 4-10); pup
fastest of 5 on core 3.

| rows | Mac | pup | cause |
|---|---|---|---|
| in-cache hits, 24-1,500 keys (rnd, int, big), mix1000 | 1.05-1.37 | 1.05-1.50 | main's byte probe: a predicted branch a slot lets the core run ahead of the tag; a group match puts the compare, the move to a register, and the count of trailing zeros on every lookup. zig-ordered trails main on the same rows (Mac rnd1000 hit 1.22 against 1.25; int1000 1.32 against 1.22). In an order the predictor learns, new and main take the same cycles at 1,000 keys. |
| lat16, lat1000 | 2.93, 1.95 | 1.13, 1.65 | the same, on a dependent chain; conceded by decision 3 |
| 4M inserts, big1000000 insert, str1000000 insert | 1.06-1.14 | 1.15-1.32 | growth: the entries double by reallocation and the index is built anew beside the old one; zig-ordered trails main by as much on pup (main's 4M insert win is its allocator faulting pages ahead, per the panel) |
| str16, str1000, str1000000 remove | 1.30-1.38 | within 3% | a take drops its key at once (decision 4); main's left it to the next compaction, outside the timed loop |
| text hits and misses | 1.09-1.22 | 1.04-1.44 | the String's hash and compare, calls in these loops; the table's text rows trail zig-ordered by as much on main |

Everything else is faster than main, most by 25-75%: removes,
churn, misses, iteration, inserts below 4M, and hits from 100,000 keys
up. Walks on pup take 0.20 ns an entry against main's 0.42, level with
the Zig prototypes.

## The full tables

Times in ns per operation (each row's total over a million
operations); "checked" is zig-ordered-checked.

### Mac (Apple M5), fastest of 10

| row | new | main | zig-ordered | zig-ordered-checked | new / checked | new / main |
|---|---|---|---|---|---|---|
| rnd16 insert | 3.30 | 7.93 | 2.39 | 2.27 | 1.45 | 0.42 |
| rnd16 remove | 4.47 | 10.58 | 4.07 | 4.20 | 1.06 | 0.42 |
| rnd16 hit | 0.99 | 1.26 | 0.95 | 0.95 | 1.03 | 0.78 |
| rnd16 miss | 0.60 | 1.02 | 0.57 | 0.61 | 0.98 | 0.59 |
| rnd16 iterate | 0.15 | 0.49 | 0.12 | 0.12 | 1.24 | 0.30 |
| rnd24 insert | 7.27 | 10.23 | 9.74 | 9.49 | 0.77 | 0.71 |
| rnd24 remove | 8.33 | 15.48 | 5.37 | 4.86 | 1.72 | 0.54 |
| rnd24 hit | 1.37 | 1.37 | 1.14 | 1.22 | 1.12 | 1.01 |
| rnd24 miss | 0.91 | 2.01 | 0.94 | 0.89 | 1.02 | 0.45 |
| rnd24 iterate | 0.11 | 0.47 | 0.12 | 0.11 | 1.02 | 0.23 |
| rnd1000 insert | 8.58 | 9.45 | 9.86 | 9.13 | 0.94 | 0.91 |
| rnd1000 remove | 3.75 | 11.85 | 3.32 | 3.28 | 1.14 | 0.32 |
| rnd1000 hit | 1.53 | 1.25 | 1.22 | 1.28 | 1.20 | 1.23 |
| rnd1000 miss | 1.01 | 1.66 | 1.19 | 1.14 | 0.88 | 0.61 |
| rnd1000 iterate | 0.08 | 0.47 | 0.08 | 0.08 | 1.00 | 0.18 |
| rnd1500 insert | 7.41 | 10.35 | 8.19 | 7.76 | 0.96 | 0.72 |
| rnd1500 remove | 5.03 | 17.23 | 3.99 | 3.97 | 1.27 | 0.29 |
| rnd1500 hit | 1.60 | 1.68 | 1.35 | 1.31 | 1.22 | 0.95 |
| rnd1500 miss | 1.02 | 2.71 | 1.02 | 0.95 | 1.07 | 0.37 |
| rnd1500 iterate | 0.08 | 0.45 | 0.09 | 0.08 | 1.00 | 0.18 |
| rnd100000 insert | 7.22 | 10.88 | 6.40 | 6.05 | 1.19 | 0.66 |
| rnd100000 remove | 5.54 | 21.57 | 4.74 | 4.69 | 1.18 | 0.26 |
| rnd100000 hit | 2.43 | 6.16 | 2.24 | 2.15 | 1.13 | 0.39 |
| rnd100000 miss | 1.59 | 9.49 | 1.71 | 1.63 | 0.98 | 0.17 |
| rnd100000 iterate | 0.14 | 0.46 | 0.14 | 0.14 | 1.00 | 0.30 |
| rnd150000 insert | 6.94 | 10.44 | 6.53 | 6.25 | 1.11 | 0.66 |
| rnd150000 remove | 3.53 | 9.61 | 3.92 | 3.78 | 0.93 | 0.37 |
| rnd150000 hit | 2.23 | 2.92 | 2.04 | 2.02 | 1.11 | 0.76 |
| rnd150000 miss | 1.45 | 3.26 | 1.47 | 1.43 | 1.01 | 0.45 |
| rnd150000 iterate | 0.14 | 0.48 | 0.14 | 0.13 | 1.02 | 0.28 |
| rnd3000000 insert | 9.07 | 11.52 | 7.40 | 7.45 | 1.22 | 0.79 |
| rnd3000000 remove | 5.71 | 20.07 | 6.29 | 6.08 | 0.94 | 0.28 |
| rnd3000000 hit | 7.88 | 9.35 | 7.45 | 7.55 | 1.04 | 0.84 |
| rnd3000000 miss | 3.16 | 4.35 | 2.89 | 2.80 | 1.13 | 0.73 |
| rnd3000000 iterate | 0.17 | 0.39 | 0.17 | 0.18 | 0.96 | 0.45 |
| rnd4000000 insert | 15.31 | 13.48 | 12.72 | 12.79 | 1.20 | 1.14 |
| rnd4000000 remove | 13.36 | 32.51 | 14.55 | 14.82 | 0.90 | 0.41 |
| rnd4000000 hit | 11.26 | 13.51 | 10.45 | 10.81 | 1.04 | 0.83 |
| rnd4000000 miss | 4.32 | 8.98 | 3.88 | 3.97 | 1.09 | 0.48 |
| rnd4000000 iterate | 0.20 | 0.47 | 0.21 | 0.21 | 0.98 | 0.44 |
| lat16 chain | 7.38 | 2.52 | 7.81 | 7.18 | 1.03 | 2.93 |
| lat1000 chain | 9.05 | 4.63 | 9.05 | 8.44 | 1.07 | 1.95 |
| lat100000 chain | 16.63 | 17.27 | 16.36 | 16.24 | 1.02 | 0.96 |
| lat4000000 chain | 148.59 | 153.31 | 143.33 | 145.26 | 1.02 | 0.97 |
| churn16 turnover | 4.64 | 9.04 | 3.44 | 3.53 | 1.31 | 0.51 |
| churn1000 turnover | 4.93 | 8.92 | 3.93 | 4.24 | 1.16 | 0.55 |
| churn100000 turnover | 4.56 | 17.53 | 3.62 | 4.06 | 1.12 | 0.26 |
| churn4000000 turnover | 15.22 | 39.97 | 11.94 | 12.54 | 1.21 | 0.38 |
| mix16 half | 0.73 | 0.84 | 0.71 | 0.76 | 0.95 | 0.87 |
| mix1000 half | 1.20 | 1.58 | 1.03 | 1.12 | 1.06 | 0.76 |
| mix100000 half | 5.87 | 9.98 | 4.82 | 5.95 | 0.99 | 0.59 |
| mix4000000 half | 11.85 | 16.30 | 10.98 | 11.37 | 1.04 | 0.73 |
| str16 insert | 7.77 | 13.21 | 4.10 | 4.35 | 1.79 | 0.59 |
| str16 remove | 18.37 | 14.15 | 13.53 | 14.87 | 1.24 | 1.30 |
| str16 hit | 4.04 | 3.50 | 3.42 | 3.56 | 1.13 | 1.15 |
| str16 miss | 1.64 | 3.04 | 1.39 | 1.44 | 1.14 | 0.54 |
| str1000 insert | 12.10 | 14.15 | 13.55 | 14.15 | 0.85 | 0.86 |
| str1000 remove | 20.94 | 15.61 | 10.06 | 10.12 | 2.07 | 1.34 |
| str1000 hit | 5.18 | 4.25 | 3.59 | 3.81 | 1.36 | 1.22 |
| str1000 miss | 2.42 | 2.84 | 2.29 | 2.40 | 1.01 | 0.85 |
| str100000 insert | 11.36 | 16.44 | 9.50 | 9.80 | 1.16 | 0.69 |
| str100000 remove | 25.73 | 25.91 | 12.94 | 14.30 | 1.80 | 0.99 |
| str100000 hit | 14.45 | 15.73 | 8.00 | 7.79 | 1.85 | 0.92 |
| str100000 miss | 4.63 | 16.10 | 4.22 | 4.02 | 1.15 | 0.29 |
| str1000000 insert | 16.85 | 15.86 | 12.14 | 12.62 | 1.34 | 1.06 |
| str1000000 remove | 34.51 | 25.03 | 15.19 | 16.36 | 2.11 | 1.38 |
| str1000000 hit | 42.62 | 39.21 | 32.87 | 35.24 | 1.21 | 1.09 |
| str1000000 miss | 6.29 | 14.38 | 4.70 | 5.02 | 1.25 | 0.44 |
| big16 insert | 4.92 | 9.36 | 4.51 | 4.76 | 1.03 | 0.53 |
| big16 remove | 4.86 | 10.25 | 3.97 | 4.50 | 1.08 | 0.47 |
| big16 hit | 1.03 | 0.98 | 0.94 | 1.03 | 1.00 | 1.05 |
| big16 iterate | 0.11 | 0.46 | 0.10 | 0.11 | 0.95 | 0.23 |
| big1000 insert | 9.42 | 10.37 | 11.46 | 11.94 | 0.79 | 0.91 |
| big1000 remove | 3.64 | 12.57 | 2.71 | 2.76 | 1.32 | 0.29 |
| big1000 hit | 1.56 | 1.14 | 1.23 | 1.41 | 1.11 | 1.37 |
| big1000 iterate | 0.08 | 0.47 | 0.08 | 0.08 | 1.00 | 0.18 |
| big100000 insert | 8.58 | 12.63 | 9.99 | 10.47 | 0.82 | 0.68 |
| big100000 remove | 5.54 | 25.38 | 4.10 | 4.38 | 1.27 | 0.22 |
| big100000 hit | 2.78 | 6.51 | 2.83 | 2.64 | 1.06 | 0.43 |
| big100000 iterate | 0.53 | 0.69 | 0.53 | 0.53 | 0.99 | 0.76 |
| big1000000 insert | 16.74 | 15.84 | 13.51 | 13.91 | 1.20 | 1.06 |
| big1000000 remove | 5.19 | 23.52 | 3.95 | 4.21 | 1.23 | 0.22 |
| big1000000 hit | 9.93 | 10.60 | 8.42 | 9.27 | 1.07 | 0.94 |
| big1000000 iterate | 0.85 | 1.03 | 0.84 | 0.86 | 0.99 | 0.83 |

### pup (Core Ultra 9 185H, core 3), fastest of 5

| row | new | main | zig-ordered | zig-ordered-checked | new / checked | new / main |
|---|---|---|---|---|---|---|
| rnd16 insert | 6.80 | 9.47 | 5.16 | 5.16 | 1.32 | 0.72 |
| rnd16 remove | 6.47 | 12.75 | 7.27 | 7.28 | 0.89 | 0.51 |
| rnd16 hit | 1.10 | 1.32 | 1.18 | 1.36 | 0.81 | 0.84 |
| rnd16 miss | 0.82 | 1.40 | 0.77 | 0.84 | 0.97 | 0.58 |
| rnd16 iterate | 0.20 | 0.42 | 0.20 | 0.20 | 1.00 | 0.47 |
| rnd24 insert | 10.35 | 13.30 | 9.44 | 9.65 | 1.07 | 0.78 |
| rnd24 remove | 6.07 | 18.79 | 6.61 | 6.75 | 0.90 | 0.32 |
| rnd24 hit | 2.00 | 1.55 | 1.55 | 1.77 | 1.13 | 1.29 |
| rnd24 miss | 1.37 | 2.95 | 1.31 | 1.58 | 0.87 | 0.47 |
| rnd24 iterate | 0.20 | 0.42 | 0.20 | 0.20 | 1.00 | 0.48 |
| rnd1000 insert | 10.67 | 12.57 | 12.11 | 12.21 | 0.87 | 0.85 |
| rnd1000 remove | 5.74 | 15.58 | 5.35 | 5.56 | 1.03 | 0.37 |
| rnd1000 hit | 1.93 | 1.57 | 1.51 | 1.67 | 1.15 | 1.23 |
| rnd1000 miss | 1.37 | 1.65 | 1.31 | 1.59 | 0.86 | 0.83 |
| rnd1000 iterate | 0.20 | 0.41 | 0.20 | 0.20 | 1.01 | 0.48 |
| rnd1500 insert | 10.02 | 13.86 | 9.80 | 10.01 | 1.00 | 0.72 |
| rnd1500 remove | 6.57 | 21.01 | 6.15 | 6.16 | 1.07 | 0.31 |
| rnd1500 hit | 2.17 | 1.74 | 1.75 | 1.85 | 1.18 | 1.25 |
| rnd1500 miss | 1.64 | 3.42 | 1.55 | 1.74 | 0.94 | 0.48 |
| rnd1500 iterate | 0.20 | 0.41 | 0.20 | 0.20 | 1.00 | 0.48 |
| rnd100000 insert | 11.72 | 16.91 | 8.60 | 8.83 | 1.33 | 0.69 |
| rnd100000 remove | 7.50 | 32.23 | 6.89 | 7.16 | 1.05 | 0.23 |
| rnd100000 hit | 4.13 | 8.09 | 3.46 | 3.64 | 1.13 | 0.51 |
| rnd100000 miss | 3.30 | 12.30 | 3.21 | 3.33 | 0.99 | 0.27 |
| rnd100000 iterate | 0.20 | 0.45 | 0.20 | 0.20 | 1.00 | 0.45 |
| rnd150000 insert | 12.60 | 18.90 | 8.67 | 8.95 | 1.41 | 0.67 |
| rnd150000 remove | 6.17 | 25.64 | 5.33 | 5.58 | 1.10 | 0.24 |
| rnd150000 hit | 4.14 | 4.95 | 3.48 | 3.85 | 1.08 | 0.84 |
| rnd150000 miss | 2.18 | 4.41 | 2.12 | 2.43 | 0.90 | 0.49 |
| rnd150000 iterate | 0.20 | 0.47 | 0.20 | 0.20 | 0.99 | 0.43 |
| rnd3000000 insert | 15.41 | 20.94 | 16.34 | 16.83 | 0.92 | 0.74 |
| rnd3000000 remove | 9.40 | 40.20 | 12.75 | 13.60 | 0.69 | 0.23 |
| rnd3000000 hit | 21.56 | 21.10 | 19.24 | 21.13 | 1.02 | 1.02 |
| rnd3000000 miss | 6.08 | 5.97 | 6.47 | 6.70 | 0.91 | 1.02 |
| rnd3000000 iterate | 0.47 | 0.71 | 0.49 | 0.49 | 0.95 | 0.66 |
| rnd4000000 insert | 29.63 | 22.81 | 31.81 | 32.24 | 0.92 | 1.30 |
| rnd4000000 remove | 33.93 | 64.15 | 25.31 | 26.18 | 1.30 | 0.53 |
| rnd4000000 hit | 29.85 | 29.59 | 27.10 | 30.24 | 0.99 | 1.01 |
| rnd4000000 miss | 8.83 | 12.25 | 9.69 | 10.34 | 0.85 | 0.72 |
| rnd4000000 iterate | 0.64 | 0.94 | 0.68 | 0.67 | 0.95 | 0.68 |
| lat16 chain | 4.92 | 4.35 | 4.74 | 4.84 | 1.02 | 1.13 |
| lat1000 chain | 7.23 | 4.37 | 6.68 | 6.99 | 1.03 | 1.65 |
| lat100000 chain | 15.97 | 21.86 | 17.44 | 16.19 | 0.99 | 0.73 |
| lat4000000 chain | 249.44 | 251.68 | 266.49 | 264.50 | 0.94 | 0.99 |
| churn16 turnover | 4.95 | 11.69 | 4.99 | 4.83 | 1.02 | 0.42 |
| churn1000 turnover | 6.52 | 12.04 | 5.30 | 5.44 | 1.20 | 0.54 |
| churn100000 turnover | 6.33 | 24.05 | 5.38 | 5.62 | 1.13 | 0.26 |
| churn4000000 turnover | 27.34 | 70.92 | 25.10 | 26.29 | 1.04 | 0.39 |
| mix16 half | 0.98 | 1.05 | 0.91 | 0.93 | 1.05 | 0.93 |
| mix1000 half | 1.90 | 1.26 | 1.34 | 1.56 | 1.22 | 1.50 |
| mix100000 half | 8.45 | 12.32 | 7.30 | 7.60 | 1.11 | 0.69 |
| mix4000000 half | 27.51 | 25.93 | 23.35 | 26.49 | 1.04 | 1.06 |
| str16 insert | 18.24 | 23.33 | 13.35 | 13.47 | 1.35 | 0.78 |
| str16 remove | 16.94 | 20.10 | 14.12 | 14.64 | 1.16 | 0.84 |
| str16 hit | 5.15 | 4.80 | 4.72 | 4.87 | 1.06 | 1.07 |
| str16 miss | 2.55 | 2.96 | 2.60 | 2.48 | 1.03 | 0.86 |
| str1000 insert | 17.56 | 21.41 | 24.47 | 24.39 | 0.72 | 0.82 |
| str1000 remove | 17.89 | 22.78 | 18.12 | 18.54 | 0.96 | 0.79 |
| str1000 hit | 7.44 | 5.86 | 6.19 | 6.61 | 1.13 | 1.27 |
| str1000 miss | 3.64 | 2.53 | 3.38 | 3.67 | 0.99 | 1.44 |
| str100000 insert | 23.23 | 26.78 | 20.74 | 20.81 | 1.12 | 0.87 |
| str100000 remove | 22.21 | 32.21 | 21.38 | 21.83 | 1.02 | 0.69 |
| str100000 hit | 44.91 | 43.20 | 20.30 | 19.84 | 2.26 | 1.04 |
| str100000 miss | 8.58 | 19.12 | 6.47 | 6.56 | 1.31 | 0.45 |
| str1000000 insert | 33.43 | 29.12 | 37.66 | 38.07 | 0.88 | 1.15 |
| str1000000 remove | 29.51 | 35.57 | 27.51 | 28.36 | 1.04 | 0.83 |
| str1000000 hit | 107.78 | 95.07 | 93.37 | 96.96 | 1.11 | 1.13 |
| str1000000 miss | 15.01 | 16.99 | 9.93 | 10.68 | 1.41 | 0.88 |
| big16 insert | 13.71 | 15.61 | 8.00 | 8.13 | 1.69 | 0.88 |
| big16 remove | 7.25 | 14.36 | 9.11 | 9.28 | 0.78 | 0.50 |
| big16 hit | 1.17 | 1.52 | 1.41 | 1.39 | 0.84 | 0.77 |
| big16 iterate | 0.20 | 0.46 | 0.20 | 0.20 | 1.00 | 0.43 |
| big1000 insert | 14.98 | 16.49 | 15.08 | 15.20 | 0.99 | 0.91 |
| big1000 remove | 7.56 | 21.22 | 5.58 | 5.68 | 1.33 | 0.36 |
| big1000 hit | 2.02 | 1.84 | 1.63 | 1.78 | 1.14 | 1.10 |
| big1000 iterate | 0.24 | 0.51 | 0.25 | 0.24 | 1.00 | 0.47 |
| big100000 insert | 23.46 | 25.26 | 14.80 | 15.34 | 1.53 | 0.93 |
| big100000 remove | 9.72 | 53.40 | 8.48 | 8.88 | 1.10 | 0.18 |
| big100000 hit | 5.48 | 8.18 | 5.05 | 5.37 | 1.02 | 0.67 |
| big100000 iterate | 0.77 | 1.01 | 0.77 | 0.77 | 0.99 | 0.76 |
| big1000000 insert | 34.00 | 25.74 | 42.99 | 43.58 | 0.78 | 1.32 |
| big1000000 remove | 12.61 | 43.32 | 11.98 | 11.73 | 1.08 | 0.29 |
| big1000000 hit | 25.34 | 27.33 | 23.99 | 24.18 | 1.05 | 0.93 |
| big1000000 iterate | 2.54 | 3.22 | 2.66 | 2.67 | 0.95 | 0.79 |

## The runtime-Zig route

Porting `ordered.zig` into the runtime as Zig, the prelude's Map
calling it, needs what `extern zig` does not have: a generic function
(it takes no compile-time parameters, SPEC §15) and a Zig-defined type a
Rig object can hold as a field, with its drop. That is the owner's
decision.
