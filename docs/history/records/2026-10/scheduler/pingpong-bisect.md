# bench/net pingpong regression on pup (2026-10-21)

## Verdict: code, not machine
- pup booted 2026-09-26 (kernel 7.0.0-34, governor powersave on all 22, THP madvise): same boot as #405's row (2026-10-20).
- 2d808f36f (#405) rebuilt today, unpinned, interleaved with 41ea93eab: 5.0-6.0 us/trip vs 13.6-14.2. The old build still gets #405's number.
- No core pinning is recorded for #405's row; bench-net runs unpinned (22 workers). Later in the night a Trig gate (rig535-gate) loaded pup to 14-18, so the decisive runs are pinned to (8,9) (2 workers) plus load-independent counts (strace -c, perf cpu_core/instructions).

## Bisect (first-parent, 75 merges; `merges.txt`)
| merge | pingpong unpinned (load ~6) | pinned 8,9 |
|---|---|---|
| 2d808f36f #405 | 5.0-5.2 | 7.7 |
| e82528c43 #427 | 5.8-6.2 | |
| f077fd034 #437 | 4.9-5.2 | 7.7 |
| bccc3c54f #439 land-1 | 6.2-8.2 | 7.8 |
| 6c4020f6b #448 | 6.5-8.3 | 7.8 |
| 7055bbea1 #451 land-2b | 10.0-13.0 | 16.3 |
| 42ec69f67 #460 | 11.6-13 | |
| 59c2f519a #505 | 12.1-13 | |
| 41ea93eab #523 | 13.6-14 | 16.4 |
| b37e08158 main | 13.3-13.6 (coordinator) | |

#451 is the guilty merge. #439's unpinned step (~+1.5 us) did not show pinned, in syscall counts (8.0/trip, all on one thread), or in instructions (user +1.7%, kernel flat); unconfirmed, possibly load noise.

## Inside #451: a9111f86d
Chain (pinned 8,9): d13a47272 7.9, c7e4453ca 7.8, 35c565d25 7.7, 405ed67d8 7.7, **a9111f86d 16.3**, b07777ff1 13.5.
a9111f86d "sched: the run-next slot can be stolen, and every loop counts toward a yield check". In `wake()`:

    const before = w.lifo.swap(f, .seq_cst);
    var stealable = f.home == null;
    ...
    if (stealable) notifyNew();

Before it, filling an empty run-next slot woke no one; now every wake of an unpinned fiber calls notifyNew(), which kicks a sleeping worker's poller (eventfd write). Diagnostic builds of a9111f86d (scratch copies, not committed):
- A: restore the old wake (notify only when a displaced fiber goes to the ring): 8.0-8.5 pinned, back to baseline.
- B: keep the notify, disable stealNext: 14.7-17 (small part).

Syscalls for 20,000 trips (pingpong-only program, strace -c, same pinned or unpinned):
| build | epoll_pwait | write | read | total | per trip |
|---|---|---|---|---|---|
| 405ed67d8 | 40k | 40k | 80k | 160k | 8.0 |
| a9111f86d | 141k | 98k | 138k | 377k | 18.9 |
| A (old wake) | 40k | 40k | 80k | 160k | 8.0 |
| main b37e08158 | 178k | 147k | 117k | 442k | 22 |
Kernel instructions 913M -> 1,330M; task-clock 155 ms -> 455 ms.

## Mechanism
Old: client and server fibers both run on worker 0; each trip is write, read, EAGAIN, epoll_pwait, wake into run-next, run it. 8 syscalls, one thread.
New: each poller wake calls notifyNew -> kicks a sleeper (eventfd write + its epoll_pwait + eventfd read). The woken worker searches, takes the other fiber (stealNext after 3 us, or from the ring), so client and server split across two workers. On main the idle worker also watches the busy worker's epoll (21a97bb7b, #451): strace shows each thread polling both epfds (3 and 6) and writing both eventfds (4, 7), often twice in a row. Every trip now crosses threads: a cross-core wake per direction, ~19-22 syscalls instead of 8. b07777ff1's `next_quiet` only quiets wakes when the woken worker finds the slot already empty; here it steals successfully, which clears it.

## Likely fix
Don't notify on a run-next fill when the waking worker will run the fiber itself next (waking from its own poller / about to yield or sleep), and keep a request/response pair on one worker: notify only for a displaced fiber (old rule) or when the slot's fiber is still unclaimed at the owner's next yield check (the Go `runnext` 3 us rule enforced by the owner, not by a woken thief). Recheck fork-join (test/cli/sched_forkjoin.sh), which a9111f86d was for.

Also: 41ea93eab -> main adds ~2 us more (user instructions 64.7M -> 77-79M, syscalls 377k -> 442k); not bisected.
