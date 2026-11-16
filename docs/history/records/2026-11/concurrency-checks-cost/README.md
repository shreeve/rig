# What checks cost in the concurrency gaps (2026-11-15)

The release measurement of 2026-11-15
([concurrency-bench-remeasure](../concurrency-bench-remeasure/README.md))
found Rig behind on the Mac: loopback ping-pong 20% and echo 47% slower
than Tokio, fork-join sum 18% and quicksort 53% slower than Rayon. This
record splits each gap into what Rig's checks cost and what the design
costs, by building the same programs with checks taken out, in a
scratch build that was never committed (Rig has no fast mode, #1083).

**Result.** Checks explain none of the loopback gaps and none of the
fork-join sum's. They explain about a sixth of the quicksort's: about
6% of Rig's quicksort time, nearly all in `std.sort`'s merge
(`sym_merge`, `rotate`, `swap_range`), where no test is proven today.
The rest of every gap is design.

| Gap (Mac) | Rig `--release` | Rival | Gap | Checks | Design |
|---|---|---|---|---|---|
| ping-pong | 16.10 to 16.34 µs | Tokio 14.15 to 14.45 µs | 1.9 µs | 0% (any check cost is under 18% of the gap) | 100% |
| echo | 8.52 to 8.60 µs | Tokio 6.12 to 6.17 µs | 2.4 µs | 0% (under 4%) | 100% |
| psum | 2.66 to 2.69 ms | Rayon 2.35 to 2.38 ms | 0.31 ms | 0% (under 21%) | 100% |
| qsort | 81.3 to 81.9 ms | Rayon 52.0 to 52.6 ms | 29.3 ms | about 17% (5 ms) | about 83% |

The bounds in parentheses come from the noise: the largest move of any
checks-off arm on that row, in either direction, as a share of the gap.

## Arms

Apple M5, 10 cores, macOS (Darwin 27.2), main 7a2efd0f3, Zig 0.17.0.
A release build is one `zig build-obj -Osafe` of the package's root
(the runtime is imported by path, so it is one Zig module), then a link
(`src/main.zig`, `buildApart`). Each checks-off arm is a scratch `$ZIG`,
a wrapper that copies the package to a private folder, patches the
copy, and calls Zig; `bin/rig`, the worktree and the shared package in
`~/.cache/rig` are untouched. Rig's checks come in two kinds, and the
arms take them out separately:

- **Arithmetic**: `+`, `-`, `*`, `@divTrunc`, `@shlExact` and casts are
  emitted as Zig operators and checked by Zig's safe mode (a `b.vs`
  after each `adds`).
- **Index tests**: `xs[i]`, slices, `swap`, `read`/`write` go through
  the runtime's `index`, `bounds`, `provenOffset` and kin, which test in
  every build mode and call `indexPanic`, `slicePanic`, `lenPanic`,
  `bytesPanic`; and `shiftAmount`'s test.

