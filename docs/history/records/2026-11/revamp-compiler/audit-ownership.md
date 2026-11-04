# Audit: the ownership checker (src/ownership.zig), phase 2

Base: origin/main dd355f669 (phase 1 landed, #914-#926), worktree
rv-audit2, `bin/rig` and `bin/rig-oracle` built from it. Read only;
nothing tracked was changed but this file.

Read, line by line: `src/ownership.zig` 1-9158 (all of it: the state
and paths 1-650, the checker's fields and instance checks 650-1260,
diagnostics 1260-1560, vars, scopes, points, joins 1560-2210, loan
queries and liveness 2210-2475, declarations and statements 2475-2870,
the expression walk, places, carry 2870-3700, lend, move, clone, drop
3700-4630, implicit copies 4630-4915, bindings and assignment
4915-5390, calls 5390-6250, stores 6250-6480, closures 6480-6650,
return and origins 6650-7025, branches and match 7025-7540, loops and
jumps 7540-8000, defer 8000-8140, type helpers 8140-8630, helpers and
unit tests 8630-9158). Also read in full: docs/CORE.md; the review
records-2026-10/compiler-review/review-ownership-emit.md; the phase 1
ledger; docs/internals/weak-spots.md; test/oracle/differences;
INTERNALS "Ownership". Read in part: storage.zig (argument storage,
1700-2110), test/oracle/lower.zig (`and`/`or`, tasks),
docs/design/concurrency.md (tasks, actors).

About 70 probes, each run with `rig check`, `bin/rig-oracle -v`, and,
when accepted, `RIG_SANITIZE=1 rig run`. They are reproduced below where
they carry a finding.

## Findings

| ID | file:line | category | severity | finding | evidence | proposed fix | est. net LOC | risk |
|---|---|---|---|---|---|---|---|---|
| O1 | ownership.zig:3045-3051 (`walkList`, the operator arm, through `walkThenHeld`) | accept-unsound (North Star 2) | CRITICAL | The right operand of `and` and `or` is walked as if it always ran. Its effects stand on the path where it is skipped: a move there (`markInvalid`, which also drops the moved var's loans), and a take (`markNone`). So a value with a `drop` body that is "moved" in a skipped operand is still dropped at its scope's end at run time, after the checker let what it views be freed; and a take there records the field as `none`, so a later `p.f = x` drops nothing (`old_nones`) and the old value leaks. CORE §2 sentence 3 (an owner not moved drops where its scope ends) and sentence 6 (a drop body uses the views); CORE §5 (assigning drops the old value). | P1 (`and`, use of freed memory under RIG_SANITIZE=1; oracle: `DIFF main prod=accept ref=reject C4 cannot move a while a read loan of it is live`), P2 (`or`, same, oracle DIFF), P3 (leak of 33 bytes; the oracle does not model `old_nones`) | Walk the right operand as a branch, as `walkNullish` does: `base = here()`, walk it, `s = leave(base, past)`, `apply(join(stateAt(base), s))`. The left operand of `and`/`or` is a `Bool`, so the `holdRead` of `walkThenHeld` holds nothing there. The oracle already lowers it so (test/oracle/lower.zig:2567, "The right side runs only on some paths"). Add P1 and P3 as `fail`/`test` cases. | +10 | low |
| O2 | ownership.zig:7073-7090 (`walkIfBinding`: `failed` taken once, after `walkConditionParts` walked every part), 7787-7792 (`loopIteration`, a binding `while` condition) | accept-unsound (North Star 2) | CRITICAL | The same class in condition parts: `if a and b as x and c` takes its failure state after all parts, so the `else` path (and a `while`'s exit) carries the moves and takes of parts after the one that failed. INTERNALS' exit table already states the right rule (a failing part leaves for the construct's entry); the code joins one state, not one per part. | P4 (`if no() and take(<g) as k`, use of freed memory, oracle DIFF), P5 (`while`, with a `break`, use of freed memory, oracle DIFF), P6 (`if no() and <p.f as b` then `p.f = ...` in the `else`: leak) | In `walkConditionParts`, after each part take `exitTo(.{ .to = base, .resume_at = else })` and join the states; `walkIfBinding` and `loopIteration` use that join as `failed`/`exit`. The per-part exit also reports a binding's view escaping on the path where a later part fails, which the single exit already does. | +20 | low-medium (diagnostics of `as` bindings may move) |
| O3 | ownership.zig:2015-2020 (`reportDropped`, called by every `exitTo` with a `to`: each branch's `leave`, each join) | check speed | MEDIUM | It scans every var below the point (`hasLoanFrom` on each flow) on every branch exit, so ownership is quadratic in vars x branches. | A function of N statements `aK: List[Int] = List()` / `if aK.len > 0` / `print(...)`: N = 4k 13.5 ms, 16k 136 ms, 40k 754 ms of ownership (`rig check --time`); `sample` puts 98% of the time in `exitTo`. On bench/check's workload ownership is 11.0 of 98 ms (no branchy giant function there). | Skip unless some var at or above the point holds a loan's root, as `releaseVarsFrom` does (1616): `for (loan_counts[depth..]) n > 0`. Exact: every loan it reports, and every statement temporary `reportTempHolder` reports, is on a var at or above `depth`. | +3 | low |
| O4 | ownership.zig:2217-2227 (`findLoan`) | check speed | LOW | Each lend of a root that is lent scans every flow and asks `holderLive` of each holder, dead ones included, so N views of one List, each used once, cost N^2. | 16,000 `vK = ?base[..]` take 454 ms of ownership (4,000: 31 ms); `sample`: `exitTo` 58%, `findLoan` 41%. | After O3, keep per root the holders that carry a loan on it (maintained where `countLoans` is), so a query visits those only. | +30 | medium |
| O5 | ownership.zig:6908 (`checkOrigins`), 3603 (`carryAs`); sema's `from` check | wrong rejection; docs claim what does not run (North Star 6); two classifiers (North Star 4) | MEDIUM | concurrency.md:204-209 says a function may return `-> Task[T]`, "returned with `from`", the task keeping the loans its signature shows. Neither form is accepted: with `from v` sema rejects "`start` returns `Task[Int]`, which views nothing"; without it, ownership rejects "returns a view of `v`, but a call of it carries no loan of `v`: its type cannot hold what the result views". The checker's own `carryAs` treats a task as carrying every loan of its arguments, while the origins (`sema.defaultOrigins`, the `from` check) say a `Task[T]` holds none. | P7, P8 | The owner's call: either a task's type holds the loans of its call (so `sema.mayHoldView` and the origins agree with `carryAs`), or concurrency.md says a task holding a loan is not returned and the message says that. | small | low |
| O6 | test/oracle/lower.zig:3906 (task branch) | oracle gap (verification of North Star 2) | MEDIUM | The oracle accepts programs whose task keeps a loan the program breaks: `t = total(?v)&` then `!v.push(2)` then `>t` (P9), or `<v` before `>t` (P10), and a task of a local returned (P11). The compiler rejects all three, correctly, but its task-loan rules have no second checker: a regression there passes the suite silently. Not listed in test/oracle/differences because no test reaches these shapes. | P9-P11 (`stricter ... prod=reject ref=accept`) | Give the task's value its call's argument loans in the oracle's task branch, and add `# oracle:` cases for the three shapes. | +15 (oracle) | low |
| O7 | ownership.zig:1183 (`checkMethodCalls`, 16 rounds), 6434 (`selfViewIn`, 64 vars: `break` then null), 6400 (`absorbLoans`, `through.len > 16`: stop), 8358 (`genericStoreIn`, depth 16) | accept-unsound in principle | LOW | Four bounds that, when hit, stop the check and accept, unlike the loop fixpoint's backstop, which rejects ("this loop is too complex", 7748). None is reachable by a program in use; each would take a chain of 16 to 64 views or calls. The depth bounds elsewhere (`holderLiveDepth`, `carryLoan`, `ownsVar`) answer conservatively. | reading | Report "too complex for the ownership checker" where each bound is hit, as `walkLoop` does. | +12 | low |
| O8 | ownership.zig:5474-5482 (`heldForCall`, its `.argument` case), 5709; the header 30-33; `Var.call_held` 377-380 | dead code | LOW | Storage records an `.argument` only as `.owned` or `.pointer` (storage.zig:2066-2075, 1812), never `.copy`, so `heldForCall(_, .argument)` always returns null and the call at 5709 never holds anything. The comments still describe "a copied argument a call holds". | grep of every `record(..., .argument, ...)` | Drop the `.argument` path; `heldForCall` serves the self only; fix the three comments (and INTERNALS "Loans travel with values", if it says the same). | -8 | low |
| O9 | ownership.zig:612-624 (`Owning`), 8285-8314 (`kindLabel`) | needless complexity | LOW | The type names `Owning.drop_glue` and `Owning.unique` carry, and the loops `kindLabel` runs over arrays and optionals to find them, are never read: `reportAlias` (4839) and `captureFix` (4478) read only the tags `.shared`, `.weak`, `.unique`, `.generic`; `.list`, `.box`, `.text`, `.drop_glue` all print "owns a `T`". | grep | An enum `{ owner, shared, weak, unique, generic }`; `kindLabel` in about eight lines. | -25 | low |
| O10 | ownership.zig:6155 (`isSwapBuiltin`), 6225 (`isPrint`) | one classifier per fact (North Star 4) | LOW | Still decided by name text and "no symbol" (review-ownership-emit §1b); the `self.find("swap")` fallback is gone. Sema records `swapsTwoPlaces`, and storage `printCall`. | reading | Read the recorded facts (`ctx`'s print and swap facts) here too. | -10 | low |
| O11 | ownership.zig:21, 691, 3393, 5995 ("struct"); 8270-8271; 609 and 4652; 4296; 9148 | vocabulary, stale text, misleading diagnostics | LOW | "struct" names a Rig object four times. An orphaned doc sentence ("A List (or a view of one) whose elements move ... walked by a view of each slot") heads `owningKind`. `loop_view_rule` says a loop view "cannot be cloned", but `+x` of one is accepted (P12), and the binding message says it "would carry the viewed handle" for a `String` element. `movePayload` says "(partial moves are not supported)", which CORE §5 contradicts (fields move like names, built; `match <h.e` works, P13). `article` sits after the unit tests. | P12, P13, reading | Reword; move `article` up. | 0 | none |
| O12 | ownership.zig:2767 (`isStmtTempVar`), 2774 (`stmtTempAt`), used by `selfLeaves` 6051 and 6072 | a fact keyed by position | LOW | A statement temporary is found by its start position, which nested made values share (`mk().f().g()`). It picks the right one only because the outermost is held last (post-order); a self whose own temporary is not held would get its inner value's. Latent: both end with the statement. | reading | Key them by node id, as `part_temps` already is. | 0 | low |

Probes (each `sub main()` is the whole program after the declarations):

```text
P1  obj Guard / items: []Int / drop(!@) print(@items.len, @items[0])
    fun no() -> Bool  false ;  fun take(g: Guard) -> Bool  true
    a = List[Int] with 41, 42 ; g = Guard(items: ?a[..])
    ok = no() and take(<g)
    <a ; (allocate 64 Ints) ; print(ok)
    -> accepted; at main's end g's drop body reads a's freed buffer:
       "error: rig: use of freed memory" (RIG_SANITIZE=1)
P2  P1 with `fun yes() -> Bool true` and `ok = yes() or take(<g)`: same
P3  obj P / f: String? ; p = P(f: String("original long string for the heap"))
    ok = no() and eat(<p.f) ; p.f = String("replacement ...") ; print(ok, p.f)
    -> "memory leak detected: 1 allocation (33 bytes)"
P4  P1 with `if no() and take(<g) as k` (take -> Int?) / print(k) / else <a ...
P5  P1 with `while no() and take(<g) as k` / i += k / break ; then <a ...
P6  if no() and <p.f as b / print(b) / else / p.f = String("replacement ...")
    -> leak; the emitted store is `__rig_slot_3.* = __rig_new_3` with no drop
P7  fun start(v: ?List[Int]) -> Task[Int] from v / total(v)&   (rejected by sema)
P8  the same without `from`                                      (rejected by ownership)
P9  t = total(?v)& ; !v.push(2) ; print(>t)     compiler rejects, oracle accepts
P10 fun spawn() -> Int / v = ... / t = total(?v)& / <v / >t   same
P11 fun start() -> Task[Int] / v = ... / total(?v)&           same
P12 for x in ?v / !w.push(+x)   accepted;   for x in ?v / y = x   rejected with
    "... cannot be cloned, moved, dropped, or stored"
P13 h = H(e: E.a(s: String("x"))) ; match <h.e / .a(s) => eat(<s)   accepted, runs clean
```

### Probed and sound

Each of these was accepted only where it should be, ran clean under
RIG_SANITIZE=1 where accepted, and the oracle agreed or abstained:

- moves out of views: `if o as x` then `<x` (type error), `<p.a` through
  `?Pair`, a `match` payload, a loop view, a box;
- partial moves: in a loop, in one branch, reassigned in a branch,
  below a moved field, then used whole, returned, captured, matched;
  `match <h.e`;
- loops: a move seen by the next iteration, a view kept across passes,
  `continue` and `break` states;
- closures: `|?v|` against a write, a callable view returning a capture's
  view past its scope, `|!w|` of a write view, a closure's result
  viewing a capture, stores through two captures, a parameter's view
  stored through a capture;
- `once` closures: moved captures, a callee that never calls it (no
  leak), a bound closure passed twice (rejected);
- calls: `keeps` missing (rejected at the store), a generic `T = ?String`
  stored through `!List[T]`, `id[T]` returning its argument's view, a
  view of a by-value `T` stored in `!List[?T]`, owned and generic
  function values that may store;
- tasks: `f(?x)&` against a write and a drop, a write-loan task in
  `Tasks`, a task in an object field (sema), a task of a local returned,
  a set outliving a block's value, `(!a).log(?line)&` of an actor;
- actors: a method returning a view of state, or of its argument;
- `select`: a send's view (channels hold no loan), a move in a loop arm;
- chains: `collect` of views of a capture, of `zip`'s second list, of a
  slice per item, `find` past its block;
- #924 conditional bindings: a made value bound and moved out, a view of
  a header temporary, `?o as b` against a reassignment, in a loop, `<o
  as b`;
- API objects: an erased copy of plain data, pushed per iteration, chosen
  by a call, escaping a block;
- evaluation order: `print(v.len, grow(!v))`, `pair(p.n, bump(!p))`,
  `[q.n, bump(!q), q.n]`, `String(...)`; a move before a failing later
  argument (`f(<g, h(n)!)`, an object literal, `String(<g, h()!)`): no
  leak.

### The review's §1 and §3, as they stand in this file

- §1b (built-ins by name): `isPrint` and `isSwapBuiltin` are still by
  text (O10); the `self.find("swap")` fallback is gone.
- §3 "the checker without sema": resolved. `Checker.sema` is no longer
  optional, and the unit tests run sema first (`checkWithSema`).
- §3 "its own name resolver": still (`names`, `find`, 17 uses), as
  deferred; hidden vars are named by `spanText` of made values, never an
  identifier, so they never shadow a user's name.
- §3 vocabulary: "receiver" is gone from the file; "struct" remains
  (O11).
- §1d-1f are emit's and are not in this file. The one decision the checker
  makes for emit, `old_nones` (whether a field's old value is `none`, so
  its store drops nothing), is the fact O1 and O2 make wrong; it is
  recorded once, and AND-ed over every walk, which is the right shape.

### Every place that orders or bounds by a source position

`extent` (1323: a hidden leaf past the file's end stands at its node's
span start, the #922 fix), `stepAt`, `resumeAt`/`resumeBefore`,
`stmtStart`/`stmtEnd`, `liveFrom`/`loopStartFrom` (a loop's start by
`extent`), `holderLiveDepth` and `useAhead` (last-use and walked
positions), `indexUses` (records a leaf's raw `pos`: a hidden leaf past
the end only makes its symbol live longer, which is conservative),
`useBranchesAfter` (a branch before its condition), `inTwoArms`,
`noteInvalidated` (reads the source byte before a wait, guarded by
`f.at <= source.len`), `reportArmView` (scans the source from a loan's
position; clamped), `ownerCallee` and `callWithCalleeAt` (diagnostics
only), and the statement temporaries keyed by start position (O12). None
of the others decides a fact from a made-up position: every position
that bounds a scope or a statement goes through `extent`.

## Stated rules and restrictions

| Rule or restriction (where) | Judgment |
|---|---|
| The right operand of `and`/`or` and a later condition part always run (implicit, 3045, 7078) | Wrong: O1, O2. |
| "a `for x in ?list` element ... cannot be cloned, moved, dropped, or stored" (609) | The rule is the known prod-strict difference for `y = x` (CORE §2 sentence 1 copies a read view); "cloned" is false (P12). Reword now; the binding rule is the owner's, already listed. |
| "closures cannot escape their defining scope" (6508) | CORE §7; keep. |
| "a guard cannot move a value" (typecheck) | Sound, needed: a later arm matches the same value. Keep. |
| "cannot move-capture view parameter" (4237) | CORE §7; a move capture of a `?fun` parameter is a known prod-strict difference. Keep. |
| A write view never a type argument (990, 1022) | CORE §5; keep. |
| Two `task.select` arms cannot both hold a place to write (1473) | Follows from every arm being made first (CORE §2 sentence 5); keep. |
| A loop that takes 100,000 rounds is rejected (7739) | Right shape for a bound; O7 asks the four others to do the same. |
| A path is cut at `max_path_fields` (182) | Only adds conflicts; keep. |
| A `defer` body cannot move, drop, or move a field out (8031, 8035, 5317) | CORE §7; keep. |
| An owned closure captures no view (6535) | CORE §7, §9; keep. |
| `<p.f` only of a field reached through fields a local owns (4402) | CORE §5; keep. |
| "(partial moves are not supported)" (4296) | Stale wording; CORE §5 built them (O11). |
| A function returning a task that holds a loan is rejected (6908, sema) | Contradicts concurrency.md (O5); the owner's call. |
| `checkLostTasks`: a fallible task dropped at a scope's normal end (8118) | concurrency.md "Misuse the checker rejects"; keep. |

## The biggest simplification that is not a rewrite

Make short-circuit evaluation one primitive: a "this part may not run"
branch (`here`, walk, `leave`, `join` with the state before), used by
`and`, `or`, each condition part, and already by `??`, `catch`, and the
ternary. Today each construct that can skip code builds its own exit
states, and the two that do not (O1, O2) are where the checker and the
oracle disagree on accepted programs. With that one helper the exit
table in INTERNALS gains one row and loses none, `walkIfBinding` and
`loopIteration` share their failure handling, and the effects the
checker records for emit (`old_nones`) follow from the same joins.
Beside it, collapsing `Owning` to its tags (O9) and dropping the dead
argument hold (O8) remove about 35 lines with no change in behavior.
