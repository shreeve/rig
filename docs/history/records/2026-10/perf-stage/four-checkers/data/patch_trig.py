#!/usr/bin/env python3
"""Patch the scratch Trig copy (ck0/trig, Trig 806e0a1) with call counters.
Counters live in `Checker.ck` (a List[Int]); check_and_emit prints them as
`CK0 <checker> <index> <value>` lines, and new_checker_pool prints Go's
assignment as `CK0FILE <checker> <file>` lines when count > 1."""
import sys, re
root = sys.argv[1]

def patch(path, pairs):
    p = f'{root}/{path}'
    s = open(p).read()
    for old, new in pairs:
        n = s.count(old)
        if n != 1:
            sys.exit(f'{path}: {n} matches for {old[:70]!r}')
        s = s.replace(old, new)
    open(p, 'w').write(s)

# Checker field
patch('checker/checker.rig', [(
    "  pub total_instantiation_count: U32 = 0\n",
    "  pub total_instantiation_count: U32 = 0\n  pub ck: List[Int] = List()  # CK0 counters\n")])

M = 'checker/members.rig'
patch(M, [
# helper, before instantiate_type
("# Go: checker/checker.go:22597 instantiateType\npub fun Checker.instantiate_type(",
 "# CK0: add `n` to counter `i`\npub sub ck_add_to(ck: !List[Int], i: Int, n: Int)\n  while ck.len <= i\n    !ck.push(0)\n  ck[i] += n\n\n# Go: checker/checker.go:22597 instantiateType\npub fun Checker.instantiate_type("),
# instantiate_type_with_alias
("  # tests/cases/compiler/declarationEmitArrowFunctionNoRenaming.ts contains an example of this, which previously only worked in strada via some input node reuse logic instead.\n  return t if t == 0 or m == 0\n  if not (!@).could_contain_type_variables(t)\n",
 "  # tests/cases/compiler/declarationEmitArrowFunctionNoRenaming.ts contains an example of this, which previously only worked in strada via some input node reuse logic instead.\n  ck_add_to(!@ck, 0, 1)\n  if t == 0 or m == 0\n    ck_add_to(!@ck, 1, 1)\n    return t\n  if not (!@).could_contain_type_variables(t)\n"),
("          some = true\n          break\n    return t if not some\n  if @instantiation_stack.len == 100",
 "          some = true\n          break\n    if not some\n      ck_add_to(!@ck, 2, 1)\n      return t\n  if @instantiation_stack.len == 100"),
("  index = (?@).find_active_mapper(m)\n  key = CacheKey()\n  if index == -1\n",
 "  index = (?@).find_active_mapper(m)\n  ck_add_to(!@ck, 6, @active_mappers.len - index if index >= 0 else @active_mappers.len)\n  ck_add_to(!@ck, 12, @active_mappers.len)\n  key = CacheKey()\n  if index == -1\n    ck_add_to(!@ck, 4, 1)\n"),
("    if alias == 0\n      key = packed_types_key(PACKED_ACTIVE_MAPPER, 1, t, 0, 0)  # PORT: packed (keys.rig)\n    else\n      b = KeyBuilder()\n",
 "    if alias == 0\n      key = packed_types_key(PACKED_ACTIVE_MAPPER, 1, t, 0, 0)  # PORT: packed (keys.rig)\n    else\n      ck_add_to(!@ck, 7, 1)\n      b = KeyBuilder()\n"),
("    if @active_type_mappers_caches[index].get(key) as cached_type\n      return cached_type\n  @total_instantiation_count += 1\n",
 "    if @active_type_mappers_caches[index].get(key) as cached_type\n      ck_add_to(!@ck, 3, 1)\n      return cached_type\n    ck_add_to(!@ck, 5, 1)\n  @total_instantiation_count += 1\n"),
("  else\n    !@active_type_mappers_caches[index].put(key, result)\n  _ = (!@instantiation_stack).pop()\n",
 "  else\n    ck_add_to(!@ck, 8, @active_type_mappers_caches[index].len)\n    ck_add_to(!@ck, 9, 1 if @active_type_mappers_caches[index].len >= 16 else 0)\n    !@active_type_mappers_caches[index].put(key, result)\n  _ = (!@instantiation_stack).pop()\n"),
# pop_active_mapper
("  _ = (!@active_mappers).pop()\n  # Clear the map, but keep it for later reuse.\n",
 "  _ = (!@active_mappers).pop()\n  ck_add_to(!@ck, 10, @active_type_mappers_caches[@active_mappers.len].len)\n  ck_add_to(!@ck, 11, 1 if @active_type_mappers_caches[@active_mappers.len].len > 16 else 0)\n  # Clear the map, but keep it for later reuse.\n"),
# mapper_map
("pub fun Checker.mapper_map(!@, m: MapperId, t: TypeId) -> TypeId\n  match (?@).mapper_kind(m)\n    .Simple\n",
 "pub fun Checker.mapper_map(!@, m: MapperId, t: TypeId) -> TypeId\n  ck_add_to(!@ck, 20, 1)\n  match (?@).mapper_kind(m)\n    .Simple\n      ck_add_to(!@ck, 21, 1)\n"),
("    .Array\n      sources = (?@).mapper_sources(m)\n      for i in 0..sources.len()\n        return (?@).type_at((?@).mapper_targets(m), i) if t == (?@).type_at(sources, i)\n      return t\n    .ArrayToSingle\n",
 "    .Array\n      sources = (?@).mapper_sources(m)\n      ck_add_to(!@ck, 22, 1)\n      ck_add_to(!@ck, 29, sources.len())\n      for i in 0..sources.len()\n        return (?@).type_at((?@).mapper_targets(m), i) if t == (?@).type_at(sources, i)\n      return t\n    .ArrayToSingle\n      ck_add_to(!@ck, 23, 1)\n"),
("      # the mapper's sources as typeParameters and its node as parent\n      sources = (?@).mapper_sources(m)\n",
 "      # the mapper's sources as typeParameters and its node as parent\n      ck_add_to(!@ck, 24, 1)\n      sources = (?@).mapper_sources(m)\n"),
("    .Function => return (!@).function_mapper_map(m, t)\n    .Merged\n      m1 = (?@).mapper_m1(m)\n",
 "    .Function\n      ck_add_to(!@ck, 25, 1)\n      return (!@).function_mapper_map(m, t)\n    .Merged\n      ck_add_to(!@ck, 26, 1)\n      m1 = (?@).mapper_m1(m)\n"),
("    .Composite\n      m1 = (?@).mapper_m1(m)\n      m2 = (?@).mapper_m2(m)\n      t1 = (!@).mapper_map(m1, t)\n      return (!@).instantiate_type(t1, m2) if t1 != t\n      return (!@).mapper_map(m2, t)\n    .Inference => return (!@).inference_type_mapper_map(m, t)\n",
 "    .Composite\n      ck_add_to(!@ck, 27, 1)\n      m1 = (?@).mapper_m1(m)\n      m2 = (?@).mapper_m2(m)\n      t1 = (!@).mapper_map(m1, t)\n      return (!@).instantiate_type(t1, m2) if t1 != t\n      return (!@).mapper_map(m2, t)\n    .Inference\n      ck_add_to(!@ck, 28, 1)\n      return (!@).inference_type_mapper_map(m, t)\n"),
# instantiate_type_worker
("  alias = alias_in\n  flags = (?@).type_flags(t)\n  if flags & TYPE_FLAGS_TYPE_PARAMETER != 0\n    return (!@).get_mapped_type(t, m)\n  if flags & TYPE_FLAGS_OBJECT != 0\n    object_flags = (?@).type_object_flags(t)\n    if object_flags & (OBJECT_FLAGS_REFERENCE | OBJECT_FLAGS_ANONYMOUS | OBJECT_FLAGS_MAPPED) != 0\n      if object_flags & OBJECT_FLAGS_REFERENCE != 0 and (?@).reference_node(t).is_none()\n        resolved_type_arguments = (?@).reference_resolved_type_arguments(t)\n        new_type_arguments = (!@).instantiate_types(resolved_type_arguments, m)\n        return t if same_type_list(new_type_arguments, resolved_type_arguments)\n",
 "  alias = alias_in\n  flags = (?@).type_flags(t)\n  if flags & TYPE_FLAGS_TYPE_PARAMETER != 0\n    ck_add_to(!@ck, 30, 1)\n    return (!@).get_mapped_type(t, m)\n  if flags & TYPE_FLAGS_OBJECT != 0\n    object_flags = (?@).type_object_flags(t)\n    if object_flags & (OBJECT_FLAGS_REFERENCE | OBJECT_FLAGS_ANONYMOUS | OBJECT_FLAGS_MAPPED) != 0\n      if object_flags & OBJECT_FLAGS_REFERENCE != 0 and (?@).reference_node(t).is_none()\n        ck_add_to(!@ck, 31, 1)\n        resolved_type_arguments = (?@).reference_resolved_type_arguments(t)\n        new_type_arguments = (!@).instantiate_types(resolved_type_arguments, m)\n        if same_type_list(new_type_arguments, resolved_type_arguments)\n          ck_add_to(!@ck, 32, 1)\n          return t\n"),
("      if object_flags & OBJECT_FLAGS_REVERSE_MAPPED != 0\n        return (!@).instantiate_reverse_mapped_type(t, m)\n      return (!@).get_object_type_instantiation(t, m, alias)\n    return t\n  if flags & TYPE_FLAGS_UNION_OR_INTERSECTION != 0\n    source = t\n",
 "      if object_flags & OBJECT_FLAGS_REVERSE_MAPPED != 0\n        ck_add_to(!@ck, 33, 1)\n        return (!@).instantiate_reverse_mapped_type(t, m)\n      ck_add_to(!@ck, 34, 1)\n      return (!@).get_object_type_instantiation(t, m, alias)\n    ck_add_to(!@ck, 43, 1)\n    return t\n  if flags & TYPE_FLAGS_UNION_OR_INTERSECTION != 0\n    ck_add_to(!@ck, 35, 1)\n    source = t\n"),
("    return t if same_type_list(new_types, types) and alias_symbol == t_alias_symbol\n    if alias == 0\n      alias = (!@).instantiate_type_alias(t_alias, m)\n",
 "    if same_type_list(new_types, types) and alias_symbol == t_alias_symbol\n      ck_add_to(!@ck, 36, 1)\n      return t\n    if alias == 0\n      alias = (!@).instantiate_type_alias(t_alias, m)\n"),
("  if flags & TYPE_FLAGS_INDEX != 0\n    instantiated = (!@).instantiate_type((?@).type_target(t), m)\n",
 "  if flags & TYPE_FLAGS_INDEX != 0\n    ck_add_to(!@ck, 37, 1)\n    instantiated = (!@).instantiate_type((?@).type_target(t), m)\n"),
("  if flags & TYPE_FLAGS_INDEXED_ACCESS != 0\n    if alias == 0\n      alias = (!@).instantiate_type_alias((?@).type_alias(t), m)\n    object_type = ",
 "  if flags & TYPE_FLAGS_INDEXED_ACCESS != 0\n    ck_add_to(!@ck, 38, 1)\n    if alias == 0\n      alias = (!@).instantiate_type_alias((?@).type_alias(t), m)\n    object_type = "),
("    # and makes no mapper (docs/DIVERGENCE.md).\n    return (!@).get_conditional_type_instantiation_of((?@).conditional_mapper(t), t, m, false, alias)  # forConstraint\n  if flags & TYPE_FLAGS_SUBSTITUTION != 0\n",
 "    # and makes no mapper (docs/DIVERGENCE.md).\n    ck_add_to(!@ck, 41, 1)\n    return (!@).get_conditional_type_instantiation_of((?@).conditional_mapper(t), t, m, false, alias)  # forConstraint\n  if flags & TYPE_FLAGS_SUBSTITUTION != 0\n    ck_add_to(!@ck, 42, 1)\n"),
# get_object_type_instantiation
("pub fun Checker.get_object_type_instantiation(!@, t: TypeId, m: MapperId, alias: AliasId) -> TypeId\n  declaration = NodeRef()\n",
 "pub fun Checker.get_object_type_instantiation(!@, t: TypeId, m: MapperId, alias: AliasId) -> TypeId\n  ck_add_to(!@ck, 44, 1)\n  declaration = NodeRef()\n"),
("  return t if type_parameters.len() == 0\n  # We are instantiating an anonymous type that has one or more type parameters in scope. Apply the\n",
 "  if type_parameters.len() == 0\n    ck_add_to(!@ck, 45, 1)\n    return t\n  ck_add_to(!@ck, 49, type_parameters.len())\n  # We are instantiating an anonymous type that has one or more type parameters in scope. Apply the\n"),
("  full_key = InstantiationKey(owner: U64(target), key: key)\n  if @instantiations.get(full_key) as found\n    return found\n  type_arguments = (!@).new_type_list(?arguments)\n  new_mapper = (!@).new_type_mapper(type_parameters, type_arguments)\n",
 "  full_key = InstantiationKey(owner: U64(target), key: key)\n  if @instantiations.get(full_key) as found\n    ck_add_to(!@ck, 46, 1)\n    return found\n  ck_add_to(!@ck, 47, 1)\n  type_arguments = (!@).new_type_list(?arguments)\n  new_mapper = (!@).new_type_mapper(type_parameters, type_arguments)\n"),
# instantiate_types
("pub fun Checker.instantiate_types(!@, types: TypeList, m: MapperId) -> TypeList\n  # Go: checker/checker.go:23309 instantiateList\n",
 "pub fun Checker.instantiate_types(!@, types: TypeList, m: MapperId) -> TypeList\n  ck_add_to(!@ck, 50, 1)\n  ck_add_to(!@ck, 51, types.len())\n  # Go: checker/checker.go:23309 instantiateList\n"),
# conditional instantiation
("    key = InstantiationKey(owner: INSTANTIATIONS_ROOT | U64(root), key: (?@).get_type_items_instantiation_key(?arguments, alias, for_constraint))\n    if @instantiations.get(key) as found\n      return found\n",
 "    key = InstantiationKey(owner: INSTANTIATIONS_ROOT | U64(root), key: (?@).get_type_items_instantiation_key(?arguments, alias, for_constraint))\n    ck_add_to(!@ck, 52, 1)\n    if @instantiations.get(key) as found\n      ck_add_to(!@ck, 53, 1)\n      return found\n"),
])

