# Trig d78aa3f3's reserved Tables in the order a thread reserves them.
IDS = ['ids.sym_base', 'ids.tab_base', 'ids.binder', 'ids.tab_loc', 'ids.node_base']
STORE = ('types literals structured references interfaces union_or_intersections type_parameters small_kinds signatures composites '
 'type_predicates index_infos type_aliases mappers value_symbol_extras structured_extras union_or_intersection_extras signature_extras '
 'structured_member_records type_lists u32_lists signature_links symbol_node_links type_node_links symbol_reference_links value_symbol_links '
 'mapped_symbol_links alias_symbol_links late_bound_links declared_type_links members_links signature_links_pages symbol_node_links_pages '
 'type_node_links_pages symbol_reference_links_pages mapped_symbol_links_pages alias_symbol_links_pages late_bound_links_pages '
 'declared_type_links_pages members_links_pages merged_symbols alias_targets alias_targets_pages immediate_targets immediate_targets_pages '
 'string_literal_types string_literal_types_pages').split()
CHECKER = ['store.' + s for s in STORE] + ['checker.syms', 'checker.symbol_data', 'checker.lazy_index', 'checker.tab_heads', 'checker.base_constraints', 'checker.tab_entries']
assert len(CHECKER) == 53
def name(nthread, k):
    if nthread == 5: return IDS[k]
    if nthread == 53: return CHECKER[k]
    if nthread == 58: return IDS[k] if k < 5 else CHECKER[k - 5]
    return f'?{nthread}#{k}'
