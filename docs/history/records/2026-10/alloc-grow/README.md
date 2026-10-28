# Large blocks that grow: into a kept block, else by mremap from 64 KiB (2026-10-28)

bench/hash's prover saw Rig's release allocator (`src/alloc.zig`) behind
glibc's `malloc` on the insert rows of tables of 100,000 keys, under the
same Zig table (`zig-ordered:rig` against `zig-ordered`). The guess was
that glibc's `realloc` grows a chunk in place. A profile says otherwise,
and the change taken here is two lines of policy in `remap`.

## The profile

`mkprof.py` makes `map-prof.zig`, bench/hash's `map.zig` whose `main`
runs the rows named on its command line; `prefix.sh` names every row
`map.zig` runs before the big-value rows, so a measured row starts
from the heap the real program leaves; `on` starts `perf` there
(`stat.sh`, `prof.sh`, `perf --control`); `drv.sh` builds it on malloc
and on a tree's alloc.zig. pup, core 6, two repetitions of each row
(`stat-pup.txt`):

| row | malloc user / kernel cycles | main user / kernel | main faults |
|---|---:|---:|---:|
| int100000 (`sized:100000`) | 921M / 2.9M | 905M / 51.7M | 614 |
| rnd150000 | 883M / 2.6M | 930M / 143.2M | 7,493 |
| big100000 | 1,365M / 4.0M | 1,087M / 455.9M | 27,407 |

User work is the same or less; the gap is the kernel. `strace` of the
int100000 rows shows why: each table's entries grow from 1.25 MiB to
2.5 MiB by `mremap`, which takes fresh pages (each one zeroed by the
system and faulted in by `MADV_POPULATE_WRITE`), while the heap holds
the 2.5 MiB block the last table freed, resident, and then gives it
back (`munmap`, `trimKept`) because the new pages passed its bound.
164 `mremap`s, 164 `madvise`s, and 157 `munmap`s in 16 tables. glibc,
whose heap is warm by then, takes the same growth from memory it holds.

## Variants (each a patch in this directory)

- **kept** (`kept.patch`): `remap` copies a growing large block into a
  kept block that fits before it would `mremap`, and keeps the old one.
- **kept-unmap** (`kept-unmap.patch`, on kept): the same, but the old
  block is unmapped rather than kept.
- **mremap64** (`mremap64.patch`): main with `move_large` 64 KiB, so
  more blocks grow by `mremap`.
- **mremap-kept** (`mremap-kept.patch`): `mremap` first from 64 KiB on
  Linux, a kept block only where it cannot (the Mac, smaller blocks).
- **kept64** (the branch): kept, and `move_large` 64 KiB: a kept block
  that fits first, else on Linux `mremap` from 64 KiB, else the
  caller's copy.

A first try of kept also grew a block in place into a kept block that
began where it ended (`takeAfter`): found by walking the kept lists, it
spent 60% of `big1000`'s time in `remap`, and without it the rows were
the same, so it was taken out. Kept blocks are mostly of exact sizes
(a table's growth frees one of each), so a neighbour long enough is
rare.

## bench/hash on pup

`hb.py 9`: each program nine times, interleaved, fastest of each row,
ns per operation, core 6. The allocators under the Zig table
(`hb-zig-pup4.txt`, the last and quietest of four runs; `hb-zig-pup2`
and `-pup3` hold all five variants):

| row | main | kept | kept64 | kept64 against main |
|---|---:|---:|---:|---|
| int100000 insert | 11.00 | 10.57 | 10.27 | 7.1% faster |
| rnd100000 insert | 11.35 | 9.88 | 9.67 | 17.4% faster |
| rnd150000 insert | 12.47 | 9.82 | 9.61 | 29.8% faster |
| str100000 insert | 19.31 | 16.55 | 16.40 | 17.7% faster |
| big100000 insert | 27.18 | 20.91 | 21.45 | 26.7% faster |
| all 104 rows, geometric mean | 1 | 0.968 | 0.983 | 1.7% faster |
| the 18 rows of 3M and 4M keys | 1 | 0.970 | 0.998 | the same |

With malloc beside them (`hb-zig-pup3.txt`: malloc, main, kept64),
kept64 closes 41% of main's gap to malloc on int100000 (9.98, 11.50,
10.87) and 72% on big100000 (18.67, 28.79, 21.49), matches it on
rnd100000 (9.90, 11.30, 9.99), and passes it on rnd150000 (10.30,
12.84, 10.09).
mremap64 and mremap-kept were slower than main on these rows
(`hb-zig-pup2.txt`: int100000 13.09 and 12.97 against 11.30,
big100000 30.94 and 31.12 against 29.07): moving pages takes fresh
ones every time, the cost the profile found. kept-unmap lost most of
kept's gain (`stat-pup.txt`'s method: big1000 kernel cycles 227M
against kept's 6M), since the next table's growth then finds no block
to take.

Rig's own Map (`map.rig`, `rig-fast`, built by each Rig;
`hb-rig-pup3.txt`): kept64 against main 2.0% faster over 130 rows,
the same over the 3M and 4M rows (0.7% faster); big100000 insert
20.7% faster, rnd150000 18.9%, str100000 21.7%, int100000 7.0%.

`--mem` (one map of 4M Int keys): kept64 34.6 bytes an entry under the
Zig table against main's 34.8; 29.3 against 29.6 for Rig's Map.

On the Mac nothing changes: there is no `mremap`, and a kept block that
fits was already what the caller's copy took (`hb-zig-mac.txt`,
`hb-rig-mac.txt`: kept against main 0.997 over the Zig rows, Rig's Map
within 1%).

## Trig on pup

