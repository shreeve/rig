
## cpu_core/ld_blocks.store_forward,period=1301/upp: 16115 samples

| innermost function | samples | share |
|---|---:|---:|
| checker.Checker.get_relater | 794 | 4.9% |
| rig.runtime.Niche(checker.Relater,.{ .offset = 89, .Word = u8, .value = 2, .spare = 254 }) | 651 | 4.0% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll | 559 | 3.5% |
| mem.swap__func_3831 | 523 | 3.2% |
| checker.Checker.is_simple_type_related_to_ex | 417 | 2.6% |
| checker.Checker.get_type_from_type_node_worker | 366 | 2.3% |
| compiler_rt.memcpy.copyBlocks | 324 | 2.0% |
| rig.ordered.Ordered(checker.CacheKey,u32).findIndexed | 317 | 2.0% |
| checker.Checker.instantiate_type_with_alias | 261 | 1.6% |
| checker.Checker.mapper_map | 251 | 1.6% |
| rig.runtime.ListOf(checker.Relater,0).pop | 232 | 1.4% |
| ast.Ast.is_tuple_type_node | 224 | 1.4% |
| atomic.Value(u32).load | 192 | 1.2% |
| checker.is_unary_tuple_type_node | 185 | 1.1% |
| checker.Checker.is_type_related_to | 170 | 1.1% |
| checker.KeyBuilder.write_uint32 | 151 | 0.9% |
| rig.table.Table(checker.Type,134217728).constSlot | 151 | 0.9% |
| checker.Checker.get_conditional_type_instantiation_of | 148 | 0.9% |
| rig.runtime.ListOf(u32,0).push | 144 | 0.9% |
| rig.table.Table(u32,268435456).push | 144 | 0.9% |
| checker.Checker.instantiate_types | 143 | 0.9% |
| rig.runtime.foldMul | 129 | 0.8% |
| checker.Checker.get_conditional_flow_type_of_type | 125 | 0.8% |
| rig.table.Table(checker.Type,134217728).at | 122 | 0.8% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 | 116 | 0.7% |
| rig.alloc.alloc | 114 | 0.7% |
| checker.Checker.new_type_list | 111 | 0.7% |
| checker.Checker.get_relation_key | 110 | 0.7% |
| checker.KeyBuilder.mix | 107 | 0.7% |
| checker.Checker.get_object_type_instantiation | 103 | 0.6% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| checker.Checker.get_relater @ checker.zig | checker.Checker.check_type_related_to_ex_output | 794 | 4.9% |
| rig.runtime.Niche(checker.Relater,.{ .offset = 89, .Word = u8, .value = 2, .spare = 254 }) @ runtime.zig | rig.runtime.some | 651 | 4.0% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).match | 534 | 3.3% |
| mem.swap__func_3831 @ mem.zig | rig.runtime.swap__func_3827 | 523 | 3.2% |
| checker.Checker.is_simple_type_related_to_ex @ checker.zig | - | 417 | 2.6% |
| checker.Checker.get_type_from_type_node_worker @ checker.zig | - | 366 | 2.3% |
| compiler_rt.memcpy.copyBlocks @ memcpy.zig | compiler_rt.memcpy.copyBlocksAlignedSource | 324 | 2.0% |
| rig.ordered.Ordered(checker.CacheKey,u32).findIndexed @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).findHashed | 317 | 2.0% |
| checker.Checker.mapper_map @ checker.zig | - | 251 | 1.6% |
| checker.Checker.instantiate_type_with_alias @ checker.zig | - | 249 | 1.5% |
| rig.runtime.ListOf(checker.Relater,0).pop @ runtime.zig | checker.Checker.get_relater | 232 | 1.4% |
| ast.Ast.is_tuple_type_node @ ast.zig | checker.is_unary_tuple_type_node | 222 | 1.4% |
| checker.is_unary_tuple_type_node @ checker.zig | checker.Checker.get_implied_constraint | 185 | 1.1% |
| checker.Checker.is_type_related_to @ checker.zig | - | 170 | 1.1% |
| atomic.Value(u32).load @ atomic.zig | rig.sched.Flag.load__func_279 | 169 | 1.0% |
| checker.KeyBuilder.write_uint32 @ checker.zig | checker.KeyBuilder.write_type | 151 | 0.9% |
| rig.table.Table(checker.Type,134217728).constSlot @ table.zig | rig.table.Table(checker.Type,134217728).at | 151 | 0.9% |
| checker.Checker.get_conditional_type_instantiation_of @ checker.zig | - | 147 | 0.9% |
| checker.Checker.instantiate_types @ checker.zig | - | 138 | 0.9% |
| rig.runtime.foldMul @ runtime.zig | rig.runtime.hashWords | 129 | 0.8% |
| rig.alloc.alloc @ alloc.zig | - | 114 | 0.7% |
| checker.Checker.get_relation_key @ checker.zig | - | 110 | 0.7% |
| checker.Checker.get_object_type_instantiation @ checker.zig | checker.Checker.instantiate_type_worker | 103 | 0.6% |
| checker.Checker.is_type_reference_with_generic_arguments @ checker.zig | - | 101 | 0.6% |
| checker.Checker.get_conditional_flow_type_of_type @ checker.zig | - | 99 | 0.6% |
| rig.table.Table(checker.Type,134217728).at @ table.zig | checker.Checker.type_flags | 98 | 0.6% |
| __rig_std_sort.insertion__func_3822 @ __rig_std_sort.zig | __rig_std_sort.sort_by__func_3820 | 98 | 0.6% |
| checker.Checker.check_type_related_to_ex_output @ checker.zig | - | 95 | 0.6% |
| checker.Checker.is_unknown_like_union_type @ checker.zig | - | 95 | 0.6% |
| checker.Checker.instantiate_type_worker @ checker.zig | - | 94 | 0.6% |

