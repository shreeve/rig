# Step 10: one lowering for the checker and the emitter (design study)

Read-only study of the `revamp` worktree at `d0d009c7`. Every `file:line`
below is at that commit. Probes are in `probes/` next to this file. Each
was run with that worktree's `bin/rig` (built Oct 4 23:35) and
`bin/rig-oracle`.

## 0. Summary

**The class.** Emit introduces a storage location that the ownership
checker never walks, so a view that the checker roots at the subject
points into a copy in the emitted Zig. Today each instance is handled by
a conservative rejection.

**Evidence.** In the last three review rounds, 8 of the 10 Critical/High
findings were this class:

- step 3 round 2: R2-C1, R2-C2, R2-C3, R2-H1;
- steps 4–5 round 1: C1, H1, H3;
- steps 4–5 round 2: R2-C1.

The other two (steps 4–5 H2 and round-2 H1, `.slot` under a read view)
were representation bugs that the Zig compiler caught. So HANDOFF's
condition for step 10 ("decide from the bug rate that remains") is met:
the rate in this class did not fall after steps 1–5.

**What this study adds.** An inventory of every hidden storage emit
writes (§1), plus two accepted latent instances that no rule covers
(§1.4: p01, p05).

**Recommendation.**

- **Do not build a full lowering (Core IR) inside this consolidation.**
  It is 6–10 weeks of work and rewrites both `ownership.zig` and
  `emit.zig`.
- **Inside the consolidation, build "storage facts".** Each hidden
  storage emit makes becomes a recorded fact, decided once in typecheck
  where the header class is already decided. The ownership checker walks
  each fact as a hidden var with its real lifetime. Emit may declare
  storage only through one chokepoint that requires the fact, and never
  takes the address of a Zig rvalue. This generalises what `dropsTemp`
  already does for statement temporaries. It gives the structural
  guarantee for the known class: every emitted storage location is a
  fact the checker walks. Cost: about 1.5–2 weeks for stages B1–B3.
- **Then (the payoff) make emit point, not copy, for place and view
  subjects** (B4), and derive the rules from the storage facts instead
  of stating them on syntax (B5). This lifts `rejectHeaderCopy` for
  place subjects and the blanket `arm_view` rule, as HANDOFF promises.
  B4 and B5 fit in the consolidation only if the schedule allows;
  otherwise they come right after it.
- **Keep the oracle independent.** It must not share the lowering. It
  should stop mirroring the compiler's arm-local restriction
  (`test/oracle/lower.zig:1008-1014`). Add a dynamic second opinion that
  sees emitted storage: poison hidden storage at the end of its
  lifetime under `RIG_SANITIZE`.
- **Record the full lowering (A) as a decision and plan only.** Build it
  later, staged construct by construct, if the bug rate after B stays
  high.

---

## 1. The problem, precisely

### 1.1 The rule and the class

AGENTS.md, "How we build", says: *the checker checks exactly what is
emitted. Emit adds no temporary, evaluation order, re-evaluation, or
drop that the ownership checker did not walk.*

Today the checker walks the source IR (with facts). Emit walks the same
IR and decides on its own where to make Zig storage. Statement
temporaries are the one place where the two already share a recorded
decision: `dropsTemp` (`sema.zig`; walked by `ownership.zig:1503`
`holdTemp` and `:1513` `dropStmtTemps`; emitted by `emit.zig:1072`
`emitTempSlots` and `:3052` `rig.keep`). Every other hidden storage is
emit's own decision.

### 1.2 Inventory of hidden storage, order and drops in `src/emit.zig`

Status key:

- **W**: walked (the checker models the same storage or order).
- **C**: compensated (a conservative rule makes it safe).
- **U**: uncompensated.
- **R**: representation only (no ownership effect).

#### Group 1: copies of a subject, part or receiver (the bug class)

