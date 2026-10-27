# Huge pages for new large blocks of 16 MiB or more (2026-10-27)

#725 ([alloc-large/](../alloc-large/README.md)) measured huge pages in
the release allocator (`src/alloc.zig`) two ways: for every new block
of 2 MiB or more, as decision 11 of the hash race had them, which
raised Trig's peak memory and was left out; and for new blocks of 16 MiB
or more ("thp16"), which kept Trig's peak memory within 0.4% and made
bench/hash's 3M and 4M-key rows about 14% faster on pup. The owner
approved the second: "Yes, build huge pages for new blocks of 16 MiB or
more, with #725's gates and Trig's peak-RSS check; open the PR for me to
merge." This is that change, built afresh on main `967e1ac11` and
measured again against it.

## What changed

On Linux, a large block of 16 MiB or more (`huge_large`) that a heap
maps afresh is aligned to 2 MiB and advised with `MADV_HUGEPAGE`
(`mapLarge`, `adviseHuge`). The heap maps the block at its size first,
which the kernel often places on a 2 MiB boundary already; if it does
not, it maps 2 MiB more and gives back the head and tail. A block that
`mremap` grows to 16 MiB or more moves (`MREMAP_FIXED`) to a range so
aligned, and is advised. Blocks reused from those a heap keeps are left
as they are, a piece of an advised block staying advised; smaller
blocks keep the system's pages; other systems are unchanged. Every
large size from 16 MiB is a multiple of 4 MiB (four buckets per
doubling), so such a block is whole huge pages.

pup's THP is `madvise`, defrag `madvise` (an advised fault may compact
memory); kernel 7.0.0.

## Failing first

The test "on Linux a new block of 16 MiB or more, and one grown to it,
is aligned for huge pages and asks for them, and a smaller one does
not" maps a 16 MiB and an 8 MiB block on a heap of its own and grows an
8 MiB block to 32 MiB through the allocator's `remap`, and reads each
mapping's `VmFlags` in /proc/self/smaps (`hg`). With `adviseHuge` made
a no-op it fails on pup (`TestUnexpectedResult`); with the change it
passes at Debug, ReleaseSafe and ReleaseFast. On the Mac it is skipped.

## Trig on pup

Trig main `403a823` (src/ with tools/trig/main.rig), built release by
Rig main `967e1ac11` (main) and by the branch (thp16), on release slots
1-2 and 0-5 (`build.sh`). `measure.py`, as #725's: ts-pattern and
zod3, `trig -p tsconfig.trig.json --noEmit`, at `--checkers 1` on core
8 (9 idle) and `--checkers 4` on cores 6 to 9, the builds interleaved,
the order reversed every other round, 20 rounds; the fastest wall with
its user time, the least sys time, the fewest user instructions and
page faults, peak RSS (`/usr/bin/time %M`) median and largest. Outputs
agreed in every run.

Under `perf stat` ([trig-perf.md](trig-perf.md); walls include perf's
start):

| project | checkers | build | wall s | user s | sys s | instructions (user) | page faults | RSS MB median | RSS MB max |
|---|---|---|---:|---:|---:|---:|---:|---:|---:|
| ts-pattern | 1 | main | 0.991 | 0.881 | 0.096 | 9,482.9M | 40,757 | 295.0 | 295.0 |
| ts-pattern | 1 | thp16 | 0.983 | 0.881 | 0.094 | 9,484.4M | 40,543 | 296.2 | 296.2 |
| ts-pattern | 4 | main | 0.534 | 1.448 | 0.123 | 9,971.4M | 48,010 | 332.8 | 333.1 |
| ts-pattern | 4 | thp16 | 0.535 | 1.429 | 0.131 | 9,972.4M | 48,012 | 332.8 | 332.9 |
| zod3 | 1 | main | 0.202 | 0.163 | 0.027 | 1,714.5M | 9,637 | 89.2 | 89.4 |
| zod3 | 1 | thp16 | 0.198 | 0.161 | 0.028 | 1,716.3M | 9,637 | 89.2 | 89.4 |
| zod3 | 4 | main | 0.160 | 0.314 | 0.056 | 2,335.9M | 18,930 | 132.8 | 132.9 |
| zod3 | 4 | thp16 | 0.161 | 0.333 | 0.056 | 2,335.6M | 18,932 | 132.7 | 132.9 |

