# The `spread` wake's script under load (2026-11-15)

`test/cli/spawn_wake.sh` built a program, preempted by signal, that made
four tasks in turn and waited for them in order on four workers, 8
rounds, and required that in 5 or more rounds all four started within
300 µs of the moment the maker made the first. In core-suite runs on the
Mac it failed three times in a day ("in 3 of 8 rounds"); alone it passed.

## Method

Runs on the Mac (10 cores, other sessions' load 3 to 8), through
`tools/heavy`; load from CPU hogs (`sh -c 'while :; do :; done'` under
`nice` and `timeout`, killed by PID). Two programs, one run each per
line below:

- the script's program, printing each round's start times and
  `RIG_SCHED_STATS` (ReleaseSafe);
- a C program that does the same with no Rig: four threads, each asleep
  in its own kqueue; the maker computes 240 ms, kicks thread 1
  (`EVFILT_USER`, as `Poller.kick` does), and computes 60 ms; each woken
  thread kicks the next and computes 60 ms. A round passes when the
  third thread woke within 300 µs of the first kick.

## What delays the tasks

Rounds of 8 in which all started within 300 µs, 6 runs each:

| Load | C, kqueue wakes only | Rig |
|---|---|---|
| none added (load 7.4) | 8 8 7 5 8 8 | 8 8 8 8 8 8 |
| 10 hogs at nice 5 | 7 2 7 3 2 3 | 7 8 8 5 4 7 |
| 14 hogs at nice 20 | 4 5 2 2 3 2 | 8 6 8 8 7 8 |
| 10 hogs at nice 0 | 2 4 1 5 4 2 | 6 8 4 7 7 4 |

The C program, which has no scheduler of its own, misses 300 µs in most
rounds under load: a thread woken by a kick waits for the system to run
it, and each step of the chain of wakes waits again. In every Rig run,
loaded or not, the stats showed 24 steals (three a round: tasks 2 to 4
taken by woken workers) and no task preempted. A late round's starts
grow by a step each, as the chain of wakes does (`notify` from
`spread`, then each worker that finds work, the last searching, wakes
the next): 11, 483, 1,102, 1,679 µs, against 6, 20, 32, 42 µs in a
prompt round. The scheduler made each wake as it should; the system
ran the woken threads late. The bound was a timing property no
scheduler can promise on a loaded machine.

With `spread` removed (a `bin/rig` built with it returning at once),
the second to fourth tasks started 130 to 1,047 µs late, at the
monitor's look (two looks in a row with work queued, then the signal's
stop, whose `leftToIdle` wakes a worker): one round of 8 came within
300 µs by chance.

## Decision

`spread` is the same code in every build: `runFiber` and `handoff` call
it whether the program is preempted or not. In a release build the
only difference between the switch's wake and the monitor's is when it
comes, so no assert there can tell them apart without a bound on time.
A script that asserts only what holds under load (the other three
start before the first ends) passes even on one worker, where the
monitor's stops interleave them, so it checks preemption, which
`preempt_spin.sh` and `preempt_cover.sh` already do. The script is
removed, and the mechanism is a unit test in src/sched.zig, "tasks made
in turn and waited for in order start on the idle workers, woken as
their maker's worker switches to the first":

- four workers; the maker waits until the other three are listed asleep
  (`testSpinUntilOthersSleep`), makes four tasks, all in its "run next"
  slots (which no sleeper looks in, and whose filling wakes no worker),
  and waits for the first, which takes its worker by handoff;
- the first makes no yield check, as a task in a preempted build makes
  none, and computes until the other three have started, or 2 s pass:
  they can start only on other workers, and only once one is woken;
- asserts that the switch found work waiting and woke a worker for it
  (`test_spreads`, a count compiled only in tests), and that all three
  started while the first ran.

Under load the woken workers may start late; the 2 s bound is thousands
of times the milliseconds the system took above.

| Broken | Result |
|---|---|
| `spread` returns at once | fails: no switch woke a worker (`spreads >= 1`), 2.2 s |
| `spread` counts but never calls `notify` | fails: the three never start beside the first, 2.2 s |

`zig build test` passes in Debug, ReleaseSafe, and ReleaseFast. The test
alone, 20 runs in a row with 10 hogs at nice 0 (load 19): 20 of 20. No scheduler behavior
changed.

## The class

The scripts of test/cli that assert a bound on wall-clock time:

- `preempt_cover.sh`: a 20 ms sleeper beside a computation on one
  worker wakes within 25 ms, and a miss is run again. Under load, 1 of
  240 runs missed (66 ms; closure, divrem, and map, 40 runs each, with 10
  and 14 hogs at nice 0), so failing needs two misses in a row. Sound:
  the second run is the load allowance, and `PREEMPT_COVER_STRICT=1`,
  which takes none, is the quiet gate before a release.
- `preempt_reads.sh`: a 20 ms sleeper must wake within 2 s, and within
  100 ms beside two searches on one worker, where the bug it guards
  woke it in 30 ms to 15.8 s. Sound: 80 ms of slack.
- `sched_service.sh`: a 10 ms sleep or a socket round trip must take
  under half of a spin of 150 million turns on the busy worker. Sound:
  a ratio, and a loaded system slows the spin as much as the wake.
- `run_next_fair.sh` (2 s), `std_file_ops.sh` (5 s), `std_http.sh`
  (timeouts of 0.2 to 3 s), `blocking_cancel.sh` and `interrupt.sh`
  (deadlines on calls that never end), `big_source.sh` and `embed.sh`
  (15 to 45 s and 5 s for a check): bounds far above what they time.
- `resignal.sh`: under 3,000 signals in a second where the back-off
  allows about 1,000; load only lowers the count. Sound.
- `heavy_class.sh`, `mac_claim.sh`: lower bounds on a wait. Sound.
- `actor_restart_window.sh` runs under seeds already, whose virtual
  clock makes its window exact.

With 10 hogs at nice 0, `sched_service.sh`, `preempt_reads.sh`,
`run_next_fair.sh`, and `resignal.sh` each passed 5 runs of 5. Only
`spawn_wake.sh` asserted a bound that the system's scheduling of a
woken thread decides.
