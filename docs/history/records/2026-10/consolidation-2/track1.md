# Track 1: one classifier per fact, for Stages 3 to 5

Consolidation round 2, track 1 ([PLAN.md](PLAN.md)). For each item: the
paths that decide the fact, with their places on main 55a21e1b1, whether
they decide one fact, the case two paths split on, and what merged.
Probes: the session scratchpad's `track1/`, run with `RIG_OUT_DIR` there.

## 1.1 What crosses to a task

### The map

| Path | Place | Fact |
|---|---|---|
| `blockerIn`, through `crosses`, `crossingBlocker`, `localBlocker`, `taskBlocker`, `taskParams` | sema.zig:9885 | what in a type keeps it from going to a task, as it goes (moves or shares, local or any) |
| `boundBlocker` | sema.zig:9811 | a bounded or `pub` `T` whose bounds do not name `Sends`/`Syncs` |
| `atomicHandle`, `atomicReach` | sema.zig:9531, 9945 | a `*` whose count is atomic, and what it hands across |
| `frozenObject` | sema.zig:492 | a `*{A + Syncs}` holds a frozen value |
| `Checker.crossingTypeOf` | typecheck.zig:9157 | the type a task's or an actor's part crosses as (its erasure's object, a closure literal's view) |
| `Requirement.task` with `requireTask` | typecheck.zig:9122, 21066 | each instance's `T` goes as a value of a known type would (`taskBlocker`) |
| `holdsTask` | sema.zig:10050 | a value holds a task or a set of tasks |
| `Requirement.no_task` with `requireNoTask` | typecheck.zig:9134, 21065 | each instance's `T` holds no task |
| `lacks` for `Sends`/`Syncs` | sema.zig:7771 | through `blockerOf`, the walk above |
| the runtime's `synchronized` | runtime.zig:1729 | the count `atomicHandle` calls atomic: a word Cell (`isWord`: `i64`, `bool`, `f64`, an enum, as `isWordValue`), an actor, a channel; a frozen value through `Frozen`'s `always_atomic` |

Every site that sends a value to a task, an actor, or `par` calls
`crossingBlocker` (or `localBlocker`) and then `requireTask` with the
same type and crossing (typecheck.zig:8985, 8997, 13246, 13326, 13335,
13426, 13439, 13943, 13950, 14350, 15462): one walk, read twice, once
for the known type and once for each instance. `lacks(Sends/Syncs)` is
the same walk. `objectLack`'s `.shared` row and `frozenIn`'s read
`frozenObject`, the one decider of a `*{A + Syncs}`. No probe split
these: a channel, a Cell, or an actor of a task is refused at its make
(its values hold no loan), so no handle hides a task the crossing walk
does not see.

**Two paths, one fact: a value hidden from the rules that wait for a
task holds none.** Three places hid a value: an erasure to an API
object (typecheck.zig:15416), a value given out of `task.isolate`
(typecheck.zig:14010), and a capture of an owned closure
(typecheck.zig:17951). The first two checked the known type
(`holdsTask`) and each instance's `T` (`requireNoTask`), each with its
own copy of the check. The owned closure checked only the known type:
an instance's `T` holding a task was refused by the ownership checker's
loan rule (`checkViews`: "stores a `T` in ... an owned closure, which
carries no loan, and a view keeps what it views lent"), because a task
may hold a view. Stage 5 review 1 parked it (track 2, row 10): right
today, since every `Task` and `Tasks` may hold a view by type
(`reachOf`), but resting on that classifier, not the task rule.

### The case

`fun mk[T](x: T) -> *fun() -> Int` capturing `<x`, made as
`mk[Task[Int]]`, directly, through another generic body
(`outer[U]` calling `mk`), with the `T` in a field (`Hold[T]`), or in
`task.isolate`. On main each is refused by the loan rule; the two rules
agree on accept and reject in every probe (a `pub` generic must say
`[T: Owned]`, which a task lacks), so the split is the rule that
answers, which the parked review named.

### What merged

`Checker.hidesNoTask(at, ty, how, where)`, `how` one of `erased`,
`isolated`, `captured`: the known type through `holdsTask`, each
instance's `T` through `Requirement.no_task`. The erasure, `isolate`,
and the owned closure each call it; `requireNoTask` is gone, and
`taskWhy` gives the one reason ("its field `t` is a `Task[Int]`", or "a
`T` holds one") to the erasure's message and the instance's. Cases:
"apis object crossing a generic owned closure holds no task" (now the
task rule's message) and "... over a value holding its parameter holds
no task" (a field, through another generic body), both failing on main.

The oracle's `tests` floor falls from 22,796 to 22,794 (main decides
exactly 22,796): the two functions of the case on main (`sq`, `mk`)
were decided because the program reached the ownership checker, which
rejected it; it now stops in the type checker, before either checker
decides it, as programs rejected in sema do. No verdict changed.
