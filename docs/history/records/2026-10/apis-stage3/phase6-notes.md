# APIs Stage 3, phase 6: notes (2026-10-23)

Phase 6 of [build-plan.md](build-plan.md): implied bounds, and the rule
that public generics state their bounds. The design is
[docs/design/apis.md](../../../../design/apis.md), Stage 3, "Public
generics state their bounds", with the defaults of
[open-questions.md](open-questions.md) (6: implied bounds for every
parameter; 7: this phase lands last, on its own; 8: the migration is a
script reading the compiler's own fixes). It is the one Stage 3 change
that rejects programs a release accepted.

## What is built

| Piece | Where |
|---|---|
| A type parameter of a `pub` function, a `pub` type, or a `pub` method of a `pub` type states its bounds (not a set or value parameter) | `SymbolFlags.states_bounds`, set by `SymbolResolver.markStated`; `SemContext.stated` holds the declaration as written, `pub fun sum[T]` |
| Its body is checked against its bounds alone, as a bounded parameter's is | `sema.checkedByBounds`, read by `typecheck.checkBoundedBodies`, `ownership.checkBoundedCopies`, the copy out of a view, `sema.boundLack`/`paramsLack` (`lacks`), `sema.boundBlocker` (crossing), and calls under a method's bounds |
| The error is at the parameter, with the bounds to write and a note at the use: `` `pub fun sum[T]` adds `T`s: write `[T: Num]` `` | `sema.statedMessage`, `boundUse`, `reportStated`, `reportStatedLack`, `reportStatedUser`; `typecheck.statedCrossing` |
| A method call on a `T` of a `pub` declaration goes through a bound: the fix names the one API the module sees that declares the method, else says to declare one | `typecheck.typeParamCall`, `boundForMethod` |
| Implied bounds: a type parameter named as an argument of a generic type in a function's signature, or in a generic type's fields and payloads, has the built-in bounds of the parameter it fills, transitively, whatever the declarations' order | `Symbol.implied`; `TypeResolver.implying`, `implyBounds`; `resolve.impliedFixpoint`; `sema.boundApis` reads them; `sema.checkBounds` checks them at each instance |
| A bound asked of an argument made of other types (`Chain[Pair[T, U]]`) inside a generic declaration waits until types' contents are known | `DeferredCheck.bounds` |
| `tools/state-bounds.py`: runs `rig check`, writes each fix into the brackets, one per parameter a round, until clean; `--dry-run` prints the diff and restores every file | `tools/state-bounds.py`, `test/cli/state_bounds.sh` |

New cases: 20 in `types-apis` ("apis pub states its bounds ...": one
per capability with its fix, the fix that adds to written bounds, the
bound another implies left out, a type's parameter, a method's own, a
private generic per instance, implied bounds through `Map` and through
a type's field declared after its user, an implied bound at an
instance, facts no API names, and the composite argument), and
`test/cli/state_bounds.sh`. SPEC "Bounds" gains "Implied bounds" and
"Public generics state their bounds", with an example and a rejection;
"Generic bodies" and the modules section say which parameters are
checked by bounds.

## Decisions beyond the design

1. **Only built-in APIs are implied.** An API of a program's own adds a
   witness, a compile-time parameter of the declaration that states it,
   so `fun f[T](b: ?Bag[T])` under `obj Bag[T: Shape]` still writes
   `[T: Shape]` (the error says so, at the parameter). *Default:* keep.
2. **Where bounds are implied:** a function's own parameters by its
   parameters' and result's types, and a generic type's by its fields
   and payloads; never by a body's types, and never by a method's
   signature for its type's parameters (a method adds bounds only as
   `fun Wrap[T: Print].m`).
3. **Which declarations state their bounds:** `pub fun`/`sub`, `pub obj`
   and `pub enum` (every method of the type, private ones and `drop`
   included, since they share the parameter), and the own parameters of
   a `pub` method of a `pub` type. A `pub` method of a private type, an
   API's methods and defaults, and an addition's parameters keep their
   rules.
4. **A `pub` generic's task over an unbounded `T` is local,** as one
   over a bounded `T` without `Sends` is (SPEC §18); a crossing that
   needs it (`par.map`, a channel, an actor) is rejected with the fix
   `[T: Sends]` or `[T: Syncs]`. No Trig task changed: its emitted Zig
   has no `spawn` that became `spawnLocal`.
5. **`+x` on a `T` asks `Copy`,** the generic clone's rule today for
   any bounded `T` (a `T: Clone` body's `+x` is rejected toward `Copy`
   as before). The fix says `Copy`. A generic clone of an owning `T` is
   not built; that is when `Clone` would be the bound.
6. **Printing a view of a `T`** (`print(x)`, `String("", x)` with
   `x: ?T`) records the `T`'s requirement, so a bounded body needs
   `Print` there too; Stage 2 checked it only for a `T` by value.
7. **The fix is the whole entry,** the written bounds and the new one,
   less one another implies (`[T: Eq]` hashing asks `[T: Hash]`), so
   `tools/state-bounds.py` replaces the entry and never merges lists.
   It writes one fix per parameter a round; a chain of `pub` generics
   each calling the last takes a round per link.
8. **The composite-argument crash.** `obj Chain[T: Copy]` with
   `fun zip[U](...) -> Chain[Pair[T, U]]` panicked in `sema.copies` on
   `main` (bounds were asked before types' contents were known); such a
   check now waits for them. A case covers it.
9. **Lowering:** a built-in bound changes no call, but a `T: Copy`
   element read is written as any copy type's is: Trig's core.zig reads
   13 elements with `rig.at(xs, i)` where it wrote
   `rig.elemPtr(xs, i).*`. Every other module's Zig is identical.

## The migrations

- **std:** 0 changes (`tools/state-bounds.py` over a program using
  every std module, with `RIG_STD=std`). **examples/:** 0 (no `pub`
  generic).
- **The suite:** about 1,800 bracket entries in test cases, written by
  the script from each case's own files, most of them the generated
  chains of `probes-08` and `probes-01`. Cases that tested a
  per-instance check across modules of what is now a bound ("foreign
  instance requirement", "foreign chain requirement", their CLI
  fixtures, `diagnostics.sh`) test the bound's message, or a fact no API
  names (a literal's fit, an array length). Stage 1 calls across modules
  go through a private generic (`types-generic`, "type param method
  ...").
- **Trig's src/:** 51 type parameters of 49 declarations in 5 files
  ([trig-migration.diff](trig-migration.diff), `git apply` from Trig's
  root). The plan's estimate was about 32: `OrderedMap[K, V]` hashes
  its keys with no `Map` in its fields, so it states `K: Hash`; 39 of
  core/core.rig's slice helpers state `E: Copy`. With it, Trig's
  programs (`tools/trig/main.rig`, and one using every module) check
  clean, and `--tests` over each directory module too. A debug trig
  built from the migrated copy gives byte-identical output to one built
  by `main` from Trig's own src/ on mitt, tiny-invariant, neverthrow,
  and superstruct.

## What Trig must know

The rule rejects Trig's src/ as it is: apply the diff (or run
`tools/state-bounds.py` on a program that uses every module) in the
same step as taking this Rig. `copy_map_into` states `K: Copy, V: Copy`
(not `Clone`, as the plan guessed); `memoize` states `E: Copy + Owned`;
`breadth_first_search_parallel` states `N: Hash`.
