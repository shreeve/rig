# Why Trig loses more than tsrs from one checker to four (2026-10-28)

The owner's question: why are Trig's workers so much slower than tsrs's?
The fact to explain, on pup: Trig's PGO build is 1.19× shipped tsrs at
one checker on ts-pattern (1.37× on zod3, [tsrs-standing-2.md](../hash-race/tsrs-standing-2.md)),
about 1.35× tsrs in Go order at four checkers, and about 1.49× tsrs's
default mode. This record redoes [scaling.md](scaling.md) (2026-10-24)
on today's builds, splits the loss from one checker to four into its
parts by milliseconds of wall time, and names who owns each.
Measurement and diagnosis only; no code changed. Scripts and summaries
are in [scaling-2-data/](scaling-2-data/); the raw perf traces stay on
pup in `/zfs/worktrees/rig/scaling-2/`.

## Setup

- **Builds.** The two Trig PGO binaries tsrs-standing-2 timed (Trig
  `403a823`): by Rig main `773978d1d` (#754, huge pages for Tables past
  2 MiB) and by `2c01f07dd` (main before #754), in
  `/zfs/worktrees/rig/tsrs-standing-2/packs/`. "Trig" below is the
  `773978d1d` build; `2c01f07dd` is timed beside it for #754. Shipped
  tsrs 0.18.0, in Go order (`--checkerAssignment go --noLazyMembers`, as
  the standing times it) and in its default mode. Every run's output was
  checked: Trig at 1, 2, 4 and 8 checkers and both tsrs modes print the
  same bytes on both projects.
- **Cores.** Multi-checker runs on E-cores: one checker on 12, two on
  12-13, four on 12-15 (one E-core cluster, which shares its 2 MiB L2),
  eight on 12-19. One-checker runs for the scaling ratio on core 12 too,
  so every ratio here compares like cores; only ratios are compared, as
  in scaling.md. On an E-core Trig is 1.216× tsrs at one checker, against
  1.19× on P-core 1. Each batch waited until no other thread ran on its
  cores (and for Trig's full suite); load average 1.1 to 3.9 (other
  sessions built on 0,5, 6-9 and 10,11).
- **Tools.** `perf stat` (10 interleaved rounds for wall, 5 for
  counters); `perf record` of every context switch on the cores used,
  with uprobes on a copy of the Trig binary: each checker task's start
  (with its `k`) and end, each `check_source_file`, `FileLoader.load`,
  `new_checker`, and the fiber switch (`rig.sched.switchNaked`), so a
  checker's CPU time is known even when fibers share a thread; cycle
  profiles with call stacks per phase; traces of `mmap`, `munmap`,
  `mremap`, `madvise`, TLB flushes and IPIs; `RIG_SCHED_STATS=1`;
  `smaps_rollup` sampled every 5 ms; `--extendedDiagnostics` from both
  tools. Phases: the **head** is exec to the first checker's start, the
  **check** to the last checker's end, the **tail** to exit.

## 1. Wall time by checker count

10 interleaved rounds, E-cores, median (fastest), ms
([times-summary.txt](scaling-2-data/times-summary.txt)):

| ts-pattern | 1 | 2 | 4 | 8 |
|---|---:|---:|---:|---:|
| Trig | 1,315 (1,284) | 889 (856) | 555 (545) | 509 (489) |
| tsrs, Go order | 1,081 (1,057) | 728 (679) | 425 (402) | 310 (298) |
| tsrs, default | 1,062 (1,032) | 607 (582) | 358 (353) | 272 (268) |
| Trig / tsrs Go | 1.216 (1.215) | 1.223 (1.261) | **1.307 (1.354)** | 1.644 (1.639) |
| Trig / tsrs default | 1.238 | 1.465 | **1.550** | 1.874 |
| speedup: Trig, tsrs Go, default | | 1.48, 1.49, 1.75 | 2.37, 2.55, 2.97 | 2.58, 3.49, 3.91 |

| zod3 | 1 | 2 | 4 | 8 |
|---|---:|---:|---:|---:|
| Trig | 269 (264) | 238 (234) | 171 (165) | 167 (163) |
| tsrs, Go order | 201 (196) | 172 (167) | 117 (109) | 92 (90) |
| tsrs, default | 178 (175) | 126 (120) | 90 (87) | 82 (79) |
| Trig / tsrs Go | 1.339 (1.345) | 1.387 (1.402) | **1.468 (1.512)** | 1.803 (1.806) |
| Trig / tsrs default | 1.510 | 1.883 | **1.892** | 2.034 |
| speedup: Trig, tsrs Go, default | | 1.13, 1.17, 1.41 | 1.57, 1.73, 1.97 | 1.62, 2.18, 2.18 |

From one checker to four, Trig loses 7.5% against tsrs in Go order on
ts-pattern by the median (11% by the fastest) and 9.6% on zod3 (12%);
against tsrs's default mode, 25%. tsrs's own four-checker time varies
between sessions (ts-pattern 394 to 425 ms by the median), so the size
of the loss does too: 39 ms in the timing session, 69 ms in the
timeline session of section 3. At eight checkers Trig gains 8% over
four, tsrs in Go order 27%.

What one to four costs each tool in CPU, which both pay (5 rounds,
[counters-summary.txt](scaling-2-data/counters-summary.txt)):

| ts-pattern, 1 → 4 checkers | Trig | tsrs Go |
|---|---:|---:|
| task-clock | 20.3% more (1,307 → 1,572 ms) | 18.7% more (1,075 → 1,275) |
| user instructions | 5.3% more (each checker's own globals) | 6.2% more |
| user cycles per instruction | 9.6% more (0.563 → 0.617) | 8.6% more (0.532 → 0.578) |
| kernel cycles | 0.276G → 0.455G | 0.179G → 0.234G |
| page faults | 15.5K → 33.5K | 17.8K → 20.9K |
| TLB flushes | 730 → 7,549 | 94 → 198 |
| function-call IPIs | 0 → 4,193 | 0 → 53 |
| `munmap`, `madvise`, `mremap` calls | 114, 340, 117 → 556, 702, 231 | 9, 27, 0 → 52, 166, 0 |
| dTLB load misses | 3.0M → 3.5M | 0.42M → 0.34M |
| cycles stalled on page walks | 0.098G → 0.131G | 0.014G → 0.015G |
| LLC misses | 17.3M → 16.3M | 13.0M → 14.6M |
| memory traffic (system) | 2.2 GB in 0.58 s at four | 2.4 GB in 0.44 s |

The user side scales alike: the cycles per instruction rise 9.6% and
8.6%, and the four checkers in one E-core cluster share its L2 for
both. Trig's kernel side grows three times as much. Memory bandwidth is
far below what pup's memory gives, for both.

## 2. The four-checker timeline

5 interleaved runs each, medians, E-cores 12-15, ms
([timeline-summary.txt](scaling-2-data/timeline-summary.txt)):

| ts-pattern | wall | head | check | tail | checkers 0, 1, 2, 3 | longest / mean | time with 1, 2, 3, 4 threads running |
|---|---:|---:|---:|---:|---|---:|---|
| Trig, 1 checker | 1,264 | 46.5 | 1,211 | 6.6 | | | |
| tsrs Go, 1 thread | 1,044 | | | 2.6 | | | |
| Trig, 4 | 546 | 52.8 | 474.9 | 16.7 | 475, 388, 329, 314 | 1.26 | 152, 60, 16, 314 |
| tsrs Go, 4 | 394 | 25.6 | 362.9 | 4.4 | 337, 363, 236, 249 | 1.23 | 46, 89, 14, 242 |
| tsrs default, 4 | 340 | 26.0 | 310.2 | 3.9 | 310, 272, 293, 279 | 1.07 | 34, 16, 11, 278 |

| zod3 | wall | head | check | tail | checkers 0, 1, 2, 3 | longest / mean |
|---|---:|---:|---:|---:|---|---:|
| Trig, 1 checker | 250 | 46.0 | 205 | 0.2 | | |
| tsrs Go, 1 thread | 181 | | | 0.3 | | |
| Trig, 4 | 160 | 50.5 | 102.2 | 8.5 | 101, 102, 87, 59 | 1.15 |
| tsrs Go, 4 | 97 | 24.0 | 73.3 | 0.7 | 61, 60, 73, 43 | 1.24 |
| tsrs default, 4 | 83 | 23.8 | 57.7 | 0.9 | 58, 58, 58, 58 | 1.00 |

Each Trig checker keeps one worker for its whole task at four cores
(its CPU time equals its span). Concurrency over the run: Trig 2.9 of a
possible 4 on ts-pattern, tsrs in Go order 3.1.

- **Head.** Trig's 52.8 ms: 5.9 from exec to `FileLoader.load`, 41-42
  to the first `new_checker` (parse, bind, the program), 3.1 making the
  four checkers one after another, 2.5 to the first task. By
  `--extendedDiagnostics` on the same cores Trig parses in 31-32 ms and
  binds in 11, at one checker and at four; tsrs parses in 18 and binds
  in 6 on one thread, and parses and binds together in 16 on four
  ([extdiag.txt](scaling-2-data/extdiag.txt)). Worker 0 sleeps and is
  woken 319 times in the head (`RIG_SCHED_STATS`; file reads through the
  blocking pool), as on 2026-10-24.
- **Tail.** 16.7 ms at four checkers, of which 14.9 after the output is
  written; 6.6 at one checker; tsrs 3.5 after its output. The profile of
  the tail: about two thirds `munmap` in the kernel (freeing pages) and
  a third the drop code (`dropFields`, `rig.alloc.free`). 343 `munmap`
  calls in it: 172 Tables, 99 large blocks.
- **Per file.** Go's checker 0 holds `tests/large-exhaustive.test.ts`
  (197 ms in Trig), `tests/real-world.test.ts` (93) and
  `tests/distribute-unions.test.ts` (48); checker 1 holds
  `tests/exhaustive-match.test.ts` (288)
  ([perfile.txt](scaling-2-data/perfile.txt)). tsrs has no per-file
  trace (`--generateTrace` is not supported).
- **Per checker, Trig against tsrs, same partition:** 1.41× on checker
  0, 1.07× on 1, 1.39× on 2, 1.26× on 3; 1.27× in all. So Trig's
  longest checker is 0, tsrs's is 1. Alone on one core (four checkers on
  core 12, fiber switches traced,
  [timeline2-summary.txt](scaling-2-data/timeline2-summary.txt)) Trig's
  checker 0 already takes 1.26× its checker 1's time, where tsrs's takes
  0.94×: the skew is single-thread work, not parallel slowdown. Checker
  0 spends 21.6% of its samples in `instantiate_type_with_alias` against
  16-18% for the others ([bychecker.txt](scaling-2-data/bychecker.txt)).

## 3. The loss from one checker to four, ranked

The loss is Trig's four-checker wall less what it would take at its
one-checker ratio to tsrs: on ts-pattern 546 − 1.211 × 394 = 69 ms in
the timeline session (39 ms in the timing session), on zod3 160 − 1.381
× 97 = 26 ms. By phase:

| | ts-pattern | zod3 |
|---|---:|---:|
| head: 52.8 − 1.211 × 25.6; 50.5 − 1.381 × 24.0 | 21.8 ms | 17.4 ms |
| check: 474.9 − 1.211 × 362.9; 102.2 − 1.381 × 73.3 | 35.4 ms | 1.0 ms |
| tail: 16.7 − 1.211 × 4.4; 8.5 − 1.381 × 0.7 | 11.4 ms | 7.5 ms |

Split by cause and owner, largest first:

1. **The serial head: 22 ms on ts-pattern, 17 on zod3 (Trig, on Rig's
   tasks).** It does not shrink with checkers, so its share grows from
   4% of Trig's one-checker run to 10% at four on ts-pattern, and from
   18% to 32% on zod3. In it: parse and bind are 1.8× tsrs's on one
   thread (43 against 24 ms, 14 ms beyond Trig's ratio); tsrs parses
   and binds on every thread (24 to 16 ms, worth 10 ms at Trig's ratio);
   Trig makes its checkers one after another (3.1 ms) and spawns their
   tasks (2.5).
2. **The heaviest group is Trig-slow: 14 ms on ts-pattern (Trig,
   single-thread).** Trig's checkers are 1.27× tsrs's in all, but its
   checker 0 is 1.41×; at a uniform 1.27× its check would end at 461
   ms, not 475. Go's partition is the same for both, and tsrs's
   longest checker is not this group. On zod3 the groups are balanced
   (Trig's longest / mean is 1.15, tsrs's 1.24) and the check phase
   loses nothing.
3. **The serial tail: 11 ms on ts-pattern, 7.5 on zod3 (Rig and
   Trig).** Freeing four checkers and the program at exit (two thirds
   of it the kernel unmapping), memory the process gives back by
   exiting. scaling.md measured 26 ms on P-cores; now 16.7 on E-cores.
4. **Per-core costs that only Trig grows: about 7-12 ms on ts-pattern
   (Rig).** Trig's kernel cycles grow by 0.18G from one checker to four
   against tsrs's 0.055G: about 27 ms of CPU beyond Trig's ratio,
   spread over four checkers. The traces show where
   ([mm-summary.txt](scaling-2-data/mm-summary.txt)): in the check,
   about 1,450 TLB flushes send IPIs to the other checkers' cores
   (4,060 remote shootdowns, 4,200 IPIs a run, against tsrs's 53), and
   the calls behind them are 155 `mremap`s, 136 of them `rig.alloc.remap`
   moving a growing large block, and 26 `munmap`s; plus 18K more page
   faults (tsrs: 3K more). The user cycles per instruction rise one
   point more than tsrs's (9.6% against 8.6%), about 5 ms on the
   longest checker.
5. **The rest of the check: 0-14 ms, not attributed.** In the timeline
   session the check phase is 35 ms over Trig's ratio, of which items 2
   and 4 explain 21-26; in the timing session the whole loss is 39 ms,
   which leaves almost nothing for it. tsrs's four-checker run-to-run
   spread is this size.
6. **Rig's scheduler and allocator: none measurable.** Scheduler
   symbols are about 0.01% of the check's samples; `rig.alloc` is 1.9-2.1% of
   each checker's samples at four, as at one; each checker keeps its
   worker; workers 1-3 each sleep once or twice.

**What Go mode forbids and what it does not.** The partition is fixed:
with Trig's four checkers perfectly balanced, ts-pattern's check would
take 377 ms, not 475 (98 ms, 18% of the wall), and tsrs's default
assignment with stealing is 14-16% faster than its Go order at four
(54-67 ms) and 12% at eight. That is outside Go mode. Everything in items 1 to 4
is allowed in Go mode, and on CHECKERS.md's list of what Trig may take
while staying exact: a parallel parse and bind (its item 2), checkers
made in their tasks (3), teardown by exit (4), and single-thread speed.

## 4. What changed since 2026-10-24

| | 2026-10-24 (P-cores, all) | today (E-cores, four) |
|---|---|---|
| longest checker / mean, Trig and tsrs Go | 1.41, 1.22 | 1.26, 1.23 |
| Trig's checkers against tsrs's, sorted by length | 1.31 to 1.87 (heaviest 1.87) | 1.15 to 1.33 |
| head | 54 ms, serial | 52.8 ms, serial (unchanged) |
| tail | ~26 ms | 16.7 ms |
| page faults at four checkers | 93.8K | 33.5K |
| scheduler | 0.03% of samples | about 0.01% |

The heaviest group's skew is smaller, the faults are a third, and the
tail is two thirds; the head is where it was, and is now the largest
part of the loss. Whether checker 0 still spends its end under
`choose_overload`, as scaling.md found, was not settled: the PGO
build's call stacks are mostly a few frames deep, so this record's
profiles attribute by leaf, and their "under" figures are lower bounds.

## 5. #754's huge pages at four checkers

Huge pages are per Table, not per heap or per thread. Each checker
builds its own Tables, 43 of which pass 2 MiB, so `rig.table.reserve`
makes 172 reservations at four checkers (each a `munmap` to trim, a
`madvise(NOHUGEPAGE)` for the first 2 MiB and a `madvise(HUGEPAGE)` for
the rest; 215 GB of address space reserved), against 43 at one
([memory.txt](scaling-2-data/memory.txt)). Peak RSS and AnonHugePages
(`smaps_rollup`, 5 ms samples):

| | ts-pattern 1 | ts-pattern 4 | zod3 1 | zod3 4 |
|---|---:|---:|---:|---:|
| peak RSS, `773978d1d` (#754) | 279 MB | 339 MB | 93 MB | 143 MB |
| peak RSS, `2c01f07dd` | 268 MB | 299 MB | 87 MB | 123 MB |
| #754's increase | 4.0% | **13%** | 7.6% | **17%** |
| AnonHugePages, #754 | 156 MB | 142 MB | 32 MB | 46 MB |
| tsrs Go peak RSS / AnonHugePages | 207 / 128 MB | 232 / 141 MB | 55 / 28 MB | 87 / 45 MB |

#754's memory cost grows with the checker count, about 10 MB a checker
on ts-pattern and 5 MB on zod3: each checker's Tables each leave a
partly written last huge page. Its speed at four: ts-pattern 2.9% faster
by the median (555 against 571 ms), page faults 33.5K against 49.0K,
IPIs 4,193 against 5,184; zod3 the same (171 against 171 ms).

## 6. The fixes, by size

| fix | owner | recovers at four checkers | at one |
|---|---|---|---|
| Parse and bind in tasks, and the checkers made in their tasks | Trig, on Rig's tasks | ts-pattern ~15-20 ms (3-4%), zod3 ~15 ms (9%) | none |
| Parse and bind as fast as tsrs's on one thread (43 against 24 ms) | Trig | up to ~19 ms, less once parallel | ~19 ms |
| Exit after the output, skipping the drops (a release-build exit in Rig; Trig calls it after `write_output`) | Rig and Trig | ts-pattern 12-14 ms (2.5%), zod3 ~8 ms (5%) | ~6 ms |
| The instantiation-heavy group (Go's checker 0: large-exhaustive, real-world) as fast as tsrs's | Trig | ~14 ms on ts-pattern | part of the 1.19× |
| Grow large blocks without moving them while other threads run (reserved address space, as Tables do), so `mremap` sends no shootdowns | Rig | an estimated 3-7 ms on ts-pattern | none |
| Huge pages per Table bounded at many checkers | Rig | memory, not time | |

The first three together take back the serial part of the loss, 33 ms
of the 39-69 on ts-pattern and 25 of the 26 on zod3. Balancing the
checkers would be worth more (98 ms on ts-pattern) but changes tsc's
output, so it belongs to a later canonical mode.

## Open questions for the panel

1. Which of checker 0's files is Trig-slow? tsrs gives no per-file time;
   a single-file program per test, timed in both, would say.
2. Does the unattributed 0-14 ms of the check (item 5) survive a quiet
   machine, or is it tsrs's run-to-run spread?
3. Eight checkers: Trig gains 8% over four, tsrs 27%. Not traced here;
   the same head and tail, eight checkers made serially, and Go's
   partition keeping the heavy group are the likely parts.
4. Is a parallel front end now worth its lines? CHECKERS.md declined it
   when the front end was under 2% of the one-checker samples; at four
   checkers it is 10% of ts-pattern's wall and 32% of zod3's.
5. `rig.alloc.remap` at four checkers: is moving growth worth its TLB
   shootdowns once other threads run, or should a large block grow in
   reserved address space?
6. #754 at many checkers: should Table huge pages wait for a larger
   size, or count against a budget, so memory does not grow 10 MB a
   checker?
