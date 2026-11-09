# Small heaps do not ask for huge pages for their Tables (2026-11-09)

**Question.** A controlled check on pup found huge pages cost mitt 4.2%
and neverthrow 5.4% at 8 checkers, and level at 4. Head-to-head boards
looked worse above the Table gate (112-139 free 2 MiB blocks: 17 wins,
18 losses) than below it (19-65 free: 29 wins, 8 losses). What costs,
and how can a small heap at many workers not pay it, with no option?

**What costs.** On mitt at 8 checkers Trig makes 440 `madvise` calls,
against 7 with huge pages off, and only 2 huge pages are ever faulted. Each of 309 Tables reserved at once asks, which splits a mapping;
almost none of them leaves the first 2 MiB that never ask.

**Which rule.** The heap taken when a Table is made does not separate the
projects: 7-20 MiB at one checker, 23-45 MiB at 8, with zod3 and
ts-pattern level with one another and with the small ones per checker
(a probe of `reserveTable`, on every project at 1, 2, 4, and 8
checkers). What a heap does
afterward does. A Table now waits, in a list, for the heap that reserved
it to fault in ahead (`faultsAhead`, already the allocator's test for
huge segments), and asks then, once for all that heap's Tables. A heap
that leads the program asks as it reserves, as before. No program hint
and no hot-path code: the test is in `took`, on the path that takes
memory from the system.

**Measured.** pup, plain Trig builds 242fb6f on Rig efa08ecf0 with and
without the change (base, an A/A copy of base, the fix), libs off,
one slot, shuffled in each round, median ms. Compacted between cells
for the small projects, 60 rounds. Only runs above the gate (free > 64)
are counted; [results.txt](results.txt) has every row and
[ab.sh](ab.sh), [absum.py](absum.py) the method.

| | fix vs base | A/A | fix vs A/A copy |
|---|---|---|---|
| mitt c4 | 4.3% faster | 1.2% | 3.1% faster |
| mitt c8 | 5.2% faster | 2.4% | 2.9% faster |
| neverthrow c4 | 1.8% faster | 0.0% | 1.8% faster |
| neverthrow c8 | 5.8% faster | 2.9% | 3.0% faster |
| tiny-invariant c8 | 1.9% faster | 0.0% | 1.9% faster |
| tiny-invariant c4 | 1.3% faster | 1.7% | within A/A |
| 1 checker | level to 1.5% faster | | |

Instructions level on every row, peak RSS within 0.2 MiB of base. Large
heaps keep their huge pages (not compacted between cells, 20 rounds):
ts-pattern at 8 checkers 5.5% faster with the same faults, at 1 level,
at 4 2.0% slower with an A/A of 1.4% and 2% more faults; contracts level
at 1, 4, and 8 with the same faults.

The A/B is on Rig efa08ecf0. The change was then rebased on ec0a2a743,
whose difference, dense stacks, Trig does not use. Neverthrow at 1 and 8
checkers have fewer runs above the gate (57 and 79 of 180).
