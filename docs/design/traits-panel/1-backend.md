# Traits for Rig: backend and dispatch (panel 1)

Grounded in origin/main 59a8c9a18: INTERNALS "Generics", "Emit" (generic
functions, closures, inlining), `src/runtime.zig` (`FnRef`, `Closure`,
`Box`, `Shared`, `hash`), DESIGN "Cost model", and `bin/rig emit` on
small programs written for the review.

## What today's output tells us

- A generic is a Zig generic: `fun biggest[T](a: T, b: T)` is
  `fn biggest(comptime T: type, ...)`, called `biggest(i64, 3, 4)`. Zig
  makes one instance per argument list; emit writes one body per Rig body.
  The inlining rule never inlines a function with type parameters (only
  `inline fun` does); LLVM may still.
- A generic body cannot call a method on `T` at all (typecheck: "a
  generic parameter `T` has no methods"). `.hash()`, `==`, ordering and
  printing reach `T` only through runtime reflection (`rig.hash`,
  `rig.eql`, `rig.compare`), which dispatches on `@typeInfo` at compile
  time. So a bound that names user methods is the first time a generic
  body calls user code on `T`: the backend work is real but small.
- `?fun(A) -> R` is already a trait object of one method: `FnRef` is a
  16-byte fat value `{ctx, call_fn}`, built by `.of(Env, &env)`,
  `.ofFn(f)`, `.ofClosure(h)`, called `f.call(.{x})`.
- `*fun(A) -> R` is `*Shared(Closure)`: a counted handle to a struct
  holding `{ctx, invoke_fn, drop_fn}`, with the environment a second
  allocation. Its "vtable" is inline in the value, and it costs two
  allocations and two dependent loads per call.
- `^T` is `Box(T){ value: *T }`, a thin pointer; `Shared(T)` is
  `{strong, weak, value}` in Zig's auto layout, with atomic counts only
  when `synchronized(T)`.

## 1. Static dispatch: what a bound adds to emit

Sketch:

```rig
trait Shape
  fun area(?@) -> Float

obj Circle impl Shape
  r: Float
  fun area(?@) -> Float
    3.14 * @r * @r

fun total[T: Shape](xs: ?List[T]) -> Float
  t = 0.0
  for x in xs
    t += x.area()
  t
```

**Option A, by name.** Emit `x.area()` as written; Zig resolves `T.area`
per instance. Zero new emit. Breaks as soon as an impl lives outside the
type (an impl for `Int` or `String`, which are `i64` and `rig.String` and
have no decls of Rig's), and when two traits give one type methods of the
same name.

**Option B, a comptime lookup.** `rig.implOf(Shape, T).area(x)`, a
registry Zig searches at compile time. Needs a program-wide table of
impls in the runtime, across modules Zig does not see as a set. Fragile.

**Option C, a witness parameter (recommended).** Each bound is one more
`comptime` parameter, after the type it bounds; sema already knows the
impl at every call (it is checking it), so emit writes the impl's name:

```zig
pub fn total(comptime T: type, comptime W_T_Shape: type,
             xs: *const rig.List(T)) f64 { ... W_T_Shape.area(x) ... }
// call: total(Circle, Circle, &cs)              impl in the type itself
// call: total(i64, __rig_impl_Shape_Int, &ns)   impl declared apart
```

The witness for an impl declared on the type is the type itself; one
declared apart is a module-level struct `__rig_impl_<Trait>_<Type>`.
Instances stay 1:1 with today's (W is a function of T), so code size is
unchanged. Compile time drops slightly: the body is checked once against
the trait, and per instance only "an impl exists" is checked, instead of
re-checking each operation. The receiver lowers uniformly because the
trait fixes each method's self mode and `?T` is `rig.ReadView(T)`, which
applies the same rule (`lendByValue`) as the impl's own `?@` parameter.
So an impl must match the trait's modes exactly, and its `from`/`keeps`
may be no wider than the trait's: the ownership checker reads the trait,
and the vtable thunks below have one signature.

Marker bounds over built-in capabilities (`[K: Hash]`, `[T: Copy]`,
`[T: Ord]`) need no witness and no emit change at all: they are today's
`Requirement` records written into the signature, still lowered through
`rig.hash`/`rig.eql`/`rig.compare`.

**Default:** C, from the first release that has user traits.

## 2. Dynamic dispatch: representation and cost

**Option A, fat pointer (recommended).** A trait object is
`{ptr, vt: *const VTable}`, 16 bytes, by value. The vtable is a static
`const` per (trait, type), built at comptime from the witness, and Zig's
lazy analysis makes one only where a coercion to that trait object is
written.

| Rig | Zig | made from | notes |
|---|---|---|---|
| `?dyn Shape` | `rig.DynRef(Shape_VT)` `{ptr: *const anyopaque, vt}` | `?c` where expected | like `FnRef.of` |
| `!dyn Shape` | `{ptr: *anyopaque, vt}` | `!c` | |
| `^dyn Shape` | `rig.DynBox(Shape_VT)` | `^Circle` moved in: pointer reused, no allocation | `vt.drop` drops fields and frees with the type's size and align |
| `*dyn Shape` | `{shared: *anyopaque, vt}` | `*Circle` moved in | `vt.clone_strong`, `vt.drop_strong`, `vt.value`: `Shared`'s auto layout and per-`T` atomic counts are not readable without `T` |
| `~dyn Shape` | later | | |

VTable: one thunk per method (erases self: `*const anyopaque` to
`*const T`, then calls `W.m`), then `drop`, `clone_strong`/`drop_strong`/
`value` for the handle forms, and `print` (the type's name, as
`<closure>` is printed today). Thunks are required anyway: Zig cannot
take the address of an `inline fn`, and the rule writes small methods
`inline`. The thunk calls the method, so the method stays inlinable
everywhere, and inlines into its thunk.

**Option B, embedded vptr (C++).** Thin pointers, but every value of an
impl type carries a pointer, which changes the layout of plain data,
breaks bit copies, `==` and `.hash()` by fields, and closes impls at the
type's declaration. A cost where no sigil is: rejected.

**Option C, no trait objects; closed sets as enums.** An enum with
payloads, a `match` per method: no allocation, values inline, often
faster than a vtable. Already works.

**Per-call cost.** A direct or static call costs nothing beyond a call
and is usually inlined. A dynamic call is one load of the slot from a
vtable in cache plus an indirect call: a few cycles predicted, but it
ends inlining, constant propagation and vectorization across the call.
That is today's `?fun` call cost; today's `*fun` call adds a load. A
drop of `^dyn` is always an indirect call, even for plain data, since the
type is gone (`needsDrop` is true for every trait object).

**Object safety**, from the trait's declaration: no compile-time
parameters on a method, `Self` only as the receiver, a result that views
self only when its type does not name `Self`. A `<@` method through
`^dyn` is lowered as a thunk that moves the value out, frees the box, and
calls the impl.

**Does Rig need it now?** No. Enums cover closed sets, a struct of `*fun`
fields is a hand-written vtable, and `?fun` covers one method. Open,
cross-module sets (HTTP handlers, widgets, plugins) want it later.
Declare traits now so a vtable can be derived from them unchanged.

**Default:** A, fat pointer, as a later phase; views and boxes before
counted handles.

## 3. Keeping dispatch visible

- **IR and facts.** One fact per method call, `dispatchOf(call)`:
  `direct` (a known type's method), `static {param, trait, method}`
  (through a bound), `dynamic {trait, slot}`. Emit reads it through
  `Facts`, never by name. `rig check --facts=sema` prints it:
  `dispatch call 16:10 "x.area()" static Shape.area on T`. The coercion
  that erases a type is a lend-table row (`lends ... dyn Shape`), written
  in one place (`emitLend`), as `FnRef` is today.
- **In `rig emit`.** Static: `W_T_Shape.area(x)`. Dynamic:
  `s.vt.area(s.ptr)`. Direct: `x.area()`. Three shapes, readable at a
  glance.
- **At the call site.** Options: (a) nothing, the type says it; (b) a call
  sigil for dynamic calls; (c) a word in the type, `?dyn Shape`.
  `?fun` calls show nothing at the call today, and "the costs are where
  the sigils are" puts the cost at the erasure. A bare `?Shape` reads as
  a concrete type (Rust dropped bare trait objects for this reason).
  **Default:** (c): calls look like every call; the type carries `dyn`
  (or `Dyn[Shape]` as a built-in generic, if the syntax panel prefers
  no new keyword); the erasure is a recorded lend.

## 4. Tasks, SIMD, inlining

- **Tasks.** Erasure hides `moves`/`shares`. Options: (a) a trait object
  never crosses, as a function does not today; (b) the trait declares it
  (`trait Job moves`), checked at each impl; (c) the type says it
  (`^dyn Job moves`), checked at each coercion, where the concrete type is
  known. The vtable is a static `const`, valid on every thread, so the
  representation is not the problem. `*dyn` never crosses (non-atomic
  counts) unless `T` is synchronized, which also is hidden.
  **Default:** (a) first; then (c) for `^dyn`, the job-queue and
  actor-message case.
- **SIMD.** Static bounds keep vector code: the witness call inlines and
  `@Vector` operations stay per lane type. Dynamic calls block
  vectorizing loops that call them; passing `Simd[T, n]` through a
  function pointer is fine in Zig. Advise static bounds in numeric code;
  no rule needed.
- **Inlining.** Unchanged for static dispatch: generic functions follow
  today's rule, impl methods are ordinary methods. Vtable thunks are
  plain `fn`, never `inline`; LLVM can devirtualize a local coercion
  followed by a call.

## 5. Side note: owned closures

`*dyn` as designed is one allocation (`Shared(Env)`) plus a static
vtable; today's `*fun` is two allocations with an inline three-word
table. Once `*dyn` exists, `*fun` could be lowered the same way.

## 6. Phased plan, least risk first

1. **Marker bounds over built-in capabilities** (`[K: Hash]`,
   `[T: Copy]`, `[T: Ord]`, `[T: Eq]`): sema only, zero emit change; turns
   today's unwritten requirements into a signature contract (DESIGN's
   stated cost). Std adopts them (`hash.Map[K: Hash, V]`).
2. **User traits with static dispatch**: `trait`, impls declared on the
   type in its own module, `[T: Trait]` bounds, the `dispatch` fact,
   witness parameters. Impls for foreign or built-in types come with
   coherence rules (the trait's or the type's module).
3. **`?dyn`, `!dyn`, `^dyn`**: fat pointers, static vtables, object
   safety, never crossing tasks.
4. **`*dyn`** and `^dyn ... moves` for tasks; then reconsider `*fun`'s
   lowering, and `~dyn`.
