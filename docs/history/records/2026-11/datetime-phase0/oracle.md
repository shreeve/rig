# The Jiff oracle (datetime phase 0, 2026-11-20)

`tools/jiff-oracle/`: a Rust program built against Jiff 1.0.0 that
answers generated cases one line for each line, for `std.datetime`'s
answers to be compared with (DATETIME-DESIGN §12). Its README is the
reference for the line format; this record says what was built, how many
cases there are, how long they take, and how the zone data was checked.
The Mac, Apple M5, Rust 1.99.1, Python 3.

## What it is built from

| Crate | Version | Checksum (Cargo.lock) |
|---|---|---|
| `jiff` | 1.0.0 | `9cc767b5763de45e810109520123bb2829a653f3a7ed9be40b2bc4f81158f595` |
| `jiff-core` | 1.0.0 | `894f7ac42105f584100691b3bf6e6b92dd12fcfa225f6c397f95c8a94b47b68f` |
| `jiff-tzdb` | 1.0.0 | `12e71a1b68a875a44a33bb7a1dd84392cb77145a3367a552a3cfe6a4f5cf3afc` |

- `jiff` is named with `default-features = false, features = ["std",
  "tzdb-bundle-always"]`.
- `jiff-core` and `jiff-tzdb` are named too, each `=1.0.0`. Jiff's
  manifest allows any 1.x of both, and without them Cargo took
  `jiff-core` 1.0.1, which is not the code Jiff 1.0.0 was released with.
- The sources Cargo fetched are the clone at `misc/jiff` (tag 1.0.0,
  `3b1bdf9`): `diff -r` of each crate's `src` differs only in the clone's
  test data, and the two `concatenated-zoneinfo.dat` are identical.
- Cargo fetches into its own registry, outside the repository; the build
  goes to `tools/jiff-oracle/target/` (ignored by the folder's
  `.gitignore`), or, in the test, under `$RIG_OUT_DIR`.

## The bundle, and nothing else

**From Jiff's source.** With `tzdb-zoneinfo` and `tzdb-concatenated` off,
`src/tz/db/zoneinfo/mod.rs` and `src/tz/db/concatenated/mod.rs` select
their `disabled.rs`, whose `from_env` returns a database that
`is_definitively_empty`. `TimeZoneDatabase::from_env`
(`src/tz/db/mod.rs:297`) tries those two first and then
`bundled::Database::new()`, which `tzdb-bundle-always` selects
(`src/tz/db/bundled/mod.rs`). `tz::db()` is that database. `TZDIR` is read
only by the zoneinfo reader, and `TZ` only by `tz-system`, which is off.

**By a run** (`gen.py --bundle-check`, also run by the test):

- `jiff-oracle --version` prints `jiff 1.0.0,
  TimeZoneDatabase(Bundled(available)), jiff-tzdb 2026f`.
- `gen.py` decodes the bundle itself: the name table in `tzname.rs`, each
  name's TZif record (version 2, the 64-bit block), and the POSIX rule at
  its end, expanded year by year. For all 598 names, every transition
  through 2040, 41,415 in all, and the offset before the first, Jiff's
  `following` gives exactly what the bundle has: time, offset and
  abbreviation.
- The machine's own data is also 2026f (`/usr/share/zoneinfo/+VERSION`),
  so agreeing with the bundle does not by itself show the machine's files
  are unread. So the check builds a false `zoneinfo` whose
  `America/New_York` and `UTC` are Tokyo's, and asks 7,218 questions
  (every transition, and the zone cases of `America/New_York`, `UTC` and
  `Asia/Tokyo`) with `TZ` and `TZDIR` unset, with `TZDIR` at the false
  directory, with `TZ=Asia/Tokyo`, with both (`TZ=:America/New_York`),
  and with `TZDIR` at a missing directory. All five give the same
  answers. A Jiff that read `TZDIR` would have answered New York's
  questions with Tokyo's offsets.

## The format

