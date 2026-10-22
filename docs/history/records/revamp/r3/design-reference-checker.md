# Design: a reference ownership checker for Rig (the oracle)

Read-only design, 2026-10-03, against `revamp` at 2d9e490f (saved by the lead from the
design agent's report; the agent had no write tool). Numbers measured with today's `bin/rig`.

## 0. Summary
- A small reference checker written from `docs/CORE.md`, run only in the test suite beside
  `src/ownership.zig`; reports every function where they disagree (production accepts, reference
  rejects = likely hole; the reverse = false rejection or reference gap).
- Recommended: a test-only Zig executable `bin/rig-oracle` (`zig build oracle`, sources in
  `test/oracle/`). It lowers each function body into a tiny core with explicit statement
  temporaries and explicit evaluation order, then runs a bitset dataflow (CFG liveness, loan set
  per var, fixpoint): the NLL/Polonius "facts and rules" shape, specialised to Rig.
- Coverage: stage 1 (<= 1,500 lines) decides 61% of the corpus (60% of its accepted probes) and
  79% of the matrix; stage 2 reaches 86% of the corpus and 100% of the matrix.
- Cost: no Zig build; ~12 ms CPU per program; ~30 s wall for the whole corpus at -j 2.

## 1. Architecture
### (a) Zig, in process, over a lowered core (recommended)
- `test/oracle/main.zig` roots a separate executable. Zig forbids imports outside a module's root,
  so `src/lib.zig` (6 lines) re-exports `modules`, `sema`, `parser`, `rig`, `diag`; `build.zig` adds a
  `rig_lib` module (with the `rig_std` import) used only by the oracle, and an `oracle` step copying
  the binary to `bin/rig-oracle`. `src/main.zig` never imports `lib.zig` or `test/oracle/`.
- One behavior-neutral hook in `modules.zig`: per module, whether ownership ran and the range of
  diagnostics it appended (`own_diags: [2]u32`), since sema errors stop ownership.
- Per program, one process: load and check with `ModuleGraph` (production's verdict); for every
  function body of every non-std module whose sema has no non-lint error, lower to the core or
  abstain; run the dataflow; compare per function.
- Allowed inputs: IR via `parser.ir` accessors; `symbolOf`/`Symbol`; `typeOf`, `TypeStore`,
  `typeInfo` (`glue`, `plain`, `borrows`, `poison`, `has_type_var`); `callSlotsOf`;
  `calleeOf`/`instanceOf`/`genericCallOf`; `elemCallOf`/`textCallOf`; `isErrorMember`, `isExhaustive`.
- Forbidden (production's classifications): `dropsTemp`/`temp_drops`, `readsInPlace`,
  `takesSubject`, `readsThrough`/`reads`, `readsAsView`, `unboxes`, `arrayViewOf`, `lendsText`,
  `takes`, `writesThrough`, `lendsCellTemp`, `cell_temps`; step 2's `handsOver`/`Use`; anything in
  `ownership.zig` or `typecheck.zig`. A lint enforces it.
- Why: independent code, classification and control flow; +10–20% over `rig check`; exact types;
  exhaustive `Tag` switch makes a new IR kind a compile error until classified or abstained.
### (b) Python over `check --facts` + `--facts=sema`: highest independence, but names lack identity
(shadowing), types are spellings without `TypeInfo`; ~3x slower; new node kinds fail silently.
Fallback only.
### (c) Rejected: Datalog/Soufflé (external dep, same lowering), abstract interpreter (dynamic; the
sanitizer covers that), a second rule table in ownership.zig or desugar-to-Rig-then-production
(not independent).

## 2. Abstention
- Unit: a function body (`fun`, `sub`, method, `drop` body, `test` block). Verdicts: accept,
  reject(rule, location, reason), unknown(reason). Lowering is total or returns
  `error.Abstain{kind, span}`; the dataflow never guesses.
- Stage 1 covers: module/fun/sub/struct/enum/errors/use/test/drop_decl decls; `set` (every op),
  `drop`, `pass`, `block`, `labeled`; `if` (block, ternary, guard), one-part `as`, `while` (as, step,
  else), `for` (read/write/move/range/call source), `match` with arms/patterns/guards; `return`,
  `break`, `continue`, `propagate`, `propagate_none`, `catch`; `call` (functions, methods, `print`,
  `Text`, element and Text built-ins, imported/std functions by signature), `member`, `index`,
  `array`, `array_fill`, `kwarg`, `..`; every operator, `??`, `and/or/not/neg`; `move`, `read`,
  `write`, `clone`; every type kind except `shared`/`fun_type`.
- Stage 1 abstains on: closures (lambda, captures, fun_type values); handles (`*T`, `~T`); `defer`,
  `errdefer`; `Cell`/`Signal`; `raw_block`, `builtin`, extern; generic bodies. Also: poison-typed
  expressions, joined `and` chains with `as` parts, assigning through a held `!T` whose `T` may hold
  a view, assigning a view to a view-typed place (Core §6 planned), `for`/`match` over a non-call
  made value (Core gap D9/D10).
- Measured whole-program coverage (`rig normalize` node kinds):

| Set | Programs | Stage 1 | Stage 2 | Stage 3 |
|---|---|---|---|---|
| corpus | 4,273 (1,862 accepted) | 2,609 (61%) | 3,661 (86%) | 4,181 (98%) |
| matrix | 1,224 | 970 (79%) | 1,224 (100%) | — |
| behavior+reject+examples | 1,691 | 867 (51%) | 1,332 (79%) | 1,545 (91%) |

  Corpus programs per excluded group (any/only): handles 640/360, closures 534/296, generics
  509/320, Cell/Signal 241/104, defer 78/54, raw/extern 50/43, test 15/10, unparsable 42.

## 3. Rules (each cites a Core sentence s1–s10 or section)
The oracle implements the *built* status; widening planned rules sit behind `--planned`; narrowing
planned rules (Cell `unique`) are never on by default.
### 3.1 Core form
Vars: parameters, user bindings (by SymbolId), hidden vars (statement temps `%t`, join vars `%j`,
match subject, for source). Places: root var + path; loans on root vars. Ops: `copy`, `move`,
`take` (optional field), `lend(read|write|reserved)`, `clone`, `make`, `call`, `assign`,
`drop` (guarded), `dead`, `use`. Terminators: goto, branch, switch, return, fail. Every op carries
its span and Core rule.
### 3.2 Kinds (§1) from typeInfo: plain; handle (top-level `*T`/`~T`); owning (glue, or holds an
owner/handle); view (borrows non-empty, or String; write if borrows.write).
### 3.3 Lowering: context decides (READ, TAKE, RET, LEND, DISCARD per Core §3)
- L1 (s1,s4) place in READ: plain/read view copies with its loans; else implicit read lend; never moves.
- L2 (s1) place in TAKE: copy if plain/read view; owner/handle/write view rejected (C2) except a
  bare local in RET, which moves.
- L3 (s2,§5) `<p`: move a whole binding; `<p.f` optional field: take; else reject.
- L4 (s2) `+p`: read access; new owner carrying p's loans.
- L5 (s4,§3) `?e`/`!e`: lend a place; a made `e` goes to `%t` then is lent (views stay in statement).
- L6 (§3) made values in READ/DISCARD: fresh `%t`, dropped and dead at statement end, last made
  first; in TAKE straight into dst.
- L7 branching values (ternary, ??, catch, e!, e?) become CFG branches; each leaf lowered in the
  parent's context into one join var. READ never moves; TAKE bare non-copy leaf is C2.
- L8 headers are their own statements; header temps die at header end; bindings live through body
  (call result -> hidden owner; `?p` -> view; `<p` takes).
- L9 match: hidden subject var holds the lend through every guard and arm (failed-guard edge keeps
  it live); payloads are views or copies; `match <p`/call result: bindings own payloads; moving out
  through a view: C7.
- L10 for: `?p`/`!p` hidden source var holds the lend; elements copies or views; `<p`/call owned.
- L11 (§6) `p = e`: e first (TAKE into %v), then index operands left to right, then assign.
- L12 calls (built order; a Core gap): callee value, receiver, arguments left to right; a `!`
  receiver/argument is a two-phase `lend(reserved)` (conflicts like a read until the call).
- L13 (s3) scopes end with guarded drops in reverse order then deads; jumps emit the same per scope
  left, plus statement temps so far.
### 3.4 Loan flow and liveness
Facts: issued(L,P) (one external loan per view-capable parameter; static for literals/constants),
holds(V,L,P), live(V,P) (backward CFG liveness), access, cfg. loan_live(L,P) :- holds(V,L,P), live(V,P).
Flow (filtered by destination type: a type that can hold no view carries no loan): F1 lend gives
{L} ∪ holds(root); F2 copy of a read view carries its loans; F3 make unions operands; F4 call result
carries loans of every view-capable argument/receiver and the callee value (s7); F5 after a call
each `!` root gains all arguments' loans; F6 assign: whole var strong update, field/element weak
union. Joins union; status init ⊓ moved = maybe-moved; loops to fixpoint. A var is used by any op
reading it, by a drop whose type has a user drop body; a `!` parameter is used at every exit.
### 3.5 Checks
C1 (s1,s2) use of a not-definitely-initialized var. C2 (s1) owning/handle/write-view place in TAKE
without `<` outside RET. C3 (s2) `<p.f` of a non-optional path. C4 (s5) access conflicting with a
live loan on the same root (reserved conflicts except reads). C5 (s6,s3,§3) drop/dead of a var with
a live loan ("does not live long enough" / "outlives its statement"). C6 (s7) at exit, returned
value and `!` params hold only external/static loans. C7 (§5) move out through a view. C8 (s9,
stage 2) store of a loan-carrying value into Cell/Signal/owned closure. C9 (§7, stage 2) defer
bodies inlined at each exit before drops. Not checked: mutability/permission (sema), §8 syntax.

## 4. Diagnostics (triage only)
`<file> <function> prod=<accept|reject|sema|skip> ref=<accept|reject|unknown> [<rule> L:C <reason>]`.
Flags: `--explain FN` (lowered core with loan sets and live vars), `--liveness=textual` (classify
liveness-precision differences), `--planned`.

## 5. Integration
- Test kind `oracle` in `test/run` (on by default; builds `bin/rig-oracle` via `zig build oracle`);
  chunks of ~300 programs: whole corpus (no sampling), behavior/reject/known/examples, every rig doc
  block, matrix programs via `test/matrix.py --oracle`. ~45–60 s wall at -j 2.
- Fails on: production accepts and reference rejects; ownership rejects and reference fully accepts;
  a stale allowlist entry (FIXED); oracle crash/assert; decided-function count below
  `test/oracle/coverage` floor.
- Allowlist `test/oracle/differences`: `<program> <function> <prod-accepts|prod-rejects> <class> <note>`,
  classes prod-unsound (needs test/known file), prod-strict, ref-gap, core-gap.
- Every rig/rig reject block of CORE.md must get the same verdict; with `--planned`, pending blocks
  their decided verdict; promotion flips the oracle rule in the same change.
- Lint: `test/oracle/` imports no ownership.zig/typecheck.zig and no forbidden accessor; nothing in
  `src/` imports lib.zig or test/oracle.
- Process: the oracle's author works from CORE.md, SPEC §7 and the tests, without reading
  ownership.zig; each rule's comment cites its Core sentence.

## 6. Size and staging
| Stage | Contents | Zig lines | Time |
|---|---|---|---|
| 1a | main.zig ~220, core.zig ~130, kinds.zig ~50, lower.zig ~400 (straight line, if/ternary, while, for, jumps, calls/methods/print/Text/built-ins, sigils, temps and headers), flow.zig ~320 (liveness, fixpoint, C1–C7) | ~1,120 | 4–5 days |
| 1b | match/guards, if/while…as, catch, ??, e!, e?, labeled | +300 (≈1,420) | 2–3 days |
| glue | build.zig ~20, src/lib.zig 6, modules.zig hook ~3, test/run kind+lint ~60, matrix --oracle ~15 | ~100 | 1 day |
| triage | classify/allowlist or fix first disagreements | — | 2–4 days |
| 2 | handles, closures, defer/errdefer, Cell/Signal, joined as chains, --planned | +600–700 | 1–1.5 weeks |
| 3 | generic bodies, textual-liveness triage, independent kind recomputation | +250–350 | 3–5 days |
Land 1a before step 2's B3/B4 so every step-2/3 commit runs under it.

## 7. Risks and limits
- Emit-side bugs (W3) are invisible (e.g. `v[0] = grow(!v)`, F2): sanitizer + equiv.py cover them.
- Would have caught F1 (C2) and both temporaries slips (C5 at `dead(%t)`; live subject var on
  failed-guard edge).
- Shared inputs (parser, rig.zig rewrites, sema types, TypeInfo bits) mislead both; stage 3's kind
  recomputation covers part.
- Shared misreading of the Core: independent author, sentence-cited rules, doc-example check.
- Core gaps it surfaces: call evaluation order and two-phase write lends (L12, built and tested but
  not in CORE); D9/D10; whether a drop with no user body uses what the value views.
- Noise: CFG liveness more permissive than production's (informational, classified by
  --liveness=textual); the oracle must be at least as precise as production on forms it decides,
  or abstain.
- Drift guards: exhaustive Tag switch, coverage floor, CORE examples through the oracle.
- Not covered: generic instance requirements, cross-module proxies, raw code.