patch('checker/constructors.rig', [
("  id = (?@).get_type_list_key(type_arguments)\n  key = InstantiationKey(owner: U64(target), key: id)\n  if @instantiations.get(key) as found\n    return found\n",
 "  id = (?@).get_type_list_key(type_arguments)\n  key = InstantiationKey(owner: U64(target), key: id)\n  ck_add_to(!@ck, 54, 1)\n  if @instantiations.get(key) as found\n    ck_add_to(!@ck, 55, 1)\n    return found\n"),
])

patch('execute/emit.rig', [
("    result.counts.instantiations += Int(c.total_instantiation_count)\n",
 "    result.counts.instantiations += Int(c.total_instantiation_count)\n  ck_k = 0\n  for c in ?pool.checkers\n    for v, i in ?c.ck\n      print(\"CK0\", ck_k, i, v)\n    print(\"CK0\", ck_k, 90, c.instantiations.len)\n    print(\"CK0\", ck_k, 91, c.has_instantiations.len)\n    print(\"CK0\", ck_k, 92, Int(c.type_count))\n    print(\"CK0\", ck_k, 93, Int(c.total_instantiation_count))\n    ck_k += 1\n"),
])

patch('declarations/checkerpool.rig', [
("  if count > 1\n    associations = program.checker_associations(count)\n",
 "  if count > 1\n    associations = program.checker_associations(count)\n    for a, f in ?associations\n      print(\"CK0FILE\", a, program.files[f].file_name, program.skip_type_checking(f, false))\n"),
])
print('patched')
