# Exit panel, lens: adversarial critic, and Trig's side

Rig main `cf6a362a6`, Trig `origin/main` 6184626 and `origin/checker-drop`
(PR #277, open). Read-only on every repo. I ran no timings: no Mac check
could settle a Linux kernel question, and pup is out of reach. My scripts
and their output are in
`the panel's scratch folder (not kept)`
(`an.py`, `fit.py`, `q.py`). They read the raw rows of
`table-vmas-data/drop-ab.txt` (800 rows) and `exit-handoff-data/ab.txt`
(240 rows).

pup's kernel, from the records: Linux 7.0.0-38-generic, Ubuntu, THP
`madvise` (perf-stage/table-huge.md:46, perf-stage/stlb-aliasing.md:26).

## 1. The OS report's numbers against the raw data

### The per-MiB fit: sound to about ±25%

My refit of exit time (reaped less at-exit) against RSS at exit, all rows:

| checkers | drop-ab slot | exit-handoff slot | both |
|---|---|---|---|
| 1 | 0.092 ms/MiB, intercept -0.3, R² 0.87 | 0.083, +0.3, R² 0.86 | 0.089 |
| 4 | 0.127, -1.1, R² 0.91 | 0.106, +0.5, R² 0.77 | 0.120 |
| 8 | 0.134, -0.7, R² 0.82 | 0.129, -1.1, R² 0.86 | 0.130 |

The fit reproduces the OS report's slopes, an intercept near zero, and a
rate that rises with checkers. That rise also shows in the exit-handoff
slot, which had no free 2 MiB blocks, so huge pages at one checker do not
explain it. Four caveats:

- **The rate moves 20% between slots.** At four checkers it is 0.106 in
  one slot and 0.127 in the other, on the same binary at 229 MiB:
  ts-pattern's exit medians were 25.2 ms and 29.6 ms.
- **The exit is noisy within one arm.** ts-pattern at 4, today: 16.7 to
  36.6 ms over 20 rounds. In the drop arm: 11.6 to 25.9. A median of 20
  is good to about ±2 ms; a median of 5 is not.
- **RSS at exit includes the binary's file-backed pages,** 12-21 MiB
  (Trig RESULTS 2026-11-05, rss3). Unmapping them frees no page. So the
  slope per anonymous MiB is a little higher than fitted, and the
  intercept a little lower. This matters only for the small projects.
- **The fit is across projects,** so it cannot separate cost per MiB from
  each project's mix of heaps and Tables. The drop arm, whose Tables are
  gone, has the same slope (0.125 against 0.129 at four), which supports
  one rate.

### The like-for-like correction: right in direction, loose in size

The numbers quoted are those in `data/exit.txt`: Trig 13.1, 28.3 and
25.0 ms, tsrs 6.8, 10.0 and 11.9 ms. All are from the same slot with 82
free blocks, and the brief's 17-29 ms does mix slots. But:

- **n = 5 per arm, with wide spreads.** Trig at four checkers ran 15.7 to
  31.1 ms, at eight 22.4 to 35.1 ms. That Trig's exit is shorter at eight
  than at four is noise.
- **The tsrs match (92 MiB × 0.117 = 10.8 ms) is softer than it reads.**
  - The 92 MiB comes from a smaps snapshot taken at 70% of the run, not
    at exit.
  - 0.117 is none of the fitted rates. At eight checkers the fits give
    0.124-0.135, which predicts 11.4-12.4 ms.
  - So tsrs fits within 10-20%, not exactly.
- **The conclusion holds:** tsrs exits faster because less of its memory
  is on 4 KiB pages. That is a memory-shape fact, not an exit feature.

### The checker drop: 10 ms off the exit; about half reached the wall, and at eight checkers almost none did

Paired by round (drop less today, same round, same slot, medians of 20):

| project | C | exit | at-exit (the run itself) | reaped (the wall) | rounds the drop won | task-clock |
|---|---:|---:|---:|---:|---:|---:|
| ts-pattern | 1 | 0 | -1.3 ms | -2.2 ms | 11/20 | 9.2 ms more |
| ts-pattern | 4 | -10.1 ms | +0.7 ms | **-8.0 ms** | 14/20 | 10.3 ms more |
| ts-pattern | 8 | -10.3 ms | **+9.9 ms** | **-4.0 ms** | 12/20 | 32.6 ms more |
| zod3 | 4 | -2.8 ms | +2.1 ms | -1.0 ms | 12/20 | level |
| zod3 | 8 | -4.9 ms | +1.5 ms | -1.8 ms | 13/20 | 15.8 ms more |

- **At eight checkers the gain was eaten.** Across all 20 ranks of the
  sorted runs, ts-pattern's at-exit moved about 10 ms later: 391-425 ms
  today, 404-436 with the drop. By the fastest wall the drop is level at
  four and eight, in exitwatch and in `perf stat`. So the run got longer
  by most of what the exit saved. This is not noise: the whole
  distribution shifted.
- **At four checkers on ts-pattern most of the gain survived** (8 ms, 14
  of 20 rounds). On zod3 what is left is noise (12-13 of 20 rounds).
- **Trig's own A/B of the final version agrees** (RESULTS 2026-11-05: P-cores at 4, non-PGO builds of
  both arms). ts-pattern was level at 4 and 1.9% faster at 8; zod3 was
  1.3% slower at 4 and 1.9% faster at 8. Peak RSS was 11-27% lower. No
  row clears the bar.

