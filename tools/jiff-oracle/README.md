# The Jiff oracle

Jiff 1.0.0's answers for `std.datetime` (DATETIME-DESIGN §12). `gen.py`
writes the cases, one to a line; `jiff-oracle` reads them and prints
Jiff's answer to each, one line for each line, which Rig's answers to the
same cases are compared with line for line. Jiff's answers are not
committed: they are made where they are compared.

```bash
cd tools/jiff-oracle
cargo build --release --locked             # target/release/jiff-oracle
python3 gen.py DIR                         # DIR/calendar.in … round.in
target/release/jiff-oracle < DIR/zones.in > DIR/zones.out
python3 gen.py --kind counts               # one kind, to stdout
python3 gen.py --bundle-check target/release/jiff-oracle
```

`test/cli/jiff_oracle.sh` builds it, checks a fixed set of its answers
against the values Jiff's own tests assert, runs the bundle check, and
compares std.datetime's and std.time's answers to every generated case
with Jiff's (below); it is skipped where there is no Rust toolchain.

## What it is built from

- `jiff` 1.0.0, `jiff-core` 1.0.0 and `jiff-tzdb` 1.0.0, each pinned to
  that exact version in `Cargo.toml` and by its checksum in `Cargo.lock`.
  Jiff's own manifest allows any `jiff-core` 1.x and `jiff-tzdb` 1.x;
  naming them pins the two Jiff 1.0.0 was released with.
- `default-features = false, features = ["std", "tzdb-bundle-always"]`.
  Without `tzdb-zoneinfo` and `tzdb-concatenated`, Jiff's readers of the
  machine's zone files are the stubs in `src/tz/db/zoneinfo/disabled.rs`
  and `src/tz/db/concatenated/disabled.rs`, which find nothing, so
  `tz::db()` (`src/tz/db/mod.rs`, `from_env`) falls through to the bundle:
  jiff-tzdb's `concatenated-zoneinfo.dat`, IANA `2026f` in the rearguard
  form. Without `tz-system`, nothing reads `TZ`.
- `jiff-oracle --version` prints the database Jiff uses and the bundle's
  version: `jiff 1.0.0, TimeZoneDatabase(Bundled(available)), jiff-tzdb
  2026f`.

