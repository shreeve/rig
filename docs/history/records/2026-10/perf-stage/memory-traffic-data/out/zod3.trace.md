# out/zod3.trace.1.json (30 runs)

records 1134767; allocated 123.5 MB in 567151 blocks; peak of live blocks 51.5 MB

## Volume by owner (bytes requested)

| owner | MB | share | blocks | share | avg B |
|---|---:|---:|---:|---:|---:|
| u32 | 15.1 | 12.2% | 188185 | 33.2% | 80 |
| u8 | 12.8 | 10.3% | 160327 | 28.3% | 79 |
| ast.NodeRec | 12.3 | 10.0% | 1928 | 0.3% | 6396 |
| __rig_std_prelude.Map(u32,u32) | 9.4 | 7.6% | 729 | 0.1% | 12900 |
| map entries u32 -> u32 | 7.4 | 6.0% | 56899 | 10.0% | 130 |
| ast.SymbolRec | 6.1 | 4.9% | 933 | 0.2% | 6537 |
| map entries checker.CacheKey -> u32 | 4.5 | 3.6% | 135 | 0.0% | 33181 |
| map index checker.CacheKey -> void | 4.1 | 3.3% | 291 | 0.1% | 14020 |
| map entries checker.InstantiationKey -> u32 | 3.9 | 3.2% | 14 | 0.0% | 280857 |
| checker.TableEntry | 3.9 | 3.2% | 24745 | 4.4% | 157 |
| checker.KeyedSym | 3.9 | 3.2% | 12173 | 2.1% | 320 |
| ast.ListRec | 3.3 | 2.7% | 1504 | 0.3% | 2197 |
| map index u32 -> u32 | 3.1 | 2.5% | 6724 | 1.2% | 455 |
| map entries u32 -> checker.ExportCollision | 2.2 | 1.8% | 483 | 0.1% | 4644 |
| ast.TextRec | 2.2 | 1.8% | 2490 | 0.4% | 893 |
| u64 | 1.9 | 1.6% | 2329 | 0.4% | 829 |
| checker.SymbolData | 1.8 | 1.5% | 13 | 0.0% | 141137 |
| map index checker.CacheKey -> u32 | 1.8 | 1.4% | 905 | 0.2% | 1964 |
| ast.FlowRec | 1.7 | 1.4% | 822 | 0.1% | 2074 |
| ast.Node | 1.4 | 1.2% | 27237 | 4.8% | 52 |
| i64 | 1.4 | 1.1% | 13933 | 2.5% | 97 |
| checker.SpellingCandidate | 1.3 | 1.1% | 61 | 0.0% | 21573 |
| checker.Loc | 1.3 | 1.1% | 28 | 0.0% | 46809 |
| map index checker.InstantiationKey -> u32 | 1.3 | 1.1% | 12 | 0.0% | 109200 |
| untyped | 1.1 | 0.9% | 4408 | 0.8% | 243 |

## Volume by mechanism

| mechanism | MB | share | blocks | share |
|---|---:|---:|---:|---:|
| List/String growth | 59.3 | 48.0% | 41736 | 7.4% |
| allocSlice (other) | 29.0 | 23.4% | 448403 | 79.1% |
| Map entries | 22.7 | 18.4% | 63734 | 11.2% |
| Map index | 11.5 | 9.3% | 8842 | 1.6% |
| Io.Writer.Allocating.ensureTotalCapacityPrecise | 0.6 | 0.5% | 4185 | 0.7% |
| array_list.Aligned(u8,null).ensureTotalCapacityPrecise | 0.5 | 0.4% | 222 | 0.0% |
| Map gone bits | 0.0 | 0.0% | 21 | 0.0% |
| - | 0.0 | 0.0% | 6 | 0.0% |
| rig.runtime.start | 0.0 | 0.0% | 1 | 0.0% |
| box (create) | 0.0 | 0.0% | 1 | 0.0% |

## Volume by caller

| caller | MB | share | blocks | share |
|---|---:|---:|---:|---:|
| ast.Ast.new_node (ast.zig:304:23) | 12.3 | 9.9% | 1104 | 0.2% |
| checker.Checker.table_put (checker.zig:2796:67) | 9.5 | 7.7% | 48867 | 8.6% |
| binder.Binder.new_symbol (binder.zig:210:34) | 6.0 | 4.9% | 573 | 0.1% |
| checker.Checker.new_table (checker.zig:2773:23) | 5.5 | 4.5% | 13 | 0.0% |
| checker.Checker.recursive_type_related_to (checker.zig:68436:40) | 4.2 | 3.4% | 377 | 0.1% |
| checker.Checker.relation_set (checker.zig:65377:82) | 4.1 | 3.3% | 79 | 0.0% |
| checker.Checker.table_entries (checker.zig:2813:74) | 3.9 | 3.2% | 24745 | 4.4% |
| checker.Checker.sort_symbols_by_key (checker.zig:82568:72) | 3.9 | 3.2% | 12173 | 2.1% |
| ast.Binding.get_symbol_table (ast.zig:16734:25) | 3.7 | 3.0% | 352 | 0.1% |
| checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 3.7 | 3.0% | 15 | 0.0% |
| parser.Parser.finish_source_file (parser.zig:941:384) | 3.5 | 2.9% | 181 | 0.0% |
| ast.Ast.add_text (ast.zig:312:28) | 3.3 | 2.7% | 1801 | 0.3% |
| ast.Ast.add_list (ast.zig:353:24) | 3.2 | 2.6% | 680 | 0.1% |
| checker.Checker.extend_export_symbols (checker.zig:81251:48) | 2.6 | 2.1% | 759 | 0.1% |
| ast.Ast.add_text (ast.zig:311:24) | 2.2 | 1.8% | 833 | 0.1% |
| ast.Ast.new_identifier (ast.zig:1299:24) | 2.0 | 1.6% | 502 | 0.1% |
| checker.Checker.new_symbol (checker.zig:2551:30) | 1.8 | 1.5% | 13 | 0.0% |
| binder.Binder.new_flow_node (binder.zig:532:32) | 1.6 | 1.3% | 456 | 0.1% |
| checker.Checker.get_conditional_type_instantiation_of (checker.zig:48513:43) | 1.5 | 1.2% | 3 | 0.0% |
| parser.Parser.new (parser.zig:429:30) | 1.5 | 1.2% | 866 | 0.2% |
| checker.Checker.get_spelling_suggestion_for_name (checker.zig:53577:32) | 1.3 | 1.1% | 61 | 0.0% |
| checker.Checker.invoke_once (checker.zig:37270:29) | 1.2 | 0.9% | 2214 | 0.4% |
| binder.Binder.declare_symbol_ex (binder.zig:234:65) | 1.1 | 0.9% | 45 | 0.0% |
| checker.Checker.get_named_members (checker.zig:41968:61) | 1.1 | 0.9% | 15728 | 2.8% |
| checker.Ids.of (checker.zig:90983:41) | 1.0 | 0.8% | 14 | 0.0% |

## Volume by mechanism, owner, caller

