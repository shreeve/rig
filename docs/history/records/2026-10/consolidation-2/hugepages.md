# Huge pages for large tables: measured, not taken (2026-10-25)

**Question.** Rig's runtime reserves each `Table` with `MADV_NOHUGEPAGE`
(`src/table.zig`, `reserve`). Trig's ts-pattern makes 27 such
reservations, and its large written tables hold about 88 MiB. Trig takes
3.2 times tsrs's dTLB misses, and tsrs advises its arena
`MADV_HUGEPAGE`. Would huge pages for the large tables make Trig faster?

**Answer.** Not by enough. Asking for huge pages past a table's first
2 MiB made ts-pattern with one checker 2.4% faster by task-clock, and
2.3% faster on top of the prefault change (`prefault-busy`). It made
zod3 0.9% slower, and with all cores gave ts-pattern nothing on top of
prefault. Asking for them over the whole table gained up to 5.2% on
ts-pattern, but raised peak RSS by 49% with all cores (377 to 562 MB),
and zod3's by 144% (136 to 332 MB). Neither clears the bar in AGENTS.md
(a real gain on Trig, never slower elsewhere). The code stays as it is.

## What was tried

Two rules, both on Linux only:

- **past**: a reservation larger than 2 MiB is aligned to 2 MiB; its
  first 2 MiB keep `MADV_NOHUGEPAGE`, so a table touched only at its
  start commits small pages; the rest is advised `MADV_HUGEPAGE`.
  Smaller tables keep `MADV_NOHUGEPAGE`.
- **whole**: a reservation of 2 MiB or more is aligned to 2 MiB and
  advised `MADV_HUGEPAGE` whole.

The alignment over-reserves by 2 MiB and unmaps the slack at each end,
so `unreserve` is unchanged. The `past` patch, for anyone who returns to
this:

```zig
const huge: usize = 2 << 20;

fn reserve(bytes: usize) [*]align(page) u8 {
    const linux = builtin.os.tag == .linux;
    const large = linux and bytes > huge;
    const span = if (large) bytes + huge else bytes;
    const m = std.posix.mmap(null, span, ...) catch reservePanic(bytes);
    if (!linux) return m.ptr;
    if (!large) { madvise(m.ptr, m.len, NOHUGEPAGE); return m.ptr; }
    const head = alignForward(@intFromPtr(m.ptr), huge) - @intFromPtr(m.ptr);
    if (head > 0) munmap(m[0..head]);
    if (head < huge) munmap(m[head + bytes ..]);
    const p = m.ptr + head;
    madvise(p, huge, NOHUGEPAGE);
    madvise(p + huge, bytes - huge, HUGEPAGE);
    return p;
}
```

## pup's policy

`/sys/kernel/mm/transparent_hugepage/enabled` is `always [madvise]
never`, and `defrag` is `always defer defer+madvise [madvise] never`
(kernel 7.0.0-38). Only an advised range gets huge pages, so today's
`MADV_NOHUGEPAGE` changes nothing on pup; it guards hosts set to
`always`. An advised fault compacts synchronously when no 2 MiB block
is free. Every smaller huge page size (16 KiB to 1 MiB) is `never`.
Across the session the Normal zone had 0 to 54 free 2 MiB blocks, yet every advised
fault got a huge page (`thp_fault_fallback` 0 per run) with 0 to 2
compaction stalls per run. The 13% loss of the earlier trial
(docs/internals/backlog.md) was the allocator's segments advised while
pup's memory was fragmented and short; here 3 to 22 GB were free.
No system setting was changed.

## Numbers

Rig main (12b0bdc88) against each arm, Trig main (a16e538, src and
tools/trig/main.rig) built `rig build --release` with each, on pup.
`pf` is the prefault change as it stood uncommitted in
`/zfs/worktrees/rig/prefault/fix` (alloc.zig only); `both` is `pf` and
`past`, `bothw` is `pf` and `whole`. Every arm prints the same output.

**One checker, cycles** (`--checkers 1`, core 8, sibling 9 idle,
interleaved, fastest of 15; dTLB and faults the median):

| project | arm | task-clock ms | user cycles | kernel cycles | user instr | dTLB misses | faults |
|---|---|---:|---:|---:|---:|---:|---:|
| ts-pattern | main | 1174.1 | 5.077G | 0.501G | 12.751G | 2.01M | 80,927 |
| ts-pattern | pf | 1152.8 | 5.032G | 0.462G | 12.751G | 1.98M | 37,683 |
| ts-pattern | whole | 1142.8 | 5.029G | 0.415G | 12.755G | 1.48M | 58,393 |
| ts-pattern | past | 1145.7 | 5.042G | 0.418G | 12.751G | 1.80M | 63,133 |
| ts-pattern | both | 1126.8 | 4.994G | 0.377G | 12.755G | 1.75M | 19,888 |
| ts-pattern | bothw | 1113.3 | 4.945G | 0.367G | 12.751G | 1.41M | 15,149 |
| zod3 | main | 219.7 | 0.928G | 0.115G | 2.305G | 0.23M | 19,588 |
| zod3 | pf | 212.9 | 0.910G | 0.106G | 2.306G | 0.23M | 8,448 |
| zod3 | whole | 218.8 | 0.921G | 0.126G | 2.304G | 0.16M | 16,474 |
| zod3 | past | 221.7 | 0.932G | 0.116G | 2.305G | 0.23M | 18,965 |
| zod3 | both | 214.7 | 0.917G | 0.106G | 2.300G | 0.22M | 7,825 |
| zod3 | bothw | 216.3 | 0.918G | 0.115G | 2.303G | 0.16M | 5,334 |

