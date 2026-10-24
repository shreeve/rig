# APIs Stage 5, phase 1: crossing bounds in the braces (2026-10-24)

Phase 1 of [build-plan.md](build-plan.md), built on the approved CORE
text (§4, "A shared API object counts a value of hidden type, and an
API object crosses tasks only by a bound it names"; the panel's
[6-final.md](core-panel/6-final.md) with the reviewer's three fixes)
and the defaults of [open-questions.md](open-questions.md). An API
object crosses tasks by `Sends` or `Syncs` in its braces or its API,
checked on the hidden value where its type is erased; each form then
crosses by its row of SPEC §18's table. It is stacked on #616 (a
generic instance gives no task what goes to none), whose `lacks`
through the crossing walk and `Requirement.no_task` it uses.

## What is built

| Piece | Where |
|---|---|
| `Sends` and `Syncs` in the braces where the form uses them: `^{A}` both, `?{A}` `Syncs`, `!{A}` `Sends`; the other rejected toward the one it can (`a read view goes to another task when its value syncs: write ?{Shape + Syncs}`); named twice reported; `*{...}` and `~{...}` still "not built yet" whole | `resolve.resolveApiObject` |
| `sema.objectBounds`, the one classifier of an object's bounds (its braces and every built-in API its API builds on), read by `blockerIn`, `objectMeets`, `objectUnowned`, the reach facts (`Owned`), and the erasure | `src/sema.zig` |
| `blockerIn`'s `.api_object`: no blocker when the bound for `how` is named (`crossingBound`: `Sends` to move, `Syncs` to share), a blocker otherwise, a local task included; the form's row is the wrappers' (a read view reaches it to share, a write view and a box as they go) | `sema.blockerIn` |
| One spelling per view: a view's braces name only the bound its form uses (`formBraces`), applied where the view's type is interned, so `?b` of a `^{A + Sends}` is a `?{A}`; the lend table matches a box's or a write view's object by it (`objectViewOf`); the runtime's `ApiView` drops the same bound from its braces string, so both spell one Zig type | `SemContext.intern`, `lendRows`, `runtime.ApiView` |
| The erasure checks every bound of `objectBounds` on the hidden value: `Owned`, `Print`, `Clone` as before (now the API's too), and `Sends` and `Syncs` by the crossing walk, the error naming the field and why, or the bound a `T` lacks (`write [T: Shape + Sends]`) | `typecheck.erasable`, `crossingLack` |
| A task, an actor's argument: an object without its bound names the bound to write (`` `<j` is given to a task, and `^{Job}` hides its value's type without naming `Sends`: write `^{Job + Sends}` ``), with "a local task too" where another part pins the task; an object deeper in a part says it names no bound for this | `typecheck.crossCheck`, `objectLack`, `crossingReason` |
| A channel of boxes that may hold a loan names the fix, `^{Job + Owned + Sends}` | `typecheck.chanMake` |
| A call through an object as a task: `rig.Task(T).spawnObject(obj, "m", args)` (`spawnObjectLocal` for a local one) runs the table's entry on another core, given the object's two words | `src/tasks.zig`, `Emitter.emitTask` |
| The reviewer's fix 1: an owned closure captures no task or set of tasks, nor a value holding one (`an owned closure holds no task: ...`), so `holdsTask` of a `*fun` is false truthfully, and no task leaves `task.isolate` in one or hides in an object | `typecheck.ownedClosure` |
| The oracle: an object's names from its braces and its API's declarations (`kinds.objectNames`), its crossing by its form's row (`objectCrosses`), and a walk to the first object a task part holds that does not cross as passed (`objectBlocker`); rule T1 rejects a task given or lent one, before abstaining on the task as before. A box of an API's `Owned` holds no loan, as the compiler now says | `test/oracle/kinds.zig`, `lower.zig`, `core.zig` |

## Decisions beyond the design

1. **A view's braces are canonical.** Open question 4 rejects writing
   `?{A + Sends}`, and Stage 4's question 10 lends no object of other
   braces, so a box `^{Job + Sends}` would have lent a `?{Job + Sends}`
   no parameter could name. The view's type drops the bound its form
   cannot use, one spelling per meaning, in sema (at intern) and in the
   runtime's `ApiView`.
