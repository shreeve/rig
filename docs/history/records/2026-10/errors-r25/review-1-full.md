# R2.5 generic error sets: soundness review 1

The full text of [review-1.md](review-1.md), with every probe program inline. The
probes ran with `RIG_OUT_DIR` set and `RIG_SANITIZE=1`; the files were not kept.

## Findings

### 1. HIGH: `return e` in a generic-set body writes into `rig.unwritten_slot` (bus error)

Probe: `p11min.rig` (also `p11.rig`, `p12.rig`, `p13.rig`)

```rig
error Bad
  empty

error Wide
  big(n: Int)

fun g(n: Int) -> Int!Bad
  return Bad.empty if n == 0
  n

fun first[E](n: Int, f: ?fun(Int) -> Int!E) -> Int!E
  v = f(n) catch |e|
    return e
  v

fun outer(n: Int) -> Int!Bad
  first(n, g)!

sub main()
  print(outer(0) catch -1)
```

`rig check` accepts it. At run time it crashes with `Bus error` in
`putFields` (runtime.zig:126). `outer` fails with `Bad`, which has no
fields, so it has no `__out` and lends `rig.unwritten_slot` to `first`.
In `first`, a value of `E` is always a `rig.ErrorValue`, and `return e`
emits `rig.failValue(__out, ...)`. That calls `putFields`, which copies
the whole `ErrData` whenever `@sizeOf(ErrData) > 0`, whatever the
member. Because some set in the program (`Wide`) has fields, it writes
into `no_error_data`, a `const` that `@constCast` made writable, which
is read-only memory.

The same crash happens:
- when the frame without a slot is a closure lent as
  `?fun(Int) -> Int!Bad` (p13: `via(0, |x| first(x, g)!)`);
- inside a task's callback chain (p12, `twice(0, |x| first(x, g)!)`).

Without `Wide` (`p11nofields.rig`) it prints `-1`.

The design's claim "nothing writes it: the view's set has no fields
there, by typing" does not hold. `failValue` writes the slot for every
member, including one with no fields. Possible fixes:
- make `failValue` or `putFields` write only when the code's member has
  fields (the glue knows this);
- make `unwritten_slot` writable scratch (per thread);
- give a frame without a slot a real local slot when it calls a
  fails-by-set function.

### 2. HIGH: a fallible `task.select` arm function no longer compiles (Zig error)

Probes: `p03.rig` (named function), `p05.rig` (closure literal)

```rig
use std.task

error Bad
  empty

fun pick(v: Int?) -> Int!Bad
  return Bad.empty if v == none
  v ?? 0

fun quitf(v: Int?) -> Int!Bad
  return Bad.empty if v == none
  100

sub main()!
  ch = *Chan[Int](4)
  quit = *Chan[Int](1)
  !ch.send(7)!
  r = task.select(
    (!ch).on_recv(pick),
    (!quit).on_recv(quitf),
  )!
  print(r)
```

`rig check` accepts it. Zig fails at `tasks.zig:1603`: "missing tuple
field with index 1". `select` calls `arms[k].f.call(.{arms[k].got})` (and
`.call(.{})` on line 1604) without `argsWithSlot`. Every `FnRef` of a
fallible function now has `ErrSlot` in its parameters, so the call is
short one argument. The program has no fields at all, so before this
change the `FnRef` had no slot and this compiled.

This is a regression for any fallible arm in a program without fields.
It already failed this way, before the change, in programs with fields.
Fix: use `rt.argsWithSlot(F, ..., slot)` there. A select that fails with
fields also needs an `Into` slot variant, as `parMap` and `reduce` have.

`net.zig:636` (`t.f.call(.{t.req})`) is safe only because an http
handler is not fallible. Every other runtime `FnRef` call goes through
`argsWithSlot`.

### 3. MEDIUM: bad diagnostic for a closure-only call in a frame that declares a set

Probe: `p17.rig` (and `p16.rig`, an actor method)

