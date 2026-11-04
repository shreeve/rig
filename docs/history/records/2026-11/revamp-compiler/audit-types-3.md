# Audit: types and effects, third pass (typecheck 11500-22971, inlining 60-1000), 2026-11-03

Scope: `src/typecheck.zig` 11500-22971 and `src/inlining.zig` 60-1000 at
revamp-c = main a4e4ce6a8, after the first pass (`audit-types.md`, T1-T17)
and the second (`audit-types-2.md`, U1-U13); neither's rows are repeated
(U4, `collect` of views at typecheck.zig:14561, lies in this range and is
theirs). Nothing the 10-31 review settled or deferred is raised again
(the frame walker's second model, the template generic model, the
private inlining evaluator, the context fields as a design).

## What was read

- typecheck.zig, line by line: 11500-11974, 12105-13052, 13371-14860,
  15640-17470, 17500-17565, 17672-18217, 18232-19645, 19670-20210,
  20240-22971 (the first pass's spans 11975-12110, 13052-13371,
  14860-15640, 17470-17500, 17565-17672, 18217-18232, 19645-19670,
  20210-20240 were not read again). That is generic inference
  (`instantiateCall`, `inferBindings`, `bindArg`, `bindSet`, conflicts
  and hints), constructors and field arguments, named nones, API calls
  (`objectCall`, `iterNextCall`, `apiMethodCall`, `apiShorthand`,
  `apiNameCall`, `typeParamCall`, `typeParamResult`), actors
  (`actorMake`, `frozenMake`, `actorSupervised`, `actorCall`),
  `noteTarget`, `noteMethod`, the element methods (`elemsCall`,
  `reduceCall`, `sumCall`, `prefetchCall`, `bytesCall`), chains,
  `associatedCall`, `inferTypeArgs`, `crossModuleCall`, the self sigil
  and self-mode rules, `checkExpr` to `checkActual`, `lendView`, the
  erasures, lasting lends (`keptLends`), `sliceArgRejected`,
  `arrayAsSlice`, `mismatch`, `checkContextual`, `recordLift`,
  `LendBaseFix`, `writeLendRead`, literal typing and fits, error-set
  patterns, `List(...)`, builtins and casts, closures and captures,
  `meets`/`compatible`, generic requirements, frame owners and the
  frame walker, method calls at instances, stated forwards, headers,
  APIs and conformances, `satisfies`, and the unit tests.
