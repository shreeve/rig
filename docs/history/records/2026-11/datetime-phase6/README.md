# Datetime phase 6: `format` and `try_format`, and the teaching text (2026-11-22)

Phase 6, the last, of the datetime design (docs/design/datetime.md §8.1,
§8.4, §10.2, §10.6, §11 phase 6, §12, the owner's approved v3 with its
amendments of 2026-11-22), written to "total or visible". Branch
`format-phase6`, from `zoned-phase5` at 1edfdbe9f (phase 5,
`ZonedDateTime`, in review; phase 4 is on main). Groups and spreads are
built at the same time in the worktree `named-groups`, so this change
adds one file, `std/datetime/format.rig`, and only the `format` and
`try_format` methods to `date.rig`, `clock.rig`, `datetime.rig` and
`zoned.rig`, and stays out of the options code of the compiler.

## What landed

| Part | Where |
|---|---|
| `x.format(pattern)` and `x.try_format(pattern)!` on `Date`, `Time`, `DateTime`, `ZonedDateTime`: §8.4's directives with Jiff's meanings, the flag `-`, a precision `%.1f` to `%.9f`; years below 0 as Jiff writes them; `%Z` from the zone tables in capitals, a fixed zone's short offset, `UTC`; `%s` toward zero | `std/datetime/format.rig` (new, embedded by `std/embed.zig`), one method each in the four types' files |
| A zone's abbreviation at an instant: the local type's, by the search that gives its offset (`zoneType`, `ruleType`, `zone_abbreviation`) | `std/datetime.zig` |
| The check as Rig compiles: the directive table a second time (`sema.FormatType`, `formatOwner`, `formatNeeds`, `formatPads`, `formatFault`, with a unit test), and `formatCall`, which reads the string (`formatString`: a literal, or a module constant bound to one, here or in another module, through a chain) at both places a method is called (`synthMemberCall`, the call through the type); a call that passes is recorded as a maker's of constants is (`recordConstMaker`), so it gives `String` and emit unwraps it (`emitConstMaker`, `rig.makerPanic` for a disagreement) | `src/sema.zig`, `src/typecheck.zig` |
| Tests | `test/rig/std-datetime-format.rig.test` (15 cases: every directive on every type by `format` and `try_format`, the ends of the range, `%Z` and `%z` of named, fixed and UTC zones and of Monrovia's seconds, `%s` before 1970, module constants, every kind of refusal, `!` and `catch` refused, `try_format`'s failures); `test/cli/datetime_format_table.sh` (both ways, below); `test/cli/datetime_no_panic.sh` requires `format.rig` among the files it reads |
| The oracle: a sixth kind, `format.in`, and `instant.in_zone`'s abbreviation answered by `format("%Z")`, so no part of any case is left unanswered | `tools/jiff-oracle/` (`gen.py`, `src/main.rs`, `answer.rig`, `compare.awk`, `README.md`), `test/cli/jiff_oracle.sh` (15 fixed cases from Jiff's own printer tests) |
| Docs | STD ("Writing by a format string", with the directive table; the whole surface's example, pending since phase 1, an ordinary one), SPEC §13, the design (phase 6 built; `try_format` fails `invalid`; `%Z` in capitals), the journey [12, Dates and times that mean what they say](../../../../learn/12-dates.md) with its links (learn/README, docs/README, journey 11 and 06, journeys.md, where the end-to-end journey becomes 13), CHANGELOG, HANDOFF, ROADMAP |

## Decisions left to the builder

1. **How `format` cannot fail.** std declares it `-> String!` with the
   body `@try_format(pattern)!`, and the compiler, once the string
   passes its check, records the call as a maker's of constants
   (§10.6), so its type is the plain `String`, `!` and `catch` on it are
   refused, and emit unwraps it with `rig.makerPanic` for a failure the
   check ruled out. A disagreement between the compiler's table and
   std's is then a reported bug in Rig, never a silent empty string; a
   `-> String` body would have needed a fallback. The doc comment says
   so.
2. **The failure:** `DateTimeError.invalid`, as §7.2 lists `try_format`
   among the calls that fail `invalid` for bad text. §10.3's
   parenthesis "(`try_format`)" named the call, not a member; the design
   now says so.
3. **The parameter** is `pattern`: `d.format(pattern: "%j")`.
4. **What is known as Rig compiles:** a string literal in any quoting
   (its escapes read as the literal's), or a module constant bound to
   one, in this module or another (`lib.FMT`), through a chain of such
   constants (a per-target constant is not). A local binding of a
   literal, a template and any other expression are refused with
   `try_format` as the fix, as the brief and §8.4 say ("a literal or a
   module constant bound to one").
5. **The flag `-`** is taken only on a directive that pads (`%Y %m %d %e
   %j %G %V %H %M %S %I`). Jiff takes it anywhere and does nothing with
   it on the others (`%-A`, `%-F`, `%-u`, `%-s`, `%-f`); Rig refuses
   those, since a flag that does nothing reads as a mistake.
6. **A precision** is one digit, 1 to 9. Jiff writes nothing for `%.0f`
   and clamps `%.10f` to nine digits; Rig refuses both.
7. **Bytes outside directives** are written as they are, by `format`
   and `try_format` alike. Jiff fails on a format string that is not
   UTF-8, which a Rig literal reaches only by a `\x` escape; the two Rig
   sides agree, and the oracle generates no such string.
8. **`%Z` in capitals**, as Jiff writes it (`Case::Upper`): Guam's
   `ChST` is `CHST`. The oracle's `instant.in_zone` answer, which phase 5
   printed as the data spells it, is now `%Z`'s, so both sides compare
   the capitals.
9. **`%s` is toward zero**, Jiff's `Timestamp::as_second`: 5.5 seconds
   before 1970 is `-5`, where `unix_s()` floors to `-6`.
10. **The diagnostic** names the call, the directive, the type, why, and
    what the type takes: "`d.format("%H")`: `%H` in the format string
    does not suit a `Date`: a `Date` has no time of day; a `Date` takes
    `%Y %m %d %e %A %a %B %b %j %F %u %G %V %%`". One error per call, at
    its first bad directive, on the string. A `DateTime` given a zone's
    directive is told `dt.in_zone(tz)!` gives one.
11. **The abbreviation reaches only zoned values.** `ZonedDateTime`'s
    `try_format` looks it up and passes it in, so a program that formats
    only dates and times carries no zone table.
12. **The teaching text** is a journey of its own, 12, of 1,773 words,
    not a section of journey 06, which is already 3,275 words over the
    house limit of 3,000. The end-to-end journey, not yet written,
    becomes 13.

## Pending the owner: `format` and §10.6's list

How it works today: std declares `format(?@, pattern: ?String) ->
String!`, its body `@try_format(pattern)!`. A call whose string passes
the check is recorded as a maker of constants is (§10.6), so it types as
`String`, `!` and `catch` on it are refused, a task of it keeps
`Task[String!]` as a maker's does, and emit unwraps it with
`rig.makerPanic`. §10.6's list, the owner's, does not name `format`. And
a function value is the declared `String!` with no check:
`f = datetime.Date.format; f(d, "%H")!` compiles and fails
`DateTimeError.invalid` as the program runs. That is visible (it needs
`!`), but STD's row `x.format(pattern) -> String` and SPEC §13's sentence
hold only for calls. Whether `format` joins §10.6's list, and whether
`Date.format` as a value is refused, is the owner's to decide; the
mechanism is unchanged until he does.

## After review (2026-11-22)

An independent review (no soundness bug found) gave four fixes, each
with its failing case first:

1. The fix offered for a string made as the program runs searched the
   call's text for `.format(` and found a nested call's:
   `d.format(t.format("%H"))` offered `d.format(t.try_format("%H"))!`. It
   now rewrites the call's own member name by its source span:
   `d.try_format(t.format("%H"))!`.
2. A directive ended at the byte after `%`, so `d.format("%é")` named
   `%\303`; it ends on a whole UTF-8 character (`formatFault`, with a
   unit test).
3. The case named "from another module" had none: it uses `lib.CLOCK`
   from a second file, and a new case refuses it on a `Date` and refuses
   another module's template constant with the `try_format` fix.
4. docs/internals/backlog.md records that the fact is kept per call, so
   a generic body that could call `format` would need it per instance.

The review also notes two clarifying edits to owner-tagged text in the
design (`%Z` in capitals, `try_format` failing `.invalid`), which change
no rule.

## Both ways

`test/cli/datetime_format_table.sh` writes, for each of the four types,
208 format strings: `%` and `%-` before each of the 94 printable ASCII
bytes, the precisions `%.f` and `%.0f` to `%.10f`, the colon forms,
`%` and `%-` at the end, widths and text around a directive. It checks
each with `format` (`rig check`, in files of 80, under the 100 errors
the compiler shows) and runs each through `try_format`, and requires the
same answer: `Date` 23 taken, `Time` 18, `DateTime` 39, `ZonedDateTime`
43, every other refused both ways.

## Where Rig differs from Jiff on purpose, tested directly

Rig refuses as it compiles, and `try_format` fails, where Jiff writes
something (§8.4, §9 item 9): `%.f` on a `Date` (Jiff writes nothing);
the directives not in v1 (`%y`, `%c`, `%::z` among them); the flags `_`,
`0`, `^`, `#`; widths (`%3f`, `%05d`); `-` on a directive that does not
pad; `%.0f` and `%.10f`. None is generated for the oracle.

## The row of §12 phase 6 reaches

"Every `format` directive on every type, in `format` and in
`try_format`": `std-datetime-format`'s four cases of every directive,
each string written by both and compared, and the both-ways script.

## Measured

### The oracle

`gen.py` writes `format.in`, 158,079 cases: every directive each type
takes alone, with `-` where it pads, then strings of several, on dates
about the ends of the year and of the ISO week year in the 19 sample
years and 300 random ones; every hour with fractions of each length and
300 random times; 502 dates and times, the ends of the range among
them; every name a second before and at each of its transitions through
2040 and its rule's, with every directive of a zone; the 24 zones of
`ZONES`, Guam and seven fixed zones with every string, at random
instants and the ends of the range; and each directive of another
type's, which both refuse. The other files are unchanged.

| Case | Count | Same | Different |
|---|---|---|---|
| `format.*` | 158,079 | 158,079 | 0 |
| `instant.in_zone`, the abbreviation now compared | 157,714 | 157,714 | 0 |
| every case, phases 1 to 6 | 2,344,535 | 2,344,534 | 0 (1 `skip`) |

### What a program pays

Release builds on the Mac (`rig build --release`):

| Program | Bytes | `__text` | `__const` |
|---|---|---|---|
| a `Date` printed | 478,816 | 266,232 | 17,072 |
| a `Date` by `format("%A, %B %-d, %Y")` | 479,264 | 267,884 | 17,272 |
| a zoned value printed | 578,720 | 271,772 | 116,280 |
| a zoned value by `format("%F %T %Z")` | 596,112 | 274,732 | 117,440 |

`format` on a date costs 448 bytes and no zone table. On a zoned value
it costs 2,960 bytes of code and 1,160 of tables (the abbreviations),
which here cross a 16 KB page.

## Verification

On the Mac, through `tools/heavy`:

- While building: `std-datetime-format` and every other `std-datetime*`
  and `std-time*` file, `cli.datetime_format_table`,
  `cli.datetime_no_panic`, `cli.jiff_oracle` (2,344,534 answers the same
  as Jiff, none different), `cli.datetime_zone_tests`,
  `cli.datetime_local`, `cli.tzdb_tables_fresh`, `doc-STD`, `doc-SPEC`,
  `doc-design-datetime`, `doc-learn-12-dates`, `doc-learn-06-stdlib`,
  `doc-learn-11-performance`, and `oracle`.
- The whole core once (`tools/heavy --class correctness swarm
  test/rig.rip -w 4 -q`): 12,621 jobs in 643 s, none died.
- A plain `tools/heavy zig build` after.
- `tools/emit-diff origin/main` (47b6e27c9): identical in 37 of 38
  programs, 635 files; Trig's entry fails to emit on both sides alike
  (its generated `buildinfo` is not in a checkout).
- The check guard (`bench/check/guard.py`, under `tools/mac-claim`, at a
  load of 2.6 to 2.7), interleaved four rounds, branch first, against
  `tools/baseline origin/main`: the fewest instructions 2,160,385,869
  for the branch and 2,172,257,951 for main, 0.5% fewer (main's runs
  were the higher in every round, which is noise of the load: the
  branch adds work to `rig check` only at a call of `format`), and 0.1%
  over the committed baseline, within its 2%.

Not run here: the json, hash and text guards (the change touches no code
they time), the Trig and loco light gates, and pup.
