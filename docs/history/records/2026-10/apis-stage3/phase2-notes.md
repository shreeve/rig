# APIs Stage 3, phase 2: notes (2026-10-23)

Phase 2 of [build-plan.md](build-plan.md): calls through a bound, and
witnesses. The design is [docs/design/apis.md](../../../../design/apis.md),
Stage 3, with the defaults of [open-questions.md](open-questions.md); phase
1 is [phase1-notes.md](phase1-notes.md) and its review
[review-p1.md](review-p1.md). This page records how phase 2 was built and
the decisions the record did not settle.

## What is built

| Piece | Where |
|---|---|
| A call on a bounded `T`, `x.area()`, typed from the API's declaration with `Self` the `T`: self, parameters, the method's own compile-time parameters, result and failure; the API's `from` and `keeps` given to the call's parameters | `typecheck.typeParamCall`, `apiMethodsIn`, `apiMethodAt`, `apiMethodCall` |
| `Shape.area(c)` and `shapes.Shape.area(c)`, self the first argument | `apiNamedCallee`, `apiNameCall` |
| The shorthand `c.area()` on a type with no `area` of its own, through the one API the module declares or imports that the type provides and that declares it; two make the call name the API | `apiShorthand`, `visibleApis`, `reportAmbiguous` |
| A call on an unbounded `T` that would reach a default or an addition says to write the bound | `reportApiUnbound`, at the instance |
| Defaults checked once, generic over `Self` bounded by the API; additions' methods checked as methods of the type they add to | `checkApiDefaults`, `checkAddMethods`; ownership's `walkDecl` |
| The dispatch fact, one per method call: `direct`, or `static` with the witness, the API, and how the method takes self | `sema.Dispatch`, `recordDispatch` (`noteMethod` records `direct` first) |
| Witnesses: a type parameter's own (`W_T_Shape`), or a conformance's with the witnesses of its generic arguments; `GenericCall.witnesses`; `SemContext.type_witnesses` for each generic instance whose parameters take them | `sema.witnessFor`, `argWitnesses`, `recordTypeWitnesses` (after the storage plan) |
| What each witness names: the type's method, an addition's, or a default | `Conformance.members`, filled by `checkConformance` |
| Emit: a parameter `comptime W_T_Shape: type` after each bounded type parameter, of functions, generic types, defaults, and witnesses; witnesses among compile-time arguments and type arguments; `__rig_impl_Shape_Square` per conformance; `__rig_defaults_Shape(Self, W_Self_Shape)`; `W.area(rig.selfArg(W.area, &x))`; tasks through `spawnWitness` | `emit.zig` "APIs of a program's own: witnesses"; `rig.selfArg`; `Task.spawnWitness` |
| The oracle lowers a call through an API with the API method's signature and clauses, read from the call's dispatch, and decides defaults and additions' methods | `test/oracle/lower.zig` `method`, `apiMethodOf`; `main.zig` `collectDecl` |

## Decisions beyond the design

1. **Additions are lowered here,** not left to phase 3: a witness is
   the same namespace whether its methods are the type's or an
   addition's, and phase 1's cases already pass `Int` to `[T: Shape]`.
   An addition that gives several APIs writes its methods in the first
   conformance's witness; the others name them there. Phase 3 keeps
   method-level bounds and additions to `Slot[n]` and `Table[T, n]`.
2. **Self through a witness:** `rig.selfArg(W.area, &x)` gives the
   method self from the receiver's address as Zig's method call would,
   a pointer or a copy (`rig.ReadView`'s rule), so emit writes one form
   for an owned value, a view, an element, and a temporary.
3. **The error slot through a bound is passed by the API's set,** a fact:
   a call through a witness takes the slot (`calleeTakesSlot`) where its
   `!` or `catch` lends one, as the call's type, the API's declared
   result, says. Every implementation fails with exactly that set, so no
   compile-time probe of the instance's method is needed. Self goes as
   the API declares it, also a fact: `!@` by address, `?@` as the view
   the caller lends (a copy only where `rig.ReadView` copies, a value
   that holds no view), `<@` moved in. A call on an unbounded `T` stays
   Stage 1's `x.m()`, which Zig resolves at each instance.
4. **A default is written once per API,** in `__rig_defaults_Shape(Self,
   W_Self_Shape)`, a type of the API's module, and each witness that takes
   it names `__rig_defaults_Shape(Square, @This()).describe`: the default
   calls the API's other methods through the witness it is given.
5. **Witness parameters are read by type** at the top of each body that
   takes them (`_ = @TypeOf(W_T_Shape)`), since Zig rejects both an
   unused parameter and a discard of a used one, and whether a body uses
   its witness through a type's arguments is not a fact emit has.
6. **What `c.area()` sees:** the APIs the module declares and the `pub`
   ones of the modules it imports. The shorthand applies to a value of a
   named type, a view of one included, never to a handle, an optional, or
   a `T`.
7. **"`T` has no method `area`"** is reported at the instance, where an
   unbounded `T`'s instance has no `area` of its own but provides an API
   the module sees that declares it; any other missing method keeps
   Stage 1's message.
8. **A store through a bound into a value of a type parameter's type:**
   a call through an API whose method keeps a parameter stores it in
   self. A view of a local stored in the caller's value is rejected as
   for any type (`w` outlives it), and one stored in a `T` the body owns
   is rejected, since a generic body tracks no view a `T` holds. Only a
   call through an API carries such a `keeps`; a function value's default
   origins never store a local's view into a `T`.
9. **An API's method names its parameters and gives them no defaults,**
   the review's two open points, with Swift's rule: an implementation
   uses the API's names, and an API's parameter takes no default, since a
   call through the API passes every argument by the API's names.
10. **Every method call records `direct` or `static`,** built-in methods
    included; `rig check --facts=sema` prints each, and a generic call's
    witnesses.
11. **A generic object takes no `drop` body yet** (SPEC §8), so the build
    plan's `drop` of `Bag[T: Closer]` is a method in the cases; a `drop`
    body, once allowed, finds the witness among its type's parameters as
    any method does.
12. **The oracle's own check of conformance clauses** waits for phase 5
    (the oracle's second opinion): a program whose implementation keeps
    more than its API is rejected in sema, where the oracle decides none
    of its functions.

## Messages beyond "The errors a reader meets first"

- `` `Shape` is an API, not a value; call a method through it by name: `Shape.method(x)` ``
- `` `Shape.area` takes self as a value of a type that provides `Shape`, and `Label` does not ``
- `` `Shape` declares no method `perimeter` ``
- `` `Pair.pick` names its parameter `second` where `Picker` declares `first`; a method meets its API with the same names: write `...` ``
- `` `Scaled.by` gives `k` a default, and an API's method takes none: a call through the API passes each argument ``
- `` cannot let this call store a view of `t` in `y`, a `T`: a generic body tracks no view a value of a type parameter holds ``

## Deferred, with the phase that builds each

- Method-level bounds (`fun Wrap[T: Print].show(?@)`), additions to
  `Slot[n]` and `Table[T, n]`: phase 3.
- `type Item`, `I.Item`, `Iter`: phase 4.
- The oracle's conformance clauses, the Lean lemma: phase 5.
- Public generics state their bounds: phase 6.

## Trig

Phase 2 only accepts more programs, but for the two rejections of
decision 9, which no program had a reason to write before calls
through a bound existed. Trig declares no API. Its emitted Zig is
byte-identical under main's compiler and this one: the 12 programs with
a `main` in its `tools/` and `tests/`, built as its packs build them
(every module of the package compared), and the 49 files of `src/` that
emit alone.
