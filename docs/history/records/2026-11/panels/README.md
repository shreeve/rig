# Panels of 2026-11-05: synthesis

The owner asked for three panels of three experts each. Each panel revisited one idea that showed a large gain overnight but was stopped by a specific problem. The reports are beside this file.

## Loop split: DROP, 3 of 3

- **The gain isn't the yield check** (codegen.md).
  - In fast mode, `+` and `*` carry LLVM's `nsw` flag, and with it LLVM lengthens the chain of steps in one arithmetic loop's `i*7`. The block form happens to keep that chain short.
  - Making only that loop's arithmetic wrapping, with the check kept on every turn, gives the same cycles as the split (712M against Rust's 707M; main is 874M).
- **Trig on the Mac with the split** (measure.md), 60 rounds at one checker with an A/A arm:
  - cycles 0.27-0.86% more on all six projects;
  - wall time 0.3-1.0% slower;
  - instructions at best 0.44% fewer.
  - It fails the bar on arm64 as on x86. The microbenchmarks still take 20% fewer cycles on the same builds.
- **Preemption replaces it** (preemption.md).
  - Under `RIG_PREEMPT=signal` there are no loop checks at all. Trig and loco make no local tasks, so with preemption on by default on Linux x86-64 release builds, no real program keeps a check.
  - The Mac port is feasible and honest: signals as on Linux, one reserved register for the trampoline (Go does the same with R27), no PAC issue. About 250-400 lines.
  - First step: a Mac ceiling of Trig with three arms (main, split, checks compiled out).
- **The archived split decides in emit** (`leavesEarly`), which breaks North Star 4.

## Exit handoff: DROP the handoff; MEASURE FIRST one probe

- **The handoff, in every form, is dishonest.** It gains only by moving CPU time and peak memory off the caller. mold's own manual says its fork "hides that latency".
- **Trig's exit has no user-space work left.** `os.exit` skips drops and joins (runtime.md). The exit is kernel page freeing, about 0.09-0.13 ms per resident MiB (os.md; critic.md refit).
- **tsrs exits faster** because 60% of its memory is on 2 MiB pages (os.md).
- **Parallel release at the end** gains little.
  - `munmap` serializes on `mmap_lock` (critic.md).
  - `MADV_DONTNEED` in parallel is estimated at 1.2-1.5 times faster.
  - Honest prize: ts-pattern 0.7-2.5%, zod3 1-3.5% at 4-8 checkers, and 0 at one thread.
  - Probe first on pup (vmabench, 20 rounds, perf lock contention). Drop it for good if it is under 1.8 times faster than a plain exit.
- **Trig-side wins** (critic.md), Trig's to decide:
  - **T1:** a checker sends its result before its drop, and main doesn't wait on drops. Trig's checker drop saved about 10 ms of exit, but main waiting on late drops ate most of it.
  - **T2:** free only the Tables.
  - **T3:** a heap census at four checkers, to shrink what is resident.

## Packed Tables: DROP, 3 of 3, coloring included

- **The page walks are an aliasing effect** (memory.md): 67% of misses land on page 0 of 2 MiB-aligned Table heads. This holds on E-cores only.
- **Coloring** removes the same walks at no cost.
  - It was measured on P-cores (60 and 20 rounds, A/A) and found level, and was parked on 2026-11-02 (critic.md).
  - Its verdict never reached the records.
- **On the race's P-cores**, Trig's whole walk excess over tsrs is at most 1.45 points on ts-pattern and 0.39 on zod3 (critic.md).
- **No read path without a test** exists for a shared-page layout (readpath.md). The cheapest costs 3 instructions per read on x86, and writes double. Moving a Table's storage is sound under CORE §5.
- **Where the P-core cost really is:** kernel cycles. Trig spends 351M against tsrs's 179M, about 4.7% of Trig's cycles. That is Trig's id density, and it can be measured without timing.

## Side leads

- **Fast mode's `nsw`** lengthens arithmetic chains in some loops. This is a Zig-ceiling question for numeric programs, with no evidence that it touches Trig.
- **The moving Table path** has thin test coverage. Run test/rig/table.rig.test under `RIG_TABLE_FALLBACK=1 RIG_SANITIZE=1`.
