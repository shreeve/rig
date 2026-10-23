# APIs Stage 3: the build plan (2026-10-23)

How to build Stage 3 of [docs/design/apis.md](../../../../design/apis.md),
"APIs of your own", after the consolidation round. The design is that
page's Stage 3 section; its open points, each with a default, are
[open-questions.md](open-questions.md). This plan says where each piece
goes, in which order, with which tests, and what to watch. Line numbers
are of `main` at c77a86b07.

## Where Stages 1 and 2 live

| Piece | Where |
|---|---|
| Bounds and headers in the grammar | `rig.grammar` `tfield` (`name ":" apis2 → (bound)`, about line 772), `apis`/`apis2` (774-781); headers on `struct`, `enum`, `generic_struct`, `generic_enum` (793-825) carry `apis:group?`; `unique` is contextual; `trait` and `impl` are reserved lexer words with no form |
| Bounds in the Parser wrapper | `src/rig.zig`: `Api` enum (2128, `named`, `ownable`), `Parser.bounds` (2311), `tparamBounds` (3349) strips bounds and records them by position, `boundsAt` (3374) |
| Bounds on symbols | `sema.Symbol.apis: Apis` (`src/sema.zig` 803), `Apis = std.EnumSet(Api)` (810), `implied` (814), `formatApis` (823); `resolve.boundsOf` (555), `resolve.headerApis` (575) |
| An instance provides its bounds | `sema.checkBounds` (6183) → `lacks` (6122) → `boundLack`, `paramsLack`, `heldLack`, `ordLack`; `reportLack` (6228), `cannotDo`, `lackDetail`; called from `resolve.zig` 3430 and `typecheck.zig` 10655, 17659, 17671 |
| A bounded body does only what its bounds name | `typecheck.checkBoundedBodies` (18550), `apiOf(Requirement)` (18533), `reportUnbounded` (18569); also `ownership.checkBoundedCopies` (808), `typecheck.zig` 13973 (Copy) and 9515 (Ord), `sema.boundBlocker` (7194, Moves/Shares) |
| Own meanings | `sema.apiMethodName` (6076), `ownApiMethod` (6089), `ownApiOf` (6099); `typecheck.checkHeaders` (18579) → `checkApiMethod` (18629) with `fixedSignature` (18611); emit `emitOwnApis` (`src/emit.zig` 1085) writes `__rig_own_eq`, `_order`, `_print`, `_hash`; the runtime's `ownsApi` (`src/runtime.zig` 716) |
| Stage 1 calls on a `T` | `typecheck.typeParamCall` (12115; rejects a bounded `T` at 12124), `typeParamResult` (12216), `wrapResult` (12240); each call is a `sema.GenericMethodCall` (2266) in `ctx.generic_methods` (2519), copied across modules by `importParam` (8777); checked per instance by `checkGenericInstantiations` (17636) → `checkMethodCalls` (18423) → `checkMethodCall`, `instanceMethod` (18392), `declaredType` (18408) |
| Stage 1 in emit | plain `x.m()`, which Zig resolves per instance; `calleeTakesSlot` (`emit.zig` 8160); the `type_param_calls` fact (`sema.zig` 1063, `recordTypeParamCall` 3618) is read only by `emitDiscard` (`emit.zig` 2057) |
| Facts | `src/facts.zig` wraps `SemContext` read-only: `genericCallOf` (317), `isTypeParamCall` (377), `ownApiOf` (858); `GenericCall` (`sema.zig` 1750: type args, receiver arg, `sets`, `fails_by_set`); `--facts=sema` is `main.zig` 335 → `sema.writeFactsDump` (1959). No dispatch fact exists |
| Generic sets | `resolve.markSetParams` (338), `SymbolFlags.set_param` (`sema.zig` 699), `sema.isSetParam` (5647); typecheck `setArgs` (11393), `failsBySet` (11402) |
| The oracle | `test/oracle/` (`main.zig`, `core.zig`, `flow.zig`, `kinds.zig`, `lower.zig`), built by `build.zig` 146-158; a bounded `T` is decided by `Copy` and `Owned` (`kinds.zig` 56-110); a call on a `T` takes its self from the sigil and its parameters from the callee (`lower.zig` 3865) |
| Lean | `formal/LambdaRig/` has nothing on bounds yet |
| Tests | `types-apis` (22 cases, Stage 2), `types-generic` (107, about 35 on Stage 1), `errors-generic` (23, sets), `ownership-generic` (21), `emit-generic` (18), `std-hash` (20) |

