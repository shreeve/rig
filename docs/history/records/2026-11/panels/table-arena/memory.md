# table-arena panel, memory lens (TLB, page tables, huge pages, mmap layout)

2026-11-05. Read-only. Sources: scaling/investigation.md, table-arena.md
(+ arena-data/ab-summary.md), table-vmas.md, task-memory.md,
2026-10/perf-stage/stlb-aliasing.md (+ its table-color.diff, pstat1.txt),
kernel-leads.md, table-huge.md, archive-tags.md; `archive/table-arena`
against its base 11df1f2c1; origin/main `src/table.zig`, `src/alloc.zig`.
Mac probe: scratchpad/panels/table-arena-memory/ (alias2.c, place.c,
alias2.txt).

## The finding that reframes the panel

The packed build's win came from moving Table heads off 2 MiB boundaries.
It did not come from packing them densely.

stlb-aliasing.md (2026-11-01/02) had already found that on pup's E-cores:

- two thirds of Trig's STLB misses land on **page 0 of a 2 MiB-aligned
  Table head**: 66.9% on ts-pattern, 64.2% on zod3;
- among Table misses, 83% fall in one STLB set (page index mod 128 = 0).

`reserveTable` (alloc.zig:987) hands out 2 MiB-aligned ranges, and a
Table's lowest slots are its hottest. So each checker's ~43-50 heads
share one set of a cache that holds about 16 entries per set. These are
conflict misses, not capacity misses.

A **coloring arm** started Table k at `(k*37 mod 512)` pages into its
range: about 30 lines, in the record as table-color.diff. It was counted
on E-cores and timed only on P-cores. It was never landed, tagged or
closed.

Set its counters beside the packed build's. Same E-cores, memory
fragmented (1-2 free 2 MiB blocks), so neither arm had huge pages:

| walk stall (`ld_head.pgwalk_at_ret`), % of user cycles | main | packed (table-arena) | colored (stlb-aliasing) |
|---|---:|---:|---:|
| ts-pattern, 1 checker | 4.48 / 4.0 | 1.47 | 1.15 |
| ts-pattern, 4 | 4.24 / 3.7 | 0.78 | 0.97 |
| zod3, 1 | 2.95 / 2.5 | 0.50 | 0.71 |
| zod3, 4 | 3.59 / 3.1 | 0.62 | 0.97 |

(main: the arena record's base / the color record's main. The colored
figures are its stall counts over user cycles: 199.5M to 58.0M, 214.7M to
55.8M, 22.9M to 6.6M, 43.4M to 13.6M.)

The two arms land within about 0.3 points of each other.

- The packed build's heap blocks are not 2 MiB-aligned, so it de-aliased
  the heads as a side effect.
- Coloring gets the same 3-3.5 points:
  - with no test on any read;
  - with no zeroing;
  - with RSS unchanged (231,220 against 231,216 KB).

The record's conclusion, "a table's density cannot come without a test on
every read", is true. But density was not what paid.

## Q1. Where do the page walks come from?

The STLB-miss loads, sampled with data addresses (stlb-aliasing,
`memcls2.py`), ts-pattern at one checker, E-core:

| Source | Share of misses |
|---|---:|
| Table heads, page 0 of a 2 MiB window (set conflict) | 66.9% |
| Table heads, other pages | 14.3% |
| Large blocks and Lists grown by `mremap` | 10.8% |
| The binary's data (its first rodata page, at 0x1000000, is another page 0) | 7.0% |
| Stacks | under 1% |

- **Code is not in this metric.** `ld_head.pgwalk_at_ret` counts loads.
  Instruction-TLB walks were never measured, and the binary row above is
  rodata loads.
- **The heap's share is small.** Segments are not visible in this table,
  and large blocks are 11%.
- **After coloring, page-0 misses fall from 80% to 41% (ts-pattern) and
  from 74% to 18% (zod3).** The page-0 misses left are on large blocks
  (which the kernel places on 2 MiB boundaries) and on segment headers (4
  MiB-aligned, on small pages while the gate is shut). That is the same
  aliasing, in the heap's mappings.
- **Sparse small-page Tables matter for faults, page tables and exit, and
  little for walks.** Once de-aliased, Trig's walks fall 81-85%, to about
  1.3M against tsrs's 0.35M on ts-pattern.

**How much is wall time.** On E-cores the walk stall turns into cycles
about one for one. Overlap does not hide it:

- ts-pattern, one checker: coloring removes 2.8 points of walk stall, and
  user cycles fall 2.9%;
