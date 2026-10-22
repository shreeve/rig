# Origins: the implementation plan

Role: implementation in Rig's compiler. The question is how to make a
call's result (and what a call stores) carry the loans of only the
arguments it really views. Today it carries the loans of every
argument.

Every claim about today's compiler was checked against
`/Users/shreeve/Data/Code/rig-revamp` (`d29be15f`). Line numbers are
from that commit. The probes are in `probes-impl/`.

A throwaway prototype of inferred result origins was built in a
scratch copy; no tracked file was touched. Its diff is
`probes-impl/proto-inferred.diff`, 147 lines. §2 has the results.

---

## 0. Bottom line

1. **The checker already computes origins. It just never writes them
   down.**
   - Every parameter that can carry a view holds an *external* loan on
     itself (`bindParam`, 1301–1349).
   - At every exit, the returned value's loan set names exactly the
     parameters it came from (`walkReturnValue`/`checkEscape`,
     3409–3466).
   - A 30-line recorder plus a 15-line narrowing in `walkCall` made
     the prototype accept these, all sanitizer-clean: `two.rig`,
     `recur.rig`, `generic.rig`, `produces.rig`, a swap through an
     inner call, a temporary in the excluded position, and a
     compile-time parameter.
   - It still rejected every under-borrow attempt I wrote (§2).
2. **The data structure every layer shares is one `Summary` per
   function.** It holds, as parameter bitmasks:
   - the parameters the result may view;
   - for each write parameter, the parameters whose views it may
     receive;
   - which parameters must live for the whole program (step 6.2).

   Three things share it:
   - **one recorder**, which fills it from the body walk;
   - **one call rule**, which reads it in `walkCall`;
   - **one argument-to-parameter mapping**, which must be the fact emit
     already uses (`call_slots`) plus the receiver.

   That mapping is the one place where a bug is unsound. The prototype
   shows it: a naive positional mapping would accept
   `probes-impl/kw_args_trap.rig` while `r` still views `x`.
3. **Recommended design ("A"): the declared or default summary lives in
   the function type, and the body walk checks it.**
   - **The default** (no `from` written) is the type-directed
     `produces` mask (step 6.3).
   - **`from` narrows it.**
   - **The callee's own walk proves `Σ_actual ⊆ Σ_declared`.** That
     includes the default, so a missing `produces` edge becomes a false
     rejection in the callee, never an unsound caller.
   - **Callers read only the callee's type.** That covers every kind
     of call: direct, method, `?fun` value, closure, `extern zig`,
     generic instance, and imported. So there is:
     - no call graph;
     - no fixpoint;
     - no ordering between functions;
     - no new cross-module export, because function types are already
       imported.
4. **Inference (L2) is an optional convenience for private
   functions.** It does not need to be the default.
   - It needs callee-first ordering, a fixpoint over strongly
     connected components, and a new fact naming each method call's
     resolved symbol.
   - The prototype did it with a quiet pre-pass. It needed two quiet
     rounds plus the reporting walk, so about 3× the ownership walking.
     An SCC order brings that to 1× for non-recursive functions.
5. **Field precision splits in two.**
   - **L1a, owner-side loan paths** (disjoint `!p.x` and `!p.y`). It
     touches the conflict queries, the heart of the checker. It
     reopens self-loans: `absorbLoans` today *silently drops* a loan
     on the var being stored into (3226), which is safe only because
     whole-root conflicts make that case unreachable.
   - **L1b, holder-side parts** (`pair.rig`, `split.rig`). It can be an
     *optional refinement* beside the existing union, so every
     whole-value consumer stays as it is. It needs per-field last-use
     to pay off.
   - Both are the largest and riskiest layers. Build them last.
6. **Statement temporaries.** Every layer changes only two things:
   - the *value* a call returns;
   - what `absorbThroughWrites` stores.

   None of them touches `temps`, `holdTemp`, `dropStmtTemps`, or
   `capture`, the code of the two earlier slips. The excluded
   arguments' lends still end with the statement, as today. That is
   conservative inside the statement, and it keeps the fragile code
   frozen.
7. **Order:**
   1. the summary core and the mapping fact;
   2. `produces` + the body check (6.3);
   3. **L0 carry** (generalizes `viewLoans` and `throughReadSlice`);
   4. declared `from`, including function types and `extern zig`;
   5. **D2 depth/path tokens** (`from self.src`);
   6. static-parameter summaries (6.2), on the same recorder;
   7. optional private inference;
   8. L1a;
   9. L1b.

   Steps 2–4 are about 650–900 lines and close every same-typed and
   different-typed "which argument" case. Steps 5 and 9 close the
   holder cases (`split.rig`).

---

## 1. Anatomy: what the checker does today

