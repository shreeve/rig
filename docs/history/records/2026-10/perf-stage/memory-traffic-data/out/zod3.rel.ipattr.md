
## cpu_core/mem_load_retired.l3_miss,period=97/upp: 5857 samples

| innermost function | samples | share |
|---|---:|---:|
| compiler_rt.memcpy.copyBlocks | 785 | 13.4% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 | 427 | 7.3% |
| rig.runtime.ListOf(u32,0).at__func_1276 | 381 | 6.5% |
| rig.table.Table(u32,268435456).at | 158 | 2.7% |
| checker.Checker.symbol_flags | 145 | 2.5% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at | 145 | 2.5% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch | 124 | 2.1% |
| rig.runtime.ListOf(ast.ListRec,0).at__func_1278 | 107 | 1.8% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch | 106 | 1.8% |
| rig.runtime.ListOf(u32,0).atProven | 102 | 1.7% |
| rig.table.Table(checker.StructuredType,67108864).at | 101 | 1.7% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll | 101 | 1.7% |
| rig.ordered.Ordered(u32,u32).findHashed | 86 | 1.5% |
| checker.Checker.could_contain_type_variables | 85 | 1.5% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll | 84 | 1.4% |
| rig.table.Table(checker.Type,134217728).at | 76 | 1.3% |
| mem.eqlBytes | 70 | 1.2% |
| checker.Checker.is_declaration_contained_in | 70 | 1.2% |
| rig.table.Table(checker.TypeMapper,16777216).at | 68 | 1.2% |
| compiler_rt.memcpy.copyFixedLength | 67 | 1.1% |
| rig.table.Table(checker.Signature,33554432).at | 66 | 1.1% |
| binder.Binder.bind_each_statement_functions_first | 65 | 1.1% |
| rig.runtime.ListOf(checker.Loc,0).at__func_3750 | 65 | 1.1% |
| rig.ordered.Ordered(u32,u32).matchAll | 64 | 1.1% |
| ast.Ast.text | 61 | 1.0% |
| rig.runtime.atProven | 52 | 0.9% |
| checker.Checker.get_late_bound_symbol | 49 | 0.8% |
| ast.as_node | 44 | 0.8% |
| checker.Checker.type_target | 42 | 0.7% |
| checker.Checker.get_flow_node_of_node | 41 | 0.7% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| compiler_rt.memcpy.copyBlocks @ memcpy.zig | compiler_rt.memcpy.copyBlocksAlignedSource | 785 | 13.4% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 @ runtime.zig | ast.Ast.kind | 214 | 3.7% |
| rig.table.Table(u32,268435456).at @ table.zig | rig.table.Table(u32,268435456).atInt | 158 | 2.7% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at @ table.zig | checker.Checker.value_symbol_links_resolved_type | 139 | 2.4% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).findIndexed | 124 | 2.1% |
| checker.Checker.symbol_flags @ checker.zig | checker.Checker.symbol_is_value_ex | 105 | 1.8% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).match | 101 | 1.7% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).findIndexed | 100 | 1.7% |
| rig.runtime.ListOf(u32,0).atProven @ runtime.zig | __rig_std_text.Interner.find | 93 | 1.6% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | checker.Checker.node_symbol | 88 | 1.5% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | ast.Ast.word_list | 87 | 1.5% |
| rig.runtime.ListOf(ast.ListRec,0).at__func_1278 @ runtime.zig | ast.Ast.nodes | 87 | 1.5% |
| rig.ordered.Ordered(u32,u32).findHashed @ ordered.zig | rig.ordered.Ordered(u32,u32).get | 85 | 1.5% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).match | 84 | 1.4% |
| mem.eqlBytes @ mem.zig | - | 70 | 1.2% |
| checker.Checker.is_declaration_contained_in @ checker.zig | checker.Checker.get_named_members | 70 | 1.2% |
| rig.table.Table(checker.TypeMapper,16777216).at @ table.zig | checker.Checker.mapper_kind | 66 | 1.1% |
| binder.Binder.bind_each_statement_functions_first @ binder.zig | - | 65 | 1.1% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | ast.Ast.word_node | 65 | 1.1% |
| ast.Ast.text @ ast.zig | - | 61 | 1.0% |
| rig.table.Table(checker.Type,134217728).at @ table.zig | checker.Checker.type_flags | 52 | 0.9% |
| checker.Checker.get_late_bound_symbol @ checker.zig | - | 49 | 0.8% |
| rig.runtime.ListOf(checker.Loc,0).at__func_3750 @ runtime.zig | checker.Ids.sym_file_of | 49 | 0.8% |
| compiler_rt.memcpy.copyFixedLength @ memcpy.zig | compiler_rt.memcpy.copyRange4 | 46 | 0.8% |
| checker.Checker.could_contain_type_variables @ checker.zig | checker.Checker.instantiate_type_with_alias | 46 | 0.8% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | checker.Checker.node_locals | 46 | 0.8% |
| rig.table.Table(checker.StructuredType,67108864).at @ table.zig | checker.Checker.structured_signatures | 42 | 0.7% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | checker.Checker.check_exports_on_merged_declarations | 40 | 0.7% |
| rig.runtime.String.__rig_drop @ runtime.zig | rig.runtime.dropElement__func_777 | 40 | 0.7% |
| checker.Checker.could_contain_type_variables @ checker.zig | checker.Checker.instantiate_symbol | 38 | 0.6% |

