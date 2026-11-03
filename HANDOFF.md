# HANDOFF: where Rig stands

This is the resume point for anyone, human or agent, picking up Rig
work. Read it first, then [AGENTS.md](AGENTS.md) (the rules) and
[docs/CORE.md](docs/CORE.md) (the ownership model every rule derives
from). What changed is in [CHANGELOG.md](CHANGELOG.md), and what is
planned is in [docs/ROADMAP.md](docs/ROADMAP.md). Why it was decided,
and what was measured, is in the records,
[docs/history/records/](docs/history/records/INDEX.md), whose ledger's
newest entry summarizes the latest rounds.

## Start here

A new session, human or agent, takes these steps in order:

1. **Read** this file to the end, then [AGENTS.md](AGENTS.md) (the
   rules, the map of the compiler, and how a change is made, its gates
   included), then the newest "RESUME HERE" entry of the
   [ledger](docs/history/records/ledger.md). [docs/CORE.md](docs/CORE.md)
   is the ownership model every rule derives from; read it before any
   change to the checker or the language.
2. **Notes outside the repo.** Read
   `~/Data/Code/Claude/rig/rig/fresh-start-brief.md` first: the
   one-page brief for a fresh session, with where Trig stands against
   tsrs, the leads in order, the paths on pup, and what was measured
   and is not to be redone. The owner's standing preferences are in
   `~/.claude/projects/-Users-shreeve-Data-Code-rig/memory/MEMORY.md`.
3. **See what is open:** `gh pr list` (drafts are being measured or
   wait on the owner), "In flight" below, and `git log --oneline -20
   origin/main` for what landed last.
4. **Work** in a worktree (`wt new NAME`, AGENTS.md "How a change is
   made"), never in the main checkout. Each compiler, emit, runtime, or
   std change passes the gates of AGENTS.md step 6, std.json's guard
   among them, and a speed change meets Trig's bar (AGENTS.md, "A speed
   feature pays for its lines").
5. **Ask the owner** what the record does not settle: a short message,
   with each decision numbered and a default for each. Only the owner
   approves a merge, a rule change, a name, or a release; an approval
   relayed by another session is not his.
6. **Leave it current.** A change updates its docs, CHANGELOG, and this
   file's status in the same PR; a session that ends adds a "RESUME
   HERE" entry to the ledger.

## Current state

- **Release:** `v0.2.9` is the latest release (Zig 0.17.0, Nexus
  2.0.0). `main` is ahead of it toward `v0.3.0`, which is not tagged.
  The changes since `v0.2.9`, renames and removed spellings included,
  are in [CHANGELOG.md](CHANGELOG.md).
- **Releases:** every change, fixes included, ships in the current
  line, `v0.3.x`; an earlier line gets no further releases. Rounds land
  on `main` untagged until the next tag; its release notes include a
  migration guide for the renames (`tools/migrate-0.3.py`).
- **Branches:** `main` is the one long-lived branch. Work lands through
  short-lived branches and pull requests: plain git, with no CI,
  gates, or required checks.
- **Toolchain:** Zig 0.17.0, pinned in `mise.toml`. Nexus 2.0.0
  generates the parser at every build, from the sibling checkout's
  `nexus/bin/nexus` (AGENTS.md, "Workflow").
  [docs/internals/zig-0.17.md](docs/internals/zig-0.17.md) covers every
  Zig API Rig uses. Its `@intCast` from a signed type to a narrower
  unsigned one miscompiles in release builds (LLVM `trunc nsw`); Rig's
  emitted Zig and runtime cast through the unsigned type of the source's
  width instead, until Zig fixes it.
- **Health:** a change lands on a green core suite (`swarm test/rig.rip`:
  the test files, the doc examples, their pending examples the planned
  Core rules, the examples, the unit tests, and the oracle floors in
  `test/oracle/coverage`). A change to the compiler, the runtime, or std
  also passes Trig's light gate (`tools/light`, AGENTS.md step 6) before
  it merges: a debug trig on Trig's six cli projects, four ways each,
  byte-identical to tsc, in about a minute; and loco's (`rig/tools/light`
  in a loc checkout): loco built with that Rig, its output identical to
  the Rust loc's. The full suite (`swarm test/rig.rip all`, the core
  with test/cli, the probes, and the matrix's programs whose own Zig
  changed, built in packs), and Trig's full suite
  (`tools/full-main` on pup; the last result is in
  `/zfs/trig-pup/full/LATEST`) run before each major or minor release,
  optionally before a patch. Nothing runs on a schedule: there are no
  crons and no nightlies. A quick check takes under a minute a repo and
  a long one under ten; one that takes longer is a defect to fix. No
  case is marked `known:`; a `known:` names the failure it waits for.

