# Row 33D, expert review: the compiler

Read against main ad5d9b043 (the read-only checkout `~/Data/Code/worktrees/rig/core-33d-read`;
line numbers are from that tree). Probes ran with its `bin/rig` and `bin/rig-oracle`
(`check`, `emit`, and `run` with `RIG_SANITIZE=1` on the Mac), in
`/private/tmp/claude-501/core33d-expert/p/`. Nothing was built.

## Summary

The direction is right and the size is about right, but the plan has one soundness hole, names
the wrong fact for the read point, misdiagnoses two of its three classes, and gets the gain and
guard lists partly wrong. In order of weight:

1. **Emit evaluates "pure" parts last, so a binding's last use is not where it stands.** A
   hoisted call, a hoisted array, and an assignment skip a part `storage.isPureArg` calls pure
   (a fixed local of any type included) and evaluate it at the consumer, after every other part.
   An unheld assignment evaluates its target's base before its value. Statement-long liveness
   hid this; ending a binding at its walked use opens a use after free that the oracle accepts
   (probes `pure2.rig`, `purearg2.rig`, section 3.1). The plan must hold such a part's loans until
   its consumer finishes.
2. **The read point is `sema.readsThrough` (the recorded `reads` fact), not `readsAsValue` or
   `copies`.** Emit reads a view of plain data at the operand (`rig.eql(r.*, ...)`), and the
   checker already ends a read-through operand's or argument's loans there (`copiedOut`, 2759):
   `add(first(?v), bump(!v))` and `addI(firstI(?w), bumpI(!w))` are accepted today and run clean
   under the sanitizer. So d3 is not a guard; it becomes accepted, as do the three
   `int.eq_then_write.*` lines (now `ref-gap`) and the core-gap line p74.
