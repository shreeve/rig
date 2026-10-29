# Workers panel: Trig's parallel design (2026-10-28)

Data: [trig-data.txt](trig-data.txt).

**A finding that reframes items 2 and 3.** tsrs 0.18.0's Go order is not
Trig's partition (Trig has three esnext libs tsrs lacks). So "checker 0 is
1.41×" compares different groups. Costed by tsrs's per-file CPU, the two
partitions' longest groups at four checkers are equal: 371 against 369 ms.

**1. A parallel front end now pays.** Libraries take 34 of the 43 ms, and
lib.dom alone about 24 (15.5 parse, 8.5 bind).

- **Design:** parse each file in a task, started as soon as the loader
  learns its path, lib.dom first. Keep the loader's walk and bind serial,
  in program order (atoms and class ids are interned in that order).
  Order, deduplication by path and package id, and the depth rules then
  stay exact, as in Go and tsrs. Make the checkers in their tasks.
- **Gain:** 15-18 ms at four checkers on both projects (ts-pattern 3%
  faster, zod3 10%).
- Rig needs nothing new. A parallel bind (2-3 ms more, per-file
  interning) can wait.

**2. No group of files is Trig-slow.** On one thread:

- Checker 0's heavy tests: 1.23× tsrs; exhaustive-match: 1.22×.
- The base program (libraries and src/) checks at 1.40×, and every
  checker repeats that work.
- `get_source_file_for_resolved_module` (program.rig:129) scans every
  file name: 2-3.5% of samples on zod3.

**3. From 4 to 8 checkers, it is the partition.**

- At 8, longest/mean is 2.0 and 2.26 for Trig's partition, against 1.50
  and 1.40 for tsrs's.
- Trig's longest group shrinks 7% from 4 to 8; Trig gains 8%.
- On Trig's partition, tsrs's longest checker is 19% longer on ts-pattern
  and 43% on zod3. The gap at 8 is nearer 1.4× than 1.64×.

**4. CHECKERS.md's list:**

- Skip empty checkers: exact, about 1 ms each at 8.
- Later passes in tasks: nothing to gain on `--noEmit` runs.
- A machine-sized count: the owner's call. tsrs's own rule picks 4 here.

**Ranked, at four checkers (ts-pattern / zod3):**

1. Parse in tasks, checkers made in theirs: 15-18 ms on each.
2. Exit without drops: 12-14 / 8 ms.
3. Faster parse and bind (lib.dom is the floor): up to 8-10 ms.
4. Base first touch, and the resolve scan: 2-4 ms.

**Port now:** an assignment dump, an assignment from a file, and per-file
times, to compare Trig and tsrs on one partition.
