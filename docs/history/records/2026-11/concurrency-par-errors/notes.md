# A closure's own errors in quiet passes (2026-11-15)

Found by review of the select-arm change (backlog, 2026-11-15): a closure
written in `par.map` whose body was in error passed `rig check` and
stopped emit with "internal error: cannot emit this expression".

```text
use std.par

sub main()!
  xs = List[*Cell[Int]]()
  !xs.push(*Cell(1))
  ys = par.map(?xs, |c| (!c).swap(5))
  print(ys[0], xs[0].get())
```

`par.map(?xs, |x| x.abs())` on `Int`s did the same.

## Cause

`closureType` (src/typecheck.zig) types a closure written where a std
form calls a function: quietly as one that cannot fail, then as one that
can, and, when neither checks clean, it gives the first type and leaves
the errors to the call's own check of the closure (`checkArgs`). But
`par.map` and `par.workers` build on the closure's value, and a closure
whose tail is in error gives poison. The call then stopped with
`skipCall`, whose `synthArgs` checks each argument again with no
parameter types: the closure's parameter is poison there, so every error
that touches it is silenced, and the closure is checked as one that
cannot fail, which reported a stray "use of `!` propagation requires a
fallible enclosing function" for a closure that propagates. No check
reported the real error.

## Fix

Where a call cannot build on what a closure gives and stops,
`skipClosureCall` checks the closure aloud, given what the call lends
it, as whichever of the two quiet checks found fewer errors
(`closureErrors`), and leaves it out of `synthArgs`. Where the call goes
on, its own check reports the closure's errors as before.

A first version checked aloud in `closureType` itself, whenever neither
quiet check was clean. That rejected programs that are right: an arm of
`task.select` whose closure needs the type the arms join to,
`(!b).on_recv(|v| .blue)` after an arm giving `Color.red`, or
`List()` after `List[Int]()`, checks clean only against the join, which
`checkArgs` gives it. The quiet check is not the closure's last, so it
may not report. Test "chan select arm typed by the join" keeps it so.

Generic calls had the same shape at a smaller cost: `lentLambdaType`
types a closure argument quietly, given the parameter types the other
arguments bind, and when its body is in error, the type parameter its
result would bind stays unbound, and the call said "cannot infer `K`",
a Rig error that hid the closure's own. The closures whose quiet check
found errors with every parameter type known are kept
(`Inference.failed`), and a type parameter left unbound that one of
their results would bind is explained by checking that closure aloud
(`lambdaLeftUnbound`), in place of "cannot infer".

## Every quiet pass over a closure, with its verdict

| Pass | Call sites | Before | Verdict |
|---|---|---|---|
| `closureType`, `par.map` | `parCall` | value poison: `skipCall`, errors lost, emit failed | fixed: `skipClosureCall` |
| `closureType`, `par.workers` | `parWorkers` | the same | fixed: `skipClosureCall` |
| `closureType`, `par.each`, `par.push` | `parCall`, `parPush` | a `sub`: no value to be poison, `checkArgs` reports | right; `par.each` goes through `skipClosureCall` like `map` |
| `closureType`, `par.map` gives nothing, or a write view | `parCall`, `parWorkers`, `givesWriteView` | the call's error alone, the closure's hidden | fixed: the call's error, then `skipClosureCall` |
| `closureType`, `task.isolate`, `task.supervise` | `isolateCall` | `checkArgs` reports; no parameters to lose | right |
| `closureType`, `task.select`'s arms | `armResult` | the join is checked by `checkArgs` | right; must stay quiet (above) |
| `task.select`'s named arms | `taskSelectNamed` | no closure | right |
| `http.serve` | `httpServe` | no quiet pass: `checkArgs` checks the closure | right |
| `lentLambdaType`, generic inference | `inferBindings` (`time.within`, `sort.sort_by`, `sort.sort_by_key`, any generic function) | inferred: `checkArgs` reports; unbound: "cannot infer", closure's errors hidden | fixed: `lambdaLeftUnbound` |
| Map and Set `update`, `retain`, `ensure_with`, `ensure_by` | prelude methods, parameters from self | `checkArgs` reports | right |
| `chainFnResult`, chains (`map`, `filter`, `any`, `all`, `find`, `min_by`, `max_by`) | `chainTypes` | null on errors; the loop the chain becomes checks the closure | right |
| `lambdaChecksQuietly`, `reduce` | `reduceFunction` | `checkArgs` reports | right |
| `argType` (`synthQuiet`) of any argument | every call | the call's own check reports | right |
| `*Actor.supervised(*|| ...)`, a task `(|...| ...)()&` | | checked aloud | right |

Probes, each run on the base (3cfdde207) and the branch: the two
programs above, `par.workers` and `par.each` with `x.abs()`, closures
that propagate (`|x| x.abs()!`), a `par.map` closure that gives nothing
and is in error, `par.push`, `task.isolate`, `task.supervise`, select
arms (receive and send, and the join cases), `http.serve`, Map `update`,
`retain`, `ensure_with`, Set `retain`, `time.within`, `sort.sort_by`,
`sort.sort_by_key`, chains, `reduce`, a user generic, `Actor.supervised`,
and a task of a closure. Only the par calls and the generic calls with
an unbound parameter changed; every other verdict and message is the
base's.

## Cases

- concurrency-par: "par map closure's own error" (the first program),
  "par closures' errors of every kind" (`map`, a closure that
  propagates, `workers`, a closure that gives nothing).
- concurrency-chan: "chan select arm typed by the join".
- types-generic: "generic closure's errors leave a parameter unbound"
  (a user generic, `sort.sort_by_key`, `time.within`).
