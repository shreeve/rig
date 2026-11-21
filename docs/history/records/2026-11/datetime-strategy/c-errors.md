# Committee report: error handling (C)

Language design view: Rust's `Result` and panics and the API guidelines, Swift's
`throws`/`try`, Zig's error unions and safety checks, Go's error values, Java's and
C#'s exceptions. Read: PROPOSAL.md, rust.md, zig-go.md, design.md; Rig
`AGENTS.md`, SPEC ("Both modes keep every check", §13, §17 `panic`), `docs/IDEAS.md`,
`docs/design/datetime.md` (whole), `std/time.rig`, `std/datetime/*.rig` (main
e38454865); Jiff 1.0.0 `timestamp.rs`, `zoned.rs`, `civil/*.rs`, `signed_duration.rs`.
Probes in `scratchpad/unix/c/` run with `RIG_STD=std bin/rig run`.

## 0. What the probes show

| Probe | Result |
|---|---|
| `lenient.rig`: `n = text.parse_int("99999999")!; d.add(days: n)` | **panic**, exit 134. An amount read from text reaches the panic; no maker ever checked it |
| `strict.rig`: the same through `checked_add(...)!` up to `sub main()!` | `error: DateTimeError.range`, exit 1, **with no location and no value** |
| `strict.rig`: `last.checked_add(hours: 1) catch panic("next_run: ...", last, ...)` | works; the panic is written, and visible, in the program |
| `sat.rig`: `a.since(b) == a.since(c)` for instants 9 000 and 8 000 years apart | **`true`**: both saturate to 2 562 047 h. `b.unix()` for year 1000 prints a 1677 duration |

Three things follow. The lenient premise "text and parts from a user are checked where
they come in, so reaching the panic takes arithmetic that walks past 9999" (§7.2) is
false: keyword amounts, increments and offsets are numbers from outside too, and no
maker checks them. Strict, as Rig stands, gives a worse message than today's panics.
And the design's worst sharp edge is not a panic at all: `since` and `unix()` return
wrong values without a word.

## 1. The principle

**Strict, with the totality pushed as far as ranges allow.** Proposed wording:

> No datetime or duration method panics. A method whose result can leave its type's
> range, or whose argument can be bad, returns `!`. A method that cannot fail is total,
> and the design makes methods total by choosing ranges, never by saturating or
> clamping. A constant argument that would fail is a compile error, and the `!` stays.
> The only panics in a datetime program are the ones the program writes:
> `catch panic("why")`, or, after v1, a `Duration` operator, which traps as `Int`'s
> `+` does.

Why strict and not lenient:

1. **It is Jiff, translated correctly.** Every named method in Jiff that can leave the
   range returns `Result`: `checked_add`, `round` (on `Timestamp`, `Zoned`, `DateTime`,
   `Time` and `SignedDuration`), `start_of_day`, `tomorrow`, `from_second`. Jiff panics
   only through the operator traits (`impl Add<Span> for Date` is
   `checked_add(rhs).expect(...)`), plus `abs` and `from_secs_f64`, which copy Rust
   std. Zig is the same: `std.math.add`, `mul` and `cast` return `error.Overflow`, and
   only `+` traps. Rust's ints too: `checked_add` is named, and `+` panics. The pattern
   everywhere is that **operators trap and named functions can be fallible**. Rig's
   calendar types have no operators, so `d.add(days: 1)` is the counterpart of Jiff's
   `checked_add`, not of its `+`. The design's line "Jiff's operators panic the same
   way" (§7.2) compares a Rig method with a Rust operator.
2. **A Rig panic costs more than the exceptions cited in its defence.** Temporal's
   `RangeError`, java.time's `DateTimeException` and C#'s `ArgumentOutOfRangeException`
   are caught by the request handler: one request gets a 500 and the server goes on. A
   Rig panic ends the process (only `task.isolate` contains one). With lenient, a server
   that does `today.add(days: n)` with `n` from a query string can be stopped by one
   request.
