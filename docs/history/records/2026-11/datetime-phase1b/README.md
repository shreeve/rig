# Datetime phase 1b: several unit keywords in one call (2026-11-21)

Phase 1b of the datetime design (docs/design/datetime.md §5.2, its
bullet "Several unit keywords add up"; §10.1, its last row; §11). The
owner said go on 2026-11-21. Wherever a call gives a `Duration`
parameter by unit keywords it may give several, which add up:
`time.sleep(hours: 1, minutes: 30)`.

## The representation

A parameter filled by several parts is a third kind of argument slot,
beside an argument and a default: `sema.ArgSlot.parts`, a
`DurationParts` holding the parts' indexes in the call's argument list,
in the order written, and what the sum becomes (the `Duration`, packed
as the `Duration?` a parameter of that type takes, or an `Int` of
nanoseconds for `time.after`). `sema.ParamFill` gets `.parts` too, which
carries no loans: every part is an `Int` or a `Float`.

Each part is recorded as phase 1 records one unit (`sema.Duration`), with
no target type, so emit writes it as the `Int` of nanoseconds it counts
(`rig.durationInt(i64, x, unit)` or `rig.durationFloat`). The slot is
written `rig.durationSum(T, .{ a, b })`, a checked add in the order
written. A part evaluated first (hoisted, when another argument can fail
or the call reorders arguments with effects) is held as its `Int`, and
the sum reads the temporaries.

A new union variant was chosen over keeping `.arg` and hanging the
other parts off a fact, because every reader of the argument-to-parameter
mapping then fails to compile until it handles the parts. The readers,
each handled:

| Reader | What it does with the parts |
|---|---|
| `typecheck.zig` `checkArgs` (fills, slots, stores) | records `.parts`; a part carries nothing to keep |
| `typecheck.zig` `wastedClones` | skips them (numbers) |
| `storage.zig` `callHoistsArgs` | orders each part among the arguments, so a reorder with effects hoists |
| `storage.zig` `argumentParam`, `emit.zig` `hoistParts` | find a part's slot (`sema.slotOf`) |
| `emit.zig` `emitArgsFrom` | writes the sum (`emitDurationParts`) |
| `test/oracle/lower.zig` `slotIndex` | maps each part to its slot |
| `--facts=sema` | `parts(arg0+arg1) Duration` |

## Decisions

1. **Each part is a number a `Duration` holds** before the parts add up,
   as one unit alone is: a constant part past the range is refused, and
   a part past it at run time panics, even where a later part of the
   other sign would bring the sum back. "An `Int` part is exact" holds:
   no part is rounded but a `Float`. The sum is then a checked add in an
   `Int`.
