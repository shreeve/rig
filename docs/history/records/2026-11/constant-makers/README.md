# Constant arguments: a maker called with constants (2026-11-22)

The owner's decision 2 of the datetime strategy, "total or visible"
(2026-11-22; docs/design/datetime.md §10.6 on main): when every argument
to a listed std maker is a compile-time constant and the maker's check
passes, the call's type is the plain `T`, not `T!`; a constant that fails
is a compile error; with any argument known only at run time the call is
`T!` as declared. A prover-based version was rejected: the rule asks
only Rig's constant evaluation. Branch `constant-makers`, from main
e38454865.

## What landed

| Part | Where |
|---|---|
| The list of makers and their checks: `ConstMaker` (`date`, `time`, `date_time`), `constMaker`, `MakerPart` with each part's range, `monthDays`, `isLeapYear`, `makerFault`; a unit test of each boundary | `src/sema.zig`, beside `stdArgCheck` |
| The rule, at the call of a type's function: every argument and every default left out is a constant (`constInt`), the check runs, the call gives `T` and records the fact, or an error names the part refused and its range | `src/typecheck.zig` `associatedCall`, `constMakerCall` |
| `!` and `catch` on such a call: the error of any call that cannot fail, saying why this one cannot | `src/typecheck.zig` (`synthPropagate`'s and `synthCatch`'s non-fallible errors) |
| The fact, `const_makers`, and its reader | `src/sema.zig` (`Facts`, `recordConstMaker`, `isConstMaker`), `src/facts.zig` |
| Emit: the call in a block that gives it a slot for a failure's fields, its `T!` unwrapped by a `catch` that panics as a bug in Rig (`rig.makerPanic`), never Zig's `unreachable` | `src/emit.zig` (`emitCall`, `emitConstMaker`), `src/runtime.zig` |
| Tests | `test/rig/std-datetime-makers.rig.test`: the plain type, by position, by name and with defaults; each kind of constant; each kind of run-time argument; the refusals and their messages; `!` and `catch`; the emitted Zig; every boundary of each maker made or refused by a constant call, and std's own `new` given the same values at run time; a binding named `e` beside the call; a task of the call; a failure's trace, of which a constant call is never a site |
| The migration | `tools/migrate-constant-makers.py` |
| Docs | SPEC §13 (the rule, an example, a rejection), `docs/STD.md` std.datetime (the makers' signatures and the rule), the comments of `Date.new` and `Time.new`, CHANGELOG (Added), HANDOFF, AGENTS' map |

## Decisions

1. **The mechanism: a list in sema, as `stdArgCheck` lists the checks
   of std methods**, not a marker in the std declaration. Rig has no
   declaration attributes, so a marker means grammar work; and the
   compile-time evaluator (`cteval`) runs only functions of integers,
   `Bool`s and enums, not a maker that returns an object or fails. The
   check is std's, held a second time, as `format`'s directive table is
   (§10.6 says so). What keeps the two copies together is the test that
   runs every value either side of each boundary through both: the
   constant call (made, or refused with the message) and std's `new` at
   run time (made, or `range`). A later maker joins by a line in
   `constMaker`, its parts in `params`, and its check in `makerFault`.
2. **`!` on a call whose arguments are valid constants is refused**, as
   `!` on any call that cannot fail is ("`!` needs a fallible operand"),
   with a message that says why this one cannot: "`!` needs a fallible
   operand, and `datetime.Date.new(2026, 1, 31)` cannot fail: its
   arguments are constants that pass its check, so it gives a
   `datetime.Date`; write it without `!`". `catch` the same. Allowing it
   would make `!` mean "might fail" on a call that cannot, which hides
   nothing but says something false; the committee leaned to the plain
   `T`, which makes the refusal follow from the rule with no special
   case. A refused constant with a `!` written gives the refusal alone.
3. **What a constant is: `sema.constIntOf`**, the classifier the
   negative-wait check and constant arithmetic use: a literal, a module
   constant (`LIMIT`), another module's (`lib.N`), a local binding never
   reassigned or written whose value is constant (`m = 2`), a
   compile-time function's value, and arithmetic on these. A default the
   call leaves out is read the same way in the declaring module. A
   binding the program changes, a parameter, and any other expression
   leave the call `T!`.
4. **A type alias** (`type D = datetime.Date`, `D.new(2026, 12, 31)`)
   names the same maker, so the rule applies: the call resolves to the
   same type's function.
5. **A function value** (`make = datetime.Date.new`, `make(2026, 1,
   31)!`) is a call of a `fun(Int, Int, Int) -> Date!`, not of the maker
   written, so it takes `!` whatever its arguments: the rule reads the
   call as written.
6. **Generics.** A maker called with constants in a generic body is
   checked there, once, and gives `T` in every instance. A compile-time
   parameter (`fun month_start[m: Int]()`, `Date.new(2026, m, 1)`) is not
   a constant in the body, which is checked once for every instance, so
   that call takes `!`: the answer is the call's own and the same in
   every instance. A call through a type parameter cannot reach `new`,
   which takes no self.
7. **A task of the call** (`Date.new(2026, 1, 31)&`) holds what the maker
   declares, `Task[Date!]`, as a task of any fallible call: the rule is
   about the call's value, and the task's wait is where its failure is
   taken.
8. **The error names the part and its range**, at the argument:
   "`datetime.Date.new(2023, 2, 29)` always fails, its arguments being
   constants: February 2023 has 28 days; write a day from 1 to 28"; for a
   name, its value ("13 is not a month" for `LIMIT`).
9. **Emit never writes `unreachable`.** The call is unwrapped by
   `catch |e| rig.makerPanic(e)`, a cold panic naming the error and
   calling it a compiler bug, so a disagreement between the two copies
   is a panic in every build mode rather than undefined behavior in a
   fast one (§10.6). The capture's name is unique to the call, after the
   first build named it `e` and a test's local `e` shadowed it (the case
   is kept).

