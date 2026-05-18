# Rig — Session Handoff (post-M20h, PB1 effectively complete)

**You are picking up a Rig compiler session mid-arc.** M20h
(owned / escaping closures) shipped end-to-end (1/5 → 5/5);
the Phase B reactive canary now exercises a retained M20h
closure (effectively PB1). The next concrete action is
**M20i — resource-aware `Vec(T)`** for multi-subscriber lists.
Read top-to-bottom once; then it's a reference.

---

## TL;DR

- **Project**: Rig is a systems language ("Zig-fast, Rust-safe,
  Ruby-readable") that compiles to Zig 0.16. Repo:
  `/Users/shreeve/Data/Code/rig`.
- **Where we are**: M20h shipped end-to-end (commits `f4b448c..a4505d5`).
  `examples/reactive_canary.rig` now demonstrates Cell + stack-
  local closure (M20g) + retained `*Closure()` (M20h) all
  composing — the substrate piece Phase B's reactive validation
  needed. **746 tests passing, 0 failing.** Clean tree on
  `main`, all pushed.
- **Next concrete action**: **start M20i design checkpoint**
  with GPT-5.5 (resource-aware `Vec(T)` for multi-subscriber
  callback lists). Then implement in 3-5 sub-commits per the
  M5-style cadence. M20i's load-bearing question: how does
  `Vec(~Effect)` handle `push` / `drop` / `resize` for
  refcounted element handles without leaking refcounts? A
  naive `ArrayList(handle)` wrapper memcpy-copies handles
  and double-frees on resize.
- **Phase B sequence updated**:
  `PB0 ✅ → M20h ✅ → PB1 (covered by canary refresh) →
  M20i (next) → PB2 → PB3`. PB1's "single retained Effect"
  ships via the canary's `eff: *Closure() = *Closure(fn |+count|
  ...); eff()` block — the next canary extension is multi-
  subscriber notification (PB2), which needs `Vec(~Effect)`.
- **Owner**: Steve (`shreeve@github`). Collaborates with the AI
  agent AND consults GPT-5.5 via the `user-ai` MCP for design
  checkpoints + post-implementation reviews.
- **Established cadence**: design checkpoint → implement in 3–5
  sub-commits (M5-style: `Mxx(n/total)`) → post-implementation
  review → commit. Each sub-commit must keep all tests passing.

---

## 1. Project orientation (read these first)

Authoritative project docs, in order of importance for the
next arc:

| File | Purpose |
|---|---|
| `docs/REACTIVITY-DESIGN.md` | **Phase B starts here.** The design note that drove the M20+ ordering. Phase A (substrate) is done; Phase B is the rig-reactive validation milestone. |
| `SPEC.md` | Language spec. §Lambdas (M20g) documents capture modes + V1 non-escaping rule. §Shared Ownership covers M20d (handles), M20e (auto-drop), M20f (Cell). |
| `docs/ROADMAP.md` | Milestone history (M0 → M20g done). M20+ list shows item #8 (closure captures) is now ✅; only items #9-#17 (substrate maturity) remain before V2. |
| `docs/SEMANTIC-SEXP.md` | Sema IR shape. What the grammar emits, what the checker walks. |
| `docs/INHERITED-FROM-ZAG.md` | Grammar/lexer surface inherited from the Zag/Nexus stack. |
| `rig.grammar` | Nexus grammar. Conflict count currently **38** (unchanged across M20g). |

Codebase highlights:

| File | Role |
|---|---|
| `src/rig.zig` | Lexer rewriter + Tag enum. M20g added `captures` / `cap_*` tags. |
| `src/parser.zig` | **Generated** by `zig build parser` from `rig.grammar`. Don't edit by hand. |
| `src/types.zig` | Sema: SymbolResolver, TypeResolver, ExprChecker, Type interner, lookup helpers. ~6500 lines after M20g. New: `SymbolKind.capture`; `synthLambda` + `validateCaptures` + `walkLambdaBody`; `SemContext.lambda_return_types` map. |
| `src/emit.zig` | Zig codegen. ~3500 lines after M20g. New: closure struct emit (`emitClosureBinding` + a dozen helpers); `SymbolEntry.is_closure`; `lookupIsClosure` rewrites `f()` → `f.invoke()`. |
| `src/ownership.zig` | M2-era borrow/move checker. M20g added: `Binding.is_closure`; `in_call_callee`/`in_set_rhs` context flags; dedicated `walkLambda` applying cap_move outer-state effects. |
| `src/runtime_zig.zig` | M20d V1 runtime as a Zig string constant (`RcBox` / `WeakHandle` / `Cell` / `rcNew` / etc.). Unchanged in M20g. |
| `src/main.zig` | CLI driver. Writes `_rig_runtime.zig` sibling file in `emitProjectToTmp`. |
| `build.zig` | Build steps. `zig build`, `zig build parser`, `zig build test`. |
| `test/run` | Test driver. `./test/run` to verify; `./test/run --update` to regenerate goldens. |
| `EMIT_TARGETS` in `test/run` | Names of `examples/` to run end-to-end. M20g added the 4 positive closure examples. |

---

## 2. M20+ status (V1 substrate)

| # | Item | Status | Where |
|---|---|---|---|
| 1 | Instance methods + `self` semantics + receiver-style calls | ✅ | M20a + M20a.1 + M20a.2 |
| 2 | Real generic-instance member typing | ✅ | M20b(4/5) |
| 3 | Generic methods on generic types | ✅ | M20b(4/5) + M20b(5/5) |
| 4 | `Option(T)` / `Result(T, E)` as generic enum types | ✅ | M20c |
| 5 | Methods on enums | ✅ | M20a |
| 6 | `*T` / `~T` real `Rc` / `Weak` semantics | ✅ | M20d + M20d.1 + M20d.2 |
| 6.5 | Automatic scope-exit drop | ✅ | M20e + M20e.1 |
| 7 | Interior mutability — `Cell(T)` library type | ✅ | M20f + M20f.1 |
| 8 | Closure capture mode syntax (non-escaping V1) | ✅ | M20g (1-5/5) + M20g(2.1) |
| 8.5 | Owned/escaping closure values | ✅ | M20h (1-5/5) + M20h.1 |

**The V1 ownership substrate is COMPLETE + has its first
escape-aware abstraction.** Items 9-17 are substrate maturity
(`unsafe` lattice, `try_block` lowering, explicit error sets,
etc.) — important but not blocking Phase B.

## Phase B status

| Step | Item | Status | Where |
|---|---|---|---|
| PB0 | Reactive canary scaffold | ✅ | `examples/reactive_canary.rig` |
| M20h | Owned/escaping closure values | ✅ | commits `f4b448c..a4505d5` |
| PB1 | Single retained Effect | ✅ | folded into canary refresh (M20h(5/5)) |
| M20i | Resource-aware `Vec(T)` | 🚧 | NEXT: design checkpoint |
| PB2 | Cell → Effect notification | pending | depends on M20i |
| PB3 | Memo + batching + topology | pending | depends on PB2 |

---

## 3. M20h retrospective (the just-completed arc)

### Design lock (entry 17 — DO NOT re-checkpoint)

Five locked decisions, all enforced by the test corpus:

1. **Surface**: `cb: *Closure() = *Closure(fn |+count| body)`.
   Mirrors `*Cell(value: 0)` (explicit `*` for visible heap
   alloc + refcount). Bare `Closure(fn ...)` rejected with
   tailored hint.
2. **Type spelling**: `Closure()` zero-arity only in M20h.
   `Closure(Int)` errors with "expects 0 type arguments, got
   1"; bare `Closure` errors with "must be written with empty
   parentheses". Arity-bearing closures (Closure1<T>, etc.)
   deferred.
3. **ABI**: type-erased `rig.Closure0` vtable + per-literal
   anonymous env struct. Surface type is uniform
   `*rig.RcBox(rig.Closure0)`. Each closure literal gets a
   unique env struct + invoke/drop thunks; `ctx: *anyopaque`
   hides the layout.
4. **Drop model**: `RcBox.dropStrong` runs payload's
   `__rig_drop` (gated by `comptime hasRigDrop(T)`) on LAST
   strong drop. Closure0's `__rig_drop` calls the per-literal
   `rigDrop` thunk → capture drops + `allocator.destroy(env)`.
   The earlier proposal that ran capture-drop from each
   binding's scope-exit defer was caught and rejected at
   design time — would UAF on `cb2 = +cb; -cb; cb2()`.
5. **Ownership relaxation**:
   `in_owned_closure_constructor_arg` is a NEW context flag
   set ONLY for the exact `*Closure(fn ...)` shape. `walkLambda`
   accepts ANY of three flags now (`in_set_rhs ||
   in_call_callee || in_owned_closure_constructor_arg`). The
   M20g non-escaping rules still apply everywhere else.

### Implementation summary

Sub-commit by sub-commit (all on `main`):

| Commit | What it shipped |
|---|---|
| `f4b448c` M20h(1/5) | Runtime + type spelling. `Closure0` vtable + `hasRigDrop` predicate + `RcBox.dropStrong` `__rig_drop` hook in `runtime_zig.zig`. `Closure` builtin (zero arity) registered in `types.zig`. Emit lowers `*Closure()` → `*rig.RcBox(rig.Closure0)`. Bare `Closure` / `Closure(Int)` / redefinition diagnostics. |
| `3f00bdf` M20h(2/5) | Sema for construction + invocation. `detectOwnedClosureConstruction` intercepts `(share (call Closure (lambda ...)))` in `synthExpr` → returns the precise closure handle type. `cb()` typing for owned closures returns void. Diagnostics: bare `Closure(fn ...)` no `*`, non-lambda arg, wrong arity, `cb(args)`. Grammar: new `FN captures inline_body` form with `inline_body = call → (block 1)` so single-call lambda bodies parse inside `(...)`. Conflict count: 38 → 69. |
| `64e29ab` M20h(3/5) | Ownership relaxation. New `walkShare` dispatcher detects owned-closure construction and sets `in_owned_closure_constructor_arg` for the inner walk. `walkLambda` escape check accepts the new flag; reset inside the body so nested constructions don't inherit. Pre-M20h `return *Closure(fn ...)` (rejected by M20g) now passes. |
| `a4505d5` M20h(4/5) | Emit construction + invocation — the load-bearing emit work. `emitOwnedClosureConstruction` produces a labeled-block expression with an inline `Env = struct { ... fn rigInvoke ... fn rigDrop ... }`; env is heap-allocated via `rig.defaultAllocator().create(Env)`, captures init via reuse of M20g's `emitClosureInit` with a leading `.` for the inferred struct literal, wrapped in `Closure0` + `rig.rcNew`. `emitCall` adds the M20h `cb.value.invoke()` rewrite. `is_owned_closure` SymbolEntry flag set by `emitSetOrBind` via three signals (RHS / type annotation / sema). |
| TBD M20h(5/5) | Tests + canary + docs. 4 positive (EMIT_TARGETS) + 4 negative examples. `examples/reactive_canary.rig` updated to include a retained M20h closure. SPEC §Lambdas extended with §Owned Closures (M20h). ROADMAP M20h entry. This HANDOFF refresh. |

### Verified end-to-end behaviors

- **Stack-local construction**: `cb: *Closure() = *Closure(fn
  |+count| count.set(count.get() + 1)); cb(); cb()` compiles
  + runs (count is 2 after two invocations).
- **Escaping return**: `fun make_counter() -> *Closure() { ...
  *Closure(fn |+count| ...) }; cb = make_counter(); cb()`
  works. The local Cell binding is dropped at function exit
  but the closure's cloned strong handle keeps it alive.
- **Clone-doesn't-drop-early**: `cb = make_counter(); cb2 =
  +cb; -cb; cb2(); cb2()` runs cleanly. The Cell payload is
  freed only when BOTH `cb` and `cb2` drop their strong
  handles — last-strong-drop semantics work as designed.
- **Move capture**: `*Closure(fn |<count| ...)` compiles +
  runs; outer `count` enters `.moved` state.
- **Escape rejection still works**: bare `f = fn |...| ...;
  return f` (M20g shape) still rejected. Only the exact
  `*Closure(fn ...)` shape gets the new flag.
- **The canary refresh** (`examples/reactive_canary.rig`)
  prints `1\n3\n13` — M20f Cell set/get + M20g stack-local
  closure + M20h retained-effect-closure all composing.

### M20h deferred — explicitly NOT done

1. **Arity-bearing closures** (`Closure1<T>`, `Closure2<A, B>`,
   etc.). Required for callbacks with arguments. The M20h
   ABI is committed to no-arg / void-return; arity-bearing
   variants need a parallel `Closure1` / `Closure2` runtime
   type per arity + sema/emit dispatch on signature. Likely
   a future M20j or after Phase B exposes the need.
2. **Multi-statement closure bodies**. The new grammar form
   is `FN captures call` (the `inline_body` non-terminal is
   a single `call`). Multi-stmt bodies still need indented-
   block lambdas which don't compose inside `(...)`.
   Workaround: lift the work into a named helper sub and
   have the closure call it.
3. **`fn || expr` empty-capture inline form**. Grammar
   `captures = BAR_CAPTURE capture BAR_CAPTURE` requires
   non-empty captures, so empty `||` doesn't parse. The
   existing `fn block` no-capture indented form works for
   block-bodied cases, but inline `fn || expr` doesn't.
   Most callbacks capture something, so not urgent.
4. **~~Pre-existing M20g `in_set_rhs` leak~~ FIXED in M20h.1**:
   was — a bare lambda inside an array literal at set-RHS
   position (`xs = [fn |+x| ...]`) silently passes
   ownership because `in_set_rhs` flows through the array
   element walk. GPT-5.5's M20h post-implementation review
   flagged this as a must-fix-before-M20i (Vec storage
   shapes hit it directly), and M20h.1 narrows the flag to
   direct lambda RHS only. See ROADMAP §M20h.1.
5. **Method-value form** (`Effect(count.changed)` syntax).
   Deferred indefinitely; for V1 users always wrap the
   method in a lambda.

---

## 4. M20g retrospective (prior arc — kept for reference)

### Design pass (GPT-5.5, locked)

The five binding rules from the M20g checkpoint, plus tactical
clarifications from the M20g(2/5) post-implementation review.
Do NOT re-derive these:

1. **Default `|x|` is Copy-only.** Resources (`*T`/`~T`) MUST
   use explicit mode (`|+x|` / `|<x|` / `|~x|`). Without this,
   `|rc|` would hide a refcount-bump (violating M20d's
   visible-effects rule).
2. **NO `|*x|` capture mode.** `*` already means "allocate Rc
   by moving expr in"; overloading would be confusing.
   Strong-clone capture spells as `|+rc|`.
3. **V1 closures are STRICTLY non-escaping.** Allowed only as
   `(set ...)` RHS or as `(call ...)` callee. No return / no
   call arg / no record field / no aliasing. Reactive callback
   storage needs a future M20h (or a trusted Reactor/Effect
   builtin).
4. **Closure values are non-copyable AND implicitly fixed.**
   `g = f` rejected; `f = fn ...; f = fn ...` rejected.
5. **Captured resource guards live in the closure-instance's
   enclosing scope**, not inside the closure body. (Otherwise
   each invocation would drop the capture; second invocation
   would UAF.)

Tactical Q&A (from M20g(2/5) checkpoint, also locked):

- **Ownership-side `Binding.is_closure` flag**, NOT a
  `Type.closure` variant. The type variant would cascade into
  `compatible` / `formatType` / emit's type lowering for
  zero V1 benefit; the ownership flag is sufficient because
  closures are structurally distinguishable in the IR.
- **Context tracking via two Checker bools** (`in_call_callee`
  + `in_set_rhs`) rather than an enum stack. The only "allowed"
  contexts for a closure value are call-receiver and set-RHS;
  two bools suffice.
- **EMIT_TARGETS strategy**: Copy-only closure in (3/5);
  resource captures added in (4/5) once the closure-instance
  guard discipline lands. Avoids ever shipping leaky golden
  Zig output.

### Implementation summary

Sub-commit by sub-commit (all on `main`):

| Commit | What it shipped |
|---|---|
| `99927c0` M20g(1/5) | Grammar + lexer + IR shape extension. Lambda IR: `(lambda CAPTURES PARAMS RETURNS BODY)`. New tags: `captures`, `cap_copy`, `cap_clone`, `cap_weak`, `cap_move`. SymbolResolver scaffolding (no binding yet). |
| `3b26692` M20g(2/5) | Sema + ownership. `SymbolKind.capture`, `synthLambda` mode validation, `Binding.is_closure`, context flags, non-escaping enforcement, dedicated ownership `walkLambda`. |
| `5413c8e` M20g(2.1) | Polish: tailored "cannot reassign closure binding" diagnostic per GPT-5.5's review (was the generic `=!` message users never wrote). |
| `dcc5baa` M20g(3/5) | Emit: closure struct + `invoke(self: *@This())`; `f()` → `f.invoke()`; capture remapping to `self.cap_<n>`; `SemContext.lambda_return_types` for inferred Zig return types. Copy-only example in EMIT_TARGETS. |
| `b8a3248` M20g(4/5) | Auto-drop: per-resource-capture guards at the closure-instance enclosing scope. clone/weak/move examples added to EMIT_TARGETS. |
| TBD M20g(5/5) | Docs (SPEC §Lambdas + ROADMAP M20g + this HANDOFF refresh). |

### Example file naming convention (kept for future closure tests)

Positive: `closure_capture_<mode>.rig` (in EMIT_TARGETS).

Negative: `closure_<scenario>_rejected.rig` (sema/ownership goldens only):
- `closure_resource_default_rejected.rig` — `|rc|` for `*T`
- `closure_copy_rejected.rig` — `g = f` for closure
- `closure_escape_return_rejected.rig` — `return fn ...`
- `closure_escape_arg_rejected.rig` — `foo(f)` for closure
- `closure_capture_param_collision_rejected.rig` — `fn |x| (x: Int)`
- `closure_nested_capture_rejected.rig` — `fn |+rc| fn |+rc| ...`
- `closure_reassign_rejected.rig` — closure-fixed reassignment

### Deferred from M20g (revisit when relevant)

1. **Multi-capture syntax** (`fn |+rc, n| body`). V1 grammar
   accepts a single capture node; the IR shape already wraps it
   in a `(captures cap_node...)` list so future multi-capture
   is purely a grammar + capture-iteration extension. Defensive
   duplicate-name detection is already plumbed in
   `SymbolResolver.bindCaptures`.
2. **Inline-call shape `(fn |...| body)()`**. The
   ownership-side accept list includes this position, but the
   parser rejects it due to the indented-block / suffix-call
   composition. SPEC §Lambdas documents the limitation.
   Closing it requires a grammar refinement around block-as-
   expression composability — out of scope for V1.
3. **Nested-lambda capture from outer closure**. Rejected with
   a dedicated diagnostic; emit would need to clone
   `self.cap_<n>` from the outer closure into the inner
   closure's init expression. Future "escaping closures"
   M20h work would handle this naturally.
4. **Value-returning closures with non-primitive return types**.
   Current `emitZigTypeForTypeId` handles primitives, shared/
   weak, nominal, parameterized_nominal. Closures returning
   unusual types (slices, fn-types, etc.) fall back to `void`.
   Not a hard blocker — the V1 use cases (Phase B Effects)
   are void-returning callbacks.

---

## 4. Phase B plan (scoped with GPT-5.5; conversation entries 15-16)

The Phase B scoping checkpoint produced an agreed sequence
through ~12-20 commits over the next 6-10 weeks. **Do NOT
re-litigate Q1-Q5 below — they were decided collaboratively
and locked.** Each subsequent Mxx arc (M20h, M20i) gets its
own design checkpoint when it starts.

### Agreed sequencing

```
PB0:  Minimal reactive canary scaffold      ✅ shipped
M20h: Owned/escaping closure values         ← NEXT: design checkpoint
PB1:  Single retained Effect using M20h
M20i: Resource-aware Vec(T)                 ← design checkpoint when reached
PB2:  Cell → Effect notification (multi-subscriber)
PB3:  Memo + batching + topology
```

### Locked decisions (Q1-Q5 from the Phase B checkpoint)

**Q1 — Minimum canary first, NOT the full ~500-line library.**
Each surfaced language gap gets its own Mxx commit on main;
the library grows in `examples/reactive_canary.rig` (single
file until M15b cross-module sema improves) as those commits
land. Avoids speculatively designing M20h/M20i with no concrete
use exposing what shape they need.

**Q2 — Narrow M20h (escaping closures), NOT trusted Effect/Memo
builtins.** This is the load-bearing decision. The original
lean (mirror the `Cell` builtin playbook for `Effect` / `Memo`)
was rejected because it would HIDE the gap Phase B is supposed
to expose. Quote from GPT-5.5: *"Cell was acceptable as a
builtin because interior mutability is a primitive unsafe
abstraction with no user-level unsafe yet. Effect/Memo are
library constructs. If you bake them into the runtime, the
canary stops testing whether Rig can express retained
callbacks."* The Rig substrate must grow real escaping
closures; the library stays library-level.

**Q3 — Defer `Vec(T)` until PB1 exposes the need.** First
retained Effect uses a single-callback slot. When `Vec(T)`
does land (as M20i), it MUST be resource-aware: `push` /
`drop` / `resize` correctly handle `*T` / `~T` element
ownership; no naive `std.ArrayList` wrapper that memcpy-copies
handles.

**Q4 — Hybrid on main, single-file until M15b.** Language
fixes ship as normal Mxx commits with the M5-style cadence.
The canary file (`examples/reactive_canary.rig`) IS the
regression test and lives in `EMIT_TARGETS`. Start single-file
to avoid cross-module sema weakness masking errors; split into
`test/modules/reactive/` only after M15b matures.

**Q5 — Functional canary + docs as success.** Phase B done
when a single end-to-end test passes (e.g., `count.set(2);
reactor.flush(); effect observes new value`) AND SPEC
documents what subset of reactivity works + what's
intentionally deferred. NOT the full 500-line library — the
canary is the validation deliverable.

### M20h scope guardrails (locked at Phase B checkpoint)

When M20h gets its own design checkpoint, these are the
already-locked constraints. The checkpoint scopes syntax,
ABI, drop model, type spelling — NOT whether to do M20h.

```
IN:  no-arg or fixed-arity closures (matching M20g lambda params)
     heap-owned closure environment
     resource captures dropped with the closure
     call/invoke after defining-scope exit
     store in struct field (so a parent can retain the closure)

