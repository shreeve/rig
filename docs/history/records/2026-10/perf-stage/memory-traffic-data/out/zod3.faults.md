# out/zod3.faults.json (1 runs)

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

copied in all: 32.4 MB

# page-faults: 9301 samples

## page-faults by region

| region | samples | share |
|---|---:|---:|
| table | 6442 | 69.3% |
| large | 2119 | 22.8% |
| anon | 386 | 4.2% |
| file bin | 219 | 2.4% |
| unmapped | 81 | 0.9% |
| small | 50 | 0.5% |
| file [vdso] | 2 | 0.0% |
| stack | 1 | 0.0% |
| file [vvar] | 1 | 0.0% |

## page-faults by owner

| owner | samples | share |
|---|---:|---:|
| table checker.ValueSymbolLinks | 1091 | 11.7% |
| table checker.StructuredType | 768 | 8.3% |
| table checker.Type | 711 | 7.6% |
| table u32 | 594 | 6.4% |
| table checker.SignatureLinks | 560 | 6.0% |
| table checker.TypeNodeLinks | 548 | 5.9% |
| ast.NodeRec | 495 | 5.3% |
| table checker.CheckerSymbol | 460 | 4.9% |
| table checker.Signature | 451 | 4.8% |
| table checker.TypeMapper | 420 | 4.5% |
| (anon mapping) | 386 | 4.2% |
| __rig_std_prelude.Map(u32,u32) | 274 | 2.9% |
| map entries checker.InstantiationKey -> u32 | 272 | 2.9% |
| (binary data) | 222 | 2.4% |
| u8 | 213 | 2.3% |
| table checker.SymbolNodeLinks | 199 | 2.1% |
| u64 | 186 | 2.0% |
| u32 | 165 | 1.8% |
| table checker.UnionOrIntersectionType | 147 | 1.6% |
| ast.SymbolRec | 144 | 1.5% |

## page-faults by owner and allocating caller

| owner | caller | samples | share |
|---|---:|---:|---:|
| table checker.ValueSymbolLinks | - | 1091 | 11.7% |
| table checker.StructuredType | - | 768 | 8.3% |
| table checker.Type | - | 711 | 7.6% |
| table u32 | - | 594 | 6.4% |
| table checker.SignatureLinks | - | 560 | 6.0% |
| table checker.TypeNodeLinks | - | 548 | 5.9% |
| ast.NodeRec | ast.Ast.new_node (ast.zig:304:23) | 495 | 5.3% |
| table checker.CheckerSymbol | - | 460 | 4.9% |
| table checker.Signature | - | 451 | 4.8% |
| table checker.TypeMapper | - | 420 | 4.5% |
| (anon mapping) | - | 386 | 4.2% |
| (binary data) | - | 222 | 2.4% |
| __rig_std_prelude.Map(u32,u32) | checker.Checker.new_table (checker.zig:2773:23) | 210 | 2.3% |
| table checker.SymbolNodeLinks | - | 199 | 2.1% |
| map entries checker.InstantiationKey -> u32 | checker.Checker.get_object_type_instantiation (checker.zig:46692:39) | 192 | 2.1% |
| u64 | parser.Parser.new (parser.zig:429:30) | 186 | 2.0% |
| table checker.UnionOrIntersectionType | - | 147 | 1.6% |
| ast.SymbolRec | binder.Binder.new_symbol (binder.zig:210:34) | 144 | 1.5% |
| u8 | parser.Parser.finish_source_file (parser.zig:941:384) | 109 | 1.2% |
| table checker.TypeReference | - | 107 | 1.2% |

## page-faults by kind of block

| kind | samples | share |
|---|---:|---:|
| table | 6442 | 69.3% |
| List/String growth | 1446 | 15.5% |
| anon | 386 | 4.2% |
| Map entries | 372 | 4.0% |
| file bin | 219 | 2.4% |
| allocSlice (other) | 192 | 2.1% |
| array_list.Aligned(u8,null).ensureTotalCapacityPrecise | 99 | 1.1% |
| unmapped | 81 | 0.9% |
| Map index | 60 | 0.6% |
| file [vdso] | 2 | 0.0% |
| stack | 1 | 0.0% |
| file [vvar] | 1 | 0.0% |

## page-faults by sampled function (innermost inlined frame)

| function | samples | share |
|---|---:|---:|
| rig.table.Table(checker.StructuredType,67108864).push (table.zig) | 768 | 8.3% |
| rig.table.Table(checker.Type,134217728).push (table.zig) | 712 | 7.7% |
| rig.table.Table(u32,268435456).push (table.zig) | 594 | 6.4% |
| checker.Checker.set_value_symbol_links_target (checker.zig) | 554 | 6.0% |
| compiler_rt.memcpy.copyBlocks (memcpy.zig) | 504 | 5.4% |
| rig.table.Table(checker.CheckerSymbol,67108864).push (table.zig) | 460 | 4.9% |
| rig.table.Table(checker.Signature,33554432).push (table.zig) | 451 | 4.8% |
| compiler_rt.memsetSmallPowerOf2__func_2 (compiler_rt.zig) | 423 | 4.5% |
| rig.table.Table(checker.TypeMapper,16777216).push (table.zig) | 420 | 4.5% |
| rig.runtime.ListOf(ast.NodeRec,0).push (runtime.zig) | 352 | 3.8% |
| checker.Checker.set_value_symbol_links_mapper (checker.zig) | 284 | 3.1% |
| rig.table.Table(checker.SignatureLinks,134217728).at (table.zig) | 280 | 3.0% |
| checker.Checker.set_signature_links_resolved_signature (checker.zig) | 276 | 3.0% |
| rig.runtime.ListOf(__rig_std_prelude.Map(u32,u32),0).push (runtime.zig) | 274 | 2.9% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).insertHashed (ordered.zig) | 272 | 2.9% |
| checker.Checker.set_type_node_links_resolved_type (checker.zig) | 155 | 1.7% |
| rig.table.Table(checker.UnionOrIntersectionType,67108864).push (table.zig) | 147 | 1.6% |
| rig.runtime.ListOf(ast.SymbolRec,0).push (runtime.zig) | 144 | 1.5% |
| checker.Checker.check_expression_cached_ex (checker.zig) | 138 | 1.5% |
| checker.Checker.get_type_from_type_reference (checker.zig) | 125 | 1.3% |
