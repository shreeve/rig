# typeorm

94305 maps; 4997484 keyed ops (lookups, puts, takes; maps and sites are ranked by these): lookup hit 2287853, miss 1581067; put new 832391, existing 232515; take hit 49403, miss 14255; clear 410020; retain 0; iter 4311; at 571321; grow 3726. Puts after the map's first lookup: 0.75.

## Top 10 maps by ops

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

## Top 10 sites (type and where first seen) by ops

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

## Top 10 types by ops

| type | maps | keyed ops | get hit | get miss | put new | put old | take | clear | iter | at | grow | max peak | peak histogram (bucket:maps) | puts after 1st get | avg key B |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|
| `Map[U32, U32]` | 34358 | 2073889 | 1200566 | 614385 | 237569 | 19767 | 1602 | 339 | 722 | 571321 | 2262 | 17750 | 0:186 1:12419 2-3:9756 4-7:7441 8-15:2693 16-31:821 32-63:746 64-127:187 128-255:72 256-511:31 512-1023:1 1024-2047:2 2048-4095:1 16384-32767:2 | 0.63 | 4 |
| `Set[U32]` | 14585 | 510734 | 18047 | 295677 | 107380 | 45800 | 43830 | 3280 | 3363 | 0 | 849 | 7556 | 0:1310 1:11926 2-3:335 4-7:204 8-15:138 16-31:92 32-63:496 64-127:31 128-255:46 256-511:5 4096-8191:2 | 0.21 | 4 |
| `Map[checker.CacheKey, U32]` | 16 | 426956 | 122877 | 152623 | 151435 | 21 | 0 | 225126 | 0 | 0 | 37 | 21600 | 1:1 2-3:1 4-7:2 8-15:3 16-31:2 32-63:2 64-127:1 512-1023:1 1024-2047:1 4096-8191:1 16384-32767:1 | 1.00 | 16 |
| `Map[U32, checker.SignatureLinksExtra]` | 1 | 318295 | 270033 | 20353 | 20353 | 7556 | 0 | 0 | 0 | 0 | 10 | 20353 | 16384-32767:1 | 1.00 | 4 |
| `Map[checker.InstantiationKey, U32]` | 1 | 215799 | 68255 | 72438 | 75106 | 0 | 0 | 0 | 0 | 0 | 12 | 75106 | 65536-131071:1 | 1.00 | 16 |
| `Map[checker.InferenceKey, I32]` | 37897 | 203082 | 2205 | 66959 | 66959 | 66959 | 0 | 0 | 0 | 0 | 121 | 237 | 1:24498 2-3:11717 4-7:1407 8-15:213 16-31:5 32-63:8 64-127:46 128-255:3 | 1.00 | 14 |
| `Map[String, Int]` | 6 | 168898 | 139924 | 12348 | 13112 | 0 | 3514 | 0 | 1 | 0 | 31 | 3576 | 0:1 2-3:1 2048-4095:4 | 0.73 | 113 |
| `Map[Int, checker.SourceFileLinks]` | 1 | 120460 | 46344 | 50681 | 3280 | 20155 | 0 | 0 | 0 | 0 | 7 | 3280 | 2048-4095:1 | 1.00 | 8 |
| `Map[checker.NodeRef, checker.NodeLinks]` | 1 | 110635 | 38573 | 50636 | 16518 | 4908 | 0 | 0 | 0 | 0 | 10 | 16518 | 16384-32767:1 | 1.00 | 8 |
| `Map[String, Bool]` | 3 | 97747 | 74374 | 11656 | 11717 | 0 | 0 | 0 | 0 | 0 | 19 | 7161 | 32-63:1 4096-8191:2 | 0.99 | 106 |