3. **The Rust API guidelines' test fails here.** C-VALIDATE allows a panic when the
   precondition is one the caller is expected to check, and can check cheaply beside
   the call: `i < len`, a divisor that is not zero. Whether `d.add(months: n)` stays in
   range cannot be checked without doing the date arithmetic, so the operation has to
   be the one that reports it.
4. **Rig's `!` is the cheapest marker of any language here.** Go's `if err != nil`
   costs three lines, so Go's time package chose never to fail and wraps at the edges.
   Java's checked exceptions cost signatures and catch blocks, so people wrap them away.
   Swift's `Calendar.date(byAdding:to:)` returns `Date?`, and real code force-unwraps it
   with `!`, which crashes. Rig's `!` is one character and *propagates*: it is Swift's
   `try`, not `try!`. The cost that pushed other languages towards panics or wrapping
   mostly does not exist here.
5. **It halves the surface.** Lenient needs about 20 `checked_` twins (`add`, `round`,
   `floor`, `start_of_day` on five types; `add`, `sub`, `times`, `div`, `neg`, `abs`,
   `round`, `floor` on `Duration`; `Monotonic.add` and `at`). That is Rust's
   checked/wrapping/saturating/overflowing explosion again. Strict has one name for each
   operation, and the `!` says what it does.
6. **It is what the owner said:** "We cannot panic. We must have effects stay visible."
   Lenient keeps panics that a value from outside can reach.

### What it reads like

```rig fragment
sub main()!
  start = datetime.Date.parse(args[1])!
  for k in 0..12
    print(start.add(months: k)!)                  # anchored recurrence

fun expiry(issued: datetime.ZonedDateTime) -> datetime.ZonedDateTime!
  issued.add(days: 90)!.start_of_day()!

fun next_run(last: datetime.Instant) -> datetime.Instant   # a caller that won't fail
  last.add(hours: 1) catch panic("next_run: an hour after", last, "is past 9999")

fun mean(xs: ?List[time.Duration]) -> time.Duration!
  total = time.duration(0)
  for x in xs
    total = total.add(x)!
  total.div(xs.len)!                               # an empty list is now an error, not a panic
```

In a `sub main()!` the cost is one character per call. In a function that must not
fail, the program writes the panic itself, with its reason, at the call. That is "effects
stay visible" in its plain sense.

### The two risks of strict, and what removes them

- **Errors that lose where they came from.** Probe: `error: DateTimeError.range`, with no
  file, call or value, where today's panic names all three. Build the item already in
  `docs/IDEAS.md` (line 117), "a failure's trace in debug builds", from Zig's error
  return trace, together with strict or before it. Zig's answer to "errors are just
  tags" is exactly that trace. Without it, strict trades a good message for a bad one.
- **The silencer culture.** When a failure is rare, people write the cheapest thing that
  compiles: Rust's `.unwrap()`, Swift's `!`, Java's `catch (Exception e) {}`. In Rig the
  cheapest is `d.add(days: n) ?? d` or `catch d`, which is a *silent wrong date*, worse
  than a panic. Docs and examples show only `!` and `catch panic("why")`, never a value
  fallback for date arithmetic. (A lint is possible later; not proposed now.)

### Total by range, not by saturation (Zig's lesson)

Zig's `Io.Duration` is an `i96` so that its makers have nothing to fail. Rig can't widen
`Duration` (the owner chose one `Int`), but two small choices remove most of the `!`
that would be pure noise:

- **`Duration`'s range is symmetric**, ±(2⁶³−1) ns: no maker produces `Int.min`.
  `std/time.rig`'s `magnitude` already assumes this for parts. Then `neg()` and `abs()`
  are total, and `div(n)` fails only for `n == 0`.
- **A `Monotonic` reading is never negative** (the clock's readings aren't). Then
  `since` and `elapsed` are total: the difference of two values in [0, Int.max] fits an
  `Int`. Today `Monotonic.at(<-200 years>).elapsed()` overflows and panics, a panic the
  inventory misses.

## 1b. Against the owner's clarification

