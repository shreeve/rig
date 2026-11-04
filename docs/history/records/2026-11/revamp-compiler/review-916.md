# Review of PR #916 (rv-types)

Rig at the branch head (`bin/rig`) compared with main (f4769e324, built by `tools/baseline`). Probes are in `$TMPDIR/p916/` (`run.sh` runs both rigs under `RIG_SANITIZE=1`). Areas run: `ctfun` and `concurrency-actor`, both green.

Verdict: V2/V3, T1's fallible join, V6's main forms, and the duplicate-keyword handling work as claimed. U1 is still unsound in two forms the PR does not cover (issues 1 and 2), and they belong in this PR. Separately, I found a severe emit bug that main has too (issue 6).

## 1. U1 unsound: a typed constant whose value is an enum literal (high)
`src/cteval.zig:1000-1008` (`spelledType`) reads only the constant's *value*. For `H: Other = .east`, the value `.east` spells no type, so the function returns null and nothing is checked. `argValue` then reads `.east` as `Dir.east`.
```
enum Dir: north, east     enum Other: west, east
fun size[d: Dir] -> Int  -> Int(d) + 1
H: Other = .east
a: [size[H]]Int = [1, 2]      # accepted on both rigs, prints 2
type P = [size[H]]Int         # accepted (alias)
fun g[n: Int]() ... a: [size[H]]Int   # accepted (generic body)
```
In a body, `print(size[H])` is rejected ("expected `Dir`, got `Other`"). The untyped `H = Other.east` is now rejected, so the PR closes the untyped form only.
**Fix:** when `ir.Set.type(set) != .nil`, resolve that type in module scope and return it, before falling back to the value.

## 2. U1 unsound: a nested compile-time call as an argument (high)
`spelledType` returns null for `.ct_call` (`cteval.zig:1010`).
```
fun oth[n: Int] -> Other  -> Other.east
fun add[n: Int] -> Int
a: [size[oth[0]]]Int = [1, 2]   # accepted, 2 (Other.east as Dir)
a: [size[add[0]]]Int = [1, 2]   # accepted, 2 (Int 1 as Dir)
type P = [size[oth[0]]]Int      # accepted
```
In a body, and in a `Simd` count, the same call is rejected.
**Fix:** for `.ct_call`, return the callee's declared result type (`signatureOf(target).returns`, imported).

## 3. A slice crosses to a task with only `Sends` on its elements (medium; also on main)
`src/sema.zig:11318`: `.slice => blockerIn(ctx, sl.elem, how, ...)` passes `how` on, while `.read_view` uses `.shares`. A `[]T` is a shared read view, so `T` should sync.
- `fun n(ts: []Task[Int])`, `n(?ts)&`: accepted and runs.
- `?Task[Int]` in the same position is rejected.
- `c.sl(xs)` for an actor `fun sl(?@, xs: []Holder)`, where `Holder` holds `^{Job + Sends}`: newly accepted by V2. `c.sl(?xs)` was already accepted on main.

The actor message also says the slice "is given to it" (`typecheck.zig:13994`: `how` is `.moves` for any `k` but `.read_view`).
**Fix:** in `blockerIn`, give a slice `.shares`, and let `.write_view` of a slice walk the element with `.moves`. In `actorCall`, treat `.slice` as `.shares`.

## 4. T1: an arm that never returns still decides the join by order (low)
`typecheck.zig:15184`: `first = arms[0].gives`.
- `select(a.on_recv(|v| panic("no")), b.on_recv(|v| v ?? 0))!` is rejected ("bound to `Void`").
- The same arms swapped run and print 7.

**Fix:** take the value type from the first arm that does not give `noreturn`.

## 5. V6: a `=!` binding or a compile-time call that is the enum none still panics at run time (low)
- `k =! Kind.empty; Tagged(kind: k)` passes the check and panics at run time.
- `Tagged(kind: pick[0])` does the same.

The integer none rejects both forms at check (`Node(id: U32(zero[3]))`). The enum branch (`typecheck.zig:12718`) is syntactic.
**Fix:** decide it with the same constant evaluator the integer branch uses.

## 6. Out of scope, severe, also on main: a select arm's closure that captures reads a dead stack frame
- `x = task.select((!a).on_recv(|+k, v| k + (v ?? 0)))!` prints `-6148914691236517201` (0xAA…, undefined memory).
- With `|?s, v|`, it panics in `FnRef.ctxAs`'s alignment invariant.

Emit (`emit.zig:9321`) declares each arm's `__rig_env_N` inside a labeled block, `__rig_call_N: { var env…; break … recvArm(a, FnRef.of(&env)) }`. That block has ended by the time `selectInto` calls the arm. This breaks North Star 1 and 2.
**Fix:** hoist each arm's environment into the enclosing scope (phase 2, emit). Add a case with a capturing arm.

## Checked and fine
- **Actor arguments (V2/V3).** Bare, field path, temporary, box, optional (`?Holder?`), `?*Plain`, API object erasure, and `<h` all cross as views and must sync. `?h`, `+h` (wasted clone), and given values are unchanged. Closure literals are still checked. A generic `?U` and a write slice are type errors, as before.
- **Lifetimes after dropping the "keeps" claim.** Under `&`, a task still keeps every loan: drop, move, write, reassign, and a loop-local in `Tasks` are all rejected. A plain call's loan ends at the call (`n = c.sl(xs); !xs.push(4)` runs clean).
- **`reduce` with `stores = 0`.** I could not make it keep a view: closure bodies that store an element view are rejected, and so is `keeps` with a returned write view.
- **Duplicate keywords.** Functions, methods, actor methods, `Actor`, `task.supervise`, and constructors each report once.
- **`stdForm`** matches the old dispatch, including `par.workers`.
