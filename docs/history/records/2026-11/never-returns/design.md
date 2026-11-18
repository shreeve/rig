# Functions that never return (2026-11-14)

## The problem

Trig replaced a per-module `go_panic`, whose body was a bounds failure
Zig and LLVM know never returns, with one shared helper in another
module:

```text
pub sub fail(msg: ?String)
  rarely
  print("!! stop", msg)
  panic(msg)
```

called from hot code (`debug.fail(msg) if not cond`, 17 sites in the
parser alone). Rig wrote `fail` as a Zig function returning `void`, so
in a split build LLVM had to assume it returns, and kept every caller's
fall-through path: Trig's parse phase measured 1.2% slower at one
checker.

## The fact

A function never returns when its body cannot finish and nothing in it
leaves early:

- no `return`, and no `!` or `?` that passes a failure or a `none` on,
  outside its closures (`rig.holdsExit`, which `rig.alwaysPanics`
  already reads);
- and its block diverges, where a statement diverges when it is a
  `panic`; a call of a function already known never to return; an `if`
  with an `else` whose branches both diverge; a `match` whose arms all
  do (every `match` is exhaustive); a `loop` no `break` leaves
  (`sema.isLoop`, `sema.breaksOut`); or a block one of whose statements
  diverges (what follows is never reached).

A `break` or `continue` out of a diverging statement can only go to a
loop inside the function, and a loop counts only when no `break` leaves
it, so at the function's level nothing reaches its end.

It is decided once, for the whole program, after every module is
checked (`src/returns.zig`, `returns.decide`, beside
`inlining.decide`), and recorded in each declaring module's
`SemContext.never_returns`, keyed as `inlined` is, by where the name is
declared. Emit reads it (`Facts.neverReturns`) and writes the function's
Zig result `noreturn`. No checker reads it.

## Decisions

1. **Which functions.** Only a function whose result is `Void` and that
   cannot fail: a `sub` without `!`. The runtime reads some functions'
   Zig result types by reflection (an actor's method, an iterator's
   `next`, a task's body); for a `Void` function the runtime maps
   `noreturn` back to `void` exactly (`tasks.zig`, an actor's
   `Result`), which no reflection can do for a function that names a
   value type. A `fun -> Int` whose every path panics stays as it is.
2. **Recursion.** The least fixed point: a call counts only once its
   callee is known never to return, so a function that only calls
   itself, or a cycle of functions that only call each other, is not
   marked. Sound, conservative, and deterministic.
3. **Methods** are functions: a call counts by the target typecheck
   recorded (`callTargetOf`). A call through an actor's handle, a
   witness, or an API object (`isActorCall`, `dispatchOf`) never counts:
   the Zig callee there is the runtime's or a type parameter's.
4. **Generic functions** are decided per declaration. Zig writes one
   generic function for all instances, and typecheck checks the body once
   with type variables, so the targets it recorded are the same at every
   instance; a method of a type parameter's value has no target.
5. **Closures** are never marked (a closure is called through a pointer
   whose type the Rig type sets). A function taking closures is decided
   like any other; a call of its closure parameter has no target, so it
   never counts.
6. **`test` blocks, `drop` bodies, compile-time functions, `extern`
   functions, and the root `main`** are not candidates. `main` is called
   by the runtime (`rig.onOwnStack`), which reads its result type.
   Rig has no exported or C-ABI functions of its own.
7. **What users see.** Nothing changes what a program means or whether
   it is accepted: a call of `fail` is still typed `Void`, so
   `fun h() -> Int` whose body is `fail("x")` is still rejected, and
   statements after a call of `fail` are still accepted (Zig 0.17
   accepts code after a call of a `noreturn` function, and coerces a
   pointer to a `noreturn` function to one returning `void`; probed).
   SPEC's "Function markers" says, beside the `rarely` rule, that such a
   function is compiled as one that never returns.
8. **Siblings.** `os.exit` is an `extern zig` function declared `sub
   exit(code: Int)`; its shim must match the Zig type Rig lowers the
   declaration to, so making it `noreturn` needs a way to say so in the
   declaration: new syntax, the owner's call. Not done here.
9. **Split builds.** `rig.split.crosses` already refuses a `noreturn`
   function, so such a function is never cut: each unit compiles its
   body, and every call of it is direct.

## Call sites

Emit changes nothing at a call. Zig 0.17 reports unreachable code only
after a statement it sees is `noreturn` by its syntax (`@panic`,
`return`), not after a call of a `noreturn` function, so the statements
a program writes after `fail(...)` still compile, and LLVM drops them.
Leaving them in keeps emit writing exactly what the checkers walked
(North Star 4), and keeps Zig's unused-local and never-mutated checks
seeing the code they saw.

## Tests

`test/rig/emit-never-returns.rig.test`: the code cases (a panic, a
call of one, a `loop`, a `match`; a method and a generic; a function
from another module), the cases that stay `void` (a panic on some paths,
a `return`, a `loop` a `break` leaves, a function that only calls
itself, an `if` with no `else`) and a `fun -> Int` that stays `i64`,
and runs: a guard that holds and one that fails, a `loop` ending in a
panic, a method and a generic, statements after a call, a call from
another module, lent as a callable, run as a task, deferred, and an
actor's method. `test/cli/units.sh`: the same across two units.
