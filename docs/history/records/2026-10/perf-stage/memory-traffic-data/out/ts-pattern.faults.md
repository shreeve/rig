# out/ts-pattern.faults.json (1 runs)

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

copied in all: 66.6 MB

# page-faults: 40065 samples

## page-faults by region

| region | samples | share |
|---|---:|---:|
| table | 32476 | 81.1% |
| large | 6683 | 16.7% |
| anon | 529 | 1.3% |
| file bin | 221 | 0.6% |
| unmapped | 82 | 0.2% |
| small | 70 | 0.2% |
| file [vdso] | 2 | 0.0% |
| stack | 1 | 0.0% |
| file [vvar] | 1 | 0.0% |

## page-faults by owner

| owner | samples | share |
|---|---:|---:|
| table checker.ValueSymbolLinks | 5545 | 13.8% |
| table u32 | 4746 | 11.8% |
| table checker.TypeMapper | 4503 | 11.2% |
| table checker.StructuredType | 4004 | 10.0% |
| table checker.Type | 3977 | 9.9% |
| table checker.CheckerSymbol | 2655 | 6.6% |
| table checker.Signature | 2100 | 5.2% |
| map entries checker.InstantiationKey -> u32 | 1271 | 3.2% |
| table checker.UnionOrIntersectionType | 1224 | 3.1% |
| __rig_std_prelude.Map(u32,u32) | 1160 | 2.9% |
| map entries checker.CacheKey -> u32 | 918 | 2.3% |
| checker.SymbolData | 838 | 2.1% |
| table checker.TypeNodeLinks | 602 | 1.5% |
| table checker.SignatureLinks | 546 | 1.4% |
| ast.NodeRec | 541 | 1.4% |
| (anon mapping) | 529 | 1.3% |
| table checker.TypeParameter | 483 | 1.2% |
| table checker.ConditionalType | 457 | 1.1% |
| table checker.TypeReference | 424 | 1.1% |
| table checker.TypeAlias | 346 | 0.9% |

## page-faults by owner and allocating caller

| owner | caller | samples | share |
|---|---:|---:|---:|
| table checker.ValueSymbolLinks | - | 5545 | 13.8% |
| table u32 | - | 4746 | 11.8% |
| table checker.TypeMapper | - | 4503 | 11.2% |
| table checker.StructuredType | - | 4004 | 10.0% |
| table checker.Type | - | 3977 | 9.9% |
| table checker.CheckerSymbol | - | 2655 | 6.6% |
| table checker.Signature | - | 2100 | 5.2% |
| table checker.UnionOrIntersectionType | - | 1224 | 3.1% |
| __rig_std_prelude.Map(u32,u32) | checker.Checker.new_table (checker.zig:2773:23) | 1103 | 2.8% |
| map entries checker.InstantiationKey -> u32 | checker.Checker.create_type_reference_ex (checker.zig:5770:39) | 960 | 2.4% |
| checker.SymbolData | checker.Checker.new_symbol (checker.zig:2551:30) | 838 | 2.1% |
| map entries checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 762 | 1.9% |
| table checker.TypeNodeLinks | - | 602 | 1.5% |
| table checker.SignatureLinks | - | 546 | 1.4% |
| ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 541 | 1.4% |
| (anon mapping) | - | 529 | 1.3% |
| table checker.TypeParameter | - | 483 | 1.2% |
| table checker.ConditionalType | - | 457 | 1.1% |
| table checker.TypeReference | - | 424 | 1.1% |
| table checker.TypeAlias | - | 346 | 0.9% |

## page-faults by kind of block

| kind | samples | share |
|---|---:|---:|
| table | 32476 | 81.1% |
| List/String growth | 3359 | 8.4% |
| Map entries | 2446 | 6.1% |
| Map index | 696 | 1.7% |
| anon | 529 | 1.3% |
| file bin | 221 | 0.6% |
| allocSlice (other) | 180 | 0.4% |
| unmapped | 82 | 0.2% |
| array_list.Aligned(u8,null).ensureTotalCapacityPrecise | 72 | 0.2% |
| file [vdso] | 2 | 0.0% |
| stack | 1 | 0.0% |
| file [vvar] | 1 | 0.0% |

## page-faults by sampled function (innermost inlined frame)

| function | samples | share |
|---|---:|---:|
| rig.table.Table(u32,268435456).push (table.zig) | 4746 | 11.8% |
| rig.table.Table(checker.TypeMapper,16777216).push (table.zig) | 4503 | 11.2% |
| rig.table.Table(checker.StructuredType,67108864).push (table.zig) | 4004 | 10.0% |
| rig.table.Table(checker.Type,134217728).push (table.zig) | 3977 | 9.9% |
| checker.Checker.set_value_symbol_links_target (checker.zig) | 2956 | 7.4% |
| rig.table.Table(checker.CheckerSymbol,67108864).push (table.zig) | 2655 | 6.6% |
| rig.table.Table(checker.Signature,33554432).push (table.zig) | 2100 | 5.2% |
| checker.Checker.set_value_symbol_links_mapper (checker.zig) | 1496 | 3.7% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).insertHashed (ordered.zig) | 1271 | 3.2% |
| rig.table.Table(checker.UnionOrIntersectionType,67108864).push (table.zig) | 1224 | 3.1% |
| rig.runtime.ListOf(__rig_std_prelude.Map(u32,u32),0).push (runtime.zig) | 1160 | 2.9% |
| compiler_rt.memsetSmallPowerOf2__func_2 (compiler_rt.zig) | 1007 | 2.5% |
| rig.ordered.Ordered(checker.CacheKey,u32).insertHashed (ordered.zig) | 918 | 2.3% |
| rig.runtime.ListOf(checker.SymbolData,0).push (runtime.zig) | 839 | 2.1% |
| checker.Checker.set_value_symbol_links_containing_type (checker.zig) | 699 | 1.7% |
| compiler_rt.memcpy.copyBlocks (memcpy.zig) | 496 | 1.2% |
| rig.table.Table(checker.TypeParameter,67108864).push (table.zig) | 483 | 1.2% |
| rig.table.Table(checker.ConditionalType,67108864).push (table.zig) | 457 | 1.1% |
| rig.table.Table(checker.TypeReference,67108864).push (table.zig) | 424 | 1.1% |
| rig.runtime.ListOf(ast.NodeRec,0).push (runtime.zig) | 375 | 0.9% |
