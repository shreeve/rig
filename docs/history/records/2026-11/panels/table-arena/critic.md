# table-arena panel, critic lens: is the prize real at the wall, on the race's cores?

2026-11-05. Read-only, no timing: pup is unreachable, and nothing here needed
the Mac. Sources:

- in the repo, on origin/main:
  - `docs/history/records/2026-11/scaling/`: investigation.md, table-arena.md,
    arena-data/ab-summary.md, table-vmas.md;
  - `2026-10/perf-stage/`: stlb-aliasing.md and its data
    (`color-timing-summary.txt`, `table-color.diff`), next-win-ranking.md
    (addendum), scaling-2.md;
  - `2026-10/hash-race/tsrs-standing-3.md` and `tsrs-standing-3-data/walks.txt`,
    the only record with P-core page-walk counters;
  - `archive-tags.md`;
- session notes: the foreman's queue notes (row 55) and
  `beat-tsrs-list.md` (row 17);
- Trig's `tools/cli/bench`, for the race's command lines;
- the memory lens's report, `memory.md`.

## Q1. The memory report against the records

### The 67% page-0 figure: right, but it is an E-core count

stlb-aliasing.md section 3 gives 66.9% for ts-pattern and 64.2% for zod3, at
one checker. 83% of the Table misses fall in set 0 by page index mod 128.

The sampled event was `cpu_atom/event=0xd0,umask=0x11/`: retired loads that
missed the STLB, **on the atom (E-core) PMU**, with the run pinned to core 12.
So it measures Crestmont's STLB only. No record attributes P-core STLB misses
by address.

### "Never landed, tagged or closed": wrong

Coloring was judged on 2026-11-02, the morning after it was built:

- **queue.md row 55:** "**PARKED, under the bar.** E-cores: page walks 76-85%
  fewer, cycles 2.1-4.6% fewer. P-cores ... every project within the A/A spread
  ... Redwood Cove's STLB doesn't alias the way Crestmont's does."
- **beat-tsrs-list.md row 17:** "**CLOSED, under the bar** ... The STLB gap is
  an E-core effect. Lazy members go on main's base."

It did not stall. It was measured on the race's kind of core and failed the
bar there. It looks open only because:

- the verdict lives in session notes, not in the repository;
- stlb-aliasing.md ends on its P-core table and a "next measurement" paragraph,
  with no closing line;
- archive-tags.md has no row, because the diff was never committed (it stayed
  in an uncommitted worktree, and only `table-color.diff` was kept).

That record gap is how this panel came to rediscover it. Fixing it is the one
concrete action from this lens: see the verdict.

### Was "level on P-cores" well measured? For wall time, yes

From `color-timing-summary.txt` (stlb-aliasing.md, "P-core timing"):

- `time-ab.sh`, with shuffled rounds, a warm-up, an A/A arm and binaries on
  tmpfs;
- 60 rounds on the 25 ms projects and 20 on ts-pattern, zod3 and
  tiny-invariant;
- one checker on core 6, and four on 0, 6, 8, 10: one per physical P-core,
  siblings idle;
- all 1,440 runs had the huge-page gate shut (1 free 2 MiB block). That is the
  case with the most small-page walks, the one most favorable to coloring.

Results:

- ts-pattern: 0.4% slower at one checker, level at four;
- zod3: level at one checker, 0.2% faster at four;
- cycles within ±0.5% everywhere, inside the A/A spreads of 0.1-1.4%;
- the best row of all is tiny-invariant at four checkers, 0.8% faster, inside
  its own 0.7% A/A.

Twenty rounds against an A/A spread of 0.4-0.6% would see a 1% gain. They rule
out the 1.5% bar with room to spare.

What it did **not** do:

- count P-core walks, so the mechanism is unmeasured;
- run 8 or more checkers, or two checkers on SMT siblings that share one STLB;
- run on today's Trig: the timing was on Trig 07e4447 and Rig e10087dd8,
  before lazy members.

None of these is the race's configuration (below), so none reopens it.

### What counts for the race and the bar

The race's shapes:

- **One thread:** `taskset -c 3`, `--singleThreaded` (Trig's tools/cli/phases,
  profile, ledger).
