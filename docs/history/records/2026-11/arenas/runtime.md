# Arenas in Rig: the runtime and codegen view

Panelist: runtime and codegen. Read only; one probe (`rig emit` of the plain binarytrees, in
`probes-runtime/`). Rig at `11c888df1`. No timing was run; every number below is either quoted
from a file (cited) or an estimate, marked as one.

## 1. What allocation looks like today (verified)

- **Every value allocation goes through four runtime helpers**: `create` (runtime.zig:1973),
  `allocSlice`, `reallocSlice`, `freeSlice`, `destroy` (runtime.zig:6664-6749). They call
  `defaultAllocator()` (runtime.zig:6634), which is `HeapProfile` under `RIG_HEAP_PROFILE`, the
  `LeakChecker` in a debug build (on `Sanitizer` with `RIG_SANITIZE`, on `SafeAllocator` with
  `RIG_LEAK_TRACE`), and `fast_alloc.allocator` (alloc.zig:2616) in a release build. The
  allocator is a comptime-known vtable, so in release the call devirtualizes to alloc.zig's
  `alloc`/`free` (alloc.zig:2642, 2657): a **never-inlined call** that reads the thread's heap
  from a thread-local and pops or pushes a free list. The noinline is load-bearing: a fiber may
  resume on another thread after any switch, so program code never reads a thread-local itself
  (alloc.zig:2531-2540, runtime.zig:6570-6590).
- **Who calls them.** `^v` is `rig.Box(T).init(v)` (emit.zig:10677, runtime.zig:3032); `*T` is
  `rig.shared(v)` (runtime.zig:3011) over `Counted` (runtime.zig:2715); an owned closure is
  `rig.create(Env)` then `Closure.init` (emit.zig:11183, runtime.zig:3253); `List` grows only
  through `growBy` (runtime.zig:3626) and `String` through its own `growBy` (runtime.zig:4342);
  `Map`/`Set` (ordered.zig:311, unordered.zig:422) use the same helpers. Task records are *not*
  value allocations: `allocRecord` (alloc.zig:2739, sched.zig:6603) straight from the heap.
- **The runtime's own persistent allocations** call `defaultAllocator()` directly: 18 sites in
  runtime.zig, 20 in tasks.zig, 3 in net.zig (e.g. the drop queue, runtime.zig:2824). These must
  never land in a region.
- **No value stores an allocator** (INTERNALS.md:5797, verified in `ListOf`, runtime.zig:3492:
  `buf`, `len`, optional inline room; `Box` is one pointer; `Closure` three words).
- **Drop glue per node.** The probe shows the plain binarytrees' `Tree` drop: `dropFields` ->
  `Box.__rig_drop` -> `releaseNested` (reads `task()`, a call in a scheduled build,
  sched.zig:424; bumps a depth counter) -> `releaseErased` -> `dropElement` -> `destroy` -> the
  noinline `free`. So each node costs one allocator call to make and a task read, two counter
  updates and an allocator call to drop.
- **The leak checker already tags allocations by a dynamic scope**: each allocation made under a
  `task.isolate` records the isolate's id (`LeakChecker.tags`, runtime.zig:7306-7312), and a
  panic marks what it left as left, not leaked (`leaveFrom`). A region tag is the same pattern.

## 2. The mechanisms compared

### M1. A task-local "current region", switched at region entry (dynamic scope)

Routing: every *value* allocation asks "is a region open on this task?" and bumps if so.

- **Where the test goes.** Not in the inline helpers: program code may not read a thread-local,
  and `task()` is a call in a scheduled build. Put it inside alloc.zig, in a second noinline
  entry `allocValue` beside `alloc`, which already holds the heap: `if (h.region) |r| bump`.
  The region pointer lives in the fiber's `TaskState` and is mirrored into the running thread's
  `Heap` at region entry and exit and at every fiber resume (one store per switch). The
  runtime's own allocations keep calling `alloc`, which never looks.
