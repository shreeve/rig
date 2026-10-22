# syntax-a: resume here

Branch `syntax-a`, worktree `../rig-syntax-a`, pushed to origin. Head
b6296ea1 (base faceba15). The working tree was clean at the checkpoint,
so no "work in progress" commit was needed: every change is in the 12
commits below.

Helper worktrees: `../rig-syntax-a-base` (faceba15, detached, for
comparisons) and `../rig-syntax-a-equiv` (syntax-a with
`src/runtime.zig` from faceba15, built to `syntax-a/rig-equiv`, so that
emit/pkg comparisons are not swamped by the one runtime comment change).
Saved in `.git/revamp/r3/syntax-a/`: `rewrite.py` (the tree-wide
rewrite; `scan`/`apply`, `--only=spacing,drop,closure`; idempotent:
`rewrite.py scan` in the worktree reports "0 files to rewrite"),
`verify_drop.py` (cross-checks drop detection against the old
compiler's `--facts`: 4828 accepted programs, 0 disagree),
`compare_rewrite.py` (written, NOT yet run: old compiler on original
source vs new compiler on rewritten source), `rig-base` (faceba15
build), `rig-equiv`, `suite.txt`, `corpus-partial.txt`.

## Commits (faceba15..b6296ea1)

- 3842800b Drop with a statement `<x`; a statement `-x` only negates
- a31342cf Rewrite drop statements `-x` as `<x` (rewrite.py)   [script]
- 52f85693 Write drops as `<x` in tests and docs, and reject a closure's last-line `<x` with a hint
- e203eb89 Reject an operator spaced on one side only, a detached postfix, and a spaced member dot
- 1bf91475 Balance the spacing of operators in the tree (rewrite.py)   [script]
- 6277f00c Document the spacing rule and the pairing of `?` and `!`
- 6803c0f6 End a multi-line closure body with its bracket on a line of its own
- d12bd178 Lay out multi-line closure bodies with the bracket on its own line (rewrite.py)   [script]
- 8c4f2ebd Document the closing bracket of a multi-line closure body
- 1fbba781 Say in CORE what `?` promises about a Cell
- 6a8f6fc6 Add TODO.md with the agent tooling item
- b6296ea1 Say `<x` for a drop in the runtime's comment

## Status of the items

1. `<x` drop: DONE (compiler, tests, docs, oracle). 435 drops rewritten by
   script; 3 closure-tail cases fixed by hand (R16-rs3, drop_captured_resource,
   match_captured_payload_move); 3 corpus probes (audit-frontend-b3,
   review-sc3-nh5/nh6) left as `-x`, which now negates and runs.
2. Spacing: DONE (lexer records, Parser reports after a successful parse,
   all violations at once, max 32). Corpus probes whose point was odd
   spacing are left as-is and are now rejections (list: SPACING_KEEP in
   rewrite.py). `whitespace_insensitive.rig` split into a behavior test of
   the allowed forms and `reject/syntax/unbalanced_spacing.rig`.
3. Closures: DONE (lexer: hanging close, a closing line that starts with
   anything else, wrong indentation; `reject/syntax/closure_body_close.rig`).
   Script inlines a one-line body, else puts `)` on its own line, and moves
   `# error: L:C:` directives. d04 corpus probe fixed by hand (kwargs).
4. CORE Cell sentence: DONE, in sentence 4's paragraph, right after the
   bold sentence (`?x` lends ... (§4)). SPEC §7 Lending states it and the
   exact rule.
5. TODO.md: DONE, Map row in AGENTS.md; vocab/doc/style accept it.
6. `?`/`!` docs: DONE: README tour (new first subsection with table and a
   run example), WELCOME (central idea), DESIGN (rationale paragraph).

## What remains

- Gates on the head (through heavy.sh, one at a time):
  - suite `./test/run --delta`: DONE at b6296ea1: 2913 passed, 0 failed,
    3 pending (suite.txt).
  - corpus `./test/run --delta corpus`: CANCELLED at the checkpoint
    (no failure printed before the cancel). Rerun.
  - `test/matrix.py --delta`: not run. Its templates may break the spacing
    or closure rules; `"drop": dict(lines=["<v", "3"])` already updated.
  - `zig build test --cache-dir "$(mktemp -d)"`: passed during the work
    (rerun on the head).
- Equivalence, not run:
  - `test/equiv.py syntax-a/rig-base syntax-a/rig-equiv -j N` from the
    worktree: every program both accept must emit identically.
  - `compare_rewrite.py syntax-a/rig-base ../rig-syntax-a-base
    syntax-a/rig-equiv ../rig-syntax-a -j N`: rewritten vs original.
    Expected differences: hand-edited tests (new messages), spacing
    probes now rejected, and possibly closure-layout line numbers.
  - The runtime comment (b6296ea1) changes every package: explain it,
    and compare with rig-equiv.
- PR description: write `.git/revamp/r3/pr-syntax-a.md` in the style of
  pr-ignored-bang.md, with a v0.3.0 migration section:
  `-x` → `<x` ("this expression does nothing as a statement; to drop `x`
  now, write `<x`"), `a <b` → `a < b` ("an operator has the same spacing
  on both sides; write ..."), `f() !` → `f()!`, `w . get()` → `w.get()`,
  hanging `print(x))` → `)` on its own line ("a closure body below its
  bar list ends with `)` on a line of its own ..."). Don't push further.
- Coordinator's note for the ?/! docs: no general claim about the
  `(!set).insert(k)` form was added.

## Design questions hit (decided conservatively; report to the owner)

- A closure's last line is its value (as `<x` there always was), so in a
  closure that gives no value (`?sub` closure) a last-line `<x` is no drop.
  The checker rejects it with "write `_ = <q`". Making it a drop needs the
  closure's type in the parser, or a fact all passes read.
- `.` "no space on either side": a line break before `.` inside brackets
  is still allowed (SYNTAX documents method chains across lines;
  `line_joining.rig` tests it). Spaces on one line are rejected.
- `f (x)` / `xs [0]` (space before a call or index bracket) stay allowed:
  not operators, and SYNTAX documents `f (x)`.
- `=` and the compound assignments count as infix operators (`x =1` is
  rejected). `->`, `=>`, `:` and `,` are not checked.
- The Cell sentence says "a field whose type is a Cell"; a bare `?Cell[T]`,
  an element, or a Cell behind a `*T` in the view also change. CORE has
  the exact sentence; SPEC states the full rule.
- A statement `<e` of a non-name is `(drop (move e))`, read as `_ = <e`
  by every pass (typecheck `checkDiscard`, ownership's discard binding in
  `walkDrop`, emit `emitDiscard`, the oracle's `dropStmt`): small
  delegations, since `drop` held only a name before. Specified in
  INTERNALS (Parser wrapper bullet).
- Grammar conflicts: none (no `@conflicts`); the `drop_stmt` token is
  gone, and `drop` is a `@wrapper` kind the Parser wrapper builds.
