# Design v2: checks the compiler proves away, rebuilt on units

Status: design only, nothing built. Replaces the walk of
`design-proven-checks.md` (§4.3, §5) and of branch `proofs` (PR #126).
Keeps its facts (`nonneg`, `below`, `fits`), its gen/use/kill tables
(§3, §4.2), `Proven` / `provenOf`, emit's four sites, the runtime
helpers, and `rig.len`. Builds on `setorder` (`storage.SetOrder`,
`storage.eachSetStep`), which must land first.

## 0. In one paragraph

Round 1's walk re-modeled, by hand, choices emit makes: which part of an
assignment runs first, where a loop's step sits, which arm a `match`
tries first. Each re-model drifted, and was patched. v2 removes the
proofs walk's dependence on *any* order inside a statement, and makes
every order *between* statements a recorded fact read by all three
passes. The body is cut into **units**: a statement, a guard part of an
`if`/`while` condition, a `for` source, a `match`'s arm selection.
**Inside a unit nothing is ordered**: every check in unit `u` is proved
from the facts at `u`'s entry minus every write anywhere in `u`, and a
fact `u` makes (a guard, a check that ran, `i = 0`) appears only on
`u`'s exit, and only if `u` writes nothing it names. **Between units**,
the walk follows a skeleton (block order, guard parts, loop step,
jumps, arm selection, defers, exits) whose every edge is a named fact
that emit and the ownership checker read too. Emit asserts, as it
writes, that each check and each write lands inside its own unit's
code, so no hoist can carry one across a boundary unseen.

## 1. The class behind the four holes

| # | Hole | What the walk assumed | Who actually decided |
|---|---|---|---|
| 1 | `continue` in a `while` condition reached the step before the guard | the step follows the guard | emit's step placement + Zig's continue expression |
| 2 | a `match` guard writing `i` changed later arms | arms are independent | emit's guarded-match lowering (labeled block of `if`s) |
| 3 | `t[i] = src[i]`: target proven by the value's check | value before target | emit's `actsBeforeStore`, else Zig's place-first order |
| 4 | `pick(!t, !i)[0] = s[i]` unchecked in `--release` | only target *indexes* can act | emit evaluated the call root in place, before the value |

All four: an order the walk used was computed in a second place. The
`walkAtomic` idea (an expression's parts are proved from facts that hold
in any order) was right; round 1 applied it to expressions but not to
statements, and modeled statement internals beside emit instead.

## 2. The construction

### 2.1 Units (one positive list, `syntax.eachUnit`)

A **unit** is one of:

1. a statement of a block that is not a structured statement: a binding,
   an assignment (any target, any op), an expression statement,
   `return e`, `break e`, `continue`, `<x`;
2. a **guard part** of an `if` or `while` condition: each operand of the
   condition's top `and` chain (through binding-condition joins), and
   each `as` part's value;
3. a `while` step (it is an assignment statement);
4. a `for` source;
5. a `match`'s **selection**: its subject, every pattern, every guard;
6. a `raw` block, which is **opaque** (§2.3).

Structured statements (`if`, `while`, `for`, `match`, a labeled or plain
block, `defer`) are not units; they are the skeleton that orders units.
A block inside a unit's expression (a value `match` arm, a value `if`
block, a `catch` handler block) holds **nested units**; a nested unit
lies wholly inside its enclosing unit.

`syntax.eachUnit(body, visitor)` lists every unit of a body with its
kind and its enclosing structure, and `storage`'s planner records
`unit_of(node)` (the innermost unit holding each node) as a node fact.

### 2.2 The unit rule

For unit `u` with entry state `E`:

- `K(u)` = every write site (`recordWrite`) in `u`'s subtree, nested
  units, closure literals (`|!i|`) and `defer`s registered inside `u`
  included. For an assignment, the store itself is **not** in `K(u)`:
  `eachSetStep` lists its steps (value, base, indexes), and the store
  follows the last step in every `SetOrder`. A compound op (`+=`) runs
  after every step, before the store.
- `A(u) = E − K(u)`, the **atomic state**. Every check in `u` (index,
  `read`/`write`, `+`, the compound `+=`, the target's place-finding
  index) is proved from `A(u)`. A nested unit's entry state is `A(u)`.
