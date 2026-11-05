# Why Trig falls further behind tsrs with more checkers (2026-11-04)

The question: Trig is 10.6% slower than shipped tsrs on ts-pattern at one
checker and 32.8% at four, 31.8% and 42.9% on zod3
([tsrs-standing-8.md](../../2026-10/hash-race/tsrs-standing-8.md)). Where
does the extra time go as checkers are added, who owns each part, and what
would each Rig-side fix be worth? Measurement only: no Rig or Trig code
changed. Scripts and summaries are in [data/](data/); the raw perf files
stay on pup in `/zfs/rig-work/scaling/`.

This builds on [scaling-2.md](../../2026-10/perf-stage/scaling-2.md)
(2026-10-28), [conc-audit.md](../../2026-10/perf-stage/conc-audit.md)
(2026-11-01), and the Trig session's study of today (its go-expert notes,
`timeline.txt`, `phases.txt` and memory trials; summarized where cited).
What those settled is not measured again: the Go partition's imbalance,
Trig's dynamic queue, the serial parse and bind, memory bandwidth, false
sharing (HITM snoops 5-6k a run, fewer than tsrs's), and the allocator
policy trials (huge pages from a Table's first byte: much slower; past its
first 2 MiB with no gate: level).

## In short

1. **Trig adds no more CPU than tsrs as checkers are added.** From one
   checker to four, task-clock rises 27.0% for Trig, 26.9% for shipped
   tsrs and 25.2% for tsrs in Go's mode; to eight, 33.4%, 38.1% and 32.9%
   (ts-pattern). User cycles per instruction rise alike (Trig 9.7%, Go mode
   8.9%). What Trig loses is wall time per CPU second: at four checkers
   its cores are busy 73% of the run against 89% for tsrs and 80% for Go
   mode. That is the critical path: file assignment, the heaviest group's
   single-thread speed, the serial head, and the exit.
2. **The Rig side of the loss is memory shape, not tasks.** Three costs
   grow with checkers in Trig and barely in tsrs, all from how Trig's
   Tables and heaps are mapped: the kernel's teardown at exit (25-28 ms at
   four and eight checkers on ts-pattern against 10-12), the kernel's
   page-fault work (10.6% of cycles at eight against 6.7%), and page walks
   (4.1% of user cycles against 0.2%). Together they are about 30 ms of
   the 85 ms that ts-pattern loses against Go mode at eight checkers, and
   all of zod3's 11 ms.
3. **Rig's scheduler and allocator code cost nothing measurable.** No
   cycle sample of 7,800 at eight checkers lands in `rig.sched`;
   `rig.alloc` is 1.8-2.2% of cycles at one checker and at eight; 166
   context switches a run against tsrs's 733.
4. **A correction to today's reading.** "Trig's CPU rises 27% on the same
   instructions, tsrs's 6%" compared eight checkers on one core with eight
   on eight cores. On one core Trig runs its eight checkers one after
   another on its one worker, while tsrs's eight threads share the core by
   time slices and lose cache to each other, so tsrs's one-core figure is
   inflated (4.85G user cycles against 4.05G at one checker). On matched
   cores, one checker against eight, the growth is the same for both
   (point 1).

## 1. Wall time and CPU by checker count

pup E-cores: one checker on 12, two on 12-13, four on 12-15 (one cluster,
one shared L2), eight on 12-19. Ten shuffled rounds in a timing slot
(18:46-18:48, 82 free 2 MiB blocks after compaction, load 2.3), every run
under `perf stat` and `/usr/bin/time`; wall by perf's `duration_time`.
Fastest of 10 (medians in [curve-summary.md](data/curve-summary.md)), ms:

