# webpack

138469 maps; 8618999 keyed ops (lookups, puts, takes; maps and sites are ranked by these): lookup hit 3994951, miss 2655199; put new 1629145, existing 253769; take hit 52396, miss 33539; clear 694165; retain 0; iter 7701; at 2199313; grow 9985. Puts after the map's first lookup: 0.71.

## Top 10 maps by ops

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

## Top 10 sites (type and where first seen) by ops

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

## Top 10 types by ops

| type | maps | keyed ops | get hit | get miss | put new | put old | take | clear | iter | at | grow | max peak | peak histogram (bucket:maps) | puts after 1st get | avg key B |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|
| `Map[U32, U32]` | 36647 | 3980072 | 2256011 | 1211361 | 496389 | 14011 | 2300 | 3944 | 1513 | 2199313 | 6120 | 24448 | 0:2021 1:6608 2-3:8403 4-7:9022 8-15:5911 16-31:2420 32-63:1270 64-127:568 128-255:185 256-511:191 512-1023:25 1024-2047:11 2048-4095:10 8192-16383:1 16384-32767:1 | 0.66 | 4 |
| `Map[checker.CacheKey, U32]` | 62 | 927600 | 228660 | 351987 | 346823 | 130 | 0 | 388311 | 0 | 0 | 925 | 36318 | 2-3:1 4-7:40 8-15:8 16-31:3 32-63:1 64-127:2 128-255:1 256-511:1 512-1023:1 2048-4095:1 4096-8191:1 16384-32767:1 32768-65535:1 | 1.00 | 16 |
| `Set[U32]` | 55678 | 652272 | 50420 | 293141 | 207963 | 58043 | 42705 | 1551 | 2076 | 0 | 1284 | 21518 | 0:805 1:41654 2-3:10609 4-7:640 8-15:828 16-31:593 32-63:416 64-127:69 128-255:48 256-511:6 512-1023:3 1024-2047:4 2048-4095:1 8192-16383:1 16384-32767:1 | 0.12 | 4 |
| `Map[checker.InstantiationKey, U32]` | 1 | 518717 | 152671 | 180636 | 185339 | 71 | 0 | 0 | 0 | 0 | 13 | 185339 | 131072-262143:1 | 1.00 | 16 |
| `Map[checker.NodeRef, checker.ArrayLiteralLinks]` | 1 | 270621 | 230701 | 9980 | 9980 | 19960 | 0 | 0 | 0 | 0 | 9 | 9980 | 8192-16383:1 | 1.00 | 8 |
| `Map[checker.LazyName, U32]` | 1 | 193725 | 84248 | 100554 | 8923 | 0 | 0 | 0 | 0 | 0 | 9 | 8923 | 8192-16383:1 | 0.99 | 8 |
| `Map[U64, Bool]` | 2 | 166336 | 73028 | 46654 | 46654 | 0 | 0 | 0 | 0 | 0 | 14 | 46491 | 128-255:1 32768-65535:1 | 1.00 | 8 |
| `Map[U32, checker.TypeAliasLinks]` | 1 | 163863 | 141311 | 14893 | 6974 | 685 | 0 | 0 | 0 | 0 | 9 | 6974 | 4096-8191:1 | 1.00 | 4 |
| `Map[U32, checker.SignatureLinksExtra]` | 1 | 159771 | 127599 | 16086 | 16086 | 0 | 0 | 0 | 0 | 0 | 10 | 16086 | 8192-16383:1 | 1.00 | 4 |
| `Map[checker.NodeRef, checker.NodeLinks]` | 1 | 137138 | 66223 | 35790 | 12595 | 22530 | 0 | 0 | 0 | 0 | 9 | 12595 | 8192-16383:1 | 1.00 | 8 |
