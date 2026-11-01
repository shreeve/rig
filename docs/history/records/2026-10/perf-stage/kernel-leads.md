# Three kernel-time leads, measured as one set of arms (2026-11-01)

Queue row 44. [kernel-time.md](kernel-time.md) and
[table-huge.md](table-huge.md) left three leads for Trig's kernel time:

1. **A large Table's first 2 MiB on a huge page.** `reserveTable`
   advises a Table's range for huge pages only past its first 2 MiB.
2. **Large blocks on huge pages from 2 MiB**, where `huge_large` is
   16 MiB.
3. **Each checker heap's first segment faulted in ahead.** At four
   checkers a checker's heap faults lazily until it has taken
   `prefault_big` (8 MiB) from the system (`faultsAhead`).

**Answer: none lands.** Each raises Trig's peak RSS wherever it acts,
outside the A/A spread, which breaks the owner's rule against trading
memory for speed:

- **Lead 1** costs about 2 MiB of RSS for each Table a checker writes.
  Peak RSS rises 27% on ts-pattern, 111% on zod3, and 186-408% on the
  small projects. It is 3.2% faster on ts-pattern and 2.8% on zod3, and
  2.5-29% slower on the small projects.
- **Lead 2** rises 0.96% (2.3 MB) on ts-pattern, in every run, and is
  level elsewhere. It is 0.8-3.6% faster with free 2 MiB blocks, only
  1.3% on ts-pattern at the quiet level and level at the open one, and
  does nothing when memory is fragmented.
- **Lead 3** rises 1.2-9.5% at one checker and 2.3-34% at four, at every
  level of free memory. It is no faster: by arithmetic its ceiling is
  under 0.1% of ts-pattern's cycles.

The three together compound the costs: at four checkers peak RSS is
117-1,304% higher, and ts-pattern took 263 compaction stalls in 20
runs. The code is kept as the tag `archive/kernel-leads` (`20c5d3ab2`,
the combined arm); each lead alone is a patch in
[kernel-leads-data/](kernel-leads-data/).

## Arms

Rig `e4ba6de3c` (origin/main; main has since gained no change to
`alloc.zig` or `table.zig`) and four arms on it, each a change to
`src/alloc.zig` alone:

| Arm | Change | Patch |
|---|---|---|
| main | none | |
| aa | a byte-identical copy of main's Trig binary (A/A) | |
| l1 | `reserveTable` advises the whole range, its first 2 MiB included, when its gate (`hugeFree`, more than 64 free blocks) is open | [l1.patch](kernel-leads-data/l1.patch) |
| l2 | `huge_large` is 2 MiB: a new block, or one grown by `mremap`, from 2 MiB is mapped aligned to 2 MiB and asks for huge pages (`adviseHuge`, its own blocks and 8 free) | [l2.patch](kernel-leads-data/l2.patch) |
| l3 | every heap faults its segments in ahead, 1 MiB at a time, its first segment included; the huge-page advice for a segment stays as main has it | [l3.patch](kernel-leads-data/l3.patch) |
| all | l1, l2 and l3 together | `archive/kernel-leads` |

Each arm is a plain build. No environment variable switches an arm.

- **Rig.** One Rig build per arm on pup, on E-cores 12-19
  ([build.sh](kernel-leads-data/build.sh), its Rig part).
- **Trig `fb60a18`** (main), with `CHECK_IDS` false as Trig's release
  builds have it, was checked and emitted by each arm's Rig on pup,
  with a stand-in `zig` that records its arguments
  ([emit.sh](kernel-leads-data/emit.sh)). The emitted packages differ
  only in `rig/alloc.zig`.
