
### Compiler.c1.census (page 16384)

| path | calls | MiB copied | share of bytes |
|---|---:|---:|---:|
| same | 24 | 0.0 | 0.0% |
| small_small | 21965 | 6.4 | 26.9% |
| small_large | 72 | 1.9 | 7.8% |
| shrink_small | 3 | 0.0 | 0.0% |
| span_grow_warm | 19 | 0.0 | 0.0% |
| span_copy_warm | 51 | 7.4 | 31.0% |
| span_grow_fresh | 3 | 0.0 | 0.0% |
| span_copy_new | 22 | 8.1 | 34.3% |
| all | 22159 | 23.7 | |

Bytes copied by block size (MiB; bucket = old size < 2^k):

| size < | small_small | small_large | shrink_small | span_copy_warm | span_copy_new |
|---|---:|---:|---:|---:|---:|
| 8 B | 1068 / 0.0 |  |  |  |  |
| 16 B | 233 / 0.0 |  |  |  |  |
| 32 B | 5703 / 0.1 |  |  |  |  |
| 64 B | 6085 / 0.2 | 1 / 0.0 |  |  |  |
| 128 B | 3105 / 0.2 | 1 / 0.0 | 3 / 0.0 |  |  |
| 256 B | 1951 / 0.3 |  |  |  |  |
| 512 B | 1376 / 0.4 |  |  |  |  |
| 1 KiB | 924 / 0.5 |  |  |  |  |
| 2 KiB | 764 / 0.8 |  |  |  |  |
| 4 KiB | 331 / 0.7 |  |  |  |  |
| 8 KiB | 222 / 1.0 |  |  |  |  |
| 16 KiB | 143 / 1.3 |  |  |  |  |
| 32 KiB | 60 / 0.9 | 34 / 0.7 |  |  |  |
| 64 KiB |  | 36 / 1.1 |  | 8 / 0.4 | 2 / 0.1 |
| 128 KiB |  |  |  | 23 / 1.6 | 3 / 0.2 |
| 256 KiB |  |  |  | 11 / 1.5 | 7 / 1.0 |
| 512 KiB |  |  |  | 6 / 1.7 | 4 / 1.2 |
| 1 MiB |  |  |  | 2 / 1.1 | 3 / 1.6 |
| 2 MiB |  |  |  | 1 / 1.0 | 2 / 2.0 |
| 4 MiB |  |  |  |  | 1 / 2.0 |
    src cold n=1 copied=131072
    src carve n=21 copied=8405474
    ge copy_warm pages>=4 n=43 copied=7326121 aligned_n=16 aligned_copied=2679843 follow_n=0 follow_copied=0
    ge copy_warm pages>=16 n=9 copied=4008008 aligned_n=5 aligned_copied=1710123 follow_n=0 follow_copied=0
    ge copy_warm pages>=64 n=1 copied=1048576 aligned_n=0 aligned_copied=0 follow_n=0 follow_copied=0
    ge copy_new pages>=4 n=20 copied=8435548 aligned_n=7 aligned_copied=1822278 follow_n=0 follow_copied=0
    ge copy_new pages>=16 n=10 copied=7143424 aligned_n=3 aligned_copied=1376256 follow_n=0 follow_copied=0
    ge copy_new pages>=64 n=3 copied=4194304 aligned_n=0 aligned_copied=0 follow_n=0 follow_copied=0

Top callers by bytes copied (inlined frames, innermost first, runtime frames trimmed):

| MiB | calls | caller | paths (calls/bytes) |
|---:|---:|---|---|
| 3.1 | 8006 | ListOf(ast.Node,0).growBy | small_small=7989/651860 small_large=6/196608 span_copy_warm=5/458752 span_copy_new=4/1966080 |
| 2.0 | 1 | ListOf(ast.NodeRec,0).growTo < ListOf(ast.NodeRec,0).push < ast.Ast.new_node | span_copy_new=1/2097152 |
| 1.2 | 254 | ListOf(ast.SymbolRec,0).growTo < ListOf(ast.SymbolRec,0).push < binder.Binder.new_symbol | small_small=243/704384 small_large=6/196608 span_copy_warm=4/327680 |
| 1.1 | 27 | ListOf(ast.FlowRec,0).growTo < ListOf(ast.FlowRec,0).push < binder.Binder.new_flow_node | small_small=19/62160 small_large=4/81920 span_copy_warm=2/983040 |
| 1.0 | 1 | ListOf(ast.NodeRec,0).growTo < ListOf(ast.NodeRec,0).push < ast.Ast.new_node | span_copy_new=1/1048576 |
| 1.0 | 1 | ListOf(ast.NodeLoc,0).growTo < ListOf(ast.NodeLoc,0).push < ast.Ast.new_node | span_copy_warm=1/1048576 |
| 1.0 | 26 | String.growList < String.appendBytes < String.addValue | small_small=18/46733 small_large=1/23377 span_copy_warm=5/974677 |
| 0.9 | 11 | ListOf(checker.InferenceContext,0).growTo < ListOf(checker.InferenceContext,0).push < checker.Checker.new_inference_context_worker | small_small=6/30240 small_large=1/30720 span_copy_warm=3/430080 span_copy_new=1/491520 |
| 0.7 | 723 | ListOf(i64,0).growBy | small_small=716/402112 small_large=5/163840 span_copy_warm=1/65536 span_copy_new=1/131072 |
| 0.6 | 2 | ListOf(checker.InferenceInfo,0).growTo < ListOf(checker.InferenceInfo,0).push < checker.Checker.alloc_inference_info | span_copy_warm=1/36864 span_copy_new=1/589824 |
| 0.6 | 19 | rig.ordered.Ordered(i64,i64).reserveOne | small_small=14/66048 small_large=2/65536 span_copy_warm=2/327680 span_copy_new=1/131072 |
| 0.5 | 6 | ListOf(checker.InferenceInfo,0).growTo < ListOf(checker.InferenceInfo,0).push < checker.Checker.alloc_inference_info | small_small=2/13824 small_large=1/18432 span_copy_warm=2/221184 span_copy_new=1/294912 |
| 0.5 | 2 | ListOf(ast.NodeRec,0).growTo < ListOf(ast.NodeRec,0).reserveTotal < ListOf(ast.NodeRec,0).reserve | small_large=1/64 span_copy_new=1/524288 |
| 0.5 | 1 | ListOf(ast.NodeLoc,0).growTo < ListOf(ast.NodeLoc,0).push < ast.Ast.new_node | span_copy_warm=1/524288 |
| 0.5 | 32 | rig.ordered.Ordered(checker.CacheKey,checker.TypeList).reserveOne | small_small=27/103296 small_large=2/49152 span_copy_warm=2/147456 span_copy_new=1/196608 |
| 0.4 | 570 | rig.ordered.Ordered(u32,u32).reserveOne | small_small=569/383648 small_large=1/32768 |
| 0.4 | 199 | ListOf(ast.FlowListRec,0).growTo < ListOf(ast.FlowListRec,0).push < binder.Binder.new_flow_list | small_small=197/271776 small_large=1/32768 span_copy_warm=1/65536 |
| 0.3 | 63 | ListOf(ast.FlowRec,0).growTo < ListOf(ast.FlowRec,0).push < binder.Binder.new_flow_node | small_small=52/112960 small_large=6/122880 span_copy_warm=1/40960 |
| 0.3 | 18 | ListOf(u64,0).growBy | small_small=15/33728 small_large=1/32768 span_copy_warm=2/196608 |
| 0.3 | 9 | rig.ordered.Ordered(checker.FlowLoopKey,u32).reserveOne | small_small=6/33280 small_large=1/32768 span_copy_warm=1/131072 span_copy_new=1/65536 |
| 0.3 | 2 | ListOf(ast.ListRec,0).growTo < ListOf(ast.ListRec,0).push < ast.Ast.add_list | small_small=1/64 span_copy_warm=1/262144 |
| 0.3 | 2 | ListOf(ast.NodeLoc,0).growTo < ListOf(ast.NodeLoc,0).reserveTotal < ListOf(ast.NodeLoc,0).reserve | small_large=1/32 span_copy_warm=1/262144 |
| 0.2 | 1 | ListOf(ast.NodeRec,0).growTo < ListOf(ast.NodeRec,0).push < ast.Ast.new_node | span_copy_new=1/262144 |
| 0.2 | 6 | String.growList < String.appendBytes < String.addValue | small_small=3/12832 span_copy_warm=1/96201 span_copy_new=1/144301 |
| 0.2 | 215 | rig.ordered.Ordered(checker.InferenceKey,i32).reserveOne | small_small=215/233984 |

(422 callers in all, 23.7 MiB)

### Compiler.c4.census (page 16384)

| path | calls | MiB copied | share of bytes |
|---|---:|---:|---:|
| same | 29 | 0.0 | 0.0% |
| small_small | 31865 | 9.7 | 33.5% |
| small_large | 107 | 2.7 | 9.3% |
| shrink_small | 3 | 0.0 | 0.0% |
| span_grow_warm | 19 | 0.0 | 0.0% |
| span_copy_warm | 48 | 6.1 | 20.9% |
| span_grow_fresh | 5 | 0.0 | 0.0% |
| span_copy_new | 53 | 10.5 | 36.2% |
| all | 32129 | 28.9 | |