- **All cores:** `trigN` is "trig with tsc's default checkers (4)", pinned by
  `PINN` (tools/cli/bench lines 45, 97). That is four checkers spread over
  0-11.

Both shapes match what the coloring timing ran: one P-core with its sibling
idle, and four checkers on four physical P-cores. The bar is judged on core 3.

**What the owner should expect from coloring on the race's cores: nothing.**
That means 0 ± 0.5% wall, no change in instructions, no change in RSS. It
clears neither the 1.5% time bar nor the 1% instruction bar.

The E-core gain is real (2.1-4.6% fewer user cycles, counted, never timed as
wall). It matters to users on hybrid laptops. But it is outside the bar as the
bar is written, the same standing as loop-split's arm64 question.

## Q2. Is the 3-3.5 points of walk stall real wall time on P-cores? No

Every "3-3.5 points" figure is E-core data:

- investigation.md ran only on E-cores ("P-cores were not used: eight checkers
  need eight like cores");
- table-arena.md timed only on E-cores;
- stlb-aliasing.md's counters were taken only on E-cores.

The metric was `ld_head.pgwalk_at_ret`, Crestmont's retirement-stall event.

The only P-core walk counters are in tsrs-standing-3: `walks.sh`, P-core 1
with its sibling idle, 8 interleaved rounds, Trig `1b2-pgo` against shipped
tsrs. Recomputed from `walks.txt`, as a share of user cycles:

| P-core 1 | load walk active | store | code (iTLB) | all walks | completed load walks |
|---|---:|---:|---:|---:|---:|
| Trig ts-pattern | 2.62% | 0.34% | 1.36% | **4.32%** | 1.70M |
| tsrs ts-pattern | 1.07% | 0.63% | 1.17% | **2.87%** | 0.56M |
| Trig zod3 | 1.15% | 0.32% | 1.02% | **2.49%** | 0.12M |
| tsrs zod3 | 0.59% | 0.24% | 1.27% | **2.10%** | 0.04M |

Two things follow.

1. **On a P-core, Trig's whole walk excess over tsrs is 1.45 points on
   ts-pattern and 0.39 on zod3.** That is about 11 ms and 0.6 ms, and it is an
   upper bound: `walk_active` counts the cycles a walk is running, much of it
   overlapped with other work, not the cycles retirement waits.
   - Even a fix that removed every excess walk could reach the bar only on
     ts-pattern, and only if every walk cycle were a stall.
   - On zod3 it cannot reach the bar at all.
   - Coloring removes only the aliasing part of the excess, and the timing
     says that part is about 0.
2. **The P-core takes about a quarter of the E-core's walks for the same
   program.** On ts-pattern at one checker that is 1.7M against 4.8-6.7M
   (stlb-aliasing section 3), against 14-19 times tsrs's on E-cores.
   - Redwood Cove's STLB holds the ~43-50 aligned heads that Crestmont's
     set 0 cannot (Crestmont's conflicts start at 16 heads, per `alias.c`).
   - So the "page 0 of every head" aliasing is mostly a Crestmont problem.
     That answers the memory report's "I don't know which": the miss is not
     there to hide.

next-win-ranking.md's addendum had already warned that "the P-core gain may be
nearer 1-2%". The timing then came in below even that.

## Q3. Better uses of the same effort, on the race's cores

The scoreboard puts the all-cores gap at ts-pattern 1.20 and zod3 1.04, with
four checkers on P-cores.

investigation.md section 5 splits the loss against Go mode at four checkers
(E-core; kernel costs are less core-dependent than walks). On ts-pattern:

- exit beyond tsrs's: 15.4 ms (the exit panel's);
- kernel memory work: 9 ms;
- page walks: 3 ms, which on P-cores is roughly zero (Q2);
- serial head: 4.6 ms (Trig's);
- file assignment, shipped tsrs against Go mode: 53 ms (Trig's).

Leaving out the exit and the parallel release, here is what is left in the
Table and memory area.

### 1. Trig's id layout (ids dense per checker): the surest, and Trig's

This is the only candidate that attacks a cost the P-core keeps:

- **Faults.** These are kernel work, and a better TLB does not hide them. At
  one checker, 67% of Trig's faults land in the small-page Table heads.
  On P-core 1 in standing-3, kernel cycles were 351M against tsrs's 179M (gate
  shut) and faults 40K against 18K: an excess of about 4.7% of Trig's cycles,
  over three times the whole walk excess.
- **Page tables, and resident pages at exit.** Exit follows resident memory,
  about 0.14-0.28 µs a page (table-vmas.md).

It needs no Rig change and adds nothing to any read. scaling-2 already showed
one case: one Table reserving 1,280 MiB and writing a page every 80 MiB, which
"Trig indexes densely".

- **Prize:** unbounded until measured. The ceiling is part of the 9 ms of
  kernel work at four checkers, plus a share of the resident pages at exit.
  A plausible 1-2% on ts-pattern.
- **The measurement** is cheap and needs no timing slot. At the peak of one
  ts-pattern run at one checker and at four, take
  - stlb-aliasing's pagemap scan (`scanwin.py`, `pertable.py`), joined with
  - each Table's count of slots written and its highest slot written (a
    Trig-side counter).

  Pages resident, against the pages the written slots would need if
  front-packed, gives the faults and RSS the dense layout would save, before
  anyone renumbers anything.
- **Owner:** Trig (memory: Trig owns its perf). Forward it raw.

### 2. Fewer Tables per checker: uncertain sign, Trig's

Merging Tables indexed by the same `Slot[n]` into one Table of an object is
expressible today, with no Rig change. It cuts heads, mappings and page-table
pages.

But faults and resident pages fall only where the merged fields are written
together, and every read then pulls a wider line. The sign on user cycles is
unknown. It also does nothing on P-cores for walks, since there is no walk
problem there to fix.

Lower than item 1. Try it only where item 1's per-Table data shows two Tables
always written together.

### 3. Rig-side packing of small Tables without moving them: no prize for Trig

A Table whose whole `n * size` is small could be carved densely, at full size,
from one shared reservation. That is sound, with no read test and no zeroing.

But Trig's hot heads belong to Tables reserved at their largest `n`, and they
stay large. Packing applies only to Tables that are already small, and those
are not where the misses or faults are. Making Trig's Tables small is item 1
again. DROP.

### Not in this area, but larger

File assignment (53 ms at four on ts-pattern, against Go mode's partition) and
the heaviest group's single-thread speed are each larger than everything above
together. Both are Trig's, and known to it.

Zero-page shootdowns (investigation fix 3) are about 2 ms at eight checkers
and less at four. Trig's write-before-read fixes them.

## Q4. Verdict on the whole table-arena line

It is **not "a real method with one fixable flaw"**. It is a method whose
prize lives on the wrong cores.

- **The packed arena** traded a structural cost (a test on every read: 14-18%
  more instructions on every core, plus 8-24% more peak memory) for a walk
  saving that exists on E-cores. On the race's P-cores it would lose more than
  the 6-12% it lost on E-cores, since the instructions stay and the walk
  saving goes away. No layout dissolves the read test without keeping a fixed
  reservation of all `n`. The read-path expert's question is moot for the race
  unless the saving were large on P-cores, and it is not.
- **Coloring** is that same walk saving with no cost. It was measured honestly
  on the race's cores and found level, and it was correctly closed under the
  bar on 2026-11-02. Re-proposing it on E-core counts reopens a settled
  question.
- What remains in this area that P-cores pay for is **faults and resident
  pages**, which follow Trig's id layout. That is Trig's to decide.

Two loose ends to tidy:

1. Write coloring's verdict into the repository:
   - a closing paragraph in stlb-aliasing.md (P-cores level, closed under the
     bar 2026-11-02, the reason, and where the diff is);
   - an archive-tags.md entry in its "not tagged" form.
   This is docs only, needs no light gate, and stops a third rediscovery.
2. Forward Q3 item 1's per-Table density measurement to Trig, raw.

If the owner ever wants hybrid-laptop users' E-core speed to count, coloring
is the 30 lines to revisit. That is a change to the bar, the owner's call, and
not this panel's.

**DROP.**