**One checker, wall** (core 8, interleaved, fastest of 10; the wall
includes `perf` and `time` around the run; sys the fastest, RSS the
median peak). A second round, run while pup grew busy, is in brackets.

| project | arm | wall s | sys s | RSS MB | huge pages per run |
|---|---|---:|---:|---:|---:|
| ts-pattern | main | 1.227 [1.258] | 0.10 | 325 | 0 |
| ts-pattern | pf | 1.210 [1.236] | 0.08 | 339 | 0 |
| ts-pattern | whole | 1.199 [1.225] | 0.07 | 364 | 64 |
| ts-pattern | past | 1.209 [1.254] | 0.08 | 329 | 37 |
| ts-pattern | both | 1.191 [1.216] | 0.07 | 343 | 37 |
| ts-pattern | bothw | 1.179 [1.249] | 0.07 | 379 | 64 |
| zod3 | main | 0.249 [0.300] | 0.02 | 85 | 0 |
| zod3 | pf | 0.243 [0.278] | 0.01 | 90 | 0 |
| zod3 | whole | 0.250 [0.307] | 0.02 | 133 | 30 |
| zod3 | past | 0.246 [0.303] | 0.02 | 89 | 3 |
| zod3 | both | 0.242 [0.300] | 0.01 | 94 | 3 |
| zod3 | bothw | 0.242 [0.302] | 0.02 | 138 | 30 |

**All cores** (Trig's default 4 checkers on cores 0-2, 5, 8-21;
interleaved, fastest of 10, median in brackets):

| project | arm | wall s | sys s | faults | dTLB misses | RSS MB | huge pages |
|---|---|---:|---:|---:|---:|---:|---:|
| ts-pattern | main | 0.565 [0.587] | 0.16 | 94,494 | 2.45M | 377 | 0 |
| ts-pattern | pf | 0.535 [0.584] | 0.15 | 89,494 | 2.23M | 378 | 0 |
| ts-pattern | whole | 0.544 [0.566] | 0.15 | 70,434 | 1.27M | 562 | 140 |
| ts-pattern | past | 0.540 [0.557] | 0.15 | 82,101 | 2.06M | 392 | 32 |
| ts-pattern | both | 0.538 [0.571] | 0.13 | 77,082 | 2.00M | 393 | 32 |
| ts-pattern | bothw | 0.559 [0.575] | 0.15 | 65,435 | 1.28M | 564 | 140 |
| zod3 | main | 0.198 [0.210] | 0.06 | 32,867 | 0.54M | 136 | 0 |
| zod3 | pf | 0.172 [0.199] | 0.04 | 28,497 | 0.42M | 138 | 0 |
| zod3 | whole | 0.195 [0.217] | 0.07 | 27,719 | 0.28M | 332 | 108 |
| zod3 | past | 0.194 [0.198] | 0.05 | 32,867 | 0.44M | 136 | 0 |
| zod3 | both | 0.175 [0.195] | 0.05 | 28,496 | 0.47M | 137 | 0 |
| zod3 | bothw | 0.208 [0.222] | 0.06 | 23,346 | 0.32M | 333 | 108 |

## What the numbers say

- **The TLB was never the cost.** ts-pattern takes about 2 million dTLB
  load misses in 5 billion user cycles. Huge pages cut them by a quarter
  (`whole`) or a tenth (`past`), and user cycles by under 1%, with user
  instructions unchanged. The gain that shows is in the kernel: fewer
  faults (0.501G to 0.418G kernel cycles for `past`), which the prefault
  change already takes much of.
- **What a table commits is the cost of `whole`.** Each table touched
  at all commits 2 MiB, and each checker has its own tables, so RSS
  grows with the checkers: zod3 with 4 checkers went from 136 to 332 MB.
- **`past` is cheap in memory** (1% to 4% more RSS) but its gain, 2.4%
  on one project with one checker, does not hold on zod3 or with all
  cores.
- A3's estimate (4-6% of ts-pattern) assumed tsrs's gain came from the
  TLB; tsrs's huge pages are on its arena, which holds most of its
  heap, not on 27 tables of which few are written past their first
  2 MiB.

## The Mac

macOS has no transparent huge pages. Its one form, `mmap`'s
`VM_FLAGS_SUPERPAGE_SIZE_2MB`, is for x86-64 only and wires the whole
range when it is mapped, so it cannot back a lazily zeroed reservation;
nothing cheap applies. Both rules are compiled only for Linux: Trig
built on the Mac by main's Rig and by the `past` Rig has an identical
`__text` (8,456,876 bytes, same hash; the files differ only in their
UUID and signature), so the Mac was not timed.

## bench/tasks

`bench/tasks/tasks.rig` makes no table. Built `--release=fast` on pup
with main's Rig and the `past` Rig, its disassembly is identical, so
the change cannot move it.
