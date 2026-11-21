# Committee report (Rig compiler and language view): no panics in std.datetime

Read: PROPOSAL.md, rust.md, zig-go.md, design.md; Rig main e38454865 `AGENTS.md`,
SPEC §1 ("Both modes keep every check"), §13 (Errors), §17 (`panic`),
`docs/design/datetime.md` (all), `std/time.rig`, `std/datetime/*.rig`,
`src/typecheck.zig` `stdArgChecks` and its checks, `src/proofs.zig` header,
`src/runtime.zig` `durationInt`/`durationFloat`/`durationSum`; Jiff 1.0.0
`timestamp.rs`, `zoned.rs`, `civil/{date,datetime,time}.rs`, `signed_duration.rs`.
Probes are in `scratchpad/unix/c-rig/` (`p1.rig`, `lenient.rig`, `strict.rig`,
`visible.rig`), run with `RIG_STD=std bin/rig run`.

The owner's bar, as clarified: **normal code never panics because of a value a user
gave, including one that later flows into arithmetic (a user's 9999-12-31 plus a
day). A panic is for extraordinary system failure.**

## 1. The principle: strict where failure is possible, total by construction elsewhere

**Decision: no datetime function or method panics. A call that can leave a range
returns `!`. A call that cannot fail has no `!`, and the design works to make more
calls unable to fail, so the `!`s that remain each mark a real failure.** That is
the strict reading, with no `!` on calls that cannot fail. The lenient reading
does not meet the owner's bar, for four reasons.

1. **The library cannot tell input from arithmetic.** Lenient says "never on input,
   only on arithmetic past the range". But the user's number becomes arithmetic one
   line later. Probe `lenient.rig`: a renewal period read from a file
   (`text.parse_int("200000")!`) flows into `start.add(months: period * k)` and
   panics: `datetime.Date.add: 2027-01-31 plus years: 0, months: 200000 … is beyond
   the range of dates`. That is exactly the owner's "joker entered a bad date". The
   line between input and arithmetic belongs to the caller's data flow, which
   `Date.add` cannot see. Only the result type can carry the failure.
2. **The `Int` analogy fails on range.** `Int` overflow is accepted because ±9.2e18
   cannot be reached by plausible data, so reaching it is a bug. A date's range is
   ±9999 years: ±240,000 months, ±7.3 million days. Plausible bad data reaches that
   every day: the sentinel `99999999`, milliseconds mistaken for seconds, `9999-12-31`
   stored as "no end" plus one day. `Duration`'s ±292 years is reachable too (a
   timeout of `1e10` seconds in a config file). So these failures come from data and
   need an error.
3. **Jiff, the model, is strict on every named method.** Checked in source:
   `Date::checked_add`, `Timestamp::checked_add`, `Zoned::checked_add`,
   `Zoned::round`, `Zoned::start_of_day`, `end_of_day`, `first_of_month`,
   `tomorrow`, and `DateTime::round` all return `Result`. Only the `+` operator
   panics (`civil/date.rs:2097`, `.expect("adding span to date overflowed")`). Rig
   has no operator on these types, so following Jiff means every range-leaving
   method returns `!`.
4. **Strict is smaller.** Lenient doubles the surface: `checked_add`, `checked_sub`,
   `checked_times`, plus the new `checked_round`, `checked_floor`,
   `checked_start_of_day`, `checked_div`, `checked_neg`, and so on. Strict has one
   name per operation, and the caller picks a policy with Rig's existing tools:
   `!` passes the failure up, `catch fallback` substitutes a value, and
   `catch panic("…")` panics in the caller's own source, visibly (probe
   `visible.rig`: `d.checked_add(days: 1) catch panic("no tomorrow after", d)`).
   That last form is the North Star's "effects stay visible" applied to panics:
   the only panics left are ones a program writes itself.

**What strict costs.** `x = d.add(months: 1)!` inside a `sub main()!` or a fallible
function costs one character (probe `strict.rig`, which reads cleanly). In a
function that cannot fail, the author writes `catch`, which states a decision that
was hidden before. A function that does calendar arithmetic on user data was
always fallible; strict makes it say so.

