# Faulting large tables in ahead: measured, not taken (2026-10-26)

**Question.** On Linux each `Table` is reserved `MADV_NOHUGEPAGE`
(`src/table.zig`, `reserve`), so Trig's store of about 88 MiB faults
in 4 KiB at a time. Trig (fork) measured Trig on ts-pattern against
tsrs: at one checker Trig spent 272M more kernel cycles on page faults,
about 5% of the run, and 331M more at four checkers. 53% of the faults
were `Table.push` touching each page for the first time, and about 12%
were writes to the link tables' slots. Would a table that faults in
each 2 MiB stretch at once, as #674 and #678 do for allocator heaps
(`MADV_POPULATE_WRITE`), or as one huge page, make Trig faster?

**Answer.** No. Every arm cuts Trig's page faults by a third to a half.
With arms 1 and 4, Trig takes 19.0K faults at one checker, close to
tsrs's 17.8K. But kernel time follows the memory touched, about 1.6
times tsrs's, not the number of faults: each page is still allocated
and zeroed, and populating saves only the trap. Populating alone saves
2% of kernel cycles at one checker, and at four checkers costs 5% more.

Huge pages with populate (arm 4) cut kernel cycles by 15 to 18% at one
checker and run about 1% faster in total cycles. But they raise peak
RSS by 9% at four checkers, because each checker's link tables commit
a whole 2 MiB wherever a write lands. Huge pages on pushes only
(arm 6) keep RSS within 4%, but save no cycles at one checker, and the
wall time does not move.

