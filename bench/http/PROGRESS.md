# HTTP benchmark progress

Each row is one measurement of `bench/http/bench-http` (README.md):
requests per second and latency, best of 3, and memory per idle
connection. The reference rows are hyper's and Go's when the benchmark
began; Rig's are added as the runtime grows.

## arm64 (Mac, 10 cores, 5,000 idle connections)

| Date | Change | Variant | req/s | p50 | p99 | per idle conn |
|---|---|---|---|---|---|---|
| 2026-10-20 | reference | tokio | 180339 | 346 us | 614 us | 18.6 KiB |
| 2026-10-20 | reference | go | 163675 | 366 us | 1071 us | 18.5 KiB |
| 2026-10-20 | #397: http.serve | rig-fast | 171062 | 365 us | 641 us | 32.6 KiB |
| 2026-10-20 | buffers held only per request | rig-fast | 191526 | 326 us | 597 us | 16.6 KiB |
| 2026-10-20 | #405: free tasks run on any worker again | rig-fast | 170966 | 366 us | 643 us | 16.6 KiB |
| 2026-10-21 | #535: interrupts cancel main | rig-fast | 168209 | 371 us | 649 us | 16.6 KiB |
| 2026-10-22 | main before #541, interleaved | rig-fast | 170635 | 362 us | 721 us | 16.6 KiB |
| 2026-10-22 | #541: a run-next fill wakes no worker | rig-fast | 168668 | 357 us | 930 us | 16.6 KiB |

## x86-64 (pup, 22 cores, 10,000 idle connections)

| Date | Change | Variant | req/s | p50 | p99 | per idle conn |
|---|---|---|---|---|---|---|
| 2026-10-20 | reference | tokio | 294609 | 162 us | 808 us | 10.8 KiB |
| 2026-10-20 | reference | go | 237436 | 153 us | 1439 us | 19.3 KiB |
| 2026-10-20 | #397: http.serve | rig-fast | 845844 | 51 us | 427 us | 16.6 KiB |
| 2026-10-20 | buffers held only per request | rig-fast | 205059 | 293 us | 471 us | 8.6 KiB |
| 2026-10-20 | #405: free tasks run on any worker again | rig-fast | 1124804 | 37 us | 402 us | 8.6 KiB |
| 2026-10-21 | #535: interrupts cancel main | rig-fast | 1010096 | 42 us | 286 us | 8.6 KiB |
| 2026-10-22 | main before #541, interleaved (pup cores 8,9) | rig-fast | 166171 | 237 us | 3542 us | 8.6 KiB |
| 2026-10-22 | #541: a run-next fill wakes no worker (pup cores 8,9) | rig-fast | 194189 | 198 us | 3512 us | 8.6 KiB |

The "buffers held only per request" rows (#402) ran on a build that
pinned every task to the worker that made it, a slip of #401 that #405
fixed: one core served every connection. Their memory stands; their
speed does not, and #405's rows are the measure. On the Mac one core
leaves the load generator, on the same machine, more of the others,
which is why that row reads faster.
