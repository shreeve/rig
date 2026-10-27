# Large blocks: reuse by fit, and huge pages measured (2026-10-27)

The hash race's prover found two gaps in the release allocator
(`src/alloc.zig`; [prover.md](../hash-race/prover.md), section 2):
big-value inserts on pup took 1.75 times malloc's time, because a freed
block over 32 KiB was reused only by a request of its exact size and a
heap kept at most 16 MiB of them; and Rig asks for no huge pages, which
glibc's malloc with `hugetlb=1` showed are worth about 11% on the 4M-key
rows. Rig - Swiss asked, for the owner, for both fixes as one PR,
measured on Trig. The first is kept; the second, as decided (huge pages
for blocks of 2 MiB or more), raised Trig's peak memory and is left out.

## What changed

- **Reuse by fit.** A heap keeps freed large blocks in buckets (four
  per doubling), each block at least its bucket's size, with a bit per
  bucket that holds any. A request takes the first block of the lowest
  bucket from its own that holds one at least its size, and keeps what
  is past it as a block of its own (a piece smaller than the smallest
  large request, 40 KiB on Linux and 48 KiB on the Mac, is unmapped).
- **The bound.** A heap keeps a freed block while what it holds in large
  blocks, handed out and kept, is no more than the most it has handed
  out at once and 16 MiB more (`keepBound`: the bytes kept may be up to
  `large_peak - large_live + keep_large`). A free and a reuse leave
  "handed out and kept" unchanged, so only new pages can pass the bound;
  after mapping them (or growing a block by `mremap`) the heap gives back
  kept blocks until it is within it: the smallest block that alone is
  enough, else the largest, and again. Before, the bound was 16 MiB kept
  at any time; the peak the bound allows is the same, the most handed
  out at once and 16 MiB, since at that peak the heap keeps 16 MiB at
  most.
- A block another heap made, freed here, counts against this heap's
  bound as new pages would (its count of live bytes floors at zero).

Two first tries were taken out. A trim that gave back the largest kept
block first gave back, on `big1000000`, the last round's 80 MiB table
to make room for a 10 MiB one, and the next round mapped it afresh
(`sim.zig` replays the row's allocations, four rounds, and prints what
the heap took from the system each round; on the Mac: main 319 MiB a
round, the largest-first trim 279, the smallest-that-covers trim 239).
And a cap, a request taking only a block less than about 2.5 times its
size, left a round's first growths to map new pages beside the last
round's big blocks: without it `sim.zig` takes 160 MiB a round, and on
pup's bench/hash (7 runs, both with the largest-first trim) the big
inserts took 0.75 of main's time against the cap's 0.84.

## Failing first

