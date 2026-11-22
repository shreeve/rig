# Datetime phase 4: `TimeZone` (2026-11-22)

Phase 4 of the datetime design (docs/design/datetime.md §7.4 to §7.7, §11
phase 4, the owner's approved v3 with its amendments of 2026-11-22),
written to "total or visible" from the start. Branch `tz-phase4`, from
main f2529bd91 (phases 0 to 3, error traces, the constant-argument rule,
the keyword rule, and total or visible). Groups and spreads were built at
the same time in another worktree, so this change stays out of
`std/datetime/date.rig`, `datetime.rig` and the options code of the
compiler. `ZonedDateTime` (phase 5) and `format` (phase 6) are later; the
STD examples that need them stay `rig pending`.

## What landed

| Part | Where |
|---|---|
| The zone tables of IANA 2026f from Jiff 1.0.0's bundle, as phase 0 laid them out: the zones, the names file, and the pinned test table (Dublin in the standard form, Test/Morocco) | `std/tzdb_data.zig`, `std/tzdb_names.zig`, `std/tzdb_test_data.zig`, written by `tools/gen-tzdb.py` (its default output is now `std/`) |
| The search: a name in any ASCII case by binary search, a zone's offset at a second (transitions in two u32 halves, the POSIX rule after the last as Jiff reads it), a name's primary identifier, every name as a `[]Static` built when Zig compiles a program that asks | `std/datetime.zig`, ported from phase 0's measured `tzdbx.zig` |
| `TimeZone`: `named`, `fixed`, `utc`, `parse`, `name`, `offset_at`, `==` and `Hash` by primary identifier; `zone_names`, `tzdb_version`, `local` | `std/datetime/zone.rig` |
| `DateTimeError.unknown_zone` and `no_system_zone` | `std/datetime/calendar.rig` |
| `file.read_link` | `std/file.rig`, `std/file.zig` (NotLink maps to `FileError.invalid`) |
| The checks as Rig compiles: `TimeZone.fixed` of constants (`sema.ConstMaker.zone_fixed`, `makerFault`), and `TimeZone.named` of a string literal against the names file (`zone_named`, `zoneNamed`, `nearestZoneName`); the names file reaches std.datetime's sema through the module graph's std reader (`SemContext.zone_names`), so `RIG_STD` agrees | `src/sema.zig`, `src/typecheck.zig` (`zoneNamedCall`), `src/modules.zig` |
| A directory module whose files each have an `extern zig` block of one file loads that shim once | `src/modules.zig` (`loadShims`) |
| Tests | `test/rig/std-datetime-zone.rig.test` (23 cases), `std/datetime/zone_test.rig` (8, on the test table, run by `rig test std.datetime`), `test/cli/datetime_local.sh` (31 `TZ` cases and the system's own), `file_read_link.sh`, `tzdb_tables_fresh.sh`, `datetime_zone_tests.sh`, and `datetime_no_panic.sh` extended to the shims and tables |
| The oracle: `zone.offset` for every name; `answer.rig` answers it, `zone.name` and `zone.eq` | `tools/jiff-oracle/gen.py`, `src/main.rs`, `answer.rig`, `README.md`; `test/cli/jiff_oracle.sh` |
| Docs | STD (Zones, read_link), SPEC §13 (the listed makers), the design (phase 4 built, what a program pays), INTERNALS (the names file as a shim), CHANGELOG, HANDOFF |

## Decisions left to the builder

1. **The layout:** `id: I16`, a name's index (598 of them), a zone of
   the test table from `0x4000`, or -1 for a fixed zone; `mins: I16`, a
   fixed zone's offset in minutes. Four bytes (§7.3), checked by a test.
   `utc()`, `fixed(hours: 0)`, `named("UTC")`, `parse("Z")` and
   `parse("-00:00")` are the one value `(-1, 0)`.
2. **The errors:** a name the data does not hold fails
   `DateTimeError.unknown_zone` (`named`, `parse`, `local`); no system
   zone, `DateTimeError.no_system_zone`. `fixed` fails `invalid` for two
   signs, checked first, then `range` beyond ±25:59; `parse` fails
   `invalid` for any offset text it refuses, `+26:00` among them (text,
   as phase 2 decided for `parse`).
3. **The spellings §7.2 leaves open:** `zone_names() -> []Static` (the
   names live in the program, so nothing allocates) and `tzdb_version()
   -> Static`. `name() -> String`, as §7.4 gives it, since a fixed
   zone's name is made.
4. **`local()`:** a set `TZ` is read in the design's order: empty, a
   path (`:` dropped, or a leading `/`, or one with `zoneinfo/`), a name,
   then a rule with no daylight saving. A rule is a name of three letters
   or more, or `<…>` of three or more letters, digits, `+` and `-`; an
   offset of one or two digits of hours, 0 to 25, with `+` or `-`, and
   `:mm`; within ±25:59. Seconds, a daylight-saving part, or anything
   after fail. A `TZ` it cannot read fails `unknown_zone`. Reading
   `/etc/localtime` or `/etc/timezone`, a `FileError` (not a link, denied)
   counts as nothing there and the next source is tried; a `task.Stop`
   fails `local()`, which is a waiting point. A link that names no path
   with `zoneinfo/` falls through to `/etc/timezone`.
5. **The literal check:** a plain literal, double-quoted with no escape
   or `{`, or single-quoted with no `''`; any other argument, a binding of
   a literal among them, is not a constant and takes `!`, as §10.6's list
   says ("a string literal"). The fix offered is a name whose last part
   is the literal (`denver`: `America/Denver`), else the nearest in ASCII
   case within a third of its length in edits, at least two; with none
   that near, the message points at `datetime.zone_names()`.
6. **`fixed` of constants beyond range and of two signs**, such as
   `fixed(hours: 26, minutes: -1)`: the compile error names the hours,
   where std at run time fails `invalid` for the signs first. Both refuse;
   only the wording differs.
7. **The test table** is searched by the same shim function, by its
   `id`, so its 2 zones (228 transitions) are compiled into a program
   that uses a named zone; no program can name it, since its one function,
   `test_zone_find`, is declared only in `std/datetime/zone_test.rig`
   (`cli.datetime_zone_tests` checks a program cannot reach it).

## Open questions

1. **"A message that names TZ" and "a message that gives the data's
   version"** (§7.7): an error member without fields prints only its
   name, `DateTimeError.no_system_zone`, so the member's documentation
   and STD say to set `TZ`, and that `tzdb_version()` gives the version.
   Fields on the two members (a `Static` hint) would put the words in
   the failure itself, at the price of a set whose members differ in
   shape. Proposed default: no fields.
2. **Hours in a `TZ` rule** are taken from 0 to 25 with `:mm`, as
   `fixed`'s range; POSIX writes 0 to 24. Proposed default: keep 25.

## The surface against the design

Every row of §7.4 is built as written. §12's rows phase 4 reaches, each
with a case: zone equality and hashing (the six rows; hashing through a
`Map` and a `Set`); Monrovia's offset with its seconds (its printing in
text is phase 5's `offset_text`); every `TZ` case (empty, a name,
`:name`, a path, `UTC0`, `EST5`, a rule with daylight saving, nonsense);
Lord Howe's half hour; Apia skipping 2011-12-30; Dublin and Morocco on
the pinned table; `TimeZone.parse`'s forms, its refusals, and
`parse(tz.name())` for a named, a fixed and the UTC zone; `named("utc")`;
`zone_names()`; `fixed(minutes: 330)`; and the constant-argument rule for
`named` and `fixed` (constants without `!`, `!` refused, a run-time
argument needing it, a bad constant refused), with each fixed offset
either side of each boundary by a constant call and by std at run time.

## Measured

### The oracle

`gen.py` appends `zone.offset` cases to `zones.in`: every name, an hour
and a second before each transition through 2040 and each of its rule's
in 2100, 2400 and 9998, at it and an hour after, the first and last
instants; and five fixed zones. `zones.in` grows from 656,038 to 827,469
lines (sha256 `af9799be…`); the other files are unchanged. The whole set
is 1,943,026 cases.

| Operation | Same | Different |
|---|---|---|
| `zone.offset` | 171,431 | 0 |
| `zone.name` | 1,794 | 0 |
| `zone.eq` | 861 | 0 |
| the zone cases | 174,086 | 0 |
| all answered, with phases 1 to 3's | 1,095,068 | 0 |

`instant.in_zone` and the other zoned cases stay open for phase 5.

### What a program pays

Release builds on the Mac (Apple M5), `rig build --release`, against
main's `rig` (f2529bd91) for the first two:

| Program | main | this branch | `__text` | `__const` | `__cstring` |
|---|---|---|---|---|---|
| no std.datetime | 460,920 | 460,920 | 260,936 | 17,024 | 4,335 |
| a `Date` only | 479,352 | 479,352 | 267,684 | 17,104 | 4,578 |
| a fixed zone (`fixed`, `offset_at`, `name`) | | 480,344 | 268,500 | 17,152 | 4,693 |
| a named zone (`named`, `offset_at`) | | 578,856 | 270,800 | 116,248 | 13,815 |

- A program that uses only dates is the same size as on main (82 more
  bytes of strings, the error set's two new names, inside the page).
- A fixed zone costs 992 bytes; a named zone 99,504 bytes over a
  `Date`-only program, of which the tables are 99,144 bytes of
  `__const` and 9,237 of names and abbreviations, and the search 3,116
  bytes of code: phase 0's 115,776 less the measuring program's own.
- Every program that uses std.datetime has the three table files written
  into its package (337 KB of Zig), which Zig reads only when a named
  zone is used. Build time was measured in phase 0 (0.07 s for a
  program that uses a zone, 2.1%).

## Verification

On the Mac, through `tools/heavy`:

- `zig build`; while building, the areas that changed: every
  `std-datetime*`, `std-time*` and `std-file` file, every doc's examples,
  `cli.jiff_oracle` (1,095,068 answers the same as Jiff, none
  different), `cli.test_std_module`, `cli.modules`,
  `cli.module_test_files`, and the five new or extended scripts.
- The whole core once (`tools/heavy --class correctness swarm
  test/rig.rip -w 4 -q`): 12,554 jobs in 800 s, one died,
  `cli.exit_teardown` ("the workers did not stop" under load), which
  passed rerun alone.
- A plain `tools/heavy zig build` after.
- `tools/emit-diff origin/main`: 12 of 38 programs differ, each only in
  std.file's new `read_link` (7 lines of its module, 22 of its shim);
  no program among them uses std.datetime's zones. Trig's entry fails to
  emit on both sides alike (its generated `buildinfo` is not in a
  checkout).
- The check guard (`bench/check/guard.py`, under `tools/mac-claim`, at a
  load of 3.2 to 3.3), interleaved four rounds, branch first, against
  `tools/baseline origin/main`: the fewest instructions 2,165,016,271
  for the branch and 2,164,427,230 for main, 0.03% more, and 0.4% over
  the committed baseline, within its 2%.

Not run here: the json, hash and text guards (the change touches no
code they time), the Trig and loco light gates, and pup.
