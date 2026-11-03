# Row 33C: what a value's loans name, as one fact (CORE §9, planned): draft 2, final pass

Rig language analysis, 2026-11-01, against main 928b44bf2. Draft 1 (`draft.md`) went to three
expert reviews: soundness and CORE (`expert-core.md`), the compiler (`expert-compiler.md`), and
adversarial programs (`expert-adversary.md`, with every program and its output). This draft takes
their revisions; where they disagreed, the choice and its reason are stated. It covers the one
fact only. Ending loans at their last use within a statement (row 33D) is its own change, after.

## What draft 1 got wrong

- **It classified by the type's kind.** An owning object can hold a view (`List[?String]`, an
  iterator holding `?List`), and a `^?v` or `*T` can carry a loan; a value inside a temporary is no
  `none` because its type owns. All three reviewers found this, and the adversary showed it would
  wrongly accept programs that read a dropped temporary (`if pick(?mk())[0] as s`).
- **It missed the unwritten lend.** `for x in first_list(mk())` has no sigil: `mk()` is lent where
  a view goes (sentence 4). Treated as `none`, the loop would read a dropped List. Main and the
  oracle reject it, and must keep doing so.
- **Its readers were the wrong functions.** The nine predicates it named answer questions about a
  type, and stay as they are. The places that decide per expression are others (below).
- **Two claims were false on main.** The `if ... as` and `match` forms of its example already run;
  only the `for` rule fails. And emit does change for the newly accepted programs (below).

## The fact

> **What a value's loans name:** a set of two answers, either, both, or neither. **place**: a loan
> on a binding or a path from one, with that path; **made**: a loan on a value made in the
> statement, which the statement's end drops. Neither means the value carries no loan.

It is a set, not a single answer (expert-compiler over expert-core): a value can view both a place
and a temporary, and the readers ask different halves. A header asks "could it be made here", while
moving out asks "could it be a place's". The place answer keeps its path, so `from @field` narrows
in headers as it does in calls (expert-adversary).

**The positive list**, compositional, so it fits CORE §9 in one paragraph with no exceptions (CORE
§10). It follows sentences 4, 6, and 7, and §3–§4:

| The expression | What its loans name |
|---|---|
| a type that may hold no loan (CORE §9, per type, at the instance) | neither |
| a constant, a function, an `Enum.variant`, a literal (a `"abc"` as a `?String` too) | neither |
| a binding's name: a local, parameter, capture, or self | place (that binding) |
| a path `b.f`, `b[i]`, read rather than lent | what `b` names; past a view on the path, what that view names |
| a lend of `x` whose type is a view (`?x` of a read view is that view, §4; `!x` of a held `!T` lends it on) | what `x` names |
| any other lend of `x`, written or unwritten where a view goes (sentence 4), or its slice | where `x` lives (place if its path starts at a binding, made if at a value made in the statement), joined with what `x` names |
| a call | the join, over each input whose loans the result carries (sentence 7, its recorded origins: arguments, counted as the lends they are; self, as its method takes it, narrowed by `from @path`; the called value, when a value is called), of what that input names. Each of several results has its own answer; the call's is their join. A call with no recorded origins keeps today's answer, made when an argument makes a temporary. |
| `+x`, `<x`, `*<x`, `^<x`, an erasure to an API object | what `x` names |
| a constructor, an array, a handle or box made from parts, an optional or enum payload, a closure literal (its captures) | the join of its parts |
| branches, a `match`, a block, a loop's value | the join of its leaves and tails; a leaf that jumps adds nothing |
| a jump, or no value | not asked |

A read view of a value that copies, read where a value is expected, still carries its answer here.
Where it is copied out is a decision about the context (`sema.copies`), not about the expression.

**Where a value lives is a different fact, and stays one.** "Reads in place" applies only to a
subject of type `?T`, `!T`, `[]T`, or `![]T`. A view-kind object made in a header, such as an
iterator `Cur(xs: ?xs, i: 0)`, is still held there (expert-adversary). So typecheck's
`isTemporary`, which asks where a value lives, does not read this fact; otherwise `?mk_iter(?ls)`
would lose its temporary slot (expert-compiler and expert-adversary over expert-core).

## Who records it, who reads it

- **Records:** sema, in a function of its own beside `handsOver`, `sema.viewsOf`. `handsOver` runs
  at about 100 call sites and should not pay for walking a call's arguments. It reads `typeOf` at
  the instance, the per-type *may hold a loan*, the call's recorded origins and self paths, and
  `readViewField`, through one exhaustive switch over the IR's kinds, as `shapeOf` is. Its answer is
  recorded in storage's decision table, as `.hands` is, so `verifyDecisions` fails a pass that sees
  a different one.
