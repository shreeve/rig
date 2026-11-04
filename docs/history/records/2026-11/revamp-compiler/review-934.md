# Review of PR #934 (rv-tasklend)

I found no soundness hole. I tried 45 probes against main (8b3549a3a) and
the branch, running both checkers. Every program the branch accepts ran
clean under `RIG_SANITIZE=1` with `RIG_SEED` 1..20. `swarm test/rig.rip
concurrency-task` passes: 129 jobs, none died. Probes are in
`$TMPDIR/r934/*.rig`, with runner `p.sh`.

## Rejected by both checkers, correctly

- returned task, then the source written, moved, or dropped (a5, a8)
- task of a task, `wait_it(<t)&` and `Task[Task[Int]]` (a6, b10)
- method `?@` returning a task, then the object moved (a7, f8)
- task-returning generic (f7); a task made in a closure (f6, f3)
- `par.map` over a function that returns a task (f5)
- a sub that moves a task into a set, checked at its caller (b3)
- a task bound to a variable declared before its source, then given a
  view of that source (g3-g7)
- a write task that leaves through `if` values, `!@` / `@m()&`, or
  rebinding (c4, a3, a3b, b14)
- an actor or a channel holding a task, even one with no loans (c6, f2)

The legitimate uses of a write task's name still pass: `>t + 1`, `>t!`,
`>t catch`, `<c.cancel()`, `>d` in both arms of an `if`, and
`time.within(d, |<t| >t!)` (e1, b1).

## Issues

1. **MEDIUM (docs and release notes): the PR fixes main soundness holes it does not list or test.**
   Main accepts these programs, and the branch rejects them:
   - d1 and d1b: a local object holding a read task, `j = Job(t: total(?xs)&)`, then `!xs.push` or `<xs` before the wait. Main runs d1b to the wrong answer: it prints `0` where the right sum is `3`, because the task reads `xs` after `<xs` dropped it. `RIG_SANITIZE` does not catch it.
   - d5: `o: Task[Int]? = total(?xs)&`, then `!xs.push`.
   - b4: `*Job(t: total(?xs)&)` cloned, then `!xs.push` while the clone lives.
   - f4: `t = time.within(d, |?xs| total(?xs)&)`, then `!xs.push`.

   **Fix:** add a `fail` case with `# oracle:` lines for each shape to `test/rig/concurrency-task.rig.test`. Add an *Unsound:* item to CHANGELOG "Upgrading" (near CHANGELOG.md:316) and a row to `docs/MIGRATING-0.3.md:659`. The PR body's "Rejected now" list should name them.

2. **LOW (release notes): sound programs main accepts are now rejected.**
   The rule matches CORE sentence 7 and the new concurrency.md text, but neither the CHANGELOG nor the Trig note lists it.
   - c17: `fun start(v: ?List[Int]) -> Task[Int]` whose task does not read `v`. The caller now keeps `v` lent, so a later `!xs.push` is rejected.
   - d2: a method `fun spawn(?@) -> Task[Int]` now needs `?b.spawn()` at the call, and the task keeps `b` lent.

   No `from` form says "views nothing". The corpus check found none of these programs.

   **Fix:** list the rule in CHANGELOG "Upgrading", item 72 or a new item, and in the Trig note.

3. **LOW (oracle, pre-existing class): the compiler accepts what the oracle rejects.**
   `t = call(|?xs| total(?xs)&)`, with `fun call(f: ?fun() -> Task[Int]) -> Task[Int]`. The compiler accepts it, and the oracle rejects it: "C5 a loan of a temporary outlives its statement" (f3ok, h2).

   The same DIFF exists on main for plain views, `call(|?xs| xs)` (h1), so it is not this PR's bug. The PR does make it reachable for tasks and objects. A test of this shape would fail the suite.

   Tasks cannot be lent a closure: `runit(f)&` is rejected (g2). So the result never views the closure, and the compiler's acceptance looks sound.

   **Fix:** settle the class separately; the oracle should keep a lent closure's captures, not the temporary.

4. **LOW (oracle coverage): the oracle decides no Tasks-set flow.**
   It abstains on every `!ts.add(...)` flow ("a method reached through a handle") and on generic stores ("a generic instance at a view"), in b3, b9, f4, and f8. So the PR's set cases have no second checker. O6 asked only for P9-P11, which are covered.

## The two new rejections

- **Cell.** `*Cell(...)` of a task, a `Box[Task]`, a `List[Task]`, `Job?`, or a generic `Cell[T]` with `T = Task` is rejected (e2-e5). concurrency.md says no shared home holds a task, so I found no legitimate program caught.
- **`break t` of a write task.** It is caught, and the legitimate uses above are not (e1, b1).

## Over-approximation

Within concurrency.md, "a task as able to view anything" causes no wrong rejection beyond item 2:
- a sub that takes `!Tasks[Int]` and a `?String`, and adds a task with no loans, is accepted, and its caller is free to write the String afterwards (c15);
- the same holds for `!List[Job]` (c16);
- a sub that moves a task with no loans into a set is now accepted (b3ok; main rejected it).
