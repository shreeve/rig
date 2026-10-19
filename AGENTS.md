# AGENTS.md — working on Rig

Start here. [HANDOFF.md](HANDOFF.md) has where Rig stands right now and
what comes next.

## What Rig is

Rig is a fast, indentation-sensitive systems language that compiles to
Zig. Its grammar is written for **Nexus** (`rig.grammar` →
`src/parser.zig`). A small set of sigils makes ownership visible at the
point where it happens:

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

The aim: the readability of Python and Ruby, the cost model of Zig and
C, and the safety of Rust. No GC, no hidden allocation, no hidden
refcount traffic, no silent control flow. The ownership model is one
page: [docs/CORE.md](docs/CORE.md).

## What the compiler must guarantee

These are about the compiler, not the process. They don't bend.

1. **Accept means correct.** If `rig check` accepts a program, the
   emitted Zig compiles, runs, and does what the source says. Anything
   it can't lower correctly is rejected with a Rig diagnostic. Never an
   `@compileError` placeholder, and never a construct silently dropped.
2. **Safe code cannot corrupt memory.** Use-after-move, double-free,
   use-after-free, dangling views, and leaks in safe Rig are compiler
   bugs. Only `raw` code may break this. "Runs clean" means clean under
   `RIG_SANITIZE=1`, which the test runners set.
3. **Effects stay visible.** Every sigil survives as a named node in the
   IR. No feature hides a move, clone, allocation, failure, or mutation.
4. **One classifier per fact.** Whether an expression is a place, a fresh
   value, a lend, or a view is decided once and recorded. The checker
   checks exactly what emit produces.
5. **Ownership features fit the Core.** A change that touches ownership
   fits `docs/CORE.md` in a paragraph, or changes the Core first.
6. **Never edit `src/parser.zig`.** It is generated from `rig.grammar`.
7. **Docs claim only what runs.** Every `rig` example in the docs is run
   by `swarm test/rig.rip`; a planned rule uses a ```` ```rig pending ```` block.
8. **Words:** lend, view, loan, ownership checker; never "borrow". A
   Rig `obj` is an "object", never a "struct". Comments describe the
   code as it is; history belongs in git.

## How we work

### Show what you're doing

- **One PR per piece of work, opened early.** Push your first commit
  early and open the PR as a draft, so the checklist has a home. Its
  body is a checklist of the steps; tick each one as it lands. `gh pr
  list` is the board of work in progress. When the work is done, mark
  it ready with `gh pr ready`.
- **One worktree per branch:** `wt new BRANCH` makes it under
  `~/Data/Code/worktrees/rig/`; `wt done` removes it after the merge.
  Never work in the main checkout; it's Steve's.
- **Say what you're doing.** One line when you start a step, one when it
  finishes or fails: what's done, what's next, what you're waiting on.
- **Stuck? Say so.** After two failed attempts at the same thing, stop
  and report what you tried. Don't loop silently.
- **Long jobs:** anything over two minutes runs in the background. Say
  what it is and roughly how long it takes.

### Testing

Tests are cases in `test/rig/*.rig.test` (docs/RIG-TESTS.md): `code`,
`fail`, `test`, and `bomb`, each a few lines of Rig and its result. Run
them with `swarm test/rig.rip`: a run with no
names is the core, every file but the probes of past reviews, the doc
examples, the unit tests, and the oracle, in seconds when little
changed; name files to run just those, `doc` for the doc examples,
`cli` for the scripts of `test/cli` (minutes), `probes` for the
probes' cases, `all` for all three, and `proofs` by hand after a change
to the proofs (`test/README.md`). A bug fix starts with a case that
fails. There are no gates or required runs: run more when you judge the
change needs it. Never time on burst, a shared VM: time arm64 on
the Mac and x86 on pup.

### Spend tokens well

- Use Sonnet for routine work and the top model for design and
  soundness.
- At most 3 agents at a time. Agent reports stay under 300 words.
- Don't rerun tests that passed, don't re-read files you already have,
  and don't relay FYIs between sessions.
- When something is Steve's call, ask him with a numbered list of
  decisions and a default for each.

### Commits and merging

- Commit messages are short and imperative. No AI attribution lines.
- Before a PR that rejects old syntax merges, send Trig a one-line note
  and a migration script.
- Merge your own PR when the work is done. After a merge, `wt done`
  removes the worktree and the local branch; delete the GitHub branch if
  the merge didn't.
- **Plain git.** No GitHub Actions, no gates, no required checks, no
  commit statuses. Don't add any unless Steve asks.

## Workflow

```bash
zig build                          # bin/rig (ReleaseSafe; -Doptimize=debug for compiler work)
bin/rig run file.rig               # compile and run (debug, leak-checked)
bin/rig emit file.rig              # the emitted Zig
bin/rig check --time file.rig      # time per compiler pass
swarm test/rig.rip                 # the core: every test file, the docs, examples, unit tests
swarm test/rig.rip std-text        # one test file, test/rig/std-text.rig.test
swarm test/rig.rip all             # the core, the scripts of test/cli, and the probes
swarm test/rig.rip doc             # the doc examples
swarm test/rig.rip cli.lsp         # one script of test/cli
RIG_LEAK_TRACE=1 bin/rig run f.rig # leaks with allocation stack traces
```

- **Nexus** is co-developed. `zig build` regenerates `src/parser.zig`
  with `../nexus/bin/nexus`, or another binary with `-Dnexus=PATH`.
- **Timeouts:** under load, rerun a timeout alone before trusting it.

## Map

| Path | Role |
|---|---|
| `HANDOFF.md` | Where Rig stands and what comes next |
| `rig.grammar` | Nexus grammar: syntax and the IR schema |
| `src/sema.zig`, `resolve.zig`, `typecheck.zig` | Semantic analysis |
| `src/ownership.zig` | Move, loan, and drop checking |
| `src/facts.zig`, `storage.zig`, `proofs.zig` | Facts recorded once, read by emit |
| `src/emit.zig`, `runtime.zig` | Zig code generation and runtime |
| `src/main.zig`, `lsp.zig` | CLI and language server |
| `std/` | The standard library |
| `test/rig/` | The tests, as `.rig.test` files (docs/RIG-TESTS.md), run by `test/rig.rip` |
| `test/` | The rest of the suite; `test/README.md` explains it |
| `tools/` | Generators and migration scripts |
| `examples/` | Example programs, all run by the suite |
| `docs/CORE.md` | The ownership model on one page |
| `docs/INTERNALS.md` | Compiler architecture and the IR |
| `SPEC.md`, `SYNTAX.md` | What every form means and how it's written |
