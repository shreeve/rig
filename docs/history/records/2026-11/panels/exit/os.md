# Exit panel, lens: operating systems and process exit (Linux, macOS)

Rig main `cf6a362a6`. Read-only on every repo. Mac probes and their raw
output: `the panel's scratch folder (not kept)`
(`probe.c`, `watch.c`, `run.sh`, `probe.txt`, `modes.txt`, `rss.py`, `sum.py`).
pup was not reached; every Linux number is from the records.

## 1. What the exit is made of

### What the 17-29 ms window holds

- The window is `exitwatch`'s "reaped less at-exit"
  (exit-handoff-data/exitwatch.zig). "At exit" is `PTRACE_EVENT_EXIT` on
  the main thread, which comes at the start of `do_exit`, after user
  space has finished. So the whole window is kernel time:
  - `zap_other_threads`, and each worker's `do_exit`;
  - `exit_mmap`, run by the last thread to let go of the mm;
  - `exit_notify`, and the parent's `wait4` waking.
- **No user-space work is in it.** `os.exit` is `exitNow`
  (src/runtime.zig:7839): it locks the output, flushes, and calls
  `endProcess` (runtime.zig:7828), which is `exit_group` on Linux and
  `_exit` on macOS. It joins no thread, runs no drop and no atexit.
  Trig's release build ends this way.

### Exit time is resident memory times a per-page rate that rises with checkers

I fitted exit time against RSS at exit over every exitwatch row in
`exit-handoff-data/ab.txt` and `table-vmas-data/drop-ab.txt`: six
projects, Trig as it is today and with the checker drop (`rss.py`).

| checkers | slope | per 4 KiB page | intercept |
|---|---:|---:|---:|
| 1 | 0.087 ms/MiB | 0.34 µs | 0.6 ms |
| 4 (today) | 0.135 ms/MiB | 0.53 µs | -1.6 ms |
| 4 (checker drop) | 0.132 ms/MiB | 0.52 µs | -1.3 ms |
| 8 | 0.124 ms/MiB | 0.49 µs | 0.3 ms |

- **The intercept is about zero.** No fixed cost per thread or per
  checker can be seen, so killing threads costs nothing measurable.
  The record's mapping and page-table costs (1,304 mappings at about
  1 ms, about 0.6 ms of page tables) fall inside the noise of these fits.
- **The exit is page freeing.** table-vmas.md's "follows its resident
  memory" holds. But the cost per page is not fixed:
  - pup's single-thread dense probe (vmabench): 0.14 µs a page;
  - Trig at one checker: 2.4 times that;
  - Trig at four and eight checkers: 3.5-3.8 times that.
- **The checker drop lowered RSS, not the rate.** At four checkers it
  saved 10 ms, all of it from 72 MiB fewer resident pages; the slope
  stayed 0.13.

### Why the rate rises with checkers (hypothesis, not measured)

- The pages a thread frees were faulted on other cores: their
  `struct page` lines, refcounts, mapcounts and LRU-list neighbours were
  written there.
- `exit_mmap` frees them in address order on a single core, so these
  lines arrive cold and in random order. vmabench faulted in address
  order on the core that frees them.
- At eight checkers the faulting cores span two E-core clusters, with no
  L2 shared between them.
- The record has no kernel profile inside the exit window, so this stays
  a hypothesis.
- **To settle it:** time `exit_mmap`, `unmap_vmas`, `free_pgtables` and
  `release_pages` with kprobes over 10 exits (bpftrace, or
  `perf record -a -g` in the window). Check at the same time whether the
  window holds any TLB shootdown. exit.py's count of zero comes from
  per-task events, which miss the handlers that run on remote CPUs.

### Why tsrs's exit is shorter: fewer 4 KiB pages

- **The like-for-like numbers.** Only the investigation's slot measured
  Trig and tsrs together (data/exit.txt, 82 free 2 MiB blocks):
  - Trig: 13.1, 28.3 and 25.0 ms at one, four and eight checkers;
  - tsrs as shipped: 6.8, 10.0 and 11.9 ms.
- **The brief's comparison mixes conditions.** Its "Trig 17-29 ms" comes
  from the exit-handoff slot, which had 0 free blocks, so Trig had almost
  no huge pages there. tsrs was not measured in that slot.
- **At eight checkers, tsrs in Go mode:**
  - 138 of its 230 MiB anonymous memory is on 2 MiB pages, which leaves
    92 MiB on 4 KiB pages;
  - 92 MiB × 0.117 ms/MiB is 10.8 ms, and its measured exit is 10.8 ms.
- **Trig at eight:**
  - 174 MiB is on 4 KiB pages;
  - at about 0.13 ms/MiB that predicts 22-23 ms, and it measured 25 ms.