| mechanism | owner | caller | MB | share | blocks |
|---|---:|---:|---:|---:|---:|
| List/String growth | ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 12.3 | 9.9% | 1104 |
| Map entries | map entries u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 6.6 | 5.3% | 42399 |
| List/String growth | ast.SymbolRec | binder.Binder.new_symbol (binder.zig:210:34) | 6.0 | 4.9% | 573 |
| List/String growth | __rig_std_prelude.Map(u32,u32) | checker.Checker.new_table (checker.zig:2773:23) | 5.5 | 4.5% | 12 |
| Map index | map index checker.CacheKey -> void | checker.Checker.recursive_type_related_to (checker.zig:68436:40) | 4.1 | 3.3% | 291 |
| allocSlice (other) | checker.TableEntry | checker.Checker.table_entries (checker.zig:2813:74) | 3.9 | 3.2% | 24745 |
| allocSlice (other) | checker.KeyedSym | checker.Checker.sort_symbols_by_key (checker.zig:82568:72) | 3.9 | 3.2% | 12173 |
| List/String growth | __rig_std_prelude.Map(u32,u32) | ast.Binding.get_symbol_table (ast.zig:16734:25) | 3.7 | 3.0% | 352 |
| allocSlice (other) | u8 | parser.Parser.finish_source_file (parser.zig:941:384) | 3.5 | 2.9% | 181 |
| Map entries | map entries checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 3.4 | 2.8% | 49 |
| List/String growth | u8 | ast.Ast.add_text (ast.zig:312:28) | 3.3 | 2.7% | 1583 |
| List/String growth | ast.ListRec | ast.Ast.add_list (ast.zig:353:24) | 3.2 | 2.6% | 680 |
| Map index | map index u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 2.8 | 2.3% | 6468 |
| Map entries | map entries checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 2.6 | 2.1% | 7 |
| Map entries | map entries u32 -> checker.ExportCollision | checker.Checker.extend_export_symbols (checker.zig:81251:48) | 2.2 | 1.8% | 483 |
| List/String growth | ast.TextRec | ast.Ast.add_text (ast.zig:311:24) | 2.2 | 1.8% | 833 |
| List/String growth | u32 | ast.Ast.new_identifier (ast.zig:1299:24) | 2.0 | 1.6% | 294 |
| List/String growth | checker.SymbolData | checker.Checker.new_symbol (checker.zig:2551:30) | 1.8 | 1.5% | 12 |
| List/String growth | ast.FlowRec | binder.Binder.new_flow_node (binder.zig:532:32) | 1.6 | 1.3% | 456 |
| List/String growth | u64 | parser.Parser.new (parser.zig:429:30) | 1.5 | 1.2% | 685 |
| List/String growth | checker.SpellingCandidate | checker.Checker.get_spelling_suggestion_for_name (checker.zig:53577:32) | 1.3 | 1.1% | 50 |
| Map entries | map entries checker.InstantiationKey -> u32 | checker.Checker.get_conditional_type_instantiation_of (checker.zig:48513:43) | 1.3 | 1.1% | 1 |
| Map index | map index checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 1.1 | 0.9% | 8 |
| allocSlice (other) | u32 | checker.Checker.get_named_members (checker.zig:41968:61) | 1.1 | 0.9% | 15728 |
| Map entries | map entries checker.InferenceKey -> i32 | checker.Checker.invoke_once (checker.zig:37270:29) | 1.0 | 0.8% | 2000 |
| List/String growth | checker.Loc | checker.Ids.of (checker.zig:90983:41) | 1.0 | 0.8% | 14 |
| List/String growth | checker.InferenceContext | checker.Checker.new_inference_context_worker (checker.zig:38875:41) | 1.0 | 0.8% | 10 |
| allocSlice (other) | u32 | ast.Binding.new (ast.zig:16721:69) | 0.9 | 0.7% | 360 |
| allocSlice (other) | u32 | ast.Binding.new (ast.zig:16722:69) | 0.9 | 0.7% | 360 |
| allocSlice (other) | u32 | ast.Binding.new (ast.zig:16723:69) | 0.9 | 0.7% | 360 |
| allocSlice (other) | u32 | ast.Binding.new (ast.zig:16724:69) | 0.9 | 0.7% | 360 |
| List/String growth | ast.Node | ast.Ast.add_list (ast.zig:358:37) | 0.9 | 0.7% | 764 |
| allocSlice (other) | ast.CommentDirective | lexer.Scanner.mark (lexer.zig:2412:117) | 0.9 | 0.7% | 9100 |
| List/String growth | compiler.ParseTask | compiler.FileLoader.new_task (compiler.zig:1542:24) | 0.8 | 0.7% | 7 |
| Map index | map index checker.CacheKey -> u32 | checker.Checker.instantiate_type_with_alias (checker.zig:46272:69) | 0.8 | 0.7% | 850 |
| allocSlice (other) | u32 | checker.Checker.get_named_members (checker.zig:41966:82) | 0.7 | 0.6% | 5548 |
| Map entries | map entries u32 -> u32 | binder.Binder.table_put (binder.zig:181:79) | 0.7 | 0.6% | 14128 |
| Map index | map index checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 0.7 | 0.6% | 30 |
| List/String growth | ast.File | compiler.new_program (compiler.zig:4737:23) | 0.7 | 0.5% | 6 |
| allocSlice (other) | u8 | tspath.RootedFilePath.as_path (tspath.zig:3204:53) | 0.6 | 0.5% | 9687 |
| allocSlice (other) | u8 | tspath.CaseSensitivity.canonicalize (tspath.zig:2188:33) | 0.6 | 0.5% | 9080 |
| List/String growth | checker.InferenceInfo | checker.Checker.alloc_inference_info (checker.zig:39476:34) | 0.6 | 0.5% | 10 |
| List/String growth | u8 | binder.Binder.declare_symbol_ex (binder.zig:234:65) | 0.6 | 0.5% | 22 |
| Map entries | map entries checker.CachedSignatureKey -> u32 | checker.Checker.get_erased_signature (checker.zig:39835:42) | 0.6 | 0.5% | 7 |
| allocSlice (other) | u8 | compiler.Program.path_key_of (compiler.zig:3127:507) | 0.6 | 0.5% | 8500 |
| Io.Writer.Allocating.ensureTotalCapacityPrecise | untyped | - | 0.6 | 0.5% | 4185 |
| allocSlice (other) | u32 | checker.Checker.type_list_items (checker.zig:75628:25) | 0.5 | 0.4% | 33432 |
| Map entries | map entries checker.CacheKey -> u32 | checker.Checker.get_union_type_from_sorted_list (checker.zig:4722:36) | 0.5 | 0.4% | 12 |
| array_list.Aligned(u8,null).ensureTotalCapacityPrecise | untyped | rig.std.file.readHere (file.zig:113:36) | 0.5 | 0.4% | 87 |
| allocSlice (other) | checker.RecursionId | checker.Checker.get_resolved_base_constraint (checker.zig:47489:22) | 0.5 | 0.4% | 7337 |

## Blocks by mechanism, owner, caller

