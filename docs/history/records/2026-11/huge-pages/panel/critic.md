# Huge-pages panel, critic lens: what the records actually bound

2026-11-06. Read only; no runs, no pup. Sources, all checked line by line:

- Rig `origin/main` `9d73afdf1`: `src/alloc.zig`, `src/table.zig`;
  records `2026-11/scaling/investigation.md` (cited below as INV),
  `2026-11/scaling/table-arena.md`, `2026-11/panels/table-arena/critic.md`,
  `2026-11/panels/exit/os.md`, `2026-10/perf-stage/{table-huge, thp-gate,
  thp-fragmented, table-arena, four-checkers/kernel}.md`,
  `2026-10/table-prefault/README.md`, `archive-tags.md`.
- Trig `docs/RESULTS.md` (scoreboards of 11-03 and 11-05, the `hugepages`
  row at :745, the table-prefault paragraph at :1148, the checker drop at
  :1982), `docs/research/29-concurrency-panel-2026-11-04/README.md`.
- tsrs `notes/mem-no-thp.md`, `notes/linux-x86-round.md`,
  `crates/tsrs_core/src/{reserve.rs, arena.rs}`.

## 0. Verdicts, ranked

| # | Proposal | Verdict | First step | Kill threshold |
|---|---|---|---|---|
| 1 | Settle Q1 on pup with a 2×2 THP on/off A/B of both programs (extends linux P4) | **PURSUE** (no code) | one slot, below | (tsrs's THP gain − Trig's) < 1.5% at 1 thread and at the race's 4 checkers, natural state: close Table huge-page work |
| 2 | Record the machine state in every race row | **PURSUE** (Trig's tools, free) | free order≥9 blocks at start, `thp_fault_alloc/fallback`, `compact_stall` per program | none; it is bookkeeping |
| 3 | Per-Table density census (pagemap × per-Table high-water and slot counts) | **MEASURE FIRST** (offline, no timing slot) | the table-arena critic's Q3 item 1, plus head sizes 2 MiB / 1 MiB / 512 KiB computed offline | push-dense Tables hold < 50% of the small-page Table memory at 4-8 checkers: D1 dead; no head size saves ≥ 1/4 of head faults at ≤ 1% RSS: head question closed |
| 4 | allocator D1, typed record arena | **MEASURE FIRST**, only after 1 and 3 pass; design fails soundness as written (§3) | the allocator's ceiling arm, but read only for speed | < 3% faster at 4 checkers on the race's pin, or < 1.5% at 1, natural state, 20 rounds: drop before the CORE round |
| 5 | linux P1, growth sampler off the push path | **MEASURE FIRST**, low | re-measure gate open vs shut on today's Trig (one slot) | gross open-vs-shut < 2% on ts-pattern at 1 and 4 checkers today: drop; built arm < 1.5% at leave35 over 20 rounds, any `compact_stall` of its own, or > 0.3% instructions: drop |
| 6 | linux P2 (read the THP mode), P3 (count one node) | **PURSUE**, small, as correctness on users' machines; no speed claim | unit tests with fake sysfs/buddyinfo | n/a |
| 7 | allocator D2, PROT_NONE guard windows + SIGSEGV | **DROP** | | same prize as P1, plus an accept-means-correct hazard (EFAULT) |
| 8 | macos "Mac as control" | **DROP** as a bound | replace by item 1 | |
| 9 | allocator D3, D4; macos A-F; every kernel feature in linux §2 | **DROP** (agree with the experts) | | |

Two things the panel should say plainly to the owner:

- **The earlier attempts were not premature, but their prize numbers are
  stale.** Every open-vs-shut number (3.1%, 2.3%, 1.4%, 4.6%) was taken on
  Trig of late October (0.74-1.47 s, 260-420 MB). Trig is now 0.666 s at one
  thread and has the checker drop, lazy members, `exact` and zero-copy. No
  design here should be built on those numbers; item 1 and item 5's first
  step re-take them.
- **At one thread the gap is inside the lottery band.** The 11-05 race is
  1.02 (default) and 0.97 (signal preemption). tsrs's own swing between a
  run with and without huge pages on pup was 0.651 → 0.707 s (8.6%,
  RESULTS:1735). There is nothing left to chase at one thread except the
  machine state.

## 1. Q1: is "huge pages are one of the main reasons tsrs wins" true?

### What huge pages are worth to each program, measured

| | value | source, conditions |
|---|---|---|
| tsrs, its arena on huge pages | 1.7-5.9% less wall | linux-x86-round: cloud VM, 40 GiB free, `thp_fault_fallback` 0 |
| tsrs, THP off for the whole process | 4-10% more check time; 3-25% more wall on 17 projects | mem-no-thp.md, Depot 32-64 vCPU |
| tsrs on pup, ts-pattern, 1 thread | 0.651 s (15.6K faults) vs 0.707 s (35.9K faults): 8.6% | RESULTS:1735; two bench runs, not interleaved |
| Trig, all advice vs none, quiet (196 free) | 5.4% (main), 4.6% (gate) faster; RSS 3.9-4.6% higher | thp-gate.md, P-core 1, 20 rounds, Trig 403a823 |
| Trig, Table gate open vs shut | 3.1% at 1, 2.3% at 4 | four-checkers/kernel.md, E-cores, **3 open runs of 12** |
| Trig, Table windows alone, net of a 0.8% hook | 1.4% at 1 (ts-pattern, 34-56 free); 0 on zod3 | table-huge.md, hybrid, P-core 6, 20 rounds |

So when both get them, tsrs gains about 5-9% and Trig about 5%: the
difference that is "tsrs uses huge pages better" is 0-4 points at one
thread. When the gate is shut and tsrs's compaction succeeds, tsrs gains
its full 5-9% and Trig only its segments' 1-2% (table-huge `seg`): up to
about 7 points. The current one-thread gap (2%, or -3% with signal) lies
wholly inside that band.

### Shares of the gap at 1, 4 and 8 checkers

| | 1 thread (race: core 3) | 4 checkers (race: pin 0-11, P-cores) | 8 checkers (E-cores 12-19, INV) |
|---|---|---|---|
| gap to shipped tsrs | 12 ms of 666 (1.02); signal: Trig faster | 46 ms of 275 (1.20) | 148 ms of 435 (1.52), pre-drop |
| kernel excess | faults+populate 5.6% vs 4.7% of cycles at 82 free (INV §2, E-core); 351M vs 179M kernel cycles with the gate shut (standing-3, P-core): ≈ 4.7% of Trig's cycles | ≈ 3.5 points of cycles (INV, E-core: 8.8% vs 5.3%) ≈ 9-10 ms | 4.7 points ≈ 13 ms |
| exit excess | 13.1 vs 6.8 ms ≈ 1% | pre-drop 28 vs 10 ms; the drop saved ~10 ms at 4 (table-vmas, os.md), so ≈ 8 ms ≈ 3% (unmeasured on P-cores since) | 22.1 (post-drop) vs 11.9 ms ≈ 2.3% |
| page walks | ≤ 1.45 points, upper bound, P-core with sibling idle (table-arena critic Q2) | ≈ 0 on P-cores with siblings idle; **unknown with SMT siblings busy**, which pin 0-11 allows | 3.5 points (E-core only) |
| **of it, attributable to page size (not density)** | the lottery: 0-7 points, as above | Table tails open vs shut ≈ 2.3% ≈ 6 ms (3 runs), plus some exit: **about 13-17% of the gap** | in the INV slot (82 free) the tails were already huge (46 MiB) and exit was still 25 ms: **≈ 0 beyond what main's gate gives when open**; in gate-shut states ≈ 6-8 ms of exit (linux §4) |
| the rest of the gap | none | file assignment ≈ 9 of 16 busy points, forbidden by exact output; tsc's partition tail, which tsc has too; Trig's own ≈ 7 points: exit, serial head, the heaviest checker's memory shape and yield checks (research 29) | heads (density): 95 MiB on 4 KiB pages in 409 heads; assignment |

**Verdict on Q1.** At one thread the claim is half true: huge pages are the
only thing still moving the ratio, but as tsrs's luck with pup's compactor,
not as a cost Trig carries. At four and eight checkers it is false as
stated. The page-size share is about one sixth of the four-checker gap; the
larger memory share is density (heads, sparse link Tables), which no advice
fixes; the largest share is file assignment and idle time, which are Trig's.

## 2. Q2: "bytes touched are level" (150 vs 152 MiB, 220 vs 230)

Source: INV §3, `/proc/PID/smaps` of ts-pattern **at about 70% of a run**,
Trig against **tsrs in Go mode** (`--checkerAssignment go --noLazyMembers`).
It is not the same measure as the claim makes it:

1. **Not shipped tsrs.** In the same slot shipped tsrs peaked at 167 / 195
   MiB against Go mode's 207 / 242 (INV §1). Go mode turns tsrs's lazy
   members off, which costs it memory; Trig had lazy members on. Trig's
   RssAnon at peak is 178.6 MiB today at one checker (RESULTS:2022, after
   zero-copy), already more than shipped tsrs's whole RSS (167 MiB, binary
   included). Against the program the race runs, Trig's anonymous memory
   is not level; it is roughly 1.2-1.3× (anonymous for shipped tsrs was not
   recorded, so this is a bound, not a number).
