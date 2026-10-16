# AGENTS.md — working on Rig

Read this before changing anything. It is short on purpose. Where
Rig stands and what comes next is in [HANDOFF.md](HANDOFF.md); read
that first. The short phrases we steer by are in
[docs/RIG-MANTRAS.md](docs/RIG-MANTRAS.md).

## North star

Rig is a fast, indentation-sensitive systems language that compiles
to Zig. Its grammar is written for **Nexus** (`rig.grammar` →
`src/parser.zig`). A small algebra of sigils makes ownership visible
where it happens, so memory safety reads more cleanly than in Rust:

| Sigil | Meaning |
|---|---|
| `<x` | move; as a statement, drop now |
| `?x` / `?T` | lend to read / read view |
| `!x` / `!T` | lend to write / write view |
| `+x` | clone |
| `^x` / `^T` | box (one owner on the heap) |
| `*x` / `*T` | shared (refcounted) |
| `~x` / `~T` | weak |
| `expr!` / `T!` | propagate failure / fallible type |
| `expr?` / `T?` | propagate `none` / optional type |

Everything else aims for the readability of Python and Ruby, the
cost model of Zig and C, and the safety of Rust: no GC, no hidden
allocation, no hidden refcount traffic, no silent control flow.

## Rules

1. **We test and verify everything we say.** A feature exists when a
   program using it runs and prints the right thing, with no leaks and
   no use of freed memory under the sanitizing allocator. A rejection
   exists when a
   `test/reject` test or a ```` ```rig reject ```` doc example proves
   it. Docs make no claims the test suite does not check, and every
   `rig` example in the docs is run by `./test/run` (see
   `test/README.md`). A rule that is decided but not built is shown
   with a ```` ```rig pending ```` example, which the suite checks does
   not work yet.
2. **Accept means correct.** If `rig check` accepts a program, the
   emitted Zig compiles, runs, and does what the source says. Anything
   the compiler cannot lower correctly is rejected in sema with a Rig
   diagnostic (file:line:col). Never emit `@compileError` placeholders
   and never drop a construct silently.
3. **Safe code cannot corrupt memory.** Use-after-move, double-free,
   use-after-free, dangling views, and leaks in safe Rig are
   compiler bugs. Only code inside `raw` may break these guarantees.
   The one leak the compiler does not prevent is a cycle of strong
   `*T` handles, as in Rust and Swift; `~T` exists to break cycles,
   and every test and example must still run leak-free.
4. **Effects stay visible.** Every sigil survives as a named node in
   the semantic IR (`docs/INTERNALS.md`), which the checkers and emitter
   consume by name. Don't add features that hide moves, clones,
   allocation, failure, or mutation.
5. **Substrate in the language, libraries in userland.** No GC, no
   macros, no built-in reactive framework.
6. **Never edit the generated parser.** `src/parser.zig` is generated
   at build time from `rig.grammar` and is not tracked; edit the
   grammar (see Workflow). The
   grammar's `@schema` declares every IR node and its roles; the
   compiler reads the tree through the generated accessors
   (`parser.ir`), by role, never by position. Grammar conflicts must
   be understood: every conflict that remains is listed and justified
   in `docs/INTERNALS.md`.
7. **Comments explain the code as it is.** Milestone history,
   design-chat references, and changelogs belong in git history.

## How we build

These keep soundness a property of the compiler's structure, not of
review rounds.

- **A feature fits the Core.** `docs/CORE.md` states the ownership
  model. A feature that touches ownership fits it in one paragraph,
  with no exception list, or changes the Core first; a rule the Core
  does not imply is a bug.
- **One classifier per fact.** Whether an expression is a place, a
  fresh owned value, a lend, or a view is decided once, by a positive
  list, and recorded as a fact. No category is defined as "not" another,
  and no pass re-derives one from syntax.
- **The checker checks exactly what is emitted.** Emit adds no
  temporary, evaluation order, re-evaluation, or drop that the
  ownership checker did not walk.