## cpu_core/ld_blocks.store_forward,period=1301/upp: 6086 samples

| innermost function | samples | share |
|---|---:|---:|
| compiler_rt.memcpy.copyBlocks | 152 | 2.5% |
| checker.Checker.get_relater | 146 | 2.4% |
| mem.swap__func_3831 | 141 | 2.3% |
| parser.Parser.rewind | 133 | 2.2% |
| rig.runtime.Niche(checker.Relater,.{ .offset = 89, .Word = u8, .value = 2, .spare = 254 }) | 126 | 2.1% |
| checker.Checker.mapper_map | 91 | 1.5% |
| checker.Checker.is_simple_type_related_to_ex | 89 | 1.5% |
| checker.Checker.check_type_related_to_ex_output | 76 | 1.2% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll | 73 | 1.2% |
| checker.Checker.get_object_type_instantiation | 69 | 1.1% |
| checker.Checker.instantiate_type_with_alias | 66 | 1.1% |
| lexer.Scanner.mark | 64 | 1.1% |
| rig.table.Table(u32,268435456).push | 63 | 1.0% |
| checker.Checker.get_accessed_property_name | 62 | 1.0% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 | 60 | 1.0% |
| rig.runtime.take__func_2464 | 59 | 1.0% |
| rig.alloc.alloc | 59 | 1.0% |
| checker.Checker.check_type_related_to | 58 | 1.0% |
| rig.runtime.foldMul | 56 | 0.9% |
| checker.Checker.instantiate_types | 54 | 0.9% |
| rig.ordered.Ordered(checker.CacheKey,u32).findIndexed | 54 | 0.9% |
| rig.runtime.ListOf(checker.Relater,0).pop | 52 | 0.9% |
| checker.Checker.get_signatures_of_structured_type | 51 | 0.8% |
| rig.runtime.Niche(lexer.ScannerState,.{ .offset = 112, .Word = u16, .value = 352, .spare = | 46 | 0.8% |
| rig.table.Table(checker.Type,134217728).constSlot | 45 | 0.7% |
| rig.table.Table(checker.Type,134217728).at | 42 | 0.7% |
| checker.Checker.check_type_related_to_ex | 41 | 0.7% |
| checker.Checker.is_type_related_to | 40 | 0.7% |
| parser.Parser.try_parse_modifier | 39 | 0.6% |
| rig.ordered.Ordered(u32,checker.ExportCollision).home | 39 | 0.6% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| compiler_rt.memcpy.copyBlocks @ memcpy.zig | compiler_rt.memcpy.copyBlocksAlignedSource | 152 | 2.5% |
| checker.Checker.get_relater @ checker.zig | checker.Checker.check_type_related_to_ex_output | 146 | 2.4% |
| mem.swap__func_3831 @ mem.zig | rig.runtime.swap__func_3827 | 141 | 2.3% |
| rig.runtime.Niche(checker.Relater,.{ .offset = 89, .Word = u8, .value = 2, .spare = 254 }) @ runtime.zig | rig.runtime.some | 126 | 2.1% |
| parser.Parser.rewind @ parser.zig | - | 120 | 2.0% |
| checker.Checker.mapper_map @ checker.zig | - | 91 | 1.5% |
| checker.Checker.is_simple_type_related_to_ex @ checker.zig | - | 89 | 1.5% |
| checker.Checker.check_type_related_to_ex_output @ checker.zig | - | 76 | 1.2% |
| checker.Checker.get_object_type_instantiation @ checker.zig | checker.Checker.instantiate_type_worker | 69 | 1.1% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).match | 68 | 1.1% |
| lexer.Scanner.mark @ lexer.zig | parser.Parser.mark | 64 | 1.1% |
| checker.Checker.instantiate_type_with_alias @ checker.zig | - | 64 | 1.1% |
| rig.alloc.alloc @ alloc.zig | - | 59 | 1.0% |
| checker.Checker.get_accessed_property_name @ checker.zig | - | 58 | 1.0% |
| checker.Checker.check_type_related_to @ checker.zig | checker.Checker.is_type_related_to | 58 | 1.0% |
| rig.runtime.foldMul @ runtime.zig | rig.runtime.hashWords | 56 | 0.9% |
| rig.ordered.Ordered(checker.CacheKey,u32).findIndexed @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).findHashed | 54 | 0.9% |
| checker.Checker.instantiate_types @ checker.zig | - | 53 | 0.9% |
| rig.runtime.ListOf(checker.Relater,0).pop @ runtime.zig | checker.Checker.get_relater | 52 | 0.9% |
| rig.runtime.Niche(lexer.ScannerState,.{ .offset = 112, .Word = u16, .value = 352, .spare = @ runtime.zig | rig.runtime.some | 46 | 0.8% |
| rig.table.Table(checker.Type,134217728).constSlot @ table.zig | rig.table.Table(checker.Type,134217728).at | 45 | 0.7% |
| checker.Checker.get_signatures_of_structured_type @ checker.zig | checker.Checker.get_signatures_of_type | 44 | 0.7% |
| checker.Checker.check_type_related_to_ex @ checker.zig | - | 41 | 0.7% |
| parser.Parser.try_parse_modifier @ parser.zig | - | 39 | 0.6% |
| rig.ordered.Ordered(u32,checker.ExportCollision).home @ ordered.zig | rig.ordered.Ordered(u32,checker.ExportCollision).findIndexed | 39 | 0.6% |
| rig.runtime.take__func_699 @ runtime.zig | lexer.get_text_of_node_from_source_text | 39 | 0.6% |
| checker.Checker.is_type_related_to @ checker.zig | - | 37 | 0.6% |
| checker.Checker.get_apparent_type @ checker.zig | - | 35 | 0.6% |
| rig.ordered.Ordered(u32,u32).insertHashed @ ordered.zig | rig.ordered.Ordered(u32,u32).put | 34 | 0.6% |
| rig.table.Table(u32,268435456).push @ table.zig | checker.Checker.new_type_list | 33 | 0.5% |

## cpu_core/mem_load_retired.l1_miss,period=4001/upp: 6199 samples

| innermost function | samples | share |
|---|---:|---:|
| compiler_rt.memcpy.copyBlocks | 453 | 7.3% |
| rig.runtime.ListOf(u32,0).at__func_1276 | 282 | 4.5% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 | 255 | 4.1% |
| rig.runtime.ListOf(checker.Loc,0).at__func_3750 | 186 | 3.0% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at | 171 | 2.8% |
| rig.table.Table(u32,268435456).at | 158 | 2.5% |
| mem.eqlBytes | 150 | 2.4% |
| rig.table.Table(checker.Type,134217728).at | 138 | 2.2% |
| checker.Checker.symbol_flags | 133 | 2.1% |
| checker.Checker.could_contain_type_variables | 125 | 2.0% |
| rig.alloc.alloc | 121 | 2.0% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll | 110 | 1.8% |
| checker.Checker.is_declaration_contained_in | 107 | 1.7% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll | 94 | 1.5% |
| rig.table.Table(checker.StructuredType,67108864).at | 75 | 1.2% |
| rig.alloc.free | 68 | 1.1% |
| rig.runtime.ListOf(u32,0).atProven | 63 | 1.0% |
| rig.runtime.atProven | 60 | 1.0% |
| checker.Checker.symbol_value_declaration | 57 | 0.9% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll | 56 | 0.9% |
| checker.Checker.is_reserved_member_name | 51 | 0.8% |
| rig.ordered.Ordered(u32,u32).matchAll | 51 | 0.8% |
| rig.ordered.Ordered(u32,u32).findHashed | 50 | 0.8% |
| rig.runtime.ListOf(ast.ListRec,0).at__func_1278 | 46 | 0.7% |
| ast.Ast.is_private_identifier | 46 | 0.7% |
| rig.table.Table(checker.Signature,33554432).at | 43 | 0.7% |
| rig.table.Table(checker.TypeMapper,16777216).at | 41 | 0.7% |
| rig.table.Table(checker.UnionOrIntersectionType,67108864).at | 40 | 0.6% |
| ast.Ast.set_parent_in_immediate_children | 39 | 0.6% |
| checker.Checker.instantiate_symbol | 39 | 0.6% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| compiler_rt.memcpy.copyBlocks @ memcpy.zig | compiler_rt.memcpy.copyBlocksAlignedSource | 453 | 7.3% |
| rig.runtime.ListOf(checker.Loc,0).at__func_3750 @ runtime.zig | checker.Ids.sym_file_of | 165 | 2.7% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at @ table.zig | checker.Checker.value_symbol_links_resolved_type | 162 | 2.6% |
| rig.table.Table(u32,268435456).at @ table.zig | rig.table.Table(u32,268435456).atInt | 158 | 2.5% |
| mem.eqlBytes @ mem.zig | - | 149 | 2.4% |
| checker.Checker.symbol_flags @ checker.zig | checker.Checker.symbol_is_value_ex | 126 | 2.0% |
| rig.alloc.alloc @ alloc.zig | - | 121 | 2.0% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).match | 110 | 1.8% |
| checker.Checker.is_declaration_contained_in @ checker.zig | checker.Checker.get_named_members | 107 | 1.7% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | ast.Ast.word_node | 107 | 1.7% |
| rig.table.Table(checker.Type,134217728).at @ table.zig | checker.Checker.type_flags | 98 | 1.6% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).match | 93 | 1.5% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 @ runtime.zig | ast.Ast.kind | 83 | 1.3% |
| rig.alloc.free @ alloc.zig | - | 68 | 1.1% |
| checker.Checker.could_contain_type_variables @ checker.zig | checker.Checker.instantiate_type_with_alias | 67 | 1.1% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | ast.Ast.word_list | 63 | 1.0% |
| rig.runtime.atProven @ runtime.zig | __rig_std_text.Interner.find | 58 | 0.9% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CachedTypeKey,u32).match | 56 | 0.9% |
| checker.Checker.could_contain_type_variables @ checker.zig | checker.Checker.instantiate_symbol | 55 | 0.9% |
| checker.Checker.is_reserved_member_name @ checker.zig | checker.Checker.is_named_member | 51 | 0.8% |
| rig.ordered.Ordered(u32,u32).findHashed @ ordered.zig | rig.ordered.Ordered(u32,u32).get | 50 | 0.8% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | __rig_std_text.Interner.text | 50 | 0.8% |
| ast.Ast.is_private_identifier @ ast.zig | ast.Ast.is_private_identifier_class_element_declaration | 41 | 0.7% |
| ast.Ast.set_parent_in_immediate_children @ ast.zig | - | 39 | 0.6% |
| checker.Checker.instantiate_symbol @ checker.zig | - | 39 | 0.6% |
| rig.table.Table(checker.TypeMapper,16777216).at @ table.zig | checker.Checker.mapper_kind | 38 | 0.6% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at @ table.zig | checker.Checker.type_node_links_outer_type_parameters | 35 | 0.6% |
| lexer.text_to_keyword @ lexer.zig | - | 34 | 0.5% |
| ast.Ast.text @ ast.zig | - | 34 | 0.5% |
| rig.ordered.Ordered(u32,u32).__rig_drop @ ordered.zig | rig.runtime.dropElement__func_1013 | 34 | 0.5% |

