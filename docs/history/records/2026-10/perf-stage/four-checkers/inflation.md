# Four checkers: work inflation from one to four (2026-11-01)

Question (Trig's owner, narrowed by the coordinator): why does Trig's check
phase at four checkers lose more to tsrs than at one? This part covers the
user-side cost per thread: duplicated work, the same work running slower,
and balance. Kernel time (faults, mmap, the huge-page gate) belongs to
another agent and appears here only as totals.

Measurement only: nothing built, edited or committed. Binaries: Trig
`806e0a1` PGO (`/zfs/worktrees/rig/standing-6/trig/bin`), tsrs shipped 0.18.0
in Go mode (`--checkerAssignment go --noLazyMembers`). Scratch, scripts and
raw data on pup: `/zfs/worktrees/rig/four-checkers/inflation/` (`stat.txt`
counters, `rec2/` and `rec3/` profiles, `one.txt`, and the scripts
`stat.sh`, `rec2.sh`, `ana2.py`, `win.py`, `rank.py`, `bal.py`, `grow.py`).

**E-core numbers are relative.** One thread ran on E-core 18, four on 16-19.
Those four cores are one cluster sharing a 2 MiB L2, so contention there is
worse than on P-cores, where each core has its own L2. Builds by other
sessions ran on 12-17 throughout and sometimes on 16-19 (the scripts waited
for those cores to be free before each run). Absolute times moved by up to
15% between batches, so only ratios within a batch are used. P-core
figures come from Swiss's audit tonight ([conc-audit.md](../conc-audit.md), 20 rounds)
and standing-6.

## Short answer

Trig's per-thread inflation from one to four is the same as tsrs's. Both
duplicate the same work (the same type and instantiation counts) and lose
about the same IPC. What makes Trig scale worse on ts-pattern is where its
single-thread excess sits. Almost all of the instructions Trig executes
beyond tsrs are in the heaviest checker's files. At one checker that
excess is spread over the whole run; at four, that checker is the critical
path, so the excess counts in full against the wall.

## 1. Duplicated work: the same in both

`--extendedDiagnostics` counts, summed over the checkers:

| | Trig 1 | Trig 4 | growth | tsrs 1 | tsrs 4 | growth |
|---|---:|---:|---:|---:|---:|---:|
| ts-pattern Types | 508,937 | 554,766 | 9.0% | 506,567 | 549,079 | 8.4% |
| ts-pattern Instantiations | 3,638,908 | 3,772,526 | 3.7% | 3,638,700 | 3,754,264 | 3.2% |
| ts-pattern Symbols | 954,642 | 1,030,377 | 7.9% | 933,321 | 1,011,581 | 8.4% |
| zod3 Types | 90,910 | 154,598 | 70% | 90,555 | 153,730 | 70% |
| zod3 Instantiations | 287,551 | 465,783 | 62% | 287,438 | 465,216 | 62% |
| zod3 Symbols | 199,073 | 318,079 | 60% | 178,125 | 297,365 | 67% |

User instructions, exact counters (perf stat; the counts do not depend on
the core type):

| | Trig 1 → 4 | tsrs 1 → 4 |
|---|---|---|
| ts-pattern | 7.963G → 8.389G, 5.3% more | 7.225G → 7.673G, 6.2% more |
| zod3 | 1.391G → 1.904G, 37% more | 1.203G → 1.692G, 41% more |
| mitt | 0.169G → 0.176G, 4% more | 0.125G → 0.189G, 51% more (rayon) |

Which Trig functions grow (shares from `perf record` scaled to the exact
totals; noise is about ±20M per function):
- ts-pattern: checker code is 342M of the 426M extra instructions and 547M
  of the 606M extra user cycles (E-cores). The largest growth is in
  `resolve_structured_type_members_worker`, `mapper_map`,
  `get_type_from_type_node_worker`, `set_structured_type_members` and
  `instantiate_type_with_alias`. Rig's runtime: alloc and memcpy add 43M
  instructions and 40M cycles (34% more, from a small base). Tables and
  the scheduler add nothing measurable.
- zod3: checker code is 459M of the 513M extra instructions:
  `set_structured_type_members` (76M), `instantiate_type_with_alias` (73M),
  `resolve_structured_type_members_worker` (66M), `extend_export_symbols`.
  Each checker resolves the lib and global types again. Alloc adds 44M
  instructions and 12M cycles.

Duplicated instructions are cheap. With four checkers on one E-core (Trig
runs them on one worker, one after another), ts-pattern executes 5.3% more
instructions in only 1.7% more user cycles, because IPC rises from 1.81 to
1.88. zod3 executes 37% more instructions in 35% more cycles.

## 2. The same work running slower: about equal

User IPC, one thread → four:

| | Trig | tsrs |
|---|---|---|
| ts-pattern, P-cores (audit, gate open) | 2.507 → 2.471, 1.4% lower | 2.497 → 2.487, 0.4% lower |
| ts-pattern, P-cores (standing-6) | 2.39 → 2.39 | 2.43 → 2.44 |
| zod3, P-cores (audit) | 2.38 → 2.31, 3.1% lower | 2.50 → 2.41, 3.6% lower |
| ts-pattern, E-cores | 1.74 → 1.62, 6.9% lower | 1.77 → 1.68, 5.1% lower |
| zod3, E-cores | 1.62 → 1.53, 5.6% lower | 1.70 → 1.65, 2.9% lower |

On E-cores, L2 misses per thousand instructions grow 47% for Trig (4.40 to
6.45) against 39% for tsrs (3.68 to 5.05) on ts-pattern, and 35% against
27% on zod3. The cluster's shared L2 makes Trig's larger footprint show
more there. On P-cores the difference is about one point of IPC on
ts-pattern and nothing on zod3.

User cycles, one → four, P-cores (audit): ts-pattern Trig 6.9% more, tsrs
6.6% more; zod3 Trig 41% more, tsrs 46% more. The difference on ts-pattern
is about 10M cycles, about 0.5 ms at four.

Waits: Trig's context switches do not grow with checkers (712 at one, 745
at four on ts-pattern; zod3 768 to 797), so its checking threads do not
park or futex-wait while they check. The roughly 700 switches even at one
checker come from the runtime's monitor thread, which wakes about every
millisecond (about 8M kernel cycles per run, off the critical path).
tsrs's grow from 69 to 409 (rayon). Migrations stay at 0 to 2.