- Facts `u` makes (G1 at a guard part's true edge, G2 for a top-level
  check, G3 for `i = c` / `i = s.len` / `i = j`, G4 for a length read,
  E1 for `n = s.len`) are added on `u`'s exit edge, and each is dropped
  if `K(u)` or the store writes anything it names. Then the store's own
  effect applies (`i += c` keeps `nonneg(i)`; §3.3 of v1).
- Nothing else is generated inside `u`. Value-position `and`, `or`,
  ternary `if`, `??`, and `catch` are parts of their unit: their guards
  make no facts, and their operands' writes are in `K(u)`.

The rule names no order of evaluation. Any order emit picks inside `u`
(the setorder steps held or not, hoisted arguments, a held receiver or
subject, a statement slot) runs only code in `u`, whose writes are all
in `K(u)`, and makes no fact visible to `u`'s own checks.

### 2.3 Between units: the skeleton

| Construct | The walk |
|---|---|
| block | units and structured statements in order; at the end, apply the kills of the block's `defer`s |
| `if` | guard parts in order, each from the previous part's exit; the `then` block from the last part's exit; the `else` from `E − K(all parts)`; after it, `E − K(if)` |
| `while` | `L = E − K(loop)` (keeping `nonneg(i)` when every write of `i` in the loop is `+= c`); guard parts from `L` each iteration; body from the last part's exit; **step** from `meet(body end, every state a jump carries to .step)`; `else` from `L − K(parts)`; after it, `E − K(loop)` |
| `for` | source unit; `L` as for `while`; body from `L`; no fact about the bindings |
| `match` | selection unit; each arm body from the selection's exit; after it, `E − K(match)` |
| jump (`break`, `continue`) | carries `A(u) − K(every defer pending in the body)` to its `JumpDest`; only `.step` is joined (a `.head` lands in `L`, an `.exit` in the coarse join) |
| `return`, failing `e!` / `e?` | leave the body: carry nothing |
| `raw` | opaque: nothing in it is proven; after it, no fact |
| closure, `defer` body | walked as their own bodies, from no facts |

A meet is set intersection with the smaller `k` for `below`. Every state
inside a loop contains `L` (only kills of `K(loop)` remove facts, and
`L` names nothing in `K(loop)` except a kept `nonneg`), so a meet never
needs a fixpoint.

## 3. The facts (each decided once; who reads it)

| Fact | Decider | Emit | Ownership | Proofs | Re-derivation removed |
|---|---|---|---|---|---|
| **Statement order**: `SetOrder` (`set_order`) and the step list `eachSetStep` | `storage.decideSetOrder` (setorder) | `openAssign`, `hoistTarget`, `emitPlaceAssign` | `walkSet` over `eachSetStep` | `eachSetStep` only, to tell steps from the store; **no field of `SetOrder`** | round 1's `actsBeforeStore` re-model (gone with setorder) |
| **Units**: `unit_of(node)`, `syntax.eachUnit` | `eachUnit` (syntax, IR only), recorded by the storage planner | `enterUnit` at each unit it writes; asserts `unit_of(n) == current` at every check site, write site, and `hiddenStorage` evaluation | not needed: it walks every order exactly | the walk's partition | new |
| **Guard parts**: `syntax.eachGuardPart(cond)` | `rig.isConditionJoin` + the top `and` chain, one iterator | `emitIf` / `emitWhile` / `emitHeader` (one `if` per binding part; each `and` operand marked as a unit) | `walkConditionParts` | guard parts | emit's `collectParts` and round 1's `walkCondParts`/`walkGuard` |
| **Step placement**: `StepPoint` (`step_point` on a `while`: `.continue_expr` or `.after_body`) | `storage.decideStepPoint` (today `sema.stepReadsBinding`, a `Pending` entry) | `emitWhile` | `loopIteration` (replaces `spec.cond_binds and stepReadsBinding`) | only through `JumpDest` | three callers of one classifier; `Pending` budget 4 → 3 |
| **Jump targets**: `JumpDest` (`jump_dest` on each `break`/`continue`: the target construct and `.exit` / `.step` / `.head`) | one resolver in typecheck (lexical, by label), using `StepPoint`; its "not inside a loop" and "continue in the condition leaves a binding unbound" errors move there | `emitBreak`/`emitContinue` write the Zig label from the dest and the unit kind (`continue :L` from a guard part, `break :L_body` from the body, `break :L_step` from the step); the `targets[...].cont` mutation goes | `walkJump` files the exit under `breaks`, `step_conts`, or `conts` from the fact | which jumps join the step | emit's `jumpTarget` stack, ownership's `walkJump` lookup, typecheck's `hasContinue` rule |
| **Arm selection**: `match_block`, `matchGuarded`, `match_rereads` (existing) | `storage` | `emitMatch` | `walkMatch` | none, except `match_rereads`: a subject read again in the arms proves nothing | round 1's per-arm guard model |
| **Defer run points**: a `defer` runs at the exits of the block that holds it | the IR (the enclosing block); `syntax.deferBlock` | writes a Zig `defer` in that block (emit.zig:1305) | `runDefers` / `runDefersTo` at scope pops and exits | kills at that block's end; a jump kills every pending defer of the body | none existed; if emit ever moves a defer, this becomes a recorded fact |
| **Exits**: `return`, failing `e!` / `e?` leave the body | `syntax.leavesBody` (positive list), checked by typecheck's fallibility pass | `return` / `try` / `orelse return` | `exitTo(.propagate)`, `walkReturn` | the failing edge carries nothing | round 1's `st.clear()` after a jump node |
| **Hoisted temporaries**: storage facts (`new_value`, `base`, `index`, `hoists_args`, `receiver_hold`, `argument_hold`, `subject_hold`, `header_points`, statement slots) | the storage planner | `hiddenStorage` (requires the fact) | walks them in their order | **none**: they evaluate inside their unit, which emit asserts | none needed |

