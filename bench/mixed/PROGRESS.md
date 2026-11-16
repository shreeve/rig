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

pup, cores 0-11, 10,000 idle connections, medians of 5 rounds (best in
brackets), at cc3374990 (records/2026-11/concurrency-mixed/linux/).

| Date | Change | Variant | offered | req/s | p50 | p99 | p99.9 | max |
|---|---|---|---|---|---|---|---|---|
| 2026-11-16 | reference | tokio | 50000 | 49995 | 437 us (423) | 1279 us (1277) | 1375 us (1371) | 1912 us (1737) |
| 2026-11-16 | reference | go | 50000 | 49999 | 54 us (54) | 1220 us (1216) | 3144 us (2919) | 4561 us (4377) |
| 2026-11-16 | ea3704772 | rig-safe | 50000 | 49997 | 474 us (471) | 1252 us (1251) | 1326 us (1321) | 1630 us (1476) |
| 2026-11-16 | reference | tokio | 100000 | 99999 | 36 us (36) | 102 us (98) | 860 us (559) | 1624 us (1551) |
| 2026-11-16 | reference | go | 100000 | 99999 | 35 us (35) | 1111 us (841) | 3548 us (3491) | 7403 us (5600) |
| 2026-11-16 | ea3704772 | rig-safe | 100000 | 99999 | 40 us (40) | 97 us (95) | 520 us (246) | 1535 us (1410) |
| 2026-11-16 | reference | tokio | 150000 | 149998 | 29 us (29) | 608 us (314) | 3836 us (2611) | 6461 us (5800) |
| 2026-11-16 | reference | go | 150000 | 149998 | 42 us (36) | 3071 us (2427) | 5701 us (5271) | 8948 us (7622) |
| 2026-11-16 | ea3704772 | rig-safe | 150000 | 149998 | 35 us (34) | 267 us (137) | 1696 us (1271) | 5476 us (3268) |
| 2026-11-16 | reference | tokio | 200000 | 199991 | 44 us (42) | 2109 us (2031) | 3450 us (3120) | 6243 us (4890) |
| 2026-11-16 | reference | go | 200000 | 199997 | 65 us (54) | 4304 us (3494) | 6841 us (6700) | 11.2 ms (10.1) |
| 2026-11-16 | ea3704772 | rig-safe | 200000 | 199998 | 39 us (38) | 829 us (702) | 1560 us (1402) | 4563 us (3028) |
| 2026-11-16 | reference | tokio | 250000 | 249978 | 620 us (363) | 3885 us (3568) | 5455 us (5126) | 9540 us (8132) |
| 2026-11-16 | reference | go | 250000 | 249996 | 98 us (95) | 6539 us (6173) | 9462 us (8565) | 15.0 ms (13.5) |
| 2026-11-16 | ea3704772 | rig-safe | 250000 | 249987 | 171 us (59) | 2908 us (1117) | 5688 us (4504) | 7703 us (6644) |
| 2026-11-16 | reference | tokio | 300000 | 299936 | 1304 us (1158) | 7815 us (6201) | 10.6 ms (8550) | 14.5 ms (13.9) |
| 2026-11-16 | reference | go | 300000 | 299995 | 290 us (265) | 11.3 ms (10.6) | 16.2 ms (13.7) | 24.2 ms (19.3) |
| 2026-11-16 | ea3704772 | rig-safe | 300000 | 299975 | 322 us (164) | 4122 us (2638) | 7431 us (4020) | 10.5 ms (8531) |
| 2026-11-16 | reference | tokio | 350000 | 327936 | 123 ms (11.1) | 324 ms (35.2) | 343 ms (41.4) | 357 ms (48.4) |
| 2026-11-16 | reference | go | 350000 | 326040 | 146 ms (139) | 374 ms (355) | 399 ms (385) | 425 ms (414) |
| 2026-11-16 | ea3704772 | rig-safe | 350000 | 312226 | 257 ms (95.9) | 535 ms (173) | 553 ms (187) | 573 ms (197) |