## cpu_core/mem_load_retired.l3_miss,period=97/upp: 15742 samples

| innermost function | samples | share |
|---|---:|---:|
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll | 1877 | 11.9% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll | 1567 | 10.0% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch | 689 | 4.4% |
| compiler_rt.memcpy.copyBlocks | 646 | 4.1% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch | 641 | 4.1% |
| rig.table.Table(u32,268435456).at | 606 | 3.8% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll | 533 | 3.4% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 | 499 | 3.2% |
| rig.runtime.ListOf(u32,0).at__func_1276 | 407 | 2.6% |
| rig.ordered.Ordered(u32,checker.MappedSymbolLinks).matchAll | 383 | 2.4% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).eqlKey | 279 | 1.8% |
| rig.table.Table(checker.Type,134217728).at | 274 | 1.7% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at | 259 | 1.6% |
| rig.table.Table(checker.TypeMapper,16777216).at | 229 | 1.5% |
| checker.Checker.could_contain_type_variables | 206 | 1.3% |
| rig.table.Table(checker.StructuredType,67108864).at | 199 | 1.3% |
| rig.ordered.Ordered(u32,u32).findHashed | 192 | 1.2% |
| ast.Ast.is_parenthesized_type_node | 191 | 1.2% |
| checker.Checker.type_target | 187 | 1.2% |
| rig.table.Table(checker.ConditionalType,67108864).at | 183 | 1.2% |
| rig.ordered.Ordered(u32,u32).matchAll | 170 | 1.1% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at | 149 | 0.9% |
| rig.runtime.ListOf(u32,0).atProven | 147 | 0.9% |
| rig.runtime.eqlAs__func_4378 | 137 | 0.9% |
| rig.table.Table(checker.UnionOrIntersectionType,67108864).at | 124 | 0.8% |
| rig.runtime.ListOf(ast.ListRec,0).at__func_1278 | 112 | 0.7% |
| checker.Checker.symbol_flags | 112 | 0.7% |
| rig.ordered.Ordered(checker.CachedSignatureKey,u32).matchAll | 105 | 0.7% |
| rig.table.Table(checker.Signature,33554432).at | 103 | 0.7% |
| rig.runtime.atProven | 101 | 0.6% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).match | 1877 | 11.9% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).match | 1567 | 10.0% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).findIndexed | 689 | 4.4% |
| compiler_rt.memcpy.copyBlocks @ memcpy.zig | compiler_rt.memcpy.copyBlocksAlignedSource | 646 | 4.1% |
| rig.table.Table(u32,268435456).at @ table.zig | rig.table.Table(u32,268435456).atInt | 606 | 3.8% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).findIndexed | 590 | 3.7% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CachedTypeKey,u32).match | 533 | 3.4% |
| rig.ordered.Ordered(u32,checker.MappedSymbolLinks).matchAll @ ordered.zig | rig.ordered.Ordered(u32,checker.MappedSymbolLinks).match | 383 | 2.4% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).eqlKey @ ordered.zig | rig.ordered.Ordered(checker.CachedTypeKey,u32).keyMatch | 279 | 1.8% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at @ table.zig | checker.Checker.value_symbol_links_resolved_type | 234 | 1.5% |
| rig.table.Table(checker.TypeMapper,16777216).at @ table.zig | checker.Checker.mapper_kind | 225 | 1.4% |
| rig.table.Table(checker.Type,134217728).at @ table.zig | checker.Checker.type_flags | 209 | 1.3% |
| rig.ordered.Ordered(u32,u32).findHashed @ ordered.zig | rig.ordered.Ordered(u32,u32).get | 191 | 1.2% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 @ runtime.zig | ast.Ast.kind | 184 | 1.2% |
| ast.Ast.is_parenthesized_type_node @ ast.zig | ast.Ast.skip_type_parentheses | 168 | 1.1% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at @ table.zig | checker.Checker.type_node_links_outer_type_parameters | 128 | 0.8% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | ast.Ast.word_list | 119 | 0.8% |
| checker.Checker.could_contain_type_variables @ checker.zig | checker.Checker.instantiate_type_with_alias | 112 | 0.7% |
| rig.table.Table(checker.StructuredType,67108864).at @ table.zig | checker.Checker.structured_target | 112 | 0.7% |
| checker.Checker.type_target @ checker.zig | checker.Checker.is_tuple_type | 108 | 0.7% |
| rig.ordered.Ordered(checker.CachedSignatureKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CachedSignatureKey,u32).match | 105 | 0.7% |
| rig.runtime.ListOf(u32,0).atProven @ runtime.zig | __rig_std_text.Interner.find | 103 | 0.7% |
| checker.Checker.symbol_flags @ checker.zig | checker.Checker.symbol_is_value_ex | 97 | 0.6% |
| rig.runtime.ListOf(ast.ListRec,0).at__func_1278 @ runtime.zig | ast.Ast.nodes | 96 | 0.6% |
| rig.runtime.eqlAs__func_4378 @ runtime.zig | rig.runtime.eqlAs__func_4672 | 95 | 0.6% |
| checker.Checker.get_generic_object_flags @ checker.zig | checker.Checker.is_generic_type | 94 | 0.6% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | checker.Checker.conditional_flow_step | 94 | 0.6% |
| rig.ordered.Ordered(u32,u32).matchAll @ ordered.zig | rig.ordered.Ordered(u32,u32).findSmall | 89 | 0.6% |
| rig.table.Table(checker.ConditionalType,67108864).at @ table.zig | checker.Checker.conditional_mapper | 89 | 0.6% |
| checker.Checker.get_type_from_type_reference @ checker.zig | - | 89 | 0.6% |

