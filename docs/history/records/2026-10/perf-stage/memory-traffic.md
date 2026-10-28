# Where Trig's memory traffic comes from (2026-10-28)

**The question.** Rig's lookup code already matches hand-written Zig
([map-wide-keys.md](../hash-race/map-wide-keys.md)). What's left between
Trig and tsrs, a Rust port of the same checker, is mostly memory
traffic: cache and TLB misses, page faults, and allocation. Where does
that traffic come from, structure by structure, and how much of it can
Rig remove? The owner's method for speed work applies: first find the
fastest Zig, then make Rig emit it.

**The answer.** Trig and tsrs miss L1 and L2 about equally; the gap is
farther out. On ts-pattern Trig has 1.9× tsrs's L3 load misses,
3.2× its loads that miss the second-level TLB (STLB), 2.2× its page-fault
traps, and 2.6× its loads blocked by store forwarding. By the structure
each miss lands in:

- **Map indexes** hold a third of Trig's L3 misses and nearly half its
  STLB misses: the tag and slot arrays of three wide-key Maps.
- **Tables** hold a quarter of its L3 misses, a third of its STLB
  misses, and **81% of its page-fault traps**. tsrs keeps the same data
  (types, symbols, signatures) in one bump arena on 2 MiB pages, which
  take about 64 traps.
- **Large Lists** hold a fifth of its L3 misses: the AST's node and
  symbol arrays, built by doubling.
- **Map entries** hold a seventh.

The "6.4×" that Trig's research quotes for allocation (its
docs/research/09-speed-2026-10-20/B1.md) counts *instructions* in the
allocation-and-copy leaf, not bytes. By bytes, Trig's heap takes 361 MB
in 3.43M blocks on ts-pattern. tsrs's heap takes 252 MB in 2.4M blocks,
plus 134 MB of bump arena: about the same total.

Three ceiling experiments ran in one hand-edited build of Trig's emitted
Zig, each switched on at run time:

- **Huge pages for the large Map indexes** take out 24% of STLB misses
  and save no cycles. The walks overlap the DRAM misses they ride on.
- **Faulting in a Table 64 KiB ahead of `push`** takes out 64% of
  ts-pattern's traps and 7.4% of its kernel cycles, with 2.3% fewer
  user cycles. Peak memory rises 0.6% on ts-pattern and 2.0% on zod3.
- **Copying the `Relater` pool in place**, with emit's extra copies of a
  288-byte value gone, takes out 28-36% of blocked loads and saves 2.0%
  of user cycles on ts-pattern, none on zod3.

All three together: 2.2% fewer cycles on ts-pattern (user and kernel),
and wall times 1.3% (ts-pattern) and 3.0% (zod3) faster by the median,
on a busy pup. Each one is at or under the speed bar. The rest of the
gap is layout, Rig's and Trig's: Tables on small pages where tsrs uses
one arena on huge pages, three arrays per Map lookup where hashbrown has
two, and Trig's copies of stored lists.

Scripts, the private build's patch, and summaries are in
[memory-traffic-data/](memory-traffic-data/). Raw samples and traces
(about 6 GB) stay on pup in `/zfs/worktrees/rig/memory-traffic/`.

## Method

- **Builds.** Rig main `4d80efe17` (#740's merge, huge pages for the
  segments of a heap that faults in ahead), built on pup's E-cores
  12-15. Trig `403a823` (its `src/` and `tools/trig/main.rig`, from
  `git archive`), built `--release` through
  `/zfs/trig-pup/trial/slot.sh` on slot 10,11:
  - `rel`: the plain release build, for counts and for samples by
    instruction;
  - `trace`: built by a private Rig with frame pointers and an
    allocation trace. Neither is on main or meant for it;
    `alloc-trace.diff` is the patch.
  - `fp`: frame pointers alone.
- **The allocation trace** (`alloc-trace.diff`). `RIG_ALLOC_TRACE=1` at
  build time makes `defaultAllocator` a recorder in front of Rig's
  allocator. Each alloc, free, move and resize, and each reserved
  Table, writes one 64-byte record: the TSC, the address and length,
  the owner, and four return addresses from the frame-pointer chain.
  The owner is the type `allocSlice`, `reallocSlice` or `create` names,
  or a tag (`map index K -> V`, `map entries`, `table T`).
  - The records go to a 24 GiB `MAP_NORESERVE` buffer advised for huge
    pages, written out at exit with `/proc/self/maps`.
  - A ts-pattern run writes 6.87M records (440 MB), the same number in
    every run.