## In flight

- **Patterns and chains (2026-11-02).** The owner's design of a
  pattern test, from a panel of Rust, Ruby, and Swift programmers
  ([design/matches.md](docs/design/matches.md)): `x matches P`,
  alternatives in parentheses that bind when they agree, `name?` and
  `none` in a payload. Built on branch `matches`; it rejects `x as .p`
  (loco has one site, `tools/migrate-matches.py` rewrites it). Next, as
  its own change, the approved fused iterator chains
  ([design/iterators.md](docs/design/iterators.md)) with `min_by(key)`
  and `max_by(key)`.
- **The `for` header (t05)**, approved and not started: a use in a
  `for` header belongs to the loop's entry, not its body, where the
  header copies its source out, so `for x in a.arr` with a body that
  writes what `a` viewed is accepted (`review-header-paths-1-t05`, a
  `prod-strict` line of `test/oracle/differences`). The row's goal,
  rule, cases, and gates are in
  [records/2026-10/core-33d/next-handoff.md](docs/history/records/2026-10/core-33d/next-handoff.md)
  (row 2). It follows 33D (#859: a statement's loans end at their last
  use, CORE §6 rewritten) and the oracle taught CORE §6 (#861).
- **The oracle's model of the hidden `E?`** (errors track 2's R3-3) is
  the one piece of errors with data left
  ([round-report.md](docs/history/records/2026-10/consolidation/round-report.md)).
