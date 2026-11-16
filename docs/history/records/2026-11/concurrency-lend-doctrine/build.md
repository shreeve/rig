# Step 2 built: what `!` lends to a shared value (2026-11-15)

The owner approved the design ([design.md](design.md)) in his words
"Approve the defaults". This records what was built on branch
`lend-doctrine`, and what it was checked against.

## The fact

- `sema.loanOfView(viewed)`: read when a write view of `viewed` lends
  only to read, a value `sema.changesByMark` judges by its concrete type
  (a Cell, a Signal, a channel, an actor, a value that holds a Cell);
  write for an API object, a type parameter, a handle, or a view.
- `SemContext.loanOf(lend)`, recorded by typecheck (`Checker.recordLoan`)
  where `!x`'s view is chosen, `synthLend`: a method's self reached
  through a handle is the handle's value. An actor's call and a select
  arm's channel already went through `synthLend` as a self
  (`armHandle`), so they need no route of their own. `lendView` records
  it again where a handle goes where a view of its value is expected
  (a `.handle` row: read by the value; none: the handle itself, write).
- The ownership checker lends `x` by it in the generic lend walk and in
  `walkCallBody` (`recv_loan`, which replaces the line that turned an
  actor's call or a select arm's self into a read). What a call stores
  through its self still follows the self's mode, so nothing a call
  stores is lost to a read loan. `Checker.taskOf` pins a task only for a
  `!x` whose loan is a write.
- Emit reads nothing new.

## Checked

- Every probe of the inventory and both step-2 panels (165 programs):
  no program accepted before is rejected; the newly accepted ones are
  the design's consequences and the breaker's attack forms, each run
  clean under `RIG_SANITIZE=1`.
- Two cases of the old rule became tests: ownership-cell "cell mark
  lends the place to read" (was "cell mark lends the handle") and
  std-shared "shared map put while a view lives".
- New cases: ownership-cell "cell lend ..." (accepted forms, the
  breaker's attacks, and what stays rejected: `!h` lending the handle
  twice, writes of the place in the arguments, rebinding or dropping
  while a result view lives, two `!{Grow}` of one owned value or of an
  erased one, a type parameter), concurrency-cell "cell lend ..." under
  `seeds: 20`, concurrency-chan "chan lend ...".
- The docs' examples the rule makes legal turned from `rig pending` to
  `rig`.

## Gates

- `tools/emit-diff origin/main` with the branch's `bin/rig`: identical,
  36 programs, 533 files.
- The core suite: green but for the reference checker, which still
  holds the old rule until its own change teaches it CORE's text: it
  rejects `doc/SPEC/5cf88226f148 main` and
  `test/behavior/concurrency/cell_lend_a_task_through_a_handle.rig main`,
  the first it meets of the programs the rule newly accepts. Those wait
  for the merge with that change.

## After review (101 programs, scratchpad `review-lend/REVIEW.md`)

The adversarial review found no unsound accept and no wrong reject the
branch brings, and three things to fix, each built here with a failing
case first.

- **`swap` of a Cell, a data race on main too.** `swap` read and wrote
  a Cell as plain memory. The reviewer's v04 (5,000,000 swaps of two
  `!Cell[Int]` views racing 5,000,000 `!c.add(1)` on another task,
  `rig build --release`) lost 31,000 to 52,000 adds in each of 10 runs.
  Run again here on the base compiler (3cfdde207), release, three runs:
  4,936,254, 4,932,932, and 4,942,196 of 5,000,000, so 63,746, 67,068,
  and 57,804 adds lost. `swap` now refuses any place that holds a value
  that changes by a marked call (`sema.holdsMarkedValue`, from
  `changesByMark`), a Cell with itself too, and points to the Cell's
  own `swap`; handles still swap. Trig (main, f0363520), loco, std,
  examples, and bench swap no Cell: the only Cell in Trig is
  `src/core/core.rig:354`, never swapped, and the std `swap` calls
  (`std/terminal.rig` 543, 545, 1477-1486) exchange plain fields.
  Nine cases of earlier reviews that swapped Cells became rejections or
  lost that line.
- **`!s` of a `*{A}` into a `!{A}`: North Star 1, on main too.** The
  lend table's handle row asked `changesByMark`, which said yes for an
  API object, while the loan said no, so `rig check` accepted what Zig
  rejected. `changesByMark` now answers by the concrete type and never
  for an API object or a type parameter, and every decision of what
  changes by a marked call asks it: the lend table, `lendsHandle`, a
  `match !h`, the self rule, `swap`, and the loan. `!s` of a `*{A}`
  lends only the handle.
- **CORE §4's wording** now says the loan is judged by the concrete
  type of the value lent from, not the view it becomes.

The owner's added item, a guard of the premise for std: the checkers
see it in Rig code, since a `!@` method of a value that holds a Cell
changes only its Cells and nothing views into a Cell, so the unchecked
part is Zig. Type checking now rejects a std `extern zig` function that
gives a view and takes a value that changes by a marked call unless it
is listed, read, in `Checker.marked_views` (`std.shared.find` and
`std.shared.settle`). `test/cli/std_premise.sh` checks every std module,
and a std copy with an unlisted such function, and with a method that
grows a List field it views, both rejected.
