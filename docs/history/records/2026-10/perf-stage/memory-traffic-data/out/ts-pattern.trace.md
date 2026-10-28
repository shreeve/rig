# out/ts-pattern.trace.1.json (10 runs)

records 6869148; allocated 361.3 MB in 3428532 blocks; peak of live blocks 140.7 MB

## Volume by owner (bytes requested)

| owner | MB | share | blocks | share | avg B |
|---|---:|---:|---:|---:|---:|
| u32 | 52.8 | 14.6% | 1948176 | 56.8% | 27 |
| map entries u32 -> u32 | 28.6 | 7.9% | 234803 | 6.8% | 121 |
| map entries checker.InstantiationKey -> u32 | 22.3 | 6.2% | 14 | 0.0% | 1591577 |
| __rig_std_prelude.Map(u32,u32) | 20.9 | 5.8% | 799 | 0.0% | 26130 |
| map entries checker.CacheKey -> u32 | 19.4 | 5.4% | 332 | 0.0% | 58552 |
| u8 | 19.4 | 5.4% | 361297 | 10.5% | 53 |
| checker.KeyedSym | 18.1 | 5.0% | 65282 | 1.9% | 276 |
| map index checker.CacheKey -> u32 | 15.6 | 4.3% | 3492 | 0.1% | 4465 |
| checker.TableEntry | 14.9 | 4.1% | 123306 | 3.6% | 120 |
| ast.NodeRec | 13.1 | 3.6% | 2269 | 0.1% | 5783 |
| map entries checker.InferenceKey -> i32 | 11.2 | 3.1% | 73711 | 2.1% | 151 |
| map entries u32 -> i64 | 9.4 | 2.6% | 41110 | 1.2% | 229 |
| map index u32 -> u32 | 9.3 | 2.6% | 28013 | 0.8% | 332 |
| checker.SymbolData | 9.2 | 2.5% | 14 | 0.0% | 655344 |
| checker.RecursionId | 7.4 | 2.1% | 98001 | 2.9% | 75 |
| ast.SymbolRec | 7.4 | 2.0% | 981 | 0.0% | 7515 |
| i64 | 7.1 | 2.0% | 72325 | 2.1% | 98 |
| map index checker.InstantiationKey -> u32 | 5.2 | 1.5% | 14 | 0.0% | 374468 |
| untyped | 4.8 | 1.3% | 32734 | 1.0% | 147 |
| checker.ElementInfo | 4.8 | 1.3% | 89363 | 2.6% | 53 |
| map entries checker.CachedTypeKey -> u32 | 4.7 | 1.3% | 16 | 0.0% | 294909 |
| checker.NodeRef | 4.7 | 1.3% | 138897 | 4.1% | 33 |
| checker.InferenceContext | 3.9 | 1.1% | 13 | 0.0% | 302436 |
| checker.InferenceInfo | 3.5 | 1.0% | 13 | 0.0% | 272204 |
| ast.ListRec | 3.4 | 0.9% | 1734 | 0.1% | 1936 |

## Volume by mechanism

| mechanism | MB | share | blocks | share |
|---|---:|---:|---:|---:|
| allocSlice (other) | 106.7 | 29.5% | 2784505 | 81.2% |
| Map entries | 106.4 | 29.4% | 359208 | 10.5% |
| List/String growth | 105.5 | 29.2% | 214771 | 6.3% |
| Map index | 38.0 | 10.5% | 37300 | 1.1% |
| Io.Writer.Allocating.ensureTotalCapacityPrecise | 4.3 | 1.2% | 32555 | 0.9% |
| array_list.Aligned(u8,null).ensureTotalCapacityPrecise | 0.6 | 0.2% | 178 | 0.0% |
| Map gone bits | 0.0 | 0.0% | 11 | 0.0% |
| - | 0.0 | 0.0% | 2 | 0.0% |
| rig.runtime.start | 0.0 | 0.0% | 1 | 0.0% |
| box (create) | 0.0 | 0.0% | 1 | 0.0% |

## Volume by caller

| caller | MB | share | blocks | share |
|---|---:|---:|---:|---:|
| checker.Checker.table_put (checker.zig:2796:67) | 36.7 | 10.1% | 245983 | 7.2% |
| checker.Checker.relation_set (checker.zig:65377:82) | 19.8 | 5.5% | 107 | 0.0% |
| checker.Checker.sort_symbols_by_key (checker.zig:82568:72) | 18.1 | 5.0% | 65282 | 1.9% |
| checker.Checker.new_table (checker.zig:2773:23) | 16.5 | 4.6% | 13 | 0.0% |
| checker.Checker.table_entries (checker.zig:2813:74) | 14.9 | 4.1% | 123306 | 3.6% |
| checker.Checker.get_conditional_type_instantiation_of (checker.zig:48513:43) | 13.9 | 3.8% | 7 | 0.0% |
| ast.Ast.new_node (ast.zig:304:23) | 13.0 | 3.6% | 1218 | 0.0% |
| checker.Checker.invoke_once (checker.zig:37270:29) | 11.3 | 3.1% | 74066 | 2.2% |
| checker.Checker.some_property_reduces_to_never (checker.zig:49765:42) | 11.2 | 3.1% | 45633 | 1.3% |
| checker.Checker.new_symbol (checker.zig:2551:30) | 9.2 | 2.5% | 14 | 0.0% |
| checker.Checker.create_type_reference_ex (checker.zig:5770:39) | 8.6 | 2.4% | 4 | 0.0% |
| checker.Checker.instantiate_type_with_alias (checker.zig:46272:69) | 7.7 | 2.1% | 3631 | 0.1% |
| binder.Binder.new_symbol (binder.zig:210:34) | 7.3 | 2.0% | 637 | 0.0% |
| checker.Checker.get_named_members (checker.zig:41981:32) | 6.0 | 1.7% | 64508 | 1.9% |
| checker.Checker.type_list_items (checker.zig:75628:25) | 5.5 | 1.5% | 293576 | 8.6% |
| checker.Checker.get_permissive_instantiation (checker.zig:48278:37) | 5.3 | 1.5% | 10 | 0.0% |
| checker.Checker.get_named_members (checker.zig:41968:61) | 4.6 | 1.3% | 85754 | 2.5% |
| checker.Checker.set_mapped_symbol_links_key_type (checker.zig:78480:106) | 4.5 | 1.2% | 28 | 0.0% |
| checker.Checker.get_intersection_type_of_set (checker.zig:44088:43) | 4.5 | 1.2% | 26 | 0.0% |
| - | 4.3 | 1.2% | 32786 | 1.0% |
| ast.Binding.get_symbol_table (ast.zig:16734:25) | 4.2 | 1.2% | 441 | 0.0% |
| checker.Checker.new_inference_context_worker (checker.zig:38875:41) | 3.9 | 1.1% | 12 | 0.0% |
| checker.Checker.get_resolved_base_constraint (checker.zig:47489:22) | 3.9 | 1.1% | 56555 | 1.6% |
| checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 3.6 | 1.0% | 11 | 0.0% |
| checker.Checker.context_inferences (checker.zig:38894:30) | 3.6 | 1.0% | 219256 | 6.4% |

## Volume by mechanism, owner, caller

