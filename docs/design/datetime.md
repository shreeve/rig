# Dates, times and zones for Rig: design brief, v3

Status: **final**, 2026-11-17, amended 2026-11-20 and 2026-11-22 (every call is total
or visibly fallible, and `Duration` is 16 bytes: "Total or visible" below, and 5.1).
Nothing in it is open: each decision is the owner's,
follows Jiff, or is forced by Rig. It was reviewed over ten rounds, and states the
design as it stands; the history is in section 13.

This file is the whole design. The reviews that led to it are in `reviews/`, kept as
evidence for its measurements; where one of them disagrees with this file, this file is
right. The earlier drafts, v1 and v2, are deleted. The panels and the committee behind
"Total or visible" are in `records/2026-11/datetime-strategy`.

- `reviews/jiff-check.md` and `reviews/independent-review*.md`: the design against Jiff
  1.0.0's source, with measurements;
- `reviews/rig-side.md` and `reviews/builder-review*.md`: the design against Rig's
  compiler and language, with probes built and run;
- `reviews/cold-read*.md`: two readers with no history, as users and as editors.

## How to read this

Date and time handling is hard in three ways, and a reviewer should press on all three:
- **Technical.** Calendar arithmetic does not round-trip (a month added and then taken
  away). Clock time has gaps and repeats. Ranges overflow.
- **The data is fuzzy.** The zone database changes several times a year, and governments
  change rules at short notice.
- **Many answers are judgment.** What "one month after Jan 31" is, or whether two values
  of the same instant in different zones are equal.

A rule carries a tag where its origin matters. An untagged rule follows Jiff or is
forced by Rig.
- **[Owner]** the owner decided it.
- **[Jiff]** it follows Jiff 1.0.0, and "measured" means it was run against Jiff.
- **[Rig]** the language or compiler forces it.
- **[Judgment]** a reasonable designer could choose otherwise.

Nothing is open. One thing was measured before it was decided: the layout of
`Duration`, in phase 0 (5.1).

## Total or visible

**[Owner, 2026-11-22]** Every call in `std.time` and `std.datetime` is either **total**,
giving an answer for every value of its argument types, or returns `!`. No call panics
on any value.

- **Ranges are chosen to make calls total.** Where a call would fail only because a
  range is a little too small, the range is widened or bounded so that the call cannot
  fail, rather than given a `!`: `Duration` holds ±292 billion years (5.1), its range is
  symmetric so `neg()` and `abs()` cannot fail, and a `Monotonic` reading stays within
  146 years (5.7).
- **Nothing saturates.** A result that cannot be represented is a failure, never a
  value that is quietly wrong.
- **One name per operation.** `add` is the fallible sum; there is no `checked_add`
  beside it, and no saturating twin. A program that wants the end of the range asks for
  it by name: `d.add(days: n) catch datetime.Date.max()`.
- **Constant arguments are checked at compile time** and need no `!`:
  `Date.new(2026, 1, 31)` (10.6).
- **A test** finds no `panic(` in `std/time.rig` or `std/datetime/` (12).

The owner's words: "We cannot have normal code panicking. That is a hard crash. It
should only happen in extraordinary cases of system failure, not just some joker
entered a bad date."

Why every call that can fail returns `!`, and not only the ones that take text or parts:
- **The library cannot tell input from arithmetic.** A user's number becomes arithmetic
  one line later. The committee ran three programs, each on ordinary data, that a
  panicking `add` or `round` ends:
  - a user's 9999-12-31 plus a day;
  - a renewal period read from a file, in `start.add(months: period * k)`;
  - `Instant.parse("9999-12-30T22:00:00.9Z")!.round(seconds: 1)`.
- **Ordinary data sits on the ends of the range.** 9999-12-31 is the "no end" of SQL
  Server, Oracle and SAP; 0001-01-01 is .NET's `DateTime.MinValue` and Go's zero time.
  An `Int` overflows only on extreme input; a date's range is reached by a sentinel
  plus a day.
- **Jiff's named methods return `Result`:** `checked_add`, `round`, `start_of_day`,
  `tomorrow`, `Timestamp::from_second`. Only its `+` and `-` operators panic, and
  Rig's datetime types have no operators (5.6), so Rig's `add` is Jiff's `checked_add`.
- **A panic ends a Rig process.** Temporal's `RangeError` and java.time's
  `DateTimeException` are caught by a request handler, and one request fails.
- **It is smaller:** one name per operation where the alternative needs about twenty
  `checked_` twins.

What a program writes:
- `!` passes a failure up; in a `sub main()!` it costs one character;
- `catch` handles it;
- `catch panic("why")` where the program truly cannot go on, a panic written in the
  program's own source;
- never a value fallback such as `d.add(days: n) ?? d`, which gives a wrong date
  without a word. The docs show `!`, `catch`, and the ends by name.

```rig
use std.datetime

fun renew(start: datetime.Date, months: Int) -> datetime.Date!
  start.add(months: months)!

sub main()!
  start = datetime.Date.new(2027, 1, 31)
  print(renew(start, 1)!)
  print(renew(start, 200_000) catch datetime.Date.max())
```

```output
2027-02-28
9999-12-31
```

The bar holds for the library's own calls. Rig's `Int` arithmetic, which a program
writes itself, still panics on overflow; whether the language should hold the same bar
is a question for later (`docs/IDEAS.md`). A failure that leaves `main` names where it
came from by an error trace (10.5).

---

# 1. Context

## 1.1 Rig, as far as it shapes this design

Rig is an indentation-sensitive language that compiles to Zig 0.17.0.

- **The North Star:**
  1. Accept means correct: a program the compiler accepts must not fail in Zig.
  2. Safe code cannot corrupt memory.
  3. Effects stay visible: no hidden allocation or reference counting.
  4. One classifier per fact.
  5. Ownership features fit the Core.
  6. Docs claim only what runs: doc examples are tests.
- **Value kinds:** *plain* data copies like an `Int`; *owning* values hold a resource and
  move. Every type here is plain. A `String` owns heap bytes, so a function that returns
  one allocates, visibly.
- **Text:** `print(x)` writes a value's text and allocates nothing. `String(x)` gives the
  same text as a `String`.
- **Errors:** a fallible function returns `T!` and the caller writes `f()!`, or handles
  it with `catch`. `!` on a call that cannot fail is rejected. A panic is a bug in the
  program, and ends it. `Int` overflow panics, in debug and release builds; no call in
  this design panics ("Total or visible").
- **Language rules that decide spellings** (each verified by building Rig and running a
  probe; `reviews/builder-review*.md`):
  - An object is made by naming its fields, and a constructor cannot fail. A type with
    private fields is made by a static function: `Date.new(…)!`, or `Date.new(…)` when
    every argument is a constant (10.6).
  - A type has no constants, and a module constant cannot be an object. So it is
    `TimeZone.utc()`, and a program's own constant holds a number (`TIMEOUT_S = 30`).
  - A method is always called with parentheses: `d.year()`.
  - A parameter with a default is an option, given by name (SPEC "Functions"), so a
    positional argument never reaches one.
  - Two modules may not import each other, and a method is declared in the module that
    declares its type.
  - `when` is a reserved word. `in`, `with`, `add`, `sub`, `round` and `format` may all
    name methods.
  - A parameter default is a literal or a constant; an optional parameter is
    `x: T? = none`.
  - No local or parameter may reuse the name of an imported module, so with
    `use std.time` nothing else is called `time`. (That is why the module is
    `std.datetime` and not `std.date`.)
  - Arithmetic operators belong to built-in numbers only, and none of this design's
    types has one (5.6). Comparison comes from the `Eq`, `Ord` and `Hash` APIs, which
    any type may have.
  - `I128` is a built-in integer, and prints as an `Int` does.
  - `/` truncates toward zero. There is no floor division; the calendar code writes one.
- **std** is embedded in the compiler; a user's build has no std directory on disk.
  - A std module's Zig helpers ("shims") are written beside the generated program, with
    any Zig file a shim imports.
  - Std carries data as generated Zig tables (`char_tables.zig`, `width_tables.zig`).
    `$embed` is refused inside std.
  - A shim function returns numbers, static text, static slices and several results. It
    cannot return a Rig object.
- **Doc examples:** a `rig` block with an `output` block is built and run. A `rig` block
  alone is only checked. A `rig pending` block passes while its feature is unbuilt.

## 1.2 Today's `std.time`, which this replaces

```
type Duration = Int                  # private; nanoseconds
pub NS US MS SECOND MINUTE           # constants, counts of ns
pub obj Instant: Ord                 # a MONOTONIC reading; one field, ns: Int
  at(ns: Duration), add(ns: Duration), since(earlier) -> Int, elapsed() -> Int
pub fun now() -> Instant             # monotonic
pub fun within[R](ns: Duration, f) -> R!
extern: since_start() -> Int, unix_ns() -> Int, sleep(ns: Duration)!
time.after(…)                        # a select arm, typed by hand in the compiler
```

- A duration argument is a bare number of seconds or one keyword (`ms:`, `us:`, `ns:`).
- The compiler finds duration parameters by the parameter's **name** (`ns`) and the
  type's **text** (`Duration`), inside `std.time` only.

## 1.3 Jiff, and the guiding rule

[Jiff 1.0.0](https://github.com/BurntSushi/jiff) (tag `1.0.0`, commit `3b1bdf9`,
2026-11-15, MIT or Unlicense) mostly follows TC39 Temporal.

- **Jiff's answers.** Wherever reasonable designers disagree about behavior, Rig does
  what Jiff does, unless section 9 lists a deviation.
- **Rig's surface.** Rig does not copy Jiff's 93 public types, its 10-field `Span`, its
  26 builder types (keyword arguments replace them), or its reference-counted zones.
- **Size.** Jiff is about 119,000 lines, most of them tests and docs. The target is
  about 5,000 lines of Rig plus 2,000 to 3,000 of tests.
- **License.** A port is allowed. Ported files keep the MIT notice.
- A clone is at `~/Data/Code/rig/misc/jiff`.

---

# 2. The surface at a glance

Spellings marked "(spelling)" in section 4 onward are the builder's to settle. The rest
is decided.

```
use std.time
use std.datetime

sub main()!
  # Timing, on the monotonic clock
  start = time.monotonic()
  time.sleep(ms: 20)!
  print(start.elapsed())                           # 20ms 113us 482ns
  print(start.elapsed() < time.duration(ms: 50))   # true

  # Durations
  d = time.duration(minutes: 90)
  print(d.hours())                                 # 1
  print(d)                                         # 1h 30m

  # Now, in a zone (a literal name is checked at compile time: no !)
  denver = datetime.TimeZone.named("America/Denver")
  z = datetime.now().in_zone(denver)
  print(z)               # 2026-11-17T08:07:03.512094-07:00[America/Denver]
  print(z.date(), z.weekday())                     # 2026-11-17 Tuesday

  # A day later on the clock, and exactly 24 hours later (fail past 9999)
  print(z.add(days: 1)!)
  print(z.add(hours: 24)!)

  # Calendar math
  due = datetime.Date.new(2027, 1, 31).add(months: 1)!    # 2027-02-28
  print(due.days_since(z.date()))                  # 103

  # A time with no zone, placed in one
  dt = datetime.DateTime.parse("2026-03-08T02:30")!       # skipped in Denver
  print(dt.in_zone(denver)!)       # 2026-03-08T03:30:00-06:00[America/Denver]

  # Text
  launch = datetime.ZonedDateTime.parse("2027-01-01T00:00:00+00:00[UTC]")!
  print(launch.since(z).hours())
  print(z.format("%A, %B %-d, %Y"))                # Tuesday, November 17, 2026
```

| Type | Make one | Read it | Change it | Compare and count |
|---|---|---|---|---|
| `time.Duration` | a duration form (5.2); `time.duration(…)`; `Duration.parse(s)!`; `Duration.from_parts(s, ns)!`; `min()` `max()` | `hours()` `minutes()` `seconds()`, and `ms()` `us()` `ns()` as `I128`; `float_seconds()`, `subsec_ns()`, `iso()` | `add(…)!` `sub(…)!` `times(n)!` `div(n)!` `round(…)!` `floor(…)!`, `neg()` `abs()` | `Eq` `Ord` `Hash` |
| `time.Monotonic` | `time.monotonic()`; `Monotonic.at(…)!` | `elapsed()` | `add(…)!` | `since`; `Eq` `Ord` `Hash` |
| `datetime.Instant` | `datetime.now()`; `Instant.from_unix_s(s, ns:)!` `from_unix_ms(ms)!` `from_unix_us(us)!` `from_unix_ns(ns)` `from_unix_float(s)!`; `Instant.parse(s)!`; `min()` `max()` | `unix()` `unix_s()` `unix_ms()` `unix_us()` | `add(…)!` `round(…)!` `floor(…)!` `in_zone(tz)` | `since`; `Eq` `Ord` `Hash` |
| `datetime.Date` | `Date.new(y, m, d)!`; `Date.parse(s)!`; `datetime.today(tz)`; `min()` `max()` | `year()` `month()` `day()` `weekday()` `day_of_year()` `days_in_month()` `iso_week()` `iso_week_year()` | `add(…)!` `with(…)!` `at(t)` `in_zone(tz)!` `first_of_month()` `last_of_month()` `nth_weekday(n, w)!` `nth_weekday_of_month(n, w)!` | the counts (6.4); `Eq` `Ord` `Hash` |
| `datetime.Time` | `Time.new(h, m, s, ns)!`; `Time.parse(s)!`; `min()` `max()` | `hour()` `minute()` `second()` `nanosecond()` | `add(…)` (wraps) `with(…)!` `round(…)` (wraps) `floor(…)` | `since`; `Eq` `Ord` `Hash` |
| `datetime.DateTime` | `DateTime.new(y, m, d, h, mi, s, ns)!`; `date.at(t)`; `DateTime.parse(s)!`; `min()` `max()` | `date()` `time()`, and the readers of both | `add(…)!` `with(…)!` `round(…)!` `floor(…)!` `in_zone(tz, …)!` | `since`; the counts; `Eq` `Ord` `Hash` |
| `datetime.TimeZone` | `named(s)!` `fixed(hours:, minutes:)!` `utc()` `parse(s)!`; `datetime.local()!` | `name()` `offset_at(i)` | | `Eq` `Hash` |
| `datetime.ZonedDateTime` | `i.in_zone(tz)`; `dt.in_zone(tz, …)!`; `ZonedDateTime.parse(s, …)!` | `instant()` `datetime()` `date()` `time()` `zone()` `offset()` `offset_text()`, and the readers of a date and a time | `add(…)!` `with(…)!` `in_zone(tz)` `start_of_day()!` `round(…)!` `floor(…)!` | `since`; the counts; by instant: `Eq` `Ord` `Hash` |
| `datetime.Weekday` | `.monday` … `.sunday` | `iso_number()` | | `Eq` `Ord` `Hash` |

