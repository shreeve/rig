# Rig test suite

```bash
./test/run                 # everything (parallel)
./test/run ownership       # only tests whose id contains "ownership"
./test/run -v known/emit   # list each result, including known failures
./test/run --update ir     # rewrite IR snapshots after an intended grammar change
```

The summary line reads `N passed, M failed, K known`. The suite is green
when nothing fails and no known-failing test has started passing. A
filter that selects nothing exits 2.

The runner needs GNU `timeout` (on macOS, `gtimeout` from `brew install
coreutils`). `ZIG` names the Zig executable, `RIG_TEST_TIMEOUT` the
seconds each test may take (default 120), and `RIG_TEST_OUT` the
directory for emitted packages (see [Output](#output)).

## Layout

| Path | Contract |
|---|---|
| `test/behavior/<area>/<name>.rig` | `rig run` exits 0, no leaks, stdout equals the `# expect:` block |
| `test/reject/<area>/<name>.rig` | `rig check` exits non-zero with `file:line:col` diagnostics whose messages contain each `# error:` text |
| `test/known/<area>/<name>.rig` | a known bug, written as a behavior or reject test of the *correct* behavior |
| `examples/<name>.rig` | curated showcase programs; same contract as `behavior/` |
| `test/ir/<name>.rig` | raw and semantic IR snapshots (`<name>.raw.sexp`, `<name>.sem.sexp`) |
| `test/torture/<name>.rig` | bad input: `rig run` must reject it with a `file:line:col` diagnostic, never crash |
| `test/cli/<name>.sh` | a bash script exercising the `rig` commands; passes when it exits 0 (see below) |
| `unit` | `zig build test` |
| `parser` | `src/parser.zig` matches what Nexus generates from `rig.grammar` |
| `doc/<file>/L<n>` | the ```` ```rig ```` block at line `n` of a Markdown file (see below) |

Areas: `syntax`, `types`, `effects`, `ownership`, `emit`, `runtime`, `modules`.
A multi-file test is a directory `<name>/` with an entry `main.rig`; the
directives go in `main.rig`.

One file per test, discovered automatically; there is no list to edit.

## Directives

Directives are whole-line comments.

```rig
sub main()
  print 42
  print "done"

# expect:
# 42
# done
```

- `# expect:` starts the expected-stdout block. Each following `#` line is
  one line of output (`# ` is stripped; a bare `#` is an empty line). The
  block ends at the first non-comment line. With no block, stdout must be
  empty.
- `# expect-panic: <text>` — the program must exit non-zero with `<text>`
  on stderr. An `# expect:` block, if present, still checks stdout.
- `# error: <text>` — makes the file a rejection test. Repeat the line to
  require several diagnostics. `# error: L:C: <text>` also requires the
  diagnostic to be at line `L`, column `C`.

## Doc examples

Every ```` ```rig ```` block in the Markdown files (`*.md`, `docs/`,
`examples/`, `test/`) is a test, so the docs cannot drift from the
compiler. The word after `rig` on the opening fence sets the contract:

| Fence | Contract |
|---|---|
| ```` ```rig ```` | a program `rig check` accepts |
| ```` ```rig ```` followed by ```` ```output ```` | run like a behavior test: stdout equals the output block, no leaks |
| ```` ```rig reject ```` followed by ```` ```error ```` | `rig check` rejects it; each line of the error block appears in a diagnostic |
| ```` ```rig fragment ```` | only parsed; for snippets that are not whole programs |
| ```` ```rig facts ```` followed by ```` ```facts ```` | `rig check --facts` accepts it and prints exactly the facts block |
| ```` ```rig file=name.rig ```` | module `name.rig`, written next to the next example, which can `use name` |

Blank lines may separate a block from its `output` or `error` block. A
failure is reported with the id `doc/<file>/L<line>`, naming the line of
the opening fence; `./test/run doc` runs only the doc examples.

## Leak checking

`rig run` builds in Debug mode, where the runtime records every live
allocation (address and size, no stack traces). The emitted `main`
defers `rig.finish()`, which prints
`error: rig: memory leak detected: N allocations (B bytes) never freed`
and exits 1 if anything is still allocated. A double free or a free of
memory that was never allocated panics. A behavior test therefore fails
on any leak or double free. To see where leaked memory was allocated,
run the test again by hand with `RIG_LEAK_TRACE=1 bin/rig run file.rig`:
the runtime then allocates through Zig's `DebugAllocator`, which prints
a stack trace for each leak.

## CLI tests

Each `test/cli/<name>.sh` runs in an empty directory with `RIG` (the
compiler), `ROOT` (the checkout), and `RIG_OUT_DIR` set, sources
`test/cli/_lib.sh` for `fail`, `expect_eq`, `expect_has`, and
`expect_rc`, writes the programs it needs with heredocs, and passes when
it exits 0. Files starting with `_` are helpers, not tests.

## Known bugs

`test/known/` is the work queue. Each file is written as a behavior or
reject test of the correct behavior, and its header also says what goes
wrong today. Fix the bug, run the suite, and the test reports `FIXED`;
move it into `test/behavior/` or `test/reject/` under the same area in
the same commit, and drop the note about the bug from its header: tests
outside `known/` describe current behavior only.

## Output

`rig run` writes emitted Zig to `$RIG_OUT_DIR` when set. The suite uses
`.zig-cache/rig-test/<id>/`, or `$RIG_TEST_OUT/<id>/` (a CLI test's
scratch directory is its `work/` subdirectory), so emitted code for a
failing test can be inspected there, and repeated runs hit Zig's build
cache. One run at a time uses an output directory; a second run waits
for the first, unless `RIG_TEST_OUT` gives it a directory of its own.
