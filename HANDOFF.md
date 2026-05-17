# Rig — Session Handoff (post-M20g(1/5))

**You are picking up a Rig compiler session in mid-arc.** This document
captures everything you need to continue cleanly. Read top-to-bottom
once; then it's a reference.

---

## TL;DR

- **Project**: Rig is a systems language ("Zig-fast, Rust-safe,
  Ruby-readable") that compiles to Zig 0.16. Repo:
  `/Users/shreeve/Data/Code/rig`.
- **Where we are**: Just shipped **M20f + M20f.1** (interior
  mutability via the built-in `Cell(T)` type, plus post-review
  fixes) AND **M20g(1/5)** (closure capture grammar + IR
  foundation per a fresh GPT-5.5 design checkpoint).
  **648 tests passing, 0 failing.** Clean tree on `main`, all
  pushed. The V1 ownership + interior-mutability substrate is
  complete; closure capture is half-built (grammar/IR done;
  sema/emit/auto-drop pending).
- **Next milestone**: **complete M20g** — sub-commits (2-5/5)
  remain. Grammar + IR foundation shipped in (1/5); (2/5) sema
  capture binding + mode validation, (3/5) emit closure as
  anonymous Zig struct + invoke method, (4/5) auto-drop
  integration with M20e guards, (5/5) SPEC + ROADMAP + HANDOFF.
  Design checkpoint with GPT-5.5 is LOCKED (see §3 below for
  the design decisions). Next session can start (2/5)
  immediately without re-checkpointing.
- **Owner**: Steve (`shreeve@github`). Collaborates with the AI
  agent AND consults GPT-5.5 via the `user-ai` MCP for design
  checkpoints + post-implementation reviews.
- **Established cadence**: design checkpoint → implement in 3–5
  sub-commits (M5-style: `Mxx(n/total)`) → post-implementation
  review → commit. Each sub-commit must keep all tests passing.

---

## 1. Project orientation (read these first)

Authoritative project docs, in order of importance:

| File | Purpose |
|---|---|
| `SPEC.md` | Language spec. §Shared Ownership documents: auto-drop semantics (M20e), alias-footgun rule (M20d), `*T?` vs `(*T)?` precedence (M20d.1), `*expr` move semantics (M20d), built-in `~T.upgrade()` method (M20d.2), `Cell(T)` interior mutability + Copy-only restriction (M20f), resource-temporaries boundary (M20e.1). |
| `docs/ROADMAP.md` | Milestone history (M0–M20f done; M20g(1/5) shipped, (2-5/5) pending). M20+ list shows what's next. |
| `docs/REACTIVITY-DESIGN.md` | Substrate design note. The forcing function for M20+ work. |
| `docs/SEMANTIC-SEXP.md` | Sema IR shape. What the grammar emits, what the checker walks. |
| `docs/INHERITED-FROM-ZAG.md` | Grammar/lexer surface inherited from the Zag/Nexus stack. |
| `rig.grammar` | Nexus grammar. Conflict count currently **38**. |

Codebase highlights:

| File | Role |
|---|---|
| `src/rig.zig` | Lexer rewriter + Tag enum. |
| `src/parser.zig` | **Generated** by `zig build parser` from `rig.grammar`. Don't edit by hand. |
| `src/types.zig` | Sema: SymbolResolver, TypeResolver, ExprChecker, Type interner, lookup helpers. ~6100 lines after M20f.1. M20f's `registerBuiltins(ctx, module_scope)` registers built-in Cell. |
| `src/emit.zig` | Zig codegen. ~2800 lines after M20f. M20e guard/disarm helpers + M20f Cell-binding `var` emit + M20g(1/5) lambda IR walker. |
| `src/ownership.zig` | M2-era borrow/move checker. M20d added the alias-footgun rule. |
| `src/runtime_zig.zig` | M20d V1 runtime as a Zig string constant (`RcBox` / `WeakHandle` / `rcNew` / etc.). |
| `src/main.zig` | CLI driver. Writes `_rig_runtime.zig` sibling file in `emitProjectToTmp`. |
| `build.zig` | Build steps. `zig build`, `zig build parser`, `zig build test`. |
| `test/run` | Test driver. `./test/run` to verify; `./test/run --update` to regenerate goldens. |
| `EMIT_TARGETS` in `test/run` | Names of `examples/` to run end-to-end. |

---

## 2. M20+ status (post-M20g(1/5))

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
| 8 | **Closure capture mode syntax** | 🚧 | **M20g(1/5) shipped — grammar + IR. (2-5/5) pending.** |

---

## 3. Retrospectives + decisions locked

### M20e — auto-drop via Zig `defer` guards

M20e shipped as 5 sub-commits. The single biggest design moment
was the GPT-5.5 redirection during the M20e checkpoint — captured
here so future sessions don't re-derive it.

#### The design redirection

I went into the checkpoint proposing **CFG-aware explicit drop
synthesis**: extend `ownership.zig` to walk the scope chain at
every exit point (early return, break, continue, match-arm
divergence, try-catch propagation), insert `(drop x)` IR nodes
at the right edges, handle per-branch convergence with explicit
analysis. The HANDOFF I wrote post-M20d framed M20e this way.

GPT-5.5's intervention: **don't build a mini-MIR drop elaborator.
Use Zig `defer` guards.**

For every resource binding, emit (illustrative):

```zig
const rc = rig.rcNew(...) catch @panic("...");
var __rig_alive_rc: bool = true;
defer if (__rig_alive_rc) {
    __rig_alive_rc = false;
    rc.dropStrong();
};
```

Explicit discharges disarm the guard before the defer fires.
Zig's defer behavior is path-sensitive across branches, early
returns, break / continue, try / catch (when try-block emit
lands), and labeled-block recipes — without any Rig-side static
analysis.

This was a major simplification. The whole milestone collapsed
from "build a flow-aware drop elaborator" to "emit a guard + a
defer at binding sites, emit a disarm at discharge sites."

### What V1 auto-drop actually does

**Discharges (binding consumed, auto-drop suppressed)**:
- `-x` (explicit drop) — runtime call + disarm
- `<x` (move out, via argument / RHS / move-assign) — disarm +
  yield handle via labeled-block expression
- `return x` (bare resource return) — disarm before return
- Reassignment `x = *new(...)` — drop old, re-arm guard for new

**Non-discharges (binding still live, auto-drop fires at scope exit)**:
- `+x` (clone) — original + clone both auto-drop independently
- `~rc` (weak ref) — both shared + weak auto-drop independently
- `w.upgrade()` — fresh `(*T)?`, weak still live
- Field access (`rc.field`) and method calls (`rc.method()`) —
  M20d read-only auto-deref; non-consuming

**Drop order**: LIFO automatically (each defer queued at binding
site).

**Panic / unreachable**: defers don't run on `@panic` /
`unreachable`. Programs that panic with live handles leak. The
process is dying; this is fine.

### Implementation summary (in `src/emit.zig`)

Five new emit helpers + one Emitter field:

- `resourceKindOfBinding(name_node) -> ?ResourceKind` — sound
  under shadowing via `decl_pos` lookup.
- `resourceKindOfBareUse(name) -> ?ResourceKind` — use-site
  classification (inherits the global-scan fragility; see §8).
- `emitResourceGuard(zig_name, kind)` — the var + defer preamble.
  Uses disarm-inside-defer pattern so Zig doesn't complain about
  "never mutated" in the pure-auto-drop case.
- `emitResourceDisarm(zig_name)` — the `= false` assignment.
- `emitDisarmIfBareResourceName(expr)` — convenience wrapper.
- `pending_param_guards: ?Sexp` Emitter field — staged by
  `emitFun`, consumed by `emitBlock` / `emitFunBody` to install
  guards for resource parameters right after the open brace.

Integration points:

- `emitSetOrBind`: fresh-binding branch installs guard; reassign
  branch emits drop-and-rearm for resource bindings.
- `emitBlock` / `emitFunBody`: call `flushPendingParamGuards`
  after `{\n`.
- `emitStmt.@"drop"`: appends disarm after the runtime call.
- `emitReturn` / `emitFunBody` implicit-return: prepend disarm
  for resource bare-name returns.
- `emitExprList.@"move"`: for bare resource names, wraps in a
  `rig_mv_N: { disarm; break :rig_mv_N x; }` labeled-block
  expression.

### Sema sub-fix in M20e(3/5)

Reassignment uncovered a pre-existing M5-era bug:
`SymbolResolver.walkSet` was adding a fresh symbol on every
`rc = X` (with the M5 TODO comment "Whether to add or reuse will
be revisited when ownership consumes sema"). This worked for
sema's own queries but produced an orphan first-symbol that
emit's forward-order scan picked up — `rc.field` after
reassignment failed to install the M20d `.value` bridge.

Fix: `walkSet` now dedups on `.default` kind via the new
`SemContext.lookupInScopeOnly`. `.fixed` (`=!`) and `.shadow`
(`new x = ...`) still unconditionally add new symbols.

### Tests added across M20e + M20e.1

M20e itself (six new EMIT_TARGETS):
- `auto_drop_basic.rig` — pure auto-drop, no explicit `-rc`
- `factory_returns_rc.rig` — bare `return rc` factory pattern
- `reassign_rc.rig` — drop-and-rearm on reassignment
- `auto_drop_if_else.rig` — branch divergence
- `auto_drop_early_return.rig` — early return from nested if
- `auto_drop_in_loop.rig` — resource declared inside while body

M20e.1 regressions (two new EMIT_TARGETS for fixes from GPT-5.5's
post-implementation review):
- `auto_drop_shadow_across_fns.rig` — scoped resource
  classification under cross-function shadowing.
- `move_assign_rc.rig` — `<-` move-assign disarms the RHS.

Plus 6 existing resource-bearing examples regenerated with the
M20e guard preamble.

**Total: 564 → 606 (+42).**

### M20e coverage gaps (deferred)

1. **`try_block` lowering with resource locals** — blocked on
   the pre-existing M20+ #14 gap (`try_block` emit still emits
   `@compileError`). Once try-block lands, defer-guard should
   Just Work; add the regression test then.
2. **`i = i + 1` inside a nested block** — pre-existing
   `scanMutations` issue with per-block `seen` masking the outer
   binding. Workaround: use `i += 1`. Unrelated to M20e.
3. **Unbound resource temporaries** — `(*User(...)).field` and
   similar shapes that don't bind the allocation to a name fall
   outside M20e's RAII contract. SPEC §Shared Ownership now
   documents the binding-only boundary; the M20e auto-drop
   only fires for named bindings and parameters. A future
   ergonomics milestone may close this by rejection or hidden-
   temp lowering.

---

### M20f — Cell(T) interior mutability

M20f shipped as 4 sub-commits. The full M20d + M20e + M20f arc
ended up being a tight coherent unit: shared/weak handles +
auto-drop + interior mutability are now all real V1 primitives
that compose end-to-end. GPT-5.5's M20f checkpoint produced
three corrections that shaped the final design:

#### Corrections from GPT-5.5's M20f checkpoint

1. **Cell is runtime-baked**, not a Rig source file. Parallel to
   `RcBox` / `WeakHandle`. Future stdlib types may live in
   `std/*.rig` once a layout coalesces.
2. **Synthetic ordinary methods, not ad-hoc sema intercept.** My
   original plan was to special-case Cell at `synthMemberCall`
   (parallel to M20d.2's `.upgrade()` intercept). GPT-5.5 pushed
   back: Cell is a NOMINAL type, modelable via M20b's generic-
   method machinery. Register Cell as a generic_type with
   synthetic `get(?self) -> T` and `set(?self, value: T)`
   methods; M20d's read-only auto-deref accepts them through
   shared naturally. No write-receiver bypass needed.
3. **`set(self: *Self)` in runtime, NOT `*const Self` +
   `@constCast`.** Only valid if the underlying storage is
   actually mutable. Use `*Self` and emit Cell bindings as
   `var`. `=!` (fixed) still prevents rebinding at the Rig
   level — SPEC permits interior mutation through fixed
   bindings.
4. **V1 restriction: `T` must be Copy.** The critical hazard.
   Non-Copy `Cell(T)` would let `set` corrupt ownership
   (overwriting a `*User` without dropping the previous handle).
   Enforced via `isCopyTypeForCell` predicate at
   `resolveType.@"generic_inst"` time.

#### What Cell(T) looks like

User-facing API:

```rig
sub main()
  rc: *Cell(Int) = *Cell(value: 0)
  rc.set(5)
  print(rc.get())        # 5
```

Lowers to:

```zig
pub fn main() void {
    const rc: *rig.RcBox(rig.Cell(i32)) =
        (rig.rcNew(rig.Cell(i32){ .value = 0 })
            catch @panic("Rig Rc allocation failed"));
    var __rig_alive_rc: bool = true;
    defer if (__rig_alive_rc) {
        __rig_alive_rc = false;
        rc.dropStrong();
    };
    rc.value.set(5);
    std.debug.print("{any}\n", .{ rc.value.get() });
}
```

The whole V1 ownership stack composes through Cell:
M20b parameterized_nominal + M20d shared + M20e auto-drop +
M20d read-only auto-deref + M20f synthetic Cell methods + M20f
Copy-only enforcement. No new sema dispatch for the shared
case — Cell's `get` / `set` are ordinary read-receiver methods.

#### Two emit-side fixes that landed in M20f(3/4)

1. **Expected-type propagation through `(share x)`** in
   `checkExpr`: with expected `shared(T)`, recursively
   `checkExpr(x, T)`. Lets `*Cell(value: 0)` with `rc: *Cell(Int)`
   drive M20b's substitution to `Cell(Int)` instead of erroring
   "unannotated generic constructor".
2. **Explicit-typed struct literal for built-in inner** in
   `(share inner)` emit: when inner is a built-in nominal call
   AND the LHS type wraps the same built-in, emit
   `rig.Cell(i32){ .value = 0 }` (typed literal) instead of
   `.{ .value = 0 }` (anonymous). Without this, `rcNew(anytype)`
   inferred a synthetic comptime struct. New Emitter field
   `current_set_type: ?Sexp` threads the LHS type through
   `emitSetOrBind` (saved/restored for nested bindings).

---

### M20g(1/5) — closure capture grammar + IR foundation

M20g(1/5) shipped at commit `99927c0` with a fresh GPT-5.5
design checkpoint. The remaining sub-commits (2-5/5) ship sema,
emit, auto-drop, docs — design is fully locked, no further
checkpoint needed before executing.

**Locked design decisions** (the 5 binding rules from
GPT-5.5's M20g checkpoint; do NOT re-derive):

1. **Default `|x|` is Copy-only.** Resources (`*T`/`~T`) MUST
   use explicit mode (`|+x|` / `|~x|` / `|<x|`). Without this,
   `|rc|` would hide a refcount-bump (violating M20d's
   visible-effects rule).
2. **NO `|*x|` capture mode.** `*` already means
   "allocate Rc by moving expr in"; overloading would be
   confusing. Strong-clone capture spells as `|+rc|`.
3. **V1 closures are STRICTLY non-escaping.** Can be bound
   to a local and invoked synchronously in the declaring
   scope. Cannot be returned, stored in structs/enums, or
   passed to APIs that retain them. Reactive callback
   storage needs a future M20h (or a trusted
   Reactor/Effect builtin).
4. **Closure values are non-copyable.** `g = f` where
   `f = fn |+rc| ...` must be rejected, otherwise resource
   captures double-drop (Zig struct copy without
   cloneStrong).
5. **Captured resource guards live in the
   closure-instance's enclosing scope**, not inside the
   closure body. (Otherwise each invocation would drop the
   capture; second invocation would UAF.)

**What (1/5) shipped:**
- Grammar: extended `lambda` rule with optional `|capture|`
  between FN and params. New `captures` sub-rule wraps the
  single-capture form. Conflict count unchanged at 38.
  Multi-capture (comma-separated) is a follow-up.
- Lexer: extended `isCapturePipe` probe to accept a single
  sigil-prefix token (`+`/`<`/`~`) before the captured ident.
  New `Lexer.isCaptureContentCat` predicate keeps sigil
  prefix + ident tokens from clearing `pending_close_bar`.
- IR shape: `(lambda CAPTURES PARAMS RETURNS BODY)` — 5
  children. CAPTURES is `_` (nil) or `(captures cap_node)`.
- New Tags: `captures`, `cap_copy`, `cap_clone`, `cap_weak`,
  `cap_move`.
- `SymbolResolver.walkLambda` updated for the new shape
  (items[2] is now params; captures slot is read but not yet
  bound — that's (2/5)).

**What (2/5) needs to do** (sema):
- Bind each capture's NAME in the closure body scope with
  the per-mode type:
  - `cap_copy`: requires outer Copy non-resource; binds with
    outer type. Reject `*T`/`~T` outer with the visible-
    effects diagnostic.
  - `cap_clone`: cloneStrong on `*T` → binds `*T`; cloneWeak
    on `~T` → binds `~T`; else copy-clone (Copy types).
  - `cap_weak`: requires outer `*T`; binds `~T`. Reject
    otherwise.
  - `cap_move`: moves outer; binds with outer type; outer
    enters `.moved` state (ownership pass picks this up).
- Reject closure escape (return / store / non-immediate
  use). Per GPT-5.5's V1 conservative path: accept only
  `f = fn |...| body` then immediate-invocation `f()` or
  inline `(fn |...| body)()`. Reject any other use.
- Reject closure-value copy/assignment.
- Implementation hook: `walkLambda` in `src/types.zig`
  already updated for the new shape. Bind-capture logic
  goes right before `try self.walk(body)`.

**What (3/5) needs to do** (emit):
- Closure value lowers to an anonymous Zig struct with a
  field per capture and a `pub fn invoke(self: *@This()) RT`
  method. Field-init at construct time:
  - `cap_copy`: `field = <outer_name>` (Zig value copy)
  - `cap_clone` (shared): `field = <outer>.cloneStrong()`
  - `cap_clone` (weak): `field = <outer>.cloneWeak()`
  - `cap_weak`: `field = <outer>.weakRef()`
  - `cap_move`: `field = blk: { __rig_alive_<outer> = false;
    break :blk <outer>; }`
- Inside the closure body, capture-name references map to
  `self.<field>`, NOT the outer-scope name. Per GPT-5.5:
  need an explicit emitter scope mapping (not the global-
  name-scan fallback). Add a capture-binding entry on the
  emitter's `ScopeFrame` that distinguishes "capture: emit
  as self.field" from "local: emit as bare name".
- `f()` lowers to `f.invoke()`.
- Implementation hook: `emitFun` in `src/emit.zig` already
  dispatches to lambda; needs lambda-specific path that
  emits the struct + invoke method.

**What (4/5) needs to do** (auto-drop integration):
- For each resource capture, install an M20e-style guard +
  defer in the enclosing scope of the closure instance:

  ```zig
  const __cap_rc = rc.cloneStrong();
  const f = struct { ... }{ .rc = __cap_rc };
  var __rig_alive_f_rc: bool = true;
  defer if (__rig_alive_f_rc) {
      __rig_alive_f_rc = false;
      f.rc.dropStrong();
  };
  ```

- For `cap_move`, the outer guard disarms (move semantics)
  and the closure capture takes over.
- Guard ownership is closure-instance-lifetime, NOT per-
  invocation. Closures may be invoked multiple times;
  drop happens once at scope exit.
- Implementation hook: extend `emitSetOrBind`'s resource-
  guard installation to also handle closure values that own
  resource captures. The closure struct value isn't itself
  a resource (no Rc), but its CAPTURED resources need
  M20e-style guards.

**What (5/5) needs to do** (docs):
- SPEC: new §Lambdas section (or expand §Shared Ownership)
  with the capture-mode table:
  - `|x|` → cap_copy (Copy required; resources rejected)
  - `|+x|` → cap_clone
  - `|~x|` → cap_weak (requires *T)
  - `|<x|` → cap_move (disarms outer)
  Document V1 non-escaping limitation explicitly. Note
  stored reactive callbacks need a future M20h or trusted-
  builtin path.
- ROADMAP: M20f section's M20g entry → full retro. M20+ #8
  → ✅. Note that the V1 ownership substrate is complete
  and Phase B of REACTIVITY-DESIGN.md becomes reachable.
- HANDOFF: refresh for the next session — substrate
  complete; what comes after (reactive validation, stdlib,
  unsafe enforcement, etc.).

**Example file naming convention for M20g tests:**
- Positive: `closure_capture_copy.rig`,
  `closure_capture_clone.rig`, `closure_capture_weak.rig`,
  `closure_capture_move.rig`, `closure_cell_mutation.rig`
  (the M20f integration test).
- Negative: `closure_resource_default_rejected.rig`
  (`|rc|` for resource), `closure_copy_rejected.rig`
  (`g = f` for closure value), `closure_escape_rejected.rig`
  (`return fn |+rc| ...`).

**Two open implementation questions for (2/5):**

- **Closure-value copy rejection enforcement point.** Sema
  or ownership? Ownership has the binding-tracker; sema has
  the type info. My lean: ownership-side rule that rejects
  any reassignment / parameter-pass / return of a closure
  value. The "closure type" is structural in Zig but
  semantically should be non-copyable in Rig. A simple
  marker on the binding (kind `.closure` or a flag on
  `Binding`?) suffices.
- **Escape detection scope.** Per GPT-5.5: V1 conservative
  acceptance is "local-binding-then-immediate-invoke" OR
  "inline-call". Any other use (return value, RHS of
  binding for non-call contexts, struct field, etc.) is
  rejected. Implementable in ownership.zig as a rule that
  fires when a closure-typed value appears in a non-call,
  non-bind-then-invoke context.

---

## 4. Quick-start for M20g(2/5)

The detailed retrospective for M20g(1/5) and the full plan
for sub-commits (2-5/5) live in §3 above. This section is a
quick orientation for a new session opening the repo.

### Minute-1: orient

```bash
git pull --ff-only
git log -1 --format='%h %s'   # should be HEAD at or after a4ecbdf
./test/run 2>&1 | tail -3     # should print "648 passed, 0 failed"
```

### Minute-2: read the locked design

§3 above. The five binding decisions are non-negotiable
(GPT-5.5 endorsed; do NOT re-checkpoint). Specifically:

- `|x|` is Copy-only — resources require explicit mode
- No `|*x|` (use `|+x|` for clone)
- Non-escaping closures only (no return/store)
- Closure values are non-copyable
- Capture guards live in closure-instance enclosing scope

### Minute-3: start coding sub-commit (2/5)

The first concrete step is in `src/types.zig`:

1. Find `walkLambda` (one of two; the SymbolResolver's
   `walkLambda` is around line ~852). It's already
   updated for the new IR shape; you'll extend its
   captures-handling.
2. Bind each capture's NAME into the closure's body scope
   with the per-mode type (see §3's (2/5) plan).
3. Reject `cap_copy` on resource types (the visible-effects
   diagnostic).
4. Add escape-detection in ownership.zig (a closure-typed
   value can only appear in immediate-call or
   local-binding-then-invoke positions).
5. Add closure-copy rejection in ownership.zig (treat
   closure bindings as Move-and-non-rebindable).
6. Add example files following the naming convention
   in §3.
7. Run `./test/run --update` to capture goldens, review
   diffs, run `./test/run` to verify all green.
8. Commit with M5-style header
   (`M20g(2/5): <short summary>`).

### Reading the GPT-5.5 design pass yourself

If you want to see the actual checkpoint message + the
response that locked the five decisions, use the `user-ai`
MCP server's `get_conversation` tool with
`conversation_id: "c_5c1d09d53ebe2f62"` to dump the thread.
The M20g checkpoint is the last design-pass turn (turn 12
in the running list — see §7 below).

---

## 5. Working conventions (unchanged from M20d HANDOFF)

### Git

- All commits on `main`. No feature branches.
- Sub-commit style: `Mxx(n/total): short summary`.
- ALWAYS pass multi-line commit messages via HEREDOC.
- Push after every commit.

### Testing

- `./test/run` — run all 648 tests + Zig unit tests
- `./test/run --update` — regenerate goldens
- Add new examples to `EMIT_TARGETS` for end-to-end coverage

### GPT-5.5 collaboration

Non-negotiable per Steve. Use the `user-ai` MCP server's
`discuss` tool with `conversation_id: "c_5c1d09d53ebe2f62"` and
`model: "openai:gpt-5.5"`. Set `max_tokens >= 6000`.

Pattern: design checkpoint → implement → post-implementation
review → commit.

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
12. **M20g design checkpoint — capture modes + non-escaping closures**

To continue the thread, pass `conversation_id` and `model` as
above. Models live in
`/Users/shreeve/.cursor/projects/Users-shreeve-Data-Code-rig/mcps/user-ai/tools/`.

---

## 7. Hazards / known fragilities

1. **Don't extend `unwrapReadAccess` to peel `weak`.** Weak
   handles require explicit `.upgrade()`. Adding silent weak
   deref would reintroduce null-deref hazards.
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
7. **Don't skip the GPT-5.5 review loop.** Cost: ~$0.30–$0.50
   per round; value: prevented soundness bugs in every M20
   milestone so far. Most recently, GPT-5.5's M20e checkpoint
   redirection (defer-guards instead of CFG drop synthesis)
   saved the milestone from being 2–3x larger and riskier.
8. **Don't ship `^w` upgrade-sigil without re-checkpointing.**
   M20d.2 reserved this as a future-sugar candidate; three
   hard constraints documented if it ever ships.

### Pre-existing fragilities NOT addressed in M20d/M20e

1. **`(T)?` paren-grouping in type position**: the grammar's
   `"(" type ")" → 2` action leaks the literal parens into the
   IR, so users can't currently spell `(*T)?` in type
   annotations. Workaround: type inference. Pre-existing.
2. **Emit's `handleKindOf` and `resourceKindOfBareUse` use a
   scope-aware lookup as of M20e.1** (the original first-match-
   wins global scan was a memory-safety hazard for auto-drop
   disarm and got fixed). The legacy concern about the M20a.2
   two-self-methods fragility (still uses a global name scan in
   the print-polish path elsewhere) remains; the systematic fix
   is a sema-side use-site attribution table (`pos → SymbolId`
   built during type-check) that all consumers can query.
   Lower priority now that the highest-stakes consumer
   (auto-drop) is sound.
3. **`SymbolResolver.walkSet` outer-scope assignment**: M20e(3/5)
   dedup is same-scope only. `x = ...` in an inner scope when
   `x` only exists in an outer scope currently still creates a
   fresh inner symbol — possibly inconsistent with SPEC's
   "implicit shadowing is illegal" rule. Worth auditing against
   the SPEC when M20g(2/5) starts touching block-scoped state
   (closure bodies are new scopes; closure-capture rules touch
   the same `walkLambda` machinery).
4. **`scanMutations` per-block `seen` masking** — `i = i + 1`
   inside a nested block is treated as a fresh declaration
   instead of a mutation. Workaround: use `i += 1`. Surfaced
   during M20e(4/5) loop test work.
5. **`unsafe` / `%x` enforcement** (M20+ item #9) — pre-existing
   deferral, unchanged.
6. **`try_block` emit** (M20+ item #14) — pre-existing
   `@compileError`. Blocks M20e's try/catch resource test.

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
- **M20e specific**: if an auto-drop scenario isn't behaving,
  check the emitted Zig for the `var __rig_alive_<name>` flag
  and the matching `defer if (__rig_alive_<name>) { ... }`.
  Use `bin/rig build foo.rig` to inspect emit without running.
- **General confusion**: read REACTIVITY-DESIGN.md. It's the
  design note that drives M20+ ordering.

---

## 9. Closing notes from the M20f / M20g(1/5) session

- The biggest design moment of the M20f arc was GPT-5.5's
  "synthetic ordinary methods, not ad-hoc intercept" pushback.
  My original plan would have replicated the M20d.2 `.upgrade()`
  intercept pattern — slow accretion of magic-method machinery.
  GPT-5.5 saw that Cell is a NOMINAL type and modelable via
  M20b's existing generic-method machinery. The result is much
  cleaner: Cell's methods are read-receivers in sema and pass
  through M20d's auto-deref without any special-casing.
- The Copy-only restriction (`isCopyTypeForCell`) caught a
  subtle hazard I missed: `Cell(*User).set(...)` would overwrite
  the previous handle without dropping it. GPT-5.5's M20f
  checkpoint flagged this as the critical correctness issue.
  Defer the non-Copy case until V1 grows replace/take/Drop.
- Two emit fixes for `*Cell(...)` construction (expected-type
  propagation through `(share x)` + explicit-typed struct
  literal for built-in inner) cost ~50 lines of focused emit
  work — the pattern is reusable for future stdlib types that
  follow the runtime-baked nominal model.
- The whole V1 substrate now composes: M20a methods + M20b
  generics + M20c generic enums + M20d shared/weak + M20e
  auto-drop + M20f Cell. Each milestone has self-validating
  end-to-end tests. Each builds cleanly on the previous.
- M20g closures is the LAST V1 substrate piece. After it ships,
  Phase B of REACTIVITY-DESIGN.md (the rig-reactive validation
  milestone) becomes reachable — that's where the "wow factor"
  emerges from the combination of features.

Good luck. Read SPEC.md §Shared Ownership (Cell subsection),
ROADMAP.md M20d–M20f sections, REACTIVITY-DESIGN.md, then pick
up M20g at sub-commit (2/5). The design checkpoint is locked
(see §3 retrospective + §4 quick-start above). Implementation
order: sema → emit → auto-drop → docs.
