# Standings and the no-regression check, 2026-11-18

Where Rig stood at the end of 2026-11-18, after the sort kernel (#1145),
integer folds by vectors (#1146), the ring join (#1147), the Mac
closed-loop rule (#1144), `--strip` (#1076) and `String` of text pieces
(#1077): first that none of them made anything slower, then fresh
standings against Rayon and the JSON parsers on pup and the Mac.

## Nothing got slower

Main 3bea1c455 (#1145-#1148) against the main before them, c014f5e3f,
each with an A/A arm.

- **pup, board AH** ([raw/board-AH-pup.txt](raw/board-AH-pup.txt), slots
  553 and 554): every row inside the A/A's spread. Cycles a request,
  trivial: 30,512 against 30,774 (hyper 33,418); mix: 66,984 against
  64,645, with the A/A, the same binary as main, at 67,022 (the row's
  usual 64.6k/67k draw; hyper 69,306). One core, 10,000 idle, p99 at 120k,
  80k and 40k: 63, 49, 54 µs in both (hyper 58, 50, 56). Ceiling at 160k:
  152.4k against 152.6k a second (hyper 150.3k). Closed loop on 0-11,
  median of 7: 736.6k against 737.1k (hyper 343.9k). bench/net and
  bench/tasks level.
- **The Mac** ([regression-mac.md](regression-mac.md)): every row inside the A/A's
  spread; the closed loop 159.1k against 159.1k (hyper 139.1k), bench/mixed
  p50 78 against 78 µs (hyper 86), mix cycles a request 1.001 of the old.
- **Trig** ([raw/trig-ab-seed1.txt](raw/trig-ab-seed1.txt),
  [raw/trig-ab-c4-seeds2-3.txt](raw/trig-ab-c4-seeds2-3.txt), slots 555
  and 556): Trig 726f9899 built with each Rig, Trig's `tools/bench/ab`
  with its A/A. One checker: all six projects level, instructions
  identical. Four checkers: seed 1 flagged four small projects slower on
  the fastest wall; seeds 2 and 3 (60 rounds) reversed three of them, and
  tiny-invariant's medians are level or faster (+1.4%, -0.7%, -0.4%) with
  0.05% more instructions, the ring join's one compare a join. Level. The
  emitted Zig of Trig's own code is identical between the two Rigs; only
  the runtime and scheduler differ.
- **#1077 on pup, board AI** ([raw/board-AI-pup.txt](raw/board-AI-pup.txt),
  slot 553): `http.text` builds every response through the changed
  `String`; trivial requests take 1.0% fewer instructions (34,060 against
  34,413), the mix, the tail and the closed loop level.

## Against Rayon, pup

[rayon-pup.md](rayon-pup.md): bench/fork, Rig a303f69fd, 20 rounds, medians.

| | Rig | Rayon | |
|---|---:|---:|---|
| qsort, 12 workers | 96.3 ms | 123.4 ms | Rig 22% faster |
| qsort, 1 worker | 255.8 ms | 266.9 ms | Rig 4% faster |
| psum, 12 workers | 6.05 ms | 4.66 ms | Rig 30% slower |
| psum, 1 worker | 14.36 ms | 11.89 ms | Rig 21% slower |

## Against Rayon, the Mac

[rayon-mac.md](rayon-mac.md): bench/fork, Rig a303f69fd against Rayon
1.12.0, three boards of 20 interleaved rounds, each its own
`tools/mac-claim`, pooled: Rig/Rayon as a paired median [interquartile
range], beside a rebuild and a layout control.

| | workers | Rig/Rayon | |
|---|---:|---:|---|
| qsort | 10 | 0.998 [0.959-1.034] | level |
| qsort | 1 | 1.107 [1.088-1.121] | Rig 11% slower |
| psum | 10 | 1.034 [0.974-1.137] | Rig 3% slower, inside the A/A spread |
| psum | 1 | 1.250 [1.198-1.351] | Rig 25% slower |

psum at one worker trails on both machines, so its gap is mostly the leaf
and the cost of each split, not stealing.

## Against the JSON parsers, pup

[json-pup.md](json-pup.md): one P-core, 20 rounds, medians. By geomean
over the six files std.json runs 3,524 MB/s: 18.6% faster than yyjson
(2,971) and 4.9% slower than simdjson's DOM (3,706); 1.21 times sonic-rs,
1.65 times simd-json, 7.1 times serde_json, 13.2 times Go's
`encoding/json/v2`. It leads gsoc-2018 (16.3% ahead of simdjson) and
twitterescaped (10.7% ahead of yyjson); simdjson leads twitter,
citm_catalog and github_events by 1.26-1.32 times. Against the x86 race of
2026-10-15, std.json is 29% faster by geomean.

## Against the JSON parsers, the Mac

[json-mac.md](json-mac.md): Apple M5, 50 interleaved rounds in two
claims, fastest of 50. By geomean std.json runs 4,642 MB/s: 7.6% faster
than yyjson (4,313), the fastest of the others, and 0.1% slower than the
best parser of each file; 1.28 times sonic-rs, 1.32 times simdjson's DOM,
1.60 times simd-json, 5.4 times serde_json, 9.8 times Go's
`encoding/json/v2`. It leads gsoc-2018 (9% ahead of sonic-rs, 71% ahead of
yyjson), citm_catalog (6%) and canada (5%); yyjson leads twitter by 11%,
twitterescaped by 7% and github_events by 1.5%. Against 2026-11-07,
std.json is 1.4% faster by geomean, with yyjson's numbers within 0.4%.

The scripts are in [scripts/](scripts/), every sample in [raw/](raw/). The Mac's scripts are in [scripts/mac/](scripts/mac/).