The known gap: in a body declaring `-> Int!Bad`, `x.size()!` on an
unbounded `T` is rejected ("`x.size` may fail with any error"), and
`return x.size()!` in a `T!` body records `Int!!`: `typeParamResult`
asks `wrapResult` to wrap a result already wrapped by `checkReturn`'s
expected type, always with `type_any_error`. The message is the
consolidation's (track 2); the full fix for a set is a bound (Phase 2).

## The pieces, and the pass that owns each

| Piece | Pass |
|---|---|
| `api Name[: A + B]` with required methods, defaults, and `type Item`; `add Type: A`, `add Wrap[T: A]: B`; `api` and `add` contextual at the start of a module-level declaration (as `unique` is), so `user.api` and `!set.add(x)` keep working; `trait` and `impl` hint "write `api`" / "write `add`"; `[S: Source, S.Item: Ord]` (a dotted `tfield`); `fun Wrap[T: Print].show(?@)` | `rig.grammar` (new rules and nodes `api`, `api_add`), `src/rig.zig` (layout, `tparamBounds` for user API names and associated-type entries); tell Nexus, which mirrors `rig.grammar` and `src/rig.zig` |
| An API symbol: its methods' signatures, defaults, supertraits, associated types | resolve (`declareApi`), sema (a symbol kind `api`; `Symbol.apis` widened from `EnumSet(Api)` to built-ins plus a list of user API ids) |
| "`Shape` is an API, not a type"; `add Inte: Shape`; an `add` in the type's own module with no bound; an `add` naming a view, handle, optional, array, slice, or function type | resolve |
| Conformance: each required method present, matching exactly (self, parameters and modes, `once`, compile-time parameters, result and its failure); `from`/`keeps` within the API's by position; `pub`; defaults' signatures; supertraits, built-in ones included (`api Job: Moves` checked by `crossingBlocker`) | typecheck, a `checkConformance` beside `checkHeaders`, sharing `fixedSignature`'s comparison |
| Coherence: once per program per type and API, in the type's or the API's module; no overlap; no addition to a bare `T` | modules (`src/modules.zig` sees every module in order) with sema's conformance table |
| One classifier: `sema.provides(ctx, ty, api) ?Conformance`, the only answer to "does this type provide this API, and by which witness" | sema; `checkBounds`/`lacks`, typecheck, dispatch facts, and emit all go through it |
| A bounded body's call `x.area()`: typed from the API's declaration (no per-instance result inference); its failure is the API's set; its compile-time parameters as the API declares them; `Shape.area(c)` | typecheck (a branch in `typeParamCall`, which today rejects a bounded `T`) |
| Ownership of a call through a bound: the API's `from` and `keeps` | `src/ownership.zig`, reading the API method's clauses from the call's fact; never the instance's |
| Dispatch fact per method call: `direct`, `static` (with the witness symbol), later `dynamic` | sema records it once; `facts.zig` exposes it; `writeFactsDump` prints it |
| Witnesses: a namespace per conformance (`__rig_impl_Shape_Square`), one compile-time parameter per user bound on the declaration that states it (function, method, or generic type), the call `W_T_Shape.area(x)`, defaults as generic functions of the API's module | emit, from the facts only |
| Implied bounds from a signature's types, for every parameter | resolve/typecheck (where `checkBounds` meets a bounded parameter naming `Map[K, V]`) |
| `Iter`, derived by the `for` loop's own iterator rule, with `Item` | sema (the loop's classifier becomes `sema.iterItem`, used by `for` and the bound alike) |
| `pub` generics state their bounds | typecheck (`checkBoundedBodies` extended to unbounded parameters of `pub` declarations) |

## Phases