| mechanism | owner | caller | MB | share | blocks |
|---|---:|---:|---:|---:|---:|
| Map entries | map entries u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 27.6 | 7.6% | 218251 |
| allocSlice (other) | checker.KeyedSym | checker.Checker.sort_symbols_by_key (checker.zig:82568:72) | 18.1 | 5.0% | 65282 |
| List/String growth | __rig_std_prelude.Map(u32,u32) | checker.Checker.new_table (checker.zig:2773:23) | 16.5 | 4.6% | 12 |
| allocSlice (other) | checker.TableEntry | checker.Checker.table_entries (checker.zig:2813:74) | 14.9 | 4.1% | 123306 |
| Map entries | map entries checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 13.7 | 3.8% | 61 |
| List/String growth | ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 13.0 | 3.6% | 1218 |
| Map entries | map entries checker.InferenceKey -> i32 | checker.Checker.invoke_once (checker.zig:37270:29) | 11.2 | 3.1% | 73711 |
| Map entries | map entries checker.InstantiationKey -> u32 | checker.Checker.get_conditional_type_instantiation_of (checker.zig:48513:43) | 10.9 | 3.0% | 3 |
| Map entries | map entries u32 -> i64 | checker.Checker.some_property_reduces_to_never (checker.zig:49765:42) | 9.4 | 2.6% | 41091 |
| List/String growth | checker.SymbolData | checker.Checker.new_symbol (checker.zig:2551:30) | 9.2 | 2.5% | 13 |
| Map index | map index u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 9.1 | 2.5% | 27732 |
| Map entries | map entries checker.InstantiationKey -> u32 | checker.Checker.create_type_reference_ex (checker.zig:5770:39) | 7.9 | 2.2% | 2 |
| Map index | map index checker.CacheKey -> u32 | checker.Checker.instantiate_type_with_alias (checker.zig:46272:69) | 7.5 | 2.1% | 3412 |
| List/String growth | ast.SymbolRec | binder.Binder.new_symbol (binder.zig:210:34) | 7.3 | 2.0% | 637 |
| Map index | map index checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 6.1 | 1.7% | 46 |
| List/String growth | i64 | checker.Checker.get_named_members (checker.zig:41981:32) | 5.2 | 1.4% | 38303 |
| allocSlice (other) | u32 | checker.Checker.get_named_members (checker.zig:41968:61) | 4.6 | 1.3% | 85754 |
| allocSlice (other) | u32 | checker.Checker.type_list_items (checker.zig:75628:25) | 4.3 | 1.2% | 270263 |
| Io.Writer.Allocating.ensureTotalCapacityPrecise | untyped | - | 4.3 | 1.2% | 32555 |
| List/String growth | __rig_std_prelude.Map(u32,u32) | ast.Binding.get_symbol_table (ast.zig:16734:25) | 4.2 | 1.2% | 441 |
| List/String growth | checker.InferenceContext | checker.Checker.new_inference_context_worker (checker.zig:38875:41) | 3.9 | 1.1% | 12 |
| allocSlice (other) | u32 | checker.Checker.context_inferences (checker.zig:38894:30) | 3.6 | 1.0% | 219256 |
| allocSlice (other) | u8 | parser.Parser.finish_source_file (parser.zig:941:384) | 3.6 | 1.0% | 173 |
| List/String growth | checker.InferenceInfo | checker.Checker.alloc_inference_info (checker.zig:39476:34) | 3.5 | 1.0% | 12 |
| allocSlice (other) | checker.RecursionId | checker.Checker.get_resolved_base_constraint (checker.zig:47489:22) | 3.3 | 0.9% | 52093 |
| List/String growth | ast.ListRec | ast.Ast.add_list (ast.zig:353:24) | 3.3 | 0.9% | 688 |
| List/String growth | u8 | ast.Ast.add_text (ast.zig:312:28) | 3.2 | 0.9% | 1968 |
| Map entries | map entries u32 -> checker.MappedSymbolLinks | checker.Checker.set_mapped_symbol_links_key_type (checker.zig:78480:106) | 3.1 | 0.9% | 16 |
| Map entries | map entries checker.CacheKey -> u32 | checker.Checker.get_intersection_type_of_set (checker.zig:44088:43) | 3.1 | 0.9% | 14 |
| allocSlice (other) | checker.NodeRef | checker.Checker.add_declaration (checker.zig:2762:78) | 3.1 | 0.9% | 96752 |
| Map entries | map entries checker.CachedTypeKey -> u32 | checker.Checker.get_permissive_instantiation (checker.zig:48278:37) | 3.0 | 0.8% | 5 |
| Map index | map index checker.InstantiationKey -> u32 | checker.Checker.get_conditional_type_instantiation_of (checker.zig:48513:43) | 3.0 | 0.8% | 4 |
| List/String growth | u32 | checker.Checker.sym_list_items (checker.zig:75678:25) | 2.4 | 0.7% | 21680 |
| allocSlice (other) | u32 | checker.Checker.get_named_members (checker.zig:41966:82) | 2.3 | 0.6% | 26205 |
| List/String growth | ast.TextRec | ast.Ast.add_text (ast.zig:311:24) | 2.2 | 0.6% | 1060 |
| Map index | map index checker.CachedTypeKey -> u32 | checker.Checker.get_permissive_instantiation (checker.zig:48278:37) | 2.2 | 0.6% | 5 |
| Map entries | map entries checker.CacheKey -> u32 | checker.Checker.get_union_type_from_sorted_list (checker.zig:4722:36) | 2.1 | 0.6% | 14 |
| List/String growth | u32 | checker.Checker.some_property_reduces_to_never (checker.zig:49781:41) | 2.1 | 0.6% | 23242 |
| allocSlice (other) | checker.ElementInfo | checker.Checker.element_info_list_items (checker.zig:75928:25) | 2.0 | 0.6% | 42206 |
| List/String growth | u32 | ast.Ast.new_identifier (ast.zig:1299:24) | 2.0 | 0.6% | 236 |
| Map entries | map entries checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 2.0 | 0.6% | 4 |
| Map entries | map entries checker.CachedSignatureKey -> u32 | checker.Checker.get_signature_instantiation_without_filling_in_type_arguments (checker.zig:39742:42) | 2.0 | 0.5% | 5 |
| allocSlice (other) | ast.CommentDirective | lexer.Scanner.mark (lexer.zig:2412:117) | 1.9 | 0.5% | 7067 |
| allocSlice (other) | checker.RecursionId | checker.Checker.get_resolved_base_constraint (checker.zig:47486:30) | 1.8 | 0.5% | 28884 |
| Map index | map index u32 -> i64 | checker.Checker.some_property_reduces_to_never (checker.zig:49765:42) | 1.8 | 0.5% | 4542 |
| allocSlice (other) | checker.ElementInfo | checker.Checker.tuple_normalizer_add (checker.zig:45344:21) | 1.7 | 0.5% | 35500 |
| List/String growth | checker.RecursionId | checker.Checker.get_resolved_base_constraint (checker.zig:47486:30) | 1.6 | 0.5% | 12562 |
| Map entries | map entries checker.CachedTypeKey -> u32 | checker.Checker.get_restrictive_instantiation (checker.zig:48292:37) | 1.6 | 0.5% | 4 |
| allocSlice (other) | u8 | tspath.RootedFilePath.as_path (tspath.zig:3204:53) | 1.6 | 0.5% | 29566 |
| Map index | map index checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 1.6 | 0.5% | 7 |

