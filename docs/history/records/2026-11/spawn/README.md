# A task's maker keeps its worker while idle workers take what it makes (2026-11-06)

Research 29 #6 (Trig, docs/research/29-concurrency-panel-2026-11-04), approved by the owner on 2026-11-05: "a spawned task doesn't pre-empt its spawner", as Go's `go` behaves. The panel inferred it from the code: a task made by a running task goes in its maker's "run next" slot, and the maker's next yield check yields to it, so a serial loader that starts a parse for each file it finds is displaced by its own children. It fits the parse trial of 2026-10-25 (parse 30 to 39 ms at four checkers). Trig's parse in waves (research 29 #4) waits on it.

Machine: Apple M5 (4 P-cores, 6 E-cores), macOS 27.0.1. Rig main 9d73afdf1 against branch `spawn-keeps`.

## The problem, measured

A producer makes 200 tasks, each a loop of W steps, and runs the same loop itself between them (`data/producer.rig`, `data/producer.go`): its own finish time against its ideal (200 times one loop), the fastest of 20 rounds, at 4 workers.

| one loop | Rig main | Go |
|---|---|---|
| 9 µs | 2.28 ms against 1.83: 25% over | none over |
| 31 µs | 6.82 ms against 6.15: 11% over | none over |
| 92 µs | 19.4 ms against 18.4: 5% over | 0.3% over |

Each task made costs its maker 2-5 µs and two steals: the maker yields to the child at its next check, waits in its ring, and is stolen back by a worker woken for it.

## The rule

A yield check yields to work that waits for its worker only when no worker with nothing to do could take it (`sched.leftToIdle`): while a worker is asleep or looking, the maker's ring is empty and no pinned task waits, the work is left to that worker, which the check wakes, and the maker runs on.

- **When every worker is busy** the check yields as before, so a task waits behind a computing one no longer than it did.
- **Pinned work** (a local task's) only its worker may run, so the check yields to it.
- **An empty ring** is the condition that keeps a burst local. The `spawn` row (waves of 1,000 tasks that return their index, then a wait) checks once in each wave: left to idle workers, the trivial tasks spread over cores and their ends came back across threads, 65% slower. Run where they were made, under the condition, it is level.
- **The recursive check** (`claimWaiting`, gated by `waiting`) leaves work so too, and then sets `waiting` again. The fiber waits in a "run next" slot that no sleeper looks in, and only the flag keeps it in sight; without setting it again, a worker going to sleep as the check left it the fiber lost it (the unit test "a run-next fiber made as the other worker goes to sleep..." caught this). A notice of work already gone (a task made and handed its maker's worker at once sets the flag) ends there: woken for nothing, idle workers made `chain` 8.7% slower.
- **Under preemption** `preempted()` follows the same rule.
- **Locality stays.** A worker is woken only at the maker's next check, once the maker has kept running; two tasks that answer each other, or a task made and waited for at once, never reach one.

The rule covers woken work as well as made work: the same slot holds both. Rig's condition was that no bench/tasks or bench/actors row get slower, ping-pong rows included; none does (below).

## Results

**The producer** (4 workers, fastest of 20): 1.87 ms at 9 µs (2% over its ideal, from 25%), 6.17 ms at 31 µs (level), 18.6 ms at 92 µs (level). One steal per task made, the child.

**bench/tasks and bench/actors**, 40 alternating runs of main, an A/A copy, and the branch (`data/five6.csv`), against main's median:

| row | A/A | branch |
|---|---|---|
| spawn | 0.8% slower | 1.0% slower |
| chain | 0.7% slower | 1.3% faster |
| fanout | 3.9% slower | 0.6% slower |
| yield | 0.8% slower | 2.7% slower (first quartile 1.0% faster) |
| hog | 6.3% faster | 12.5% faster |
| produce | 0.5% faster | 8.7% faster |

bench/tasks' scale rows (15 rounds, cycles and instructions) are level, within 0.5% in instructions. bench/actors (30 rounds): `solo` level, `contend` 3-8% faster, `spread` within its A/A arm.

**The new `produce` row**, the producer at 31 µs on all 10 workers, in bench/tasks with Go, Tokio and Rayon twins (bench-tasks, best of 5): Rig 6.25 ms, Go 5.41, Tokio 5.43, Rayon 5.36. Rig is at its own ideal; the rest of the gap is its loop's speed (one loop takes Rig 30.6 µs and Go 26.8 µs), which the yield checks cost and signal preemption takes back.

## Waking at the check, not at the push (Rayon's rule)

Rayon, which tsrs runs on, leaves the spawner running too (rayon-core registry.rs `push` onto the local deque), but wakes a sleeping thread at the push, unless one is awake and idle (sleep/mod.rs `new_jobs`). Built as its own compiler, the same rule waking at the push in `wake` (unless a worker is looking) against waking at the check, 30 alternating rounds (`data/ww.csv`), against main's median:

| row | at the check | at the push |
|---|---|---|
| produce | 9.7% faster | 8.0% faster |
| chain | 1.0% faster | 77% slower |
| hog | level | 13.7% faster |
| solo, contend, spread | level, 3.1% faster, 4.7% slower | level, 3.6% faster, 3.5% slower |

Waking at the push wakes a worker for every task made, the 10,000 that `chain` makes and hands its own worker at once among them, each woken worker finding nothing. Rayon's tasks are made to be run elsewhere (`join`, `scope`), and it has no handoff. Waking at the check wakes one only for work still waiting after its maker ran on, so it keeps both. `hog`, the noisiest row (its A/A arm swings up to 36% at the fastest), is the one row waking at the push read better.

## Trig

Trig (origin/main 49ffa44, the release pack) built by main's Rig and by the branch's, against an A/A copy of main's; the six projects at one checker and at four, 20 interleaved rounds each (`data/tr1.csv`, `data/tr4.csv`). Spotlight's indexer held about three cores through it (load average 8 to 14), which the A/A arm shows.

- **Instructions:** within 0.4% of main on every project at both counts (the A/A arm's within 0.3%).
- **Paired cycles:** 1.6% fewer to 1.4% more against main, the A/A arm 0.3% fewer to 1.7% more. Paired wall time the same: within the A/A arm's spread.
- **Output:** one digest per project across the three arms in all 720 runs; peak memory level.

Level, as the panel expected: Trig's checker makes its few tasks at once and waits for them, never between work of its own. The rule is for the shape Trig's parse in waves (research 29 #4) will have.

## Gates (the Mac)

Core suite 11,529 jobs green; emit-diff, only `rig/sched.zig` differs (in the 32 programs that make tasks); loco's light gate GREEN (47 s); Trig's light gate GREEN (Trig c040e92, 0 died); guards: json 0.0-0.2% more instructions, hash and text level or fewer, check 0.3% over its baseline.

## Tests

- Three unit tests of the decision (src/sched.zig), each judged by which worker runs what: with an idle worker the maker never moves and its child runs on the other worker; with every other worker busy the maker yields and the child runs on its worker; with a local child the maker yields though a worker is idle. Seeded runs take another path (`deterministic`), so these are the rule's tests.
- The lost-wakeup tests of the "run next" slot pass, run repeatedly.

## Data

`data/`: `producer.rig`, `producer.go` (the producer, W = 30,000 steps; the others were made from them), `spawnrow.rig` (the spawn row alone), `time-rows.py` (alternating runs), `five6.csv` (the 40 rounds), `ww.csv` (check against push, 30 rounds; arms base, check, push), `tr1.csv` and `tr4.csv` (Trig; arms base, baseA, spawn).