| Arm | What it builds |
|---|---|
| `c` | the shipping `rig build --release` (Zig ReleaseSafe) |
| `arith` | every emitted (non-runtime) Zig function starts with `@setRuntimeSafety(false)`: the arithmetic checks of program and std code go; the runtime keeps every check |
| `idx` | the runtime's index, slice, length, byte and shift tests made assumptions (each panic helper becomes `inline` with `@setRuntimeSafety(false); unreachable`, so LLVM deletes the test); arithmetic checks kept |
| `rig` (task's arm a) | `arith` and `idx` together: every check Rig's semantics make is gone; the runtime's own Zig checks (scheduler, sockets, allocator, Zig std) stay |
| `fast` (task's arm b) | `rig`, compiled ReleaseFast: no check anywhere |

A probe program confirmed each arm: an out-of-range index, an overflowing
add, and a bad slice panic under `c`; under `arith` only the add stops
panicking; under `rig` and `fast` none do. Disassembly confirms it in
the hot code (below).

Every board ran under `tools/mac-claim`, interleaved, fastest of N, with
Tokio, Rayon and Go in the same rotation. The Mac was shared: load
averages 1.9 to 5.1 at the boards' starts.

## Numbers

**Fork-join** (`fork.rig` and its Rayon twin from the remeasure record;
ms, fastest):

| Board | Rounds | Load | | c | arith | idx | rig | fast | Rayon |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 20 | 4.2 | psum | 2.664 | 2.730 | | 2.727 | 2.714 | 2.350 |
| | | | qsort | 81.345 | 77.006 | | 75.996 | 77.067 | 51.959 |
| 2 | 24 | 3.2 | psum | 2.685 | 2.681 | 2.636 | 2.677 | 2.651 | 2.379 |
| | | | qsort | 81.947 | 81.728 | 83.486 | 81.753 | 80.827 | 52.602 |

One quicksort runs 80 ms on ten cores, and its rounds spread from 77 to
110 ms on a shared Mac, so the fastest of 20 moves by several percent
between boards. A steadier probe, `qsort30`, runs the same `qsort` 30
times in one process (wall seconds, fastest; the `c` arm was the
slowest in 20 of 26 rounds):

| Board | Rounds | Load | c | arith | idx | rig | fast |
|---|---|---|---|---|---|---|---|
| A | 10 | 1.9 | 2.192 | 2.085 | 2.138 | 2.052 | 2.057 |
| B | 16 | 2.1 | 2.513 | 2.320 | 2.363 | 2.367 | 2.196 |

`rig` is 6.4% and 5.8% faster than `c`; `arith` alone 4.9% and 7.7%;
`idx` alone 2.5% and 6.0%; the two kinds overlap (taking out one lets
LLVM fold some of the other). `fast` against `rig`: 0.2% slower on A,
7.2% faster on B, so the runtime's own checks are not separable from
noise here. With fork board 1 (6.6%) and board 2 (0.2%), checks are
about 6% of Rig's quicksort time: 5 ms of the 29 ms gap.

`/usr/bin/time -l` on `qsort30`: `c` retires 204.1 G instructions in
54.7 G cycles, `rig` 166.2 G in 50.6 G (19% fewer instructions, 8%
fewer cycles; both include idle workers' spinning).

**Sockets** (`bench/net`, per round trip or connection, fastest):

| Board | Reps | Load | | c | arith | rig | fast | Tokio | Go |
|---|---|---|---|---|---|---|---|---|---|
| 1 | 9 | 3.4 | ping-pong | 16.34 µs | 16.27 | 16.37 | 15.99 | 14.45 | 16.31 |
| | | | echo | 8.52 µs | 8.59 | 8.45 | 8.53 | 6.12 | 7.48 |
| | | | connect | 50.46 µs | 51.70 | 50.59 | 50.90 | 63.04 | 61.57 |
| 2 | 12 | 5.1 | ping-pong | 16.10 µs | | 16.01 | 16.20 | 14.15 | |
| | | | echo | 8.60 µs | | 8.53 | 8.55 | 6.17 | |
| | | | connect | 50.28 µs | | 51.37 | 52.48 | 61.73 | |

No arm moves ping-pong or echo by more than 2.1%, in either direction,
and none moves either the same way on both boards. Connect, where Rig
leads, is up to 4.4% slower with checks off, as noise or layout.

**Control, `bench/tasks`** (5 reps, load 3.7):

| | c | arith | rig | fast | Tokio | Go |
|---|---|---|---|---|---|---|
| spawn | 128 ns | 180 | 126 | 108 | 173 | 227 |
| chain | 54 ns | 55 | 53 | 52 | 154 | 212 |
| fanout | 67.7 ms | 79.6 | 79.6 | 80.9 | 67.7 | 68.0 |
| yield | 6 ns | 6 | 6 | 5 | 42 | 248 |
| produce | 5.7 ms | 6.7 | 6.3 | 6.2 | 5.3 | 6.0 |

`chain` and `yield` do not move. `spawn` under `fast` is 16% faster than
`c` on one board of five reps, a hint that the runtime's own Zig checks
on the spawn path cost something; it wants a board of its own before
anyone acts on it. `fanout` and `produce` are 18% and 10 to 18% *slower*
with checks off: their work is `spin`, `total = (total + i * 7) %
1000003`. With the overflow check gone the add is `nsw`, LLVM proves
`total >= 0`, and it rewrites the loop around an unsigned division whose
chain (`sub`, `add lsl`, `umulh`, `sub`, `add lsr`, `lsr`, `msub`) is
longer than the checked loop's (`adds`, `b.vs`, `smulh`, `add`, `asr`,
`add`, `msub`). A check is not always a cost.

## Where the quicksort's checks are

A `sample` of `qsort30` (built with frame pointers, `RIG_FRAME_POINTERS=1`)
over 3 s: of the busy samples, `sym_merge` 44.8%, `qsort` 36.4% (the
partition loop, and `insertion` inlined into it), `memmove` 6.2%,
the comparator's `FnRef` thunk 5.5%, preemption signals (`pthread_kill`,
`_sigtramp`) 3.8%. By source line (the emitted Zig's, mapped to Rig):

| Share of busy samples | Rig source | What runs |
|---|---|---|
| 22% | `rotate` → `swap_range` (std/sort.rig:99-114), inlined in `sym_merge` | `!xs.swap(a + i, b + i)` per element |
| 19% | fork.rig, the partition `for x in xs` and its pushes | no check |
| 6% | `sym_merge`'s third binary search (std/sort.rig:83-90) | `xs[p - c]`, `xs[c]`, `(start + r) / 2`, and the comparator |
| 6% | fork.rig, the `out.push` loops | no check |
| 5% | `sort_by` → `insertion` (std/sort.rig:20-26, 42-47), inlined in `qsort` | `xs[j]`, `xs[j - 1]`, `swap(j, j - 1)` |

The rest of `sym_merge` (16%) is its other searches, its moves and its
recursion; 6% of `qsort`'s samples carry no line.

`rig check --facts=proofs` on a copy of std.sort proves only `i += 1`
and `xs[j]`'s lower test in `insertion`, and nothing in `sym_merge`,
`rotate` or `swap_range`.

**1. `swap_range`'s loop, the hot one.** Under `c`, each element runs
18 instructions: `adds`/`b.vs` for `a + i` and for `b + i`, an upper
test for each index (`cmp`/`b.hs`; LLVM folds the lower test into it),
the swap's `i == j` test, the loop's count, compare and branches, two
loads and two stores. Under `rig`, 8: the checks gone, LLVM hoists `a + i == b + i`
(true only when `a == b`) out of the loop. That is most of the
quicksort's 6%. Not provable today: `a`, `b`, `n` are parameters, and
the pass knows nothing of a parameter. Every caller (`rotate`, from
`sym_merge`, from `sort_by`) does keep `0 <= a`, `a + n <= xs.len`,
`0 <= b`, `b + n <= xs.len`.

**2. `sym_merge`'s binary searches** (std/sort.rig:52-60, 66-74,
83-90): per probe, a midpoint `(i + j) / 2` or `(start + r) / 2`, an
add or subtract (`h + 1`, `c + 1`, `p - c`), and two index tests. The
midpoint add cannot overflow when both ends are non-negative and at most
a length (`2 * max_len < 2^63`), and the midpoint lies below the upper
end; but the ends again come from parameters (`a`, `m`, `b`).

**3. `insertion`** (std/sort.rig:42-47): unproven are `xs[j]`'s upper
test, both of `xs[j - 1]`'s, `j - 1` twice, the four tests of
`swap(j, j - 1)`, and `j -= 1`. All are provable inside the function:
`j = i` with `i < xs.len` gives `j < xs.len`; the loop's step `j -= 1`
only lowers `j`, so it keeps every upper bound; and the guard `j > 0`
gives `0 <= j - 1` and rules out overflow in `j - 1`. LLVM already
removes most of these (the checked inner loop keeps one compare and
branch per step), so the gain is small: by estimate, about 1% of the quicksort.

## Recommendations for src/proofs.zig

In order of what they would take off the quicksort:

1. **Facts about a parameter from every call site, for functions that
   are not `pub`.** The counterpart of the result bounds the pass already
   finds (`sema.ResultBound`): where every call of a private function
   passes arguments that satisfy `nonneg`, `below(i, k, len(s))` or
   `below(i, k, int(n))` about its other arguments, the function's body
   starts with those facts. It proves `swap_range`'s four tests per
   element and `rotate`'s and `sym_merge`'s index tests: most of the 6%.
   (Inlining does not give LLVM these facts, as the checked code shows.)
2. **A step that only lowers keeps upper bounds; a copy copies facts.**
   `j -= c` and `j = j - c` (literal `c >= 0`) keep `below(j, k, b)`;
   `i += c` keeps `nonneg(i)`; `j = i` gives `j` every fact of `i`; a
   guard `j > c` gives `nonneg(j - c - 1)` and proves `j - c`'s
   subtraction. Proves `insertion` whole.
3. **The sum of two length-bounded values fits.** `i + j` where both
   are non-negative and at most a length cannot overflow, and `(i + j) /
   2` is below whichever end bounds it: every midpoint of a binary
   search (`sym_merge`, `lower_bound`, `search`).

None of these touches the loopback or fork-join-sum gaps, which have no
check cost to remove.

## The design side

- **qsort, about 83%.** `std.sort.sort` is a stable merge in place
  (insertion runs of 20, then SymMerge with rotations): O(n log² n)
  moves, and `sym_merge` is 45% of the busy samples. The Rayon twin calls
  `sort_unstable`, which never merges. Each comparison is an indirect
  call through the comparator's `FnRef` (a `blr` in `insertion` and in
  `sym_merge`; the thunk alone is 5.5%), where Rust inlines its
  comparator. A rotation by blocks (one range test, then moves) would
  take both the checks and most of the moves out of `rotate`; that, an
  unstable sort, and an inlined comparator are std and language design,
  not proofs work, and are the owner's call.
- **psum.** Each of the 4,096 leaves is a task spawned and joined;
  `seq_sum`'s loop has no check left to remove.
- **ping-pong and echo.** Unchanged by every arm; the remeasure record's
  next step stands (a system-call profile of echo in both runtimes).
  `net.rig` also makes a new `String` for every read, where Tokio's twin
  reuses one buffer per connection.

## Not measured

- x86-64 Linux, routed to pup: the same arms (`c`, `arith`, `idx`,
  `rig`, `fast`) of `fork.rig` with Rayon (24 rounds), `qsort30` (16
  rounds), `bench/net` with Tokio and Go (12 reps), and `bench/tasks`
  with Tokio and Go (5 reps). On Linux a release build is one
  `zig build-exe` of the root; the wrapper patches any root `.zig` it is
  given, so it carries over.
- `spawn` under `fast` against `c`, on a board of its own, to see
  whether the runtime's own checks on the spawn path cost what one
  board suggests.
