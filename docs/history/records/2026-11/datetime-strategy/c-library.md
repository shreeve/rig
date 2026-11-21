# Committee report: the date-time library view

Read: COMMITTEE.md, PROPOSAL.md, rust.md, zig-go.md, design.md; rig `docs/design/datetime.md`
(all), SPEC "Both modes keep every check", §13 Errors, "### panic", "Numeric conversions",
"Error sets"; `std/time.rig`, `std/datetime/*.rig` (main e38454865); Jiff 1.0.0
`timestamp.rs`, `zoned.rs`, `civil/date.rs`, `civil/datetime.rs`, COMPARE.md. Probes run
with `bin/rig run` (programs in `clib/`).

The owner's clarified bar (relayed by the coordinator): *no panic in normal code; a panic only for
extraordinary system failure, never because someone entered a bad date, including a user's
value that later flows into arithmetic, such as adding a day to a user's 9999-12-31.*

## 0. Two facts that decide most of this

**Jiff's methods are already strict.** Checked in source: `Timestamp::round`,
`Zoned::round`, `Zoned::start_of_day`, `Date::tomorrow`, `Zoned::first_of_month`, every
`checked_add`, all return `Result`. Jiff has **no panicking `add` method**. Only its
`impl Add`/`Sub` operators panic (`.expect("adding span to date overflowed")`), and
COMPARE.md's section on this is titled "Jiff makes checked or saturating arithmetic
explicit". Design §7.2 justifies Rig's panicking `add` *method* with "Jiff's operators panic
the same way". But Rig has no operators on these types. The thing in Jiff that matches Rig's `add`
method is Jiff's `checked_add`, which returns a `Result`. Following Jiff faithfully gives the strict reading.

**The lenient principle as drafted fails its own test.** It promises "never on a valid
value". Probe (`clib/p1.rig`):

```
hi = datetime.Instant.parse("9999-12-30T22:00:00.9Z")!   # valid text from outside
print(hi.round(seconds: 1))                                # constant argument
```
```
panic: datetime.Instant.round: 9999-12-30T22:00:00.9Z rounds beyond the range of instants ...
exit=134
```

So does `Date.parse("9999-12-31")!.add(days: 1)`. 9999-12-31 is the standard "no end"
sentinel in SQL Server, Oracle and SAP. Its mirror, 0001-01-01, is .NET's
`DateTime.MinValue` and Go's zero `Time`. These values are not edge cases. They arrive
from databases every day. The datetime range is narrow enough that ordinary data sits on its
edges. `Int`'s range is not like that: an `Int` overflows only on adversarial input. That
difference is why "panic where `Int` would" is the wrong analogy for points on a calendar.

## 1. The principle: total or visible

> **Every `std.time` and `std.datetime` call is either total (it cannot fail on any value
> of its argument types) or returns `!`. No call panics on any value. Where a call would
> fail only because a range is slightly too small, the type's range is chosen so that
> the call is total, rather than adding a `!`.**

This sits between strict and lenient in the way the owner asked for. It is strict about failure:
every call that can fail returns `!`. It is not strict about noise: calls that cannot fail
carry no `!`, and a few calls are made total on purpose by choosing ranges (Zig's habit,
zig-go.md):

- `Monotonic` holds readings within ±2^62 ns (±146 years). Any difference of two readings
  then fits a `Duration`, so `since` and `elapsed`, the hot timing calls, are total. Only
  `at` and `add` take `!`. The OS clock counts from boot, so a reading is nowhere near
  this limit.
- `Duration`'s range is made symmetric, ±(2^63−1) ns, leaving `Int.min` out. That makes `neg` and
  `abs` total.
- `Time.add` and `Time.round` wrap, so they stay total.

What stays total (most calls): every reader; the counts (`days_since` and the rest, which
fit easily within 20,000 years); `in_zone` from an `Instant` or a `ZonedDateTime`;
`Date.at`; `first_of_month`, `last_of_month`; `Time.add` and `Time.since`; `now()`;
`today()`; `Monotonic.since` and `elapsed`; `Duration`'s readers, `neg` and `abs`;
`from_unix_ns`; `unix_s`, `unix_ms`, `unix_us`; `offset_at`.

What takes `!`: every call that leaves a range on a value that may have come from a user.

**Short programs, as they read:**

```rig
sub main()!
  start = time.monotonic()                          # total
  due = datetime.Date.new(2027, 1, 31)!.add(months: 1)!
  for k in 0..12
    print(bill_start.add(months: k)!)               # a user's start date: can fail at 9999
  i = datetime.Instant.from_unix_ms(text.parse_int(field)!)!
  print(i.round(seconds: 1)!)                       # i came from outside: can fail
  print(z.add(days: 1)!, z.date(), z.weekday())     # readers: no !
  print(start.elapsed())                            # total
```

