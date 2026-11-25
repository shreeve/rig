# Rebuilding Rig in place

How Rig is rebuilt into a cleaner, smaller, equally fast or faster system
without starting from an empty repository. This page holds the rules
and the process. The target design it builds toward is
[architecture.md](architecture.md), written in phase B. The running
state is the rebuild ledger,
[docs/history/records/rebuild/ledger.md](../history/records/rebuild/ledger.md).
Every agent working on the rebuild reads this page first, then
AGENTS.md, then the ledger's newest entry.

## What the rebuild is

Rig works: it checks and compiles Trig, a full TypeScript checker,
which beats tsrs in time and memory. Rig was built by exploring, and
its layout shows the order things were learned in rather than the
order they belong in. The rebuild keeps everything Rig does and
rebuilds how it does it: pass by pass, in this repository, on `main`,
with every step proven and Trig working at every commit.

It is not:

- a new repository, or a second Rig beside the first;
- a feature round: no new language feature, std module, or option
  lands as part of a rebuild step;
- a rewrite for taste: a step lands because it makes Rig smaller,
  clearer, more correct, or faster, and shows it.

## The North Star

These bind every step, and nothing in this page loosens them:

1. AGENTS.md's six guarantees: accept means correct; safe code cannot
   corrupt memory; effects stay visible; one classifier per fact;
   ownership features fit the Core; docs claim only what runs.
2. Trig never breaks. Every commit on `main` builds Trig, and Trig's
   output stays byte-identical to tsc's.
3. Nothing gets slower. No guarded row, race cell sum, or `rig check`
   time moves past its bar against `revamp-base`, the tag every step
   is measured against.

## The documents

| Document | Holds | Changes when |
|---|---|---|
| `docs/internals/rebuild.md` (this page) | rules, phases, the step recipe | a rule changes, with the owner's approval |
| `docs/internals/architecture.md` | the target: passes, data model, shared machinery, line budgets | phase B writes it; the owner approves each revision |
| `docs/history/records/rebuild/ledger.md` | state: steps done, in flight, next; the line scoreboard; decisions | every step |
| `docs/history/records/2026-11/revamp-base/` | the baseline and the commands that reproduce it | never; a new baseline is a new record |

## Phases

### A. Baseline

`revamp-base` (tag, commit 645996606) is the before state. Its record
holds, each with its commands and its run-to-run spread:

- correctness: the core and full suites, doc examples, the oracle's
  rejections, coverage, and differences, Trig's and loco's light gates;
- the emit snapshot: every module's Zig for examples, bench programs,
  an all-std program, and Trig, with a sha256 manifest;
  `tools/emit-diff revamp-base` compares against it;
- compiler speed: `bench/check/guard.py`, `rig check --time` on Trig
  (per pass, peak memory), `zig build` time, the size of `bin/rig`,
  and Zig's build time for Trig's emitted code;
- generated code: the json, hash, text, and print guards; the tasks,
  actors, net, and http benches, on the Mac and pup;
- the headline: Trig's race board on pup against tsrs (16 projects,
  1 to 8 checkers, wall time and peak memory), Trig pinned as
  `trig-revamp-base`;
- structure: lines by language for the compiler, runtime, std, tests,
  and docs; the largest files; the passes.

### B. Re-imagine

A pause before any code: knowing what Rig is now, design what it
should have been. Three experts on the top model each read the whole
compiler, the runtime's interface to it, INTERNALS, CORE, and the
records' measured negatives, then each write, alone, the design they
would build from a blank page: the passes and their order, the IR and
what each pass hands the next, which facts exist and who records them,
the machinery shared across passes, and a line budget per pass. They
must not read each other's drafts until all three are written.

The lead merges the three into `architecture.md`, where each part
says:

- the ideal, and why;
- today's code, and its gap to the ideal;
- the path from one to the other as a series of steps, each either an
  identity step or a behaviour step (below);
- what was considered and rejected, with the reason.

