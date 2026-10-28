# Huge pages for the allocator's 4 KiB memory: remedy 2 (2026-10-28)

**Question.** The kernel profile of table fault-ahead
([perf-stage/fault-ahead/kernel.md](../perf-stage/fault-ahead/kernel.md),
§4 and remedy 2 of §5) found "alloc.zig segment region: ~14.5k pages
(57 MiB), all populated by madvise, at 4K", and estimated that huge
pages for it would save about 45M kernel cycles on ts-pattern at one
checker (1% of the total), plus dTLB walks. The owner approved building
that remedy in `src/alloc.zig`, measured on Trig on pup. Why does that
memory stay at 4 KiB, and what fixes it?

**Answer.** The segment region does not stay at 4 KiB. Since #740
(`da32cb8af`), every segment of a heap that faults in ahead is advised
`MADV_HUGEPAGE` before its first populate, and on Trig all of that
memory is in huge pages: 44 MiB of 44 on ts-pattern, 20 of 20 on zod3,
at peak. The 57 MiB populated at 4 KiB is the allocator's *large*
blocks (32 KiB to 16 MiB, `mapLarge` and `remap`), which `prefault`
fills by `MADV_POPULATE_WRITE` (`likelyFilled`): the profile's
"segment region" is mislabelled. Those blocks are mostly too small,
or populated in stretches too short, to hold whole huge pages: of the
49.3 MiB that ts-pattern populates in them, 8 MiB lies in whole 2 MiB
windows, and of zod3's 17.7 MiB, none. At ts-pattern's peak, 26 MiB of
plain (small-page) anonymous memory is wholly resident in aligned 2 MiB
windows; at zod3's, none. **No change is made**: remedy 2's target is
already built, and what remains at 4 KiB in `alloc.zig` cannot clear
the speed bar with peak memory no higher.

## What was measured

Trig `403a823` built `--release --pgo` by Rig `2c01f07dd`
(`/zfs/worktrees/rig/tsrs-standing-1028/packs/2c01f07dd-pgo/bin`, sha256
`ddd421a5cdb58f3b...`), `-p tsconfig.trig.json --noEmit --checkers 1`
on pup core 6 (sibling 7 idle). pup: kernel 7.0.0-38, THP `madvise`,
defrag `madvise`, `max_ptes_none` 511, load 1.8 to 3.7 (other
sessions' work on other cores).

- `peak.py`: reads `/proc/PID/smaps` every 5 ms and prints, at the
  sample of largest Rss, each mapping's Rss, AnonHugePages and flags
  (`peak.txt`).
- `windows.py`: at the sample of largest Rss, for each plain anonymous
  mapping (neither `hg` nor `nh`), the 2 MiB-aligned windows wholly
  inside it whose 512 pages are all present (`/proc/PID/pagemap`): the
  memory huge pages could have held at no cost in memory
  (`windows.txt`).
- `pop.py`: from `strace -f -e trace=madvise,mmap,mremap,munmap`, every
  `MADV_POPULATE_WRITE`, split into the segment region's and the rest,
  with the whole 2 MiB windows inside each call's range (`pop.txt`).
- `/proc/vmstat`'s `thp_fault_alloc` around three runs, and `/usr/bin/time`.

## The segment region is in huge pages

At ts-pattern's peak (`peak.txt`), the segment region is the 64 GiB
`MAP_NORESERVE` reservation and the segments carved from its start:

| mapping | size | Rss | AnonHugePages | flags |
|---|---:|---:|---:|---|
| the leading heap's first segment | 4 MiB | 4.0 MB | 4.0 MB | `nr hg` |
| the second thread's segment | 4 MiB | under 1 MB | 0 | `nr` |
| the leading heap's other segments | 40 MiB | 40.0 MB | 40.0 MB | `nr hg` |

zod3: 4 and 16 MiB, `hg`, wholly in huge pages; the second thread's
segment likewise plain and nearly empty. Each run takes 25 huge-page
faults (`thp_fault_alloc`, the same in three runs): 22 for the
segments, 3 for the one block of 16 MiB or more (`huge_large`). The
segment region's populates (41 calls, 41.0 MiB on ts-pattern; 17 and
17.0 on zod3) all fall in `hg` ranges, and a populate there takes a
huge page, as [alloc-seg-thp/](../alloc-seg-thp/README.md) found. The
fault-ahead experts' own `smaps-main` (Rig `8292a97f9`, which has #740)
shows the same: 4 and 40 MiB `hg`, all AnonHugePages.