`format("…")` and `try_format(s)!` are on `Date`, `Time`, `DateTime` and `ZonedDateTime`
(8.4). The makers of 10.6, shown here with `!`, take none when every argument is a
constant. Every call shown without `!` is total (7.2).

What the smaller members give:
- Every reader returns an `Int`: `year()`, `month()` (1 to 12), `day()`, `hour()`,
  `minute()`, `second()`, `nanosecond()`, `day_of_year()` (1 to 366), `days_in_month()`,
  `iso_week()`, `iso_week_year()`.
  - `nanosecond()` is the whole part below a second, 0 to 999,999,999, and `with(ns:)`
    sets all of it. (Jiff's method of that name is only the last three digits; this is
    its `subsec_nanosecond`.)
- `weekday()` returns a `Weekday`, compared as `d.weekday() == .monday`.
- `d.at(t) -> DateTime` joins a date and a time of day. `dt.date()` and `dt.time()` take
  them apart.
- `z.instant()`, `z.datetime()`, `z.date()`, `z.time()` and `z.zone()` give a zoned
  value's parts.
- **`in_zone` has two meanings, by what it is called on:**
  - on an `Instant` or a `ZonedDateTime` it keeps the instant and shows it in `tz`;
  - on a `DateTime` or a `Date` it keeps the reading on the clock and finds the
    instant, which can fail (6.5, 6.7).
- `since` and the counts take a value of the receiver's own type.

---

# 3. Modules

**[Owner]** Two modules, and `std.datetime` imports `std.time`, never the reverse.

| Module | Holds |
|---|---|
| `std.time` | the monotonic clock and waiting: `Duration`, `Monotonic`, `monotonic()`, `since_start()`, `duration(…)`, `sleep`, `within`, `after` |
| `std.datetime` | the calendar and the wall clock: `Instant`, `now()`, `Date`, `Time`, `DateTime`, `ZonedDateTime`, `TimeZone`, `Weekday`, `today(tz)`, `local()`, `zone_names()`, `tzdb_version()` |

- **`time.now()` is removed.** Today it reads the monotonic clock. A call is a compile
  error whose fix names both replacements: `time.monotonic()` for timing and
  `datetime.now()` for the date and time. Nothing that compiled before silently changes
  clocks.
- `time.unix_ns()` is removed, with the fix `datetime.now().unix().ns()`, an `I128`
  (`Int(…)` of it where an `Int` is wanted: the wall clock reads within 1677 to 2262,
  7.8). **[Rig]** It
  stays until `datetime.now()` exists (section 11, phase 3), so that there is always a
  wall clock and every gate stays green.
- A program that only sleeps or times does not load the calendar code.
- Why not `Instant` in `std.time`: its `in_zone` returns a `std.datetime` type, and its
  printing needs the calendar math, so the two modules would import each other.

---

# 4. Types and names

## 4.1 Nine types, and two sets of options

| Type | Meaning | Jiff |
|---|---|---|
| `time.Duration` | An exact, signed length of time. | `SignedDuration` |
| `time.Monotonic` | A reading of the monotonic clock. | (Rust's `std::time::Instant`) |
| `datetime.Instant` | An exact point on the shared timeline, in UTC. | `Timestamp` |
| `datetime.Date` | A day on the calendar. | `civil::Date` |
| `datetime.Time` | A time of day on the clock face. | `civil::Time` |
| `datetime.DateTime` | A date and a time of day, with **no zone**. | `civil::DateTime` |
| `datetime.ZonedDateTime` | An instant in a time zone. | `ZonedDateTime` |
| `datetime.TimeZone` | A named zone from the embedded data, or a fixed offset. | `TimeZone` |
| `datetime.Weekday` | `.monday` … `.sunday`, ordered from Monday. `iso_number()` gives Monday as 1. | `Weekday` |

- **Two small enums** name the choices of two keywords: how a skipped or repeated time
  is resolved (6.5), and what to do with a stored offset that no longer fits (8.3).
  They are `datetime.Resolve` and `datetime.Conflict`.
- **Not types:** a span or period (6.1), an offset (7.6), builders (keywords), a handle
  on the zone data (module functions), an ISO week date (methods).
- **[Owner] There is a zoneless `DateTime`.**
  - Zoneless data has no other single value: a Postgres `timestamp`, an Excel cell, an
    HTML `datetime-local`, an iCal floating time.
  - Once `DateTime` names the zoned type, the short name is gone for good.

## 4.2 Vocabulary

- **Use:** *instant* (an exact point), *duration* (an exact length), *date*, *time of
  day*, *time zone*, *monotonic clock*.
- **Never, as a word for one of these types:** "moment", "timestamp", "naive", "civil",
  "plain", "local", "span", "period".
- A clock time that does not exist is **skipped**, and one that happens twice is
  **repeated**. Not "ambiguous".
- **Three clocks, kept apart in the wording:**
  - the *monotonic clock* only measures elapsed time;
  - the *wall clock* is the system's idea of the current instant;
  - *on the clock* means a date and time of day as a clock in some zone shows it, and
    the *clock face* is a time of day with no date.

---

# 5. Durations and the monotonic clock (`std.time`)

## 5.1 Representation

**[Owner, 2026-11-22]** Jiff's layout: whole seconds in an `Int` and nanoseconds in an
`I32`, of one sign, in 16 bytes. Its range is ±292 billion years, and symmetric: the
whole seconds are within ±(2^63 − 1), never `Int.min`, and the nanoseconds within
±999,999,999.

- **Why 16 bytes.** Every difference this design takes then fits: `a.since(b)` for any
  two values of a type (20,000 years at most), `i.unix()` for any instant, and
  `m.since(earlier)` for two readings. So `since` and `unix()` are total, with no `!`
  and no saturation ("Total or visible").
- **What it costs.** Phase 0 measured both layouts call by call
  (`records/2026-11/datetime-phase0`): the 16 bytes cost about 1.9 ns more on
  `elapsed()` (beside a clock read of about 12.7 ns, and not explained), 0.3 ns on
  `since`, 0.1 ns on a deadline's `add`, and 0.1 to 0.3 ns on `sleep(0)`. `within` and
  `select` show no difference beyond noise.
- **The readers of the smaller units return `I128`** (5.3): nanoseconds over 292
  billion years do not fit an `Int`.
- **The scheduler still speaks an `Int` of nanoseconds** underneath `sleep`, `within`,
  `after` and `per:`. A wait longer than that waits as long as the scheduler can (5.8).
  A `Monotonic` reading stays one `Int` (5.7).
- **What can still fail:** `Duration`'s own arithmetic (`add`, `sub`, `times`, `div`,
  `round`, `floor`) returns `!`, failing `.range` past ±292 billion years and `.invalid`
  for `div(0)` (5.4). The calendar types' own arithmetic, `add(days:)`, `add(months:)`
  and the counts, never goes through a `Duration`.

## 5.2 Duration forms

Wherever a parameter is typed `Duration`, a call gives it in one of these forms.

- **[Owner]** A bare number is **seconds**, an `Int` or a `Float`: `sleep(90)`,
  `z.add(duration: 0.5)`. This holds on `add` for `DateTime`, `ZonedDateTime` and `Time`
  too, so `dt.add(duration: 1)` is one second, not a day; the owner considered requiring
  a unit there and kept bare seconds. On a `DateTime` the duration is an option, given
  by name or by a unit, `z.add(seconds: 0.5)`, so `dt.add(1)` is refused, and the docs
  for those `add`s show `add(days: 1)` beside it.
- A unit keyword: `ns:`, `us:`, `ms:`, `seconds:`, `minutes:`, `hours:`.
- **[Owner]** Several unit keywords add up, each unit at most once:
  `add(hours: 1, minutes: 30)`. Built as its own change after the rest (section 11,
  phase 1b; `records/2026-11/datetime-phase1b`).
  - Signs may differ, and the parts simply add: `hours: 1, minutes: -30` is 30 minutes.
  - An `Int` part is exact. A `Float` part is rounded to the nanosecond, half away from
    zero. Then the parts are added; a sum beyond the range fails, as below.
- A bare number together with a unit keyword is rejected.
- A value that is already a `Duration` passes as it is. `ms: d` with `d` a `Duration`
  is rejected.
- **No days or weeks.** `days:` or `weeks:` where a `Duration` is taken is a compile
  error. Its fix fits the place: `hours: 24` for a wait, `add(days:)` on a value with a
  date, and `i.in_zone(tz).add(days: 1)!` for an `Instant`. A day is not always 24 hours,
  and libraries that put 24-hour days on an exact length have shipped that bug: Java's
  `Duration.ofDays`, C#'s `TimeSpan.FromDays`, chrono's `Duration::days`. (The error
  fires only when the function called has no parameter of its own named `days`.)
- **A constant** that is not finite, or beyond the range, is a compile error.
- **[Owner, 2026-11-22] A number known only at run time** never panics. Which forms can
  fail at all follows from the range:
  - **Total:** one `Int` keyword of `ns:`, `us:` or `ms:`. Every `Int` of a unit below
    a second fits, so these are accepted everywhere, as a constant is.
  - **Can fail:** a `Float` (not finite, or beyond the range), a bare `Int` or an `Int`
    of `seconds:` (**[Judgment]** `Int.min` seconds is one past the symmetric range,
    which keeps `neg()` total; a bare `Int` is total but for that one value, and is
    treated as the forms that can fail rather than given a range of its own), an
    `Int` of `minutes:` or `hours:` (`Int.max` hours is past ±292 billion years), and
    several keywords summed.
  - Where one of these is given, the place decides:
    - **in a call that returns `!`** (a std call, or a program's function whose error
      set can hold the failure, 10.7), the conversion is folded into that call's own
      failure: `i.add(ms: t)!` has one `!`, which covers the conversion and the sum.
      It fails `.range` beyond the range and `.invalid` for a number that is not
      finite; both of std's error sets have those members (10.3);
    - **in a wait** (`sleep`, `within`, `after`, `per:`), an `Int` beyond the range waits
      as long as the scheduler can and a negative one counts as zero (5.8). A `Float`
      is refused, with the fix `time.duration(x)!`;
    - **anywhere else**, it is a compile error whose fix makes the conversion visible:
      `time.duration(minutes: n)!`, then the `Duration` passed as it is.
- **`time.duration(<form>)`** makes a standalone value: `time.duration(ms: 250)`,
  `time.duration(5)`. It returns a `Duration` for a form that cannot fail, constants
  among them (10.6), and a `Duration!` for a form that can: `time.duration(x)!` for a
  `Float` read from a file.
  - Without the constant-argument rule of 10.6, `time.duration` would take the forms
    that cannot fail only, and `time.checked_duration(<form>) -> Duration!` the rest.
- **Removed:** the constants `time.NS`, `US`, `MS`, `SECOND` and `MINUTE`.

**Rules for a function that declares a `Duration` parameter** [Rig]:
- Unit keywords fill the `Duration` parameter when the function has exactly one. With
  two or more, each is given by its own name.
- A `Duration` parameter may always be given by its own name, with a bare number of
  seconds or a `Duration` value: `time.sleep(d: 5)!`.
- No parameter of a function with a `Duration` parameter is named `ns`, `us`, `ms`,
  `seconds`, `minutes` or `hours`, the `Duration` parameter included. (Today's are all
  named `ns`; they become `d`.)
- An optional one is written `d: Duration? = none`, and `none` or an optional value
  passes as it is.
- A bare number is positional, so a `Duration` parameter that takes one comes first:
  `time.within(0.5, f)!`. After a keyword, Rig lets only a closure literal follow by
  position, so with a unit it is `time.within(ms: 500, f: f)!` or
  `time.within(ms: 500, || f()!)!`.
- The forms apply where the call names the function or method, which includes a method
  called through an API. Through a function value there are no parameter names, so the
  caller passes a `Duration` value.

## 5.3 Reading a duration

- **Totals only**, truncated toward zero, and all total. **[Owner, 2026-11-22]**
  - `hours()`, `minutes()` and `seconds()` return an `Int`; `seconds()` is the whole
    seconds the value holds.
  - `ms()`, `us()` and `ns()` return an `I128`, exact: 292 billion years of
    nanoseconds do not fit an `Int`. `ns()` of any `Duration` is exact.
  - -1.5 seconds has `seconds()` of -1, not -2.

```rig
use std.time

sub main()
  d = time.duration(seconds: 9_300_000_000)
  print(d.seconds(), d.ns())
  print(time.Duration.max())
```

```output
9300000000 9300000000000000000
2562047788015215h 30m 7s 999ms 999us 999ns
```

- `float_seconds() -> Float` (spelling).
- **No "parts" accessors**, with the one low-level exception in 5.4. C#'s `.Minutes` and
  Python's `.seconds` are a known trap:
  `timedelta(days=1, seconds=5).seconds` is 5.

## 5.4 Arithmetic

**[Owner, 2026-11-22]** One name each, and every one that can leave the range returns
`!`:

- `add(d)!`, `sub(d)!`, `times(n: Int)!`: fail `.range` past ±292 billion years.
- `div(n: Int)!`, truncating toward zero: fails `.invalid` for 0, and only then (the
  range is symmetric, so dividing the largest value by -1 fits).
- `neg()` and `abs()`: total, since the range is symmetric.
- `round(…)!` and `floor(…)!` are in 6.8.
- `Duration.min()` and `Duration.max()`: the ends of the range, total.
- A total kept over a loop is `total = total.add(d)!`, and a mean `total.div(n)!`,
  which fails for an empty list where it would otherwise divide by zero.
- **[Owner] Two low-level members**, because `std.datetime` is another module and
  cannot see the fields (spelling; they are named so that nobody takes one for a
  total):
  - `d.subsec_ns()`: the part below a whole second, with the duration's sign, an `Int`;
  - `Duration.from_parts(seconds, ns)!`: the two must agree in sign and `ns` must be
    within ±999,999,999, or it fails `.invalid`. **[Owner, 2026-11-22]** It is the
    representation itself, so it fails on nothing else, but `Int.min` seconds, past the
    symmetric range, which fails `.range` as that number of seconds does as a duration
    form.

## 5.5 Text

- **[Owner]** `print` shows the friendly form, and `d.iso()` gives ISO 8601.

  | Duration | `print` | `d.iso()` |
  |---|---|---|
  | 2 h 30 min | `2h 30m` | `PT2H30M` |
  | 1,234,567 ns | `1ms 234us 567ns` | `PT0.001234567S` |
  | -1.5 s | `-1s 500ms` | `-PT1.5S` |
  | zero | `0s` | `PT0S` |
  | 400 days | `9600h` | `PT9600H` |

  - Jiff prints ISO by default and the friendly form on request. Its friendly form
    writes `1s 500ms ago` and `µs`; Rig writes a leading `-` and `us`.
