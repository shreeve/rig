# APIs: the design

This is the record of how Rig gains APIs, bounds, and API objects,
in five stages. The owner approved it as the direction. Each stage is
built when a program needs it, and each section says whether its stage
is built. Two panels of three experts wrote the reports behind it, kept
as written in [traits-panel/](traits-panel/README.md), and a third
panel chose the words, in [naming-panel/](naming-panel/README.md); where
a report and this page differ, this page holds.

## Why, and why in stages

**Generics** let one piece of code work for many types: `List[T]`,
`Map[K, V]`, `Task[T]`, `fun max[T](a: T, b: T)`. Rig has them and uses
them everywhere. **APIs and bounds** say what those types must be
able to do. Rig has none: a generic body is checked against every
instance the program makes, with the error at the call and a note at
the body line ([SPEC, Generic bodies](../../SPEC.md#generic-bodies)).
That is the model of C++ templates and of Zig's `comptime`, and it
carries Rig a long way.

Three things it cannot do alone:

1. Say in a signature what a `T` must do. A body applies the built-in
   operations to a `T` (arithmetic, ordering, `==`, `.hash()`,
   printing, copying, moving) and, with Stage 1, calls its methods,
   and only the instances check them.
2. A type with its own `hash` cannot be a `Map` key by that hash
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
| 1 | method calls on a type parameter, checked per instance | none | *(built)* |
| 2 | built-in bounds: `Eq`, `Hash`, `Ord`, `Copy`, `Sends`, ... | `[K: Hash]`, `obj X: Eq` | *(built)* |
| 3 | APIs of a program's own, dispatched at compile time | `api`, `obj X: A`, `add X: A` | *(built)* |
| 4 | API objects behind a view or a box | `?{Shape}`, `!{Shape}`, `^{Shape}` | *(in part: the types, the views, and calls through them)* |
| 5 | shared API objects, and API objects crossing tasks | `*{Shape}`, `~{Shape}`, `^{Job + Sends}`, `?{Job + Syncs}` | *(planned: designed, its Core change awaiting the owner)* |

Two principles hold across every stage:

- **Ownership stays visible.** An API's method declares how it takes
  self, `?@`, `!@`, or `<@`, and what its result views and its call
  keeps, `from` and `keeps`, exactly as a method does. Nothing an API
  adds hides a move, a lend, or a store.
- **Dispatch stays visible, and its cost with it.** A call through a
  bound is a direct call at no cost. A call through an API object is
  an indirect call, and only a type written in braces makes one, so
  the braces mark the cost.

## The words

```text
api Shape                              # what a Shape can do: methods only, no fields
  fun area(?@) -> Float                # required: no body
  sub describe(?@)                     # default, built only on the API; a type may override it
    print("area", @area())

obj Square: Shape + Print              # Square provides Shape and Print
add Int: Shape                         # add Shape to Int, written in Shape's module
api Widget: Shape + Named + Print      # a named combination
fun total[T: Shape](xs: ?List[T])      # any T that provides Shape
?{Shape}   ^{Job + Sends}              # any value that provides Shape
```

- **`api`** declares a named set of methods a type provides: required
  ones, with no body, and defaults, written only in terms of the API's
  own methods. It holds no fields and no state. It is the API, not the
  implementation, which lives in the types that provide it.
- **A type provides an API on its header,** `obj Square: Shape`, read
  "`Square` provides `Shape`". **`add Int: Shape`** adds one to a type
  declared elsewhere. `api` always declares a new name and `add` always
  names a type that exists, so `add Inte: Shape` is an error.
- **`+` joins APIs,** in a header, a bound, and braces alike.
- **Every default may be overridden** by a method of the same
  signature; a method with a default's name and another signature is an
  error.
- **The built-in APIs keep short names,** `Eq`, `Hash`, `Ord`, `Print`,
  `Copy`, `Clone`, `Owned`, `Sends`, `Syncs`, `Num`, `Iter`, and an
  error about one says what cannot be done: "`Label` cannot be hashed".
- **`api` and `add` are keywords only at the start of a
  declaration,** so `user.api` and `!set.add(x)` keep working.
  `trait` and `impl` stay reserved only to say "write `api`" and "write
  `add`".
- **`{Iter[Item: Int]}`** is kept free to name an API object's
  associated type, and a bare API name in a type is an error, so a
  later form has its spelling.
- **"Contract" is kept for another idea.** A later feature of
  preconditions and postconditions would be spelled `requires` and
  `ensures`, never with the word contract.

## Stage 1: methods on a type parameter *(built)*

A generic body may call a method on a `T`, checked against each
instance as the built-in operations are today. There is no new syntax.
This closes the first gap with the least machinery, and every later
stage keeps it for a parameter with no bound.

```rig
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
parameter, or a view of one (`?T`, `!T`), is checked at each instance,
as the rest of a generic body is: the instance's type must declare a
method `m`, visible where the body is (`pub` when the type's module is
another), that takes the arguments with the types the body passes
them (a literal as `Int` or `Float`), and gives the result the body
takes. The body is typed once, so the call's result takes its type
from where the call stands:

- the type its context expects: a typed binding, an argument, a
  return, an assignment (`t += x.area()` with `t` a `Float`), with `-> T`
  substituted in each instance, so `x.dup()` gives a `T`;
- through `!` or `catch` a fallible one, and through `?` or `??` an
  optional one: `a: Float = x.parse()!` needs a `Float!`;
- the other operand of an arithmetic or comparison operator, a literal
  there as a binding of it would be: `x.area() + 1.0` is a `Float`, and
  `x.size() > 3` needs an `Int`;
- as a statement, nothing: the method must be a `sub`, and the message
  for one that gives a value says to write `_ = x.m()`;
- under `_ =`, any result that cannot fail, dropped there in each
  instance.

Anywhere else the body cannot know the result's type, and the call is
rejected with the fix.

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

```rig reject
obj Label
  id: Int

fun total[T](xs: []T) -> Float
  t = 0.0
  for x in xs
    t += x.area()
  t

sub main()
  print(total([Label(id: 1)]))
```

```error
`total[Label]` cannot use `T = Label`: the generic body calls `area` on a `T`, and `Label` has no method `area`
```

```rig reject
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

```rig reject
obj Square
  side: Float

  fun area(?@) -> Float
    @side * @side

sub show[T](x: ?T)
  print(x.area())

sub main()
  s = Square(side: 2.0)
  show(?s)
```

```error
`x.area()` calls a method on a `T`, whose result type the body cannot know; give it one: `a: Float = x.area()`, then `print(a)`
```

**What Stage 1 leaves out.** Reading a field of a `T` and calling `T`
itself stay rejected. Emit writes the call as Zig resolves it per
instance, `x.area()`, so a method of an `obj` or an `enum`, in any
module, std included, lowers with no new machinery. Emit lowers a
built-in type's methods (`List`, `String`, `Cell`, a number) by the
type it resolves at the call, which a `T` does not give, so an instance
whose type is a built-in one is rejected with a message that says so.
So is an instance whose method has compile-time parameters of its own,
which emit passes at each call and a body written once cannot, and
one whose method is marked `inline`, whose frame each caller's count
includes and a call through a `T` would not.

**Where it is described.** SPEC's "Generic bodies" gives the rule, and
DESIGN's "Per-instance checking" its reasons.

## Stage 2: built-in bounds *(built)*

A bound names, in the signature, a capability a body uses, so the error
moves to the user's line and the signature becomes the contract. Stage
2 adds bounds over the built-in APIs, and a type's header naming the
ones it gives a meaning of its own; `api` and `add` come with Stage 3.

```rig
use std.text

fun max[T: Ord](a: T, b: T) -> T               # a bound, in the brackets
  a if a > b else b

fun count[K: Hash + Print, V](m: ?Map[K, V]) -> Int   # several, joined with +
  m.len

obj Name: Eq + Hash                            # Name gives Eq and Hash its own meaning
  text: String

  fun eq(?@, other: ?Name) -> Bool
    a = ?@text[..]
    b = ?other.text[..]
    return false if a.len != b.len
    for i in 0..a.len
      return false if text.to_lower(a[i]) != text.to_lower(b[i])
    true

  sub hash_into(?@, h: !Hasher)
    for b in ?@text[..]
      !h.add(text.to_lower(b))

obj Version: Ord                               # Ord named, no `order`: ordered by its fields
  major: Int
  minor: Int

enum Suit: Ord                                 # an enum takes the list too
  clubs
  spades

sub main()
  print(max(Version(major: 1, minor: 2), Version(major: 1, minor: 10)).minor, max(Suit.clubs, Suit.spades))
  a = Name(text: String("Ada"))
  b = Name(text: String("ADA"))
  m: Map[Name, Int] = Map()
  !m.put(<a, 1)
  print(m.get(?b), count(?m))
```

```output
10 .spades
1 1
```

**Bounds.** A bound is written in the brackets, `[T: Ord]`, and several
are joined with `+`. The compiler tells `[T: Ord]` from `[n: Int]` by
what the name after the colon is, an API or a type. A type parameter
starts with a capital letter and a value parameter with a lowercase
one, so the two read apart, and each mistake has its own error.

**The built-in APIs.** Two kinds, split along the mantra: facts the
compiler derives from a type's parts, which no type ever declares, and
capabilities a type may give its own meaning.

| API | Means | A type writes |
|---|---|---|
| `Copy` | a bare use copies | never: plain data and read views |
| `Clone` | `+x` makes a new owner | never; implied by `Copy` |
| `Owned` | holds no loan | never: no part is a view (`Static` is fine) |
| `Sends` | may go to another task | never: SPEC §18 |
| `Syncs` | may be read by several tasks at once | never: SPEC §18 |
| `Eq` | `==`, `!=` | `fun eq(?@, other: ?Self) -> Bool` |
| `Hash: Eq` | `.hash()` | `sub hash_into(?@, h: !Hasher)` |
| `Ord: Eq` | `<` and its kin | `fun order(?@, other: ?Self) -> Order` |
| `Print` | `print` and text building | `sub print(?@, out: !Printer)` |
| `Num`, `Integer: Num`, `Signed: Num` | arithmetic; `%`, bits, shifts; negation | never: built-in numbers only |

`Copy` never implies `Owned`: `[T: Copy]` with `T = ?String` keeps its
loan. A Cell's elements need both, written `Copy + Owned`; there is no
shorter name. `Iter` comes with Stage 3, since its useful bound names
its item type, `[I: Iter, I.Item: Ord]`.

**Which types provide which.** Numbers, `Bool`, text (`String`,
`?String`, `Static`), and plain enums provide `Eq`, `Hash`, `Ord`, and
`Print`, so `false < true`, and a String orders by its bytes as a
`?String` does. `Float` provides `Eq` and `Ord`, with `NaN` comparing
false as `==` and `<` do today, and not `Hash`, so a float never keys a
Map. An optional, an array, and a slice provide `Eq`, `Hash`, `Ord`, and
`Print` when their elements do; arrays and slices order element by
element. A `List[T]` provides `Print`, and `Clone` when `T` does, and
not `Eq`, `Hash`, or `Ord`, as its `==` today. A `Map`, a `Set`, a
Cell, a Signal, a handle, and a task provide only the derived facts,
and `Print` where `print` takes them today. An
object or an enum with fields provides `Eq`, `Hash`, and `Print` by its
fields, as today, and `Ord` only when its header names it.

**Giving a capability a meaning of one's own.** A type changes `==`,
hashing, ordering, or printing only by naming the API on its header,
`obj Name: Eq + Hash`, and writing the method. A method that is merely
named `eq` or `hash` stays an ordinary method, as it is today, which
removes SPEC §5's trap. Naming `Ord` without an `order` method orders
by the fields, in declared order. A type that declares its own `Eq`
loses the derived `Hash`, so a key whose `==` and hash disagree is
rejected where it is used. Derived `==` and `.hash()` call a part's own
`eq` and `hash_into` at every level of nesting. The signatures in the
table are fixed: another signature under one of these names, on a type
that names the API, is an error, not a quiet opt-out. A type's own
`print` comes with this stage: `print` and text building already run
through the path it joins.

**`Order`, `Hasher`, and `Printer`.** Three small built-in types, named
with no import:

- `Order` is a built-in enum, `.less`, `.equal`, `.greater`, and
  `a.then(b)` gives `a` unless it is `.equal`, then `b`, for ties:
  `@major.order(?o.major).then(@minor.order(?o.minor))`.
- `Hasher` takes what a type's hash is made of, `!h.add(x)`, where
  `x` is any value that provides `Hash`; the hasher mixes them, so a
  type never combines numbers by hand.
- `Printer` writes a type's printed form: `!out.text(...)` writes text
  as it is, and `!out.value(x)` writes a value as `print` shows a part
  of another, text in quotes. Padding and other bases are wrappers that
  come later.

**What a bound changes in a body.** A type parameter with any bound is
checked against its bounds alone: a body may copy a `T: Copy`, compare
a `T: Ord`, and put a `T: Copy + Owned` in a Cell, and may not do what
its bounds do not name. A parameter with no bound keeps per-instance
checking, method calls included (Stage 1), unless it is a `pub`
declaration's: a `pub` generic states its bounds (Stage 3). A view
as a type argument, `T = ?X`, meets only these built-in bounds.

**Tasks.** A bounded `T` without `Sends` or `Syncs` does not cross, so
a task that takes one is local, as SPEC §18 makes any task whose
arguments do not cross; a channel send, an actor's argument, and
`par.each` reject it.

**std.** `Map[K: Hash, V]` and `Set[K: Hash]`, with the bound
implied wherever the type is named; `sort`, `search`, `lower_bound`,
`min`, `max`, `clamp` take `T: Ord`; `contains` and `index_of` take
`T: Eq`; `abs` takes `T: Signed + Ord`. `sort_by` stays unbounded, and
`sort_by_key` joins it. `BigInt` keeps `compare` and `equals`, with no
`<`. `iter.count` and `iter.sum` wait for `Iter`, in Stage 3.

**Errors.** An error about a built-in API says what cannot be done, at
the user's line:

```rig reject

obj Reading
  value: Float

sub main()
  m: Map[Reading, Int] = Map()
  print(m.len)
```

```error
`Map[Reading, Int]` cannot use `K = Reading`: `Reading` cannot be hashed; its field `value` is a `Float`
```

```rig reject
obj Point
  x: Int

fun max[T: Ord](a: T, b: T) -> T
  a if a > b else b

sub main()
  print(max(Point(x: 1), Point(x: 2)).x)
```

```error
`max[Point]` cannot use `T = Point`: `Point` cannot be ordered; name `Ord` on its header: `obj Point: Ord`
```

```rig reject
obj Name: Eq
  text: String

  fun eq(?@, other: ?Name) -> Bool
    @text.len == other.text.len

sub main()
  print(Name(text: String("a")).hash())
```

```error
`Name` declares its own `==`, so it cannot be hashed by its fields; write `sub hash_into(?@, h: !Hasher)`
```

```rig reject
obj Version: Ord
  major: Int

  fun order(?@, other: Version) -> Order
    @major.order(?other.major)

sub main()
  print(Version(major: 1) < Version(major: 2))
```

```error
`Version.order` takes `other` as `Version`, but `Ord` fixes `fun order(?@, other: ?Self) -> Order`
```

**Lowering.** None: a built-in bound is today's recorded requirement
written into the signature, and the runtime's `rig.eql`, `rig.hash`,
and `rig.compare` call a type's own methods where it declares them.

## Stage 3: APIs of your own *(built)*

*Built:* `api` with required methods and defaults, APIs that build on
others and on the built-in ones, headers and `add`, how an
implementation must match its API, coherence, `pub` on a method that
meets a `pub` API, a bound by an API checked at each instance, a call
through a bound with the API's clauses and set, `Shape.area(c)` and the
shorthand `c.area()`, witnesses, a generic type's among its
arguments, method-level bounds, additions to `Slot[n]` and
`Table[T, n]`, associated types with their bounds, `Iter` with
`iter.count` and `iter.sum` ([SPEC, APIs](../../SPEC.md#apis)), implied
bounds, and the rule that public generics state their bounds ([SPEC,
Bounds](../../SPEC.md#bounds)).

```rig
pub api Shape
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

sub main()
  squares = List([Square(side: 1.0), Square(side: 2.0)])
  print(total(?squares), squares[0].describe())
```

```output
5.0 a shape of area 1.0
```

**An API** is a named set of methods: a member without a body is
required, one with a body is a default. `Self` is the conforming type
and `@` its value, as in an `obj`. An API may build on others,
`api Named: Print`, and name a type each provider chooses, an
associated type, `type Item`, read as `I.Item`. A subtrait inherits its
supertraits' methods exactly: it may not redeclare or re-default them,
and two defaults for one method are an error until the type writes the
method. A default's `from` and `keeps` are as written, never inferred
from its body. Associated constants, and APIs with parameters of
their own (`api Into[T]`), wait for a later decision.

**`Iter`** is the built-in API a `for` loop already accepts: `type Item`
and `fun next(!@) -> Item?`. A type provides it when it declares that
method, by the one rule the loop uses to find an iterator, and its
`Item` is what `next` gives; no header names it, as none names `Sends`.
It comes with this stage because its useful bound names its item type,
`[I: Iter, I.Item: Ord]`, and with it come `iter.count` and `iter.sum`.
A generic body tracks no view an `I.Item` holds, so an instance whose
items may view memory the iterator owns is rejected, unless its `next`
names only fields declared as read views (`next(!@) -> (?K)? from
@map`, Core sentence 7): its items view what the iterator only views,
as a Map's and a Set's do.

**A type provides an API on its header,** `obj Square: Shape`,
beside `unique` (`obj Ticket unique: Print`). The type's methods are
ordinary methods, in its body or beside it. A method that meets a `pub`
API on a `pub` type says `pub`; leaving it off is an error with the
fix.

**`add Type: API`** is for the two cases the header cannot say:

- a type of another module, or a built-in type, written in the API's
  module: `add Int: Shape`;
- an API a type provides only under a bound: `add Wrap[T: Shape]: Shape`.

An `add` in the type's own module with no bound is rejected toward the
header form, so each case has one spelling. An addition's methods stay
inside it and need no `pub`: they belong to the API, and never become
methods of the type for every importer, so a call on a `T` with no
bound (Stage 1) never reaches one. `add` names a type by its name: an
object, an enum, or a built-in type such as `Int`, `String`, `List[T]`,
or `Slot[n]`. A view, a handle, an optional, an array, a slice, and a
function type take their facts from their parts, and no `add` names
one. `add` says what it does, adds `Shape` to `Int`, whoever owns
`Int`; Rust's `impl Trait for Type` is not used, and `for` is Rig's
loop word.

**Coherence.** A type provides an API at most once in the whole program,
in its own module or the API's. There are no additions to a bare
type parameter, at most one per API and type constructor, and none
whose conditions overlap. A bound is met if the type provides the API
anywhere in the program; only the `c.area()` shorthand depends on what a module
imports. An addition may not define a method the type already
has, and never adopts an existing method as an implementation. When two
imported APIs give one type a method of one name, `c.area()` is an
error that says to name the API: `Shape.area(c)`, with self's sigil
written as at any call.

**How an implementation must match its API.** Exactly, in how it
takes self (`?@`, `!@`, `<@`), in each parameter's type and mode, views
included, in `once`, in its compile-time parameters, and in its result,
how it fails included. Only `from` and `keeps` may
narrow: an implementation may name fewer than the API, compared by
parameter position, never more. A call through a bound uses the API's
clauses, which every implementation is within. In an API, a method
whose result could hold a view must write its `from`; there is no
default. An implementation that keeps what its API does not would let
a call through the API end a loan the implementation still holds, so
it is rejected where it is declared.

**How an API's method fails.** As any method does: `-> T!E` with a
declared set or a union, `-> T!` with any error, or a set parameter of
its own, `fun each[E](?@, f: ?fun(Item) -> Bool!E) -> Int!E`
([SPEC, Generic sets](../../SPEC.md#generic-sets)). An implementation
declares the same: the same set or union, `T!` for `T!`, and the same
set parameters in the same places. It never fails with a narrower set,
though `from` and `keeps` may narrow. Those two are facts only the
checkers read; a set is part of the result's type, which one body
written for every instance receives, the slot of the members' fields
included, so every instance must give it the same. A narrower set would
give a caller through the bound nothing, since that caller sees the
API's set, and a method may always declare a set wider than the members
it uses. So a call through a bound is checked as any call is: `!`
passes the API's set on into a frame whose set holds it, `catch |e|`
gives `e` the API's set, matched without `_` when it is a declared set,
and every instance's method fails with exactly that set. A default's
failures are checked in the API's module, as any body's are. An API
names no set for each provider to choose; a reader whose set depends on
its provider waits for the design of std's I/O sets.

**A body that passes a method's failure on.** With no bound, a generic
body does not know how a `T`'s method fails: Stage 1 takes `x.size()!`
to fail with any error, so a body that declares a set of its own,
`-> Int!Bad`, cannot pass the failure on, and each instance's method
must fail with any error. A bound says how the method fails, in the
signature, once, and a frame whose set holds the API's passes it on:

```rig
error Bad
  empty

error Disk
  full

error Load = Bad | Disk

api Sized
  fun size(?@) -> Int!Bad

obj Word: Sized
  s: String

  fun size(?@) -> Int!Bad
    return Bad.empty if @s.len == 0
    @s.len

fun total[T: Sized](xs: ?List[T]) -> Int!Load
  n = 0
  for x in xs
    n += x.size()!                    # `Bad` passes into `Load`, which holds it
  n

sub main()
  words: List[Word] = List()
  !words.push(Word(s: String("ab")))
  !words.push(Word(s: String("abc")))
  print(total(?words) catch -1)
```

```output
5
```

**Bounds.** In the brackets, always, since brackets mean compile time:
`[T: Ord + Print]`, a bound on an associated type as an entry of its
own, `[S: Source, S.Item: Ord]`, and a bound on a method's own
parameter, `fun map[U: Print](?@, ...)`. There is no `where` clause. A
method that exists only for some instances is written with its bound
in the type's brackets, `fun Wrap[T: Print].show(?@)`; repeating a
bound the type already has is rejected, and a conformance is met only
by methods its own bounds imply. An API may build on the built-in
facts, `api Job: Sends`: every provider can be sent to another task, checked at its
header, and a `[T: Job]` may be sent to another task.

**What a bounded body may do.** Call what its bounds declare, and use
what the built-in bounds name, and no more. Actors never provide a
user API: `*Actor[A]` meets none, and nothing lends a view of an actor's
value, so no bound reaches an actor's state around its mailbox.

**Facts no API names.** A bound states what a body does that an API
names. A few facts of a type's parts have no API: whether a literal
fits it (`x * 300` with `T = U8`), whether it can be frozen
(`*Frozen(<x)` holds nothing that changes what it reaches), and whether
it has a default (`T()`, with which a `Table[T, n]` fills its slots).
Each is checked at every instance, in every generic body, bounded or
not, public or not, with the error at the call or type that makes the
instance and a note at the body line, as Stage 1 reports. An API may
name one later, when a signature needs to say it.

**Compile-time values.** A bound applies to a type parameter. `[n: Int]`
already says what `n` is and takes no bound: a range a value must lie
in (`n > 0`) is a precondition, for the later `requires`, and a
compile-time function checks its arguments with `panic` (`cap[0]`). An
API declares methods, never a compile-time function or a constant. An
API's method may take compile-time parameters of its own, types, values,
and sets, and a call through a bound passes them as at any call, since
the API declares them. The implementation's method, a default or an
addition's included, is checked at them as a call of it is, at each
instance of the body that makes the call: a private one keeps
per-instance checking, and Zig is never left to find what it does not
allow. `Slot[n]` meets the bounds a number does but the
number APIs: it copies, compares, orders, hashes, prints, and crosses.

**Tasks, function values, and closures.** `Sends` and `Syncs` stay
facts of a type's parts ([SPEC §18](../../SPEC.md#18-tasks)): a
function value moves and shares, a callable view and an owned closure
do neither, and a `*Frozen[T]` does both. A call through a bound may be
a task, `x.area()&`, which crosses by the bounds: self lent to read
needs `Syncs`, and a bounded `T` with neither makes the task local, as
in Stage 2. A closure is never generic and takes no bound; one written
in a bounded body calls through the body's bounds. A function value
provides no API of a program's own.

**Frozen values.** `*Frozen[T]` and Stage 5's `*{Shape}` meet at a few
points, and Stage 3 changes neither:

- A `*Frozen[T]` provides `Eq`, `Hash`, and `Print` as its value does,
  `Sends` and `Syncs` always, and no API of a program's own: a handle
  is not its value. A generic over `T: Shape` takes `?f`, which lends
  the frozen value as a `?T`, and calls its `?@` methods; nothing
  reaches a `!@` or `<@` method through it.
- Freezing a bounded `T` is checked at each instance, as a fact no API
  names.
- `*{Shape}` counts as a `*T` does and stays with its task. A value many
  tasks read is a `*Frozen[T]` while its type is known; one whose type
  is erased is Stage 5's case, checked where the type is erased, as
  `^{Job + Sends}` is.

**Public generics state their bounds.** A `pub` generic, a function or
a type, names by bounds everything its body does with each type
parameter that an API names; the error carries the fix. The bounds a
signature's types require are implied: a parameter named in
`Map[K, V]`, or in the field of a type bounded so, is `K: Hash` without
saying it, whether or not it has bounds of its own. An API of a
program's own is never implied: its witness is a compile-time parameter
of the declaration, which writes it. A private generic keeps
per-instance checking, since its author sees every instance, and facts
no API names stay per instance everywhere. The error is at the
parameter, with the bounds to write, `` `pub fun sum[T]` adds `T`s:
write `[T: Num]` ``, and `tools/state-bounds.py` writes each bound from
the compiler's own fixes.

**Lowering.** A call through a bound is a direct call. Each
conformance has one witness, a namespace declared beside it, whose
members name the type's methods and the defaults it takes:
`__rig_impl_Shape_Square` in the type's module for a header, and
`__rig_impl_Shape_Int` in the API's module for an addition. Each bound
on an API of a program's own adds one compile-time parameter, its
witness, after the type it bounds, to the declaration that states it: a
function, a method's own brackets, or a generic type. The call is
written `W_T_Shape.area(rig.selfArg(W_T_Shape.area, &x))`, where
`rig.selfArg` gives self as the method takes it, a pointer or a copy. A
type provides an API once in the program, so its witness follows from
it: `Bag[Square]` is one Zig type, `Bag(Square,
__rig_impl_Shape_Square)`, with the witness among its arguments, and
its methods, its own `print` among them, find the witness in the type.
Instances stay one per type, so code size does not change. A default
is a generic function of the API's module, checked once as
`describe[Self: Shape](?@)`, and written in a namespace of the API's
defaults, `__rig_defaults_Shape(Self, W_Self_Shape)`, which each witness
that takes a default names. An addition's methods are written in its
witness, the first of them when it gives several APIs. Two names that
would be the same in one module, of two APIs named `Shape` or of the
types `geo_Circle` and `geo.Circle`, are told apart by their place
(`__rig_impl_Shape_Square_1`, `W_T_Shape_1`). A type parameter with no
bound has no witness to give, so it meets no bound by an API. The built-in bounds take no witness: the
runtime's `rig.eql`, `rig.hash`, and `rig.compare` still serve them.
Every method call records how it dispatches, `direct`, `static`, or
`dynamic` (Stage 4's), and `rig check --facts=sema` prints it; in `rig
emit` the three read `x.area()`, `W.area(x)`, and `s.vt.area(s.ptr)`. A
call on a `T` with no bound, which Zig resolves at each instance, is
`direct`.

**The errors a reader meets first**, each with its fix:

```text
`Shape` is an API, not a type: write `[T: Shape]` for one type known when compiling, or `?{Shape}` for any type at run time
`T` has no method `area`: `total[T]` gives `T` no bound; write `[T: Shape]`, which declares `area`
`total[Label]` cannot use `T = Label`: `total` needs `T: Shape`, and `Label` does not provide `Shape`; declare `obj Label: Shape`
`Square` provides `Shape` but has no method `area`; declare `fun area(?@) -> Float` in `Square`
`Counter.next` takes `self` as `?@`, but `Source` declares `next(!@)`; a method meets its API with the same self: write `fun next(!@) -> Item?`
`Log.watch` keeps `s`, but `Watcher.watch` keeps nothing: a call through `Watcher` would end the loan on `s` while `Log` still views it; add `keeps s` to `Watcher.watch`
`c.area()` could call `Shape.area` or `Region.area`, which both apply to `geo.Circle`; name the API: `Shape.area(c)`
`Disk.size` fails with `Int!Io`, but `Sized` declares `size(?@) -> Int!Bad`; a method meets its API with the same set: write `-> Int!Bad`
`Pool` provides `Job`, which builds on `Sends`, but `Pool` cannot be sent to another task: its field `cache` is a `*Cell[List[Int]]`
`add` names a type, and `?Square` is a view: write `add Square: Shape`
`filter` is `pub`, so it states what its body does with `E`: it copies an `E`; write `[E: Copy]`
```

Those built so far, each from a program that meets it:

```rig reject
api Shape
  fun area(?@) -> Float

fun total(x: Shape) -> Float
  1.0

sub main()
  print(1)
```

```error
`Shape` is an API, not a type: write `[T: Shape]` for one type known when compiling, or `?{Shape}` for any type at run time
```

```rig reject
api Shape
  fun area(?@) -> Float

add Int: Shape
  fun area(?@) -> Float
    Float(@)

fun total[T](x: ?T) -> Float
  x.area()

sub main()
  n = 3
  print(total(?n))
```

```error
`T` has no method `area`: `total[T]` gives `T` no bound; write `[T: Shape]`, which declares `area`
```

```rig reject
api Shape
  fun area(?@) -> Float

obj Label
  text: Int

fun total[T: Shape](x: ?T) -> Float
  x.area()

sub main()
  print(total(?Label(text: 1)))
```

```error
`total[Label]` cannot use `T = Label`: `total` needs `T: Shape`, and `Label` does not provide `Shape`; declare `obj Label: Shape`
```

```rig reject
api Shape
  fun area(?@) -> Float

obj Square: Shape
  side: Float

sub main()
  print(Square(side: 1.0).side)
```

```error
`Square` provides `Shape` but has no method `area`; declare `fun area(?@) -> Float` in `Square`
```

```rig reject
api Source
  fun next(!@) -> Int?

obj Counter: Source
  n: Int

  fun next(?@) -> Int?
    @n

sub main()
  print(Counter(n: 1).n)
```

```error
`Counter.next` takes `self` as `?@`, but `Source` declares `next(!@)`; a method meets its API with the same self: write `fun next(!@) -> Int?`
```

```rig reject
api Watcher
  sub watch(!@, s: ?String)

obj Log: Watcher
  seen: ?String

  sub watch(!@, s: ?String) keeps s
    @seen = s

sub main()
  print(1)
```

```error
`Log.watch` keeps `s`, but `Watcher.watch` keeps nothing: a call through `Watcher` would end the loan on `s` while `Log` still views it; add `keeps s` to `Watcher.watch`
```

```rig reject
api Shape
  fun area(?@) -> Float

api Region
  fun area(?@) -> Float

add Int: Shape + Region
  fun area(?@) -> Float
    Float(@)

sub main()
  c = 3
  print(c.area())
```

```error
`c.area()` could call `Shape.area` or `Region.area`, which both apply to `Int`; name the API: `Shape.area(c)`
```

```rig reject
error Bad
  empty

error Io
  lost

api Sized
  fun size(?@) -> Int!Bad

obj Disk: Sized
  n: Int

  fun size(?@) -> Int!Io
    @n

sub main()
  print(1)
```

```error
`Disk.size` fails with `Int!Io`, but `Sized` declares `size(?@) -> Int!Bad`; a method meets its API with the same set: write `-> Int!Bad`
```

```rig reject
api Job: Sends
  fun cost(?@) -> Int

obj Pool: Job
  cache: *Cell[List[Int]]

  fun cost(?@) -> Int
    1

sub main()
  print(1)
```

```error
`Pool` provides `Job`, which builds on `Sends`, but `Pool` cannot be sent to another task: its field `cache` is a `*Cell[List[Int]]`
```

```rig reject
api Shape
  fun area(?@) -> Float

obj Square
  side: Float

add ?Square: Shape
  fun area(?@) -> Float
    1.0

sub main()
  print(1)
```

```error
`add` names a type, and `?Square` is a view: write `add Square: Shape`
```

## Stage 4: API objects *(built, but for associated types)*

*Built:* the braces in a type, the rules on what they name, a bare
`{Shape}` rejected as unsized (written or inferred), the bounds an
object meets, and which methods a call through one reaches, with why
for those it does not
([phase1-notes.md](../history/records/2026-10/apis-stage4/phase1-notes.md));
the views, `?{Shape}` and `!{Shape}`: the erasure, lent by the lend
table's last row and recorded once; calls through a table, typed and
checked by the API's declaration and clauses; the copy of a plain read
view, local to its block; and the oracle's second opinion on each
([phase2-notes.md](../history/records/2026-10/apis-stage4/phase2-notes.md));
the boxes, `^{Shape}`: a `^T` moved in keeping its allocation, its drop
through the table and the drop queue, `<@` methods that end the box,
`Clone` and `Print` entries, loans to the drop, `Owned`'s no-loan
homes, and no default value
(SPEC, "API objects";
[phase3-notes.md](../history/records/2026-10/apis-stage4/phase3-notes.md)).
An object of an API with an associated type, `^{Source[Item: Int]}`,
waits for a program that needs it (phase 5).

An **API object** is a value of some type that provides an API, the
type chosen when the program runs. It is written as the API in braces,
behind a view or a box. Its ownership rules are CORE's, approved before
any code (CORE §4, "An API object hides its value's type, never its
loans"); this section follows them and designs the rest:

```text
api Shape
  fun area(?@) -> Float

  fun describe(?@) -> String              # a default
    String("a shape of area ", @area())

fun area_of(s: ?{Shape}) -> Float
  s.area()                                # an indirect call, through the table

sub main()
  sq = Square(side: 2.0)
  print(area_of(sq))                      # lends `?{Shape}`, unmarked like any read
  shapes: List[^{Shape}] = List()
  !shapes.push(^Square(side: 3.0))        # boxed where the `^` is written
  c = ^Circle(r: 1.0)
  !shapes.push(<c)                        # a `^Circle` moved in, its allocation kept
  for s in ?shapes
    print(s.describe())
```

An object is made from a conformance, and its table from that
conformance's witness: each entry calls the method the witness names, a
type's own, an addition's, or a default. So everything Stage 3 checks
of a conformance (the same self, parameters, names, result, and set;
`from` and `keeps` within the API's) holds of every object made from
it, and a call through an object is checked as a call through a bound
is.

**The braces.** `{Shape}` reads as set notation: some member of the set
of types that are `Shape`. Braces hold only APIs, so `{T}` of a type
parameter and `{Square}` of a type are errors. A bare `{Shape}` has no
size of its own and is rejected toward `?{Shape}` or `^{Shape}`. The
holding sigils keep their meanings, so no new rule is needed for them:

| Form | Is | Methods callable | Copies |
|---|---|---|---|
| `?{Shape}` | a read view | `?@` | yes, as a read view does |
| `!{Shape}` | a write view | `?@`, `!@` | never |
| `^{Shape}` | a box, an owner | `?@`, `!@` (through `!b`), `<@` (`<b.m()` frees the box) | `+b` only with `Clone` (below) |

Only a `^{Shape}` has a `+`: `+s` of a `?{Shape}` or a `!{Shape}`
would make a value of no size of its own, and is rejected.

The braces name one API of a program's own, which may build on others,
and beside it the built-in APIs an object serves itself: `Owned`,
checked where the type is erased, and `Print` and `Clone`, each an
entry of the table, `^{Shape + Owned + Print}`. An object has one
table, so two APIs of a program's own are joined by name first,
`api Both: Shape + Named`, then `?{Both}`. `Copy` is rejected in the
braces, since each form copies or not by its own kind; so are `Eq`,
`Hash`, and `Ord`, since two objects may hide two types, which `==`
and `<` cannot compare; and the number APIs, which only numbers
provide. `Sends` and `Syncs` are Stage 5's.

Braces mean nothing else in Rig, outside string escapes, so they cannot
be misread. Anywhere but a type, a brace keeps its message, "Rig has no
braces: a block is the lines indented under its header". A map or set
literal, if Rig ever has one, sits in an expression, where a type never
does.

**Making one.** At an expected type, by an ordinary lend or move. The
lend table gains one row: a value of a type that provides `Shape` lends
`?{Shape}` to read and `!{Shape}` to write. The rows compose as they do
today, so `?b` of a `^Square`, `?h` of a `*Square`, and `?f` of a
`*Frozen[Square]` lend a `?{Shape}` of the value they reach, and `?b`
of a `^{Shape}` lends the `?{Shape}` it holds. A box is made by moving
one in: `<c` of a `c: ^Square`, where a `^{Shape}` is expected, keeps
its allocation, and `^Square(side: 3.0)` and `^<sq` box a new one
where the `^` is written. A bounded `T` erases through its witness, as
it calls through it; a `T` with no bound has none, so it erases to no
object, as it meets no bound by an API (Stage 3). The built-in APIs in
the braces are checked here, where the type is still known:
`^{Shape + Owned}` of a `Note` holding a `?String` is rejected. No
sigil marks the erasure; the braces in the expected type do. Only
the value a lend or a move reaches is erased, never a place's or an
element's type: a `!^Square` is never a `!^{Shape}`, through which
`b = ^Circle(r: 1.0)` would write a `Circle` into a `^Square`. One
object form never converts to another API's: a `?{Named}` is not a
`?{Shape}`, even where `Named` builds on `Shape`.

**What a call through an object can reach.** Each method of the API and
of those it builds on, defaults included, except one that takes
compile-time parameters of its own (types, values, or sets, which each
call passes and a table cannot) or names `Self` anywhere but self (a
`?Self` parameter, a `-> Self` result), which the hidden type alone
could give. Every API method takes self, so none is left out for
lacking one. The rest of the API forms objects; calling a method left
out says why, and that it is called through a bound. One function
decides which methods an object reaches and in which order, and the
table's entries follow it.

**Calls.** `s.area()` through an object is checked against the API's
declaration, `Self` hidden: how it takes self, each parameter by the
API's names, `once`, its result and how it fails, and its `from` and
`keeps`, which every implementation is within. Self goes by its sigil,
as the form allows: a `?{Shape}` reaches `?@` methods, a `!{Shape}` and
`!b` of a `^{Shape}` reach `!@` ones too, and `<b.m()` of a `^{Shape}`
reaches `<@` ones, taking the value out and freeing the box first, as
`<b.m()` of any box does; it ends the box, which is dropped exactly
once, even if the method fails. `Shape.area(s)` names the API, as
through a bound, where two APIs an object's API builds on both declare
`area`.
Every call through an object records the dispatch fact `dynamic`, with
the method's place in the table.

**How a method fails through an object.** As through a bound: with the
API's set, union, or `T!`, which every implementation declares the
same, so an entry has one type whatever type is erased to it. `!`
passes the set on into a frame whose set holds it, and `catch |e|`
gives `e` the API's set, matched without `_` when it is a declared one.
A set with fields reaches the caller through the slot, as from any call
that may fail with fields: an entry for a fallible method takes the
slot, as a callable view of a fallible function does
([SPEC, Generic sets](../../SPEC.md#generic-sets)), and gives it to the
method where the method takes one. A method with a set parameter of
its own, `fun each[E](...)`, is called through a bound.

**Associated types.** An API that declares `type Item` forms objects
only with the type named in the braces, `^{Source[Item: Int]}`, the
spelling kept for it ("The words"): each entry then has one type, and
a conversion checks that what the conformance gives `Item` is that
type. `Iter` is the same: `!{Iter[Item: Int]}` advances an iterator of
any type through its table's `next`. Without the type named, an object
of such an API is rejected with the spelling.

**What a call costs.** A load from a table in cache and an indirect
call: a few cycles, but no inlining, no constant folding, and no
vectorizing across it, the cost of a `?fun` call today. A drop of a
`^{Shape}` is always an indirect call, since the type is gone. In
numeric code, prefer a bound.

**Rules that keep it sound:**

- Through a `!{Shape}` a program only calls methods. Assigning to it
  (`w = c`, `w += x`), swapping, moving out of it, and reading its value
  into a binding (`x = w`, which copies or moves a value of a known
  type) are rejected: the value it views may be of another type, and
  its size is not known. `!b` of a `b: ^{Shape}` may still replace the
  whole box, `b = ^Circle(r: 1.0)`.
- A method a call through an object cannot reach is rejected at the
  call, with the reason; the rest of the API is callable.
- A call through an object uses the API method's `from` and `keeps`,
  which every implementation is within, never an implementation's own:
  neither the erased type's `from @field` nor `Iter`'s rule for a view
  result applies. An owned closure is the case of one method with no
  clauses, so today's closure rules are unchanged.
- An object carries every loan the value carried, and since the type
  is hidden it may hold anything: a view, a handle, a `drop` body. So
  the loans of a `?{Shape}` or `!{Shape}` end at its last use, and
  those of a `^{Shape}` at its drop, which may read them.
  `^{Shape + Owned}` holds no view, checked at the erasure, and goes
  where no loan may: an owned closure's environment. It may still hold
  a handle, so the error, freezing, and crossing rules reject it where
  a handle may not go: an error set's field, an actor's state, the
  value of a `*Frozen`.
- An erasure needs an address. Erasing a read view of plain data, or
  of a type parameter's value, views a local of the erasing block: a
  copy of the value, decided by kind, never by the size at which
  `rig.ReadView` passes a view as a copy, so whether a program compiles
  never turns on a size. The object carries a loan on that local, so
  it never leaves the block, returned or stored beyond it (a loop's
  pass is a block, so objects kept across passes are rejected too), and
  the error says to lend the owner where it lives, or to take a
  `?{Shape}`. An object of a generic `?T` therefore cannot be returned.
  A temporary lent as an object is a temporary of its statement, as any
  lent temporary is (CORE §3).
- An object meets only the `Clone`, `Print`, and `Owned` its braces or
  API name, each checked on the value's type where it is erased. It
  meets no other built-in bound, and none is forwarded through its view
  or box: `Map[?{Shape}, Int]` is rejected, since a `?{Shape}` is not
  `Hash`. Bounds never widen from one object type to another, and a
  marker supertrait never makes an object form `Copy` or crossing:
  each form copies or moves by its own kind. `Print` and `Clone` are
  each a table entry. A generic body's `print(x)` of a `T` is held to
  `Print` at an object instance too.
- No value that holds a task or a set of tasks is erased: `task.isolate`,
  an error's field, and a crossing see a task only where its type shows
  it.
- `{Shape}` is never a type argument, written or inferred: a generic
  `put[T](a: !T, b: !T)` called with two `!{Shape}`s is rejected, or
  it could swap a `Circle` into a `Square`. A `List[^{Shape}]` takes
  `^{Shape}`, a sized owner, and is fine.
- An object has no default value, since a zero object has no table to
  call through: `Table[^{Shape}, n]`, a `T()` at `T = ^{Shape}`, and a
  `resize` that fills are rejected; write `^{Shape}?`.
- An object meets no bound by an API: `T = ^{Shape}` does not meet
  `[T: Shape]`, and the error says to take a `?{Shape}`. A call on a `T`
  with no bound (Stage 1) at an instance whose `T` is an object is
  rejected, as at a built-in type.
- An object is never frozen: whether a value can be frozen is a fact of
  its type's parts, gone with the type. Freeze the value first; `?f` of
  the `*Frozen[Square]` lends a `?{Shape}`.
- An API object goes to no task in this stage, a local one included:
  its hidden value may hold what goes to none, an owned closure or a set
  of tasks, so a task over a call through one (`s.area()&`), a task
  given or lent one, a channel send, an actor's argument, and
  `par.each` reject it. Crossing is a bound in the braces (Stage 5).
- A closure captures an object as it captures any view or owner, and an
  owned closure takes a `^{Shape}` only with `+ Owned`. A closure is
  never erased to an object, since a function value provides no API of
  a program's own. A closure parameter of an API method, `once`
  included, passes through its entry untouched.

**Frozen values and Stage 5.** A `*Frozen[T]` stays a handle to a value
whose type is known, read by many tasks; it lends a `?T`, which erases
as any read view of its value does, inside one task. Stage 4 has no
counted object: an erased value many tasks read, and `*{Shape}` itself,
are Stage 5's, their crossing checked where the type is erased.

**Lowering.** An API object is a fat pointer, `{ptr, vt}`, sixteen
bytes, with one static table per API and type. The API's module writes
the table's type beside its defaults, `__rig_table_Shape`: one function
per method an object reaches, in the order that decides them, then the
drop a box needs and the `print` and `clone` an object serves. A
compile-time function of that module, `__rig_table_Shape_of(T, W)`,
gives the table of type `T` by its witness `W`, and Zig makes it once
per type and only where a conversion names it. Each entry is a small
function: it casts `ptr` to `T` and calls `W.area(rig.selfArg(W.area,
p))`, the witness's member, as a call through a bound does, passing the
arguments and, where the method takes one, the slot; Zig takes no
address of an inline function, so the method stays inlinable everywhere
else. A `<@` entry moves the value out of the box and frees it first.
`?{Shape}` is `rig.ApiView(__rig_table_Shape, .read, "")`, `!{Shape}`
its `.write` form, and `^{Shape}` `rig.ApiBox(__rig_table_Shape, "")`,
the string the built-in APIs its braces name, for `$name`, whose
drop is the table's: the value's drop and the free, through the queue a
`^T` uses, so long chains are released without deep recursion. A
conversion writes `.{ .ptr = &sq, .vt = __rig_table_Shape_of(Square,
__rig_impl_Shape_Square) }`, and a call `s.vt.area(s.ptr)`, the third of
the shapes `rig emit` shows. A pointer to the table inside each value
would change the layout of plain data, and is not used. Emit writes
each from facts: the erasure, the dispatch, and the methods an object
reaches.

**The errors a reader meets first**, each with its fix:

```text
`{Shape}` has no size of its own: hold it behind a view or a box, `?{Shape}`, `!{Shape}`, or `^{Shape}`
braces hold APIs, and `Square` is a type: write `?Square` for a view of it, or name an API it provides, `?{Shape}`
`{Shape + Named}` names two APIs of a program's own, and an object has one table: declare `api Both: Shape + Named` and write `?{Both}`
`area_of(?l)` cannot lend `l` as a `?{Shape}`: `Label` does not provide `Shape`; declare `obj Label: Shape`
`Shape.scale` takes compile-time parameters, which a call through `?{Shape}` cannot pass: call it through a bound, `[T: Shape]`
cannot assign through `w`, a `!{Shape}`: the value it views may be of another type; call its methods, or hold a `^{Shape}` and replace the box
`Note` is erased to `^{Shape + Owned}`, which holds no loan, but its field `text` is a `?String`
`+b` makes a new owner, and a `^{Shape}` is not cloned: its type is erased; write `^{Shape + Clone}`, or build `Shape` on `Clone`
`?{Shape}` of `p` views a copy held in this block, since `Point` is plain data, so it cannot leave the block; lend the owner where it lives, or take `p: ?{Shape}`
`Source` declares `type Item`, so an object of it names that type: `^{Source[Item: Int]}`
```

## Stage 5: shared objects, and crossing tasks *(in part)*

*Phase 1 is built:* crossing bounds in the braces and the API, checked
where the type is erased, each form crossing by its row, and no owned
closure holding a task
([phase1-notes.md](../history/records/2026-10/apis-stage5/phase1-notes.md)).
`*{Shape}` and `~{Shape}` (phase 2) and owned closures as objects
(phase 4) are not built yet.

*Designed and approved (2026-10-23).* The owner: "Approve
the Stage 5 CORE text as written in core-stage5/6-final.md and #615's
design defaults (with the reviewer's three fixes). Build Stage 5 in
phases with adversarial reviews; land each after the suite and light
gate." Its ownership rules are CORE §4's paragraph "A shared API object
counts a value of hidden type", *(planned)*, revised by a Core panel
([core-panel/](../history/records/2026-10/apis-stage5/core-panel/))
from the draft in
[core-draft.md](../history/records/2026-10/apis-stage5/core-draft.md);
the phases are in
[build-plan.md](../history/records/2026-10/apis-stage5/build-plan.md),
and what this section decides by default is in
[open-questions.md](../history/records/2026-10/apis-stage5/open-questions.md).
It builds on Stage 4's tables, erasure, and boxes.

Stage 5 adds the last two holding forms of an API object, `*{Shape}`
and `~{Shape}`, and lets every form cross tasks by a bound in its
braces:

```text
api Shape
  fun area(?@) -> Float

api Job: Sends + Owned                  # every Job may go to another task, and holds no loan
  fun run(?@) -> Int

fun area_of(s: *{Shape + Syncs}) -> Float
  s.area()

sub main()
  s: *{Shape} = *Square(side: 2.0)      # a counted handle, made where the `*` is written
  t = +s                                # a new count, through the table
  w = ~s                                # its weak handle, a `~{Shape}`
  print(t.area())                       # `?@` methods only, as through any handle
  f: *{Shape + Syncs} = *Frozen(Square(side: 3.0))
  a = area_of(+f)&                      # counted atomically, so read by many tasks
  b = area_of(+f)&
  print(>a + >b)
  jobs: List[^{Job}] = List()           # `Job` builds on `Sends`, so each box may go to a task
```

Who needs it: a value of hidden type kept by several owners in one
task (a tree's nodes with weak parents, listeners registered in several
places, a registry of plugins), and an erased value many tasks read (a
configuration, a set of rules compiled once). A `*Frozen[T]` already
gives the second for a value whose type is known; `*{A + Syncs}` gives
it for one whose type is erased.

### `*{Shape}`, a shared object

A counted handle to a value of some type that provides `Shape`. It is
made, as every object is, at an expected type, where the type is still
known:

- `<h` of a `h: *Square` moves the handle in and keeps its allocation,
  and `+h` adds a count first;
- `*Square(side: 2.0)` and `*<sq`, written where a `*{Shape}` goes, make
  the allocation there;
- a frozen value's handle, `*Frozen(Square(side: 2.0))` or a
  `*Frozen[Square]`, becomes only a `*{Shape + Syncs}`, whose counts are
  atomic (below), never a `*{Shape}`.

A handle is erased only as it moves or counts, never through a view:
`!sq` lent as a `!*{Shape}` would let a `Circle` be written into a
`*Square`, and a `?*Square` read as a `?*{Shape}` would read eight
bytes as sixteen. Nothing else becomes one. An actor's or a channel's handle does not:
their methods are messages, not the value's. A box does not: `*<b` of a
`^{Shape}` would move a value whose size is erased, so a value is shared
before it is erased. A holding sigil over a held object is rejected, as
over any held value (CORE sentence 8): `*^{Shape}`, `^*{Shape}`.

It is a handle, so it only reads (CORE sentence 8):

- a call through it reaches the API's `?@` methods; a `!@` or `<@`
  method is rejected, with the fix: hold a `^{Shape}`, or change the
  value through a `Cell` it holds;
- `?s` lends the `?{Shape}` it holds, by the `*T` row of the lend table,
  at no cost (the same two words); `!s` lends the handle itself, as `!h`
  of a `*T` does;
- `+s` adds a count, never a clone, so `Clone` in its braces is
  rejected; `<s` moves it; a drop gives a count back, and the last one
  drops the value;
- `Print` and `Owned` in its braces are checked on the value where it is
  erased, as for every object.

A type that holds a `Cell` lives only behind `*` (CORE sentence 9), so
`*{A}` is the one object such a type makes. Its `?@` methods change the
Cell by a marked call, as through a `*T`; that is how a shared object
changes.

**Its table holds the count operations.** A `Shared`'s layout, and
whether its counts are atomic, depend on the hidden type, so a
`*{Shape}` cannot count inline as a `*Square` does. The object is
`{ptr, vt}`, sixteen bytes, as every object is; `ptr` is the address of
the value inside its counted allocation, so `?s` is the same two words
and every method entry is the one views and boxes call. The table gains
the entries of the allocation: share (`+s`), drop (a count given back,
the last dropping the value through the drop queue a `*T` uses), and
the weak ones (make, clone, drop, and upgrade a weak handle). Each
reaches the counts from the value's address by the allocation's layout.

**The holding follows from the braces.** A `*{Shape}` holds a `*T`'s
allocation and counts plainly; a `*{Shape + Syncs}` holds a frozen
value's and counts atomically; neither becomes the other, so atomicity
is never checked per instance. A `*Square` erases with the entries of
`Counted(Square, false)`, a `*Frozen[Square]` with those of
`Counted(Square, true)`. The compiler picks the table,
`__rig_table_Shape_of(T, W, holding)`, and nothing at run time asks:
one table per API, type, and holding (a box, a `*T`'s allocation, a
frozen value's), made by Zig only where a conversion names it. Under
`api Shape: Syncs`, every `*{Shape}` is a `*{Shape + Syncs}`, so it
takes only a frozen value, and the error names the API.

**What it costs.** A call through a `*{Shape}` costs what a call
through a `?{Shape}` does: the same entry. `+s` and a drop are an
indirect call to an entry, a few cycles more than the inline count of a
`*T`, and atomic only in a `*{Shape + Syncs}`.
Phase 2 measures both against a `*T` (`bench/apis`).

### `~{Shape}`, a weak one

`~s` of a `*{Shape}` makes a `~{Shape}`; `*w` gives a `*{Shape}?`, a
new count while the value lives and `none` after; `+w` makes another
weak handle. It exists only for a `*{Shape}` that does not sync, so its
counts are always plain, and it never crosses, so its braces are its
handle's without a crossing bound. `~` of a `*{Shape + Syncs}` is
rejected, as a frozen value has no weak handle: an upgrade on one core
would race the atomic last drop on another. It carries the loans its
`*{Shape}` carries, so `*w` never gives a count that has escaped them.

### Crossing tasks: a bound in the braces

`Sends` and `Syncs` join `Owned`, `Print`, and `Clone` among the
built-in APIs braces may name. Like `Owned`, each is a fact of the
hidden value, checked where its type is erased, by the classifier that
decides it for every type (`sema.crossingBlocker`). An API that builds
on one gives it to every object of the API, since Stage 3 checks it at
every type that provides the API: `^{Job}` of `api Job: Sends` is
`^{Job + Sends}`. Then each form crosses by its own row of SPEC §18's
table, with the hidden value as its `T`:

| Form | sends: may go to another task | syncs: may be read by several at once | Its braces may name |
|---|---|---|---|
| `?{A}` | when the value syncs | when the value syncs | `Syncs` |
| `!{A}` | when the value sends | never | `Sends` |
| `^{A}` | when the value sends | when the value syncs | `Sends`, `Syncs` |
| `*{A}` | never | never | `Syncs`, making it the next row |
| `*{A + Syncs}` (a frozen value's) | yes | yes | no `Owned`: a frozen value holds no view |
| `~{A}` | never | never | neither |

A bound a form cannot use is rejected toward the one it can, so each
meaning has one spelling: `?{Shape + Sends}`, `!{Shape + Syncs}`,
`*{Shape + Sends}`, and a crossing bound in a `~{...}`. A bound the API
names that a form cannot use is no error: it describes the value, and
`?{Job}` of `api Job: Sends` does not cross.

**A shared object crosses by its count.** `*{A + Syncs}`, written or
by its API, takes only a frozen value's handle, which counts
atomically and whose value never changes. A `*Square` erased to one is
rejected toward freezing it, and in a generic body only a
`*Frozen[T]` erases to one, never a `*T` whose `T` syncs. `Owned` in
its braces is rejected, so it has one spelling.

**Where it is checked.** At the erasure, where the type is known, as
`Owned` is: the hidden value against the bounds, by `crossingBlocker`,
the error naming the part that keeps it from crossing. In a generic
body, a `T` erases to `^{Shape + Sends}` only under `[T: Shape +
Sends]`, and the error names the bound to add. After the erasure,
nothing looks at the hidden type again: an object crosses by its
braces alone.

**What goes where.** The rules for tasks, channels, actors, and `par`
are unchanged; objects meet them by the table above:

- A task's argument: `work(<j)&` gives it a `^{Job + Sends}`;
  `total(?b)&` lends it a `^{Shape + Syncs}` to read; `area_of(+f)&`
  gives it a `*{Shape + Syncs}`.
- A channel's element moves and holds no view, so it is
  `*Chan[^{Job + Sends + Owned}]`, or `*Chan[^{Job}]` of an
  `api Job: Sends + Owned`. `Sends` never implies `Owned`: a task keeps
  the loans of what it is given, but a channel, an actor's state, and
  an owned closure keep none.
- An actor's state holds `^{Job + Sends + Owned}` fields; its methods
  take boxes that send and read views of what syncs, and give results
  that send, as for any type.
- `par.map(?xs, f)` reads a `List[^{Shape + Syncs}]` from every task, and
  `par.each(!xs, f)` hands out the elements of a `List[^{Shape +
  Sends}]`; a closure written there captures an object by the same rows.
- A frozen value may hold `*{A + Syncs}` handles, which are other
  frozen values' (CORE sentence 9), so `*Frozen(List[*{Plugin +
  Syncs}])`, a shared plugin registry, works. It holds no other
  object: a box or a view that syncs may hold a one-word `*Cell`,
  which changes. The erased value many tasks read is a frozen value
  erased, `*{A + Syncs}`: freeze first, then erase.
- `task.isolate` and `task.supervise` take and give objects by these
  rules and their own.

**An object without the bound goes to no task, a local one included**
(open question 13). The hidden value may hold an owned closure, which
SPEC keeps from every task, a local one too, because its type does not
show its captures; an object hides more. Stage 4's phase 3 lets an
object go to a local task, so a `^{Shape}` hiding an owned closure
reaches two local tasks at once. Approved: closed with this rule, at
any depth of what the task is given, which narrows Stage 4's approved
open question 14. Its cost is recorded as a limit: a GUI's render task,
`render(?root)&` over a `*{Widget}` tree, is rejected, though a
`*Widget` tree, or a frozen `*{Widget + Syncs}` tree, works.

**An object never hides a task or a set of tasks** (open question 14).
A task is bound to the scope that waits for it, and an erased drop
would hide that wait: `task.isolate(|| mk())` gives a `^{Shape}`
hiding a task started inside it, which isolate rejects for any value
whose type shows one. Approved: rejected at the erasure, naming the
field. **No owned closure holds a task either:** `*|<t| 7` in an object
left `task.isolate` (probed), since `holdsTask` read no captures; a
closure's captures are now walked, and a type parameter by its
instance (`Requirement.no_task`).

### Owned closures as one-method objects

Today an owned closure, `*fun(A) -> R`, is a `*` handle to a
`rig.Closure`, which holds the environment's address, its call, and
its drop: two allocations per closure (the environment and the counted
closure), and a call loads the function from the counted one. Once
`*{...}` exists, the same value can be a shared object of one method:
one counted allocation of the environment, and a handle `{ptr, vt}`
whose static table holds the call, the drop, and the counts. The
language does not change: `*fun` keeps its type, its rules, and its
crossing (never), and `~fun` is its weak handle.

The cost, measured on the Mac with Stage 4 phase 3's compiler, release
build: making an owned closure, calling it once, and dropping it takes
11.1 ns, against 4.6 ns for a `*` object of one field (one allocation)
and 4.3 ns for a box. So the second allocation and its indirection cost
about 6 ns, and one allocation would make a closure about 45% faster to
make and drop; a call is unchanged (a load from a table in cache, then
the indirect call, where today the load is from the heap); a handle
grows from 8 bytes to 16. Default: build it last, as its own phase,
kept only if `bench/closures` (a closure made per element) clears the
speed bar on both machines and Trig is not slower. Trig makes its 10
owned closures once, at start-up, so it gains nothing measurable, and
its emitted Zig changes: Trig is told before it lands.

### The error slot and associated types

As in Stage 4. A `*{A}`'s method entries are those views and boxes
call, so a fallible method's entry takes the slot, `!` passes the API's
set on, `catch |e|` gives `e` the API's set, and a method with a set
parameter of its own is called through a bound. An API with `type Item`
forms `*{Source[Item: Int]}` with the type named, built with Stage 4's
phase 5, and is rejected with that spelling until then; a crossing
bound follows it, `^{Source[Item: Int] + Sends}`.

### Rules that keep it sound

- Crossing is decided once, at the erasure, where the type is known;
  after it, an object crosses by its braces and its API alone.
- An object without the bound a task needs goes to no task; one with it
  goes as its form's row says.
- No object, and no owned closure, hides a task or a set of tasks.
- A `*{A}` only reads; it carries the loans of what it holds, as a `*T`
  does, until its last count is dropped, and its `~{A}` the same; `+
  Owned` carries none, and a `*{A + Syncs}` holds a frozen value,
  which holds no view.
- The holding follows from the braces: a `*{A}` holds a `*T`'s
  allocation, a `*{A + Syncs}` a frozen value's.
- No form becomes another: a `^{A}` is never a `*{A}`, a `*{A}` never a
  `^{A}`, and a `*{A}` never a `*{A + Syncs}`, nor back.
- A handle is erased only as it moves or counts, never through a view.
- A `~{A}` never crosses, and a `*{A + Syncs}` has no weak handle.
- A Cell of an object is rejected by the Cell's own rule: its value
  copies and holds no loan (`Copy + Owned`), and no object is both, as
  a view copies but carries a loan and a box owns but moves. Stage 4's
  "Stage 5" message for it gives way to that one.

### Lowering

`*{Shape}` is `rig.ApiShared(__rig_table_Shape, builtins)` and
`~{Shape}` `rig.ApiWeak(__rig_table_Shape, builtins)`, beside
`rig.ApiView` and `rig.ApiBox`. A conversion writes
`.{ .ptr = &h.value, .vt = __rig_table_Shape_of(Square,
__rig_impl_Shape_Square, .shared) }`; `+s` writes
`s.vt.__rig_share(s.ptr)`; `?s` writes `s.read()`, the same two words;
a call `s.vt.area(s.ptr)`, as through a view. A crossing bound changes
no Zig: it is a check. Emit writes each from facts: the erasure (now
with its holding), the dispatch, and the methods an object reaches.

### The errors a reader meets first

```text
`*Square` is erased to `*{Shape + Syncs}`, which several tasks read, but its count is not atomic: freeze the value, `*Frozen(...)`
`<j` is given to a task, and `^{Job}` hides its value's type without naming `Sends`: write `^{Job + Sends}`
`Note` is erased to `^{Job + Sends}`, which goes to other tasks, but its field `cache` is a `*Map[String, Int]`, whose count is not atomic
a read view goes to another task when its value syncs: write `?{Shape + Syncs}`
a shared handle goes to another task when several tasks may read its value: write `*{Shape + Syncs}`
`*{Shape}` only reads, as any handle: `grow` takes `!@`; hold a `^{Shape}`, or change the value through a `Cell` it holds
`*<b` would move a value whose type is erased: share the value before erasing it, `*<sq` where a `*{Shape}` goes
`~f` of a `*{Shape + Syncs}`: a frozen value has no weak handle
a frozen value's handle is erased only to `*{Shape + Syncs}`, which counts atomically: write `*{Shape + Syncs}`
`*{Shape + Syncs}` holds a frozen value, which holds no view: take `Owned` out of the braces
`Runner` is erased to `^{Shape}`, but its field `t` is a `Task[Int]`, and an API object never hides a task: wait for it first, or keep it beside the object
```

## What each checker and proof adds

| Stage | Compiler | Reference checker (`test/oracle`) | Lean model (`formal/`) |
|---|---|---|---|
| 1 | per-instance typing of the call; the function-value ownership rule | the same rule, read from the call's facts | nothing |
| 2 | bounded parameters held to their bounds; marker facts | computes the marker facts itself; a copy of a bounded `T` needs `Copy` | `Copy` only of plain kinds |
| 3 | conformance, coherence, clauses within the API's by position, the same failure as the API's; one dispatch fact per call | conformance clauses checked on its own; a call through a bound read with the API's clauses | a subsumption lemma, proved: a call checked against wider clauses is sound for any callee within them (formal/LambdaRig/Calls.lean: `within_live` for loans, both clauses; `api_calls_run` for programs whose calls take read views) |
| 4 | object facts; the erasure's lend; no assignment through `!{...}`; a dynamic call checked with the API's clauses; an object of a plain view's copy stays in its block | object facts computed itself; a dynamic call read with the API's clauses from its dispatch fact; abstains only on what is not built | erasing a type keeps its loans, and a box of erased type keeps them to its drop |
| 5 | count operations in the table, chosen by the hidden allocation at erasure; crossing bounds checked at erasure by `crossingBlocker`; an object without one goes to no task; no object hides a task | crossing facts of objects computed from their braces and API; a `*{A}` carries its value's loans to its last count | crossing obligations: an object checked at erasure holds no value that stays on one thread, so `confined` still holds |

## Alternatives considered

- **Extending duck typing to every operation** (Zig, C++): kept, for a
  parameter with no bound, in Stage 1. Alone it leaves signatures
  silent and lets two methods of one name meet by accident.
- **Structural APIs** (Go): any type with the methods provides the API.
  Rejected for a program's own APIs: accidental conformance, and no home for
  defaults or associated types. Built-in capabilities are structural,
  as derived facts.
- **Conformance in `impl` blocks only** (Rust): a type's methods split
  across blocks. The header says what a type is; `add` is for the
  two cases it cannot.
- **A `where` clause**: every bound fits in the brackets.
- **API objects spelled bare** (`?Shape`): reads as a concrete type and
  hides the cost. **`dyn`**: jargon. **`Dyn[Shape]`**: brackets would
  hand an API to a type with no values of its own. **`any`**: a word
  where the mantra wants a mark, since dispatch is a mechanic. Braces
  won.
- **`Sends` and `Syncs` for the task bounds**: the sigils `<` and `*`
  name moves and sharing within a task, and a bound that reused the
  words would read as them. The bounds name crossing to other tasks, so
  they are `Sends` and `Syncs`, Rust's `Send` and `Sync`, which mean
  the same: `List[*Node]` moves with `<` but is not `Sends`, and a
  `*<Node(...)` is shared by `*` but is not `Syncs`.
- **Requiring bounds on every generic**: 300 to 500 of the suite's
  generics would change, for no reader a private generic has. Only
  `pub` generics must state their bounds.
- **API objects now**: enums and closures cover today's programs.