- **Samples.** PEBS samples with data addresses on core 3 (sibling 4
  idle; `pebs.sh`), checked against core 8 before each run. Five events
  at once, each at its own period: L1, L2 and L3 load misses, loads that
  missed the STLB, and loads blocked by store forwarding. pup caps
  samples at about 1,000 a second per event, so:
  - ts-pattern: 20 runs of `rel` and of tsrs, and 10 traced runs;
  - zod3: 40 runs of `rel` and of tsrs, and 30 traced runs;
  - each event comes to 9K to 16K samples.
- **Charging samples to structures** (`memtrace.py`).
  - The perf clock (`-k CLOCK_MONOTONIC`) is matched to the trace's TSC
    through two clock records.
  - Each sample's data address goes to the block live at that moment
    that holds it. A small block's start comes from its 64 KiB page's
    size class; a large block or a Table is looked up as an interval.
  - What lies outside the heap goes to its mapping (the binary's data,
    the stack, other anonymous memory).
  - `report.py` symbolizes the sites (`llvm-symbolizer --inlines`) and
    groups the volume and the samples by owner, by allocating mechanism,
    and by caller.
- **tsrs.** The source build `/zfs/trig-pup/tsrs/bin/tsrs`, which keeps
  line tables but no types (`strip = "symbols"` is off), in Go mode on
  one thread, as tsrs-standing.md ran it. It has no allocation trace,
  so its samples are charged by the code that made the access
  (`cat.py`): each sample's whole inline chain sorts it into a hash
  table (hashbrown), an arena read (`P<T>`), the allocator, or the rest.
  Trig's `rel` samples are sorted the same way, with Rig's Map, Table
  and List.
  - Allocation volume comes from mimalloc's own statistics
    (`MIMALLOC_SHOW_STATS=1`), and the arena from tsrs's
    `TSRS_MEM_SPLIT=1`.
  - The counts (`counts.sh`) also cover the shipped tsrs.
- **Faults** (`faults.sh`). Every trap, with its address
  (`-e page-faults -c 1 -d`), charged to its owner as above. tsrs's
  traps are charged by mapping.
- **Layout.** `layout.py` reads Trig's objects from the release binary's
  DWARF. tsrs's binary carries no type information, so its sizes come
  from the `size_of` asserts in its source.

Other sessions built Trig and Rig on slots 10,11 and 0,5 throughout, and
the four-hourly cron ran its builds. Load was 1.1 to 3. Counts and
samples were taken on core 3 with sibling 4 idle; timing was on core 8
(below).

## Whole-run counts

`counts.sh`: 5 rounds interleaved, medians. `rel` is Trig, `tsrs` the
shipped binary, and `tsrs-src` the source build that was sampled
(`out/counts.md`).

| ts-pattern | Trig | tsrs | tsrs-src | Trig / tsrs |
|---|---:|---:|---:|---:|
| user cycles | 4,214M | 3,010M | 3,652M | 1.40 |
| loads | 2,460M | 1,690M | 1,930M | 1.46 |
| stores | 1,151M | 860M | 1,111M | 1.34 |
| L1 load misses | 36.6M | 34.3M | 34.1M | 1.07 |
| L2 load misses | 2.88M | 2.86M | 3.18M | 1.01 |
| L3 load misses | 1.015M | 0.538M | 0.616M | **1.89** |
| loads blocked by store forwarding | 13.5M | 5.24M | 5.12M | **2.58** |
| loads that missed the STLB | 1.241M | 0.393M | 0.455M | **3.16** |
| stores that missed the STLB | 0.080M | 0.396M | 0.419M | 0.20 |
| dTLB load walk cycles | 85.1M | 32.7M | 33.6M | 2.60 |
| lines into L2 | 46.9M | 34.1M | 39.2M | 1.38 |
| kernel cycles | 335M | 168M | 170M | 2.00 |
| page faults | 39,820 | 17,810 | 17,690 | 2.24 |

