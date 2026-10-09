# Rig test suite

```bash
./test/run                 # everything (parallel)
./test/run ownership       # only tests whose id contains "ownership"
./test/run -v known        # list each result of the known bugs
./test/run --update ir     # rewrite IR snapshots after an intended grammar change
./test/run corpus          # every corpus program (a plain run takes a sample)
./test/run --shard 2/4     # the second of four disjoint shards of a run
./test/run --prune         # only remove the output of tests that are gone
test/matrix.py             # generate and run the form x context x type matrix
test/matrix.py --shard 2/4 # the second of four disjoint shards of the matrix
./test/run --delta corpus  # check every program; run only those whose run
test/matrix.py --delta     # could differ from one that passed (below)
```

A shard takes the selected tests whose id hashes to it, so the N shards
of a run, on one machine or several, run each test once; the first also
runs the whole-program checks (`unit`, `parser`, `classify`, `vocab`,
`style`).

The summary line reads `N passed, M failed, K known, P pending`. The
suite is green when nothing fails and no known-failing test or pending
doc example has started passing. A
filter that selects nothing, or only the `parser` check when Nexus is
not built, exits 2; naming only kinds that have no tests (`known`, when
no bug is open) exits 0. The runner works from any directory.

The runner needs bash and either GNU `timeout` or perl (stock macOS has
perl). `ZIG` names the Zig executable, `RIG_TEST_TIMEOUT` the seconds
each test may take (default 120), `RIG_TEST_OUT` the directory for
each test's output, `RIG_BUILD_STORE` where programs build (see
[Output](#output)), `RIG_RESULTS_CACHE` where passing runs are recorded
(see [Rerunning only what changed](#rerunning-only-what-changed)), and
`RIG_SANITIZE=0` turns off the sanitizer (see
[below](#leak-checking-and-the-sanitizer)).

## Layout

| Path | Contract |
|---|---|
| `test/behavior/<area>/<name>.rig` | the program runs, exits 0, has no leaks or use of freed memory, and its stdout equals the `# expect:` block |
| `test/reject/<area>/<name>.rig` | `rig check` exits non-zero with `file:line:col` diagnostics whose messages contain each `# error:` text (and, with `# errors: n`, exactly `n` errors); each hint of a lend of a place as a path's base, applied alone, draws no error the program did not draw at the same place (`test/hints.py`) |
| `test/known/<area>/<name>.rig` | a known bug, written as a behavior or reject test of the *correct* behavior |
| `examples/<name>.rig` | curated showcase programs; same contract as `behavior/` |
| `test/ir/<name>.rig` | raw and semantic IR snapshots (`<name>.raw.sexp`, `<name>.sem.sexp`) |
| `test/torture/<name>.rig` | bad input: `rig run` must reject it with a `file:line:col` diagnostic, never crash |
| `test/cli/<name>.sh` | a bash script exercising the `rig` commands; passes when it exits 0 (see below) |
| `test/corpus/<name>.rig` | a reviewer's probe: `rig check` rejects it with a `file:line:col` diagnostic, or it runs sanitizer-clean (see below) |
| `unit` | `zig build test` |
| `parser` | `src/parser.zig` matches what Nexus generates from `rig.grammar` |
| `classify` | no pass in `src/` keeps a classifier of what an expression hands over beside `sema.handsOver` (`isPlaceExpr`, `isPlace`, `makesValue`, `isBranching`, `readLeaves`, `classifyReceiverShape`), and emit names hidden storage only through its storage facts (`Emitter.hiddenStorage`) |
| `vocab` | the docs, std/, the string literals in `src/`, and `# error:` lines say lend, view, and loan (docs/CORE.md, "Three words"): Rust's word for all three appears only in the lines `test/vocabulary-allow.txt` lists, each as `path: line text`, and in no path; an entry that matches no such line, or appears twice, fails |
| `style` | the Rig in `test/` (but `test/torture/`), `examples/`, `std/`, and the docs' ```` ```rig ```` blocks is written one way: a definition writes its parameter list (`sub main()`); one blank line goes between top-level declarations, though one-line ones (`use`, constants, `extern`, `type`) may stand together; no two blank lines run together; a file or block neither starts nor ends with a blank line, and a file ends with a newline; no line of code ends in spaces. A file or block whose expected errors are the definition rule's own may break that rule |
| `doc/<file>/L<n>` | the ```` ```rig ```` block at line `n` of a Markdown file (see below) |
| `oracle/<set>` | the reference ownership checker agrees with the compiler over a set of programs (see below) |

Areas: `syntax`, `types`, `effects`, `ownership`, `emit`, `runtime`, `modules`,
`std` (the standard library).
A multi-file test is a directory `<name>/` with an entry `main.rig`; the
directives go in `main.rig`.

One file per test, discovered automatically; there is no list to edit.

## Directives

Directives are whole-line comments.

```rig
sub main()
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
- `# release` — a behavior test is also built with `--release` (Zig's
  safe optimized mode) and must pass the same way: exit 0 (or the
  expected panic) and print the `# expect:` block. Use it where the
  optimizer may treat the emitted Zig differently from a debug build.
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
With `RIG_SANITIZE=1`, emit also fills each storage location it adds
(a call's evaluated arguments and receiver, a statement's or header's
temporaries, a held or matched subject) with `0xAA` bytes when its scope
ends, so a view that outlives that storage reads garbage instead of a
stale value. A behavior test therefore fails on any leak, double free,
or use of freed memory, and on most reads of dead hidden storage. Run a
failing program by hand with
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
the output directory is what the test is about. Scripts inherit the
suite's `RIG_BUILD_STORE`, so `rig run|build|test` builds in the store
(see [Output](#output)); a script about the output directory sets
`RIG_BUILD_STORE=` for those commands.

## The corpus

`test/corpus/` keeps the probe programs written by past reviews and
audits, deduplicated by content. Each program either is rejected by
`rig check` with a `file:line:col` diagnostic, or runs (see [Output](#output)) under the
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
removes each passing program's output; its build stays in the store
(a few gigabytes for the whole corpus, see [Output](#output)), so a
later run rebuilds only the programs whose emitted Zig changed. Add new review probes here, named `<review>-<probe>.rig`.

`test/matrix.py` generates the programs where one expression form (a
place, a ternary, `o?`, `??`, `catch`, `if … as`, `match`, a call, a
constructor, `<x`, `+x`) stands in one context (a `print` argument, a
`?T` argument, `==`, a binding, a field store, a Vec push, `return`, an
element assignment, a `match` subject, a `for` source, a consuming
receiver, a test against `none` or a bare `.variant`) for each of
several types (Int, String, Text, Vec, `*T`, Box, a struct with a `drop`,
a payload enum), and holds each to the corpus's rule; a slice of the
value, written with no lend, stands as an argument where a `[]T` or a
String goes, also while a later argument writes what it slices; and a
slice of an array, a Vec, a Text, or a String held owned, through a
read or write view, a `*T`, a box (or a write view of either), a field,
a field holding a write view, or a nested field, as an argument or
bound bare, stands while the owner is changed or replaced, or after its
last use. It also puts a
block-local binding at the tail of each kind of value block (an `if`
branch, a `match` arm, a `catch` handler, a loop's `else`, a nested
`if`), with and without a `defer` that uses it, for a binding, a field
store, and a result. And it uses a view of a read `match` payload in
its arm, or returns or stores it, for each kind of type reached through
each kind of subject, runs other code on the stack before reading it,
and checks that a program that runs prints what the payload holds,
since the sanitizer cannot see a stale stack slot. It lends a binding
that is a write view (a `match !e` payload, `if !o as b`, `for b in
!v`, a `!T` parameter, a `|!b|` capture, a held `b = !x`, a field of a
write view) of a Text, a Vec, a `Box[Text]`, or a struct holding a Vec,
whole, sliced, or to a call or `?self` method, then writes through the
binding while the view is live, or after its last use; a program that
runs must print what the view showed before the write. A read match's
binding of a write view field, of a local or a `!E` parameter, is
written the same way, and every such program must be rejected
(`lendw.`). A `while` step
reads what its condition binds, a view or a struct holding one, while
the body grows what it views on each way to the step (the body's end,
`continue`, `continue :outer` from a nested `for`, `while`, or
`while … as`, also under a joined or `catch break` condition, an inner
loop, a `defer`, a `break`), and a program that runs must print how
many steps ran. And it puts a `while`, `for`, `while … as`, `match`, or
`if` in each kind of loop (`while`, `while … as`, joined, `catch break`,
`for`) that jumps once (`continue`, `continue :outer`, `break :outer`,
or `continue` in the inner construct's `else`) past a `defer` or an
owned local, and a program that runs must print the trace of passes,
steps, defers, and drops the jumps' meaning gives. Last, it changes or
reads a Cell (`set`, `replace`, `get`, a `Cell[Vec]`'s `push`, `pop`,
`clear`, and `c[i] = e`, and a `?self` method) of each kind of value
holding one (a struct with a `drop`, without one, with fields Zig knows
at compile time, the Cells in a part, a generic type, a bare Cell, and
generic types that hold a Cell holder only behind a handle or in a Vec)
through each kind of path to it (a local, a field, a Vec or array
element, a `?T` parameter, a slice, a `?self` method, a stored view, a
`|?x|` capture, `if … as`, `for` over a view, a `*T`, a view a generic
function returns, an element of a `?Vec` parameter, a subslice), in a
statement, a loop that continues or breaks early, a `defer`, and a loop
that returns. Every such program must be accepted, and print the state
the operations give both in a debug build and built with `--release`,
where Zig's optimizer would expose a write through a read-only pointer. And
it changes or reads the Cell of a temporary that holds one, of the same
kinds of value, where the temporary stands: made in the statement, a
part of one, or a leaf a value that branches may take beside a name's
(`a if k else mk()`, `o ?? mk()`, `mkf()!`, `mko()?`, a nested branch,
a part of a branch), through a Cell member, a `?self` method, a view a
method returns, and, where no leaf is a name's, a read or write lend,
in a statement, an argument, a loop, and an `if` and a `while`
condition, with each leaf taken (`celltemp.`). Every such program must
be accepted, and print, in debug and with `--release`, the trace in
which each change lands in the leaf taken and each temporary's `drop`
sees it. Every loop a cell
writes counts its passes and stops at a cap, and each program is
stopped past its time (`--timeout`), when its processes hold more than
its memory (`--mem`; an address-space limit would stop the sanitizer,
which reserves far more than it uses), or past 1 MB of output. `--rig`
tests another compiler.
It writes to a temporary directory
and commits nothing; `-k` picks cells by id and `-v` lists every result.

## The reference ownership checker

`test/oracle/` is a second ownership checker, written from
[docs/CORE.md](../docs/CORE.md) and SPEC's ownership sections without
reading `src/ownership.zig`, and built as `bin/rig-oracle` (`zig build
oracle`; `src/lib.zig` is its view of the compiler, which `bin/rig`
never imports). It lowers each function to a small core with its
statement temporaries and evaluation order written out, then checks
moves, loans, and drops with a dataflow over the function's control
flow. Each function gets its verdict, accept or reject, or none when
the function uses a form the oracle does not model yet. The test kind
`oracle` runs it over five sets:

| Id | Programs |
|---|---|
| `oracle/lint` | none: `test/oracle/` uses none of the compiler's ownership classifications, and `src/` imports neither `lib.zig` nor `test/` |
| `oracle/tests` | `test/behavior`, `test/reject`, `test/known`, and `examples` |
| `oracle/corpus` | every corpus program (no sample) |
| `oracle/docs` | every doc example but fragments |
| `oracle/matrix` | the matrix programs (`test/matrix.py --oracle`) |

A set fails when the compiler accepts a function the oracle rejects:
that may be a soundness hole, and it can never be allowlisted. When the
compiler rejects a function the oracle accepts, the run reports it
(`stricter`), and `test/oracle/differences` records it once classified
(a compiler rejection the Core allows, an oracle gap, or a question the
Core leaves open). A set also fails when a listed difference is gone
(`FIXED`), or when the oracle decides fewer functions than the set's
floor in `test/oracle/coverage`.

A test may state the oracle's own verdict on one of its functions, in
a comment line the oracle checks on every run, whatever the compiler
decides (also where the compiler's semantic checks stop first):

```
# oracle: main reject C2
```

The word after the function is `accept`, or `reject` with the rule
the oracle names (C1–C8, B1–B4). A different verdict, or none, fails
the set. These lines are
the oracle's own tests: each of the oracle's header rules (a subject
that is a place, a made value, a part of one, a lend of one, or a
branching value) has tests that state its verdict, so the change that
builds a planned rule can rely on the oracle to catch what it gets
wrong. By hand:

```bash
bin/rig-oracle -v file.rig            # every function's two verdicts
bin/rig-oracle --explain main file.rig  # the lowered core of `main`
bin/rig-oracle --stats test/corpus/*  # why it abstains, by count
bin/rig-oracle --sema -v file.rig     # also functions the compiler's
                                      # semantic checks rejected
```

## Proving a refactor changed nothing

```bash
test/equiv.py OLD_RIG NEW_RIG [-j N] [--keep DIR] [--no-cache]
```

runs two compilers over every tracked program and every ```` ```rig ````
block in the docs, and compares what they print for `parse`,
`normalize`, `check`, `check --facts`, and, for an accepted program,
`check --facts=sema`, `check --facts=storage`, `emit` (the root
module), and `pkg`: a hash of the whole package that
`RIG_SANITIZE=1 rig emit` writes, every module, the standard library's
shims, and the runtime with its sanitizer, so a change that shows only
in another module or in sanitized code is still seen. It lists each
program whose output differs, with the sections that differ (`--keep`
saves both outputs, and both packages for `pkg`), and exits 1 if any
does. Build the old compiler from the base commit and copy `bin/rig`
aside first. A refactor's every difference is a planned rule or a fixed
bug, and its pull request lists them.

The old compiler's results are cached in `rig-equiv-cache` in the
repository's git directory, by a hash of its binary, the section, the
program's path, and the contents of the program and of every module
beside it that a `use` could name; so a rerun against the same old
compiler runs only the new one. `--no-cache` runs both.

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
exist, and keeps those of every corpus program though it runs only a
sample; `./test/run --prune` does only that.

A test that runs a program (behavior, example, known bug, doc example
with output, corpus, matrix) passes only on positive evidence that the
program ran: `rig run` creates the file the harness names in
`RIG_RUN_STARTED`, a fresh path in the run's private results directory
(test/matrix.py: a private directory of its own), only once the program
has started. Without a regular file there, or with rig's `the program
did not run`, the test fails with `the program did not run`, whatever
the exit status or output; so does a known bug or a pending example, so
a failure in rig, Zig, or the build store never passes, holds, or counts
as the known failure. In the corpus and the matrix, a program a signal
ended (`rig: the program was killed by signal N`) fails too, unless it
is a Rig panic: an abort (signal 6) after its `panic:` report. A status
above 128 alone is the program's own.

Programs build in a store shared by every worktree of the repository,
`rig-build-store` in its git directory (`git rev-parse
--git-common-dir`), or `$RIG_BUILD_STORE`; `RIG_BUILD_STORE=` (empty)
builds each in its test's output directory instead. `rig run` builds a
package in the store's entry named by a hash of everything the build
reads (docs/INTERNALS.md), so a program built before, in this worktree
or another, by this compiler or another that emits the same package, is
not built again; a new branch's first run rebuilds only the programs
whose package it changed. Zig still checks every input of a cached
build. A run with no filter removes the entries no run has used for
`RIG_BUILD_STORE_DAYS` days (default 7), each renamed into the store's
trash in one step and then deleted. `test/matrix.py` builds in the
same store. One run at a time uses an output directory; a second run waits
for the first, unless `RIG_TEST_OUT` gives it a directory of its own.
The runner marks an output directory as its own with a `.rig-test`
file, and refuses a `RIG_TEST_OUT` that is not empty and lacks it, so
it never removes files it did not write.

The output directory's `.durations` file records how long each test
took, in whole seconds; the next run starts the longest tests first, so
it does not end waiting on one of them.

## Rerunning only what changed

A program's run passes or fails by its inputs: the package `rig run`
builds (every module, the standard library's shims, and the runtime),
how rig runs it, Zig, and what the test expects. A change that leaves
all of them as they were, such as a diagnostic's wording or a fix in
the checker that rejects nothing new, cannot change the verdict, so the
run need not be repeated.

Each passing run of a behavior test, example, doc example with output,
corpus program, or matrix program is recorded in the results cache,
`rig-results-cache` in the repository's git directory beside the build
store (or `$RIG_RESULTS_CACHE`; empty records nothing). Its key is a
hash of:

- the package `RIG_SANITIZE=1 rig emit` writes for the program, every
  file by its path and contents (the package `rig run` builds is this
  one with the line naming its start hook), and whether Zig links it
  with libc, which `rig emit` notes;
- the entry file, so the program's directives (`# expect:`,
  `# expect-panic:`, `# release`, `# timeout:`) and, for a matrix
  program, what it must print and whether it is also built with
  `--release`;
- what judges the run: `test/run` itself, or the functions of
  `test/matrix.py` that run and judge a program;
- the driver that runs it, `src/main.zig`, which `bin/rig` is built
  from first (`test/run` always builds it, and `test/matrix.py` does
  when the cache is on);
- `zig env` (Zig's version, its standard library, and the target), the
  `ZIG` named, the test's time limit, and every `RIG_` variable but
  those that name a place (`RIG_RESULTS_CACHE`, `RIG_BUILD_STORE`,
  `RIG_BUILD_STORE_DAYS`, `RIG_TEST_OUT`, `RIG_OUT_DIR`): the sanitizer
  and its knobs, `RIG_LEAK_TRACE`, `RIG_STD`, and any a program reads.

With `--delta`, `./test/run` and `test/matrix.py` check every program as
always, but do not run one whose key is recorded: it passes, carried
over, and the summary says how many were (`2841 passed (2790 carried
over)`). Everything else runs: a program whose package changed, any
program after a change to the runtime, the driver, the harness, or Zig,
and every test whose verdict is not a run's (rejections, IR snapshots,
CLI scripts, the whole-program checks, the oracle). Known bugs and
pending examples are never carried over. A run without `--delta`
records its passes but carries nothing over, so the merge gates at a
pull request's head run in full and fill the cache for the next round.
`test/matrix.py --rig` neither reads nor writes the cache.

A record is an empty file named by its key, so runs in every worktree
share it. A failing run records nothing, and neither does a passing run
the sanitizer stopped guarding (`rig: sanitizer: mapping limit
reached`), or one during which something its key names changed: after
the run, the key is computed again and must be the same, and `test/run`,
`src/main.zig`, and `bin/rig` (which a `zig build` replaces) must be the
ones the run started with. A run with no filter removes the records no
run has used for `RIG_BUILD_STORE_DAYS` days. The CLI tests run with
`RIG_RESULTS_CACHE` empty, so they neither fill nor prune the shared
cache. `test/cli/results_cache.sh` checks that a changed expectation,
runtime, libc link, driver, harness, Zig, or setting is never carried
over, and that a change during a run is never recorded.

Two inputs are left out of the key. A program whose output depends on
the clock, randomness, or the machine it runs on is carried over on the
strength of one passing run; and so is one that reads an environment
variable not named `RIG_` (`os.env`), since hashing the whole
environment (`PWD`, `TMPDIR`, ...) would match no record.
