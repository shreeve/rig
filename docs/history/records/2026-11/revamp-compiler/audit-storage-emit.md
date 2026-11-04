# Audit: storage, facts, and emit (first half), phase 2

Read line by line: `src/storage.zig` 1-2329 (all), `src/facts.zig`
1-1486 (all), `src/emit.zig` 1-5909 (module and declaration writing,
witnesses and API tables, functions and prologues, scopes and names,
`hiddenStorage`, guards and drops, statements and temporary slots,
headers, bindings and assignments, control flow, loops, `match` in all
its forms, `as` heads). Base: origin/main `dd355f669`, its `bin/rig`
and `bin/rig-oracle`. Probes ran under `RIG_SANITIZE=1` with the oracle
(`rig-oracle -v`) beside each; they are quoted inline below (the
scratch copies are not tracked).

Summary: no program the ownership checker accepts used freed memory,
leaked, or double freed in about 30 probes over the plan's constructs
(hoisted selves and arguments, temporary slots in `defer`, held, taken,
and consuming headers, `match <x` alternatives and guards,
destructures, failing parts of `print`, `String(...)`, arrays and
assignments, held headers). The oracle agreed on every decided
function. Two accepted programs evaluate in an order the source does
not say (E1, E2). Emit makes two hidden storage locations no fact
names (E3), and the check INTERNALS says enforces that does not exist
(E4). The rest is North Star 4 residue, dead code, comments, and one
check-speed lead (storage is the largest pass).

## Findings