2. **A snapshot, not a peak.** "70% of a run" is a different point in each
   program's work, and Trig's checkers still grow after it.
3. **Resident, not touched.** On huge pages a touched byte costs 2 MiB of
   residency; on small pages 4 KiB. tsrs's 100-138 MiB of huge pages
   include its frontier slack (dense, about 1 MiB a thread); Trig's sparse
   small pages count only what was touched. Both sides are inflated
   differently, so even Go mode's "level" is not an equality of bytes.

The allocator's conclusion ("page size and layout: all of it") depends on
point 1. Drop "bytes touched ≈ 0% of the gap"; say instead that against Go
mode resident memory was level in that slot, and against shipped tsrs it
is not known and probably 20-30% higher.

## 3. Q3: D1, the typed record arena

### Is it different from archive/table-arena and #832? Yes, in kind

- `archive/table-arena` packed whole Tables in heap blocks and had to
  answer any index below `n`: a test on every read, 14-18% more
  instructions (scaling/table-arena.md).
- #832 (perf-stage/table-arena.md) only puts Tables' ranges in shared
  256 GiB regions to cut system calls; each Table still spans its full `n`.
- D1 packs records, each named by a handle a push made, so no read test.
  That is new.

### But it is unsound as written

The report says a `Ref` of one arena read in another "reads zeros, under
the same rule that makes a `Slot[n]` of one Table good in any other". It
does not. A Table is homogeneous: slot `s` of any Table of `T` is a `T`. An
arena is heterogeneous: offset `r` of arena B may lie in the middle of a
record of another type, so a `Ref[T]` from arena A read in B is a type
confusion. An enum, a bool, an optional or a tag in `T` then holds an
invalid bit pattern, which is illegal behaviour in the Zig emitted. The
same holds for a zeroed `Ref` field (offset 0). Fixes exist: brand each arena
with its own type (`Ref[T, A]`), or limit records to types where every bit
pattern is valid, and reserve offset 0. Either makes the CORE change larger
than a §10 paragraph.

