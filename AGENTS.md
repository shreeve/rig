# AGENTS.md: working on Rig

What Rig is, what the compiler must guarantee, where things live, how to
build and test, how a change is made, and the traps. This page changes
only when a rule does; where Rig stands and what comes next is
[HANDOFF.md](HANDOFF.md), read next.

## What Rig is

Rig is an indentation-sensitive systems language that compiles to Zig.
It aims for the readability of Python and Ruby, the cost model of Zig
and C, and the memory safety of Rust: no garbage collector, no hidden
allocation, no hidden reference counting, no silent control flow. The
compiler checks a program, writes Zig, and Zig optimizes and links.
Ownership is visible where it happens, as one-character sigils that mean
the same thing everywhere; words are libraries.

The six families of sigils are on one page in [docs/QUICK.md](docs/QUICK.md),
and each is taught in [docs/learn/01-sigils.md](docs/learn/01-sigils.md).

Brackets after a name are compile time (`List[Int]`), parentheses run
time. The whole ownership model is [docs/CORE.md](docs/CORE.md).

## The North Star: what the compiler must guarantee

These are about the compiler, not the process. They do not bend.

1. **Accept means correct.** If `rig check` accepts a program, the
   emitted Zig compiles, runs, and does what the source says. Anything it
   cannot lower correctly is rejected with a Rig diagnostic: never a Zig
   error, an `@compileError` placeholder, or a construct silently dropped.
2. **Safe code cannot corrupt memory.** Use after move, double free, use
   after free, dangling views, and leaks in safe Rig are compiler bugs.
   Only `raw` code may break this. "Runs clean" means clean under
   `RIG_SANITIZE=1`, which the test runner sets.
3. **Effects stay visible.** Every sigil survives as a named node in the
   IR. No feature hides a move, clone, allocation, failure, or mutation.
4. **One classifier per fact.** Whether an expression is a place, a made
   value, a lend, or a view is decided once, by a positive list, and
   recorded. The checker checks exactly what is emitted: emit decides
   nothing the checkers did not walk.
5. **Ownership features fit the Core.** A change that touches ownership
   fits `docs/CORE.md` in a paragraph (CORE §10), or changes the Core
   first, as its own reviewed change the owner agrees to.
6. **Docs claim only what runs.** Every `rig` example in the docs is a
   test. A rule decided but not built is shown in a `rig pending` block.

## The map

The compiler is one pipeline; [docs/internals/INTERNALS.md](docs/internals/INTERNALS.md)
("Pipeline", "Source map") describes each pass.

| Path | Role |
|---|---|
| `rig.grammar` | the Nexus grammar: tokens, the IR schema, the rules and the node each makes |
| `src/parser.zig` | generated from `rig.grammar` by `zig build`; not tracked |
| `src/rig.zig` | the `Lexer` wrapper (layout, line joins, token classes) and the `Parser` wrapper (rewrites the tree into the semantic IR) |
| `src/modules.zig` | loads `use`d files and checks modules in dependency order |
| `src/sema.zig`, `resolve.zig`, `typecheck.zig` | names, declarations, types, effects, and the facts table |
| `src/storage.zig` | the hidden storage emit makes, decided once for emit and the ownership checker |
| `src/ownership.zig` | the ownership checker: moves, loans, drops |
| `src/proofs.zig` | the index, byte, and add checks known to pass, which emit omits |
| `src/inlining.zig`, `symbols.zig` | program-wide inlining decisions; the program's `:name` symbols |
| `src/facts.zig` | emit's read-only view of a checked module; decisions emit still makes itself are `Pending` |
| `src/emit.zig` | Zig code generation, one file per module |
| `src/runtime.zig`, `sched.zig`, `tasks.zig`, `net.zig` | the runtime, scheduler, tasks and actors, and sockets, embedded in `bin/rig` and written beside each program |
| `src/main.zig`, `lsp.zig`, `editor.zig` | the CLI (`rig --help`), the language server, editor support |
| `std/` | the standard library (`.rig`, with Zig shims), embedded in `bin/rig` |
| `test/rig/*.rig.test` | the behavior and rejection cases, one file per area |
| `test/cli/*.sh`, `test/torture/`, `test/oracle/` | command-line scripts, bad input, the reference ownership checker |
| `examples/` | whole programs, each run by the suite against its `# expect:` block |
| `bench/` | benchmarks against Zig, Tokio, Go, serde_json and others; each has a README, and the concurrency ones a PROGRESS.md |
| `tools/` | generators, migration scripts (`migrate-0.3.py`), `equiv.py` |
| `ZIG-0.17.md` | the Zig 0.17 reference every project's agents read, edited only here; after a change lands on `main`, `gh gist edit 57a74df35e17dacb30dcaa5d5164a27f -f ZIG-0.17.md ZIG-0.17.md` copies it to the gist the other projects link (Rig's own Zig notes are docs/internals/zig-0.17.md) |
| `formal/` | λRig in Lean 4 (`cd formal && lake build`) |

