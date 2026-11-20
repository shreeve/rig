# Spawn after the fork-join stack (2026-11-19)

The fork-join stack (#1157-#1175) beat Rayon on every row of the fork
board but made a plain spawn (`f()&` that is not a fork) slower. This
record is how that was found, fixed past its old speed, and checked on
Trig and the Mac. Boards on pup ran in ab slots on P-cores 0-11 with an
A/A arm, rotated rounds, medians, and bench/tasks at two placements
(two never-taken prints appended to `main`). Raw output is in
[raw/](raw/), the scripts in [scripts/](scripts/).

## The cause

The stack made the wake shared by forks and plain spawns
(`wakeQueued`) an `inline fn`, so the whole wake was pasted into
`spawnApart`: 432 bytes before, 1,747 after on x86 (82 and 430 lines on
arm64). Alongside, the record was built by a call and copied in, so it
was written twice (5% more instructions, 15% more L1 data misses), and
it grew from 432 to 464 bytes, from 7 cache lines to 8.

## The fixes

| PR | What | pup, spawn per task (bench/tasks) |
|---|---|---|
| (stack) | before #1181 | 150 / 147.5 ns (pre-stack 124.5 / 137.5) |
| #1181 | plain spawns call `wakeIn` (never inlined); the record filled where it lies; `Header.cancel` passed by the waiter, the record 448 bytes | 129.5 / 131 ns |
| #1183 | no alignment check on a record; a task made while every run-next slot is full goes to the ring's tail (one locked store a spawn, not two); a record's size class found at compile time, its free list popped inline | **103 / 104.5 ns** |

[raw/finalboard.txt](raw/finalboard.txt) holds #1183's board against
#1181's runtime: spawn 21% faster, hog 19% faster, spawn alone 23% faster
at one worker (102.3 to 78.8 ns; instructions 969 to 758) and 10% at 12
workers (124.7 to 112.5 ns). The fork board is level or faster: qsort at
one worker 3% faster, psum at 12 workers 4% faster. Actors are level.

Dropped, each for gaining nothing measurable:

- one wait per search pass (f95c21aff). It read qsort at one worker
  9% slower, but its code never runs at one worker: `search` grew 80
  bytes and moved the fork's whole hot path ([raw/leanboard.txt](raw/leanboard.txt);
  nm of the pup binaries showed the burst arm's fork code at the same
  addresses as main's).
- reading the clock once every 16 pauses (f38e73737; `clock_gettime`
  through the vDSO was 2.9% of cycles): 81.5 against 78.8 ns.
- a per-worker cache of clean records: 150-200 lines and 18 fields reset at
  a task's end for 1-3%, most of which the inline free list took.

## Where the time goes (Amdahl)

[raw/spawn-amdahl.md](raw/spawn-amdahl.md), from
[raw/spawnprof.txt](raw/spawnprof.txt). One spawn's own work never
regressed: about 100 ns at one worker in every version. The stack's cost
was coordination among 12 workers. Its two largest shares are contended
atomics (11.5% of cycles: the run-next slot's `xchg`, the ring tail's
seq_cst store, the global `searching` line) and idle spinning in
`search` (63% of it `pause`). Filling the record was 1.7%. The size-class
lookup, at 2.3% of cycles, turned out worth 210 instructions a spawn.

## Trig

At 100 rounds #1181 read neverthrow c1 1.1% and tiny-invariant c4 1.4%
slower (A/A 0.9%), and #1183 about 0.7% slower on four of six projects at
c1. Instructions were flat on every row, and the owner accepted both. On
Linux the program's section (`rig_text`) follows the runtime's at 16-byte
alignment, so every runtime change moves all of Trig's code: five Trig
builds of the day put it at five different offsets.
[raw/trigalign.txt](raw/trigalign.txt) then measured main 636fd02a5
against fae440c77, the runtime of the morning: level (c1 all six within
the bar; c4 zod3 1.5% slower, A/A 1.2%). Pinning `rig_text` to 16 KiB on
Linux, as #1180 does on the Mac, read about 1% slower on four rows, and
was closed (tag `archive/elf-anchor`).

## Guards

On main 636fd02a5 (Mac, instructions): std.json within 0.3% of its
baseline on all six files, the hash tables within 0.2% on every row
(Map's text churn 1.1% fewer), text search within 0.1%.

## The Mac

- Fork board, 20 rounds ([raw/mac-fork-board.txt](raw/mac-fork-board.txt)):
  - qsort 8% faster than Rayon at one worker and 9% at ten;
  - psum 6% faster at ten workers;
  - psum at one worker level within noise (the A/A arm read 9% apart).
  - main is level with or faster than fae440c77 on all four.
- Task rows ([raw/mac-tasks-board.txt](raw/mac-tasks-board.txt)):
  - chain, fanout, yield and produce are level, and hog is 3-7% faster;
  - spawn reads slower: main 152 / 128.5 ns against fae440c77's 124 / 114.5.
- By merge, spawn alone ([raw/mac-spawn-by-merge.txt](raw/mac-spawn-by-merge.txt)):
  - at one worker, 66.6 ns (1,247 instructions) to 58.3 ns (999): 12% faster;
  - at ten workers, level through #1180 and #1173 (93-96 ns), then 116.1
    with #1181 and a bimodal 101-184 with #1183, with fewer instructions.

  The extra time is coordination on Apple cores, not work, and is being
  traced.

## Pingpong against Tokio, pup

[raw/pingpong-pup.txt](raw/pingpong-pup.txt) and
[raw/pingpong-pup-threads.txt](raw/pingpong-pup-threads.txt), 160,000 round trips:

| | Rig | Tokio |
|---|---|---|
| Time per trip | 4.86 µs | 4.74 µs |
| System calls per trip | 6.2: epoll 2.17, read 2.03, write 2.03, no EAGAIN | 7.0: epoll 2, recvfrom 3 (1 EAGAIN), sendto 2 |
| Threads | one thread runs both sides | two threads alternate |
| User / kernel time | 0.14 s / 0.68 s | 0.16 s / 0.65 s |

The 2.5% lies in the kernel, about 0.2 µs a trip. perf trace and perf
sched need tracefs, which pup does not grant without root.
