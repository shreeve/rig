# Huge pages for Tables while memory is fragmented (2026-10-31)

**Question.** Trig's reserved Tables take 66-77% of its page faults
([kernel-time.md](kernel-time.md)). Huge pages would cut those faults,
but the gate `hugeFree` in `src/alloc.zig` asks Linux for huge pages only
while more than 64 free 2 MiB blocks exist, and on pup it was shut in
every run of [tsrs-standing-4.md](../hash-race/tsrs-standing-4.md) (5 to
69 free). The stall the gate prevents is real
([thp-fragmented.md](thp-fragmented.md), [thp-spare.md](thp-spare.md)).
How can Tables get huge pages, or fewer faults, while memory is
fragmented, without compaction stalls?

**Answer.** Ask for each 2 MiB window as the Table first reaches it,
gated on a few free blocks at that moment (`jit`), not for the whole
reservation at reserve time. It takes the free blocks there are and
never stalls: on Trig at pup's fragmentation (30-45 free 2 MiB blocks)
and below it, jit is 1.2-2.8% faster than main on ts-pattern and zod3,
with 8-30% fewer page faults on ts-pattern, no compaction stall in 240
runs, and every output tsrs's bytes. It is not yet a clean win:

- **Quiet, main is 1.8% faster on ts-pattern.** jit took 64 huge pages
  where main took 76: windows Trig writes through `t[s]` past `len` are
  never reached by `push`, so jit never asks for them.
- **jit runs 0.8% more user instructions** on ts-pattern: five more
  Tables' `push` were outlined, as in fault-ahead's first try.
- **Peak RSS is higher** wherever jit takes huge pages and main does
  not: 1.3-1.5% on ts-pattern, 6.5% on zod3, 8-13% (2.6-4 MB) on the
  small projects. Huge pages commit a window whole; main pays the same
  when its gate is open.

The design that keeps both is a **hybrid**: main's gate at reserve when
it is open, and jit's window-at-a-time asks only when it was shut, with
the slow path in `push` marked cold so `push` inlines as before. That
is one more build to measure (below). `MADV_COLLAPSE`, a compacting
"breaker", and a helper thread that faults pages in ahead all lose on
one core or stall. Peak RSS rises with any form, so the trade goes to
the foreman.

Scripts, patches and raw output are in [table-huge-data/](table-huge-data/).

## pup

- Linux 7.0.0-38-generic. `/sys/kernel/mm/transparent_hugepage/`:
  `enabled` `[madvise]`, `defrag` `[madvise]`, `khugepaged/max_ptes_none`
  511, `shrink_underused` 1; every multi-size THP (`hugepages-8kB` to
  `hugepages-1024kB`) `never`, `hugepages-2048kB` `inherit`;
  `vm.compaction_proactiveness` 20.
- At 02:19, with 14 GB free, `/proc/buddyinfo` showed 18 free 2 MiB
  blocks outside DMA, 1,953 of 1 MiB and 9,468 of 512 KiB. During
  release builds it read 0.

## Why the gate is shut, and what the kernel offers

Under `defrag=madvise` a fault in a range advised `MADV_HUGEPAGE` takes a
free 2 MiB block if one exists and otherwise compacts in the fault; no
per-range mode takes a free block without ever compacting
(thp-fragmented.md, "A stall-free form"). Two things decide whether a
request stalls: whether free blocks exist when the range faults, and
how long after the check that is.

main's Table asks once, at `reserve`, for all of its reservation (24 MiB
to 4 GiB), and grows into it for the rest of the run. So the check must
leave room for everything the program will later fault through that
advice: 64 blocks, about what Trig takes. A check made just before each
2 MiB is first written needs room for one.

## Candidates

1. **jit**: each 2 MiB window of a Table asks for huge pages as `push`
   first reaches it, while `/proc/buddyinfo` shows at least 8 more than
   the window needs; segments and large blocks keep their advice at
   creation, gated the same way. The check sits on the folded limit
   that [fault-ahead/user.md](fault-ahead/user.md) proposed: `push`
   compares `len` with an `edge` field in place of `n`, so its fast path
   gains no instruction. `reach`, out of line, decides the next window.
   One reading of buddyinfo grants up to 16 windows ([jit.patch](table-huge-data/jit.patch)).
