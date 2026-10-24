# APIs Stage 5, phase 2: shared and weak API objects (2026-10-24)

Phase 2 of [build-plan.md](build-plan.md), built on phase 1
([phase1-notes.md](phase1-notes.md)), the approved CORE text (§4, "A
shared API object counts a value of hidden type, and an API object
crosses tasks only by a bound it names"; the panel's
[6-final.md](core-panel/6-final.md) with the reviewer's three fixes),
and the defaults of [open-questions.md](open-questions.md). A
`*{Shape}` counts a value of hidden type in the allocation the `*T` it
was made of holds; a `*{Shape + Syncs}` holds a frozen value's,
counted atomically; a `~{Shape}` is the weak handle of the first.

## What is built

| Piece | Where |
|---|---|
| `*{A}` and `~{A}` as types: `Type.shared` and `Type.weak` of an `api_object`, which stands behind a handle as behind a view (`sema.unsizedAt`); `ObjectForm` gains `.shared` and `.weak`, and `objectHeld` reads them, so every classifier that reads an object's form (`objectMeets`, `objectUnowned`, `lacks`, the printer of errors) has them | `src/sema.zig` |
| The braces of a handle: `Sends` in `*{...}` rejected toward `Syncs`, any crossing bound in `~{...}`, `Clone` in either (`+` counts), `Owned` beside `Syncs` (fix 3), and a `~{...}` whose API syncs | `resolve.resolveApiObject`, `handleBraces` |
| The holding from the braces, one classifier: `sema.frozenObject` (the braces or the API name `Syncs`), read by `atomicHandle` (so `blockerIn` crosses a `*{A + Syncs}` by its atomic count and holds a `*{A}` and a `~{A}` from every task, a local one included), `frozenIn` (a frozen value holds a `*{A + Syncs}`, fix 2), `reachOf` (a `*{A + Syncs}` holds no view), `objectMeets` (it meets `Owned`), the erasure, and the weak handle | `src/sema.zig` |
| The erasure of a counted handle, `eraseShared` beside `eraseBox`: a `*T` (or a `*T?`) into a `*{A}` (`*{A}?`), a frozen value's handle only into a `*{A + Syncs}`, each the move or new count it is (`<h`, `+h`, `*S(...)` and `*<x` made of their own type where one goes); an actor's, a channel's, and a Cell's handles, and another object, rejected; recorded as `Erasure{form = .shared, holding = .counted or .frozen}`, which `--facts=sema` prints | `typecheck.eraseShared`, `erasable` |
| No erasure through a view (A5): a `?h` or `!h` of a `*T` where a `?*{A}` or `!*{A}` goes is rejected toward `+h` | `typecheck.handleThroughView` |
| A box's value is never shared: `*<b` of a `^{A}` names the fix | `typecheck.synthShare` |
| Calls: `?@` only; a `!@` or `<@` method through a `*{A}`, or a view of one, is rejected with the fix; `?s` lends the `?{A}` the handle holds by the `*T` row of the lend table, which already reached it | `typecheck.objectCall`, `sema.lendRows` |
| Counts: `+s` and `+w` as any handle's; `~s` makes a `~{A}` (rejected of a `*{A + Syncs}`); `*w` gives a `*{A}?` | the existing handle paths (`synthClone`, `synthWeak`, `weakUpgrade`) |
| Crossing: a `*{A + Syncs}` to any task, a channel, an actor's state; a `*{A}` and a `~{A}` to none, each naming why | `sema.blockerIn` (unchanged but for `atomicHandle`), `typecheck.objectLack` |
| Loans: a `*{A}` and a `~{A}` carry their value's loans to the last count's drop, as the hidden type may have a `drop` body; `+ Owned` and `*{A + Syncs}` none | the existing classifiers, by the type's reach |
| `rig.ApiShared(table, braces)` and `rig.ApiWeak(table, braces)`: `{ptr, vt}`, sixteen bytes, `ptr` the value's address inside its counted allocation; `of` takes the handle, allocating and counting nothing; `read` lends the `ApiView`; `cloneStrong`, `dropStrong`, `weakRef`, `cloneWeak`, `dropWeak`, and `upgrade` go through the table, with the names a `*T`'s and a `~T`'s have, so emit writes counts and drops as it writes a handle's; `ApiShared` queues no drop, the allocation's `dropStrong` does | `src/runtime.zig` |
| Tables: `__rig_table_Shape_of(T, W, holding)`, `rig.ApiHolding` (`.box`, which views share, `.counted`, `.frozen`); `__rig_drop` and `__rig_clone` per holding (`dropStrong` and `cloneStrong` of the `Counted(T, atomic)` around the value, reached by `@fieldParentPtr`); `__rig_weak`, `__rig_weak_drop`, and `__rig_upgrade`, the plain holding's alone (unreachable in the others): three words more per table | `Emitter.emitApiTable`, `runtime.dropErased`, `cloneErased`, `weakErased`, `weakDropErased`, `upgradeErased` |
| Printing: through the table where the braces or API name `Print`; a weak handle prints `~(alive)` or `~(gone)`, as a `~T` does; `$name` spells `*{Shape}` and `~{Shape + Print}` | `ApiShared.__rig_print`, `ApiWeak.__rig_print`, `__rig_api_object` |
| A Cell of an API object rejected for good (open question 17), no longer as not built | `sema.object_cell` |
| A table's slot of a handle: `*{Shape + Owned}?`, and `*{Shape + Syncs}?` as it is | `resolve.tableElementError` |
| The oracle: `*{A}` an owner carrying every loan its value may hold, its drop reading them, none with `Owned` or `Syncs`; `~{A}` carrying the same loans and dropping no value; `*{A + Syncs}` crossing both ways, `*{A}` and `~{A}` neither (rule T1 reads it) | `test/oracle/kinds.zig` |

## Decisions beyond the design

1. **A shared object changes through a `*Cell` its value holds.** The
   design says a type holding a Cell changes "through its `?@`
   methods ... as through a `*T`". Through a `*T`, a type holding a
   Cell by value changes by its `!@` methods (`sema.changesByMark`),
   and no `?@` method can lend a Cell field to write. A `*{A}` reaches
   `?@` methods only, as designed, since whether the hidden type holds
   a Cell is erased; so the value changes through a `*Cell` field that
   a `?@` method counts and changes, `c = +@hits; !c.set(...)`. The
   case "changed through a Cell its value holds" does so; apis.md says
   so.
2. **The Cell of an object's message.** Open question 17 rejects it
   "by the Cell's own rule (`Copy + Owned`)", but a Cell holds any
   value but a view (`*Cell[List[Int]]` is accepted), so no rule of
   the Cell's own rejects an object. It is rejected by the object rule
   that was there, worded as final: "a Cell holds no API object:
   `Cell[^{Shape}]`; a shared object changes through a `Cell` its value
   holds".
3. **Views share the box's table.** `ApiHolding` has three values, not
   one per form: a view's conversion names `.box`, whose drop and
   clone entries no view reaches, so a value viewed and boxed makes one
   table.
4. **The weak entries are three, not four.** `+w` and `~s` both add a
   weak count (`__rig_weak`, without the strong count's assertion, as
   `Weak.cloneWeak` does); a weak handle's print upgrades and gives the
   count back, never the last, rather than reading the count through a
   fourth entry.
5. **The message for `*<b`** ends "`*<x` where a `*{Shape}` goes", not
   the plan's `*<sq`, a name from the example.
6. **`api Shape: Syncs`'s errors name the API:** "`*Sq` is erased to
   `*{Shape2}`, which several tasks read (`Shape2` builds on `Syncs`),
   but its count is not atomic", and "`~{Shape}` would be a weak handle
   of a frozen value: `Shape` builds on `Syncs`, so every `*{Shape}`
   holds one".
7. **The erasure records the value's type** as `from` (`Square`, not
   `*Square`), as a box's does, since the table and the witness are the
   value's; the holding is printed after it (`... counted`).