## cpu_core/mem_load_retired.l2_miss,period=307/upp: 16040 samples

| innermost function | samples | share |
|---|---:|---:|
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll | 2114 | 13.2% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll | 1672 | 10.4% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll | 795 | 5.0% |
| rig.table.Table(u32,268435456).at | 631 | 3.9% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 | 582 | 3.6% |
| compiler_rt.memcpy.copyBlocks | 442 | 2.8% |
| rig.runtime.ListOf(u32,0).at__func_1276 | 391 | 2.4% |
| rig.ordered.Ordered(u32,checker.MappedSymbolLinks).matchAll | 344 | 2.1% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch | 337 | 2.1% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch | 274 | 1.7% |
| checker.Checker.could_contain_type_variables | 260 | 1.6% |
| rig.table.Table(checker.Type,134217728).at | 259 | 1.6% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at | 234 | 1.5% |
| rig.table.Table(checker.TypeMapper,16777216).at | 226 | 1.4% |
| rig.table.Table(checker.ConditionalType,67108864).at | 193 | 1.2% |
| rig.table.Table(checker.StructuredType,67108864).at | 183 | 1.1% |
| ast.Ast.is_parenthesized_type_node | 179 | 1.1% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at | 174 | 1.1% |
| rig.runtime.ListOf(checker.Loc,0).at__func_3750 | 174 | 1.1% |
| checker.Checker.type_target | 160 | 1.0% |
| rig.ordered.Ordered(u32,u32).matchAll | 158 | 1.0% |
| checker.Checker.get_non_distributed_type_parameter | 158 | 1.0% |
| rig.ordered.Ordered(u32,u32).findHashed | 154 | 1.0% |
| checker.Checker.is_declaration_contained_in | 153 | 1.0% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).eqlKey | 147 | 0.9% |
| rig.runtime.ListOf(u32,0).atProven | 147 | 0.9% |
| rig.table.Table(checker.UnionOrIntersectionType,67108864).at | 138 | 0.9% |
| checker.Checker.symbol_flags | 127 | 0.8% |
| checker.Checker.get_type_from_type_reference | 119 | 0.7% |
| rig.runtime.ListOf(ast.ListRec,0).at__func_1278 | 117 | 0.7% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).match | 2114 | 13.2% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).match | 1671 | 10.4% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CachedTypeKey,u32).match | 795 | 5.0% |
| rig.table.Table(u32,268435456).at @ table.zig | rig.table.Table(u32,268435456).atInt | 631 | 3.9% |
| compiler_rt.memcpy.copyBlocks @ memcpy.zig | compiler_rt.memcpy.copyBlocksAlignedSource | 442 | 2.8% |
| rig.ordered.Ordered(u32,checker.MappedSymbolLinks).matchAll @ ordered.zig | rig.ordered.Ordered(u32,checker.MappedSymbolLinks).match | 344 | 2.1% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).findIndexed | 337 | 2.1% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).findIndexed | 250 | 1.6% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at @ table.zig | checker.Checker.value_symbol_links_resolved_type | 216 | 1.3% |
| rig.table.Table(checker.TypeMapper,16777216).at @ table.zig | checker.Checker.mapper_kind | 206 | 1.3% |
| rig.table.Table(checker.Type,134217728).at @ table.zig | checker.Checker.type_flags | 192 | 1.2% |
| checker.Checker.could_contain_type_variables @ checker.zig | checker.Checker.instantiate_type_with_alias | 177 | 1.1% |
| ast.Ast.is_parenthesized_type_node @ ast.zig | ast.Ast.skip_type_parentheses | 157 | 1.0% |
| rig.runtime.ListOf(checker.Loc,0).at__func_3750 @ runtime.zig | checker.Ids.sym_file_of | 156 | 1.0% |
| checker.Checker.get_non_distributed_type_parameter @ checker.zig | checker.Checker.get_mapped_type | 155 | 1.0% |
| rig.ordered.Ordered(u32,u32).findHashed @ ordered.zig | rig.ordered.Ordered(u32,u32).get | 154 | 1.0% |
| checker.Checker.is_declaration_contained_in @ checker.zig | checker.Checker.get_named_members | 153 | 1.0% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).eqlKey @ ordered.zig | rig.ordered.Ordered(checker.CachedTypeKey,u32).keyMatch | 147 | 0.9% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | checker.Checker.conditional_flow_step | 142 | 0.9% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at @ table.zig | checker.Checker.type_node_links_outer_type_parameters | 139 | 0.9% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 @ runtime.zig | ast.Ast.kind | 129 | 0.8% |
| checker.Checker.get_type_from_type_reference @ checker.zig | - | 119 | 0.7% |
| checker.Checker.symbol_flags @ checker.zig | checker.Checker.symbol_is_value_ex | 112 | 0.7% |
| rig.runtime.atProven @ runtime.zig | __rig_std_text.Interner.find | 107 | 0.7% |
| mem.eqlBytes @ mem.zig | - | 104 | 0.6% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 @ runtime.zig | ast.Ast.pos | 99 | 0.6% |
| rig.runtime.ListOf(ast.ListRec,0).at__func_1278 @ runtime.zig | ast.Ast.nodes | 97 | 0.6% |
| rig.table.Table(checker.ConditionalType,67108864).at @ table.zig | checker.Checker.conditional_root | 96 | 0.6% |
| rig.ordered.Ordered(checker.CachedSignatureKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CachedSignatureKey,u32).match | 94 | 0.6% |
| rig.ordered.Ordered(u32,u32).matchAll @ ordered.zig | rig.ordered.Ordered(u32,u32).match | 90 | 0.6% |

