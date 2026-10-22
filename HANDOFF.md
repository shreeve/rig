# HANDOFF: where Rig stands

This is the resume point for anyone, human or agent, picking up Rig
work. Read it first, then [AGENTS.md](AGENTS.md) (the rules) and
[docs/CORE.md](docs/CORE.md) (the ownership model every rule derives
from). What changed is in [CHANGELOG.md](CHANGELOG.md), and what is
planned is in [docs/ROADMAP.md](docs/ROADMAP.md). Why it was decided,
and what was measured, is in the records,
[docs/history/records/](docs/history/records/INDEX.md), whose ledger's
newest entry summarizes the latest rounds.

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
- **Health:** the bar for landing is a green full run on `main`: the
  full suite (`swarm test/rig.rip all`, with the doc examples, their
  pending examples the planned Core rules), `test/matrix.py`, the unit
  tests, and the oracle floors in `test/oracle/coverage`. A change to
  the compiler, the runtime, or std also passes Trig's light gate before
  it merges: Trig's release build, and its six projects run five ways,
  byte-identical to `main`; Trig's full suites run on `main` every few
  hours or on demand. No case is marked `known: true`: no bug is open.

## In flight

- **Errors with data,** from the approved spec
  (docs/history/records/revamp/r3/errors-panel/): on `main` are declared
  error sets (R2, #542), clones across modules and Map's `+` (#548), the
  runtime's error-data plumbing (R3a, #550), and CORE's paragraph "A
  failure moves its error", revised by a panel of four
  (docs/history/records/2026-10/errors-core/). Next are R3 (fields,
  with the sites R3a left to it: a failure through a function value),
  R4 (std.json), and R2.5 (generic sets).
- **Trig's stores on `Table`/`Slot`:** Trig's migration; the same reads
  without a test, measured in a stand-in build, made ts-pattern about 3%
  faster.

## Next, in order

Trig checks with several checkers in tasks, and its output equals tsc's
at each count. tsrs leads it by 1.69x on one checker on ts-pattern and
uses about 1.7x less memory. In the owner's order:

1. **Single-thread speed of the checker and of Map/Set,** which carries
   into every checker. With every safety check removed, ts-pattern runs
   11.2% faster (index tests 8.0%, conversions 2.9%, Zig's bounds 1.7%,
   overflow 1.2%; docs/history/records/2026-10/safety-checks/measurement.md). By
   share of that cost: the stores (`Table`/`Slot`), Trig's symbol and id
   accessors, the std Map/Set probes, and Trig's AST records. Map and
   Set code is 18.8% of ts-pattern's samples, beyond its checks.
2. **Doing less.** Trig allocates about 6.4x what tsrs does. Its memory
   is live data, not List slack (exact presizing saved 4% on Linux): the
   stores' contents, Map entries, and about 200,000 small `u32` lists.
   The heap profile (`RIG_HEAP_PROFILE=sites`) names their owners.
3. **Build speed.** `rig build` reuses no cached work (ROADMAP, "Cached
   `rig build`"), and a Trig release build takes about 9 minutes and
   about 9 GB on pup.
4. **Two limits of the ownership checker** that make std code clumsy,
   each a Core question for the owner first: a write view bound by
   `if !@slots[j] as s` cannot be returned `from @`, though the read
   form can; and an object's field cannot be moved out of it alone (no
   partial moves). Together they keep a Map slot at 40 bytes rather
   than 24 (backlog, "The Map's entries in its table slots"). The same
   first limit keeps `find` from handing back the entry, which is what
   the rest of Map's and Set's checks wait on: a 1.3-1.9% ceiling on
   ts-pattern; proving their probe indexes alone gained nothing
   (docs/history/records/2026-10/safety-checks/len-and-map-notes.md).

Measured and set aside: lazy member tables (symbols are about a tenth
of Trig's heap), prefault for every heap with tasks (no gain, 8-15%
more memory), sharing global types across checkers (a low ceiling, and
tsc's ids per checker could not be matched), and a parallel parse and
bind (about 1.5% of ts-pattern).

APIs, `api Shape` ([docs/design/apis.md](docs/design/apis.md)), are
built in stages. Stage 1, method calls on a type parameter, and Stage 2,
built-in bounds (`[T: Ord]`, `obj Version: Ord`, a type's own `eq`,
`hash_into`, `order`, and `print`), are on `main`. Stages 3 to 5 wait
for a program that needs them; a design question is answered from the
record, and what it does not settle goes to the owner as a decision with
a default.

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
Trig projects it was not trained on.

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

Learn Rig ([docs/learn/](docs/learn/README.md)) has journeys 01 to 10.
Journey 07 teaches APIs' Stages 1 and 2 and `xs.reduce(start, f)`;
rewrite its later sections as Stages 3 and 4 land. Journey 11 is
written last; how a journey is written, and its outline, are in
[docs/internals/journeys.md](docs/internals/journeys.md). What the
journeys found in the compiler and its docs is at the end of
[docs/internals/backlog.md](docs/internals/backlog.md).

Toward `v0.3.0` are the docs pass, a full run, and the tag with its
migration guide. `tools/migrate-0.3.py` migrates the 0.2 renames it
names (box, list, string, obj); the renames since live in their own
scripts, `tools/migrate-builtin-map.py` (`Map`, `Set`, and `Hasher`
built in), `tools/rename-interner.py` (`text.Interner`), and
`tools/rarely-body.py` (`rarely` as a body's first line), and a few
have none yet: `catch` at `??`'s level, a byte as a string literal
where a `U8` is expected (`b'A'` gone), the capitalization of
generic parameters, and the forms CHANGELOG lists as removed. The
release folds them into one guide. Everything after that is in
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
  own reviewed change, and needs the user's agreement. Ask the "Rig"
  session (below).
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

For design intent, Core questions, or whether something is a new feature
or consolidation, send a message to the **"Rig"** session. This file
states the current facts.
