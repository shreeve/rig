# Task benchmark progress

Each row is one measurement of `bench/tasks/bench-tasks` (README.md):
time per operation, best of 5, on an Apple M5 with 10 cores. Read down
a column to see how a benchmark moves. The reference rows are Tokio's
and Go's at the baseline; the Rig rows below them are added as the
scheduler grows (`bench-tasks --record "#PR: what changed"`, which
appends to the end of the file, so a Mac row moves up into its table).
`hog` came with #355 and `memory` with #356: the rows before them have
none, and Tokio's and Go's are from then. Until #356 the scheduler was
the `rig-sched` variant, and `rig-fast` ran on Zig's `Threaded`
backend; from #356 on, `rig-fast` runs on the scheduler.

| Date | Change | Variant | spawn (per task) | chain (per task) | fanout (per run) | yield (per yield) | hog (per step) | memory (per task) |
|---|---|---|---|---|---|---|---|---|
| 2026-10-19 | reference | tokio | 171 ns | 167 ns | 69.0 ms | 40 ns | 2.9 ms | 270 B |
| 2026-10-19 | reference | go | 232 ns | 223 ns | 69.6 ms | 233 ns | 3.2 ms | 2.9 KiB |
| 2026-10-19 | #347: baseline, Zig's `Threaded` backend | rig-fast | 12.28 us | 10.29 us | 82.7 ms | 412 ns |
| 2026-10-19 | #348: fibers on one worker | rig-sched | 103 ns | 47 ns | 570.5 ms | 17 ns |
| 2026-10-19 | #349: a worker per core, with stealing | rig-sched | 206 ns | 61 ns | 75.8 ms | 13 ns |
| 2026-10-19 | #351: stacks, handoff, a faster spawn | rig-sched | 132 ns | 45 ns | 76.4 ms | 11 ns |
| 2026-10-19 | #352: waiting without spinning | rig-sched | 105 ns | 47 ns | 76.4 ms | 8 ns |
| 2026-10-19 | #355: yield checks | rig-sched | 113 ns | 45 ns | 78.2 ms | 10 ns | 84.11 us |
| 2026-10-19 | #356: the scheduler is the default | rig-fast | 94 ns | 49 ns | 78.0 ms | 8 ns | 84.63 us | 32.0 KiB |
| 2026-10-19 | #358: guards sized to the program | rig-fast | 106 ns | 44 ns | 77.8 ms | 10 ns | 101.25 us | 17.0 KiB |
| 2026-10-19 | #371: deterministic runs | rig-fast | 107 ns | 44 ns | 78.4 ms | 8 ns | 82.82 us | 17.0 KiB |
| 2026-10-19 | #372: task.isolate | rig-fast | 110 ns | 44 ns | 77.8 ms | 10 ns | 93.15 us | 17.0 KiB |
| 2026-10-20 | #383: actors | rig-fast | 109 ns | 45 ns | 80.0 ms | 10 ns | 102.17 us | 17.0 KiB |
| 2026-10-20 | #386: the idle path | rig-fast | 99 ns | 47 ns | 86.8 ms | 11 ns | 106.03 us | 17.0 KiB |
| 2026-10-20 | #389: deadlock detection | rig-fast | 104 ns | 47 ns | 86.6 ms | 11 ns | 91.37 us | 17.0 KiB |

## x86-64 (pup)

The same benchmarks on pup: Linux, x86-64, 22 cores. Tokio builds from
the crates.io release (pup has no `misc/tokio` clone).

| Date | Change | Variant | spawn (per task) | chain (per task) | fanout (per run) | yield (per yield) | hog (per step) | memory (per task) |
|---|---|---|---|---|---|---|---|---|
| 2026-10-19 | reference | tokio | 252 ns | 252 ns | 101.2 ms | 44 ns | 2.3 ms | 372 B |
| 2026-10-19 | reference | go | 272 ns | 265 ns | 84.9 ms | 474 ns | 1.9 ms | 2.9 KiB |
| 2026-10-19 | #352: Zig's `Threaded` backend | rig-fast | 20.37 us | 19.94 us | 109.3 ms | 98 ns |
| 2026-10-19 | #352: waiting without spinning | rig-sched | 274 ns | 82 ns | 108.0 ms | 7 ns |
| 2026-10-19 | #355: yield checks | rig-sched | 222 ns | 82 ns | 96.7 ms | 7 ns | 73.60 us |
| 2026-10-19 | #356: the scheduler is the default | rig-fast | 272 ns | 82 ns | 103.8 ms | 7 ns | 71.54 us | 9.0 KiB |
| 2026-10-19 | #358: guards sized to the program | rig-fast | 311 ns | 76 ns | 102.3 ms | 7 ns | 55.78 us | 5.2 KiB |
| 2026-10-19 | #371: deterministic runs | rig-fast | 272 ns | 82 ns | 99.6 ms | 9 ns | 46.50 us | 5.2 KiB |
| 2026-10-19 | #372: task.isolate | rig-fast | 313 ns | 78 ns | 101.4 ms | 9 ns | 82.35 us | 5.2 KiB |
| 2026-10-20 | #383: actors | rig-fast | 270 ns | 79 ns | 97.9 ms | 11 ns | 57.12 us | 5.2 KiB |
| 2026-10-20 | #386: the idle path | rig-fast | 246 ns | 83 ns | 98.1 ms | 8 ns | 79.89 us | 5.2 KiB |
| 2026-10-20 | #389: deadlock detection | rig-fast | 278 ns | 79 ns | 98.0 ms | 8 ns | 69.41 us | 5.2 KiB |