Two cases, written against main's `allocLarge` and `freeLarge` on a
heap of their own, fail on main and pass on the branch (the branch's
test, "a freed large block serves a smaller request and keeps the
rest...", holds both and more):

    main: a freed 4 MiB block serves a 2 MiB request
      ...expected u8@10815c000, found u8@10855c000
    main: 32 MiB of 512 KiB blocks built again take no new pages
      ...expected 33554432, found 50331648

## Trig on pup

Trig main `403a823` (src/ with tools/trig/main.rig), built release
(`rig build --release`, as Trig ships) by Rig main `54a7158b5` (base) and
by that commit with the change (reuse), and with huge pages as decided
(thp: reuse, and on Linux every new block of 2 MiB or more mapped
aligned to 2 MiB with `MADV_HUGEPAGE`, the same after an `mremap`
growth), on release slots 1-2 and 0-5 (`build.sh`). `measure.py`:
ts-pattern and zod3, `trig -p tsconfig.trig.json --noEmit`, at
`--checkers 1` on core 8 (9 idle) and `--checkers 4` on cores 6 to 9,
the builds interleaved, the order reversed every other round; the
fastest wall with its user time, the least sys time, the fewest user
instructions and page faults, peak RSS (`/usr/bin/time %M`) median and
largest. Outputs agreed in every run. pup's THP is `madvise`, defrag
`madvise`; kernel 7.0.0.

Under `perf stat` (instructions and page faults), 20 rounds
([trig-perf.md](trig-perf.md); walls include perf's start):

| project | checkers | build | wall s | user s | sys s | instructions (user) | page faults | RSS MB |
|---|---|---|---:|---:|---:|---:|---:|---:|
| ts-pattern | 1 | base | 1.098 | 0.983 | 0.104 | 9,480.6M | 40,942 | 298.1 |
| ts-pattern | 1 | reuse | 1.070 | 0.949 | 0.091 | 9,480.5M | 40,758 | 295.0 |
| ts-pattern | 1 | thp | 1.051 | 0.950 | 0.088 | 9,481.0M | 37,862 | 300.8 |
| ts-pattern | 4 | base | 0.615 | 1.653 | 0.142 | 9,969.9M | 48,755 | 340.8 |
| ts-pattern | 4 | reuse | 0.600 | 1.620 | 0.140 | 9,970.2M | 48,013 | 332.8 |
| ts-pattern | 4 | thp | 0.589 | 1.631 | 0.142 | 9,970.0M | 47,256 | 337.1 |
| zod3 | 1 | base | 0.219 | 0.178 | 0.034 | 1,714.0M | 9,788 | 90.8 |
| zod3 | 1 | reuse | 0.213 | 0.177 | 0.026 | 1,714.7M | 9,636 | 89.2 |
| zod3 | 1 | thp | 0.216 | 0.172 | 0.031 | 1,712.8M | 9,526 | 89.3 |
| zod3 | 4 | base | 0.179 | 0.381 | 0.057 | 2,335.5M | 19,165 | 136.8 |
| zod3 | 4 | reuse | 0.175 | 0.379 | 0.052 | 2,333.9M | 18,928 | 132.7 |
| zod3 | 4 | thp | 0.172 | 0.364 | 0.060 | 2,334.0M | 18,899 | 132.7 |

With no perf, 20 rounds, a fourth build, thp16 (huge pages from 16 MiB,
not the decided 2 MiB), and minor faults from `/usr/bin/time %R`
([trig-wall.md](trig-wall.md)):

| project | checkers | build | wall s | user s | sys s | minor faults | RSS MB |
|---|---|---|---:|---:|---:|---:|---:|
| ts-pattern | 1 | base | 0.977 | 0.879 | 0.080 | 74,404 | 298.1 |
| ts-pattern | 1 | reuse | 0.975 | 0.880 | 0.082 | 73,790 | 295.0 |
| ts-pattern | 1 | thp | 0.965 | 0.871 | 0.079 | 63,304 | 300.8 |
| ts-pattern | 1 | thp16 | 0.969 | 0.877 | 0.081 | 72,552 | 296.2 |
| ts-pattern | 4 | base | 0.534 | 1.422 | 0.124 | 86,290 | 340.8 |
| ts-pattern | 4 | reuse | 0.537 | 1.438 | 0.104 | 84,523 | 332.9 |
| ts-pattern | 4 | thp | 0.520 | 1.406 | 0.120 | 80,918 | 337.1 |
| ts-pattern | 4 | thp16 | 0.526 | 1.421 | 0.113 | 84,524 | 332.8 |
| zod3 | 1 | base | 0.189 | 0.158 | 0.021 | 21,314 | 90.8 |
| zod3 | 1 | reuse | 0.185 | 0.163 | 0.021 | 21,117 | 89.2 |
| zod3 | 1 | thp | 0.187 | 0.160 | 0.018 | 20,513 | 89.3 |
| zod3 | 1 | thp16 | 0.187 | 0.160 | 0.019 | 21,118 | 89.2 |
| zod3 | 4 | base | 0.150 | 0.344 | 0.036 | 34,272 | 136.8 |
| zod3 | 4 | reuse | 0.145 | 0.319 | 0.048 | 33,649 | 132.8 |
| zod3 | 4 | thp | 0.153 | 0.333 | 0.035 | 33,041 | 132.7 |
| zod3 | 4 | thp16 | 0.149 | 0.318 | 0.042 | 33,649 | 132.7 |

**Reuse, against base.** Instructions the same (within 0.07% either
way). Peak memory lower in every case: ts-pattern 1.0% at one checker
and 2.3% at four, zod3 1.8% and 3.0%. Page faults 0.4 to 1.6% fewer.
The walls move within the noise: 2.3 to 2.8% faster under perf, and
0.6% slower to 3.4% faster without it, where ts-pattern moved 0.2% and
0.6%. So on Trig the change does not clear the speed bar (more than 2%
faster or 1% fewer instructions); it lowers peak memory, and the case
for it is bench/hash's rows, below.

**Huge pages, as decided, against reuse.** Peak memory higher on
ts-pattern: 2.0% at one checker (300.8 MB against 295.0) and 1.3% at
four (337.1 against 332.8); zod3 unchanged. Page faults 7.1% fewer on
ts-pattern at one checker (perf), 14% fewer minor faults; instructions
the same. The walls: ts-pattern 1.0 to 1.8% faster at one checker and
1.9 to 3.2% at four; zod3 1.7% faster to 5.5% slower. Decision 11 lands
huge pages only if Trig's peak memory is not higher; it is, so they are
left out (and INTERNALS says so).

**thp16**, huge pages for new blocks of 16 MiB or more: peak memory as
reuse's (ts-pattern 0.4% higher at one checker, the same at four; zod3
the same), walls within the noise (ts-pattern 0.6% and 2.1% faster, zod3
1.1% and 2.8% slower). Its effect on bench/hash is below. It is not the
decided design, so it is not in the change; it is a question for the
owner.

## bench/hash

The prover's harness from `hash-bench-2` (uncommitted there), copied with
`ZIG_ALLOCS` naming one copy of `alloc.zig` per variant: `zig-foa`
(map.zig on the port of boost's flat map) on main's allocator (rigmain;
rigmain2 an identical second build, the control), the change (rigreuse),
the change with huge pages from 2 MiB (rigthp) and from 16 MiB
(rigthp16), and libc's malloc. `bench-hash --reps 9 --mem`, fastest of
9 per row; pup on core 8 (9 idle), the Mac through `tools/low`.
`hbsum.py` sums each report as the prover's table: each variant's time
against main's, the geometric mean over a group of rows (under 1.00 is
faster).

pup, run 3 ([hb-pup-3.txt](hb-pup-3.txt)):

| rows | n | rigmain2 (control) | rigreuse | rigthp | rigthp16 |
|---|---:|---:|---:|---:|---:|
| Int: insert, remove, turnover | 24 | 0.963 | 0.969 | 0.939 | 0.949 |
| Int: lookups, iterate | 30 | 0.994 | 1.008 | 1.013 | 1.022 |
| Int: 3M and 4M rows | 18 | 0.986 | 0.967 | 0.863 | 0.866 |
| Text: insert, remove | 8 | 1.054 | 0.974 | 0.961 | 0.978 |
| Text: hit, miss | 8 | 0.983 | 0.988 | 0.992 | 0.990 |
| Big values: insert | 4 | 1.009 | 0.761 | 0.661 | 0.683 |
| Big values: remove, hit, iterate | 12 | 1.006 | 1.006 | 0.974 | 0.980 |
| All | 104 | 0.991 | 0.977 | 0.943 | 0.951 |

pup, run 2 ([hb-pup-2.txt](hb-pup-2.txt)), with malloc:

| rows | n | rigreuse | rigthp | malloc |
|---|---:|---:|---:|---:|
| Int: insert, remove, turnover | 24 | 0.971 | 0.959 | 0.995 |
| Int: lookups, iterate | 30 | 1.009 | 1.016 | 1.015 |
| Int: 3M and 4M rows | 18 | 0.967 | 0.883 | 1.006 |
| Text: insert, remove | 8 | 0.910 | 0.901 | 1.432 |
| Text: hit, miss | 8 | 0.992 | 0.986 | 1.036 |
| Big values: insert | 4 | 0.769 | 0.668 | 0.567 |
| Big values: remove, hit, iterate | 12 | 1.015 | 0.986 | 1.002 |
| All | 104 | 0.974 | 0.949 | 1.013 |

The Mac ([hb-mac-1.txt](hb-mac-1.txt)), where the change is the same
with or without huge pages:

| rows | n | rigreuse | malloc |
|---|---:|---:|---:|
| Int: insert, remove, turnover | 24 | 0.999 | 1.009 |
| Int: lookups, iterate | 30 | 1.002 | 0.989 |
| Int: 3M and 4M rows | 18 | 0.992 | 0.983 |
| Text: insert, remove | 8 | 0.964 | 1.816 |
| Text: hit, miss | 8 | 1.006 | 1.043 |
| Big values: insert | 4 | 0.810 | 0.790 |
| Big values: remove, hit, iterate | 12 | 0.997 | 0.992 |
| All | 104 | 0.988 | 1.036 |

The big inserts, ns per insert:

| row | pup main | pup reuse | pup thp | pup malloc (run 2) | Mac main | Mac reuse | Mac malloc |
|---|---:|---:|---:|---:|---:|---:|---:|
| big16 | 22.02 | 22.17 | 22.17 | 13.39 | 9.39 | 9.14 | 9.09 |
| big1000 | 43.78 | 26.52 | 26.41 | 26.84 | 19.29 | 13.56 | 15.67 |
| big100000 | 41.86 | 26.86 | 23.67 | 23.72 | 18.12 | 12.40 | 12.12 |
| big1000000 | 94.88 | 81.11 | 52.80 | 44.11 | 31.52 | 28.99 | 23.33 |

So on pup `big1000` is 65% faster and `big100000` 56% faster, level with
malloc; `big1000000` 17% faster, still 1.84 times malloc's time (its
last table, 160 MiB, is mapped afresh each round, where glibc's heap
already holds it), which huge pages bring to 1.20 times. On the Mac
`big1000` is 42% faster, `big100000` 46%, `big1000000` 8.7%. The big
inserts' geometric mean on pup is now 1.36 times malloc's time, from
1.76. `big16`'s maps are small blocks, unchanged. Peak memory for one
4M-key map is the same (54.7 bytes an entry on pup, 54.5 on the Mac).