## Blocks by mechanism, owner, caller

| mechanism | owner | caller | blocks | share | MB |
|---|---:|---:|---:|---:|---:|
| allocSlice (other) | u32 | checker.Checker.type_list_items (checker.zig:75628:25) | 270263 | 7.9% | 4.3 |
| allocSlice (other) | u32 | checker.Checker.context_inferences (checker.zig:38894:30) | 219256 | 6.4% | 3.6 |
| Map entries | map entries u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 218251 | 6.4% | 27.6 |
| allocSlice (other) | checker.TableEntry | checker.Checker.table_entries (checker.zig:2813:74) | 123306 | 3.6% | 14.9 |
| allocSlice (other) | u32 | checker.Checker.add_mapped_members_for_key_type (checker.zig:50553:22) | 96910 | 2.8% | 1.6 |
| allocSlice (other) | checker.NodeRef | checker.Checker.add_declaration (checker.zig:2762:78) | 96752 | 2.8% | 3.1 |
| allocSlice (other) | u32 | checker.Checker.get_named_members (checker.zig:41968:61) | 85754 | 2.5% | 4.6 |
| allocSlice (other) | u32 | checker.Checker.infer_from_types (checker.zig:37036:89) | 84290 | 2.5% | 1.3 |
| allocSlice (other) | u32 | checker.Checker.infer_types (checker.zig:36861:34) | 81541 | 2.4% | 1.3 |
| allocSlice (other) | u32 | checker.Checker.new_inference_context (checker.zig:38806:32) | 80541 | 2.3% | 1.3 |
| Map entries | map entries checker.InferenceKey -> i32 | checker.Checker.invoke_once (checker.zig:37270:29) | 73711 | 2.1% | 11.2 |
| allocSlice (other) | u32 | checker.Checker.get_type_from_inference (checker.zig:39256:44) | 68878 | 2.0% | 1.1 |
| allocSlice (other) | u8 | ast.Ast.get_property_name_for_property_name_node (ast.zig:13373:37) | 68766 | 2.0% | 1.1 |
| allocSlice (other) | u32 | checker.Checker.invoke_once (checker.zig:37274:28) | 68612 | 2.0% | 1.1 |
| allocSlice (other) | u32 | checker.Checker.invoke_once (checker.zig:37275:28) | 68612 | 2.0% | 1.1 |
| allocSlice (other) | u32 | checker.Checker.get_cross_product_intersections (checker.zig:44435:38) | 68062 | 2.0% | 1.1 |
| allocSlice (other) | checker.KeyedSym | checker.Checker.sort_symbols_by_key (checker.zig:82568:72) | 65282 | 1.9% | 18.1 |
| allocSlice (other) | checker.RecursionId | checker.Checker.get_resolved_base_constraint (checker.zig:47489:22) | 52093 | 1.5% | 3.3 |
| allocSlice (other) | u32 | checker.Checker.sym_list_items (checker.zig:75678:25) | 46101 | 1.3% | 0.7 |
| allocSlice (other) | checker.ElementInfo | checker.Checker.element_info_list_items (checker.zig:75928:25) | 42206 | 1.2% | 2.0 |
| Map entries | map entries u32 -> i64 | checker.Checker.some_property_reduces_to_never (checker.zig:49765:42) | 41091 | 1.2% | 9.4 |
| List/String growth | i64 | checker.Checker.get_named_members (checker.zig:41981:32) | 38303 | 1.1% | 5.2 |
| allocSlice (other) | u32 | checker.Checker.create_normalized_tuple_type_ex (checker.zig:45181:26) | 37093 | 1.1% | 0.6 |
| allocSlice (other) | u32 | checker.Checker.tuple_normalizer_add (checker.zig:45343:21) | 35500 | 1.0% | 0.6 |
| allocSlice (other) | checker.ElementInfo | checker.Checker.tuple_normalizer_add (checker.zig:45344:21) | 35500 | 1.0% | 1.7 |
| Io.Writer.Allocating.ensureTotalCapacityPrecise | untyped | - | 32555 | 0.9% | 4.3 |
| allocSlice (other) | u8 | tspath.RootedFilePath.as_path (tspath.zig:3204:53) | 29566 | 0.9% | 1.6 |
| allocSlice (other) | u8 | checker.Checker.is_known_property (checker.zig:67053:55) | 29526 | 0.9% | 0.5 |
| allocSlice (other) | checker.RecursionId | checker.Checker.get_resolved_base_constraint (checker.zig:47486:30) | 28884 | 0.8% | 1.8 |
| allocSlice (other) | u8 | tspath.CaseSensitivity.canonicalize (tspath.zig:2188:33) | 28124 | 0.8% | 1.5 |
| Map index | map index u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 27732 | 0.8% | 9.1 |
| allocSlice (other) | u32 | checker.Checker.find_applicable_index_info (checker.zig:48631:42) | 27698 | 0.8% | 0.4 |
| allocSlice (other) | u8 | compiler.Program.path_key_of (compiler.zig:3127:507) | 27437 | 0.8% | 1.5 |
| allocSlice (other) | u32 | checker.Checker.create_union_or_intersection_property (checker.zig:50089:32) | 26978 | 0.8% | 0.4 |
| allocSlice (other) | u32 | checker.Checker.get_named_members (checker.zig:41966:82) | 26205 | 0.8% | 2.3 |
| allocSlice (other) | i64 | checker.Checker.get_named_members (checker.zig:41981:32) | 26205 | 0.8% | 0.8 |
| allocSlice (other) | checker.NodeRef | checker.Checker.create_union_or_intersection_property (checker.zig:50060:46) | 26102 | 0.8% | 0.8 |
| allocSlice (other) | u32 | checker.Checker.get_optional_type (checker.zig:12479:19) | 25549 | 0.7% | 0.4 |
| allocSlice (other) | u32 | checker.Checker.create_union_or_intersection_property (checker.zig:49924:50) | 24493 | 0.7% | 0.4 |
| allocSlice (other) | u32 | checker.Checker.get_type_parameters_for_mapper (checker.zig:39773:28) | 24270 | 0.7% | 0.4 |
| List/String growth | u32 | checker.Checker.type_list_items (checker.zig:75628:25) | 23313 | 0.7% | 1.2 |
| List/String growth | u32 | checker.Checker.some_property_reduces_to_never (checker.zig:49781:41) | 23242 | 0.7% | 2.1 |
| List/String growth | u32 | checker.Checker.sym_list_items (checker.zig:75678:25) | 21680 | 0.6% | 2.4 |
| allocSlice (other) | u8 | checker.Checker.get_type_from_index_infos_of_contextual_type (checker.zig:9666:38) | 19524 | 0.6% | 0.3 |
| allocSlice (other) | u32 | checker.Checker.get_conditional_flow_type_of_type (checker.zig:6439:45) | 19470 | 0.6% | 0.3 |
| allocSlice (other) | u32 | checker.Checker.some_property_reduces_to_never (checker.zig:49781:41) | 17849 | 0.5% | 0.3 |
| allocSlice (other) | bool | checker.Checker.some_property_reduces_to_never (checker.zig:49782:42) | 17849 | 0.5% | 0.1 |
| allocSlice (other) | u8 | tspath.split (tspath.zig:1080:47) | 16888 | 0.5% | 0.3 |
| allocSlice (other) | u32 | checker.Checker.compute_base_constraint (checker.zig:47546:41) | 16695 | 0.5% | 0.3 |
| allocSlice (other) | u32 | checker.Checker.get_covariant_inference (checker.zig:39107:47) | 16390 | 0.5% | 0.3 |

