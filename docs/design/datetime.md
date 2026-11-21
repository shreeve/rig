# Dates, times and zones for Rig: design brief, v3

Status: **final**, 2026-11-17, amended 2026-11-20 (`Duration` is one `Int`, 5.1).
Nothing in it is open: each decision is the owner's,
follows Jiff, or is forced by Rig. It was reviewed over ten rounds, and states the
design as it stands; the history is in section 13.

This file is the whole design. The reviews that led to it are in `reviews/`, kept as
evidence for its measurements; where one of them disagrees with this file, this file is
right. The earlier drafts, v1 and v2, are deleted.

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

Nothing is open. One thing is decided by a measurement and not by argument:
the layout of `Duration`, in phase 0 (5.1).

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
- **Errors:** a fallible function returns `T!` and the caller writes `f()!`. A panic is a
  bug in the program. `Int` overflow panics, in debug and release builds.
- **Language rules that decide spellings** (each verified by building Rig and running a
  probe; `reviews/builder-review*.md`):
  - An object is made by naming its fields, and a constructor cannot fail. A type with
    private fields is made by a static function: `Date.new(…)!`.
  - A type has no constants, and a module constant cannot be an object. So it is
    `TimeZone.utc()`, and a program's own constant holds a number (`TIMEOUT_S = 30`).
  - A method is always called with parentheses: `d.year()`.
  - There are no keyword-only parameters: a positional argument binds to the first
    parameter.
  - Two modules may not import each other, and a method is declared in the module that
    declares its type.
  - `when` is a reserved word. `in`, `with`, `add`, `sub`, `round` and `format` may all
    name methods.
  - A parameter default is a literal or a constant; an optional parameter is
    `x: T? = none`.
  - No local or parameter may reuse the name of an imported module, so with
    `use std.time` nothing else is called `time`. (That is why the module is
    `std.datetime` and not `std.date`.)
  - Arithmetic operators belong to built-in numbers only. Comparison comes from the
    `Eq`, `Ord` and `Hash` APIs, which any type may have.
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

  # Now, in a zone
  denver = datetime.TimeZone.named("America/Denver")!
  z = datetime.now().in_zone(denver)
  print(z)               # 2026-11-17T08:07:03.512094-07:00[America/Denver]
  print(z.date(), z.weekday())                     # 2026-11-17 Tuesday

  # A day later on the clock, and exactly 24 hours later
  print(z.add(days: 1))
  print(z.add(hours: 24))

  # Calendar math
  due = datetime.Date.new(2027, 1, 31)!.add(months: 1)    # 2027-02-28
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
| `time.Duration` | a duration form (5.2); `time.duration(…)`; `Duration.parse(s)!`; `Duration.from_parts(s, ns)` | `hours()` `minutes()` `seconds()` `ms()` `us()` `ns()`, `float_seconds()`, `subsec_ns()`, `iso()` | `add` `sub` `times` `div` `neg` `abs` `round` `floor`, and `checked_add` `checked_sub` `checked_times` | `Eq` `Ord` `Hash` |
| `time.Monotonic` | `time.monotonic()`; `Monotonic.at(…)` | `elapsed()` | `add(…)` | `since`; `Eq` `Ord` `Hash` |
| `datetime.Instant` | `datetime.now()`; `Instant.from_unix(…)!`; `Instant.parse(s)!` | `unix()` `unix_s()` | `add(…)` `checked_add(…)!` `round(…)` `floor(…)` `in_zone(tz)` | `since`; `Eq` `Ord` `Hash` |
| `datetime.Date` | `Date.new(y, m, d)!`; `Date.parse(s)!`; `datetime.today(tz)` | `year()` `month()` `day()` `weekday()` `day_of_year()` `days_in_month()` `iso_week()` `iso_week_year()` | `add(…)` `checked_add(…)!` `with(…)!` `at(t)` `in_zone(tz)!` `first_of_month()` `last_of_month()` `nth_weekday(n, w)!` `nth_weekday_of_month(n, w)!` | the counts (6.4); `Eq` `Ord` `Hash` |
| `datetime.Time` | `Time.new(h, m, s, ns)!`; `Time.parse(s)!` | `hour()` `minute()` `second()` `nanosecond()` | `add(…)` (wraps) `checked_add(…)!` `with(…)!` `round(…)` `floor(…)` | `since`; `Eq` `Ord` `Hash` |
| `datetime.DateTime` | `DateTime.new(y, m, d, h, mi, s, ns)!`; `date.at(t)`; `DateTime.parse(s)!` | `date()` `time()`, and the readers of both | `add(…)` `checked_add(…)!` `with(…)!` `round(…)` `floor(…)` `in_zone(tz, …)!` | `since`; the counts; `Eq` `Ord` `Hash` |
| `datetime.TimeZone` | `named(s)!` `fixed(hours:, minutes:)` `utc()` `parse(s)!`; `datetime.local()!` | `name()` `offset_at(i)` | | `Eq` `Hash` |
| `datetime.ZonedDateTime` | `i.in_zone(tz)`; `dt.in_zone(tz, …)!`; `ZonedDateTime.parse(s, …)!` | `instant()` `datetime()` `date()` `time()` `zone()` `offset()` `offset_text()`, and the readers of a date and a time | `add(…)` `checked_add(…)!` `with(…)!` `in_zone(tz)` `start_of_day()` `round(…)` `floor(…)` | `since`; the counts; by instant: `Eq` `Ord` `Hash` |
| `datetime.Weekday` | `.monday` … `.sunday` | `iso_number()` | | `Eq` `Ord` `Hash` |

