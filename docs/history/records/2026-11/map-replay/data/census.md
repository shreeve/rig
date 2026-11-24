# Census: Maps and Sets alive by length, Trig at c4 (supabase-studio, webpack)

For the 8-byte compact Map question. Measurement only; nothing pushed.

## Method

- Rig `scratch/map-trace` at `b104b1bc6` ("Count the Maps and Sets alive by length, under RIG_MAP_CENSUS"), on the
  pin 383a1b2b5. In a `RIG_MAP_TRACE=1` build, `RIG_MAP_CENSUS=PATH` at run time turns the trace into counters
  (no records), under the trace's lock (thread-safe at c4).
- A Map/Set is **registered** (a `__rig_census` byte, its bucket + 1) at its first writing op or when cloned
  (`rig.cloneValue`, which now also resets the clone's trace id); its bucket {0, 1-4, 5-16, >16} follows its length.
  A Map never written is always empty and is invisible until its **drop** (`rig.dropElement`), where every Map and
  Set is seen, named by its K/V type and, when dropped as a record's field (`rig.dropFields`), by `Record.field`
  (a List or optional of Maps in a field counts as that field). No Trig hook was needed: the build is the same pack
  as the trace (release, `os.exit` dropped so the teardown drops run, `CHECK_IDS=false`, libs prebuilt).
- Why not count at creation: Rig emits a Map as a Zig struct literal (`Map(K, V){}`, or a field default filled in by a
  record literal), so there is no call to hook; only writes, clones and drops run code.
- **Snapshots.** s0 at every line of output: the last is the end of the work, after which only the teardown runs,
  so everything dropped after it was alive then: **exact**, with labels. s1 each time peak RSS (`getrusage` maxrss,
  sampled every 1024 census events and at each output) rises; s2 each time the registered-live count peaks. For
  s1/s2 the registered Maps alive are exact; never-written ones are bounded: **low** = those dropped in the
  teardown, **high** = every never-written one dropped after the snapshot, which counts short-lived locals born
  after it (an upper bound). In both projects the last RSS rise came before the last output (s0's RSS = the
  final maxrss), and registered-alive counts at s1 and s0 are within 10%, so the long-lived population is the s0 one.
- Checks: output of the census build = plain build's at c4; anomalies 0 (no registered bucket out of step, no
  never-written Map dropped non-empty); registered still alive at exit 0.
