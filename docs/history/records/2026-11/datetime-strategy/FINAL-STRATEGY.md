# Rig datetime: the final strategy, "total or visible"

Settled from two panels (first: `rust.md`, `zig-go.md`, `design.md`; second:
`c-library.md`, `c-errors.md`, `c-rig.md`) against the owner's bar: **"We
cannot have normal code panicking. That is a hard crash. It should only happen
in extraordinary cases of system failure, not just some joker entered a bad
date."** All three committee members chose the same principle independently.

## The rule

**Every call in `std.time` and `std.datetime` is either total (it cannot fail
on any value of its argument types) or returns `!`. No call panics on any
value. Where a call would fail only because a range is a little too small, the
range is chosen so the call is total, rather than adding a `!`. Nothing
saturates: a result that can't be represented is a failure, never a quietly
wrong value.**

Why the "lenient" reading (panic where `Int` would) was rejected: the library
can't tell input from arithmetic. A user's 9999-12-31 plus a day, a renewal
period from a file in `start.add(months: period * k)`, and
`Instant.parse("9999-12-30T22:00:00.9Z")!.round(seconds: 1)` all panicked when
the committee ran them. Sentinel dates sit on the range's edges in ordinary
data. And Jiff's own named methods (`checked_add`, `round`, `start_of_day`,
`tomorrow`) all return `Result`; only its `+` and `-` operators panic, and Rig's
datetime types have no operators. Strict is also smaller: one name per
operation, no `checked_` twins.

## What changes

**Total, no `!`** (already, or by a range choice):
- readers (`year()`, `hours()`, `ns()`, ...), the counts, comparisons, text
  printing, `in_zone` on an `Instant`;
- `Time.add`, `Time.round`, `Time.since`: they wrap on the clock face (2 of 3;
  the third wanted a failing `Time.add` plus `wrapping_add`);
- `Duration.neg()` and `abs()`: `Duration`'s range becomes symmetric, leaving
  out `Int.min`;
- `Monotonic.since` and `elapsed()`: readings are held non-negative and within
  146 years, so their difference always fits;
- `Instant.from_unix_ns(ns: Int)`, `unix_s()`, `unix_ms()`, `unix_us()` (floored,
  exact).

**Fallible, `!`** (one name each; every `checked_` twin is deleted):
- `add`, `round`, `floor`, `start_of_day` on `Date`, `DateTime`, `Instant`,
  `ZonedDateTime`; `Monotonic.add` and `Monotonic.at`;
- `Duration`'s `add`, `sub`, `times`, `div` (fails on 0), `round`, `floor`;
- `since` on `Instant`, `DateTime`, `ZonedDateTime`, and `Instant.unix()`:
  `Duration!` instead of saturating;
- every maker from parts or text (as now), plus `Duration.from_parts` and
  `TimeZone.fixed` (now `!`);
- the new Unix makers:
  ```rig
  Instant.from_unix_s(s: Int, ns: Int = 0) -> Instant!   # ns within ±999,999,999 (signs may differ, as Jiff's Timestamp::new)
  Instant.from_unix_ms(ms: Int) -> Instant!
  Instant.from_unix_us(us: Int) -> Instant!
  Instant.from_unix_ns(ns: Int) -> Instant               # total: ±292 years
  Instant.from_unix_float(s: Float) -> Instant!          # .invalid on NaN, .range beyond; to the nearest ns
  ```
  `Instant.from_unix(<duration form>)` is removed.

**Duration forms with a run-time number** (`ms: t` where `t` is not a
constant):
- in a call that returns `!`, the conversion is folded into that call's own
  failure (`i.add(ms: t)!` fails cleanly, never panics);
- in a wait (`sleep`, `within`, `after`, `per:`), a too-large number waits as
  long as the scheduler can and a negative one counts as zero (as §5.8 says);
- anywhere else it is a compile error whose fix makes the conversion visible:
  `time.duration(ms: t)!` (see decision 2).

**`round` and `floor` increments:** a constant increment is checked at compile
time, as now; a computed one that isn't allowed fails `.invalid` (every round
is fallible now, so no constant-only rule is needed).

**Range ends by name:** `min()` and `max()` on `Date`, `Time`, `DateTime`,
`Instant`, `Duration` (as Jiff has), so a program that saturates does so on
purpose, visibly.

**No `panic(` in std's time code**, enforced by a test (the one in
`datetime.now()` is unreachable and goes).

**Errors that say where and what.** Strict turns today's precise panic messages
into errors; one that reaches `main` prints only `error:
DateTimeError.range`. All three asked for location and context: an error-return
trace when a failure leaves `main` (Zig has error-return traces; IDEAS.md
already notes the idea), or std errors that carry the call and the value. This
is language work, separate from the library.

**Teaching:** write `!` to pass a failure up, or `catch` to handle it, and
`catch panic("why")` where a program truly can't go on. A value fallback like
`d.add(days: n) ?? d` silently gives a wrong date; the docs say so.

## Decisions for the owner

1. **Adopt "total or visible"** for datetime and the migration of the merged
   phases (`add` gains `!`; `checked_add` becomes `add`; `since`/`unix()` gain
   `!`; the migration script rewrites call sites and writes `catch panic("...")`
   only where a function can't pass a failure up). Default: yes.
2. **Constant arguments drop the `!`** (a language rule, 2 of 3 for it): when
   every argument to a listed std maker is a compile-time constant that passes
   the check the compiler already runs, the call returns the plain type and a bad
   value is a compile error: `Date.new(2026, 1, 31)`,
   `TimeZone.fixed(hours: 5)`, `time.duration(ms: 250)`, with no `!`; the same
   calls with a run-time value take `!`. The source shows which case applies (all
   literals), and it never changes between releases. About 100 to 200 compiler
   lines. The dissent: it makes `!` depend on the arguments. A prover-based
   version was rejected by all three. Default: yes, as its own PR. If no:
   `time.duration` takes constants only and `time.checked_duration(<form>) ->
   Duration!` takes run-time numbers.
3. **Duration operators** (§5.6, planned after phase 6): `+` on two durations
   can overflow, and an operator can't carry `!`, so they'd be the only panic
   left. Default: drop them; `a.add(b)!` stays.
4. **`Duration` stays one `Int`** (8 bytes), with `since` returning `Duration!`.
   A 16-byte `Duration` would make `since` total but put `!` on `ns()`, `us()`
   and `ms()`, which are on every timing line. Default: keep one `Int`.
5. **Error traces**, as their own language change, before datetime phase 4.
   Default: yes.
6. **Language-wide**, outside datetime: Rig's own `Int` `+` panics on overflow
   when a user's number drives it. Whether the language should hold the same bar
   is a larger question. Default: note it in IDEAS.md, decide later.

## Order of work (if approved)

1. Error traces (language), so strict failures read well.
2. The constant-argument rule (language), if approved.
3. Datetime "total or visible": the Unix makers, every row above, `min`/`max`,
   no `panic(` in std, migration of Rig's tree and Trig.
4. The keyword-only rule (decided separately), then phases 4 to 6 written to
   this strategy from the start.
