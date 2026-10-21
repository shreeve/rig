# Rig tests

A Rig test file holds many small, named cases, each a few lines of Rig
and what they must do. One file covers one area (`text.rig.test`,
`json.rig.test`, `ownership.rig.test`), and every case is checked at one
of four points on the way from Rig source to a running program:

```
Rig source ──► rig ──► Zig ──► zig ──► executable ──► output
                │        │                              │
              fail     code                     test, bomb
```

| Verb | Built? | Run? | Passes when |
|---|---|---|---|
| `code` | to Zig | no | rig emits the Zig the case gives |
| `fail` | no | no | rig rejects the case, with the errors it gives |
| `test` | yes | yes | the case prints the result it gives, and exits cleanly |
| `bomb` | yes | yes | the case panics with the message it gives |

Zig is trusted: it only turns the emitted code into something to run.

## A test file

```
# std.text: text as bytes, runes, units, and chars.

test "building a string from parts", "ab"
  String("a", "b")

test "a parse of empty text fails, and the caller handles it", true
  use std.text
  text.parse_bool("") catch |e| (e == text.ParseError.invalid)

test "splitting on a space", '''
  a
  b
  c
'''
  use std.text
  for w in text.split("a b c", " ")
    print(w)

bomb "a char boundary past the end", "the index is out of bounds"
  use std.text
  text.char_boundary("ab", 9)

fail "a byte function takes a U8", "does not fit in `U8`"
  use std.text
  text.is_digit(300)

code "a call into std.text calls the module's function", "__rig_m2_std_text.is_digit(55)"
  use std.text
  text.is_digit(55)
```

- **A case** starts at a line `verb "name"` at the left margin; its
  body is the indented lines after it, up to the next line at the left
  margin.
- **A body is statements**, run as `main`'s, with no `sub main()`. Its
  declarations (`use`, `fun`, `sub`, `obj`, `enum`, `error`, `type`,
  `extern`, `inline fun`) are lifted to the top of the case's program. A
  body that declares `main` is a whole program, used as written, and so
  is one marked `whole: true`.
- **A `use` at the left margin of the file** serves every case that names
  a member of the module (`text.` for `use std.text`) and binds no name
  of its own the same, since Rig rejects a program that imports a
  module and binds its name.
- **A program of several files** gives the others after its body, each
  `file "PATH"` at the body's margin with its lines two spaces in. A
  position in one of them counts from that file's first line.
- **The item after the name is the case's result:**
  - `test`: a Rig value, `true`, `42`, `"ab"`, `none`, `[1, 2]`. The case
    passes when what it prints is what `print` of that value prints. A
    body that prints nothing itself has its last line printed.
  - `bomb`: text its panic message contains.
  - `fail`: text an error contains, `"L:C: text"` to pin its position,
    counted from the body's first line; several items for several
    errors.
  - `code`: Zig the emitted root module contains, compared without
    regard to spacing.
- **`'''` opens a result of many lines**, closed by `'''` alone at the
  left margin; its lines are written two spaces in.
- **Options follow as `key: value`:** `release: true` (also built and run
  in Zig's safe mode), `timeout: SECONDS` (default 120), `exit: N` (the
  status a `test` exits with), `errors: N` (exactly N errors, for a
  `fail`), `prints: "TEXT"` (what a `bomb` prints before it panics),
  `stderr: "TEXT"` (what a `test` writes to stderr), `seeds: K` (a
`test` or `bomb` also runs deterministically with each seed from 1 to
K, `RIG_SEED`, and gives the same result each time), `whole: true` (the
  body is a whole program, used as written), `file: "NAME.rig"` (the
  name of the case's program file, by default its name, `split_on_a_space.rig`;
  what a program prints about its own place names it), `known: true` (a
  known bug: the case is written as Rig should behave, passes while it
  fails, and fails the day it passes, to have the mark taken off).