| mechanism | owner | caller | blocks | share | MB |
|---|---:|---:|---:|---:|---:|
| Map entries | map entries u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 42399 | 7.5% | 6.6 |
| allocSlice (other) | u32 | checker.Checker.type_list_items (checker.zig:75628:25) | 33432 | 5.9% | 0.5 |
| allocSlice (other) | u8 | checker.Checker.node_text (checker.zig:81434:29) | 28463 | 5.0% | 0.5 |
| allocSlice (other) | checker.TableEntry | checker.Checker.table_entries (checker.zig:2813:74) | 24745 | 4.4% | 3.9 |
| allocSlice (other) | u8 | lexer.get_text_of_node_from_source_text (lexer.zig:5730:29) | 18266 | 3.2% | 0.3 |
| allocSlice (other) | u32 | checker.Checker.get_named_members (checker.zig:41968:61) | 15728 | 2.8% | 1.1 |
| Map entries | map entries u32 -> u32 | binder.Binder.table_put (binder.zig:181:79) | 14128 | 2.5% | 0.7 |
| allocSlice (other) | checker.KeyedSym | checker.Checker.sort_symbols_by_key (checker.zig:82568:72) | 12173 | 2.1% | 3.9 |
| allocSlice (other) | ast.Node | checker.Checker.mark_node_assignments_worker__struct_5512.__rig_invoke (checker.zig:35743:49) | 10945 | 1.9% | 0.2 |
| allocSlice (other) | checker.NodeRef | checker.Checker.add_declaration (checker.zig:2762:78) | 10651 | 1.9% | 0.3 |
| allocSlice (other) | u8 | tspath.RootedFilePath.as_path (tspath.zig:3204:53) | 9687 | 1.7% | 0.6 |
| allocSlice (other) | u8 | checker.Checker.ast_symbol_name (checker.zig:50465:29) | 9242 | 1.6% | 0.2 |
| allocSlice (other) | ast.CommentDirective | lexer.Scanner.mark (lexer.zig:2412:117) | 9100 | 1.6% | 0.9 |
| allocSlice (other) | u8 | tspath.CaseSensitivity.canonicalize (tspath.zig:2188:33) | 9080 | 1.6% | 0.6 |
| allocSlice (other) | u8 | compiler.Program.path_key_of (compiler.zig:3127:507) | 8500 | 1.5% | 0.6 |
| allocSlice (other) | u32 | checker.Checker.add_mapped_members_for_key_type (checker.zig:50553:22) | 7547 | 1.3% | 0.1 |
| allocSlice (other) | checker.RecursionId | checker.Checker.get_resolved_base_constraint (checker.zig:47489:22) | 7337 | 1.3% | 0.5 |
| allocSlice (other) | u32 | checker.Checker.sym_list_items (checker.zig:75678:25) | 7312 | 1.3% | 0.1 |
| allocSlice (other) | u8 | ast.Ast.get_property_name_for_property_name_node (ast.zig:13373:37) | 7204 | 1.3% | 0.1 |
| allocSlice (other) | u32 | checker.Checker.context_inferences (checker.zig:38894:30) | 6828 | 1.2% | 0.1 |
| allocSlice (other) | u8 | ast.SourceFileMetaData.cloned (ast.zig:14616:200) | 6717 | 1.2% | 0.3 |
| Map index | map index u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 6468 | 1.1% | 2.8 |
| allocSlice (other) | checker.NodeRef | checker.Checker.get_effective_call_arguments (checker.zig:19446:29) | 6167 | 1.1% | 0.2 |
| List/String growth | u32 | checker.Checker.filter_type (checker.zig:6854:38) | 5671 | 1.0% | 0.4 |
| allocSlice (other) | u32 | checker.Checker.get_named_members (checker.zig:41966:82) | 5548 | 1.0% | 0.7 |
| allocSlice (other) | i64 | checker.Checker.get_named_members (checker.zig:41981:32) | 5548 | 1.0% | 0.2 |
| allocSlice (other) | ast.Node | parser.Parser.parse_modifiers_ex (parser.zig:4847:34) | 5546 | 1.0% | 0.1 |
| List/String growth | u32 | checker.Checker.type_list_items (checker.zig:75628:25) | 5140 | 0.9% | 0.3 |
| allocSlice (other) | u32 | checker.Checker.filter_type (checker.zig:6854:38) | 5127 | 0.9% | 0.1 |
| allocSlice (other) | u32 | checker.Checker.get_optional_type (checker.zig:12479:19) | 5032 | 0.9% | 0.1 |
| allocSlice (other) | u32 | checker.Checker.reorder_candidates (checker.zig:18744:30) | 4846 | 0.9% | 0.1 |
| Io.Writer.Allocating.ensureTotalCapacityPrecise | untyped | - | 4185 | 0.7% | 0.6 |
| allocSlice (other) | u32 | checker.Checker.type_distributed (checker.zig:81914:19) | 3989 | 0.7% | 0.1 |
| allocSlice (other) | u8 | compiler.Program.get_emit_module_format_of_file (compiler.zig:3146:326) | 3921 | 0.7% | 0.3 |
| allocSlice (other) | ast.Node | parser.Parser.parse_union_or_intersection_type (parser.zig:3507:23) | 3634 | 0.6% | 0.1 |
| List/String growth | i64 | checker.Checker.get_named_members (checker.zig:41981:32) | 3275 | 0.6% | 0.4 |
| allocSlice (other) | checker.RecursionId | checker.Checker.get_resolved_base_constraint (checker.zig:47486:30) | 3236 | 0.6% | 0.2 |
| allocSlice (other) | u8 | lexer.Scanner.mark (lexer.zig:2409:63) | 3003 | 0.5% | 0.0 |
| allocSlice (other) | u32 | checker.Checker.infer_types (checker.zig:36861:34) | 2832 | 0.5% | 0.0 |
| allocSlice (other) | u32 | checker.Checker.write_type_reference_key (checker.zig:65712:49) | 2795 | 0.5% | 0.0 |
| allocSlice (other) | u8 | checker.Checker.is_known_property (checker.zig:67053:55) | 2765 | 0.5% | 0.0 |
| allocSlice (other) | u32 | checker.Checker.create_union_or_intersection_property (checker.zig:50089:32) | 2696 | 0.5% | 0.0 |
| List/String growth | u32 | checker.Checker.sym_list_items (checker.zig:75678:25) | 2665 | 0.5% | 0.3 |
| allocSlice (other) | checker.NodeRef | checker.Checker.create_union_or_intersection_property (checker.zig:50060:46) | 2638 | 0.5% | 0.1 |
| allocSlice (other) | u8 | lexer.Scanner.value_add (lexer.zig:2370:24) | 2607 | 0.5% | 0.0 |
| allocSlice (other) | u32 | checker.Checker.new_inference_context (checker.zig:38806:32) | 2235 | 0.4% | 0.0 |
| allocSlice (other) | u32 | checker.Checker.create_union_or_intersection_property (checker.zig:49924:50) | 2180 | 0.4% | 0.0 |
| List/String growth | u8 | ast.Names.intern (ast.zig:17784:32) | 2166 | 0.4% | 0.2 |
| Map entries | map entries checker.InferenceKey -> i32 | checker.Checker.invoke_once (checker.zig:37270:29) | 2000 | 0.4% | 1.0 |
| List/String growth | u32 | checker.Checker.get_reduced_union_type (checker.zig:42701:35) | 1908 | 0.3% | 0.1 |

