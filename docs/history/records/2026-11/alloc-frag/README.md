# Rig allocator: small-class fragmentation in Trig, measured: class layout is not the lever (2026-11-24)

Measured first, nothing landed. Rig: Trig's pin b4d9e7247 plus the thp-size census (a83dd857d, 0175420e8, d13fdaad6),
then the per-heap census, the per-heap huge-page knob and two ceilings (patches/). Trig ffdc6801, read only. Its output
was byte-identical across every arm (md5 per project).

## Result in one paragraph

With huge pages off, Trig's heap segments on typeorm sit about 29 MB above its live heap at c1, more at c4. A per-heap
census puts almost all of it in **free small blocks inside pages still partly used**: on pup's typeorm at c1, 21.6 MB
free in 100 MB of small-class pages, only 0.9 MB of it in wholly free pages. Live blocks of mixed lifetimes are spread
over nearly every page of the busy classes, so no page can go back. Two cheap ceilings do not reach it: **(c)** a class
borrowing a free block from the class above cuts typeorm c1's peak by 0.9% for 0.24% more instructions; **(a)** 8-byte
classes across 96-160 B save nothing. At c4 every difference is inside the ±3% run-to-run spread. Only keeping
allocations of different lifetimes apart could free those pages; that is **(b)**, a long-lived arena for the checker's
lasting allocations, held under the owner's rule that no part of Rig's arena work is built without a full discussion
and his approval (2026-11-21).

## 1. The per-heap census (patches/rig-heap-census.patch)

`RIG_HEAP_RSS=1` (Linux; read once; a one-byte test when a heap, segment or worker is made and at exit) writes, at the
peak (sampled each millisecond from `getrusage`) and at exit, one key=value line per segment, per heap, per class holding
free blocks, and a totals line: taken and live bytes; each segment's resident and huge-page bytes (`PAGEMAP_SCAN`); the
free blocks on each class's lists, walked with each block checked before it is read; pages wholly free; warm and cold
span bytes; kept large blocks; `keepBound` and `spanBound` with the settled peak they come from. It reconciles:
segments = the region's scan = smaps' region, and region + Tables + other = VmRSS to the page. Method and format:
data/heap-census.md.

typeorm at c1, huge pages off, on burst (its install there may be partial; pup's below agrees): segments 161.4 MB
against 132.3 MB live. Of the 29.1 MB gap, 25.8 MB is free small blocks in partly used pages (the 112 B class alone holds
2.7 MB free across 48 pages, 88% free; 120, 128, 144 and 1280 B are alike), 1.0 MB wholly free pages, 3.9 MB warm spans
(spanBound 17 MB, not binding), 1.2 MB segment headers, 1.0 MB unused room, 0.5 MB tail. Kept large blocks hold nothing.

## 2. The ceilings (data/ceilings.md)

- **(c)** patches/rig-borrow.patch: `RIG_SMALL_BORROW=N`. A class whose lists are empty and whose page is carved out takes
  a free block of one of the N classes above (alignment 8 or less) before a new page; freed, it goes on its own length's
  list. Cost when unset: one byte test in `allocSlow`.
- **(a)** patches/rig-fine-mid.patch: classes of 136 and 152 bytes, so 96-160 B go in steps of 8 (compile-time).

pup, through the E-core guard scripts, plain release builds for Meteor Lake; c1 on one E-core, c4 on four.

| arm | typeorm c1 instructions | Compiler c1 instructions | typeorm c1 peak, huge pages off | Compiler c1 peak |
|---|---|---|---|---|
| base (census only) | 6261.49 M | 1748.95 M | 228.8 MB | 68.1 MB |
| (c) binary, unset | +0.019% | +0.003% | 228.9 | 68.1 |
| (c) N=2 | +0.24% | +0.035% | 226.8 (−0.9%) | 68.0 |
| (a) | +0.008% | +0.004% | 230.0 (+0.5%) | 68.2 |

Census at typeorm c1 (huge pages off): (c) N=2 turns 4.4 of the 21.6 MB of free blocks into live ones, net −2.1 MB of
segments; (a) moves nothing. At c4 (three runs each) (c) N=2 reads −2.7% on both projects and (a) −3.1% on typeorm and
+1.4% on Compiler, all inside the ±3% spread. Neither clears "several percent of memory at no speed cost", so neither
was taken to a P-core cycles slot. Rig's hash and json guards were not run: the Mac never went quiet enough for
`tools/mac-claim`, and the results made them moot.

## Decision

Rig: neither ceiling is taken. The free space is survivors of mixed lifetimes pinning pages across classes, which class
layout cannot reach. The lever left is lifetime separation, (b), held for the owner. The per-heap huge-page knob built
on the same branch (`RIG_HEAP_HUGE_MIN_MB`, in patches/rig-heap-census.patch) is raced separately and goes to the owner
with its own numbers. The scratch commits are kept on an archive tag.