Bytes copied by block size (MiB; bucket = old size < 2^k):

| size < | small_small | small_large | shrink_small | span_copy_warm | span_copy_new |
|---|---:|---:|---:|---:|---:|
| 8 B | 2055 / 0.0 |  |  |  |  |
| 16 B | 501 / 0.0 |  |  |  |  |
| 32 B | 6904 / 0.1 |  |  |  |  |
| 64 B | 8921 / 0.3 |  |  |  |  |
| 128 B | 4997 / 0.3 | 2 / 0.0 | 3 / 0.0 |  |  |
| 256 B | 3011 / 0.4 |  |  |  |  |
| 512 B | 1924 / 0.5 |  |  |  |  |
| 1 KiB | 1314 / 0.7 |  |  |  |  |
| 2 KiB | 1080 / 1.2 |  |  |  |  |
| 4 KiB | 502 / 1.1 |  |  |  |  |
| 8 KiB | 336 / 1.5 | 3 / 0.0 |  |  |  |
| 16 KiB | 228 / 2.1 | 2 / 0.0 |  |  |  |
| 32 KiB | 92 / 1.4 | 51 / 1.1 |  |  |  |
| 64 KiB |  | 49 / 1.5 |  | 11 / 0.5 | 13 / 0.6 |
| 128 KiB |  |  |  | 21 / 1.5 | 15 / 1.2 |
| 256 KiB |  |  |  | 12 / 1.7 | 13 / 1.9 |
| 512 KiB |  |  |  | 1 / 0.2 | 7 / 1.9 |
| 1 MiB |  |  |  | 2 / 1.1 | 2 / 1.0 |
| 2 MiB |  |  |  | 1 / 1.0 | 2 / 2.0 |
| 4 MiB |  |  |  |  | 1 / 2.0 |
    src steal n=25 copied=2179931
    src carve n=28 copied=8816241
    ge copy_warm pages>=4 n=37 copied=5871582 aligned_n=15 aligned_copied=1935768 follow_n=0 follow_copied=0
    ge copy_warm pages>=16 n=4 copied=2490368 aligned_n=2 aligned_copied=786432 follow_n=0 follow_copied=0
    ge copy_warm pages>=64 n=1 copied=1048576 aligned_n=0 aligned_copied=0 follow_n=0 follow_copied=0
    ge copy_new pages>=4 n=40 copied=10410656 aligned_n=12 aligned_copied=2031616 follow_n=0 follow_copied=0
    ge copy_new pages>=16 n=12 copied=7215147 aligned_n=4 aligned_copied=1310720 follow_n=0 follow_copied=0
    ge copy_new pages>=64 n=3 copied=4194304 aligned_n=0 aligned_copied=0 follow_n=0 follow_copied=0

Top callers by bytes copied (inlined frames, innermost first, runtime frames trimmed):

| MiB | calls | caller | paths (calls/bytes) |
|---:|---:|---|---|
| 4.4 | 11140 | ListOf(ast.Node,0).growBy | small_small=11108/1189036 small_large=14/430080 span_copy_warm=5/458752 span_copy_new=10/2555904 |
| 2.2 | 7 | ListOf(ast.NodeRec,0).growTo < ListOf(ast.NodeRec,0).push < ast.Ast.new_node | small_small=3/832 span_copy_new=3/2293760 |
| 1.5 | 38 | ListOf(checker.InferenceContext,0).growTo < ListOf(checker.InferenceContext,0).push < checker.Checker.new_inference_context_worker | small_small=24/120960 small_large=4/122880 span_copy_warm=3/430080 span_copy_new=7/921600 |
| 1.2 | 254 | ListOf(ast.SymbolRec,0).growTo < ListOf(ast.SymbolRec,0).push < binder.Binder.new_symbol | small_small=243/704384 small_large=6/196608 span_copy_warm=3/262144 span_copy_new=1/65536 |
| 1.1 | 7 | ListOf(ast.NodeLoc,0).growTo < ListOf(ast.NodeLoc,0).push < ast.Ast.new_node | small_small=3/416 small_large=2/65536 span_copy_warm=2/1114112 |
| 1.0 | 1 | ListOf(ast.NodeRec,0).growTo < ListOf(ast.NodeRec,0).push < ast.Ast.new_node | span_copy_new=1/1048576 |
| 0.8 | 26 | String.growList < String.appendBytes < String.addValue | small_small=18/46733 small_large=1/23377 span_copy_warm=3/374750 span_copy_new=1/399403 |
| 0.8 | 27 | ListOf(ast.FlowRec,0).growTo < ListOf(ast.FlowRec,0).push < binder.Binder.new_flow_node | small_small=19/62160 small_large=4/81920 span_copy_warm=1/655360 span_copy_new=1/40960 |
| 0.8 | 97 | rig.ordered.Ordered(checker.CacheKey,checker.TypeList).reserveOne | small_small=85/266496 small_large=4/98304 span_copy_warm=3/196608 span_copy_new=3/245760 |
| 0.7 | 1034 | ListOf(i64,0).growBy | small_small=1027/418208 small_large=5/163840 span_copy_new=2/196608 |
| 0.6 | 963 | rig.ordered.Ordered(u32,u32).reserveOne | small_small=963/662152 |
| 0.6 | 5 | ListOf(ast.NodeRec,0).growTo < ListOf(ast.NodeRec,0).reserveTotal < ListOf(ast.NodeRec,0).reserve | small_large=3/8320 span_copy_new=2/589824 |
| 0.5 | 1 | ListOf(ast.NodeLoc,0).growTo < ListOf(ast.NodeLoc,0).push < ast.Ast.new_node | span_copy_warm=1/524288 |
| 0.4 | 19 | ListOf(checker.InferenceInfo,0).growTo < ListOf(checker.InferenceInfo,0).push < checker.Checker.alloc_inference_info | small_small=14/37728 small_large=1/18432 span_copy_new=4/368640 |
| 0.4 | 50 | String.growList < String.appendBytes < String.addValue | small_small=42/160939 small_large=4/95070 span_copy_new=4/159532 |
| 0.4 | 60 | rig.ordered.Ordered(i64,i64).reserveOne | small_small=55/247808 small_large=4/131072 |
| 0.4 | 199 | ListOf(ast.FlowListRec,0).growTo < ListOf(ast.FlowListRec,0).push < binder.Binder.new_flow_list | small_small=197/271776 small_large=1/32768 span_copy_warm=1/65536 |
| 0.4 | 14 | ListOf(ast.ListRec,0).growTo < ListOf(ast.ListRec,0).push < ast.Ast.add_list | small_small=11/42304 small_large=2/65536 span_copy_new=1/262144 |
| 0.4 | 75 | String.growList < String.appendBytes < String.addValue | small_small=68/187936 small_large=2/48601 span_copy_warm=1/52597 span_copy_new=1/78895 |
| 0.3 | 63 | ListOf(ast.FlowRec,0).growTo < ListOf(ast.FlowRec,0).push < binder.Binder.new_flow_node | small_small=52/112960 small_large=6/122880 span_copy_warm=1/40960 span_copy_new=1/40960 |
| 0.3 | 5 | ListOf(ast.NodeLoc,0).growTo < ListOf(ast.NodeLoc,0).reserveTotal < ListOf(ast.NodeLoc,0).reserve | small_small=2/64 small_large=2/36864 span_copy_warm=1/262144 |
| 0.3 | 3 | ListOf(ast.NodeRec,0).growTo < ListOf(ast.NodeRec,0).push < ast.Ast.new_node | small_small=1/512 small_large=1/32768 span_copy_new=1/262144 |
| 0.3 | 258 | rig.ordered.Ordered(checker.InferenceKey,i32).reserveOne | small_small=258/278016 |
| 0.3 | 33 | ListOf(u64,0).growBy | small_small=30/36704 small_large=1/32768 span_copy_warm=1/65536 span_copy_new=1/131072 |
| 0.3 | 2 | ListOf(ast.NodeRec,0).growTo < ListOf(ast.NodeRec,0).push < ast.Ast.new_node | small_small=1/1024 span_copy_new=1/262144 |

(478 callers in all, 28.9 MiB)

### nuxt.c1.census (page 16384)

| path | calls | MiB copied | share of bytes |
|---|---:|---:|---:|
| same | 793 | 0.0 | 0.0% |
| small_small | 294264 | 49.0 | 46.2% |
| small_large | 240 | 4.0 | 3.7% |
| shrink_small | 1343 | 0.2 | 0.2% |
| span_grow_warm | 27 | 0.0 | 0.0% |
| span_copy_warm | 123 | 14.0 | 13.2% |
| span_grow_fresh | 12 | 0.0 | 0.0% |
| span_copy_new | 81 | 38.9 | 36.7% |
| all | 296883 | 106.1 | |

Bytes copied by block size (MiB; bucket = old size < 2^k):

