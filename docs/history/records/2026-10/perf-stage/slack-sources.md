# Where the large blocks' slack lives (2026-11-01)

A follow-up to rows 43 and 45, measured only; nothing was built. Row 43
([large-blocks.md](large-blocks.md)) found 14.2 MiB of ts-pattern's large
blocks resident but never written at Trig's heap peak. Row 45
([fault-used.md](fault-used.md)) found faulting in ahead accounts for only
2.4 MiB of it. The question here was where the rest lives: huge pages on
blocks of 16 MiB or more, reused kept blocks, or something else.

**The answer: almost nowhere.** Row 43's figure was mostly a measuring
error. With residency counted correctly, ts-pattern's large blocks hold
4.3 MiB unwritten at the peak and zod3's 1.8 MiB, and the arms below
recover all of it.

The data is in [slack-sources-data/](slack-sources-data/):

- [measure.patch](slack-sources-data/measure.patch): the measuring patch
  against Rig `a40f20d6d`, for measurement only. It is row 43's patch,
  plus each block's origin and residency read from `/proc/self/pagemap`.
- [origin.txt](slack-sources-data/origin.txt) and
  [origin-mincore.txt](slack-sources-data/origin-mincore.txt): the
  profile by origin, counted correctly and as row 43 counted it.
- [arms.sh](slack-sources-data/arms.sh) and `d-*.diff`: the arms.
- [rss.sh](slack-sources-data/rss.sh), [rss.txt](slack-sources-data/rss.txt)
  and [modes.txt](slack-sources-data/modes.txt): the peak RSS runs and
  their summary by huge-page mode.

**Setup:** Trig `4bc7a9a`, built by Rig `a32adf178` as a release package.
Each arm patches that one package's `rig/alloc.zig`, built with
`-Osafe -fomit-frame-pointer` through the release slot. The profiles and
the 1-checker runs used one E-core, and the 4-checker runs four.
Binaries were copied to tmpfs, 5 rounds, arms interleaved.

## Row 43's measuring error

Row 43's snapshot scanned each block back from its end for its last
nonzero byte, then asked `mincore` which pages were resident. Reading an
untouched page of an anonymous mapping maps the shared zero page there.
`mincore` reports that page as resident, but RSS does not count it. So
every page the scan read looked resident, and every block looked faulted
in to its end.

The tell: a build with no faulting in ahead at all showed exactly the
same residency, to the hundredth of a MiB
([origin-mincore.txt](slack-sources-data/origin-mincore.txt)).

Counted from `/proc/self/pagemap` instead, a page counts only when it is
present and mapped by this process alone (bits 63 and 56). The zero page
is never mapped by one process alone.

## Slack at the peak, by origin

Unwritten resident MiB at Trig's heap peak, one checker
([origin.txt](slack-sources-data/origin.txt)):

| Origin | ts-pattern, main | ts-pattern, no faulting ahead | zod3, main | zod3, no faulting ahead |
|---|---:|---:|---:|---:|
| new block | 0.38 | 0.00 | 0.26 | 0.00 |
| kept block | 0.30 | 0.30 | 0.27 | 0.27 |
| grown into a kept block | 0.46 | 0.46 | 0.19 | 0.19 |
| grown by `mremap` | 2.02 | 0.00 | 1.05 | 0.00 |
| grown by `mremap`, huge pages (one 16 MiB block) | 1.15 | – | – | – |
| **all** | **4.31** | **0.76** | **1.77** | **0.46** |

- **Faulting in ahead:** 3.5 MiB of ts-pattern's 4.3 and 1.3 of zod3's
  1.8. Half the room an `mremap` grow gains is faulted in, and Lists
  stop short of it.
- **Huge pages:** one block reaches 16 MiB on ts-pattern. Its 2 MiB pages
  leave 1.15 MiB unwritten past its end; with no huge pages that block
  would have 0.
- **Kept blocks:** 0.76 and 0.46 MiB. This is an upper bound, since the
  measuring patch zeroes a kept block when it is handed out, which writes
  every page of it.

## Peak RSS by arm

The arms, against main (m):

- **n:** no huge pages for large blocks (`huge_large` at the most).
- **k:** a kept block handed out gives back its pages past half its size
  (`MADV_DONTNEED`), and one grown into gives back its pages past the
  copy.
- **h:** row 45's arm h: half a new block faulted in ahead, none on an
  `mremap` grow.
- **all:** n, k and h together.

ts-pattern's runs fall into two modes, about 11 MiB apart at one checker
and 22 MiB apart at four. The higher mode is Tables on huge pages: those
runs started with about 72 or more free 2 MiB blocks, so the Tables'
huge-page gate opened (the gate asks for more than 64). None of these
arms touches that gate. Each mode is compared only with the same mode.
The table gives each arm's median minus m's median in that mode, in MiB
([modes.txt](slack-sources-data/modes.txt)):

| Project, checkers | n | k | h | all | m's median |
|---|---:|---:|---:|---:|---:|
| ts-pattern 1, low mode | -1.2 | -0.7 | -2.4 | -4.3 | 227.0 |
| ts-pattern 1, high mode | -1.2 | -0.7 | -2.9 | -4.3 | 237.8 |
| ts-pattern 4, low mode | -0.5 | -0.9 | -5.6 | -6.6 | 254.3 |
| ts-pattern 4, high mode | +3.0 | +0.3 | -4.8 | -5.2 | 276.2 |
| zod3 1, low mode | 0.0 | -0.3 | -1.9 | -1.8 | 73.2 |
| zod3 1, high mode | 0.0 | -0.3 | -1.3 | -1.6 | 75.3 |
| zod3 4 (one mode) | +0.1 | -0.4 | -1.6 | -1.5 | 104.7 |

Some cells rest on one or two runs; modes.txt gives the counts.

The four small projects at one checker repeat to 0.1 MiB: h saves 0.2 to
0.8 MiB, all saves 0.3 to 0.9, and n and k nothing.

At one checker on ts-pattern, the arms' 4.3 MiB matches the profile's
4.3 MiB. The three levers together recover all of the large blocks' slack:

- faulting ahead about 2.5 MiB;
- huge pages on the 16 MiB block 1.2;
- kept blocks 0.7.

That is 1.8% of the peak at one checker, and 2.6% at four.

## What it leaves

- **No large lever is left in the large blocks.** Their slack is 4.3 MiB
  at most on ts-pattern. h holds most of it, and row 45 measured h's
  cost: 1.5 to 2.1% more cycles on mitt and neverthrow. n and k were not
  timed; each saves 1.2 MiB or less.
- **The largest swing in Trig's peak memory is the Tables' huge pages:**
  11 MiB at one checker and 22 MiB at four on ts-pattern, 2 MiB on zod3.
  That is a speed trade already measured
  ([thp-spare.md](thp-spare.md), [table-huge.md](table-huge.md)).
- **Row 43's other findings stand:** sizes, used extents, and which
  owners hold the room. Only its residency, and so its slack, was
  overstated.
