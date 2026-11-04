# Audit: types and effects (typecheck, cteval, inlining, proofs), 2026-11-03

Scope: `src/typecheck.zig` (22,971 lines), `src/cteval.zig` (2,063),
`src/inlining.zig` (1,473), `src/proofs.zig` (2,951), at revamp-c =
main a4e4ce6a8. Read with the 10-31 review (`review-types.md`) and
`evaluators-deferred.md`; nothing they settled or deferred is raised
again (the four evaluators, literal kinds by text, the 84 context
fields as a design, the frame walker's second model, the template
generic model, IR tag names).

## What was read

- typecheck.zig, closely: 1-135 (entry points, orphan comment), 2255-2280
  (`handleWritable`), 2440-2475 (`synthQuiet`), 2690-2725, 9800-9912
  (`swap`), 11975-12110 (closure inference trial, `argType`),
  13052-13371 (`synthMemberCall`), 14860-15640 (every hand-typed std
  form: `taskJoin`, `parCall`, `parWorkers`, `isolateCall`, `chanMake`,
  `taskSelect`, `armResult`, `httpServe`, `ioCopy`, the trial helpers,
  `parCapture`, `taskSetWait`, `waitOperand`, `spelledWait`,
  `cellListCall`), 17470-17500, 17565-17672 (lend bases), 18217-18232,
  19645-19670, 20210-20240. The rest by grep: every function's callers
  (dead-code scan of all 849 functions over src/, test/, tools/), every
  `quiet`/`tentative` site, every `catch false|null|{}`, vocabulary.
  About 3,000 of 22,971 lines read line by line; the rest not read.
- proofs.zig: 1-2228 in full (the pass, summaries, unit-order check,
  dump); 2229-2951 (unit tests) by name only.
