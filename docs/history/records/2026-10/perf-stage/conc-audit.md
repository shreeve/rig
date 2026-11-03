# Concurrency audit of Trig: four costs at one and four checkers (2026-11-01)

The owner's question: why don't Rig's tasks give Trig consistently excellent
numbers against tsrs? Measurement only; nothing changed, nothing committed.
Scripts and derived tables: [conc-audit-data/](conc-audit-data/)
(`summary.txt` and `modes.txt` derived, `time.sh`, `analyze.py`,
`modes.py`, `noyield.patch`, `shas.txt`). The raw `times.txt` (205 KB)
is on pup in `/zfs/trig-pup/records-data/conc-audit/`.

**Short answer.** Rig's concurrency machinery is not where Trig loses. Trig does
not duplicate more memory per checker than tsrs does, its page walks stay at
2% of user cycles or less, and its yield checks cost about 1-1.5% of cycles
at most. What loses at four checkers is serial and single-thread work: the
parse and bind before checking (about 16-17 ms more than tsrs4 on zod3 and
ts-pattern), the check phase's single-thread speed (45 ms of ts-pattern's
68 ms gap), and kernel memory work that grows with the number of checkers.

## The table

Each cell gives its unit. "Tonight" means measured 2026-11-01 02:21-02:26 on
pup P-cores, Trig `806e0a1` (trig#231 included) by Rig `928b44bf2`. The other
cells name the record they come from.

| cost | empty, 1 | empty, 4 | zod3, 1 | zod3, 4 | ts-pattern, 1 | ts-pattern, 4 |
|---|---|---|---|---|---|---|
| **1. Serial head** (share of wall; PGO; tonight). Parse+bind / everything outside Check time | 70% / 100% (no checking) | 56% / 96% | 16% / 23% | 28% / 43% | 3.4% / 5.9% | 9.0% / 18% |
| ...tsrs, same measure | 55% / 100% | 49% / 100% | 13% / 21% | 15% / 36% | 2.4% / 4.4% | 5.0% / 14% |
| ...Amdahl ceiling (1 / serial share) | 1.0x | | 4.4x (tsrs 4.9x) | | 17x (tsrs 23x) | |
| **2. Single-thread codegen** (share of user cycles, PGO, one checker) | not measured | not measured | checks 6.4%; store forwarding 0.2%; indirect calls pending (row 40) | estimate ~3.6% of wall (6.4% x check share 56%) | checks 5.9%; store forwarding 1.1%; indirect calls pending (row 40) | estimate ~4.8% of wall (5.9% x 82%) |
| | | | codegen-gap.md | derived | codegen-gap.md | derived |
| **3. Memory duplicated per checker** (4-over-1 ratios, PGO; tonight). RSS: Trig vs tsrs | | 1.09 vs 1.63 (+2.6 vs +11.0 MB) | | 1.47 vs 1.59 (+36.7 vs +31.7 MB) | | 1.12 vs 1.13 (+20.3 vs +25.2 MB) with the gate shut; 1.23 with it open |
| ...dTLB walks completed: Trig vs tsrs | | 1.35 vs 2.75 | | 1.97 vs 1.65 | | 0.87 vs 0.60 |
| ...cycles with a page walk active, as a share of user cycles: Trig (tsrs) | 1.0% (1.0%) | 1.3% (1.7%) | 1.5% (0.9%) | 2.0% (1.0%) | 2.2-2.5% (1.7%) | 2.0% (1.2%) |
| ...kernel cycles, share of all cycles: Trig (tsrs) | 28% (32%) | 37% (35%) | 13% (10%) | 17% (11%) | 7.4% (5.7%) | 10.6% (6.3%) |
| **4. Yield checks: upper bound** (turn and tickCall compiled out; plain release; tonight). Fewer instructions / fewer cycles / less wall (median, fastest in brackets) | 3.8% / 1.8% / 0.4% (3.0%) | 3.8% / 1.1% / 3.5% (4.2%) | 3.6% / 1.5% / 1.1% (1.5%) | 3.2% / 1.4% / 1.3% (0.9%) | 4.0% / 0.8% / 0.9% (1.3%) | 4.0% / 0.9% / 0.1% (1.1%) |
| ...earlier (trig-zig-ceiling.md, Oct 27, plain, one checker) | | | 3.35% / 1.74% / 2.86% | | 4.00% / 1.48% / 1.38% | |

## Trig4 against tsrs4, by phase (PGO, medians, ms; tonight)

The gap is split by Trig's and tsrs's own `--extendedDiagnostics` clocks.
"Other serial" is wall less Check time less parse and bind: start-up, config,
making the checkers, global diagnostics, reporting, and exit.

| project | Trig4 wall | tsrs4 wall | gap | parse+bind | check | other serial |
|---|---:|---:|---:|---:|---:|---:|
| empty | 26.7 | 22.9 | 3.9 | 3.7 (14.9 vs 11.2) | 0.9 | -0.7 (10.9 vs 11.6) |
| zod3 | 98.3 | 69.1 | 29.3 | **17.2** (27.6 vs 10.4) | 11.3 (55.5 vs 44.2) | 0.7 |
| ts-pattern | 312.5 | 244.4 | 68.1 | 15.9 (28.1 vs 12.2) | **44.7** (254.9 vs 210.2) | 7.5 (29.5 vs 22.0) |

At one checker the check phase is 1.11x tsrs's on ts-pattern and 1.21x on
zod3. At four it is 1.21x and 1.26x. So on ts-pattern about 15-20 ms of the
44.7 ms check gap at four comes from scaling: the kernel's memory work (Trig4
spends 100 ms of system time against tsrs4's 54) and the huge-page gate's
lottery (below). The rest is single-thread speed.

On empty, Trig4 is 5.6 ms slower than Trig1: parse and bind the same, check
0.9 ms more, and other serial work 4.5 ms more. That is the item-15 checker
construction, which checker-tasks stacked on #832 cut 2.9% (item15-stacked.md).

## Method

- **Builds.** `base` and `noyield`: Trig `806e0a1` (`src/`, `tools/trig` by
  `git archive`, `tools/trig/main.rig` as root), emitted by `rig build
  --release` at Rig `928b44bf2` (tools/baseline) with a stand-in Zig. Each was
  compiled on the Mac through tools/heavy as `zig build-exe -Osafe
  -fomit-frame-pointer -target x86_64-linux.7.0...7.0-gnu.2.43
  -mcpu=meteorlake`, then copied to pup. They are plain release builds, not
  PGO. `.text` identity with a build made on pup is untested, because no pup
  build of this package exists. `noyield` makes `rig.turn` and
  `rig.tickCall` return at once (`noyield.patch`, trig-zig-ceiling's
  `noyield.patch` on today's runtime). Its `.text` is 2.2% smaller. It has
  3,354 turn sites and 387 entry flags. `pgo` is standing-6's PGO build of
  the same commits (Rig - Merges; `/zfs/worktrees/rig/standing-6/trig/bin`,
  sha256 `e65925ff31ff785e`), read-only. tsrs is the shipped 0.18.0 in Go mode
  (`--checkerAssignment go --noLazyMembers`).
- **Timing.** pup, Swiss's slot. One checker ran on P-core 6 with sibling 7
  idle (`--singleThreaded`; tsrs with `RAYON_NUM_THREADS=1`). Four ran on
  0,6,8,10 with siblings idle. perf and time ran on E-cores. There were 8 arms
  and 20 rounds per project, with the first arm rotated each round, and every
  run used `--extendedDiagnostics`. Each run recorded `perf stat` (wall,
  user and kernel cycles, user instructions, faults, dTLB load and store
  `walk_completed` and `walk_active`) and peak RSS (`/usr/bin/time`). All
  480 runs printed the same diagnostics as tsrs1, with the statistics lines
  left out. Load average was 3.0-3.9, and two rounds waited for the cores.
- **Phases.** Trig's and tsrs's clocks round each phase to 1 ms, so the
  tables use means over 20 runs. "Everything outside Check time" (wall less
  Check time) is the true serial share, because only Trig's `check_groups`
  runs in parallel.
- **Huge-page gate.** On ts-pattern, Trig's runs split in two by faults:
  about 14.7k (gate open) and 39.4k (shut) at one checker, 32k and 47.9k at
  four. Open runs are 3-4% faster and use 4% more RSS at one checker and 14%
  more at four. The split fell differently per arm (pgo1 11 open, pgo4 4
  open). `modes.txt` gives each mode, and the RSS ratio above is given per
  mode. empty and zod3 ran in one mode throughout. The no-yield comparison
  is the same within the shut mode alone (`modes.txt`).
- **Reused.** codegen-gap.md (checks, store forwarding), trig-zig-ceiling.md
  and sched-check/ (yield checks), tsrs-standing-5.md and scaling-2.md (RSS
  and dTLB at 4-over-1 on older builds; tonight replaces them), item 15 and 16
  notes (head on E-cores, checker construction). Row 40 (Rig language
  analysis) is measuring indirect calls; it is cited as pending.

## Fix first, ranked by reach at four checkers (against tsrs4)

1. **Parse and bind: the serial head (Trig).** It takes 17 ms of zod3's 29 ms
   gap (17% of Trig4's wall) and 16 ms of ts-pattern's (5%). On empty it is
   3.7 ms (14%). Paths: libraries parsed ahead in tasks (lib-parse-ahead:
   superstruct 12%, mitt 10% less at four; zod3 0.6%), parser speed (#231
   landed tonight; Trig still parses in 20.6 ms what tsrs does in 10.4 at
   four), and a parallel bind (7 ms against tsrs's 0; it needs a design
   round, bind-design.md). Realistic: 8-12 ms on zod3 (8-12%), 5-10 ms on
   ts-pattern (2-3%).
2. **Check-phase single-thread speed (Trig mostly, Rig partly).** It takes
   45 ms on ts-pattern (14%) and 11 ms on zod3. Rig's share: checks 5.9-6.4%
   of user cycles, but the sound part a proofs pass reaches is 0.4-0.8%
   (proof-pass.md). Store forwarding is 0.2-1.1%. Indirect calls are pending
   (row 40). The rest is Trig's data and algorithm (codegen-gap.md).
   Realistic Rig-side: 1-2% from these.
3. **Kernel memory work that grows with checkers (Rig).** Trig4's kernel
   cycles are 17% of zod3's cycles and 10.6% of ts-pattern's, against tsrs4's
   11% and 6.3%. System time is 46 against 28 ms on zod3 and 100 against 54
   on ts-pattern. That is about 5 ms of zod3's wall and about 10-12 ms of
   ts-pattern's at four. A gate that opens reliably at four checkers is worth
   3-4% on ts-pattern by itself, but costs 14% more RSS there.
4. **Making the checkers and the other serial work (Trig on #832).** This is
   the 4.5 ms Trig4 loses to Trig1 on empty, and 7.5 ms on ts-pattern.
   checker-tasks stacked on #832 cuts it by about 3% on small projects
   (item15-stacked.md). Realistic: 1-4 ms.
5. **Yield checks (Rig).** The upper bound is 0.8-1.8% of cycles and 0.1-1.3%
   of wall by the median, with 3.2-4.0% of instructions. sched-check found no
   sound check that is cheaper. Row 36's sound "ver" form (std scan loops)
   reaches about 1.2-1.4% of instructions on small projects and nothing on
   large ones. Realistic: under 1%.
6. **dTLB walks (Rig and Trig).** These are 2% of user cycles at most, and
   about 1 point more than tsrs on zod3 and ts-pattern. Per-checker
   duplication is no worse than tsrs's (RSS 4-over-1 lower or equal). Last.
