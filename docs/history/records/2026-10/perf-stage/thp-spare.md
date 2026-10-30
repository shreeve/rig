# The huge-page gate's spare, measured (2026-10-29)

**Question.** The huge-page gate ([thp-gate.md](thp-gate.md)) asks
Linux for huge pages only while `/proc/buddyinfo` shows more than
`huge_spare` free 2 MiB blocks, and `huge_spare` was 128.
[tsrs-standing-3.md](../hash-race/tsrs-standing-3.md) found pup idling
at 88 to 139 free blocks, around 128: the gate shut in 36 of 40
ts-pattern runs, and Rig main ran 4.1% slower by the median than
`773978d1d`, which asks always and did not stall at that level. A run's
own huge pages drain the count, so a run that starts just above 128
gets huge pages only for its first requests. Which spare keeps the
quiet gain, takes huge pages at pup's idle level, and still never
stalls when memory is fragmented? Candidates: 128 (main), 64, 32, 16.

The bar, thp-gate's:
- at least as fast as main quiet and at pup's idle level;
- never slower than no huge pages when memory is partly fragmented or
  fragmented (within the 2% noise), with `compact_stall` reported;
- slower on neither project;
- peak memory no higher than main's where both ask.

**Answer.** 64 clears the bar, and 32 and 16 do not.

- **Idle level** (114-168 free blocks, median 132). 64 is 5.8% faster
  than 128 on ts-pattern and 1.9% on zod3, and 7.0% and 4.5% faster
  than no huge pages. 128 shut for most runs (40k faults a run where
  64 takes 15k), 1.7% faster than no huge pages.
- **Quiet** (178-490 free) and **natural** (300-350 free): every
  spare asks, and 64 is within 1.4% of 128 (ts-pattern quiet 1.4%
  slower, natural 0.1% faster; zod3 0.9% faster and 0.1% slower), the
  noise of six PGO builds trained apart.
- **Partly fragmented** (frag leaving 35, runs starting at 34-67 free,
  median 46-53). 64 asks for nothing and runs as no huge pages does
  (ts-pattern 1.0% faster, zod3 1.0% slower), with no stall. At 32
  ts-pattern compacted in 17 of 20 runs and ran more than 5% slower
  than no huge pages in 8 (up to 70%, its 75th percentile 27%); at 16
  it ran 33.5% slower by the median; asking always, 57.9% slower.