| ts-pattern | 1 | 2 | 4 | 8 |
|---|---:|---:|---:|---:|
| Trig (Go's assignment) | 1,177.6 | 787.2 | 510.7 | 435.2 |
| tsrs, shipped | 1,067.7 | 607.3 | 381.5 | 287.0 |
| tsrs, Go mode | 1,090.4 | 714.9 | 429.8 | 324.3 |
| Trig against tsrs | 10.3% slower | 29.6% | 33.9% | 51.6% |
| Trig against Go mode | 8.0% slower | 10.1% | 18.8% | 34.2% |
| busy cores / C: Trig, tsrs, Go mode | | | 73%, 89%, 80% | 45%, 64%, 56% |

| zod3 | 1 | 2 | 4 | 8 |
|---|---:|---:|---:|---:|
| Trig | 204.7 | 181.7 | 126.0 | 112.7 |
| tsrs, shipped | 174.9 | 125.1 | 91.3 | 81.9 |
| tsrs, Go mode | 195.7 | 168.4 | 110.1 | 97.4 |
| Trig against tsrs | 17.0% slower | 45.2% | 38.0% | 37.6% |
| Trig against Go mode | 4.6% slower | 7.9% | 14.4% | 15.7% |
| busy cores / C: Trig, tsrs, Go mode | | | 70%, 84%, 77% | 50%, 60%, 53% |

Every run printed tsc's output and exit status, the same bytes in all 24
arms of a project. Trig here is Trig's PGO build in
`/zfs/trig-pup/runs/eq-new` (Rig 3fe58d632, lazy member tables on by
default, sha256 `e4e3e99e0efdba59`); tsrs is 0.18.0 as standing-8 ran it
(`d0bd720c20e99007`), shipped and with `--checkerAssignment go
--noLazyMembers`, `RAYON_NUM_THREADS` and `--checkers` both set to C. The
Trig session's tsrs 0.21.0 in Go mode (`TSRS_CHECKER_ASSIGNMENT=go`) took
431 ms at four checkers, as 0.18's Go mode does here, but 411 at eight
against 324: at eight, 0.18's Go mode is not the same partition as
Trig's, so its eight-checker column is not like for like.

Counters, medians of 10 ([curve-summary.md](data/curve-summary.md)):

| ts-pattern | task-clock 1 → 4 → 8, ms | kernel share of cycles | page walks, % of user cycles | page faults, K | peak RSS, MiB |
|---|---|---|---|---|---|
| Trig | 1,169 → 1,485 → 1,560 | 6.6% → 8.8% → 10.6% | 3.30 → 3.88 → 4.11 | 15.9 → 32.6 → 42.9 | 216 → 251 → 264 |
| tsrs, shipped | 1,066 → 1,353 → 1,472 | 5.1% → 5.3% → 5.8% | 0.28 → 0.19 → 0.20 | 16.0 → 18.3 → 20.3 | 167 → 184 → 195 |
| tsrs, Go mode | 1,092 → 1,367 → 1,451 | 5.7% → 6.1% → 6.7% | 0.29 → 0.18 → 0.21 | 18.1 → 21.3 → 23.6 | 207 → 231 → 242 |

| zod3 | task-clock 1 → 4 → 8, ms | kernel share of cycles | page walks, % of user cycles | page faults, K | peak RSS, MiB |
|---|---|---|---|---|---|
| Trig | 202 → 354 → 450 | 12.1% → 15.4% → 19.6% | 2.31 → 3.41 → 4.28 | 6.3 → 15.0 → 21.6 | 72 → 97 → 113 |
| tsrs, shipped | 175 → 305 → 396 | 10.1% → 10.4% → 11.9% | 0.13 → 0.16 → 0.23 | 5.4 → 8.2 → 11.8 | 49 → 75 → 98 |
| tsrs, Go mode | 197 → 337 → 410 | 10.0% → 10.4% → 11.9% | 0.14 → 0.17 → 0.25 | 5.7 → 9.3 → 13.0 | 58 → 89 → 111 |

"Page walks" is `ld_head.pgwalk_at_ret`: cycles a load at the head of the
reorder buffer waits on a page walk. The user cycles per instruction from
one checker to eight: Trig 0.568 → 0.623 (9.7% more), Go mode 0.528 →
0.575 (8.9%), shipped 0.543 → 0.606 (11.6%); on zod3 17.6%, 9.4% and
14.1%. Load stalls on LLC misses grow less in Trig (7.2% → 8.2% of user
cycles) than in tsrs (6.2-6.7% → 10.3%).

## 2. Where the cycles go, by kind

Cycle samples with call stacks, six runs per arm, kernel frames resolved
from `/proc/kallsyms` ([kinds.txt](data/kinds.txt)), share of all cycles:

| | Trig 1 | Trig 8 | Go mode 1 | Go mode 8 |
|---|---:|---:|---:|---:|
| ts-pattern: page faults | 3.97% | 7.86% | 4.66% | 5.07% |
| `madvise` (most of it `MADV_POPULATE_WRITE`, faults taken ahead) | 1.59% | 1.97% | 0.0% | 0.04% |
| TLB shootdown interrupts received | 0.0% | 0.43% | 0.0% | 0.0% |
| `mremap`, `mmap`, `munmap` | 0.23% | 0.54% | 0.0% | 0.1% |
| `rig.alloc` (user) | 1.80% | 2.18% | | |
| `rig.sched` (user) | 0 | 0 | | |
| zod3: page faults + `madvise` | 9.99% | 16.31% | 7.57% | 8.82% |
| zod3: TLB shootdown interrupts | 0.0% | 0.97% | 0.0% | 0.0% |

Page faults and faults taken ahead are 5.6% of Trig's cycles at one
checker and 9.8% at eight on ts-pattern; Go mode's 4.7% and 5.1%. The
exit's teardown does not show in these profiles (perf stops counting the
threads as they exit); it is timed in section 4.

