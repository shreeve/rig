# Datetime phase 5: `ZonedDateTime` (2026-11-22)

Phase 5 of the datetime design (docs/design/datetime.md §6.3 to §6.8,
§7.2, §7.6, §8.1 to §8.3, §11 phase 5, the owner's approved v3 with its
amendments of 2026-11-22), written to "total or visible" from the start.
Branch `zoned-phase5`, from `tz-phase4` at 03b5894ac (phase 4,
`TimeZone`, PR #1219). Groups and spreads were built at the same time in
the worktree `named-groups`, so this change keeps to one new file,
`std/datetime/zoned.rig`, with one `in_zone` method each in
`std/datetime/date.rig` and `datetime.rig`, and does not touch the
options code of the compiler. `ZonedDateTime.add` takes the calendar
keywords inline, as `DateTime.add` does on this base; the merge with
groups gives both the `Period` group alike. `format` and `try_format`
are phase 6.

## What landed

| Part | Where |
|---|---|
| `ZonedDateTime`: `parse` (RFC 9557, `default_zone:`, `resolve:`, `conflict:`), `instant`, `datetime`, `date`, `time`, `zone`, `offset`, `offset_text`, the date and time readers, `in_zone`, `add`, `with`, `start_of_day`, `round`, `floor`, `since`, the four counts, `==`, `<` and `Hash` by the instant, `print`; `today(tz)`; the enums `Resolve` and `Conflict` | `std/datetime/zoned.rig` (new, embedded by `std/embed.zig`) |
| `i.in_zone(tz)`, total; `dt.in_zone(tz, resolve:)!`; `d.in_zone(tz)!` | `instant.rig`, `datetime.rig`, `date.rig`, one method each |
| `DateTimeError.skipped_or_repeated` and `offset_conflict` | `std/datetime/calendar.rig` |
| How a time on the clock becomes an instant: `zone_local`, a port of Jiff's `to_ambiguous_timestamp` (jiff-core `tz/tzif/query.rs` and `tz/posix.rs`) on phase 4's transitions and rules, returning the offsets before and after packed in one `Int` | `std/datetime.zig` |
| A constant increment given `ZonedDateTime.round` or `floor` is checked as `DateTime`'s (`sema.ArgCheck.day_increment`) | `src/sema.zig`, one line |
| Tests | `test/rig/std-datetime-zoned.rig.test` (35 cases); `std/datetime/zone_test.rig` (3 more, on the pinned test table); `test/cli/datetime_no_panic.sh` requires `zoned.rig` among the files it reads |
| The oracle: `answer.rig` answers every zoned case; a new case, `zoned.with`, which `gen.py` writes about each transition and the oracle answers with Jiff's `ZonedDateTimeWith`; `compare.awk` passes over a part Rig answers `-` (the abbreviation, phase 6's `%Z`) | `tools/jiff-oracle/`, `test/cli/jiff_oracle.sh` |
| Docs | STD ("Zoned values", with an example that replaces the pending one), the design (phase 5 built, the enums' and members' names), CHANGELOG, HANDOFF |

## Decisions left to the builder