- **Leaving a scope never silently forgets a loan.** Every path out
  of a scope (a jump, a failing condition or guard, an error) reports
  the loans it discards.
- **A feature is specified as a desugaring.** A feature that touches
  ownership or lifetimes states its desugaring into existing forms in
  `docs/INTERNALS.md`; its checker rule is the one the desugaring
  implies.
- **Fix the class, not the instance.** A soundness fix names its class,
  lists the sibling sites it checked, and adds a test that would catch
  a sibling (`test/matrix.py` finds many).
- **A second soundness round stops the feature.** A feature that needs
  a second round of soundness fixes stops for a redesign.
- **One branch at a time per fact or classifier.** Branches may change
  `src/ownership.zig` or typecheck's classification of expressions at
  once only if they touch different facts or classifiers. Each later
  branch to merge first passes the full gates on the combined tree:
  main with the earlier branches merged, plus it.
- **Land fast, release deep.** A round lands through the fast gate, in
  minutes: the build, `./test/run --delta`, the round's new tests, a
  targeted grid of the forms it changes, and one independent review run
  in parallel with them, then `tools/gate`, whose verdict is the merge
  check ("How merging works" below). A round that changes a soundness
  classifier (`src/ownership.zig`, the facts or proofs walks, or
  typecheck's classification of expressions) also runs the full
  matrix. The deep gate runs on `main` as it stands, about twice a day:
  the full suite, corpus, matrix, and unit tests, equivalence against
  the last deep run, the JSON benchmark guard, and the
  generated grids in debug and `--release` on macOS and Linux. A deep
  gate failure is bisected and fixed before any new round lands. A
  release is tagged only after a clean deep gate and an adversarial
  review of everything merged since the last release.
- **Rerun only what changed.** A grid or corpus rerun uses `--delta`
  (`./test/run --delta`, `test/matrix.py --delta`): it checks every
  program, and runs only those whose package, expectation, driver,
  harness, or Zig differ from a run that passed (test/README.md,
  "Rerunning only what changed").
- **Reviewer probes are kept** in `test/corpus/`.
- **"Runs clean" means sanitizer-clean:** no leak and no use of freed
  memory under `RIG_SANITIZE=1`, which `./test/run` sets.

## Workflow

```bash
zig build                  # builds bin/rig (ReleaseSafe; -Doptimize=debug for compiler work)
./test/run -j 2            # full suite; must be green before every commit
./test/run -j 2 corpus     # every reviewer probe, not only the default sample
test/matrix.py -j 2        # form x context x type programs, checked and run
./test/run json            # std.json against Python on all 10,511 inputs (tools/fetch-json-data.sh first)
zig build oracle           # builds bin/rig-oracle (./test/run does it too)
zig build test --cache-dir "$(mktemp -d)"  # unit tests, not replayed from cache
bin/rig run file.rig       # compile + run (debug, leak-checked)
bin/rig emit file.rig      # the emitted Zig
bin/rig check --time file.rig              # the time each compiler pass takes
bin/rig test file.rig      # run the file's own `test` blocks
bin/rig build --release -o prog file.rig   # optimized executable (safe)
RIG_LEAK_TRACE=1 bin/rig run file.rig      # leaks with allocation stack traces
RIG_SANITIZE=1 bin/rig run file.rig        # crash at any use of freed memory
RIG_NO_CRASH_REPORT=1 ./prog              # no crash report (macOS) or apport (Linux) if it dies (test harnesses)
tools/gate                 # test the pushed head on burst, and post the merge check rig/gate
```

- Nexus: Rig and Nexus are co-developed. Every `zig build` target
  generates `src/parser.zig` from `rig.grammar` with `nexus/bin/nexus`
  in the nearest parent directory, normally `../nexus/bin/nexus` beside
  this checkout, and regenerates it only when the grammar or that binary
  changes. Any Nexus will do, built from the sibling checkout's main
  (`zig build -Doptimize=safe` there). Without one the build fails and
  says where it looked. To use another binary: `zig build -Dnexus=PATH`.
- The machines are shared: run a full run, a grid, or a corpus pass
  through the machine's job queue (`cpuq run --cores 2 -- …`, with
  `-j "$CPUQ_CORES"`), which shares the CPUs fairly instead of waiting
  on the load. Start a job only when no one else is waiting, and send
  long full runs to the Linux machine, one at a time. Pass `-j` to
  `zig build` there too; without it Zig uses every CPU. Under load,
  rerun a timeout failure alone before trusting it. A wait loop watches
  only its own job, and every loop has a bound.
