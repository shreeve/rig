# HANDOFF: where Rig stands, and what comes next

This is the resume point for anyone, human or agent, picking up Rig
work. Read it first, then [AGENTS.md](AGENTS.md) (the rules) and
[docs/CORE.md](docs/CORE.md) (the ownership model every rule derives
from).

## Current state

- **Release:** `v0.2.0` is the latest release (Zig 0.17.0, Nexus
  2.0.0), with CI green on Linux and macOS. It is the consolidation
  release described below; its release notes list each change in what
  programs mean or whether they are accepted. The version string in
  `build.zig` changes only when a release is cut.
- **Branches:** `main` is the one long-lived branch. Work lands through
  short-lived branches and pull requests. The ruleset on `main` requires
  `test (ubuntu-latest)` and `test (macos-latest)`, and blocks force
  pushes and deletion.
- **Toolchain:** Zig 0.17.0, pinned in `mise.toml`. Nexus 2.0.0, only
  to regenerate the parser.
  - [docs/zig-0.17.md](docs/zig-0.17.md) covers every Zig API Rig uses.
  - The cross-project Zig guide is `~/Data/Code/zig/docs/ZIG-0.17.md`.
- **Health:**

  | Check | Result |
  |---|---|
  | `./test/run` | 2,626 passed, 7 pending (planned Core rules) |
  | Corpus | 6,021 of 6,021 (`./test/run corpus`) |
  | `test/matrix.py` | 3,070 programs, 0 failed |
  | `zig build test` | 124 pass, 1 skip |
  | Oracle (`./test/run oracle`) | 5 sets pass, at or above the floors in `test/oracle/coverage` (functions decided: tests 3,418, corpus 15,781, docs 437, matrix 15,911) |

  `test/known/` holds no open bugs. The pending examples are the
  planned rules of `docs/CORE.md`.

## The feature freeze

Rig is in a feature freeze. The North Star (AGENTS.md) and
`docs/CORE.md` are fixed points.

**In scope:**

- **Building the Core's planned rules.** Each is marked *(planned)* in
  `docs/CORE.md` and shown by a `rig pending` example. Building one
  turns its pending example into an ordinary one, in the same change.
- **The weak spots and open questions below,** and bug fixes, docs,
  tests, and speed.

**Out of scope:**

- **New language features or library modules** not in the Core.
  Examples: io, fs, Map/Set, traits, threads.
- **A change to a rule.** It goes through `docs/CORE.md` first, as its
  own reviewed change, and needs the user's agreement. Ask the "Rig"
  session (below).

A change is in scope when it changes no accepted program's meaning and
only turns wrong rejections into acceptances, or builds a planned Core
rule. A change that rejects programs a release accepted lists them in
the release notes.

## The consolidation

The compiler was restructured so the Core's rules come from its
structure: about 90% of earlier soundness bugs traced to three
structural weak spots, which these steps removed (the evidence is in
`.git/revamp/reports/`, local). All ten steps are done:

1. **Type facts.** One fact per question (copyable, unique, needs
   cleanup, may hold a loan, cloneable, how a read view is represented)
   replaced the disagreeing proxies; `struct T unique` exists,
   `std.random.Rng` became the unique `Random`, and a type holding a
   `Cell` is unique.
2. **One classifier and one exit.** `sema.handsOver` decides what every
   expression hands over by a positive list, and one exit primitive ends
   every path, running defers and reporting the loans it drops; the
   `classify` test keeps `handsOver` the only classifier.
3. **Reads and lends.** A bare name reads in place where a view is
   expected, one lend table serves every owner (Vec, Text, Box, `*T`,
   optionals), and a header's subject is viewed or taken by its
   classification.
4. **Containers hold anything.** `Vec[Text]`, nested Vecs, and records
   that own text work; `?v[i]`, `!v[i]`, and `<v[i]` lend or take an
   element; assigning a view place re-points it or writes through.
5. **The remaining planned rules.** An error value meets `T!` only as
   `return`'s operand, `(!s).insert(k)`, `const x = e`, an owner moves
   as a function's or block's last value, and `+x` deep-copies Vec, Box,
   and owning structs.
6. **Result origins.** A call's result carries the loans of the
   arguments whose types could hold what it views, `from a` narrows
   that, and each body is checked against its signature.
7. **Vocabulary.** Diagnostics, docs, and internal names say lend, view,
   and loan; the `vocab` test fails on Rust's word.
8. **SPEC follows the Core,** derived from it in the new vocabulary.
9. **Speed.** Generic uses are indexed by parameter, which removed the
   quadratic generic checks.
10. **Lowering, decided as storage facts.** Every hidden storage
    location emit makes is a fact (`src/storage.zig`), emit takes no
    address of a Zig temporary such a fact names, the sanitizer poisons
    hidden storage, and the ownership checker walks what a call holds.

Alongside them, a reference ownership checker built from the Core alone
(`bin/rig-oracle`, `test/oracle/`) checks the compiler: `./test/run
oracle` fails when the compiler accepts a function the Core rejects,
and when the oracle decides fewer functions than the floors in
`test/oracle/coverage`.

The final review (`.git/revamp/r3/final-review/core-review.md`, local)
found no unsound program. Its fixes are in: a write method on a
temporary is rejected, a binding with no type holds a call's write view,
and the payload-view and loop diagnostics name only forms that compile.

**Held, each waiting on the change named:**

- **Bare `break x` of a loop-local owner** (CORE sentence 1, *planned*;
  commit `3acb07a9` on `r3-step45-held`): until emit's usage scan is a
  recorded fact.
- **Whole-program parameter summaries** (CORE §9, *planned*): a generic
  `Holder[String]` built from literals is still rejected.