| # | Site | What emit introduces | Checker side | Status |
|---|---|---|---|---|
| 1.1 | `openHeader`/`closeHeader` `1104-1117` | `(__rig_hdr_N: { slots; break :__rig_hdr_N e; })` **yields `e`'s value** (an rvalue copy) while ending the header's temporaries. Called from `emitHeader` 1120 (conditions 1824-1830, guards 2649, range bounds 2260, taken sources 2159), `for` sources 2170-2172, consuming `for` 2217, the `match` operand 2369-2378, `evalSubject` 2478 and 2500, and `as` heads 2921 and 2952. | The temporaries are walked: `walkMatch` `header_temps` `ownership.zig:3897`. The yielded copy is not a var. | **C**: `copiesHeader` plus `rejectHeaderCopy` (`typecheck.zig:2312-2325`) accept it only for a read of plain data. Emit checks its shape against the fact (2139, 2327, 2913). It is harmless where the value is a `Bool`, an index or a bound, or a made value that is taken. |
| 1.2 | `evalSubject` `2493-2506` | `var __rig_subject_N: T = value` for a guarded, held or re-read `match` whose subject has no storage or makes temporaries. Arm bindings point into it (`&subj.a.r`, 2720 and 2861). | The checker walks the subject itself and a `hold` var with its loans (`ownership.zig:3909`). | **C**: every read binding that is not plain data is arm-local, guarded or not (`arm_view`: `typecheck.zig:2486` and `2634`; `ownership.zig:4028-4040`, 832, 846, 3697). Also `copiesHeader`. |
| 1.3 | `emitMatch` `2368-2378` | An unguarded `switch` on a header block or a call result: `\|*p\|` captures point into Zig's rvalue. | Same as 1.2. | **C**: `arm_view`, `copiesHeader`. |
| 1.4 | `rig.borrowed(T, b)` (`writeLocalPlace` 1557-1561, `emitDeref` 3485-3489, member/index 3641-3644; `runtime.zig:108`) | A generic `?T` read as a value is `borrow.*` by value, a copy. A `switch` over it with `\|*x\|` points into the copy (step 3 R2-C3). | Not modelled. | **C**: `arm_view`. A `no_cell` instance requirement for match payloads (`typecheck.zig:2629`). `no_move` and `no_cell` for loop copies (1909-1910, 1966). |
| 1.5 | `emitOptionalHead` `2915-2934`; `bindOptionalBorrow` `2986-2989` | `if/while … as` over a view whose header makes temporaries: by-value capture, then `var __rig_opt_N_v = __rig_opt_N; const x = &__rig_opt_N_v`. | Not modelled. | **C**: `copiesHeader` plus `rejectHeaderCopy` (`typecheck.zig:1608`). The Cell holder is rejected separately (`typecheck.zig:1570-1572`). |
| 1.6 | `lendsCellTemp` copies: `emitOptionalHead` 2947-2949, `hoist` 5066-5074 (`var __rig_arg_N_k = part`), `hoistReceiver` 4967-4992 (`var __rig_recv_N`) | A Cell-holding part of a temporary is copied into a mutable local **inside the call block** (`__rig_call_N`). | `ownership.zig` never reads `lendsCellTemp`. A view of the part carries a loan on the statement temporary, which lives for the **statement**. | **U** (lifetime). The copy dies at the end of the call block, but the checker lets the result live to the end of the statement: probe **p01** (§1.4). The copy is also redundant now that the temporary has a mutable slot (`rig.keep(...).*` is an lvalue; see p01's emit). |
| 1.7 | `emitMemberBase` `4183-4187` | A receiver or object that branches (`if`, `match`, `??`, `catch`) is `@as(T, if (c) a else b)`, an rvalue copy. A `?self` method gets `*const T` of Zig's temporary. | The checker reads the receiver in place: each leaf is held (`holdBranchReads` `ownership.zig:3190`), and the result carries `a`'s and `b`'s loans. | **U** for a view result: probes **p03** and **p05** are accepted, and `r` points into the dead rvalue. **C** only for Cell holders ("cannot call … on a temporary that holds a Cell", `typecheck.zig:6784`; probe p04). |
| 1.8 | `payloadAliases` `2850-2864` | A payload of a type parameter (`copyable == .depends`) is bound by value, `const v = __rig_payload.v` (step 3 R2-C2). | Not modelled. | **C**: `arm_view`, `no_cell` (2629). |

#### Group 2: owned hidden storage the checker walks (the model to generalise)

| # | Site | What emit introduces | Checker side | Status |
|---|---|---|---|---|
| 2.1 | `emitTempSlots` 1072-1084; `emitStmt` 1050-1062; `rig.keep` 3052-3061; value block 4309-4314; value body 1034-1038 | `var __rig_tmp_N`, `_live`, a `defer` drop, and a drop after the statement, last made first | the `dropsTemp` fact: `holdTemp` 1503, `dropStmtTemps` 1513 | **W** |
| 2.2 | `emitHeld` 954-971 | `var __rig_held_N = base` plus a `defer` drop, in a block around the construct | `heldBaseOf`: `holdBase` `ownership.zig:3836` | **W**. `holdsHeld` (`typecheck.zig:2285`) rejects a base that makes temporaries. |
| 2.3 | `emitFor` 2152-2161 | `var __rig_src_N = <header>` (taken) | `takesSubject`: hidden var | **W** |
| 2.4 | `emitConsumingFor` 2206-2242 | `__rig_it_N` with `defer deinit`, and `__rig_elem_N` moved into an owned local | `walkFor` (move) | **W** (at the level of the form) |
| 2.5 | consuming `match` 2403-2427, 2729-2747, 2873 | `__rig_whole`, `__rig_payload`, `defer rig.discard` | `match <x` moves | **W** (form) |
| 2.6 | `bindParams` 761-763, prologue 804-806 | `var x = __rig_arg_N` for an owned parameter | an owned param var | **R** |

#### Group 3: evaluation order and re-evaluation

| # | Site | What emit decides | Checker side | Status |
|---|---|---|---|---|
| 3.1 | `hoistsArgs` 4847-4879; `emitHoistedCall` 5022-5048; `hoist` 5054-5106; `hoistReceiver` 4962-5005 | a `__rig_call_N` block, `__rig_arg_N_k`, `__rig_live_N_k` with drop defers, `__rig_recv_N`; source order, passed in slot order | `walkCall` 2997 walks in source order; a moved value's loans last until the call ends; `holdRead` 3172 | **W** for order. Storage lifetime is the call block (see 1.6). Decided by emit-local syntactic predicates, not facts: `isPureArg` 4904, `isOwnedValue` 4926, `consumedTemporary` 4888, `contains(...)`. |
| 3.2 | `openAssign` 1436-1455; `hoistIndices` 1466-1494; `emitPlaceAssign` 1376-1419; `emitRebind` 1324-1355 | `__rig_new_N`, `__rig_ix_N_k`, `__rig_slot_N`: the value first, then the indexes, then the store; the old value dropped after the new one is made | `walkFieldAssign` 2899, `walkIndicesHeld` 1945, `walkSet` 2694 (value first), `reassign` 2827 | **W**. The trigger is syntactic: `actsBeforeStore` (6220), `isPureArg`. |
| 3.3 | `emitGuardedMatch` 2616-2678; `guardBindings` 2701; `armBindings` 2726 | Bindings are read once for the guard and again for the arm, from the same `subj`. The subject is not evaluated again. | Guards are walked over the bindings, with a `hold` var | **W** (but `subj` may be the copy in 1.2) |
| 3.4 | `emitPrintArgs` 5250-5262; `printsByAddress` 5267-5279 | a tuple: by address for `readByAddress` types, by value otherwise | `holdRead`; same fact (`sema.readByAddress`) | **W** |
| 3.5 | `emitWhileJoined` 1968-2003; `emitRangeFor` 2255-2262; `emitStep` 1927-1945 | where the step is placed; bounds evaluated once | per-form walkers | **W** |

#### Group 4: drops and drop flags

| # | Site | What emit decides | Checker side | Status |
|---|---|---|---|---|
| 4.1 | `emitGuard` 922-941; `resourceGuard` 945; `Scan` 5972-6038 | Whether a binding gets an alive flag (`__rig_alive_x`), from emit's own scan of `<x`, `-x`, tails, `for <v` and `\|<x\|` | The checker's moves are not recorded as facts. Emit's tail takes do read the `useOf` fact (`takesTail` 3272). | **W** today, but **a second classifier** of "may be consumed". If the planned bare `break x` (Core s1) is built, `Scan` (which has no `break` case) must change in step: a sibling hazard. |
| 4.2 | `defer`/`errdefer` 1150-1154; slot and guard `defer`s | Zig's defer order | `exitTo` 1066 re-walks defer bodies at each exit | **W** (by Zig's semantics) |
| 4.3 | `rig.discard` 1207; `isNone`/`isVariantDiscard` 3789-3811 (`dropsWhenTested` 4943) | drops inside the runtime | consuming position; derived from `handsOver` and `dropsTemp` | **W** |