- `Duration.parse(s)!` accepts ISO 8601 and all of Jiff's friendly grammar (measured):
  - accepted: `1.5h`, `1h30m`, `1 hour, 30 minutes`, `01:30:00`, `2h 30m ago`,
    `1h 90m`, `1500ms`, `+1h`, `PT1.5H`, `µs` as well as `us`, and a leading `-` for
    the whole duration;
  - rejected: `1h -30m`, `30m 1h`, `1h 1h`, `PT-1H`, a unit of a day or more (`P1D`,
    `1 day`), and a number with no unit (`90`).

## 5.6 Operators

**[Owner, 2026-11-22]** None. `Duration` has no `+`, `-`, `*` or `/`.

- `a + b` on two durations can overflow, and an operator cannot carry a `!`, so an
  operator would be the one panic left in the library, and a duration a user gave
  could reach it (`Duration.parse(s)!` and then `+`).
- Nothing in this design needs them: timing is `start.elapsed()`, comparison comes from
  `Ord`, and totals and means are `total = total.add(d)!` and `total.div(n)!`.
- Operators on plain objects in general are an idea of their own (`docs/IDEAS.md`).

## 5.7 The monotonic clock

**[Owner]** `time.monotonic() -> Monotonic` reads the monotonic clock, which never goes
back. It is today's `Instant`, renamed, and giving durations.

- **[Owner, 2026-11-22] A reading is never negative, and stays within 146 years**
  (2^62 nanoseconds) of the clock's zero. The system's monotonic clock counts from
  boot, nowhere near that. The difference of two readings is then one `Int`
  subtraction that cannot overflow, so `since` and `elapsed()` are total.
- `m.elapsed() -> Duration`: from the reading to now. Total.
- `m.since(earlier) -> Duration`: between two readings; negative when `earlier` is the
  later one. Total.
- `m.add(<duration form>) -> Monotonic!`: a deadline. `rekey = start.add(120)!`, and
  later `time.monotonic() >= rekey`. It fails `.range` when the result is negative or
  past 146 years.
- `Monotonic.at(<duration form>) -> Monotonic!`: a reading a duration after the clock's
  zero, for a test or for code that is handed the time. It fails as `add` does.
- `Eq`, `Ord` and `Hash`. It is one `Int` of nanoseconds and passes as a word. What
  `print` shows is not meaningful.
- `time.since_start() -> Duration`: the time since the program started. Total.
- Under the deterministic scheduler all of these are virtual.
- A `Monotonic` and an `Instant` are different types in different modules, so the two
  clocks cannot be mixed.

## 5.8 Waiting

- `time.sleep(d)!`, `time.within(d, f)!` and the `time.after(d)` select arm take a
  duration form.
- **[Owner]** A negative constant given to one of these is a compile error. A negative
  value at run time counts as zero: `sleep` returns at once, as it does today, and a
  `within` or `after` is already due.
- **[Owner, 2026-11-22]** A wait never fails on its duration: one longer than an `Int` of
  nanoseconds waits as long as the scheduler can, and a negative one is zero. These are
  the right answers for a wait, not values made up. A `Float` known only at run time is
  refused at compile time, with the fix `time.duration(x)!`, so a number that is not
  finite never reaches a wait (5.2).
- `per:` (a restart window on `task.supervise` and `Actor.supervised`) is an option,
  not a `Duration` parameter in the sense of 5.2: it is given by its own name, with a
  bare number of seconds or a `Duration` value:
  `per: 0.5`, `per: time.duration(ms: 500)`. A negative constant is a compile error; its
  run-time behavior does not change.
- The compiler knows these four by name. A program's own function cannot ask for the
  check.
- **Nothing else about waiting changes.** `sleep` and `within` keep their errors
  (`task.Stop`), cancellation, nested deadlines (the earlier one holds) and `within`'s
  `f: once`. `after` stays an arm of a `select` only. `time.since_start` stays usable as
  a function value.

---

# 6. Calendar arithmetic (`std.datetime`)

## 6.1 No span type

**[Judgment]** Calendar amounts are keywords, and calendar differences are `Int`
counts.

- `z.add(days: 1)!`, `d.add(months: 1, days: 3)!`, `d.days_since(other)`.
- Jiff and Temporal have a span that mixes units (`P1Y2M3DT4H`). Jiff argues for it
  (`DESIGN.md:264-345`): it round-trips ISO 8601 durations with calendar units, and it
  can be rebalanced against a date.
- **What Rig gives up:**
  - parsing `P1Y2M` or `P3D` into a value (they are rejected, 5.5);
  - "2 years 3 months 4 days between these" as one call (it is three counts, 6.4);
  - rounding a mixed amount.
- **What Rig gains:** no 10-field type, and no question of whether `1h 30m` equals
  `90m`.

## 6.2 Adding calendar amounts

**[Jiff]** except where marked.

- **The signatures** **[Owner, 2026-11-22]** (each but `Time`'s returns `!`):
  - `Date`: `add(years: 0, months: 0, weeks: 0, days: 0) -> Date!`, by keyword only.
  - `DateTime` and `ZonedDateTime`: `add(duration: Duration? = none, years: 0,
    months: 0, weeks: 0, days: 0)`, returning `DateTime!` and `ZonedDateTime!`. Each is
    an option, given by name, so `z.add(seconds: 0.5)!` or `z.add(duration: 0.5)!` is
    half a second, `z.add(hours: 2)!` is two hours, and `z.add(days: 1, hours: 2)!` is
    both.
  - `Instant` and `Monotonic`: `add(d: Duration)`, returning `Instant!` and
    `Monotonic!`.
  - `Time`: `add(d: Duration) -> Time`, total: it wraps (below).
  - The calendar keywords take an `Int`.
- **Order, in three groups:**
  1. years and months, added together as months, and then the day is clamped to the
     month's end;
  2. weeks and days;
  3. the exact duration.
  - Jan 31 + 1 month is Feb 28, or Feb 29 in a leap year. Mar 31 + 1 month is Apr 30.
    Feb 29 + 1 year is Feb 28.
  - Jan 31 + 1 month + 1 day is Mar 1 (clamp, then days).
  - **[Judgment]** 2024-02-29 with `years: 1, months: -12` is 2024-02-29: the two
    cancel before the clamp.
- **Amounts may be negative.** `d.add(months: -1)!`; Mar 31 - 1 month is Feb 28 or 29.
  None of these types has a `sub`; only `Duration` does.
- **[Judgment] Signs may differ between the groups**, each applied in order with its own
  sign: from the 1st of a month, `d.add(months: 1, days: -1)!` is that month's last day,
  and `z.add(days: 1, hours: -1)!` is an hour short of the same time tomorrow. Jiff
  cannot answer this: its span has one sign for all units.
- **Recurrences anchor to the start:** the k-th is `start.add(months: k)!`. Stepping
  from the previous result drifts (Jan 31, Feb 28, Mar 28).
- **[Owner, 2026-11-22]** `add` fails `.range` when the result of any of the three
  groups leaves the type's range (7.2). That includes amounts too large to sum:
  `d.add(years: n)!` fails for an `n` whose months overflow an `Int`, and never panics.
  A duration form with a run-time number fails inside the same `!` (5.2).
- **On a `Date`:**
  - `d.add(1)` is a compile error: each amount is an option, given by name.
  - `d.add(hours: 1)` is a compile error that says a date has no time of day. (Jiff
    accepts it and adds the whole days.)
- **On a `DateTime`:** every day is 24 hours, since there is no zone.
- **On a `Time`:** `add` **wraps past midnight**: 23:00 + 2 hours is 01:00. It is the
  sum on the clock face, exact modulo a day for any `Duration`, so it cannot fail.
  **[Owner, 2026-11-22]** There is no `checked_add` that fails on a wrap: a sum that
  must not pass midnight is taken on a `DateTime`, whose date shows whether it did.

## 6.3 Adding to a `ZonedDateTime`

**[Jiff]** (`zoned.rs:2339-2372`)

1. Add years and months, then weeks and days, to the date and time **on the clock**.
2. Turn that into an instant once, by the "compatible" rule (6.5).
3. Add the exact duration **on the timeline**.

- When the months (years × 12 + months) and the days (weeks × 7 + days) both come to
  zero, steps 1 and 2 are skipped and the value's instant is used as it is. (Otherwise
  `z.add(days: 0)`, or `z.add(weeks: 1, days: -7)`, on the second of a repeated time
  would move it back an hour.)
- `z.add(days: 1)!` lands at the same time on the clock, or just after a skipped one.
  `z.add(hours: 24)!` is exactly 24 hours. On a 23-hour day they differ by an hour.
- A repeated time does not survive a round trip (measured): the second 01:30, plus a
  day, minus a day, is the first 01:30.

## 6.4 Counts

`days_since`, `weeks_since`, `months_since` and `years_since`, on `Date`, `DateTime` and
`ZonedDateTime`. Each returns an `Int`.

**[Owner] A count walks forward from the earlier value.** `a.days_since(b)` is positive
when `a` is later and negative when it is earlier, and
`a.days_since(b) == -b.days_since(a)` always.

**[Jiff] The count itself is Jiff's `earlier.until(later)`.** These rules were measured
to equal it, with no exception, over 83 million pairs of values in every zone
(`reviews/independent-review-3.md`):

- **Days:** the largest `n` for which `earlier.add(days: n)` is not after the later
  value, and never more than the days from the earlier value's date to the later
  value's date, or 0 when the later date is not after it. (The limit matters only where
  a repeated time crosses midnight.)
- **Weeks:** days / 7.
- **Months, for two dates:** the difference in calendar months, less one when the later
  date's day of the month is smaller than the earlier date's.
- **Months, with a time of day:** count the whole days first; then apply the date rule
  to the earlier value's date and that date plus those days.
- **Years:** months / 12.

Consequences the docs state:
- **Month ends.** Jan 31 to Feb 28 is 0 months and 28 days, although Jan 31 + 1 month
  is Feb 28. Java and Postgres give the same 0.
- **Birthdays.** Someone born on Feb 29 turns a year older on Mar 1 in a common year
  (measured: `years_since` is 0 on Feb 28 and 1 on Mar 1).
- **Which period of a recurrence a date is in.** The periods start at
  `start.add(months: k)` (6.2), so on a clamped month end the count is one short: from
  a start of 2027-01-31, the second period begins on 02-28, but
  `months_since` is still 0 that day. The index is:

  ```
  k = today.months_since(start)
  if start.add(months: k + 1)! <= today
    k = k + 1
  ```

  The same holds for `years_since` and a start on Feb 29.
- **Days are counted on the clock.** Across a repeated hour, 2024-11-03T01:50-04:00 to
  2024-11-04T01:00-05:00 in New York is 24 hours 10 minutes, and 0 days.

**[Owner] Two zones.** The later value is first converted to the earlier value's zone,
so the count is taken on the earlier value's calendar. Jiff refuses such a count at
run time.
- Which calendar matters (measured): noon on 2026-03-07 to noon on 03-08 in New York is
  23 hours, 1 day on New York's calendar and 0 days on UTC's.
- So as one value moves past a fixed one, the calendar in use changes from its own to
  the other's. `in_zone` first chooses a calendar outright.

**Whole units and what is left over.** Step from the earlier value, whichever it is,
and put a sign on the result at the end:

```
early = start
late = launch
if launch < start
  early = launch
  late = start

n = late.days_since(early)                 # never negative
rest = late.since(early.add(days: n)!)     # never negative
```

For years, months and days as well, go on from `n`, and split the two **dates**:

```
d0 = early.date()
d1 = d0.add(days: n)!
m = d1.months_since(d0)
years = m / 12
months = m % 12
days = d1.days_since(d0.add(months: m)!)
```

- This is measured to equal Jiff's years, months, days and rest in every case run
  (872,115 pairs across five zones, and all dates). For two `Date`s, `d0` and `d1` are
  the dates themselves.
- `n` and `rest` are measured to be non-negative in every zone. Stepping from the later
  value can give "2 days and minus 15 minutes".
- Two shorter ways give other answers: counting months on the zoned values themselves
  differs where a time is skipped, and counting years, then months from there, then
  days differs when the earlier date is Feb 29.
- On a 25-hour day `rest` can reach 24 hours or more.
- Never divide `hours()` by 24.

## 6.5 Skipped and repeated times

**[Jiff]**

- **The "compatible" rule** (also Temporal's and RFC 5545's): a skipped time moves
  forward by the length of the gap (02:30 becomes 03:30), and a repeated time takes the
  earlier of the two.
- **A keyword chooses otherwise.** It is called `resolve:` here, and its values are an
  enum's: `.compatible` (the default), `.earlier`, `.later` and `.reject` (spelling;
  `when` is reserved). `dt.in_zone(tz, resolve: .reject)!` fails for a skipped or
  repeated time.
  - For a repeated time, `.earlier` and `.later` are the first and the second.
  - For a skipped time they are the gap's length before and after: Denver's 02:30 on
    2026-03-08 is 01:30-07:00 with `.earlier` and 03:30-06:00 with `.later` (measured).
- It is accepted where a date and time become an instant:
  `dt.in_zone(tz, resolve: …)!`, `z.with(…, resolve: …)!` and
  `ZonedDateTime.parse(s, resolve: …)!`.
- `dt.in_zone(tz)!` with the default can fail only at the end of the range.
- **`with`, and `round` or `floor` to a unit smaller than a day, first keep the value's
  own offset.** Only when that offset is not valid for the new time on the clock does
  the rule decide: the keyword's for `with`, "compatible" for the other two. Measured:
  the second 01:30 in Denver on 2026-11-01 (-07:00), with the minute set to 45, is
  01:45-07:00, where "compatible" alone would give 01:45-06:00.
- **`start_of_day`, `d.in_zone(tz)!`, and `round` or `floor` to `days: 1` do not keep
  the offset.** They work from the starts of days (6.7).
- **Keeping the offset can move a rounded time by more than the increment** [Jiff]: the
  first 01:50 in Denver on 2026-11-01 (-06:00) with `round(minutes: 30)` is
  02:00-07:00, 70 minutes later, because 02:00 has only the later offset.
- **`add` takes no such keyword** and always uses "compatible".
- **Gaps and repeats are found by comparing offsets**, never by the data's
  daylight-saving flag. The standard form of the zone data flags Dublin and Morocco the
  other way round: Dublin's winter, and Morocco's Ramadan, are the flagged part.

## 6.6 `since`, equality and order

