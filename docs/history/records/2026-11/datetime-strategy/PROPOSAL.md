# Proposal: no hidden panics in Rig's datetime library

The owner's direction (2026-11-22): **"We cannot panic. We must have effects
stay visible."** The library should inherit Jiff's best ideas, avoid what other
libraries learned the hard way, and be among the best date-time libraries in any
language, from its first release. This proposal is the coordinator's synthesis of
a first panel (Rust, Zig and Go, API design: `rust.md`, `zig-go.md`,
`design.md` in this folder). A second committee reviews it.

## The baseline Rig gives

- **Rig's `Int` arithmetic panics on overflow** in every build mode (SPEC,
  "Both modes keep every check"), and `panic` is "for a bug: a state the program
  cannot go on from" (SPEC §17). `+%` wraps by choice. A constant that overflows
  is a compile error.
- **Fallible calls** return `T!`, are written `f()!` (passing the error up),
  `f() catch ...`, or `f() ?? fallback`. The `!` at the call is the visible
  effect.
- So a datetime library can't do better than the language for arithmetic the
  program itself writes, but it can make sure that **no value from outside, and
  no valid value, ever reaches a panic**, and that every place a panic could
  happen has a visible, fallible twin.

## The principle proposed

> **A datetime call panics only where the same arithmetic on an `Int` would:
> arithmetic the program wrote that walks past the range. Never on text, parts
> or a number from outside; never on a valid value; never hidden inside an
> argument. Every call that can panic has a `checked_` twin that fails with
> `!` instead, and every input path is fallible.**

Open question for the committee: is that the owner's "we cannot panic", or does
he mean the stricter reading, that **no datetime call panics at all** (every
range-leaving operation returns `!`)? Both are laid out below; the committee
recommends one.

## Inventory: every panic in the design today (§5.2, §7.2) and its fix

| # | Panic today | Proposed |
|---|---|---|
| 1 | `Instant.from_unix(<duration form>)` with a non-constant number past ±292 years or NaN: the panic happens converting the argument, before the call, with no `!` visible; years 2263 to 9999 unreachable | **Replace** with `Instant.from_unix_s(s: Int, ns: Int = 0) -> Instant!`, `from_unix_ms(ms: Int) -> Instant!`, `from_unix_us(us: Int) -> Instant!` (fail with `.range` outside -9999 to 9999; computed in `I128`), and `from_unix_ns(ns: Int) -> Instant` (cannot fail: ±292 years). Inverses `unix_s()` (exists), `unix_ms()`, `unix_us()` (new, floored, exact), and `unix()` as now. All three experts agree. |
| 2 | A `Float` of Unix seconds | **Open (panel split 2 to 1):** leave it out (callers convert to `Int` where NaN shows) vs. `from_unix_float(s: Float) -> Instant!` (`.invalid` on NaN, `.range` on infinities and beyond), because Rig has no checked `Float -> Int` conversion and `Int(f * 1000)` itself panics on NaN. Coordinator leans to `from_unix_float`, given that gap. |
| 3 | A duration form given a non-constant number out of range or not finite (`sleep(ms: x)`, `add(ms: x)`, `time.duration(x)`) | **Add `time.checked_duration(<form>) -> Duration!`** as the one gate for numbers from outside (convert once where the number comes in; then pass the `Duration`, which nothing can make fail). Under the strict reading: also refuse a non-constant `Float` form at compile time, so a `Float` reaches a duration only through the gate. |
| 4 | `checked_add(ms: t)` panics when `t` is out of range, because the form converts before the call | **`checked_` methods fail, never panic, on their own arguments too:** a non-constant form passed to a `checked_` method is converted inside it. |
| 5 | `add`, `round`, `floor`, `start_of_day` on `Instant` and the calendar types, past the range | Lenient: keep the panic (Jiff's operators do the same), with `checked_add` (exists), `checked_round`, `checked_floor`, `checked_start_of_day`. Strict: these return `!` themselves. |
| 6 | `Monotonic.add`, `Monotonic.at` past 292 years | Same as 5. |
| 7 | `Duration`'s `add`, `sub`, `times`, `div`, `neg`, `abs`, `round`, `floor` past the range; `div(0)` | Lenient: as `Int` (panic), with `checked_` twins for each (some exist). Strict: `!` on each. |
| 8 | `Duration.from_parts(s, ns)` with bad parts | **Fallible**: `-> Duration!` (it builds from parts, which §7.2 says is fallible). |
| 9 | `TimeZone.fixed(...)` with non-literal arguments out of range or of mixed sign | **Fallible**: `-> TimeZone!`; literal arguments still checked at compile time. |
| 10 | `round`/`floor` with a non-literal increment that isn't allowed | **Constant increments only** (a compile error otherwise), so the check is always at compile time; a computed increment is a rare need that a later `checked_round(by:)!` can meet. |
| 11 | Panic messages that name neither the call nor the number | Every remaining panic names the call and the value. |

## Ideas to weigh

- **Strict vs. lenient.** Strict means `d.add(days: 1)!` on every add: no panics
  at all, but `!` on calls that fail only at the year 9999. Temporal throws a
  `RangeError` from `add` (an exception, visible to no one); Jiff's methods return
  `Result` and its operators panic; java.time throws. Rig's `!` is cheap to pass
  up (`x = d.add(days: 1)!` in a `sub main()!`), so strict may cost less in Rig
  than elsewhere.
- **Proof-elided `!`?** Rig has a prover (`src/proofs.zig`). A fallible call
  whose failure the compiler can disprove (all-literal `TimeZone.fixed(hours: 5,
  minutes: 30)`, `Date.new(2026, 1, 31)`) could need no `!`. That would be a
  language change; note it, don't decide it here.
- **What else Jiff got right that the design should keep or check:** spans vs.
  Rig's keyword amounts (§6.1), the `Zoned` round-trip of RFC 9557, disambiguation
  of skipped and repeated times (`.compatible`, `.earlier`, `.later`, `.reject`),
  the bundled tzdb with a freshness test, `since` saturating only where the
  representation forces it.
