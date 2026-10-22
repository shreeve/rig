# Audit: brackets branch, ownership soundness of generic functions and methods

Reviewer lens: memory safety and ownership soundness of generic functions and
generic methods (`git diff 6df0c48..brackets`), plus Zig-compile failures of
accepted programs. Binary: the existing `bin/rig` (not rebuilt). Scratch
programs: `/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/C1/`
(abbreviated `$C1` below); minimal repros in `$C1/repro/`.

Every command below is run as

```
RIG_OUT_DIR=$C1/out bin/rig run $C1/repro/<file>.rig
```

(optionally with `RIG_LEAK_TRACE=1`, which uses the DebugAllocator and turns
several silent use-after-frees into segfaults). Each finding was reproduced
twice (plain and with `RIG_LEAK_TRACE=1`, or two separate runs).

## Summary

Two critical soundness holes, both reachable with a few lines of safe Rig,
both reachable through generic functions (one of them only through generic
code). Everything else in the lens — moves, drops on early return and on `!`
propagation, `defer`/`errdefer`, per-instance copy/clone/discard/temporary
requirements through arbitrarily indirect instance chains, borrow-typed type
arguments, loans through generic results — held up.

## Findings

| ID | Severity | Repro path | What happens | Expected | Suspected cause | Fix idea |
|---|---|---|---|---|---|---|
| F2 | **Critical** | `$C1/repro/F2_for_loop_moves_vec_element.rig`, `F2b_for_loop_duplicates_into_vec.rig`, `F2c_generic_type_method.rig` | In a generic body, `for x in v` over a `Vec[T]` (by value, `?Vec[T]`, a borrowed field `?self.items`, or a `!Vec[T]` param iterated without `!`) binds `x: T` as if owned, and `r = <x` / `!out.push(<x)` “moves” the element out while the Vec still owns it. Instantiated with `T = *Res`: F2 prints `drop 1` and then reads `a.n` from the freed box (segfault under `RIG_LEAK_TRACE=1`); F2b panics `reached unreachable code` in `RcBox.dropStrong` (`assert(self.strong > 0)`) on the second drop, with or without leak trace; F2c (generic *type* method, `for x in ?self.items`) segfaults under leak trace. Accepted by `rig check`. | Reject, as the non-generic equivalent is (“resource Vec[T] iteration requires an explicit read borrow” / ``expected `*Res`, got `?*Res` ``), or record a `.plain` requirement at the move so `steal[*Res]` is rejected per instance (as a *copy* `r = x` already is). | `typecheck.elementTypeForLoop` (src/typecheck.zig:1098–1121) decides `is_resource` only for `.shared`/`.weak` elements, so a `type_var` element is typed `T`, not `?T`; `ownership.isResourceVec` (src/ownership.zig:3115–3122) uses `typeHasDropGlue`, which is false for a type var, so `loop_borrow` is not set (src/ownership.zig:2691, 2798) and `moveVar` treats the element as an owned binding. The emitter then writes `const tmp: T = x;` with no ownership transfer (`rig emit`). Pre-existing for generic *types*' methods; generic functions make it far easier to reach. | In ownership, a `.loop_elem` var from a non-`<` loop whose type `maybeDropGlue`s: route `<x` and `-x` through `reportAlias(.generic)` (records a plain requirement) instead of `moveVar`; for concrete owning types keep the existing rejection. Alternatively make `isResourceVec`/`is_resource` also true for `maybeDropGlue` element types and require `for x in ?v` (then `<x` is a type error, as in non-generic code). Add `test/reject/ownership/generic_for_moves_element.rig`. |
| F2d | Medium (sub-case of F2) | `$C1/repro/F2d_drop_loop_elem_ignored.rig` | `sub dropall[T](v: ?Vec[T])` with `for x in v` / `-x` is accepted and the `-x` is emitted as nothing (`for (v.*.items()) \|x\| { _ = &x; }`). The program says “drop now” and nothing is dropped. Violates rule 2 (never drop a construct silently). | Reject (non-generic: “cannot drop loop-borrow alias”), or record a plain requirement. | Same as F2. | Same as F2. |
| F1 | **Critical** (pre-existing, also through generics) | `$C1/repro/F1_if_as_on_borrowed_optional_generic.rig`, `F1e_generic_handle.rig`, `F1b_if_as_on_borrowed_optional_handle.rig`, `F1c_if_as_borrowed_param_nongeneric.rig`, `F1d_while_as_borrowed.rig` | `if o as v` (and `while o as v`) where `o` is a **read borrow** of an optional owning value (`?T?` param, `?Res?` param, or a local `b = ?o`) binds `v` as an owned copy with its own drop. F1 (`fun unwrap[T](o: ?T?, d: T) -> T`, `return v`): output `drop 2 / 1 / drop 1 / drop 1` — `Res 1` dropped twice. F1e (`?(Vec[T])?`): `panic: rig: double free or free of memory that was never allocated`. F1b (`(*Vec[Int])?`): refcount assert in `dropStrong`. F1c/F1d (non-generic `sub peek(o: ?Res?)`, generic `while`): `drop 1` printed twice. | Reject moving out of a borrow (the `??` and `o?` forms already are: “a borrow cannot give up the resource inside it”, and a field `if h.r as x` is rejected), or bind `v` as a borrow of the payload with no drop. In a generic body, record a plain requirement. | `walkIf` (src/ownership.zig:2483–2505) calls `walkConsumed(ir.As.value(cond), .binding)`; `checkNoImplicitCopy` finds no owning kind for a *borrow* type (`?Res?`), so nothing is reported, and `bindNew` makes `v` an owning var; the emitter (`if (rig.borrowed(?T, o)) \|tmp\| { var v = tmp; defer rig.drop(&v); ... }`) duplicates the value. `walkLoop` / `loopIteration` (`cond_binding`, src/ownership.zig:2659–2665, 2770) have the same gap for `while`. Not introduced by this diff, but the new generic functions reach it directly (`?T?` params). | In `walkIf`/`walkWhile` with an `as` condition: if the value's type is a borrow of an optional whose payload `typeHasDropGlue`, reject (“a borrow cannot give up the resource inside it; write `if <m as x` on the owner or read it through the borrow”); if it `maybeDropGlue`s, `reportAlias(.generic)`. Or lower it as a payload borrow (`\|*v\|`, no defer) and type `v` as `?Payload`. Add reject tests for the generic and non-generic forms. |
| F3 | Medium (wrong rejection; new syntax) | `$C1/repro/F3_explicit_instance_unit_variant.rig` | `Opt[Res].nothing` (explicit instance, unit variant of an owning generic enum) is rejected: ``bare use of `Opt` value `Opt[...].nothing` in binding would alias an owning value``; the same in an argument. In a generic body, `Opt[T].nothing` records a *copy* requirement, so `empty[Res]` is rejected with “the generic body copies a `T`”. `ROpt.nothing` and `Opt[Int].nothing` are accepted. SPEC §4 Generic types shows `Option[Int].nothing` as valid. | Accept: a variant constructor is a fresh value. | `checkNoImplicitCopy` (src/ownership.zig:1850–1852) skips `Enum.variant` only when `namesType(object)`; `namesType` (src/ownership.zig:1894–1910) handles `.src` and `module.Type` but not an `.inst` bracket list (`Opt[Res]`). | In `namesType`, return true when `self.isInstance(e)` and the instance is a type (`sema.instanceOf(e) == .type`). Add a behavior test with `Opt[Res].nothing` as binding, argument and in a generic body. |
| F4 | Low (wrong rejection) | `$C1/repro/F4_generic_borrow_arith.rig` | In a generic body, `a + b` with `a: ?T`, `b: ?T`, and `a = a + 1` with `a: !T`, are rejected (``operator `+` requires numeric operands; got `?T` ``), while the concrete `?Int`/`!Int` forms are accepted and auto-deref. | Accept, record the `.numeric` requirement on `T`, and deref (`rig.ReadBorrow(T)` is a value for numbers). | Operand typing in typecheck does not peel a borrow of a `type_var` before the numeric/ordered requirement check. | Peel `?T`/`!T` to `T` in the arithmetic/comparison operand path as for concrete borrows; emit `.*` for `!T`. Not a soundness issue. |
| F5 | Low (diagnostic) | `$C1/repro/F5_misleading_recursion_message.rig` | `type Box[T]` whose method `rewrap(self) -> Box[Box[T]]` calls a generic `keep(...)`: rejected with “a generic function cannot call itself with its own type parameters nested deeper”, though no function calls itself (the growth is through `Box`'s methods being expanded for each deeper `Box` instance). The rejection matches the documented rule for generic types; only the wording is wrong. | Message naming the generic type (as the pure-type version does: “a generic type's body cannot nest itself in its own type arguments”). | `expandInstantiations` picks the function-flavoured message when the chain passes through a function instance. | Choose the message by what started the cycle. |

