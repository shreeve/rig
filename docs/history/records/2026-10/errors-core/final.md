# CORE's "A failure moves its error": the panel's result

The owner's rule for a CORE change: 4 to 7 experts revise it, their
review is accepted, then one final pass. Four experts revised the
paragraph of errors-spec §9 independently ([brief](brief.md)): a
language-spec author, an ownership-systems veteran, a technical writer,
and a Core purist. Each found the approved draft right in substance and
wrong in wording that the oracle, written from CORE alone, would read
literally.

## What the final text takes from the panel

| Change from the §9 draft | Raised by | Why |
|---|---|---|
| "keeps nothing (sentence 7)" rests on the type: an error holds no loan, so the call keeps nothing and its result views none of it | spec author, ownership, writer | sentence 7 lets a `keeps` function store a kept view in any write view it is lent, and narrows nothing for a function value |
| "a hidden `E?` of its statement", not "a slot" | Core purist, writer | CORE and SPEC already use "slot" for a `Table`'s place and `Slot[n]`; an optional is a form the page covers |
| the `!` or `catch` every fallible call carries is the hidden lend's mark | Core purist | sentence 4: every write lend is written |
| `e!` takes the error out with `<` and returns it | Core purist | the same moves, with no write view lent across two sets (the caller's may be wider) |
| a new, empty `E?` per catching call; any failing `return` | ownership, spec author | "a slot of its caller's" read as one per frame, and was false under `e!` |
| a task holds its call's error as it holds its result | ownership, Core purist | a write loan on the `Task` would stop it moving into `Tasks`, being returned, or taken by `>t` |
| "no `*` or `~` handle", keeping `^T` and `^error` | ownership | "no handle" would read as forbidding a box |
| §7 Defer: no failure leaves a defer | ownership | what keeps a nested failure from replacing the leaving error; built (`!` in `defer` or `errdefer` is rejected) |
| one *(built)* / *(planned)* mark per sentence | all | honest marks, each sentence testable |
| two `rig pending` examples: the field rule's rejection, a task dropped with its error unread | all four proposed some | each fails until R3 builds it |

"No-loan home" (sentence 9) was proposed for the field rule and not
taken: CORE defines it as keeping text only as a `Static`, which would
forbid a `String` field.

## Left as notes

- `catch |_|` drops before its handler, and a destructure's `_` at the
  statement's end; no program can tell the two apart.
- CORE has no sentence of its own about `Task`; the paragraph speaks of a
  task's result as SPEC §18 does.
- The oracle checks "no field holds a loan" independently only for
  named functions with no `keeps`; for function values it needs the
  field rule's type fact (errors-spec §10).