| Piece | Where | What it does for origins |
|---|---|---|
| External token | `bindParam` 1301–1349 | Every parameter that lends (`ref != .none`) or may carry a loan gets `Loan{root = param, ext = true}` in its flow. It is never a conflict, and it may be returned. |
| Result check | `walkReturnValue` 3409, `checkEscape` 3444 | Every `return` and every tail value goes through here, after the branches are joined. `isLocalLoan` (3257) separates the caller's loans (`ext`, or a fresh lend through a view parameter) from local ones. |
| Call result | `walkCall` 2790–2953 | `result` = the callee's value (closure captures, a `?fun`'s token) ∪ the receiver's reborrow ∪ `stored` (2911), where `stored` is every argument that `keepsCallable`. |
| Call stores | `walkCall` 2918–2925, `absorbThroughWrites` 3149, `absorbLoans` 3221 | `stored` is absorbed into the receiver and into every write root of every argument. |
| Stores into the caller's memory, in the callee | `walkFieldAssign` 2736 branch, `absorbLoans` param branch (3236), `reassign` through a `!T` param (2647), `storeThroughLocal` 2689 | Today these only check "no local loan". They are exactly the sites where a store summary would be recorded. |
| String-only L0 | `viewLoans` 1839, `addViewLoan` 1856, `mayOwnText` 1870 | A loan on a var whose type reaches no Text is replaced by that var's own loans. This is the carry rule, specialized to `String`. |
| `[]T`-only path L0 | `throughReadSlice` 1991, used by `walkBorrow` 1906 | A lend through a read slice keeps what the slice keeps, not a loan on the root. |
| Liveness | `holderLive` 1160 | Per var: last use per symbol (`indexUses` 1126). Per-field liveness would extend this. |
| Cross-module summaries, precedent | `PlainRequirement`; `modules.zig:423` appends `ownPlainReqs()` to the module's `SemContext`; `importParam` (sema 3582) copies them to the importer's proxy | The template for exporting anything ownership learns about a declaration. |
| Argument → parameter | `SemContext.callSlotsOf` (sema 1354), recorded by typecheck 5089–5130, read by emit 4336/4505/4664 | Exists for keyword and defaulted calls. It does not record the receiver. |

Function types (`sema.FunctionType`, sema 97) are interned and compared
by identity. They are built at about 10 sites (resolve 875, 1053, 1502,
1666, 2301, 2350; sema 3275, 3479; typecheck 4744, 5330, 6625, 7948).
`lendCallable` (typecheck 7810) requires `plain == fn_ty`.

---

## 2. The prototype

**Change.** It is in a scratch copy, about 60 lines in
`ownership.zig`:

- `Var.param_index`;
- a mask that `walkReturnValue` fills from the result's loans whose
  root is a parameter;
- a quiet pre-pass over the module's functions, starting from ⊥ (empty
  masks, seeded for every local `fun`), repeated until stable;
- in `walkCall`, for a direct call by name with no call slots:
  `result = callee value ∪ args in mask`.

| Probe | Today | Prototype | Sanitizer run |
|---|---|---|---|
| `two.rig` | rejected | accepted | `0` |
| `recur.rig` (self-recursive) | rejected | accepted, mask `{a}` after the fixpoint | `1 5` |
| `generic.rig` | rejected | accepted | `0 1` |
| `produces.rig` | rejected | accepted (inference subsumes `produces`) | `5 3` |
| `u3b_swap_ok` (`first(b, a)` inside) | rejected | accepted | `1 7` |
| `u10_temp_ok` (`first(?x, ?mk())`) | rejected ("temporary outlives") | accepted | `1 1` |
| `param_count` (compile-time parameter first) | rejected | accepted | `0` |
| `u1_paths`, `u4_loop`, `u5_closure`, `u7_mutual`, `u8_byval`, `u3_swap` (writes the viewed owner) | rejected | **rejected** | — |
| `u2_struct` (result is a field of a local `Pair(a, b)`) | rejected | rejected for both `x` and `y` (needs L1b to free `x`) | — |
| `u9_temp` (result views the temporary) | rejected | rejected | — |
| `kw_args`, `kw_args_trap` | rejected | rejected (the prototype falls back on call slots) | — |

**Lessons:**

1. **The first prototype was unsound in a quiet way.** Missing
   summaries were treated as "all arguments" in round 1. A
   self-recursive function then fixed itself at `{a, b}`, because the
   union is monotone. A least fixpoint must start every function in
   the SCC at ⊥, and must never treat an imported or unknown callee
   as ⊥.
2. **The mapping is the trap.** With named arguments, argument 0 is
   `b: ?y`. A positional reading would narrow to `?y`, free `x`, and
   accept `kw_args_trap.rig` with `r` viewing `x`. Ownership must use
   the mapping emit uses.
3. **The recorder needs nothing new from the walk.** Joins, loop
   fixpoints, closures, match payloads and inner calls already put the
   right parameter tokens into the returned value.

---

## 3. The shared core (build first)

### 3.1 Data

```zig
// sema.zig
pub const ParamMask = u64;           // bit i: run-time parameter i (a method's `self` is 0)
pub const Origins = struct {
    /// The parameters a result may view. A callable's own value (its
    /// captures, or what a `?fun` lends) is always included.
    result: ParamMask,
    /// Per write-lending parameter q: the parameters whose views a call
    /// may store into what q leads to. Empty slice = the default.
    stores: []const struct { into: u8, from: ParamMask } = &.{},
    /// D2 only: the result views what parameter i *views*, not i itself.
    deep: ParamMask = 0,
};
pub const FunctionType = struct { ..., origins: ?*const Origins = null };  // null = default
```

**Origins in the function type:**

- Hash and compare `origins` by value in `hashType`/`typeEqual`.
- Copy it at every `FunctionType` construction site (§1 lists 12),
  including the generic substitutions (sema 3275, 3479; typecheck 4744)
  and `importType`.
- The masks are positional, so imports and instances need no renaming.

**Functions with more than 64 parameters** use `origins = null` and the
full default: cheap, and always sound.

**Ownership:**

- `Var.param_index: ?u8` is set by `bindParam` for run-time parameters
  only. Compile-time value parameters are bound first (`walkFun` 1275)
  and get none; the prototype confirmed it.
- `FnCtx.actual: *Origins` is the recorder. Each closure gets its own,
  so a closure's returns never land in the enclosing function's
  summary.