Nothing is slower beyond the control's spread: in run 3 the control
(identical code) has 8 rows over 3% from main, and its groups move from
0.963 to 1.054. The rows over 3% slower for rigreuse in both pup runs
are `int16 miss` (1.35 to 1.93 ns, and 1.43 to 2.04 in run 2) and none
other; a miss in one 16-key map allocates nothing, and the same row was
12.6% faster in the first run of the change (with the cap), so it is
the binary's layout, not the allocator. The 4M rows with huge pages are
14% faster on pup (thp or thp16), as the prover measured with glibc.

## Runtime benches

`bench/tasks`, `bench/actors`, `bench/net`, `bench/http` (rig-fast),
base and the change interleaved, best of each round's 3 runs
(`bench.sh`, `benchsum.py`). pup on cores 6 and 7, 5 rounds
([benches-pup-2.log](benches-pup-2.log)):

| bench | case | base | reuse |
|---|---|---:|---:|
| tasks | spawn | 60 ns | 61 ns |
| tasks | chain | 86 ns | 85 ns |
| tasks | fanout | 309.8 ms | 310.0 ms |
| tasks | yield | 22 ns | 21 ns |
| tasks | hog | 131.65 us | 131.06 us |
| tasks | memory | 4.6 KiB | 4.6 KiB |
| actors | solo / contend / spread | 11 / 15 / 10 ns | 11 / 15 / 10 ns |
| net | pingpong | 5.09 us | 5.00 us |
| net | echo | 3.79 us | 3.84 us |
| net | connect | 28.97 us | 30.08 us |
| http | req/s | 196,316 | 201,191 |
| http | p50 / p99 | 201 / 3448 us | 198 / 3434 us |

