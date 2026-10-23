# The scheduler's sleep handshake (#581)

2026-10-23, consolidation track 2. The backlog's two scheduler items:
the `relook` gap formal/README recorded, and the idle worker that once
missed a run-next fiber for 2 seconds on pup.

## (a) The relook gap: closed in the code since the model was written

formal/README described work made into the global queue that waits
while a worker sleeps, closed in the model only by `relook`, "which
`src/sched.zig` does not have". It does: `sleep` has taken that step
since 21a97bb7b (2026-10-20 15:42), 80 minutes after the model landed
(7f1d93f51, 14:05). After a worker lists itself in `sleepers`, if no
worker searches and `hasWork` finds the global queue or a ring
non-empty, it takes itself off the list and counts itself as searching
(`w.searching = true`, `searching += 1`); `loop` then takes the work
while counted, and the `fetchSub` that returns 1 calls `notify`. That is
the model's `.remove` then `.recount` (Sleep.lean), and the checks with
`relook` pass (2 workers with 2 pieces, 3 workers with 1 asleep, and
Deep's 2 workers making work every way at once).

Interleavings checked by reading, all orders `.seq_cst` as the model
assumes:

1. The README's trace. Worker 0 searches and finds nothing; worker 1
   sees it searching and sleeps without a last look; two pieces arrive
   and `notifyNew` sees worker 0 searching. Worker 0 stops searching;
   its last look sees `searching == 0` and the global queue non-empty,
   so it counts itself searching, takes one piece in `next`, and its
   `fetchSub` returns 1: `notify` pops worker 1 and kicks it.
2. A waker pops the worker between its listing and its last look:
   `sleepers.remove` fails, so it waits for the kick (`waitWoken`) and
   comes back counted as searching by that waker, never twice.
3. The last look is skipped because another worker searches: that
   searcher reads the global queue after the rings, or stops and sleeps
   itself, and the last worker to stop searching makes the look with
   `searching == 0`. This chain is what the model checks.
4. A thread outside pushes to the global queue after the worker's look.
   The worker listed itself (`sleepers.count += 1`) before it read
   `global.count`; the pusher adds to `global.count` before it reads
   `searching` and `sleepers.count` (`notifyNew`). One of the two sees
   the other: the worker relooks, or `notify` pops and kicks it.
5. The relook finds nothing (another worker took the work): `loop`
   counts it out of `searching` and it sleeps again; `searching` stays
   exact.

So no worker sleeps while work sits in the global queue or a ring.
The fix here is to formal/README and the model's comments.

## (b) The 2-second miss: the old `next_quiet` rule's test

The test that failed, "a fiber left in a busy worker's run-next slot is
taken by an idle worker", is gone: #541 (a5ddfa91e, 2026-10-22)
removed `next_quiet`, made filling a slot wake no worker, and rewrote
the test as "a task made while its maker computes runs beside it, from
the maker's next yield check". The failure (backlog entry b324d592c,
2026-10-21) was on the old code, where a slot fill woke a sleeper
through `notifyNew` unless `next_quiet` was set, and the test's maker
computed with no yield check, so nothing else could hand the fiber on.

Reproduced on b324d592c, debug, pup, `taskset -c 12-19`, the test alone
(a filter on `addTest`, not committed), with a probe printing the state
at each miss:

| Load on 12-19 | Runs | Failures |
|---|---|---|
| 8 busy loops, 4 test streams | 20,000 | 43 |
| 16 busy loops, 8 test streams | 20,000 | 42 |
| 8 busy loops, 4 streams, fuller probe | 10,000 | 30 |
| no busy loops, 4 streams, fuller probe | 20,000 | 1,451 |

