# Making an `Instant` from a Unix time: design panel report

Language and library design (least surprise, error handling, date-time APIs).
Read: rig `AGENTS.md`, `docs/design/datetime.md` §5.1, §5.2, §7.1, §7.2, §7.8, §10.2,
`std/datetime/instant.rig`, `SPEC.md` "Numeric conversions" (main e38454865); Jiff
1.0.0 `crates/jiff/src/timestamp.rs` and `signed_duration.rs`; chrono 0.4.45
`src/datetime/mod.rs`; Go 1.27.3 `src/time/time.go`. Probes run with `bin/rig run`
(`RIG_STD=std`, since the built binary lacks `Instant`).

## 0. What the probes show

| Program | Result |
|---|---|
| `Instant.from_unix(10_000_000_000)` (constant) | compile error: "`10_000_000_000` seconds is more nanoseconds than a `Duration` holds" |
| `from_unix(x)`, `x = text.parse_int("10000000000")!` (year 2286) | panic: `a duration is more nanoseconds than a Duration holds` (`runtime.zig:4732`), naming neither `from_unix` nor the number |
| `from_unix(ms: 9_300_000_000_000_000)` read from text (year 2264) | the same panic |
| `from_unix(f)`, `f = text.parse_float("nan")!` | panic: `a duration is not a finite number of nanoseconds a Duration holds` |
| `i.checked_add(ms: ms) catch i`, `ms` read from text, out of range | **panics** (the form is converted before the call, so `checked_add` never sees it) |
| `from_unix(1_700_000_000.000_000_1)` | `2023-11-14T22:13:20Z`: the 100 ns is lost in the `Float` |
| `hi = parse("9999-12-30T22:00:00Z")!; hi.unix_s()` | `253402207200`, and no function turns it back into `hi` |

So today: (a) a Unix number from outside the program can stop it, with a message that
does not say where; (b) nothing makes an instant past 2262 or before 1677 from a number,
though the type holds -9999 to 9999 and `unix_s()` reads them; (c) a function named
`checked_` panics on its argument.

## 1. Should it be fallible?

**Yes.** The owner's reasoning is right about the function he has: every `Duration` is
an instant in range, so `Duration -> Instant` cannot fail, and a `!` on it would be a
lie. The trouble is that the call a newcomer writes is not `Duration -> Instant`; it is
`number -> Instant`, and the number-to-`Duration` step in front of it is where it fails,
by panicking, at a range (1677 to 2262) that is not the type's range (-9999 to 9999).
The fix is to change the signature, not to put the `!` back on this one.

Why fallible, by Rig's own rules:

- **§7.2's first rule:** "Building a value from parts or text is fallible" (`Date.new`,
  `Time.new`, `DateTime.new`, every `parse`). A Unix number is parts. `from_unix` is
  today the one maker of a datetime value from outside data that does not follow it.
  A newcomer who has learned `Date.new(2027, 1, 31)!` expects `from_unix_s(t)!`.
- **Effects stay visible:** a call that can stop the program on a value from a file is
  the failure least visible of all. Rig has no checked `Float -> Int` conversion
  (`Int(f)` panics on NaN, SPEC "Numeric conversions"), so the program cannot even
  check a `Float` cheaply before it reaches the panic; the maker must check it.
- **The panic is reached by input, not by arithmetic.** §7.2 justifies `add`'s panic:
  "Text and parts from a user are checked where they come in, so reaching the panic
  takes arithmetic that walks past the year 9999." `from_unix` *is* where they come in.
  Year 2262 is 236 years out; data reach it today (far-future sentinels like
  `9999999999`, expiry dates, `Int.max` used as "never", JavaScript's range of
  ±8.64e15 ms).

### Precedent (checked in source where marked)

