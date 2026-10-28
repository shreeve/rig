# Huge pages for the small-object heap's segments (2026-10-27)

**Question.** On pup, Trig at one checker takes 2.3 times tsrs's page
faults and 3.2 times its dTLB misses, and a quarter of its wall gap to
tsrs is kernel time ([tsrs-standing](../hash-race/tsrs-standing.md)).
tsrs keeps 63% of its heap in transparent huge pages; Trig keeps 2 to
9%, since the release allocator (`src/alloc.zig`) advises huge pages
only for new large blocks of 16 MiB or more ([alloc-thp16/](../alloc-thp16/README.md)),
and `src/table.zig` advises its reservations `MADV_NOHUGEPAGE`. Would
huge pages for the heap's 4 MiB segments, or for large tables, make
Trig faster without raising its peak memory (decision 11)?

**Answer.** Huge pages for the segments of a heap that faults in ahead
(`seglead`) make Trig 1.7 to 3.2% faster at one checker and 2.9 to
4.6% at four, user cycles 1.3 to 2.4% fewer, kernel cycles 3 to 8%
fewer, dTLB misses 22 to 36% fewer, instructions unchanged. Peak
memory rises 0.1 to 0.7% on ts-pattern and 1.5 to 2.0% on zod3 (1.3
to 2.5 MB), the band in which #725 left huge pages from 2 MiB out. So
it goes to the owner, default not taken. Advising every segment
(`seg`) raises peak memory 1.9 to 9.0%; huge pages for tables past
their first 2 MiB (`tbl`) make ts-pattern 3.3 to 3.9% faster at one
checker and zod3 not at all, and raise peak memory 4.0 to 16%: not
taken, as on 2026-10-25.

## The variants

Rig main `36422da59` (main), Trig main `403a823`. Each variant is main
with one change, on Linux only:

- **seg**: the segment region advised `MADV_HUGEPAGE` whole as it is
  reserved, and a segment mapped on its own likewise. Segments are 4
  MiB aligned to their size, so each is two huge pages, with no
  over-map and trim needed.
- **segnp**: seg, and a segment's 1 MiB stretches no longer faulted in
  ahead (`prefault` skipped in `newPage`).
- **seglead**: main, and `newPage` advises a new segment
  `MADV_HUGEPAGE` when its heap faults in ahead (`faultsAhead`: it
  leads the heaps, or has taken two segments or more). This is the
  branch.
- **tbl**: main, and `table.zig`'s `reserve` keeps `MADV_NOHUGEPAGE` on
  a reservation's first 2 MiB (to the first 2 MiB boundary past its
  start) and advises the rest `MADV_HUGEPAGE`: consolidation-2's
  `past` rule, without its alignment, since pup's kernel already places
  these reservations on 2 MiB boundaries (every advised table's tail
  showed AnonHugePages equal to its Rss).

Each Rig built on pup (`build.sh`, cores 0,5), and Trig built release
with it through `/zfs/trig-pup/trial/slot.sh` on cores 0,5. A slot's
lock is its index in `TRIG_RELEASE_SLOTS`, so `"0,5"` alone waits on
slot 0's lock, which another session's builds on 10,11 held; the
script names `"0,5 0,5 0,5"`, cores 0,5 under whichever lock is free.
Every variant printed the same output in every run.

pup: THP `madvise`, defrag `madvise`, kernel 7.0.0-38, 16 to 24 GB
available, load under 2 (another session built on cores 10, 11).

## Method

- `measure.py` (alloc-thp16's, with user and kernel cycles and dTLB
  misses added): `trig -p tsconfig.trig.json --noEmit --checkers 1` on
  core 6, its sibling 7 idle, 20 rounds, the five builds interleaved
  and the order reversed every other round; under `perf stat`
  (`trig-perf.md`) and without it (`trig-wall.md`, faults from
  `/usr/bin/time %R`); and at `--checkers 4` on cores 0,5,6,7, 10
  rounds under perf (`trig-perf4.md`). Fastest wall with the median
  beside it, least sys, fewest instructions, cycles and faults, median
  dTLB misses, peak RSS (`/usr/bin/time %M`) median and largest.