3. **(B) needs the walked loans kept somewhere.** Once a binding is dead after its walked use,
   its loans live only in the `Value` the walk returns, and many consumers discard values
   (`walkReadArgs` 7665, `walkIndexOf`, `walkThenHeld`'s later operand). The binding's use must
   put its loans in `temps` (the rule `holdMoved` (4053) already applies to `<x`), so that
   `temps` holds every in-flight value's loans and the one consumption rule is the only way out.
4. **(C) is not the hidden `hold` var.** `walkMatch` clears it when an arm is chosen (7065). The
   loans that reach the arms are the subject's `temps`, which `walkMatch` shrinks only for a lent
   subject with a root (7022; `walkAsMatch` 7154). `match firstr(?v).n` with `!v.push` in an arm
   is rejected today though its subject is an `Int`. The fix is two lines.
5. **t05 is a loop-liveness issue, not a statement one.** `LoopCtx.start` is the `for` node's
   first position (7432), so a binding last used in a `for` header counts as used on every pass:
   `for x in a.arr` with `!xs.push` in the body is rejected with no branch and no held value.
   It belongs in its own row, with a run test (section 3.4).
6. **The walked-use set must be scoped to one walk of a statement.** As written ("a set of walked
   positions"), marks survive into the next fixpoint round and the final reporting walk, where a
   use not yet reached looks walked. That accepts `print(poke(!v), x.n)` inside a loop.

## 1. The kinds of `temps` entries, and where each must survive

`temps` (749) is today "loans the current statement keeps that no var holds", and every entry is
truncated at the statement's end (`walkStmtValue` 2551). The consumption rule replaces "statement
end" with "end of the node that consumes the value", keeping entries below the node's start
untouched. That stack discipline matters: the self reservation, `place_hold`, and `held_read`
entries are removed by index (`reservation` 5408, 5521; `mark` 3230, 3270, 5344, 5861), which
stays right only if a node's end filters entries at or above its own start and keeps their order.

| Entry | Added | Must survive until | Notes |
|---|---|---|---|
| A lend's loan (`?x`, `!x`) | `lendVar` 3582 | the consumer of the lend's value; a call's end for an argument the call holds | also carried by the `Value` |
| A moved value's loans (`<x`) | `holdMoved` 4053 | the consumer of the moved value | the model for (B) below |
| `place_hold` | 3228, 3268, 5342 | its walker's end (indices of a place found before they run) | removed by index, stack-scoped |
| Self reservation (`reserved`) | 5351 | the call's start, then the call's end | removed and reinserted by index |
| `held_read` | `holdRead` 5765, `holdBranchLeaf` 5847 | the consumer (call, operator, index) | only for `sema.readByAddress` values |
| An argument's write loan | 5475 | the call's end | a write view a method's result keeps |
| A result's loans re-added | `endWriteLends` 3419, `keepViewTemps` 3427 | the consumer of the result | the in-flight-value role |
| A stored write lend | kept by `endWriteLends` (`stored`) | the statement's end, as now | the callee may store where no var records it |
| `walkSwapCall`'s two lends | 5922-5948 | the swap's end | saved and restored around the second |
| A deferred body's result loans | `runDefers` 7773 | the deferred body's end | scoped |
| A header's subject temps | `walkMatch` 7001, `walkAsMatch` 7138 | the header's end (see 4 above) | today kept through the arms unless lent with a root |

Loans that are *not* in `temps` but are statement-scoped are held by hidden vars, which
`holderLiveDepth` (2228) calls live always:

| Hidden var | Where | Life |
|---|---|---|
| Statement temporary | `holdTemp` 2566, `holdPartTemps` 2584 | to the statement's end, dropped by `dropStmtTemps` |
| Call-held storage | `holdForCall` 5225 | the call's end (`endCallHeld`) |
| The call's results | 5703 | the destructure's targets |
| An erased copy | 2711 | its scope |
| `walkMatch`'s `hold` | 7029 | cleared at each arm's start (7065) |
| An arm's var | 7254 | the arm |
| A header's held base | `holdBase` 6914 | the construct's scope |
| A `for`'s element loans | 7561 | the loop |

The draft's rule shrinks only `temps`, so an owning temporary without a `drop` body still keeps
its views to the statement's end through its hidden var: `n = mk(?v).len + grow(!v)` with
`mk -> List[?Int]` is rejected by main and accepted by the oracle (`owntemp2.rig`), and stays so
under the draft. CORE sentence 6 allows it. Either take it (a statement temporary's hidden var is
live while a loan on it is in `temps` or a live var, or while its drop runs a `drop` body: the
`holdsPastDrop` rule, 2191) or list it as out of scope with a `known: true` case. I would take it
here: it is the same class as (A), and about ten lines in `holderLiveDepth`.

**Is "temps shrink to what the node's value carries, plus what something else holds"
implementable without missing a holder?** Yes, with three conditions:

- Every use of a binding whose binding may die in the statement puts the loans it carries in
  `temps` (a `holdMoved` at `walkName` 2965 and at a lend through a binding), so the invariant is
  "`temps` holds the loans of every value in flight". Without it, (B) loses loans wherever a
  consumer drops a `Value`, and the draft's "a call holds its arguments' loans" only covers
  `walkCallBody`'s own argument loop, not `walkReadArgs` (print, `String`, panic), `walkIndexOf`,
  or `walkThenHeld`.
- The rule is applied at the consumer's end to entries at or above the consumer's start, never
  below, and keeps order.
- The exceptions are named, not inferred: `stored` lends (statement end), the reservation,
  `place_hold`, `held_read` (their walkers end them), and the parts emit evaluates at the
  consumer (section 3.1).

Folding `endWriteLends` and `keepViewTemps` into the rule is right: they are the rule for one
consumer each. `copiedOut` (2759) is the rule for a read-through operand and should be named so
too.

## 2. The walked-use set for (B)

It is the right mechanism, and the "last source position walked" alternative is rightly rejected
(`stmt if cond` walks the later cond first). A count of unwalked uses per symbol is not simpler
in practice: it breaks when a use is walked twice (fixpoint rounds of a loop nested in the
statement), while a set is idempotent. What the draft must add:

1. **Scope the marks to one walk of a statement.** Push a mark on `walkStmtValue` entry and
   truncate at its exit, after `dropStmtTemps` (which asks `holdsPastDrop`, so the statement's
   uses must still read as walked there). Loop bodies, `while` conditions (`walkStmt` 7506), and
   steps are walked as statements each round, so each round starts with no marks. Otherwise, in
   `x = ?v[0]` then `print(poke(!v), x.n)` in a loop, the final walk finds `x.n` already marked
   from an earlier round and accepts a use after free.
2. **Ask every statement on the walk stack, not just the innermost.** `cur_stmt` is the innermost
   statement, so today a binding used in an enclosing statement before the nested one counts as
   dead there (`liveFrom` 2254). `after_value` covers an assignment's target; anything else that
   runs after a nested statement but sits before it in the source would not be. With a stack of
   marks, "live while any enclosing statement has an unwalked use of it in its extent" covers
   both. Nested statements' marks are dropped at their exit, which errs toward live for the
   outer statement: safe, and it costs nothing on the planned gains.
3. **Don't count a binding's own declaration leaf, or a plain assignment target, as a future
   use.** `indexUses` (2154) notes every leaf with a symbol, including `it` in `o as it` and `x`
   in `x = ...`. An unmarked declaration leaf in the enclosing `if` would keep `it` live through
   its body and lose c1. Count uses at positions after the declaration, or mark binding leaves as
   they bind.
4. Keep `after_value`, `defer_used`, `step_at`, and `loopStartFrom` as they are. They answer
   jumps, deferred code, and loops, which a per-statement set doesn't see.
5. Uses never walked (unreachable code, a rejected call's arguments, type positions) stay
   unmarked, which errs toward live. That is safe.

Branches are fine with one set: a then-branch's marks carry into the else-branch, but no position
lies in both. `print(poke(!v) if c else x.n)` stays rejected (the then-branch is walked while
`x.n` is unmarked). That's conservative, and the oracle accepts it.

Closures: a capture is a use at the literal (`indexUses` notes the origin there), and the
closure's `Value` carries its captures, so the rule holds. Match arms, blocks, and `catch`
handlers are nested statements and fall under items 1 and 2.

Cost: `holderLiveDepth` runs inside conflict scans. Keep per-symbol use positions sorted
(built once by `indexUses`) and the marks a small sorted list per statement frame, so each query
is a binary search per stack frame. Measure `rig check --time` on Trig before landing (row 33A).

## 3. Evaluation order

### 3.1 Where emit evaluates a part later than the checker walks it

`storage.isPureArg` (179) calls a part pure if it is a literal, a constant, a function, a fixed
local (of any type), or a view or move of a name. Emit then skips it when it hoists and
evaluates it at the consumer, after the hoisted parts:

- a hoisted call, `emitHoistedCall` (emit.zig 9719; `storage.hoistsArgs` 270): keyword arguments
  out of order, a lent closure, an argument that can leave after an owned one;
- a hoisted array, `emitHoistedArray` (emit.zig 7086);
- a held assignment's value and indices, `openAssign` (emit.zig 3192, 3247);
- an unheld assignment (`SetOrder.held` false, storage.zig 1084): Zig finds the target, base
  first, before it evaluates the value. `storage.eachSetStep` (976) says "value first, in the
  order it runs", and the checker walks it so (`walkSet` 4696). The storage comment's claim that
  "no program can tell" the orders apart holds only while the value's views last the statement.

Both forms below are rejected today only because the binding lives the whole statement. The
oracle accepts both, so it will not catch a regression.

`pure2.rig`: `rb =! ?u[0].b` and then `slot(!u).b = rb`, where `slot` pushes 100 elements and
returns `!v[0]`. Emitted (with `v` in place of `u` so that it checks):

```zig
const rb = &u.constSlot(0).*.b;
(rig.rt(slot(&v))).b = rb.*;
```

The base `slot(...)` runs before `rb.*` is read. With `u`, the draft walks `rb` first, ends it,
and accepts the program, and emit reads `rb.*` from the buffer `slot` freed.

`purearg2.rig`: `print(f(b: rb, a: grow(!v)))` with `rb =! ?v[0]` and `f(a: Int, b: Box)`.
Emitted (with `u` for the lend):

```zig
rig.print(.{ rig.rt(f(rig.rt(grow(&u)), rb.*)), "\n" });
```

`rb.*` is read after `grow`. The draft's "a view argument is used until the call returns" would
not save it, because `rb` here is read through (a `Box` parameter), and a read-through argument
ends where it stands (`copiedOut`).

**Required:** a part that `isPureArg` passes over in a hoisted call or array, the value and pure
indices of a held assignment, and the value of an unheld assignment are used at the consumer.
Their loans stay in `temps`, narrowed to read where they only read, until the call, array, or
store finishes. The checker reads `storage.hoistsArgs`, `storage.isPureArg`, and
`storage.setOrder`, which are recorded facts, so emit decides nothing new and `tools/emit-diff`
stays identical. (The alternative is to narrow `isPureArg` so that a fixed local read through a
view held as a pointer isn't pure. That changes emit, so emit-diff would differ. I prefer the
checker-side rule.) Add `fail` guards for both shapes, and for the keyword-argument and array
forms.

### 3.2 The operand read point

Emit reads a view of plain data at the operand, not at the operator:

```zig
rig.print(.{ rig.eql(r.*, rig.rt(bump(&b))), "\n" });     // r: ?[3]Int
rig.print(.{ rig.eql(rp.*, rig.rt(pokep(&q))), "\n" });   // rp: ?P, P plain
const r = a;                                              // r = ?a with a: Int: a copy at the binding
```

Zig evaluates arguments left to right and `r.*` is a by-value copy. I checked this on the Mac:
`print(firstI(?w) == Item(n: bumpI(!w), ...))`, where `bumpI` sets `w[0].n = 7` and pushes 1000
elements, is accepted today and prints `true` under `RIG_SANITIZE=1` and `--release`. So the
copy is taken before the later operand runs (`uaf1.rig`). I did not check x86-64's self-hosted
backend; pup was out of bounds for this review.

The fact the checker should read is the one it already reads: `sema.readsThrough`
(`facts.reads`, recorded only by typecheck's `readOf`, typecheck.zig 17571; consumed by
`walkUnerased` 2747 and `copiedOut`). `rig check --facts=sema` shows `reads leaf "r"` in
`r == bump(!b)` and `reads leaf "w"` in `w == a` for `[3]Int`, and no `reads` for a `print`
argument such as `print(first(?v), ...)`. `readsAsValue` is a type predicate (scalar or plain
enum) and doesn't decide where a value is read. Using it would make the checker disagree with
its own `copiedOut`, which today accepts:

```rig
print(add(first(?v), bump(!v)))        # accepted today; sanitizer-clean; prints 7
print(addI(firstI(?w), bumpI(!w)))     # accepted today
```

With `readsThrough` as the classifier:

- **Newly accepted:** the 8 `*.eq.write_view` / `*.eq.destructure_write` lines, including
  plain and array (the draft's own rule, "a view of a plain object, array ... is kept as a view",
  would keep the 4 plain and array lines rejected, contradicting its gain list); d3
  (`r == bump(!a)`, so it moves from guard to gain); the 3 `int.eq_then_write.*` lines,
  currently `ref-gap` "compiler right"; p74 (`print(id(?s).n, bump(!s))`, `core-gap`).
- **Still rejected:** a2 and every `*.arg_then_write.*` line (a `print` argument is not read
  through, so it is a view argument held until `print` returns), b2 (a String view isn't read
  through), and every by-address read (`holdRead`).

The `eq_then_write` and p74 lines are owner decisions, because the differences file cites Core
§6 for them. But CORE §6's sentence ("a value an earlier argument reads stays lent until the
call returns") already isn't what's built for copied values: see `add(first(?v), bump(!v))`
above. The honest wording is "reads in place". I recommend accepting them and fixing the
sentence.

### 3.3 Forms audited and in order

| Form | Emitted | Order |
|---|---|---|
| `print(a, b)`, `String(a, b)`, `!t.add(a, b)` | `rig.print(.{ a, b })`, `rig.String.of(.{...})`, `t.add(.{...})` | left to right |
| `o ?? r` + later | `(blk: { var __rig_v = opt(&b); ... } orelse r) + pokev(&b)` | in place |
| `e catch r` + later | inline labeled block with `catch`, then `+ pokev(&b)` | in place |
| `x if c else y` | `@as(T, if (c) x else y)` | cond, branch |
| `stmt if cond` | `if (cond) stmt` | cond first, as walked |
| keyword arguments (non-pure) | `const __rig_arg_0 = r.x; const __rig_arg_1 = grow(&u); two(arg1, arg0)` | source order |
| a temporary in a later operand | `x.n + rig.keep(&__rig_tmp, ..., mk(&v2)).*.at(0)`; only the `var` declaration is hoisted | in place |
| an assignment that acts | `{ const __rig_new = r.x; (slot(&v)).x = __rig_new; }` | value first, as walked |
| a held index | `__rig_new`, then `__rig_ix`, then the store | as walked |

The oracle orders keyword arguments by source too (`kwx.rig`).

### 3.4 t05

`for x in (a if c else b).arr` emits `for (@as(*A3, (if (c) a else b)).arr) |x|`. Accepting a
write to `xs` in the body needs two changes: a `for`'s `LoopCtx.start` after its source (7432;
a `while` condition does run each pass, so only `for`), and the `holdBase` var (6914) no longer
always live. The sanitizer must also show that Zig copies a `for` operand read through a pointer
before the body runs. No test exercises that today, because every such program is rejected.
Simpler probes show the first cause alone: `for x in a.arr` with `a = !xs[0]` and `!xs.push` in
the body is rejected, and accepted with the push after the loop (`t05b.rig`, `t05e.rig`). Give
it its own row.

## 4. Self-checks and diagnostics

- The `headerTempLoan` assertion in `walkFor` (7377) compares the source's returned `Value` with
  `stmt_drops`. It reads neither `temps` nor liveness, so it is unaffected.
  `storage.verifyDecisions` is storage-only, and the checker-side rule in 3.1 changes no
  decision.
- The other `self_check` in ownership.zig (1692, binding hold versus storage plan) doesn't
  involve loans.
- Reports driven by liveness (`reportTempOutlived` in `dropStmtTemps` and `walkMatch`,
  `reportCallHeld` in `endCallHeld` 5251) can only fire less often.
- `carryLoan`'s internal error (3437) is about var scope, not `temps`.
- The crash risk is the index bookkeeping in section 1 (the reservation and `held_read` counts),
  if the consumption filter ever touches entries below a node's start. Assert that in
  self-check builds.
- Every change makes live sets smaller (temps entries and bindings), so nothing accepted today
  is rejected, provided the binding-use entries of section 1 last no longer than the statement.
  But `fail` cases with several errors may lose one, or have their note move, and `fail` checks
  each error given. Expect churn in error lists in `ownership-misc-1` (42 conflict cases),
  `ownership-param`, and probes-12/17/21/24/30/32/34/35/36/38.

## 5. Size, risk, test areas

ownership.zig, net:

| Piece | Lines |
|---|---|
| Use positions per symbol, the marks stack, the query in `holderLiveDepth` | 50-70 |
| Binding uses into `temps` | 10-15 |
| One consumption helper, used by `walkMember`, operators, constructors, `walkCallBody`, `walkReadArgs`, folding `endWriteLends` and `keepViewTemps` | 40-70, about 20 removed |
| Pure parts held to the consumer (3.1) | 25-40 |
| Header subject temps (C) | 2-4 |
| Statement temporary liveness (owntemp2) | about 10 |

That totals about 140-210 lines, in line with the draft's 150-250. Drop the oracle work (60-100
lines): the risk class here is emit's order, which the oracle (written from CORE) cannot see, and
it already accepts both 3.1 programs. Guard with compiler `fail` cases and sanitizer-run `test`
cases instead.

The differences file loses the draft's list (minus t05), the 4 plain and array eq lines it
mis-sorted, the 3 `int.eq_then_write.*` lines, p74, and whatever else the oracle reports FIXED.
Watch 224 (`f(!vs) catch !vs`), 255, 256, 209, and 210. About 25 cases: one per consumption form
(operator, call, method, constructor, field copy-out, `??`, `catch`, branch, `print`, `String`,
`add`), one per pure-part form (hoisted call, keyword arguments, array, held and unheld
assignment) as a `fail`, plus the guards a2, b2, a stored lend, a `drop`-body temporary, a
temporary's view past its statement, the loop-round case of 2.1, and accepted siblings run under
the sanitizer.

Areas: `ownership-*` (match, header, results, view, views, write, receiver, misc-1/2, param),
probes-22 and probes-26 (v07 becomes a `test`), `test/oracle/differences` and `rejections`, and
CORE's doc examples (sentence 6 and §6's `print(v, grow(!v))`, which stays rejected: a List is
read by address).

Risk is moderate to high, and it sits in 3.1 and 2.1. Both are silent use-after-free paths that
the oracle accepts.

## Answers to the draft's open questions

1. **Is the order the statement runs the order the checker walks?** No, in four places: pure
   parts of hoisted calls, pure parts of hoisted arrays, held assignments' pure value and
   indices, and unheld assignments (target first). Everywhere else audited, yes (3.3).
2. **(C) in this row?** Yes, but it is the subject's `temps` (2-4 lines), not the `hold` var.
   t05 is separate.
3. **Oracle §6 here?** No. It can't see emit's order, and §6 as CORE words it isn't what the
   compiler builds for copied values.
4. **CORE clause?** Sentence 6's addition is fine. §6's "a value an earlier argument reads"
   should say "reads in place", or the owner keeps the `eq_then_write` and p74 lines rejected
   and the checker must then stop accepting `add(first(?v), bump(!v))`, which is worse.