| size < | small_small | small_large | shrink_small | span_copy_warm | span_copy_new |
|---|---:|---:|---:|---:|---:|
| 2 B | 8 / 0.0 |  |  |  |  |
| 4 B | 1 / 0.0 |  |  |  |  |
| 8 B | 5916 / 0.0 |  |  |  |  |
| 16 B | 5037 / 0.0 |  |  |  |  |
| 32 B | 76726 / 1.2 |  |  |  |  |
| 64 B | 66759 / 2.2 | 8 / 0.0 | 22 / 0.0 |  |  |
| 128 B | 57245 / 4.1 | 11 / 0.0 | 493 / 0.1 |  |  |
| 256 B | 43197 / 5.9 | 60 / 0.0 | 828 / 0.1 |  |  |
| 512 B | 18368 / 5.0 |  |  |  |  |
| 1 KiB | 10130 / 5.3 |  |  |  |  |
| 2 KiB | 6185 / 6.7 |  |  |  |  |
| 4 KiB | 2880 / 6.2 |  |  |  |  |
| 8 KiB | 1108 / 4.9 | 1 / 0.0 |  |  |  |
| 16 KiB | 529 / 4.6 |  |  |  |  |
| 32 KiB | 175 / 2.7 | 112 / 2.4 |  |  |  |
| 64 KiB |  | 48 / 1.5 |  | 44 / 1.9 | 12 / 0.5 |
| 128 KiB |  |  |  | 38 / 2.8 | 15 / 1.3 |
| 256 KiB |  |  |  | 24 / 3.5 | 14 / 2.2 |
| 512 KiB |  |  |  | 14 / 4.0 | 13 / 4.4 |
| 1 MiB |  |  |  | 3 / 1.8 | 14 / 9.1 |
| 2 MiB |  |  |  |  | 10 / 13.9 |
| 4 MiB |  |  |  |  | 3 / 7.5 |
    src carve n=81 copied=40830291
    follow copy_warm any n=1 copied=266269
    follow copy_warm end n=1 copied=266269
    ge copy_warm pages>=4 n=79 copied=12704756 aligned_n=18 aligned_copied=2822684 follow_n=1 follow_copied=266269
    ge copy_warm pages>=16 n=17 copied=6114440 aligned_n=5 aligned_copied=1441792 follow_n=1 follow_copied=266269
    ge copy_new pages>=4 n=69 copied=40288595 aligned_n=11 aligned_copied=4572480 follow_n=0 follow_copied=0
    ge copy_new pages>=16 n=40 copied=36579667 aligned_n=7 aligned_copied=3990848 follow_n=0 follow_copied=0
    ge copy_new pages>=64 n=13 copied=22440936 aligned_n=0 aligned_copied=0 follow_n=0 follow_copied=0

Top callers by bytes copied (inlined frames, innermost first, runtime frames trimmed):

| MiB | calls | caller | paths (calls/bytes) |
|---:|---:|---|---|
| 11.9 | 106170 | ListOf(ast.Node,0).growBy | small_small=106127/6938416 small_large=14/442368 span_copy_warm=13/1835008 span_copy_new=8/3211264 |
| 8.1 | 83 | rig.ordered.Ordered(checker.CacheKey,checker.TypeList).reserveOne | small_small=61/202368 small_large=5/122880 span_copy_warm=12/2457600 span_copy_new=4/5701632 |
| 5.7 | 30 | String.growList < String.appendBytes < String.addValue | small_small=18/46733 small_large=1/23377 span_copy_warm=7/1674591 span_copy_new=3/4268616 |
| 5.1 | 3577 | ListOf(ast.SymbolRec,0).growTo < ListOf(ast.SymbolRec,0).push < binder.Binder.new_symbol | small_small=3544/3816992 small_large=22/577664 span_copy_warm=9/583392 span_copy_new=1/323296 |
| 4.2 | 4 | ListOf(compiler.ParseTask,0).growTo < ListOf(compiler.ParseTask,0).push < compiler.FileLoader.new_task | span_copy_new=4/4423680 |
| 4.0 | 4 | ListOf(checker.InferenceInfo,0).growTo < ListOf(checker.InferenceInfo,0).push < checker.Checker.alloc_inference_info | span_copy_warm=1/73728 span_copy_new=3/4128768 |
| 4.0 | 21869 | ListOf(i64,0).growBy | small_small=21869/4180768 |
| 3.7 | 13 | ListOf(checker.InferenceContext,0).growTo < ListOf(checker.InferenceContext,0).push < checker.Checker.new_inference_context_worker | small_small=6/30240 small_large=1/30720 span_copy_warm=2/307200 span_copy_new=4/3563520 |
| 3.6 | 6712 | rig.ordered.Ordered(u32,u32).reserveOne | small_small=6706/3494112 small_large=2/65536 span_copy_warm=2/131072 span_copy_new=1/131072 |
| 3.1 | 9 | rig.ordered.Ordered(module.ModuleResolutionCacheKey,module.ResolvedModule).reserveOne | small_small=2/32000 small_large=1/25600 span_copy_warm=1/102400 span_copy_new=5/3123200 |
| 3.0 | 10 | ListOf(rig.runtime.Niche(ast.File,.{ .offset = 752, .Word = u32, .value = 7, .spare = 65536 }),0).growTo < ListOf(rig.runtime.Niche(ast.File,.{ .offset = 752, .Word = u32, .value = 7, .spare = 65536 }),0).push < compiler.FileStore.put | small_small=3/21504 small_large=1/24576 span_copy_warm=1/49152 span_copy_new=5/3047424 |
| 2.3 | 1111 | ListOf(module.ResolvedModule,0).growTo < ListOf(module.ResolvedModule,0).push < module.ModeAwareCache(module.ResolvedModule).push | small_small=1102/2151680 small_large=5/102400 span_copy_warm=1/40960 span_copy_new=2/81920 |
| 2.3 | 1133 | ListOf(compiler.SubRef,0).growTo < ListOf(compiler.SubRef,0).push | small_small=1116/1995840 small_large=9/161280 span_copy_warm=2/107520 span_copy_new=2/107520 |
| 1.9 | 37 | rig.ordered.Ordered(checker.UnionOfUnionKey,u32).reserveOne | small_small=23/108288 small_large=3/73728 span_copy_warm=6/983040 span_copy_new=5/835584 |
| 1.6 | 343 | rig.ordered.Ordered(u32,checker.ExportCollision).reserveOne | small_small=342/1622016 small_large=1/32768 |
| 1.4 | 2054 | ListOf(packagejson.StringPair,0).growTo < ListOf(packagejson.StringPair,0).push < packagejson.put_pair | small_small=2054/1444864 |
| 1.4 | 2054 | ListOf(packagejson.StringPair,0).growTo < ListOf(packagejson.StringPair,0).push < packagejson.decode_string_map | small_small=2054/1444864 |
| 1.3 | 13 | ListOf(checker.LazyMemberTable,0).growTo < ListOf(checker.LazyMemberTable,0).push < checker.Checker.get_ready_lazy_member_table_worker | small_small=7/28448 small_large=1/28672 span_copy_warm=1/57344 span_copy_new=3/1261568 |
| 1.1 | 26079 | rig.ordered.Ordered(u32,u32).insertSmallSlow | small_small=26079/1177688 |
| 1.1 | 39 | ListOf(u64,0).growBy | small_small=33/82304 small_large=2/65536 span_copy_warm=3/458752 span_copy_new=1/524288 |
| 1.0 | 8757 | String.growList < String.appendBytes < String.addValue | small_small=8757/1085576 |
| 1.0 | 1 | ListOf(ast.NodeRec,0).growTo < ListOf(ast.NodeRec,0).push < ast.Ast.new_node | span_copy_new=1/1048576 |
| 1.0 | 256 | ListOf(tspath.RootedFilePath,0).growTo < ListOf(tspath.RootedFilePath,0).push < compiler.Program.common_source_directory | small_small=256/1044480 |
| 1.0 | 757 | ListOf(ast.SymbolRec,0).growTo < ListOf(ast.SymbolRec,0).push < binder.Binder.new_symbol | small_small=756/982144 small_large=1/17440 |
| 0.9 | 11 | rig.ordered.Ordered(u32,rig.runtime.ListOf(printer.EmitHelper,0)).reserveOne | small_small=6/33280 small_large=1/32768 span_copy_warm=2/393216 span_copy_new=1/524288 |

(736 callers in all, 106.1 MiB)

### nuxt.c4.census (page 16384)

| path | calls | MiB copied | share of bytes |
|---|---:|---:|---:|
| same | 1380 | 0.0 | 0.0% |
| small_small | 462752 | 71.4 | 47.4% |
| small_large | 386 | 7.5 | 5.0% |
| shrink_small | 1428 | 0.2 | 0.1% |
| span_grow_warm | 54 | 0.0 | 0.0% |
| span_copy_warm | 165 | 16.5 | 10.9% |
| span_grow_fresh | 20 | 0.0 | 0.0% |
| span_copy_new | 241 | 55.1 | 36.6% |
| all | 466426 | 150.6 | |

Bytes copied by block size (MiB; bucket = old size < 2^k):

