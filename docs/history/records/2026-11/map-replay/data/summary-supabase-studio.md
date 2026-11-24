# supabase-studio

526271 maps; 45995945 keyed ops (lookups, puts, takes; maps and sites are ranked by these): lookup hit 15304149, miss 16671129; put new 12401292, existing 1190474; take hit 224654, miss 204247; clear 3978109; retain 0; iter 20497; at 6642973; grow 64690. Puts after the map's first lookup: 0.83.

## Top 10 maps by ops

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

## Top 10 sites (type and where first seen) by ops

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

## Top 10 types by ops

| type | maps | keyed ops | get hit | get miss | put new | put old | take | clear | iter | at | grow | max peak | peak histogram (bucket:maps) | puts after 1st get | avg key B |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|
| `Map[checker.CacheKey, U32]` | 33 | 16630498 | 1767330 | 7434400 | 7428595 | 173 | 0 | 2447803 | 0 | 0 | 27043 | 96224 | 1:1 2-3:2 4-7:2 8-15:8 16-31:5 32-63:1 128-255:2 256-511:4 512-1023:3 1024-2047:2 4096-8191:1 32768-65535:1 65536-131071:1 | 1.00 | 16 |
| `Map[U32, U32]` | 133607 | 13741170 | 7331388 | 4440520 | 1847956 | 77575 | 43731 | 1796 | 5450 | 6642973 | 17520 | 150046 | 0:2112 1:27479 2-3:33653 4-7:36315 8-15:20815 16-31:7317 32-63:2797 64-127:866 128-255:418 256-511:1703 512-1023:87 1024-2047:28 2048-4095:8 4096-8191:6 8192-16383:1 32768-65535:1 131072-262143:1 | 0.62 | 4 |
| `Set[U32]` | 225514 | 3556584 | 414915 | 1487384 | 1277370 | 178449 | 198466 | 5317 | 12497 | 0 | 13694 | 7272 | 0:27982 1:173466 2-3:5123 4-7:3835 8-15:6219 16-31:5301 32-63:1188 64-127:198 128-255:817 256-511:1330 512-1023:34 1024-2047:17 4096-8191:4 | 0.26 | 4 |
| `Map[checker.InstantiationKey, U32]` | 1 | 2155503 | 1041945 | 554230 | 559326 | 2 | 0 | 0 | 0 | 0 | 15 | 559326 | 524288-1048575:1 | 1.00 | 16 |
| `Map[checker.LazyName, U32]` | 1 | 1329008 | 327477 | 991123 | 10408 | 0 | 0 | 0 | 0 | 0 | 9 | 10408 | 8192-16383:1 | 1.00 | 8 |
| `Map[checker.InferenceKey, I32]` | 117250 | 1252415 | 126326 | 375363 | 375363 | 375363 | 0 | 0 | 0 | 0 | 2907 | 1996 | 1:67666 2-3:35089 4-7:5242 8-15:5256 16-31:3386 32-63:305 64-127:239 128-255:24 256-511:35 512-1023:4 1024-2047:4 | 1.00 | 14 |
| `Map[checker.NodeRef, checker.JsxElementLinks]` | 1 | 865806 | 646146 | 89971 | 87341 | 42348 | 0 | 0 | 0 | 0 | 12 | 87341 | 65536-131071:1 | 1.00 | 8 |
| `Map[U32, checker.TypeAliasLinks]` | 1 | 789566 | 760332 | 20514 | 7150 | 1570 | 0 | 0 | 0 | 0 | 9 | 7150 | 4096-8191:1 | 1.00 | 4 |
| `Map[checker.NodeRef, checker.NodeLinks]` | 1 | 565083 | 247122 | 139421 | 48375 | 130165 | 0 | 0 | 0 | 0 | 11 | 48375 | 32768-65535:1 | 1.00 | 8 |
| `Map[String, Int]` | 138 | 555276 | 452252 | 46516 | 44058 | 0 | 12450 | 0 | 162 | 0 | 35 | 12590 | 0:133 2-3:1 4096-8191:1 8192-16383:3 | 0.72 | 144 |
