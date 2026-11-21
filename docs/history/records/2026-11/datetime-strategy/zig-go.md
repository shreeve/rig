# Instant from a Unix time: Zig / Go view

## Facts checked
- Zig 0.17 std (`lib/std/Io.zig`): `Io.Timestamp` and `Io.Duration` hold an `i96` of ns. The constructors
  `Duration.fromSeconds/fromMilliseconds/fromMicroseconds(x: i64)` multiply in `i96`, so they cannot overflow:
  Zig makes the type wide enough to be total rather than panic or return an error. `toSeconds` etc. `@intCast` to i64
  (cannot fail at i96 / 1e9). Zig has no fallible Unix-time constructor because it has none to fail.
- Zig panics: `@panic` and safety-checked illegal behavior (overflow, bad `@intCast`) stop the program in Debug/ReleaseSafe
  but are UNDEFINED in ReleaseFast/Small. Rig's "panic" must therefore be an explicit emitted check, never a bare
  `@intCast`/`+`, or the North Star ("accept means correct") fails in release builds. Zig's idiom for recoverable bad
  input is an error union; panics are for bugs in the caller.
- Go (go1.27.3, run here on arm64, source in `scratchpad/unix/go/main.go`):
  - `time.Unix(sec, nsec)`, `UnixMilli`, `UnixMicro` accept any int64 and never fail. `Time` spans +-292e9 years, so
    `time.Unix(MaxInt64,0)` is year 292277026596 and `.Unix()` round-trips. `Unix(MinInt64,0)` already
    wraps in its internal offset (printed as a year 292277026596 date; `.Unix()` still returns MinInt64).
  - The silent edges are elsewhere: `time.Date(2300,...).UnixNano()` returns -8032952073709551616 (wraps, documented
    "undefined"). `Duration(MaxInt64)+1` wraps to MinInt64. `time.Duration(float64(1e19))` and `time.Duration(NaN)`
    give MaxInt64 and 0 here but are implementation-defined (amd64 gives MinInt64 for both). `Add` of two
    huge Durations wrapped to year 2554. Lesson: Go never fails and leaves the edge to garbage; a newcomer from Go
    expects `from_unix(x)` to take any integer. Go can do this only because its Time is wide (i64 seconds).
- Jiff 1.0.0 (`crates/jiff/src/timestamp.rs`): `from_second(i64)`, `from_millisecond(i64)`, `from_microsecond(i64)`,
  `from_nanosecond(i128)`, `from_duration(SignedDuration)`, all `Result<Timestamp, Error>`; the doc examples show the
  caller choosing to saturate. Per-unit, fallible, Int-taking: exactly the shape under test. `Timestamp::new(s, ns)` is
  also fallible and carries ns.
- From memory (not re-checked here, no network): Rust `Duration::from_secs_f64` panics on negative/NaN/overflow, with
  `try_from_secs_f64` for the fallible path; chrono `DateTime::from_timestamp(secs, nsecs) -> Option`; Java
  `Instant.ofEpochSecond` throws `DateTimeException` past +-31556889864403199; Python `fromtimestamp` raises
  OverflowError/ValueError/OSError; JS `new Date(ms)` yields an Invalid Date past 8.64e15 and Temporal
  `Instant.fromEpochMilliseconds` throws RangeError; Swift `Date(timeIntervalSince1970:)` takes a Double and never
  fails (reference-date based, far wider range); Kotlin `Instant.fromEpochSeconds` clamps (saturates) beyond its range
  in kotlinx-datetime, not throwing. Every language whose instant is narrower than its integer either fails or
  clamps; none panics on a runtime Unix number except Rust's explicitly-named float path.

## Q1: fallible?
Yes. Rig's Instant (+-9999 years) is narrower than `Int` seconds, so the maker is fallible by the same rule Rig applies
to `Date.new`: untrusted parts -> `T!`. The owner's "violent" instinct is right, and `from_unix` going infallible was
true only for the duration-typed parameter, whose narrowness just moved the panic into the argument. Panic-at-argument
hides the failure in a place with no `!` (it breaks "effects stay visible" and POLS: Go, Jiff, Java, JS, Python
users all expect a Unix integer from a file to be rejected, not to crash).

Duration form vs per-unit makers: per-unit wins.
- Duration form can't express years 2263..9999 at all (Duration caps at 2262), so it can never be the general maker.
- A per-unit `Int` maker takes exactly the type each caller has (Go `UnixMilli`, Jiff `from_millisecond`, Java
  `ofEpochMilli`), no Float, no rounding, no saturation.
