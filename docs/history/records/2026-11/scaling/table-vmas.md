# Tables' split mappings, and what Trig's exit is made of (2026-11-04)

**Question.** [investigation.md](investigation.md) counted 1,304 mappings
in Trig at eight checkers against tsrs's 107, and an exit of 25-28 ms
against 10-12. Most of those mappings are Rig's. `reserveTable` and
`table.zig`'s `reserve` advise each Table's range past its first 2 MiB
`MADV_HUGEPAGE` inside a region advised `MADV_NOHUGEPAGE`, which splits
the region into two or three mappings a Table. Would one huge-page
policy for the whole Table region, set once, so Tables share mappings,
shorten the exit? And which part of the exit is the mapping count, and
which the sparse page tables of Trig's id numbering?

**Answer.**

- **The mapping count is about 1 ms of the exit at most.** Neither
  variant is built.
- **Page tables are well under 1 ms.**
- **The exit is the resident memory.**
- **The split happens only when memory has free 2 MiB blocks.** With
  memory fragmented, as pup's has been since 21:30 (0 or 1 free block
  after compaction), main's Tables already sit in one mapping per
  region.

## What splits the mappings

Every split is gated on free 2 MiB blocks (`alloc.zig`'s `hugeFree`
and `hugeFreeFor`):

- a Table's tail advised `MADV_HUGEPAGE` in `reserveTable`;
- a heap's segment and a large block advised for huge pages in
  `adviseHuge`.

With the gate shut, nothing is advised. Trig's PGO build on ts-pattern
at four checkers, with 1 free block (a `/proc/PID/smaps` snapshot at
about 70% of a run), had 264 mappings, 255 of them anonymous:

- **The Tables' region was one mapping**, 66 MiB resident.
- **The rest were the heaps' and stacks' mappings:**
  - 134 between 2 MiB and 1 GiB, 12 MiB resident;
  - 118 of 2 MiB or less, 31 MiB resident;
  - 2 large ones, 25 MiB resident.

The investigation's 1,304 mappings were measured with 82 free blocks.

## The exit's parts, measured

[vmabench](table-vmas-data/vmabench.zig) maps 64 GiB, writes small
pages densely or one every STRIDE, and splits the mapping the way the
Tables split their region. It then exits under
[exitwatch](exit-handoff-data/exitwatch.zig), which times the kernel's
teardown of exactly that shape (reaped less at-exit). It ran on pup core
16 at 22:14, with no timing job running and Trig's release builds on
P-cores, load 4.6, 8 rounds ([vmab.sh](table-vmas-data/vmab.sh),
[vmab.txt](table-vmas-data/vmab.txt),
[vmab-ptes.txt](table-vmas-data/vmab-ptes.txt)). Medians of the
teardown:

| Shape | 1 mapping | 1,300 mappings |
|---|---:|---:|
| nothing written | 0.09 ms | 0.51 ms |
| 45,000 pages (176 MiB), dense | 6.25 ms | 7.14 ms |
| 45,000 pages, one per 40 KiB (about 900 page-table pages, Trig's shape at eight checkers) | 6.44 ms | 7.54 ms |
| 30,000 pages, dense | 4.6 ms | |
| 30,000 pages, one per page-table page (30,000 of them) | 23.9 ms | |

- **A mapping costs 0.3-0.85 µs at exit.** 1,300 of them cost 0.4-1.1
  ms, under 0.25% of ts-pattern's wall at four or eight checkers. A
  shared Table mapping could not clear the bar of 1.5% on its own.
- **A page-table page costs about 0.65 µs.** Trig's 3.4 MiB of page
  tables at eight checkers (about 870 pages) is about 0.6 ms. Sparse
  ids cost Trig more as page faults and page walks during the run
  ([investigation.md](investigation.md), section 3) than at exit.
- **A resident small page costs about 0.14 µs.** Trig's exit follows
  its resident memory instead:
  - `trig --version`, the binary mapped and nearly nothing written:
    0.25 ms;
  - ts-pattern at one checker, 206 MiB resident: 12-13 ms;
  - at four checkers, 229 MiB: 25 ms
    ([exit-handoff.md](exit-handoff.md)).

  Trig's pages cost about twice what the probe's dense pages do. They
  are spread over heaps, stacks and Tables, with threads' exits beside
  them; this record does not split them further.

So what shortens the exit is less memory resident when the process
ends: a checker dropped in its own task as it finishes gives its Tables'
pages back there, while the others still check (Trig's change 1, Trig's
`checker-drop`).

## The variants, kept but not built

- **small** ([small.diff](table-vmas-data/small.diff)): Tables never ask
  for huge pages, so their region stays one mapping.
- **region** ([region.diff](table-vmas-data/region.diff)): the region
  asks for huge pages once, as it is mapped, while the gate is open; no
  Table asks. Every Table's first page would then commit 2 MiB, which
  Trig's v1 found much worse, and peak memory would rise.
- **A head kept small by placement** cannot be had: in one mapping
  advised for huge pages, any aligned 2 MiB may become a huge page at a
  fault. Only a mapping of its own keeps a Table's head on small pages.

[variant-zig](table-vmas-data/variant-zig) swaps a variant's
`table.zig` and `alloc.zig` into a program's runtime as it compiles, for
a Trig build against any of them.

## Today against Trig's drop (2026-11-05)

Trig's `checker-drop` (Trig - Helper's, 374b77a, on Trig main c23dfe0)
drops each checker in its own task once nothing can ask it more; the
last to finish keeps its own. Both builds use Rig 27010375f:

- **today:** c23dfe0, PGO-trained by `tools/trig/pgo`;
- **drop:** 374b77a, optimized by today's profile with no training of its
  own, so the functions the drop changed run without a profile.

Their output is the same in 46 cases ([ident.sh](table-vmas-data/ident.sh)):

- the six race projects at 1, 4 and 8 checkers;
- `--extendedDiagnostics`, with its times left out;
- `TRIG_LAZY_STATS` at 4;
- two small `--noEmit --declaration` projects, one clean and one with a
  declaration error.

The runs were on pup's E-cores (1 on 12, 4 on 12-15, 8 on 12-19) in one
slot, 01:28-01:32, with 10 free 2 MiB blocks at its start and 0 at its
end, load 1.9. There were 20 shuffled rounds; each job ran once under
exitwatch and once under `perf stat` and `/usr/bin/time`
([abslot.sh](table-vmas-data/abslot.sh),
[abn3.sh](table-vmas-data/abn3.sh), [abn3.py](table-vmas-data/abn3.py),
[drop-ab.txt](table-vmas-data/drop-ab.txt),
[summary](table-vmas-data/drop-ab-summary.md)).

| project | C | wall median, ms | wall fastest | exit median | peak RSS median, MiB | instructions |
|---|---:|---|---|---|---|---|
| ts-pattern | 1 | 1,218.8 → 1,225.4 | 1,178.1 → 1,194.2 | 19.8 → 19.7 | 204 → 204 | 0.6% more |
| ts-pattern | 4 | 521.8 → 510.8, 2.1% faster | 479.1 → 480.1 | 29.6 → 19.5 | 229 → 198, 13.6% less | 0.9% more |
| ts-pattern | 8 | 450.1 → 440.0, 2.2% faster | 420.0 → 419.7 | 32.5 → 22.1 | 247 → 178, 28.0% less | 1.1% more |
| zod3 | 1 | 211.7 → 213.6 | 198.8 → 195.9 | 6.8 → 6.7 | 71 → 71 | 0.4% more |
| zod3 | 4 | 130.0 → 126.7, 2.5% faster | 122.1 → 110.1, 9.8% faster | 10.8 → 8.0 | 95 → 85, 11.0% less | 1.2% more |
| zod3 | 8 | 118.8 → 116.2, 2.2% faster | 108.4 → 103.4, 4.6% faster | 13.9 → 9.0 | 112 → 98, 12.6% less | 1.7% more |
| mitt | 4 | 24.2 → 24.4 | 19.8 → 19.6 | 3.7 → 3.3 | 40 → 40 | 1.6% more |
| neverthrow | 4 | 27.1 → 26.7 | 21.5 → 22.3 | 3.5 → 3.5 | 40 → 41 | 1.3% more |
| superstruct | 4 | 27.3 → 29.5, 8.1% slower | 24.0 → 25.0, 4.2% slower | 3.2 → 2.6 | 31 → 30 | 2.4% more |
| tiny-invariant | 4 | 96.8 → 100.6, 3.9% slower | 86.0 → 86.8 | 7.2 → 6.7 | 59 → 57 | 1.9% more |

- **The drop takes about a third of the exit off on the large
  projects:**
  - ts-pattern: 10 ms at four and at eight checkers;
  - zod3: 3-5 ms;
  - peak memory 11-28% lower.

  The exit handoff ([exit-handoff.md](exit-handoff.md)) took the whole
  exit off: 5.9% and 8.0% on ts-pattern at four and eight checkers,
  8.2% and 12.7% on zod3. The drop gets 2.1-2.5% by the median.
- **It costs instructions everywhere** (0.4-2.4% more; the checkers'
  drops run where they used not to) and wall time on the short runs:
  superstruct 8.1% slower by the median and 4.2% by the fastest;
  tiny-invariant 3.9% slower by the median. In a 25-100 ms run the
  checkers end close together, so a checker still dropping can outlast
  the one that kept its own.
- **Against Trig's bar** (more than 2% faster wall, or at least 1% fewer
  instructions with time no worse, peak RSS no higher):
  - ts-pattern and zod3 at four and eight checkers clear the wall half
    by their medians, narrowly (2.1-2.5%). Only zod3 does by its
    fastest; ts-pattern's fastest is level.
  - No row clears the instruction half.
  - superstruct and tiny-invariant are slower.
  - Peak RSS is lower or level, within 1%, everywhere.

  One slot of 20 rounds puts gains of 2-2.5% inside what the timing
  rules call noise unless they hold over more rounds; cycles back them
  only weakly (1-2% more cycles on every row).