| Library | Maker | Out of range / not finite |
|---|---|---|
| Jiff 1.0 (source) | `Timestamp::from_second(i64)`, `from_millisecond`, `from_microsecond`, `from_nanosecond(i128)`, `new(s, ns)`, `from_duration(SignedDuration)` | all `Result`; **no `f64` maker on `Timestamp` at all**. `SignedDuration::from_secs_f64` panics (`.expect`), `try_from_secs_f64` is the `Result` twin |
| chrono 0.4 (source) | `from_timestamp_secs(i64)`, `from_timestamp(s, ns: u32)`, `from_timestamp_millis`, `_micros` | `Option`; but `from_timestamp_nanos(i64) -> Self`, **infallible, because every `i64` of ns is in range**, exactly Rig's `Duration` case |
| Go (source) | `time.Unix(sec, nsec)`, `UnixMilli`, `UnixMicro` | never fail: `nsec` outside [0, 1e9) is folded in; the doc admits `1<<63-1` "has no corresponding time value" (silently wrong) |
| Rust std | `Duration::from_secs_f64` | panics; `try_from_secs_f64` returns `Result` (1.66+); `UNIX_EPOCH + d` panics, `checked_add` gives `Option` |
| Java | `Instant.ofEpochSecond(s)`, `ofEpochSecond(s, nanoAdjustment)`, `ofEpochMilli` | `DateTimeException` past ±1e9 years; the nano adjustment may be any `long` and is folded in |
| Kotlin kotlinx.datetime | `Instant.fromEpochSeconds(s, ns = 0)`, `fromEpochMilliseconds` | **clamps** to `Instant.MIN`/`MAX` |
| Python | `datetime.fromtimestamp(float)` | `OverflowError`/`OSError` past the platform range, `ValueError` on NaN |
| Swift | `Date(timeIntervalSince1970: Double)` | never fails; NaN gives a `Date` holding NaN |
| JavaScript | `new Date(ms)` | Invalid Date (NaN inside) past ±8.64e15 ms or not finite |
| Temporal | `Instant.fromEpochMilliseconds(n)`, `fromEpochNanoseconds(bigint)` | `RangeError`, also for a non-integral number |

Read by family: every library with an exact type (Jiff, chrono, Java, Temporal, Python)
**fails** on an out-of-range Unix number. Kotlin clamps; Go, Swift and JavaScript hand
back a wrong or poisoned value. **None panics on an integer Unix time.** A Rust or Jiff
user expects `Result`; a Java, Python or Temporal user expects an exception they can
catch; a Swift/JS/Go user expects no failure at all, and is better served by a visible
`!` than by a panic. Clamping (Kotlin) gives a wrong instant silently and is out by
"accept means correct". A panic surprises all of them.

### Duration form or per-unit makers?

Per-unit makers taking an `Int`. Reasons:

1. **A `Duration` parameter cannot be fallible about its own number.** §5.2 makes every
   `Duration` parameter take duration forms, and the form is converted at the call,
   before the function runs (the `checked_add` probe). A `from_unix(d: Duration) ->
   Instant!` would still panic on `from_unix(ms: t)`. Only plain number parameters let
   the maker see, and refuse, the number.
2. **The range.** A `Duration` stops at 2262; `Instant` goes to 9999. `Int` seconds,
   milliseconds and microseconds cover the whole range (±2.9e11 years, ±2.9e8, ±2.9e5).
3. **Symmetry with the reader.** `i.unix_s() -> Int` is exact at any instant;
   `Instant.from_unix_s(i.unix_s())!` gives it back. Today it has no inverse.
4. **Newcomers know these names**: Jiff `from_second`/`from_millisecond`, chrono
   `from_timestamp_millis`, Go `UnixMilli`, Java `ofEpochMilli`, Temporal
   `fromEpochMilliseconds`, Kotlin `fromEpochMilliseconds`. Nobody's Unix maker takes
   a unit keyword.
5. **No second path.** With these, the duration-form `from_unix` adds nothing: a
   `Duration` in hand is `Instant.from_unix_ns(d.ns())`, exact and infallible. Keeping
   both would leave two spellings, one of which panics on outside data (Taste: one
   mechanism per idea).

### Does a `Float` belong?

**Yes, as its own fallible maker**, though Jiff, chrono, Go, Java and Kotlin have none.
Float seconds are a real wire format (Python's `time.time()`, Prometheus's HTTP API,
many JSON APIs), and Rig gives a program no checked way to turn a `Float` into an
`Int`: without the maker, the user writes `Int(f * 1000)`, which panics on NaN and
truncates, which is worse than the maker it replaces. Its doc says plainly that a
`Float` near 1.7e9 resolves about 240 ns (about 30 µs near 9999), so a finer time is
given as `Int`s. It is a separate name, so `from_unix_s(t)` with an `Int` never
silently goes through a `Float`.

## 2. The general rule for duration forms

Keep the panic as the default: it matches `Int` overflow and `Int(f)`, and nearly every
duration a program makes (`sleep(ms: 50)`, `add(hours: 1)`, a timeout from a constant)
is its own. Untrusted numbers need one fallible door, not a `!` on every call:

- **`time.checked_duration(<form>) -> Duration!`**: the form's number checked, failing
  (not finite, or beyond ±292 years) instead of panicking. A program converts outside
  numbers once, where they come in, and passes the `Duration` value to `sleep`, `add`,
  `within`, which then cannot fail on it. The name pairs with `checked_add`; `Duration.parse(s)!` already does this for text.
- **A `checked_` method must not panic on its argument.** Today `i.checked_add(ms: t)`
  panics before the call. A duration form given to a `checked_` method should fail
  with that method's range error. (A compiler change at the form's conversion; the
  designer of 5.2 decides the mechanism.)
