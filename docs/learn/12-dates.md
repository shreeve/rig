# Dates and times that mean what they say

Here is a Python script that books a meeting for noon tomorrow in Denver
and writes the date of a contract:

```python
from datetime import date, datetime, timedelta
from zoneinfo import ZoneInfo

denver = ZoneInfo("America/Denver")
today = datetime(2026, 3, 7, 12, tzinfo=denver)
tomorrow = today + timedelta(days=1)
print(tomorrow - today)                        # 1 day, 0:00:00
signed = date(2027, 1, 31)
print(signed.strftime("%d %b %Y, %H:%M"))      # 31 Jan 2027, 00:00
print(signed.replace(month=2))                 # ValueError
```

Each line looks right, and three of them are not. Only 23 hours pass
between the two noons, since Denver moves its clocks forward that night,
yet the subtraction says a day. A date has no time of day, and
`strftime` prints `00:00` for it without a word. There is no way to add
a month, and the nearest thing fails as the program runs, on the one
day of the year a test did not try.

Rig's `std.datetime` keeps these apart by type, checks what it can as
the program compiles, and makes every failure visible. This chapter
walks through dates, times on the clock, instants, zones, and text, in
that order, and ends on what a program does when a date runs out of
range.

## A date is a day on the calendar

A `Date` is a day and nothing more: no time of day, no zone. Here is a
contract signed on the last day of January, and its renewals:

```rig
use std.datetime

fun leap_day(year: Int) -> datetime.Date!
  datetime.Date.new(year, 2, 29)!

sub main()!
  signed = datetime.Date.new(2027, 1, 31)
  print(signed, signed.weekday())
  print(signed.add(months: 1)!, signed.add(months: 2)!, signed.add(months: 1, days: 1)!)
  print(signed.add(months: 1)!.days_since(signed))
  born = datetime.Date.new(2024, 2, 29)
  print(datetime.Date.new(2025, 2, 28).years_since(born), datetime.Date.new(2025, 3, 1).years_since(born))
  print(leap_day(2028)!)
  leap_day(2027) catch |e| print(e)
```

```output
2027-01-31 Sunday
2027-02-28 2027-03-31 2027-03-01
28
0 1
2028-02-29
DateTimeError.range
```

`Date.new(2027, 1, 31)` has no `!`. Every argument is a constant, so
Rig checks the date as it compiles, and a call that passes cannot fail.
`leap_day` makes its date from a year known only as the program runs,
so there the call can fail, and the `!` after it says so. February 29 of
2027 fails with `DateTimeError.range`, and `catch` prints it.

`add` takes the calendar amounts by name, each of either sign. A month
after January 31 is the last day of February: the day clamps to the
month's end, as Jiff, Temporal, and java.time all do. Months come first,
then days, so a month and a day after January 31 is March 1.

The counts walk forward from the earlier date. Someone born on February
29 is not a year older on February 28 of a common year, and is on March
1. `days_since` is plain subtraction of days.

## A time on the clock is a reading, not a moment

A `DateTime` is a date and a time of day with no zone, what a wall clock
shows, as a Postgres `timestamp` or an HTML `datetime-local` holds one.
It becomes a moment only in a zone, and there the zone's rules apply:

```rig
use std.datetime

sub main()!
  denver = datetime.TimeZone.named("America/Denver")
  today = datetime.DateTime.new(2026, 3, 7, hour: 12).in_zone(denver)!
  print(today)
  print(today.add(days: 1)!)
  print(today.add(hours: 24)!)
  print(today.add(days: 1)!.since(today))
  skipped = datetime.DateTime.new(2026, 3, 8, hour: 2, minute: 30)
  print(skipped.in_zone(denver)!)
  _ = skipped.in_zone(denver, resolve: .reject) catch |e| print(e)
```

```output
2026-03-07T12:00:00-07:00[America/Denver]
2026-03-08T12:00:00-06:00[America/Denver]
2026-03-08T13:00:00-06:00[America/Denver]
23h
2026-03-08T03:30:00-06:00[America/Denver]
DateTimeError.skipped_or_repeated
```

`TimeZone.named("America/Denver")` takes a string literal, which Rig
checks against the zone data as it compiles, so it needs no `!` either.
The data is compiled into the program, and gives the same answer on
every machine.