**Why the run got longer: three causes, the first one certain from the
code.**

1. **The drop is in the joined path.** `check_group` drops the checker
   (`<c`, checkerpool.rig:282 on `checker-drop`) before it returns. Main
   joins every task in order (`for t in <tasks`, :166). A checker that
   ends within its drop time of the last checker therefore holds main up
   for the rest of its drop. With eight checkers on tsc's static
   assignment, end times bunch closer than with four.
2. **The drops run beside the last checker.** They add 10-33 ms of
   task-clock (3-5 ms a checker). Each walks a whole checker's cold
   memory on a core next to the busy one: pup's E-cores share an L2 four
   to a cluster. Each Table's `MADV_DONTNEED` (alloc.zig:1015) also sends
   a TLB shootdown to the busy core. At four checkers, on one cluster
   (12-15), this costs little; at eight it cost more.
3. **The profile did not match.** The drop arm ran on today's profile, so
   the functions it changed ran without one. This is small: one checker
   moved 1.3 ms, with 0.6% more instructions.

**The lesson for every exit idea:** a millisecond off the exit is not a
millisecond off the wall when the freeing happens beside work that is
still running.

## 2. The parallel release at the end, attacked

### `munmap` serializes in one process: the design as written gains about nothing on Linux

The OS report says "The zapping runs under a downgraded read lock, so
shares run in parallel." That is wrong for `munmap` against `munmap`:

- `__vm_munmap` takes `mmap_write_lock_killable`.
- `vms_complete_munmap_vmas` (mm/vma.c, 6.x) downgrades to the read lock,
  then zaps the pages and frees the page tables under it.
- A second thread's `munmap` needs the write lock, so it waits until the
  first thread's read hold ends: the whole zap.

The downgrade lets page faults and `madvise` run beside a zap. It does
not let another `munmap` run. So T threads unmapping T shares run one
after another, plus lock handoffs. The Mac probe's 2.1× is XNU's
`vm_map` and does not carry over. Nothing I know of in 6.x changes this,
and the records hold no evidence on 7.0.

### `MADV_DONTNEED` runs in parallel, but the free path below it has shared locks

`MADV_DONTNEED` takes `mmap_read_lock`, or only the VMA's lock in recent
kernels (per-VMA locks for `MADV_DONTNEED` came in the 6.1x series, so
7.0 has them). Threads can therefore zap at once. What they then share:

- **The lruvec lock, the one most likely to serialize them.** In
  `folios_put_refs` (mm/swap.c), every anonymous folio on the LRU is
  taken off it under the lruvec's `lru_lock`, held for each batch of up
  to 31 folios. There is one lruvec per memcg and node; pup has one node,
  and a process sits in one memcg, so every releasing thread contends on
  one spinlock.
  - `lruvec_del_folio` is a `list_del`. It writes both neighbours'
    `struct page`, and those neighbours are in fault order, interleaved
    from every core. That makes them the cold, random-order lines the OS
    report blames for the per-page rate rising with checkers, and they
    are touched inside the lock.
- **The zone lock,** taken in `free_pcppages_bulk` when a CPU's per-CPU
  list passes its high mark. 6.7's auto-tuned high mark makes this rarer.
- **The memcg's page counters,** uncharged per batch: atomics on lines
  shared by every releasing thread.

My estimate of the Linux speedup at three or four threads is 1.2-1.5×,
not the 1.5-2.5× the OS report assumes. That is a reading of the code,
not a measurement; the probe in §5 settles it.

**`MADV_FREE` is useless here.** It leaves the pages mapped and resident
until memory runs short, so the exit still zaps and frees every one, and
`MADV_FREE` adds a walk and an LRU move under the same lock.

**`DONTNEED` costs safety that `munmap` keeps.** After `munmap`, a task
the gate missed faults loudly. After `DONTNEED`, it reads zeros and goes
on. The parallel form is therefore exactly the one where a gate bug
fails silently.