- **[Owner, 2026-11-22]** `a.since(b) -> Duration` is exact and total for any two
  values: a `Duration` holds the 20,000 years between the ends of the range (5.1). It
  is defined on `Instant`, `DateTime`, `ZonedDateTime` and `Monotonic`. For two
  `ZonedDateTime`s the zones may differ. For a `DateTime` every day is 24 hours.
- A `Date` has no `since`, only the counts.
- `Time.since` is the difference on the clock face and can be negative: 01:00 since
  23:00 is -22 hours. A length of time that crosses midnight needs a date: use a
  `DateTime` or a `ZonedDateTime`.
- **[Owner] A `ZonedDateTime` compares, orders and hashes by its instant alone.** Noon
  in New York and 18:00 in Paris of the same instant are equal, and one key in a map.
  `a.zone() == b.zone()` tests the zone. (Jiff does the same; Temporal also compares
  the zone.)

## 6.7 `with`, the start of a day, and small helpers

**[Jiff]** except where marked.

- **`with(…)!`** replaces fields by keyword and fails when the result is not a real
  value (`Date.new(2024, 2, 29).with(year: 2023)` fails):
  - `Date`: `year:`, `month:`, `day:`;
  - `Time`: `hour:`, `minute:`, `second:`, `ns:`;
  - `DateTime` and `ZonedDateTime`: all of those.
  - A positional argument is a compile error: each field is an option, given by name.
- **The start of a date `d` in a zone** is 00:00 on `d`, turned into an instant by
  "compatible". That is the first instant of the day, which is not always 00:00. In São
  Paulo on 2015-10-18 it is 01:00. In the Azores on 2026-10-25, when 00:00 to 00:59
  happens twice, it is the first 00:00.
  - One day in the data is an exception, as in Jiff: Toronto on 1919-03-31, where the
    clock went from 23:30 to 00:30. The start is 01:00, though 00:30 to 00:59 exist.
- **`z.start_of_day()!`** is the start of `z`'s own date.
  - **[Owner, 2026-11-22]** It fails `.range` at the very end of the range, as Jiff's
    does: on the first date a zone shows, the day's start can lie before the first
    instant (7.1).
- **[Owner] `d.in_zone(tz)!`** is the start of the date `d` in `tz`: the same thing,
  starting from a date.
  - It fails only when 00:00 on `d` at the zone's offset is outside the range of
    instants (7.1). For a named zone that is -9999-01-01 everywhere, -9999-01-02 in UTC
    and every zone east of -02:00, and 9999-12-31 in UTC and every zone west of +02:00.
    A fixed zone beyond ±22:00 also fails one date further in.
  - A date the zone skipped altogether does not fail. It gives the start of the next
    one: 2011-12-30 in Apia gives 2011-12-31T00:00.
- **A day's range** is from its start to the start of the next day, and the safe way
  goes through the date:

  ```
  d = z.date()
  from = d.in_zone(z.zone())!
  to = d.add(days: 1)!.in_zone(z.zone())!
  ```

  - On the last date, 9999-12-31, `add` fails; a program that stores it as "no end"
    tests for it first, `d == datetime.Date.max()`, or handles the failure.
  - These ranges cover the timeline with no gap and no overlap. Where a repeated time
    crosses midnight, a date comes back after the next has begun, so a value can lie
    outside its own date's range: St. John's each autumn from 1987 to 2010, after 00:01
    went back to 23:01.
  - Two shorter ways are wrong:
    - `z.add(days: 1)!.start_of_day()!` skips a day where a late-evening time is skipped
      the next day: in Nuuk, from 2026-03-27T23:30 it gives the 29th.
    - `z.start_of_day()!.add(days: 1)!` is an hour late on a day that did not start at
      midnight: Havana on 2026-03-08, Beirut, Cairo, Santiago.
