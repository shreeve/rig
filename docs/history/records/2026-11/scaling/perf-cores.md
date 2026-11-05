# Workers that ask for performance cores (2026-11-04)

**Question.** Trig's NEEDS 75, from its concurrency panel of 2026-11-04
(change 8; the owner approved it that day): long-running workers should
ask for performance cores, on macOS by a thread QoS class
(`pthread_set_qos_class_self_np`, `QOS_CLASS_USER_INITIATED` or
`QOS_CLASS_USER_INTERACTIVE`), on hybrid x86 Linux by whatever is
honest. Which class keeps Trig's checkers on the performance cores of
the Mac, when there are more checkers than performance cores?

**Answer.** Neither moves anything measurable, so nothing is built. On
this Mac a worker at the default class already gets the performance
cores as often as one at user-initiated or user-interactive: the share
of CPU time on them, and the wall time, are the same within the noise at
one, four, six and ten checkers, with the machine as loaded as it is in
use and with eight more busy loops beside it. On pup's hybrid x86 there
is no per-thread request that does anything a pin would not (below).

## What a worker runs at today

A probe ([probe.zig](perf-cores-data/probe.zig)) prints the class of a
process's main thread and of a thread it starts, on macOS 27.0.1:

- a process started from a shell: main thread `0x21`
  (user-interactive), a new thread `0x15` (default);
- the same under `taskpolicy -c utility`: main `0x11` (utility), a new
  thread `0x15`, clamped to utility by the process's policy.

So Rig's worker 0, `main`'s thread, runs at user-interactive, and the
other workers at default. A class set on a thread cannot raise it past
a process's clamp, so a program started at utility or in the background
stays there whatever its workers ask.

## Measured on the Mac

The Mac: 4 performance cores (`hw.perflevel0`, "Super", 16 MiB L2) and
6 efficiency cores (`hw.perflevel1`, 6 MiB L2), 10 workers. The program
([checkers.rig](perf-cores-data/checkers.rig)) runs C checker tasks of
equal work: 1M puts into a `Map[Int, Int]` and a `List`, 1M lookups,
then 60M steps of arithmetic, about 205 ms each alone on a performance
core. Each worker but `main`'s took its class from `RIG_QOS` as its
first act ([qos.zig](perf-cores-data/qos.zig), the experiment's
`src/qos.zig`, one call in `sched.zig`'s `workerMain`). A wrapper
([pcore.zig](perf-cores-data/pcore.zig)) starts the program and reads
`proc_pid_rusage(RUSAGE_INFO_V6)` of the exited process before reaping
it: `ri_user_ptime + ri_system_ptime` over `ri_user_time +
ri_system_time` is the share of its CPU time on performance cores, with
no `sudo`. Arms interleaved, order rotated each round, at normal
priority (under `tools/low`'s `nice 19` the program would compete for
cores at a priority no real run has). The machine carried other
sessions' builds, load 6 to 7 ([ab.sh](perf-cores-data/ab.sh),
[ab.py](perf-cores-data/ab.py)).

15 rounds ([ab1.txt](perf-cores-data/ab1.txt)), wall in ms:

| C | default: fastest, median, P share | user-initiated | user-interactive |
|---:|---|---|---|
| 1 | 222, 230, 97.8% | 220, 227, 98.0% | 222, 230, 97.5% |
| 4 | 271, 281, 61.5% | 268, 283, 60.8% | 268, 280, 61.1% |
| 6 | 300, 313, 48.5% | 299, 321, 47.5% | 301, 312, 48.8% |
| 10 | 386, 415, 41.2% | 380, 417, 41.3% | 398, 417, 41.8% |

With eight `yes > /dev/null` loops at default running beside it, 6
rounds ([ab2.sh](perf-cores-data/ab2.sh), [ab2.txt](perf-cores-data/ab2.txt)):
at four checkers medians 297.5, 288.5 and 288.0 ms (P share 49%, 59%,
54%); at six 359, 363 and 364 ms (50% each). With five times the work,
about 1.2 s a run, 5 rounds ([checkers2.rig](perf-cores-data/checkers2.rig),
[ab3.txt](perf-cores-data/ab3.txt)): at four checkers medians 1,249,
1,243 and 1,247 ms (P share 77-78%); at six 1,393, 1,400 and 1,404 ms
(55-56%).

- **The classes above default change nothing.** Every difference is
  under the run-to-run spread, at every checker count, quiet or
  contended, short or long.
- **The scheduler shares the performance cores across threads.** At six
  checkers every checker's own span is within 4% of the others' (274 to
  285 ms in one run), where four on performance cores and two on
  efficiency cores would end far apart: macOS moves equal threads
  between the clusters so they progress alike, whatever their class.
  The wall is then the work over the cores' combined speed, which no
  class changes.
- **Even four checkers do not hold the four performance cores**: 61%
  of their time there with other work on the machine, 77-78% on the
  longer runs. The other sessions' threads share them, at the same
  class.
- **The measure sees placement when it moves.** The whole program under
  `taskpolicy -c utility` ([ab4.txt](perf-cores-data/ab4.txt), 5
  rounds): at six checkers 46% on performance cores against 56%, a
  median of 300 ms against 287; at four 70% against 78%. An early
  single run with only the workers at utility took 377 ms against 317,
  31% against 50%.

## Hybrid x86 Linux (pup)

pup is a Core Ultra 9 185H: `cpu_core` 0-11, `cpu_atom` 12-21. Its
`acpi_cppc/highest_perf` ranks the CPUs 64 (four), 60 (eight), 38 (the
eight E-cores) and 25 (the two low-power cores), and `cpu_capacity` is
1024 on every CPU. The kernel (7.0) packs busy threads toward the
highest-ranked idle CPUs (ITMT), so an unpinned checker already goes to
a P-core when one is free. What a thread could ask for itself:

- **An affinity mask of the P-cores** would override `taskset` and
  cpusets, which Trig's own benches set, and keep work off idle E-cores
  when there are more checkers than P-cores, which is slower.
- **`sched_setattr`'s `SCHED_FLAG_UTIL_CLAMP_MIN`** steers placement
  only where CPUs differ in capacity, which pup's do not report, and
  frequency only under the `schedutil` governor; pup runs
  `intel_pstate`, which reads neither.

So the honest thing on Linux is nothing. No placement run was made on
pup: Trig's release builds held its P-cores at the time, and the
kernel's ranking already does what a request would.

## What this leaves

- Rig sets no thread class and no mask; docs/internals/scheduler.md
  says so and why.
- A program that wants its threads at a class, or on given cores, has
  the process-wide tools: `taskpolicy` on macOS, `taskset` on Linux.
- What would keep a heavy checker off the efficiency cores is fewer
  checkers than performance cores, which is Trig's choice of C, or work
  split finer than one checker a core, as Trig's dynamic mode does.
