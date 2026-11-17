# An event-driven watch over the busy workers' pollers (2026-11-17, archived)

The question, as in [concurrency-holder](../concurrency-holder/README.md): HTTP's p99
at 80,000 requests a second on pup's one core (2 workers) is about 950 µs against
hyper's 580-630, because an arrival on a busy worker's poller waits for the watcher's
1 ms look.

The line, three designs, archived as `archive/watch-d` (0683d21ac), `archive/watch-d2`
(daace2ebe) and `archive/watch-d3` (b26e6f536):

- **D**: while a worker holds the watch, the other workers' pollers are nested in its
  own (epoll EPOLLET, kqueue EV_CLEAR), registered once per watch hand-off; its wait
  ends as soon as a watched poller gains events, with the 1 ms look as a backstop.
- **D2**: one waiter per poller: a watched worker sleeps on a poller holding only its
  kick, so the watcher is the one thread woken by its connections; a watcher waking
  with work lets the watch go, kicking the kick-only sleepers back to their own.
- **D3**: kick-only sleeps only while another worker is busy, the watch passed to one
  sleeper rather than broadcast, and released only while a busy owner exists.

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

## Measured (pup board W, Y; the Mac's boards)

| arm | p99 at 80k | p50 | cycles/req trivial / mix vs main | ping-pong |
|---|---|---|---|---|
| main | 951-999 µs | 44 µs | | 4.85 µs |
| D | 403 | 147 | 1.48 / 1.20 | 2x slower |
| D2 | **328 (316-332)** | 96 | 1.50 / 1.21 | 2x slower |
| D3 (Mac only) | level with main's low Mac tail | level | 1.30 / 1.12 | 8.8% slower |
| hyper | 580-653 | 44 | | |

D2's counters at 80k: the watch let go 0.5 times a request; at 200k only 106 wakes in
all, so the cost lived in the quiet moments. D3 made releases rare (0.06 a request on
2 workers) and the cost stayed: with 2 workers no third can be busy, so while both
sleep each arrival wakes the owner and, through the nesting, the watcher.

## The lesson

The tail is solvable: a second waiter on a busy worker's events takes p99 below
hyper's, and tight. The cost is that second waiter while no one is busy: any design
must have exactly one thread woken per arrival when every worker sleeps, and add no
system call per sleep. A shared sleep (every sleeper in one epoll that nests every
poller, whose direct waiters wake one at a time) is the candidate written up next;
macOS wakes every thread waiting on a kqueue, which a probe here measured, so the
Mac needs its own answer.
