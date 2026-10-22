# Lazy member tables in Trig: how they fit Rig

Sources read: Rig docs/CORE.md (§2, §4, §5), docs/QUICK.md, SPEC.md ("An object
that names its none", "Reading", `pub ?` fields), docs/STD.md (Map and Set,
List, std.sort), std/__rig_builtin.rig (Map layout), src/runtime.zig (List
layout); tsrs notes/lazy-members.md, checker_09.rs and checker_10.rs (the
tables), tsrs/upstream/patches/base/0001 and 0002 (the Go of #64475 and
#64526); Trig docs/checker/DESIGN.md, NEEDS.md, src/checker/checker.rig,
members.rig, store_generated.rig, declarations.rig.

Nothing was built or run. The code below is a sketch in Trig's style. Its
spellings have not been checked by `rig check`.

## 0. Short answer

- The lazy tables are records in two Lists on the Checker, named by
  `U32` ids. Two Maps index them by `TypeId`. Each table's per-name
  entries live in one Map per kind for the whole checker, keyed by
  `(table, name)`, rather than in a Map inside each record. That keeps
  every record plain data, 48 and 24 bytes.
- `ready` stays a `Bool`, as in Go. The fields it guards are one plain
  object, `LazyMembers`, written once by a single writer just before
  `ready` is set. Rust needed a `OnceCell` only because it shared the
  table through `Rc`/`P` pointers and so needed mutability through a
  shared reference. Rig has one owner (the checker) and ids, so it needs
  nothing like that.
- "A table dropped from the map stays alive for callers still holding it"
  is automatic. Dropping the table is `take` on the index Map, and the
  record stays in the List, so a caller's id stays valid.
- Every reentrant path in Go maps onto ids plus copying small values out.
  Rig rejects exactly one thing here: holding a view of a record, or
  walking a Map, across a `(!@)` call. That view would dangle in any
  language, because a nested call can push to the List and move its
  buffer.
- **Rig needs no new feature.** Two notes are recorded in §3 as
  observations, not needs.

## 1. The representation

### 1.1 Ids

```rig
# A lazy member table: its index in `lazy_member_tables`, plus one.
obj LazyTab
  id: U32
  none id == 0

# A lazy mapped table: its index in `lazy_mapped_tables`, plus one.
obj LazyMap
  id: U32
  none id == 0

# A name in one lazy table: the key of the checker-wide entry Maps.
obj LazyName
  table: U32          # LazyTab.id or LazyMap.id
  name: ast.Atom
```

`LazyTab?` is 4 bytes, and `if (!@).get_ready_lazy_member_table(t) as lt`
is one compare. Go's `*lazyMemberTable` nil is `none`. `LazyName` is
8 bytes, so a Map keyed by it stores no hashes (`stores_hashes` is
`$size(K) > 8`).

Trig's other ids (`Sym`, `TypeId`, `Tab`) are `U32` aliases where 0 is
none. A `LazyTab` could be a bare `U32` alias too. Making it a
named-none object matters only where it sits in an optional, chiefly as
a Map value (§4).

### 1.2 Records (Go #64475, `lazyMemberTable`)

```rig
# Go lazyMemberTable's fields that prepareLazyMembers fills, set together
# just before `ready` (Go assigns them in one statement, then ready = true).
obj LazyMembers
  unaffected: AtomList = AtomList()            # sorted atom ids of declared members that instantiate to themselves
  call_signatures: SigList = SigList()
  construct_signatures: SigList = SigList()
  index_infos: InfoList = InfoList()
  base_types: TypeList = TypeList()

# Go: lazyMemberTable (microsoft/TypeScript#64475)
obj LazyMemberTable
  mapper: MapperId = 0
  ready: Bool = false
  m: LazyMembers = LazyMembers()
  # Go `declared` is `Checker.lazy_declared`, keyed by (this table, name).
  # Go `typeArguments` is read only for prepareLazyMembers's thisArgument,
  # which runs right after creation; it is passed there (as tsrs does).
```

These fields go on the Checker, beside its other stores:

```rig
lazy_member_tables: List[LazyMemberTable] = List()   # by LazyTab.id less one; never shrinks
lazy_member_index: Map[TypeId, LazyTab] = Map[TypeId, LazyTab]()   # Go `lazyMemberTables`
lazy_declared: Map[LazyName, Sym] = Map[LazyName, Sym]()           # every table's Go `declared`
```

How the Go maps to Rig:

- **Go's `delete(c.lazyMemberTables, t)`.** This becomes
  `_ = (!@lazy_member_index).take(t)`. The record stays at its index,
  and so do its `lazy_declared` entries. A caller up the stack that still
  holds `lt` (for example `getMemberOfUnresolvedStructuredType`, between
  base types) reads and writes the same record as before. This is tsrs's
  arena status of 2026-10-10, with no arena: the List is the arena.
- **`unaffected`.** Go binary-searches a sorted `[]string`. Trig sorts
  atom ids into a range of `store.atom_lists` and tests membership with
  `sort.search` over a read view of that range. The answer is the same,
  because the list is only ever searched and never printed or walked in
  order. It counts as an index that gives the same answers (AGENTS
  rule 7).
- **Signatures, index infos and base types** are ranges of the shared
  lists, `{start, count}`, which are immutable once made. They are
  exactly what `resolve_lazy_members` hands to
  `set_structured_type_members`, as Go hands over its slices.

### 1.3 Records (Go #64526, `lazyMappedTable`)

```rig
enum InfoState: U8        # Go's indexInfosReady and resolving, which are never both true
  unready
  resolving
  ready

# Go: lazyMappedTable (microsoft/TypeScript#64526)
obj LazyMappedTable
  type_parameter: TypeId = 0
  template_type: TypeId = 0
  modifiers_type: TypeId = 0
  index_infos: InfoList = InfoList()
  template_modifiers: U8 = 0              # MappedTypeModifiers
  should_link_prop_declarations: Bool = false
  infos: InfoState = .unready
```

On the Checker:

```rig
lazy_mapped_tables: List[LazyMappedTable] = List()
lazy_mapped_index: Map[TypeId, LazyMap] = Map[TypeId, LazyMap]()     # Go `lazyMappedTables`
lazy_mapped_members: Map[LazyName, Sym] = Map[LazyName, Sym]()       # every table's Go `members`
```

tsrs's `Option<Option<Symbol>>` comes out like this:

- The outer optional is whether `lazy_mapped_members` holds the key
  (`Map.get` gives a `(?Sym)?`).
- The inner optional is the stored `Sym`, where 0 means "being created"
  or "no member". This matches Go, where a present nil entry differs from
  an absent key.
- `get_lazy_mapped_type_member` returns `(Sym, Bool)`, Go's
  `(member, ok)`, as two results.
- Go's `delete(lazy.members, name)` becomes
  `_ = (!@lazy_mapped_members).take(key)`. This Map is only looked up by
  name and never walked, so the place `take` leaves until the Map
  compacts does not matter.

### 1.4 Why not a Map inside each record

A Rig `Map` is a 104-byte header: `len`, then the Lists `es` and `hs`,
then a `Table` of two Lists, each List 24 bytes. A record holding one
would have three problems:

1. It would take 104 bytes before its first `put`. Across the private
   monorepo's 881,767 tables (single checker), that is about 92 MB of
   headers alone, where Go's map header is about 48 bytes and tsrs's
   table is 24.
2. The record would own a resource, so it could no longer be copied out
   in one read (§2.1).
3. A fill would need `!@lazy_member_tables[i].declared` in the same
   statement as the call that makes the symbol. Rig rejects that whenever
   the call takes `!@`, which is why the shared Map is the shape that fits
   (§2.3).

## 2. Where Rig's rules push back, and the idiom for each

Throughout, the checker is `!Checker`. Each `(!@).f()` call touches all of
`@` (CORE §5), and reentrancy is legal: a nested call simply gets `@` lent
on. What Rig polices is what may be *held* across such a call.

### 2.1 A view of a record across a `(!@)` call: rejected; copy it out instead

`r = ?@lazy_member_tables[i]` followed by `(!@).instantiate_type(...)`
while `r` is live is rejected ("cannot lend `@` to write while a read loan
... is live"). That is the real hazard: `instantiate_type` can create
another lazy table, `push` to the List, and move its buffer.

The idiom is to copy the record out. The record is plain data (U32s and
ranges), so a typed binding or an accessor that returns by value takes a
48-byte snapshot with no loan:

```rig
fun Checker.lazy_members(?@, lt: LazyTab) -> LazyMembers
  @lazy_member_tables[Int(lt.id) - 1].m
```

The snapshot is never stale where it is read. Go reads `lm`'s fields
only after `ready`, and after `ready` they never change, so a copy taken
then is the truth for good. The only field that changes later is
`ready`, and the only writes after it are to `lazy_declared`, which is
not in the record.

### 2.2 Walking a table while the checker writes: rejected; copy, or walk by index

`for e in ?@tabs[k].items()` with a `(!@)` call in the body is rejected.
Several functions walk a table and call into the checker as they go:

- `prepare_lazy_members`, `resolve_lazy_members` and
  `every_lazy_property` walk `declaredMembers` and call
  `is_named_member`, `get_lazy_declared_member` and `f`, each `!@`.
- `every_lazy_property` and `get_member_of_unresolved_structured_type`
  walk `base_types` and call `get_property_of_type_ex` and
  `get_properties_of_type`.

There are two idioms:

- **Ranges:** copy the `TypeList` (8 bytes) and read
  `(?@).type_at(list, k)` each step. This already works, because ranges
  are immutable.
- **Tables:** `(?@).table_entries(tab)` copies the entries, which is
  Trig's existing NEEDS-42 workaround. To avoid the allocation, a
  copying accessor `fun Checker.table_entry_at(?@, t: Tab, i: Int) ->
  TableEntry?` over `Map.at` reads each step, with no loan between steps.
  Binder tables never `take`, so `at` is one step there. A declared-member
  table never changes during the walk: the Go code walks
  `resolveDeclaredMembers(source).declaredMembers`, which is complete
  before the walk.

### 2.3 Writing one table's entries while reading another: free with shared Maps

A read of `@lazy_member_tables[j].mapper` and a write
`!@lazy_declared.put(...)` touch different fields of `@`, so they can sit
in one body. Two elements of one List are *not* disjoint (`?v[i]` and
`!v[j]` are both loans on `v`, CORE §5). That would bite if a record held
its own Map and one table's fill read another table's record in the same
statement. With the entries in a separate checker field, and records
copied out first, it never arises.

### 2.4 Reentrant fill: keep Go's order exactly; do not take the record out

Three reentrant cases, and the Rig shape of each:

| Go reentrancy | Rig shape |
|---|---|
| `getReadyLazyMemberTableWorker` puts `lm` in the map **before** `prepareLazyMembers`. A nested lookup of the same `t` sees `ready == false` and gets nil, then falls back to `resolveStructuredTypeMembers`, which resolves `t` in full. | Push the record, `put` the index, call `!@prepare_lazy_members(t, lt, this_arg)`. Collect `base_types` and the signatures in locals (`List[TypeId, inline: 8]`, ranges). Write `m` once at the end, then `ready = true`. Nested callers never read the record before `ready`, so local accumulation is equivalent to Go's progressive `append`. |
| After prepare, `if t.objectFlags & MembersResolved != 0 { resolveLazyMembers(t, lm) }`: `t` was resolved while it was being prepared. | The same call. `resolve_lazy_members` takes the index entry, and the id stays valid. |
| `getLazyDeclaredMember` reads `declared[name]`, calls `newInstantiatedSymbol`, then writes. | `key = LazyName(lt.id, name)`, `result = @lazy_declared.get(key) ?? 0`, then the call, then `!@lazy_declared.put(key, result)`, in Go's order. If the call reentered and stored the name first, the later `put` overwrites, as Go's assignment does. |
| `getLazyMappedTypeMember` stores a nil sentinel **before** calling `getMemberOfStructuredType(modifiersType, name)`, so a recursive lookup sees "no member". | `!@lazy_mapped_members.put(key, 0)` before the call. It is a value in a shared Map, so a nested lookup sees it. |
| `getLazyMappedTypeIndexInfos`: `resolving = true`, compute, `resolving = false`, recheck `MembersResolved`, store. | Assign `@lazy_mapped_tables[i].infos = .resolving` between calls. A nested call reads `.resolving` and returns an empty `InfoList`. |

The idiom to avoid here is "take a record out of its List while it is
worked on" (`swap` with an empty value, or an optional field emptied by
`<`). It is the usual Rig answer when an owned part must be lent to write
alongside `!Checker`. For lazy tables it would be *wrong*: a reentrant
lookup must see the sentinel and the `resolving` and `ready` state, not an
emptied slot. Keeping the state in plain fields and shared Maps, written
before each call that can reenter, preserves Go's semantics exactly. Taking
out stays right for scratch that no reentrant call reads. An example is
`every_lazy_property`'s `seen` set if it is pooled on the checker:
`seen = (!@free_atom_sets).pop() ?? Set[ast.Atom]()`, passed as `!seen`,
then cleared and pushed back, as `free_type_mappers_caches` is already used
in members.rig:2998.

### 2.5 Write views are never stored; closures do not capture the checker

- There is no `!LazyMemberTable` handle to keep across calls, and Rig
  forbids a write view in a field or a long-lived local. The id is the
  handle, and writes are `@lazy_member_tables[i].field = v` or a `sub` on
  the record (`!@lazy_member_tables[i].fill(m)`).
- Go's `everyPropertyOfStructuredType(t, f func(*ast.Symbol) bool)`
  becomes `f: ?fun(!Checker, Sym) -> Bool`. This is the shape
  `map_type_with_alias` and `compare_properties` already use, and
  DESIGN §4 records a probe showing such closures work. The closures
  (`isWeakType`'s, `hasProperties`'s `false`) take the checker as a
  parameter and capture no view of it. `seen` passes down the recursion
  as `!Set[ast.Atom]` (a held `!T` lends on).

### 2.6 Set-once is a convention, enforced by one writer

Rig has no write-once field, and none is needed. Give `LazyMemberTable` a
single writer, `sub fill(!@, m: LazyMembers)`, which sets `m` and then
`ready`, and panics (`go_panic`) if `ready` is already true. If the record
lives in a module of its own, `pub ?ready` and `pub ?m` make every other
module read-only on them (SPEC "`pub ?name`"). That is a
compile-time guarantee that only `fill` writes them.

## 3. Does Rig need a new feature? No

Each shape tsrs needed has a Rig equivalent already in Trig's use:

| tsrs shape | Rig shape |
|---|---|
| `OnceCell` (mutation through a shared pointer) | a `Bool` plus a plain field, under one owner |
| `Rc` / arena pointer that outlives the map entry | an index into a List that never shrinks |
| `RefCell<FxHashMap>` per table | one checker Map keyed `(table, name)` |
| `Option<Option<P<Symbol>>>` | `Map.get` optional times `Sym` 0, returned as `(Sym, Bool)` |

I looked for anything that cannot be expressed and found none. The
reentrancy rules Rig enforces (no view held across `!@`) are the ones the
design must follow anyway, because the List's buffer moves.

Two observations, not needs:

1. **A `Map` value pays an optional flag** (`Entry.value: V?`). A Map whose
   value is a `U32` alias such as `Sym` or `TypeId` therefore spends 8
   bytes on each value. If the value type is an object that names its
   none, the value is 4 bytes. NEEDS 39 asked for exactly this, and Rig
   has built it ("An object that names its none", SPEC). Moving Trig's
   `Sym`, `TypeId` and similar ids from aliases to such objects would
   shrink every `Map[_, Sym]` and `Map[_, TypeId]` cache, not only these
   tables. That is a Trig-wide decision, and NEEDS 39 can be closed.
2. **The 104-byte `Map` header** is why per-record Maps are avoided (§1.4).
   Nothing here needs it smaller. A program that keeps a million small Maps
   would want a smaller empty Map (one word until first use), but that is a
   Rig speed question for its own measured case.

## 4. Memory

Sizes are on a 64-bit target. Zig lays out the emitted objects without the
declared order, so padding is minimal.

| Record | Fields | Bytes |
|---|---|---|
| `LazyTab`, `LazyMap` | `U32` (and their optionals) | 4 |
| `LazyName` (Map key) | table `U32`, atom `U32` | 8 |
| `LazyMembers` | 5 ranges × 8 | 40 |
| `LazyMemberTable` | mapper 4, `ready` 1, `LazyMembers` 40 | 48 (56 if Go's `typeArguments` range is kept) |
| `LazyMappedTable` | 3 `TypeId`s 12, `InfoList` 8, 3 bytes | 24 |
| `lazy_member_index` entry | key 4 plus `LazyTab?` 4 | 8, plus about 5 bytes per table slot (`tags` U8, `at` U32) |
| `lazy_declared` / `lazy_mapped_members` entry | key 8 plus `Sym?` | 16 (12 if `Sym` names its none), plus about 5 bytes per slot |

How that compares per member table:

- **Go:** a struct of a bool, a pointer, five slices and a map pointer
  (about 170 bytes), a map header, and its index entry.
- **tsrs:** 80 bytes in its arena (a 24-byte `SymbolTable` inline).
- **Trig:** 48 bytes plus about 13 for the index.

For the monorepo's single-checker counts:

- **Tables:** 881,767 member tables are about 42 MB of records and about
  11 MB of index in Trig, against about 70 MB of records in tsrs.
- **Entries:** `lazy_declared` holds one entry per member looked up
  (2.06M of them instantiated), about 16 to 21 bytes each.
- **Mapped tables:** about 40k, under 1 MB.
- **Never freed:** nothing here is freed before the checker is. Go's
  freed table is mostly GC'd memory. In Trig, a table resolved in full
  (14%) keeps its 48 bytes. The `LazyMembers` ranges become the resolved
  type's members anyway, as tsrs notes for its arena slices.

A later option, only on measurement (DESIGN §5), is `lazy: LazyTab` as a
field of `TypeReference`, replacing `lazy_member_index`. It costs 4 bytes
on every reference type, and in exchange each `may_have_lazy_members` hit
becomes one indexed load instead of a hash lookup.

## 5. Sketch of the hot path

```rig
# Go: getMemberOfUnresolvedStructuredType (microsoft/TypeScript#64475)
fun Checker.get_member_of_unresolved_structured_type(!@, t: TypeId, name: ast.Atom) -> Sym
  if (!@).get_ready_lazy_member_table(t) as lt and not is_reserved_member_name(name)
    result: Sym = 0
    source = (?@).type_target(t)
    !@resolve_declared_members(source)
    decl = (?@).table_get((?@).interface_declared_members(source), name)
    if decl != 0 and (!@).is_named_member(decl, name)
      result = (!@).get_lazy_declared_member(lt, decl, name)
    bases = (?@).lazy_members(lt).base_types      # 8-byte copy; no loan
    for k in 0..bases.len()
      break if result != 0 and (?@).symbol_flags(result) & ast.SYMBOL_FLAGS_VALUE != 0
      prop = (!@).get_property_of_type_ex((?@).type_at(bases, k), name, true, false)
      result = prop if prop != 0 and not (?@).is_static_private_identifier_property(prop)
    return result
  (?@).table_get((?@).structured_members((!@).resolve_structured_type_members(t)), name)

# Go: getLazyDeclaredMember
fun Checker.get_lazy_declared_member(!@, lt: LazyTab, symbol: Sym, name: ast.Atom) -> Sym
  key = LazyName(table: lt.id, name: name)
  result = @lazy_declared.get(key) ?? 0
  if result == 0
    result = symbol
    m = (?@).lazy_members(lt)
    if not (?@).atom_list_has_sorted(m.unaffected, name)
      mapper = @lazy_member_tables[Int(lt.id) - 1].mapper
      result = (!@).new_instantiated_symbol(symbol, mapper)
    !@lazy_declared.put(key, result)
  result
```

Note that `get_property_of_type_ex` in the loop may run
`resolve_lazy_members` on `t` itself and `take` its index entry. `lt` and
`bases` stay valid, just as Go's `lm` pointer does.
