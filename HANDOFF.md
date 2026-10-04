# HANDOFF: where Rig stands, and what comes next

This is the resume point for anyone, human or agent, picking up Rig
work. Read it first, then [AGENTS.md](AGENTS.md) (the rules) and
[docs/CORE.md](docs/CORE.md) (the ownership model every rule derives
from).

## Current state

- **Release:** `v0.1.2` is the latest release (Zig 0.17.0, Nexus
  2.0.0), with CI green on Linux and macOS. It fixes a use-after-free
  through a view stored in a borrowed parameter; `v0.1.1` fixed three
  use-after-free classes found in `v0.1.0`. The version string in `build.zig` changes
  only when a release is cut.
- **Branches:** `main` is the one long-lived branch. Work lands through
  short-lived branches and pull requests; the `revamp` branch carries the
  consolidation below.
  Every change reaches `main` through a pull request: the ruleset on
  `main` requires `test (ubuntu-latest)` and `test (macos-latest)`, and
  blocks force pushes and deletion.
- **Toolchain:** Zig 0.17.0, pinned in `mise.toml`. Nexus 2.0.0, only
  to regenerate the parser.
  - [docs/zig-0.17.md](docs/zig-0.17.md) covers every Zig API Rig uses.
  - The cross-project Zig guide is `~/Data/Code/zig/docs/ZIG-0.17.md`.
- **Health:**

  | Check | Result |
  |---|---|
  | `./test/run` | 2,251 passed, 8 pending (planned Core rules) |
  | Corpus | 4,273 of 4,273 |
  | `test/matrix.py` | 910 programs, 0 failed |
  | `zig build test` | 113 pass, 1 skip |

  `test/known/` holds no open bugs. Every bug the past audits found on
  `main` is fixed.

## The feature freeze

Rig is in a feature freeze while its compiler is consolidated. The
North Star (AGENTS.md) and `docs/CORE.md` are fixed points.

**In scope:**

- **Consolidation:** restructuring the compiler so the Core's rules come
  from its structure. The plan is below.
- **Building the Core's planned rules.** These are already decided: each
  is marked *(planned)* in `docs/CORE.md` and shown by a `rig pending`
  example. Building one turns its pending example into an ordinary one,
  in the same change.
- **Bug fixes, docs, tests, and speed.**

**Out of scope:**

- **New language features or library modules** not in the Core.
  Examples: io, fs, Map/Set, traits, threads.
- **A change to a rule.** It goes through `docs/CORE.md` first, as its
  own reviewed change, and needs the user's agreement. Ask the "Rig"
  session (below).

**The test for whether something is consolidation:** it either changes
no accepted program's meaning and only turns wrong rejections into
acceptances, or it is a planned Core rule.

## The consolidation plan

The evidence is in `.git/revamp/reports/` (local, not in git):

- `seams/root-cause.md`: why soundness bugs kept appearing;
- `core-audit/*.md`: six audits of the code against the Core, and
  `WORK-ORDER.md`.

The root cause, in one line: about 90% of past soundness bugs traced to
three structural weak spots. The steps below remove them, in order. One
branch at a time touches `src/ownership.zig` or typecheck's
classification. Each step lands as its own reviewed change with every
gate green.

1. **Type facts.** One fact per question, replacing the proxies
   (`owningKind`, `maybeDropGlue`, the five disagreeing "copyable"
   rules):
   - copyable;
   - unique;
   - needs cleanup;
   - may hold a loan;
   - cloneable;
   - how a read view is represented.

   Build `unique`: `struct T unique` replaces `std/random.rig`'s empty
   `drop` on `Random`. (A type holding a `Cell` becomes unique in step
   3, which it needs.)

   This also fixes false rejections such as `<p` on a plain match
   payload. See `core-audit/kinds.md`.
