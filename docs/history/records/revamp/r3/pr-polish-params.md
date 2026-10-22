# Polish: parameter lists on every definition, Rig's own builtins, a style check

Two syntax decisions of 2026-10-07 (rig-questions.md, "Function
definitions write their parameter list" and "Rig's own compiler
builtins"), built with no change to ownership, and a style check that
keeps Rig's own code written one way.

The branch is two commits:

1. **The compiler, docs, and the check** (hand-written).
2. **The mechanical rewrite** of tests, examples, std, and the docs'
   ```` ```rig ```` blocks, produced only by
   `.git/revamp/r3/polish_rewrite.py` (not shipped). The script is
   idempotent; re-run it after merging main to rewrite any newly added
   programs.

## A function always writes its parameter list

`sub main()` and `fun answer() -> Int`, as calls (`f()`) and function
types (`sub()`) already write it.

- **Where it is enforced.** The grammar still parses a definition without
  `()`, so that the Parser wrapper (`src/rig.zig`, `paramList`) can
  reject it at its name with the whole header to write. Every such
  definition in a file is reported in one run, not only the first, so
  migrating a file takes one pass. The grammar's rules are unchanged
  (only comments), so `src/parser.zig` regenerates byte-identically and
  the grammar still has no conflicts.
- **Forms checked:**

  | Form | Before | Now |
  |---|---|---|
  | top-level `fun` / `sub`, `main` | `sub main` | rejected; fix-it `sub main()` |
  | failing `sub` | `sub save!` | `sub save()!` |
  | generic | `fun first[T, n: Int] -> T?` | `fun first[T, n: Int]() -> T?` |
  | method, `pub` method (structs, enums, generic types) | `pub fun get -> Int` | `fun get() -> Int` |
  | `extern fun` / `extern sub` | `extern sub halt` | `extern sub halt()` |
  | `extern zig` block declarations, `pub` ones | `pub fun one -> Int` | `fun one() -> Int` |
  | `drop(!self)` | always had its list (the grammar requires it) | unchanged |
  | `test "name"` | not a function; takes no list | unchanged |
  | closures | a bar list is required (`\|\| body`) | unchanged |
  | function types | `fun() -> T`, `sub()`, `sub()!` already required `()` | unchanged |
  | enum variants | `circle(r: Int)`, or a bare `none` (not a function) | unchanged |

- **Docs.** SYNTAX's sentence "A function with no parameters may leave
  out the empty `()`" is replaced by the rule, with a `rig reject`
  example; the generics paragraph now says `sub show[n: Int]()` is
  called `show[3]()`; the grammar summary shows `params` as required.
  SPEC, WELCOME, README, INTERNALS, STD, DESIGN, ROADMAP (the
  formatter item no longer says "`sub main` rather than `sub main()`"),
  zig-0.17, and examples/README had prose mentions of parenless headers
  updated by hand. `main`'s diagnostic now reads "`main` must be
  `sub main()`, or `fun main() -> Int` ...".

## Rig's own builtins

- `@size(T)`, `@align(T)`, `@name(T)`, and `@type(x)` (only as their
  argument, as `@TypeOf` was) work anywhere, and emit as Zig's
  `@sizeOf`, `@alignOf`, `@typeName`, `@TypeOf`.
- Zig's builtins keep their Zig names and work only inside `raw`: the
  casts, and Zig's four names for Rig's queries.
- **Inside `raw`, both spellings work** (`@size` and `@sizeOf` alike),
  so raw code can be written either way and moving code into `raw`
  never breaks it.
- Outside `raw`, Zig's name gets a fix-it that rewrites the whole call,
  its argument included, reported once (`@alignOf(@TypeOf(x))` gives one
  error, "write `@align(@type(x))`").
- A keyword after `@` now reads as a name (`@type`), in the lexer
  rewriter.
- SPEC §5's placeholder `@name(args)` became `@builtin(args)`, and the
  section now lists Rig's four and Zig's, with a running example and a
  `rig reject` example. SPEC §15's list says "one of Zig's builtins".
- SPEC's other `@` uses were checked: `@intCast` (§15 example) is inside
  `raw`; `@as`, `@splat`, `@backingInt`, `@intCast` in WELCOME and
  INTERNALS are tables of the Zig Rig emits, not Rig code. The prose
  `@sizeOf(T)` in SPEC's Bytes section and INTERNALS became `@size(T)`.
- **Flag for the design owner:** `@name(T)` returns the name the emitted
  Zig gives the type (`@name(Int)` is `i64`, `@name(Bool)` is `bool`),
  exactly as `@typeName` did. SPEC says so and a doc example checks it.
  Giving Rig's name (`Int`) instead would be a behavior change, left for
  a decision.

## The style check

`./test/run style` (a whole-program check, like `vocab`, in perl, about
1 s) reads the Rig in `test/` (all but `test/torture/`, whose files are
malformed on purpose), `examples/`, `std/`, and every ```` ```rig ````
block of the Markdown files:

- a definition writes its parameter list (redundant with the compiler
  except in `rig fragment` blocks, which are only parsed);
- exactly one blank line between top-level declarations; one-line
  declarations (`use`, constants, `extern`, `type`) may stand together
  with none;
- no two blank lines in a row;
- no blank first or last line, and a file ends with a newline;
- no line of code ends in spaces (a comment may: an `# expect:` line can
  need them).

A file or doc block whose expected errors are the definition rule's own
diagnostic may break that rule (the reject tests of it). No reviewer
finding named other style drift; the last three items are the drift the
check found in the tree (all in reviewer probes).

## Breaking changes

| Before (rejected now) | Fix-it |
|---|---|
| `sub main` | write `sub main()`: a function's parameter list is always written, even when empty |
| `fun answer -> Int` | write `fun answer() -> Int`: ... |
| `fun first[T] -> T?` | write `fun first[T]() -> T?`: ... |
| `sub save!` | write `sub save()!`: ... |
| `extern sub halt` | write `extern sub halt()`: ... |
| `@sizeOf(I64)` outside `raw` | write `@size(I64)`: Rig's builtin is `@size`; Zig's `@sizeOf` works only inside `raw` |
| `@alignOf(P)` outside `raw` | write `@align(P)`: ... |
| `@typeName(Int)` outside `raw` | write `@name(Int)`: ... |
| `@sizeOf(@TypeOf(x))` outside `raw` | write `@size(@type(x))`: ... |
| `@size(@TypeOf(x))` outside `raw` | write `@type(x)`: ... |

Changed diagnostics: the unknown-builtin and safe-builtin messages list
`@size`, `@align`, `@type`, `@name`; `main`'s signature message writes
`sub main()` and `fun main() -> Int`. Nothing that ran changes meaning.

## Tests

- Reject: `test/reject/syntax/definition_without_params{,_result,_method,_extern,_fails,_each}.rig`
  (each with its fix-it at line:col; `_each` checks every definition is
  reported), `test/reject/effects/zig_builtin_name_outside_raw.rig`
  (five fix-its, `# errors: 5`).
- Behavior: `test/behavior/effects/rig_builtins.rig` (the four builtins,
  in a generic, and inside `raw` under both spellings).
- Unit: the parser rejects each form with the header to write; a
  keyword after `@` lexes as a name.
- Docs: SYNTAX's and SPEC's new `rig reject` and running examples.

## The rewrite (commit 2)

`polish_rewrite.py` changed **6,469 `.rig` files and 11 Markdown files
(322 ```` ```rig ```` blocks)**: 6,480 files, +8,507 / -7,851 lines.

| Change | Files | Lines |
|---|---|---|
| `()` added to a definition | 6,158 | 7,627 definitions |
| a Zig builtin name outside `raw` renamed | 11 | 21 lines |
| a blank line inserted between top-level declarations, or a run of blank lines collapsed | 760 (all but 13 in `test/corpus/`) | +833 / -177 blank lines |
| trailing spaces removed | 26 (all reviewer probes) | |
| `# error: L:C:` pins moved with their line or column | 4 | |

By area: `test/corpus/` 5,811, `test/reject/` 356, `test/behavior/` 290,
`examples/` 9, `std/` 3, and the docs (SPEC, SYNTAX, WELCOME, README, FAQ,
`docs/CORE.md`, `docs/STD.md`, `docs/DESIGN.md`, `docs/INTERNALS.md`,
`docs/BEYOND-RUST.md`, `test/README.md`). No doc block's blank lines
changed. `docs/CORE.md`'s only change is the mechanical one: 53 headers gain `()`
(47 `sub main`), and its prose is untouched. No `test/ir/` or
`test/torture/` file needed a change.

What the script does, so a re-run after merging main is safe:

- It rewrites only code: strings and comments are left alone, and Zig's
  builtin names inside a `raw` block are left as written.
- A file or doc block whose expected errors are the new diagnostics
  themselves keeps its code as written. These are the reject tests and
  the SYNTAX/SPEC `rig reject` examples.
- Every `# error: L:C:` pin follows its line and column. In a
  multi-file test, a pin may name a line of another module, so the
  script moves it to wherever one of the files' rewrites took it and the
  rewritten program reports it. One test needed this:
  `foreign_array_len`, whose lib.rig pins went from 1:26/1:27 to
  1:28/1:29.
- It is idempotent: `--check` after a run reports 0 files.
- It is reproducible: after a comment fix in commit 1, a fresh run on the
  amended commit 1 gave a commit 2 byte-identical to the gated one.

Hand-edited in commit 1, because they are not `.rig` files or doc blocks:

- Rig embedded in `test/cli/*.sh` and in `test/matrix.py`'s templates,
  and in `src/` unit tests.
- One cli expectation of a rewritten file's note position
  (`diagnostics.sh`, 1:26 → 1:28).
- Five test comments that named the old builtins.
- The four `# error:` lines whose message text changed on purpose.

If cell-temp adds `.sh` tests with parenless Rig in `printf` strings,
they need the same hand edit.

## Gates and equivalence

**pup** (Linux x86_64, `pup-gates.sh`, -j 12, on 914c5910; the tip
since differs only by a comment), every gate green:

| Gate | Result |
|---|---|
| suite | 2,803 passed, 0 failed, 4 pending (main has the same 4 pending blocks), 175 s |
| corpus | 6,905 passed, 0 failed, 371 s |
| matrix | 5,099 programs: 2,370 ran clean, 2,729 rejected, 0 failed, 281 s |
| `zig build test` (fresh cache) | 126/128 passed, 2 skipped (the aarch64-only stack tests) |
| oracle doc vocab | 337 passed, 0 failed, 4 pending |

Logs: `.git/revamp/r3/logs/polish/pup.*`.

On the Mac, the suite on the first rewrite found 5 failures, all fixed in
commit 1, and the reruns were green:

- three `printf`'d `.sh` programs the hand edit had missed;
- one cli note position;
- the `_each` reject test, which the script rewrote because none of its
  pins carried the whole message.

**Equivalence 1: the tree before the rewrite, through the new compiler**
(`test/equiv.py`, main 5e551bc5's compiler against commit 1's, on pup).
9,272 programs, 7,672 differ, and every difference is one the rewrite
or a deliberate message change accounts for
(`logs/polish/equiv-preA.{log,classified}`):

| Why it differs | Programs |
|---|---|
| its own source has a parenless definition or a Zig builtin name outside `raw` | 6,409 |
| it uses a `std` module the rewrite changes (std's own definitions were parenless) | 59 |
| only the package hash: `src/runtime.zig`, embedded in every package, had a comment updated | 1,195 |
| a diagnostic's text changed on purpose (`main`'s signature message, the builtin lists) | 7 |
| new in this branch (`rig_builtins.rig`, SPEC's new builtin example) | 2 |

**Equivalence 2: the old program under the old compiler, against the
rewritten program under the new one** (`.git/revamp/r3/emit_equiv.py`,
`rig check`'s verdict, a rejection's messages without positions, and an
accepted program's emitted Zig):

- `.rig` programs: 8,929 compared. 17 differ, each only in a diagnostic
  text changed on purpose (`main`'s signature message, the builtin
  lists).
- Doc blocks: 332 compared, each old block paired with the block its
  rewrite became. 0 differ.
- The 8 new tests and 3 new doc examples have no counterpart.

So the rewrite changes no program's meaning, and **every accepted
program emits byte-identical Zig.**

## Nexus

The Nexus mirror needs `rig.grammar` (comments only) and `src/rig.zig`
(the `@` keyword rule and `paramList`) re-synced:
`.git/revamp/r3/nexus-sync-polish.diff`.