## Bytes copied by growth that moved a block (reallocSlice)

| owner | caller | MB | moves |
|---|---:|---:|---:|
| __rig_std_prelude.Map(u32,u32) | checker.Checker.new_table (checker.zig:2773:23) | 1.4 | 2 |
| ast.SymbolRec | binder.Binder.new_symbol (binder.zig:210:34) | 1.2 | 131 |
| u32 | ast.Ast.new_identifier (ast.zig:1299:24) | 0.8 | 36 |
| ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 0.8 | 1 |
| map entries checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 0.7 | 2 |
| map entries checker.InstantiationKey -> u32 | checker.Checker.get_conditional_type_instantiation_of (checker.zig:48513:43) | 0.7 | 1 |
| checker.SpellingCandidate | checker.Checker.get_spelling_suggestion_for_name (checker.zig:53577:32) | 0.7 | 40 |
| u64 | parser.Parser.new (parser.zig:429:30) | 0.6 | 381 |
| map entries u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 0.6 | 2398 |
| __rig_std_prelude.Map(u32,u32) | ast.Binding.get_symbol_table (ast.zig:16734:25) | 0.6 | 127 |
| map entries u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 0.6 | 2284 |
| map entries checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 0.6 | 3 |
| u8 | ast.Ast.add_text (ast.zig:312:28) | 0.6 | 66 |
| ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 0.6 | 51 |
| u8 | ast.Ast.add_text (ast.zig:312:28) | 0.5 | 177 |
| checker.Loc | checker.Ids.of (checker.zig:90983:41) | 0.5 | 14 |
| __rig_std_prelude.Map(u32,u32) | ast.Binding.get_symbol_table (ast.zig:16734:25) | 0.5 | 92 |
| ast.ListRec | ast.Ast.add_list (ast.zig:353:24) | 0.5 | 13 |
| ast.TextRec | ast.Ast.add_text (ast.zig:311:24) | 0.5 | 57 |
| map entries u32 -> checker.ExportCollision | checker.Checker.extend_export_symbols (checker.zig:81251:48) | 0.5 | 105 |
| ast.FlowRec | binder.Binder.new_flow_node (binder.zig:532:32) | 0.5 | 185 |
| map entries u32 -> checker.ExportCollision | checker.Checker.extend_export_symbols (checker.zig:81251:48) | 0.5 | 102 |
| ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 0.5 | 17 |
| __rig_std_prelude.Map(u32,u32) | ast.Binding.get_symbol_table (ast.zig:16734:25) | 0.5 | 7 |
| checker.SymbolData | checker.Checker.new_symbol (checker.zig:2551:30) | 0.5 | 1 |

copied in all: 32.4 MB

# cpu_core/mem_load_retired.l3_miss,period=97/upp: 9186 samples

## cpu_core/mem_load_retired.l3_miss,period=97/upp by region

| region | samples | share |
|---|---:|---:|
| large | 4276 | 46.5% |
| table | 2227 | 24.2% |
| small | 1967 | 21.4% |
| file bin | 553 | 6.0% |
| anon | 78 | 0.8% |
| freed | 73 | 0.8% |
| unmapped | 11 | 0.1% |
| stack | 1 | 0.0% |

## cpu_core/mem_load_retired.l3_miss,period=97/upp by owner

| owner | samples | share |
|---|---:|---:|
| ast.NodeRec | 1025 | 11.2% |
| u32 | 888 | 9.7% |
| (binary data) | 553 | 6.0% |
| ast.SymbolRec | 484 | 5.3% |
| table checker.Type | 457 | 5.0% |
| u8 | 412 | 4.5% |
| map index checker.InstantiationKey -> u32 | 383 | 4.2% |
| map index checker.CacheKey -> u32 | 354 | 3.9% |
| __rig_std_prelude.Map(u32,u32) | 342 | 3.7% |
| table checker.StructuredType | 279 | 3.0% |
| map entries checker.CacheKey -> u32 | 264 | 2.9% |
| table u32 | 258 | 2.8% |
| map entries checker.InstantiationKey -> u32 | 243 | 2.6% |
| table checker.ValueSymbolLinks | 231 | 2.5% |
| ast.ListRec | 213 | 2.3% |
| map entries u32 -> u32 | 193 | 2.1% |
| table checker.Signature | 155 | 1.7% |
| table checker.TypeNodeLinks | 130 | 1.4% |
| ast.TextRec | 118 | 1.3% |
| checker.Loc | 111 | 1.2% |
| table checker.CheckerSymbol | 104 | 1.1% |
| compiler.ParseTask | 87 | 0.9% |
| ast.Node | 86 | 0.9% |
| table checker.UnionOrIntersectionType | 86 | 0.9% |
| table checker.TypeReference | 85 | 0.9% |

## cpu_core/mem_load_retired.l3_miss,period=97/upp by owner and allocating caller

| owner | caller | samples | share |
|---|---:|---:|---:|
| ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 1024 | 11.1% |
| (binary data) | - | 553 | 6.0% |
| ast.SymbolRec | binder.Binder.new_symbol (binder.zig:210:34) | 482 | 5.2% |
| table checker.Type | - | 457 | 5.0% |
| map index checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 350 | 3.8% |
| map index checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 291 | 3.2% |
| table checker.StructuredType | - | 279 | 3.0% |
| table u32 | - | 258 | 2.8% |
| table checker.ValueSymbolLinks | - | 231 | 2.5% |
| ast.ListRec | ast.Ast.add_list (ast.zig:353:24) | 213 | 2.3% |
| map entries checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 187 | 2.0% |
| map entries checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 177 | 1.9% |
| __rig_std_prelude.Map(u32,u32) | ast.Binding.get_symbol_table (ast.zig:16734:25) | 175 | 1.9% |
| u32 | binder.Binder.declare_symbol_ex (binder.zig:234:65) | 170 | 1.9% |
| u8 | binder.Binder.declare_symbol_ex (binder.zig:234:65) | 169 | 1.8% |
| __rig_std_prelude.Map(u32,u32) | checker.Checker.new_table (checker.zig:2773:23) | 159 | 1.7% |
| table checker.Signature | - | 155 | 1.7% |
| u32 | ast.Ast.new_parameter_declaration (ast.zig:1585:24) | 151 | 1.6% |
| u32 | ast.Binding.new (ast.zig:16721:69) | 131 | 1.4% |
| table checker.TypeNodeLinks | - | 130 | 1.4% |
| ast.TextRec | ast.Ast.add_text (ast.zig:311:24) | 118 | 1.3% |
| u8 | ast.Ast.add_text (ast.zig:312:28) | 111 | 1.2% |
| table checker.CheckerSymbol | - | 104 | 1.1% |
| map entries u32 -> u32 | checker.Checker.table_put (checker.zig:2796:67) | 103 | 1.1% |
| compiler.ParseTask | compiler.FileLoader.new_task (compiler.zig:1542:24) | 87 | 0.9% |

