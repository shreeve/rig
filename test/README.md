# Rig test suite

`test/rig.rip` runs Rig's tests with Rip's Swarm
([docs/RIG-TESTS.md](../docs/RIG-TESTS.md) is its spec): the cases of
`test/rig/*.rig.test` (every behavior and rejection test), every
```` ```rig ```` block of the docs, `examples/`, `test/torture/`, the
unit tests, and the reference ownership checker's sets in its core; the
scripts of `test/cli/` as `cli`; and the probes of past reviews,
`test/rig/probes-*.rig.test`, as `probes`. Run it through `cpuq run`
(AGENTS.md):

```bash
swarm test/rig.rip                 # the core
swarm test/rig.rip cli             # the scripts of test/cli
swarm test/rig.rip probes          # the probes of past reviews
swarm test/rig.rip all             # all three
swarm test/rig.rip std-text        # test/rig/std-text.rig.test alone
swarm test/rig.rip doc             # the doc examples alone (doc-SPEC: SPEC.md's)
swarm test/rig.rip cli.lsp         # one script of test/cli, by its name
swarm test/rig.rip full            # by hand: every script with its sweeps whole
swarm test/rig.rip proofs          # by hand: the proven checks' differential run
test/matrix.py                     # by hand: the form x context x type matrix
bench/json/check/compare.py        # by hand: std.json against Python's json
```

A case that fails lands in `.swarm/died`, with its reason in
`.swarm/errors.log`; the run lists each failure at its end and exits 1.

## Layout

| Path | What it holds |
|---|---|
| `test/rig/<area>.rig.test` | the behavior and rejection tests, as cases (docs/RIG-TESTS.md) |
| `test/cli/<name>.sh` | a script that drives the `rig` command line (below) |
| `test/torture/<name>.rig` | bad input `rig run` must reject with a `file:line:col` diagnostic, never crashing |
| `test/rig/probes-*.rig.test` | the probes of past reviews, as cases (below) |
| `test/oracle/` | the reference ownership checker and its lists (below) |
| `test/lanes/` | the SIMD lane grids `test/cli/lane_grid.sh` generates and checks |
| `test/matrix.py`, `test/hints.py` | the matrix and the lend hints' check (below) |

Beside them, by hand: `bench/json/check/` compares `std.json` with
Python's `json` module, and `tools/equiv.py` proves a refactor changed
nothing (below).

## Examples

An example, `examples/<name>.rig`, is a whole program whose `# expect:`
block (the comment lines after it, `# ` taken off each) is what it
prints. `test/rig.rip` runs each as a `test` case. The cases of
`test/rig` give their results on their headers (docs/RIG-TESTS.md).

## Doc examples