| size < | small_small | small_large | shrink_small | span_copy_warm | span_copy_new |
|---|---:|---:|---:|---:|---:|
| 2 B | 8 / 0.0 |  |  |  |  |
| 4 B | 1 / 0.0 |  |  |  |  |
| 8 B | 9615 / 0.0 |  |  |  |  |
| 16 B | 8852 / 0.1 |  |  |  |  |
| 32 B | 137243 / 2.2 |  |  |  |  |
| 64 B | 109461 / 3.6 | 16 / 0.0 | 24 / 0.0 |  |  |
| 128 B | 82886 / 5.7 | 19 / 0.0 | 525 / 0.1 |  |  |
| 256 B | 61223 / 8.2 | 60 / 0.0 | 879 / 0.1 |  |  |
| 512 B | 25016 / 6.9 |  |  |  |  |
| 1 KiB | 13531 / 7.2 |  |  |  |  |
| 2 KiB | 7990 / 8.6 |  |  |  |  |
| 4 KiB | 4131 / 9.0 |  |  |  |  |
| 8 KiB | 1587 / 7.0 | 1 / 0.0 |  |  |  |
| 16 KiB | 890 / 7.9 |  |  |  |  |
| 32 KiB | 318 / 5.0 | 183 / 4.1 |  |  |  |
| 64 KiB |  | 107 / 3.3 |  | 51 / 2.3 | 46 / 2.0 |
| 128 KiB |  |  |  | 65 / 4.7 | 68 / 5.4 |
| 256 KiB |  |  |  | 34 / 5.2 | 53 / 8.2 |
| 512 KiB |  |  |  | 13 / 3.3 | 40 / 12.6 |
| 1 MiB |  |  |  | 2 / 1.0 | 25 / 14.3 |
| 2 MiB |  |  |  |  | 8 / 10.3 |
| 4 MiB |  |  |  |  | 1 / 2.2 |
    src steal n=107 copied=14424369
    src cold n=2 copied=589824
    src carve n=132 copied=42748471
    follow copy_warm any n=1 copied=131072
    follow copy_warm cold n=1 copied=131072
    ge copy_warm pages>=4 n=114 copied=14837257 aligned_n=28 aligned_copied=4173344 follow_n=1 follow_copied=131072
    ge copy_warm pages>=16 n=15 copied=4517600 aligned_n=5 aligned_copied=1572864 follow_n=0 follow_copied=0
    ge copy_new pages>=4 n=195 copied=55625623 aligned_n=52 aligned_copied=18407761 follow_n=0 follow_copied=0
    ge copy_new pages>=16 n=74 copied=41371387 aligned_n=20 aligned_copied=14380008 follow_n=0 follow_copied=0
    ge copy_new pages>=64 n=9 copied=13200360 aligned_n=4 aligned_copied=7302120 follow_n=0 follow_copied=0

Top callers by bytes copied (inlined frames, innermost first, runtime frames trimmed):

| MiB | calls | caller | paths (calls/bytes) |
|---:|---:|---|---|
| 22.7 | 166486 | ListOf(ast.Node,0).growBy | small_small=166366/11660244 small_large=38/1228800 span_copy_warm=30/3801088 span_copy_new=38/7143424 |
| 10.3 | 273 | rig.ordered.Ordered(checker.CacheKey,checker.TypeList).reserveOne | small_small=212/686592 small_large=15/368640 span_copy_warm=15/1769472 span_copy_new=24/8011776 |
| 7.5 | 12508 | rig.ordered.Ordered(u32,u32).reserveOne | small_small=12497/7197136 small_large=4/131072 span_copy_warm=4/393216 span_copy_new=1/131072 |
| 5.8 | 62 | String.growList < String.appendBytes < String.addValue | small_small=50/49055 small_large=1/23377 span_copy_new=10/5960739 |
| 5.0 | 3577 | ListOf(ast.SymbolRec,0).growTo < ListOf(ast.SymbolRec,0).push < binder.Binder.new_symbol | small_small=3544/3816992 small_large=22/577664 span_copy_warm=9/896768 |
| 4.9 | 31585 | ListOf(i64,0).growBy | small_small=31585/5181696 |
| 4.7 | 45 | ListOf(checker.InferenceContext,0).growTo < ListOf(checker.InferenceContext,0).push < checker.Checker.new_inference_context_worker | small_small=24/120960 small_large=4/122880 span_copy_warm=3/430080 span_copy_new=14/4239360 |
| 4.6 | 1003 | rig.ordered.Ordered(u32,checker.ExportCollision).reserveOne | small_small=1001/4773888 small_large=2/65536 |
| 4.2 | 4 | ListOf(compiler.ParseTask,0).growTo < ListOf(compiler.ParseTask,0).push < compiler.FileLoader.new_task | span_copy_new=4/4423680 |
| 2.3 | 1111 | ListOf(module.ResolvedModule,0).growTo < ListOf(module.ResolvedModule,0).push < module.ModeAwareCache(module.ResolvedModule).push | small_small=1102/2151680 small_large=5/102400 span_copy_warm=1/40960 span_copy_new=3/163840 |
| 2.3 | 1133 | ListOf(compiler.SubRef,0).growTo < ListOf(compiler.SubRef,0).push | small_small=1116/1995840 small_large=9/161280 span_copy_warm=2/107520 span_copy_new=4/143360 |
| 2.2 | 55143 | rig.ordered.Ordered(u32,u32).insertSmallSlow | small_small=55143/2291152 |
| 2.2 | 6 | ListOf(rig.runtime.Niche(ast.File,.{ .offset = 752, .Word = u32, .value = 7, .spare = 65536 }),0).growTo < ListOf(rig.runtime.Niche(ast.File,.{ .offset = 752, .Word = u32, .value = 7, .spare = 65536 }),0).push < compiler.FileStore.put | span_copy_new=4/2260992 |
| 2.0 | 64 | rig.ordered.Ordered(checker.UnionOfUnionKey,u32).reserveOne | small_small=43/209664 small_large=6/147456 span_copy_warm=6/540672 span_copy_new=9/1228800 |
| 1.7 | 44 | ListOf(checker.LazyMemberTable,0).growTo < ListOf(checker.LazyMemberTable,0).push < checker.Checker.get_ready_lazy_member_table_worker | small_small=28/113792 small_large=4/114688 span_copy_warm=3/344064 span_copy_new=9/1261568 |
| 1.6 | 22 | rig.ordered.Ordered(u32,rig.runtime.ListOf(printer.EmitHelper,0)).reserveOne | small_small=12/66560 small_large=2/65536 span_copy_new=6/1572864 |
| 1.5 | 2225 | ListOf(packagejson.StringPair,0).growTo < ListOf(packagejson.StringPair,0).push < packagejson.put_pair | small_small=2225/1577984 |
| 1.5 | 2225 | ListOf(packagejson.StringPair,0).growTo < ListOf(packagejson.StringPair,0).push < packagejson.decode_string_map | small_small=2225/1577984 |
| 1.5 | 2 | ListOf(ast.NodeRec,0).growTo < ListOf(ast.NodeRec,0).push < ast.Ast.new_node | span_copy_new=2/1572864 |
| 1.5 | 48 | ListOf(rig.runtime.ListOf(checker.NodeRef,0),0).growTo < ListOf(rig.runtime.ListOf(checker.NodeRef,0),0).push < checker.Checker.push_data_declaration | small_small=32/97920 small_large=4/98304 span_copy_warm=7/737280 span_copy_new=2/589824 |
| 1.4 | 7 | ListOf(checker.InferenceInfo,0).growTo < ListOf(checker.InferenceInfo,0).push < checker.Checker.alloc_inference_info | span_copy_warm=1/36864 span_copy_new=5/1474560 |
| 1.3 | 4806 | rig.ordered.Ordered(u32,void).reserveOne | small_small=4805/1317120 small_large=1/32768 |
| 1.2 | 10 | ListOf(checker.InferenceInfo,0).growTo < ListOf(checker.InferenceInfo,0).push < checker.Checker.alloc_inference_info | small_small=2/10368 small_large=1/18432 span_copy_warm=1/73728 span_copy_new=5/1142784 |
| 1.2 | 78 | ListOf(u64,0).growBy | small_small=71/152928 small_large=3/98304 span_copy_new=4/983040 |
| 1.2 | 48 | ListOf(rig.runtime.ListOf(u32,0),0).growTo < ListOf(rig.runtime.ListOf(u32,0),0).push < checker.Checker.conditional_flow_step | small_small=32/97920 small_large=4/98304 span_copy_warm=6/688128 span_copy_new=3/344064 |

(854 callers in all, 150.6 MiB)

### typeorm.c1.census (page 16384)

| path | calls | MiB copied | share of bytes |
|---|---:|---:|---:|
| same | 253 | 0.0 | 0.0% |
| small_small | 178654 | 31.0 | 37.9% |
| small_large | 141 | 3.2 | 3.9% |
| shrink_small | 63 | 0.0 | 0.0% |
| span_grow_warm | 26 | 0.0 | 0.0% |
| span_copy_warm | 146 | 19.1 | 23.3% |
| span_grow_fresh | 2 | 0.0 | 0.0% |
| span_copy_new | 33 | 28.5 | 34.9% |
| all | 179318 | 81.8 | |

