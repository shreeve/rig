# Brief: revise CORE's paragraph "A failure moves its error"

You are one of four experts revising one paragraph of Rig's Core,
docs/CORE.md (read it whole: ~/Data/Code/rig/docs/CORE.md; the paragraph
is in §2 under sentence 10, at "**A failure moves its error.**"). The
Core is the ownership model every other document and the compiler must
agree with; a second checker (the oracle, test/oracle/) is written from
it alone. The owner's rule: every CORE change goes through 4–7 experts;
their review is accepted, then a final pass makes one voice.

## What the paragraph must now say

The owner approved errors with data on 2026-10-21 (the spec:
~/Data/Code/rig/docs/history/records/revamp/r3/errors-panel/errors-spec.md,
§4 fields, §5 handling, §7 lowering, §8 invariants, §9 the proposed CORE
paragraph, §15 the decisions). Approved decisions this paragraph carries:

1. A member's field type holds no loan, holds no handle (`*`, `~`)
   anywhere inside it, and clones (by copy, text, or deep copy). Moving
   to another task follows from these. (Amends the old "never a view,
   and every field clones".)
2. Each call of a fallible function is lent, hidden, a write view of a
   slot of its caller's, which keeps nothing (sentence 7):
   `return E.name(...)` moves the made error into it before the scope's
   exits run; `e!` passes the slot on; `catch |err|` moves the error into
   the handler's own binding, which drops when the handler ends unless the
   handler moves it on.
3. A `catch` that binds no name, or `_`, drops the error before its
   handler runs.
4. A task's call is lent a slot its `Task` owns, so `>t!` and `>t catch`
   take the error from the task, and dropping the task drops it.
5. An error is plain or owning by the enum rule (§1); `error` is owning.
6. Reading, matching, printing, storing, and cloning an error follow its
   type.

The spec's §9 draft (a starting point, not binding):

> **A failure moves its error.** An error set's member may carry
> fields, as an enum's variant does; each field's type holds no loan,
> holds no handle, and clones, so an error never limits an owner, moves
> to any task, `+e` always works, and dropping one runs no `drop` body.
> An error is plain or owning by the enum rule (§1), and `error`, which
> holds an error of any set, is owning. Each call of a fallible function
> is lent, hidden, a write view of a slot of its caller's, which keeps
> nothing (sentence 7): `return E.name(...)` moves the made error into it
> before the scope's exits run, `e!` passes the slot on, and `catch
> |err|` moves the error into the handler's own binding, which drops
> when the handler ends unless the handler moves it on; a `catch` that
> binds no name, or `_`, drops it before its handler runs. A task's call
> is lent a slot its `Task` owns, so `>t!` and `>t catch` take the error
> from the task, and dropping the task drops it. Reading, matching,
> printing, storing, and cloning an error follow its type.

## What is built today, and what is planned

Built (main, 2026-10-22): `error` is a type and owning; `return
E.name` moves an error out; `e!` passes it on; `catch |err|` binds it
owned, dropped at the handler's end unless moved; reading, matching,
printing, storing (`List[error]`), cloning follow the type; declared
sets (`T!E`, unions) are built; the runtime can carry error data
(R3a, gated). Planned (R3): fields on members, the field rule, the slot
lowering and its task form, and a nameless catch dropping before its
handler (meaningful only once errors own fields). Keep CORE's
*(built)* / *(planned)* marks honest, sentence by sentence.

## The rules for the text

- CORE §10: it fits one paragraph, with no exception list; its rules
  follow the value's type; it is a desugaring into forms the page
  already covers (sentence 7's write view that keeps nothing, an owning
  local, `<` of an optional place).
- Every claim must be true or marked planned, and stay testable (each
  `rig` example on the page is a test).
- Rig's words: you lend a view, the compiler records a loan; never
  "borrow". A Rig `obj` is an object. `@` is self. Plain short words;
  timeless prose (what is, not what changed).
- Rig's taste: dissolve rather than patch; one word per idea.

## Your output

Write to the file named in your instructions:
1. Your revised paragraph, ready to paste, with its *(built)* /
   *(planned)* marks.
2. Any example the paragraph needs added, changed, or kept (the current
   `rig reject` and `rig pending` examples stay unless you say why).
3. Up to 5 decisions you want the owner to see, each with your default.
4. Your reasoning, at most 300 words: what you changed from the §9 draft
   and why, and anything in it you think is wrong.

Your final reply: at most 200 words, your text's key changes.
