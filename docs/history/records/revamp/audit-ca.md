# Audit: closure-args (borrowed callables, `|?x|` / `|!x|`)

Branch `closure-args` at `ce59309`, reviewed against `git diff main..closure-args`.
Built main from `git archive main` into scratch to check for regressions.

Repro directory, with every finding verified twice:
`/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R16/repro/`
(`$R` below). Run with `RIG_OUT_DIR=$R/../out bin/rig run $R/<file>`.

## Findings

| ID | Sev | Kind | Summary | Repro | Suspected code |
|---|---|---|---|---|---|
| C1 | Critical | wrong accept (use-after-free) | Calling a callable value that is not a closure binding drops the callable's loans from the result. This covers a `?fun` local (`g = ?l; r = g()`), `(?l)()`, and `pass(?l)()`. A `|?c| c` result then outlives `c`, or is returned from the function that owns `c`. | `C1_callable_result_loans_scope.rig`, `C1b_lend_call_result.rig`, `C1c_passed_callable_call.rig`, `C1d_return_dangling.rig` | `src/ownership.zig:2334-2344` (`walkCall` callee branch) |
| C2 | Critical | wrong accept (dangling borrow) | A closure body can store a borrow received as a closure *parameter* through a captured `!v`, either as `v.w = w` or `v = View(w: w)`. The caller then passes a borrow of its own local, which escapes into the outer `v`. | `C2_param_borrow_through_capture_literal.rig`, `C2b_param_borrow_through_capture_named.rig` | `src/ownership.zig:2269-2283` (`walkFieldAssign`), `:2207-2214` (`reassign`), `:2523` (`isLocalLoan`) |
| H1 | High | wrong accept (Zig compile error) | `|!x|` of a binding that is never otherwise written emits `const x`, so `&x` is `*const`. It hits any non-literal initializer: `x = seed(1)`, a struct holding a borrow, a `*T`. | `H1_write_capture_const.rig`, `H1b_write_capture_const_struct.rig` | `src/resolve.zig:419-428` (`markWritten` is not called for `cap_write`) |
| H2 | High | wrong accept / regression | `?T` with `T` a function type (a `fun` value, a function name, or a stack closure) becomes a borrowed callable after substitution. The call site emits `rig.FnRef`, but the generic body declares `rig.ReadBorrow(T)`. This breaks a generic `fun f[T](x: ?T)`, a generic struct field `w: ?T`, and an enum payload `v: ?T`, including across modules. `H2b` and `H2c` ran on main. | `H2_generic_readborrow_T_closure.rig`, `H2b_generic_readborrow_T_fn_regression.rig`, `H2c_generic_field_regression.rig`, `H2d_generic_enum_payload.rig` | `src/sema.zig:2365` (`callableFn` matches the substituted `?T`), `src/emit.zig:2181`, `:3719` |
| H3 | High | wrong accept (Zig compile error) | `|?f|` of a named stack closure: the env field is typed `rig.FnRef`, but the initializer is the closure struct `f`. The capture diagnostic's own hint ("Borrow it with `|?f|`") leads here. | `H3_capture_read_closure.rig` | `src/emit.zig:3542` / `writeCapturedBorrow` (`:3552`) does not use `emitLend` for closures |
| M1 | Medium | wrong reject / regression | A `!fun(Int) -> Int` parameter and `!g` of a `fun`-typed local are now rejected, so a function-pointer variable can no longer be reassigned through a write borrow. Both ran on main. The hint `?g` cannot assign, and `M1` also cascades to 3 errors. | `M1_write_borrow_fn_regression.rig`, `M1b_generic_write_fn_regression.rig` | `src/resolve.zig:1461`, `src/typecheck.zig:2300`, `captureBorrow` `.function` arm |
| M2 | Medium | bad diagnostic (hint loop) | `|+f|` of a `?fun` param suggests `|<f|`. `|<f|` then suggests `|+f|`. Neither compiles; `|?f|` does. | `M2_capture_callable_param_hint.rig` | `src/typecheck.zig` `checkCapture` (`cap_clone` message), `src/ownership.zig` move-capture of borrowed param |
| M3 | Medium | bad diagnostic | `|+f|` of a stack closure gives 2 errors: "move it in with `|<f|`" and "Borrow it with `|?f|`". The second hint hits H3. | `M3_capture_closure_two_errors.rig` | `checkCapture` and `src/ownership.zig:2636` |
| M4 | Medium | bad diagnostic | `apply(cb, 1)` for an owned `cb` gives 2 errors with conflicting hints: "write `?cb`" and "use `<cb` to move or `+cb` to clone". Neither of the second pair compiles. | `M4_owned_closure_bare_two_errors.rig` | ownership bare-shared-handle check runs after typecheck already reported |
| L1 | Low | bad diagnostic | For `+cb` / `<cb` passed as a callable, the hint is "write `?+cb`" / "write `?<cb`". | `L1_owned_closure_hint_nonsense.rig` | `src/typecheck.zig` `lendCallable` (uses `sourceText(e)`) |
| L2 | Low | bad diagnostic | For `apply(mk(), 1)` the hint is "write `?mk()`", which is then rejected as a temporary that owns a resource. | `L2_owned_temp_hint.rig` | `lendCallable` |
| L3 | Low | bad diagnostic | `keep(?f)` with a generic `T` → `Vec[T]` gives 3 errors for one mistake, and `opt(?f)` / `wrap(?f)` give 2. | `L3_generic_vec_three_errors.rig` | `heldCallable` at instantiation plus the existing generic-borrow rule |
| L4 | Low | bad diagnostic | `Cell(value: ?f)` gives 3 errors. | `L4_cell_three_errors.rig` | same |
| L5 | Low | bad diagnostic | `|?double|` of a module function gives a correct first error, then "bare use of captured resource `double` … use `+double`". | `L5_capture_module_fn.rig` | `src/ownership.zig` capture resource marking (`.cap_read`/`.cap_write` => resource) |
| L6 | Low | bad diagnostic | Moving out of a `|!r|` capture says "closure captures are owned by the closure environment … Use `+r`". `r` is borrowed, not owned, and `+r` does not compile for a resource struct. It also gives 2 errors. | `L6_move_borrowed_capture_msg.rig` | `src/ownership.zig:2606` (`cap_read`/`cap_write` treated as `capture_resource`) |
| L7 | Low | inconsistency / message | Through a captured `!c`, `!c.inc()` and `!v.push(1)` are rejected with "captures are fixed when the closure is created". The same spelling is accepted on a `!T` parameter, and `!b.items.push(n)` is accepted on the capture. | `L7_write_capture_method_sigil.rig` | `checkBindingWritable` `.capture` arm used for method receivers |
| L8 | Low | wrong reject | Closure literals are inferred in parameter order with no second pass: `rpipe(3, |b| ..., |x| x > 2)` cannot infer `C`, while the same call with the parameters swapped works. | `L8_literal_order_inference.rig` | `src/typecheck.zig` `inferBindings` lambda loop (`:4091`) |
| L9 | Low | bad diagnostic | A literal passed to a plain `fun(Int) -> Int` parameter suggests "make it owned (`*|...|`)", which that parameter does not take. It should suggest declaring the parameter `?fun(Int) -> Int`. | `L9_fun_param_literal_hint.rig` | "closures cannot escape" message |
| L10 | Low | bad diagnostic | `run(?f)` into a `fun` parameter suggests "`?fun(Int) -> Int` or `!fun(Int) -> Int`". `!fun` is now rejected. | `L10_fun_param_borrow_hint.rig` | borrow-copy mismatch hint |
| L11 | Low | wrong reject / message | `|!v, ?b| v.w = b` is rejected even when `b` outlives `v`, with the message "`v` borrows `v`, which outlives it". | `L11_store_outliving_capture.rig` | `walkFieldAssign` `borrowedRoot` path |
| L12 | Low | bad diagnostic | `s.subscribe(|?x| print(x))` gives 3 errors. Main gave 2 for `|+x|`; the new one is "cannot store a borrow of `x` in a `Signal`". `*|?x|` then hints "use a stack closure", which `subscribe` does not take. | `L12_signal_literal_three_errors.rig` | Cell/Signal store check and owned-closure borrow message |
| P1 | (pre-existing) | wrong accept | Rebinding a `?Wrap` local (plain struct, held by pointer) to a call result that returns `?Wrap` by value fails in Zig. It is pre-existing for functions (`P1b` fails on main too); the new callable path hits it too. | `P1_readborrow_plain_rebind.rig`, `P1b_preexisting_plain_rebind.rig` | `emitRebind` / plain read-borrow representation |

