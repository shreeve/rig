# The huge-page gate, measured (2026-10-28)

**Question.** [thp-fragmented.md](thp-fragmented.md) found that Rig's
requests for huge pages stall in the kernel when memory is fragmented,
and that a test of free 2 MiB blocks avoided the stall. The owner
approved the gate: "proceed -- if you see that big benefit, keep it --
if not, revert". The gate is built on branch `thp-gate` (`5b103b53f`).
Does it keep the quiet gain and lose nothing when memory is fragmented?

The bar:
- at least 1.5% faster than no huge pages, quiet, on ts-pattern or zod3;
- never slower than no huge pages, fragmented;
- slower on neither project.

**Answer.** It clears the bar, so the gate is kept.

- **Quiet.** With about 195 free 2 MiB blocks, the gate is 4.6% faster
  than no huge pages on ts-pattern (main 5.4%) and 3.0% on zod3 (main
  4.0%). It takes 76 and 16 huge pages, where main takes 78 and 16.
- **Fragmented.** Under the light level, the gate is within 0.4%
  (ts-pattern) and 0.2% (zod3) of no huge pages, with its kernel cycles
  and no stalls of its own. Main there is 56.8% and 54.2% slower.
- **Partly fragmented.** With 48-62 free blocks, the gate asks for
  nothing and runs as no huge pages does (0.5% slower, within the
  noise). Main stalls and runs 15.6% slower.
- **Memory.** Peak memory is that of main, 12.0 MB (ts-pattern) and
  7.7 MB (zod3) above no huge pages, wherever the gate asks.

**The gate.** On Linux, a Table's `reserve`, a heap's new segment, and
a new or grown large block of 16 MiB ask for huge pages only while
`/proc/buddyinfo` shows more than 128 free blocks of 2 MiB or more
outside the `DMA` zone (order 10 counting as two, and so on).

- **The test.** It is one cold `noinline` function, `alloc.zig`'s
  `hugeFree`, with a 4 KiB buffer on its stack, no allocation, and raw
  `openat` and `read`. A file it cannot read asks for nothing.
- **No cache.** The file is read at each request and nothing is kept.
  The requests are few (55 a run on ts-pattern, 48 on zod3), each at a
  segment's or a block's mapping or a Table's reservation, never on a
  hot path. A cached reading would be out of date exactly when memory
  fragments.

**The gap, kept.** A Table is still advised once, at `reserve`, for its
whole reservation, so a Table grown after memory fragments faults
through the compactor. Advising it a 2 MiB window at a time was not
built, because it cannot be free on the push path:

- `push` now tests `len` against the compile-time `n`. A window would
  have it test against a limit stored in the Table, which is one more
  load on every push and 8 more bytes in every reserved Table (Trig
  declares 43 Tables).
- A slot written by `t[s] = x` past `len` never passes through `push`,
  so the windows it fills would not be advised at all.
- `bench/hash` and its guard cannot measure it, since Map and Set hold
  no Table.

The gap matters only to a program whose Tables grow while another
program drains the free blocks.

## Method

As in [thp-fragmented.md](thp-fragmented.md).

- **Builds.** Three PGO builds of Trig `403a823` (trained by
  `tools/trig/bolt-train`), compared by `time.sh`:
  - (a) main `773978d1d`, whose `src/` is main's at `9f05d492e`;
  - (d) no `MADV_HUGEPAGE`;
  - (g) `thp-gate` `5b103b53f` (`build-g.sh`).
- **Machine.** pup core 1 with sibling 2 idle.
- **Levels.** quiet (`unfrag` first), and light, a fresh `frag.c` of
  2 GiB for each run.
- **Rounds.** 20 interleaved rounds of ts-pattern, then zod3.
- **Runs:**
  - `times-g.txt` (17:36-17:46), quiet and light. Other sessions held
    memory during ts-pattern's quiet runs (48-62 free blocks), which is
    the "partly fragmented" row. zod3's quiet runs had 194 free blocks.
  - `times-g-quiet.txt` (17:46-17:51), quiet alone, once compaction had
    brought pup back to 196. ts-pattern's runs had 196-198 (one
    had 36); zod3's had only
    78-118, so the gate asked for nothing there and zod3's quiet row is
    taken from `times-g.txt`.

