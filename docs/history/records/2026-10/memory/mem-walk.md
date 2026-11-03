# Memory walk: where Trig's extra memory goes against tsrs, by stage and by kind (2026-11-02)

**Files:** `src/`, `stages.txt`, `kinds.txt` and `sites.txt` are in
[mem-walk-data/](mem-walk-data/); the raw runs (`data/`, `mac-sites/`) are
on pup in `/zfs/trig-pup/records-data/mem-walk/`.

Measured only; nothing here is for merging. Asked by Rig - Swiss for the owner: Trig's peak RSS stays
38–61% over shipped tsrs, and the small slices measured so far (0.3–6 MiB each) are not closing it.

## Setup

- **Trig** main 16b97ae (the worktree is removed; its change is `src/trig-memwalk.diff`, never pushed), `--release` by pup's
  Rig e10087dd8, CHECK_IDS false (as the benchmark builds). Measurement-only stage snapshots: a `std.memwalk`
  module given through `RIG_STD` (`src/memwalk.rig`, `src/memwalk.zig`), called after config, load (parse +
  resolve), bind, checker creation, check and report; `src/patch-zig.py` adds a registry of every Table to
  the emitted package. A snapshot records `os.memory` (heap live bytes, at block size), each Table's
  resident bytes (mincore), /proc/self/status and smaps. A second build with `RIG_HEAP_PROFILE=1` gives
  heap live bytes by owner (the type allocated) at each stage; a third with `RIG_HEAP_PROFILE=sites`
  (compiled on the Mac from the same package; heap owners don't depend on the OS) names the calls that
  made the 120 largest sites at the peak.
- **tsrs** 0.18.0 source 280b426b (pup `/zfs/trig-pup/mem-census/src`) with two more `TSRS_MEM_SPLIT`
  points, `load end` and `bind end`, in `Program::bind_source_files` (`src/tsrs-memwalk.diff`); Cargo `dev`
  profile (opt-level 3, no LTO). Struct sizes and counts are the shipped binary's (Helper's census,
  [mem-census-tsrs.md](mem-census-tsrs.md)). Shipped mode, and Go mode (`TSRS_LAZY_DTS=0 --checkerAssignment go --noLazyMembers`).
- pup, E-cores 12–19, one checker (`--singleThreaded`, Trig `--checkers 1`, `RAYON_NUM_THREADS=1`). Every
  run's stdout and exit status equal tsc's (`data/`).
- MiB = 2^20 bytes. "Live" is what the program holds: Trig's heap live (at block size) plus its Tables'
  resident pages; tsrs's arena used plus mimalloc's live blocks. "Anon" is anonymous RSS (RSS less
  file-backed pages).

## Summary

1. **Object counts are the same as tsrs Go mode.** ts-pattern: symbols 954,642 against 953,714; types
   508,937 against 506,567; instantiations 3,638,908 against 3,638,700. Shipped tsrs makes 480,145
   symbols. So against **shipped** tsrs the gap is mostly **more objects (laziness)**, and against Go mode
   it is **bigger objects (layout) plus a few kinds Trig keeps that tsrs frees**.
2. **Peak RSS, and how the gap to shipped tsrs splits** (shipped binaries' VmHWM for tsrs; Trig's plain build):

   | project | Trig | tsrs shipped | tsrs Go | gap to shipped | of it: tsrs's laziness (Go − shipped, anon) | Trig over Go (anon) | file-backed (Trig − tsrs) |
   |---|---:|---:|---:|---:|---:|---:|---:|
   | empty | 28.0 | 16.0 | 20.3 | 12.0 | 4.1 | 4.1 | 3.8 |
   | zod3 | 73.5 | 44.5 | 57.9 | 29.0 | 13.5 | 11.6 | 4.0 |
   | ts-pattern | 225.1 | 161.2 | 206.1 | 63.9 | 44.9 | 13.3 | 3.7 |

   The file-backed column is not code: Trig is static and keeps the lib .d.ts text in its rodata (4.5 MiB
   resident against tsrs's 1.7), where tsrs reads the same 2.9 MiB into its heap (counted in its anon).
   Code is 7.6 MiB resident against tsrs's 4.3 + 2.4 of shared libraries. Net, about 1 MiB.
3. **By stage, Trig over Go mode (anon):** ts-pattern +1.1 after load, +6.8 after bind, +15.7 after check;
   zod3 +3.5, +7.3, +11.7; empty +1.0, +2.8, +4.1. **Bind is half of zod3's and the empty project's
   excess**, and check is two thirds of ts-pattern's.
4. **Live data at the peak, ts-pattern:** Trig 212.7, tsrs Go 190.3, shipped 138.7. Trig's live exceeds
   its anon by about 3 MiB: the untouched room of its power-of-two single blocks (the 16 MiB instantiation
   cache, the 8 MiB list of member-table headers) is counted live but never touched.
5. **The allocator is not the problem** (as found before): heap overhead (anon less live) is under 3 MiB
   on every project.

## Deliverable 1: memory by stage (one checker)

Trig's stage points: config, load (`process_all_program_files`: parse and resolve), bind (the program's bind
loop), checker creation, check (`check_groups`), exit (after the report). tsrs's: `load end` and `bind end`
(both added, in `bind_source_files`), `parse end` (its own, at checker creation; after binding), `check end`,
`exit`. tsrs's columns come from the dev build, whose file-backed pages are larger than the shipped
binary's (15 against 8.5 MiB), so only live and anon are compared here; peaks are in the summary.
Raw: `data/plain/*/err` (MEMWALK lines), `data/tsrs/*.memsplit`; table by `src/stages.py`.