## Bytes copied by growth that moved a block (reallocSlice)

| owner | caller | MB | moves |
|---|---:|---:|---:|
| i64 | checker.Checker.get_named_members (checker.zig:41981:32) | 2.6 | 38303 |
| map entries u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 2.5 | 9559 |
| map entries u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 1.8 | 14353 |
| ast.SymbolRec | binder.Binder.new_symbol (binder.zig:210:34) | 1.6 | 148 |
| map entries u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 1.6 | 6120 |
| map entries u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 1.4 | 29430 |
| checker.SymbolData | checker.Checker.new_symbol (checker.zig:2551:30) | 1.4 | 2 |
| map entries u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 1.3 | 10166 |
| map entries u32 -> checker.MappedSymbolLinks | checker.Checker.set_mapped_symbol_links_key_type (checker.zig:78480:106) | 1.0 | 6 |
| map entries checker.CachedSignatureKey -> u32 | checker.Checker.get_signature_instantiation_without_filling_in_type_arguments (checker.zig:39742:42) | 1.0 | 2 |
| checker.InferenceContext | checker.Checker.new_inference_context_worker (checker.zig:38875:41) | 1.0 | 1 |
| map entries u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 1.0 | 19767 |
| __rig_std_prelude.Map(u32,u32) | checker.Checker.new_table (checker.zig:2773:23) | 0.9 | 1 |
| u32 | ast.Ast.new_identifier (ast.zig:1299:24) | 0.8 | 48 |
| map entries checker.InferenceKey -> i32 | checker.Checker.invoke_once (checker.zig:37270:29) | 0.8 | 4672 |
| __rig_std_prelude.Map(u32,u32) | ast.Binding.get_symbol_table (ast.zig:16734:25) | 0.8 | 171 |
| checker.InferenceInfo | checker.Checker.alloc_inference_info (checker.zig:39476:34) | 0.8 | 9 |
| ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 0.8 | 1 |
| map entries checker.CachedTypeKey -> u32 | checker.Checker.get_restrictive_instantiation (checker.zig:48292:37) | 0.8 | 1 |
| map entries checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 0.8 | 4 |
| map entries checker.CachedTypeKey -> u32 | checker.Checker.get_permissive_instantiation (checker.zig:48278:37) | 0.7 | 4 |
| checker.InferenceContext | checker.Checker.new_inference_context_worker (checker.zig:38875:41) | 0.7 | 10 |
| checker.NodeRef | checker.Checker.add_declaration (checker.zig:2762:78) | 0.7 | 44055 |
| map entries checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 0.7 | 3 |
| map entries checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 0.7 | 1 |

copied in all: 66.6 MB

# cpu_core/ld_blocks.store_forward,period=1301/upp: 10538 samples

## cpu_core/ld_blocks.store_forward,period=1301/upp by region

| region | samples | share |
|---|---:|---:|
| unmapped | 10532 | 99.9% |
| large | 4 | 0.0% |
| small | 1 | 0.0% |
| file bin | 1 | 0.0% |

## cpu_core/ld_blocks.store_forward,period=1301/upp by owner

| owner | samples | share |
|---|---:|---:|
| (unmapped) | 10532 | 99.9% |
| map index checker.CacheKey -> u32 | 3 | 0.0% |
| map entries checker.InstantiationKey -> u32 | 1 | 0.0% |
| checker.Relater | 1 | 0.0% |
| (binary data) | 1 | 0.0% |

## cpu_core/ld_blocks.store_forward,period=1301/upp by owner and allocating caller

| owner | caller | samples | share |
|---|---:|---:|---:|
| (unmapped) | - | 10532 | 99.9% |
| map index checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 3 | 0.0% |
| map entries checker.InstantiationKey -> u32 | checker.Checker.get_conditional_type_instantiation_of (checker.zig:48513:43) | 1 | 0.0% |
| checker.Relater | checker.Checker.put_relater (checker.zig:67880:32) | 1 | 0.0% |
| (binary data) | - | 1 | 0.0% |

## cpu_core/ld_blocks.store_forward,period=1301/upp by kind of block

| kind | samples | share |
|---|---:|---:|
| unmapped | 10532 | 99.9% |
| Map index | 3 | 0.0% |
| Map entries | 1 | 0.0% |
| allocSlice (other) | 1 | 0.0% |
| file bin | 1 | 0.0% |

## cpu_core/ld_blocks.store_forward,period=1301/upp by sampled function (innermost inlined frame)

| function | samples | share |
|---|---:|---:|
| rig.runtime.Niche(checker.Relater,.{ .offset = 89, .Word = u8, .value = 2, .spare = 254 }).unwrap (runtime.zig) | 489 | 4.6% |
| checker.Checker.get_relater (checker.zig) | 445 | 4.2% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll (ordered.zig) | 396 | 3.8% |
| mem.swap__func_4160 (mem.zig) | 336 | 3.2% |
| checker.Checker.get_type_from_type_node_worker (checker.zig) | 296 | 2.8% |
| checker.Checker.is_simple_type_related_to_ex (checker.zig) | 256 | 2.4% |
| compiler_rt.memcpy.copyBlocks (memcpy.zig) | 245 | 2.3% |
| rig.ordered.Ordered(checker.CacheKey,u32).findIndexed (ordered.zig) | 211 | 2.0% |
| checker.Checker.mapper_map (checker.zig) | 185 | 1.8% |
| ast.Ast.is_tuple_type_node (ast.zig) | 162 | 1.5% |
| atomic.Value(usize).fetchAdd (atomic.zig) | 158 | 1.5% |
| rig.runtime.ListOf(checker.Relater,0).pop (runtime.zig) | 143 | 1.4% |
| checker.Checker.is_type_related_to (checker.zig) | 143 | 1.4% |
| checker.Checker.instantiate_type_with_alias (checker.zig) | 142 | 1.3% |
| checker.is_unary_tuple_type_node (checker.zig) | 126 | 1.2% |
| rig.table.Table(checker.Type,134217728).constSlot (table.zig) | 111 | 1.1% |
| rig.table.Table(u32,268435456).push (table.zig) | 95 | 0.9% |
| checker.Checker.get_conditional_type_instantiation_of (checker.zig) | 93 | 0.9% |
| checker.Checker.instantiate_types (checker.zig) | 93 | 0.9% |
| rig.table.Table(checker.Type,134217728).at (table.zig) | 92 | 0.9% |
| checker.Checker.get_object_type_instantiation (checker.zig) | 90 | 0.9% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll (ordered.zig) | 80 | 0.8% |
| checker.Checker.get_relation_key (checker.zig) | 75 | 0.7% |
| checker.Checker.is_unknown_like_union_type (checker.zig) | 75 | 0.7% |
| checker.Checker.new_type_list (checker.zig) | 73 | 0.7% |