### C1 detail

```rig
sub main
  a: Vec[Int] = Vec()
  !a.push(1)
  r = ?a
  if true
    c: Vec[Int] = Vec()
    !c.push(42)
    !c.push(43)
    l = |?c| c
    g = ?l
    r = g()
  print(r.len, r[0])
```

`rig check` accepts it. `rig run` gives `thread … panic: index out of bounds` from `r.*.at(0)`, reading the freed `c`.

- `r = (?l)()` (`C1b`) and `r = pass(?l)()` (`C1c`) print `0`: a freed Vec.
- `fun bad(a: ?Vec[Int]) -> ?Vec[Int]` whose body is `c = …; l = |?c| c; g = ?l; g()` (`C1d`) returns a dangling borrow of its own local and prints `0`.

The non-aliased form is correctly rejected: `r = call(?l)` gives "`c` does not live long enough". The branch that should cover these is `walkCall`'s callee handling:

```zig
} else if (callee == .src) {
    _ = try self.walkName(callee, true);
    // A stack closure's result may borrow what the closure holds.
    if (self.find(self.text(callee))) |id| {
        if (self.vars.items[id].closure) result = self.varValue(id);
    }
} ... else {
    _ = try self.walk(callee);
}
```

It only handles `closure` vars. A `?fun` local's loans (carried from `lendClosure`) and a call or `?l` callee's value are discarded.

