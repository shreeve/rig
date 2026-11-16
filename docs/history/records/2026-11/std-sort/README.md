# std.sort: a fast `sort`, and the stable path's two candidates (2026-11-15)

The owner approved four decisions directly ("Ok. Good suggestions."):
one `sort`, always stable in meaning; `sort` fast where stability is
invisible, by an unstable in-place O(n log n) sort with comparisons
inlined; the stable path (`sort_by`, `sort_by_key`, custom orderings)
faster, two candidates measured and not chosen; no `sort_unstable`
name. This record has what was built for the second, the numbers for
the third, and a recommendation the owner decides on.

Apple M5, 10 cores, macOS (Darwin 27.2), Zig 0.17.0, Rust 1.99.1,
branch `std-sort-fast` from main 3f4564a4b. Every figure is ns per
element, the fastest round of an interleaved board run under
`tools/mac-claim` (each outer round runs every arm on every row in a
fresh shuffled order; each run takes the fastest of 3 rounds; 5 outer
rounds for the unstable board, 4 for the stable one). A row of n
elements sorts 2^20 / n separate slices of fresh data each round (one
slice from 2^20 up). The data, the generator (splitmix64), and the
patterns are the same in every language: `rand` (63-bit keys),
`sorted`, `rev`, `dups` (16 values). Text is a view of decimal digits
(`?String`, Zig's `[]const u8`, Rust's `&str`); `obj` is an object of
two Ints ordered by its fields; `rec` is `{key, id}` ordered by `key`.
The programs are in [programs/](programs/), the full tables in
[board-unstable.tsv](board-unstable.tsv) and
[board-stable.tsv](board-stable.tsv).

## 1. "Equal means identical", decided from the type

Rig has no compile-time question about a type that Rig code can ask
(no reflection; a bound only says what a body may do). But the fact
already has a home: the runtime's `rig.order` is where Rig decides, at
Zig compile time, how each type orders (an own `order` method, text by
bytes, an object by its fields, an enum by variant then payload). The
new `rig.orderIsIdentity(T)` sits beside it and follows it case by
case: true for numbers, `Bool`, plain enums, text (equal bytes;
a String's capacity is not observable), and optionals, arrays, boxes,
objects and enums made only of these whose order is derived; false for
a type with an `order` of its own (two keys it calls equal may differ),
a handle (its identity shows through a Cell or a weak handle), a view
held by address, and any runtime type. `std/sort.zig` exposes it to
std as `equal_is_same[T]()`, a Zig-backed function Zig folds to a
constant, so `sort` compiles to one path per type. Nothing is faked: a
type the predicate does not know falls to the stable path, which is
always right. A stricter reading of "one classifier per fact" would
have sema record it as a fact of each type (as `Copy` and `Owned`
are), which emit would hand to std; that is the minimal compile-time
fact if the owner prefers it there, and it would replace the runtime
walk one for one.

## 2. `sort` for identical-when-equal types: pattern-defeating quicksort

Written in Rig (`std/sort.rig`): Orson Peters' pdqsort as Zig's
`std.sort.pdq` and Rust's old `sort_unstable` do it: median of three
or nine, block partition (BlockQuicksort, 64 offsets a side, as
bytes), insertion sort to 24, equal-run split, O(n) sorted and reversed
detection, heapsort after too many unbalanced partitions; recursion on
the smaller side only (O(log n) stack); `<` compared in a `T: Ord`
body, inline. Tests force the heapsort and pattern-breaking paths in a
scratch copy (clean under `RIG_SANITIZE=1`).

Two runtime faults surfaced and are fixed in the same change:

- `!xs.swap(i, j)` went through Zig's `std.mem.swap`, which swaps byte
  by byte; LLVM turned two neighbours' swap into byte shuffles
  (`ushl`/`uzp1` on NEON), so the insertion sort of 16 Ints ran 2 to 3
  times as slow as the old sort's (the first board,
  [board-unstable-first.tsv](board-unstable-first.tsv): 16 Ints 23.2
  against 17.4). An element up to 64 bytes now swaps as whole values.
  Zig's own `std.sort.pdq` has the same fault (column
  `zig-pdq-safe`), so the Zig ceiling below is also given value swaps
  (`zig-pdqv`, `std.sort.pdqContext` with a value-swapping context).
- `<` on an object ordered by its fields made an `Order` per field and
  compared it; it now decides field by field (`!=` and `<` on a number,
  `Bool` or plain enum field). Before, objects ran 72% slower than Zig
  at 4M (80.5 against 46.7); in Zig the same `Order` route was 1.8 to
  3.2 times as slow as a direct less.

Against today's `sort` (`old`, main's compiler and std) and the Zig
ceiling built the same way (ReleaseSafe; `-fast` is Zig's unchecked
mode, which Rig no longer builds), random input:

