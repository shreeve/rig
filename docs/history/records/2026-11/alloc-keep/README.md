# Pages the allocator keeps and does not use (2026-11-15)

Two changes to `src/alloc.zig`, each its own commit on the branch
`alloc-kept-age`, both from measurements by the Trig lead.

## 1. A kept large block that idles gives its pages back (`coolIdle`)

**Problem.** Trig's FileStore keeps `trees: List[File?]` beside the
program's file list while `take_tree` moves each tree out; the list is
then freed as one block of 16 MiB or more. A heap keeps freed blocks of
16 MiB or more for reuse within `keepBound`, and a heap that faults in
ahead keeps every one resident. Nothing later takes the list's blocks,
so mui at one checker held about 40 MiB of dead resident pages after
the front end (vmmap, the Mac).

**Rule.** A resident kept block gives its pages back (`decommit`) and
stays kept by address (`Heap.cold`) once its heap has taken from the
system as many new bytes as the block holds, since it was kept, and has
not taken it again. Each kept block's header records `Heap.taken` when
it was kept (`LargeFree.since`); `Kept.due` is the least `since + len`,
and `Heap.took` compares `taken` with it, so the rule runs only as the
heap takes new pages (a new segment, a carved span, a new mapping, a
growth by `mremap`).

**Why this rule.** A block used again soon (a List that grows, a buffer
used again, tables built and dropped again and again, the hash bench's
churn) is taken before the heap takes new pages, so it stays resident;
a steady state takes no new pages at all. A block that cools and is
taken again later faults its pages in once more, no more than the new
pages its heap faulted in meanwhile: at most twice the faults of a heap
that grows. An age by counted events would need a count on the hot
paths and a constant to tune; this one reuses `Heap.taken`.

**System calls.** None on a free or a reuse of a large block. One
`madvise` per block that cools, once per keep, at a `took` (itself after
an `mmap` or a segment's carve). On the Mac, a cooled block taken again
makes the existing `recommit` call (`MADV_FREE_REUSE`).

**Measured** on the Mac (Rig 42e4a0a42 as `base`, with the rule as
`new`). On macOS a page given back with `MADV_FREE_REUSABLE` leaves the
footprint at once but stays in RSS until the system takes it, so
`ps`'s RSS and `/usr/bin/time -l`'s maximum RSS do not move; the
physical footprint (vmmap's summary, `time -l`'s peak footprint) does.

- `dead.rig` (below): 600,000 records pushed into a List, popped into
  another, the first dropped, then 1.5 million Strings made; read while
  it sleeps: physical footprint 148.6 MB as `base`, 132.5 MB as `new`;
  the kept 16 MiB block's dirty pages 16.0 MB and 16 KB. A variant
  whose later work makes no List of 16 MiB or more (`dead2`) kept no
  block of 16 MiB or more as `base` either (127.1 MB both).
- Trig (main ffc14e476, `tools/check/build` with `TRIG_RIG_OVERRIDE=1`)
  on mui, `--singleThreaded`: peak memory footprint 919.6 MB as `base`,
  905.4 MB as `new`, in three runs each (14.2 MB lower, 1.5%); maximum
  RSS 935.7 and 937.2 MB; wall 2.57-2.82 s and 2.51-2.79 s on a loaded
  Mac; output identical. Sampled by vmmap, the mappings of 16 MiB or
  more (a 48 MiB and a 28 MiB region, 48.8 MB resident) held 11.2 MB
  less dirty at 1.6 s; at 2.2 s only 1.4 MB less, as a cooled block was
  taken again. The rest of the 40 MiB the Trig lead counted is not in
  kept blocks of 16 MiB or more: free spans under 16 MiB that a busy
  heap keeps warm within `spanBound` are the next place to look.

## 2. A heap's first segment keeps small pages (`segmentAsks`)

**Problem.** rig#1088 (72 size classes, not 44) made small
multi-threaded programs slower on pup: Trig on superstruct and mitt at
4 and 6 checkers (10 to 14 ms runs) 4 to 16% slower, RSS 54 to 65 MB,
kernel cycles 41 to 49 M, faults flat. A heap's class pages are carved
densely from its segment's start, a 64 KiB page per class, and every
segment asked for huge pages: the first pages of 72 classes reach past
a segment's two huge pages into a third, each mostly unwritten, so
each heap zeroed about 2 MiB more.

**Rule.** A segment asks for huge pages only once its heap has taken a
segment's worth from the system (`huge_segments_from`), so a heap's
first segment keeps small pages. Under THP `always` every segment still
gets huge pages unasked, as before.

**Measured** on pup (THP `madvise`, E-cores 12-19), a Zig driver of
`alloc.zig` (`driver.zig` below): five threads each take two blocks of
every small size step and `dense` KiB of 48-byte blocks; the run with
the fewest kernel cycles of 15. `base` is 42e4a0a42; `two` keeps a
heap's first two segments small; `one` is the rule taken.

| dense | arm | kernel cycles | task-clock | Rss | AnonHugePages | faults |
|---:|---|---:|---:|---:|---:|---:|
| 0 | base | 12.9 M | 6.21 ms | 31.2 MB | 30.7 MB | 376 |
| 0 | one | 9.9 M | 4.63 ms | 14.3 MB | 10.2 MB | 1,247 |
| 0 | two | 10.0 M | 3.76 ms | 7.1 MB | 0 | 1,334 |
| 2048 | base | 18.0 M | 8.91 ms | 41.4 MB | 41.0 MB | 381 |
| 2048 | one | 14.9 M | 7.49 ms | 24.8 MB | 20.5 MB | 1,306 |
| 2048 | two | 19.1 M | 8.18 ms | 17.6 MB | 0 | 1,425 |
| 8192 | base | 34.4 M | 18.10 ms | 72.1 MB | 71.7 MB | 396 |
| 8192 | one | 28.5 M | 16.79 ms | 55.5 MB | 51.2 MB | 1,310 |
| 8192 | two | 38.5 M | 19.42 ms | 55.1 MB | 30.7 MB | 1,425 |

A second round gave the same order (base 13.5/17.5/32.7 M, one
10.0/14.2/28.8 M, two 9.2/17.6/39.4 M). Keeping two segments small
saves more memory only for a heap that writes under 2 MiB, and costs up
to 15% more kernel cycles once it writes more, as its pages fault one
by one; one segment holds 16 MB less than base at every size, with
10 to 26% fewer kernel cycles. Trig's own timing on pup is the
coordinator's.

All of `alloc.zig`'s tests pass on pup (185 passed, 3 skipped, the
Mac's own), cross-built with `zig test src/alloc.zig -target
x86_64-linux --test-no-exec`.

## Gates

On the Mac, with both changes: `zig build test` in debug and in
release, green; the core suite (`swarm test/rig.rip -w 2`), 11,891
jobs, none died. The speed guards, each in a Mac claim, all within 2% of their
`guard.txt`: check 0.5% fewer instructions (2,147,327,174 against
2,157,462,149); json every file 0.0%; hash every row 0.0 to 0.1%, but
Map int-churn 0.7% and text-churn 1.2% fewer; text every row 0.0 to
0.1% fewer.