Questions the design answers at least: does sema need to run twice;
can the facts table, storage, and proofs share one recorder; where do
typecheck's 26,000 lines split; what emit shares with a future LLVM
backend through a lowered IR; which runtime and compiler code can be
shared (the compiler's maps already run in Zig, as `Map` and `HashMap`
do); what the measured negatives in the records rule out.

The owner approves `architecture.md` before phase C.

### C. Pilot

One hard step, the first one `architecture.md` names (by default,
typecheck's split), run through the full recipe. The pilot measures
the process as well as the code: how long a step takes, how often its
proof fails, how many lines it removes. If the pilot misses its line
budget or its proof, the process is fixed before phase D, not after.

### D. Rebuild

The steps of `architecture.md`, in its order, one at a time per set
of files. At most three agents work at once, each on files no other
agent touches.

### E. Behaviour and speed

The behaviour steps the rebuild turned up, such as fixes, simplifications
that change output, and speed work that the cleaner code makes possible,
each measured against `revamp-base`. The lowered IR that the LLVM
backend needs belongs here, if `architecture.md` puts it here.

### F. Close

The docs revamp, the CHANGELOG, HANDOFF, and the release. A final
board against `revamp-base`, recorded.

## Two kinds of step

**An identity step** changes how Rig is built, not what it does. Its
proof is that `tools/emit-diff revamp-base` (or against the previous
step's commit) prints `identical` for every program, and every suite
is green. Identical emitted Zig means identical programs, so an
identity step needs no timing run: only the compiler's own speed is
checked (`bench/check/guard.py`).

**A behaviour step** changes what Rig emits, accepts, rejects, or
prints. Its proof is the usual one: a failing case first, the gates,
and the guards or a race for anything that could move speed.

**No step is both.** A step that restructures code and changes output
is split in two, and the behaviour half lands as its own change.

### When the old code was wrong

Byte-identical output is a proof, not a goal. The old code had bugs,
and a rebuilt pass is better when it does not repeat them. The rule is
**no unexplained difference**:

1. A rebuilt pass that finds an old bug does not copy it and does not
   fix it silently. The finding becomes a case that fails on the old
   code.
2. If the fix is small in the old code, it lands on `main` first, as
   its own behaviour step. The rebuild then reproduces the fixed
   output, and its step is again an identity step.
3. If the fix is natural only in the new code, the step lands with an
   emit diff, and its PR classifies every differing hunk:

   | Kind | What the PR shows |
   |---|---|
   | Bug fixed | the case that failed before and passes now |
   | Better output | why it is better, and its measurement: guards, or a race for speed |
   | Neutral (order, names) | why it cannot change behaviour, and the guards unmoved |

   A hunk that fits no row blocks the step.
4. A difference in what Rig accepts or rejects follows AGENTS.md: a
   program a release accepted and the rebuild rejects goes in the
   release notes, and Trig gets a note and a migration script first.

## Less code

Rewrites grow unless something pushes back. In this one, lines are a
gate.

- **Budgets.** `architecture.md` gives each pass a line budget, set
  from the three designs, not from today's size. A step's budget counts
  only the lines that step itself can delete: a step that adds a table
  says which later step its readers' savings land in. The ledger keeps a
  scoreboard: lines per pass at `revamp-base`, now, and the budget.
- **Every PR reports** net lines changed, split into compiler, runtime,
  and std source on one side and tests and docs on the other. Source
  lines are expected to fall. A step that adds net source lines says
  why in its PR, and the reviewer can refuse the reason.
- **The deletion review.** Every step gets one reviewer agent whose
  only question is what in the touched code could be deleted, merged,
  or shared, and which reads the rest of the compiler for code that
  does the same thing. Its findings are fixed in the step or become the
  next step.
- **Two copies are a finding.** Two places that decide one fact, or two
  helpers that do one thing, become one. That is AGENTS.md's "one
  classifier per fact", applied to the compiler's own code.
- **No new knobs.** No options, switches, compatibility shims, or
  layers kept "for later". A switch used to measure is removed in the
  same step, or its PR is a draft.
- **Dissolve, don't patch** (docs/design/mantras.md). A step that needs
  a special case to keep its proof passing is redesigned, not
  patched.

## The step recipe

1. **Claim it** in the ledger: the step, its kind, its files, its line
   budget, the agent.
2. **Worktree.** `wt new NAME`. One session per worktree and branch.
3. **Read** the pass, its INTERNALS section, and its tests. Run
   `tools/basecheck` against the base.
4. **For a behaviour step, a failing case first.**
5. **Build the step.** Keep the parser generated (edit `rig.grammar`),
   rebuild after any std or runtime edit, and slice source only through
   `diag.textBetween` or `diag.textOf`.
6. **Prove it:**
   - `tools/emit-diff BASE`: `identical` for an identity step, every
     hunk classified for a behaviour step;
   - the core suite, `tools/heavy --class correctness swarm test/rig.rip -w 4 -q`,
     green, with the oracle silent and never weakened;
   - `bench/check/guard.py` within 2% of its baseline in instructions;
   - for a compiler, runtime, or std change: Trig's and loco's light
     gates GREEN; for a behaviour step that changes emitted code, the
     json, hash, and text guards within 2%;
   - for a behaviour step meant to move speed: a race in a pup board
     slot, through the slot queue.
7. **The deletion review,** and its findings fixed or ledgered.
8. **The PR:** a draft from the start, its body a checklist of this
   recipe, with the line report and, for a behaviour step, the hunk
   table. `gh pr ready` when every box is ticked.
9. **Merge** on the usual authority (AGENTS.md "Only the owner
   approves"; the standing merge authority for green, measured,
   no-slower changes). Update the ledger and HANDOFF. `wt done NAME`.

## Stop rules

- A step whose proof fails twice for the same reason stops, and the
  design in `architecture.md` is revisited.
- A second round of soundness fixes on one piece stops that piece for
  redesign (docs/design/mantras.md).
- A regression on `main`, in correctness or speed, is bisected and
  fixed before anything else lands.
- If the pilot shows the process cannot hold identity at a reasonable
  pace, the rebuild stops at the pilot and the owner decides.

## Speed

The bars of AGENTS.md hold: Trig's bar (more than 1.5% faster, or at
least 1% fewer instructions on one checker), the 2% guards, timing
only on the Mac through `tools/mac-claim` and on pup in a board slot.
The records list what was measured and failed; a step does not redo
one without new evidence (docs/history/records/INDEX.md).

Identity steps keep the generated code's speed by construction. Gains
come from behaviour steps, and the rebuild aims to make those easier:
fewer places to change, one recorder of facts, and a lowered IR that a
second backend can use.

## Agents

- At most three agents at once; the top model for design, the pilot,
  and any ownership or soundness step; Sonnet only for mechanical work.
- Each brief names the step, its files, its kind, its proof, and the
  traps: `src/parser.zig` is generated; std and the runtime are
  embedded in `bin/rig`; docs are tests; the oracle is never weakened;
  emit decides nothing that the checkers did not record.
- Reports run to at most 300 words, with the details in the record or
  ledger.
- Agents never merge, push to another session's branch, or open a pup
  slot themselves.

## Using `/codebase-revamp`

The skill gives the frame: recon, baseline, audit, triage, and ledger.
On Rig, this page overrides it where they differ:

- the North Star above, AGENTS.md's process, and the owner's approval
  bind every step; the skill's freedom to drop any rule but the North
  Star applies to rules inside the code, not to AGENTS.md;
- work lands as small PRs on `main`, not on one long `revamp` branch;
- the ledger is the tracked one above, not one inside `.git`;
- phase B replaces the skill's audit phase as the source of the plan;
  auditors run inside steps, as the deletion review and as lenses on
  security, completeness, and toolchain currency.

## Decisions for the owner

These are asked before or during the rebuild, each with a default:

1. Approve this page. Default: approve, with the rebuild starting once
   the milestone is called.
2. Approve `architecture.md` after phase B. Default: approve, or ask
   for a revision.
3. The pilot step. Default: typecheck's split.
4. Whether the compiler is ever written in Rig itself (self-hosting).
   Default: out of scope; sharing Zig code between the compiler and
   the runtime is in scope.