`gen.py --bundle-check BIN` shows it by a run. It decodes the bundle
itself (each name's TZif record and the POSIX rule at its end), asks the
oracle for every transition of all 598 names through 2040, and requires
the two to agree; then it asks again with `TZDIR` pointing at a false
`zoneinfo` (its `America/New_York` and `UTC` are Tokyo's) and with `TZ`
set, and requires the same answers.

`gen.py` reads the bundle from the copy Cargo fetched for this folder
(`cargo metadata --locked`), which Cargo checks against the checksum in
`Cargo.lock`; it refuses any other version.

## The line format

A case is one line: an operation, a space, and its arguments, separated
by single spaces. For a `.parse` operation the argument is the rest of
the line, spaces included. The answer is one line; where an answer has
several parts they are separated by single spaces.

- A value Jiff refuses (out of range, a skipped or repeated time under
  `reject`, text it does not read) prints `error`.
- A case where Rig differs from Jiff on purpose prints `skip`, as a whole
  or as one part of its answer, and the comparison passes over that
  (below). A duration of `i64::MIN` seconds, one past Rig's symmetric
  range (§5.1), is one: `duration.parse` of such a text, and
  `duration.round` of such an input or with such an answer.
- A line the oracle cannot read (an unknown operation, a malformed
  argument, amounts of both signs) is a mistake in the generator, not an
  answer: the oracle stops with exit status 2 and names the line.

Arguments are written as Jiff prints, which is what Rig prints and reads:

| Argument | Form | Example |
|---|---|---|
| DATE | ISO 8601; a year outside 0 to 9999 with a sign and six digits | `2024-02-29`, `-000001-01-01` |
| TIME | `HH:MM:SS`, and a fraction when it is not zero | `13:45:00.5` |
| DATETIME | DATE `T` TIME | `2024-02-29T13:45:00` |
| INSTANT | RFC 3339 in UTC, ending in `Z` | `2024-02-29T20:45:00Z` |
| ZONE | a name in the data, in any case, or a fixed offset `±HH:MM` | `America/Denver`, `-07:00` |
| Y M W D | years, months, weeks and days, integers of one sign | `0 1 0 3`, `-1 0 0 -2` |
| DUR | a duration in ISO 8601, as Jiff prints it (Rig's `iso()`) | `PT1H30M`, `-PT0.5S` |
| UNIT INC | a rounding unit (`ns`, `us`, `ms`, `seconds`, `minutes`, `hours`, `days`) and its increment | `minutes 15` |

A zoned value in a case is a ZONE and an INSTANT: the instant shown in
that zone. Answers print each value as its type prints (§8.1): a
ZonedDateTime in RFC 9557 (`2026-03-08T03:30:00-06:00[America/Denver]`,
its offset rounded to the minute), a duration in ISO 8601.

### 1. Calendar arithmetic (`calendar.in`)

| Case | Answer | Rig |
|---|---|---|
| `date.add DATE Y M W D` | DATE | `d.add(years:, months:, weeks:, days:)` |
| `date.info DATE` | weekday, day of year, days in month, ISO week, ISO week year, first and last of the month | `weekday()` … `last_of_month()` |
| `datetime.add DATETIME Y M W D DUR` | DATETIME | `dt.add(duration: d, years:, …)` |
| `zoned.add ZONE INSTANT Y M W D DUR` | ZONED | `z.add(duration: d, years:, …)` |
| `time.add TIME DUR` | the wrapped TIME | `t.add(d)` |
| `instant.add INSTANT DUR` | INSTANT | `i.add(d)` |
| `instant.unix INSTANT` | DUR; the whole seconds, milliseconds and microseconds, each floored; INSTANT again from that DUR | `i.unix()`, `i.unix_s()`, `i.unix_ms()`, `i.unix_us()`, `Instant.from_unix_s(u.seconds(), ns: u.subsec_ns())` |
| `instant.since INSTANT INSTANT` | DUR | `a.since(b)` |
| `date.nth_weekday DATE N WEEKDAY` | DATE | `d.nth_weekday(n, w)` |
| `date.nth_weekday_of_month DATE N WEEKDAY` | DATE | `d.nth_weekday_of_month(n, w)` |
| `date.with DATE Y M D` | DATE | `d.with(year:, month:, day:)` |
| `time.since TIME TIME` | DUR | `a.since(b)` |
| `datetime.since DATETIME DATETIME` | DUR | `a.since(b)` |

Every date of 19 years (-9999, -9998, -1, 0, 1, 4, 100, 1600, 1900, 1969,
1970, 2000, 2023, 2024, 2025, 2100, 2400, 9998, 9999) against each month
offset from -24 to 24, against ±1, 4, 100, 400 and 19,998 years and
19,999, and three mixed amounts; then dates and times, zoned values (in
the zones of `gen.py`'s `ZONES` and every name) and times of day with
random amounts. Then, from a stream of their own, each date of the 19
years with `nth_weekday` of 1, -1, and one of ±2, ±5, ±53, 0 and
±1,000,000, `nth_weekday_of_month` twice with `n` from -6 to 6, and
`with` of a random date's parts or an impossible one; and 10,000
`time.since` and 20,000 `datetime.since`, each exact (§6.6). Then, from a
stream of their own, 10,000 `instant.unix`, three in four within an `Int`
of nanoseconds of 1970 and the rest across the whole range, the ends of
each among them, and 20,000 `instant.since` (§5.1, §7.8).

### 2. Zones (`zones.in`)

| Case | Answer | Rig |
|---|---|---|
| `instant.in_zone INSTANT ZONE` | ZONED, its exact offset (`-00:44:30`), its abbreviation | `i.in_zone(tz)`, `offset_text()`, `format("%Z")` |
| `datetime.in_zone DATETIME ZONE` | four ZONEDs: `.compatible`, `.earlier`, `.later`, `.reject` | `dt.in_zone(tz, resolve:)` |
| `date.in_zone DATE ZONE` | ZONED: the start of the date | `d.in_zone(tz)` |
| `zoned.with ZONE INSTANT DATETIME` | four ZONEDs, the date and time on the clock replaced by DATETIME's: `.compatible`, `.earlier`, `.later`, `.reject` | `z.with(year:, …, ns:, resolve:)` |
| `zoned.start_of_day ZONE INSTANT` | ZONED | `z.start_of_day()` |
| `zone.name ZONE` | the name in the data's spelling | `tz.name()` |
| `zone.eq ZONE ZONE` | `true` or `false` | `==` |
| `zone.offset ZONE INSTANT` | the offset in seconds, east positive | `tz.offset_at(i).seconds()` |
| `zone.transitions ZONE INSTANT` | the offset (seconds) and abbreviation before the first transition, then `UNIX/OFFSET/ABBR` for each transition before the instant | (the bundle check) |

For each of the 598 names, and each transition through 2040 (and its
rule's in 2100, 2400 and 9998): the instant an hour before, a second
before, at, a second after and an hour after it; the clock an hour
before, a second before, at and a second after each side of the change,
and in its middle; the start of the dates on each side; the start of the
day a second either side; `with` from half an hour either side to the
clock a second before the change, at either end of it, in its middle and
a second before its end; and a day and 24 hours added and taken away
half an hour either side. A name whose rules are another's (the same
bytes in the bundle) is tested a second either side of each transition,
and the rest once under the first name. Then the ends of the range, in
zones east and west and in fixed zones of ±25:59. Last, the offset alone
of every name, its rules' names too: an hour and a second before each
transition through 2040 and each of its rule's in 2100, 2400 and 9998,
at it and an hour after; the first and last instants in each; and five
fixed zones at the first instant, 1970 and the last.

### 3. Counts (`counts.in`)

| Case | Answer |
|---|---|
| `date.count DATE DATE` | a since b in days, weeks, months, years; then years, months, days from the earlier to the later |
| `datetime.count DATETIME DATETIME` | the same, then the rest, a DUR |
| `zoned.count ZONE INSTANT INSTANT` | the same, both in ZONE |

`a since b` is `a.days_since(b)` (and weeks, months, years): Jiff's
`earlier.until((unit, later))`, negative when a is the earlier (§6.4).
The years, months and days are Jiff's `earlier.until((Unit::Year,
later))`, which §6.4's recipe must give, and the rest its part below a
day. The rest after the whole days (`until((Unit::Day, later))`) is §6.4's
`late.since(early.add(days: n))`; were the two rests ever different, both
would print, joined by `/` (none is, in the full run).

Each pair is written in both orders. Every date of six years against
offsets of 0 to 1,461 days chosen about month and year ends; random
dates; dates and times; and zoned values about the transitions of the
zones in `ZONES` and of every zone, at distances of an hour to 800 days,
with the design's cases (§12).

### 4. Text (`text.in`)

| Case | Answer |
|---|---|
| `date.parse TEXT`, `time.parse`, `datetime.parse`, `instant.parse` | the value printed |
| `duration.parse TEXT` | DUR |
| `zoned.parse TEXT` | three ZONEDs: conflict `.reject` (the default), `.keep_instant`, `.keep_clock` (§8.3) |

Random values in the form each prints, which must read back as
themselves (zoned values with the offset the bundle gives, with no
offset, with `Z`, and with an offset the zone does not have then), and
each spelling of §8.1's and §5.5's tables. Durations are compared as
ISO 8601: Rig's `print` of a duration is its own (§9 item 8).

### 5. Rounding (`round.in`)

| Case | Answer |
|---|---|
| `time.round TIME UNIT INC` | `round`, then `floor` |
| `datetime.round DATETIME UNIT INC` | the same |
| `instant.round INSTANT UNIT INC` | the same |
| `zoned.round ZONE INSTANT UNIT INC` | the same |
| `duration.round DUR UNIT INC` | the same |

`round` is Jiff's `RoundMode::HalfExpand` and `floor` its
`RoundMode::Floor`. Only increments Rig allows (§6.8) are given; values
fall often on a multiple or exactly half way.

## std.datetime's answers

`answer.rig` gives std.datetime's and std.time's answers to the same
lines, every case but one part: the abbreviation of `instant.in_zone`,
`format("%Z")`'s, which phase 6 builds, prints `-`, as a case or a part
not answered does. A call that fails prints `error`, as Jiff's does
(§7.2). `compare.awk` compares them part for part, passing over each `-`
and each `skip`, and prints each difference and the counts;
`jiff_oracle.sh` requires no difference.

```bash
bin/rig build --release tools/jiff-oracle/answer.rig -o DIR/answer
DIR/answer DIR/calendar.in > DIR/calendar.rig
paste -d '\t' DIR/calendar.in DIR/calendar.out DIR/calendar.rig | awk -f tools/jiff-oracle/compare.awk
```

## Left out

The oracle does not check where Rig differs from Jiff on purpose
(§6.8, §9); each of these is tested directly in Rig.

- **Rounding.** `round` prints `skip` for an `Instant` before 1970 that is
  exactly half way (Jiff takes it away from 1970, §9 item 12); for a
  `DateTime` or `ZonedDateTime` in a year at or below 0 that reaches the
  next midnight (Jiff 1.0.0 does not carry it into the next day there,
  item 14), the `DateTime`'s round as one part of its answer; and for `round(days: 1)` on a
  `ZonedDateTime` unless the value lies in its own date's range and that
  date's start plus a day on the clock is the next date's start (item 14).
  `floor` is checked in each of these.
- **The one duration past Rig's range.** Jiff's `SignedDuration` holds
  `i64::MIN` seconds, which Rig's symmetric range leaves out so that no
  negation fails (§5.1, §9 item 17); a duration case at it prints `skip`.
- **Mixed signs.** Amounts of both signs are never given: Rig applies
  each group with its own sign, which Jiff's span cannot (§6.2, item 4).
- **Counts across two zones**, which Jiff refuses (§6.4, item 3).
- **Text a type reads only in its own form.** `Date`, `Time` and
  `DateTime` are given no text with more than their own form (an offset, a
  zone, or a date with a `Time`), which Rig rejects and Jiff drops without
  a word (§8.1, item 15). No bare number is given as a duration (item 7).
- **What Rig does not have:** a `TimeZone.parse` of Rig's own forms, a
  default zone in parsing (§8.2), a calendar keyword on a `Date` that is
  not a calendar unit, `format` (phase 6).

## Size

About 2.19 million cases. `gen.py` writes them in about 3.4 s and the
oracle answers them in about 1 s.
