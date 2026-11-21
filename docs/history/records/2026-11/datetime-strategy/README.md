# Datetime's strategy: total or visible (2026-11-22)

The datetime design (docs/design/datetime.md, the owner's v3) as built in
phases 1 to 3 panicked in several calls: `add`, `round`, `floor` and
`start_of_day` past the range, `Duration`'s arithmetic, `from_parts` and
a computed rounding increment, and a duration form given a run-time number
beyond a `Duration`; and `since` and `unix()` saturated. The question
began with `Instant.from_unix(<duration form>)`, which panicked on a Unix
number past 2262 and could make no instant beyond it, and the owner's
"why isn't this simply fallible?". It ended as a rule for the whole
library. The design states the result; this record says how it was
decided.

## The owner's bar

> "We cannot panic. We must have effects stay visible. ... It needs to be
> excellent, not sloppy and awkward. ... Spiritually inherit from Jiff and
> jump to the right answer immediately. Our DateTime library should be one
> of the best in all software."

and, asked whether that meant every call or only input:

> "We cannot have normal code panicking. That is a hard crash. It should
> only happen in extraordinary cases of system failure, not just some
> joker entered a bad date."

## How it was decided

| Step | Who | Report |
|---|---|---|
| First panel, on making an `Instant` from a Unix time | Rust's time libraries; Zig and Go; API design | [rust.md](rust.md), [zig-go.md](zig-go.md), [design.md](design.md), from [BRIEF.md](BRIEF.md) |
| The coordinator's synthesis: a principle, every panic in the design with a proposed fix, strict against lenient | | [PROPOSAL.md](PROPOSAL.md) |
| Committee of three, on the principle and each row | a date-time library view; an error-handling view; Rig's compiler and language view | [c-library.md](c-library.md), [c-errors.md](c-errors.md), [c-rig.md](c-rig.md), from [COMMITTEE.md](COMMITTEE.md) |
| The strategy, settled from the panels and the committee | | [FINAL-STRATEGY.md](FINAL-STRATEGY.md) |
| An independent rating of the library with the strategy applied, against Jiff, Temporal, java.time, Noda Time, chrono, Go, Python and Swift | | [RATING.md](RATING.md) |

The probe programs the reports cite are kept beside them: `c/`
(c-errors.md), `clib/` (c-library.md), `c-rig/` (c-rig.md), `d/`
(design.md), `go/` (zig-go.md) and `probes/` (the rating). They ran
against main e38454865 with `RIG_STD` set to its `std/`.

What they found:

- **All three panelists** chose per-unit Unix makers taking an `Int`
  (`from_unix_s`, `from_unix_ms`, `from_unix_us`, and a total
  `from_unix_ns`), each fallible, over a duration form, which cannot see
  its own number and stops at 2262. Two of three left out a `Float`
  maker; the committee, all three, put it in (`from_unix_float`), since
  Rig has no checked `Float` to `Int` conversion and `Int(f)` panics on a
  NaN.
- **All three committee members** chose, apart, the same principle: every
  call is total or returns `!`; nothing panics; nothing saturates; ranges
  are chosen to make calls total where a `!` would be noise. Each ran
  programs that crashed on ordinary data under the lenient reading (a
  user's 9999-12-31 plus a day, a renewal period from a file, a valid
  instant near the end rounded to the second), and each found that Jiff's
  named methods return `Result` and only its operators panic. Two of three
  wanted constant arguments to drop the `!`; all three rejected a version
  that asks the prover. All three asked for error traces, since a strict
  failure that reaches `main` names nothing.
- **The rating** scored the library 8 overall with the strategy applied
  (about 7 as built), with correctness, performance and verification at 9.
  Its second weakness was the one-`Int` `Duration`, which makes `since`
  and `unix()` fallible on every call, and its second step to a 10 was a
  16-byte `Duration` that makes them total.

## The owner's decisions (2026-11-22)

1. **"Total or visible"**, for the whole library and the migration of
   phases 1 to 3: `add` gains `!`, `checked_add` becomes `add`, every
   `checked_` twin goes. Approved at the default.
2. **Constant arguments drop the `!`**, as a language rule of its own.
   Approved at the default. Without it, `time.duration` would take only
   forms that cannot fail and `time.checked_duration` the rest.
3. **No operators on `Duration`.** Approved at the default: `+` could
   overflow and an operator cannot carry `!`.
4. **`Duration` takes Jiff's 16 bytes**, whole seconds in an `Int` and
   nanoseconds, ±292 billion years. This reverses the strategy's default,
   which kept one `Int` and gave `since` and `unix()` a `!`. With 16 bytes
   `since` and `unix()` are total, with no `!` and no saturation;
   `seconds()` returns an `Int`, and `ms()`, `us()` and `ns()` an `I128`;
   `Duration`'s own `add`, `sub`, `times`, `div`, `round` and `floor` keep
   `!`, since they can still pass ±292 billion years, and `div` can be
   given 0. FINAL-STRATEGY.md shows decision 4 as it was put to him.
5. **Error traces** as their own language change, before datetime's
   phase 4. Approved at the default.
6. **The language-wide question**, whether Rig's own `Int` arithmetic
   should meet the same bar, is noted in docs/IDEAS.md and decided later.

## What the design took from it

The design's "Total or visible" section and every place tagged
[Owner, 2026-11-22]: the rule; the 16-byte `Duration`, its `I128`
readers and its symmetric range; the duration forms with a run-time number
(total where every value fits, folded into a fallible call's `!`, clamped
in a wait, a compile error elsewhere); `Monotonic` readings within 146
years; `!` on every `add`, `round`, `floor`, `start_of_day`,
`Monotonic.add` and `at`, `Duration.from_parts` and `TimeZone.fixed`; the
Unix makers and readers; `min()` and `max()`; no operators; a test that
finds no `panic(` in std's time code; and the order of work: error traces,
the constant-argument rule, the change that applies the strategy to phases
1 to 3, the keyword-only rule (decided separately), then phases 4 to 6
written to it.

Two points the strategy left open the design settles from it:

- With 16 bytes, a run-time `Int` of `ns:`, `us:`, `ms:` or `seconds:`
  always fits, so those forms are total everywhere and need no `!`; only a
  `Float`, `minutes:` or `hours:`, or several keywords summed can fail.
- `Time.round` and `Time.floor` are total, so their increment must be a
  constant; a computed one fails `.invalid` on the types whose `round`
  already returns `!`.
