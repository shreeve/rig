# Datetime phase 2: `Date`, `Time`, `DateTime`, `Weekday` (2026-11-21)

Phase 2 of the datetime design (docs/design/datetime.md, the owner's v3
of 2026-11-17, amended 2026-11-20). It builds `std.datetime` as a
directory module with the calendar and the clock face, its four types
with their text, and the positional checks of §10.2's phase 2 row.
The branch is rebased on phase 1b (several unit keywords in one call,
main c2f90250a), so a `DateTime`'s `add` takes several units beside its
calendar amounts. `Instant`, `TimeZone`, `ZonedDateTime`, `now`,
`today`, `in_zone`, and `format` are later phases and stay `rig pending`
in STD.

## What landed

| Part | Where |
|---|---|
| The error set, the ends of the range, and the calendar math: days from a date and back, leap years and month lengths, the day of the year, ISO weeks, a month step, floor division | `std/datetime/calendar.rig` |
| `Weekday`: `.monday` to `.sunday`, `iso_number()`, `Eq`, `Ord` from Monday, `Hash`, `print` of the English name | `std/datetime/weekday.rig` |
| `Date`: `new`, `parse`, the readers, `first_of_month`, `last_of_month`, `nth_weekday`, `nth_weekday_of_month`, `add`, `checked_add`, `with`, `at`, the four counts, `print` | `std/datetime/date.rig` |
| `Time`: `new`, `parse`, the readers, `add` (wraps), `checked_add`, `with`, `since`, `round`, `floor`, `print` | `std/datetime/clock.rig` |
| `DateTime`: `new`, `parse`, `date()`, `time()`, the readers of both, `add`, `checked_add`, `with`, `since` (saturating), the four counts, `round`, `floor` (with `days: 1`), `print` | `std/datetime/datetime.rig` |
| ISO 8601 reading and writing by Jiff's grammar, each type in its own form only | `std/datetime/text.rig` |
| The checks of §10.2's phase 2 row and of `round` and `floor` on a `Time` and a `DateTime`; no checked method called in a generic body | `sema.ArgCheck` (`clock_increment`, `day_increment`, `calendar_add`, `duration_add`, `by_name`), `sema.stdArgCheck`; `typecheck.zig` `checkCalendarAdd`, `checkDurationAdd`, `checkByName`, `checkUnitIncrement`, `oneIncrement`, and `checkMethodCall` (a generic's instance) |
| Tests | `test/rig/std-datetime.rig.test` (`Weekday`, `Date`; 29 cases), `std-datetime-clock` (`Time`, `DateTime`; 28), `std-datetime-checks` (every form of each checked method at each kind of call, a generic among them, built and run, several units, every rejection, and the sizes; 17), `std-datetime-ports` (more of Jiff's tests, the whole range of dates; 8), `std-datetime-docs` (170 of the examples in Jiff's documentation; 10) |
| The oracle: five more operations; std.datetime's and std.time's answers, compared with Jiff's by the suite | `tools/jiff-oracle/gen.py`, `src/main.rs`, `answer.rig`, `compare.awk`, `README.md`; `test/cli/jiff_oracle.sh` |
| Jiff's documentation examples, each ported or left out and why | [doc-examples.md](doc-examples.md) |
| Docs | `docs/STD.md` "std.datetime"; CHANGELOG (Unreleased, Added); HANDOFF's "In flight"; ROADMAP |

No file of std.time changed: std.datetime imports it (each of
`clock.rig` and `datetime.rig` has its own `use std.time`), so a program
that only sleeps or times loads none of the calendar.

## Decisions left to the builder

1. **The error set** is `datetime.DateTimeError`, the module's name
   with `Error` as `time.TimeError`, `json.JsonError`, and `net.NetError`
   are, with `invalid` (text that is not the type's form, or names no
   real value: `parse`) and `range` (`new`, `with`, `checked_add`,
   `nth_weekday`, `nth_weekday_of_month`). The later phases add their
   variants to it (§10.3).
2. **The fields** (§10.3): `Date` is `y: I16`, `m: U8`, `d: U8`; `Time`
   is `h`, `m`, `s: U8` and `ns: U32`; `DateTime` is `on: Date` and `at:
   Time`, since `d` and `t` would shadow its `add`'s parameter `d`. The
   sizes are §7.3's, checked by a test: 1, 4, 8, and 12 bytes. All
   private, so a value is made only by the module's functions.