- **Compiling.** Each package was compiled on the Mac, through
  `tools/heavy`, with `rig build --release`'s own arguments (`-Osafe
  -fomit-frame-pointer -fno-stack-protector`) for pup's target
  (`x86_64-linux`, `-mcpu=meteorlake`)
  ([mk.sh](kernel-leads-data/mk.sh), [builds.txt](kernel-leads-data/builds.txt)).
  Release builds on pup were queued and stopped behind other sessions'
  builds and timing, so the compile moved to the Mac.
- **Outputs.** Every arm printed main's bytes and exit status on every
  project, in every run.

## Method

- **Harness.** [ab.sh](kernel-leads-data/ab.sh) works as
  `/zfs/trig-pup/trial/time-ab.sh` does: it waits out Trig's suite and
  its cron hours, makes a warm-up run each round, and shuffles the
  arms' order by round (seeded). It differs in three ways:
  - it counts `cpu_atom` events, as the E-cores need;
  - it runs a `PRE` command before each run (`unfrag`, below);
  - each run also records the free 2 MiB blocks outside DMA at its
    start (`/proc/buddyinfo`, as `hugeFree` counts them), whether the
    Tables' gate was open (more than 64), and the whole machine's change
    in `thp_fault_alloc` (huge pages taken) and `compact_stall` over the
    run.
- **Running.** `taskset -c CORES perf stat --no-scale`, with perf pinned
  to the program's cores. The binaries ran from `/tmp` (tmpfs), and
  peak RSS came from `/usr/bin/time %M`.
- **Cores.** One checker (`--singleThreaded`) on E-core 13; four
  (`--checkers 4`) on E-cores 14-17. Lead 3 and the combined arm ran at
  both; the others at one checker.
- **Projects.** The `empty` project is one `export {}` file with the
  default libraries.
- **Summaries.** [summ.py](kernel-leads-data/summ.py) gives medians,
  and for each arm against main the median of the per-round ratios with
  its quartiles.

Three levels of free memory:

| Level | Free 2 MiB blocks | Runs with the Table gate shut | Rounds | Arms | Raw, summary |
|---|---|---|---|---|---|
| fragmented (other sessions' release builds running) | 0-7 | all 300 | 5 | all | [times-e1.txt](kernel-leads-data/times-e1.txt), [summary-e1.txt](kernel-leads-data/summary-e1.txt) |
| open (pup with nothing else running) | 61-271 | 1 of 2,800 | 60 small, 20 ts-pattern and zod3 | all | [times-n.txt](kernel-leads-data/times-n.txt), [summary-n.txt](kernel-leads-data/summary-n.txt) |
| quiet (`unfrag 256` before each run, from table-huge-data) | 189-307 | none | 60 and 20 | main, aa, l2 | [times-q.txt](kernel-leads-data/times-q.txt), [summary-q.txt](kernel-leads-data/summary-q.txt) |

A first look at the quiet level, 3 rounds with l1, all and all4, is in
[summary-e2.txt](kernel-leads-data/summary-e2.txt). It agrees with the
open level.

No P-core slot was asked for. Peak RSS decides every arm, and on the
E-cores it is exact: the A/A copy's RSS is main's to 0.01% at one
checker and within 0.5% at four, and an arm's RSS change is the same in
every run.

## Peak RSS

Open level; the median of the per-round ratios against main (main4 for
the four-checker arms). Main's own peak is given in the first row.

| Arm | empty | mitt | neverthrow | superstruct | ts-pattern | zod3 |
|---|---:|---:|---:|---:|---:|---:|
| main | 50.6 MB | 32.8 MB | 33.4 MB | 24.4 MB | 243.5 MB | 77.1 MB |
| aa | 0.00% | 0.00% | 0.00% | 0.00% | 0.00% | 0.00% |
| l1 | 186% higher | 309% higher | 302% higher | 408% higher | 27.1% higher | 111% higher |
| l2 | 0.00% | 0.00% | 0.00% | 0.00% | **0.96% higher** | 0.00% |
| l3 | 1.97% higher | 2.92% higher | 5.83% higher | 7.96% higher | 1.15% higher | 3.72% higher |
| all | 188% higher | 312% higher | 307% higher | 416% higher | 29.3% higher | 114% higher |
| main4 | 59.6 MB | 37.4 MB | 38.5 MB | 31.2 MB | 283.7 MB | 107.5 MB |
| aa4 | 0.14% higher | 0.01% higher | 0.10% higher | 0.46% higher | 0.13% higher | 0.11% higher |
| l3, four checkers | 9.1% higher | 19.2% higher | 22.3% higher | 27.0% higher | 2.3% higher | 6.1% higher |
| all, four checkers | 674% higher | 1,044% higher | 1,050% higher | 1,304% higher | 117% higher | 353% higher |

Fragmented, l1 and l2 take no huge page and their faults and RSS are
main's exactly. l3's rises there as at the open level: 1.4-9.5% at one
checker and 2.7-34% at four (summary-e1.txt).

## Time and counts

Wall time against main, open level (E-cores; medians of per-round
ratios, quartiles in summary-n.txt):

| Arm | empty | mitt | neverthrow | superstruct | ts-pattern | zod3 |
|---|---|---|---|---|---|---|
| aa | 0.1% slower | 0.1% faster | 0.6% slower | 0.6% faster | 0.4% slower | 0.3% slower |
| l1 | 2.5% slower | 29.1% slower | 22.6% slower | 14.1% slower | 3.2% faster | 2.8% faster |
| l2 | 1.3% faster | 3.8% faster | 1.9% faster | 0.2% slower | level | 1.1% faster |
| l3 | 0.8% slower | 1.1% slower | 2.2% slower | 1.1% slower | 0.3% slower | 0.3% slower |
| all | 2.0% slower | 26.2% slower | 22.6% slower | 15.3% slower | 3.3% faster | 1.7% faster |
| aa4 | level | 0.8% faster | level | 0.1% faster | 0.5% slower | 1.0% faster |
| l3, four checkers | 1.5% slower | 4.7% slower | 5.6% slower | 6.4% slower | 0.7% faster | 0.7% faster |
| all, four checkers | 11.9% slower | 62.2% slower | 58.8% slower | 68.0% slower | 0.2% faster | 3.7% slower |

ts-pattern and zod3, open level, medians:

| Arm | wall ms | user cycles | kernel cycles | user instructions | kernel instructions | faults | huge pages | peak RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| ts-pattern main | 1,407 | 4,894M | 277M | 8,925.8M | 153.8M | 15,459 | 65 | 243.5 MB |
| l1 | 1,373 | 4,790M | 233M | 8,925.8M | 103.0M | 5,918 | 115 | 309.4 MB |
| l2 | 1,417 | 4,952M | 265M | 8,925.9M | 133.2M | 13,554 | 76 | 245.8 MB |
| l3 | 1,416 | 4,926M | 278M | 8,925.8M | 157.3M | 15,387 | 65 | 246.3 MB |
| main4 | 601 | 5,436M | 464M | 9,399.0M | 286.7M | 32,815 | 50 | 283.7 MB |
| l3, four | 595 | 5,415M | 468M | 9,399.0M | 295.2M | 30,537 | 50 | 289.8 MB |
| all, four | 601 | 5,311M | 515M | 9,398.9M | 181.8M | 8,102 | 254 | 615.0 MB |
| zod3 main | 284 | 922M | 101M | 1,568.3M | 74.7M | 7,302 | 11 | 77.1 MB |
| l1 | 276 | 893M | 104M | 1,568.3M | 52.2M | 2,652 | 61 | 162.4 MB |
| l2 | 282 | 920M | 99M | 1,568.3M | 70.7M | 6,759 | 13 | 77.1 MB |
| l3 | 285 | 922M | 105M | 1,568.3M | 78.1M | 7,250 | 11 | 80.0 MB |

Lead 2 at the quiet level, against main, with A/A beside it
(summary-q.txt):

| Project | l2 wall [25th, 75th] | aa wall [25th, 75th] | l2 user cycles | l2 kernel cycles | l2 faults | l2 peak RSS |
|---|---|---|---|---|---|---|
| empty | 0.6% faster [-4.4%, +1.7%] | 0.2% faster [-3.0%, +3.0%] | 0.7% fewer | 5.1% fewer | 12.3% fewer | level |
| mitt | 3.6% faster [-7.0%, -0.3%] | level [-4.6%, +3.1%] | 1.7% fewer | 8.0% fewer | 28.7% fewer | level |
| neverthrow | 2.9% faster [-6.8%, +0.5%] | 0.4% faster [-5.0%, +1.6%] | 0.2% fewer | 5.8% fewer | 2.0% fewer | level |
| superstruct | 1.0% faster [-4.0%, +3.8%] | 0.9% faster [-3.9%, +2.6%] | 0.3% fewer | 0.3% more | level | level |
| ts-pattern | 1.3% faster [-2.1%, +0.1%] | 0.2% faster [-0.8%, +1.2%] | 0.5% fewer | 4.9% fewer | 12.3% fewer | **0.96% higher** |
| zod3 | 0.8% faster [-1.5%, +0.2%] | 0.2% slower [-1.8%, +1.3%] | 0.2% fewer | 2.6% fewer | 7.4% fewer | level |

Compaction stalls: 263 in the combined arm's 20 four-checker
ts-pattern runs at the open level, and 2 in 3 at the quiet level. Every
other arm had none.

## Read from these

- **Lead 1 commits a huge page at each Table's first write.** A checker
  reserves 43 Tables, and most hold far less than 2 MiB. With the gate
  open each first write now takes a whole 2 MiB page: about 50 more huge
  pages for each checker (ts-pattern 115 against 65, zod3 61 against
  11), each mostly empty. That is the reason `reserve` keeps the first
  2 MiB on small pages. Where the Tables are large (ts-pattern, zod3),
  the faults fall 62-64%, giving 2.2-3.3% fewer user cycles and a 2.8-3.2%
  faster run. On the small projects the kernel's cost of zeroing those
  pages is 38-127% more kernel cycles, and a slower run. With the gate
  shut, as on a fragmented host, it does nothing. A per-Table choice
  cannot be made at `reserve`, which does not know how far a Table will
  be written. Asking as each window is first reached is table-huge's
  jit, whose hook in `push` cost 0.8% of instructions.
- **Lead 2's huge pages commit the unwritten tails of 2-16 MiB blocks.**
  A huge page backs a whole 2 MiB window. A List's block past its
  written part, the growth slack of
  [large-blocks.md](large-blocks.md), is now committed 2 MiB at a time
  wherever a window is touched. On ts-pattern that is 11 more huge
  pages, and 2.3 MB of peak RSS in every run. On the projects whose
  blocks it fills (zod3 and the small projects) RSS is level, and it
  saves up to 29% of faults and up to 9% of kernel cycles. At the quiet
  level that makes mitt 3.6% faster and neverthrow 2.9%, on E-cores where
  A/A's own quartiles span 3-8%. It changes no user instruction. Total instructions fall by
  the kernel's share: 2.0% on mitt, and 0.23% on ts-pattern. With fewer
  than 8 free blocks more than a block needs, it does nothing.
  [alloc-large/](../alloc-large/README.md) measured the same rise from
  2 MiB, which is why `huge_large` is 16 MiB.
- **Lead 3 commits pages no checker writes and saves almost nothing.**
  Every heap now commits its first 1 MiB stretch at once, and each
  stretch after it. That includes the heaps `faultsAhead` leaves lazy
  for this reason, the ones that keep to one segment. It also includes
  the unused ends of each class's 64 KiB pages
  ([kernel-time.md](kernel-time.md), "pages never touched"). Populating
  a page saves only its trap, about 850 of the 5,000-5,600 kernel cycles
  a fresh page costs ([fault-ahead/](fault-ahead/README.md)). A checker
  heap's first segment is 1,024 pages, so it saves at most about 0.9M
  cycles a checker: 3.5M at four checkers, 0.06% of ts-pattern's 5.9G
  cycles. The measured faults fell by up to 29%, but kernel instructions
  rose 2-25%, from populating pages never touched, and kernel cycles rose
  or held.
- **The combined arm adds the costs.** At four checkers, lead 1's
  advice spans four checkers' Tables, 172 reservations asked for whole.
  They drain the free blocks the gate counted at `reserve`, and later
  faults compact (263 stalls in 20 ts-pattern runs), as
  [thp-spare.md](thp-spare.md) found for a spare too small.
- **The Mac.** Lead 3's prefault is `MADV_POPULATE_WRITE`, Linux's
  alone. On macOS the arm runs main's code, so it was not timed there.
  Leads 1 and 2 are Linux huge pages.

## Not built

- **Lead 2 within what is faulted in ahead.** This would advise only
  the whole 2 MiB windows inside the range a new block or a growth
  already populates (`likelyFilled`), which commits those pages anyway,
  so RSS could not rise. Such a block is two mappings, advised and not,
  and `mremap` moves only a range within one mapping. A List that grows
  from such a block would then be copied instead of moved, which costs
  what row 43 measured `mremap` saving. Its gain is also bounded by
  lead 2's own: 0.8-3.6%, only with free blocks, and no user
  instruction. Not worth a build unless the owner wants that trade
  measured.

## Recommendation

1. **Land none of the three** (default). Each raises peak RSS where it
   acts: lead 1 by 27-408%, lead 3 by 1.2-34%, lead 2 by 0.96% on
   ts-pattern. Of the three, lead 2 alone gains time without raising
   RSS elsewhere, and only with free 2 MiB blocks.
2. Keep `archive/kernel-leads` for reference. The record's patches give
   each lead alone.
3. Trig's kernel time remains its footprint times the cost of a 4 KiB
   page ([kernel-time.md](kernel-time.md)). The levers left are Trig's
   footprint and its large blocks' slack ([large-blocks.md](large-blocks.md)),
   not where the allocator asks for huge pages.