Bytes copied by block size (MiB; bucket = old size < 2^k):

| size < | small_small | small_large | shrink_small | span_copy_warm | span_copy_new |
|---|---:|---:|---:|---:|---:|
| 4 B | 2 / 0.0 |  |  |  |  |
| 8 B | 6852 / 0.0 |  |  |  |  |
| 16 B | 801 / 0.0 |  |  |  |  |
| 32 B | 27717 / 0.4 |  |  |  |  |
| 64 B | 39682 / 1.3 |  |  |  |  |
| 128 B | 55845 / 4.2 |  | 34 / 0.0 |  |  |
| 256 B | 24328 / 3.3 | 13 / 0.0 | 29 / 0.0 |  |  |
| 512 B | 10008 / 2.7 |  |  |  |  |
| 1 KiB | 5576 / 2.9 |  |  |  |  |
| 2 KiB | 5362 / 6.0 |  |  |  |  |
| 4 KiB | 1497 / 3.3 | 1 / 0.0 |  |  |  |
| 8 KiB | 595 / 2.7 |  |  |  |  |
| 16 KiB | 301 / 2.7 |  |  |  |  |
| 32 KiB | 88 / 1.4 | 83 / 1.8 |  |  |  |
| 64 KiB |  | 44 / 1.4 |  | 47 / 2.1 | 4 / 0.2 |
| 128 KiB |  |  |  | 51 / 4.1 | 6 / 0.4 |
| 256 KiB |  |  |  | 29 / 4.4 | 6 / 0.9 |
| 512 KiB |  |  |  | 15 / 4.8 | 4 / 1.4 |
| 1 MiB |  |  |  | 3 / 2.2 | 2 / 1.5 |
| 2 MiB |  |  |  | 1 / 1.5 | 6 / 8.2 |
| 4 MiB |  |  |  |  | 4 / 11.4 |
| 8 MiB |  |  |  |  | 1 / 4.5 |
    src cold n=1 copied=786432
    src carve n=32 copied=29122809
    follow copy_warm any n=1 copied=44032
    follow copy_warm cold n=1 copied=44032
    ge copy_warm pages>=4 n=99 copied=17805778 aligned_n=38 aligned_copied=7764841 follow_n=0 follow_copied=0
    ge copy_warm pages>=16 n=19 copied=8927333 aligned_n=11 aligned_copied=4620288 follow_n=0 follow_copied=0
    ge copy_warm pages>=64 n=1 copied=1572864 aligned_n=0 aligned_copied=0 follow_n=0 follow_copied=0
    ge copy_new pages>=4 n=29 copied=29732864 aligned_n=11 aligned_copied=11796480 follow_n=0 follow_copied=0
    ge copy_new pages>=16 n=17 copied=28311552 aligned_n=6 aligned_copied=11173888 follow_n=0 follow_copied=0
    ge copy_new pages>=64 n=11 copied=25231360 aligned_n=3 aligned_copied=9568256 follow_n=0 follow_copied=0

Top callers by bytes copied (inlined frames, innermost first, runtime frames trimmed):

| MiB | calls | caller | paths (calls/bytes) |
|---:|---:|---|---|
| 7.9 | 3 | ListOf(compiler.ParseTask,0).growTo < ListOf(compiler.ParseTask,0).push < compiler.FileLoader.new_task | span_copy_new=3/8257536 |
| 7.5 | 14 | ListOf(checker.InferenceContext,0).growTo < ListOf(checker.InferenceContext,0).push < checker.Checker.new_inference_context_worker | small_small=6/30240 small_large=1/30720 span_copy_warm=5/1904640 span_copy_new=2/5898240 |
| 6.3 | 10 | rig.ordered.Ordered(module.ModuleResolutionCacheKey,module.ResolvedModule).reserveOne | small_small=2/32000 small_large=1/25600 span_copy_new=7/6502400 |
| 6.0 | 59648 | ListOf(ast.Node,0).growBy | small_small=59623/3180816 small_large=7/229376 span_copy_warm=13/1638400 span_copy_new=3/1245184 |
| 4.2 | 7711 | ListOf(ast.SymbolRec,0).growTo < ListOf(ast.SymbolRec,0).push < binder.Binder.new_symbol | small_small=7697/3960768 small_large=9/258336 span_copy_warm=4/222304 |
| 4.0 | 58 | rig.ordered.Ordered(checker.CacheKey,checker.TypeList).reserveOne | small_small=41/155136 small_large=5/122880 span_copy_warm=10/3096576 span_copy_new=1/786432 |
| 3.0 | 10 | ListOf(rig.runtime.Niche(ast.File,.{ .offset = 752, .Word = u32, .value = 7, .spare = 65536 }),0).growTo < ListOf(rig.runtime.Niche(ast.File,.{ .offset = 752, .Word = u32, .value = 7, .spare = 65536 }),0).push < compiler.FileStore.put | small_small=3/21504 small_large=1/24576 span_copy_warm=3/1032192 span_copy_new=3/2064384 |
| 3.0 | 1911 | ListOf(module.ResolvedModule,0).growTo < ListOf(module.ResolvedModule,0).push < module.ModeAwareCache(module.ResolvedModule).push | small_small=1908/3051520 small_large=2/40960 span_copy_warm=1/40960 |
| 2.6 | 1903 | ListOf(compiler.SubRef,0).growTo < ListOf(compiler.SubRef,0).push | small_small=1901/2656640 small_large=1/17920 span_copy_warm=1/35840 |
| 2.4 | 3 | ListOf(checker.InferenceInfo,0).growTo < ListOf(checker.InferenceInfo,0).push < checker.Checker.alloc_inference_info | small_small=1/9216 span_copy_warm=1/147456 span_copy_new=1/2359296 |
| 1.8 | 5 | ListOf(checker.InferenceInfo,0).growTo < ListOf(checker.InferenceInfo,0).push < checker.Checker.alloc_inference_info | small_large=1/18432 span_copy_warm=3/700416 span_copy_new=1/1179648 |
| 1.4 | 1815 | ListOf(ast.SymbolRec,0).growTo < ListOf(ast.SymbolRec,0).push < binder.Binder.new_symbol | small_small=1813/1426176 small_large=2/65536 |
| 1.4 | 7601 | ListOf(i64,0).growBy | small_small=7600/1444064 small_large=1/32768 |
| 1.3 | 2221 | rig.ordered.Ordered(u32,u32).reserveOne | small_small=2215/936344 small_large=2/65536 span_copy_warm=4/393216 |
| 1.1 | 12446 | String.growList < String.appendBytes < String.addValue | small_small=12446/1205213 |
| 1.1 | 28 | String.growList < String.appendBytes < String.addValue | small_small=18/46733 small_large=1/23377 span_copy_warm=6/1049189 |
| 1.0 | 11289 | String.growList < String.reserve < tspath.get_normalized_absolute_path_from_normalized_slashes | small_small=11289/1088941 |
| 0.9 | 12 | ListOf(checker.LazyMemberTable,0).growTo < ListOf(checker.LazyMemberTable,0).push < checker.Checker.get_ready_lazy_member_table_worker | small_small=7/28448 small_large=1/28672 span_copy_warm=4/860160 |
| 0.8 | 12 | ListOf(checker.SyntheticNode,0).growTo < ListOf(checker.SyntheticNode,0).push < checker.Checker.new_synthetic_node | small_small=7/28448 small_large=1/28672 span_copy_warm=3/802816 |
| 0.8 | 28 | rig.ordered.Ordered(checker.UnionOfUnionKey,u32).reserveOne | small_small=17/79872 small_large=3/73728 span_copy_warm=4/442368 span_copy_new=2/245760 |
| 0.8 | 20 | String.growList < String.appendBytes < String.addValue | small_small=13/68400 small_large=1/23377 span_copy_warm=6/728681 |
| 0.7 | 7155 | ListOf(ast.SymbolEntry,0).growTo < ListOf(ast.SymbolEntry,0).push < ast.Binding.table_put | small_small=7155/766840 |
| 0.7 | 577 | ListOf(compiler.FileIncludeReason,0).growTo < ListOf(compiler.FileIncludeReason,0).push < compiler.FileLoader.add_include_reason | small_small=566/381280 small_large=8/163840 span_copy_warm=3/163840 |
| 0.6 | 9703 | String.growList < String.appendBytes < String.appendFixed__func_1249 | small_small=9703/654734 |
| 0.6 | 2297 | ListOf(ast.FlowRec,0).growTo < ListOf(ast.FlowRec,0).push < binder.Binder.new_flow_node | small_small=2295/603100 small_large=2/37360 |

(580 callers in all, 81.8 MiB)

### typeorm.c4.census (page 16384)

| path | calls | MiB copied | share of bytes |
|---|---:|---:|---:|
| same | 296 | 0.0 | 0.0% |
| small_small | 210226 | 38.6 | 44.2% |
| small_large | 251 | 6.0 | 6.9% |
| shrink_small | 70 | 0.0 | 0.0% |
| span_grow_warm | 41 | 0.0 | 0.0% |
| span_copy_warm | 150 | 13.8 | 15.8% |
| span_grow_fresh | 10 | 0.0 | 0.0% |
| span_copy_new | 112 | 28.9 | 33.1% |
| all | 211156 | 87.3 | |

