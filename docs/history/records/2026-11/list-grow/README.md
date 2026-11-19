# A List grown past 16 MiB on macOS (2026-11-19)

[qsort-mac](../qsort-mac/README.md) found that on macOS a List growing past 16 MiB was copied into a
fresh mapping, with no `mremap` to use, while libmalloc's large realloc grows in place. Together with
the first touch of fresh memory, that was about 6% of fork.rig's qsort critical path at 10 workers.
This record measures whether Linux has the same cost, describes the fix built for macOS, and gives
its boards.

## Linux: already ahead of Rust

[grow.rig](grow.rig) times one growth in a fresh process, and [rust/](rust/src/main.rs) is its twin
(`Vec`, glibc). The cases:
- `span`: a full List of 1,886,750 Ints (15.1 MB, under 16 MiB) extended by as many.
- `map`: 2,097,152 Ints (16 MiB) extended by as many.
- `push`: 2^22 pushes into an empty List.

Measured on pup, Rig 586e3939a, core 6, slot 641 (quiet honoured), 20 interleaved runs, medians in ms
(`data/gbp.txt`):

| case | Rig | Rust | system calls (strace, one run) |
|---|---|---|---|
| span | 4.25 | 4.99 | Rig: no `mremap` (a fresh mapping and a copy) |
| map | 2.36 | 5.55 | Rig: one `mremap` |
| push | 5.16 | 9.33 | Rig: one `mremap` |

Linux's `mremap` already moves a mapping's pages. A span that crosses 16 MiB is copied there too, but
Rig is still faster than Rust in every case, because its new block is aligned for huge pages and
prefaulted. Nothing is changed on Linux.

## The fix on macOS

`movePages` (src/alloc.zig) moves pages the way `mremap` does:
1. Map a fresh range of the new length.
2. Map the old block's whole pages into the start of that range with `mach_vm_remap` (copy false,
   `VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE`), so the new range shares them.
3. Leave the old range: a mapping of its own is unmapped; a span's pages inside its span segment are
   mapped afresh in place (zero, not resident), so the span segment stays mapped and the new range
   holds the pages alone.

It is used in two places:
- **A mapping of its own that grows**, when no kept block fits it, where it used to return null and
  leave the caller to copy.
- **A span that grows past 16 MiB into a fresh mapping**, when the span starts on a page (16 KiB). On
  the Mac spans are carved in 4 KiB units, so a span can start mid-page. One that does is still
  copied. A fresh span segment's first span starts on a page, as do the large Lists of a heap that
  has just taken its segment.

The bytes after the last whole page are copied. If refreshing the old range fails, the new range is
mapped afresh and the caller copies everything, so neither range shares the other's pages. A first
version also moved pages when a span grew into a fresh *span*, which can start mid-page. The test
"four threads take, write, grow, and free spans" caught it at once: the move overwrote neighbouring
spans. The move now runs only into a mapping of its own.

**Memory:**
- No address space is reserved ahead.
- The new range is the length the copy's new block had.
- The old pages are not duplicated: they move.
- A grown mapping's old block used to be kept resident within the heap's keep bound; now it is gone.

fork.rig's peak RSS (`/usr/bin/time -l`, 5 interleaved runs, `data/rss.txt`) is level:

| workers | main | new |
|---|---|---|
| 1 | 845 MB (764-895) | 818 MB (759-852) |
| 10 | 723 MB (686-785) | 730 MB (674-774) |

## Boards on the Mac

Apple M5, Rig main b7bb1df1d against the branch. Every timed run was inside `tools/mac-claim`, while
the Mac carried other sessions' work (load 4-6).

**Growth micro:** 15 rounds, medians in ms (`data/micro.txt`).

| case | main | new | Rust |
|---|---|---|---|
| span | 2.26 | 1.08 | 1.16 |
| map | 2.41 | 1.21 | 1.19 |
| push | 4.34 | 2.59 | 3.32 |

**fork.rig:** fork-order's fork.rig, each Rig arm at three placements, with an A/A copy of main at
p1. p1 and p2 add one and two never-taken prints after qsort's, as qsort-mac's shift/ does
([p1.rig](p1.rig), [p2.rig](p2.rig)). Rayon is fork-order's twin.
- qsort at 10 workers, 40 rounds, 10 workers only (`data/w10.txt`, `data/b10.py`):
  - Each arm's median: main 62.73, 57.06 and 57.64 ms across the three placements; new 53.89, 55.16
    and 54.88; A/A 56.93; Rayon 56.36.
  - Median of the placements: new/main 0.952.
  - Paired by round, new/main per placement: 0.872, 0.966, 0.939. A/A/main1: 1.032 paired, 0.998 by
    medians.
  - Against Rayon, paired: new 0.960-0.975, main 0.999-1.107.
- Both rows at 1 and 10 workers, 20 rounds (`data/fork.json`, qsort-mac's `pboard.py`), medians of
  the placements:
  - qsort at 1 worker: new/main 0.990, A/A 1.004.
  - qsort at 10 workers: new/main 0.941, A/A 0.954.
  - psum at 1 and 10 workers: level within the A/A arm.

**Guards:** run with the branch's `bin/rig`, both pass.
- bench/json/guard.py: within 0.1% on all six files.
- bench/hash/guard.py: within 0.3% on every row, text-churn 1.1% fewer instructions.

**The std sort board:** std-sort's `ab.py`, which keeps the fastest of 20 rounds, in ns per element
(`data/sort.txt`). Every row is within 1%: sorted Ints of 16 0.987, texts 1.000 and 1.001, records
reversed 1.000, random Ints 1.005, random records of 65,536 1.009. The sort's buffers stay under
16 MiB, so this path never runs.