3. **The files**: `calendar`, `weekday`, `date`, `clock` (a `Time`; a
   file named `time.rig` beside `use std.time` would read as the module),
   `datetime`, and `text`. No Zig shim: the calendar math is plain Rig.
4. **The parameters**: `Time.new(hour, minute, second = 0, ns = 0)` and
   `DateTime.new(year, month, day, hour = 0, …, ns = 0)` as §7.2 gives
   them; `Time.parse(text)` names its parameter `text`, not `s`, beside
   the field `s`; `add(years: Int = 0, months: Int = 0, weeks: Int = 0,
   days: Int = 0)`, and on a `DateTime` `d: time.Duration? = none`
   first; `with` takes each field as `Int? = none`; `round` and `floor`
   six `Int?` keywords, `ns` to `hours`, and on a `DateTime` `days` too,
   as phase 1's `Duration.round` does.
5. **The messages** of the checks, each fix one that compiles:
   "`add` of a `Date` takes its amounts by name, and no positional
   argument: `add(days: 1)`" (with the `Int` written; for another type
   but a `Float` or a `Duration`, "…, an `Int` of each, …");
   "a `Date` has no time of day, so `add` takes no `hours:`: a date and a
   time of day is a `DateTime`, `d.at(t).add(weeks: 1, hours: 2)`" (§6.2;
   every amount written is kept), and for a `Float` or a `Duration` by
   position, "… takes no duration, `0.5`: … `d.at(t).add(0.5)`";
   for two units to `round` or `floor` on a `Time` or a `DateTime`, phase
   1b's "write the increment in one unit, `round(ms: 250)`" only where
   the sum is an increment they take, else "name one of them,
   `round(minutes: 1)`"; and for a checked method called in a generic
   body, "`bump[datetime.DateTime]` cannot use `T = datetime.DateTime`:
   the generic body calls `x.add(d, 2, 0, 0, 0)`, and
   `datetime.DateTime.add` checks its arguments where it is called, by
   name, which a call in a generic body cannot give; call it where its
   type is written, or pass a closure that does";
   "`add` takes one duration by position and its calendar amounts by
   name: `add(1, years: 2)`, not a second positional argument";
   "`with` takes the fields it replaces by name, `with(day: 1)`, and no
   positional argument" (`second: 0` for a `Time`, `hour: 0` for a
   `DateTime`); "`round` takes a unit from `ns:` to `hours:`, or `days:
   1`, and its increment, and `weeks:` is none of them"; "an increment of
   `round` divides the next larger unit and is smaller than it, so
   `minutes:` takes 1, 2, 3, 4, 5, 6, 10, 12, 15, 20, or 30, and `45` is
   not one of them"; "`round` takes `days: 1` and no other number of
   days, and `2` is not 1". A checked method taken as a value gets phase
   1's message.
6. **Weekday from a day count** is a floor modulus (`weekday_index`),
   not jiff-core's multiply-and-shift (`civil/date.rs:728`): the two
   agree over the whole range (the oracle's `date.info` gives every
   date of 19 years), and Rig has no `u32` wrap to write the shift
   plainly.
7. **Panics** name the operation and its arguments as written:
   "datetime.Date.add: 9999-12-31 plus years: 0, months: 0, weeks: 0,
   days: 1 is beyond the range of dates, -9999-01-01 to 9999-12-31";
   "datetime.DateTime.add: 9999-12-31T23:59:59 plus 1s and years: 0, …";
   "datetime.DateTime.round: 9999-12-31T23:59:59.999999999 rounds past
   9999-12-31"; an increment that is not a constant and not allowed,
   "datetime.Time.round: the increment 7 does not divide 60 or is not
   smaller than it".
8. **A sum of calendar amounts** is taken in `I128`, so `add(years:
   Int.max)` reaches the range's panic, not an `Int` overflow, and
   `checked_add` fails for it (§6.2, "amounts too large to sum").

## The design against the code

Nothing in the code made a part of the design wrong or impossible.
§10.2's line numbers had moved (the hook is now `typecheck.zig`
`stdArgChecks`, `synthMemberCall` and `associatedCall` call it, and
`typeMember` refuses a checked method as a value); the hook took the
new checks as variants of `sema.ArgCheck`, with no change to the call
machinery that phase 1b touches.

One class the design does not name, found by the review: **a generic
body** passes every argument of a call on a type parameter by position,
so `x.add(d, 2, 0, 0, 0)` in `fun bump[T](x: T, …)`, instantiated at a
`DateTime`, added two years, and a `with` or a date's `add` by position
ran too; phase 1's `Duration.round` was open the same way (`x.round(k,
k, k, k, k, k)` with `k: Int?`). A checked method is now refused where a
generic's instance is checked against its type's methods
(`checkMethodCall`), as it is refused as a function value; a closure
carries one.

Two things the design leaves implicit, settled by Jiff's code and
checked by the oracle:

- **A `Time` in the basic form that also reads as a date** is refused,
  as Jiff refuses it: `1230` (Dec 30), `123045`, `103000.123456789`.
  Jiff tries a month and day, and a year and month, on what the time
  consumed (`fmt/temporal/parser.rs:335`), so `T1230` or `12:30` is
  the way to write it. Rig keeps Jiff's answer, so the oracle's text
  cases agree.
- **A date whose text is not a real date** (`2023-02-29`) is
  `DateTimeError.invalid` from `parse`, as std.time's `Duration.parse`
  calls any text it cannot read invalid, and `range` from `new`.

## Ported from Jiff

Each routine of `std/datetime` names the line of Jiff 1.0.0 it follows:
jiff-core `civil/date.rs:490` (`to_unix_epoch_day`, Neri and
Schneider), `:892` (`to_date`), `:519` (`to_iso_week_date`), `:1317`
(`iso_week_start_from_year`), `:770` (`nth_weekday`), `:332`
(`nth_weekday_of_month`), `:209` (`day_of_year`); `civil/mod.rs:171`,
`:189`; `civil/weekday.rs:186`; jiff `civil/date.rs:1356`
(`checked_add_span`), `:3423` (`month_add_overflowing`), `:2726`
(`since_with_largest_unit`); `civil/datetime.rs:1694`, `:3570`
(`DateTimeRound::round`); `util/round.rs:109` (`for_datetime`,
`for_time`); `fmt/temporal/parser.rs:524` to `:925`; `fmt/util.rs:727`.

### Tests ported

| File | Ported | Left out, and why |
|---|---|---|
| jiff-core `civil/mod.rs` | `year_leap`, `month_days` (`year_days` through `days_in_month`) | none |
| jiff-core `civil/date.rs` | `date_min`, `date_max`, `unix_epoch_day_weekday`, `first_of_last_of`, `days_in`, the four round trips (`unix_epoch_to_date_and_back_again_*`, `date_to_unix_epoch_and_back_again`, `date_to_week_date_and_back_again`), all over the whole range, every date walked a day at a time; `day_of_year_in_non_leap_year`, `day_of_year_in_leap_year`; `nth_weekday_of_month_various`, `_errors`, `_near_minimum_date`, `_near_maximum_date`, `_every_month_has_four_weekdays` (over a 400-year cycle and the end years); `nth_weekday_various`, `_errors`, `_extreme`; `add`, `sub`; `to_iso_week_date_various` | `ISOWeekDate`'s own type (`iso_week_date_*` and its `prop_*`), `from_day_of_year*`, `day_of_year_no_leap*`, `days_in_year`, `first_of_year`, `yesterday`, `tomorrow`, `prev_year`, `next_year`: none is in Rig's surface (§6.7, §8.5); the other quickcheck properties, which the whole-range walk and the oracle stand for |
| jiff-core `civil/weekday.rs` | none | every test is of `from_*`/`to_*` offsets, `wrapping_add`, `since`, `until`, `cycle`: Rig's `Weekday` has only `iso_number()` and its order (§4.1); `iso_number` is tested |
| jiff-core `civil/time.rs`, `civil/datetime.rs` | none directly | conversions to seconds, `Timestamp`, and overflowing adds of internal types; their results are reached through `Time.add`, `since`, and the oracle's `time.add` |
| jiff `civil/date.rs` | `add_constrained`, `since_years`, `since_months`, `since_weeks`, `since_days`, `until_month_lengths`, `since_until_not_commutative`, `until_months_no_balance`, `until_extremes`, `nth_weekday_of_month`, `nth_weekday_extreme`, `date_invalid_day` | `t_from_unix` (an `Instant`, phase 3); `until_weeks_round` and the rounding of spans (no span, §6.1); `test_month_add*` (internal); `date_size` (Rig's sizes are tested); the serde tests |
| jiff `civil/time.rs` | `min`, `max`, `invalid`, `rounding_cross_midnight`, `overflowing_add` and the wrapping of the largest durations (with Rig's `Duration`) | `UnsignedDuration` and spans beyond a `Duration`'s 292 years (§5.1); `time_size`; serde |
| jiff `civil/datetime.rs` | `from_temporal_docs`, `since`, `until` (in counts and the rest), `until_month_lengths` | `until` in microseconds across the whole range (a `Duration` saturates there, §6.6); `datetime_size`; serde |
| tests/tc39_262 `civil/date/add.rs` | `basic`, `overflow_constrain`, `overflow_reject` | `balance_smaller_units*`: time units on a `Date` are a compile error in Rig (§6.2) |
| tests/tc39_262 `civil/date/until.rs` | `basic`, `largestunit_higher_units`, `weeks_months`, `wrapping_at_end_of_month`, the exact counts of `rounding_relative` | `largestunit_smallestunit_mismatch`, `round_*`, `roundingincrement`, `roundingmode_*`, `smallestunit_higher_units`: a count is not rounded (§6.1) |
| tests/tc39_262 `civil/time/add.rs` | `argument_duration`, `argument_string_fractional_units_rounding_mode`, `argument_string_negative_fractional_units`, `argument_object`, `argument_object_checked`, `argument_duration_max`/`_min` (with the largest `Duration`), `balance_negative_time_units`, `argument_higher_units` (a day wraps back), `argument_mixed_sign` (as a deviation: Jiff's span takes its last unit's sign, Rig's units each keep their own, §5.2) | `argument_string_duration_too_large` (beyond a `Duration`) |
| tests/tc39_262 `civil/time/sub.rs` | through `add` of a negative duration (no `sub`, §6.2), the same cases | as for `add.rs` |
| tests/tc39_262 `civil/time/round.rs` | `rounding_cross_midnight`, `rounding_increment_nanoseconds`, `_microseconds`, `_milliseconds`, `_seconds`, `_minutes`, `_hours`, `rounding_mode_floor`, `rounding_mode_half_expand`; `rounding_increment_invalid`, `_out_of_range`, and `smallest_unit_missing` are compile errors, in `std-datetime-checks` | the five other rounding modes (§6.8) |
| tests/tc39_262 `civil/time/until.rs` | `basic`, `argument_cast`, `balance_negative_time_units`, `result_sub_second` | `largestunit*`, `round*`, `roundingincrement*`, `roundingmode*`: `since` is an exact `Duration`, not rounded |
| tests/tc39_262 `civil/time/equals.rs` | none | each case parses a zoned or annotated string into a `Time`, which Rig refuses (§8.1); the refusals are tested |
| tests/tc39_262 `civil/datetime/add.rs` | `ambiguous_date`, `balance_negative_time_units`, `hour_overflow` | none |
| tests/tc39_262 `civil/datetime/round.rs` | `balance`, `limits`, `rounding_direction` (its half to the later, in a negative year), `roundingincrement_one_day`, `roundingmode_basic`, `roundingmode_halfexpand`, `roundingmode_floor`; the increment rules by the compile-time check | the other modes |
| tests/tc39_262 `civil/datetime/until.rs` | `balance_negative_duration`, `balance` (the forward count), `balance_negative_time_units`, `inverse`, `no_unnecessary_units`, `subseconds`, `units_changed`, `weeks_months_mutually_exclusive`, `wrapping_at_end_of_month` | where Jiff counts backward from the later value (`-P40M30DT…`, `-1.month().days(30).hours(23)`), Rig counts forward from the earlier (§9 item 3), tested as such; `largestunit_smallestunit_mismatch`, `round_*`, `roundingincrement_*`, `roundingmode_ceil`: the rounding of counts (§6.1) |
| Jiff's documentation of these types (`src/civil/*.rs`), 354 examples | 170, in `std-datetime-docs` | 184, each listed in [doc-examples.md](doc-examples.md) with its reason: chiefly what Rig's surface does not have (spans, rounded counts, the rounding modes it lacks, `ISOWeekDate`, weekday arithmetic, builders, `strftime`), and zones and instants of later phases |

## Measured: the oracle

`gen.py` writes the same 1,669,949 cases as phase 0 (the inputs' sha256
are unchanged but `calendar.in`'s, which has the new cases after the old
ones, byte for byte), and 71,646 more: 1,741,595 in all. Jiff answers
them in 1 s. `answer.rig`, built with `--release`, answers phase 2's and
std.time's, and `test/cli/jiff_oracle.sh` builds both, runs every case,
and requires no difference (`compare.awk`), in about 15 s. Every case
answered is the same as Jiff's:

| Operation | Same | Different | Left out on purpose |
|---|---|---|---|
| `date.add` | 437,283 | 0 | |
| `date.info` (weekday, day of year, days in month, ISO week and year, first and last of the month) | 6,941 | 0 | |
| `date.count` (four counts each way, and years, months, days) | 174,036 | 0 | |
| `date.nth_weekday` | 20,823 | 0 | |
| `date.nth_weekday_of_month` | 13,882 | 0 | |
| `date.with` | 6,941 | 0 | |
| `datetime.add` | 35,083 | 0 | 4,917: a duration beyond a `Duration`'s range (§5.1) |
| `datetime.count` (with the rest) | 60,004 | 0 | |
| `datetime.since` | 10,247 | 0 | 9,753: beyond ±292 years, where Rig saturates (§6.6) |
| `datetime.round` (round and floor) | 15,000 | 0 | of the rounds, 81 in a year at or below 0 that reach the next midnight, where Jiff does not carry (§6.8, item 14); their floors are compared |
| `time.add` (wrapped and checked) | 8,748 | 0 | 1,252: a duration beyond the range |
| `time.since` | 10,000 | 0 | |
| `time.round` | 15,000 | 0 | |
| `date.parse`, `time.parse`, `datetime.parse` (round trips and §8.1's spellings) | 15,041 | 0 | |
| `duration.parse` (std.time) | 5,270 | 0 | 741: past a `Duration`'s range |
| `duration.round` (std.time) | 8,313 | 0 | 1,687: an input, an answer, or a multiple near the input past the range |
| **all** | **842,612** | **0** | 18,350, and 81 rounds |

The oracle once skipped every `datetime.round` in a year at or below 0
(1,506); it now skips only those that reach the next midnight, so 1,425
rounds within the day in those years are compared. The cases of later
phases (`instant.*`, `zoned.*`) are not answered yet.

## The independent review

A review of the branch (2026-11-21) found nothing blocking; it confirmed
the oracle's counts and Jiff's carry bug (in year -5, 23:30 rounds to
00:00 of the day before), and walked every date of the range against a
model. Its findings, each fixed with a case that failed before the fix
(checked with the branch's previous `rig`, f2d2f0bf9):

1. A generic body passed every check by (above): refused at the
   instance, with a case for each check, std.time's `round` among them
   (`std-datetime-checks`, "a generic body cannot call a checked
   method").
2. Nothing ran the comparison with the oracle: `jiff_oracle.sh` now
   builds `answer.rig` and requires every answer to be Jiff's.
3. Behaviours kept with no ported test, and omissions not listed: the
   tests named in the table above, the whole range walked, and Jiff's
   documentation examples (doc-examples.md).
4. A date's `add(0.5)` or `add(time.duration(hours: 24))` suggested
   `add(days: …)`, which takes an `Int`: they are told a date has no time
   of day. Two units to a `Time`'s `round` suggested an increment it
   refuses (`minutes: 61`): now one it takes, or one of the units given.
5. A test printed a literal `1h` and divided `hours()` by 24 (§6.4 says
   never): it counts days and gives the rest.
6. The oracle skipped every round in a year at or below 0: only those
   reaching the next midnight now.
7. A refusal's fix dropped the other amounts: it keeps them.
8. Panics said "1 days" and "0 days and 1s": they write the keywords.
9. STD's "Until `Instant` lands" was not timeless: reworded.

## Verification

On the Mac, through `tools/heavy`, after the rebase on c2f90250a and the
review's fixes:

- `zig build`, and `zig build test`.
- Swarm on what changed with `oracle` and `unit`: the five
  `std-datetime*` files, `std-time`, `std-time-forms`, `std-time-waits`,
  the generic files `errors-generic`, `ownership-generic`, `types-apis`,
  `types-generic`, `doc-STD`, and `cli.jiff_oracle` (which compares the
  oracle's 1.74 million cases): 840 jobs, none died.
- `tools/emit-diff origin/main` (main at c2f90250a): identical, 38
  programs, 583 files.
- The whole core suite once (`tools/heavy --class correctness swarm
  test/rig.rip -w 4`): 12,373 jobs in 596 s, none died. (Before the
  rebase and the review: 12,330 jobs, none died.)
- A plain `tools/heavy zig build` last. The coordinator runs the guards,
  the Trig and loco light gates, and the Linux checks.
