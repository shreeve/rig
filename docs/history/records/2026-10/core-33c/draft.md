# Row 33C: "is a view" as one fact (CORE §9, planned): draft 1

Rig language analysis, 2026-11-01, against main 928b44bf2. The owner accepted "'Is a view' as one
fact" as a default of the compiler review (2026-10-31, decision 3). This is the draft for the CORE
change process: experts revise it, a final pass follows, and the owner approves before any code.
It covers the one fact only; ending statement-long loans at their last use (row 33D) is a change
of its own, after this one.

## The problem

CORE §9 says each expression has "one classification of what it hands over: a place, a made value,
a lend, branches, or a jump *(built)*; whether it is a view, and whether the value lives for the
whole program *(planned)*". The built half is `sema.handsOver`, decided once and asked by
typecheck, the ownership checker, and emit. The planned half is decided again and again: the
review counted about eight deciders (`isReadOrWriteView`, `isViewType`, `holdsMarkedView`,
`mayHoldMarkedView`, `mayHoldView`, `holdsViewOnly`, `viewHeldAsPointer`, `isErasedView`,
`readsAsValue`), and `typecheck.isTemporary` derives "temporary" from `handsOver` plus
`isReadOrWriteView`. Most of these answer a question about a type, which CORE §9 already makes a
per-type fact; the trouble is where a pass asks the type question to answer an expression
question, and gets it wrong.

The failure the weak spots name (docs/internals/weak-spots.md, "Review findings not fixed"), checked
on main:

```rig
fun first_list(lists: ?List[List[String]]) -> ?List[String]
  ?lists[0]

sub main()
  ls: List[List[String]] = List()
  inner: List[String] = List()
  !inner.push(String("a"))
  !ls.push(<inner)
  for x in first_list(?ls)
    print(x)
```

```error
a loop over a List of `String` walks a List that a name holds, or a field or element of one; bind `first_list(?ls)` to a name first
```

`first_list(?ls)` hands over a made value (a call), so the loop treats it as a List of owners made
in its header, which it would have to drop, and rejects it. But the value is a view of `ls[0]`:
nothing is made, nothing is dropped, and the loop can read it in place, as it reads `?ls[0]`.

## The fact

`handsOver` gains a second answer beside its kind, recorded with it, once per expression:

> **What the value views:** `none` (it owns what it holds, or is plain data), or `place` (a view of
> memory a place owns, so a loan names that place), or `made` (a view of a value made in its own
> statement, which the statement's end drops).

The positive list, by what the expression hands over and its type's kind (CORE §1):

| The expression | What its value views |
|---|---|
| a type of the plain or owning or handle kind | `none` |
| a lend, `?x`, `!x`, or a slice of `x` | what `x` is: `place` for a place, `made` for a value made there (`?mk()`) |
| a place whose type is of the view kind (a binding, field, or element holding a view) | `place` |
| a part of a made value, of the view kind | `made` |
| a call, or method call, whose result is of the view kind | `place` when every argument its origins name (CORE sentence 7, `from a`) is a place or views one; `made` when one views a value made in the statement |
| a constructor of an object of the view kind | the join of what its fields' values view |
| branches | the join of its leaves (`made` over `place` over `none`) |
| a jump, or no value | not asked |

A read view of a value that copies, read where a value is expected, is still a view here: where it
is copied out is a decision about the context (`sema.copies`), not about the expression.

## Who records it, who reads it

- **Records:** sema, in `handsOver`, from the facts it already has (`typeOf`, the call's recorded
  origins). One exhaustive switch, as `shapeOf` is now: a new IR kind does not compile until it is
  classified.
- **Reads:** typecheck's `isTemporary`, the header-subject rules (a `for`'s source, `if ... as`,
  `match`), the storage planner's header temporaries, the ownership checker where it carries a
  call's loans, and emit only through `Facts`. Each type-level predicate stays where it answers a
  type question; each place that asks one to answer "is this expression a view, and of what" asks
  the fact instead.

## What changes for programs

Only accepts more. The loop above is accepted and reads `ls[0]` in place. A `for`, `if ... as`, or
`match` whose subject is a call returning a view of a place reads it in place, as it reads the
place. Nothing accepted today is rejected.

## CORE §9, as it would read

- **Per expression, one classification** of what it hands over: a place, a made value, a lend,
  branches, or a jump; and what its value views: nothing, a place, or a value made in its
  statement *(built)*; whether the value lives for the whole program *(planned)*.

## Tests

- The loop above, and its `if ... as` and `match` siblings, as `test` cases (all fail today).
- A call whose origins name a made value (`for x in first_list(?mk_lists())`), still rejected.
- Branches of a view and a made value.
- The oracle, which reads CORE alone, should agree; any case it rejects goes to
  `test/oracle/differences` with the reason.

## Open questions for the experts

1. Is `none` / `place` / `made` the right shape, or does "lives for the whole program" (a view of a
   `Static`) belong in the same answer now?
2. Is a call's result `place` exactly when its origins name only places, given generic results
   (`T` at an instance that is a view) and API objects (`?{A}`, whose hidden value may hold a view)?
3. Which of the eight deciders become readers of the fact, and which stay type-level?
4. Does anything in emit change, or only what the checkers accept?