All within the run-to-run spread: `net connect`'s rounds run 28.97 to
31.51 us for base and 30.08 to 33.18 for the change, and `echo` 3.79 to
4.08 and 3.84 to 4.15. A first set of 3 rounds, with thp, is
[benches-pup.log](benches-pup.log). None of these programs makes a
block over 32 KiB on a hot path (task stacks are mapped by the
scheduler, not the allocator; net reads 4 KiB).

The Mac through `tools/low` (`macbench.sh`), 5 rounds, at load 5 to
18 from other sessions' suites ([benches-mac.log](benches-mac.log)):

| bench | case | base | reuse |
|---|---|---:|---:|
| tasks | spawn | 111 ns | 112 ns |
| tasks | chain | 44 ns | 44 ns |
| tasks | fanout | 83.7 ms | 83.5 ms |
| tasks | yield | 5 ns | 5 ns |
| tasks | hog | 81.34 us | 75.66 us |
| tasks | memory | 17.1 KiB | 17.1 KiB |
| actors | solo / contend / spread | 5.0 / 26 / 0.8 ns | 5.0 / 25 / 0.8 ns |
| net | pingpong | 14.72 us | 14.82 us |
| net | echo | 5.96 us | 5.92 us |
| net | connect | 49.54 us | 49.98 us |
| http | req/s | 171,133 | 175,673 |
| http | p50 / p99 | 365 / 660 us | 351 / 659 us |