**Making more calls total (no `!` where nothing can fail):**
- `Duration`'s range becomes symmetric, ±(2^63−1) ns, leaving out `Int.min`. Then
  `neg()` and `abs()` cannot fail, and `div(n)` fails only for `n == 0`.
- `Monotonic` readings are never negative (`at` refuses a negative). Then
  `since` and `elapsed()` of two readings always fit in an `Int` and stay total.
- These stay total and keep no `!`: the readers, `first_of_month`,
  `last_of_month`, `Instant.in_zone(tz)`, `Date.at(t)`, `Time.round` and
  `Time.floor` (which wrap, and take constant increments), the new
  `Time.wrapping_add`, `from_unix_ns`, `datetime.now()`, `time.monotonic()`,
  `time.duration(<constant form>)`, and `Duration.parse` (already `!`).
- `datetime.now()` today ends in `?? panic(...)`, which can never be reached
  (`wall_ns` is an `Int`, so 1677 to 2262). Build it without the optional, so std
  holds no `panic(` call at all. Add a test that greps `std/time.rig` and
  `std/datetime/` for `panic(` and finds none. That makes the owner's promise
  something the suite checks.

## 2. The inventory

| # | Decision | Exact signature |
|---|---|---|
| 1 | **Accept** | `Instant.from_unix_s(s: Int, ns: Int = 0) -> Instant!`, `from_unix_ms(ms: Int) -> Instant!`, `from_unix_us(us: Int) -> Instant!`, `from_unix_ns(ns: Int) -> Instant` (total). Inverses: `unix_s()`, `unix_ms()`, `unix_us() -> Int` (floored, exact), and `unix_ns() -> I128` (exact, total), **replacing `unix() -> Duration`**, which saturates (see 4.1). Remove `from_unix(<form>)`. |
| 2 | **Include** | `Instant.from_unix_float(s: Float) -> Instant!`: `.invalid` for NaN, `.range` for an infinity or a value beyond the range. Rig has no checked `Float -> Int` conversion, so without this maker a user writes `Int(f)`, which panics on NaN. The library would route its users into the panic it promises to avoid. |
| 3 | **Replace** with one rule for duration forms (below), and the gate `time.Duration.from(<form>) -> Duration!` (the name pairs with `Duration.parse`; strict retires the `checked_` prefix, so not `time.checked_duration`). `time.duration(<form>) -> Duration` takes constant forms and `Duration` values only. | |
| 4 | **Subsumed.** The `checked_` methods go away. A run-time number in a form fails through the `!` of the call it is given to. | |
| 5 | **Strict** | `Instant.add(d) -> Instant!`, `round(…) -> Instant!`, `floor(…) -> Instant!`; `Date.add(…) -> Date!`; `DateTime.add/round/floor -> DateTime!`; `ZonedDateTime.add/round/floor/start_of_day -> ZonedDateTime!` (this reverses 6.7's "cannot fail"; phase 5 is unbuilt, and Jiff's returns `Result`). `Time.add(d) -> Time!` fails past midnight (today's `checked_add`). New `Time.wrapping_add(d) -> Time` is the clock-face sum, Jiff's name: Rig spells wrapping (`+%`), so a plain `add` should not wrap silently. A calendar sum whose months or days overflow an `Int` fails `.range` in `add` too, never panics. |
| 6 | **Strict** | `Monotonic.add(d) -> Monotonic!`, `Monotonic.at(d) -> Monotonic!` (fails for a negative `d` or one beyond the range). `since` and `elapsed` stay total (see 1). |
| 7 | **Strict** | `Duration.add/sub(d) -> Duration!`, `times(n: Int) -> Duration!`, `div(n: Int) -> Duration!` (fails only for 0), `round/floor(…) -> Duration!`. `neg()` and `abs()` total, given the symmetric range. Retire `checked_add`, `checked_sub`, `checked_times`. |
| 8 | **Accept** | `Duration.from_parts(seconds: Int, ns: Int) -> Duration!` |
| 9 | **Accept** | `TimeZone.fixed(hours: Int = 0, minutes: Int = 0) -> TimeZone!`. Literals are still checked at compile time. See 3.4 for dropping the `!` on literals. |
| 10 | **Accept** constant increments only. They keep `Time.round` and `Time.floor` total. For the types whose `round` is `!` anyway, a run-time increment could fold into that failure later at no cost to the surface. |
| 11 | **Moot.** std holds no panic. The only panics left in a datetime program are the program's own `catch panic(…)`, `Int` arithmetic, and numeric conversions, all language rules. |

**The duration-form rule** (rows 3 and 4): *a number known only at run time becomes
a `Duration` only under a `!` or a `catch`.*
- A constant is checked at compile time, as today. A `Duration` value passes as it
  is.
- A run-time `Int` or `Float` given to a std call that fails with a `range` member
  (every `add`, `Monotonic.at`, `Duration.from`) is converted inside that call's
  failure: `.range` beyond the range, `.invalid` for NaN. `i.add(ms: t)!` has one
  `!`, which covers both the conversion and the sum. Both `TimeError` and
  `DateTimeError` already have `invalid` and `range`.
- In a wait (`sleep`, `within`, `after`, `per:`), a run-time `Int` beyond the range
  waits as long as the scheduler can (5.8, unchanged; correct by meaning). A
  run-time `Float` is refused at compile time, with the fix `Duration.from(x)!`.
- Anywhere else (`time.duration`, `Time.wrapping_add`, a user's function whose
  error set has no `range`), a run-time number is a compile error whose fix is
  `time.Duration.from(ms: t)!`.
- Cost: typecheck records which form converts fallibly, as a positive list on the
  callee: fallible, from std, with a `range` member. Emit writes
  `try rig.durationIntChecked(...)`, mapped to the callee's error, so the checker
  checks what emit writes (North Star 4). The runtime gains the checked twins of
  `durationInt`, `durationFloat` and `durationSum`. About 150 to 250 lines, medium
  risk: every form site passes through `emit.zig:6021`. In Rig's tree, the run-time
  forms are almost all waits (`time.sleep(ms: ms)!` in benches), which do not
  change.

## 3. Open points

1. **A `Float` Unix maker:** yes, `from_unix_float(s: Float) -> Instant!` (row 2).
   Its doc states the resolution: about 240 ns near 2023.
2. **Run-time `Float` duration forms:** allowed only where they fail through a
   `!` (the rule above). Refused in waits and where nothing can fail.
3. **Constant-only `round` increments:** yes (row 10).
4. **Removing `!` where the compiler proves a call cannot fail.** There are two
   tiers, and only the first should be pursued.
   - **Pursue: the constant tier.** When every argument of a listed std maker is a
     compile-time constant and its std check passes, the call may be written
     without `!`, because no run-time failure exists. The makers:
     `Date.new`, `Time.new`, `DateTime.new`, `TimeZone.fixed`, `TimeZone.named`
     with a literal, `from_unix_s/ms/us` with a constant, and `Duration.from` with
     a constant. The machinery exists: `stdArgChecks` already decides literal
     increments with `constInt`, and 10.2 plans the literal checks of `named` and
     `fixed`. Recorded once as a fact on the call (North Star 4), this is a
     constant-folding fact, not a flow proof. Its answer never changes between
     releases. If a refactor turns the literal into a variable, the `!` becomes
     required, which is exactly the point where failure becomes possible. Cost: about
     100 to 200 lines, plus validity rules held twice (as `format`'s directive
     table already is), with a test that runs every maker both ways. It also
     needs one sentence in SPEC §13 ("a bare call to a fallible function is
     rejected, unless the compiler evaluated it at compile time and it succeeded").
     It removes the most visible noise: `Date.new(2026, 1, 31)` and
     `TimeZone.fixed(hours: 5, minutes: 30)` in examples and tests.
   - **Do not pursue: the flow tier.** That would drop `!` on `d.add(days: 1)` where
     `d` is proven at most 9999-12-30. `proofs.zig` is an emit optimization: emit
     omits a proven check, and the debug build still makes it as an assertion. It
     never changes types. Letting it decide whether a call is fallible would move
     typing into an optimizer pass. A call's spelling would then depend on how far
     the prover reaches, which grows from release to release. It would also need
     range facts about datetime values that the prover's six `Int` and length facts
     do not have.

## 4. What else, ranked

1. **`since` and `unix()` saturate: a silent wrong answer.** That is worse under
   the North Star than a panic ("no feature hides a failure"). `a.since(b)` for two
   user dates 300 years apart returns ±292 years without a word. Fix:
   `Instant/DateTime/ZonedDateTime.since(other) -> Duration!`, replace `unix()` by
   the exact `unix_ns() -> I128` (row 1), and keep `Monotonic.since` and `elapsed`
   total (see 1). The alternative is the owner's call: widen `Duration` to 16 bytes
   as Jiff's is. Then `since` and the offsets are total, at the measured cost of
   1.9 ns on `elapsed()` (phase 0). It is a migration of phase 1, and it removes
   every saturation in the design.
2. **Saturating by choice needs the ends.** Under strict, Jiff's `saturating_add`
   is `d.add(days: n) catch datetime.Date.max()`, but there is no `max()`. Probe
   `visible.rig` needed `catch (datetime.Date.new(9999, 12, 31) catch d)`. Add
   total `min()` and `max()` to `Date`, `DateTime`, `Instant` and `Duration`; Rig
   has no type constants, so they are functions.
3. **Duration operators (5.6) would be the one remaining panic, and they are
   reachable by user values.** `d1 + d2` overflows at ±292 years, which a user's
   number reaches far more easily than an `Int`'s ±9.2e18. Default: do not add
   them. The `!` methods are enough, and `total = total.add(d)!` reads fine.
   Otherwise they panic as `Int`'s operators do, and the docs say so.
4. **`Time.add` wraps under a plain name** (row 5). Rig spells wrapping. Rename the
   wrapping sum to `wrapping_add`, and let `add` fail past midnight.
5. **Recurrences.** 6.2 documents in prose the drift trap (stepping from the
   previous result gives Jan 31, Feb 28, Mar 28). Jiff's `series(period)` makes the
   right way the easy way. A `start.series(months: 1)` iterator, anchored to the
   start, is worth a later phase.
6. **Errors say nothing about where.** `DateTimeError` is `invalid` or `range`,
   with no position or field. Jiff's parse errors name the offset. Strict turns
   more failures into errors, so the phase-4-to-6 error sets should at least be fine
   grained (10.3 lists them). A position for `parse` would need error payloads,
   a language question.
7. **Embedded zone data ages with the binary** (7.5, [Owner]). A long-lived server
   gives wrong local times after a government changes its rules, and Jiff reads the
   system copy for that reason. This is not a panic, but it decides "among the best"
   for servers. Keeping `TimeZone` an index leaves the door open. It is worth one
   line in the docs next to `tzdb_version()`.

## Cost summary

- **std:** signatures move to `!`, and the `checked_` twins go away (net smaller).
  New: `wrapping_add`, `from_unix_*`, `Duration.from`, `min()` and `max()`, and the
  symmetric `Duration` range.
- **Compiler:** the duration-form rule (150 to 250 lines). The constant tier of
  `!` elision (100 to 200 lines, plus a SPEC sentence). No flow-proof work.
- **Migration** of phases 1 to 3: `x.checked_add(…)` becomes `x.add(…)`, and
  `x.add(…)` becomes `x.add(…)!`. In a function that cannot fail,
  `migrate-datetime.py` writes `catch panic("…")`, so the old panic becomes visible
  where it was. The compiler's "must be wrapped with `!` or `catch`" error finds
  every site the script misses. The users are only Rig's own tests: datetime appears
  in five `test/rig` files and a few benches, which use `elapsed`.
