# APIs Stage 3, phase 3: notes (2026-10-23)

Phase 3 of [build-plan.md](build-plan.md): method-level bounds and what
remained of additions. The design is
[docs/design/apis.md](../../../../design/apis.md), Stage 3, with the
defaults of [open-questions.md](open-questions.md); phases 1 and 2 are
[phase1-notes.md](phase1-notes.md) and [phase2-notes.md](phase2-notes.md).
Phase 2 already lowered additions and conditional additions
(`add Wrap[T: Shape]: Shape`, with coherence of one addition per API and
type constructor), so this phase builds the rest.

## What is built

| Piece | Where |
|---|---|
| `fun Wrap[T: Print].show(?@)`: the bounds of a method's owner parameters, stripped and recorded by where each name is, and the parameters kept per method | `Parser.tparamBounds` on `owner_params`, `Parser.owner_bounds`, `ownerBoundsAt` |
| What each method adds, by the type's parameter's place: `sema.OwnerBound` on `Field.owner_bounds` | `SymbolResolver.ownerBounds` (`SemContext.owner_bounds`), `TypeResolver.resolveMethod` |
| While a method under bounds is resolved and checked, its type's parameters carry them too; a requirement made on one meanwhile is decided at once, never left for the type's instances | `sema.widenOwnerBounds`, `restoreOwnerBounds`, `ownerWidened`; `typecheck.checkNominal`, `decidedByOwnerBounds` |
| What a method may add: no bound the type gives already, and no ownership fact | `typecheck.checkOwnerBounds` |
| A call meets the method's bounds, by its type's arguments, and records the witnesses it passes | `typecheck.meetsOwnerBounds`, `sema.ownerWitnesses`, the fact `owner_witnesses` (`--facts=sema` prints it) |
| A method under bounds meets no API on the header, gives no own meaning, is no loop's `next`, and is reached by no call on an unbounded `T` or through an actor's handle | `checkConformance`, `checkApiMethod`, `iteratorShape`, `checkMethodCall`, `actorCall` |
| Emit: `comptime W_T_Shape: type` after self, read by type at the top of the body; a call passes the witnesses first among its compile-time arguments, after self when the receiver is the first argument (`Wrap[Square].doubled(?w)`) | `emit.ownerWitnessParams`, `emitFun`, `emitArgs` |
| `add Slot[n]: Shape`, `add Table[T, n]: Shape`, `add Ring[T: Shape, n]: Shape`: a lowercase name in an addition's brackets is a value parameter of the type's parameter's type; every `Slot[n]` keys as one constructor; a witness of a value parameter takes `comptime n: i64` | `SymbolResolver.walkAdd`, `TypeResolver.addedType`, `sema.typeKey`, `conformanceArgs`, `conditionsMet`, `typecheck.genericSym`, `emit.emitWitness`, `writeWitness` |

New cases: 17 in `types-apis` ("apis own method bounds ...", "apis own
add with value parameters", "apis own add a slot twice", "apis own
homes", "apis own method's own bound"), 2 in `emit-apis`; "apis own add a
value parameter" now pins what stays rejected (`add Slot[3]`). SPEC's
"Methods outside the body" and "APIs" say both, with an example and a
rejection; SYNTAX the forms.

## Decisions beyond the design

1. **A method's bounds name no ownership fact.** `Copy`, `Clone`,
   `Owned`, `Moves`, and `Shares`, and an API built on any of them
   (`api Job: Moves`), are rejected on a method toward the type's
   brackets. They say how a value of the type is copied, kept, and sent;
   storage, ownership, the oracle, and emit decide those once per type,
   for every method, and a method that copied a `T` the type does not
   let copy would need each of them to see the method's bounds. With
   this rule only typecheck sees them, and every other pass is unchanged.
   *Default:* keep; a program that needs `T: Copy` for one method bounds
   the type or uses `+x`.
2. **"Repeating a bound" includes one implied:** `T: Shape` on a method
   of `obj Box[T: Named]`, where `Named` builds on `Shape`, is rejected
   as `T: Eq` on `[T: Hash]` would be.
3. **A type argument that holds a type parameter with no bound** meets
   no method bound, even a built-in one: `fun f[U](w: ?Wrap[U])` cannot
   call `w.show()`, and says to write `[U: Print]`. Checking it at each
   instance instead would need a second per-instance path for method
   calls on a generic type, and the witness of an API has nowhere to come
   from. A call on an unbounded `T` (Stage 1) never reaches a method
   under a bound, for the same reason.
4. **Facts no API names inside a method under bounds** (a literal's fit,
   freezing) are recorded on the type's parameter as for any method, so
   they are checked at every instance of the type, whether or not it
   calls the method. Conservative: it may reject an instance that never
   calls the method. *Default:* keep until a program meets it.
5. **Such a method is never a conformance's, an own meaning, or a
   loop's `next`,** and an actor's handle does not call it: each of those
   calls a method with no bound of its own in place. An addition under
   the bound gives the API instead.
6. **An addition's value parameter takes no bound** (open question 11)
   and is named by a lowercase name; `add Slot[3]` and `add Table[T, 4]`
   stay rejected as additions to one instance.

## Messages

- `` `Wrap[Label].doubled` needs `T: Shape`, and `Label` does not provide `Shape`; declare `obj Label: Shape` ``
- `` `Wrap[U].doubled` needs `T: Shape`, and `U` has no bound: a call reaches a method under a bound only where the bounds of its type's arguments give it; write `[U: Shape]` ``
- `` `Box.a` repeats `T: Shape`, which `obj Box[T: Named + Eq]` already gives: a method's bounds add to its type's ``
- `` `Box.c` bounds `T` by `Copy`, which says how a `T` is copied, kept, or sent, the same in every method: bound the type, `obj Box[T: Copy]` ``
- `` `Wrap.area` is declared under `T: Print`, which `Wrap[T]: Shape` does not state: a conformance is met only by methods its own bounds imply; take `Shape` off the header and write `add Wrap[T: Print]: Shape`, which declares `area` ``
- `` cannot iterate over `Count[Int]`: ... its `next` is declared under a bound on its type's parameters, which the loop does not state ``
- `` ... the generic body calls `x.show()`, and `Wrap[Int].show` is declared under a bound on its type's parameters, which a call on a `T` with no bound does not state ``

## Deferred

- `type Item`, `I.Item`, `Iter`: phase 4.
- The oracle's conformance clauses, the Lean lemma: phase 5.
- Public generics state their bounds: phase 6.

## The oracle

It decides the new cases as the compiler does. Its floors in
`test/oracle/coverage` were far below what it decides; they are raised
to today's counts: `tests` 22130 decided functions, `docs` 1020
(`matrix` is unchanged).

## Trig

Phase 3 only accepts more programs. Trig (37f9e6b) emits the same Zig
under main's compiler (2dee0b7ec, phase 2's base) and this one: the 12
programs with a `main` in its `tools/` and `tests/` that build, staged
as its packs stage them (the program beside `src/`'s modules), every
module of each package compared but the runtime, which phase 2 changed;
and all 303 files of `src/` emitted alone, the 49 that emit identical
and the rest rejected alike. Three more programs with a `main` build
under neither compiler (a stale prototype, and two whose `standins`
module a script writes).
