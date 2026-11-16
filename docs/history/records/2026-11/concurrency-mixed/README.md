# Open-loop mixed-workload HTTP benchmark: first measurement (2026-11-16, Mac)

The item the owner approved before any claim against Tokio or Go: an
open-loop benchmark of requests that compute, over thousands of idle
connections. bench/mixed (its README gives the method) was built for it
on the branch `bench-mixed`, from main ea3704772; the runs used the
benchmark's commit 3b0b8b797 (main plus bench/mixed alone).

## Setup

- **Machine.** Apple M5, 10 cores, macOS. Every timed run held the Mac's
  claim (`tools/mac-claim`, under 20 minutes each), which waits for the
  machine to go quiet; builds ran through `tools/heavy`.
- **Servers.** Rig `http.serve`, `rig build --release`; hyper 1 on Tokio
  1.53's multi-threaded runtime, `cargo build --release`, LTO, one
  codegen unit; Go's `net/http`, `go build`.
- **Workload.** One request in four is `GET /hash?seed=N`, the 64-bit
  FNV-1a hash of 4 KiB of xorshift data, 8 times over: 31 µs of one core
  in each language, measured alone (Go 31.3 µs, Rust 30.7 µs, Rig 30.8
  µs). The rest are `GET /`, 13 bytes. The generator checks every
  answer's status and body; no run had an error.
- **Load.** The Go generator in bench/mixed/load, wrk2's method: 128
  connections, each with a fixed schedule of send times, latency counted
  from the intended start. 1 s warm-up, then 5 s counted, per rate.
  5,000 idle keep-alive connections opened first and held through every
  rate (100 of them checked to still answer at the end: 99 of 99 in
  every run). Rig's server ran with `RIG_HTTP_IDLE_MS=600000`, since its
  default closes a connection idle for 60 s and Go's and hyper's never do.
- **Rounds.** 5 rounds, each starting every server once, fresh, through
  all seven rates in increasing order; the servers' order rotated each
  round.

```sh
O=$SCRATCH/mixed; R=docs/history/records/2026-11/concurrency-mixed
tools/heavy bench/mixed/bench-mixed --out $O --build-only
tools/mac-claim --minutes 19 bench-mixed-1 bench/mixed/bench-mixed --out $O --time-only --rounds 5 \
  --rates 20000,40000,60000,80000,100000,120000,140000 --raw $R/mac-raw.jsonl
bench/mixed/bench-mixed --summary $R/mac-raw.jsonl
```

## The table

Median over 5 rounds, the best in brackets. `/` p99 and `/hash` p99 are
the two routes' own 99th percentiles; the cores are CPU time over the
counted window, the server's and the generator's.

