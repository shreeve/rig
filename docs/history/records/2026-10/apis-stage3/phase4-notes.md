# APIs Stage 3, phase 4: notes (2026-10-23)

Phase 4 of [build-plan.md](build-plan.md): associated types and `Iter`.
The design is [docs/design/apis.md](../../../../design/apis.md), Stage 3,
with the defaults of [open-questions.md](open-questions.md) (9: `Iter`
is derived by the loop's own rule); phases 1 to 3 are
[phase1-notes.md](phase1-notes.md), [phase2-notes.md](phase2-notes.md),
and [phase3-notes.md](phase3-notes.md).

## What is built

| Piece | Where |
|---|---|
| `type Item` in an API: a hidden parameter after `Self`, an associated type of `Self`; the API's methods and defaults name it bare | `SymbolResolver.declareApi`, `TypeResolver.resolveApi`, `typecheck.checkApiDefaults`; `Parser.rewriteBuiltin` lets it hide a built-in type's name (`Item`) |
| An associated type is a type parameter its base determines: `Symbol.assoc_of` (base, API, name) and the base's `Symbol.assoc`; one symbol however often it is named, carried by proxies with its base | `sema.AssocOf`, `assocApiOf`, `assocParam`, `importSymbol` |
| `S.Item` in a type: through `S`'s bounds, `Self` in an API, or a type's parameter in its methods | `TypeResolver.assocMember` |
| `[S: Source, S.Item: Ord]`: a dotted entry, its bounds recorded by its base's name and given to the associated type once the APIs are known | `rig.grammar` (`assoc_bound`), `Parser.tparamBounds`, `assocBoundsAt`; `SymbolResolver.noteAssocBounds`, `resolveAssocBounds` |
| Substituting a base substitutes its associated types: a type parameter's own, an iterator's item, or what a conformance gives | `sema.substituteType` → `assocSubst` → `assocType`, `conformanceAssoc` |
| What a conformance gives each associated type: what its methods give where the API's required methods name it, matched by shape | `sema.inferAssoc`, `matchAssoc`, `Conformance.assoc` |
| Each instance checks its associated types' bounds and requirements at what its arguments give them | `sema.withAssoc` in `checkBounds` and `typecheck.checkRequirements` |
| `Iter`, a built-in API: `sema.iterItem` is the one classifier for the `for` loop (`iteratorShape`), the bound (`lacks`), and `I.Item` | `rig.Api.Iter`, `sema.iterItem`, `methodOfType` |
| `(!it).next()` on an `I: Iter`: `fun next(!@) -> I.Item?`, direct | `typecheck.iterNextCall` |
| Emit: `W_S_Source.Item` through the witness of the bound that declares it; `rig.IterItem(I)` for an iterator's item; each witness writes `pub const Item = ...` | `emit.writeTypeParam`, `emitWitness`; `rig.IterItem` in the runtime |
| std.iter: `count[I: Iter]`, `sum[I: Iter, I.Item: Num]` | `std/iter.rig`, `std/embed.zig`, STD.md |

New cases: 11 in `types-apis` ("apis own associated type ...", "apis
iter ..."), 1 in `emit-apis`, 5 in the new `std-iter` (each std
iterator, `text.split`, `lines`, `words`, `chars`, `utf8.runes`, and the
Map and Set iterators, is an `Iter` whose item the loop gives). SPEC's
APIs section gains associated types and `Iter`, with an example and a
rejection; its iterator section names `Iter`; SYNTAX and STD the forms.

## Decisions beyond the design

1. **A provider's associated type is what its methods give,** where the
   API's required methods name it (Swift's inference), with no `type
   Item = Int` member: `Iter`'s `Item` is what `next` gives, and one
   mechanism serves both. An API declares no associated type that none
   of its required methods names (an error at the API). *Default:* keep;
   a member form waits for an API that needs a type no method shows.