- zod3, four checkers: 2.2 points of stall removed, 4.6% fewer cycles (the
  extra is L2-set conflicts on the same heads: latp0 put 3.6% of
  slow-load latency on page 0);
- the packed arm: the stall it removed works out to 2.6% of base user
  cycles at one checker and 3.4% at eight (ab-summary's cycles × the
  stall shares).

So the ceiling on E-cores is about 2-4% of wall, roughly 25-45 ms on
ts-pattern at one checker and 12-17 ms at four or eight.

On P-cores the coloring arm timed **level** (20-60 rounds, every row
within A/A). P-core walks were never counted, so either the P-core STLB
does not alias this way or its walkers hide it. I don't know which.

## Q2. A layout with tsrs's density, without a test or zeroing?

A read with no test needs every slot it may read, up to n, at a fixed
mapped address: a reservation of all n. That rules out sharing a page
between two Tables' heads. It does not rule out spreading them across
TLB sets, which is all the walks needed.

| Candidate | Avoids the read test? | Avoids zeroing? | Verdict |
|---|---|---|---|
| One reservation per checker or thread, carved densely, the whole carve moving when one Table outgrows it | yes | yes | **Unsound or no gain.** Moving the carve moves Tables that were not written, under live loans on them (`a = ?t2[s]` while `t1` grows). That breaks CORE's "only a write moves a table". Without moving, each Table still needs n slots of address space, so heads cannot share pages. Sizing from a first pass is Trig choosing a smaller n, Trig's call. Rig has no "checker", and per-thread placement buys page-walk-cache locality, not fewer TLB entries. |
| `MAP_NORESERVE` with lazy faults | yes | yes | **Already main** (table.zig:121, alloc.zig newTableRegion). The packed build's zeroing came from putting Tables in reused heap blocks, not from main's design. |
| `MADV_HUGEPAGE` only on dense regions | yes | kernel zeroes 2 MiB | **Little left.** Density is known only at a write: jit's hook cost 0.8% of instructions (table-huge). Full windows hold 28% (ts-pattern) and 8% (zod3) of misses, and coloring takes the page-0 conflict without them. |
| THP `defrag=defer` | n/a | n/a | **Not Rig's to choose.** It is a machine-wide sysfs setting; pup and the distribution defaults use `madvise`. `alloc.zig`'s gate already does per process what `defer` does: take a free block if there is one, never compact. khugepaged's 10 s scan is useless for 0.1-1.3 s runs. |
| tsrs's heap | n/a | n/a | **Its density is in its data, not its mmap.** One 32 GiB reservation, carved by bump allocation into 2 MiB chunks advised huge with **no gate**, which compacts in the fault. Its handles are allocation-ordered, so each thread fills its chunks front to back: that is where its 60% on huge pages comes from. Rig cannot take the no-gate half (thp-fragmented: 34-41% slower when fragmented). The dense half is Trig's id numbering (table-arena "What this leaves", investigation §7). Its mimalloc heap stays on 4 KiB pages, and takes 85% of tsrs's few misses. |
| **Coloring** (new to this panel's list, built 11-02) | yes | yes | **The one that fits.** It keeps the reservation and spreads the heads across TLB and L2 sets. |

## Q3. Why were huge pages from a Table's first byte much slower?

This is kernel-leads lead 1.

- **Each Table's first write takes a whole huge page, cleared by the
  kernel.** 40-48 of a checker's 43-50 Tables stay under 2 MiB, so each
  first touch zeroes 2 MiB that is mostly never used:
  - about 50 more huge pages a checker (ts-pattern 115 against 65);
  - peak RSS 27% higher on ts-pattern, 111% on zod3, 186-408% on the
    small projects;
  - on the small projects, 38-127% more kernel cycles and a 2.5-29%
    slower run.
- **Compaction, once the free blocks run out.** At four checkers, 172
  Tables asking for their whole ranges drained the free blocks the gate
  had counted, and later faults compacted: 263 stalls in 20 ts-pattern
  runs.
- **It was faster on the large projects** (3.2% on ts-pattern, 2.8% on
  zod3). That fits this lens's reading: a huge head is one TLB entry, so
  it cannot alias.

Coloring avoids both causes. It changes no advice and commits no page
earlier: heads stay on 4 KiB pages, and the gate is untouched.

## Q4. The design: colored Tables (and later, colored large blocks)

### Step 1, colored Tables

This is stlb-aliasing's table-color.diff, rebased. main now uses
`tables_lock.lock()` where the diff has `lockTables()`; nothing else
moved.

- **`src/alloc.zig`:**
  - add `colorOf()`: an atomic counter k, giving `(k*37 mod 512)` pages;
  - `reserveTable` (line 987) takes `color + bytes` rounded up to 2 MiB,
    returns `at + color`, and advises huge from
    `alignForward(color + 2 MiB)`;
  - `unreserveTable` (line 1005) aligns `p` back to its window before
    `MADV_DONTNEED` and handing the range back;
  - three unit tests change (in the diff).
- **`src/table.zig`:** none required.
  - `reserve` (line 118) maps its own range in debug builds and for
    Tables larger than a region. It may take the same offset for
    uniformity.
  - `at`, `constSlot` and `slot` (lines 225-241) are untouched. No
    instruction is added to any access.
- **Docs:** INTERNALS' Table row, and table.zig's header (in the diff).
  CORE is untouched: addresses are not semantics.

Expected gain:

- **E-cores:** 2.1-4.6% fewer user cycles, counted at 1 and 4 checkers,
  so about 2-4% wall where the scaling loss lives. At eight checkers
  (about 344 heads in one set today) it should match the packed arm's
  4.29 to 0.75 points.
- **P-cores:** level, as measured.
- **Unchanged:** faults, the exit, and the zero-page shootdowns. Those
  follow resident pages, which coloring does not change.

Memory:

- **Peak RSS identical,** measured: the same pages are touched.
- **Address space:** up to 2 MiB more per Table, unbacked.
- **Page tables:** at most one more 4 KiB page per Table whose written
  span now crosses a 2 MiB boundary, at most 1.4 MiB at 344 Tables and
  likely a few hundred KiB. VmPTE is not in maxrss, so this needs
  reporting on its own.
- **With the gate open:** a large Table's small-page head grows from
  2 MiB to up to 4 MiB less its color, so slightly fewer huge pages and
  slightly more faults. RSS cannot rise from it.

Risks:

- **The gain is E-core-only, as measured so far.** Like loop-split's
  arm64 question, whether that counts is the owner's call.
- **Coloring on the Mac.** The probe (Apple M5, 16 KiB pages, 200M
  random reads): 200 aligned heads run 1.4-1.9 times slower than colored
  ones (521-533 against 279-293 ms; 398-431 against 282-305), and 50
  heads are level. But macOS Tables never use `reserveTable`, and macOS's
  own `mmap` already scatters their starts (place.c: 43 mappings at
  mostly distinct offsets mod 2 MiB). So the Mac needs nothing now.

### Step 2, after step 1 lands or fails on its own

Color the large blocks that are not advised huge. Today the kernel
places these on 2 MiB boundaries (`mapLarge`, line 523, `mapPages`, line
534). The colored arm's leftover page-0 misses point at them. The offset
must be kept for `mremap` and `munmap`.

Segment headers are 4 MiB-aligned by design (a pointer is masked to find
its segment), so only the header's hot fields could move. Count them
before designing anything.

### Not proposed

- The packed or committed arena itself: DROP. Its walk gain is had
  without it.
- Huge heads, `MADV_COLLAPSE`, the jit hook, a no-gate policy: measured
  and closed (above).

## The measurement that settles it (once pup is back)

1. **Build.** Rebase table-color.diff onto origin/main's alloc.zig, as a
   plain build with no switch. Build Trig's PGO binary with it through
   `table-vmas-data/variant-zig`, which swaps `alloc.zig` alone, against
   the same Trig built with main, plus a byte-identical A/A copy.
2. **E-cores, wall.** One checker on 12, four on 12-15, eight on 12-19,
   in a slot from `/tmp/open-slot.sh`, as in the investigation:
   - 20 shuffled interleaved rounds per arm (more on the short projects);
   - free 2 MiB blocks logged per run;
   - counters `pgwalk_at_ret`, `walk_completed`, user and kernel cycles,
     instructions, and peak RSS, plus VmPTE near the end of a run;
   - the STLB-miss attribution (`memcls2.py`, `setconf.py`): the
     page-0 share should fall below 5% for Tables.
3. **P-cores, counters.** The same arms on core 6 with
   `cpu_core/dtlb_load_misses.walk_completed/`, `walk_active` and
   `mem_inst_retired.stlb_miss_loads`. This answers why P-cores were
   level, which stlb-aliasing left open.

It passes if the E-cores are more than 1.5% faster by the median over 20
rounds, cycles agree, peak RSS is level, and the P-cores are level or
better. If it passes on E-cores alone, it goes to the owner as an
E-core-only gain.

## Verdict

**MEASURE FIRST: colored Tables** (step 1), timed on E-cores at 1, 4 and
8 checkers. **DROP** the packed arena.
