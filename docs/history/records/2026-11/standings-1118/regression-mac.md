# mac-final-board: main 3bea1c455 against old main c014f5e3f on the Mac

Apple M5 (4 P + 6 E), 2026-11-18 13:10-13:32. Question: did main 3bea1c455 (#1145 std.sort, #1146 vector folds
plus src/runtime.zig, #1147 the scheduler's `>t` handoff) make anything slower than c014f5e3f on the Mac? (Board
AH on pup found Linux level everywhere.) Nothing edited in ~/Data/Code/rig; no pup, no burst.

## Verdict: Mac, no regression

Every row's m11/m10 paired median lies inside aa11/m11's A/A range, or (closed loop) on the fast side of it. Two
first reads crossed or touched the line and were rerun in their own claims; both came back level:
- bench/tasks yield, 10 rounds: m11/m10 1.065 [1.002-1.756], inside A/A [0.600-1.115] but slower in 10 of 10
  rounds. 30 rounds: 1.008 [0.834-1.577], A/A 1.019 [0.643-1.209]; best runs 6.17 ms (m11) against 6.16 (m10).
- bench/mixed p50, 10 rounds: m11/m10 1.019 [0.775-1.169], just over A/A's top (0.988 [0.800-1.013]); 80 µs
  against 78, while aa11 (m11's code plus a dead function) read 78. Ten more rounds: 1.006 [0.961-1.025] against A/A
  [0.916-1.101]; all 20 together 1.006, A/A [0.800-1.101]: level. Cycles a request 1.001, instructions 1.000.

## Arms

| arm | what |
|---|---|
| m10 | c014f5e3f (old main), detached worktree, `tools/heavy zig build`, `rig build --release` |
| m11 | 3bea1c455 (main), the same |
| aa11 | 3bea1c455 + `layoutDead` called from `workerMain` under a volatile false flag (wws/lay.patch's pattern): __text +60 bytes in every program (m10 to m11: +720 to +756) |
| tokio | bench/net/tokio (wws build, 11-17; source unchanged since 10-20) and bench/tasks/tokio (built now, cargo --release) |
| hyper | hyper-mac/comp/http/tokio (closed loop) and comp/mixed/tokio (mix), built 11-16; bench/ is identical in both commits |
| loads | bench/mixed/load and bench/http/load from m11, go build |

Harnesses reused: f2/netboard.py (net, tasks), f2/closed.py (closed loop), tail/run2.py with `PACES=sleep MIX=4
IDLE=5000 RIG_WORKERS=TOKIO_WORKER_THREADS=HYPER_WORKERS=8` and tail/pru (mix, with cycles a request over the
generator's counted window), f2/state.sh. New: fb/sum.py (tables), job.sh, all.sh. Scratch, with raw/*.jsonl and
c-*.log claim logs: raw/regression-mac/ (the scripts in scripts/mac/)

Ratios are paired by round: median [min-max]. Verdict per row: SLOWER only when m11/m10's median lies outside
aa11/m11's range on the slow side; faster when outside on the fast side; else level.

## The Mac's state per claim (state.sh at the command's start and end; .mac-quiet absent throughout)

| claim | requested -> ran | quiet wait | start: load 1/5/15, busiest others | end |
|---|---|---|---|---|
| fb-net (15 rounds) | 13:10:40 -> 13:12:00-13:13:22 | 1 min (119% in use: WindowServer 36%, PeerPaymentMessagesExtension 23%) | 3.03/3.32/4.77; WindowServer 35% | 2.99 |
| fb-tasks (10) | 13:13:22 -> 13:14:23-13:14:39 | under 1 min | 3.03/3.28/4.54; WindowServer 38%, PeerPaymentMessagesExtension 24% | 6.79 (the benchmark) |
| fb-closed (7) | 13:14:39 -> 13:15:24-13:17:14 | under 1 min | 4.98/4.00/4.73; WindowServer 34% | 9.15 (the benchmark) |
| fb-mix (10) | 13:17:14 -> 13:18:21-13:23:55 | 1 min (125%: WindowServer 32%, PeerPayment 19%) | 4.53/5.11/5.12; WindowServer 39% | 6.77; Google (Chrome) 59%, started during |
| fb-tasks2 (30) | 13:24:01 -> 13:24:32-13:25:15 | under 1 min | 4.44/5.61/5.44; nothing over 20% | 9.31 (the benchmark) |
| fb-mix2 (10) | 13:25:32 -> 13:26:03-13:31:36 | under 1 min | 5.51/6.05/5.65; nothing over 20% | 6.86; WindowServer 22% |

Every claim rc=0; none gave up or hit its limit. The load averages during the closed loop and the mix include the
benchmark itself (server plus generator, 4-6 cores busy). The mix's p99 floor here (~1.2 ms) is higher than the
quiet boards' (~0.6 ms, mac-final2) and every arm, hyper included, had 3-6 of 20 rounds with p99 over 5 ms: the
machine, not an arm.

## Headline (m11 against m10 against the competitor; medians)

| row | m10 | m11 | competitor | m11/m10 | aa11/m11 (A/A) | verdict |
|---|---:|---:|---:|---|---|---|
| net pingpong µs | 16.96 | 16.86 | tokio 16.44 | 0.998 | [0.927-1.099] | level |
| net echo µs | 5.98 | 5.99 | tokio 6.26 | 0.996 | [0.874-1.084] | level |
| net connect µs | 53.01 | 53.11 | tokio 65.37 | 1.016 | [0.590-1.047] | level |
| closed loop req/s | 159,051 | 159,072 | hyper 139,132 | 1.000 | [0.896-1.005] | level |
| closed loop server CPU µs/req | 8.98 | 9.15 | hyper 15.95 | 0.994 | [0.971-1.205] | level |
| mix 100k p50 µs (20 rounds) | 78 | 78 | hyper 86 | 1.006 | [0.800-1.101] | level |
| mix 100k p99 µs (20) | 1211 | 1236 | hyper 1232 | 1.054 | [0.008-58.3] | level |
| mix 100k p99.9 µs (20) | 1844 | 1850 | hyper 1870 | 1.044 | [0.013-42.9] | level |
| mix rounds p99 > 5 ms (of 20) | 4 | 6 | hyper 3 | | aa11 5 | level |
| mix cycles/req (20) | 78,998 | 79,292 | hyper 89,762 | 1.001 | [0.954-1.026] | level |
| tasks spawn ms (30) | 15.16 | 15.59 | tokio 17.57 | 0.994 | [0.809-1.164] | level |
| tasks chain ms (30) | 0.558 | 0.553 | tokio 1.777 | 0.996 | [0.953-1.071] | level |
| tasks fanout ms (30) | 70.89 | 72.08 | tokio 70.75 | 1.016 | [0.710-1.114] | level |
| tasks yield ms (30) | 6.457 | 6.493 | tokio 43.43 | 1.008 | [0.643-1.209] | level |
| tasks hog ms (30) | 0.011 | 0.010 | tokio 212.9 | 1.012 | [0.621-1.359] | level |
| tasks produce ms (30) | 5.326 | 5.341 | tokio 6.024 | 1.005 | [0.411-1.034] | level |

## Every table: the board as asked (net 15, tasks 10, closed 7, mix 10 rounds)


### bench/net, 15 rounds (µs a trip; lower is better)

| row | m10 | m11 | aa11 | tokio | m11/m10 | aa11/m11 (A/A) | tokio/m11 | verdict |
|---|---:|---:|---:|---:|---|---|---|---|
| pingpong | 16.96 [15.61-20.39] | 16.86 [16.58-18.08] | 16.99 [16.63-18.36] | 16.44 [15.88-21.91] | 0.998 [0.844-1.075] | 1.015 [0.927-1.099] | 0.972 [0.887-1.229] | level |
| echo | 5.98 [5.90-6.59] | 5.99 [5.88-6.65] | 6.03 [5.81-6.39] | 6.26 [6.12-6.97] | 0.996 [0.917-1.092] | 0.998 [0.874-1.084] | 1.046 [0.924-1.183] | level |
| connect | 53.01 [50.45-53.67] | 53.11 [50.82-87.80] | 52.71 [49.53-55.08] | 65.37 [45.38-145.83] | 1.016 [0.967-1.701] | 0.993 [0.590-1.047] | 1.234 [0.738-2.774] | level |

### bench/tasks, 10 rounds (ms a run; lower is better)

| row | m10 | m11 | aa11 | tokio | m11/m10 | aa11/m11 (A/A) | tokio/m11 | verdict |
|---|---:|---:|---:|---:|---|---|---|---|
| spawn | 14.585 [10.500-15.662] | 14.407 [13.127-16.582] | 15.043 [10.729-16.138] | 17.760 [17.110-23.079] | 1.005 [0.902-1.362] | 1.006 [0.699-1.199] | 1.245 [1.033-1.758] | level |
| chain | 0.550 [0.529-1.226] | 0.545 [0.513-0.800] | 0.542 [0.515-0.720] | 1.783 [1.193-2.099] | 0.963 [0.437-1.511] | 0.995 [0.656-1.080] | 3.070 [2.219-3.432] | level |
| fanout | 72.415 [69.651-81.618] | 72.863 [70.036-102.481] | 73.913 [70.765-78.417] | 75.448 [71.764-79.277] | 1.000 [0.901-1.446] | 1.022 [0.700-1.108] | 1.040 [0.710-1.105] | level |
| yield | 6.516 [6.239-7.021] | 7.110 [6.451-11.373] | 6.637 [6.379-7.533] | 43.235 [41.390-44.591] | 1.065 [1.002-1.756] | 0.947 [0.600-1.115] | 6.156 [3.751-6.792] | level |
| hog | 0.012 [0.010-0.016] | 0.010 [0.008-0.013] | 0.012 [0.008-0.015] | 218.305 [207.261-231.121] | 0.821 [0.631-1.195] | 1.060 [0.760-1.615] | 21131.719 [18489.700-25443.515] | level |
| produce | 5.257 [5.204-5.397] | 5.267 [5.212-5.422] | 5.250 [5.194-5.316] | 6.244 [5.587-6.314] | 1.005 [0.966-1.017] | 0.995 [0.963-1.016] | 1.187 [1.056-1.206] | level |

### bench/http closed loop, 64 connections, 7 rounds (requests a second; higher is better)

| row | m10 | m11 | aa11 | hyper | m11/m10 | aa11/m11 (A/A) | hyper/m11 | verdict |
|---|---:|---:|---:|---:|---|---|---|---|
| req/s | 159051 [150963-160561] | 159072 [152401-161466] | 157972 [143363-160284] | 139132 [132155-139910] | 1.000 [0.991-1.015] | 0.991 [0.896-1.005] | 0.867 [0.850-0.879] | level |

### bench/http closed loop, latency (µs; lower is better)

| row | m10 | m11 | aa11 | hyper | m11/m10 | aa11/m11 (A/A) | hyper/m11 | verdict |
|---|---:|---:|---:|---:|---|---|---|---|
| p50 µs | 388 [387-402] | 389 [385-398] | 391 [387-411] | 454 [450-459] | 1.000 [0.990-1.005] | 1.008 [0.997-1.049] | 1.169 [1.153-1.178] | level |
| p99 µs | 644 [590-714] | 632 [568-735] | 644 [604-1079] | 686 [651-1162] | 1.029 [0.846-1.064] | 1.017 [0.973-1.705] | 1.139 [1.052-1.581] | level |

### bench/http closed loop, server CPU (µs a request; lower is better)

| row | m10 | m11 | aa11 | hyper | m11/m10 | aa11/m11 (A/A) | hyper/m11 | verdict |
|---|---:|---:|---:|---:|---|---|---|---|
| server CPU µs a request | 8.98 [8.78-10.38] | 9.15 [8.73-10.24] | 9.35 [8.89-10.94] | 15.95 [15.82-16.19] | 0.994 [0.977-1.042] | 1.034 [0.971-1.205] | 1.740 [1.548-1.824] | level |

load at each round's first run: 0 { 4.98 4.00 4.73 }; 1 { 7.23 4.57 4.92 }; 2 { 7.00 4.64 4.94 }; 3 { 7.03 4.76 4.97 }; 4 { 7.48 4.96 5.04 }; 5 { 8.71 5.34 5.18 }; 6 { 8.80 5.52 5.24 }

### bench/mixed 100k/s, 8 workers, -pace sleep, 10 rounds (µs; lower is better)

| row | m10 | m11 | aa11 | hyper | m11/m10 | aa11/m11 (A/A) | hyper/m11 | verdict |
|---|---:|---:|---:|---:|---|---|---|---|
| p50 | 78 [75-102] | 80 [75-90] | 78 [72-80] | 86 [81-102] | 1.019 [0.775-1.169] | 0.988 [0.800-1.013] | 1.064 [0.900-1.291] | SLOWER on this read; level on the rerun and over 20 rounds (below) |
| p99 | 3688 [1091-156829] | 1456 [1132-110424] | 1168 [868-7634] | 1196 [1033-81507] | 0.664 [0.008-27.306] | 0.776 [0.008-6.708] | 0.787 [0.009-68.436] | level |
| p999 | 9227 [1660-166096] | 5017 [1725-118537] | 1732 [1495-14926] | 1872 [1613-93493] | 0.729 [0.011-9.869] | 0.597 [0.013-8.452] | 0.729 [0.014-53.793] | level |
| timer_p99 | 255 [192-504] | 280 [156-359] | 258 [88-304] | 211 [136-411] | 1.009 [0.598-1.725] | 0.949 [0.264-1.679] | 0.792 [0.408-2.635] | level |

### bench/mixed 100k/s, server cost (pru, counted window) (per request; lower is better)

| row | m10 | m11 | aa11 | hyper | m11/m10 | aa11/m11 (A/A) | hyper/m11 | verdict |
|---|---:|---:|---:|---:|---|---|---|---|
| cycles a request | 78995 [77872-83020] | 79597 [78503-81173] | 78852 [77422-79887] | 89172 [88710-90872] | 1.005 [0.955-1.031] | 0.998 [0.954-1.006] | 1.127 [1.096-1.147] | level |
| instructions a request | 94930 [93337-95202] | 95033 [94143-95240] | 95141 [94828-95258] | 101871 [100488-102143] | 1.002 [0.991-1.017] | 1.000 [0.999-1.012] | 1.071 [1.055-1.085] | level |

### bench/mixed 100k/s, server context switches (per request; lower is better)

| row | m10 | m11 | aa11 | hyper | m11/m10 | aa11/m11 (A/A) | hyper/m11 | verdict |
|---|---:|---:|---:|---:|---|---|---|---|
| context switches a request | 0.665 [0.645-0.681] | 0.673 [0.625-0.686] | 0.675 [0.657-0.686] | 0.852 [0.776-0.870] | 1.007 [0.941-1.064] | 1.000 [0.991-1.081] | 1.265 [1.130-1.388] | level |

| arm | rounds p99 > 5 ms | which | rounds max > 5 ms | achieved min | csw a request median |
|---|---:|---|---:|---:|---:|
| m10 | 4 | 0,1,5,8 | 6 | 96747 | 0.665 |
| m11 | 4 | 2,4,6,7 | 6 | 99928 | 0.673 |
| aa11 | 2 | 5,8 | 3 | 99996 | 0.675 |
| hyper | 2 | 1,3 | 4 | 99984 | 0.852 |

p50 per round (µs): m10 79 89 78 102 78 85 77 76 85 75; m11 82 78 82 79 82 78 90 80 78 75; aa11 74 79 80 79 77 78 72 80 76 76; hyper 81 90 86 102 86 94 81 87 81 81

p99 per round (µs): m10 10036 156829 1203 3332 1091 20354 4044 1111 67954 1166; m11 1713 1194 8667 1191 9378 1138 110424 9251 1198 1132; aa11 1001 1172 1185 1152 1102 7634 868 1360 7353 1165; hyper 1046 67275 1182 81507 3485 3052 1033 1207 1155 1186

p999 per round (µs): m10 16671 166096 1903 6443 1660 29135 12011 1692 78623 1787; m11 8209 1752 16274 1738 16319 1766 118537 16236 1825 1725; aa11 1595 1740 1746 1711 1724 14926 1495 3412 13977 1721; hyper 1613 75744 1821 93493 7757 8719 1659 1802 1794 1924

round start times: 13:18:28 13:19:10 13:19:52 13:20:34 13:20:42 13:21:24 13:22:05 13:22:47 13:22:55 13:23:37

## Rerun: bench/tasks, 30 rounds (claim fb-tasks2)

### bench/tasks, 30 rounds (ms a run; lower is better)

| row | m10 | m11 | aa11 | tokio | m11/m10 | aa11/m11 (A/A) | tokio/m11 | verdict |
|---|---:|---:|---:|---:|---|---|---|---|
| spawn | 15.159 [11.405-17.842] | 15.586 [11.026-21.143] | 15.589 [11.669-17.116] | 17.571 [16.907-18.952] | 0.994 [0.741-1.466] | 1.004 [0.809-1.164] | 1.125 [0.823-1.627] | level |
| chain | 0.558 [0.540-0.579] | 0.553 [0.539-0.601] | 0.560 [0.544-0.593] | 1.777 [1.552-2.286] | 0.996 [0.944-1.077] | 1.005 [0.953-1.071] | 3.194 [2.824-4.136] | level |
| fanout | 70.887 [66.626-78.200] | 72.084 [68.383-100.077] | 70.488 [66.581-78.735] | 70.754 [66.912-99.898] | 1.016 [0.912-1.407] | 0.977 [0.710-1.114] | 0.974 [0.709-1.250] | level |
| yield | 6.457 [6.157-7.481] | 6.493 [6.167-9.938] | 6.505 [6.251-7.756] | 43.425 [40.985-44.149] | 1.008 [0.834-1.577] | 1.019 [0.643-1.209] | 6.691 [4.390-7.011] | level |
| hog | 0.011 [0.009-0.014] | 0.010 [0.008-0.019] | 0.010 [0.008-0.014] | 212.884 [199.758-224.776] | 1.012 [0.685-1.386] | 0.947 [0.621-1.359] | 20517.907 [10962.208-25693.089] | level |
| produce | 5.326 [5.280-5.665] | 5.341 [5.262-13.300] | 5.325 [5.265-5.467] | 6.024 [5.835-6.269] | 1.005 [0.939-2.450] | 0.997 [0.411-1.034] | 1.132 [0.439-1.165] | level |

## Rerun: bench/mixed 100k, 10 more rounds (claim fb-mix2)

### bench/mixed 100k/s, 8 workers, -pace sleep, 10 rounds (µs; lower is better)

| row | m10 | m11 | aa11 | hyper | m11/m10 | aa11/m11 (A/A) | hyper/m11 | verdict |
|---|---:|---:|---:|---:|---|---|---|---|
| p50 | 78 [75-81] | 76 [74-83] | 76 [72-87] | 86 [83-105] | 1.006 [0.961-1.025] | 0.994 [0.916-1.101] | 1.121 [1.000-1.382] | level |
| p99 | 1175 [1125-1631] | 1236 [1005-7546] | 1200 [948-73049] | 1260 [1121-214632] | 1.080 [0.824-5.495] | 0.939 [0.164-58.345] | 0.949 [0.151-178.562] | level |
| p999 | 1768 [1711-7948] | 1850 [1634-16282] | 1761 [1573-87722] | 1870 [1706-233527] | 1.061 [0.922-8.199] | 0.956 [0.111-42.943] | 0.967 [0.105-129.882] | level |
| timer_p99 | 230 [186-324] | 245 [99-328] | 246 [90-355] | 258 [184-328] | 1.106 [0.401-1.618] | 1.025 [0.427-1.241] | 1.122 [0.607-2.636] | level |

### bench/mixed 100k/s, server cost (pru, counted window) (per request; lower is better)

| row | m10 | m11 | aa11 | hyper | m11/m10 | aa11/m11 (A/A) | hyper/m11 | verdict |
|---|---:|---:|---:|---:|---|---|---|---|
| cycles a request | 79093 [78408-80097] | 78849 [78139-80827] | 78839 [77538-81668] | 90083 [88961-91688] | 1.001 [0.990-1.011] | 0.999 [0.975-1.026] | 1.140 [1.101-1.164] | level |
| instructions a request | 95085 [94955-95226] | 95105 [94998-95228] | 95168 [94589-95346] | 101762 [100643-102198] | 1.000 [0.999-1.002] | 1.001 [0.994-1.002] | 1.071 [1.058-1.074] | level |

### bench/mixed 100k/s, server context switches (per request; lower is better)

| row | m10 | m11 | aa11 | hyper | m11/m10 | aa11/m11 (A/A) | hyper/m11 | verdict |
|---|---:|---:|---:|---:|---|---|---|---|
| context switches a request | 0.671 [0.667-0.678] | 0.671 [0.667-0.674] | 0.671 [0.653-0.682] | 0.843 [0.724-0.882] | 0.999 [0.990-1.010] | 1.003 [0.973-1.014] | 1.262 [1.080-1.312] | level |

| arm | rounds p99 > 5 ms | which | rounds max > 5 ms | achieved min | csw a request median |
|---|---:|---|---:|---:|---:|
| m10 | 0 | none | 1 | 99988 | 0.671 |
| m11 | 2 | 2,3 | 5 | 99977 | 0.671 |
| aa11 | 3 | 0,4,7 | 3 | 98875 | 0.671 |
| hyper | 1 | 6 | 2 | 99987 | 0.843 |

p50 per round (µs): m10 77 81 81 79 79 77 78 75 75 75; m11 76 78 83 80 79 74 76 76 76 76; aa11 79 76 76 79 87 73 72 82 76 76; hyper 86 87 83 87 89 88 105 84 83 86

p99 per round (µs): m10 1138 1261 1631 1153 1178 1219 1336 1125 1127 1172; m11 4147 1219 7546 6336 1234 1005 1202 1194 1238 1547; aa11 73049 1172 1241 1229 19391 1035 948 69664 1134 1132; hyper 1379 1271 1138 1250 1325 1215 214632 1184 1121 1288

p999 per round (µs): m10 1767 1912 7948 1719 1770 1773 1901 1711 1718 1764; m11 11095 1768 16282 14094 1854 1634 1798 1780 1847 7060; aa11 87722 1741 1805 1781 26382 1689 1573 76438 1714 1704; hyper 2627 1830 1717 1910 1932 1783 233527 1797 1706 2420

round start times: 13:26:10 13:26:52 13:27:33 13:28:15 13:28:23 13:29:05 13:29:46 13:30:28 13:30:36 13:31:18

## bench/mixed 100k, both claims together (20 rounds)

### bench/mixed 100k/s, 8 workers, -pace sleep, 20 rounds (µs; lower is better)

| row | m10 | m11 | aa11 | hyper | m11/m10 | aa11/m11 (A/A) | hyper/m11 | verdict |
|---|---:|---:|---:|---:|---|---|---|---|
| p50 | 78 [75-102] | 78 [74-90] | 76 [72-87] | 86 [81-105] | 1.006 [0.775-1.169] | 0.994 [0.800-1.101] | 1.099 [0.900-1.382] | level |
| p99 | 1211 [1091-156829] | 1236 [1005-110424] | 1172 [868-73049] | 1232 [1033-214632] | 1.054 [0.008-27.306] | 0.939 [0.008-58.345] | 0.935 [0.009-178.562] | level |
| p999 | 1844 [1660-166096] | 1850 [1634-118537] | 1740 [1495-87722] | 1870 [1613-233527] | 1.044 [0.011-9.869] | 0.956 [0.013-42.943] | 0.953 [0.014-129.882] | level |
| timer_p99 | 242 [186-504] | 270 [99-359] | 258 [88-355] | 250 [136-411] | 1.106 [0.401-1.725] | 0.973 [0.264-1.679] | 0.955 [0.408-2.636] | level |

### bench/mixed 100k/s, server cost (pru, counted window) (per request; lower is better)

| row | m10 | m11 | aa11 | hyper | m11/m10 | aa11/m11 (A/A) | hyper/m11 | verdict |
|---|---:|---:|---:|---:|---|---|---|---|
| cycles a request | 78998 [77872-83020] | 79292 [78139-81173] | 78845 [77422-81668] | 89762 [88710-91688] | 1.001 [0.955-1.031] | 0.999 [0.954-1.026] | 1.134 [1.096-1.164] | level |
| instructions a request | 95070 [93337-95226] | 95089 [94143-95240] | 95141 [94589-95346] | 101762 [100488-102198] | 1.000 [0.991-1.017] | 1.001 [0.994-1.012] | 1.071 [1.055-1.085] | level |

### bench/mixed 100k/s, server context switches (per request; lower is better)

| row | m10 | m11 | aa11 | hyper | m11/m10 | aa11/m11 (A/A) | hyper/m11 | verdict |
|---|---:|---:|---:|---:|---|---|---|---|
| context switches a request | 0.670 [0.645-0.681] | 0.671 [0.625-0.686] | 0.673 [0.653-0.686] | 0.845 [0.724-0.882] | 1.000 [0.941-1.064] | 1.000 [0.973-1.081] | 1.262 [1.080-1.388] | level |

| arm | rounds p99 > 5 ms | which | rounds max > 5 ms | achieved min | csw a request median |

## Yield per round (ms)

10 rounds: m10 7.02 6.63 6.44 6.48 7.01 6.24 6.56 6.37 6.34 6.79; m11 7.15 7.07 6.45 11.37 7.75 6.64 6.61 6.75 7.85 8.72; aa11 6.45 7.44 6.52 6.82 6.69 7.04 6.56 7.53 6.58 6.38

30 rounds: m10 6.53 6.17 6.23 6.39 6.42 6.29 6.37 6.27 6.30 6.30 6.38 7.13 7.28 6.95 6.49 6.21 7.23 6.51 6.38 7.26 6.35 6.32 7.10 6.16 6.65 7.05 6.75 6.64 7.09 7.48; m11 7.00 7.10 6.39 8.91 6.68 6.57 7.92 6.50 9.94 6.20 6.41 6.38 6.36 6.43 6.30 6.27 6.34 7.68 6.84 6.61 6.17 6.53 6.25 6.83 6.43 6.65 6.40 6.49 7.16 6.24; aa11 6.25 6.50 6.39 6.39 6.58 6.42 7.44 7.76 6.39 6.40 6.68 7.24 7.69 6.46 6.33 6.49 6.46 7.17 6.52 6.73 6.32 7.13 6.47 7.05 6.95 6.41 7.38 6.72 6.34 6.86
