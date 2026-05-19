# Rig — Session Handoff (M25 user-defined Drop complete)

**You are picking up a Rig compiler session at the M25 boundary.**
**Phase B + the raw-escape boundary (M22) + the fake-surface
floor-raising audit (M22.1) + the M22.1.1 runtime rename + the
M15b cross-module sema (module honesty) + M15b.1 sema-time
unbound-name detection + scope-correctness fixes + M15b.2
public-API-leaks-private-type rejection + M25 user-defined
Drop are all shipped.** M20h (owned
escaping closures) + M20i (resource-aware Vec) + M20i.1
(resource-Vec iteration via `for x in ?vec`) + M20i.1.1 (sema
attribution table) + PB2 (single-subscriber Signal) + PB3(1/5)
(captured-resource audit fix) + PB3 (multi-subscriber
`Signal(T)` with R2 reentrancy policy) + PB4 (R2 relaxed for
set; library/substrate boundary locked) + M21 (`%T` unsafe /
raw effect boundary) + M22 (rename `unsafe` → `raw`; drop
fn-modifier; block-only enforcement) + M22.1 (fake-surface
audit: H1 resource-temp leak fix + 5 reserved-surface
retractions) + **M25 (user `drop self: !Self` + auto-generated
structural drop glue + "any drop glue is non-Copy" alias rule)**
all shipped end-to-end. The reactive canary
(`examples/reactive_canary.rig`) demonstrates the full Cell +
closure + Vec-iteration + Signal chain producing
`1\n3\n13\n7\n99\n111\n111`; M25's canaries
(`examples/struct_drop_basic.rig` and friends) demonstrate
user Drop end-to-end. **1035 tests passing, 0 failing.
Clean tree on `main`.** The substrate ladder Layers 0–7 are
all complete, the reactive primitive is in its V1 final form,
the safety boundary uses a clean Rig-native `raw` block
syntax, every accepted V1 surface form has enforced semantics
or a clean Rig sema rejection, AND user-defined Drop closes
the substrate-unlock half-step that gates a userland reactive
library. The next concrete action is **M26 (Cell-non-Copy +
replace/take)** — the second half of the userland Reactor
unblock — or another **Steve-driven choice from the forward-
arc menu** in §13.

---

## TL;DR

