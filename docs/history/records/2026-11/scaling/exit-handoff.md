# The exit handoff: a parent that exits while its child tears down (2026-11-04)

**Question.** Fix 2 of [investigation.md](investigation.md): Trig's
exit is the kernel tearing down its memory, 25-28 ms at four and eight
checkers on ts-pattern, 13-18 ms more than tsrs's. The owner approved a
prototype that day, behind a build option that is off by default. The
process forks as it starts. The child runs the program, writes its
output, closes its standard streams, and hands its exit status to the
parent through a pipe. The parent, whose address space is tiny, exits
at once with that status, and the child tears its memory down in the
background. What moves off the stopwatch, what does not, and what does
the handoff change about signals, job control, the pid, stdin, crashes,
and output, on macOS and Linux?

**Answer.**

- **The stopwatch.** On Trig's PGO build the wall a shell sees falls by
  the whole exit: 5.9% on ts-pattern at four checkers and 8.0% at
  eight, 8.2% and 12.7% on zod3, and 1.7% and 3.1% at one checker. The
  fork costs about 0.05 ms on a small program.
- **What does not move:**
  - the teardown's CPU, 17-29 ms of one core's kernel time a run on
    ts-pattern;
  - the memory, 204-248 MiB, which stays resident until the teardown
    frees it;
  - the run's CPU time, which a caller's `time`, `getrusage`, and
    `perf stat` no longer count, since the process they wait for is
    the parent.
- **The prototype.** `RIG_EXIT_HANDOFF=1` at build time, about 190
  lines in `src/handoff.zig` and four calls in `runtime.zig`. It
  keeps the status, signals, crashes, and output a caller sees, with
  the limits below.
- **The owner decides whether it ships.**

## Measured: Trig on pup