## 3. What the memory looks like

Snapshots of `/proc/PID/smaps` at about 70% of a run
([smaps.txt](data/smaps.txt)) and page-table size near the end
([pte.txt](data/pte.txt)), ts-pattern:

| | Trig 1 | Trig 8 | Go mode 1 | Go mode 8 |
|---|---:|---:|---:|---:|
| mappings | 173 | 1,304 | 58 | 107 |
| anonymous memory, MiB | 150 | 220 | 152 | 230 |
| of it in huge pages | 72 | 46 | 100 | 138 |
| advised for small pages (Tables' first 2 MiB): mappings, MiB | 52, 32 | 409, 95 | 8, 0.2 | 28, 0.6 |
| advised for huge pages: mappings, MiB resident | 53, 80 | 410, 46 | 1, 100 | 1, 145 |
| page tables (VmPTE), MiB | 0.8 | 3.4 | 0.6 | 1.0 |

zod3 at eight: 1,207 mappings against 15, 10 of 91 MiB in huge pages
against 46 of 97, page tables 3.2 against 0.7 MiB.

- **Each checker brings 43 reserved Tables, and each Table its own
  mappings.** A Table's first 2 MiB keep small pages, and the rest asks for
  huge pages when the gate is open (`table.zig`'s `reserve`), so each
  Table is two or three mappings of the Tables' region. At eight checkers
  409 small-page heads hold 95 MiB on 4 KiB pages, and the 410 huge-page
  tails hold only 46 MiB: most Tables never fill past their head, and
  those that do are written sparsely. tsrs keeps everything in one 1 GiB
  arena advised for huge pages, filled densely.
- **The faults are in the heads.** At one checker 67% of Trig's 15.9K page
  faults land in mappings advised for small pages, the Tables' heads and
  the Tables' region where no huge advice was given; 26% in other
  anonymous memory (the heaps' segments and large blocks); 0.2% in
  huge-page ranges ([tlb.txt](data/tlb.txt), last part).
  At eight the heads hold three times the memory.
- **The page walks are in the heads too.** Loads that miss the second-level
  TLB, sampled with their data addresses and placed in the run's last map
  ([stlb.txt](data/stlb.txt)): at one checker, of the twelve mappings
  that take the most, ten are 2 MiB mappings of the Tables' heads' shape
  (2.4-5.6% each) beside one 4 MiB mapping (14%); at eight they spread
  over hundreds of them. Trig's completed page walks are 15 times tsrs's
  at one checker (4.4M against 0.3M) and 26 times at eight (5.5M against
  0.2M). A 2 MiB head on 4 KiB pages needs 512 TLB entries where a huge
  page needs one.
- **Sparse writes cost page tables.** Each 2 MiB stretch touched needs its
  own page of page table: 3.4 MiB of them at eight checkers is about 870
  stretches, 1.7 GiB of address space touched to hold 220 MiB.

## 4. TLB shootdowns and the exit

Tracepoints `tlb:tlb_flush`, `syscalls:sys_enter_exit_group` and
`syscalls:sys_exit_wait4` of the shell, five runs per arm, with call
stacks for the flushes ([tlb.txt](data/tlb.txt), [exit.txt](data/exit.txt)):

| ts-pattern, per run | Trig 1 | Trig 4 | Trig 8 | Go mode 8 | shipped 8 |
|---|---:|---:|---:|---:|---:|
| TLB flushes (all CPUs) | 1,139 | 9,959 | 19,114 | 416 | 522 |
| remote shootdowns received | 0 | | 12,861 | 209 | |
| exit, `exit_group` to reaped, ms (median) | 13.1 | 28.3 | 25.0 | 10.8 | 11.9 |
| zod3: exit, ms | 5.2 | 6.6 | 11.6 | 5.5 | 4.6 |

Exit at one, four and eight checkers: shipped tsrs 6.8, 10.0 and 11.9 ms
on ts-pattern, 2.0, 3.1 and 4.6 on zod3; Go mode 8.6, 11.9 and 10.8, and
2.1, 3.3 and 5.5.

- **The shootdowns come from the zero page.** At eight checkers, 91% of
  the flushes that send interrupts (5,107 of 5,620 over two runs) come
  from a write fault replacing a read-only page (`wp_page_copy`): a slot
  of a Table read while its page was never written maps the shared zero
  page, and the first write to it then replaces that page and flushes the
  TLB of every core running a checker. `mremap` makes 8%, `munmap` 1%.
  At one checker the same faults flush only locally (2,064 of 2,284). This
  is the 3 ms scaling-2 found at four checkers, grown to about 12,900
  remote flushes a run at eight.
- **The exit is the kernel tearing down that memory shape.** Trig's
  release build ends by `os.exit` after its output (nothing is dropped),
  so the 25-28 ms is the kernel's alone: 1,304 mappings, 174 MiB on 4 KiB
  pages, 3.4 MiB of page tables, against 107, 92 and 1.0 for Go mode.

## 5. The loss, ranked

The loss at C checkers is Trig's wall less what it would take at its
one-checker ratio to tsrs in Go mode (1.080 on ts-pattern, 1.046 on
zod3). Kernel and page-walk shares are turned into wall time at the
whole run's shares, which assumes the critical checker has the average
shares; the exit is serial and counts in full.

| ts-pattern, ms | at 4 | at 8 | owner |
|---|---:|---:|---|
| loss against Go mode | 46.5 | 85.0 | |
| exit teardown beyond tsrs's | 15.4 | 13.3 | Rig (memory shape) |
| kernel memory work that grows with checkers | 9 | 13 | Rig (memory shape) |
| page walks that grow with checkers | 3 | 3.5 | Rig (memory shape) |
| serial parse and bind (Trig 21-23 ms at every C; tsrs 0.21's 27 → 17 → 16) | 4.6 | 5.7 | Trig |
| the rest: the heaviest group's single-thread speed, and at eight a partition that differs from 0.18's Go mode | 15 | 50 | Trig, and the tsrs version (section 1) |
| file assignment: shipped tsrs against Go mode, at Trig's ratio | 53 | 41 | Trig (outside Go mode) |

| zod3, ms | at 4 | at 8 | owner |
|---|---:|---:|---|
| loss against Go mode | 10.8 | 10.8 | |
| exit teardown beyond tsrs's | 3.1 | 5.8 | Rig |
| kernel memory work that grows | 3.7 | 6.3 | Rig |
| page walks that grow | 1.1 | 1.7 | Rig |
| serial parse and bind (Trig 20-22 ms at every C; tsrs 0.21's 25 → 16 → 14) | 3.3 | 7.4 | Trig |
| the rest | -0.4 | -10.4 | |

On zod3 the Rig side accounts for all of the loss against Go mode (the
parts exceed it at eight, where Trig's check scales better than 0.18's Go
mode, a version difference this record does not resolve; the parse and
bind times are the Trig session's, on tsrs 0.21); on
ts-pattern for 27 of 46.5 ms at four and 30 of 85 at eight. Against
shipped tsrs the largest single part is file assignment, which the Trig
session measured (`TRIG_CHECKERS=dynamic`: 460 → 353 ms at eight) and owns.

What does not grow: the scheduler (no samples; workers keep their
checkers; three or four migrations a run in the Trig session's count),
the allocator's own code (flat at about 2%), cross-thread frees (inside
that 2%), user cycles per instruction (as tsrs's on ts-pattern), memory
bandwidth (scaling-2), and contended lines (HITM snoops below tsrs's).

## 6. Rig-side fixes, with ceilings

The ceilings are what Trig would gain if the cost fell to tsrs's level,
from the tables above; they overlap, since one memory shape causes all
three.

1. **Tables of one thread packed densely on huge pages (an arena like
   tsrs's).** One cause behind the faults, the page walks, the
   shootdowns' reach and the exit: 43 Tables a checker, each reserved at
   its largest size, its first 2 MiB on 4 KiB pages in a mapping of its
   own, written sparsely. tsrs's shape is one reserved range per process,
   handed out to threads in chunks of 1-64 MiB, huge pages from the 2 MiB
   chunks up, never given back. For Rig that means Tables taken from a
   heap's own arena, contiguous, with a small Table's first pages packed
   beside other Tables' rather than 2 MiB apart. The design question is
   growth: a reserved Table grows in place and never moves; packed Tables
   either move once when they outgrow their chunk (sound only if no view
   of a slot outlives a push, as for a List) or keep a reserved tail with
   a packed head (a branch on each index). Ceiling, all three costs to
   tsrs's level: ts-pattern 49 ms at four (9.6%) and 45 ms at eight
   (10.4%), of which page walks alone 17 and 15 ms (3.3% and 3.5%; 3.0% at
   one checker too); zod3 13 ms at four (10.6%) and 19 ms at eight (17%).
   Measure: a prototype arm on its own branch (after the foreman's OK),
   time-ab at one, four and eight checkers on P-cores and E-cores, with
   this record's counters: mappings, VmPTE, faults, `pgwalk_at_ret`,
   remote shootdowns, exit time. The memory trials already run (huge
   pages earlier or without the gate, Tables kept where they are) were
   level or slower, so the density, not the advice, is what pays.
2. **The exit.** The teardown follows the memory shape: fix 1 brings it
   toward tsrs's 10-12 ms. A step on its own is to end the process
   before the kernel's teardown is waited for (the parent exits once the
   output is written while a child holding the memory ends behind it, as
   mold does), the owner's call. Ceiling: Trig's whole exit, 25-28 ms on
   ts-pattern at four and eight (5-6% of wall) and 7-12 ms on zod3
   (5-10%); 13-18 ms and 3.5-7 ms of that is beyond tsrs's. Measure:
   [exit.py](data/exit.py) on the tracepoints, and wall in time-ab.
3. **The zero page under Tables.** A slot read before its page is written
   maps the zero page, and the write then shoots down every checker's
   TLB: about 5,000 such faults a run at eight checkers, half of them
   sending interrupts, 12,900 remote flushes. Either Trig writes before it reads (Trig's side), or a Table
   whose reads can precede its writes is faulted in ahead as it is first
   read. Ceiling: the interrupts' 0.4% of cycles on ts-pattern and 1.0%
   on zod3 at eight, about 2 ms and 1 ms, plus the TLB refills they force
   (inside the page walks of fix 1). Measure: remote shootdowns
   ([tlbsrc.py](data/tlbsrc.py)) and wall.
4. **Not worth a change:** the scheduler, the allocator's code, and
   `mremap` (8% of the flushes that send interrupts; scaling-2's panel
   measured its share at 0.4 ms).

## 7. For Trig

- File assignment (shipped tsrs against Go mode: 48 ms at four checkers
  on ts-pattern, 37 at eight), and the heaviest group's single-thread
  speed: Trig's.
- Writing a Table slot before it is first read removes most of the
  shootdowns (fix 3).
- Sparse Tables (scaling-2's 1,280 MiB Table written a page every 80 MiB)
  multiply the page tables and the exit; indexing them densely helps
  whatever Rig does.
- Exit numbers for Trig: section 4's table.

## Method

- **pup.** Every timing and profile ran in a slot from `/tmp/open-slot.sh`
  (18:44-18:59, four slots of 1-3 minutes: timing, profiles, exit,
  flushes), each when `cpuq status` showed no holder and no Trig timing ran;
  binaries copied to tmpfs for each slot and removed after. Load 1.2 to
  4.4 from builds on P-cores; E-cores 12-19 were free of other work.
- **Scripts.** [curve.sh](data/curve.sh) and [slot.sh](data/slot.sh) (the
  timing; [analyze.py](data/analyze.py) makes the summary);
  [prof.sh](data/prof.sh) (STLB-miss loads with data addresses, and map
  snapshots), [prof2.sh](data/prof2.sh) (cycles with stacks, smaps),
  [prof3.sh](data/prof3.sh) (exit and flush tracepoints),
  [prof4.sh](data/prof4.sh) (flush stacks, faults by mapping), each through
  [slotp.sh](data/slotp.sh); [pte.sh](data/pte.sh) (page-table size, run
  outside a slot); [classify2.py](data/classify2.py),
  [stlb.py](data/stlb.py), [smaps.py](data/smaps.py),
  [exit.py](data/exit.py), [tlbsrc.py](data/tlbsrc.py), [pf.py](data/pf.py).
  Raw rows: [curve.txt](data/curve.txt).
- **Limits.** The perf sample rate is capped at 1,000 a second on pup, so
  the kind shares rest on 1,000-6,700 samples per arm (six runs each);
  shares under 0.5% are rough. The eight-checker fault attribution did not
  finish inside its slot; the one-checker attribution and the smaps
  snapshots stand in for it. P-cores were not used: eight checkers need
  eight like cores, and pup's P-cores less 3-4 give five.