ts-pattern and zod3 at one checker, `measure.py 20` (alloc-seg-thp's):
core 6, sibling 7 idle, 20 rounds, the six builds interleaved and the
order reversed every other round; fastest wall, fewest cycles and
instructions, peak RSS by `/usr/bin/time`, the same in every run of a
build (`trig-perf2.md`; `trig-perf.md` is a first run of main and
kept). Every build is Trig main `403a823` built release through
`/zfs/trig-pup/trial/slot.sh` on cores 0,5 (`build.sh`).

| project | build | wall s | median | instructions | user cycles | kernel cycles | faults | RSS MB |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| ts-pattern | main | 0.946 | 0.970 | 9,285.6M | 3,831.5M | 356.0M | 39,908 | 271.6 |
| ts-pattern | kept | 0.951 | 0.966 | 9,289.4M | 3,851.0M | 345.5M | 39,907 | 274.2 |
| ts-pattern | mremap64 | 0.947 | 0.971 | 9,289.1M | 3,839.4M | 357.1M | 40,892 | 267.5 |
| ts-pattern | mremap-kept | 0.944 | 0.969 | 9,291.5M | 3,854.7M | 348.5M | 40,893 | 267.5 |
| ts-pattern | kept-unmap | 0.946 | 0.963 | 9,288.0M | 3,847.5M | 356.8M | 40,135 | 268.8 |
| ts-pattern | kept64 | 0.946 | 0.972 | 9,282.1M | 3,864.8M | 341.5M | 40,805 | 264.1 |
| zod3 | main | 0.193 | 0.199 | 1,687.6M | 715.1M | 91.5M | 9,316 | 84.7 |
| zod3 | kept | 0.192 | 0.200 | 1,686.4M | 720.0M | 93.4M | 9,318 | 87.3 |
| zod3 | mremap64 | 0.193 | 0.200 | 1,691.1M | 715.7M | 95.4M | 9,959 | 84.9 |
| zod3 | mremap-kept | 0.192 | 0.200 | 1,679.4M | 715.5M | 95.4M | 9,959 | 84.9 |
| zod3 | kept-unmap | 0.194 | 0.201 | 1,682.6M | 724.9M | 97.2M | 9,510 | 82.7 |
| zod3 | kept64 | 0.192 | 0.202 | 1,690.0M | 716.9M | 94.7M | 9,960 | 82.2 |

No variant moves Trig's time: every wall is within 0.6% of main's, and
instructions within 0.5%. Peak memory differs, deterministically:

- kept: 1.0% higher on ts-pattern, 3.1% on zod3. A growth that copies
  into a kept block takes no new pages, so nothing trims, and the block
  it left stays kept within the bound.
- mremap64 and mremap-kept: 1.5% lower on ts-pattern, 0.2% higher on
  zod3.
- kept64: 2.8% lower on ts-pattern (264.1 MB against 271.6) and 2.9%
  on zod3 (82.2 against 84.7). Below 1 MiB main grows a block by
  copying it into a new one and keeps the old, resident; kept64 moves
  its pages when no kept block fits, so the old block is not left, and
  takes a kept block when one fits, so tables built again reuse pages.

## Decision

kept64 is taken: bench/hash's 100,000-key inserts 7-30% faster under
the Zig table (Rig's Map 7-22%), 1.7% faster over every row and the
same on the 3M and 4M rows, and Trig's peak memory 2.8-2.9% lower with
its time unchanged. It does not clear Trig's speed bar; it is kept on
bench/hash's gain with Trig's memory lower, the rule the owner set for
this round. The other four are recorded here as measured and not taken.

## What is left

- **big16 and big1000** (tables of 16 and 1,000 big values) stay
  11-17% behind malloc (hb-zig-pup3), unchanged by any variant. Their insert time is
  the copy of a small block crossing size classes (11% of big1000 in
  `memcpy`, where glibc extends in place) and, in `big16`, about 30M
  kernel cycles of new segments: a page of alloc.zig stays with the
  size class that first took it, so the earlier rows' empty pages
  cannot serve the 1,280-byte class, and glibc's freed chunks serve any
  size. Returning an empty page to its segment for any class (as
  mimalloc does) is the lead; it costs a count per page on every free.
- In-place growth into a free neighbour needs kept blocks found by
  address, and coalesced, to pay; see `takeAfter` above.

## Gates

- A failing case first: "a large block grows into a kept block that
  fits..." and "on Linux a large block from 64 KiB that no kept block
  fits grows by moving its pages" fail on main (on pup, another address
  and a null remap) and pass here; `zig test src/alloc.zig` passes on
  the Mac and pup.
- `tools/heavy swarm test/rig.rip all -q -w 6` on the Mac: 10,775 jobs,
  none died.
- `zig build test` on pup: safe and fast pass. Debug failed once, run
  beside the Trig light gate's load, in `src/tasks.zig`'s "a set of
  tasks keeps the failure it gives and drops every other one's data"
  (the kept byte read 170, 0xAA, a slot never written); then three runs
  each of main and the branch passed. Debug builds allocate through the
  leak checker, not alloc.zig.
- Trig's light gate (`tools/pup-rig 4bee4748c`, then `PUP_RIG=` its
  Rig `tools/light`, from a clone of Trig `403a823` whose release slots
  and workers keep off cores 1-3 and 8-11): GREEN in 69 s.
- loco's light gate (loc `947ffa0`): GREEN in 32 s, 122 runs, none
  differ.
- std.json's guard: within 2% on all six files (0.1-0.7% fewer
  instructions per byte than `guard.txt`).
- The runtime benches (bench/tasks, actors, net, http) were not run:
  the change touches only a large block's growth.
