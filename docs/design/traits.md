# Traits: the design

This is the record of how Rig gains traits, bounds, and trait objects,
in five stages. The owner approved it as the direction. Each stage is
built when a program needs it, and each section says whether its stage
is built. Two panels of three experts wrote the reports behind it, kept
as written in [traits-panel/](traits-panel/README.md); where a report
and this page differ, this page holds.

## Why, and why in stages

**Generics** let one piece of code work for many types: `List[T]`,
`Map[K, V]`, `Task[T]`, `fun max[T](a: T, b: T)`. Rig has them and uses
them everywhere. **Traits and bounds** say what those types must be
able to do. Rig has none: a generic body is checked against every
instance the program makes, with the error at the call and a note at
the body line ([SPEC, Generic bodies](../../SPEC.md#generic-bodies)).
That is the model of C++ templates and of Zig's `comptime`, and it
carries Rig a long way.

Three things it cannot do:

1. A generic body cannot call a method on a `T`. Only the built-in
   operations reach a `T`: arithmetic, ordering, `==`, `.hash()`,
   printing, copying, moving.
2. A type with its own `hash` cannot be a `hash.Map` key by that hash
   ([SPEC §5](../../SPEC.md#5-expressions)): the generic body calls the
   built-in one.
3. One list cannot hold values of different types behind one interface.

Closures, enums with payloads, and objects of `*fun` fields cover much
of this today: `sort_by(?xs, |a, b| ...)` orders by anything, an enum
holds a closed set of kinds, and an object of owned closures is a
hand-written table of methods. So the design is built in stages, the
smallest first, and each later stage waits for a program that needs
it.

| Stage | What it adds | New syntax | Status |
|---|---|---|---|
| 1 | method calls on a type parameter, checked per instance | none | *(planned, next)* |
| 2 | built-in bounds: `Eq`, `Hash`, `Ord`, `Copy`, `Moves`, ... | `[K: Hash]` | *(planned)* |
| 3 | user traits, dispatched at compile time | `trait`, `obj X: T`, `impl X: T` | *(planned)* |
| 4 | trait objects behind a view or a box | `?{Shape}`, `!{Shape}`, `^{Shape}` | *(planned)* |
| 5 | shared trait objects, and trait objects crossing tasks | `*{Shape}`, `^{Job + Moves}` | *(planned)* |

Two principles hold across every stage:

- **Ownership stays visible.** A trait method declares how it takes
  self, `?@`, `!@`, or `<@`, and what its result views and its call
  keeps, `from` and `keeps`, exactly as a method does. Nothing a trait
  adds hides a move, a lend, or a store.
- **Dispatch stays visible, and its cost with it.** A call through a
  bound is a direct call at no cost. A call through a trait object is
  an indirect call, and only a type written in braces makes one, so
  the braces mark the cost.

## Stage 1: methods on a type parameter *(planned, next)*

A generic body may call a method on a `T`, checked against each
instance as the built-in operations are today. There is no new syntax.
This closes the first gap with the least machinery, and every later
stage keeps it for a parameter with no bound.

```rig pending
obj Square
  side: Float

  fun area(?@) -> Float
    @side * @side

obj Circle
  r: Float

  fun area(?@) -> Float
    3.0 * @r * @r

fun total[T](xs: []T) -> Float
  t = 0.0
  for x in xs
    t += x.area()
  t

sub main()
  print(total([Square(side: 2.0), Square(side: 3.0)]), total([Circle(r: 1.0)]))
```

```output
13.0 3.0
```

**Typing.** A call `x.m(args)` on a value whose type is a type
parameter, or a view of one (`?T`, `!T`), is typed at each instance,
as the rest of a generic body is: the instance's type must declare a
method `m`, visible where the body is (`pub` when the type's module is
another), that takes the arguments as written, and its result type is
the call's type in that instance. A method with compile-time
parameters of its own is called as it would be outside a generic body.

**Self.** The sigil at the call says how the body takes self, as at any
call: `x.m()` reads, `!x.m()` writes, `<x.m()` consumes. An instance
whose method takes self another way is rejected at the call that makes
the instance; the body is not rewritten to fit.

**Ownership.** The body is ownership-checked once, as today, for a `T`
that may own a resource. The method a call reaches is not known there,
so the call is checked as a call of a function value is, with no
`from` or `keeps` to narrow it: its result may carry the loans of self
and of every view argument, and a call that writes self may store what
any argument views in self. Every method meets these bounds, so the
check holds for every instance. An instance never needs a second
ownership check.

**What a failure reads.** As for the built-in operations: at the call
or type that makes the instance, with a note at the body line.

```rig pending
obj Label
  text: String

fun total[T](xs: []T) -> Float
  t = 0.0
  for x in xs
    t += x.area()
  t

sub main()
  print(total([Label(text: String("a"))]))
```

```error
`total[Label]` cannot use `T = Label`: the generic body calls `area` on a `T`, and `Label` has no method `area`
```

```rig pending
obj Counter
  n: Int

  sub bump(!@)
    @n += 1

fun touch[T](x: ?T)
  x.bump()

sub main()
  c = Counter(n: 0)
  touch(?c)
```

```error
`touch[Counter]` cannot use `T = Counter`: the generic body calls `x.bump()`, which reads `x`, but `Counter.bump` takes `self` as `!@`
```

**What Stage 1 leaves out.** Reading a field of a `T` and calling `T`
itself stay rejected. A method of a built-in type (`List`, `String`,
`Cell`, a number) is reached through a `T` only where emit already
lowers that method by its resolved type; otherwise the instance is
rejected with a message that says so. Emit writes the call as Zig
resolves it per instance, `x.area()`, so a method of an `obj` or an
`enum`, in any module, std included, lowers with no new machinery.

**What changes with it.** SPEC's "Generic bodies" (the sentence that a
body cannot call a method on a `T`), DESIGN's "Per-instance checking",
the FAQ's answer on traits, and journey 07, which teaches generics as
they are once Stage 1 lands. The examples above are ```` ```rig
pending ````: the suite fails them the day they work, and they become
ordinary examples then.

## Stage 2: built-in bounds *(planned)*

A bound names, in the signature, a capability a body uses, so the error
moves to the user's line and the signature becomes the contract:

```text
fun max[T: Ord](a: T, b: T) -> T
  a if a > b else b

hash.Map[K: Hash, V]
```

**The built-in traits.** Two kinds, split along the mantra: facts the
compiler derives from a type's parts, which no type ever declares, and
capabilities a type may give its own meaning.

| Trait | Means | A type writes |
|---|---|---|
| `Copy` | a bare use copies | never: plain data and read views |
| `Clone` | `+x` makes a new owner | never; implied by `Copy` |
| `Owned` | holds no loan | never: no part is a view (`Static` is fine) |
| `Moves` | may move to another task | never: SPEC §18's "moves" column |
| `Shares` | may be read by several tasks | never: SPEC §18's "shares" column |
| `Eq` | `==`, `!=` | `fun eq(?@, other: ?Self) -> Bool` |
| `Hash: Eq` | `.hash()` | `sub hash_into(?@, h: !hash.Hasher)` |
| `Ord: Eq` | `<` and its kin | `fun order(?@, other: ?Self) -> Order` |
| `Print` | `print` and text building | `sub print(?@, out: !Printer)` |
| `Num`, `Integer: Num`, `Signed: Num` | arithmetic; `%`, bits, shifts; negation | never: built-in numbers only |
| `Iter` | `for x in !it` | `type Item` and `fun next(!@) -> Item?` |

`Copy` never implies `Owned`: `[T: Copy]` with `T = ?String` keeps its
loan. A Cell's elements need both.

**Giving a capability a meaning of one's own.** A type changes `==`,
hashing, ordering, or printing only by naming the trait on its header,
`obj Name: Eq + Hash`, and writing the method. A method that is merely
named `eq` or `hash` stays an ordinary method, as it is today, which
removes SPEC §5's trap. Naming `Ord` without an `order` method orders
by the fields, in declared order. A type that declares its own `Eq`
loses the derived `Hash`, so a key whose `==` and hash disagree is
rejected where it is used. Derived `==` and `.hash()` call a part's own
`eq` and `hash_into` at every level of nesting. The signatures above are
fixed: another signature under one of these names is an error, not a
quiet opt-out. `Order` is a built-in enum, `less`, `equal`, `greater`,
with `then` to chain comparisons.

**What a bound changes in a body.** A type parameter with any bound is
checked against its bounds alone: a body may copy a `T: Copy`, compare
a `T: Ord`, and put a `T: Owned` in a Cell, and may not do what its
bounds do not name. A parameter with no bound keeps per-instance
checking. A view as a type argument, `T = ?X`, meets only these
built-in bounds in this stage.

**Tasks.** A bounded `T` without `Moves` or `Shares` does not cross, so
a task that takes one is local, as SPEC §18 makes any task whose
arguments do not cross; a channel send, an actor's argument, and
`par.each` reject it.

**std.** `hash.Map[K: Hash, V]` and `hash.Set[K: Hash]`, with the bound
implied wherever the type is named; `sort`, `search`, `lower_bound`,
`min`, `max`, `clamp` take `T: Ord`; `contains` and `index_of` take
`T: Eq`; `abs` takes `T: Signed + Ord`. `sort_by` stays unbounded, and
`sort_by_key` and `iter.count` and `iter.sum` join it. `BigInt` keeps
`compare` and `equals`, with no `<`.

**Lowering.** None: a built-in bound is today's recorded requirement
written into the signature, and the runtime's `rig.eql`, `rig.hash`,
and `rig.compare` call a type's own methods where it declares them.

## Stage 3: traits of your own *(planned)*

```text
pub trait Shape
  fun area(?@) -> Float

  fun describe(?@) -> String          # a default method
    String("a shape of area ", @area())

pub obj Square: Shape + Print
  side: Float

  pub fun area(?@) -> Float
    @side * @side

fun total[T: Shape](xs: ?List[T]) -> Float
  t = 0.0
  for x in xs
    t += x.area()
  t
```

**A trait** is a named set of methods: a member without a body is
required, one with a body is a default. `Self` is the conforming type
and `@` its value, as in an `obj`. A trait may build on others,
`trait Named: Print`, and name a type its conformers choose, an
associated type, `type Item`, read as `I.Item`. A subtrait inherits its
supertraits' methods exactly: it may not redeclare or re-default them,
and two defaults for one method are an error until the type writes the
method. A default's `from` and `keeps` are as written, never inferred
from its body. Associated constants, and traits with parameters of
their own (`trait Into[T]`), wait for a later decision.

**Conformance is written on the type's header,** `obj Square: Shape`,
beside `unique` (`obj Ticket unique: Print`). The type's methods are
ordinary methods, in its body or beside it. A method that meets a `pub`
trait on a `pub` type says `pub`; leaving it off is an error with the
fix.

**`impl Type: Trait`** is for the two cases the header cannot say:

- a type of another module, or a built-in type, written in the trait's
  module: `impl Int: Shape`;
- a conformance that holds only under a bound: `impl Wrap[T: Shape]: Shape`.

An `impl` in the type's own module with no bound is rejected toward the
header form, so each case has one spelling. Rust's `impl Trait for
Type` is not used: `for` is Rig's loop word.

**Coherence.** A type meets a trait at most once in the whole program,
in its own module or the trait's. There are no impls for a bare type
parameter, at most one impl per trait and type constructor, and none
whose conditions overlap. A bound is met if an impl exists anywhere in
the program; only the `c.area()` shorthand depends on what a module
imports. A retroactive impl may not define a method the type already
has, and never adopts an existing method as an implementation. When two
imported traits give one type a method of one name, `c.area()` is an
error that says to name the trait: `Shape.area(c)`, with self's sigil
written as at any call.

**How an implementation must match its trait.** Exactly, in how it
takes self (`?@`, `!@`, `<@`), in each parameter's type and mode, views
included, in `once`, and in its result. Only `from` and `keeps` may
narrow: an implementation may name fewer than the trait, compared by
parameter position, never more. A call through a bound uses the trait's
clauses, which every implementation is within. In a trait, a method
whose result could hold a view must write its `from`; there is no
default. An implementation that keeps what its trait does not would let
a call through the trait end a loan the implementation still holds, so
it is rejected where it is declared.

**Bounds.** In the brackets, always, since brackets mean compile time:
`[T: Ord + Print]`, a bound on an associated type as an entry of its
own, `[S: Source, S.Item: Ord]`, and a bound on a method's own
parameter, `fun map[U: Print](?@, ...)`. There is no `where` clause. A
method that exists only for some instances is written with its bound
in the type's brackets, `fun Wrap[T: Print].show(?@)`; repeating a
bound the type already has is rejected, and a conformance is met only
by methods its own bounds imply.

**Names.** A type parameter starts with a capital letter and a value
parameter with a lowercase one, so `[T: Ord]` and `[n: Int]` read
apart; each mistake has its own error.

**What a bounded body may do.** Call what its bounds declare, and use
what the built-in bounds name, and no more. Actors never meet a user
trait: `*Actor[A]` meets none, and nothing lends a view of an actor's
value, so no bound reaches an actor's state around its mailbox.

**Public generics state their bounds.** In this stage a `pub` generic
must name, by bounds, everything its body does with each type
parameter; the error carries the fix, and `rig fix` writes the bounds
across a tree, std first. A private generic may keep per-instance
checking, since its author sees every instance. The one check that
stays per instance everywhere is whether a literal fits each instance's
type (`x * 300` with `T = U8`).

**Lowering.** A call through a bound is a direct call. Each bound adds
one compile-time parameter after the type it bounds, its witness, and
the call is written `W_T_Shape.area(x)`: the type itself for a
conformance on its header, or a module-level `__rig_impl_Shape_Int` for
an `impl`. Instances stay one per type, so code size does not change.
A generic type's witnesses are compile-time parameters of its methods,
never of the type, so one Rig type stays one Zig type. Every method
call records how it dispatches, `direct`, `static`, or `dynamic`, and
`rig check --facts=sema` prints it; in `rig emit` the three read
`x.area()`, `W.area(x)`, and `s.vt.area(s.ptr)`.

**The errors a reader meets first**, each with its fix:

```text
`Shape` is a trait, not a type: write `[T: Shape]` for one type known when compiling, or `?{Shape}` for any type at run time
`T` has no method `area`: `total[T]` gives `T` no bound; write `[T: Shape]`, which declares `area`
`total[Label]` cannot use `T = Label`: `total` needs `T: Shape`, and `Label` is not `Shape`; declare `obj Label: Shape`
`Square` is declared `Shape` but has no method `area`; declare `fun area(?@) -> Float` in `Square`
`Counter.next` takes `self` as `?@`, but `Source` declares `next(!@)`; a method meets its trait with the same self: write `fun next(!@) -> Item?`
`Log.watch` keeps `s`, but `Watcher.watch` keeps nothing: a call through `Watcher` would end the loan on `s` while `Log` still views it; add `keeps s` to `Watcher.watch`
`c.area()` could call `Shape.area` or `Region.area`, which both apply to `geo.Circle`; name the trait: `Shape.area(c)`
```

## Stage 4: trait objects *(planned)*

A **trait object** is a value of some type that meets a trait, chosen
when the program runs. It is written as the trait in braces, behind a
view or a box:

```text
fun area_of(s: ?{Shape}) -> Float
  s.area()

sub main()
  sq = Square(side: 2.0)
  print(area_of(sq))                    # lends `?{Shape}`, unmarked like any read
  shapes: List[^{Shape}] = List()
  !shapes.push(^Square(side: 3.0))
  !shapes.push(^Circle(r: 1.0))
  for s in ?shapes
    print(s.describe())
```

**The braces.** `{Shape}` reads as set notation: some member of the set
of types that are `Shape`. Braces hold only traits, so `{T}` of a type
parameter and `{Square}` of a type are errors. A bare `{Shape}` has no
size of its own and is rejected toward `?{Shape}` or `^{Shape}`. The
holding sigils keep their meanings, so no new rule is needed for them:

| Form | Is | Methods callable | Copies |
|---|---|---|---|
| `?{Shape}` | a read view | `?@` | yes, as a read view does |
| `!{Shape}` | a write view | `?@`, `!@` | never |
| `^{Shape}` | a box, an owner | `?@`, `!@` (through `!b`), `<@` (`<b.m()` frees the box) | `+b` only when the trait requires `Clone` |

Braces mean nothing else in Rig, outside string escapes, so they cannot
be misread. A map or set literal, if Rig ever has one, sits in an
expression, where a type never does.

**Making one.** At an expected type, by an ordinary lend or move:
`area_of(sq)` lends a `?{Shape}`, and `b: ^{Shape} = ^<c` moves a box
in, reusing its allocation. No sigil marks the erasure; the braces in
the expected type do.

**What a call costs.** A load from a table in cache and an indirect
call: a few cycles, but no inlining, no constant folding, and no
vectorizing across it, the cost of a `?fun` call today. A drop of a
`^{Shape}` is always an indirect call, since the type is gone. In
numeric code, prefer a bound.

**Rules that keep it sound:**

- Through a `!{Shape}` a program only calls methods. Assigning,
  swapping, or moving out of one is rejected: the value it views may be
  of another type. `!b` of a `b: ^{Shape}` may still replace the whole
  box.
- A method with compile-time parameters of its own, with `Self` outside
  `@`, or with no self, is not callable through an object; the rest of
  the trait is, and the error says why for that method.
- A call through an object uses the trait method's `from` and `keeps`,
  which every implementation is within. An owned closure is the case of
  one method with no clauses, so today's closure rules are unchanged.
- A `^{Shape}` carries the loans of what it was made from, as a `^T`
  does. With no bound saying otherwise, it may hold a loan and its drop
  may read one, so those loans last to its drop.
- Built-in bounds on an object are set only where a concrete type is
  erased, written in the braces: `^{Shape + Owned}`. They never widen
  from one object type to another, and a marker supertrait never makes
  an object form `Copy` or crossing: each form takes its facts from its
  own kind.
- A trait object does not cross to another task in this stage; a task
  that takes one is local.

**Lowering.** A trait object is a fat pointer, `{ptr, vt}`, sixteen
bytes, with one static table per trait and type, made only where a
conversion to that object is written. Each table entry calls the method
through a small function, since Zig takes no address of an inline
function, so the method stays inlinable everywhere else. A pointer to
the table inside each value would change the layout of plain data, and
is not used.

## Stage 5: shared objects, and crossing tasks *(planned)*

- **`*{Shape}`**, a counted handle to a trait object, calls only `?@`
  methods, as any handle does; `+s` counts. Its table also holds the
  count operations, since a `Shared`'s layout and whether its counts
  are atomic depend on the hidden type. **`~{Shape}`** is its weak
  handle.
- **Crossing tasks** is a bound in the braces, checked where the type is
  erased, where it is still known: `^{Job + Moves}` may move to another
  task, `?{Job + Shares}` may be read by several. A job queue and an
  actor's messages are the cases this serves.
- Once `*{...}` exists, an owned closure, `*fun`, may be lowered the
  same way, saving one allocation per closure.

## What each checker and proof adds

| Stage | Compiler | Reference checker (`test/oracle`) | Lean model (`formal/`) |
|---|---|---|---|
| 1 | per-instance typing of the call; the function-value ownership rule | the same rule, read from the call's facts | nothing |
| 2 | bounded parameters held to their bounds; marker facts | computes the marker facts itself; a copy of a bounded `T` needs `Copy` | `Copy` only of plain kinds |
| 3 | conformance, coherence, clauses within the trait's by position | conformance clauses checked on its own | a subsumption lemma: a call checked against wider clauses is sound for any callee within them |
| 4 | object facts; no assignment through `!{...}` | object facts computed itself; abstains on a dynamic call until then | erasing a type keeps its loans |
| 5 | count operations in the table; crossing bounds at erasure | crossing facts of objects | crossing obligations |

## Alternatives considered

- **Extending duck typing to every operation** (Zig, C++): kept, for a
  parameter with no bound, in Stage 1. Alone it leaves signatures
  silent and lets two methods of one name meet by accident.
- **Structural traits** (Go): any type with the methods meets the trait.
  Rejected for user traits: accidental conformance, and no home for
  defaults or associated types. Built-in capabilities are structural,
  as derived facts.
- **Conformance in `impl` blocks only** (Rust): a type's methods split
  across blocks. The header says what a type is; `impl` stays for the
  two cases it cannot.
- **A `where` clause**: every bound fits in the brackets.
- **Trait objects spelled bare** (`?Shape`): reads as a concrete type and
  hides the cost. **`dyn`**: jargon. **`Dyn[Shape]`**: brackets would
  hand a trait to a type with no values of its own. **`any`**: a word
  where the mantra wants a mark, since dispatch is a mechanic. Braces
  won.
- **`Move` and `Share`, or `Sends`**: every owner moves, so the task
  bounds say where to: `Moves` and `Shares`, SPEC §18's own words.
- **Requiring bounds on every generic**: 300 to 500 of the suite's
  generics would change, for no reader a private generic has. Only
  `pub` generics must state their bounds.
- **Trait objects now**: enums and closures cover today's programs.
