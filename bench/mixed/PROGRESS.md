# Mixed-workload benchmark progress

Each row is one rate of `bench/mixed/bench-mixed` (README.md): one
request in four computes, 5,000 idle connections held throughout, 128
connections carrying the open-loop load. Each cell is the median over
the rounds, with the best in brackets; latencies count from each
request's intended start. The reference rows are hyper's and Go's when
the benchmark began; Rig's are added as the runtime grows.

## arm64 (Mac, Apple M5, 10 cores, 5,000 idle connections)

2026-11-16, main ea3704772 (the benchmark's commit 3b0b8b797), 5
rounds, the servers' order rotated each round. At 140,000 a second
every server is past saturation (the machine's, generator included),
and its latencies are lower bounds. The rows at 40,000 and 80,000, the
per-route p99s and the cores used are in
docs/history/records/2026-11/concurrency-mixed/README.md.

| Date | Change | Variant | offered | req/s | p50 | p99 | p99.9 | max |
|---|---|---|---|---|---|---|---|---|
| 2026-11-16 | reference | tokio | 20000 | 19999 | 32 us (32) | 314 us (163) | 950 us (906) | 1516 us (1129) |
| 2026-11-16 | reference | go | 20000 | 19999 | 40 us (39) | 402 us (321) | 1030 us (998) | 1269 us (1216) |
| 2026-11-16 | ea3704772 | rig-safe | 20000 | 19999 | 32 us (32) | 198 us (104) | 923 us (882) | 1146 us (1105) |
| 2026-11-16 | reference | tokio | 60000 | 59999 | 54 us (53) | 502 us (459) | 1113 us (1099) | 1449 us (1355) |
| 2026-11-16 | reference | go | 60000 | 59999 | 63 us (62) | 602 us (580) | 1252 us (1196) | 1855 us (1611) |
| 2026-11-16 | ea3704772 | rig-safe | 60000 | 59999 | 54 us (53) | 500 us (389) | 1118 us (1032) | 1430 us (1420) |
| 2026-11-16 | reference | tokio | 100000 | 99998 | 92 us (86) | 1186 us (996) | 1747 us (1523) | 2848 us (1926) |
| 2026-11-16 | reference | go | 100000 | 99998 | 120 us (119) | 12.7 ms (5.4) | 16.1 ms (8.3) | 20.2 ms (11.7) |
| 2026-11-16 | ea3704772 | rig-safe | 100000 | 99998 | 90 us (88) | 1094 us (1023) | 1669 us (1490) | 2599 us (2166) |
| 2026-11-16 | reference | tokio | 120000 | 119977 | 230 us (194) | 1981 us (1674) | 4410 us (2073) | 6291 us (2785) |
| 2026-11-16 | reference | go | 120000 | 119950 | 1151 us (365) | 19.5 ms (3.5) | 25.4 ms (5.6) | 30.4 ms (9.8) |
| 2026-11-16 | ea3704772 | rig-safe | 120000 | 119995 | 216 us (195) | 2538 us (1668) | 4322 us (2347) | 5465 us (3204) |
| 2026-11-16 | reference | tokio | 140000 | 125121 | 305 ms | 529 ms | 538 ms | 571 ms |
| 2026-11-16 | reference | go | 140000 | 115891 | 475 ms | 857 ms | 873 ms | 886 ms |
| 2026-11-16 | ea3704772 | rig-safe | 140000 | 124084 | 305 ms | 566 ms | 576 ms | 583 ms |

## x86-64 (Linux, 22 cores)

Not yet measured; the commands are in README.md, "On Linux".
