# Speed: the process and the plan ("process")

My angle: change how the remaining steps are scheduled, reviewed and
gated, so that more of them run at once and fewer review cycles are
needed, while the soundness bar stays the same. The infrastructure
(cpuq, pup, splitting the corpus) is the "infra" agent's angle, and
measuring where the hours went is the "timeline" agent's. I use their
numbers only where the process depends on them.

**Sources:** ledger.md (the post-v0.2.0 entries), open-items.md,
rig-questions.md, step10/design.md, text-rule/*.md,
holding-rule/design.md, the review-*.md reports, logs/*/*.sum, GitHub
Actions run times, and the source of src/ (to map steps to
classifiers).

---

## 0. Summary

The remaining steps can be ordered as **two ownership lanes, plus
four lanes that touch no ownership code**. All of them meet at the
fold, followed by one scripted rename sweep. Combined with the process
changes below, the critical path drops from about **50 hours of
wall-clock time (5–7 calendar days, read as "1–2 weeks")** to about
**26–32 hours (2–3 calendar days)**. The bar stays the same:

- every ownership step gets its own independent review;
- the stop rule applies to each step separately;
- the full four gates still pass at every PR head;
- equivalence and the oracle are unchanged.

Ranked by payoff:

| # | Change | Saves (critical path) | Risk |
|---|---|---|---|
| 1 | **Pipeline and stack.** Start step N+1's implementation, on top of N's branch, when N enters review. Merge with `--auto`, and start the next step on an event, not when someone notices. | 10–14 h (about 2 h of idle time per round: B4a sat 1 h 24 min before its review, and #56's merge went unnoticed for 2 h 23 min) | Low: rebase churn if N's review changes its design. No soundness risk, because N+1 is reviewed on its own diff and regated on the merged base. |
| 2 | **Review runs alongside the gates.** The reviewer starts once a branch is built, the suite is green, and equivalence is classified, not after corpus and matrix. | 6–8 h (about 45 min per review round, over about 9 rounds) | Low: the final gates still pass before the PR. A gate failure after the review is a non-soundness fix. |
| 3 | **Probe ahead.** Use experiment builds (the step's rejection switched off, as B4a's reviewer did), generator axes for the step's new forms, and reviewer probes written while the implementer codes. | 5–12 h: about half of the round-2s, and possibly one stop | Medium: it could breed false confidence. The independent post-code review stays, and the stop rule counts rounds exactly as today (§2). |
| 4 | **Two ownership lanes** under a refined rule: one branch per classifier, with a combined-tree additivity gate (§1.3). | 8–9 h | Medium: an interaction outside the corpus and probe sets. Mitigated by the combined gate, both reviewers' probe sets, and the fuzzers. **Changing AGENTS.md needs the owner's approval.** |
| 5 | **Carry gate results over by equivalence.** Rerun only what changed since the last green gate; doc-only changes run `doc vocab links`. The full gates run once, at the PR head. | 3–5 h, plus freed CPU that the second lane needs | Low to medium: a missed dependency such as runtime.zig, the harness, or matrix programs. The carry-over conditions are explicit (§4.3). |
| 6 | **One decision sheet for the owner, now,** covering every open design question for the remaining steps. | 0–8 h for each decision that would otherwise block a lane overnight | None. |
| 7 | **Prepare the renames as a tested script during the other work**, and run them once at the end (`^T`, `List`, then the text rename after the fold). | About 2 agent-days moved off the critical path; the sweep itself takes about 2.5 h | Low: emit is byte-identical and the two-tree proof already exists. |
| 8 | **Write the docs in parallel,** in the final spelling, once the designs are frozen. | About 2 agent-days moved off the critical path | Low: the doc examples are run by the suite. |
| 9 | **No release PRs on the way to v0.3.0,** except a live-hole patch release, batched to at most one a day. A pre-existing fix rides in its feature's PR when that PR lands the same day. | About 50 min of CI for each skipped release, and lead attention | Low: live holes still ship promptly. |

---

## 1. Which steps truly conflict

### 1.1 Step → code and facts

The steps are from the brief's queue. B4b and `^T` are split as in §3.

| Step | Ownership / classification it changes | Other code | Emit change |
|---|---|---|---|
| seam 2b (`!` on temporaries; in progress) | `walkLend`, the write-lend temporary slots, `storeThroughLend`, `viewOnPath`, `isConstant` (typecheck) | `src/rig.zig` receiver-sigil rule (Nexus re-sync) | yes (write-lent temporary slots) |
| copies fact | **new fact "copies"**, replacing `copyable` / `isPlainData` / `copiedByReadView` / the C3 list (sema 22+4+3 sites, typecheck 10+4, ownership `readsThroughWriteView`) | `fill`, `[n of x]`, `\|+x\|` | yes (a plain struct copied out of `?P`) |
| B4b-1: lift the header-temporary rejection for place subjects | `rejectHeaderCopy` (typecheck), `copiesHeader`, `headerPoints`, `matchesInPlace` (storage) | emit header blocks | yes |
| B4b-2: lift arm-local payload views where matched in place | `arm_view` (sema, typecheck, ownership), generic `no_cell` (typecheck) | | small (82 classified flips, per the B4a report) |
| seam 3: one holder rule (Box, optional, generic `T`, handles) | `requireNoView` (ownership), `holdsMarkedView` / `mayHoldView`, `boxedType` | the Box forwarding of index, slice, `for`, `==` and operators, which is "every use reaches through the box" | small |
| Static (text stage 1) | new type tag; the literal's type in resolve and typecheck; joins (`unify`, `compatible`, `??`, branches); the Cell/Signal rule decided by type (ownership `walkCallBody`); `from static` | std/os.rig | **none** (byte-identical, per migration.md §3) |
| fold (text stage 2) | the `?Text` pointer view becomes bytes in sema, typecheck, ownership and emit, through about 15 emit sites; runtime `ReadView` | oracle `kinds.zig` / `lower.zig` | yes (at most 91 programs) |
| `^T` prerequisites | none, except the forwarding, which goes into seam 3 | resolve (rejecting stacked heap sigils), the `unbox` shadowing, reserving `^fun`, hints | none |
| sweep: `^T` + `List` + text rename | none | grammar (Nexus), resolve names, about 1,300 `.rig` files, hints | none (two-tree, byte-identical) |
| docs and final review | none | docs | none |

### 1.2 Pairwise interaction (for ownership steps that might overlap)

The ratings rest on the mechanisms each step touches, and on the
classes the reviews keep finding: stores, moves, temporaries, header
copies and constants.

| Pair | Shared territory | Interaction |
|---|---|---|
| seam 2b ∥ copies | a bare read through a write view (C3) of a write-lent temporary | **low** |
| seam 2b ∥ B4b | statement temporaries in headers (`match`/`for` over `!mk()…`) | **high**: same lane, serial |
| copies ∥ B4b | whether a plain-struct payload is a copy or a view, which decides where `arm_view` applies | **medium** |
| copies ∥ seam 3 | optionals or generics of views: "copies" says a read view copies; seam 3 says the holder carries its loan | **medium-high**: same lane, serial |
| B4b ∥ seam 3 | payload views through Box or generic `T`; B4b's generic `no_cell` lift | **medium** |
| B4b ∥ Static | payloads of `Static?` (`if os.env(..) as v`), which become plain copies | **low** |
| Static ∥ fold | the same text classification | serial (the fold needs Static, seam 3 and B4b) |

**Lanes that follow from this** (each lane is serial; across lanes
the pairs are low, or medium under a fixed merge order):

- **Lane A, temporaries and headers:** seam 2b → B4b-1 → B4b-2 (and
  E1, bare `break x`, if it is in v0.3.0).
- **Lane B, values and holders:** copies → seam 3 (+ Box forwarding)
  → Static.
- **Join:** the fold (needs B4b, seam 3 and Static), then the sweep,
  docs, final review, v0.3.0.

The pairs that would run at the same time are seam 2b ∥ copies (low),
B4b-1 ∥ seam 3 (medium), and B4b-2 ∥ Static (low). Merge order: B4b-1
lands before seam 3, because seam 3 must rebase onto the lift.

Moving Static before seam 3 is tempting, because today's `String`
already goes into generics and optionals. I don't recommend it.
semantics.md and the decided text plan both put Static after seam 3:
seam 3 makes the `?String` conversion an ordinary `?T`, and it covers
handles too.

### 1.3 Refining "one ownership branch at a time"

The rule exists because two unreviewed changes to the same mechanism
can interact in a way that neither review saw. It already bends in
practice. Hotfix 7, a large ownership change, ran beside round C and
merged after a combined-tree check (ledger 03:58–04:07). Steps 6 and
10's B2 ran together because B2 changed only emit.

**Proposed wording for AGENTS.md (owner approval needed):**

> At most one branch at a time changes a given fact or classifier
> (a `sema.Facts` table, or a classifier the `classify` check lists)
> or a given mechanism in `src/ownership.zig`. Two ownership branches
> may be open at once when:
> 1. each design lists the facts and mechanisms it changes and those
>    it reads, and neither changes what the other reads;
> 2. their merge order is fixed in advance;
> 3. the second merges only after a **combined-tree gate**.

The combined-tree gate, as a script (`r3/combined.sh A B`):

1. Merge both branches into a scratch worktree on top of main, and
   build it as C.
2. **Additivity check:** run `equiv.py B C` and `equiv.py A C`. They
   must differ only on A's and B's own equivalence-diff programs
   respectively, and on those C must print what A or B alone printed.
   Any program in both diff sets is an interaction candidate, listed
   and reviewed by hand.
3. Run both reviewers' probe sets and both generator axes on C,
   sanitizer-clean, with the oracle agreeing.
4. Run the full four gates on C.

**What this risks:**

- **An interaction no program exercises.** Additivity only covers the
  roughly 8,300 tracked programs, plus the probes and generated
  programs. The fuzzers keep running on C after the merge, and the
  final v0.3.0 review is the backstop.
- **A shared helper changes mid-branch** (for example `walkCallBody`,
  used by seam 3 and Static, which are in the same lane, so the case is
  rare). The rule says such a change must be announced. If it hits the
  other lane's list, the two branches serialize from then on.
- **Lead attention:** two ownership reviews in flight at once.

**Payoff:** 8–9 h on this plan. This is real, but smaller than items
1–3, which need no rule change. If the owner declines, take the
pipelined serial plan in §5.3; it loses about 9 h.

---

## 2. Fewer review cycles

**What the evidence says.** Of the last 11 reviewed rounds, 7 needed a
second review. Four of them narrowed or stopped part of the feature:

- step 3: escaping payload views;
- steps 4–5: header temporaries;
- step 10: C2, which led to rejecting every header with a temporary
  outright;
- seam 2: stopped.

In almost every case the Critical was **a pre-existing hole in a
shared mechanism that the new feature made reachable**: stores
absorbed only through a named receiver, a syntactic move-through-lend
check, header copies, statement temporaries, or constants.

Reviews themselves are fast. Seam 2's round 1 took 14 minutes to find
its Critical, and round 2 took 6. The time goes into the fix, the
regate, and the round that follows. Every seam 2 Critical was a short
program that fails under `RIG_SANITIZE`, and h03/h05/h07/h08,
z02 and z10 were already oracle `DIFF`s: "no oracle set contains
one", as the reviewer wrote.

| Change | How it works | Estimate |
|---|---|---|
| **Design-first review, with a class checklist** | A short design (or desugaring, as AGENTS already asks) answers one question for each recurring class: does this feature open a new path into store absorption, moves through a view, a statement temporary's lifetime, a header copy, constants, or Cell changes? A reviewer attacks the design for 20–30 minutes before any code. Findings at this stage are not soundness rounds, because no code exists yet. | Costs about 45 min, off the critical path (written during the previous step). It would have named seam 2's assignment store path and the syntactic move check up front. Saves about 1 round-2 in 3 (about 1.75 h each), and could have avoided the seam 2 stop (about 7 h, though the v0.2.2 fixes it produced were needed anyway). |
| **Experiment builds and generator axes, ahead of the step** | A prober agent builds the base with the step's rejection switched off, which is cheap. The B4a reviewer did exactly this with `experiment.py`, and it found B4b-C1 early. The agent also adds the step's new forms to `test/matrix.py`'s axes (`WRITE_TARGETS`, `STORE_FORMS`, `PAYLOAD_*`; seam 2 needed `(!mk())`, `wrap(!mk())` and `(!mk() if c else !t)` there). It runs everything under the sanitizer and the oracle. The holes it lists become the step's failing tests before implementation starts. | About 1 h of prober time, in parallel. It turns review findings into design inputs, and is the biggest lever on round count. |
| **Reviewer probes written up front** | The reviewer writes attack probes from the design while the implementer codes. When the code exists, the probes run in minutes. **Honest accounting:** a hole these probes find in the code counts as review round 1, exactly as today. The change saves time waiting for review, not rounds. | About 45 min per step, from overlapping the reviewer's writing with implementation. |
| **Continuous differential fuzzing** | A low-priority runner on pup or idle cores. It composes generator axes at random, plus the round's probes mutated, against main and each branch head. It flags any accepted program that fails under the sanitizer or that the oracle `DIFF`s, and files the findings to the implementer before review. Each oracle gap it trips (abstaining on "a sigil on an accessed object", for example, which hid seam 2's C2) goes to the oracle lane. | About 0.5 day to build. It catches what the axes cover; the savings are counted with the experiment builds. |
| **Batching reviews** | For **non-ownership** work (the lane C hints, `^T` prerequisites, oracle changes, docs): one review across several small branches. For **ownership** steps: no shared verdict, because a batched stop would stop both. Instead, the same reviewer reviews consecutive steps in a lane back to back, keeping their context and probe sets. A fresh reviewer takes the fold and the final review. | Saves about 3 review setups and 2 CI cycles in lane C; about 15 min of orientation per ownership review. |

