# Where Trig stands against tsrs, after #758 to #767 (2026-10-29)

The question: with #758 (Maps of 64 bytes), #761 (the runtime built
unchecked), #764 (huge pages only while Linux has free 2 MiB blocks to
spare), #745, #731, #766 and #767 on Rig main, how far is Trig's PGO
build behind shipped tsrs at one checker; how much did Rig move since
[tsrs-standing-2.md](tsrs-standing-2.md)'s main, timed again the same
day; and where does zod3's larger gap come from? The method is
standing-2's, with TLB counters added. Measurement only; no code
changed. Scripts and raw output are in
[tsrs-standing-3-data/](tsrs-standing-3-data/).

## Method

- **Machine.** pup (Core Ultra 9 185H). Every run on P-core 1, its
  sibling 2 idle (`taskset -c 1`); before each round `time.sh` waited
  until no other thread ran on core 1 or 2. Load average 0.4 to 3.5
  through ts-pattern, 0.7 to 7.3 through zod3 (other sessions' builds
  started during the second pass; the wait held core 1 and 2 clear).
- **Trig.** Main `2ba0719` (its float fix is what Rig main's #745
  needs), its `src/` and `tools/trig` taken by `git archive`, its
  projects copied beside them, so the cron's checkout cannot move under
  the builds or the timing. `tools/trig/main.rig` is the root.
- **Variants.** Each Rig in its own clone under
  `/zfs/worktrees/rig/tsrs-standing-3`, built with `zig build` on cores
  1,2; each Trig through `/zfs/trig-pup/trial/slot.sh` with
  `TRIG_RELEASE_SLOTS='10,11 10,11 10,11'`, `rig build --release --pgo`
  trained by `tools/trig/bolt-train`, as Trig ships it
  ([build.out](tsrs-standing-3-data/build.out)):
  - `1b2-pgo`: Trig `2ba0719` by Rig main `1b2f4b59d`;
  - `773-pgo`: Trig `2ba0719` by standing-2's main `773978d1d`; it
    builds there, so the step from `773-pgo` to `1b2-pgo` is Rig's alone;
  - `773-403-pgo`: standing-2's own binary, Trig `403a823` by
    `773978d1d`, copied (sha256 `4147764dce2d4773`, as standing-2's
    build.out); it ties today's numbers to that record's;
  - `tsrs`: shipped 0.18.0, and `tsrs-src`, its source build, Go mode on
    one thread:
    `RAYON_NUM_THREADS=1 tsrs -p tsconfig.trig.json --noEmit --singleThreaded --checkerAssignment go --noLazyMembers`.
    Trig: `trig -p tsconfig.trig.json --noEmit --singleThreaded`.
- **Timing** (`time.sh`). 20 rounds, the five variants interleaved in
  each, ts-pattern then zod3; then all of it again (`times-b.txt`). One
  `perf stat` per run: wall time, user and system time, user and kernel
  cycles, user instructions, page faults, completed dTLB walks (loads,
  stores), loads that missed the dTLB and hit the STLB, and completed
  iTLB walks; peak RSS from `/usr/bin/time`; and, before each run,
  Linux's free 2 MiB blocks as #764's gate counts them. A round 0, not
  counted, kept each variant's reference output; all five references
  are tsrs's bytes, and every run of the 400 matched its reference.
