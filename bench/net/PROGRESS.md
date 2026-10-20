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

## x86-64 (pup)

The same benchmarks on pup: Linux, x86-64, 22 cores. Tokio builds from
the crates.io release (pup has no `misc/tokio` clone).

| Date | Change | Variant | pingpong (per trip) | echo (per trip) | connect (per conn) |
|---|---|---|---|---|---|
| 2026-10-20 | reference | tokio | 5.07 us | 1.60 us | 30.29 us |
| 2026-10-20 | reference | go | 5.90 us | 949 ns | 49.63 us |
| 2026-10-20 | #396: std.net | rig-fast | 4.81 us | 1.10 us | 25.86 us |