8. **The cases live in `test/rig/types-apis-shared.rig.test`,** beside
   phase 1's file.

## Cases

`test/rig/types-apis-shared.rig.test`, 46 cases, under the suite's
`RIG_SANITIZE=1`, the task ones under `seeds: 20`: CORE's weak-handle
example and its two-task frozen example (now ordinary in CORE, with the
non-atomic `*{Shape + Syncs}` as `rig reject`), a handle moved and
counted into one, one made where it goes, counts through the table, a
List of two types with a shared element, a value changed through its
`*Cell`, a chain of 100,000 links with weak handles dropped without
deep recursion, a frozen plugin registry read by two tasks (fix 2),
printing, `?s` lent on, `!s` lent to write, optionals, a field and a
`drop` body at the last count, the API's `Syncs`, generic erasures by
their bounds, weak handles counted, a call by the API's name, `$name`,
a channel of frozen objects, an actor's state, a value erased at a task's call; and the rejections: a
count that is not atomic (CORE's), a generic one (A2), a frozen
value's handle into a `*{A}` (A1), `Sends`, `Clone`, `Owned` with
`Syncs` (fix 3), crossing bounds in `~{...}`, a weak handle of an API
that syncs, `~` of a frozen object, `!@` and `<@` calls, `*<b`, forms
becoming one another, views of handles (A5), an actor's and a
channel's handles, holding sigils, a `*{A}` and a `~{A}` given to a
task, a hidden task, `Print`, a table's slot, an actor's state, a
frozen value holding a plain one, and a Cell. Each `fail` and `test`
was seen failing under phase 1's compiler (39 of the first 40 rejected
as not built; the holding sigil `*^{Shape}` already had its message).
Also: `ownership-apis` (a loan across `+s` to the last count, to the
drop past the last use, through a weak handle (A4), none with `Owned`
or `Syncs`, ended with the last count, an owned closure's capture),
`emit-apis` (the types, a move that allocates and counts nothing, the
frozen table, counts, lends, and calls, the count entries), phase 1's
and Stage 4's "not built" cases of `*{...}`, `~{...}`, and a Cell
rewritten, `test/cli/facts_sema.sh` (both holdings), and
`test/cli/leaks.sh` (shared and weak objects traced, and a frozen one
whose last count is given back on a worker, under 20 seeds).

The oracle decides more with them: its floors rise to tests 22673 and
docs 1069, and it rejects the three loan cases the compiler does
(`test/oracle/rejections`).

## Speed

`bench/apis/shared.rig` against `handle.rig`: a count of a `*{Shape}`
taken and given back costs 2.9 ns on the Mac and 1.9 ns on pup,
against 0.6 ns and 0.3 ns inline for a `*Square`, within the plan's
5 ns (bench/apis/README.md).

## Found while building

- The oracle rejects `s = task.isolate(|| mk())!` where `mk` gives a
  `^{Shape}` (a loan of the temporary closure outliving its
  statement), which the compiler accepts; it does the same for
  `*{Shape}`. No case in the suite has it; it predates this phase.

## Not built (later phases)

The Lean obligation (phase 3); owned closures as objects of one method
(phase 4, its own performance PR).
