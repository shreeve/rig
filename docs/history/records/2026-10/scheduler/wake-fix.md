# Fix for the pingpong regression: PR #541 (merged as f14b86c58), rows in PR #543

## The rule (sched.wake)
Filling a worker's run-next slot wakes no worker. A fiber it pushes out to the ring still wakes one (the old rule).
- The worker runs the fiber next when it woke the fiber itself: from its poller or a timer while it looks for work (`w.current == null`), at a task's end (`done` runs with current null), or at a yield check that then yields to it (`w.servicing`, set in serviceBusy).
- A fiber that wakes another and keeps running either stops soon (send, then wait) or reaches a yield check. A loop's yield check yields to the slot, so the maker goes to the ring and a worker is woken for it. A recursive check reads `waiting`, which a fill from a running fiber sets. Fork-join spreads at g's first yield check.
- `next_quiet` is removed: no fill wakes a worker that would find the slot empty. stealNext stays for workers that are searching anyway.

## The watcher (sched.sleepIn, sleep's defer)
Before: each time a busy worker that holds descriptors woke from sleep while no watch was held, it kicked a sleeper (passWatch). That sleeper's serviceAll then took the busy worker's fibers. The watcher dropped the watch whenever the other worker happened to be idle at that instant.
Now: the watcher keeps the watch while a worker holding descriptors is awake, or has slept since the watch began (`slept` against `watch_mark`). It lets go only when every such worker slept through a whole watch.
Ordering (Dekker): the waker stores `idle=0` before it loads `watcher`, and the watcher stores `watcher=null` before it reads `idle`. The old code loaded `watcher` before storing `idle=0`.

Both parts are needed. Unit test crossings out of 4000 (Mac, debug):
- main: 1000-1600
- wake rule only: about 700
- deferred rule with the old watcher: 940-1140
- both: about 25

## Tests
- New: "two tasks that answer each other over a socket stay on one worker". It runs 2000 TCP round trips on 2 workers and counts reads that land on a different worker from their answer. The bound is under 500.
- Rewritten: "a task made while its maker computes runs beside it, from the maker's next yield check". It needs real parallelism: the task spins until the maker has made 1000 more turns.
- The recursive-check test no longer sets next_quiet.
- test/cli/sched_forkjoin.sh: pass.
- Mac full suite: 9546 jobs, green.
- pup `zig build test` in debug, safe and fast: all pass.

## System calls (pup, pingpong only, 20,000 trips, cores 8,9)
- main: 432k (21.6 a trip); worker 1 ran 19,974 fibers
- fix: 164k (8.2 a trip: epoll 2.2, write 2, read 4); worker 1 ran 27

## Bench numbers, interleaved, best (rows in #543)
| | main | fix |
|---|---|---|
| pup pingpong, cores 8,9 (bench-net) | 6.98 us | 4.92 us |
| pup pingpong, cores 8,9 (pp-only, quiet moment) | 11.2 us | 5.2 us |
| pup pingpong unpinned, load 13 (Trig gate) | 19.7 us | 10.7 us |
| pup connect / echo, cores 8,9 | 31.0 / 3.97 us | 29.6 / 3.94 us |
| pup http req/s, cores 8,9 | 166,171 | 194,189 |
| pup tasks spawn / chain / fanout / yield | 73 / 96 ns / 344 ms / 24 ns | 69 / 86 ns / 314 ms / 27 ns |
| Mac pingpong / echo / connect | 19.71 / 5.85 / 51.4 us | 16.17 / 5.97 / 56.7 us |
| Mac http req/s | 170,635 | 168,668 |
| Mac tasks spawn / chain / fanout / yield | 126 / 44 ns / 78.5 ms / 6 ns | 142 / 45 ns / 80.3 ms / 9 ns |
| Mac actors solo / contend / spread | 5.1 / 30 / 0.9 ns | 5.0 / 33 / 1.0 ns |

pup could not be measured quietly: a Trig gate held load at 7-15 all night. I never got an unpinned number to set against #405's 4.82 us.

On the Mac, net and http often failed with "can't assign requested address" (ephemeral ports used up by the 10,000 idle connections). This happened for both builds, so it is not from this change. The Mac connect number is noisy.

## Open finding: Mac yield 40% slower from Worker layout, not logic
On the Mac, yield-only, 1M yields: main 6.5-8.5 ms, fix 8.7-15.6 ms. The cause is the Worker struct's layout:
- Old main with only the two new fields added, unused, is just as slow.
- Fix with the old notify everywhere is just as slow.
- Fix with cache-line alignment is 5.5-7.0 ms, faster than main. The alignment: `sp` align(cache_line), Ring `head` and `tail` each align(cache_line), and `lifo` align(cache_line).

Full tasks bench with alignment against main, best of 4 (ms per run, not per task):
- spawn 15.96 vs 14.57
- chain 458 vs 446 us
- fanout 85.1 vs 81.5
- yield 5.65 vs 6.85

Fanout may be about 4% slower; this needs pup timing. On pup, unaligned yield is 24 vs 27 ns (12% slower).
Experiment tree: /private/tmp/claude-501/-Users-shreeve-Data-Code-rig/1762ad8a-9823-467a-b54f-a392863cb42c/scratchpad/exp5.