### 3.2 The argument-to-parameter fact

This is the one classifier for "which argument fills which parameter".

- **The fact.** Typecheck records a `call_params: NodeKey → []const
  ParamSource` for **every** call, where `ParamSource = union { recv,
  arg: u32, default }`. It extends `recordCallSlots` (typecheck 5126)
  with the receiver, and covers:
  - `obj.m(..)` with a value receiver: `recv`;
  - `T.m(..)` (a type-named callee): none;
  - `p.f(..)` with `f` a function field (`callsFunctionField` 4344):
    none;
  - built-ins.
- **Consumers.** Emit's argument order (4336, 4505, 4664) and ownership
  read the same fact.
- **Fallback.** Missing entry, arity mismatch, variadic `print`/`Text`,
  `swap` (3039): no narrowing.
- **Cost.** About 60 lines, plus a unit test per call shape.

### 3.3 The recorder

`recordResult(v)`, called in `walkReturnValue` beside `checkEscape`:

- for each `l ∈ v.loans` with `vars[l.root].param_index = i`, set bit
  `i`;
- loans on globals are static;
- in a closure, loans with `root < closure_base` are the environment.

`recordStore(q, v)` is called at the four store sites of §1. `q` is
the write parameter at the root of the target, or each parameter whose
external write loan `storeThroughLocal` follows. It sets
`stores[q] |= params(v)`.

**Notes on the recorder:**

- Stores are recorded where they happen, not at exits. That is weaker
  than per-path, but sound and simpler: a store on a path that later
  fails is still seen by a caller that `catch`es.
- Quiet loop iterations record subsets of the final state, so the
  union is unaffected.
- **After step 2.** Once `exitTo` is the one exit primitive (step 2,
  E2–E4), `recordResult` moves into it, as the `.return` exit's single
  hook.

### 3.4 The call rule

This is a change to `walkCall` only.

Let `S` be the callee's effective origins (§4.3), and `A[i]` the value
of the argument filling parameter `i`. The receiver's value is
`recv_val ∪ reborrow`, computed today at 2830–2840.

```
result = callee_value ∪ ⋃{ A[i] | i ∈ S.result, keepsCallable(arg i) }
stored_into(q) = ⋃{ A[i] | i ∈ S.stores[q] }       (default: every argument, as today)
```

- **Results.** This replaces the union at 2911.
- **Stores.** The absorb loop at 2918–2925 calls `absorbThroughWrites`
  for each write argument `q` with `stored_into(q)` instead of the
  common `stored`.
- **Unchanged:**
  - the `cell` check;
  - `text_op` and `print`;
  - the receiver reservation;
  - `holdArgRead`;
  - **the `temps` handling at 2928–2943**: every lend made in the
    arguments still ends with its statement (§11.1).

---

## 4. Layer P: the `produces` default, checked (step 6.3)

### 4.1 Sema

`produces(P, R) bool` holds when a value of type `P` can lead to memory
of a type that a view slot of `R` targets. It is computed per type pair
and memoized in a `std.AutoHashMapUnmanaged(u64, bool)` on the checker,
since `ctx` is const there.

**Edges** (all of them, as the `holds()` walker in `computeTypeInfo`,
sema 2374, already follows):

- fields and enum payloads;
- optionals;
- array, slice, Vec and Box elements;
- `*T` and `~T` to `T`;
- view targets (`?T`, `!T`);
- callable results;
- type variables, unknown, and poison: everything.

**Two memory classes need care:**

- **bytes.** `String`, `[]U8`, `[N]U8` and a Text's buffer are one
  class, because a String's bytes and a `[]U8` can view the same
  buffer.
- **closure environments.** These are reached by every callable.

**Lend-table rows are edges.** Once step 3.1a's `lendsAs` exists,
derive the edges from it, so a new row cannot forget its edge.

### 4.2 The default mask

- `result`: the parameters whose **declared** type `produces` the
  result type.
- `stores[q]`: the parameters whose declared type `produces` some view
  slot type inside `q`'s target.

For a generic function, take the generic signature, not the instance.
At a call, `ctx.genericCallOf(node)` identifies one; read the callee
symbol's own type. A type variable produces everything, so this never
relies on parametricity, and the body check below covers it.

### 4.3 The effective origins of a callee

The callee's type is unwrapped through `borrow_read`, `callable` and
`shared` to its `FunctionType`:

- with `origins` set: those;
- otherwise: the default above.

One function, `effectiveOrigins(ctx, fn_ty, generic_ty)`, serves:

- `walkCall`;
- the callee's own check;
- the reference checker, which reimplements it.

### 4.4 The check in the callee

At the end of `walkFun` (and of `walkLambda`): if `actual ⊄ effective`,
report at the first return or store that set the extra bit:

> "`first` returns a view of `b`, but its signature lets it view only
> `a`; write `from a, b`".

For a default that the body exceeds, this can only fire when a
`produces` edge is missing: a compiler bug, now caught as a rejection
instead of a hole. It is skipped for:

- a body-less declaration (`extern zig`, `extern fun`): trusted;
- built-ins: trusted, and listed with unit tests.

### 4.5 Fixes, cost, risk

- **Fixes:** `r01`–`r04`, `method_key.rig`, `produces.rig`.
- **Does not fix:** same-typed arguments (`two`, `strip`, `cut`,
  `st05`).
- **Size:**
  - about 140 lines in sema (`produces`, its tests, defaults);
  - about 50 in ownership (recorder, check, call rule);
  - the 60 for the mapping fact.