| n | Int old | Int new | Zig pdqv safe | Text old | Text new | Zig pdqv safe | Obj old | Obj new | Zig pdqv safe | Rust `sort_unstable` (Int) |
|---|---|---|---|---|---|---|---|---|---|---|
| 16 | 17.39 | 8.38 | 10.45 | 17.57 | 13.94 | 14.90 | 11.31 | 10.41 | 12.41 | 5.68 |
| 256 | 55.36 | 14.26 | 14.28 | 71.96 | 41.17 | 42.36 | 45.71 | 17.28 | 18.20 | 4.48 |
| 4,096 | 101.02 | 16.83 | 16.74 | 144.40 | 67.65 | 68.76 | 89.19 | 20.53 | 22.08 | 5.83 |
| 65,536 | 150.48 | 19.17 | 19.27 | 226.96 | 94.99 | 96.16 | 139.88 | 23.61 | 25.43 | 7.34 |
| 2^20 | 203.43 | 21.29 | 21.66 | 329.41 | 129.62 | 130.38 | 196.66 | 26.53 | 28.64 | 8.84 |
| 2^22 | 232.69 | 22.55 | 22.96 | 420.67 | 160.84 | 161.38 | 229.93 | 28.19 | 30.65 | 9.61 |

Other patterns at 2^20 (old, new, Zig pdqv safe): Int sorted 1.58,
0.38, 0.39; reversed 18.65, 1.97, 1.79; 16 values 75.45, 3.19, 3.28.
Text sorted 8.12, 4.55, 4.41; reversed 55.28, 12.75, 12.67; 16 values
92.09, 18.82, 18.92. Objects sorted 1.49, 0.65, 0.65; reversed 19.58,
2.43, 3.74; 16 values 77.43, 4.15, 4.56.

- Every one of the 72 rows is faster than today's sort: from 7% faster
  (16 reversed Strings, 34.20 to 32.08) to 24 times as fast (2^20 Ints
  of 16 values). Random Ints: 2.1 times as fast at 16, 6.0 at 4,096,
  10.3 at 2^22.
- Against the Zig ceiling built the same way, Rig is level (within 2%)
  or faster on 65 of the 72 rows. Slower by more than 2%: reversed Ints
  from 256 up (4.5 to 10%, 1.97 against 1.79 at 2^20: the reversal
  loop's swaps are checked), sorted text at 2^20 (3.2%), and 16-valued
  text at 2^22 (4.6%).
- Rust's `sort_unstable` (ipnsort: branchless partitions, sorting
  networks for small slices) is 2.3 times as fast on random Ints at
  2^22 and about 2.6 times on text; that is a different algorithm, not
  a different compile, and the next bar if `sort` is to go further.

## 3. The stable path: two candidates

Arms, all on the same compiler (main's for `old`):

| Arm | Algorithm | Compare |
|---|---|---|
| `old` | today: insertion runs of 20, SymMerge by rotations (O(n log² n) swaps) | closure, indirect |
| `branch` | the same algorithm on this branch (whole-value swaps) | closure, indirect |
| `symi` | the same algorithm as one inline body, explicit stack for the recursion ([programs/symi-sort_by.rig](programs/symi-sort_by.rig)) | closure, inlined |
| `a` | buffered stable merge: natural runs (falling ones reversed), runs of 32 by binary insertion, powersort merge order, each merge copying the shorter run to a buffer of n/2 elements ([programs/cand.zig](programs/cand.zig)) | `rec`, `sint`, `sstr`: closure, indirect; `reco`: `<`, direct |
| `b` | in-place block merge sort: Zig's `std.sort.block` (WikiSort, O(n log n), a 512-element stack cache) | as `a` |
| Zig block safe | `std.sort.block` called from Zig | direct |
| Rust | `slice::sort_by` (driftsort, n/2 buffer) | direct (monomorphized) |

`a` and `b` are Zig code in a scratch std's shim (a copy of std/ named
by `RIG_STD`, never committed): they say what each algorithm is worth,
not what a Rig port costs. A Rig port pays Rig's index and overflow
checks (about 6% of a sort by the checks-cost record) and, for `a`,
needs a primitive safe Rig lacks: moving elements between a slice and
uninitialized scratch (Rig has no raw pointers); a std-internal shim
for those moves is the smallest. Rows: `rec` is `sort_by(|a, b| a.key
< b.key)`, `reco` the same records under `sort` with an own `order` by
key, `sint` `sort_by(|a, b| a < b)` on Ints, `sstr` the same on text.

Random input:

| Row | n | old | branch | symi | a | b | Zig block | Rust stable |
|---|---|---|---|---|---|---|---|---|
| rec | 16 | 10.75 | 10.64 | 10.17 | 17.79 | 19.80 | 15.21 | 5.40 |
| rec | 4,096 | 101.49 | 95.05 | 76.68 | 44.13 | 60.85 | 39.61 | 9.33 |
| rec | 2^20 | 226.05 | 199.82 | 159.51 | 70.63 | 114.41 | 74.53 | 15.30 |
| reco | 4,096 | 86.65 | 80.24 | 74.92 | 39.50 | 40.36 | 39.36 | 9.39 |
| reco | 2^20 | 193.82 | 163.44 | 155.58 | 66.21 | 74.61 | 74.22 | 15.47 |
| sint | 16 | 17.25 | 17.35 | 8.87 | 10.53 | 15.51 | 12.27 | 5.24 |
| sint | 2^20 | 202.71 | 190.55 | 157.81 | 62.73 | 91.49 | 67.40 | 12.23 |
| sstr | 2^20 | 327.49 | 300.44 | 276.63 | 135.98 | 183.55 | 144.74 | 86.32 |