Bytes copied by block size (MiB; bucket = old size < 2^k):

| size < | small_small | small_large | shrink_small | span_copy_warm | span_copy_new |
|---|---:|---:|---:|---:|---:|
| 4 B | 2 / 0.0 |  |  |  |  |
| 8 B | 8325 / 0.0 |  |  |  |  |
| 16 B | 1473 / 0.0 |  |  |  |  |
| 32 B | 30489 / 0.5 |  |  |  |  |
| 64 B | 52799 / 1.7 |  |  |  |  |
| 128 B | 62368 / 4.7 |  | 40 / 0.0 |  |  |
| 256 B | 27515 / 3.7 | 13 / 0.0 | 30 / 0.0 |  |  |
| 512 B | 11682 / 3.2 |  |  |  |  |
| 1 KiB | 6401 / 3.4 |  |  |  |  |
| 2 KiB | 5854 / 6.6 |  |  |  |  |
| 4 KiB | 1857 / 4.1 | 1 / 0.0 |  |  |  |
| 8 KiB | 825 / 3.8 | 1 / 0.0 |  |  |  |
| 16 KiB | 485 / 4.5 |  |  |  |  |
| 32 KiB | 151 / 2.4 | 151 / 3.4 |  |  |  |
| 64 KiB |  | 85 / 2.7 |  | 63 / 2.9 | 31 / 1.4 |
| 128 KiB |  |  |  | 56 / 4.4 | 35 / 2.8 |
| 256 KiB |  |  |  | 23 / 3.8 | 20 / 3.1 |
| 512 KiB |  |  |  | 7 / 2.2 | 13 / 4.2 |
| 1 MiB |  |  |  | 1 / 0.6 | 7 / 5.4 |
| 2 MiB |  |  |  |  | 4 / 5.3 |
| 4 MiB |  |  |  |  | 1 / 2.2 |
| 8 MiB |  |  |  |  | 1 / 4.5 |
    src steal n=62 copied=9141454
    src carve n=50 copied=21167116
    ge copy_warm pages>=4 n=87 copied=11445973 aligned_n=30 aligned_copied=4484262 follow_n=0 follow_copied=0
    ge copy_warm pages>=16 n=8 copied=2883584 aligned_n=3 aligned_copied=1146880 follow_n=0 follow_copied=0
    ge copy_new pages>=4 n=81 copied=28844652 aligned_n=31 aligned_copied=12712000 follow_n=0 follow_copied=0
    ge copy_new pages>=16 n=26 copied=22653629 aligned_n=16 aligned_copied=11101248 follow_n=0 follow_copied=0
    ge copy_new pages>=64 n=6 copied=12664832 aligned_n=3 aligned_copied=4407296 follow_n=0 follow_copied=0

Top callers by bytes copied (inlined frames, innermost first, runtime frames trimmed):

| MiB | calls | caller | paths (calls/bytes) |
|---:|---:|---|---|
| 7.9 | 3 | ListOf(compiler.ParseTask,0).growTo < ListOf(compiler.ParseTask,0).push < compiler.FileLoader.new_task | span_copy_new=3/8257536 |
| 7.6 | 66827 | ListOf(ast.Node,0).growBy | small_small=66774/4026980 small_large=19/622592 span_copy_warm=14/1703936 span_copy_new=14/1638400 |
| 5.1 | 47 | ListOf(checker.InferenceContext,0).growTo < ListOf(checker.InferenceContext,0).push < checker.Checker.new_inference_context_worker | small_small=24/120960 small_large=4/122880 span_copy_warm=10/1781760 span_copy_new=6/3317760 |
| 4.4 | 174 | rig.ordered.Ordered(checker.CacheKey,checker.TypeList).reserveOne | small_small=136/474624 small_large=12/294912 span_copy_warm=16/1818624 span_copy_new=8/2064384 |
| 4.2 | 7711 | ListOf(ast.SymbolRec,0).growTo < ListOf(ast.SymbolRec,0).push < binder.Binder.new_symbol | small_small=7697/3960768 small_large=9/258336 span_copy_warm=3/142464 |
| 3.0 | 1911 | ListOf(module.ResolvedModule,0).growTo < ListOf(module.ResolvedModule,0).push < module.ModeAwareCache(module.ResolvedModule).push | small_small=1908/3051520 small_large=2/40960 span_copy_warm=1/40960 |
| 3.0 | 6 | ListOf(rig.runtime.Niche(ast.File,.{ .offset = 752, .Word = u32, .value = 7, .spare = 65536 }),0).growTo < ListOf(rig.runtime.Niche(ast.File,.{ .offset = 752, .Word = u32, .value = 7, .spare = 65536 }),0).push < compiler.FileStore.put | span_copy_new=6/3096576 |
| 2.6 | 1903 | ListOf(compiler.SubRef,0).growTo < ListOf(compiler.SubRef,0).push | small_small=1901/2656640 small_large=1/17920 span_copy_warm=1/35840 |
| 2.2 | 28 | String.growList < String.appendBytes < String.addValue | small_small=18/46733 small_large=1/23377 span_copy_warm=3/166557 span_copy_new=5/2059884 |
| 2.0 | 12497 | ListOf(i64,0).growBy | small_small=12496/2069408 small_large=1/32768 |
| 2.0 | 7 | ListOf(checker.InferenceInfo,0).growTo < ListOf(checker.InferenceInfo,0).push < checker.Checker.alloc_inference_info | small_small=1/288 span_copy_warm=3/258048 span_copy_new=3/1843200 |
| 1.7 | 3499 | rig.ordered.Ordered(u32,u32).reserveOne | small_small=3493/1634736 small_large=6/196608 |
| 1.7 | 8 | rig.ordered.Ordered(i64,compiler.Flight).reserveOne | small_large=1/25856 span_copy_new=2/1758208 |
| 1.4 | 1815 | ListOf(ast.SymbolRec,0).growTo < ListOf(ast.SymbolRec,0).push < binder.Binder.new_symbol | small_small=1813/1426176 small_large=2/65536 |
| 1.2 | 41 | ListOf(checker.LazyMemberTable,0).growTo < ListOf(checker.LazyMemberTable,0).push < checker.Checker.get_ready_lazy_member_table_worker | small_small=28/113792 small_large=4/114688 span_copy_warm=8/974848 span_copy_new=1/57344 |
| 1.2 | 12838 | String.growList < String.appendBytes < String.addValue | small_small=12838/1240031 |
| 1.1 | 60 | rig.ordered.Ordered(rig.runtime.String,i64).reserveOne | small_small=40/202752 small_large=8/196608 span_copy_warm=6/393216 span_copy_new=6/393216 |
| 1.1 | 11759 | String.growList < String.reserve < tspath.get_normalized_absolute_path_from_normalized_slashes | small_small=11759/1141381 |
| 0.9 | 47 | rig.ordered.Ordered(checker.UnionOfUnionKey,u32).reserveOne | small_small=32/155904 small_large=6/147456 span_copy_warm=3/147456 span_copy_new=4/540672 |
| 0.9 | 35 | ListOf(checker.SyntheticNode,0).growTo < ListOf(checker.SyntheticNode,0).push < checker.Checker.new_synthetic_node | small_small=26/92288 small_large=3/86016 span_copy_warm=3/401408 span_copy_new=3/401408 |
| 0.9 | 22563 | rig.ordered.Ordered(u32,u32).insertSmallSlow | small_small=22563/911048 |
| 0.7 | 7155 | ListOf(ast.SymbolEntry,0).growTo < ListOf(ast.SymbolEntry,0).push < ast.Binding.table_put | small_small=7155/766840 |
| 0.7 | 2 | ListOf(checker.InferenceInfo,0).growTo < ListOf(checker.InferenceInfo,0).push < checker.Checker.alloc_inference_info | span_copy_warm=2/737280 |
| 0.7 | 577 | ListOf(compiler.FileIncludeReason,0).growTo < ListOf(compiler.FileIncludeReason,0).push < compiler.FileLoader.add_include_reason | small_small=566/381280 small_large=8/163840 span_copy_new=3/163840 |
| 0.7 | 44 | ListOf(rig.runtime.ListOf(u32,0),0).growTo < ListOf(rig.runtime.ListOf(u32,0),0).push < checker.Checker.conditional_flow_step | small_small=32/97920 small_large=4/98304 span_copy_warm=5/344064 span_copy_new=2/147456 |

(658 callers in all, 87.3 MiB)

### webpack.c1.census (page 16384)

| path | calls | MiB copied | share of bytes |
|---|---:|---:|---:|
| same | 412 | 0.0 | 0.0% |
| small_small | 282355 | 44.4 | 40.8% |
| small_large | 254 | 5.6 | 5.2% |
| shrink_small | 132 | 0.0 | 0.0% |
| span_grow_warm | 26 | 0.0 | 0.0% |
| span_copy_warm | 164 | 19.5 | 17.9% |
| span_grow_fresh | 14 | 0.0 | 0.0% |
| span_copy_new | 103 | 39.4 | 36.2% |
| all | 283460 | 108.9 | |

