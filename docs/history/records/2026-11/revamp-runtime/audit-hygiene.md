# Audit: tooling and docs hygiene (revamp, 2026-11-03)

Read-only audit of `origin/main` (edc481031). Nothing tracked was changed.
Checkers: `$TMPDIR/aud/{links,bench,p2}.py`. References searched: the repo
minus `.git`, `.zig-cache`, `.swarm`, `docs/history`; Trig and loc.

## 1. tools/ (36 files)

Every migration script named by MIGRATING-0.3.md or CHANGELOG stays. No script is dead by the
test "no reference anywhere". Findings:

| ID | file:line | finding | evidence | proposed fix |
|---|---|---|---|---|
| T1 | tools/chars_bench.rig | benchmark referenced by nothing; only its own header names it | `grep -rF chars_bench` finds only itself; one commit (2026-10-13) | move to `bench/text/` with a README row, or delete |
| T2 | tools/unicode_bench.rig | same: referenced by nothing | `grep -rF unicode_bench` finds only itself; one commit (2026-10-12) | move to `bench/text/` (or `bench/unicode/`), or delete |
| T3 | tools/drop-write-parens.py | a migration (CHANGELOG:776) missing from the `tools/` row of AGENTS.md and from MIGRATING-0.3.md | refs: CHANGELOG.md only | add it to the AGENTS map list, or MIGRATING-0.3 "Step 3" if 0.2.9 programs need it |
| T4 | AGENTS.md:79 | the `tools/` row omits tools that tests run: `markers.py`, `map-trace.py`, `inline_budget.py`, `inline_grid.py`, `terminal_ghostty.*`, `text_go.py`, `utf8_zig.zig`, `text_int_go.go`, `x25519-table.zig`, `zig-next.py`, `to-rig-test.py`, `verify-unicode.py`, `gen-unicode.py`, `basecheck`, `fetch-json-data.sh` | all referenced by test/cli or docs | name the groups ("generators and their `--check`s", "tool-backed test oracles") |
| T5 | tools/basecheck | referenced only by HANDOFF.md:35 (not AGENTS.md, not a test) | grep | fine to keep; mention in AGENTS "How a change is made" if it is a gate |
| T6 | bench/json/timers/time.py:1, timeall.py:1 | docstring says "the way tools/bench-json does"; the driver is `bench/json/bench-json` | `ls tools/bench-json` missing | say `bench/json/bench-json` |
| T7 | bench/json/json-string-stats.py:4 | usage says `tools/json-string-stats.py`; the file is in `bench/json/` | missing path | fix usage line |
| T8 | timers/time.py vs timers/timeall.py | two files with the same docstring (possible duplicate) | identical first lines | diff them; keep one |

Referenced tools that are not in this repo (Trig's or loc's, fine): `tools/light`, `tools/pup-rig`,
`tools/full-main`, `tools/trig`. `tools/gitdir.` and `tools/x25519-table.zig.` are sentence-end
punctuation matches.

## 2. test/cli/*.sh

`test/rig.rip:523,714` runs every `*.sh` not starting with `_` (as `cli.NAME`; `full` adds sweeps),
so no script is orphaned. Helpers `_lib.sh`, `_lsp.py`, `_frames.py`, `_name_grid.py` are each
sourced by a script; every directory in `test/cli/fixtures/` and every `.rig` there is referenced.

| ID | file | finding | evidence | proposed fix |
|---|---|---|---|---|
| C1 | (none) | no orphan script, no script for a removed `rig` subcommand | all `rig <verb>` uses are in `rig --help` (run, test, build, check, emit, batch, clean, lsp, parse, tokens, normalize) | none |
| C2 | migrate_029.sh, migrate_loop_view.sh, migrate_tool.sh, rename_task_bounds.sh, state_bounds.sh | test migration scripts for 0.2.9 to 0.3.0; stay until the tools go | tools kept per scope | none |

## 3. bench/*/README.md

Flags in README command lines checked against `--help` of actors, hash, http, json, net, tasks,
terminal, text drivers: no unknown flag. Paths in backticks checked.

