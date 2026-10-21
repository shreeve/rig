# Traits panel 2: adversarial soundness review

Read against origin/main 59a8c9a18 (SPEC "Generic bodies", "Second-class views", "How long a loan
lasts", §11 closures, §18 task table and actors, §5 `hash`), and the three panel-1 reports. Checks
were made with `bin/rig check` on small programs. One fact found there: inside a generic body, `+x` with
`T = ?List[Int]` copies the view (the loan stays), although `+s` of a `?String` outside one makes a
`String`. So `Clone` on a view type is "copy the view". That is consistent, but the spec should say it.

Holes are listed most severe first. Each has a sketch, why it breaks, and the rule that fixes it.

## A. Unsound as proposed

**A1. Assigning through `!dyn Tr` writes the wrong type.** (ownership Q3, backend §2)

```rig
sub swap_in(w: !dyn Shape, c: Circle)
  w = c            # w may view a Square
```

A write view assigns today (CORE sentence 1). When the type is erased, the assignment writes a
Circle into a Square's storage. A swap of two `!dyn` views does the same.
**Rule:** through `!dyn Tr` a program may only call methods. Assigning, swapping, and moving out are
rejected. `!b` of a `b: ^dyn Tr` may still replace the whole box.

**A2. `?X` meets a "read-only" trait, but the trait returns `Self`.** (ownership Q2(a))

```rig
trait Join
  fun join(?@, o: ?Self) -> Self
fun both[T: Join](a: T, b: T) -> T
  a.join(?b)
both(?x, ?y)       # T = ?X; X.join builds a new X, which comes back as a ?X of a temporary
```

Every method takes `?@`, so the trait passes Q2(a), yet the result is a view of a dead value. A
static method (`fun default() -> Self`) breaks the same way.
**Rule:** `?X` meets `Tr` only if every method of `Tr`, its supertraits, and its default methods has
a `?@` self, and `Self` appears only as `@` or under `?`. This is the object-safety test plus "reads
only". Phase 1 may take Q2(b) (a view meets only marker bounds) and add (a) later.

**A3. `keeps` is compared by name, not by position.**

```rig
trait W
  sub watch(!@, s: ?String, t: ?String) keeps s
impl W for X
  sub watch(!@, t: ?String, s: ?String) keeps s     # keeps the trait's second parameter
```

Read by name, the impl's clause is a subset of the trait's. Read by position, it keeps the
parameter the trait ends at the call. A dynamic call would then free `t`'s loan early.
**Rule:** compare `from` and `keeps` by parameter position. The oracle's C10 does the same.

**A4. Converting `^Tr` to `^(Tr + Owned)` hides a loan.**

```rig
b: ^dyn Watcher = ^<Plain()
!b.watch(?t)                      # trait says keeps s: b now carries t's loan
c: ^dyn (Watcher + Owned) = <b    # then into a Cell
```

**Rule:** marker bounds on an object are set only where a concrete type is erased. They never widen
from one object type to another. Upcasting to fewer bounds is fine.

**A5. Marker supertraits do not carry over to every object form.** `trait T: Copy` must not make
`^dyn T` Copy, since a bit copy of a box is a double free. `trait J: Moves` does not make `*dyn J`
move, since its count is not atomic.
**Rule:** a supertrait marker describes the hidden type. Each object form takes its facts from the
kind table (`?dyn` copies; `^dyn` moves when the hidden type moves; `*dyn` never moves).

**A6. A lending iterator through `Iter`.**

```rig
obj Lines            # owns buf: String, refills it on every next
  fun next(!@) -> (?String)?        # views @.buf
fun first_two[I: Iter](it: !I) -> Pair[I.Item, I.Item]
  Pair(first: it.next()!, second: it.next()!)
```

The trait omits `from`. If that is read as "Item views only what @ views", which a generic `for`
needs in order to be usable, the impl's real `from @` counts as "within", and the first line dies
when the second `next` writes `buf`. If it is read conservatively as `from @`, every generic iterator
body that keeps two items is rejected.
**Rule:** in a trait, a method whose result could hold a view must write `from`. No default applies.
Add a clause that names what a view parameter views, not the parameter itself (the syntax panel
picks the spelling). `Iter.next` uses that clause. An impl whose result views an owned part of `@`
does not meet `Iter`. A later `LendIter` says `from @`.

**A7. A bound on an actor type bypasses its mailbox.** With `obj Counter: Tick`, a generic call
`x.tick()` emits the witness `Counter.tick(x)`, a direct call on the actor's state, if anything ever
lets `*Actor[Counter]` meet `Tick` or lends `?Counter` out of it.
**Rule:** `*Actor[A]` meets no user trait, and the lend table gives no `?A` of an actor (SPEC: an
actor's fields are reached only by its methods). Write this down, since the ownership report says
"handles need no auto impls" without excluding actors.

**A8. User `eq` alone breaks `hash.Map`. The backend and types reports also contradict each other
here.** Types: a declared `eq` or `hash` replaces the derived one, and generic bodies call it.
Backend: `Hash` and `Eq` bounds need no witness and lower through `rig.hash` and `rig.eql`, which
reflect over fields. Under the backend's plan, a Map keyed on a case-insensitive `Name` probes with
field equality. Under either plan, a user `eq` paired with a derived `hash` gives equal keys
different hashes. `obj Pair { a: Name }` must also use `Name.eq` and `Name.hash` for its field when
both are derived.
**Rule:** derived `==` and `.hash()` call a user method at every level of nesting (`rig.eql` and
`rig.hash` check for the declaration). A type that declares `eq` is not `Hash` unless it also
declares `hash`. `eq` and `hash` (and later `order` and `print`) are reserved names with fixed
signatures (`fun hash(?@) -> U64`), and a different signature is an error, not a silent opt-out.
Std's `sort` and `Map` stay memory-safe under a lying `eq`, `hash`, or `order`, as they are under
bounds checks today.

## B. Undefined or contradictory

**B1. Per-instance checking: retire it, or keep it forever?** Types C retires it (phase 3).
Ownership C keeps unbounded `[T]` on per-instance rules forever, and holds a bounded parameter to its
bounds alone. So `fun f[T: Shape](x: T) -> Pair[T, T]` (a copy) is legal in types' phase 1 and an
error under ownership.
**Rule:** any bound on a parameter turns per-instance checking off for that parameter. Whether
unbounded retires is a separate decision for the owner. Default: retire, as types C says.

**B2. A bounded `T` without `Moves` in a task.** SPEC §18 makes a task *local* when an argument does
not cross. It is not rejected. **Rule:** a bounded `T` without `Moves`/`Shares` is treated as not
crossing, so the task is local. A channel send, an actor argument, and `par.each` reject it. An
erased object without the marker works the same way. Backend §4's "(a) never crosses" is this rule.

**B3. Coherence.** The cycle ban on imports already stops a header conformance and a retroactive
impl of one concrete type. It does not stop these:
(i) two impls in one trait module, `impl Tr for List[T] where T: A` and the same `where T: B`, which
overlap for a type that is both;
(ii) a blanket `impl Print for T where T: Shape` beside `obj X: Print`, where X meets `Shape`
retroactively in a module X's module never imports.
**Rule:** no impls for a bare type parameter. At most one impl per (trait, type constructor), with
no overlapping conditions. Impls are facts of the whole program (a bound is met if an impl exists
anywhere). Only the `c.area()` shorthand is scoped by import. A retroactive impl may not define a
method name the type already has, and it never silently adopts an existing method as an
implementation. Otherwise one type ends up with two `area`s, which contradicts types' own "one
namespace" rule.

**B4. Supertraits and defaults.** It is undefined whether a subtrait may redeclare a supertrait's
method with narrower clauses, and which default wins when `B: A` and `C: A` each give `A.d` one.
**Rule:** a subtrait inherits supertrait methods exactly and cannot redeclare or re-default them.
Conflicting defaults are an error until the type writes the method. A default body's clauses are as
written, never inferred from the body, so editing a body never changes the contract.

**B5. Conditional methods.** `obj Wrap[T]: Shape` whose `area` exists only `where T: Num` would let
`Wrap[String]` claim `Shape`.
**Rule:** a conformance is met only by methods whose conditions follow from its own `where`. Two
methods of one name on one type are an error, whatever their conditions (no specialization).

**B6. Witnesses for generic types.** Backend C passes `W` beside `T` to functions. For
`obj Wrap[T]: Print where T: Print`, or `obj Sorted[T: Ord]` with a user `order`, putting `W` in
the type would make `Wrap(T, W)` and `Wrap(T, void)` two Zig types for one Rig type.
**Rule:** a type's witnesses are compile-time parameters of its methods, never of the type.

**B7. Generic methods and object safety.** Backend makes object safety a property of the whole
trait. Ownership excludes only the offending methods. **Rule:** follow ownership. A method with its
own type or value parameters, with `Self` outside `@`, or with no self is left out of the vtable,
and calling it through an object is an error that says why.

**B8. Associated types.** It is undefined whether `type Item = !Int` is allowed (it must not be: no
value holds a write view), or `type Item = ?fun()` (it must not be: a callable view is never a type
argument). It is also undefined whether the SPEC "Generic bodies" loan rule (a `T` taken by value
counts as stored or returned) covers `I.Item`.
**Rule:** an associated type follows the rules for type arguments, and the loan rule covers it.
`where I.Item: Owned` opts out of the loan rule.

**B9. `Copy` against `Owned`.** Types: `Copy` is plain data. Ownership: `Copy` also holds for read
views. The two must agree, and `Copy` must never imply `Owned`, or `[T: Copy]` with `T = ?String`
loses its loan. Cell's elements need `Copy + Owned`. Unify the names (types writes `Move`/`Share`,
ownership `Moves`/`Shares`; pick one pair). **Default:** ownership's table, with `Plain` as an alias
for `Copy + Owned`.

**B10. `once`.** Exact match, as ownership says. One addition: a trait method whose closure parameter
is `once` keeps it so through dynamic dispatch. The vtable thunk forwards it and never calls it.

## Ranking of panel-1 recommendations

| # | Recommendation | Verdict |
|---|---|---|
| T1 | traits, static only first | keep |
| T2 | derived built-ins; nominal user traits | keep; reserve the signatures of `eq` and `hash` (A8) |
| T3 | header conformance, retroactive only in the trait's module, one impl per program | change: B3 |
| T4 | syntax, conditional methods and conformance | keep; add B5 |
| T5 | built-in trait names; user `eq`/`hash` now | change: B9 names; user `eq` withdraws derived `hash` (A8) |
| T6 | `Map[K: Hash]`, `sort[T: Ord]` | keep |
| T7 | staged migration | keep; settle B1 |
| T8 | case convention as a rule | keep |
| O1 | exact modes, narrower clauses | keep; positional (A3); trait results write `from` (A6) |
| O2 | markers; a bounded parameter is held to its bounds | keep; add B2 and B9 |
| O3 | `?X` meets read-only traits | change to (b) for phase 1; (a) later with A2's test |
| O4 | object forms carry loans; `+ Owned/Moves/Shares` | keep, later; add A1, A4, A5 |
| O5 | dynamic calls use the trait's clauses | keep |
| O6 | oracle C10, copy rule; Lean obligations only | keep; C10 positional, plus A8's fixed signatures |
| B-1 | witness parameter | keep; B6 for types |
| B-1m | marker bounds lower through `rig.hash`/`rig.eql` unchanged | change: they must call user methods at every level (A8) |
| B-2 | fat-pointer objects, later | keep; A1 |
| B-3 | `dispatch` fact; `dyn` in the type | keep |
| B-4 | objects do not cross tasks, then `^dyn ... moves` | keep, restated as B2 (local, not rejected) |
| B-6 | phased plan | keep; a `!dyn` cannot be assigned through from the phase it lands in |
