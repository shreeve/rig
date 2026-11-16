# std.sort: the stable path as built (2026-11-16)

The owner chose the stable path directly on 2026-11-16: "a buffered
merge (allocates n, documented) or an in-place block merge ...
whichever is faster within 2% of Rust's stable sort, the in-place one
at parity". [README.md](README.md) measured candidate (a), the
buffered merge, as the faster on every row of 4,096 elements and up,
so (a) is what was built, with the record's second finding: a sort
that is inline throughout gets its closure's compare inlined.

Branch `sort-stable` from main 93e2fa4ec. Apple M5, macOS (Darwin
27.2), Zig 0.17.0, Rust 1.99.1. Same programs, data, and method as
README.md (`programs/rsort.rig`, `programs/rust/`): ns per element,
the fastest of 20 interleaved rounds (each run the fastest of 3),
under `tools/mac-claim`. `old` is main's compiler and std, `new` this
branch.

## What it is

`std/sort.rig`: `sort_by` (and through it `sort_by_key` and `sort` of
a type whose equal values may differ) finds natural runs, reverses a
strictly falling one, sorts each on to 32 elements by insertion
(whole-value swaps), and merges them in powersort's order (Munro and
Wild; the depth of a run boundary is the leading zeros of
`(a + m) * s ^ (m + b) * s`, `s = ceil(2^62 / n)`, as Rust's driftsort
computes it), on a stack of at most 64 runs. Each merge moves the
shorter run out to a room of `n / 2` elements, allocated at the first
merge that has work, and merges it back, front first or back first.
`sort_by`, `next_run`, `insert_by`, and `merge_by` are `inline`, with
no recursion, so the sort compiles into each call site and LLVM
inlines the closure: the bench binary has no closure thunk.

`std/sort.zig`: the room (`room_alloc`, `room_bytes`, `room_free`,
`room_slots`, aligned to 64 bytes, freed by `Room`'s drop, which drops
no element) and four moves that copy an element's bits and drop
nothing (`move_to`, `move_one`, `shift_one`, `pick_one`). A move only
ever writes a slot that holds no element and reads one that holds none
after, so for any comparator, consistent or not, each element ends in
the slice once (test "sort keeps every element under a comparator that
is no order"). A panic in the comparator runs no drop (SPEC §17), so an
element in the slice and the room at once is freed by neither; under
`task.isolate` the room's address, on the stack, is found and the room
counted as left by the panic, not leaked.

**The merge step.** A branchless step (`pick_one` selects the address
to load) was 20-25% faster than a branching one on random Ints and
records, but 30-50% slower on 16-valued input, where long streaks
predict well. The built step decides every 32 steps by how often the
run taken from changed in the last 32 (8 or more: select), starting
with select. Measured (exploration, 5 rounds, ns per element, 2^20):

| row | branch | select | adaptive (built) |
|---|---|---|---|
| rec rand | 61.68 | 47.44 | 49.36 |
| sint rand | 53.67 | 40.40 | 41.81 |
| rec dups | 30.76 | 44.55 | 33.63 |
| sint dups | 24.70 | 35.31 | 28.78 |
| sstr rand | 121.85 | 124.38 | 130.91 |

Text loses 5-7% to the branching step either way: its compare branches
inside, and the select serializes the steps that the branch lets the
processor run ahead on. Unchecked indexes in `pick_one` gained nothing
(the step is bound by its load-compare chain), so Zig's checks stay.

**`rig.order` of integers.** An own `order` by an Int key compared by
branches: `std.math.order` ends in a checked `unreachable` (for a NaN),
so LLVM could not fold `x.order(?y) == .less` into `x < y`. A plain
three-way test for integers, Bools, and enums (runtime `intOrder`)
made `reco` 46% faster at 2^20 random (74.21 to 50.73).

## The stable board

[board-stable-built.tsv](board-stable-built.tsv) has every row. Every
row of `new` is faster than `old`. Random input (old, new, Rust
`sort_by`):

| row | n | old | new | Rust |
|---|---|---|---|---|
| rec | 16 | 10.57 | 10.18 | 5.37 |
| rec | 4,096 | 93.41 | 33.46 | 9.42 |
| rec | 2^20 | 196.77 | 51.39 | 15.37 |
| reco | 4,096 | 79.27 | 32.35 | 9.35 |
| reco | 2^20 | 165.56 | 50.89 | 15.37 |
| sint | 16 | 17.07 | 8.55 | 5.10 |
| sint | 4,096 | 96.09 | 27.80 | 7.67 |
| sint | 2^20 | 188.53 | 42.66 | 12.02 |
| sstr | 4,096 | 136.09 | 65.33 | 25.25 |
| sstr | 2^20 | 299.76 | 136.00 | 86.14 |

Presorted input at 2^20 (old, new, Rust): rec sorted 1.69, 0.23, 0.23;
rec reversed 14.41, 0.45, 0.45; rec 16 values 67.59, 34.48, 3.49; sint
16 values 69.57, 30.01, 2.35; sstr sorted 7.83, 4.65, 1.64; sstr
reversed 51.29, 4.55, 1.86. 16 reversed elements: 6.59, 0.43, 2.69
(rec), 34.29, 4.04, 11.37 (sstr).

**Against Rust.** Level on sorted and reversed records and Ints, and
faster on 16 reversed elements; 3.3 times as slow on random records at
2^20, 3.5 on Ints, 1.6 on text, and 10 to 13 times on 16-valued input.
The owner's bar, within 2% of Rust's stable sort, is not met by either
candidate: driftsort sorts input without long runs by a stable
quicksort through the same n/2 buffer (16 values partition in a few
passes), with branchless partitions and small-sort networks. That
quicksort is the next step for the stable path; the merge here is its
merge.

## The unstable board

`sort` of identity types did not change in source, but in the bench
binary it shares `main` with the stable kernels, into which `sort_by`
is now inlined. [board-unstable-built.tsv](board-unstable-built.tsv)
(20 rounds, old and new): 66 of the 72 rows are within 2% or faster;
six read 2.0 to 3.9% slower (Ints random at 16 and 4,096, sorted at 16
and 2^20, 16-valued at 2^20, objects reversed at 256).

A 20-round A/B of those rows (ns per element) against the same
program with the stable kernels taken out (`uold`, `unew`: `sort` only)
and an arm of this std on main's runtime (`oldrt`):

| row | old | new | oldrt | uold | unew |
|---|---|---|---|---|---|
| int rand 16 | 7.91 | 7.98 | 8.00 | 7.95 | 7.95 |
| int rand 4,096 | 15.92 | 16.19 | 16.03 | 16.04 | 16.01 |
| int rand 65,536 | 18.26 | 18.65 | 18.42 | 18.38 | 18.25 |
| int rand 2^20 | 20.42 | 20.90 | 20.69 | 20.36 | 20.59 |
| int dups 2^20 | 3.07 | 3.15 | 3.12 | 3.05 | 3.10 |
| int sorted 2^20 | 0.36 | 0.36 | 0.37 | 0.36 | 0.37 |
| obj rev 256 | 2.51 | 2.58 | 2.56 | 2.54 | 2.53 |

In a program that sorts only with `sort`, every row is level (within
2%: 1.6% slower at most, 16-valued Ints at 2^20). In the bench binary
four Int rows and one object row read 2.1 to 2.8% slower: placement,
from the stable sort's copy inlined into the same function, the price
README.md named for inlining the compare (one copy of the sort per
call site, as Rust's monomorphization pays).