2. **The API's `Owned` counts** as the braces' does (default 15's
   `*Chan[^{Job}]` of `api Job: Sends + Owned`): Stage 4 counted only
   the braces' `Owned`, though `Print` and `Clone` came from the API.
3. **Every bound the API names is checked at the erasure,** not only
   the braces'. Stage 3 checks them of each type that provides the API,
   but a generic type provides it wherever an instance is formed:
   `^Wrap[*Int](...)` into a `^{Job}` of `api Job: Sends` would have
   sent a `*Int`, and `^Wrap[Tok](...)` into a `^{Shape}` of `api Shape:
   Clone`, with `Tok` unique, was accepted on main and cloned a unique
   value through the table (`+w`). Both are now rejected at the erasure.
4. **The local-task message** reads "... write `^{Shape + Syncs}` (a
   local task too: what it hides may go to no task)".
5. **The cases live in `test/rig/types-apis-crossing.rig.test`,** a file
   of their own, not `types-apis`.
6. **The oracle decides crossing only at a task's call** (`f(x)&`), and
   only for objects; channels, actors, and `par` stay the compiler's.
   A function with a task's wait still abstains; T1 fires on the
   rejected cases' stated verdicts. The floors rise to what it decides
   with the new cases' other functions (tests 22594, docs 1062).

## Cases

`test/rig/types-apis-crossing.rig.test`, 33 cases, the `test`s under
`seeds: 20` and the suite's `RIG_SANITIZE=1`: a sending box given to a
task (CORE's example), a syncing box lent to two tasks, a syncing read
view lent on, a sending write view lent to write, the API's bound, calls
through an object as tasks (`?b.area()&`, `(<j).run()&` of a `<@`
method), a channel of boxes between a producer and a consumer, an
actor's state of boxes fed from tasks, `par.map` and `par.each` over
boxes, a generic erasure by its bound, `task.isolate` giving a box, a
field and an optional, and the braces' names and canonical views; and
the rejections: a box that does not send (a `*Map` field), a view that
does not sync (a `Cell[Int]` field), an owned closure hidden, a box
given without its bound (CORE's example), lends without the bound (four
forms), a local task, `?{A + Sends}`, `!{A + Syncs}`, a generic without
the bound, a channel's and an actor's loans, a channel and an actor
without `Sends`, freezing, a bound named twice, `*{...}` and `~{...}`,
an owned closure holding a task or a set of tasks, isolate giving one,
the generic types that provide an API only where their arguments
do, and a generic owned closure's instance at a task. Each was seen failing before the change (29 rejected as not built
or with Stage 4's message, two accepted, the holes; the isolate case
already passed). Also: `emit-apis` (the object task and the canonical
view type), `test/cli/facts_sema.sh` (a box erased with its bound),
`test/cli/check_tasks.sh` (no local task over a `^{Job + Sends}`), and
CORE's two Stage 5 examples phase 1 builds, now ordinary (`rig` and
`rig reject`); its other three stay pending for phase 2.

## Trig

Phase 1 only accepts more programs but for two rejections no Trig
program meets (an owned closure capturing a task; an object of a generic
type that meets its API's bounds only for some arguments). Trig's
emitted Zig is byte-identical under main's compiler (a4d1cf635) and this
one: of its 15 programs with a `main` in `tools/` and `tests/`, built as
its packs build them, 12 emit (the CLI, `tools/trig/main.rig`, among
them) and 3 are rejected alike; of the 304 files of `src/` emitted
alone, 49 emit and 255 are rejected alike; 428 Zig files compared, the
runtime apart.

## Not built (later phases)

`*{A}` and `~{A}` (phase 2), with `*{A + Syncs}` and the reviewer's fix
2 (a frozen value holding `*{A + Syncs}` handles) and fix 3 (`Owned`
rejected in `*{A + Syncs}`); the Lean obligation (phase 3); owned
closures as objects (phase 4).