2. **MADV_COLLAPSE** of each window once it is filled in small pages.
3. **breaker**: each window advised and populated at once, compacting if
   it must, until one window takes more than 1 ms; then as jit.
4. **stash**: a helper thread keeps 3 regions of 2 MiB advised and
   faulted in ahead; each window the frontier reaches takes one by
   `mremap`, which moves a huge page as one entry
   ([stash.patch](table-huge-data/stash.patch), on jit).
5. **Gate at reserve, smaller spare, or per-Table**: thp-spare measured
   spares of 32 and 16, which stall when a run drains the free blocks
   after asking. A per-Table gate keeps the same flaw. Not measured
   again.
6. **Reserve at start-up**: Trig already reserves its Tables at start-up;
   the gate is shut then too.
7. **Multi-size THP** (64 KiB folios): cuts the faults 16-fold with no
   2 MiB slack, but it is a machine setting (`hugepages-64kB/enabled`),
   `never` on pup and every default system.

## The micro model

[tabjit.c](table-huge-data/tabjit.c) models Trig's Tables on ts-pattern:
40 reservations of 4 GiB filled to the page counts Trig faults in its
Tables (5,545, 4,503, ... pages, 126 MiB in all; fault-ahead/kernel.md),
64 bytes a push, the table chosen at random by size so that all grow
together, with four random reads of written slots after each push for
the TLB's share. The first 2 MiB of each keeps small pages, as `reserve`
does. [micro.sh](table-huge-data/micro.sh) ran each arm once a round,
rotated, 10 rounds a level, on P-core 6 with sibling 7 idle (04:35-04:41,
a quiet slot: no builds on pup):

- **natural**: pup as it was. Each run's exit frees what it took, so
  the free count the next run sees swings from 0 to 54.
