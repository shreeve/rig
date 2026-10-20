# Actor benchmark progress

Each row is one measurement of `bench/actors/bench-actors` (README.md):
time per call, best of 7, on an Apple M5 with 10 cores. Read down a
column to see how a benchmark moves. The reference rows are Tokio's and
Go's when the benchmark began; the Rig rows below them are added as
actors grow (`bench-actors --record "#PR: what changed"`, which appends
to the end of the file, so a Mac row moves up into its table).

| Date | Change | Variant | solo (per call) | contend (per call) | spread (per call) |
|---|---|---|---|---|---|
| 2026-10-20 | reference | tokio | 134 ns | 134 ns | 35 ns |
| 2026-10-20 | reference | go | 3.7 ns | 21 ns | 0.7 ns |
| 2026-10-20 | #383: actors, every call a message | rig-fast | 99 ns | 151 ns | 35 ns |
| 2026-10-20 | #386: the idle path | rig-fast | 4.9 ns | 6.9 ns | 1.6 ns |
| 2026-10-20 | #389: deadlock detection | rig-fast | 6.0 ns | 34 ns | 1.7 ns |
| 2026-10-20 | #391: actor failure | rig-fast | 5.9 ns | 42 ns | 1.3 ns |
| 2026-10-20 | #392: supervised actors | rig-fast | 5.0 ns | 33 ns | 1.0 ns |

## x86-64 (pup)

The same benchmarks on pup: Linux, x86-64, 22 cores. Tokio builds from
the crates.io release (pup has no `misc/tokio` clone).

| Date | Change | Variant | solo (per call) | contend (per call) | spread (per call) |
|---|---|---|---|---|---|
| 2026-10-20 | reference | tokio | 260 ns | 252 ns | 16 ns |
| 2026-10-20 | reference | go | 12 ns | 66 ns | 1.3 ns |
| 2026-10-20 | #386: the idle path | rig-fast | 13 ns | 33 ns | 2.2 ns |
| 2026-10-20 | #389: deadlock detection | rig-fast | 15 ns | 32 ns | 1.8 ns |
| 2026-10-20 | #391: actor failure | rig-fast | 12 ns | 31 ns | 1.8 ns |
| 2026-10-20 | #392: supervised actors | rig-fast | 14 ns | 34 ns | 2.3 ns |
