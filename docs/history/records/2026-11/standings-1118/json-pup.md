# std.json against the fastest parsers, pup, Rig a303f69fd (2026-11-18)

- **Machine:** pup (Intel Core Ultra 9 185H, AVX2, x86-64 Linux), ab slot 558 (25 min, opened about
  15:43:50, closed 15:48:59 by the script's trap), 2,197 free 2 MiB blocks, load under 1, no other
  holder. `quiet-check.sh 558`: honoured.
- **Harness:** bench/json/timers/time.py's method with every sample kept (`s1118-json-board.py`,
  scripts/): each program calibrated to about 400 ms of parsing after a warm run, 20 interleaved
  rounds, the variant order rotating each round, every run pinned to P-core 6 (`taskset -c 6`, sibling 7
  idle; the driver on P-core 8). MB/s = 10^6 bytes; the honest harness (`parse` out of line).
- **Builds** (all on E-cores 12-19 with no slot open, /zfs/trig-pup/standings-1118): std.json `rig-safe`
  (`bench-json --build-only`, `rig build --release`, Zig's safe mode, every check kept), and an A/A arm,
  a byte copy of each file's program. yyjson 0.10.0 and simdjson 3.10.1 DOM (`cbench/build.sh`, GCC 15.2,
  `-O3 -march=native`), sonic-rs, simd-json (tape) and serde_json (`rust-bench/build.sh native`,
  rustc 1.98.0), Go 1.27.2's `encoding/json/v2` into an `any` (`gobench/build.sh`). Data: the six
  files, sha256 as tools/fetch-json-data.sh pins them.
- Raw samples: raw/json-samples.txt; the board's output (fastest, median, ranges):
  raw/json-board.txt.

## Medians, MB/s

| file | std.json | A/A | yyjson | simdjson DOM | sonic-rs | simd-json tape | serde_json | Go v2 |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| twitter | 3678 | 3672 | 3767 | **4857** | 2779 | 2450 | 376 | 238 |
| twitterescaped | **2918** | 2922 | 2637 | 2047 | 2204 | 1421 | 328 | 185 |
| canada | 1441 | 1443 | 1436 | **1489** | 1434 | 1121 | 349 | 135 |
| citm_catalog | 4080 | 4084 | 3694 | **5341** | 3588 | 2565 | 692 | 319 |
| gsoc-2018 | **6813** | 6781 | 3297 | 5858 | 5161 | 3473 | 1173 | 543 |
| github_events | 4456 | 4451 | 3958 | **5593** | 3780 | 2721 | 416 | 343 |
| geomean | 3524 | 3522 | 2971 | **3706** | 2916 | 2135 | 494 | 266 |

## Per file: std.json's time, the best competitor, std.json against yyjson and against the best

| file | std.json, µs a parse (MB/s, range) | best competitor | against yyjson | against the best |
|---|---|---|---|---|
| twitter | 171.7 (3678, 3542-3705) | simdjson DOM 4857 | 2.4% slower | simdjson 1.32x faster |
| twitterescaped | 192.7 (2918, 2854-2964) | yyjson 2637 | 10.7% faster | std.json leads, 10.7% |
| canada | 1562 (1441, 1420-1467) | simdjson DOM 1489 | 0.3% faster (a tie) | 3.2% slower |
| citm_catalog | 423.3 (4080, 3993-4112) | simdjson DOM 5341 | 10.4% faster | simdjson 1.31x faster |
| gsoc-2018 | 488.5 (6813, 6507-6861) | simdjson DOM 5858 | 2.07x faster | std.json leads, 16.3% |
| github_events | 14.6 (4456, 4401-4497) | simdjson DOM 5593 | 12.6% faster | simdjson 1.26x faster |
| geomean | (3524) | simdjson DOM 3706 | 18.6% faster | 4.9% slower |

The A/A arm is within 0.5% of std.json on every file and 0.1% by geomean. Fastest-of-20 (time.py's own
figure) tells the same story: std.json 3563 by geomean, yyjson 3021, simdjson 3753.

## Against the last x86 race (2026-10-15, Rig f95ea861d, pup, CPU 2, fastest of 15)

Fastest against fastest, MB/s:

| file | std.json then | std.json now | yyjson then / now | simdjson then / now | sonic-rs then / now |
|---|---:|---:|---|---|---|
| twitter | 2770 | 3705 | 3771 / 3865 | 4751 / 4887 | 2661 / 2800 |
| twitterescaped | 2232 | 2964 | 2624 / 2673 | 2098 / 2074 | 2129 / 2229 |
| canada | 1289 | 1467 | 1392 / 1448 | 1442 / 1497 | 1365 / 1441 |
| citm_catalog | 2922 | 4112 | 3607 / 3799 | 5192 / 5426 | 3401 / 3622 |
| gsoc-2018 | 5781 | 6861 | 3198 / 3330 | 5718 / 5919 | 5005 / 5258 |
| github_events | 3238 | 4497 | 3941 / 4020 | 5533 / 5730 | 3766 / 3876 |
| geomean | 2754 | 3563 | 2925 / 3021 | 3649 / 3753 | 2813 / 2954 |

- std.json is 29% faster by geomean than on 15 Oct; the competitors are 3-5% faster on the same
  binaries' versions (core 6 against core 2, and the machine's state), so about 24 points of it are
  std.json's own.
- Against yyjson: 6% behind then, 18% ahead now (fastest), leading five files of six; yyjson keeps
  twitter by 2.4%.
- Against simdjson DOM, the x86 bar: simdjson was 1.32x std.json by geomean then (std.json
  25% slower), and is 1.05x now (std.json 5% slower). simdjson still leads twitter (1.32x), citm_catalog (1.31x) and
  github_events (1.26x), and edges canada (3%); std.json leads gsoc-2018 and twitterescaped.
- sonic-rs, simd-json, serde_json and Go: std.json is 1.21x sonic-rs, 1.65x simd-json, 7.1x serde_json
  and 13.2x Go's json/v2 by geomean (medians). The 15 Oct race had no serde_json or Go row on pup; the
  Mac's 2026-11-05 standing had Go v2 8.2x behind std.json, on x86 it is 13.2x.

## Odd

- yyjson's citm_catalog spread is wide (3473-3799, 9%); every other cell is within about 5%.
- Go was 1.27.2 here (pup's mise), 1.27.3 on the Mac's 2026-11-05 standing.
