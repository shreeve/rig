# APIs Stage 5: the build plan (2026-10-23)

How to build Stage 5 of [docs/design/apis.md](../../../../design/apis.md),
"shared objects, and crossing tasks" (`*{Shape}`, `~{Shape}`,
`^{Job + Sends}`, `?{Job + Syncs}`, and owned closures lowered as
objects of one method), once Stage 4's boxes have landed. The design is
that page's Stage 5 section; its open points, each with a default, are
[open-questions.md](open-questions.md); the Core text it needs first,
drafted in [core-draft.md](core-draft.md), was revised by a panel
([core-panel/](core-panel/)) and approved by the owner on 2026-10-23,
with the design's defaults and the reviewer's three fixes: "Build Stage
5 in phases with adversarial reviews; land each after the suite and
light gate." It is in CORE §4 as *(planned)*. The compiler
implementer's sizes, from main at 86bca420b, are used below. Line references are of `main` at
53b34d260 (Stage 4's phase 2) and of PR #614 (Stage 4's phase 3, boxes,
under review).

## What Stage 5 reuses from Stage 4

| Stage 4 piece | Where | What Stage 5 does with it |
|---|---|---|
| `Type.api_object` with its `builtins: Apis`, under `read_view`, `write_view`, and `Box` | `src/sema.zig` | the same type under `shared` and `weak`; `builtins` gains `Sends` and `Syncs` |
| The braces' rules (`resolve.TypeResolver`): one API of a program's own; `Owned`, `Print`, `Clone` beside it; `Sends`, `Syncs` rejected as "Stage 5" | `src/resolve.zig` | the two accepted where the form can use them, rejected toward the other where it cannot (open question 4) |
| The erasure, `typecheck.erase` and `eraseBox` (#614), sharing `erasable`; `sema.Erasure {api, from, view, witness, form, optional, copy}` | `src/typecheck.zig`, `src/sema.zig` | a third path, `eraseShared`; `Erasure.form` gains `.shared` and `holding` (`.box`, `.counted`, `.frozen`); `erasable` checks the crossing bounds |
| The built-in bounds checked at the erasure (`Owned` naming the field that holds a view) | `typecheck.erasable` | `Sends` and `Syncs` checked the same way, by `sema.crossingBlocker` (9465), naming the part |
| `blockerIn`'s `.api_object` case: a blocker everywhere but a local task (#614) | `sema.zig` 9582 in #614 | by the braces and the API: null where the form's row says it crosses, a blocker otherwise, a local task included (open question 13) |
| `sema.atomicHandle` (9212), the one predicate of an atomic count | `sema.zig` | decides what a `*{A + Syncs}` may take |
| Tables: `__rig_table_Shape` and `__rig_table_Shape_of(T, W)`, with `__rig_drop`, `__rig_clone`, `__rig_print`, and `<@` entries (#614) | `Emitter.emitApiTable`, `runtime.zig` | a third parameter, the holding; share and weak entries; the drop entry by holding |
| `rig.ApiView`, `rig.ApiBox` (#614): `{ptr, vt}`, `ptr` the value's address | `src/runtime.zig` | `rig.ApiShared` and `rig.ApiWeak` of the same shape; `Counted(T, atomic)` (1402) and `Weak(T)` give the entries |
| `Dispatch.dynamic`, `objectCall`, `checkReceiverMode` | `typecheck.zig` | a call through a `*{A}` reaches `?@` methods only, as through a `*T` |
| The oracle's `objectInfo` and `Reach.anything`, an erasure lowered as the lend or move it is | `test/oracle/kinds.zig`, `lower.zig` | `*{A}` and `~{A}` kinds; a `*T`'s erasure as a move or a new count; crossing facts of objects |
| `rig.Closure` behind `Shared`, `FnRef.ofClosure` | `runtime.zig` 1894 | phase 4 lowers it as a one-method `ApiShared` |

## The pieces, and the pass that owns each

| Piece | Pass |
|---|---|
| `*{A}` and `~{A}` in a type: the grammar already parses a holding sigil over `tatom`; `Type.shared` and `Type.weak` of an `api_object`, unsized beneath them as under a view or a box; printed `*{Shape + Syncs}` | `rig.grammar` (no change expected), `src/sema.zig`, the printer |
| The braces: `Sends` and `Syncs` by form (open question 4), `Clone` rejected in `*{...}`, any crossing bound rejected in `~{...}`; a holding sigil over a held object (`*^{A}`) rejected as for any held value | `resolve.TypeResolver` |
| An object's crossing facts: the bounds its braces name and its API builds on (`sema.objectBounds`, one classifier, read by resolve, `blockerIn`, `erasable`, `objectMeets`, the printer of errors, and the oracle's mirror); `blockerIn`'s `.api_object` null when the bound for `how` is there; `.shared(object)` decided before `atomicHandle`, and `.weak(object)` always a blocker; `lacks` routed through `blockerOf`, so `[T: Sends]` takes a `^{Job + Sends}` | `src/sema.zig` |
| The erasure of a shared handle, `eraseShared` beside `eraseBox`: `<h` and `+h` of a `*T`, `*S(...)` and `*<x` written where a `*{A}` goes; a `*Frozen[T]` only where a `*{A + Syncs}` goes; nothing under a view; rejected for an actor, a channel, a Cell, and `*<b` of a `^{A}`; the holding read from the braces and recorded as `Erasure.holding`; `--facts=sema` prints it | `typecheck.eraseShared`, `erasable` |
| The crossing check at every erasure: `crossingBlocker(from, .moves or .shares)` for `Sends` and `Syncs`; for `*{A + Syncs}`, `atomicHandle` of the handle too; a bounded `T` by its bounds | `typecheck.erasable` |
| No object, and no owned closure, hides a task or a set of tasks (open question 14): one walk, `sema.holdsTask`, at every erasure, now walking a closure's captures and a type parameter by its instance (`Requirement.no_task`, about 60 lines) | `typecheck.erasable`, `sema` |
| Calls through `*{A}`: `?@` only, `!@` and `<@` rejected with the fix; `?s` lends `?{A}` by the `*T` row (`LendStep.handle`), `!s` lends the handle | `typecheck.objectCall`, `sema.lendRows` |
| Counts: `+s`, `<s`, the drop, `~s`, `*w`, `+w`; `~` of a `*{A + Syncs}` rejected | typecheck (where `+h`, `~h`, `*w` are typed today), `ownership.zig` |
| Loans: a `*{A}` carries its value's loans, as a `*T` does, to the drop of every handle that carries them; `+ Owned` none; the oracle the same | `src/ownership.zig`, `test/oracle/` |
| Tables: `__rig_table_Shape_of(T, W, holding)`; `__rig_drop` and `__rig_clone` per holding (`+s` is `cloneStrong`); `__rig_weak`, `__rig_weak_drop`, and `__rig_upgrade` for the plain holding only, by `@fieldParentPtr`; 3 words per table, and a `*{A}` is 16 bytes | `Emitter.emitApiTable`, `src/runtime.zig` |
| `rig.ApiShared`, `rig.ApiWeak`: `read()` lends the `ApiView`; `ApiShared` queues no drop itself, `dropStrong` does; `typeName` spells `*{Shape}` | `src/runtime.zig` |
| Local tasks and isolate: no special case; they read `blockerIn` and `holdsTask` | `src/tasks.zig`, `typecheck` task check |
| Owned closures as objects of one method (phase 4): `*fun` as `rig.ApiShared(ClosureTable(params, R), "")`, one `Counted(Env)` allocation; `~fun` as `rig.ApiWeak`; `FnRef.ofClosure`, Signal callbacks, and every `*fun` site in the runtime | `src/runtime.zig`, `src/emit.zig` |
| Lean: crossing obligations over `formal/LambdaRig/Tasks.lean` | `formal/` |

## Phase 0: the Core (docs only, owner) *(approved 2026-10-23)*

Stage 5 adds a handle, a weak handle, and crossing rules, so CORE
changes first, through the Core change process: a panel of four (a
Core purist, a compiler implementer, an adversary, and a reviewer)
revised [core-draft.md](core-draft.md), and the owner approved the
final text ([core-panel/6-final.md](core-panel/6-final.md)) with open
questions 13 and 14. It widens §1's handle row, the `*T` row of §4's
lend table, sentences 8 and 9 by a clause each, and Stage 4's list's
last line, and adds one paragraph and a list of five after Stage 4's,
with five `rig pending` examples; SPEC §18's crossing table gains the
objects' rows, marked planned.

## Phases

Each phase is one PR, opened as a draft with a checklist, through Rig's
full suite and Trig's light gate, with an adversarial review before it
lands. Phases 1 and 2 only accept more programs, but for the two
narrowings (open questions 13 and 14), which reject programs Stage 4's
phase 3 accepts: neither Trig nor the suite has one (Trig declares no
API), so Trig's emitted Zig stays byte-identical through phase 3. Phase
4 changes the Zig of every owned closure, Trig's included. Until a
phase builds a form, the form is a Rig error naming the stage.

### Phase 1: crossing bounds in the braces (about 1,000 lines, 40 cases)

`Sends` and `Syncs` in `?{...}`, `!{...}`, and `^{...}`; an API's
crossing bounds; the check at the erasure; `blockerIn` by the form's
row; tasks, channels, actors, `par`, and isolate over objects; the two
narrowings, with `holdsTask` walking a closure's captures and a type
parameter's instance (`Requirement.no_task`). `*{...}` stays "not built
yet (docs/design/apis.md, Stage 5)".

Cases (`test/rig/types-apis.rig.test`, "apis object crossing ..."):

- `test`s: a `^{Job + Sends}` given to a task, `work(<j)&`; a
  `^{Shape + Syncs}` lent to two tasks, `total(?b)&`; a `?{Shape +
  Syncs}` lent to a task; a `!{Shape + Sends}` lent to one task to
  write; `^{Job}` of `api Job: Sends` given to a task; a
  `*Chan[^{Job}]` of `api Job: Sends + Owned` between a producer and a
  worker; an actor whose state holds `List[^{Job + Sends + Owned}]` and
  whose method takes one; `par.map` over a `List[^{Shape + Syncs}]`,
  `par.each` over a `List[^{Shape + Sends}]`; a generic `[T: Shape +
  Sends]` erasing to `^{Shape + Sends}`; `task.isolate` giving a
  `^{Shape}`; every one under `RIG_SANITIZE=1`, and the channel one
  with `--seeds=20`;
- `fail`s, with these texts:
  - `` `Note` is erased to `^{Job + Sends}`, which goes to other tasks, but its field `cache` is a `*Map[String, Int]`, whose count is not atomic ``;
  - `` `Grid` is erased to `?{Shape + Syncs}`, which several tasks read, but its field `hits` is a `Cell[Int]` ``;
  - `` `<j` is given to a task, and `^{Job}` hides its value's type without naming `Sends`: write `^{Job + Sends}` ``, and the siblings for a read lend (`Syncs`) and a write lend (`Sends`);
  - the same for a local task (`` ... a local task too: what it hides may stay on no task ``, open question 13);
  - `` a read view goes to another task when its value syncs: write `?{Shape + Syncs}` ``;
  - `` a write view is never read by two tasks at once: write `!{Shape + Sends}` for one that goes to another task ``;
  - `` `T` is erased to `^{Shape + Sends}`, but `T` is not bounded by `Sends`: write `[T: Shape + Sends]` ``;
  - a channel of `^{Job + Sends}` (`` a channel's element holds no loan, and `^{Job + Sends}` may hold one: write `^{Job + Sends + Owned}` ``), and an actor's state the same;
  - `` `Runner` is erased to `^{Shape}`, but its field `t` is a `Task[Int]`, and an API object never hides a task: wait for it first, or keep it beside the object `` (and a `Tasks[Int]` field; open question 14), and the same for an owned closure capturing a task (`*|<t| 7` in an object, out of `task.isolate`) and a `[T: Shape]` erasing a `^T` whose `T` holds one;
  - `*Frozen(<b)` of a `^{Shape + Syncs}` keeps phase 3's message (a value that syncs may hold a one-word `*Cell`);
- `test/cli/facts_sema.sh`: the braces' bounds on an erasure line;
  `rig check --tasks` prints nothing for a task over a `^{Job + Sends}`.

Oracle: crossing facts of objects, computed in `kinds.zig` from the
braces and the API (never from the compiler's facts): an object's
`sends` and `syncs` by its form's row. The oracle decides crossing only
for objects; elsewhere it abstains, as today. Floors in
`test/oracle/coverage` go up, never down.

Docs: SPEC "API objects" gains crossing, and §18's object rows for
views and boxes lose their planned mark; apis.md's Stage 5 *(in part)*; CORE's phase 0 paragraph to
*(built)* for crossing.

### Phase 2: `*{A}` and `~{A}` (about 1,400 lines, 50 cases)

The shared and weak forms: the erasure of a `*T` into a `*{A}` and of a
`*Frozen[T]` into a `*{A + Syncs}`, the count entries, `rig.ApiShared` and `rig.ApiWeak`, calls, lends, counts,
weak handles, `*{A + Syncs}` crossing, loans, and the oracle's kinds.

Cases:

- `types-apis` `test`s: CORE's example (`*{Shape}` from `*Square(...)`,
  `+s`, `~s`, `*w` before and after the last drop, printing `4.0` and
  `gone`); `<h` of a `*Square` keeping its allocation (an `emit-apis`
  `code` case that it allocates nothing); `+h`; `*<sq`; a
  `List[*{Shape}]` of two types with a shared element; a `*{Tick}` of a
  type holding a `Cell[Int]`, changed by a `?@` method; a tree of
  100,000 `*{Node}` children with `~{Node}` parents dropped without deep
  recursion; `*{Shape + Syncs}` of a `*Frozen[Square]` read by two tasks
  (CORE's second example); a shared plugin registry,
  `*Frozen(List[*{Plugin + Syncs}])`, read by two tasks; `*w` of a
  `~{Shape}` keeping its `*{Shape}`'s loans; `print(s)` with `+ Print`;
  `?s` lent to a `?{Shape}` parameter;
- `fail`s:
  - `` `*Square` is erased to `*{Shape + Syncs}`, which several tasks read, but its count is not atomic: freeze the value, `*Frozen(...)` ``;
  - `` a shared handle goes to another task when several tasks may read its value: write `*{Shape + Syncs}` ``;
  - `` `*{Shape}` only reads, as any handle: `grow` takes `!@`; hold a `^{Shape}`, or change the value through a `Cell` it holds ``, and `<@` the same;
  - `` `*<b` would move a value whose type is erased: share the value before erasing it, `*<sq` where a `*{Shape}` goes ``;
  - `` a `*{Shape}` is counted, so `+s` never clones its value: take `Clone` out of the braces ``;
  - `` `~f` of a `*{Shape + Syncs}`: a frozen value has no weak handle ``;
  - `` a frozen value's handle is erased only to `*{Shape + Syncs}`, which counts atomically: write `*{Shape + Syncs}` ``, and the same for a generic `*T` whose `T` syncs;
  - `` `*{Shape + Syncs}` holds a frozen value, which holds no view: take `Owned` out of the braces ``;
  - `!sq` lent as a `!*{Shape}`, and `?sq` as a `?*{Shape}`: a handle is erased only as it moves or counts;
  - `` a weak handle never crosses: take `Syncs` out of `~{Shape + Syncs}` ``;
  - an actor's handle and a channel's erased to `*{Shape}` (`` `*Actor[Counter]` is an actor's handle, whose methods are messages, so it is no `*{Shape}` ``);
  - `*^{Shape}` and `^*{Shape}` (the existing message for a holding sigil over a held value);
  - a `*{Shape}` given to a task (`` `*{Shape}` stays with its task, as a `*T` does: its braces name no `Syncs` ``);
- `ownership-apis`: a `*{Shape}` of a value holding `?t` keeps `t` lent
  until the last count is dropped, across `+s`; `+ Owned` frees `t`
  after the last use; a `*{Shape + Syncs}` carries no loan;
- `emit-apis`: `rig.ApiShared(__rig_table_Shape, "")`, the conversion's
  `.vt = __rig_table_Shape_of(Square, __rig_impl_Shape_Square,
  .counted)`, `s.vt.__rig_share(s.ptr)`, the `.frozen` table's atomic
  entries;
- `test/cli/leaks.sh`: shared objects and weak ones under
  `RIG_LEAK_TRACE=1` and `RIG_SANITIZE=1`, and a frozen one freed on
  another worker (`--seeds=20`);
- `test/cli/facts_sema.sh`: `erasures ... "h" *Square *{Shape} ... counted`.

Oracle: `*{A}` and `~{A}` kinds from the type (a handle carrying every
loan its value may hold, to the drop of its last count; `~{A}` the
same); a `*T`'s erasure as a move or a new count keeping its loans.

Speed: `bench/apis` gains `+s` and a drop of a `*{Shape}` against a
`*Square`'s, fastest of 5, interleaved, on both machines; the count
through the table within 5 ns of the inline one. A program with no
`*{...}` emits the same Zig.

Docs: SPEC's shared and weak objects; SYNTAX's types; QUICK; STD (none
expected); CORE to *(built)*; apis.md *(built)* but phase 4;
docs/learn/07; CHANGELOG; HANDOFF.

### Phase 3: the proof (about 300 lines of Lean)

`formal/LambdaRig/Tasks.lean` models which values stay on one thread
(`holds`) and proves `confined`: two tasks that hold such a value are
pinned to one core. Stage 5's obligation, stated there: an object is a
value whose `holds` is its hidden value's; an erasure whose crossing
bound was checked (`crossingBlocker` found nothing) gives an object
that holds none, so `spawnFree` may take it; and an object whose braces
name no bound is taken by no spawn (open question 13). Lemma
`erase_confined`: erasing keeps `holds`, so `confined` and `pin_kept`
hold of every state as before. It gates nothing, and may land beside
phase 2.

### Phase 4: owned closures as objects of one method (about 900 lines, 25 cases; its own performance PR, kept only if measured faster)

`*fun(A) -> R` and `*sub(A)` lowered as `rig.ApiShared` of a table of
one method per closure literal: one `Counted(Env)` allocation instead
of the environment's and the `Closure`'s; `~fun` as `rig.ApiWeak`;
every runtime site that takes a `*Shared(Closure)` (`FnRef.ofClosure`,
`Signal`'s `Callback`, and every other use of `rig.Closure`).
No checker change: phase 4 changes only lowering. Sema keeps
`.shared(.function)`, so the facts and rules of owned closures stay as
they are, crossing included (never), and a `*fun` is never a `*{A}`
(the adversary's A7). It is a performance change, not a language one,
so it lands as its own PR, judged by its bench alone.

Cases: every existing owned-closure case passes unchanged (the suite
is the test); `emit-apis` `code` cases for the new conversion and call;
`test/cli/leaks.sh` for closures under `RIG_LEAK_TRACE=1`.

Speed, the gate: `bench/closures`, a closure made, called once, and
dropped per element over 20 million elements, against main, fastest
of 5, interleaved, on both machines. Today on the Mac: 11.1 ns per
closure, against 4.6 ns for a one-allocation `*` object; the estimate
is 5 to 6 ns, about 45% faster. Kept only if it is more than 2% faster
on both machines, calls are not slower (`bench/apis`'s `?fun` row), and
Trig's light gate and timing are not slower. Trig's emitted Zig changes
(its 10 owned closures), so Trig gets a one-line note first.

### With Stage 4's phase 5: associated types

`*{Source[Item: Int]}` and `^{Source[Item: Int] + Sends}` come with
Stage 4's phase 5, when a program needs it: about 100 lines on top of
it, the crossing bound after the named type.

## Risks, and the North Star checks

- **Accept means correct.** Each phase accepts only forms it lowers;
  `*{...}` stays a Rig error until phase 2. A table's entry types come
  from the API and the holding alone, so every type erased to one fits;
  a `code` case per holding.
- **Safe code cannot corrupt memory.** The holes this design closes,
  each with a case: an object hiding an owned closure reaching two
  local tasks (open question 13), an object or an owned closure hiding
  a task leaving `task.isolate` (14), a non-atomic count reaching
  another core through `*{A + Syncs}` (6), a weak handle of a frozen
  value, through `~` of a `*{A + Syncs}` or of a `*{A}` hiding a frozen
  allocation (7, 10), and a handle erased through a view (8). Counts reached from the value's address by the
  allocation's layout: a `code` case per holding, and a sanitizer case
  of a frozen object freed on another worker. Every `test` runs under
  `RIG_SANITIZE=1`. Two rounds of soundness fixes in one phase stop the
  feature for redesign (CORE §10).
- **Effects stay visible.** No sigil marks an erasure; the braces of the
  expected type do. `+s` is written, and its cost (an indirect call) is
  that of a form with braces, which mark the cost. A crossing bound is
  a check and emits nothing.
- **One classifier per fact.** "Does this cross": `crossingBlocker` and
  `blockerIn`, objects included. "Is this count atomic": `atomicHandle`.
  "Which bounds does an object meet": `objectBounds`, braces and API
  together. "Does a value hold a task": `holdsTask`. Each merge adds the
  case two paths would have split on.
- **Emit decides nothing.** The erasure with its holding, the dispatch,
  and the methods are facts; emit never asks whether a count is atomic.
- **The oracle.** Never weakened; crossing facts of objects computed
  from the type in `kinds.zig`; differences recorded in
  `test/oracle/differences`.
- **Speed.** A program with no `*{...}` and no crossing bound emits the
  same Zig through phase 3: compare std.json's and Trig's emitted Zig
  before and after each phase; the speed census after merges; bisect
  any change over 2% before more lands. Phase 4 is gated by its bench.
- **Nexus and editors.** No grammar change is expected (a holding sigil
  over `tatom` parses today). If one is needed, Nexus's refresh copies
  Rig's main, and the editor-support session updates the grammars.
- **Trig.** Phases 1 to 3 leave its emitted Zig byte-identical; phase 4
  changes it, after a one-line note (warn Trig before breaking).

## Docs, by phase

- Phase 0: CORE §1, §4, sentences 8 and 9, and the paragraph, as
  `rig pending`; SPEC §18's object rows, marked planned.
- Phase 1: SPEC's crossing of objects, and §18's rows built; apis.md *(in part)*.
- Phase 2: SPEC's shared and weak objects; SYNTAX; QUICK; CORE built;
  docs/learn/07; CHANGELOG; HANDOFF.
- Phase 3: formal/README.md's list of what is proved.
- Phase 4: INTERNALS' owned closures; CHANGELOG.

## Size

About 3,300 lines of compiler, tests, and docs across three compiler
PRs (phases 1, 2, and 4, the last its own performance PR, kept only if
faster), about 80 lines
of CORE before them, and 300 of Lean. Phase 2 is the bulk and the risk
(counts through a table, weak handles of erased values); phase 1 is
mostly checks and messages over classifiers that exist.
