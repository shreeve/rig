# Decisions: `for x in !it`, and CORE on Static and holders

Implements the four approvals of 2026-10-10 ("all as recommended").

## 1. `for x in !it` is required for an iterator in a place
- `typecheck.zig`: `bare_place_advances` is false. A bare `for x in it` over
  a place whose type is an iterator is rejected: "write `for x in !it`: the
  loop advances `it`". A made iterator (`for w in s.words()`) stays bare.
  The index-binding hint and the read-lend hint now say `!it` too.
- Commit 1 is the output of `.git/revamp/r3/decide/rewrite.py` alone (44
  loops in tests, corpus, docs; it also shifts `# error: L:C:` columns on
  edited lines). It is re-runnable: `rewrite.py REPO RIG [JOBS]`.
- Commit 2 flips the switch, with the hand edits to SPEC, SYNTAX, INTERNALS,
  IDEAS, and the new test `test/reject/ownership/for_iterator_bare_place.rig`
  and a SPEC reject example.
- `test/matrix.py`: the place and field sources write `!`; the duplicate
  `bang` source is gone.
- `tools/migrate-0.3.py` rewrites the form by running `rig check` and
  inserting the `!` it asks for. It also accepts explicit file paths,
  processes `*.rig.tmpl`, and in `scan` prints a `HINT` for other text files
  with old spellings (never rewritten). Tests in `test/cli/migrate_tool.sh`.

## 2. CORE
Sentence 9 (no-loan homes keep text only as a `Static`), sentence 7 (a
`Static` and module constants live for the whole program), section 1
(`Static` is plain), section 4 (a `Static` reads as a `?String`, never
converts where written, nothing converts `?String` to `Static`), section 5
(holder sentence; the box of a view is `^?v`, as in SPEC). Two new examples
(a `Cell` of `Static`, and its rejection).

## Gates
- `./test/run --delta`: green except `parser`, which also fails on main
  0f602871 (src/parser.zig is stale against the sibling Nexus; not touched here).
- corpus: 10032 passed. matrix: 7140 programs, 0 failed.
- equiv against 0f602871: 12629 programs; 5 differ, all in `check --facts`
  (the changed diagnostics of the bare-`for` and `?c` hints and the new bare
  rejection). parse, check, emit and pkg (emitted Zig) are identical.
