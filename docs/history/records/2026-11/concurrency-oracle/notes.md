# The reference checker learns the task rules: notes

2026-11-15, branch `oracle-tasks` from main 61ddd14d5. The owner's
words: "the reference checker learns the task rules". The survey
behind it is [survey.md](survey.md).

## What was already there

Since b67332c4b, 2b0f96179, and e3f82b885 the reference checker
(`bin/rig-oracle`) decided `>t`, `>t!`, `>t catch |e|`, `<t.cancel()`,
a task's read loans until its drop, `>ts`, `!ts.add`, and generic
instances at `Task` and `Tasks`, with verdict tests for a task's read
loans (C4) and for `-> Task[T] from v`. The backlog's line that it
"models no tasks" was stale.

## What was missing, and what it models now

Each from CORE and SPEC alone; `src/ownership.zig` was not read.

1. **Calls through an actor's handle** (89 abstaining functions of the
   tests, 19 of the docs). `a.count()` and `!a.add(x)` on a
   `*Actor[T]` abstained ("a method reached through a handle"). Now the
   method is `T`'s, called on the handle, which the call reads: SPEC
   "Actors" says the `!` "marks the call, and lends nothing", and a
   call made with `&` "keeps none of the handle". `*Actor(x)` is a
   shared home: no value carrying a loan, and no task, goes in (C8).
   An argument of an actor's method is not stored in the actor's value
   unless its method stores it, and the method's own body is checked,
   so the arguments are an ordinary call's.
2. **The arms of `task.select`** (30 of the tests, 4 of the docs).
   `!ch.on_recv()`, `!ch.on_send(<v)`, `?t.on_end()` are not members
   of `Chan` or `Task`. Each arm is now a value that holds what it was
   lent and given, read by the select, so "what an arm lends stays
   lent, and what it sends stays taken, until the select returns"
   (SPEC "Channels"). The older spelling's function is lent to the
   arm, and its write captures stay write loans. What a channel is
   sent, by `send` or `on_send`, goes into a shared home (C8).
3. **A task's write loans** (no abstention: a wrong accept). A task
   kept what its call lent to write as a read loan, since a call's
   result keeps write loans only when its type holds a write view, so
   `t = fill(!xs)&` then `print(xs.len)` was accepted. The task call's
   op now keeps them as write loans (`Op.task_writes`). A task returned
   from a function still carries read loans only: by T2 no task with a
   write loan is returned.
4. **T2, a task lent to write moves nowhere** (SPEC §18 "Loans",
   concurrency.md "Where a task may go"). New rule: a `Task` var
   carrying a write loan is moved only by the binding of the task
   call that made it (`Op.binds_task`) and into its wait or cancel
   (`Var.waits`); any other move, store, `return`, or `break` is T2.
   The compiler rejects these in sema, which leaves most of their
   types poisoned, so only `task write loan moved` and the new `task
   write loan moved to a local` reach a verdict.
5. **No shared home holds a task** (concurrency.md rule 3). A Cell of
   a task abstained in `kinds` ("a `Cell` or `Signal` of a view"), and
   a task with no loan went into a channel or an actor's value
   unchecked. `kinds.Info.holds_task` now marks a type holding a task
   or a set of tasks, not through a view or handle; any no-loan store
   (`*Cell(x)`, `!c.set(x)`, `*Signal(x)`, `*Actor(x)`, `!ch.send(x)`,
   an arm's send, an owned closure's captures) of such a value is C8.
6. **Element methods that only read** (5 functions using `par`, 1
   doc). `xs.sum()` was taken as a write receiver with no `!`; the
   modes of the built-in element methods are now one exhaustive switch:
   `copy`, `fill`, `swap`, and a byte `write` change their self, the
   rest read it.

## Verdict tests, rule by rule

| Rule | Tests |
|---|---|
| (a) a task keeps its call's loans | `task read loan live` (C4); new `task write loan read` (C4) |
| (b) a task's drop uses its loans | new `task dropped where its scope ends keeps its loans` (C4) |
| (c) drops and defers in the order they run | `task defer after` (C4), `task defer before` (accept) |
| (d) no shared home holds a task | `task in a Cell`, `task in an object in a Cell`, `task set in a Cell`; new `task in a channel`, `task in an actor's value`, `task in an owned closure` (all C8) |
| (e) a write task only bound and waited | `task write loan moved`, new `task write loan moved to a local` (T2) |
| (f) a task's error | new `task errors waited, canceled, and dropped` (accept), `task error moved out of its catch` (C1), `task canceled ends its loans` (accept) |
| (g) `-> Task[T] from v` | `task returned with from`, `task returned keeps its loan`, and the others already there |
| actors | new `actor marked call while a task reads the handle` (accept); `actor task keeps argument loans` (C4) |
| select arms | `chan select`, `chan select makes its arms in order` (accept); `chan select arms lend to write`, `chan select end lends the task` (C4) |

## Rules left to the compiler

- **A fallible task dropped without waiting** (SPEC §18 "Drop"; the
  tests `task fallible lost`, `sets lost`): a rule that an error is not
  lost, not an ownership rule. Core §2 says dropping a task drops its
  error, so the checker accepts both, reported as `stricter`.
- **Type rules sema decides first**: a task as a statement, a
  write-view argument of an actor's method, `<@` and `keeps`/`from`
  methods through a handle, a Signal's type argument, a channel's or
  actor's type holding a view. The checker models (d) itself, but
  these stop in sema.

## A question the Core leaves open

CORE §4's lend table says `!h` "lends the handle itself". For an arm of
a select, SPEC says what an arm lends stays lent until the select
returns, but not whether a channel's `!` in an arm is a write lend held
that long. Read as one, two arms on one channel conflict, and the
compiler accepts them (`chan select makes its arms in order`, whose
`!chs[i]` and `!chs[1]` may be one channel, and
`select(a: !d.on_recv(), b: !d.on_send(2))`). The checker reads an arm
as holding the place of its channel to read until the select returns:
the select commits one arm alone, and only that arm changes its
channel, inside the select. A later arm that writes that place is
still rejected (`!chs[0].on_recv()` beside `grow(!chs)`). The backlog
records it for the owner.
