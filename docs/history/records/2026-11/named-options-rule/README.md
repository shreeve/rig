# The named-options rule (2026-11-22)

Step 1 of the owner's named options ([docs/design/options.md](../../../../design/options.md),
section 11; the decision is [named-options/](../named-options/README.md)):
**a parameter with a default is an option, and options are given by
name.** Required values come first, by position; a closure written last
fills its callback parameter; no parameter is exempt. Branch
`named-options`, from main 81cc259cd. Groups, spreads, object update and
the shorthand are later steps.

## What landed

| Part | Where |
|---|---|
| The rule: an argument by position that fills a parameter with a default is refused, "`by` has a default, so it is an option, given by name: `by: 2`; to pass it by position, remove its default" | `src/typecheck.zig` `checkArgs` |
| A closure written last fills the callback where its position would give an option (`closureParam`), in all three copies: `checkArgs`, `argViews`, generic inference | `src/typecheck.zig` |
| The edge rules at the declaration: no default on `_`; a required parameter after an option only if it takes a function | `src/resolve.zig` `paramDefaults` |
| A function with options is not a value (`optionsValue`, at a function's name, a module's function, and `Type.method`), and a generic body, whose calls go by position, does not call a method with options | `src/typecheck.zig` |
| `Time.new(hour, minute, second, ns = 0)`; `DateTime.add(duration:)` (its own commit, before the migration, so the migration could write `duration:`) | `std/datetime/` |
| The datetime position checks deleted: `ArgCheck.by_name` (`with`), `duration_add`, the positional part of `calendar_add` (an `Int` by position), and the "no positional argument" of the round checks. Kept: a `Date`'s time of day (a `Float` or `Duration` by position, a unit's keyword) and the increments of `round` and `floor`, which check values | `src/sema.zig`, `src/typecheck.zig` |
| The migration, driven by `rig check`'s own errors | `tools/migrate-options.py`, `test/cli/migrate_options.sh` |
| Tests | `test/rig/syntax-options.rig.test` (every kind of call, a duration option, the closure fill, the declaration rules, function values, a generic body); the datetime checks' fail cases now show the rule's messages |
| Docs | SPEC "Functions" and "Durations", SYNTAX §8 and §11 (`scaled(3, 2)` a refused case), STD (the makers, `dt.add(duration:)`), docs/learn/06-stdlib.md "Operands and options", design/datetime.md, design/options.md (step 1 built), CHANGELOG, MIGRATING-0.3.md "Options by name", HANDOFF, IDEAS (one copy of the makers' check) |

## The migration

The script inserts `name: ` where each refusal points, and `0` or
`second: 0` for a `Time.new` without its second, checking again until
nothing is refused (an error in a module hides the program's own). Run
over Rig's tree with a scratch build that had the rule:

| Source | Rewrites |
|---|---|
| tests (`test/rig`) | 465 |
| docs (STD 12, SYNTAX 1) | 13 |
| std (terminal 9, datetime 2) | 11 |
| tools (`unicode_ranges.rig`, `jiff-oracle/answer.rig`) | 7 |
| bench (`terminal/bench.rig`) | 1 |
| Trig | 67, on 49 lines |
| loco | 24, on 22 lines |

Most are the datetime makers' clocks and `ns`. The panel's count (326
sites) left out first parameters and `Time.new`'s second; this one has
both. Seven `fail` cases that showed the deleted checks' messages were
left out of the migration commit and rewritten with the rule.

Two lessons for the script: a test case or doc block is checked as the
runner writes it out (`test/rig.rip`, `program`), with a map from each
line back to the file; and a Trig tool whose modules are Trig's `src/`
(`tools/trig/main.rig`, `tools/checker/driver.rig`) is checked from a
build directory, `src/` with the tool's `main.rig` and the generated
`libtrees` and `buildinfo` (`tools/trig/gen-libtrees`), since checked
alone it cannot read its modules and gives no refusal. A check that
times out is printed as `MANUAL`.

`trig.patch` applies to Trig's origin/main f06b9c59 both alone and on
top of `datetime-phase1/trig.patch` and `datetime-phase3/trig.patch`,
which Trig's main still lacks; it was produced on top of them, where
`tools/trig/main.rig` checks clean under the rule. `loco.patch` applies
to loco's origin/main c6b5e38, and `rig/main.rig` and
`rig/loc/loc_test.rig` check clean under the rule.

## Verification

- `zig build`, `zig build test`; the core suite (`swarm test/rig.rip -w
  4`), and `unit` and `oracle`.
- `tools/emit-diff origin/main`, Trig from the patched copy: 2 of 38
  programs differ. Trig's `__rig_std_datetime.zig`: `DateTime.add`'s
  parameter is `duration`, and panic positions in `clock.rig` moved a
  line with `Time.new`'s comment. Trig's `libtrees.zig`: only the
  absolute paths of the two emit directories in its embeds. And
  `bench/terminal`'s `__rig_std_terminal.zig`: `scroll_clear` is no
  longer inlined by the rule, since its call `shift_up(..., keep:
  @keeps())` adds a `kwarg` node to the inliner's size
  (`inlining.size`), which puts it past `max_expanded` (320). A keyword
  emits nothing, so counting `kwarg` nodes as zero would keep the
  decision; that changes other functions' sizes and is left for its own
  change.
- `bench/check/guard.py`, fewest of 4 interleaved: main 2,162,685,681
  instructions, the branch 2,166,372,114 (0.17% more, within noise).