- **`datetime.today(tz) -> Date`** is `datetime.now().in_zone(tz).date()`. Total.
- **[Owner, 2026-11-22] The ends of each range by name:** `min()` and `max()` on
  `Date`, `Time`, `DateTime`, `Instant` and `Duration`, each total, as Jiff's `MIN` and
  `MAX` (Rig's types have no constants, so they are functions). A program that wants
  to saturate does so on purpose, where it can be seen:
  `d.add(days: n) catch datetime.Date.max()`.
- **[Owner] Four helpers on a `Date`**, each Jiff's:
  - `d.first_of_month()` and `d.last_of_month()`;
  - `d.nth_weekday(n, w)!` counts from `d`: the `n`-th `w` after it, or before it when
    `n` is negative. `d.nth_weekday(1, .monday)!` is the next Monday, never `d` itself.
    It fails for `n` of 0 and for a result outside the range.
  - `d.nth_weekday_of_month(n, w)!` counts within `d`'s month, from its end when `n` is
    negative: the fourth Thursday of November is
    `Date.new(2026, 11, 1).nth_weekday_of_month(4, .thursday)!`, the 26th. `n` is 1 to
    5 or -1 to -5; it fails for any other `n` and when the month has no such day.
- **[Owner] `datetime.zone_names()`** gives all 598 names, old spellings included,
  as a static list of static text sorted by name, for a list a person picks from.

## 6.8 Rounding

**[Jiff]** except where marked.

- `round(…)` takes exactly one unit keyword and its increment, an `Int`:
  `round(minutes: 15)!`, `round(seconds: 1)!`. It is not a duration form, and a
  positional argument is a compile error.
- **[Owner, 2026-11-22]** `round` and `floor` return `!` on `Duration`, `Instant`,
  `DateTime` and `ZonedDateTime`, failing `.range` when the result leaves the range:
  9999-12-30T22:00:00.9Z rounded to the second is past the last instant. On a `Time`
  they are total.
- `datetime.now().round(seconds: 1)!` is how an instant prints without a fraction.
- **Which increments**, each from 1 to 1,000,000,000:

  | Type | Units | The increment |
  |---|---|---|
  | `Duration` | `ns:` to `hours:` | any |
  | `Instant` | `ns:` to `hours:` | must divide 24 hours |
  | `Time` | `ns:` to `hours:` | must divide the next larger unit and be smaller than it |
  | `DateTime`, `ZonedDateTime` | `ns:` to `hours:`, and `days: 1` | as for a `Time` |

- **[Owner, 2026-11-22] A bad increment:**
  - a constant one is a compile error;
  - a computed one fails `.invalid`, through the `!` the call already has: a calendar
    that snaps to a step the user chose (5, 10, 15 or 30 minutes) passes it as it is;
  - on a `Time`, whose `round` and `floor` are total, the increment must be a constant,
    and a computed one is a compile error. (A `Time` rounded by a computed step goes
    through a `DateTime`.)
- **Halves:** a `Duration` rounds a half away from zero (1.5 s to 2 s, -1.5 s to -2 s).
  The others round a half to the later value.
  - **[Owner]** That includes an `Instant` before 1970. Jiff rounds an instant's half
    away from 1970, so there one instant rounds differently as an `Instant` and as a
    `ZonedDateTime`.
- **To `days: 1` on a `ZonedDateTime`**, the multiples are the starts of days (6.7):
  - `floor(days: 1)` is the latest start of a day at or before the value. That is
    `start_of_day()` except on the two kinds of day in 6.7: in St. John's it is the
    next date's start, and in Toronto on 1919-03-31 at 00:45 it is the day before's.
    (Jiff's, measured.)
  - `round(days: 1)` chooses between that start and the first start of a day after
    the value, a half going to the later. So it uses the day's real length: noon on
    Denver's 23-hour day rounds down.
  - **[Judgment]** Jiff 1.0.0 measures to the start plus one day on the clock, which is
    not the next day's start when the day began at 01:00: in Havana on 2026-03-08,
    18:00 rounds to 01:00 on the 9th (measured). Rig gives 00:00 on the 9th. The oracle
    checks `round(days: 1)` only for a value inside its own date's range, on a day
    whose start plus one day on the clock is the next date's start.
- `Time.round` wraps: 23:59:59.6 rounds to 00:00:00. The others fail `.range` when the
  result leaves the range.
- **A round that passes midnight carries into the next day, in every year.** Jiff 1.0.0
  does not for years at or below 0 (`civil/datetime.rs:3582` and `3590` multiply the
  carried day by the sign of the year; measured: 23:30 in year 0 rounds to 00:00 of the
  same day). Rig does not copy that, and the oracle is not used for those cases.
- **[Owner] `floor(…)`** takes the same argument and goes to the multiple at or
  before the value: `z.floor(minutes: 15)!`, `i.floor(hours: 1)!`. For a `Duration`
  that is toward negative infinity. Truncating is the commoner need (Go's `Truncate`, Java's
  `truncatedTo`), and without it the only way is `with`, field by field. It is Jiff's
  floor mode, measured on every type.
  - **To a unit below a day, as in Jiff:** on a `ZonedDateTime`, "at or before" is on
    the clock.
    When the floored time is skipped it moves forward past the gap (6.5), and can then
    be later than the value: in Lord Howe, 02:35 on 2026-10-04 with
    `floor(minutes: 20)` is 02:50, because 02:00 to 02:30 does not exist. It happens
    only where a gap does not start and end on multiples of the increment.
- Other rounding modes are not in v1.

---

# 7. Values, ranges and zones

## 7.1 Calendar and ranges

**[Jiff]**

- The proleptic Gregorian calendar only. Year 0 exists and is 1 BCE, as in ISO 8601.
- `Date`: -9999-01-01 to 9999-12-31.
- `Instant`: -9999-01-02T01:59:59Z to 9999-12-30T22:00:00.999999999Z. It is narrower
  than the dates by 25:59:59 at each end, so that every instant has a date under every
  offset. In UTC the last instant is on 9999-12-30.
- Leap seconds: `:60` in text is read as `:59`. Otherwise they are ignored, as in Unix
  time.

## 7.2 What is total and what fails

**[Owner, 2026-11-22]** Every call is one or the other ("Total or visible"). **No call
panics**, on any value.

- **Total, with no `!`:**
  - every reader: `year()` to `nanosecond()`, `weekday()`, `iso_week()`, `date()`,
    `time()`, `zone()`, `offset()`, `offset_text()`, `name()`, and `Duration`'s
    totals (5.3);
  - the counts (6.4), comparison, `Eq`, `Ord` and `Hash`, and printing;
  - `since` on every type that has one (6.6), `Monotonic.elapsed()`,
    `time.since_start()`;
  - `Time.add`, `Time.round` and `Time.floor`, which wrap or stay within the day;
  - `Duration.neg()` and `abs()` (the range is symmetric);
  - `i.in_zone(tz)` and `z.in_zone(tz)`, `d.at(t)`, `first_of_month()`,
    `last_of_month()`, `tz.offset_at(i)`;
  - `Instant.from_unix_ns`, `unix()`, `unix_s()`, `unix_ms()`, `unix_us()` (7.8);
  - `datetime.now()`, `datetime.today(tz)`, `time.monotonic()`, `TimeZone.utc()`,
    `zone_names()`, `tzdb_version()`, `min()` and `max()`;
  - `format` with a string known at compile time (8.4), and `time.duration` of a form
    that cannot fail (5.2).
- **Fallible, `!`**, failing `.invalid` for a bad argument or text and `.range` for a
  result outside the range (and with the zone errors of 10.3):
  - **making a value from parts, text or a number:** `Date.new`, `Time.new`,
    `DateTime.new`, every `parse`, `with`, `dt.in_zone`, `d.in_zone`, `nth_weekday`,
    `nth_weekday_of_month`, `TimeZone.named`, `TimeZone.parse`, `TimeZone.fixed`,
    `datetime.local`, `try_format`, `Duration.from_parts`, `Monotonic.at`, and
    `Instant.from_unix_s`, `from_unix_ms`, `from_unix_us`, `from_unix_float`;
    - `Date.new(year, month, day)`.
    - `Time.new(hour, minute, second, ns = 0)`, so `Time.new(8, 7, 3, ns: 500)` says
      nanoseconds.
    - `DateTime.new(year, month, day, hour = 0, minute = 0, second = 0, ns = 0)`.
    - `Time.new(23, 59, 60)` fails; only parsing reads `:60` as `:59`.
  - **arithmetic that can leave the range:** `add` on `Date`; `add`, `round` and
    `floor` on `DateTime`, `Instant` and `ZonedDateTime`; `z.start_of_day()`;
    `Monotonic.add`; `Duration`'s `add`, `sub`, `times`, `div` (and `div(0)`),
    `round` and `floor`;
  - **a duration form given a number known only at run time** that can fail, folded
    into the call's own `!` (5.2);
  - **a computed `round` or `floor` increment** that is not allowed (6.8).
- **One name each.** There is no `checked_add`, `checked_sub` or `checked_times`: `add`
  is the fallible one, and the failure is handled where it is called.
- **Constant arguments** are checked at compile time, where a bad one is an error
  (10.2), and a maker called with constants alone takes no `!` (10.6):
  `Date.new(2026, 1, 31)`, `TimeZone.fixed(hours: 5, minutes: 30)`.
- **Nothing saturates.** `since` and `unix()` are exact for every value (5.1); there is
  no saturating arithmetic but the one a program writes with `min()` and `max()`.
- **What a program does with a failure:** `!` to pass it up, `catch` to handle it, or
  `catch panic("why")` where it truly cannot go on, which puts the panic in the
  program's own source. The docs never show `d.add(days: n) ?? d`: it gives a wrong date
  without a word.
- **The test.** No `panic(` appears in `std/time.rig` or `std/datetime/` (12).
  `datetime.now()` reads an `Int` of nanoseconds, which lies within the range of
  instants, so it is built with no fallback to panic in.

## 7.3 Sizes

Measured on a stand-in built with Rig.

| Type | Bytes |
|---|---|
| `Weekday` | 1 |
| `Date`, `TimeZone` | 4 |
| `Monotonic` | 8, and it passes as a word |
| `Time` | 8 |
| `DateTime` | 12 |
| `Duration` | 16: its whole seconds and its nanoseconds **[Owner, 2026-11-22]** |
| `Instant` | 16 |
| `ZonedDateTime` | 24: its instant, its zone and its offset in seconds |

- Except `Monotonic`, none passes as a word: a type with its own `Print` never does
  (`sema.zig:11304`). This design accepts that. Relaxing the rule is a separate
  compiler question, outside this work.

## 7.4 Time zones

**[Owner]** A `TimeZone` is plain data: an index into zone data compiled into the
program, or a fixed offset. It never allocates and has no reference count.

- **`TimeZone.named(s)!`**
  - Names match without regard to ASCII case.
  - An unknown name fails. Nothing falls back to UTC.
  - **A string literal that names no zone is a compile error**, with the nearest name
    as its fix, and a literal that names one needs no `!` (10.6):
    `TimeZone.named("America/Denver")`.
  - `named("UTC")`, in any case, returns `utc()` (Jiff does the same).
- **`TimeZone.fixed(hours:, minutes:)!`** **[Owner, 2026-11-22]**
  - **[Owner]** Whole minutes only. Offsets with seconds are all historic (measured
    over the 598 names in the data): none is in use today, and the last ended on
    1972-01-07 (Monrovia, -00:44:30). A fixed zone with seconds could not be written
    and read back, since RFC 9557 text rounds the offset to the minute. Named zones
    carry their historic seconds exactly.
  - Two `Int` keywords, each defaulting to 0. A positional argument is a compile error
    (10.2): `fixed(-7)` would otherwise read as hours without saying so.
  - **[Owner]** The two must agree in sign: -05:30 is `fixed(hours: -5, minutes: -30)`.
  - **[Judgment]** The offset is hours × 60 + minutes, within ±25:59, and minutes may
    pass 59: `fixed(minutes: 330)` is +05:30.
  - It does not take a `Duration`. To freeze a zoned value's offset as a zone:
    `TimeZone.parse(z.offset_text())!`, which fails for a historic offset with seconds.
  - Out of range, or mixed signs: a compile error for constants, which then need no
    `!` (10.6); otherwise it fails `.range` beyond ±25:59 and `.invalid` for mixed
    signs.
  - `fixed(hours: 0)` is `utc()`.
- **`TimeZone.utc()`**
- **[Owner] `TimeZone.parse(s)!`** reads a zone name, or an offset as `+05:30`, `+0530`
  or `+05`. It is the fallible way to turn an offset from a file or a user into a zone,
  and `TimeZone.parse(tz.name())!` gives `tz` back.
  - **[Judgment]** `Z` or `z`, `+00:00` and `-00:00` give `utc()`. (Jiff reads `Z` as
    an offset but not inside brackets, so `…[Z]` in a zoned string still fails.)
  - An offset with seconds (`+05:30:00`), with one digit (`-7`), or with a name before
    it (`UTC+5`) fails.
- **`tz.name() -> String`**
  - a named zone: the name that was asked for, in the data's spelling.
    `named("america/denver")` is `America/Denver`, and `named("Asia/Calcutta")` stays
    `Asia/Calcutta`;
  - a fixed zone: its offset, `-07:00`;
  - `utc()`: `UTC`.
  - This is what a `ZonedDateTime` prints in its brackets.
- **`tz.offset_at(i: Instant) -> Duration`**, total.
- **Equality and hashing** [Jiff], measured:

  | Compared | Equal? |
  |---|---|
  | `Asia/Calcutta`, `Asia/Kolkata` | yes: the same *primary identifier* |
  | `America/Denver`, `America/Shiprock` | yes |
  | `Africa/Accra`, `Africa/Abidjan` | **no**, though their rules are identical |
  | `UTC` (which is `utc()`), `Etc/UTC` | **no** |
  | `utc()`, `fixed(hours: 0)`, `named("UTC")` | yes: one value |
  | `Etc/GMT+7`, `fixed(hours: -7)` | **no**: a named zone never equals a fixed one |

  - Two named zones are equal when their primary identifiers are equal
    (`tz/timezone.rs:2749-2772`). Two fixed zones are equal when their offsets are.
  - `Hash` follows the same rule. Jiff's `TimeZone` has no hash, so this part is
    Rig's and is tested directly.
- **Inside:** a named zone is an index into the 598 **names**. Each name points at its
  zone's rules and at its primary identifier. A fixed zone is its offset in minutes.

## 7.5 The zone data

**[Owner]** Embedded in the program, never read from the system at run time. The same
program gives the same answer on every machine.

- **This differs from Jiff**, which reads the system's copy and embeds one only where
  there is none. Jiff's reason is freshness: the system's copy is updated, and an
  embedded one is as old as the build.
- **The data:** IANA `2026f`, taken from Jiff's own bundle so that it matches the test
  oracle. It is the "rearguard" form, which differs from the standard form only in
  which half of the year a few zones flag as daylight saving. Rig decides by offsets
  and exposes no daylight-saving flag, so the choice does not show.
- **How it is carried** (verified by building Rig and running it,
  `reviews/builder-review.md`):
  - `tools/gen-tzdb.py` writes generated Zig tables into `std/`: per zone the
    transitions as plain arrays, the offsets, the abbreviations and the parsed rule for
    dates after the last transition; the names; and each name's primary identifier,
    which comes from a separate table in Jiff (`tz/db/metadata.rs`).
  - It fetches its inputs, the `jiff` and `jiff-tzdb` crates, pinned by checksum, as
    `tools/gen-unicode.py` fetches its own. A test checks the tables are current.
  - The names are in a file of their own, which the compiler reads through its std
    reader for the literal check in 7.4 (so a std given by `RIG_STD` agrees).
  - It also writes a small **test table** from pinned zone files (Dublin in the
    standard form, a made-up Morocco rule), reached by a private function. Only tests
    inside the module can call it: files `std/datetime/*_test.rig`, run by
    `rig test std.datetime`. That is how a test gets rules that do not change with the
    data, and a user's program cannot reach them.
  - A shim searches the tables and returns numbers. Nothing is parsed at run time.
- **What a program pays:** nothing unless it uses a named zone. A program that uses
  only `Date` is the same size as before the zones were built, and one that uses only
  fixed zones grows by 1 KB. One that uses a named zone carries the tables, about
  100 KB (measured, `records/2026-11/datetime-phase4`).
- `datetime.tzdb_version()` returns `"2026f"`. Each Rig release refreshes the data.
- **A one-way door.** A `ZonedDateTime` holds its `TimeZone`, and a plain value cannot
  hold an owning one. So zone data loaded at run time could only ever be loaded once
  and kept for the life of the program. Keeping a `TimeZone` an index leaves that open.
  It is not in v1.

## 7.6 Offsets

- An offset is a `Duration`: `z.offset()`. `print(z.offset())` shows `-7h`.
- `z.offset_text() -> String` gives `-07:00`, as the `%:z` directive does. Both show
  seconds when a historic offset has them (`-00:44:30`).
- **In RFC 3339 and RFC 9557 text the offset is rounded to the minute** [Jiff]:
  `1968-02-01T23:15:00-00:45[Africa/Monrovia]`. When parsing, that rounded offset
  counts as agreeing with the zone.
- **A trap** [Jiff], which the docs state: parsing such a string as an `Instant`
  ignores the zone and uses the rounded offset, so it reads back 30 seconds off.
  Parsing it as a `ZonedDateTime` is exact. It affects only dates before 1972.

## 7.7 The system's zone

`datetime.local()!` asks for it. Nothing ever uses it, or UTC, without being asked.

**[Judgment]**, except where marked.
1. **`TZ`, when it is set:**
   - empty means UTC (the Unix convention, and Jiff's);
   - a zone name. A leading `:` is dropped, and a path is cut to what follows
     `zoneinfo/`;
   - **[Judgment]** an absolute path with no `zoneinfo/` in it, such as
     `:/etc/localtime`, which is read as a link and what it points at is cut the same
     way;
   - **[Owner]** a rule with no daylight-saving part, as a fixed offset: `UTC0`,
     `EST5`, `<+08>-8`. Not after a `:`, which marks a name. **[Owner, 2026-11-22]**
     Its hours run from 0 to 25, as `fixed`'s do, where POSIX stops at 24;
   - anything else fails. A set `TZ` never falls through to the files below.
2. Otherwise, the name the `/etc/localtime` link points at, cut the same way (macOS
   points it at `/var/db/timezone/zoneinfo/America/Denver`).
3. Otherwise, the name in `/etc/timezone`.
4. Otherwise it fails, with a message that names `TZ`.

**[Owner, 2026-11-22]** The error members carry no fields, so a failure prints its
member's name (`DateTimeError.no_system_zone`, `DateTimeError.unknown_zone`); the
member's documentation and STD say to set `TZ`, and that `tzdb_version()` gives the
data's version. "A message" below means that documentation.

- **Not read:** a `TZ` rule with a daylight-saving part or with seconds
  (`EST5EDT,M3.2.0,M11.1.0`), and the bytes of `/etc/localtime`. Either would need a
  zone that is not in the embedded data, which a plain `TimeZone` cannot hold. The
  common spellings `EST5EDT` and `PST8PDT` are zone names and work as names.
- A zone the data lacks (one newer than the Rig release) fails with a message that
  gives the data's version.
- **Where it fails by default:** on Windows, where v1 reads `TZ` only and Windows does
  not set it; and where `/etc/localtime` is a copy and not a link, with no
  `/etc/timezone`, as in some container images. The message names `TZ` in both cases. A
  program that can do without the system's zone writes the fallback itself.
- It reads the environment and the file system each time it is called (it allocates
  and may wait), and nothing is cached. A program keeps the result.
- It needs a new `file.read_link` in `std.file`, since `file.realpath` follows every
  link.
- **Differences from Jiff:** Jiff tries `TZ` as a rule before a name, reads rules with
  daylight saving, reads the bytes of `/etc/localtime`, caches the answer, and has a
  form that falls back to an "unknown" zone instead of failing. Two results differ:
  - `TZ=UTC0` is `utc()` in Rig and prints `[UTC]`; in Jiff it is a separate zone that
    prints `[+00:00]`.
  - `TZ=EST5` is -05:00 in both, but Rig's fixed zone has no abbreviation, so `%Z`
    prints `-05` where Jiff prints `EST`.

## 7.8 Instants

- `datetime.now() -> Instant` reads the wall clock.
  - **[Owner]** It is the real clock under the deterministic scheduler too; only the
    monotonic clock is virtual there.
  - It is total: the clock reads an `Int` of nanoseconds since 1970, the years 1677 to
    2262, inside the range.
- **[Owner, 2026-11-22] Making an instant from a Unix time**, one maker for each unit
  a file or a message holds, each taking an `Int` (or a `Float`) and never a duration
  form, so the maker sees the number and can refuse it:

  ```
  Instant.from_unix_s(s: Int, ns: Int = 0) -> Instant!
  Instant.from_unix_ms(ms: Int) -> Instant!
  Instant.from_unix_us(us: Int) -> Instant!
  Instant.from_unix_ns(ns: Int) -> Instant
  Instant.from_unix_float(s: Float) -> Instant!
  ```

  - `from_unix_s(s, ns: n)!` is `s` seconds and `n` nanoseconds after
    1970-01-01T00:00Z, as Unix tools count; `n` is given by name. It fails `.range`
    beyond the range of instants (7.1), and for an `n` outside ±999,999,999. The two
    may differ in sign and are summed exactly, as in Jiff's `Timestamp::new`:
    `from_unix_s(0, ns: -1)` is 1969-12-31T23:59:59.999999999Z. `Int.max` and
    `Int.min` fail; nothing overflows.
  - `from_unix_ms(ms)!` and `from_unix_us(us)!` are a JavaScript or Java time and a
    count of microseconds; each fails `.range` beyond the range. (An `Int` of either
    reaches far past the year 9999.)
  - `from_unix_ns(ns)` is total: an `Int` of nanoseconds reaches the years 1677 to
    2262, all inside the range. It is Go's `UnixNano` read back.
  - `from_unix_float(s)!` is a `Float` of seconds, a wire format of Python's
    `time.time()`, Prometheus and many JSON APIs, converted from its exact value to the
    nearest nanosecond, a half away from zero. It fails `.invalid` for a NaN and
    `.range` for an infinity or a value beyond the range. A `Float` near 1.7e9
    resolves only about 240 ns, so a finer time is given as `Int`s. Without this maker
    a program would write `Int(f)`, which panics on a NaN.
  - With constant arguments `from_unix_s`, `from_unix_ms` and `from_unix_us` take no
    `!` (10.6): `Instant.from_unix_s(1_700_000_000)`.
  - There is no `from_unix(<duration form>)`. A `Duration` value `d` is
    `Instant.from_unix_s(d.seconds(), ns: d.subsec_ns())!`.
- **Reading a Unix time**, all total:
  - **`i.unix() -> Duration`**, exact at any instant, negative before 1970. Then
    `i.unix().seconds()`, or `.ns()` as an `I128`. `.seconds()` truncates toward
    zero, so half a second before 1970 is 0, not -1.
  - **`i.unix_s()`, `i.unix_ms()`, `i.unix_us()`**, each an `Int`: the whole seconds,
    milliseconds and microseconds since 1970, floored, exact at any instant
    (microseconds at the year 9999 are about 2.5e17). `unix_s()` is the count Unix
    tools give, and each is the inverse of its maker.
  - There is no `unix_ns()`: nanoseconds at the year 9999 do not fit an `Int`. It is
    `i.unix().ns()`, an `I128`.
- At the edges:

  | Call, with each number known only at run time | Result |
  |---|---|
  | `from_unix_s(9_300_000_000)` | 2264-09-14T21:20:00Z |
  | `from_unix_s(253_402_207_200, ns: 999_999_999)` | 9999-12-30T22:00:00.999999999Z, the last instant |
  | `from_unix_s(253_402_207_201)` | fails `.range` |
  | `from_unix_s(-377_705_023_201)` | -009999-01-02T01:59:59Z, the first instant; one less fails |
  | `from_unix_ms(8_640_000_000_000_000)` | fails `.range` (JavaScript's last `Date`, the year 275760) |
  | `from_unix_ns(Int.max)` | 2262-04-11T23:47:16.854775807Z |
  | `from_unix_float(nan)`, `(inf)`, `(1e12)` | fails `.invalid`, `.range`, `.range` |

  The same calls with constants are compile errors where they would fail, and take no
  `!` where they would not (10.6).

```rig
use std.datetime
use std.text

sub main()!
  s = text.parse_int("9300000000")!
  i = datetime.Instant.from_unix_s(s)!
  print(i, i.unix_s(), i.unix_ms())
  print(datetime.Instant.from_unix_ns(-1))
  print(datetime.Instant.from_unix_float(text.parse_float("1700000000.5")!)!)
  print(datetime.Instant.from_unix_ms(s * 1_000_000) catch datetime.Instant.max())
```

```output
2264-09-14T21:20:00Z 9300000000 9300000000000
1969-12-31T23:59:59.999999999Z
2023-11-14T22:13:20.5Z
9999-12-30T22:00:00.999999999Z
```

- `i.add(<duration form>)!`, `i.round(…)!`, `i.floor(…)!`, and the total
  `i.since(other)` and `i.in_zone(tz)`.
- There are no calendar keywords on an instant: `i.add(days: 1)` is the compile error
  of 5.2, since a day needs a zone.

---

# 8. Text

## 8.1 What each type prints and reads

**[Jiff]**

| Type | `print` | `parse` |
|---|---|---|
| `Duration` | `1h 30m` (5.5) | ISO 8601 and the friendly grammar |
| `Instant` | RFC 3339 with `Z`: `2026-11-17T15:07:03.512094Z` | RFC 3339 with any offset |
| `Date` | `2026-11-17` | ISO 8601 |
| `Time` | `08:07:03.512094` | ISO 8601 |
| `DateTime` | `2026-11-17T08:07:03.512094` | ISO 8601 |
| `ZonedDateTime` | RFC 9557: `2026-11-17T08:07:03.512094-07:00[America/Denver]` | RFC 9557 |
| `TimeZone` | its `name()` | `TimeZone.parse` (7.4) |
| `Weekday` | `Tuesday` | none |

- `String(x)` gives the same text as a `String`, which is how a value is stored:
  `String(z)` and later `ZonedDateTime.parse(text)!` give back the same instant in the
  same zone.
- Seconds are always printed. A fraction is printed only when it is not zero, with its
  trailing zeros dropped. So printed instants do not sort as text. A fixed width comes
  from `format` on the zoned form:
  `i.in_zone(datetime.TimeZone.utc()).format("%Y-%m-%dT%H:%M:%S%.3fZ")`.
- A year below 0 prints with a sign and six digits, `-000001-01-01`, and reads back in
  that form only.
- The grammar is Jiff's `fmt/temporal`, including what it rejects. Measured:

  | Text | Parsed as | Result |
  |---|---|---|
  | `2024-03-10T03:30:00` | `Instant` | rejected: an instant needs an offset |
  | `2024-03-10t03:30:00z`, `2024-03-10 03:30:00,5Z` | `Instant` | accepted |
  | `…-06:00[America/Denver]` | `Instant` | accepted; the zone is ignored |
  | `2024-03-10T03:30:00[America/Denver]` | `ZonedDateTime` | accepted; resolved as in 6.5 |
  | `…-06:00[america/denver]` | `ZonedDateTime` | accepted; prints `[America/Denver]` |
  | `…-07:00[-07:00]`, `…[-0700]`, `…[-07]` | `ZonedDateTime` | accepted, as a fixed zone |
  | `2024-03-10T03:30:00-06:00` | `ZonedDateTime` | rejected: no zone (but see 8.2) |
  | `2024-03-10T03:30:00Z` | `DateTime`, `Date`, `Time` | rejected: `Z` marks an instant |
  | `2024-03-10` | `DateTime` | accepted: midnight |
  | `20240310`, `03:30` | `Date`, `Time` | accepted |
  | `2024-06-30T23:59:60…` | any type that reads a time | accepted; the second is read as 59 |

**[Owner] `Date`, `Time` and `DateTime` read only their own form.** Jiff reads the
part it wants and drops the rest without a word; Rig rejects the text. Measured, for
what Jiff does:

| Text has | `Date` | `Time` | `DateTime` |
|---|---|---|---|
| a date only | reads it | rejects | reads it as midnight (kept) |
| a date and a time | **rejects** (Jiff drops the time) | **rejects** (Jiff drops the date) | reads it |
| a time only | rejects | reads it | rejects |
| an offset as well | **rejects** (Jiff drops it) | **rejects** (Jiff drops it) | **rejects** (Jiff drops it) |
| a zone in brackets as well | **rejects** (Jiff drops it) | **rejects** (Jiff drops it) | **rejects** (Jiff drops it) |
| `Z` | rejects | rejects | rejects |

- Dropping an offset without a word gives a time that is hours off with no error.
  Java's `LocalDateTime.parse` rejects such text; Python's `fromisoformat` keeps the
  offset.
- Two cases above stay as Jiff has them. A date alone is a `DateTime` at midnight,
  which loses nothing. An `Instant` ignores a zone in brackets, since the offset alone
  fixes the instant; the cost is that it does not notice an offset that no longer fits
  its zone (8.3), which only `ZonedDateTime.parse` checks.

**Not in v1:** text in any other form (`11/17/2026`, `17 Nov 2026`, an HTTP or email
date). There is no parsing by a format string yet (8.4).

## 8.2 Text with no zone of its own

`ZonedDateTime.parse(s, default_zone: tz)!` (spelling) supplies a zone for text that has
none. This is Rig's, not Jiff's. **[Judgment]**

- Text with a zone in brackets keeps its own, and the default is not used.
- Text with neither offset nor zone is placed in `tz`, resolved as in 6.5.
- Text with an offset and no brackets is placed in `tz`, and the offset must agree with
  it, as in 8.3.
- Text ending in `Z` and no brackets is that instant, shown in `tz`.
- Without a default, text with no zone in brackets is rejected.
- **It does not convert.** To show an API's text in a user's zone:
  `Instant.parse(s)!.in_zone(tz)`.
  - So with Denver as the default, `…T15:07:03Z` is read and `…T15:07:03+00:00` is
    rejected, though they are one instant: the second states an offset, and it is not
    Denver's.
- A zoned value that keeps the text's own offset as a fixed zone is not made in one
  call in v1. It is `Instant.parse(s)!.in_zone(TimeZone.parse(offset)!)`, with the
  offset cut from the text.

## 8.3 A stored string whose offset no longer fits its zone

**[Jiff]** `2030-12-01T12:00-02:00[America/Sao_Paulo]` was written before 2019, when
Brazil had daylight saving in December. Today's rules give -03:00 for that date.

- By default the string is **rejected**.
- A keyword chooses otherwise. It is called `conflict:` here, and its values are an
  enum's (spelling): `.reject` (the default), `.keep_instant` (11:00-03:00) and
  `.keep_clock` (12:00-03:00).
- `Z[zone]` never conflicts: it means that instant, shown in that zone.

## 8.4 `format`

A small strftime, with Jiff's meanings for each directive.

- **[Owner] `x.format("…") -> String` takes a string known at compile time**, a literal
  or a module constant bound to one, which the compiler checks against the type: `%H`
  on a `Date`, `%z` on a `DateTime` and an unknown directive are compile errors. So it
  cannot fail.
- **Which directive suits which type:**

  | Directives | `Date` | `Time` | `DateTime` | `ZonedDateTime` |
  |---|---|---|---|---|
  | `%Y %m %d %e %A %a %B %b %j %F %u %G %V` | yes | | yes | yes |
  | `%H %M %S %I %p %T %R %f %.f` | | yes | yes | yes |
  | `%z %:z %Z %s` | | | | yes |

  (Jiff accepts `%.f` on a `Date` and prints nothing. Rig refuses it, so the test of
  every directive does not use the oracle there.)
- **`x.try_format(s)!`** (spelling) takes a string made at run time, and fails where
  `format` would not compile.
- The directive table exists twice, in the compiler and in the library. A test checks
  every directive on every type both ways.
- **Kept:** `%Y %m %d %e %H %M %S %I %p %A %a %B %b %j %F %T %R %z %:z %Z %s %u %G %V
  %f %.f %%`, the `-` flag (no padding), and a precision on the fraction (`%.3f`).
  - `%e` pads with a space (`March  8`); `%-d` is the day with no padding.
  - `%f` drops trailing zeros and `%.f` prints nothing for zero, so a fixed width needs
    a precision.
  - `%Z` is the zone's abbreviation at that instant (`MST`, `MDT`). A fixed zone has
    none and prints its offset in Jiff's short form (`-07`, `+05:30`), and `utc()`
    prints `UTC`.
  - A year below 0 follows Jiff: `%Y` of year -1 is `-001` and `%F` is `-0001-01-01`,
    which does not read back. `print` is the form that does (8.1).
- **Not in v1:** `%c %r %x %X` (locale forms), `%y %g` (two-digit years), `%Q %q %::z
  %:::z %U %W %w %C %D %k %l %P %N %n %t %h`, the `_`, `0`, `^` and `#` flags, and
  widths (`%3f` and `%05d` are out; the precision `%.3f` is in).
- English names only.
- Parsing by a format string is not in v1.

## 8.5 ISO weeks

`d.iso_week()` and `d.iso_week_year()`. 2025-12-29 is week 1 of 2026.

---

# 9. Deviations from Jiff

1. **Names:** `Instant` for `Timestamp`; one `Duration`; `Monotonic` where Rust has
   `std::time::Instant`.
2. **No span.** Calendar amounts are keywords, counts are `Int`s, and ISO durations
   with years, months, weeks or days are rejected (6.1).
3. **Counts** walk forward from the earlier value and negate, where Jiff measures from
   the receiver; across two zones they use the earlier value's calendar, where Jiff
   refuses (6.4).
4. **Calendar keywords may differ in sign** (6.2). Jiff's span has one sign.
5. **Zone data** is embedded and prepared at build time (7.5).
6. **`local()`** reads names and fixed offsets only, never falls back to an unknown
   zone, and caches nothing (7.7).
7. **A bare number is seconds** wherever a duration is taken (5.2).
8. **`print` of a duration** is the friendly form, with `-` and `us` (5.5).
9. **Compile errors** where Jiff fails at run time or accepts: `days:` on a duration, a
   positional argument to `add`, `with`, `round`, `floor` or `fixed` where
   10.2 forbids one, `Date.add(hours: 1)`, a misspelled zone
   name, a bad `format` string, a bad rounding increment, a bad `fixed`.
10. **Fixed zones** take whole minutes (7.4).
11. **`TimeZone` hashes** (7.4), and **`Weekday` orders**, from Monday (4.1). Jiff's do
    neither.
12. **`Instant.round`** takes a half to the later value before 1970 too (6.8).
13. **`ZonedDateTime.parse(s, default_zone:)`** (8.2), and `Z` read by
    `TimeZone.parse` (7.4).
14. **A round that passes midnight** carries into the next day in years at or below 0,
    where Jiff 1.0.0 has a bug; and **`round(days: 1)`** measures to the next day's
    start, where Jiff 1.0.0 measures to the start plus a day on the clock (6.8).
15. **`Date`, `Time` and `DateTime` read only their own form** (8.1).
16. **Fewer things:** no offset type, no daylight-saving flag, only two rounding modes,
    no parsing by format string, fewer `format` directives.
17. **No call panics** ("Total or visible", 7.2). **[Owner, 2026-11-22]** Jiff panics in
    its `+` and `-` on every datetime type, in `SignedDuration`'s operators and in the
    `abs` of its smallest value, in `SignedDuration::from_secs_f64`, and in
    `civil::date` given bad parts. Rig has none of these. Its `add`, `round`, `floor`
    and `start_of_day` are Jiff's `checked_add`, `round`, `floor` mode and
    `start_of_day` under one name each, with no `checked_` or `saturating_` twins: Jiff's
    `saturating_add` is `add(…) catch T.max()`. `Duration`'s range is symmetric, so its
    `neg` and `abs` cannot fail.
18. **No operators on `Duration`** (5.6), where Jiff's `SignedDuration` has `+`, `-`,
    `*` and `/`. **[Owner, 2026-11-22]**
19. **Constant arguments are checked at compile time** and the maker then takes no `!`
    (10.6).
20. **`Time.add` wraps** under its plain name, as Jiff's `wrapping_add` does; Jiff's
    `Time::checked_add`, which fails past midnight, has no counterpart (6.2).
21. **Unix makers** **[Owner, 2026-11-22]** (7.8): `from_unix_s(s, ns:)`,
    `from_unix_ms`, `from_unix_us` as Jiff's `Timestamp::new`, `from_second`,
    `from_millisecond` and `from_microsecond`, but `from_unix_ns` takes an `Int` and
    cannot fail where Jiff's `from_nanosecond` takes an `i128` and can; and
    `from_unix_float`, which Jiff does not have. Their inverses `unix_ms()` and
    `unix_us()` are `Int`s, floored.

---

# 10. Compiler and std work

Line numbers were read from `origin/main` on 2026-11-17 (10.1 to 10.4) and 2026-11-22
(10.5 to 10.7), and need checking again when the work starts. Sizes are the reviewers'
estimates. 10.1 to 10.7 are built (phases 1 to 3, then a to c of section 11), before
phase 4 (11).

## 10.1 Durations

| Site | Today | Change | Size, risk |
|---|---|---|---|
| `src/resolve.zig:2557` `paramDurations` | matches the type's text `Duration`, in `std.time` only | match the resolved `time.Duration`, and `Duration?`, in any module | 40 lines, low |
| `src/typecheck.zig:11786-11803` | unit keywords fill the parameter **named** `ns` | fill the parameter **typed** `Duration`, by the rules in 5.2 | 40, medium |
| `src/typecheck.zig:12254` `checkDurationArg` | takes an `Int` or `Float` | also a `Duration` value; range check in seconds; the negative-constant check for the list in 5.8 | 70, low |
| `src/typecheck.zig:12284-12336`, `16880`, `16916` | diagnostics for the constants | removed | -60, low |
| `src/typecheck.zig:21753` `isSecondsName` | rejects `seconds:` | `seconds:` is a unit; `sec`, `secs`, `s` get "did you mean" | small |
| `src/sema.zig:12117-12150` | the units `ms`, `us`, `ns` | add `seconds`, `minutes`, `hours` | small |
| new | (none) | `days:` or `weeks:` to a function with a `Duration` parameter and no parameter of that name: the error of 5.2, with its fix | 30, low |
| `src/emit.zig:5961`, `src/runtime.zig:4582` | `durationInt` and `durationFloat` build an `Int` | build the object, wrapped as an optional for a `Duration?` parameter; the runtime is given the type and fills fields by name | 100, medium |
| `time.after`, `per:` (`typecheck.zig:16432`, `14833`; `emit.zig:9476`, `8527`, `9526`; `tasks.zig:1819`) | an `Int` of nanoseconds | stay nanoseconds inside, and take a `Duration` value by its type | 40, low |
| `src/sema.zig:6509` and the `since_start` plumbing | keyed on the name | kept; `since_start` becomes a Rig wrapper over a private function | small |
| **Several unit keywords** (`sema.ArgSlot`, `typecheck.zig:11908-11982`, `emit.zig`, `storage.zig`) | one argument fills one parameter, and six places read that | a parameter filled by several parts, summed with a checked add | 250 to 400 lines in five files, medium to high: every call passes through it. Its own change (phase 1b) |

Phase 1 in all, before the summed keywords: 700 to 1,000 changed lines in `src`, and
about 80 test cases, one for each form at each site. A site that is missed shows up as
a Zig error in emitted code, which breaks North Star rule 1, so those tests are `test`
cases that reach the emitter, not doc examples.

## 10.2 Checks of a std call's arguments

There is no precedent for checking the arguments of a std type's method. These share
one new hook, at the two places where a method call and a call through the type are
resolved (`typecheck.zig:14256` `synthMemberCall`, `17068` `associatedCall`), and at a
third for a method taken as a value (below). A call through the type passes the value
first, and the hook counts after it. A check is written in the phase shown, and each
type's tests of it land with the type.

| Check | Size | Lands in phase |
|---|---|---|
| `round` and `floor`: exactly one unit keyword, no positional argument, and a literal increment must be allowed | 60 lines | 1 (with the hook) |
| No positional argument to `Date.add`, any `with`, or `TimeZone.fixed`; at most one to `DateTime.add` and `ZonedDateTime.add` (so `z.add(1, 2)` is not a second and two years) | 40 | 2 |
| `Date.add(hours: 1)`: the message of 6.2 | 10 | 2 |
| `TimeZone.named("…")`: a literal must name a zone (the names file from 7.5; `editDistance` gives the nearest) | 150 | 4 |
| `TimeZone.fixed(…)`: literals in range and of one sign | 50 | 4 |
| `format("…")`: the argument must be known at compile time, and its directives must suit the type | 200 | 6 |

- **[Rig] A checked method cannot be taken as a value** (`f = datetime.Date.add`), since
  a call through a value passes by every check. That is refused where a type's member
  becomes a value (`typecheck.zig:8794` `typeMember`, which already refuses a generic
  type's method). `TimeZone.named` stays usable as a value: its check is only of a
  literal.
- **Removed names** get a fix through the existing hint table (`sema.zig:6471`), which
  can name two replacements: `time.now`, `time.unix_ns`, `time.Instant`, and the five
  constants.
- The rule that a parameter with a default is an option, given by name
  ([options.md](options.md)), replaced the positional checks and the refusal of a
  checked method as a value: a function with options is not a value. The increment
  checks of `round` and `floor` remain, since they check values.

## 10.3 std

- `std/time.rig`, rewritten. Its private function `monotonic` is renamed, since the
  public one takes the name.
- `std/datetime`, new, as a directory module, with a shim `std/datetime.zig` for the
  table search and the wall clock. Each of its files has its own `use std.time`.
  - A field cannot share a name with its reader, so the fields are short (`y`, `m`,
    `d`) and the readers have the full names.
- `std/file`: `read_link`.
- `std/embed.zig`: rows for the new files and tables.
- `tools/gen-tzdb.py`, with its freshness test.
- **Errors:** one error set for each module, in the style of `std/text.rig` and
  `std/json.rig`, which the builder follows for the signatures.
  - `std.time`, `TimeError`: `invalid`, for bad text (`Duration.parse`), bad parts
    (`from_parts`), a number that is not finite, a computed increment that is not
    allowed, and `div(0)`; `range`, for a result past the range (`add`, `sub`,
    `times`, `round`, `floor`, `Monotonic.add` and `at`, and a duration form's
    conversion).
  - `std.datetime`, `DateTimeError`: `invalid` and `range` in the same senses, and
    then unknown zone (`unknown_zone`), a skipped or repeated time under `.reject`
    (`skipped_or_repeated`), an offset conflict (`offset_conflict`), no system zone
    (`no_system_zone`), a bad format string (`try_format`).
  - A duration form's conversion fails with the member of that name in the callee's
    own set, so both sets keep `invalid` and `range` (5.2).
- SPEC "Durations" (`SPEC.md:14850`) is rewritten. `docs/STD.md` "std.time" is
  rewritten, and "std.datetime" is new. `docs/internals/INTERNALS.md` describes the
  duration fact and changes with it. `docs/ROADMAP.md` gains the entry in phase 1, and
  loses its stale line about durations.
- **Tests** are in `test/rig/std-time*.rig.test` and `test/rig/std-datetime*.rig.test`,
  except the ones that need the pinned test table, which are inside the module (7.5).

## 10.4 Migration

`tools/migrate-datetime.py`, on the pattern of `tools/migrate-durations.py`.

| Old | New |
|---|---|
| `time.now()` | `time.monotonic()` |
| the type `time.Instant`, `Instant.at(x)` | `time.Monotonic`, `Monotonic.at(x)` |
| `t.elapsed() < 250 * time.MS` | `t.elapsed() < time.duration(ms: 250)` |
| `print(t.elapsed())` in a bench that prints nanoseconds | `print(t.elapsed().ns())` |
| `t.since(u)`, `time.since_start()` used as an `Int` | the same, as a `Duration` |
| `time.unix_ns()` (in phase 3, when `datetime.now()` exists) | `datetime.now().unix().ns()` |
| `TIMEOUT = 30 * time.SECOND` | `TIMEOUT_S = 30`, passed bare |

- In Rig's own source: `time.now()` on 29 lines in tests and 67 in benches;
  `.elapsed()` on 27 and 66; the constants on 36 and 1; `time.Instant` or `Instant.at`
  on 16 lines of tests, `.since(` on 9 and `since_start` on 8. `docs/history` is a
  record and is left alone.
- **The live docs are tests too**, and the ones that use a removed name change in the
  same phase as the name: `SPEC.md` (9 lines), `docs/STD.md` (9),
  `docs/learn/06-stdlib.md` (7), `docs/learn/09-tests.md` (4), `docs/MIGRATING-0.3.md`
  (9).
- The bench harnesses read printed whole nanoseconds (`bench/tasks/bench-tasks:121`).
- `test/rig/std-misc.rig.test:2796` sleeps a negative constant and becomes a compile
  error; the test changes. Two more tests run the old forms and change with them:
  `test/cli/migrate_durations.sh` and `test/cli/emit.sh`.
- **Trig** has 5 such lines in 2 files, which must compile under the new Rig:
  `tools/checker/bench.rig` times with `time.now()` on 4 lines (phase 1), and
  `tools/trig/main.rig:97` reads `time.unix_ns()` (phase 3). The builder prepares each
  patch, and the Trig session lands it with the Rig change.

**The migration of phases 1 to 3 to "Total or visible"** (10.7), by
`tools/migrate-tov.py`, which is driven by the compiler's errors, as
`tools/migrate-options.py` is:

| Old | New |
|---|---|
| `x.add(…)`, `x.round(…)`, `x.floor(…)` on `Date`, `DateTime` or `Instant`; `Monotonic.add` and `at`; `Duration`'s `add`, `sub`, `times`, `div`, `round`, `floor` | the same with `!`; in a function that cannot fail, `catch panic("…")` naming the call, so the old panic stays where it was, now in the program's source |
| `x.checked_add(…)`, `checked_sub`, `checked_times` | `x.add(…)`, `sub`, `times` |
| `t.checked_add(d)` on a `Time` | left for a person (MANUAL): there is no call that fails past midnight (6.2) |
| `Instant.from_unix(x)`, `from_unix(seconds: x)` | `Instant.from_unix_s(x)!` for an `Int`, `from_unix_float(x)!` for a `Float` |
| `Instant.from_unix(ms: t)`, `us:`, `ns:` | `from_unix_ms(t)!`, `from_unix_us(t)!`, `from_unix_ns(t)` |
| `Instant.from_unix(minutes: t)`, `hours:`, several keywords | left for a person (MANUAL); rare |
| `Instant.from_unix(d)` with a `Duration` `d` | `Instant.from_unix_s(d.seconds(), ns: d.subsec_ns())!` |
| `d.ms()`, `d.us()`, `d.ns()` where an `Int` is wanted | the same, an `I128`; `Int(d.ns())` where the value must be an `Int` (a `Monotonic`'s difference always fits) |
| `Date.new(2027, 1, 31)!` and the other makers of 10.6, every argument a constant | `Date.new(2027, 1, 31)` (once 10.6 has landed) |
| a run-time `Float` given to a wait | `time.sleep(time.duration(x)!)!` |

- Every site is a compile error first: a `T!` used as a `T`, `!` on a call that cannot
  fail, a removed name through the hint table, or an `I128` where an `Int` is wanted.
  So the script can miss nothing silently.
- In Rig's own source (counted 2026-11-22, tests, benches, std, docs and the oracle):
  `checked_` on 83 lines, `from_unix(` on 55, `.unix()` on 24, `.ns()` on 97, `.ms()` on
  14, `.us()` on 4, and about 500 calls of `Date.new`, `Time.new` or `DateTime.new`
  with constant arguments; every `add`, `round` and `floor` in the datetime tests.
- The live docs change with it: `docs/STD.md`, SPEC "Durations", `docs/MIGRATING-0.3.md`.
- **Trig:** phase 1's `tools/checker/bench.rig` reads `elapsed()`, and phase 3's
  `tools/trig/main.rig` reads `datetime.now().unix().ns()` as an `Int`; the second
  becomes `Int(datetime.now().unix().ns())`. The builder prepares the patch with the
  change.
- Where a release accepted a form this rejects, the release notes list it, and Trig
  gets its note and the script (AGENTS.md).

## 10.5 Error traces

**[Owner, 2026-11-22]** A language change of its own, before the change of 10.7
(`docs/ROADMAP.md`, Language). Under "Total or visible" a failure that leaves `main`
prints only `error: DateTimeError.range`, where a panic's message would name the call
and the value. So when a failure leaves `main`, Rig prints each `f()!` site it passed
through, from Zig's error return trace. It needs no syntax.

| Site | Today | Change |
|---|---|---|
| `src/runtime.zig:8599` `failMain`, `8613` `reportFailure` | print `error: E.name`, or the error's fields | then print the trace, a Rig file and line for each `!` |
| `src/emit.zig:1945` | `main`'s catch | passes the trace to the runtime |
| new | (none) | how a Zig frame in the emitted code is shown as the Rig line of its `!` |

- Its design is its own round: which builds print it (debug builds at least; release
  builds if a measurement shows the trace costs little there), and the form of a line.
- Tests: a failure from three calls deep prints three sites; one handled by `catch`
  prints none.

## 10.6 Constant arguments

**[Owner, 2026-11-22]** A language rule of its own, which this library relies on:
**when every argument to a listed std maker is a compile-time constant, and the check
the compiler already runs on those arguments passes, the call's type is the plain type,
not `T!`.** A bad constant is a compile error, as it is today, and `!` on a call that
passes is rejected, as on any call that cannot fail.

- **The makers listed:** `Date.new`, `Time.new`, `DateTime.new`, `TimeZone.fixed`,
  `TimeZone.named` with a string literal, `Duration.from_parts`,
  `Instant.from_unix_s`, `from_unix_ms` and `from_unix_us`, and `time.duration` (5.2).
  `parse` is not among them.
- **A constant** is what Rig already computes as one (`sema.constIntOf`,
  `Checker.floatConst`, a string literal); the rule never asks a prover.
- **The source shows which case applies:** every argument is a literal or a constant.
  The answer never changes between releases. A refactor that turns a literal into a
  variable makes the `!` required, which is where failure becomes possible, and the
  compiler says so.
- **Recorded once** as a fact on the call (North Star 4). Emit writes the call with a
  `catch` that reports a disagreement between the compiler's check and the library's as
  a bug in Rig, never Zig's `unreachable`. The validity rules exist twice, in the check
  and in std, as `format`'s directive table does (8.4), and a test runs every maker on
  each side of each rule both ways.
- **SPEC §13** gains one sentence: a bare call to a fallible function is rejected,
  unless it is a listed std maker whose arguments are all constants that pass its check.
- Sites: `src/typecheck.zig:12505` `stdArgChecks` (the checks), `9914` (the bare-call
  error), `src/sema.zig:16910` `constIntOf`, and the hook of 10.2 for `named` and
  `fixed`. About 100 to 200 lines.
- **Without the rule,** the makers keep their `!` with constants (a bad constant is
  still a compile error, and the `!` is never taken), `time.duration` takes only the
  forms that cannot fail, and `time.checked_duration(<form>) -> Duration!` takes the
  rest (5.2). Nothing else in this design changes.
- A version that drops `!` wherever a prover shows a call cannot fail was rejected:
  whether a call needs `!` would then depend on how far the prover reaches, which
  changes between releases. `src/proofs.zig` stays an emit optimization that never
  changes a type.

## 10.7 Total or visible

**[Owner, 2026-11-22]** The change that applies "Total or visible" to phases 1 to 3,
after 10.5 and 10.6. Phases 4 to 6 are written to it from the start.

| Site | Today | Change | Size, risk |
|---|---|---|---|
| `std/time.rig` `Duration` | one private `Int` field `n` of nanoseconds | private `s: Int` and `ns: I32` of one sign, symmetric (5.1); `ms()`, `us()`, `ns()` return `I128`; `add`, `sub`, `times`, `div`, `round`, `floor` return `!`; `checked_*` removed; `min()`, `max()`; `from_parts` returns `!` | std, medium: every reader and every printer |
| `std/time.rig` `Monotonic` | `at`, `add` panic past 292 years | readings within 0 to 146 years; `at` and `add` return `!` | small |
| `src/runtime.zig:4731` `durationInt`, `4740` `durationFloat`, `4751` `durationSum`, `4765` `durationNs` | build the one field; panic out of range | build the two fields; a checked twin of each that returns the error for the callee's set; `durationNs` clamps for the scheduler | 100, medium |
| `src/sema.zig:12233` `duration` | the form's unit and whether it is a `Float` | also how the form converts: total, folded into the callee's `!`, clamped in a wait, or refused (5.2), a positive list on the callee | 50, low |
| `src/typecheck.zig:12770` `checkDurationArg` | a run-time number accepted anywhere | a form that can fail refused where the callee cannot fail, a run-time `Float` refused in a wait, each with the fix of 5.2; a program's function whose error set cannot hold the failure refused the same way | 100, medium |
| `src/emit.zig:6021`, `9915` | `rig.durationInt(…)`, `rig.durationSum(…)` | `try` the checked twin where the form is folded, mapped to the callee's error | 50, medium: every form passes through it |
| `src/typecheck.zig:12603` `checkUnitIncrement` | a computed increment reaches a panic in the body | a computed increment on a `Time` refused; elsewhere it passes and the body fails `.invalid` | 30, low |
| `std/datetime/*.rig` | `add`, `round`, `floor` panic; `checked_add`; `from_unix`; `unix()` and `since` saturate; `now()`'s unreachable panic | the signatures of 7.2 and 7.8; `min()`, `max()`; no `panic(` | std, medium |
| `tools/jiff-oracle` | leaves out what saturates | answers it (12) | small |
| new test | (none) | no `panic(` in `std/time.rig` or `std/datetime/` (12) | small |
| `tools/migrate-tov.py` | (none) | the rows above (10.4), from the compiler's errors | medium |

- The duration-form rule is about 150 to 250 lines in the compiler; the rest is std and
  the migration.
- The bench guards and phase 0's `bench/duration` show the 16-byte layout's cost on the
  timing calls, as recorded in 5.1.

---

# 11. Phases

One pull request each, green on every gate before the next. The gates are Rig's own
(AGENTS.md): the core suite, the light gates of the two programs built with Rig (Trig
and loco), the bench guards, and, for a phase that changes the runtime (phase 1 does),
the checks on the Linux host. Each brings its own docs, CHANGELOG and HANDOFF lines,
and its own lines of the migration guide.

Phase 1 waits for one other change to merge first: the "loan vocabulary" rename of
Rig's ownership wording, which the owner has approved and which rewrites diagnostics in
the same compiler files.

0. **Measure** (built). No visible change. Its pull request holds the benchmark, the oracle,
   the generator, and the numbers as a record under `docs/history/records`.
   - The 16-byte `Duration` against an `Int`, with the benchmark of 5.1. The owner
     decides on the numbers.
   - The generator and its tables: size in a program, and build time, as a record and
     not a gate. The tables themselves are committed in phase 4.
   - The Jiff oracle (section 12).
1. **`std.time`** (built). `Duration` with its forms (one unit keyword), reading, arithmetic,
   `round` and `floor`, `from_parts` and `subsec_ns`, printing and parsing;
   `time.duration`; `Monotonic`; waiting; the compiler work of 10.1; the hook of 10.2
   with its first check.
   - `time.now()`, `time.Instant` and the constants are removed. `time.unix_ns()` stays
     for now, and the fix for `time.now()` names `time.monotonic()` and
     `time.unix_ns()`.
   - Rig's tree, its live docs and Trig's timing lines migrate.
   - 1b. Several unit keywords in one call.
2. **`Date`, `Time`, `DateTime`, `Weekday`** (built), with their text: the calendar math
   (Jiff's `jiff-core`), `add`, counts, `with`, `round`, `floor`, the helpers, ISO
   weeks. The positional checks.
3. **`Instant`** (built): `now`, `from_unix`, `unix`, `add`, `since`, `round`, `floor`,
   RFC 3339. `time.unix_ns()` is removed, its uses migrate (Rig's and Trig's), and the
   fix for `time.now()` names `datetime.now()`.

**[Owner, 2026-11-22] Then, before phase 4, in this order** (records/2026-11/datetime-strategy):

- **a. Error traces** (10.5, built), a language change of its own, so that a failure
  that leaves `main` says where it came from before more calls become fallible.
- **b. The constant-argument rule** (10.6, built), a language rule of its own.
- **c. Total or visible** (10.7, built; `records/2026-11/datetime-tov`): the 16-byte `Duration` with its `I128` readers; the
  duration-form rule (5.2); every signature of 7.2, `!` on each `add`, `round`, `floor`,
  `Monotonic.add` and `at`, and `Duration`'s arithmetic; `checked_*` removed; the Unix
  makers and readers of 7.8; `min()` and `max()`; `TimeZone.fixed`'s and
  `from_parts`' `!`; no `panic(` in std, with its test; the oracle's saturation
  exclusions dropped (12); and the migration of phases 1 to 3 in Rig's tree, its live
  docs and Trig (10.4).
- **d. The keyword-only rule**, decided separately.

Phases 4 to 6 are written to "Total or visible" from the start: `TimeZone.fixed` and
every `ZonedDateTime` `add`, `round`, `floor` and `start_of_day` return `!`, and nothing
in them panics.

4. **`TimeZone`** (built; `records/2026-11/datetime-phase4`): the tables, `named` and
   its literal check, `fixed`, `utc`, `parse`, `name`, `offset_at`, `zone_names`,
   `tzdb_version`, `local` (with `file.read_link`).
5. **`ZonedDateTime`** (built; `records/2026-11/datetime-phase5`): `in_zone` (from an
   `Instant`, a `DateTime` and a `Date`), the readers, `add`, counts, `with`,
   `start_of_day`, `round`, `floor`, `since`, RFC 9557, `today`.
6. **`format` and `try_format`**; then the teaching text in `docs/learn`.

Phase 1 puts section 2's sample into `docs/STD.md` as `rig pending` examples, and each
phase turns its own into tests. A doc example prints a fixed instant or a comparison,
never the current time (7.8).

**[Owner, 2026-11-22] No operators on `Duration`** (5.6), in v1 or after.

**Not in v1:** parsing by a format string, RFC 2822, locales, zone data loaded at run
time, the Windows zone-name mapping, other rounding modes, a keyword that rejects a
clamped month end.

---

# 12. Testing

- **Port Jiff's tests** for every behavior kept: 117 in `jiff-core`, 516 in `jiff`, 216
  in its `tests/` (mostly ports of Temporal's test262), and about 1,190 doc examples.
  The pull request that ports a file lists the tests it leaves out and why.
- **The oracle.** A small Rust program in `tools/`, built against the pinned Jiff that
  `gen-tzdb.py` fetches, with `default-features = false, features = ["std",
  "tzdb-bundle-always"]`, so that it uses the bundled `2026f` data and not the
  machine's. It reads generated inputs and prints Jiff's answers, which Rig's output
  must match line for line.
  - Its test skips where there is no Rust toolchain, as `test/cli/text_go.sh` does for
    Go. Jiff's answers are not committed.
  - It leaves out the cases where Rig differs from Jiff on purpose, in rounding (6.8).
    **[Owner, 2026-11-22]** Nothing else: with `Duration` in Jiff's 16 bytes, every
    `add` of a large duration, every `since` and every `unix()` is compared, and so
    are the failures, each where Jiff fails. The phase 3 ports left out for a
    `Duration`'s old range (`checked_arithmetic_at_max`,
    `nanosecond_roundtrip_boundaries`) are ported with the change of 10.7.
  - Generated inputs:
    - every date in a sample of years, against each month offset;
    - every zone, an hour either side of each transition;
    - every count, in both directions, on dates, on dates with times, and in zones;
    - parse and print round trips.
- **Pinned zone data.** A test of zone rules uses the generated test table (7.5), never
  whatever the embedded data says today. A test of a stored string whose offset no
  longer fits needs none: any offset that disagrees with the embedded rules will do.
- **Where Rig differs on purpose** (section 9) the oracle cannot check, so each is
  tested directly.
- **[Owner, 2026-11-22] No panic.** A test reads `std/time.rig` and every file of
  `std/datetime/` and finds no `panic(`, so the promise of "Total or visible" is one the
  suite checks. Each fallible call has a case at each end of its range that fails with
  the member 7.2 names, and each total one a case at its ends that does not fail.
- **Cases that must have a test:**

  | Case | Source |
  |---|---|
  | Spring forward (23 hours) and fall back (25 hours) in the US | Jiff `tz/timezone.rs:2879`, `zoned.rs:6349`, `6775` |
  | Apia skipping 2011-12-30 | Jiff `zoned.rs:6380` |
  | Lord Howe's 30-minute change | write |
  | Dublin and Morocco, flagged the other way round | Jiff's cases, on the pinned test table |
  | Jan 31 + 1 month; Feb 29 + 1 year; Jan 31 + 1 month + 1 day | Jiff `tests/tc39_262/civil/date/add.rs:64` |
  | `add(months: 1, days: -1)`; `add(days: 1, hours: -1)` | write |
  | `add(days: 0)` and `add(days: 0, hours: 1)` on a repeated time | write |
  | Counts in both directions: 2023-12-30T10:00 and 2024-03-01T00:00; 2023-11-30T09:00 and 2024-02-29T09:00; Denver 2026-03-07T02:30 and 03-08T03:00 | write |
  | Antarctica/Casey 2010-03-04T00:00+11 to 23:00+08: 26 hours and 0 days | write |
  | A Feb 29 birthday | write |
  | 24 hours 10 minutes across a repeated hour is 0 days | Jiff `zoned.rs:6361` |
  | Whole days and the rest, launch before and after the start, in every zone | write |
  | Counts across two zones | write |
  | `with` on the second of a repeated time keeps its offset | write |
  | `start_of_day`: São Paulo 2015-10-18, Azores 2026-10-25 | write |
  | Rounding: halves for each type, an instant before 1970, each increment rule, noon on a 23-hour and a 25-hour day, `Time` wrapping | write |
  | Zone equality and hashing: the six rows in 7.4 | write |
  | Monrovia: printing, and the 30-second trap | Jiff `tz/offset.rs:1966` |
  | A stored string whose offset no longer fits | write |
  | The ends of each range | Jiff `civil/date.rs:3566`, `timestamp.rs:1402` |
  | `TZ`: empty, a name, `:name`, a path, `UTC0`, `EST5`, a rule with daylight saving, nonsense | write |
  | Negative waits; a wait longer than an `Int` of nanoseconds; a run-time `Float` refused in a wait | write |
  | `Time.add` and `Time.round` wrapping; a computed increment refused on a `Time` and failing `.invalid` elsewhere | write |
  | `Monotonic`: `elapsed`, `since`, `add`, ordering, a deadline; `at` and `add` failing below 0 and past 146 years | write |
  | `Duration`: `min()` and `max()`; `neg` and `abs` of both; `add`, `times` and `round` failing past them; `div(0)`; `ms()`, `us()`, `ns()` of `max()` as `I128` | write |
  | Each duration form with a run-time number: total (`ms: t`), folded into a `!` (`i.add(minutes: t)!` failing), clamped in a wait, and refused elsewhere with its fix | write |
  | The constant-argument rule: each maker of 10.6 with constants (no `!`, and `!` refused), with one run-time argument (`!` required), and with a bad constant (a compile error) | write |
  | The Unix makers at the edges of 7.8, and each reader as the inverse of its maker | write |
  | `since` between the first and last instant, date and time; `unix()` of both | write |
  | `9999-12-31` plus a day, a renewal period from text, and `9999-12-30T22:00:00.9Z` rounded to the second each fail, not panic | write |
  | `add(years: 1, months: -12)` on Feb 29; `z.add(1, 2)` is refused | write |
  | Years, months and days between two dates, from Feb 29 | write |
  | A day's range: Havana 2026-03-08 (the day starts at 01:00), Nuuk from 2026-03-27T23:30, Apia 2011-12-30 (no such date); `d.in_zone` on 9999-12-31 fails in UTC and succeeds in Tokyo | write |
  | `floor` where the floored time is skipped: Lord Howe 2026-10-04T02:35, `floor(minutes: 20)` | write |
  | To `days: 1`: Havana 2026-03-08 at 12:45 and 18:00 (`round`); St. John's 2004-10-30T23:30-03:30 and Toronto 1919-03-31T00:45 (`floor`, `start_of_day`) | write |
  | `d.in_zone` on -9999-01-03 in a fixed zone of +25:59 fails | write |
  | The period index of a recurrence from 2027-01-31, on 02-27, 02-28, 04-30 and 05-31 | write |
  | `add(weeks: 1, days: -7)` on a repeated time; `.earlier` and `.later` on Denver's skipped 02:30 | write |
  | `round(minutes: 30)` on the first 01:50 in Denver on 2026-11-01 | write |
  | `nth_weekday` and `nth_weekday_of_month`: the next Monday from a Monday, a fifth Friday that does not exist, `n` of 0 | write |
  | A round that passes midnight in a year at or below 0 | write |
  | `floor` on each type, and on an instant before 1970 | write |
  | `TimeZone.parse`: the three offset forms, the refused ones, and `parse(tz.name())` for a named, a fixed and the UTC zone; `named("utc")` | write |
  | The four cases of text with a default zone (8.2), and `Z` | write |
  | Every cell of 8.1's table of what `Date`, `Time` and `DateTime` read | write |
  | `first_of_month`, `last_of_month`; `zone_names()`; `from_parts` and `subsec_ns`; `fixed(minutes: 330)` | write |
  | Every `format` directive on every type, in `format` and in `try_format` | write |

---

# 13. History

- **v1** (2026-11-16): the owner's design. He agreed to it except three items it marked
  open: the zoneless `DateTime`, operators on `Duration`, and where `Instant` lives.
- **v2** (2026-11-17): checked against Jiff's source and Rig's `origin/main`, then five
  review rounds, the last two with independent reviewers. The owner's decisions from
  those rounds are tagged [Owner] above.
- **v3** (this file): a clean rewrite. What changed from v2:
  - `Instant` and `now()` moved to `std.datetime`, and `time.now()` is removed;
  - `Monotonic` replaces `Stopwatch`;
  - spellings the language requires: `Date.new(…)!`, `time.duration(…)`,
    `TimeZone.utc()`, readers with parentheses;
  - counts are stated as Jiff computes them;
  - `start_of_day`, zero calendar amounts, rounding increments and halves, zone
    equality for fixed zones, and the recipe for whole units and the rest are
    corrected;
  - `TimeZone.parse`; the positional checks; `file.read_link`;
  - the compiler work is sized, and the summed unit keywords are their own change;
  - additions made in rounds 6 and 7 to close gaps a cold reader found, which the
    owner then approved: `floor`, the date helpers, `zone_names`, strict parsing, an
    infallible `start_of_day` (fallible since 2026-11-22), and two low-level members
    of `Duration`.
- **Rounds 6 to 8** reviewed v3 three ways each time: against Jiff, against Rig, and by
  a cold reader. Round 8 found no wrong answer, nothing unbuildable and no
  contradiction beyond one sentence about the ends of the range, which is corrected.
  Round 9 confirmed that correction and the other last edits.
- **Round 10**, after the owner approved the remaining items, was a full review again,
  with a second cold reader who had seen nothing. The design did not change. It
  corrected how rounding and flooring to a whole day are stated (6.7, 6.8), named one
  more deviation from Jiff there, replaced phase 0's benchmark plan (5.1), and settled
  some smaller wording. The reader who found the day-rounding errors then checked the
  corrected rules against Jiff over 11.1 million values.
- **Phase 0** (2026-11-20) measured `Duration`'s two layouts call by call. The owner
  first chose one `Int` of nanoseconds, as Go's, with `since` and `i.unix()`
  saturating beyond ±292 years.
- **Total or visible** (2026-11-22, `records/2026-11/datetime-strategy`). A question
  about `Instant.from_unix`, whose duration form panicked on a Unix number past 2262,
  went to two panels. The first (Rust, Zig and Go, API design) gave the Unix makers; a
  committee of three (a date-time library view, an error-handling view and Rig's
  compiler view) each chose, apart, that no call panics, and an independent rating
  scored the result. The owner approved the strategy and changed one of its
  decisions: `Duration` takes Jiff's 16 bytes, so `since` and `unix()` are total
  rather than fallible. The sections tagged [Owner, 2026-11-22] say what changed: the
  rule, 5.1 to 5.8, 6.2, 6.6 to 6.8, 7.2 to 7.4, 7.8, 9, 10.4 to 10.7, 11 and 12.