His bar: "We cannot have normal code panicking... It should only happen in
extraordinary cases of system failure not just some joker entered a bad date." So a
value from a user must never reach a panic, including after it flows into arithmetic
(9999-12-31 + 1 day).

**This settles the question: strict. Lenient fails his bar by construction.** Under
lenient, `user_date.add(days: 1)` panics in normal code unless the programmer
remembered `checked_add`, and the probe shows a parsed amount doing exactly that. There
is no stable middle. Any date, instant, amount or duration may have come from a user,
and the library cannot tell which. So every operation whose result *depends on its
values* can be reached by a joker, and must answer with `!`. The middle ground he wants,
"no `!` noise on calls that can't fail", is met by making those calls *actually*
unable to fail, not by letting the ones that can fail panic:

- **Total by construction, no `!`:** every reader; counts (`days_since`, ...);
  `Time.add`, `round` and `floor` (they wrap); `first_of_month` and `last_of_month`;
  `date.at(t)`; `i.in_zone(tz)` (the instant range was chosen for this);
  `from_unix_ns`; `unix_s`, `unix_ms` and `unix_us`; `Duration.neg` and `abs`
  (symmetric range); `Monotonic.since` and `elapsed` (non-negative readings);
  `time.duration(<constant>)`; `format` (a checked literal); `today(tz)`; `now()`.
- **Fallible, `!`:** everything that leaves a range or takes a bad argument, which is
  exactly where a user's value can make it fail.
- **Constant arguments:** compile errors. For these alone I now recommend letting the
  `!` go (open points, revised): an all-constant call is decided at compile time, so it
  truly cannot fail at run time.

What the bar means for each row:

| # | Under his bar |
|---|---|
| 1 | Required. A Unix number is user data. Makers `!`. `unix()` gets `!` rather than saturating (a wrong value is not a panic, but it breaks "accept means correct") |
| 2 | Required if a `Float` maker exists. A user's NaN must give `.invalid`, never reach `Int(f)` |
| 3 | Required. A user's number in a form can fail only through a `!` the call has. Waits saturate, which is exact and not a panic. Non-constant `Float` forms are refused |
| 4 | Required. `checked_x(ms: user)` panicking is the very case |
| 5 | **Required: strict.** 9999-12-31 + 1 day is his example. `round`, `floor` and `start_of_day` too: a user's 9999-12-30T23:59 rounded to the hour |
| 6 | Required. `start.add(seconds: user_timeout)` must not panic. `since` and `elapsed` become total through the range |
| 7 | Required. `d.times(user_count)` and `total.div(len)` with a user's empty list. `neg` and `abs` become total through the range. **The §5.6 operators conflict with the bar:** `a + b` on user-derived durations would trap. Rig's own `Int` `+` has the same conflict, which is a language question, not this library's. Recommend keeping 5.6 deferred until the owner rules on it |
| 8, 9 | Required. Parts and offsets from a user give `!` |
| 10 | Met: a constant-only increment has no run-time failure at all |
| 11 | No range panic is left in std. What remains are invariant checks, which fire only on a library bug: his "extraordinary" class |
| 12 | Not a panic, but a silent wrong value, which is worse. Fix it |
| 13 | Consistency |

## 2. The inventory

