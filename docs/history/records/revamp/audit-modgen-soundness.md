# Audit: generics across modules — soundness lens

Branch `modules-generics` (HEAD 2df2827), `git diff main..modules-generics`,
checked with the existing `bin/rig` (built 03:59, after the last `src/`
change). Scratch repros live under
`/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R11a/`
(called `$R` below); each was run with `RIG_OUT_DIR=$R/out/<name>`, and each
finding was reproduced twice.

About 90 multi-module programs were written against the new feature. The
proxy and import machinery held up under every requirement kind, chains,
diamonds, type identity, ownership, and drop-glue attack below. One new
wrong accept was found, in emit. Three older wrong accepts turned up along
the way. They are listed apart because the branch did not introduce them,
though one of them now shows up on a cross-module path too.

## Findings

| # | Severity | Kind | Introduced by this diff? | Repro | Summary |
|---|---|---|---|---|---|
| F1 | **High** | wrong accept (Zig compile error) | **yes** (emit.zig:2557) | `$R/F1_const_method/` | A method call on a module constant whose type is another module's generic enum (`lib.NONE.is_none()`) is emitted as a call through the *type*: `lib.Opt(i64).is_none()` |
| P1 | High (pre-existing) | wrong accept (Zig error, or an internal emit error) | no; the cross-module form is new | `$R/P1_oversized_generic_arg/`, `$R/P1_oversized_generic_arg_local/` | An array literal over 8 MiB, passed where a generic call infers its type, is poisoned with no diagnostic |
| P2 | Medium (pre-existing) | wrong accept (Zig compile error) | no | `$R/P2_unused_type_param/` | A generic enum that names its type parameter only as `Tag[T]` (emitted as `Self`) gets no `_ = T;`: "unused function parameter" |
| P3 | Medium (pre-existing) | wrong accept (Zig compile error) | no | `$R/P3_borrowed_owned_closure_call/` | Calling an owned closure through a read borrow (`c.peek()()`) skips the deref: `c.peek().value.invoke(...)` |

### F1 — a method call on a foreign generic-enum constant is emitted as a call through the type

`$R/F1_const_method/lib.rig`:

```rig
pub enum Opt[T]
  some(value: T)
  none

  fun is_none(?self) -> Bool
    match self
      .some(value) => false
      .none => true

pub NONE: Opt[Int] =! .none
```

`$R/F1_const_method/main.rig`:

```rig
use lib

sub main()
  print(lib.NONE.is_none())
```

Output (both runs):

```
$ bin/rig check main.rig      # exit 0
$ bin/rig run main.rig
.../out/F1_const_method/__rig_main.zig:11:30: error: expected 1 argument(s), found 0
    rig.print(.{ lib.Opt(i64).is_none() });
```

Variants that fail the same way:
- `$R/r1`: `lib.DEF.or(5)` gives "expected 2 argument(s), found 1".
- `$R/r7`: a constant declared in a second module, `a.D.or(1)`, gives `@import("lib.zig").Opt(i64).@"or"(1)`.
- `$R/t1`: keyword arguments, which go through the hoisted-call path: `lib.Opt(i64).pick(__rig_arg_1_1, __rig_arg_1_0)`.

Controls that pass:
- the same program in one module (`$R/r1l`) prints `5 true`;
- a non-generic enum constant across modules (`$R/r1n`, `$R/t1` first half) runs;
- other uses of the constant (`x = lib.DEF`, `match lib.ONE`, `lib.Box(v: lib.DEF)`, `$R/r2`) run.

**Cause.** The new branch in `emitMemberBase` (src/emit.zig:2556–2557):

```zig
// `m.Wrap.make(...)` of another module's generic type.
if (o.isKind(.member) and self.isTypeCallee(o)) if (obj_ty) |t| if (self.sema.types.get(t) == .parameterized_nominal) return self.emitTypeTy(t);
```

For a member, `isTypeCallee` (emit.zig:2895) returns true whenever the
member's object is a module. It does not check whether the member names a
type or a value. A module constant of type `lib.Opt[Int]` is a
`parameterized_nominal` value, so the receiver is replaced by the type.

**Fix.** Take the branch only when the member names a generic type:
- look up `ir.Member.name(o)` in the module's `foreign_semas` entry and require `.generic_type`; or
- have typecheck record `instance_of = .type` on the `lib.Wrap` member node, as it does for `Pair[Int, String]`, and drop this line so the existing `instanceOf(o)` branch handles it.

Narrowing `isTypeCallee` itself for members, to "names a type in that
module", would also harden its other callers (emit.zig:2505, 2889, 2952,
2996). Those callers currently treat any `mod.X` as a type.

Suggested tests:
- `test/behavior/modules/generic_enum_constant/`: `lib.NONE.is_none()`, a method with arguments, and one with keyword arguments.
- the same through a second module (`a.D.or(1)`).

### P1 — an oversized argument to an inferring generic call is poisoned with no diagnostic (pre-existing)

