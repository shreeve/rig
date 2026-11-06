# The huge-page test follows the system's mode, and counts one node (2026-11-06)

Item 6 of the huge-page panel ([panel/SYNTHESIS.md](panel/SYNTHESIS.md)):
two small correctness fixes to the release allocator's huge-page test
(`src/alloc.zig`), linux.md's P2 and P3, which the critic marked PURSUE
as correctness on users' machines with no speed claim. The owner
approved both. Nothing changes on pup (`enabled=madvise`,
`defrag=madvise`, one node).

## P2: the mode, read once

Linux 7.0's `vma_thp_gfp_mask` decides, per fault, whether a fault that
finds no free 2 MiB block compacts in the fault. By `defrag`:

| `defrag` | a range that asked (`MADV_HUGEPAGE`) | a range that did not |
|---|---|---|
| `always` | compacts, and retries | compacts, no retry |
| `defer+madvise` | compacts | wakes kcompactd |
| `madvise` | compacts | takes a free block or none |
| `defer` | wakes kcompactd | wakes kcompactd |
| `never` | takes a free block or none | takes a free block or none |

Whether a range that did not ask gets huge pages at all is `enabled`:
`always` yes, `madvise` no, `never` no range does. From Linux 6.8,
`hugepages-2048kB/enabled` sets it for 2 MiB pages alone, unless it says
`inherit`, its default; the allocator reads it where it exists.

So the test in front of every request (`hugeFree`, `hugeFreeFor`) is
needed only where asking turns a fault into a compacting one, and asking
is how a range gets huge pages only under `enabled=madvise`. Under
`enabled=always` Rig's request does nothing but add the stall; and the
ranges Rig meant to keep small (segments of a heap that does not fault
in ahead, large blocks of 2 to 16 MiB, each Table's first 2 MiB) got
huge pages there, which alloc-thp16 and alloc-seg-thp measured as
higher peak memory.

The allocator reads `/sys/kernel/mm/transparent_hugepage/enabled` and
`defrag` once (`thpMode`, the word in brackets of each) and decides each
request by one table (`adviceFor`):

| want | `never` | `madvise`, `defrag` that compacts | `madvise`, `defer`/`never` | `always`, `defrag` that compacts | `always`, `defer`/`never` |
|---|---|---|---|---|---|
| huge, a fresh range | nothing | ask behind the test (as before) | ask, no test | nothing | nothing |
| huge, a range that may have said small | nothing | ask behind the test | ask, no test | ask behind the test | ask, no test |
| small | nothing | nothing (as before) | nothing | `MADV_NOHUGEPAGE` | `MADV_NOHUGEPAGE` |

"Ask again" is for a large block that `mremap` grows to 16 MiB from a
block of 2 to 16 MiB, which asked for small pages: the range keeps the
advice of the block it grew from, and madvise has no advice that clears
`MADV_NOHUGEPAGE`, so only asking for huge pages undoes it. A block of
16 MiB or more asked for nothing, and grown asks for nothing again, so
its faults do not compact. A file that cannot be read, or names no mode, is
taken as `madvise`/`madvise`, today's behavior.

Where the decision is applied:

- a new segment: huge for a heap that faults in ahead, small for one
  that does not (`Heap.newPage`);
- a new large block: huge from 16 MiB, small from 2 MiB (`allocLarge`);
- a block grown by `mremap`: huge again to 16 MiB, small to 2 MiB from
  less (`remap`);
- a reserved Table: under `always` its region is left unadvised, its
  first 2 MiB ask for small pages, and a dropped Table's range is
  mapped afresh with `MAP_FIXED`, which gives its pages back and leaves
  it unadvised (`reserveTable`, `unreserveTable`, `newTableRegion`).
  Before Linux 6.12 a `MAP_FIXED` that fails may leave the range
  unmapped, a hole inside the region's bounds where the system could
  later put any mapping, which `unreserveTable` would then take for a
  Table's. So a range that cannot be mapped afresh is never handed out
  again: it is filled with a `PROT_NONE` mapping by
  `MAP_FIXED_NOREPLACE`, and if that fails too it is kept in a list of
  16 holes that `unreserveTable` takes for no Table's; past 16 the
  program panics (`loseTableRange`). Under `madvise` and `never` the region keeps its
  one `MADV_NOHUGEPAGE`, as before, so ranges given back merge with it;
- `table.zig`'s own mapping (a debug build's, or a Table the region
  cannot place) asks by `hugeFree`, which holds under `madvise` alone;
  under `always` it maps all of it small, with no stall.