- **Cost against today**: for a program that opens no region, nothing (a root flag,
  `__rig_regions`, as `__rig_memory` gates `counts`, alloc.zig:139). For one that does, every
  heap allocation pays one load from the heap it already read and a predicted branch (estimate:
  under half a nanosecond; place `region` beside `free` in `Heap`), and every fiber resume one
  store. The bump itself stays behind the noinline call: about the cost of today's free-list pop,
  not bumpalo's inlined bump.
- **Task switches.** A fiber that moves to another thread takes its region with it, because the
  region is in its `TaskState` and resume rewrites the new thread's heap. The region's chunks
  belong to the heap that made them; freeing them at close from another thread goes through the
  remote path that already exists (alloc.zig:552-568, spans under their lock).
- **A value freed after the region closes** is the real danger, and dynamic scope makes it
  easy to create: anything allocated in the dynamic extent lands in the region, including an
  outer `List` grown inside it, a `String` pushed into an outer `Map`, a value sent on a channel,
  a task's result. So M1 is sound only with a sema rule on the region body (section 4): it is
  checked like a task body, captures by view or copy only, writes no owning place from outside,
  and its result leaves as plain data or is cloned out at close.
- **Completeness**: total. It reaches every allocation in the extent, including through
  closures (`Closure.invoke_fn` is type-erased), API objects (`ApiBox` vtables), std code and
  the runtime's value builders (`String.of`). That is what makes skipping drop glue safe
  (below).

### M2. Compile-time specialization: a hidden comptime parameter per allocating function

- Each function that allocates, transitively, takes `comptime where: enum { heap, region }`
  (plus the region pointer, a runtime value) and is instantiated per kind; an allocation lexically
  in a region body inlines the bump. Fastest per allocation.
- **Cost**: the transitive closure of "allocates" covers most of a real program (any
  `String`, `List`, `print` formatting). Every function reachable from a region body is emitted
  twice; Trig would roughly double the Zig it compiles for that part, and Rig already splits
  builds to keep Zig's compile time down (`split.zig`). The emitter needs a call graph and a
  fixpoint it does not have today.
- **It cannot be complete**: closures, `FnRef` views, API objects and every type-erased call
  cannot carry a comptime parameter, so they fall back to the heap. A region value that owns one
  heap block then cannot skip its drop glue, which removes most of the gain, or it needs M1's
  dynamic test anyway as the fallback.
- **Verdict**: not as the mechanism. As a later optimization on top of M1, the emitter may
  inline the bump for allocations it can see are lexically inside the region body.

### M3. Values carry where they came from (a tag in List, String, box)