### A hidden cost the report leaves out

Trig's side Tables (flags, caches, the 7 link Tables) are indexed by dense
per-kind ids. Under D1 a `TypeId` becomes a word offset spread across every
record kind, so any Table indexed by it becomes sparser by the mean record
size over 8 bytes: the very problem D1 is meant to remove. Trig would have
to move that side data into the records. That is the large part of the
refactor, and its effect on reads is unmeasured.

### Does the 5-7% ceiling at 4-8 checkers survive the share bound? No

INV's fix-1 ceiling is 9.6% / 10.4% at 4 / 8, on E-cores, with every cost
brought to tsrs's level. Take out of it:

- page walks, 3.3-3.5 points: about 0 on the race's P-cores;
- the exit excess, which the checker drop has since cut by about 10 ms at
  4 and 8 checkers: about 2 points;
- the link Tables, which D1 leaves alone: of the faults table-prefault
  attributed, 53% were pushes and 12% link-Table writes, so a sixth to a
  fifth of the Table part stays.

What is left is **about 3-4% at 4-8 checkers, and about 1% at one**, and
only in states with free 2 MiB blocks (the arena's huge part still needs a
gate). That is above the bar at four checkers, but only just, and before
the read and refactor costs.

### A smaller form with today's reads? Not on Rig's side