No pass derives any of these from syntax on its own: emit and ownership
call the same iterator or read the same recorded answer, and the proofs
walk reads the same. The proofs walk is **driven** by `eachUnit` and the
skeleton table above; a construct `eachUnit` does not list is walked as
one opaque unit (positive list: an unknown shape proves nothing).

## 4. Rules (unchanged from v1 except where marked)

- Subjects and bounds: v1 §2.1. Gens: G1–G4 (v1 §3.1), now applied only
  on a unit's exit edge (§2.2). Uses: v1 §3.2. Kills: v1 §4.2.
- **E1 (new): equality.** At the exit of a unit `n = s.len` (a binding
  or an assignment; `n` an own `Int`, `s` an own slice view), `eq(n, s)`
  holds, with G3's `nonneg(n)` and G4's `fits(s)`. It dies when `n` is
  written or `s` re-pointed. It is used only at gen time: adding
  `below(i, k, int(n))` with `eq(n, s)` also adds `below(i, k, len(s))`,
  and adding `eq(n, s)` converts each `below(_, _, int(n))` held. Each
  derived fact then has its own kill rule (it stays true while `i` and
  `s` stay, whatever `n` does later). About 40 lines and three unit
  tests.
- `match_rereads`: a subject that is read again proves nothing.
- `raw`: opaque.

## 5. The holes and their siblings, impossible by construction

1. **`continue` in a `while` condition.** The `continue` stands in a
   guard part `p`; the state it carries is `A(p)`, which holds no fact
   from `p` or any later part (those exist only on part exits it never
   takes). `JumpDest` says `.step` (with `.continue_expr`), so the step
   starts from a meet that includes `A(p)`. The step cannot see a guard
   the jump skipped. No `hasContinue` test exists to forget.
2. **`match` guard writes `i`.** All guards are in one selection unit;
   each arm body starts from its exit, `E − K(selection)`, and gets no
   fact from any guard. Arm order is never consulted.
3. **Target proven by the value's check.** G2 from the value is added
   only on the assignment unit's exit. Inside it, the value, base,
   indexes, place-finding, and compound op are all proved from `A(u)`,
   whichever runs first.
4. **Call-rooted target.** `pick(!t, !i)` is a step of the unit, so
   `!i ∈ K(u)`, and every fact about `i` is gone from `A(u)`: `s[i]` keeps
   its test in every build, for every value of `SetOrder`.

Siblings from setorder's class table and rev126 (each is inside one
unit, so the rule above covers it with no case of its own): method roots
`(!p).at(!i)[k] = …`; `?`/`!` roots `get(!h)?.f = …`; branch roots
`(!a if c else !b)[i] = …`; every compound op (`+=`, `-=`, `<<=`, `%=`);
an index that writes (`t[next(!i)] = s[i]`); a value that holds
statements (`x = match …` with arms that write); a receiver held before
arguments; named arguments reordered by `hoists_args`; `!`/`?` inside an
argument; a `!s.write(i, v)` whose `v` writes `i` (v1 hole 5); a closure
literal `|!i|` made inside the statement. The siblings between units:
the `while` step and `continue` from body, condition, and step (via
`JumpDest`); a `defer` that writes `i` (block-end kill; jumps kill all
pending); `for` and `if … as` subjects (their own units, before the
body); a jump out of an assignment's value (it carries `A(u)`).