2. **An associated type's bounds name built-in APIs only.** `[S: Source,
   S.Item: Shape]` is rejected as not built: a bound by an API of a
   program's own needs a witness of the associated type, a compile-time
   parameter no declaration takes yet. *Default:* build it when a
   program needs one.
3. **A method's bounds on an associated type** (`fun Wrap[T: Iter,
   T.Item: Ord].m`) are rejected as not built: bound it in the type's
   brackets.
4. **`iter.sum` gives `I.Item?`,** `none` for an empty iterator: a body
   over a `T: Num` has no literal of type `T` (`t: T = 0` is rejected
   today), so the sum starts from the first item. *Default:* keep; a
   zero for `Num` waits for a constant in an API.
5. **An associated type does what its own bounds name,** as a bounded
   parameter does (`hasBounds` holds for every associated type): `S.Item`
   with no bound is not copied, compared, or printed.
6. **Two iterators of one type in one body.** A generic body tracks no
   view a `T` holds, so a value of `I.Item` from one `!I` parameter
   alive while another `!I` is advanced is read as a store into the
   other and rejected with the fix `keeps a, b`, as any value of a type
   parameter's type is; one iterator per body, or `keeps`, is accepted.
   *Default:* keep; narrowing it is the backlog's view-tracking item.
   A method under a bound (phase 3) names its type parameter's
   associated types too (`fun Wrap[T: Source].grab(!@) -> T.Item?`).
7. **`iterItem` also rejects a `next` with compile-time parameters**
   ("takes compile-time parameters"), which a loop could not call.
8. **`rig.IterItem` in the runtime** names an iterator's item in Zig, so
   a body bounded by `Iter` needs no witness: `Iter`, like the other
   built-in APIs, takes none.

9. **An instance whose associated type may view memory its base owns
   is rejected** (added in review, [review-p34.md](review-p34.md)): a
   body holds items across `next` without tracking them, so an item
   viewing the iterator's own storage could dangle. Decided at each
   instance by the ownership checker's own reach (`sema.viewReach`), in
   `sema.checkBounds`. It rejects a Map's and a Set's iterators too,
   whose types do not show their items to be outside them, whatever the
   body does with the items: an interim rule, with the design question in
   the review. A bound by `Iter` also takes no view of an
   iterator and no `next` private to another module (`sema.iterLack`).

## Messages

- `` `Source` declares `type Item`, which none of its required methods names: a provider's `Item` is what its methods give in their place ``
- `` `T` has no associated type `Item`: `T` has no bound; `[T: Iter]` gives it `Item`, and an API gives what it declares with `type Item` ``
- `` `big[Floats]` cannot use `I.Item = Float`: `Float` cannot be hashed ``
- `` `iter.count[Label]` cannot use `I = Label`: `Label` is no iterator: it declares no `fun next(!@) -> T?` ``
- `` `Iter` is derived, and a type never names it: `X` provides it by declaring `fun next(!@) -> T?`, which a `for` loop calls ``
- `` `S.Item` has no bound, so it does not give a copy; give it one: `[S.Item: Copy]` `` (the Stage 2 message, for a parameter with no bound of its own)
- `` a bound by an API of a program's own on an associated type, `S.Item: Shape`, is not built yet: ... ``

## Deferred

- The oracle's conformance clauses, the Lean lemma: phase 5.
- Public generics state their bounds: phase 6.
- Learn Rig journey 07's Stage 3 sections: a backlog entry; its "What is
  not there yet" now says Stage 3 runs.

## The oracle

It decides the new cases as the compiler does; its floors are raised to
today's counts, `tests` 22163 and `docs` 1024.

## Trig

Phase 4 only accepts more programs. Trig (37f9e6b) emits the same Zig
under main's compiler (2dee0b7ec) and this one: the 12 programs with a
`main` that build, every module of each package but the runtime (which
gains `rig.IterItem`), and all 303 files of `src/` emitted alone (49
emit, the rest rejected alike), as for phase 3.