In every one of the 1,481 probed failures the fill woke no one: in
1,452 a worker was searching as the maker filled its slot (`searching`
1, `sleepers` 0 just before the spawn), so `notifyNew` left it to that
worker, and in the other 29 `next_quiet` was already set. The nap that
begins the test ends with a timer wake into a slot, which wakes the
other worker; that worker's search either found the slot emptied by its
owner first, setting `next_quiet` (1,444 of the 1,481), or had passed
the slot before the fill (37), and either way it then slept: its last
look reads the global queue and the rings, not the slots. In 9 of the
misses it had also cleared `waiting` as it slept, which is the race
below.

So the miss was not the relook gap, nor load alone: the run-next slot
was outside the sleep handshake. #541 dissolved the old form (no fill
wakes a sleeper, and the maker's yield checks hand the fiber on), but
one path of that remained.

## The race on main: a sleeping worker cleared the slot's notice

On main, a fiber that fills its slot and runs on wakes no worker and
sets `waiting`. A loop's check sees the slot itself (`hasOwnWork`), but
a recursive check reads only `waiting`. `sleep` cleared `waiting`
unconditionally, and its last look does not read the slots. So:

1. Worker 1 searches, passes worker 0's slot (empty), finds nothing.
2. On worker 0, fiber `g` makes task `f`: `f` fills the slot, `waiting`
   is set.
3. Worker 1 goes to sleep and clears `waiting`; its last look sees no
   global or ring work.
4. `g` computes in recursion: every call reads `waiting`, which is 0.
   `f` waits, with worker 1 asleep, until `g` makes a loop check or
   ends (then `>t` runs it by handoff).

That is fork-join `t = f()&; g(); >t` with a recursive `g`, run
serially whenever the other worker was between its search and its sleep
at the spawn.

The test "a run-next fiber made as the other worker goes to sleep is
handed on at its maker's next recursive check" makes it happen: each of
up to 4,000 rounds has the other worker run a task that ends at once,
then makes a task a little later each round (0 to 7.9 us), and computes
as recursion does for up to 50 ms. On main it fails every run: on the
Mac 5 of 5 (first miss at round 9 to 195), on pup 10 of 10. At each
miss the probe showed the maker's slot full, `waiting` 0, the other
worker asleep (`idle` 1, listed), and no worker searching.

### The fix

`clearWaiting`, as a worker goes to sleep: clear `waiting`, then read
every worker's slot, and set `waiting` again if one holds a fiber.
`wake` fills the slot, then reads `waiting` (now `.seq_cst`, was
`.monotonic`) and sets it if 0. With the store, the slot reads, the
swap, and that load all sequentially consistent: if the sleeper's read
of the maker's slot comes before the fill in the total order, its clear
comes before the maker's load, which reads 0 or later and sets the
flag; otherwise the sleeper sees the fiber and sets it back. A slot
whose fiber its owner then takes leaves the flag set; the next check to
see it finds nothing and clears it, as a stale flag always did.