The stop rule is unchanged: a second soundness round after the code
exists stops the feature. Design review and probing ahead make that
second round rarer. They don't redefine it.

---

## 3. Merge or split

- **copies + seam 3: keep them apart.** They do share optionals and
  generics of views, which is why they sit in the same lane, back to
  back. Merging saves one fixed overhead, about 1.5 h once pipelined,
  and doubles what a stop would take down. Copies is ready to start now
  (brief-copies.md); seam 3 is not.
- **seam 3 + Static: one design, two stacked branches.** semantics.md
  §6 asks for one branch. One design (the holder rule plus `Static`,
  D2 and D4, with one CORE edit) keeps them coherent. Two branches keep
  separate stop budgets: Static's risk is covariance (redteam finding
  2), and seam 3's is holders. The same reviewer takes both, back to
  back.
- **Static + fold: no.** Static's emit is byte-identical and cheap to
  prove. The fold is the riskiest emit change left (91 programs, in
  emit's weak spots). All three text reports say to review it alone.
  Split it as **F0** (oracle model first, the bounded fold set from the
  old compiler's facts, the comptime asserts that `T != rig.Text`; no
  behavior change, done in the oracle lane), then **F**.
- **B4b: split into B4b-1** (the header-temporary lift for place
  subjects: `rejectHeaderCopy` returns early when `headerPoints`)
  **and B4b-2** (arm-local payload views where matched in place, plus
  the 82 flips). E1, the bare `break x`, would be B4b-3, after the
  emitter's usage scan becomes a fact, if it is in v0.3.0. The header
  copies class has slipped three times, so a stop should not take the
  payload lift down with it. Each sub-step re-runs the review-b4a probes
  (an open item).
- **`^T`: split** the prerequisites from the spelling. These go in
  lane C, now, in today's `Box` spelling:
  - reject stacked heap sigils in resolve;
  - fix the `unbox` shadowing;
  - reserve `^fun`;
  - add the migration and dead-key hints.

  The forwarding ("every use reaches through the box") goes into
  seam 3. The spelling goes into the sweep.
- **The sweep: one branch for `^T`, `List` and the text rename**, as
  already planned, but with the scripts written and **rehearsed
  against main every night**. Each night, apply the scripts to a copy
  of main and run the two-tree comparison; `holding-rule/design/compare.py`
  folds into `test/equiv.py --two-tree`.
- **Renames first instead? No.** The text rename can't precede the
  fold: today's `?Text` and `String` would both be spelled `?String`
  until the fold unifies them. An early `^T`/`List` sweep would force
  the in-flight seam 2b and copies branches to rebase over about 1,300
  files. It would also make every later patch release from main a
  breaking release. The only benefit would be tests written once in
  the final spelling, and the script gives that at the end for free.

---

## 4. Agent orchestration

### 4.1 More agents within the 8-core budget

Implementers, reviewers and designers use almost no CPU. They build
once and run single programs. CPU goes to gates, equivalence and
fuzzing. So the limit on agents is the lead's attention and how heavy
the gates are, not the core count. The proposed steady state is 6–7
agents plus the lead:

| Lane | Agents | Heavy CPU |
|---|---|---|
| A (ownership) | 1 implementer, plus a reviewer when a step is in review | gates, about 2 cores, short with carry-over |
| B (ownership) | 1 implementer, plus a reviewer when a step is in review | gates, about 2 cores |
| P (probe ahead) | 1 prober / designer, who writes the next step's design, experiment build, axes and up-front probes | matrix runs of new axes, about 1–2 cores |
| C (no ownership) | 1 implementer: rename tooling, `^T` prerequisites, open-item hints, M2 (closure into `!fun`), the Nexus sync batch | light |
| O (oracle and fuzz) | 1 agent: close the oracle gaps from open-items (p26, p36, z01/z07, `<(!s if c else !t).o`, h06, sigil on an accessed object), F0, the fuzz runner | the fuzzer at low priority, ideally on pup |
| D (docs) | 1 agent once seam 3 + Static's design is frozen | light |

Give the lead a one-line status board (ledger RESUME HERE) and a
fixed brief template: design, class checklist, axes, merge order. Put
the combined-tree gate in a script, so a merge needs a decision, not
manual steps.

### 4.2 No idle waits

- **A trigger starts the next step,** not the lead noticing it. When
  step N enters review, start N+1's implementation, stacked on N.
  Keep N+2's design and experiment probing running in lane P. When
  N's PR is set to `--auto`, a `Monitor` (or `gh pr checks --watch`)
  wakes the lead when it merges. Missing that merge cost 2 h 23 min
  on #56.
- **The reviewer starts at "built + suite + equivalence classified".**
  Corpus, matrix and unit run in parallel. Seam 2's round 1 spent
  05:06–05:54 in gates and equivalence before its 14-minute review.
- **Settle the owner's questions in one sitting now** (§6), so no lane
  waits overnight on "awaiting the user's confirmation".

### 4.3 Skip gate reruns that would repeat a result

A gate result depends on the compiler's outputs over the program set,
`src/runtime.zig`, the test harness, and the programs themselves.
Rerun only what changed since the last green gate:

| Changed since the last green gate | Rerun |
|---|---|
| prose only (`*.md`, no `rig` block) | `./test/run vocab` plus the link check (seconds) |
| `rig` blocks in docs | `./test/run doc vocab` (about 30 s) |
| `test/oracle/` only | `./test/run oracle`, `matrix.py --oracle` |
| tests or probes added or changed, no `src/` change | those files, plus `./test/run` |
| `src/` changed, `runtime.zig` and harness unchanged | `equiv.py LAST_GATED NEW`, extended to the kept matrix programs. Zero diffs: corpus and matrix carry over, and only the suite and unit tests rerun. Diffs: the suite, unit tests, and only the corpus and matrix programs whose check or emit differs. |
| `runtime.zig`, `test/run`, `matrix.py` or the Zig version changed | everything |

**At every PR head, all four gates plus `oracle doc vocab` run in
full** (on pup or in CI if infra moves them there). The merge bar
stays as it is; only the reruns in between get cheaper.

---

## 5. The new plan to v0.3.0

### 5.1 Timeline

Times are hours of wall-clock time from T0 (now: seam 2b in progress).
Each ownership step is costed with the process above at about 3.5–4.5 h:

- implementation: 1.5–2 h (B4a took about 1 h, round C 1.5 h, seam 2
  1.7 h);
- quick gates: 0.5 h, with the review running alongside;
- a fix round, about 60% of the time: about 1.3 h;
- the PR and CI: off the critical path.

| Lane | Step | Starts | Ends |
|---|---|---|---|
| A | seam 2b: finish, review | T0 | T0+4 |
| A | B4b-1, header lift (stacked on seam 2b) | T0+3 | T0+7.5 |
| A | B4b-2, payload lift | T0+7 | T0+11 |
| B | copies (starts now; merges after seam 2b, combined gate) | T0 | T0+4.5 |
| B | seam 3 + Box forwarding (merges after B4b-1, combined gate) | T0+4 | T0+9 |
| B | Static (stacked; same reviewer) | T0+8.5 | T0+12.5 |
| P | experiment builds, axes and up-front probes: copies and B4b now; seam 3 and Static by T0+3; the fold by T0+8 | T0 | T0+10 |
| C | rename scripts, two-tree equivalence, `^T` prerequisites, hints, M2, Nexus batch; one batched review | T0 | T0+10 |
| O | oracle gaps, F0, the fuzz runner | T0 | T0+8, then continuous |
| D | docs in the final spelling (CORE, SPEC, WELCOME, SYNTAX, STD), with `pending` blocks where needed | T0+6 | T0+16 |
| **join** | **the fold (F), on top of both lanes; fresh reviewer** | T0+13 | T0+18 (+3 if a round 2) |
| | sweep: run the scripts, two-tree proof, hints review, full gates | T0+18 | T0+20.5 |
| | docs final pass, then the final review by three parallel reviewers (soundness, teaching and docs, migration), then fixes | T0+20.5 | T0+25 |
| | v0.3.0 PR, CI, tag, notes | T0+25 | T0+26 |

### 5.2 Critical path

The critical path runs: copies → seam 3 → Static → fold → sweep →
final review → release. That is about **26 h**, or **about 31 h** with
one round-2 or stop on it. Lane A has about 1.5 h of slack. The
**current serial plan**, at about 5 h per round as observed (round C
5.1 h, B4a 4.8 h, hotfix 7 about 4 h, seam 2 7 h to its stop), with
its idle gaps, two stops, and the renames, docs and final review done
in sequence, comes to about **50 h**. Owner availability, pauses and
reboots stretch that to 5–7 calendar days. The new plan fits in **2–3
calendar days** under the same interruptions.

### 5.3 Fallback if the rule stays as it is

Keep every change except item 4, and run A and B as one serial chain:
seam 2b → copies → B4b-1 → B4b-2 → seam 3 → Static → fold, with each
stacked on the previous one. The critical path is about **35–40 h
(3–4 days)**.

### 5.4 Checkpoints

These are kept from today:

- open-items.md is checked before each merge;
- equivalence is classified with zero accepted-to-rejected programs,
  unless listed;
- the oracle is a hard gate;
- each step has its own independent review and its own stop rule;
- a full gate runs at the PR head.

One checkpoint is new: the combined-tree gate at every cross-lane
merge.

---

## 6. Owner decisions to batch now (one sitting, about 1 h)

These are taken from open-items.md, rig-questions.md and the
holding-rule and text-rule reports. Each would otherwise block a lane
mid-flight.

1. **Seam 2:** confirm the parse change (`!f(x).g()` lends `f(x)`).
   Decide `?mkc()` (a read lend of a temporary that holds a Cell):
   lift its rejection like `!mkc()`, or keep it.
2. **B4b:** decide the `as` rejection over a Cell holder. Decide
   whether to accept the two Low forms from review-b4a-round2 (a
   payload view leaving `match w.r?`, and returning from `match r`
   after `if w.r as r`).
3. **Seam 3 + Static:** the one holder rule's CORE wording; `^?T` /
   `Box[?T]` written explicitly (redteam: reject a written `^?T`);
   `Static`'s name, and its conversion sites (reads only); D2 (`?(?T)`
   = `?T`) and D4 (17 swap programs rejected).
