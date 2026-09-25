# AGENTS.md — working on Rig

Read this before changing anything. It is short on purpose.

## North star

Rig is a fast, indentation-sensitive systems language that compiles
to Zig. Its grammar is written for **Nexus** (`rig.grammar` →
`src/parser.zig`). A small algebra of sigils makes ownership visible
where it happens, so memory safety reads more cleanly than in Rust:

| Sigil | Meaning |
|---|---|
| `<x` | move |
| `?x` / `?T` | read borrow |
| `!x` / `!T` | write borrow |
| `+x` | clone |
| `-x` | drop now |
| `*x` / `*T` | shared (refcounted) |
| `~x` / `~T` | weak |
| `expr!` / `T!` | propagate failure / fallible type |
| `expr?` / `T?` | propagate `none` / optional type |

Everything else aims for the readability of Python and Ruby, the
cost model of Zig and C, and the safety of Rust: no GC, no hidden
allocation, no hidden refcount traffic, no silent control flow.

## Rules

1. **We test and verify everything we say.** A feature exists when a
   program using it runs and prints the right thing, with no leaks
   under the checking allocator. A rejection exists when a
   `test/reject` test or a ```` ```rig reject ```` doc example proves
   it. Docs make no claims the test suite does not check, and every
   `rig` example in the docs is run by `./test/run` (see
   `test/README.md`).
2. **Accept means correct.** If `rig check` accepts a program, the
   emitted Zig compiles, runs, and does what the source says. Anything
   the compiler cannot lower correctly is rejected in sema with a Rig
   diagnostic (file:line:col). Never emit `@compileError` placeholders
   and never drop a construct silently.
3. **Safe code cannot corrupt memory.** Use-after-move, double-free,
   use-after-free, dangling borrows, and leaks in safe Rig are
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
6. **Never edit `src/parser.zig` by hand.** Edit `rig.grammar` and
   run `zig build parser` (Nexus 1.0.0 or later; see Workflow). The
   grammar's `@schema` declares every IR node and its roles; the
   compiler reads the tree through the generated accessors
   (`parser.ir`), by role, never by position. Grammar conflicts must
   be understood: every conflict that remains is listed and justified
   in `docs/INTERNALS.md`.
7. **Comments explain the code as it is.** Milestone history,
   design-chat references, and changelogs belong in git history.

## Workflow

```bash
zig build                  # builds bin/rig
./test/run                 # full suite; must be green before every commit
bin/rig run file.rig       # compile + run (Debug, leak-checked)
bin/rig emit file.rig      # the emitted Zig
bin/rig test file.rig      # run the program's `test` blocks
bin/rig build --release -o prog file.rig   # optimized executable (ReleaseSafe)
RIG_LEAK_TRACE=1 bin/rig run file.rig      # leaks with allocation stack traces
```

- Nexus: `zig build parser` and `./test/run` (whose parser check
  regenerates `src/parser.zig` and compares) use `nexus/bin/nexus` in
  the nearest parent directory, normally `../nexus/bin/nexus` beside
  this checkout. It must be Nexus 1.0.0 or later; an older build there
  fails generation or the parser check. To use another binary, name it
  in both places: `zig build parser -Dnexus=PATH` and
  `NEXUS=PATH ./test/run`.
- Fixing a bug starts with a failing test that reproduces it.
- Every change keeps `./test/run` green.
- Commit messages are short, imperative, and describe the change.
  No AI attribution lines.

## Map

| Path | Role |
|---|---|
| `rig.grammar` | Nexus grammar: syntax, and the IR schema every node follows |
| `src/rig.zig` | Lexer and parser wrappers (layout, spacing, IR rewrites) |
| `src/diag.zig` | Diagnostics: spans, line and column, the printed format |
| `src/parser.zig` | Generated — do not edit: lexer, parser, IR tags and accessors |
| `src/modules.zig` | Module graph and `use` resolution |
| `src/sema.zig` | Semantic analysis front door: types, symbols, drop glue, the facts table |
| `src/resolve.zig` | Declaration pass: builtins, names, type resolution |
| `src/typecheck.zig` | Expression pass: types every expression, records facts, checks fallibility and the `raw` boundary |
| `src/ownership.zig` | Move / borrow / drop checking |
| `src/emit.zig` | Zig code generation |
| `src/runtime.zig` | Runtime support shipped with every program (embedded by `src/emit.zig`) |
| `src/main.zig` | CLI |
| `test/` | The test suite (see `test/README.md`) |
| `examples/` | Curated example programs, all run by the suite |
| `SPEC.md` | Language reference |
| `docs/DESIGN.md` | Principles and rationale |
| `docs/INTERNALS.md` | Compiler architecture, the IR, the runtime |
| `docs/ROADMAP.md` | Future directions |
| `docs/zig-0.16.md` | Zig 0.16 for Rig contributors: the language, std, and build APIs Rig uses |
