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
| 2026-10-27 | main 54a7158b5 before #725, interleaved | rig-fast | 14.72 us | 5.96 us | 49.54 us |
| 2026-10-27 | #725: a freed large block serves any request it fits | rig-fast | 14.82 us | 5.92 us | 49.98 us |
| 2026-10-27 | main 967e1ac11 before #726, interleaved | rig-fast | 14.69 us | 5.96 us | 45.19 us |
| 2026-10-27 | #726: huge pages for new blocks of 16 MiB or more (Linux only) | rig-fast | 14.81 us | 5.92 us | 48.47 us |
| 2026-10-28 | main de6ef3e41 before #767, interleaved | rig-fast | 14.10 us | 5.90 us | 45.17 us |
| 2026-10-28 | #767: a frozen value's allocation has no weak count | rig-fast | 14.04 us | 5.87 us | 46.35 us |
| 2026-10-29 | main 277fba515 before #773, interleaved | rig-fast | 25.60 us | 6.17 us | 78.37 us |
| 2026-10-29 | #773: pointer-sized ^T? and ~T?, no dead drops, a cheaper last drop | rig-fast | 19.22 us | 6.12 us | 53.64 us |
| 2026-10-30 | main a8acfdc5c before #779, interleaved | rig-fast | 14.22 us | 5.82 us | 47.07 us |
| 2026-10-30 | #779: no read buffer held while waiting, untouched signal stacks and fresh stacks, TCP_NODELAY | rig-fast | 14.67 us | 5.82 us | 47.23 us |
| 2026-10-30 | main a8acfdc5c before #781 | rig-fast | 14.73 us | 5.88 us | 49.69 us |
| 2026-10-30 | main a8acfdc5c before #781 | rig-safe | 14.46 us | 5.91 us | 48.99 us |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-fast | 14.61 us | 5.95 us | 53.13 us |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-safe | 14.52 us | 5.93 us | 51.79 us |

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
| 2026-10-24 | main before #621, interleaved (pup cores 8,9) | rig-fast | 4.95 us | 3.62 us | 27.09 us |
| 2026-10-24 | #621: os.memory counts each allocation (pup cores 8,9) | rig-fast | 4.98 us | 3.60 us | 26.72 us |
| 2026-10-24 | main before #624, interleaved (pup cores 6,7) | rig-fast | 5.18 us | 4.05 us | 30.51 us |
| 2026-10-24 | #624: the blocking pool keeps a few threads busy (pup cores 6,7) | rig-fast | 5.22 us | 4.12 us | 30.43 us |
| 2026-10-25 | main before #677, interleaved (pup cores 6,7) | rig-fast | 5.59 us | 4.08 us | 30.41 us |
| 2026-10-25 | #677: fewer yield checks (pup cores 6,7) | rig-fast | 5.59 us | 4.03 us | 31.85 us |
| 2026-10-25 | main 99dcccf13 (before #677 and #683), interleaved (pup cores 6,7) | rig-fast | 5.16 us | 3.95 us | 29.93 us |
| 2026-10-25 | #683: the pool's spin lock waits by reading (pup cores 6,7) | rig-fast | 5.07 us | 3.94 us | 29.77 us |
| 2026-10-27 | main 54a7158b5 before #725, interleaved (pup cores 6,7) | rig-fast | 5.09 us | 3.79 us | 28.97 us |
| 2026-10-27 | #725: a freed large block serves any request it fits (pup cores 6,7) | rig-fast | 5.00 us | 3.84 us | 30.08 us |
| 2026-10-27 | main 967e1ac11 before #726, interleaved (pup cores 6,7) | rig-fast | 4.93 us | 3.59 us | 28.10 us |
| 2026-10-27 | #726: huge pages for new blocks of 16 MiB or more (pup cores 6,7) | rig-fast | 4.99 us | 3.62 us | 28.89 us |
| 2026-10-28 | main de6ef3e41 before #767, interleaved (pup core 6) | rig-fast | 4.73 us | 4.55 us | 28.88 us |
| 2026-10-28 | #767: a frozen value's allocation has no weak count (pup core 6) | rig-fast | 4.74 us | 4.56 us | 28.71 us |
| 2026-10-29 | main 277fba515 before #773, interleaved (pup core 6) | rig-fast | 5.08 us | 4.87 us | 30.04 us |
| 2026-10-29 | #773: pointer-sized ^T? and ~T?, no dead drops, a cheaper last drop (pup core 6) | rig-fast | 5.06 us | 4.86 us | 30.30 us |
| 2026-10-30 | main a8acfdc5c before #779, interleaved (pup core 8) | rig-fast | 4.78 us | 4.57 us | 28.97 us |
| 2026-10-30 | #779: no read buffer held while waiting, untouched signal stacks and fresh stacks, TCP_NODELAY (pup core 8) | rig-fast | 4.82 us | 4.57 us | 29.54 us |
| 2026-10-30 | main a8acfdc5c before #781 | rig-fast | 8.10 us | 980 ns | 42.56 us |
| 2026-10-30 | main a8acfdc5c before #781 | rig-safe | 9.71 us | 1.05 us | 33.54 us |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-fast | 8.94 us | 1.02 us | 30.18 us |
| 2026-10-30 | #781: a large optional result through the caller's place | rig-safe | 8.98 us | 1.00 us | 26.24 us |