`format("…")` and `try_format(s)!` are on `Date`, `Time`, `DateTime` and `ZonedDateTime`
(8.4).

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
- `time.unix_ns()` is removed, with the fix `datetime.now().unix().ns()`. **[Rig]** It
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
  Their type names are the builder's (say `datetime.Resolve` and `datetime.Conflict`).
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

**[Owner, 2026-11-20]** One `Int` of nanoseconds, as Go's `time.Duration`. It occupies
8 bytes, and its range is ±292 years: from 1970, the years 1677 to 2262. `sleep`,
`elapsed()` and the scheduler's calls underneath all speak the same `Int`.

- **This differs from Jiff**, whose duration is whole seconds and nanoseconds in 16
  bytes, with a range of ±292 billion years. Phase 0 measured both, call by call
  (`records/2026-11/datetime-phase0`): the 16 bytes cost about 1.9 ns more on
  `elapsed()` and 0 to 0.3 ns elsewhere. The owner chose the one `Int` for its
  simplicity.
- **What the range leaves out**, met as Go meets it:
  - `a.since(b)` between values more than 292 years apart **saturates** at the
    largest or smallest `Duration` (6.6).
  - `i.unix()` saturates the same way outside the years 1677 to 2262, and
    `i.unix_s()` gives the whole seconds exactly at any instant (7.8).
  - The calendar types' own arithmetic, `add(days:)`, `add(months:)` and the counts,
    never goes through a `Duration`, so the full range of years is unaffected.
- `Duration`'s own arithmetic (`add`, `times`, and the rest) panics when it leaves the
  range, as every `Int` does (7.2). Only `since` and `unix()` saturate.

## 5.2 Duration forms

Wherever a parameter is typed `Duration`, a call gives it in one of these forms.

- **[Owner]** A bare number is **seconds**, an `Int` or a `Float`: `sleep(90)`,
  `z.add(0.5)`. This holds on `add` for `DateTime`, `ZonedDateTime` and `Time` too, so
  `dt.add(1)` is one second, not a day; the owner considered requiring a unit there and
  kept bare seconds. The docs for those `add`s show `add(days: 1)` beside it.
- A unit keyword: `ns:`, `us:`, `ms:`, `seconds:`, `minutes:`, `hours:`.
- **[Owner]** Several unit keywords add up, each unit at most once:
  `add(hours: 1, minutes: 30)`. This lands as its own change after the rest (section
  11, phase 1b); until then a call takes one unit keyword.
  - Signs may differ, and the parts simply add: `hours: 1, minutes: -30` is 30 minutes.
  - An `Int` part is exact. A `Float` part is rounded to the nanosecond, half away from
    zero. Then the parts are added; a sum too large for a `Duration` panics.
- A bare number together with a unit keyword is rejected.
- A value that is already a `Duration` passes as it is. `ms: d` with `d` a `Duration`
  is rejected.