| ID | file:line | category | severity | finding | evidence | proposed fix | est. net LOC | risk |
|---|---|---|---|---|---|---|---|---|
| E1 | storage.zig:383 (`decideSelfHold`) | accept-correct (NS1, evaluation order) | medium | A call whose arguments are hoisted holds its self only when the self holds a `.call` or `.index` (or is a temporary a `!@` method writes). A self that can leave, `o?` or `o ?? return -1`, is evaluated where the call is, after every hoisted argument: the arguments' effects happen though the source leaves first (SPEC "Arguments are evaluated in the order written"; INTERNALS Calls). Memory stays safe: owned hoisted arguments are dropped by their flags (probe 3, clean). | Probe 1: `obj R` with `fun len2(?@, a: Int, b: Int)`; `fun go(o: R?) -> Int?  (o?).len2(b: say(1), a: say(2))`; `go(none)` prints `arg 1`, `arg 2`, then `-5`; source order prints only `-5`. Same for `(o ?? return -1).len2(b: say(3), a: say(4))`. Probe 3: `(o?).take(String("abc"), say(k)?)` with `o` none prints `arg 1`. Emitted: `const __rig_arg_1_0 = say(1); ... (rig.some(o) orelse return null).len2(...)`. Oracle accepts all. | Hold a self that can act or leave as well as one that indexes: `if (!contains(recv, &.{.index}) and !setActs(recv) and !(writes and temporary)) return null;` (`setActs` covers a call, a set, a drop, a panic, `return`, `?`, `!`, and the jumps). `reachesLeaf` then gives `.leaf` for an object self and `.value` for a scalar, both of which the planner and emit already handle. Add probe 1 as a `test` case. | +2 | low |
| E2 | storage.zig:2038 (`callParts`), emit hoisted call block | accept-correct (NS1, evaluation order) | medium | The callee of a call through a function value is never a hoisted part: when the arguments are hoisted (an owned argument before one that can leave, or a closure literal), a callee that acts is evaluated after them. Without hoisting Zig evaluates the callee first, so the order depends on whether some argument can fail. Same class as E1 and #917's arm channels: a part of a call that storage lists nowhere. | Probe 2: `fun pick(k) -> fun(String, Int) -> Int` printing `callee`; `pick(7)(String("abc"), say(3)!)` prints `arg 3` then `callee 7`; `fs[say(0)!](String("ab"), say(1)!)` prints `arg 1` before `arg 0`; `mkh().f(String("abcd"), say(5)!)` prints `arg 5` before `mkh`. Oracle: `unknown (an unusual callee)`. | Make a call's parts one positive list in storage, in written order: the callee when it is no name or member path and acts (`setActs`), else the self (`heldSelf`), then the arguments; record the callee as a part (`invoked`-like kind, life `call`, by `owned`) and have the hoisted block evaluate it first. Fixes E1 and E2 as a class. | +20 | medium |
| E3 | emit.zig:1660-1683 (`emitObjectCall`) | NS4 / hidden storage without a fact (#917 class) | low (latent) | A call through an API object writes `const __rig_obj_N = <self>;` (the self evaluated once) and `var __rig_res_N = rig.outPlace(O);` (a result through the caller's place) by hand, outside `hiddenStorage`, with no storage fact. Both hold values of the program; neither is poisoned under `RIG_SANITIZE`. Today each is a copy of a view or a handle that a slot or place keeps, or a value moved straight out, so no view can outlive it; but nothing checks that, and the checker never walks it. | `test/rig/emit-apis.rig.test:236` expects `const __rig_obj_`; grep of emit 1-5909 for `const __rig_`/`var __rig_` outside `hiddenStorage` finds only these two that hold a program value (the rest are flags, labels, counters, and compile-time names). | Record `self` (by copy, life call) and a `results`-like fact for `result_out` calls in `Planner.call`; name both through `hiddenStorage`, which also poisons them. | +12 | low |
| E4 | docs/internals/INTERNALS.md:1290, 1940 | docs claim no test (NS6) | low-medium | Both paragraphs say "the suite's `classify` check fails on" a classifier outside `handsOver` and on "a storage name spelled anywhere else". No such check exists: no `classify` in `test/rig.rip`, `test/cli`, or `tools`; it was a test kind of the old runner and went with commit `9651516a2` (2026-10-17). E3 is what slipped through. | `grep -rn classify test tools src` finds only unrelated names. | Either restore the two checks as `facts.zig` unit tests (tokenize emit.zig as the import test does: every string literal starting `var __rig_`/`const __rig_` must come from an allowlist of bookkeeping names, and `handsOver`'s kinds asked only in sema), or drop the two sentences. Restoring is about 30 lines and catches E3 now. | +30 | low |
| E5 | facts.zig:720-743, 760-767, 995, 271 | NS4 (facts give emit live classifiers) | low | `Facts` still answers node questions by calling a classifier when emit asks, not by reading a recorded decision: `isCatchAll`, `matchSelects`, `optionalBindsStringBytes`, `loopBindsStringBytes`, `hoistsResults` (`leavesAfterOwned`), `swapsTwoPlaces`, and `readsThroughWrite`, which decides how a binding of a write view is held inside facts.zig itself (`sema.lendByValue`). They agree with the planner today because both run on the final facts, and a disagreement on `hoistsResults` reaches `unsupported` rather than a wrong program; but none is in `verifyDecisions`, so "decided once" is by convention. review-ownership-emit §1g still true: the guard test forbids only `.pending.` and `moves(`. | Read of facts.zig in full; each method's body. | Add each as a `sema.Question` with its decider (the `decider` table takes one line each) and have Facts read `storage.decided`; move `readsThroughWrite` into storage as `binds_through_write`. Then the facts test can state the rule positively: a Facts method taking a node reads a recorded table. | +15 | low |
| E6 | emit.zig:2733-2737 (`copiesSubject`) | NS4 (derive, then assert) | low | review §1e still true: emit works out `hasTemps && !headerPoints` and fails if it differs from the recorded `copiesHeader`. The fact exists; emit should read it. Called from `emitFor`, `emitMatch`, `emitOptionalHead`. | Lines read. | Emit reads `facts.copiesHeader(node)`; the consistency check moves to `storage.plan` (or `verifyDecisions`), where the planner already computes `headerPoints` for each header. | -4 | low |
| E7 | emit.zig:2963-2995 (`emitBind`) | NS4 (pointer or copy decided in emit) | low | review §1d still true: `binds_view`, `copies`, `is_lend`, `holds_ptr`, and `is_var` are worked out from the type, the syntax, and an exception list (`writeSliceElem`, `callableFn`, `objectView`). `planHolds` already records `Symbol.hold` per binding; pointer-or-copy is the other half of the same fact. | Lines read. | Record `Symbol.bind = pointer / copy / value` in `planHolds` from the same predicate (storage owns it), and emit reads it. Fits in a small change because `planHolds` walks every symbol already. | +6 | medium (wide reach: every binding) |
| E8 | storage.zig:2193 vs emit.zig:3389-3400 + `divBuiltin` (11439) | NS4 (two classifiers of one fact) | low | Whether `x op= v` lowers to a call that assigns its result, so its place is held in `__rig_slot` once, is decided twice: `storage.assignsThroughCall` (+`laneChecked`) for the fact, and `emitCompound`'s `builtin` chain for the lowering. `divBuiltin` also reads emit's mode field `literal_ty`, which storage cannot see. They agree on every shape today (I checked each operator and type class by reading); a future operator added to one only turns into an internal error or an unused fact. | Lines read. | Record the lowering once (`compound_call: ?enum{rem, div, shl, lanes, mask, sat}`) in storage and have `emitCompound` switch on it. | 0 | low |
| E9 | sema.check:6224 (`storage.plan`) | check speed | low | Storage is the largest pass of `rig check` on bench/check's workload: 26.2 ms of 99.3 ms (best of 3; typecheck 19.5 ms), and 241 ms of 912 ms at eight times the size, so linear. A 1 s `sample` of the 8x run puts most of it in `Planner.walk`, which records `reaches_leaf` and `hands` for every node, and `verifyDecisions` then answers every recorded question again in every build. The `funcs` dimension alone: 31.5 ms of 118 ms. | `rig check --time` on `gen.workload()`; per-dimension runs. | Measure `verifyDecisions` gated on `self_check` (it is an assertion; one line), then whether `hands`, asked of every node, is cheaper as a dense per-node array than as a decision. Land only past the speed bar. | ~0 | low |
| E10 | facts.zig (Facts methods), emit.zig:4761 | dead code | low | Never called: `Facts.bindingAccess`, `isObjectSym`, `repoints`, `setHasFields`, `tableFill` (other passes call the sema functions directly); re-exports `facts.Answer`, `facts.ValueParts`, `syntax.eachGuardOperand`, `syntax.leavesBody`, `syntax.dataFields`, `syntax.Api`; `Emitter.subjectRereadable` (4761) and with it `syntax.subjectRereadable`. Unused parameters: `Facts.markerOf`'s `f`, `emitWitnessSelf`'s `call` (1695, `_ = call`), `writeParts`'s third (2404). | grep of every caller in src/ and test/oracle/. | Delete. | -45 | none |
| E11 | storage.zig:633-634, 1172-1173; emit.zig:1720-1724, 2599-2602, 5011-5013, 5461-5465, 981; facts.zig:646-647, 1149 | stale or detached comments | low | Doc comments left above the wrong declaration by edits: storage 633 ("The enum a `match` switches on", `matchedType`'s) above `armType`; storage 1172 (`setLeaves`'s) above `hoistsResults`, so `setLeaves` has none; emit 1720 (`emitRigName`'s) above `emitOwnApis`; emit 2599 (`emitTempSlots`'s) above `emitErasedSlots`; emit 5011 (`consumedPayload`'s) above `altsProng`; facts 646 (`payloadBindings`'s) above `payloadFieldOf`. Emit 5461-5465 says `addr` twice. Facts 1149 says "the bits of the object `sym`" over `wordSized(ty) bool`. Emit 981 is misindented. Emit's header (6-13) still says facts come "from sema's facts table (`sema.zig`)" and that a binding is `var` when it "holds a Cell or a value with drop glue"; INTERNALS Emit "Bindings" still says `sema.moves` (review §3, not fixed). | Lines read. | Move each to its declaration; reword the two headers to `Facts` and `Symbol.hold`. | 0 | none |
| E12 | (ownership / typecheck) | diagnostic | low | `match pick(?mk(k))` with a payload binding used in an arm draws two errors at one position for one cause: "this `match` reads the view its subject returns after its header drops the temporary" and "a view of the temporary `mk(k)` outlives its statement". | `fun pick(b: ?Box2) -> ?E from b`; `match pick(?mk(k))` / `.a(s, n) => print(s)`. | Report the header error alone (the second is its consequence). Outside this audit's files; for the ownership auditor. | -3 | low |

### review-ownership-emit §1, item by item

| Item | Still true? | Fixable without a rewrite? |
|---|---|---|
| a. "is this binding used" derived twice | No: emit's `Scan` is gone; emit reads `Facts.isUsed`, which `storage.plan` records once (`SemContext.used`). | done |
| b. built-ins by name text | Yes: `isNoneLeaf` (storage 74) and `printCall` (storage 89) by text with a symbol check; `isSwapCall` (emit 8582, outside this range). | yes, record `builtin_of(call)` where resolve binds names (small) |
| c. method lowering by name in emit | Yes, outside this range (emit 9459 and on). | yes, piecewise |
| d. pointer or copy for a binding | Yes (E7). | yes |
| e. derive then assert (`copiesSubject`) | Yes (E6). | yes, trivially |
| f. emit's own type predicates | Outside this range. | |
| g. facts guard a blacklist; Facts forwards classifiers | Yes (E5). | yes |

## Rules and restrictions stated in these files

| Rule (where stated) | Holds? | Judgment |
|---|---|---|
| Emit makes no storage that no fact names (storage.zig:11; INTERNALS Storage facts) | All but E3 in this range, and the Zig-rvalue exceptions weak-spots.md lists | Keep; enforce by a test (E4) |
| Arguments are evaluated in the order written (SPEC §Calls 1445; INTERNALS Calls) | Not for a self that can leave (E1) or a callee that acts (E2) when arguments hoist | Keep; fix the class in storage (E2's fix) |
| Each storage decision is made once and verified (`decide`, `verifyDecisions`) | For the 27 recorded questions; the live classifiers of E5 bypass it | Keep; extend to E5's |
| Emit decides nothing the checkers did not walk (facts.zig header) | Mostly; E5-E8 | Keep |
| The facts unit test guards the boundary | Only the imports and two substrings | Keep, and state it positively once E5 lands |
| A capture is storage only for a binding something reads, decided as emit does (INTERNALS) | Yes: one `SemContext.used` | Keep |
| A held header (`held_header`) is skipped where a task, closure, `raw` block, or a viewing result names the parameter (storage 1490) | Yes; probes with early `return` and growth in a loop are clean, and re-pointing a parameter is rejected | Keep |
| A header that copies a value made in it is rejected unless plain data (weak-spots, `rejectHeaderCopy`) | Yes on the probes | Keep |
| The suite's `classify` check (INTERNALS 1290, 1940) | Does not exist (E4) | Restore or delete the sentences |

## The biggest simplification that is not a rewrite

Give a call one list of its parts, in written order, decided in
storage: the callee when it acts, else the self, then each argument,
each with its hold. `selfHold`'s `contains(.call, .index)` test, the
select arm's `heldSelf`, and the planner's separate self and argument
records collapse into one walk that emit's hoisted block also walks,
and E1 and E2 cannot recur because no part of a call is evaluated
outside the list. With E5's classifiers recorded as questions,
facts.zig becomes reads of recorded tables plus type questions, and
its unit test can assert exactly that instead of a blacklist.
