# R3a review: runtime error-data plumbing (branch `slots`, commits aab2ea583..ea5a093c7)

Scope: `git diff origin/main -- src/` (src/runtime.zig, src/tasks.zig). Read-only; one Zig
experiment (`zs.zig` here) checked the gate-off codegen.

## Verdict

No blockers. With the gate off, ReleaseFast/ReleaseSafe code for the hot paths is unchanged;
with the gate on, every site I traced keeps or drops a failure's data exactly once, and no
site reads `control.err` after `release()`. One test is racy (M1).

## Question 1: gate off

- `ErrData` is `extern struct { bytes: [0]u8 align(1) }`, so `@sizeOf` is 0. `Control` is
  unchanged in size (checked: a struct with a zero-size `err` field keeps its old size).
  `?*ErrData` is still an 8-byte runtime value, but every gate-off caller passes a literal
  `null` to a private function with one live caller (`waitWith`, `waitAllWith`,
  `waitFirstWith`, `waitTasksWith`, `parRunInto`). The `*Into` entries are never referenced,
  so Zig never compiles them.
- Experiment: `keepFailure` applied to an `anyerror!u64` with a runtime `?*ErrData` gives
  the same ReleaseFast arm64 instructions as the function without it. The `o.* = d.*` copy is
  zero bytes, and `dropErrorData` is inline and comptime-empty.
- `callChunk` returns `anyerror!void`, and both chunk bodies (`parMap`/`parEach` `Ctx.chunk`)
  already return `anyerror!void` when fallible. It is called only under `comptime fallible`,
  so the types of `parRun`, `parMap` and `parEach` are unchanged. The non-fallible short path
  still `return body(ctx, 0, n)`.
- Ordering: every data copy or drop is evaluated before the `defer release()` runs, or sits
  textually before `release()` (waitTasks, waitAll, waitFirst).
- `rig run/test/build` use `zig build-exe`, never `zig test`, so `builtin.is_test` never
  turns on `TestErrorGlue` in a program.

### L1 (low): debug builds keep a residual cost
`Task.wait` -> `waitWith(null)` -> `keepResult` adds two calls, a by-value copy of `T`, and
a runtime `if (out)` plus an error-union test in Debug, where LLVM does not optimize. The same
holds for the waits on sets and for `parRun`. `rig run` and the suite build Debug. This is
negligible, but it is not "identical". Fix if wanted: make the slot comptime-optional
(`comptime has_out: bool` plus `out: if (has_out) ErrSlot else void`), or skip the `keepResult`
call under `comptime rt.error_glue == null`.

### L2 (low): `wait_first` has a new safety check
`var last: ?Err` and `last.?` add a null check once per all-failed `wait_first` in safe
builds. It is not on a loop path; leave it, or keep `Err = undefined` plus a separate
`have_last` that only the gate-on path reads.

## Question 2: gate on, per site

- `Task.waitWith`: the canceledHere, timed_out and passed_on paths drop through
  `dropResult`, and the normal return keeps (copies into `out`, or drops when there is
  none). Exactly once, before release.
- `cancelWith` keeps; `__rig_drop` drops. Both run before the deferred release.
- `waitTasksWith`: the `failure == null` guard means only the first failure is
  `keepFailure`d. Untaken tasks are stopped and `dropResult`ed. A Stop from `w.sleep`
  writes nothing, which is right because Stop has no fields.
- `waitAllWith`: it keeps the first failure, returns at once, and `stopUntaken` drops the
  rest. A sleep failure drops every untaken task. Correct.
- `waitFirstWith`: each new failure drops the one before it. Success, sleep failure and
  the all-failed exit each settle `last` exactly once. Correct.
- `dropEnded` keeps a failed task without touching its data (`Handle.keep` is a no-op, and
  `join` gives the same result again). The data is later settled once by whichever of
  wait_all, wait_first, stopUntaken or `__rig_drop` takes it. No double drop.
- `ParState.fail`: the cmpxchg winner copies the data, and every loser drops its own slot.
  `failure` and `failure_data` are read only after `for (helpers) t.wait()`. Helpers are
  `Task(void)` and have no deadline, and a canceled waiter still joins in `stop()`, so the
  join always happens-after the winner's writes. No race.
- `takesSlot` matches only a last parameter whose type is exactly `*rt.ErrData`. A generic
  last parameter (`null`) and any other pointer return false. A `FnRef` or closure struct
  returns false, which is R3's concern.
- `reportFailure`: the drop is deferred, so it runs on the interrupt path too. On that path
  nothing is shown, the later `finish()` flushes output, and `failMainReported` ends by the
  signal, which matches `failMain`.

### M1 (medium, test flake): `TestErrorGlue.drops` is not atomic
Location: runtime.zig `TestErrorGlue.drop` (`drops += 1`), and the tasks.zig test "a par
run keeps its first chunk's failure data...".
Scenario: `runForTest(..., 4)` runs helpers on 4 OS threads. The cmpxchg losers call
`s.fail` -> `dropErrorData` at the same time, an increment is lost, and
`calls - 1 == drops` fails intermittently. TSan would also flag it.
Fix: make it `std.atomic.Value(usize)` with `fetchAdd(1, .monotonic)`, and update the readers.

### L3 (low): gate-off versions of `reportFailure`, `showFailure` and `failMainReported` are never compiled
`is_test` forces the glue on, and no program references these functions, so the
`errorShown` branch has never been type-checked. Add a gate-off compile reference in R3, or
call them from emit only when glue exists.

### N1 (nit): `waitTasksInto` is not re-exported
runtime.zig re-exports only `pub const waitTasks = tasks.waitTasks;`, so emit cannot reach
`rig.waitTasksInto` yet. `parMap` and `parEach` have no `Into` entry, which the design defers.

### N2 (nit): the design doc does not match the code
The doc says `ErrData = [N]u8 align(A)` / `[0]u8`; the code uses
`extern struct { bytes: ... }`. Update the doc, since R3's emit must match the code.

### N3 (nit, for R3): `reportFailure` changes when the error line appears
It shows the error before `main`'s drops and `finish`, while `failMain` shows it after them.
Output from drops, or from tasks still running, now follows the error line. It also holds
the output lock and stderr while `glue.print` formats user fields; a panic inside it would
deadlock the panic report.

### N4 (for R3): a slotless wait must not let a fields failure propagate
`wait()`, `waitTasks()`, `wait_all()` and `parRun` without `out` drop the data but still
return the code. Emit must use the `*Into` forms wherever a member with fields can propagate
to a catcher; otherwise the catcher reads an undefined slot.

## Resolution

- M1: `TestErrorGlue.drops` is an atomic count.
- L1: a wait no one takes the fields from is given `rt.no_slot`, a
  `NoSlot`, and every choice between a slot and a drop is made at
  compile time, so a plain wait has no slot code in any build mode.
- Nits: `waitTasksInto` is re-exported; the design note says `ErrData`
  is a struct; `reportFailure`'s comment says emit calls it after
  `main`'s drops and defers, before the leak check.
- L2 (`last.?` in `wait_first`) and L3 (the gate-off forms of the exit
  functions compile only once R3 calls them) are left: one check on a
  path where every task failed, and code R3 compiles.