- Placing several Tables in one reservation with today's reads is only
  possible for Tables whose whole `n·size` is small. A Table's read is
  `base + i·size` with no test, so every Table needs its full `n` laid out
  contiguously. Trig's hot heads belong to Tables reserved at large `n`.
  The table-arena critic dropped this (Q3 item 3), and nothing here changes
  it.
- The smaller forms are Trig's: dense per-checker ids, and merging Tables
  indexed by the same `Slot` into one Table of an object. They need no Rig
  or CORE change, and they help under any page size.
- **The ceiling arm proposed is a speed bound, not an RSS bound.**
  Right-sizing ×2 and packing 36 Tables leaves one partly filled frontier
  window per Table (about 36 MiB a checker on huge pages), not D1's one
  per checker. Read its time; compute D1's RSS from the census (item 3).

## 4. Q4: window-at-a-time advice, and the guard-window variant

### Does the populate path see the Tables' growth? No

`newPage` (alloc.zig:313-331) runs when a heap carves a new 64 KiB class
page. Its populate (`:316`) fires once per 1 MiB of a segment, and only in
heaps that fault ahead (`prefault` returns at once otherwise; at four
checkers no heap does until it has taken `prefault_big`; four-checkers
kernel.md, "Segments"). A Table's growth is a store into a reserved range
(`table.zig` `reserve`, :118-139, through `reserveTable`, alloc.zig:987); no
Rig code runs on it but `push`. So P1 is a sampler clocked by the heap's
carving, not by the Tables:

- a Table phase that grows faster than the heap carves outruns it (lost
  gain only);
- `mincore` on a window's first page finds a frontier only for push-dense
  Tables. A link Table's touched windows are scattered, so "advise the next
  W" there commits a whole 2 MiB per sparse write: main-open's RSS.
  alloc.zig cannot read a Table's `len`, so P1 needs `table.zig` to
  register only push-grown ranges, or a dense-prefix test (windows 0..k all
  resident);
- W doubling brings back the staleness of advice at reserve: blocks
  counted at the check are faulted for hundreds of milliseconds. Keep W at
  1-2, as the segments do (they ask moments before populating).

### Is 0.8 ms per failed compaction right? As a mean, yes; the tail is the risk

- The brief's figure: 0.29 s more sys for about 360 stalls.
- thp-gate's partly fragmented row: 130 ms more wall for 181 stalls, 0.72
  ms each. Its light row: 482 ms for 397 stalls, 1.2 ms each.
- But single windows reached 21 ms (table-huge, "whole", light) and 84 ms
  (the breaker).
- A successful direct compaction is not free either.

So the linux report's break-even ("asking pays while compaction succeeds
more than about half the time") is too generous. With a heavy tail, asking
beyond the free blocks loses unless compaction nearly always succeeds,
which is what thp-gate's 15.6% and 56.8% slower rows show for Trig.

### Reconciling the RSS costs: two designs, and an old base

| figure | what was measured | design |
|---|---|---|
| 4.6% (linux, "271 vs 259") | thp-gate (g), quiet, 1 checker: **all advice** (segments, Table tails, large blocks) against none | all tails |
| 14% (linux) | four-checkers kernel.md, 4 checkers: gate open vs shut, 326 vs 286 MB, 3 open runs | all tails, the link Tables' sparse windows included |
| 1.5% (allocator, jit) | table-huge, 1 checker: 246.7 → 250.4 MB, with jit taking 37 of 76 windows | frontier windows only, half covered |
| 3.9% (allocator) | table-prefault arms 5/6, 4 checkers: 383 → 398 MB | push frontiers only, every window asked |