OUT: async, traits / interfaces, dynamic dispatch over arbitrary
     signatures, closure equality, closure cloning, fallible
     callbacks (`fn() -> Void!`), cross-module closure ABI
```

GPT-5.5's and my shared bias for the M20h syntax: explicit
`*Closure(fn |+rc| body)` constructor (mirrors `*Cell(value: 0)`)
versus overloading `*lambda` to mean both "Rc allocate" and
"synthesize closure object with generated ABI / drop glue."
NOT locked — the M20h checkpoint should weigh both with the
emitter constraints in view.

Substrate gaps GPT-5.5 flagged that M20h/PB1/PB2/PB3 will
encounter (Phase B checkpoint, entry 15):

1. **Closure type spelling and ABI** — FnOnce vs FnMut vs Fn-like.
   Start with no-arg void; defer the trait hierarchy.
2. **Resource containers** — `Vec(~Effect)` push/drop/resize
   must move handles correctly. M20i designs this.
3. **Built-in optional ergonomics** — `weak.upgrade()` returns
   `(*T)?`; match/unwrap may need cleanup before subscriber
   lists are pleasant.
4. **Method values / function references** — `Effect(count.changed)`
   form deferred initially.
5. **Fallible callbacks** — defer until `try_block` emit lands;
   initial closures are `fn() -> Void`.

### Minute-1 next session

```bash
git pull --ff-only
git log -1 --format='%h %s'   # should be at or after M20h.1
./test/run 2>&1 | tail -3     # should print "754+ passed, 0 failed"
bin/rig run examples/reactive_canary.rig    # prints "1\n3\n13"
```

### Minute-2: scope M20i with GPT-5.5

M20i (resource-aware `Vec(T)`) needs a fresh design
checkpoint — unlike M20h, this isn't locked. Concrete
questions for the GPT-5.5 checkpoint:

1. **Builtin vs library**: Q2 of the Phase B checkpoint
   leaned "Cell as builtin OK because primitive; Effect /
   Memo as user code". Where does `Vec(T)` fall?
   - Lean **builtin** for V1 because: heap allocation +
     refcount-handle semantics are baked-into-runtime
     territory, paralleling Cell.
   - Counter-lean: a real `Vec` has push/pop/iter/clear/etc.
     and Rig should be expressive enough to write it.
   - Defer the call to the checkpoint.
2. **Resource discipline**: For `Vec(*T)` (vec of strong
   handles), `Vec(~T)` (vec of weak handles), `Vec(T)` (vec
   of Copy types) — what's the V1 API contract?
   - `push(<rc)` move-into vec? `push(+rc)` clone-into vec?
   - `remove(i)` returns the moved-out element vs drops it?
   - `clear()` drops all elements?
   - `Vec(*T)` whole-vec drop: does it walk each element
     and call `dropStrong`?
3. **Generic parameterization**: `Vec(T)` is generic in T.
   M20c's generic enum machinery + M20b's generic struct
   machinery cover the typing side. The runtime emit shape
   needs to handle both Copy and Resource element types.
4. **Sema integration**: `Vec` becomes another reserved
   builtin name (like Cell, Closure). The arity / type-
   parameter contract is `Vec(T)` exactly one type arg.
5. **PB2 driver**: with `Vec(~Effect)` in place, the canary
   gains a multi-subscriber demo
   (`count.subscribe(eff); count.set(2); flush()` → each
   eff invoked). The PB2 commit drives the M20i API shape.

### Minute-3: start M20i(1/N) after checkpoint

The Phase B Q1-Q5 locked decisions still apply. Hybrid on
main, single-file canary, narrow language-fixes rather than
trusted builtins where possible.

---

**Below: legacy M20h plan (kept for reference; M20h shipped
2026-05-17 — see §3 above for the implementation summary).**

**Locked M20h design (entry 17 summary):**

- **Surface**: `cb: *Closure() = *Closure(fn |+count| body)`
  — explicit constructor, mirrors `*Cell(value: 0)`. NOT
  `*lambda` sigil overload; NOT `own fn` keyword.
- **Type spelling**: `Closure()` only in M20h (special-case
  empty `()` since it would normally hit the generic-empty-
  params rejection). NO args, NO return type yet — pure
  no-arg void closures. Reject `Closure(Int)`, bare
  `Closure`, etc.
- **ABI** (this is the load-bearing call; entry 17 caught a
  UAF in an earlier proposal):
  - New runtime type `rig.Closure0` with vtable:
    `ctx: *anyopaque`, `invoke_fn`, `drop_fn`, `allocator`.
  - Each closure literal generates a UNIQUE env struct
    (`RIG_CLOSURE_ENV_N`) holding captures + invoke/drop
    thunks. Env is heap-allocated SEPARATELY from the RcBox.
  - `RcBox.dropStrong()` gets a NEW hook: when payload type
    has `__rig_drop`, call it before freeing. Closure0
    implements `__rig_drop` to call `drop_fn(ctx, allocator)`.
  - Surface type `*Closure()` lowers to
    `*rig.RcBox(rig.Closure0)` UNIFORMLY (type erasure;
    enables return-from-fn, store-in-struct, future Vec).
- **Why type erasure**: each closure literal has a different
  anonymous env struct, but the surface type must be uniform
  so multiple closure literals can be assigned to the same
  `*Closure()` variable, returned from functions, stored in
  containers, etc.
- **Ownership**: owned closure becomes a regular `*T` handle
  (clonable via `+cb`, moveable via `<cb`, weakable via `~cb`,
  storable in struct fields, returnable). NOT marked
  `is_closure=true`. M20g's `is_closure` flag is only for
  bare lambda values.
- **Allow lambda in constructor arg**: dedicated
  `in_owned_closure_constructor_arg` flag, set ONLY for the
  exact `*Closure(fn ...)` shape. Do NOT generalize to all
  constructors (would prematurely allow `Effect(fn ...)` /
  `Box(fn ...)` before escaping semantics exist for arbitrary
  APIs).
- **Invocation**: `cb()` plain call syntax, lowered to
  `cb.value.invoke()`. Reject `cb(args)` in M20h.
- **Capture semantics**: same as M20g (cap_copy / cap_clone /
  cap_weak / cap_move) but drop happens at `__rig_drop` time
  (last strong drop), NOT at each binding's scope-exit
  defer. THIS IS CRITICAL — the earlier proposal that called
  capture-drop from every binding's defer would UAF when
  `cb2 = +cb; -cb; cb2()`.

**Sub-commit decomposition (5, not 4)**:

```
M20h(1/5): runtime + type spelling
  - add rig.Closure0 (vtable struct) to runtime
  - add RcBox.__rig_drop hook (call payload's __rig_drop on last strong)
  - register Closure builtin (special-case empty arity)
  - sema accepts Closure() type; rejects other arities
  - emit type Closure() → rig.Closure0; *Closure() → *rig.RcBox(rig.Closure0)
  No closure construction emit yet.

M20h(2/5): sema / call typing
  - *Closure(fn ...) recognized as owned closure construction
  - cb() typechecks when cb: *Closure()
  - reject cb(args), bare Closure(fn ...), Closure(Int), etc.

M20h(3/5): ownership relaxation
  - add in_owned_closure_constructor_arg context flag
  - allow lambda literal only in exact owned-closure-constructor-arg shape
  - owned closure binding is NOT is_closure; ordinary shared handle
  - capture move effects still apply to outer

M20h(4/5): emit owned closure construction + invocation
  - generate env struct (RIG_CLOSURE_ENV_N) with invoke/drop thunks
  - allocate env, init captures, build Closure0, rcNew
  - cb() → cb.value.invoke()

M20h(5/5): tests + PB1 + docs
  - retained-callback test (returns *Closure() from a function)
  - clone-doesn't-drop-early test (catches the UAF the design fixed:
    `cb2 = +cb; -cb; cb2()` must NOT drop captures until cb2 also drops)
  - move-capture test
  - escape rejection still works for non-wrapped lambdas
  - bare `Closure(fn ...)` rejected
  - SPEC §Lambdas extension + ROADMAP + HANDOFF refresh