2. **A constant sum** (every part a constant, by phase 1's rule) is
   checked whole: past the range is "`hours: 2562047, minutes: 48` is
   more nanoseconds than a `Duration` holds"; negative, for a wait, "a
   wait of `hours: 1, minutes: -90` is negative, -30m: a constant wait is
   zero or more", the value written as `print` shows a `Duration`. A part
   alone may be negative.
3. **Messages:** a repeated unit, "the unit `hours:` is given twice: a
   duration's units add up, each given at most once"; a unit beside a
   bare number or the parameter's name, "`time.sleep` takes one duration:
   `2` or `minutes: 1, seconds: 30`, not both" (phase 1's said "in one
   unit"), every unit named; units, and `days:` or `weeks:` among them,
   given to a function of two durations are said once, before the count
   of arguments, with one fix for all of them, "`span` takes 2 durations,
   so each is given by its own name: `a: time.duration(hours: 1, minutes:
   30)`" (`b: time.duration(hours: 26)` for `a: 1, days: 1, hours: 2`), or
   "give `time.duration(ms: 3, us: 4)` to the one it is for" when every
   duration is named; a duration given by position and by name is
   "parameter `a` of `span` is given twice"; a keyword that names no
   parameter now suggests "with units' keywords, `ms: 40` or `minutes: 1,
   seconds: 30`".
4. **`days:` and `weeks:` among units** are said once, with the fix for
   the whole call: the days, the weeks, and any `hours:` become one
   `hours:` where the first of them stood, the other units as written:
   `days: 1, hours: 2, minutes: 30` is told `hours: 26, minutes: 30`, and
   `minutes: 30, weeks: 1, days: n()` is told `minutes: 30, hours: 168 +
   24 * n()`.
5. **The count of arguments.** Of a callee that takes one duration, the
   keywords that name no parameter count as one argument (the units, a
   calendar keyword, a misspelling), so `time.sleep(minutes: 1, secs: 2)`
   is told "did you mean `seconds: 2`?", not that it gives two arguments.
6. **`round` and `floor`** keep their check of exactly one unit. Given
   several, the message counts them and gives the one-unit form when it
   can, in the largest unit the sum is a whole number of, which suits
   §6.8's increments for every type: `round(hours: 1, minutes: 30)` is
   told "takes one unit and its increment, not 2: write the increment in
   one unit, `round(minutes: 90)`", and `floor(minutes: 1, seconds: 0)`
   `floor(minutes: 1)`; else it names the smallest unit given. Whether
   the one-unit increment is allowed for a `Time` or a `DateTime` (it
   must divide the next larger unit) is checked by those types' own
   `round` when phase 2 builds them.

No form phase 1 accepted is refused. The forms phase 1 refused and 1b
accepts are several distinct units in one call.

## The independent review

A review of the branch (2026-11-21) found nothing blocking: no accepted
program broke and no sum came out wrong (37 probes). Its findings, each
now fixed with a case that failed before it (`std-time-forms`):

1. Units given to a function of two durations were counted as one
   argument, so `span(ms: 3, us: 4)` said "expects 2 arguments, got 1".
   The count folds the keywords that name no parameter only for a callee
   of one duration; for two or more, units are said once, first.
2. `docs/learn/04-concurrency.md` and `std/time.rig`'s header still said
   one unit.
3. "Not both" named only the first unit; it names every unit given.
4. `span(1, a: 2)` kept phase 1's "takes one duration, in one unit"; it
   is now "parameter `a` of `span` is given twice".
5. `span(a: 1, days: 1, hours: 2)` got two fixes that disagreed; it gets
   one, `b: time.duration(hours: 26)`.
6. The one-unit fix of `round` and `floor` used the smallest unit given;
   it uses the largest the increment is a whole number of (decision 6).

Left as phase 1 had it: `time.duration(days: 1, d: 3)` is a count error
("expects 1 argument, got 2"), not the `days:` message, since `d:` names
the parameter and `days:` does not.

## Where the code met the design

Nothing in the code made the design wrong or impossible. §10.1 guessed
250 to 400 lines in five files; the change is about 300 lines of `src`
in six (`sema`, `typecheck`, `emit`, `storage`, `facts`, `runtime`) and
one line of the oracle.

## Tests

`test/rig/std-time-forms.rig.test` (16 new cases, three of them from the review) and
`std-time-waits.rig.test` (5, the concurrent ones under `seeds: 20`),
each reaching the emitter: several units at a function, a generic
function, a type's function, std.time's methods, a method, an API's
method under a bound and through an API object, an optional
`Duration?`, another module's function, a call run as a task, an actor's
method, `sleep`, `within` with a closure literal after the units and
with `f:`, and the deadline arm; parts that are hoisted (another argument
fails, or the call reorders arguments with effects); the order of
evaluation; each `Float` part rounded alone (`us: 0.0005, ns: 0.5` is
2 ns); mixed signs; both ends of the range reached by a sum, and passed
(constant: refused; at run time: panics, below and above); a part past
the range and a part not finite; and each refusal. Phase 1's cases of
two units and of `floor(ms: 1, us: 2)` were changed: two distinct units
are accepted, so the case gives a unit twice.

## Measured

`bench/check/guard.py` on plain builds, interleaved against main
(199b14631, `tools/baseline`), twice each:

| Run | Instructions | `rig check` total |
|---|---|---|
| main 1 | 2,171,282,869 | 110.299 ms |
| branch 1 | 2,184,065,783 | 105.301 ms |
| main 2 | 2,168,998,216 | 106.430 ms |
| branch 2 | 2,184,246,644 | 105.700 ms |

The guard's fewest of 7 read 0.6% more instructions on the branch at a
load of 4.7, so the workload was counted again, interleaved, fewest of
12: main 2,178,899,843, the branch 2,180,366,354, 0.07% more, within the
run-to-run spread the guard's own notes give (1.8%). Time is level.
A call with no duration does one more test of `info.durations` when it
counts its arguments and none else.

`tools/emit-diff origin/main`: the emitted Zig differs in
`rig/runtime.zig` alone (`durationSum`, 10 lines) for the 36 programs
that carry it; no program gives several units, so nothing else differs.

## Verification

On the Mac, through `tools/heavy`: `zig build`, `zig build test`; swarm's
`unit` and `oracle`; `std-time-forms` (39 jobs) and `std-time-waits` (13); the doc examples
of SPEC, STD, learn 06, and INTERNALS; `tools/emit-diff origin/main`
(above); and the whole core suite once: 12,275 jobs, none died (the run
reported the record and a test case added while it ran as files left in
the checkout; that case, a task and an actor's method, then passed in
`std-time-waits` alone).

After the review's fixes: `std-time-forms` (42 jobs) and
`std-time-waits`, the doc examples of learn 04, the cases checked to fail
with the branch's previous `rig` (2cc2bbf1d), and the whole core suite
once: 12,279 jobs, none died.
