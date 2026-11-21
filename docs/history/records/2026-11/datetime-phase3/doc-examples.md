# Jiff's documentation examples of `Timestamp`

Every example in the doc comments of Jiff 1.0.0's `src/timestamp.rs`
(88), by the line its code starts on and the item it documents: ported
to `test/rig/std-datetime-instant-ports.rig.test` (the case named), or
left out, and why. Jiff's `Timestamp` is Rig's `Instant`; its
`SignedDuration` and `Span` of hours and less are Rig's `Duration`.
Section numbers are docs/design/datetime.md's. Extracted from the source
at `misc/jiff` (tag 1.0.0).

Ported: 60, three of them in part. Left out: 28.

| Example | Item | Title | Status |
|---|---|---|---|
| `timestamp.rs:40` | `Timestamp` |  | ported: `docs: parsing and printing` |
| `timestamp.rs:52` | `Timestamp` |  | ported: `docs: parsing and printing` |
| `timestamp.rs:77` | `Timestamp` |  | ported: `docs: parsing and printing` |
| `timestamp.rs:92` | `Timestamp` |  | ported: `docs: parsing and printing` |
| `timestamp.rs:118` | `Timestamp` |  | ported: `docs: arithmetic` |
| `timestamp.rs:133` | `Timestamp` |  | ported: `docs: arithmetic` |
| `timestamp.rs:148` | `Timestamp` |  | ported: `docs: arithmetic` (the `Duration` in hours, its friendly form) |
| `timestamp.rs:165` | `Timestamp` |  | ported: `docs: arithmetic` (a `Duration`'s `floor` and `round`) |
| `timestamp.rs:200` | `Timestamp` |  | ported: `docs: round` |
| `timestamp.rs:235` | `Timestamp` |  | ported: `docs: parsing and printing` (its two parses; `in_tz` is phase 5) |
| `timestamp.rs:273` | `Timestamp` |  | ported: `docs: parsing and printing` |
| `timestamp.rs:290` | `Timestamp` |  | ported: `docs: parsing and printing` |
| `timestamp.rs:305` | `Timestamp` |  | left out: `in_tz`, a zone (phase 5) |
| `timestamp.rs:328` | `MIN` |  | ported: `docs: the ends of the range` (the first date and time under -25:59:59, read) |
| `timestamp.rs:344` | `MAX` |  | ported: `docs: the ends of the range` (the last under +25:59:59, read) |
| `timestamp.rs:385` | `now` |  | ported: `docs: made from Unix time` |
| `timestamp.rs:416` | `new` |  | ported: `docs: made from Unix time` |
| `timestamp.rs:432` | `new` | normalized sign | ported: `docs: Unix time read back` |
| `timestamp.rs:451` | `new` | limits | ported: `docs: Unix time read back` (from `since` of the floor) |
| `timestamp.rs:461` | `new` | limits | ported: `docs: the ends of the range` (its offset part left out: no offset type, §4.1) |
| `timestamp.rs:500` | `constant` |  | left out: a const fn: Rig's `from_unix(…)!` |
| `timestamp.rs:538` | `from_second` |  | ported: `docs: made from Unix time` |
| `timestamp.rs:559` | `from_second` | saturating construction | left out: a Unix time beyond ±292 years, which a duration form cannot write (§5.1) |
| `timestamp.rs:611` | `from_millisecond` |  | ported: `docs: made from Unix time` |
| `timestamp.rs:632` | `from_millisecond` | saturating construction | left out: a Unix time beyond ±292 years (§5.1) |
| `timestamp.rs:684` | `from_microsecond` |  | ported: `docs: made from Unix time` |
| `timestamp.rs:705` | `from_microsecond` | saturating construction | left out: a Unix time beyond ±292 years (§5.1) |
| `timestamp.rs:757` | `from_nanosecond` |  | ported: `docs: made from Unix time` |
| `timestamp.rs:778` | `from_nanosecond` | saturating construction | left out: a Unix time beyond ±292 years (§5.1) |
| `timestamp.rs:827` | `from_duration` |  | left out: `SystemTime`, Rust's |
| `timestamp.rs:848` | `from_duration` | out of bounds | left out: a duration beyond ±292 years (§5.1) |
| `timestamp.rs:874` | `from_duration` | saturating construction | left out: a duration beyond ±292 years (§5.1) |
| `timestamp.rs:916` | `as_second` |  | ported: `docs: Unix time read back` (`unix().seconds()`; `unix_s()` floors) |
| `timestamp.rs:945` | `as_millisecond` |  | ported: `docs: Unix time read back` |
| `timestamp.rs:974` | `as_microsecond` |  | ported: `docs: Unix time read back` |
| `timestamp.rs:1004` | `as_nanosecond` |  | ported: `docs: Unix time read back` |
| `timestamp.rs:1036` | `subsec_millisecond` |  | ported: `docs: Unix time read back` (from `subsec_ns()`) |
| `timestamp.rs:1068` | `subsec_microsecond` |  | ported: `docs: Unix time read back` (from `subsec_ns()`) |
| `timestamp.rs:1096` | `subsec_nanosecond` |  | ported: `docs: Unix time read back` |
| `timestamp.rs:1120` | `as_duration` |  | ported: `docs: Unix time read back` |
| `timestamp.rs:1165` | `signum` |  | ported: `docs: Unix time read back` (no `signum`: compared with 1970) |
| `timestamp.rs:1192` | `is_zero` |  | ported: `docs: made from Unix time` (no `is_zero`: compared with 1970) |
| `timestamp.rs:1231` | `in_tz` |  | left out: `in_tz`, a zone (phase 5) |
| `timestamp.rs:1244` | `in_tz` |  | left out: `in_tz`, a zone (phase 5) |
| `timestamp.rs:1258` | `in_tz` | errors | left out: `in_tz`, a zone name (phase 4) |
| `timestamp.rs:1289` | `to_zoned_datetime` |  | left out: a fixed zone (phase 4) and a zoned value (phase 5) |
| `timestamp.rs:1307` | `to_zoned_datetime` | POSIX time zone strings | left out: a POSIX rule as a zone, which Rig does not read (§7.7) |
| `timestamp.rs:1358` | `checked_add` |  | ported: `docs: arithmetic` |
| `timestamp.rs:1372` | `checked_add` | negative spans are supported | ported: `docs: arithmetic` |
| `timestamp.rs:1386` | `checked_add` | available via addition operator | ported: `docs: arithmetic` |
| `timestamp.rs:1400` | `checked_add` | error on overflow | ported: `docs: the ends of the range` (its sum of 175,307,616 hours and more is beyond a `Duration`, §5.1) |
| `timestamp.rs:1422` | `checked_add` | adding absolute durations | ported: `docs: arithmetic` |
| `timestamp.rs:1503` | `checked_sub` |  | ported: `docs: arithmetic` (`add` of the negation) |
| `timestamp.rs:1517` | `checked_sub` | use with [`SignedDuration`] and [`std::time::Duration`] | ported: `docs: arithmetic` (`add` of the negation) |
| `timestamp.rs:1561` | `saturating_add` |  | left out: saturating arithmetic, not in Rig (§7.2) |
| `timestamp.rs:1608` | `saturating_sub` |  | left out: saturating arithmetic, not in Rig (§7.2) |
| `timestamp.rs:1697` | `until` |  | ported: `docs: since` (in seconds) |
| `timestamp.rs:1716` | `until` | using bigger units | ported: `docs: since` (a `Duration` in hours) |
| `timestamp.rs:1741` | `until` | rounding the result | ported: `docs: since` (floored to the second) |
| `timestamp.rs:1788` | `since` |  | ported: `docs: since` |
| `timestamp.rs:1839` | `duration_until` |  | ported: `docs: since` |
| `timestamp.rs:1873` | `duration_until` | difference with [`Timestamp::until`] | left out: a span (§6.1) |
| `timestamp.rs:1909` | `duration_since` |  | ported: `docs: since` |
| `timestamp.rs:1964` | `round` |  | ported: `docs: round` |
| `timestamp.rs:1987` | `round` | changing the rounding mode | ported: `docs: round` (`Trunc` after 1970 is `floor`) |
| `timestamp.rs:2008` | `round` | rounding to the nearest 5 minute increment | ported: `docs: round` |
| `timestamp.rs:2049` | `series` | when to check a glucose monitor | ported: `docs: a series` (each anchored to the start) |
| `timestamp.rs:2104` | `strptime` |  | left out: `strptime`: no parsing by a format string (§8.4) |
| `timestamp.rs:2144` | `strftime` |  | left out: `strftime`: `format` is phase 6, on the zoned types |
| `timestamp.rs:2159` | `strftime` | errors are silently ignored | left out: `strftime` (phase 6) |
| `timestamp.rs:2170` | `strftime` | errors are silently ignored | left out: `strftime` (phase 6) |
| `timestamp.rs:2203` | `display_with_offset` |  | left out: `display_with_offset`: no offset type (§4.1); a zoned value prints its offset (phase 5) |
| `timestamp.rs:2255` | `impl Timestamp` |  | left out: a printed precision: `format`'s `%.3f` (phase 6) |
| `timestamp.rs:2303` | `impl Timestamp` |  | ported: `docs: parsing and printing` |
| `timestamp.rs:2319` | `impl Timestamp` | setting the precision | left out: a printed precision (phase 6) |
| `timestamp.rs:2596` | `impl std::time::SystemTime` |  | left out: `SystemTime`, Rust's |
| `timestamp.rs:2754` | `TimestampDisplayWithOffset` |  | left out: `display_with_offset` and a printed precision (phase 6) |
| `timestamp.rs:2852` | `TimestampArithmetic` |  | ported: `docs: arithmetic` |
| `timestamp.rs:2996` | `TimestampDifference` |  | ported: `docs: since` (a `Duration`'s `round`) |
| `timestamp.rs:3060` | `smallest` |  | ported: `docs: since` (a `Duration`'s `round`) |
| `timestamp.rs:3109` | `largest` |  | ported: `docs: since` (in seconds) |
| `timestamp.rs:3139` | `mode` |  | left out: the rounding mode `Ceil`, not in Rig (§6.8) |
| `timestamp.rs:3197` | `increment` |  | ported: `docs: since` (a `Duration`'s `round`, in minutes) |
| `timestamp.rs:3309` | `TimestampRound` |  | ported: `docs: round` |
| `timestamp.rs:3328` | `TimestampRound` |  | ported: `docs: round` (`Trunc` after 1970 is `floor`) |
| `timestamp.rs:3377` | `smallest` |  | ported: `docs: round` |
| `timestamp.rs:3408` | `mode` |  | left out: the rounding mode `Ceil`, not in Rig (§6.8) |
| `timestamp.rs:3454` | `increment` |  | ported: `docs: round` |