- `sys-ts.sh` and `huge-ts.sh`: the tsrs-standing record's `sys.sh`
  and `huge.sh` on these builds, on core 6 (that record used core 8),
  `--singleThreaded`, so the numbers compare with its own.
  `sys-ts-summary.txt` has the medians, and peak RSS of the
  `--singleThreaded` runs.
- `huge.py`: AnonHugePages and Rss, the most seen in three runs at one
  checker (smaps_rollup read every 5 ms). `smaps.py` reads each mapping
  near the end of a run, which showed where the memory is.
- `hb.py`: bench/hash's `map.rig` built `rig-fast` by main's and
  seglead's Rig; 9 runs each interleaved, the fastest of each row, and
  the `--mem` measure (one `Map[Int, Int]` of 4M keys, peak RSS of
  `mem` less `mem0`, least of 9). On pup on core 6, twice; on the Mac
  once (5 runs), where the change compiles to nothing.

**perf's page faults are not `%R`'s.** A fault taken by
`MADV_POPULATE_WRITE` (the heap's `prefault`) counts in the process's
minor faults but not in perf's `page-faults` event, which counts only
traps. So perf's 40,334 on ts-pattern are traps, mostly tables and
first touches of large blocks; `%R`'s 65,940 include the faults
prefault takes for segments, which huge pages replace with one fault
per 2 MiB.

## Trig at one checker

Under perf, 20 rounds (`trig-perf.md`):

| project | build | wall s | median | sys s | user cycles | kernel cycles | instructions | traps | dTLB misses | RSS MB |
|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| ts-pattern | main | 0.900 | 0.908 | 0.087 | 3,814.7M | 358.3M | 9,292.2M | 40,334 | 2.05M | 272.9 |
| ts-pattern | seg | 0.887 | 0.894 | 0.081 | 3,800.1M | 342.4M | 9,295.7M | 39,840 | 1.55M | 278.0 |
| ts-pattern | segnp | 0.886 | 0.896 | 0.071 | 3,792.0M | 342.6M | 9,293.3M | 39,861 | 1.57M | 278.0 |
| ts-pattern | seglead | 0.885 | 0.890 | 0.074 | 3,767.0M | 340.3M | 9,286.0M | 39,908 | 1.55M | 274.2 |
| ts-pattern | tbl | 0.866 | 0.873 | 0.063 | 3,761.8M | 257.5M | 9,285.2M | 15,635 | 1.88M | 283.7 |
| zod3 | main | 0.188 | 0.192 | 0.032 | 711.7M | 97.5M | 1,691.8M | 9,736 | 0.222M | 86.2 |
| zod3 | seg | 0.183 | 0.189 | 0.024 | 696.0M | 92.1M | 1,685.9M | 9,272 | 0.143M | 91.3 |
| zod3 | segnp | 0.186 | 0.189 | 0.028 | 708.7M | 92.8M | 1,681.4M | 9,280 | 0.146M | 91.3 |
| zod3 | seglead | 0.182 | 0.187 | 0.030 | 695.2M | 89.8M | 1,681.5M | 9,321 | 0.144M | 87.5 |
| zod3 | tbl | 0.188 | 0.193 | 0.030 | 706.4M | 96.1M | 1,685.3M | 8,017 | 0.215M | 92.5 |

Without perf, 20 rounds (`trig-wall.md`; faults are minor faults):

| project | build | wall s | median | sys s median | minor faults | RSS MB |
|---|---|---:|---:|---:|---:|---:|
| ts-pattern | main | 0.884 | 0.890 | 0.084 | 65,940 | 272.9 |
| ts-pattern | seg | 0.870 | 0.877 | 0.081 | 54,972 | 278.0 |
| ts-pattern | segnp | 0.875 | 0.878 | 0.082 | 54,971 | 278.0 |
| ts-pattern | seglead | 0.869 | 0.874 | 0.082 | 55,040 | 274.2 |
| ts-pattern | tbl | 0.855 | 0.861 | 0.063 | 41,241 | 283.7 |
| zod3 | main | 0.173 | 0.176 | 0.027 | 20,102 | 86.2 |
| zod3 | seg | 0.172 | 0.174 | 0.028 | 15,294 | 91.3 |
| zod3 | segnp | 0.171 | 0.173 | 0.025 | 15,294 | 91.3 |
| zod3 | seglead | 0.170 | 0.172 | 0.025 | 15,342 | 87.5 |
| zod3 | tbl | 0.173 | 0.175 | 0.026 | 18,385 | 92.5 |

The tsrs-standing form (`sys-ts.sh`, `--singleThreaded`, medians of
10 rounds; peak RSS from two more runs each):

| project | build | wall ms | user ms | system ms | kernel cycles | traps | dTLB misses | peak RSS MB |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| ts-pattern | main | 895.2 | 801.8 | 89.6 | 371M | 40,243 | 2.11M | 273.9 |
| ts-pattern | seglead | 877.1 | 798.5 | 77.9 | 346M | 39,823 | 1.53M | 274.2 |
| ts-pattern | tbl | 860.8 | 801.0 | 60.0 | 269M | 15,542 | 1.88M | |
| zod3 | main | 175.8 | 152.3 | 25.5 | 99M | 9,641 | 0.22M | 86.0-86.2 |
| zod3 | seglead | 170.2 | 149.1 | 23.5 | 93M | 9,234 | 0.14M | 87.5 |
| zod3 | tbl | 175.8 | 151.0 | 26.1 | 97M | 7,923 | 0.22M | |

(seg and segnp are in `sys-ts-summary.txt`, within 1% of seglead in
time.) Peak RSS was the same in every run of a build, to the KB: it is
not noise.

**seglead against main**, one checker: wall 1.7% faster on ts-pattern
(fastest, perf and plain alike; medians 1.8 to 2.0%), 1.7 to 3.2% on
zod3 (medians 2.3 to 2.6%); `sys-ts.sh`'s medians 2.0% and 3.2%. User
cycles 1.3% fewer on ts-pattern and 2.3% on zod3, kernel cycles 5.0%
and 7.9% fewer, dTLB misses 24% and 35% fewer, instructions 0.1% fewer
and 0.6% fewer. Minor faults 17% and 24% fewer, traps 1% and 4%:
prefault already took the segments' faults in one call a megabyte,
and a huge page takes them a fault per 2 MiB. The gain is the TLB and
the kernel's work per page, not traps. Peak RSS 274.2 MB against 272.9
on ts-pattern (0.5%; 0.1% `--singleThreaded`), 87.5 against 86.2 on
zod3 (1.5%; 1.7% `--singleThreaded`).

**seg** gains the same, a little less on user cycles, and costs more
memory: 278.0 MB (1.9%) and 91.3 (5.9%). Trig at one checker runs two
threads; advising the whole region gives the second thread's heap,
which takes little, a 2 MiB page at its first touch, and every heap's
last segment a 2 MiB page. seglead gives huge pages only to a heap
that already faults in ahead, whose segments are filled densely; its
only cost is the rest of the huge page its current segment is filling,
where prefault had faulted in 1 MiB stretches.

**segnp against seg:** the same faults to a fault and the same RSS.
`MADV_POPULATE_WRITE` on an advised range takes a huge page, so the
prefault of a huge-paged segment costs one call per 2 MiB and changes
nothing else; where huge pages are off or none is free, it still saves
a trap per page. seglead keeps prefault as it is.

**tbl:** ts-pattern 3.3 to 3.9% faster, kernel cycles 28% fewer,
traps 61% fewer; zod3 no faster. Peak RSS 4.0% higher on ts-pattern
and 7.3% on zod3.

## Trig at four checkers

`--checkers 4` on cores 0,5,6,7, 10 rounds under perf
(`trig-perf4.md`):

| project | build | wall s | median | user cycles | kernel cycles | traps | dTLB misses | RSS MB |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| ts-pattern | main | 0.501 | 0.514 | 6,070.2M | 554.9M | 48,434 | 3.36M | 309.6 |
| ts-pattern | seg | 0.490 | 0.508 | 5,987.9M | 537.7M | 46,063 | 2.36M | 320.2 |
| ts-pattern | segnp | 0.493 | 0.504 | 5,993.9M | 527.6M | 46,085 | 2.28M | 320.2 |
| ts-pattern | seglead | 0.486 | 0.499 | 5,927.0M | 522.0M | 48,010 | 2.64M | 311.8 |
| ts-pattern | tbl | 0.493 | 0.507 | 6,013.1M | 486.6M | 32,889 | 3.10M | 348.3 |
| zod3 | main | 0.152 | 0.163 | 1,405.7M | 216.6M | 19,703 | 0.687M | 124.9 |
| zod3 | seg | 0.154 | 0.158 | 1,375.2M | 207.8M | 17,414 | 0.468M | 136.2 |
| zod3 | segnp | 0.147 | 0.158 | 1,390.1M | 207.1M | 17,426 | 0.467M | 136.1 |
| zod3 | seglead | 0.145 | 0.158 | 1,387.3M | 210.0M | 19,289 | 0.535M | 127.4 |
| zod3 | tbl | 0.154 | 0.161 | 1,404.8M | 223.5M | 18,238 | 0.678M | 145.1 |

seglead: 3.0% faster on ts-pattern (median 2.9%), user cycles 2.4%
fewer, dTLB misses 22% fewer, peak RSS 0.7% higher (2.2 MB); zod3
4.6% faster (median 3.1%), user cycles 1.3% fewer, dTLB misses 22%
fewer, peak RSS 2.0% higher (2.5 MB). A checker's heap faults in ahead
from its second segment, so its first keeps small pages. seg costs
3.4% and 9.0%, tbl 12.5% and 16%: each checker has its own tables.

## Huge pages held

`huge-ts.sh` (the sample of largest Rss, three runs, `--singleThreaded`):

| project | build | Rss MB | AnonHugePages MB | share |
|---|---|---:|---:|---:|
| ts-pattern | main | 273.0-273.1 | 8 | 3% |
| ts-pattern | seg | 275.7-278.2 | 54-56 | 20% |
| ts-pattern | seglead | 270.7-274.4 | 50-60 | 18-22% |
| ts-pattern | tbl | 281.3-284.7 | 112-122 | 40-43% |
| zod3 | main | 83.8-86.2 | 0 | 0 |
| zod3 | seg | 87.3-91.4 | 22-24 | 25-26% |
| zod3 | seglead | 83.4-84.1 | 18 | 21-22% |
| zod3 | tbl | 90.7-92.7 | 12 | 13% |

(`huge-ts.txt` in KB; the sampled Rss misses the peak by a few MB, so
judge memory by `%M` above.) Where ts-pattern's 273 MB are, near the
end of a main run (`smaps.py`): 123 MB in tables (one `nh` mapping,
the reservations side by side), 43 MB in the segment region, 16 MB in
one large block of 20 MiB (the only memory in huge pages), the rest in
smaller large blocks. tsrs's 63% is its arena; Trig's equivalent, the
segments, is under a sixth of its memory, and its tables, the largest
part, cannot take huge pages without committing 2 MiB at each table's
frontier.

## Why tables say `MADV_NOHUGEPAGE`, and whether it still holds

`6fde90632` ("table: Table[T, n] holds n slots ...", 2026-10-21) made
reserved tables `MAP_NORESERVE` and `MADV_NOHUGEPAGE`, with the reason
in `reserve`'s comment: "A huge page would commit 2 MiB at a table's
first touch." Trig makes about 40 tables per checker store
(`store_generated.rig`), most written sparsely or not at all. On pup,
whose THP is `madvise`, the advice changes nothing, since an unadvised
range never gets huge pages; it guards hosts set to `always`.
[consolidation-2/hugepages.md](../consolidation-2/hugepages.md)
(2026-10-25) measured advising tables whole (peak RSS 49% higher at
four checkers on ts-pattern, 144% on zod3) and `past`, tbl's rule (2.4%
faster on ts-pattern at one checker, zod3 0.9% slower), and kept the
code.