#### empty

| stage | Trig live (heap + tables) | tsrs shipped live (arena + heap) | tsrs Go live | Trig − Go | Trig anon RSS | tsrs shipped anon | tsrs Go anon | Trig − Go |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| after config | 0.2 | | | | 4.3 | | | |
| after load (parse + resolve) | 8.9 (8.9 + 0.0) | 5.1 (1.9 + 3.2) | 8.7 (5.5 + 3.2) | +0.2 | 10.7 | 6.1 | 9.7 | +1.0 |
| after bind | 15.0 (15.0 + 0.0) | 6.5 (3.1 + 3.4) | 10.9 (7.3 + 3.6) | +4.1 | 16.4 | 7.6 | 13.6 | +2.8 |
| after checker creation | 15.7 (15.2 + 0.5) | 6.5 (3.1 + 3.4) | 10.9 (7.3 + 3.6) | +4.8 | 17.1 | 7.6 | 13.6 | +3.5 |
| after check | 15.7 (15.2 + 0.5) | 7.4 (3.9 + 3.5) | 11.3 (7.6 + 3.7) | +4.4 | 18.2 | 8.9 | 14.1 | +4.1 |
| exit | 15.7 (15.2 + 0.5) | 7.4 (3.9 + 3.5) | 11.3 (7.6 + 3.7) | +4.4 | 18.2 | 8.9 | 14.0 | +4.2 |

Trig file-backed at check 9.8 MiB; Trig VmHWM 28.0.

#### zod3

| stage | Trig live (heap + tables) | tsrs shipped live (arena + heap) | tsrs Go live | Trig − Go | Trig anon RSS | tsrs shipped anon | tsrs Go anon | Trig − Go |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| after config | 0.2 | | | | 4.3 | | | |
| after load (parse + resolve) | 14.8 (14.8 + 0.0) | 7.1 (3.2 + 3.9) | 12.6 (8.8 + 3.8) | +2.2 | 17.4 | 12.1 | 13.9 | +3.5 |
| after bind | 23.6 (23.6 + 0.0) | 8.9 (4.8 + 4.1) | 15.3 (11.1 + 4.2) | +8.3 | 23.9 | 12.7 | 16.6 | +7.3 |
| after checker creation | 24.2 (23.6 + 0.6) | 8.9 (4.8 + 4.1) | 15.3 (11.1 + 4.2) | +8.9 | 24.5 | 12.7 | 16.6 | +7.9 |
| after check | 59.2 (38.5 + 20.8) | 31.9 (21.1 + 10.8) | 46.4 (32.0 + 14.4) | +12.8 | 61.6 | 36.8 | 49.9 | +11.7 |
| exit | 59.1 (38.4 + 20.8) | 31.9 (21.1 + 10.8) | 46.4 (32.0 + 14.4) | +12.7 | 61.6 | 34.6 | 49.9 | +11.7 |

Trig file-backed at check 12.0 MiB; Trig VmHWM 73.5.

#### ts-pattern

