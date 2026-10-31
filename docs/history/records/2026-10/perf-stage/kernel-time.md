# The kernel time Rig's runtime causes in Trig (2026-10-31)

[tsrs-standing-4.md](../hash-race/tsrs-standing-4.md) charged Rig's
allocator with most of Trig's kernel-time gap to tsrs at one checker.
On ts-pattern, `madvise` took 20 ms of 72 ms of kernel time, in 258 calls
on zod3 against tsrs's 18, and `munmap` and `mremap` took 7 ms. This
record asks which call site and policy each of those calls comes from,
whether the pages faulted in ahead are ever touched, and what a change
to the allocator could save. It changes no code: no change to the
allocator's policies is worth timing. Scripts, traces summarized, and
counts are in [kernel-time-data/](kernel-time-data/).

## Method

- **Builds** (pup; [build.sh](kernel-time-data/build.sh)): Rig main
  `6c150dfa8`, and a prototype of it ([proto.patch](kernel-time-data/proto.patch),
  never merged) whose `alloc.zig` and `table.zig` put an invalid
  `madvise` (advice `0x7700` plus the site) just before each kernel call,
  naming its site. The prototype also turns policies off by `RIG_KT`: `s`
  no segment prefault, `l` no prefault of a new large block, `g` none of
  a growth, `S` a new segment's whole 4 MiB at once, `t` the tags. Trig
  `2ba0719` built by each: main by standing-4's PGO recipe, the
  prototype by `rig build --release`.
- **Attribution** ([trace.bt](kernel-time-data/trace.bt),
  [attr.py](kernel-time-data/attr.py)): bpftrace records every `mmap`,
  `munmap`, `mremap` and `madvise` with its arguments, result and time in
  the kernel, and every user page fault's address, in order, for one run
  on E-core 14. Each call goes to the site of the tag before it, and each
  fault to the mapping it falls in.
- **Pages never touched** ([where.py](kernel-time-data/where.py)): with
  every prefault off but still tagged (`RIG_KT=tslg`), each page a
  prefault would have taken counts as touched if it faults before it is
  unmapped or the program ends. Ranges moved by `mremap` move their
  pages with them.
- **Counts** ([counts.sh](kernel-time-data/counts.sh)): 7 interleaved
  runs per switch on E-core 15, with user and kernel cycles, faults and
  peak RSS. These are arms of one binary, so they show where the costs
  lie and are not timings.
- The traced times are on an E-core and include the tags' own calls.
  Their shares count; their milliseconds do not compare with
  standing-4's P-core times.

## Where the calls come from

[attr-ts-pattern.t.txt](kernel-time-data/attr-ts-pattern.t.txt) and
[attr-zod3.t.txt](kernel-time-data/attr-zod3.t.txt) show main's policies.
The huge-page gate was shut, as in every standing-4 run, so no call
asked for huge pages.

| site | ts-pattern calls | MiB | share of time in these calls | zod3 calls | MiB | share |
|---|---:|---:|---:|---:|---:|---:|
| growth prefault (half the gain) | 98 | 28.8 | 24% | 70 | 8.1 | 19% |
| table teardown `munmap` (43 tables, at exit) | 43 | (reserved) | 22% | 43 | | 17% |
| segment prefault, next 1 MiB | 28 | 28.0 | 20% | 11 | 11.0 | 21% |
| new large block prefault (3/4) | 101 | 17.1 | 16% | 81 | 8.5 | 20% |
| new segment prefault, first 1 MiB | 10 | 10.0 | 10% | 5 | 5.0 | 10% |
| growth `mremap` | 116 | +60.5 | 5.5% | 88 | +19.2 | 7.7% |
| large block `mmap` | 112 | 39.6 | 1.6% | 92 | 12.3 | 2.8% |
| `keepPiece` remnant `munmap` | 16 | 0.2 | 0.6% | 16 | 0.2 | 1.4% |
| table reserve (`mmap` and `NOHUGEPAGE`) | 86 | | 0.3% | 86 | | 0.7% |
| `trimKept`, `freeLarge` over `keepBound` | **0** | | | **0** | | |