## Migration

`std.datetime` came after 0.3.0, so no released program changes, and
no release note lists a rejection. `tools/migrate-constant-makers.py`
(in `migrate-datetime.py`'s style) drops the `!` from each call whose
arguments are integer literals forming a real date or time, and prints
`MANUAL` for a literal call the maker refuses or one handled with
`catch`, and `CHECK` for a test line whose positions may move. In Rig's
tree it rewrote 521 calls: `test/rig/std-datetime.rig.test` 197,
`std-datetime-docs` 142, `std-datetime-clock` 112,
`std-datetime-ports` 32, `std-datetime-checks` 24,
`std-datetime-instant-ports` 1, `docs/STD.md` 12, and one comment in
`std/datetime/date.rig`. Its five `MANUAL` lines were prose showing a
failure with a constant (`Date.new(2023, 2, 29)!` fails), each written
again by hand. The compiler's error found the calls whose constants are
names. Trig and loc use no std.datetime maker (the script finds none).
`docs/design/datetime.md` was left alone (rewritten on main by #1207;
its one maker call in a rig block is `rig pending` there).

## Verification

On the Mac, at the branch's three commits over e38454865, every run
through `tools/heavy`:

- `zig build` and `zig build test` pass (the unit test of each maker's
  boundaries among them).
- `swarm test/rig.rip` on what the change touched: `std-datetime`,
  `-checks`, `-clock`, `-docs`, `-ports`, `-instant`, `-instant-ports`,
  `-makers` (17 cases), `doc-SPEC`, `doc-STD`, `oracle`, and `unit`, all
  green.
- The core suite once, `--class correctness swarm test/rig.rip -w 4`:
  12,450 jobs, none failed, in 813 s.
- `tools/emit-diff e38454865` (the branch's base; main since adds only
  docs): the 38 programs (examples, benches, every std module, Trig)
  emit the same Zig but for `rig/runtime.zig`, which gains
  `makerPanic`'s 8 lines; no program outside the tests calls a maker
  with constants.
- `bench/check/guard.py`, against main 75a6c7b5e's `rig`
  (`tools/baseline`), alternating, four rounds each at a load of 4.4 to
  4.7: the fewest instructions are 2,181,229,167 for main and
  2,181,628,245 for the branch, level (0.02%); both are 1.1% over the
  committed baseline, the machine's load. A first set of rounds read
  the branch 3.2% higher: the suite had rebuilt `bin/rig` with
  `-Dself-check=true`, and a plain `zig build` before the second set
  removed it.
- Trig and loc light gates were not run here: they run once the
  branch is rebased onto main, after the error-traces change lands.
