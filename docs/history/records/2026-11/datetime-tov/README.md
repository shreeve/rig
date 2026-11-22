# Total or visible: phases 1 to 3 to the strategy (2026-11-22)

The owner's datetime strategy, "total or visible" (2026-11-22;
`records/2026-11/datetime-strategy`), applied to what phases 1 to 3
built, as docs/design/datetime.md 10.7 and section 11 (step c) list it:
every call of std.time and std.datetime is total or returns `!`, none
panics on any value, nothing saturates, and `Duration` takes Jiff's 16
bytes. Branch `datetime-tov`, from `named-options` (abe3beb53), rebased
onto main once #1211 merged.

## What landed

| Part | Where |
|---|---|
| `Duration` of 16 bytes: whole seconds `s: Int` within ±(2^63 - 1) and `nano: I32` of one sign; `ms()`, `us()`, `ns()` as `I128`; `add`, `sub`, `times`, `div`, `round`, `floor` returning `!`; `neg`, `abs` total; `min()`, `max()`; `from_parts` returning `!`; `checked_*` deleted | `std/time.rig` |
| `Monotonic`: readings within 0 to 2^62 ns, `at` and `add` returning `!`, `since` and `elapsed` total; waits clamp a duration longer than the scheduler holds (`wait_ns`) | `std/time.rig` |
| `Date`, `DateTime`, `Instant`: `add`, `round`, `floor` returning `!`; `Time.add`, `round`, `floor` total (wrapping); `since` and `unix()` exact; `min()`, `max()`; the Unix makers `from_unix_s(s, ns:)!`, `_ms`, `_us`, `_float`, and total `_ns`; `unix_ms()`, `unix_us()`; `from_unix` removed; no `panic(` | `std/datetime/*.rig` |
| The runtime's duration helpers: two fields; `Try` twins giving the callee's own error, `Clamp` twins for waits; parts summed exactly in `i128`; `durationNs` clamped | `src/runtime.zig` |
| How a form converts, decided once (`sema.DurationHow`: total, clamped, folded with the callee's set), refused elsewhere with the fix; `time.duration` plain for a form that cannot fail; a computed increment refused on a `Time`; the constant rule's makers `Duration.from_parts` and `Instant.from_unix_s`, `_ms`, `_us` | `src/sema.zig`, `src/typecheck.zig` |
| Emit: a call whose form is folded is a block the conversion breaks out of with the callee's error, a hoisted call's block too | `src/emit.zig` |
| Tests: every file of std-time and std-datetime rewritten where its purpose changed; `std-datetime-total` (the committee's three programs, every row of 7.2 at the ends, the forms at each kind of site, the 16-byte layout); the Jiff ports left out for the old range; `cli.datetime_no_panic`; `cli.migrate_tov` | `test/rig`, `test/cli` |
| The oracle: no saturation left out | `tools/jiff-oracle` |
| Migration | `tools/migrate-tov.py`; Trig: `trig.patch` here |
| Docs | STD, SPEC Durations and §13, learn 06, CHANGELOG, MIGRATING-0.3, INTERNALS, the design, HANDOFF, AGENTS |

## Decisions

1. **A bare `Int` and `seconds:` known only as the program runs can
   fail.** The design (5.2) called them total, but `Int.min` seconds is
   one past the symmetric range the owner chose so that `neg()` cannot
   fail. Rather than panic or saturate on that one value, they are among
   the forms that can fail: folded into a fallible call, clamped in a
   wait, refused elsewhere. Only `ns:`, `us:`, `ms:` are total. The
   design's 5.2 says so, tagged [Judgment]. **For the designer.**
2. **`time.duration` of a total form is a plain `Duration`** (5.2), not
   only of constants; the brief's "constant rule" wording is the
   narrower reading. `!` on it says its form cannot fail.
3. **Which set a folded conversion fails with:** the callee's own set if
   it has `range` and `invalid`; for a callee that may fail with any
   error, `DateTimeError` for std.datetime's and `TimeError` for every
   other (a program's too); otherwise refused. Zig names errors per
   set, so the runtime's `Try` twins take the error values and return a
   set of their own, which joins a declared set.
4. **A task's call takes no folded form**: its arguments are made as it
   starts and its failure is taken where it is waited; refused, saying
   so.
5. **std.datetime builds a `Duration` from its fields** (std modules
   construct one another's objects), so `since` and `unix()` are total
   without a fallible `from_parts`.
6. **A `Time`'s increment is constant-only**; its body's unreachable
   other increment rounds to the nanosecond (`clock_step`, `catch 1`),
   not a panic.
7. **Fields `s` and `nano`**, since a field cannot share its reader's
   name `ns`.
8. **A new script, `tools/migrate-tov.py`, driven by `rig check`** in
   `migrate-options.py`'s style, rather than extending the regex-driven
   `migrate-datetime.py`: every site is a compile error first. Its
   `catch panic("...")` is parenthesized, so it fits any expression.
9. **The oracle's one deliberate skip**: Jiff's `SignedDuration` holds
   `i64::MIN` seconds, past Rig's symmetric range.
10. `Duration.parse` beyond the range stays `invalid` (text); a monotonic
    reading from the system clock is trusted (it counts from boot).

## Newly refused forms

A bare call of each `add`, `round`, `floor`, `Monotonic.at`/`add` and
`Duration` arithmetic without `!`; the `checked_*` methods;
`Instant.from_unix`; an `I128` reader where an `Int` is wanted; a
`Float` known only as the program runs given to a wait; a form that can
fail given to a call that cannot (a `Time`'s `add`, a program's plain
function, a task's call); a computed increment of a `Time`; `!` on
`time.duration` of a total form and on a constant Unix maker or
`from_parts`. 0.3.0 accepted the wait `Float` and the reading's `add`
and `at` without `!` (CHANGELOG, "Upgrading from v0.3.0").

## Migration

In Rig's tree `migrate-tov.py` rewrote 719 sites (tests, benches, docs,
the oracle); each test whose purpose changed was rewritten by hand.
Trig: one line, `tools/trig/main.rig`'s `clock()`, reads
`Int(datetime.now().unix().ns())` (`trig.patch`, on top of the
datetime phase 1, phase 3 and named-options-rule patches; checked with
this `rig`); `tools/checker/bench.rig` checks clean. loco uses neither
module: no patch.

## Measured

- **The oracle**: calendar 605,870 the same, counts 234,040, text
  26,072 (1 skip, decision 9), round 55,000; 920,982 in all, none
  different (891,707 before, with the saturated cases skipped).
- **bench/duration's calls, against main** (ccc0f2139), the real
  std.time of each, fastest of 20 rounds, five interleaved runs each,
  under `tools/mac-claim`: `elapsed()` 13.42 to 15.47 ns (2.05 ns more,
  phase 0 measured about 1.9); `since` 0.30 to 0.59 ns; a deadline's
  `add` 0.29 to 0.55 ns (now `add(...)!`); `sleep(0)` 0.23 to 0.79 ns.
- **emit-diff** against abe3beb53 (and main, the same list): std.time's
  module in every program that uses it; `rig/runtime.zig`'s duration
  helpers (+96 -27); benches' `Int(...)` of an `I128` reader;
  bigint's `time.duration` constant now unwrapped as a maker (ids
  renumbered); `bench/par/workers` inlines `math.min` where the
  program-wide budget moved; bench/duration emits only with this Rig.
  Trig not compared (its generated `buildinfo`).
- **check guard** (`bench/check/guard.py`, under `tools/mac-claim`, at a
  load of 4.4 to 4.5): 2,184,928,491 instructions for the branch and
  2,178,630,147 for main, 0.29% more (the branch carries the
  named-options rule too); 1.3% over the committed baseline, within its
  2%; every pass's time and scaling level with main.

## Verification

`zig build`, `zig build test`; the core suite once (12,521 jobs, 12
died: the CLI scripts and the design's examples since fixed, each
rerun green: the migration scripts, the preempt and scheduler scripts,
`cli.std_http`, `doc-design-datetime`); every doc's examples; the time
and datetime areas, `std-datetime-total`, `cli.jiff_oracle`,
`cli.migrate_tov`, `cli.datetime_no_panic`. Not run here, by the
coordinator: the json, hash and text guards, the Trig and loco light
gates, pup.

## After review (2026-11-22)

Two independent reviews of 91d3d942b; decision 1 stands, put to the
owner. Fixed, each with its failing case first:

1. A deterministic run's virtual clock, moved past 2^62 ns by a clamped
   wait, panicked in `monotonicNs` and `sinceStartNs` (`@intCast` of the
   i96 clock): a reading is now clamped within 0 and 2^62
   (`tasks.readingNs`), keeping `Monotonic`'s promise
   (`cli.virtual_clock_far`, deterministic only).
2. Comments that still called an `Int` of seconds total.
3. A `Float` now converts from its exact value (the double is an integer
   times a power of two, so the product is exact before the one
   rounding): `rig.floatToNs` and its copy `sema.floatToNs` for duration
   forms and constants, and `exact_ns` in std.datetime for
   `from_unix_float`. `384.2288151825` gives ...182 ns, not ...183; a
   finite `Float` past the range fails `range`, not `invalid`.
4. `Duration.from_parts(Int.min, 0)` fails `range`, as `Int.min` seconds
   does as a form.
5. Minor: `migrate-tov.py`'s duplicate definitions removed; a removed
   `checked_*` names its replacement; a fallible `time.duration(...)`
   given as a duration is said once; in a function that cannot fail, the
   fix offered is `time.duration(...) catch ...`.