| offered | server | req/s | p50 | p99 | p99.9 | max | `/` p99 | `/hash` p99 | server cores | generator cores |
|---|---|---|---|---|---|---|---|---|---|---|
| 20000 | rig-safe | 19999 | 32 µs (32 µs) | 198 µs (104 µs) | 923 µs (882 µs) | 1146 µs (1105 µs) | 176 µs | 216 µs | 0.4 | 0.4 |
| 20000 | tokio | 19999 | 32 µs (32 µs) | 314 µs (163 µs) | 950 µs (906 µs) | 1516 µs (1129 µs) | 306 µs | 348 µs | 0.4 | 0.4 |
| 20000 | go | 19999 | 40 µs (39 µs) | 402 µs (321 µs) | 1030 µs (998 µs) | 1269 µs (1216 µs) | 393 µs | 451 µs | 0.8 | 0.6 |
| 40000 | rig-safe | 39999 | 41 µs (41 µs) | 367 µs (144 µs) | 980 µs (933 µs) | 1264 µs (1179 µs) | 349 µs | 408 µs | 0.7 | 0.7 |
| 40000 | tokio | 39999 | 41 µs (41 µs) | 431 µs (284 µs) | 1006 µs (941 µs) | 1271 µs (1222 µs) | 417 µs | 470 µs | 0.7 | 0.7 |
| 40000 | go | 39999 | 47 µs (46 µs) | 481 µs (461 µs) | 1084 µs (1076 µs) | 1369 µs (1346 µs) | 470 µs | 522 µs | 1.3 | 0.8 |
| 60000 | rig-safe | 59999 | 54 µs (53 µs) | 500 µs (389 µs) | 1118 µs (1032 µs) | 1430 µs (1420 µs) | 485 µs | 526 µs | 1.2 | 1.1 |
| 60000 | tokio | 59999 | 54 µs (53 µs) | 502 µs (459 µs) | 1113 µs (1099 µs) | 1449 µs (1355 µs) | 490 µs | 547 µs | 1.1 | 1.1 |
| 60000 | go | 59999 | 63 µs (62 µs) | 602 µs (580 µs) | 1252 µs (1196 µs) | 1855 µs (1611 µs) | 584 µs | 645 µs | 2.1 | 1.4 |
| 80000 | rig-safe | 79999 | 64 µs (63 µs) | 723 µs (504 µs) | 1321 µs (1295 µs) | 1943 µs (1732 µs) | 710 µs | 766 µs | 1.8 | 1.8 |
| 80000 | tokio | 79999 | 64 µs (61 µs) | 743 µs (694 µs) | 1341 µs (1323 µs) | 1885 µs (1744 µs) | 729 µs | 790 µs | 1.7 | 1.8 |
| 80000 | go | 79998 | 84 µs (82 µs) | 902 µs (878 µs) | 1487 µs (1449 µs) | 2759 µs (2194 µs) | 883 µs | 946 µs | 3.5 | 2.2 |
| 100000 | rig-safe | 99998 | 90 µs (88 µs) | 1094 µs (1023 µs) | 1669 µs (1490 µs) | 2599 µs (2166 µs) | 1083 µs | 1129 µs | 2.6 | 2.7 |
| 100000 | tokio | 99998 | 92 µs (86 µs) | 1186 µs (996 µs) | 1747 µs (1523 µs) | 2848 µs (1926 µs) | 1173 µs | 1216 µs | 2.6 | 2.8 |
| 100000 | go | 99998 | 120 µs (119 µs) | 12.7 ms (5359 µs) | 16.1 ms (8320 µs) | 20.2 ms (11.7 ms) | 12.7 ms | 12.7 ms | 4.2 | 2.7 |
| 120000 | rig-safe | 119995 | 216 µs (195 µs) | 2538 µs (1668 µs) | 4322 µs (2347 µs) | 5465 µs (3204 µs) | 2533 µs | 2550 µs | 3.4 | 3.1 |
| 120000 | tokio | 119977 | 230 µs (194 µs) | 1981 µs (1674 µs) | 4410 µs (2073 µs) | 6291 µs (2785 µs) | 1977 µs | 1997 µs | 3.3 | 3.1 |
| 120000 | go | 119950 | 1151 µs (365 µs) | 19.5 ms (3514 µs) | 25.4 ms (5581 µs) | 30.4 ms (9751 µs) | 19.4 ms | 19.5 ms | 4.4 | 2.9 |
| 140000 | rig-safe | 124084 | 304.6 ms (301.1 ms) | 566.1 ms (535.4 ms) | 575.5 ms (545.8 ms) | 583.1 ms (558.6 ms) | 566.1 ms | 566.1 ms | 3.6 | 3.0 |
| 140000 | tokio | 125121 | 304.9 ms (286.0 ms) | 528.9 ms (501.4 ms) | 538.5 ms (516.3 ms) | 570.9 ms (528.8 ms) | 528.9 ms | 528.9 ms | 3.4 | 3.0 |
| 140000 | go | 115891 | 474.6 ms (361.6 ms) | 857.0 ms (668.8 ms) | 872.6 ms (688.3 ms) | 885.9 ms (707.1 ms) | 857.0 ms | 857.0 ms | 4.4 | 2.8 |

Resident memory at the end of a run, with the 5,000 idle connections:
Rig 92-96 MiB, hyper 97 MiB, Go 178-180 MiB. The generator's timer woke
late by 23 µs at the 99th percentile at 20,000 a second, rising to
150-260 µs at 100,000 and 120,000: the floor under every latency there.

## What it shows

- **Rig and hyper are level** at every rate up to saturation: p50 within
  2 µs of each other below 120,000 (216 against 230 µs there), and the medians of p99 and p99.9 within the
  round-to-round spread. Rig's median p99 is lower at 20,000 (198 µs
  against 314) and 40,000 (367 against 431), the same at 60,000 to
  100,000, and higher at 120,000 (2.5 ms against 2.0); its p99.9 is
  within 5% of hyper's at every rate below saturation. They use the
  same cores (2.6 at 100,000).
- **Go trails both.** Its p50 is 15-31% higher below 100,000; from
  100,000 its p99 jumps to 12.7 ms and 19.5 ms (Rig's 1.1 ms and 2.5
  ms), and it spends 1.6 times the cores of either (4.2 against 2.6 at
  100,000).
