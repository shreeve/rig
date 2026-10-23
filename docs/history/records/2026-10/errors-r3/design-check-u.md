# Errors with data: dissolving the `error_data` switch (design check, 2026-10-22)

Ordered by the owner after R3's second review found two more soundness
bugs. Measured on the Mac (arm64). The probes, prototype and
measurements (probes/, proto/, latent/, micro/, jsonbench/, trigpack/)
stayed in the check's working folder; this report summarizes them. It
was built as the errors-u change (Option U, the coercion fact, and the
7 classes).

## Recommendation: Option U, one representation decided from the type

- `error` is always a `rig.ErrorValue`.
- Every `T!` frame and fallible function-value type always takes `__out`.
- The glue file is always written, empty when no set has fields.
- No pass reads a program-wide mode. `ErrData`'s size is a compile-time
  constant in the runtime.

**The HIGH bug is a missing coercion, not the switch.** A set without
fields widened into an error type with fields fails even with no
`error` and no mode involved: `error L = E | M; x: L = M.plain`
(probes/h2_union.rig). So keeping the switch as one shared fact
(Option K) does not close it.

- The checker records every adaptation to an expected type in one
  place (`recordAdapted` → `recordLift`, which is how optionals are
  lifted). Record "set without fields into an `ErrorValue` type" there.
- Emit wraps that value at its one value entry, `emitValue`, beside
  `liftOf`.
- Under U every program goes through this path, so a site that skips it
  fails in ordinary suite cases.
- MEDIUM (the leak in `print(mk())`, `mk() -> error`): give `error`
  drop glue in `sema.holdsIn`. CORE already calls `error` owning in
  every program.

**Why not K.** With the switch forced on, the core suite (about 5,600
jobs) failed 40 cases. 38 of them fail the same way on main's own
compiler once a program merely declares one unused member with fields.
That makes 7 latent bug classes on main; the second review found 2 of
them.

## Cost of U, measured

| Workload | Result |
|---|---|
| std.json, all six files, safe and fast | machine code byte-identical (`otool`); timings within 0.97–1.04 on identical code |
| `T!` recursion, catch loop, fields declared elsewhere | identical, or within 0.03% instructions (LLVM drops an unwritten slot) |
| A loop that only calls through a `?fun -> T!` | 1.2% slower (fast) and 4.0% slower (safe), with 0.2% fewer instructions; decision 4 targets this |
| Trig on ts-pattern, release | 48.46 vs 48.72 ms (0.5%), instructions 0.03% more; `checker.zig` unchanged |
| Trig, debug | 0.6% more instructions |

Instructions, main against the prototype, fast build:

| Case | main | prototype |
|---|---|---|
| `rec` | 936.3M | 936.6M |
| `catchloop` | 2,719.3M | 2,719.5M |
| `recfields` (fields declared but unrelated) | 937.2M | 937.5M |
| `recreach` (fields reach the slot) | 1,300M | 1,300M |

`recreach` costs 39% more than `rec` under every option.

**Size:** about 25–40 lines of mode plumbing removed, about 15 changed,
and about 50 for the coercion fact. The 7 classes take roughly 100–250
more lines; they are bugs on main and need fixing under K as well.

## What decides how `error` is represented today

- emit's `error_data` (6 direct reads) and the program-wide branch in
  `isErrorValueTy`, which feeds 28 calls in 20 functions;
- `typecheck.zig:5427` uses the module's `declaresErrorFields`, a third
  classifier;
- `storage.decideMatchRereads` always rereads, whatever the mode;
- `sema.holdsIn` gives `error` no drop glue (the MEDIUM leak);
- `main.zig` writes the glue, and builds a program with fields only
  outside a batch;
- the spec's §7.1 narrowing was never built: one field anywhere puts a
  slot on every `T!` frame.

Sema, storage and ownership run per module, before the program-wide
fact exists. K would therefore need the mode worked out before any
check, so a module's facts would depend on which program imports it.

## The 7 latent classes (latent/results.txt)

| Class | Cases | Example |
|---|---|---|
| Slot passed to a Zig-backed std method or function | 17 | `Chan.send(i, __out)`, `rig.net.copy(…, __out)`, std.http |
| Slot left out on another emit path | 5 | `rig.keep(…, mkf(6))` |
| A function-value type differs by the slot | 7 | `fn (i64) anyerror!i64` vs `fn (i64, *ErrData) …`, in tasks.zig and closures |
| Bare error code where an `ErrorValue` goes (the HIGH class) | 4 | `Net.timeout`, `X.one`, `A.x` |
| Emit's internal error "sema should have rejected it" | 3 | a `catch` read in place of a call that takes the slot |
| `==` on `error!ErrorValue` in a runtime path | 1 | modules-imported |
| A hidden `slot` shadows a declaration | 1 | ownership-misc-1 |

The MEDIUM leak makes the 7th class.

## Owner decisions (2026-10-22, all approved)

The owner's words: "Approve the defaults: adopt Option U and remove the
switch; drop §7.1's narrowing and §7.10's gate in favor of the json
instruction guard and timing; land U with the coercion fact and the 7
classes as one change before #565 and R2.5; make the slot zero-bit when
no set has fields."

1. Adopt U and remove `error_data`.
2. Drop spec §7.1's narrowing and §7.10's gate. The gate is the json
   instruction guard, plus Trig and json timing on both machines.
3. Land U, the coercion fact, and the 7 classes as one change, before
   #565 and R2.5.
4. Make the slot zero-bit when no set has fields, in the same change.

**Not recommended now:** making every error value one `ErrorValue`
type, sets without fields included. It costs 2+N bytes for a stored
error without fields in a program with fields, and changes §7.2.