1. **The layout:** `at: Instant`, `tz: TimeZone`, `off: I32`, the zone's
   offset at the instant in seconds; 24 bytes (§7.3), checked by a test.
   The offset is always the zone's at the instant, as Jiff's
   `ZonedDateTime` holds it: every maker goes through one function
   (`zoned_of`), so a value made at an offset the text gave
   (`.keep_instant`) shows the zone's own offset there, as Jiff's does
   (Monrovia's `23:15:30-00:45`).
2. **The names §4.1 and §10.3 leave open:** the enums are the design's
   suggestions, `Resolve` and `Conflict`; the members are
   `skipped_or_repeated` (a skipped or repeated time under
   `resolve: .reject`) and `offset_conflict` (under `conflict: .reject`).
   Naming is the owner's call; these are the defaults.
3. **Which member a failure of `parse` gives:** text it does not read and
   an instant beyond the range, `invalid`, as `Instant.parse` does; a name
   in brackets the data does not hold, `unknown_zone`; the two new members
   as above. Everywhere else an instant beyond the range is `range`.
4. **A zone in brackets** is read by `TimeZone.named` for a name (so
   `[UTC]` in any case is `utc()`, and `[Z]` fails `unknown_zone`, as
   Jiff refuses it) and as a fixed zone of whole minutes for an offset
   (`[-07:00]`, `[-0700]`, `[-07]`; seconds refused, as Jiff does). A
   time of day is optional, midnight when absent, as in Jiff's grammar.
5. **`default_zone:` with an offset and no brackets** (§8.2: "the offset
   must agree with it, as in 8.3"): `conflict:` applies there as with a
   zone in brackets, so `.keep_instant` and `.keep_clock` work on such
   text too.
6. **`with` keeps its own offset only where the new time is repeated**,
   as Jiff's `OffsetConflict::PreferOffset` does; a skipped time goes to
   `resolve:`. So `resolve: .reject` does not fail on a repeated time
   when the value's own offset is one of the two (tested).
7. **`round(days: 1)`** needs the next day's start only when the value is
   not itself a start: where that start is beyond the range it fails
   `range`, as Jiff's (`FailedLengthOfDay`) does.
8. **The counts' days** start at the days between the two dates (0 when
   the later date is not after the earlier) and step down while
   `earlier.add(days: n)` passes the later value or fails (§6.4).
9. **Text:** the offset in RFC 9557 is rounded to the minute, a half away
   from zero, within ±25:59 (Jiff's `round_to_nearest_minute`), with `-`
   for any negative offset; `offset_text()` is exact, `-00:44:30`, and
   `+00:00` for UTC. An offset written with seconds agrees with a zone's
   only exactly; one written without agrees with a zone's offset that has
   seconds when equal to it rounded (Jiff's `is_equal`,
   `fmt/temporal/parser.rs:100`).
10. **The pinned test table's Test/Morocco**, permanent daylight saving
    written as ending at 23:00 on December 31: Jiff's reading of the
    clock (`dst_info_wall`, which lacks the fix `dst_info_utc` has) sees
    an hour's gap there, so `.earlier` and `.reject` on 23:00 to 23:59
    of December 31 answer as for a gap; `.compatible` and `.later` give
    the time as it is. Rig follows Jiff. No zone of the real data has
    such a rule (Africa/Casablanca in 2026f is `+00` all year there,
    checked to 2100), so the test asserts only what is right
    (`.compatible`, `.later`).

## Where Rig differs from Jiff on purpose, tested directly

- `round(days: 1)` measures to the next day's start (§9 item 14):
  Havana 2026-03-08 at 12:45 and 18:00 round to 00:00 on the 9th.
- A round past midnight in year 0 carries into the next day (item 14).
- Counts across two zones use the earlier value's calendar (item 3):
  noon to noon in New York across 2026-03-08 is 1 day on its calendar
  and 0 on UTC's, whichever value is shown in UTC.
- Calendar groups of different signs (item 4): `add(months: 1,
  days: -1)` and `add(days: 1, hours: -1)`.
- `parse(s, default_zone:)` (item 13): the four cases of §8.2 and none.

## The rows of §12's table phase 5 reaches

Each with a case in `std-datetime-zoned` unless named: spring forward
(23 hours) and fall back (25 hours); Apia skipping 2011-12-30; Lord
Howe's half hour, a gap and a repeat; Dublin and Morocco on the pinned
test table (`zone_test.rig`: Dublin's gap and repeat found by offsets in
2026 and in its rule's 2087, a day across each change 23 and 25 hours,
Morocco at +01:00 all year); `add(months: 1, days: -1)` and
`add(days: 1, hours: -1)`; `add(days: 0)`, `add(days: 0, hours: 1)` and
`add(weeks: 1, days: -7)` on a repeated time; the Denver counts both
ways; Casey's 26 hours and 0 days; 24 hours 10 minutes across a repeated
hour, 0 days; whole days and the rest, launch before and after the
start; counts across two zones; `with` on the second of a repeated time;
`start_of_day` in São Paulo and the Azores; noon on a 23-hour and a
25-hour day; Monrovia's printing and its 30-second trap; a stored string
whose offset no longer fits; a day's range (Havana, Nuuk, Apia;
9999-12-31 in UTC and Tokyo); `floor(minutes: 20)` in Lord Howe;
`round(days: 1)` in Havana and `floor`/`start_of_day` in St. John's and
Toronto; -9999-01-03 at +25:59; `.earlier` and `.later` on Denver's
skipped 02:30; `round(minutes: 30)` on the first 01:50; the four cases
of a default zone, and `Z`; a round past midnight in year 0; and the
ends of each range: `add` (a nanosecond past each end, a day past the
last date, a sum of years that overflows), a duration form with a
run-time number folded into `add`'s `!`, `round`, `floor`,
`start_of_day`, `with`, `dt.in_zone` (23:59:00.999999999 at +25:59 on
the last date succeeds and a second later fails), `d.in_zone`, and
`parse` beyond the range, each failing with the member §7.2 names; and
`i.in_zone` total at both ends at ±25:59, `since` between the first and
last instants. The constant-increment check and `add(1, 2)` are refused
as Rig compiles; a computed increment fails `invalid`.

## Measured

### The oracle

`gen.py` writes a new case, `zoned.with ZONE INSTANT DATETIME`: from half
an hour either side of each transition of every zone (and of its rule's
in 2100, 2400 and 9998), to the clock a second before the change, at
either end of it, in its middle and a second before its end; answered
for each of the four `resolve:` values. `zones.in` grows from 827,469 to
1,070,899 lines (sha256 `0a3c4060…`); the other files are unchanged.

| Case | Count | Same | Different |
|---|---|---|---|
| `instant.in_zone` | 157,714 | 157,714 | 0 |
| `datetime.in_zone` (four answers each) | 219,633 | 219,633 | 0 |
| `date.in_zone` | 30,716 | 30,716 | 0 |
| `zoned.start_of_day` | 49,064 | 49,064 | 0 |
| `zoned.with` (four answers each) | 243,430 | 243,430 | 0 |
| `zoned.add` | 236,256 | 236,256 | 0 |
| `zoned.count` | 93,806 | 93,806 | 0 |
| `zoned.parse` (three answers each) | 40,768 | 40,768 | 0 |
| `zoned.round` (round and floor) | 20,000 | 20,000 | 0 |
| every case, phases 1 to 5 | 2,186,456 | 2,186,455 | 0 (1 `skip`) |

`instant.in_zone`'s abbreviation is phase 6's and is passed over; its
offset is compared in Jiff's short form (`+03` for `+03:00`), from
`offset_text()`. No case is left unanswered.

## Verification

On the Mac, through `tools/heavy`:

- While building: every `std-datetime*` and `std-time*` file,
  `cli.jiff_oracle`, `cli.datetime_no_panic`, `cli.datetime_zone_tests`,
  `cli.datetime_local`, `cli.tzdb_tables_fresh`, `doc-STD`,
  `doc-design-datetime`, and `oracle`; `rig test std.datetime` (11 of 11).
- The whole core once (`tools/heavy --class correctness swarm
  test/rig.rip -w 4 -q`): 12,595 jobs in 698 s, two died under load,
  `cli.dense_actors` (a sanitized restart run) and `cli.exit_teardown`
  ("the workers did not stop"), neither touching std.datetime; both
  passed rerun alone.
- A plain `tools/heavy zig build` after.
- `tools/emit-diff origin/main` (bbdb95a51, phase 4 merged): identical in
  37 of 38 programs, 635 files; Trig's entry fails to emit on both sides
  alike (its generated `buildinfo` is not in a checkout).
- The check guard (`bench/check/guard.py`, under `tools/mac-claim`, at a
  load of 2.7 to 3.0), interleaved four rounds, branch first, against
  `tools/baseline origin/main`: the fewest instructions 2,161,823,741 for
  the branch and 2,160,025,804 for main, 0.08% more, and 0.2% over the
  committed baseline, within its 2%.

Not run here: the json, hash and text guards (the change touches no code
they time), the Trig and loco light gates, and pup.