- **light**: a fresh `frag` (thp-spare-data's, capped at 2 GiB) for each
  run takes every free 2 MiB block and holds it while the run lasts.
- **quiet**: `unfrag 256` once, `unfrag 64` before each run.

The stash arms ran twice: with the helper on E-core 12 (`2cpu`), and
sharing core 6 with the pushing thread (`1cpu`), the fair one-core
number. Medians ([micro-summary.txt](table-huge-data/micro-summary.txt),
raw [micro.txt](table-huge-data/micro.txt)); "vs small" is the median of
each round's wall ratio:

| level | arm | wall ms | vs small | sys ms | faults | huge MiB | slowest window ms | compact stalls | RSS MiB |
|---|---|---:|---|---:|---:|---:|---:|---:|---:|
| natural | small (main, gate shut) | 152 | | 31 | 32,462 | 0 | | 0 | 128 |
| natural | gate (main, 64 spare) | 151 | 1.7% faster | 34 | 32,462 | 0 | | 0 | 128 |
| natural | whole (ask always) | 144 | 6.3% faster | 21 | 8,414 | 104 | 1.60 | 1 | 138 |
| natural | **jit** | 142 | **6.7% faster** | 19 | 9,399 | 95 | 0.19 | 0 | 133 |
| natural | breaker | 142 | 7.2% faster | 19 | 8,414 | 104 | 0.19 | 0 | 138 |
| natural | collapse | 179 | 17.5% slower | 49 | 32,462 | 84 | 1.28 | 0 | 128 |
| natural | stash, 1 cpu | 142 | 7.0% faster | 20 | 8,422 | 110 | 0.02 | 2 | 144 |
| natural | stash, 2 cpus | 133 | 12.2% faster | 33 | 8,422 | 110 | 0.11 | 4 | 144 |
| light | small | 175 | | 32 | 32,462 | 0 | | 0 | 128 |
| light | gate | 171 | 1.4% faster | 33 | 32,462 | 0 | | 0 | 128 |
| light | whole | 247 | 50.8% slower | 98 | 23,264 | 36 | 21.05 | 114 | 128 |
| light | **jit** | 175 | **0.3% slower** | 28 | 32,462 | 0 | 0.00 | 0 | 128 |
| light | breaker | 179 | 2.0% faster | 23 | 12,368 | 84 | 1.21 | 4 | 132 |
| light | collapse | 194 | 9.3% slower | 48 | 32,462 | 83 | 0.86 | 0 | 128 |
| light | stash, 1 cpu | 226 | 20.8% slower | 145 | 29,672 | 15 | 0.02 | 42 | 136 |
| light | stash, 2 cpus | 150 | 12.1% faster | 36 | 10,304 | 99 | 0.11 | 6 | 144 |
| quiet | small | 150 | | 35 | 32,462 | 0 | | 0 | 128 |
| quiet | gate | 145 | 2.8% faster | 23 | 8,414 | 104 | 0.20 | 0 | 138 |
| quiet | whole | 143 | 5.0% faster | 18 | 8,414 | 104 | 0.22 | 0 | 138 |
| quiet | **jit** | 142 | **5.5% faster** | 22 | 8,414 | 104 | 0.19 | 0 | 138 |
| quiet | breaker | 146 | 2.9% faster | 21 | 8,414 | 104 | 0.30 | 0 | 138 |
| quiet | collapse | 185 | 21.8% slower | 51 | 32,462 | 84 | 1.02 | 0 | 128 |
| quiet | stash, 1 cpu | 142 | 5.2% faster | 22 | 8,422 | 110 | 0.02 | 0 | 144 |
| quiet | stash, 2 cpus | 132 | 11.7% faster | 26 | 8,422 | 110 | 0.11 | 0 | 144 |

The stash4k arms (the helper's regions in small pages) were 2.3-8.2%
slower than small on one core and 2.0-10.8% faster on two
(micro-summary.txt).

Read from these:

- **jit takes what is free and never stalls.** Its slowest first write
  into a window in 300 runs was 0.81 ms; asking always (whole) reached
  521 ms. Where a run started with blocks to spare it took 94-104 MiB
  of huge pages and matched asking always; where frag held every block
  it asked for none and ran as small pages do. main's gate, which needs
  64 spare at reserve, shut in every natural and light run.
- **A huge page is worth about 5-7% here, the TLB included**, the
  same order as thp-fragmented's Trig measure (5.3% quiet).
- **MADV_COLLAPSE loses at every level**, 9-22% slower: the window is
  faulted in small pages first, then copied. thp-fragmented found the
  same on kernel 6.x.
- **The breaker bounds the number of stalls, not their length.** It
  lets the first slow window through: 84 ms in one light run, 10 ms in
  another. On ts-pattern one such window is 1-11% of the run.
- **The stash's gain is the second core.** Sharing the core, it is a
  slower way to compact (20.8% slower fragmented: the compaction is the
  same work, now on the checker's core); stash4k on one core is slower
  everywhere, since faulting a page in another thread's region costs
  what faulting it in place does. On a second core it is 12% faster at
  every level, fragmented included, because both the compaction and the
  zeroing leave the checker's core.
- **RSS**: a huge page commits its window whole, so jit and whole hold
  5-10 MiB more than small pages here; the stash holds 16 MiB more (3
  regions ready at the end, and each window's slack).

## Trig

**Builds** ([build.sh](table-huge-data/build.sh)): Rig main `3296a2feb`
and main with [jit.patch](table-huge-data/jit.patch), each in its own
clone on pup; Trig `2ba0719` built by each with `rig build --release
--pgo`, trained by `tools/trig/bolt-train`, through `slot.sh` on the
E-core slots: main `d57ed6e860072d3d`, jit `68002bcd0569e6cf`. Plain
builds, no switch in either. A check program
([tabcheck.rig](table-huge-data/tabcheck.rig)) pushed 3 million slots
through jit's window path and read them back, same answer as main.

**Timing** ([time.sh](table-huge-data/time.sh), thp-spare's harness):
P-core 6 with sibling 7 idle, `perf` and `frag` on the E-cores, 20
rounds a level, the two arms rotated each round. All six projects at
the natural level (05:50-05:54, E-core builds running); ts-pattern and
zod3 at leave35 (`unfrag 256`, then a `frag` leaving 35 free blocks),
light (a fresh `frag` taking every free block, which left 1-69 as the
kernel compacted behind it) and quiet (`unfrag 256` before each run),
06:06-06:19 with nothing else on pup. Every output matched main's, and
main's matched tsrs's, on all six. Raw: [times-natural.txt](table-huge-data/times-natural.txt),
[times-frag.txt](table-huge-data/times-frag.txt); medians and quartiles:
[summary.txt](table-huge-data/summary.txt).

| project, level | free at start | main wall | jit wall | jit vs main [25th, 75th] | kernel cycles main / jit | faults main / jit | huge pages jit (main) | peak RSS main / jit |
|---|---:|---:|---:|---|---|---|---:|---|
| ts-pattern, natural | 34 (32-45) | 858 ms | 843 ms | **1.2% faster** [-2.2%, +0.4%] | 0.35G / 0.30G | 40,245 / 28,061 | 37 (0) | 246.7 / 250.4 MB |
| ts-pattern, leave35 | 34 | 778 ms | 758 ms | **2.6% faster** [-3.7%, -0.5%] | 0.32G / 0.29G | 40,246 / 32,659 | 26 (0) | 247.1 / 250.4 MB |
| ts-pattern, light | 23 (1-69) | 785 ms | 769 ms | **1.9% faster** [-4.4%, -0.2%] | 0.34G / 0.31G | 40,245 / 37,003 | 16 (0) | 247.1 / 250.4 MB |
| ts-pattern, quiet | 245 | 713 ms | 727 ms | **1.8% slower** [+1.3%, +2.6%] | 0.24G / 0.26G | 14,894 / 20,661 | 64 (76) | 259.1 / 259.5 MB |
| zod3, natural | 39 (30-45) | 168 ms | 165 ms | 1.6% faster [-3.5%, -0.5%] | 0.10G / 0.09G | 9,924 / 9,044 | 11 (0) | 77.2 / 82.3 MB |
| zod3, leave35 | 34 | 157 ms | 154 ms | 2.8% faster [-4.0%, -0.2%] | 0.09G / 0.09G | 9,924 / 9,044 | 11 (0) | 77.3 / 82.3 MB |
| zod3, light | 10-20 (1-69) | 157 ms | 155 ms | 0.3% faster [-1.9%, +1.8%] | 0.09G / 0.09G | 9,924 / 9,582 | 2 (0) | 77.3 / 80.5 MB |
| zod3, quiet | 249 | 152 ms | 153 ms | 0.3% slower [-0.4%, +1.5%] | 0.09G / 0.09G | 7,774 / 9,045 | 11 (15) | 84.1 / 82.3 MB |
| tiny-invariant, natural | 43 | 77 ms | 77 ms | 1.2% faster [-3.6%, +2.1%] | 0.05G / 0.05G | 6,043 / 5,630 | 7 (0) | 49.2 / 52.4 MB |
| superstruct, natural | 30 | 37 ms | 35 ms | 6.2% faster [-7.9%, -0.9%] | 0.03G / 0.02G | 2,743 / 2,098 | 4 (0) | 22.9 / 25.7 MB |
| mitt, natural | 32 | 29 ms | 29 ms | 1.8% faster [-8.2%, +2.5%] | 0.03G / 0.03G | 2,625 / 2,260 | 3 (0) | 31.3 / 33.9 MB |
| neverthrow, natural | 33 | 31 ms | 31 ms | 3.0% slower [-4.9%, +4.4%] | 0.03G / 0.03G | 3,072 / 2,560 | 3 (0) | 30.6 / 34.6 MB |

(Huge pages are the change in `thp_fault_alloc` over the run, the whole
machine's; with nothing else asking, they are Trig's.)

User instructions, medians: ts-pattern 7.972G (main) and 8.036-8.042G
(jit) at every level, 0.8% more; zod3 0.5-0.7% more; the small projects
within 0.4%. `nm` shows why: main's binary outlines `push` for 10 Table
types, jit's for 15, as the call to `reach`, which returns, replaced the
call to `fullPanic`, which does not.

Read from these:

- **Where main's gate is shut, jit is faster on both large projects**,
  by 1.2-2.8% where 26-37 blocks were free, and by 0.3-1.9% where a few
  were. Its kernel cycles fall 9-14% on ts-pattern. It takes about as
  many huge pages as there are free blocks past its floor of 8, and
  never more: 0 compaction stalls in all 240 of its runs, and its
  slowest ts-pattern run (924 ms) was in the natural part with builds
  on the E-cores, where main's slowest was 878 ms.
- **At pup's natural level jit takes 37 huge pages on ts-pattern, half
  of the 76 the quiet run takes.** The other half is the gain the free
  blocks do not allow without compacting. Its 1.2% there is under
  Trig's bar of 1.5%.
- **Quiet, jit loses 1.8% on ts-pattern** by asking for 12 fewer
  windows, those written past the push frontier, and by its 0.8% more
  instructions. Both are fixable, below.
- **Peak RSS:** ts-pattern 1.3-1.5% higher, zod3 6.5% (5 MB), the small
  projects 2.6-4 MB higher, wherever jit takes huge pages and main
  does not. Where both take them (quiet), jit's RSS is the same or
  lower. This is the cost of huge pages, which main also pays when its
  gate is open.

## The hybrid, and what it would cost

Keep main's `reserve` when its gate is open (more than 64 free blocks):
the whole reservation asks at once, as today, and `edge` is `n`. When
the gate is shut, leave the reservation unadvised and ask a window at
a time as `push` reaches `edge`, gated on 8 free blocks more than the
window needs, with one reading of `/proc/buddyinfo` granting up to 16
windows. Mark the call to `reach` cold at its call site, so that
LLVM's inliner weighs `push` as it does main's. Expected: quiet and
idle levels exactly as main; fragmented levels as jit, less the 0.8%
instructions. Segments and large blocks keep main's gate: jit's
lower floor for them likely accounts for part of the RSS rise on the
small projects, and their faults are not the Tables'.

It costs one 8-byte `edge` field and one `asked` field in a reserved
Table on Linux, about 30 lines in `table.zig` and 25 in `alloc.zig`,
and a unit test of `reach` on a buddyinfo reading for the test. It
needs one more PGO build and a 25-minute slot to confirm before any
change to `src/`.

## Stash on the blocking pool (not built)

The stash's measured gain is the second core: on one core it is a
slower way to compact. Done on Rig's existing blocking pool rather
than a new thread, `reach` would post "fault in a 2 MiB region" to the
pool and take a finished one by `mremap` at a later window: a hand-off
of about 4 µs per window (row 20 measured the pool's stat hand-offs at
about that), 60 windows on ts-pattern, 0.03% of the run. The pool's
thread is idle in a one-checker run, so on a machine with a free core
the stash's 12% (micro) would carry over in part; under `taskset -c 6`
it shares the checker's core and, fragmented, loses 21%. Whether a
runtime may spend a second core on a "one checker" run, and whether
Trig against tsrs should then be timed so, is the owner's call.

## Recommendation

1. **Build and time the hybrid** (default): one PGO build, 20 rotated
   rounds at quiet, natural and leave35. Land it in `table.zig` and
   `alloc.zig` only if it is level with main quiet and more than 1.5%
   faster on ts-pattern where the gate is shut, with the RSS trade
   approved.
2. **Peak RSS**: any form of huge pages for Tables raises it 1.5% on
   ts-pattern and 6.5% on zod3 where main's gate is shut. Accept for
   the speed (default), or keep main.
3. **Drop** `MADV_COLLAPSE` (9-22% slower in every state), the breaker
   (bounds how many stalls, not how long: one window took 84 ms), and
   the stash thread (owner's principle; loses on one core).
4. **Machine settings, not Rig's:** 64 KiB multi-size THP
   (`hugepages-64kB/enabled=madvise`) would cut Tables' faults 16-fold
   with no 2 MiB slack and need no free 2 MiB block; it is off on pup
   and on every default system, so Rig cannot count on it.