Every ```` ```rig ```` block in the Markdown files (`*.md`, `docs/`,
`examples/`, `test/`) is a test, so the docs cannot drift from the
compiler. The word after `rig` on the opening fence sets the contract:

| Fence | Contract |
|---|---|
| ```` ```rig ```` | a program `rig check` accepts |
| ```` ```rig ```` followed by ```` ```output ```` | run like a behavior test: stdout equals the output block, no leaks |
| ```` ```rig ```` followed by ```` ```stderr ```` (after the ```` ```output ```` block, if one) | as above, and stderr equals the stderr block; ```` ```stderr exit=N ```` also requires exit status `N` |
| ```` ```rig reject ```` followed by ```` ```error ```` | `rig check` rejects it; each line of the error block appears in a diagnostic |
| ```` ```rig fragment ```` | only parsed; for snippets that are not whole programs |
| ```` ```rig facts ```` followed by ```` ```facts ```` | `rig check --facts` accepts it and prints exactly the facts block |
| ```` ```rig file=name.rig ```` | module `name.rig`, written next to the next example, which can `use name`; a path, ```` ```rig file=dir/name.rig ````, writes a file of the directory module `dir` |
| ```` ```rig pending ```` | a rule that is decided but not built yet (see below) |

Blank lines may separate a block from its `output`, `stderr`, or `error` block.

A ```` ```rig pending ```` block shows the behavior a decided rule will
have: followed by an `output` block it is a program that runs and prints
it, followed by an `error` block a program the check rejects with those
messages, and alone a program the check accepts. It passes, and counts
as `pending`, while that check fails for a reason that means the rule is
missing: the program is rejected, accepted where it should be rejected,
rejected with other messages, or prints something else. A timeout, a
compiler crash, or an accepted program that fails to compile, leaks, or
uses freed memory still fails it, as it would any example. Once the
rule is built and the example passes, the suite fails, and
the change that built the rule marks the block ```` ```rig ```` (or
```` ```rig reject ````). So the docs state planned rules only as
tests, and no example claims behavior the compiler does not have. A
failure names the doc and the line of the opening fence (`SPEC.md:160`).
Each doc is an area, `doc-<name>` (`doc-SPEC`, `doc-CORE` for
docs/CORE.md), and `doc` names them all.

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

A program that panics on purpose (a `bomb` case, one that gives its
`exit:`, and the CLI tests' panicking programs and `rig test` runs) runs with
`RIG_NO_CRASH_REPORT=1`. That only stops a crash report for its abort. On
macOS, `rig run` and `rig test` answer their program's crash themselves,
always, with or without it, and
the CLI tests run a built program through `quiet` (test/cli/_lib.sh), which
uses `cpuq cap --no-crash-report` where cpuq (cap protocol 3 or later) is on
PATH: neither the user's ReportCrash (~/Library/Logs/DiagnosticReports) nor
the system's (/Library/Logs/DiagnosticReports) files one. On Linux the
program's core limit of exactly 1 keeps the kernel from passing it to the
`core_pattern` handler (apport). It still exits 134 with the same output.
`test/rig.rip` sets it for those cases alone and clears it for every other
program, whose crash is still reported on Linux, and on macOS when it is a
built program run directly; `test/cli/no_crash_report.sh` checks the status
and output are the same with and without it, on Linux the core limit, and on
macOS that both report folders stay empty for a panic run quiet and for one
under `rig run` without it, while a built program's panic not run quiet still
files a report.

The suite also builds every program it runs (`test` and `bomb` cases,
examples, doc examples with output) with `RIG_SANITIZE=1`,
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
system calls and two pages of address space per allocation, and an
allocation-heavy program runs several times slower, so a plain `rig
run` keeps only the leak checker. Each live
guarded block is a memory mapping, and Linux caps those per process
(`vm.max_map_count`); past about half that many live blocks (or
`RIG_SANITIZE_BLOCKS`, which tests set to reach the cap), the sanitizer
prints `rig: sanitizer: mapping limit reached; further allocations are
not guarded` once and allocates the rest normally, poisoning them when
freed. Leak checking still covers every block.

## Strict optionals

`RIG_STRICT_OPTIONALS=1 swarm test/rig.rip` runs the suite with every object's
optional held as a tagged struct, which Zig never lifts a value into
and never tests with `orelse` or `null` (docs/INTERNALS.md, Emit,
"Optionals"). A program then compiles only if the compiler writes
every operation on such an optional through the runtime's optional
helpers, and prints what it prints in a plain run, so a run in this
mode that passes shows no optional site was missed. Run it after a
change to how emit or the runtime handles optionals.
`test/cli/strict_optionals.sh` runs one program both ways in every run.

## CLI tests

Each `test/cli/<name>.sh`, which `swarm test/rig.rip cli` runs, runs in
an empty directory with `RIG` (the compiler), `ROOT` (the checkout),
`RIG_OUT_DIR`, and `RIG_TESTS` set: the behavior and rejection tests,
as the runner writes them out (`behavior/<area>/<name>.rig` and
`reject/<area>/<name>.rig`, or `<name>/main.rig`). A program a script
needs exactly as it is lives in `test/cli/fixtures/`. A script sources
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

A script keeps only what needs the command line: the `rig` command's
own exit status, the files and caches it writes, environment variables,
signals, pipes, the language server's stdio. What a program prints,
panics with, or is rejected with is a case of `test/rig` instead, built
in a pack. A script about rig's caches or its store runs most of its
checks against a stand-in Zig, keeping a real build or two. A sweep
checks by default the part that holds the bug it was written for, and
the whole of it with its variable set: `LANE_GRID_FULL`,
`INLINE_BUDGET_FULL`, `LSP_CHECK_FULL`, `NO_CRASH_REPORT_FULL`,
`PANIC_STATUS_FULL`, `TEXT_GO_FULL`, `UTF8_GUARD_FULL`, `UTF8_ZIG_FULL`,
`WIDE_MASKS_FULL` (`LANE_GRID_FULL=1 swarm test/rig.rip cli`). A
comparison with Go or with Zig's own library checks answers recorded
in a case, which a tool in `tools/` writes and the variable checks are
still the reference's.

## The JSON tests

`bench/json/check/compare.py` runs `std.json` over 10,511 generated and
hand-written inputs and compares each parse with Python's `json` module
(`bench/json/check/README.md` says how, and lists the groups). It runs by hand,
when `std.json` changes: with no group it takes every group, and
`--subset` a fixed, spread-out part of each. The groups `checker` and
`corpus` read third-party files that `tools/fetch-json-data.sh` fetches
into `bench/json/check/data/`. Without them those groups are skipped with a
note, and `JSON_REQUIRE_DATA=1` makes that a failure.

## The probes of past reviews

`test/rig/probes-*.rig.test` hold the probe programs written by past
reviews and audits, as cases named after their probes
(`review-arm-temps-2-m46 last arm index target view local`): a `fail`
case where the compiler rejects the probe, and a `test` or `bomb` case,
with what it prints, where it runs. Each is a probe that gives the
reference ownership checker a function whose lowered core no other test
or probe has; they give it most of the functions it decides
(`oracle.tests`, below). The core skips their own checks, which double
its time, but its oracle job reads every probe; `swarm test/rig.rip
probes` (or `all`) checks what each prints or is rejected with. A new
review adds its probes as cases, to a probes file or to the test file
of the area it probes.

Probe batches started by hand should set `RIG_OUT_DIR=$(mktemp -d)` and
delete it afterwards, so they never write to the user cache.

`test/matrix.py` generates the programs where one expression form (a
place, a ternary, `o?`, `??`, `catch`, `if … as`, `match`, a call, a
constructor, `<x`, `+x`) stands in one context (a `print` argument, a
`?T` argument, `==`, a binding, a field store, a List push, `return`, an
element assignment, a `match` subject, a `for` source, a consuming
receiver, a test against `none` or a bare `.variant`) for each of
several types (Int, `?String`, `String`, `List`, `*T`, `^T`, an object with a `drop`,
a payload enum, and in a few cells an object holding a Cell, which must
be rejected), and holds each to one rule: `rig check` rejects it with a
`file:line:col` diagnostic, or it runs clean under the sanitizer; a slice of the
value, written with no lend, stands as an argument where a `[]T` or a
`?String` goes, also while a later argument writes what it slices; and a
slice of an array, a List, a String, or a `?String` held owned, through a
read or write view, a `*T`, a box (or a write view of either), a field,
or a nested field, as an argument or
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
that is a write view (a `match !e` payload of every subject, named,
guarded, nested, and of a branch of write lends; `if !o as b` and
`while !o as b`; `for b in !v`, with an index and over an array; a `!T`
parameter; a `|!b|` capture; a held `b = !x`; a `defer` in the arm) of
a String, a
List, a `^String`, or an object holding a List, whole, sliced, or to a
call or `?self` method, then writes through the binding while the view
is live, or after its last use; a program that runs must print what the
view showed before the write. A read binding of a write view (`if o as
b` and `while o as b` of a local `(!T)?`) is written the same way, and
so is a match of a branch that reads a place holding a write view (bare
write views, `??` of an optional write view), through the binding or
through the place; every such program must be rejected
(`lendw.`). And it puts each header (`match`, `if … as`, `while … as`,
`for`) over a subject that reaches a place holding a write view through
a branch, through a path, `?.`, `??`, and `catch`, written bare, lent
to read (`?S`), and lent to write (`!S`), for a `!W` parameter and a
local write view, and writes through the place while a view of the binding lives; every such
program must be rejected (`hdr.`). A `while` step
reads what its condition binds, a view or an object holding one, while
the body grows what it views on each way to the step (the body's end,
`continue`, `continue $outer` from a nested `for`, `while`, or
`while … as`, also under a joined or `catch break` condition, an inner
loop, a `defer`, a `break`), and a program that runs must print how
many steps ran. And it puts a `while`, `for`, `while … as`, `match`, or
`if` in each kind of loop (`while`, `while … as`, joined, `catch break`,
`for`) that jumps once (`continue`, `continue $outer`, `break $outer`,
or `continue` in the inner construct's `else`) past a `defer` or an
owned local, and a program that runs must print the trace of passes,
steps, defers, and drops the jumps' meaning gives. Last, it changes or
reads a Cell (`set`, `replace`, `get`, a `Cell[List]`'s `push`, `pop`,
`clear`, and `c[i] = e`, and a `?self` method) of each kind of value
holding one (an object with a `drop`, the Cells in a part, a generic
type, a bare Cell) through the `*` handle it lives behind: directly,
through a `?T` parameter given the handle, and through a `?self`
method, in a statement, a loop that continues or breaks early, a
`defer`, and a loop that returns. Every such program must be accepted,
and print the state the operations give both in a debug build and
built with `--release`, where Zig's optimizer would expose a write
through a read-only pointer (`cellmut.`). A value holding a Cell made
or held anywhere but behind `*` (a local, a by-value parameter, a List
element, a temporary changed where it stands) must be rejected
(`cellmut.value.`, `celltemp.value.`). It also guards an index, a byte
read or write (of an integer or a `Simd`), or an add with each guard the compiler knows, and two
that prove nothing (`+%`, `or`), writes what the guard named between it
and the use in each way a program can (an assignment, a `!` lend, a
closure, a `defer`, a branch, a `match` arm, a loop, `raw`, a shadowing
`new`, a step), and checks that `rig check --facts=proofs` lists at the
use exactly the tests its own table of the rules proves, and that the
program runs clean, or panics with the use's own message where the write
moved the index out of range, in debug and with `--release` (`proof.`;
`--deep` also nests each use). It puts a write of `i` (`bump(!i)`, a
`|!i|` closure, a nested `i += 1`) and a use of it in the slots of each
statement form (a call, a binding, an assignment and each target root, a
`return`, a `while` with a `continue` in each part, an `if`, a `match`
with guards, value forms, a `defer`), under a guard, and checks that the
use is proven exactly when the guard's facts reach its unit (no write of
`i` in it or on a path from the guard), and that each cell runs alike in
debug and with `--release` (`unit.`: each slot pair with `bump(!i)` and
`s[i]` under an `if`, and each slot with no write under each guard;
`--deep` runs every write, use, and guard). Every loop a cell
writes counts its passes and stops at a cap, and each program is
stopped past its time (`--timeout`), when its processes hold more than
its memory (`--mem`; an address-space limit would stop the sanitizer,
which reserves far more than it uses), or past 1 MB of output. `--rig`
tests another compiler.
It writes to a temporary directory
and commits nothing; `-k` picks cells by id and `-v` lists every result.
Its programs build in `rig-build-store` in the repository's git
directory (or `$RIG_BUILD_STORE`), and a passing run is recorded in
`rig-results-cache` beside it (or `$RIG_RESULTS_CACHE`), so `--delta`
runs only the programs whose emitted Zig changed. The suite's core runs
the reference checker over its programs (`oracle.matrix`).

## The reference ownership checker

`test/oracle/` is a second ownership checker, written from
[docs/CORE.md](../docs/CORE.md) and SPEC's ownership sections without
reading `src/ownership.zig`, and built as `bin/rig-oracle` (`zig build
oracle`; `src/lib.zig` is its view of the compiler, which `bin/rig`
never imports). It lowers each function to a small core with its
statement temporaries and evaluation order written out, then checks
moves, loans, and drops with a dataflow over the function's control
flow. Each function gets its verdict, accept or reject, or none when
the function uses a form the oracle does not model yet. The suite's
core runs it over three sets, and checks it with a lint:

| Id | Programs |
|---|---|
| `oracle.lint` | none: `test/oracle/` uses none of the compiler's ownership classifications, and `src/` imports neither `lib.zig` nor `test/` |
| `oracle.tests` | the behavior and rejection tests, as `test/rig.rip` writes them out, and `examples` |
| `oracle.docs` | every doc example but fragments |
| `oracle.matrix` | the matrix programs (`test/matrix.py --oracle`) |

A set fails when the compiler accepts a function the oracle rejects:
that may be a soundness hole, and it can never be allowlisted. It also
fails when the oracle's own rejections change: every function the
oracle rejects is listed in `test/oracle/rejections` (`program
function`), and a set fails on one not listed (`UNLISTED`: add it) and
on a listed one the oracle decides and no longer rejects (`LOST`: the
reference checker was weakened, whatever the compiler decides). A doc
example is listed by its doc and a hash of its text
(`doc/SPEC/0f3c9a1b2d4e`), so an edit that only moves it keeps its
entry; one that changes its text renames it. So a change to the oracle that loses a rejection shows, though a
stricter compiler alone would only be reported
(`test/cli/oracle_rejections.sh` checks that both fire). When the
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
the oracle names (C1–C9, B1–B4). A different verdict, or none, fails
the set. These lines are
the oracle's own tests: each of the oracle's header rules (a subject
that is a place, a made value, a part of one, a lend of one, or a
branching value) has tests that state its verdict, so the change that
builds a planned rule can rely on the oracle to catch what it gets
wrong. By hand:

```bash
bin/rig-oracle -v file.rig            # every function's two verdicts
bin/rig-oracle --explain main file.rig  # the lowered core of `main`
bin/rig-oracle --stats --list .zig-cache/rig-tests/oracle/tests.list  # why it abstains, by count
bin/rig-oracle --sema -v file.rig     # also functions the compiler's
                                      # semantic checks rejected
```

## Proving a refactor changed nothing

```bash
tools/equiv.py OLD_RIG NEW_RIG [-j N] [--keep DIR] [--no-cache]
```

runs two compilers over every tracked program, every case of `test/rig`
(written out as programs by `swarm test/rig.rip tree`), and every
```` ```rig ```` block in the docs, and compares what they print for `parse`,
`normalize`, `check`, `check --facts`, and, for an accepted program,
`check --facts=sema`, `check --facts=storage`, `emit` (the root module),
and `pkg`: a hash of the whole package that `RIG_SANITIZE=1 rig emit`
writes, every module, the standard library's shims, and the runtime with
its sanitizer, so a change that shows only in another module or in
sanitized code is still seen. It lists each program whose output
differs, with the sections that differ (`--keep` saves both outputs, and
both packages for `pkg`), and exits 1 if any does. Build the old
compiler from the base commit and copy `bin/rig` aside first. A
refactor's every difference is a planned rule or a fixed bug, and its
pull request lists them.

The old compiler's results are cached in `rig-equiv-cache` in the
repository's git directory, by a hash of its binary, the section, the
program's path, and the contents of the program and of every module
beside it that a `use` could name; so a rerun against the same old
compiler runs only the new one. `--no-cache` runs both.

## The differential run of the proven checks

```bash
swarm test/rig.rip proofs        # programs with a proven test
swarm test/rig.rip proofs-all    # every program
```

runs the tests the compiler omits (docs/INTERNALS.md, "Proven checks")
three ways, for each `test` and `bomb` case (but known bugs) and example
that `rig check --facts=proofs` lists a test for: in
debug, where every omitted test is still made as an assertion, with
`--release`, and with `--release` and `RIG_NO_PROOFS=1`, where emit
omits nothing. The three runs must print the same, exit the same, and
panic with the same message, and no proven check may fail. It builds
each program three times, so it runs by hand, after a change to the
proofs (`src/proofs.zig`), and neither `core` nor `all` includes it.

## Known bugs

A known bug is a case of `test/rig` written as Rig should behave, with
what goes wrong today in its first comment, and marked `known: true`:
the case passes while it fails, and fails the day it passes. Fix the
bug, and the case says to take the mark off; take it off, and the
comment about the bug, in the same commit.
