# Row 33C, expert review: the compiler

Read against origin/main 370b3e41a (line numbers are from that tree). Probes ran with the
`bin/rig` of 144f70057 (the read-only worktree), `rig check` / `rig emit` only, in a scratch
directory. Probe sources: `/private/tmp/claude-501/-Users-shreeve-Data-Claude-Worktrees-rig-rig-language-analysis-aa0a1d/67c60f05-c7b3-4699-a1a3-55125acb3379/scratchpad/p/*.rig`.

## Summary

The draft names the right gap but the wrong deciders and the wrong rows. Three findings change it:

1. **Nearly all the named predicates are type questions and stay.** The expression deciders
   that answer "what does this value view, and where does it live" are others the draft does not
   list: `sema.viewsOnlyMade` (sema.zig:14547), `storage.startsOutsideHeader` (storage.zig:567),
   the three `placeOf(...).named()` loop checks (typecheck.zig:3535, 3557, 3570), `typecheck.tempBase`
   (typecheck.zig:4174), and `sema.forViewsSlot` (sema.zig:14498).
2. **A three-valued join loses what readers need.** `moveSource` asks "may this be a place's"
   (place dominates); headers ask "may this be in a value made here" (made dominates). A mixed
   view (`pick(?ls, ?mk())`) needs both bits. Use a set `{place, made}`.
3. **The draft's "siblings fail today" is wrong for `match` and `if ... as` over a call's view**:
   both are accepted now (probes `m.rig`, `i.rig`). Only the `for` rule over a List, table, or
   shared handle of moving elements rejects. The siblings that *do* fail are different:
   a path through a call's view when the call makes an unrelated temporary (`o5.rig`), a path
   through a call's view in a loop (`o4.rig`), and a view field of a made owning object (`r.rig`,
   `r2.rig`).

## 1. Who answers "is this expression a view, and of what" today

### Type questions: they stay

| Predicate | Where | What it answers |
|---|---|---|
| `isReadOrWriteView` | sema.zig:10385 | is the type `?T`/`!T` |
| `isViewType` | sema.zig:11971 | `?T`, `!T`, `[]T`, `?String` (parameter lending, `lentParam` 11962) |
| `holdsMarkedView`, `mayHoldMarkedView`, `mayHoldView` | sema.zig:10976, 10982, 10989 | may a value of the type carry a loan (CORE §9 per-type fact) |
| `holdsViewOnly` | sema.zig:11504 | holds only `?String` views (ownership.zig:1597, 2768, 3388, 5598, 5622, 6119) |
| `viewHeldAsPointer` | sema.zig:11469 | representation (facts.zig:1105, emit.zig:6147, storage.zig:55, 1482) |
| `isErasedView` | sema.zig:644 | API object view, erased value (typecheck.zig:1691, 1778, 9746) |
| `readsAsValue` | sema.zig:12745 | a scalar read through a view reads as the value (typecheck.zig:19138) |

Their ~90 call sites ask about a type: a symbol's declared type, a parameter's, a result's,
an element's. None of them should read the new fact. The draft should say so outright rather
than calling them "eight deciders".

### Compositions of `handsOver` and a type predicate: they stay, with one cleanup

- `typecheck.isTemporary` (typecheck.zig:6898): `part_of_made`, or `made`/`branches` whose type
  is not `?T`/`!T`. This asks "is the value itself a pointer to somewhere else, or storage made
  here". It is not "what it views". **It must not read the new fact.** Take `?mk_iter(?ls)`, where
  `mk_iter` returns an object that holds a view. The fact would say `place`, but the iterator
  object is still a temporary that needs a slot (`lendTemp`, typecheck.zig:6768). If that slot
  were skipped, emit would take the address of a Zig temporary that no storage fact names,
  which is the weak spot docs/internals/weak-spots.md forbids. Callers: typecheck.zig:6768, 6835,
  13162, 13349, 13512, 14125, 14194, 14217.
- `pathHands` (sema.zig:14397): a path from a made base whose type is a view is `.place`. That
  stays as the *kind*. The fact adds whether what it reaches is made (`id(?mk()).e`).