All within the spread (`hog` ran 66 to 146 us a round for either build
in a first set of 3 rounds). The change's fifth `http` round did not
run: right after the base's, the Mac had no ephemeral port left for
the idle connections (`can't assign requested address`), so its row is
the best of 4 rounds. Each PROGRESS.md has the two rows for each
machine.

## std.json

`PATH=<branch>/bin:$PATH tools/low bench/json/guard.py` on the Mac,
instructions per byte against guard.txt:

| file | instructions per byte | baseline |
|---|---:|---:|
| twitter | 7.8771 | 7.9344 (0.7% fewer) |
| twitterescaped | 9.3650 | 9.4241 (0.6% fewer) |
| canada | 16.1459 | 16.1583 (0.1% fewer) |
| citm_catalog | 8.0334 | 8.0698 (0.5% fewer) |
| gsoc-2018 | 3.4378 | 3.4624 (0.7% fewer) |
| github_events | 7.0057 | 7.0534 (0.7% fewer) |

Within 2% on all six. A parse allocates nothing over 32 KiB on its hot
path, so the change cannot move it.

## The earlier lead: in-place growth from 64 KiB

The std.hash records (`archive/std-hash`, `plain-slots.md`, "Next")
left `move_large = 64 << 10` (grow a large block by `mremap` from 64 KiB
rather than 1 MiB) to measure: then, on bench/hash, only the
100,000-key insert moved, 17.8% slower. It was not tried again here:
zig-foa's tables never call `remap`, so bench/hash's Zig rows cannot
show it, and with reuse by fit a List that grows by copying now takes
its next block from what the heap keeps. It stays a lead for a program
whose Lists grow past 64 KiB.

## Gates

- A failing case first: the two above; the branch's allocator tests
  pass (`zig test src/alloc.zig`, ReleaseSafe and Debug, on the Mac).
- `tools/heavy swarm test/rig.rip all -q -w 6` on the Mac: 10,659 jobs,
  none died (run with `RIG_SANITIZE=1`, as the runner sets).
- `zig build test` on pup at `-Doptimize=debug`, `safe` and `fast`: all
  pass.
- Trig's light gate (`PUP_RIG=<branch rig on pup> tools/light`, from a
  clone of Trig main `403a823` whose release slots leave out 10-11):
  GREEN in 50 s.
- loco's light gate (`rig/tools/light RIG=<branch bin/rig>`, loc
  `947ffa0`): GREEN in 50 s, 122 runs, none differ.
- std.json's guard: within 2% on all six files (above).
- The runtime benches on pup and the Mac: above, rows in each
  PROGRESS.md.
