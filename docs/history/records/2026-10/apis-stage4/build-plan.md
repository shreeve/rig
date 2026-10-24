# APIs Stage 4: the build plan (2026-10-23)

How to build Stage 4 of [docs/design/apis.md](../../../../design/apis.md),
"API objects" (`?{Shape}`, `!{Shape}`, `^{Shape}`), once Stage 3 has
landed. The design is that page's Stage 4 section, refreshed for what
Stage 3 built; its open points, each with a default, are
[open-questions.md](open-questions.md). This plan says where each piece
goes, in which order, with which tests, and what to watch. Line numbers
are of `main` at 03e4f360d (Stage 3's phases 1 and 2); phases 3 and 4
are PRs #588 and #594.

## What Stage 4 reuses from Stage 3

An object is a conformance with its type erased, so Stage 4 adds a
representation and a call path, and reuses every check of a
conformance.

| Stage 3 piece | Where | What Stage 4 does with it |
|---|---|---|
| The one classifier "does `T` provide `A`, by which witness" | `sema.provides` (`src/sema.zig` 6791), `sema.witnessFor` (6905) | decides every erasure; a `T` with no bound has no witness, so no object |
| Witnesses: `__rig_impl_Shape_Square`, `W_T_Shape`, `Conformance.members` (own, added, default) | `sema.Witness`, `emit.emitWitness` (`src/emit.zig` 1222) | a table entry calls `W.m`, the witness's member, so defaults and additions need nothing new |
| Self by sigil: `rig.selfArg(W.area, &x)` | `src/runtime.zig` 723, `emit.emitWitnessSelf` | each entry gives self to the method the same way, from `ptr` cast to `*T` |
| The dispatch fact, `direct` or `static` | `sema.Dispatch` (986), `recordDispatch` (4208), `--facts=sema` (`test/cli/facts_sema.sh`) | gains `dynamic`, with the API, the method, its table slot, and self's mode |
| A call typed from the API's declaration | `typecheck.apiMethodCall` (12454), `apiNameCall` (12569), `apiMethodAt` | the object call takes the same path with `Self` hidden |
| Ownership by the API's clauses, read from the dispatch fact | `ownership.zig`; oracle `lower.zig` `method` (3853), `apiMethodOf` (3922) | a dynamic call reads the same clauses from the same fact |
| Error sets through a bound; the slot of a set with fields | `emit.calleeTakesSlot` (8477), `emitArgs` (8442), `FunState.has_out` | `calleeTakesSlot` answers yes for `dynamic`; the entry takes the slot as a callable view does (`rig.FnRef.argsFor`, `src/runtime.zig` 1880) |
| Associated types (phase 4, #594) | `sema.AssocOf`, `Conformance.assoc`, `sema.iterItem` | `{Source[Item: Int]}` checks `Conformance.assoc` at erasure (phase 5 here) |
| Method-level bounds (phase 3, #588) | `Field.owner_bounds` | a method under owner bounds is never an API's, so no table sees one |
| Callable views as the model of a fat value | `rig.FnRef` `{ctx, call_fn}`, `LendStep.callable`, `Type.callable` | `?{Shape}` is `read_view(api_object)` as `?fun` is `read_view(callable)`; the erasure is a lend row as `.callable` is |

## The pieces, and the pass that owns each

| Piece | Pass |
|---|---|
| `{A}` in a type: `"{" apis "}" → (api_object)` in `tatom`, so `?{A}`, `!{A}`, `^{A}`, `List[^{A}]`, `^{A}?` parse by the existing rules; the lexer makes `{` and `}` tokens instead of `err` (`Lexer.lexError`, `src/rig.zig` 1918), and the Parser wrapper keeps "Rig has no braces: a block is the lines indented under its header" for a brace anywhere else | `rig.grammar` (TYPES), `src/rig.zig`; Nexus's refresh copies them |
| `Type.api_object: { api: ?ApiRef, builtins: Apis, assoc: []const TypeId }`, an unsized type under the existing `read_view`, `write_view`, and `Box[...]`, interned with a conservative `TypeInfo` (it may hold anything: a view, a handle, a `drop` body; never `holds_type_var`, so its facts never wait for an instance), so `carry`, `mayHoldView`, and `holdsViewOnly` keep its loans; printed `?{Shape + Owned}` in messages, `$name`, and the LSP's hover | `src/sema.zig` (`Type`, the type printer), `src/lsp.zig` reads the printer |
| Resolving the braces: one API of a program's own; `Owned`, `Print`, `Clone` beside it; `{T}`, `{Square}`, two user APIs, `Copy`, `Eq`, `Hash`, `Ord`, the number APIs rejected; `Sends`, `Syncs` "Stage 5"; an API with `type Item` needs `[Item: X]` | `resolve.TypeResolver` (beside `resolveApi`) |
| A bare `{A}` as a value's, field's, parameter's, or type argument's type, written or inferred (`inferTypeArgs` and `unify` never bind a type parameter to `{A}`); no default value of an object (`Table[^{A}, n]`, `T()`, a filling `resize`) | typecheck, where a sized type is required |
| Which methods an object reaches, in table order: `sema.objectMethods(ctx, api) []ObjectMethod`, each `{name, api, field, slot}`, the API's own after those it builds on, defaults included; a method with its own compile-time parameters or `Self` outside self is left out with its reason | sema, once per API; typecheck's call, emit's table, and the oracle read it |
| Object facts: `?{A}` a read view that copies, `!{A}` a write view, `^{A}` owning; `Owned` only from the braces; `Clone`, `Print` from the braces or the API's supertraits, and no other built-in bound, none forwarded through a view or box (`Map[?{A}, V]` is no `Hash`); `+` only of a `^{A}`; no crossing, no freezing, no error field (it may hold a handle); `dropRunsBody` answers `.yes` for `^{A}`; `provides` answers null for any object | sema's existing classifiers (`boundLack`, `crossingBlocker`, `dropRunsBody`, `lendByValue`, `needsDrop`'s fact), no new walk |
| The erasure: `LendStep.erase` in `sema.lendsAs` (10407) as the last row, after `unbox`, `handle`, `optional`, erasing only the value reached, never a place's or an element's type (a `!^Square` is no `!^{A}`); a box moved in where `^{A}` is expected; built-in bounds checked there; one fact per conversion, `SemContext.erasures`: `{api, from: TypeId, witness: Witness, form: read/write/box}` | sema (lend table), typecheck (at the expected type, `meets` 17535 and the argument path), `facts.erasureOf` |
| An erasure of a read view of plain data, decided by kind (never `rig.ReadView`'s size), or of a `?T` of a type parameter's value: an object of a copy that is a hidden local of the erasing block (`StorageBy.copy`, a new `StorageLife.block`), recorded on the erasure fact; ownership roots the loan at that local, never through `walkThroughView` | sema decides, storage gives the copy its block-scoped slot, ownership roots the loan there |
| A temporary lent as an object (`area_of(Square(side: 2.0))`) | `src/storage.zig`: the hidden slot of a lent temporary, as for any `?T` of one |
| Calls on an object: `x.m()`, `!x.m()`, `<b.m()`, `Shape.m(x)`; typed from the API's declaration (`apiMethodAt`), self's sigil against the form; `Dispatch.dynamic {api, method, slot, self_mode, receiver_arg}`; one predicate `Dispatch.viaApi()` replaces the `== .static` tests (ownership, emit) so none skips `dynamic` | typecheck (`objectCall` beside `typeParamCall` 12344 and `apiNameCall`), sema records |
| No assignment through `!{A}`: where an assignment through a `!T` is decided (`recordWriteThrough`, `typecheck.zig` 1660), `checkSwap` (9120), a take or move out, and `x = w`'s read | typecheck, one predicate `sema.isErasedView(ty)` |
| Stage 1 at an object instance rejected (`instanceMethod`, 18934); `T = ^{A}` against `[T: A]` rejected (`checkBounds`, `sema.zig` 6659, through `provides`) | typecheck, sema |
| Loans: an erasure carries the source's loans (a lend row; a box's move); a dynamic call by the API's `from`/`keeps` only, never an implementation's (no `from @field`, no `Iter` rule 9; the static path, keyed on the dispatch fact); a `?{A}`'s and `!{A}`'s to their last use, a box's to its drop; `+ Owned` for no-loan homes; the block-local copy | `src/ownership.zig` |
| Tables and fat pointers: `emitApi` writes `__rig_table_Shape` and `__rig_table_Shape_of(comptime T: type, comptime W: type) *const __rig_table_Shape` for every API an object can reach; `emitTypeTy` (9613) writes `rig.ApiView(__rig_table_Shape, .read)`, `.write`, `rig.ApiBox(__rig_table_Shape)`; `emitLend` (5127) writes an erasure; a call `s.vt.area(s.ptr, args, slot)`; `calleeTakesSlot` answers yes for `dynamic` | `src/emit.zig`, from facts only |
| `rig.ApiView`, `rig.ApiBox` (its `__rig_drop` calls `vt.drop`; reached for printing and drop as `Box` is), entry helpers for each self mode | `src/runtime.zig` |
| The oracle: object kinds computed itself (an `objectInfo` beside `callableInfo`); an erasure as a lend or a move that keeps every loan; a dynamic call with the API's clauses from the dispatch fact; the block-local copy | `test/oracle/kinds.zig` (`Kinds.of`), `lower.zig` (`method`, `apiMethodOf`) |
| Lean: a packing lemma (erasing a type keeps its loan tags; a box of erased type is owning, its drop reading its loans) | `formal/LambdaRig/` when λRig has boxes of views; else an obligation in `docs/design/formal-plan.md` |

## Phase 0: the Core (docs only, owner) *(done)*

Stage 4 changes ownership rules, so CORE changed first, as its own
reviewed change (North Star 5, the Core change process): a panel of
four (a Core purist, a compiler implementer, an adversary, and a
reviewer) revised the draft this plan proposed, closing thirteen holes
(H1 to H13), and the owner approved the final text on 2026-10-23
([core-panel/](core-panel/), `6-final.md` and `approved.md`). CORE now
has:

- §1's kinds table: `?{A}` and `!{A}` among the views, `^{A}` among
  the owners, each *planned*.
- §4's lend table, its last row: "a `T` that provides `A` | `?{A}` |
  `!{A}` | planned".
- The paragraph *An API object hides its value's type, never its
  loans*, and its list *Only its methods reach the value*, with two
  `rig pending` examples (`area_of` printing `4.0 9.0`, and a read loan
  through `s: ?{Shape} = ?v[0]` rejected).

What the panel changed from this plan's draft, and the design now
follows: the object may hold anything (a view, a handle, a `drop`
body), not only a loan; a copy is decided by kind and is a local of the
erasing block, not the frame; only a `^{A}` has `+`; an object meets
only the `Clone`, `Print`, and `Owned` its braces or API name; it has
no default value and is never a type argument, written or inferred;
only the value reached is erased; a `<@` call drops the box exactly
once, even if it fails.

## Phases

Each phase is one PR, opened as a draft with a checklist, through Rig's
full suite and Trig's light gate, with an adversarial review before it
lands (as review-p1 and review-p2 of Stage 3). Every phase only accepts
more programs, except the lexer change of phase 1, which no program can
meet (a brace never lexed), so Trig's emitted Zig must stay
byte-identical: Trig declares no API. Until a phase builds a form, the
form is a Rig error (North Star 1), and the phase that builds it removes
the error.

### Phase 1: the type and its facts (about 1,000 lines, 30 cases)

Grammar, lexer, resolve, sema, typecheck: the braces, `Type.api_object`,
the form rules, object facts, `sema.objectMethods` with its reasons. A
conversion to an object and a call through one are rejected: "an API
object is not built yet (docs/design/apis.md, Stage 4)".

Cases (`test/rig/types-apis.rig.test`, "apis object ..."), `fail` with
these exact texts:

- "bare": `` `{Shape}` has no size of its own: hold it behind a view or a box, `?{Shape}`, `!{Shape}`, or `^{Shape}` ``, as a local's, a field's, a parameter's, and a type argument's type;
- "a type in braces": `` braces hold APIs, and `Square` is a type: write `?Square` for a view of it, or name an API it provides, `?{Shape}` ``;
- "a type parameter in braces": `` braces hold APIs, and `T` is a type parameter: write `[T: Shape]` and `?T`, or name an API, `?{Shape}` ``;
- "two APIs": `` `{Shape + Named}` names two APIs of a program's own, and an object has one table: declare `api Both: Shape + Named` and write `?{Both}` ``;
- "Copy in braces": `` an API object never copies but as a view does: `?{Shape}` copies, `^{Shape}` moves; take `Copy` out of the braces ``;
- "Eq in braces" (and `Hash`, `Ord`): `` two API objects may hide two types, which `==` cannot compare; take `Eq` out of the braces ``;
- "crossing in braces": `` an API object that crosses tasks, `^{Shape + Sends}`, is not built yet (docs/design/apis.md, Stage 5) ``;
- "a bound not named": `Map[?{Shape}, Int]` (`` `?{Shape}` is not `Hash`: an API object meets only the `Clone`, `Print`, and `Owned` its braces or API name ``);
- "an associated type unnamed": `` `Source` declares `type Item`, so an object of it names that type: `^{Source[Item: Int]}` `` (phase 5 builds the named form; until then `` ... is not built yet ``);
- "stray braces": `if x {` and `x = {1}` keep `` unexpected `{`; Rig has no braces: a block is the lines indented under its header ``;
- `test` cases that parse and print the types of `List[^{Shape}]`, `^{Shape}?`, `?{Shape + Owned + Print}` through `$name`;
- a `test/cli/facts_sema.sh` line for the type's spelling in `--facts=sema`.

### Phase 2: views and calls (about 2,200 lines, 50 cases)

The erasure to `?{A}` and `!{A}` (the lend row, its composition through
boxes, handles, frozen handles, and optionals; the copy local to its
block; lent temporaries), calls through them with the `dynamic` fact, error
sets and the slot, `Shape.area(s)`, no assignment through `!{A}`,
ownership by the API's clauses, the tables and `rig.ApiView`, and the
oracle's lowering of both.

Cases:

- `types-apis`: `area_of(sq)`, `area_of(?b)` of a `^Square`, `area_of(?h)` of a `*Square`, `area_of(?f)` of a `*Frozen[Square]`, `area_of(3)` with `add Int: Shape`, `area_of(?x)` in a `[T: Shape]` body; a default and an addition's method through an object; `!w.grow(2.0)` seen by the owner; a `List[?{Shape}]` walked; keyword arguments by the API's names; `Shape.area(s)`; and these `fail`s:
  - `` `area_of(?l)` cannot lend `l` as a `?{Shape}`: `Label` does not provide `Shape`; declare `obj Label: Shape` ``;
  - `` `x` is a `T` with no bound, so it is no `?{Shape}`: write `[T: Shape]` ``;
  - `` `Shape.scale` takes compile-time parameters, which a call through `?{Shape}` cannot pass: call it through a bound, `[T: Shape]` ``, and `` `Shape.join` names `Self` outside self, which a call through `?{Shape}` cannot know: call it through a bound, `[T: Shape]` ``, and `` `Sized.each` takes a set parameter, `E`, which a call through `?{Sized}` cannot pass: call it through a bound, `[T: Sized]` `` (one per reason);
  - `` cannot lend to write through a read view `?{Shape}` `` (`!s.grow(2.0)` on a `?{Shape}`);
  - `` cannot assign through `w`, a `!{Shape}`: the value it views may be of another type; call its methods, or hold a `^{Shape}` and replace the box ``, with siblings for `w += x`, `swap(!a, !b)`, `<w`, and `x = w` (`` `w` is a `!{Shape}`, whose value's type is erased, so `x = w` neither copies nor moves it: lend it on, `x = ?w` or `x = !w` ``);
  - `` `?{Shape}` of `p` views a copy held in this block, since `Point` is plain data, so it cannot leave the block; lend the owner where it lives, or take `p: ?{Shape}` `` (returned, stored in a caller's `!List[?{Shape}]`, and kept across a loop's passes; used in the block is a `test`; a large plain object behaves as a small one);
  - `+s` of a `?{Shape}` (`` `+s` would make a value of no size of its own: only a `^{Shape}` has `+` ``);
  - an inferred type argument, `put(!w1, !w2)` of two `!{Shape}`s into `put[T](a: !T, b: !T)` (`` `T` cannot be `{Shape}`, which has no size of its own: an API object is never a type argument ``);
  - a default value, `Table[^{Shape}, 4]` (`` an API object has no default value: write `^{Shape}?` ``);
  - `` `total[^{Shape}]` cannot use `T = ^{Shape}`: `total` needs `T: Shape`, and an API object meets no bound by an API; take a `?{Shape}` `` and the Stage 1 sibling (`` ... an API object's methods are called only where its type is written ``);
  - `` `*Frozen(<b)` freezes a `^{Shape}`, whose type is erased, so whether it can be frozen is not known: freeze the value before erasing it `` (phase 3 for the box; the view form here);
- `errors-apis`: `!` of an API's `Bad` into a union holding it, through `?{Sized}`; `catch |e|` matched without `_`; a set with fields (a `String` among them) through an object under `RIG_SANITIZE=1`; `T!` through an object; a failing default through an object;
- `ownership-apis`: a result `from @` of a `?{Shape}` keeps the owner's loan (`!sq.grow()` after it is rejected); `keeps s` through a `!{Watcher}` stores the loan in the owner; an implementation with fewer `keeps` called through an object keeps the API's loans; an object of a temporary past its statement rejected;
- `emit-apis` (`code`): `s.vt.area(s.ptr)`; `.vt = __rig_table_Shape_of(Square, __rig_impl_Shape_Square)`; `pub const __rig_table_Shape = struct`; an entry calling `W.area(rig.selfArg(W.area, p))`; the slot a `!` lends passed after the arguments of `s.vt.size(s.ptr, ...)` for a set with fields;
- `test/cli/facts_sema.sh`: `dispatch call ... "s.area()" dynamic Shape.area slot 0` and `erasures ... "sq" Square ?{Shape} __rig_impl_Shape_Square(Square)`.

Oracle: an erasure lowered as the lend it is, keeping every loan; a
dynamic call with the API method's clauses from the dispatch fact,
never an implementation's; the object kinds from `Kinds.of`, computed
from the type, never from the compiler's facts. It abstains on nothing
this phase builds; floors in `test/oracle/coverage` go up, never down.

Speed: a `bench/apis` pair at the phase's end, a loop of calls through
a `?{Shape}` against the same calls through a `?fun` and through an
enum's `match`, fastest of 5, interleaved, on both machines; the
object call within 2% of the `?fun` call (the design's claim).

Docs: SPEC gains "API objects" after "APIs" (the view forms, with
examples and the rejections above); SYNTAX the type form; QUICK the
braces; apis.md's Stage 4 *(in part)*; CORE's phase 0 rows to
*(built)* for views.

### Phase 3: boxes (about 1,500 lines, 40 cases)

`^{A}` from `<c` of a `^T` (its allocation kept) and from `^...` where
the `^` is written; its drop through the table (the queue of
`rig.Box`); `<@` methods (`<b.m()`); `!b` lending `!{A}` and `b = ^...`
replacing the box; `+ Owned` checked at erasure and its no-loan homes;
`Clone` and `Print` entries; loans to the drop; `^{A}?` and recursive
types (`next: ^{Node}?`); `List[^{A}]` grown, sorted by a key, cleared;
tasks over a call through an object (local); closures capturing objects.

Cases:

- `types-apis`: the design's example (a `List[^{Shape}]` of two types, a default through each); a recursive list of 100,000 boxed objects dropped without deep recursion; `<b.close()` frees once; `b = ^Circle(r: 1.0)` drops the old value; `print(b)` with `+ Print` and with `api Shape: Print`; `+b` with `+ Clone`; `s.area()&` local; `fail`s:
  - `` `Note` is erased to `^{Shape + Owned}`, which holds no loan, but its field `text` is a `?String` ``;
  - `` `+b` makes a new owner, and a `^{Shape}` is not cloned: its type is erased; write `^{Shape + Clone}`, or build `Shape` on `Clone` ``;
  - `` `^{Shape}` cannot be printed: its type is erased; write `^{Shape + Print}`, or build `Shape` on `Print` ``;
  - `` `<s.close()` consumes self, and `s` is a `!{Shape}`, a view: only a box, `^{Shape}`, gives its value up ``;
  - an owned closure capturing `<b` of a `^{Shape}` (`` an owned closure holds no loan, and a `^{Shape}` may hold one: write `^{Shape + Owned}` ``);
  - a channel send, an actor's argument, an actor's state, an error set's field, and `*Frozen(<b)` of a `^{Shape + Owned}`, which may hold a handle (the existing crossing, error, and freezing messages, naming the object);
  - a failing `<@` method, `<b.close()` that fails, drops the box exactly once (a `test` under `RIG_SANITIZE=1`);
- `ownership-apis`: a `^{Shape}` of a value holding `?t` keeps `t` lent to its drop, not its last use; `!b.watch(?t)` with `keeps s` makes `b` carry `t`'s loan; `^{Shape + Owned}` lets `t` change after the box's last use;
- `emit-apis`: `rig.ApiBox(__rig_table_Shape)`; the conversion of `<c` writing no allocation; a `<@` entry freeing the box;
- every `test` case under `RIG_SANITIZE=1` (the runner), and one with `RIG_LEAK_TRACE=1` in `test/cli`.

Oracle: a box's erasure as a move that keeps the loans; the box's kind
(owning, drop reads its loans without `Owned`); `<@` through a box.

Docs: SPEC "API objects" gains boxes; CORE's rows to *(built)*;
apis.md's Stage 4 *(built)* but for associated types; CHANGELOG;
HANDOFF; docs/learn/07's later sections (a backlog entry if not).

### Phase 4: the proof (about 250 lines of Lean)

`formal/LambdaRig/`: the packing lemma of apis.md's checker table,
erasing a type keeps its loan tags and `Rel` holds with an object's
facts (owning, its drop reading its loans), stated over λRig's boxes
and views as an `erase` form that evaluates as its operand. It needs
Stage 3's phase 5 (the subsumption lemma) for calls through the
object; the packing half stands alone. It gates nothing in the
compiler, and may land beside phase 2 or 3 when ready, or stay an
obligation in `docs/design/formal-plan.md` if λRig still lacks
functions.

### Phase 5: objects with associated types (about 700 lines, 15 cases; when a program needs it)

`{Source[Item: Int]}` and `{Iter[Item: Int]}`: the braces name each
associated type; an erasure checks `Conformance.assoc` (or
`sema.iterItem` for `Iter`) against it; the table's entries take the
named type. `for x in !it` over a `!{Iter[Item: Int]}` advances it
through the table, which needs the loop's classifier to see an object
(`iterItem` of an object is its named `Item`). Cases: a `^{Iter[Item:
Int]}` of `text.split` and of a program's iterator in one `List`; a
mismatch (`` `Words` gives `Item = ?String`, and `^{Iter[Item: Int]}` names `Int` ``);
a missing name. This phase waits for a program that needs it
(open question 7).

## Risks, and the North Star checks

- **Accept means correct.** Phase 1 accepts types it does not lower;
  no program may reach an unlowered conversion or call: each is a Rig
  error with a case, and a `code` case shows each lowered form. An
  entry's Zig type comes from the API's declaration alone, so every
  type erased to it fits; a `code` case per self mode and one with the
  slot.
- **Safe code cannot corrupt memory.** The three holes known before
  this plan, each with a case from its phase: assignment through
  `!{A}` (the panel's A1), a marker widened between object types (A4),
  and an object viewing a local copy of a view (the failure Stage 3's
  phase 2 met first: a `?@` result viewing a local copy); the core
  panel's thirteen holes (H1 to H13, [core-panel/](core-panel/)) each
  get a case in the phase that builds the form. Every `test`
  runs under `RIG_SANITIZE=1`. Two rounds of soundness fixes in one
  phase stop the feature for redesign (CORE §10).
- **Effects stay visible.** No sigil marks the erasure; the braces of the
  expected type do, and the erasure is a recorded lend or move, with no
  allocation the source does not write (`^`), checked by a `code` case
  that `<c` allocates nothing.
- **One classifier per fact.** "Does `T` provide `A`, by which witness":
  `sema.provides`, as in Stage 3. "Which methods an object reaches, in
  which slot": `sema.objectMethods`, read by typecheck, emit, and the
  oracle. "Is this an erased view no assignment writes": one predicate.
  "Does a drop read loans": `dropRunsBody`. "Is a view held as a copy":
  `lendByValue`, the rule `rig.ReadView` mirrors. Each merge adds the
  case two paths would have split on.
- **Emit decides nothing.** The erasure, its witness, the dispatch kind,
  and the slot are facts; emit never looks up a conformance or a method
  list. `facts.zig`'s `Pending` gains nothing.
- **The oracle.** Never weakened; an object's kinds computed from the
  type in `kinds.zig`, not read from the compiler's facts; differences
  recorded in `test/oracle/differences`.
- **Speed.** A program with no object emits the same Zig: compare
  std.json's and Trig's emitted Zig before and after each phase
  (expect identical: neither declares an API), run the speed census
  after merges, and bisect any change over 2% before more lands.
  `bench/apis` holds the object call to a `?fun` call.
- **Nexus and editors.** `rig.grammar` and `src/rig.zig` change in
  phase 1; Nexus's refresh copies Rig's main. The editor grammars
  (TextMate, highlight.js, Vim) learn braces in a type through the
  editor-support session.
- **Zig.** A table is a `const` behind a comptime function, so one per
  API and type; a `code` case across modules shows one table for a type
  erased in two (Zig memoizes `__rig_table_Shape_of(Square, W)` by its
  arguments, and `W` is the one witness declaration).

## Docs, by phase

- Phase 0 *(done)*: CORE §1, §4, and the paragraph, as `rig pending`.
- Phase 1: SYNTAX's types; SPEC "API objects" with the form rules.
- Phase 2: SPEC's views and calls; QUICK; apis.md *(in part)*; CORE
  pending to built for views; CHANGELOG; HANDOFF.
- Phase 3: SPEC's boxes; CORE built; apis.md *(built)* but phase 5;
  docs/learn/07.
- Phase 5: SPEC's associated types in braces; STD (`Iter` objects).

## Size

About 5,400 lines of compiler, tests, and docs across four compiler
PRs (phases 1, 2, 3, and 5, the last on need), 60 lines of CORE before
them, and 250 of Lean. Phase 2 is the bulk and the risk; phase 3
follows its pattern; phase 1 is mostly the type's rules and their
messages.