| # | Verdict | Signature |
|---|---|---|
| 1 | **Accept, plus one change.** Makers as proposed. **`unix()` stops saturating** | `Instant.from_unix_s(s: Int, ns: Int = 0) -> Instant!`, `from_unix_ms(ms: Int) -> Instant!`, `from_unix_us(us: Int) -> Instant!`, `from_unix_ns(ns: Int) -> Instant`; `i.unix_s()`, `i.unix_ms()`, `i.unix_us() -> Int` (floored, total); `i.unix() -> time.Duration!` (`.range` outside 1677 to 2262). `from_unix(<form>)` removed |
| 2 | **Accept `from_unix_float`** | `Instant.from_unix_float(s: Float) -> Instant!`: `.invalid` on NaN, `.range` on ±inf and beyond; exact value rounded half away from zero to the ns. Separately, Rig should have a checked `Float` → `Int` conversion. Its absence is a language gap that this maker only covers for one case |
| 3 | **Change to one rule:** a non-constant number in a duration form can fail only through a `!` the call already has | constant forms: everywhere, checked at compile time. `Duration` values: everywhere. Non-constant `Int` forms: in any callee that returns `!` (the form's `.range` is the callee's), in `Time.add` (reduced modulo a day, exactly, so it stays total), and in the waits (`sleep`, `within`, `after`, `per:`: beyond the range waits as long as the scheduler can, as §5.8 says, which is exact). **Non-constant `Float` forms: refused everywhere**, with a fix naming the door. `time.duration(<form>) -> Duration` takes constant forms and `Duration`s only. `time.checked_duration(<form>) -> time.Duration!` takes any form (`.invalid` NaN, `.range` beyond) |
| 4 | **Accept, generalized by 3 and 5**: every method that takes a `Duration` and can fail folds the form's failure into its own `!` | (no separate `checked_` methods remain) |
| 5 | **Strict.** `checked_add` removed (it *is* `add` now) | `Instant.add(d: time.Duration) -> Instant!`, `.round(<unit>: Int) -> Instant!`, `.floor(...) -> Instant!`; `Date.add(years: Int = 0, months: Int = 0, weeks: Int = 0, days: Int = 0) -> Date!`; `DateTime.add(d: time.Duration? = none, years:, months:, weeks:, days:) -> DateTime!`, `.round(...)!`, `.floor(...)!`; `ZonedDateTime.add(...)!`, `.round(...)!`, `.floor(...)!`, `.start_of_day() -> ZonedDateTime!` (back to Jiff; the owner's deviation 15 for `start_of_day` reverses). `Time.add`, `Time.round` and `Time.floor` wrap and stay total; `Time.checked_add` (fails on a wrap) stays, as in Jiff |
| 6 | **Strict, with the non-negative range** | `Monotonic.at(d: time.Duration) -> Monotonic!` (`.range` if negative), `m.add(d) -> Monotonic!`, `m.since(earlier) -> Duration` and `m.elapsed() -> Duration` total |
| 7 | **Strict, with the symmetric range** | `add(d) -> Duration!`, `sub(d) -> Duration!`, `times(n: Int) -> Duration!`, `div(n: Int) -> Duration!` (`.invalid` for 0), `round(...) -> Duration!`, `floor(...) -> Duration!`; `neg()` and `abs()` total. `checked_add`, `checked_sub` and `checked_times` removed. The §5.6 operators, after v1, trap as `Int`'s do: an operator is the program choosing `Int`'s rule, visibly |
| 8 | **Accept** | `Duration.from_parts(seconds: Int, ns: Int) -> Duration!`. It also catches `seconds * 1e9` overflowing, which panics today |
| 9 | **Accept** | `TimeZone.fixed(hours: Int = 0, minutes: Int = 0) -> TimeZone!`; literals still checked at compile time |
| 10 | **Accept for v1** | Constant increments only, which keeps `Time.round` total. Later, the `!` types can take a computed increment as `.invalid` with no change of signature |
| 11 | **Replace.** The library then has no range panics left. Make propagated failures say where they came from | Build IDEAS' error return trace (debug builds). Panics left inside std are invariant checks (library bugs) and name the call |
| 12 | **New: `since` stops saturating** | `Instant.since(other) -> time.Duration!`, the same on `DateTime` and `ZonedDateTime` (`.range` beyond ±292 years). `Time.since` and `Monotonic.since` stay total |
| 13 | **New: range errors say `.range`** | `Duration.parse` and `Instant.parse` give `.invalid` today for text that is well formed but out of range; they should give `.range`, as every other maker does |

Footprint of 5 to 7 on merged code: about 360 lines in tests, examples, benches,
STD.md and SPEC take a `!`, or `checked_x` becomes `x`. It is mechanical, and every site
is a compile error with a fix: a `T!` used as a `T`, or a removed name through the hint
table.

## 3. Open points

- **`Float` Unix maker:** yes, `from_unix_float(s: Float) -> Instant!` (row 2). Float
  seconds are a real wire format (Python's `time.time()`, Prometheus, many JSON APIs),
  and without the maker users write `Int(f)`, which panics on NaN. Also ask for a checked
  `Float` → `Int` in the language.
- **Non-constant `Float` duration forms:** refuse them at compile time, everywhere. A
  `Float` reaches a `Duration` only through `time.checked_duration(...)!`, where NaN
  shows. Non-constant `Int` forms stay where the call already says `!` (row 3).
- **Constant-only `round` increments:** yes, for v1 (row 10).
- **Proof-elided `!`:** **don't pursue.** (1) Whether a call site needs `!` would depend
  on how strong the prover is, which changes between releases, and on whether an
  argument is a literal, which changes in refactors. Code would gain or lose a required
  marker for reasons a reader can't see. (2) It hides an effect, against North Star 3:
  a reader can no longer tell from the call whether `Date.new(...)` is fallible.
  (3) No language here does it. Zig's answer to a fallible call with constant arguments
  is comptime evaluation and a compile error, with `try` kept. Rig's §10.2 hook gives
  the same: a failing constant is a compile error, so the `!` on
  `Date.new(2026, 1, 31)!` costs one character and is never taken.
  - **Revised after the owner's clarification:** pursue the *narrow, syntactic* form
    instead. A call to a std maker the §10.2 hook evaluates, whose arguments are **all
    constants**, gives `T` and not `T!`: `Date.new(2026, 1, 31)`,
    `TimeZone.fixed(hours: 5, minutes: 30)`, `Instant.from_unix_s(1_700_000_000)`. A
    failure is a compile error. The rule is visible in the source (every argument a
    literal or constant), not hidden in the prover. A refactor that makes an argument a
    variable brings back the `!`, and the compiler says so. This removes the noise on
    the one class of calls that truly cannot fail at run time, and it does not touch
    `add`. The prover-based elision stays rejected.

## 4. What else, by importance

1. **Silent saturation is the worst edge in the design** (probe: instants 1 000 years
   apart give the same `since`). Saturation is a wrong value accepted without a word: Go's
   mistake, here by choice (§5.1, §6.6, §7.8, deviation 17). Under "accept means
   correct" a wrong answer is worse than a panic. Rows 1 and 12 fix it. Jiff has no such
   edge, because its duration is wide. Where Rig's is narrow, the honest answer is `!`.
2. **Strict needs failure traces.** Without them a propagated `DateTimeError.range`
   names nothing, and people will reach for `catch panic` just to get a message. Build
   the IDEAS trace with strict (row 11). Keep the error sets as plain tags (cheap,
   matchable). The trace gives the location, as Zig's does.
3. **Teach `!` and `catch panic("why")`, never a value fallback, for date arithmetic.**
   `d.add(days: n) ?? d` is the Rig version of the Swift force-unwrap and Java's empty
   catch, and it gives a wrong date without a word. Every doc example and the
   `docs/learn` text (phase 6) model the two honest forms.
4. **Make the ranges do the work** (symmetric `Duration`, non-negative `Monotonic`).
   Each removes a `!` that would be noise, and one removes a panic the inventory missed
   (`Monotonic.since` and `elapsed`).
5. **The precedent table in §7.2 should not cite Temporal or java.time as equivalents of
   a panic.** Theirs are catchable per request; a Rig panic ends the process. The
   design's argument for lenient rests partly on that equivalence.
6. **Recurrences:** §6.2's "anchor to the start" guidance is the kind of rule people
   miss. A Jiff-style `start.series(months: 1)` iterator (`Date::series` in Jiff), which
   yields `start.add(months: k)` and stops with `.range` at the end, would build it in.
   It is small, and could come after v1.
7. **Small:** `Monotonic.at`'s doc says it panics, but it cannot (`Monotonic(n: d.n)`).
   `datetime.now()`'s panic is unreachable (an `Int` of wall-clock ns is always in
   range), so it should be an invariant check, not a range panic.
