# R3-1: fields on error members, in direct calls (design)

Round R3 of errors with data, phase 1 (the owner: "Start R3 here in this
session"). It builds the spec's §4 and §5 and §7's lowering for direct
calls, catches, and leaving `main` (spec:
../../revamp/r3/errors-panel/errors-spec.md; CORE §2, "A failure moves
its error"). Phase 2 takes tasks and function values; phase 3 the
oracle and std's I/O sets.

## Checking

- A member may declare fields as an enum's variant does.
- The field rule, at the set's declaration (`Checker.checkErrorFields`):
  a field's type holds no loan (`sema.mayHoldView`), holds no `*` or `~`
  handle anywhere (`sema.holdsHandle`), and clones (`sema.cloneable`);
  `error`, or the set itself, inline is "a member holding `error`
  contains itself: write `^error`".
- Construction, patterns, printing, and comparing take the payload
  enum's paths, which the checker already has.

## The program-wide fact

`main.zig` knows, once every module is checked, whether any module
declares a member with fields. It tells each module's emitter, as it
tells it whether the program makes tasks. In a program where none does,
emit writes exactly the Zig it writes on main.

## Lowering, in a program with fields

- A set's declaration: the Zig error set of every member's code, and
  for each member with fields a Zig struct of them,
  `pub const @"E__bad" = struct { pos: i64, msg: rig.String };`.
- A value of a set with fields, of a union of one, and of `error`, is a
  `rig.ErrorValue`: `{ code: anyerror, data: rig.ErrData }`. Its drop,
  clone, `==`, and print go through the glue. A set without fields
  stays a bare Zig error.
- A function that may fail with fields (its set has a member with
  fields, or it is `T!`) takes `__out: rig.ErrSlot` last. A Zig-backed
  one never does.
- `return E.bad(f: x)` writes the member's struct through `__out`, then
  returns the code. `return e` of an `ErrorValue` copies its data
  through `__out` and returns its code. A member without fields writes
  nothing.
- `g()!` passes the function's own `__out`.
- `g() catch |e| H` declares a slot in the statement, passes it, and
  binds `e` as `.{ .code = err, .data = slot }`, owned by the handler.
  A `catch` that binds no name, or `_`, drops the slot's data before
  its handler.
- `match e` switches on `e`'s code, narrowed to the set; an arm of a
  member with fields reads its struct from `e.data`.
- The glue: one program-wide file, `__rig_errors.zig`, imports each
  module that declares a member with fields and defines `Glue`: `size`
  and `alignment` (the largest member's struct), `drop`, `clone`, `eql`,
  and `print`, each a switch on the code. The root module re-exports it
  as `__rig_error_glue`, which switches R3a's runtime on.
- Leaving `main`: the body is called with a slot of `__rig_run_main`'s;
  a failure is shown and its fields dropped (`rig.reportFailure`)
  before `rig.finish`'s leak check, then `rig.failMainReported` exits.

## What shows it

- Every R3 case of errors-spec §11 that needs no task or function
  value, under the sanitizer.
- `tools/equiv.py`: no emitted difference for any program in the suite
  that declares no member with fields.