Every case that runs is held to the sanitizer: a leak or a use of freed
memory fails it, and so does a panic in a `test`. A `fail` the compiler
crashes on fails too.

## How a file runs

1. **Read.** The file is split into its cases, and each becomes a program
   of its own.
2. **`code` and `fail`** cases are checked one by one: each is compiled
   alone, so one the compiler rejects affects no other.
3. **`test` and `bomb`** cases are built into **packs**: one executable
   holding the cases of several files of one family (the area's part
   before `-`: `types-misc-1` is of `types`), up to 400 cases and never
   part of a file, compiled once with one copy of the runtime (`rig
   batch build`). Cases with `release: true` are also built into packs
   of their own, up to 200 a pack, in Zig's safe mode.
4. **Each case runs alone**, as its own process: `rig batch run PACK N`
   starts case `N`, so a panic, a leak, or a crash ends only that case.
   On macOS a case's panic files no crash report.
5. **A case left out of a pack** (rig rejects it, or its Zig breaks the
   pack's build) runs alone, with `rig run`, and reports its own error.
   A pack Zig will not build is built again without the programs Zig's
   errors name, so only those run alone; when its errors name none, all
   its cases do.
6. **Nothing unchanged is redone.** The runner reads every file on each
   run (well under a second for all of them), and keys each pack by the
   compiler and its cases' programs: a pack whose key is unchanged is
   not built again, so editing only a case's expected result rebuilds
   nothing, and when the key matches it runs neither rig nor Zig. `rig
   batch build` keeps a key of its own, of every file it writes, how Zig
   builds them, and which Zig, and skips Zig when it matches. Changing a
   case rebuilds its pack alone. A new compiler runs rig over every pack
   again, but Zig only over the packs whose Zig it changed: a change to
   the checkers alone compiles none, and a change to the runtime every
   one.
7. **Packs are shared.** Each builds in the build store,
   `rig-build-store` in the repository's git directory (or
   `$RIG_BUILD_STORE`; empty, in the pack's own directory), under a hash
   of what Zig compiles, so a pack that any worktree has built, with the
   same Zig, is never compiled again: a new worktree's first run
   compiles only what its changes changed. Within a pack, a file that
   several cases' programs share (a module of the standard library, for
   one) is one file that Zig compiles once, not once a case. The runner
   removes the store's entries that no build has used for five days.

`test/rig.rip` does this with Rip's Swarm. Its setup builds the compiler
with its own checks on (`-Dself-check=true`), the reference ownership
checker, and the unit tests, in one `zig build` that compiles them at
once, then reads the files. A pack that needs building is a job of its
own, `build.zig.<rank>.<pack>.debug` or `.release`, which Swarm starts
before every other job but `build.unit`, the largest first: the jobs
that need no pack (the scripts of `test/cli`, the oracle, `fail` and
`code` cases) run while the packs compile, and a `test` or `bomb` case
waits only for its own pack. Each job checks one case and lands in
`done/` or, with its reason in `errors.log`, in `died/`. Swarm runs a
job per CPU at once (`-w N` chooses another number; more than the CPUs
is slower, as each job waits on a process of its own), and each job's
time goes to `.swarm/times`.

Beside the test files, the runner reads the docs' examples, each
```` ```rig ```` block of a Markdown file a case (below), and two
directories of whole programs where they are: `examples/`, each a `test`
whose `# expect:` block is its result, and `test/torture/`, bad input
`rig run` must reject with a position and never crash on. It also runs
the scripts of `test/cli`, each in an empty directory of its own with
`RIG`, `ROOT`, `ZIG`, `RIG_OUT_DIR`, `RIG_TESTS` (the cases as files,
below), and `TIMEOUT_CMD` set, passing when it exits 0, and the
compiler's own Zig tests (`zig build test`). `RIG_OUT_DIR` lasts from
run to run, so a program a script builds unchanged is not compiled
again: `rig build` copies the executable it kept, and a script's own
Zig command runs through `zig_once` (`test/cli/_lib.sh`), which skips it
while its command, Zig, and inputs are the last run's. Every program
still runs, and is checked, every time. A run in which a job died lists
each with its reason and exits 1.