| stage | Trig live (heap + tables) | tsrs shipped live (arena + heap) | tsrs Go live | Trig − Go | Trig anon RSS | tsrs shipped anon | tsrs Go anon | Trig − Go |
|---|---:|---:|---:|---:|---:|---:|---:|---:|
| after config | 0.2 | | | | 4.3 | | | |
| after load (parse + resolve) | 15.3 (15.3 + 0.0) | 6.5 (2.6 + 3.9) | 13.0 (9.2 + 3.8) | +2.3 | 17.3 | 11.2 | 16.2 | +1.1 |
| after bind | 24.5 (24.5 + 0.0) | 8.3 (4.0 + 4.3) | 16.1 (11.8 + 4.3) | +8.4 | 25.4 | 14.4 | 18.6 | +6.8 |
| after checker creation | 25.2 (24.5 + 0.7) | 8.3 (4.0 + 4.3) | 16.1 (11.8 + 4.3) | +9.1 | 26.1 | 14.4 | 18.6 | +7.5 |
| after check | 213.8 (103.0 + 110.8) | 139.6 (96.2 + 43.4) | 191.5 (132.4 + 59.1) | +22.3 | 210.9 | 150.2 | 195.2 | +15.7 |
| exit | 214.0 (103.2 + 110.8) | 139.6 (96.2 + 43.4) | 191.4 (132.4 + 59.0) | +22.6 | 212.9 | 146.6 | 195.2 | +17.7 |

Trig file-backed at check 12.2 MiB; Trig VmHWM 225.1.

Readings:
- **Load.** Trig holds 14.8 MiB on zod3 against Go mode's 12.6, though tsrs's 12.6 includes the 3.4 MiB of
  source text it reads onto its heap and Trig's lib text sits in rodata. Trig's parse output is AST
  records 11.2 MiB (NodeRec 6.6, ListRec 1.6, node data and list words 2.2, Node lists 0.4) against
  tsrs's 9.0, and identifier text 2.7 MiB (copied identifier bytes 1.7, TextRec 1.1) against 0.14:
  tsrs's identifiers point into the source text.
- **Bind** adds 8.8 MiB on zod3 (9.2 on ts-pattern) against tsrs's 2.7 (3.1): three per-node `u32`
  lists, `node_symbol`, `node_flow`, `node_locals`, filled for every node of every file, 2.8 MiB; binder
  symbols `SymbolRec` 2.1 MiB (64 B each) against tsrs's 32 B `Symbol`; symbol tables 1.8 MiB (a Map
  header is 64 B against tsrs's 24 B `SymbolTable`); flow records 0.8.
