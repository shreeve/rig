# Rig — Session Handoff (post-M20e)

**You are picking up a Rig compiler session in mid-arc.** This document
captures everything you need to continue cleanly. Read top-to-bottom
once; then it's a reference.

---

## TL;DR

- **Project**: Rig is a systems language ("Zig-fast, Rust-safe,
  Ruby-readable") that compiles to Zig 0.16. Repo:
  `/Users/shreeve/Data/Code/rig`.
- **Where we are**: Just shipped **M20e + M20e.1** — automatic
  scope-exit drop for `*T` / `~T` bindings via Zig `defer` guards,
  plus post-review tactical fixes (reassignment disarm-order under
  fallible RHS, scoped resource classification under shadowing, `<-`
  move-assign disarm). **606 tests passing, 0 failing.** Clean tree
  on `main`, all pushed. The M20d / M20e arc is complete — V1 has
  real, ergonomic shared/weak ownership semantics.
- **Next milestone**: pick one of two M20+ items. Both feed the
  reactive-substrate validation:
  - **M20f: Interior mutability — `Cell(T)` library type** (M20+
    item #7). Smaller scope; user-facing single-type addition;
    can land via library code + small sema support.
  - **M20g: Closure capture mode syntax** (M20+ item #8).
    `|name|` / `|~name|` / `|<name|` capture modes; requires
    closure lowering + capture-mode IR. Bigger lift; HARD
    requires M20e (which now exists, so this is unblocked).
  See §4 below for the trade-off and my lean.
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
| `SPEC.md` | Language spec. §Shared Ownership now documents real auto-drop semantics (M20e), the alias-footgun rule (M20d), `*T?` vs `(*T)?` precedence (M20d.1), `*expr` move semantics (M20d), built-in `~T.upgrade()` method (M20d.2). |
| `docs/ROADMAP.md` | Milestone history (M0–M20e done). M20+ list shows what's next. |
| `docs/REACTIVITY-DESIGN.md` | Substrate design note. The forcing function for M20+ work. |
| `docs/SEMANTIC-SEXP.md` | Sema IR shape. What the grammar emits, what the checker walks. |
| `docs/INHERITED-FROM-ZAG.md` | Grammar/lexer surface inherited from the Zag/Nexus stack. |
| `rig.grammar` | Nexus grammar. Conflict count currently **38**. |

Codebase highlights:

| File | Role |
|---|---|
| `src/rig.zig` | Lexer rewriter + Tag enum. |
| `src/parser.zig` | **Generated** by `zig build parser` from `rig.grammar`. Don't edit by hand. |
| `src/types.zig` | Sema: SymbolResolver, TypeResolver, ExprChecker, Type interner, lookup helpers. ~5900 lines after M20e. |
| `src/emit.zig` | Zig codegen. ~2600 lines after M20e (added M20e guard / disarm helpers). |
| `src/ownership.zig` | M2-era borrow/move checker. M20d added the alias-footgun rule. |
| `src/runtime_zig.zig` | M20d V1 runtime as a Zig string constant (`RcBox` / `WeakHandle` / `rcNew` / etc.). |
| `src/main.zig` | CLI driver. Writes `_rig_runtime.zig` sibling file in `emitProjectToTmp`. |
| `build.zig` | Build steps. `zig build`, `zig build parser`, `zig build test`. |
| `test/run` | Test driver. `./test/run` to verify; `./test/run --update` to regenerate goldens. |
| `EMIT_TARGETS` in `test/run` | Names of `examples/` to run end-to-end. |

---

## 2. M20+ status (post-M20e)

| # | Item | Status | Where |
|---|---|---|---|
| 1 | Instance methods + `self` semantics + receiver-style calls | ✅ | M20a + M20a.1 + M20a.2 |
| 2 | Real generic-instance member typing | ✅ | M20b(4/5) |
| 3 | Generic methods on generic types | ✅ | M20b(4/5) + M20b(5/5) |
| 4 | `Option(T)` / `Result(T, E)` as generic enum types | ✅ | M20c |
| 5 | Methods on enums | ✅ | M20a |
| 6 | `*T` / `~T` real `Rc` / `Weak` semantics | ✅ | M20d + M20d.1 + M20d.2 |
| 6.5 | **Automatic scope-exit drop** | ✅ | **M20e (just landed)** |
| 7 | Interior mutability — `Cell(T)` library type | ⬜ | Candidate next |
| 8 | Closure capture mode syntax | ⬜ | Candidate next (M20e unlocks) |

---

## 3. M20e retrospective + decisions locked

M20e shipped as 5 sub-commits. The single biggest design moment
was the GPT-5.5 redirection during the M20e checkpoint — captured
here so future sessions don't re-derive it.

### The design redirection

I went into the checkpoint proposing **CFG-aware explicit drop
synthesis**: extend `ownership.zig` to walk the scope chain at
every exit point (early return, break, continue, match-arm
divergence, try-catch propagation), insert `(drop x)` IR nodes
at the right edges, handle per-branch convergence with explicit
analysis. The HANDOFF I wrote post-M20d framed M20e this way.

GPT-5.5's intervention: **don't build a mini-MIR drop elaborator.
Use Zig `defer` guards.**

For every resource binding, emit:

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

## 4. Next milestone — pick one

Both candidates are M20+ items required for the reactive substrate
validation (Phase B of REACTIVITY-DESIGN.md). They have different
shapes and different gating:

### Option A — M20f: `Cell(T)` interior mutability (M20+ #7)

**Goal**: a library type `Cell(T)` providing interior mutability
— users can mutate through a `*Cell(T)` shared handle, working
around the M20d "no write-through-shared" rule. The user-facing
escape hatch the M20d rejection diagnostics already point at.

**Shape**: small library type (lives in stdlib eventually; for
V1 probably a hard-coded built-in in the runtime or as a Rig
source file). Sema support: methods on `Cell(T)` need to
work through shared without tripping the receiver-mode
rejection (`Cell` exposes `set` / `get` that look like write/read
but internally do controlled `unsafe` mutation).

**Pros**:
- Smaller scope; ~one sub-commit's worth if Cell is implemented
  purely in the runtime + uses existing M20d sema.
- User-facing payoff: closes the M20d footgun ("you can't mutate
  through `*T`") with a real solution.
- Validates the M20d substrate from a different angle.

**Cons**:
- Requires Rig's stdlib story to take shape (where does Cell
  live? `use std.Cell`?). M15 has the module system but no
  std layout convention yet.
- Might need a small sema carve-out so `Cell.set` typechecks
  through a shared handle (it's a `?self` method that internally
  does unsafe mutation; the sema rule is "read-receiver, but
  trust the implementation").

### Option B — M20g: Closure capture modes (M20+ #8)

**Goal**: lambda syntax with explicit capture-mode markers:
`|name|` strong / `|~name|` weak / `|<name|` move / `|+name|`
clone. Closures that capture resources need M20e (which now
exists) to avoid leaking captured handles on every invocation.

**Shape**: significant lift. Need to:
- Extend grammar with capture-mode syntax in the `lambda` rule.
- New IR shape for capture lists.
- Sema: determine each capture's type per its mode.
- Emit: lower to Zig closures (Zig 0.16 has anonymous structs
  with captured fields).
- Auto-drop: each captured shared/weak gets a guard + defer
  inside the closure body. M20e already does this for normal
  bindings; capture variables need parallel handling.

**Pros**:
- Big user-visible feature; closures unlock the reactive
  substrate's callback model.
- Validates the M20e auto-drop machinery from a fresh angle
  (closures are essentially scopes-as-values).

**Cons**:
- 4–5 sub-commits worth of work. Grammar + IR + sema + emit
  all touched.
- Closure lowering has Zig-side subtleties (Zig closures are
  always anonymous structs; need to thread the captured
  variables through).

### My lean

**M20f Cell first, then M20g closures.** Three reasons:

1. **Cell is the proximate M20d follow-up**: the M20d
   diagnostics already point at "planned `Cell(T)` in M20+ item
   #7" as the escape hatch for write-through-shared. Users
   reaching that diagnostic today have no answer; landing Cell
   gives them one.
2. **Smaller scope = faster iteration**: Cell lets you exercise
   the M20d substrate end-to-end without grammar work. Closures
   force grammar + IR work that should land after we know what
   typical Cell-using code looks like.
3. **REACTIVITY-DESIGN ordering**: the document's "Cell / Memo
   / Effect" sketch starts with Cell as the foundation. Memo and
   Effect (the closure-using parts) build on Cell. Same order
   in Rig.

Closures (M20g) become reachable after Cell ships. Both unlock
Phase B of REACTIVITY-DESIGN.

---

## 5. Open questions for the next session

Before starting M20f / M20g, surface these to GPT-5.5 + Steve:

**Q1 — Stdlib layout for Cell.** Where does `Cell(T)` live?
Options:
- (a) Hard-coded in the runtime as a Zig type (parallel to
  `RcBox` / `WeakHandle`). Rig surface gets a built-in nominal
  with a known set of methods.
- (b) A Rig source file (`std/cell.rig`) auto-included or
  imported via `use std.Cell`. Requires M15b path canonicalization
  for std lookup.
- (c) Hybrid: Rig source file that delegates to Zig builtins via
  `unsafe` blocks. Closer to Rust's pattern.

My lean: (a) for V1. Sets a precedent that "built-in container
types live in the runtime alongside Rc/Weak"; revisit when
stdlib design coalesces.

**Q2 — Cell's safety story.** Cell's `set(?self, value: T)` is
fundamentally `unsafe` (internally mutates through a `?self`
read borrow). How does this typecheck without breaking the
M20d receiver-mode rejection?

Options:
- (a) Cell methods get a runtime-only `unsafe` carve-out: sema
  allows them to mutate `self` because the receiver is `Cell`
  and Cell is built-in.
- (b) Methods use `%self` (raw pointer) — explicit unsafe.
  Honest but verbose.
- (c) M20+ item #9's full `unsafe` enforcement lands first;
  Cell uses it correctly.

My lean: probably (a) for V1, with explicit doc that Cell is
built-in and trusted. (c) is the principled answer but pulls
in more substrate.

**Q3 — Closure capture grammar.** Rig's existing lambda syntax
is `fn |params| body`. Capture modes prefixing names is the
proposed extension: `fn |~weak_x, <moved_y| body`. Does this
parse cleanly given the current `|` usage for captures
(`catch |err|`) and patterns? Probably yes (different
positions), but worth checking against the grammar conflict
count.

---

## 6. Working conventions (unchanged from M20d HANDOFF)

### Git

- All commits on `main`. No feature branches.
- Sub-commit style: `Mxx(n/total): short summary`.
- ALWAYS pass multi-line commit messages via HEREDOC.
- Push after every commit.

### Testing

- `./test/run` — run all 600 tests + Zig unit tests
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

## 7. The user-ai MCP conversation

Persistent conversation ID: **`c_5c1d09d53ebe2f62`**

Now contains, in order:
1. M20a thesis review
2. Reactivity design discussion
3. M20a–c design + review cycles
4. M20d design + post-(1/5) refinements + tactical Q2/Q3/`*T?`-precedence round
5. M20d Q1 (auto-drop discipline) joint decision
6. M20d.1 review fixes round
7. M20d.2 (`^w` sigil vs method form) joint decision
8. **M20e design checkpoint — the defer-guard redirection**

To continue the thread, pass `conversation_id` and `model` as
above. Models live in
`/Users/shreeve/.cursor/projects/Users-shreeve-Data-Code-rig/mcps/user-ai/tools/`.

---

## 8. Hazards / known fragilities

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
   "implicit shadowing is illegal" rule. Should be audited
   against the SPEC before M20f Cell starts touching block-
   scoped state.
3. **`scanMutations` per-block `seen` masking** — `i = i + 1`
   inside a nested block is treated as a fresh declaration
   instead of a mutation. Workaround: use `i += 1`. Surfaced
   during M20e(4/5) loop test work.
4. **`unsafe` / `%x` enforcement** (M20+ item #9) — pre-existing
   deferral, unchanged.
5. **`try_block` emit** (M20+ item #14) — pre-existing
   `@compileError`. Blocks M20e's try/catch resource test.

---

## 9. If you get stuck

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

## 10. Closing notes from the M20e session

- The defer-guard insight from GPT-5.5 was the single biggest
  design moment of the M20d+M20e arc. The original plan I
  proposed (CFG drop elaboration) would have been correct but
  much bigger; defer-guards collapsed it to a tractable size.
- M20e's emit work touched five sites (binding, param, drop,
  return, move) but each is a small targeted change. The
  architecture is "ownership identifies discharges; emit owns
  the guard lowering."
- Pace expectation: M5-style sub-commits with reviews. Each
  self-validating. M20e shipped in 5 sub-commits across one
  session with GPT-5.5 design checkpoint at the start; M20f
  (Cell) probably fits the same pattern with one or two
  sub-commits.
- Have fun. The substrate is solidly in. Both candidate next
  milestones (Cell, closures) feed the reactive validation,
  and that's where Rig's "wow factor" emerges from the
  combination of features.

Good luck. Read SPEC.md §Shared Ownership, ROADMAP.md M20d–
M20e sections, REACTIVITY-DESIGN.md, then pick M20f Cell or
M20g closures per §4 above. Then checkpoint with GPT-5.5
before starting.