Bytes copied by block size (MiB; bucket = old size < 2^k):

| size < | small_small | small_large | shrink_small | span_copy_warm | span_copy_new |
|---|---:|---:|---:|---:|---:|
| 2 B | 3 / 0.0 |  |  |  |  |
| 4 B | 2 / 0.0 |  |  |  |  |
| 8 B | 8589 / 0.0 |  |  |  |  |
| 16 B | 7368 / 0.1 |  |  |  |  |
| 32 B | 64946 / 1.0 |  |  |  |  |
| 64 B | 82986 / 2.9 | 2 / 0.0 | 4 / 0.0 |  |  |
| 128 B | 53389 / 3.6 | 5 / 0.0 | 127 / 0.0 |  |  |
| 256 B | 32637 / 4.4 | 26 / 0.0 | 1 / 0.0 |  |  |
| 512 B | 15604 / 4.3 |  |  |  |  |
| 1 KiB | 7554 / 4.1 |  |  |  |  |
| 2 KiB | 4676 / 5.1 |  |  |  |  |
| 4 KiB | 2640 / 5.7 | 1 / 0.0 |  |  |  |
| 8 KiB | 1178 / 5.2 |  |  |  |  |
| 16 KiB | 599 / 5.3 |  |  |  |  |
| 32 KiB | 184 / 2.9 | 125 / 2.7 |  |  |  |
| 64 KiB |  | 95 / 3.0 |  | 46 / 2.0 | 17 / 0.8 |
| 128 KiB |  |  |  | 61 / 4.5 | 22 / 1.6 |
| 256 KiB |  |  |  | 34 / 4.8 | 19 / 3.1 |
| 512 KiB |  |  |  | 17 / 4.9 | 15 / 4.6 |
| 1 MiB |  |  |  | 6 / 3.3 | 18 / 11.6 |
| 2 MiB |  |  |  |  | 9 / 10.4 |
| 4 MiB |  |  |  |  | 3 / 7.3 |
    src cold n=1 copied=524288
    src carve n=102 copied=40749595
    ge copy_warm pages>=4 n=118 copied=18364586 aligned_n=16 aligned_copied=1993191 follow_n=0 follow_copied=0
    ge copy_warm pages>=16 n=23 copied=8604808 aligned_n=2 aligned_copied=528413 follow_n=0 follow_copied=0
    ge copy_new pages>=4 n=86 copied=40481066 aligned_n=25 aligned_copied=9316501 follow_n=0 follow_copied=0
    ge copy_new pages>=16 n=45 copied=35541930 aligned_n=9 aligned_copied=7276693 follow_n=0 follow_copied=0
    ge copy_new pages>=64 n=12 copied=18526239 aligned_n=3 aligned_copied=4595343 follow_n=0 follow_copied=0

Top callers by bytes copied (inlined frames, innermost first, runtime frames trimmed):

| MiB | calls | caller | paths (calls/bytes) |
|---:|---:|---|---|
| 11.6 | 117090 | ListOf(ast.Node,0).growBy | small_small=117049/6256252 small_large=11/360448 span_copy_warm=13/1703936 span_copy_new=12/3866624 |
| 8.6 | 83 | rig.ordered.Ordered(checker.CacheKey,checker.TypeList).reserveOne | small_small=58/201600 small_large=6/147456 span_copy_warm=11/1916928 span_copy_new=8/6782976 |
| 6.7 | 3370 | ListOf(ast.SymbolRec,0).growTo < ListOf(ast.SymbolRec,0).push < binder.Binder.new_symbol | small_small=3324/3938432 small_large=25/786528 span_copy_warm=10/921120 span_copy_new=6/1332320 |
| 4.9 | 15 | String.growList < String.appendBytes < String.addValue | small_small=8/45579 span_copy_warm=1/186826 span_copy_new=5/4877901 |
| 4.2 | 4 | ListOf(compiler.ParseTask,0).growTo < ListOf(compiler.ParseTask,0).push < compiler.FileLoader.new_task | span_copy_new=4/4423680 |
| 4.1 | 17881 | ListOf(i64,0).growBy | small_small=17864/3642976 small_large=11/360448 span_copy_warm=4/327680 |
| 3.8 | 29 | String.growList < String.appendBytes < String.addValue | small_small=18/46733 small_large=1/23377 span_copy_warm=7/1674591 span_copy_new=2/2246640 |
| 3.3 | 6178 | rig.ordered.Ordered(u32,u32).reserveOne | small_small=6173/3144120 small_large=2/65536 span_copy_warm=3/262144 |
| 2.1 | 877 | ListOf(compiler.SubRef,0).growTo < ListOf(compiler.SubRef,0).push | small_small=867/1823360 small_large=5/89600 span_copy_warm=3/143360 span_copy_new=2/107520 |
| 2.0 | 12 | rig.ordered.Ordered(checker.FlowLoopKey,u32).reserveOne | small_small=6/33280 small_large=1/32768 span_copy_warm=2/655360 span_copy_new=3/1376256 |
| 1.9 | 803 | ListOf(module.ResolvedModule,0).growTo < ListOf(module.ResolvedModule,0).push < module.ModeAwareCache(module.ResolvedModule).push | small_small=795/1809920 small_large=5/102400 span_copy_warm=1/40960 span_copy_new=2/81920 |
| 1.8 | 12 | ListOf(checker.InferenceContext,0).growTo < ListOf(checker.InferenceContext,0).push < checker.Checker.new_inference_context_worker | small_small=6/30240 small_large=1/30720 span_copy_new=4/1843200 |
| 1.7 | 13 | ListOf(checker.LazyMemberTable,0).growTo < ListOf(checker.LazyMemberTable,0).push < checker.Checker.get_ready_lazy_member_table_worker | small_small=7/28448 small_large=1/28672 span_copy_warm=4/860160 span_copy_new=1/917504 |
| 1.6 | 8 | rig.ordered.Ordered(module.ModuleResolutionCacheKey,module.ResolvedModule).reserveOne | small_small=2/32000 small_large=1/25600 span_copy_warm=1/102400 span_copy_new=4/1484800 |
| 1.5 | 4 | ListOf(checker.InferenceInfo,0).growTo < ListOf(checker.InferenceInfo,0).push < checker.Checker.alloc_inference_info | span_copy_warm=1/36864 span_copy_new=3/1548288 |
| 1.5 | 9 | ListOf(rig.runtime.Niche(ast.File,.{ .offset = 752, .Word = u32, .value = 7, .spare = 65536 }),0).growTo < ListOf(rig.runtime.Niche(ast.File,.{ .offset = 752, .Word = u32, .value = 7, .spare = 65536 }),0).push < compiler.FileStore.put | small_small=3/21504 small_large=1/24576 span_copy_warm=1/393216 span_copy_new=4/1130496 |
| 1.3 | 9 | ListOf(ast.TextRec,0).growTo < ListOf(ast.TextRec,0).push < ast.Ast.add_text | small_small=6/25824 small_large=1/32768 span_copy_warm=1/262144 span_copy_new=1/1048576 |
| 1.2 | 473 | ListOf(ast.FlowRec,0).growTo < ListOf(ast.FlowRec,0).push < binder.Binder.new_flow_node | small_small=456/773120 small_large=9/184320 span_copy_warm=4/327680 |
| 1.1 | 1341 | ListOf(ast.FlowRec,0).growTo < ListOf(ast.FlowRec,0).push < binder.Binder.new_flow_node | small_small=1333/627040 small_large=5/102400 span_copy_warm=3/450560 |
| 1.1 | 16 | String.growList < String.appendBytes < String.addValue | small_small=10/28667 small_large=2/47221 span_copy_warm=2/138390 span_copy_new=1/945805 |
| 1.1 | 61 | rig.ordered.Ordered(i64,i64).reserveOne | small_small=55/98560 small_large=2/65536 span_copy_warm=1/131072 span_copy_new=3/851968 |
| 1.1 | 25809 | rig.ordered.Ordered(u32,u32).insertSmallSlow | small_small=25809/1146792 |
| 1.1 | 10817 | parser.Parser.parse_jsdoc_comment_worker < parser.Parser.parse_jsdoc_comment | small_small=10817/1132128 |
| 1.1 | 37 | ListOf(u64,0).growBy | small_small=31/81920 small_large=2/65536 span_copy_warm=3/458752 span_copy_new=1/524288 |
| 1.1 | 1925 | ListOf(ast.FlowListRec,0).growTo < ListOf(ast.FlowListRec,0).push < binder.Binder.new_flow_list | small_small=1921/881120 small_large=1/32768 span_copy_warm=3/196608 |

(768 callers in all, 108.9 MiB)

### webpack.c4.census (page 16384)