`$R/P1_oversized_generic_arg_local/main.rig`, a single file with no modules:

```rig
struct Big
  a: [530000]Int

fun first[T](x: T) -> Int
  1

sub main()
  print(first([Big(a: [0; 530000]), Big(a: [0; 530000])]))
```

`rig check` exits 0, then Zig fails:
`first([_]Big{ ... })`: "expected 2 argument(s), found 1", because the type argument is missing.

The generic-constructor form `Wrap(v: [Big, Big])` in one file (`$R/m3`)
fails earlier, inside the emitter: "internal error: cannot emit an untyped
generic constructor (sema should have rejected it)". Across modules
(`$R/P1_oversized_generic_arg/`), the emitter falls through the new
`parameterized_nominal` constructor branch, because the call has no type, and
Zig reports "expected type 'type', found '[2]__rig_main.Big'". Binding the
same literal directly (`x = [Big(..), Big(..)]`) is correctly rejected:
"`[2]Big` takes 8480000 bytes".

**Cause.**
1. `argType` (typecheck.zig:3806–3815) synthesizes the argument with `synthQuiet`, which truncates the diagnostics.
2. `sema.reportOversized` (sema.zig ~2138) has already put the type into `ctx.oversized`.
3. The real check then hits the `ctx.oversized.contains(ty)` early return in `checkArrayBytes` (sema.zig ~2124), which returns false with no new diagnostic.
4. The argument becomes invalid and no error remains.

The frame check (`frameBytes`, typecheck.zig ~6005) also skips any value over
8 MiB, on the assumption that it was reported.

**Fix.** Do not record into `oversized` while `self.tentative > 0`, or skip `checkArrayBytes` in tentative synthesis. More generally, make `synthQuiet` roll back `oversized` along with the diagnostics.

### P2 — a generic enum whose parameter appears only as `Tag[T]` (pre-existing)

```rig
enum Tag[T]
  on
  off

  fun flip(?self) -> Tag[T]
    .on

sub main()
  t: Tag[Int] = .off
  print(t.flip() == .on)
```

`rig check` exits 0. Zig then reports `pub fn Tag(comptime T: type) type`:
"unused function parameter".

`emitGenericHead` (emit.zig:468–472) decides whether to write `_ = T;` from a
syntactic mention (`mentions`). `Tag[T]` mentions `T`, but it is emitted as
`Self` (`isSelfInstance`), so nothing in the Zig uses `T`. The same failure
appears through `lib.rig` (`$R/r8`, first version).

**Fix.** Do not count a mention inside an instance that `isSelfInstance` rewrites to `Self`. Alternatively, emit `_ = T;` from the emitted text rather than the source.

### P3 — calling an owned closure through a read borrow (pre-existing)

```rig
struct Hold
  v: *fun() -> Int

  fun peek(?self) -> ?*fun() -> Int
    ?self.v

sub main()
  c = Hold(v: *|| 5)
  print(c.peek()())
```

`rig check` exits 0. Zig then reports that `*const *rig.runtime.RcBox(...)`
"does not support field access" at `c.peek().value.invoke(.{})`. The
"owned closure handle" path in `emitCallDirect` (emit.zig ~2711) does not
dereference a borrowed handle. It was found through a generic in `$R/g3l`
(`Hold[T]`), but it does not depend on generics.

## Attacks that came back clean

Every item below was run. Accepted programs ran leak-free in Debug with the
correct output. Rejections came with the right `file:line:col` and, where
relevant, a note in the other module's file.

**1. Requirement kinds imported and checked** (`a1`, `a2`, `a6`, `a7`, `k3`, `j3`, `g4`, `r6`, `n3`, `q2`)
- plain copy (`a = x`), with the note in lib.rig;
- element-take (`for x in ?v` then `<x`);
- `==`, `<`, arithmetic, `fits` (`x + 300` with `U8`);
- `float` (`x * 0.5` with `Int`), `signed`, `integer` (`&` with `Float`), `shift` (`<< 40` with `I32`);
- `array_len` (`lib.arr[-1]`, `lib.Ring[Int, 99999999999]`);
- the 8 MiB value cap (`lib.Ring[Int, 2000000]`, and a chain-only `lib.ring[Int, 2000000]`);
- the 16 MiB frame cap (a function, a type's method over `T`, a type's method over `n`);
- closure copies (`|+x|`);
- builtin element rules reached in a generic body (`Cell[Pt]`, `Vec[Owner]`, `Signal[Pt]`, `[2]*Int`, `[<x; 1]`);
- a generic method's own `U`, called through a value and through the type (`lib.Wrap[Int].conv[String]`).

**2. Owning type arguments** (`a1`, `a2`, `g3`, `d4`, `h3`, `h7`, `r4`, `l4`, `q2`)
- Types: `Vec[Int]`, a struct with `drop`, `*T`, `~T`, owned closures, `a.Res` from a third module.
- Every copy is rejected. Moves, drops, `self: Self` consumption, and enum payload moves (`.some(value) => <value`) run leak-free, with drop order matching the one-file version.
- A foreign instance holding a `Vec` or a private `drop` type runs its glue.
- Bare aliasing of a foreign instance with glue is rejected.