- **Risk: low to medium.** A wrong mapping is unsound (§3.2). A wrong
  edge is a false rejection in Rig code, and is trusted only for
  built-ins and externs.

---

## 5. Layer L0: the carry rule

A view carries what it views, not its holder.

**Rule.** For a value of view type `V` holding a non-external loan on
var `h`: if `ownReach(type(h), V)`, keep the loan; otherwise replace it
by `flows[h].loans`, recursively (depth 16, then keep).

`ownReach(H, V)` holds when `H` reaches memory a `V` view targets
through **owned edges and write-view edges only**:

- **Owned edges:** field, payload, element, optional, Box, a `*T`
  handle, and a `Cell`'s contents.
- **Write-view edges:** `!T` and `![]T`.

Type variables, unknowns and closures reach everything. This is
formal.md §2.3, Lemma 1.

### 5.1 Changes

1. **`carry(V, v)` replaces `viewLoans`/`addViewLoan`.** `mayOwnText`
   becomes `ownReach(type(h), bytes)`, which is exactly today's
   `reachesText`.
   - Every site that calls `viewLoans` today calls `carry`:
     `walk` 1500, `walkMember` 1830, `bindNew` 2598, `reassign` 2666,
     `walkFieldAssign` 2724, the `cell` branch 2903, `walkCall` 2942,
     `walkSwapCall` 3075, `absorbLoans` 3223, and `bindPayload` 3692.
   - So the rule is decided in one place (AGENTS "one classifier").
2. **Path form for lends.** `throughReadSlice` (1991) generalizes to
   `throughReadView`: a step whose object type is `borrow_read`, a read
   slice, or `String`.
   - `walkBorrow` already sends that case to `walkBorrowedPath`, which
     returns the root's held loans, not a loan on it.
   - The type form would also cover `prefix.rig`. The path form is more
     precise when the holder also owns the target type
     (`cursor_own.rig`: `Cursor{items: ?Vec[Item], scratch:
     Vec[Item]}`).
3. **Call results.** At 2941–2943, `holdsViewOnly → keepViewTemps(viewLoans)`
   becomes `result = carry(result_ty, result)` for every view-holding
   result type.
   - Keep `keepViewTemps` (which also *shrinks* `temps`) for `String`
     only, exactly as today.
   - Widening it would let `print(!c.next().n, !c.next().n)` through in
     one statement. That is a separate, temporaries-touching decision
     (§11.1).

### 5.2 Soundness hazards

- **A write edge must never take the replacement.** `!c.next()` with
  `Cursor{items: !Vec[Item]}` must keep the loan on `c`.
- **A drop body still makes the holder whole-live.** `holderLive` 1180
  already does this.
- **`carry` on external tokens: keep them** in this layer. Splitting
  them is D2 (§7).

### 5.3 Fixes, cost, risk

- **Fixes:** `cursor.rig`, `deep2.rig`, `prefix.rig`.
- **Size:** about 120 lines in sema (`ownReach`, memoized, with tests)
  and about 40 in ownership (net, after deleting `addViewLoan` and
  `mayOwnText`).
- **Risk: medium.** It is trusted at call results, as `viewLoans` is
  today, and the reference checker must reimplement `ownReach` on its
  own. A missing owned edge is unsound.

---

## 6. Layer D: declared `from`, checked by the body

### 6.1 Syntax plumbing

These are implementation costs only; the syntax itself is the syntax
role's call.

- **Grammar.** `returns = "->" type [FROM origins]`, where `origins` is
  a comma list of names, or an empty list meaning "only static and the
  environment".
- **The same clause goes on:**
  - `fun_type` (`?fun(..) -> R from ..`);
  - `ext_fun` and `zfun` (extern zig);
  - a write parameter, as `h: !Holder from x`: a `from` field on the
    `:` param node.
- **Function types need parameter names.** Today `fun_type` takes
  unnamed types (`rig.grammar:573`), so `from a` cannot name anything.
  Allow `name: type` items in the list (names are not part of type
  identity), or accept positions.
- **`from` stays an identifier.** It is a field and parameter name in
  `test/behavior/types/struct_equality.rig` and two corpus programs.
  Make it a keyword only after a return type, as `new` is only at
  statement start (`src/rig.zig:765`, `stmtStart() and nextIsName()`).
- **Size.** About 15 grammar lines and about 20 in `rig.zig`. Both
  files are mirrored in Nexus: report the change.

### 6.2 Resolve

- Map each name in `from` to its parameter index. `self` is index 0
  for a method.