```rig
fun outer(n: Int) -> Int!Wide
  first(n, |x| w(x)!)!
```

The errors are:
- "conflicting types for `E` in the call to `first`: `Wide` (argument 0)
  and `error` (argument 2); give it in brackets: `first[error](...)`".
  "Argument 0" is the result context, not an argument. The suggested
  `first[error]` is then rejected (p17b.rig: "`expression` may fail with
  any error, and `outer` declares `Int!Wide`").
- A cascade, "use of `!` propagation requires a fallible enclosing
  function", pointing at the closure body.

`first[Wide](...)` works (p17c.rig). Rejecting the call is by design
(rule 3), but the message should point to `first[Wide]` and should not
call the result "argument 0".

### 4. LOW: suggests a union over a set parameter, which is out of scope

Probe: `r4.rig`

`fun f5[E](..., f: ?fun(Int) -> Int!E) -> Int!Bad` with `f(n)!` says:
"... or declare a set that holds both (`error L = Bad | E`)". Unions
over a parameter are out of scope (design §5), so the suggestion cannot
be followed.

### 5. LOW: the generic mismatch message names the inner type

Probe: `r5.rig`

`f6(1, one)`, where `one` is not fallible, says "expected `Int!E`, got
`Int`". The non-generic case (`r6.rig`) says "expected
`?fun(Int) -> Int!Bad`, got `fun(Int) -> Int`". The generic message
comes from `bindArg`'s inner `noteMismatch`.

### 6. LOW, pre-existing: a bracketed generic call is named `` `expression` ``

Probe: `r7.rig`

`id[Int](n)!` says "`expression` may fail with any error ...". This
happens without set parameters too.

## Not findings (by design or pre-existing)

- `xs.reduce(0, f)` with a view `f: ?fun(...) -> Int!Bad` (or `!E`) is
  rejected because reduce expects `Int!`. This is the same for declared
  sets, so it is not new.
- Passing a `?fun -> Int!Bad` (or `!E`) where `?fun -> Int!` goes is
  rejected. Views are not widened.
- `par.map(xs, f)` with a view, or with a closure that captures `?f`, is
  rejected by par's capture rule.

## What works (sanitizer-clean, no leaks)

| Area | Probe |
|---|---|
| Local views `h = ?g` | p01 |
| Closure literals; owned closures lent (`?c` and bare `c`); function values (`fv`, `?fv`); `List[*fun]`; arrays of function values; optional function values; with sets with and without fields; programs with and without fields | p02, p18, p18b, p30 |
| `time.within` with `!Bad` and `!Wide` functions | p08 |
| `reduce` and `par.map` with set callbacks, and the generic function inside their closures | p07 |
| `List[E]`, `+e`, `<e`, `?e`, `x: E` locals, `E?` locals reassigned in a loop | p09, p36 |
| `defer` and `errdefer`, recursion, recursion that wraps the callback, `wid[error]` | p10, p37 |
| `E = error` with String fields; catch with and without a binding; `return <e` as `error?`; `catch none` | p14 |
| Methods with their own set parameter (`?@`, `!@`), on a generic object | p15 |
| Actor methods calling generic-set functions | p16 |
| Tasks over generic-set functions, with fields and without, in a list | p24 |
| Higher-order views whose parameter is a view with `!E`; unions inferred from closures and named in brackets | p19 |
| `[E, T]`, `[T, E]`, `[k: Int, E]`; two set parameters | p23, p27 |
| Owned closures and stack closures typed `!E` in the body, lent to another generic | p32, p33 |
| Owned results through `f(n)!.len` and `catch String(...)` | p35 |
| Parenthesized and `if`/`else` forms | p26 |
| `sub main()!` and `test` blocks | p29 |
| Cross-module: `pub` generics, a lib without fields with a main with fields, an imported set bound from two modules | m1, m2 |
| Expected rejections give Rig diagnostics, not Zig errors | r1 to r5 |