4. **`^T`:** how unboxing is spelled; the one rule for what reaches
   through `^`; how long `Box` stays reserved with a hint.
5. **The fold:** D3 (`+s` allocates); the `(?String)?` spelling.
6. **Is E1 (bare `break x`) in v0.3.0?** Are field-precise loans after
   it? (redteam finding 8 wanted them before the fold.)
7. **Process:** approve or decline §1.3 (two ownership lanes), and §4.3
   (gate carry-over, with the full gates at the PR head).

---

## 7. Risks, and how the bar is kept

| Change | What could go wrong | What keeps the bar |
|---|---|---|
| Stacking and pipelining | N's review changes N's design, so N+1 is rebuilt | N+1 is reviewed on its own diff after rebasing; gates run on the merged base; the stop rule applies per step |
| Review during the gates | A gate failure appears after the review is written | Gate failures are usually Zig or test plumbing; any `src/` fix after the review goes back to the reviewer as a targeted check |
| Probing ahead | Implementers fit the probes, and reviewers trust them | A fresh adversarial review still follows every ownership step; up-front probe failures count as round 1 |
| Two lanes | An unseen interaction between lanes | The additivity gate, both probe sets, both axes, and continuous fuzzing on the combined tree; a fixed merge order; the owner's approval |
| Gate carry-over | A dependency is missed, so a stale green | Explicit triggers (runtime, harness, Zig); equivalence extended to matrix programs; full gates at every PR head |
| Fewer release PRs | A live hole waits longer | A live hole still gets a patch release within a day |
| Sweep at the end | Script bugs | The two-tree equivalence (byte-identical emit, mapped diagnostics), rehearsed nightly; a planted diff proves the normaliser reports it |

Nothing here relaxes AGENTS' rules 1–7, the sanitizer, the oracle,
equivalence, or independent review. The one AGENTS change proposed, the
lane rule in §1.3, is optional and needs the owner's approval.