# cpu_core/mem_load_retired.l2_miss,period=307/upp: 10521 samples

## cpu_core/mem_load_retired.l2_miss,period=307/upp by region

| region | samples | share |
|---|---:|---:|
| large | 5423 | 51.5% |
| table | 2783 | 26.5% |
| small | 1638 | 15.6% |
| file bin | 430 | 4.1% |
| anon | 159 | 1.5% |
| freed | 70 | 0.7% |
| unmapped | 18 | 0.2% |

## cpu_core/mem_load_retired.l2_miss,period=307/upp by owner

| owner | samples | share |
|---|---:|---:|
| map index checker.InstantiationKey -> u32 | 1375 | 13.1% |
| map index checker.CacheKey -> u32 | 985 | 9.4% |
| ast.NodeRec | 688 | 6.5% |
| table checker.Type | 566 | 5.4% |
| u32 | 534 | 5.1% |
| map index checker.CachedTypeKey -> u32 | 472 | 4.5% |
| table u32 | 442 | 4.2% |
| (binary data) | 430 | 4.1% |
| ast.SymbolRec | 315 | 3.0% |
| map entries checker.InstantiationKey -> u32 | 315 | 3.0% |
| table checker.StructuredType | 291 | 2.8% |
| map index u32 -> checker.MappedSymbolLinks | 232 | 2.2% |
| table checker.ValueSymbolLinks | 226 | 2.1% |
| map entries checker.CacheKey -> u32 | 220 | 2.1% |
| table checker.TypeNodeLinks | 211 | 2.0% |
| __rig_std_prelude.Map(u32,u32) | 207 | 2.0% |
| u8 | 202 | 1.9% |
| (anon mapping) | 159 | 1.5% |
| table checker.TypeMapper | 152 | 1.4% |
| checker.Loc | 137 | 1.3% |
| map entries checker.CachedTypeKey -> u32 | 135 | 1.3% |
| table checker.ConditionalType | 131 | 1.2% |
| table checker.TypeReference | 111 | 1.1% |
| map entries u32 -> u32 | 110 | 1.0% |
| table checker.UnionOrIntersectionType | 106 | 1.0% |

## cpu_core/mem_load_retired.l2_miss,period=307/upp by owner and allocating caller

| owner | caller | samples | share |
|---|---:|---:|---:|
| map index checker.InstantiationKey -> u32 | checker.Checker.get_conditional_type_instantiation_of (checker.zig:48513:43) | 852 | 8.1% |
| map index checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 760 | 7.2% |
| ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 687 | 6.5% |
| table checker.Type | - | 566 | 5.4% |
| table u32 | - | 442 | 4.2% |
| (binary data) | - | 430 | 4.1% |
| map index checker.CachedTypeKey -> u32 | checker.Checker.get_permissive_instantiation (checker.zig:48278:37) | 383 | 3.6% |
| map index checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 373 | 3.5% |
| ast.SymbolRec | binder.Binder.new_symbol (binder.zig:210:34) | 312 | 3.0% |
| table checker.StructuredType | - | 291 | 2.8% |
| map index u32 -> checker.MappedSymbolLinks | checker.Checker.set_mapped_symbol_links_key_type (checker.zig:78480:106) | 232 | 2.2% |
| table checker.ValueSymbolLinks | - | 226 | 2.1% |
| table checker.TypeNodeLinks | - | 211 | 2.0% |
| map entries checker.InstantiationKey -> u32 | checker.Checker.create_type_reference_ex (checker.zig:5770:39) | 161 | 1.5% |
| __rig_std_prelude.Map(u32,u32) | checker.Checker.new_table (checker.zig:2773:23) | 160 | 1.5% |
| (anon mapping) | - | 159 | 1.5% |
| map entries checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 158 | 1.5% |
| table checker.TypeMapper | - | 152 | 1.4% |
| map index checker.InstantiationKey -> u32 | checker.Checker.create_type_reference_ex (checker.zig:5770:39) | 150 | 1.4% |
| u8 | binder.Binder.declare_symbol_ex (binder.zig:234:65) | 131 | 1.2% |
| table checker.ConditionalType | - | 131 | 1.2% |
| map index checker.CacheKey -> u32 | checker.Checker.get_intersection_type_of_set (checker.zig:44088:43) | 127 | 1.2% |
| u32 | binder.Binder.declare_symbol_ex (binder.zig:234:65) | 124 | 1.2% |
| checker.Loc | checker.Ids.of (checker.zig:90983:41) | 122 | 1.2% |
| map entries checker.InstantiationKey -> u32 | checker.Checker.get_conditional_type_instantiation_of (checker.zig:48513:43) | 112 | 1.1% |

## cpu_core/mem_load_retired.l2_miss,period=307/upp by kind of block

| kind | samples | share |
|---|---:|---:|
| Map index | 3361 | 31.9% |
| table | 2783 | 26.5% |
| List/String growth | 2431 | 23.1% |
| Map entries | 955 | 9.1% |
| file bin | 430 | 4.1% |
| allocSlice (other) | 313 | 3.0% |
| anon | 159 | 1.5% |
| freed | 70 | 0.7% |
| unmapped | 18 | 0.2% |
| array_list.Aligned(u8,null).ensureTotalCapacityPrecise | 1 | 0.0% |

## cpu_core/mem_load_retired.l2_miss,period=307/upp by sampled function (innermost inlined frame)

| function | samples | share |
|---|---:|---:|
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll (ordered.zig) | 1330 | 12.6% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll (ordered.zig) | 964 | 9.2% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll (ordered.zig) | 460 | 4.4% |
| rig.table.Table(u32,268435456).at (table.zig) | 418 | 4.0% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1199 (runtime.zig) | 392 | 3.7% |
| compiler_rt.memcpy.copyBlocks (memcpy.zig) | 256 | 2.4% |
| rig.runtime.ListOf(u32,0).at__func_1294 (runtime.zig) | 254 | 2.4% |
| rig.ordered.Ordered(u32,checker.MappedSymbolLinks).matchAll (ordered.zig) | 232 | 2.2% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch (ordered.zig) | 198 | 1.9% |
| checker.Checker.could_contain_type_variables (checker.zig) | 196 | 1.9% |
| rig.table.Table(checker.Type,134217728).at (table.zig) | 179 | 1.7% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at (table.zig) | 176 | 1.7% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch (ordered.zig) | 159 | 1.5% |
| rig.table.Table(checker.TypeMapper,16777216).at (table.zig) | 151 | 1.4% |
| rig.runtime.ListOf(checker.Loc,0).at__func_4079 (runtime.zig) | 137 | 1.3% |
| rig.table.Table(checker.ConditionalType,67108864).at (table.zig) | 131 | 1.2% |
| rig.ordered.Ordered(u32,u32).matchAll (ordered.zig) | 122 | 1.2% |
| rig.ordered.Ordered(u32,u32).findHashed (ordered.zig) | 115 | 1.1% |
| ast.Ast.is_parenthesized_type_node (ast.zig) | 114 | 1.1% |
| rig.table.Table(checker.StructuredType,67108864).at (table.zig) | 114 | 1.1% |
| checker.Checker.type_target (checker.zig) | 111 | 1.1% |
| rig.runtime.ListOf(u32,0).atProven (runtime.zig) | 110 | 1.0% |
| checker.Checker.symbol_flags (checker.zig) | 110 | 1.0% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).eqlKey (ordered.zig) | 104 | 1.0% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at (table.zig) | 97 | 0.9% |