- **Diagnosis** (`diag.sh`, on `1b2-pgo`, P-core 1): Trig's and tsrs's
  `--extendedDiagnostics`, 5 runs each; two tiny projects with zod3's
  options, 20 interleaved runs each: `empty` (one empty file, so only
  zod3's five libraries) and `nolib` (`noLib`); 40 sampled profiles each
  of zod3 (a sample every 10M cycles, user and kernel, kernel stacks
  whole; Trig keeps no frame pointer, so its user side is the leaf), with
  exec, write, exit and, on Trig, uprobes at `FileLoader.load` and
  `Checker.check_source_file` as phase marks; 40 profiles of Trig's
  user cycles with LBR call stacks, for callers; 3 runs recording every
  page fault; `strace` counts. `walks.sh` then counted the cycles a page
  walk was active, 8 interleaved runs each.

## Trig against tsrs

Both passes together, 40 rounds a variant (each pass alone is in
`times-summary.txt` and `times-b-summary.txt`):

ts-pattern:

| | wall median | wall fastest | user cycles | kernel cycles | instructions | page faults | dTLB load walks | STLB hits | peak RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Trig PGO, Rig main `1b2f4b59d` | 746.6 ms | 705.7 ms | 3.285G | 351M | 7.983G | 40,415 | 2.01M | 86.2M | 251 MB |
| the same, gate open (4 runs) | 712.5 ms | 705.7 ms | 3.196G | 250M | 7.986G | 15,277 | 1.25M | 49.4M | 262 MB |
| the same, gate shut (36 runs) | 747.7 ms | 727.3 ms | 3.288G | 352M | 7.982G | 40,415 | 2.03M | 87.4M | 251 MB |
| Trig PGO, `773978d1d` | 717.5 ms | 706.2 ms | 3.268G | 238M | 8.163G | 15,543 | 1.17M | 49.3M | 272 MB |
| standing-2's binary | 721.2 ms | 701.3 ms | 3.275G | 241M | 8.164G | 15,542 | 1.15M | 50.3M | 269 MB |
| tsrs shipped | 627.9 ms | 620.6 ms | 2.882G | 179M | 7.227G | 17,802 | 0.59M | 21.6M | 202 MB |
| tsrs source build | 748.6 ms | 740.4 ms | 3.490G | 179M | 8.133G | 17,687 | 0.65M | 20.6M | 205 MB |

zod3:

| | wall median | wall fastest | user cycles | kernel cycles | instructions | page faults | dTLB load walks | STLB hits | peak RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| Trig PGO, Rig main `1b2f4b59d` | 148.2 ms | 142.1 ms | 0.615G | 99M | 1.414G | 10,061 | 204k | 11.3M | 80.9 MB |
| the same, gate open (8 runs) | 146.3 ms | 142.1 ms | 0.607G | 92M | 1.415G | 7,912 | 127k | 7.2M | 87.7 MB |
| the same, gate shut (32 runs) | 148.5 ms | 143.8 ms | 0.616G | 100M | 1.413G | 10,061 | 207k | 11.4M | 80.9 MB |
| Trig PGO, `773978d1d` | 148.0 ms | 142.9 ms | 0.624G | 92M | 1.438G | 8,060 | 122k | 7.2M | 90.8 MB |
| standing-2's binary | 147.9 ms | 142.3 ms | 0.627G | 91M | 1.439G | 8,061 | 120k | 7.2M | 88.2 MB |
| tsrs shipped | 111.3 ms | 108.4 ms | 0.482G | 56M | 1.206G | 5,414 | 54k | 3.1M | 53.8 MB |
| tsrs source build | 137.4 ms | 133.3 ms | 0.617G | 51M | 1.403G | 4,725 | 55k | 3.1M | 54.8 MB |

Trig PGO on Rig main against shipped tsrs:

| | ts-pattern | zod3 |
|---|---:|---:|
| wall, median | **1.19×** (1.19×, 1.19× by pass) | **1.33×** (1.34×, 1.32×) |
| wall, fastest | 1.14× | 1.31× |
| wall, median, gate open | 1.13× | 1.31× |
| user time | 1.14× | 1.28× |
| system time | 1.97× | 1.54× |
| user cycles | 1.14× | 1.28× |
| kernel cycles | 1.97× | 1.76× |
| instructions | 1.10× | 1.17× |
| page faults | 2.27× | 1.86× |
| dTLB load walks | 3.39× | 3.74× |
| iTLB walks | 1.19× | 1.26× |
| peak RSS | 1.24× | 1.50× |

On 2026-10-28 the same comparison gave 1.19× and 1.37×. Standing-2's
binary, timed again today, gives **1.15× and 1.33×**: today's pup ran
every variant faster than on 2026-10-28 (tsrs 7.9% and 4.5%, that binary
11% and 7.6%), so of the two records' ratios only those taken the same
day compare.

**The huge-page gate.** pup had 88 to 139 free 2 MiB blocks through the
timing (median 107 before a ts-pattern run, 122 before a zod3 run),
around the gate's 128. Rig main's runs are bimodal by it: with the gate
open a run takes 15,277 page faults on ts-pattern (7,912 on zod3), shut
40,415 (10,061). A run's own huge pages drain the count: two runs that
began at 132 and 133 took huge pages for their first requests and none
after. Only 4 of 40 ts-pattern runs and 8 of 40 zod3 runs had the gate
open. `773978d1d`, from before the gate, asks always, and at this level
of free blocks its requests did not stall (its faults are standing-2's,
15,543 and 8,060).

## The step from standing-2's main, same day

`773-pgo` and standing-2's binary are within 0.5% of each other on
every count (Trig's step from `403a823` to `2ba0719` changes nothing
here), so the step below is Rig's, `773978d1d` to `1b2f4b59d`:

| | ts-pattern, all runs | ts-pattern, gate open | zod3, all runs | zod3, gate open |
|---|---:|---:|---:|---:|
| wall median | **4.1% slower** | 0.7% faster | 0.2% slower | 1.1% faster |
| wall fastest | 0.1% faster | 0.1% faster | 0.6% faster | 0.6% faster |
| user cycles | 0.5% more | 2.2% fewer | 1.4% fewer | 2.7% fewer |
| kernel cycles | 48% more | 5.2% more | 7.3% more | 0.6% fewer |
| instructions | 2.2% fewer | 2.2% fewer | 1.7% fewer | 1.6% fewer |
| page faults | 2.6× | 1.7% fewer | 25% more | 1.8% fewer |
| dTLB load walks | 72% more | 6.4% more | 68% more | 4.2% more |
| peak RSS | 7.8% less | 3.8% less | 11% less | 3.4% less |

- **Where the gate lets it, Rig main is faster:** 2.2% (ts-pattern) and
  2.7% (zod3) fewer user cycles, 2.2% and 1.6% fewer instructions (#761,
  #758), 0.7% and 1.1% faster by the median, and 3.4-3.8% less peak
  memory (#758).
- **Where the gate shuts, ts-pattern loses 4.9%** against its own
  gate-open runs (kernel cycles 41% more, user cycles 2.9% more from
  1.6× the dTLB walks); zod3 loses 1.5%. The gate was set where
  `773978d1d` stalled (48-62 free blocks, [thp-gate.md](../perf-stage/thp-gate.md));
  today, at 88-139, asking did not stall, and the gate cost ts-pattern
  its huge pages in 36 of 40 runs.

## Where zod3's gap comes from

On ts-pattern Trig is 1.19× tsrs, on zod3 1.33×; by median wall zod3's
gap is 36.9 ms of a 148 ms run. Cut two ways:

**By phase** (`--extendedDiagnostics` medians, 5 runs each, P-core 1,
[extdiag.txt](tsrs-standing-3-data/extdiag.txt)):

| zod3 | Trig | tsrs | gap | Trig / tsrs |
|---|---:|---:|---:|---:|
| parse | 19 ms | 11 ms | 8 ms | 1.7× |
| bind | 7 ms | 3 ms | 4 ms | 2.3× |
| check | 116 ms | 92 ms | 24 ms | 1.26× |
| outside the program's timers (exec, config, exit) | 4.2 ms | 2.3 ms | 1.9 ms | |
| wall (timing medians) | 148.2 ms | 111.3 ms | 36.9 ms | 1.33× |

ts-pattern's parse and bind are the same size (19 + 7 against 12 + 4
ms), but its check is 737 against 621 ms (1.19×), so the head's 10-12 ms
is 9% of ts-pattern's gap and 33% of zod3's. Trig's head by uprobe, in
the profiled runs: exec to the first `FileLoader.load` 5.8 ms, to the
first `check_source_file` 27.0 ms more; its tail, the output to exit,
0.3 ms (tsrs 0.4). At one checker teardown costs nothing: the drops and
the exit together are under 0.5 ms.

**By kind** (timing medians, at the 4.95 GHz both ran at): user cycles
0.615G against 0.482G, 27 ms of the gap (73%); kernel cycles 99M against
56M, 9 ms (24%).

- **Kernel.** Outside timer ticks (which perf's own sampling inflates),
  88% of Trig's kernel samples are memory: page faults 52%,
  `MADV_POPULATE_WRITE` prefaulting 34% (167 calls, 32.6 MiB; tsrs makes
  none), `munmap`, `mremap` and `mmap` 11%. tsrs's are 82% memory, all
  faults. So about 41M cycles, 8 ms, is the kernel giving Trig memory:
  peak RSS 80.9 against 53.8 MB, in 4 KiB pages while the gate is shut
  ([prof-summary.txt](tsrs-standing-3-data/prof-summary.txt),
  [mem-summary.txt](tsrs-standing-3-data/mem-summary.txt)). The faults
  fall where the checker first writes new objects:
  `resolve_structured_type_members_worker` 1,763 a run,
  `instantiate_type_with_alias` 1,621, `memset` 478, `memcpy` 416
  ([faults-summary.txt](tsrs-standing-3-data/faults-summary.txt)). File
  I/O is under 1 ms on either side: Trig's 780 context switches against
  tsrs's 69 (each `stat`, read and `realpath` handed to the blocking
  pool's thread) cost 0.7 kernel samples a run against tsrs's 0.45, about
  0.5 ms.
- **Fixed cost.** The `empty` project, zod3's five libraries and nothing
  else, takes Trig 26.4 ms and tsrs 15.2 (68M and 27M user and kernel
  cycles against 44M and 22M); parse 11-12
  against 8 ms, bind 5-6 against 2. Trig binds 33,368 symbols there,
  tsrs 12,559; the 20,800 more are zod3's whole difference in symbols
  (199,073 against 178,125). Peak RSS 31.0 against 17.5 MB holds without
  `perf` too (30.4 and 17.5, standing-2's binary). Trig's program has three libraries tsrs's
  lacks (`lib.esnext.iterator`, `.modulesource`, `.promise`), 1,138 of
  60,390 lines, about 0.3 ms. `nolib`, the process alone, costs both 13M
  cycles: startup is no part of the gap
  ([fixed-summary.txt](tsrs-standing-3-data/fixed-summary.txt)).
- **The checker's own hot spots**, by LBR stacks of Trig's user cycles
  ([lbr-summary.txt](tsrs-standing-3-data/lbr-summary.txt)), each a
  share of zod3's 124 ms of user time: `resolve_external_module` 4.2%
  inclusive (5.2 ms; 3.1% its own, with what PGO inlined into it: the
  resolved-module lookup, `get_source_file_for_resolved_module`, and
  three `String` copies a call),
  `Program.get_emit_module_format_of_file` 1.5% (1.9 ms; it copies the
  file's name into a new `String` on every call from
  `check_source_element`), and `check_collisions_for_declaration_name`
  1.5% (1.9 ms). tsgo answers each from a cache or a map; tsrs is
  stripped, so its own time in them is not measured.
- **TLB.** Page walks are active 1.1% of Trig's user cycles on zod3
  (0.6% for tsrs), with the gate open in those runs, and 2.5% (1.1%) on
  ts-pattern, with it shut ([walks.txt](tsrs-standing-3-data/walks.txt)):
  about 0.6 ms on zod3, 9 ms on ts-pattern. Trig's loads hit the STLB 2.3-4× as often as
  tsrs's.

## The leads, ranked by zod3's 36.9 ms

The rows overlap where noted: the kernel row's milliseconds fall inside
the phases of the first two.

| lead | owner | zod3 | ts-pattern | measured as |
|---|---|---:|---:|---|
| 1. Parse and bind 1.7× and 2.3× tsrs's; 7 ms of it the five libraries every project parses (bind 3.5 ms: 2.7× tsrs's symbols in the libraries) | Trig | **12 ms (33%)** | 10-12 ms (9%) | extdiag; the `empty` project |
| 2. The checker's resolution hot spots: `resolve_external_module`, `get_emit_module_format_of_file`, `check_collisions_for_declaration_name` | Trig | **up to 9 ms (24%)** | not measured | LBR inclusive shares of user cycles |
| 3. The kernel giving 1.5× the memory: faults, `MADV_POPULATE_WRITE`, `munmap`/`mremap`; partly inside 1 and 2 | Rig and Trig | **8 ms (22%)** | 35 ms of kernel cycles in all (14 with the gate open), not split by kind | kernel samples by kind, scaled to kernel cycles |
| 3a. of which the gate shut at 88-139 free blocks | Rig | 2.2 ms (1.5%) | 35 ms (4.9%) | gate-open against gate-shut runs |
| 3b. of which the footprint: RSS 80.9 against 53.8 MB (libraries alone 31.0 against 17.5) | Trig, and Rig's Tables and prefaulting | the rest, ~6 ms | | RSS; `strace` |
| 4. The rest of the check, at about ts-pattern's ratio | Trig | ~10 ms | most of its gap | check 24 ms, less 2 and the kernel's part |
| 5. TLB walks beyond tsrs's | Rig (huge pages, Table layout) and Trig (data layout) | ~0.6 ms | ~9 ms | walk-active cycles |
| 6. File I/O through the blocking pool | Rig (std.file) | ~0.5 ms | ~0.5 ms | syscall samples; 780 against 69 switches |
| 7. Startup, teardown | | none | none | `nolib`; output-to-exit 0.3 ms |

What makes zod3's ratio worse than ts-pattern's is rows 1 and 2: the
head is the same 10-12 ms on both but a third of zod3's gap, and
zod3's own 85 files and their imports feed `resolve_external_module`
and its neighbours. Without rows 1 and 2 at
tsrs's speed, zod3 would be about 1.14×, ts-pattern's ratio.

- **Rig-side:** the gate's threshold (3a): on ts-pattern it is the
  largest single Rig lead today, 4.9%, and it costs only while free
  blocks sit between the level where asking stalls (48-62 in
  thp-gate.md) and 128; prefaulting by `MADV_POPULATE_WRITE` is a third
  of Trig's memory kernel time on zod3, and whether it fills pages Trig
  never touches was not measured; TLB walks (5) on ts-pattern; std.file's
  pool (6) is small.
- **Trig-side:** the head (1), the resolution hot spots (2), the
  libraries' symbols (1), and the footprint (3b).

## Odd things

- pup's free 2 MiB blocks sat at the gate's threshold the whole time, so
  Rig main's numbers are a mix of two modes; the table gives both.
- tsrs and every Trig ran faster than on 2026-10-28 (above); the same-day
  rows are the comparison.
- `/usr/bin/time` measures `perf stat`'s child tree: perf itself peaks at
  about 17.5 MB, so the `nolib` runs' RSS is perf's, not theirs.
- Trig's `nolib` wall time varies 5.6 to 9.5 ms with its CPU time flat:
  a 5 ms run is at the mercy of the core's clock ramp. Its cycles, equal
  to tsrs's, are the measure used.
- The first diagnosis run lost its phase marks: PGO inlined
  `checker.new_checker` away, so the mark is the first
  `check_source_file` instead.
