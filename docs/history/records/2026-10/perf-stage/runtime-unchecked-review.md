# Soundness review: PR #761 `runtime-unchecked` (head 2756eb9d0)

Reviewed from the code (`git diff origin/main -- src/`), its callers in
`src/runtime.zig`, `src/tasks.zig`, `src/net.zig`, `src/table.zig`,
`src/ordered.zig`, `src/unordered.zig`, `src/emit.zig`, and `std/*.zig`.
The PR's comments were treated as claims to check, not as facts.

## Framing: what changes, and for which builds

- `proven_checks = builtin.mode == .debug`. A Rig program's build is
  `-Odebug` (`rig run`), `-Osafe` (`--release`, `--release=safe`), or
  `-Ofast` (`--release=fast`) (`src/main.zig`, `Mode`). Under `-Ofast`
  every one of these checks was already off on `main`. So the PR changes
  only `--release` (ReleaseSafe) builds, and every invariant below was
  already load-bearing for `--release=fast`. The PR trusts nothing new
  for fast builds, and for safe builds it trusts what fast builds already
  trusted.
- `@setRuntimeSafety` is scoped to its block. A probe (`probes/leak.zig`,
  ReleaseSafe) shows that an `inline fn`'s `@setRuntimeSafety(false)`
  does not leak into its caller: the caller's later out-of-bounds index
  still panics. The non-inline callees inside the unchecked blocks
  (`index`, `std.mem.swap`) keep their own checks.
- `alloc.zig` serves only release builds: a debug program allocates
  through the leak checker (`ownAllocator`). So the debug asserts in
  `segmentOf` and `blockOf` run only in `alloc.zig`'s own unit tests,
  never on a Rig program. "Kept in a debug build" holds for the runtime
  blocks, where the suite's debug runs assert `invariant`, but not for
  these two.

## Per-block verdicts