The candidates the brief named do not apply: segments are 4 MiB
aligned to their size, so each is two whole huge pages; `newPage`
advises before it populates; the leading heap leads from its first
segment (`leads`: no other heap has taken anything); the one segment
at 4 KiB is the second thread's, which holds under 1 MB; no collapse
by khugepaged is needed, since the pages are huge at their fault.

## Where the 57 MiB is

| | ts-pattern | zod3 |
|---|---:|---:|
| minor faults (`%R`) | 51,885 | |
| populate in large blocks, over the run | 201 calls, 49.3 MiB | 150 calls, 17.7 MiB |
| of it in whole 2 MiB windows | 8 MiB | 0 |
| populate calls under 2 MiB | 39.8 MiB | 17.7 MiB |
| plain anonymous memory at peak (mappings of 2 MiB Rss or more) | 37-38 MB in 8 mappings | 7.6 MB in 3 |
| of it wholly resident in aligned 2 MiB windows | 26 MiB (13 windows) | 0 |

Large blocks are mostly Lists growing by `mremap` from 64 KiB
(alloc-grow, #749), and a growth populates half the bytes it gains, so
a block's populates are a few hundred KiB to a few MiB at a time, at
offsets a huge page rarely lines up with. The blocks that reach several
MiB fill their tails by ordinary faults, which is how 26 MiB of
ts-pattern's ends up in resident 2 MiB windows by its peak. The largest
mappings are 14, 7 and 6 MiB on ts-pattern (5, 3 and 2 windows) and
3.5 MiB on zod3 (none).

## Why no change

- **Memory-neutral huge pages** (advise only the whole 2 MiB windows
  inside each populated range, which populate commits anyway): 8 MiB
  on ts-pattern, about 2,000 pages at the profile's ~3,100 kernel
  cycles saved a page, ~6M cycles, 0.15% of the run; nothing on zod3.
  It also splits a block's mapping in two or three, and `mremap` grows
  only a range within one mapping, so every later growth would need
  the advice made whole first.
- **Huge pages for whole large blocks below 16 MiB** reach at most the
  26 MiB resident at peak on ts-pattern: ~6,700 pages, ~20M kernel
  cycles, 0.5% of the run, with some dTLB gain on top, and nothing on
  zod3. This is the lead #725 measured as "every new block of 2 MiB or
  more" ([alloc-large/](../alloc-large/README.md)): ts-pattern 1.0 to
  1.8% faster at one checker, peak memory 2.0% higher, left out; and
  [alloc-thp16/](../alloc-thp16/README.md) took only 16 MiB and up,
  where memory did not rise. Since then #749 grows these blocks by
  `mremap` and reuses kept blocks, which lowered Trig's peak 2.8 to
  2.9% but leaves the blocks no larger: the largest are still under 16
  MiB, and a huge page advised over a block's untouched tail still
  commits up to 2 MiB a block. A threshold between 2 and 16 MiB covers
  less than the 26 MiB bound and still raises ts-pattern's peak. So
  this lead cannot clear the bar (more than 1.5% faster, or 1% fewer
  instructions, with peak memory no higher), and was not rebuilt.
- **Even all of it free**: if every 4 KiB page the large blocks take
  (49 MiB populated, ~60 MiB with their faults) were a huge page at no
  memory cost, the profile's per-page costs give ~45M kernel cycles,
  about 1.1%: the experts' estimate, which is the bound of this memory,
  not of the segments.

The 4 KiB pages that remain in Trig are the tables (123 MiB at
ts-pattern's peak, `nh`), remedy 1's work in `src/table.zig`, and these
large blocks. Remedy 2, huge pages for the segment region, is #740,
built and in main since 2026-10-27.

## Commands

    python3 peak.py BIN PROJECTDIR        # in misc/projects; core 6
    python3 windows.py BIN PROJECTDIR
    taskset -c 6 strace -f -e trace=madvise,mmap,mremap,munmap -o strace-tsp.txt BIN -p tsconfig.trig.json --noEmit --checkers 1
    python3 pop.py strace-tsp.txt
    grep thp_fault_alloc /proc/vmstat     # before and after a run

The straces (654 and 519 lines) are on pup in
`/zfs/worktrees/rig/alloc-seg-huge/`.