In a function that cannot fail, the program writes its own decision:
`d.add(days: 7) catch panic("past 9999")`. That panic is visible in its source, the same
way Rig's `+%` is wrapping by choice. Jiff users write `?` at exactly the same places
(`zdt.checked_add(1.day())?`, `ts.round(Unit::Second)?`). Rig's `!` is one character, and
`sub main()!` absorbs it.

**What the language still does.** Rig's `Int` operators panic on overflow, so the bar
cannot reach arithmetic a program writes on `Int`s. The library promises the bar for its
own calls. The planned `Duration` operators (§5.6) would reintroduce panics on durations a
user entered: `Duration.parse(...)` followed by `+`. I recommend not adding panicking
`Duration` operators. If they are wanted, they belong to a language-wide decision about
`Int` overflow under this bar. The methods are enough.

## 2. The inventory, row by row

| # | Decision | Signature |
|---|---|---|
| 1 | **Accept, with one change.** `ns` must be within ±999,999,999, as in Jiff's `Timestamp::new`; signs may differ. Outside that it fails `.range` rather than being folded in. A `ns` field of 1.5e9 in a file is corrupt data, and folding it in guesses. Add the inverses, and stop saturating `unix()`. | `Instant.from_unix_s(s: Int, ns: Int = 0) -> Instant!`, `from_unix_ms(ms: Int) -> Instant!`, `from_unix_us(us: Int) -> Instant!`, `from_unix_ns(ns: Int) -> Instant`; `i.unix_s() -> Int`, `i.unix_ms() -> Int`, `i.unix_us() -> Int` (floored, exact, total: microseconds at year 9999 are 2.5e17, which fits an `Int`); **`i.unix() -> time.Duration!`** (fails outside 1677 to 2262, no saturation; chrono deprecated its panicking `timestamp_nanos` for `timestamp_nanos_opt`) |
| 2 | **Include it.** Float seconds are a real wire format (Python's `time.time()`, Prometheus, JSON), and Rig has no checked `Float -> Int` conversion. Without this maker, users write `Int(f * 1000)`, which panics on NaN. | `Instant.from_unix_float(s: Float) -> Instant!`: `.invalid` for NaN, `.range` for ±inf or out of range; rounds from the exact value to the nearest ns, half away from zero |
| 3 | **Replace.** A form is converted *inside* its callee, exactly (in `I128`). Each callee then does one of three things. A `!` method fails with `.range`, or with `.invalid` for NaN. A wait (`sleep`, `within`, `after`, `per:`) clamps: a negative wait is zero, as today, and a wait past an `Int` of ns lasts as long as the scheduler can, as §5.8 already says. `Time.add` wraps, exactly modulo a day. **`time.duration(<form>)` takes constants only.** Numbers from outside go through a new gate. **A non-constant `Float` form** is accepted only by a `!` callee and by the gate. Anywhere else it is a compile error whose fix names `ms: Int(x * 1000)` (a conversion visible in the source) or the gate. | `time.duration(<constant form>) -> Duration`; `time.checked_duration(<form>) -> Duration!` |
| 4 | **Subsumed** by row 3 and row 5: no `checked_` method is left to break its promise. | |
| 5 | **Strict.** `add`, `round`, `floor` and `start_of_day` return `!`. **`checked_add` is deleted** on these types, because two names for one operation goes against "one mechanism per idea". **`since` returns `!` instead of saturating.** Saturating hands back a silent wrong answer, Go's regret: `time.Since(time.Time{})` reports 292 years. | `Instant.add(d: Duration) -> Instant!`; `Date.add(years: 0, months: 0, weeks: 0, days: 0) -> Date!`; `DateTime.add(d: Duration? = none, years:…, days: 0) -> DateTime!`; same shape for `ZonedDateTime`; `round(…)`, `floor(…)` `-> Self!` on `Instant`, `DateTime`, `ZonedDateTime`; `z.start_of_day() -> ZonedDateTime!` (Jiff's returns `Result`; this reverses an owner call); `since(other) -> Duration!` on `Instant`, `DateTime`, `ZonedDateTime`. `Time.add` (wraps), `Time.round` (wraps) and `Time.since` stay total. `Time.checked_add` stays: it means something different (no wrap past midnight), and Jiff uses the same name for it. |
| 6 | **Made total by range where possible.** Readings are held within ±2^62 ns. | `Monotonic.at(d: Duration) -> Monotonic!`, `m.add(d: Duration) -> Monotonic!`; `since`, `elapsed` total |
| 7 | **Strict, with a symmetric range.** `checked_*` methods deleted. | `add`, `sub` `(d: Duration) -> Duration!`; `times(n: Int) -> Duration!`; `div(n: Int) -> Duration!` (fails on 0); `round(…)`, `floor(…)` `-> Duration!`; `neg()`, `abs()` total |
| 8 | **Accept.** Use the same part rule as row 1, which I'd prefer to the current same-sign rule: `ns` within ±999,999,999, signs may differ, the two summed. | `Duration.from_parts(seconds: Int, ns: Int) -> Duration!` |
| 9 | **Accept.** Literals are still checked at compile time. The `!` stays, as on `Date.new`. | `TimeZone.fixed(hours: Int = 0, minutes: Int = 0) -> TimeZone!` |
| 10 | **Change.** Every `round` and `floor` now returns `!`, so a computed increment that isn't allowed simply fails `.invalid` through that same `!`. A constant one is still a compile error. User-chosen snapping (5, 10, 15 or 30 minutes in a calendar app) is a real need, and constant-only would push it into a `match`. | as in row 5 and row 7 |
| 11 | **Accept, but it is nearly moot:** the library has no reachable panics left. `now()`'s panic cannot be reached (the clock is an `Int` of ns, inside the range) and counts as system failure. What replaces panic messages is item 4.1 below. | |