- **Checker creation** is small on both sides (Trig 0.6 MiB, Tables' first pages).
- **Check** is where ts-pattern's gap grows: +188 MiB live in Trig against +175 in Go mode and +131 shipped.

## Deliverable 2: census by kind at the end of check (the peak)

Trig's rows: Tables by element type (mincore, `data/plain/*/check.tables`) and heap owners
(`data/prof/*/check.owners`), sorted into the tsrs census's kinds by `src/kinds.py`. Heap `u32` is split by
stage (load: AST; bind − load: the binder's lists by node; the rest: checker lists). Map indexes (`u64`)
are split by the sites run (`sites.txt`): single blocks at cache sites to "lists, caches and maps", the
rest (about 27,000 small indexes, nearly all from `resolve_*_members`) to symbol tables. Trig's lib
text is in rodata, so its "source and lib file text" row is 0 here (it is in file-backed pages).

#### empty
| kind | Trig MiB | tsrs shipped | tsrs Go | Trig − Go |
|---|---:|---:|---:|---:|
| AST nodes | 6.92 | 2.97 | 5.71 | +1.21 |
| identifiers and text | 1.66 | 0.02 | 0.02 | +1.64 |
| source and lib file text | 0.00 | 2.91 | 2.91 | -2.91 |
| symbols | 1.68 | 0.57 | 1.20 | +0.48 |
| symbol tables and members | 1.51 | 0.34 | 0.66 | +0.85 |
| types | 0.10 | 0.01 | 0.01 | +0.09 |
| signatures | 0.01 | 0.00 | 0.00 | +0.01 |
| links and side tables | 0.02 | 0.24 | 0.24 | -0.22 |
| lists, caches and maps | 0.61 | 0.08 | 0.03 | +0.58 |
| binder lists by node (Trig only) | 1.88 | 0.00 | 0.00 | +1.88 |
| mappers | 0.00 | 0.00 | 0.00 | +0.00 |
| inference | 0.00 | 0.00 | 0.00 | +0.00 |
| flow nodes | 0.40 | 0.05 | 0.13 | +0.27 |
| diagnostics | 0.01 | 0.00 | 0.00 | +0.01 |
| node builder | 0.00 | 0.00 | 0.00 | +0.00 |
| program, config, other | 0.45 | 0.22 | 0.22 | +0.23 |
| **total** | **15.25** | **7.41** | **11.13** | **+4.12** |

(cache indexes 0.00, mapped-links index 0.00 MiB moved out of the u64 total)
#### zod3
| kind | Trig MiB | tsrs shipped | tsrs Go | Trig − Go |
|---|---:|---:|---:|---:|
| AST nodes | 11.24 | 4.39 | 9.01 | +2.23 |
| identifiers and text | 3.02 | 0.14 | 0.14 | +2.88 |
| source and lib file text | 0.00 | 3.41 | 3.41 | -3.41 |
| symbols | 4.31 | 2.89 | 6.35 | -2.04 |
| symbol tables and members | 10.48 | 3.30 | 7.87 | +2.61 |
| types | 7.66 | 6.18 | 5.96 | +1.70 |
| signatures | 1.41 | 1.65 | 1.65 | -0.24 |
| links and side tables | 5.33 | 2.73 | 4.32 | +1.01 |
| lists, caches and maps | 7.81 | 4.77 | 4.83 | +2.98 |
| binder lists by node (Trig only) | 2.80 | 0.00 | 0.00 | +2.80 |
| mappers | 1.64 | 1.42 | 1.52 | +0.12 |
| inference | 0.77 | 0.08 | 0.08 | +0.69 |
| flow nodes | 0.85 | 0.27 | 0.42 | +0.43 |
| diagnostics | 0.12 | 0.11 | 0.11 | +0.01 |
| node builder | 0.00 | 0.04 | 0.04 | -0.04 |
| program, config, other | 1.01 | 0.39 | 0.38 | +0.63 |
| **total** | **58.46** | **31.77** | **46.09** | **+12.37** |

(cache indexes 0.94, mapped-links index 0.00 MiB moved out of the u64 total)
#### ts-pattern
| kind | Trig MiB | tsrs shipped | tsrs Go | Trig − Go |
|---|---:|---:|---:|---:|
| AST nodes | 11.79 | 4.02 | 9.63 | +2.16 |
| identifiers and text | 3.19 | 0.93 | 0.93 | +2.26 |
| source and lib file text | 0.00 | 3.46 | 3.46 | -3.46 |
| symbols | 16.84 | 14.97 | 29.89 | -13.05 |
| symbol tables and members | 36.51 | 11.61 | 32.49 | +4.02 |
| types | 35.61 | 35.38 | 34.05 | +1.56 |
| signatures | 6.73 | 7.79 | 7.78 | -1.05 |
| links and side tables | 19.89 | 11.98 | 20.41 | -0.52 |
| lists, caches and maps | 54.92 | 37.27 | 36.46 | +18.46 |
| binder lists by node (Trig only) | 2.90 | 0.00 | 0.00 | +2.90 |
| mappers | 17.59 | 8.22 | 12.10 | +5.49 |
| inference | 4.25 | 1.95 | 1.95 | +2.30 |
| flow nodes | 0.64 | 0.23 | 0.36 | +0.28 |
| diagnostics | 0.64 | 0.35 | 0.33 | +0.31 |
| node builder | 0.00 | 0.09 | 0.09 | -0.09 |
| program, config, other | 1.19 | 0.41 | 0.41 | +0.78 |
| **total** | **212.69** | **138.66** | **190.34** | **+22.35** |

(cache indexes 7.66, mapped-links index 0.63 MiB moved out of the u64 total)

### Counts and bytes each, the large rows (ts-pattern; tsrs Go mode)

| object | Trig count × bytes | Trig MiB | tsrs count × bytes | tsrs MiB | gap is |
|---|---|---:|---|---:|---|
| symbols | 906k `CheckerSymbol` × 12 + 130k `SymbolData` × 32 + binder `SymbolRec` × 64 | 16.8 | 954k `Symbol` × 32 | 29.9 | Trig **smaller**, −13.1 |
| member and symbol tables | ~150k Map headers × 64 (9.2: one 8 MiB checker List block, 1.2 binder) + entries 13.0 + indexes 9.2 + member lists 1.36M × 4 | 36.5 | 116k `SymbolTable` × 24 + entry buffers 12.7 + name indexes 10.2 + extras 1.7 + member lists 5.2 | 32.5 | bigger, +4.0: the 64 B header (40 B over tsrs's × ~140k = 5.5) |
| types | 509k `Type` × 32 + kind records | 35.6 | 859k type allocations, 40–72 B | 34.1 | about level |
| mappers | **1,152,768** × 16 | 17.6 | **763,725** × 16 | 12.1 | **more objects**, +5.5 |
| type lists | **3.36M** elements × 4 (`type_lists` Table) | 12.8 | 741k `[P<Type>]` slices, about 1.7–2.0M elements | 7.6 | **more objects**, +5.2 |
| instantiation and relation caches | instantiation 16.0 (one block) + index 2.5; relations 6.0 + 2.5 and 3 smaller 3.4; conditional 3.0 + 1.25; signature 1.2; union, union-of-union, property 2.1 | 38.3 | `CacheHashKey` tables 17.8, restrictive 3.5, relations 3.3, signature 0.9, union-of-union 0.7, reference instantiations 0.6 | 27.0 | **bigger**, +11 (power-of-two single blocks, 8 B hash kept beside larger keys, 80 B index per 16 slots) |
| links | `ValueSymbolLinks` 927k × 16 + extras + by-node links × 4 | 19.3 | `PSlot` tables + `IdGroup` + stores | 20.4 | level |
| signatures | 134k × 48 + extras | 6.7 | 134k × 56 | 7.8 | Trig smaller |
| inference | one List each of every `InferenceInfo` (2.25) and `InferenceContext` (1.88) made | 4.3 | arena, freed with the context | 2.0 | **kept**, +2.3 |
| AST + identifier text | records + words 11.8, text 3.2 | 15.0 | nodes 9.6, text 0.9 | 10.6 | bigger, +4.4 (identifier text copied) |
| binder lists by node | 3 × 4 B × every node | 2.9 | in the node structs that have them | — | bigger, +2.9 |

**More objects against bigger objects** (Trig − Go mode, live, ts-pattern +22.4 MiB): more or kept
objects +13.0 (mappers 5.5, type list elements 5.2, inference 2.3); bigger objects +28.2 (caches 11.3,
AST and identifier text 4.4, symbol tables 4.0, binder lists by node 2.9, other checker lists 2.6, types
1.6, program 0.8, flow and diagnostics 0.6); smaller objects −18.8 (symbols −13.1, lib text held in
rodata −3.5, links −1.2, signatures −1.0). On zod3 (+12.4) the order is different: the parser and binder rows
(AST +2.2, identifier text +2.9, binder lists +2.8, symbol tables +2.6) are 10.5 of it.

Against **shipped** tsrs, the more-objects share is tsrs's laziness: its Go mode adds 51.7 MiB live on
ts-pattern (symbols +14.9, symbol tables +20.9, links +8.4, AST +5.6, mappers +3.9) and 14.3 on zod3.
Trig makes every one of those objects.

## Deliverable 3: the top three levers, per project

MiB are live bytes against tsrs (anon RSS moves by about the same, less the untouched room of big
single blocks). "Laziness" = objects tsrs never makes; "layout" = the same objects, smaller; "kept" =
objects tsrs frees and Trig keeps.

### ts-pattern (peak 225.1 against shipped 161.2: 63.9; against Go mode 19.0)

1. **Laziness: up to 44.9 MiB** (tsrs's own Go-mode cost in anon; live +51.7: symbols 14.9, symbol tables
   20.9, links 8.4, AST 5.6, mappers 3.9). Three tsrs switches make it: lazy member tables (#64475 and
   #64526), lazy .d.ts binding, and its checker assignment; their split is the one run still to do (below).
   What Trig has measured: lazy members (#64475 alone) 5–9 MiB, declined at 1–2% slower; #64526, about
   half of tsrs's gain from lazy members, was never ported; lazy .d.ts binding has no prototype (its bound
   measured bind time only, 1.8 ms). *Cost: code in member resolution and the binder, and exactness at the
   pin (both PRs are past it).*
2. **Caches, layout: +11.3 MiB** (38.3 against 27.0). The instantiation cache is one map of 16 MiB of
   entries plus a 2.5 MiB index, grown by doubling, against tsrs's per-type tables (`CacheHashKey`, 13.7 MiB
   in 600 tables); the relation cache is 8.9 MiB against 3.3. The bytes are in power-of-two single blocks
   (up to half unused room), the 8-byte hash kept beside any key over 8 bytes, and 80 bytes of index per
   16 slots. *Cost: unknown; a change to the map's growth or key layout needs a speed A/B (relations and
   instantiation lookups are hot: gap map, relations family 3.8%).*
3. **Mappers and type lists, kept: +10.7 MiB** (mappers 1.15M against tsrs's 0.76M live, +5.5; type list
   elements 3.36M against about 1.9M, +5.2). Same bytes each; Trig's Tables only push, while tsrs's arena
   returns 23.5 MiB to free lists over this run. Not laziness: tsrs Go mode makes the same calls
   (instantiations equal). *Cost: unknown; first count how many are dead at the end (a counter run), then
   reuse or intern.*

### zod3 (peak 73.5 against shipped 44.5: 29.0; against Go mode 15.6)

1. **Laziness: up to 13.5 MiB** (anon; live +14.3: symbols 3.5, symbol tables 4.6, AST 4.6, links 1.6).
   Same switches and costs as above.
2. **Parse and bind layout: about 7.9 MiB.** Binder lists by node 2.8 (three `u32` per node of every
   file, where Go keeps them only in the nodes that can have them); identifier text 2.9 (Trig copies each
   identifier's bytes and keeps a `TextRec`; tsrs points into the source text); AST records +2.2. *Cost:
   a node's symbol, flow and locals by another lookup; identifier text read from the file text.*
3. **Symbol and member tables, layout: +2.6 MiB** (+4.0 on ts-pattern): a Rig `Map` header is 64 bytes
   (one cache line, small tags inline) against tsrs's 24-byte `SymbolTable`; about 50,000 tables on zod3,
   150,000 on ts-pattern. *Cost: a Rig std change (a smaller Map, or a compact table type for Trig's
   symbol tables), and a speed A/B on member lookups.*

Next on zod3: caches and checker lists +3.0, types +1.7 (of it 1.2 MiB of huge-page tail in the `Type`
Table: 4.0 MiB resident for 2.8 of records).

### empty (peak 28.0 against shipped 16.0: 12.0; against Go mode 4.1)

1. **Laziness: 4.1 MiB** (anon; live +3.7: AST 2.7, symbols 0.6, symbol tables 0.3): lazy .d.ts parsing
   and binding, since the empty project checks nothing.
2. **Binder lists by node: 1.9 MiB**, layout (as above).
3. **Identifier text: 1.6 MiB**, layout (as above); AST records +1.2 next.

File-backed pages are about level net (Trig +3.8 MiB, of which 2.9 is the lib text tsrs keeps on its
heap), so the binary is not a lever.

## Not done, and caveats

- **tsrs's laziness by switch** (lever 1's size per switch): three tsrs runs on ts-pattern and zod3,
  shipped with one switch off each. Waiting for pup.
- Trig was measured as a plain `--release` build; the benchmark build is PGO. PGO changes code layout,
  not data, so only the file-backed code pages could differ.
- Trig's map index attribution (`u64`) is exact for the 120 largest sites (8.3 of 17.5 MiB on ts-pattern);
  the rest, 27,000 small blocks, is charged to member tables by their sites' callers, which the sampled
  rows show are nearly all `resolve_*_members`.
- tsrs's type-list element count is inferred from its slice bytes (8-byte rounding), so ±10%.

## Files

- `src/`: `memwalk.rig` and `memwalk.zig` (the std module, pup copy at `/zfs/trig-pup/memwalk/std`),
  `patch-zig.py`, `build.sh`, `runs.sh`, `tsrs-runs.sh`, `tsrs-memwalk.diff`, `stages.py`, `census.py`,
  `kinds.py`, `sites.py`.
- `data/plain/PROJ/`: Trig plain build: `err` (MEMWALK lines, `/usr/bin/time -v`), `STAGE.smaps`,
  `STAGE.tables` (resident, element size, slots, address, bytes, type), `plain.err` (3 more peaks).
- `data/prof/PROJ/STAGE.owners`: heap-profile build, live bytes, blocks, made, owner.
- `data/tsrs/`: tsrs memsplit by stage, both modes.
- `mac-sites/r/PROJ/err`: the sites report (120 sites at the peak); `mac-sites/out/` is the emitted, patched
  package it was compiled from.
- pup: `/zfs/trig-pup/memwalk/` keeps the scripts, `std/` and `r/` (Trig's binaries are deleted);
  `/zfs/trig-pup/mem-census/target` (891 MiB) is the tsrs build with the two stage points, kept for
  `tsrs-switches.sh` (the laziness split by switch, not yet run); its source change is in
  `/zfs/trig-pup/mem-census/src` (`git diff`). Delete both when that run is done or dropped.
- `stages.txt`, `kinds.txt`, `sites.txt`: the generated tables.
