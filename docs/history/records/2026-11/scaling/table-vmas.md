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