The reason holds. tbl replaces the advice rather than adding to it
(the first 2 MiB keep `MADV_NOHUGEPAGE`; the rest asks for huge pages),
and it costs what the comment says, once per table past 2 MiB rather
than once per table: in zod3 five tables pass their first 2 MiB, and
each tail holds 2 to 4 MB in huge pages, all of it resident. Since
2026-10-25 the gain on ts-pattern has grown (3.3 to 3.9% at one
checker, as prefault took the heap's faults and left the tables' traps
the most of what remains), but zod3 gains nothing, and peak memory
rises 4.0 to 16%. Not taken.

## bench/hash

`hb.py`, pup, core 6, 9 runs interleaved, twice (`hb-pup-1.txt`,
`hb-pup-2.txt`):

| | run 1 | run 2 |
|---|---:|---:|
| seglead against main, 130 rows (geometric mean) | 1.003 | 1.019 |
| the 18 rows of 3M and 4M keys | 1.018 | 1.007 |
| `mem`, peak MB, main / seglead | 147.4 / 147.4 | 147.4 / 147.4 |
| `mem` less `mem0`, bytes an entry, main / seglead | 29.9 / 29.6 | 29.9 / 29.6 |

The 4M-key map's peak is the same (147.4 MB); `mem0`, the keys alone,
is 1 MB higher (34.5 MB against 33.5), the segment tail, so the
per-entry figure reads 0.3 lower. Rows more than 3% apart in both runs:
faster, `str16 insert` (23%), `big16 insert` (15%), `int16 insert`,
`rnd24 remove`, `str1000 remove`, `str100000 miss`, `str1000000 miss`,
`big16 remove` (3 to 8%); slower, `rnd1000 insert` (11 to 13%), `int
ensure-miss` (17 to 20%), `int1000 insert` and `remove`, `int100000
remove`, `rnd1500 insert`, `rnd24 insert`, `int insert`, `int hit`,
`pair hit`, `string ensure-miss` (3 to 9%, `int hit` 26% once). The
map's tables from 16 MiB already have huge pages, and the rest is the
size of alloc-thp16's control's spread (rows of a byte-identical
allocator 4 to 8% apart): no gain or loss is claimed. On the Mac (`hb-mac.txt`)
the change compiles to nothing; the geometric mean is 0.993 and the
4M map 30.7 bytes an entry for both, which shows the spread of two
builds of the same code.

