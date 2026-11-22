# binarytrees in 200 ms: the performance view (2026-11-21)

Panelist: performance. Read only. Rig 0.3.0 at `5cd726a84` (main). Probes, scripts and raw
output are in `probes-perf/`: the emitted Zig (`plain.zig`, `fast.zig`), the release
binaries, a `sample` profile of each (`prof-plain.txt`, `prof-fast.txt`), and a C model of
each mechanism (`floor.c`, results in `bench*.out`). All timing ran under `tools/mac-claim`
(four claims: `bt200-perf`, `-perf2`, `-perf3`, `-perf4`); other sessions were building
between claims, so single runs are good to about ±10%. **Measured** and **estimate** are
marked throughout.

## 1. Where the plain port's 877 ms goes

### What the emitted code does per node (read from `plain.zig` and the disassembly)

- `Tree` is two `rig.Opt(rig.Box(Tree))`. A box's optional keeps `none` in the null address
  (runtime.zig:838, `Niche`), so **`^Tree?` costs 8 bytes and a node 16**. That is a 16-byte
  size-class block with no header (alloc.zig keeps headers per segment), the same size as
  Rust's `Option<&Tree>` pair. Node size is not the plain port's problem.
- **Build**: `rig.Box(Tree).init(bottom_up_tree(d-1))` (runtime.zig:3039): one call to
  alloc.zig's `alloc` (alloc.zig:2642), which is `noinline` by design (alloc.zig:2531-2540:
  a fiber may resume on another thread, so program code never reads a thread-local). Inside,
  `my_heap()` is a Zig `threadlocal`, which on macOS compiles to a call through the TLV
  descriptor (`blr x8` into `_tlv_get_addr`). Nodes are allocated children first
  (post-order).
- **Check**: `item_check` is tight (two loads, two tests, two calls, overflow checks).
  `rig.tickCall()` is a no-op in this preempted build (`__rig_preempt = true`; runtime.zig:555).
- **Drop**: per node, `Box.__rig_drop` (runtime.zig:3061) -> `releaseNested`
  (runtime.zig:2821) -> `task()` -> `sched.current()`, a never-inlined `currentOf` under
  preemption (sched.zig:424) with its own `_tlv_get_addr` call -> depth counter up, recurse
  into both children, counter down, queue test -> `free` (alloc.zig:2657), another
  `noinline` call with a third `_tlv_get_addr`, a load of the segment header, a store.
  So each node costs **three noinline runtime calls and three TLS lookups**, and is visited
  three times (build, check, drop).

### Profile (measured: `sample`, n = 22, the parallel phase, 9,147 busy samples)

| Function (top of stack) | Share | Belongs to |
|---|---:|---|
| `_tlv_get_addr` (libdyld) | 22.5% | TLS: 1/3 alloc, 2/3 drop |
| `Box(Tree).__rig_drop` | 18.0% | drop |
| `item_check` | 13.7% | check |
| `bottom_up_tree` | 12.9% | build |
| `alloc.alloc` | 12.7% | allocation |
| `alloc.free` | 12.5% | drop |
| `sched.currentOf` | 7.0% | drop (`task()` for the drop depth) |

Grouped: **drop ≈ 52%, allocation ≈ 20%, build 13%, check 14%**. Cache misses do not stand
out: the free lists stay roughly address-ordered because every tree frees in post-order and
the next pops LIFO, so the scattered-node cost the brief asks about is small here (the C
models below agree: building in walk order against post-order moved 2 ms at the 64-way
split). The fast port's profile is 50% `bottom_up_tree`, 50% `item_check`, nothing else.

### The rest (measured runs, n = 21)

| Program | Wall | User CPU | RSS |
|---|---:|---:|---:|
| Rig plain `--release` | 0.81, 0.81, 0.90, 0.96 s | 5.5-6.0 s | 174 MB |
| Rig fast `--release` | 0.23, 0.24 s (0.33 once) | 1.66 s | 345-370 MB |

- Per node, the plain port spends about **9.3 ns of CPU** (5.7 s / 616 M nodes), the fast port
  2.7 ns.
- **Task split**: 9 `Tasks`, one per depth, each about 67 M nodes (2^(25-d) trees of
  2^(d+1) nodes). The M5's 10 cores are **4 P + 6 E** (`hw.perflevel0/1.physicalcpu`). In the
  profile every worker was busy, and macOS moves threads to P cores as they free up, so the
  split costs less than the CPU column suggests: 5.7 s / 0.85 s is 6.7 cores busy, and the
  rest is the serial phase.
