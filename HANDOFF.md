# Rig — Session Handoff (M20i.1 complete; PB3 unblocked)

**You are picking up a Rig compiler session at the M20i.1 boundary.**
M20h (owned escaping closures) + M20i (resource-aware Vec) +
PB2 (single-subscriber Signal) + **M20i.1 (resource-Vec
iteration via `for x in ?vec`)** all shipped end-to-end. The
reactive canary (`examples/reactive_canary.rig`) demonstrates
the full Cell + closure + Signal + Vec-iteration chain
producing `1\n3\n13\n7\n99\n111`. **832 tests passing, 0
failing. Clean tree on `main`.** The next concrete action is
the **PB3 design checkpoint — multi-subscriber Signal +
batching + topology**, now that the substrate prerequisite
(resource-Vec iteration) is solid.

---

## TL;DR

- **Project**: Rig is a systems language ("Zig-fast, Rust-safe,
  Ruby-readable") that compiles to Zig 0.16. Repo:
  `/Users/shreeve/Data/Code/rig`.
- **Where we are**: Substrate ladder Layers 0–6 ✅; Layer 6
  iteration (M20i.1, the PB3 prerequisite) ✅; Layer 7
  (reactivity) HALF-shipped — single-subscriber via
  `Signal(T)` ✅; multi-subscriber pending.
- **Next concrete action**: **PB3 design checkpoint** with
  GPT-5.5 (multi-subscriber Signal + batching + topology).
  Substrate is now solid — `for cb in ?self.subs` is the
  intended notification primitive; the open design questions
  are the Signal-state shape (one `Vec(*Closure())` slot vs
  Cell-extension), the synchronous-set-with-iteration ABI,
  and whether PB3 introduces Reactor.flush or stays purely
  synchronous (the "minimum viable multi-subscriber" question
  parallel to PB2's "minimum viable single-subscriber").
- **Cadence (non-negotiable)**: design checkpoint with GPT-5.5
  via `user-ai` MCP → implement in 3–5 sub-commits (M5-style:
  `Mxx(n/total)`) → post-implementation review → commit.
  Each sub-commit must keep all tests passing.
- **Owner**: Steve (`shreeve@github`). GPT-5.5 collaboration
  is non-negotiable — see §8 for the MCP details.

---

## First 3 minutes for next AI

```bash
git pull --ff-only
git log -1 --format='%h %s'        # most recent commit; at/after M20i.1(4/4)
./test/run 2>&1 | tail -3          # should say "832 passed, 0 failed"
bin/rig run examples/reactive_canary.rig    # 1\n3\n13\n7\n99\n111
```

**Then read** (in order):

1. This file's TL;DR + Non-negotiable invariants below (~5 min)
2. `docs/INFLUENCES.md` §1 (the substrate ladder — the
   conceptual map of where every milestone fits) (~5 min)
3. ROADMAP.md most-recent entries (M20i.1, PB2, M20i, M20h)
   (~10 min)
4. `docs/REACTIVITY-DESIGN.md` (Phase B design north star)
   (~15 min)
5. `examples/reactive_canary.rig` (~2 min — the regression
   test that captures the full Phase B chain)

**Then do**:

- Open a design checkpoint with GPT-5.5 for **PB3 — multi-
  subscriber Signal**. The substrate prerequisite (`for cb in
  ?subs`) is solid; the design space is the Signal-state
  shape (one `Vec(*Closure())` field vs Cell-extension), the
  set-with-iteration ABI (synchronous vs deferred), and
  whether PB3 introduces Reactor.flush or stays purely
  synchronous like PB2. Steve has resisted speculative
  expansion of Signal's API; keep PB3 minimum-viable and
  defer batching/topology/Memo to PB4.

---

## Non-negotiable invariants

A fresh AI must internalize these BEFORE writing any code.
Violating any of them will silently corrupt the substrate.

- **Resource handles `*T` / `~T` are NOT Copy.** Use explicit
  `+` (clone), `<` (move), `-` (drop), `~` (weak from shared).
  Bare aliasing is rejected.
- **`*T` auto-deref is read-only.** Write-through-shared
  requires an interior-mutability primitive (Cell-style or
  Signal-style trusted runtime).
- **Cell(T) is Copy-only.** Non-Copy `Cell(T)` is deferred
  until replace/take/Drop semantics land.
- **Owned closures are `*Closure()` no-arg void only.**
  Arity-bearing closures (`Closure1<T>`, etc.), return types,
  and fallible callbacks are all deferred.
- **Bare lambdas are non-escaping.** Only the exact
  `*Closure(fn ...)` construction shape may escape. Other
  positions (call args, struct fields, array elements,
  function returns) all reject bare lambdas.
- **Vec(T) is a resource value type** (owns its buffer). Bare
  copy is rejected as would-double-free; must move (`<v`) or
  explicitly drop (`-v`).
- **Vec resource `get` / `pop` are deferred** for resource T
  (Copy T `get` / `pop` work). Iteration **shipped in
  M20i.1** via external `for x in ?vec`; resource T mandates
  the `?` source borrow, element binds as a read borrow of
  the slot, `+x` / `<x` / `-x` / `return x` / bare-aliasing
  uses are sema/ownership-rejected with tailored diagnostics.
- **Signal(T) is single-subscriber synchronous canary.** No
  multi-subscriber, no batching, no topology. PB3 (now
  unblocked) will generalize.
- **Grammar conflict count: 69** (was 38 pre-M20h; +31 from
  the M20h(2/5) inline-call lambda body). All benign S/R with
  prefer-shift; reviewed and accepted.
- **Never edit `src/parser.zig` by hand** — it's generated
  from `rig.grammar` via `zig build parser`.
- **Always run GPT-5.5 design checkpoints** before starting a
  new arc. The collaboration has caught real bugs (UAF in the
  M20h ABI proposal; `in_set_rhs` leak in M20g) that would
  have shipped otherwise.

---

## 1. Project orientation

Authoritative project docs, in order of importance:

| File | Purpose |
|---|---|
| `docs/INFLUENCES.md` | **The substrate ladder + design lineage.** §1 is the conceptual map; everything else is design-rationale for why Rig leans the way it does. |
| `docs/REACTIVITY-DESIGN.md` | Phase B design north star — what `Cell` / `Memo` / `Effect` are eventually supposed to look like. Useful when designing PB3 / PB4. |
| `SPEC.md` | Language spec. §Owned Closures (M20h), §Resource-aware containers via Vec(T) (M20i), §Reactive primitive Signal (PB2), §Cell, §Lambdas. |
| `docs/ROADMAP.md` | Milestone history (M0 → PB2 done). Each shipped milestone has a dedicated section with sub-commit table + locked design decisions. |
| `docs/SEMANTIC-SEXP.md` | Sema IR shape. What the grammar emits, what the checker walks. |
| `docs/INHERITED-FROM-ZAG.md` | Grammar/lexer surface inherited from the Zag/Nexus stack. |
| `rig.grammar` | Nexus grammar. **Conflict count: 69.** |

Codebase highlights:

| File | Lines | Role |
|---|---:|---|
| `src/rig.zig` | ~1360 | Lexer rewriter + Tag enum. |
| `src/parser.zig` | ~2400 | **GENERATED** by `zig build parser`. Do not edit. |
| `src/types.zig` | ~7370 | Sema. SymbolResolver, TypeResolver, ExprChecker, type interner. `registerBuiltins` registers Cell/Closure/Vec/Signal. |
| `src/emit.zig` | ~4260 | Zig codegen. `tryEmitVecConstruction`, `emitOwnedClosureConstruction`, `ResourceKind` (.shared/.weak/.vec_value), interior-mutable binding detection. |
| `src/ownership.zig` | ~1600 | M2-era borrow/move checker. Context flags: `in_call_callee`, `in_set_rhs` (narrow to direct lambda RHS post-M20h.1), `in_owned_closure_constructor_arg`. |
| `src/runtime.zig` | ~510 | V1 runtime as a Zig string constant. Contains `RcBox`, `WeakHandle`, `Cell`, `Closure0`, `Vec`, `Signal`, `dropElement` hybrid-dispatch helper, RcBox/WeakHandle/Vec markers (`__rig_rcbox_marker` etc.). |
| `src/main.zig` | ~700 | CLI driver. Writes `_rig_runtime.zig` sibling file per emitted module. |
| `build.zig` | ~70 | `zig build`, `zig build parser`, `zig build test`. |
| `test/run` | ~270 | Test driver. `EMIT_TARGETS` array names the end-to-end runnable examples. |

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
| 9 | Resource-aware containers (Vec(T)) | ✅ | M20i (1-5/5) |
| 9.1 | Resource-Vec iteration (`for x in ?vec`) | ✅ | M20i.1 (1-4/4) |
| 10 | Single-subscriber reactive primitive (Signal(T)) | ✅ | PB2 (1-3/3) |

## 2b. Phase B status

| Step | Item | Status | Where |
|---|---|---|---|
| PB0 | Reactive canary scaffold | ✅ | `examples/reactive_canary.rig` |
| M20h | Owned/escaping closure values | ✅ | commits `f4b448c..a4505d5` |
| PB1 | Single retained Effect | ✅ | folded into canary refresh (M20h(5/5)) |
| M20i | Resource-aware `Vec(T)` | ✅ | commits `4675fca..d6d6c83` |
| PB2 | Single-subscriber Signal | ✅ | commits `5918a15..8c4f36c` |
| M20i.1 | Resource-Vec iteration (`for x in ?vec`) | ✅ | commits `65a3c44..` (this arc) |
| **PB3** | **Multi-subscriber + batching + topology** | **🚧 NEXT** | **design checkpoint pending; substrate now unblocked** |

---

## 3. PB2 retrospective (just-completed arc)

### Design lock (GPT-5.5 conversation entry 25)

Locked at the PB2 design checkpoint:

1. **Single-subscriber `Signal(T)`, NOT Reactor / NOT
   Cell-extension.** Per GPT-5.5: "PB2 should prove one
   retained closure can be subscribed and invoked by state
   change. It should not solve subscriber-list iteration."
   The canary discipline (Phase B Q1) drives the scoping.
2. **Signal wrapper, NOT Cell extension.** Keeps Cell
   primitive; avoids needing `*Cell(Vec(...))` (which would
   force Cell-non-Copy relaxation).
3. **Read-receiver methods (interior mutability).** Matches
   Cell's pattern: `signal.set(v)` not `(!signal).set(v)`.
   Runtime trusts itself to mutate through `*Self`.
4. **Synchronous push on `set`.** PB3 will introduce
   mark-dirty + queued flush; PB2 ships the simplest possible
   notification path.

### Implementation

| Commit | What it shipped |
|---|---|
| `5918a15` PB2(1/3) | `Signal(T)` runtime + sema + emit. Runtime: `value: T`, `subscriber: ?*RcBox(Closure0) = null`, methods `get` / `set` / `subscribe` / `__rig_drop`. Sema: one-arg generic_type builtin, Copy-T-only, methods registered with read receivers. Emit: routes through existing Cell-style construction path. |
| `ea91145` PB2(2/3) | Canary extension. New PB2 block in `examples/reactive_canary.rig`. Canary output: `1\n3\n13\n7\n99`. |
| `8c4f36c` PB2(3/3) | Docs. SPEC §"Reactive primitive: Signal(T) (PB2)"; ROADMAP PB2 entry; this HANDOFF refresh. |

### Verified canary chain

```rig
# examples/reactive_canary.rig output: 1\n3\n13\n7\n99
count: *Cell(Int) = *Cell(value: 0)
count.set(1); print(count.get())                # 1   — PB0 Cell

bump = fn |+count| count.set(count.get() + 1)
bump(); bump(); print(count.get())              # 3   — M20g stack-local closure

eff: *Closure() = *Closure(fn |+count| count.set(count.get() + 10))
eff(); print(count.get())                       # 13  — M20h retained closure

sig: *Signal(Int) = *Signal(value: 0)
log: *Closure() = *Closure(fn |+sig| print(sig.get()))
sig.subscribe(+log); sig.set(7); sig.set(99)   # 7, 99 — PB2 Signal
```

### What PB2 explicitly does NOT cover

- Multi-subscriber notification (PB3, after iteration lands).
- Batching / topology / Reactor.flush (PB4).
- Memo (derived values that auto-recompute).
- Effect lifecycle / unregister-on-drop.

---

## 4. M20i retrospective (resource-aware containers)

### Design lock (GPT-5.5 entries 23 + 24)

1. **Vec(T) is a resource VALUE TYPE** (owns its backing
   buffer). Bare copy/alias = double-free; must move (`<v`)
   or explicitly drop (`-v`).
2. **V1 element kinds**: Copy primitives, `*T`, `~T`,
   `*Closure()`. Arbitrary nominal T deferred. Nested
   `Vec(Vec(T))` rejected.
3. **Mutating methods are write-receiver**: `push`, `clear`,
   `pop` require `(!vec).method(...)`. `length`, `get` are
   read-receiver. Distinct from Cell's interior-mutability
   pattern.
4. **`get` and `pop` are Copy-T-only** at the call site.
   Resource-T iteration is the deferred M20i.1 gap.
5. **`dropElement` uses hybrid marker + `__rig_drop` dispatch**:
   strong handles (pointer types) detected via
   `__rig_rcbox_marker` on the pointee; value types via
   `__rig_drop` decl.

### Implementation

| Commit | What it shipped |
|---|---|
| `dcaff39` scope lock | HANDOFF M20i scope locked + mandatory subscriber-shaped regression test. |
| `4675fca` M20i(1/5) | Runtime + type spelling. `rig.Vec(T)` + `dropElement` + RcBox/WeakHandle markers. |
| `b774e8b` M20i(2/5) | Sema methods + `Vec()` / `Vec(capacity: N)` constructor. |
| `13f079b` M20i(3/5) | Ownership: bare-Vec-copy rejected as double-free. |
| `2ef41b6` M20i(4/5) | Emit: `tryEmitVecConstruction`, `ResourceKind.vec_value`, auto-drop guard, `-vec` discharge. |
| `d6d6c83` M20i(5/5) | 10 examples (5 positive + 5 negative) + SPEC §Vec + ROADMAP + HANDOFF. **Subscriber-shaped regression test** `vec_subscribers.rig` (the mandatory exit gate) prints `11` end-to-end. |

### M20i deferred (M20i.1+ candidates)

- **Resource-T iteration** (`vec.foreach(fn (e) e())` or
  `for x in vec`). The PB3 blocker.
- **Resource-T `get` / `pop`** (return `(*T)?` needs optional-
  resource auto-drop).
- **`insert(i, v)` / `remove(i)` / `swap_remove(i)`**.
- **Persistent/CHAMP Vec** (see INFLUENCES §6).

---

## 5. M20h retrospective (owned escaping closures)

### Design lock (GPT-5.5 entry 17)

1. **Surface**: `*Closure(fn |+count| body)`. Mirrors
   `*Cell(value: 0)`. Explicit `*` for visible heap alloc.
2. **Type spelling**: `Closure()` only — zero arity. Arity-
   bearing variants (Closure1<T>) deferred.
3. **ABI**: type-erased `rig.Closure0` vtable (`ctx`,
   `invoke_fn`, `drop_fn`, `allocator`) + per-literal
   anonymous env struct. Surface type is uniform
   `*rig.RcBox(rig.Closure0)`.
4. **Drop**: `RcBox.dropStrong` runs payload's `__rig_drop` on
   last strong (gated by `comptime hasRigDrop(T)`). Closure0's
   `__rig_drop` calls the per-literal `rigDrop` thunk. **NOT**
   from each binding's defer — that earlier proposal would
   UAF on `cb2 = +cb; -cb; cb2()`.
5. **Ownership relaxation**: dedicated
   `in_owned_closure_constructor_arg` context flag set ONLY
   for the `*Closure(fn ...)` shape.

### Implementation

| Commit | What it shipped |
|---|---|
| `f4b448c` M20h(1/5) | Runtime: `Closure0` + `hasRigDrop` + `RcBox.dropStrong` `__rig_drop` hook. Sema: `Closure` zero-arity builtin. |
| `3f00bdf` M20h(2/5) | Sema construction + invocation. Grammar: new `FN captures inline_body` form. Conflict count: 38 → 69. |
| `64e29ab` M20h(3/5) | Ownership relaxation via new context flag. |
| `a4505d5` M20h(4/5) | Emit: `emitOwnedClosureConstruction` produces labeled-block with inline anonymous env struct + invoke/drop thunks. |
| `09a6b78` M20h(5/5) | 8 examples + canary refresh (PB1 folded in) + SPEC §Owned Closures. |
| `1c86aca` M20h.1 | Post-impl fix: `in_set_rhs` narrowed to direct lambda RHS only (caught by GPT-5.5 review). |

### Verified end-to-end

- Stack-local construction: works, drops cleanly.
- Escaping return (`fun make_counter() -> *Closure() { ... }`).
- Clone-doesn't-drop-early UAF test (`cb2 = +cb; -cb; cb2()`).
- Move-capture.
- Escape rejection still fires for non-wrapped lambdas.

### M20h deferred

- Arity-bearing closures (`Closure1<T>`, `Closure2<A, B>`).
- Multi-statement closure bodies inside `*Closure(...)`.
- `fn || expr` empty-capture inline form.
- Method-value form (`Effect(count.changed)`).

---

## 6. M20g retrospective (closure captures)

M20g shipped (1-5/5 + 2.1, commits `99927c0..a999461`) on
2026-05-16. The five locked rules: default `|x|` is Copy-only;
no `|*x|` mode; V1 closures strictly non-escaping (until M20h
relaxed for `*Closure()`); closure values non-copyable +
implicitly fixed; captured-resource guards live at the
closure-instance's enclosing scope. Full retrospective lives
in `docs/ROADMAP.md` §M20g. The M20h.1 fix later corrected
M20g's `in_set_rhs` leak (lambdas in array literals/struct
constructors silently passing) — that hazard is closed.

---

## 7. Phase B plan (locked decisions from entries 15-16)

The original Phase B scoping checkpoint locked Q1-Q5. These
remain operationally relevant; do NOT re-litigate.

**Q1 — Minimum canary first, NOT the full ~500-line library.**
Each surfaced language gap gets its own Mxx commit on main;
the library grows in `examples/reactive_canary.rig` as those
commits land. PB2's single-subscriber Signal is the current
state of the canary.

**Q2 — Narrow substrate features, NOT trusted Effect/Memo
builtins.** The Rig substrate must grow real escaping
closures (M20h ✅), real resource-aware containers (M20i ✅),
real reactive primitives (PB2 Signal ✅). Effect/Memo/Reactor
must remain expressible in user-level code, not baked into
the runtime.

**Q3 — Defer multi-feature pieces until the canary exposes
the need.** Vec deferred until PB1 exposed it; multi-
subscriber deferred until PB3 forces it; Cell-non-Copy
deferred until PB3 forces it (and it may not).

**Q4 — Hybrid on main, single-file canary until M15b.** All
language fixes ship as normal Mxx commits. The canary file
(`examples/reactive_canary.rig`) IS the regression test and
lives in `EMIT_TARGETS`.

**Q5 — Functional canary + docs as success.** Phase B done
when an end-to-end test passes AND SPEC documents the working
subset + intentional deferrals. PB2 satisfies the "retained-
subscriber observes state change" milestone; PB3 + PB4 finish
the picture (multi-subscriber + Memo + topology).

---

## 8. Working conventions (unchanged)

### Git

- All commits on `main`. No feature branches.
- Sub-commit style: `Mxx(n/total): short summary`.
- ALWAYS pass multi-line commit messages via HEREDOC.
- Push after every commit.

### Testing

- `./test/run` — runs all 800+ tests + Zig unit tests.
- `./test/run --update` — regenerates goldens.
- Add new examples to `EMIT_TARGETS` in `test/run` for
  end-to-end coverage.

### GPT-5.5 collaboration (non-negotiable)

Use the `user-ai` MCP server's `discuss` tool with:

```
conversation_id: "c_5c1d09d53ebe2f62"
model: "openai:gpt-5.5"
max_tokens: >= 6000
```

Pattern: design checkpoint → implement → post-implementation
review → commit. Polish from the review ships as `Mxx.1`.

### Editing conventions

- DO NOT edit `src/parser.zig` directly — it's generated.
- DO use `ReadLints` after substantive edits.
- DO use TodoWrite for multi-step tasks (don't tell the user
  you're updating todos; just do it).

---

## 9. The user-ai MCP conversation log

Persistent conversation ID: **`c_5c1d09d53ebe2f62`**

Compressed history (25 entries; ~$20 total spend across all
arcs). Each numbered entry is a logical exchange:

1. **M20a thesis review** — Rig's three philosophical tensions
2. **Reactivity design discussion** — Q1-Q5 Phase B scoping pre-locked
3. **M20a-c design + review cycles** — methods/self, generics, generic enums
4. **M20d design + (1/5) refinements + tactical rounds** — *T/~T semantics, *T? precedence
5. **M20d Q1 (auto-drop discipline)** — defer-guard direction picked
6. **M20d.1 review fixes**
7. **M20d.2 (`^w` sigil vs method form)** — built-in method picked
8. **M20e design** — defer-guard redirection
9. **M20e post-impl review (M20e.1 fixes)**
10. **M20f design** — Cell synthetic methods + Copy-only
11. **M20f post-impl review (M20f.1 fixes)**
12. **M20g design** — capture modes + non-escaping
13. **M20g(2/5) tactical** — locked Q&A on closure-value enforcement
14. **M20g(2/5) post-impl review** — caught reassign-diagnostic polish
15. **Phase B scoping** — Q1-Q5 locked + M20h scope guardrails
16. **Phase B sequencing confirmation** — locked `PB0→M20h→PB1→M20i→PB2→PB3`
17. **M20h design** — locked `*Closure()` ABI + caught UAF in earlier proposal
18. **M20h(2/5) grammar resolution** — narrow `FN captures inline_body` over braces
19. **M20h post-impl review** — caught `in_set_rhs` leak → M20h.1
20. **Async / Clojure / Nexis influence review** — corrected M20h-as-async-substrate overstatement; PersistentVec-first overreach
21. **Substrate ladder review** — locked the 10-layer hierarchy in INFLUENCES §1; corrected Layer 5 wording (stored callable state, not partial execution); softened lifetime comparison
22. **PB2/PB3 scoping** — Option A vs B vs C vs D for iteration; locked Option B (single-subscriber Signal, defer iteration)
23. **M20i scoping** — Option A (M20i alone) over Option B (M20i + Phase B together); subscriber-shaped regression mandatory; Cell-non-Copy stays separate
24. **M20i design** — Vec is a resource VALUE TYPE (the load-bearing insight); 5-sub-commit decomp; hybrid `dropElement` dispatch
25. **PB2 design** — single-subscriber Signal; Cell unchanged; PB3 deferred until iteration
26. **M20i.1 design** — external `for x in ?vec` (Option B) over internal `vec.foreach(...)`; GPT-5.5 pushed back hard on the foreach plan because external `for` reuses existing grammar + ownership-mode vocabulary, no callback ABI, no lambda-params grammar, and the `?` source mode is the natural enforcement point for both loop-borrow on source AND borrowed-slot element binding
27. **M20i.1 emit shape clarification** — Shape X (resource: `&__rig_p[__rig_i]` slot alias + scope-frame rewrite to `__rig_elem.*`) for resource elements; Shape Y (plain Zig `const`) for Copy elements. Closes the "Zig copy is harmless because Rig will reject bad uses" shortcut from Steve's Shape Y proposal — Shape X preserves the borrow boundary at the Zig level too

To continue the thread, pass `conversation_id` and `model`
as above. MCP tool descriptors live at:
`/Users/shreeve/.cursor/projects/Users-shreeve-Data-Code-rig/mcps/user-ai/tools/`

---

## 10. Future arcs (deferred, NOT roadmap commitments)

Documented in `docs/INFLUENCES.md` as design-space options.
NOT promises to ship.

- **Async via `^` sigil**. Plausible spellings: `^expr`
  (await), `^T` (Future<T>). NOT `expr^`. See INFLUENCES §4.
- **Structured concurrency**. Layer 8. Designed after Phase B.
- **CHAMP-backed persistent collections**. Nexis project shows
  what this costs on Zig (requires GC, which Rig doesn't have).
  Conditional on PB3 actually needing snapshot-iteration.
- **User-defined `Drop`**. The M20h `__rig_drop` runtime hook
  is already extensible to user types.
- **Cell-non-Copy relaxation**. Conditional — may never be
  needed if Reactor stays an owned mutable object.

---

## 11. Hazards / known fragilities

### V1 invariants

1. **Don't extend `unwrapReadAccess` to peel `weak`.** Weak
   handles require explicit `.upgrade()`.
2. **Don't let auto-deref bridge write/value receivers.**
   M20d(4/5)'s `checkReceiverMode` `.shared` rejection is
   the safety check.
3. **Don't `@constCast(sema)` in emit.** Use
   `typeEqualsAfterSubst` for type comparisons.
4. **Don't use a mutable global allocator.** Allocator is in
   `RcBox`.
5. **Don't use `u32` for refcounts.** `usize` per GPT-5.5.
6. **Don't make `Option` / `Result` the built-in optional /
   fallible representation.** `T?` and `T!` are separate
   built-in types.
7. **Don't skip the GPT-5.5 review loop.** It catches real
   bugs (UAFs, leaks) that would otherwise ship.
8. **Conflict count 69 is intentional.** If it changes,
   revert and reconsider.

### Closure / Vec / Signal-specific

1. **`Binding.is_closure` + `fixed=true` are paired.** Set
   both when emit's `walkSet` sees a bare lambda RHS. The
   `is_owned_closure` flag (M20h) is separate — owned
   closures are NOT marked `is_closure`.
2. **Three lambda-permission ownership flags** must all
   reset inside lambda body: `in_call_callee`, `in_set_rhs`,
   `in_owned_closure_constructor_arg`.
3. **Capture-name body refs map via emit's scope frame**, NOT
   a global name scan. The scope frame stores
   `"self.cap_<n>"` qualified names.
4. **Closure-instance guards key on `<closure>.cap_<n>`**, not
   on separate `__cap_<n>` const intermediates.
5. **Vec is a resource VALUE.** Bare alias = double-free. The
   M20i(3/5) `checkSharedHandleAlias` extension covers Vec;
   the M20h.1 `in_set_rhs` narrowing is what makes nested
   Vec-in-aggregate sites correctly reject.
6. **`vec_subscribers.rig` is the M20i exit gate.** Don't
   break it without checkpoint approval.
7. **M20i.1 `is_loop_borrow` element bindings reject consume
   ops uniformly.** `+cb` / `<cb` / `-cb` / `return cb` /
   bare-alias all fire tailored diagnostics. The element's
   `borrow_root_index` is set to the source Vec, so popScope
   auto-releases the loop-source read borrow.
8. **M20i.1 emit Shape X (resource elements) installs a
   `cb → __rig_elem_X.*` scope-frame mapping.** Combined
   with the `is_owned_closure=true` mark, `cb()` lowers to
   `__rig_elem_X.*.value.invoke()` via the M20h call-site
   rewrite. Don't bypass the scope-frame; it's the only way
   the borrow boundary stays visible at the Zig level.
9. **`vec_for_notify.rig` is the M20i.1 exit gate.** Don't
   break it without checkpoint approval — it's the multi-
   subscriber PB3 substrate test.

### Pre-existing fragilities not yet addressed

1. **`(T)?` paren-grouping** in type position: grammar leaks
   the literal parens. Workaround: type inference.
2. **Emit's global name scans in legacy paths** (M20a.2
   `two_self_methods` print-polish). Acceptable until a
   sema-side use-site attribution table lands.
3. **`scanMutations` per-block `seen` masking** — `i = i + 1`
   inside a nested block treated as fresh declaration.
   Workaround: use `i += 1`.
4. **`unsafe` / `%x` enforcement** — pre-existing deferral.
5. **`try_block` emit** — `@compileError` placeholder. Blocks
   fallible Effects.

---

## 12. If you get stuck

- **Tests failing**: `./test/run 2>&1 | grep FAIL` shows
  failures. Most are golden diffs from intended changes —
  verify with `git diff test/golden/` and
  `./test/run --update` if intentional.
- **Grammar conflict count changed**: revert and reconsider.
  The 69 conflicts are reviewed and intentional.
- **Sema diagnostic isn't firing**: check the IR shape via
  `bin/rig normalize path/to/file.rig`.
- **Zig compile error in emitted code**: `bin/rig run
  path/to/file.rig` shows path + Zig error. For shared/weak:
  inspect both `/tmp/rig_<name>/<name>.zig` AND
  `/tmp/rig_<name>/_rig_runtime.zig`.
- **Closure/Vec/Signal-specific**: check the emitted Zig for
  the `cap_<n>` fields, `__rig_alive_<binding>` guards, and
  `__rig_drop` calls. The body of a closure should reference
  captures via `self.cap_<n>`.
- **General confusion**: read `docs/INFLUENCES.md` §1
  (substrate ladder) to see where the current arc fits.

---

## 13. Current frontier notes

- **PB2 + M20i.1 are complete.** PB2 is intentionally single-
  subscriber; don't expand Signal's API speculatively. M20i.1
  shipped external `for x in ?vec` (resource Vec) and `for x
  in vec` (Copy Vec) with the locked design from entries 26 +
  27. The substrate for multi-subscriber notification is now
  solid.
- **PB3 is the next concrete arc.** Multi-subscriber Signal +
  notification iteration via `for cb in ?self.subs`. Design
  questions for the upcoming checkpoint:
  - Signal-state shape: one `Vec(*Closure())` field replacing
    the optional single subscriber slot? Cell-extension is
    still off the table (would force Cell-non-Copy
    relaxation).
  - Set-with-iteration ABI: synchronous push-on-set (parallel
    to PB2's single-subscriber synchronous notification) vs
    deferred queue + explicit `flush`. The canary discipline
    pushes toward "minimum viable" — synchronous-iterate-all
    is probably right for PB3.
  - Where to design Reactor / batching: PB4 or earlier?
    Steve's instinct (and GPT-5.5's PB2 lock) is to defer
    Reactor until PB3 exposes whether topology / order /
    re-entrance actually bite.
  - Mutation-during-iteration: PB3 must reject
    `signal.subscribe(...)` triggered transitively by a
    subscriber being invoked (that would write-borrow the
    Signal's Vec while it's read-borrowed). M20i.1's standard
    borrow-conflict rule already handles this at the IR
    level; we just need to confirm the Signal method bodies
    compile cleanly under that rule.
- **Do not design Memo / batching / topology** in PB3 itself.
  Those are PB4. Keep PB3 minimum-viable.
- **Maintain the cadence**: design checkpoint → sub-commits →
  post-impl review. Each sub-commit must keep all tests
  passing. The cadence has caught real correctness bugs;
  skipping it costs more than running it.
- **The substrate ladder** (`docs/INFLUENCES.md` §1) is the
  authoritative conceptual map. M20i.1 is in Layer 6
  ("Resource-aware containers"); PB3 is in Layer 7
  ("Reactivity"). Layers 8 (Structured concurrency) and 9
  (Async) remain deferred.

Good luck. Read `docs/INFLUENCES.md` §1 first, then ROADMAP's
M20i.1 and PB2 sections, then this file's invariants. Then run
the PB3 design checkpoint with GPT-5.5.
