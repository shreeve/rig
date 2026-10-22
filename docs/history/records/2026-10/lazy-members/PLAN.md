# Lazy member tables in Trig: the plan

Merged from three reports (port-map.md, exactness.md, rig-fit.md, beside
this file). Owner's direction: implement it now, and have it on.

## What and why

TypeScript #64475 builds the member table of an instantiated class or
interface lazily, one member at a time, as members are looked up.
#64526 does the same for `keyof` mapped types. In tsrs, with both on:
peak memory 23–25% lower, check time 13–16% lower, 41% fewer symbols.
The pin (655f0268) has neither PR. The authoritative Go diffs are
`~/Data/Code/trig/misc/tsrs/upstream/patches/base/0001` (#64475) and
`0002` (#64526).

## Exactness: the deciding facts

- **#64475 can be exact at every checker count.** Eager resolution
  creates types only through signatures, index infos and base types; the
  lazy table does that same work at the same moment and defers only the
  member symbols. tsrs counted equal types and instantiations, 34% fewer
  symbols. So type ids, union order and the TS2589/TS5115 cut-offs are
  the pin's. What changes is symbol count and symbol creation order:
  check that no output orders by symbol id (a debug counter of symbol-id
  tie-breaks must stay 0).
- **#64526 as posted is not exact:** it skips creating types (tsrs:
  9,842 fewer), which moves type ids and cut-offs. Port only an exact
  variant: keep every type the eager path makes, defer only the symbols.
  Use tsrs's form of the mapped-table creation (resolve the template only
  under the `resolving` guard), not the PR's, which recurses forever on
  joi's `SchemaLike` (tsrs testdata/regressions/lazy-mapped-template-cycle).
- **Several checkers:** tsrs's dify difference (a TS2578 at 5, 7, 8, 12
  checkers) is a moved cut-off leaving a `@ts-expect-error` unused. Rerun
  dify with #64475 alone; expect it exact.

## The switch

`TRIG_LAZY_MEMBERS` (and later `TRIG_LAZY_MAPPED`), read in tools/trig,
never in the core; no CLI flag (tsc rejects unknown options). "Off" runs
the pin's own code. Put the flags in the Swarm job key, so "on" runs never
reuse "off" results.

Staging (owner): on by default in single-checker mode as soon as every
suite is byte-identical with it on; on for `--checkers C` once the
checkers job is exact at each count; `=0` stays as the off switch.

## Build order (each step byte-identical when off)

0. The switch, and symbol/type/instantiation counts in the bench output.
1. Refactors that change no behaviour (tsrs ran them in both modes):
   the split of `instantiate_symbol`, the refactored `get_single_signature`,
   `is_weak_type`, `is_function_object_type`,
   `is_string_index_signature_only_type_worker`.
2. #64475: the lazy table, `prepare_lazy_members` (signatures, index
   infos, base types: the eager type work, at the same moment),
   `get_lazy_declared_member`, `resolve_lazy_members`; answer
   `get_property_of_type_ex` (declarations.rig:630), the signature and
   index-info queries and `every_property` from it.
   Entry: `resolve_object_type_members` (members.rig:3516, called at
   :3513 for an instantiated reference).
3. Tests and the DIVERGENCE row; measure; turn on (single checker).
4. #64526, the exact variant, its own PR, behind `TRIG_LAZY_MAPPED`.
5. (Later, optional) tsrs's follow-ups in notes/mem-lazy.md.

Size: about 650–880 lines of Rig for both PRs.

## Data, in Rig (no new Rig feature needed)

- `lazy_tables: List[LazyMemberTable]` on the Checker, indexed by
  `lazy_index: Map[TypeId, LazyTab]`, where `LazyTab` is a `U32` that
  names 0 as its none (`LazyTab?` is 4 bytes). Go's `delete` is `take` on
  the index; the record stays in the List, so a caller's id stays valid.
- A table's per-name entries in one checker-wide `Map[LazyName, Sym]`
  keyed by (table, name), not a Map in each record (a Map header is
  104 B). Make `Sym` name its none and the entry is 12 B.
- `ready: Bool` plus one plain object of the ranges `prepare` fills,
  written once just before `ready` is set. Mapped tables: a 3-state enum
  (absent, being created, made).
- A table record is 48 B (tsrs: 80); a mapped table 24 B.

## Rig answers to the port map's seven questions

1. A table read while it is being filled: keep Go's write order exactly;
   nested lookups must see the "being created" entry and the
   `resolving`/`ready` state. Never take the record out of its List while
   working on it.
2. A table used after it leaves the map: automatic, by id (above).
3. Walking a Map while the checker writes: walk by index, or copy what
   you need out first. Never hold a view of a record or a Map across a
   `(!@)` call: a nested call may push and move the List's buffer.
4. A Map nested in a List record: don't; use the checker-wide keyed Map.
5. A closure or an enum for the property test: an enum of the few tests
   (data, a direct `match`, no indirect call); a `?fun` parameter also
   works if a test needs captures.
6. Go's `defer` around a flag reset: Rig's `defer`, written beside the
   set, as in Go.
7. Functions returning three lists: several results,
   `-> (A, B, C)`, bound by name at the call; or a small object if they
   travel further than the call.

## Tests first

The PRs' own tests (`instantiatedReferenceLazyMembers`,
`mappedTypeLazyMembers`; not at the pin, so take them from the patches),
tsrs's mapped-template cycle, member order, union order by type id, the
refactored predicates, the recursion cut-offs, dify.

## Measurement and the bar

Main, off and on, interleaved on pup core 3, fastest of 10: time, perf
counts, peak RSS, and the heap profile (`RIG_HEAP_PROFILE=1`). Counters
(tsrs's `LazyMemberStats`) plus four that must stay 0 in debug builds:
extra types created, extra instantiations, members made twice, symbol-id
tie-breaks. The bar: faster, or peak RSS at least 5% lower with time no
worse. Expect smaller memory gains than tsrs's, since Trig's symbols are
already small (trig#163).
