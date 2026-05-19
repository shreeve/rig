# AGENTS.md — compass for AI sessions on Rig

You are picking up a Rig compiler session. Read this file in full
before writing any code or making any design proposals. It is
short by design; the heavy detail lives in `HANDOFF.md`,
`SPEC.md`, and `docs/`.

---

## What Rig is (one paragraph)

Rig is a systems programming language with Zig-level performance,
Rust-inspired ownership safety, and a small, expressive surface
syntax. It compiles to Zig 0.16. The language is built around two
complementary invariants:

1. **Important effects are visible directly in the syntax** —
   ownership transfer, borrowing, cloning, dropping, shared / weak
   handles, failure propagation, compile-time specialization,
   capture modes, raw-escape boundary.
2. **Visible source effects survive as visible semantic Tags
   through lowering** — every syntactic effect emits as a
   first-class IR node the checkers and emitter consume by name.
   Tools that read the IR see the same facts the compiler does,
   without speculation.

That's the thesis. Everything else is implementation detail.

---

## Cadence (non-negotiable)

Every new design arc follows this cadence:

```
GPT-5.5 design checkpoint  (via the user-ai MCP server)
    ↓
3–5 sub-commits, M5-style numbering: Mxx(n/total)
    ↓
post-implementation review  (via user-ai)
    ↓
commit
```

Every sub-commit must keep all tests passing
(`./test/run` should report `N passed, 0 failed`).

The collaboration with GPT-5.5 has caught real correctness bugs
in every M20+ arc (UAF in M20h's ABI proposal, `in_set_rhs` leak
in M20g, emit reverse-scan fragility in M20i.1, captured-resource
UAF in PB3). Skipping it costs more than running it.

The active design conversation is `c_5c1d09d53ebe2f62`. Continue
it, or start a focused new conversation if the topic is
genuinely orthogonal.

---

## What you must read before touching code

In order, with rough budgets:

1. **`HANDOFF.md` TL;DR + Non-negotiable invariants** (~5 min) —
   current state and the invariants you cannot violate.
2. **`docs/INFLUENCES.md` §1** (~5 min) — the substrate ladder.
   The conceptual map of where every milestone fits.
3. **`docs/ROADMAP.md`** most recent entries (~10 min) —
   commit-by-commit history.
4. **`docs/REACTIVITY.md`** (~15 min) — Phase B north star.
5. **`SPEC.md`** §Overview + the section relevant to your arc
   (~10 min depending on scope).
6. **`docs/IR.md`** (~5 min) — IR shape and the
   lowering invariant.

If your work touches reactivity, also read
`examples/reactive_canary.rig` and
`examples/signal_multi_subscriber.rig` — the canaries are the
regression tests for the full Phase B chain.

---

## Don't-do list (hard rules)

These are guardrails. Each has caused or threatened real harm.

- **Don't add features that hide effects.** Visible source effects
  must survive as visible semantic Tags through lowering.
  Reserved-but-not-enforced surfaces are M22.1-class hazards;
  emit-time `@compileError`-as-placeholder is forbidden. New
  surface ships with full semantics + emit, OR a clean sema
  rejection with a Rig diagnostic.
- **Don't pivot Rig's positioning to "the AI language."** Rig is
  a systems language with a contract that happens to be useful
  to AI tooling because the facts are visible. AI-native
  marketing invites natural-language-input + opaque-generation
  expectations, the inverse of Rig's thesis. Per
  `docs/INFLUENCES.md` §10 rule 9.
- **Don't add GC.** Ownership replaces it. If a feature requires
  GC, redesign the feature, not the language.
  (`docs/INFLUENCES.md` §10 rule 4.)
- **Don't add a macro system in V1.** `pre` plus library design
  covers the V1 use cases.
- **Don't ship reactive library primitives as builtins.** PB4
  locked the position: `Reactor` / `Memo` / `Effect` / batching
  / topology are userland work. Substrate goes in the language;
  libraries go in user code. Matches Rust and Zig position.
