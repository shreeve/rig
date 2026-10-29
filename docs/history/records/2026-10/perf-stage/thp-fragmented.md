# Huge pages when memory is fragmented (2026-10-28)

**Question.** Rig asks Linux for transparent huge pages
(`MADV_HUGEPAGE`) in three places: a reserved Table past its first
2 MiB (#754, `src/table.zig` `reserve`), each new segment of a heap that
faults in ahead (#740, `src/alloc.zig` `newPage`), and a new large block
of 16 MiB or more (`allocLarge`, `remap`). pup runs the distribution
defaults, THP `enabled=madvise` and `defrag=madvise`, under which a
fault in an advised range compacts memory in the fault when no free
2 MiB block is left. From about 10:40 to 13:00 on 2026-10-28, with pup's
memory fragmented by builds, ts-pattern's kernel cycles on main went
from 0.26G a run to a median of 1.7G
([check-bisect.md](check-bisect.md), "Machine state"). How do Rig's huge
pages behave when memory is fragmented, which of the three users stall,
and should #754 be reverted (#760) or each user gated?

**Answer.** With memory fragmented on purpose so that no free 2 MiB
block is left, pup reproduces the stall. Main's ts-pattern spends a
median of 1.96-2.04G kernel cycles (0.25G quiet) and runs 34-41% slower
than a build with no huge pages; zod3 is hit in some runs and not
others, from 0.4% faster to 78% slower at the median. Late in the
afternoon pup fragmented by itself, under other sessions' builds, to
35-64 free 2 MiB blocks, and main ran 3.9% slower than no huge pages on
ts-pattern there too.

- **Two users stall: the Tables' (#754), most, and the segments'
  (#740).** The revert alone (#760) still runs 17-18% slower than no
  huge pages on ts-pattern. With the segments' advice also removed, it
  runs as no huge pages does.
- **The large blocks' advice costs nothing measurable on Trig.**
  ts-pattern makes one block of 16 MiB and zod3 none, but such a block
  faults the same way.
- **Quiet, the huge pages are worth keeping.** Main is 5.3% faster than
  no huge pages on ts-pattern and 4.8% on zod3. The Tables give about
  3.9 and 0.5 points of it, the segments 1.7 and 4.0. They cost 9.8 MiB
  (ts-pattern) and 5.1 MiB (zod3) more peak memory.

**A gate keeps both.** Rig advises only while `/proc/buddyinfo` shows
enough free 2 MiB blocks. With 128 blocks to spare the gate never
stalled at any level. Quiet, it kept the gain: 5.2% faster than no huge
pages on ts-pattern, where main was 5.4% in the same rounds. With 16 to
spare it kept more of the gain when a few dozen blocks were free, but
stalled in 7 of 20 runs. The other two candidates lose:

- `MADV_COLLAPSE` costs more than small pages when memory is quiet and
  fails when it is not.
- Gating on `defrag` being `defer` or `never` turns huge pages off on
  every system left at the defaults, pup among them.

**Recommendation:** gate all three users on 128 free 2 MiB blocks to
spare (the default) rather than revert #754, and close #760.

Measurement only: no change on main. The fragmenter, the patches, the
scripts, and every run's raw output are in
[thp-fragmented-data/](thp-fragmented-data/).

## Method

- **Builds.** Trig `403a823`, `tools/trig/main.rig` as the root, built
  `rig build --release --pgo`, trained by `tools/trig/bolt-train`, as
  `tsrs-standing-2` built it, by six Rigs:

  | build | Rig | `MADV_HUGEPAGE` for | binary (sha256) |
  |---|---|---|---|
  | (a) | main `773978d1d` (#754) | Tables, segments, large blocks | `4147764dce2d4773` |
  | (b) | the #760 revert: `2c01f07dd`, whose `src/` is the revert's | segments, large blocks | `82a765e7d34b8eb2` |
  | (c) | (b) with `c-no-segment-huge.patch` | large blocks | `4332770d444947fa` |
  | (d) | (b) with `d-no-huge.patch` | nothing | `ad6654099059c3a5` |
  | (e) | (a) with `e-buddy-gate.patch` | all three, each only while free 2 MiB blocks number the range's need (its size in 2 MiB, at most 16) and 16 more | `39d31b884e241eb6` |
  | (e2) | (a) with `e2-buddy-gate-128.patch` | as (e), 128 more | `f02e400634124018` |

  (a) and (b) are `tsrs-standing-2`'s binaries. The others were built in
  clones of their own (`build.sh`), Rig on cores 10,11 and Trig through
  `/zfs/trig-pup/trial/slot.sh` with `TRIG_RELEASE_SLOTS="10,11 10,11
  10,11"`, 23 to 32 minutes each.
- **What each asks for.** `strace` of (a) shows that ts-pattern advises
  37 Table reservations (24 MiB to 4 GiB of address space each), 12
  segments and one 16 MiB block; zod3 advises the same 37 Tables and 6
  segments. Quiet, ts-pattern takes 78 huge pages on (a) and 25 on (b),
  and zod3 takes 16 and 10 (`thp_fault_alloc`).
- **The fragmenter** (`frag.c`) works in three steps, and prints
  `/proc/buddyinfo` after each:
  1. It maps M bytes advised `MADV_NOHUGEPAGE` and writes them. M is the
     least of `MemFree` less 512 MiB, `MemAvailable` less 13 GiB, and a
     cap. The buddy allocator hands out its smallest free blocks first,
     so this takes the free memory of orders 0 to 8 before any 2 MiB
     block.
  2. It frees every other 4 KiB page of it, so M/2 comes back as single
     pages whose buddies are held.
  3. It takes every free block of order 9 or more that is left, as many
     2 MiB pages advised `MADV_HUGEPAGE`, and holds them.

  It never leaves less than 13 GiB available by its own doing, a GiB
  above `slot.sh`'s 12, and the time script waits while it cannot. The
  levels:
  - **light**, the level timed throughout: M capped at 2 GiB. It holds
    1.1-1.65 GiB, at most 2.6 GiB for a moment. On a trial, 224 free
    2 MiB blocks before and 2 after, counting outside the `DMA` zone
    (whose blocks no user page takes).
  - **heavy**: M uncapped. With the machine to itself it wrote 10.2 GiB
    and held 5.4 GiB (on a trial, 91 free blocks before and 2 after). In
    the e2 run, other sessions held 16 GiB, so it held only 0.9-1.7 GiB,
    about what light does.
  - **quiet**: `unfrag.c` first faults in 256 huge pages and frees them,
    which compacts if it must. In r10 and r20 a quiet run started with
    300 or more free 2 MiB blocks. In the e2 run other sessions had
    fragmented memory, `unfrag` could make only 45 of its 256, and the
    "quiet" runs started with 35-64 free blocks. Those are reported
    apart, as **natural**.

  A fresh fragmenter is made for each fragmented run and killed (by its
  pid) as the run ends; the next run waits 2 s. The light level is
  milder than the afternoon's state, since it leaves free blocks of
  orders 7 and 8. Yet main's kernel cycles under it (median 1.52G on
  ts-pattern in r10, 1.96G in r20) match what the afternoon showed
  (median 1.7G, up to 3.3G).
- **Timing** (`time.sh`, `summ.py`):
  - **Setup.** pup core 1 with sibling 2 idle, running
    `-p tsconfig.trig.json --noEmit --singleThreaded`. In each round
    every build runs once, in an order rotated each round, each run
    quiet and then at each fragmented level; ts-pattern's rounds come
    first, then zod3's.
  - **Measures.** Wall time is perf's `duration_time`; user and kernel
    cycles come from `cpu_core`; also page faults, peak RSS from
    `/usr/bin/time`, and the change over the run in `/proc/vmstat`'s
    `thp_fault_alloc`, `thp_fault_fallback`, `compact_stall`,
    `compact_success` and `compact_fail`. Those counters are the whole
    machine's, so other sessions' work can show in them: in r10, (d),
    which advises nothing, saw a median of 55 `thp_fault_alloc`. The
    cycles and faults are Trig's own.
  - **Comparisons.** "Faster" and "slower" are the median over rounds of
    each round's ratio to (d) in the same round and level, with the
    25th to 75th percentile of the wall ratio. Every output was the
    reference's, byte for byte.
- **Runs.** Load average was 1.3 to 4 throughout, from other sessions'
  builds and timing on other cores, and from this record's own builds
  on 10,11 during r10.
  - r10: (a)-(d), quiet and light, 10 rounds (15:06-15:13).
  - r20: (a)-(e), quiet and light, 20 rounds (15:38-15:54).
  - e2: (a), (b), (d), (e) and (e2), natural, light and heavy, 10
    rounds (16:27-16:45).
  - quiet: (a), (d), (e) and (e2), quiet alone, 10 rounds (16:48-16:50),
    once `unfrag` had brought pup back to 175 or more free blocks
    (`quietrun.sh`).
- **The micro test** (`collapse.c`, `micro.sh`, `micro.txt`): 64 MiB of
  fresh memory put in huge pages four ways, each in a process of its
  own, quiet, light and heavy, 5 rounds.

## The builds, quiet and fragmented

r20, 20 rounds, against (d), no huge pages:

| ts-pattern | quiet: wall | kernel cycles | vs (d) | light: wall | kernel cycles | vs (d) [25th, 75th] | `compact_stall` | peak RSS |
|---|---:|---:|---|---:|---:|---|---:|---:|
| (a) main | 788 ms | 0.25G | 5.3% faster | 1202 ms | 1.96G | 34.1% slower [+13.5%, +68.4%] | 192 | 269.0 MB |
| (b) #760 revert | 823 ms | 0.36G | 1.4% faster | 1009 ms | 1.08G | 16.9% slower [+5.2%, +36.4%] | 71 | 258.5 MB |
| (c) revert, no segment advice | 838 ms | 0.38G | 0.3% slower | 862 ms | 0.36G | 0.3% slower [-2.4%, +7.8%] | 9 | 260.3 MB |
| (d) no `MADV_HUGEPAGE` | 841 ms | 0.38G | | 858 ms | 0.35G | | 0 | 259.2 MB |
| (e) gated, 16 spare | 793 ms | 0.25G | 4.7% faster | 917 ms | 0.36G | 2.5% slower [-1.6%, +30.1%] | 0 | 272.2 MB |

| zod3 | quiet: wall | kernel cycles | vs (d) | light: wall | kernel cycles | vs (d) [25th, 75th] | `compact_stall` | peak RSS |
|---|---:|---:|---|---:|---:|---|---:|---:|
| (a) main | 156 ms | 0.09G | 4.8% faster | 162 ms | 0.11G | 0.4% faster [-2.5%, +15.1%] | 14 | 88.2 MB |
| (b) #760 revert | 157 ms | 0.10G | 4.3% faster | 165 ms | 0.12G | 1.2% slower [-1.7%, +5.2%] | 5 | 81.8 MB |
| (c) revert, no segment advice | 161 ms | 0.10G | 0.3% faster | 162 ms | 0.10G | 0.9% faster [-3.4%, +3.3%] | 0 | 83.3 MB |
| (d) no `MADV_HUGEPAGE` | 163 ms | 0.10G | | 164 ms | 0.10G | | 0 | 83.1 MB |
| (e) gated, 16 spare | 154 ms | 0.09G | 4.8% faster | 162 ms | 0.10G | 1.2% faster [-3.5%, +1.5%] | 0 | 90.8 MB |

The e2 run, 10 rounds, wall against (d) and kernel cycles; "natural" is
memory other sessions had fragmented, 35-64 free 2 MiB blocks at the
start (ts-pattern) and about 45 (zod3):

| | ts-pattern natural | light | heavy | zod3 natural | light | heavy |
|---|---|---|---|---|---|---|
| (a) main | 3.9% slower, 0.67G | 40.6% slower, 2.04G | 44.1% slower, 2.41G | 3.2% faster, 0.10G | 78.4% slower, 0.79G | 114.5% slower, 0.96G |
| (b) #760 revert | 2.4% faster, 0.34G | 18.4% slower, 1.00G | 20.7% slower, 1.21G | 3.6% faster, 0.10G | 8.4% slower, 0.11G | 6.4% slower, 0.11G |
| (d) no `MADV_HUGEPAGE` | 0.38G | 0.34G | 0.34G | 0.11G | 0.10G | 0.10G |
| (e) gated, 16 spare | 4.3% faster, 0.31G | 1.7% slower, 0.34G | 1.7% slower, 0.34G | 1.9% faster, 0.10G | 1.6% faster, 0.10G | 0.7% slower, 0.10G |
| (e2) gated, 128 spare | 0.3% faster, 0.36G | 1.5% slower, 0.35G | 0.1% slower, 0.35G | 1.1% faster, 0.11G | 0.0% slower, 0.10G | 1.2% slower, 0.10G |

Read from these:

- **The stall is all in the kernel**, as it was in the afternoon. User
  cycles do not move with the level (ts-pattern 3.54-3.77G, zod3
  0.65-0.69G).
- **r10 agrees on ts-pattern** (`times-r10.txt`). Under the light level,
  (a) is 29.8% slower than (d), (b) 14.4% slower, and (c) 0.3% faster.
  Quiet, (a) is 6.6% faster and (b) 1.6% faster.
- **zod3 is a lottery.** It needs 16 huge pages. A run that starts with
  a few free blocks, while the kernel defers compaction after earlier
  failures (`compact_defer_shift`, state that outlives a run), often
  gets through. So (a) on zod3 under the light level read 13.2% slower
  in r10, 0.4% faster in r20, and 78.4% slower in the e2 run.

## Which users stall

- **Tables (#754) stall the most.** Under the light level in r20, (a)
  against (b) on ts-pattern is 0.88G more kernel cycles at the median,
  121 more compaction stalls, and 17.2 of the 34.1 points. A Table's
  reservation is advised once, for all of it, so every 2 MiB the Table
  grows into later faults through the compactor.
- **Segments (#740) stall as surely, less often.** (b) against (c) is
  0.72G more kernel cycles, 62 more stalls, and 16.6 points. Each 4 MiB
  segment is advised and populated at once.
- **Large blocks of 16 MiB or more cost nothing measurable on Trig.**
  (c) against (d) is within the noise at both levels; ts-pattern makes
  one such block (9 stalls a run). The mechanism is the same, so a
  program that makes many large blocks would stall as the others do.

What one advised fault costs when it must compact (`micro.txt`). Each
way puts 64 MiB in place; the table gives the median of 5 in wall ms,
and how much ended in huge pages:

| way | quiet | light | heavy |
|---|---|---|---|
| `MADV_HUGEPAGE`, then written (Rig's way) | 5.9 (64 MiB huge) | 31.5, up to 872 (2 MiB) | 904, 551-1039 (0) |
| written in 4 KiB pages, then `MADV_COLLAPSE` | 33.4 (64 MiB) | 18.0, up to 76 (0) | 18.4, up to 103 (0) |
| `MADV_HUGEPAGE` only if `buddyinfo` shows 32 free blocks | 5.8 (64 MiB) | 16.4 (0) | 16.5 (0) |
| 4 KiB pages, no advice | 15.7 (0) | 16.2 (0) | 16.2 (0) |

With no free 2 MiB block, an advised fault is 2 to 60 times slower than
small pages, and it still mostly ends in small pages. The compaction
fails (`compact_fail` is nearly every `compact_stall` in every run) and
the kernel falls back.

## A stall-free form

The kernel offers no per-range "huge if free, never compact". Under
`defrag=madvise`, which is Ubuntu's default and pup's, only an advised
range gets huge pages at all, and an advised range compacts in its
faults. The three candidates:

1. **Advise only when `defrag` is `defer` or `never`.** Under `defer`
   an advised fault takes a free 2 MiB block or falls back at once, so
   it never stalls. But on a system left at the defaults it never
   advises, which is build (d): the quiet gain is gone. It is worth
   keeping only as a short cut beside a gate: where `defrag` is
   `defer`, no check is needed, and where it is `never`, advice changes
   nothing.
2. **`MADV_COLLAPSE` once a 2 MiB window is filled.** It ignores
   `defrag`, always compacts if it must, and copies. Quiet, it took
   33.4 ms for 64 MiB, where faulting huge took 5.9 ms and small pages
   15.7 ms, so it is slower than no huge pages before the TLB gain
   starts. Fragmented, it fails (0 MiB huge) in 18 ms, up to 103. It
   loses on both counts, and a Table has no hook at which a window is
   known to be full.
3. **A check of free 2 MiB blocks first.** Each advice first reads
   `/proc/buddyinfo` once (55 times on ts-pattern, 48 on zod3) and
   counts the blocks of order 9 and up outside the `DMA` zone. It
   advises only if they number the range's need (its size in 2 MiB, at
   most 16) and a margin more. Its cost is within the noise: quiet, (e)
   is 4.7% faster than (d) on ts-pattern where (a) is 5.3%, and 4.8% on
   zod3 as (a) is, with the same 78 and 16 huge pages. The margin
   decides the rest:
   - **16 to spare (e)** stops the stall whenever free blocks are
     scarce, but not when a few dozen are free. In 13 of 20 light runs
     in r20 it started with 2 to 16 free blocks, advised nothing, and
     ran as (d) did (0.33-0.37G kernel cycles). In the other 7 it
     started with 41 or 42, advised, took about 40 huge pages, and then
     stalled 74-80 times (1.5-5.2G kernel cycles, 22-110% slower than
     the median of (d)). Where memory was fragmented naturally (35-64
     free), it advised, took about 60 huge pages, stalled less (median
     29 stalls, 0.31G kernel cycles), and came out 4.3% faster than (d).
     A margin smaller than what a program takes (Trig: 78) lets one run
     drain the free blocks and stall on the rest.
   - **128 to spare (e2)** never stalled at any level, natural, light or
     heavy: 0 compaction stalls and (d)'s kernel cycles. Where 35-64
     blocks were free, it advised nothing and gave up the gain (0.3%
     faster than (d) on ts-pattern, 1.1% on zod3). Quiet, it keeps the
     gain. In a quiet run of (a), (d), (e) and (e2) (`times-quiet.txt`,
     16:48-16:50, 10 rounds), every run started with 175-244 free blocks,
     the most compaction could make by then. There (e2) took the same 78
     and 16 huge pages as (a), with no stall. It was 5.2% faster than (d)
     on ts-pattern, where (a) was 5.4% and (e) 5.8%. On zod3 it was 2.4%
     faster, where (a) was 4.4% and (e) 2.9%.

The check is made when a range is advised. A segment is populated as it
is advised, so its check is current. A Table is advised once, as it is
reserved, for all of its reservation, and faults as it grows. So a
Table reserved while memory was free and grown after it fragmented can
still stall. A program that runs for seconds, as Trig does, meets this
only when another program drains the free blocks while it runs. A
long-running one would want its Tables advised a window at a time,
which needs a hook on the growth path; #754's record found such a hook
costly ([fault-ahead/](fault-ahead/README.md)).

## Recommendation

1. **Tables (#754): gate, do not revert** (default). Close #760. The
   Tables' quiet gain (3.9 of ts-pattern's 5.3 points) is the largest of
   the three, and the gate removes the stall measured here.
2. **Segments (#740): gate** (default), with the same check inside
   `adviseHuge`. Their quiet gain is 1.7 points on ts-pattern and 4.0 on
   zod3, and they stall as surely as the Tables do.
3. **Large blocks: gate** (default), through the same `adviseHuge`. No
   gain or loss was measured on Trig, and the exposure is the same.
4. **The margin: 128 free 2 MiB blocks** (default). This is above
   Trig's 78 huge pages, and it never stalled. The alternative is 16,
   which keeps the gain when a few dozen blocks are free but stalled in
   7 of 20 light runs.

The gate is one function, `hugeFree`, in `alloc.zig` and `table.zig`
(`e2-buddy-gate-128.patch`). Built properly, it would live once, read
`defrag` first, and come with a test.

## Effect on other sessions

The fragmenter held memory only while a fragmented run was timed, each
hold lasting a few seconds, in these windows:

- 14:05-14:06, an aborted first start of `time.sh`, whose Trig runs
  failed at once;
- 14:07, a trial;
- 14:10-14:13, the micro test;
- 15:06-15:13, r10;
- 15:38-15:54, r20;
- 16:27-16:45, the e2 run.

A Rig program that advised huge pages on another core in those seconds
would have met the same stall. Trig timing on pup in those windows
should check its kernel cycles.