## 3. Balance: where Trig loses

Each checker thread's checking span and its sampled instructions and
cycles, E-cores 16-19, medians of 12 runs (ts-pattern) and 30 (zod3).
Ranks are by instructions; with the same Go partition, rank 1 is the same
checker in both tools. Trig's rank 1 runs on the main thread, and its
counts are taken inside its checker window only. Sampled counts are scaled
to each tool's exact totals.

ts-pattern:

| rank | Trig instr | tsrs instr | Trig vs tsrs | Trig IPC | tsrs IPC | Trig cycles vs tsrs |
|---|---:|---:|---|---:|---:|---|
| 1 | 3.12G (38.4%) | 2.48G (33.2%) | 26% more | 1.90 | 1.82 | 22% more |
| 2 | 1.99G | 2.06G | 4% fewer | 1.53 | 1.57 | |
| 3 | 1.61G | 1.50G | 7% more | 1.44 | 1.56 | |
| 4 | 1.41G | 1.42G | the same | 1.36 | 1.59 | |
| 2-4 | 5.01G | 4.98G | 0.5% more | | | 10% more |

- Trig executes 716M more instructions than tsrs at four checkers, and
  646M of them are in rank 1, the heaviest checker. Ranks 2-4 execute the
  same instructions as tsrs but take 10% more cycles (lower IPC under
  contention).
- At one checker Trig executes 738M more instructions than tsrs, about
  the same excess. So the excess belongs to particular files (rank 1's),
  not to duplication.
- In rank 1, `instantiate_type_with_alias` is 25.2% of instructions
  (19.6% in ranks 2-4) and `mapper_map` 11.2% (7.4%). The instantiation
  count matches tsrs's (0.5% more), so Trig spends more instructions per
  instantiation on these files. tsrs is stripped, so this cannot be
  compared function by function.
- Checking spans (one clean run): Trig 486, 396, 336 and 315 ms. Busiest
  over mean: Trig 1.27, tsrs 1.21 (12-run medians: Trig 1.274, range
  1.262-1.293; tsrs 1.213, range 1.197-1.238).

zod3: Trig's excess is spread over ranks 1-3 (10%, 32% and 22% more
instructions than tsrs; rank 4 the same). Busiest over mean: Trig 1.20,
tsrs 1.23. On zod3 Trig's balance is the better one.

