# Rig — Session Handoff (post-M20d)

**You are picking up a Rig compiler session in mid-arc.** This document
captures everything you need to continue cleanly. Read top-to-bottom
once; then it's a reference.

---

## TL;DR

- **Project**: Rig is a systems language ("Zig-fast, Rust-safe, Ruby-readable")
  that compiles to Zig 0.16. Repo: `/Users/shreeve/Data/Code/rig`.
- **Where we are**: Just shipped **M20d + M20d.1** (`*T` / `~T` real
  `Rc<T>` / `Weak<T>` semantics, plus post-review tactical fixes).
  Last commit on `main` covers M20d.1. **556 tests passing, 0
  failing.** Clean tree, all pushed.
- **Next milestone**: **M20e** — automatic scope-exit drop for `*T` /
  `~T` bindings. Design pre-sketched in ROADMAP M20e entry; must land
  before M20+ item #8 (closure capture).
- **Owner**: Steve (`shreeve@github`). Collaborates with the AI agent
  AND consults GPT-5.5 via the `user-ai` MCP for design checkpoints +
  post-implementation reviews.
- **Established cadence**: design checkpoint → implement in 3–5 sub-
  commits (M5-style: `Mxx(n/total)`) → post-implementation review →
  commit. Each sub-commit must keep all tests passing.

---

## 1. Project orientation (read these first)

Authoritative project docs, in order of importance:

| File | Purpose |
|---|---|
| `SPEC.md` | Language spec. Ownership sigils, `?/!` triangle, V1 scope, etc. §Shared Ownership covers the M20d V1 contract (explicit-drop, alias rule, `*T?` vs `(*T)?` precedence, `*expr` move semantics). |
| `docs/ROADMAP.md` | Milestone history (M0–M20d done). M20e queued. M20+ "now-blocking" list at the bottom. |
| `docs/REACTIVITY-DESIGN.md` | Substrate design note. The forcing function for M20+ work. |
| `docs/SEMANTIC-SEXP.md` | Sema IR shape. What the grammar emits, what the checker walks. |
| `docs/INHERITED-FROM-ZAG.md` | Grammar/lexer surface inherited from the Zag/Nexus stack. |
| `rig.grammar` | Nexus grammar. Conflict count currently **38** (M20d added 4 for `*T?` / `~T?` chain). |

Codebase highlights:

| File | Role |
|---|---|
| `src/rig.zig` | Lexer rewriter + Tag enum. Add new IR tags here. |
| `src/parser.zig` | **Generated** by `zig build parser` from `rig.grammar`. Don't edit by hand. |
| `src/types.zig` | Sema: SymbolResolver, TypeResolver, ExprChecker, Type interner, lookup helpers. ~5800 lines after M20d. |
| `src/emit.zig` | Zig codegen. ~2400 lines after M20d. |
| `src/ownership.zig` | M2-era borrow/move checker. M20d added the alias-footgun rule (`checkSharedHandleAlias`). M20e expands the scope-exit walker here for auto-drop. |
| `src/effects.zig` | Fallibility (`T!`) checker. Subordinate to sema. |
| `src/modules.zig` | Multi-file projects via `use foo`. M15. |
| `src/main.zig` | CLI driver. M20d added `_rig_runtime.zig` sibling-file writing in `emitProjectToTmp`. |
| `src/runtime_zig.zig` | M20d V1 runtime source as a Zig string constant. Emit prepends `const rig = @import("_rig_runtime.zig");` to every module. |
| `build.zig` | Build steps. `zig build`, `zig build parser`, `zig build test`. |
| `test/run` | Test driver. `./test/run` to verify; `./test/run --update` to regenerate goldens. |
| `examples/*.rig` | Source-form test inputs. Auto-discovered by `test/run` for raw_sexp/semantic_sexp/errors goldens. |
| `test/golden/{raw_sexp,semantic_sexp,errors,emitted_zig}/*.{sexp,txt,zig}` | Goldens. |
| `EMIT_TARGETS` in `test/run` | Names of `examples/` to run end-to-end (emit + ast-check + actual `bin/rig run`). |

---

## 2. M20+ status (the big picture)