`in_zone` places the reading on Denver's clock and gives a
`ZonedDateTime`: the instant, the zone, and the zone's offset there. A
zoned value prints in RFC 9557, the offset and the zone's name together,
so text written today reads back as the same moment in the same zone.

The two `add`s answer two questions. `add(days: 1)` is the same time on
the clock tomorrow, noon again, though only 23 hours later; `add(hours:
24)` is exactly 24 hours later, at 13:00. `since` gives the time between
two moments, 23 hours, where Python said a day.

At 02:00 that night the clocks jump to 03:00, so 02:30 never happens in
Denver. `in_zone` moves a skipped time forward by the length of the gap,
as Temporal and Jiff do, and `resolve: .reject` refuses it instead. A
repeated time in November, when 01:30 happens twice, is resolved the
same way.

## An instant is the same everywhere

An `Instant` is a point on the shared timeline, the same in every zone.
A launch time read from an API, shown in two places:

```rig
use std.datetime

sub main()!
  launch = datetime.Instant.parse("2027-03-14T15:00:00Z")!
  tokyo = launch.in_zone(datetime.TimeZone.named("Asia/Tokyo"))
  denver = launch.in_zone(datetime.TimeZone.named("America/Denver"))
  print(tokyo)
  print(denver)
  print(tokyo == denver, tokyo.date() == denver.date())
  print(launch.unix_s(), launch.since(datetime.Instant.from_unix_s(0)).hours())
  stored = String(denver)
  back = datetime.ZonedDateTime.parse(stored)!
  print(back == denver, back.zone() == denver.zone())
```

```output
2027-03-15T00:00:00+09:00[Asia/Tokyo]
2027-03-14T09:00:00-06:00[America/Denver]
true false
1805036400 501399
true true
```

`in_zone` on an instant cannot fail: every instant has a reading in
every zone. Two zoned values of one instant are equal, though their
dates differ, since `==` compares the moments; `zone()` compares the
zones. `String(z)` is how a zoned value is stored, and
`ZonedDateTime.parse` reads it back.