- emit.zig:5379 (`emitOptionalHead`'s `owns`) is emit deciding from `handsOver` plus a type. It
  is not this fact, but it breaks "emit decides nothing". It should become a recorded fact,
  typecheck's own `owns` at typecheck.zig:2846. That is a separate cleanup; leave it out of 33C
  or fold it in as a one-line fact.
- ownership.zig:1632, 1672 and typecheck.zig:2604, 2634, 2784, 2811, 3199, 3674, 3680, 4108,
  4539, 7171, 7678, 8456, 15813, 16283, 17195, 19069 ask about a symbol's, field's, or
  element's type. They stay.

### Expression deciders: these read the fact

| Decider | Where | Today's proxy | With the fact |
|---|---|---|---|
| `viewsOnlyMade` | sema.zig:14547 (used by `moveSource`, 14462) | walks lends and call origins | `views == {made}`; delete the function |
| `startsOutsideHeader` | storage.zig:567 (via `reachesPlace` 538, which feeds `headerPoints` 516, `matchesInPlace` 932, typecheck's `rejectHeaderCopy` 4163, emit's `headerPoints` 2626) | "the path's base makes no statement temporary" | `made ∉ views` of the path's base |
| loop rule, List | typecheck.zig:3570 | `placeOf(src).named()` | named, or `views ≠ ∅ and made ∉ views` |
| loop rule, table | typecheck.zig:3557 | same | same |
| loop rule, shared handle | typecheck.zig:3535 | same | same |
| `tempBase` | typecheck.zig:4174 | the path's base drops a temporary | a part whose value is a view reads what it views, not its base |
| `forViewsSlot` | sema.zig:14498 | `handsOver(src).kind == .place` | also a view-typed source with `made ∉ views` |
| `rejectHeaderCopy` exemption | typecheck.zig:4161 and `storage.holdsView` 917 | "a view a call returns" (match only) | any view-typed subject with `made ∉ views` copies only the pointer |

Two of these show the cost of having two answers:

- **`viewsOnlyMade` misreads a lend of a call's view.** `viewsOnlyMade(!getw(!b))` is true,
  since the operand `getw(!b)` is `made`. But the view is of `b`. So `<(!getw(!b)).o` is reported
  as "cannot take out of a temporary" (probe `h.rig`, original form). It is rejected anyway by
  `checkLendBases`, so no program is unsound. The draft's lend row has the same mistake: a lend of
  a value whose own type is a view views what that value views.
- **Two headers over the same storage get opposite answers.** `match pick(?es, ?String("k"))` is
  accepted (`o3.rig`), because `holdsView` handles a call's view whatever its temporaries.
  `if pick(?hs, ?String("k")).o as s` is rejected (`o5.rig`, "this header binds a copy of its
  subject"), because `startsOutsideHeader` sees the `String("k")` temporary in the base. Here
  `pick` is declared `from hs`, so the view never reaches the temporary.

## 2. Is `sema.handsOver` the right place?

**Classify it in sema, beside `handsOver`. Do not put it inside `Hands`.** Record it through
storage's decision table, as `.hands` is now.

- `handsOver` is not stored. It is a pure function, about 100 call sites, recomputed on every
  ask (sema.zig:14321). The new answer recurses into call arguments through `callParamsOf`. If it
  went into `Hands`, every hot `hands()` call would pay for that. Make it a separate entry point,
  `sema.viewsOf(ctx, e)`, as one exhaustive switch over `shapeOf`.
- Add `Question.views` (sema.zig:2360) with a `packed struct(u8) { place, made }` answer. `encode`
  already bitcasts structs (storage.zig:1350). Add `storage.viewsOf` going through `decide`, and a
  `Facts.viewsOf` accessor beside `Facts.handsOver` (facts.zig:766). `verifyDecisions`
  (storage.zig:1386) then proves that every pass, typecheck's early askers included, got the
  same answer. That is the "recorded before every reader asks" guarantee, checked in every
  build rather than assumed.
- **Facts it needs, and when each exists:**
  - `typeOf` of the expression, recorded when typecheck synthesizes it. Every reader asks after
    `synthExpr` (checkFor asks after typecheck.zig:3104; `moveSource` after the operand is
    typed). `headerPoints` runs later.
  - `callParamsOf(call)`, recorded at typecheck.zig:11098, only when the call checks with no
    missing argument. Task calls already widen `origins.result` to every parameter
    (typecheck.zig:11091).
  - The receiver's carry: `resultCarriesReceiver` (sema.zig:2923).
  - At a generic instance, `typeOf(call)` is already the concrete result.
- **A missing fact must never add `made`.** If there are no `CallParams` (a call with errors, an
  intrinsic), fall back to today's rule: `made` exactly when an argument makes a statement
  temporary, which is what `startsOutsideHeader` checks; `place` otherwise. Then the new answer is
  never more `made` than today's, and "nothing accepted today is rejected" holds by construction.
- **A type that holds a type parameter** (`holds_type_var`) counts as a view for this question,
  so its origins are walked. An `?{A}` API object view is a view type; its methods' origins come
  from the API's declaration, which `CallParams` carries like any other.

## 3. The failing loop, traced

`for x in first_list(?ls)` is checked by `checkFor` (typecheck.zig:3062):

1. The mode is `.iter`. `hands(source)` is `made`, the type is `?List[String]` and not an array, so
   no header is recorded (typecheck.zig:3127–3145). `unbound` is false, because the source is a
   made value (3156).
2. `elementTypeForLoop` (3542) peels the view to `List[String]`. `String` moves, and
   `placeOf(call).named()` is false: the base is a call, not a `.src` (2133). That is the
   rejection at 3570–3577.

**Everything after typecheck already handles it:**

- **Emit.** The plain-element twin (`c.rig`) already emits
  `for (rig.rt(first_list(&ls)).items()) |x|`. The named twin (`d.rig`) emits
  `for (v.*.items()) |*e| { const x = e.bytes(); ... }`. The accepted loop would take the first
  form with the second's capture: read in place, drop nothing. `storage.forConsumes`
  (storage.zig:850) is false for a view type (`owns(?List)` is `moves != .no`, which is false), and
  `loopBindsStringBytes` decides by type. **Emit needs no source change for the loop.**
- **Ownership.** `walkFor` (ownership.zig:7343) walks the call. For a source with no place it
  sets `spec.moved = value.loans` (7375), so the elements carry the call's loans on `ls`, and
  `headerTempLoan` (7373) rejects a loan on a header temporary. This already works for the
  accepted slice twin: `for x in first_slice(?ls)` with `!ls.push(...)` in the body is rejected
  with "cannot lend `ls` to write while a read loan is live" (`b2.rig`). With `?mk()` instead it
  is rejected with "a view of the temporary `mk()` outlives its statement" (`e.rig`, `f.rig`).
- **Storage.** No header temporaries are planned (`?ls` is a lend of a place). `forViewsSlot`
  should be true here, so the element gets `slot_view`/`loop_view` like the place form. The
  element is already typed as a view (`?String`, `?*Foo`, probe `hd.rig`), so this is consistency,
  not soundness.

**To accept it correctly**, the three loop checks (3535, 3557, 3570) accept a source that is
named, or whose `viewsOf` is non-empty with `made` absent. With `made` present, keep the
rejection, but name the made value in the hint ("bind `mk()` to a name first", not
`first_list(?mk())`). Binding the call to a name would still dangle, and the ownership checker
already says so. Extend `forViewsSlot` the same way. For `r2.rig` (`mk_rec(?ls).src`, a view field
of a made owning object), `tempBase` and `rejectHeaderCopy` must also ask the fact: the header
copies only the pointer, which points into `ls`.

## 4. Does emitted Zig change for programs accepted today?

- **The loop rule, `forViewsSlot`, and `viewsOnlyMade`: no.** Each fires only on programs
  rejected today. `moveSource` gives the same answer for every accepted program; it differs only
  for lends of a call's view, which `checkLendBases` rejects.
- **Replacing `startsOutsideHeader`: yes, for one narrow class.** A header whose path goes
  through a call's view, where the call also makes a temporary the view does not reach, and which
  binds plain data (the `rejectHeaderCopy` exemption at typecheck.zig:4166), is copied today. It
  would then be pointed: the block yields `&place` instead of a copy. Behaviour is unchanged; the
  bytes change. Run `tools/emit-diff BASE` over examples, benches, std, and Trig to count it. I
  expect few or none in Trig.
- **Size.** About 200–250 lines of compiler code:
  - sema: +110 (`viewsOf`), −35 (`viewsOnlyMade`), small `forViewsSlot` change
  - storage: +20 (the `Question`, `startsOutsideHeader` and `holdsView` via the fact)
  - typecheck: +30 (one helper for the three loop checks, `tempBase`, `rejectHeaderCopy`)
  - facts: +5
  - emit, ownership: 0
  - Docs about 60 lines; 14 test cases.
- **Risk: low to moderate.** The fallback keeps it accept-only. `verifyDecisions` catches any
  ordering mistake. The real risk is a wrong origins walk accepting a dangling header. The
  ownership checker backs that up (`headerTempLoan`, `walkMatch`), and the tests below aim at it.
- **Areas touched:**
  - ownership-for, ownership-header, ownership-origin, ownership-move, ownership-generic,
    ownership-apis, emit-held, emit-loop, emit-match
  - ownership-misc-2: its two existing failures at lines 1993 and 2033 keep their text, since
    `mk()` and `makeSubs()` make the Lists
  - SPEC.md:6078–6107: the paragraph needs a sentence; its `rig reject` example still rejects,
    since `mk().items` is in a made value
- **Oracle.**
  - Add `viewsOf` (and `Views`) to the forbidden list in test/rig.rip:1037. `facts.views` is
    already forbidden.
  - The oracle's `forStmt` (test/oracle/lower.zig:2009) takes a made `.iter` source into a held
    var that carries its loans, so it should accept the loop.
  - The path forms (`o4`, `r`) go through `heldView`, and `o5` through `asHeader`. Run the matrix.
    Any rejection goes to test/oracle/differences with its reason, never into the oracle.

## Revised "Who records it, who reads it"

- **Records:** sema, in `sema.viewsOf(ctx, e)` beside `handsOver`: one exhaustive switch over
  `shapeOf`, from `typeOf`, `instanceOf`, and `callParamsOf`. Storage records each answer
  through its decision table (`Question.views`), so every pass reads the first answer and
  `verifyDecisions` fails on any later disagreement. Emit reads it only through
  `Facts.viewsOf`. Where a call has no recorded origins, the answer is today's rule: `made` when an
  argument makes a statement temporary.
- **Reads:**
  - `moveSource` (replacing `viewsOnlyMade`)
  - `storage.reachesPlace` (replacing `startsOutsideHeader`), and `holdsView`
  - the `for` source rules for a List, a table, and a shared handle
  - `tempBase` and `rejectHeaderCopy`
  - `forViewsSlot`
- **Does not read it:**
  - `isTemporary`: it asks whether the value is itself a pointer, a type question about a made
    value.
  - The per-type predicates (`isReadOrWriteView`, `isViewType`, `holdsMarkedView`,
    `mayHoldMarkedView`, `mayHoldView`, `holdsViewOnly`, `viewHeldAsPointer`, `isErasedView`,
    `readsAsValue`).
  - The ownership checker's loan flow, which stays the authority on which loans a value carries.
    The fact is the per-statement summary of it. Under `-Dself-check`, assert that a walked
    header value carries a loan on a statement temporary only when `made ∈ viewsOf`.

## Revised "The fact" rows (compiler-side corrections)

- **Shape:** a set over `{place, made}`. ∅ is "no value" (a jump, a statement). A three-valued
  join cannot serve both `moveSource` (may it be a place's) and headers (may it be made here).
- **Not by CORE §1 kind.** An owning object can hold a view (`Rec { name: String, src: ?List }`).
  `mk_rec(?ls)` carries a loan on `ls` while being owning. Its own storage is made, and its view
  field views a place. Replace row 1 with: a value with no view on its path and none in its type:
  `place` if it is a place, `made` if made here.
- **A lend `?x`:** if `x`'s own type is a view (a call's view result), what `x` views. Otherwise
  `place` or `made` by where `x` is.
- **A part of a made value whose value is a view** (`mk_rec(?ls).src`): what the made value's
  origins carry, as for a call returning a view. Any other part: `made`. The draft's "part of a
  made value, of the view kind → made" is wrong for view fields.
- **A place whose path crosses a view** (`pick(?hs).xs`, `mk_ref().f`): what that view views,
  whatever the place's own type.
- **A call:** the union over the arguments and receiver its origins carry. With no recorded
  origins, the fallback above. A `default` fill counts as `made` if it makes a statement
  temporary.
- **Static** stays out. A constant is a `place`, which is right for every reader listed. Add a
  third bit when whole-program parameter summaries need it (the `Holder[?String]` held item).

## Revised "Tests"

Accepted today, and currently rejected (`test`):

- `for x in first_list(?ls)` over `List[String]` (the draft's loop)
- `for x in ?first_list(?ls)`
- `for x in (first_list(?ls) if ls.len > 0 else ?ls[0])`
- `for b in pick(?hs, ?"k").xs`: a path through a call's view (`o4`)
- `for t in mk_rec(?ls).src`: a view field of a made owning object (`r`), and its `List[Int]`
  twin (`r2`), which is today rejected by `tempBase`
- `if pick(?hs, ?String("k")).o as s`, where `pick` is declared `from hs` (`o5`), and the same
  path as a `match` subject
- `for x in first(?hs)` over `?*List[String]`: the shared-handle rule (`s`)
- The table twin of the first case

Regressions that pass today (`test`, not "fail today" as the draft says):

- `match first(?es)` (`m`)
- `if first(?hs).o as s` (`i`)
- `match pick(?es, ?String("k"))` (`o3`)

Still rejected (`fail`):

- `for x in first_list(?mk())`, with the hint naming `mk()`
- `for x in pick2(?ls, ?mk())`, a mixed view with both bits
- `!ls.push(...)` inside the accepted loop: a read loan is live
- `keep.push(<h)` from a call-view loop over `List[*Foo]`
- A `code` case for the accepted loop: `items()) |*`, with no `rig.drop` of the source

Plus:

- Generic `id[T](?ls)` and `id[T](?mk())`
- An `?{A}` method returning a view
- `tools/emit-diff` over the corpus, counting the copy-to-pointer headers
- The oracle matrix, with differences recorded

Run under `RIG_SANITIZE=1` (the runner sets it). Remove the weak-spots entry
(docs/internals/weak-spots.md:106) and "Also open: the per-expression fact" (130). Update
INTERNALS "What an expression hands over" ("not classified yet") and the "Header subjects" table.
Add the SPEC §? sentence for the loop rule.

## Decisions, with defaults

1. **Shape:** a `{place, made}` set, not a three-valued join. Default: the set; static waits.
2. **Home:** `sema.viewsOf` beside `handsOver`, recorded through storage's `Question` table and
   verified at the seal. Default: yes, not inside `Hands`.
3. **Missing origins:** fall back to today's "an argument makes a temporary". Default: yes, so
   the change is accept-only by construction.
4. **Readers:** `viewsOnlyMade`, `startsOutsideHeader`/`holdsView`, the three loop checks,
   `tempBase`, `rejectHeaderCopy`, `forViewsSlot`. `isTemporary` and the per-type predicates
   stay. Default: as listed.
5. **Made-view loops:** typecheck keeps rejecting them, with the hint naming the made value.
   Default: yes, since it is earlier than the ownership checker and its message stays stable.
6. **Emit:** no source change. Bytes change only for copy-to-pointer headers. Default: accept,
   measured by emit-diff.
7. **emit.zig:5379 `owns`:** default: its own small follow-up, not 33C.
8. **The self-check tying the fact to the loan flow:** default: add it under `-Dself-check`.
