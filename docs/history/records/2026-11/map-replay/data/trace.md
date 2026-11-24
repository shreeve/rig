# Trig's Map and Set stream at c1: traces for the hashbrown replay

Measurement only: nothing landed or was pushed. Built 2026-11-24 (burst time).

## Where everything is

On burst, under `~/cpuq/tmp/maptrace/` (ZFS, lz4):

| Path | What |
|---|---|
| `PROJ/trace.bin.zst` | the full trace, zstd (`zstd -dc` gives the raw 48-byte records) |
| `PROJ/trace.bin.types` | one line per map id: `id<TAB>K<TAB>V<TAB>Map\|Set<TAB>0xSITE` |
| `PROJ/filtered/mapN.bin` | raw records of the Nth busiest map (N = 1..5), every op of that one id, in order |
| `PROJ/filtered/siteN.bin` | raw records of every map of the Nth busiest site (N = 1..5), interleaved as they ran |
| `PROJ/ids/{mapN,siteN}.ids` | the map ids in each filtered file, one per line |
| `PROJ/maps.tsv` | per map id: op counts, peak, final, puts after first lookup, first/last record index, key widths |
| `PROJ/sites.txt`, `sites.json`, `addrs.txt` | the sites symbolized (llvm-symbolizer `--inlining`, JSON) and the name used |
| `PROJ/summary.md`, `sites.tsv`, `top-maps.tsv`, `run.log` | the summaries (copied here, beside this file) |
| `trig-traced`, `trig-plain` | the two Trig builds (not stripped, non-PIE `EXEC`, so a site address is a static address) |
| `pack-traced/out/*.zig` | the traced build's generated Zig, which the sites' `file:line` point into |
| `mt`, `mt.c` | `mt sum TRACE OUT.tsv` and `mt filter TRACE IDS OUT` (C; reads `/dev/stdin` from `zstd -dc`) |
| `build.sh`, `run.sh`, `filter.sh`, `agg.py`, `sites.py` | the recipe (copies in `tools/` here) |

PROJ is `Compiler-Unions`, `typeorm`, `webpack`, `supabase-studio`. Sizes: full traces 7.7, 21, 38, 132 MB
compressed (4.2M, 6.2M, 11.8M, 57.8M records); filtered files 0.2, 0.2, 0.4, 2.5 GB raw (14 to 207 MB on disk).
No sampling or filtering was needed: every op of every Map and Set is in the full trace.

To get one map's stream from the full trace: `zstd -dc PROJ/trace.bin.zst | ./mt filter /dev/stdin IDS OUT.bin`
with the ids in IDS, one per line (ids by type or site: `awk -F'\t' '$2=="checker.CacheKey" && $3=="U32"' PROJ/trace.bin.types | cut -f1`,
or by site: match column 5 against `PROJ/sites.txt`).

## Builds

- **Rig**: scratch branch `scratch/map-trace` (local worktree `~/Data/Code/worktrees/rig/map-trace`; on burst
  `~/cpuq/worktrees/rig-maptrace`), two commits on 383a1b2b5 (Trig's pin): `d01cdb4ca` (trace walks and `at`,
  name each map's site) and `6ac8678cd` (INTERNALS.md). Built `zig build -Dcpu=x86_64_v3`. Not pushed.
- **Trig**: `~/cpuq/worktrees/trig-thp-size` at d78aa3f3, plain release (no PGO, no BOLT), packed as
  `tools/bench/heap` packs it: `main.rig`'s release `os.exit` dropped (so the runtime's `finish` flushes the trace),
  `CHECK_IDS = false`, libs prebuilt by `gen-libtrees`; `RIG=rig-maptrace TRIG_RIG_OVERRIDE=1`. `trig-traced` adds
  `RIG_MAP_TRACE=1`; `trig-plain` is the same pack without it.
- **Runs**: c1 as `/zfs/trig-pup/trial/t3/phases-sweepBC6.sh` spells it (arm M1): `env -u TRIG_PREBUILT_LIBS trig
  --singleThreaded -p CFG --noEmit` (without its `--extendedDiagnostics`, so stdout compares), in the harness's
  project directory (`cd -P`; `tsconfig.trig.json` when present), on burst's copy of the corpus
  (`~/cpuq/worktrees/trig-main/misc/corpus`). The trace went through a FIFO into zstd.

| Project | dir, config | plain | traced | stdout traced = plain |
|---|---|---:|---:|---|
| Compiler-Unions | typescript-benchmarking/cases/solutions/Compiler-Unions, tsconfig.json | 0.27 s | 0.43 s | equal (72 lines, exit 2 both) |
| typeorm | typeorm/packages/typeorm, tsconfig.json | 0.81 s | 1.08 s | equal (47 lines, exit 2 both) |
| webpack | webpack, tsconfig.json | 1.24 s | 1.79 s | equal (1035 lines, exit 2 both) |
| supabase-studio | supabase-studio/apps/studio, tsconfig.trig.json | 4.52 s | 7.04 s | equal (10 lines, exit 2 both) |

## Coverage

- Trig's maps are the built-in `Map` and `Set` (std/prelude.rig, held by the runtime's `OrderedMap`/`OrderedSet` in
  src/ordered.zig: the census's `Ordered(CacheKey,TypeList)` and `Ordered(u32,u32)` are `Map[CacheKey, U32]` and
  `Map[U32, U32]` here). Trig's `hashset.HashSet` and `collections.Set` wrap the built-in `Set`, so they are traced.
- Trig's src uses no `HashMap`/`HashSet` (src/unordered.zig), so nothing there was traced. src/fastmap.zig is the
  compiler's own (sema), not in Trig's binary.
