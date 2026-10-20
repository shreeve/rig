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

## x86-64 (pup, 22 cores, 10,000 idle connections)

| Date | Change | Variant | req/s | p50 | p99 | per idle conn |
|---|---|---|---|---|---|---|
| 2026-10-20 | reference | tokio | 294609 | 162 us | 808 us | 10.8 KiB |
| 2026-10-20 | reference | go | 237436 | 153 us | 1439 us | 19.3 KiB |
| 2026-10-20 | #397: http.serve | rig-fast | 845844 | 51 us | 427 us | 16.6 KiB |