The checks come in tiers. `core`, which a run with no names checks, is
every test file but the probes', the doc examples, the examples, the
torture input, the unit tests, and the reference ownership checker, and
takes seconds. The scripts of `test/cli` take minutes, since several
build dozens of programs one by one, and run when named. `probes` is
the cases of `test/rig/probes-*.rig.test`, the probes of past reviews:
they would double the core's time, and what the core wants of them, the
oracle's verdicts, its oracle job checks anyway. `proofs`, the differential run
of the proven checks, builds each program three times, and runs only
when named, by hand, after a change to the proofs:

```bash
swarm test/rig.rip              # core
swarm test/rig.rip cli          # the scripts of test/cli
swarm test/rig.rip probes       # the probes of past reviews
swarm test/rig.rip all          # core, cli, and probes
swarm test/rig.rip std-text     # test/rig/std-text.rig.test alone
swarm test/rig.rip doc-SPEC     # SPEC.md's examples alone (doc: every doc's)
swarm test/rig.rip tree         # only write the cases out as programs (below)
swarm test/rig.rip proofs       # by hand (proofs-all: every program)
```

## Doc examples

Every ```` ```rig ```` block in the Markdown files at the root and in
`docs/`, `docs/learn/`, `docs/launch/`, `docs/design/`, `docs/internals/`, `examples/`, and `test/` is a
case, so the docs cannot drift from the compiler. Each doc is an area,
`doc-<name>`: its path without `.md` or a leading `docs/`, slashes made
dashes (`doc-SPEC`, `doc-CORE` for docs/CORE.md, `doc-learn-01-sigils`
for docs/learn/01-sigils.md). The words after `rig` on the
opening fence, and the block that follows, give the contract:

| Block | Case |
|---|---|
| ```` ```rig ```` and an ```` ```output ```` block | a `test`: it prints exactly the output, sanitizer-clean; a ```` ```stderr ```` block after it (or alone) is its stderr, and ```` ```stderr exit=N ```` its exit status |
| ```` ```rig ```` alone | `rig check` accepts it |
| ```` ```rig reject ```` and an ```` ```error ```` block | a `fail`: each line of the error block is in a diagnostic, `L:C: text` pinning its place in the block |
| ```` ```rig fragment ```` | it parses |
| ```` ```rig facts ```` and a ```` ```facts ```` block | `rig check --facts` prints exactly the facts |
| ```` ```rig file=m.rig ```` | module `m.rig` of the next example's program; `file=dir/m.rig` is a file of the directory module `dir` |
| ```` ```rig pending ```` | a rule decided but not built (below) |

A block's program is named `main.rig`. Its `test` cases go into the
docs' packs like any file's.

A ```` ```rig pending ```` block shows a decided rule's behavior: with an
`output` block a program that prints it, with an `error` block one the
check rejects, alone one the check accepts. It passes while it fails for
want of the rule (rejected, accepted where it must be rejected, rejected
with other messages, or printing something else), fails on any other
failure (a timeout, a crash, a leak, a program that did not run), and
fails the day it works, saying to make it ```` ```rig ````. A block that
breaks these rules (an unknown word, an unclosed fence, an `output`
block after `reject`) is a case that fails, saying how. A failure names the doc and the line of the
opening fence (`SPEC.md:160`). `doc` names every doc's area.

## The pack

A pack is the `test` and `bomb` cases of a few files as one program. Given a
case's number, `PACK N` runs that case and nothing else, handing it the
arguments after the number. Planned, so that each pack is a test suite of
its own, runnable anywhere without a runner: its listing, numbered and
described from each case's first comment; choosing a case by name; and
`PACK all -j N`, which runs every case as its own process and judges it
from expectations built into the pack.

## Converting tests

`tools/to-rig-test.py OUT.rig.test "TITLE" TEST...` writes tests written
the older way, each a program of its own file (`<name>.rig`, or
`<name>/main.rig` with its other files beside it) with its expectations
in directives, into one test file. A test under a `reject/` folder
becomes a `fail` case, one with `# expect-panic:` a `bomb` case, and any
other a `test` case. Its directives become the header's result and
options, its `sub main()` goes, and the positions its `# error:` lines
pin move with its statements. A test keeps its whole program where
removing `main` would change it: top-level code other than
declarations, a line of `main` less than two spaces in, a declaration
nested in `main`, a position pinned to `main` itself, or a comparison
of stderr. A test of several files keeps its program too, its other
files following as `file` blocks.