# cpu_core/mem_load_retired.l3_miss,period=97/upp: 10457 samples

## cpu_core/mem_load_retired.l3_miss,period=97/upp by region

| region | samples | share |
|---|---:|---:|
| large | 6015 | 57.5% |
| table | 2655 | 25.4% |
| small | 1420 | 13.6% |
| file bin | 309 | 3.0% |
| anon | 34 | 0.3% |
| freed | 22 | 0.2% |
| unmapped | 2 | 0.0% |

## cpu_core/mem_load_retired.l3_miss,period=97/upp by owner

| owner | samples | share |
|---|---:|---:|
| map index checker.InstantiationKey -> u32 | 1438 | 13.8% |
| map index checker.CacheKey -> u32 | 1154 | 11.0% |
| ast.NodeRec | 638 | 6.1% |
| map entries checker.InstantiationKey -> u32 | 537 | 5.1% |
| u32 | 501 | 4.8% |
| table checker.Type | 485 | 4.6% |
| map index checker.CachedTypeKey -> u32 | 445 | 4.3% |
| table u32 | 409 | 3.9% |
| map entries checker.CacheKey -> u32 | 380 | 3.6% |
| table checker.StructuredType | 314 | 3.0% |
| (binary data) | 309 | 3.0% |
| ast.SymbolRec | 290 | 2.8% |
| map index u32 -> checker.MappedSymbolLinks | 285 | 2.7% |
| __rig_std_prelude.Map(u32,u32) | 226 | 2.2% |
| table checker.TypeNodeLinks | 219 | 2.1% |
| u8 | 196 | 1.9% |
| table checker.ValueSymbolLinks | 190 | 1.8% |
| map entries checker.CachedTypeKey -> u32 | 182 | 1.7% |
| table checker.TypeMapper | 158 | 1.5% |
| table checker.ConditionalType | 124 | 1.2% |
| table checker.CheckerSymbol | 120 | 1.1% |
| table checker.TypeReference | 114 | 1.1% |
| checker.SymbolData | 108 | 1.0% |
| table checker.UnionOrIntersectionType | 105 | 1.0% |
| map entries u32 -> u32 | 105 | 1.0% |

## cpu_core/mem_load_retired.l3_miss,period=97/upp by owner and allocating caller

| owner | caller | samples | share |
|---|---:|---:|---:|
| map index checker.InstantiationKey -> u32 | checker.Checker.get_conditional_type_instantiation_of (checker.zig:48513:43) | 1046 | 10.0% |
| map index checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 900 | 8.6% |
| ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 638 | 6.1% |
| table checker.Type | - | 485 | 4.6% |
| table u32 | - | 409 | 3.9% |
| map index checker.CachedTypeKey -> u32 | checker.Checker.get_permissive_instantiation (checker.zig:48278:37) | 396 | 3.8% |
| map index checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 333 | 3.2% |
| table checker.StructuredType | - | 314 | 3.0% |
| (binary data) | - | 309 | 3.0% |
| map entries checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 286 | 2.7% |
| map entries checker.InstantiationKey -> u32 | checker.Checker.create_type_reference_ex (checker.zig:5770:39) | 286 | 2.7% |
| map index u32 -> checker.MappedSymbolLinks | checker.Checker.set_mapped_symbol_links_key_type (checker.zig:78480:106) | 285 | 2.7% |
| ast.SymbolRec | binder.Binder.new_symbol (binder.zig:210:34) | 281 | 2.7% |
| table checker.TypeNodeLinks | - | 219 | 2.1% |
| table checker.ValueSymbolLinks | - | 190 | 1.8% |
| map entries checker.InstantiationKey -> u32 | checker.Checker.get_conditional_type_instantiation_of (checker.zig:48513:43) | 183 | 1.8% |
| __rig_std_prelude.Map(u32,u32) | checker.Checker.new_table (checker.zig:2773:23) | 172 | 1.6% |
| map index checker.CacheKey -> u32 | checker.Checker.get_intersection_type_of_set (checker.zig:44088:43) | 161 | 1.5% |
| table checker.TypeMapper | - | 158 | 1.5% |
| table checker.ConditionalType | - | 124 | 1.2% |
| table checker.CheckerSymbol | - | 120 | 1.1% |
| table checker.TypeReference | - | 114 | 1.1% |
| u8 | binder.Binder.declare_symbol_ex (binder.zig:234:65) | 112 | 1.1% |
| checker.SymbolData | checker.Checker.new_symbol (checker.zig:2551:30) | 108 | 1.0% |
| table checker.UnionOrIntersectionType | - | 105 | 1.0% |

## cpu_core/mem_load_retired.l3_miss,period=97/upp by kind of block

| kind | samples | share |
|---|---:|---:|
| Map index | 3529 | 33.7% |
| table | 2655 | 25.4% |
| List/String growth | 2210 | 21.1% |
| Map entries | 1405 | 13.4% |
| file bin | 309 | 3.0% |
| allocSlice (other) | 289 | 2.8% |
| anon | 34 | 0.3% |
| freed | 22 | 0.2% |
| array_list.Aligned(u8,null).ensureTotalCapacityPrecise | 2 | 0.0% |
| unmapped | 2 | 0.0% |

## cpu_core/mem_load_retired.l3_miss,period=97/upp by sampled function (innermost inlined frame)

| function | samples | share |
|---|---:|---:|
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll (ordered.zig) | 1390 | 13.3% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll (ordered.zig) | 1115 | 10.7% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll (ordered.zig) | 432 | 4.1% |
| rig.table.Table(u32,268435456).at (table.zig) | 375 | 3.6% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch (ordered.zig) | 364 | 3.5% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1199 (runtime.zig) | 362 | 3.5% |
| compiler_rt.memcpy.copyBlocks (memcpy.zig) | 329 | 3.1% |
| rig.ordered.Ordered(u32,checker.MappedSymbolLinks).matchAll (ordered.zig) | 280 | 2.7% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch (ordered.zig) | 274 | 2.6% |
| rig.runtime.ListOf(u32,0).at__func_1294 (runtime.zig) | 272 | 2.6% |
| rig.table.Table(checker.Type,134217728).at (table.zig) | 174 | 1.7% |
| rig.table.Table(checker.TypeMapper,16777216).at (table.zig) | 158 | 1.5% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at (table.zig) | 150 | 1.4% |
| checker.Checker.could_contain_type_variables (checker.zig) | 139 | 1.3% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).eqlKey (ordered.zig) | 135 | 1.3% |
| rig.table.Table(checker.ConditionalType,67108864).at (table.zig) | 124 | 1.2% |
| rig.ordered.Ordered(u32,u32).matchAll (ordered.zig) | 115 | 1.1% |
| ast.Ast.is_parenthesized_type_node (ast.zig) | 115 | 1.1% |
| checker.Checker.type_target (checker.zig) | 110 | 1.1% |
| rig.table.Table(checker.StructuredType,67108864).at (table.zig) | 105 | 1.0% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at (table.zig) | 105 | 1.0% |
| rig.runtime.ListOf(u32,0).atProven (runtime.zig) | 100 | 1.0% |
| rig.ordered.Ordered(u32,u32).findHashed (ordered.zig) | 100 | 1.0% |
| rig.runtime.ListOf(checker.Loc,0).at__func_4079 (runtime.zig) | 90 | 0.9% |
| checker.Checker.symbol_flags (checker.zig) | 83 | 0.8% |