| # | Item | Status | Where |
|---|---|---|---|
| 1 | Instance methods + `self` semantics + receiver-style calls | ✅ | M20a + M20a.1 + M20a.2 |
| 2 | Real generic-instance member typing | ✅ | M20b(4/5) |
| 3 | Generic methods on generic types | ✅ | M20b(4/5) + M20b(5/5) |
| 4 | `Option(T)` / `Result(T, E)` as generic enum types | ✅ | M20c |
| 5 | Methods on enums | ✅ | M20a |
| 6 | **`*T` / `~T` real `Rc` / `Weak` semantics** | ✅ | **M20d (just landed)** |
| 6.5 | Automatic scope-exit drop for `*T` / `~T` | ⬜ | **M20e (next — design pre-sketched in ROADMAP)** |
| 7 | Interior mutability — `Cell(T)` library type | ⬜ | After M20e (or before, IF Cell stays simple) |
| 8 | Closure capture mode syntax (`|name|` / `|~name|` etc.) | ⬜ | After M20e (HARD dependency — see ROADMAP M20e entry) |

---

## 3. M20d retrospective + decisions locked

M20d shipped as 5 sub-commits with one tactical follow-up pass on the
GPT-5.5 conversation. The full milestone retro lives in
`docs/ROADMAP.md` (M20d section); this section captures the **decisions
locked** during the milestone so future work doesn't re-derive them.

### Joint Q1 — Auto-drop discipline (Steve delegated to Claude + GPT-5.5)

**Decision: Option A — explicit `-x` / `-w` only for V1.** Compiler
auto-drop synthesis deferred to **M20e**, queued before #8 closure
capture.

Rationale (jointly agreed):
- M20d already touched grammar, type variants, runtime, driver wiring,
  operator emit, read-only auto-deref, and three receiver-mode
  rejections. Adding flow-aware drop synthesis to the same milestone
  would force meaningful surgery on `src/ownership.zig` (M2-era) AND
  touch every control-flow form (early return, break/continue, panic,
  try/catch, match arm divergence, conditional moves) — too much
  surface for one milestone.
- A → B is strictly additive (M20e can refine M20d users' code
  silently); B → A would be breaking.
- Rig's visible-effects thesis supports explicit `-x` — consistent
  with `<x` / `+x` / `?x` / `!x` already being explicit.
- The alias-footgun rule (M20d(3/5)) catches the worst silent-leak
  hazard (`rc2 = rc`, `f(rc)`). The residual "forgot to `-x`" leak is
  documented honestly in SPEC §Shared Ownership.

### Joint Q2 — Multi-module runtime resolution

**Decision: sibling file in the same tmpdir as emitted modules.**
`emitProjectToTmp` writes `_rig_runtime.zig` once, every module
prelude has `const rig = @import("_rig_runtime.zig");`, all modules
share one dir so the import resolves uniformly.

### Joint Q3 — `*expr` consume vs clone

**Decision: `*expr` MOVES `expr` into the new `RcBox`.** Implicit
clone would silently duplicate ownership. Users wanting to keep the
original write `*(+expr)` (clone then move into Rc). Documented in
SPEC §Shared Ownership.

### Q4 — Existing `(share x)` / `(weak x)` no-op users

Resolved trivially: only `examples/spacing.rig` used these in
expression position (parser smoke test). M20d's sema change (`(share x)`
types as `shared(typeOf(x))`) is transparent to the test because the
spacing test only checks raw_sexp / semantic_sexp shapes, which were
unchanged.

### New: `*T?` precedence

Suffix `?` binds TIGHTER than prefix `*` / `~`, consistent with
`?T?` / `!T?`. So `*User?` parses as `(shared (optional User))`
("shared handle to optional User"); the "optional shared handle"
form needed by `WeakHandle.upgrade()` is spelled `(*User)?`.
Documented in SPEC §Shared Ownership.

### GPT-5.5 refinements folded in

All 8 of GPT-5.5's post-(1/5) refinements made it into the right
sub-commits:

| # | Refinement | Where it landed |
|---|---|---|
| 1 | Explicit runtime API names (`cloneStrong` / `dropStrong` / `cloneWeak` / `dropWeak` / `weakRef` / `upgrade`) | M20d(2/5) `src/runtime_zig.zig` |
| 2 | `+weak` / `-weak` lower correctly (not silently no-op) | M20d(3/5) `handleKindOf` dispatch |
| 3 | Moves don't touch refcounts (sema-only handle transfer) | M20d(3/5) `(move x)` pass-through |
| 4 | Bare-handle alias rule for ordinary binding/assign/call-arg | M20d(3/5) `checkSharedHandleAlias` in `ownership.zig` |
| 5 | Read-only auto-deref ONLY (write/value through `*T` rejected) | M20d(4/5) `unwrapReadAccess` + `ReceiverTypeKind.shared` |
| 6 | Reject nested `**T` (defensive, since `**` lexes as power op) | M20d(4/5) `resolveType` arm |
| 7 | Soft scope-exit warning lint | **Deferred to M20e** (would need new `warning` severity + scope-exit walker; M20e needs the same walker for auto-drop so they share infrastructure) |
| 8 | Runtime as Zig string constant (operationally simpler than `@embedFile`) | M20d(2/5) `src/runtime_zig.zig` |

