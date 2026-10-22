# Can a plain `fun` value cross between tasks? Soundness review

Checkout: `~/Data/Code/worktrees/rig/fun-and-comptime` at 4805cd800 (main). Probes are in
`fc-panel/probes-a/`, each run with that checkout's `bin/rig`.

## Verdict: SOUND WITH AMENDMENTS

The claim holds by type once one existing checker hole is closed (A1):
**no value of type `.function` holds a closure, except a closure binding itself**, and a closure
binding has no use as a value except a call. `?g` turns it into `read_view(callable)`, which is
a different type. A `.function` value lowers to a Zig `*const fn` (emitted:
`f: *const fn (i64) i64`, `m: *const fn (*Counter, i64) i64`, `h: *const fn (i64) anyerror!i64`).
That is an immutable code address with no environment, so giving it to another core or sharing it
copies one word. It also confers no capability: a task on any core can already call that function
by name. Module-level bindings are compile-time constants. An `extern` C function cannot be a
value. No std Zig-backed function takes or returns a plain `fun`, and no std `.zig` shim has a
module-level `var`. A function type's parameters and result are not parts of the value
(SPEC, Owned closures), so `fun(*Node) -> Int` holds no `*Node`.

## Holes found

### H1: a closure literal assigned into an existing slot (exists today; must close first)

`rig check` accepts each of the following. Emit then fails with "internal error: cannot emit this
expression (sema should have rejected it)". That already breaks North Star 1 today. Under the
proposal, `g` would be a plain `fun` slot holding a capturing closure (even `|!total|`), and the
type rule would send it across cores.

| probe | form | today |
|---|---|---|
| p03_reassign | `g: fun(Int) -> Int = inc` then `g = \|+n, x\| x + n` | check accepts, emit fails |
| s05_while_assign | as p03, with `\|!total, x\|` in an `if`, then `t = call(g)&` | check accepts; a local task today, cross-core under the proposal |
| p13_reassign_task | p03 + `call(g)&` | check accepts |
| p04_writeview | `sub set(f: !fun(Int) -> Int)` with `f = \|x\| x + 2` | check accepts, emit fails |
| v06_fieldwrite_view | `set(!b.f)` with `f = \|+n, x\| x + n`, where `n` is `set`'s local | check accepts (a dangling env, if emitted) |
| y06_wlocal | `w = !h` then `w = \|+n, x\| x + n` | check accepts |

Cause: `src/ownership.zig`, the binding walk (around line 3931). For `.default, .fixed, .shadow`,
`is_lambda` sets `lambda_ok = true` before it knows whether `.default` makes a new binding or
reassigns (`self.find(name)` is checked only afterwards, at line 3955). `b.f = |..|` is rejected
(p12) because a field target is not a `.src` name.

Fix: set `lambda_ok` only when the statement makes a new binding: `.fixed`, `.shadow`, or
`.default` with `find(name) == null`. A reassignment, including one through a write view
(param, local, or `!b.f`), reports "closures cannot escape their defining scope".

### H2: owned closures would quietly change in local tasks

Owned closures would change behavior in local tasks without anyone deciding it. Suppose the change
just drops `.function` from `blockerIn`. Then `.shared => ... else if (local) blockerIn(ctx, inner, .shares, ...)`
recurses into `*fun`'s inner `.function` and returns null. A `*fun` or `~fun` given or lent to a
local task, rejected today (v05: "`*fun(Int) -> Int` holds `fun(Int) -> Int`, a function"),
would be accepted. Cross-core is still blocked, by `.shared => here`.

That is probably sound: an owned closure's environment holds no view and is read-only, and a
local task shares its thread. But it is a separate change. Pin it: in local mode, `.shared` and
`.weak` whose inner type is `.function` stay blocked.

### H3: `?fun` views must keep blocking, whatever their origin

`.callable` is what `?fun(...)` views (`callableOfFn` = `read_view(callable(fn))`). The type
cannot tell `inc`, `?h` (a plain local), `?g` (a closure), a closure literal, a captured `|?g|`
(u01–u03: inside a closure body a captured closure is `?fun`), and a forwarded `?fun` or
`once ?fun` param (q09, q10) apart. All of them must keep blocking, for moves and shares, local
or not.

Option rejected: deciding from the argument's expression (a name, or `?h` of a non-closure). That
is a second classifier for one fact. A task takes a function as `fun(...)` by value.

## Probes where the claim held

The following were all rejected on main:
- p01, p11, q07: a closure literal to a by-value `fun` param, `List.push`, or `Cell.set`.
- p02, p07, p08, p09, p10, p12, q12, t01–t03, v01, v02, w01–w03, x01: a closure binding
  copied, moved, `+g`, `=! g`, put in an optional, a ternary, a field, an element, or a generic
  `id(g)`, returned, or given to a task, including in a loop, inside a closure body, or with no
  annotation.
- p05, p06: a closure binding captured `+g` or `<g` into `*|..|`.
- q01, q02, u01, y04: a `?fun` converted to `fun`, or stored.
- q03, y02, y05: a closure lent where `?T` goes, including a generic object's `?T` field through
  a `type` alias. y05's message is confusing: "expected `?fun(Int) -> Int`, got
  `?fun(Int) -> Int`", because a read view and a callable print the same. Not a soundness issue.
