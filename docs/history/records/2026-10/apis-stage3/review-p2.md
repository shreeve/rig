# APIs Stage 3, phase 2: adversarial review (2026-10-23)

A review of PR #584 ([phase2-notes.md](phase2-notes.md)): calls through a
bound, witnesses, defaults, additions lowered, error sets through a
bound, dispatch facts, ownership by the API's clauses, and the oracle's
lowering. It hunted North Star 1 and 2: a program `rig check` accepts
that then fails in Zig, crashes, leaks, or misbehaves under
`RIG_SANITIZE=1`, and a construct silently dropped. 89 probe programs,
each run with `rig check` and, when accepted, `RIG_SANITIZE=1 rig run` on
a self-check build, several compared with `rig emit`, `--facts=sema`, the
oracle (`bin/rig-oracle`), and `main`'s compiler. Each fix has its case
in `test/rig/types-apis.rig.test`.

The earlier attempt's two failures, a `!@` self passed as a copy and a
`?@` result viewing a local copy, do not recur: self goes by its sigil,
as the dispatch fact says, through `rig.selfArg`, whose pointer or copy
is the one `rig.ReadView` makes for the method's own declaration.

## Findings, by severity

### High: accepted, then failed in Zig

1. **Two witnesses of one name.** A type providing a local `Shape` and an
   imported `geo.Shape` wrote `__rig_impl_Shape_Sq` twice; the types
   `geo_Circle` and `geo.Circle` both wrote `__rig_impl_Shape_geo_Circle`;
   and `[T: Shape + geo.Shape]` declared `W_T_Shape` twice. *Fixed:* the
   names are made in one place each (`sema.witnessName`,
   `sema.witnessParamName`, which `--facts=sema` and emit share), and two
   that would be the same are told apart by their place
   (`__rig_impl_Shape_Sq_1`, `W_T_Shape_1`); every other name is as
   before. Case "apis own witness names".
2. **A type parameter with no bound met a bound by an API.** `Bag[U]` in
   `obj Holder[U]`, `-> Bag[T]` in `make[T]`, and `total(x)` in
   `outer[T]` were left to each instance, as Stage 1 leaves an unbounded
   `T`; but the body has no witness to pass, so emit stopped with an
   internal error or Zig found an argument missing (`main` ran these
   only because phase 1 wrote no witnesses). *Fixed:* `checkBounds`
   reports it where the body names it, with the fix `give it the bound:
   [U: Shape]`. Phase 6's implied bounds may later write the bound for
   the reader. Case "apis own unbounded meets a bound".
3. **A generic type with a compile-time value parameter** that provides
   an API on its header (`obj Grid[n: Int, T: Shape]: Shape`) wrote its
   witness `fn __rig_impl_Shape_Grid(comptime n: type, ...)`. *Fixed:* a
   value parameter takes its type, as the type's own function does. Case
   "apis own value parameter witness".
4. **An addition giving several APIs** (`add Wrap[T: Shape]: Shape +
   Region`) wrote in its first witness only the first API's methods, and
   the second witness named `name`, which only `Region` declares, there.
   *Fixed:* the first witness holds every method of the addition
   (decision 1 as written). Case "apis own addition of several APIs".

### Low

5. **Decision 9 rejected a parameter named `_`,** which SPEC allows any
   function for a parameter its body ignores. *Fixed:* `_` on either side
   meets any name; a call through the API still passes the API's names.
   Case "apis own ignored parameter".

### Found, not phase 2's (parked)

6. **High, Stage 1:** a body with an unbounded `T` that stores a
   parameter's view in an owned `x: T` through the instance's `keeps`
   method, then moves `x` into the caller's `!List[T]`, hands the caller
   a view its signature never declared; the caller drops the string and
   reads freed memory (`main` does the same). The call through a bound is
   rejected for this (decision 8, below). Case "type param method stores
   through an owned value" (`known: true`, `ownership-generic`), and a
   backlog entry.
7. **Low:** `c.describe()` on a `^Square` box says "no method `describe`
   on type `Square`", though `b.area()`, the type's own, works through the
   box; whether the shorthand sees through a box is a design point.
   Backlog.
8. **Low, Stage 2:** `if ?o as v` on a `?T?` in a body bounded by any API
   asks for `Copy`, as `main` does for `[T: Print]`.
9. **Low:** `f(?fz)` on a `*Frozen[Square]` infers `T` as the handle, which
   provides no API; `f[Square](?fz)` works, as the design describes.

## Decisions 8 and 9, checked

- **Decision 8** (no view stored through a bound in a `T` the body owns)
  is broader than needed for a parameter's view in a value the body then
  drops (`x = <w; !x.watch(s); x.n()` is rejected, and is safe), but the
  body tracks no view a `T` holds, so the same value moved into the
  caller's list would smuggle the view out (finding 6 is exactly that
  hole without the bound). The rejection is right; narrowing it needs
  views tracked through a `T`, a design change. Storing into the caller's
  value with `keeps` declared, and its rejection without, both hold.
- **Decision 9** (an implementation uses the API's names) rejected no
  sane program but `_` (finding 5): keyword calls through the bound and
  by name (`x.scale(m: 1, k: 10)`, `Sz.scale(One(n: 3), m: 2, k: 1)`)
  pass by the API's names.

## Probed without findings

Self by its sigil through a bound: `!@` changes seen by the caller,
through nested generics, a field of `!@`, `!o.items[i]`, `for x in !xs`,
`if !o as v`, a closure capturing `!x`, a re-lent write view (`v = !x`,
`w = !v`), a `Table` slot, a fixed array element, and a `Map` value from
`ensure`; small (copied) and large (by address) types. `?@` results
`from @` used after the call, by default, by name, and on a small type;
views of temporaries rejected past their statement; `<@` through a bound,
by name, in a loop, and by a default (no double drop, no leak). Defaults
calling required methods and other defaults, overridden, recursive, and
mutually recursive with the type's method; supertraits through a
sub-API bound and a diamond. Additions to `Int` (with `!@`), `String`
(each sigil), `List[T]`, `List[T: Shape]` nested, `Map`, `Set`, `Float`,
an enum, and another module's type; a module that calls a bounded
generic with a type whose addition lives in a module it never imports.
Witness-carrying types: two instances in one program, nested three deep
inside a bounded body, across modules, as a `List` element, `Map` value
and key, `Set` element, `Table` slot, a field of a plain object, with
derived `Print`, `Eq`, and `Hash`, and a method passing `@` to a bounded
generic (a witness naming its own type). Error sets through a bound:
fields (a `String` among them) through `catch |e|`, `!` into a wider
union, a default that fails, a task's wait (`task.Stop` joined), a
fallible `sub` with `!@`, exhaustiveness without `_`, and `T!`. API
methods' own compile-time parameters (a type, a value, a set) through a
bound and by name; `Self` in parameters and results; keyword arguments;
ambiguity; actors (a state type's API called in the actor's method, a
handle rejected as `T`); tasks through a witness with each sigil, local
and crossing, and a write-lent task rejected from `Tasks.add`; `*Frozen`
passed as `?T`. The oracle decided every probe's functions it decides
without disagreeing; emit's choices read from facts (`dispatch`,
`generic_calls` witnesses, `type_witnesses`, the slot), and `rig emit`
reads as the design says.