## cpu_core/mem_load_retired.l3_miss,period=97/upp by kind of block

| kind | samples | share |
|---|---:|---:|
| List/String growth | 3707 | 40.4% |
| table | 2227 | 24.2% |
| Map entries | 1028 | 11.2% |
| Map index | 933 | 10.2% |
| allocSlice (other) | 554 | 6.0% |
| file bin | 553 | 6.0% |
| anon | 78 | 0.8% |
| freed | 73 | 0.8% |
| array_list.Aligned(u8,null).ensureTotalCapacityPrecise | 19 | 0.2% |
| unmapped | 11 | 0.1% |
| Map gone bits | 2 | 0.0% |
| stack | 1 | 0.0% |

## cpu_core/mem_load_retired.l3_miss,period=97/upp by sampled function (innermost inlined frame)

| function | samples | share |
|---|---:|---:|
| compiler_rt.memcpy.copyBlocks (memcpy.zig) | 1033 | 11.2% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1199 (runtime.zig) | 549 | 6.0% |
| rig.runtime.ListOf(u32,0).at__func_1294 (runtime.zig) | 478 | 5.2% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll (ordered.zig) | 375 | 4.1% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll (ordered.zig) | 346 | 3.8% |
| rig.table.Table(u32,268435456).at (table.zig) | 239 | 2.6% |
| checker.Checker.symbol_flags (checker.zig) | 227 | 2.5% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at (table.zig) | 200 | 2.2% |
| checker.Checker.could_contain_type_variables (checker.zig) | 169 | 1.8% |
| rig.runtime.ListOf(u32,0).atProven (runtime.zig) | 159 | 1.7% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch (ordered.zig) | 158 | 1.7% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch (ordered.zig) | 154 | 1.7% |
| rig.table.Table(checker.Type,134217728).at (table.zig) | 148 | 1.6% |
| mem.eqlBytes (mem.zig) | 139 | 1.5% |
| checker.Checker.is_declaration_contained_in (checker.zig) | 135 | 1.5% |
| rig.table.Table(checker.Signature,33554432).at (table.zig) | 133 | 1.4% |
| rig.runtime.ListOf(ast.ListRec,0).at__func_1296 (runtime.zig) | 122 | 1.3% |
| rig.runtime.atProven (runtime.zig) | 117 | 1.3% |
| rig.ordered.Ordered(u32,u32).findHashed (ordered.zig) | 110 | 1.2% |
| rig.ordered.Ordered(u32,u32).matchAll (ordered.zig) | 110 | 1.2% |
| rig.runtime.ListOf(checker.Loc,0).at__func_4079 (runtime.zig) | 107 | 1.2% |
| rig.table.Table(checker.StructuredType,67108864).at (table.zig) | 102 | 1.1% |
| binder.Binder.bind_each_statement_functions_first (binder.zig) | 86 | 0.9% |
| rig.table.Table(checker.TypeMapper,16777216).at (table.zig) | 85 | 0.9% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at (table.zig) | 82 | 0.9% |

# cpu_core/ld_blocks.store_forward,period=1301/upp: 9180 samples

## cpu_core/ld_blocks.store_forward,period=1301/upp by region

| region | samples | share |
|---|---:|---:|
| unmapped | 9179 | 100.0% |
| large | 1 | 0.0% |

## cpu_core/ld_blocks.store_forward,period=1301/upp by owner

| owner | samples | share |
|---|---:|---:|
| (unmapped) | 9179 | 100.0% |
| map entries checker.InstantiationKey -> u32 | 1 | 0.0% |

## cpu_core/ld_blocks.store_forward,period=1301/upp by owner and allocating caller

| owner | caller | samples | share |
|---|---:|---:|---:|
| (unmapped) | - | 9179 | 100.0% |
| map entries checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 1 | 0.0% |

## cpu_core/ld_blocks.store_forward,period=1301/upp by kind of block

| kind | samples | share |
|---|---:|---:|
| unmapped | 9179 | 100.0% |
| Map entries | 1 | 0.0% |

## cpu_core/ld_blocks.store_forward,period=1301/upp by sampled function (innermost inlined frame)

| function | samples | share |
|---|---:|---:|
| rig.runtime.Niche(checker.Relater,.{ .offset = 89, .Word = u8, .value = 2, .spare = 254 }).unwrap (runtime.zig) | 748 | 8.1% |
| checker.Checker.get_relater (checker.zig) | 416 | 4.5% |
| parser.Parser.rewind (parser.zig) | 327 | 3.6% |
| atomic.Value(usize).fetchAdd (atomic.zig) | 253 | 2.8% |
| rig.runtime.ListOf(checker.Relater,0).pop (runtime.zig) | 201 | 2.2% |
| rig.runtime.take__func_2705 (runtime.zig) | 200 | 2.2% |
| checker.Checker.get_signatures_of_structured_type (checker.zig) | 198 | 2.2% |
| compiler_rt.memcpy.copyBlocks (memcpy.zig) | 194 | 2.1% |
| mem.swap__func_4160 (mem.zig) | 184 | 2.0% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll (ordered.zig) | 184 | 2.0% |
| rig.runtime.AllocTrace.walk (runtime.zig) | 170 | 1.9% |
| rig.table.Table(u32,268435456).push (table.zig) | 135 | 1.5% |
| rig.runtime.Niche(lexer.ScannerState,.{ .offset = 112, .Word = u16, .value = 352, .spare = 65184 }).unwrap (runtime.zig) | 113 | 1.2% |
| checker.Checker.instantiate_types (checker.zig) | 110 | 1.2% |
| checker.Checker.new_type_list (checker.zig) | 106 | 1.2% |
| checker.Checker.check_expression_ex (checker.zig) | 96 | 1.0% |
| rig.ordered.Ordered(checker.CacheKey,u32).findIndexed (ordered.zig) | 96 | 1.0% |
| checker.Checker.get_object_type_instantiation (checker.zig) | 90 | 1.0% |
| checker.Checker.get_accessed_property_name (checker.zig) | 89 | 1.0% |
| checker.Checker.instantiate_type_with_alias (checker.zig) | 85 | 0.9% |
| checker.Checker.get_type_items_instantiation_key (checker.zig) | 79 | 0.9% |
| checker.Checker.get_flow_type_of_reference_in (checker.zig) | 77 | 0.8% |
| rig.runtime.rt__func_704 (runtime.zig) | 76 | 0.8% |
| rig.runtime.rt__func_5458 (runtime.zig) | 72 | 0.8% |
| checker.Checker.get_apparent_type (checker.zig) | 69 | 0.8% |

# cpu_core/mem_load_retired.l2_miss,period=307/upp: 9388 samples

## cpu_core/mem_load_retired.l2_miss,period=307/upp by region