### TLB shootdowns: cheap at the end

- Idle workers asleep in futex are lazy-TLB CPUs. x86 skips lazy CPUs on
  a flush, so each flush reaches only the other releasing cores.
- `mmu_gather` flushes once per full batch (thousands of pages) and once
  per call. For 150 MiB that is tens of IPIs, well under 0.1 ms.
- The exit itself flushes nothing remote (`fullmm`), so these IPIs are
  new cost, but small.

### Back-to-back runs, moved cost, and honesty

- **Back-to-back runs:** the gain survives. The freeing finishes before
  `exit_group`, so the next run starts on a clean slate, and nothing
  overlaps it.
- **Moved cost:** none leaves the window. It does raise total CPU: lock
  spinning, IPIs, worker wake-ups, and losing the exit's cheaper
  `fullmm` path. It trades throughput for latency. On a machine whose
  cores are busy with other work, such as a CI box running several trig
  processes at once, it is a small loss. That is the trade any parallel
  algorithm makes, and `time` and `perf stat` report it truthfully.
- **Honest by the owner's standard: yes.**
  - The caller's `wait` covers the work.
  - rusage counts it: the releasing threads' system time.
  - maxrss is unchanged.
  - Nothing overlaps the next run.

  Being honest does not make it worth its code.

### A design fix if it is ever built

Split the shares by owner, not by address: each worker releases its own
heap's segments and the Tables of the checker that ran on it. The
`struct page` lines it faulted are then more likely to be in its own
cluster's L2. This helps the per-page cost, not the lruvec lock.

## 3. Cheaper wins on Trig's side (Trig's to decide; findings forwarded raw)

**T1. Take the drop out of the joined path.** Today `check_group` drops
its checker before returning (checkerpool.rig:282), and main joins every
task (:166).

- Instead, each task could send its result (diagnostics, globals,
  counts) on a channel and then drop its checker.
- Main takes N results from the channel, writes the output, and calls
  `os.exit` (tools/trig/main.rig:147). It keeps the tasks in the pool,
  unjoined, until then, and `os.exit` ends any drop still in flight.
- A drop cut short leaves its pages to the exit, as today.
- This is honest: everything stays in the process, skipping work the end
  makes pointless, the same thing as `os.exit` skipping drops.
- Gain: up to the 10 ms at-exit shift at eight checkers, by cause 1 of
  §1; nothing at one checker. **Measure first:** count how often the
  penultimate checker's drop outlives the last checker's end. A
  timestamp per task, 20 runs, would show it.

**T2. Release only what returns memory.** A dropped checker's small
blocks go back on its heap's free lists with their pages resident. A
busy heap keeps every large block resident (alloc.zig:850,
`faultsAhead`). So the drop's whole RSS gain is its Tables'
`MADV_DONTNEED` (`unreserveTable`, alloc.zig:1005).

