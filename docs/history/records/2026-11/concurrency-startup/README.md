# The first parallel call: where 0.44 ms goes

Mac M5 (10 cores), `startup-trace` at 7fbe29a04 (main after #1103), `--release`,
each arm a fresh process, arms rotated, 15 rounds (20 on board 5), under
`tools/mac-claim`; traces 12 to 25 runs, medians.
Rows are fastest / median in ms. The program is psum from
[concurrency-fork-join](../concurrency-fork-join/measurement.md): 2^25 Ints
summed by halves down to 8,192, the left half on a task, timed three times in
a row. Measurement only: every probe lived in a scratch copy of the runtime,
never committed.

## The answer

The first call pays for **virtual-memory work done while ten threads are
busy**: the workers' threads start and each maps its first task stacks at
the moment the work spreads, and macOS serializes those calls on the
process's one VM map. Each costs about 7 µs alone and about 160 µs in the
ramp. Done before the call, the same work costs the call nothing: with the
workers started and one batch of 16 stacks mapped (not touched) per worker
before psum, the first call is 2.015 ms against a warm 1.988, 0.03 ms over,
where Rayon's first call is 0.12 over.

| cause (10 workers) | µs on the first call | evidence |
|---|---:|---|
| `main` blocked starting the workers (9 `pthread_create`, 9 kqueues, the monitor) | ~100 | `main` spends 96-99 µs in `startWorkers` (trace); `main` starting one worker that starts the rest saves 135 (board 5) |
| fresh stack reservations made during the ramp | 150-330 | 12 reservations of 16 stacks in the first call, median 164 µs each against 22 warm (trace); mapping each worker's first 16 before it spawns saves 154 (board 5), and 330 once the threads are already up (eager against eager + map 16, board 3) |
| work that spreads late, to threads still starting | ~170 | workers enter 40-230 µs after the first `&` and run their first fiber at a median 167-203 µs (84 with the threads up early); what lazy start keeps after both fixes above (0.205 against 0.04) |
| everything else: first touches of ~170 stacks, the workers' heaps (9 segment maps, 8 µs each), cold code | 30-40 | the residual of the best arm |
| **total** | **425-456** | cold 2.403-2.438 against warm 1.977-1.996 (boards 1-5) |

The causes overlap (a reservation is slow because threads start beside it),
so the shares are each fix's measured gain, not a partition.

The first touches are not the cost: touching 16 stacks per worker as well as
mapping them gains nothing more (2.015 against 2.020). One worker shows the
same cost without any thread start: `RIG_WORKERS=1` pays 0.43-0.48 ms on its
first call for 91 fresh stacks in 6 reservations (about 4.4 µs a stack, the
reservation's share, its mprotect, a page-table page and a zero-fill fault).

## Why so many stacks, and why they cost so much in the ramp

psum's first call touches about 170 fresh stacks at 10 workers (171 page
faults in the call, against 24 in a warm one) and 91 at one: forks waiting
in the ring start before their makers finish, each on a stack of its own,
and nested waits keep about a dozen alive per chain. A warm call reuses the
32 free stacks each worker keeps.

A Zig ceiling (`ceil/contend.zig`) times one reservation, an `mmap` of 16
stacks with 16 `mprotect`s, as `sched.takeStack` makes it:

| | alone | 9 other threads spinning | 10 threads at once, each mapping 16 and touching them |
|---|---:|---:|---:|
| mmap none + 16 mprotect rw (Rig's) | 7.0 µs | 17.4 µs | 395 µs |
| mmap rw + 16 mprotect guard none | 7.0 | 14.1 | 338 |
| mmap none + 16 mmap FIXED rw | 10.2 | 20.3 | 409 |

Each call takes the VM map's lock to write, and every running thread of the
process is a core to shoot down, so ten threads mapping at once wait on one
another. No layout of the reservation escapes it; only the timing does. The
other micro-costs (`ceil/costs.zig`): a thread spawn 7 µs on its creator (63
for nine, the last running 70 µs after the first spawn), a kqueue 0.15, an
alternate signal stack 0.4-0.5, a stack page's first touch 2.0-2.3.

## Boards

Board 1, the runtime as built (`rig-base`) against Rayon 1.12:

| arm | psum1 | psum2 | psum3 |
|---|---|---|---|
| rig cold | 2.438 / 2.472 | 2.004 / 2.025 | 1.996 / 2.018 |
| rig pre (a task made and waited for at `main`'s start) | 2.353 / 2.405 | 2.003 / 2.021 | 1.988 / 2.016 |
| rig gap (psum3 after 100 ms asleep) | 2.433 / 2.494 | 2.011 / 2.038 | 2.284 / 2.990 |
| rayon cold | 2.053 / 2.116 | 1.941 / 1.982 | 1.938 / 1.961 |
| rayon pre | 2.004 / 2.063 | 1.953 / 2.000 | 1.931 / 1.972 |
| rayon gap | 2.063 / 2.135 | 1.956 / 2.018 | 2.054 / 2.854 |
| rig, 1 worker, cold | 5.540 / 5.653 | 5.118 / 5.259 | 5.062 / 5.208 |
| rig, 1 worker, pre | 5.421 / 5.551 | 5.045 / 5.166 | 5.043 / 5.167 |
| rayon, 1 thread, cold | 3.540 / 3.562 | 3.463 / 3.513 | 3.479 / 3.508 |

Boards 2-5, the scratch runtime's prototypes (`rig-inst`, knobs read from the
environment; the trace off), psum1 against the same run's psum3:

| arm | what it does | psum1 | first-call excess |
|---|---|---|---:|
| cold | as built | 2.433 / 2.462 | 0.456 |
| tree | `main` starts worker 1, which starts the rest and the monitor | 2.268 / 2.343 (board 5) | 0.28 |
| mapall | `startWorkers` maps each worker's first 16 stacks before it spawns | 2.249 / 2.305 (board 5) | 0.26 |
| tree + mapall | worker 1 maps the others' first stacks, then starts them | 2.189 / 2.235 (board 5) | 0.21 |
| prefault 4 / 16 at thread start | each worker maps and touches 4 or 16 stacks as it starts, lazily | 2.338 / 2.382 | 0.35-0.40 |
| eager | workers start as `main` starts | 2.326 / 2.356 | 0.35 |
| eager + map 16 (no touch) | and each maps 16 stacks as it starts | 2.020 / 2.039 | 0.04 |
| eager + prefault 4 / 8 / 16 / 32 | and touches 4 to 32 of them | 2.015-2.041 | 0.03-0.06 |
| rayon cold | | 2.054 / 2.081 | 0.13 |

Excess is psum1's fastest less psum3's in the same board. Board 4 ran about
3% slower throughout (warm 2.04-2.08), so board 5 (20 rounds: cold, tree,
mapall, tree + mapall, eager + map 16, Rayon) repeats its lazy arms; there
cold is 2.403 / 2.481, eager + map 16 2.011 / 2.027, Rayon 2.050 / 2.097
against its warm 1.934.

## The gap after idle (not the question, but larger)

psum3 after 100 ms asleep costs 0.29 ms at best and 0.97 at the median over
a warm call; Rayon pays 0.11 and 0.89. It is not memory: the call faults no
more than a warm one (23 against 24) and maps one reservation at most. It is
waking: the median worker runs its first fiber 125 µs into the call (36
warm), the last 297 (68 warm), as idle cores wake one by one, each woken
worker waking the next when it finds work (`notify`). Both runtimes pay it;
Rig pays 0.1 to 0.2 ms more. See fix 4.

## Fixes, ranked by measured share

1. **Start the workers before the first parallel call, and have each map
   (not touch) its first 16 stacks as it starts.** Measured: the first call
   goes from 0.43 to 0.04 ms over warm (gain 0.39 fastest, 0.45 median),
   ahead of Rayon's 0.12; about 0.40 of psum's 0.44 ms gap to Rayon closes.
   Costs: no resident memory for the stacks (address space only, 16 × 80
   MiB a worker, which the first call maps today anyway); the threads'
   start-up (9 spawns, 9 kqueues, the monitor, about 0.1 ms of CPU) moves to
   program start, off `main`'s path if worker 1 starts the rest; each
   worker's thread stack and heap as today. **It changes documented
   behavior**: scheduler.md says "a program that makes none starts no
   workers", and `task.workers(n)` takes effect "before its first task".
   The owner's call among:
   - a. start at `main`'s start only in a program that can make a task, a
     fact the compiler records (an `&`, an actor, `par`, or a std call that
     spawns, reachable from `main`); a program that cannot starts none, as
     now. One whose `&` never runs pays about 0.1 ms and nine sleeping
     threads for nothing.
   - b. start when `main` calls `task.workers(n)`, which today only records
     `n`: opt-in, a doc change to std.task only.
   - c. nothing in the runtime: a program makes a task before its parallel
     part, as `pre` and `tiny` do by hand (0.07-0.18 saved, not 0.39,
     since the stacks are still mapped in the ramp).
2. **Keep the lazy start, but make it cheap: `main` starts worker 1, which
   maps every worker's first 16 stacks and then starts the others and the
   monitor.** Measured: 0.21 fastest, 0.25 median (board 5: 2.189 / 2.235
   against cold 2.403 / 2.481); each half alone gives 0.14-0.18. No
   behavior change; no memory; a few dozen lines in `startWorkers` and
   `workerMain`. What it leaves (0.2 ms) is work spreading to threads that
   do not yet exist, which only an earlier start removes. The one to build
   if fix 1 waits for the owner, and a part of fix 1 in any case (worker 1
   starting the rest keeps the start off `main`'s path).
3. **Fewer stacks: free fork-join** ([runtime.md](../concurrency-fork-join/runtime.md),
   item 2, a fork run on its waiter's stack). It cuts the fresh stacks a
   call needs from about 170 toward the stolen forks (45-79 a call), so
   fewer reservations land in the ramp. Not measured: the design is not
   built. Expected under the lazy start: part of what fix 2's mapping
   already removes; nothing further under fix 1. Its case rests on warm
   forks and memory, not on this.
4. **The gap after idle**: a woken worker that finds a ring with several
   tasks wakes two more rather than one, so idle cores wake in a tree, not a
   chain. Bound: at most the 0.1-0.2 ms Rig pays over Rayon there; the rest
   is the cores waking. Not prototyped; it changes the sleep protocol
   checked in formal/Models/Sleep.lean.

Pre-faulting (touching) stacks is not needed: mapping is the cost, the
touches are not, so fix 1 holds no extra memory. Larger reservations do not
help either: every layout serializes alike (the ceiling's table).

## Linux runs wanted (pup)

The VM-lock serialization is a macOS finding; Linux's `mmap_lock` (and
per-VMA locks since 6.4) behaves differently, so the shares may move.
1. Board 1 on pup, P-cores (taskset 0,6,8,10 and the full 22), base runtime
   against Rayon: cold, pre, gap, one worker.
2. Boards 3 and 5 (eager, eager + map 16, tree, mapall, tree + mapall)
   with the scratch runtime built for x86-64 Linux, on a P-core set.
3. `ceil/contend.zig` and `ceil/costs.zig` on pup: one reservation alone,
   beside 9 spinning threads, and 10 at once.
4. One traced run set (`traces.sh 25`) for the fault counts and the
   reservation times per call.

## Fix 2, built

`startup-tree`: at the first task `main` starts worker 1 alone, which maps
a first reservation of 16 stacks (untouched) for itself and each worker
after it, then starts them and the monitor (`sched.startRest`); `main`'s
end waits for that before it stops the monitor and joins the threads
(`waitStarting`). Worker 0's stacks are left to `main`, as before: a
mapping in `startWorkers` put `posix.mmap`, whose safe-mode errno path
writes a stack trace through a pointer, on every task's path to its first
spawn, and the stack census (test/cli/stack_census.sh) then gave a
recursive task that reason in place of its cycle of calls. A reservation
the system refuses is left for `takeStack`, as a unit test checks.

Mac M5, `--release`, against main at ea3704772 built the same way, with an
A/A arm (a copy of main's binary), every arm a fresh process, arms rotated,
20 rounds each, one `tools/mac-claim` a board (`board6.py`, binaries by
`build6.sh`). Fastest / median, ms:

| arm | psum1 | psum3 | psum1 against main's, by medians |
|---|---|---|---|
| main cold | 2.438 / 2.486 | 1.987 / 2.016 | |
| A/A cold | 2.433 / 2.464 | 1.978 / 2.011 | 0.9% faster |
| fix cold | **2.205 / 2.230** | 1.983 / 2.007 | **10.3% faster** |
| main pre | 2.341 / 2.387 | 1.990 / 2.014 | |
| A/A pre | 2.354 / 2.379 | 1.986 / 2.002 | 0.3% faster |
| fix pre | 2.064 / 2.098 | 1.978 / 2.007 | 12.1% faster |
| main gap | 2.414 / 2.479 | 2.288 / 2.858 | |
| A/A gap | 2.432 / 2.457 | 2.367 / 2.865 | 0.9% faster (psum3 0.3% slower) |
| fix gap | 2.203 / 2.234 | 2.309 / 2.853 | 9.9% faster (psum3 0.2% faster) |
| main, 1 worker, cold / pre | 5.523 / 5.654, 5.562 / 5.711 | | |
| A/A, 1 worker | 5.562 / 5.668, 5.551 / 5.684 | | 0.2% slower, 0.5% faster |
| fix, 1 worker | 5.540 / 5.679, 5.576 / 5.661 | | 0.4% slower, 0.9% faster |
| Rayon cold / pre / gap | 2.056 / 2.136, 1.995 / 2.039, 2.074 / 2.139 | 1.936 / 2.024 | |

The first call gains 0.233 ms fastest and 0.256 median (the prototype,
`TREE` + `MAPALL`, 0.21 and 0.25), and its excess over a warm call falls
from 0.451 to 0.222 ms, where Rayon's is 0.120: about half of psum's gap
to Rayon closes. psum2, psum3, the gap's psum3 and one worker are within
the A/A's spread (full rows in `board6-startup.txt`).

The benchmarks, medians of 20 against main's, with the A/A beside:

| row | fix | A/A |
|---|---|---|
| tasks spawn (the first row, so it pays the start; it swings on the Mac, so medians) | 10.8% faster | 2.1% faster |
| tasks chain | 3.7% faster | 8.6% faster |
| tasks fanout | 0.3% slower | 0.9% slower |
| tasks yield | 0.9% faster | 1.3% slower |
| tasks hog | 1.8% faster | 2.8% faster |
| tasks produce | 0.3% faster | 0.0% |
| tasks memory (bytes a live task) | the same (17,010 against 17,014) | the same |
| actors solo | 0.7% slower | 0.5% slower |
| actors contend | 5.9% faster | 1.8% slower |
| actors spread | 1.0% slower | 0.5% faster |
| net pingpong | 0.8% faster | 0.1% slower |
| net echo | 0.6% faster | 0.2% slower |
| net connect | 0.7% slower | 3.5% slower |

No row is slower beyond the A/A's spread. Raw rows: `board6-tasks.txt`,
`board6-actors.txt`, `board6-net.txt`, and the `.json` beside each.

### Linux runs wanted (pup)

Not run: nothing here ran on pup or burst. On pup, in a slot
(`tools/pup-slot open NN 20 ab startup-tree`), from a Rig checkout at the
fix, binaries on /zfs, every timed command pinned:

```sh
# The two compilers, each in its own folder (from a Trig checkout).
tools/pup-rig ea3704772          # main: PUP_RIG=/zfs/trig-pup/rig-ea37047.../bin/rig
tools/pup-rig FIX_SHA            # the fix
M=docs/history/records/2026-11/concurrency-startup/measurement
O=/zfs/trig-pup/startup6
(cd $M/rayon && cargo build --release --target-dir $O/cargo)
$M/build6.sh /zfs/trig-pup/rig-MAIN/bin/rig /zfs/trig-pup/rig-FIX/bin/rig $O/cargo/release/startup $O
# One board a slot.
BIN=$O taskset -c 0-11 python3 $M/board6.py startup 20 $O/board6-startup-pup.json
BIN=$O taskset -c 0-11 python3 $M/board6.py tasks 20 $O/board6-tasks-pup.json
BIN=$O taskset -c 0-11 python3 $M/board6.py actors 20 $O/board6-actors-pup.json
BIN=$O taskset -c 0-11 python3 $M/board6.py net 20 $O/board6-net-pup.json
```

`taskset -c 0-11` is pup's six P-cores with their SMT siblings, so each
runtime sizes its pool to the 12 CPUs the mask allows (`RIG_WORKERS` and
`RAYON_NUM_THREADS` unset). Linux maps under
`mmap_lock` (per-VMA locks since 6.4), so the gain there may differ; the
change is still behavior-neutral.

## Files

In `measurement/`: `startup.rig` (psum by mode: cold, pre, tiny, gap,
mark, markgap), the Rayon twin `rayon/` (`src/main.rs`, `Cargo.toml`),
`board.py` (BOARD=1 to 4, ARMS= to pick; board 5 is board 4's lazy
arms), `traces.sh`, `traces-gap.sh`, `traces-arms.sh`, `analyze.py`,
`ceil/costs.zig` and `ceil/contend.zig` (their output in `ceiling.txt`),
the boards' output (`board1.txt` to `board5.txt`, with the raw times in
the `.json` files), the trace summaries
(`trace10.txt`, `trace1.txt`, `tracegap.txt`), and `trace.patch`, the
scratch runtime's changes to `src/sched.zig` and `src/alloc.zig`: a
per-worker event buffer, timestamps by `clock_gettime_nsec_np`, fault counts
by `getrusage`, and the `RIG_X_*` knobs (`EAGER`, `PREFAULT=K`, `NOTOUCH`,
`TREE`, `MAPALL`); and for the built fix, `board6.py` (SET startup,
tasks, actors or net, against main with an A/A arm), `build6.sh`, and
their output, `board6-*.txt` and `board6-*.json`.
