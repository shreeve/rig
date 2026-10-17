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
   `RIG_SANITIZE=1`, which `./test/run` sets.
3. **Effects stay visible.** Every sigil survives as a named node in the
   IR. No feature hides a move, clone, allocation, failure, or mutation.
4. **One classifier per fact.** Whether an expression is a place, a fresh
   value, a lend, or a view is decided once and recorded. The checker
   checks exactly what emit produces.
5. **Ownership features fit the Core.** A change that touches ownership
   fits `docs/CORE.md` in a paragraph, or changes the Core first.
6. **Never edit `src/parser.zig`.** It is generated from `rig.grammar`.
7. **Docs claim only what runs.** Every `rig` example in the docs is run
   by `./test/run`; a planned rule uses a ```` ```rig pending ```` block.
8. **Words:** lend, view, loan, ownership checker; never "borrow". A
   Rig `obj` is an "object", never a "struct". Comments describe the
   code as it is; history belongs in git.

## How we work

### Show what you're doing

- **One PR per piece of work, opened early.** Push your first commit
  early and open the PR as a draft, so the checklist has a home. Its
  body is a checklist of the steps; tick each one as it lands. `gh pr
  list` is the board of work in progress. When the work is done, mark
  it ready with `gh pr ready`; `tools/gate` refuses a draft.
- **One worktree per branch:** `wt new BRANCH` makes it under
  `~/Data/Code/worktrees/rig/`; `wt done` removes it after the merge.
  Never work in the main checkout; it's Steve's.
- **Say what you're doing.** One line when you start a step, one when it
  finishes or fails: what's done, what's next, what you're waiting on.
- **Stuck? Say so.** After two failed attempts at the same thing, stop
  and report what you tried. Don't loop silently.
- **Long jobs:** anything over two minutes runs in the background. Say
  what it is and roughly how long it takes.

### Test in two steps

**1. Smoke test on the Mac, while you work.** `tools/check N` runs the
branch's own tests, the whole-program checks, and N% of the suite,
chosen at random, on this Mac:
`tools/check 1` is about 40 tests, `tools/check 5` about 200, and
`tools/check 20` about 800. Use it as often as you like. It runs on
the Mac by default, not on a remote host: it is how we learn whether a
change is worth sending to a remote host at all. `tools/check N --on
HOST` runs the same check on HOST (burst or pup), through `cpuq submit`,
when Steve asks. A bug
fix starts with a test that fails; `./test/run --delta <ids>` reruns
just the tests you name.

**2. Full test on burst, when we're happy.** Only when Steve asks, never
by rule on every PR:

- `tools/gate` tests a PR's pushed head: the suite and the corpus, plus
  the matrix when the PR touches a file in `tools/gate`'s
  `MATRIX_PATHS`: `facts`, `storage`, `proofs`, `emit`, `ownership`,
  `sema`, and `runtime` in `src/`, and the matrix's own files. It
  skips a PR that touches no code or harness.
- `tools/deep` tests everything merged on `main`: the suite, the corpus,
  and the full matrix. When it fails, `tools/deep --bisect` finds the
  merge that broke it, and the fix goes in on a new branch.

A full suite never runs on the Mac; when Steve asks, `cpuq submit
cpuq/suite.json` runs it on burst (test/README.md, "The tiers").

Never time on burst, a shared VM: time arm64 on the Mac and x86 on pup,
through `cpuq lease pup-bench`.

**Nothing else runs unless Steve asks:** no full local suite, corpus,
matrix, `./test/run json`, benchmark or check-speed guards, review
agents, or expert panels. Two cases get an offer, not a run:

- A change to a `src/` file in `MATRIX_PATHS`: offer Steve one review
  agent. Reviews have caught memory bugs every test passed.
- Two open PRs that touch the same `MATRIX_PATHS` file: say so in
  both, and before the second merges, offer a gate with the first
  merged into it.

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
- Only Steve merges. After a merge, `wt done` removes the worktree and
  the local branch; delete the GitHub branch if the merge didn't.

## Workflow

```bash
zig build                          # bin/rig (ReleaseSafe; -Doptimize=debug for compiler work)
bin/rig run file.rig               # compile and run (debug, leak-checked)
bin/rig emit file.rig              # the emitted Zig
bin/rig check --time file.rig      # time per compiler pass
./test/run --delta <ids>           # the tests you name, skipping unchanged passes
RIG_LEAK_TRACE=1 bin/rig run f.rig # leaks with allocation stack traces

tools/check 1                      # smoke test on the Mac: branch tests + 1% of the suite
tools/check 5                      #   ... + 5%
tools/check 20                     #   ... + 20%
tools/check 1 --on burst           #   the same, on burst (when Steve asks)
tools/gate                         # a PR on burst (when Steve asks)
tools/deep                         # all of main on burst (when Steve asks)
```

- **Nexus** is co-developed. `zig build` regenerates `src/parser.zig`
  with `../nexus/bin/nexus`, or another binary with `-Dnexus=PATH`.
- **Shared machines:** cpuq places work by when it will finish, on the
  Mac, pup, or burst. Run work through `cpuq run --label rig:NAME -- …`
  with `-j "$CPUQ_CORES"`, and keep the label stable. Add `--local` only
  for macOS behaviour, timing, or `tools/check`. A suite or matrix goes
  through `cpuq submit cpuq/suite.json --note "#PR branch"` (or
  `matrix.json`). Never ssh to pup or burst; use `--spill-to HOST`.
  Limit test programs with `cpuq cap`, not a watchdog. Under load,
  rerun a timeout alone before trusting it.

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
| `test/` | The suite; `test/README.md` explains it |
| `tools/` | `check`, `gate`, and `deep`: the test tiers |
| `cpuq/` | The job specs `cpuq submit` runs on burst |
| `examples/` | Example programs, all run by the suite |
| `docs/CORE.md` | The ownership model on one page |
| `docs/INTERNALS.md` | Compiler architecture and the IR |
| `SPEC.md`, `SYNTAX.md` | What every form means and how it's written |
