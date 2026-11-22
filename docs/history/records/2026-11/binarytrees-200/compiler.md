# binarytrees in 200 ms: the compiler and optimizer view

Panelist: compiler and optimizer. Read only in every repo; probes in
[probes-compiler/](probes-compiler/). Rig at `5cd726a84`, Zig 0.17.0, Apple M5.
The question: what Rig's compiler could do with `binarytrees.rig` unchanged, so the
plain port gets faster, without changing what any program means.

## Method (measured, not estimated)

Each optimization was simulated by hand in the Zig that `rig emit` writes for the
plain port, then built exactly as `rig build --release` builds it (`-Osafe
-fomit-frame-pointer -fno-stack-protector -mcpu=native+reserve_x15`, `build-obj`, the
`__rig_text` section re-flagged as `keepCodeApart` does, main.zig:1325, then
`build-exe`; `probes-compiler/mk.sh`, `apart.py`). The variants are generated from the
emitted file by `probes-compiler/gen.py`, so each differs from the real emit only in the
lines the optimization would change. A hand rebuild of the unchanged emit (`bt-man`)
times the same as `rig build --release` (`bt-base`), which checks the method. Every
variant's output at n = 10 and n = 21 has the same md5 as `rig build --release`'s.

Timing: `tools/mac-claim`, five interleaved runs at n = 21 per board, `/usr/bin/time -l`
(10 ms resolution); fastest wall, CPU as user + sys, five boards in all (`run1.txt` to
`run5.txt`, about two minutes of runs). The fast port was rebuilt and run in the same
boards as the reference: 0.21 s fastest (the brief's 219 ms).

| Variant: what the compiler would emit | Wall (fastest) | CPU | Peak RSS |
|---|---:|---:|---:|
| `rig build --release` today (`bt-base`) | 0.87 s | 5.7-6.1 s | 174 MB |
| A. drop without the generic glue (`v_directdrop`) | 0.62 s | 4.0-4.6 s | 174 MB |
| B. A + a free list per task, the allocator only when it is empty (`v_freelist`) | 0.60 s | 3.5-3.7 s | 174 MB |
| C. a region per tree, bump behind a never-inlined call (`v_region_call`) | 0.34 s | 2.2 s | 239 MB |
| D. a region per tree, bump inlined (`v_region_inline`) | 0.32 s | 2.0-2.2 s | 239 MB |
| E. D, nodes narrowed to two 32-bit offsets (`v_region32`) | 0.33 s | 2.1-2.2 s | 157 MB |
| F. D, the long-lived tree in a region too (`v_region_all`) | **0.28 s** | 2.0-2.1 s | 239 MB |
| G. F, each depth's trees cut into ≤10 tasks (`v_region_all_split10`; a source shape, not an optimization) | 0.27 s | 2.1-2.3 s | 450-560 MB |
| the fast port, `binarytrees-fast.rig` (same boards) | 0.21 s | 1.7-1.8 s | 310-370 MB |

## Where the time goes today

The emitted build and walk are already lean (probes-compiler/bt.zig:18-38): `^Tree?` is
`rig.Opt(rig.Box(Tree))`, a `Niche` at the null address (runtime.zig:837-840), 8 bytes;
`Tree` is 16 bytes; `item_check` is two null tests and two calls; `tickCall` is a
constant `return` in a preempted build (runtime.zig:555-561). The cost is per box:

- **Make**: `Box.init` (runtime.zig:3038-3042) -> `create` (runtime.zig:1973) -> the
  never-inlined `alloc` (alloc.zig:2642): a thread-local read and a free-list pop. The
  noinline is load-bearing: a fiber may resume on another thread, so program code never
  reads a thread-local (alloc.zig:2531-2540).
- **Drop**: `Box.__rig_drop` (runtime.zig:3062-3065) -> `releaseNested`
  (runtime.zig:2821-2831), which per box calls `task()` (runtime.zig:6574), under
  preemption `sched.current()`, a never-inlined call (sched.zig:424-427), bumps and drops
  `drop_depth`, tests the queue, then `releaseErased` -> `dropElement` -> `dropFields`
  -> `destroy` -> the never-inlined `free` (alloc.zig:2657).

Measured split of the 0.87 s: the generic drop glue (a `task()` call and the depth
bookkeeping per box) is about 0.25 s of wall (today -> A); the allocator calls another
0.02-0.06 s of wall, 0.5 s of CPU (A -> B); freeing per node at all, and the heap's
scattered addresses, the rest down to 0.32 s (B -> D). The long-lived tree, made and
freed through the heap while nothing else runs (before the tasks start and at the end of
`main`), is another 40-50 ms of wall (D -> F).

## 1. Region inference as an optimization

**Gain: 0.87 -> 0.28 s measured (F), −590 ms. The largest by far, and nearly all of what
the compiler can do.** Inlining the bump buys about nothing over a call (C vs D, ≤20
ms): the gain is not freeing per node and the nodes laid out in order, not the
allocation's instruction count. So the explicit `Arena[T]` already decided, whose
emitted shape is C, should land near 0.30-0.34 s for a plain-like port (measured C and
F; the arenas panel estimated 0.35-0.45 s, arenas-panel/runtime.md §5).

**The emitted code** (probes-compiler/pkg/v_region_all.zig): a clone of the producer,
`bottom_up_tree_r(depth, r: *Region)`, whose `^e` in the result is a bump in `r`; at the
use site a hidden region local, made once per call of the enclosing function (outside
the loop, so its chunks are reused tree after tree, as `!pool.keep(0)` reuses the pool),
reset where the temporary is dropped today, and freed when the function ends; for a
local (`long_lived`), freed at its drop. The region is the task's, on its fiber's stack,
never the thread's, so a fiber moved to another thread or preempted mid-bump is safe
without the thread-local rule.

**The proof, from facts Rig already has.** Three conditions:

1. *The consumer only reads.* The value is a statement temporary (`dropsTemp`, storage
   fact `temp`; INTERNALS.md:1980-2040) or a local, used only through read views (`?T`:
   `item_check(t: ?Tree)`), never taken (`useOf`), never viewed to write. The ownership
   checker already guarantees no view of a temporary outlives its statement (a kept view
   "is reported", `dropStmtTemps`) and no view of a local outlives its drop, and a read
   view cannot move, swap or free a box (CORE §4-5). So at the drop the value still owns
   exactly the graph it owned when made, and nothing else refers into it.
2. *The producer is region-pure.* Every box reachable from the result was made by the
   producer in building that result: the result is built only from plain data, defaults
   (`Tree()`, `none`) and `^` of region-pure calls, recursively (`Tree(left:
   ^bottom_up_tree(d - 1), ...)`). This is a new, small, inductive inference over the
   call graph (a greatest fixpoint over the cycles `inlining.Pass.cutCycles` already
   finds, inlining.zig:1311). A producer that takes only plain data cannot reach another
   heap value to put in its result. Only allocations that flow into the result go to the
   region; a temporary the producer frees before it returns stays on the heap, so the
   region holds exactly the bytes the value owns and cannot grow in a loop (the arenas
   synthesis's objection to inferred regions).
3. *The type drops only memory.* No user `drop`, no `*T`/`~T`, Cell, closure, task or
   resource anywhere in it (`sema.typeHasDropGlue`, sema.zig:8866, refined to a "memory
   only" predicate beside `resourceKind`, sema.zig:14146). Then skipping the walk is
   unobservable except in heap statistics.

**What turns it off (today's code is emitted, never an error):** the value or a part of
it moves: returned, passed by value, stored in a field or List, captured by an owned
closure, sent into a task (`&`) or a channel, added to a `Tasks`; a write view of it is
taken (a callee could swap a heap box in or a region box out); the producer puts in its
result a box it got elsewhere (a parameter, a List, a call that is not region-pure); the
type holds anything with a drop of its own. In the plain port all three trees pass:
both `item_check(bottom_up_tree(...))` statements and `long_lived`, a local read until
the end of `main` (binarytrees.rig:27, 36, 39, 49).

**Cost to build: high, about a pass.** A post-check pass (its premise is a program the
ownership checker accepted) that records two facts emit reads through `facts.zig`:
"this temporary or local is region-made" and "this function has a region clone". Emit
writes the clone, a second emission with a hidden parameter, only for region-pure
producers (so code grows little, unlike the transitive specialization the arenas panel
rejected as M2), and the region local's reset and free. Runtime: a `Region` (chunks from
`allocSlice`, bump, reset, free), about 50 lines in the probe. Debug and sanitized
builds: each region box a real block tagged with its region (the leak checker's isolate
tags, runtime.zig:7306, are the pattern), all freed at the reset, so `RIG_SANITIZE`
crashes on a use after it and the leak checker reports a heap box a skipped walk missed.
The region local holds no program value (bookkeeping, like an alive flag), and the drop
stays where the checker put it, so "the checker checks exactly what is emitted" holds.
Estimate: 1,500-2,500 lines across a new pass, emit, the runtime and tests.

**Risk: medium, concentrated.** A wrong proof is a use after free in release. It rests
on the ownership checker's existing guarantees plus one new inference (region purity),
small and local. Memory rises (239 vs 174 MB peak): 1 MB chunks, and each task keeps
its tree's chunks between trees; a smaller first chunk trims it.

**CORE §10 and DESIGN.md:250.** The arenas synthesis set inferred regions aside as a
*rule*. As an optimization it changes no rule and no drop point; only how the memory
goes back changes. Its *speed* does change with distant edits (an impure producer turns
it off): a performance cliff with no diagnostic, which a note from `rig build` (which
drops are regions, and why one is not) would make visible.

## 2. Cheaper boxes without regions

- **Typed drop glue: −250 ms measured as the bound (A).** The probe drops a `Tree` by a
  direct recursion that frees each box: no `task()` call, no depth counter, no
  type-erased `releaseErased`. Shipped as is it would be wrong: the depth counter and
  queue keep a 200k-node list from overflowing the stack (runtime.zig:2799-2812). The
  safe version keeps them but reads `task()` once per drop root and passes the
  `*TaskState` down (it is the fiber's, so a migration mid-drop is harmless), calling the
  typed release directly. Expected −150 to −250 ms here (estimate between A and today).
  Cost low to medium, in runtime.zig's drop path and emit's drop calls, no new facts.
  Risk low: release order and the depth bound stay. **It helps every program that drops
  boxes, Lists of boxes and trees.**
- **A free list per task for one size class: a further −20 to −60 ms wall, −0.5 s CPU
  measured (B).** The best an inlined fast path could do, since program code may not read
  the thread's heap (alloc.zig:2531-2540); a task-owned list sidesteps that. Frees are
  already sized (`destroy` passes `@sizeOf(T)`, runtime.zig:6744-6749). It holds memory
  until the task ends and needs a cap. Cost medium, gain small: not before regions.
- **Freeing a tree without recursion** (pointer reversal, an explicit stack) still visits
  every node: at most A's gain, which caching `task()` gets more cheaply.

## 3. Smaller nodes

`^Tree?` is already 8 bytes with the null niche (`Opt` of a `__rig_box`,
runtime.zig:837-840), and `Tree` 16 bytes, as Rust's `Box<Node>` node is. The only
narrower node is two 32-bit offsets, the fast port's. Measured inside a region (E): **no
gain in time** (0.33 vs 0.32 s), 82 MB less peak memory. The compiler could do it only
for a region-made value, as a second layout of the type with every function that reads
it cloned (here `item_check`). Cost high, risk medium (two layouts of one type), gain
memory only. Not recommended.

## 4. Building in place

`Box(T).init(value)` (runtime.zig:3038) allocates, then stores the 16-byte value, which
arrives in two registers from the recursive call: two stores either way, and the region
probes keep that shape and still reach 0.28 s. Expected gain about 0 ms for this node
(estimate; it matters for a large `T`, which `Box.fill` already handles for arrays,
runtime.zig:3046). Not worth doing for this.

## Could the plain port reach ~200 ms by optimization alone?

**No: about 280 ms, measured (F), against 210 ms for the fast port in the same boards.**
Regions take the time from 0.87 to 0.28 s and CPU from 6 to 2 s, beating Rust's plain
port (408 ms) and within 1.3x of the fast port. The remaining 70 ms is not the parallel
shape (G, the same with each depth's trees cut into tasks, 0.27 s) and not node size
(E). CPU is still 15-20% above the fast port's (2.0 vs 1.75 s), and the stretch tree's
fresh 1 MB chunks are touched while nothing else runs; those are the likely remaining
causes (unmeasured).

## Ranking (ms gained against cost)

| # | Mechanism | Gain on the plain port | Cost to build | Risk |
|---|---|---:|---|---|
| 1 | Region inference for read-only temporaries and locals of region-pure producers | −590 ms (measured, F) | High: a post-check pass, two facts, a clone in emit, a runtime `Region`, debug tagging | Medium: a wrong proof is a use after free |
| 2 | Typed drop glue, `task()` read once per drop root | −150 to −250 ms (A, −250, measured as the bound) | Low-medium: runtime and emit | Low |
| 3 | Per-task free list | −20 to −60 ms more (B, measured) | Medium | Memory held; needs a cap |
| 4 | Narrow nodes in a region | 0 ms (E, measured); −82 MB | High | Medium |
| 5 | Building in place | ~0 (estimate) | Low | Low |

1 and 2 do not add: with a region there is no drop left to speed up. 2 is the cheap win
for every program; 1 is the one that matters here.

## Recommended path to ~200 ms

1. Typed drop glue (2) now: cheap, general, −150 to −250 ms on the plain port as it is.
2. The decided `Arena[T]`: its runtime is C's, so a plain-like port with an arena should
   time about 0.28-0.34 s, the arena around the long-lived tree included.
3. Region inference (1) only if the plain port, unchanged, must be fast. It reuses the
   arena's runtime with the compiler choosing where, and it measures at 0.28 s.
4. The last 70 ms is per-node CPU, not shape or node size: profile F against the fast
   port before building anything for it.

## Decisions for the owner (defaults)

1. Typed drop glue that reads `task()` once per drop root. **Default: yes**, before any
   arena work.
2. Region inference as an optimization. **Default: not now**: after `Arena[T]` lands,
   reusing its runtime, if the unchanged plain port must be fast. It is the only route
   that leaves the source alone, and it measures at 0.28 s.
3. If it is built, a note on what is and is not a region. **Default: yes**, so a distant
   edit that turns it off is visible.
4. The 200 ms target. **Default: hold it for the arena port**; the plain port's realistic
   ceiling by optimization is ~280 ms.

## Biggest risk

Region inference's proof. Its failure is silent memory corruption in release, and it
depends on the ownership checker's guarantee that nothing outlives a read-only temporary
(already relied on everywhere) and on the new region-purity inference: a heap box in a
region-made value would leak, and a region box kept by a heap value would dangle. Debug
builds that tag region boxes and free them at the reset, under `RIG_SANITIZE`, catch it
on the paths the tests run, not on the others.
