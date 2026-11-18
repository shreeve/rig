# Rig against hyper, Go and Pingora: where HTTP stands (2026-11-17)

Where Rig's HTTP stood against hyper 1.x on Tokio, Go's net/http and Pingora at the end
of the 2026-11-16/17 line (the holder, the watch, the deadline, the HTTP stack, the
non-blocking flush, the Mac's immediate look, the timer cover), on both machines, with the
load generator paced on time. Every row has a layout control beside it: main plus a
dead function, built separately, the A/A spread.

## How it was measured

- **Generator.** Every latency row uses bench/mixed's on-time generator (#1130, `-pace
  spin`): one thread reads the clock and writes each request at its time. The old
  generator paced with Go's `time.Sleep`, which on Linux waits in epoll with
  whole-millisecond timeouts and sent requests up to 1 ms late; its p99 rows measured the
  generator ([concurrency-holder](../concurrency-holder/README.md),
  [concurrency-watch](../concurrency-watch/README.md), each corrected). CPU, ceiling,
  closed-loop and bench/net rows never depended on it.
- **Closed loop** is given as the median of 7 rounds with their range, never the best:
  on pup the same binary scored 740k and 901k req/s best-of-7 in two slots.
- **bench/net ping-pong pinned to two sibling threads** (pup 6,7) is bimodal in every arm,
  old main included: a round is 4.8 µs or about 11, and its median only says which mode
  won. Its minimum is the comparable number.
- **Linux:** pup (Core Ultra 9 185H), timing slots opened by the Rig session with the
  machine quiet. Server on one P-core's two threads (0,5) for the one-core rows, on 0,1,2,5
  for cycles per request, on 0-11 for the closed loop. Sources: the Rig session's
  boards X, Z, P and AB (`hyper-1116/REPORT.md`, slots 538, 541, 543, 544).
- **Mac:** Apple M5 (4 P + 6 E), every timed run under `tools/mac-claim`. A system process
  held about one core throughout (spotlightknowledged in the first claims,
  IMTranscoderAgent in the later ones).

## Linux (pup)

Rig is main with the timer cover (8cfec3286, #1135; main 39830dcc9). A/A is the spread of
three other builds of main in the same board (m9 1871ff05e, its layout copy lay3, and hb,
the HTTP fix's build). Board AB unless named.

| row | Rig | A/A | hyper | Go | Pingora | Rig against hyper |
|---|---|---|---|---|---|---|
| cycles a request, trivial, 150k | 30,076 | 30,690-30,948 | 33,522 | 68.8k (X) | 47.7k (X) | 10% fewer |
| cycles a request, mix (1 in 4 hashing) | 66,639 | 67,062-67,332 | 69,246 | 93.6k (X) | 83.2k (X) | 3.8% fewer |
| one core, 80k: p50 / p99 / p99.9 µs | 31 / 50 / 72 | 30-31 / 50-51 / 62-70 | 33 / 51 / 74 | past saturation (Z) | 31 / 56 / 87 (Z) | level at p99, lower p50 |
| one core, 40k: p50 / p99 / p99.9 (Z, m9) | 18 / 53 / 70 | | 18 / 54 / 143 | | 21 / 50 / 138 | level; lower p99.9 |
| one core, 120k: p50 / p99 / p99.9 (Z, m9) | 23 / 62 / 82 | | 17 / 56 / 105 | | 37 / 86 / 185 | **trails by 6 µs** at p50 and p99 |
| one core, 140k: p50 / p99 (P, m9, threads free) | 21 / 64 | | 20 / 87 | | | lower p99 |
| one core, 150k: p50 / p99 (P, m9, threads free) | 36 / 160 | | 266 / 2,062 (past capacity) | | | far lower |
| one-core ceiling, offered 160k / 200k (req/s) | 151,636 / 143,947 | 150,185-151,227 / 143,119-143,640 | 149,709 / 139,863 | 90.3k / 83.5k (X) | 122.3k / 114.0k (X) | 1.3% / 2.9% more |
| closed loop on 0-11, median of 7 (range), k req/s | 731 (698-819) | 663-779 (613-894) | 352 (293-363) | 445 (X, best of 7; no median taken) | | 2.1x |
| bench/net on 0-11: connect / echo / ping-pong µs | 27.20 / 1.01 / 4.98 | 26.80-28.05 / 1.01-1.03 / 5.00-5.01 | | | | |
| bench/net pinned 6,7: connect / echo µs | 29.39 / 3.57 | 29.14-29.71 / 3.54-3.59 | | | | |

Binding each worker thread to a CPU (board P) changes nothing for Rig on one core's two
threads (equal medians); it helps hyper above 140k. No case for binding in the runtime.

## Mac (M5, 10 workers unless named)

Rig is main 1871ff05e (#1127) for the CPU, closed-loop and net rows, and a1742e713 (the
same runtime) for the tail rows. A/A is the layout copy against main, paired by round.
CPU rows are per request at 100k open loop, 12 rounds rotated; the tail rows are the
on-time generator's, 10 rounds at 2 workers.

| row | Rig | A/A | hyper | Go | Rig against hyper |
|---|---|---|---|---|---|
| cycles a request, trivial, 100k | 36.4k | 0.985 | 42.8k | 109.7k | 12% fewer |
| cycles a request, mix, 100k | 73.0k | 0.985 | 83.3k | 145.9k | 12% fewer (all 12 rounds) |
| cycles a request, mix, 2 workers, 55k | 64.3k | 1.001 | 66.2k | 95.4k | 5% fewer |
| mix, 2 workers, 55k: p50 / p99 / p99.9 µs | 40 / 495 / 967 | 39 / 463 / 964 | 42 / 515 / 989 | 30 / 701 / 1,380 | level |
| mix, 8 workers, 100k: p99 in rounds under 5 ms | 1,001 | 922 | 1,013 | 1,363 | level |
| closed loop, 64 connections, median of 7 (range), k req/s | 166.4 (158.6-175.0) | 166.9 (162.2-177.3) | 174.5 (173.6-175.8) | 155.8 (146.1-157.6) | **4% fewer** (paired 0.958) |
| bench/net connect, ms a run (median) | 25.7 | 0.998 | Tokio 31.5 | 31.0 | 18% faster |
| bench/net ping-pong | 307 | 0.990 | Tokio 300 | 321 | level |
| bench/net echo | 635 | 1.000 | Tokio 517 | 591 | **23% slower** |

At 100k on 8 workers every arm, the A/A pair included, had 4-10 of 20 rounds with a
p99 of 10-350 ms: the machine, not a server. On the Mac the on-time generator is
itself late (its own p99 about 100 µs at 55k and 470-650 at 100k, against a few µs on
pup), probably because one thread does every socket write; the old sleeping pacer is
more punctual there, and with it Rig and hyper are also level (p99 471 against 465 at
55k on 2 workers).

## Where Rig leads

- CPU a request: 4-10% under hyper on Linux and 5-12% on the Mac; half to a third of Go's.
- The one-core ceiling on Linux (1.3% and 2.9% more than hyper), and the tail past 140k,
  where hyper runs out of capacity first.
- The closed loop on Linux: 2.1x hyper by median.
- Connect on the Mac: 18% faster than Tokio and Go.
- p99.9 on Linux at 40k and 120k, and at 80k in board Z (67 against 85; in board AB 72
  against 74, inside the A/A spread); p50 at 80k (31 against 33).

## Where Rig trails

1. **Linux, one core at 120k:** hyper is 6 µs ahead at p50 and p99 (17 / 56 against 23 /
   62). Rig is level at 40k and 80k and ahead from 140k.
2. **Mac echo:** 23% slower than Tokio and 8% slower than Go. The Mac's immediate look
   (#1127) cost echo about 4%, a trade the owner accepted for the other rows.
3. **Mac closed loop:** 4% fewer requests than hyper by median (paired 0.958
   [0.909-1.002]); the best rounds are level (175.0k against 175.8k).

Both Mac rows are open work as of this record (a diagnosis on the Mac, measure first).