Presorted input at 2^20 (rec): sorted 1.71, 1.69, 2.47, 0.94, 3.42,
2.61, 0.23; reversed 18.09, 14.49, 12.12, 1.17, 10.91, 12.72, 0.45; 16
values 80.67, 67.05, 54.89, 38.53, 50.36, 40.12, 3.53.

**The compare's share and the algorithm's.** On the same algorithm,
inlining the closure's compare (`symi` against `branch`) makes the
stable sort 25% faster on random records at 2^20 (199.82 to 159.51),
21% on Ints, 9% on text, and twice as fast at 16 elements, where
insertion is all there is (17.35 to 8.87 on Ints). The algorithm
(`a` against `symi`, with `a`'s compare still indirect) is worth 2.3
times on random records at 2^20 (159.51 to 70.63), 2.5 on Ints, and
10 times on reversed input. Of the gap from today's `sort_by` to Rust
on random records at 2^20, the compare is 22% and the algorithm the
rest.

**A closure's compare can be inlined without changing a call site.**
`sort_by` is already emitted inline. When everything it calls with the
closure is inline as well (no recursion: `symi` turns SymMerge's into
an explicit stack), Zig inlines the whole sort into the caller, the
closure's `FnRef` holds a constant function pointer, and LLVM calls the
closure directly and inlines it: `symi`'s binary has no closure thunk
and no `sym_merge` left (`nm`), where `old`'s has one thunk per call
site's type. The price is one copy of the sort per call site, as
Rust's monomorphization pays. No language change is needed.

**(a) buffered merge** is the faster: 2.8 times this branch's
`sort_by` on random records at 2^20 with an indirect compare (3.2
times main's), level with Zig's block sort on random input (from 10%
slower at 4,096 to 12% faster at 2^20) and 1.5 to 19 times faster than
it on sorted and reversed input from 4,096 up, since runs are found in
O(n). It allocates n/2 elements, which
`sort_by` would document. At 16 elements it is slower than today
(17.79 against 10.75) because its compare is the indirect call; an
inline Rig port would give it `symi`'s small-slice speed.

**(b) in-place block merge** allocates nothing and is O(n log n): 1.7
times this branch's `sort_by` on random records at 2^20 with an
indirect compare, 2.2 with a direct one; it finds no runs (sorted input 2.0 times slower
than today, 3.42 against 1.69), and Zig's version is about 800 lines
with a 512-element stack cache, which a Rig port would keep or lose
(without it WikiSort is slower still).

**Neither is near Rust.** driftsort is 4.6 times as fast as `a` on
random records at 2^20 (15.30 against 70.63), and 1.3 to 31 times
across all 80 rows: it adds a stable quicksort for data without runs
(the same n/2 buffer), branchless merges, and small-sort networks.

**Recommendation: (a), the buffered merge, inline so the compare is
inlined, with natural runs, as the step toward driftsort.** It is the
faster on every row of 4,096 elements and up (`b` leads on 7 of the 80
rows, all of 16 or 256 elements), keeps the code small, and
its one cost, an allocation of n/2 elements, is visible in the
signature's docs (as Rust's `sort` documents it). If no allocation is
a hard rule for std, (b) is the choice, at 1.6 times `a`'s time on
random records with the closure's compare (1.1 times with a direct
one) and slower than today on sorted input. The choice is
the owner's; neither is committed.

## What was committed

`sort`'s quicksort path, `rig.orderIsIdentity` and its shim, the
runtime's value swap and field-by-field `<`, the tests
(`test/rig/std-sort.rig.test`), STD.md and CHANGELOG. `sort_by`,
`sort_by_key`, and the stable path are unchanged in source. On this
branch's compiler they run up to 27% faster than on main's (`branch`
against `old`; reversed input gains most, from the whole-value swaps),
and a few rows run slower in code that did not change: a 20-round
interleaved A/B (`programs/ab.py`) gave sorted text 5.5% slower at
4,096 and 4.4% at 65,536, and 16 reversed records 6.9% slower, while
random records at 65,536 ran 9.1% faster and 16 sorted or random Ints
level. These sit in the size of the code-placement effects the speed
rules name (5 to 7% on Apple cores) and go away with whichever stable
candidate replaces the merge; they are listed for the owner.

A last change came from the core suite: once `sort.sort[F32]` fails
its bound, every bounded helper it reaches (`std.sort.pdq[F32]` and the
rest) failed it again, 14 errors for one mistake. The compiler now
checks no instance made by one whose bounds failed
(`typecheck.checkGenericInstantiations`), so the call reports once, as
before.