### One deviation from GPT-5.5's M20d design

`WeakHandle.dropWeak` takes `Self` BY VALUE, not `*Self`. GPT-5.5's
original spec was `*Self` for defensive nulling. The deviation: `*Self`
would require weak bindings to emit as `var` in Zig (Zig errors on
`&const_binding` to a non-const param), which would force sema-aware
mutation scanning in emit. Rig's ownership pass already catches
`-w; -w` (see `walkDrop` — "cannot drop `x` twice"), so defensive
nulling without ownership integration would just paper over checker
bugs. Trade-off documented in `src/runtime_zig.zig` source.

### M20d.1 follow-up (post-review fixes)

After M20d shipped, GPT-5.5's post-implementation review surfaced
four items; all addressed in M20d.1 (see ROADMAP). Tests grew
544 → 556.

- Recursive chain check for `rc.inner.field = X`
- `weak.upgrade()` sema first-class (returns built-in `(*T)?`)
- `formatType` paren-disambiguation for `*T?` vs `(*T)?`
- Ownership-side scope-aware lookup in `checkSharedHandleAlias`

### Two pre-existing gaps NOT addressed in M20d/M20d.1

1. **`(T)?` paren-grouping in type position**: the grammar's
   `"(" type ")" → 2` action leaks the literal parens into the IR
   (`(T)?` becomes `(optional (( T )))` instead of `(optional T)`),
   so users can't currently spell `(*T)?` (the return type of
   `WeakHandle.upgrade()`) in type annotations. Workaround: rely on
   type inference (`m = w.upgrade()`); the type is correct in sema
   even if not annotatable. Pre-existing Nexus grammar action
   behavior; fix queued as a future cleanup.
2. **Emit's `handleKindOf` global symbol scan**: same shadowing
   fragility as the ownership-side check, but in emit. M20d.1 fixed
   the ownership side; the emit side stays as first-match-wins with
   a documented TODO. Failure mode is loud (Zig compile error like
   "no field 'X' on RcBox"), not silent. The systematic fix is a
   sema-side use-site attribution table (`pos → SymbolId` built
   during type-check, queryable from emit + ownership). Queued as
   substrate cleanup; would also subsume the M20a.2 two-self-methods
   global-scan fragility.