A sleeper does not take the slot's fiber itself (a last look at the
slots, then a relook, would also close it): the slot is for the maker,
so two tasks that answer each other stay on one worker (#541), and a
worker's fiber waits at most until its maker's next check, loop or
recursive.

With the fix the new test passes 30 of 30 on the Mac and every run on
pup (below).

## Under load on pup's E-cores

Debug builds, `taskset -c 12-19`, 8 busy loops beside 4 test streams:

| Build | Tests | Runs | Failures |
|---|---|---|---|
| main + the new test | the new test | 200 | 71 |
| the fix | the new test and main's two slot tests | 1,000 | 0 |
| main | main's two slot tests ("runs beside it", "recursive check") | 2,000 | 0 |

Unloaded, main fails the new test every run (10 of 10 on pup, 5 of 5
on the Mac); load spreads the timing, so 36% of loaded runs miss.

## Gates

- `swarm test/rig.rip all` on the Mac: 9,818 jobs, green.
- pup `zig build test`: debug 252 of 253 pass (1 skipped), safe 251
  (2 skipped), fast 249 (4 skipped), none failed.
- formal/: comments only; `lake build` not run.
- Trig's light gate: not run, by the round's instruction; due before
  the merge, as for any runtime change.

## Benchmarks

Main and the fix interleaved (order alternating), fastest of N, each
bench script's own run, load, and memory functions
(a small driver, not kept). pup: the whole
driver under `taskset -c 8,9`, one P-core's two hyperthreads, as the
#541 and #552 rows were.

pup, tasks and actors 20 runs, net 10, http 8:

| | main | fix | |
|---|---|---|---|
| spawn | 61.3 ns | 63.3 ns | 3.2% slower |
| chain | 86 ns | 86 ns | 0.1% faster |
| fanout | 310.8 ms | 310.3 ms | 0.1% faster |
| yield | 22.6 ns | 22.7 ns | 0.4% slower |
| hog | 130.79 us | 130.86 us | 0.1% slower |
| actors solo / contend / spread | 11.55 / 14.49 / 10.51 ns | 11.30 / 14.21 / 10.39 ns | 2.2%, 1.9%, 1.1% faster |
| pingpong | 4.86 us | 4.93 us | 1.5% slower |
| echo | 3.81 us | 3.80 us | 0.4% faster |
| connect | 28.09 us | 28.06 us | 0.1% faster |
| http req/s | 197,925 | 196,492 | 0.7% fewer |
| http p50 / p99 | 195 / 3,482 us | 202 / 3,445 us | |

spawn is the one cell beyond 2%. It is noise: `wake` takes the changed
load only when the slot was empty, which `spawn`'s adds, each pushing
the last task out to the ring, almost never reach. A second set of 30
runs with a copy of main's own binary as a third and fourth variant
gave main 0.0%, the fix 0.5% slower, the fix with the old `.monotonic`
load 3.3% slower, and the identical copy of main 2.6% slower. An
earlier set of 30, with a `sleep` that never clears `waiting` as a third
variant, gave the fix 2.1% and that variant 1.7% slower. A second
http set (12 runs): 0.4% fewer requests, p50 1.6% faster. A second net
set (16): pingpong 1.2% slower, echo 0.2% faster, connect 1.6% slower.

The Mac, under other sessions' load (1-minute load 4 to 10 for every
set, up to 17 by the end), so its numbers are noisy. tasks 40 runs,
actors 30, net 12, http 10 (the rows in each PROGRESS.md):

| | main | fix | |
|---|---|---|---|
| spawn | 75.7 ns | 79.5 ns | 5.0% slower |
| chain | 44 ns | 44 ns | 0.3% slower |
| fanout | 77.0 ms | 76.4 ms | 0.7% faster |
| yield | 5.16 ns | 5.07 ns | 1.9% faster |
| hog | 69.06 us | 53.21 us | 23.0% faster |
| actors solo / contend / spread | 5.0 / 40 / 0.96 ns | 5.0 / 40 / 0.85 ns | 0.3% faster, 0.5% slower, 11.0% faster |
| pingpong | 13.55 us | 13.55 us | 0.0% |
| echo | 5.89 us | 5.93 us | 0.6% slower |
| connect | 48.89 us | 49.56 us | 1.4% slower |
| http req/s | 180,389 | 181,146 | 0.4% more |
| http p50 / p99 | 322 / 1,248 us | 295 / 1,797 us | |

Beyond 2% slower: spawn and http's p99. Both are noise here:

- spawn: a first set of 20 had it 6.6% slower; a control set of 40
  with an identical copy of main's binary and the fix with the old
  `.monotonic` load as more variants gave the fix 6.9% faster, the copy
  1.4% slower, and the old-load build 44.6% faster (Mac spawn is
  bimodal, about 79 or 143 ns, as align.md found). The same set had
  hog 22.6% faster for the identical copy and yield 10.9% slower for
  the fix and 5.2% faster for the old-load build.
- http p99: the bench reports the p99 of the run with the most
  requests, one sample of a tail. Over 12 interleaved runs of each,
  main's p99 was 691 us at best and 987 at the median, the fix's 616
  and 848; requests 177,045 and 178,956 at best.

Nothing measured on either machine moves by more than its noise.
