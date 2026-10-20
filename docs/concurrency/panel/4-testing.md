# Panel 4: testing and regression

## Findings, most severe first

1. **Nothing checks where tasks run.** The cases check only their output.
   Seeded runs use one thread (src/sched.zig:1069). No `code` case checks the
   compiler's choice between `.spawn(` and `.spawnLocal(` (src/emit.zig:6853).
   One unit test, added by #405, checks the runtime's side (src/tasks.zig:2063).
2. **A parallelism check is cheap and reliable.** A probe's 8 CPU-bound tasks
   (`--release=fast`, `RIG_WORKERS=4`) used 4.0x as much user time as wall.
   The same work pinned by a `?*Node` argument, as in #401's slip, used
   1.0x. With all ten cores busy:
   3.3–3.6x against 0.8x.
3. **Seeded runs cannot find:** problems with memory ordering, wakeups lost
   between threads (sleepers, the Wait epoch), a fiber resumed before its
   registers are saved (`After`), poller wakes from another thread, the
   blocking pool (run in place), real deadlines, or starvation by a hog
   task.
4. **Nothing asserts that a pinned fiber resumes only on its `home`**
   (src/sched.zig:1180).
5. **TSan does not work with fibers yet.** Zig 0.17's `-fsanitize-thread`
   reported a planted race. On src/sched.zig's tests it reported nothing,
   but "local tasks…" crashed with SIGSEGV and "many workers…" ran past
   150 s. The likely cause is the missing
   `__tsan_switch_to_fiber` annotations; I did not rule out a real bug.
6. **Speed and flakiness are fine.** Each `concurrency-*` area takes 1.6–7
   s, and all 12 take about 55 s. 96 area runs found no flakes: 60 with
   default settings, 36 with `RIG_WORKERS` set to 64 or 2. None of the six
   scheduler unit tests covers stealing, timers, or the blocking pool.

## Decisions for the owner

1. Add a test/cli script: a fan-out built with `--release=fast` and run with
   `RIG_WORKERS=4`, which must use at least 2x as much user time as wall
   time. **Default: yes** (0.3 s).
2. Add `code` cases: a crossing argument emits `.spawn(`, and a `*T`
   argument emits `.spawnLocal(`. **Default: yes.**
3. Safe builds panic when a pinned fiber resumes away from `home`.
   **Default: yes.**
4. `RIG_SCHED_STATS=1` prints per-worker counts at exit (tasks run, steals,
   pinned, parks), so tests can check where work ran without timing it.
   **Default: yes, after 1–3.**
5. Add a by-hand `perf` step for changes to the scheduler or tasks. It runs
   `bench-tasks --time-only` for `rig-fast` and fails at over 1.5x the last
   PROGRESS.md row. **Default: yes, not in CI.**
6. Add TSan fiber annotations to `switchTo`; run the unit tests under it. **Default: later, as a separate PR.**
7. Run a nightly stress job with `RIG_WORKERS` set to 2 and to 64.
   **Default: no, until a flake appears.**