- A tag word makes every `List` and `String` 24 bytes instead of 16, everywhere, in every program
  (Trig's heap and Tables are mostly Lists and records of them). `^T` is a bare pointer with no
  room. Stealing pointer bits costs a mask on every access.
- **Better: provenance by address.** Reserve the regions' chunks in an address range of their own,
  as alloc.zig already does for Tables (`reserveTable`, INTERNALS.md:5763). Then
  `inRegion(p) = (p -% region_base) < region_len`: two loads of hot globals and a compare, no
  load of the block or a header, no field in any value. `freeSlice`/`destroy` return at once for
  a region block; `reallocSlice` grows it in the region. Gated by `__rig_regions`, so other
  programs pay nothing. This gives M3's correctness at none of its cost.

### M4. The recommendation: M1 + address provenance + memory-only drop skipping

Runtime pieces:

```text
Region (on the fiber's stack, linked):
  parent: ?*Region
  cur, end: [*]u8          // bump window in the current chunk
  chunks: list of chunks   // 64 KiB first, doubling, from the region range
  big: list of own-chunk blocks (above big_min, e.g. 64 KiB)
  depth: u32               // the TaskState region depth, for unwinding

enterRegion(r):  r.parent = task().region; task().region = r; heap.region = r   (noinline)
leaveRegion(r):  return r's chunks to the heap's chunk cache (bounded, warm/cold as spans are);
                 task().region = r.parent; heap.region = r.parent
allocValue:      if heap.region |r| and len <= big_min: bump (align, test end, else new chunk)
                 else if heap.region |r|: own chunk in the region range, linked in r.big
freeSlice/destroy:  if regions and inRegion(p): own chunk ? return it now : no-op
reallocSlice(old):  if inRegion(old): last bump ? extend in place
                                     : own chunk ? remap the chunk
                                     : bump new, copy, old is waste
```

Emitted shape for `region` around an expression (surface syntax is the language panel's):

```text
{ var __rig_region_3: rig.Region = undefined; rig.enterRegion(&__rig_region_3);
  defer rig.leaveRegion(&__rig_region_3);
  const __rig_val = <body>;              // result plain data, or
  break :blk rig.cloneOut(&__rig_val);   // cloned to the parent allocator before leave
}
```

## 3. The specific questions

**Growing a List in a bump arena.** Doubling leaves every old buffer behind: the waste is at most
the final capacity again (the geometric sum), so a List built in a region can take up to twice
its memory. Three cuts: (a) a buffer at the bump top extends in place (bumpalo's trick; a List
built alone, the common case, then wastes nothing); (b) above `big_min` a buffer gets its own
chunk, whose growth is a real remap and whose free is real, so only small Lists waste, and only
up to `big_min` each; (c) `List(capacity: n)` already allocates exactly (runtime.zig:3542).

**Frees in a region become no-ops** by the address test in `freeSlice`/`destroy`, before the
allocator is reached; alloc.zig's fast `free` is never handed a region block (its `segmentOf`
would read a region chunk as a segment header, alloc.zig:2687-2692, so the test must come first).

**Skipping drop glue for the bulk free.** Making frees no-ops still walks the tree: a dropped
`Tree` visits every node to free nothing, which costs about what freeing did. The walk can be
skipped at the root when two things hold:
1. `T`'s drop glue is **memory only**: no user `drop` body, no `*T`/`~T` (counts outside the
   region), no resource (file, socket, task handle, channel). A comptime predicate beside
   `needsDrop` (runtime.zig:1215), `dropsOnlyMemory(T)`, from sema's `typeHasDropGlue`.
2. **Everything an arena block owns is in the arena.** M1 gives this for free inside the extent;
   the sema rule (no owning value moved in from outside, no owning value received from a channel
   or task, no growth of outer places) closes the rest.

Then `Box.__rig_drop` / `List` drop / `dropFields` begin with
`if (regions and comptime dropsOnlyMemory(T) and inRegion(ptr)) return;`: one range test per
dropped root instead of a walk. Types that are not memory-only keep their glue (it still runs, its
frees become no-ops).

**Panics.** A panic caught by an `isolate` must close the regions opened under it:
`TaskState` keeps the region depth, and the isolate's cleanup pops to its saved depth
(the leak checker's isolate tags, runtime.zig:7306, are the model).

**Debug and test builds.** The region in a debug build is a *tracking* region over the
`LeakChecker`'s own allocator, not a bump: each region allocation is a real block, tagged with the
region's id as isolates tag theirs. In-region frees are real frees (stricter than release, which is
allowed since safe Rig cannot use a value after its drop). Drop skipping is the same as release
(the same comptime test, with `inRegion` meaning "tagged with an open region"), and
`leaveRegion` frees every block still tagged with it. Consequences:
- Under `RIG_SANITIZE` (the test suite) each block has its own pages and a free makes them
  inaccessible (INTERNALS.md:5797), so **any use after region close crashes at the access**,
  with the stack. No new mechanism.
- The leak checker reports any heap block an arena value owned and the skipped walk never freed:
  a broken invariant 2, i.e. a compiler bug, shows as a leak in the test suite rather than as a
  silent leak in release.
- Debug must *not* run the full glue where release skips it, or it would hide exactly that leak.

**Heap profiles.** `RIG_HEAP_PROFILE` keeps `HeapProfile.owner(T)` (runtime.zig:6764) on each
region allocation and counts its bytes under `T` *and* a `region` total; `leaveRegion` subtracts
the region's bytes in one step. `=sites` names the region's entry. `os.memory` counts the chunks
as heap blocks (they come from alloc.zig), so its live figure stays honest; used bytes vs chunk
bytes is a free second number.