#### Group 5: closures

| # | Site | What emit introduces | Checker side | Status |
|---|---|---|---|---|
| 5.1 | `emitStackClosure` 5331-5339; `emitCaptureInit` 5385-5416 | `var f = struct{…}{ .cap_x = … }` | a closure var holding its captures' loans | **W** |
| 5.2 | `hoistClosure` 5535-5546; `emitInlineInvoke` 4655-4672 | `__rig_env_N` / `__rig_fn_N` in the call block, with `defer rig.dropFields` | no var | **C**: "a closure literal lives only for the call" (`typecheck.zig:8281`; probe p06 is rejected) |
| 5.3 | `emitOwnedClosure` 5459-5482 | a heap environment | an owned value with no loans (C8) | **W** |

#### Pointers into places (no new storage; listed for completeness)

- `const __rig_subject_N = &place` (2468-2471).
- `const __rig_subject_N = view_call()` held as the pointer it is
  (2475-2491).
- `lendChain`'s `(if (x.*) |*__rig_lent_N| …)` (3192-3196). Its operand
  is a place or a kept temporary (`rig.keep(...).*`), so it is an lvalue.
- `for (…items()) |*x|`.

These are all sound.

### 1.3 What the compensations cost

All the "C" rules above exist because of emit:

- `copiesHeader` with `rejectHeaderCopy`;
- `arm_view` (every non-plain read payload or catch-all binding is
  arm-local, even for a plain place subject with no guard, where emit
  points into the place);