## Gates (seglead)

The unit test "on Linux a new segment of a heap that faults in ahead
is aligned for huge pages and asks for them, and one of a heap that
does not keeps small pages" fails on pup with `adviseHuge` made a
no-op (as does #726's) and passes at Debug, ReleaseSafe and
ReleaseFast (`zig build test`, pup, cores 0,5). On the branch's head,
`35b455100` (its second commit asks `faultsAhead` only on Linux, so
the change compiles to nothing elsewhere; Linux's code is the same):

- `tools/heavy swarm test/rig.rip all -q -w 6` on the Mac: 10,702 jobs,
  none died.
- `zig build test` on pup at Debug, ReleaseSafe and ReleaseFast: all
  pass.
- Trig's light gate, `PUP_RIG=<the branch's Rig, built on pup in this
  record's directory> tools/light`, from a clone of Trig main `403a823`
  whose `tools/pup` runs its workers on cores 0, 4-7 and 12-21 (`-w
  12`) and its release builds on cores 0,5: GREEN in 58 s (and in 59 s
  on `78f15118f`). `tools/pup-rig`'s shared `rig-next` held another
  session's Rig.
- loco's light gate (`rig/tools/light RIG=<branch bin/rig>`, loc
  `947ffa0`): GREEN in 30 s, 122 runs, none differ.
- std.json's guard on the Mac: every file within 2% of `guard.txt`,
  0.1 to 0.8% fewer instructions per byte.

## Decision

Huge pages for the segments of a heap that faults in ahead: Trig 1.7
to 3.2% faster at one checker and 2.9 to 4.6% at four, cycles agreeing,
over 20 interleaved rounds at one checker; peak memory 0.1 to 0.7%
higher on ts-pattern and 1.5 to 2.0% on zod3. **Default: not taken**,
since zod3's rise is the size of the one (1.3 to 2.0%) for which #725
left huge pages from 2 MiB out, and decision 11 allows none that is
meaningful.
