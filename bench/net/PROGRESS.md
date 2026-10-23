# Socket benchmark progress

Each row is one measurement of `bench/net/bench-net` (README.md): time
per round trip or connection, best of 3, on an Apple M5 with 10 cores.
The reference rows are Tokio's and Go's when the benchmark began; the
Rig rows below them are added as the runtime grows (`bench-net --record
"#PR: what changed"`, which appends to the end of the file, so a Mac row
moves up into its table).

| Date | Change | Variant | pingpong (per trip) | echo (per trip) | connect (per conn) |
|---|---|---|---|---|---|
| 2026-10-20 | reference | tokio | 14.10 us | 5.68 us | 57.43 us |
| 2026-10-20 | reference | go | 16.01 us | 5.68 us | 58.58 us |
| 2026-10-20 | #396: std.net | rig-fast | 14.79 us | 5.98 us | 57.29 us |
| 2026-10-20 | #405: free tasks run on any worker again | rig-fast | 14.55 us | 5.71 us | 52.38 us |
| 2026-10-22 | main before #541, interleaved | rig-fast | 19.71 us | 5.85 us | 51.37 us |
| 2026-10-22 | #541: a run-next fill wakes no worker | rig-fast | 16.17 us | 5.97 us | 56.74 us |
| 2026-10-22 | main before #552, interleaved | rig-fast | 14.98 us | 5.94 us | 49.81 us |
| 2026-10-22 | #552: each worker on cache lines of its own | rig-fast | 14.39 us | 5.96 us | 50.33 us |
| 2026-10-23 | main before #581, interleaved | rig-fast | 13.55 us | 5.89 us | 48.89 us |
| 2026-10-23 | #581: a sleeping worker leaves the run-next notice set | rig-fast | 13.55 us | 5.93 us | 49.56 us |

## x86-64 (pup)

The same benchmarks on pup: Linux, x86-64, 22 cores. Tokio builds from
the crates.io release (pup has no `misc/tokio` clone).

| Date | Change | Variant | pingpong (per trip) | echo (per trip) | connect (per conn) |
|---|---|---|---|---|---|
| 2026-10-20 | reference | tokio | 5.07 us | 1.60 us | 30.29 us |
| 2026-10-20 | reference | go | 5.90 us | 949 ns | 49.63 us |
| 2026-10-20 | #396: std.net | rig-fast | 4.81 us | 1.10 us | 25.86 us |
| 2026-10-20 | #405: free tasks run on any worker again | rig-fast | 4.82 us | 1.01 us | 25.51 us |
| 2026-10-22 | main before #541, interleaved (pup cores 8,9) | rig-fast | 6.98 us | 3.97 us | 31.04 us |
| 2026-10-22 | #541: a run-next fill wakes no worker (pup cores 8,9) | rig-fast | 4.92 us | 3.94 us | 29.60 us |
| 2026-10-22 | main before #552, interleaved (pup cores 8,9) | rig-fast | 4.90 us | 3.56 us | 27.10 us |
| 2026-10-22 | #552: each worker on cache lines of its own (pup cores 8,9) | rig-fast | 4.88 us | 3.55 us | 26.46 us |
| 2026-10-23 | main before #581, interleaved (pup cores 8,9) | rig-fast | 4.86 us | 3.81 us | 28.09 us |
| 2026-10-23 | #581: a sleeping worker leaves the run-next notice set (pup cores 8,9) | rig-fast | 4.93 us | 3.80 us | 28.06 us |