## Attacks that came up clean

All run with `bin/rig run` (leak-checked) unless noted; files under `$C1/`.

Owning `T` by value, returned, conditional, dropped
- `a if c else b` and `<a if c else <b` with `T = Res` (drop body): the unused branch drops exactly once (a1).
- Early `return <a` / fall-through `<b`, and `fail` via `return E.bad` in `T!` generics; unused params dropped once, in reverse order (a2, i1, ac1 compared line by line with a non-generic twin).
- A generic that holds owning `T`s and fails midway via `mk(<b, bad)!`: moved-in values dropped once, the rest on the failure path (a3, aw1 with `errdefer` and nested generic `f(...)!`).
- `defer`/`errdefer` ordering with owning locals in generic bodies (i1, aw1); `defer sink(?x)` after `x` is returned is rejected as use after move (o1, same as non-generic o2).
- Recursion (`count`, `even`/`odd` mutual recursion, `rec` failing at depth with owning args): each level drops once (p1, be1).
- `Vec[T]` built in a generic from owning `*Res`, `for x in <v` with `break` / early `return <x`, `while !v.pop() as x`: every element dropped exactly once (c1, ad1, an1).
- Parameter reassignment rejected; `new x = <x` works, `new x = x` records a copy requirement (as1, at1).
- Generic methods with own type parameters on plain and generic types: consuming `self`, `!self` swaps, `Box[Res].swapin[Int](...)`, `Tagger.keep[Res](!t, ...)`, shared-handle receivers (q1, ak1).
- Keyword-argument reordering and hoisted fallible/`catch`-returning arguments to a generic call: owned temporaries dropped once on each path (al1).