With no perf, minor faults from `/usr/bin/time %R`
([trig-wall.md](trig-wall.md)):

| project | checkers | build | wall s | user s | sys s | minor faults | RSS MB median | RSS MB max |
|---|---|---|---:|---:|---:|---:|---:|---:|
| ts-pattern | 1 | main | 0.972 | 0.878 | 0.084 | 73,790 | 295.0 | 295.0 |
| ts-pattern | 1 | thp16 | 0.963 | 0.860 | 0.078 | 72,553 | 296.2 | 296.2 |
| ts-pattern | 4 | main | 0.523 | 1.444 | 0.122 | 84,523 | 332.8 | 332.9 |
| ts-pattern | 4 | thp16 | 0.519 | 1.394 | 0.113 | 84,524 | 332.8 | 332.9 |
| zod3 | 1 | main | 0.188 | 0.162 | 0.023 | 21,118 | 89.2 | 89.4 |
| zod3 | 1 | thp16 | 0.186 | 0.151 | 0.020 | 21,119 | 89.2 | 89.4 |
| zod3 | 4 | main | 0.149 | 0.319 | 0.042 | 33,649 | 132.7 | 132.9 |
| zod3 | 4 | thp16 | 0.148 | 0.333 | 0.041 | 33,649 | 132.7 | 132.9 |

**Peak memory.** ts-pattern at one checker peaks 0.4% higher, 296.2 MB
against 295.0, in every one of the 40 runs of each (the median is the
largest); at four checkers it is the same, and zod3 is the same at both
(132.7 against 132.8 at four). These are #725's thp16 numbers to the
tenth of a MB. The 1.2 MB is the same in every run, so it is not
noise: a huge page backs all 2 MiB of a stretch the program writes
only part of. It is the same 0.4% the owner approved from #725's
record.

**Time and instructions.** Instructions within 0.1% either way. Walls
0.7 to 1.1% faster without perf and 0.6% slower to 2.0% faster under it,
all within the run-to-run spread; ts-pattern's minor faults 1.7% fewer
at one checker. Against the speed bar of more than 1.5% faster (#727;
a gain of 1.5 to 2% counts only over 20 interleaved rounds or more,
with cycles backing it), only zod3 at one checker under perf moves that
far (2.0% faster, 20 rounds), and the same case without perf is 1.1%
faster; cycles were not measured, and no Trig gain is claimed. On Trig
the change neither clears the bar nor costs anything; the case for it
is bench/hash's rows, below.

## bench/hash