- **Between** (frag leaving 55, runs starting at 7-130, median 56-72).
  64 asked in the runs above 64: one of 20, starting at 74, compacted
  (65 stalls, 25% slower than its round's no huge pages); by the median
  64 is 1.5% faster than no huge pages on ts-pattern and 1.8% on zod3.
- **Fragmented** (light, 1-33 free). 64 is within 1.0% of no huge
  pages with no stall; asking always is 96.4% slower on ts-pattern.
- **Memory.** Where 64 and 128 both ask, peak memory is the same:
  259.4 MB on ts-pattern, 84.6 MB on zod3 (128 84.5).

64 is about what one program takes for itself (Trig PGO takes 76 huge
pages on ts-pattern, 15 on zod3): a program that asks finds free blocks
for its faults rather than compacting in them. zod3, which takes 15,
would gain from asking at 35-67 free (32, 16, and always run it 2.8 to
3.1% faster than no huge pages there); 64 gives that up, which the
bar allows, to keep ts-pattern from stalling.

A spare that grows with what the process has already taken (so that a
run's own huge pages do not shut its later requests) was not measured:
the constant clears the bar.

## Method

- **Builds.** Six clones of Rig main `277fba515` on pup, each built by
  `build.sh` and differing only in `alloc.zig` (`arms.diff`):
  `s128` (main), `s64`, `s32`, `s16` (`huge_spare`), `always`
  (`hugeFree` true, as `773978d1d` asked) and `never` (`hugeFree`
  false: no `MADV_HUGEPAGE` anywhere). Trig `2ba0719` (`git archive`)
  built by each with `--release --pgo`, trained by
  `tools/trig/bolt-train`, through `slot.sh` on release slot 10,11
  (`builds.log`). Separate binaries, never a switch in one.
- **Machine.** pup, `taskset -c 1`, sibling 2 idle (`time.sh` waits
  until nothing else runs on 1 or 2).
- **Levels** (`time.sh`, `frag.c` with a `LEAVE` argument added):
  - quiet: `unfrag 256` first;
  - normal: `unfrag 256`, then a fresh `frag` capped at 2 GiB that
    takes all but 115 free 2 MiB blocks outside DMA, held for the run
    (pup's idle level of standing-3's morning; runs started at 114-168
    as the kernel compacted after frag);
  - partly: the same leaving 55 (runs started at 7-130, median 56-72,
    above the 48-62 meant, so it is "between" above);
  - leave35: leaving 35, which made the partly fragmented level (34-67);
  - light: `frag` alone, taking every free block, as thp-gate;
  - natural: nothing done, last. pup had 14-17 free blocks before the
    timing, after other sessions' release builds; by the end, after
    the session's own `unfrag` runs, 300-350, so natural is quiet's
    twin here, not the idle level.
- **Rounds.** 20 interleaved rounds per level, arms rotated by round,
  ts-pattern then zod3 (`times.txt` 21:55-23:07, `times-leave35.txt`
  23:08-23:20). Every output matched `s128`'s reference byte for byte.

Medians; "vs" is the median of each round's wall ratio. Stalls are
`compact_stall`, the whole machine's over the run, with the runs that
had any in brackets. `summary.txt` has the 25th and 75th percentiles,
user and kernel cycles, and `thp_fault_alloc`.

| | wall | vs never | vs s128 | stalls (runs) | faults | peak RSS |
|---|---:|---:|---:|---:|---:|---:|
| **ts-pattern, quiet** (178-490 free) | | | | | | |
| s128 | 818 ms | 8.9% faster | | 0 (0) | 15060 | 259.4 MB |
| s64 | 829 ms | 8.7% faster | 1.4% slower | 0 (0) | 15060 | 259.4 MB |
| s32 | 814 ms | 8.3% faster | 0.2% faster | 0 (0) | 15059 | 263.1 MB |
| s16 | 812 ms | 10.1% faster | 1.0% faster | 0 (0) | 15059 | 263.1 MB |
| always | 819 ms | 8.0% faster | 0.4% slower | 0 (0) | 15059 | 259.5 MB |
| never | 889 ms | | 9.7% slower | 0 (0) | 40412 | 247.4 MB |
| **ts-pattern, natural** (300-343 free) | | | | | | |
| s128 | 699 ms | 5.5% faster | | 0 (0) | 15060 | 259.6 MB |
| s64 | 698 ms | 5.6% faster | 0.1% faster | 0 (0) | 15060 | 259.6 MB |
| s32 | 699 ms | 5.7% faster | 0.0% faster | 0 (0) | 15059 | 263.1 MB |
| s16 | 697 ms | 5.7% faster | 0.4% faster | 0 (0) | 15059 | 263.1 MB |
| always | 698 ms | 5.5% faster | 0.2% faster | 0 (0) | 15059 | 259.7 MB |
| never | 739 ms | | 5.8% slower | 0 (0) | 40411 | 247.6 MB |
| **ts-pattern, normal** (114-168 free, median 132) | | | | | | |
| s128 | 784 ms | 1.7% faster | | 0 (0) | 39982 | 247.9 MB |
| s64 | 747 ms | 7.0% faster | 5.8% faster | 0 (0) | 15060 | 259.6 MB |
| s32 | 745 ms | 7.0% faster | 5.7% faster | 0 (0) | 15060 | 263.1 MB |
| s16 | 753 ms | 5.9% faster | 4.9% faster | 0 (0) | 15059 | 263.1 MB |
| always | 752 ms | 5.8% faster | 4.2% faster | 0 (0) | 15059 | 259.7 MB |
| never | 795 ms | | 1.8% slower | 0 (0) | 40412 | 247.6 MB |
| **ts-pattern, between** (frag leaving 55; 7-130 free, median 56) | | | | | | |
| s128 | 792 ms | 0.1% faster | | 0 (0) | 40412 | 247.6 MB |
| s64 | 789 ms | 1.5% faster | 0.0% faster | 0 (1) | 40409 | 247.6 MB |
| s32 | 761 ms | 3.0% faster | 3.3% faster | 24 (12) | 16814 | 257.5 MB |
| s16 | 775 ms | 2.7% faster | 1.8% faster | 32 (17) | 18544 | 255.4 MB |
| always | 777 ms | 2.8% faster | 2.5% faster | 42 (18) | 18336 | 252.6 MB |
| never | 789 ms | | 0.1% slower | 0 (0) | 40411 | 247.6 MB |
| **ts-pattern, partly fragmented** (frag leaving 35; 34-67 free, median 46) | | | | | | |
| s128 | 757 ms | 0.4% faster | | 0 (0) | 40411 | 247.6 MB |
| s64 | 753 ms | 1.0% faster | 0.2% slower | 0 (0) | 40411 | 247.6 MB |
| s32 | 776 ms | 0.8% slower | 1.9% slower | 32 (17) | 19055 | 254.8 MB |
| s16 | 1026 ms | 33.5% slower | 36.9% slower | 52 (20) | 21908 | 254.0 MB |
| always | 1196 ms | 57.9% slower | 59.0% slower | 95 (20) | 24975 | 250.5 MB |
| never | 760 ms | | 0.4% slower | 0 (0) | 40411 | 247.6 MB |
| **ts-pattern, light** (1-22 free) | | | | | | |
| s128 | 756 ms | 0.3% slower | | 0 (0) | 40411 | 247.6 MB |
| s64 | 749 ms | 1.0% faster | 1.0% faster | 0 (0) | 40412 | 247.6 MB |
| s32 | 760 ms | 0.2% slower | 0.6% slower | 0 (0) | 40410 | 250.9 MB |
| s16 | 753 ms | 0.1% faster | 0.5% faster | 0 (0) | 40410 | 250.9 MB |
| always | 1466 ms | 96.4% slower | 93.9% slower | 196 (20) | 38100 | 247.9 MB |
| never | 755 ms | | 0.3% faster | 0 (0) | 40411 | 247.6 MB |
| **zod3, quiet** (433-486 free) | | | | | | |
| s128 | 154 ms | 1.4% faster | | 0 (0) | 7909 | 84.5 MB |
| s64 | 152 ms | 1.6% faster | 0.9% faster | 0 (0) | 7909 | 84.6 MB |
| s32 | 153 ms | 1.6% faster | 0.1% slower | 0 (0) | 7910 | 87.7 MB |
| s16 | 152 ms | 2.2% faster | 1.2% faster | 0 (0) | 7910 | 87.5 MB |
| always | 153 ms | 1.7% faster | 0.7% faster | 0 (0) | 7908 | 84.6 MB |
| never | 156 ms | | 1.4% slower | 0 (0) | 10055 | 77.8 MB |
| **zod3, natural** (330-350 free) | | | | | | |
| s128 | 142 ms | 2.6% faster | | 0 (0) | 7909 | 84.5 MB |
| s64 | 141 ms | 2.6% faster | 0.1% slower | 0 (0) | 7909 | 84.6 MB |
| s32 | 142 ms | 2.4% faster | 0.0% slower | 0 (0) | 7911 | 87.7 MB |
| s16 | 144 ms | 2.0% faster | 0.5% slower | 0 (0) | 7910 | 87.5 MB |
| always | 142 ms | 2.6% faster | 0.2% slower | 0 (0) | 7908 | 84.6 MB |
| never | 146 ms | | 2.7% slower | 0 (0) | 10055 | 77.8 MB |
| **zod3, normal** (80-365 free, median 126) | | | | | | |
| s128 | 158 ms | 1.8% faster | | 0 (0) | 7910 | 84.5 MB |
| s64 | 154 ms | 4.5% faster | 1.9% faster | 0 (0) | 7909 | 84.6 MB |
| s32 | 156 ms | 2.0% faster | 1.1% faster | 0 (0) | 7910 | 87.7 MB |
| s16 | 156 ms | 1.9% faster | 0.1% faster | 0 (0) | 7910 | 87.5 MB |
| always | 157 ms | 3.5% faster | 1.5% faster | 0 (0) | 7908 | 84.6 MB |
| never | 161 ms | | 1.8% slower | 0 (0) | 10056 | 77.8 MB |
| **zod3, between** (frag leaving 55; 54-107 free, median 72) | | | | | | |
| s128 | 154 ms | 1.7% slower | | 0 (0) | 10058 | 77.7 MB |
| s64 | 153 ms | 1.8% faster | 2.9% faster | 0 (0) | 7910 | 84.6 MB |
| s32 | 149 ms | 3.4% faster | 5.1% faster | 0 (0) | 7910 | 87.7 MB |
| s16 | 149 ms | 3.7% faster | 4.7% faster | 0 (0) | 7910 | 87.5 MB |
| always | 151 ms | 2.9% faster | 3.0% faster | 0 (0) | 7908 | 84.6 MB |
| never | 155 ms | | 1.7% faster | 0 (0) | 10055 | 77.8 MB |
| **zod3, partly fragmented** (frag leaving 35; 34-67 free, median 53) | | | | | | |
| s128 | 150 ms | 0.1% slower | | 0 (0) | 10058 | 77.7 MB |
| s64 | 150 ms | 1.0% slower | 1.0% slower | 0 (0) | 10059 | 77.8 MB |
| s32 | 146 ms | 2.8% faster | 3.3% faster | 0 (0) | 7910 | 87.7 MB |
| s16 | 145 ms | 3.2% faster | 2.0% faster | 0 (0) | 7910 | 87.5 MB |
| always | 144 ms | 3.1% faster | 3.7% faster | 0 (0) | 7908 | 84.6 MB |
| never | 150 ms | | 0.1% faster | 0 (0) | 10056 | 77.8 MB |
| **zod3, light** (1-33 free) | | | | | | |
| s128 | 149 ms | 0.7% slower | | 0 (0) | 10059 | 77.7 MB |
| s64 | 149 ms | 0.6% slower | 0.5% faster | 0 (0) | 10058 | 77.8 MB |
| s32 | 150 ms | 1.0% slower | 0.3% slower | 0 (0) | 10059 | 80.7 MB |
| s16 | 149 ms | 0.8% slower | 0.8% faster | 0 (0) | 10058 | 80.7 MB |
| always | 153 ms | 3.4% slower | 1.5% slower | 7 (12) | 8054 | 83.1 MB |
| never | 148 ms | | 0.7% faster | 0 (0) | 10055 | 77.8 MB |

**Two oddities.**
- The `s32` and `s16` builds hold 3.3 to 3.7 MB more at their peak
  than the others at every level, light included, where none of them
  asks for anything: a property of those two PGO builds (each arm's
  profile was trained apart and none is the same bytes), not of the
  spare.
- The level a fresh `frag` leaves rises by 10 to 20 blocks before the
  run starts, as the kernel compacts after it; frag leaving 55 made
  54-85 on most runs, and leaving 35 made 34-67.

The new test, that the gate asks with 100 free blocks (a quiet host's
idle level) and not with 55 (memory partly fragmented), failed against
128 first. `zig build test` on pup with `-Doptimize=debug`, `safe`,
and `fast` passes.
