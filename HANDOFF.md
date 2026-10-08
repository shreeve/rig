# HANDOFF: where Rig stands, and what comes next

This is the resume point for anyone, human or agent, picking up Rig
work. Read it first, then [AGENTS.md](AGENTS.md) (the rules) and
[docs/CORE.md](docs/CORE.md) (the ownership model every rule derives
from).

## Current state

- **Release:** `v0.2.9` is the latest release (Zig 0.17.0, Nexus
  2.0.0), with CI green on Linux and macOS. It checks and emits every
  assignment as its value, then its store, closing the assignment holes
  of earlier versions, and adds `--delta` runs that rerun only what
  changed; its release notes list each change.
- **Releases:** every change, fixes included, ships in the current
  line, `v0.3.x`; an earlier line gets no further releases. Rounds land
  on `main` untagged until the next tag, which is cut only after the
  deep gate (AGENTS.md, "Land fast, release deep"); its release notes
  include a migration guide for any renames.
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
  | Oracle (`./test/run oracle`) | 5 sets pass, at or above the floors in `test/oracle/coverage` (functions decided: tests 3,414, corpus 15,781, docs 437, matrix 15,911) |

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

1. **Type facts.** One fact per question (copies, unique, needs
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
temporary needs `!`, which lends the temporary to write in its
statement's slot (`!mk().pop()`, CORE sentence 4), a binding with no
type holds a call's write view, and the payload-view and loop
diagnostics name only forms that compile.

**Held, each waiting on the change named:**

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
  So does B4b's "Mark bare break and payload views past the arm built
  in CORE sentence 1".
- **Field-disjoint loans:** today field loans are unioned. The design
  owner decided they come, with field-precise re-pointing, as their own
  round after B4, with `docs/CORE.md` updated first. The other three
  rules the Core left open are decided and built (CORE sentences 1, 6,
  and 7): a call's result that holds no write view keeps a write
  argument lent to read, and that argument's write lend ends as the call
  returns; dropping a container of views uses them only through a `drop`
  body; a bare name or place only reads, so `x = h.w`, like `x = w`, of
  a `!Int` copies the Int.
- **The kind of a struct of Strings:** CORE calls it a view, SPEC plain
  data; the compiler treats it as CORE's read-view kind.
- **A branching receiver:** a pointer per leaf (built) or a rejection?
- **Clone limits:** are the missing clones of a type from another
  module, or one holding a `Signal`, rules or gaps?

## Weak spots

Reviewers keep finding problems in these areas. Change them carefully,
and run the corpus after.

- **Statement temporaries** (Core §3). A header whose subject makes a
  temporary and reaches a place outside it binds the place's own: emit
  points at it (`storage.headerPoints`, the storage fact `header_value`
  held by pointer). One that reaches no place copies a value made in the
  header (`copiesHeader`, the storage fact `header_copy`) and is
  rejected, unless it takes its subject or binds plain data of a value
  made there. Tests: `test/behavior/ownership/header_points_through_temporary.rig`,
  `header_temporary_points.rig`, `header_branch_points.rig`, and
  `test/reject/ownership/header_temporary_rejected.rig`.
  - *Resolved in B4a:* a place inside a view of a value the header
    makes (`id(?mk()).e`, `(?mk()).e`, `idh(?mkh()).xs`) lives in the
    header's own temporary, so the header copies it and stays rejected;
    pointing there would read the temporary after the header drops it.
    Tests: the `sema` unit test "storage: a header points at a place its
    temporaries reach, never into one" and
    `test/reject/ownership/header_place_inside_temporary.rig`.
- **Payload views.** A read match's binding that is no plain data views
  the subject where emit matches it (`storage.matchesInPlace`: a place,
  a held part, a view a call returns, a value branching over views,
  through temporaries or a guard), so a view of it carries the subject's
  loan past the arm. Where a read match matches a copy, such a binding
  is usable within its arm only (`SymbolFlags.arm_view`); every such
  subject with a header temporary is also rejected (`rejectHeaderCopy`).
  Tests: `test/behavior/ownership/match_payload_view_outlives_arm.rig`
  and `test/reject/ownership/match_payload_view_escapes.rig`.
  - *Resolved in B4a:* a generic read view a field or an element holds
    on the subject's path (`match w.r`, `match arr[1]`) is reached in
    place, `rig.viewedPtr(T, &w.r).*`, never through a `rig.viewed`
    copy whose payload a pointer would outlive. Tests:
    `test/cli/emit_shapes.sh` (no `&rig.viewed(` and no switch on a
    `rig.viewed(` copy), `test/behavior/emit/generic_view_field_subject.rig`,
    `test/behavior/emit/generic_view_field_guard.rig`, and the escape
    `test/behavior/ownership/generic_view_field_escape.rig`.
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
- **Statement-long loans the Core does not need** (compiler-stricter,
  listed in `test/oracle/differences`): a call's result's read loans,
  and a write lend the call stores or whose result is a write view, last
  until the statement ends, not until their last use in it. So
  `match find(!v)` cannot write `v` in an arm after the payload's last
  use, `print(firstw(!v).n, v.len)` is rejected, and so is reading `v`
  after `keep(!v, !h, ?x)` in its statement though `h` is used no more.
  The Core allows all three, and the oracle accepts them. A later round
  ends these loans at their last use within the statement. Likewise a
  generic callee's argument write lend lasts to the statement's end,
  since its origins come from its signature, where a `T` could hold
  anything (`print(gfirst(!v).n, v.len)` is rejected); per-instance
  origins are a later refinement.
- **Review findings not fixed:**
  - Over-rejections main has too (review of B4b part 2, probes
    `test/corpus/review-b4b-2-p22`, `p24`, `p25`, `p43`): a payload
    view pushed into a Vec inside a `for` stays rooted on the loop
    binding; a view returned from a `match` nested on an outer payload
    binding (`match r.i` in `.a(r)`) is rooted on that binding; and a
    write-view local a payload view came through cannot be re-pointed
    while the view lives.
  - An operator, generic inference, and a binding with no type read a
    read view of a scalar as the value (`readsAsValue`), but keep a read
    view of a plain struct, array, or optional as the view: copying
    those out there would change the type of accepted programs
    (`x = r` with `r: ?Point` binds a `?Point`). Where a type is
    expected, every value that copies is copied out (`sema.copies`).
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
2. B5: what B4b left of the header temporaries rule, a header that
   copies a value made in it.
3. The structural address chokepoint.
4. The per-expression "is a view" fact.
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
  example, the root module's and the whole sanitized package's. It
  caches the old compiler's results, so a rerun against the same base
  runs only the new compiler. Explain every difference it prints.

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