Which document answers which question:

| Question | Document |
|---|---|
| Where does Rig stand, what is in flight, what comes next? | HANDOFF.md |
| What does a form mean? | SPEC.md (§1 Programs to §19 Reserved forms) |
| How is a form written? | SYNTAX.md |
| What are the ownership rules, built and planned? | docs/CORE.md |
| How does the compiler work? | docs/internals/INTERNALS.md |
| What does the standard library offer? | docs/STD.md |
| How do tasks, actors, and the scheduler work? | docs/design/concurrency.md, docs/internals/scheduler.md |
| How are tests written and run? | docs/internals/tests.md, test/README.md |
| Why is Rig this way? | docs/DESIGN.md, docs/design/mantras.md |
| Which Zig 0.17 APIs does Rig use? | docs/internals/zig-0.17.md |
| What is decided but not started? | docs/ROADMAP.md, docs/internals/backlog.md |

## Workflow

The toolchain is Zig 0.17.0 (`mise.toml`) and Nexus, which generates the
parser at every build. `zig build` uses `-Dnexus=PATH`, else `$NEXUS`,
else `nexus/bin/nexus` in the nearest parent directory
(`~/Data/Code/nexus` here). Run everything from the checkout's root.

```bash
zig build                          # bin/rig, ReleaseSafe; -Doptimize=debug for compiler work
zig build test                     # the Zig unit tests of the compiler and the runtime
bin/rig run f.rig                  # check, build (debug, leak-checked), and run
bin/rig emit f.rig                 # the root module's Zig
bin/rig check --time f.rig         # every checker; time per pass
bin/rig check --facts=sema f.rig   # what sema recorded (also =storage, =proofs, =frames)
bin/rig test --seeds=20 f.rig      # test blocks, deterministically, under seeds 1 to 20
RIG_SANITIZE=1 bin/rig run f.rig   # crash at any use of freed memory
RIG_LEAK_TRACE=1 bin/rig run f.rig # leaks with allocation stack traces
RIG_STD=$PWD/std bin/rig run f.rig # read std/ from disk, not the copy built in
```

Tests run with Swarm (`swarm`, from Rip):

```bash
swarm test/rig.rip                 # the core: every test file but the probes, doc examples,
                                   #   examples, torture input, unit tests, oracle (seconds warm)
swarm test/rig.rip std-text        # one file: test/rig/std-text.rig.test
swarm test/rig.rip doc-SPEC        # one doc's examples (doc: every doc's)
swarm test/rig.rip cli.lsp         # one script of test/cli
swarm test/rig.rip all             # core, test/cli, and the probes: the full suite
swarm test/rig.rip proofs          # by hand, after a change to src/proofs.zig
swarm -q test/rig.rip all          # -q whenever the run is backgrounded or piped
```