- **Saturation is the machine's, not a server's.** All three stop near
  124,000 a second (Go 116,000) with the server using 3.4-4.4 cores and
  the generator about 3: past that, latency grows through the window to
  half a second. A second board at 200,000 offered (8 rounds,
  `mac-stalls.jsonl`) kept Rig at 112,000-113,500 and hyper at
  113,000-116,000, Go at 102,000-108,000: no server's throughput
  collapses under overload on a quiet machine.
- **No head-of-line blocking shows.** `/` p99 is at most 60 µs under
  `/hash` p99 at every rate in every server: a trivial request does
  not wait behind the hashing ones in any of the three.

## The idle connections set the tail

A board of 2 rounds at 20,000, 60,000 and 100,000 a second, three ways
(`mac-idle-in-load.jsonl`, `mac-idle-apart.jsonl`,
`mac-idle-none.jsonl`): the 5,000 idle connections held by the load
generator (as above), held by a process of their own
(`--idle-apart`), and none. With no idle connections, p99.9 at 20,000
falls from about 900 µs to 92-204 µs in every server (p99 to 72-90
µs):

| p99.9 at 20,000 | in the generator | apart | none |
|---|---|---|---|
| rig-safe | 868, 933 µs | 854, 833 µs | 124, 135 µs |
| tokio | 878, 856 µs | 934, 1795 µs | 92, 97 µs |
| go | 34.9 ms, 935 µs | 1035, 1027 µs | 204, 157 µs |

Holding them in a separate process changes nothing, so the cost is not
the generator's; it is the same in all three servers, so it is not one
runtime's either. It is most likely the kernel's own periodic work over
10,000 more sockets (the two ends of each), which stalls loopback
traffic for up to a millisecond. Whatever its cause, it lies under
every server equally: the ~1 ms p99.9 floor in the table is the Mac's,
and a server's lead or lag shows above it.

## Possible scheduler problems

- **Two stalls of 54-63 ms in Rig.** Of 56 Rig runs at or below
  120,000 a second, two had one stall each, both at 60,000 and both in
  the idle board (max 62.9 ms with idle connections, 54.2 ms with
  none; p99 48 and 40 ms, since a stall that long holds back about 1%
  of the window's requests). The 8 Rig runs of the overload board at
  60,000, ten minutes later, had none (max 1.4-1.6 ms), nor did any run of
  the main board. Go had larger tails more often (a 38 ms stall at
  20,000 twice, and 10-30 ms at 100,000 and above in most rounds);
  hyper's worst was 16.5 ms. Two in 56 is not enough to blame Rig's
  scheduler, nor to clear it: worth a longer board at 60,000 with
  `RIG_PREEMPT_TRACE=1`, or a trace of the workers' wakes, to see
  whether a stall is a worker asleep with work queued.
- **Under a loaded machine Rig lost more throughput.** In an
  exploratory run before the claim, on a machine at load 9 with test
  suites running (not timing data), Rig reached 93,000 a second at
  120,000 offered and fell to 66,000 at 160,000, where hyper fell from
  114,000 to 98,000 and Go from 119,000 to 109,000. On the quiet
  machine none fell. If it holds when measured, it would point at
  workers that spin or sleep badly when the cores are shared: worth one
  board under a fixed, controlled background load.

## Linux (not run)

Nothing ran on pup or burst. On pup, every timed command pinned to
cores 0-11 (a slot's shell otherwise runs on its two low-power cores),
built on the E-cores, in a pup timing slot:

```sh
cd /zfs/worktrees/rig/bench-mixed && O=/zfs/trig-pup/bench-mixed && R=$O/raw.jsonl
taskset -c 12-19 bench/mixed/bench-mixed --out $O --build-only
taskset -c 0-11 bench/mixed/bench-mixed --out $O --time-only --rounds 5 --idle 10000 \
  --rates 50000,100000,150000,200000,250000,300000,350000 --raw $R
taskset -c 0-11 bench/mixed/bench-mixed --out $O --time-only --rounds 2 --idle 0 \
  --rates 50000,150000,250000 --raw $O/idle-none.jsonl
bench/mixed/bench-mixed --summary $R
```

The rates are a guess from bench/http (pup took 830,000 trivial requests
a second closed-loop from Rig): a first round should find saturation
and set the list. 10,000 idle connections fit one loopback address; the
generator spreads them over 127.0.0.x past 20,000.

## Files

- `mac-raw.jsonl`, `mac-run-1.txt`: the main board, 5 rounds, every row
  and the run's output.
- `mac-idle-in-load.jsonl`, `mac-idle-apart.jsonl`,
  `mac-idle-none.jsonl`, `mac-run-idle.txt`: the idle-connection board.
- `mac-stalls.jsonl`, `mac-run-stalls.txt`: 8 rounds at 60,000 and
  200,000, for stalls and overload.