- **Don't bypass the "any type with drop glue is non-Copy"
  rule (M25).** A struct with resource fields OR a user `drop`
  declaration is non-Copy at the ownership layer. Bare alias /
  assignment / call-arg is rejected; only `<x` move is the V1
  multi-binding shape. New language features that introduce a
  way to silently alias such values would re-open the double-
  free hazard the rule prevents.
- **Don't edit `src/parser.zig` by hand.** It's generated from
  `rig.grammar` via `zig build parser`.
- **Don't skip the GPT-5.5 design checkpoint.** Rationale above.
- **Don't fix the library when the language is wrong.** The
  canary discipline (`docs/REACTIVITY.md` Phase B Q1):
  the library is the canary; if it doesn't compose, fix the
  language.

---

## What "complete the Rig language" means

Phase B is shipped (substrate ladder Layers 0–7, 982 tests
passing). The next forward arcs are listed in `HANDOFF.md` §13:

- **Category A — Substrate cleanup**: M15b.2 ✅ shipped,
  M25 user-defined Drop ✅ shipped, body-less `extern fun`,
  `Closure1<T>` / `Closure2<A,B>` arity, legacy global
  name-scan retirement.
- **Category B — Optional substrate extensions**:
  M26 `Cell`-non-`Copy` ✅ shipped (completed the userland-
  reactive-library unblock alongside M25), Layer 8 structured
  concurrency, Phase C reactive sugar, `pre` AST extraction,
  persistent collections (conditional).
- **Category C — V1.x tooling**: `rig sema --json` v0
  (stable, versioned semantic export). Smaller scope, no
  design checkpoint required (it's a projection over
  existing `SemContext`). See `docs/ROADMAP.md` §V1.x.

The forward arc is Steve-driven. Your job is to execute the
chosen arc cleanly under the cadence above, not to invent a new
direction. If you think a direction change is genuinely
warranted, raise it as a discussion item with GPT-5.5 first.

---

## Where things live

| File | Role |
|---|---|
| `AGENTS.md` (this file) | Compass; first thing read |
| `HANDOFF.md` | Current state; non-negotiable invariants; forward-arc menu |
| `SPEC.md` | Language spec (canonical) |
| `docs/ROADMAP.md` | Milestone history (M0 → PB4 done) and V1.x tooling layer |
| `docs/CHECKLIST.md` | Per-milestone checklists |
| `docs/IR.md` | IR shape + lowering invariant |
| `docs/REACTIVITY.md` | Phase B design north star |
| `docs/INFLUENCES.md` | Design lineage; substrate ladder; strategic rules (§12 covers the Zag / Nexus grammar substrate) |
| `rig.grammar` | Nexus grammar (current conflict count: 75) |
| `src/rig.zig` | Lexer rewriter + Tag enum |
| `src/parser.zig` | **GENERATED** — do not edit by hand |
| `src/types.zig` | Sema (SymbolResolver, TypeResolver, ExprChecker, builtins) |
| `src/effects.zig` | Effects checker (fallibility) |
| `src/ownership.zig` | M2-era borrow/move/drop checker |
| `src/emit.zig` | Zig codegen |
| `src/runtime.zig` | V1 runtime as a Zig string constant (RcBox, WeakHandle, Cell, Closure0, Vec, Signal) |
| `src/main.zig` | CLI driver |
| `examples/` | Positive + negative examples; `*_rejected.rig` and `*_reserved.rig` are diagnostic regression tests |
| `test/run` | Test driver |

---

## If you get stuck

- **Read `HANDOFF.md` §12** ("If you get stuck"). It has a
  triage list for common failure modes.
- **Don't bypass an invariant to make a test pass.** If the
  invariant is wrong, the cadence is to discuss it with
  GPT-5.5 and update the invariant explicitly. Silently
  weakening an invariant is how substrates rot.
- **Re-read the substrate ladder** in `docs/INFLUENCES.md` §1.
  Most "I don't know what should happen here" questions resolve
  to "what layer is this on, and is the layer below it solid?"

---

## Bottom line

The thesis is the contract. The cadence is the discipline. The
ladder is the map. The invariants are the guardrails. Everything
else is implementation.
