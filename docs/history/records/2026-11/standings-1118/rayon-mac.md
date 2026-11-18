# Rig against Rayon on the Mac: fork-join board, 2026-11-18

Rig main **a303f69fd** (origin/main after a fetch; includes #1145 ipnsort, #1146 fold, #1147 ring join, #1148).
Apple M5, 10 cores, Darwin 27.2. Rig `--release` (ReleaseSafe), Zig 0.17.0. Rayon 1.12.0, Rust 1.99.1,
`cargo build --release` (LTO, one codegen unit). Harness: docs/history/records/2026-11/concurrency-bench-remeasure/fork/
(fork.rig, rayon/), with a runner that extends run.py (board.py, in raw/rayon-mac/ and scripts/mac/). fork.rig has two rows, psum and qsort.

Arms, each round: `rig` (main), `aa` (a second build of main with a dead function added: Zig drops it,
so the code layout is the same and this arm measures run-to-run noise), `lay` (layout control: the same function kept,
called only if psum's result is 7, which it never is; it moves `___rig_main.qsort` from 60 to 44 mod 128 and `psum`
from 116 to 20), `rayon`. Workers set by `RIG_WORKERS=N` and `RAYON_NUM_THREADS=N`, N = 1 and 10.
Each round runs both worker counts (order alternating) and the four arms in rotating order. 20 rounds a board; three boards,
each its own `tools/mac-claim`. Every run's checks agree (psum 16760439056, qsort 4194304).

Ratios are paired per round: Rig/Rayon below 1 means Rig is faster. A/A is aa/rig and lay/rig.

## Pooled, 60 rounds (paired median [interquartile range])

| row | workers | Rig/Rayon | A/A rebuild | A/A layout | rounds Rig won | verdict |
|---|---:|---:|---:|---:|---:|---|
| psum | 1 | 1.250 [1.198-1.351] | 0.985 [0.912-1.055] | 0.997 [0.939-1.047] | 3 of 60 | Rig 25% slower |
| psum | 10 | 1.034 [0.974-1.137] | 0.998 [0.929-1.065] | 0.995 [0.915-1.064] | 21 of 60 | Rig 3% slower, inside the A/A spread |
| qsort | 1 | 1.107 [1.088-1.121] | 1.001 [0.975-1.034] | 1.003 [0.967-1.026] | 3 of 60 | Rig 11% slower |
| qsort | 10 | 0.998 [0.959-1.034] | 1.011 [0.974-1.073] | 1.018 [0.964-1.087] | 31 of 60 | level |

## Per board (median / fastest in ms; paired median [full range])

## board1.json checks {'psum': ['16760439056'], 'qsort': ['4194304']}
| row | workers | Rig median / fastest ms | Rayon median / fastest ms | Rig/Rayon paired median [range] | A/A rebuild [range] | A/A layout [range] | Rig wins |
|---|---:|---:|---:|---:|---:|---:|---:|
| psum | 1 | 7.85 / 5.41 | 5.92 / 3.84 | 1.271 [0.935-1.731] | 0.943 [0.640-1.182] | 0.987 [0.646-1.125] | 1 of 20 |
| psum | 10 | 2.56 / 2.39 | 2.58 / 2.37 | 1.013 [0.828-1.939] | 1.022 [0.552-1.342] | 1.026 [0.481-1.226] | 8 of 20 |
| qsort | 1 | 168.32 / 163.31 | 151.34 / 147.63 | 1.111 [1.087-1.269] | 0.990 [0.901-1.042] | 0.983 [0.876-1.035] | 0 of 20 |
| qsort | 10 | 56.20 / 51.22 | 56.64 / 54.37 | 0.989 [0.838-1.084] | 1.023 [0.883-1.918] | 1.011 [0.943-1.263] | 12 of 20 |
## board2.json checks {'psum': ['16760439056'], 'qsort': ['4194304']}
| row | workers | Rig median / fastest ms | Rayon median / fastest ms | Rig/Rayon paired median [range] | A/A rebuild [range] | A/A layout [range] | Rig wins |
|---|---:|---:|---:|---:|---:|---:|---:|
| psum | 1 | 8.22 / 7.25 | 6.76 / 5.18 | 1.231 [0.613-3.025] | 0.993 [0.569-8.947] | 0.988 [0.404-2.528] | 1 of 20 |
| psum | 10 | 2.90 / 2.58 | 2.81 / 2.44 | 1.082 [0.757-1.538] | 0.986 [0.686-1.792] | 0.971 [0.748-1.690] | 7 of 20 |
| qsort | 1 | 168.05 / 161.70 | 151.75 / 148.35 | 1.108 [0.885-1.511] | 0.996 [0.930-1.472] | 1.006 [0.809-1.301] | 3 of 20 |
| qsort | 10 | 59.31 / 49.87 | 56.73 / 54.10 | 1.023 [0.835-1.998] | 0.985 [0.635-2.317] | 0.967 [0.547-1.396] | 8 of 20 |
## board3.json checks {'psum': ['16760439056'], 'qsort': ['4194304']}
| row | workers | Rig median / fastest ms | Rayon median / fastest ms | Rig/Rayon paired median [range] | A/A rebuild [range] | A/A layout [range] | Rig wins |
|---|---:|---:|---:|---:|---:|---:|---:|
| psum | 1 | 6.18 / 5.11 | 4.68 / 3.76 | 1.267 [1.000-1.630] | 1.002 [0.872-1.613] | 1.032 [0.856-1.614] | 1 of 20 |
| psum | 10 | 2.60 / 2.32 | 2.47 / 2.17 | 1.030 [0.728-1.304] | 0.992 [0.830-1.100] | 0.988 [0.783-1.639] | 6 of 20 |
| qsort | 1 | 164.51 / 158.71 | 148.46 / 145.67 | 1.100 [1.057-1.310] | 1.015 [0.881-1.198] | 1.006 [0.802-1.360] | 0 of 20 |
| qsort | 10 | 55.41 / 47.62 | 55.55 / 53.31 | 0.990 [0.846-1.084] | 1.010 [0.951-1.103] | 1.026 [0.945-3.961] | 11 of 20 |

## Load at each claim's start

- Board 1 (claim queued at 15:12:19 behind the JSON session's `json-smoke` claim; ran 15:13:32 to 15:13:56): load 2.26 / 3.31 / 3.08.
  Busiest: WindowServer 43%, an `asuka` "Mac Test.app" GUI test 20%, Chrome helpers 4-9%.
- Board 2 (mac-claim waited 1 min for quiet: 102% of a core in use; busiest WindowServer 39%, `asuka` "OpenVista Chart.app" 17%,
  Chrome 9%; ran 15:15:22 to 15:15:48): load 1.88 / 2.88 / 2.94. Busiest at start: WindowServer 37%, Chrome 20%.
- Board 3 (queued behind another `json-smoke` claim; ran 15:20:42 to 15:21:06): load 2.94 / 2.89 / 2.92.
  Busiest: WindowServer 39%, Chrome 4-12%, Claude 5-8%.
- `~/Data/Code/mumps-compare/.mac-quiet` was absent throughout. No correctness job waited in tools/heavy.

## Notes

- psum is a 2-8 ms row read from memory (256 MB): its medians run 20-60% above its fastest and single rounds swing up to 9x
  (board 2's A/A range). The pooled interquartile ranges are the honest spread; only psum at one worker clears it clearly.
- Against #1147's boards (Rayon as a fraction of Rig then): psum 1 worker 0.705 -> 0.80 now; qsort 1 worker 0.762 -> 0.90
  (ipnsort); psum 10 workers 0.94 -> 0.97; qsort 10 workers 0.90 -> 1.00.
- The layout arm moved qsort's alignment yet stayed within noise on every row (0.995 to 1.018), so at this SHA neither placement
  shows the kind of layout effect #1147 found (its slow binary had qsort at 40 mod 128).
- Fastest-of-20 at 10 workers favours Rig on qsort in every board (47.6-51.2 against 53.3-54.4 ms) while the medians are level:
  Rig's 10-worker qsort has the wider spread.
