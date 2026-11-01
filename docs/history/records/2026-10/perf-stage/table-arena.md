# Tables' address space and a kept buddyinfo reading (2026-10-31)

**Question.** beat-tsrs item 15: Trig's four checkers start slower than
one, and each checker's 43 reserved Tables cost about 16 µs of system
calls each on a pup E-core (a read of `/proc/buddyinfo`, then `mmap`,
`madvise`, and the `munmap`s that trim an aligned range), about 0.7 ms a
checker. Two Rig-side fixes, in `src/alloc.zig` and `src/table.zig`:
(3) keep a reading of `/proc/buddyinfo` for a few milliseconds, so a
burst of Tables reads it once; (2) hand Tables ranges of one address
space, with no mapping per Table. What does each reach on Trig, and is it
safe?

**Answer.** Built as #832. Fix 2 includes fix 3 and was judged with it.
With memory fragmented as pup's is under load (10 free 2 MiB blocks, the
huge-page gate shut):

- One Trig run at 4 checkers reads `/proc/buddyinfo` 4 times where it
  read it 174 times. It calls `mmap` 69 times, not 240, and `munmap` 30
  times, not 203.
- On E-cores, at 4 checkers: 3.4-4.3% fewer user plus kernel
  instructions and 1.6-4.9% less task-clock. At 1 checker: 0.8-1.0%
  fewer instructions.
- On P-cores, at 4 checkers: 1.8-3.7% fewer instructions, and wall
  times within the noise. Stacked with Trig's checker-tasks: 1.6-4.5%
  less wall by the median and 2.1-7.0% less by the fastest.
- Every output is byte-identical, and peak RSS is level.

## Fix 3: the kept reading

- **Window: 4 ms.** One checker's 43 Tables are made in about 1 ms. Four
  checkers made one after another span a few ms (the strace timeline
  shows 43 reads 0.08 ms apart, with 1.3-1.7 ms between checkers under
  strace).
- **The clock.** It is read through the vDSO (`CLOCK_MONOTONIC`, tens of
  nanoseconds). A reading is one atomic word: the time in units of 2^16
  ns in the top 40 bits (two years) and the free blocks, saturating at
  2^24 - 1, in the low 24. A thread can never pair one reading's time
  with another reading's count.
- **Why a Table may use a kept "yes".** A Table takes no 2 MiB block when
  it is reserved, only as it is written over the whole run. The spare of
  64 (thp-spare.md) is there for what memory gives up during the run. A
  reading 4 ms older moves the reservation 4 ms earlier, which adds
  nothing to that.
- **Why a segment or large block may use only a kept "no".** These take
  their blocks moments after they ask (`hugeFreeFor`, floor 8;
  table-huge.md). A stale "no" costs at most some missed huge pages and
  never stalls; a stale "yes" could stall. So a "yes" is always read
  afresh, and its blocks are subtracted from the kept count. That keeps
  the count conservative about the process's own takes for the Table
  gate too.
- **Alone, on P-cores at 4 checkers:** 1.0-3.2% fewer instructions, with
  wall time within the noise (1.5% more to 2.6% less by the median).

## Fix 2: the Tables' address space

- **Reservation.** On Linux, a release build reserves regions of 256 GiB
  (`MAP_NORESERVE`, so none of it is committed under overcommit 0 or 1).
  Each region is advised `MADV_NOHUGEPAGE` once and aligned to 2 MiB, up
  to 32 regions (8 TiB). Trig at 4 checkers reserves 210 GiB of Tables;
  at 22 checkers it would need 5 regions.
