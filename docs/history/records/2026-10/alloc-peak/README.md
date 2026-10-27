# Kept large blocks and peak memory (2026-10-27)

#725 ([alloc-large/](../alloc-large/)) let a heap keep freed large
blocks up to `keepBound(h) = large_peak - large_live + keep_large`
(16 MiB), meaning never to raise peak memory. bench/hash's memory row
(one `Map[Int, Int]` of 4,000,000 keys, peak RSS of `rig-fast mem` less
`mem0`, `/usr/bin/time -l` on the Mac) went from 39.7 to 51.0 bytes an
entry at #725, 45 MB more. This record is the diagnosis, the fix (the
peak counted after a free), a first fix measured and not taken (fix A,
a fixed 16 MiB), and the numbers.

## Diagnosis

`large_peak` and `large_live` count address space, not touched pages.
A Map's table, or a List grown by copying, maps a new block twice the
size, mostly untouched (prefault touches at most 8 MiB, and only on
Linux), copies, and frees the old one. At that moment the new block
counts in full toward `large_peak`, so the bound lets the old block be
kept, and its pages stay resident. If no later mapping comes, nothing
trims it. The 4M-key row's last large-block events, traced on main:

```
MAP 98304 KiB  live=221184 peak=221184 kept=14928
FREE 49152 KiB live=172032 peak=221184 kept=14928 keep=true   <- old entries block kept, resident to the end
```

The bound is 221,184 - 172,032 + 16,384 = 65,536 KiB, so the 48 MiB
block joins the 14.6 MiB already kept. Its pages were touched (it held
the entries), and the 96 MiB block that replaces it is filled after,
so the process holds both: the 45 MB.

## The fix: the peak counted after a free

`large_peak` is raised in `freeLarge`, after the freed block leaves
`large_live`, and no longer in `lent`: the heap's settled peak, the most
it has had handed out just after a free. A growth's moment, the old
block and the new one handed out together, is left out, so the old
block is kept only within `keep_large`. A table built and dropped still
counts its whole size, since its last growth's free leaves it handed
out, so tables built and dropped again and again take their pages from
what the heap kept. The bound saturates, `(large_peak -| large_live) +
keep_large`, since new pages can take what is live past the settled
peak; then the heap keeps no more than `keep_large` (`trimKept`). Kept
plus live stays within the settled peak and `keep_large`, or, while new
pages have taken the heap past that peak, what is live and `keep_large`.
For the 4M-key row, at the 48 MiB free what stays handed out is the most
it has been, the bound is 16 MiB, and the block is given back.

It still counts address space: a block handed out and never touched
counts once a free follows it. And one table grown past 16 MiB, dropped
and grown again, takes new pages for its last block: the block before
it was given back at its growth, and the rebuild's request for that
size splits the kept last block. A probe on the Mac (one table grown
from 1 to 32 MiB, twice) took 63 MiB the first time and 32 MiB the
second.

## Tests

All three in `src/alloc.zig`, on a heap of their own, pass on the
branch at ReleaseSafe and Debug on the Mac:

- "a block grown as a List grows it, to past `keep_large`, keeps no
  more than `keep_large` of the blocks it grew from": a block of 1 MiB
  grown to 64 MiB, each step taking a block twice the size and freeing
  the old, the heap keeping no more than `keep_large` after each free;
  dropped, the last block is kept. It fails on main once the 16 MiB
  block is freed (the heap then keeps 31 MiB):

      6/9 main.test.a block grown as a List grows it, to past `keep_large`, ...FAIL (TestUnexpectedResult)

- #725's "a freed large block serves a smaller request and keeps the
  rest, and a table dropped and built again takes no new pages", with
  its 32 MiB of 512 KiB blocks built again: as on main, but for its last
  check, after a 64 MiB block takes new pages past the settled peak,
  which now reads that the heap keeps no more than its bound and
  `keep_large`.
- "tables grown past `keep_large` in all, dropped, and built again take
  no new pages": 48 tables grown from 128 KiB to 512 KiB, all held at
  once (24 MiB), dropped, and built again the same way. It passes on
  main and fails on fix A. The case asked for, one table grown past 16
  MiB, does not hold, as above, so the case is several tables, as
  bench/hash's big rows build them.

## Fix A, measured and not taken

