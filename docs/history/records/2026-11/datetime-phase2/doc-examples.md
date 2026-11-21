# Jiff's documentation examples of `Date`, `Time`, `DateTime`, and `Weekday`

Every example in the doc comments of Jiff 1.0.0's `src/civil/date.rs`,
`time.rs`, `datetime.rs`, `weekday.rs`, and `iso_week_date.rs` (354), by
the line its code starts on and the item it documents: ported to
`test/rig/std-datetime-docs.rig.test` (the case named), or left out, and
why. Section numbers are docs/design/datetime.md's. Extracted from
the source at `misc/jiff` (tag 1.0.0).

Ported: 170. Left out: 184.

| Example | Item | Title | Status |
|---|---|---|---|
| `date.rs:37` | `Date` |  | ported: `type-level examples: text, order, sums, counts` |
| `date.rs:49` | `Date` |  | left out: the text of another type's form, which Rig refuses (§8.1), or a rounded difference (§6.1) |
| `date.rs:73` | `Date` |  | ported: `type-level examples: text, order, sums, counts` |
| `date.rs:96` | `Date` |  | ported: `type-level examples: text, order, sums, counts` |
| `date.rs:108` | `Date` |  | ported: `type-level examples: text, order, sums, counts` |
| `date.rs:120` | `Date` |  | ported: `type-level examples: text, order, sums, counts` |
| `date.rs:135` | `Date` |  | ported: `type-level examples: text, order, sums, counts` |
| `date.rs:199` | `ZERO` | (untitled) | left out: no type constants in Rig (§1.1) |
| `date.rs:229` | `new` | (untitled) | ported: `date examples: making one and its readers` |
| `date.rs:240` | `new` |  | ported: `date examples: making one and its readers` |
| `date.rs:300` | `constant` | (untitled) | left out: a const fn: Rig's `new(…)!` |
| `date.rs:336` | `from_iso_week_date` | (untitled) | left out: no ISO week date type (§4.1, §8.5) |
| `date.rs:381` | `with` | (untitled) | ported: `date examples: with` |
| `date.rs:405` | `year` | (untitled) | ported: `date examples: making one and its readers` |
| `date.rs:437` | `era_year` | (untitled) | left out: not Rig's surface: a year is signed, with a year 0 (§7.1) |
| `date.rs:478` | `month` | (untitled) | ported: `date examples: making one and its readers` |
| `date.rs:495` | `day` | (untitled) | ported: `date examples: making one and its readers` |
| `date.rs:510` | `weekday` | (untitled) | ported: `date examples: making one and its readers` |
| `date.rs:534` | `day_of_year` | (untitled) | ported: `date examples: making one and its readers` |
| `date.rs:563` | `day_of_year_no_leap` | (untitled) | left out: not Rig's surface (§2) |
| `date.rs:587` | `first_of_month` | (untitled) | ported: `date examples: making one and its readers` |
| `date.rs:602` | `last_of_month` | (untitled) | ported: `date examples: making one and its readers` |
| `date.rs:621` | `days_in_month` | (untitled) | ported: `date examples: making one and its readers` |
| `date.rs:642` | `first_of_year` | (untitled) | left out: not Rig's surface (§2, §6.7) |
| `date.rs:657` | `last_of_year` | (untitled) | left out: not Rig's surface (§2, §6.7) |
| `date.rs:675` | `days_in_year` | (untitled) | left out: not Rig's surface (§2) |
| `date.rs:694` | `in_leap_year` | (untitled) | left out: not Rig's surface (§2) |
| `date.rs:713` | `tomorrow` | (untitled) | left out: not Rig's surface: `add(days: 1)` |
| `date.rs:737` | `yesterday` | (untitled) | left out: not Rig's surface: `add(days: -1)` |
| `date.rs:774` | `nth_weekday_of_month` | (untitled) | ported: `date examples: the nth weekday` |
| `date.rs:787` | `nth_weekday_of_month` |  | ported: `date examples: the nth weekday` |
| `date.rs:805` | `nth_weekday_of_month` |  | ported: `date examples: the nth weekday` |
| `date.rs:851` | `nth_weekday` | (untitled) | ported: `date examples: the nth weekday` |
| `date.rs:877` | `nth_weekday` |  | ported: `date examples: the nth weekday` |
| `date.rs:902` | `nth_weekday` |  | ported: `date examples: the nth weekday` |
| `date.rs:920` | `nth_weekday` | the start of Israeli summer time | ported: `date examples: the nth weekday` |
| `date.rs:938` | `nth_weekday` | getting the start of the week | ported: `date examples: the nth weekday` |
| `date.rs:956` | `nth_weekday` |  | ported: `date examples: the nth weekday` |
| `date.rs:1001` | `iso_week_date` | (untitled) | left out: no ISO week date type: `iso_week()`, `iso_week_year()` (§8.5) |
| `date.rs:1063` | `in_tz` | (untitled) | left out: zones are phase 5 |
| `date.rs:1084` | `in_tz` | dealing with ambiguity | left out: zones are phase 5 |
| `date.rs:1107` | `in_tz` |  | left out: zones are phase 5 |
| `date.rs:1150` | `to_zoned_datetime` | (untitled) | left out: zones are phase 5 |
| `date.rs:1176` | `to_datetime` | (untitled) | left out: `d.at(t)`, tested |
| `date.rs:1206` | `at` | (untitled) | left out: Rig's `at` takes a `Time`, tested |
| `date.rs:1217` | `at` |  | left out: Rig's `at` takes a `Time`, tested |
| `date.rs:1269` | `checked_add` | s | ported: `date examples: add and the counts` |
| `date.rs:1292` | `checked_add` | available via addition operator | ported: `date examples: add and the counts` |
| `date.rs:1301` | `checked_add` | negative spans are supported | ported: `date examples: add and the counts` |
| `date.rs:1314` | `checked_add` | error on overflow | ported: `date examples: add and the counts` |
| `date.rs:1328` | `checked_add` | adding absolute durations | ported: `date examples: add and the counts` |
| `date.rs:1410` | `checked_sub` | (untitled) | left out: no `sub` on these types (§6.2): `checked_add` of a negative amount, tested |
| `date.rs:1441` | `saturating_add` | (untitled) | left out: no saturating sum: `add` panics and `checked_add` fails (§7.2) |
| `date.rs:1464` | `saturating_sub` | (untitled) | left out: no `sub` (§6.2), and no saturating sum |
| `date.rs:1522` | `until` | s | ported: `date examples: add and the counts` |
| `date.rs:1543` | `until` | using bigger units | ported: `date examples: add and the counts` |
| `date.rs:1568` | `until` | rounding the result | ported: `date examples: add and the counts` |
| `date.rs:1596` | `until` | units biggers than days inhibit reversibility | ported: `date examples: add and the counts` |
| `date.rs:1650` | `since` | (untitled) | ported: `date examples: add and the counts` |
| `date.rs:1703` | `duration_until` | (untitled) | left out: a `Date` has no `since` (§6.6); on a `Time` or `DateTime` it is `since`, tested |
| `date.rs:1725` | `duration_until` | difference with [`Date::until`] | left out: a `Date` has no `since` (§6.6); on a `Time` or `DateTime` it is `since`, tested |
| `date.rs:1753` | `duration_until` | getting an unsigned duration | left out: a `Date` has no `since` (§6.6); on a `Time` or `DateTime` it is `since`, tested |
| `date.rs:1780` | `duration_since` | (untitled) | left out: a `Date` has no `since` (§6.6); on a `Time` or `DateTime` it is `since`, tested |
| `date.rs:1808` | `series` | Halloween day of the week | left out: no span (§6.1): a recurrence is `start.add(months: k)` (§6.2) |
| `date.rs:1838` | `series` | how many times do I mow the lawn in a year? | left out: no span (§6.1): a recurrence is `start.add(months: k)` (§6.2) |
| `date.rs:1855` | `series` | a period less than a day | left out: no span (§6.1): a recurrence is `start.add(months: k)` (§6.2) |
| `date.rs:1876` | `series` | finding the most recent Friday the 13th | left out: no span (§6.1): a recurrence is `start.add(months: k)` (§6.2) |
| `date.rs:1917` | `strptime` | (untitled) | left out: parsing by a format string is not in v1 (§8.4) |
| `date.rs:1957` | `strftime` | (untitled) | left out: `format` is phase 6 |
| `date.rs:1970` | `strftime` | errors are silently ignored | left out: `format` is phase 6 |
| `date.rs:1981` | `strftime` |  | left out: `format` is phase 6 |
| `date.rs:2380` | `DateArithmetic` | (untitled) | left out: no span or `Into` argument: keywords (§6.1, §6.2) |
| `date.rs:2495` | `DateDifference` | (untitled) | left out: no span, so no difference builder (§6.1) |
| `date.rs:2561` | `smallest` | (untitled) | left out: rounding a count, or a builder (§6.1, §6.8) |
| `date.rs:2606` | `largest` | (untitled) | left out: rounding a count (§6.1): not Rig's |
| `date.rs:2635` | `mode` | (untitled) | left out: a rounding mode Rig lacks, or rounding a count (§6.8) |
| `date.rs:2684` | `increment` | (untitled) | left out: rounding a count (§6.1), or tested in `round` |
| `date.rs:2904` | `DateWith` | (untitled) | left out: a builder: Rig's `with(…)!` takes the fields by name, tested |
| `date.rs:2944` | `build` | (untitled) | left out: a builder's field Rig lacks (a day of the year, milliseconds, the date or time whole), or its other examples |
| `date.rs:2965` | `build` | error for invalid date | left out: a builder's field Rig lacks (a day of the year, milliseconds, the date or time whole), or its other examples |
| `date.rs:3024` | `year` | (untitled) | ported: `date examples: with` |
| `date.rs:3039` | `year` | only changing the year can fail | ported: `date examples: with` |
| `date.rs:3065` | `era_year` | (untitled) | ported: `date examples: with` |
| `date.rs:3083` | `era_year` |  | ported: `date examples: with` |
| `date.rs:3110` | `era_year` | overrides `DateWith::year` | ported: `date examples: with` |
| `date.rs:3123` | `era_year` |  | ported: `date examples: with` |
| `date.rs:3153` | `month` | (untitled) | ported: `date examples: with` |
| `date.rs:3168` | `month` | only changing the month can fail | ported: `date examples: with` |
| `date.rs:3195` | `day` | (untitled) | ported: `date examples: with` |
| `date.rs:3212` | `day` | changing only the day can fail | ported: `date examples: with` |
| `date.rs:3250` | `day_of_year` | (untitled) | left out: not Rig's surface (§2) |
| `date.rs:3261` | `day_of_year` |  | left out: not Rig's surface (§2) |
| `date.rs:3273` | `day_of_year` |  | left out: not Rig's surface (§2) |
| `date.rs:3310` | `day_of_year_no_leap` | (untitled) | left out: not Rig's surface (§2) |
| `date.rs:3329` | `day_of_year_no_leap` |  | left out: not Rig's surface (§2) |
| `date.rs:3355` | `day_of_year_no_leap` |  | left out: not Rig's surface (§2) |
| `time.rs:45` | `Time` |  | ported: `time examples` |
| `time.rs:57` | `Time` |  | left out: the text of another type's form, which Rig refuses (§8.1), or a rounded difference (§6.1) |
| `time.rs:80` | `Time` |  | ported: `time examples` |
| `time.rs:95` | `Time` |  | ported: `time examples` |
| `time.rs:123` | `Time` |  | ported: `time examples` |
| `time.rs:143` | `Time` |  | ported: `time examples` |
| `time.rs:158` | `Time` |  | ported: `type-level examples: text, order, sums, counts` |
| `time.rs:173` | `Time` |  | ported: `type-level examples: text, order, sums, counts` |
| `time.rs:205` | `Time` |  | ported: `time examples` |
| `time.rs:259` | `new` | (untitled) | ported: `time examples` |
| `time.rs:273` | `new` |  | ported: `time examples` |
| `time.rs:309` | `constant` | (untitled) | left out: a const fn: Rig's `new(…)!` |
| `time.rs:341` | `midnight` | (untitled) | ported: `readers, joining, and with by field` |
| `time.rs:374` | `with` | (untitled) | ported: `time examples` |
| `time.rs:394` | `hour` | (untitled) | ported: `readers, joining, and with by field` |
| `time.rs:411` | `minute` | (untitled) | ported: `readers, joining, and with by field` |
| `time.rs:428` | `second` | (untitled) | ported: `readers, joining, and with by field` |
| `time.rs:445` | `millisecond` | (untitled) | ported: `readers, joining, and with by field` |
| `time.rs:462` | `microsecond` | (untitled) | ported: `readers, joining, and with by field` |
| `time.rs:479` | `nanosecond` | (untitled) | ported: `readers, joining, and with by field` |
| `time.rs:503` | `subsec_nanosecond` | (untitled) | ported: `readers, joining, and with by field` |
| `time.rs:517` | `subsec_nanosecond` | nanoseconds from a timestamp | left out: from an `Instant` (phase 3), or a builder field Rig lacks |
| `time.rs:549` | `to_datetime` | (untitled) | left out: `d.at(t)`, tested |
| `time.rs:581` | `on` | (untitled) | left out: `d.at(t)`, tested |
| `time.rs:592` | `on` |  | left out: `d.at(t)`, tested |
| `time.rs:624` | `wrapping_add` | available via addition operator | ported: `time examples` |
| `time.rs:636` | `wrapping_add` | add nanoseconds to a `Time` | ported: `time examples` |
| `time.rs:648` | `wrapping_add` | add span with multiple units | ported: `time examples` |
| `time.rs:660` | `wrapping_add` | adding an empty span is a no-op | ported: `time examples` |
| `time.rs:669` | `wrapping_add` | addition wraps on overflow | ported: `time examples` |
| `time.rs:691` | `wrapping_add` |  | ported: `time examples` |
| `time.rs:755` | `wrapping_sub` | (untitled) | left out: no weekday arithmetic (§4.1) |
| `time.rs:831` | `checked_add` | add nanoseconds to a `Time` | ported: `time examples` |
| `time.rs:844` | `checked_add` | add span with multiple units | ported: `time examples` |
| `time.rs:857` | `checked_add` | adding an empty span is a no-op | ported: `time examples` |
| `time.rs:868` | `checked_add` | error on overflow | ported: `time examples` |
| `time.rs:888` | `checked_add` |  | ported: `time examples` |
| `time.rs:902` | `checked_add` | adding absolute durations | ported: `time examples` |
| `time.rs:963` | `checked_sub` | (untitled) | left out: no `sub` on these types (§6.2): `checked_add` of a negative amount, tested |
| `time.rs:998` | `saturating_add` | (untitled) | left out: no saturating sum: `add` panics and `checked_add` fails (§7.2) |
| `time.rs:1021` | `saturating_add` |  | left out: no saturating sum: `add` panics and `checked_add` fails (§7.2) |
| `time.rs:1041` | `saturating_sub` | (untitled) | left out: no `sub` (§6.2), and no saturating sum |
| `time.rs:1183` | `until` | s | ported: `time examples` |
| `time.rs:1201` | `until` | using smaller units | ported: `time examples` |
| `time.rs:1245` | `since` | (untitled) | ported: `time examples` |
| `time.rs:1296` | `duration_until` | (untitled) | left out: a `Date` has no `since` (§6.6); on a `Time` or `DateTime` it is `since`, tested |
| `time.rs:1316` | `duration_until` | difference with [`Time::until`] | left out: a `Date` has no `since` (§6.6); on a `Time` or `DateTime` it is `since`, tested |
| `time.rs:1347` | `duration_until` | getting an unsigned duration | left out: a `Date` has no `since` (§6.6); on a `Time` or `DateTime` it is `since`, tested |
| `time.rs:1374` | `duration_since` | (untitled) | ported: `type-level examples: text, order, sums, counts` |
| `time.rs:1430` | `round` | (untitled) | ported: `time examples` |
| `time.rs:1453` | `round` | changing the rounding mode | ported: `time examples` |
| `time.rs:1476` | `round` | rounding to the nearest 5 minute increment | ported: `time examples` |
| `time.rs:1494` | `round` | rounding wraps around on overflow | ported: `time examples` |
| `time.rs:1519` | `series` | visiting every third hour | left out: no span (§6.1): a recurrence is `start.add(months: k)` (§6.2) |
| `time.rs:1541` | `series` |  | left out: no span (§6.1): a recurrence is `start.add(months: k)` (§6.2) |
| `time.rs:1581` | `strptime` | (untitled) | left out: parsing by a format string is not in v1 (§8.4) |
| `time.rs:1622` | `strftime` | (untitled) | left out: `format` is phase 6 |
| `time.rs:1633` | `strftime` |  | left out: `format` is phase 6 |
| `time.rs:1648` | `strftime` | errors are silently ignored | left out: `format` is phase 6 |
| `time.rs:1659` | `strftime` |  | left out: `format` is phase 6 |
| `time.rs:1788` | `core` | (untitled) | left out: Rust's `Debug` and `Display` with a precision: `format` (phase 6) |
| `time.rs:1818` | `core` | (untitled) | left out: Rust's `Debug` and `Display` with a precision: `format` (phase 6) |
| `time.rs:1834` | `core` | setting the precision | left out: Rust's `Debug` and `Display` with a precision: `format` (phase 6) |
| `time.rs:2176` | `TimeArithmetic` | (untitled) | left out: no span or `Into` argument: a duration form (§5.2) |
| `time.rs:2320` | `TimeDifference` | (untitled) | left out: no span, so no difference builder (§6.1) |
| `time.rs:2382` | `smallest` | (untitled) | left out: rounding a count, or a builder (§6.1, §6.8) |
| `time.rs:2419` | `largest` | (untitled) | left out: rounding a count (§6.1): not Rig's |
| `time.rs:2446` | `mode` | (untitled) | left out: a rounding mode Rig lacks, or rounding a count (§6.8) |
| `time.rs:2504` | `increment` | (untitled) | left out: rounding a count (§6.1), or tested in `round` |
| `time.rs:2635` | `TimeRound` | (untitled) | left out: a rounding mode Rig lacks (§6.8) |
| `time.rs:2654` | `TimeRound` |  | left out: a rounding mode Rig lacks (§6.8) |
| `time.rs:2702` | `smallest` | (untitled) | ported: `type-level examples: text, order, sums, counts` |
| `time.rs:2730` | `mode` | (untitled) | ported: `type-level examples: text, order, sums, counts` |
| `time.rs:2776` | `increment` | (untitled) | ported: `type-level examples: text, order, sums, counts` |
| `time.rs:2842` | `TimeWith` | (untitled) | left out: a builder: `with(…)!`, tested |
| `time.rs:2896` | `build` | (untitled) | ported: `time examples` |
| `time.rs:2907` | `build` | error for invalid time | ported: `time examples` |
| `time.rs:2916` | `build` | error for ambiguous sub-second value | left out: a builder's field Rig lacks (a day of the year, milliseconds, the date or time whole), or its other examples |
| `time.rs:2975` | `hour` | (untitled) | ported: `readers, joining, and with by field` |
| `time.rs:3003` | `minute` | (untitled) | ported: `readers, joining, and with by field` |
| `time.rs:3031` | `second` | (untitled) | ported: `readers, joining, and with by field` |
| `time.rs:3068` | `millisecond` | (untitled) | ported: `readers, joining, and with by field` |
| `time.rs:3103` | `microsecond` | (untitled) | ported: `readers, joining, and with by field` |
| `time.rs:3138` | `nanosecond` | (untitled) | ported: `readers, joining, and with by field` |
| `time.rs:3176` | `subsec_nanosecond` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:43` | `DateTime` |  | ported: `datetime examples` |
| `datetime.rs:55` | `DateTime` |  | left out: the text of another type's form, which Rig refuses (§8.1), or a rounded difference (§6.1) |
| `datetime.rs:81` | `DateTime` |  | ported: `datetime examples` |
| `datetime.rs:96` | `DateTime` |  | ported: `datetime examples` |
| `datetime.rs:120` | `DateTime` |  | ported: `datetime examples` |
| `datetime.rs:132` | `DateTime` |  | ported: `type-level examples: text, order, sums, counts` |
| `datetime.rs:147` | `DateTime` |  | ported: `type-level examples: text, order, sums, counts` |
| `datetime.rs:162` | `DateTime` |  | ported: `type-level examples: text, order, sums, counts` |
| `datetime.rs:197` | `DateTime` |  | ported: `datetime examples` |
| `datetime.rs:244` | `ZERO` | (untitled) | left out: no type constants in Rig (§1.1) |
| `datetime.rs:277` | `new` | (untitled) | ported: `datetime examples` |
| `datetime.rs:294` | `new` |  | ported: `datetime examples` |
| `datetime.rs:343` | `constant` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:360` | `constant` |  | ported: `readers, joining, and with by field` |
| `datetime.rs:398` | `from_parts` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:427` | `with` | (untitled) | ported: `datetime examples` |
| `datetime.rs:451` | `year` | (untitled) | ported: `datetime readers` |
| `datetime.rs:483` | `era_year` | (untitled) | left out: not Rig's surface: a year is signed, with a year 0 (§7.1) |
| `datetime.rs:515` | `month` | (untitled) | ported: `datetime readers` |
| `datetime.rs:532` | `day` | (untitled) | ported: `datetime readers` |
| `datetime.rs:549` | `hour` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:566` | `minute` | (untitled) | ported: `datetime readers` |
| `datetime.rs:583` | `second` | (untitled) | ported: `datetime readers` |
| `datetime.rs:600` | `millisecond` | (untitled) | left out: not Rig's: `nanosecond()` is the whole fraction (§2) |
| `datetime.rs:617` | `microsecond` | (untitled) | left out: not Rig's: `nanosecond()` is the whole fraction (§2) |
| `datetime.rs:634` | `nanosecond` | (untitled) | left out: Jiff's three digits are not Rig's `nanosecond()` (§2) |
| `datetime.rs:658` | `subsec_nanosecond` | (untitled) | left out: from an `Instant` (phase 3), or a builder field Rig lacks |
| `datetime.rs:674` | `subsec_nanosecond` | nanoseconds from a timestamp | left out: from an `Instant` (phase 3), or a builder field Rig lacks |
| `datetime.rs:703` | `weekday` | (untitled) | ported: `datetime readers` |
| `datetime.rs:727` | `day_of_year` | (untitled) | ported: `datetime readers` |
| `datetime.rs:756` | `day_of_year_no_leap` | (untitled) | left out: not Rig's surface (§2) |
| `datetime.rs:783` | `start_of_day` | (untitled) | left out: not on a `DateTime` (§6.7: on a `ZonedDateTime`, phase 5) |
| `datetime.rs:801` | `end_of_day` | (untitled) | left out: not Rig's surface |
| `datetime.rs:821` | `first_of_month` | (untitled) | ported: `datetime readers` |
| `datetime.rs:838` | `last_of_month` | (untitled) | ported: `datetime readers` |
| `datetime.rs:857` | `days_in_month` | (untitled) | ported: `datetime readers` |
| `datetime.rs:880` | `first_of_year` | (untitled) | left out: not Rig's surface (§2, §6.7) |
| `datetime.rs:897` | `last_of_year` | (untitled) | left out: not Rig's surface (§2, §6.7) |
| `datetime.rs:915` | `days_in_year` | (untitled) | left out: not Rig's surface (§2) |
| `datetime.rs:934` | `in_leap_year` | (untitled) | left out: not Rig's surface (§2) |
| `datetime.rs:955` | `tomorrow` | (untitled) | left out: not Rig's surface: `add(days: 1)` |
| `datetime.rs:981` | `yesterday` | (untitled) | left out: not Rig's surface: `add(days: -1)` |
| `datetime.rs:1017` | `nth_weekday_of_month` | (untitled) | left out: on a `DateTime` not Rig's; the date's, `dt.date()`, has it (§2) |
| `datetime.rs:1030` | `nth_weekday_of_month` |  | left out: on a `DateTime` not Rig's; the date's, `dt.date()`, has it (§2) |
| `datetime.rs:1048` | `nth_weekday_of_month` |  | left out: on a `DateTime` not Rig's; the date's, `dt.date()`, has it (§2) |
| `datetime.rs:1096` | `nth_weekday` | (untitled) | left out: on a `DateTime` not Rig's; the date's, `dt.date()`, has it (§2) |
| `datetime.rs:1122` | `nth_weekday` |  | left out: on a `DateTime` not Rig's; the date's, `dt.date()`, has it (§2) |
| `datetime.rs:1147` | `nth_weekday` |  | left out: on a `DateTime` not Rig's; the date's, `dt.date()`, has it (§2) |
| `datetime.rs:1166` | `nth_weekday` | the start of Israeli summer time | left out: on a `DateTime` not Rig's; the date's, `dt.date()`, has it (§2) |
| `datetime.rs:1184` | `nth_weekday` | getting the start of the week | left out: on a `DateTime` not Rig's; the date's, `dt.date()`, has it (§2) |
| `datetime.rs:1202` | `nth_weekday` |  | left out: on a `DateTime` not Rig's; the date's, `dt.date()`, has it (§2) |
| `datetime.rs:1233` | `date` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:1248` | `time` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:1275` | `iso_week_date` | (untitled) | left out: no ISO week date type: `iso_week()`, `iso_week_year()` (§8.5) |
| `datetime.rs:1355` | `in_tz` | (untitled) | left out: zones are phase 5 |
| `datetime.rs:1379` | `in_tz` | dealing with ambiguity | left out: zones are phase 5 |
| `datetime.rs:1404` | `in_tz` | errors | left out: zones are phase 5 |
| `datetime.rs:1420` | `in_tz` |  | left out: zones are phase 5 |
| `datetime.rs:1482` | `to_zoned_datetime` | (untitled) | left out: zones are phase 5 |
| `datetime.rs:1501` | `to_zoned_datetime` | POSIX time zone strings | left out: zones are phase 5 |
| `datetime.rs:1609` | `checked_add` | (untitled) | ported: `datetime examples` |
| `datetime.rs:1628` | `checked_add` | available via addition operator | ported: `datetime examples` |
| `datetime.rs:1638` | `checked_add` | negative spans are supported | ported: `datetime examples` |
| `datetime.rs:1652` | `checked_add` | error on overflow | ported: `datetime examples` |
| `datetime.rs:1665` | `checked_add` | adding absolute durations | ported: `datetime examples` |
| `datetime.rs:1762` | `checked_sub` | (untitled) | left out: no `sub` on these types (§6.2): `checked_add` of a negative amount, tested |
| `datetime.rs:1796` | `saturating_add` | (untitled) | left out: no saturating sum: `add` panics and `checked_add` fails (§7.2) |
| `datetime.rs:1822` | `saturating_sub` | (untitled) | left out: no `sub` (§6.2), and no saturating sum |
| `datetime.rs:1892` | `until` | (untitled) | ported: `datetime examples` |
| `datetime.rs:1917` | `until` | using bigger units | ported: `datetime examples` |
| `datetime.rs:1941` | `until` | rounding the result | left out: rounding a count, or a span (§6.1) |
| `datetime.rs:1968` | `until` | units biggers than days inhibit reversibility | ported: `datetime examples` |
| `datetime.rs:2022` | `since` | (untitled) | ported: `datetime examples` |
| `datetime.rs:2073` | `duration_until` | (untitled) | left out: a `Date` has no `since` (§6.6); on a `Time` or `DateTime` it is `since`, tested |
| `datetime.rs:2103` | `duration_until` | difference with [`DateTime::until`] | left out: a `Date` has no `since` (§6.6); on a `Time` or `DateTime` it is `since`, tested |
| `datetime.rs:2131` | `duration_until` | getting an unsigned duration | left out: a `Date` has no `since` (§6.6); on a `Time` or `DateTime` it is `since`, tested |
| `datetime.rs:2158` | `duration_since` | (untitled) | left out: a `Date` has no `since` (§6.6); on a `Time` or `DateTime` it is `since`, tested |
| `datetime.rs:2221` | `round` | (untitled) | ported: `datetime examples` |
| `datetime.rs:2238` | `round` | changing the rounding mode | ported: `datetime examples` |
| `datetime.rs:2257` | `round` | rounding to the nearest 5 minute increment | ported: `datetime examples` |
| `datetime.rs:2281` | `round` | overflow error | ported: `datetime examples` |
| `datetime.rs:2297` | `round` |  | ported: `datetime examples` |
| `datetime.rs:2337` | `series` | when to check a glucose monitor | left out: no span (§6.1): a recurrence is `start.add(months: k)` (§6.2) |
| `datetime.rs:2413` | `strptime` | (untitled) | left out: parsing by a format string is not in v1 (§8.4) |
| `datetime.rs:2452` | `strftime` | (untitled) | left out: `format` is phase 6 |
| `datetime.rs:2465` | `strftime` | errors are silently ignored | left out: `format` is phase 6 |
| `datetime.rs:2476` | `strftime` |  | left out: `format` is phase 6 |
| `datetime.rs:2514` | `core` | (untitled) | left out: Rust's `Debug` and `Display` with a precision: `format` (phase 6) |
| `datetime.rs:2546` | `core` | (untitled) | left out: Rust's `Debug` and `Display` with a precision: `format` (phase 6) |
| `datetime.rs:2562` | `core` | setting the precision | left out: Rust's `Debug` and `Display` with a precision: `format` (phase 6) |
| `datetime.rs:2920` | `DateTimeArithmetic` | (untitled) | left out: no span or `Into` argument: keywords (§6.1, §6.2) |
| `datetime.rs:3045` | `DateTimeDifference` | (untitled) | left out: no span, so no difference builder (§6.1) |
| `datetime.rs:3099` | `smallest` | (untitled) | left out: rounding a count, or a builder (§6.1, §6.8) |
| `datetime.rs:3144` | `largest` | (untitled) | left out: rounding a count (§6.1): not Rig's |
| `datetime.rs:3174` | `mode` | (untitled) | left out: a rounding mode Rig lacks, or rounding a count (§6.8) |
| `datetime.rs:3235` | `increment` | (untitled) | left out: rounding a count (§6.1), or tested in `round` |
| `datetime.rs:3399` | `DateTimeRound` | (untitled) | ported: `datetime examples` |
| `datetime.rs:3418` | `DateTimeRound` |  | ported: `datetime examples` |
| `datetime.rs:3468` | `smallest` | (untitled) | ported: `type-level examples: text, order, sums, counts` |
| `datetime.rs:3499` | `mode` | (untitled) | ported: `type-level examples: text, order, sums, counts` |
| `datetime.rs:3548` | `increment` | (untitled) | ported: `type-level examples: text, order, sums, counts` |
| `datetime.rs:3658` | `DateTimeWith` | (untitled) | left out: a builder: `with(…)!`, tested |
| `datetime.rs:3700` | `build` | (untitled) | ported: `datetime examples` |
| `datetime.rs:3724` | `build` | error for invalid datetime | ported: `datetime examples` |
| `datetime.rs:3748` | `date` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:3773` | `time` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:3804` | `year` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:3820` | `year` | only changing the year can fail | ported: `readers, joining, and with by field` |
| `datetime.rs:3847` | `era_year` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:3865` | `era_year` |  | ported: `readers, joining, and with by field` |
| `datetime.rs:3892` | `era_year` | overrides `DateTimeWith::year` | ported: `readers, joining, and with by field` |
| `datetime.rs:3905` | `era_year` |  | ported: `readers, joining, and with by field` |
| `datetime.rs:3935` | `month` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:3951` | `month` | only changing the month can fail | ported: `readers, joining, and with by field` |
| `datetime.rs:3978` | `day` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:3995` | `day` | changing only the day can fail | ported: `readers, joining, and with by field` |
| `datetime.rs:4033` | `day_of_year` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:4047` | `day_of_year` |  | ported: `readers, joining, and with by field` |
| `datetime.rs:4062` | `day_of_year` |  | ported: `readers, joining, and with by field` |
| `datetime.rs:4099` | `day_of_year_no_leap` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:4120` | `day_of_year_no_leap` |  | ported: `readers, joining, and with by field` |
| `datetime.rs:4146` | `day_of_year_no_leap` |  | ported: `readers, joining, and with by field` |
| `datetime.rs:4173` | `hour` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:4201` | `minute` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:4229` | `second` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:4266` | `millisecond` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:4305` | `microsecond` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:4344` | `nanosecond` | (untitled) | ported: `readers, joining, and with by field` |
| `datetime.rs:4386` | `subsec_nanosecond` | (untitled) | ported: `readers, joining, and with by field` |
| `weekday.rs:28` | `Weekday` |  | left out: weekday arithmetic and offsets other than ISO's are not Rig's (§4.1); its order and `iso_number()` are tested |
| `weekday.rs:40` | `Weekday` |  | left out: weekday arithmetic and offsets other than ISO's are not Rig's (§4.1); its order and `iso_number()` are tested |
| `weekday.rs:56` | `Weekday` |  | left out: weekday arithmetic and offsets other than ISO's are not Rig's (§4.1); its order and `iso_number()` are tested |
| `weekday.rs:68` | `Weekday` | (untitled) | left out: weekday arithmetic and offsets other than ISO's are not Rig's (§4.1); its order and `iso_number()` are tested |
| `weekday.rs:111` | `from_monday_zero_offset` | (untitled) | left out: no weekday from a number (§4.1) |
| `weekday.rs:141` | `from_monday_one_offset` | (untitled) | left out: no weekday from a number (§4.1) |
| `weekday.rs:171` | `from_sunday_zero_offset` | (untitled) | left out: no weekday from a number (§4.1) |
| `weekday.rs:203` | `from_sunday_one_offset` | (untitled) | left out: no weekday from a number (§4.1) |
| `weekday.rs:228` | `to_monday_zero_offset` | (untitled) | left out: only ISO's number, `iso_number()` (§4.1) |
| `weekday.rs:247` | `to_monday_one_offset` | (untitled) | left out: `iso_number()`, tested |
| `weekday.rs:266` | `to_sunday_zero_offset` | (untitled) | left out: only ISO's number (§4.1) |
| `weekday.rs:285` | `to_sunday_one_offset` | (untitled) | left out: only ISO's number (§4.1) |
| `weekday.rs:305` | `next` | (untitled) | left out: no weekday arithmetic (§4.1) |
| `weekday.rs:325` | `previous` | (untitled) | left out: no weekday arithmetic (§4.1) |
| `weekday.rs:345` | `since` | (untitled) | left out: no weekday arithmetic (§4.1) |
| `weekday.rs:366` | `until` | (untitled) | left out: no weekday arithmetic (§4.1) |
| `weekday.rs:389` | `wrapping_add` | (untitled) | left out: no weekday arithmetic (§4.1) |
| `weekday.rs:401` | `wrapping_add` |  | left out: no weekday arithmetic (§4.1) |
| `weekday.rs:427` | `wrapping_sub` | (untitled) | left out: no weekday arithmetic (§4.1) |
| `weekday.rs:439` | `wrapping_sub` |  | left out: no weekday arithmetic (§4.1) |
| `weekday.rs:462` | `cycle_forward` | (untitled) | left out: no weekday arithmetic (§4.1) |
| `weekday.rs:485` | `cycle_reverse` | (untitled) | left out: no weekday arithmetic (§4.1) |
| `iso_week_date.rs:43` | `ISOWeekDate` |  | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:55` | `ISOWeekDate` |  | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:72` | `ISOWeekDate` |  | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:92` | `ISOWeekDate` | sample dates | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:110` | `ISOWeekDate` | overlapping leap and long years | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:132` | `ISOWeekDate` | printing all weeks in a year | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:182` | `ZERO` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:204` | `new` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:246` | `from_date` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:270` | `year` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:290` | `week` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:316` | `weekday` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:348` | `first_of_week` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:386` | `last_of_week` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:429` | `first_of_year` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:467` | `last_of_year` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:512` | `days_in_year` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:534` | `weeks_in_year` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:555` | `in_long_year` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:576` | `tomorrow` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:606` | `yesterday` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
| `iso_week_date.rs:638` | `date` | (untitled) | left out: no ISO week date type (§4.1, §8.5); `iso_week()` and `iso_week_year()` are tested |