One case to a line: an operation, then its arguments, separated by
single spaces; a `.parse` takes the rest of the line. One answer to a
line, its parts separated by single spaces. Values are written as Jiff
prints them, which Rig prints and reads; a zoned value in a case is a zone
and an instant (`America/Denver 2026-03-08T09:30:00Z`); durations are ISO
8601 as Jiff prints them (Rig's `iso()`). A value Jiff refuses is `error`;
a case where Rig differs on purpose is `skip`; a line the oracle cannot
read stops it with status 2 and the line's number. The operations, by
the four kinds of §12 and a fifth for rounding:

| File | Operations |
|---|---|
| `calendar.in` | `date.add`, `date.info`, `datetime.add`, `zoned.add`, `time.add`, `instant.add` |
| `zones.in` | `instant.in_zone`, `datetime.in_zone` (all four resolutions), `date.in_zone`, `zoned.start_of_day`, `zone.name`, `zone.eq`, and `zoned.add` of a day and of 24 hours |
| `counts.in` | `date.count`, `datetime.count`, `zoned.count`: a since b in days, weeks, months and years; years, months and days; the rest |
| `text.in` | `date.parse`, `time.parse`, `datetime.parse`, `instant.parse`, `duration.parse`, `zoned.parse` (with each `conflict:`) |
| `round.in` | `time.round`, `datetime.round`, `instant.round`, `zoned.round`, `duration.round`: the round, then the floor |

`zone.transitions` serves the bundle check.

## Left out, where Rig differs on purpose

- `round` answers `skip` for an `Instant` before 1970 exactly half way
  (§9 item 12), for a `DateTime` or `ZonedDateTime` in a year at or below
  0 (item 14), and for a `ZonedDateTime`'s `round(days: 1)` unless the
  value is in its own date's range and that date's start plus a day on the
  clock is the next date's start (item 14). `floor` is checked in all of
  them. In the full run: 2,889 instant rounds, 1,506 datetime
  rounds, and 114 of 4,000 zoned `days: 1` rounds are `skip`.
- No amounts of both signs (item 4); no counts across two zones (item 3);
  no text for `Date`, `Time` or `DateTime` beyond its own form (item 15);
  no bare number as a duration (item 7); durations compared as ISO 8601,
  not as Rig prints them (item 8).

## The cases

| File | Cases | Of which |
|---|---|---|
| `calendar.in` | 544,224 | 437,283 `date.add` (6,941 dates of 19 years, each against 49 month offsets, 11 year offsets and 3 mixed amounts), 6,941 `date.info`, 40,000 `datetime.add`, 40,000 `zoned.add`, 10,000 `time.add`, 10,000 `instant.add` |
| `zones.in` | 656,038 | 157,714 `instant.in_zone`, 219,633 `datetime.in_zone`, 30,716 `date.in_zone`, 49,064 `zoned.start_of_day`, 196,256 `zoned.add`, 1,794 `zone.name`, 861 `zone.eq` |
| `counts.in` | 327,846 | 174,036 `date.count`, 60,004 `datetime.count`, 93,806 `zoned.count`, each pair in both orders |
| `text.in` | 66,841 | 40,768 `zoned.parse`, 6,011 `duration.parse`, and about 5,000 of each other; 134 of them fixed spellings |
| `round.in` | 75,000 | 15,000 each of time, datetime and instant, 20,000 zoned, 10,000 durations |
| **all** | **1,669,949** | |

- Every generated text of a value reads back as itself, apart from the
  forms meant not to (no offset, `Z`, a conflicting offset, durations in
  seconds alone).
- The two rests of a count (after the whole days, and after the years,
  months and days) were never different: no answer carries the `/` that
  marks one.
- `gen.py` writes the same bytes on every run (a splitmix64 seed, and the
  bundle). sha256 of the inputs: `calendar.in` `6fe2c95f…`, `zones.in`
  `26b46ef7…`, `counts.in` `98b061d2…`, `text.in` `88ed8991…`,
  `round.in` `5fa07f0d…`.

## The time

Under `tools/mac-claim`, five runs of the whole: `gen.py DIR`, then each
file through the oracle. The fastest: **2.89 s**, of which `gen.py` 2.24 s
and the oracle 0.62 s (1.67 million answers, about 2.7 million a second).
The five totals were 2.89 to 3.14 s. Building the oracle once its crates
are fetched takes about 5 s.

## Verified

- `cargo build --release --locked` in `tools/jiff-oracle/`.
- `tools/heavy swarm test/rig.rip cli.jiff_oracle -q`: passed (one job,
  `.swarm/died` empty). The test builds the oracle under `$RIG_OUT_DIR`,
  checks 27 answers against the values Jiff's tests and examples assert
  (each cited by file and line), checks that amounts of both signs stop it
  with status 2, and runs the bundle check.
- The test with no `cargo` on the `PATH` prints `cargo is not
  installed: skipped` and passes.
