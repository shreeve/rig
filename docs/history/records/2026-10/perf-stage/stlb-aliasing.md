# Why Trig misses the TLB: huge pages, and the aliasing under them (2026-11-01)

Measured only; nothing was built, no shared file changed. Scripts and raw
output are in [stlb-aliasing-data/](stlb-aliasing-data/), but for
`color-small.txt` (252 KB), on pup in `/zfs/trig-pup/records-data/next-win/huge-pages-data/`.

## The answer in one paragraph

Trig's dTLB walk excess over tsrs is mostly not a missing-huge-page problem.
Two thirds of all of Trig's STLB misses (67% on ts-pattern, 64% on zod3)
land on **page 0 of a reserved Table**. Every Table starts on a 2 MiB
boundary (`reserveTable` hands out 2 MiB-aligned ranges, one after another),
and a Table's hottest slots are its lowest (intrinsic types, lib symbols), so
the ~50 Tables of each checker put their hottest page at the same address
modulo 2 MiB. Those pages all fall in **one STLB set**, which holds far fewer
than 50, so they evict each other: conflict misses, not capacity misses. Huge
pages cannot fix this, because a Table's first 2 MiB keeps small pages by
design (and must, to keep peak RSS: 42-48 Tables per checker stay under
2 MiB). The fix costs no memory: start each Table at a different page offset
inside its reservation ("coloring"). A micro on an E-core shows the mechanism
at full strength: 50 aligned heads of 4 hot pages each walk on 76% of reads,
colored heads on almost none, and the loop runs 2.1x as fast.

## Setup

- pup, kernel 7.0.0-38, THP `enabled=madvise`, `defrag=madvise`, khugepaged
  `defrag=1`, scan sleep 10 s, 4096 pages a scan, `max_ptes_none` 511.
  `MADV_COLLAPSE` exists (6.1+).
