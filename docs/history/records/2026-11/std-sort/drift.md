# std.sort: the stable path at Rust's design (2026-11-16)

The owner asked, of Rust's 1.6 to 3.5 times lead on random input over
the buffered merge ([built.md](built.md)), "is something we can fix
now?"; his decision 5 is "fastest, within 2% of Rust's stable sort".
His rule for speed work: the fastest hand-tuned Zig first, measured
against the competitor, then Rig's std made to use exactly that.

Branch `sort-drift` on `sort-stable` (98e985cf4). Apple M5, macOS
(Darwin 27.2), Zig 0.17.0, Rust 1.99.1. ns per element, the fastest
of 15 interleaved rounds (each run the fastest of 3; every arm on
every row in a fresh shuffled order each round) under
`tools/mac-claim`, by [programs/dboard.py](programs/dboard.py), with
Rust's arm run twice as an A/A check (within 2% on every row but a
few text rows of 1 to 2 ns, where Rust's own two arms differ by up to
45%). Data and kinds as README.md: `rec` records by one key through
`sort_by`, `reco` the same by an own `order` through `sort`, `int`
Ints by `sort_by(|a, b| a < b)`, `str` text views the same way.

## The ceiling: driftsort in Zig

[programs/drift.zig](programs/drift.zig) is driftsort (Orson Peters
and Lukas Bergdoll, Rust's `core::slice::sort::stable`) written again
in Zig from its design: runs of sqrt(n) or more kept and merged in
powersort's order, shorter stretches left unsorted and merged lazily
while they fit in the scratch, then sorted by a stable quicksort
(pseudomedian pivot, branchless partition through the scratch, the
left-ancestor test that splits off a pivot's equals), small sorts by
sort-4/sort-8 networks, insertion, and a bidirectional merge, and
branchless merges. Its comparison count is Rust's exactly on every
input tried (21,929,697 on a million random records). Getting its
time to Rust's took:

- An eager run's length computed by `@min(32, len)` has type `u6`,
  so `n << 1` wrapped to 0: Zig's `@min` narrows to the comptime
  operand's type. Rust's sort of 32 records made 152 comparisons, ours
  183, until the result was typed `usize`.
- Pointer loops as Rust's (`ldr`, `csel`, `str`, `cinc` per element),
  the pivot copied to a local so no store reloads it, the partition's
  unrolled bound computed once, and the right part copied home
  reversed four at a time (as a vector of `u64` for 8-byte elements):
  partitions went from about 9 instructions an element to Rust's 6.
- Elements moved as integers (`u64`, `u128`) where their size is one:
  Zig moves an object of two fields through the stack when several are
  live, and reading it back before the store lands cost reversed
  records 72% and 16-valued records 20%.
- The data 64-byte aligned, as malloc aligns Rust's: 16-byte records
  at an 8-byte boundary read 20 to 30% slower on 16-valued input.
- Scratch from malloc, as Rust's: Zig's `smp_allocator` maps a large
  block fresh each time, which faulted 30% onto 65,536 Ints of 16
  values.
- No safety checks in the kernels (as Rust's run without bounds
  checks), including the small helpers that cast pointers: their
  `@ptrFromInt` and alignment checks were 8 instructions an element.

Text has a second fault, outside the sort: `std.mem.order` compares
byte by byte. Compared eight bytes at a time as big-endian words
(`textLess`, a `bool`), text sorts 1.4 to 2.3 times as fast as
Rust's, which calls `memcmp`.

[board-drift-ceiling.tsv](board-drift-ceiling.tsv) (Zig `-O
ReleaseFast` and `ReleaseSafe`, Rust `sort_by`):

| row | 1,024 | 4,096 | 65,536 | 2^20 |
|---|---|---|---|---|
| rec rand, Rust / Zig | 8.25 / 7.96 | 9.35 / 9.10 | 11.51 / 11.18 | 15.22 / 14.89 |
| rec dups | 3.12 / 2.81 | 2.78 / 2.63 | 2.86 / 2.88 | 3.53 / 3.40 |
| rec rev | 0.40 / 0.42 | 0.38 / 0.41 | 0.44 / 0.45 | 0.45 / 0.44 |
| int rand | 6.94 / 7.11 | 7.70 / 7.74 | 9.00 / 9.16 | 12.06 / 12.09 |
| int dups | 2.32 / 2.37 | 1.97 / 1.97 | 1.90 / 1.89 | 2.34 / 2.37 |
| int rev | 0.32 / 0.35 | 0.30 / 0.32 | 0.33 / 0.32 | 0.33 / 0.33 |
| str rand | 22.20 / 13.29 | 25.30 / 15.29 | 33.28 / 20.79 | 86.08 / 41.38 |

39 of the 48 rows are within 2% of Rust or faster. Slower: reversed
input of 1,024 and 4,096 elements, 7 to 8% (0.02 to 0.03 ns an
element: the reverse of a run, which Rust's slice `reverse`
vectorizes), and five rows 2.2 to 4.0% (16-valued Ints at 1,024,
random Ints at 1,024, sorted Ints at 2^20, sorted records at 65,536,
reversed records at 65,536), each under 0.2 ns an element.

## Rig's port

`std/sort.rig` holds the algorithm, as the ceiling's driver: the run
stack and powersort's depths, the lazy merge of unsorted runs, and the
stable quicksort's explicit stack, with each pivot kept by its bits in
the room's last 64 slots for the left-ancestor test. `std/sort.zig`
holds the loops that move elements between the slice and the room
while they compare them (a natural run, the small sort, the pivot,
the two partitions, a merge, and the merge sort that ends a quicksort
path after 2 log2(n) partitions): each checks the range it is given
and runs unchecked inside, and leaves every element of its range in
it exactly once whatever the comparator answers (a bidirectional
merge that finds the answers were no order copies its source back).
All are `inline`, and nothing recurses (the pseudomedian walks its
recursion's leaves in order, the same comparisons), so the closure is
inlined at each call as before. A pseudomedian out of line, recursive
as Rust's, measured twice as slow on every random and 16-valued row:
with the closure passed to a function not inlined, LLVM stopped
inlining it everywhere. Two limits differ from Rust's to keep the
frame the sort is inlined into under a page, where an x86-64 build
probes the stack (test/cli/preempt_section.sh found the probe called
from the program's section): powersort's depths are bytes, and a
quicksort path partitions at most 48 times before its merge sort,
where Rust allows 2 log2(n), more only past 2^24 elements.

A variant with the whole driver in Zig (a `drift_by` kernel, measured
and not kept) ran within 1% of this one on every row: the driver in
Rig costs nothing measurable.

Text `<` is now `rig.textLess` (emit and `rig.compare`), and `order`
`rig.textOrder` through it. An `Order`-returning compare left LLVM a
branch on the result in a safe build, a mispredicted branch per
comparison in the partition; with the `bool` the partition takes it
with no branch. Against `std.mem.order` (the port's first board,
[board-stable-drift-first.tsv](board-stable-drift-first.tsv), 8
rounds, before the text compare and the helpers' checks), random text
views sort 4.3 times as fast at 65,536 and sorted ones 6.3 times.

[board-stable-drift.tsv](board-stable-drift.tsv), `new` against the
buffered merge (`base`, #1114) and Rust's `sort_by` (Rust's two arms
within 1.3% of each other on every row but text):

| row | n | base | new | Rust |
|---|---|---|---|---|
| rec rand | 1,024 | 29.30 | 8.26 | 8.30 |
| rec rand | 2^20 | 52.04 | 15.28 | 15.38 |
| int rand | 1,024 | 24.73 | 7.41 | 7.01 |
| int rand | 2^20 | 43.85 | 12.49 | 12.25 |
| str rand | 2^20 | 137.18 | 44.66 | 85.64 |
| rec dups | 1,024 | 26.25 | 2.95 | 3.12 |
| rec dups | 2^20 | 34.91 | 3.51 | 3.49 |
| int dups | 1,024 | 22.68 | 2.55 | 2.32 |
| int dups | 2^20 | 30.64 | 2.38 | 2.34 |
| rec rev | 1,024 | 0.42 | 0.48 | 0.40 |
| rec rev | 2^20 | 0.45 | 0.47 | 0.45 |
| int rev | 1,024 | 0.40 | 0.34 | 0.33 |
| rec sorted | 2^20 | 0.23 | 0.24 | 0.23 |

Against the buffered merge every random and 16-valued row is 3.3 to
15 times as fast, text 2.2 to 6.6 times (it gains the compare too),
reversed Ints 12 to 17% faster; reversed records are 15 to 28% slower
at 1,024 and 4,096 (0.06 to 0.10 ns an element) and 5 to 7% from
65,536, and sorted input is level within 0.01 ns.

Against Rust, 49 of the 64 rows are within 2% or faster: text 1.4 to
2.5 times as fast (random text 1.6 to 1.9 times), random and
16-valued records within 1% or faster (16-valued records of 1,024
and 4,096 4 to 6% faster), sorted input within 1.8%, 16-valued Ints
from 65,536 within 1.6%. Slower: random Ints by 2.0 to 5.8%,
reversed Ints by 0.6 to 5.6%, 16-valued Ints of 1,024 and 4,096 by
6.3 to 9.9%, and reversed records by 21 to 25% at 1,024 and 4,096
(6 to 8% from 65,536).

**Where the port trails.** The kernels compile to the ceiling's code
(the partition, small-sort, and merge loops in the bench binary are
the ceiling's instruction for instruction), and the driver is not the
cost (the all-Zig variant). The rows left are small sorts and
reversed input. Per call, Rig's sort costs about 600 instructions more
than the ceiling's at 21 elements (its arrays zeroed, the room from
Rig's allocator, where Rust and the ceiling use a 4 KB stack buffer
below 4 KB of scratch): about 0.15 ns an element at 1,024, most of the
16-valued Ints' gap there. Reversed records are the reverse of one
run; the ceiling, with the same kernel, is 5 to 8% slower than Rust's
vectorized slice reverse at 1,024 and 4,096, and the port reads 0.06
ns an element more again, which this round did not place (a room from
malloc changed nothing; a reverse one element at a time was slower).
Shrinking the sort's frame (byte depths, 48 partitions) made the
random and 16-valued rows 1 to 7% faster than the board before it
([board-stable-drift-first.tsv](board-stable-drift-first.tsv) is the
port's first): a smaller frame for the `main` the sort is inlined
into, which suggests the Ints' remaining 2 to 6% is of the same kind.

## The unstable board

`sort` of identity types did not change in source, and its text rows
gain the compare: random, sorted, and reversed text 1.3 to 4.4 times
as fast, 16-valued text level
([board-unstable-drift.tsv](board-unstable-drift.tsv), 8 rounds).
Three rows read 2.4 to 4.6% slower there (Ints reversed at 4,096 and
2^20, objects sorted at 2^22); over 20 rounds with an A/A arm
([board-unstable-drift-ab.tsv](board-unstable-drift-ab.tsv)) every
row of those patterns is within the A/A's spread (the A/A itself up
to 4.2%, objects sorted at 2^22, where the new arm reads the same
4.2%). An earlier build of this branch read objects sorted at 65,536
and 2^20 4.1% slower in the bench binary and level in a program that
sorts only with `sort` ([programs/rsortu.rig](programs/rsortu.rig),
[board-unstable-drift-only.tsv](board-unstable-drift-only.tsv)):
placement, from the stable sort inlined into the same `main`, as
built.md found.
