# Rig test suite

```bash
./test/run                 # everything (parallel)
./test/run ownership       # only tests whose id contains "ownership"
./test/run -v known        # list each result of the known bugs
./test/run --update ir     # rewrite IR snapshots after an intended grammar change
./test/run corpus          # every corpus program (a plain run takes a sample)
test/matrix.py             # generate and run the form x context x type matrix
```

The summary line reads `N passed, M failed, K known, P pending`. The
suite is green when nothing fails and no known-failing test or pending
doc example has started passing. A
filter that selects nothing, or only the `parser` check when Nexus is
not built, exits 2; naming only kinds that have no tests (`known`, when
no bug is open) exits 0. The runner works from any directory.

The runner needs bash and either GNU `timeout` or perl (stock macOS has
perl). `ZIG` names the Zig executable, `RIG_TEST_TIMEOUT` the seconds
each test may take (default 120), `RIG_TEST_OUT` the directory for
emitted packages (see [Output](#output)), and `RIG_SANITIZE=0` turns
off the sanitizer (see [below](#leak-checking-and-the-sanitizer)).

## Layout

| Path | Contract |
|---|---|
| `test/behavior/<area>/<name>.rig` | `rig run` exits 0, no leaks or use of freed memory, stdout equals the `# expect:` block |
| `test/reject/<area>/<name>.rig` | `rig check` exits non-zero with `file:line:col` diagnostics whose messages contain each `# error:` text (and, with `# errors: n`, exactly `n` errors) |
| `test/known/<area>/<name>.rig` | a known bug, written as a behavior or reject test of the *correct* behavior |
| `examples/<name>.rig` | curated showcase programs; same contract as `behavior/` |
| `test/ir/<name>.rig` | raw and semantic IR snapshots (`<name>.raw.sexp`, `<name>.sem.sexp`) |
| `test/torture/<name>.rig` | bad input: `rig run` must reject it with a `file:line:col` diagnostic, never crash |
| `test/cli/<name>.sh` | a bash script exercising the `rig` commands; passes when it exits 0 (see below) |
| `test/corpus/<name>.rig` | a reviewer's probe: `rig check` rejects it with a `file:line:col` diagnostic, or it runs sanitizer-clean (see below) |
| `unit` | `zig build test` |
| `parser` | `src/parser.zig` matches what Nexus generates from `rig.grammar` |
| `doc/<file>/L<n>` | the ```` ```rig ```` block at line `n` of a Markdown file (see below) |

Areas: `syntax`, `types`, `effects`, `ownership`, `emit`, `runtime`, `modules`,
`std` (the standard library).
A multi-file test is a directory `<name>/` with an entry `main.rig`; the
directives go in `main.rig`.

One file per test, discovered automatically; there is no list to edit.

## Directives

Directives are whole-line comments.

```rig
sub main
  print(42)
  print("done")

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
- `# errors: <n>` — the check must report exactly `n` errors (notes
  aside), so a cascade of follow-on errors fails the test. Use it where
  one mistake should get one error.
- `# timeout: <seconds>` — raises this test's time limit above
  `RIG_TEST_TIMEOUT`, for a behavior test or CLI script that builds
  programs slowly when Zig's cache is cold.

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
| ```` ```rig pending ```` | a rule that is decided but not built yet (see below) |

Blank lines may separate a block from its `output` or `error` block.

A ```` ```rig pending ```` block shows the behavior a decided rule will
have: followed by an `output` block it is a program that runs and prints
it, followed by an `error` block a program the check rejects with those
messages, and alone a program the check accepts. It passes, and counts
as `pending`, while that check fails for a reason that means the rule is
missing: the program is rejected, accepted where it should be rejected,
rejected with other messages, or prints something else. A timeout, a
compiler crash, or an accepted program that fails to compile, leaks, or
uses freed memory still fails it, as it would any example. Once the
rule is built and the example passes, the suite fails with `FIXED`, and
the change that built the rule marks the block ```` ```rig ```` (or
```` ```rig reject ````). So the docs state planned rules only as
tests, and no example claims behavior the compiler does not have. A
failure is reported with the id `doc/<file>/L<line>`, naming the line of
the opening fence; `./test/run doc` runs only the doc examples.

## Leak checking and the sanitizer

`rig run` builds in Debug mode, where the runtime records every live
allocation (address and size, no stack traces). The emitted `main`
defers `rig.finish()`, which prints
`error: rig: memory leak detected: N allocations (B bytes) never freed`
and exits 1 if anything is still allocated. A double free or a free of
memory that was never allocated panics. To see where leaked memory was
allocated, run the test again by hand with
`RIG_LEAK_TRACE=1 bin/rig run file.rig`: the runtime then allocates
through Zig's `SafeAllocator`, which prints a stack trace for each
leak.

The suite also builds every program it runs (behavior tests, examples,
known bugs, doc examples with output, the corpus) with `RIG_SANITIZE=1`,
which puts the sanitizing allocator under the leak checker. Each block
gets pages of its own, a free makes them inaccessible, and no address
is handed out twice, so reading or writing freed memory, or past the end
of a block, crashes at once with
`error: rig: use of freed memory at address 0x...` and a stack trace.
A behavior test therefore fails on any leak, double free, or use of
freed memory. Run a failing program by hand with
`RIG_SANITIZE=1 bin/rig run file.rig`. The sanitizer costs a few
system calls and two pages of address space per allocation: the suite
takes about 15% longer, and an allocation-heavy program runs several
times slower, so a plain `rig run` keeps only the leak checker.
`RIG_SANITIZE=0 ./test/run` runs the suite without it. Each live
guarded block is a memory mapping, and Linux caps those per process
(`vm.max_map_count`); past about half that many live blocks (or
`RIG_SANITIZE_BLOCKS`, which tests set to reach the cap), the sanitizer
prints `rig: sanitizer: mapping limit reached; further allocations are
not guarded` once and allocates the rest normally, poisoning them when
freed. Leak checking still covers every block.

## CLI tests

Each `test/cli/<name>.sh` runs in an empty directory with `RIG` (the
compiler), `ROOT` (the checkout), and `RIG_OUT_DIR` set, sources
`test/cli/_lib.sh` for `fail`, `expect_eq`, `expect_has`, and
`expect_rc`, writes the programs it needs with heredocs, and passes when
it exits 0. Files starting with `_` are helpers, not tests.

A script builds its programs with `rig run|build|test ... file.rig`, a
function in `_lib.sh` that gives each root file its own output directory
under `$RIG_OUT_DIR/programs/`, whose Zig cache the harness keeps
between runs. Zig caches one build per root path and flags, and every
program's root is `__rig_main.zig` in its output directory, so programs
built in one directory would rebuild cold on every run. (`zig build-exe`
caches nothing, so `rig build` is always cold; prefer `rig run` when the
executable itself is not under test.) Call `"$RIG"` directly for
commands that build nothing (`check`, `emit`, usage errors) and when
the output directory is what the test is about.

## The corpus

`test/corpus/` keeps the probe programs written by past reviews and
audits, deduplicated by content. Each program either is rejected by
`rig check` with a `file:line:col` diagnostic, or runs under the
sanitizer with no leak, no use of freed memory, no Zig compile error,
no crash, and no Zig safety check that means emitted code went wrong
(`reached unreachable`, a wrong union field, ...). A probe need not
succeed: Rig's own panics (bounds, overflow) and exit statuses are
fine, and nothing checks its output. A multi-module probe is a
directory with `main.rig`. Probes that need a module we no longer
have, loop forever, or leak through a cycle of strong handles (the one
leak Rig allows) are left out, and so are those rejected only by the
parser.

Running every accepted probe builds hundreds of programs, several
minutes of work, so a plain `./test/run` takes a fixed sample, one
program in 16 by a hash of its name; `./test/run corpus` (or any filter
that names corpus programs) takes all of them, as CI should nightly or
before a merge that touches the checkers or the emitter. A corpus run
removes each passing program's build, so the corpus leaves no cache
behind. Add new review probes here, named `<review>-<probe>.rig`.

`test/matrix.py` generates the programs where one expression form (a
place, a ternary, `o?`, `??`, `catch`, `if … as`, `match`, a call, a
constructor, `<x`, `+x`) stands in one context (a `print` argument, a
`?T` argument, `==`, a binding, a field store, a Vec push, `return`, an
element assignment, a `match` subject, a `for` source, a consuming
receiver, a test against `none` or a bare `.variant`) for each of
several types (Int, String, Text, Vec, `*T`, Box, a struct with a `drop`,
a payload enum), and holds each to the corpus's rule. It also puts a
block-local binding at the tail of each kind of value block (an `if`
branch, a `match` arm, a `catch` handler, a loop's `else`, a nested
`if`), with and without a `defer` that uses it, for a binding, a field
store, and a result. It writes to a temporary directory
and commits nothing; `-k` picks cells by id and `-v` lists every result.

## Proving a refactor changed nothing

```bash
test/equiv.py OLD_RIG NEW_RIG [-j N] [--keep DIR]
```

runs two compilers over every tracked program and every ```` ```rig ````
block in the docs, and compares what they print for `parse`,
`normalize`, `check`, `check --facts`, and, for an accepted program,
`check --facts=sema` and `emit`. It lists each program whose output
differs, with the sections that differ (`--keep` saves both outputs),
and exits 1 if any does. Build the old compiler from the base commit
and copy `bin/rig` aside first. A refactor's every difference is a
planned rule or a fixed bug, and its pull request lists them.

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
cache. A doc example's directory is `doc/<file>/<checksum>/`, named by
its text rather than its line, so an edit that moves it keeps its cache.
A run with no filter removes the directories of tests that no longer
exist. One run at a time uses an output directory; a second run waits
for the first, unless `RIG_TEST_OUT` gives it a directory of its own.
The runner marks an output directory as its own with a `.rig-test`
file, and refuses a `RIG_TEST_OUT` that is not empty and lacks it, so
it never removes files it did not write.

The output directory's `.durations` file records how long each test
took, in whole seconds; the next run starts the longest tests first, so
it does not end waiting on one of them.
