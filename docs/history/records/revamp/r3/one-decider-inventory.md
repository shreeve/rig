# One decider: inventory of emit's ownership and memory decisions

Branch `one-decider` (worktree `rig-one-decider`), from main 1d356a09
(#86 merged). Line numbers are `src/emit.zig` at 1d356a09 (the snapshot
the inventory was taken from); function names are stable.

Status after this round:

- **Fact** — emit reads a recorded node fact (facts table or storage facts).
- **Type** — emit reads how a type is held in Zig (`Facts` "Types"): one
  answer per type, the same in every pass. Allowed by design (see "What
  counts as a classifier" below).
- **Moved** — was emit's own decision; now a recorded decision this round.
- **Pending** — emit still decides, through `Facts.pending` (the allowlist,
  25 entries, budget enforced by `facts.zig`'s unit test), or by a local rule
  over type facts (marked **T!**). Each row names the fact it should become.

Classification key used below: **F** recorded fact; **S** shared predicate
(storage.zig / sema node classifier) also called by another pass; **T**
per-type fact combined with emit's own rule; **E** IR shape only.

## What counts as a classifier

Structure (`src/facts.zig`): emit imports `std`, `parser.zig`, `rig.zig`,
`facts.zig`, `diag.zig` only. `sema.zig`, `storage.zig`, `resolve.zig` are
unreachable from emit, so `sema.copies(...)`, `storage.matchesInPlace(...)`
etc. do not compile there. `Facts` holds the context as `*const anyopaque`;
the unit test fails if emit imports another compiler file, names
`sema_context`, `@ptrCast`, or `anyopaque`, if `Pending` exceeds its budget,
or if a `Pending` entry is no longer used (so the list tracks reality and
only shrinks).

`Facts` offers three kinds of thing:

1. **Node facts** — getters of the facts table and storage facts
   (`symbolOf`, `typeOf`, `dropsTemp`, `lendOf`, `storageOf`, `useOf`,
   `headerOf`, ...), and from this round the recorded decisions
   `leafStep`, `reachesLeaf` (null when no pass decided it → emit's
   internal error).
2. **Types** — the type table, symbols, and per-type answers about how a
   value is held in Zig: `viewHeldAsPointer`, `lendByValue`,
   `interiorMutable`, `genericReadView`, `cloneable`, plus structure
   (`unwrapViews`, `boxedType`, `callableFn`, `nominalDecl`, field
   lookups, formatting). These are not node decisions: a `?T` is spelled
   one way everywhere, and the checkers read the same function.
3. **Pending** — every node decision emit still makes with a classifier the
   checkers also call (`handsOver`, `hoistsArgs`, `matchesInPlace`, ...),
   or with a per-type predicate it combines into its own node rule
   (`copies`, `moves`, `holdsCellByValue`, `readByAddress`,
   `assignWritesThrough`).

`Facts.syntax` re-exports IR-only helpers (`lentPlace`, `argValue`,
`contains`, `valueParts`, `isCatchAll`, `subjectRereadable`, ...): they read
no fact.

## Mechanism added this round: recorded decisions

`sema.Question` / `SemContext.decided`: a question about a node is answered
the first time any pass asks it and recorded; every later ask (emit's
included) reads the record. `storage.verifyDecisions`, at the end of
`storage.plan`, asks every recorded question again from the final facts and
panics (internal error) on an answer that changed after it was recorded —
the "two passes acted on different answers" class, detected mechanically.
Emit only reads (`Facts.leafStep`/`reachesLeaf`); an unrecorded answer is an
internal error. Converting a single-node predicate is mechanical: add a
`Question`, its `Answer` type and decider, and a `Facts` getter; make the
planner ask it wherever emit will read it.

Sweep: all 8,684 non-reject programs emitted with no internal error and no
`verifyDecisions` panic, so no drift exists today for `leaf_step` and
`reaches_leaf` between typecheck's `madeLeaves`/`readInPlace`, the plan's
walk, and emit.

## 1. Copy vs pointer

| Line | Function | Decision | Consults | Class | Status |
|---|---|---|---|---|---|
| 3285, 3310 | emitValue | lend a node as the lend table says | `lendOf` | F | Fact |
| 3311 / 3604 | emitValue / readsThrough | `(e).*` | `readsThrough` and `isPtrViewExpr` and not name/member/index | F+T+E | Pending (class V: `viewRead`) |
| 1760–1768 | writeLocalPlace | name holding a pointer view read as `name.*`; generic view `rig.viewed` | `is_ptr` (viewHeldAsPointer), `genericReadView` | T! | Pending (class V) |
| 3450 | emitName | yield the pointer itself | `ptr_tail` flag + `is_ptr` | T! | Pending (class V) |
| 3941–3948 | emitList member/index | field/element holding a pointer view: `.*` unless `tail && ptr_tail`; generic view via `viewed`/`viewedPtr` on the subject path | `isPtrViewExpr`, `genericReadViewOf`, `onSubjectPath` | T! | Pending (class V) |
| 1737, 1731 | emitPlace (index) | write view element deref; `viewedPtr` on the subject path | `isPtrViewExpr`, `onSubjectPath` | T+E | Pending (class V) |
| 3747–3778 | emitDeref / emitSwitchDeref | `rig.viewed(T,p)` / `(p).*` / `viewedPtr(T,&name).*` | `genericReadViewOf` | T | Type |
| 3529 | emitStored | store a pointer for a view | `isPtrViewExpr` and not `readsThrough` | T+F | Pending (class V) |
| 3688, 3717 | emitValueAs / emitBareAs | a view where a (optional) pointer view goes stays a pointer | `isPtrViewExpr`, `isPtrViewTy(unwrapOptionals(t))` | T! | Pending (class V) |
| 1854 | emitReturnValue | return the pointer for a pointer-view result | `isPtrViewTy(...)`, `isErrorValue` | T! | Pending (class V) |
| 5347 | emitArg | pointer-view parameter gets `emitWriteViewPtr` | `isPtrViewTy(params[i])` | T | Type (the parameter's representation; the plan's `.value` hold uses the same) |
| 3348–3442 | emitLend / lendChain | where a lend starts, `&x` or not, `\|*__rig_lent\|`, `rig.lend` | `lend.steps()` (F), shape (E), `isPtrViewExpr` (T) | F+E+T | Fact (lend rows) + Type |
| 3652 | emitLendAddress | `&operand` vs `emitReadLend` | `lendOf`, type, shape | F+T+E | Fact |
| 3861–3874 | emitList `.read`/`.write` | `?f` → FnRef; `?x` by pointer → address; `!x` slice vs `&x` | `callableFn`, `isPtrViewExpr`, `writeSliceElem` | T | Type |
| 4079–4088 | emitAddressOf | hoisted; reachesLeaf → leaf pointer; pointer local; pointer view; else `&` + place | `reachesLeaf` | S+T | **Moved** (`reaches_leaf`); the `&` fallback is class A |
| 4189–4281 | emitIndex | `vecAt` / `.at(i)` copy vs `.constSlot(i).*` / `.slot(i).*`; slice `rig.at` vs `rig.elemPtr` | `elemInPlace` = `copies != yes or holdsCellByValue`, `throughReadView`, `read_place` | **T!** | Pending (class X: `elemAccess`; `holdsCellByValue` is redundant there) |
| 4311–4330 | emitIndexBase | handle `.value`; generic view as written; reachesLeaf → member base | type, `reachesLeaf` | T+S | **Moved** (reaches_leaf) |
| 4477–4528 | emitMemberBase | object of a member: slot / place / leaf pointer / `@as(T, expr)` copy / `.*` of a call's pointer view | `reachesLeaf` (S), `writesTemp`/`dropsTemp` (F), shape (E), type (T) | S+F+E+T | reaches_leaf **Moved**; `@as(T, expr)` receiver is class A |
| 5791–5820 | emitPrintArgs / printsByAddress | print/`Text`/`add` argument by address | shape + `readByAddress(peelViews(ty))` | **T!** | Pending (class P: `printsByAddress`; ownership's `holdRead` decides it differently, own:3930) |
| 5984–6009 | writeCapturedView | `\|?x\|`/`\|!x\|` capture form | `writeSliceElem`, `is_ptr`, `isPtrViewTy`, `genericReadView` | T! | Pending (class B: binding form) |
| 5939 | emitCaptureInit `cap_move` | move the pointer vs `writeTake` | `is_ptr && isPtrViewTy`, `consumes` | T+F | Pending (class B) |
| 3887–3923, 5953 | clone | `cloneStrong`/`cloneValue(&(x))`/... | `cloneable` | F (type fact) | Type; `cloneValue(&(expr))` of a non-place is class A |
| 6145–6183, 3802 | emitTypeTy / emitViewPtrTy / emitPointerTy | `?T` spelling, `*T` vs `*const T`, ReadPtr/ReadView/ReadSlice | `lendByValue`, `interiorMutable`, `genericReadView` | T | Type |

## 2. Slot vs Zig temporary

| Line | Function | Decision | Consults | Class | Status |
|---|---|---|---|---|---|
| 1156–1192 | emitStmt / emitTempSlots / writeTempDrop | slots, flags, defers per statement temporary | `stmtTemps` (dropsTemp), `hiddenStorage(.temp)` | F | Fact |
| 3288 | emitValue | `rig.keep(&slot, &live, v).*` | `dropsTemp` | F | Fact |
| 1218–1231 | openHeaderBy / closeHeader | labeled header block | `firstStmtTemp`, `header_value` storage | F | Fact |
| 1252–1272 | emitSubjectPtr | header yields `&place` / view pointer / leaf pointer | `handsOver(e).kind`, `isPtrViewExpr` | S+T | Pending (`handsOver`; class H) — the leaf walk below it is **Moved**, and the plan now walks header subjects' leaves (`subjectHeader`) |
| 1277–1281 | copiesSubject | header copy = temps && !headerPoints, **checked against `copiesHeader`** | `headerPoints` | S, checked against F | Pending (`headerPoints`, class H) |
| 4545–4620 | emitLeafPtr | per leaf step: `(if (c) &a else &b)`, `\|*leaf\|`, place address, `&@as(T, lit)`, made: slot or `&@as(T, v)` | `leafStep`, `dropsTemp`, `interiorMutable` | S+F | **Moved**: `leafStep` recorded; `&@as(T, v)`/`&@as(T, lit)` require the storage fact `zig_temp` (`zigTemporary`) |
| 4627–4639 | emitPayloadHolder | the optional/fallible whose payload is captured by address | `leafStep`, `dropsTemp` | S+F | **Moved** (leafStep recorded; a made holder no slot keeps requires `zig_temp`) |
| 5181–5193 | emitCellAddress | refuse a made leaf no slot keeps on a Cell path | `madeLeaves` | S+F+T | Pending (`madeLeaves`; reads the recorded leaf steps but walks itself) |
| 5640 | emitSlotAddress | `&(keep(...).*)` | `dropsTemp` | F | Fact |
| 5004, 5343, 5604–5621 | emitElemCall / emitArg / hoist | `&` before a temporary array lent as a slice | `lendsTempArray`, `lendsCellTemp` | F | **Moved**: unhoisted `&[...]` requires `zig_temp` |
| 3216 | bindOptionalView | copy into `__rig_opt_N_v`, `&copy` | `o.copy`, `is_ptr` | F/T | Fact (`as_copy`) |

## 3. By-address capture

| Line | Function | Capture | Consults | Class | Status |
|---|---|---|---|---|---|
| 2546–2559 | emitMatch catch-all | read: `emitCapture`; write: `&place`; consume: `\|whole\|` | `matchMode` | S | Pending (class M) |
| 3036, 2786 | emitCapture / wholeBinding | `\|*x\|` vs `\|x\|` | `catchAllByAddress(ty, in_place)`; typecheck uses `copies != yes` for `arm_view` (tc:2585) | S+T | Pending (class M: record per catch-all pattern; two predicates today) |
| 2581, 3054–3077 | payloadAliases | `\|*p\|` when writes or any used binding by address | `payloadByAddress` (plan calls it on the same `b`); "used" is emit's `Scan` vs plan's names | S | Pending (class M), checked by `hiddenStorage(.payload)` |
| 2914 | guardBindings | `&subj.v.f` vs `subj.v.f` | `payloadByAddress` | S | Pending (class M) |
| 2282–2328 | emitFor | `\|*x\|` when write, taken, or element is a read view | `headerOf == .taken`, mode, binding type | **T!** | Pending (class H: `forConsumes`/element form) |
| 3125–3138 | emitOptionalHead | header viewed/held → `\|*__rig_opt\|` | `headerOf` | F | Fact |
| 3141–3182 | emitOptionalHead | view of an optional: copy vs pointer; subject `(name)` vs `((value).*)` | `viewsOptionalValue`, `lendsCellTemp`, shape | S+F+E | Pending (`viewsOptionalValue`, class H); **the shape test was a bug, fixed this round** (bf094123) |
| 3184–3205 | emitOptionalHead | resource → owned capture; plain → by value | `kindOf` (moves) | T | Pending (`moves`, class B) |
| 4554–4583 | emitLeafPtr fallback / unwrap | `\|*__rig_leaf\|` | `leafStep` + `leaf` storage | S+F | **Moved** |

## 4. Evaluation order

| Line | Function | Decision | Consults | Class | Status |
|---|---|---|---|---|---|
| 3930, 5528 | emitHoistedCall | hoist the arguments | `hoistsArgs` | S | Pending (class C) |
| 5452–5511 | hoistReceiver | receiver hold; **`by` recomputed by emit** instead of `ReceiverHold.by` | `receiverHold`, `consumedTemporary` | S+T | Pending (class C; read `by` from the `receiver` fact) |
| 5562–5632 | hoist | argument hold and `by` (duplicate of the plan's switch) | `argumentHold` | S+T | Pending (class C) |
| 5542 | emitHoistedCall | leave pure arguments | `isPureArg` | S | Pending (class C) |
| 1621–1679 | openAssign / hoistIndices | value into `__rig_new`, indexes into `__rig_ix` | `actsBeforeStore`, `isPureArg` | S | Pending (class O: `assignForm(set)`) |
| 1507–1521 | emitRebind | store after the value | `storageOf(value, .new_value)` | F | Fact |
| 2151–2187 | emitWhile | step inside the bindings' scope vs continue expression | `stepReadsBinding` (ownership asks it too) | S | Pending (class O: `loopStep(while)`) |
| 2610–2668 | evalSubject | how the subject is held; **branch re-derives `subjectHold`** | `subjectHold`, `hasStorage`, `headerPoints`, `isPtrViewExpr` | S+T | Pending (class M; switch on the `subject` fact's `by`) |
| 2496–2533 | emitMatch | what the switch reads | `headerPoints`, `handsOver == place`, `throughElement`, `hasStorage`, `isPtrViewExpr` | S+T+E | Pending (class M: `held_view` is computed three times: emit 2467, tc:2145, own:4891) |
| 5795 | emitPrintArgs | print args by address at the call | printsByAddress | **T!** | Pending (class P) |

## 5. Drop placement

| Line | Function | Decision | Consults | Class | Status |
|---|---|---|---|---|---|
| 6329 | kindOf | resource kind | `moves != no` + type shape | T | Pending (`moves`, class B: per-binding `dropForm`) |
| 1050 | resourceGuard | flag vs scope | `consumes` | F | Fact |
| 804, 852 | bindParams / emitFunPrologue | parameter is a resource; `var` copy | `isPtrViewTy`, `kindOf` | T | Pending (class B) |
| 1413 | emitBind | resource unless `holds_ptr` | `kindOf` + `holds_ptr` | **T!** | Pending (class B) |
| 1059 | emitHeld | `defer drop` of the held base | `heldBaseOf`, `kindOf` | F+T | Pending (class B) |
| 1496–1534 | emitRebind | drop old after new; re-arm flag | `assignWritesThrough`, `kindOf` | T | Pending (`assignWritesThrough`, class B/O) |
| 1586–1603 | emitPlaceAssign | `rig.drop(slot)` then store; chain duplicated in plan.placeAssign | `kindOf`, `writesThrough` | T+F | Pending (class O) |
| 1771 | emitDrop | `-x` | `local.kind` | T | Pending (class B) |
| 2263, 2343 | emitFor / emitConsumingFor | **consuming loop** | `is_vec && (move or (!hasStorage && kindOf))`, array of moving elements; plan copies the formula; ownership uses `mode == .move or headerOf == .taken` | **T!** | Pending (class H: `forConsumes(loop)`; two classifiers, harmless today because typecheck rejects a made Vec of moving elements) |
| 2973, 3088 | ownedParts / emitPrelude | `match <x` parts owned or discarded | `payloadBindings`, `kindOf` | F+T | Pending (class B) |
| 3231 | bindOptionalResource | owning `as` binding + guard | `kindOf`, `consumes` | T+F | Pending (class B) |
| 4098–4121, 5435 | emitInfix / dropsWhenTested | **`rig.isNone(x)` / `isVariantDiscard(x)` drop the operand inside the test** | `handsOver == made && !dropsTemp`, `kindOf` | **T!** | Pending (class D: a drop no checker walks; record in typecheck's comparison check or slot the operand) |
| 5486, 5605 | hoistReceiver / hoist | drop of hoisted values | `kindOf` | T | Pending (class B/C) |
| 5853, 5878 | closures | resource captures; `dropFields` | `kindOf` | T | Pending (class B) |
| 3307, 3452, 3510, 3826 | take | `rig.take(&flag, x)` | `useOf == .take`, `readsInPlace`, `consumes` | F | Fact |
| 1362 | emitSet `_ = e` | `rig.discard(e)` | `kindOf` | T | Pending (class B) |

## 6. Mutability

| Line | Function | Rule | Class | Status |
|---|---|---|---|---|
| 1422–1431 | emitBind | `var` iff rebound, or not a held pointer and written / owning / interior-mutable / comptime-folded; `rebound = repointed or (reassigned and !assignWritesThrough)` | **T!** | Pending (class B) |
| 1451 | emitBind | a rebindable view spells `*T` / `*const T` | T | Type |
| 3097, 3242, 5489, 5611 | prelude / optional / hoists | `var` iff value/optional kind, writes, cell, mutable temp array | T+F | Pending (class B) |
| 2654 | evalSubject | always `var` | E | — |
| 4213, 4287 | emitIndex / throughReadView | `.constSlot` vs `.slot` | T+E | Pending (class X) |
| 3802, 6172 | type spelling | `*T`/`*const T`/ReadPtr; `[]T`/`[]const T`/ReadSlice | T | Type |

## 7. View vs value

| Line | Function | Rule | Class | Status |
|---|---|---|---|---|
| 897 | declare | local `is_ptr` iff `viewHeldAsPointer` | T | Type |
| 1399–1413 | emitBind | `binds_view`, `copies`, `is_lend`, `holds_ptr` | **T!**+E | Pending (class B/V) |
| 1489 | emitRebind | re-point a view local | `repoints` (F) + `assignWritesThrough` (T) + shape | Pending (class B) |
| 1576 | emitPlaceAssign | re-point a field holding a write view | `isPtrViewExpr && !writesThrough` | T+F | Pending (class O) |
| 2467, 2523, 2643 | emitMatch / evalSubject | `held_view`; `viewedPtr` | S+T+E | Pending (class M) |
| 3164–3173 | emitOptionalHead | `(name)` vs `((value).*)` | E | **Bug fixed** (bf094123) |
| 5105 | emitCallDirect | owned closure from a call yielding a pointer view → `.*` | T | Type |

## 8. Addresses of Zig rvalues (HANDOFF list)

1. `?self` method on a value no slot keeps (emitMemberBase 4512–4527):
   `@as(Q, if (c) a else mkq(5)).me()` and `(mkq(6)).me()`. **Pending**
   (class A). Emit does not know it is taking the address (Zig does,
   implicitly, for a `*const Self` receiver): the planner should record
   `zig_temp` (or a slot) for such a receiver, and `emitCallDirect`
   should require it when the method's receiver is a pointer.
2. `emitLeafPtr`'s `&@as(T, value)` (and `&@as(T, lit)`, and a made
   payload holder): **Moved** — storage fact `zig_temp`, required by
   `Emitter.zigTemporary`. Two programs in the whole corpus reach it
   (`review-cell-temp2-p21_unique_named_leaf`).
3. Labeled value-block yields whose address is taken (emitAddressOf's
   `&` + emitPlace fallback, lendChain `&(value)` when `!at.ptr`; the
   emitLeafPtr route is now `zig_temp`; the emitMemberBase route is site
   1). **Pending** (class A).
4. Temporary array lent to a call (`&[_]T{...}` in emitArg, emitElemCall):
   **Moved** — `zig_temp`, recorded for a call that evaluates its
   arguments where they stand (hoisted arrays already had `argument`).

Other rvalue addresses not on the HANDOFF list (class A): clone `.deep`
`rig.cloneValue(&(expr))` (3914); `emitAddressOf(base)` of an index /
slice / elems base that relies on a slot no assertion requires (4254,
4354, 5028); lendChain's `.optional` row over a non-place (3432).

## 9. Found bugs

- **A (fixed, bf094123, test `test/behavior/emit/optional_view_field_as.rig`).**
  `if h.o as t`, `h.o` a field (or element, `hs[1].o`) holding a read view
  of an optional, was accepted by `rig check` and emitted
  `if ((h.o.*).*)`, which Zig rejects. Emit decided by the subject's shape
  (`value == .src`) whether its value was already dereferenced; the
  member rule had already dereferenced the field's view. Main fails the
  same program (verified with main's binary).
- **Two classifiers, latent today** (not fixed; each is a Pending class):
  consuming `for` (emit/plan formula vs ownership's `mode`/`taken`);
  print-by-address (emit's shape + `readByAddress(peelViews)` vs
  ownership's `holdRead`); catch-all by address (emit's
  `catchAllByAddress` vs typecheck's `copies != yes` arm-view rule);
  `held_view` computed in three passes; `dropsWhenTested` is a drop no
  checker walks; hoistReceiver/hoist/evalSubject recompute the `by` the
  storage fact already records (a disagreement would be an internal error,
  not a miscompile).
- **Equivalence:** across 9,720 programs (tests, examples, std, corpus, doc
  blocks), emit and the package hash are byte-identical to main at every
  commit except bf094123's fix; `check --facts=storage` gains `zig_temp`
  lines in 13 programs (additions only).

## 10. Plan for the rest (Pending → 0)

Ordered by risk and value. Each is one branch-sized step: add the
question(s) to `sema.Question` (or a node fact), have the plan (or
typecheck, where it decides first) record it, make the checker that
assumed it read it, switch emit to `Facts`, delete the `Pending` entries,
lower the budget.

1. **Class V — `viewRead(node)`** (value or pointer of a place holding a
   view): extend `readsThrough` to names, fields, elements, decided where
   typecheck adapts the view; emit dereferences in `emitValue` only.
   Removes `ptr_tail`/`want_ptr` flags; bug A was this class.
2. **Class A — the address chokepoint**: every `&` and `|*x|` reads a fact
   (place, slot, named storage, `zig_temp`); record `zig_temp` (or force a
   slot) for a pointer receiver no slot keeps and for block yields; give
   the checker the `life` to check.
3. **Class M — match decisions**: `matchMode`, `matchesInPlace`,
   `matchRereads`, `matchBlock`, `subjectHold` (single-node, mechanical
   with `Question`), `payloadByAddress`/`catchAllByAddress` per binding
   (record with the match as context), `held_view` once; typecheck's
   `arm_local`/`arm_view` read them.
4. **Class H — headers**: `headerPoints`, `viewsOptionalValue`,
   `forConsumes(loop)`, the `as` owns test, `handsOver` in
   emitSubjectPtr/emitOptionalHead (record the header form).
5. **Class C — calls**: `hoistsArgs`, `receiverHold`, `argumentHold`,
   `consumedTemporary`, `keptInSlot`, `hasStorage`, `isPureArg` (all
   single-node, mechanical); read `by` from the `receiver`/`argument`
   facts.
6. **Class O — order**: `actsBeforeStore`, `stepReadsBinding`, `assignForm`
   (emitPlaceAssign and plan.placeAssign share one recorded form).
7. **Class P — `printsByAddress(arg)`**, decided once, read by ownership's
   `holdRead` and emit.
8. **Class D — `dropsWhenTested`**: record it, and have the checker walk
   the drop (or keep the operand in a slot).
9. **Class B — binding form per symbol**: `is_ptr`, resource kind and
   guard, `var`/`const`, parameter copy; removes `moves`,
   `assignWritesThrough` from emit.
10. **Class X — `elemAccess(index)`**: removes `copies`,
    `holdsCellByValue`.
