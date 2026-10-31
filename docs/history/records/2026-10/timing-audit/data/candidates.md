# Timing audit, step 1: decisions that rest on a fixed build order (2026-10-30)

A read-only audit of records, PR bodies, bench PROGRESS files and harnesses
on `origin/main` 179c50afa, and the PRs created from 2026-10-19 on
(#398 to #796). Nothing was run on pup or the Mac.

## How the bias works

- **What it is.** The first run after a wait or a switch lands on a core
  that idled, at 3.8 GHz against 4.4 on pup. tsrs-standing-4 measured it
  under `time.sh`'s wait of about 1 s before each round:
  - 3-10% more wall time on the 25 ms projects;
  - about 2% on zod3 (about 150 ms);
  - nothing on ts-pattern at one checker (0.7-1.4 s).
- **Cycles go the other way on short runs.** The cold first variant took
  5-7% fewer user cycles on the 25 ms projects. A lower clock makes each
  memory stall cost fewer cycles. So on short runs "fewest user cycles"
  favors the first variant, and wall time penalizes it. On long runs
  neither moves.
- **Fastest-of-N does not fix it.** If the order is fixed, every run of
  the first variant is the cold one. Only rotating or alternating the
  order spreads the cost.
- **Which way a verdict leans.**
  - Reference first: the change looks faster. Gains that landed a
    change are overstated, and costs that were accepted are understated.
  - Change first: the change looks slower. A "slower, so held or
    closed" verdict is overstated.
- **How exposed a harness is.**
  - Strong: a quiet-core wait before each round, as in `time.sh`
    (`busy()`, five `ps` checks 0.2 s apart), or an unpinned
    multi-checker run that follows a pinned run.
  - Weak, not measured: runs back to back, where only Python or the
    shell runs between them. Examples are `census-time.py` and
    `trigtime.py` before #795, `pfmeasure.py`, and the bench drivers.

Run lengths, from the records:

| Workload | Length |
|---|---|
| ts-pattern, 1 checker | 0.7-1.4 s |
| ts-pattern, 4 checkers | 0.33-0.56 s |
| zod3, 1 checker | 0.14-0.27 s |
| zod3, 4 checkers | 0.15-0.17 s |
| tiny-invariant | 70-150 ms |
| superstruct, mitt, neverthrow | 25-46 ms |
| bench-json | about 400 ms a process, calibrated first |
| bench/hash, bench/tasks | every row inside one long process |

## The harnesses and their order

| Harness | Order | Wait before a round | Used for |
|---|---|---|---|
| `hash-race/tsrs-standing-data/time.sh` (standing-1, #739) | fixed, `main-pgo` first | `pgrep` only (weak) | Trig against tsrs, the steps #733/#735/#736 |
| `tsrs-standing-2-data/time.sh` (#756) | fixed, `773-pgo` (#754) first | `busy()` (strong) | #754's step, Trig against tsrs |
| `tsrs-standing-3-data/time.sh` (#771) | fixed, `1b2-pgo` (main) first | strong | main against 773978d1d, zod3's gap |
| `tsrs-standing-4-data/time-rot.sh` (#796) | rotated | strong | standing-4 (`time.sh`'s fixed runs were discarded) |
| `perf-stage/trig-zig-ceiling-data/time.sh` (#753) | fixed | `ps` check (weak to medium) | the ceilings |
| `perf-stage/scaling-2-data/time.sh` (#757) | fixed, `t773` first | `busy()` on cores 12-19 (strong) | scaling, Trig against tsrs |
| `hash-race/map-wide-keys-data/pup-time.sh` | fixed | `pgrep` only | memory decision |
| `hash-race/small-maps-data/trig-time.sh` | fixed, main then new | none | memory decision |
| `perf-stage/loop-hoist-data/time.sh` (#706) | fixed, one project per call | none | #706 landed on instructions |
| `prefault-lead/pfmeasure.py` (#674, #678) | fixed, main first after every project and mode switch | none, but 4 checkers unpinned after a pinned run | **#674, #678** |
| `prefault-lead/sweep.py` (#678) | fixed, threshold 0 (main) first | none | #678's threshold |
| `table-prefault/measure.py` (#699) | fixed | none | not taken |
| `alloc-seg-thp/sys-ts.sh` | fixed | none | sys-time study only |
| `compact-map/run.sh` (#606) | fixed | none | not taken |
| `consolidation/census/census.py` (json, benches) | fixed, ref first; each build is one whole bench run | none | censuses, #619 |
| `census/trigtime.py`, `census/census-time.py` before #795 | fixed, ref first after every project switch | none | censuses (10-23, 10-24, #789); likely the "pup core 3, fastest of N" PR timings (#780, #782) |
| `bench/json/bench-json` | fixed variant order within a run, calibrated first | none | std.json A/Bs |
| `bench/hash/bench-hash`, `bench-tasks`, `-actors`, `-net`, `-http` | fixed variant order; rows inside one process | none | bench rows |
| `bench/apis` (README loop) | fixed, `object` (the change) first | none | #612 |
| `alloc-*/measure.py`, `mimalloc-ceiling/measure.py` | **reversed every other round** | none | #676, #725, #726, #733, #740, #749, #750 |
| `perf-stage/thp-gate-data`, `thp-fragmented-data`, `thp-spare-data` `time.sh` | **rotated** | strong | #762, #764, #778 |
| `check-bisect-data`, `runtime-unchecked-data` `time.sh` | **rotated** | strong | #759, #761 |
| `map-stage`, `map-inline` `trigbench.sh` | **rotated** | — | #702, #703, #521 |
| `bounds-enum-data/ab.sh`, `jsonab.sh`; `list-grow-data/abk.sh`, `jsonab*.sh`; `memory-traffic-data/xtime.sh`; `rehash-counts-data/trigtime.sh` | **alternated** | — | #705, #697, #786 |
| `checks-data/timeit.py`, `mactime.py`; `safety-checks/len-map-data/timeit.py` | **rotated** | — | #672, safety checks |
| `sched-check-study/time-trig.py` (session home) | **alternated** | load wait | queue row 10 |

## Candidates, ranked by how likely the verdict is to flip

### 1. #678: a heap past two segments faults in ahead (landed 2026-10-25). HIGH

- **Decision.** Landed for zod3's time. Peak RSS rose 5.0-5.6% at four
  checkers, against the then bar of "peak memory no higher".
- **Numbers (wall).** ts-pattern had no gain:
  - 4 checkers: 0.522/0.515 → 0.524/0.515 s;
  - 1 checker: 1.244/1.248 → 1.280/1.232 s.

  The whole case is zod3:
  - 4 checkers: 0.170/0.162 → 0.160/0.155 s, 4-6% faster;
  - 1 checker: 0.251/0.243 → 0.239/0.233 s, 4-5% faster.

  zod3's page faults fell 35% at four checkers, but its sys time did not
  move (0.056/0.054 → 0.057/0.056). The 7-8% less user time is what a
  higher clock would give.
- **Run length, machine, harness.** zod3 0.15-0.25 s, on pup.
  `pfmeasure.py`: one checker on core 6, four checkers unpinned, fastest
  of 10 and of 20.
- **Order.** Fixed. Main ran first after every project and mode switch.
  Its four-checker runs followed a pinned one-checker run, so they landed
  on cores that had idled.
- **Could it flip?** Yes. Take 2-6% off main's side and zod3 is left
  between level and 4% faster. The sweep, also with main first, read
  zod3 at 8 MB as level with main (0.162 against 0.162 s).

### 2. standing-2: "#754 on zod3, 1.8% slower" (record #756; #754 landed 2026-10-28). HIGH for the claim, LOW for the decision

- **Numbers.** zod3:
  - wall 1.8% slower by the median, 2.9% by the fastest;
  - user cycles 0.1% more, instructions 0.2% more;
  - kernel cycles 2.7% fewer.

  ts-pattern: 3.8% faster, with 30% fewer kernel cycles.
- **Run length, machine, harness.** zod3 about 160 ms, on pup core 1.
  `tsrs-standing-2-data/time.sh`, with a strong wait before each round.
  20 rounds.
- **Order.** Fixed. `773-pgo` (#754) ran first in every round. This is
  exactly the case standing-4 measured, at about 2% on zod3.
- **Could it flip?** The claim, yes: #754's 1.8% slower on zod3 is about
  the bias, and the cycles show no loss. The decision, no: #754 landed
  on ts-pattern (long, also backed by cycles). The cost that remains is
  zod3's 7.5% peak memory, which is real. The claim should not be carried
  forward as a time cost.

### 3. #525: the first prefault, while a program has one heap (landed 2026-10-21). MEDIUM

- **Numbers (wall).** ts-pattern 2.2% faster, against a 2% bar.
  zod3 3.5%, tiny-invariant 3.3% and mitt 5.9% faster. RSS rose from 397
  to 425 MB.
- **Run length, machine, harness.** ts-pattern about 1.3 s. The others
  are 30-270 ms. pup core 3, fastest of 10, "interleaved". The harness is
  not recorded. It is probably the measurement behind the backlog entry
  (pfmeasure's predecessor).
- **Order.** Not recorded. pfmeasure-style is fixed with the reference
  first.
- **Could it flip?** The short projects' gains could all be bias.
  ts-pattern does not depend on order, but at 2.2% it was only just over
  the bar. The rule was later found not to fire in Trig at all once
  Trig's main became a fiber (prefault-lead, 2026-10-24). #674 replaced
  it, so a rerun is moot: rerun #674 and #678 instead.

### 4. Censuses and "within 2%" gates timed with the reference first. MEDIUM-LOW

These are the "nothing slower" verdicts:

| Census or PR | Harness | Backed by cycles? |
|---|---|---|
| speed-baseline, 2026-10-23 (#577) | `trigtime.py`, ts-pattern and zod3 | no: wall only on Linux |
| census, 2026-10-23 night | `trigtime.py` | no |
| census, 2026-10-24 (#653) | `trigtime.py` | no |
| census, 2026-10-30 (#789) | `census-time.py` before #795, six projects | yes: user cycles |
| #621's accepted Trig cost (pup 0.5-0.8% slower, zod3 0.7-0.8%; "within 2%" was the condition to land) | not recorded | no |
| #566's u-timing (zod3 0.3%, tiny-invariant 1.0% slower) | not recorded | no |

- **Which way it leans.** With the reference first, the newer build
  looks faster, so a regression on zod3 of up to about 2%, or 3-10% on
  the small projects, could hide under "within 2%".
- **#789.** The verdict stands. Main had 1.6-2.2% fewer user cycles on
  every project, and on short runs the cycle bias favors the reference.
  So main's cycle gain is, if anything, understated (#795 says the same).
- **The 10-23 and 10-24 censuses, and #621.** These are wall time only.
  On zod3 a 2-4% regression could have been masked.
- **The timing only (no cycles):**
  - ts-pattern is reliable, so the 10-24 typecheck creep (a `rig check`
    of 3-6 s) stands;
  - zod3 is open.

### 5. #674: the heap that does the program's work faults in ahead (landed 2026-10-25). MEDIUM-LOW

- **Numbers (wall).**
  - ts-pattern, 1 checker: 2.1-2.9% faster (1.406/1.374 → 1.367/1.346
    s), with sys time 10 ms lower and 53% fewer faults.
  - zod3, 1 checker: 4.0-7.2% faster (0.268/0.257 → 0.250/0.247 s).
  - 4 checkers: within noise.
  - RSS 4-6% higher.
- **Run length, machine, harness.** ts-pattern about 1.37 s, zod3 0.25
  s. pup, `pfmeasure.py`, fastest of 10, two sets.
- **Order.** Fixed, main first.
- **Could it flip?** Not on ts-pattern, whose time does not depend on
  order and whose sys time explains part of the gain. ts-pattern alone
  carried it over the 2% bar of the time. zod3's gain is likely 2% or
  more smaller than reported. The verdict probably holds, by a thin
  margin.

### 6. #514: an object's flag optional in one store (landed 2026-10-21). LOW-MEDIUM

- **Numbers.**
  - Headline: the binder's fastest bind 16.66 → 15.47 ms, 7.1% faster
    (pup E-core).
  - Behind it: on full runs, ts-pattern cycles 1.3% fewer and zod3 1.8%
    fewer; blocked loads 79% fewer in the binder bench and 38% fewer on
    ts-pattern; Mac 1.3%.
- **Run length, machine, harness.** The bind is a 16 ms phase at the
  start of each process, which is where the clock is low. It was the
  panel's prototype. Order not recorded.
- **Could it flip?** The 7.1% headline may be mostly bias. The landing
  verdict rests on cycles and blocked loads, so it holds.

### 7. #782: loop-tick (held). LOW

- **Numbers.** On ts-pattern, all three readings agree:
  - wall: 2.6% slower;
  - cycles: 3.936G → 4.033G, 2.5% more;
  - instructions: 9.568G → 9.782G, 2.2% more.

  zod3 2.1% slower and superstruct 1.3% slower, both wall.
- **Run length, machine, harness.** ts-pattern about 0.9 s, zod3 about
  0.2 s, superstruct about 31-46 ms. pup core 3, 10 rounds, release
  builds. The harness is not recorded; the counters it reports match
  `census-time.py` before #795.
- **Order.** Probably fixed, with main a8acfdc5c first, but not
  recorded.
- **Could it flip?** No. ts-pattern is long, and its extra instructions
  and cycles fail the bar (more than 1.5% faster, or at least 1% fewer
  instructions) whatever the order. If main ran first, zod3's and
  superstruct's losses are understated. If the branch ran first, they
  could vanish, but they decide nothing. The benchmarks-game rows
  (ray, fannkuch) are multi-second runs, and are unaffected.

### 8. #778: the huge-page spare of 64 (landed 2026-10-30). LOW

- **Numbers (median wall).**
  - ts-pattern at the idle level: 5.8% faster than 128, 7.0% faster
    than no huge pages (747 against 784 and 795 ms). Faults fell from
    40k to 15k.
  - Partly fragmented: the spare of 64 never stalls, where 32 stalled in
    17 of 20 runs and 16 ran 33.5% slower.
  - zod3 rows (141-161 ms) moved 0.1-4.5%.
- **Machine, harness.** pup P-core 1. `thp-spare-data/time.sh`, six PGO
  arms, 20 rounds a level.
- **Order.** Rotated: the arms are rotated each round. In the frag
  modes every run starts after the same frag setup and a 2 s sleep, so
  all arms are treated alike.
- **Could it flip?** No. ts-pattern is long, the stalls are 33-96%, and
  zod3's small rows are unbiased. The one caveat: 64 against 128 at the
  quiet level is "1.4% slower" on ts-pattern, which is within six PGO
  builds' noise, as the record says.

### 9. Records whose measurements rank work, with no decision flipping. LOW

- **trig-zig-ceiling (#753).** Fixed order with a per-round check.
  zod3's unchecked ceiling of 7.5% may be about 2% high. Its cycles were
  8.3% fewer, so the ranking stands. "Partial inlining 0.9% slower" is
  small either way.
- **standing-3 (#771).** Main (`1b2-pgo`) ran first, so its zod3 reading
  of "0.2% slower than 773978d1d" is likely 1-2% faster in truth.
  zod3's 1.33× against tsrs is a little high. standing-4 already notes
  this.
- **standing-1 (#739).** `main-pgo` ran first, so zod3's 1.37× is a
  little high. The plain-build steps were not first.
- **scaling-2 (#757).** Fixed order with `t773` (Trig) first and a
  strong wait. The ms-level phase claims for zod3 at 4 and 8 checkers
  carry a 2-5% bias against Trig.

### 10. Accepted costs and choices that cannot flip toward a different action. LOW

- **#612, bench/apis.** 2.5% slower on pup. The change (`object`) ran
  first, and runs are 900 ms on pup, so the cost is if anything
  overstated.
- **#565, R4's placement swing.** Accepted. Each bench-json process
  calibrates first, so its timed runs follow warm ones.
- **#617, the Mac's safe std.json 4-7% slower.** #617 was last in its
  run and consistent over three run orders.
- **#619, canada slower.** Accepted.
- **#624, "bound 3 beat 4 by 9%", and #683, the c and d locks.** loco on
  the Mac. The decisive rows run 1.4-5 s. The 43% sys and the
  oversubscription p90 are over 10%.
- **#718, iterator chains.** 4.8 ms runs on the Mac with 3% gaps. The
  design does not rest on them; the adapter's 26% is over 10%.
- **Not taken, where a reference-first bias would only have favored the
  arm that lost:**
  - #606 and #608: Map experiments, bench/hash rows inside one process;
  - #699: table prefault;
  - #679: huge pages for large tables, superseded by #754;
  - #686 and #687: closed on instructions.

## Unaffected

- **Order rotated or alternated:**
  - #676, #725, #726, #733, #740, #749, #750 (`alloc-*/measure.py`
    reverses every other round);
  - #762, #764, #778 (rotated);
  - #759, #761 (rotated);
  - #702, #703, #521 (rotated);
  - #705, #697, #786 (alternated);
  - #785 (both orders run).
- **Decided on instructions or cycles, or on long runs:** #536, #538,
  #677, #682, #696, #706, #710, #711, #729, #735, #736, #755, #780 (on
  ts-pattern, with cycles), #786.
- **Differences over 10%:** #405, #407, #468, #478, #496, #521, #524,
  #621's spawn on the Mac, #698, #724, #785.
- **The bench PROGRESS files** hold single-build rows, not A/B verdicts.
  Their A/B claims live in the PR bodies above.

## Rerun plans on pup, order rotated

General rules for every rerun:

- **The quiet protocol.** Follow the queue's pup lane rule 4: the
  timing runs on a P-core with its sibling idle, and builds stay on the
  E-cores through `slot.sh` (`TRIG_RELEASE_SLOTS="12,13 14,15 16,17"`).
  Avoid the cron hours.
- **Separate binaries.** Never a switch inside one binary.
- **Rotated harnesses.**
  - Six projects at one checker: `census/census-time.py` from main
    (rotated since #795). It keeps the fastest wall, the fewest user
    cycles and instructions, and the peak RSS.
  - Medians with perf counters at one checker: `tsrs-standing-4-data/time-rot.sh`.
  - Four checkers: `alloc-grow/measure.py` with `FOUR=1`. It pins cores
    0,5,6,7, reverses the order every other round, and gives medians,
    user and kernel cycles, faults and RSS.
- **Twenty rounds** each.

**1. #678.**
- **Faithful A/B.** Trig `8e2f21f`, release, built by Rig `c2639a40f`
  (the parent) and by `f3dff92f3` (#678's merge).
  - `alloc-grow/measure.py 20 main=... change=...`, at one checker;
  - then the same with `FOUR=1`;
  - then `census-time.py 20` on the six projects.
- **Whether it still pays on main**, after #740, #754, #764 and #778:
  main against main with `prefault_big` set out of reach (one-line arm,
  `src/alloc.zig`), Trig `2ba0719` PGO, the same three runs.
- **Rule.** Keep it only if zod3 or ts-pattern is more than 1.5% faster
  by the median, or user plus kernel cycles are at least 1% fewer. If
  not, its 5% peak memory argues for removing it.

**2. #754 on zod3.**
- Use standing-2's cached binaries, `2c0-pgo` (Rig `2c01f07dd`) and
  `773-pgo` (`773978d1d`, #754).
- Run `time-rot.sh` with `V="2c0-pgo 773-pgo"` and
  `PROJS="zod3 ts-pattern"`, on core 6.
- Expect zod3 level; if so, correct the claim in the next standing
  record.

**3. #674 (and #525 through it).**
- Trig `a16e538` built by Rig `12b0bdc88` (the record's main; the merge
  parent is `15866c096`) and by `e0857bbb5` (#674's merge).
- Run `alloc-grow/measure.py 20` at one checker, then `census-time.py 20`
  on the six projects.
- The question: is ts-pattern still more than 1.5% faster, and how much
  of zod3's 4-7% survives?
- #525 itself (`41ea93eab` against `eaf00e094`) needs the Trig of
  2026-10-21 and is superseded. Skip it unless the owner wants it.

**4. The wall-only censuses and gates.**
- Re-time with `census-time.py 20` on the six projects, with a Trig
  that every build in a pair can build:
  - the 2026-10-24 census: `f55fe3d9a` against `122597c52`;
  - #621: `f8366f090` against `29f8cb5a8` (the parent and the merge);
  - #566: its parent against its merge.
- Flag any project slower than 2% by wall that the original run called
  within 2%.

**5. #782**, for the record only.
- Rig `a8acfdc5c` against `e62feea16` (rebased only if queue row 10
  revives it), Trig `2ba0719` release.
- Run `census-time.py 20` with `CORE=3`.
- Expect ts-pattern still about 2.5% slower in cycles and instructions.
  zod3's and superstruct's walls are the only readings order can move.

**6. #778.** No rerun needed: its harness already rotates. To confirm
zod3 alone, run `thp-spare-data/time.sh` with `MODES="natural normal"`
and `V="s128 s64 never"`.

**7. #514.** Optional. Trig's binder bench (checker.ts) built by #514's
parent and merge. Alternate the order, and read user cycles and blocked
loads, not the 16 ms phase's wall.