- `holdsHeld`;
- the Cell-holder `as` rejection;
- the receiver-Cell-temporary rejection;
- the closure-literal-for-the-call rule;
- the generic `no_cell` and `no_move` copy requirements.

Each rule is stated on the subject's **syntax**. Steps 4–5 round 2 asked
for the opposite: "the rule should be stated once, on the emit path that
copies, not on the subject's syntax." CORE carries the cost as "payload
views … usable within their arm only, for now". HANDOFF lists it under
"Weak spots".

### 1.4 New uncompensated instances (probes in `probes/`)

| Probe | Shape | `rig check` | Emitted Zig | Run |
|---|---|---|---|---|
| p01 | `print(id(?mk().p).n)`, `P` holds a Cell | accept | `__rig_call_2: { var __rig_arg_2_0 = (rig.keep(...).*).p; break :__rig_call_2 id(&__rig_arg_2_0); }).n`: the pointer outlives its block | prints correctly; a latent dangling read of a block local |
| p02 | two such calls in one `print` | accept | same | correct in Debug and in `--release=fast` |
| p03 | `r = (a if c else b).inner()`, `inner(?self) -> ?Text` | accept; oracle accepts | `const r = @as(S, (if (c) a else b)).inner();`: `r` points into a dead rvalue | prints correctly (latent) |
| p04 | p03 with a Cell holder | rejected (6784) | | |
| p05 | p03 with `?[4]Int` | accept; oracle accepts | same shape | correct in Debug and `--release=fast` (latent) |
| p06 | a closure literal lent, and the result called | rejected (8281) | | |

