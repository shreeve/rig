# Datetime phase 1: `std.time` (2026-11-21)

Phase 1 of the datetime design (docs/design/datetime.md, the owner's v3
of 2026-11-17, amended 2026-11-20: `Duration` is one `Int`). It builds
`std.time`'s `Duration` and `Monotonic`, the duration forms of one unit
at every place a call gives one, waiting, and the first check of a std
call's arguments; it removes `time.now()`, `time.Instant`, and the
constants of nanoseconds, and migrates Rig's tree. Phase 1b, several
unit keywords in one call, is a later change.

## What landed

| Part | Where |
|---|---|
| `Duration`: readers, `from_parts`, `subsec_ns`, arithmetic, `checked_*`, `round`, `floor`, `print`, `iso`, `parse`; `Monotonic`; `monotonic`, `since_start`, `duration`, `sleep`, `within` | `std/time.rig`, `std/time.zig` |
| A parameter typed `time.Duration` or `Duration?`, in any module, takes the forms (§10.1 row 1) | `resolve.zig` `paramDurations`, by the resolved type (`sema.durationParam`) |
| Unit keywords fill the one `Duration` parameter; two take each by name; `seconds:`, `minutes:`, `hours:`; `days:`, `weeks:`; a Duration value; the negative constant of a wait; no parameter named for a unit (rows 2 to 7) | `typecheck.zig` `checkArgs`, `checkDurationArg`, `badDurationKeyword`; `sema.duration` |
| The argument becomes the `Duration`, packed for a `Duration?`, or an `Int` of nanoseconds for `time.after` and `per:` (rows 8, 9) | `emit.zig`; `runtime.zig` `durationInt`, `durationFloat`, `durationNs` |
| `since_start` a Rig wrapper over a private extern (row 10) | `std/time.rig`; the runtime's flag is still keyed on the public name |
| The hook of §10.2 with its first check, `round` and `floor`, at a method call, a call through the type, and a method taken as a value | `typecheck.zig` `stdArgChecks`, `checkUnitIncrement`, `typeMember`; `sema.stdArgCheck` |
| The removed names, each with its fix | `sema.stdRenamed` |
| Tests | `test/rig/std-time.rig.test` (values, text, arithmetic, `Monotonic`), `std-time-forms` (each form at each kind of callee, the rejections), `std-time-waits` (waits, `seeds: 20`); `test/cli/migrate_datetime.sh` |
| Migration | `tools/migrate-datetime.py`; Rig's tests, benches, bench harnesses, and live docs |
| Trig | [trig.patch](trig.patch) |

The time cases of `test/rig/std-misc.rig.test`, its negative sleep among
them, moved to `std-time*.rig.test`, rewritten. The §10.1 row of several
unit keywords is phase 1b's.

## Decisions left to the builder

1. **The error set** is `time.TimeError`, with `invalid` (text that is
   not a duration, `Duration.parse`) and `range` (`checked_add`,
   `checked_sub`, `checked_times`), in the style of `text.ParseError`.
2. **The field** of `Duration` and `Monotonic` is `n`, private, so
   neither is made but by std.time's functions. The runtime fills and
   reads it by that name (`sema.duration.field`): emit writes
   `rig.durationInt(T, x, unit)` with `T` the `Duration`, and
   `rig.durationNs(d)` where `time.after` and `per:` take nanoseconds.
   A program that names neither std.time nor a `Duration` still writes
   `per: 0.5`, given to the runtime as an `Int`, with no `Duration` type
   loaded.
3. **The spellings** of §5.3 and §5.4 stand as the design gives them:
   `float_seconds()`, `subsec_ns()`, `Duration.from_parts(seconds, ns)`,
   and `times(n)`, `div(n)`. The private constants are `HOUR_NS` and its
   kin, never `MS`, so `time.MS` gets the removed name's fix, not "is
   private".
4. **`round` and `floor`** are declared with six optional `Int`
   parameters, `ns` to `hours`. The hook refuses any call but one unit by
   name, and a function value of either; the body panics on any other
   increment, which only a value the hook cannot see reaches.
5. **A negative constant** is what Rig's constant evaluation calls one
   (`sema.constIntOf`, as the range check of a duration already used): a
   literal, its negation, and a binding fixed to one, so `x = -3` then
   `time.sleep(x)` is refused too.
6. **`days:` and `weeks:`** give the fix that fits every place phase 1
   has, `hours: 24` (or the hours the count makes: `weeks: 2` is
   `hours: 336`). The fixes for a value with a date, `add(days:)`, and
   for an `Instant`, come with those types (phases 2 and 3).
7. **`Duration.parse`** is Jiff 1.0.0's parser, from its source
   (`fmt/friendly/parser.rs`, `parser_label.rs`, `fmt/temporal/parser.rs`,
   `fmt/util.rs`): `P` or `p` after any sign is ISO 8601, anything else
   the friendly form; the labels are matched longest first; `,` is a
   decimal separator too; trailing whitespace is accepted, and `ago`
   after `HH:MM:SS`, as Jiff's code accepts them; at most 21 digits are
   read for a number, as Jiff's `u64_prefix`. A value past the range is
   `TimeError.invalid`.