- **Reads, in place of the re-decisions found:**
  - `sema.viewsOnlyMade` (sema.zig:14547);
  - `storage.startsOutsideHeader` (storage.zig:567);
  - the three `for` checks that ask whether a name holds the subject (typecheck.zig:3535, 3557,
    3570): reject an owned temporary List (the §3 planned case) or a subject whose answer has made;
  - `tempBase` (typecheck.zig:4174), `forViewsSlot` (sema.zig:14498), `holdsView`, and
    `rejectHeaderCopy`;
  - `holdsHeld` / `makesTemps`: a held base is refused when its answer has made, not when any
    temporary appears anywhere inside it.
- **The ownership checker never accepts because of the fact.** It goes on working out loans from
  flow, its safety net (CORE sentence 6); the fact chooses what typecheck allows into a header and
  which message a rejection gives. Under `-Dself-check`, an assertion checks that the fact and the
  checker's loans on statement temporaries agree.
- **Emit decides nothing new.** It reads the storage plan. For a newly accepted header, a temporary
  argument that is no origin of the view (a key) ends at the header while the view lives, which the
  plan records. One narrow class of headers accepted today switches from a copy to a pointer with
  the same behavior; `tools/emit-diff` counts it.

## What changes for programs

Only accepts more. A header (`for`, `if ... as`, `match`) reads in place a subject that is a view a
call returns, or a path through one, as it reads a place: a `for` over a List of owners included,
which today asks for a named place. A lend of a view-returning call lends the view on, for `?` and
`!` (`?first_list(?ls)`, `!first_mut(!ls)`). A read-view field of a made value is copied out with
its own loans, as a `from @field` method's result already is (`v = hold(?ls).items`, which the
compiler rejects and the oracle accepts today). Nothing accepted today is rejected: every new
acceptance is one whose answer has no made, and a made answer is rejected as the ownership checker
rejects it now.

## CORE, as it would read

- §9: **Per expression, one classification** of what it hands over (a place, a made value, a lend,
  branches, or a jump) and of what the loans its value carries name (places, with their paths, a
  value made in its statement, both, or neither), each decided once by a positive list *(built)*;
  whether the value lives for the whole program *(planned)*.
- §3, its status note: a `for` over a view a call returns becomes *built*. The draft's loop becomes
  an ordinary example, beside the `rig pending` one for a `for` over a made List of owners, which
  stays planned (a different rule: an owned temporary held for the loop).

## Tests

From the three reports (16 proposed by expert-adversary, with programs and outputs):
- **Now accepted:** `for x in first_list(?ls)`, the same through a path (`pick(?lss)[0]`,
  `wrap(?xs).items`), a write-view result (`!first_mut(!ls)`), a generic result, a closure's result,
  and `?first_list(?ls)`.
- **Still rejected, with their messages:** a made argument with no sigil (`first_list(mk())`,
  `mk().all()`, `items_of(mk())` through `?{A}`, `boxed().items()`, `if first(mk()) as s`); a value
  inside a temporary (`if pick(?mk())[0] as s`, `match pick(?mk())[0]`); a body that writes,
  drops, or stores against the view's owner (`!ls.push` in the loop). The hint for a loop over a
  view of a made value names `mk()`, not the call, since binding the call would still dangle.
- **Guards that pass today:** the `if ... as` and `match` forms of the example; a made view-kind
  iterator in a header (`for x in Cur(xs: ?xs, i: 0)`).
- **The oracle:** `viewsOf` joins the classifiers it may not call (test/rig.rip:1037); the matrix
  runs, and any rejection the compiler makes that the oracle does not goes to
  `test/oracle/differences` with its reason.

## Size

About 200–250 compiler lines (sema and typecheck; storage's decision table), about 60 doc lines,
and about 14–16 test cases. The ownership checker's source does not change. Risk is low to
moderate. It touches the ownership-for, -header, -origin, -move, -generic, and -apis areas, and
emit-held, -loop, and -match. The existing rejections in ownership-misc-2, and the reject example at
SPEC.md:6107, keep their text.

## Out of scope, as rows of their own

- emit.zig:5379 decides `owns` from `handsOver` plus a type: a fact to record (expert-compiler).
- A loop's view of a view parameter, returned, is wrongly rejected today (expert-adversary,
  program `f05`): its own fix.
- Whether a value lives for the whole program stays planned. No reader in this change asks it, and
  CORE no longer converts a `?String` to a `Static` (expert-core).
