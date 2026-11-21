# Datetime phase 3: `Instant` and `datetime.now()` (2026-11-21)

Phase 3 of the datetime design (docs/design/datetime.md, the owner's v3
of 2026-11-17, amended 2026-11-20; the datetime phases approved
2026-11-21). It builds std.datetime's `Instant`, an exact point on the
shared timeline, and `datetime.now()`, the wall clock, with RFC 3339
text, and removes `time.unix_ns()`, whose fix is
`datetime.now().unix().ns()`. Branch `datetime-p3`, from main 5db6cfed7
(phases 1, 1b, and 2). `in_zone`, `TimeZone`, `ZonedDateTime`,
`today`, and `format` are later phases; the examples that need them
stay `rig pending` in STD.

## What landed

| Part | Where |
|---|---|
| `Instant`: `from_unix` (which does not fail: the owner's decision of 2026-11-21), `parse`, `unix`, `unix_s`, `add`, `checked_add`, `since`, `round`, `floor`, `Eq`, `Ord`, `Hash`, `print`; `now()` | `std/datetime/instant.rig` |
| The wall clock, read as `time.unix_ns()` read it: `std.Io.Timestamp.now(io, .real)` | `std/datetime.zig` (`wall_ns`), `std/embed.zig` |
| RFC 3339's offset and RFC 9557's annotations, by Jiff's grammar | `std/datetime/text.rig` (`offset_text`, `annotations_text`, `zone_annotation`, `key_annotation`) |
| `time.unix_ns()` removed, with its fix in the hint table; the fix for `time.now()` names `datetime.now()` | `std/time.rig`, `std/time.zig`, `src/sema.zig` (`stdRenamed`) |
| The increment of `round` and `floor` on an `Instant`, checked where it is called; `days:` and `weeks:` on its `add` and `checked_add`, with a fix that names a zone | `sema.ArgCheck.instant_increment`, `sema.duration.zoneless`; `typecheck.zig` `incrementAllowed`, `checkUnitIncrement`, `oneIncrement`, `calendarKeyword`, `ParamInfo.zoneless` |
| The migration of `time.unix_ns()` | `tools/migrate-datetime.py`, `test/cli/migrate_datetime.sh` |
| Tests | `test/rig/std-datetime-instant.rig.test` (every form of `from_unix`, `add`, and `checked_add` at each kind of call, `unix`, `unix_s`, `since`, `round`, `floor`, the checks, text, `now`; 28 cases), `std-datetime-instant-ports` (Jiff's tests and documentation examples; 24) |
| The oracle: `instant.unix` and `instant.since`; std.datetime's answers to every instant case | `tools/jiff-oracle/gen.py`, `src/main.rs`, `answer.rig`, `README.md`; `test/cli/jiff_oracle.sh` |
| Jiff's documentation examples, each ported or left out and why | [doc-examples.md](doc-examples.md) |
| Trig's line, rewritten | [trig.patch](trig.patch) |
| Docs | `docs/STD.md` (std.time loses `unix_ns`; std.datetime gains `Instant` and `now`, with an example run), SPEC and `docs/learn/09-tests.md` (the wall clock that stays real under a seed is `datetime.now()`), `docs/MIGRATING-0.3.md`, `docs/internals/INTERNALS.md` (which shim reads the wall clock), CHANGELOG (Added; "Upgrading from v0.3.0"), HANDOFF's "In flight", ROADMAP |

SPEC's language did not change: the duration forms, `days:` refused
where a duration is taken, and the checks of a std call's arguments are
phase 1's and 2's mechanisms, given one more type.

## Decisions left to the builder

1. **The fields**: `s: Int`, the whole seconds since 1970 floored, and
   `ns: U32`, the nanoseconds after them, 0 to 999,999,999, not Jiff's
   pair of one sign. The order of the fields is then the order of the
   timeline, so the derived `Eq`, `Ord`, and `Hash` are right with no
   code, and `unix_s()` is the field. 16 bytes (§7.3), checked by a
   test. Private, so an instant is made only by `from_unix`, `parse`,
   `now`, and arithmetic.
2. **The shim** is `std/datetime.zig`'s `wall_ns() -> i64`, the same
   read `time.unix_ns()` made (`std.Io.Timestamp.now(rig.io(), .real)`),
   real under the deterministic scheduler, which virtualizes only the
   monotonic clock. An `i64` of nanoseconds holds 1677 to 2262, inside
   the range, so `now()`'s panic beyond the range cannot be reached.
3. **The errors**: `checked_add` fails with `DateTimeError.range`;
   `parse` fails with `DateTimeError.invalid` for
   any text it refuses, an instant past the range among them, as phase 2
   decided for `parse` (its decision 1).
4. **The message for `days:` on an instant** says why and names the
   one fix that compiles: "an `Instant` has no calendar, so `add` takes
   no `days:`: a day on the clock is a zone's; write `hours: 24`, exactly
   24 hours a day", keeping every amount written (`hours: 170` for
   `weeks: 1, hours: 2`). The fix in a zone, `i.in_zone(tz).add(days:
   1)`, is phase 5's to add to the message, with its test; STD shows it
   as `rig pending`. It is phase 1's calendar refusal with the callee
   known (`ParamInfo.zoneless`), so `Instant.from_unix(days: 1)` keeps
   phase 1's message.
5. **`add` and `checked_add` are not checked methods**: their only check
   is of a keyword, which only a direct call writes, so an `Instant`'s
   `add` stays usable as a function value, as `Monotonic.add` and
   `Time.add` are. `round` and `floor` are checked, so neither is a value
   nor called in a generic body (phase 2's mechanism, tested).
6. **The increment rule** is Jiff's `Increment::for_timestamp`
   (`util/round.rs:148`): from 1 to 1,000,000,000 and dividing a day in
   its unit. A constant that breaks it is "an increment of `round` on an
   `Instant` divides a day, so `minutes:` takes a number that divides
   1,440, and `7` does not"; another panics, "datetime.Instant.round: the
   increment 7 does not divide 1,440, the minutes in a day", the count
   grouped as the compile error groups it (from a table of the six
   counts, so the panic allocates nothing). Two units given are offered
   as their sum only when it divides a day (`round(seconds: 450)` for
   `minutes: 7, seconds: 30`); else as the first unit, with its
   increment when the check takes it and otherwise the largest below it
   that it takes (`round(minutes: 6)` for `minutes: 7, seconds: 1`). The
   review found phase 2's `Time` and `DateTime` offering the refused
   increment too (`round(minutes: 7)`); `oneIncrement` now offers only
   what `incrementAllowed` takes, for all three, each with a case.
7. **Panics** name the operation and its value: "datetime.Instant.add:
   9999-12-30T22:00:00.999999999Z plus 1ns is beyond the range of
   instants, -009999-01-02T01:59:59Z to 9999-12-30T22:00:00.999999999Z";
   "datetime.Instant.round: … rounds beyond the range of instants, …";
   "datetime.Instant.floor: -009999-01-02T01:59:59Z floors before
   -009999-01-02T01:59:59Z".
8. **A zone in brackets** is checked against RFC 9557's grammar as Jiff
   checks it and not looked up, as Jiff's `parse_timestamp` does not:
   `…Z[Not/A_Zone]` reads, `…Z[` and `…Z[!u-ca=iso8601]` (a critical
   annotation that is not a zone) fail. The oracle compares every one of
   §8.1's spellings.
9. **The test of `now()`** compares its progress with the monotonic
   clock's across a sleep (within half a second), trying again up to
   five times so a clock set meanwhile does not fail it, and under seeds
   checks it reads between 2026-11-01 and 2262, where a virtual clock
   would read 1970, needing no forward move. Neither prints the time.
10. **The migration** writes `datetime.now().unix().ns()`, adds `use
    std.datetime` in the order of the `use std.` lines beside `use
    std.time` (the file's, the test case's or else the test file's
    header, or the Markdown block's), or uses the file's own name for it
    (`dt.now()` beside `use std.datetime as dt`), drops a `use std.time`,
    under any name, that no code names any more, and leaves `time.unix_ns` as a function value for a
    person (MANUAL). It runs phase 1's rewrites only where a phase 1
    form is named: phase 1's `.ns()` after a reading is not idempotent,
    and a file migrated for phase 1 that still read `time.unix_ns()`
    would have had it twice (found on `docs/STD.md`; the case in
    `migrate_datetime.sh` checks a second run changes nothing).
11. **Rig's own tree** had four uses: `std-time.rig.test`'s case of the
    wall clock moved to std.datetime's tests; `std-time-forms`' two
    `fail` cases that name removed forms on purpose were edited by hand
    (a third removed name, `unix_ns`, and the wall clock beside a
    reading); STD's std.time example dropped its wall-clock line, which
    std.datetime's example now has. No bench and no example used it.

## The design against the code

**`from_unix` could not fail.** §7.8 gave `Instant.from_unix(<duration
form>)!`, failing outside the range, and §7.2 said `from_unix(x)!` with a
`Float` from a user fails outside the range. Since the amendment of
2026-11-20 a `Duration` is one `Int` of nanoseconds, the years 1677 to
2262, inside the range of instants, so `from_unix` could never fail. The
owner decided (2026-11-21, through the coordinator) to drop the `!`:
`from_unix` returns an `Instant`, and a number beyond a `Duration`
panics where the call makes the duration, as any duration form does;
§7.2, §7.8, and §2's table say so. That panic said "a duration is not a
finite number of nanoseconds a Duration holds" for a finite `Float` out
of range; it now says "a duration is more nanoseconds than a Duration
holds", as an `Int` out of range does, and keeps the first for a NaN or
an infinity (`src/runtime.zig`, `durationFloat`; cases in
`std-time-forms` and `std-datetime-instant`). A maker from whole Unix
seconds, the inverse of `unix_s()` for instants outside 1677 to 2262,
waits on the owner. Nothing else in the code made the design wrong or
impossible.

**A deviation from Jiff found by the review:** Jiff 1.0.0 reads
`-009999-01-02T01:59:58.999999999Z`, a nanosecond below its own minimum
(its doc test at `timestamp.rs:461` refuses the same value from parts).
Rig refuses it, as §7.1's range says ("parse refuses", and the ports of
`new_err` and `invalid_time`). The oracle never writes it: its minimum
has no fraction.

## Ported from Jiff

Each routine names the line of Jiff 1.0.0 it follows: jiff-core
`bounds.rs` (`UnixEpochSeconds`); jiff `util/round.rs:148`
(`for_timestamp`), `timestamp.rs:3471` (`TimestampRound::round`), and
`:1482` (`checked_add_duration`); `fmt/temporal/parser.rs:132`
(`to_timestamp`) and `:286` (`parse_temporal_datetime`); `fmt/offset.rs`
`:422` to `:658` (the offset); `fmt/rfc9557.rs:238` (the annotations).

### Tests ported

Jiff 1.0.0's tree has no tc39 tests of an instant: its
`tests/tc39_262` holds `civil` and `span` only, so there are none to
port.

| File | Ported | Left out, and why |
|---|---|---|
| jiff-core `timestamp.rs` | `sub_assign` (as `add` of the negation), `new_ok` (Jiff's `as_second` and `subsec_nanosecond` are `unix().seconds()` and `unix().subsec_ns()`; `unix_s()` floors), `new_err` and `from_nanosecond_err` (a nanosecond or a second past each end), `checked_arithmetic_below_min`, `checked_arithmetic_overflow` (with the largest `Duration`: from 1970 it never leaves the range, from an end it does), `checked_seconds_across_epoch`, `checked_arithmetic_boundaries` (605 sums against the total computed apart), `to_datetime_no_subsec`, `to_datetime_with_subsec` (as text under each offset, read), `to_datetime_limits` (the first and last date and time under ±25:59:59, read) | `checked_arithmetic_at_max`: it adds 253,402,207,199 seconds at once, beyond a `Duration` (§5.1); a nanosecond count out of ±999,999,999 in `new_err`, which a single duration cannot write; `prop_timestamp_datetime_roundtrip`, a quickcheck, which the oracle's 5,021 parse round trips stand for |
| jiff `timestamp.rs` | `to_datetime_specific_examples`, `to_datetime_many_seconds_in_some_days` (372 instants printed and read back, the same Jiff's test reaches), `invalid_time`, `timestamp_size` (16 bytes), `timestamp_deserialize_yaml` (its text), `timestamp_precision_loss` | `system_time_roundtrip`, `system_time_limits`: Rust's `SystemTime`; `nanosecond_roundtrip_boundaries`: nanoseconds since 1970 at the ends are beyond a `Duration` (`unix()` saturates there, and `unix_s()` at both ends is tested); `timestamp_saturating_add` and `_sub`: no saturating arithmetic, and a day on an instant is a compile error, tested; the quickchecks `prop_unix_seconds_roundtrip` and `prop_nanos_roundtrip_unix`, which the oracle's `instant.parse` and `instant.unix` (`from_unix(unix())`) stand for; `timestamp_constant_and_new_are_same1` and `2`: no `constant` |
| jiff `util/round.rs` | `for_timestamp`: the increments it takes, run, and those it refuses, `Int.min` and `Int.max` among them, compile errors | its days and weeks, which no instant takes: `days:` is a compile error, tested |
| Jiff's documentation of `Timestamp` (`src/timestamp.rs`), 88 examples | 60, three in part, in `std-datetime-instant-ports` | 28, each listed in [doc-examples.md](doc-examples.md) with its reason: zones (phases 4 and 5), `strftime` and printed precision (phase 6), saturating arithmetic and Unix times beyond a `Duration`, `SystemTime`, spans, `Ceil` |

§12's rows for this phase: the ends of the range (`timestamp.rs:1402`:
"the ends of the range", "docs: the ends of the range"); an instant
before 1970 for `floor` and rounding ("round before 1970", a half going
to the later); `unix()` saturation and `unix_s()` at both ends ("unix
and unix_s", "unix_s at both ends of the range"); `since` saturation
("since"); RFC 3339's forms, `t`, `z`, `,5`, a zone in brackets ignored,
and a missing offset refused ("parse RFC 3339", "parse refuses").

## Measured: the oracle

`gen.py` writes 30,000 more cases than phase 2, 1,771,595 in all;
`calendar.in` has the new `instant.unix` and `instant.since` after its
old cases, and every other file is unchanged byte for byte. Jiff answers
every case; `answer.rig` (built `--release`) answers phase 2's, std.time's,
and every instant case, and `test/cli/jiff_oracle.sh` requires no
difference:

| Operation | Same | Different | Left out on purpose |
|---|---|---|---|
| `instant.add` | 8,778 | 0 | 1,222: a duration beyond a `Duration`'s range (§5.1) |
| `instant.unix` (`unix()`, `unix_s()`, `from_unix(unix())`) | 10,000 | 0 | of these, 2,423 instants outside 1677 to 2262, where `unix()` saturates: their `unix()` and `from_unix` are skipped, their `unix_s()` compared |
| `instant.since` | 10,296 | 0 | 9,704: beyond ±292 years, where Rig saturates (§6.6) |
| `instant.parse` (round trips and §8.1's spellings) | 5,021 | 0 | |
| `instant.round` (round and floor) | 15,000 | 0 | of the rounds, 2,889 before 1970 exactly half way, where Jiff goes away from 1970 (§9 item 12); their floors are compared |
| the instant cases | 49,095 | 0 | |
| all, with phases 1 and 2's | 891,707 | 0 | |

The cases of later phases (`instant.in_zone`, `zoned.*`, `zone.*`,
`date.in_zone`, `datetime.in_zone`) are not answered yet.

## Trig and loco

Trig reads `time.unix_ns()` once, in `tools/trig/main.rig` (`clock`, Go's
`osSys.Now`). [trig.patch](trig.patch) is what
`tools/migrate-datetime.py` writes there, `datetime.now().unix().ns()`,
with `use std.datetime` in place of `use std.time`, which names nothing
else in the file, and the comment above it brought up to date (by hand:
a reading of the monotonic clock is a `Monotonic`). It was made against
Trig's main (f06b9c59), which has not landed phase 1's patch; it touches
another file than phase 1's (`tools/checker/bench.rig`), and `git apply
--check` passes on main and on main with phase 1's patch applied. loco
uses nothing of std.time.

## Verification

On the Mac, through `tools/heavy`:

- `zig build`, and `zig build test`.
- Swarm on what changed with `oracle` and `unit`: the seven
  `std-datetime*` files, `std-time`, `std-time-forms`, `std-time-waits`,
  the generic files `errors-generic`, `ownership-generic`, `types-apis`,
  `types-generic`, every doc's examples (`doc`), `cli.jiff_oracle` (the
  oracle's 1.77 million cases, 891,707 answered the same and none
  different), `cli.migrate_datetime`, and `cli.emit`: 1,862 jobs, none
  died.
- `tools/emit-diff origin/main` (main at 5db6cfed7): 12 of 38 programs
  differ, each a bench that imports std.time, and only by the removed
  `unix_ns`: its four lines in `__rig_std_time.zig` and the shim's
  function and header in `rig/std/time.zig`. Trig's entry fails to emit
  on both sides alike (its generated `buildinfo` and `libtrees` modules
  are not in a checkout), so it compared nothing; by hand, Trig's
  `main.rig` with the patch applied, beside stubs of those two modules,
  checks with no error but the stubs' missing members.
- The whole core suite once (`tools/heavy --class correctness swarm
  test/rig.rip -w 4 -q`): 12,423 jobs in 623 s, none died.
- After the review's fixes (from_unix with no `!`, each refusal's fix
  one the checker takes, the migration's alias, the wall-clock tests):
  swarm on the same set, 1,865 jobs, none died (the oracle's 891,707
  answers the same, none different); `tools/emit-diff origin/main`, the
  same 12 benches by the removed `unix_ns`, and `rig/runtime.zig` in 36
  programs by the panic message of a `Float` past a `Duration`; the
  whole core suite, 12,426 jobs in 905 s, none died.
- A plain `tools/heavy zig build` last. The coordinator runs the review,
  the guards, the Trig and loco light gates, and the Linux checks.