- **What makes the difference.** Huge pages free about 100 times more
  cheaply per byte: one PMD, one folio, one buddy free per 2 MiB. My
  estimate is 1-3 µs per huge page against about 230 µs for 512 small
  pages.
  - Cross-check: Trig at one checker exits in 13.1 ms with 72 MiB on
    huge pages, and in 17.1 ms with none.
  - Thread counts are similar (rayon's pool against Trig's workers), and
    mappings are worth about 1 ms, so neither explains it.
- **Prediction to check.** On a fragmented pup, tsrs's exit should grow
  toward Trig's, unless it gets huge pages by direct compaction (stalls
  that would land in its run instead). Measure tsrs under exitwatch in
  the same slot as Trig, at 0 and at more than 50 free blocks.

## 2. Honest ways to cut the real cost

Rates are pup's, from the fits above.

| Lever | Estimate | Basis | Verdict |
|---|---|---|---|
| (a) Fewer resident pages at exit | 0.09 ms/MiB at one checker, 0.13 at four and eight | fits above; the checker drop: 72-91 MiB fewer, 10 ms less | the main lever |
| (a′) Finished checkers' heaps give back kept large blocks and free segments when their worker goes idle | 3-6 ms at four checkers on ts-pattern (task-memory.md, inferred) | `decommit` already exists (src/alloc.zig:415); busy heaps keep everything (alloc.zig:850); segments are never returned (alloc.zig:24) | measure after the checker drop lands, as task-memory.md says |
| (b) Huge pages | up to about 0.12 ms per MiB moved to them; ceiling about 15-20 ms at four and eight checkers | the tsrs arithmetic above | only with density (table-arena) and free 2 MiB blocks; sparse huge pages raised RSS 27-408% (`archive/kernel-leads`). Not an exit feature |
| (c) Release on idle cores during the run | measured: about 10 ms at four and eight on ts-pattern; 2.1-2.5% faster by median, fastest level | table-vmas.md, "Today against Trig's drop" | the checker drop: Trig's, already measured |
| (c′) New: release in parallel at the end (below) | about 6-15 ms at four and eight checkers on ts-pattern (1.2-3%), 3-7 ms on zod3 (2.5-5%), nothing at one checker | Mac probe: 4 threads unmapping 1 GiB in 3.9 ms against 8.3 ms for the exit alone (2.1 times faster); Linux speedup assumed 1.5-2.5 times | MEASURE FIRST |
| (d) Park workers before exit | about 0 | intercept about 0; threads are killed in parallel | DROP |
| (e) `_exit` after the flush | 0 | Rig already does it (runtime.zig:7828-7832) | done |

### MADV_DONTNEED during the run costs other cores

In a process with several threads, each `MADV_DONTNEED` or `munmap`
sends a TLB shootdown to every core running the mm, which interrupts the
busy checkers:

- one interrupt per call or gather batch, 1-3 µs each on the core that
  receives it;
- for 43 Tables a checker on 8 cores, about 300 of them: under 1 ms
  spread over the run.

This is small, but a design that releases in many small calls would
multiply it.

### Design (c′): release in parallel at the end

**The idea.** Linux tears an mm down on one core and never in parallel.
The program can do most of that freeing itself on its idle workers just
before `exit_group`. The cost stays in the caller's wall time, in the
process's own CPU time, and inside its peak RSS. Nothing is hidden: it is
the kernel's teardown split across cores the program already owns.

**Where.** `endProcess` (src/runtime.zig:7828), release builds on Linux,
after `writeProfile`:

1. **Gate.** Do the release only when:
   - main has returned, or called `os.exit` with no other task runnable
     or running and no blocking-pool work in flight (from the scheduler's
     idle count);
   - output is locked and flushed;
   - at least 2 workers are idle.

   Otherwise run plain `exit_group`, as now. `os.exit` called from a task
   while others run must not release, since they would read zeroed
   memory.
2. **Split.** Divide what is resident among the idle workers:
   - the heap-segment region, `[region start, region_next)`
     (alloc.zig:899);
   - the Table regions (alloc.zig:950-975, `table_regions`);
   - each heap's large blocks, kept and handed out.
3. **Release.** Each worker unmaps its share with `munmap`, on its OS
   thread stack and never on a fiber stack carved from a segment.
   - `munmap` rather than `MADV_DONTNEED`: it also frees page tables
     and mappings, and a stray access faults instead of reading zeros.
     The zapping runs under a downgraded read lock, so shares run in
     parallel.
   - Main waits on a futex for all of them, then calls `exit_group`.
4. **Excluded:** stacks, runtime globals, the binary, and debug or
   leak-checked builds (whose leak check and heap profile run first).

About 60 lines in `runtime.zig`, `sched.zig` and `alloc.zig`, removable
in one step. No language rule changes: the program has ended, and the
memory is never observed again.

**Risks:**