Migration cost for the merged phases: every `x.add(…)` becomes a compile error, because a
bare call to a fallible function is rejected. The migration is therefore loud, never
silent. `tools/migrate-datetime.py` can append `!` where the caller can fail, and rename
`checked_add` to `add`.

## 3. Open points

- **`Float` Unix maker:** yes, `from_unix_float(s: Float) -> Instant!` (row 2).
- **Non-constant `Float` duration forms:** accepted only where the call can fail
  (`!` methods, `time.checked_duration`). Refused everywhere else at compile time, with a fix
  that makes the conversion visible (row 3).
- **Constant-only `round` increments:** not needed. Fallible rounds take any increment and fail
  `.invalid` (row 10).
- **Proof-elided `!`: don't pursue it.**
  1. Rig rejects `!` on a call that cannot fail. Under elision, whether `!` is required or
     forbidden would depend on what the prover managed. Turning a literal into a variable
     would flip it, and a reader could no longer tell from the text whether a call can
     fail. "Effects stay visible" means visible in the source, not to the prover.
  2. It would rarely fire. Nearly every `!` above is on a runtime receiver
     (`d.add(days: 1)` depends on `d`). Only all-literal makers would benefit, and those
     already get a compile-time check, with the `!` costing one character.
  3. The language effort is better spent on item 4.1.

## 4. What else, ranked

1. **Failures must say where and what.** This is the cost of going strict, and the most
   important item. Today's panics name the call and the value (`datetime.Instant.round:
   9999-12-30T22:00:00.9Z rounds beyond …`). A strict failure that reaches `main` prints
   only `error: DateTimeError.range`, because Rig's errors are plain enum values with no
   payload. That would be a real step back from Jiff, whose errors carry rich context. Ask
   for one of two fixes. One: Zig's error return traces, printed when a failure leaves
   `main` (Rig compiles to Zig, which already records these). Two: a way for a std error
   to carry a static message and the offending value. Without one of them, the strict
   design is correct but hard to debug.
2. **No saturation anywhere.** `since` and `unix()` saturate today (§5.1, §6.6). That is
   a silent wrong answer, which "accept means correct" forbids more strongly than a panic.
   Sentinel dates make it routine, not rare. Fixed by row 5 and row 1. The alternative
   considered was a 16-byte `Duration` (Jiff's `SignedDuration`). It would make
   `since` and `unix` total, but then `ms()`, `us()` and `ns()` would need `!`, and those
   are on every timing line. Keep the `Int` and fail.
3. **`min()` and `max()` on every type** (Jiff has `MIN`/`MAX` on each): `Date.min()`,
   `Date.max()`, and the same on `Time`, `DateTime` and `Instant`. §6.7 tells programs to
   test for 9999-12-31 as "no end", but the design gives that date no name. Without
   these, every program hand-writes `Date.new(9999, 12, 31)!`.
4. **Embedded zone data with a `.reject` default for conflicting offsets (§8.3).** A
   binary built with older zone data than the program that wrote a string will reject
   valid stored strings. Jiff has the same default but reads the system's zone data, so
   it meets the problem less often. Say so in the docs beside `tzdb_version()`, and test
   the message.
5. **Reading RFC 2822 and HTTP dates** (`Tue, 17 Nov 2026 15:07:03 GMT`), which Jiff
   has as `fmt::rfc2822`. After ISO, these are the commonest machine date format (HTTP
   `Date`, `Last-Modified`, email, RSS). Their absence is the most visible gap against
   the best libraries. Add them soon after v1.
6. **The `Duration` operators (§5.6)**, revisited under the bar (section 1).
