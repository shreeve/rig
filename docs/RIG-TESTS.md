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
  text.parse_bool("") catch |e| e == text.ParseError.invalid

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
  `stderr: "TEXT"` (what a `test` writes to stderr), `whole: true` (the
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
3. **`test` and `bomb`** cases are built into the area's **pack**: one
   executable holding every such case, compiled once with one copy of
   the runtime (`rig batch build`). Cases with `release: true` are also
   built into a second pack, in Zig's safe mode.
4. **Each case runs alone**, as its own process: `rig batch run PACK N`
   starts case `N`, so a panic, a leak, or a crash ends only that case.
   On macOS a case's panic files no crash report.
5. **A case left out of a pack** (rig rejects it, or its Zig breaks the
   pack's build) runs alone, with `rig run`, and reports its own error.
6. **Nothing unchanged is redone.** The runner first hashes each test
   file with the compiler and itself; when that matches the last run's,
   it reads nothing and queues the jobs it saved then. Otherwise it reads
   the file, and keys each pack by the compiler and its cases' programs:
   a pack whose key is unchanged is not built again, so editing only a
   case's expected result rebuilds nothing, and when the key matches it
   runs neither rig nor Zig. `rig batch build` keeps a key of its own, of every
   file it writes and how Zig builds them, and skips Zig when it matches.
   Changing a case rebuilds its file's packs alone; a new compiler
   rebuilds them all.

`test/rig.rip` does this with Rip's Swarm. Its setup builds the
compiler with its own checks on (`-Dself-check=true`), reads the files,
and builds the packs;
each job checks one case and lands in `done/` or, with its reason in
`errors.log`, in `died/`. Swarm runs a job per CPU at once (`-w N`
chooses another number; more than the CPUs is slower, as each job waits
on a process of its own), and each job's time goes to `.swarm/times`.

Beside the test files, the runner reads the docs' examples, each
```` ```rig ```` block of a Markdown file a case (below), and two
directories of whole programs where they are: `examples/`, each a `test`
whose `# expect:` block is its result, and `test/torture/`, bad input
`rig run` must reject with a position and never crash on. It also runs the scripts of
`test/cli`, each in an empty directory of its own with `RIG`, `ROOT`,
and `RIG_OUT_DIR` set, passing when it exits 0, and the compiler's own
Zig tests (`zig build test`).

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
swarm test/rig.rip proofs       # by hand (proofs-all: every program)
```

## Doc examples

Every ```` ```rig ```` block in the Markdown files at the root and in
`docs/`, `examples/`, and `test/` is a case, so the docs
cannot drift from the compiler. Each doc is an area, `doc-<name>`: its
path without `.md` or a leading `docs/`, slashes made dashes
(`doc-SPEC`, `doc-CORE` for docs/CORE.md). The words after `rig` on the
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
doc's pack like any file's.

A ```` ```rig pending ```` block shows a decided rule's behavior: with an
`output` block a program that prints it, with an `error` block one the
check rejects, alone one the check accepts. It passes while it fails for
want of the rule (rejected, accepted where it must be rejected, rejected
with other messages, or printing something else), fails on any other
failure (a timeout, a crash, a leak, a program that did not run), and
fails the day it works, saying to make it ```` ```rig ````. A block that
breaks these rules (an unknown word, an unclosed fence, an `output`
block after `reject`) is a case that fails, saying how.

## The pack

A pack is the `test` and `bomb` cases of one file as one program. Given a
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
its own, where such a test was kept before test files held them:
`behavior/<area>/<name>.rig` and `reject/<area>/<name>.rig` (or
`<name>/main.rig`), under `.zig-cache/rig-tests/tree`. The scripts of
`test/cli` read them there (`$RIG_TESTS`), the compiler's unit test of
emit's unit order reads the `emit` and `proofs` programs there, and the
oracle (`test/oracle`) reads them by those names: its `tests` set (the
probes of past reviews among them), with the examples, its `docs` set
(every doc example but fragments, each named by its doc and a hash of
its text, so an edit that only moves it keeps its name in
`test/oracle/rejections`), its `matrix` set (`test/matrix.py --oracle`),
and its `lint` check are jobs of the core. A `fail` case whose
diagnostic suggests a lend of a place as a path's base also has each
hint checked (`test/hints.py`).

## Why

One Zig compile per file replaces one per case, and a pack is compiled
only when it changes. The 2,964 behavior and rejection tests, in the 55
files of `test/rig` and with the release runs 3,257 jobs, measured on
the Mac with cpuq's 4 cores, against the bash runner it replaced, which
ran them as files of their own:

| | Wall time | CPU time |
|---|---|---|
| the bash runner, each a file, no caches | 744 s | 2,891 s |
| `swarm test/rig.rip`, every pack compiled | 73 s | 386 s |
| the same, nothing changed | 11 s | 63 s |

With the examples, the torture input, and the unit tests, the core is
3,293 jobs and takes 11.5 seconds when nothing changed. The scripts of
`test/cli` add 77 jobs and about three and a half minutes: their job
time, 2,626 seconds, is 17 times the rest's, and the slowest,
`inline_budget`, takes 202 seconds alone.

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