Per-instance checking (copy / clone / discard / temporary / element reads)
- Copy of `T` reached only indirectly: generic → generic → generic, through a generic method on a plain type, a non-generic method of a generic type, a generic enum method, a closure whose parameter is `T`, recursion, owned and stack closures in `main`, `defer`, `drop` bodies, `test` blocks, `catch` handlers, `??` right side, guards, `while`/`for` headers, array literals, string interpolation, a generic body calling a concrete instance, `keep[Self]` (d1–d3, m1–m9, n1–n3, aa1–aa5, ao1–ao2, aj1, av1–av2, bg1). All rejected per instance with the body note.
- Other copy forms: `Pair(first: x, second: x)`, `[x, x]`, `o: T? = x` twice, returning `b.v` from `?Box[T]`, `match` payload out of `?Opt[T]`, `r = x` in a borrowed loop, `+x` clone of `T`, `v[0]`, `?v[0]`, `v.get(0)`, `v[0] = <x`, `Cell.get`, `c[0]`/`c.get(0)`/`c[0] = <x` on `Cell[Vec[T]]`, `Vec` slicing, `??` and `o?` on `?T?`, discarded/temporary results of `T` (e3, e5–e7, c2, t1–t3, ai1–ai10, f4, s1–s2, u1, bb1). The `Cell.replace` / `Cell[Vec[T]].push/pop` paths run correctly for `*Res` (ai8, ai9).
- Built-in element rules per instance: `Vec[Res]`, `Vec[Vec[Int]]`, `Signal[Res]` (through `mk`, `setv`, `getv`), stack `Signal` in a generic body (a4, af1, h1–h2, ay1–ay3).
- Owned closures in generics: capturing `<x: T` and dropping it with the closure; `*fun() -> T` / `*fun(T)` rejected (ag1–ag4).

Borrows through generics
- `?T` returned from `?Box[T]` / `?Vec[T]` / `!T` and kept across a reassignment, `-owner`, a move, or a second write borrow: rejected (b1–b4, ae1–ae3, k3).
- Borrow stored into a generic struct (`fun wrap[T](x: ?T) -> Box[?T]`, `Box[!T]`) and kept past the owner, or returned from a local: rejected (k1–k2, k4, aq1–aq2). Correct values for `T = Res`, `Int`, and a struct holding a `Cell` (read borrow is a pointer, sees later `set`) (v1).
- `put(!r, ?r)`, `set(!r, <r)`, `f(<r, ?r)`, `g(?s, <s)`, `sw(!v[0], !v[1])`, `sw(!bx.a, !bx.b)`: rejected (j1, ax1, ah1).
- `!v.push(<x)` / `!v.push(x)` receiver sigils inside generic bodies (j3); `!T` params used for write-through (j2, p1).
- Chains of `?T`/`!T`/`?Vec[T]`/`!Vec[T]` through several generic functions for `T = Res`, `Int`, `String`, `*Res` (r1, ar1).

Type arguments that must be rejected
- `?P`, `!P`, `Box[?Res]`, a struct with a `?Res` field, `?Res?`, `*Holder` holding a borrow, `Vec[?Res]`, `[]Int` (inferred and through `keep[?T]` inside another generic), explicit `keep[?Res]`, and a generic method's own parameter bound to a borrow (k5, g1, g1b, l1–l2, y2, z3, bi1). Stack closures cannot be passed (g2). Function values, owned closures, `~T`, `(*Res)?`, arrays, plain enums, error sets, stack `Cell`s, `*Cell`, `*Signal` work as type arguments (g3, g5, y1).
- Type arguments of a generic type's associated generic function (`Box.twice2(Res(...), 3)`) are checked against the type's body (z1–z2).

Zig compilation of accepted programs
- No Zig compile error was produced by any accepted program in this audit: explicit brackets, `sub show[T]` with no parentheses, mixed type and value parameters (`rep[*Res, 2]`), unused type parameters, `T?`, `T!`, nested instances (`Box[Box[T]]`), `?Vec[T?]`, generic methods called through the type with the receiver first, deep generic chains (af1, bd1, p1, ar1, y1).

Cross-module
- A private generic function used by a public generic type's method is unreachable from an importer because generic types cannot cross modules, and `lib.Box[...]` does not parse in a type position; no instance escapes the checking module (x1).