New siblings this design closes that round 1 left open: a hoist that
moves an evaluation into an earlier unit (emit's containment assertion
fails); a subject node emitted in the selection and again in an arm
(`match_rereads`: unproven); a guard part that writes what it compares
(gens dropped when `K(p)` names them).

## 6. What it costs in proofs

| Shape | Round 1 | v2 |
|---|---|---|
| value-position guard: `x = s[i] if i < s.len else 0`, `ok = i < n and s[i] == c` | proven | **lost** |
| a check whose subject another part of the same statement writes | unproven (`walkAtomic`) | unproven |
| `t[i] = src[i]` with `c = t[i]` before | proven | proven |
| match arm bodies after guards | proven (patched rule) | same |
| step after a body `continue` | from the body's start less its writes | meet of real predecessors: same or better |
| `while i < n and src[i]`, `n = src.len` | unproven | **proven** (E1) |

Trig's measured patterns:

- **SWAR**, `i = 0; while i + 8 <= s.len: w = s.read[U64, .little](i);
  …; i += 8`: the guard part gives `below(i, 8, len s)`; the read is its
  own statement (both tests proven), `i += 8` its own (no_overflow).
  Unchanged from round 1; the guard's own `+` waits for round 2.
- **skip_space**'s `if c == SPACE and i + 8 <= s.len and
  s.read[U64](i) == SPACES`: three guard parts; part 2's `+` proven from
  the loop guard and `fits(s)`, part 3's read from part 2. Unchanged.
- **`while i < n and src[i]`** with `n = src.len` earlier: part 1 gives
  `below(i, 1, int n)`, E1 adds `below(i, 1, len src)`; part 2's
  `src[i]` upper is proven (lower when `nonneg(i)`). New.
- **SIMD** reads under `while i + 16 <= s.len`: same shape as SWAR; once
  `simd` lands, `numSize` answers `N * @size(E)` for `Simd[E, N]` (one
  case, its own twin tests). Not in this round.

None of the measured loops uses a value-position guard. Bringing those
back later means marking their operands as units in emit (the same
`enterUnit`), not a new walk rule.

## 7. Tests that catch divergence mechanically

1. **Emit's containment assertion** (always on in the compiler's debug
   build, so every suite, corpus, and matrix run checks it): when emit
   writes a check site, a write site, or a `hiddenStorage` evaluation,
   `unit_of(node)` must be the unit it is inside. This is the one
   remaining way the proofs could misjudge order, and it fails the
   compile, not a proof.
2. **The unit-order test** (replaces the walk-order test, which compared
   assignments only): over `test/behavior/{emit,proofs}` and the corpus,
   emit's trace (unit enters and exits, each jump's Zig label) and the
   proofs walk's trace must list the same units in the same nesting, and
   each jump's label must be the one its `JumpDest` and unit kind give.
   Every unit kind is compared, not only assignments.
3. **The differential run** (`test/run --proofs-diff`, fast gate on
   programs with a non-empty `--facts=proofs`; deep gate on all): each
   program in debug (every omitted test asserted), in `--release`, and
   in `--release` with `RIG_NO_PROOFS=1` (emit ignores `provenOf`). All
   three must print the same, exit the same, and panic with the same
   message; "a proven check failed" fails the test anywhere.
4. **The `unit.` grid** in `test/matrix.py`: statement form × write slot
   × use slot × guard.
   - FORMS and their slots: call statement `f(A, B)`; binding
     `x = A + B`; name `x = A`, `x += A`; element `t[A] = B`, `t[A] += B`;
     roots `pick(!t, A)[B] = C`, `(!w).at(A)[B] = C`, `get(!h, A)?.f[B] =
     C`, `(!a if A else !b)[B] = C`; `return A + B`; `while P1 and P2 : S`
     with body `B`; `if P1 and P2` / `else E`; `match A` with
     `1 if G1 => B1`, `_ if G2 => B2`; value forms `x = (A if c else B)`,
     `ok = A and B`, `x = match k` with block arms; inner block with
     `defer W`; `continue` placed in `P1`, `B`, and `S`.
   - WRITES of `i`: `bump(!i)`, a closure `|!i|` made and called, a
     nested `i += 1` (in statement-bearing slots), none.
   - USES: `s[i]`, `s.read[U32](i)`, `i + 1`, `!s.write[U32](i, v)`.
   - GUARDS: `if i < s.len` around, `while i < s.len` around, a check
     `c = s[i]` before.
   - `i` starts at `s.len - 1`, so the use is out of range exactly when
     the write runs first. Each cell: debug and `--release` agree and no
     proof assertion fires (that checks the order emit really used); and
     the dump marks the use exactly when the generator's own model says
     so: "proven iff a guard dominates the use's unit and no write of `i`
     is in that unit or on a unit path from the guard". That model is a
     third, independent statement of §2.2, and it does not depend on
     which order the run took, so it checks order-independence even in
     cells where the write happens to run second.
   - About 2,900 cells; the fast gate runs every form × slot pair with
     `bump(!i)`, use `s[i]`, guard `if` (about 600); the deep gate runs
     all, in debug and `--release`.
5. Kept from round 1: `test/behavior/proofs/` pairs (each hole a test,
   now with siblings), `facts_proofs.sh`, `emit_shapes.sh`, the `proof.`
   grid, and the rev126 probes in the corpus.

## 8. Soundness, in four lines

(1) A check in unit `u` runs after `u`'s entry and before its exit, with
only `u`'s code between (containment, asserted by emit); every write in
that code is in `K(u)`, so `A(u)` is true there. (2) Between units, each
edge the walk follows is one of the facts in §3, which emit and the
ownership checker read too; where the walk is coarser than an edge (the
join after a construct, the kill of every pending defer at a jump), it
removes more facts, never fewer. (3) Unseen writes are impossible in an
accepted module (v1 §4.1, Core sentences 4–9). (4) Each use is the
arithmetic of v1 §3.2 and §7.

## 9. Scope, effort, branches

**Scope:** round 1's coverage less value-position guards, plus E1. Out:
round 2's fixpoint and shift rule, false edges, `for` facts, owned
containers, SIMD widths.

**Restart, do not rebase.** `proofs` (PR #126) put its walk, its
set/match/step patches, and the parts worth keeping in one large commit
(07f7c8044), and setorder rewrote the emit paths it touches
(`openAssign`, compound stores). Close #126 with a pointer here.

1. **`loopfacts`** (after setorder merges; it touches `ownership.zig`,
   so one branch at a time): `StepPoint`, `JumpDest`, `eachGuardPart`,
   `syntax.leavesBody`. Emit, ownership, and typecheck read them; no
   emitted output changes (equiv: zero emit differences; oracle silent;
   matrix and corpus green). About 1.5 agent-days, plus review.
2. **`proofs2`**, from main after `loopfacts`: take from `proofs` by path
   (`git checkout proofs -- …`): `recordWrite` and the write sites
   (resolve, typecheck, sema), `Proven`/`provenOf`/`--facts=proofs`,
   emit's four sites, the runtime helpers and `rig.len`, the tests,
   docs. Keep `proofs.zig`'s subjects, facts, `Kills`, gens, and uses
   (about 450 lines); rewrite its walk on `eachUnit` (about 300 lines,
   smaller than round 1's, which had special cases per form). Add
   `unit_of`, emit's `enterUnit` and assertion (about 120), E1 (about
   40), the unit-order test, the differential runner, and the `unit.`
   grid (about 350 lines of Python). About 3 agent-days, plus the
   fast-gate review.

Total about 4.5 agent-days. If the `proofs2` review finds a soundness
hole in the unit rule itself, that is this feature's second round, and
it stops (AGENTS.md).

## 10. Owner decisions

1. Accept losing value-position guards (§6) for this round.
2. Emit's containment assertion on in every debug build of the compiler
   (a lookup per check, write, and hidden-storage site).
3. Land `loopfacts` as its own PR before `proofs2`.
4. INTERNALS "Proven checks" is rewritten as the unit desugaring
   (`unit u ==> check everything in u from E − K(u); add u's facts after
   it`); CORE's bullet and SPEC's sentences from v1 stand unchanged.
