# APIs Stage 5, phase 1: adversarial review (2026-10-24)

A review of PR #620 ([phase1-notes.md](phase1-notes.md)) against the
approved CORE text (§4, "A shared API object counts a value of hidden
type, and an API object crosses tasks only by a bound it names"), SPEC
§18's rows, the panel's holes A1 to A7 and the reviewer's fixes
([core-panel/](core-panel/)), and the defaults of
[open-questions.md](open-questions.md). The branch was first rebased on
`main` after #616 landed, and the PR retargeted to `main`. About 175
probe programs, each checked, run with `RIG_SANITIZE=1` (the task probes
as `test` blocks under seeds 1 to 20), and given to the oracle
(`rig-oracle -v` where it decides). Each fix has its case; the full
suite is green.

## Findings, by severity

### High: a stated rule got past, with a use after free

1. **A generic body's erasure skipped each instance's bounds.** The
   erasure checks the bounds an object names on the hidden type
   (`sema.lacks`), and a type parameter its bounds do not decide lacks
   nothing there: it is "decided by each instance". But nothing
   recorded what each instance must meet, so `^Wrap[U](...)` erased in
   a generic body passed every bound, whatever `U` became:
   - `Owned`: `go[U](u: U) -> ^{Shape + Owned}` called with `?n` of a
     local `List` returned a box viewing the freed List; printing it
     gave `Wrap(u: [])` for `[1, 2, 3]`. The API's `Owned` the same
     (decision 2).
   - `Sends` and `Syncs`: `j: ^{Job + Sends} = ^Wrap[U](u: <u)` with
     `U = *Int` sent a count that is not atomic to another core, where
     `^Wrap[*Int](...)` written out is rejected (decision 3's own
     case, one generic body away); also through a `List[U]` field, a
     `?U` field, a view erased to `?{Shape + Syncs}`, a write view to
     `!{Shape + Sends}`, nested generics, and a generic type's method.
   - `Clone`: `+b` cloned a unique `Tok` through the table.
   - `Print`, and every other bound an API builds on: `api Shape: Eq`
     with a default `@ == @` reached Zig for `U = *fun() -> Int`
     (`rig.eql: no == on ...`).

   *Fixed:* the erasure records, for each type parameter the value
   holds that its bounds do not decide, what each instance must meet:
   the crossing bounds as the task walk's `Requirement.task` (the one
   crossing classifier, at the form's row), and every other bound as a
   new `Requirement.meets`, decided by `sema.lacks` as the known type's
   erasure is. The error names the instance, the object, and the bound:
   "`go[?List[Int]]` cannot use `U = ?List[Int]`: the generic body
   erases a value that holds a `U` to `^{Shape}`, whose braces or API
   name `Owned`, and `?List[Int]` is not `Owned`". Cases "apis object
   crossing a generic body erases its parameter's instance without the
   bound", "... without the other bounds", and "... without the API's
   Eq". The braces' `Owned`, `Print`, and `Clone` had the same gap in
   Stage 4; it is one class, closed together.

### Medium: accepted, then failed in Zig

2. **`par.map` over read views of objects.** `par.map(?xs, |s|
   s.area())` with `xs: List[?{Shape + Syncs}]`, which phase 1 lets
   cross, failed in Zig: sema lends any read view by value
   (`copiedByReadView`), but the runtime's twin rule did not know
   `rig.ApiView`, so `rig.lend` handed the closure the element's
   address. *Fixed:* the runtime lends a read view of an object as it
   is (`isReadApiView`). Case "apis object crossing par over read
   views".

### Low: messages and docs

3. **A held object's reason named both bounds.** For an object reached
   inside what a task is passed, the error said "an API object whose
   braces and API name no `Sends` or `Syncs` for this" even of a
   `^{Shape + Sends}` that only lacks `Syncs`. *Fixed:* `crossingReason`
   names the bound it lacks when the braces name the other one. Case
   "apis object crossing a held object names the bound it lacks".
4. **SPEC §18 still marked the view and box rows planned,** said "Today
   an API object goes to no task", and the local-task paragraph kept
   "once objects cross ... *planned*". *Fixed* in SPEC, which also says
   that an unbounded type parameter's erasure is checked at each
   instance.

## The builder's decisions

1. **A view's braces drop the bound its form cannot use:** sound.
   `formBraces` only removes, and the bound it removes is the one the
   form never crosses by, so no view crosses more than its box: `?b` of
   a `^{A + Sends}` (a `?{A}`) is rejected lent to a task, bare, through
   a generic `T`, to a local task, and to `par`; `!b` of a `^{A +
   Syncs}` likewise. The sema and runtime spellings agree with several
   bounds (`^{Shape + Print + Sends + Syncs}` lending `?{Shape + Print
   + Syncs}` and `!{Shape + Print + Sends}`, printed and lent on).
2. **An API's `Owned` counts like a written one:** sound once finding 1
   holds at instances; owned closures, channels, and a box returned
   from its function take `^{Job}` of `api Job: Owned`, and a value
   holding a view is rejected at the erasure and by Stage 3.
3. **Every supertrait bound is checked at erasure:** right, and now at
   each instance too (finding 1); transitive supertraits (`api Job:
   Base`, `api Base: Sends`) and a bounded `[T: Shape]` of `api Shape:
   Clone` are rejected at the instance.
4. **The oracle checks crossing only at a task call, and only for
   objects:** no compiler-accept/oracle-reject found. Its walk agrees
   with the compiler's on handles (a `*H` holding `^{A + Sends}` given
   to a task needs `Syncs` in both), views passed bare, optionals,
   fields, Lists, Maps, transitive APIs, and the object task; it
   abstains on most `test` bodies (a method through a handle).

