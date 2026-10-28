
## cpu_core/mem_load_retired.l2_miss,period=307/upp: 4485 samples

| innermost function | samples | share |
|---|---:|---:|
| copy_nonoverlapping<u8> | 566 | 12.6% |
| mi_page_malloc_zero | 407 | 9.1% |
| get<tsrs_ast::ast::NodeHeaderWord> | 263 | 5.9% |
| get<u64> | 162 | 3.6% |
| intersects | 157 | 3.5% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_checker::types::Type>>> | 148 | 3.3% |
| <tsrs_checker::checker::Checker>::source_file_and_index_of_node | 133 | 3.0% |
| ?? | 126 | 2.8% |
| is_reserved_member_name | 123 | 2.7% |
| eq<tsrs_core::ptr::P<tsrs_ast::flow::FlowNode>> | 114 | 2.5% |
| eq | 101 | 2.3% |
| likely | 84 | 1.9% |
| {closure#0}<u64, hashbrown::alloc::inner::Global, tsrs_checker::relater_1::{impl#0}::looku | 78 | 1.7% |
| data | 77 | 1.7% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo | 70 | 1.6% |
| hash | 69 | 1.5% |
| {closure#0} | 65 | 1.4% |
| any<tsrs_core::ptr::P<tsrs_ast::ast::Node>, tsrs_checker::checker_11::{impl#3}::is_declara | 46 | 1.0% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>>> | 41 | 0.9% |
| get<core::option::Option<tsrs_core::ptr::P<[core::cell::Cell<u32>; 128]>>> | 41 | 0.9% |
| is_le | 37 | 0.8% |
| get<core::option::Option<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_checker::types:: | 37 | 0.8% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_ast::symbol::SymbolTable>>> | 30 | 0.7% |
| could_contain_type_variables | 29 | 0.6% |
| {closure#0}<tsrs_ast::ast::Node, tsrs_checker::types::TypeNodeLinks> | 27 | 0.6% |
| atomic_load<u8> | 26 | 0.6% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> | 26 | 0.6% |
| hash_bytes | 25 | 0.6% |
| mi_ptr_page_is_valid_ex | 25 | 0.6% |
| copied<[u8; 8], core::array::TryFromSliceError> | 24 | 0.5% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| copy_nonoverlapping<u8> @ mod.rs | _mm_loadu_si128 | 565 | 12.6% |
| mi_page_malloc_zero @ alloc.c | _mi_page_malloc_zero | 298 | 6.6% |
| get<tsrs_ast::ast::NodeHeaderWord> @ cell.rs | get<tsrs_ast::ast::NodeHeaderWord> | 263 | 5.9% |
| get<u64> @ cell.rs | get | 158 | 3.5% |
| <tsrs_checker::checker::Checker>::source_file_and_index_of_node @ utilities.rs | - | 133 | 3.0% |
| ?? @ ?? | - | 126 | 2.8% |
| is_reserved_member_name @ utilities.rs | is_named_member | 123 | 2.7% |
| eq<tsrs_core::ptr::P<tsrs_ast::flow::FlowNode>> @ option.rs | lookup | 114 | 2.5% |
| mi_page_malloc_zero @ alloc.c | mi_theap_xmalloc_small_zero_nonnull | 109 | 2.4% |
| {closure#0}<u64, hashbrown::alloc::inner::Global, tsrs_checker::relater_1::{impl#0}::looku @ raw.rs | find_inner | 78 | 1.7% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo @ raw.rs | find_inner | 70 | 1.6% |
| hash @ types.rs | {closure#0} | 69 | 1.5% |
| data @ types.rs | as_type_reference | 66 | 1.5% |
| any<tsrs_core::ptr::P<tsrs_ast::ast::Node>, tsrs_checker::checker_11::{impl#3}::is_declara @ macros.rs | is_declaration_contained_by | 46 | 1.0% |
| likely @ mod.rs | find_inner | 45 | 1.0% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_checker::types::Type>>> @ cell.rs | resolved_type_of_value_symbol | 44 | 1.0% |
| {closure#0} @ parser_3.rs | {closure#0}<tsrs_parser::parser_3::{impl#0}::override_parent_in_immediate_children::{closu | 43 | 1.0% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>>> @ cell.rs | get<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>> | 41 | 0.9% |
| eq @ checker.rs | {closure#0}<tsrs_checker::checker::CacheHashKey, tsrs_core::ptr::P<tsrs_checker::types::Ty | 41 | 0.9% |
| get<core::option::Option<tsrs_core::ptr::P<[core::cell::Cell<u32>; 128]>>> @ cell.rs | narrow_slot<tsrs_checker::types::ValueSymbolLinks> | 41 | 0.9% |
| likely @ util.rs | find_inner | 39 | 0.9% |
| intersects @ lib.rs | could_contain_type_variables | 38 | 0.8% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_checker::types::Type>>> @ cell.rs | name_type | 38 | 0.8% |
| is_le @ cmp.rs | call_once<fn(core::cmp::Ordering) -> bool, (core::cmp::Ordering)> | 37 | 0.8% |
| get<core::option::Option<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_checker::types:: @ cell.rs | get<core::option::Option<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_checker::types:: | 37 | 0.8% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_checker::types::Type>>> @ cell.rs | <tsrs_checker::checker::Checker>::is_symbol_unaffected_by_instantiation | 32 | 0.7% |
| intersects @ symbolflags.rs | intersects | 31 | 0.7% |
| {closure#0}<tsrs_ast::ast::Node, tsrs_checker::types::TypeNodeLinks> @ links.rs | {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo | 27 | 0.6% |
| atomic_load<u8> @ atomic.rs | load | 26 | 0.6% |
| hash_bytes @ lib.rs | write | 25 | 0.6% |

## cpu_core/mem_load_retired.l3_miss,period=97/upp: 4261 samples

| innermost function | samples | share |
|---|---:|---:|
| get<tsrs_ast::ast::NodeHeaderWord> | 368 | 8.6% |
| eq<tsrs_core::ptr::P<tsrs_ast::flow::FlowNode>> | 257 | 6.0% |
| data | 235 | 5.5% |
| intersects | 212 | 5.0% |
| ?? | 161 | 3.8% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_checker::types::Type>>> | 138 | 3.2% |
| hash | 133 | 3.1% |
| mi_page_malloc_zero | 127 | 3.0% |
| copy_nonoverlapping<u8> | 125 | 2.9% |
| get<u64> | 115 | 2.7% |
| eq | 114 | 2.7% |
| get<core::option::Option<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_checker::types:: | 108 | 2.5% |
| traverse | 89 | 2.1% |
| likely | 82 | 1.9% |
| {closure#0} | 64 | 1.5% |
| deref<tsrs_checker::types::Type> | 64 | 1.5% |
| {closure#0}<u64, hashbrown::alloc::inner::Global, tsrs_checker::relater_1::{impl#0}::looku | 58 | 1.4% |
| nodes | 48 | 1.1% |
| is_reserved_member_name | 43 | 1.0% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_ast::symbol::{impl#17}::search::{cl | 42 | 1.0% |
| get<u32> | 38 | 0.9% |
| _mm256_cmpeq_epi8 | 37 | 0.9% |
| hash_bytes | 35 | 0.8% |
| copied<[u8; 4], core::array::TryFromSliceError> | 33 | 0.8% |
| get<core::option::Option<tsrs_core::ptr::P<[core::cell::Cell<u32>; 128]>>> | 32 | 0.8% |
| get<tsrs_ast::nodeflags::NodeFlags> | 30 | 0.7% |
| {closure#0}<tsrs_ast::ast::Node, tsrs_checker::types::TypeNodeLinks> | 30 | 0.7% |
| copied<[u8; 8], core::array::TryFromSliceError> | 29 | 0.7% |
| is_prologue_directive | 28 | 0.7% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>>> | 27 | 0.6% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| get<tsrs_ast::ast::NodeHeaderWord> @ cell.rs | get<tsrs_ast::ast::NodeHeaderWord> | 368 | 8.6% |
| eq<tsrs_core::ptr::P<tsrs_ast::flow::FlowNode>> @ option.rs | lookup | 257 | 6.0% |
| data @ types.rs | as_type_reference | 230 | 5.4% |
| ?? @ ?? | - | 161 | 3.8% |
| hash @ types.rs | {closure#0} | 133 | 3.1% |
| copy_nonoverlapping<u8> @ mod.rs | _mm_loadu_si128 | 122 | 2.9% |
| get<u64> @ cell.rs | get | 108 | 2.5% |
| get<core::option::Option<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_checker::types:: @ cell.rs | get<core::option::Option<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_checker::types:: | 108 | 2.5% |
| traverse @ utilities_1.rs | tsrs_ast::utilities_1::for_each_return_statement::traverse::{closure#0} | 89 | 2.1% |
| mi_page_malloc_zero @ alloc.c | _mi_page_malloc_zero | 86 | 2.0% |
| intersects @ nodeflags.rs | intersects | 73 | 1.7% |
| likely @ util.rs | find_inner | 69 | 1.6% |
| deref<tsrs_checker::types::Type> @ ptr.rs | hash | 64 | 1.5% |
| {closure#0}<u64, hashbrown::alloc::inner::Global, tsrs_checker::relater_1::{impl#0}::looku @ raw.rs | find_inner | 58 | 1.4% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_checker::types::Type>>> @ cell.rs | resolved_type_of_value_symbol | 54 | 1.3% |
| eq @ checker.rs | {closure#0}<tsrs_checker::checker::CacheHashKey, tsrs_core::ptr::P<tsrs_checker::types::Ty | 52 | 1.2% |
| is_reserved_member_name @ utilities.rs | is_named_member | 43 | 1.0% |
| intersects @ symbolflags.rs | intersects | 43 | 1.0% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_ast::symbol::{impl#17}::search::{cl @ raw.rs | find_inner | 42 | 1.0% |
| mi_page_malloc_zero @ alloc.c | mi_theap_xmalloc_small_zero_nonnull | 41 | 1.0% |
| _mm256_cmpeq_epi8 @ avx2.rs | cmpeq | 37 | 0.9% |
| hash_bytes @ lib.rs | write | 35 | 0.8% |
| copied<[u8; 4], core::array::TryFromSliceError> @ result.rs | try_from<u8, 4> | 33 | 0.8% |
| get<core::option::Option<tsrs_core::ptr::P<[core::cell::Cell<u32>; 128]>>> @ cell.rs | narrow_slot<tsrs_checker::types::ValueSymbolLinks> | 32 | 0.8% |
| {closure#0} @ symbol.rs | {closure#0}<usize, tsrs_ast::symbol::{impl#17}::search::{closure_env#0}> | 31 | 0.7% |
| get<tsrs_ast::nodeflags::NodeFlags> @ cell.rs | get<tsrs_ast::nodeflags::NodeFlags> | 30 | 0.7% |
| get<u32> @ cell.rs | {closure#3}<tsrs_ast::ast::Node, tsrs_checker::types::SignatureLinks> | 30 | 0.7% |
| {closure#0}<tsrs_ast::ast::Node, tsrs_checker::types::TypeNodeLinks> @ links.rs | {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo | 30 | 0.7% |
| copied<[u8; 8], core::array::TryFromSliceError> @ result.rs | try_from<u8, 8> | 29 | 0.7% |
| is_prologue_directive @ utilities_1.rs | {closure#0} | 28 | 0.7% |

## cpu_core/mem_inst_retired.stlb_miss_loads,period=211/upp: 2291 samples

| innermost function | samples | share |
|---|---:|---:|
| copy_nonoverlapping<u8> | 440 | 19.2% |
| mi_page_malloc_zero | 214 | 9.3% |
| ?? | 147 | 6.4% |
| eq | 114 | 5.0% |
| eq<tsrs_core::ptr::P<tsrs_ast::flow::FlowNode>> | 114 | 5.0% |
| get<tsrs_ast::ast::NodeHeaderWord> | 113 | 4.9% |
| is_reserved_member_name | 113 | 4.9% |
| {closure#0} | 89 | 3.9% |
| likely | 76 | 3.3% |
| get<tsrs_core::text::TextRange> | 50 | 2.2% |
| key | 40 | 1.7% |
| {closure#0}<u64, hashbrown::alloc::inner::Global, tsrs_checker::relater_1::{impl#0}::looku | 39 | 1.7% |
| nodes | 37 | 1.6% |
| copied<[u8; 4], core::array::TryFromSliceError> | 30 | 1.3% |
| {closure#1} | 27 | 1.2% |
| copied<[u8; 8], core::array::TryFromSliceError> | 23 | 1.0% |
| any<tsrs_core::ptr::P<tsrs_ast::ast::Node>, tsrs_checker::checker_11::{impl#3}::is_declara | 23 | 1.0% |
| get<tsrs_ast::nodeflags::NodeFlags> | 23 | 1.0% |
| hash_bytes | 22 | 1.0% |
| is_le | 21 | 0.9% |
| copied<tsrs_core::ptr::P<tsrs_checker::types::Type>> | 19 | 0.8% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo | 18 | 0.8% |
| {closure#0}<tsrs_core::ptr::P<tsrs_checker::types::Type>, hashbrown::alloc::inner::Global, | 18 | 0.8% |
| spec_eq<u8, u8, 4> | 17 | 0.7% |
| as_ref<hashbrown::table::HashTable<u32, hashbrown::alloc::inner::Global>> | 17 | 0.7% |
| mi_ptr_page_is_valid_ex | 16 | 0.7% |
| probe_seq | 16 | 0.7% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_ast::symbol::{impl#17}::search::{cl | 15 | 0.7% |
| mi_bitmap_chunk_count | 14 | 0.6% |
| mi_page_free_quick_collect | 14 | 0.6% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| copy_nonoverlapping<u8> @ mod.rs | _mm_loadu_si128 | 440 | 19.2% |
| mi_page_malloc_zero @ alloc.c | _mi_page_malloc_zero | 162 | 7.1% |
| ?? @ ?? | - | 147 | 6.4% |
| eq<tsrs_core::ptr::P<tsrs_ast::flow::FlowNode>> @ option.rs | lookup | 114 | 5.0% |
| get<tsrs_ast::ast::NodeHeaderWord> @ cell.rs | get<tsrs_ast::ast::NodeHeaderWord> | 113 | 4.9% |
| is_reserved_member_name @ utilities.rs | is_named_member | 113 | 4.9% |
| likely @ util.rs | find_inner | 56 | 2.4% |
| {closure#0} @ checker_01.rs | tsrs_core::core_go::get_spelling_suggestion_worker::<tsrs_core::ptr::P<tsrs_ast::symbol::S | 54 | 2.4% |
| mi_page_malloc_zero @ alloc.c | mi_theap_xmalloc_small_zero_nonnull | 52 | 2.3% |
| get<tsrs_core::text::TextRange> @ cell.rs | get<tsrs_core::text::TextRange> | 50 | 2.2% |
| eq @ checker.rs | {closure#0}<tsrs_checker::checker::CacheHashKey, tsrs_core::ptr::P<tsrs_checker::types::Ty | 50 | 2.2% |
| {closure#0}<u64, hashbrown::alloc::inner::Global, tsrs_checker::relater_1::{impl#0}::looku @ raw.rs | find_inner | 39 | 1.7% |
| nodes @ ast.rs | tsrs_ast::utilities_2::get_heritage_clause | 34 | 1.5% |
| eq @ cmp.rs | eq<u32> | 32 | 1.4% |
| {closure#0} @ symbol.rs | {closure#0}<usize, tsrs_ast::symbol::{impl#17}::search::{closure_env#0}> | 31 | 1.4% |
| key @ symbol.rs | {closure#0} | 31 | 1.4% |
| copied<[u8; 4], core::array::TryFromSliceError> @ result.rs | try_from<u8, 4> | 30 | 1.3% |
| {closure#1} @ symbol.rs | {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_ast::symbol::{impl#17}::search::{cl | 27 | 1.2% |
| copied<[u8; 8], core::array::TryFromSliceError> @ result.rs | try_from<u8, 8> | 23 | 1.0% |
| any<tsrs_core::ptr::P<tsrs_ast::ast::Node>, tsrs_checker::checker_11::{impl#3}::is_declara @ macros.rs | is_declaration_contained_by | 23 | 1.0% |
| get<tsrs_ast::nodeflags::NodeFlags> @ cell.rs | get<tsrs_ast::nodeflags::NodeFlags> | 23 | 1.0% |
| hash_bytes @ lib.rs | write | 22 | 1.0% |
| is_le @ cmp.rs | call_once<fn(core::cmp::Ordering) -> bool, (core::cmp::Ordering)> | 21 | 0.9% |
| likely @ mod.rs | find_inner | 20 | 0.9% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo @ raw.rs | find_inner | 18 | 0.8% |
| copied<tsrs_core::ptr::P<tsrs_checker::types::Type>> @ option.rs | resolved_base_constraint_of | 18 | 0.8% |
| {closure#0}<tsrs_core::ptr::P<tsrs_checker::types::Type>, hashbrown::alloc::inner::Global, @ raw.rs | find_inner | 18 | 0.8% |
| spec_eq<u8, u8, 4> @ equality.rs | eq<u8, u8, 4> | 17 | 0.7% |
| as_ref<hashbrown::table::HashTable<u32, hashbrown::alloc::inner::Global>> @ option.rs | index | 17 | 0.7% |
| mi_ptr_page_is_valid_ex @ free.c | mi_ptr_page_is_valid | 16 | 0.7% |

## cpu_core/ld_blocks.store_forward,period=1301/upp: 4609 samples

| innermost function | samples | share |
|---|---:|---:|
| <tsrs_checker::checker::Checker>::get_normalized_type_worker | 584 | 12.7% |
| copy_nonoverlapping<u8> | 227 | 4.9% |
| ?? | 137 | 3.0% |
| intersects | 100 | 2.2% |
| mi_page_malloc_zero | 99 | 2.1% |
| <tsrs_checker::relater_types::Relater>::recursive_type_related_to | 97 | 2.1% |
| mi_theap_malloc_zero_aligned_at | 62 | 1.3% |
| <tsrs_checker::checker::Checker>::instantiate_type_with_alias_worker | 61 | 1.3% |
| write<tsrs_checker::types::TypeAlloc<tsrs_checker::types::ObjectType>> | 58 | 1.3% |
| <tsrs_ast::symbol::SymbolMap>::insert | 56 | 1.2% |
| next<tsrs_core::ptr::P<tsrs_checker::types::Type>> | 45 | 1.0% |
| record_item_insert_at | 44 | 1.0% |
| lowest_set_bit | 43 | 0.9% |
| eq | 43 | 0.9% |
| is_tuple_type | 43 | 0.9% |
| full | 42 | 0.9% |
| <tsrs_ast::symbol::SymbolMap>::search | 41 | 0.9% |
| get_object_type_instantiation | 40 | 0.9% |
| likely | 40 | 0.9% |
| <tsrs_checker::checker::Checker>::instantiate_list::<tsrs_core::ptr::P<tsrs_checker::types | 37 | 0.8% |
| scan | 36 | 0.8% |
| get | 36 | 0.8% |
| mix16_b | 36 | 0.8% |
| wrapping_mul | 33 | 0.7% |
| write<std::sync::poison::rwlock::RwLock<hashbrown::table::HashTable<(tsrs_module::cache::T | 32 | 0.7% |
| write<std::sync::poison::rwlock::RwLock<hashbrown::table::HashTable<(tsrs_module::cache::M | 31 | 0.7% |
| insert<u32, hashbrown::alloc::inner::Global, tsrs_ast::symbol::{impl#17}::insert::{closure | 31 | 0.7% |
| hash_bytes | 29 | 0.6% |
| <tsrs_checker::mapper::TypeMapper>::map | 29 | 0.6% |
| should_normalize_intersection | 29 | 0.6% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| <tsrs_checker::checker::Checker>::get_normalized_type_worker @ checker_14.rs | - | 584 | 12.7% |
| copy_nonoverlapping<u8> @ mod.rs | _mm_loadu_si128 | 202 | 4.4% |
| ?? @ ?? | - | 137 | 3.0% |
| mi_page_malloc_zero @ alloc.c | _mi_page_malloc_zero | 95 | 2.1% |
| <tsrs_checker::relater_types::Relater>::recursive_type_related_to @ relater_2.rs | - | 95 | 2.1% |
| mi_theap_malloc_zero_aligned_at @ alloc-aligned.c | mi_theap_malloc_aligned_at | 62 | 1.3% |
| <tsrs_checker::checker::Checker>::instantiate_type_with_alias_worker @ checker_11.rs | - | 61 | 1.3% |
| write<tsrs_checker::types::TypeAlloc<tsrs_checker::types::ObjectType>> @ mod.rs | write<tsrs_checker::types::TypeAlloc<tsrs_checker::types::ObjectType>> | 58 | 1.3% |
| <tsrs_ast::symbol::SymbolMap>::insert @ symbol.rs | - | 56 | 1.2% |
| is_tuple_type @ checker_11.rs | is_generic_tuple_type | 43 | 0.9% |
| <tsrs_ast::symbol::SymbolMap>::search @ symbol.rs | - | 41 | 0.9% |
| get_object_type_instantiation @ checker_11.rs | instantiate_type_worker | 40 | 0.9% |
| intersects @ lib.rs | get_reduced_type | 37 | 0.8% |
| mix16_b @ xxh3.rs | mix32_b | 36 | 0.8% |
| scan @ scanner.rs | next_token | 34 | 0.7% |
| get @ frozen.rs | name | 34 | 0.7% |
| <tsrs_checker::checker::Checker>::instantiate_list::<tsrs_core::ptr::P<tsrs_checker::types @ checker_11.rs | - | 33 | 0.7% |
| write<std::sync::poison::rwlock::RwLock<hashbrown::table::HashTable<(tsrs_module::cache::T @ mod.rs | {closure#0}<std::sync::poison::rwlock::RwLock<hashbrown::table::HashTable<(tsrs_module::ca | 32 | 0.7% |
| write<std::sync::poison::rwlock::RwLock<hashbrown::table::HashTable<(tsrs_module::cache::M @ mod.rs | {closure#0}<std::sync::poison::rwlock::RwLock<hashbrown::table::HashTable<(tsrs_module::ca | 31 | 0.7% |
| insert<u32, hashbrown::alloc::inner::Global, tsrs_ast::symbol::{impl#17}::insert::{closure @ raw.rs | insert_unique<u32, hashbrown::alloc::inner::Global, tsrs_ast::symbol::{impl#17}::insert::{ | 31 | 0.7% |
| likely @ util.rs | find_inner | 30 | 0.7% |
| hash_bytes @ lib.rs | write | 29 | 0.6% |
| should_normalize_intersection @ checker_14.rs | get_normalized_union_or_intersection_type | 29 | 0.6% |
| <tsrs_checker::checker::keyBuilder>::write_some_alias_arg @ checker_09.rs | - | 28 | 0.6% |
| record_item_insert_at @ raw.rs | insert_tagged_at_index<u32, hashbrown::alloc::inner::Global> | 28 | 0.6% |
| is_bucket_full @ raw.rs | fix_insert_index | 28 | 0.6% |
| <tsrs_checker::mapper::TypeMapper>::map @ mapper.rs | - | 27 | 0.6% |
| lowest_set_bit @ bitmask.rs | next | 26 | 0.6% |
| eq<tsrs_core::ptr::P<tsrs_checker::types::Type>> @ non_null.rs | next<tsrs_core::ptr::P<tsrs_checker::types::Type>> | 26 | 0.6% |
| full @ tag.rs | find_inner | 24 | 0.5% |

## cpu_core/mem_load_retired.l1_miss,period=4001/upp: 4591 samples

| innermost function | samples | share |
|---|---:|---:|
| copy_nonoverlapping<u8> | 391 | 8.5% |
| mi_page_malloc_zero | 344 | 7.5% |
| get<tsrs_ast::ast::NodeHeaderWord> | 269 | 5.9% |
| intersects | 230 | 5.0% |
| get<u64> | 191 | 4.2% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_checker::types::Type>>> | 149 | 3.2% |
| ?? | 121 | 2.6% |
| <tsrs_checker::checker::Checker>::source_file_and_index_of_node | 113 | 2.5% |
| is_reserved_member_name | 109 | 2.4% |
| value_declaration | 69 | 1.5% |
| any<tsrs_core::ptr::P<tsrs_ast::ast::Node>, tsrs_checker::checker_11::{impl#3}::is_declara | 62 | 1.4% |
| eq | 59 | 1.3% |
| {closure#0} | 56 | 1.2% |
| data | 54 | 1.2% |
| could_contain_type_variables | 51 | 1.1% |
| copied<[u8; 8], core::array::TryFromSliceError> | 48 | 1.0% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>>> | 47 | 1.0% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo | 42 | 0.9% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> | 41 | 0.9% |
| likely | 40 | 0.9% |
| mi_ptr_page_is_valid_ex | 40 | 0.9% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> | 35 | 0.8% |
| is_le | 34 | 0.7% |
| atomic_load<u32> | 33 | 0.7% |
| mi_theap_malloc_zero_aligned_at | 33 | 0.7% |
| get<core::option::Option<tsrs_core::ptr::P<[core::cell::Cell<u32>; 128]>>> | 32 | 0.7% |
| eq<u8, u8> | 28 | 0.6% |
| name | 28 | 0.6% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_ast::symbol::SymbolTable>>> | 27 | 0.6% |
| hash_bytes | 26 | 0.6% |

| innermost frame | inlined into | samples | share |
|---|---|---:|---:|
| copy_nonoverlapping<u8> @ mod.rs | _mm_loadu_si128 | 390 | 8.5% |
| mi_page_malloc_zero @ alloc.c | _mi_page_malloc_zero | 291 | 6.3% |
| get<tsrs_ast::ast::NodeHeaderWord> @ cell.rs | get<tsrs_ast::ast::NodeHeaderWord> | 269 | 5.9% |
| get<u64> @ cell.rs | get | 171 | 3.7% |
| ?? @ ?? | - | 121 | 2.6% |
| <tsrs_checker::checker::Checker>::source_file_and_index_of_node @ utilities.rs | - | 113 | 2.5% |
| is_reserved_member_name @ utilities.rs | is_named_member | 109 | 2.4% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_checker::types::Type>>> @ cell.rs | resolved_type_of_value_symbol | 66 | 1.4% |
| any<tsrs_core::ptr::P<tsrs_ast::ast::Node>, tsrs_checker::checker_11::{impl#3}::is_declara @ macros.rs | is_declaration_contained_by | 62 | 1.4% |
| intersects @ symbolflags.rs | intersects | 55 | 1.2% |
| mi_page_malloc_zero @ alloc.c | mi_theap_xmalloc_small_zero_nonnull | 53 | 1.2% |
| intersects @ lib.rs | could_contain_type_variables | 49 | 1.1% |
| copied<[u8; 8], core::array::TryFromSliceError> @ result.rs | try_from<u8, 8> | 48 | 1.0% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>>> @ cell.rs | get<tsrs_core::ptr::P<tsrs_ast::symbol::Symbol>> | 47 | 1.0% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_checker::types::Type>>> @ cell.rs | name_type | 42 | 0.9% |
| {closure#0}<u32, hashbrown::alloc::inner::Global, tsrs_checker::links::{impl#5}::get::{clo @ raw.rs | find_inner | 42 | 0.9% |
| get<tsrs_core::ptr::ThinSlice<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> @ cell.rs | get<tsrs_core::ptr::P<tsrs_ast::ast::Node>> | 41 | 0.9% |
| mi_ptr_page_is_valid_ex @ free.c | mi_ptr_page_is_valid | 40 | 0.9% |
| is_le @ cmp.rs | call_once<fn(core::cmp::Ordering) -> bool, (core::cmp::Ordering)> | 34 | 0.7% |
| get<core::option::Option<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> @ cell.rs | get<core::option::Option<tsrs_core::ptr::P<tsrs_ast::ast::Node>>> | 34 | 0.7% |
| atomic_load<u32> @ atomic.rs | load | 33 | 0.7% |
| mi_theap_malloc_zero_aligned_at @ alloc-aligned.c | mi_theap_malloc_aligned_at | 33 | 0.7% |
| could_contain_type_variables @ checker.rs | <tsrs_checker::checker::Checker>::is_symbol_unaffected_by_instantiation | 32 | 0.7% |
| get<core::option::Option<tsrs_core::ptr::P<[core::cell::Cell<u32>; 128]>>> @ cell.rs | narrow_slot<tsrs_checker::types::ValueSymbolLinks> | 32 | 0.7% |
| intersects @ lib.rs | instantiate_type_with_alias | 28 | 0.6% |
| value_declaration @ symbol.rs | is_static_private_identifier_property | 27 | 0.6% |
| hash_bytes @ lib.rs | write | 26 | 0.6% |
| {closure#0}<u64, hashbrown::alloc::inner::Global, tsrs_checker::relater_1::{impl#0}::looku @ raw.rs | find_inner | 26 | 0.6% |
| get<tsrs_ast::symbolflags::SymbolFlags> @ cell.rs | get<tsrs_ast::symbolflags::SymbolFlags> | 25 | 0.5% |
| <tsrs_checker::checker::Checker>::infer_from_types @ inference.rs | - | 25 | 0.5% |
