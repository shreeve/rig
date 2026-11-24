# Rig allocator: growth copies, in-place growth, mremap, in-place shrink (2026-11-23)

Measured first, nothing landed. Rig base 383a1b2b5 (Trig's pin). Trig faeb512b, read only: arm sources are copies.
Mac: Apple M-series, 16 KiB pages. pup: Meteor Lake E-cores (Crestmont), 4 KiB pages.

## Result in one paragraph

This is a negative result for the allocator. The copies are real (24-151 MiB a run), but removing them saves no cycles.
**(a) Growing in place into fresh pages has nothing to grow into.** For every copying span remap, the span after it
is already handed out. At most 0.3 MiB of 24-151 MiB could have grown in place.
**(b) mremap** removes the copy and 4-5% of RFO L3 misses, and cuts store-buffer stalls by 12%. In exchange it nearly
doubles page faults (82-91% more), and costs 0.8-1.2% more instructions and 1.1-2.3% more cycles (user plus kernel):
a loss.
**(c) In-place shrink** is cheap and clean, and is cycle-neutral. It is a memory tool, not a speed one. It lets Trig
drop the parser's fitted copy at 0-1.5% more peak RSS than today, where dropping the copy without it costs 4.5-6.3% more
on the Mac.

## 1. Census (counter-patched Rig: patches/rig-census.patch)

Every `remap` is classified by the path it takes, with the bytes it copies (the caller's copy is counted when remap
returns null), a size histogram, and the caller (its return address, symbolized with inlined frames by `atos -i`).
The census was run on the Mac through tools/heavy. Counts are deterministic: two builds gave identical numbers.
Tables: data/census-tables.md (paths, histograms, top 25 callers for each run), data/census-cross.md, data/clones.txt.

| run | remaps | MiB copied | small→small (caller copies) | small→large | span copied into a warm span | span copied into a new block | could grow in place into fresh pages | span copies ≥64 KiB | ≥256 KiB | ≥1 MiB |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Compiler c1 | 22159 | 23.7 | 6.4 | 1.9 | 7.4 | 8.1 | 0.0 | 15.0 | 10.6 | 5.0 |
| Compiler c4 | 32129 | 28.9 | 9.7 | 2.7 | 6.1 | 10.5 | 0.0 | 15.5 | 9.3 | 5.0 |
| nuxt c1 | 296883 | 106.1 | 49.0 | 4.0 | 14.0 | 38.9 | 0.3 | 50.5 | 40.7 | 21.4 |
| nuxt c4 | 466426 | 150.6 | 71.4 | 7.5 | 16.5 | 55.1 | 0.1 | 67.2 | 43.8 | 12.6 |
| typeorm c1 | 179318 | 81.8 | 31.0 | 3.2 | 19.1 | 28.5 | 0.0 | 45.3 | 35.5 | 25.6 |
| typeorm c4 | 211156 | 87.3 | 38.6 | 6.0 | 13.8 | 28.9 | 0.0 | 38.4 | 24.4 | 12.1 |
| webpack c1 | 283460 | 108.9 | 44.4 | 5.6 | 19.5 | 39.4 | 0.0 | 56.1 | 42.1 | 17.7 |
| webpack c4 | 384718 | 143.4 | 58.7 | 9.3 | 17.0 | 58.4 | 0.2 | 70.7 | 47.1 | 13.2 |

(MiB columns. "≥64 KiB" means the old block was at least 16 Linux pages, 64 at 256 KiB, 256 at 1 MiB.)

- **Grew in place**, warm or fresh: 14-45 calls a run, no bytes. **Mappings** (≥16 MiB): no remap reached one on these
  projects, so "mapping moved" and "mapping copied into a kept block" are 0. **Shrinks of a large block**: none. Trig
  never shrinks a span through realloc today.
- **Copied into a new block**: 98% of the bytes are a span carved fresh at the end of its segment (`src carve`).
  The rest are cold spans. The old span then goes to the warm free list.
- **Small→small** (both sizes ≤32 KiB, one class per page) is 27-47% of the bytes. remap cannot help there:
  `reallocSlice` copies. That is `ListOf(Node).growBy` (117k calls on webpack), `Ordered(u32,u32)`, and
  `ListOf(SymbolRec)`.
- **Top callers by bytes copied** (webpack c1): `ListOf(ast.Node).growBy` 11.6 MiB, `Ordered(CacheKey,TypeList).reserveOne`
  8.6, `ListOf(SymbolRec)` from `Binder.new_symbol` 6.7, `String.growList` from `addValue` 4.9 and 3.8,
  `ListOf(ParseTask)` from `FileLoader.new_task` 4.2 (4 calls, all copies into new blocks), `ListOf(i64)` 4.1,
  `Ordered(u32,u32)` 3.3, `ListOf(InferenceContext)` 1.8. These match the LBR study.
- **mremap eligibility.** On Linux every span starts on a page (span_unit = page = 4 KiB), and 90-97% of span-copy bytes
  are blocks of 16 pages or more. On the Mac (16 KiB pages, 4 KiB units) only a quarter to a third of those bytes start
  on a page (the `aligned` columns in data/census-tables.md), so a Mac movePages for spans would reach far fewer.
- **Following span free?** (the `follow` columns): for copying remaps, the span right after holds a free span long
  enough, or ends at the segment's uncarved end, for 0-0.3 MiB a run. Spans are carved densely, and a growing List is
  almost never the last span of its segment once anything else is allocated. So (a) has no payoff, and its pup build
  was cancelled.

## 2. The arms (Rig patches in patches/; one arm each, no tuning, per the scope cap)

- **M (b)**, patches/rig-b.patch (also carries (a)'s reordering, which the census shows never fires): a span of 16 pages
  or more that cannot grow where it lies is moved into a cold span or a fresh carved one (a warm one last) by
  `mremap(MREMAP_MAYMOVE|MREMAP_FIXED|MREMAP_DONTUNMAP)`. The old range stays mapped and reads zero, as a span segment
  must stay mapped. About 40 lines. Spans live inside the region's one 64 GiB reservation. mremap of a sub-range works
  (Linux splits the VMA), so spans need no mapping of their own. Each move splits the VMA, and the moved piece cannot
  merge back (its pgoff is the old address's). webpack c1 made 184 mremaps (strace). vm.max_map_count on pup is 1 M.
- **F (c)**, patches/rig-c.patch: `shrinkSpan` (15 lines: the tail is handed out on its own, then freed as any span,
  joining its neighbours warm or cold). remap shrinks a span in place when it stays large (>32 KiB): free goes by
  length, so a block cut to a small size must copy. Plus a scratch `List.fit` (resolve.zig method, runtime
  `ListOf.fit` = `reallocSlice(len)`). Trig copy, patches/trig-fit.patch: `parse_source_file_into` fits the file's
  lists in place and gives the scratch a new Ast (no `take_fitted`, no copy for lists that stay spans).
- **N** (memory reference only): the same copy-free tree without fit (patches/trig-nofit.patch), on rig-c.

Built on burst: UNITS=1, meteorlake, stripped. Base on Rig 383a1b2b5; M, F and N
with TRIG_RIG_OVERRIDE. Timed on pup E-core 18 (c1) under flock ecores.lock. The harness waited for "no slot open"
before each project of each round. B1 and B2 are the same base binary (the A/A arm). 12 rounds, rotating order,
medians, perf stat counting user plus kernel (no multiplexing), /usr/bin/time. stdout is byte-identical across all arms
on every project. Full table: data/pup-c1.txt.
c4 was not run: the scope cap said to stop once cycles came back within 1% or worse.

### pup E-core, c1 (median of 12; each arm compared with B1; Compiler / webpack / nuxt / typeorm)

| | A/A (B2) | M: mremap (b) | F: copy-free + in-place shrink (c) |
|---|---|---|---|
| cycles (user+kernel) | 0.3% / 0.7% / 1.0% / 1.0% fewer | 2.3% / 1.4% / 1.1% / 1.7% more | 0.9% / 0.8% / 0.4% fewer, level |
| user cycles | 0.1% more, then 0.5% / 1.0% / 0.6% fewer | 0.8% / 0.4% more, 0.2% fewer, level | 0.7% / 0.8% / 1.0% fewer, 0.4% more |
| instructions | level | 1.2% / 0.8% / 0.8% / 0.9% more | level, then 0.2% / 0.5% / 0.6% more |
| wall | 0.9% slower, then 0.5% / 1.3% / 0.7% faster | 3.0% / 2.1% / 0.3% / 1.4% slower | level, level, 1.2% faster, level |
| page faults | level | **91% / 86% / 84% / 82% more** | level |
| sys time | noise | 19-33% more | noise |
| ocr.demand_rfo.l3_miss | 0.7% / 0.5% fewer, 0.3% more, 0.3% fewer | 3.7% / 5.1% / 4.9% / 5.1% fewer | 6.6% / 1.3% / 2.1% / 1.6% fewer |
| mem_scheduler_block.st_buf (store buffer) | 1.1% more, then 2.9% / 2.4% / 3.8% fewer | 4.3% / 12.7% / 12.1% / 12.0% fewer | 6.7% / 11.0% / 7.9% / 7.9% fewer |
| mem_bound_stalls_load.llc_miss | 2.5% / 1.1% / 3.7% / 1.0% fewer | 3.5% / 2.1% more, 1.0% fewer, 1.1% more | 0.7% / 0.9% / 3.6% fewer, 2.6% more |
| longest_lat_cache.miss | 1.5% / 0.5% / 2.3% / 0.1% fewer | 2.5% / 5.5% / 3.6% / 8.3% fewer | 2.6% / 1.0% / 0.6% fewer, 0.8% more |
| peak RSS | level | 2.5% higher, then 1.2% / 2.2% / 3.8% lower | 0.3% lower, 1.0% / 1.5% higher, level |

E-core names for the asked counters: `cycle_activity.stalls_l2_miss` corresponds to
`mem_bound_stalls_load.llc_hit + .llc_miss` (both are L2 misses; llc_hit moved 2-4% either way and is in
data/pup-c1.txt), `resource_stalls.sb` to `mem_scheduler_block.st_buf`, and `ocr.demand_rfo.l3_miss` exists as is.
memcpy's share of sampled misses was not re-recorded (perf mem): the counters already show the store-side relief and
the cycle cost.

**Reading.** Copying hurts in the store path: removing it gives 4-5% fewer RFO L3 misses and 12% fewer store-buffer
stalls, which is Trig's signature. But the copy's destination is mostly a freshly carved span (98% of the bytes), whose
pages fault anyway. And the old span, freed warm after a copy, is resident and reused by the next allocations. With
DONTUNMAP the old range is empty, so the next use of those addresses faults again: twice the faults. The kernel work
(faults, mremap, the split VMAs) costs more than the copy. User cycles stay level, and total cycles are 1.1-2.3% more.
An mremap without DONTUNMAP plus an mmap to refill the hole would fault the same way. A variant that kept the old
range's pages (moving into a span and leaving the old one warm) would be a copy again. So (b) in this allocator is a
loss on Trig, and the loss comes from its own design, not from tuning.

**F**, the copy-free tree with in-place shrink, has cycles within the A/A noise (0.0-0.9% fewer, against the A/A's
0.3-1.0%), RFO L3 misses 1-7% fewer, and store-buffer stalls 7-11% fewer. That matches Trig's own reading: the store
misses move to the first writes, and cycles do not move.

## 3. In-place shrink and the fitted copy (task item from Trig)

- **Today alloc.zig cannot give a span's tail back.** `resize` succeeds only when `largeSize` is unchanged, and `remap`
  returns null for any shrink (`new_len < memory.len`). The caller (`reallocSlice`, `String.fit`) copies into a new
  block. No List method shrinks; `+v` clones exactly. The span code has every piece needed (`handOutSpan`, `freeSpan`,
  `putSpan`): `shrinkSpan` is the inverse of `growSpan`, 15 lines under the spans lock. One rule: a span may shrink
  only to a large size, because free classifies a block by its length. Shrinking a mapping (≥16 MiB) would need
  munmap of its tail and the kept-block bookkeeping; no Trig block is that large.
- **How often Trig would shrink.** Clone census at `Ast.take_fitted` (data/clones.txt): per run, 320 (Compiler)
  to 29k (nuxt) list clones, copying 15-84 MiB. Of those, the clones whose live part is itself a span (shrinkable in
  place, no copy) are 81-449 a run, but they carry most of the bytes: 13.4 of 15.1 MiB (Compiler), 52.6 of 79.8
  (webpack), 43.4 of 83.9 (nuxt), 15.3 of 47.3 (typeorm). The rest are small lists whose room was a span: cutting them
  to a small class still copies, a few KiB each.
- **Peak memory** (Mac, /usr/bin/time -l, 3 runs, identical each time; data/mac-rss.txt): today's fitted copy: webpack 375
  MiB, nuxt 383, typeorm 247, Compiler 66. Copy-free without fit: 395 / 407 / 260 / 69, so 5.3% / 6.3% / 5.3% / 4.5%
  more. Copy-free with in-place fit: 378 / 385 / 248 / 66, so 0.8% / 0.5% / 0.4% / 0% more. **In-place shrink recovers
  85-100% of the memory the copy-free tree costs.** On pup, F against base: 1.0% / 1.5% higher on webpack and nuxt,
  level on typeorm and Compiler. Trig measured copy-free without fit at 19-20% more *heap* at c1; RSS includes the type
  store and Tables, so its share is smaller.
- Instructions: F 0.0-0.6% more on pup (each file's fresh arena regrows from `reserve_for_text`'s estimate), and level
  on the Mac.

## 4. Risks

- **Fragmentation and RSS.** (b): RSS 1-4% lower, since the old span's pages are dropped, but VMAs split once per move
  and twice the faults. (c): the tail joins the free spans where it lies. Warm or cold follows `freeSpan`'s bound,
  so fragmentation is no worse than a free.
- **Huge pages.** Span segments ask for huge pages (`ask(.huge)` in carveSpan; mode madvise on pup). An mremap of a
  4 KiB-aligned piece of a THP-backed segment splits that 2 MiB page at both ends. Part of M's extra kernel time is
  likely that (AnonHugePages not measured). Rig 2's knob is on branch `thp-size`, `scratch/thp-size` on GitHub
  (ce8f7f9ac `alloc: RIG_HUGE_MIN_MB sets the size from which a Table, segment or large block asks for huge pages`,
  plus two census commits), not on main. A higher threshold would make segments ask later and split less, but not
  change the fault doubling. In-place shrink does not touch page tables.
- **Views into a moved block.** Safe code cannot hold a view across a growth, and the ownership checker guarantees it:
  `!v.push(..)` needs a write view of `v`, which is rejected while any read view of `v` or into its elements is still
  in use (CORE.md's opening example and §1: "cannot change `v` while a read view of it is still in use"). The runtime
  checks nothing in release builds. Moving pages instead of copying changes nothing for safe code: both invalidate the
  old address. For raw code holding a stale pointer, the old range reads zeros after a DONTUNMAP move instead of stale
  bytes or someone else's data (undefined behaviour either way). A shrink in place keeps the address, so a view into
  the kept part would be fine, but `fit` is a write method, so the checker already excludes views across it.
- **Fit to alloc.zig.** (c) fits cleanly: one function beside growSpan, one branch in remap. A `List.fit` (or a name the
  owner picks) is a language or std addition with its own naming and docs round, and is the only way a program reaches
  it. `String.fit` would start using it at once. (b) fits mechanically but loses, so it should not be built. (a) is
  three reordered lines that never fire on Trig.

## 5. Recommendation

1. Do not build (a) or (b). File both as measured negatives. The growth copies cost Trig no measurable cycles once
   their store misses are counted against the faults any alternative takes.
2. If Trig wants its parser's fitted copy gone for memory or simplicity (not speed), in-place shrink of spans is the
   piece that makes it free: cycle-neutral, 0-1.5% more peak RSS than the copy, against 4.5-6.3% more without it.
   It needs a List method (naming is the owner's) and the 15-line `shrinkSpan`. It is a separate, small Rig change.
3. Small→small copies (27-47% of the bytes) are outside remap. No change proposed. Trig's reserve experiment already
   showed that pre-sizing is noise.

## Files

- patches/: rig-census, rig-a, rig-b, rig-c (against Rig 383a1b2b5); trig-fit, trig-nofit (against Trig faeb512b).
  rig-c.patch holds the 15-line `shrinkSpan` and the scratch `List.fit`, kept for the day Trig's AST layout wants a
  copy-free exact tree.
- data/: census-tables.md (the census by path, size and caller), census-cross.md, clones.txt (the clone census at
  `take_fitted`), pup-c1.txt (the pup A/B, every counter), mac-rss.txt (peak memory on the Mac). N was not timed on
  pup: its batch waited behind board slot 738 and was cancelled; the Mac numbers answer the memory question.

## Decisions (2026-11-23)

Rig, the foreman, on the owner's authority: (a) and (b) are filed as measured negatives and not built. In-place shrink
and a List method are parked: the copy-free tree with shrink saves 0-0.9% of cycles (noise) and no memory over today's
fitted copy, so there is nothing to win yet. `shrinkSpan` stays in rig-c.patch for Trig's AST layout decision.