`datetime.now()` reads the wall clock as an `Instant`. The wall clock
can be set, so it can jump. To time a step, read `time.monotonic()`, as
[the standard library chapter](06-stdlib.md#how-long-it-took) does; a
`Monotonic` cannot be mixed up with an `Instant`.

## Text by a format string

`print` writes the standard forms. A person reads something else, and
`format` writes it by a strftime string:

```rig
use std.datetime

LOG = "%Y-%m-%dT%H:%M:%S%.3f%:z"

sub main()!
  denver = datetime.TimeZone.named("America/Denver")
  z = datetime.DateTime.new(2026, 11, 1, hour: 1, minute: 30, ns: 250_000_000).in_zone(denver)!
  print(z.format("%A, %B %-d, %Y at %-I:%M %p %Z"))
  print(z.format(LOG))
  later = z.add(hours: 1)!
  print(later.format(LOG), later.format("%Z"))
  user = String("%d/%m/%Y")
  print(z.date().try_format(user)!)
  _ = z.date().try_format(String("%d/%m/%y")) catch |e| print(e)
```

```output
Sunday, November 1, 2026 at 1:30 AM MDT
2026-11-01T01:30:00.250-06:00
2026-11-01T01:30:00.250-07:00 MST
01/11/2026
DateTimeError.invalid
```

`%-d` drops the day's padding, `%Z` is the zone's abbreviation at that
instant, and `%.3f` writes the fraction to three digits, so every line
of a log has the same width. An hour after the first 01:30 that morning
is the second 01:30, in standard time: the clock shows the same, and the
offset and the abbreviation tell them apart.

`format` takes a string Rig knows as it compiles, a literal or a module
constant such as `LOG`, and checks each directive against the type where
it is called. So the call cannot fail, and gives a plain `String`. A
string made as the program runs, such as a user's setting, goes to
`try_format`, which fails with `DateTimeError.invalid` exactly where
`format` would not have compiled: here at `%y`, a two-digit year, which
Rig leaves out.

The check is what catches Python's silent `00:00`:

```rig reject
use std.datetime

sub main()
  signed = datetime.Date.new(2027, 1, 31)
  print(signed.format("%d %b %Y, %H:%M"))
```

```error
5:23: `signed.format("%d %b %Y, %H:%M")`: `%H` in the format string does not suit a `Date`: a `Date` has no time of day
```

A misspelled zone fails the same way, as Rig compiles, with the name it
meant:

```rig reject
use std.datetime

sub main()
  print(datetime.TimeZone.named("America/Denvr"))
```

```error
4:33: the zone data has no zone named `America/Denvr`; did you mean `"America/Denver"`?
```

And a date has no hours to add:

```rig reject
use std.datetime

sub main()
  signed = datetime.Date.new(2027, 1, 31)
  print(signed.add(hours: 1))
```

```error
5:20: a `Date` has no time of day, so `add` takes no `hours:`: a date and a time of day is a `DateTime`, `d.at(t).add(hours: 1)`
```

## When a date runs out

Dates run from -9999-01-01 to 9999-12-31, and 9999-12-31 is a common
"no end" in databases. A day after it does not exist. In Rig, no call of
`std.datetime` panics on any value: each either gives an answer for
every value it takes, or returns `!`. A renewal period read from a file
is ordinary data that can run past the end:

```rig
use std.datetime

fun renew(start: datetime.Date, months: Int) -> datetime.Date!
  start.add(months: months)!

sub main()
  start = datetime.Date.new(2027, 1, 31)
  print(renew(start, 12) catch datetime.Date.max())
  print(renew(start, 200_000) catch datetime.Date.max())
  last = datetime.Date.max()
  next = last.add(days: 1) catch |e|
    print("no day after", last, e)
    last
  print(next)
```

```output
2028-01-31
9999-12-31
no day after 9999-12-31 DateTimeError.range
9999-12-31
```

`renew` passes a failure up with `!`, and its caller decides. One
`catch` keeps the last date by name, `catch datetime.Date.max()`, and
the other says what happened. What the docs never write is `?? d`, a
fallback that gives a wrong date without a word: a program that wants
the end of the range asks for it.

There is one `add` for each type, the fallible one, and no twin that
saturates or panics. The calls that cannot fail have no `!`: the
readers, the counts, `since`, printing, `format` with a checked string,
and `in_zone` on an instant.

## Summary

| To | Write |
|---|---|
| make a date or a time | `Date.new(2027, 1, 31)`, `Time.new(8, 30, 0)`; with a run-time part, `Date.new(y, 1, 31)!` |
| add calendar amounts | `d.add(months: 1)!`, `z.add(days: 1)!`; exact time, `z.add(hours: 24)!` |
| count | `a.days_since(b)`, `a.months_since(b)`, `a.since(b)` |
| place a reading in a zone | `dt.in_zone(tz)!`, `dt.in_zone(tz, resolve: .reject)!` |
| show an instant in a zone | `i.in_zone(tz)` |
| name a zone | `TimeZone.named("America/Denver")`, checked as Rig compiles |
| store and read back | `String(z)`, `ZonedDateTime.parse(s)!` |
| write for a person | `x.format("%A, %B %-d")`; a run-time string, `x.try_format(s)!` |
| keep the end of the range | `d.add(days: n) catch datetime.Date.max()` |

**A calendar day, a time on the clock, and a moment are three types,
and every call on them either cannot fail or says so with `!`.**

## What is not there yet

There is no parsing by a format string: text is read in ISO 8601,
RFC 3339, and RFC 9557 only. There are no locales, so names are English,
and no RFC 2822 dates for email and HTTP. The zone data is compiled into
the program and is never loaded as it runs. The design and its reasons
are in [design/datetime.md](../design/datetime.md).

## Where to go next

- [The standard library: a tool in an afternoon](06-stdlib.md) times a
  step with `std.time`, beside the files, JSON, and the rest a tool
  needs.
- [Errors and optionals: failure you can see](03-errors.md) covers `!`,
  `catch`, and error sets, which every fallible call here uses.
- [STD](../STD.md#stddatetime) lists every member of `std.datetime` and
  `std.time`, and every `format` directive.
- [SPEC §13](../../SPEC.md#13-errors) states the rule that a maker of
  constants takes no `!`.