- **The hash race** (`bench/hash`; its panel's decisions in
  [hash-race/](docs/history/records/2026-10/hash-race/)): `Map` and
  `Set` are compiler built-ins over `zig-ordered`'s table, and `HashMap`
  and `HashSet` over `zig-hash`'s (INTERNALS, "The built-in Map and
  Set"). Open: the owner confirms the iterator names (`HashItems` and
  the rest); text-key rows trail zig-hash 1.2-2.6 times (a String key's
  slot is 40 bytes, with no prefetch); the lane fact that would let `for
  k in m.lanes()` index a `[n]T` with no test waits for an array index's
  proven form in emit; and std's Map using a write view returned `from
  @` (`find` handing back the entry, with `edit` and `ensure` on top), a
  1.3-1.9% ceiling on ts-pattern, timed on Trig on its own.

## Next, in order

The owner's priority is Trig's speed against tsrs; memory counts where
it buys speed. Trig checks with several checkers in tasks, and its
output equals tsc's at each count. Standing-7
([tsrs-standing-7.md](docs/history/records/2026-10/hash-race/tsrs-standing-7.md),
PGO Trig) measured it against tsrs as shipped: ts-pattern 16.7% slower
at one checker and 44.5% at four, zod3 39.3% and 62.9%, with 38-54%
more peak memory. Trig does the same work as tsrs in its Go mode,
object for object; shipped tsrs's lazy members save it 42.7 MiB on
ts-pattern (480k symbols against 934k) and 7.5 MiB on zod3, and are its
main lead, 12.7-21.5% faster than its own Go mode at four threads.
Standing-7 predates rig#873 (small objects of integers held as one
word: every Trig project 0.9-3.6% faster on pup, peak memory level) and
trig#243 to #246, so a standing-8 comes first. The leads, in order:

1. **tsrs's lazy members, ported faithfully.** Trig's own ceiling saved
   only about 6 MiB, so it missed what tsrs does; measure tsrs's
   switches one by one first.
2. **`get_property_of_type_ex`'s extra calls,** 1.8-2.25 times tsrs's,
   counted by call site.
3. **Flow and name resolution:** their counts match tsrs's, and their
   gap is cost per call (zod3).
4. **The head:** parse and bind cost per node, and file calls off the
   blocking pool.
5. **Trig's full suite in under ten minutes:** split release builds
   (rig#854's units: 3.1 minutes against 28.6 on pup), one shared build,
   and smaller shards. Its two release compiles take 31 and 18 minutes,
   and its 300-test chunks about 15 minutes each.

What was measured and is not to be redone (table coloring, prefault,
sparse links tables, the relation cache's key and path, Map calls out
of line, store-forward stalls, loop bounds checks, re-checked optionals
and tags, parse-time atoms, broad-corpus PGO, and more) is in the
brief's "Don't redo" (`~/Data/Code/Claude/rig/rig/fresh-start-brief.md`).

Beside these, `rig lsp` moves onto Nexus's generated server (`nexus
--editor --lang src/rig.zig rig.grammar DIR`): Rig fills in the
generated `hooks.zig` (tokens, Rig-worded syntax errors, analysis of
the editor's unsaved text, completion words), and analysis needs an
entry to the checker that takes source in memory.

APIs, `api Shape` ([docs/design/apis.md](docs/design/apis.md)), are
built in all five stages. What remains, objects of an API with an
associated type (Stage 4, phase 5), the Lean model's crossing
obligation (Stage 5, phase 3), and owned closures as objects (Stage 5,
phase 4), is in [docs/ROADMAP.md](docs/ROADMAP.md), "APIs, the rest".

`Map`, `Set`, `Hasher`, `Order`, `Printer`, and `Symbol` are built in;
the run-time string interner is `text.Interner` in `std.text`. Trig
moves to these names with `tools/migrate-builtin-map.py` and
`tools/rename-interner.py`.

An object's optional is the size of the object where a field has room
for `none` (a String's, List's, box's, or handle's address, a `Bool`,
an enum's spare tag), an object that is an id names its own
(`none id == 0`), and every other flag optional is written in one
store. On Trig's binder (checker.ts, x86), a 4-byte `Node?` measured
14% faster and the one store alone 7%; Trig takes the first by naming
`Node`'s none and writing `none` for its `Node(id: 0)` placeholders.

Release builds on Linux can be laid out by a workload with BOLT,
`rig build --release --bolt -- WORKLOAD`: 7.6 to 7.9% fewer cycles on
Trig projects it was not trained on. They can also be optimized by
LLVM's profile-guided optimization, `rig build --release --pgo --
WORKLOAD`: Trig 10% faster with 14% fewer instructions on a project it
was not trained on, and 5-9% faster than BOLT alone
([record](docs/history/records/2026-10/perf-stage/pgo.md)). Release
builds omit frame pointers and stack canaries; `RIG_FRAME_POINTERS=1`
keeps the first for a profiler, `RIG_STACK_PROTECTOR=1` the second.

`std.terminal`, a terminal emulator library, matches Ghostty (pinned
at `31bdcd5a7963`) on 416 recorded cases and its fuzzer, scrollback
included, and beats it on every corpus of bench/terminal. Its
decisions, model, checks, and what is left are in
[docs/design/terminal.md](docs/design/terminal.md). Nothing is in
flight; the next piece (a reading API for renderers, OSC, resize, or
`std.tty` last) is the owner's choice.

Compile-time functions (`fun cap[n: Int] -> Int`, called `cap[8]`)
run in the checker (`src/cteval.zig`) over integers, `Bool`, plain
enums, and fixed arrays of them, and a function value goes to any
task (SPEC, "Compile-time functions" and §18). The next forms, a call
over an enclosing generic's parameter (`[cap[n]]T`) and text
parameters, are in docs/ROADMAP.md.

Learn Rig ([docs/learn/](docs/learn/README.md)) has journeys 01 to 11.
Journey 07 teaches generics and built-in bounds, and 08 APIs of a
program's own and API objects of every form, Stages 3 to 5. Journey 12
is written last; how a journey is written, and its outline, are in
[docs/internals/journeys.md](docs/internals/journeys.md). What the
journeys found in the compiler and its docs is at the end of
[docs/internals/backlog.md](docs/internals/backlog.md).

Toward `v0.3.0` are Rig's and Trig's full suites and the tag. Its migration guide is
[docs/MIGRATING-0.3.md](docs/MIGRATING-0.3.md), and CHANGELOG's
"Upgrading from v0.2.9" lists the 43 forms 0.2.9 accepted that 0.3.0
rejects, which the tag's release notes take over. The scripts:
`tools/migrate-0.3.py` (box, list, string, obj, builtin, label, self,
const), `tools/state-bounds.py`, and, for programs written against
`main` between the releases, `tools/migrate-builtin-map.py`,
`tools/rename-interner.py`, `tools/rarely-body.py`, and
`tools/rename-task-bounds.py`. Over the 4,836 programs `v0.2.9`
accepts, `main` accepts 1,094 as written and 3,495 after the scripts;
the rest need a form of the guide's Step 2 or 4 by hand
([release-0.3.0.md](docs/history/records/2026-10/consolidation-2/release-0.3.0.md)).
Everything after that is in
[docs/ROADMAP.md](docs/ROADMAP.md); the decided engineering items, with
their probe cases, are in [docs/internals/backlog.md](docs/internals/backlog.md).

## Scope

The North Star (AGENTS.md) and `docs/CORE.md` are fixed points.

**In scope:**

- **Building the Core's planned rules.** Each is marked *(planned)* in
  `docs/CORE.md` and shown by a `rig pending` example. Building one
  turns its pending example into an ordinary one, in the same change.
- **The weak spots and open questions** in
  [docs/internals/weak-spots.md](docs/internals/weak-spots.md), bug
  fixes, docs, tests, and speed.
- **Language and library work toward `v0.3.0` and Trig,** listed in
  [docs/ROADMAP.md](docs/ROADMAP.md). Each fits the Core.

**Needs the design owner first:**

- **A change to a rule.** It goes through `docs/CORE.md` first, as its
  own reviewed change, and needs the owner's agreement.
- **New library modules** beyond those in the roadmap, such as threads,
  and a new type built into the language.

A change that rejects programs a release accepted lists them in the
release notes.

## Conventions

- **Vocabulary:** *you lend a view; the compiler remembers the loan.*
  - lend: the act, written on the owner's side;
  - view: the value handed over;
  - loan: the owner-side record.

- **Commits:** prose, "area: what it now does", with a body of plain
  sentences and no AI attribution (AGENTS.md).
- **Comments:** timeless, describing the code as it is. History belongs
  in git.
- **The parser:** `src/parser.zig` is generated by `zig build` from
  `rig.grammar` and is not tracked; edit the grammar.
  `rig.grammar`, `src/rig.zig`, and `src/diag.zig` are mirrored
  byte-for-byte in Nexus's `test/rig`, so a change to them needs a Nexus
  re-sync.
- **Builtins:** a builtin call is `$name(...)`. Rig's raw builtins track
  Zig's names exactly (`$fromBackingInt`, `$trunc`). The old names are
  rejected with a hint.
- **Speed work:** a speed feature lands when its gain on a real program,
  measured on runs it was not trained on, pays for its lines
  (AGENTS.md, "Working rules").
- **Merging:** after a branch merges, delete it locally and on GitHub,
  and remove its worktree. `main` stays the only branch.

## Who to ask

This file, AGENTS.md, and the records state the current facts, and are
enough to start from. Design intent and Core questions go to the owner,
as decisions with a default each; the records under
[docs/history/records/](docs/history/records/INDEX.md) hold the panels
and measurements behind every past decision.