| ID | file:line | finding | evidence | proposed fix |
|---|---|---|---|---|
| B1 | bench/hash/README.md:39 | `bench/hash/upstream/` is "missing" only because `fetch-deps` creates it (git-ignored); not a defect | text says "(which git ignores)" | none |
| B2 | bench/terminal/README.md:3 | names `std/terminal`; the file is `std/terminal.rig` | `ls std/terminal*` | write `std.terminal` |
| B3 | bench/terminal/README.md:66-69 | narrates: "growing them a row at a time cost `text` a third of its speed" | prose | "growing them a row at a time costs `text` a third of its speed; the first row reserves room for the rest" |
| B4 | bench/terminal/README.md:73-80 | "A scroll once cost most of its time...", "each SGR once looked its pen up in a list" | prose | present tense: "A scroll's cost is the fill of the new row: `@memset` of a U64 that is not 0 stores one cell at a time, so an empty cell is 0...; styles past 32 are found by key, since a list that only grows made `rgb` crawl" |
| B5 | bench/actors,http,net,tasks/PROGRESS.md | tables are dated history rows (ledgers, not current claims); each row carries a date and a PR | e.g. actors/PROGRESS.md:30 | none; READMEs do not present them as current |
| B6 | bench/*/README.md | no "now", "used to", "no longer", "previously", "for now" found | grep over 17 READMEs | none |

Stale-number check: the READMEs cite `guard.txt` rather than copying figures, apart from
bench/terminal (corpus speeds against Ghostty, undated: confirm against the last run).

## 4. Links (root *.md and docs/ except docs/history/)

Python checker, fenced blocks skipped (an inline "````" is not a fence), GitHub slugs, duplicate
headings suffixed. Files scanned: root and docs, about 70.

Broken relative links: **0** (missing files: 0; missing anchors: 0). Two apparent hits
(`tests.md#timing`, `../test/README.md#doc-examples`) came from a checker bug and resolve.

## 5. Timeless prose (outside history/ and CHANGELOG.md)

Skipped as correct: `now` meaning "immediately" (`<x` drops now, `ending it now`, `time.now`), "the old value" of an
assignment, "no longer than" (a length), "no more" (a bound), ZIG-0.17.md (about Zig's changes),
MIGRATING-0.3.md (a migration guide narrates change by design), HANDOFF.md status sections.
`today`/`still` describing what the compiler does (many in ROADMAP, CORE planned rules) are
present-tense statements of a gap; not listed.

| ID | file:line | finding | evidence | proposed fix |
|---|---|---|---|---|
| P1 | AGENTS.md:180 | "is now true" | "SPEC, CORE, STD... say what is now true" | "say what is true" |
| P2 | AGENTS.md:222 and HANDOFF.md:288 | "`area: what it now does`" (commit style) | an example subject | keep: names the commit form, but "what it does" is shorter |
| P3 | HANDOFF.md:298 | "The old names are rejected with a hint." | narration | "A raw builtin's old spelling is rejected with a hint." or drop |
| P4 | README.md:75-77 | "The `main` branch renames `Box`, `Vec`, `Text`, and `struct` to ..." | narrates the rename | "`^T`, `List`, `String`, and `obj` are 0.3's spellings of `Box`, `Vec`, `Text`, `struct`; v0.2.9 uses the old ones" (README release note; or move to CHANGELOG) |
| P5 | SPEC.md:6292 | "a function that can fail is rejected for now" | planned gap | "is rejected (a `rig pending` or ROADMAP row names the plan)" |
| P6 | SPEC.md:6138, 6193 | "as before any call" | refers to history | "as any call does" |
| P7 | SPEC.md:13122 | "a panic ends the program as before" | history | "a panic ends the program" |
| P8 | docs/design/apis.md:1465 | "where a closure now loads from the heap" | change | "where a closure loads from the heap" |
| P9 | docs/design/formal-plan.md:315 | "left out for now" | provisional | "Allocators as owners: out of scope; arenas with IDs. Revisit when a GPUI port measures the need." |
| P10 | docs/design/json.md:87 | "(a count of trailing zeros, now `m.trailing_zeros() >> 3`)" | change | "(a count of trailing zeros, `m.trailing_zeros() >> 3`)" |
| P11 | docs/design/iterators.md:238 | "Build chains as loops now; make a chain a value only when" | provisional | "Build chains as loops; make a chain a value only when" |
| P12 | docs/internals/INTERNALS.md:439 | "`match` arms parse as before" | history | "`match` arms parse as written" |
| P13 | docs/internals/INTERNALS.md:2124 | "made where it is written, as before, while it is false" | history | "made where it is written while it is false" |
| P14 | docs/internals/INTERNALS.md:2517 | "which every context uses as before" | history | "which every context uses" |
| P15 | docs/internals/INTERNALS.md:3073 | "the captured value's var now holds each of them" | change | "holds each of them" |
| P16 | docs/internals/INTERNALS.md:3734, 3742 | "lasts to the statement's end as before"; "temporaries are as before" | history | drop "as before" in both |
| P17 | docs/internals/INTERNALS.md:3834 | "`p`'s var now also views what `v` viewed" | change | "`p`'s var also views" |
| P18 | docs/internals/INTERNALS.md:4897 | "is emitted as before" | history | "is emitted unchanged" (or "as any other read") |
| P19 | docs/internals/INTERNALS.md:5391 | "is rejected as before" | history | "is rejected" |
| P20 | docs/internals/INTERNALS.md:6104 | "on a listed one it no longer rejects" | describes a test condition; borderline | "a listed rejection it stops rejecting" |
| P21 | docs/internals/backlog.md:180 | "now that `+k` of a `?K: Clone` clones in a generic body; today they take an owned `K`" | change | "since `+k` of a `?K: Clone` clones in a generic body; the three take an owned `K` today" |
| P22 | docs/internals/backlog.md:281 | "**A `?^T` field can no longer be filled from a parameter.**" | title narrates a change | "**A `?^T` field cannot be filled from a parameter.**" |
| P23 | docs/internals/scheduler.md:303 | "is one function, as before" | history | "is one function" |
| P24 | docs/internals/tests.md:286 | "not what the tool would write now" | change | "not what the tool writes" |
| P25 | docs/internals/tests.md:377 | "no longer rejects (`LOST`...)" | test condition; borderline | "stops rejecting" |
| P26 | docs/learn/07-generics.md:366 | "A `Point` that does not name `Ord` is now rejected" | change | "is rejected by the bound" |
| P27 | docs/learn/08-apis.md:87 | "The Python typo is now a compile error" | change | "The Python typo is a compile error" |
| P28 | docs/learn/09-tests.md:343 | "The failure is no longer luck." | reader's journey; fine as a lesson | optional: "The failure is not luck." |
| P29 | docs/learn/09-tests.md:464 | "cannot say something the compiler no longer does" | borderline | "cannot say what the compiler does not do" |
| P30 | docs/learn/01-sigils.md:185 | "the old name can no longer use it" | semantic ("after a move"), fine | none |
| P31 | docs/learn/07-generics.md:5 | "Go once took `interface{}`" | history of Go, not Rig | none |
| P32 | docs/MIGRATING-0.3.md:82 | "`self` is an ordinary name now" | migration doc | none |
| P33 | docs/internals/journeys.md:13 | rule: "no 'currently', 'now', or 'new'" | rule exists; P1-P29 break it elsewhere | add the check to a doc test (grep over docs for these words) |

Counts: section 1: 8 findings (2 delete-or-move, 3 doc, 2 stale path, 1 duplicate); section 2: 0
defects; section 3: 3 findings (2 prose, 1 name); section 4: 0 broken links; section 5: 33 rows
(about 27 true rewrites). Not an exhaustive reading of `still`/`today` (hundreds, mostly
present-tense gaps) or of ZIG-0.17.md (83 hits, about Zig changes).