Trig's PGO build of [investigation.md](investigation.md)
(`/zfs/trig-pup/runs/eq-new`, sha256 `e4e3e99e0efdba59`), unchanged,
under [exitwatch](exit-handoff-data/exitwatch.zig). This launcher
traces only the program's exit (`PTRACE_O_TRACEEXIT`): the kernel stops
the process as it starts to exit, before it tears down its memory. The
launcher notes that moment, the wall a handoff gives (what remains of a
real handoff's cost is its fork, below). It then lets the process go and
notes when it is reaped, the wall a caller sees today. A plain arm
(`EXITWATCH_PLAIN=1`) times the reaping with no tracing, to show the
tracing costs nothing.

The runs were on pup's E-cores: one checker on 12, four on 12-15, eight
on 12-19. There were 20 shuffled rounds in one timing slot (21:30-21:32,
`cpuq` clear, no Trig timing running, 0 free 2 MiB blocks after
compaction), and every run printed tsc's output and status 2
([ehab.sh](exit-handoff-data/ehab.sh), [ehab.py](exit-handoff-data/ehab.py),
[ab.txt](exit-handoff-data/ab.txt)). Times in ms, fastest / median:

| project | C | today, plain | today, traced | with the handoff | the exit, median | resident at exit |
|---|---:|---|---|---|---:|---:|
| ts-pattern | 1 | 1,201.7 / 1,214.3 | 1,201.8 / 1,212.7 | 1,186.3 / 1,193.8 | 17.1 | 204 MiB |
| ts-pattern | 4 | 503.8 / 514.1 | 492.9 / 512.6 | 470.9 / 483.9 | 25.2 | 229 MiB |
| ts-pattern | 8 | 427.6 / 452.4 | 433.1 / 447.5 | 405.6 / 416.4 | 29.0 | 248 MiB |
| zod3 | 1 | 204.0 / 210.2 | 204.6 / 210.1 | 197.7 / 203.7 | 6.8 | 71 MiB |
| zod3 | 4 | 120.0 / 127.9 | 119.8 / 129.7 | 111.0 / 117.4 | 10.5 | 96 MiB |
| zod3 | 8 | 108.0 / 116.9 | 111.1 / 115.4 | 97.6 / 102.0 | 13.6 | 113 MiB |

- **The handoff removes the whole exit from the wall, not only the part
  beyond tsrs's.** By the medians against today's plain runs:
  ts-pattern 1.7%, 5.9% and 8.0% faster at one, four and eight
  checkers; zod3 3.1%, 8.2% and 12.7%. tsrs's own exit is 7-12 ms, so
  with the handoff Trig's wall would hold less exit than tsrs's.
- **The exit grows with checkers** (17 → 29 ms on ts-pattern) where the
  resident memory barely does (204 → 248 MiB). It is the mappings and
  page tables of section 3 of the investigation, torn down on one core.
- **Tracing costs nothing**: the traced runs' reaped times match the
  plain runs' within 1%.

## Measured: the prototype on pup

[modes.rig](exit-handoff-data/modes.rig), built by the branch's Rig
with and without `RIG_EXIT_HANDOFF=1`, under `exitwatch` untraced, on
E-cores and outside a timing slot:

- **The fork**, as `mode ok` (prints a line and exits), 40 interleaved
  runs on core 16: 0.74 ms by the median without the handoff, 0.79 ms
  with it; fastest 0.66 and 0.69 ([fork.txt](exit-handoff-data/fork.txt)).
  The fork comes before the program has any memory of its own, so its
  cost is the binary's mappings alone. It was not measured on Trig,
  which would need a Trig build with the option.
- **A program that ends holding 820 MiB** (`mode big 20000000`, four
  tasks filling a `List` and a `Map`, then `os.exit(0)`), 10 interleaved
  runs on 16-19 ([big.txt](exit-handoff-data/big.txt)): 979 ms by the
  median without the handoff, 886 ms with it. Its exit, traced as
  above, is 74-87 ms.


## What moves off the stopwatch, and what does not

- **Moves:** the time from the program's last write to the caller's
  `wait` returning, which is the whole teardown.
- **Does not move:** the teardown itself. It runs on a core after the
  caller has gone on: 17-29 ms of kernel time on ts-pattern, during
  which 204-248 MiB stay resident and are freed as it goes. A caller
  that runs the program again at once, as a benchmark loop does, runs
  the next one beside it.
- **What a caller measures changes.** `time`, `getrusage(RUSAGE_CHILDREN)`
  and `/usr/bin/time`'s peak memory see the parent: on the Mac, 1.7-2.6
  ms of CPU against 1,281-1,422 ms without the handoff, for the same
  program. `perf stat` loses the child's counts unless it follows
  children and stays until they end. So Trig's bar, which reads
  instructions and peak memory, must be judged on a build without the
  handoff, or by the child's own counts.

## Behavior

The prototype is [handoff.zig](exit-handoff-data/handoff.zig), with its
hooks in `runtime.zig`, `main.zig` and `emit.zig` as [hooks.diff](exit-handoff-data/hooks.diff). Tested on the Mac with
[modes.rig](exit-handoff-data/modes.rig), built with and without it,
and on Linux (pup) with [linux-tests.sh](exit-handoff-data/linux-tests.sh) ([linux-tests.txt](exit-handoff-data/linux-tests.txt)).

| What | With the handoff | Checked |
|---|---|---|
| exit status | the child's: 0, `fun main`'s 3, `os.exit(5)` from a task, a panic's 134, a failure's 1 | Mac, Linux |
| output | flushed by the runtime as today, then the child closes fds 0-2 before it hands off its status, so `prog \| cat` and `prog \| head -1` end as soon as it does | Mac, Linux |
| stdin | the child's; the parent closes its copy | Mac, Linux |
| a crash | a child that dies before it hands off (panic, a signal, an exit that does not pass through the runtime's end) closes the pipe; the parent waits for it, then exits with its status or dies by its signal, with no core of its own. SIGKILL of the child: 137; SIGSEGV: 139 | Mac, Linux |
| Ctrl-C, Ctrl-\, a hangup, a resize | the terminal signals the process group, which holds both; the parent ignores those the kernel sends (sender pid 0); the child handles them as today, and the parent ends as the child does (Ctrl-C through a pty: killed by SIGINT, as without the handoff) | Mac, Linux |
| a signal sent to the pid the caller knows | `kill PID`, `timeout`: the parent passes INT, TERM, HUP, QUIT, USR1, USR2, ALRM and CONT to the child (`kill -TERM`: status 143, as without) | Mac, Linux |
| a signal sent to the whole group by a process | reaches the child twice, once directly and once passed on | by design |
| Ctrl-Z, `fg`, `bg` | the terminal stops and continues the whole group: both processes, as one job | Mac (by group signals; not through a pty) |
| SIGSTOP or SIGKILL sent to the parent alone | cannot be passed on: SIGSTOP stops only the parent; SIGKILL ends the parent, and on Linux the child with it (`PR_SET_PDEATHSIG`); on macOS the child runs on to its end | Mac, Linux |
| the pid | the caller knows the parent's; the program runs as the child, so a pid it reports or writes to a file is the child's | |
| a caller that reaps orphans | the child is reparented to init or the nearest subreaper, which reaps it after the parent has gone | |
| PGO training | no handoff: the profile is read once the process ends | |
| startup | a fork before anything else, so no thread, kqueue or epoll exists yet (macOS does not carry a kqueue into a child) | |

## What this leaves

The owner's decisions, each with a default:

1. **Ship it?** Default: yes, as an opt-in build option
   (`RIG_EXIT_HANDOFF=1`, or `--exit-handoff` on `rig build`), off by
   default, with its costs to measurement in its doc. Trig turns it on
   for its released binary and off for its benches.
2. **On by default for release builds?** Default: no. It changes what
   `time`, `perf stat`, and peak-memory tools report, and the pid a
   program runs as.
3. **Pass on signals sent to the whole group by a process?** Default:
   as built, a second delivery. Telling a signal sent to the group from
   one sent to the pid is not possible from the parent.