3. **`unsafe` / `%x` enforcement** (M20+ item #9). Pre-existing
   deferral, unchanged.

---

## 4. M20e plan (next session)

The ROADMAP M20e entry has the full design sketch. Quick recap:

- Extend `src/ownership.zig` (or a dedicated post-ownership pass) to
  synthesize `(drop x)` IR nodes at scope exit for any `*T` / `~T`
  binding not already discharged.
- **Discharge markers** (per GPT-5.5's M20d Q1 refinements):
  - `-x` (explicit drop)
  - `<x` (move out, including `<- rc` and explicit `<rc` arg / RHS)
  - bare `return x` on a tail position (treat as consuming move-out)
- **Non-discharge** (binding stays live):
  - `+x` (clone — original still alive)
  - `~rc` (weak ref — original shared still alive)
  - `w.upgrade()` (weak still alive)
  - field access / method calls (read-only via auto-deref; binding
    not consumed)
- **Suppress synthesis when**:
  - binding type isn't `shared` / `weak`
  - binding already in state `.moved` or `.dropped`
  - global / `pre` decl
  - binding type is `unknown` (no type info means we can't be safe)
- **On top of the same walker, add the M20d-deferred soft warning
  lint**: when synthesis is blocked by a shape we can't safely
  synthesize for (multiple control-flow branches with divergent move
  status, etc.), emit a warning telling the user to add explicit `-x`.

Hazards to design through (GPT-5.5 flagged these in the M20d design
pass):
- early `return`, `break` / `continue`, `panic` / `unreachable`
- `try` / `catch` unwinding (M14's labeled-block lowering is
  non-trivial)
- `match` arm divergence (M18 multi-statement arms)
- conditionally-moved bindings (`<rc` in one arm only — only ONE
  branch should drop)
- M17's labeled-block recipe for `if`-as-expression (`rig_blk_N`)

Expected sub-commits: 4–5 (mirror M20d). First commit is probably
the IR + walker scaffolding (no behavior change); subsequent commits
add discharge tracking, branch-aware analysis, the lint, and tests.

**Pre-(1/5) checkpoint with GPT-5.5 is recommended** — auto-drop is
the kind of work where a focused design pass catches whole categories
of bugs before code lands.

---

## 5. Open questions for Steve (BEFORE M20e)

**Q1 — Auto-drop scope: full RAII or just shared/weak?** Rig's
existing M5 v1 Move classification treats nominal user types
(`User`, `Box`, etc.) as Move but DOES NOT enforce no-implicit-copy
on plain assignment. M20e could either:
- (A) Only synthesize drops for `*T` / `~T` (matches the M20d V1
  contract; smaller scope). User types still leak silently.
- (B) Generalize to all non-Copy types with declared destructors
  (full RAII). Requires `Drop` infra (which V1 doesn't have yet)
  and is a much bigger lift.

My lean for M20e: **A**. M20+ item #7 (`Cell(T)`) and the reactive
substrate need shared/weak RAII specifically; nominal-type RAII can
wait for a dedicated "user Drop" milestone (M20f / V2).

**Q2 — `weak.upgrade()` sema first-class?** Make `w.upgrade()` work
via Rig source (currently errors). Two implementations: synthetic
field on weak symbols, or `synthMemberCall` intercept. Either is
small. Worth bundling into M20e (1/n) or a separate M20d.1?

My lean: bundle into **M20e(1/n)**. The auto-drop walker needs to
treat `w.upgrade()` as non-discharging, which means it needs to
recognize the form anyway. Adding the sema bridge at the same time
keeps the design coherent.

---

## 6. Working conventions

### Git

- All commits on `main`. No feature branches in current practice.
- Sub-commit style: `Mxx(n/total): short summary` (M5-style).
- Commit messages: motivation + what changed + GPT-5.5 attribution
  where applicable + test count delta. See M20a–d commits for
  templates.
- ALWAYS pass via HEREDOC for multi-line messages:
  ```
  git commit -m "$(cat <<'EOF'
  Title

  Body
  EOF
  )"
  ```
- Push after every commit (this project doesn't accumulate locally).

### Testing

- `./test/run` — run all 544 tests + Zig unit tests
- `./test/run --update` — regenerate goldens (review diffs before committing)
- New examples auto-discovered for raw_sexp / semantic_sexp / errors
- For end-to-end (emit + ast-check + actual run): add example name to
  `EMIT_TARGETS` in `test/run`
- Every sub-commit must keep tests green

### GPT-5.5 collaboration

**This is non-negotiable per Steve.** Established pattern:

1. **Design checkpoint BEFORE coding**: send proposed design (with
   alternatives + your lean on each question) to GPT-5.5 via the
   `user-ai` MCP server's `discuss` tool with `conversation_id:
   "c_5c1d09d53ebe2f62"` and `model: "openai:gpt-5.5"`.
2. **Implement** against the design (with corrections applied).
3. **Post-implementation review**: send the full diff back via the
   same conversation. Attach diffs as file paths (write to `/tmp/`
   first). Expect 1–2 rounds of fixes.
4. **Commit only after sign-off.**

**Set `max_tokens` >= 6000** when asking GPT-5.5 — its responses are
substantive. The `max_tokens: 4000` default once produced an empty
response (eaten by reasoning budget).

**Key prior reviews** (in the conversation thread): M5(1–6) audit,
M20a design pass, M20a.2 hardening, M20b design + 2 review rounds,
M20c design + review, M20d design + post-(1/5) refinements +
tactical Q2/Q3/`*T?`-precedence round.

### Editing conventions

- DO NOT edit `src/parser.zig` directly — it's generated.
  Edit `rig.grammar`, run `zig build parser`, commit both.
- DO NOT touch `.zig-cache/` — that's build artifacts.
- DO NOT add emojis to code or docs unless explicitly requested.
- DO use the `ReadLints` tool after substantive edits to check for
  linter warnings in modified files.
- DO use `TodoWrite` for multi-step tasks (any 3+ step plan).

---

## 7. The user-ai MCP conversation

Persistent conversation ID: **`c_5c1d09d53ebe2f62`**

It now contains, in order:
1. M20a thesis review
2. Reactivity design discussion (3+ rounds)
3. M20a design pass → implementation → 2 review rounds
4. M20a.1 sugar → review
5. M20a.2 hardening → 2 review rounds
6. M20b design checkpoint → 5 sub-commits → 2 review rounds
7. M20c design checkpoint → 3 sub-commits → review
8. M20d design checkpoint
9. **M20d Q1 (auto-drop) decision** — joint Claude + GPT-5.5 call,
   Option A locked
10. **M20d post-(1/5) tactical Q2/Q3/`*T?`-precedence round** — A/B/C
    + 8 concrete refinements, all folded into (2/5)–(5/5)

To continue the thread, pass `conversation_id: "c_5c1d09d53ebe2f62"`
and `model: "openai:gpt-5.5"` (or `"openai:gpt-5.5-pro"` for harder
questions). Models live in
`/Users/shreeve/.cursor/projects/Users-shreeve-Data-Code-rig/mcps/user-ai/tools/`.

---

## 8. Hazards / things to NOT do (post-M20d edition)

1. **Don't extend `unwrapReadAccess` to peel `weak`.** Weak handles
   require explicit `.upgrade()`. Adding silent weak deref would
   reintroduce null-deref hazards.
2. **Don't extend `unwrapBorrows` to peel `shared`.** Use the narrower
   `unwrapReadAccess` helper. Hazard #2 from the prior HANDOFF is
   resolved by the helper split — keep them separated.
3. **Don't let auto-deref bridge write/value receivers.** M20d(4/5)'s
   `checkReceiverMode` adding `.shared` rejection for `.write` /
   `.value` is the safety check. Removing it would silently permit
   write-through-shared, breaking the aliasing model.
4. **Don't `@constCast(sema)` in emit.** Use `typeEqualsAfterSubst`
   for type comparisons in emit paths.
5. **Don't bind weak handles to `var` in emit speculatively.** The
   runtime's `dropWeak` takes `Self` by value (M20d deviation) so
   weak bindings can stay `const`. Adding `var` would trip Zig's
   unused-mutable error.
6. **Don't use a mutable global allocator.** Allocator is in
   `RcBox`. M20+ may later thread allocator through; keep the
   storage-in-box invariant.
7. **Don't use `u32` for refcounts.** `usize` per GPT-5.5.
8. **Don't make `Option` / `Result` the built-in optional / fallible
   representation.** `T?` and `T!` are separate built-in types.
9. **Don't skip the GPT-5.5 review loop.** Cost: ~$0.30/round; value:
   prevented soundness bugs in every M20 milestone so far.
10. **Don't ship M20+ #8 (closure capture) without M20e first.**
    Captures of `*T` / `~T` need automatic drop or every closure
    leaks every captured handle on each invocation.

---

## 9. If you get stuck

- **Tests failing after a change**: `./test/run 2>&1 | grep FAIL`
  shows just the failures. Most failures are golden diffs from
  intended changes — verify with `git diff test/golden/` and
  `./test/run --update` if intentional.
- **Grammar conflict count changed**: revert and reconsider. The 38
  conflicts are all reviewed and intentional. Adding more without
  understanding is a code smell.
- **Sema diagnostic isn't firing**: check that the IR shape reaches
  the right walker. `bin/rig normalize path/to/file.rig` prints the
  semantic IR — useful for confirming what sema sees.
- **Zig compile error in emitted code**: `bin/rig run path/to/file.rig`
  shows both the emitted Zig path (in the error footer) AND any Zig
  errors. For shared/weak issues: open `/tmp/rig_<name>/<name>.zig`
  AND `/tmp/rig_<name>/_rig_runtime.zig` to inspect.
- **`*T` user-code surprise**: re-read SPEC §Shared Ownership. The
  V1 contract is explicit-drop, no auto-deref for weak, read-only
  for shared.
- **General confusion**: read REACTIVITY-DESIGN.md. It's the design
  note that drives the M20+ ordering and explains *why* each
  substrate piece matters.

---

## 10. Closing notes from the M20d session

- The user is Steve. Communicates clearly; trusts the GPT-5.5 loop.
- Pace expectation: M5-style sub-commits with reviews. Each sub-
  commit must be self-validating.
- Steve delegated Q1/Q2/Q3 + `*T?` precedence jointly to Claude +
  GPT-5.5 during the M20d arc. The decisions are recorded in §3
  above and in the GPT-5.5 conversation thread. Don't re-derive
  them.
- The Rip→Rig syntax connection is important to Steve. REACTIVITY-
  DESIGN.md is the validation target for the entire M20+ arc.
- Rig's "wow factor" emerges from the COMBINATION of features. Don't
  over-promise individual ones; value is in the synthesis.
- Have fun. The trajectory is sound, the substrate is most of the
  way in, and M20e is the last piece before the reactive validation
  milestone can begin.

Good luck. Read SPEC.md §Shared Ownership, then ROADMAP.md M20d +
M20e sections, then the M20e design sketch in §4 above. Then
checkpoint the M20e design with GPT-5.5 before starting M20e(1/n).