| | runs | wall | user cycles | kernel cycles | `compact_stall` | peak RSS | vs (d) |
|---|---:|---:|---:|---:|---:|---:|---|
| ts-pattern, quiet (196 free) | | | | | | | |
| (a) main | 20 | 735 ms | 3.31G | 0.25G | 0 | 269.0 MB | 5.4% faster |
| (d) no advice | 20 | 783 ms | 3.42G | 0.35G | 0 | 259.2 MB | |
| (g) gate | 20 | 739 ms | 3.33G | 0.25G | 0 | 271.2 MB | 4.6% faster |
| ts-pattern, partly fragmented (48-62 free) | | | | | | | |
| (a) main | 20 | 980 ms | 3.71G | 1.09G | 181 | 260.6 MB | 15.6% slower |
| (d) no advice | 20 | 850 ms | 3.70G | 0.38G | 0 | 259.2 MB | |
| (g) gate | 20 | 850 ms | 3.71G | 0.39G | 4 | 259.2 MB | 0.5% slower |
| ts-pattern, light | | | | | | | |
| (a) main | 20 | 1343 ms | 3.80G | 2.78G | 397 | 257.1 MB | 56.8% slower |
| (d) no advice | 20 | 861 ms | 3.68G | 0.39G | 82 | 259.2 MB | |
| (g) gate | 20 | 859 ms | 3.73G | 0.40G | 89 | 259.2 MB | 0.4% slower |
| zod3, quiet (194 free) | | | | | | | |
| (a) main | 20 | 149 ms | 0.62G | 0.09G | 0 | 88.2 MB | 4.0% faster |
| (d) no advice | 20 | 157 ms | 0.64G | 0.11G | 0 | 83.1 MB | |
| (g) gate | 20 | 150 ms | 0.62G | 0.10G | 0 | 90.8 MB | 3.0% faster |
| zod3, light | | | | | | | |
| (a) main | 20 | 242 ms | 0.66G | 0.53G | 47 | 80.5 MB | 54.2% slower |
| (d) no advice | 20 | 155 ms | 0.65G | 0.10G | 0 | 83.1 MB | |
| (g) gate | 20 | 158 ms | 0.67G | 0.10G | 0 | 83.1 MB | 0.2% slower |

Medians, with `compact_stall` the whole machine's over each run. On
ts-pattern under the light level, (d), which asks for nothing, saw 82
stalls a run from other processes, and the gate 89; the cycles are
Trig's own. "vs (d)" is the median of each round's wall ratio.
`summary.txt` has the 25th and 75th percentiles and the rest. Every
output was the reference's.

Rig's gates for the branch:
- `swarm test/rig.rip all` (10,792 jobs), green;
- Trig's light gate against the branch's Rig on pup, GREEN;
- loco's light gate on the Mac, GREEN;
- `bench/json/guard.py`, all six files 0.1-0.8% fewer instructions;
- `bench/hash/guard.py`, every row within 0.3%;
- `zig build test` on pup with `-Doptimize=debug`, `safe` and `fast`,
  passing.
- AGENTS' runtime benches on pup (`bench/tasks`, `bench/actors`,
  `bench/net`, `bench/http`, rig-fast), main and the branch interleaved,
  4 rounds of 3 runs, fastest of 12, on P-core 1 and its sibling 2
  (`bench.sh`, `benches-pup.log`, `benchsum.py`): unchanged, every case
  within 1.2% except http's p50 latency, 6.4% lower (187 us against
  175) with its p99 0.4% higher and its requests 0.2% more, which is
  noise. No PROGRESS.md row is added.

The gate's tests failed first against a stand-in for main's behavior:
the parser's count, and no huge-page request for a block, a growth, or
a segment under a fragmented reading. The test reading replaces the
file only in Zig's own tests, since the free-block count is otherwise
the machine's.