8. **The messages**: "a wait of `-1` is negative: a constant wait is
   zero or more, and a negative one written so is a mistake"; "a duration
   takes no `days:`, since a day is not always 24 hours: write `hours:
   24` for exactly 24 hours"; "a function that takes a `Duration` names
   no parameter `ms`: a call writes a duration with a unit's keyword,
   `ms: 40`, so rename it"; "`f` takes 2 durations, so each is given by
   its own name, `a: 1`, not by a unit's keyword"; "a unit's keyword takes
   a number, and `d` is a `time.Duration` already: write it with no
   keyword, not `ms: d`"; "`time.sleep` has no parameter `secs`; did you
   mean `seconds: 2`?"; and for `round` and `floor` the four of
   `checkUnitIncrement` and "`std.time.Duration.round` checks its
   arguments where it is called, so it must be called; wrap it in a
   closure to pass it as a value".
9. **The migration keeps meaning over idiom.** A reading compared with a
   count of a constant becomes a comparison of durations; any other
   reading gets `.ns()` and any other constant its number, so a program
   prints what it printed (the bench harnesses read whole nanoseconds).
   Each kept number and each reading it guessed is printed as `CHECK`.

## The design against the code

The line numbers of §10 were read again: `resolve.zig:2557`
`paramDurations` stood where §10 says, and the other sites within about
150 lines of it. Nothing in the code made a part of the
design wrong or impossible. Two things the design does not say, and
the code needed:

- **A hoisted argument.** Emit evaluates a call's arguments into typed
  temporaries when one can fail or must be ordered; a duration form
  there was typed as the number it is written as and converted again
  when read. It is now held as what it becomes (`sema.Duration.written`)
  and read from its temporary. `std-time-waits` reaches it
  (`time.within(ms: minus(5), ...)`, `per: time.duration(ms: 500)`).
- **A `Duration?` parameter** takes the `Duration` packed as its
  optional (`rig.pack`), since an object's optional may be the runtime's
  own type rather than Zig's.

## Measured

`Duration.parse`, `round`, and `floor` against Jiff 1.0.0, through the
phase-0 oracle (`tools/jiff-oracle`, built offline from Cargo's
registry), with a Rig program answering the same lines:

| Cases | Same as Jiff | Beyond `Duration`'s range | Different |
|---|---|---|---|
| `duration.parse` of `gen.py`'s `text.in` | 5,270 | 741 (Jiff's 16 bytes hold them; Rig refuses) | 0 |
| `duration.round`, the round and the floor, of `round.in` | 8,488 | 1,512 (not run: input or answer past the range) | 0 |
| 30,000 generated texts of the friendly grammar (labels, fractions, commas, `ago`, `HH:MM:SS`, signs, spaces, calendar units, misspellings) | 29,590 (25,155 of them refused by both) | 410 | 0 |

## Left out

- Phase 1b (several unit keywords), operators on `Duration` (§5.6), and
  everything of `std.datetime`. `time.unix_ns()` stays until
  `datetime.now()` (phase 3).
- `docs/history` is left as it was; so is a research script in Trig,
  `docs/research/28-name-lookup-2026-11-04/C-scripts/names.rig`, a
  record of its own.
- loco uses nothing of std.time: no patch.

## Verification

On the Mac, through `tools/heavy`:

- `zig build` and `zig build test`; swarm's `unit` and `oracle` jobs.
- Each area touched, alone: `std-time` (25 jobs), `std-time-forms`
  (20), `std-time-waits` (7), `std-misc`, `std-net`, the six
  `concurrency-*` files, `probes-29`, `types-generic`; the doc examples
  of SPEC, STD, MIGRATING-0.3, learn 06 and 09, and INTERNALS; and the
  scripts `migrate_datetime`, `migrate_durations`, `emit`,
  `preempt_cover`, `preempt_forks`, `preempt_reads`, `preempt_section`,
  `run_next_fair`, `sched_service`, `std_file_ops`, `std_http`, and
  `jiff_oracle`, which also skipped as it should with cargo offline and
  an empty registry.
- The whole core suite once: 12,246 jobs, one died,
  `cli.preempt_section`, whose list of calls outside the program's
  section named `__rig_std_time.sleep`, now `sleep_ns`; it passed alone
  after the rename.
- `tools/emit-diff origin/main` (main is one PR past this branch's base,
  #1201, typecheck only): the emitted Zig differs in `rig/runtime.zig`
  alone, the duration helpers (`durationInt` and `durationFloat` given
  the type, `durationOf`, `durationNs`), for the 24 programs that carry
  it; 12 benches the migration rewrote do not emit with main's `rig`,
  since they name `time.monotonic()`; examples, std, and Trig emit the
  same Zig otherwise.
- Trig: `git apply --check` of the patch on Trig at `f06b9c59`. The
  coordinator runs the bench guards, the Trig and loco light gates, and
  the Linux checks.