**Fix:** when the callee's type is a borrowed callable (`sema.callableFn`) and `mayCarryBorrow(fn.returns)`, union the callee's walked value into `result`. That means `varValue(id)` for a name, and the value of `walk(callee)` for any other expression.

### C2 detail

```rig
struct View
  w: ?Vec[Int]

sub run(f: ?sub(?Vec[Int]))
  local: Vec[Int] = Vec()
  !local.push(7)
  !local.push(8)
  f(?local)

sub main
  a: Vec[Int] = Vec()
  v = View(w: ?a)
  v = View(w: ?a)      # works around H1 so the Zig compiles
  run(|!v, w|
    v.w = w)
  print(v.w.len)       # prints 0: `local` is freed
```

The named-closure form behaves the same (`C2b`): `set = |!v, w: ?Vec[Int]| v = View(w: w)`, then `set(?local)` in an inner block, then `v.w.len` after the block prints `0`.

In the closure body, `w` is a `.param` with `ref != .none`, so `isLocalLoan` treats its loan as caller-supplied and lets it be stored into a caller-owned place. For a function that is sound, because the call site absorbs argument loans into its `!` arguments. For a closure, the destination is a captured `!v`, which no call site sees: neither `f(?local)` inside `run` nor `set(?local)`. The method-call path `!v.set(w)` is rejected ("`w` does not live long enough"), so only field assignment and whole assignment through the capture leak.

The equivalent code without a closure is rejected: `w = !v; w.w = ?local` in an inner block gives "cannot store a borrow of `local` in `w.w`".

**Fix:** inside a closure body, treat the closure's own parameters' loans as local when the destination root is a capture, in both `walkFieldAssign` and the captured-write `reassign` path. Alternatively, reject storing anything but outer-capture loans through a captured `!x`.

### H1 detail

```rig
fun seed(n: Int) -> Int
  n + 1

sub main
  x = seed(1)
  f = |!x|
    x += 1
  f()
  print(x)
```

Zig fails with `expected type '*i64', found '*const i64'` at `.cap_x = &x`. The same happens for `run(|!x| …)`, for a struct holding a borrow field (`H1b`), and for a `*T` handle.

`|!x|` is the headline use of the feature, as in `each(?v, |!count, n| …)` with a computed `count`. The existing tests all use literal initializers, which are `var` for another reason (`isZigComptimeIn`).

**Fix:** mark the outer symbol written (`markWritten`) when resolving a `cap_write` capture.

### H2 detail

```rig
fun double(n: Int) -> Int
  n * 2

struct View[T]
  w: ?T

fun use_it[T](x: ?T) -> Int
  1

sub main
  print(use_it(?double))
  g: fun(Int) -> Int = double
  v = View(w: ?g)
  h = v.w
  print(h(3))
```

On main this prints `1` and `6`. On the branch, Zig fails with `expected type '*const fn (i64) i64', found 'rig.runtime.FnRef(...)'`. With a stack closure (`use_it(?f)`, `View(w: ?f)`, `lib.peek(?f)` in another module) the branch accepts code that main rejected, and it fails the same way.

It also lets a value hold a borrowed callable (`View[fun…]`, `Opt.some(v: ?g)`), which the design says never happens. That is currently masked by the Zig failure.

**Fix (either):**
- treat `?T` whose `T` is a type parameter as a plain read borrow, and make `callableFn` apply only to a `?fun` written as such. `callOf`/`lend` would then only apply where the declared (unsubstituted) parameter is `?fun(...)`.
- or reject a type parameter bound to a function type where the generic declaration uses `?T`, plus in field and payload positions.

### H3 detail

```rig
sub main
  x = 1
  f = |!x|
    x += 1
  g = |?f| f()
  g()
  g()
  print(x)
```

Zig fails with `expected type 'rig.runtime.FnRef(&.{}[0..0],void)', found '__rig_main.main__struct_…'` at `.cap_f = f`. The same happens with `|?f| run(f)` and `|?f| run(?f)`.

`|?f|` of a `?fun` parameter works (`c5`). Only a named stack closure breaks.