Both experts quote correctly; they price different designs. All tails cost
about three times frontier-only, because a link Table commits 2 MiB per
sparse write. P1 as written is all-tails (its own text says "as main's when
the gate is open"). It becomes frontier-only only with the restriction
above.

Every base is old: Trig's peak was then 247-420 MB and is now about 210
MiB at one checker, with the drop at four and eight. In absolute terms,
frontier slack is about 1 MiB per large dense Table per live checker (4-15
MB), and all tails 12-40 MB. Relative to today's smaller base, these
percentages will be higher. Re-measure; do not quote.

### Is the Table gate all or nothing? In effect, yes

- `hugeFree` (alloc.zig:597-600) compares a kept reading (4 ms life,
  `reading_life_ns`) with `huge_spare` 64 and never spends from it.
- `hugeFreeFor` (:608-613) needs a fresh reading for a yes, adds
  `huge_floor` 8, and spends `need`.
- A checker's 43 Tables are reserved within about 1 ms, and four checkers'
  within a few ms. So one reading decides every Table of the run: all
  tails or none.

The linux report is right on this point. The allocator report never claims
otherwise.

### D2, the guard window: DROP

It buys the same windows as P1 (gross 2.2% at one checker in the 30-64 free
band, 0 on zod3, little at 4-8 where the heads are), at real costs:

- `read(2)` or `write(2)` on an unopened window gets `EFAULT` instead of a
  fault. That is a silent wrong result in std paths, against accept means
  correct;
- `mprotect` takes `mmap_lock` for writing per window while every checker
  faults;
- it interacts with signal preemption (rig#952, which already uses
  signals), with `RIG_SANITIZE`, and with debuggers;
- VMAs split per window on top of 1,304 mappings.

P1, restricted, reaches the same windows without any of these.

## 5. Q5: the Mac as a control. Invalid as a bound

"pup's gap minus the Mac's gap" folds in at least six differences, each the
size of the effect sought:

1. **ISA and codegen.** arm64 against x86-64; `rig build --pgo` is Linux
   only (AGENTS map), so Trig on the Mac is not the race's PGO build, and a
   darwin tsrs is a different build again.
2. **Cores.** M5 P/E cores against Redwood Cove; Trig's walk excess
   differs fourfold even between pup's own core types (table-arena critic
   Q2).
3. **Pages.** 16 KiB pages give 4× fewer faults and 4× the TLB reach, and
   they change Trig's sparse-touch cost differently from tsrs's dense one.
   The macos lens's own probe found page-table pages dominate a sparse
   exit (163 ms), so layout still matters there; it is not "footprint
   only".
4. **Rig's own code paths differ.** On Darwin `reserveTable` returns null
   (alloc.zig:988): each Table is its own `mmap`, `prefault` does nothing,
   and large blocks are not aligned. The Mac does not run the memory
   layout being judged.
5. **Scheduler.** macOS moves equal threads between clusters
   (perf-cores.md); pup's race pins 0-11. With four checkers on 4P+6E, the
   critical path differs.
6. **Load.** The lens measured at load 5-7.

The honest control is on pup: the same binaries, cores and slot, with THP
off for each process (item 1).

## 6. What everyone missed

1. **The race's machine state is the lottery, and it is not recorded.** A
   slot opened with drop_caches + compact_memory gave 82 free blocks for
   INV, 1 for the table-arena and coloring slots, and 196-273 for quiet
   runs. The scoreboard reports none of it, nor tsrs's
   `thp_fault_alloc`/`compact_stall`. Until it does, a ratio at one thread
   is not comparable between days. This is free (item 2) and comes before
   any Rig change.
2. **tsrs's exit under fragmentation.** The exit panel predicted it; nobody
   measured it. tsrs's 10.8-11.9 ms exit is 92 MiB on small pages at 82
   free blocks. On a fragmented pup either its exit grows toward Trig's, or
   its huge pages come from direct compaction inside its run. Either
   changes what "beyond tsrs's exit" means. Add exitwatch for tsrs to item 1.