| # | Block | Check removed | Invariant needed | Who establishes it on every path | Verdict |
|---|---|---|---|---|---|
| 1 | `FnRef.ctxAs` (thunks of `of`, `ofFn`, `ofClosure`) | `@alignCast` alignment (and its non-null) | `ctx` was made from a `P`, the same pointer type as the thunk's | Construction: each constructor builds `ctx` and `call_fn` together from one typed argument (`env: *Env`; `f: F`; `&box.value: *C`), so Zig's types check the pair. Emit builds a FnRef only through `.of(@TypeOf(x), &x)`, `.ofFn(..)`, `.ofClosure(..)` (emit.zig 10201, 10329, 10345, 10348, 10374), never as a struct literal. Nothing writes `.ctx` or `.call_fn` after construction (grep of src/ and std/), and no runtime code bit-casts one FnRef type to another. A dangling `ctx` (a view outliving its env) is the ownership checker's job, and the alignment check would not catch it. | SOUND |
| 2 | `List.items` (inline lists): `m.ptr[0..len]` | slice bound `len <= m.len` | `len <= mem().len` | Same List invariant `main` already trusts in `push`, `at`, `slot`, `items` (no inline room). Every writer of `len` keeps it: `push` (after `grow`), `fromSlice`, `filled`, `resize`, `keep`, `clear`, `pop`, `insert`/`remove` (checked slices), `tasks.zig` par map/workers (`out.len = n` after `initCapacity(n)`), `Shared.listKeep` (`rest <= len`). An inline List has `buf.len == 0` only while `len <= inline_len`: `grow` moves to the heap with at least `2 * inline_len`, and `__rig_drop` clears `len` first. | SOUND |
| 3 | `List.grow`: `buf.len *| 2` | multiply overflow | none | Saturates; `reallocSlice` then panics above `max_len`. | SOUND |
| 4 | `List.pop` | index `len - 1 < m.len`, and the decrement's underflow | `0 < len <= mem().len` | `len == 0` returns first; no code runs between the decrement and the read, so no alias or drop can intervene. Same invariant as row 2. | SOUND |
| 5 | `IntoIter.next` | index, and `next_index + 1` overflow | `next_index < it.list.len <= mem().len` | Checked against `len` just before the read, nothing in between. `it.list` is the iterator's own moved copy (`for x in <v`), which the loop body cannot reach; an inline List's `mem()` is the copy's own `inline_buf`. `next_index < len <= max_len`, so `+%` cannot wrap. | SOUND |
| 6 | `String.appendBytes`: `@memcpy` to `@memmove`, unchecked | equal lengths; `@memcpy`'s no-overlap check | both `bytes_.len` long | By construction (`(ptr + used)[0..bytes_.len]`). `@memmove` is correct under any overlap. A source that aliases the String itself is rejected by the ownership checker (`!t.add(?t)`, `!t.add(t[1..])`: `probes/alias*.rig`). Even if it were not, the removed overlap check could not catch it: after a reallocating `grow` the source is freed (no overlap with the new block), and without one the source `[0, used)` and the destination `[used, ...)` do not overlap. | SOUND |
| 7 | `String.copyFresh` (in `ofShort`, `clone`) | equal lengths; no overlap | `dst` freshly allocated, `dst.len == src.len` | `allocSlice(u8, n)` returns exactly `n` (both its raw path and the `fills`/`alloc` path); `ofShort` returns early at 0 and slices `buf[0..w.end]` in checked code outside the block; `clone` returns early at 0. A fresh block overlaps a live one only after a use-after-free, which is a bug before this point either way. | SOUND |
| 8 | `rt.at` | slice bound | `idx < items.len` | `index(i, items.len)` just before, in a separate function that keeps its checks, against the same by-value `items`. `items` is a slice, array, or pointer to an array (emit.zig 7102, strings and slices only), whose `.len` is exactly the bound Zig checks. A mutation between taking `items` and `index` cannot change the copied `len`; whether `items` still points at live memory is the ownership checker's job, and the bounds check does not test that. | SOUND |
| 9 | `rt.elemPtr` | slice bound | same | same | SOUND |
| 10 | `rt.swap` | two slice bounds | `a, b < items.len` | two `index` calls. See the pre-existing note below on `i == j`. | SOUND |
| 11 | `heldBytes` (in `freeSlice`, `reallocSlice`) | `sliceAsBytes`'s `len * @sizeOf(T)` overflow | the byte count fits a `usize` | Holds for every slice that describes real memory, whatever made it: no object is larger than the address space. So it holds for callers outside `allocSlice`/`reallocSlice` too: `String.grow` and `__rig_drop` pass `allocatedSlice()`, whose buffer Zig's `ArrayList` may have grown (`addValue` through `Writer.Allocating`, std shims' `appendSlice`, `ensureTotalCapacityPrecise`, `shrinkAndFreePrecise` in `std/file.zig` and `src/net.zig`), all with `defaultAllocator()`. A zero-size `T` (a List's `max_len` buffer) returns empty, and `freeSlice` returns at 0 bytes. The removed check could fire only for a fabricated slice (`raw` code). | SOUND |
| 12 | `Table.push`: `@intCast` to `@truncate` | `len` fits `Index` | `len < n`, and `n - 1` fits `Index` | `if (len == n) fullPanic` before, and only `push` raises `len` (no other writer in table.zig, emit, or std). `Slot(n)` is the smallest of u8/u16/u32/u64 holding `n - 1`. Probe `probes/table.rig`: `Table[String, 256]` (u8 slots) gives slot 255, then panics "a table of 256 slots is full" in `--release` and debug. | SOUND |
| 13 | `alloc.segmentOf` (in `free`, `freeSmall`) | `@ptrFromInt` non-null and 8-alignment | `p` is a small block of this allocator | The masked address is always 4 MiB-aligned, and is zero only for `p` < 4 MiB, which no block reaches (segments come from `mmap`). So the removed check could catch no free this allocator gets, small or not. `fastClass` keys on length and alignment only, but those decide the block's kind: `resize`/`remap` keep a small block in its class and a large one large (`new != null` is refused for a large block; `remap` returns null if either side is small), so a contract-keeping free of a large block always has `len > max_small >= 1024`, and `fastClass` returns null. A block is never in a segment's first page (`newPage` returns `s + page_size` with `used = 2`), and the null check would not detect that case anyway. A foreign pointer or a wrong length is undefined behavior with or without this check: the old check only caught a pointer below 4 MiB. Every foreign allocator found (`smp_allocator` in sched/tasks/net/runtime, `page_allocator` in sched) is paired with its own free. Every zero-length free (dangling `@ptrFromInt(@alignOf(T))` slots, `&.{}`) is filtered first (`Allocator.free`, `freeSlice`'s 0 check, `Table`'s `cap > 0`, `ordered.zig`'s `cap != 0`). | SOUND |
| 14 | `alloc.blockOf` | `@alignCast` to 8 | `p % 8 == 0` | Blocks are carved at multiples of their class size (all multiples of 8) from 64 KiB pages in 4 MiB-aligned segments. On `main`, a ReleaseSafe build would have panicked on a free of a misaligned interior pointer (such as `s[1..]` of a small block); now that free would corrupt the free list. I found no such path: every free in runtime, std shims, Map/Set, and Table passes a block start, and `String`'s `items.ptr` is only ever set to a block start. | SOUND |

Cross-thread: probe `probes/xthread.rig` builds Lists of Strings on 8
tasks per round, 50 rounds, and drops them on the waiting task (the
`seg.heap != h` path, then `freeSmall`'s remote list, then `blockOf`). It
prints 624600 in debug, `--release`, and `--release=fast`. Probe
`probes/lists.rig` (pop to empty, `for s in <w`, slice index, String
add/clone) gives the same output in debug and `--release`.

## Notes beyond the 14 blocks (not caused by the PR)

1. **`rt.swap(s, i, i)` passes aliasing `noalias` pointers.**
   `std.mem.swap(comptime T, noalias a: *T, noalias b: *T)` (Zig 0.17
   std/mem.zig:3931) gets `&items[a]` twice when `i == j`, which a Rig
   program can do (`!s.swap(i, i)`; `probes/swap.rig` runs and prints
   the right answer). Zig defines this as undefined behavior, and no
   build checks it. It is harmless in practice (every store writes the
   original byte), and it is the same on `main`. The fix is one line,
   `if (a != b)` before `std.mem.swap`.
2. **Hardening, cost zero:** `Table.push` tests `len == n`. With `>=`,
   the `@truncate` would stay exact even if `len` were ever past `n`.
   No safe path makes it so (that needs a data race on a Table, which
   the ownership checker forbids).
3. **What the PR does lose:** defense in depth in `--release`. A bug
   elsewhere that broke `len <= buf.len`, or freed an interior pointer,
   panicked at these sites on `main` and is now silent corruption, as it
   already was under `--release=fast`. This loss is not a soundness
   hole, since no accepted program reaches it, but the PR text could say
   so plainly.
4. INTERNALS's "kept in a debug build, which also asserts the
   invariant" does not cover `alloc.zig`: debug programs never run it.
   Only `zig build test` asserts those two.

## Probes

All are in [runtime-unchecked-review-data/](runtime-unchecked-review-data/), built with this worktree's `bin/rig` (rebuilt
with `tools/heavy zig build`), with `RIG_OUT_DIR` set to a temporary
directory on the Mac:

- `lists.rig`: pop, IntoIter, slice `at`, String add and clone (debug = release).
- `alias.rig`, `alias2.rig`: String self-append, rejected by the ownership checker.
- `xthread.rig`: frees across tasks (debug = release = fast).
- `table.rig`: Table push at the u8 Slot boundary panics "full".
- `swap.rig`: `swap(i, i)` (note 1).
- `leak.zig`: an inline callee's `@setRuntimeSafety(false)` does not reach its caller.
