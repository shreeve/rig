# Task benchmark progress

Each row is one measurement of `bench/tasks/bench-tasks` (README.md):
time per operation, best of 5, on an Apple M5 with 10 cores. Read down
a column to see how a benchmark moves. The reference rows are Tokio's
and Go's at the baseline; the Rig rows below them are added as the
scheduler grows (`bench-tasks --record "#PR: what changed"`).

| Date | Change | Variant | spawn (per task) | chain (per task) | fanout (per run) | yield (per yield) |
|---|---|---|---|---|---|---|
| 2026-10-19 | reference | tokio | 171 ns | 167 ns | 69.0 ms | 40 ns |
| 2026-10-19 | reference | go | 232 ns | 223 ns | 69.6 ms | 233 ns |
| 2026-10-19 | #347: baseline, Zig's `Threaded` backend | rig-fast | 12.28 us | 10.29 us | 82.7 ms | 412 ns |
| 2026-10-19 | #348: fibers on one worker | rig-sched | 103 ns | 47 ns | 570.5 ms | 17 ns |
| 2026-10-19 | #349: a worker per core, with stealing | rig-sched | 206 ns | 61 ns | 75.8 ms | 13 ns |
| 2026-10-19 | #351: stacks, handoff, a faster spawn | rig-sched | 132 ns | 45 ns | 76.4 ms | 11 ns |
| 2026-10-19 | #352: waiting without spinning | rig-sched | 105 ns | 47 ns | 76.4 ms | 8 ns |