- **The panic names its site**: `datetime.Instant.add: 9300000000000000 ms is beyond a
  Duration's range (±292 years)`, not today's `a duration is more nanoseconds than a
  Duration holds`, which names neither the call nor the number.

## 3. Recommendation

Fits the pending rule that a defaulted parameter after the first is given by name.

```rig fragment
# The instant `s` seconds and `ns` nanoseconds after 1970-01-01T00:00Z, summed exactly.
pub fun from_unix_s(s: Int, ns: Int = 0) -> Instant!
# The instant `ms` milliseconds after 1970-01-01T00:00Z, as JavaScript and Java count.
pub fun from_unix_ms(ms: Int) -> Instant!
# The instant `us` microseconds after 1970-01-01T00:00Z.
pub fun from_unix_us(us: Int) -> Instant!
# The instant `ns` nanoseconds after 1970-01-01T00:00Z; cannot fail (1677 to 2262).
pub fun from_unix_ns(ns: Int) -> Instant
# The instant `s` seconds after 1970-01-01T00:00Z, to the nearest nanosecond (about 240 ns near 2023).
pub fun from_unix_float(s: Float) -> Instant!
```

Removed: `Instant.from_unix(<duration form>)`. Its uses become `from_unix_s(t)!`,
`from_unix_ms(t)!`, or `from_unix_ns(d.ns())` for a `Duration` value; a migration
script maps each unit keyword to its maker (`seconds:`/bare `Int` to `from_unix_s`,
`ms:`, `us:`, `ns:` to theirs, bare `Float` to `from_unix_float`; `minutes:`/`hours:`
become `from_unix_s(t * 60)!`, rare).

Failures, all `DateTimeError` (calendar.rig): `.range` beyond the instant range or
±infinity, `.invalid` for NaN. Every maker floors toward the past before 1970, as
`unix_s()` does.

### At the edges

| Call | Result |
|---|---|
| `from_unix_s(1_700_000_000)!` | 2023-11-14T22:13:20Z (a constant still takes `!`, as `Date.new(2027, 1, 31)!` does) |
| `from_unix_s(-1)!`, `from_unix_ms(-1)!` | 1969-12-31T23:59:59Z, 1969-12-31T23:59:59.999Z |
| `from_unix_s(0, ns: -1)!` | 1969-12-31T23:59:59.999999999Z; `ns` may be any `Int`, of either sign, summed (as Go and Java's nano adjustment) |
| `from_unix_s(9_300_000_000)!` (past 2262) | 2264-09-14T21:20:00Z, where today it panics |
| `from_unix_s(253_402_207_200, ns: 999_999_999)!` | 9999-12-30T22:00:00.999999999Z, the last instant |
| `from_unix_s(253_402_207_201)` | fails `.range` |
| `from_unix_s(-377_705_023_201)!` / one less | -9999-01-02T01:59:59Z / fails `.range` |
| `from_unix_s(Int.max)`, `from_unix_ms(Int.max)`, `from_unix_us(Int.max)` | fail `.range` (no overflow: the sum is in `I128`) |
| `from_unix_ms(8_640_000_000_000_000)` (JS's last `Date`) | fails `.range` (year 275760) |
| `from_unix_ns(Int.max)` / `Int.min` | 2262-04-11T23:47:16.854775807Z / 1677-09-21T00:12:43.145224192Z |
| `from_unix_float(1.7e9)!` | 2023-11-14T22:13:20Z |
| `from_unix_float(-0.5)!` | 1969-12-31T23:59:59.5Z |
| `from_unix_float(nan)` / `(inf)` / `(1e12)` | fails `.invalid` / `.range` / `.range` |

The `Float` is converted from its exact value, rounded to the nanosecond half away from
zero, as a duration form's `Float` part is (§5.2). A constant argument out of range can
be a compile error through the §10.2 hook (about 20 lines), as `TimeZone.fixed`'s
literals are; the `!` stays, as on `Date.new`.

### Owner decisions (defaults first)

1. Replace `from_unix(<form>)` with the fallible `Int` makers above. Default: yes.
2. `from_unix_ns` without `!`, since it cannot fail (chrono's `from_timestamp_nanos`).
   Default: yes.
3. A `Float` maker: name `from_unix_float` (pairs with `Duration.float_seconds()`);
   alternatives `from_unix_f`, or none. Default: `from_unix_float`.
4. Name of the seconds maker: `from_unix_s` (the inverse of `unix_s()`), or the
   shorter `from_unix`. Default: `from_unix_s`, which names its unit beside
   `from_unix_ms` and reads back what `unix_s()` gives. (Either way every old call is
   a compile error, not a new meaning: the result now takes `!`.)
5. Duration forms: add `time.checked_duration(<form>)!`; make `checked_` methods fail,
   not panic, on their argument; name the site in the panic. Default: all three.