- Reject:
  - an unknown name;
  - a parameter that cannot `produces` the result ("`k: !Int` cannot
    hold a view of an `Item`"), which catches typos early;
  - a `from` on a result type that holds no view.
- Build `Origins` and intern the function type with it (resolve 875,
  1053, 1502).
- About 70 lines.

### 6.3 Typecheck

Function-value compatibility becomes "same shape". That is a new
`sema.fnShapeEq(a, b)`, ignoring `origins`, used in:

- `lendCallable` 7818;
- the owned-closure comparison 7823;
- `compatible` for function-typed values;
- `bindArg`'s `.function` arm 5924.

The *origin* fit of a function value is checked in ownership, because
only ownership knows a local closure's actual summary. This is about 40
lines.

### 6.4 Ownership

| Construct | Where its summary comes from | What is checked |
|---|---|---|
| Named function / method | its type (declared or default) | its body, at `walkFun` end (§4.4) |
| Closure literal with an expected type (passed directly) | the expected type (typecheck gives it that type) | its body in `walkLambda`, environment excluded |
| Closure binding `f = \|..\|` (no expected type) | **inferred** from its body in `walkLambda`, stored on `Var.origins`. This is local and ordered: the literal is walked before any use. | at each lend `?f` to a `?fun` parameter: `Var.origins ⊆ expected` (from `ctx.callableOf(arg)`); at a direct call `f(..)` the inferred mask narrows |
| `?fun` parameter `f` | its declared type | calls through `f` use it; `f`'s own token is the environment (always kept) |
| Owned closure `*\|..\|` | its type (default unless declared). An inferred mask stays on the binding while it is local. | at a lend, as for a closure binding |
| `extern zig` / `extern fun` | declared (trusted) or default (trusted, as today) | none: the trust boundary, like `raw` |
| Generic | the generic signature's | the body, once, with `T` opaque |
| Imported | the imported type: `importType` copies `origins` | done in the declaring module |
| Recursion | the declared type (assume–guarantee: every returning run has finite depth) | the body, against the same mask |

**Size.** About 120 lines: the subset check at lends, the closure
inference, and storing on the `Var`.

**Diagnostics** name the narrower `from` that would work. The recorded
`actual` mask *is* that `from`, which is how L2 pays off without being
the default.

### 6.5 Fixes

`two`, `strip`, `cut`, `firstmut`, `generic`, `recur`, `funval`,
`closure_ret`, `store` (with `h: !Holder from x`), and `br_x01`
(`os.env(..) -> String? from` with an empty list).

The std annotations to write:

- `text.strip_prefix`, `strip_suffix`, `cut`: `from s`;
- `split`, `lines`, `words`: per-field results (§9) or `from s, sep`;
- `os.env`: an empty `from`.

### 6.6 Cost and risk

- **Size:** about 300–400 lines in total.
- **Risk: medium.**
  - Every declared mask is proved by the body, except externs.
  - The new unsound surface is §3.2 (the mapping) and the
    `FunctionType` copy sites. A construction site that drops
    `origins` widens to the default, which is safe. A site that copies
    the wrong function's `origins` is unsound. Assert in Debug that the
    instance and the generic type have equal `origins`.

---

## 7. Layer D2: depth and path tokens (`from self.src`)

L0 frees the holder whenever the holder's type does not own the target
type. Rust's `&'s P<'b> -> &'b V`, and Prior-art's "depth" (Swift's
`copy` versus `borrow`), matter only when the holder **also** owns that
type: `Parser{src: ?Vec[Tok], scratch: Vec[Tok]}` with `next(!self) ->
?Tok`.

**Token.** `Loan.slot: u8` on external loans:

- `0`: the argument itself (ε);
- `1..254`: the view held in top-level field `k`;
- `255`: anything the argument views.

**Body side.** In `walkMember`/`walkBorrowedPath`/`walkBorrow`, a step
that crosses a read-view field `f` of a parameter whose flow is
`{ext(p, 0)}` yields `ext(p, f)`. Today it yields `ext(p, 0)`. This is
the path form of L0, applied to tokens.

**Caller side, at `(p, f)`.** If argument `p` is a lend of an owned
local `x`, use:

- `flows[x].loans` (with L1b, `flows[x].parts[f]`);
- otherwise the whole argument value.

**Declared form.** `from self.src` sets `deep` and the field.

**Size and risk.** About 120 lines. Medium risk: the projection must
stop at write-view fields. It is needed for the "holder owns the target
too" shape and for `split.rig`'s `next`.

---

## 8. Layer S: static-parameter summaries (step 6.2) on the same recorder

`Origins` gains `static_params: ParamMask`, recorded where a value with
only external parameter loans goes into a `Cell` or `Signal`, or into
an owned capture:

- `walkCall` 2873–2885;
- `walkFieldAssign` 2721;
- `walkLambda` 3297–3318.

Those sites are errors today.

**No re-walk and no ordering.** The walk records three things:

- (a) each function's direct static parameters;
- (b) edges "parameter `q` of `g` is passed to parameter `p` of `f`";
- (c) each call site that passes a value with local loans to some
  `f.p`.

After the module's walk, close (a) over (b), which is graph
reachability, then report each (c) whose target is static-required.

- **Where it is reported:** "`remember` keeps `s` in a Cell (line 3),
  so its argument must live for the whole program".
- **Cross-module.** For `pub` functions, export the closed set per
  symbol beside `plain_reqs` (`modules.zig:423`, `importParam`).
  Modules are checked callee-first, so the sets are final.
- **Function values.** A function with a non-empty set cannot be
  lent as a `?fun` (loans.md 6.1), or it states it in its type later.
- **Generics.** This replaces `checkViews`'s per-type rejection
  (578–590) with a per-call check.
- **Size.** About 300–450 lines (loans.md's estimate holds). Risk is
  medium; it is independent of origins except for the shared
  recorder.

**Why S needs no fixpoint and inferred origins do.** A static summary
only adds *obligations* on callers. A result summary changes the loan
sets the caller's own walk uses for its *own* conflicts. So the caller
needs it before walking.

---

## 9. Layer I: inferred origins for private functions (optional)

**Mechanics:**

1. A call graph over the module's top-level functions and methods.
   - Direct calls use `symbolOf(callee)`.
   - Method calls need a new typecheck fact, `method_of: NodeKey →
     SymbolId`: today ownership sees only the callee's function type,
     never which method (`receiverMode` 4354).
2. Tarjan's SCCs, walked callee-first.
   - A non-recursive function is walked once, reporting, and records
     its actual mask, which becomes its effective mask for callers.
   - A recursive SCC starts every member at ⊥. It walks quietly until
     stable (sets only grow; the lattice is finite), then walks once
     with reports.
   - Diagnostics must then be sorted by position, since the walk order
     is no longer source order.
3. Functions are still all walked inside one `Checker`.
   - Only the order changes: `walkDecl`'s module arm (1225) iterates
     the SCC order.
   - Methods inside `struct` members need the same order.
   - The `fn_arena` reset (1281) is unaffected: masks are `u64`.
4. **Only private functions use the inferred mask.**
   - A `pub` function's contract stays its type, declared or default.
     So no body-dependent summary crosses a module, and changing a
     body never breaks an importer.
   - Inside the module, a private function's callers depend on its
     body. That is a deliberate exception to "rules follow the value's
     type". Decide it explicitly: AGENTS forbids exception lists.

**Cost.** About 200–250 lines, plus about 30 for the method fact.
Compile time: 1× walks for non-recursive code, k× for recursive SCCs.
The prototype's naive pre-pass was 3×.

**Risk: medium.** It adds nothing in expressiveness over D (formal §3:
L2 and L3 are equally expressive wherever there is a body), so it can
wait for evidence that `from` is noise in real programs.

---

## 10. Field precision

### 10.1 L1a: owner-side loan paths (disjoint lends)

**Data.** `Loan.path: PathId`: an interned chain of field symbols,
where 0 is the whole value. An index step ends the path, since every
element is one place. `Place` (resolvePlace 1774) gains `path`.

**Conflicts.** `findLoan(root, q)` → `findLoanAt(root, path, q)`. Two
loans conflict when their paths are prefix-related.

| Operation | Path it uses |
|---|---|
| `borrowVar` | the place's path |
| `walkFieldAssign` 2713 (assigning `p.f`) | the target's path |
| `moveVar`, `walkDrop`, `reassign` | whole |
| reading `p.y` | the path |
| a method receiver reservation | the receiver place's path |
| `holdArgRead` | the place's path |

**The read side is the expensive part.** Today reading `p.y` goes
`walkMember → walk(p) → walkName → checkReadable(p)` and checks the
whole root. A path-aware read means a `walkPlaceRead` for member
chains: about 25 call sites in `walk*`.

**Self-loans: mandatory, and found in this review.**

- `absorbLoans` drops `l.root == id` silently (3226).
- `walkFieldAssign` unions without a self check (2752).
- `storeThroughLocal` and `walkLambda`'s capture absorption likewise.

Today a store of `?p.own` into `p.r` is unreachable: the root is
borrowed (`self_store.rig` is rejected at the assignment). With paths,
it becomes reachable. Each of these sites must *reject* a stored loan
rooted at the receiving var (formal §2.5 hazard 1). A `match` payload
`alias_path` (string) is the existing precedent for paths.

**Fixes and cost.** It fixes `disjoint*.rig`. About 350–500 lines.
**Risk: high**, because the conflict queries are the heart of the
checker. It needs the one-ownership-branch slot to itself.

### 10.2 L1b: holder-side parts

**Data.** This is an optional refinement beside the union:

```zig
const Part = struct { field: u16, loans: []const Loan };
const Value = struct { loans: []const Loan = &.{}, parts: []const Part = &.{} };  // loans = ∪ parts
const Flow  = struct { ..., parts: []const Part = &.{} };
```

Only one level, top-level fields. Every existing reader of `.loans`
stays correct: a whole use reads everything, as formal's "whole-use
completeness" requires.

**The new code sits only at refinement sites:**

| Site | What it does with parts |
|---|---|
| A constructor in `walkCall` (namesType) | builds the parts |
| `walkMember` and the D2 projection | project a part |
| `walkFieldAssign` on an owned local | a **strong** update of the part. Today it is a weak union even for an owned local (2753), a separate precision gain. |
| `joinFlow` | pointwise union; a side without parts drops the parts |
| The call rule | per-field result origins (`Origins.result_parts`); inferred from a returned constructor's parts; declared as `-> Split(rest from s, sep from sep)` |

**Liveness, which is what makes `pair.rig` pass.**

- `indexUses` records `member(p, f)` as a use of `(sym(p), f)`, and any
  other use of `p` as whole.
- In `findLoan` (1107), a loan held only in part `f` of a holder is in
  force while the holder is whole-live (`holderLive`, drop glue
  included) or `(holder, f)` is used later.
- Since `last_use` is per symbol, this needs a second map:
  `(SymbolId, u16) → u32`.

**Fixes and cost.**

- **Fixes:** `pair.rig`, `mkpair.rig` (past Rust), `u2_struct.rig`
  (frees `x`), and, with D2, `split.rig`.
- **Size:** about 600–900 lines.
- **Risk: high.** `holderLive` and `findLoan` are where every
  non-lexical decision is made, and the gain beyond Rust is narrow
  (formal §3). Build it last, and only for split-like code in real
  programs.

---

## 11. Cross-cutting

### 11.1 Statement temporaries (the fragile area)

**Rule for every layer:** change `result` and the per-write-argument
`stored`, and **nothing** in this list:

- `temps` (2928–2943);
- `holdTemp` 1376;
- `dropStmtTemps` 1386;
- `headerTempLoan` 1418;
- `capture` 947 (the round-3 report);
- `stmt_drops`;
- the match `hold` var.

**Why narrowing a result is safe here:**

- **An owning temporary argument** (`?mk()`, `?Text(..)`) is a hidden
  var, and the argument's value is a loan on it.
  - If the mask excludes that argument, the result does not carry the
    loan. `dropStmtTemps` and the header check then see nothing to
    report. That is correct, because the callee proved it
    (`u10_temp_ok`; `hdr_sep_temp.rig` becomes acceptable with `cut`
    declared `from s`).
  - If the mask includes it, everything reports as today (`u9_temp`).
- **The lends inside excluded arguments** stay in `temps` until the
  statement ends. That is conservative inside the statement, and is
  today's behavior.

**Two follow-ups would shrink `temps`.** Each is a separate,
temporaries-touching commit, run against the full corpus and the
extended matrix (step 2's §4.0 rules):

- ending excluded arguments' lends at the call (`keepViewTemps` for
  all results);
- the L0 version for `!c.next()` twice in one statement.

**After step 2,** `exitTo` reports every loan a path drops, so the
recorder's only hook is the `.return` exit.

### 11.2 Cell, Signal, owned closures (sentence 9)

These are unchanged. The `cell` branch (2869–2885) and `walkLambda`'s
owned-capture rejection run before any narrowing, and an owned
closure's value carries no loans.

The static-parameter layer (§8) is the only one that relaxes them, and
it shares the recorder. A future rule, "a `*fun` carries its contents'
loans like `*T`", would make an owned closure's inferred mask
meaningful at calls through it. It is out of scope here.

### 11.3 Closures and `?fun`

- **The environment is always in the result.** `walkName(callee)` and
  `lendClosure` (1700) supply it.
- **Masks only ever narrow the parameters.**
- **A closure's body is a function:** `FnCtx.actual` is per closure,
  and `in_closure` keeps captures (`root < closure_base`) out of the
  parameter bits.

### 11.4 Generics

- **A generic body is walked once,** with `T` opaque. A `T`-typed
  parameter carries an external token (`mayCarryBorrow` is true for a
  type variable), so its mask is exact.
- **Defaults come from the generic signature,** so no parametricity
  argument is needed. If member access on `T` ever exists, nothing
  breaks: the default stays "`T` produces everything".
- **`checkInstantiations` (536)** is unaffected. Instances of generic
  functions still reject a `T` holding a view.

### 11.5 Cross-module

- **D and P:** the function type is the contract, and `importType`
  copies `origins`.
- **S:** an exported set per `pub` symbol, through `importParam`.
- **I:** never exported, by design.

---

## 12. Order, size, risk

| # | Layer | Lines (net) | Risk | Ownership slot | Flips (reject tests that lose a line) | Unlocks |
|---|---|---|---|---|---|---|
| 0 | Mapping fact `call_params` + `Origins` + recorder + call rule (no narrowing yet: the default is "all", so it is IR-equivalent) | +150 | low | yes | none | the rest |
| 1 | P: `produces` default + body check (6.3) | +190 | low–med | yes | none expected; `r01`–`r04` become behavior | `method_key`, `produces` |
| 2 | L0 carry (one `carry` classifier) | +160 / −60 | medium | yes | none expected | `cursor`, `deep2`, `prefix` |
| 3 | D: declared `from` (grammar, resolve, type, typecheck shape, ownership check, closures and `?fun`, extern zig, std annotations) | +350 | medium | yes | none (new syntax) | `two`, `strip`, `cut`, `firstmut`, `generic`, `recur`, `funval`, `closure_ret`, `store`, `br_x01` |
| 4 | D2 depth/path tokens | +120 | medium | yes | none | the holder-owns-target shape |
| 5 | S static parameters (6.2) | +300–450 | medium | yes | the 6.2 list in audit-steps3-6 | `t06`, `t07`, `t09`, `n09`, `static_param` |
| 6 | I: private inference (optional) | +230 | medium | yes | none | annotation-free private code |
| 7 | L1a owner paths + self-loan rejections | +350–500 | high | yes, alone | `disjoint` | disjoint field lends |
| 8 | L1b parts + per-field liveness + per-field results | +600–900 | high | yes, alone | none | `pair`, `mkpair`, `split`, `u2_struct` |

**Dependencies:**

- **Steps 1 and 2 of HANDOFF come first:**
  - `may hold a loan` as a step 1 type fact;
  - `handsOver.static` and `exitTo` from step 2.
- **3.1a's `lendsAs`** is wanted before P, so its rows become edges.
- Layers 0–3 are one branch at a time, each green on the four gates.
- **Promoting the Core's sentence 7 `pending` example** belongs to
  layer 3, with CORE, SPEC, BEYOND-RUST §2 ("the trade"), DESIGN
  "Borrows without lifetimes", and INTERNALS ("loans travel with
  values").

---

## 13. Tests that would prove each layer

### 13.1 Behavior tests (accepted, sanitizer-clean, output checked)

- Each probe the layer unlocks.
- Every argument shape at a narrowed call:
  - a lend of a local, a field, an element, a slice, and a `Text` lent
    as a String;
  - a view parameter passed on;
  - an owning temporary in the excluded position;
  - a keyword argument, a default, and a receiver;
  - a compile-time parameter;
  - a generic instance;
  - a recursive and a mutually recursive callee.

### 13.2 Reject tests (one per sibling; "fix the class")

- **Callee side: the body exceeds its `from`.** Each return form must
  be rejected:
  - a tail value, `return`, an `if` branch, a `match` arm;
  - a loop's `break` value, `e catch d`, `o ?? d`, `if o as v`;
  - a field of a local struct holding both;
  - a call to an un-narrowed callee;
  - a local closure returning a captured parameter;
  - a `match` payload of a parameter;
  - a `for` element of a parameter.
- **Stores beyond the declared mask:**
  - a field assign through `!h`;
  - a call that stores, through `absorbLoans`;
  - `storeThroughLocal`;
  - a defer that stores.
- **Function values:**
  - a function or closure binding with a wider mask lent to a narrower
    `?fun`;
  - an owned closure, likewise.
- **The mapping trap:** `kw_args_trap.rig`, and its receiver and
  `T.m(..)` twins.
- **L0:**
  - a holder that also owns the target (`cursor_own` with two `next`
    calls kept live);
  - a write-view field;
  - a Box, a `*T`, a generic `T` field, an enum payload, a recursive
    type.
- **L1a:**
  - each self-loan site (§10.1);
  - `<p` and `-p` while `p.x` is lent;
  - an index path overlapping a field path.
- **L1b, each whole use while a part is lent:**
  - `print(p)`, `==`, a copy, passing, returning, `match`;
  - a `drop` body;
  - `+p`, `<p`;
  - a defer reading `p`;
  - a join where one side has no parts.

### 13.3 An origins matrix: `test/origins.py`, beside `matrix.py`

- **The grid.** Callee shape × argument form × after-action × use.
  - **Callee shapes:**
    - a free `fun`;
    - a method with `?self` or `!self`;
    - generic;
    - recursive;
    - a `?fun` parameter;
    - a closure lent;
    - an owned closure;
    - a std `extern zig`;
    - an imported module.
  - **Argument forms:** those of §13.1.
  - **After-actions:** write, reassign, move, or drop the excluded
    owner or the included owner.
- **It writes its own expected verdict:** rejected if and only if the
  touched owner is an included argument (or the call is un-narrowed).
  - Every accepted program runs under `RIG_SANITIZE=1`.
  - Every rejected one must give a `file:line:col` diagnostic.
- **This is the "test that catches a sibling"** for the mapping and
  for each new call shape.
- **Run it at `-j 2`, outside the default suite**, like the extended
  matrix. Add its two worst cells to the default sample.

### 13.4 Unit tests (`zig build test`)

- `produces` and `ownReach`: a table over every type form, imported
  nominals included.
- `call_params`: one row per call shape.
- `effectiveOrigins` for a generic and its instance.

---

## 14. What the reference checker must model

From `design-reference-checker.md` §3.4:

- **F4** (a call result carries every argument) and **F5** (`!` roots
  gain every argument) become **Σ-filtered**.
- **C6** (exit check) becomes **`Σ_actual ⊆ Σ_effective`**, plus the
  existing "external or static only".

**What it needs, written without reading `ownership.zig`:**

1. **Its own argument-to-parameter mapping** from the IR and the
   callee's declaration.
   - Do not share `call_params`: a shared mapping bug would fool both
     checkers.
   - Share only `callSlotsOf` for keyword and defaulted calls, and
     cross-check its arity.
2. **Its own `produces` and `ownReach`** over sema's types, from the
   Core's sentence 7 and §4, and its own default masks.
   - **The mask fact.** It reads `FunctionType.origins` (a shared sema
     input), but recomputes its *own* actual mask per body and compares
     it. If a resolve bug makes the declared mask wrong, both checkers
     still disagree with the body, so the bug is visible.
3. **External loans per parameter** (per slot with D2): "issued(L, P)"
   at entry. **The environment** for callables, always.
4. **L0 carry** as its own rule on lends and call results.
5. **With L1b:** parts per holder, and per-field liveness `live(V.f,
   P)` in its backward liveness. Whole uses are listed by the Core,
   not copied from the production checker.
6. **With S:** the static obligation closure (§8).
7. **The disagreement classes this adds:**
   - **`prod-strict`:** production rejects, and the reference infers a
     narrower mask. This one is useful: it finds where `from`, or
     inference, is missing in std.
   - **`prod-unsound`:** production narrows past the reference's mask.
     The likely cause is the mapping or a `FunctionType` copy site.

---

## 15. What "100%" leaves out

- **Not origins (formal §4):**
  - a view inside an owned closure, a Cell, or a Signal (sentence 9);
  - a callback that stores its argument (`hr_store.rig`);
  - branded lifetimes.
- **Inherent, and in Rust too:**
  - a result whose origin depends on a run-time value (the union is
    the right answer);
  - the elements of a Vec or array of views share one slot;
  - recursive types collapse to one slot;
  - a mutable cursor.

**With layers 0–4 and 8**, every "which argument does the result or a
store view" program in formal.md §1 that Rust accepts is accepted,
except those rows. The BEYOND-RUST trade becomes:

> Rig says which argument a result views (`from a`), and the compiler
> proves it from the body. Without `from`, a result views every
> argument that could hold such a view.

## Probe index (`probes-impl/`)

- **Accepted by the prototype, and sanitizer-clean:** `u3b_swap_ok`,
  `u10_temp_ok`, `param_count`, plus the parent's `two.rig` and the
  formal set's `recur`, `generic`, `produces`.
- **Rejected by the prototype, correctly:** `u1_paths`, `u2_struct`,
  `u3_swap`, `u4_loop`, `u5_closure`, `u7_mutual`, `u8_byval`,
  `u9_temp`, `kw_args`, `kw_args_trap`.
- **Today's behavior noted:**
  - `self_store` is rejected at the assignment; L1a must keep it
    rejected;
  - `hdr_sep_temp` is rejected today, and acceptable under D;
  - `cursor_own` is accepted, used once;
  - `two_temp_stmt` is accepted.
- **The prototype diff:** `proto-inferred.diff`. Scratch only, not for
  merging. It uses a pre-pass and treats keyword calls conservatively.