| region | samples | share |
|---|---:|---:|
| large | 4055 | 43.2% |
| table | 2272 | 24.2% |
| small | 1781 | 19.0% |
| file bin | 887 | 9.4% |
| anon | 224 | 2.4% |
| freed | 152 | 1.6% |
| unmapped | 14 | 0.1% |
| file [vvar] | 2 | 0.0% |
| stack | 1 | 0.0% |

## cpu_core/mem_load_retired.l2_miss,period=307/upp by owner

| owner | samples | share |
|---|---:|---:|
| ast.NodeRec | 991 | 10.6% |
| (binary data) | 889 | 9.5% |
| u32 | 816 | 8.7% |
| ast.SymbolRec | 541 | 5.8% |
| u8 | 514 | 5.5% |
| table checker.Type | 505 | 5.4% |
| map index checker.InstantiationKey -> u32 | 367 | 3.9% |
| table u32 | 329 | 3.5% |
| table checker.StructuredType | 274 | 2.9% |
| map index checker.CacheKey -> u32 | 271 | 2.9% |
| table checker.ValueSymbolLinks | 261 | 2.8% |
| __rig_std_prelude.Map(u32,u32) | 237 | 2.5% |
| (anon mapping) | 224 | 2.4% |
| checker.Loc | 195 | 2.1% |
| map entries u32 -> u32 | 153 | 1.6% |
| (freed block) | 152 | 1.6% |
| table checker.TypeNodeLinks | 148 | 1.6% |
| ast.ListRec | 146 | 1.6% |
| table checker.Signature | 111 | 1.2% |
| map entries checker.InstantiationKey -> u32 | 111 | 1.2% |
| checker.Checker | 109 | 1.2% |
| map entries checker.CacheKey -> u32 | 105 | 1.1% |
| ast.File | 103 | 1.1% |
| table checker.TypeReference | 95 | 1.0% |
| table checker.CheckerSymbol | 89 | 0.9% |

## cpu_core/mem_load_retired.l2_miss,period=307/upp by owner and allocating caller

| owner | caller | samples | share |
|---|---:|---:|---:|
| ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 991 | 10.6% |
| (binary data) | - | 889 | 9.5% |
| ast.SymbolRec | binder.Binder.new_symbol (binder.zig:210:34) | 541 | 5.8% |
| table checker.Type | - | 505 | 5.4% |
| table u32 | - | 329 | 3.5% |
| u8 | binder.Binder.declare_symbol_ex (binder.zig:234:65) | 313 | 3.3% |
| map index checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 299 | 3.2% |
| table checker.StructuredType | - | 274 | 2.9% |
| table checker.ValueSymbolLinks | - | 261 | 2.8% |
| u32 | binder.Binder.declare_symbol_ex (binder.zig:234:65) | 240 | 2.6% |
| (anon mapping) | - | 224 | 2.4% |
| u32 | ast.Ast.new_parameter_declaration (ast.zig:1585:24) | 224 | 2.4% |
| map index checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 200 | 2.1% |
| checker.Loc | checker.Ids.of (checker.zig:90983:41) | 159 | 1.7% |
| (freed block) | - | 152 | 1.6% |
| table checker.TypeNodeLinks | - | 148 | 1.6% |
| ast.ListRec | ast.Ast.add_list (ast.zig:353:24) | 146 | 1.6% |
| __rig_std_prelude.Map(u32,u32) | ast.Binding.get_symbol_table (ast.zig:16734:25) | 132 | 1.4% |
| table checker.Signature | - | 111 | 1.2% |
| checker.Checker | declarations.new_checker_pool (declarations.zig:285:26) | 109 | 1.2% |
| u8 | ast.Ast.add_text (ast.zig:312:28) | 103 | 1.1% |
| ast.File | compiler.new_program (compiler.zig:4737:23) | 103 | 1.1% |
| __rig_std_prelude.Map(u32,u32) | checker.Checker.new_table (checker.zig:2773:23) | 102 | 1.1% |
| table checker.TypeReference | - | 95 | 1.0% |
| table checker.CheckerSymbol | - | 89 | 0.9% |

## cpu_core/mem_load_retired.l2_miss,period=307/upp by kind of block

| kind | samples | share |
|---|---:|---:|
| List/String growth | 3782 | 40.3% |
| table | 2272 | 24.2% |
| Map index | 1004 | 10.7% |
| file bin | 887 | 9.4% |
| Map entries | 596 | 6.3% |
| allocSlice (other) | 436 | 4.6% |
| anon | 224 | 2.4% |
| freed | 152 | 1.6% |
| array_list.Aligned(u8,null).ensureTotalCapacityPrecise | 16 | 0.2% |
| unmapped | 14 | 0.1% |
| file [vvar] | 2 | 0.0% |
| Map gone bits | 2 | 0.0% |
| stack | 1 | 0.0% |

## cpu_core/mem_load_retired.l2_miss,period=307/upp by sampled function (innermost inlined frame)

| function | samples | share |
|---|---:|---:|
| compiler_rt.memcpy.copyBlocks (memcpy.zig) | 748 | 8.0% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1199 (runtime.zig) | 472 | 5.0% |
| rig.runtime.ListOf(u32,0).at__func_1294 (runtime.zig) | 441 | 4.7% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll (ordered.zig) | 364 | 3.9% |
| rig.table.Table(u32,268435456).at (table.zig) | 312 | 3.3% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll (ordered.zig) | 268 | 2.9% |
| checker.Checker.symbol_flags (checker.zig) | 263 | 2.8% |
| checker.Checker.is_declaration_contained_in (checker.zig) | 241 | 2.6% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at (table.zig) | 214 | 2.3% |
| mem.eqlBytes (mem.zig) | 203 | 2.2% |
| checker.Checker.could_contain_type_variables (checker.zig) | 199 | 2.1% |
| rig.runtime.ListOf(checker.Loc,0).at__func_4079 (runtime.zig) | 192 | 2.0% |
| rig.runtime.ListOf(u32,0).atProven (runtime.zig) | 165 | 1.8% |
| rig.table.Table(checker.Type,134217728).at (table.zig) | 163 | 1.7% |
| rig.alloc.alloc (alloc.zig) | 136 | 1.4% |
| rig.runtime.atProven (runtime.zig) | 122 | 1.3% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at (table.zig) | 119 | 1.3% |
| checker.Checker.is_reserved_member_name (checker.zig) | 111 | 1.2% |
| rig.table.Table(checker.StructuredType,67108864).at (table.zig) | 106 | 1.1% |
| rig.ordered.Ordered(u32,u32).matchAll (ordered.zig) | 101 | 1.1% |
| rig.table.Table(checker.Signature,33554432).at (table.zig) | 99 | 1.1% |
| rig.ordered.Ordered(u32,u32).findHashed (ordered.zig) | 87 | 0.9% |
| rig.table.Table(checker.TypeReference,67108864).at (table.zig) | 73 | 0.8% |
| rig.runtime.ListOf(ast.ListRec,0).at__func_1296 (runtime.zig) | 70 | 0.7% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll (ordered.zig) | 68 | 0.7% |