- **Not traced**: Trig's own `collections.OrderedMap` (src/collections/ordered_map.rig, a List-based table of its
  own), used by tsoptions (config parsing) and core/bfs (the file graph), not by the checker; `Map.ensure_by` (Trig
  never calls it); and each step of a walk (only its start is recorded, as `iter`).
- New in the trace (scratch): `iter` (a walk started by `items`, `keys`, `values`, `update`; Set `items`) and `at`
  (positional `Map.at(i)`; hit = in range), and each map's site.

## Record format

48 bytes, little-endian, one per op, in program order (one thread at c1):

| Bytes | Field |
|---|---|
| 0 | op bits 0-2 in bits 0-2; thread bits 0-4 in bits 3-7 |
| 1 | hit in bit 0; thread bits 5-10 in bits 1-6; **op bit 3 in bit 7** (changed: was thread bit 11) |
| 2-3 | key width in bytes (65535 for wider) |
| 4-7 | map id (from 1, in the order the trace first saw each map) |
| 8-11 | size of V in bytes (0 for a Set and in a `drop`) |
| 12-15 | length after the op |
| 16-23 | key hash as Rig's Map hashes it; for a `grow`, the index's new slots |
| 24-47 | the key's first 24 bytes, zero-padded |

op = `(b0 & 7) | ((b1 >> 7) << 3)`: 0 get (`has`, `get`, `edit`), 1 put (`put`, `replace`, `put_new`, the `ensure`s,
Set `add`), 2 remove (`take`), 3 clear, 4 new (first sight of the map), 5 drop, 6 grow (index rebuilt, recorded just
before the op that caused it), 7 retain, **8 iter**, **9 at**. hit: a lookup or take found the key; a put found it
already there (so put hit=0 is an insert). A `reserve` appears only as its `grow`. Keys: an int's own bytes, a
string's bytes, a struct's fields in order. Every top map's keys fit in 24 bytes (avg widths 4 to 16), so the
records hold whole keys and a replay can rebuild them exactly (hash included, for checking).

`.types` gains a 5th column, the site: the return address of the `mapTraceSee` call that first saw the map, i.e.
inside the Trig function whose op first touched it (by `new(capacity)` that is the creation; for a field, the first
op on it). `sites.txt` names it: the innermost frame outside the prelude and runtime, the receiver on that
generated-Zig line (`.local_tables`, `.new names` for `names = Map(...).new(n)`, `.active_type_mappers_caches[i]`),
and `file:line` in `pack-traced/out`. One field can show two sites if different functions touch its instances first
(webpack's `active_type_mappers_caches` is named by `instantiate_type_with_alias`, the others by
`pop_active_mapper`).

## How to read the tables

- **keyed ops** (lookups + puts + takes) rank maps and sites; clear, iter, at and grow are shown apart.
- **puts after 1st get**: the share of the map's puts that came after its first lookup. 0 is build-then-probe;
  1.00 with get-miss = put-new is the cache pattern (lookup, miss, insert), interleaved throughout.
- **peak histogram**: maps of that site or type by their peak length, power-of-two buckets.
- Per-type tables are in each `PROJ/summary.md`.

## What stands out for the replay

- The busiest single maps in supabase-studio are the instantiation caches `active_type_mappers_caches[i]`
  (`Map[CacheKey, U32]`, 16-byte keys): 80% to 96% of lookups miss, every miss followed by an insert, and the map
  is cleared over and over (136k clears on map 1) and reused: peak 467, final 0, and 13,647 grows (index rebuilds),
  presumably as each refill passes the 16-entry small-table limit again. A replay must honour `clear`.
- `Map[U32, U32]` from `big_branch` (`names = Map.new(n+1)`): built small (13 to 2k entries) then probed hard
  (supabase map 95837: 13 entries, 1.58M lookups, 80% miss).
