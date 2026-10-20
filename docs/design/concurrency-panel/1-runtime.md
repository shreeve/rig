# Runtime and scheduler

Probes: scratchpad `panel/runtime/*.rig`, macOS, release-fast; Linux untested.

## Findings

1. **A busy worker's timers and socket events wait until it stops.** Only its own `next()` every 61 turns (sched.zig:1167) or a worker about to sleep (857) services them; a yield check never does (221), `Timers.add` kicks no sleeper (484), and a sleeper's timeout is set once (586). A local task's 10 ms sleep took 1323 ms at RIG_WORKERS=8 while its home spun; a free one's, 1350 ms at 1 worker; a socket round trip, 1.47 s with seven idle (`timer_busy`, `timer_free`, `io_busy`).

2. **Fork-join runs serially.** A new task sits in the maker's run-next slot, unstealable, waking no one (172-178); yield checks count only an outermost loop's turns, reset on entry (emit.zig:2745). `t = nested()&; nested(); >t` took 2482 ms at 8 workers, both as tasks 1290 ms (`forkjoin`).

3. **The blocking pool undercounts busy threads.** `idle` drops when a thread wakes (936), not at dispatch (889): two FIFO reads with one idle thread ran serially in 2 of 11 runs (250 ms read done at 554 ms, `pool`). It also spawns under a spin lock (890), never retires threads, and keeps the call on the fiber's stack (966), out of reach of cancel and `within:`.

4. **No lost wakeup found** in `wakeHome`/`idle` (192, 1256-1265), the searching/sleepers handshake (1218-1284), or the block cache (2014-2034): seq_cst store-then-load pairs, or no switch inside.

5. **Memory.** A sleeping task holds a stack page: 17.0 KiB on the Mac, 5.2 KiB on Linux (Tokio 270 B). Cheaper, unmeasured: copy a long-parked fiber's live frames aside and release its pages, keeping the reservation.

6. Waits that spin on `yield` (tasks.zig:888, 1983) burn a core. Fanout trails Tokio (81 vs 69 ms), cause unknown.

## Decisions for the owner

1. Yield checks service their worker's due timers and poller; a new earliest timer kicks a sleeper. Default: yes.
2. Run-next is stealable (Go's runnext), and filling it wakes an idle worker. Default: yes.
3. Yield checks count every loop's turns. Default: yes.
4. An idle worker waits on every poller (nest them in one). Default: yes, before more I/O.
5. Pool: count at dispatch, spawn outside the lock, retire after 10 s idle, `RIG_BLOCKING_THREADS`. Default: yes, before std.file grows.
6. Pool calls on the heap, so cancel and deadlines end the wait. Default: yes.
7. Stack hibernation. Default: prototype later.
8. io_uring per worker. Default: after 1-6.
