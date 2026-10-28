
## cpu_core/mem_load_retired.l2_miss,period=307/upp: 12892 samples

| innermost function | samples | share |
|---|---:|---:|
| copy_nonoverlapping<u8> | 3792 | 29.4% |
| mi_page_malloc_zero | 678 | 5.3% |
| get<tsrs_ast::ast::NodeHeaderWord> | 662 | 5.1% |
| likely | 591 | 4.6% |
| eq | 484 | 3.8% |
| intersects | 453 | 3.5% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo | 425 | 3.3% |
| {closure#0}<u64, hashbrown::alloc::inner::Global, tsrs_checker::relater_1::{impl#0}::looku | 310 | 2.4% |
| {closure#0} | 276 | 2.1% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_checker::types::Type>>> | 227 | 1.8% |
| get<u64> | 225 | 1.7% |
| <tsrs_checker::checker::Checker>::source_file_and_index_of_node | 217 | 1.7% |
| data | 166 | 1.3% |
| {closure#0}<tsrs_core::ptr::P<tsrs_checker::types::Type>, hashbrown::alloc::inner::Global, | 157 | 1.2% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>>> | 153 | 1.2% |
| fold<tsrs_ast::symbol::SymbolMapEntry, (), core::iter::adapters::map::map_fold::{closure_e | 122 | 0.9% |
| <tsrs_checker::mapper::TypeMapper>::map | 112 | 0.9% |
| ?? | 102 | 0.8% |
| instantiate_type_with_alias | 93 | 0.7% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> | 89 | 0.7% |
| get<core::option::Option<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_checker::types:: | 85 | 0.7% |
| hash | 81 | 0.6% |
| get<core::option::Option<tsrs_core::ptr::P<[core::cell::Cell<u32>; 128]>>> | 78 | 0.6% |
| is_reserved_member_name | 75 | 0.6% |
| get<&[tsrs_core::ptr::P<tsrs_checker::types::Type>]> | 75 | 0.6% |
| {closure#1}<tsrs_checker::checker::CacheHashKey, tsrs_core::ptr::P<tsrs_checker::types::Ty | 73 | 0.6% |
| could_contain_type_variables | 72 | 0.6% |
| value_declaration | 65 | 0.5% |
| <tsrs_checker::checker::Checker>::get_actual_type_variable | 64 | 0.5% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> | 61 | 0.5% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| copy_nonoverlapping<u8> @ mod.rs | _mm_loadu_si128 | 3792 | 29.4% |
| get<tsrs_ast::ast::NodeHeaderWord> @ cell.rs | get<tsrs_ast::ast::NodeHeaderWord> | 662 | 5.1% |
| mi_page_malloc_zero @ alloc.c | _mi_page_malloc_zero | 512 | 4.0% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo @ raw.rs | find_inner | 425 | 3.3% |
| likely @ util.rs | find_inner | 387 | 3.0% |
| {closure#0}<u64, hashbrown::alloc::inner::Global, tsrs_checker::relater_1::{impl#0}::looku @ raw.rs | find_inner | 310 | 2.4% |
| eq @ checker.rs | {closure#0}<tsrs_checker::checker::CacheHashKey, tsrs_core::ptr::P<tsrs_checker::types::Ty | 224 | 1.7% |
| <tsrs_checker::checker::Checker>::source_file_and_index_of_node @ utilities.rs | - | 217 | 1.7% |
| likely @ mod.rs | find_inner | 201 | 1.6% |
| get<u64> @ cell.rs | get | 174 | 1.3% |
| mi_page_malloc_zero @ alloc.c | mi_theap_xmalloc_small_zero_nonnull | 166 | 1.3% |
| {closure#0}<tsrs_core::ptr::P<tsrs_checker::types::Type>, hashbrown::alloc::inner::Global, @ raw.rs | find_inner | 157 | 1.2% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>>> @ cell.rs | get<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>> | 153 | 1.2% |
| {closure#0} @ checker_01.rs | tsrs_core::core_go::get_spelling_suggestion_worker::<tsrs_core::ptr::P<tsrs_ast::symbol::S | 144 | 1.1% |
| data @ types.rs | as_type_reference | 137 | 1.1% |
| eq @ checker.rs | eq | 128 | 1.0% |
| fold<tsrs_ast::symbol::SymbolMapEntry, (), core::iter::adapters::map::map_fold::{closure_e @ macros.rs | fold<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>, core::slice::iter::Iter<tsrs_ast::symbol | 122 | 0.9% |
| <tsrs_checker::mapper::TypeMapper>::map @ mapper.rs | - | 112 | 0.9% |
| ?? @ ?? | - | 102 | 0.8% |
| instantiate_type_with_alias @ checker_11.rs | instantiate_type | 93 | 0.7% |
| intersects @ lib.rs | could_contain_type_variables | 90 | 0.7% |
| get<core::option::Option<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_checker::types:: @ cell.rs | get<core::option::Option<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_checker::types:: | 85 | 0.7% |
| hash @ types.rs | {closure#0} | 81 | 0.6% |
| get<core::option::Option<tsrs_core::ptr::P<[core::cell::Cell<u32>; 128]>>> @ cell.rs | narrow_slot<tsrs_checker::types::ValueSymbolLinks> | 78 | 0.6% |
| intersects @ symbolflags.rs | intersects | 76 | 0.6% |
| is_reserved_member_name @ utilities.rs | is_named_member | 75 | 0.6% |
| {closure#1}<tsrs_checker::checker::CacheHashKey, tsrs_core::ptr::P<tsrs_checker::types::Ty @ packedmap.rs | map<&tsrs_checker::packedmap::PackedSlot<tsrs_checker::checker::CacheHashKey, tsrs_core::p | 73 | 0.6% |
| could_contain_type_variables @ checker.rs | <tsrs_checker::checker::Checker>::is_symbol_unaffected_by_instantiation | 69 | 0.5% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> @ cell.rs | get<core::option::Option<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> | 68 | 0.5% |
| get<&[tsrs_core::ptr::P<tsrs_checker::types::Type>]> @ cell.rs | <tsrs_checker::checker::Checker>::get_conditional_type_instantiation_ex | 68 | 0.5% |

## cpu_core/mem_load_retired.l3_miss,period=97/upp: 12243 samples

| innermost function | samples | share |
|---|---:|---:|
| copy_nonoverlapping<u8> | 3025 | 24.7% |
| eq | 923 | 7.5% |
| {closure#0}<u64, hashbrown::alloc::inner::Global, tsrs_checker::relater_1::{impl#0}::looku | 837 | 6.8% |
| likely | 822 | 6.7% |
| get<tsrs_ast::ast::NodeHeaderWord> | 619 | 5.1% |
| intersects | 361 | 2.9% |
| data | 357 | 2.9% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_checker::types::Type>>> | 247 | 2.0% |
| {closure#0} | 213 | 1.7% |
| hash | 213 | 1.7% |
| get<core::option::Option<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_checker::types:: | 207 | 1.7% |
| mi_page_malloc_zero | 204 | 1.7% |
| {closure#0}<tsrs_ast::symbol::Symbol, tsrs_checker::types::MappedSymbolLinks> | 164 | 1.3% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo | 151 | 1.2% |
| get<u64> | 141 | 1.2% |
| {closure#0}<tsrs_core::ptr::P<tsrs_checker::types::Type>, hashbrown::alloc::inner::Global, | 141 | 1.2% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>>> | 124 | 1.0% |
| ?? | 119 | 1.0% |
| eq<tsrs_core::ptr::P<tsrs_ast::flow::FlowNode>> | 97 | 0.8% |
| <tsrs_checker::mapper::TypeMapper>::map | 93 | 0.8% |
| {closure#1}<tsrs_checker::checker::CacheHashKey, tsrs_core::ptr::P<tsrs_checker::types::Ty | 73 | 0.6% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> | 71 | 0.6% |
| deref<tsrs_checker::types::Type> | 70 | 0.6% |
| get<core::option::Option<tsrs_core::ptr::P<[core::cell::Cell<u32>; 128]>>> | 67 | 0.5% |
| traverse | 66 | 0.5% |
| <tsrs_checker::checker::Checker>::get_actual_type_variable | 64 | 0.5% |
| fold<tsrs_ast::symbol::SymbolMapEntry, (), core::iter::adapters::map::map_fold::{closure_e | 63 | 0.5% |
| <tsrs_checker::checker::Checker>::source_file_and_index_of_node | 58 | 0.5% |
| <tsrs_checker::checker::Checker>::instantiate_list::<tsrs_core::ptr::P<tsrs_checker::types | 58 | 0.5% |
| get<u32> | 56 | 0.5% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| copy_nonoverlapping<u8> @ mod.rs | _mm_loadu_si128 | 3016 | 24.6% |
| {closure#0}<u64, hashbrown::alloc::inner::Global, tsrs_checker::relater_1::{impl#0}::looku @ raw.rs | find_inner | 837 | 6.8% |
| likely @ util.rs | find_inner | 646 | 5.3% |
| get<tsrs_ast::ast::NodeHeaderWord> @ cell.rs | get<tsrs_ast::ast::NodeHeaderWord> | 619 | 5.1% |
| eq @ checker.rs | {closure#0}<tsrs_checker::checker::CacheHashKey, tsrs_core::ptr::P<tsrs_checker::types::Ty | 475 | 3.9% |
| data @ types.rs | as_type_reference | 328 | 2.7% |
| eq @ checker.rs | eq | 283 | 2.3% |
| hash @ types.rs | {closure#0} | 213 | 1.7% |
| get<core::option::Option<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_checker::types:: @ cell.rs | get<core::option::Option<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_checker::types:: | 207 | 1.7% |
| likely @ mod.rs | find_inner | 168 | 1.4% |
| {closure#0}<tsrs_ast::symbol::Symbol, tsrs_checker::types::MappedSymbolLinks> @ links.rs | {closure#0}<tsrs_checker::links::LinkSlot, hashbrown::alloc::inner::Global, tsrs_checker:: | 164 | 1.3% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo @ raw.rs | find_inner | 151 | 1.2% |
| {closure#0}<tsrs_core::ptr::P<tsrs_checker::types::Type>, hashbrown::alloc::inner::Global, @ raw.rs | find_inner | 141 | 1.2% |
| mi_page_malloc_zero @ alloc.c | _mi_page_malloc_zero | 126 | 1.0% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>>> @ cell.rs | get<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>> | 124 | 1.0% |
| {closure#0} @ checker_01.rs | tsrs_core::core_go::get_spelling_suggestion_worker::<tsrs_core::ptr::P<tsrs_ast::symbol::S | 124 | 1.0% |
| ?? @ ?? | - | 119 | 1.0% |
| get<u64> @ cell.rs | get | 115 | 0.9% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_checker::types::Type>>> @ cell.rs | resolved_type_of_value_symbol | 104 | 0.8% |
| eq<tsrs_core::ptr::P<tsrs_ast::flow::FlowNode>> @ option.rs | lookup | 97 | 0.8% |
| <tsrs_checker::mapper::TypeMapper>::map @ mapper.rs | - | 93 | 0.8% |
| mi_page_malloc_zero @ alloc.c | mi_theap_xmalloc_small_zero_nonnull | 78 | 0.6% |
| {closure#1}<tsrs_checker::checker::CacheHashKey, tsrs_core::ptr::P<tsrs_checker::types::Ty @ packedmap.rs | map<&tsrs_checker::packedmap::PackedSlot<tsrs_checker::checker::CacheHashKey, tsrs_core::p | 73 | 0.6% |
| deref<tsrs_checker::types::Type> @ ptr.rs | hash | 70 | 0.6% |
| intersects @ symbolflags.rs | intersects | 70 | 0.6% |
| get<core::option::Option<tsrs_core::ptr::P<[core::cell::Cell<u32>; 128]>>> @ cell.rs | narrow_slot<tsrs_checker::types::ValueSymbolLinks> | 67 | 0.5% |
| traverse @ utilities_1.rs | tsrs_ast::utilities_1::for_each_return_statement::traverse::{closure#0} | 66 | 0.5% |
| <tsrs_checker::checker::Checker>::get_actual_type_variable @ checker_15.rs | - | 64 | 0.5% |
| fold<tsrs_ast::symbol::SymbolMapEntry, (), core::iter::adapters::map::map_fold::{closure_e @ macros.rs | fold<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>, core::slice::iter::Iter<tsrs_ast::symbol | 63 | 0.5% |
| <tsrs_checker::checker::Checker>::source_file_and_index_of_node @ utilities.rs | - | 58 | 0.5% |

## cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp: 10314 samples

| innermost function | samples | share |
|---|---:|---:|
| copy_nonoverlapping<u8> | 2988 | 29.0% |
| eq | 1119 | 10.8% |
| {closure#0} | 1104 | 10.7% |
| likely | 1025 | 9.9% |
| {closure#0}<u64, hashbrown::alloc::inner::Global, tsrs_checker::relater_1::{impl#0}::looku | 839 | 8.1% |
| mi_page_malloc_zero | 487 | 4.7% |
| get<tsrs_ast::ast::NodeHeaderWord> | 295 | 2.9% |
| <tsrs_checker::checker::Checker>::source_file_and_index_of_node | 188 | 1.8% |
| {closure#0}<tsrs_core::ptr::P<tsrs_checker::types::Type>, hashbrown::alloc::inner::Global, | 180 | 1.7% |
| get_conditional_type_worker | 109 | 1.1% |
| copied<[u8; 4], core::array::TryFromSliceError> | 98 | 1.0% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo | 96 | 0.9% |
| ?? | 95 | 0.9% |
| {closure#0}<tsrs_ast::symbol::Symbol, tsrs_checker::types::MappedSymbolLinks> | 80 | 0.8% |
| is_reserved_member_name | 80 | 0.8% |
| copied<[u8; 8], core::array::TryFromSliceError> | 77 | 0.7% |
| {closure#1} | 73 | 0.7% |
| mi_ptr_page_is_valid_ex | 72 | 0.7% |
| copied<tsrs_core::ptr::P<tsrs_checker::types::Type>> | 65 | 0.6% |
| eq<tsrs_core::ptr::P<tsrs_ast::flow::FlowNode>> | 58 | 0.6% |
| as_ref<hashbrown::table::HashTable<u32, hashbrown::alloc::inner::Global>> | 50 | 0.5% |
| hash_name | 43 | 0.4% |
| data | 42 | 0.4% |
| get<tsrs_core::text::TextRange> | 41 | 0.4% |
| key | 36 | 0.3% |
| probe_seq | 34 | 0.3% |
| {closure#1}<tsrs_ast::symbol::Symbol, tsrs_checker::types::MappedSymbolLinks> | 33 | 0.3% |
| mi_page_queue_find_free_ex | 29 | 0.3% |
| spec_eq<u8, u8, 4> | 29 | 0.3% |
| get<core::option::Option<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_checker::types:: | 28 | 0.3% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| copy_nonoverlapping<u8> @ mod.rs | _mm_loadu_si128 | 2986 | 29.0% |
| {closure#0} @ checker_01.rs | tsrs_core::core_go::get_spelling_suggestion_worker::<tsrs_core::ptr::P<tsrs_ast::symbol::S | 1011 | 9.8% |
| {closure#0}<u64, hashbrown::alloc::inner::Global, tsrs_checker::relater_1::{impl#0}::looku @ raw.rs | find_inner | 839 | 8.1% |
| likely @ util.rs | find_inner | 612 | 5.9% |
| eq @ checker.rs | {closure#0}<tsrs_checker::checker::CacheHashKey, tsrs_core::ptr::P<tsrs_checker::types::Ty | 475 | 4.6% |
| eq @ checker.rs | eq | 414 | 4.0% |
| likely @ mod.rs | find_inner | 400 | 3.9% |
| mi_page_malloc_zero @ alloc.c | _mi_page_malloc_zero | 351 | 3.4% |
| get<tsrs_ast::ast::NodeHeaderWord> @ cell.rs | get<tsrs_ast::ast::NodeHeaderWord> | 295 | 2.9% |
| <tsrs_checker::checker::Checker>::source_file_and_index_of_node @ utilities.rs | - | 188 | 1.8% |
| {closure#0}<tsrs_core::ptr::P<tsrs_checker::types::Type>, hashbrown::alloc::inner::Global, @ raw.rs | find_inner | 180 | 1.7% |
| mi_page_malloc_zero @ alloc.c | mi_theap_xmalloc_small_zero_nonnull | 136 | 1.3% |
| get_conditional_type_worker @ checker_12.rs | <tsrs_checker::checker::Checker>::get_conditional_type | 109 | 1.1% |
| copied<[u8; 4], core::array::TryFromSliceError> @ result.rs | try_from<u8, 4> | 98 | 1.0% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo @ raw.rs | find_inner | 96 | 0.9% |
| ?? @ ?? | - | 95 | 0.9% |
| eq @ types.rs | eq | 93 | 0.9% |
| {closure#0}<tsrs_ast::symbol::Symbol, tsrs_checker::types::MappedSymbolLinks> @ links.rs | {closure#0}<tsrs_checker::links::LinkSlot, hashbrown::alloc::inner::Global, tsrs_checker:: | 80 | 0.8% |
| is_reserved_member_name @ utilities.rs | is_named_member | 80 | 0.8% |
| copied<[u8; 8], core::array::TryFromSliceError> @ result.rs | try_from<u8, 8> | 77 | 0.7% |
| {closure#1} @ symbol.rs | {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_ast::symbol::{impl#17}::search::{cl | 73 | 0.7% |
| mi_ptr_page_is_valid_ex @ free.c | mi_ptr_page_is_valid | 72 | 0.7% |
| {closure#0} @ symbol.rs | {closure#0}<usize, tsrs_ast::symbol::{impl#17}::search::{closure_env#0}> | 68 | 0.7% |
| copied<tsrs_core::ptr::P<tsrs_checker::types::Type>> @ option.rs | resolved_base_constraint_of | 63 | 0.6% |
| eq<tsrs_core::ptr::P<tsrs_ast::flow::FlowNode>> @ option.rs | lookup | 58 | 0.6% |
| eq @ cmp.rs | eq<u32> | 55 | 0.5% |
| eq @ checker.rs | {closure#0}<tsrs_checker::checker::CachedSignatureKey, tsrs_core::ptr::P<tsrs_checker::typ | 51 | 0.5% |
| as_ref<hashbrown::table::HashTable<u32, hashbrown::alloc::inner::Global>> @ option.rs | index | 50 | 0.5% |
| get<tsrs_core::text::TextRange> @ cell.rs | get<tsrs_core::text::TextRange> | 41 | 0.4% |
| data @ types.rs | as_type_reference | 39 | 0.4% |

## cpu_core/ld_blocks.store_forward,period=1301/upp: 13011 samples

| innermost function | samples | share |
|---|---:|---:|
| <tsrs_checker::mapper::TypeMapper>::map | 985 | 7.6% |
| copy_nonoverlapping<u8> | 742 | 5.7% |
| <tsrs_checker::relater_types::Relater>::recursive_type_related_to | 460 | 3.5% |
| data | 320 | 2.5% |
| next<tsrs_core::ptr::P<tsrs_checker::types::Type>> | 273 | 2.1% |
| intersects | 260 | 2.0% |
| <tsrs_checker::checker::Checker>::instantiate_type_with_alias_worker | 230 | 1.8% |
| mi_page_malloc_zero | 220 | 1.7% |
| mix16_b | 184 | 1.4% |
| eq | 172 | 1.3% |
| ?? | 165 | 1.3% |
| get_object_type_instantiation | 149 | 1.1% |
| eq<tsrs_core::ptr::P<tsrs_checker::types::Type>> | 138 | 1.1% |
| mi_theap_malloc_zero_aligned_at | 138 | 1.1% |
| write<tsrs_checker::types::TypeAlloc<tsrs_checker::types::ObjectType>> | 120 | 0.9% |
| _mm_movemask_epi8 | 110 | 0.8% |
| likely | 107 | 0.8% |
| full | 107 | 0.8% |
| write_uint32 | 106 | 0.8% |
| <tsrs_checker::checker::Checker>::add_type_to_intersection | 102 | 0.8% |
| add<u8> | 99 | 0.8% |
| <tsrs_checker::checker::Checker>::instantiate_list::<tsrs_core::ptr::P<tsrs_checker::types | 97 | 0.7% |
| sub<tsrs_checker::packedmap::PackedSlot<tsrs_checker::checker::CacheHashKey, tsrs_core::pt | 97 | 0.7% |
| instantiate_type_with_alias | 93 | 0.7% |
| wrapping_mul | 92 | 0.7% |
| <tsrs_ast::symbol::SymbolMap>::insert | 88 | 0.7% |
| get | 87 | 0.7% |
| rposition<tsrs_core::ptr::P<tsrs_checker::mapper::TypeMapper>, tsrs_checker::checker_11::{ | 81 | 0.6% |
| <tsrs_checker::relater_types::Relater>::is_related_to_ex | 80 | 0.6% |
| write_types | 75 | 0.6% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| <tsrs_checker::mapper::TypeMapper>::map @ mapper.rs | - | 948 | 7.3% |
| copy_nonoverlapping<u8> @ mod.rs | _mm_loadu_si128 | 684 | 5.3% |
| <tsrs_checker::relater_types::Relater>::recursive_type_related_to @ relater_2.rs | - | 452 | 3.5% |
| data @ mapper.rs | <tsrs_checker::mapper::TypeMapper>::map | 272 | 2.1% |
| <tsrs_checker::checker::Checker>::instantiate_type_with_alias_worker @ checker_11.rs | - | 230 | 1.8% |
| mi_page_malloc_zero @ alloc.c | _mi_page_malloc_zero | 212 | 1.6% |
| mix16_b @ xxh3.rs | mix32_b | 184 | 1.4% |
| ?? @ ?? | - | 165 | 1.3% |
| get_object_type_instantiation @ checker_11.rs | instantiate_type_worker | 147 | 1.1% |
| mi_theap_malloc_zero_aligned_at @ alloc-aligned.c | mi_theap_malloc_aligned_at | 138 | 1.1% |
| eq<tsrs_core::ptr::P<tsrs_checker::types::Type>> @ non_null.rs | next<tsrs_core::ptr::P<tsrs_checker::types::Type>> | 126 | 1.0% |
| write<tsrs_checker::types::TypeAlloc<tsrs_checker::types::ObjectType>> @ mod.rs | write<tsrs_checker::types::TypeAlloc<tsrs_checker::types::ObjectType>> | 120 | 0.9% |
| next<tsrs_core::ptr::P<tsrs_checker::types::Type>> @ macros.rs | try_fold<core::slice::iter::Iter<tsrs_core::ptr::P<tsrs_checker::types::Type>>, (), core:: | 119 | 0.9% |
| write_uint32 @ checker_09.rs | write_type | 106 | 0.8% |
| _mm_movemask_epi8 @ sse2.rs | match_tag | 104 | 0.8% |
| <tsrs_checker::checker::Checker>::add_type_to_intersection @ checker_13.rs | - | 102 | 0.8% |
| next<tsrs_core::ptr::P<tsrs_checker::types::Type>> @ macros.rs | write_types | 97 | 0.7% |
| sub<tsrs_checker::packedmap::PackedSlot<tsrs_checker::checker::CacheHashKey, tsrs_core::pt @ mut_ptr.rs | from_base_index<tsrs_checker::packedmap::PackedSlot<tsrs_checker::checker::CacheHashKey, t | 97 | 0.7% |
| instantiate_type_with_alias @ checker_11.rs | instantiate_type | 92 | 0.7% |
| <tsrs_ast::symbol::SymbolMap>::insert @ symbol.rs | - | 88 | 0.7% |
| get @ frozen.rs | name | 86 | 0.7% |
| <tsrs_checker::checker::Checker>::instantiate_list::<tsrs_core::ptr::P<tsrs_checker::types @ checker_11.rs | - | 85 | 0.7% |
| rposition<tsrs_core::ptr::P<tsrs_checker::mapper::TypeMapper>, tsrs_checker::checker_11::{ @ macros.rs | find_last_index<tsrs_core::ptr::P<tsrs_checker::mapper::TypeMapper>, tsrs_checker::checker | 81 | 0.6% |
| <tsrs_checker::relater_types::Relater>::is_related_to_ex @ relater_2.rs | - | 80 | 0.6% |
| eq @ checker.rs | {closure#0}<tsrs_checker::checker::CacheHashKey, tsrs_core::ptr::P<tsrs_checker::types::Ty | 78 | 0.6% |
| add<u8> @ mut_ptr.rs | get<tsrs_checker::mapper::TypeMapper> | 77 | 0.6% |
| xxh3_128_7to128 @ xxh3.rs | xxh3_128_internal | 75 | 0.6% |
| lowest_set_bit @ bitmask.rs | next | 63 | 0.5% |
| <tsrs_checker::checker::Checker>::get_intersection_type_worker @ checker_13.rs | - | 63 | 0.5% |
| pop<tsrs_core::ptr::P<tsrs_checker::types::Type>, alloc::alloc::Global> @ mod.rs | <tsrs_checker::checker::Checker>::instantiate_type_with_alias_worker | 62 | 0.5% |

## cpu_core/mem_load_retired.l1_miss,period=4001/upp: 12989 samples

| innermost function | samples | share |
|---|---:|---:|
| copy_nonoverlapping<u8> | 1635 | 12.6% |
| get<tsrs_ast::ast::NodeHeaderWord> | 939 | 7.2% |
| mi_page_malloc_zero | 731 | 5.6% |
| intersects | 611 | 4.7% |
| {closure#0} | 391 | 3.0% |
| eq | 364 | 2.8% |
| get<u64> | 353 | 2.7% |
| likely | 293 | 2.3% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo | 253 | 1.9% |
| <tsrs_checker::checker::Checker>::source_file_and_index_of_node | 249 | 1.9% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_checker::types::Type>>> | 238 | 1.8% |
| value_declaration | 204 | 1.6% |
| <tsrs_checker::mapper::TypeMapper>::map | 195 | 1.5% |
| is_reserved_member_name | 178 | 1.4% |
| instantiate_type_with_alias | 145 | 1.1% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> | 139 | 1.1% |
| data | 136 | 1.0% |
| get<tsrs_checker::types::TypeFlags> | 132 | 1.0% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> | 125 | 1.0% |
| mi_ptr_page_is_valid_ex | 108 | 0.8% |
| any<tsrs_core::ptr::P<tsrs_ast::ast::Node>, tsrs_checker::checker_11::{impl#3}::is_declara | 107 | 0.8% |
| ?? | 105 | 0.8% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>>> | 102 | 0.8% |
| spec_eq<u8, u8, 4> | 100 | 0.8% |
| pop_free | 87 | 0.7% |
| mi_theap_malloc_zero_aligned_at | 84 | 0.6% |
| {closure#0}<u64, hashbrown::alloc::inner::Global, tsrs_checker::relater_1::{impl#0}::looku | 84 | 0.6% |
| <tsrs_checker::checker::Checker>::get_actual_type_variable | 83 | 0.6% |
| atomic_load<u32> | 80 | 0.6% |
| {closure#0}<tsrs_core::ptr::P<tsrs_checker::types::Type>, hashbrown::alloc::inner::Global, | 80 | 0.6% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| copy_nonoverlapping<u8> @ mod.rs | _mm_loadu_si128 | 1635 | 12.6% |
| get<tsrs_ast::ast::NodeHeaderWord> @ cell.rs | get<tsrs_ast::ast::NodeHeaderWord> | 939 | 7.2% |
| mi_page_malloc_zero @ alloc.c | _mi_page_malloc_zero | 614 | 4.7% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo @ raw.rs | find_inner | 253 | 1.9% |
| get<u64> @ cell.rs | get | 252 | 1.9% |
| {closure#0} @ checker_01.rs | tsrs_core::core_go::get_spelling_suggestion_worker::<tsrs_core::ptr::P<tsrs_ast::symbol::S | 251 | 1.9% |
| <tsrs_checker::checker::Checker>::source_file_and_index_of_node @ utilities.rs | - | 249 | 1.9% |
| <tsrs_checker::mapper::TypeMapper>::map @ mapper.rs | - | 195 | 1.5% |
| is_reserved_member_name @ utilities.rs | is_named_member | 178 | 1.4% |
| likely @ util.rs | find_inner | 174 | 1.3% |
| instantiate_type_with_alias @ checker_11.rs | instantiate_type | 144 | 1.1% |
| intersects @ lib.rs | instantiate_type_with_alias | 142 | 1.1% |
| get<tsrs_checker::types::TypeFlags> @ cell.rs | flags | 132 | 1.0% |
| value_declaration @ symbol.rs | is_static_private_identifier_property | 129 | 1.0% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> @ cell.rs | get<tsrs_core::ptr::P<tsrs_ast::ast::Node>> | 125 | 1.0% |
| mi_page_malloc_zero @ alloc.c | mi_theap_xmalloc_small_zero_nonnull | 117 | 0.9% |
| likely @ mod.rs | find_inner | 115 | 0.9% |
| mi_ptr_page_is_valid_ex @ free.c | mi_ptr_page_is_valid | 108 | 0.8% |
| any<tsrs_core::ptr::P<tsrs_ast::ast::Node>, tsrs_checker::checker_11::{impl#3}::is_declara @ macros.rs | is_declaration_contained_by | 107 | 0.8% |
| ?? @ ?? | - | 105 | 0.8% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>>> @ cell.rs | get<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>> | 102 | 0.8% |
| spec_eq<u8, u8, 4> @ equality.rs | eq<u8, u8, 4> | 100 | 0.8% |
| get<u64> @ cell.rs | tags | 96 | 0.7% |
| intersects @ lib.rs | could_contain_type_variables | 88 | 0.7% |
| eq @ checker.rs | {closure#0}<tsrs_checker::checker::CacheHashKey, tsrs_core::ptr::P<tsrs_checker::types::Ty | 87 | 0.7% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> @ cell.rs | get<core::option::Option<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> | 85 | 0.7% |
| mi_theap_malloc_zero_aligned_at @ alloc-aligned.c | mi_theap_malloc_aligned_at | 84 | 0.6% |
| {closure#0}<u64, hashbrown::alloc::inner::Global, tsrs_checker::relater_1::{impl#0}::looku @ raw.rs | find_inner | 84 | 0.6% |
| <tsrs_checker::checker::Checker>::get_actual_type_variable @ checker_15.rs | - | 83 | 0.6% |
| atomic_load<u32> @ atomic.rs | load | 80 | 0.6% |
