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

## Code generation

Whether an argument is written by name never changes code generation
(design/options.md, section 5). Arguments reach Zig by position with
defaults filled at the call either way; the inliner's size of a function
(`inlining.size`) counted a keyword argument's node, so naming an option
could move a function past `max_expanded` (320), as `keep:` did to
std.terminal's `scroll_clear` in the migration. It counts a keyword
argument as its value now (`inlining: a keyword argument counts as its
value`, with a unit test). That keeps `scroll_clear` inlined, and it
changes 41 decisions in Trig, whose keyword calls were counted larger
than their positional forms before: 35 functions are inlined that were
not, and 6 are not that were. Own size, now and before, where a keyword
argument shrank the function itself; where the two agree, a callee's
expansion shrank:

| Function (Trig module) | Decision | Own size, now/before |
|---|---|---|
| `__rig_std_datetime.starts_with_date` | now inlined | 5/5  |
| `ast.get_host_signature_from_jsdoc` | now inlined | 25/25  |
| `ast.is_prototype_access` | now inlined | 14/14  |
| `ast.new` | now inlined | one of 21 functions named `new` |
| `checker.can_use_property_access` | no longer inlined | 22/22  |
| `checker.classify_property_name` | no longer inlined | 26/26  |
| `checker.clone_identifier` | now inlined | 33/35  |
| `checker.create_synthetic_expression` | now inlined | 27/34  |
| `checker.flow_frame_begin` | now inlined | 60/65  |
| `checker.get_containing_class_excluding_class_decorators` | now inlined | 57/64  |
| `checker.get_elaboration_element_for_jsx_child` | now inlined | 56/66  |
| `checker.is_compound_like_assignment` | now inlined | 25/25  |
| `checker.is_in_compound_like_assignment` | now inlined | 10/10  |
| `checker.new_call_signature` | now inlined | 18/18  |
| `compiler.cached_package_scope` | now inlined | 14/14  |
| `lexer.is_identifier_text` | now inlined | 27/27  |
| `lexer.scan_jsx_attribute_value` | now inlined | 11/11 43/43  |
| `lexer.strip_leading_js_doc_comment` | now inlined | 16/16  |
| `module.get_package_id` | now inlined | 59/63  |
| `parser.scan_jsx_attribute_value` | no longer inlined | 11/11 43/43  |
| `parser.parse_case_block` | now inlined | 33/33  |
| `parser.parse_namespace_import` | now inlined | 24/24  |
| `parser.reparse_jsdoc_comment` | now inlined | 60/60  |
| `printer.end_and_merge_lexical_environment_list` | now inlined | 51/51  |
| `printer.new_es_decorate_class_element_access_object` | now inlined | 35/35  |
| `semver.parse_hyphen` | now inlined | 58/62  |
| `transformers.anonymous_function_check` | no longer inlined | 19/19  |
| `transformers.transform_named_evaluation` | no longer inlined | 51/51  |
| `transformers.create_accessor_property_backing_field` | now inlined | 35/36  |
| `transformers.ed_is_anonymous_class_needing_assigned_name` | now inlined | 9/9  |
| `transformers.ed_property_access` | now inlined | 13/13  |
| `transformers.flatten_chain` | now inlined | 47/47  |
| `transformers.new_named_property_access` | now inlined | 13/13  |
| `transformers.output_file` | now inlined | 38/61  |
| `transformers.transform_named_evaluation_of_property_assignment` | now inlined | 35/35  |
| `transformers.transform_named_evaluation_of_property_declaration` | now inlined | 36/36  |
| `transformers.update_block_with_environment` | now inlined | 44/44  |
| `tsoptions.read_json_config_file` | no longer inlined | 26/26  |
| `tsoptions.for_each_property_assignment` | now inlined | 45/45  |
| `tsoptions.try_read_file` | now inlined | 20/20  |
| `vfsmatch.prefix_states` | now inlined | 21/21 41/42  |

## Measurements

- `tools/emit-diff origin/main`, Trig from the patched copy with its
  generated `libtrees` and `buildinfo`: the examples, every bench, and
  std emit the same Zig as main, bench/terminal's `scroll_clear` among
  them (inlined on both sides). Trig differs in its datetime module
  (`DateTime.add`'s parameter is `duration`, and panic positions in
  `clock.rig` move a line with `Time.new`'s comment), in the 41 decisions
  above, and in `libtrees.zig` only by the absolute paths of the two emit
  directories. emit-diff now names a program whose emit fails on both
  sides as not compared, rather than counting it identical; its std
  program no longer `use`s the prelude, which is built in.
- The check guard, fewest of 4 interleaved, branch first, with the
  inliner change: the branch 2,178,001,490 instructions, main
  2,178,701,973 (level).
- std.json, the tables and std.text (`bench/json`, `bench/hash`,
  `bench/text` `guard.py`, one `tools/mac-claim` each, the branch then
  main): every row within 0.1% of main's (json, text) or within 0.2%
  (hash).
- bench/terminal, rig-safe, under `tools/mac-claim`, interleaved, fastest
  of 5, MB/s main/branch: text 1611.3/1613.0, scroll 240.0/238.4, sgr
  324.5/325.9, tui 496.5/502.9, utf8 377.3/375.7, utf8-2027 352.4/352.7,
  rgb 465.2/466.5: level, the screens the same, the emitted Zig identical.
- Trig's own speed measurement, the A/B of PGO builds on pup at one
  checker (`tools/bench/ab`, docs/RESULTS.md), needs Trig's PGO pipeline
  (`tools/trig/pgo` on the build machine, BOLT on pup in a slot Rig opens)
  for both arms: it is the Trig session's to run on the 41 decisions,
  with its light gate.
- The core suite, `unit` and `oracle`, after each change.

## The review

An independent review at e1c84c02b found no hole for direct calls. Its
findings, fixed with a failing case first:

- A method that meets an API's gave the API's parameter a default, and a
  call through `{Shape}` or `T: Shape` then gave it by position: such a
  default is refused at the method.
- Fixes that did not compile: a `Date`'s time of day now shows
  `d.at(t).add(duration: 1.5)`; an unknown keyword where the one duration
  is an option shows `add(duration: 2)` or `timeout: 2`; a function given
  last where an option is names the parameter that takes it, `f: show`;
  and a bare `Int` given to a `Date`'s `add` names the likely intent,
  `add(days: 1)`, as the deleted check did.
- The script wrote `(by: a)` inside an argument's parentheses; the name
  goes before the whole argument now, and anything still refused in a
  file it changed (`each(3, step: 2, show)`, whose callback must then be
  named) is printed as `MANUAL ... still refused`.

Open, for the owner: a one-field object whose field has a default takes
it by position, `W(5)` for `obj W` with `n: Int = 3`. Constructors are
outside "a parameter with a default", and the design leaves them so.