- Savings: 56 B (64 - 8) per live Map/Set; compact.zig (scratch/map-replay `9312e3b62`, `blockBytes`) moves a 32 B
  header + 16 small tags = 48 B into the heap block of every non-empty map, and its first block holds 8 entries
  (today's 4), so a 1-4 map pays 4 more entries of slack, not counted below. Denominator: the plain build's peak RSS
  at c4 (median of 3).

Raw: burst `~/cpuq/tmp/maptrace/census-PROJ/census.tsv` (copies here in `census-PROJ/`); build `trig-census`;
scripts `census-run.sh`, `census.py` (copies in `tools/`).


## supabase-studio

Totals: 2102733 Maps and Sets dropped (1356036 never written), 746697 registered (written or cloned; 0 clones), anomalies 0, registered still alive at exit 0; census build max RSS 1907 MiB, plain build 1930 MiB.

| moment | RSS then | kind | 0 | 1-4 | 5-16 | >16 | all |
|---|---:|---|---:|---:|---:|---:|---:|
| end of work (last output; exact: everything dropped after it) | 1907 MiB | Map | 2454 | 14541 | 46152 | 11783 | 74930 |
| end of work (last output; exact: everything dropped after it) | 1907 MiB | Set | 31 | 3 | 1 | 7 | 42 |
| peak RSS (last rise) - low | 1907 MiB | Map | 2521 | 14573 | 49140 | 17758 | 83992 |
| peak RSS (last rise) - low | 1907 MiB | Set | 91 | 6 | 5 | 24 | 126 |
| peak RSS (last rise) - high | 1907 MiB | Map | 57310 | 14573 | 49140 | 17758 | 138781 |
| peak RSS (last rise) - high | 1907 MiB | Set | 123688 | 6 | 5 | 24 | 123723 |
| peak of registered Maps alive - low | 1907 MiB | Map | 2525 | 14571 | 49140 | 17766 | 84002 |
| peak of registered Maps alive - low | 1907 MiB | Set | 91 | 6 | 5 | 25 | 127 |
| peak of registered Maps alive - high | 1907 MiB | Map | 56241 | 14571 | 49140 | 17766 | 137718 |
| peak of registered Maps alive - high | 1907 MiB | Set | 121852 | 6 | 5 | 25 | 121888 |

low: registered Maps alive then (exact) + never-written ones dropped in the teardown; high: + every never-written one dropped after the snapshot, which counts short-lived ones born after it (an upper bound). Registered alive then, by bucket: s0 Map [24, 14541, 46152, 11783] Set [20, 3, 1, 7]; s1 Map [91, 14573, 49140, 17758] Set [80, 6, 5, 24]; s2 Map [95, 14571, 49140, 17766] Set [80, 6, 5, 25].

Top 10 holders of empty Maps/Sets alive at end of work (owner field, or `-` when not dropped as a field):

| owner.field | type | empty | 1-4 | 5-16 | >16 | of the empty, never written |
|---|---|---:|---:|---:|---:|---:|
| ast.Binding.node_fields | `Map[U32, U32]` | 1785 | 6270 | 3234 | 1257 | 1785 |
| ast.Binding.local_tables | `Map[U32, U32]` | 611 | 7107 | 3649 | 1179 | 611 |
| checker.Checker.active_type_mappers_caches | `Map[checker.CacheKey, U32]` | 23 | 0 | 0 | 0 | 0 |
| checker.Relater.maybe_keys_set | `Set[checker.CacheKey]` | 16 | 0 | 0 | 0 | 0 |
| checker.EmitResolver.name_parents | `Map[U64, checker.NodeRef]` | 4 | 0 | 0 | 0 | 4 |
| checker.EmitResolver.jsx_import_refs | `Map[U64, checker.NodeRef]` | 4 | 0 | 0 | 0 | 4 |
| checker.EmitResolver.aliases_marked | `Set[Int]` | 4 | 0 | 0 | 0 | 4 |
| vfs.MapFS.symlink_targets | `Map[String, String]` | 1 | 0 | 0 | 0 | 1 |
| checker.NodeBuilderContext.visited_types | `Set[U32]` | 1 | 0 | 0 | 0 | 1 |
| checker.Checker.resolving_explicit_type_of_symbol | `Set[U32]` | 1 | 0 | 0 | 0 | 0 |

Top 10 holders of empty Maps/Sets alive at peak RSS (owner field, or `-` when not dropped as a field):

| owner.field | type | empty | 1-4 | 5-16 | >16 | of the empty, never written |
|---|---|---:|---:|---:|---:|---:|
| - | `Set[U32]` | 116596 | 26605 | 1328 | 808 | 116596 |
| checker.InferenceState.visited | `Map[checker.InferenceKey, I32]` | 20963 | 11625 | 1675 | 586 | 20963 |
| - | `Map[U32, U32]` | 12930 | 10570 | 916 | 48 | 12930 |
| - | `Map[String, U32]` | 11910 | 1 | 0 | 0 | 11910 |
| checker.Relater.maybe_keys_set | `Set[checker.CacheKey]` | 2960 | 0 | 0 | 0 | 2894 |
| - | `Map[U32, Int]` | 1986 | 59 | 16 | 0 | 1986 |
| ast.Binding.node_fields | `Map[U32, U32]` | 1785 | 6270 | 3234 | 1257 | 1785 |
| - | `Set[String]` | 1310 | 1851 | 165 | 0 | 1310 |
| checker.ExportsOfModuleVisit.type_only_export_star_map | `Map[U32, checker.NodeRef]` | 8978 | 0 | 0 | 7 | 934 |
| checker.ExportsOfModuleVisit.non_type_only_names | `Set[U32]` | 934 | 6064 | 1338 | 649 | 934 |

Savings of an 8 B Map against today's 64 B (56 B inline each). Compact's block (bench/hash/replay/compact.zig, scratch/map-replay 9312e3b62) puts a 32 B header and 16 small tags (48 B) in the heap block of every non-empty map, and its first block holds 8 entries where today's holds 4.

| moment | empty x 56 | 1-4 x 56 | gross (empty + 1-4) | header+tags moved out, 48 B x every non-empty | net | net % of plain peak RSS |
|---|---:|---:|---:|---:|---:|---:|
| end of work | 0.1 MiB | 0.8 MiB | 0.9 MiB | 3.3 MiB | 0.7 MiB | 0.04% |
| peak RSS - low | 0.1 MiB | 0.8 MiB | 0.9 MiB | 3.7 MiB | 0.8 MiB | 0.04% |
| peak RSS - high | 9.7 MiB | 0.8 MiB | 10.4 MiB | 3.7 MiB | 10.3 MiB | 0.53% |

net = 56 B x every live Map/Set - 48 B x every non-empty one, before the 1-4 bucket's extra entry slack (first block of 8 entries, 4 x entry size more than today's 4) and allocator rounding.