## cpu_core/mem_load_retired.l1_miss,period=4001/upp: 16228 samples

| innermost function | samples | share |
|---|---:|---:|
| rig.table.Table(checker.Type,134217728).at | 684 | 4.2% |
| rig.table.Table(u32,268435456).at | 661 | 4.1% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 | 652 | 4.0% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll | 511 | 3.1% |
| checker.Checker.could_contain_type_variables | 481 | 3.0% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at | 415 | 2.6% |
| rig.runtime.ListOf(checker.Loc,0).at__func_3750 | 381 | 2.3% |
| rig.alloc.alloc | 372 | 2.3% |
| rig.runtime.ListOf(u32,0).at__func_1276 | 355 | 2.2% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll | 352 | 2.2% |
| compiler_rt.memcpy.copyBlocks | 311 | 1.9% |
| checker.Checker.get_non_distributed_type_parameter | 273 | 1.7% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll | 263 | 1.6% |
| checker.Checker.symbol_value_declaration | 261 | 1.6% |
| checker.Checker.symbol_flags | 235 | 1.4% |
| checker.Checker.is_declaration_contained_in | 206 | 1.3% |
| rig.alloc.free | 200 | 1.2% |
| rig.table.Table(checker.StructuredType,67108864).at | 200 | 1.2% |
| rig.runtime.ListOf(u32,0).atProven | 194 | 1.2% |
| rig.table.Table(checker.TypeMapper,16777216).at | 178 | 1.1% |
| rig.runtime.index__func_1313 | 174 | 1.1% |
| ast.Ast.is_parenthesized_type_node | 173 | 1.1% |
| rig.table.Table(checker.ConditionalType,67108864).at | 161 | 1.0% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at | 160 | 1.0% |
| checker.Checker.type_target | 157 | 1.0% |
| rig.table.Table(checker.TypeReference,67108864).at | 150 | 0.9% |
| rig.table.Table(checker.UnionOrIntersectionType,67108864).at | 150 | 0.9% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch | 146 | 0.9% |
| rig.ordered.Ordered(u32,u32).findHashed | 134 | 0.8% |
| rig.ordered.Ordered(u64,void).matchAll | 133 | 0.8% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| rig.table.Table(u32,268435456).at @ table.zig | rig.table.Table(u32,268435456).atInt | 661 | 4.1% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).match | 511 | 3.1% |
| rig.table.Table(checker.Type,134217728).at @ table.zig | checker.Checker.type_flags | 444 | 2.7% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at @ table.zig | checker.Checker.value_symbol_links_resolved_type | 386 | 2.4% |
| rig.alloc.alloc @ alloc.zig | - | 372 | 2.3% |
| rig.runtime.ListOf(checker.Loc,0).at__func_3750 @ runtime.zig | checker.Ids.sym_file_of | 350 | 2.2% |
| checker.Checker.could_contain_type_variables @ checker.zig | checker.Checker.instantiate_type_with_alias | 345 | 2.1% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).match | 343 | 2.1% |
| compiler_rt.memcpy.copyBlocks @ memcpy.zig | compiler_rt.memcpy.copyBlocksAlignedSource | 311 | 1.9% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CachedTypeKey,u32).match | 263 | 1.6% |
| checker.Checker.get_non_distributed_type_parameter @ checker.zig | checker.Checker.get_mapped_type | 259 | 1.6% |
| checker.Checker.symbol_flags @ checker.zig | checker.Checker.symbol_is_value_ex | 219 | 1.3% |
| checker.Checker.is_declaration_contained_in @ checker.zig | checker.Checker.get_named_members | 206 | 1.3% |
| rig.alloc.free @ alloc.zig | - | 200 | 1.2% |
| rig.table.Table(checker.TypeMapper,16777216).at @ table.zig | checker.Checker.mapper_kind | 162 | 1.0% |
| ast.Ast.is_parenthesized_type_node @ ast.zig | ast.Ast.skip_type_parentheses | 157 | 1.0% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 @ runtime.zig | ast.Ast.kind | 152 | 0.9% |
| rig.runtime.ListOf(u32,0).atProven @ runtime.zig | __rig_std_text.Interner.text | 147 | 0.9% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).findIndexed | 146 | 0.9% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 @ runtime.zig | ast.Ast.is_property_declaration | 145 | 0.9% |
| rig.ordered.Ordered(u64,void).matchAll @ ordered.zig | rig.ordered.Ordered(u64,void).match | 133 | 0.8% |
| rig.ordered.Ordered(u32,u32).findHashed @ ordered.zig | rig.ordered.Ordered(u32,u32).get | 132 | 0.8% |
| checker.Checker.instantiate_symbol @ checker.zig | - | 131 | 0.8% |
| checker.Checker.symbol_value_declaration @ checker.zig | checker.Checker.is_static_private_identifier_property | 126 | 0.8% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at @ table.zig | checker.Checker.type_node_links_outer_type_parameters | 122 | 0.8% |
| checker.Checker.is_reserved_member_name @ checker.zig | checker.Checker.is_named_member | 118 | 0.7% |
| checker.Checker.could_contain_type_variables @ checker.zig | checker.Checker.instantiate_symbol | 115 | 0.7% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | checker.Checker.conditional_flow_step | 102 | 0.6% |
| checker.Checker.type_target @ checker.zig | checker.Checker.is_tuple_type | 100 | 0.6% |
| rig.runtime.ListOf(u32,0).at__func_1276 @ runtime.zig | __rig_std_text.Interner.text | 98 | 0.6% |

## cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp: 15089 samples

| innermost function | samples | share |
|---|---:|---:|
| rig.ordered.Ordered(checker.InstantiationKey,u32).findIndexed | 2392 | 15.9% |
| rig.ordered.Ordered(checker.CacheKey,u32).findIndexed | 1772 | 11.7% |
| rig.table.Table(u32,268435456).at | 759 | 5.0% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).findIndexed | 707 | 4.7% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll | 699 | 4.6% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll | 568 | 3.8% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch | 480 | 3.2% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch | 458 | 3.0% |
| rig.ordered.Ordered(u32,checker.MappedSymbolLinks).findIndexed | 411 | 2.7% |
| rig.runtime.ListOf(ast.NodeRec,0).at__func_1192 | 306 | 2.0% |
| rig.table.Table(checker.UnionOrIntersectionType,67108864).at | 247 | 1.6% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at | 234 | 1.6% |
| rig.table.Table(checker.TypeMapper,16777216).at | 228 | 1.5% |
| rig.table.Table(checker.ConditionalType,67108864).at | 228 | 1.5% |
| checker.Checker.type_target | 224 | 1.5% |
| rig.table.Table(checker.Type,134217728).at | 211 | 1.4% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll | 191 | 1.3% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).eqlKey | 168 | 1.1% |
| rig.table.Table(checker.Signature,33554432).at | 163 | 1.1% |
| rig.ordered.Ordered(u32,u32).findHashed | 160 | 1.1% |
| checker.Checker.could_contain_type_variables | 155 | 1.0% |
| rig.ordered.Ordered(u32,checker.MappedSymbolLinks).matchAll | 155 | 1.0% |
| rig.runtime.ListOf(u32,0).atProven | 152 | 1.0% |
| rig.table.Table(checker.TypeReference,67108864).at | 117 | 0.8% |
| checker.Checker.get_non_distributed_type_parameter | 117 | 0.8% |
| rig.table.Table(checker.StructuredType,67108864).at | 116 | 0.8% |
| rig.table.Table(checker.IndexedAccessType,67108864).at | 116 | 0.8% |
| rig.runtime.ListOf(checker.Loc,0).at__func_3750 | 110 | 0.7% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at | 104 | 0.7% |
| rig.ordered.Ordered(checker.CachedSignatureKey,u32).findIndexed | 103 | 0.7% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| rig.ordered.Ordered(checker.InstantiationKey,u32).findIndexed @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).findHashed | 2392 | 15.9% |
| rig.ordered.Ordered(checker.CacheKey,u32).findIndexed @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).findHashed | 1772 | 11.7% |
| rig.table.Table(u32,268435456).at @ table.zig | rig.table.Table(u32,268435456).atInt | 759 | 5.0% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).findIndexed @ ordered.zig | rig.ordered.Ordered(checker.CachedTypeKey,u32).findHashed | 707 | 4.7% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).match | 699 | 4.6% |
| rig.ordered.Ordered(checker.CacheKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).match | 568 | 3.8% |
| rig.ordered.Ordered(checker.InstantiationKey,u32).keyMatch @ ordered.zig | rig.ordered.Ordered(checker.InstantiationKey,u32).findIndexed | 458 | 3.0% |
| rig.ordered.Ordered(checker.CacheKey,u32).keyMatch @ ordered.zig | rig.ordered.Ordered(checker.CacheKey,u32).findIndexed | 453 | 3.0% |
| rig.ordered.Ordered(u32,checker.MappedSymbolLinks).findIndexed @ ordered.zig | rig.ordered.Ordered(u32,checker.MappedSymbolLinks).findHashed | 411 | 2.7% |
| rig.table.Table(checker.ValueSymbolLinks,134217728).at @ table.zig | checker.Checker.value_symbol_links_resolved_type | 225 | 1.5% |
| rig.table.Table(checker.TypeMapper,16777216).at @ table.zig | checker.Checker.mapper_kind | 221 | 1.5% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).matchAll @ ordered.zig | rig.ordered.Ordered(checker.CachedTypeKey,u32).match | 191 | 1.3% |
| rig.table.Table(checker.UnionOrIntersectionType,67108864).at @ table.zig | checker.Checker.union_or_intersection_types | 176 | 1.2% |
| rig.ordered.Ordered(checker.CachedTypeKey,u32).eqlKey @ ordered.zig | rig.ordered.Ordered(checker.CachedTypeKey,u32).keyMatch | 168 | 1.1% |
| rig.ordered.Ordered(u32,u32).findHashed @ ordered.zig | rig.ordered.Ordered(u32,u32).get | 160 | 1.1% |
| rig.ordered.Ordered(u32,checker.MappedSymbolLinks).matchAll @ ordered.zig | rig.ordered.Ordered(u32,checker.MappedSymbolLinks).match | 155 | 1.0% |
| rig.table.Table(checker.Type,134217728).at @ table.zig | checker.Checker.type_flags | 153 | 1.0% |
| rig.table.Table(checker.ConditionalType,67108864).at @ table.zig | checker.Checker.conditional_mapper | 128 | 0.8% |
| checker.Checker.type_target @ checker.zig | checker.Checker.is_tuple_type | 125 | 0.8% |
| rig.runtime.ListOf(u32,0).atProven @ runtime.zig | __rig_std_text.Interner.find | 124 | 0.8% |
| rig.table.Table(checker.Signature,33554432).at @ table.zig | checker.Checker.signature_type_parameters | 115 | 0.8% |
| rig.table.Table(checker.IndexedAccessType,67108864).at @ table.zig | checker.Checker.indexed_access_object_type | 109 | 0.7% |
| checker.Checker.get_non_distributed_type_parameter @ checker.zig | checker.Checker.get_mapped_type | 108 | 0.7% |
| rig.ordered.Ordered(checker.CachedSignatureKey,u32).findIndexed @ ordered.zig | rig.ordered.Ordered(checker.CachedSignatureKey,u32).findHashed | 103 | 0.7% |
| rig.table.Table(checker.SubstitutionType,67108864).at @ table.zig | checker.Checker.substitution_base_type | 98 | 0.6% |
| checker.Checker.symbol_flags @ checker.zig | checker.Checker.symbol_is_value_ex | 96 | 0.6% |
| rig.table.Table(checker.ConditionalType,67108864).at @ table.zig | checker.Checker.conditional_root | 95 | 0.6% |
| rig.table.Table(checker.IndexType,67108864).at @ table.zig | checker.Checker.index_type_target | 92 | 0.6% |
| rig.table.Table(checker.TypeNodeLinks,134217728).at @ table.zig | checker.Checker.type_node_links_outer_type_parameters | 87 | 0.6% |
| rig.table.Table(checker.CheckerSymbol,67108864).at @ table.zig | rig.table.Table(checker.CheckerSymbol,67108864).atInt | 87 | 0.6% |