| zod3 | Trig | tsrs | Trig / tsrs |
|---|---:|---:|---:|
| user cycles | 766M | 508M | 1.51 |
| L1 load misses | 5.83M | 5.12M | 1.14 |
| L2 load misses | 0.557M | 0.435M | 1.28 |
| L3 load misses | 0.222M | 0.081M | **2.75** |
| blocked loads | 2.44M | 0.78M | **3.14** |
| loads that missed the STLB | 0.106M | 0.018M | **5.80** |
| dTLB load walk cycles | 8.66M | 3.07M | 2.82 |
| kernel cycles | 92.8M | 48.1M | 1.93 |
| page faults | 9,232 | 5,412 | 1.71 |

Trig and tsrs miss L1 and L2 alike. The gap is what reaches DRAM and
the page tables: L3 misses, STLB misses, walks, and faults. tsrs
*stores* miss the STLB five times as often as Trig's do. Its bump
arena and mimalloc heap write new memory spread out; Trig's writes
land in the faulted-ahead heap segments.

## 1. Misses by data structure

**Trig, ts-pattern,** charged to the block each address lies in (10
traced runs; `out/ts-pattern.trace.md`). Shares of each event:

| structure | L1 misses | L2 misses | L3 misses | STLB load misses |
|---|---:|---:|---:|---:|
| Map indexes (tags and slots) | 9.9% | 31.9% | **33.7%** | **47.0%** |
| of which `InstantiationKey -> u32` | 3.4% | 13.1% | 13.8% | 20.5% |
| `CacheKey -> u32` | 2.5% | 9.4% | 11.0% | 15.2% |
| `CachedTypeKey -> u32` | | 4.5% | 4.3% | 6.3% |
| `u32 -> MappedSymbolLinks` | | 2.2% | 2.7% | 3.6% |
| Map entries | 4.8% | 9.1% | 13.4% | 8.7% |
| Tables (reserved) | 33.6% | 26.5% | **25.4%** | **30.9%** |
| of which `Type` | 9.6% | 5.4% | 4.6% | 3.7% |
| `u32` (the type, symbol and node lists' spans) | 4.3% | 4.2% | 3.9% | 5.0% |
| `StructuredType` | 3.0% | 2.8% | 3.0% | 3.0% |
| `ValueSymbolLinks` | 3.2% | 2.1% | 1.8% | 1.7% |
| Lists grown by push | 28.3% | 23.1% | 21.1% | 9.6% |
| of which `ast.NodeRec` | 7.2% | 6.5% | 6.1% | 2.8% |
| `ast.SymbolRec` | 4.3% | 3.0% | 2.8% | |
| Lists made to size (`List(capacity:)`, clones) | 6.7% | 3.0% | 2.8% | 0.2% |
| the binary's data (lib files, constant tables) | 6.6% | 4.1% | 3.0% | 3.2% |
| other anonymous memory (task stack, runtime) | 8.4% | 1.5% | 0.3% | 0.4% |
| freed blocks (the allocator's free lists) | 1.7% | 0.7% | 0.2% | |

**zod3** (30 traced runs) shifts toward parsing. Lists grown by push
take 40.4% of L3 misses (`NodeRec` 11.2%, `SymbolRec` 5.3%). Tables
take 24.2% of L3 and 39.4% of STLB misses, and Map indexes 10.2% and
13.2%. The binary's data takes 9.8% of STLB misses: the bundled lib
files, read from 4 KiB file pages.

**Against tsrs, by the code that made the access** (`cat.py`; misses =
share × whole-run count; tsrs is the sampled source build):

| ts-pattern | L3, Trig | L3, tsrs | ratio | STLB, Trig | STLB, tsrs | ratio |
|---|---:|---:|---:|---:|---:|---:|
| hash tables (Rig Map; hashbrown) | 500K | 365K | 1.4× | 706K | 290K | **2.4×** |
| Tables; tsrs's arena (`P<T>`) | 163K | 95K | 1.7× | 272K | 62K | **4.4×** |
| List reads | 95K | (in its code) | | 63K | | |
| memcpy and memset | 46K | (in hashbrown) | | 2K | | |
| allocator | 3K | 17K | | 0K | 33K | |

| zod3 | L3, Trig | L3, tsrs | STLB, Trig | STLB, tsrs |
|---|---:|---:|---:|---:|
| hash tables | 37K | 23K | 19K | 8K |
| Tables / arena | 34K | 22K | 34K | 4K (8.7×) |

L2 misses in hash tables and Tables are about equal (1.30M against
1.56M, 0.49M against 0.56M): the same structures are touched about as
often. Trig's are farther away:

- **Tables on 4 KiB pages against tsrs's arena on 2 MiB pages.** tsrs
  keeps every type, symbol and signature in a per-thread bump arena.
  After a thread's first 1 MiB, the arena's chunks are aligned to 2 MiB
  and advised `MADV_HUGEPAGE` (its notes/linux-x86-round.md, "2-6% less
  wall time"). The arena holds 128 MiB on ts-pattern, all in huge
  pages (`TSRS_MEM_SPLIT`). Trig's 40-odd Tables each have their own
  reservation, advised `MADV_NOHUGEPAGE`, because a huge page at each
  of 40 frontiers would commit up to 2 MiB apiece
  ([alloc-seg-thp/](../alloc-seg-thp/README.md), "tbl": 3.3-3.9% faster
  on ts-pattern, 4-16% more peak memory).
- **A Map lookup touches three arrays where hashbrown touches two.** The
  index's tags (16 B a group), its slots (64 B a group, prefetched with
  the tags), and the entries. hashbrown keeps control bytes and
  buckets in one allocation. tsrs's tables are on 4 KiB pages too
  (mimalloc `no_thp`). The largest Trig indexes are 2.5 MiB
  (`InstantiationKey`, `CacheKey`) and 1.25 MiB (`CachedTypeKey`), each
  in its own mapping on 4 KiB pages.

## 2. Allocation volume

Every allocation of a traced run (`report.py`, "Volume"), and tsrs's
from mimalloc and its arena:

| | ts-pattern | zod3 |
|---|---:|---:|
| Trig, heap: bytes requested | 361.3 MB | 123.5 MB |
| Trig, heap: blocks | 3.43M | 0.57M |
| Trig, live blocks at the peak | 140.7 MB | 51.5 MB |
| Trig, Tables written (traps × 4 KiB) | about 133 MB | about 26 MB |
| tsrs, mimalloc: bytes | 251.9 MB | 52.7 MB |
| tsrs, mimalloc: blocks | 2.4M | 0.45M |
| tsrs, mimalloc: live at the peak | 59.6 MB | 12.3 MB |
| tsrs, bump arena used | 134.2 MB | 29.6 MB |

Trig requests 1.43× tsrs's heap bytes and blocks on ts-pattern and 2.3×
the bytes on zod3. Its Tables, tsrs's arena's counterpart, hold about
as much. Trig's peak of live heap blocks is 2.4× tsrs's.

**By mechanism, ts-pattern:**

| mechanism | MB | share | blocks | share | whose |
|---|---:|---:|---:|---:|---|
| fresh buffers of a known size (`List(capacity:)`, `cloneValue`, `fromSlice`) | 106.7 | 29.5% | 2.78M | **81.2%** | Trig's copies; storable views would remove them (Rig, (c)) |
| Map entries, grown by doubling | 106.4 | 29.4% | 0.36M | 10.5% | Rig's growth; Trig's map per symbol table |
| List and String growth by push | 105.5 | 29.2% | 0.21M | 6.3% | Rig's doubling; Trig's AST arrays |
| Map indexes | 38.0 | 10.5% | 0.04M | 1.1% | Rig |
| `std.Io.Writer.Allocating` (text) | 4.3 | 1.2% | 0.03M | 0.9% | std |

Growth that moved a block copied 66.6 MB in all. The largest were
`get_named_members`'s `List[Int]` (2.6 MB in 38K moves) and
`table_put`'s small `Map(u32, u32)` entries (8.7 MB over several sizes).

**The largest sites** (ts-pattern, `out/ts-pattern.trace.md`, "by
mechanism, owner, caller"; whose):

- `table_put`: `Map(u32, u32)` entries, 27.6 MB in 218K blocks, and its
  index, 9.1 MB in 28K. A Map per symbol table, grown from 4 entries by
  doubling. Trig's choice; tsrs keeps flat symbol tables
  (notes/mem-flat-symbol-tables.md).
- `sort_symbols_by_key`: `KeyedSym`, 18.1 MB in 65K blocks, and
  `table_entries`: `TableEntry`, 14.9 MB in 123K. A sort's scratch
  copy, and a table copied out to be read. Trig's.
- `new_table`: the `List[Map(u32,u32)]` of all tables, 16.5 MB in 12
  growths. Every Map is 104 bytes, and doubling moves them all. Trig's
  layout.
- `relation_set`: `CacheKey -> u32` entries, 13.7 MB, and its index,
  6.1 MB. Rig's growth of one large Map.
- `type_list_items` (270K blocks), `context_inferences` (219K),
  `add_mapped_members_for_key_type` (97K), `add_declaration` (97K),
  `get_named_members` (86K), `infer_from_types` (84K), `infer_types`
  (82K), `new_inference_context` (81K): each copies a stored list into
  a new `List` (`type_list_items` copies a Table span element by
  element; `context_inferences` is `cloneValue`). Go returns the
  slice. These are B1's "storable views". Trig's code, but removing
  them needs a Rig feature: a view of a stored list that can be held
  (class (c)).
- `invoke_once`: `InferenceKey -> i32` entries, 11.2 MB in 74K blocks,
  a Map made and dropped per call. Trig's; Go pools these
  (B1's P3).

So the volume is not Rig's in the sense of waste in its mechanisms.
Growth by doubling is `Vec`'s. The 81% of blocks that are fresh copies
are Trig's code, which Rig can only help by letting it hold a view.

## 3. Page faults

Every trap, charged to its owner (`faults.sh`; `out/*.faults.md`):

| | ts-pattern | zod3 |
|---|---:|---:|
| Trig, traps | 40,065 | 9,301 |
| in Tables | **32,476 (81.1%)** | 6,442 (69.3%) |
| in Lists grown by push | 3,359 (8.4%) | 1,446 (15.5%) |
| in Map entries | 2,446 (6.1%) | 372 (4.0%) |
| in Map indexes | 696 (1.7%) | |
| tsrs, traps | 17,809 | 5,413 |
| in mimalloc's 1 GiB arena (its heap, `no_thp`) | 16,497 (92.6%) | 4,173 (77.1%) |
| in its type arena (2 MiB pages) | about 64 | about 15 |

Trig's heap segments take almost no traps (0.2%): a heap
that faults in ahead takes its segments with `MADV_POPULATE_WRITE`
(prefault-lead) and huge pages (#740). The traps are the Tables', and
every Table trap is a first
touch. About 78% of them come at a `push`, a write to the slot after
the last. Most of the rest (16%) are the `ValueSymbolLinks` table,
written by symbol id (`set_value_symbol_links_target`, `_mapper`,
`_containing_type`). Nothing is freed and faulted again.

The Tables' data is tsrs's arena data, and tsrs takes it in 2 MiB
pages: about 64 traps instead of 32K. The ways Rig could take Table
faults out:

- **huge pages past a table's first 2 MiB** (`tbl`, measured by
  #740's record: 61% fewer traps, 3.3-3.9% faster on ts-pattern, zod3
  no faster, peak memory 4-16% higher);
- **faulting in ahead of `push`** (experiment 2 below);
- **one frontier for all tables,** as tsrs's arena has: a change to
  how Tables are laid out, not to the allocator.

## 4. Object layout

From the release binary's DWARF (`out/layout-trig.txt`) against tsrs's
`size_of` asserts (with `compressed_ptrs`, on by default on unix:
`P<T>` is 32 bits):

| object | Trig | tsrs | note |
|---|---:|---:|---|
| type header | `Type` 32 B | `Type` 24 B, data inline after it | Trig's `kind` is 4 bytes (`TypeKind` as `u32`); its per-kind data is in a separate Table, one dependent load away (table-reads.md) |
| structured data | `StructuredType` 44 B, every object type | 4 B handle; a 32 B record only once members are resolved | tsrs: 4.9M of 7.6M structured types never resolve |
| AST node | `NodeRec` 24 B | `Node` 24 B | same |
| symbol | `SymbolRec` / `CheckerSymbol` | `Symbol` 32 B | |
| signature | `Signature` 64 B | `Signature` 56 B | tsrs keeps four rare fields in a tail |
| mapper | `TypeMapper` 16 B | `TypeMapper` 16 B | same |
| value symbol links | 24 B | 16 B | tsrs: three modes, a tail for the rare |
| relater | `Relater` 288 B, moved in and out of a `List` pool | `P<Relater>`, 4 B, never moved | |
| `InstantiationKey` entry | 32 B (since map-wide-keys, no hash) | a reference per slot, keyed by its arguments | |

Rig adds no padding to any of these: `Type`, `Signature`,
`StructuredType` and `ValueSymbolLinks` are dense. `InterfaceType` has 2
bytes of tail padding, and `Relater` 9. Two things are Rig's:

- An enum declared without a width is held as `u32`. `Type.kind` takes
  4 bytes where 1 would do; with a 1-byte kind the other fields would
  still pad `Type` to 32 bytes, so it saves nothing here.
- A `Set` is 112 bytes (`Ordered` 96 and `len` 8, padded to 16).

The rest is Trig's layout: separate per-kind Tables, and records
without tsrs's "rare tail" splits.

## 5. Copies and store forwarding

Loads blocked by store forwarding, by the sampled instruction's
innermost inlined frame (`rel`, 20 runs; `out/ts-pattern.rel.ipattr.md`):

| source | share of blocked loads | what |
|---|---:|---|
| `get_relater`, `Niche(Relater).unwrap`, `ListOf(Relater).pop` | **10.3%** (4.9 + 4.0 + 1.4) | `(!@free_relaters).pop() ?? Relater()`: the 288-byte `Relater` copied out of the pool's List into an optional, unwrapped, then copied again by `rig.rt` at the caller |
| `Ordered(CacheKey, u32).matchAll` / `findIndexed` | 5.5% | the tag load after the key's hash, in `relation_get` |
| `mem.swap` in `sort` | 3.2% | `insertion` swapping elements it just wrote |
| `compiler_rt` memcpy | 2.0% | |
| `is_tuple_type_node`, `get_type_from_type_node_worker`, `is_simple_type_related_to_ex`, `mapper_map` | 1-3% each | Trig's own code |

The `Relater` copies are emit's. Emit wraps every parameter and every
inlined call's result in `rig.rt` (a function, so Zig cannot fold the
value at compile time). For a 288-byte object each `rig.rt` is a copy:

- `put_relater` copies its argument three times before the `push`
  (`rig.rt`, `rig.take` into `new r`, `take` again into `push`);
- `get_relater` copies the slot into an optional, then out of it, and
  its caller copies the result once more through `rig.rt`.

The cheapest correct form (experiment 3 below) copies once each way. Its
minimum is still two copies a relation check, where tsrs passes a 4-byte
handle; that remaining part is Trig's pool of values.

## Ceiling experiments

One binary (`mkx.py`): Trig's emitted package from the `rel` build,
with three edits to the runtime and the checker, each behind a bit of
`$RIG_X`. Every arm runs the same binary, so code placement is the same
in all of them. Built on E-cores 16-19 with the release flags (`zig
build-exe -Osafe -fomit-frame-pointer`), at Rig `4d80efe17`. Main is now
`4d3fe513f` (#744; #746, which allocates a `String(...)` once and adds a
HashMap `next_slot`); neither touches these paths.

1. **Large Map indexes on huge pages** (class (a), runtime: `ordered.zig`
   `newIndex`, or `alloc.zig` for a block that is about to be written
   whole). An index of 2 MiB or more gets its own mapping, aligned to
   2 MiB, with its whole 2 MiB stretches advised `MADV_HUGEPAGE`.
   - It costs no memory: `newIndex` writes the whole index at once
     (`@memset`), so every page is committed anyway, and a tail short of
     2 MiB keeps small pages.
   - This is the part of #725's "every large block from 2 MiB" that
     costs nothing. #725 measured the rest: Lists that double and leave
     their upper half untouched.
2. **Tables fault in ahead** (class (a), runtime: `table.zig` `push`). A
   reserved Table's `push` that reaches past what it has faulted in
   calls `MADV_POPULATE_WRITE` on the next 64 KiB.
   - Memory: at most 64 KiB past each table's frontier.
3. **The `Relater` pool in place** (class (b), emit). `get_relater` pops
   the List's last element straight into the result, and its two
   callers take it without `rig.rt`. `put_relater` writes its argument
   into the List's next slot and clears its fields there, with no
   `rig.rt`, `rig.take` or optional in between. The Zig emit would have
   to write.

`xtime.sh`: core 8 (sibling 9 idle), 20 rounds, the five arms
interleaved with the order reversed every other round; perf stat for
the counts and a second run under `/usr/bin/time` for peak RSS. Every
arm printed the `rel` build's bytes on both projects. pup was loaded:
other sessions' release builds ran on slots 10,11 and 0,5, and #746's
Trig timing ran on core 1 for part of the window. Load was 3.0 to 3.6,
so wall times moved by up to 10% between rounds (ts-pattern's median is
1,099 ms against 900 ms on a quiet pup). Judge by cycles, which moved
about 1% between arms of the same code.

ts-pattern (`out/xtime.md`; medians, fastest wall):

| arm | wall fastest | wall median | user cycles | kernel cycles | instructions | dTLB walk cycles | STLB load misses | blocked loads | faults | peak RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| base | 1,018.8 ms | 1,099.0 ms | 4,485M | 349.8M | 9,492M | 101.6M | 1.202M | 17.72M | 39,822 | 274.3 MB |
| 1, index huge pages | 1.5% slower | 2.3% slower | 0.1% fewer | 1.7% fewer | same | 12.2% fewer | **23.8% fewer** | same | same | same |
| 2, tables ahead | 0.6% slower | 1.6% faster | **2.3% fewer** | **7.4% fewer** | 0.8% more | 5.3% fewer | 3.2% fewer | same | **63.9% fewer** | 0.6% more |
| 4, relater in place | 0.9% faster | 1.1% slower | **2.0% fewer** | 2.8% fewer | 0.4% fewer | 7.3% fewer | 2.2% fewer | **28.0% fewer** | same | same |
| all three | 1.5% faster | 1.3% faster | 1.8% fewer | 7.6% fewer | 0.4% more | 13.1% fewer | 23.4% fewer | 28.1% fewer | 64.0% fewer | 0.6% more |

zod3:

| arm | wall fastest | wall median | user cycles | kernel cycles | instructions | STLB load misses | blocked loads | faults | peak RSS |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| base | 191.9 ms | 211.6 ms | 790.2M | 96.7M | 1,716M | 0.101M | 3.55M | 9,238 | 87.3 MB |
| 1 | 0.4% faster | 1.0% faster | 0.1% fewer | 0.3% fewer | same | 5.3% more | same | same | same |
| 2 | same | 2.9% faster | 0.9% fewer | 1.7% fewer | 0.6% more | same | same | **42.6% fewer** | **2.0% more** |
| 4 | 0.7% faster | 2.5% faster | 0.1% fewer | same | 0.5% fewer | 3.4% more | **35.8% fewer** | same | same |
| all three | 1.6% slower | 3.0% faster | 1.4% fewer | 3.6% fewer | same | 1.3% fewer | 35.7% fewer | 42.6% fewer | 2.0% more |

What each shows:

1. **Huge pages for the big indexes:** the STLB misses go (24% of all
   ts-pattern's) and the cycles stay. Each of those lookups also misses
   L3 on its tag line (§1), and a page walk in parallel with a DRAM
   miss costs little beyond it. zod3's indexes are under 2 MiB, so
   nothing changes there. **Not worth its lines alone.** The misses
   that cost are the L3 misses: the index's size and spread, and
   Trig's maps.
2. **Tables faulting in ahead:** most of the traps go, and with them
   7.4% of kernel cycles and 2.3% of user cycles, the stalls after each
   trap. Total cycles are 2.7% fewer, the size of #740's `tbl` arm
   (3.3-3.9% faster) at a sixth of its memory. Still, 1.5-1.8 MB is
   0.6% of ts-pattern's peak and 2.0% of zod3's, the band #725 and #740
   left untaken (decision 11). Distances under 64 KiB, or one scaled to
   a table's own rate, are the next measurement. **A runtime change
   that needs the owner's memory call.**
3. **The `Relater` in place:** blocked loads fall by 4.97M on
   ts-pattern (28% of this binary's 17.7M),
   with 2.0% fewer user cycles. zod3 relates less and shows none of the
   cycles. **An emit change** (below, R3); the copies it takes out are
   Rig's.

All three together take 2.2% of ts-pattern's cycles and give a 1.3%
faster median, about the sum of 2 and 3.

## The ranked Rig-side requirements

Ranked by what they are worth on Trig as measured here, with their class
((a) runtime or allocator alone, (b) emit, (c) a proof, fact or language
feature) and the pass that owns each.

| | requirement | measured or bounded gain | class | owner |
|---|---|---|---|---|
| R1 | **Tables take their pages ahead of the writes** (experiment 2), or in 2 MiB pages behind a single frontier. 81% of ts-pattern's traps are Table first touches. | 2.7% fewer cycles (kernel 7.4%, user 2.3%), 64% fewer traps; 0.6-2.0% more peak memory at 64 KiB | (a), and the owner's memory call | `src/table.zig` (`push`, `reserve`) |
| R2 | **No copies of a large object through `rig.rt`, `rig.take` and an optional** (experiment 3). Emit passes an aggregate wider than a few words by reference, or moves it in place: a `pop() ?? T()` into its destination, a `push` of a parameter from where it lies. The class is every object over 64 bytes that moves through a call. | 2.0% fewer user cycles on ts-pattern, 28-36% fewer blocked loads | (b) | `src/emit.zig` (`rig.rt` of parameters and results), `src/runtime.zig` (`pop`, `take`) |
| R3 | **Map storage for small maps.** Rig - Merges' heap profile (`~/Data/Code/Claude/rig/rig/trig-heap-profile/`): Map and Set storage is about 90 of the 133 MiB peak live heap, and 116,704 `Ordered(u32, u32)` maps average 138 bytes. Here, `table_put`'s maps alone make 246K blocks and 37 MB. A first room under 4, an inline form for a few entries, and growth below doubling for the large entry arrays. | bounded by memory, not cycles: up to about 10% of the peak heap; not timed | (a) | `src/ordered.zig` |
| R4 | **Storable views** of stored lists, so `type_list_items`, `context_inferences` and the rest return the span, not a copy (Trig's B1 asked too). | 2.78M of 3.43M blocks and 107 MB; the allocation leaf | (c) | `docs/CORE.md` first, then sema and ownership |
| R5 | **Huge pages for a large block written whole at once** (experiment 1). A Map index from 2 MiB. | 24% fewer STLB misses, no cycles | (a) | `src/ordered.zig` / `src/alloc.zig`; only with R1, to share the pages' code |
| R6 | **A Map lookup's three arrays.** Tags, slots and entries are each a page apart. hashbrown has two, and tsrs's L3 misses in hash tables are 0.73× Trig's. map-wide-keys measured interleaving tags with slots, and lost. | not measured; the L3 misses are the Map's largest cost (§1) | (a) | `src/ordered.zig` |
| R7 | An enum without a declared width held in the fewest bytes, not `u32`. | none on Trig's objects measured | (b) | `src/emit.zig` |

Not Rig's, though it looked it: the allocator's own code and growth
policy. A growth is `Vec`'s doubling; the copies it made come to 67 MB;
and the heap's segments take 0.2% of traps since #740.

## Trig-side findings (for Trig)

1. **Tables could share tsrs's one-frontier arena** or be fewer. Each of
   Trig's 40-odd per-kind Tables faults in its own frontier: 81% of
   ts-pattern's traps, and a third of its STLB misses. tsrs keeps
   everything in one bump arena on huge pages. Putting a type's data
   after its header (table-reads.md) would also take out the dependent
   load.
2. **Copies of stored lists** make 2.78M of ts-pattern's 3.43M blocks:
   `type_list_items`, `context_inferences`, `table_entries`,
   `sort_symbols_by_key`'s scratch, `get_named_members`,
   `add_declaration`, the inference helpers. Go returns slices; once
   Rig offers storable views (requirement R4), these become views.
3. **`table_put`'s Map per symbol table:** 37 MB and 246K blocks of
   entries and indexes, grown from 4. tsrs has flat symbol tables.
4. **`invoke_once`'s Map per call** (74K blocks, 11 MB): pool it, as Go
   pools its scratch maps (B1's P3).
5. **The `Relater` pool moves 288-byte values.** Even with emit's extra
   copies gone, a get and a put copy 576 bytes. A pool of slots (a
   Table of relaters and a free list of their slots) would move 4
   bytes, as tsrs does.
6. **`new_table`'s `List[Map(u32,u32)]`** grows by doubling a List of
   104-byte Maps (16.5 MB moved). A Table of Maps would not move them.
7. **Record splits as tsrs makes them:** `StructuredType` with a 4-byte
   handle until members resolve; `Signature` and `ValueSymbolLinks` with
   rare tails. Smaller records mean fewer lines and pages touched.
