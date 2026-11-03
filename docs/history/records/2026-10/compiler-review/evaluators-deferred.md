# One constant evaluator: deferred to the rewrite (2026-10-31)

Row 33E's PR 2 ("one constant evaluator, not four") was dropped from 33E by Rig - Swiss, option 1
of three, on Rig language analysis's reading of the code at 0fc7f6956. The owner accepted the
review's default; Rig - Swiss told him it is deferred, and why. If he wants it now, it returns as
option 3 below.

## The four evaluators are not four copies of one thing

| Evaluator | What it does |
|---|---|
| `cteval.Eval` (cteval.zig) | runs a checked compile-time function's body over the recorded types, within fixed limits |
| `sema.ctFoldBy` / `constIntBy` / `constBoolBy` (sema.zig) | folds constant expressions through a `names` environment; cteval's `argValue` already uses them, so these two share their integer arithmetic (`sema.ctArith`) |
| `inlining.Pass.valueOf` (inlining.zig) | a partial evaluator over function instances: it knows a function's compile-time parameters at one instance (Bool ones too), and decides `x and false` (false) or `x or true` (true) with an unknown side; null for anything else |
| typecheck's float folding (`floatConstIn`, `floatLimit`, `floatOp`, `floatOverflows`) | folds a float constant rounded to `F32` or `F64` at each step, for the overflow and limit diagnostics; `floatLimit` reads `F32`, `F64`, `Float` by text |

## Why it is not a cleanup

Making these one evaluator means either:

- (a) teaching `constBoolBy` to read Bool parameters and to decide around an unknown side. That
  changes what every other caller folds, the constant `if` conditions among them, so it can change
  which programs are accepted and the emitted Zig; or
- (b) giving cteval a partial mode that inlining's guards use.

Either one is design work for the rewrite. Moving the code into cteval.zig without unifying the
semantics would only relocate it.

## Options that were offered

1. **(taken)** Drop it from 33E; record "one evaluator with a partial mode" as a rewrite item, beside
   the typed and lowered IRs.
2. A narrow PR: move only typecheck's float folding beside `ctFoldBy` in sema (`ctFloatBy`), every
   float-overflow and float-limit `fail` case keeping its message and position. It unifies nothing.
3. The full unification now: inlining onto `constIntBy` / `constBoolBy` with an opt-in partial mode,
   emit-identical on Trig.

## For the rewrite

One evaluator, cteval's, with a partial mode: values may be unknown, `and` and `or` decide on a known
side, and compile-time parameters bind per instance. Constant folding, compile-time functions,
inlining's guards, and float constants all go through it, with one arithmetic (`ctArith`) per number
type.