- **Prefault is all of `madvise`'s time:** 237 `MADV_POPULATE_WRITE`
  calls on ts-pattern populate 84 MiB, and 167 on zod3 populate 33 MiB.
  The call count does not matter. Each call costs a few microseconds,
  and the time goes to the pages: about 0.93 µs a page on ts-pattern
  (standing-4's 20 ms over 21,500 pages), against about 1.0 µs for a
  fault. The 5,000-5,600 kernel cycles of a fresh page are spent either
  way, and populating saves only the trap
  ([fault-ahead/kernel.md](fault-ahead/kernel.md)).
- **No page is given back during a run.** `trimKept` and `freeLarge`
  never unmap on either project, so `keepBound` never binds. The only
  `munmap`s are remnants under 64 KiB and the 43 tables at the end.
- **Standing-4's `munmap` time is the tables' teardown,** all within
  the last 11 ms of a 2.17 s run. The exit would free those pages
  anyway. In [tear.c](kernel-time-data/tear.c) (43 tables, 129 MiB
  written), unmapping each table before exit took the same wall time as
  leaving them to the exit, 1.5% less in fact
  ([tear.txt](kernel-time-data/tear.txt)). But `perf stat` counted 26M
  more kernel cycles for it: the cycles the exit spends freeing pages
  are not counted. So when Trig's kernel cycles are set against those of
  tsrs, which leaves most of its memory to the exit, the comparison
  charges Trig about 6 ms on ts-pattern that is not in the wall time.
- **`mremap`** moves a growing List's pages: 116 calls on ts-pattern,
  about 20 µs each on an E-core, 5.5% of the time in these calls.

## The pages faulted in ahead and never touched

[attr-ts-pattern.tslg.txt](kernel-time-data/attr-ts-pattern.tslg.txt),
[attr-zod3.tslg.txt](kernel-time-data/attr-zod3.tslg.txt):

| prefault | ts-pattern pages | never touched | zod3 pages | never touched |
|---|---:|---:|---:|---:|
| segment, next 1 MiB | 7,168 | 381 (5.3%) | 2,816 | 426 (15.1%) |
| new segment, first 1 MiB | 2,560 | 294 (11.5%) | 1,280 | 209 (16.3%) |
| new large block, first 3/4 | 4,383 | 49 (1.1%) | 2,171 | 16 (0.7%) |
| growth, half the gain | 7,360 | 574 (7.8%) | 2,068 | 341 (16.5%) |
| **all** | 21,471 | **1,298 (6.0%, 5.1 MiB)** | 8,335 | **992 (11.9%, 3.9 MiB)** |

Where the touched pages lie ([where.txt](kernel-time-data/where.txt)):

- **Segments:** of the untouched pages, 645 on ts-pattern and 524 on
  zod3 lie below the highest page touched in their segment, and 30 and
  111 beyond it. They are the unused ends of 64 KiB class pages, which
  each size class takes whole. A smaller stretch would not avoid them,
  and a prefault of each class page as it is taken would cost a call per
  64 KiB.
- **New large blocks:** the last quarter, which is not prefaulted, is
  81% touched on ts-pattern and 63% on zod3. Prefaulting the whole block
  would turn 1,213 faults into populated pages (about 850 cycles saved
  each) but take 292 pages never touched (about 5,000 each), a loss.
- **Growths:** the first half of the gain is 92% and 86% touched, and the
  second half 62% and 56%: the same trade, again a loss.

The prefault sizes in place, 1 MiB stretches, 3/4 of a new block and
half of a growth, sit near the best these numbers allow.

## What each policy is worth

From the counts by switch (medians of 7; [counts-1-summary.txt](kernel-time-data/counts-1-summary.txt)),
against main's policies (`none`):

| switch | ts-pattern kernel cycles | user + kernel | peak RSS | zod3 kernel cycles | user + kernel | peak RSS |
|---|---:|---:|---:|---:|---:|---:|
| main | 449M | 6,240M | 248.4 MB | 129M | 1,172M | 78.9 MB |
| no prefault (`slg`) | 492M (+9.6%) | +0.4% | 243.2 (-2.1%) | 134M (+3.9%) | +0.7% | 75.1 (-4.8%) |
| no segment prefault (`s`) | 473M | +0.8% | 245.6 (-1.1%) | 133M | +0.3% | 76.5 (-3.0%) |
| no growth prefault (`g`) | 470M | +0.1% | 246.1 | 131M | +0.5% | 77.5 (-1.8%) |
| no new-block prefault (`l`) | 459M | +0.7% | 248.2 | 129M | +0.1% | 78.9 |
| whole segment at once (`S`) | 455M | -0.6% | 248.7 | 129M | -0.4% | 81.3 (+3.0%) |

With every prefault off, Trig takes 50% (ts-pattern) and 74% (zod3) more
traps, its kernel cycles rise 4-10%, and its total cycles rise
0.4-0.7%. That is the whole worth of faulting in ahead today, and the
RSS it costs is the untouched pages above. No switch makes Trig faster
without raising its peak memory. Turning off segment prefault would
trade about 0.3-0.8% more cycles for 3% less peak memory on zod3: a
trade, not a win. These are arms of one binary, so their sub-1% cycle
differences are within what such arms have overstated before.

## Where Trig's kernel time goes

User page faults by the mapping they fall in, main's policies:

| mapping | ts-pattern | zod3 |
|---|---:|---:|
| reserved Tables (`table.zig`) | **32,476 (77%)** | **6,442 (66%)** |
| large blocks | 6,716 | 2,448 |
| segments | 526 | 546 |
| the binary's text and read-only data (a freshly copied file) | 2,486 | 262 |
| other | 56 | 56 |

Trig touches each page about once: its fresh pages, about 61,000 of 4
KiB on ts-pattern (40,000 faulted, 21,500 populated), come to about its
peak RSS. Its kernel time is therefore its footprint times the cost of
a 4 KiB page. Most of that footprint is Table memory, which takes huge
pages only while the gate is open, and the gate was shut on pup at 5-69
free 2 MiB blocks. What remains open:

1. **Huge pages for Tables while memory is fragmented**: 127 MiB of
   ts-pattern's faults. The gate exists because compaction in the fault
   made Trig 34-70% slower ([thp-fragmented.md](thp-fragmented.md),
   [thp-spare.md](thp-spare.md)). A way to take free 2 MiB blocks without
   ever compacting would close most of the rest of the kernel gap.
   This record found no `madvise` mode that does so under `defrag=madvise`.
2. **Trig's footprint** (Trig's data, its Tables' sizes): fewer pages,
   at the same cost a page.
3. **The comparison itself:** Trig's 43 Tables are unmapped as the
   program ends, which `perf stat` counts and the exit would not. tsrs
   leaves its memory to the exit. Standing-4's kernel-cycle gap
   overstates the wall-time gap by that teardown, about 6 ms on
   ts-pattern.

## For row 21 (returns past a bound)

- On Trig at one checker `keepBound` never binds: no large block is
  given back during a run. Returning idle pages past a bound
  (`MADV_FREE` or `MADV_DONTNEED`) leaves Trig's hot path alone as long
  as the bound is no tighter than `keepBound`. A tighter bound would
  turn kept blocks into pages faulted in again at about 5,000 cycles
  each.
- Build on the prefault sizes as they are (1 MiB segment stretches, 3/4
  of a new large block, half of a growth). The data puts them near the
  best, and a block taken from those kept is not prefaulted, which is
  right: its pages are resident.
- Any return must not land on a block's prefaulted range before the
  program writes it. Populated pages that are freed and faulted again
  cost twice.

## Recommendation

No change to `alloc.zig` for kernel time. The `madvise` time is the
pages' own cost, paid sooner and slightly cheaper. The `munmap` time is
the exit's work done earlier. The rest is page size and Trig's
footprint. Neither bench/hash's 4M-key rows nor std.json is touched,
since nothing changes.
