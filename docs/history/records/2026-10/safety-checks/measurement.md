# What safety checks cost Trig (2026-10-21)

Rig origin/main 3e3a88b02 plus a measuring-only switch (data/measure-switch.diff, never landed);
Trig 86618f1a5, `rig build --release`. pup, timing on core 6 with core 7 idle, fastest of 10,
output byte-identical for every variant on ts-pattern, zod3 and tiny-invariant.

## Headline

- Trig's research B1 measured fast mode at 22% fewer instructions. That no longer holds. Today
  `--release=fast` is 5.2% fewer instructions and 3.5% less time on ts-pattern, because Rig's
  proofs, flags and Trig's own work removed much of the earlier gap.
- Fast mode is also not the ceiling: Rig's own index test (`rig.index`, `List.at`) and length test
  (`rig.len`) are ordinary code that fast mode keeps (90,149 check sites remain in the fast binary).
- **The real ceiling, every check removed:** ts-pattern 21.4% fewer instructions, 11.7% fewer
  cycles, 11.2% less time. zod3: 8.7% less time. tiny-invariant: 14.0% less time.

## Census (baseline: 143,584 check sites)

| kind | sites |
|---|---|
| index | 73,700 |
| cast (`@intCast` 18,366, `rig.len` 17,976) | 36,679 |
| overflow | 21,433 |
| other (mostly memcpyAlias, 5,123) | 6,670 |
| bounds (Zig's own) | 3,253 |
| union | 1,620 |
| unwrap | 144 |

## Ablation, ts-pattern (change against base)

| variant | instructions | cycles | time |
|---|---|---|---|
| fast | −5.2% | −3.2% | −3.5% |
| all | −21.4% | −11.7% | −11.2% |
| index | −12.2% | −7.8% | −8.0% |
| cast | −3.5% | −2.2% | −2.9% |
| overflow | −2.1% | −1.3% | −1.2% |
| bounds | −0.9% | −2.2% | −1.7% |
| union + unwrap | −0.1% | noise | noise |
| other | −0.3% | noise | noise |

In instructions the kinds add up (all −21.4% against the singles' sum −19.2%). In cycles, the
singles other than index are near the 2% noise floor; their sum (−14.4%) exceeds all-together by 2.7
points.

## Where the cost sits (perf, 292,266 samples)

- 4.46% of cycles sit directly on check branches. Top 10 lines hold 30.5%, top 30 hold 49%, top 100
  hold 73%.
- By kind, share of all cycles: index 3.33%, cast 0.61%, overflow 0.28%, bounds 0.18%.
- By family, share of check samples: store accessors 25.6%; symbol and id accessors 17.9%; std
  Map/Set/Table probing 17.4%; AST node records 8.9%; allocator 2.2%; the rest 25.6%.
- Caveat: direct samples overstate some sites (the length compare shares a cache line with the next
  load); the ablation is the true total.

## Top sites (class: a = Rig could prove it, b = can't wrap, c = two-level access that could be
one, d = other)

1. `type_flags` `@store.types[Int(t)]` — d (id made by its own table)
2. `type_at` — d
3. `type_object_flags` — d
4. `sym_file_of` — c
5. `local_sym` — c
6. `symbol_flags` `bindings[f].symbols[l]` — c
7. allocator free list `h.free[c]` — a
8. `Map.find` `@table.at[i]` — c (parallel lists)
9. `symbol_declaration` — c
10. `Ast.pos` `@recs[n.id]` — d
11. Table.place `@tags[i]` — a (the slot comes from `free_slot`)
12. Map(CacheKey).find — c
13. `instantiation_stack.pop()`, Zig bounds inside `List.pop` — a (`len <= buf.len`)
14. `node_id` `@node_base[Int(n.file) - 1]` — d
15. `data_place` `@syms[@checker_symbol(s)]` — d
16. `Interner.text` `@ends[i]` — d
17. `Map.insert` `@len += 1` — b
18–20. `symbol_declaration_count`, `symbol_name`, `symbol_value_declaration` — c
21. `Ast.kind` — d
22. Map(AssignmentReducedKey).find — c
23. `active_type_mappers_caches[index]` — d (the list changes between the test and the use)
24. Table.place `U32(j)` — b
25. `value_symbol_links_has` `rig.len` — b (a length can't pass 2^62)
26. `Items.next` `es[j]` — a
27. `Ast.word_node` — d
28. Map.find `rig.len(tags.len)` — b
29. `type_node_links_has` — b
30. `sym_at` — d

Also: `checker_symbol`'s overflow is (a), since the caller's guard `is_binder_sym(s) == false` means
`s > binder_syms`; `node_ref` `U32(f + 1)` is (b).

## Top 30 functions by site count (static)

Ast.new_node 13,387 (cast); Ast.word_node 5,784; Ids.local_sym 4,726; Ast.add_list 3,401;
Ast.add_text 3,324; checker_symbol 2,791 (overflow on `s - binder_syms - 1`); Ast.word_list 2,673;
Ast.kind 2,515; Ids.sym_file_of 2,257; Ast.nodes 2,227; Ast.finish_node 1,768; symbol_declaration
1,710; Ast.binary_expression 1,580; Map(u32,EmitNode).get 1,533; Parser.report 1,226; type_flags
1,190; data_place 1,145; Ast.update_node 1,142; symbol_flags 1,059; symbol_declaration_count 1,025;
Ids.node_id 993; new_type_list 968; node_ref 898; Interner.text 891; Map(u32,EmitNode).replace 817;
Table.place 763; Ast.name 707; Ids.sym 704; Ast.pos 671; Ast.parent 635.

## Method

- Switch `RIG_MEASURE_UNCHECKED=kind,...`: Zig's checks are removed per panic-handler kind (each
  named handler becomes `@setRuntimeSafety(false); unreachable;`, which LLVM deletes like
  ReleaseFast); index makes `provenOf` report both bounds for every `Int` index and makes
  `indexPanic`/`slicePanic` unreachable. With the variable unset, the emitted package is
  byte-identical to unmodified Rig's except for the `panic` declaration.
- Census: branches into panic-handler blocks (objdump), attributed with `addr2line -i` to the
  innermost Trig/std frame.
- Ranking: `perf record cpu_core/cycles/upp`, five runs; a sample counts toward a site on its branch
  or the compare just before it.
- Data: `data/` (census, ranks, profiles, times3.* final timing, emitted-base.tgz, logs);
  `scripts/`; `rig/`, `trig/` source copies.