- inlining.zig 1-1000 line by line (the header, `Pass`, `collect`,
  `mentions`, `target`, `calls`, the memo `settle`/`compute`, `fits`,
  `fit`, `uninline`, `forcedCycles`, Tarjan's search), and 1300-1473
  (`decide`) for the guards that call it.
- Docs: INTERNALS "What an expression hands over", "Header subjects",
  "Proven checks" (start), "Tables", "What crosses to a task"; SPEC
  "Generic functions" (inference order), "Generic sets", "An object
  that names its none", §14 Modules, §18's crossing table, the API
  crossing rules, shifts.

## Probes

About 45 programs in `$TMPDIR/a3`, run with this worktree's `bin/rig`
and `RIG_SANITIZE=1`: keyword and positional arguments to plain and
generic functions; inference through `?T` with `String`, `?String`, and
`Static`; generic sets bound by named functions and by closure
literals, with and without an expected result; calls on unbounded and
bounded `T` (read, write, `??`, `!`); API calls by shorthand, by name,
through a box and with `<` self; `*Actor`, `*Actor.supervised`, and
actor calls with lent, given, closure, handle, and API-object
arguments, written and implicit; `reduce` with closures, named
functions failing with a set, and an owned `String` accumulator; `sum`,
`swap`, `fill`, `copy` (lengths), `bytes.read/write` at constant and
huge run-time offsets; chains with `enumerate`, `zip`, `map`, `max`,
and a closure using `?`; closures inferred with `return`, fewer
parameters, `|!m, +n|` captures, path captures across a nested closure;
`List(...)` of literals, slices, and `?String`; named nones by variant
and qualified variant; `raw` casts of literals; shifts by constants and
run-time amounts; marked `inline` functions used as values and called
from their own closures. Every accepted program printed the right
answer or panicked where SPEC says it panics, except as the rows say.

## Findings

| ID | file:line | category | severity | finding | evidence | proposed fix | est. net LOC | risk |
|---|---|---|---|---|---|---|---|---|
| V1 | typecheck.zig:13871-13879, 13899-13900 | diagnostics (compiler crash) | high | `*Actor(x, mailbox: 4, mailbox: 8)` crashes the compiler: the kwarg loop accepts any number of `mailbox:`, and `params[0..args.len]` slices a 2-element array with 3, "panic: index out of bounds: index 3, len 2" in `actorMake` (bin/rig is ReleaseSafe; a fast build would read past the array). North Star 1: a mistake is a Rig diagnostic, never a crash. | probe act1.rig | count `mailbox:` and reject a second ("`mailbox:` is given twice"), or build `params` from the names given, as `actorSupervised` does | +4 | none |
| V2 | typecheck.zig:14051-14076 (`actorCall`), with 9461-9472 (`crossingTypeOf`) and 16330-16342 (`lendView`) | accept-means-correct; one classifier per fact | medium | An actor call's argument crosses by `typeOf(arg)`, which for a bare value lent where a `?T` parameter goes (`lendView` records `Lend.implicit`) is the value's type, not the view's, so it is checked as moving, not as shared. `c.peek(Holder(j: ^Sum(...)))` to `fun peek(?@, h: ?Holder)`, where `Holder` holds a `^{Job + Owned + Sends}`, is accepted and runs; `c.peek(?Holder(...))`, the same lend written, is rejected ("`?Holder` holds `{Job + Owned + Sends}` ... no `Syncs`, so no two tasks may read what it hides"). SPEC §18's table: a `?T` crosses only when `T` syncs. Task spawns do not have this gap (`peek(h)&` is caught by the kept-lend rule). | probes a5.rig (accepted, prints 4), a6.rig (rejected) | let `crossingTypeOf` return `?T` for a part whose recorded lend is implicit (`ctx.lendOf(part).implicit`), so every caller reads the one fact | +3 | low: `crossCheck`'s callers read it too; their `fail` cases pin them |
| V3 | typecheck.zig:14048 (`actorCall`), 14282 (`reduceCall`); default at 11092 (`CallSite.origins = .{}`, sema.zig:2853-2861 `stores = all_params`) | wrong rejection; diagnostics | medium | Two hand-typed calls pass no origins to `checkArgs`, which then assumes the call stores every argument, so a bare place lent to a view parameter (Core sentence 1) is rejected with a false reason: `d.peek(p)` through an actor, for `fun peek(?@, h: ?Plain)`, says "`d.peek(p)` keeps `p` lent in what `peek` stores; write `d.peek(?p)`", though `actorCall` itself refuses any method with `keeps` or `from` (:14041); `xs.reduce(0, g)` with a closure binding `g` says "keeps `g` lent in what `reduce` stores", while `run(g)` to a `?fun` parameter is accepted. `reduce` keeps nothing of `f`. | probes a4.rig, r1.rig (rejected), r2.rig (`run(g)` accepted) | `actorCall`: pass `.has_self = true, .origins = m.field.origins` (after V2, so an implicit lend crosses as shared); `reduceCall`: `.origins = .{ .stores = 0 }` | +3 | low; land with V2, never alone |
| V4 | typecheck.zig:13993-14004 (`actorSupervised`) | diagnostics | low | The sibling of T3 in another function: `*Actor.supervised(f, restarts: 2, restarts: 3)` reports the duplicate and then "call to `Actor.supervised` is missing an argument for parameter `restarts`", since `names` is built from the arguments as written. | probe p1.rig | stop at the first duplicate, or build the parameters from the fixed `{make, restarts, per, mailbox}`; one helper with T3's fix | +3 | none |
| V5 | typecheck.zig:12418-12430 (`bindArg`, `.read_view` pattern) | wrong rejection | low | A `?T` parameter given a `Static` binds `T = Static`, so `keep(String("own"), "lit")` for `fun keep[T](a: T, b: ?T) -> T` is "conflicting types for `T` ... `String` (argument 1) and `Static` (argument 2); they must have one type", while `keep[String](...)` is accepted. The rule just above admits a `?String` there (`inf.viewing`, "a `?T` meets the read view of the `String` that `T` is"), and a `Static` is read as the `?String` it is (`meets`, :19757). The hint suggests no brackets. | probe g2.rig | set `inf.viewing` for `at == .static` too, so it binds as a `?String` does | +1 | low |
| V6 | typecheck.zig:12795-12812 (`checkNoneArg`) | diagnostics | low | A constructor given an object's none as a qualified variant, `Slot1(kind: Kind.empty)` for `none kind == .empty`, is not rejected when checked: only a bare `.empty` is compared. SPEC "An object that names its none": "A constructor given it as a constant is an error". It panics at run time instead (`rig.notNone`). | probe n1.rig (panics) | compare a `Kind.name` member path too (its variant name and type), or the variant `sema.patternConst` gives | +4 | none |
| V7 | typecheck.zig:18817-18827 (`listFromElems`) | diagnostics | low | `b: List[?String] = List(["p", "q"])` is rejected (sound: the List's type may hold a view), but the fix it gives, "push a copy of each element, `!xs.push(+x)`", makes a `String`, which a `List[?String]` does not take. | probe l1.rig (first version) | for a view element type, say to push each element, `!xs.push(x)` | +2 | none |
| V8 | typecheck.zig:14844-14846, 17032-17033, 19836, 19895-19897, 20097-20098, 21444-21450, 21992-21993; 19864-19865 | stale comments | low | Seven more doc comments sit above another function's doc, which then reads as one comment, while their own function has none (the class of T6 and U7): `cellListCall`'s above `waitSet`'s, `checkContextual`'s ("A form whose type comes from context") above `byteString`'s, `cellListElement`'s above `inIndex`, `stringOrBoxed`'s above `sliceArgLend`'s, `resultCall`'s above `isJumpNode`'s, `apiOf`'s and `ownershipApi`'s both above `reachedValue`'s, `fieldLacking`'s above `taskWhy`'s; and a double blank line. | the lines | move each onto its function | 0 | none |
| V9 | typecheck.zig:13841, 14090, 16801, 22044, 19175 | needless parameters; stale text | low | Four parameters every caller passes and the body discards (`_ = method` in `typeParamResult`, `_ = obj_ty` in `actorCall`, `_ = is_self` in `reportKept`, `_ = ctx` in `providerMethods`); `requireNamed` records the operation as `"@name"`, a spelling Rig does not have (`$name`), which no message prints today (`.named` has its own wording, :21222-21225). | the lines | drop the four parameters; write `"$name"` | -8 | none |
| V10 | typecheck.zig:22155-22158, 22190, 22683-22827; inlining.zig:871; 85 uses in src/ | Zig 0.17 | info | `std.mem.indexOf`, `indexOfScalar`, `indexOfScalarPos`, `lastIndexOf`, `lastIndexOfScalar`, `indexOfPos` are deprecated aliases in Zig 0.17 (installed std/mem.zig:1292, 1305, 1482: "Deprecated in favor of `findScalarLast`"...), beside `find*` everywhere else in the same files (29 uses in typecheck, 85 in src). | `grep -c 'std\.mem\.\(indexOf\|lastIndexOf\)' src/*.zig` | rename to `find`, `findScalar`, `findScalarPos`, `findLast`, `findScalarLast`, `findPos` | 0 | none |
| V11 | typecheck.zig:14690-14694 (`sumCall`) | wrong rejection | low | `xs.sum()` of a `[]T` with `T: Num` is "`sum` adds numbers ... the elements of `[]T` are `T`": `numeric` admits only `.int` and `.float`. SPEC: `sum` adds "a List of numbers ... each as `+` adds", and `Num` gives `+` (SPEC's API table). | probe sm.rig | admit a type variable whose bounds give `Num` (`boundsGive`), recording `.numeric` for an unbounded one as `+` does | +4 | low |
| V12 | emit (found by probe; outside the range read) | diagnostics | info | A left shift by a run-time amount at or over the width panics with Zig's own message, "integer does not fit in destination type" (`@shlExact(..., @intCast(...))`), not a Rig one; SPEC says it panics, so the behavior is right, the text is not Rig's. | probe m3.rig | test the amount before the cast, with a message as `<<`'s constant check gives ("shift amount `9` is out of range for `U8` (0..7)") | +3 | none |

No critical finding. Inference, constructors, API calls, closures,
captures, the element methods, chains, the erasures, the frame walker,
and inlining's guards held on every probe beyond the rows above.
`inlining.zig` 60-1000 decides soundly: a function used as a value is
never rule-inlined (`mentions` over every module, a member by its name's
whole group), a marked one used as a value is rejected in typecheck,
`compute` reads `own.?` only of a function `decide` inlined because
`own` was known (:1440), and a cycle through a closure is a frame of
its own (probe inl1.rig runs). Dead-code scan of every function the
ranges declare over src/, test/, tools/: only `containsExpr` (T5).
Vocabulary is clean: no "borrow", "receiver", or "struct" for an
object.

## Stated rules and restrictions

| Rule (where stated) | Where decided | Judgment |
|---|---|---|
| An actor's value is an object or enum that moves and holds no view; `mailbox:` alone besides it (SPEC §18, std/task) | typecheck.zig:13869-13907 | Sound; V1 is a crash on a duplicate, not a rule problem. |
| A handle calls `?@` bare and `!@` marked, never `<@`, never a method with `keeps` or `from`; arguments cross, the result moves and views nothing | typecheck.zig:14020-14093 | Sound as written; V2 and V3 are where the arguments are read. |
| `*Actor.supervised` takes an owned closure written in the call, of no parameters, that cannot fail; its captures move to the actor's tasks | typecheck.zig:13943-14009 | Sound (an owned closure's view capture is refused, probe s1.rig). |
| An unbounded `T`'s method result takes its type from context; through `!` it is taken to fail with any error, so a method failing with a declared set does not fit (SPEC "Generic functions") | typecheck.zig:13823-13862, 21394-21398 | Stated and consistent (probe t2.rig rejects it as SPEC says). A future relaxation could take the instance's set where the body only propagates; not a defect. |
| `reduce`: a failing `f` makes the call fail with any error (SPEC) | typecheck.zig:14274-14308 | Sound (probe p3.rig); V3 is its kept-lend reason. |
| `sum` adds the elements of a List, array, or slice of numbers | typecheck.zig:14683-14706 | Extend to a `T` bounded by `Num` (V11). |
| `copy` needs equal lengths, checked when the program runs (SPEC) | runtime `rig.copy` | Two arrays of known different lengths (probe cp1.rig) could be rejected when checked, as a constant out-of-range index is; optional. |
| `List(...)` copies plain data: no element type that may hold a view | typecheck.zig:18817 | Sound; only its hint is wrong for a view element (V7). |
| A closure's inferred result: a captured write view of a copy is the value; a read view stays a view | typecheck.zig:19364-19372 | Consistent with functions (`|?m| ... m` gives `?Int`, so `return 7` mismatches); leave. |
| A marked `inline` function is only called, never a value; a cycle of them is an error | typecheck.zig (value rejection), inlining.zig:842-883 | Sound. |
| The rule inlines at most 60 nodes, 64 KiB per owner, 320 expanded nodes | inlining.zig:68-87 | Constants with their reason written; the T15 review stands. |

## The biggest simplification that is not a rewrite

The calls typecheck types by hand (the actor forms, `reduce`, `sum`,
`get`, the std forms of T7-T10) each call `checkArgs` with a
`CallSite` they assemble themselves, and two of them forget the
origins, so `checkArgs` falls back to "stores everything" (V3), while
`actorCall` re-derives how each argument crosses from its type instead
of from the lend `lendView` recorded (V2). A `CallSite` built by one
constructor from a `FunctionType` and an explicit `Origins` (no
default), and a `crossingTypeOf` that is the only reader of how a part
is passed (written lend, implicit lend, closure literal, erasure), make
both faults impossible to write again, with about the same line count:
the default goes, each of the 15 hand-typed `checkArgs` sites without
origins today (typecheck.zig:13203-15651) names its
origins in one argument, and `actorCall`'s loop shrinks to the
crossing check `crossCheck` already performs for tasks.
