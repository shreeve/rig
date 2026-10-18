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
  `use`, `fun`, `sub`, and `obj` declarations are lifted to the top of
  the case's program. A `use` at the left margin of the file applies to
  every case. A body that declares `sub main()` is a whole program,
  used as written.
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
  `stderr: "TEXT"` (what a `test` writes to stderr).

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

`test/rig.rip` does this with Rip's Swarm. Its setup reads the files and
builds the packs; each job checks one case and lands in `done/` or, with
its reason in `errors.log`, in `died/`. `-w N` is Swarm's number of jobs
at once:

```bash
swarm test/rig.rip -w 6              # every test/rig/*.rig.test
swarm test/rig.rip -w 6 text json    # test/rig/text.rig.test and json.rig.test
```

## The pack

A pack is the `test` and `bomb` cases of one file as one program. Given a
case's number, `PACK N` runs that case and nothing else, handing it the
arguments after the number. Planned, so that each pack is a test suite of
its own, runnable anywhere without a runner: its listing, numbered and
described from each case's first comment; choosing a case by name; and
`PACK all -j N`, which runs every case as its own process and judges it
from expectations built into the pack.

## Converting tests

`tools/to-rig-test.py OUT.rig.test "TITLE" FILE.rig...` writes existing
behavior and rejection tests into one test file. A file under
`test/reject/` becomes a `fail` case, a behavior test with
`# expect-panic:` a `bomb` case, and any other a `test` case; its
directives become the header's result and options, its `sub main()`
goes, and the positions its `# error:` lines pin move with its
statements. A test whose top level holds more than declarations and a
plain `sub main()` keeps its whole program.

## Why

One Zig compile per area replaces one per case, and a pack is compiled
only when it changes. `test/rig/text.rig.test` holds the 43 tests of
`std.text`, `std.utf8`, `std.utf16`, and `std.unicode` that `test/run`
runs one by one. On the Mac, with 4 cores and the compiler built:

| | Wall time |
|---|---|
| `test/run` | 38 s (132 CPU-seconds) |
| `swarm test/rig.rip -w 4 text`, packs compiled | 12 s (20 CPU-seconds) |
| the same, one case changed | 5 s |
| the same, nothing changed | 2.7 s |

The verdicts are the same, and the release runs are included. A case
runs in a few milliseconds; nearly all of the 2.7 seconds is two cases
that walk Unicode's tables in a debug build under the sanitizer.
Every case still runs alone, so isolation is unchanged, and `code` and
`fail` cases build nothing at all.

Errors and panics are tested differently because Rig makes them
different. An error is a value a `T!` function returns, and a caller
handles it with `catch`, so a `test` case checks it in the program. A
panic is a bug (an index out of bounds, an overflow, a division by zero
the compiler cannot see) that no caller can catch, so a `bomb` case
watches its process end from outside.