# cpu_core/mem_load_retired.l1_miss,period=4001/upp: 10618 samples

## cpu_core/mem_load_retired.l1_miss,period=4001/upp by region

| region | samples | share |
|---|---:|---:|
| large | 3626 | 34.1% |
| table | 3570 | 33.6% |
| small | 1639 | 15.4% |
| anon | 889 | 8.4% |
| file bin | 704 | 6.6% |
| freed | 177 | 1.7% |
| unmapped | 12 | 0.1% |
| stack | 1 | 0.0% |

## cpu_core/mem_load_retired.l1_miss,period=4001/upp by owner

| owner | samples | share |
|---|---:|---:|
| table checker.Type | 1022 | 9.6% |
| (anon mapping) | 889 | 8.4% |
| ast.NodeRec | 763 | 7.2% |
| (binary data) | 704 | 6.6% |
| u32 | 573 | 5.4% |
| checker.Checker | 484 | 4.6% |
| ast.SymbolRec | 460 | 4.3% |
| table u32 | 456 | 4.3% |
| map index checker.InstantiationKey -> u32 | 362 | 3.4% |
| table checker.ValueSymbolLinks | 340 | 3.2% |
| table checker.StructuredType | 320 | 3.0% |
| checker.Loc | 281 | 2.6% |
| map index checker.CacheKey -> u32 | 261 | 2.5% |
| u8 | 211 | 2.0% |
| table checker.TypeParameter | 198 | 1.9% |
| table checker.TypeNodeLinks | 185 | 1.7% |
| (freed block) | 177 | 1.7% |
| map index checker.CachedTypeKey -> u32 | 176 | 1.7% |
| map entries checker.InstantiationKey -> u32 | 146 | 1.4% |
| ast.File | 143 | 1.3% |
| table checker.TypeMapper | 136 | 1.3% |
| table checker.TypeReference | 135 | 1.3% |
| __rig_std_prelude.Map(u32,u32) | 126 | 1.2% |
| table checker.ConditionalType | 117 | 1.1% |
| table checker.CheckerSymbol | 115 | 1.1% |

## cpu_core/mem_load_retired.l1_miss,period=4001/upp by owner and allocating caller

| owner | caller | samples | share |
|---|---:|---:|---:|
| table checker.Type | - | 1022 | 9.6% |
| (anon mapping) | - | 889 | 8.4% |
| ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 763 | 7.2% |
| (binary data) | - | 704 | 6.6% |
| checker.Checker | declarations.new_checker_pool (declarations.zig:285:26) | 484 | 4.6% |
| ast.SymbolRec | binder.Binder.new_symbol (binder.zig:210:34) | 459 | 4.3% |
| table u32 | - | 456 | 4.3% |
| table checker.ValueSymbolLinks | - | 340 | 3.2% |
| table checker.StructuredType | - | 320 | 3.0% |
| checker.Loc | checker.Ids.of (checker.zig:90983:41) | 254 | 2.4% |
| map index checker.InstantiationKey -> u32 | checker.Checker.get_conditional_type_instantiation_of (checker.zig:48513:43) | 204 | 1.9% |
| table checker.TypeParameter | - | 198 | 1.9% |
| map index checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 194 | 1.8% |
| table checker.TypeNodeLinks | - | 185 | 1.7% |
| (freed block) | - | 177 | 1.7% |
| u32 | binder.Binder.declare_symbol_ex (binder.zig:234:65) | 168 | 1.6% |
| u8 | binder.Binder.declare_symbol_ex (binder.zig:234:65) | 149 | 1.4% |
| ast.File | compiler.new_program (compiler.zig:4737:23) | 143 | 1.3% |
| map index checker.CachedTypeKey -> u32 | checker.Checker.get_permissive_instantiation (checker.zig:48278:37) | 141 | 1.3% |
| table checker.TypeMapper | - | 136 | 1.3% |
| table checker.TypeReference | - | 135 | 1.3% |
| table checker.ConditionalType | - | 117 | 1.1% |
| map index checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 115 | 1.1% |
| table checker.CheckerSymbol | - | 115 | 1.1% |
| ast.Binding | compiler.new_program (compiler.zig:4736:26) | 104 | 1.0% |

## cpu_core/mem_load_retired.l1_miss,period=4001/upp by kind of block

| kind | samples | share |
|---|---:|---:|
| table | 3570 | 33.6% |
| List/String growth | 3001 | 28.3% |
| Map index | 1049 | 9.9% |
| anon | 889 | 8.4% |
| allocSlice (other) | 708 | 6.7% |
| file bin | 704 | 6.6% |
| Map entries | 506 | 4.8% |
| freed | 177 | 1.7% |
| unmapped | 12 | 0.1% |
| array_list.Aligned(u8,null).ensureTotalCapacityPrecise | 1 | 0.0% |
| stack | 1 | 0.0% |

## cpu_core/mem_load_retired.l1_miss,period=4001/upp by sampled function (innermost inlined frame)

| function | samples | share |
|---|---:|---:|
| rig.table.Table(checker.Type,134217728).at (table.zig) | 405 | 3.8% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1199 (runtime.zig) | 395 | 3.7% |
| rig.table.Table(u32,268435456).at (table.zig) | 392 | 3.7% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll (ordered.zig) | 333 | 3.1% |
| checker.Checker.could_contain_type_variables (checker.zig) | 305 | 2.9% |
| rig.runtime.ListOf(checker.Loc,0).at__func_4079 (runtime.zig) | 280 | 2.6% |
| rig.runtime.ListOf(u32,0).at__func_1294 (runtime.zig) | 259 | 2.4% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at (table.zig) | 253 | 2.4% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll (ordered.zig) | 251 | 2.4% |
| rig.alloc.alloc (alloc.zig) | 229 | 2.2% |
| compiler_rt.memcpy.copyBlocks (memcpy.zig) | 189 | 1.8% |
| checker.Checker.get_non_distributed_type_parameter (checker.zig) | 185 | 1.7% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll (ordered.zig) | 173 | 1.6% |
| rig.alloc.free (alloc.zig) | 159 | 1.5% |
| rig.table.Table(checker.StructuredType,67108864).at (table.zig) | 152 | 1.4% |
| checker.Checker.symbol_flags (checker.zig) | 149 | 1.4% |
| checker.Checker.symbol_value_declaration (checker.zig) | 142 | 1.3% |
| rig.table.Table(checker.TypeMapper,16777216).at (table.zig) | 136 | 1.3% |
| rig.table.Table(checker.ConditionalType,67108864).at (table.zig) | 117 | 1.1% |
| checker.Checker.is_declaration_contained_in (checker.zig) | 117 | 1.1% |
| rig.runtime.ListOf(u32,0).atProven (runtime.zig) | 112 | 1.1% |
| rig.runtime.index__func_1334 (runtime.zig) | 112 | 1.1% |
| rig.table.Table(checker.TypeReference,67108864).at (table.zig) | 102 | 1.0% |
| checker.Checker.instantiate_symbol (checker.zig) | 101 | 1.0% |
| checker.Checker.type_target (checker.zig) | 88 | 0.8% |

# cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp: 9804 samples

## cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp by region

| region | samples | share |
|---|---:|---:|
| large | 6397 | 65.2% |
| table | 3028 | 30.9% |
| file bin | 315 | 3.2% |
| anon | 43 | 0.4% |
| small | 18 | 0.2% |
| unmapped | 3 | 0.0% |

## cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp by owner

| owner | samples | share |
|---|---:|---:|
| map index checker.InstantiationKey -> u32 | 2007 | 20.5% |
| map index checker.CacheKey -> u32 | 1489 | 15.2% |
| map index checker.CachedTypeKey -> u32 | 620 | 6.3% |
| table u32 | 489 | 5.0% |
| table checker.Type | 358 | 3.7% |
| map index u32 -> checker.MappedSymbolLinks | 357 | 3.6% |
| map entries checker.InstantiationKey -> u32 | 345 | 3.5% |
| (binary data) | 315 | 3.2% |
| map entries checker.CacheKey -> u32 | 298 | 3.0% |
| table checker.StructuredType | 290 | 3.0% |
| ast.NodeRec | 271 | 2.8% |
| table checker.UnionOrIntersectionType | 183 | 1.9% |
| table checker.ValueSymbolLinks | 168 | 1.7% |
| table checker.TypeMapper | 168 | 1.7% |
| u32 | 167 | 1.7% |
| table checker.ConditionalType | 151 | 1.5% |
| map entries checker.CachedTypeKey -> u32 | 136 | 1.4% |
| table checker.TypeNodeLinks | 132 | 1.3% |
| table checker.CheckerSymbol | 129 | 1.3% |
| __rig_std_prelude.Map(u32,u32) | 107 | 1.1% |
| table checker.TypeReference | 107 | 1.1% |
| table checker.Signature | 102 | 1.0% |
| map index checker.CachedSignatureKey -> u32 | 98 | 1.0% |
| u8 | 83 | 0.8% |
| table checker.TypeParameter | 82 | 0.8% |

## cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp by owner and allocating caller

| owner | caller | samples | share |
|---|---:|---:|---:|
| map index checker.InstantiationKey -> u32 | checker.Checker.get_conditional_type_instantiation_of (checker.zig:48513:43) | 1432 | 14.6% |
| map index checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 1106 | 11.3% |
| map index checker.CachedTypeKey -> u32 | checker.Checker.get_permissive_instantiation (checker.zig:48278:37) | 553 | 5.6% |
| table u32 | - | 489 | 5.0% |
| map index checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 482 | 4.9% |
| table checker.Type | - | 358 | 3.7% |
| map index u32 -> checker.MappedSymbolLinks | checker.Checker.set_mapped_symbol_links_key_type (checker.zig:78480:106) | 357 | 3.6% |
| (binary data) | - | 315 | 3.2% |
| table checker.StructuredType | - | 290 | 3.0% |
| ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 271 | 2.8% |
| map index checker.CacheKey -> u32 | checker.Checker.get_intersection_type_of_set (checker.zig:44088:43) | 234 | 2.4% |
| map entries checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 217 | 2.2% |
| map entries checker.InstantiationKey -> u32 | checker.Checker.create_type_reference_ex (checker.zig:5770:39) | 192 | 2.0% |
| table checker.UnionOrIntersectionType | - | 183 | 1.9% |
| table checker.ValueSymbolLinks | - | 168 | 1.7% |
| table checker.TypeMapper | - | 168 | 1.7% |
| table checker.ConditionalType | - | 151 | 1.5% |
| map index checker.CacheKey -> u32 | checker.Checker.get_union_type_from_sorted_list (checker.zig:4722:36) | 149 | 1.5% |
| table checker.TypeNodeLinks | - | 132 | 1.3% |
| table checker.CheckerSymbol | - | 129 | 1.3% |
| u32 | binder.Binder.declare_symbol_ex (binder.zig:234:65) | 118 | 1.2% |
| table checker.TypeReference | - | 107 | 1.1% |
| table checker.Signature | - | 102 | 1.0% |
| __rig_std_prelude.Map(u32,u32) | checker.Checker.new_table (checker.zig:2773:23) | 100 | 1.0% |
| map index checker.CachedSignatureKey -> u32 | checker.Checker.get_signature_instantiation_without_filling_in_type_arguments (checker.zig:39742:42) | 98 | 1.0% |

## cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp by kind of block

| kind | samples | share |
|---|---:|---:|
| Map index | 4606 | 47.0% |
| table | 3028 | 30.9% |
| List/String growth | 941 | 9.6% |
| Map entries | 856 | 8.7% |
| file bin | 315 | 3.2% |
| anon | 43 | 0.4% |
| allocSlice (other) | 12 | 0.1% |
| unmapped | 3 | 0.0% |

## cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp by sampled function (innermost inlined frame)

| function | samples | share |
|---|---:|---:|
| rig.ordered.Ordered(checker.InstantiationKey,u32).findIndexed (ordered.zig) | 1541 | 15.7% |
| rig.ordered.Ordered(checker.CacheKey,u32).findIndexed (ordered.zig) | 1131 | 11.5% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).findIndexed (ordered.zig) | 484 | 4.9% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll (ordered.zig) | 462 | 4.7% |
| rig.table.Table(u32,268435456).at (table.zig) | 457 | 4.7% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll (ordered.zig) | 358 | 3.7% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch (ordered.zig) | 311 | 3.2% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch (ordered.zig) | 273 | 2.8% |
| rig.ordered.Ordered(u32,checker.MappedSymbolLinks).findIndexed (ordered.zig) | 256 | 2.6% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1199 (runtime.zig) | 206 | 2.1% |
| rig.table.Table(checker.TypeMapper,16777216).at (table.zig) | 167 | 1.7% |
| checker.Checker.type_target (checker.zig) | 158 | 1.6% |
| rig.table.Table(checker.UnionOrIntersectionType,67108864).at (table.zig) | 157 | 1.6% |
| rig.table.Table(checker.ConditionalType,67108864).at (table.zig) | 151 | 1.5% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at (table.zig) | 139 | 1.4% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll (ordered.zig) | 136 | 1.4% |
| rig.table.Table(checker.Type,134217728).at (table.zig) | 121 | 1.2% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).eqlKey (ordered.zig) | 110 | 1.1% |
| rig.runtime.ListOf(u32,0).atProven (runtime.zig) | 107 | 1.1% |
| rig.ordered.Ordered(u32,checker.MappedSymbolLinks).matchAll (ordered.zig) | 101 | 1.0% |
| checker.Checker.could_contain_type_variables (checker.zig) | 98 | 1.0% |
| rig.table.Table(checker.Signature,33554432).at (table.zig) | 90 | 0.9% |
| rig.ordered.Ordered(u32,u32).findHashed (ordered.zig) | 85 | 0.9% |
| rig.table.Table(checker.StructuredType,67108864).at (table.zig) | 80 | 0.8% |
| rig.table.Table(checker.TypeReference,67108864).at (table.zig) | 79 | 0.8% |
