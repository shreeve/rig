# Free fork-join: the design round's synthesis (2026-11-15)

Three experts, each Opus 5.5 at high effort, wrote to [brief.md](brief.md):
- [runtime.md](runtime.md): mechanics;
- [measurement.md](measurement.md): where the time goes, with programs in `measurement/`;
- [semantics.md](semantics.md): soundness.

The measurement also used the checks-cost record (records/2026-11/concurrency-checks-cost/).

## What the round found
- **Forks are not the gap.**
  - psum's 4,095 forks cost about 21 µs a core, under 1% of 2.83 ms.
  - About 83% of psum's 18% gap to Rayon is the first parallel call: Rig spends 0.44 ms more there than on a warm call, against Rayon's 0.14 ms. Warm calls trail by 3%.
  - qsort's 53% gap, measured like for like: 43% is std.sort's indirect compare, 30% its algorithm (a stable in-place merge against `sort_unstable`), and 2.5 ms element-by-element appends at the top. Fork-join and checks are at most about 4%.
- **Free fork-join is still worth building, for `par`.** Rayon-style splitting by what is left needs cheap forks, a stolen bit, and thieves that take the oldest fork.
- **It is sound by construction.** `>t` already waits for the task to end, even after a cancel or a deadline. So running the task on the waiter's stack keeps the five loan rules, drop and defer order, and `Stop`. A task that parks parks the whole fiber, as the waiter would.

## The design, where the experts agree after review
1. **The record lives in the maker's frame** for a task whose `Task` stays there (a storage fact). `Header.destroy` becomes a no-op for it.
2. **An inline run, only when a stack bound is proven.** `sched.runHere`, tried before `handoff`, runs the awaited task on the waiter's stack when the site's proven depth (the `denseDepths` facts) fits the room left. A task with no proven bound keeps today's handoff. So SPEC's 64 MiB stays, and runtime.md's 128 MiB reservation is not needed.
3. **Only a single `>t`, or a task's drop, runs inline,** and only the task being waited for, never another taken from the deque, which could deadlock on a channel. Sets, `task.all`, select, and actor calls stay fibers. Inline is off under `RIG_SEED`, as handoff already is, so a seed chooses the same; `RIG_WORKERS=1` cases test it.
4. **A panic continues in place,** as an actor method run inline does today. No catch point: one would resume the waiter on frames that tasks it started may still view. Stderr keeps its "a task this one waited for panicked" line at each level.
5. **A cancel reaches an inline task** through a fiber bit and a link to its parent, not flags set along the inline chain, which race with the next fork reusing the frames.
6. **Forks go on a per-worker Chase-Lev deque:** the owner takes the newest, thieves the oldest, one at a time, as Rayon does. Woken fibers and heap tasks stay in the run-next slots and ring.
7. **The checkers record two facts:** the record's home, and each site's proven depth. The ownership checker and the oracle learn nothing. Emit reads the facts and decides nothing.

## For the owner
1. **SPEC §18 wording.** "A task is a fiber on a stack of its own" becomes "... when that stack has room", as SPEC already says for an actor's idle path. Nothing a program writes changes. Default: yes.
2. **Order of work, by measured share.** First, what closes the rows:
   - std.sort's inlined compare and the unstable path for plain values (in progress);
   - the first parallel call's start-up (trace it, then fix; the scheduler's lane after the loopback work);
   - a List append from a slice, which needs a name from you.
   Then free fork-join (items 1–7 above) with `par` splitting by what is left. Default: this order.
3. **A name for the List append from a slice**, the qsort harness's 2.5 ms. A sibling of the existing `extend_from_bytes`:
   - `!xs.extend(?ys[a..b])`
   - `!xs.push_all(?ys)`
   Default: `extend`.
4. **Bar:** a `bench/fork` row (psum, qsort like for like, and a tree sum) on the Mac and pup against Rayon. No other row slower: bench/tasks, actors, net, http, Trig. Default: yes.