## 4. What the runtime needs from sema (for the language panel)

The region body is checked like a task body: captures by read view or copy; no write view of an
owning place made outside; no owning value moved in; no channel receive, task wait, `par.*`, or
actor call that yields an owning value; tasks started inside are waited inside. The result is
plain data, or is cloned out (`cloneValue`, runtime.zig) after the region's routing is popped and
before its chunks are freed. Without these, M1 dangles; with them, M1 is complete and sound.

## 5. binarytrees: what it would gain (estimates)

Node counts at n = 21: 9 depths x ~2^26 nodes, plus the stretch and long-lived trees, about
616 M nodes made and dropped.

- **The fast port gains about nothing.** It already allocates nothing per node: `!pool.keep(0)`
  only sets `len` (runtime.zig:3833-3837), so after its first tree every `push` lands in kept
  capacity. Its 6% on pup (328 vs 308 ms, results.md:37-48) comes with 19% more CPU (4.49 vs
  3.76 s) and is not the allocator's; bounds checks on `pool[at]`, `push`'s capacity test and the
  scheduler are the candidates. An arena of 16-byte pointer nodes against its 8-byte `I32` nodes
  might even lose on memory. **README's "no arena" attribution for the pup gap is likely wrong.**
- **The plain port is where the gain is.** Today 803 ms wall, 5.82 s CPU on the Mac
  (results.md:161-172), about 9.4 ns of CPU a node, against Rust plain (typed_arena) 408 ms /
  2.92 s, 4.7 ns a node. With a region per tree in `inner`, each node costs one noinline bump
  call and no drop (one range test per tree): estimate 4.5-5.5 ns a node, CPU about 2.8-3.4 s,
  wall about 0.35-0.45 s, so **roughly 2x faster, about tying Rust's plain port**, still behind
  the fast port's 208 ms, whose edge is the 64-way `par.map` split. Lexical inlining of the bump
  (M2 as an optimization) might take another 0.5-1 ns a node.

## 6. Measuring

- **binarytrees**: the plain port with a region around `item_check(bottom_up_tree(depth))` in
  `inner`, against today's plain and fast ports, `compare/rig/benchmarksgame/run.sh`, Mac and pup,
  output md5 checked. Also a third port: the fast port's shape (64 runs) with boxes in regions, to
  separate the arena from the split.
- **Trig, before any design round** (IDEAS.md:73 asks for it): (1) the upper bound on time, the
  share of cycles in alloc.zig's `alloc`/`free`/`allocSlow`/`freeSlow` and in drop glue
  (`dropLast`, `releaseErased`, `__rig_drop`, `drainDropQueue`) from a perf profile of a check;
  (2) the share that dies together: a lifetime mode of `HeapProfile` that stamps each block with
  an allocation counter and, at free, files its lifetime under its site, and counts blocks freed
  within the same call of the function that made them. Trig keeps most data in Tables for the
  whole run (trig-memory/README.md: ts-pattern 98.5 MiB in Tables, 85.2 heap), so expect the
  candidates to be the checker's per-relation and per-instantiation temporaries, not the trees.
- Count `rig emit` size and Zig compile time for any M2 trial.

## 7. Risks

1. **Soundness rests on sema's region-body rule.** Dynamic routing captures everything in the
   extent; any path that lets an outer owner see a region block dangles in release. The test
   suite's sanitizer catches uses, the leak checker catches skipped heap blocks, but only on paths
   the tests run.
2. **Runtime allocations that must outlive the region** (the drop queue, map trace, lazily built
   std tables, `String.of` scratch that is cached) must use the heap entry. A missed one is a
   dangling runtime structure. Mitigation: the routing entry is opt-in (`allocValue` from the five
   helpers only); the 41 direct `defaultAllocator()` sites keep the heap.
3. **Memory**: List growth waste and chunk caches; bounded as above, measured with the heap profile.
