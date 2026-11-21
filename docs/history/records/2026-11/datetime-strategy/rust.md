# Rust-time expert report: Instant from a Unix number

## Verified precedent (source checked)

- Jiff 1.0.0 (`misc/jiff/crates/jiff/src/timestamp.rs`): `Timestamp::new(i64, i32)`, `from_second(i64)`, `from_millisecond(i64)`, `from_microsecond(i64)`, `from_nanosecond(i128)` and `from_duration(SignedDuration)` all return `Result<Timestamp, Error>`. Even `from_second(i64)` is fallible, because an i64 of seconds reaches far beyond year 9999. Docs show a "saturating" wrapper built on the Result. Note `from_duration` is fallible only because Jiff's `SignedDuration` is 16 bytes and wide. Rig's `Duration` is narrower than the instant range, so the same function would be infallible in Rig. That is why Rig's design looks safe but leaks: the failure moves to making the `Duration`.
- chrono 0.4.45: `DateTime::from_timestamp(secs, nsecs) -> Option`, `from_timestamp_millis/micros -> Option`, but `from_timestamp_nanos(i64) -> Self` is infallible (an i64 of ns always fits; internally an `expect`). `NaiveDateTime::from_timestamp` was the panicking one ("Panics if the number of seconds would be out of range") and is `#[deprecated(since = "0.4.23", note = "use DateTime::from_timestamp instead")]`. The ecosystem's own verdict: a panic on an arbitrary Unix number was a mistake.
- Rust std: `Duration::from_secs(u64)` and `from_millis` never fail. `from_secs_f64` panics on negative, overflow or NaN, and `try_from_secs_f64` is the escape. The panic form exists because Rust panics are normal there; Rig's North Star says otherwise. For wall-clock points, std is fallible at the epoch step: `UNIX_EPOCH.checked_add(d) -> Option<SystemTime>` (the `+` operator panics).
- Others (from memory, not re-verified here): Go `time.Unix(sec, nsec)` and `UnixMilli` never fail (Time is wide, nsec is normalized). Java `Instant.ofEpochSecond(long, long nanoAdjustment)` throws `DateTimeException` beyond +-31556889864403199 s and normalizes any nanoAdjustment. Kotlin `Instant.fromEpochSeconds(Long, nanos)` clamps. Swift `Date(timeIntervalSince1970: Double)` takes a Double. Python `fromtimestamp` raises `ValueError`/`OverflowError`/`OSError`. JS `new Date(ms)` yields an Invalid Date; Temporal `Instant.fromEpochMilliseconds` throws `RangeError` beyond +-8.64e15 ms. Every one of them fails or clamps visibly; none panics the process. Newcomers expect "out of range -> error".

## 1. Should from-Unix be fallible?

Yes. The current design makes the most common real input (a number read from a file or the network) the one that panics, and makes years 2262-9999 unreachable. Both are defects, and neither is the caller's fault. The duration form is the wrong vehicle: `Duration` bounds the number before `from_unix` can say anything, so the failure cannot be `!` on `from_unix` at all (the panic happens at the call site's form conversion).

Per-unit makers taking `Int` win. The Int is exactly what a file or message holds; the range check is the Instant's own and can be a plain `DateTimeError.range`. Duration forms stay right where the number is a program's own constant (`sleep`, `add`).

Float seconds: leave out. 240 ns resolution near 1.7e9 is a silent loss; NaN/inf add a second failure kind; and the Int makers cover every Unix timestamp format found in practice. Swift and Python take Double, but a Rust, Go or Java newcomer expects integers. Whoever has a Float writes `from_unix_s(Int(x.floor()), ns: ...)` and sees the rounding choice. (If the owner wants one, `from_unix_f(secs: Float) -> Instant!`, failing on NaN, inf and out of range, is the only acceptable shape; do not make it the unmarked default.)

## 2. General rule

Panic on a non-constant out-of-range number in a duration form is defensible for `sleep` and `add`: the argument is nearly always a literal or program arithmetic, Rust's `Duration + Duration` and `from_secs_f64` do the same, and `!` on every `sleep` would be noise. Untrusted numbers need an opt-in fallible path that does not touch ordinary calls: `time.checked_duration(<form>)! -> Duration` (same forms, returns `DateTimeError`/`TimeError.range`), mirroring `Instant.checked_add` and Rust's `try_from_secs_f64`. Then `d = time.checked_duration(ms: n)!` and `sleep(d)`. Cost: one function, no change elsewhere. Since the from_unix makers take `Int`, from_unix itself does not need it.

## 3. Recommendation

```rig
# on Instant, all fail with DateTimeError.range beyond the range of instants
pub fun from_unix_s(s: Int, ns: Int = 0) -> Instant!   # Unix tools' count; ns any Int, normalized (Java style)
pub fun from_unix_ms(ms: Int) -> Instant!              # JavaScript, Java currentTimeMillis
pub fun from_unix_us(us: Int) -> Instant!              # Python/Go microseconds
pub fun from_unix_ns(ns: Int) -> Instant               # infallible: an Int of ns is +-292 years (chrono from_timestamp_nanos)
# remove from_unix(<duration form>); optionally keep `from_unix_f` only if wanted (above)
pub fun time.checked_duration(<form>) -> Duration!     # untrusted numbers
```

`from_unix_s(1_700_000_000)!`; `from_unix_s(5, ns: 250)!`: `ns` is name-only, which fits the pending owner decision.

Edges:
- `from_unix_s(253_402_207_200)!` = 9999-12-30T22:00:00Z OK; `+1` fails. `-377_705_023_201` OK, one less fails. Year 2262 and 9999 therefore both work.
- `Int.max`, `Int.min`: fail `.range` (compute in `I128` so `s*1e9 + ns` cannot overflow; a huge `ns` adjusts the seconds, then range is checked).
- Negative: floor-normalized, `from_unix_s(-1, ns: 500_000_000)!` is 23:59:59.5Z on 1969-12-31 (same as `from_unix_s(0, ns: -500_000_000)`).
- NaN: not representable (no Float). `from_unix_ms(Int.max)!` fails; `from_unix_us(Int.max)!` fails (about year 292277).
- `from_unix_ns(Int.min..Int.max)`: always OK, 1677 to 2262.

One-line docs:
- `from_unix_s`: the instant `s` whole seconds, plus `ns` nanoseconds, after 1970-01-01T00:00Z; fails with `DateTimeError.range` beyond the years -9999 to 9999.
- `from_unix_ms`: same, in milliseconds; fails the same way.
- `from_unix_us`: same, in microseconds.
- `from_unix_ns`: same, in nanoseconds; never fails.
- `time.checked_duration`: `time.duration`'s forms, failing with a range error instead of panicking.
- Inverse: `i.unix_s()` already exact; add `i.unix_ms() -> Int` (floored) for symmetry if wanted.
