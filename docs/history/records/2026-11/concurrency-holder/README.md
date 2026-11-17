# A sleeping worker that holds a busy worker's poller (2026-11-17, archived)

The question: Rig's HTTP p99 at a moderate load on one core (pup, server on
cores 0 and 5, 80,000 requests a second, 1 in 4 hashing for about 30 µs) was
about 1 ms, against hyper's 590-630 µs, with p50 level (44 µs). The p99 sat at
the watcher's 1 ms period: a request landing on a worker's poller while that
worker runs a hash waits until the watcher's next look, because the other
worker sleeps in its own poller.

The idea, Tokio's "the parked worker holds the driver" and the Go panel's
step 2, as a doorbell: a worker going to sleep nests a busy worker's poller fd
in its own poller (EV_DISPATCH on kqueue, EPOLLONESHOT on epoll); on readiness
it rings the owner's bell, which the owner answers at its next switch by
looking at its own poller; the holder takes the events itself only when the
owner has run one fiber for 50 µs, or (round 1) already has fibers queued.

Archived after the agreed two rounds, as `archive/sched-holder` (e07c367e0,
on PR #1123 and the stdout flush), `archive/sched-holder2` (round 2,
975d60ebf, on main 7db5f6af5) and `archive/sched-holder2b` (round 2 with a
20 µs ring delay, 1f48e9bb7). Builds, plans and reviews: the Concurrency
session's notes, `hyper-fix/holder-*.md`, `review-holder-design.md`; boards T,
U and V in the Rig session's `hyper-1116/REPORT.md`.

## Correction (2026-11-17): the p99 rows measured the load generator

Every p99 in this record came from bench/mixed's generator, which paced with Go's
`time.Sleep`: with every generator thread idle, Go's timers wait in epoll with
whole-millisecond timeouts, so the generator sent requests up to 1 ms late. Run by run,
a server's p99 was the generator's own timer lateness plus a constant for that server,
and the lateness depended on how the server's answers arrived — so the arms here
"won" by changing that rhythm, not by serving faster. Board Z (pup, slot 541, the Rig
session's `hyper-1116/REPORT.md`) reran one core at 80,000 a second, 10,000 idle, with
a generator whose one pacing thread spins on the clock:

| arm | p50 | p99 (runs) | p99.9 | generator lateness p99 |
|---|---|---|---|---|
| main, old generator | 43 µs | 920 (786-999) | 1,415 | 585 |
| hyper, old generator | 44 | 650 (559-747) | 1,381 | 242 |
| main, new generator | 30 | **50 (48-51)** | 67 | 5 |
| hyper, new generator | 33 | **51 (51-53)** | 85 | 5 |
| Pingora, new generator | 31 | 56 (55-398) | 87 | 5 |

At 40,000: main 18 / 53 / 70 µs (p50 / p99 / p99.9), hyper 18 / 54 / 143; at 120,000:
main 23 / 62 / 82, hyper 17 / 56 / 105. Main was level with hyper at p99 all along and
ahead at p99.9; the costs this record measured (p50, cycles, the ceiling, ping-pong)
were real, the tail gains were not. The line's last design, a shared sleep on Linux
(every sleeper in one epoll nesting every poller), was built and stopped before any
board, as `archive/shared-sleep` (6c0416f4f): there was no tail left to fix.

## What it bought, and at what cost (pup, one core, medians)

| arm | p99 at 80k | p50 at 80k | ceiling at 200k vs main | mix cycles vs main | connect (0-11) vs main |
|---|---|---|---|---|---|
| main | 950-1,003 µs | 43-44 µs | | | 26.5-27.6 µs |
| holder (a7cd913c2) | 570 | 170 | 3.7-5.3% lower | 4% more | 13% slower |
| round 1: take when queued (24b397104) | 454 | 137 | 4.4-5.5% lower | 2% more | 11% slower |
| round 2: re-arm on the answer (975d60ebf) | 557 | 158 | 5.3% lower | 5% more | 14% slower |
| round 2, 20 µs ring delay (1f48e9bb7) | 516 | 169 | 5.9% lower | 5% more | 16% slower |
| hyper | 591-632 | 44 | | | |

Every arm cut p99 below hyper's, and every arm paid a p50 three to four times
main's, a ceiling 4-6% lower, more cycles a request, and slower connects. The
layout control (main with two functions moved) moved the ceiling 0.03-0.12%.

On the Mac (10 workers, 100k mix) round 2 brought p50 level with main and cut
p99 (672 against 1,898 µs at 55k on 2 workers), at about 2% more cycles; the
Linux p50 cost did not follow it.

## What the counters say

`RIG_SCHED_STATS=1` (a7cd913c2 onwards) prints held, refused, rang, answered
and took per worker as a signal ends the program.

- Holder, 80k, 2 workers: about 140 holds per 1,000 requests, mutual; nearly
  every bell answered by its owner, nothing taken. The post-ring 200 µs re-arm
  window left the owner's poller unwatched — the first p50 explanation.
- Round 2 removed that window (re-arm on the answer; Mac p50 back to main's)
  yet pup's p50 stayed 158-169 µs.
- At 200k on pup, round 2 held fewer than one poller per 1,000 requests, yet
  the ceiling still fell 5.5%.

## The open question

The Linux cost is structural, paid per request or per sleep even when no one
holds. Candidates, unmeasured: the EPOLLONESHOT re-arm (two more `epoll_ctl`
calls) on every sleep; the nested epoll fd raising wakes on the parent epoll;
the owner's added checks at each switch and each wait. A `perf` profile of
round 2 against main at 200k, and `strace -c` per request, would separate them.

The tail stays the open row against hyper on pup. What did cut it, in every
arm, was a second worker waiting on the busy worker's events rather than its
own; any next design needs that without a per-sleep cost, measured by its
system calls per sleep before its tail.

A separate finding from the same work, on the Mac: an empty zero-timeout
`kevent` costs about 12 µs and a context switch; `kevent64` with
`KEVENT_FLAG_IMMEDIATE` costs 0.16 µs (branch kevent-immediate, in progress).
