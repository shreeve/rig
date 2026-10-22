# Core audit: loans, control flow, shared storage

Read-only audit, 2026-10-02.
- **Scope:** Core sentences 5, 6, 7 and 9, and the §8 fact "lives for the whole program".
- **Code:** main at `dd36c78` (`bin/rig`, run as `RIG_SANITIZE=1 bin/rig run`), and the strings branch at `../rig-text` (`59e7bed`).
- **Probes:** in `probes/loans/` (String probes in `probes/loans/text/`).
- **Check results:** one line per probe, in `probes/loans/results-check-main.txt` and `results-check-rig-text.txt`.
- **Line numbers** are in `src/ownership.zig` on main.

---

## 1. Unsound on main (ranked first)

All four are accepted by `rig check`. All four fail at run time under the sanitizer: three as use of freed memory, one as a read of a dropped Vec. All four are **rejected on rig-text**. They form one W2 bug, introduced on main by `04bb8835` ("Keep the borrows a loop's elements and a defer body's stores carry", 2026-10-01).

**Mechanism.**
- When `checkDeferBody` (3635) runs a deferred body at an exit, it now keeps *all* of the body's effects in the current state: status changes and replaced loans as well as stored borrows.
- That is right for an exit after which nothing else runs: a scope's end, `break`/`continue`, `return`.
- It is wrong for the three exits after which the current path **goes on**:
  - `e!` and `e?` (`walkPropagate`, 3603);
  - the errdefers of a fallible function tail (`walkBody`, 1205);
  - the errdefers of a block that is the function's result (`walkBlock`, 1298).
- At those exits the defers run on the way out, but the path that continues never ran them.
- rig-text has the older code plus a narrower fix: at an exit it undoes the body's effects and then unions only the loans the body stored. That is why the branch rejects these probes.
- **Merge hazard:** whoever merges main into rig-text must keep rig-text's version of `checkDeferBody`, or the bug comes back on the branch.

| # | Probe | What happens |
|---|---|---|
| U1 | `u01_defer_revives_vec_at_propagate.rig` | `defer v = Vec()`, then `eat(<v)`, then `k = maybe(ok)!`, then `v[0]`. The defer run at the `!` revives `v` on the success path. **Sanitizer: "use of freed memory"** in `v.at(0)`. Variants with a struct: `f09`, `f10` (errdefer), `f11` (`e?`). |
| U2 | `u02_defer_ends_loan_at_propagate.rig` | `r = ?x`, then `defer r = ?keep`, then `maybe(ok)!`, then `-x`, then `r[0]`. The defer re-points `r` on the continuing path, so `x` looks unborrowed: a dangling read of the dropped Vec. It panics with index out of bounds only because drop resets `len`. |
| U3 | `u03_errdefer_effect_leaks_to_success_exit.rig` | The tail `maybe(ok)!` runs errdefers (`errdefer x = Vec()`). Their effect reaches the success exit, where `defer print(x[0])` is re-checked with `x` "live" after `eat(<x)`. **Sanitizer: use of freed memory** in the defer. |
| U4 | `u04_errdefer_tail_error_value.rig` | The same through a tail `if ok 1 else E.bad` (the `ret_block` path). **Sanitizer: use of freed memory.** |

- **Hotfix (S, about 6 lines plus 4 reject tests).** At the three continuing exits, run the defers between `p = here()` and `rewind(p)`. Their diagnostics stay, their effects go.
- At the falling-through and jumping exits, keep main's behaviour: the defer really runs on those paths.
- The structural fix is §5.

**An incidental find outside loans (rule 2: accept means correct).**
- `c10b_shared_int_array_index.rig` (`h = *[1, 2]`, then `print(h[0])`) passes `rig check` and then fails to compile in Zig (`Expected pointer… found *RcBox([2]i64)`).
- `c10` does the same with an array of views.

No other probe in this dimension (about 80) is unsound on main or on rig-text.

---

## 2. Gap table

Status values are the ones the Core claims. Fix sizes: S under ~50 lines, M ~50–400, L more than that. "Step" is the consolidation step where the fix belongs.