- Failure is then the one in-range test, in one place, `DateTimeError.range` (already used by `checked_add`).
- Infallible where Zig-style width makes it so: `Int` nanoseconds is +-9.2e18 ns = 1677..2262, inside the range, so
  `from_unix_ns(Int)` needs no `!`. (ms and us as `Int` can fail: +-9.2e15 s and 9.2e12 s.)

Float seconds: leave it out. 240 ns resolution near 1.7e9 means `from_unix(1.7e9 + 0.000000123)` silently drops digits
(Rust documents this in from_secs_f64's rounding; Python/Swift/JS accept it, but they have no ns-exact alternative to
nudge toward). Adding it brings NaN, infinities, rounding mode and a second failure kind into the surface. If Float is
kept, name it so it can't be mistaken (`from_unix_f`), `!`, error on NaN/inf/range, round half away from zero to ns,
mirroring Rust's `try_from_secs_f64`. My default: omit, since a Float read from JSON is `Int(x * 1000)` to ms anyway and
that Float->Int conversion is where NaN should fail.

## Q2: duration forms
Keep panic for the form on `sleep`, `add`, `time.duration(...)`: there the number is almost always a literal or the
program's own arithmetic, a wrong one is a bug, and the cost of `!` on every `sleep(5)` is real. Same as `Int`
overflow and Rust `Duration + Duration`. But the form should not be the way untrusted numbers enter. Provide one
fallible twin, not a `!` on each call: `time.try_duration(<same forms>) -> Duration!` (Rust's `try_from_secs_f64`
precedent), failing with `DateTimeError.range`, never panicking. Anything from the network goes through it, then the
checked Duration flows into `sleep`/`add` with no further failure. Instant makers need not use it (above).

## Q3: recommended API
```
# Unix time -> Instant. Whole numbers of the unit; ns: is added, carrying.
pub fun from_unix_s(s: Int, ns: Int = 0) -> Instant!      # fails .range outside -9999-01-02T01:59:59Z .. 9999-12-30T22:00:00Z
pub fun from_unix_ms(ms: Int) -> Instant!
pub fun from_unix_us(us: Int) -> Instant!
pub fun from_unix_ns(ns: Int) -> Instant                  # cannot fail: 1677..2262
# optional: from_unix_ns_wide(ns: I128) -> Instant!   (Jiff from_nanosecond)
# Inverses, exact, never fail:  i.unix_s() (have), i.unix_ms(), i.unix_us() all floored Int; i.unix_ns() -> I128.
# i.unix() -> Duration saturating: keep as is.
# Remove Instant.from_unix(<duration form>).  Add time.try_duration(<form>) -> Duration!.
```
(`ns:` name-only fits the pending decision: `from_unix_s(1_700_000_000, ns: 5)`. `ns` is added in I128 then range-checked,
so `ns: Int.max` can't overflow.)

Edges for `from_unix_s(s)!`:
| s | result |
|---|---|
| 1_700_000_000 | ok |
| 9_223_372_036 / 9_223_372_037 (2262) | ok (the old panic zone) |
| 253_402_207_200 | ok, 9999-12-30T22:00:00Z |
| 253_402_207_201 | `DateTimeError.range` |
| -377_705_023_201 | ok; -377_705_023_202 -> `.range` |
| negative | ok; `from_unix_s(-1, ns: 500_000_000)` = half a second before 1970 |
| Int.max / Int.min | `.range`, no wrap, no panic |
| NaN | not representable: no Float here |
`from_unix_ms(Int.max)` -> `.range`; `from_unix_ns(Int.max)` = 2262-04-11T23:47:16.854775807Z, `Int.min` = 1677-09-21T00:12:43.145224192Z.

One-line docs:
- `from_unix_s(s, ns: 0)!`: The instant `s` seconds (and `ns` nanoseconds) after 1970-01-01T00:00Z, as Unix tools count; fails with `DateTimeError.range` beyond the years -9999 to 9999.
- `from_unix_ms(ms)!`: A JavaScript or Java time, whole milliseconds since 1970; fails beyond the range.
- `from_unix_us(us)!`: Whole microseconds since 1970; fails beyond the range.
- `from_unix_ns(ns)`: Whole nanoseconds since 1970 (Go's `UnixNano`); never fails, an `Int` reaches 1677 to 2262.
- `time.try_duration(...)!`: `time.duration`'s forms for a number you did not write: fails instead of panicking.

Newcomer check: Go `time.Unix(s, ns)` -> `from_unix_s(s, ns: n)!` (the `!` is the one new thing, explained by "the year
10000 doesn't exist"); Rust `from_second`/`from_millisecond` same names and shape; Java `ofEpochSecond` same; JS
`new Date(ms)` becomes `from_unix_ms(ms)!`.