The prover's harness from `hash-bench-2` (pup's
`/zfs/worktrees/rig/hash-bench-2-prover/bench/hash`), copied, with three
entries added to its `ZIG_ALLOCS`: `rigmain` (main's `src/alloc.zig`),
`rigmain2` (a copy of the same file at another path, the control) and
`rigthp16` (the branch's). `zig-foa` (map.zig on the port of boost's
flat map) on each, `bench-hash --reps 9 --mem`, fastest of 9 per row,
on core 8 (9 idle), twice ([hb-pup-1.txt](hb-pup-1.txt),
[hb-pup-2.txt](hb-pup-2.txt)). `hbsum.py` sums each report as the
prover's table: each variant's time against main's, the geometric mean
over a group of rows (under 1.00 is faster).

| rows | n | rigmain2 run 1 | rigthp16 run 1 | rigmain2 run 2 | rigthp16 run 2 |
|---|---:|---:|---:|---:|---:|
| Int: insert, remove, turnover | 24 | 1.002 | 1.001 | 1.000 | 1.005 |
| Int: lookups, iterate | 30 | 1.001 | 0.972 | 1.002 | 0.974 |
| Int: 3M and 4M rows | 18 | 0.998 | 0.889 | 0.996 | 0.892 |
| Text: insert, remove | 8 | 1.004 | 0.993 | 0.999 | 0.990 |
| Text: hit, miss | 8 | 0.995 | 0.987 | 0.997 | 0.988 |
| Big values: insert | 4 | 0.996 | 0.902 | 0.991 | 0.890 |
| Big values: remove, hit, iterate | 12 | 0.996 | 0.973 | 0.995 | 0.979 |
| All | 104 | 1.000 | 0.964 | 0.999 | 0.966 |

The 4M-key rows and the largest big-value table, ns per operation, run
1 (run 2 within 4% of each):

| row | main | main2 | thp16 |
|---|---:|---:|---:|
| int4000000 insert | 35.84 | 35.31 | 25.51 |
| int4000000 remove | 25.78 | 24.88 | 23.07 |
| int4000000 hit | 17.09 | 16.90 | 15.40 |
| int4000000 miss | 5.47 | 5.28 | 4.57 |
| int4000000 iterate | 2.52 | 2.52 | 2.36 |
| rnd4000000 insert | 33.58 | 33.56 | 24.37 |
| rnd4000000 hit | 17.65 | 17.58 | 15.65 |
| lat4000000 chain | 147.58 | 147.00 | 136.51 |
| churn4000000 turnover | 22.09 | 22.12 | 20.64 |
| big1000000 insert | 82.15 | 81.61 | 52.52 |
| big1000000 hit | 20.20 | 19.77 | 18.91 |

So the 3M and 4M rows are 11% faster (#725 measured 13% against its
main, which was before the reuse fix), the 4M inserts 27 to 29%
faster, and `big1000000`'s inserts 36% faster, where #725's thp16 had
them 1.20 times malloc's time. Peak memory for one 4M-key map is the
same: 54.8 bytes an entry for both (rigmain2 54.7).

Rows over 3% slower than main in both runs: for the control,
`int100000 remove` (7.2% and 3.9%) and `big16 hit` (3.8% and 6.9%);
for thp16, those two (8.1% and 5.9%; 6.9% and 8.4%), `rnd1000 iterate`
(5.6% both), `big16 insert` (4.2% and 3.9%), and `mix1000 half`, 26%
and 27% slower (1.20 to 1.51 ns, 1.21 to 1.54). No row of these
allocates a block over 32 KiB: `mix1000 half` looks keys up in a map of
1,000 built before the clock starts, and `big16` makes small blocks
only. The allocator's new code moves the functions after it in the
binary by 112 bytes (`nm`: `Io.Threaded.netLookup` at `0x101ed50` in
rigmain and `0x101edc0` in rigthp16), so those loops sit at other
alignments; in #725's run 3 its thp16 build, the same idea with other
code, had `mix1000 half` at 1.30 ns against main's 1.28. It is the
binary's layout, not the allocator, as `int16 miss` was in #725.

## Runtime benches

`bench/tasks`, `bench/actors`, `bench/net`, `bench/http` (rig-fast),
main and the branch interleaved, best of each round's 3 runs
(`bench.sh`, `benchsum.py`). pup on cores 6 and 7, 5 rounds
([benches-pup.log](benches-pup.log)):

| bench | case | main | thp16 |
|---|---|---:|---:|
| tasks | spawn | 60 ns | 60 ns |
| tasks | chain | 86 ns | 85 ns |
| tasks | fanout | 310.0 ms | 310.1 ms |
| tasks | yield | 21 ns | 21 ns |
| tasks | hog | 130.86 us | 130.64 us |
| tasks | memory | 4.6 KiB | 4.6 KiB |
| actors | solo / contend / spread | 11 / 15 / 10 ns | 11 / 15 / 10 ns |
| net | pingpong | 4.93 us | 4.99 us |
| net | echo | 3.59 us | 3.62 us |
| net | connect | 28.10 us | 28.89 us |
| http | req/s | 209,739 | 210,404 |
| http | p50 / p99 | 179 / 3391 us | 177 / 3381 us |

All within the run-to-run spread: `net connect`'s rounds run 28.10 to
29.38 us for main and 28.89 to 29.44 for the branch. None of these
programs makes a block of 16 MiB.

The Mac through `tools/low` (`macbench.sh`), where the change does
nothing (the code it adds is Linux's), 5 rounds and two more of `http`
([benches-mac.log](benches-mac.log)):

| bench | case | main | thp16 |
|---|---|---:|---:|
| tasks | spawn | 109 ns | 96 ns |
| tasks | chain | 42 ns | 43 ns |
| tasks | fanout | 81.8 ms | 82.5 ms |
| tasks | yield | 5 ns | 5 ns |
| tasks | hog | 87.38 us | 81.33 us |
| tasks | memory | 17.1 KiB | 17.1 KiB |
| actors | solo / contend / spread | 5 / 25 / 0.8 ns | 5 / 25 / 0.8 ns |
| net | pingpong | 14.69 us | 14.81 us |
| net | echo | 5.96 us | 5.92 us |
| net | connect | 45.19 us | 48.47 us |
| http | req/s | 172,223 | 174,056 |
| http | p50 / p99 | 363 / 629 us | 358 / 603 us |

All within the spread: `spawn` ran 109 to 118 ns a round for main and
96 to 114 for the branch, `connect` 45.19 to 50.86 and 48.47 to 50.69.
In the five interleaved rounds the second build's `http` found no
ephemeral port free right after the first's (`can't assign requested
address`), so each build's `http` ran in the rounds it went first (main
3, the branch 2); the two more rounds, 40 s apart, ran both. Each
PROGRESS.md has the two rows for each machine.

## std.json

`PATH=<branch>/bin:$PATH tools/low bench/json/guard.py` on the Mac,
instructions per byte against guard.txt:

| file | instructions per byte | baseline |
|---|---:|---:|
| twitter | 7.8807 | 7.9344 (0.7% fewer) |
| twitterescaped | 9.3647 | 9.4241 (0.6% fewer) |
| canada | 16.1443 | 16.1583 (0.1% fewer) |
| citm_catalog | 8.0329 | 8.0698 (0.5% fewer) |
| gsoc-2018 | 3.4379 | 3.4624 (0.7% fewer) |
| github_events | 7.0060 | 7.0534 (0.7% fewer) |

Within 2% on all six; the same as #725's to the third place. The Mac
runs none of the new code.

## Gates

- A failing case first: the test above, failing on pup without the
  advice; the allocator's tests pass on pup at Debug, ReleaseSafe and
  ReleaseFast and on the Mac (where the new one is skipped).
- `tools/heavy swarm test/rig.rip all -q -w 6` on the Mac: 10,659 jobs,
  none died (run with `RIG_SANITIZE=1`, as the runner sets).
- `zig build test` on pup at `-Doptimize=debug`, `safe` and `fast`: all
  pass.
- Trig's light gate (`PUP_RIG=<branch rig on pup> tools/light`, from a
  clone of Trig main `403a823` whose release slots leave out 10-11):
  GREEN in 43 s.
- loco's light gate (`rig/tools/light RIG=<branch bin/rig>`, loc
  `947ffa0`): GREEN in 30 s, 122 runs, none differ.
- std.json's guard: within 2% on all six files (above).
- The runtime benches on pup and the Mac: above, rows in each
  PROGRESS.md.

## Files

`build.sh` builds each Rig and Trig with it on pup; `measure.py` times
Trig; `run.sh` ran every pup measurement in turn; `bench.sh` and
`macbench.sh` build and time the runtime benches; `benchsum.py` and
`hbsum.py` sum their logs.