These are latent: the sanitizer guards heap only, and Zig/LLVM did not
reuse the dead stack slots in these runs. By Zig's rules they are uses
of dead storage, so each is the class in another form. Probes p03 and
p05 also show the oracle cannot see this class: it checks the program's
meaning, not the emitted Zig (INTERNALS, "The reference ownership
checker").

---

## 2. Candidate designs

Common requirements:

- equal emit for programs a stage does not touch, shown by `test/equiv.py`;
- the oracle stays a second opinion;
- one ownership branch at a time;
- accept means correct at every stage.

### Design A: a lowered Core IR, produced once, checked, and emitted from

**Shape.** A new pass `src/lower.zig` runs after typecheck and before
ownership, per function. It produces a tree or CFG of a small core:

- places and hidden vars, each with a kind (`temp`, `held`, `taken`,
  `subject`, `arg`, `recv`, `new`, `ix`, `env`) and a scope;
- explicit `move`, `copy`, `lend` (with its representation: pointer or
  value), `drop` at points, and `seq` (evaluation order);
- `match` desugared into tests plus bindings;
- `as`, `??`, `catch`, `e?` and `e!` as tag tests with labeled exits;
- `defer` as cleanups at exits.

Every node carries a source span and an "origin" name for diagnostics
(e.g. "the temporary `Text(…)`"). `ownership.zig` walks Core IR, so the
`handsOver`, `takeTail` and header special cases disappear. `emit.zig`
prints Core IR. Representation (Zig types, `const`/`var`, `@constCast`,
`ReadBorrow`) stays in emit. Storage, order and drops come only from
Core IR.

**What it removes.** All of §1's "C" rules, except the ones that are
true Core rules:

- `copiesHeader`/`rejectHeaderCopy`, `arm_view`, `holdsHeld`, the Cell
  `as` and receiver rules, and the closure-literal rule all become plain
  consequences of hidden vars with scopes;
- the emit-local classifiers `isPureArg`, `actsBeforeStore`,
  `hoistsArgs`, `consumedTemporary` and `Scan` go away;
- about 15 hand-written `__rig_` storage families become one.

This is the end state the core-audit described (`core-audit/emit.md`
§5, L0–L6).

**Cost.** L0 (facts per question) is largely done in steps 1–2. What
remains:

- the Core IR and lowerer: about 2.5–3.5k new lines;
- an ownership port: about 40–60% of 5.2k lines rewritten as walkers
  over Core IR;
- an emit port: about 40% of 6.3k lines, mostly the control and storage
  paths: match (about 560 lines), `as` (120), headers and temporaries
  (120), hoisting (275), assignment order (125), loops (380).

Effort: **6–10 weeks**, with review rounds. The net code size is about
flat to −2k lines.

**Risk.** High.

- It replaces the checker that 4,273 corpus probes and 910 matrix
  programs have hardened.
- Diagnostics must keep their wording and positions (every reject test
  compares them).
- Two big rewrites land at once, with no oracle-independent check for
  lowering bugs (the checker and emit share them).
- It cannot ship in this consolidation's one PR without freezing all
  other ownership work for its duration.

**Staging (with equiv.py).** Use a *mixed IR*. Core IR may embed
unlowered source nodes, which both passes handle as today, and constructs
move over one at a time:

- L1, calls and assignments;
- L4, statement temporaries (already a fact);
- L3, match and headers;
- L5, value sugar;
- L6, defer.

At each stage, the printer reproduces today's Zig exactly for constructs
whose storage does not change. `equiv.py` then shows emit diffs only in
programs that use the migrated construct, and only where storage really
changes. The facts and check sections must be identical except where a
construct's diagnostics are re-worded on purpose.

**Oracle independence.** It keeps lowering from the source IR, sharing no
code (the existing lint stays). It must not import `src/lower.zig`, or
lowering bugs become common-mode. Emit honesty is then structural (emit
cannot declare storage that is not a Core IR var), plus the dynamic
checks in design B.

### Design B: storage facts, a recorded plan the checker walks and emit obeys

**Shape.** Generalise `dropsTemp`/`heldBaseOf`/`copiesHeader` into one
fact:

```zig
Storage = struct {
    node: NodeKey,                    // the construct or expression
    kind: enum { header_value, subject, opt_binding, call_arg, recv, part_copy, branch_recv, env, held, taken, temp },
    by: enum { pointer, alias_copy, owned },
    life: enum { header, call, statement, arm, construct },
    ty: TypeId,
}
```

- **Typecheck** records it where it already classifies the header
  (`checkMatch` 2007, `checkFor` 1672, `checkOptionalBinding` 1544) and
  the call (hoisting, receivers). It decides it once, from `handsOver`,
  which keeps "one classifier per fact".
- **Emit** declares every `__rig_` storage through one chokepoint,
  `hiddenStorage(fact)`. It reaches an internal error if the fact is
  missing or disagrees. This generalises today's three "header copy the
  checker did not record" assertions.
- **Emit never takes the address of a Zig rvalue.** `emitAddressOf`,
  `|*x|` captures and `*const Self` receivers apply only to a Zig
  lvalue. An rvalue that needs an address gets a storage fact first
  (1.4, 1.7). `@as(T, if c a else b)` as a receiver becomes
  `(if (c) &a else &b)` when every leaf is a place, or a recorded
  `alias_copy` otherwise.
- **Ownership walks each fact.**
  - `pointer`: a loan on the place, as `?p`/`!p` (as today).
  - `owned`: a hidden owned var with that lifetime (as `held`/`taken`
    today).
  - `alias_copy`: a hidden alias var of that lifetime. Reading it is
    allowed. Views of it root there and end with `life`. A write, a
    move or a Cell change through it is rejected with **one**
    diagnostic: "this … binds a copy of `e` …; bind `e` to a name
    first".

  A copy of a type that moves and is not an alias (owning or unique) is
  an implicit copy, which the existing rule ("values that move are never
  copied implicitly") already rejects. The Cell-fork cases then follow
  from that rule rather than from syntax.
- **Drop flags** come from a fact the checker records (`consumed` per
  symbol), not from emit's `Scan`. This is optional; it removes the
  classifier in 4.1.

**What it removes.**

- **Immediately (B3):** the latent holes p01, p03 and p05 are rejected
  correctly ("does not live long enough", rooted at the copy).
  `arm_view` becomes derived: an arm binding views an `alias_copy` of
  life `arm` only where emit really copies. A plain place subject with
  no guard is viewed in place, so its payload views may escape the arm
  as Core sentence 1 says. That lifts the escaping-payload-views rule
  for the common case.
- **After B4 (point, don't copy):**
  - A place subject whose path makes a temporary (`match !v[idx(?Text("a"))]`):
    the indexes are hoisted into `__rig_ix` consts before the header, as
    `openAssign` does, and the header block breaks with the place's
    **address**.
  - A guarded match on a view-call subject is held as a pointer
    (already done).
  - A generic subject is switched on a pointer: a runtime
    `rig.borrowedPtr(T, &b)` that returns `*const T` in both
    `ReadBorrow` forms.
  - An `as` over a lent optional reached through temporaries keeps the
    pointer (`|*x|` on an lvalue).

  These lift `rejectHeaderCopy` for place, lend and branching subjects,
  so steps 4–5 R2-C1 and C1 become accepted programs with the right
  meaning. They also lift the Cell-holder `as` rejection and the
  generic `no_cell` *match* requirement where the binding now views in
  place. What remains copied is a made value: held or taken, already
  owned and walked.
- `lendsCellTemp` copies become unnecessary where the temporary has a
  slot (p01's emit shows `rig.keep(...).*` is already a mutable lvalue).
  The fact and its three emit paths can be deleted.

**Cost.**

| Stage | Lines | Time |
|---|---|---|
| B1 (fact plus chokepoint plus dump) | about 300–450 | 3–4 days |
| B2 (rvalue-address rule) | about 100–150 | 2–3 days |
| B3 (ownership walks `alias_copy`; touches `ownership.zig`) | about 200–300 | 4–6 days |
| B4 (point, don't copy) | about 200 changed in emit, about 30 runtime | 4–6 days |
| B5 (delete `copiesHeader`/`rejectHeaderCopy`/`arm_view`/`lendsCellTemp` paths; docs; tests flip) | net −150 to −250 | 3–5 days |

Total: **about 3–4 weeks**. The structural guarantee is reached at B3
(**about 1.5–2 weeks**).

**Risk.** Medium-low.

- The checker's structure stays. The new var kind (alias copy) is a
  small extension of the existing `alias_of` and `arm_of` vars
  (`ownership.zig:210-216`).
- Main risk: a storage site missed by the chokepoint. B1's audit is
  what finds it.
- B4 changes emitted shapes in the hottest emit paths (match, `as`),
  so it needs the corpus plus matrix.

**Staging (with equiv.py).**

- **B1:** emit is identical for every program. Checker and diagnostics
  are identical. Put the new facts behind a new `check --facts=storage`
  section, so the existing `facts`/`sema` sections stay byte-identical.
  equiv must show **zero diffs**. The chokepoint's internal errors are
  first a test-only report mode, listing unrecorded sites (p01 and p03
  will appear), then made fatal.
- **B2:** emit changes only for programs with an rvalue address (branch
  receivers, generic match operands). equiv lists them, and each is
  reviewed. The rest stay identical.
- **B3:** emit is identical. New rejections appear only for programs
  with latent holes. A reject test is added for each (p01, p03, p05
  first as `test/known/`). Every other diagnostic is identical.
- **B4:** emit changes only for programs with header temporaries,
  guarded matches without storage, generic matches with bindings, and
  `as` over views reached through temporaries. The meaning must stay
  the same. The sanitizer and corpus must be green.
- **B5:** rejections become acceptances. Reject tests become run tests
  (expected output written from the Core's meaning). CORE's "usable
  within their arm only, for now" and HANDOFF's weak spots change in
  the same commit.

Each stage is its own commit, with the gates.

**Oracle independence.** The oracle never reads storage facts; the
`test/run` lint already forbids reading the compiler's ownership
classifications, and `Storage` must be added to its forbidden list. Two
more measures:

1. **The oracle models the Core, not the compiler's limits.** Remove its
   mirror of `arm_view` (`lower.zig:1008-1014`). The compiler's
   remaining arm-local rejections then appear as `prod-strict`
   differences in `test/oracle/differences`. That is the right label:
   they are the compiler's restriction, and the oracle should say what
   the Core allows.
2. **A dynamic second opinion that sees emitted storage.** Under
   `RIG_SANITIZE`, emit poisons each hidden storage at the end of its
   `life`: `defer rig.poison(&__rig_subject_N)`, and the same for call
   blocks and header slots. A view that outlives its storage then reads
   `0xAA…` and the run's output (or the sanitizer) fails. Today the
   sanitizer guards heap memory only, which is why p01 and p05 pass.
   This needs no shared code with the checker, and it catches the
   class when a test exercises the path. Add a matrix axis: {subject
   shape} × {guarded} × {payload kind} × {escape, Cell change, write},
   the axis steps 3 R2-C1 asked for.

### Design C: adopt or extend the oracle's lowering

**Shape.** `test/oracle/lower.zig` (2,733 lines) lowers each function to
`core.zig`. That core has vars, loans, and ops with `reads`, `moves`,
`def`, `loan`, `access` and `kill`, in basic blocks. Statement
temporaries are hidden vars, and the order is explicit. It is close to
design A's analysis half.

**Why it cannot become the shared lowering:**

1. It is an **analysis IR with no values.** An `Op` records what is
   read, moved, lent or killed, not what is computed: no operators, no
   call targets with arguments as values, no representation (pointer or
   copy), no Zig control constructs. Emit cannot print Zig from it.
   Extending it to carry values is writing design A's IR.
2. It **abstains** on about 100 forms (`abstain(` sites in `lower.zig`:
   `raw`, compile-time arguments, keyword arguments out of place, joined
   `as` chains, write lends of made values, lends through handles, and
   more). The compiler must lower everything.
3. It encodes the **Core's meaning**, which is the point of an oracle.
   The shared lowering must encode the **emitted program's storage**,
   which is exactly where the two differ (§1).
4. Sharing it would make every lowering bug common-mode. The suite's
   only independent ownership check would disappear.

**What it can seed:**

- its lowering is a worked specification of design A's desugarings
  (`How`, `Place`, `Region` with statement temporaries last made first,
  `asHeader`/`heldPart`/`heldView` for header subjects, `defer`s
  inlined at exits);
- the `# oracle:` per-function verdict tests, as a format for Core IR
  tests;
- `flow.zig` (474 lines) as a model of a compact dataflow over basic
  blocks.

Reuse the design and the tests, not the code.

**Cost and risk.** Adopting it is design A plus migrating the oracle's
tests, so it is costlier than A. The independence loss is
disqualifying. Extending the oracle to model emit's storage is also
wrong, because it would make the oracle check the compiler rather than
the Core.

### Design D (baseline): keep rules per syntax, add only the audits

Do only B1 (chokepoint plus facts, report mode) and the sanitizer
poisoning. This finds the remaining instances, but every fix is still a
new rejection stated on syntax: the pattern that "a second soundness
round stops the feature" has already stopped twice. Cheap (about 1
week), but it does not meet "the checker checks exactly what is
emitted". Listed only for comparison.

---

## 3. Recommendation

### 3.1 Inside this consolidation (the one PR to main)

**Build B1–B3, and B4 for place subjects if the schedule allows.**
Together they give the structural guarantee for the known class: *every
storage location emit introduces is a recorded fact that the checker
walks with its real lifetime, and emit never takes the address of
storage the checker did not see.*

- **B1. Storage facts plus emit chokepoint plus `--facts=storage`.**
  - Record a `Storage` fact at each typecheck site that decides a
    header class or a call's hoisting.
  - Route every `__rig_` storage in emit (§1.2 groups 1–3 and 5.2)
    through `hiddenStorage(fact)`.
  - Report mode first (a test lists unrecorded sites), then fatal.
  - Gate: equiv.py shows zero diffs in every existing section.
- **B2. No address of a Zig rvalue.** Track lvalue-ness in emit's
  expression writer. Fix 1.7 (branch receivers become per-leaf pointers
  `(if (c) &a else &b)`) and 1.4 (generic subject through
  `rig.borrowedPtr`).
  - Gate: emit diffs only in programs with those shapes; corpus and
    matrix green.
- **B3. Ownership walks `alias_copy` facts** as hidden alias vars of
  their lifetime, with one diagnostic for a write, move or Cell change
  through a copy. `arm_view` is then derived from the facts instead of
  set on syntax.
  - p01, p03 and p05 (moved from `test/known/` to `test/reject/`) are
    rejected.
  - This touches `ownership.zig`, so no other ownership branch may be
    open.
  - Gate: full suite, corpus, matrix, oracle, and a review round
    dedicated to the class (step 3 R2-C1's matrix axis).
- **Add `RIG_SANITIZE` poisoning of hidden storage at end of life** (part
  of B1 or B3), so the dynamic check sees stack lifetimes.
- **Remove the oracle's `arm_view` mirror** (`lower.zig:1008-1014`) in a
  separate oracle-only branch. Classify the resulting `prod-strict`
  differences.
- **If time remains: B4 for place subjects reached through temporaries**
  (indexes into `__rig_ix` consts, then the header breaks with the
  address). This is the fix the steps 4–5 reviewer proposed. It turns
  `rejectHeaderCopy`'s place cases into acceptances.

### 3.2 Decision plus plan only, built afterwards

- **B4 in full and B5:** point, don't copy, for every subject and
  binding path, then delete `copiesHeader`/`rejectHeaderCopy`, the
  blanket `arm_view`, the `lendsCellTemp` copies, and the Cell `as`
  rejection. Promote CORE's "for now" wording. About 1.5 weeks after B3.
- **Drop-flag facts:** replace emit's `Scan` (4.1) with a recorded
  `consumed` fact *before* the planned bare `break x` is built.
- **Design A (Core IR):** decide by measurement. After B ships, count
  the Critical/High findings of the next two review rounds that are
  "emit and checker model different programs" (order, re-evaluation,
  drops, not only storage). If more than one per round remains, start
  A, staged L1 → L4 → L3 → L5 → L6 with the mixed IR, each stage gated
  by equiv.py. If not, A's main remaining benefit is deleting about 2k
  lines, which is not worth a checker rewrite during a freeze.

### 3.3 Staged plan with checkpoints

| # | Stage | Touches | Checkpoint (all gates green, and) |
|---|---|---|---|
| 0 | Add p01, p03, p05 to `test/known/`; add the step 3 R2-C1 matrix axis | tests | the known tests fail as expected |
| 1 | B1: `Storage` fact, `hiddenStorage` chokepoint, `--facts=storage`, report mode | sema, typecheck (recording only), emit | equiv.py: **zero** diffs in `parse`/`normalize`/`check`/`facts`/`sema`/`emit`; the report lists only the known sites |
| 2 | B1 fatal, plus sanitizer poisoning | emit, runtime | the suite is green; a poisoned probe fails before stage 4 and passes after |
| 3 | B2: lvalue rule; per-leaf pointer receivers; `borrowedPtr` | emit, runtime | equiv: emit diffs only in programs with branch receivers or generic matches, each reviewed; corpus and matrix green |
| 4 | B3: alias-copy vars in ownership; `arm_view` derived | ownership, typecheck | p01, p03, p05 rejected; every other diagnostic identical (equiv `check`); oracle and corpus green; **independent review round on the class** |
| 5 | Oracle: drop the arm-local mirror; reclassify differences | test/oracle | `differences` updated; no `prod-accepts` difference |
| 6 (stretch) | B4 for place subjects through temporaries | emit, typecheck | steps 4–5 r15, r19, r24, r25, c01, c08, c09 run sanitizer-clean with the Core's meaning; equiv: emit diffs only there |
| after | B4 rest, B5, drop-flag facts; then the A decision | | per §3.2 |

The stop rule applies to B too: if stage 4's review finds a second
round of soundness issues in this class, stop and move to design A.

---

## 4. Risks and open questions for the design owner ("Rig")

1. **Is a hidden alias copy acceptable Core semantics,** with views of
   it ending at its lifetime (B3)? Or must every view be of the
   subject itself (B4 required before B5)? CORE §2 sentence 1 says
   payload views are "usable within their arm only, for now". B3 keeps
   that true only where emit copies. The diagnostic must name the copy
   ("binds a copy of `e`"), not an invented scope.
2. **The new latent holes (p01, p03, p05)** are accepted today and have
   not been seen to misbehave. Fix them in the consolidation as bugs
   (as recommended), or record them in `test/known/` and leave them to
   step 10's build?
3. **Branch receivers:** `(a if c else b).m()` with `?self`. Lower to
   per-leaf pointers (sound when every leaf is a place, and Core §3
   says reading never moves), or reject as part of the planned "lend
   of a branching value"? The first matches what the checker already
   models (`holdBranchReads`).
4. **`lendsCellTemp`:** is it obsolete now that a temporary lent to
   read has a mutable slot (`rig.keep`)? If so, delete the fact and its
   three emit copies instead of recording them.
5. **Drop flags from emit's `Scan`** are a second classifier of moves.
   Accept the hazard until the planned bare `break x` lands, or move it
   to a fact inside the consolidation?
6. **The oracle's role:** confirm that it models the Core (not the
   compiler's restrictions), so that compiler conservatism shows as
   `prod-strict`. Commit `2c506e35` ("Align the oracle with step 3 …
   arm-local payload views") went the other way.
7. **Where storage facts are decided:** in typecheck, at the
   header-class decision (recommended, one classifier), or in a small
   "plan" pass after typecheck that also owns `hoistsArgs` and
   `actsBeforeStore`? The second is a step toward A, but adds a pass.
8. **Equivalence for B1:** is adding a new `--facts=storage` section
   (so the existing sections are byte-identical) acceptable as the
   proof? Or should `--facts=sema` include the new rows, with equiv
   taught to allow additive rows?
9. **Size and branch discipline:** B3 holds the single ownership branch
   for about 1 week. Confirm that nothing else touches ownership in
   that window. Confirm also that the consolidation PR can carry
   B1–B3 (and possibly stage 6) without blocking steps 6–9 for longer
   than that.
10. **Zig rvalue lifetimes:** B2's rule assumes we never rely on Zig
    keeping an rvalue temporary alive past its full expression. The
    `lendsTempArray` path (`&[...]` passed to a call that keeps no view)
    relies on it within one call. Confirm that it stays a documented,
    tested exception, or route it through a slot too.