- **No days or weeks.** `days:` or `weeks:` where a `Duration` is taken is a compile
  error. Its fix fits the place: `hours: 24` for a wait, `add(days:)` on a value with a
  date, and `i.in_zone(tz).add(days: 1)` for an `Instant`. A day is not always 24 hours,
  and libraries that put 24-hour days on an exact length have shipped that bug: Java's
  `Duration.ofDays`, C#'s `TimeSpan.FromDays`, chrono's `Duration::days`. (The error
  fires only when the function called has no parameter of its own named `days`.)
- A number that is not finite, or too large for a `Duration`, is a compile error when it
  is a constant and a panic otherwise.
- **`time.duration(<form>) -> Duration`** makes a standalone value:
  `time.duration(ms: 250)`, `time.duration(5)`.
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

- **Totals only**, each an `Int`, truncated toward zero: `hours()`, `minutes()`,
  `seconds()`, `ms()`, `us()`, `ns()`.
  - -1.5 seconds has `seconds()` of -1, not -2.
  - Every total fits an `Int`: `ns()` is the representation itself.
- `float_seconds() -> Float` (spelling).
- **No "parts" accessors**, with the one low-level exception in 5.4. C#'s `.Minutes` and
  Python's `.seconds` are a known trap:
  `timedelta(days=1, seconds=5).seconds` is 5.

## 5.4 Arithmetic

- `add(d)`, `sub(d)`, `times(n: Int)`, `div(n: Int)` (truncating toward zero), `neg()`,
  `abs()`.
- Overflow panics, as `Int` arithmetic does, and so does `div(0)`. `checked_add`,
  `checked_sub` and `checked_times` fail instead.
- `round(…)` and `floor(…)` are in 6.8.
- **[Owner] Two low-level members**, because `std.datetime` is another module and
  cannot see the fields (spelling; they are named so that nobody takes one for a
  total):
  - `d.subsec_ns()`: the part below a whole second, with the duration's sign;
  - `Duration.from_parts(seconds, ns)`: the two must agree in sign and `ns` must be
    within ±999,999,999, or it panics.

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

**[Owner]** Yes, as a later change of its own, after phase 6: `+` and `-` between
durations, unary `-`, and `*` and `/` by an `Int`, for `Duration` only.

- Nothing in this design needs them: timing is `start.elapsed()`, and comparison comes
  from `Ord`. Until they land, totals and averages are `total = total.add(d)` and
  `total.div(n)`.
- They are a language change, since arithmetic operators belong to built-in numbers,
  and are designed and reviewed as one.

## 5.7 The monotonic clock

**[Owner]** `time.monotonic() -> Monotonic` reads the monotonic clock, which never goes
back. It is today's `Instant`, renamed, and giving durations.

- `m.elapsed() -> Duration`: from the reading to now.
- `m.since(earlier) -> Duration`: between two readings; negative when `earlier` is the
  later one.
- `m.add(<duration form>) -> Monotonic`: a deadline. `rekey = start.add(120)`, and later
  `time.monotonic() >= rekey`.
- `Monotonic.at(<duration form>)`: a reading a duration after the clock's zero, for a
  test or for code that is handed the time.
- `Eq`, `Ord` and `Hash`. It is one `Int` of nanoseconds and passes as a word. What
  `print` shows is not meaningful.
- `add` and `at` panic when the result does not fit: more than 292 years.
- `time.since_start() -> Duration`: the time since the program started.
- Under the deterministic scheduler all of these are virtual.
- A `Monotonic` and an `Instant` are different types in different modules, so the two
  clocks cannot be mixed.

## 5.8 Waiting

- `time.sleep(d)!`, `time.within(d, f)!` and the `time.after(d)` select arm take a
  duration form.
- **[Owner]** A negative constant given to one of these is a compile error. A negative
  value at run time counts as zero: `sleep` returns at once, as it does today, and a
  `within` or `after` is already due.
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
- A duration longer than an `Int` of nanoseconds waits as long as the scheduler can
  (it does not panic).

---

# 6. Calendar arithmetic (`std.datetime`)

## 6.1 No span type

**[Judgment]** Calendar amounts are keywords, and calendar differences are `Int`
counts.

- `z.add(days: 1)`, `d.add(months: 1, days: 3)`, `d.days_since(other)`.
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

