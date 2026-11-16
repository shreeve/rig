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
