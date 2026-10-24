# APIs Stage 4, phase 2: views and calls (2026-10-23)

Phase 2 of [build-plan.md](build-plan.md), built on phase 1
([phase1-notes.md](phase1-notes.md), its [review](review-p1.md)), the
approved CORE text (§4, "An API object hides its value's type, never
its loans"), and Stage 4's 21 defaults ([open-questions.md](open-questions.md)).
A value lends `?{Shape}` and `!{Shape}`, and a call through one runs
the hidden type's method through the API's table. A box, `^{Shape}`, is
phase 3's and still rejected as not built yet.

## What is built

| Piece | Where |
|---|---|
| The lend table's last row, `LendStep.erase`: the value reached through boxes, handles, frozen handles, and optionals lends a `?{A}`, and to write a `!{A}`; never a place's or an element's type (`?List[Square]` is no `?List[?{Shape}]`) | `sema.lendRows` |
| The erasure, checked and recorded once: the value's type provides the API by a witness, meets the `Print`, `Clone`, and `Owned` the braces name, and is no object of another type (open question 10); `SemContext.erasures`, `--facts=sema`'s `erasures` | `typecheck.erase`, `sema.Erasure` |
| The copy of a read view of plain data or of a type parameter's value (H5, H12): decided by kind, a hidden local of the erasing block (`StorageKind.erased_copy`, `StorageLife.block`), declared before its statement; ownership roots the object's loan at it, never through `walkThroughView` | `typecheck.erase`, `storage` plan, `Emitter.emitErasedSlots`, `ownership.walk` |
| Calls, `s.area()` and `Shape.area(s)`: typed from the API's declaration with `Self` the object, the arguments checked by the API's names, self's sigil against the form, `Dispatch.dynamic {api, method, slot, self_mode, receiver_arg}`; `Dispatch.viaApi()` replaces the `== .static` tests in ownership and emit | `typecheck.objectCall`, `apiMethodCall` (`ApiVia`) |
| Ownership by the API's clauses: the call's `CallParams` carry the API method's origins, so a call passes on only its `from` and `keeps`, never an implementation's (H8) | as a call through a bound |
| No write through `!{A}` (A1): assignment and compound assignment, `swap`, and `x = w` each rejected by `sema.isErasedView`; `+s` of a view (H11) | `typecheck` |
| `print` by the braces' or API's `Print`; `==`, `!=`, and `.hash()` rejected, "two API objects may hide two types" (review's parked items) | `checkFormatArgs`, `EquatableWalk` |
| `Owned` and `Clone` through containers (review's parked item): `List[^{Shape + Owned}]` meets `Owned`, `List[^{Shape + Clone}]` `Clone` | `reachOf`, `deepCloneable` |
| Tables: `pub const __rig_table_Shape = struct` of an entry per method a call reaches, and `__rig_table_Shape_of(comptime T, comptime W)`, whose entries call `W.m(rig.selfArg(W.m, p), ...)`; written for every API, made by Zig only where a conversion names it | `Emitter.emitApiTable`, `SemContext.object_tables` (`typecheck.recordObjectTable`) |
| The objects: `rig.ApiView(__rig_table_Shape, .read)` and `.write`, `.{ .ptr = &sq, .vt = __rig_table_Shape_of(Square, __rig_impl_Shape_Square) }`; a call `s.vt.area(s.ptr, args, slot)` | `runtime.zig`, `Emitter.erasedObject`, `emitObjectCall` |
| The oracle: an object's kinds from its type (`objectInfo`: a view carries every loan; a box owns and its drop reads them), an object reaching anything (`Reach.anything`), an erasure lowered as the lend it is, the copy as a value made in its statement's scope, a dynamic call with the API method's clauses from the dispatch fact | `test/oracle/kinds.zig`, `lower.zig` |
| Closures' bar parameters may name an object, `\|s: ?{Shape}\|` | `Lexer.skipType` |

## Decisions beyond the design

1. **Two Zig types, one per view form.** A `?{Shape}`'s address is a
   `*const`, a `!{Shape}`'s a `*`, so nothing casts constness away
   (emit and the runtime's lint). A `!{A}` lends its `?{A}` by the lend
   table's `read_only` row, as `![]T` lends `[]T`, written `(w).read()`.
2. **Print through the table.** Every table holds `__rig_print`
   (`rig.printErased(T)`); the checker lets only an object whose braces
   or API name `Print` reach it. The plan put `Print` and `Clone`
   entries in phase 3; the review asked for `print` now, and a `Clone`
   entry needs a box.
3. **A fallible entry always takes the slot,** as a callable view does
   (open question 6), so a call of a method whose set has no fields
   lends one too; the entry passes it on only to a method that takes it
   (`rig.takesSlot`).
4. **Entries of `<@` methods are phase 3's,** with boxes: a `<@` method
   through a view is rejected as for any view. A method with no self is
   not reached through an object, with why.
5. **A receiver other than a name is evaluated once,** into a constant
   of the call's block, `s` being written twice (`s.vt`, `s.ptr`).
6. **A loop's element of plain data,** `for p in ?pts`, is already a
   copy local to the pass: an object of it kept past the pass is
   rejected as any view of it is ("`p` does not live long enough"); the
   copy's own message names an object of a held view of plain data,
   `p: ?Point`, returned, stored in a caller's List, or kept across a
   loop's passes.
7. **Expression spelling** (the coordinator's ruling from the phase 1
   review): braces stand only where a type goes; a type argument in an
   expression names an object's type with an alias, `total[S](s)`. So
   the plan's `total[^{Shape}]` and `Table[^{Shape}, 4]` cases are
   written through aliases; the default-value rule waits for boxes, the
   one form that could have a default.
8. **The bound messages:** at an object instance, "`total` needs `T:
   Shape`, and an API object meets no bound by an API; take a
   `?{Shape}`", and for an unbounded `T`, "an API object's methods are
   called only where its type is written". Phase 1's message for an
   inferred bare `{Shape}` stands.
9. **A task over a call through an object** is rejected as not built
   yet: it is local (open question 14), and is built with boxes.
10. **The entry's alignment check stays,** as a callable view's thunk
    has one: without it pup's call is 2% faster, but the Mac's 30%
    slower, since the entry then sets up a frame on each call
    (bench/apis).

## Cases

About 60 cases, each failing under phase 1's compiler (which rejected
every view of an object, or emitted no table): "apis object ..." in
`test/rig/types-apis.rig.test` (views of values, boxes, handles, frozen
handles, optionals, additions, generic bodies, defaults, write views,
Lists of views, calls by the API's name, the copy in its block, a large
plain object, a type with no fields, printing; the rejections of an
unprovided API, an unbounded `T`, a write through a read view, another
object, an unmet bound in the braces, assignment, swap and copy through
`!{A}`, a clone, the copy leaving its block, bounds at an instance, the
Core's read loan, `==` and `hash`, a call's arguments),
`errors-apis` (a set passed on, matched, a set with a `String` field, any
error, a failing default, a task), `ownership-apis` (a result from self,
`keeps` through a write view, the API's `keeps` not the
implementation's, a temporary, a loan to its last use), `emit-apis`
(the call, the erasure, the table, an entry, the slot, a receiver
evaluated once), and `test/cli/facts_sema.sh` (`dynamic`, `erasures`,
the copy's storage). Every `test` runs under `RIG_SANITIZE=1`.

## Speed

`bench/apis` (README there): a call through `?{Shape}` against a call
through `?fun`, 600 million each, fastest of 5, interleaved: 1% faster
on the Mac (274.6 ms against 276.5 ms), 2.5% slower on pup (916.7 ms
against 894.4 ms), whose difference is the entry's load from the table.

## Trig

Phase 2 only accepts more programs. Trig declares no API, and its
emitted Zig is byte-identical under main's compiler (3a736e58b) and
this one: the 12 of 15 programs with a `main` in its `tools/` and
`tests/` that build, as its packs build them (524 Zig files; the
runtime gains the objects' helpers, which no Trig program reaches), and
the 49 files of `src/` that emit alone.

## Not built (phase 3 and later)

Boxes, `^{A}`: the erasure by a move, their drop through the table,
`<@` entries, `+b` through a `Clone` entry, `^{A}?` and recursive
types, `Owned`'s no-loan homes, the default-value rule, tasks over a
call through an object, closures holding a box; associated types in
braces (phase 5); the Lean lemma (phase 4).