Each phase is one PR, opened as a draft with a checklist, through
Rig's full suite and Trig's light gate. Phases 1 to 5 only accept more
programs (plus the `api`/`add` words at a declaration's start), so
Trig's light gate must stay byte-identical; phase 6 rejects programs a
release accepted.

### Phase 1: declarations and conformance (about 1,500 lines, 40 cases)

Grammar, resolve, sema, typecheck: `api`, headers naming user APIs,
`add` (checked, not yet lowered), conformance, coherence, defaults'
signatures, supertraits. A bound by a user API is checked at each
instance (`` `total[Label]` cannot use `T = Label` ``). A call through
it is not lowered yet, so it is rejected with a Rig error, as North Star
1 asks, and phase 2 removes that error; no release ships between them.

Cases (`test/rig/types-apis.rig.test`, `fail` with the exact texts of
apis.md's "The errors a reader meets first"):

- "an API is not a type" (`` `Shape` is an API, not a type: ... ``);
- "a provider lacks a required method" (`` `Square` provides `Shape` but has no method `area` ... ``);
- "self must match" (`` `Counter.next` takes `self` as `?@`, but `Source` declares `next(!@)` ... ``);
- "keeps must be within the API's" (`` `Log.watch` keeps `s`, but `Watcher.watch` keeps nothing ... ``);
- "a failure must match" (`` `Disk.size` fails with `Int!Io`, but `Sized` declares ... ``), and its siblings: `T!` against a set, a union against one of its sets, a set parameter missing;
- "a marker supertrait" (`` `Pool` provides `Job`, which builds on `Moves` ... ``);
- "add names a type" (`` `add` names a type, and `?Square` is a view ... ``);
- `add Inte: Shape`; an `add` in the type's module with no bound; two conformances of one type (header and `add`, two `add`s, overlapping conditions); an addition defining a method the type has; `pub` missing on a method meeting a `pub` API; a default overridden with another signature; two inherited defaults; `trait`/`impl` hints; `user.api` and `!set.add(x)` still parse;
- `test` cases: a header conformance, an addition in the API's module, an API built on another, `api Job: Moves` met by plain data.

### Phase 2: calls through a bound, and witnesses (about 2,000 lines, 45 cases)

Typecheck's branch for a bounded `T`; ownership with the API's clauses;
the dispatch fact and its dump; emit's witnesses for header
conformances and defaults; a generic type's witness among its
arguments, so its `drop` and own `print` reach it; error sets through a
bound (the known gap); an API method's own compile-time parameters.

Cases:

- `types-apis`: `total[T: Shape]` over two providers; a default used
  and one overridden; a call through a bound inside a closure; `x.area()&`
  local and crossing; the `T` has-no-method message
  (`` `T` has no method `area`: `total[T]` gives `T` no bound ... ``);
  `Shape.area(c)` and the ambiguity message
  (`` `c.area()` could call `Shape.area` or `Region.area` ... ``);
- `errors-apis` (new): `!` of `Bad` into `Bad` and into a union holding
  it; `catch |e|` matched without `_`; an API method with `[E]`; a set
  with fields through a bound (the slot), under `RIG_SANITIZE=1`; a
  failing default; a task over a bounded call needs `task.Stop` in its
  set;
- `ownership-apis` (new): a result `from` the API's parameter keeps
  that loan; an implementation with fewer `keeps` called through the API
  keeps the API's loans; a bounded `T` that owns a resource moves and
  drops right through a witness call;
- `emit-apis` (new, `code`): `W_T_Shape.area(x)`; `Bag(Square,
  __rig_impl_Shape_Square)`; a `drop` of `Bag[T: Closer]` calling
  `!x.close()`;
- `--facts=sema` prints `direct`/`static` (a `test/cli` script).

Oracle (`test/oracle/lower.zig` `method()`): a call through a bound is
lowered with the API method's clauses, read from the call's fact, never
the instance's; conformance clauses (`keeps` within the API's) checked
by the oracle on its own (apis.md's checker table). Coverage floors in
`test/oracle/coverage` go up, never down.

Docs: apis.md Stage 3's example from ```` ```text ```` to ```` ```rig ````
with an ```` ```output ````, and each error of "The errors a reader meets
first" built so far to a ```` ```rig reject ````; SPEC gains a section
"APIs" after "Own meanings", and SYNTAX the forms.

### Phase 3: additions (about 1,000 lines, 20 cases)

Emit for `add`: `__rig_impl_Shape_Int` in the API's module for a
built-in type and another module's type; conditional additions
`add Wrap[T: Shape]: Shape`; method-level bounds
`fun Wrap[T: Print].show(?@)` and "repeating a bound the type already
has". Cases in `types-apis` and `emit-apis`, a module case (`file=`)
for each home of a conformance, and one per built-in type family
(`Int`, `String`, `List[T]`, `Slot[n]`).

### Phase 4: associated types and `Iter` (about 1,000 lines, 20 cases)

`type Item` in an API and in a provider, `I.Item` in a signature,
`[S: Source, S.Item: Ord]`; `Iter` derived by the loop's classifier
(one function, `sema.iterItem`); `iter.count` and `iter.sum` in std
(STD.md). Cases in `types-apis`, and a std case of each new function.
Check that every std iterator (std/text.rig, std/utf8.rig, the Map and
Set iterators) is an `Iter` with the item the loop gives today.

### Phase 5: the proof and the oracle's second opinion (about 300 lines of Lean)

`formal/LambdaRig/`: the subsumption lemma of apis.md's checker table,
that a call checked against wider `from`/`keeps` is sound for any
callee within them, stated over λRig's call rule. It may land beside
phase 2 if ready; it gates nothing in the compiler.

### Phase 6: public generics state their bounds (about 400 lines, 15 cases, a script)

The rule, implied bounds from a signature's types (every parameter,
bounded or not), and the facts no API names left per instance.
`tools/state-bounds.py` runs `rig check`, reads each "states its
bounds" error's fix, writes the bound into the brackets, and repeats
until clean; std first, then Trig. The release notes list the rule;
Trig gets a one-line note and the script before the merge.

Today's count (a scan of every `pub` generic with a type parameter,
excluding set parameters, and a hand reading of each body; ±3):