**3. Chains and diamonds** (`a3`, `a4`, `a5`, `g1`, `g2`, `l1`, `n2`, `s4`, `q1`)
- main → lib → util, where util's `>`, `==`, or copy is violated only by main's argument.
- The same through a generic type field (`lib.Wrap[T]` holding `util.Cell2[T]`), a constructor-only path, and a borrow argument made inside lib (`util.g(?x)`).
- A private helper sized by a forwarded `n`.
- A 4-deep chain main → a → b → c → d.
- A diamond where only one path violates.
- A `Bool` compile-time parameter forwarded alongside `T`.
- Each error names the right instance and "made by" chain, with the note in the right file.

**4. Type identity** (`b1`, `b2`, `h6`, `n6`, `s1`, `r8`, `s8`)
- The same `lib.Wrap[Int]` made in main, in a second module, and in lib, passed between all three.
- `Vec[lib.Wrap[Int]]` built in `a` and pushed to in main.
- `lib.Wrap[lib.Wrap[Int]]` and `*lib.Wrap[Int]`.
- Aliases of foreign instances, in main and as `pub type` in lib.
- `?`, `T?`, `*`, `[]`, `[2]`, `fun(...)`, and `T!` wrappers.
- A generic enum from lib matched in main, printing, and `== .variant`.
- `lib.Ring[Int, 2 + 2]` against `lib.Ring[Int, 4]` against `lib.Ring[Int, N]` against a local `k =! 4`.
- `a.Wrap` and `b.Wrap` stay distinct types.

**5. Proxies and positions** (`c1`, `l3`, `h5`, `m1`)
- No path records a proxy as a name, so the `decl_pos` comparisons (emit.zig:1013, 3801; ownership.zig:994, 1379, `symbolAt`) never see one. Code audit and runs agree.
- Declared-here, missing-field, and no-field notes on proxies point into lib.rig.
- Unused-local checks ignore proxies, since they are not `.local`.
- `checkInfiniteTypes` catches `Node { next: lib.Wrap[Node] }`, `lib.Two[Node]`, and `lib.Opt[List]`.
- `computeTypeInfo` reads only `contents`, which is set before the memo entry, so a partly imported proxy never caches wrong facts.

**6. Ownership across modules** (`d1`–`d5`, `r5`, `n5`)
- Borrows returned from foreign generics (`lib.first(?v)`, `lib.pick(?a, ?b)`, `lib.inner(?w)`, `lib.pairs`, `lib.view`), including through a local wrapper function, block a later mutation, drop, or move.
- The same for borrow-holding foreign structs (`lib.Pair(first: ?r)`, `lib.View`).
- `!T`/`?T` method results on `lib.Bag[P]` conflict correctly.
- Fallible foreign generics (`T!`) propagate in main and drop the argument on the error path.
- `*Cell[lib.Holder[Vec[Int]]]` with `set` and `replace`, and `Cell.get` of a glue type rejected.
- Receiver sigils `!b.push`, `!b.grow`, `<b.done()`, and a consuming method on a temporary.

**7. Emit** (`c1`, `c2`, `c3`, `h1`, `i_*`, `k_*`, `k2`, `o2`, `o3`, `p2`, `e1`, `e2`, `s6`)
- `@import("util.zig")` for a module reached only transitively, including a module named `fn`.
- main and lib both declaring `Wrap`.
- A local or type parameter named `lib` is rejected.
- Modules named `rig`, `std`, `builtin`, `root`, `panic`, `fn`, `var`, `comptime`, and generic types named `i64`, `u8`, `anyopaque`, `f32`, `usize`.
- A method named `lib` or `W`, which gives `__rig_module.lib.W(i64)`.
- `lib.Wrap[Int].make(1)` and `lib.Wrap.make(2.5)`.
- Hoisted constructors and calls whose arguments propagate (`lib.Two(a: Res, b: num(ok)!)`), leak-free on both paths.
- Keyword-argument reordering keeps evaluation order.
- Literal and `.variant` defaults come from lib's source.
- Mixed compile-time parameter kinds (`Mode`, `String`, `Bool`, `U8`).
- `--release`, `--release=fast`, and `rig test`.

**8. Visibility and self-nesting** (`q3`, `h4`, `j1`, `j2`, `o1`)
- A private `lib.Hidden` or `lib.helper` cannot be named, but works when held through a `pub` function, including generic methods of a private type.
- A self-nesting generic method of a private type is caught at main's call.
- The `pub` self-nesting check gives no false positives on a stack `map[U]`, a linked `Node[T]`, `Pair.swap`, `Wrap.twin`, mutual `even`/`odd`, or `Grid[T, n]`.
- It agrees with the one-file behaviour on `nest` and `unnest`.
