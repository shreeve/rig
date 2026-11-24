# Rig allocator: where huge pages start, measured: a speed-for-memory trade with no free point (2026-11-23)

Measured first, nothing landed. Rig base 383a1b2b5 (Trig's pin). Trig d78aa3f3, read only. The arm is on
the scratch branch `scratch/thp-size` (kept as it is; patches here). pup: Meteor Lake (P-cores 0-11, E-cores 12-19), 4 KiB pages,
THP `enabled=madvise`, `defrag=madvise`.

## Result in one paragraph

Huge pages cost Trig peak memory: a 2 MiB page commits room a List or a segment has not yet filled. A
threshold, `RIG_HUGE_MIN_MB=N`, keeps small pages for a heap's first N MiB of segments, a large block under N MiB,
and a reserved Table's first N MiB. **At its default (N=2, today's behaviour) it costs nothing.** Raising it trades speed
for memory at every checker count, with no point that saves memory for free: at N=8, wall is 0.8-2.7% higher and
peak RSS 2.1-7.2% lower; at N=32, wall 1.9-4.7% higher and RSS 3.4-9.6% lower (Compiler at c4 and c8 23% lower).
A census shows why the trade is mostly the heap's: above one checker the heap segments, not the Tables, hold most
of the huge pages. The decision whether to take any of this trade is the owner's. Rig recommends keeping N=2.

## 1. Census: which memory holds huge pages (patches/rig-census.patch)

`RIG_TABLE_RSS=1` (scratch only, never lands) prints each reserved Table's base, length, element type, `n`
and thread, its resident bytes (`/proc/self/pagemap`) and its huge-page bytes (`/proc/self/smaps`
AnonHugePages), measured as it is dropped or at exit, then each mapping outside the Tables. Fields are named
offline by the order each thread reserves its Tables (harness/census-names.py). Full tables and the raw lines:
data/census.md.

Trig at c4 on pup, THP on, N=2 (today), one run each, MiB:

| | Compiler Rss / AnonHuge | nuxt Rss / AnonHuge |
|---|---:|---:|
| store.value_symbol_links | 2.3 / 0 | 34.7 / 32 |
| store.types | 2.7 / 0 | 22.0 / 14 |
| ids.binder (main thread) | 1.2 / 0 | 14.0 / 12 |
| store.type_lists | 0.9 / 0 | 13.1 / 6 |
| checker.syms | 0.8 / 0 | 8.8 / 2 |
| all 217 Tables (summed over lifetimes) | 22.9 / 0 | 170 / 66 |
| heap segments, at exit | 87 / 54 | 320 / 190 |
| peak RSS | 120 | 521 |

- On Compiler no Table grows past its first 2 MiB, so none holds a huge page. On nuxt only the five above do.
- 159 of the 217 Tables (each checker's store) are dropped before exit and were measured as they dropped.
- Segment mappings merge across heaps, so there are no per-heap totals.

Census binary at N=2/8/32 (one run each; stdout identical across N):

| | N=2 | N=8 | N=32 |
|---|---:|---:|---:|
| Compiler c4 peak MiB | 120 | 109 | 89 |
| Compiler segments AnonHuge MiB (exit) | 54 | 46 | 14 |
| nuxt c4 peak MiB | 521 | 507 | 501 |
| nuxt segments AnonHuge MiB (exit) | 190 | 158 | 134 |
| nuxt Tables AnonHuge MiB (all) | 66 | 14 | 0 |

## 2. The arm (patches/rig-knob.patch, Rig ce8f7f9ac)

`RIG_HUGE_MIN_MB` is read once, with the mode for huge pages, from `/proc/self/environ` (`huge_min`: whole MiB,
rounded up to whole huge pages; 2 when unset). It moves where asking starts:

- a heap's segment or span segment asks once its heap has taken more than N MiB, counting that segment;
- a large block asks when it is N MiB or more (between 2 MiB and N it keeps small pages);
- a reserved Table keeps small pages for its first N MiB.

It adds no work to an allocation.
The patch also carries its unit test and the INTERNALS.md paragraph, written to land as its own PR if the owner
chooses a threshold.

**Binary:** one PGO+BOLT Trig (Trig d78aa3f3, Rig ce8f7f9ac) built on pup by Trig's recipe
(`tools/pup-rig`, `tools/trig/pgo --relocs`, `tools/trig/bolt-apply`), at pup:/zfs/trig-pup/thp-size/trig-knob-bolt,
sha256 b84853ebce3a01dbd42d44663b7c095c93a01300407825e963a89b796358f4c5.

**Checks before the race:**
- stdout identical to main's b1r on Compiler and nuxt at c4, with the knob unset and at N=2, 8 and 32.
- A/A at the default: `instructions:u` −0.003% against b1r (median of 5 interleaved runs, Compiler c4).
- Gates: `zig build test` on each commit; core suite (`tools/heavy --class correctness swarm test/rig.rip -w 4 -q`)
  12,733 jobs, exit 0; Trig `swarm tests/trig.rip cli` on burst, 38/38.

## 3. Race (pup slot 738)

harness/slot-thp.sh and harness/phases-sweepBC6.sh: 17 projects at c1/c2/c4/c8, four arms interleaved and
shuffled each round, 10 rounds, quiet honoured, c1 on P-core 3 and c2-c8 on cores 0-11 (the harness's
defaults; the census and the A/A instruction counts above ran on E-cores). M = main's b1r (Rig 383a1b2b5); B = the knob binary
unset (N=2, the A/A arm); X = N=8; Y = N=32. Wall from the shell's clock, peak RSS from `/usr/bin/time`. The
summed rows are over 16 projects (mui-docs left out, as in Rig's summary of the slot). Per project and count:
data/race-738.md (made by harness/table.py from data/race-738-runs.txt). stdout and statistics were
byte-identical across all four arms at each count on the four projects whose output the harness keeps
(supabase-studio, cal-diy, mui-docs, webpack).

Sums of medians, against M at the same count:

| | c1 | c2 | c4 | c8 |
|---|---:|---:|---:|---:|
| B (N=2) wall | −0.1% | +0.2% | −0.6% | +0.7% |
| B (N=2) RSS | −0.0% | −0.2% | −0.1% | −0.6% |
| X (N=8) wall | +0.8% | +2.0% | +2.7% | +2.0% |
| X (N=8) RSS | −2.1% | −4.2% | −5.3% | −7.2% |
| Y (N=32) wall | +1.9% | +4.1% | +4.7% | +4.6% |
| Y (N=32) RSS | −3.4% | −5.8% | −7.8% | −9.6% |

- **The knob costs nothing when off.** B is within ±0.7% of M on wall and RSS at every count.
- **No free point.** Every count that saves memory at N=8 or N=32 also runs slower. The trade grows with the
  checker count, as the census predicts: more checkers, more heaps, more segments that asked.
- **Small projects save the most memory:** Compiler and Compiler-Unions at N=32 are 21.5-24.7% lower at c2-c8, with
  wall −2.7% to +2.2%, within noise.

## Decision

Rig: keep N=2 (no change), and take the threshold to the owner as a speed-for-memory choice. Nothing lands meanwhile.
If a threshold is chosen, patches/rig-knob.patch is the change, with this race as its measurement.