- **Field-precise re-pointing:** with field-precise loans.
- **Std search taking `x: ?T`:** it would reject
  `slices.contains(?v[..], ?t[4..5])`; decide whether implicit lends
  extend to branching values.
- **`into` for stores, function-type `from`, and path tokens:** Core
  changes, after the freeze.

## Open questions

These belong to the design owner; `.git/revamp/r3/rig-questions.md`
(local) has the evidence for each.

- **Core wording.** The commit "Correct CORE status words and
  precision" proposes the status words and precision the final review
  found wrong; it needs the owner's approval, and can be dropped alone.
- **Field-disjoint loans:** today field loans are unioned. The design
  owner decided they come, with field-precise re-pointing, as their own
  round after B4, with `docs/CORE.md` updated first. The other three
  rules the Core left open are decided and built (CORE sentences 6 and
  7, §5): a call's result that holds no write view keeps a write
  argument lent to read, and that argument's write lend ends as the call
  returns; dropping a container of views uses them only through a `drop`
  body; a binding takes the type of a field or element on its right and
  an annotation converts, so `x = h.w` of a `!Int` is rejected and
  `x: Int = h.w` reads it. Open: a bare write-view name still binds the
  value it reaches (`x = w`), as v0.2.0 does; whether the binding rule
  covers names too is the owner's to decide.
- **The kind of a struct of Strings:** CORE calls it a view, SPEC plain
  data; the compiler treats it as CORE's read-view kind.
- **Arm-local payload views:** lift them for an unguarded, non-generic
  match on a place once emit matches in place?
- **A branching receiver:** a pointer per leaf (built) or a rejection?
- **Clone limits:** are the missing clones of a type from another
  module, or one holding a `Signal`, rules or gaps?

## Weak spots

Reviewers keep finding problems in these areas. Change them carefully,
and run the corpus after.

- **Statement temporaries** (Core §3). A header whose subject makes a
  temporary is rejected, unless it takes its subject or binds plain data
  of a value made there (`copiesHeader`, the storage fact
  `header_copy`), because emit binds a copy of the subject. Next: B4,
  emit points at a header's subject instead of copying it, which lifts
  the rejection.
- **Arm-local payload views.** A read match's binding that is no plain
  data is usable within its arm only, because emit may match a copy of
  the subject (a guarded match, a generic body). This rejects programs
  `v0.1.6` ran correctly. B4 and B5 lift it.
- **Addresses of Zig rvalues.** Emit still takes the address of a few
  Zig rvalues no fact names: a `?self` method on a made value no slot
  keeps, on a branching value with a made leaf, `emitLeafPtr`'s
  `&@as(T, value)` fallback, labeled value blocks' yields, and a
  temporary array lent to a call (docs/INTERNALS.md, Emit, "Addresses of
  Zig temporaries"). They are latent: the checker keeps each view within
  its statement, and Zig keeps the rvalue's slot today. Next: make the
  chokepoint structural, so every `&` and `|*x|` targets a place, a
  slot, or fact-named storage whose `life` the chokepoint checks.
- **What a view could hold:** `carry` and `sema.viewReach`, and String
  values in Cells, generics, and closures.
- **Evaluation order versus what is emitted:** call arguments, `print`
  and `Text(...)` arguments, and assignment targets.
- **`defer`/`errdefer` at exits,** owners behind `Cell`, `Box`, and
  `*T`, and generic instances.
- **Review findings not fixed:**
  - `|+x|` captures a copy of plain data or a handle only; a deep copy
    of an owner is *planned* (CORE §7).
  - `fill`, `copy`, and `[n of x]` ask whether an element is plain data,
    while a binding asks the `copyable` fact, so a read-view element is
    copyable to one and not the other: two classifiers for one fact.
  - The oracle accepts two shapes the Core rejects (the compiler
    rejects both): a `?self` result reaching an owned field beside a
    held view (`x77`), and re-pointing a write view a closure has lent
    (`x68`). Add them as `# oracle:` tests when the oracle learns them.
  - Whether an expression is a view is not one fact yet (CORE §9,
    *planned*): a loop over a call's returned view of a Vec of owners is
    rejected as if the Vec were made there.
  - `bin/rig-oracle` in a worktree goes stale; `./test/run` rebuilds it,
    so rebuild before using it by hand.

## What comes next

1. The design owner settles the open questions and the CORE wording.
2. B4 (emit points at header subjects), then B5, which lift the header
   temporaries rule and arm-local payload views.
3. The structural address chokepoint.
4. The per-expression "is a view" fact, and `copyable` for `fill` and
   `[n of x]`.
5. The held items, as their prerequisites land.

## The gates

The machine is shared. Check `sysctl -n vm.loadavg` before a full run,
and wait while the 1-minute load is above about 12.

```bash
./test/run -j 2                               # full suite; the sanitizer is on by default
./test/run -j 2 corpus                        # every reviewer probe; has caught real use-after-frees
python3 test/matrix.py -j 2                   # form x context x type programs
zig build test --cache-dir "$(mktemp -d)"     # unit tests; a plain rerun replays cached results
```

- Rerun a timeout failure alone before trusting it: under load,
  timeouts are often spurious.
- **Equivalence** proves that a refactor changed nothing:
  `python3 test/equiv.py OLD_RIG bin/rig` compares the parse, the
  checks, the facts, and the emitted Zig of every program and doc
  example. Explain every difference it prints.

## Conventions

- **Vocabulary:** *you lend a view; the compiler remembers the loan.*
  - lend: the act, written on the owner's side;
  - view: the value handed over;
  - loan: the owner-side record.

  The `vocab` test fails on Rust's word; `test/vocabulary-allow.txt`
  lists the few lines that must name it.
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
