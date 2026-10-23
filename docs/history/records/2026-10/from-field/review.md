# `from @field`: adversarial review of #605

The built rule (CORE sentence 7, [6-final.md](6-final.md)) was attacked
with 150 probe programs, each run through `rig check`, the oracle
(`rig-oracle -v`), and, when accepted, `RIG_SANITIZE=1 rig run`. Two
soundness holes, one oracle error, and one wording defect were found
and fixed; each fix starts from a case that failed.

## Findings

### S1 (high, soundness): a task dropped its lend of self

`t = (!it).next()&` through a method whose `from` names a path of self
kept only the path's loans: `<it`, or `it.at = 5`, while the task was
pending was accepted. The task then read the dropped iterator (its
`print(@own)` printed an empty String) or raced with the write. A task
is its call, still running, and keeps every loan of its receiver
(docs/design/concurrency.md); `checkArgs` widened `origins.result` for a
task but kept `self_paths`, which then narrowed the receiver's loans.

*Fix:* a task call drops `self_paths` with the rest of its clause
(`typecheck.checkArgs`). *Case:* "origin self path task", a read-view
path and an owned one.

### S2 (high, soundness): a path longer than the checker's cut

The ownership checker cuts a place's path at 8 fields. A `from` path of
9 (`from @a.b.c.d.e.f.g.h.i`) was cut too, so the body check took
`@a.b.c.d.e.f.g.h.j` for part of it; with `i` a read view the result put
no loan on self, and `<t` while it lived freed what it viewed (sanitizer
abort).

*Fix:* sema rejects a path of more than `sema.max_path_fields` (8)
fields, the constant `Paths.max_depth` now reads, so the body is always
checked against the path exactly. A deeper receiver at the call still
only adds conflicts. *Cases:* "origin self path too long", and "origin
self path eight fields" (a path of 8 is checked exactly).

### O1 (medium, oracle): self's loans copied after the call's stores

For a read-view path the oracle copied what the receiver held after the
call, stores included. A legal method that stores an argument in self
(`keeps t`) and returns a view of another path had its result carry
`t`: the compiler accepted the caller, the oracle rejected it, and such
a test would fail the suite. What a call stores in self comes from its
arguments, which the body may return only where `from` names them.

*Fix:* the oracle copies the receiver's loans into a temporary before
the call's op and carries those (`lower.zig`). No listed rejection was
lost. *Case:* "origin self path stored by the call".

### L1 (low, wording): `from @, m` suggested

A method with paths returning an unnamed parameter's view was told "its
signature says it views only `@`", with the fix `from @, m`, which is
itself rejected. *Fix:* `paramList` names the clause's paths ("views
only `@map`", "`from @map, m`"). *Case:* "origin self path names its
paths".

## Checked and sound

- H1-H6, G1-G2 beyond the shipped cases: a field re-pointed in loops, in
  a callee (`retarget(!it, ?m2)`) and by a `keeps` method; self dropped,
  moved, reassigned, swapped, a box or optional field replaced or moved;
  `@a.b` through objects and boxes; `(?String)?` fields; `Wrap[T]` at
  `T = ?Map` and at `String`; `-> !Int from @a` twice and beside a
  sibling; several results through paths.
- Body escapes: locals, branches, `??`, Lists, closures, helper calls,
  `?@` aliased to a local, self stored in a List, bound calls through
  locals, Lists, `??`, a generic relay, and a write view of `@b`.
- Map and Set iterators with `put`, `take`, `replace`, `edit`,
  `ensure`, `clear`, `retain`, `update` while an item lives; items kept
  in Lists and Maps past the iterator; temporary receivers and
  receivers that view temporaries; closures, `defer`, and tasks holding
  items; actors (a `from` is rejected on an actor's method).
- `[I: Iter]`: every std iterator, user iterators through a box, and an
  owned-field `from` (refused); a by-value iterator dropped while an
  item lives.
- Stage 3: a narrower `from @field` conforms; one viewing self where the
  API names only an argument is refused; `add` blocks across modules
  (calls take the API's `from @`).
- The inlining fix: only inlining's `mentions` read clause names as
  uses. Resolve records the clause, sema reads it, and the compile-time
  check only tests for its presence.
- The oracle agrees with the compiler on every probe it decides, but
  for the recorded body `ref-gap`. It abstains on every program using a
  Map or Set ("a generic type at an owner whose methods copy a `T`") and
  on tasks, so those cases rest on the compiler's checker alone.

## Parked (over-restrictive, no change)

- `whole = ?@; whole.text` in a `from @text` body is reported as a view
  of `@`: an alias of self carries no path.
- A method in an `add` block called directly takes its API's `from @`.
- `Hold[I: Iter]{inner: I}` is refused by `[I: Iter]` (rule 4, as
  5-review.md expected).