- The walk over everything else, most of the drop's 3-5 ms a checker
  (minus the Tables' own kernel freeing), returns no page.
- That walk is also what competes with the last checker, by cause 2.
- Giving back only the Tables gets the same memory for less CPU and less
  interference.
- Rig has no `Table` method that gives its pages back while the Table
  lives (table.zig has only `init`, `push`, `items` and the drop).
  Swapping in a fresh Table costs an `mmap` per Table.
- If Trig wants this, it is a small Rig ask (a Table `clear` that gives
  back its range), and part of the runtime expert's area.

**T3. Fewer resident pages: the lever that pays three times.**

- Each MiB not resident saves:
  - its faults during the run (Table first touches are 81% of
    ts-pattern's traps, memory-traffic.md);
  - its page walks;
  - about 0.13 ms of exit at 4-8 checkers.
- The exit is the smallest of the three.
- What is largest at exit, from the records:
  - **the last checker's Tables.** At eight checkers, 409 Table heads
    held 95 MiB on 4 KiB pages, written sparsely: 1.7 GiB of address
    space touched for 220 MiB (investigation.md §3);
  - **the heap**, in the last census at one checker (RESULTS
    2026-10-25): u32 lists 64.7 MiB, symbol tables 37 MiB, inference
    32 MiB (since mostly taken back, #212 and #215), instantiations
    16 MiB.
- There is no census at the end of a four-checker run since the drop.
  `RIG_HEAP_PROFILE=1` at four checkers on ts-pattern would rank what is
  left. That is the first step for Trig, and it costs nothing to run.

**Is the checker drop the right shape?** For peak memory, yes: 11-27%
lower, and the owner landed it for that. For speed it is the wrong shape:

- it does the kernel's freeing early, beside the critical checker;
- it walks memory it cannot give back;
- main joins on it.

T1 and T2 fix the shape without changing what it frees.

## 4. The size of the prize

The race's walls are at four checkers (tsc's default, tools/cli/bench:45)
on P-cores 0-11, with 8 idle workers at the end. The exit was measured
only on E-cores. I scaled the E-core exits after the drop by the P/E wall
ratio Trig measured at four checkers (316 against 511 ms, 0.62), up to
0.75 to be safe.

| project | race wall, all cores | exit, E-cores (drop) | exit, P-cores (estimated) | whole exit, % of wall | honest, speedup 1.2× | 1.5× | 2× |
|---|---:|---:|---:|---:|---:|---:|---:|
| ts-pattern | 274.8 ms | 19.5 ms | 12-15 ms | 4.4-5.5% | 0.7-0.9% | 1.3-1.6% | 2.0-2.5% |
| zod3 | 77.0 ms | 8.0 ms | 5-6 ms | 6.5-7.8% | 1.0-1.2% | 1.9-2.3% | 2.9-3.5% |
| tiny-invariant | 66.2 ms | 7.2 ms | 4.5-5.4 ms | 6.8-8.2% | 0.6-0.7%* | 1.2-1.4%* | 1.8-2.2%* |
| mitt, neverthrow, superstruct | 26-33 ms | 2.6-3.5 ms | 1.6-2.6 ms | 6-10% | under 1%* | about 1-1.5%* | about 2%* |
| ts-pattern, one thread | 665.6 ms | 19.7 ms | 12-15 ms | 1.8-2.3% | **0**: no idle worker | 0 | 0 |
| zod3, one thread | 120.7 ms | 6.7 ms | 4-5 ms | 3.3-4.1% | 0 | 0 | 0 |

The honest columns give the share of the wall saved: exit × 0.9 × (1 −
1/S), where 0.9 is the share in heaps and Tables (no stacks, no binary).
\* The small projects carry a larger share of file-backed binary pages
(0.5-0.7 rather than 0.9), so their columns are rougher.

- **The whole exit, which only the dishonest handoff could take,** is
  4-10% at four checkers and 2-4% at one.
- **An honest parallel release** clears the bar of more than 1.5% only if
  Linux frees about 1.6× faster on 3-4 threads than on one. My kernel
  reading says 1.2-1.5× is likelier, which puts every row at or under
  the bar.
- **At one checker,** where Trig races tsrs on one thread, it gains
  nothing.
- **It cannot win the instruction half of the bar**: it adds work.
- **A 1.5-2% gain must hold over 20 interleaved rounds.** The exit's
  median moved 4 ms between two slots on the same binary, so on
  ts-pattern the whole expected gain is the size of that drift.

**Is the area worth a build?** Not on today's evidence. It is worth one
probe, because the probe is cheap and decisive.

## 5. The measurement that settles it

**First step,** on pup in a slot, about 10 minutes. Extend
`table-vmas-data/vmabench.zig`:

- 4 threads fault 150 MiB densely, interleaved, so the LRU order mixes
  cores, as Trig's does;
- then one of four endings:
  - (a) `exit_group` at once;
  - (b) one thread `MADV_DONTNEED`s it all, then `exit_group`;
  - (c) three threads `MADV_DONTNEED` their own pages in parallel;
  - (d) three threads `munmap` in parallel. This checks my claim that
    (d) runs no faster than one thread unmapping alone.
- exitwatch, 20 rounds, E-cores 12-15, then P-cores 3, 6, 8 and 10.
- Also `perf lock contention -a` (or `perf record -a -g`) during (c), to
  see whether `lru_lock` is the wall.

**Kill rule:** if (c) from the first `madvise` to reaped is not at most
55% of (a) at exit (1.8×), drop the parallel release for good. Only if
it passes, build a Trig arm on top of T1, and time it against the drop
with `time-ab.sh` at 1, 4 and 8 checkers, 20 rounds.

**Trig side, with no Rig work:**

- T1's count first: how often the penultimate drop outlives the last
  checker.
- A `RIG_HEAP_PROFILE=1` census at four checkers.

## Verdict

- **The handoff: DROP,** as the OS report says.
- **The parallel release: MEASURE FIRST,** with only the probe above. The
  `munmap` form is DROP as written: it serializes on `mmap_lock`. My
  prior is that the `DONTNEED` form fails the 1.8× kill rule on the
  lruvec lock.
- **The cheaper wins are Trig's:**
  - take the drop out of the joined path (T1), which needs nothing from
    Rig;
  - free only what returns pages (T2), which may need a small Table
    method from Rig;
  - shrink what is resident (T3), which needs nothing from Rig and pays
    in the run three times more than at the exit.