| Tree | `pub` generic functions | need a bound | `pub` generic types | need a bound |
|---|---|---|---|---|
| std | 13 (9 bounded already) | 0 | 7 (31 `pub` methods) | 0 |
| Trig `src/` | 84 (none bounded) | 55; with implied bounds 31 | 21 | 8; with implied bounds 1 (`MultiMap`'s `V: Eq`) |

Trig's needs are `E: Copy` on its slice-to-List helpers (28, e.g.
`filter`, `find`, `flatten`, core/core.rig), `Hash` from naming
`Set`/`OrderedMap`/`Map` (25, all implied), `Eq` (8), `Clone` (1,
`copy_map_into`), and `Owned + Copy` (1, `memoize`). No generic in
either tree calls a method on a `T`: Trig passes callbacks (`dup`,
`get_key`, `cmp`) instead, which bounds may later replace.
`binary_search_unique_func` (core/binarysearch.rig 15) passes an
element by value where `?x[middle]` was likely meant.

Cases: one `fail` per capability (copy, `==`, `<`, `.hash()`, `print`,
arithmetic, `+x`, a Cell, crossing, a method call) on a `pub` generic,
each with its fix; a private generic still per instance; implied
`K: Hash` from `Map[K, V]` with a bound of its own (`[K: Print]`); a
freeze and a `Table[T, n]` in a bounded `pub` generic still checked per
instance.

## Risks, and the North Star checks

- **Accept means correct.** Phase 1 accepts declarations it does not
  yet lower; no program may reach an unlowered call: the gap is a Rig
  error, and a `code` case shows each lowered form. Every `test` case
  runs under `RIG_SANITIZE=1`, by the runner.
- **One classifier per fact.** "Does `T` provide `A`, and by which
  witness" is `sema.provides`, used by bounds, conformance, dispatch, and
  emit. "Is this an iterator, and of what" is one function for `for` and
  `Iter`. Crossing for `api Job: Moves` is `crossingBlocker`, not a new
  walk. Each merge adds a case two paths would have split on.
- **Emit decides nothing.** The dispatch kind and the witness symbol are
  facts; emit never looks up a conformance. `facts.zig`'s `Pending`
  gains nothing.
- **Witnesses through types.** A generic type's Zig function takes one
  more type parameter per user bound. Zig memoizes a type by its
  arguments, so `Bag[Square]` named in two modules must name the same
  witness declaration: the witness lives once, beside its conformance,
  and every module refers to that one. A `code` case across modules.
- **Closures and tasks in a bounded body.** The witness is a
  compile-time parameter of the enclosing function, which a closure's Zig
  struct and a task's frame reach; a case for each.
- **The fields slot.** A set with fields lowers with `__out`; a call
  through a bound passes the slot exactly as the API's set says, which
  every implementation matches. A sanitizer case with fields.
- **Speed.** Witness calls are direct and inline as today's calls do.
  std adopts no user API until `Iter` (phase 4); compare std.json's and
  Trig's emitted Zig before and after each phase (expect identical), and
  run the speed census after merges.
- **Nexus.** `rig.grammar` and `src/rig.zig` change in phase 1 (and
  maybe 3, 4): tell the Nexus session, whose refresh copies Rig's main.
- **Two rounds of soundness fixes stop the feature** for redesign
  (CORE §10). Each phase gets an adversarial review before it lands.

## Docs, by phase

- Phase 1-2: SPEC "APIs" (and "Bounds" for user APIs), SYNTAX's
  declarations, apis.md's Stage 3 to *(built)* piece by piece, QUICK,
  docs/learn/07's later sections, CHANGELOG, HANDOFF.
- Phase 3: SPEC's "A method is declared in the module that declares its
  type" points to `add` rather than to "what traits are for".
- Phase 4: STD.md (`iter.count`, `iter.sum`), SPEC's iterator section
  names `Iter`.
- Phase 6: SPEC "Generic bodies" and "Bounds", the release notes,
  CHANGELOG's rejected forms.

## Size

About 6,200 lines of compiler, tests, and docs across six PRs, and 300
of Lean. Phases 1 and 2 are the bulk and the risk; 3 and 4 follow their
pattern; 6 is small in the compiler and large in Trig's diff (about 32
declarations with implied bounds, 63 without).
