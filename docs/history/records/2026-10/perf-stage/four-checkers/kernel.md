# Where Trig's kernel time goes at four checkers (row 44), 2026-11-01

Measurement only: nothing built, edited or committed. pup E-cores (four threads
on 16-19, one on 18), so the numbers show structure, not P-core times; P-core
milliseconds are roughly half. Trig `806e0a1` PGO by Rig `928b44bf2`
(standing-6's `/zfs/worktrees/rig/standing-6/trig/bin`); tsrs 0.18.0 shipped,
Go mode. Another session's zig ran on 16 and 19 for part of the session; the
scripts waited for idle cores before each run, and the tables use medians.
Raw data and scripts: pup `/zfs/worktrees/rig/four-checkers/budget/`
(`stat.txt` and `stat.sum`, `strace/`, `frec/` with `faults.out`, `krec3/` with
`kc3.out`, `phases.out`, `threads.out`; `fault.py` is the page-fault
microbenchmark). The scope changed from a wall-time budget to row 44, so there
is no `budget.md`.

## Short answer

Trig's kernel excess comes from **populating memory one 4 KiB page at a time**,
and **reserved Tables** take most of it. 63-83% of Trig's page faults land in
the Tables' address space. A Table's first 2 MiB always uses small pages, and
the rest gets huge pages only when one `/proc/buddyinfo` reading, taken as the
checker starts, finds more than 64 free 2 MiB blocks. On pup that count sits at
30-140, so the gate is a lottery each run. tsrs takes 2.3 times fewer faults
for its memory, because its arenas are backed by huge pages.

Most of the excess is not about four checkers at all. At one checker Trig
already spends twice tsrs's system time: 43 against 23.5 ms on zod3, 130
against 67.5 on ts-pattern. Going from one checker to four adds 10 ms more for
Trig than for tsrs on zod3, and 23 ms more on ts-pattern.

Ruled out: mmap_lock contention, futex and epoll wake-ups, zeroing, and
exit_group itself.

## Counts (perf stat, 12 rotated rounds, medians)

| project | arm | wall ms | sys ms | kernel share of cycles | faults | context switches | RSS MB |
|---|---|---:|---:|---:|---:|---:|---:|
| zod3 | trig1 | 283.2 | 43.0 | 13.4% | 9.3k (7.6k) | 771 | 78 |
| zod3 | trig4 | 184.9 | 78.7 | 16.6% | 18.4k (16.9k) | 789 | 115 |
| zod3 | tsrs1 | 222.3 | 23.5 | 9.9% | 5.4k | 68 | 54 |
| zod3 | tsrs4 | 135.4 | 48.9 | 11.5% | 9.3k | 320 | 86 |
| ts-pattern | trig1 | 1474.8 | 130.5 | 8.4% | 39.5k shut / 14.7k open | 714 | 254 / 265 |
| ts-pattern | trig4 | 638.1 | 187.6 | 10.1% | 47.9k shut / 32.4k open | 739 | 286 / 326 |
| ts-pattern | tsrs1 | 1233.5 | 67.5 | 5.3% | 17.8k | 70 | 202 |
| ts-pattern | tsrs4 | 489.0 | 101.8 | 6.0% | 21.5k | 415 | 228 |

The kernel shares reproduce the audit's on E-cores. Trig's fault counts fall
into exact modes. ts-pattern runs with the Table gate open are 2.3% faster at
four (wall median 624.8 against 639.5 ms; 3 open runs, 9 shut) and 3.1% faster
at one (1446 against 1492 ms). That matches the audit's 3-4% on P-cores.

## Where the faults land (every fault recorded with its address, `perf record -e page-faults -c 1 -d`)

| | Tables region | mremap-moved large blocks | large blocks <2 MiB | large 2-16 MiB | segments | other |
|---|---:|---:|---:|---:|---:|---:|
| zod3 trig1 | 4.7k (63%) | 1.0k | 0.55k | 0.84k | 0.05k | 0.4k |
| zod3 trig4 | 12.3k (67%) | 1.4k | 1.1k | 0.87k | **1.9k** | 0.7k |
| ts-pattern trig1 (shut) | 32.5k (83%) | 4.3k | 0.9k | 1.2k | 0.07k | 0.4k |
| ts-pattern trig4 (shut) | 36.6k (77%) | 5.2k | 2.4k | 0.85k | **2.0k** | 0.8k |
| ts-pattern trig4 (open) | 21.1k (65%) | 5.3k | 2.3k | 0.85k | 2.0k | 0.8k |

- In Trig code, Table faults happen in the checker's type builders
  (`instantiate_type_with_alias`, `resolve_structured_type_members_worker`,
  `get_signature_from_declaration`), where Table inserts are inlined. Each extra
  checker adds about 2.5k Table faults on zod3.
- Even with the gate open, zod3 takes 12.3k Table faults at four, because every
  Table's first 2 MiB keeps small pages: 172 Tables at four checkers.
- Segments. At four checkers no heap "leads", so each checker heap's first
  segment is neither faulted in ahead nor given huge pages until the heap has
  taken 8 MiB: about 1.9k faults. At one checker the heap leads, and there are
  about 60.
- tsrs: 82-95% of its faults are in its gigabyte-sized arenas, at
  2.3 times fewer faults per MB of RSS.

## Kernel time by cause (cpu-clock samples with call chains, 10-16 runs per arm, ms of CPU)

Each kernel sample is classified by the frame where it entered the kernel
(page fault or system call) and by the user frame that entered it. Zeroing is
the samples on the hottest kernel instruction (`...42e90a`); the
microbenchmark confirms that address is the page-clear loop. Ordinary interrupts
are left out. The plain `cycles:k` sampling throttled on every sample on this
host, so its shares are biased, and `krec/` and `krec2/` are kept only for
reference.

| ms of CPU | zod3 trig4 | zod3 tsrs4 | ts-pattern trig4 | ts-pattern tsrs4 |
|---|---:|---:|---:|---:|
| page faults (trap) | 40.0 | 21.0 | 102.9 | 59.4 |
| ...of which zeroing | ~6 | ~8 | ~17 | ~20 |
| prefault syscalls (`MADV_POPULATE_WRITE`, segment + large) | 10.2 | 0 | 25.1 | 0 |
| Table drop at exit (`MADV_DONTNEED`) | 3.6 | 0 | 9.4 | 0 |
| mmap, munmap, file io, other | 9.6 | 1.6 | 10.7 | 3.4 |
| scheduler wake-ups (Trig poll/eventfd; tsrs futex + sched_yield) | 1.9 | 7.5 | 2.1 | 7.0 |
| thread spawn, buddyinfo | 1.9 | 0.4 | 1.3 | 1.6 |
| **total entered by fault or syscall** | 66.8 | 29.9 | 150.7 | 71.2 |
| IPIs, probably TLB shootdowns (entry seen only in Trig4; biased sampling) | ~3 | 0 | ~4 | 0 |

- Zeroing is not the gap. Trig zeroes 20-40% more memory, as its RSS is
  larger, which costs only 2-5 ms more CPU. The gap is per-page overhead: about
  2.2-2.5 µs of kernel time per 4 KiB fault, against 0.4-0.6 µs per 4 KiB
  inside a huge page (microbenchmark, one E-core).
- mmap_lock contention: none seen. Trig's per-fault kernel cost does not rise
  from one checker to four (zod3 2.5 against 2.2 µs), and context switches
  stay flat (771 against 789). The microbenchmark shows four threads of one
  process faulting in lockstep pay 30-55% more per page than four separate
  processes. Trig's checkers do not fault in lockstep enough to show this.
- Wake-ups: Trig makes about 766 futex calls, 387 epoll_pwait calls and 388
  eventfd writes per run at one checker and at four. That is 2 ms of CPU,
  against tsrs4's 7-8 ms (2.6k futex calls, 1.2-1.8k sched_yield).
- mprotect: 72 calls at four (5 at one), under 1.5 ms. munmap: 155 calls at
  four, most at exit.

## On the critical path at four

From the same samples:

| | Trig4 head kernel | busiest thread in the check window: busy / kernel | tail after the last checker sample: wall / kernel |
|---|---:|---:|---:|
| zod3 | 20.3 ms (13.8 at one) | 114 ms / 9.6 ms | 8.8 / 6.1 ms (4.0 / 1.6 at one) |
| ts-pattern | 17.2 ms (10.7 at one) | 551 ms / 37.7 ms | 22.0 / 13.4 ms (14.0 / 8.1 at one) |

Whole-run busiest thread, busy and kernel ms:

| project | Trig4 | tsrs4 |
|---|---|---|
| zod3 | 168 busy / about 21 kernel | 95 busy / about 8 kernel |
| ts-pattern | 574 busy / about 55 kernel | 440 busy / about 17 kernel |

So the kernel excess on the critical path is about 13 ms of zod3's 50 ms wall
gap and about 38 ms of ts-pattern's 149 ms, both on E-cores. Halved for
P-cores, that agrees with the audit's 5 and 10-12 ms.

**The tail.** After the diagnostics are written, Trig drops every checker on
one thread. Under strace that is 172 `MADV_DONTNEED` and 173 `MADV_NOHUGEPAGE`
calls (the Tables' ranges given back), then 89 munmap calls (large blocks),
then remote frees (`freeSlow`), and only then `exit_group`. exit_group's own
teardown is 2-4 ms of CPU, 5-8 ms under strace, about what tsrs's takes
(3-7 ms). tsrs exits straight after its output, and its tail after the last
checker is at most about 6 ms.

## Rig-side fixes, ranked by estimated wall at four

Estimates are in E-core ms. P-core ms are roughly half.

1. **Table huge-page gate decided at growth, not once at reserve (Rig, alloc.zig `reserveTable` / table.zig).**
   Today all 43 Tables of a checker are judged by one buddyinfo reading taken
   as the checker is made. When that reading is 64 blocks or fewer, every
   Table keeps small pages for the whole run. A Table could ask for huge pages
   when it first grows past its first 2 MiB, checking the count then.
   Measured shut-to-open difference: ts-pattern about 15 ms at four (2.3%)
   and 46 ms at one (3.1%); zod3 about 0. Confidence medium (3 open runs;
   the audit agrees). Cost: about 14% more RSS at four when open, and the
   compaction risk `huge_spare` guards against.
2. **Skip teardown at exit (Rig runtime/emit for release builds, or Trig calls `exitNow` after flushing).**
   This removes the Table `DONTNEED`/`NOHUGEPAGE` calls, the munmaps, and the
   frees of the checkers' memory. exit_group frees the same pages more
   cheaply, at about 130 ns per 4 KiB page, which adds back about 3-5 ms.
   Net: ts-pattern about 10 ms at four (about 9 at one), zod3 about 4 ms.
   Confidence medium-high (tail 22 ms against tsrs's at most 6 ms, 13 ms of
   kernel in it).
3. **A Table's first 2 MiB promoted to a huge page once the Table is clearly large (Rig, table.zig).**
   Small Tables stay cheap. A Table that has used about 1 MiB gets
   `MADV_HUGEPAGE`, plus `MADV_COLLAPSE` or new growth into huge pages. That
   addresses the 12.3k (zod3) and 21k (ts-pattern, gate open) small-page Table
   faults at four: 27 and 46 ms of CPU. Estimate: zod3 3-6 ms, ts-pattern
   5-10 ms. Confidence low: archive/table-ahead cut 65% of faults for only
   0.4% fewer cycles at one checker, so real savings per fault are below the
   microbenchmark's.
4. **Large blocks on huge pages from 2 MiB in heaps that fault ahead (Rig, alloc.zig `huge_large`, now 16 MiB).**
   Faults in large and mremap-moved blocks plus their prefault syscalls come
   to about 32 ms of CPU on ts-pattern at four and about 10 ms on zod3.
   Estimate: ts-pattern 4-6 ms, zod3 1-2 ms. Confidence low.
5. **A checker heap's first segment faulted ahead with huge pages at four (Rig, alloc.zig `faultsAhead`/`leads`).**
   Today no heap leads at four, so about 1.9k first-segment faults cost
   4 ms of CPU. Estimate: about 1 ms. Confidence medium.
6. **Prefaulting Tables ahead (`MADV_POPULATE_WRITE` or `MAP_POPULATE`).**
   Already tried (archive/table-ahead): small. Estimate: 1-3 ms. Last.

Not worth pursuing: mmap_lock (not observed), wake-ups (Trig is cheaper than
tsrs), zeroing (2-5 ms of CPU, proportional to Trig's larger footprint), and
exit_group itself (same as tsrs). A smaller second lottery also exists, about
1.5-1.7k faults on zod3 (7.6k against 9.3k at one checker); its source was not
found.