- **The signatures:**
  - `Date`: `add(years: 0, months: 0, weeks: 0, days: 0)`, by keyword only.
  - `DateTime` and `ZonedDateTime`: `add(d: Duration? = none, years: 0, months: 0,
    weeks: 0, days: 0)`. The duration form comes first, so `z.add(0.5)` is half a
    second, `z.add(hours: 2)` is two hours, and `z.add(days: 1, hours: 2)` is both.
  - `Time`, `Instant` and `Monotonic`: `add(d: Duration)`.
  - Each `checked_add` takes the same arguments.
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
- **Amounts may be negative.** `d.add(months: -1)`; Mar 31 - 1 month is Feb 28 or 29.
  None of these types has a `sub`; only `Duration` does.
- **[Judgment] Signs may differ between the groups**, each applied in order with its own
  sign: from the 1st of a month, `d.add(months: 1, days: -1)` is that month's last day,
  and `z.add(days: 1, hours: -1)` is an hour short of the same time tomorrow. Jiff
  cannot answer this: its span has one sign for all units.
- **Recurrences anchor to the start:** the k-th is `start.add(months: k)`. Stepping
  from the previous result drifts (Jan 31, Feb 28, Mar 28).
- `add` panics when the result of any of the three groups leaves the type's range, and
  `checked_add` fails instead (7.2). That includes amounts too large to sum:
  `d.checked_add(years: n)!` fails for an `n` whose months overflow an `Int`.
- **On a `Date`:**
  - `d.add(1)` is a compile error with the fix `add(days: 1)` (10.2).
  - `d.add(hours: 1)` is a compile error that says a date has no time of day. (Jiff
    accepts it and adds the whole days.)
- **On a `DateTime`:** every day is 24 hours, since there is no zone.
- **On a `Time`:** `add` **wraps past midnight**: 23:00 + 2 hours is 01:00.
  `checked_add` fails on a wrap.

## 6.3 Adding to a `ZonedDateTime`

**[Jiff]** (`zoned.rs:2339-2372`)

1. Add years and months, then weeks and days, to the date and time **on the clock**.
2. Turn that into an instant once, by the "compatible" rule (6.5).
3. Add the exact duration **on the timeline**.

- When the months (years × 12 + months) and the days (weeks × 7 + days) both come to
  zero, steps 1 and 2 are skipped and the value's instant is used as it is. (Otherwise
  `z.add(days: 0)`, or `z.add(weeks: 1, days: -7)`, on the second of a repeated time
  would move it back an hour.)
- `z.add(days: 1)` lands at the same time on the clock, or just after a skipped one.
  `z.add(hours: 24)` is exactly 24 hours. On a 23-hour day they differ by an hour.
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
  if start.add(months: k + 1) <= today
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
rest = late.since(early.add(days: n))      # never negative
```

For years, months and days as well, go on from `n`, and split the two **dates**:

```
d0 = early.date()
d1 = d0.add(days: n)
m = d1.months_since(d0)
years = m / 12
months = m % 12
days = d1.days_since(d0.add(months: m))
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

- `a.since(b) -> Duration` is exact within ±292 years, and beyond them saturates at
  the largest or smallest `Duration`, as Go's `Sub` does (5.1). It is defined on
  `Instant`, `DateTime`, `ZonedDateTime` and `Monotonic`. For two `ZonedDateTime`s the zones may differ. For a `DateTime` every
  day is 24 hours.
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
  value (`Date.new(2024, 2, 29)!.with(year: 2023)` fails):
  - `Date`: `year:`, `month:`, `day:`;
  - `Time`: `hour:`, `minute:`, `second:`, `ns:`;
  - `DateTime` and `ZonedDateTime`: all of those.
  - A positional argument is a compile error (10.2).
- **The start of a date `d` in a zone** is 00:00 on `d`, turned into an instant by
  "compatible". That is the first instant of the day, which is not always 00:00. In São
  Paulo on 2015-10-18 it is 01:00. In the Azores on 2026-10-25, when 00:00 to 00:59
  happens twice, it is the first 00:00.
  - One day in the data is an exception, as in Jiff: Toronto on 1919-03-31, where the
    clock went from 23:30 to 00:30. The start is 01:00, though 00:30 to 00:59 exist.