2. **One classifier and one exit.**
   - **`handsOver`:** one fact per expression — a place, a made value,
     a lend, a view, branches, or a jump — decided by a positive list.
     It replaces `isPlaceExpr`, `makesValue`, emit's `isPlace`, and the
     rest, which disagree in 12 places (`core-audit/reads.md`).
   - **`exitTo`:** the only way a path ends. It runs defers, reports
     every loan it would drop, and rewinds when the path goes on. It
     replaces about 20 hand-written join and exit sites
     (`core-audit/loans.md`).
3. **Reads and lends** (Core sentence 1 and §4).
   - A bare name only reads, so the `?` that is required today in some
     positions becomes optional.
   - One `lendsAs` table replaces six conversions:
     - `sort.sort(!v)` works on a Vec;
     - Box and `*T` members are readable;
     - `?Shape` serves a `Box[Shape]` and a `*Shape`.

   **Inherited from step 1.** Step 1 stopped its in-place views of loop
   elements and read-match payloads after a second round of soundness
   findings (`.git/revamp/r3/review-step1-round2.md`,
   `step1-carveout.md`). Each item and its next action:
   - **Header subjects, then reads in place.** A loop or match binding
     holds a copy of each element or payload today. Classify the
     subject of `for`, `match`, `if … as`, and `while … as` once, with
     step 2's `handsOver` (a place or a lend is viewed; a made value is
     taken, held in a `var`; a branch hands over per leaf), then bind
     every type's element or payload by that classification. Next:
     specify it as a desugaring in INTERNALS before any code.
   - **A type holding a `Cell` is unique** (CORE §1, *planned*). It
     becomes unique once loop and match bindings view or take it, so
     no binding copies it. Next: restore commit `2cab5408`'s rule, the
     seven programs it rewrote with `<`, and its three reject tests,
     and promote the pending example in CORE §1.
   - **A by-value parameter's Cell is a place** (step 1's item 1.7).
     `c.hits.set(v)` on `c: Counter` is rejected today while
     `c.hit()` is accepted. Next: make a parameter root a Cell place
     for a value that moves, in `requireCellPlace`, and state one rule
     in SPEC §10.
   - **The acceptance set.** The round-1 and round-2 review probes
     (`.git/revamp/r3/probes/review-step1/`, `round2/q*.rig`) are the
     tests the redesign must pass: each runs sanitizer-clean with the
     meaning the Core gives it, or is rejected. Next: copy them into
     `test/corpus/` when step 3 starts.
4. **Containers hold anything** (Core §5). Remove about six early
   rejections so `Vec[Text]`, `Vec[Vec[Int]]`, and records that own text
   work, and `?v[i]`, `!v[i]`, and `<v[i]` lend or take elements.
   Assigning to a borrow place gets one rule: a view re-points, a value
   writes through. See `core-audit/containers.md`.
5. **The remaining planned rules:**
   - an error value meets `T!` only as `return`'s operand;
   - `(!s).insert(k)` wherever a write call's `Bool` is used;
   - `const x = e` replaces `x =! e`;
   - returning an owner, ending a block with one, or `break x` moves it;
   - `+x` for Vec, Box, and owning structs.
6. **Whole-program views and loan origins.**
   - Per-function "must live for the whole program" parameter summaries,
     so a generic `Holder[String]` with literals works.
   - The signature-based refinement of which arguments a result's loans
     come from.
7. **The vocabulary pass.** One focused change rewrites every remaining
   "borrow" — in diagnostics, test expectations, comments, internal
   names (`borrow_read` and friends), and every document — into lend,
   view, and loan, by meaning:
   - the act is a lend: "cannot lend `v` to write";
   - the value is a view;
   - the record is a loan: "while a read loan is live".

   Plan it with reviewers from several viewpoints: a programmer, a
   newcomer, a documenter, the compiler, and a language designer. Merge
   their findings into one terminology guide, then edit by it. A lint
   fails on any stray "borrow". It changes no behavior.