The peak-RSS holders table uses the high bound, so its `-` (not a field) rows are mostly short-lived locals.


## webpack

Totals: 578914 Maps and Sets dropped (400005 never written), 178909 registered (written or cloned; 0 clones), anomalies 0, registered still alive at exit 0; census build max RSS 675 MiB, plain build 684 MiB.

| moment | RSS then | kind | 0 | 1-4 | 5-16 | >16 | all |
|---|---:|---|---:|---:|---:|---:|---:|
| end of work (last output; exact: everything dropped after it) | 675 MiB | Map | 588 | 1562 | 10579 | 3277 | 16006 |
| end of work (last output; exact: everything dropped after it) | 675 MiB | Set | 65 | 3 | 0 | 8 | 76 |
| peak RSS (last rise) - low | 675 MiB | Map | 600 | 1580 | 11141 | 4341 | 17662 |
| peak RSS (last rise) - low | 675 MiB | Set | 37 | 3 | 0 | 24 | 64 |
| peak RSS (last rise) - high | 675 MiB | Map | 75769 | 1580 | 11141 | 4341 | 92831 |
| peak RSS (last rise) - high | 675 MiB | Set | 33298 | 3 | 0 | 24 | 33325 |
| peak of registered Maps alive - low | 673 MiB | Map | 623 | 1589 | 11478 | 5032 | 18722 |
| peak of registered Maps alive - low | 673 MiB | Set | 51 | 5 | 0 | 32 | 88 |
| peak of registered Maps alive - high | 673 MiB | Map | 76262 | 1589 | 11478 | 5032 | 94361 |
| peak of registered Maps alive - high | 673 MiB | Set | 33830 | 5 | 0 | 32 | 33867 |

low: registered Maps alive then (exact) + never-written ones dropped in the teardown; high: + every never-written one dropped after the snapshot, which counts short-lived ones born after it (an upper bound). Registered alive then, by bucket: s0 Map [52, 1562, 10579, 3277] Set [54, 3, 0, 8]; s1 Map [64, 1580, 11141, 4341] Set [26, 3, 0, 24]; s2 Map [87, 1589, 11478, 5032] Set [40, 5, 0, 32].

Top 10 holders of empty Maps/Sets alive at end of work (owner field, or `-` when not dropped as a field):

