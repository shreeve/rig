# Concurrency panel, 2026-10-20

Six experts reviewed Rig's concurrency model as built, once all 18
points of docs/design/concurrency.md's plan had landed: the runtime and
scheduler, the language surface, adversarial soundness, testing,
formal methods, and I/O with std. Each report is at most 400 words,
with the probes it ran cited by name. The owner approved every default
below.

| Report | Expert |
|---|---|
| [1-runtime.md](1-runtime.md) | runtime and scheduler |
| [2-language.md](2-language.md) | language design |
| [3-adversarial.md](3-adversarial.md) | adversarial soundness |
| [4-testing.md](4-testing.md) | testing and regressions |
| [5-formal.md](5-formal.md) | formal methods |
| [6-io-std.md](6-io-std.md) | I/O and std |

## Decisions

**Soundness, and `file.write`**

1. A closure literal lent to a task is rejected, as a named `?f` is.
2. A task's result must move, unless the task is local.
3. `waitReady` looks at the cancel flag again after it begins its wait,
   and `canceledHere` loads it sequentially consistent.
4. `http.serve` answers `Expect: 100-continue`, retries accepting after
   running out of descriptors, limits bodies with a 413, and has
   timeouts.
5. `file.write(path, data)!` writes a file, making its parent
   directories as needed.

**The scheduler**

6. Yield checks service their worker's due timers and poller, and a new
   earliest timer wakes a sleeping worker.
7. The run-next slot can be stolen, filling it wakes an idle worker, and
   yield checks count every loop's turns.
8. An idle worker waits on every worker's poller. The blocking pool
   counts a thread busy when it dispatches a call, starts threads outside
   its lock, retires idle ones, takes `RIG_BLOCKING_THREADS`, and a
   cancel or deadline ends a pool call's wait.

**Guards against regressions**

9. A test checks that free tasks spread over cores (user time against
   wall time), compiler tests check `.spawn(` against `.spawnLocal(`, and
   a safe build panics when a pinned fiber resumes away from its home.
10. `RIG_SCHED_STATS=1` prints per-worker counts at exit, and a by-hand
    benchmark gate fails at 1.5x the last recorded row.

**Files and I/O**

11. `none` means only "nothing there"; any other failure is an error
    (`Stat?!`, `String?!`), and every call on the blocking pool is a
    fallible waiting point.
12. A first file layer: `write`, `append`, `rename`, `mkdir` (making
    parents), `remove`, `open`, `create`, with one `read`/`write` method
    shape for files, sockets, and HTTP bodies, and `io.copy`. DNS comes
    next; TLS and an HTTP client get a round of their own.

**The language**

13. Local tasks stay implicit; `rig check --tasks` lists each local task
    and what pins it.
14. `time.within` calls its closure exactly once, so it can move what it
    captures and a single task can be waited for with a deadline;
    `within:` and `wait_all` then go, and so does `task.both`.
15. Misleading messages are fixed, every message says "self" for `@`,
    and the earlier design reports carry a "superseded" note.

**Later**

16. `no_orphans` is restated over whoever holds a task's handle; the
    runtime is model-checked (TLA+, GenMC) before more hand proofs; a test
    keeps the Lean step table and the Zig constants in step.
17. A wait for a mailbox slot counts in deadlock detection, and debug and
    `rig test` builds report when every task waits and nothing can wake
    one.
18. Thread-sanitizer annotations for fibers, freeing a long-sleeping
    task's stack, and io_uring come later.