A heap keeps at most 16 MiB of freed blocks in all, the bound before
#725, with #725's reuse by fit. It restores the memory (39.5 bytes an
entry) but loses #725's gains at every size: bench/hash's `bigs` builds
a round's maps all at once (1,000 maps of 1,000 keys, 10 of 100,000, or
one of a million), a million entries of 72 bytes in all, and drops them
together, far more than 16 MiB however small each table is. Its numbers
are below beside the fix's first measurement (peakfree, the same code as
the fix, measured from `peakfree.diff` on main before the comments and
tests), and in [hb-mac-1.txt](hb-mac-1.txt), [hb-mac-2.txt](hb-mac-2.txt),
[hb-pup-1.txt](hb-pup-1.txt), [trig-perf-1.md](trig-perf-1.md) and
[trig-wall-1.md](trig-wall-1.md).

## The Mac

`hbab.py` runs bench/hash's rig-fast program, built by each Rig,
interleaved and the order reversed every other round, the fastest of
each row; and each build's bytes an entry for the 4M-key map, the least
of the rounds. Under `tools/low`.

The final code against main `a38ff34b7` (the branch's base), 15 rounds
([hb-mac-3.txt](hb-mac-3.txt)):

| | main | the fix |
|---|---:|---:|
| bytes an entry, 4M Int keys | 51.0 | 39.5 |

| rows | n | the fix against main |
|---|---:|---:|
| Int: insert, remove, turnover | 26 | 1.000 |
| Int: lookups, iterate | 43 | 1.001 |
| Int: 3M and 4M rows | 18 | 1.007 |
| Text: insert, remove | 9 | 0.999 |
| Text: hit, miss | 18 | 1.010 |
| Big values: insert | 4 | 1.009 |
| Big values: other | 12 | 1.005 |
| All | 130 | 1.003 |

The big inserts, ns per insert: `big1000` 9.96 and 10.01, `big100000`
12.19 and 12.24, `big1000000` 15.19 and 15.67. The rows over 3% slower:
`string ensure_with-miss` and `edit_put-miss` 11% (also in run 2, 10 to
11%: each round grows one table of a million String keys past 16 MiB,
the case above), `rnd150000 miss` 16% (a lookup, which allocates
nothing; not in run 2), and four rows of 3 to 5%.

The first round (main `2b4191d0c`, alloc.zig the same as `a38ff34b7`'s),
15 rounds each. Bytes an entry: before #725 (`c2b9ac461`) 39.7, main
51.0, fix A 39.5, peakfree 39.5. Run 2, against main:

| rows | n | fix A | peakfree |
|---|---:|---:|---:|
| Int: insert, remove, turnover | 26 | 1.048 | 1.001 |
| Int: lookups, iterate | 43 | 1.004 | 0.998 |
| Int: 3M and 4M rows | 18 | 1.008 | 1.008 |
| Text: insert, remove | 9 | 1.043 | 0.999 |
| Text: hit, miss | 18 | 1.035 | 1.009 |
| Big values: insert | 4 | 1.266 | 1.010 |
| Big values: other | 12 | 1.023 | 0.998 |
| All | 130 | 1.029 | 1.002 |

| big inserts, ns | main | fix A | peakfree |
|---|---:|---:|---:|
| big16 | 8.79 | 8.87 | 8.85 |
| big1000 | 9.98 | 13.14 | 10.01 |
| big100000 | 12.16 | 19.04 | 12.20 |
| big1000000 | 14.94 | 18.43 | 15.36 |

Fix A: `big1000` 32% slower than main, `big100000` 57%, `big1000000`
23%, the million-key inserts 10 to 33% and the write rows on misses 15
to 27%. Run 1, against before #725: fix A is that speed (all rows 1.005,
big inserts 1.030), main 0.972 and 0.811.

## pup

Trig main `403a823` built release by each Rig (`build.sh`, release
slot 0,5), and bench/hash, timed on core 6 with 7 idle (cores 8, 9, 1,
2, 10 and 11 were another session's). `measure.py` as #725's record ran
it, but both checker counts on core 6, so the four-checker walls are one
core's: 20 rounds, interleaved, the order reversed every other round,
once under `perf stat` and once without (`run.sh`).

The final code against main `a38ff34b7`. Trig
([trig-perf-2.md](trig-perf-2.md) under `perf stat`,
[trig-wall-2.md](trig-wall-2.md) without):

| project | checkers | build | wall s (perf) | wall s | instructions (user) | page faults | RSS MB |
|---|---|---|---:|---:|---:|---:|---:|
| ts-pattern | 1 | main | 1.022 | 1.020 | 9,475.3M | 40,543 | 296.2 |
| ts-pattern | 1 | the fix | 1.021 | 1.033 | 9,478.0M | 40,543 | 296.2 |
| ts-pattern | 4 | main | 1.090 | 1.096 | 9,966.8M | 43,946 | 324.2 |
| ts-pattern | 4 | the fix | 1.088 | 1.102 | 9,964.6M | 43,947 | 324.2 |
| zod3 | 1 | main | 0.201 | 0.196 | 1,714.7M | 9,637 | 89.2 |
| zod3 | 1 | the fix | 0.205 | 0.198 | 1,718.7M | 9,635 | 89.2 |
| zod3 | 4 | main | 0.277 | 0.279 | 2,333.9M | 16,081 | 127.0 |
| zod3 | 4 | the fix | 0.274 | 0.278 | 2,334.0M | 16,080 | 127.0 |

(RSS is the median of 20; the largest is the same, zod3's at one
checker 89.4 MB for both.) Peak memory and page faults are the same,
instructions within 0.3%, and walls from 1.1% faster to 2.0% slower,
within the noise: with the same page faults to the fault, the bound
decides for Trig as main's does, and what Trig keeps never reaches it.

bench/hash, 9 rounds ([hb-pup-2.txt](hb-pup-2.txt)), against main:

| rows | n | the fix against main |
|---|---:|---:|
| Int: insert, remove, turnover | 26 | 1.029 |
| Int: lookups, iterate | 43 | 0.974 |
| Int: 3M and 4M rows | 18 | 0.993 |
| Text: insert, remove | 9 | 1.022 |
| Text: hit, miss | 18 | 1.019 |
| Big values: insert | 4 | 1.001 |
| Big values: other | 12 | 1.006 |
| All | 130 | 1.001 |

The big inserts, ns: `big16` 16.09 and 16.12, `big1000` 17.53 and
17.44, `big100000` 26.41 and 26.28, `big1000000` 27.08 and 27.44. The
groups move 2.6% faster to 2.9% slower, and the rows over 3% slower
include lookups and walks that allocate nothing (`rnd150000 iterate`
41%, `small 4` 18%, `int hit` 11%), so this run's spread is the
binary's layout and the machine, not the bound; in the first round the
same code was 0.7% faster over all rows.

The first round (main `2b4191d0c`, 20 rounds each,
[trig-perf-1.md](trig-perf-1.md), [trig-wall-1.md](trig-wall-1.md)):
fix A and peakfree had main's peak RSS and page faults in every case
(ts-pattern 296.2 and 324.2 MB at one and four checkers, zod3 89.2 to
89.4 and 127.0), instructions within 0.4% and walls within 1.1%.
bench/hash, 9 rounds ([hb-pup-1.txt](hb-pup-1.txt)), against main:
fix A 2.3% slower over all rows and its big inserts 23% (`big1000` 73%,
`big100000` 24%, `big1000000` 8.1%, its text inserts 10%); peakfree
0.7% faster over all rows, its big inserts the same.

The 4M-key map takes 38.3 bytes an entry on pup with every build,
before #725 too: the regression shows on the Mac. Why Linux does not
show it was not traced; there a block of 1 MiB or more grows by
`mremap`, which frees no old block, and a heap that leads faults its new
blocks in ahead.

## Gates

On the final code (`9489997b0`, the fix):

- The tests above; `tools/heavy swarm test/rig.rip all -q -w 6` on the
  Mac: 10,700 jobs, none died.
- `zig build test` on pup at `-Doptimize=debug`, `safe` and `fast`
  (cores 0,5): all pass.
- Trig's light gate, `PUP_RIG=<the branch's rig, built on pup>
  tools/light`, from a clone of Trig main `403a823` whose `tools/pup`
  runs its workers on cores 0, 3-5 and 12-21 and its release builds in
  slot 0,5: GREEN in 60 s. The branch's Rig was built in this record's
  directory, not `tools/pup-rig`'s shared `rig-next`, which another
  session's build held.
- loco's light gate (`rig/tools/light RIG=<branch bin/rig>`, loc
  `947ffa0`): GREEN in 29 s, 122 runs, none differ.
- std.json's guard on the Mac, instructions per byte against
  guard.txt: twitter 7.8741 (0.8% fewer), twitterescaped 9.3676 (0.6%
  fewer), canada 16.1442 (0.1% fewer), citm_catalog 8.0318 (0.5%
  fewer), gsoc-2018 3.4383 (0.7% fewer), github_events 7.0066 (0.7%
  fewer). A parse makes no block over 32 KiB on its hot path.

Fix A passed the same gates in the first round (suite 10,676 jobs, none
died; pup's tests; Trig's light gate GREEN in 62 s; loco's GREEN).

## For the owner

1. Take the peak counted after a free as the fix? (default: yes)

Fix A restores the memory too, but loses #725's gains at every size.