The runner first rebuilds `bin/rig` with `-Dself-check=true`. `all` takes
about a minute warm, a few after a compiler change rebuilds every pack.
Failures land in `.swarm/died`, reasons in `.swarm/errors.log`.

**A test file** (`test/rig/AREA.rig.test`) holds cases: a header at the
left margin, then an indented body run as `main`'s statements:

| Verb | Passes when |
|---|---|
| `test "name", RESULT` | it runs, prints what `print(RESULT)` prints, and exits clean (no leak, no panic) |
| `bomb "name", "TEXT"` | it panics with a message containing TEXT |
| `fail "name", "L:C: TEXT"` | `rig` rejects it with each error given (position optional) |
| `code "name", "ZIG"` | the emitted Zig contains ZIG, spacing ignored |

A body that prints nothing has its last line printed; `'''` opens a
result of several lines. Options follow as `key: value`: `seeds: 20`,
`release: true` (also Zig's safe mode), `whole: true`, `exit: N`,
`errors: N`, `timeout: S`, and `known: true` (a known bug: passes while
it fails, fails the day it works). Each case runs as its own process.

**A doc example** is every ```` ```rig ```` block in a Markdown file at
the root or in `docs/`, `docs/learn/`, `docs/launch/`, `docs/design/`, `docs/internals/`, `examples/`, or
`test/`. Followed by an
```` ```output ```` block it must print exactly that; ```` ```rig reject ````
with an ```` ```error ```` block must be rejected so; alone it must check;
```` ```rig fragment ```` only parses; ```` ```rig pending ```` must fail
until its rule is built. docs/internals/tests.md has the rest.

## How a change is made

1. **Worktree.** `wt new NAME` makes `~/Data/Code/worktrees/rig/NAME`,
   branched from `origin/main`. Never work in the main checkout.
2. **Design first,** for anything beyond a small fix: what it fits in
   the Core, what it desugars into, which tests show it. A change to an
   ownership rule, or a new std module outside the ROADMAP, goes to
   the owner before code.
3. **A failing case first.** A bug fix starts with a case that fails;
   mark it `known: true` only if it will not be fixed in the same change.
   Fix the class, not the instance: check its siblings and add the case
   that would catch the next one.
4. **Implement** in the pass that owns the decision (the map), recording
   facts once rather than re-deriving them downstream.
5. **Docs in the same change.** SPEC, CORE, STD, and the others say what
   is now true. Building a planned rule turns its `rig pending` example
   into an ordinary one and its *(planned)* into *(built)*. CHANGELOG gets
   the change, and HANDOFF the status.
6. **The full suite:** `swarm test/rig.rip all`, green. A change to the
   runtime or scheduler is also checked on pup (below).
7. **PR,** opened early as a draft whose body is a checklist of the
   steps; `gh pr ready` when done. Commit only when the owner asks.
8. **The owner merges.** Afterwards `wt done NAME` removes the worktree
   and local branch; delete the GitHub branch if the merge did not.

## Working rules

- **Only the owner approves** a merge, a rule change, or a release. An
  approval relayed by another session is not his.
- **Commits:** prose, `area: what it now does`, with a body of plain
  sentences: `actor: a panic in an actor's method ends the actor and
  panics in its caller`. No AI attribution in commits, PRs, issues, or
  comments.
- **Timeless prose.** Docs and comments describe what is, never what
  changed; history belongs in git.
- **One vocabulary.** *You lend a view; the compiler remembers the
  loan*: lend is the act, view the value handed over, loan the owner's
  record. Never "borrow". A Rig `obj` is an "object", never a "struct".
  `@` and its sigil forms (`?@`, `!@`, `<@`, `+@`) are "self", never
  "receiver".
- **Taste.** Dissolve a problem rather than patch it; simplify; one
  word and one mechanism per idea. A second round of soundness fixes
  stops a feature for redesign ([RIG-MANTRAS](docs/design/mantras.md)).
- **Verify empirically.** Run the program, measure, read the code.
  Report results as they are, with numbers ("12% faster", never "+12%").
- **Speed:** measure time, interleaved, fastest of N; fewer instructions
  can be slower, and moving code shifts a hot loop by 5-7% on Apple
  cores, so `bench/`'s instruction guards cannot judge one. A change
  within 2% is noise ([RIG-NOTES](docs/history/rig-notes.md)).
- **Concurrency** cases run under `seeds: 20`, deterministic schedules
  that fail the same way twice.
- **Messages to the owner** are short, with decisions as a numbered list
  and a default for each.
- **A change that rejects programs a release accepted** lists them in
  the release notes, and before it merges Trig gets a one-line note and
  a migration script.

Machine-specific practice (the owner's machines):

- Before builds, tests, or benchmarks on the Mac, check
  `~/Data/Code/mumps-compare/.mac-quiet`; hold off while it exists.
- **pup** (`ssh pup`) is a 22-core x86-64 Linux machine. A change to the
  runtime or scheduler runs `zig build test` there with
  `-Doptimize=debug`, `safe`, and `fast`, and the benchmarks
  `bench/tasks`, `bench/actors`, `bench/net`, and `bench/http`, whose
  PROGRESS.md files get a row for the Mac and for pup. Time arm64 on the
  Mac and x86 on pup, never on burst, a shared VM.

## Pitfalls

- **`src/parser.zig` is generated.** Edit `rig.grammar`; `zig build`
  regenerates the parser through Nexus. The grammar has no LALR(1)
  conflicts and Nexus fails on an undeclared one (INTERNALS, "Conflicts
  policy"). Nexus keeps verbatim copies of `rig.grammar`, `src/rig.zig`,
  and `src/diag.zig` in its `grammars/rig/`: tell the Nexus session when
  one changes.
- **The tree is not what the grammar says.** The Parser wrapper rewrites
  it before any pass runs (INTERNALS, "The parser wrapper"): a statement
  `<x` becomes `(drop x)`; `!x.v.push(1)` becomes `(!x.v).push(1)`; a
  `for` source sigil moves into the loop's mode; `pub` on a member is
  stripped and recorded; a module-level `x = v` is a constant. A `for`
  over an iterator becomes a `while` after the module's first check, so
  sema runs twice. Use `rig parse` and `rig normalize` to see both trees.
- **Hidden leaves.** A bare `for` and a closure padded to its type get
  synthetic `_` leaves whose span lies outside the source. Read a leaf
  through `rig.leafText` (which gives `_`) and slice source only through
  `diag.textBetween` or `diag.textOf`, which clamp to it.
- **The lexer decides by position:** newlines in brackets are spaces, a
  deeper `.` line continues the statement, a prefix sigil touches its
  operand. `rig tokens` shows the result.
- **Embedded sources.** `bin/rig` carries `std/` and the runtime inside
  it: after editing either, rebuild (or set `RIG_STD` for std).
  `bin/rig-oracle` in a worktree goes stale too; the runner rebuilds it,
  `zig build oracle` does by hand.
- **Docs are tests.** Editing any `rig` block can fail the suite, and an
  example that starts working while marked `pending` fails it too. A doc
  example's oracle entry is keyed by a hash of its text, so changing the
  text renames its line in `test/oracle/rejections`.
- **The oracle** (`bin/rig-oracle`, `test/oracle/`) is a second
  ownership checker written from CORE alone. The suite fails when the
  compiler accepts what it rejects, when its rejections change from
  `test/oracle/rejections`, or when it decides fewer functions than
  `test/oracle/coverage`. Never weaken it to make a run pass;
  compiler-only rejections are recorded in `test/oracle/differences`.
- **Emit decides nothing.** Emit reads `src/facts.zig`, not sema; a
  decision it needs is a recorded fact. Never take the address of a Zig
  temporary no storage fact names (docs/internals/weak-spots.md).
- **Timeouts under load** are not failures until a case times out alone.