- cteval.zig: 1-60, 405-684 (`Pure`, `markCalls`), 1254-1853 (the
  evaluator's statements and expressions); the rest by function index.
- inlining.zig: 1-60 and 1000-1473 (instances, guards, `valueOf`,
  `cutCycles`, `decide`); 60-1000 by function index.
- Docs: INTERNALS "Proven checks", "Generics", "APIs and API objects",
  "Compile-time functions" (not "Vectors"); SPEC §18 Channels; std/par,
  task, io, http headers; weak-spots.md and the end of backlog.md.

## Probes

All in `$TMPDIR/aud` with this worktree's `bin/rig`, `RIG_SANITIZE=1`.
About 25 programs: generic calls, errors through optionals, enums,
API bounds and boxed API objects, every std form (`par.map`/`each`/
`workers` with closures, names, generics, `limit:`; `task.isolate`,
`task.supervise`; `task.select` arms in both orders; captures), seven
proof shapes (record reads under a flag, while loops bounded by `n`,
mirror indexes, masks, `0..s.len / 2`) with `--facts=proofs` and a
failing flag, and compile-time arithmetic against run-time arithmetic
(`/ % >> << +% -% *% +| -| & | ^` on signed and unsigned, both signs).
Every proof the pass recorded held; the failing flag tested and
panicked where written; compile-time and run-time arithmetic agreed in
all 32 cases.

## Findings

| ID | file:line | category | severity | finding | evidence | proposed fix | est. net LOC | risk |
|---|---|---|---|---|---|---|---|---|
| T1 | typecheck.zig:15252-15257, 15277-15306 | wrong rejection | medium | `task.select` takes its result type, fallibility included, from the first arm alone (`result orelse armResult(first)`), and checks every later arm against it. So `select(a_arm(|v| v ?? 0), b_arm(|v| chk(v ?? 0)!))` is rejected ("use of `!` propagation requires a fallible enclosing function"), while the same two arms in the other order are accepted and run. SPEC §18 says only that all arms "give the same type", and a `T` meets `T!` everywhere else (typecheck.zig:15-23). Acceptance depends on argument order, and the message does not say the first arm fixed the type. | probe s4.rig (rejected), s5.rig (arms swapped: accepted, prints 7) | type each arm's closure quietly first (as `armResult` already does for the first), take the join (`T!` if any arm fails, sets merged by `waitSet`), then check every arm against it | +15 | low: one function; `test/rig` select cases pin the rest |
| T2 | typecheck.zig:14957-14967, 15054-15064 | diagnostics | low | `par.map` and `par.workers` build `List[value]` from a closure whose result is poison, so one error cascades: `par.map(?xs, \|x\| x + nope)!` also reports "`!` needs a fallible operand; this expression has type `List[invalid]`". A generic call of the same shape (`wrap(nope)!`) reports once; the hand typing skips the poison check `instantiateCall` makes. | probes s7.rig (two errors), s8.rig (one) | `if (self.isPoison(value)) return self.skipCall(args)` after `readValue` in both | +2 | none |
| T3 | typecheck.zig:15115-15168 | diagnostics | low | `task.supervise(f, restarts: 2, per: 1000, restarts: 3)` reports the duplicate and then "call to `task.supervise` is missing an argument for parameter `restarts`": the parameter list is built from the arguments as written (`names[1..]` from each kwarg), so a duplicate makes a third, unfilled parameter. | probe s3.rig (first version) | build the parameters from the fixed list `{f, restarts, per}` and pass only those given, or stop at the first duplicate | +3 | none |
| T4 | typecheck.zig:9871-9880 | diagnostics | low | `swap(!s, !t)` of two `![]Int` bindings says "`swap` takes a place lent to write: `!x`; got `![]Int`", though the user wrote `!s`. The real reason is that `!s` of a slice lends its elements, not a place. | probe p2.rig | for a `writeSliceElem` view, say that `!s` lends a slice's elements and name `!s.swap(i, j)` | +4 | none |
| T5 | typecheck.zig:18220-18223, 2697-2703 | dead code | low | `containsExpr` has no caller (the 10-31 review named it; still there). `writeCall` has no caller either (its sibling `writeCallText` replaced it). Scan of all 849 functions of the four files over src/, test/, tools/: these two are the only dead ones. | `grep -rw containsExpr src test tools`; same for `writeCall` | delete both | -11 | none |
| T6 | typecheck.zig:125-126, 13334-13336, 15354-15355 | stale comments | low | Three doc comments sit on the wrong declaration: the orphan at :125 (named by the review, still there); `apiMethodsIn`'s doc above `boundForMethod`, which then carries two docs; `namesForeignType`'s doc ("Whether `ty` is type `name` ...") above `ioCopy`, which then reads as one comment, while `namesForeignType` has none. | the lines | delete :125-126; move the other two onto their functions | -2 | none |
| T7 | typecheck.zig:14874-14876, 14918-14920, 15112-15114, 15224-15226, 15317-15319, 15362-15364 (and :13083-13088) | duplication; check speed | low | Each of the six std forms opens with the same three lines (`module_refs.get`, `foreign_semas.get`, compare `foreign.name` with a string), and `synthMemberCall` calls all six in turn for every `m.f(...)` of every module, so a call into `ast` or `checker` makes twelve hash lookups and six string compares before reaching `crossModuleCall`. | the lines; Trig's `rig check`: typecheck 664 ms of 2,008 ms total (load average 2.3) | one `stdForm(module_sym, name) ?StdForm` (an enum of the nine forms), called once; `synthMemberCall` switches on it | -20 | low |
| T8 | typecheck.zig:2270-2273, 2459-2466, 11989-11996, 14620-14671, 15280-15286, 15397-15408, 15471-15488 | duplication; trial side effects | low | Eight copies of the trial idiom (`mark`, `quiet += 1`, often `tentative += 1`, `defer` the decrements and `shrinkRetainingCapacity(mark)`), three of them (`isolateLambdaType`, `parLambdaType`, `armResult`'s inline block) checking a closure "quietly first as one that cannot fail, then as one that can". The idiom is where the review's persistent-side-effect concern lives; keeping one copy makes the guard rule one place to read. `armResult`'s second check (:15291) is not quiet and the arm is then checked again by `checkArgs`, so its body is typed non-quietly twice (diagnostics are deduplicated, so nothing shows). | the lines | one `Checker.trial(comptime f, args) struct{ value, clean }` and one `closureFallibility(f, params)` used by par, isolate, and select | -45 | low |
| T9 | typecheck.zig:14982-14994, 15076-15094, 15507-15512 (16 `crossingBlocker` sites, 12 `statedCrossing`) | duplication | low | The crossing check is written out each time: `crossingBlocker`, then `statedCrossing`, then an `errAt` with `blockerReason`, then `requireTask`. `par.map` has it twice, `par.workers` three times, `parCapture` once. | the lines | `requireCrossing(ty, how, at, what)` returning bool; each site keeps only its sentence | -40 | low: messages must stay byte-identical (`fail` cases) |
| T10 | sema.zig:5450-5625, with typecheck's 11 callers | duplication | low | Eleven special-call facts (the std forms, `Actor.supervised`, `xs.reduce`) are eleven tables, each with a `record*` and an `is*` (task_joins, chan_makes, select_calls, select_arms, supervise_calls, http_serves, io_copies, isolate_calls, par_calls, actor_supervised, reduce_calls; 30 lines in sema name them). A call is at most one of them. | sema.zig:5450-5625 | one `std_calls: Map(key, StdCall)` with `recordStdCall`/`stdCallOf`; emit switches on it (phase 2 file) | -70 | low: emit reads each; emit-diff must be empty |
| T11 | typecheck.zig:62-91, 97-123 | duplication | low | `checkModule` and `checkCtFun` each list the same fifteen `defer c.X.deinit` lines; a new map on `Checker` must be added to both or leak in one (the review named the duplication; the fix is not a rewrite). | the lines | `Checker.deinit()`, one `defer c.deinit()` in each | -14 | none |
| T12 | typecheck.zig:2272 | effects | low | `handleWritable` turns `error.OutOfMemory` from `requireAccess` into `false` ("not writable"): an allocation failure becomes a verdict, and a different diagnostic, instead of stopping the compiler. The two other swallowed OOMs (typecheck.zig:17578 `lend_of` memo, cteval.zig:337 dedup set) only lose a cache entry. | the line | `try`, and make the function return `Error!bool` | +1 | none |
| T13 | proofs.zig:1760-1765 vs 1850-1856; 1715-1717; 40, 1208, 1241 | duplication; stale comments | info | `Summaries.of` is `resultBoundOf` again, line for line. `walkDeclBody` only forwards to `Pass.walkBody`, which has the same signature. The header and two doc comments call the unit's entry facts `A(u)`, where INTERNALS ("Proven checks") and the rest of the file say `E - K(u)`. | the lines | call `resultBoundOf`; pass `Pass.walkBody` to `eachBody`; say `E - K(u)` | -8 | none |
| T14 | proofs.zig (whole pass) | soundness review | info, no defect | Read against INTERNALS' tables: each fact maker, each proof, the kill rules (`keeps_len` only for a write through a slice view or an element store; a List place keeps its length only for an element store), the loop head `L`, masks (`keepMasked` takes the smaller room), mirrors, `lo..b / c`, the three flag shapes, and result bounds (literals only, `u64` from text starting with a digit, so no negative). I found no proof that omits a check a run could fail. Writes the pass relies on that I checked are recorded: `swap(!s, !t)` of slice views is rejected (typecheck.zig:9875), a `?String` binding cannot be lent to write, closures need explicit captures, actors are not reentrant (concurrency.md, "Deadlock"). | probes pf1.rig (`--facts=proofs` and a failing flag), p1.rig, p2.rig, s9.rig | none | 0 | |
| T15 | inlining.zig:1095-1123, 1129-1190 | soundness review | info, no defect | `ruledOut` drops a call from an instance only when `valueOf` decides the `if` around it from literals, integer constants, and the instance's own value parameters (matched by declaration position). A wrong answer here would only miss a cycle's entry check (a task that recurses would not yield), not memory; I found none. The private evaluator stays deferred. | read | none | 0 | |
| T16 | cteval.zig:1689-1742, 1765-1797 | soundness review | info, no defect | `loopFor` reads both range ends once, as the run time does; a `.src` pattern with no symbol matches anything (`meets`, :1773), which is right only because `Pure.pattern` and typecheck admit no other bare pattern (a byte literal is rewritten to an integer first: probe c1.rig gives 2 and 3). Arithmetic is `sema.ctArith`, and agreed with the run time in all 32 probe cases. | probes c1.rig, c2.rig | none | 0 | |
| T17 | typecheck.zig whole file | check speed | info | On Trig (`tools/trig/main.rig`), `rig check` takes 2,008 ms, 27.6G instructions, 651 MB; typecheck is 664 ms of it, proofs 58, inlining 67 (load average 2.3, so not comparable to guard.txt). A 2 s `sample` puts 11% of self time in typecheck functions, none above 4.5% alone, and no quadratic walk of a body (`parentIn`/`isCallee` run per statement, only for a member whose object is a lend). bench/check's scaling exponents were 1.00-1.02 at baseline (ledger). Nothing here to fix beyond T7. | `/usr/bin/time -l`, `sample` | none | 0 | |

No critical or high finding. Vocabulary is clean in all four files:
"receiver" (276 in the review) is gone, "borrow" absent, "struct" only
as the IR tags the review deferred.

## Stated rules and restrictions

| Rule (where stated) | Where decided | Judgment |
|---|---|---|
| `task.select`: all arms give the same type (SPEC §18) | typecheck.zig:15252 | Keep the rule; decide the type as the join of the arms, not the first arm's (T1). |
| `par.map`/`each`/`workers` and `http.serve` take a closure written in the call or a function's name, not a closure binding (std/par.rig header) | typecheck.zig:15447, 15333 | Sound and needed: what a closure binding captures is not in its type, and every task reads it. |
| `task.isolate`: no `\|!x\|` capture, no capture holding a write view or a closure (std/task.rig) | typecheck.zig:15169-15190 | Sound (a panic drops half-changed frames); the messages name the alternatives. |
| `par.each` and `par.workers` need the elements lent `!` (std/par.rig) | typecheck.zig:14945, 15035 | Sound; consistent with Core sentence 4 (writes are marked). |
| `par.map` gives back no value holding a write view | typecheck.zig:14958, 15058 | Sound: it would outlive the task's lend. |
| A `?[]T` parameter takes a slice binding (`f(?s)`, `f(s)`) but not `?a[..]` | test/rig/types-slice.rig.test:3 | Pinned by a `fail` case on purpose; leave. |
| Compile-time functions: module level, plain values only (integers, `Bool`, plain enums, arrays), positive list `Pure` (INTERNALS "Compile-time functions") | cteval.zig:414-607 | Sound; limits (10M steps, depth 256, 32 x 8 MiB) keep `rig check`'s verdict machine-independent. |
| Proofs: facts only about `Int` locals and parameters of the walked body, places only slice views, Lists, and object field paths (INTERNALS "Proven checks") | proofs.zig:456-549 | Conservative and sound; no shape worth adding was seen on the probes. |
| A cycle of marked `inline` functions is an error | inlining.zig:842-886 | Sound: Zig cannot inline it. |
| `par.map` `limit:` 0 or negative means one task per worker | src/tasks.zig:911-926 | Accepted and defined at run time; std/par.rig says "by default one per worker" but not that 0 and negatives mean the default: a doc line, not a checker rule. |

## The biggest simplification that is not a rewrite

The nine hand-typed std forms (`task.all`, `isolate`, `supervise`,
`select`, `par.map`, `each`, `workers`, `http.serve`, `io.copy`) keep
their rules but not their plumbing: one `stdForm` lookup decides which
form a module call is (T7), one trial helper decides a closure's
fallibility for all of them (T8), one crossing check reports what may
not cross to a task (T9), and one `StdCall` fact replaces eleven sema
tables and their 22 accessors (T10). That takes about 175 lines out of
typecheck and sema, makes `synthMemberCall`'s module branch a single
switch, and leaves each form's own sentences and its `fail` cases
untouched, so the change is checked by `swarm test/rig.rip` alone plus
an empty `tools/emit-diff`. T1 and T2 then fall out of the shared
helpers rather than being patched per form.