- **Project**: Rig is a systems language ("Zig-fast, Rust-safe,
  Ruby-readable") that compiles to Zig 0.16. Repo:
  `/Users/shreeve/Data/Code/rig`.
- **Where we are**: Substrate ladder Layers 0–7 ✅. **Phase B
  complete + reactivity-in-library boundary locked + M21
  raw-escape boundary shipped + M22 simplification applied +
  M22.1 fake-surface audit closed.** Multi-subscriber
  `Signal(T)` with PB4-relaxed R2 semantics (reentrant set
  queues + coalesces; reentrant subscribe still panics). Per
  GPT-5.5 entry 33: Rig holds the position — substrate in the
  language, reactive library in userland. M22 ships the
  simplified raw-escape lattice: **`raw` block ONLY** (no
  fn-modifier per GPT-5.5 entry 38). M22.1 ships the
  fake-surface invariant per GPT-5.5 entry 39: **every
  accepted V1 surface form has enforced semantics OR a clean
  Rig sema rejection**. H1 (resource-temp leak) was a real
  safety bug in safe code, now fixed. 5 other surfaces (`@x`
  pin, `for *x`, `pre`/`pre_block`, `try_block`, `zig "..."`)
  retracted to clean sema diagnostics. Default-unsafe
  builtin classification + extern-call-FFI-boundary
  enforcement preserved.
- **Next concrete action**: **Steve-driven choice from the
  remaining V1-blockers** in §13. With M22.1 done, the
  "fake-surface" hazard class is closed; the remaining
  must-have V1 items per GPT-5.5 entry 32 (+ entry 39's
  capability-hole audit) are: M15b cross-module signature
  import, body-less `extern fun` declarations (real FFI
  ergonomics), closure-with-args (`Closure1<T>`,
  `Closure2<A,B>`), user-defined `Drop` / non-Copy resource
  values, legacy global name-scan cleanup. Plus Cell-non-Copy
  / Layer 8 / Phase C as optional substrate extensions.
  `try_block` is now an explicit V2+ deferral (sema-rejected
  with a clean diagnostic), not a placeholder.
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
git log -1 --format='%h %s'        # most recent commit; at/after M22.1
./test/run 2>&1 | tail -3          # should say "982 passed, 0 failed"
bin/rig run examples/reactive_canary.rig    # 1\n3\n13\n7\n99\n111\n111
bin/rig run examples/signal_multi_subscriber.rig  # 0\n111\n222
bin/rig check examples/raw_outside_rejected.rig   # error msg
  bin/rig check examples/resource_temp_member_rejected.rig  # M22.1 H1
  bin/rig check examples/pin_sigil_reserved.rig             # M22.1 H4
  bin/rig check examples/try_block_reserved.rig             # M22.1 H2
  bin/rig check test/modules/cross_fallible_rejected/main.rig    # M15b
  bin/rig check test/modules/cross_visibility_rejected/main.rig  # M15b(3/5)
  bin/rig check test/modules/cross_use_std_reserved/main.rig     # M15b(4/5)
  bin/rig run test/modules/cross_resource_ok/main.rig            # M15b positive
  bin/rig check examples/unbound_call_rejected.rig               # M15b.1
  bin/rig check examples/unbound_value_rejected.rig              # M15b.1
  bin/rig check examples/unbound_type_rejected.rig               # M15b.1
  bin/rig check examples/print_as_value_rejected.rig             # M15b.1
  bin/rig run examples/if_expr_block_local.rig                   # M15b.1 positive
```

**Then read** (in order):

1. This file's TL;DR + Non-negotiable invariants below (~5 min)
2. `docs/INFLUENCES.md` §1 (the substrate ladder — the
   conceptual map of where every milestone fits) (~5 min)
3. ROADMAP.md most-recent entries (PB3, M20i.1.1, M20i.1, PB2)
   (~10 min)
4. `docs/REACTIVITY-DESIGN.md` (Phase B design north star)
   (~15 min)
5. `examples/reactive_canary.rig` + `signal_multi_subscriber.rig`
   (~3 min — the regression tests that capture the full Phase B
   chain)

**Then do**:

- Wait for canary pressure or a Steve-driven design decision
  before opening the next arc. Phase B is complete; the three
  forward paths (PB4 / Phase C / Layer 8) are all unblocked,
  but Q1-Q5's "canary first" discipline says don't pre-empt
  the design space.
- If Steve picks **PB4** (Reactor / Memo / Effect / batching),
  the design checkpoint will need to cover: Reactor as runtime
  type vs ambient context (D9 of REACTIVITY-DESIGN was "defer
  language mechanism, libraries pass explicitly"); Memo's
  deps-list shape (explicit vs `pre`-extracted per D8); Effect
  lifecycle (unregister-on-drop needs the unsubscribe primitive
  PB3 deferred); batching policy (snapshot vs queue — the R3/R4
  alternatives GPT-5.5 set aside in PB3 entry 29 may resurface).
- If Steve picks **Phase C** (sugar `:=` / `~=` / `~>`), the
  lowering is locked per REACTIVITY-DESIGN's sugar mapping; the
  open questions are `pre`-time AST extraction (D8) and whether
  scoped-context (D9 Reactor) lands at the language level.
- If Steve picks **Layer 8 / async**, the open question is pin
  discipline (M20+ deferred per INFLUENCES §1's lifetime note)
  and how `Future<T>` derives from PB3's shape — same waiter-
  list + value slot + notify-once shape, with resolve-once
  semantics instead of repeated set.

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
- **`Signal(T)` is multi-subscriber, synchronous, mixed
  reentrancy** (PB4 R2-relaxed-for-set policy). Same-Signal
  reentrant `set` queues + coalesces to latest value;
  reentrant `subscribe` still panics. `T` must be Copy.
  Heap-owned `*Signal(T)` only — stack-local rejected. No
  `unsubscribe` in V1.
- **Reactive library (`Reactor` / `Memo` / `Effect` /
  batching / topology) is USERLAND work, NOT future
  builtins.** Locked in PB4 (GPT-5.5 entry 33) — matches
  Rust/Zig position. Blocked on `Cell`-non-`Copy` for the
  natural shape.
- **`%x` raw access requires a `raw` block.** Block-only;
  no fn-modifier. Diagnostic names the operation. M22.
- **`@builtin(...)` is default-unsafe.** Only the explicit
  safe whitelist (`@sizeOf`, `@alignOf`, `@TypeOf`,
  `@typeName`, `@hasDecl`, `@hasField`, `@len`, `@This`)
  works outside `raw` block. M22.
- **No raw/unsafe function modifier in V1.** Dropped in
  M22 per GPT-5.5 entry 38. Users wrap their fn body's
  first statement in a `raw` block if needed.
- **`extern` symbols are raw-by-default at call sites.**
  Any call to an extern requires wrapping in a `raw`
  block. M22.
- **Captured resources (`+x` / `~x` / `<x` in a closure
  capture list) are non-consumable inside the closure body.**
  `<cap` / `-cap` / `return cap` / bare-alias-as-arg are all
  sema/ownership-rejected. `+cap` / `~cap` / `cap()` /
  `cap.method(...)` are allowed. Per the PB3(1/5) audit.
- **No fresh resource allocations as anonymous temporaries.**
  M22.1(1/8) per GPT-5.5 entry 39: `(*Foo(...)).field`,
  `(*Foo(...)).method()`, `?(*Foo(...))`, `+(*Foo(...))`,
  `~(*Foo(...))`, `%(*Foo(...))` are all sema-rejected. M20e
  auto-drop guards key off NAMED bindings; anonymous Rc
  temporaries would leak. Users bind to a name first.
- **`unknown` is poison-after-error, never silent success
  (M15b.1 invariant, all three sema sites).** Every unresolved
  bare identifier fires a Rig diagnostic at sema time:
  value position via `synthLeafSrc` ("use of unbound name `X`"),
  callee position via `synthCall`'s unknown-callee branch
  (same message), type position via `TypeResolver.resolveType`
  ("use of unbound type `X`"). NO leaf whitelist — `print`
  as a value (`x = print`) errors as unbound. ONLY direct
  call shape `print(...)` is whitelisted via
  `isCalleeBuiltinWhitelisted` (the one legacy emit-side
  builtin not yet in the symbol table). Builtin nominals
  (Cell/Closure/Vec/Signal) resolve through `registerBuiltins`.
- **`synthBlock` enters its block scope (M15b.1).** Value-
  position multi-stmt blocks (`if`-expression arms, `match`-
  expression arms) properly enter the scope created by
  `SymbolResolver.walkBlock` so local bindings are visible
  at use sites within the block.
- **`walkDecl` handles `.@"generic_enum"` (M15b.1).** Pre-
  M15b.1 the dispatch silently skipped generic enum bodies,
  leaving the scope cursor desynced for every subsequent
  top-level decl. Adding the missing arm both fixes the
  cursor drift and unblocks generic-enum method-body
  type-checking.
- **Cross-module references carry the same checked contracts as
  same-file (M15b invariant).** Every accepted `(member <module>
  <name>)` access and `(call (member <module> <fn>) args)`
  dispatches through `synthMember` + `dispatchCrossModuleCall`
  into the foreign SemContext via `module_refs` + `foreign_semas`,
  imports types via `importType`, and fires the same Rig
  diagnostics as same-file (with qualified names like
  `a.parse_int`). `pub` is REAL — non-pub names invisible across
  modules. `imported_nominal{module_id, sym_id}` carries canonical
  origin identity; `a.Box` and `b.Box` are different types even
  if shaped identically. Sub-invariant: `unknown` may only exist
  as poison after a diagnostic, never as a silent success type.
  Bare-identifier use-site enforcement deferred to M15b.1.
- **User Drop is plain-struct only in V1 (M25).** A struct's
  `drop self: !Self` body is sema-validated for exactly-one-
  per-struct, write-borrow receiver, no other params, no
  return, no fallibility. The compiler ALSO emits auto-
  generated structural drop glue for any struct that owns a
  resource field (regardless of whether a user body is
  present). Drop on `enum` / `errors` / `generic_type` /
  `generic_enum` is V1-deferred (per-variant payload drop
  and bounds analysis are separate substrate arcs). Drop-body
  restrictions on consume-of-self / drop-of-resource-field /
  assignment-to-resource-field are deferred — the load-bearing
  "any drop glue is non-Copy" rule prevents cross-binding
  double-free; the in-body restrictions need ownership.zig to
  walk struct method bodies (a follow-up arc). User-defined
  `Clone` for Drop types is also deferred; V1 has only `<x`
  move and explicit `-x` discharge for has_drop_glue values.
- **Any type with drop glue is non-Copy (M25).** Bare alias /
  assignment / call-arg of a `nominal` or `parameterized_nominal`
  whose symbol carries `has_drop_glue` is rejected at the
  ownership layer. This generalizes the M20d alias-discipline
  rule from the hardcoded resource set (`*T` / `~T` / `Vec` /
  `*Closure()`) to the substrate-classified set (anything the
  compiler tracks as having drop glue). Move (`<x`) is the
  only V1 multi-binding shape; user Clone + `+x` shape is
  deferred.
- **No parsed-but-not-enforced surfaces (M22.1 invariant).**
  Every accepted V1 form has enforced semantics + working
  Rig lowering, OR is rejected at sema time with a Rig
  diagnostic. NEW arcs that add syntax MUST ship the
  semantics + emit OR a clean "reserved" sema rejection. No
  emit-time `@compileError`-as-placeholder. Forms currently
  reserved (parse-accepted, sema-rejected): `@x` (pin),
  `for *x` (ptr-mode loop binding), `pre <expr>` /
  `pre INDENT body OUTDENT`, `try INDENT body OUTDENT
  [catch ...]`, `zig "..."`. Reserved-surface tests live in
  `examples/*_reserved.rig` and `examples/resource_temp_*_rejected.rig`.
- **Visible source effects must survive as visible semantic
  Tags through lowering.** This is the language-wide thesis
  the M20+ substrate ladder protects (SPEC §Overview second
  paragraph; `docs/SEMANTIC-SEXP.md` design rule). Ownership
  operations, failure propagation, compile-time specialization,
  capture modes, and the raw-escape boundary all emit as
  first-class IR nodes the checkers and emitter consume by
  name. A feature that hides ownership, mutation, failure,
  capture, or escape under runtime convention or inferred
  annotation is suspect — even if the feature is otherwise
  desirable. New arcs that add capability without making any
  new effect explicit OR unifying multiple ad-hoc mechanisms
  fail INFLUENCES.md §10 rule 1, and they erode the AI/tool
  consumability story (`docs/ROADMAP.md` §V1.x). The
  M22.1 "no parsed-but-not-enforced" invariant is the syntax-
  level corollary of this rule; this invariant is the
  semantic-level statement.
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
| `src/main.zig` | ~700 | CLI driver. Writes `_runtime.zig` sibling file per emitted module. |
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
| 9.1 | Resource-Vec iteration (`for x in ?vec`) | ✅ | M20i.1 (1-4/4) + M20i.1.1 post-impl |
| 9.2 | Captured-resource non-consumability audit | ✅ | PB3(1/5) — must-precede |
| 10 | Multi-subscriber reactive primitive (Signal(T)) | ✅ | PB2 (1-3/3) + PB3 (1-5/5) + PB4 (1-3/3) |

## 2b. Phase B status

| Step | Item | Status | Where |
|---|---|---|---|
| PB0 | Reactive canary scaffold | ✅ | `examples/reactive_canary.rig` |
| M20h | Owned/escaping closure values | ✅ | commits `f4b448c..a4505d5` |
| PB1 | Single retained Effect | ✅ | folded into canary refresh (M20h(5/5)) |
| M20i | Resource-aware `Vec(T)` | ✅ | commits `4675fca..d6d6c83` |
| PB2 | Single-subscriber Signal | ✅ | commits `5918a15..8c4f36c` |
| M20i.1 | Resource-Vec iteration (`for x in ?vec`) | ✅ | commits `65a3c44..5622832` |
| M20i.1.1 | Sema attribution table + non-bare source rejection | ✅ | commit `2c33c63` |
| PB3 | Multi-subscriber Signal + R2 reentrancy + capture audit | ✅ | commits `b0c0861..b735c71` |
| PB4 | Reentrant-set queue + library/substrate boundary lock | ✅ | commits `e1b09dc..be48696` |
| M21 | `%T` unsafe / raw effect boundary | ✅ | commits `5859f5e..219f6b7` |
| M22 | Rename `unsafe` → `raw`; drop fn-modifier; block-only | ✅ | commits `acb367d..` (this arc) |
| **Phase B** | **complete** | ✅ | reactive substrate solid; reactive library is userland |
| **Next** | **Steve picks** | **🚧** | **see §13 forward-arc menu** |

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
- **Runtime-affecting M20+ changes should add/extend end-to-end
  run tests, not only ast-check + goldens.** Per the GPT-5.5
  PB3 post-impl review (entry 31): the M20i.1 / PB3 sub-commits
  caught a runtime field-mismatch only via manual canary run
  because the test harness was historically only running
  `hello.rig` end-to-end. `run_end_to_end <name> <substr>` and
  `run_expected_panic <name> <substr>` helpers are now in
  `test/run`; use them for any new runtime-shape change.

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
28. **M20i.1 post-implementation review** — locked must-fix: replace emit-side `vecSourceForEmit` global reverse scan with sema attribution table keyed by source position (M20i.1.1). Also locked three follow-ups: reject resource Vec iteration over non-bare source; positive test for post-loop mutation released; negative test for capture-loop-borrow-in-lambda (M20g clone-capture validator handles it). PB3 reentrancy gap documented but deferred — closure-call-mediated subscriber mutation needs a runtime policy (snapshot, `notifying` flag, or queued mutations) that PB3 design will decide
29. **PB3 design — multi-subscriber Signal** — locked R2 (strict `notifying` flag + panic) over R4 (silent tolerate). GPT-5.5 pushed back hard on R4 because (a) it forces V1 to define recursive semantics that should be locked in PB4, (b) R2 has zero allocation and zero Vec-mutation-during-iteration, (c) R2 generalizes cleanly to `Future<T>`. Also locked: `Vec(*Closure())` state shape (no optional-first-slot micro-opt); subscribe-only (defer unsubscribe to PB3.x); reject stack-local `Signal(T)` (smallest-safe-path over wiring the M20e defer-guard machinery). Critical audit must-precede: captured-resource consume rejection — closure bodies must not be able to move/drop their captured `*T`/`~T` because retained subscribers are invoked multiple times
30. **PB3 tactical** — unify M20i.1's `is_loop_borrow` and PB3's `is_capture_resource` behind a single `rejectNonConsumableBindingOp` helper. Diagnostics branch on which flag fired; hooks at the same five sites M20i.1 added. Avoids "missing one of the five sites later" risk
31. **PB3 post-implementation review** — confirmed PB3 is solid (R2 is correct, Shape X for resource elements is correct, audit fix is correct). Identified small PB3.1: suppress misleading stack-Signal cascade diagnostic; add bare-resource-capture invariant test + comment (the `cap_copy` exclusion in `is_capture_resource` depends on M20g's bare-resource-capture rejection — pin the dependency); add nested-capture rejection regression; add expected-panic harness for reentrant set. Forward-arc guidance: **do not** jump to async — PB3 looks like a `Future<T>` waiter list but async still needs state-machine lowering, poll/wake ABI, pin, cancellation, borrow-across-suspension, executor. **PB4 should focus on deferred queue + flush** (R2 panic is the obvious forcing function for batching), NOT Memo first. Phase C sugar after PB4 semantics stabilize, not before
32. **Forward-arc strategic check** — GPT-5.5 recommended PB4 narrowly scoped as "queue + flush canary," preferring an explicit `*Reactor` builtin for async/future executor generalization. Out of scope: Memo / topology / batching beyond simple queue / async / sugar. V1 remaining work: `%T` unsafe / `try_block` / M15b / closure-with-args / legacy global-scan cleanup
33. **PB4 design (refined by Steve's two cues)** — Steve surfaced two inputs that reshaped PB4: (a) "Rust and Zig don't support reactivity" — implicit pushback on accumulating reactive builtins; (b) type-inference ergonomics — verbose `reactor: *Reactor = *Reactor()` is unnecessary ceremony, `rc = *User(name: "x")` works for non-generic. GPT-5.5 changed their recommendation from a new `*Reactor` builtin to a **minimal per-Signal queued reentrancy relaxation**. Reactive library (Reactor / Memo / Effect / batching) is now explicitly **userland** work, blocked on `Cell`-non-`Copy` for the natural shape — matches Rust/Zig "substrate in language, library in userland" position. PB4 ships only the `set` reentry relaxation (queue + coalesce to latest); `subscribe` stays strict (panics) because list-mutation during iteration is subtler. Iterative drain loop, NOT recursive, avoids stack growth on cascade chains. Bad user logic (infinite cascade) acceptable as V1 contract.
34. **PB4 post-implementation review** — confirmed PB4 sound; no must-fix. Three small follow-ups in PB4.1: Copy-T-only invariant comment on `pending_value`; "last-value Signal, not event stream" SPEC distinction; soften "permanently userland" to "for V1, no more without design reset" (escape hatch for V2 thread-safe `Arc<Signal>`).
35. **M21 design (`%T` unsafe / raw effect boundary)** — locked block-only `unsafe`; SUFFIX `sub raw_op() unsafe` for SPEC ergonomics. Effect model A: unsafe fn body IS unsafe context (Rust-style); safe fn calling unsafe wraps in `unsafe` block. Builtins: default-unsafe with small safe whitelist (`@sizeOf` / `@alignOf` / `@TypeOf` / `@typeName` / `@hasDecl` / `@hasField`). Scope X + extern enforcement (raw `zig "..."` blocks deferred). Trusted runtime boundary is out-of-band; user-trusted-types are M21+ via safe-wrapper pattern.
36. **M21 tactical (prefix vs suffix)** — locked PREFIX `unsafe sub` over the suffix form from entry 35. Reason: suffix would have doubled `fun`/`sub` grammar productions (+6 lines) AND changed the `(fun ...)` IR shape, requiring walker updates in sema/ownership/emit. Prefix matches existing `pub`/`extern`/`packed`/`callconv` wrapper with 1 new grammar line. Distinct IR tags `unsafe_decl` (decl-modifier wrap) and `unsafe_block` (statement form) — avoids context-dependent walker dispatch. SPEC updated to prefix shape. *(M22 later dropped the prefix-decl-modifier entirely; see entry 38.)*
37. **M21 post-implementation review** — confirmed M21 sound; one must-fix (the `pending_fn_unsafe` propagation hazard that could leak the flag from `unsafe_decl` of a non-fn to a sibling fn walked after). Shipped as M21.1: removed the `walkFun` consume; the wrapper's defer/restore exclusively owns the flag's lifetime. Companion fix: reject `unsafe struct`/`unsafe enum`/etc. with a tailored diagnostic. GPT-5.5 flagged the global-mutable-bridge pattern as long-term tech debt: "Longer-term, symbol collection should also use a `DeclCtx` instead of before/after stamping." *(M22 later rendered this whole hazard class obsolete by dropping the fn-modifier; the `pending_fn_unsafe` state ceases to exist.)*
38. **M22 cleanup design (`unsafe` → `raw`, drop fn-modifier)** — Steve flagged the M21 `unsafe` keyword as aesthetically off (heavy, Rust-imported, against Rig's sigil-heavy aesthetic). Triggered a cleanup pass. Locked: rename `unsafe` keyword → `raw` (3 letters, matches `%x` raw-prefix sigil); DROP the `unsafe sub`/`unsafe fun` fn-modifier ENTIRELY (no V1 use case justifies the ~120 lines of machinery + the global-mutable-bridge hazard); block-only enforcement; distinct `RAW` keyword token (don't reuse `RAW_PFX`); single IR tag `raw_block` (drop `unsafe_decl`). Rip-and-replace (Rig is pre-release; no deprecation). SPEC §"Unsafe / Raw (M19)" rewritten as §"Raw escape (M22)" with explicit "no raw/unsafe function modifier in V1" note to prevent future sessions from resurrecting the fn-modifier without an explicit reset.
39. **M22.1 fake-surface audit (Steve's high-level review → GPT-5.5 verdict (b) + finish-vs-retract design)** — Steve asked the senior-PL-designer question: "is our syntax clean and powerful? Are there other holes like the missing raw-fn-modifier?" GPT-5.5 returned (b) "holding up but watch X, Y, Z" with the through-line: **every concrete hazard was the same shape — accepted syntax with no enforced semantics**. M22 was the first instance of this pattern being fixed. M22.1 audits the rest and locks the invariant: every accepted V1 surface form has enforced semantics OR a clean Rig sema rejection. Six concrete hazards confirmed via `bin/rig build` evidence: H1 (resource-temp leak — real safety bug in safe code), H4 (`@x` pin sigil as no-op), H5 (`for *x` Copy-Vec as silent no-op), H2 (`try_block` emits `@compileError`), H3 (`zig "..."` emits `@compileError`), H7+H8 (`pre_block` / `pre <expr>` emit `@compileError`; `pre_param` kept). Per-item finish-vs-retract: H1 fix (reject leak-shaped resource rvalues, hidden guarded temporaries deferred); H4/H5/H7/H8/H2/H3 retract (sema rejection, no grammar changes so V2+ design space stays open). GPT-5.5 added five audit holes — all checked: emit `@compileError` paths beyond the catch-all only fire for compile-time-impossible inputs; builtin classification already default-unsafe with whitelist; raw context leak via escaping closure not reachable in V1 (single-call inline-body restriction); no other parsed-but-unenforced modifiers; `pre_param` is the only `pre`-family form that's wired and stays. Locked one-arc structure (8 sub-commits) rather than splitting Tier-3 to "cosmetic later" — H4 in particular is not cosmetic, it's a false guarantee.

41. **M15b.1 sema-honesty + scope correctness (the unknown-is-poison arc)** — Steve approved push of M15b + Option A "open M15b.1." Claude audited the 6 deferred items (A=unbound-name, B=scope-tracking, C=pub-extern grammar, D=pub-fn-returns-private, E=qualified-resource-types, F=cross-module-generics). GPT-5.5 locked: M15b.1 = A+B+fixture sweep; defer C/E/F; D becomes M15b.2 immediately after. Implementation discovered+fixed THREE bugs: (1) `synthBlock` not entering its scope (value-position multi-stmt block bindings invisible), (2) `walkDecl` missing `.@"generic_enum"` arm (silently skipped generic enum bodies + desynced scope cursor for every subsequent top-level decl — invisible until unbound-name detection surfaced false-positive "use of unbound name `o1`" in `examples/generic_enum_method.rig`), (3) the original MH9 hazard itself (unbound-name silent unknown). Test-fixture sweep: 13 example files updated to add real declarations for the `User`/`make`/`Packet`/etc. names they relied on being silently unknown. **GPT-5.5 post-impl review caught two must-fixes Claude initially deferred**: (a) `print` whitelist must be call-callee-only, not leaf-position (bare `print` as value must error); (b) type-position unbound (`x: NopeType = ...`) cannot wait for M15b.2 — must close NOW because the invariant is incomplete without it. Both fixed before push. Renamed helper `isUnboundNameWhitelisted` → `isCalleeBuiltinWhitelisted` to make the call-callee-only scope explicit. Added `TypeResolver.resolveType` unbound diagnostic + updated the corresponding unit test that pinned the pre-M15b.1 silent behavior. Tests 962→982 (+20). Five new canaries: `unbound_call_rejected`, `unbound_value_rejected`, `if_expr_block_local`, `unbound_type_rejected`, `print_as_value_rejected`. Canary unchanged. Deferrals after post-impl review: legacy global name-scan retirement (lower urgency now), public-API-leaks-private-type (M15b.2's job).

40. **M15b cross-module sema design + impl + review (the project-honesty arc)** — Steve approved the M22.1+M22.1.1 push and "Option A: open M15b with full fury." Claude ran a 7-hazard audit producing `bin/rig` repros for every cross-module contract leak (fallibility, arity, kwargs, borrow modes, extern raw, visibility, M22.1 resource-temp rule) plus a Tier-1 safety bug: cross-module `*T`-returning calls leaked the Rc + silently skipped auto-deref through it (printed the whole RcBox struct instead of the field). Also flagged `bin/rig check` as single-file-only — didn't use the ModuleGraph, so multi-file projects checked but ran was inconsistent. GPT-5.5 design checkpoint locked: nominal types tagged with origin (`{module_id, sym_id}`), NOT structural equality; foreign types re-interned into importer's local TypeStore via new `importType` recursive helper; ONE architectural fix (extending `synthMember` to look through `module_refs`) unlocks ALL downstream checks. Five sub-commits shipped: (1-2/5) substrate + contract wiring merged (`imported_nominal` Type variant + `importType` + `checkWithImports` entry + `synthMember`/`synthMemberCall`/effects `walkCrossModuleCall` + `check` uses ModuleGraph) — Tier-1 leak closed, 6 contract checks fire cross-module with qualified diagnostic names (e.g., `call to extern function `a.puts` requires raw block`); (3/5) visibility (`pub` enforced via `isCrossModuleVisible` consulting `is_public` flag stamped pre-M15b but never read); (4/5) `use std` reserved diagnostic + MH9 (sema-time unbound-name) DEFERRED to M15b.1 because initial impl exposed pre-existing branch-scope tracking gaps in `synthIfExpr`/etc. AND would require updating ~15 test-placeholder examples (`User`/`rename`/etc.) — inline deferral notes added at both intercept points so M15b.1 picks up cleanly; (5/5) SPEC §Modules section + ROADMAP §M15b + this HANDOFF entry. 8 new `test/modules/` canaries (7 reject + 1 positive `cross_resource_ok` proving end-to-end auto-deref + M20e guard work cross-module). Tests 952→960. Canary unchanged. New invariant: "`unknown` may only exist as poison after a diagnostic, never as a silent success type" — locked at cross-module call return boundary; bare-identifier use-site enforcement deferred to M15b.1.

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
10. **PB3 Signal is non-reentrant (R2 strict).** Calling
    `set` or `subscribe` during an active notification
    panics. The `notifying: bool` flag is the runtime
    guard. Lift only in PB4 with a locked queue/snapshot
    policy — don't sneak in silent reentrant behavior.
11. **PB3 captured-resource flag `is_capture_resource` is set
    by `bindCapturesLocal` for `cap_clone`/`cap_weak`/
    `cap_move`.** Unified with `is_loop_borrow` behind
    `rejectNonConsumableBindingOp`. All five hook sites
    (`.@"clone"`/`.@"weak"` arm, `walkBorrow` move_op,
    `walkDrop`, `walkReturn`, `checkSharedHandleAlias`) route
    through this helper — adding a sixth requires the same
    routing or it WILL miss one of the categories.
12. **`signal_multi_subscriber.rig` is the PB3 exit gate.**
    Don't break it without checkpoint approval — it's the
    mandatory subscriber-shaped regression that proves
    end-to-end runtime + emit + audit composes correctly.
13. **Stack-local `Signal(T)` is sema-rejected.** All Signal
    uses must be `*Signal(T)` (heap-owned). If/when M20e's
    defer-guard machinery grows a `.signal_value` resource
    kind, the rejection can be relaxed; until then, keep
    the rejection so the V1 shape stays predictable.
14. **Signal's `set` drain loop is iterative, NOT recursive
    (PB4).** Reentrant set queues `pending_value` and the
    outer drain loop picks it up. Recursive `self.set(v)`
    would re-enter the `notifying` guard AND grow the stack
    on cascade chains. If anyone "simplifies" set to a
    recursive call, that's a regression.
15. **`pending_value` is initialized to the constructor's
    `value` argument as a placeholder.** Only read when
    `pending_set == true`. The default isn't load-bearing —
    any value of type T works — but `value` is conveniently
    in scope and avoids a `?T` optional.
16. **For V1, no more in-language reactivity builtins
    without an explicit design reset.** Reactor / Memo /
    Effect / batching / topology are userland work in V1
    (per the PB4 entry 33 + 34 lock; matches Rust/Zig).
    If someone proposes a new reactivity builtin, point
    them at the lock + GPT-5.5's reasoning + the Rust/Zig
    position. The "explicit design reset" escape hatch is
    reserved for V2 cases like thread-safe `Arc<Signal>`
    that genuinely can't be expressed userland.
17. **`Signal(T)` is a LAST-VALUE primitive, NOT an event
    stream.** Reentrant `set` calls within one notification
    round coalesce to the most-recent value (slot, not
    queue). Users who need every-value-delivered semantics
    need a different primitive (Event / Channel / Queue).
    This distinction matters for future async/channel
    design — don't accidentally turn Signal into a stream.
18. **Test gap: PB4 queued reentrant-set semantics lacks a
    Rig-source regression** until V1 grows multi-capture
    (`fn |+sig, +cb|`) OR conditional inline-body grammar.
    The runtime contract is enforced by code review,
    documented in SPEC + `runtime.zig`, and verified by
    non-regression. Add a Zig-level runtime unit test as
    a small infrastructure task when one of those grammar
    extensions lands.
19. **M22 keyword: `raw` (NOT `unsafe`)**. M19 shipped
    `unsafe`; M22 renamed to `raw` for sigil-alignment with
    `%x`. If anyone "restores" the old `unsafe` keyword:
    revert. The rename is intentional and SPEC §"Raw escape
    (M22)" documents why.
20. **M22: NO raw/unsafe function modifier in V1**. The M19
    `unsafe sub`/`unsafe fun` form was dropped per GPT-5.5
    entry 38 because no V1 use case justified the
    machinery (Symbol flag, three transparent walker arms,
    `pending_fn_unsafe` global bridge, etc.). If a future
    session proposes `raw sub`/`raw fun` (or any
    fn-precondition-marker shape): require an explicit
    design reset + a concrete stdlib use case. Don't
    accidentally resurrect M19 via incremental "small
    addition."
21. **M22 safe-builtin whitelist is in `effects.zig`**:
    `@sizeOf`, `@alignOf`, `@TypeOf`, `@typeName`,
    `@hasDecl`, `@hasField`, `@len`, `@This`. Each addition
    requires explicit audit (see runtime-comment criteria
    in `isSafeBuiltin`). Default-unsafe means a new builtin
    silently becomes raw-block-required-at-call-site until
    reviewed.
22. **M22 extern is raw-by-default at call sites** even
    WITHOUT any explicit annotation on the extern
    declaration. Per GPT-5.5 entry 35: "extern declarations
    are the FFI boundary." If anyone proposes a "safe
    extern" mechanism, require a fresh design pass.
23. **M22 grammar comment hazard**: Nexus's grammar-file
    parser fails on INLINE comments after a continuation-
    alternation line in `@parser` section (`| raw  # this
    breaks`). Place comments BEFORE the rule definition or
    in dedicated comment lines. Em-dashes in `@lexer`
    section comments are fine. Found during M22(1/3).
24. **M22.1 invariant: no parsed-but-not-enforced surfaces.**
    Per GPT-5.5 entry 39: every accepted V1 form has enforced
    semantics + working Rig lowering, OR is rejected at sema
    time with a Rig diagnostic. NEW arcs that add syntax MUST
    ship both. No emit-time `@compileError`-as-placeholder.
    Currently reserved (parse-accepted, sema-rejected): `@x`
    (pin), `for *x` (ptr-mode loop binding), `pre <expr>` /
    `pre INDENT body OUTDENT`, `try INDENT body OUTDENT
    [catch ...]`, `zig "..."`. Regression-test the rejection
    via `examples/*_reserved.rig`.
25. **M22.1 resource-temp leak rule.** Fresh `*Foo(...)`
    allocations are sema-rejected as the object/receiver of
    `member` / `index` / method-call / ownership-wrapper
    (`?`/`!`/`+`/`~`/`%`). M20e auto-drop guards key off
    NAMED bindings; anonymous Rc temporaries leak. Users
    bind to a name first. Allowed positions: RHS of `set`,
    direct `return`, direct positional/kwarg arg of `call`.
    See `isFreshResourceAlloc` in `types.zig`.

### Pre-existing fragilities not yet addressed

1. **`(T)?` paren-grouping** in type position: grammar leaks
   the literal parens. Workaround: type inference.
2. **Emit's global name scans in legacy paths** (M20a.2
   `two_self_methods` print-polish). Acceptable until a
   sema-side use-site attribution table lands.
3. **`scanMutations` per-block `seen` masking** — `i = i + 1`
   inside a nested block treated as fresh declaration.
   Workaround: use `i += 1`.

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
  `/tmp/rig_<name>/_runtime.zig`.
- **Closure/Vec/Signal-specific**: check the emitted Zig for
  the `cap_<n>` fields, `__rig_alive_<binding>` guards, and
  `__rig_drop` calls. The body of a closure should reference
  captures via `self.cap_<n>`.
- **General confusion**: read `docs/INFLUENCES.md` §1
  (substrate ladder) to see where the current arc fits.

---

## 13. Current frontier notes

- **Phase B is complete + reactive library/substrate boundary
  is locked.** PB3 shipped multi-subscriber Signal with R2
  reentrancy; PB3(1/5) closed the captured-resource consume
  hole; PB4 relaxed reentrant `set` to a queued-coalesced
  drain loop AND locked the position that reactive LIBRARIES
  (Reactor / Memo / Effect / batching / topology) are
  **userland work**, not future builtins. This matches the
  Rust and Zig position: substrate in the language, reactive
  library in userland.
- **The next arc is Steve's choice from the forward-arc
  menu.** With Phase B done and the language/library boundary
  locked, the unblocked V1 work splits into two categories:

  **A. Substrate cleanup (GPT-5.5 entry 32 + entry 39
       "must-have before credible V1")** — items that gate
       real stdlib / library development:
    - ~~**`%T` unsafe / effect boundary**~~ ✅ **Landed in
      M21**, simplified in **M22** (`raw` block only).
    - ~~**Fake-surface audit / floor-raising**~~ ✅ **Landed
      in M22.1.**
    - ~~**M15b cross-module signature import**~~ ✅ **Landed
      in M15b.** Every cross-module reference now carries
      the same checked contracts as same-file. `pub` is
      real. Tier-1 cross-module leak closed.
    - ~~**M15b.1 unbound-name detection + scope correctness**~~
      ✅ **Landed in M15b.1.** Sema-time "use of unbound name"
      for value-position bare-name and unknown-callee.
      `synthBlock` scope-tracking fixed. `walkDecl` missing
      `.@"generic_enum"` arm fixed. 13 test fixtures updated.
    - ~~**M15b.2: public-API-leaks-private-type rejection**~~
      ✅ **Landed in M15b.2.** Decl-time check on every
      `pub fun` / `pub sub`: the return type, every parameter
      type, and every `parameterized_nominal` argument is
      walked recursively, and any same-module non-`pub`
      nominal leaf fires a diagnostic anchored at the
      function's name position. `imported_nominal` and
      runtime-registered builtins (Cell/Closure/Vec/Signal)
      are exempt; `type_var` is exempt (substituted at use
      sites). 5 new regression tests
      (`examples/pub_leaks_private_rejected.rig` covers
      return-type / param-type / `Box(Secret)` shapes;
      `test/modules/cross_pub_leaks_private_rejected/` is
      the cross-module integration). 982 → 987 tests.
      Implementation: `TypeResolver.collectPrivateNominalLeaks`
      + `TypeResolver.checkPublicSignatureLeaks` in
      `src/types.zig`, called from `resolveFun` after the
      function symbol's `is_public` flag and `ty` field are
      stamped.
    - **Legacy global name-scan retirement** in `emit.zig`
      (M20a.2 + M20e.1 partial). Internal cleanup; standalone
      arc now that M15b.2 is shipped.
    - **Body-less `extern fun`/`extern sub` declarations**
      (M23). Per GPT-5.5 entry 39: "a more urgent FFI hole
      than raw-fn, honestly. `extern puts: fn(String) Int`
      works, but it is not the ergonomic or readable shape
      users will expect."
    - **Closure-with-args** (M24: `Closure1<T>`,
      `Closure2<A,B>`) beyond no-arg `Closure()`. Required
      for any callback-based API that takes arguments.
    - ~~**User-defined `Drop` / non-Copy resource values**
      (M25)~~ ✅ **Landed in M25.** User `drop self: !Self`
      declarations on plain structs work end-to-end:
      sema validation (`resolveDropDecl` enforces the
      receiver shape, exactly-one-per-struct, no return,
      no fallibility, structs only); ownership generalizes
      the M20d alias-discipline to all `has_drop_glue`
      types ("any type with drop glue is non-Copy"); emit
      produces a compiler-generated `__rig_drop` that calls
      the user body (if any) then walks resource fields in
      reverse declaration order. Auto-generated drop glue
      fires even without a user body when the struct owns
      resource fields — that's what makes M25 a real
      substrate unlock for the userland reactive library.
      See `docs/ROADMAP.md` §M25 for the full retrospective
      and the V1-deferred follow-ups (drop-body restrictions,
      user Clone, optional-resource auto-drop, generic /
      enum Drop, auto-deref through member-access in method
      bodies). Cell-non-Copy split to M26 per GPT-5.5's
      design lock.

    Reserved (M22.1 retracted; sema-rejected with reserved
    diagnostic, design space preserved for V2+):
    - `try INDENT body OUTDENT [catch ...]` value-yielding
      block — `expr!` + inline `expr catch |e|` cover V1.
    - `zig "..."` inline-Zig escape — `raw` + `extern`
      cover V1.
    - `@x` pin sigil — V2 pinning story.
    - `for *x` ptr-mode loop binding — future by-ref
      iteration likely uses borrow-shaped (`for ?x`).
    - `pre <expr>` / `pre_block` — `pre_param` covers V1.

  **B. Optional substrate extensions** — these add language
       surface but aren't V1-blockers:
    - **`Cell`-non-`Copy` (M26)** — replace/take semantics
      for resource-typed Cells. **Now the natural next arc
      post-M25.** With user Drop in place, the userland
      reactive library only needs the second half (Cell.set
      that drops the old value, Cell.take that yields and
      empties, Cell.replace that swaps and returns) to
      become buildable. Per GPT-5.5's M25 design lock: this
      is its own arc with its own design checkpoint —
      `Cell.set(v)` for resource T, the optional-resource
      semantics for `take`, the empty / taken state model,
      the interaction with `*Cell(T)` interior mutation
      through shared. Open the M26 design checkpoint with
      GPT-5.5 before opening M26(1/n).
    - **Layer 8 (structured concurrency)** — scope-bound
      tasks, cancellation discipline. Prerequisite for safe
      async per INFLUENCES §1. PB3 + PB4 shapes generalize
      to `Future<T>` (resolve-once + waiter list + drain) but
      async still needs state-machine lowering, poll/wake ABI,
      pin discipline, cancellation, and an executor — NOT a
      "trivial derivation" from PB4.
    - **Phase C reactive sugar** (`:=` / `~=` / `~>`).
      Optional Rip-style ergonomics. Per GPT-5.5 entry 31:
      "do not do sugar before PB4 semantics stabilize"
      (PB4 is now stable, so this is unblocked, but it's
      still last-priority luxury).
    - **`pre` AST extraction** (REACTIVITY-DESIGN D8) — for
      derive-style macros. Would unlock auto-tracking Memo.
    - **Persistent / CHAMP-backed collections** — see
      INFLUENCES §6.

  **C. V1.x tooling layer** — see `docs/ROADMAP.md` §V1.x.
       Smaller scope than Category A or B; no design checkpoint
       required (it's a projection over the existing
       `SemContext` + IR Tags, not a new IR). Reasonable to
       interleave between Category A items.
    - **`rig sema --json` v0** (V1.x(1)) — stable, versioned,
      AI/tool-facing JSON projection of `SemContext`. Surface:
      module / decl IDs with source spans, symbol table,
      resolved types, effect sets per decl, ownership ops per
      binding, closure captures with mode, call-graph edges,
      diagnostics carrying semantic IDs. Excludes: the internal
      S-expression IR shape (free to evolve) and emit-layer Zig
      text. Schema version IS the public contract.
    - **`rig graph`** (V1.x(2)) — derived dataflow / effect /
      ownership graph view over the `sema --json` export. No
      new semantic facts; pure projection. Optional;
      experimental until the export schema is stable.

    Non-goal for Category C: any direction shift toward "Rig as
    AI-native language" marketing. The visible-effects thesis
    is what makes Rig useful to AI tooling; this category just
    exposes those facts cleanly (per INFLUENCES §10 rule 9).

  **My read**: Category A is more aligned with making Rig a
  usable systems language; Category B is more aligned with
  pushing the substrate forward; Category C unlocks the
  external tooling / AI-peer-review surface without changing
  the language. Steve picks based on what use case is pulling
  on him next.

- **Maintain the cadence**: design checkpoint → sub-commits →
  post-impl review. The cadence has caught real correctness
  bugs in every M20+ arc (UAF in M20h's earlier ABI proposal;
  `in_set_rhs` leak in M20g; emit reverse-scan fragility in
  M20i.1; captured-resource UAF in PB3); skipping it costs
  more than running it.
- **Closing PB3(1/5) hazards on the radar**:
  - The non-escaping-closure consume-from-capture path
    (`bump = fn |+sig| -sig`) was the second case PB3(1/5)
    closed. Same `is_capture_resource` flag fires. Future
    extensions to non-escaping-closure body shapes need to
    keep this hook live.
  - If/when `*Closure(...)` grows block-body support
    (currently inline-call only per M20h grammar), the audit
    is already in place — consume-of-capture is rejected at
    the ownership layer, not the emit layer.
- **Reactive library boundary for V1**: per the PB4 entry 33
  + 34 lock, **for V1, no more built-in reactive primitives
  ship without an explicit design reset**. Anyone wanting
  Reactor / Memo / Effect builds them in Rig source on top of
  Cell + Vec + Closure + Signal (once Cell-non-Copy lands).
  The "explicit design reset" escape hatch leaves room for
  V2 cases like thread-safe `Arc<Signal>` that genuinely
  can't be expressed userland — but those would require a
  fresh full design pass with GPT-5.5, not an incremental
  bolt-on.
- **The substrate ladder** (`docs/INFLUENCES.md` §1) is the
  authoritative conceptual map. Layers 0–7 ✅; Layer 8
  (Structured concurrency) and Layer 9 (Async) deferred
  pending forward-arc decision.

Good luck. Read `docs/INFLUENCES.md` §1 first, then ROADMAP's
PB4 and PB3 sections, then this file's invariants. Then
discuss with Steve which forward arc (substrate cleanup
Category A vs substrate extension Category B) his current
use case favors.