- q08, s06, v03: a closure as a module constant, a default parameter, or a field default.
- s01: a comptime `fun` parameter. s02: `id[Int]` as a value. q14, y03: view fields of
  `?fun` or `!T`.
- `f(x)&` with `f` a fun value: "a task runs a call of a function or a method" (typecheck
  `taskOf`, `target != .function`).

`from` / `keeps`: z01 shows a `from` function is a value. Its loans apply at each call, made by
the caller with its own arguments; nothing crosses with the pointer. `Type.method` with `!@` is a
`*const fn(*T, ...)`; a write view reaches it only as an argument of a call, checked there.

## The rule to implement

In `src/sema.zig` `blockerIn`:

```zig
.function => null,          // a function's address: only a name makes one (Core §7)
.callable => here,          // a ?fun view: may view a closure's captures, any task, any core
.shared => |inner| ... else if (local and ctx.types.get(inner) != .function) blockerIn(...) else here,
.weak   => |inner| ... else if (local and ctx.types.get(inner) != .function) blockerIn(...) else here,
```

- `fun(...)` and `sub(...)` values move and share wherever they are reached: a field, an
  element, an optional, a `Map` value, a result tuple, a type argument, a read view `?T` of one,
  a write view `!fun` (moves), a task's result, an actor's value or argument, or a channel.
- `?fun` / `?sub` / `once ?fun` never go to a task, not even a local one.
- `*fun` / `~fun`: unchanged.
- Closure bindings: `Checker.closureBinding` (`sym.flags.closure` and type `.function`) in
  typecheck, and `v.closure` in ownership. Belt and braces, recommended: in `crossCheck`, a part
  that is `closureBinding(part)` is rejected with "a closure stays in its binding; it goes to a
  task only through a function". That way a future escape of a closure binding as `.function`
  still cannot cross.
- `blockerReason`: `.callable` gets "a closure or function lent for a call, whose captures its
  type does not show". `.function` no longer appears.

Also update:
- SPEC §18: the table row "a function | never | never" splits into "`fun` / `sub` value | yes |
  yes" and "`?fun` view, `*fun`, `~fun` | never | never". Drop "a function given" from Local tasks.
- docs/design/concurrency.md: its row "a stack closure | when its captures move | ..." is false
  today and should be replaced.
- `sema.zig` doc comments on `crosses` and `localBlocker`.
- test/rig/modules-imported.rig.test:822: `?lib.FS` now crosses, so `errors: 1`, with only the
  `Task` error left.

## CORE.md (§7, after "An owned closure ...")

> A function value, `fun(A) -> R` or `sub(A)`, is the address of a named function and holds
> nothing, so it moves and shares as an `Int` does and goes to any task. A closure is never such a
> value: a stack closure stays in its binding and is lent only as a callable view `?fun`, which
> no task takes, and an owned closure is a `*fun` handle, which crosses as any `*T` does.

## Test cases for the PR

**Accept** (each `test`, run under `seeds: 20`; `rig check --tasks` lists none as local):
1. `use_it(inc)&` with `use_it(f: fun(Int) -> Int)`: prints 42, not local (s08).
2. `Box(f: inc)` given (`<b`) and lent (`?b`) to tasks.
3. `List[fun(Int) -> Int]` lent to a task; `(fun(Int) -> Int)?` given; a `Map[Int, fun(Int) -> Int]` value.
4. `Counter.add` (`!@`) given; the task calls it on its own `Counter`.
5. A fallible `fun(Int) -> Int!` given; the task calls `f(4)!`.
6. `*Actor(Acc(n: 1, f: inc))`, plus an actor method taking a `fun` argument (x03).
7. A task whose result is `fun(Int) -> Int` (`pick()&` returns `inc`).
8. `!h` of a plain `fun` local lent to a task that sets it to `dec`.
9. A generic `peek[T](x: ?T)` given `?h` as a task.
10. `*Chan[fun(Int) -> Int]` sending `inc` to a worker task.
11. A function value from another module (`lib.twice`), and `text.find`.

**Reject:**
1. `call(?g)&`, where `g` is a closure binding (existing "task local function lent").
2. `call(|x: Int| x + 1)&` (existing "task closure literal lent").
3. A `?fun` param forwarded to a task, where the origin is a named function (q10).
4. A `once ?fun` param forwarded (q09).
5. A captured `|?g|` lent to a task from inside a closure (u03).
6. `call(?h)&`, where `h` is a plain `fun` local, to a `?fun` param.
7. `*fun` given to a task, both cross-core and where it would be local (v05, unchanged).
8. `~fun` lent to a task.
9. H1: p03, p04, s05, v06, y06, each "closures cannot escape their defining scope".
10. Regressions: x01 (`call(g)&` by value), p02, p07.

## Decisions for the owner

1. `?fun` views stay out of tasks, even of a named function. Default: yes; pass `fun(...)` by value.
2. `*fun` / `~fun` to local tasks stay rejected in this PR. Default: yes; decide separately.
3. H1 lands in this PR, before the relaxation. Default: yes.
