# Compiler-Unions

13779 maps; 3832570 keyed ops (lookups, puts, takes; maps and sites are ranked by these): lookup hit 2620939, miss 876347; put new 280749, existing 42670; take hit 9863, miss 2002; clear 249590; retain 0; iter 191; at 85321; grow 2969. Puts after the map's first lookup: 0.59.

## Top 10 maps by ops

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

## Top 10 sites (type and where first seen) by ops

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

## Top 10 types by ops

| type | maps | keyed ops | get hit | get miss | put new | put old | take | clear | iter | at | grow | max peak | peak histogram (bucket:maps) | puts after 1st get | avg key B |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---|---:|---:|
| `Map[U32, U32]` | 3873 | 3051642 | 2317016 | 640292 | 88302 | 5902 | 130 | 285 | 64 | 85321 | 1254 | 4678 | 0:1169 1:490 2-3:319 4-7:823 8-15:339 16-31:341 32-63:198 64-127:33 128-255:25 256-511:120 512-1023:12 1024-2047:2 2048-4095:1 4096-8191:1 | 0.83 | 4 |
| `Set[U32]` | 3656 | 314902 | 81374 | 117950 | 101103 | 4726 | 9749 | 35 | 34 | 0 | 1247 | 5932 | 0:30 1:2891 2-3:36 4-7:45 8-15:62 16-31:146 32-63:204 64-127:15 256-511:224 1024-2047:2 4096-8191:1 | 0.01 | 4 |
| `Map[checker.InferenceKey, I32]` | 4791 | 53793 | 4563 | 16410 | 16410 | 16410 | 0 | 0 | 0 | 0 | 241 | 298 | 1:4345 2-3:150 4-7:46 8-15:29 16-31:2 32-63:210 64-127:5 256-511:4 | 1.00 | 14 |
| `Map[U64, Bool]` | 1 | 49894 | 18706 | 15594 | 15594 | 0 | 0 | 0 | 0 | 0 | 10 | 15594 | 8192-16383:1 | 1.00 | 8 |
| `Map[U32, checker.SignatureLinksExtra]` | 1 | 42103 | 29455 | 6324 | 6324 | 0 | 0 | 0 | 0 | 0 | 8 | 6324 | 4096-8191:1 | 1.00 | 4 |
| `Map[Int, checker.SymbolDataExtra]` | 1 | 38423 | 38158 | 156 | 56 | 53 | 0 | 0 | 0 | 0 | 2 | 56 | 32-63:1 | 0.98 | 8 |
| `Map[checker.InstantiationKey, U32]` | 1 | 34629 | 10265 | 12151 | 12213 | 0 | 0 | 0 | 0 | 0 | 9 | 12213 | 8192-16383:1 | 1.00 | 16 |
| `Map[checker.CacheKey, U32]` | 12 | 34000 | 8458 | 12795 | 12745 | 2 | 0 | 32677 | 0 | 0 | 16 | 3063 | 1:1 2-3:3 4-7:3 8-15:2 64-127:1 1024-2047:1 2048-4095:1 | 1.00 | 16 |
| `Map[checker.LazyName, U32]` | 1 | 22642 | 7881 | 14591 | 170 | 0 | 0 | 0 | 0 | 0 | 3 | 170 | 128-255:1 | 0.61 | 8 |
| `Map[U32, checker.VarianceLinks]` | 1 | 21503 | 21451 | 39 | 13 | 0 | 0 | 0 | 0 | 0 | 0 | 13 | 8-15:1 | 1.00 | 4 |