- Free 2 MiB blocks outside DMA moved between 0 and 97 during the session
  (other sessions' builds). Each line below says which state it ran in.
- Trig: `/tmp/cm/main` (release, built 2026-11-01 16:11 by a Rig with the
  Tables' address space, 7448a7da6 and later; `/tmp/uc/m` predates it and maps
  each Table alone), copied to `/tmp/hp/trigm`. tsrs: the shipped binary
  (`/zfs/trig-pup/tsrs-shipped/package`, copied whole to `/tmp/hp/tsrspkg`).
  Commands as `trial/head/time.sh`: Trig `--singleThreaded` or `--checkers 4`;
  tsrs `--checkerAssignment go --noLazyMembers`, `RAYON_NUM_THREADS` 1 or 4.
- E-cores only: one checker on core 12, four on 12-15. No wall-clock timing,
  no builds on pup. `perf stat --no-scale`, every counter at 100% running.
- "nothp" arms: Trig under a wrapper that sets `PR_SET_THP_DISABLE` (inherited
  across exec), outside perf; tsrs with `MIMALLOC_ALLOW_THP=0`, which makes
  mimalloc disable THP for the process. Same binaries, no code switch.

## 1. How much is on 2 MiB pages (peak-Rss sample of /proc/PID/smaps)

Classes come from an strace of the same run (`hps.py`): the 64 GiB segment
region, the 256 GiB Tables region, other plain mmaps and mremaps (large
blocks), stacks. MiB at the sample of largest Rss.

| run | free 2M blocks | peak Rss | AnonHuge | Tables (huge of) | large (huge) | segments (huge) |
|---|---:|---:|---:|---|---|---|
| Trig ts-pattern 1 | 81-97 | 237.8 | 130 | 121.5 (86) | 65.3 (6) | 38.3 (38) |
| Trig ts-pattern 1 | 64-69 | 227.1 | 44 | 110.8 (0) | 65.3 (6) | 38.3 (38) |
| Trig ts-pattern 4 | 69-97 | 278 | 100 | 146.3 (62) | 65-70 (0) | 47-48 (38-40) |
| Trig zod3 1 | 67-81 | 75.4 | 22 | 20.7 (4) | 23.9 (0) | 18.2 (18) |
| Trig zod3 4 | 64-81 | 103-105 | 18-20 | 33.4-34.2 (0) | 22-28 (0) | 26-28 (18-20) |
| tsrs ts-pattern 1 | 83-95 | 206 | 128 | arena 129 (128) | mimalloc 64.3 (0) | |
| tsrs ts-pattern 4 | 78-95 | 231 | 138 | arena 143 (138) | mimalloc 75 (0) | |
| tsrs zod3 1 | 77-95 | 57.3 | 28 | arena 29 (28) | mimalloc 16.3 (0) | |
| tsrs zod3 4 | 77-89 | 88 | 42-44 | arena 48-50 (42-44) | mimalloc 27 (0) | |

Stacks hold under 1 MiB in every Trig run.

**tsrs's allocator:** mimalloc v3 (`mimalloc-safe`, feature `no_thp`) for the
general heap, which is never advised and stays at 4 KiB (64-75 MiB on
ts-pattern), plus its own arena (`tsrs_core::reserve`): one 32 GiB
reservation at a fixed address behind 32-bit compressed handles, bump-carved
into 2 MiB-aligned chunks that are advised `MADV_HUGEPAGE` before they are
committed, with **no free-block gate**. `init_mimalloc` undoes mimalloc's
`PR_SET_THP_DISABLE`. Its notes measure the arena's huge pages at 2-6% of
wall time and give up the heap's for 24-32% less RSS.

So when memory has 65+ free blocks, Trig holds about as much on huge pages as
tsrs (130 against 128 MiB on ts-pattern at one checker). The gap in walks
does not come from there.

## 2. Why not more, place by place

- **Tables' first 2 MiB: never advised (`NOHUGEPAGE`), by design.** 35.5 MiB
  on ts-pattern at one checker, 84 at four; 16.7 and 34 on zod3. At ts-pattern's
  peak the Tables touch 96 windows: 42 full, 54 partial holding 24 MiB; 40 of
  the 50 Tables are under 2 MiB. Making the partial windows huge would commit
  84 MiB more on ts-pattern and 94 MiB on zod3 (55 windows, 1 full). Not
  possible within the RSS rule.
- **Tables past 2 MiB: advised only when more than 64 free blocks show at
  reserve.** Open, ts-pattern gets 86 MiB of them huge; shut, none. Open
  costs **10.7 MiB more peak RSS** (237.8 against 227.1), the partial last
  window of each large Table: this is the timing harness's RSS bimodality,
  and it already breaks "no higher peak RSS" whenever the gate opens.
- **Large blocks under 16 MiB: never advised.** 65 MiB on ts-pattern, 24 on
  zod3, mostly Lists grown by `mremap` from 64 KiB, populated a few hundred
  KiB at a time (alloc-seg-huge: 26 MiB of ts-pattern's lie in whole resident
  windows at peak).
- **Segments: advised before the first populate, 4 MiB aligned, fully huge**
  while 10 or more free blocks show (need 2 + floor 8). Earlier this evening
  pup had 0-9, so they got none too.
- **Not the cause:** faulting before the advice (segments and Tables advise
  first); misalignment (all advised ranges are 2 MiB aligned); khugepaged
  (10 s between scans, irrelevant to a 0.2-2 s process, and nothing relies
  on it); stacks.

## 3. What the TLB walks are, and what huge pages buy

E-core counters, median of 3 (`pstat1.txt`). Walks are
`dtlb_load_misses.walk_completed`; "walk stall" is `ld_head.pgwalk_at_ret`
(cycles the oldest load waits at retirement on a walk, a lower bound of the
cost) and "DTLB stall" `ld_head.dtlb_miss_at_ret`, both as a share of user
cycles. Free blocks 40-78 (Trig's Table gate open in 2 of 3 ts-pattern runs).

| run | user cycles | kernel cycles | walks | 4K walks | walk stall | + DTLB stall | faults |
|---|---:|---:|---:|---:|---:|---:|---:|
| Trig ts-pattern 1 | 4.99G | 339M | 4.80M | 4.68M | 2.9% | 3.8% | 15,461 |
| Trig ts-pattern 1 nothp | 5.03G | 488M | 6.68M | 6.49M | 4.0% | 5.3% | 35,742 |
| tsrs ts-pattern 1 | 3.80G | 230M | 0.35M | 0.26M | 0.3% | 0.8% | 17,704 |
| tsrs ts-pattern 1 nothp | 3.89G | 422M | 0.88M | 0.66M | 0.8% | 1.5% | 50,590 |
| Trig ts-pattern 4 | 5.77G | 613M | 5.65M | 5.47M | 3.4% | 4.5% | 42,428 |
| tsrs ts-pattern 4 | 4.53G | 310M | 0.29M | 0.19M | 0.3% | 0.6% | 21,347 |
| Trig zod3 1 | 917M | 121M | 0.55M | 0.51M | 2.0% | 2.8% | 7,785 |
| Trig zod3 1 nothp | 930M | 134M | 0.74M | 0.71M | 2.5% | 3.5% | 8,186 |
| tsrs zod3 1 | 636M | 68M | 0.037M | 0.016M | 0.2% | 0.6% | 5,327 |
| Trig zod3 4 | 1.40G | 239M | 1.10M | 1.01M | 3.0% | 3.9% | 16,211 |
| tsrs zod3 4 | 1.05G | 134M | 0.079M | 0.038M | 0.3% | 0.6% | 9,193 |

- On E-cores Trig takes **14x** tsrs's walks at one checker (ts-pattern and
  zod3) and **14-20x** at four (P-cores: 3.3x, earlier records). With huge
  pages off for **both**, still 7.6x (ts-pattern) and 6.2x (zod3): most of
  the excess exists at 4 KiB on both sides.
- Huge pages as Trig gets them cut its walks 28% (ts-pattern) and 26% (zod3)
  at one checker, 10-15% at four, and its total cycles 3.5% on ts-pattern at
  one checker, most of it kernel (faults: 488M to 339M kernel cycles).
- The TLB stalls at retirement are 3.8-4.5% of Trig's user cycles against
  0.6-0.8% for tsrs: about 0.15G of the 1.19G user-cycle gap on ts-pattern
  at one checker (13%).

**Where the misses land.** `cpu_atom/event=0xd0,umask=0x11` (retired loads
that missed the STLB; it counts 528K where `walk_completed` counts 543K)
sampled precisely with data addresses and page size (`memcls2.py`):

| | ts-pattern | zod3 | tsrs ts-pattern |
|---|---:|---:|---:|
| Tables, page 0 of a 2 MiB window | **66.9%** | **64.2%** | |
| Tables, other pages | 14.3% | 15.7% | |
| binary (4K; its first rodata page at 0x1000000 is another page 0) | 7.0% | 8.6% | 2.3% |
| large blocks and mremapped Lists | 10.8% | 10.7% | |
| mimalloc heap (4K) | | | 85.2% |
| stacks | under 1% | under 1% | 5.7% |

Among Table misses, 83% (ts-pattern) and 81% (zod3) are on page 0 of their
window, where uniform would be 0.2%; by page index mod 128, set 0 takes 83%
(`setconf.py`). Per Table (`pertable.py`, windows from a pagemap scan at peak
joined to the samples): Tables of 2 to 8 resident pages take 1-3% of all
misses each. A Table that small can only miss the STLB that often by
conflict. tsrs has no such peak (0.7% on page 0).

**The micro** (`alias.c`, core 13, 200M random reads, 4 KiB pages):

| Tables | hot pages each | heads | walks | cycles |
|---:|---:|---|---:|---:|
| 50 | 1 | 2 MiB aligned | 21.4M | 3.24G |
| 50 | 1 | colored | 79 | 3.17G |
| 50 | 4 | 2 MiB aligned | 151.8M | 6.53G |
| 50 | 4 | colored | 187 | 3.14G |
| 16 | 1 | aligned / colored | 10,514 / 87 | same |
| 8 | 1 | aligned / colored | 419 / 78 | same |

The E-core STLB holds about 16 pages of one set (conflict walks start at 16 heads); Trig's checker has
about 50 Table heads in it, and four checkers about 200.

Load-latency samples (`latp0.py`) put 4.2% of Trig's slow loads and 3.6% of
their latency on page 0 of a window (tsrs 0.2%): the same heads also collide
in cache sets (L1 and L2), a smaller second cost.

## 4. The fix: color the Tables, then decide the Tables' huge pages

**Step 1, no RSS, no fragmentation dependence: color each Table's start.**
`reserveTable` (src/alloc.zig) takes `len + c * 4096` and returns `p + c *
4096`, with `c` distinct per Table (for example a counter mod 128, or
`k * 37 mod 509`, spreading heads over the STLB's sets); `unreserveTable`
subtracts it. Whole pages only, so a Table touches exactly the pages it does
now: peak RSS is unchanged. The huge-page advice still starts at the next
2 MiB boundary. The debug and fallback paths in `table.zig` `reserve` want the
same offset. A variant adds `(k mod 64) * 64` bytes, spreading the L1 sets
too, at the cost of at most one more page per Table (about 200 KiB at one checker); measure
both.

- Expected: the page-0 conflict misses are 64-67% of Trig's walks; removing
  most of them takes the walk and DTLB stalls (3.8-4.5% of user cycles) down
  by about two thirds, plus the cache-set share: **about 2-4% faster at one
  checker, likely more at four** (four times the heads in the set), on
  E-cores. P-cores need their own measurement; their 3.3x excess points to
  the same cause. RSS: unchanged.
- It also makes the rest of the walks smaller than huge pages ever made them:
  Trig would sit near 1.7M walks on ts-pattern, from 4.8M.

**Step 2, after step 1: the Tables' huge pages.** The Table gate, when open,
costs 10.7 MiB peak RSS on ts-pattern and is what makes RSS bimodal. Once the
heads are colored, measure main-colored against main-colored-without-Table-
huge-pages. If the Tables' huge pages no longer clear the bar, drop them:
peak RSS falls to the low mode always, and the timing loses its bimodality.
Segments keep theirs (no RSS cost, 38 MiB of ts-pattern).

**Not proposed.** `MADV_COLLAPSE` of windows as they fill: memory-neutral,
but the full windows hold only 28% (ts-pattern) and 8% (zod3) of the misses,
and a collapse costs about 0.6 ms (table-huge micro: 179 against 152 ms),
more than it saves. Huge first windows: 84-94 MiB more RSS. Fewer, larger
allocator segments: segments are already fully huge when the gate allows.
Per-Table size hints that advise only windows a Table will fill: memory-
neutral in principle, but the misses are not in those windows.

**How to prove it.** Plain separate builds, no runtime switch: Rig main and
Rig main plus the coloring patch (and later minus the Table huge advice),
Trig release built with each, time-ab.sh on pup P-cores (60 rounds on the
25 ms projects, A/A arm, binaries on tmpfs), plus this report's E-core
counters (`pstat.sh`) and STLB-miss attribution (`memcls2.py`,
`setconf.py`): page-0 share should fall from 65% to under 5%, walks by about
two thirds, peak RSS identical. Runs on a fragmented machine and a quiet one
should both gain, since nothing in it depends on free blocks.

## 5. Is a machine fix part of it?

No. Compaction before timing opens the gates every run and so removes the
bimodality from measurements, which is worth doing for honest A/B timing
(log free order-9 blocks with each run), but users' machines are fragmented
and the program must win there. Coloring does not depend on free memory at
all; it is the part that wins everywhere. tsrs, by contrast, asks for huge
pages with no gate and compacts in the fault when it must.

## Other findings

- `trig-pup/full/LATEST` (22:05): Trig's release build timed out in the full
  suite (`0build.trig-release: timed out`), so the suite ran RED.
- `/tmp/uc/m` was built by a Rig before 7448a7da6 (it maps each Table alone);
  use `/tmp/cm/main` or newer to measure main.
- The binary's first rodata page (0x1000000, 16 MiB aligned) is hot and also
  sits in set 0; it should stop missing once the Table heads leave that set.
- The perf sample rate on pup is capped at 1000 a second
  (`perf_event_max_sample_rate`), so attribution needs several runs.
- On pup, zsh does not split `$VAR` in ssh one-liners; scripts here run
  under `sh`.

## The coloring arm, built and counted (2026-11-02)

Rig e10087dd8 with `reserveTable` starting Table k at ((k * 37) mod 512)
pages into its range (worktree `~/Data/Code/worktrees/rig/table-color`,
uncommitted; diff in `huge-pages-data/table-color.diff`). Trig 07e4447
release `--pgo`, built on pup E-cores: main trained as `tools/trig/pgo` does;
color by main's profile (2 changed functions unprofiled). Binaries in pup
`/tmp/color/{main,color,aa}`; aa is cmp-identical to main. Output identical
on all six projects at 1 and 4 checkers. alloc.zig's 25 unit tests pass on
Linux; the release Table cases of `table.rig.test` pass there by hand.

E-cores, median of 3, memory fragmented (2 free 2 MiB blocks, no huge pages
in any run):

| run | walks main / aa / color | walk stall | user cycles color vs main | peak RSS main / color KB |
|---|---|---|---|---|
| ts-pattern 1 | 6.68M / 6.62M / 1.29M (81% fewer) | 199.5M to 58.0M | 2.9% fewer | 231,220 / 231,216 |
| ts-pattern 4 | 6.48M / 6.41M / 0.97M (85% fewer) | 214.7M to 55.8M | 2.2% fewer | 261-262 MB both |
| zod3 1 | 0.75M / 0.75M / 0.14M (81% fewer) | 22.9M to 6.6M | 2.1% fewer | 74,356 / 74,352 |
| zod3 4 | 1.18M / 1.16M / 0.28M (76% fewer) | 43.4M to 13.6M | 4.6% fewer | 107-109 MB both |

Page 0 share of STLB misses: ts-pattern 80.1% to 40.6%, zod3 73.6% to 17.8%.
The Tables' page-0 misses are gone; what remains on page 0 is unattributed
(no mapping event, page size N/A: likely large blocks, which the kernel
places on 2 MiB boundaries and `mremap` grows) and segment headers (4 MiB
aligned, small pages while the segment gate is shut). Those are the next
candidates for the same treatment.

## P-core timing of the coloring arm (2026-11-02, 04:26-04:36)

`time-ab.sh` with `/zfs/trig-pup/tc/color.conf` (arms main m, A/A copy a,
color c; one checker on core 6, four on 0,6,8,10; shuffled rounds with
warm-up): 60 rounds on mitt, neverthrow, superstruct; 20 on tiny-invariant,
ts-pattern, zod3. Every output the same. All 1,440 runs had the Table gate
shut (1 free 2 MiB block): no huge pages in any run. "c vs m+a" is the median
over rounds of color's ratio to the mean of main and aa in the same round;
"faster" counts the rounds color beat that mean; A/A is main against aa by
their medians. Cycles are user plus kernel. Raw: `huge-pages-data/
color-small.txt`, `color-large.txt`; summary `color-timing-summary.txt`.

| project | checkers | wall ms m / a / c | wall, c vs m+a | rounds faster | A/A wall | cycles, c vs m+a | rounds fewer | A/A cycles | peak RSS MiB m / a / c |
|---|---:|---|---|---:|---:|---|---:|---:|---|
| mitt | 1 | 18.18 / 18.14 / 18.29 | 0.3% slower | 29/60 | 0.2% | 0.6% slower | 22/60 | 1.0% | 32.7 / 32.7 / 32.7 |
| mitt | 4 | 21.49 / 21.43 / 21.59 | 0.3% slower | 27/60 | 0.3% | 0.1% fewer | 31/60 | 0.6% | 38.1 / 38.2 / 38.2 |
| neverthrow | 1 | 20.30 / 20.23 / 20.36 | 0.3% slower | 28/60 | 0.3% | 0.4% more | 25/60 | 0.7% | 31.5 / 31.5 / 31.5 |
| neverthrow | 4 | 22.89 / 22.71 / 22.86 | 0.1% faster | 31/60 | 0.8% | level | 30/60 | 0.1% | 37.6 / 37.9 / 37.8 |
| superstruct | 1 | 27.48 / 27.29 / 27.28 | 0.2% faster | 32/60 | 0.7% | 0.2% more | 25/60 | 0.8% | 24.3 / 24.3 / 24.3 |
| superstruct | 4 | 19.04 / 18.81 / 18.87 | 0.1% faster | 31/60 | 1.2% | 0.1% more | 30/60 | 0.1% | 30.1 / 29.9 / 29.9 |
| tiny-invariant | 1 | 61.08 / 60.52 / 60.73 | 0.3% faster | 11/20 | 0.9% | 0.5% fewer | 11/20 | 0.6% | 47.7 / 47.7 / 47.7 |
| tiny-invariant | 4 | 65.05 / 64.60 / 64.55 | 0.8% faster | 13/20 | 0.7% | 0.3% fewer | 13/20 | 0.1% | 54.3 / 54.0 / 53.3 |
| ts-pattern | 1 | 740.82 / 736.39 / 740.07 | 0.4% slower | 8/20 | 0.6% | 0.5% more | 9/20 | 0.6% | 225.8 / 225.8 / 225.8 |
| ts-pattern | 4 | 302.86 / 301.72 / 303.51 | level | 11/20 | 0.4% | 0.2% fewer | 11/20 | 0.1% | 255.2 / 255.4 / 255.4 |
| zod3 | 1 | 140.47 / 138.45 / 139.23 | level | 10/20 | 1.4% | 0.3% more | 6/20 | 1.0% | 72.6 / 72.6 / 72.6 |
| zod3 | 4 | 84.21 / 84.10 / 83.89 | 0.2% faster | 11/20 | 0.1% | 0.3% fewer | 13/20 | 0.7% | 105.5 / 105.4 / 105.2 |

**On P-cores the coloring is level.** Every row is within its A/A spread,
and none clears the speed bar. Peak RSS is the same. The E-cores' 81-85%
fewer walks and 2.1-4.6% fewer user cycles do not carry over to the P-cores.
This timing did not count P-core walks (time-ab.sh records no dTLB
counters), so whether the P-core STLB sees the aliasing at all is not yet
known. Its organisation differs from the E-core's (set count, indexing, page-walk
caches), and the earlier "3.3x tsrs's walks" on P-cores may come from
something else. The next measurement, in a later P-core slot: `pstat.sh`'s
counters for main and color on core 6, with
`cpu_core/dtlb_load_misses.walk_completed/` and `walk_active`, and the
STLB-miss attribution with `cpu_core/mem_inst_retired.stlb_miss_loads/pp`.

## Verdict

Not taken (2026-11-02): level on P-cores, the race's cores, so under the speed bar. The aliasing is an E-core effect. The panels of 2026-11-05 checked it again and agree ([panels/table-arena/critic.md](../../2026-11/panels/table-arena/critic.md)). The diff is kept as `table-color.diff` beside this record.