## Other checks

The runner writes every `test`, `bomb`, and `fail` case out as a file of
its own: `behavior/<area>/<name>.rig` and `reject/<area>/<name>.rig` (or
`<name>/main.rig`), under `.zig-cache/rig-tests/tree`. The scripts of
`test/cli` read them there (`$RIG_TESTS`), `tools/equiv.py` compares two
compilers over them (`swarm test/rig.rip tree` writes them alone,
building and running nothing), the compiler's unit test of emit's unit
order reads the `emit` and `proofs` programs there, and the oracle
(`test/oracle`) reads them by those names: its `tests` set (the probes
of past reviews among them), with the examples, its `docs` set (every
doc example but fragments, each named by its doc and a hash of its text,
so an edit that only moves it keeps its name in
`test/oracle/rejections`), its `matrix` set (`test/matrix.py --oracle`),
and its `lint` check are jobs of the core. A `fail` case whose
diagnostic suggests a lend of a place as a path's base also has each
hint checked (`test/hints.py`). A test file a tool writes names the tool
on its first line (`written by tools/NAME.py`), and a core job,
`generated.<file>`, runs the tool's `--check`, which fails when the file
is not what the tool would write now.

## The reference ownership checker

`test/oracle/` is a second ownership checker, written from
[CORE](../CORE.md) and SPEC's ownership sections without
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

```text
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

## Why

One Zig compile per file replaces one per case, and a pack is compiled
only when it changes. The 2,964 behavior and rejection tests, in the 55
files of `test/rig` and with the release runs 3,257 jobs, measured on
the Mac with 4 cores, against the bash runner it replaced, which
ran them as files of their own:

| | Wall time | CPU time |
|---|---|---|
| the bash runner, each a file, no caches | 744 s | 2,891 s |
| `swarm test/rig.rip`, every pack compiled | 73 s | 386 s |
| the same, nothing changed | 11 s | 63 s |

With the docs' examples, the examples, the torture input, the unit
tests, and the oracle, the core is about 4,100 jobs and takes about 15
seconds when nothing changed; `all`, with the 65 scripts of `test/cli`
and the probes, about 8,200 jobs and a minute. A script keeps only what
needs the command line and builds nothing it built before, so none takes
more than about 20 seconds. After a change to the checkers alone, no
pack compiles again; after a change to the runtime, every pack does,
once, and the 31 packs of `all` take about 250 CPU seconds, where the
167 packs of one file each took about 700.

The verdicts are the same. A case runs in a few milliseconds; a warm
run's time is the cases themselves, a few of which are deliberate
sweeps (`text find any` searches 2.4 million times in a debug build
under the sanitizer). Every case still runs alone, so isolation is
unchanged, and `code` and `fail` cases build nothing at all.

Errors and panics are tested differently because Rig makes them
different. An error is a value a `T!` function returns, and a caller
handles it with `catch`, so a `test` case checks it in the program. A
panic is a bug (an index out of bounds, an overflow, a division by zero
the compiler cannot see) that no caller can catch, so a `bomb` case
watches its process end from outside.
