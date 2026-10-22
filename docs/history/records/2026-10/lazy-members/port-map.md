# Port map: lazy member tables (#64475, #64526) into Trig

Sources read (nothing built or run):

- the authoritative Go diffs: `misc/tsrs/upstream/patches/base/0001-*.patch` (#64475, squashed onto main) and `0002-*.patch` (#64526);
- tsrs: `notes/lazy-members.md`, `notes/mem-lazy.md`, `crates/tsrs_checker/src/{checker_09,checker_10,checker_11,checker_13,checker_15,relater_1}.rs`;
- Trig: `src/checker/{members,declarations,expressions,facts,relater,constructors,checker}.rig`, `docs/checker/DESIGN.md`, `docs/DIVERGENCE.md`, `AGENTS.md`, `HANDOFF.md`;
- the pinned Go at `misc/TypeScript` (655f0268, 2026-10-15), which has neither PR. Its `somePropertyReducesToNever` already walks an ordered map (#64521), so #64526's hunk goes onto that ordered form, as tsrs did.

All paths below are relative to `~/Data/Code/trig`. tsrs paths are relative to `misc/tsrs/crates/tsrs_checker/src/`.

## 0. Before any code: an open owner decision

`HANDOFF.md:259` lists "lazy members, which run ahead of the pin [no, until the pin has them]" as an open owner decision, and `:196` declines it for now. With the switch on, Trig would print what **tsgo + the two PRs** prints, not what the pinned tsgo prints:

- **#64475 changes only symbols.** It makes fewer symbols, and they are made in a different order. tsrs's counters show the same types and instantiations as without it. Symbol creation order does not reach Trig's output: Go's own symbol ids are handed out lazily, on first use, and Trig mirrors that (DESIGN §2). So the type log (`tools/checker/typelog`) should stay equal to the pin's.
- **#64526 changes types.** tsrs saw 9,639,962 types become 9,630,120 (about 10K fewer) on its monorepo. Type ids decide union order (DESIGN §2), so the pin's type log stops being an oracle. tsrs found no change in conformance output, but that is evidence, not proof.
- AGENTS rule 7 and the DIVERGENCE rule allow departures only "below the logic" or as "indexes that give the same answers", and say "a change to the core design needs a measured case first". This feature is neither kind of departure, so it needs the owner's approval as a mode of its own, or a pin that has the PRs.

Recommended framing: a switch that is **off by default** (`Checker.lazy_members`), with the off mode identical to the pin. Before any code, check whether #64475 and #64526 have merged upstream since 655f0268. If they have, moving the pin removes most of the problem.

## 1. Function map

Columns: what the Go PR does, where tsrs has it (file:line), the Trig counterpart (file:line, or *new*), and what changes there. A function marked **neutral** runs in both modes and must not change the work done with the switch off. A function marked **switch** is reached only when a table exists or the flag is on.

### #64475: lazy member tables for instantiated class and interface references

| Go (PR) | tsrs | Trig | Change in Trig |
|---|---|---|---|
| `Checker.lazyMemberTables` field | checker.rs:1226; flag `lazy_members` :1243 | checker.rig:31 `obj Checker` | *New* fields: `lazy_members: Bool`, `lazy_member_tables: Map[TypeId, U32]`, `lazy_tables: List[LazyMemberTable]` (§3). |
| `getPropertyOfTypeEx`: reads members through `getMemberOfStructuredType`, and signatures through `getSignaturesOfStructuredType(t)` (**neutral**) | checker_09.rs:2798, worker :2830 | declarations.rig:630 | Replace `resolved = resolve_structured_type_members(t)` + `table_get(structured_members(resolved), name)` with `get_member_of_structured_type(t, name)`. The two signature tests take `t`; Trig's `resolved` is already `t`, but the call must no longer resolve. tsrs's `instantiate` argument and augment filter are tsrs-only (L9/L10, speed): skip them. |
| `getSignaturesOfStructuredType`: lazy table first | :3075, unresolved half :3096 | members.rig:72 | Add `if get_ready_lazy_member_table(t) as lm` → the table's `call_signatures`/`construct_signatures` (`SigList` ranges, copied by value). Trig slices a single `structured_signatures` list by `call_signature_count`, while the table keeps two lists, as Go's does. |
| `getIndexInfosOfStructuredType`: lazy table first | :3142, :3152 | members.rig:875 | Same: the table's `index_infos`. |
| `resolveTypeReferenceMembers`: a ready table resolves through `resolveLazyMembers` | :3387 | members.rig:3504 | Add the table check first, then the existing body, with the padding moved into `get_reference_member_type_arguments`. |
| `resolveObjectTypeMembers`: base signatures and index infos moved into `appendInheritedSignaturesAndIndexInfos` (**neutral**) | :3402 | members.rig:3516 (body :3548–3567) | Extract lines 3559–3567 unchanged. |
| `appendInheritedSignaturesAndIndexInfos` | :3483 | *new*, members.rig | Returns three lists. Rig has no tuple return as cheap as Go's, so return a small `obj Inherited{calls, constructs, infos}` or take `!List` buffers. This is the Rig form of the existing `concatenate_signatures`/`concatenate_index_infos` calls. |
| `lazyMemberTable` struct | :3515 (+`LazyMembers` :3533, `OnceCell` for `ready`) | *new* `obj LazyMemberTable` (§3) | Go's `ready` + fields. tsrs's `OnceCell` is a Rust convenience; Trig uses a plain `ready: Bool` set last, as Go does. |
| `mayHaveLazyMembers` | :3557 | *new*, a free function over `type_object_flags` | `flags & (MEMBERS_RESOLVED \| REFERENCE) == REFERENCE`, plus `lazy_members` (the flag is read here and in `get_lazy_mapped_table`, as in tsrs). |
| `getReferenceMemberTypeArguments` | :3563 | *new*; body from members.rig:3506–3512 | Returns `(TypeList, TypeList)`. The padded list is a new `TypeList` range (`new_type_list`), as now. tsrs avoids the temporary when the arguments equal the parameters (`create_lazy_member_table` :3626): worth doing, since Trig allocates into the shared type-list arena. |
| `getReadyLazyMemberTable` / `Worker` | :3586 / :3593 (+create :3626) | *new* | Tests: Object; `type_target(t)` nonzero, not `t`; target `CLASS_OR_INTERFACE`, not `TUPLE`; `type_symbol(t)` not a `VALUE_MODULE`. Then map lookup, else create + insert + `prepare_lazy_members`. Return none if `!ready` or `MEMBERS_RESOLVED`. |
| `prepareLazyMembers` | :3782 | *new*, mirrors members.rig:3516 | Unaffected names, instantiated declared signatures and index infos, then per base: `instantiate_type` + `get_type_with_this_argument` (members.rig:3458), push the base, `get_properties_of_type(base)` unless its reduced apparent type (members.rig:513) has a ready table (and, after #64526, is not an intersection), append the inherited lists. Then `ready = true`, and if `t` got resolved meanwhile → `resolve_lazy_members`. Re-entrant (§4). |
| `resolveLazyMembers` | :3868 | *new* | Builds a `new_table()`: declared named members via `get_lazy_declared_member`, in Trig's declared order (Go: map order); then `add_inherited_members` (members.rig:1810) per stored base; `set_structured_type_members` (constructors.rig:121) with the table's lists; `lazy_member_tables.take(t)`. |
| `getLazyDeclaredMember` | :3901 | *new* | `declared` lookup, else the symbol itself if it is unaffected, else `new_instantiated_symbol(symbol, mapper)`; store it. |
| `getMemberOfStructuredType` | :3921 | *new* | Resolved → `table_get(structured_members(t), name)`, else `get_member_of_unresolved_structured_type`. |
| `getMemberOfUnresolvedStructuredType` | :3945 | *new* | No table, or a reserved name (`is_reserved_member_name`, utilities.rig:311) → resolve. Otherwise the declared member (`interface_declared_members(target)`), then the first base (in order) whose `get_property_of_type_ex(base, name, true, false)` is non-zero and not a static private (`is_static_private_identifier_property`, members.rig:1823), stopping once the result is a Value. |
| `everyPropertyOfStructuredType` / `hasPropertiesOfStructuredType` | :3997 / :4016 | *new* | The predicate is a closure in Go and tsrs. Trig's only callers are "is there one" and "all optional": an enum `PropTest` avoids a closure that captures the checker (§4). The non-lazy path walks `structured_properties(resolve(t))`. |
| `everyLazyProperty` | :4021 | *new* | Recursive. `seen: !Set[ast.Atom]`; declared members in Trig's order (Go: map order; the answer is order-free); a base with a ready table recurses, otherwise `get_properties_of_type(base)`. |
| `getSingleSignature` (**neutral**) | checker_10.rs:182 | expressions.rig:1875 | `has_properties_of_structured_type` + `get_index_infos_of_structured_type` + the two signature lists, in place of reading the `resolved` record. |
| `instantiateSymbol` split into `isSymbolUnaffectedByInstantiation` + `newInstantiatedSymbol` (**neutral**) | :2293 / :2305 / :2333 | members.rig:2816 | Split at line 2833. Trig's tail reads `value_symbol_links_name_type(symbol_in)` *before* `symbol` is replaced by its target, and builds a `new_shared_data_symbol` (trig#163): keep both in `new_instantiated_symbol`. |
| `isStringIndexSignatureOnlyTypeWorker` (**neutral**, one caveat) | checker_13.rs:3338 | members.rig:4950 | `not has_properties_of_structured_type(t)` in place of `get_properties_of_type(t).len() == 0`. **Caveat** (tsrs notes): the new form skips `getReducedApparentType`, so for a non-generic mapped type it skips `getApparentTypeOfMappedType`, which can make a type. Behind the switch, keep the old call when it is off, or prove on the type log that it makes nothing. |
| `isFunctionObjectType` (**neutral**) | checker_15.rs:1751 | facts.rig:129 | Signature lists + `get_member_of_structured_type(t, "bind")`. |
| `isWeakType` (**neutral**) | relater_1.rs:1405 (the `IsWeakTypeComputed` memo there is tsrs-only) | relater.rig:53 | Two signature lists, index infos, `has_properties`, `every_property(AllOptional)`. |
| (tsrs only) `own_lazy_member_table`, `lazy_unaffected` memo, `members_resolved_like_go`, the site counters | :3605, :3443 | — | Skip: these serve forks of a shared graph, speed, and the Node API. The `lazy_unaffected` memo is a later speed step (§2, step 9). |

### #64526: lazy members of `{ [P in keyof T]: X }` (stacked on #64475)

| Go (PR) | tsrs | Trig | Change in Trig |
|---|---|---|---|
| `Checker.lazyMappedTables` field | checker.rs:1239 | checker.rig | *New*: `lazy_mapped_tables: Map[TypeId, U32]`, `lazy_mapped: List[LazyMappedTable]`. |
| `getSignaturesOfStructuredType`: a mapped type has no signatures (**switch**) | checker_09.rs:3075/3096 | members.rig:72 | `return SigList() if lazy_members and object_flags & MAPPED != 0`, after the lazy-table test. This is the one change that cuts type creation. |
| `getIndexInfosOfStructuredType`: lazy mapped table | :3152 | members.rig:875 | `if get_lazy_mapped_table(t) as i` → `get_lazy_mapped_type_index_infos(t, i)`. |
| `prepareLazyMembers`: skip the eager base resolution for an intersection base | :3782 (:3815) | (step 2's new code) | Add `type_flags(reduced) & INTERSECTION == 0`. |
| `getMemberOfUnresolvedStructuredType`: lazy mapped table first | :3945 | (step 2's new code) | Mapped and not reserved → `get_lazy_mapped_type_member`; if it answers, return that, else fall through. |
| `resolveMappedTypeMembers`: take the table; reuse its members and index infos | checker_10.rs:2526 | members.rig:5705 | `lazy = lazy_mapped_tables.take(t)` after the upfront empty members; pass the table to the worker; at the end, if `index_infos_ready`, use the table's infos. |
| `addMemberForKeyTypeWorker` | :2919 | members.rig:5760 `add_mapped_member_for_key_type` | Three arms: an existing prop (as now); a member the table created → `table_put` that one; else `new_mapped_type_member`. The index-info arm runs only if there is no table or its infos are not ready. Trig passes nine parameters through two subs; an `obj MappedResolve` holding them (tsrs's `MappedTypeMembersState`, :2906) would shorten both, but is optional. |
| `newMappedTypeMember` (**neutral** extraction) | :2651 | *new*, from members.rig:5780–5800 | Moved code, returning the `Sym`. |
| `appendMappedTypeIndexInfo` (**neutral** extraction) | :2616 | *new*, from members.rig:5802–5812 | Moved code. Trig appends into a `!List[InfoId]` rather than returning a list. |
| `lazyMappedTable` struct | :2708 | *new* `obj LazyMappedTable` (§3) | |
| `getLazyMappedTable` | :2738 / worker :2752 | *new* | Only for `(MAPPED\|MEMBERS_RESOLVED) == MAPPED` and `is_mapped_type_with_keyof_constraint_declaration` (members.rig:5161), with no name type (5136), and an apparent modifiers type (5177, 439) that is Object. **Take tsrs's form:** the PR resolves the template type at creation, which recurses on joi's `SchemaLike` until TS5115/TS2456. tsrs resolves it only in `get_lazy_mapped_type_index_infos`, under `resolving`, which also makes tsgo-pr-b match tsgo-ref there (tsrs `testdata/regressions/lazy-mapped-template-cycle`). That needs a DIVERGENCE note against the PR. |
| `getLazyMappedTypeMember` (returns `(member, ok)`) | :2811 | *new* | Return `Sym?`: `none` means not answered. Put a 0 placeholder first ("being made / no member"). `get_member_of_structured_type(modifiers, name)`. If `t` got resolved meanwhile → its member. If the key type from `get_literal_type_from_property` (members.rig:6077) is not usable as a property name, or names something else → drop the placeholder, return `none`. Else `new_mapped_type_member(..., key, key, name)`. |
| `getLazyMappedTypeIndexInfos` | :2859 | *new* | Guarded by `resolving`. For each info of `get_index_infos_of_type(modifiers)`, append the mapped index info. If `t` got resolved meanwhile → its infos; else store with `ready = true`. |
| `somePropertyReducesToNever`: one lazy constituent is looked up by name (**switch**) | checker_11.rs:769 | members.rig:5229 | `skipped` = the first constituent that is an unresolved mapped type, or `may_have_lazy_members` and Object. Count the others' properties, then add one for each counted name that `get_property_of_type_ex(types[skipped], name, true, false)` finds, walking `counts` in order. Trig's `counts` is already an ordered `Map[ast.Atom, Int]`, so this is the #64521 form tsrs ported. The walk calls `!@` while it reads `counts` (§4). |

### Where Trig's structure differs from tsgo's, and why it matters

1. **Resolved members are ids, not a record.** `resolve_structured_type_members` returns the `TypeId`, and readers go through `structured_*` accessors in the store. So the Go rewrites that replace `resolved.X` reads are, in Trig, rewrites of `structured_*(resolved)` reads. There are about 35 such sites (constructors, nodebuilder, expressions, relater, inference, members, modules, symbolresolution, types). All of them follow a resolve, and only the PR's sites change. The tables' `SigList`/`InfoList`/`TypeList` are ranges into shared lists: they copy by value and hand straight to `set_structured_type_members`, as Go reuses its slices.
2. **Member tables are `Tab` ids into `Checker.tabs: List[Map[ast.Atom, Sym]]`, ordered and never freed.** Go walks `declaredMembers` (a map) in random order in `prepareLazyMembers`, `resolveLazyMembers` and `everyLazyProperty`. Trig walks the declared order, as `instantiate_symbol_table` already does (members.rig:2806), so the resolved table's order matches the eager path. Since tables are never freed, a table removed from `lazy_member_tables` stays valid for callers still holding its id, so Go's "kept alive by GC" comes free. The cost is that the memory is never reclaimed.
3. **Symbols are shared-data symbols** (trig#163: `new_shared_data_symbol`, about 12 bytes). Each symbol saved is cheaper in Trig than in Go or tsrs. Peak savings will be smaller than tsrs's 17–25%; the instruction and time savings from making fewer symbols and links remain.
4. **Mappers** are `MapperId` records, and their layout is changing on `mapper-slots`, which lands first. The table holds a `MapperId` plus the padded `TypeList`, and needs nothing from the layout.
5. **Walking a table while the checker writes** needs NEEDS 42 (`table_entries` copies a list). Three new walks run often: `every_lazy_property` (every `isWeakType`), `resolve_lazy_members`, and prepare's unaffected scan. Copying a list each time would eat into the gain. See §4 for the index-walk alternative.
6. **No env or flag reading in the core** (AGENTS rule 4). The switch is a `Checker` field set by the driver or CLI, not tsrs's `TSRS_LAZY_MEMBERS`.

## 2. Build order

Each step leaves Trig byte-identical with the switch off: every suite plus the type log against the pin. Each step is measurable with the switch on: the bench counters and time. **Counters** means symbols, types, signatures and instantiations. `tools/checker/bench.rig:140` prints types, signatures and instantiations today; step 0 adds `symbol_count`.

| # | Step | Off-mode gate | On-mode measure | Lines (Rig) |
|---|---|---|---|---|
| 0 | Plumbing: `Checker.lazy_members` set by the driver/CLI (a non-tsc flag such as `--lazyMembers`, owner's call); `symbol_count` in bench and driver output; an optional `LazyStats` (tables made, resolved in full, members instantiated, lookups answered) | suites, type log | flag reaches the checker | 30–50 |
| 1 | Neutral refactors of #64475: split `instantiate_symbol`; extract `append_inherited_signatures_and_index_infos` and `get_reference_member_type_arguments`; add `get_member_of_structured_type`/`_unresolved` (which still just resolve), `every_property_of_structured_type`/`has_properties` (non-lazy path only); rewrite `get_property_of_type_ex`, `get_single_signature`, `is_weak_type`, `is_function_object_type`, `is_string_index_signature_only_type_worker` (the last switch-guarded, per the caveat) | suites, type log, counters equal; time within 2% (these sit on hot paths, `isWeakType` and `getPropertyOfType`) | none (no tables yet) | 120–160 changed |
| 2a | Tables, signatures and index infos: record + maps, `may_have_lazy_members`, `get_ready_lazy_member_table`, `prepare_lazy_members`, `resolve_lazy_members`, `get_lazy_declared_member`; hooks in `resolve_type_reference_members`, `get_signatures_of_structured_type`, `get_index_infos_of_structured_type`. Member lookups still resolve in full (through `resolve_lazy_members`). | unchanged (all gated) | suites byte-identical; type log equal to the pin; types and instantiations equal off-mode; symbols about equal (prepare plus full resolution makes the same symbols in another order) | 180–220 |
| 2b | Lazy lookups: the table branch of `get_member_of_unresolved_structured_type`; `every_lazy_property`; the lazy branch of `every_property_of_structured_type` | unchanged | suites; type log equal to the pin; types and instantiations equal; **symbols drop** (tsrs: 34% on its monorepo); time and peak RSS on ts-pattern and tiny-invariant, Mac and pup | 70–90 |
| 3 | Neutral refactor of #64526: extract `new_mapped_type_member` and `append_mapped_type_index_info` from `add_mapped_member_for_key_type` | suites, type log, counters | none | 50–70 changed (mostly moved) |
| 4 | Lazy mapped tables: record + maps, `get_lazy_mapped_table` (tsrs's template-deferred form), `get_lazy_mapped_type_member`, `get_lazy_mapped_type_index_infos`; hooks in `resolve_mapped_type_members` and its worker, `get_member_of_unresolved_structured_type`, `get_index_infos_of_structured_type`; the mapped early return in `get_signatures_of_structured_type`; the intersection test in prepare | unchanged | suites byte-identical (**the first step where type ids move**: the type log stops matching the pin, so the gate is the suites plus tsrs's counters); symbols and types drop | 150–190 |
| 5 | `some_property_reduces_to_never`'s skipped constituent | unchanged | suites; symbols drop (tsrs: 93K constituents skipped on its monorepo) | 25–35 |
| 6 | Tests and docs: the PRs' own tests (`instantiatedReferenceLazyMembers.ts`, `mappedTypeLazyMembers.ts`, from the patches, with their baselines) and tsrs's `lazy-mapped-template-cycle`, run in both modes; DIVERGENCE rows or a "lazy members mode" section; CHANGELOG/HANDOFF | — | — | 40–60 Rig/test + docs |
| 7 | (optional, tsrs L1) tuple references get tables: one condition in the worker | unchanged | symbols down 13% more, peak down 5% (tsrs) | 2–5 |
| 8 | (optional, tsrs L11, L10, L6, L5) empty-object tests from tables; unmatched properties without instantiating; union prop-cache copy; conditional-mapper composite | unchanged | each switch-gated, measured alone | 20 / 80 / 25 / 30 |
| 9 | (optional, speed) the table index in the per-type `structured` record instead of `Map[TypeId,U32]` (`gen-store.py`, after mapper-slots); tsrs's per-target `unaffected` memo | unchanged | instructions and time | 30–60 |

**Total for both PRs (steps 0–6): about 650–880 lines of Rig**, about 350 of them new. Go's diffs are +287/−37 (#64475) and about +250/−60 (#64526) in `checker.go`, and Trig's line count runs about 1.3–1.5× Go's for list-building code. The follow-ups add about 200.

**Cross-check oracle with the switch on.** tsrs's counters equal tsgo-pr-a and tsgo-pr-b exactly. For a per-project comparison, run tsrs single-threaded with `--checkerAssignment go`, with the master switch on and the candidates off (`TSRS_LAZY_TUPLES=0 TSRS_LAZY_COND_MAPPER=0 TSRS_LAZY_PROP_CACHE=0 TSRS_LAZY_UNMATCHED=0 TSRS_LAZY_EMPTY=0`); `--extendedDiagnostics` prints the counts. That matches steps 0–5. tsrs has no #64475-only switch (its numbers for that came from a build of commit 1), so steps 2a and 2b are judged by "types and instantiations unchanged, type log equal to the pin", which is a stronger gate anyway.

## 3. New data, sketched in Rig

```rig
# Go: lazyMemberTable (#64475). One per instantiated class/interface reference
# answered lazily; by LazyId, never freed (a table taken out of the map stays
# valid for callers that still hold its id).
obj LazyMemberTable
  ready: Bool                 # set last by prepare_lazy_members
  mapper: MapperId
  type_arguments: TypeList    # padded; the last one is the this-argument
  unaffected: AtomList        # sorted atom ids of declared members that
                              #   instantiate to themselves (or: pre-seed `declared`, below)
  call_signatures: SigList
  construct_signatures: SigList
  index_infos: InfoList
  base_types: TypeList        # instantiated, with the this-argument
  declared: Tab               # name -> the member handed out (a checker Tab, made lazily)

# Go: lazyMappedTable (#64526)
obj LazyMappedTable
  type_parameter: TypeId
  modifiers_type: TypeId      # apparent
  template_modifiers: U32
  should_link_prop_declarations: Bool
  members: Map[ast.Atom, Sym] # 0 = "being made / no member" (Go's nil entry); absent = not asked
  index_infos: InfoList
  index_infos_ready: Bool
  resolving: Bool

# on Checker
lazy_members: Bool = false
lazy_member_tables: Map[TypeId, U32]     # Go lazyMemberTables; value = index in lazy_tables
lazy_tables: List[LazyMemberTable]
lazy_mapped_tables: Map[TypeId, U32]
lazy_mapped: List[LazyMappedTable]
```

Notes:

- `unaffected`: Go keeps a sorted `[]string` and binary-searches it; only membership matters. Trig can sort atom ids, or **pre-seed `declared` with the unaffected members themselves**, which answers the same and needs no second structure. (The "uninstantiated stand-in" lookups of L9/L10 read `declared` first too, so they still agree.)
- The template type is not stored in `LazyMappedTable`. It is fetched under `resolving`, as tsrs does.
- `List[LazyMemberTable]` must not be read through a view across any `!@` call (below), so every read copies the fields it needs, which are all ids.

## 4. For the Rig expert: what looks hard in the ownership model (flagged, not solved)

1. **A table read while it is being filled.** `prepare_lazy_members` runs with the table already in the map and `ready = false`. It calls back into `get_ready_lazy_member_table`, `get_properties_of_type`, `instantiate_*` and `get_base_types`, which can reach the same type or other tables, push to `lazy_tables` (growing it), and even resolve `t` in full. Rig cannot keep a `?`/`!` view of `lazy_tables[i]` across those `!@` calls. The plan: hold only the index, build the four lists in locals, and write the record's fields by index once at the end, before `ready = true`. Is that the idiomatic form, or should the record be a separate object handed back and forth?
2. **A table taken out of its map while callers still use it.** `resolve_lazy_members` does `lazy_member_tables.take(t)` while an outer `get_member_of_unresolved_structured_type` or `every_lazy_property` for the same `t` may still read its `base_types` and `declared`. With an append-only `List` and an index, that is safe, but nothing is ever freed. Reclaiming slots (a free list) would need proof that no frame holds the index. Is there a Rig pattern, such as an epoch or a scope-bound loan on the list, that makes reuse checkable?
3. **Walking a map while the checker writes** (NEEDS 42): declared members in three hot walks, and `counts` in `some_property_reduces_to_never`, whose loop calls `!@` per name. Today's answer is `table_entries` (a copy per walk). Map has `at(i)` now ("one step while no entry has been taken"). Is an index loop that copies `(name, sym)` out of `at(i)` and drops the view before each `!@` call sound and cheap? Binder tables are read-only to the checker, so their walks could also take a `?program` view.
4. **A nested Map inside a list record inside the Checker** (`lazy_mapped[i].members`), written between `!@` calls (placeholder put, recursive calls, final put or take). Each write must be a fresh `!@lazy_mapped[i].members.put(...)` with no `edit()` view held across a call. Is there a cheaper shape, such as one checker-wide `Map[(TypeId, Atom), Sym]`?
5. **The predicate of `every_property_of_structured_type`.** Go passes a closure. In Trig it would be called with the checker lent `!` (`filter_type` already does this: `|+include, c, s| ...`) while `every_lazy_property` also holds `!seen`. Is an enum of the two predicates (`Any`, `AllOptional`) preferable to a closure here?
6. **Go's `defer lazy.resolving = false`** in `get_lazy_mapped_type_index_infos` has an early return between set and reset. Rig: reset on each path, or a scope-exit action?
7. **Three return values** (`appendInheritedSignaturesAndIndexInfos`, `getReferenceMemberTypeArguments`): a small result object, or `!List` out-parameters? It is on a hot path, inside every prepare and eager resolve.

## 5. Risks and checks specific to Trig

- **Do reads of `MEMBERS_RESOLVED` assume resolution?** Go code that reads a type's members after calling `getPropertyOfType` can no longer assume the type is resolved. The PR handled Go's sites. Trig-only shortcuts (none found: every `structured_*` read follows a `resolve_structured_type_members`) must be audited in each step.
- **The base-type cycle reset** (members.rig:141) clears `MEMBERS_RESOLVED`. A table for that type stays in the map, so the worker's `MEMBERS_RESOLVED` test and `prepare`'s "resolved meanwhile" branch matter here. Port them exactly.
- **The type log** (`tools/checker/typelog`) is the decisive gate for steps 1–3. From step 4 on, either build a `dumptypes` oracle from tsgo-pr-b (with tsrs's template-deferral change and the ordered `somePropertyReducesToNever`) or accept suites plus counters.
- **Checker tasks** (HANDOFF item 5): tables are per checker, with nothing shared. tsrs's fork-copy logic (`own_lazy_member_table`) is not needed.