The mode is read once per process, on the first request of either
kind, so a program that makes any segment opens the two files once
(a few microseconds).

## P3: the asking thread's node

`freeHugeBlocks` summed blocks of order 9 and up over every node. A
THP fault first tries its own node (`__GFP_THISNODE`, compacting there
under NORETRY) before it takes another's, so on a host of two sockets
whose free blocks are all on the other node the summed count opened the
test while every fault compacted locally. The count is now of the lines
of the node `getcpu` names; every node's where the reading has one node
(no `getcpu` call, so a one-node host behaves as before), where `getcpu`
fails, or where the node has no lines (a node with no memory, whose
faults take another's). A reading that fills its 4 KiB buffer, about 30
nodes or more, may have lost the node's lines: then it counts none,
never the other nodes'. The kept reading, which answers the test for
4 ms, carries the node it counted in 8 bits taken from its count, so
the kept count caps at 65,535 blocks (128 GiB, far past every
threshold, and a reading taken now answers uncapped); a kept
reading of one node answers only a thread on it. A node past 254 keeps
no reading.

## Tests

On every host (`zig build test` on the Mac):

- `thpModeOf` on each `enabled` and `defrag`, with
  `hugepages-2048kB/enabled` absent, `inherit`, and its own mode, and on
  files that name no mode;
- `adviceFor` for every pair of `enabled` × `defrag` and each want;
- `freeHugeBlocks` on a two-node reading for node 0 (10), node 1 (300),
  a node with no lines and no node (310), and on a one-node reading for
  either node; a reading cut short before node 1's lines counts none
  for node 1; `oneNode`, `nodeOf`.

On Linux (run natively on pup after the merge):

- a kept reading of a two-node host answers only its node, one of a
  one-node host any;
- under `never` nothing asks and /proc/buddyinfo is not read;
- under `madvise`/`defer` everything asks with memory fragmented and no
  reading;
- under `always` a leading heap's segment and a 16 MiB block ask for
  nothing, a lone heap's segment, an 8 MiB block, and a Table's first
  2 MiB ask for small pages, a Table given back is unadvised and reads
  zeros, and an 8 MiB block grown to 32 MiB asks again behind the test;
- under `always`, with the mapping afresh made to fail (unmapping the
  range, as Linux before 6.12 may): the range is filled `PROT_NONE`; with
  the fill made to fail too, it is kept as a hole, a mapping later put
  there is not taken for a Table's, and neither range is handed out
  again.

The existing Linux tests run under `madvise`/`madvise` as before
(`useBuddyinfoForTest` sets it).

## Gates (Mac, 2026-11-06, after the review's fixes)

- `zig build test`: 305 passed, 18 skipped (the Linux cases among
  them); the test binaries for x86_64-linux and aarch64-linux compile.
- The core suite (`swarm test/rig.rip -w 6`): 11,529 jobs, none died.
- `tools/emit-diff 4573e9f4f`: only `rig/alloc.zig` differs, in the 32
  programs that carry it; no program's own Zig changes.
- A release program with a Table and a 40 MB List, emitted and built
  for x86_64-linux and aarch64-linux, ReleaseSafe and ReleaseFast
  (before the fixes).
- `bench/json/guard.py`: all six files within 0.1% of `guard.txt`.
- `bench/hash/guard.py`: every row within 0.1% or fewer instructions
  (the text rows 2.4-20.3% fewer, from main's `bytesEql`, not this
  change).
- `bench/text/guard.py`: every row 0.1-0.6% fewer instructions.
- loco's light gate: GREEN (7 unit tests, 51 checks, 122 runs
  byte-identical to the Rust loc).
- Trig's light gate on the Mac (Trig 9802432): GREEN, 27 jobs, none
  died.

The guards run on the Mac, where none of this code is compiled in (each
path is behind `builtin.os.tag == .linux`), so they show only that
nothing else moved. The light gates run on the Mac too, so they check
the runtime builds and runs with every program, not the Linux paths.

## Left for pup, after the merge

- `zig build test` natively, so the Linux cases above run.
- Trig's ts-pattern under `madvise`: `thp_fault_alloc` and
  `compact_stall` from /proc/vmstat around a run, level with main.
