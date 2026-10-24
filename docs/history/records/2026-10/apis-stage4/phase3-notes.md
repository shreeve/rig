# APIs Stage 4, phase 3: boxes (2026-10-23)

Phase 3 of [build-plan.md](build-plan.md), built on phase 2
([phase2-notes.md](phase2-notes.md)), the approved CORE text (§4, "An
API object hides its value's type, never its loans"), and Stage 4's 21
defaults ([open-questions.md](open-questions.md)). A box, `^{Shape}`,
holds a value of a type that provides `Shape` in the allocation the
`^T` it was made of held, drops it through the API's table, and ends
with a method that consumes self.

## What is built

| Piece | Where |
|---|---|
| The erasure of a box: a `^T` moved where a `^{A}` goes (`<c`, a `^Square(...)` written there, a call's result), a `^T` into a `^{A}?`, and a `^T?` into a `^{A}?`; only the box's value is erased, never a place's or an element's type (H3); recorded once, `Erasure.form = .box`, `optional`; `--facts=sema` prints it | `typecheck.eraseBox`, `erasable` (the checks views and boxes share) |
| The braces' `Owned` checked on the erased type, naming the field that holds a view | `typecheck.erasable` |
| `rig.ApiBox(__rig_table_Shape, "")`: `of` takes the `Box(T)`'s pointer, allocating nothing; `read` and `write` lend the box's `?{A}` and `!{A}` (the lend table's `unbox` row); its drop calls the table's, through `drop_queue` past 256 nested drops, as `^T` does | `runtime.zig`, `Emitter.emitValue`, `lendChain` |
| Table entries: `__rig_drop` (`rig.dropErased(T)`), `__rig_clone` (`rig.cloneErased(T)`), and an entry per `<@` method, which takes the value out of its allocation and frees it before the call (`rig.erasedTake`), so the method owns self and drops it once even when it fails (H7) | `Emitter.emitApiTable`, `runtime.zig` |
| `<b.m()` and `Shape.m(<b)`: the box moved, its drop flag cleared, before the entry runs; a `<@` method through a view, `!{A}` or `?^{A}`, rejected with "only a box gives its value up" | `typecheck.objectCall`, `checkReceiverMode` |
| `+b` through the table where the braces or API name `Clone`; otherwise rejected naming the fix | `typecheck.synthClone`, `rig.cloneValue` |
| Loans to the drop: a box's drop may run the hidden type's `drop` body, so its loans last to it (`runsDropBody`, phase 1), and a box of `+ Owned` holds none | the existing classifiers; cases in `ownership-apis` |
| `Owned`'s no-loan homes: an owned closure captures a box only with `Owned` in its braces (`sema.objectUnowned`, which walks fields) | `ownership.walkLambda` |
| No default value: `Table[^{A}, n]` rejected toward `^{A + Owned}?` (a table's slot holds no loan); `resize` and a constructor with the field left out keep their messages (H6) | `resolve.tableElementError` |
| Tasks over a call through an object: local (open question 14), `rig.Task(T).spawnObjectLocal(obj, "area", args)`, the slot from the task's record for a fallible entry; an object is no blocker of a local task | `typecheck` (task check), `sema.blockerIn`, `tasks.zig`, `Emitter.emitTask` |
| A Cell of an object rejected as Stage 5's (H9); an error's field of one rejected, as the hidden value may hold a handle (H10); crossing, actors, and freezing reject it by the existing rules, which name the object | `sema.objectCell`, `handleAt`, `blockerReason` |
| `$name` of an object's type inside a generic body: the Zig types carry the braces (`rig.ApiView(T, .read, " + Print")`) and the table its API's name (`__rig_name`), so `rig.typeName` spells `^{Shape + Print}?` | `runtime.typeName`, `Emitter.writeObjectBuiltins` |
| The oracle: a box's erasure is the move it is, keeping its loans; a box's kinds (owning, its drop reading its loans without `Owned`) from phase 2's `objectInfo`; `<@` through a box by the API's clauses from the dispatch fact. It agrees on every new rejection but one, a dynamic call's `keeps` stored into a box and read by its drop, which it accepts (a `ref-gap` in `test/oracle/differences`); its floors rise to what it decides (tests 22527, docs 1058) | `test/oracle/` (data only) |

## Decisions beyond the design

1. **Phase 2's last "not built" gate went too.** A call through a
   generic type at arguments that hold an object, `Ph[^{Shape}].mk()`
   (phase 1's review finding 1), now lowers: the alias is emitted and
   the type has a Zig spelling. Phase 1's "not built" cases for it
   became `test`s.
2. **The braces are part of the Zig type.** `rig.ApiView` and
   `rig.ApiBox` take the built-in APIs the braces name as a string, so
   `$name(T)` at `^{Shape + Print}` spells them; two objects with
   different braces never convert (open question 10), so nothing casts
   between them.
3. **A table's slot needs `Owned`.** The no-default message suggests
   `^{Shape + Owned}?`, not the plan's `^{Shape}?`, which the table's
   no-view rule rejects in turn.
4. **The clone entry is made for every type** and reached only where
   the braces or API name `Clone`; for a type `cloneValue` could not
   compile it is a stub no checked program calls (`clonesErased`).
5. **An object goes to a local task by any path,** not only as a
   call's self: `f(?b)&` with `f(s: ?{Shape})` is local too.
6. **A dynamic call's tasks pass the object by value.** `?b.area()&`
   copies the box's two words to the task, which runs the entry on the
   address; `b` stays lent for the task's life, as any receiver is.
7. **`??` does not erase.** `<sq ?? ^Circle(...)` where a `^{Shape}`
   goes is a type mismatch, as the fallback is checked against the
   left's type; `if` and `match` erase each branch.

## Cases

About 60 cases, each rejected as not built under phase 2's compiler: "apis object box ..." in
`test/rig/types-apis.rig.test` (the design's example, defaults, a
100,000-long recursive list, `<@` freeing once, by the API's name, a
failing `<@` under `RIG_SANITIZE=1`, replacement, lent views, fields
and optionals, printing by the braces and by the API and through a field, cloning by the
braces and by the API, a List grown, sorted by a key, and cleared, an
optional box, a local task, a generic argument, a table's optional
slots, an owned closure of an Owned box; and the rejections of `Owned`
over a view, a clone, a `Clone` of a type with a `drop` body, a print,
a field's print, `<@` through views, an owned closure's capture, a
default, `resize`, a constructor, a Cell and a Cell's type, `*` and `~`,
a place's and a List's type, an unprovided API, an error's field,
freezing, and crossing), phase 1's six "not built" cases rewritten as
`test`s, `ownership-apis` (a loan to the drop, a plain box's loan to
its last use, `Owned`, a loan ended with its box, `keeps` through a
call, H1, H2), `emit-apis` (the type, a move that allocates nothing,
a `<@` entry, the drop and clone entries, a task), `errors-apis` (a
task over a fallible call through an object), `test/cli/facts_sema.sh`
(box erasures), and `test/cli/leaks.sh` (boxes under
`RIG_LEAK_TRACE=1` and `RIG_SANITIZE=1`).

## Trig

Phase 3 only accepts more programs. Trig declares no API, and its
emitted Zig is byte-identical under main's compiler (53b34d260, phase
2 merged) and this one: the 12 of 15 programs with a `main` in its
`tools/` and `tests/` that build, as its packs build them (536 Zig
files, the runtime's apart, which gains `ApiBox` and the entries' helpers
no Trig program reaches; the other 3 are rejected by both alike), and
the 49 files of `src/` that emit alone.

## Not built (later phases)

Objects of an API with an associated type, `^{Source[Item: Int]}`
(phase 5, when a program needs it); the Lean lemma (phase 4); `*{A}`,
`~{A}`, a Cell of an object, and crossing tasks (Stage 5).
