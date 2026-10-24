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

## 1.3 The erasure

### The map

| Path | Place (main 55a21e1b1) | What it erases |
|---|---|---|
| `lendView` with `LendStep.erase` (the lend table, `sema.lendsAs`) and `Checker.erase` | typecheck.zig:15137, 15223 | a value lent as a `?{A}` or `!{A}`, through the table's rows (`.lift` into `T?`, `.optional`, `.unbox`, `.handle`) |
| `eraseBox` | typecheck.zig:15270 | a `^T` (or `^T?`) moved into a `^{A}` (or `^{A}?`) |
| `eraseShared` | typecheck.zig:15298 | a `*T` (or `*T?`) moved into a `*{A}` (or `*{A}?`), a frozen value's only into `*{A + Syncs}` |
| `handleThroughView` | typecheck.zig:15360 | rejects a view of a handle lent as a view of an object's handle |
| `erasable` | typecheck.zig:15388 | the checks every erasure makes on the hidden value (witness, task, bounds) |

All four are tried from one place, `checkActual` (typecheck.zig:15029),
against the type the context gives. Each read through an optional on
its own (the lend table's `.lift`, and a copy of the same peel in
`eraseBox`, `eraseShared`, and `handleThroughView`), and none read
through a `!`.

### The case

A binding of the object's type and a function's result split: `s:
^{Shape} = ^Square(...)` erases, but a function returning
`(^{Shape})!` whose last expression is `^Square(...)` was "type
mismatch: expected `^{Shape}!`, got `^Square`" (Stage 5 review 2,
parked; track 2, row 5). So were `return ^Square(...)`, `make()!` of a
`-> ^Square!`, a `*Square` or a frozen handle into `(*{Shape})!` or
`(*{Shape + Syncs})!`, a `?Named` lent into `(?{Shape})! from s`, and a
`^Square?` into `((^{Shape})?)!`. A `(^{Shape})?` result erased already.

### What merged

`Checker.erasureTarget` is the one place an erasure reads through a
`!`: for a value that is no `T!` (nor an error value), the type the
`T!` holds, when it holds an object; `checkActual` passes it to all
four. `heldInto` is the one peel of an optional for a box and a
counted handle, which `eraseBox` and `eraseShared` shared as copies.
Cases: "apis object box a fallible result erases its last expression
and return's operand" (a box, `return`, `f()!`, a view lent, a `^T?`),
"apis object shared a fallible result erases its last expression" (a
counted and a frozen handle), and "... keeps the erasure's rules" (a
frozen handle into `(*{Shape})!` is refused as where a `*{Shape}` goes).
Each ran under the sanitizer.

## 1.6 An iterator's item

### The map

| Path | Place (main 55a21e1b1) | Fact |
|---|---|---|
| `sema.iterItem` | sema.zig:8368 | the one classifier of iterators: not one, one whose `next` has another shape, or one of `item`, the `T` of `next(!@) -> T?`; the loop, `lacks(Iter)`, and `I.Item` read it |
| `sema.iterLack` | sema.zig:8400 | the `[I: Iter]` instance rule: `iterItem`, plus a view is no iterator and a `next` private to another module is not called; the loop says both too (probed: `for x in !w` of another module's private `next`, and of a view, are refused as `iter.count(!w)` is) |
| `rig.IterItem(I)` | runtime.zig:1155 | what emit writes for `I.Item` in a generic body: the payload of `I.next`'s result, read as `@typeInfo(...).optional.child` |

The runtime read the item a second time, by Zig's `?T` alone. A Rig
`T?` is Zig's `?T` only when `T` has no niche: an object with a `Bool`
or enum field, or one that names its none (`none id == 0`), holds its
`T?` as a struct (`rig.Opt`, routed by `sema.optionalRouted`), whose
payload `rig.Payload` reads.

### The case

`fun first[I: Iter](it: !I) -> I.Item?` over an iterator of `Flag`
(a `Bool` field) or of `Id` (`none id == 0`): accepted on main, then
"access of union field 'optional' while field 'struct' is active" in
Zig at `rig.IterItem`. A `for` loop over the same iterator, and
`iter.count`, which never names `I.Item`, ran.

### What merged

`rig.IterItem` reads the payload through `Payload`, the runtime's one
reading of either optional, so it gives the `T` `sema.iterItem` gives
for every `T?` emit writes. Case: "iter an item whose optional holds
its none in the item" (std-iter), failing in Zig on main.
