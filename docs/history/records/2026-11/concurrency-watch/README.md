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