No arm is more than 2% faster or uses at least 1% fewer instructions
with RSS no more than 5% higher (AGENTS.md, "A speed feature pays for
its lines"). The code stays as it is. The arms are on branch
`table-prefault` (`1db830905`, which picks an arm with `RIG_TABLE_ARM`
at `rig build`), and arm 6 written as it would land is on branch
`table-prefault-arm6` (`a1792e500`).

## The arms

All are Linux only. A table of 2 MiB or less is unchanged, and so is
every table's first 2 MiB: small pages, faulted as they are touched.

| arm | what a table larger than 2 MiB does past its first 2 MiB |
|---|---|
| 0 | as main: every page faults as it is first touched |
| 1 | a push or slot write at or past `high` (the end of what is faulted in) faults in the 2 MiB stretch that holds the slot, with `MADV_POPULATE_WRITE`, and moves `high` past it; a test on every slot write |
| 2 | arm 1 on pushes only |
| 3 | huge pages: the reservation aligned to 2 MiB (over-reserved by 2 MiB and trimmed) and advised `MADV_HUGEPAGE` past its first 2 MiB; no populate (hugepages.md's `past`) |
| 4 | arms 3 and 1 |
| 5 | arm 2 with no added instruction: the push's one length test is against a `limit` (the next 2 MiB boundary, or `n`), and the slow path panics at `n` or faults in the next stretch |
| 6 | arm 5, with each stretch a push reaches advised `MADV_HUGEPAGE` in a reservation aligned to 2 MiB |

Populating is `alloc.populate`, which is `prefault`'s `madvise` once it
has decided to fault ahead. pup's transparent huge pages are `madvise`,
as hugepages.md found.

## Trig (fork)'s numbers

ts-pattern, Trig main `8989715` (`m`) and Trig's arena-tables branch
(`a`, shreeve/trig#211, which moves Trig's eight list arenas and
`Checker.syms` into Tables), built with each arm. 10 interleaved
rounds at load about 1: fastest wall, least kernel cycles, median faults
and RSS.

Rig `3eb7d1a5e` (on `57b0360fe`), arms 0, 1 and 4:

| checkers | build | wall s | kernel cycles | faults | RSS MB |
|---|---|---:|---:|---:|---:|
| 1 | m0 | 1.01 | 456M | 38.8K | 327 |
| 1 | m1 | 1.00 | 447M | 19.0K | 336 |
| 1 | m4 | 0.98 | 372M | 19.0K | 333 |
| 1 | a4 | 0.99 | 359M | | 339 |
| 4 | m0 | 0.42 | 568M | 47.4K | 383 |
| 4 | m1 | 0.43 | 598M | 33.2K | 419 |
| 4 | m4 | 0.41 | 532M | | 417 |

Rig `1db830905` (on `91802aaf5`), arms 0, 4, 5 and 6, on Trig main:

| checkers | arm | wall s | user cycles | kernel cycles | user instr | faults | RSS MB |
|---|---|---:|---:|---:|---:|---:|---:|
| 1 | 0 | 0.99 | 4,355M | 457M | 10.18G | 38.8K | 327 |
| 1 | 4 | 0.98 | 4,363M | 389M | 0.7% more | 19.0K | 336 |
| 1 | 5 | 1.01 | 4,438M | 468M | | 24.9K | 332 |
| 1 | 6 | 0.99 | 4,406M | 411M | the same | 24.9K | 332 |
| 4 | 0 | 0.43 | | 552M | | 47.4K | 383 |
| 4 | 4 | 0.42 | | 525M | | 33.2K | 419 |
| 4 | 5 | 0.42 | | 572M | | | 398 |
| 4 | 6 | 0.42 | | 536M | | 39.0K | 398 |

Arm 6 at one checker uses 4,817M cycles in all, against arm 0's
4,812M. Arm 4 uses 1.2% fewer, but peaks at 9.4% more RSS at four
checkers. Trig's arena-tables adds little to either, and Trig (fork) is
closing #211.

## Rig's numbers

pup, Rig `3eb7d1a5e` (arms 0 to 4) and Rig main `57b0360fe` for arm 0;
Trig main `8989715` (`main`) and arena-tables `a8e0e54` (`arena`)
(`src/` with `tools/trig/main.rig`), `rig build --release`
(`buildtrig.sh`). Runs used copies of the projects, so nothing wrote
into Trig's `misc/projects` (`measure.py`). One checker ran on core 8
with its sibling 9 idle; four checkers ran on cores 0-2, 5 and 8-21.
Each case had 10 interleaved rounds:
- wall: the fastest, timed around `perf stat` and `/usr/bin/time`;
- kernel and user cycles: the least, from `perf stat --no-scale`, summed
  over pup's P-core and E-core counters;
- user instructions, faults and RSS: the median.

Load was 2 to 4.8 from other sessions, so walls vary by up to 4% between
sets. An earlier set of the same builds read ts-pattern at one checker
1.292 s for main and 1.259 to 1.307 s for the arms.

| project | checkers | Trig | arm | wall s | kernel cycles | user cycles | user instr | faults | RSS MB |
|---|---|---|---|---:|---:|---:|---:|---:|---:|
| ts-pattern | 1 | main | 0 main | 1.213 | 0.421G | 4.680G | 10.319G | 38838 | 327 |
| ts-pattern | 1 | main | 1 populate | 1.165 | 0.402G | 4.693G | 10.405G | 19006 | 337 |
| ts-pattern | 1 | main | 2 populate, pushes | 1.154 | 0.406G | 4.675G | 10.342G | 24939 | 333 |
| ts-pattern | 1 | main | 3 huge | 1.163 | 0.338G | 4.589G | 10.319G | 19199 | 336 |
| ts-pattern | 1 | main | 4 huge + populate | 1.163 | 0.337G | 4.639G | 10.405G | 19006 | 337 |
| ts-pattern | 1 | arena | 0 main | 1.177 | 0.425G | 4.591G | 10.301G | 43565 | 326 |
| ts-pattern | 1 | arena | 1 populate | 1.171 | 0.410G | 4.649G | 10.411G | 18009 | 339 |
| ts-pattern | 1 | arena | 2 populate, pushes | 1.161 | 0.408G | 4.655G | 10.339G | 23940 | 336 |
| ts-pattern | 1 | arena | 3 huge | 1.144 | 0.322G | 4.515G | 10.301G | 18212 | 338 |
| ts-pattern | 1 | arena | 4 huge + populate | 1.184 | 0.335G | 4.607G | 10.411G | 18003 | 339 |
| ts-pattern | 4 | main | 0 main | 0.526 | 0.582G | 5.285G | 10.874G | 47797 | 385 |
| ts-pattern | 4 | main | 1 populate | 0.533 | 0.576G | 5.322G | 10.964G | 33634 | 422 |
| ts-pattern | 4 | main | 2 populate, pushes | 0.528 | 0.543G | 5.253G | 10.898G | 39478 | 400 |
| ts-pattern | 4 | main | 3 huge | 0.516 | 0.508G | 5.232G | 10.874G | 33860 | 418 |
| ts-pattern | 4 | main | 4 huge + populate | 0.526 | 0.517G | 5.243G | 10.965G | 33629 | 421 |
| ts-pattern | 4 | arena | 0 main | 0.520 | 0.561G | 5.230G | 10.855G | 53207 | 377 |
| ts-pattern | 4 | arena | 1 populate | 0.544 | 0.566G | 5.203G | 10.972G | 36756 | 421 |
| ts-pattern | 4 | arena | 2 populate, pushes | 0.526 | 0.549G | 5.231G | 10.896G | 42592 | 400 |
| ts-pattern | 4 | arena | 3 huge | 0.535 | 0.497G | 5.302G | 10.856G | 37018 | 418 |
| ts-pattern | 4 | arena | 4 huge + populate | 0.555 | 0.491G | 5.265G | 10.972G | 36735 | 421 |
| zod3 | 1 | main | 0 main | 0.243 | 0.104G | 0.841G | 1.855G | 9001 | 92 |
| zod3 | 1 | main | 1 populate | 0.235 | 0.108G | 0.831G | 1.866G | 7212 | 99 |
| zod3 | 1 | main | 2 populate, pushes | 0.235 | 0.105G | 0.826G | 1.857G | 8548 | 94 |
| zod3 | 1 | main | 3 huge | 0.232 | 0.101G | 0.825G | 1.855G | 7277 | 99 |
| zod3 | 1 | main | 4 huge + populate | 0.233 | 0.102G | 0.820G | 1.866G | 7212 | 99 |
| zod3 | 1 | arena | 0 main | 0.226 | 0.103G | 0.829G | 1.855G | 9802 | 91 |
| zod3 | 1 | arena | 1 populate | 0.229 | 0.107G | 0.830G | 1.869G | 8018 | 98 |
| zod3 | 1 | arena | 2 populate, pushes | 0.230 | 0.105G | 0.838G | 1.860G | 9351 | 93 |
| zod3 | 1 | arena | 3 huge | 0.228 | 0.104G | 0.813G | 1.855G | 8080 | 97 |
| zod3 | 1 | arena | 4 huge + populate | 0.233 | 0.104G | 0.820G | 1.869G | 8014 | 98 |
| zod3 | 4 | main | 0 main | 0.181 | 0.228G | 1.249G | 2.549G | 19392 | 146 |
| zod3 | 4 | main | 1 populate | 0.188 | 0.235G | 1.250G | 2.567G | 17803 | 169 |
| zod3 | 4 | main | 2 populate, pushes | 0.187 | 0.224G | 1.273G | 2.554G | 19396 | 147 |
| zod3 | 4 | main | 3 huge | 0.179 | 0.220G | 1.254G | 2.549G | 17930 | 167 |
| zod3 | 4 | main | 4 huge + populate | 0.187 | 0.228G | 1.248G | 2.567G | 17802 | 169 |
| zod3 | 4 | arena | 0 main | 0.192 | 0.213G | 1.265G | 2.550G | 20003 | 139 |
| zod3 | 4 | arena | 1 populate | 0.189 | 0.233G | 1.261G | 2.572G | 18416 | 162 |
| zod3 | 4 | arena | 2 populate, pushes | 0.181 | 0.214G | 1.268G | 2.559G | 20006 | 139 |
| zod3 | 4 | arena | 3 huge | 0.175 | 0.222G | 1.230G | 2.550G | 18539 | 159 |
| zod3 | 4 | arena | 4 huge + populate | 0.184 | 0.224G | 1.265G | 2.572G | 18414 | 162 |

What the numbers say:

- **Faults are not the cost.** At one checker on ts-pattern, arm 1
  takes half of main's faults (19.0K against 38.8K) and saves 19M
  kernel cycles (0.402G against 0.421G). Each fault it saves costs
  about 1,000 cycles. The rest of the kernel's time goes to giving out
  and zeroing the pages, which populating still does.
- **Huge pages save kernel time.** Arms 3 and 4 cut ts-pattern's
  kernel cycles at one checker by 20% (0.421G to 0.338G), and user
  cycles by up to 2% (fewer TLB misses), with the same instructions. At
  four checkers they save 11 to 13% of kernel cycles in this set, and 5
  to 6% in Trig (fork)'s. zod3 moves within the noise.
- **Memory decides against the arms that save.** At four checkers each
  checker has its own link tables, which are indexed by program-wide
  node id and written sparsely. Arms 1, 3 and 4 commit a whole 2 MiB
  stretch wherever such a write lands: ts-pattern peaks at 417 to
  422 MB rather than 377 to 385 (8 to 12% more), and zod3 at 159 to
  169 MB rather than 139 to 146 (14 to 17% more). Faulting in only what
  pushes reach (arms 2, 5 and 6) keeps ts-pattern at 398 to 400 MB (4%
  more on Trig main, 6% on arena-tables) and zod3 within 1%. But those
  arms save only the push faults, and their kernel and wall gains fall
  within the noise.
- **A test on every slot write costs.** Arm 1 adds 0.8% user
  instructions (10.405G against 10.319G), and arm 2 adds 0.2% with its
  second test in `push`. Arms 5 and 6 fold the test into `push`'s
  length test and add none.

## The benches

`bench/tasks` and `bench/http` (rig-fast), built by Rig main and by the
probe, have identical disassembly (`objdump -d`): neither makes a
table, and `alloc.populate` inlines to `prefault`'s code. They were
timed anyway on cores 6 and 7, interleaved, 3 rounds at load 2.9 to 9.6
(`benches.sh`, `benches.log`). Best of 3, main against the probe:
- spawn 66 and 65 ns/task;
- chain 95 and 94 ns/task;
- fanout 326.9 and 335.7 ms/run;
- yield 24 and 24 ns;
- hog 141.13 and 142.93 us/step;
- http 185,403 and 185,032 req/s.
The binaries are the same, so these differences are the machine's
noise.

## Gates run on arm 6

Before the verdict, arm 6 as it would land (`a1792e500`) passed:
- `swarm test/rig.rip all` on the Mac, 10,575 jobs. The suite gained a
  case that pushes 700,000 12-byte slots and writes one far past them.
- loco's light gate: GREEN, 122 runs and 0 differ.

pup's `zig build test` was not run, since no code lands.