## Parked

- Low, design note: an argument erased at the task call itself
  (`f(^Note(m: +h))&` with `f(s: ^{Shape})`, or `!a.add(?sq)` to an
  actor's `?{Shape}`) crosses by its known type, not the object's
  braces: a known `Note` holding a `*Map` makes the task local, a known
  `Square` lets it cross. Sound (the hidden type is the written one,
  and no owned closure or task hides), and the oracle agrees, but CORE's
  "an API object without the bound a task needs goes to no task" reads
  stricter. For the designer: keep, or check the parameter's braces.
- Low: an owned closure capturing a `T` whose instance holds a task is
  rejected by the loan rule (a task may hold a view), not by
  `holdsTask`; right today, but it rests on that classifier.
- Low, older: an API method returning `^{Job + Owned}` must say
  `from @`, though a box naming `Owned` views nothing.

## Probed without findings

Calls through objects as tasks: `?b.area()&`, `(!b).grow()&`,
`(<j).run()&`, `Job.run(?j)&`, a view's and a write view's own calls,
methods with arguments, view arguments, fallible methods of each form
with plain and `String`-field errors, a `<@` task never waited for, a
`Tasks` set of them, and a second move rejected. Receivers: `j.run()&`
of a `^{Job + Sends}` (rejected toward `Syncs`), `(<j).run()&` of a
`^{Job + Syncs}` (rejected toward `Sends`). Task results: `^{Shape}`
rejected, `^{Shape + Sends}` taken back. Channels: boxes of `Sends +
Owned` between tasks, `select` send arms, a non-sending value rejected
at the erasure into the channel's element, `List` and `Map` elements,
`Owned` without `Sends` rejected. Actors: state of boxes with and
without `Sends`, messages holding boxes, results with and without
`Sends`, `?{Shape + Syncs}` arguments. `par.map` and `par.each` over
boxes of each bound, and captures. `isolate` and `supervise` giving an
object holding a task, directly, in a field, or in an owned closure
(rejected). Owned closures capturing a task directly, in an object, a
`List`, an optional, a box, a `*` handle, nested closures, a closure
holding one, and through generic `T`s (each rejected); actors and
channels captured (accepted). Hidden Cells: `*Cell[Int]` syncing with a
writer elsewhere, a `*Cell[List[Int]]` and a `Signal` rejected. Loans:
a box written, dropped, or moved while a task reads it (rejected), a
view's task returned past its value (rejected), a copied view lent to
tasks in a loop. Local tasks: an object pinned with a `*Int` argument
(`Syncs` still needed), a `*H` and a `~H` holding objects. Every
accepted program ran clean under the sanitizer.

Trig (f157406): none of its three owned closures captures a task
(`env` in `tools/trig/main.rig` captures nothing; `or_` and `memoize` in
`src/core/core.rig` capture a `List` of owned closures, an owned
closure, and a `*Cell`), and Trig declares no API, so no erasure meets
the new instance checks; nothing it writes is newly rejected.