- `ast.Binding` tables (`.local_tables`, `grow_table`'s `m`): thousands of small `Map[U32, U32]`, about 45% of lookups miss (Compiler-Unions).
- `get_declared_type_of_class_or_interface .instantiations` (`Map[InstantiationKey, U32]`): one map growing to 559k
  entries in supabase-studio, 2.2M ops, 35% miss: the one large table.


## Compiler-Unions

13779 maps; 3832570 keyed ops (lookups, puts, takes; maps and sites are ranked by these): lookup hit 2620939, miss 876347; put new 280749, existing 42670; take hit 9863, miss 2002; clear 249590; retain 0; iter 191; at 85321; grow 2969. Puts after the map's first lookup: 0.59.

### Top 10 maps

| id | type | site | keyed ops | get hit | get miss | put new | put old | take | clear | iter | at | grow | peak | final | puts after 1st get | avg key B |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 1187 | `Map[U32, U32]` | checker.Checker.big_branch .new names (checker.zig:3182) | 250993 | 154029 | 96942 | 22 | 0 | 0 | 0 | 0 | 6406 | 1 | 22 | 22 | 0.09 | 4 |
| 469 | `Map[U32, U32]` | ast.Binding.locals .local_tables (ast.zig:17669) | 165725 | 87838 | 75439 | 2448 | 0 | 0 | 0 | 0 | 0 | 7 | 2448 | 2448 | 1.00 | 4 |
| 2969 | `Map[U32, U32]` | checker.Checker.remove_subtypes .key_types (checker.zig:6413) | 88149 | 87549 | 300 | 300 | 0 | 0 | 1 | 0 | 0 | 4 | 300 | 300 | 1.00 | 4 |
| 9152 | `Map[U32, U32]` | checker.Checker.remove_subtypes .key_types (checker.zig:6413) | 87817 | 87219 | 299 | 299 | 0 | 0 | 1 | 0 | 0 | 4 | 299 | 299 | 1.00 | 4 |
| 8871 | `Map[U32, U32]` | checker.Checker.remove_subtypes .key_types (checker.zig:6413) | 87816 | 87218 | 299 | 299 | 0 | 0 | 1 | 0 | 0 | 4 | 299 | 299 | 1.00 | 4 |
| 2661 | `Map[U32, U32]` | checker.Checker.remove_subtypes .key_types (checker.zig:6413) | 87519 | 86923 | 298 | 298 | 0 | 0 | 1 | 0 | 0 | 4 | 298 | 298 | 1.00 | 4 |
| 5396 | `Map[U32, U32]` | checker.Checker.remove_subtypes .key_types (checker.zig:6413) | 87519 | 86923 | 298 | 298 | 0 | 0 | 1 | 0 | 0 | 4 | 298 | 298 | 1.00 | 4 |
| 5593 | `Map[U32, U32]` | checker.Checker.remove_subtypes .key_types (checker.zig:6413) | 87519 | 86923 | 298 | 298 | 0 | 0 | 1 | 0 | 0 | 4 | 298 | 298 | 1.00 | 4 |
| 11136 | `Map[U32, U32]` | checker.Checker.remove_subtypes .key_types (checker.zig:6413) | 87131 | 86537 | 297 | 297 | 0 | 0 | 1 | 0 | 0 | 4 | 297 | 297 | 1.00 | 4 |
| 13256 | `Map[U32, U32]` | checker.Checker.remove_subtypes .key_types (checker.zig:6413) | 86930 | 86336 | 297 | 297 | 0 | 0 | 1 | 0 | 0 | 4 | 297 | 297 | 1.00 | 4 |

### Top 10 sites

| site | maps | keyed ops | get hit | get miss | put new | put old | take | clear | iter | at | grow | max peak | peak histogram (bucket:maps) | puts after 1st get | avg key B |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|
| `Map[U32, U32]` checker.Checker.big_branch .new names (checker.zig:3182) | 313 | 1247775 | 945031 | 291563 | 11127 | 54 | 0 | 0 | 64 | 68030 | 293 | 1751 | 8-15:39 16-31:216 32-63:53 64-127:2 128-255:1 512-1023:1 1024-2047:1 | 0.54 | 4 |
| `Map[U32, U32]` checker.Checker.remove_subtypes .key_types (checker.zig:6413) | 143 | 1033672 | 1022270 | 5701 | 5701 | 0 | 0 | 147 | 0 | 0 | 104 | 300 | 1:12 2-3:61 4-7:7 8-15:4 16-31:8 32-63:37 64-127:2 128-255:1 256-511:11 | 1.00 | 4 |
| `Map[U32, U32]` ast.Binding.locals .local_tables (ast.zig:17669) | 34 | 447830 | 237925 | 202542 | 7363 | 0 | 0 | 0 | 0 | 0 | 82 | 2448 | 2-3:1 8-15:5 16-31:3 32-63:4 64-127:7 128-255:8 256-511:3 512-1023:2 2048-4095:1 | 1.00 | 4 |
| `Set[U32]` checker.Checker.get_union_type_worker_items .named (checker.zig:5479) | 687 | 165471 | 79532 | 4561 | 79965 | 1413 | 0 | 0 | 0 | 0 | 1204 | 300 | 2-3:26 4-7:35 8-15:59 16-31:132 32-63:196 64-127:15 256-511:224 | 0.00 | 4 |
| `Map[U32, U32]` ast.Binding.grow_table .new m (ast.zig:17849) | 917 | 136399 | 67537 | 53312 | 15550 | 0 | 0 | 0 | 0 | 14731 | 133 | 1176 | 4-7:613 8-15:203 16-31:53 32-63:18 64-127:11 128-255:8 256-511:6 512-1023:4 1024-2047:1 | 0.60 | 4 |
| `Map[U32, U32]` checker.Checker.map_types_by_key_property .types_by_key (checker.zig:69731) | 249 | 77873 | 8624 | 34944 | 33267 | 1038 | 0 | 0 | 0 | 0 | 509 | 292 | 1:1 2-3:2 4-7:1 8-15:46 16-31:22 32-63:77 128-255:4 256-511:96 | 1.00 | 4 |
| `Set[U32]` checker.Checker.is_skip_direct_inference_node .skip_direct_inference_nodes (checker.zig:39225) | 1 | 54876 | 0 | 54876 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0:1 | - | 4 |
| `Map[checker.InferenceKey, I32]` checker.Checker.invoke_once .visited (checker.zig:39710) | 4791 | 53793 | 4563 | 16410 | 16410 | 16410 | 0 | 0 | 0 | 0 | 241 | 298 | 1:4345 2-3:150 4-7:46 8-15:29 16-31:2 32-63:210 64-127:5 256-511:4 | 1.00 | 14 |
| `Map[U64, Bool]` checker.Checker.is_reachable_flow_node_worker .flow_node_reachable (checker.zig:37589) | 1 | 49894 | 18706 | 15594 | 15594 | 0 | 0 | 0 | 0 | 0 | 10 | 15594 | 8192-16383:1 | 1.00 | 8 |
| `Map[U32, checker.SignatureLinksExtra]` checker.Checker.signature_links_effects_signature .signature_links_extras (checker.zig:82556) | 1 | 42103 | 29455 | 6324 | 6324 | 0 | 0 | 0 | 0 | 0 | 8 | 6324 | 4096-8191:1 | 1.00 | 4 |

### Top 5 maps and sites: the streams

| file (under `~/cpuq/tmp/maptrace/Compiler-Unions/filtered/`) | ids | type | site | keyed ops |
|---|---|---|---|---:|
| `map1.bin` | 1187 | `Map[U32, U32]` | checker.Checker.big_branch .new names (checker.zig:3182) | 250993 |
| `map2.bin` | 469 | `Map[U32, U32]` | ast.Binding.locals .local_tables (ast.zig:17669) | 165725 |
| `map3.bin` | 2969 | `Map[U32, U32]` | checker.Checker.remove_subtypes .key_types (checker.zig:6413) | 88149 |
| `map4.bin` | 9152 | `Map[U32, U32]` | checker.Checker.remove_subtypes .key_types (checker.zig:6413) | 87817 |
| `map5.bin` | 8871 | `Map[U32, U32]` | checker.Checker.remove_subtypes .key_types (checker.zig:6413) | 87816 |
| `site1.bin` | 313 maps (`ids/site1.ids`) | `Map[U32, U32]` | checker.Checker.big_branch .new names (checker.zig:3182) | 1247775 |
| `site2.bin` | 143 maps (`ids/site2.ids`) | `Map[U32, U32]` | checker.Checker.remove_subtypes .key_types (checker.zig:6413) | 1033672 |
| `site3.bin` | 34 maps (`ids/site3.ids`) | `Map[U32, U32]` | ast.Binding.locals .local_tables (ast.zig:17669) | 447830 |
| `site4.bin` | 687 maps (`ids/site4.ids`) | `Set[U32, -]` | checker.Checker.get_union_type_worker_items .named (checker.zig:5479) | 165471 |
| `site5.bin` | 917 maps (`ids/site5.ids`) | `Map[U32, U32]` | ast.Binding.grow_table .new m (ast.zig:17849) | 136399 |


## typeorm

94305 maps; 4997484 keyed ops (lookups, puts, takes; maps and sites are ranked by these): lookup hit 2287853, miss 1581067; put new 832391, existing 232515; take hit 49403, miss 14255; clear 410020; retain 0; iter 4311; at 571321; grow 3726. Puts after the map's first lookup: 0.75.

### Top 10 maps

| id | type | site | keyed ops | get hit | get miss | put new | put old | take | clear | iter | at | grow | peak | final | puts after 1st get | avg key B |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 14064 | `Map[U32, checker.SignatureLinksExtra]` | checker.Checker.signature_links_effects_signature .signature_links_extras (checker.zig:82556) | 318295 | 270033 | 20353 | 20353 | 7556 | 0 | 0 | 0 | 0 | 10 | 20353 | 20353 | 1.00 | 4 |
| 14029 | `Map[checker.InstantiationKey, U32]` | checker.Checker.get_declared_type_of_class_or_interface .instantiations (checker.zig:55755) | 215799 | 68255 | 72438 | 75106 | 0 | 0 | 0 | 0 | 0 | 12 | 75106 | 75106 | 1.00 | 16 |
| 14592 | `Map[U32, U32]` | checker.Checker.big_branch .new names (checker.zig:3182) | 207447 | 207018 | 387 | 42 | 0 | 0 | 0 | 0 | 1565 | 1 | 42 | 42 | 0.36 | 4 |
| 14079 | `Map[checker.CacheKey, U32]` | checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 170495 | 17725 | 76385 | 76385 | 0 | 0 | 130418 | 0 | 0 | 2 | 27 | 0 | 1.00 | 16 |
| 13989 | `Map[checker.CacheKey, U32]` | checker.Checker.get_union_type_from_sorted_list .union_types (checker.zig:5566) | 135248 | 92048 | 21600 | 21600 | 0 | 0 | 0 | 0 | 0 | 10 | 21600 | 21600 | 1.00 | 16 |
| 14043 | `Set[U32]` | checker.Checker.is_skip_direct_inference_node .skip_direct_inference_nodes (checker.zig:39225) | 128591 | 0 | 128591 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | - | 4 |
| 14051 | `Map[U32, U32]` | checker.CachedTypes.get .map (checker.zig:93115) | 120561 | 71911 | 29609 | 17373 | 1668 | 0 | 0 | 0 | 0 | 10 | 17373 | 17373 | 1.00 | 4 |
| 14033 | `Map[Int, checker.SourceFileLinks]` | checker.Checker.source_file_links_type_checked .source_file_links (checker.zig:83656) | 120460 | 46344 | 50681 | 3280 | 20155 | 0 | 0 | 0 | 0 | 7 | 3280 | 3280 | 1.00 | 8 |
| 14086 | `Map[checker.NodeRef, checker.NodeLinks]` | checker.Checker.node_links_flags .node_links (checker.zig:82485) | 110635 | 38573 | 50636 | 16518 | 4908 | 0 | 0 | 0 | 0 | 10 | 16518 | 16518 | 1.00 | 8 |
| 10 | `Map[String, Int]` | compiler.FileLoader.path_id_of .path_ids (compiler.zig:1747) | 109019 | 101563 | 3880 | 3576 | 0 | 0 | 0 | 0 | 0 | 8 | 3576 | 3576 | 1.00 | 116 |

### Top 10 sites

| site | maps | keyed ops | get hit | get miss | put new | put old | take | clear | iter | at | grow | max peak | peak histogram (bucket:maps) | puts after 1st get | avg key B |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|
| `Map[U32, U32]` checker.Checker.big_branch .new names (checker.zig:3182) | 1073 | 633413 | 502241 | 88746 | 42303 | 123 | 0 | 0 | 720 | 443439 | 958 | 416 | 4-7:5 8-15:271 16-31:181 32-63:494 64-127:98 128-255:20 256-511:4 | 0.39 | 4 |
| `Map[U32, U32]` ast.Binding.locals .local_tables (ast.zig:17669) | 3123 | 617497 | 300884 | 298061 | 18552 | 0 | 0 | 0 | 0 | 0 | 238 | 484 | 1:1267 2-3:1005 4-7:490 8-15:191 16-31:97 32-63:38 64-127:17 128-255:9 256-511:9 | 1.00 | 4 |
| `Map[U32, checker.SignatureLinksExtra]` checker.Checker.signature_links_effects_signature .signature_links_extras (checker.zig:82556) | 1 | 318295 | 270033 | 20353 | 20353 | 7556 | 0 | 0 | 0 | 0 | 10 | 20353 | 16384-32767:1 | 1.00 | 4 |
| `Map[U32, U32]` ast.Binding.grow_table .new m (ast.zig:17849) | 6471 | 272596 | 149003 | 62982 | 60611 | 0 | 0 | 0 | 0 | 117720 | 497 | 430 | 4-7:4299 8-15:1670 16-31:311 32-63:136 64-127:38 128-255:13 256-511:4 | 0.30 | 4 |
| `Map[checker.CacheKey, U32]` checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 6 | 266913 | 25727 | 120593 | 120593 | 0 | 0 | 225126 | 0 | 0 | 3 | 27 | 2-3:1 4-7:1 8-15:2 16-31:2 | 1.00 | 16 |
| `Map[checker.InstantiationKey, U32]` checker.Checker.get_declared_type_of_class_or_interface .instantiations (checker.zig:55755) | 1 | 215799 | 68255 | 72438 | 75106 | 0 | 0 | 0 | 0 | 0 | 12 | 75106 | 65536-131071:1 | 1.00 | 16 |
| `Map[checker.InferenceKey, I32]` checker.Checker.invoke_once .visited (checker.zig:39710) | 37897 | 203082 | 2205 | 66959 | 66959 | 66959 | 0 | 0 | 0 | 0 | 121 | 237 | 1:24498 2-3:11717 4-7:1407 8-15:213 16-31:5 32-63:8 64-127:46 128-255:3 | 1.00 | 14 |
| `Map[checker.CacheKey, U32]` checker.Checker.get_union_type_from_sorted_list .union_types (checker.zig:5566) | 1 | 135248 | 92048 | 21600 | 21600 | 0 | 0 | 0 | 0 | 0 | 10 | 21600 | 16384-32767:1 | 1.00 | 16 |
| `Set[U32]` checker.Checker.is_skip_direct_inference_node .skip_direct_inference_nodes (checker.zig:39225) | 1 | 128591 | 0 | 128591 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0:1 | - | 4 |
| `Map[U32, U32]` checker.CachedTypes.get .map (checker.zig:93115) | 1 | 120561 | 71911 | 29609 | 17373 | 1668 | 0 | 0 | 0 | 0 | 10 | 17373 | 16384-32767:1 | 1.00 | 4 |

### Top 5 maps and sites: the streams

| file (under `~/cpuq/tmp/maptrace/typeorm/filtered/`) | ids | type | site | keyed ops |
|---|---|---|---|---:|
| `map1.bin` | 14064 | `Map[U32, checker.SignatureLinksExtra]` | checker.Checker.signature_links_effects_signature .signature_links_extras (checker.zig:82556) | 318295 |
| `map2.bin` | 14029 | `Map[checker.InstantiationKey, U32]` | checker.Checker.get_declared_type_of_class_or_interface .instantiations (checker.zig:55755) | 215799 |
| `map3.bin` | 14592 | `Map[U32, U32]` | checker.Checker.big_branch .new names (checker.zig:3182) | 207447 |
| `map4.bin` | 14079 | `Map[checker.CacheKey, U32]` | checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 170495 |
| `map5.bin` | 13989 | `Map[checker.CacheKey, U32]` | checker.Checker.get_union_type_from_sorted_list .union_types (checker.zig:5566) | 135248 |
| `site1.bin` | 1073 maps (`ids/site1.ids`) | `Map[U32, U32]` | checker.Checker.big_branch .new names (checker.zig:3182) | 633413 |
| `site2.bin` | 3123 maps (`ids/site2.ids`) | `Map[U32, U32]` | ast.Binding.locals .local_tables (ast.zig:17669) | 617497 |
| `site3.bin` | 1 maps (`ids/site3.ids`) | `Map[U32, checker.SignatureLinksExtra]` | checker.Checker.signature_links_effects_signature .signature_links_extras (checker.zig:82556) | 318295 |
| `site4.bin` | 6471 maps (`ids/site4.ids`) | `Map[U32, U32]` | ast.Binding.grow_table .new m (ast.zig:17849) | 272596 |
| `site5.bin` | 6 maps (`ids/site5.ids`) | `Map[checker.CacheKey, U32]` | checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 266913 |


## webpack

138469 maps; 8618999 keyed ops (lookups, puts, takes; maps and sites are ranked by these): lookup hit 3994951, miss 2655199; put new 1629145, existing 253769; take hit 52396, miss 33539; clear 694165; retain 0; iter 7701; at 2199313; grow 9985. Puts after the map's first lookup: 0.71.

### Top 10 maps

| id | type | site | keyed ops | get hit | get miss | put new | put old | take | clear | iter | at | grow | peak | final | puts after 1st get | avg key B |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 14286 | `Map[checker.InstantiationKey, U32]` | checker.Checker.get_declared_type_of_class_or_interface .instantiations (checker.zig:55755) | 518717 | 152671 | 180636 | 185339 | 71 | 0 | 0 | 0 | 0 | 13 | 185339 | 185339 | 1.00 | 16 |
| 14387 | `Map[checker.CacheKey, U32]` | checker.Checker.instantiate_type_with_alias .active_type_mappers_caches[i] (checker.zig:49461) | 400521 | 45237 | 177642 | 177619 | 23 | 0 | 234037 | 0 | 0 | 348 | 68 | 0 | 1.00 | 16 |
| 25047 | `Map[checker.NodeRef, checker.ArrayLiteralLinks]` | checker.Checker.array_literal_links_indices_computed .array_literal_links (checker.zig:82712) | 270621 | 230701 | 9980 | 9980 | 19960 | 0 | 0 | 0 | 0 | 9 | 9980 | 9980 | 1.00 | 8 |
| 14406 | `Map[checker.LazyName, U32]` | checker.Checker.index_lazy_source .lazy_slot_of (checker.zig:44405) | 193725 | 84248 | 100554 | 8923 | 0 | 0 | 0 | 0 | 0 | 9 | 8923 | 8923 | 0.99 | 8 |
| 14234 | `Map[checker.CacheKey, U32]` | checker.Checker.get_union_type_from_sorted_list .union_types (checker.zig:5566) | 189775 | 117139 | 36318 | 36318 | 0 | 0 | 0 | 0 | 0 | 11 | 36318 | 36318 | 1.00 | 16 |
| 14385 | `Map[U32, U32]` | checker.CachedTypes.get .map (checker.zig:93115) | 172304 | 86222 | 58843 | 24448 | 2791 | 0 | 0 | 0 | 0 | 10 | 24448 | 24448 | 1.00 | 4 |
| 14388 | `Map[checker.CacheKey, U32]` | checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 166466 | 17144 | 74661 | 74661 | 0 | 0 | 121915 | 0 | 0 | 523 | 68 | 0 | 1.00 | 16 |
| 25032 | `Map[U64, Bool]` | checker.Checker.is_reachable_flow_node_worker .flow_node_reachable (checker.zig:37589) | 165521 | 72539 | 46491 | 46491 | 0 | 0 | 0 | 0 | 0 | 11 | 46491 | 46491 | 1.00 | 8 |
| 14356 | `Map[U32, checker.TypeAliasLinks]` | checker.Checker.type_alias_links_declared_type .type_alias_links (checker.zig:83398) | 163863 | 141311 | 14893 | 6974 | 685 | 0 | 0 | 0 | 0 | 9 | 6974 | 6974 | 1.00 | 4 |
| 25033 | `Map[U32, checker.SignatureLinksExtra]` | checker.Checker.signature_links_effects_signature .signature_links_extras (checker.zig:82556) | 159771 | 127599 | 16086 | 16086 | 0 | 0 | 0 | 0 | 0 | 10 | 16086 | 16086 | 1.00 | 4 |

### Top 10 sites

| site | maps | keyed ops | get hit | get miss | put new | put old | take | clear | iter | at | grow | max peak | peak histogram (bucket:maps) | puts after 1st get | avg key B |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|
| `Map[U32, U32]` checker.Checker.big_branch .new names (checker.zig:3182) | 3243 | 1309335 | 995428 | 152935 | 160655 | 317 | 0 | 0 | 1507 | 1799092 | 3088 | 2295 | 4-7:36 8-15:1025 16-31:987 32-63:671 64-127:300 128-255:76 256-511:139 512-1023:6 1024-2047:1 2048-4095:2 | 0.61 | 4 |
| `Map[U32, U32]` ast.Binding.locals .local_tables (ast.zig:17669) | 807 | 744020 | 399810 | 321789 | 22421 | 0 | 0 | 0 | 0 | 0 | 389 | 1311 | 1:52 2-3:182 4-7:168 8-15:173 16-31:88 32-63:73 64-127:39 128-255:18 256-511:9 512-1023:4 1024-2047:1 | 1.00 | 4 |
| `Map[U32, U32]` ast.Binding.grow_table .new m (ast.zig:17849) | 9397 | 725698 | 353717 | 235622 | 136356 | 3 | 0 | 0 | 0 | 285565 | 1569 | 2231 | 4-7:4706 8-15:3158 16-31:936 32-63:364 64-127:146 128-255:63 256-511:13 512-1023:7 1024-2047:3 2048-4095:1 | 0.51 | 4 |
| `Map[checker.InstantiationKey, U32]` checker.Checker.get_declared_type_of_class_or_interface .instantiations (checker.zig:55755) | 1 | 518717 | 152671 | 180636 | 185339 | 71 | 0 | 0 | 0 | 0 | 13 | 185339 | 131072-262143:1 | 1.00 | 16 |
| `Map[checker.CacheKey, U32]` checker.Checker.instantiate_type_with_alias .active_type_mappers_caches[i] (checker.zig:49461) | 2 | 406723 | 45691 | 180516 | 180493 | 23 | 0 | 239211 | 0 | 0 | 348 | 68 | 16-31:1 64-127:1 | 1.00 | 16 |
| `Map[checker.NodeRef, checker.ArrayLiteralLinks]` checker.Checker.array_literal_links_indices_computed .array_literal_links (checker.zig:82712) | 1 | 270621 | 230701 | 9980 | 9980 | 19960 | 0 | 0 | 0 | 0 | 9 | 9980 | 8192-16383:1 | 1.00 | 8 |
| `Map[checker.CacheKey, U32]` checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 49 | 208253 | 20033 | 94110 | 94110 | 0 | 0 | 149100 | 0 | 0 | 524 | 68 | 2-3:1 4-7:38 8-15:8 16-31:1 64-127:1 | 1.00 | 16 |
| `Map[checker.LazyName, U32]` checker.Checker.index_lazy_source .lazy_slot_of (checker.zig:44405) | 1 | 193725 | 84248 | 100554 | 8923 | 0 | 0 | 0 | 0 | 0 | 9 | 8923 | 8192-16383:1 | 0.99 | 8 |
| `Map[checker.CacheKey, U32]` checker.Checker.get_union_type_from_sorted_list .union_types (checker.zig:5566) | 1 | 189775 | 117139 | 36318 | 36318 | 0 | 0 | 0 | 0 | 0 | 11 | 36318 | 32768-65535:1 | 1.00 | 16 |
| `Map[U32, U32]` checker.CachedTypes.get .map (checker.zig:93115) | 1 | 172304 | 86222 | 58843 | 24448 | 2791 | 0 | 0 | 0 | 0 | 10 | 24448 | 16384-32767:1 | 1.00 | 4 |

### Top 5 maps and sites: the streams

| file (under `~/cpuq/tmp/maptrace/webpack/filtered/`) | ids | type | site | keyed ops |
|---|---|---|---|---:|
| `map1.bin` | 14286 | `Map[checker.InstantiationKey, U32]` | checker.Checker.get_declared_type_of_class_or_interface .instantiations (checker.zig:55755) | 518717 |
| `map2.bin` | 14387 | `Map[checker.CacheKey, U32]` | checker.Checker.instantiate_type_with_alias .active_type_mappers_caches[i] (checker.zig:49461) | 400521 |
| `map3.bin` | 25047 | `Map[checker.NodeRef, checker.ArrayLiteralLinks]` | checker.Checker.array_literal_links_indices_computed .array_literal_links (checker.zig:82712) | 270621 |
| `map4.bin` | 14406 | `Map[checker.LazyName, U32]` | checker.Checker.index_lazy_source .lazy_slot_of (checker.zig:44405) | 193725 |
| `map5.bin` | 14234 | `Map[checker.CacheKey, U32]` | checker.Checker.get_union_type_from_sorted_list .union_types (checker.zig:5566) | 189775 |
| `site1.bin` | 3243 maps (`ids/site1.ids`) | `Map[U32, U32]` | checker.Checker.big_branch .new names (checker.zig:3182) | 1309335 |
| `site2.bin` | 807 maps (`ids/site2.ids`) | `Map[U32, U32]` | ast.Binding.locals .local_tables (ast.zig:17669) | 744020 |
| `site3.bin` | 9397 maps (`ids/site3.ids`) | `Map[U32, U32]` | ast.Binding.grow_table .new m (ast.zig:17849) | 725698 |
| `site4.bin` | 1 maps (`ids/site4.ids`) | `Map[checker.InstantiationKey, U32]` | checker.Checker.get_declared_type_of_class_or_interface .instantiations (checker.zig:55755) | 518717 |
| `site5.bin` | 2 maps (`ids/site5.ids`) | `Map[checker.CacheKey, U32]` | checker.Checker.instantiate_type_with_alias .active_type_mappers_caches[i] (checker.zig:49461) | 406723 |


## supabase-studio

526271 maps; 45995945 keyed ops (lookups, puts, takes; maps and sites are ranked by these): lookup hit 15304149, miss 16671129; put new 12401292, existing 1190474; take hit 224654, miss 204247; clear 3978109; retain 0; iter 20497; at 6642973; grow 64690. Puts after the map's first lookup: 0.83.

### Top 10 maps

| id | type | site | keyed ops | get hit | get miss | put new | put old | take | clear | iter | at | grow | peak | final | puts after 1st get | avg key B |
|---:|---|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| 69120 | `Map[checker.CacheKey, U32]` | checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 6714612 | 141104 | 3286754 | 3286754 | 0 | 0 | 136060 | 0 | 0 | 13647 | 467 | 0 | 1.00 | 16 |
| 69508 | `Map[checker.CacheKey, U32]` | checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 3462324 | 37660 | 1712332 | 1712332 | 0 | 0 | 68690 | 0 | 0 | 8304 | 205 | 0 | 1.00 | 16 |
| 68835 | `Map[checker.CacheKey, U32]` | checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 2542445 | 253671 | 1144387 | 1144387 | 0 | 0 | 827204 | 0 | 0 | 2259 | 446 | 0 | 1.00 | 16 |
| 68628 | `Map[checker.InstantiationKey, U32]` | checker.Checker.get_declared_type_of_class_or_interface .instantiations (checker.zig:55755) | 2155503 | 1041945 | 554230 | 559326 | 2 | 0 | 0 | 0 | 0 | 15 | 559326 | 559326 | 1.00 | 16 |
| 68931 | `Map[checker.CacheKey, U32]` | checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 1607099 | 269933 | 668583 | 668583 | 0 | 0 | 875423 | 0 | 0 | 731 | 613 | 0 | 1.00 | 16 |
| 95837 | `Map[U32, U32]` | checker.Checker.big_branch .new names (checker.zig:3182) | 1582004 | 313123 | 1268868 | 13 | 0 | 0 | 0 | 0 | 13 | 0 | 13 | 13 | 0.00 | 4 |
| 68857 | `Map[checker.LazyName, U32]` | checker.Checker.index_lazy_source .lazy_slot_of (checker.zig:44405) | 1329008 | 327477 | 991123 | 10408 | 0 | 0 | 0 | 0 | 0 | 9 | 10408 | 10408 | 1.00 | 8 |
| 68845 | `Map[U32, U32]` | checker.CachedTypes.get .map (checker.zig:93115) | 988915 | 606544 | 199781 | 150046 | 32544 | 0 | 0 | 0 | 0 | 13 | 150046 | 150046 | 1.00 | 4 |
| 69074 | `Map[checker.NodeRef, checker.JsxElementLinks]` | checker.Checker.jsx_element_links_jsx_namespace .jsx_element_links (checker.zig:82884) | 865806 | 646146 | 89971 | 87341 | 42348 | 0 | 0 | 0 | 0 | 12 | 87341 | 87341 | 1.00 | 8 |
| 68832 | `Map[U32, checker.TypeAliasLinks]` | checker.Checker.type_alias_links_declared_type .type_alias_links (checker.zig:83398) | 789566 | 760332 | 20514 | 7150 | 1570 | 0 | 0 | 0 | 0 | 9 | 7150 | 7150 | 1.00 | 4 |

### Top 10 sites

| site | maps | keyed ops | get hit | get miss | put new | put old | take | clear | iter | at | grow | max peak | peak histogram (bucket:maps) | puts after 1st get | avg key B |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|
| `Map[checker.CacheKey, U32]` checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 21 | 14791756 | 739412 | 7026172 | 7026172 | 0 | 0 | 2113711 | 0 | 0 | 25677 | 613 | 2-3:2 8-15:7 16-31:4 32-63:1 128-255:2 256-511:4 512-1023:1 | 1.00 | 16 |
| `Map[U32, U32]` checker.Checker.big_branch .new names (checker.zig:3182) | 6700 | 6612335 | 4032260 | 1885576 | 692109 | 2390 | 0 | 0 | 5418 | 5037873 | 7502 | 5404 | 2-3:1 4-7:12 8-15:2669 16-31:1329 32-63:613 64-127:260 128-255:166 256-511:1581 512-1023:59 1024-2047:7 2048-4095:1 4096-8191:2 | 0.52 | 4 |
| `Map[checker.InstantiationKey, U32]` checker.Checker.get_declared_type_of_class_or_interface .instantiations (checker.zig:55755) | 1 | 2155503 | 1041945 | 554230 | 559326 | 2 | 0 | 0 | 0 | 0 | 15 | 559326 | 524288-1048575:1 | 1.00 | 16 |
| `Map[U32, U32]` ast.Binding.grow_table .new m (ast.zig:17849) | 41453 | 1651656 | 724504 | 396322 | 530830 | 0 | 0 | 0 | 0 | 1512398 | 6103 | 5404 | 4-7:21855 8-15:13370 16-31:4151 32-63:1480 64-127:364 128-255:147 256-511:60 512-1023:11 1024-2047:10 2048-4095:3 4096-8191:2 | 0.46 | 4 |
| `Map[checker.LazyName, U32]` checker.Checker.index_lazy_source .lazy_slot_of (checker.zig:44405) | 1 | 1329008 | 327477 | 991123 | 10408 | 0 | 0 | 0 | 0 | 0 | 9 | 10408 | 8192-16383:1 | 1.00 | 8 |
| `Map[checker.InferenceKey, I32]` checker.Checker.invoke_once .visited (checker.zig:39710) | 117250 | 1252415 | 126326 | 375363 | 375363 | 375363 | 0 | 0 | 0 | 0 | 2907 | 1996 | 1:67666 2-3:35089 4-7:5242 8-15:5256 16-31:3386 32-63:305 64-127:239 128-255:24 256-511:35 512-1023:4 1024-2047:4 | 1.00 | 14 |
| `Map[U32, U32]` ast.Binding.locals .local_tables (ast.zig:17669) | 6093 | 1204203 | 605724 | 548063 | 50416 | 0 | 0 | 0 | 0 | 0 | 712 | 2641 | 1:1539 2-3:1768 4-7:1292 8-15:888 16-31:388 32-63:152 64-127:42 128-255:11 256-511:10 512-1023:2 2048-4095:1 | 1.00 | 4 |
| `Map[U32, U32]` checker.CachedTypes.get .map (checker.zig:93115) | 1 | 988915 | 606544 | 199781 | 150046 | 32544 | 0 | 0 | 0 | 0 | 13 | 150046 | 131072-262143:1 | 1.00 | 4 |
| `Map[checker.NodeRef, checker.JsxElementLinks]` checker.Checker.jsx_element_links_jsx_namespace .jsx_element_links (checker.zig:82884) | 1 | 865806 | 646146 | 89971 | 87341 | 42348 | 0 | 0 | 0 | 0 | 12 | 87341 | 65536-131071:1 | 1.00 | 8 |
| `Set[U32]` checker.Checker.get_properties_of_union_or_intersection_type .checked (checker.zig:46249) | 9217 | 814206 | 53504 | 380351 | 380351 | 0 | 0 | 0 | 0 | 0 | 6756 | 1296 | 1:577 2-3:1697 4-7:1461 8-15:1382 16-31:2415 32-63:796 64-127:48 128-255:4 256-511:817 512-1023:18 1024-2047:2 | 1.00 | 4 |

### Top 5 maps and sites: the streams

| file (under `~/cpuq/tmp/maptrace/supabase-studio/filtered/`) | ids | type | site | keyed ops |
|---|---|---|---|---:|
| `map1.bin` | 69120 | `Map[checker.CacheKey, U32]` | checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 6714612 |
| `map2.bin` | 69508 | `Map[checker.CacheKey, U32]` | checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 3462324 |
| `map3.bin` | 68835 | `Map[checker.CacheKey, U32]` | checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 2542445 |
| `map4.bin` | 68628 | `Map[checker.InstantiationKey, U32]` | checker.Checker.get_declared_type_of_class_or_interface .instantiations (checker.zig:55755) | 2155503 |
| `map5.bin` | 68931 | `Map[checker.CacheKey, U32]` | checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 1607099 |
| `site1.bin` | 21 maps (`ids/site1.ids`) | `Map[checker.CacheKey, U32]` | checker.Checker.pop_active_mapper .active_type_mappers_caches[i] (checker.zig:49540) | 14791756 |
| `site2.bin` | 6700 maps (`ids/site2.ids`) | `Map[U32, U32]` | checker.Checker.big_branch .new names (checker.zig:3182) | 6612335 |
| `site3.bin` | 1 maps (`ids/site3.ids`) | `Map[checker.InstantiationKey, U32]` | checker.Checker.get_declared_type_of_class_or_interface .instantiations (checker.zig:55755) | 2155503 |
| `site4.bin` | 41453 maps (`ids/site4.ids`) | `Map[U32, U32]` | ast.Binding.grow_table .new m (ast.zig:17849) | 1651656 |
| `site5.bin` | 1 maps (`ids/site5.ids`) | `Map[checker.LazyName, U32]` | checker.Checker.index_lazy_source .lazy_slot_of (checker.zig:44405) | 1329008 |