- **Handing out.** A Table takes whole huge pages: the smallest free
  range that fits, else the rest of the newest region, else a new region
  (the old region's rest goes to the free ranges). A Table larger than a
  region, or one that finds no region (`ulimit -v`, strict overcommit),
  maps its own range, as before. The Table records nothing new: on drop,
  its address says whether a region holds it.
- **Huge-page advice.** A Table past 2 MiB whose gate opens (`hugeFree`,
  with the kept reading) advises its range past the first 2 MiB
  `MADV_HUGEPAGE`. That is one system call, and the gate is unchanged.
  With the gate shut, a Table makes no system call at all.
- **Release.** A dropped Table's range gets `MADV_DONTNEED`, which gives
  its pages back to the system (the unit test checks this with
  `mincore`), so RSS falls as it did with `munmap`; the next Table to take
  the range reads zeros. If any range has asked for huge pages, a range
  given back is first advised `MADV_NOHUGEPAGE` again. The range then
  rejoins the free ranges: 128 at most, joined to their neighbours, or to
  the region's rest when it borders it. A range that would be the 129th
  is forgotten; its pages are back with the system and only its
  addresses go unused. The page tables of a range given back stay until
  the range is reused or the program ends. They are not counted in RSS:
  0.2% of the memory a Table filled.
- **Thread safety.** One spinlock covers the regions, the newest region's
  rest, and the free ranges. Only the list work is done under the lock;
  `madvise` runs outside it. The one exception is mapping a new region
  (an `mmap` and a `madvise`, once per 256 GiB).
- **Debug builds.** Each Table keeps its own mapping, as before. A Table
  used after it is dropped faults, `RIG_SANITIZE` behaves as before, and
  the leak checker's one-byte token reports a Table never dropped.

## Measurements

The arms are Trig aa3994b, built plain `--release` with no PGO:

| Arm | Rig | Trig |
|---|---|---|
| base | a5a78efbb (seg's head; `alloc.zig` and `table.zig` as main 1684f645a) | aa3994b |
| fix3 | base plus fix 3 | aa3994b |
| fix2 | #832 | aa3994b |
| base-ct | base | checker-tasks ad9ad36 (aa3994b plus `checkerpool.rig`) |
| fix2-ct | #832 | checker-tasks ad9ad36 |

**E-cores.** Cores 18-19, 20 perf runs per arm, rotated. Release builds
were running on 12-17. Raw data: [ecore-counts.txt](table-arena-data/ecore-counts.txt).

| project | checkers | fix2 instructions | fix2 task-clock | fix2-ct instructions | fix2-ct task-clock |
|---|---|---|---|---|---|
| empty | 1 | 0.9% fewer | 1.8% less | 1.2% fewer | 2.8% less |
| empty | 4 | 3.7% fewer | 4.9% less | 4.1% fewer | 4.2% less |
| mitt | 1 | 0.8% fewer | 0.7% less | 1.0% fewer | 3.8% less |
| mitt | 4 | 3.5% fewer | 1.6% less | 4.7% fewer | 1.7% less |
| neverthrow | 1 | 0.8% fewer | 1.0% less | 0.9% fewer | 0.1% less |
| neverthrow | 4 | 3.4% fewer | 3.6% less | 3.2% fewer | 1.4% less |
| zod3 | 4 | 0.3% fewer | 1.6% less | 0.4% fewer | 1.9% less |

At 4 checkers, kernel instructions fall 18-23% and kernel cycles 5-12%.

**P-cores.** One checker runs on core 6; four run on 0, 6, 8 and 10, with
their siblings idle. Each arm's binary was copied fresh first, and the
order was rotated over 20 rounds. Some rounds waited for a stray process
on the timing cores to finish. Table: [pcore-times.md](table-arena-data/pcore-times.md);
raw: [times.txt](table-arena-data/times.txt).

| project | checkers | fix2 wall median | fix2 instructions | fix2-ct wall median | fix2-ct wall fastest | base-ct wall median |
|---|---|---|---|---|---|---|
| empty | 1 | 3.2% less | 1.7% fewer | 0.6% more | 2.0% less | 1.1% less |
| empty | 4 | 1.1% less | 3.7% fewer | 3.9% less | 7.0% less | 0.4% more |
| mitt | 1 | 1.9% more | 0.1% fewer | 0.4% less | 1.6% more | the same |
| mitt | 4 | 1.2% more | 1.8% fewer | 1.6% less | 5.0% less | 0.2% less |
| neverthrow | 1 | 1.3% less | 3.0% fewer | 1.4% less | 3.4% less | the same |
| neverthrow | 4 | 0.2% less | 3.0% fewer | 4.5% less | 2.1% less | 1.3% less |
| zod3 | 4 | 1.3% less | 0.4% fewer | 2.8% less | 1.0% less | 2.1% less |

- **Against the bar** (more than 1.5% faster, or at least 1% fewer
  instructions, with peak RSS no higher): #832 clears it on instructions
  on the small projects at 4 checkers. Its wall times at 25-33 ms are
  within the run-to-run noise of about 2%.
- **Stacked with checker-tasks** (Merges' fix 1), the gain shows in wall
  time: at 4 checkers, 1.6-4.5% less than base by the median, against
  base-ct's 0.4% more to 2.1% less. Making the checkers in tasks pays
  once their 172 reservations no longer take the process's `mmap_lock`
  one after another.
- **Peak RSS** is level: within 0.3% at 4 checkers, and 1.2% lower on
  mitt at 1. An earlier apparent rise of 1.5-3.7 MB was the executable's
  own file pages (RssFile): a binary written more recently had more of
  its pages in the page cache. RssAnon was the same. Every arm is now
  copied fresh before it is timed.

## Runtime benches

bench/tasks, actors, net and http (rig-fast) ran for base and #832, 10
rounds with the order reversed each round, 3 reps a run, on P-core 6 and
its sibling 7 ([runtime-benches.txt](table-arena-data/runtime-benches.txt)).
Every row is level within 1 unit or 2.6%, except actors `contend`: 15 ns
where base gives 14, in all 10 rounds of each. That row was accepted by
the owner as layout, 2026-10-31. The evidence:

- Both binaries make the same system calls: one segment, advised for
  huge pages, and one reading of `/proc/buddyinfo`.
- They retire the same instructions to within 0.2% (208.1M against
  207.9M).
- The code that changed (`hugeFreeFor`) runs only when a segment is
  made, never in the loop being timed.
- The arena code is not linked into a program without Tables.
- What differs is placement: the data section moved by 384 bytes, and
  the hot scheduler globals in `.bss` stayed where they were.
- On E-cores 16-19, eight interleaved runs give `contend` medians of
  43.7 and 45.5 ns, with each spread wider than that gap.

## Tests

- Zig unit tests in `alloc.zig`, all passing on pup in debug, safe and
  fast:
  - a burst of 43 Tables reads `/proc/buddyinfo` once, and a reading
    older than its life is read again;
  - a kept reading tells a segment no, a yes is read afresh, and its
    blocks are taken from the kept count;
  - a burst takes 2 MiB-aligned ranges of one region and gives them back
    to the region's rest;
  - a range given back has no resident pages, and the next Table to take
    it reads zeros;
  - huge-page advice is given past the first 2 MiB while blocks are free,
    and taken back once the range is given back.
- A release case in `test/rig/table.rig.test`: reserved tables of 512 MiB
  and 3 MiB, made, written and dropped 300 times, each start as zeros.
  On pup, the program made 600 `madvise` calls and 5 `mmap` calls; each
  Table had made its own `mmap`, `madvise` and `munmap` before.

The scripts are in [table-arena-data/](table-arena-data/).