- **`z.start_of_day()`** is the start of `z`'s own date.
  - **[Owner]** It cannot fail. It panics only at the very end of the range, as
    `add` does. (Jiff's returns an error there.)
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
  to = d.add(days: 1).in_zone(z.zone())!
  ```

  - On the last date, 9999-12-31, `add` panics; a program that stores it as "no end"
    tests for it first or uses `checked_add`.
  - These ranges cover the timeline with no gap and no overlap. Where a repeated time
    crosses midnight, a date comes back after the next has begun, so a value can lie
    outside its own date's range: St. John's each autumn from 1987 to 2010, after 00:01
    went back to 23:01.
  - Two shorter ways are wrong:
    - `z.add(days: 1).start_of_day()` skips a day where a late-evening time is skipped
      the next day: in Nuuk, from 2026-03-27T23:30 it gives the 29th.
    - `z.start_of_day().add(days: 1)` is an hour late on a day that did not start at
      midnight: Havana on 2026-03-08, Beirut, Cairo, Santiago.
- **`datetime.today(tz) -> Date`** is `datetime.now().in_zone(tz).date()`.
- **[Owner] Four helpers on a `Date`**, each Jiff's:
  - `d.first_of_month()` and `d.last_of_month()`;
  - `d.nth_weekday(n, w)!` counts from `d`: the `n`-th `w` after it, or before it when
    `n` is negative. `d.nth_weekday(1, .monday)!` is the next Monday, never `d` itself.
    It fails for `n` of 0 and for a result outside the range.
  - `d.nth_weekday_of_month(n, w)!` counts within `d`'s month, from its end when `n` is
    negative: the fourth Thursday of November is
    `Date.new(2026, 11, 1)!.nth_weekday_of_month(4, .thursday)!`, the 26th. `n` is 1 to
    5 or -1 to -5; it fails for any other `n` and when the month has no such day.
- **[Owner] `datetime.zone_names()`** gives all 598 names, old spellings included,
  as a static list of static text sorted by name, for a list a person picks from.

## 6.8 Rounding

**[Jiff]** except where marked.

- `round(…)` takes exactly one unit keyword and its increment, an `Int`:
  `round(minutes: 15)`, `round(seconds: 1)`. It is not a duration form, and a positional
  argument is a compile error.
- `datetime.now().round(seconds: 1)` is how an instant prints without a fraction.
- **Which increments**, each from 1 to 1,000,000,000:

  | Type | Units | The increment |
  |---|---|---|
  | `Duration` | `ns:` to `hours:` | any |
  | `Instant` | `ns:` to `hours:` | must divide 24 hours |
  | `Time` | `ns:` to `hours:` | must divide the next larger unit and be smaller than it |
  | `DateTime`, `ZonedDateTime` | `ns:` to `hours:`, and `days: 1` | as for a `Time` |

- A bad increment is a compile error when it is a literal and a panic otherwise.
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
- `Time.round` wraps: 23:59:59.6 rounds to 00:00:00. The others panic when the result
  leaves the range.
- **A round that passes midnight carries into the next day, in every year.** Jiff 1.0.0
  does not for years at or below 0 (`civil/datetime.rs:3582` and `3590` multiply the
  carried day by the sign of the year; measured: 23:30 in year 0 rounds to 00:00 of the
  same day). Rig does not copy that, and the oracle is not used for those cases.
- **[Owner] `floor(…)`** takes the same argument and goes to the multiple at or
  before the value: `z.floor(minutes: 15)`, `i.floor(hours: 1)`. For a `Duration` that
  is toward negative infinity. Truncating is the commoner need (Go's `Truncate`, Java's
  `truncatedTo`), and without it the only way is `with`, which is fallible. It is Jiff's
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

## 7.2 What fails, and what panics

- **Building a value from parts or text is fallible:** `Date.new`, `Time.new`,
  `DateTime.new`, every `parse`, `Instant.from_unix`, `with`, `dt.in_zone`, `d.in_zone`,
  `nth_weekday`, `nth_weekday_of_month`, `TimeZone.named`, `TimeZone.parse`,
  `datetime.local`, `try_format`.
  - `Date.new(year, month, day)`.
  - `Time.new(hour, minute, second = 0, ns = 0)`.
  - `DateTime.new(year, month, day, hour = 0, minute = 0, second = 0, ns = 0)`.
  - `Time.new(23, 59, 60)` fails; only parsing reads `:60` as `:59`.
- **[Owner] `add` panics when the result leaves the range**, as `Int` overflow does,
  and `checked_add` fails instead. Jiff's operators panic the same way. Text and parts
  from a user are checked where they come in, so reaching the panic takes arithmetic
  that walks past the year 9999. (`Time.add` wraps instead.)
- **The complete list of panics:**
  - arithmetic that leaves a type's range:
    - `add`, `round`, `floor` and `start_of_day` on `Instant` and the calendar types,
      at the end of the range;
    - `Monotonic.add` and `at`, beyond 292 years;
    - `Duration`'s `add`, `sub`, `times`, `div`, `neg`, `abs`, `round` and `floor`;
  - `Duration.div(0)`;
  - a duration form given a number that is not a constant and is not finite or is out
    of range, or parts whose sum is (5.2);
  - `TimeZone.fixed` given arguments that are not literals and are out of range or of
    mixed sign (7.4), and `Duration.from_parts` given bad parts (5.4);
  - `round` or `floor` given an increment that is not a literal and is not allowed
    (6.8).
- A program that takes a number from a user checks it before it reaches one of these.
  `Instant.from_unix(x)!` with a `Float` from a user is a case: a value outside the
  range fails, and one that is not finite panics.

## 7.3 Sizes

Measured on a stand-in built with Rig.

| Type | Bytes |
|---|---|
| `Weekday` | 1 |
| `Date`, `TimeZone` | 4 |
| `Monotonic` | 8, and it passes as a word |
| `Time` | 8 |
| `DateTime` | 12 |
| `Duration` | 8 |
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
    as its fix.
  - `named("UTC")`, in any case, returns `utc()` (Jiff does the same).
- **`TimeZone.fixed(hours:, minutes:)`**
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
  - Out of range, or mixed signs: a compile error for literals, a panic otherwise.
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
- **`tz.offset_at(i: Instant) -> Duration`**
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
- **What a program pays:** nothing unless it uses a `TimeZone` or a `ZonedDateTime`. A
  program that uses only `Date` grows by about 1 KB (measured). One that uses a zone
  carries the tables, about 210 KB of data before the table layout is settled.
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
     `EST5`, `<+08>-8`. Not after a `:`, which marks a name;
   - anything else fails. A set `TZ` never falls through to the files below.
2. Otherwise, the name the `/etc/localtime` link points at, cut the same way (macOS
   points it at `/var/db/timezone/zoneinfo/America/Denver`).
3. Otherwise, the name in `/etc/timezone`.
4. Otherwise it fails, with a message that names `TZ`.

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
- **`Instant.from_unix(<duration form>)!`** is the instant that long after
  1970-01-01T00:00Z: `Instant.from_unix(1_700_000_000)!`, or
  `Instant.from_unix(ms: t)!` for a JavaScript time. It fails outside the range.
  - A `Float` near 1.7e9 resolves only about 240 ns, so a Unix time finer than a
    microsecond is given with `us:` or `ns:`.
- **`i.unix() -> Duration`**, negative before 1970. Then `i.unix().seconds()`, `.ms()`.
  - `.seconds()` truncates toward zero, so half a second before 1970 is 0, not -1.
  - Outside the years 1677 to 2262 it saturates, as `since` does (5.1).
- **`i.unix_s() -> Int`**: the whole seconds since 1970, floored, exact at any instant.
  It is the count Unix tools give.
- `i.add(<duration form>)`, `i.checked_add(…)!`, `i.since(other)`, `i.round(…)`,
  `i.floor(…)`, `i.in_zone(tz)`.
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
   positional argument to `add`, `checked_add`, `with`, `round`, `floor` or `fixed` where
   10.2 forbids one, `Date.add(hours: 1)`, a misspelled zone
   name, a bad `format` string, a bad rounding increment, a bad `fixed`.
10. **Fixed zones** take whole minutes, and `fixed` panics on a bad argument that is not
    a literal, where Jiff returns an error (7.4).
11. **`TimeZone` hashes** (7.4), and **`Weekday` orders**, from Monday (4.1). Jiff's do
    neither.
12. **`Instant.round`** takes a half to the later value before 1970 too (6.8).
13. **`ZonedDateTime.parse(s, default_zone:)`** (8.2), and `Z` read by
    `TimeZone.parse` (7.4).
14. **A round that passes midnight** carries into the next day in years at or below 0,
    where Jiff 1.0.0 has a bug; and **`round(days: 1)`** measures to the next day's
    start, where Jiff 1.0.0 measures to the start plus a day on the clock (6.8).
15. **`Date`, `Time` and `DateTime` read only their own form** (8.1), and
    `start_of_day` cannot fail (6.7).
16. **Fewer things:** no offset type, no daylight-saving flag, only two rounding modes,
    no parsing by format string, fewer `format` directives.
17. **`Duration` is one `Int` of nanoseconds** (5.1), where Jiff's is 16 bytes: `since`
    beyond ±292 years and `i.unix()` outside the years 1677 to 2262 saturate, as Go's
    do, and `i.unix_s()` gives Unix seconds.

---

# 10. Compiler and std work

Line numbers were read from `origin/main` on 2026-11-17 and need checking again when
the work starts. Sizes are the builder reviewer's estimates.

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
| No positional argument to `Date.add`, any `with`, or `TimeZone.fixed`; at most one to `DateTime.add` and `ZonedDateTime.add` (so `z.add(1, 2)` is not a second and two years). The same for each `checked_add` | 40 | 2 |
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
- A keyword-only parameter in the language would replace the positional checks. It is
  a separate proposal, outside this work.

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
  - `std.time`: bad text (`Duration.parse`), out of range (`checked_add`,
    `checked_sub`, `checked_times`).
  - `std.datetime`: out of range, bad text, unknown zone, a skipped or repeated time
    under `.reject`, an offset conflict, no system zone, a bad format string
    (`try_format`).
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

0. **Measure.** No visible change. Its pull request holds the benchmark, the oracle,
   the generator, and the numbers as a record under `docs/history/records`.
   - The 16-byte `Duration` against an `Int`, with the benchmark of 5.1. The owner
     decides on the numbers.
   - The generator and its tables: size in a program, and build time, as a record and
     not a gate. The tables themselves are committed in phase 4.
   - The Jiff oracle (section 12).
1. **`std.time`.** `Duration` with its forms (one unit keyword), reading, arithmetic,
   `round` and `floor`, `from_parts` and `subsec_ns`, printing and parsing;
   `time.duration`; `Monotonic`; waiting; the compiler work of 10.1; the hook of 10.2
   with its first check.
   - `time.now()`, `time.Instant` and the constants are removed. `time.unix_ns()` stays
     for now, and the fix for `time.now()` names `time.monotonic()` and
     `time.unix_ns()`.
   - Rig's tree, its live docs and Trig's timing lines migrate.
   - 1b. Several unit keywords in one call.
2. **`Date`, `Time`, `DateTime`, `Weekday`**, with their text: the calendar math
   (Jiff's `jiff-core`), `add`, counts, `with`, `round`, `floor`, the helpers, ISO
   weeks. The positional checks.
3. **`Instant`**: `now`, `from_unix`, `unix`, `add`, `since`, `round`, `floor`, RFC
   3339. `time.unix_ns()` is removed, its uses migrate (Rig's and Trig's), and the fix
   for `time.now()` names `datetime.now()`.
4. **`TimeZone`**: the tables, `named` and its literal check, `fixed`, `utc`, `parse`,
   `name`, `offset_at`, `zone_names`, `tzdb_version`, `local` (with `file.read_link`).
5. **`ZonedDateTime`**: `in_zone` (from an `Instant`, a `DateTime` and a `Date`), the
   readers, `add`, counts, `with`, `start_of_day`, `round`, `floor`, `since`, RFC 9557,
   `today`.
6. **`format` and `try_format`**; then the teaching text in `docs/learn`.

Phase 1 puts section 2's sample into `docs/STD.md` as `rig pending` examples, and each
phase turns its own into tests. A doc example prints a fixed instant or a comparison,
never the current time (7.8).

**After v1, as its own change:** operators on `Duration` (5.6).

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
  - It leaves out the cases where Rig differs from Jiff on purpose: in rounding (6.8),
    and a `since` or `unix()` beyond `Duration`'s ±292 years, which saturates (5.1).
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
  | Negative waits; `Time.add` wrapping and `checked_add` | write |
  | `Monotonic`: `elapsed`, `since`, `add`, ordering, a deadline | write |
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
    infallible `start_of_day`, and two low-level members of `Duration`.
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
  chose one `Int` of nanoseconds, as Go's, over Jiff's 16 bytes: `since` and
  `i.unix()` saturate beyond ±292 years, and `i.unix_s()` gives Unix seconds at any
  instant (5.1, 6.6, 7.3, 7.8).