8. **The SPEC rewrite,** around the Core, in the new vocabulary. About
   65 exception lists become derivations, for about 20% less text.
   `core-audit/docs.md` maps it section by section.
9. **Speed.** Two quadratic generic checks take most of `rig check`'s
   time on large programs: `expandInstantiations` and
   `checkInstanceSizes` via `sema.usesParams`. Index the generic frames
   by their declaration.
10. **Decide on lowering.** A pre-check lowering pass would let the
    checker and the emitter see one program (`core-audit/emit.md`).
    Decide only after steps 1–4, from the bug rate that remains.

**Invariants every step keeps:**

- the rules in AGENTS.md "How we build";
- accept means correct;
- sanitizer-clean;
- no accepted program changes meaning except by a planned Core rule;
- every pending example that starts working is promoted in the same
  change.

## Weak spots

Reviewers keep finding problems in these areas. Change them carefully,
and run the corpus after:

- **Statement temporaries** (Core §3). Two soundness slips since the
  redesign, both caught by the corpus before merging: a view of a
  temporary's part, and a match subject's loan across guards. AGENTS.md
  says a third slip stops the feature for redesign.
- **String views of a `Text`:** `viewLoans`, `mayOwnText`, and String
  values in Cells, generics, and closures.
- **Evaluation order versus what is emitted:** call arguments, `print`
  and `Text(...)` arguments, and assignment targets. All are fixed today,
  and all are the "checker models a different program than emit"
  class.
- **`defer`/`errdefer` at exits:** `Exit.goesOn()`.
- **Owning values behind `Cell`, `Box`, and `*T`, and generic
  instances.**
- **Copies of a type holding a `Cell`.** Such a type copies, so a copy
  forks the state the `Cell` holds: `b = a`, `k = a[0]`, and `k = <a[0]`
  each make an independent `Cell`. It is not a memory hole; step 3's
  rule that a `Cell` holder is unique closes it.

## The gates

The machine is shared. Check `sysctl -n vm.loadavg` before a full run,
and wait while the 1-minute load is above about 12.

```bash
./test/run -j 2                               # full suite; the sanitizer is on by default
./test/run -j 2 corpus                        # all 4,273 probes, about 20 min; has caught real use-after-frees
python3 test/matrix.py -j 2                   # form x context x type programs
zig build test --cache-dir "$(mktemp -d)"     # unit tests; a plain rerun replays cached results
```

- Rerun a timeout failure alone before trusting it: under load,
  timeouts are often spurious.
- **IR equivalence** proves that a refactor changed nothing. Dump
  `bin/rig check --facts` for every `.rig` file and doc example with the
  old and the new compiler, and diff the dumps. Also diff the
  diagnostics of every reject test.

## Conventions

- **Vocabulary:** *you lend a view; the compiler remembers the loan.*
  - lend: the act, written on the owner's side;
  - view: the value handed over;
  - loan: the owner-side record.

  Add no new "borrow" for the act. Step 7 removes the rest.
- **Commits:** short, imperative, with no AI attribution.
- **Comments:** timeless, describing the code as it is. History belongs
  in git.
- **The parser:** never edit `src/parser.zig` by hand. Edit
  `rig.grammar`, then run `zig build parser` with Nexus 2.0.0.
  `rig.grammar`, `src/rig.zig`, and `src/diag.zig` are mirrored
  byte-for-byte in Nexus's `test/rig`, so a change to them needs a Nexus
  re-sync.
- **Builtins:** Rig's raw `@` builtins track Zig's names exactly
  (`@fromBackingInt`, `@trunc`). The old names are rejected with a hint.
- **Merging:** after a branch merges, delete it locally and on GitHub,
  and remove its worktree. `main` stays the only branch.

## Who to ask

For design intent, Core questions, or whether something is a new feature
or consolidation, send a message to the **"Rig"** session. Its work log
is `.git/revamp/ledger.md` (local); this file states its current facts.
