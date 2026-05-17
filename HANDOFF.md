# Rig — Session Handoff (post-PB0, Phase B scoped)

**You are picking up a Rig compiler session mid-arc.** M20g
shipped end-to-end (V1 substrate complete); PB0 (Phase B
canary scaffold) just landed; Phase B has been scoped with
GPT-5.5 and the agreed plan is below. The next concrete
action is the **M20h design checkpoint** (escaping closures).
Read top-to-bottom once; then it's a reference.

---

## TL;DR

- **Project**: Rig is a systems language ("Zig-fast, Rust-safe,
  Ruby-readable") that compiles to Zig 0.16. Repo:
  `/Users/shreeve/Data/Code/rig`.
- **Where we are**: M20g (V1 substrate) shipped end-to-end. **PB0
  (Phase B canary scaffold)** landed at `examples/reactive_canary.rig`
  with `M20f` Cell composition and `M20g` stack-local closure
  invoke both verified end-to-end. **706 tests passing, 0
  failing.** Clean tree on `main`, all pushed.
- **Next concrete action**: **M20h design checkpoint** —
  escaping/owned closure values. Phase B's load-bearing first
  substrate gap. The Phase B scoping checkpoint already
  produced the IN/OUT scope guardrails for M20h (see §4 below);
  the M20h-specific checkpoint locks the syntax, ABI, drop
  model, and type spelling.
- **Phase B is scoped** (entries 15-16 in the user-ai
  conversation): the agreed sequence is
  `PB0 → M20h → PB1 → M20i → PB2 → PB3`. PB0 done.
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

**The V1 ownership substrate is COMPLETE.** Items 9-17 are
substrate maturity (`unsafe` lattice, `try_block` lowering,
explicit error sets, etc.) — important but not blocking the
reactivity validation milestone.

## Phase B status

| Step | Item | Status | Where |
|---|---|---|---|
| PB0 | Reactive canary scaffold | ✅ | `examples/reactive_canary.rig` |
| M20h | Owned/escaping closure values | 🚧 | NEXT — design checkpoint |
| PB1 | Single retained Effect | pending | depends on M20h |
| M20i | Resource-aware `Vec(T)` | pending | depends on PB1 exposing the need |
| PB2 | Cell → Effect notification | pending | depends on M20i |
| PB3 | Memo + batching + topology | pending | depends on PB2 |

---

## 3. M20g retrospective (the just-completed arc)

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
git log -1 --format='%h %s'   # should be HEAD at or after PB0 commit
./test/run 2>&1 | tail -3     # should print "706+ passed, 0 failed"
bin/rig run examples/reactive_canary.rig    # prints "1\n3"
```

### Minute-2: read the agreed scope above

Re-read §4. Q1-Q5 are locked. M20h scope IN/OUT is locked.
The remaining open decision is the M20h checkpoint itself:
syntax, ABI, drop model.

### Minute-3: run the M20h design checkpoint

Open the user-ai conversation (`c_5c1d09d53ebe2f62`,
`model: "openai:gpt-5.5"`, `max_tokens >= 6000`) and run a
focused M20h checkpoint covering:

- Syntax: `*Closure(fn |+rc| body)` constructor vs `*lambda`
  sigil overload vs `own fn |+rc| body` new keyword
- ABI: closure environment layout, invoke method signature,
  generated drop glue for resource captures
- Type spelling: `*Closure()` / `*Closure(args, returns)` /
  something else
- Drop model: refcounting (Rc-wrapped) vs unique ownership
  (the `*T` shape implies Rc but Effects don't need sharing)
- Interaction with M20g's `is_closure` / `non-escaping`
  enforcement: M20h needs to relax this for closures that
  are explicitly `*Closure(...)`-wrapped
- Sub-commit decomposition (~3-5 sub-commits expected,
  matching the M20d/M20e/M20g pattern)

Then implement. Then post-implementation review. Then PB1.

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
16. **Phase B scoping confirmation** — locked sequencing
    (`PB0 → M20h → PB1 → M20i → PB2 → PB3`), confirmed PB0
    content (working Cell+stack-local closure + commented
    M20h/M20i TODOs as gap markers, not syntax promises),
    confirmed fresh M20h checkpoint required before coding.

To continue the thread for the next arc, pass `conversation_id`
and `model` as above. Models live in
`/Users/shreeve/.cursor/projects/Users-shreeve-Data-Code-rig/mcps/user-ai/tools/`.

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