| path | calls | MiB copied | share of bytes |
|---|---:|---:|---:|
| same | 950 | 0.0 | 0.0% |
| small_small | 382710 | 58.7 | 41.0% |
| small_large | 401 | 9.3 | 6.5% |
| shrink_small | 137 | 0.0 | 0.0% |
| span_grow_warm | 66 | 0.0 | 0.0% |
| span_copy_warm | 152 | 17.0 | 11.8% |
| span_grow_fresh | 29 | 0.0 | 0.0% |
| span_copy_new | 273 | 58.4 | 40.7% |
| all | 384718 | 143.4 | |

Bytes copied by block size (MiB; bucket = old size < 2^k):

| size < | small_small | small_large | shrink_small | span_copy_warm | span_copy_new |
|---|---:|---:|---:|---:|---:|
| 2 B | 3 / 0.0 |  |  |  |  |
| 4 B | 2 / 0.0 |  |  |  |  |
| 8 B | 12280 / 0.0 |  |  |  |  |
| 16 B | 12452 / 0.1 |  |  |  |  |
| 32 B | 84354 / 1.3 |  |  |  |  |
| 64 B | 117039 / 4.0 | 7 / 0.0 | 5 / 0.0 |  |  |
| 128 B | 73320 / 4.9 | 10 / 0.0 | 131 / 0.0 |  |  |
| 256 B | 42422 / 5.7 | 26 / 0.0 | 1 / 0.0 |  |  |
| 512 B | 20094 / 5.5 |  |  |  |  |
| 1 KiB | 9272 / 5.0 |  |  |  |  |
| 2 KiB | 5581 / 6.1 |  |  |  |  |
| 4 KiB | 3239 / 7.1 | 1 / 0.0 |  |  |  |
| 8 KiB | 1501 / 6.7 |  |  |  |  |
| 16 KiB | 864 / 7.8 |  |  |  |  |
| 32 KiB | 287 / 4.5 | 205 / 4.5 |  |  |  |
| 64 KiB |  | 152 / 4.8 |  | 52 / 2.3 | 50 / 2.3 |
| 128 KiB |  |  |  | 54 / 3.9 | 79 / 6.0 |
| 256 KiB |  |  |  | 26 / 3.6 | 66 / 10.2 |
| 512 KiB |  |  |  | 14 / 3.8 | 44 / 13.3 |
| 1 MiB |  |  |  | 6 / 3.4 | 24 / 13.5 |
| 2 MiB |  |  |  |  | 9 / 10.9 |
| 4 MiB |  |  |  |  | 1 / 2.2 |
    src steal n=101 copied=12187232
    src cold n=2 copied=245760
    src carve n=170 copied=48810430
    follow copy_warm any n=3 copied=196608
    follow copy_warm cold n=3 copied=196608
    ge copy_warm pages>=4 n=100 copied=15362155 aligned_n=25 aligned_copied=3214880 follow_n=1 follow_copied=98304
    ge copy_warm pages>=16 n=20 copied=7471104 aligned_n=3 aligned_copied=1048576 follow_n=0 follow_copied=0
    ge copy_new pages>=4 n=223 copied=58824148 aligned_n=50 aligned_copied=11985805 follow_n=0 follow_copied=0
    ge copy_new pages>=16 n=78 copied=41864427 aligned_n=17 aligned_copied=8463569 follow_n=0 follow_copied=0
    ge copy_new pages>=64 n=10 copied=13799824 aligned_n=1 aligned_copied=1572864 follow_n=0 follow_copied=0

Top callers by bytes copied (inlined frames, innermost first, runtime frames trimmed):

| MiB | calls | caller | paths (calls/bytes) |
|---:|---:|---|---|
| 20.0 | 153953 | ListOf(ast.Node,0).growBy | small_small=153854/8508312 small_large=28/901120 span_copy_warm=11/1245184 span_copy_new=46/10289152 |
| 13.2 | 268 | rig.ordered.Ordered(checker.CacheKey,checker.TypeList).reserveOne | small_small=204/697728 small_large=17/417792 span_copy_warm=11/835584 span_copy_new=33/11894784 |
| 6.0 | 3370 | ListOf(ast.SymbolRec,0).growTo < ListOf(ast.SymbolRec,0).push < binder.Binder.new_symbol | small_small=3324/3938432 small_large=25/786528 span_copy_warm=8/1078176 span_copy_new=3/454368 |
| 5.0 | 27021 | ListOf(i64,0).growBy | small_small=27004/4636800 small_large=11/360448 span_copy_new=4/262144 |
| 4.9 | 9367 | rig.ordered.Ordered(u32,u32).reserveOne | small_small=9361/4899712 small_large=4/131072 span_copy_warm=2/131072 |
| 4.2 | 4 | ListOf(compiler.ParseTask,0).growTo < ListOf(compiler.ParseTask,0).push < compiler.FileLoader.new_task | span_copy_new=4/4423680 |
| 3.9 | 48 | ListOf(checker.LazyMemberTable,0).growTo < ListOf(checker.LazyMemberTable,0).push < checker.Checker.get_ready_lazy_member_table_worker | small_small=28/113792 small_large=4/114688 span_copy_warm=2/1376256 span_copy_new=14/2523136 |
| 3.8 | 74 | String.growList < String.appendBytes < String.addValue | small_small=44/197528 small_large=3/79739 span_copy_warm=6/445414 span_copy_new=16/3264611 |
| 2.9 | 50 | String.growList < String.appendBytes < String.addValue | small_small=39/48328 small_large=1/23377 span_copy_new=7/2987510 |
| 2.7 | 43 | ListOf(checker.InferenceContext,0).growTo < ListOf(checker.InferenceContext,0).push < checker.Checker.new_inference_context_worker | small_small=24/120960 small_large=4/122880 span_copy_new=13/2580480 |
| 2.1 | 14 | ListOf(ast.NodeRec,0).growTo < ListOf(ast.NodeRec,0).push < ast.Ast.new_node | small_small=8/7424 span_copy_new=6/2162688 |
| 2.0 | 877 | ListOf(compiler.SubRef,0).growTo < ListOf(compiler.SubRef,0).push | small_small=867/1823360 small_large=5/89600 span_copy_new=4/179200 |
| 1.9 | 803 | ListOf(module.ResolvedModule,0).growTo < ListOf(module.ResolvedModule,0).push < module.ModeAwareCache(module.ResolvedModule).push | small_small=795/1809920 small_large=5/102400 span_copy_new=2/81920 |
| 1.9 | 40 | ListOf(ast.TextRec,0).growTo < ListOf(ast.TextRec,0).push < ast.Ast.add_text | small_small=24/73376 small_large=4/131072 span_copy_warm=2/196608 span_copy_new=9/1572864 |
| 1.9 | 47001 | rig.ordered.Ordered(u32,u32).insertSmallSlow | small_small=47001/1967864 |
| 1.4 | 6 | ListOf(rig.runtime.Niche(ast.File,.{ .offset = 752, .Word = u32, .value = 7, .spare = 65536 }),0).growTo < ListOf(rig.runtime.Niche(ast.File,.{ .offset = 752, .Word = u32, .value = 7, .spare = 65536 }),0).push < compiler.FileStore.put | small_large=1/24576 span_copy_warm=1/98304 span_copy_new=3/1376256 |
| 1.3 | 473 | ListOf(ast.FlowRec,0).growTo < ListOf(ast.FlowRec,0).push < binder.Binder.new_flow_node | small_small=456/773120 small_large=9/184320 span_copy_warm=4/368640 span_copy_new=1/81920 |
| 1.3 | 39 | rig.ordered.Ordered(checker.FlowLoopKey,u32).reserveOne | small_small=24/133120 small_large=4/131072 span_copy_new=9/1048576 |
| 1.2 | 600 | rig.ordered.Ordered(u32,checker.InheritanceInfo).reserveOne | small_small=587/823296 small_large=10/245760 span_copy_warm=3/147456 |
| 1.1 | 61 | ListOf(u64,0).growBy | small_small=54/119840 small_large=3/98304 span_copy_new=4/983040 |
| 1.1 | 25 | ListOf(checker.BigTab,0).growTo < ListOf(checker.BigTab,0).push < checker.Checker.new_big_tab | small_small=17/66048 small_large=1/32768 span_copy_warm=3/655360 span_copy_new=4/393216 |
| 1.1 | 10821 | parser.Parser.parse_jsdoc_comment_worker < parser.Parser.parse_jsdoc_comment | small_small=10821/1132608 |
| 1.1 | 48 | ListOf(rig.runtime.ListOf(u32,0),0).growTo < ListOf(rig.runtime.ListOf(u32,0),0).push < checker.Checker.conditional_flow_step | small_small=32/97920 small_large=4/98304 span_copy_warm=2/245760 span_copy_new=5/688128 |
| 1.1 | 1925 | ListOf(ast.FlowListRec,0).growTo < ListOf(ast.FlowListRec,0).push < binder.Binder.new_flow_list | small_small=1921/881120 small_large=1/32768 span_copy_warm=3/196608 |
| 1.0 | 1341 | ListOf(ast.FlowRec,0).growTo < ListOf(ast.FlowRec,0).push < binder.Binder.new_flow_node | small_small=1333/627040 small_large=5/102400 span_copy_warm=2/368640 |

(859 callers in all, 143.4 MiB)