- **Serial phase** (estimate): the stretch tree (8.4 M nodes, built, checked, dropped) and the
  long-lived tree's build run on one core before any task starts, and its check and drop
  after: about 70-90 ms at the plain port's per-node cost.

## 2. The floor on this machine

The C model (`floor.c`, clang -O3, pthreads over a shared job queue; output byte-identical to
the Rig ports) isolates each mechanism. Measured, n = 21, 10 threads, after removing false
sharing from the first version (its per-worker bump pointers shared cache lines; those runs
are discarded):

| Model | Total | Serial (stretch + long-lived) | Depths | CPU |
|---|---:|---:|---:|---:|
| **b8**: 8-byte nodes, 4-byte index links, inline bump, walk order, 64 runs/depth | **203 ms** | 35 ms | 169 ms | 1.57 s |
| **b16**: 16-byte pointer nodes, otherwise b8 | 231-237 ms | 43 ms | 188-192 ms | 1.71 s |
| **b16p**: b16 built post-order, as an arena `add` must build | 233 ms | 42 ms | 191 ms | |
| **nb**: b16, but the bump is a noinline call reading a thread-local (runtime.md's M1) | 260 ms | 38 ms | 222 ms | |
| b16, one task per depth | 230 ms | | 190 ms | |
| b16p, one task per depth | 295 ms | | 251 ms | |
| nb, one task per depth | 303 ms | | 264 ms | |
| b8 / b16 / b16p / nb on 1 thread | 1.33 / 1.31 / 1.38 / 1.42 s | | | |

(`b16d`, b16 plus a drop walk, is not reported: it stored to one shared global per node and
measured false sharing, not the walk.)

What this says about the floor:

1. **About 200 ms is the floor itself, not a target with headroom.** b8 at 203 ms matches
   Rust fast + mimalloc (205 ms) and Rig fast (219 ms). The depth phase runs 9.3 cores busy
   (1.57 s CPU in 169 ms), so it is core-bound: about 2.2 ns a node on a P core, slower on
   the E cores.
2. **Memory bandwidth is not the limit.** Single-threaded, 8- and 16-byte nodes cost the same
   (1.33 against 1.31 s). Only the depth 18 and 20 trees (8-32 MB at 16 bytes) leave a core's
   share of L2; that is about 7-9 GB of DRAM traffic over 190 ms, 40-50 GB/s, well under the
   M5's limit (estimate). 16-byte nodes cost about 20-30 ms at 10 threads (b16 against b8),
   from cache capacity, not bandwidth.
3. **The serial phase is 35-43 ms** in every design: a sixth to a fifth of the budget, spent
   on one core while nine wait. About 8 ms of the stretch tree is page faults on 134 MB of
   fresh memory at 16 bytes (single-threaded stretch at 3.1 ns a node against 2.2 in the
   reused depth phase). Only building one tree in parallel would remove it, which the
   program, not the language, would have to say.
4. Rust fast's mimalloc edge (233 to 205 ms) is bumpalo's chunks: a `Bump::new()` per tree
   gets and frees chunks up to 32 MB, and mimalloc keeps them warm. **An arena per tree is
   only as fast as its chunk cache.**

## 3. The budget: plain port to about 200 ms

Starting at 877 ms. The first two rows are the decided arena; the gains are estimates built
on the profile shares and the C models, in the order they would be built.

| # | Mechanism | Gain | Lands at | Evidence | Cost to build |
|---|---|---:|---:|---|---|
| 1 | **No per-node drop**: arena contents copy, one free per arena (decided) | ~400 ms | ~480 | drop is 52% of samples | the arena (decided) |
| 2 | **Bump instead of a free-list pop + TLS**, behind the noinline call (runtime.md M1) | ~170 ms | ~310 | alloc + its TLS 20%; nb, per-depth tasks, 303 ms | part of the arena |
| 3 | **Inline bump fast path**: `cur + size <= end` emitted at `!a.add`, on the arena value itself (no thread-local: the arena is a value the code holds), new chunk behind a noinline call | ~10-40 ms | ~280 | nb 260 against b16 231 (64 runs), 303 against 295 (per depth) | small: emit + one runtime helper |
| 4 | **Arena chunk cache**: a dropped arena's chunks go back to a per-heap cache, large ones included; first chunk small (about 1 KiB) or carved from the size classes, so `Arena.new()` per tree is two small operations | keeps 25-30 ms from being lost (2.8 M arenas a run, 32 MB chunks at depth 20) | (same) | Rust fast: system malloc 233 against mimalloc 205 | small-medium, alloc.zig |
| 5 | **Split each depth's trees across tasks** (`par.map` over runs in `inner`, as the fast port does) | ~40-60 ms | ~235 | b16p 295 to 233; nb 303 to 260 | none in the language; the program changes |
| 6 | **8-byte nodes** (4-byte links) | ~20-30 ms | ~205-215 | b8 203 against b16 231-237 | large: a 4-byte arena view (below) |
| 7 | Build in walk order | 0-2 ms (64 runs) | | b16 vs b16p | impossible with copy-in `add`; not needed |
| 8 | Prefetching | ~0 | | walk is near-sequential in both orders | none |
| 9 | Huge pages | 0 on the Mac | | macOS arm64 gives user code no superpages (16 KB pages); TLB reach is not the limit | n/a (pup only) |
| 10 | Serial phase (stretch + long-lived) | ≤10 ms realistic | | 35-43 ms in all models; ~8 ms page faults | rule-bending to remove fully |

Row 6 in more detail. An arena view is a pointer, 8 bytes (arenas SYNTHESIS, "Open risks").
A 4-byte view could be **self-relative inside an arena**: each arena reserves an aligned
virtual range (as alloc.zig's `reserveTable` already does for Tables), and a view field of a
value held in that arena stores a 32-bit offset; reading it is `(field_addr & ~mask) | off`.
The catch is that the same `Node` type may live outside the arena (a local holding views),
so the narrow form has to follow the type, for example a node type declared for one arena,
which is a language decision under CORE §10, not an optimization emit may choose alone.
That is a large change for 20-30 ms.

**Without row 6, the plain port with an arena lands at about 230-250 ms (estimate);** with it,
about 205-215. Without row 5 (one task per depth kept), about 280-300 ms.

### Two findings beside the arena

- **macOS TLS is 22.5% of the plain port's CPU.** Every Zig `threadlocal` in alloc.zig and
  sched.zig is a call to `_tlv_get_addr` on macOS (three per node here). Reading the thread
  pointer (`TPIDRRO_EL0`) and a fixed slot directly, or caching the heap in the worker
  record, would speed every allocating Rig program on the Mac (estimate: the plain port
  877 to about 700 ms). It does not matter for the arena path once its bump is inline.
- **The drop depth counter costs a `task()` call per box** (`currentOf` is 7% by itself plus
  its TLS). A box of a type whose recursion depth is bounded by its own data cannot avoid
  it, but a release build could keep the counter in the heap record that `free` already
  loads.

## 4. Recommendation

1. Build the arena with the inline bump (row 3) and a chunk cache (row 4) from the start;
   runtime.md's noinline bump leaves 10-40 ms on the table.
2. Write the plain port's `inner` with `par.map` over runs, each making a fresh arena per
   tree (row 5): that is code close to the plain port, and it is how Rust's fast port is
   written.
3. Measure; expect about 230-250 ms. Decide row 6 only if the last 30 ms matter.

## 5. Decisions for the owner (defaults)

1. **Inline bump at `!a.add`**, on the arena value, no thread-local. Default: yes.
2. **Arena chunks recycled through a per-heap cache**, big chunks included. Default: yes.
3. **The plain port splits each depth's trees with `par.map`**, as the fast port does.
   Default: yes, it is the benchmark's own fast shape and needs nothing new in Rig.
4. **4-byte arena views (8-byte nodes)**. Default: no for now; revisit after measuring 1-3.
5. **macOS TLS fast path** in alloc.zig and sched.zig, as its own change. Default: yes, a
   separate runtime item, not part of the 200 ms path.

## 6. Biggest risk

The 200 ms target is the machine's floor (C at 203 ms, Rust at 205), so every remaining
cost shows: with 16-byte nodes the best measured model is 231 ms, and the per-tree arena
(2.8 M of them, each a `*` count plus chunks) adds cost no C model paid. Expect about 230 ms
from natural code unless 4-byte views are built.
