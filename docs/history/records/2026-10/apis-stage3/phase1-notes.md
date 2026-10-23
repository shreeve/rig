# APIs Stage 3, phase 1: notes (2026-10-23)

Phase 1 of [build-plan.md](build-plan.md): declarations and
conformance, checked and not lowered. The design is
[docs/design/apis.md](../../../../design/apis.md), Stage 3, with the
defaults of [open-questions.md](open-questions.md). This page records
how it was built and the decisions the record did not settle.

## What is built

| Piece | Where |
|---|---|
| `api Name[: A + B]` with required methods, defaults, and `type Item` (parsed, rejected); `add Type: A`, `add Wrap[T: A]: B` (any type parses, so the checker can name what `add` takes) | `rig.grammar` (`api`, `amembers`, `add`; nodes `api`, `api_type`, `api_add`) |
| `api` and `add` keywords only at the start of a declaration at the module's margin (after `pub` too), before a name or, for `add`, a type | `src/rig.zig` `classifyWord`, `moduleDeclStart`, `nextStartsType` |
| `[T: Shape]`: a capital parameter with one name after the colon is a bound; resolve tells an API from a type, and `[N: Int]` keeps its error | `Parser.tparamBounds`; `resolve.boundsOf`, `boundNamesType` |
| An API symbol (`SymbolKind.api`): its hidden `Self` (`type_params[0]`), its methods (`fields`, `Field.is_default`), and what it builds on (`apis`, `user_apis`) | `resolve.declareApi`, `walkApi`, `TypeResolver.resolveApi`, `resolveApiMethods` |
| `Symbol.user_apis: []const ApiRef` beside `apis`: a type parameter's bounds, a type's header, an API's | `sema.zig`; `ApiRef` is the declaring module's id and its symbol there, the same in every module |
| Conformances: one per header API (`recordHeaderConformances`, after the symbol walk) and per API of an addition (`resolveAdd`, resolved before other declarations) | `SemContext.conformances`, `sema.Conformance` |
| The one classifier: `sema.provides(ctx, ty, api) ?Provision` (a bound, or a conformance by module and index), searching the module, the API's, and the type's | `sema.zig`; `checkBounds` routes user bounds through it |
| Conformance: methods present and matching (self, parameters, compile-time parameters, result and failure, `once`), `from` and `keeps` within the API's by position, built-in supertraits, two defaults, `pub` | `typecheck.checkApis`, `checkConformance`, `checkMethodMeets`, `apiMethodType` |
| Coherence: once per type and API (and APIs that build on it), in the type's module or the API's, an addition at home only under a bound, none naming a method its type has | `checkConformance`, `checkAddHome` |
| A bounded `T` (a program's API) does what its bounds name: `hasBounds`, `boundApis` (built-in APIs the user APIs build on), `formatBounds` at every Stage 2 site | `sema.zig`, `typecheck.zig`, `ownership.checkBoundedCopies` |
| A call through a user bound, and an API named as a value (`Shape.area(c)`), are rejected | `typecheck.typeParamCall`, `boundMethod`, `useName` |
| Passes that walk the module skip `api` and `api_add` (`rig.isApiDecl`): typecheck's bodies, ownership, emit | `typecheck.checkModule`, `ownership.walkDecl`, `emit.emit`, `Scan.walk` |

35 new cases in `test/rig/types-apis.rig.test` ("apis own ..."), 11 of
them `test`s; SPEC gains "APIs" with an example, three rejections, and
a `rig pending` call through a bound; SYNTAX the forms and keywords.

## Decisions beyond the design

1. **Defaults' bodies and additions' methods are resolved, not
   typechecked.** A default is written in terms of the API's methods
   (`@area()`), which is a call through a bound, phase 2's. Checking
   bodies now would reject the design's own example, or need a partial
   branch phase 2 replaces. They are never emitted and nothing calls
   them, so nothing unchecked reaches Zig. Phase 2 checks defaults, phase
   3 additions' methods. Their signatures are checked now.
2. **A type that provides an API provides those it builds on** (Swift's
   rule): `obj Tile: Named` with `api Named: Shape` meets `[T: Shape]`.
   The design says a subtrait inherits its supertraits' methods; this
   makes the bound follow.
3. **"No overlap" is one addition per API and type constructor.**
   Conditions are never compared: `add List[T: Print]: Shape` and `add
   List[T: Eq]: Shape` are two, an error. A header and an addition of an
   API, or of one it builds on, are two. Duplicates across modules cannot
   arise: an addition is written in the type's module or the API's, and
   imports have no cycles, so the check is per module.
4. **An API's method takes self.** A method without `@` ("static") has
   no lowering in the design; rejected.
5. **No `pub` inside `api` or `add`, and no `pub add`.** An API's
   methods are as public as it; an addition's belong to its API.
6. **`add` names every instance:** `add List[Int]: Shape` is rejected
   ("an addition covers every instance"); a type with a compile-time
   value parameter (`Slot[n]`, `Table[T, n]`) is rejected as not built
   yet (phase 3's).
7. **`[T: Shape]` with one colon** is read as a bound when the
   parameter starts with a capital; a type there keeps Stage 2's
   value-parameter error (`[N: Int]`). The message for an unknown bound
   changed from "names no built-in API" to "names no API", in the one
   existing case.
8. **Two defaults of one name across two APIs a type names** (`obj X:
   A + B`), not only through one API, need the method written.
9. **Self in an API is a hidden type parameter**, so conformance is a
   substitution (`Self` to the type, the API method's compile-time
   parameters to the implementation's) and a comparison of interned
   types; a set parameter in the same place matches.
10. **The `pub` rule** is checked on headers only: an addition's methods
    take no `pub`.

## Messages beyond "The errors a reader meets first"

- `` `T` is bounded by `Shape`, which gives no method `perimeter`; ... `` (Stage 2's text)
- `` `x.area()` calls `Shape.area` through the bound `T: Shape`, and a call through a bound is not built yet (docs/design/apis.md, Stage 3) ``
- `` `Shape` is an API, not a value; a call through it by name, `Shape.method(x)`, is not built yet ... ``
- `` `count[Wrap[Label]]` ...; `Wrap[T]` provides `Shape` only where `T: Shape` ``
- `` `X.m` takes `at` as `Float`, but `A` declares `m(!@, at: Int)`; a method meets its API with the same parameters: write `...` ``, and the like for compile-time parameters and `once`
- `` `Shelf.first` may give a view of `other`, but `Store.first` does not: ... ``
- `` `Store.last` gives `?Int`, which may view what it is passed, and an API's method says what with `from`: `-> ?Int from @` ``
- `` `Int` provides `Shape` twice: a type provides an API once in the whole program ``
- `` `Square` is declared in this module, so it names `Shape` on its header: `obj Square: Shape`; ... ``
- `` `add List[T]: Pusher` declares `push`, which `List[T]` has already: ... ``
- `` `Square.area` meets `Shape`, a `pub` API, on `Square`, a `pub` type, so it is `pub`: write `pub fun area(?@) -> Float` ``
- `` `X` provides `A` and `B`, which both give `name` a default: declare `name` in `X` to choose ``
- `` `Named` builds on `Shape`, which declares `area`: ... ``; `` `Loop` builds on itself, through `Ring` ... ``
- `` an API's associated type, `type Item`, is not built yet: its methods name their types ``
- `` Rig has no `trait`; write `api`: ... `` and `` Rig has no `impl`; write `add`: ... ``

## Deferred, with the phase that builds each

- Calls through a bound, `Shape.area(c)`, defaults' bodies, the
  dispatch fact, witnesses: phase 2.
- Additions' lowering and their methods' bodies, method-level bounds
  (`fun Wrap[T: Print].show(?@)`), additions to `Slot[n]`: phase 3.
- `type Item`, `I.Item`, `[S: Source, S.Item: Ord]`, `Iter`: phase 4.
- Public generics state their bounds: phase 6.

## Trig

No top-level declaration in `~/Data/Code/trig/src` starts with `api` or
`add` (the one `add =` is a local). Phase 1 only accepts more programs,
so Trig's light gate should stay byte-identical; it was not run here.