## 4. The check phase at four, P-cores (audit means)

| | check 1 | check 4 | speed-up |
|---|---:|---:|---:|
| Trig, gate open | 683.5 ms | 249.2 ms | 2.74 times |
| Trig, gate shut | 708.0 ms | 256.3 ms | 2.76 times |
| tsrs | 624.8 ms | 210.2 ms | 2.97 times |
| zod3 Trig | 113.4 ms | 55.5 ms | 2.04 times |
| zod3 tsrs | 93.5 ms | 44.3 ms | 2.11 times |

If Trig scaled as tsrs does, its ts-pattern check at four would take 230
ms: 19 ms less. This report estimates that split as follows:
- Balance, from the excess concentrated in rank 1 (busiest over mean 1.27
  against 1.21): 249 × (1 − 1.21/1.27) ≈ 12 ms.
- Kernel cycles growing with checkers: Trig 127M more cycles at four,
  tsrs 31M more. The difference of 96M cycles is about 21 ms of CPU, about
  5 ms of wall over four checkers. The other agent owns this.
- User-side inflation: Trig's IPC loss is one point larger, but it
  duplicates 0.9 points fewer instructions. About 0-2 ms.

That totals 17-19 ms. On zod3 the check phase scales almost equally (1.8
ms); its gap at four is the serial head (audit).

## Ranked causes, ts-pattern at four checkers (P-cores; ms estimated from E-core ratios)

1. **Trig's extra instructions on the heaviest checker's files (Trig's
   checker code).** Rank 1 executes 26% more instructions than tsrs's for
   the same files and the same instantiation count, mostly in
   `instantiate_type_with_alias` and `mapper_map`. It sets the check
   wall at four: Trig's rank 1 takes 22% more cycles than tsrs's, close
   to the check gap at four (19% more, 249 against 210 ms). Fixing it
   would bring rank 1 down to about rank 2, and Trig's check at four to
   about 200 ms (tsrs 210). Estimated win: 35-50 ms at four, about 12-15% of
   Trig4's wall, against about 9% of instructions at one. It covers about
   12 ms of the "scaling" 19 ms and most of the "single-thread" 25 ms in
   the audit's split. Confidence: medium-high that the excess sits in rank 1
   (exact totals, consistent over 12 runs); medium on which functions,
   since tsrs has no symbols. Next step for Trig: profile rank 1's files
   (Go's checker 0) against tsrs, one checker at a time.
2. **Kernel memory work growing with checkers (Rig's allocator and Tables,
   the other agent's).** About 5 ms of the check at four.
3. **Lower IPC under contention on ranks 2-4 (unknown owner: Trig's data
   layout or Rig's allocator).** The same instructions as tsrs take 10%
   more cycles on E-cores. It costs nothing today, because it is off the
   critical path. Once cause 1 is fixed, rank 2 becomes the critical path,
   and this then costs about 10% of it, about 20 ms on E-cores. It
   matters after cause 1.
4. **Duplication and the Rig runtime's share of the growth.** These match
   tsrs's: types 9.0% against 8.4% more, instructions 5.3% against 6.2%
   more. Alloc, tables and the scheduler add under 1.5% of cycles. Worth
   0-2 ms; no action.

## Most surprising

Trig executes the same instructions as tsrs on three of its four checkers.
Its whole 10% instruction excess on ts-pattern sits on the one checker that
sets the wall at four. So a single-thread speed problem in Trig's
instantiation path shows up as "poor scaling".

## Memory mode

buddyinfo (Normal, orders 9 and 10) ranged from 47-116 and 0-84 during the
batches. Trig1 on ts-pattern always faulted about 14.7k times (gate open);
Trig4 was mixed, 40-48k (mostly shut). zod3 and tsrs were in one mode.
Each batch's line in `stat.txt` records its buddyinfo reading.