- Fixing a bug starts with a failing test that reproduces it.
- Every change keeps `./test/run` green.
- Commit messages are short, imperative, and describe the change.
  No AI attribution lines.

## How merging works

Burst tests a pull request; GitHub's runners do not test it again.

1. Merge `origin/main` into the branch, push, and open the pull request.
2. From the branch's clean worktree, run `tools/gate`. It submits the
   suite, the corpus and the matrix to burst (`cpuq/*.json`, each a
   `--delta` run), and when all pass it posts the commit status
   `rig/gate`, success, on the exact commit they tested.
3. The required checks, `test (ubuntu-latest)` and `test (macos-latest)`,
   come from `.github/workflows/gate.yml`, which reads that status and
   nothing else; `tools/gate` re-runs it, so they turn green within
   seconds. A push after the gate has no status, and its checks fail
   until `tools/gate` passes on it.
4. Only Steve merges.

A pull request from a fork is tested in full on GitHub's runners
(`.github/workflows/test.yml`), which also runs the whole suite cold on
`main` nightly, on Ubuntu and macOS, and by hand (test/README.md, "The
merge gate and CI").

## Map

| Path | Role |
|---|---|
| `HANDOFF.md` | Where Rig stands, the work that comes next, the gates, and whom to ask |
| `TODO.md` | Work decided but not started |
| `rig.grammar` | Nexus grammar: syntax, and the IR schema every node follows |
| `src/rig.zig` | Lexer and parser wrappers (layout, position, IR rewrites) |
| `src/diag.zig` | Diagnostics: spans, line and column, the printed format |
| `src/parser.zig` | Generated at build time from `rig.grammar`, not tracked: lexer, parser, IR tags and accessors |
| `src/modules.zig` | Module graph and `use` resolution |
| `src/sema.zig` | Semantic analysis front door: types, symbols, drop glue, the facts table |
| `src/resolve.zig` | Declaration pass: builtins, names, type resolution |
| `src/typecheck.zig` | Expression pass: types every expression, records facts, checks fallibility and the `raw` boundary |
| `src/storage.zig` | Storage facts: the hidden storage emit makes, decided once |
| `src/ownership.zig` | Move / loan / drop checking |
| `src/nametable.zig` | The table a plain enum's `from_text` finds a name in, built by the compiler and emitted as data, which `rig.NameTable` reads |
| `src/inlining.zig` | Which small functions are emitted `inline`, decided once for the whole program |
| `src/proofs.zig` | Proven checks: the index, byte-access, and add tests a guard or check already made, which emit omits |
| `src/facts.zig` | What emit may know: the recorded facts, read-only; emit imports no classifier |
| `src/emit.zig` | Zig code generation |
| `src/runtime.zig` | Runtime support shipped with every program (embedded by `src/emit.zig`) |
| `src/main.zig` | CLI |
| `src/lsp.zig` | `rig lsp`, the language server (editors/README.md) |
| `src/editor.zig` | What an editor shows of one file: classified tokens, outline, folds, parse errors |
| `src/lib.zig` | The compiler as a library, for `bin/rig-oracle` only |
| `tools/` | `migrate-0.3.py`, which migrates 0.2 programs to 0.3; `gen-unicode.py`, which writes `std/unicode_tables.zig` and `std/grapheme_tables.zig` (the classes behind `std/grapheme.zig`, the chars of `std.text`) from the pinned Unicode data, and `verify-unicode.py`, which checks it (`RIG_UCD`, docs/STD.md) |
| `test/` | The test suite (see `test/README.md`) |
| `test/corpus/` | Reviewer probes: each is rejected, or runs sanitizer-clean |
| `test/oracle/` | The reference ownership checker, `bin/rig-oracle`, and its classified differences |
| `test/json/` | `std.json` against Python's `json` module, run by `./test/run json` (see `test/json/README.md`) |
| `tools/fetch-json-data.sh` | Fetches the third-party JSON files that test reads, pinned by sha256, into the untracked `test/json/data/` |
| `tools/gate` | Tests a pull request's pushed head on burst and posts the merge check `rig/gate` ("How merging works") |
| `.github/workflows/` | `gate.yml`, the required checks, read from `rig/gate`; `test.yml` and `shards.yml`, the whole suite cold on GitHub's runners (nightly, by hand, and for forks) |
| `bench/json/` | The JSON benchmark: Rig and Zig builds, and the Rust and Zig competitors (not in CI; see `bench/json/README.md`) |
| `bench/names/` | The name lookup benchmark: `from_text`'s table against comparing names one by one (not in CI) |
| `bench/check/` | The check-speed guard: `rig check`'s instructions, pass times (`rig check --time`), and scaling on generated programs (not in CI; see `bench/check/guard.py`) |
| `bench/print/` | The print-size guard: the machine code one `print` adds in `--release=fast`, against a recorded bound (not in CI; see `bench/print/guard.py`) |
| `examples/` | Curated example programs, all run by the suite |
| `std/` | The standard library: Rig modules and the Zig behind their Zig-backed declarations |
| `docs/CORE.md` | The ownership model on one page, which every other doc must agree with |
| `docs/QUICK.md` | The sigils and ownership on one short page, for a newcomer or a model's prompt |
| `README.md` | Overview and a short tour |
| `WELCOME.md` | Guide for programmers coming from other languages |
| `SYNTAX.md` | How every form is written, and the grammar summary |
| `SPEC.md` | Language reference: what every form means |
| `FAQ.md` | Common questions |
| `docs/STD.md` | The standard library's modules |
| `docs/TEXT.md` | Text: bytes, runes, units, and chars, how each is measured, and the modules for each |
| `docs/TEXT-API.md` | Every name of the text API in one list, with its signature and whether it is built |
| `docs/DESIGN.md` | Principles and rationale |
| `docs/RIG-MANTRAS.md` | The short phrases we steer by: how we choose, build, name, and measure |
| `docs/BEYOND-RUST.md` | What Rig changes for a Rust programmer |
| `docs/RUST-TRIAGE.md` | What Rig should take from Rust and what it should leave, sorted by priority: a plan, not a description of the compiler |
| `docs/INTERNALS.md` | Compiler architecture, the IR, the runtime |
| `docs/ROADMAP.md` | Future directions |
| `docs/json/` | The JSON parser's design, its open items, and the measurement record |
| `docs/simd/` | The design for portable vectors (`Simd`): proposal, Zig lowering, opcodes, and the Zig probes behind them |
| `docs/RIG-EMDB-WASM.md` | A plan, nothing built: Rig and emdb on WebAssembly, a Rig binding to emdb, and later emdb's core in Rig |
| `IDEAS.md` | Suggestions for improving Rig, led by the bar it must clear: shorter and plainer than idiomatic Rust |
| `docs/RIG-NOTES.md` | Weak, missing, and inconsistent spots in Rig that the work on std.json found, each with its cost and a fix to consider |
| `docs/zig-0.17.md` | Zig 0.17 for Rig contributors: the language, std, and build APIs Rig uses |
