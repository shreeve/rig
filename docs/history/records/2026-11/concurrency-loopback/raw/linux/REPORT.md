# rig#1105 loopback on Linux (pup, 2026-11-16 06:00–06:19, board slot 274, QUIET honoured)

main ea3704772 against the branch bfdf37fb5 (= 8d0c506b0's runtime), `rig build --release` (rig-safe), Tokio from
bench-remeasure (bench/ unchanged since 3f4564a4b). The record's board.py / med.py / http_ab.py (Linux settle()), every
run pinned (the slot's shell is on LP cores 20-21). Medians of the rounds, µs a trip unless named.

| row | cores | main | branch | branch against main | Tokio |
|---|---|---:|---:|---|---:|
| echo | 6,7 | 3.74 | 3.52 | 5.9% faster | 3.40 |
| pingpong | 6,7 | 5.16 | 4.92 | 4.7% faster | 4.88 |
| connect | 6,7 | 28.80 | 31.34 | **8.8% slower** | 28.67 |
| echo | 0-11 | 1.12 | 1.16 | 3.6% slower (min 1.08 / 1.07) | 1.31 |
| pingpong | 0-11 | 5.46 | 5.10 | 6.6% faster | 4.92 |
| connect | 0-11 | 26.52 | 28.69 | **8.2% slower** | 32.12 |
| HTTP req/s, 5 rounds | 0-11 | 616k–809k, median 739k | 551k–632k, median 625k | **15% fewer**; main ahead in 4 of 5 rounds; p50 74 → 91 µs | hyper 352k–363k |

tasks (spawn, chain, yield, produce, fanout, hog) and actors (solo, spread, contend): level, pinned and on 0-11
(yield 1.2% faster pinned; spawn within 1.6%).

System calls for net's three benchmarks (strace -f -c; 20,000 + 100,000 + 500 calls):
main 831,943 (read 484,987 of which 241,059 EAGAIN; write 328,347; futex 16,172),
branch 495,664 (read 242,961, 722 EAGAIN; write 241,817; futex 8,449): **40% fewer**,
Tokio 664,933 (recvfrom 361,594, sendto 241,000, futex 13,995, epoll_wait 45,899).

Reading: the short-read change does what it says on Linux (EAGAIN reads gone; half the futex calls), and echo and
pingpong pinned are 5–6% faster. But connect is 8–9% slower at both core sets, and HTTP serves 15% fewer requests
on 12 cores: against the record's own bar ("pingpong and connect level on Linux; HTTP at least level") it does not
pass on Linux. Files: this folder (net6/net12/tasks6/tasks12/actors6/http12 .txt, strace-*.txt).
