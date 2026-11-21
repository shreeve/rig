# Rig `std.time` / `std.datetime`: an independent rating

Rated 2026-11-21 against Jiff, TC39 Temporal, java.time, Noda Time, chrono,
Go `time`, Python `datetime`/`zoneinfo` and Swift Foundation. It is rated
**as it would be with FINAL-STRATEGY ("total or visible") applied**. Where
the code built today differs, I say so.

What I read: the design (`docs/design/datetime.md`, v3), the code
(`std/time.rig`, `std/datetime/*.rig`, about 1,700 lines), the ten test
files (about 3,200 lines, 152 cases), the five phase records, and the
strategy. I also ran probes with `bin/rig run` and `RIG_STD` pointed at the
tree. (The `bin/rig` I was given was built before phase 3 merged, so it
needed the tree's std.)

Scope: phases 1 to 3 are built (durations, `Monotonic`, `Date`, `Time`,
`DateTime`, `Weekday`, `Instant`). Zones, `ZonedDateTime` and `format`
(phases 4 to 6) exist only in the design. So the zone and format scores
rate a design, not code.

## Scores

| Axis | Score | Why, and how it compares with the best on that axis |
|---|---|---|
| **Overall** | **8** | A small, carefully reasoned library. Where it is built it is verified more thoroughly than almost any of its peers. The hardest half (zones, DST and offset conflicts, formatting) is still a design, and the strategy's migration has not started. It would be a 9 if phases 4 to 6 land as designed and verified. Today, as built, it is about a 7. |
| Correctness | 9 | 891,707 oracle cases answered exactly as Jiff 1.0.0 answers them, with none different. Every one of the 7.3 million dates in the range is walked, and Jiff's tests and documentation examples are ported. It also found two real Jiff 1.0.0 bugs (rounding carry in years at or below 0; `round(days: 1)` on a day that starts at 01:00), and it diverges there on purpose. That is on par with Jiff and java.time. It loses a point only because the zone code, where most real bugs in date libraries live, is unbuilt. |
| Safety (no crashes, no silent wrong answers) | 9 with the strategy (7 today) | With the strategy, every call either cannot fail or returns `!`, nothing panics and nothing saturates. That is stricter than Jiff, which panics in its operators, and far stricter than Go, which saturates, or chrono. **Today** `since` and `unix()` saturate silently: 1500 to 2500 prints as `2562047h…`. A saturated `Int.min` then panics in `.neg()` (probed). `add` panics past 9999-12-31. The remaining risk is that users write `?? fallback` or `catch panic` to quiet the `!`. |
| API clarity and least surprise | 8 | There are few types. Calendar amounts are keywords that may differ in sign, counts are plain `Int`s, and every reader has a total and no "parts" trap. Compile errors catch `days:` on a duration, `Date.add(1)` and bad round increments. Noda Time and Temporal are clearer in two places. Here, `in_zone` has two meanings depending on the receiver: keep the instant, or keep the clock reading. Also, `dt.add(1)` is one *second*. The strategy adds `!` to every `add`, `since` and `round`, and the constant-argument rule makes whether a call needs `!` depend on whether its arguments are literals. |
| Completeness for real programs | 6 as designed (4 as built) | Missing: a span/period value (ISO `P1Y2M`/`P3D` are rejected, and y/m/d differences take a six-line recipe), parsing by format string, RFC 2822/HTTP dates, locales, ISO week-date values, Windows local zone, durations beyond ±292 years, and rounding modes beyond half-up and floor. java.time, Noda and Jiff cover all of these. Today there is no time zone at all, so "now in Denver" cannot be written. |
| Time-zone handling (as designed) | 8 | The design is excellent: `TimeZone` is a 4-byte plain index into an embedded 2026f tzdb (no refcount). It uses Temporal's "compatible" rule with an `.earlier`/`.later`/`.reject` resolve option. Offset conflicts are rejected by default, with keep-instant and keep-clock options. Gaps are found by comparing offsets, not the DST flag. A misspelled zone literal is a compile error, and zones are equal by primary ID. That matches Jiff and Noda. It loses points because the embedded data is as old as the binary, with no system or refreshable source. Also, `local()` fails on Windows and in containers whose `/etc/localtime` is a copy, and POSIX TZ rules with DST are not read. Noda and Jiff handle all three. |
| Text formats | 7 | Strong on what it covers. ISO 8601 for each type is strict: a `Date` rejects text with a time or offset, where Jiff silently drops them. It also has RFC 3339, RFC 9557 with annotations, ISO and friendly durations, and a designed strftime subset whose format string is checked at compile time. It has no strptime, RFC 2822, locales, two-digit years or widths. Jiff (`strtime` both ways, RFC 2822, friendly spans) and java.time (`DateTimeFormatter`) are well ahead. |
| Performance | 9 | Plain values with no allocation: `Date` is 4 bytes, `DateTime` 12, `Instant` 16, `ZonedDateTime` 24. It uses the Neri–Schneider day conversions and compact zone tables (111 KB against Jiff's 207 KB). A probe measured about 1 ns per `Date.add(days:)` or `add(months:)` and about 2 ns for add plus `months_since` (release build). That is on par with Jiff, chrono and Go, and well ahead of java.time, Python and Foundation. It loses a point because types with a `Print` don't pass in a register (a compiler limit, noted in the design). |
| Testing and verification | 9 | A differential oracle against a pinned Jiff (1.77 M generated cases, bundle-only tzdb proven with a poisoned `TZDIR`). Every deliberate deviation is listed and tested directly, with independent reviews each phase. This is deeper differential testing than Jiff itself has. Temporal's test262 is the other benchmark. Gaps: the ground truth is Jiff, so a model error shared with Jiff passes; there is no fuzzing of the parsers on arbitrary bytes; quickcheck properties are stood in for by the oracle; and phases 4 to 6 have no oracle answers yet. |

## Where the built code differs from the strategy

| Strategy | Code today |
|---|---|
| No `panic(` in std time code | 21 `panic(` sites: `add`, `round`, `floor`, `from_parts`, increments, `now()`; `Int` overflow in `Duration.add/sub/times/neg/abs` |
| `add` returns `!`; `checked_add` deleted | `add` panics, and `checked_add` is a twin |
| `since`, `unix()` return `Duration!` | They saturate at ±2^63 ns (silent wrong answer) |
| `Duration` range symmetric | Includes `Int.min`, so `neg`/`abs` of a saturated value panics |
| `from_unix_s/ms/us/ns/float` | One `from_unix(<duration form>)`, which panics past ±292 years; Unix seconds outside 1677–2262 can be read (`unix_s()`) but not turned back into an `Instant` |
| `min()`/`max()` by name | Absent |
| Computed bad round increment fails `.invalid` | It panics |
| `TimeZone.fixed`, `Duration.from_parts` return `!` | `from_parts` panics, and its `seconds * 1e9` overflow is a bare "integer overflow" |

## Three greatest strengths

1. **Verification.** A line-for-line oracle against a pinned Jiff, with
   zero differences over 891,707 answered cases, the whole date range
   walked, and every deviation from Jiff argued, listed and tested. It
   found two real bugs in Jiff 1.0.0. Few date libraries in any language
   can show this.
2. **The model is right and small.** It separates the monotonic clock,
   instants, wall-clock values and zoned values. There are no 24-hour
   "days" on an exact duration (a bug java.time, .NET and chrono shipped).
   Counts walk forward from the earlier value, so `a.days_since(b) ==
   -b.days_since(a)`. Calendar keywords can carry mixed signs. It is nine
   types where Jiff has 93.
3. **Errors are moved to compile time where possible.** These are compile
   errors: `days:` on a duration, `Date.add(hours: 1)`, a bad round
   increment, a misspelled zone literal, and (designed) a bad
   `format` string. Combined with "total or visible", a program the
   compiler accepts has no hidden date panics, which is stronger than any
   peer.

## Five most important weaknesses or risks (ranked)

1. **The hard half is unbuilt, and the error model is about to change
   under the built half.** Zones, DST resolution, offset conflicts,
   RFC 9557 zoned parsing, `local()`, and `format` with its compile-time
   check are where date libraries break. The strategy's migration
   rewrites every merged phase's signatures. These scores are partly a
   forecast.
2. **Choosing a one-`Int` `Duration` makes common calls fallible.** Under
   strict rules, `Instant.since`, `DateTime.since` and `unix()` return
   `!` on every call, though they fail only past ±292 years. Every `add`
   gains `!` too. The danger is that users write `?? d` or
   `catch panic` by habit, which brings back silent wrong answers and
   crashes. Jiff's 16-byte `SignedDuration` makes `since` total. Phase 0
   measured that layout at about 0–2 ns more per call.
3. **Errors are coarse.** `DateTimeError` is `invalid | range`, with no
   position, input or operation. Under strict rules that is all a user
   gets where today's panics name the value. Error traces are deferred to
   separate language work. Jiff's messages and java.time's
   `DateTimeParseException` (with index) are far more useful.
4. **No span/period value.** ISO 8601 calendar durations (`P1D`,
   `P1Y2M`), which appear in iCal, XML Schema, Postgres `interval`,
   YouTube and Azure APIs, are rejected. "2 years, 3 months, 4 days" is a
   recipe, not a call, and mixed amounts can't be rounded or formatted.
   Jiff `Span`, Temporal `Duration`, java.time `Period` and Noda `Period`
   all have one.
5. **Deployment gaps in zones and text.** The embedded tzdb ages with the
   binary, with no system or refreshable source. `local()` fails on
   Windows and on images with a copied `/etc/localtime`, which is common
   in Docker. POSIX TZ rules with DST are not read. There is no strptime,
   no RFC 2822 or HTTP-date parsing, and no locale. Real programs that
   ingest logs, emails or HTTP headers need these on day one.

Smaller things: `dt.add(1)` is one second. `in_zone` has two meanings. The
constant-argument rule makes `!` depend on whether arguments are literals.
Printed instants vary in width, so they don't sort as text (as in Jiff).

## What would raise it to a 10

1. **Build phases 4 to 6 to the design, against the oracle's existing
   zone cases**: every transition of all 598 names, both directions of
   every count, and `resolve:` and `conflict:` on each kind of day. Write
   them to "total or visible" from the start.
2. **Make the common path total.** Either use a 16-byte `Duration` so
   `since` and `unix()` cannot fail, or give `Instant.since` a result
   type that holds its whole range. Keep `!` for the operations that
   genuinely leave a range.
3. **Rich errors.** Errors should carry the operation, the input and
   (for parsing) the byte offset. Ship error-return traces before phase 4,
   as the strategy proposes.
4. **A calendar-amount value** (years, months, weeks, days, plus a
   `Duration`) that parses and prints ISO `P…` and feeds `add`, without
   Jiff's balancing machinery.
5. **Text breadth:** strptime with the same compile-time checking,
   RFC 2822 and HTTP dates, and widths and padding flags.
6. **Zone deployment:** an optional system or explicitly loaded tzdb (the
   one-way door is already kept open), reading `/etc/localtime` TZif
   bytes, POSIX TZ rules with DST, and the Windows zone mapping.
7. **Verification beyond Jiff:** fuzz every parser on arbitrary bytes
   (differentially against Jiff, with no crash allowed). Port Temporal's
   test262 cases for the zoned operations directly. Add a second oracle
   (java.time or Temporal's polyfill) for the zone phases, so a model
   error shared with Jiff is caught.
