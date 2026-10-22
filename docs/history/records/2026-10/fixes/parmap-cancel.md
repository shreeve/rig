# `Stop.canceled` after a failed `par.map`

2026-10-22. Branch `fix-parmap-cancel`.

## The bug

After a `par.map` or `par.each` failed, the calling task's next fallible
wait (`time.sleep(d)!`, `>t!`, a channel's `recv`) failed with
`task.Stop.canceled`, though nothing canceled it. The cancel was sticky,
and it climbed: a task that waited on the infected task with `>t`, even
one that cannot fail, became canceled too, so every wait in `main` after
it failed.

## The cause

`Task.waitWith` (src/tasks.zig) decided whether the waiter had been
canceled during its wait by reading two flags: its own, and the waited
task's. When either was set it marked the waiter canceled
(`markCanceled`). The second flag is set whenever anyone cancels the
task waited on, and the usual someone is the waiter itself: `parRun`
cancels its helper tasks after the first failure and then waits for
each with `t.wait()`, so the wait copied the cancel up into the caller.
The line dates from the move of tasks into tasks.zig (7f96af6ba), before
the scheduler.

## The class

Every construct that cancels tasks it owns and then waits for them was
probed, each in a task of its own, then followed by `time.sleep(MS)!`:

| Construct | Waits through | Affected |
|---|---|---|
| `par.map`, `par.each` (failure) | `Task.wait` | yes |
| `http.serve` closing its connections (`net.zig`, `Server.stop`) | `Task.wait` | yes, by reading; not reached by a test |
| `Tasks` `wait_first`, `>ts` failing, dropping a set | `handle.stopped` | no |
| `task.all` failing | `handle.stopped` | no |
| `task.isolate` after a panic | `Isolate.stop` | no |
| `time.within` timing out | the wait's own timeout path | no |
| `<t.cancel()`, dropping a task | `Task.stop` | no |

## The fix

The waiter counts only its own flag. The waited task's flag never adds
anything the waiter's own does not: a cancel the waiter passed on was
its own first; an isolate stopping cancels every task under it
directly, a waiter among them; and the isolate's caller, whose `f` may
wait on such a task, fails with `Stop.panicked`, not a cancel. `markCanceled`, whose only caller this was, is gone, so a task
takes a cancel only from what cancels it: its owner, an isolate, or an
interrupt.

## Tests

`test/rig/concurrency-cancel.rig.test`, under `seeds: 20`:
- `cancel par failure`: `par.map` and `par.each` fail, then a sleep, a
  wait on a fallible task, and a channel send and receive succeed, in
  the task and in its owner. Failed on main.
- `cancel par canceled`: a task canceled during a `par.map` stays
  canceled after it (the genuine cancel is still seen).
- `cancel leaves the caller`: `wait_first`, a failing `>ts`, a failing
  `task.all`, an isolate's panic, a `time.within` timeout, a dropped set,
  `<t.cancel()`, and a dropped task, each followed by a sleep that must
  succeed.