**Fix:** in `writeCapturedBorrow`, when the outer local is a stack closure (or a `fun` value), emit `emitLend(outer, fn_ty)` (`FnRef.of(@TypeOf(f), &f)` or `ofFn`).

### M1 detail

```rig
fun double(n: Int) -> Int
  n * 2

fun inc(n: Int) -> Int
  n + 1

sub set(dst: !fun(Int) -> Int, v: fun(Int) -> Int)
  dst = v

sub main
  g: fun(Int) -> Int = double
  set(!g, inc)
  print(g(1))
```

Main prints `2`. The branch gives 3 errors:
- "a call never changes a closure's environment … write `?fun(Int) -> Int`";
- "cannot assign to parameter `dst`";
- "write `?g`".

The generic `set[T](dst: !T, v: T)` is rejected the same way. A `fun` value is a Copy function pointer, and a write borrow of the *variable* is meaningful.

**Fix:** reject only where the `!` would lend a closure to be called. That means keeping `!fun` legal as a place type (or rejecting it only for stack-closure bindings), and letting `|!g|` capture a `fun`-typed local.

## Clean (attacked, held)

- **Escapes through types.** `Vec[?fun]`, `[N]?fun`, `(?fun)?`, `Cell[?fun]`, `Wrap[?fun]`, a struct field, an enum payload declared `?fun`, and module-level bindings are all rejected. Generic `T` inferred as `?fun` into `Vec[T]`, `Box[T]`, `T?`, or `ident(x: T) -> T` is rejected (with noise, L3).
- **Escapes through scopes.** Reassigning an outer `?fun` local to `?l` of an inner closure is rejected, both directly and through `pass(?l)`, `pickc(?l)` (a stack closure returning its callable), `g: ?fun = ?l`, and a loop body. `return ?l`, `id(?l)`, and `g(?l)` through a `fun` pointer are rejected in a function that was lent nothing. A literal lent to a call whose result holds a callable is rejected. `return ?(|…|)` is rejected.
- **Owned closures.** `*|?x|`, `*|!x|`, `*|?f|`, and `*|<f|` of a callable are rejected. An owned closure cannot take `?fun`. Dropping or reassigning `cb` while `?cb` is lent through a result is rejected.
- **defer and errdefer.** A closure used in `defer`/`errdefer` keeps `|?x|`/`|!x|` loans to scope end: reassign and `-v` are rejected.
- **Liveness.** A write after capture when a later call exists is rejected, including across `for` back-edges. `g = |?f| …` carries `f`'s loans. `new` shadowing keeps the old loans. A closure rebind is rejected (fixed binding). Env drop glue (`|<view|` of a borrow-holding struct with `drop`) keeps loans to scope end, for both typed and untyped bindings. Reading a Copy `Int` between calls of a `|!x|` closure is allowed, consistent with the existing `w = !x; print(x)` rule.
- **Aliasing.** Two literals capturing `!x` in one call. A literal `|!c|` together with `?c`. `walk(!v, ?l)` and `walk(|?v|…, !v)` in either order. `|?v|` plus `<v` in either order, and `|?v|` plus `|<v|`. Method receivers `b.each(|!b|…)`, `!b.grow(|?b|…)`, and `b.each(?add)`. `for x in ?v` while `|!v|` is live. All rejected.
- **Callee-side storage.** A callable storing a captured borrow into its `!View` parameter, whether by assignment, method, or helper, is rejected in the body. A callable's result carries loans into `!` arguments (`fill`) and into call results (`get`), and a callee returning `f(?local)` is rejected.
- **Emit.** These run correctly and leak-free:
  - fallible arguments `may(n)!` before or after a `|<r|` literal: `r` is dropped exactly once on the success and failure paths;
  - argument evaluation order with a hoisted env (`apply2(bump(!k), |+k, a| …)` gives 22);
  - literals in `while` and `if` conditions, `and`/`or` short-circuit, `??`, `match` subject, `return`, `defer`, a conditional expression with `|<c|` on the taken and untaken branch, and `for` bodies;
  - nested literals, recursion forwarding a wrapper literal (`rec(n-1, |?f, +n, k| …)`), and three-level generic forwarding with inner literals;
  - kwargs, paren-free command calls with literals, `?sub()` with no params, `?fun` returning `T!` and `T?`, `?fun(T)` methods on generic types, and cross-module generics and methods;
  - `|!x|` through arrays, slices, optionals, enums, strings, and `*T` handles (old handle dropped), and assigning a resource through `|!r|`;
  - `|?s|` of Cell-holding structs, where changes stay visible.
- **Runtime.** `FnRef.ofClosure` cannot be invalidated during a call. A lent owned closure is only reachable through read paths, and borrowing an element of a Cell's Vec is rejected.