| owner.field | type | empty | 1-4 | 5-16 | >16 | of the empty, never written |
|---|---|---:|---:|---:|---:|---:|
| ast.Binding.node_fields | `Map[U32, U32]` | 381 | 546 | 436 | 244 | 381 |
| ast.Binding.local_tables | `Map[U32, U32]` | 117 | 710 | 441 | 339 | 117 |
| checker.Checker.active_type_mappers_caches | `Map[checker.CacheKey, U32]` | 51 | 0 | 0 | 0 | 0 |
| checker.Relater.maybe_keys_set | `Set[checker.CacheKey]` | 50 | 0 | 0 | 0 | 0 |
| checker.EmitResolver.name_parents | `Map[U64, checker.NodeRef]` | 4 | 0 | 0 | 0 | 4 |
| checker.EmitResolver.jsx_import_refs | `Map[U64, checker.NodeRef]` | 4 | 0 | 0 | 0 | 4 |
| checker.EmitResolver.aliases_marked | `Set[Int]` | 4 | 0 | 0 | 0 | 4 |
| vfs.MapFS.symlink_targets | `Map[String, String]` | 1 | 0 | 0 | 0 | 1 |
| checker.NodeBuilderContext.visited_types | `Set[U32]` | 1 | 0 | 0 | 0 | 1 |
| checker.Checker.resolving_explicit_type_of_symbol | `Set[U32]` | 1 | 0 | 0 | 0 | 0 |

Top 10 holders of empty Maps/Sets alive at peak RSS (owner field, or `-` when not dropped as a field):

| owner.field | type | empty | 1-4 | 5-16 | >16 | of the empty, never written |
|---|---|---:|---:|---:|---:|---:|
| - | `Map[U32, Int]` | 24393 | 402 | 60 | 0 | 24393 |
| - | `Set[U32]` | 23422 | 24800 | 479 | 344 | 23422 |
| - | `Map[String, U32]` | 13236 | 0 | 0 | 0 | 13236 |
| - | `Map[U32, U32]` | 10699 | 12126 | 1092 | 57 | 10699 |
| checker.InferenceState.visited | `Map[checker.InferenceKey, I32]` | 2345 | 4137 | 368 | 60 | 2345 |
| - | `Map[String, ast.Node]` | 1980 | 0 | 0 | 0 | 1980 |
| - | `Set[Int]` | 1979 | 52 | 0 | 0 | 1979 |
| checker.WideningContext.widened_types | `Map[U32, U32]` | 1375 | 157 | 0 | 0 | 1375 |
| checker.WideningContext.child_contexts | `Map[U32, U32]` | 1125 | 352 | 54 | 1 | 1125 |
| checker.DiagnosticsCollection.file_diagnostics_sorted | `Set[Int]` | 1041 | 0 | 0 | 3 | 1038 |

Savings of an 8 B Map against today's 64 B (56 B inline each). Compact's block (bench/hash/replay/compact.zig, scratch/map-replay 9312e3b62) puts a 32 B header and 16 small tags (48 B) in the heap block of every non-empty map, and its first block holds 8 entries where today's holds 4.

| moment | empty x 56 | 1-4 x 56 | gross (empty + 1-4) | header+tags moved out, 48 B x every non-empty | net | net % of plain peak RSS |
|---|---:|---:|---:|---:|---:|---:|
| end of work | 0.0 MiB | 0.1 MiB | 0.1 MiB | 0.7 MiB | 0.2 MiB | 0.02% |
| peak RSS - low | 0.0 MiB | 0.1 MiB | 0.1 MiB | 0.8 MiB | 0.2 MiB | 0.02% |
| peak RSS - high | 5.8 MiB | 0.1 MiB | 5.9 MiB | 0.8 MiB | 6.0 MiB | 0.87% |

net = 56 B x every live Map/Set - 48 B x every non-empty one, before the 1-4 bucket's extra entry slack (first block of 8 entries, 4 x entry size more than today's 4) and allocator rounding.


The peak-RSS holders table uses the high bound, so its `-` (not a field) rows are mostly short-lived locals.