## cpu_core/mem_load_retired.l2_miss,period=307/upp: 5956 samples

| innermost function | samples | share |
|---|---:|---:|
| compiler_rt.memcpy.copyBlocks | 559 | 9.4% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 | 351 | 5.9% |
| rig.runtime.ListOf(u32,0).at__func_1276 | 274 | 4.6% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll | 244 | 4.1% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll | 236 | 4.0% |
| rig.table.Table(u32,268435456).at | 186 | 3.1% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at | 146 | 2.5% |
| checker.Checker.symbol_flags | 139 | 2.3% |
| checker.Checker.could_contain_type_variables | 131 | 2.2% |
| mem.eqlBytes | 123 | 2.1% |
| checker.Checker.is_declaration_contained_in | 105 | 1.8% |
| rig.runtime.ListOf(checker.Loc,0).at__func_3750 | 99 | 1.7% |
| rig.table.Table(checker.Type,134217728).at | 95 | 1.6% |
| rig.runtime.ListOf(u32,0).atProven | 90 | 1.5% |
| rig.runtime.atProven | 88 | 1.5% |
| rig.ordered.Ordered(u32,u32).matchAll | 77 | 1.3% |
| rig.ordered.Ordered(u32,u32).findHashed | 65 | 1.1% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch | 64 | 1.1% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at | 63 | 1.1% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch | 58 | 1.0% |
| rig.alloc.alloc | 57 | 1.0% |
| rig.table.Table(checker.StructuredType,67108864).at | 56 | 0.9% |
| rig.table.Table(checker.Signature,33554432).at | 55 | 0.9% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll | 50 | 0.8% |
| rig.runtime.ListOf(ast.ListRec,0).at__func_1278 | 50 | 0.8% |
| binder.Binder.bind_each_statement_functions_first | 47 | 0.8% |
| checker.Checker.instantiate_symbol | 46 | 0.8% |
| rig.table.Table(checker.UnionOrIntersectionType,67108864).at | 44 | 0.7% |
| rig.table.Table(checker.TypeReference,67108864).at | 44 | 0.7% |
| checker.Checker.is_reserved_member_name | 41 | 0.7% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| compiler_rt.memcpy.copyBlocks @ memcpy.zig | compiler_rt.memcpy.copyBlocksAlignedSource | 559 | 9.4% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).match | 244 | 4.1% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).match | 235 | 3.9% |
| rig.table.Table(u32,268435456).at @ table.zig | rig.table.Table(u32,268435456).atInt | 186 | 3.1% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at @ table.zig | checker.Checker.value_symbol_links_resolved_type | 135 | 2.3% |
| mem.eqlBytes @ mem.zig | - | 121 | 2.0% |
| checker.Checker.symbol_flags @ checker.zig | checker.Checker.symbol_is_value_ex | 115 | 1.9% |
| checker.Checker.is_declaration_contained_in @ checker.zig | checker.Checker.get_named_members | 105 | 1.8% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 @ runtime.zig | ast.Ast.kind | 100 | 1.7% |
| checker.Checker.could_contain_type_variables @ checker.zig | checker.Checker.instantiate_symbol | 86 | 1.4% |
| rig.runtime.atProven @ runtime.zig | __rig_std_text.Interner.find | 85 | 1.4% |
| rig.runtime.ListOf(checker.Loc,0).at__func_3750 @ runtime.zig | checker.Ids.sym_file_of | 81 | 1.4% |
| rig.runtime.ListOf(u32,0).atProven @ runtime.zig | __rig_std_text.Interner.find | 68 | 1.1% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | ast.Ast.word_node | 67 | 1.1% |
| rig.ordered.Ordered(u32,u32).findHashed @ ordered.zig | rig.ordered.Ordered(u32,u32).get | 65 | 1.1% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).findIndexed | 64 | 1.1% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | ast.Ast.word_list | 62 | 1.0% |
| rig.table.Table(checker.Type,134217728).at @ table.zig | checker.Checker.type_flags | 61 | 1.0% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at @ table.zig | checker.Checker.type_node_links_outer_type_parameters | 60 | 1.0% |
| rig.alloc.alloc @ alloc.zig | - | 57 | 1.0% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).findIndexed | 55 | 0.9% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CachedTypeKey,u32).match | 50 | 0.8% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | checker.Checker.node_symbol | 49 | 0.8% |
| rig.ordered.Ordered(u32,u32).matchAll @ ordered.zig | rig.ordered.Ordered(u32,u32).match | 48 | 0.8% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 @ runtime.zig | ast.Ast.initializer | 48 | 0.8% |
| binder.Binder.bind_each_statement_functions_first @ binder.zig | - | 47 | 0.8% |
| checker.Checker.instantiate_symbol @ checker.zig | - | 46 | 0.8% |
| checker.Checker.could_contain_type_variables @ checker.zig | checker.Checker.instantiate_type_with_alias | 44 | 0.7% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 @ runtime.zig | ast.Ast.pos | 42 | 0.7% |
| checker.Checker.is_reserved_member_name @ checker.zig | checker.Checker.is_named_member | 41 | 0.7% |

## cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp: 4841 samples

| innermost function | samples | share |
|---|---:|---:|
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 | 303 | 6.3% |
| rig.table.Table(u32,268435456).at | 296 | 6.1% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at | 214 | 4.4% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).findIndexed | 194 | 4.0% |
| rig.ordered.Ordered(checker.CacheKey,u32).findIndexed | 151 | 3.1% |
| checker.Checker.could_contain_type_variables | 132 | 2.7% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch | 132 | 2.7% |
| rig.table.Table(checker.Signature,33554432).at | 131 | 2.7% |
| rig.table.Table(checker.StructuredType,67108864).at | 115 | 2.4% |
| rig.runtime.ListOf(u32,0).at__func_1276 | 111 | 2.3% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch | 106 | 2.2% |
| checker.Checker.symbol_flags | 103 | 2.1% |
| rig.runtime.ListOf(u32,0).atProven | 94 | 1.9% |
| rig.table.Table(checker.UnionOrIntersectionType,67108864).at | 88 | 1.8% |
| rig.table.Table(checker.Type,134217728).at | 83 | 1.7% |
| rig.ordered.Ordered(u32,u32).findHashed | 81 | 1.7% |
| mem.eqlBytes | 73 | 1.5% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at | 73 | 1.5% |
| rig.runtime.ListOf(checker.Loc,0).at__func_3750 | 69 | 1.4% |
| rig.table.Table(checker.TypeReference,67108864).at | 68 | 1.4% |
| checker.Checker.is_declaration_contained_in | 68 | 1.4% |
| checker.Checker.type_mapper | 66 | 1.4% |
| rig.table.Table(checker.TypeMapper,16777216).at | 64 | 1.3% |
| checker.Checker.get_non_distributed_type_parameter | 54 | 1.1% |
| checker.Checker.type_target | 54 | 1.1% |
| checker.Checker.is_reserved_member_name | 40 | 0.8% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll | 40 | 0.8% |
| rig.table.Table(checker.InterfaceType,67108864).at | 40 | 0.8% |
| rig.runtime.ListOf(ast.ListRec,0).at__func_1278 | 40 | 0.8% |
| rig.table.Table(checker.ConditionalType,67108864).at | 38 | 0.8% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| rig.table.Table(u32,268435456).at @ table.zig | rig.table.Table(u32,268435456).atInt | 296 | 6.1% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at @ table.zig | checker.Checker.value_symbol_links_resolved_type | 213 | 4.4% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).findIndexed @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).findHashed | 194 | 4.0% |
| rig.ordered.Ordered(checker.CacheKey,u32).findIndexed @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).findHashed | 151 | 3.1% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).findIndexed | 128 | 2.6% |
| checker.Checker.could_contain_type_variables @ checker.zig | checker.Checker.instantiate_symbol | 111 | 2.3% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).findIndexed | 106 | 2.2% |
| rig.table.Table(checker.Signature,33554432).at @ table.zig | checker.Checker.signature_type_parameters | 83 | 1.7% |
| checker.Checker.symbol_flags @ checker.zig | checker.Checker.symbol_is_value_ex | 83 | 1.7% |
| rig.ordered.Ordered(u32,u32).findHashed @ ordered.zig | rig.ordered.Ordered(u32,u32).get | 81 | 1.7% |
| rig.runtime.ListOf(u32,0).atProven @ runtime.zig | __rig_std_text.Interner.find | 77 | 1.6% |
| mem.eqlBytes @ mem.zig | - | 73 | 1.5% |
| checker.Checker.is_declaration_contained_in @ checker.zig | checker.Checker.get_named_members | 68 | 1.4% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at @ table.zig | checker.Checker.type_node_links_outer_type_parameters | 67 | 1.4% |
| checker.Checker.type_mapper @ checker.zig | checker.Checker.get_object_type_instantiation | 65 | 1.3% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 @ runtime.zig | ast.Ast.pos | 65 | 1.3% |
| rig.table.Table(checker.TypeMapper,16777216).at @ table.zig | checker.Checker.mapper_kind | 57 | 1.2% |
| rig.table.Table(checker.TypeReference,67108864).at @ table.zig | checker.Checker.reference_node | 53 | 1.1% |
| checker.Checker.get_non_distributed_type_parameter @ checker.zig | checker.Checker.get_mapped_type | 51 | 1.1% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 @ runtime.zig | ast.Ast.kind | 50 | 1.0% |
| rig.runtime.ListOf(checker.Loc,0).at__func_3750 @ runtime.zig | checker.Ids.sym_file_of | 49 | 1.0% |
| rig.table.Table(checker.Type,134217728).at @ table.zig | checker.Checker.type_flags | 48 | 1.0% |
| rig.table.Table(checker.UnionOrIntersectionType,67108864).at @ table.zig | checker.Checker.union_or_intersection_types | 46 | 1.0% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 @ runtime.zig | ast.Ast.is_export_declaration | 43 | 0.9% |
| rig.table.Table(checker.StructuredType,67108864).at @ table.zig | checker.Checker.structured_signatures | 43 | 0.9% |
| rig.table.Table(checker.UnionOrIntersectionType,67108864).at @ table.zig | checker.Checker.union_origin | 42 | 0.9% |
| checker.Checker.is_reserved_member_name @ checker.zig | checker.Checker.is_named_member | 40 | 0.8% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).match | 40 | 0.8% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | checker.Checker.node_symbol | 38 | 0.8% |
| rig.table.Table(checker.StructuredType,67108864).at @ table.zig | checker.Checker.structured_members | 37 | 0.8% |