- Linux may scale poorly: the lruvec lock is one per memcg and node, and
  the zone lock is taken in pcp drains, so freeing on 4-8 cores could
  come out only 1.2 times faster.
- A gate bug would let a running task see unmapped memory and crash the
  program during exit, which changes its status.
- Total CPU rises by the lock contention and the interrupts.
- A program that does any work after its last output (stdin draining,
  the blocking pool) must fail the gate.

**Measurement that settles it.** First step, on pup in a slot (pup is
out of reach today): extend vmabench with T threads that fault the pages
(1, 4 and 8, so faults land on other cores), then one of three endings:

- exit at once;
- one thread unmaps everything;
- T threads unmap their shares.

All under exitwatch, 20 rounds, at 0 and at more than 50 free blocks. If
the parallel ending is not at least 1.8 times faster than exit at four
threads, drop the design. If it is, build an arm of Trig and time-ab it
at one, four and eight checkers against the checker drop, with
`/usr/bin/time` and `perf stat` checking that RSS and CPU are reported
truthfully.

## 3. Is any form of the handoff honest?

**Precedent:**

- **mold** forks by default. Its manual says "`--fork` hides that
  latency" and warns that the fork also hides the resource statistics
  `time(1)` reports. It tells users to pass `--no-fork` when they need
  them. So the best-known precedent concedes the accounting problem.
- **`git gc --auto`** detaches (`gc.autoDetach`) and says so on stderr.
  That is housekeeping after the command's own result, not the
  command's own cost.
- **lld's early `_exit`** and **clang's `-disable-free`** skip only
  user-space frees. That is honest, and Rig already does it.
- **Daemons** (Gradle, Bazel, tsserver, rust-analyzer) never tear down.
  They are a different architecture, and their benchmarks are labelled
  "warm".

**Where the line is.** A gain is real for the person running the program
only if all three hold:

1. the caller's `wait` covers all the work done for it;
2. its rusage and maxrss land on the caller (Unix sends them up only
   through reaping);
3. back-to-back runs do not overlap.

The handoff breaks the second and third whenever it gains anything. The
child is reparented to init, or to a subreaper, which alone receives its
times. A form where the parent waits by default gains nothing by default.
Its opt-in mode is mold's `--fork`: a convenience for users, not a speed
result. It could never count toward the bar or a comparison with tsrs.
Even its convenience is small: 10-30 ms at the prompt, under the roughly
100 ms a person notices.

**Verdict on the handoff: drop it in every form from Rig.** If Trig ever
wants mold-style behaviour for interactive use, a launcher outside the
compiler can give it, off by default and documented as mold documents
it. Rig carries no code for it.

## 4. macOS

The Mac was not quiet (load 6-8; `.mac-quiet` absent). Runs were through
`tools/low`, 7 interleaved rounds, with the window measured from the last
output byte to `wait4` returning (`watch.c`):

| program | RSS | exit, fastest / median |
|---|---:|---|
| C probe, 1 GiB, faulted by 1 / 4 / 8 threads | 1.0 GiB | 7.8 / 8.3, 8.0 / 8.7, 8.2 / 8.7 ms |
| C probe, main unmaps it all, then `_exit` | 1.0 GiB | 7.1 / 7.9 ms (the same work as the exit) |
| C probe, 4 / 8 threads unmap shares in parallel, then `_exit` | 1.0 GiB | 3.7 / 3.9, 4.1 / 4.7 ms |
| C probe, 256 MiB | 256 MiB | 1.5-1.6 / 1.7-1.9 ms |
| `modes.rig big 5000000`, Rig release build | about 360 MiB | 3.8 / 4.9 ms |
| `modes.rig big 20000000` | about 1.25 GiB | 14.7 / 15.0 ms |
| `modes.rig ok` | 2 MiB | 0.33 / 0.35 ms |

- **About ten times cheaper per byte than pup.** A Rig heap exits at
  about 0.012 ms/MiB, against Trig's 0.09-0.13 on pup. That reflects
  16 KiB pages (four times fewer per MiB) and faster cores.
- **What it means for Trig on the Mac.** A Trig run holding 230 MiB
  would exit in about 3 ms, under 1% of its run time. The exit is not a
  Mac problem.
- **The teardown is synchronous.** The pipe's end of file arrives only
  after the teardown, and the gap matches the exit.
- **Little rise with faulting threads.** Unlike pup's fits, the exit
  grew only 5% from one faulting thread to four.
- **Parallel unmapping halves the exit at four threads.** This is the
  evidence (c′) rests on. It is the Mac's kernel; Linux is unmeasured.

## Verdict

- **The handoff: DROP.** It moves cost out of the measured window and
  off the caller's accounting; even mold's manual says so.
- **The honest successor: MEASURE FIRST.** Release in parallel at the
  end on idle workers, plus (a′) after the checker drop lands. The first
  step is the multi-threaded vmabench on pup above.
