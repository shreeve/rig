# Tasks over cores, against Tokio, Rayon, and Go (2026-11-04)

Step 1 of the concurrency plan the owner approved on 2026-11-04 (measure first). It adds `bench/tasks/bench-scale`, scaling benchmarks in all four runtimes, and a measurement of memory per task that counts page tables. The benchmarks and rules are in [bench/tasks/README.md](../../../../../bench/tasks/README.md) ("Scaling"), and the standing tables are in [bench/tasks/SCALING.md](../../../../../bench/tasks/SCALING.md).

## Runs

- [mac-2026-11-04.md](mac-2026-11-04.md): Apple M5, every worker count, with each row's counters.

## What they show

On the Mac:
- Rig spreads work over cores as well as Tokio, Rayon, and Go: 7.1 to 7.6 times at ten workers.
- Rig's CPU loop is 25 to 32% slower at every worker count: fewer instructions than Go, but about 27% more cycles. The yield check's countdown is on the loop's chain of dependent adds. The fix is the plan's strip-mining of counted loops (emit only).
- A split of `tree` costs about 2 µs at one worker, against Rayon's 10 ns, because every split gets a stack of its own. This is the plan's free fork-join behind `&`.
- Allocation is Rig's clear lead: twice the system allocator at one worker, and 4.4 times Tokio at ten workers, where macOS's malloc and Go's collector stop scaling.
- A sleeping task holds 32.7 KiB, of which 16.1 KiB is page tables (macOS `footprint`). `bench-tasks`'s `memory` column (16.6 KiB) counts only the stack's page. Tokio holds 267 B and Go 2.9 KiB.

## Not measured here

- The live stack at a park. It needs a counter in the scheduler, so it comes with NEEDS 72, after #952 settles.
- Syscalls on the Mac. `/usr/bin/time -l` gives none, and dtrace needs SIP off.