3. **pup may not represent users, in either direction.** The ZFS ARC
   hypothesis (linux §1) is plausible and testable (`arcstats`,
   `pagetypeinfo`, as root). Typical users:
   - CI VMs, fresh and mostly free, where tsrs measured its gains with 0
     fallbacks. There both programs get huge pages, and Rig's gate opens.
   - ext4 desktops, whose page cache compacts.

   If pup is worse than both, the race understates Trig wherever the
   gate's shut state is a pup artifact. Changing pup (capping the ARC) is a
   machine state and the owner's call; it applies to both programs alike.
4. **THP `enabled=always`.** linux P2 is right that Rig misreads it. Under
   `always`, tsrs's mimalloc heap gets THP anyway (`MI_NO_THP` only removes
   the `madvise`), so tsrs pays its 2 MiB-per-thread-page amplification
   (mem-no-thp.md: 0.7 GiB at 64 vCPU). The RSS comparison shifts toward
   Trig there. Which distributions ship `always` is not verified in the
   linux report (the upstream Kconfig default is `always`; Ubuntu ships
   `madvise`). Check each distribution's config before claiming.
5. **The heads can be priced offline.** At one checker about 10 Tables pass
   2 MiB, so their heads are full. 10 × 512 = about 5K of 15.9K faults are
   in heads that would cost nothing to make huge on ts-pattern, and up to
   2 MiB each on mitt. The allocator dropped a head offset by argument, not
   data. With the census (item 3), head sizes of 2 MiB, 1 MiB and 512 KiB
   can be costed in faults and RSS per project with no build. Making a
   full head huge after the fact means `MADV_COLLAPSE`, about 0.5-1 ms per
   2 MiB copied against about the same saved: DROP that form.
6. **SMT in the race's pin.** "P-core walks ≈ 0" was measured with siblings
   idle. Pin 0-11 is six physical P-cores with both threads each, so two
   checkers can share one STLB (research 29: "Unknown: SMT placement").
   TLB reach, the one thing huge pages give besides faults and exit, may
   matter more in the race than the records show. Count walks in item 1 at
   the race's own pin.
7. **The brief mixes configurations.** "Exit 22 ms of 0.275 s at 8
   checkers" pairs the checker drop's E-core 8-checker exit (RESULTS:1982)
   with the race's 4-checker P-core wall (RESULTS 11-05). The race's exit
   at four P-cores after the drop is unmeasured.
8. **A factual slip in linux §0:** tsrs does not commit "one 2 MiB chunk at
   a time just before its bump pointer reaches it". Its thread chunks
   double from 2 to 64 MiB (`arena.rs:195-233`, `MAX_CHUNK`), each advised
   and `mprotect`ed whole at commit (`reserve.rs:111-127`). tsrs's advice is
   as stale as Rig's reserve-time gate; it simply has no gate.

## 7. The measurement (item 1), as one pup slot

- **Arms:** Trig and tsrs 0.21 `--fast`, each with THP on and THP off.
  - Trig off: a wrapper that calls `prctl(PR_SET_THP_DISABLE, 1)` and
    execs. The setting survives `execve`.
  - tsrs off: `MIMALLOC_ALLOW_THP=0`, so mimalloc sets the prctl itself.
    tsrs's own `main` clears it unless that variable is set.
- **States:**
  - quiet: `compact_memory`, and at least 150 free blocks at start;
  - natural or leave35, recorded per run.
- **Pins:** core 3 with `--singleThreaded`; pin 0-11 with 4 checkers (the
  race).
- **Rounds:** 20, interleaved and shuffled (time-ab).
- **Counters, per program and run:**
  - free blocks at start;
  - `thp_fault_alloc`, `thp_fault_fallback`, `compact_stall`,
    `compact_success`, `compact_fail`;
  - faults and kernel cycles;
  - `dtlb_load_misses.walk_active` (P-core PMU);
  - exit by exitwatch;
  - RssAnon and AnonHugePages at peak.
- **Reads:**
  - (tsrs on − off) − (Trig on − off) is huge pages' share of the gap at
    that state, directly;
  - whether tsrs's huge pages come from free blocks (P1 can match them) or
    from compaction (Rig should not chase them);
  - the walk count with SMT siblings busy.
- **Kill:** below 1.5% at both pins in the natural state ends Table
  huge-page work. Above 3% at 4 checkers moves items 3 and 4 forward.