```

Required regression tests (called out at entry 17 — these
pin the design decisions):

1. **Basic retained callback** (returns `*Closure()` from a
   function, invokes after defining scope exits).
2. **Clone doesn't drop captures early** (`cb2 = +cb; -cb;
   cb2()` — the test that proves type-erasure + `__rig_drop`-
   on-last-strong is correct).
3. **Move capture** (`*Closure(fn |<count| ...)`).
4. **Escape rejection** for non-wrapped lambdas still works
   (M20g enforcement preserved).
5. **Bare `Closure(fn ...)` rejected** (the owned form is
   `*Closure(fn ...)` — without `*` is an error).

Then post-implementation review with GPT-5.5 in the same
conversation. Then PB1.

---

## 5. Working conventions (unchanged)

### Git

- All commits on `main`. No feature branches.
- Sub-commit style: `Mxx(n/total): short summary`.
- ALWAYS pass multi-line commit messages via HEREDOC.
- Push after every commit.

### Testing

- `./test/run` — run all 700+ tests + Zig unit tests
- `./test/run --update` — regenerate goldens
- Add new examples to `EMIT_TARGETS` for end-to-end coverage

### GPT-5.5 collaboration

Non-negotiable per Steve. Use the `user-ai` MCP server's
`discuss` tool with `conversation_id: "c_5c1d09d53ebe2f62"` and
`model: "openai:gpt-5.5"`. Set `max_tokens >= 6000`.

Pattern: design checkpoint → implement → post-implementation
review → commit. Polish from the review ships as `Mxx.1`.

### Editing conventions

- DO NOT edit `src/parser.zig` directly — it's generated.
- DO use `ReadLints` after substantive edits.
- DO use `TodoWrite` for multi-step tasks.

---

## 6. The user-ai MCP conversation

Persistent conversation ID: **`c_5c1d09d53ebe2f62`**

Now contains, in order:
1. M20a thesis review
2. Reactivity design discussion
3. M20a–c design + review cycles
4. M20d design + post-(1/5) refinements + tactical Q2/Q3/`*T?`-precedence round
5. M20d Q1 (auto-drop discipline) joint decision
6. M20d.1 review fixes round
7. M20d.2 (`^w` sigil vs method form) joint decision
8. M20e design checkpoint — the defer-guard redirection
9. M20e post-implementation review (M20e.1 review fixes round)
10. M20f design checkpoint — Cell synthetic methods + Copy-only
11. M20f post-implementation review (M20f.1 fixes round)
12. M20g design checkpoint — capture modes + non-escaping closures
13. M20g(2/5) tactical checkpoint — closure-value enforcement
    point, escape-detection scope, etc. Locked the Q&A
    summarized in §3 above.
14. M20g(2/5) post-implementation review — cleared (2/5),
    surfaced one polish item (closure-reassign diagnostic →
    M20g(2.1)) and emit guidance for (3/5).
15. **Phase B scoping checkpoint** — locked Q1-Q5 (minimum
    canary first, narrow M20h not trusted builtins, defer Vec
    until PB1 exposes the need, hybrid on main with single-file
    until M15b, functional canary + docs as success). Locked
    M20h scope guardrails (IN/OUT lists in §4 above).
16. Phase B scoping confirmation — locked sequencing
    (`PB0 → M20h → PB1 → M20i → PB2 → PB3`), confirmed PB0
    content (working Cell+stack-local closure + commented
    M20h/M20i TODOs as gap markers, not syntax promises),
    confirmed fresh M20h checkpoint required before coding.
17. **M20h design pass** — locked syntax (`*Closure(fn ...)`
    constructor), type spelling (`Closure()` only, no args
    in M20h), ABI (type-erased `rig.Closure0` + vtable +
    `RcBox.__rig_drop` hook), ownership (owned closure is
    regular `*T` handle; dedicated
    `in_owned_closure_constructor_arg` flag for the lambda
    arg position), invocation (`cb()` → `cb.value.invoke()`),
    and the 5-sub-commit decomposition. The checkpoint CAUGHT
    a UAF bug in an earlier ABI proposal (capture-drop from
    every binding's defer would UAF on `cb2 = +cb; -cb;
    cb2()`); type erasure + `__rig_drop` on last strong is
    the fix. See §4 above for the full locked design summary.
18. **Grammar-blocker resolution for M20h(2/5)** — picked the
    narrow `FN captures inline_body` form (with `inline_body
    = call → (block 1)`) over braces or pre-bind workarounds.
    Conflict count 38 → 69 (all benign S/R, prefer-shift).
19. **M20h post-implementation review** — signed off the
    full arc with one must-fix (`in_set_rhs` leak → M20h.1)
    and several wording refinements (M20h-as-async substrate
    not ABI; bare-Closure rejection wording; "Closure0"
    numbering rationale).
20. **Async / Clojure / Nexis influence review** (the most
    recent turn). Reviewed Claude's analysis of a ChatGPT-5
    digest on Rust async + Clojure borrowings + Steve's Nexis
    project. Corrected: M20h validates substrate not ABI;
    PersistentVec-first for M20i is overreach (M20i stays
    mutable resource-aware Vec). Signed off `docs/INFLUENCES.md`
    with small wording fixes (now applied).

To continue the thread for the next arc, pass `conversation_id`
and `model` as above. Models live in
`/Users/shreeve/.cursor/projects/Users-shreeve-Data-Code-rig/mcps/user-ai/tools/`.

---

## 6b. Future arcs (deferred, NOT roadmap commitments)

These are documented in `docs/INFLUENCES.md` as design-space
options to weigh when the time comes. They are NOT on the
near-term roadmap; they are NOT promises to ship.

- **Async via `^` sigil**. Plausible candidate spellings:
  `^expr` (await), `^T` (Future<T>). NOT `expr^` (suffix
  preserved for future use; deliberate non-commitment).
  Async ships only after structured concurrency, which
  ships only after reactivity validation. See INFLUENCES §3
  and §8 Rule 2.
- **Structured concurrency**. The layer between reactivity
  (M20i / PB2 / PB3) and async. Trio-style nurseries vs
  Kotlin-style coroutine scopes is an open question. Design
  checkpoint after Phase B is done.
- **CHAMP-backed persistent collections**. Architecturally
  studied via the Nexis project (`/Users/shreeve/Data/Code/nexis`),
  which ships real CHAMP + plain trie + transients + xxHash3
  on Zig. Nexis brought its own GC; Rig cannot. Implementation
  options: Rc-every-node (viable but expensive), arena-per-
  snapshot (defeats the point), region/epoch (open).
  Demoted to M20j+ conditional on Phase B exposing the need.
- **User-defined `Drop`**. The M20h `__rig_drop` runtime hook
  is already extensible to user types declaring `__rig_drop`.
  When V1 grows a Drop story, the substrate is ready.
- **Style guide that idiomatically prefers `=!`**. NOT a
  surface flip; cultural / documentation. See INFLUENCES §5.

---

## 7. Hazards / known fragilities

### V1-substrate hazards (unchanged from prior HANDOFFs)

1. **Don't extend `unwrapReadAccess` to peel `weak`.** Weak
   handles require explicit `.upgrade()`.
2. **Don't let auto-deref bridge write/value receivers.**
   M20d(4/5)'s `checkReceiverMode` adding `.shared` rejection
   is the safety check.
3. **Don't `@constCast(sema)` in emit.** Use
   `typeEqualsAfterSubst` for type comparisons.
4. **Don't use a mutable global allocator.** Allocator is in
   `RcBox`.
5. **Don't use `u32` for refcounts.** `usize` per GPT-5.5.
6. **Don't make `Option` / `Result` the built-in optional /
   fallible representation.** `T?` and `T!` are separate
   built-in types.
7. **Don't skip the GPT-5.5 review loop.** Most recently,
   GPT-5.5's M20g(2/5) review surfaced the closure-reassign
   diagnostic polish AND endorsed the (3/5) emit shape before
   we coded it.
8. **Don't ship `^w` upgrade-sigil without re-checkpointing.**
   M20d.2 reserved this as a future-sugar candidate; three
   hard constraints documented if it ever ships.

### M20g-specific notes

1. **`Binding.is_closure` + `fixed=true` are paired.** Set both
   when emit's `walkSet` sees a lambda RHS. The fixed flag
   prevents reassignment; the closure flag drives the
   non-escaping enforcement in `checkPlainUse`.
2. **The two context bools (`in_call_callee` + `in_set_rhs`)
   reset inside the lambda body.** ownership.zig's `walkLambda`
   does this explicitly so a nested `f = fn ...; f()` inside
   the body doesn't inherit the outer construction's flags.
3. **Capture-name body refs map via emit's scope frame, NOT a
   global name scan.** A new scope frame is pushed at invoke
   body entry; each capture's `zig_name` is the fully-qualified
   `"self.cap_<n>"` string. Body `emitExpr` on a bare `.src`
   does the normal `self.lookup(text)` and writes
   `"self.cap_<n>"` literally. Don't add a global-name-scan
   shortcut here — emit's known-fragile global scan was paid
   down in M20e.1 specifically to avoid this kind of
   shadow-sensitive hazard.
4. **Closure-instance guards key on `<closure>.cap_<n>`**, NOT
   on a separate `__cap_<n>` const intermediate. Per GPT-5.5's
   emit guidance: keep the indirection at the captured-field
   level, not a separate binding. LIFO defer ordering takes
   care of "closure drops before outer" automatically.
5. **`closure_capture_weak.rig` uses a void-body** to avoid
   `.upgrade()`'s optional-formatting in the golden. If a
   future test wants to exercise upgrade-then-format, expect
   to plumb a custom format helper or accept the Zig
   default-format ugliness.

### Pre-existing fragilities NOT addressed in M20g

1. **`(T)?` paren-grouping in type position**: the grammar's
   `"(" type ")" → 2` action leaks the literal parens into the
   IR, so users can't currently spell `(*T)?` in type
   annotations. Workaround: type inference. Pre-existing.
2. **Emit's global name scans in legacy paths** (the M20a.2
   `two_self_methods` shape uses a global name scan in
   print-polish). The high-stakes consumers (auto-drop disarm,
   closure capture remap) are scope-aware; this remaining
   global scan is acceptable until a sema-side use-site
   attribution table (`pos → SymbolId` built during
   type-check) lands.
3. **`SymbolResolver.walkSet` outer-scope assignment**:
   M20e(3/5) dedup is same-scope only. Worth auditing against
   SPEC's "implicit shadowing is illegal" rule when a future
   arc touches block-scoped state.
4. **`scanMutations` per-block `seen` masking** — `i = i + 1`
   inside a nested block is treated as a fresh declaration
   instead of a mutation. Workaround: use `i += 1`.
5. **`unsafe` / `%x` enforcement** (M20+ item #9) — pre-existing
   deferral, unchanged.
6. **`try_block` emit** (M20+ item #14) — pre-existing
   `@compileError`. Blocks M20e's try/catch resource test (and
   any Phase B Effect that wants to propagate errors out of a
   callback).

---

## 8. If you get stuck

- **Tests failing after a change**: `./test/run 2>&1 | grep FAIL`
  shows just the failures. Most failures are golden diffs from
  intended changes — verify with `git diff test/golden/` and
  `./test/run --update` if intentional.
- **Grammar conflict count changed**: revert and reconsider.
  The 38 conflicts are all reviewed and intentional.
- **Sema diagnostic isn't firing**: check that the IR shape
  reaches the right walker. `bin/rig normalize path/to/file.rig`
  prints the semantic IR.
- **Zig compile error in emitted code**: `bin/rig run
  path/to/file.rig` shows both the path AND the Zig error.
  For shared/weak issues: inspect both `/tmp/rig_<name>/<name>.zig`
  AND `/tmp/rig_<name>/_rig_runtime.zig`.
- **Closure-specific**: if a closure isn't behaving, check the
  emitted Zig for the `cap_<n>` fields and the
  `__rig_alive_<closure>_cap_<n>` guards. The body should
  reference captures via `self.cap_<n>`.
- **General confusion**: read `docs/REACTIVITY-DESIGN.md` — for
  the next arc, that document IS the design.

---

## 9. Closing notes from the M20g session

- The biggest design win of the M20g arc was GPT-5.5's "no
  `Type.closure` variant" pushback at the tactical checkpoint.
  My original lean was to add a closure type to the type system
  for symmetry with shared / weak. GPT-5.5 saw that the type
  variant would cascade into `compatible`, `formatType`, emit
  type lowering, and possibly function-type interop — for V1's
  non-escaping non-copyable closures, structural recognition
  via the lambda IR head is sufficient. The result: closure
  semantics live on the ownership pass's `Binding.is_closure`
  flag, type checking continues with `unknown_id`, and the
  whole substrate stays clean.
- The `_ = self;` pacification for void-body closures with
  unreferenced captures was a small but important detail. Zig
  refuses both "unused parameter" AND "pointless discard" —
  the `bodyReferencesAnyCapture` scan is the right size of
  workaround.
- The closure-instance guard discipline composes beautifully
  with M20e's defer-guard strategy. LIFO defer ordering means
  "drop the closure's captures first, then the outer's
  bindings" Just Works without explicit ordering logic.
- The whole V1 substrate (M20a + M20b + M20c + M20d + M20e +
  M20f + M20g) now composes through closures: a closure can
  capture a `*Cell(T)` clone, invoke `.set(x)` on the cell from
  inside the body, and have everything drop cleanly at scope
  exit. That's the substrate working AS DESIGNED — and it sets
  Phase B up to demonstrate the same composition end-to-end.

Good luck. Read `docs/REACTIVITY-DESIGN.md`, run a design
checkpoint with GPT-5.5, then scope Phase B at whatever
sub-commit granularity feels right for the validation
milestone.