# cpu_core/mem_load_retired.l1_miss,period=4001/upp: 9622 samples

## cpu_core/mem_load_retired.l1_miss,period=4001/upp by region

| region | samples | share |
|---|---:|---:|
| large | 3385 | 35.2% |
| table | 2092 | 21.7% |
| file bin | 1449 | 15.1% |
| small | 1434 | 14.9% |
| anon | 1085 | 11.3% |
| freed | 152 | 1.6% |
| unmapped | 17 | 0.2% |
| file [vvar] | 4 | 0.0% |
| stack | 4 | 0.0% |

## cpu_core/mem_load_retired.l1_miss,period=4001/upp by owner

| owner | samples | share |
|---|---:|---:|
| (binary data) | 1453 | 15.1% |
| (anon mapping) | 1085 | 11.3% |
| ast.NodeRec | 828 | 8.6% |
| u32 | 679 | 7.1% |
| table checker.Type | 606 | 6.3% |
| ast.SymbolRec | 505 | 5.2% |
| checker.Checker | 490 | 5.1% |
| u8 | 307 | 3.2% |
| table u32 | 280 | 2.9% |
| checker.Loc | 264 | 2.7% |
| table checker.ValueSymbolLinks | 251 | 2.6% |
| table checker.StructuredType | 206 | 2.1% |
| __rig_std_prelude.Map(u32,u32) | 155 | 1.6% |
| map index checker.CacheKey -> u32 | 155 | 1.6% |
| map index checker.InstantiationKey -> u32 | 154 | 1.6% |
| (freed block) | 152 | 1.6% |
| ast.File | 110 | 1.1% |
| table checker.CheckerSymbol | 110 | 1.1% |
| table checker.TypeReference | 86 | 0.9% |
| table checker.Signature | 83 | 0.9% |
| ast.ListRec | 82 | 0.9% |
| map entries u32 -> u32 | 82 | 0.9% |
| table checker.UnionOrIntersectionType | 77 | 0.8% |
| map entries checker.CacheKey -> u32 | 73 | 0.8% |
| table checker.TypeParameter | 71 | 0.7% |

## cpu_core/mem_load_retired.l1_miss,period=4001/upp by owner and allocating caller

| owner | caller | samples | share |
|---|---:|---:|---:|
| (binary data) | - | 1453 | 15.1% |
| (anon mapping) | - | 1085 | 11.3% |
| ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 828 | 8.6% |
| table checker.Type | - | 606 | 6.3% |
| ast.SymbolRec | binder.Binder.new_symbol (binder.zig:210:34) | 503 | 5.2% |
| checker.Checker | declarations.new_checker_pool (declarations.zig:285:26) | 490 | 5.1% |
| table u32 | - | 280 | 2.9% |
| table checker.ValueSymbolLinks | - | 251 | 2.6% |
| checker.Loc | checker.Ids.of (checker.zig:90983:41) | 237 | 2.5% |
| table checker.StructuredType | - | 206 | 2.1% |
| u32 | ast.Ast.new_parameter_declaration (ast.zig:1585:24) | 194 | 2.0% |
| u8 | binder.Binder.declare_symbol_ex (binder.zig:234:65) | 189 | 2.0% |
| u32 | binder.Binder.declare_symbol_ex (binder.zig:234:65) | 184 | 1.9% |
| (freed block) | - | 152 | 1.6% |
| map index checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 125 | 1.3% |
| map index checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 121 | 1.3% |
| ast.File | compiler.new_program (compiler.zig:4737:23) | 110 | 1.1% |
| table checker.CheckerSymbol | - | 110 | 1.1% |
| __rig_std_prelude.Map(u32,u32) | checker.Checker.new_table (checker.zig:2773:23) | 99 | 1.0% |
| table checker.TypeReference | - | 86 | 0.9% |
| table checker.Signature | - | 83 | 0.9% |
| ast.ListRec | ast.Ast.add_list (ast.zig:353:24) | 82 | 0.9% |
| table checker.UnionOrIntersectionType | - | 77 | 0.8% |
| u8 | ast.Ast.add_text (ast.zig:312:28) | 72 | 0.7% |
| table checker.TypeParameter | - | 71 | 0.7% |

## cpu_core/mem_load_retired.l1_miss,period=4001/upp by kind of block

| kind | samples | share |
|---|---:|---:|
| List/String growth | 3233 | 33.6% |
| table | 2092 | 21.7% |
| file bin | 1449 | 15.1% |
| anon | 1085 | 11.3% |
| allocSlice (other) | 688 | 7.2% |
| Map index | 552 | 5.7% |
| Map entries | 334 | 3.5% |
| freed | 152 | 1.6% |
| unmapped | 17 | 0.2% |
| array_list.Aligned(u8,null).ensureTotalCapacityPrecise | 12 | 0.1% |
| file [vvar] | 4 | 0.0% |
| stack | 4 | 0.0% |

## cpu_core/mem_load_retired.l1_miss,period=4001/upp by sampled function (innermost inlined frame)

| function | samples | share |
|---|---:|---:|
| compiler_rt.memcpy.copyBlocks (memcpy.zig) | 492 | 5.1% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1199 (runtime.zig) | 377 | 3.9% |
| rig.runtime.ListOf(u32,0).at__func_1294 (runtime.zig) | 326 | 3.4% |
| rig.runtime.ListOf(checker.Loc,0).at__func_4079 (runtime.zig) | 260 | 2.7% |
| rig.table.Table(u32,268435456).at (table.zig) | 251 | 2.6% |
| rig.table.Table(checker.Type,134217728).at (table.zig) | 245 | 2.5% |
| rig.alloc.alloc (alloc.zig) | 210 | 2.2% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at (table.zig) | 205 | 2.1% |
| mem.eqlBytes (mem.zig) | 180 | 1.9% |
| checker.Checker.could_contain_type_variables (checker.zig) | 168 | 1.7% |
| checker.Checker.symbol_flags (checker.zig) | 158 | 1.6% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll (ordered.zig) | 155 | 1.6% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll (ordered.zig) | 145 | 1.5% |
| checker.Checker.is_declaration_contained_in (checker.zig) | 140 | 1.5% |
| rig.alloc.free (alloc.zig) | 127 | 1.3% |
| checker.Checker.symbol_value_declaration (checker.zig) | 109 | 1.1% |
| ast.Ast.set_parent_in_immediate_children (ast.zig) | 106 | 1.1% |
| rig.runtime.ListOf(u32,0).atProven (runtime.zig) | 95 | 1.0% |
| rig.table.Table(checker.StructuredType,67108864).at (table.zig) | 92 | 1.0% |
| rig.ordered.Ordered(u32,u32).matchAll (ordered.zig) | 86 | 0.9% |
| checker.Checker.is_reserved_member_name (checker.zig) | 74 | 0.8% |
| rig.ordered.Ordered(u32,u32).findHashed (ordered.zig) | 73 | 0.8% |
| rig.table.Table(checker.Signature,33554432).at (table.zig) | 70 | 0.7% |
| ast.Ast.text (ast.zig) | 68 | 0.7% |
| rig.table.Table(checker.UnionOrIntersectionType,67108864).at (table.zig) | 66 | 0.7% |

# cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp: 8092 samples

## cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp by region

| region | samples | share |
|---|---:|---:|
| large | 3946 | 48.8% |
| table | 3186 | 39.4% |
| file bin | 795 | 9.8% |
| anon | 98 | 1.2% |
| small | 31 | 0.4% |
| unmapped | 28 | 0.3% |
| freed | 4 | 0.0% |
| stack | 2 | 0.0% |
| file [vvar] | 2 | 0.0% |

## cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp by owner

| owner | samples | share |
|---|---:|---:|
| (binary data) | 797 | 9.8% |
| ast.NodeRec | 697 | 8.6% |
| map index checker.InstantiationKey -> u32 | 560 | 6.9% |
| u32 | 557 | 6.9% |
| table checker.Type | 547 | 6.8% |
| table u32 | 476 | 5.9% |
| map index checker.CacheKey -> u32 | 402 | 5.0% |
| table checker.ValueSymbolLinks | 350 | 4.3% |
| table checker.StructuredType | 323 | 4.0% |
| ast.SymbolRec | 315 | 3.9% |
| u8 | 227 | 2.8% |
| __rig_std_prelude.Map(u32,u32) | 210 | 2.6% |
| table checker.Signature | 194 | 2.4% |
| table checker.TypeReference | 163 | 2.0% |
| checker.Loc | 153 | 1.9% |
| table checker.CheckerSymbol | 143 | 1.8% |
| table checker.TypeNodeLinks | 139 | 1.7% |
| map entries checker.InstantiationKey -> u32 | 135 | 1.7% |
| table checker.UnionOrIntersectionType | 130 | 1.6% |
| map entries checker.CacheKey -> u32 | 128 | 1.6% |
| ast.File | 125 | 1.5% |
| ast.ListRec | 100 | 1.2% |
| (anon mapping) | 98 | 1.2% |
| table checker.TypeParameter | 91 | 1.1% |
| ast.Binding | 88 | 1.1% |

## cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp by owner and allocating caller

| owner | caller | samples | share |
|---|---:|---:|---:|
| (binary data) | - | 797 | 9.8% |
| ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 697 | 8.6% |
| table checker.Type | - | 547 | 6.8% |
| table u32 | - | 476 | 5.9% |
| map index checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 466 | 5.8% |
| table checker.ValueSymbolLinks | - | 350 | 4.3% |
| map index checker.CacheKey -> u32 | checker.Checker.relation_set (checker.zig:65377:82) | 348 | 4.3% |
| table checker.StructuredType | - | 323 | 4.0% |
| ast.SymbolRec | binder.Binder.new_symbol (binder.zig:210:34) | 315 | 3.9% |
| u32 | binder.Binder.declare_symbol_ex (binder.zig:234:65) | 223 | 2.8% |
| u8 | binder.Binder.declare_symbol_ex (binder.zig:234:65) | 195 | 2.4% |
| table checker.Signature | - | 194 | 2.4% |
| u32 | ast.Ast.new_parameter_declaration (ast.zig:1585:24) | 190 | 2.3% |
| table checker.TypeReference | - | 163 | 2.0% |
| table checker.CheckerSymbol | - | 143 | 1.8% |
| table checker.TypeNodeLinks | - | 139 | 1.7% |
| table checker.UnionOrIntersectionType | - | 130 | 1.6% |
| ast.File | compiler.new_program (compiler.zig:4737:23) | 125 | 1.5% |
| __rig_std_prelude.Map(u32,u32) | checker.Checker.new_table (checker.zig:2773:23) | 110 | 1.4% |
| checker.Loc | checker.Ids.of (checker.zig:90983:41) | 104 | 1.3% |
| __rig_std_prelude.Map(u32,u32) | ast.Binding.get_symbol_table (ast.zig:16734:25) | 100 | 1.2% |
| ast.ListRec | ast.Ast.add_list (ast.zig:353:24) | 100 | 1.2% |
| map entries checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 99 | 1.2% |
| (anon mapping) | - | 98 | 1.2% |
| map index checker.InstantiationKey -> u32 | checker.Checker.get_conditional_type_instantiation_of (checker.zig:48513:43) | 94 | 1.2% |

## cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp by kind of block

| kind | samples | share |
|---|---:|---:|
| table | 3186 | 39.4% |
| List/String growth | 2498 | 30.9% |
| Map index | 1068 | 13.2% |
| file bin | 795 | 9.8% |
| Map entries | 309 | 3.8% |
| allocSlice (other) | 102 | 1.3% |
| anon | 98 | 1.2% |
| unmapped | 28 | 0.3% |
| freed | 4 | 0.0% |
| stack | 2 | 0.0% |
| file [vvar] | 2 | 0.0% |

## cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp by sampled function (innermost inlined frame)

| function | samples | share |
|---|---:|---:|
| rig.table.Table(u32,268435456).at (table.zig) | 450 | 5.6% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1199 (runtime.zig) | 432 | 5.3% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).findIndexed (ordered.zig) | 430 | 5.3% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at (table.zig) | 324 | 4.0% |
| rig.ordered.Ordered(checker.CacheKey,u32).findIndexed (ordered.zig) | 320 | 4.0% |
| checker.Checker.could_contain_type_variables (checker.zig) | 234 | 2.9% |
| rig.runtime.ListOf(u32,0).at__func_1294 (runtime.zig) | 209 | 2.6% |
| rig.runtime.ListOf(u32,0).atProven (runtime.zig) | 198 | 2.4% |
| mem.eqlBytes (mem.zig) | 192 | 2.4% |
| checker.Checker.symbol_flags (checker.zig) | 179 | 2.2% |
| rig.table.Table(checker.Signature,33554432).at (table.zig) | 162 | 2.0% |
| rig.runtime.ListOf(checker.Loc,0).at__func_4079 (runtime.zig) | 153 | 1.9% |
| rig.table.Table(checker.StructuredType,67108864).at (table.zig) | 135 | 1.7% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll (ordered.zig) | 131 | 1.6% |
| rig.table.Table(checker.Type,134217728).at (table.zig) | 126 | 1.6% |
| checker.Checker.is_declaration_contained_in (checker.zig) | 121 | 1.5% |
| rig.table.Table(checker.TypeReference,67108864).at (table.zig) | 121 | 1.5% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch (ordered.zig) | 119 | 1.5% |
| rig.ordered.Ordered(u32,u32).findHashed (ordered.zig) | 118 | 1.5% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch (ordered.zig) | 118 | 1.5% |
| rig.table.Table(checker.UnionOrIntersectionType,67108864).at (table.zig) | 115 | 1.4% |
| checker.Checker.is_reserved_member_name (checker.zig) | 109 | 1.3% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at (table.zig) | 102 | 1.3% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll (ordered.zig) | 83 | 1.0% |
| rig.runtime.ListOf(ast.ListRec,0).at__func_1296 (runtime.zig) | 81 | 1.0% |