| Core rule | Core claims | Actual behavior (probe) | Gap | Code | Fix | Step |
|---|---|---|---|---|---|---|
| 3/6, at exits | built | A `defer`/`errdefer` run at `e!`, `e?` or a fallible tail leaks its effects into the path that goes on (U1–U4). | **Unsound** | `checkDeferBody` 3647, `walkPropagate` 3605, `walkBody` 1205, `walkBlock` 1298 | S (hotfix), M (§5 helper) | hotfix now; then the W2 helper |
| 5: one writer or many readers | built | Enforced for a name holding a loan, for numbers too (`a01`–`a05`, `a12`, `m01`, `m02`, `m05` rejected). | none | `conflicts` 642 | — | — |
| 5, "numbers included" | built | A read view of plain data is a *copy* with no loan when it comes from a call (`a08`, `a11`: `t: ?Int = id(?n)`, then `n = 3`, then `t` is accepted and emitted as `i64`) or from a `match ?h` payload (`m04`: `h = .no`, then `print(n)` is accepted). Yet `r = ?n` keeps a loan (`a01`). Sound, but two rules for one sigil. | wording or behavior | `bindPayload` 3294 (`isCopy`), the typecheck/emit copy of `?Int` results | S (wording), M (behavior) | Core §4 lend table: say "a read view of plain data where a value is expected is a copy" |
| 6: field | built | A view in a struct field keeps the loan until the struct's last use (`f02`, `f03`, `f04`, `f08`, `a03` rejected). | none | `walkFieldAssign` 2470, call `stored` 2593 | — | — |
| 6: list | built | **Arrays** of views carry loans (`a10`, `loop_element_of_made_array_borrows`). A **Vec** cannot hold a view at all (`a06`: "`Vec[T]` requires … got `?Int`"). | Core overstates "a list" | typecheck Vec element rule | M (with Core §5) | containers step (§5 of the Core) |
| 6: optional | built | Yes (`a07`, `a13` with `??`). | none | — | — | — |
| 6: closure | built | Yes: stack closures carry their captures' loans (`a05`, `st04` on the branch). | none | `walkLambda` 2949 | — | — |
| 6: result | built | Yes for non-plain views (`a13`, `st09`). Plain-data views are copies (row 5). | see row 5 | `walkCall` 2621 | — | — |
| 6: `match`/`as` bindings | built | Yes (`a09`, `a07`; `as` keeps the value's loans). | none | `bindPayload` 3289, `walkConditionParts` 3148 | — | — |
| 6: loop variables | built | Yes (`a10`, `m05`; the source stays borrowed through a hidden var 3506). | none | `bindLoopElems` 3501 | — | — |
| 6: String views | branch | On rig-text every flow probe is rejected correctly (`text/st01`–`st10`). | none found | rig-text `capture` reports statement temps | — | — |
| 7: "only of what it was lent" | built | It may also return a view of a module constant (`g01` accepted: `fun rows -> []Int` returns `?ROWS[..]`), and an extern-zig function with no borrowed parameter returns a program-lifetime view (`os.args()`). | Core omits statics | `isLocalLoan` 2893, `isGlobal` 796 | S (wording) | Core text |
| 7: result has *all* loans | built | True: no under-borrowing found (results, `??`, `catch`, ternaries, loop values, methods, callables). Over-borrowing is real (`r01`–`r04`). Worst case: an `!Int` counter passed beside the table stays write-locked while the result lives (`r04`). | pain, not soundness | `walkCall` 2593 | M (§6.2) | after the W2 helper; optional |
| 9: Cell/Signal | built, "per value: decided" | Checked **per type** in typecheck: `Cell[T]`/`Signal[T]` reject a `T` that may hold a borrow (`c03`, `c04`, `c08`, `c09`). Ownership adds a per-value check for loans that arrive inside an allowed type (`*V` or `~V` with loans: `c11`, `c15`). | status: per type + per value | typecheck Cell rule; `walkCall` 2585 | M (§6.1) | after strings |
| 9: owned closures | built | Per value: a capture carrying a loan is rejected (`c06`, `c14`); literals and statics are fine (`c07`, `t04`, `t11`). | none on main; at boundaries on the branch (`t09`) | `walkLambda` 2932 | M (§6.1) | after strings |
| 9: `*T` | built | **Not enforced:** `*V(r: ?a)` is accepted (`c01`). Every handle carries the loan instead (`+h`, `~h`, upgrade, moved into a struct or function), and every escape is caught (`c02`, `c12`, `c16`). Sound, but it contradicts the sentence. | Core wrong, behavior sound | `walkShare` 2911 | S (wording) or S (reject) | Core text |
| 9: generics | — | A generic function rejects any borrow-carrying `T`; a generic type with methods does too (`checkInstantiations` 492). On rig-text a `T = String` is rejected per type when the body stores a `T` in shared storage (`t06`). | per type | 492–532 | M (§6.1) | after strings |
| §8: lives for the whole program | decided, as a **type** fact | It is a **value** fact, and it is already encoded implicitly in three ways: an empty loan set (literals, `c07`, `t02`, `t08`), a loan on a global root (`isGlobal`, `g01`, `t10`), and an extern-zig result with no borrowed parameter. It is lost at function boundaries on rig-text (`t07`, `t09`) and in generic instances (`t06`). | design | — | M–L (§6.1) | after strings |
| W2 silent drops | — | 14 sites (§3). One is live-unsound (U1–U4). The rest are safe only by the discipline of their callers. | structural | §3 | M (§5) | W2 helper |

---

## 3. How ownership.zig handles flow (map)

### The core and its operations

**Abstract state:** `flows[var]` (status plus loans), a trail of changes, and `temps` (statement loans).

**Operations (800–1010):**
- `here`: take a point;
- `rewind`: undo back to a point;
- `capture`: the changes since a point, *filtered*;
- `apply`;
- `leave` = `capture` + `rewind`;
- `join`: a status max and a loan union;
- `joinAt`;
- `leaveTo` (3593) = report + `capture`.

### Save, restore and join sites

There are **51 calls in 13 functions**:

| Operation | Calls |
|---|---|
| `here` | 10 |
| `leave` | 9 |
| `leaveTo` | 4 |
| `capture` (direct) | 2, plus 2 inside the helpers |
| `joinAt` | 3 |
| `join` | 9 |
| `apply` | 11 |
| `rewind` | 5 |

Calls per function: `walkMatch` 8, `walkLoop` 8, `walkIfBinding` 6, `walkIf` 4, `loopIteration` 4, `walkNullish` 3, `walkCatch` 3, `walkLabeled` 2, `walkLambda` 2, `walkFun` 2, `checkDeferBody` 2, `walkJump` 1.

Related counts:
- 7 `pushScopeFor`/`popScope` pairs;
- 9 places that shrink `temps`;
- defers re-walked from 7 sites (4 `runDefers`, 3 `runDefersTo`), for five kinds of exit:
  - a scope's end;
  - `return`;
  - `break`/`continue`;
  - `e!`/`e?`;
  - a fallible tail.

### Per construct

- **`if`:** the condition, then each branch from `base`, with `leave`, `join`, `apply`.
- **`if … as` and joined conditions:** the parts push scopes. A failing part is `leaveTo(base, else-start)`; the `else` starts from it.
- **`match`:**
  - each arm starts from `start`, the entry state joined with every failed guard;
  - a failed guard is `leaveTo(base, next-arm)`;
  - with no catch-all arm, `start` also joins the result.
- **`catch`, `??`:** the handler or right side is walked from `base` and joined with `stateAt(base)`. `?? return` and `?? break` make that side unreachable, so the join is `base` (`f01` rejected correctly).
- **Loops (`walkLoop` 3414):**
  - the head is the join of the entry, the back edge and the `continue`s;
  - it iterates quietly until `statesEql`, with a 100k-round backstop that rejects the loop;
  - then one reporting walk;
  - the exit is the condition-false state (or a failing `as` part) joined with the `break`s.
- **Labeled blocks:** `joinAt(point, breaks)`.
- **Jumps:** run the defers to the target depth, then `leaveTo(target)`, then become unreachable.
- **`return`:** run all defers, then become unreachable.
- **`e!` / `e?`:** run all defers and **continue** (U1–U4).
- **`defer`:**
  - checked where it is written, with its effects undone;
  - re-walked at each exit with `hidden` scopes and `defer_floor`;
  - effects kept at every exit (since `04bb8835`).
- **Closures and nested functions:** walked against a snapshot, then rewound.

### Every place a loan leaves the state without a report

| Site | What is dropped | Why it is safe today | Probe |
|---|---|---|---|
| S1 `capture` 878 / 883 | Loans of vars below the point on vars above it, and temps on such vars | Every caller with open scopes calls `leaveTo` first; the others have balanced scopes. **Caller discipline, not structure.** | `f02`, `f03`, `f07` rejected |
| S2 `leaveTo` 3595 | Holders not live at `at`; temps never reported | NLL; temps end with the abandoned statement | `f02`, `f03` |
| S3 `releaseVarsFrom` 693 (`popScope`) | Loans on scope vars held by dead holders; held by anything when unreachable; temps silently (709) | Unreachable paths are dead | `f04`, `f08` |
| S4 `escapeVarsFrom` 1312 | A value's loans on closing vars, after reporting | Reports first | `f07` |
| S5 statement end 1279 | All of the statement's temps | By definition | — |
| S6 `walk` readsThrough 1330 | Temps taken to reach plain data | The value is a copy | — |
| S7 `walkCall` 2562, 2622 | Argument temps when the result holds no borrow; `print` | The result keeps nothing | — |
| S8 `walkConditionParts` 3159; `walkMatch` 3224, 3247 | The header's temps; a lent scrutinee; guard temps | Bindings hold their own loans | `match_subject_borrow_ends_with_bindings` |
| S9 `walkSwapCall` 2716 | Both values, including the one `replace` stores | Typecheck rejects borrow-holding `replace`/`swap` values | `s01`–`s03` rejected |
| S10 Cell argument 2587 | Loans after reporting; a plain read | Error or copy | `c11` |
| S11 type gates: 1125, 2325, 2393, 1645, 1520, 3294 | Loans of values whose type cannot hold one; **Copy payloads** | They are copies | `m04`, `a08` (see row 5) |
| S12 rewinds: `walkFun` 1187, `walkLambda` 2999, `checkDeferBody` written 3648 | Everything | Intended | — |
| S13 `checkDeferBody` at exit 3647 | **Nothing is dropped: everything is kept, including on paths that continue** | — | **U1–U4 unsound** |
| S14 `reassign` 2393 | The old loans (re-pointing) | Intended; U2 abuses it through S13 | `u02` |

**Not found:** an unbalanced-scope `rewind`. `p01`: a guarded binding (`r = ?v if c`) is normalized into a block. Every binding form pushes a scope.

---

## 4. Corrections to the Core document

1. **§1 table.**
   - `Text` is marked built under *owning*. Main has no `Text`; it exists only on the strings branch.
2. **Sentence 3/6, "built".**
   - This needs a caveat until U1–U4 are fixed: the `!`/`?` exits break it on main.
3. **Sentence 5, "numbers included".**
   - True for a name holding `?n`.
   - A read view of plain data reached through a call result, a `match ?h` payload or an `as` binding is a copy with no loan (`a08`, `a11`, `m04`); even `t: ?Int = id(?n)` is a copy.
   - Recommended: put it in the lend table, not the sentence: "where a value of plain data is expected, `?x` lends a copy". Then sentence 5 holds for every *view*, and plain-data reads are values.
   - The alternative is to make every `?Int` a real pointer, which costs every numeric API.
4. **Sentence 6, "a list".**
   - Only arrays today. Vec rejects view elements (`a06`; Core §5 already marks Vec-of-anything as decided).
5. **Sentence 7.**
   - Add: "…or of something that lives for the whole program (a literal, a module constant, `os.args()`)". Main already allows this (`g01`; SPEC §15 on extern zig).
   - "Carries the loans of everything it was lent": true as stated (an over-approximation). The status should note the known pain (§6.2).
6. **Sentence 9.**
   - Split it:
     - "`Cell` and `Signal` change through any path, and an owned closure hides its captures in its type, so these three accept only values that carry no loan."
     - "`*T` only reads: its handles carry its contents' loans like any value."
   - That matches main, which accepts `*V(r: ?a)` (`c01`) and tracks it soundly (`c02`, `c12`, `c16`).
   - Replace "checked per value: decided" with what is true today:
     - Cell/Signal: per type (typecheck) plus per value (ownership);
     - owned closures: per value;
     - generic instances: per type.
7. **§8, "lives for the whole program".**
   - Listed as a type fact, but literals and `os.args` are values. Move it to the expression classification ("what it hands over"), as designed in §6.1.

---

## 5. Design: one exit helper that cannot forget a loan (the W2 fix)

### Rule

There is exactly one way to take the state of a path that ends: **`exitTo`**. It:

1. runs the defers of the scopes it closes;
2. reports every loan it is about to drop whose holder (a var *or a temp*) is live where the path resumes;
3. captures the state relative to the target point;
4. when the current path **goes on** after the exit (`e!`, `e?`, a fallible tail), restores the state from before step 1.

`capture` and `filterLoansBelow` on flows become private to it. `leaveTo` disappears.

```zig
const Exit = struct {
    to: Point,               // state is relative to this point
    scope_depth: usize,      // scopes at index >= this close
    resume_at: ?u32,         // liveness point; null = after this statement
    defers: enum { none, normal, failing } = .none,
    goes_on: bool = false,   // `e!`, `e?`, a tail that may fail
};

/// The only way to end a path. Nothing it drops goes unreported.
fn exitTo(self: *Checker, e: Exit) Error!State {
    const back: ?Point = if (e.goes_on) try self.here() else null;
    if (e.defers != .none) try self.runDefersTo(e.scope_depth, e.defers == .failing);
    try self.reportLoansFrom(e.to.vars, e.resume_at); // vars and temps
    const s = try self.captureFiltered(e.to);          // the one filter
    if (back) |p| try self.rewind(p);
    return s;
}
```

- `reportLoansFrom` is today's `leaveTo` loop, plus temps.
- `releaseVarsFrom` (`popScope`) calls the same reporter.
- `rewind` and `apply` gain `std.debug.assert(self.vars.items.len == p.vars)`, so an unbalanced scope fails loudly in Debug.

### Sites it replaces

| Today | Becomes |
|---|---|
| `leaveTo` callers: `walkIfBinding` 3129, `walkMatch` 3249, `loopIteration` 3486, `walkJump` 3580 | `exitTo(.{ .resume_at = … })`; jumps add `.defers = .normal` (drops the separate `runDefersTo` at 3579) |
| `capture` in `loopIteration` 3489, 3498 | `exitTo` (balanced, reports nothing) |
| `leave` in `walkIf` 3111/3113, `walkIfBinding` 3135/3138, `walkCatch` 3177, `walkNullish` 3188, `walkMatch` 3255, `joinAt` 907 (`walkLabeled` 3410, `walkLoop` 3465, `loopIteration` 3496) | `exitTo` + `rewind`, still named `leave`; the assertion guarantees nothing is filtered |
| `walkReturn` 3037 | `exitTo(.{ .defers = fails ? .failing : .normal })` (result unused; the path ends) |
| **`walkPropagate` 3605, `walkBody` 1205, `walkBlock` 1298** | **`exitTo(.{ .defers = …, .goes_on = true })`: fixes U1–U4** |
| `popScope` 675 | defers + the same reporter (fall-through keeps the defer effects) |
| `checkDeferBody(report_changes = false)` 3647 | unchanged: keeping effects is now correct, because only non-continuing exits reach it with effects kept |

### Size and risk

**Size:**
- about +90 / −70 lines in `ownership.zig`, with no change to other files;
- plus 4 reject tests (U1–U4) and 2 behavior tests (a defer that stores a borrow at a `break`, and at a fall-through).

**Risk: low to medium.**
- Diagnostics may move by one site, or appear once more where a path was reported twice; `last_err_kept` already de-duplicates.
- Loop quiet rounds are unchanged.
- The assertion may expose a latent unbalanced site, which is the point.
- Validate with the 242 ownership reject tests, the 111 behavior tests, `test/corpus`, and the 1,046-probe re-run from the root-cause report, under `RIG_SANITIZE=1`.

**Relation to the root-cause plan.**
- This is the W2 half of fix (b), "one source of truth per fact": the fact here is "where a path ends".
- Lowering (fix (a), stages A2/A3) would remove most callers.
- `exitTo` is still the primitive the lowered `break`, `return` and cleanup forms would call, so it is not throwaway work.

---

## 6. Designs for the open items

### 6.1 "Lives for the whole program" as a tracked value fact

**Definition.**
- A value is **static** when its type may hold a borrow and its loan set contains only loans on static roots.
- Static roots are module constants (`isGlobal`) and a new `Loan.static` root for extern-zig results with no borrowed parameter.
- A literal is static because it makes no loan.
- This is the fact main already computes implicitly. Make it a named predicate, `isStatic(Value)`, in the expression classification (Core §8, "what it hands over"), not a type flag.

**What it unlocks today:** nothing new on main. There String is always static, so `t02`, `t06`, `t07`, `c07`, `t09` and `t10` are already accepted.

**What it unlocks on rig-text needs one more step: crossing function boundaries.** These are rejected on the branch:
- `t07`: a `String` parameter stored in a Cell;
- `t09`: an owned closure capturing a `String` parameter;
- `t06`: `Holder[String]` whose method calls `self.c.set(x)`.

They are rejected because a parameter's value is unknown, so it carries an `ext` loan, and the generic check is per type.

**Design: "static-required" parameter summaries.**
- While checking `f`, a value stored into shared storage (Cell/Signal set, replace or construct; an owned-closure capture) whose only loans are `ext` loans on parameters is not an error. It records `f.static_params |= {p}`.
- Loans on locals stay errors.
- At every direct call or method call of `f`, the argument for `p` must be static. Otherwise the error is reported at the call: "`remember` keeps `s` in a Cell (line 3), so its argument must live for the whole program; `?t[..]` borrows `t`".
- A caller passing its own parameter records it in turn, so summaries propagate.
- Order: iterate the module's functions to a fixpoint (sets only grow), or check on demand with a recursion guard. Cross-module summaries are stored in the module's `SemContext`.
- Generic instances replace rig-text's per-type rejection (`checkInstantiations` 539–548). A `T` parameter in `static_params` makes each call site check its argument value. `h.put("b")` is accepted and `h.put(?t[..])` is rejected.
- **Indirect calls** (a function used as a value, an owned closure, a callable parameter) have no visible summary. A function with non-empty `static_params` cannot be referenced as a value; the error goes at the reference.

**Cost:** M–L (~300–500 lines across ownership and sema; tests).

**Risk: medium.**
- Interprocedural state is new to the checker.
- A diagnostic now points at the caller rather than the store.
- Ship it after the strings branch lands. It answers t06, t07 and t09, which are real lines in a String-heavy program.

### 6.2 Sentence 7: "a `?A` result comes only from arguments that could produce an `A`"

**Evaluation.**
- **Fixes:** `r01` (a `?Key` beside a `?Table`), `r02` (a `?Int` index), `r03` (a method argument), and `r04` (an `!Int` counter that today stays write-locked while the result lives). These shapes are common in table, parser and lookup code.
- **Does not fix:** the String-heavy case on the branch. `fun after(hay: String, key: String) -> String` (`text/st05`) still borrows `key`'s Text, because a String can produce a String. The worst pain on the strings branch is untouched.

**Rule.** `produces(P, R)` holds when the type graph of `P` reaches the view target of `R`. The edges are:
- fields, payloads, optionals, array, Vec and Box elements, handles (`*T` and `~T` to `T`), callable results, and type variables (which reach anything);
- the lend-table rows: `Text` to `String`, `[N]T`/`Vec[T]` to `[]T`.

`walkCall` (2593) drops an argument's loans when `!produces(argTy, resultTy)`. Callee loans (closures) are kept.

**Soundness.**
- In the callee, the returned value's loans are already a subset of the parameters' `ext` loans (`checkEscape` 3079).
- The type system guarantees that a value of type `?A` derived from parameter `p` was reached through `p`'s graph. Only `raw` can break that, and `raw` is exempt.
- Defense in depth: in `checkEscape`, reject a returned `ext` loan on a parameter whose type does not produce the result type. This should never fire.

**Cost:**
- S–M: `produces` with memoization (~80–120 lines in sema), built on the existing `holds()` walker so new type forms are covered by default;
- ~15 lines in `walkCall`;
- one SPEC paragraph and tests.

**Risk:**
- Low to medium. A missing edge is unsound, so unknown or unrecognized types default to "produces".
- It is the first rule where the signature narrows loans, so the fuzzer should get a generator for it.

**Verdict:**
- Worth doing, but after the W2 helper and not before the strings merge.
- If the strings branch is the priority, a stronger answer to `st05` is a body-inferred provenance summary per function (which parameters' loans reach the result). It costs about the same as §6.1 and shares its machinery.
- It makes callers depend on callee bodies, which the Core's "rules follow the value's type" principle argues against. Decide that explicitly.

---

## 7. Probe index

**Unsound on main** (rejected on rig-text):
- `u01`–`u04`;
- `f09`, `f10`, `f11`: the same mechanism with a struct instead of a Vec, so they are not memory errors.

**Rejected correctly on both branches:**

| Area | Probes |
|---|---|
| Flow | `f01`–`f04`, `f07`, `f08`; `f12` (`and` with a move on its right side: accepted and correct) |
| Aliasing | `a01`–`a05`, `a07`, `a09`, `a10`, `a12`, `a13`; `m01`, `m02`, `m05` |
| Shared storage | `c02`–`c04`, `c06`, `c08`, `c09`, `c11`–`c16`; `s01`–`s03`; `c05` and `c07` are accepted and correct |

**Accepted and sound, but showing a gap:**
- `a08`, `a11`, `m04`: plain-data views are copies;
- `c01`: `*T` holds a view;
- `g01`: a static view result;
- `r01`–`r04`: over-borrowing (rejected; this is the pain);
- `t01`–`t11`: statics and Strings.

**Accept-means-correct failure:** `c10`, `c10b` (`*[…]` indexed).

**Strings branch:** `text/st01`–`st10`, all rejected correctly; `st05` shows the over-borrowing the refinement cannot fix.
