# Many types, one contract

Here is a Python program that adds up the area of some shapes:

```python
class Square:
    def __init__(self, side): self.side = side
    def area(self): return self.side * self.side

class Circle:
    def __init__(self, r): self.r = r
    def ares(self): return 3.0 * self.r * self.r

shapes = [Square(2), Circle(1)]
print(sum(s.area() for s in shapes))
```

The typo in `ares` waits until the loop reaches a circle, then raises
`AttributeError`. Nothing said that a shape must have an `area`, so
nothing could check it sooner. Go and Rust fix this with an interface
or a trait: a named contract that each type signs. Rig calls it an
API, and checks every signature where it is written.

[Write it once, for every type](07-generics.md) bounded a type
parameter by the built-in APIs, `[T: Ord]`. This chapter writes APIs
of its own, gives them to types written elsewhere, and keeps values of
many types in one list.

## A contract with a name

`api` declares what a type must do:

```rig
api Shape
  fun area(?@) -> Float

  fun describe(?@) -> String
    String("a shape of area ", @area())

obj Square: Shape
  side: Float

  fun area(?@) -> Float
    @side * @side

obj Circle: Shape
  r: Float

  fun area(?@) -> Float
    3.0 * @r * @r

  fun describe(?@) -> String
    String("a circle of radius ", @r)

fun total[T: Shape](shapes: ?List[T]) -> Float
  t = 0.0
  for s in shapes
    t += s.area()
  t

sub main()
  squares = List([Square(side: 1.0), Square(side: 2.0)])
  print(total(squares), total(List([Circle(r: 1.0)])))
  print(squares[1].describe())
  print(Circle(r: 2.0).describe())
```

```output
5.0 3.0
a shape of area 4.0
a circle of radius 2.0
```

`api Shape` names two methods. `area` has no body, so every type that
provides `Shape` must declare it. `describe` has one, a default, written
only in terms of the API's own methods. A type may keep it, as `Square`
does, or write its own, as `Circle` does.

`obj Square: Shape` says that `Square` provides `Shape`, on the line
that declares it. An API holds no fields and no state, only methods.

`[T: Shape]` bounds `total` by the API. The body may call what `Shape`
names, and each call must pass a type that provides it. The bound
names exactly what the body needs, so `total`'s reader learns the
contract from its signature.

The Python typo is now a compile error, at the type that broke the
contract:

```rig reject
api Shape
  fun area(?@) -> Float

obj Circle: Shape
  r: Float

  fun ares(?@) -> Float
    3.0 * @r * @r
```

```error
`Circle` provides `Shape` but has no method `area`; declare `fun area(?@) -> Float` in `Circle`
```

A type that does not name `Shape` is rejected where a call needs it,
with the fix:

```rig reject
api Shape
  fun area(?@) -> Float

obj Point
  x: Int

fun total[T: Shape](shapes: ?List[T]) -> Float
  t = 0.0
  for s in shapes
    t += s.area()
  t

sub main()
  print(total(List([Point(x: 1)])))
```

```error
`total[Point]` cannot use `T = Point`: `total` needs `T: Shape`, and `Point` does not provide `Shape`; declare `obj Point: Shape`
```

## A contract for a type you did not write

`Int` is declared by Rig, so its header cannot name a new API. `add`
gives it one:

```rig
api Weight
  fun grams(?@) -> Int

  fun heavy(?@) -> Bool
    @grams() > 1000

add Int: Weight
  fun grams(?@) -> Int
    @

obj Parcel: Weight
  kg: Int

  fun grams(?@) -> Int
    @kg * 1000

fun total[T: Weight](xs: ?List[T]) -> Int
  t = 0
  for x in xs
    t += x.grams()
  t

sub main()
  print(total(List([250, 1500])), total(List([Parcel(kg: 2)])))
  n = 1500
  print(Weight.heavy(n), Parcel(kg: 1).heavy())
```

```output
1750 2000
true false
```

`add Int: Weight` reads "add `Weight` to `Int`". Its methods belong to
the API, not to `Int`, so `n.heavy()` is not an `Int` method. The call
names the API instead, `Weight.heavy(n)`. Through a bound, `x.grams()`
reaches either kind.

An addition is written in the API's module. A type provides an API
once in the whole program, so two libraries never give `Int` two
meanings of `grams`.

## A contract with a type in it

Some APIs name a type that each provider chooses. The built-in one a
`for` loop walks is `Iter`: a type that declares `next(!@) -> T?`
provides it, and its `Item` is that `T`:

```rig
use std.iter

obj Countdown
  n: Int

  fun next(!@) -> Int?
    return none if @n == 0
    @n -= 1
    @n + 1

fun largest[I: Iter, I.Item: Ord + Copy](it: !I) -> I.Item?
  best = (!it).next() ?? return none
  for x in !it
    best = x if x > best else best
  best

sub main()
  for x in Countdown(n: 3)
    print(x)
  c = Countdown(n: 4)
  print(iter.sum(!c) ?? 0)
  d = Countdown(n: 5)
  print(largest(!d) ?? -1)
```

```output
3
2
1
10
5
```

`Countdown` names no API. Declaring `next` is enough, so a `for` loop
walks it. `I.Item` is the item type of whatever iterator `largest` is
given, and `I.Item: Ord + Copy` bounds it as its own entry in the
brackets. `iter.sum` is written the same way, with `I.Item: Num`. An
API of a program's own declares such a type with `type Item`
([SPEC, APIs](../../SPEC.md#apis)).

## Giving `==` a meaning of its own

The built-in APIs `Eq`, `Hash`, `Ord`, and `Print` work the same way.
An object compares, hashes, and prints by its fields. A type that names
one of them on its header writes the method that gives its own
meaning. Here tags compare without regard to case:

```rig
use std.text

obj Tag: Eq + Hash + Print
  name: String

  fun eq(?@, other: ?Tag) -> Bool
    a = ?@name[..]
    b = ?other.name[..]
    return false if a.len != b.len
    for i in 0..a.len
      return false if text.to_lower(a[i]) != text.to_lower(b[i])
    true

  sub hash_into(?@, h: !Hasher)
    for b in ?@name[..]
      !h.add(text.to_lower(b))

  sub print(?@, out: !Printer)
    !out.text("#")
    !out.text(?@name)

sub main()
  counts: Map[Tag, Int] = Map()
  for word in ["Rig", "zig", "RIG", "rig"]
    t = Tag(name: String(word))
    n = counts.get(?t) ?? 0
    !counts.put(<t, n + 1)
  print(counts.len, counts.get(?Tag(name: String("rig"))))
  print(Tag(name: String("Zig")), Tag(name: String("a")) == Tag(name: String("A")))
```

```output
2 3
#Zig true
```

Each API fixes its method's signature. `eq` decides `==`. `hash_into`
feeds the parts of the hash to a `Hasher`, which mixes them. `print`
writes through a `Printer`. `Map`, `==`, and `print` then call these
methods, for a `Tag` alone and inside any other value.

`Ord` is given the same way, with `order`, which gives `.less`,
`.equal`, or `.greater`. Here the most urgent job sorts first:

```rig
use std.sort

obj Job: Ord
  priority: Int
  name: ?String

  fun order(?@, other: ?Job) -> Order
    other.priority.order(?@priority).then(@name.order(?other.name))

sub main()
  jobs = [Job(priority: 1, name: "lint"), Job(priority: 3, name: "deploy"), Job(priority: 3, name: "build")]
  sort.sort(!jobs)
  for j in jobs
    print(j.priority, j.name)
```

```output
3 build
3 deploy
1 lint
```

Comparing `other` to `@` reverses the order, and `a.then(b)` breaks a
tie by `b`. `sort.sort` is generic, `sort[T: Ord]`, and `<` calls the
same method.

A hash that disagrees with `==` would lose keys, so a type with its own
`==` and no `hash_into` is never hashed:

```rig reject
obj Tag: Eq
  name: String

  fun eq(?@, other: ?Tag) -> Bool
    @name.len == other.name.len

sub main()
  counts: Map[Tag, Int] = Map()
  print(counts.len)
```

```error
`Map[Tag, Int]` cannot use `K = Tag`: `Tag` declares its own `==`, so it cannot be hashed by its fields; write `sub hash_into(?@, h: !Hasher)`
```

## Many kinds in one list

Every instance of `total` has one `T`. A list of squares and circles
together needs a type that covers both. An enum with payloads is one,
for a closed set of kinds. For an open set, braces hide the type:

```rig
api Shape
  fun area(?@) -> Float
  sub grow(!@, by: Float)

obj Square: Shape
  side: Float

  fun area(?@) -> Float
    @side * @side

  sub grow(!@, by: Float)
    @side += by

obj Circle: Shape
  r: Float

  fun area(?@) -> Float
    3.0 * @r * @r

  sub grow(!@, by: Float)
    @r += by

fun area_of(s: ?{Shape}) -> Float
  s.area()

sub main()
  shapes: List[^{Shape}] = List()
  !shapes.push(^Square(side: 2.0))
  !shapes.push(^Circle(r: 1.0))
  for s in !shapes
    !s.grow(1.0)
  for s in shapes
    print(area_of(s))
  sq = Square(side: 5.0)
  print(area_of(sq))
```

```output
9.0
12.0
25.0
```

`{Shape}` is an **API object**: a value of some type that provides
`Shape`, chosen as the program runs. It has no size of its own, so a
sigil always says how it is held, as for any value. `^{Shape}` is a box
that owns one, so `List[^{Shape}]` holds squares and circles together.
`?{Shape}` is a read view of one, and `!{Shape}` a write view.

`area_of(sq)` lends a plain `Square` as a `?{Shape}`, with no box and
no copy. `!s.grow(1.0)` changes each shape through its box, marked as
any write is. A method that takes `<@` ends the box it is called on:

```rig
api Shape
  fun area(?@) -> Float
  fun close(<@) -> Float

obj Square: Shape
  side: Float

  fun area(?@) -> Float
    @side * @side

  fun close(<@) -> Float
    print("closing")
    @side

sub main()
  b: ^{Shape} = ^Square(side: 2.0)
  print(b.area())
  print(<b.close())
```

```output
4.0
closing
2.0
```

`<b.close()` moves the box into the call, which drops it exactly once,
even if the method fails.

A call through an object finds the method in a table, one per type and
API, and calls it. That is one indirect call, the price of not knowing
the type. A call through a bound, `[T: Shape]`, costs nothing: it is
direct. So the braces mark where the cost is.

## An object keeps its loans

An API object hides the value's type, never its loans. A `?{Shape}`
made from an element of a List keeps the List lent, as a `?Square`
would:

```rig reject
api Shape
  fun area(?@) -> Float

obj Square: Shape
  side: Float

  fun area(?@) -> Float
    @side * @side

sub main()
  v: List[Square] = List()
  !v.push(Square(side: 1.0))
  s: ?{Shape} = ?v[0]
  !v.push(Square(side: 2.0))
  print(s.area())
```

```error
cannot lend `v` to write while a read loan is live
```

The push could move the List's elements, and `s` would read freed
memory. Since the type is hidden, the object may hold anything: a
view, a handle, a `drop` body. So a view's loans last to its last use,
and a box's to its drop, and no lifetime is ever written.

## Shared objects

`*{Shape}` counts a value of hidden type, as `*T` counts one of a known
type. `~{Shape}` is its weak handle:

```rig
api Shape
  fun area(?@) -> Float

obj Square: Shape
  side: Float

  fun area(?@) -> Float
    @side * @side

  drop(!@)
    print("square dropped")

sub main()
  s: *{Shape} = *Square(side: 2.0)
  t = +s
  w = ~s
  print(t.area())
  <s
  if *w as h
    print("alive", h.area())
  <t
  if *w as h
    print("alive", h.area())
  else
    print("gone")
```

```output
4.0
alive 4.0
square dropped
gone
```

`*Square(...)` makes the counted value where a `*{Shape}` is expected.
`+s` adds a count, and `~s` makes a weak handle. `*w` gives a new count
while the value lives and `none` after. The last count's drop runs
`Square`'s `drop`.

Like every handle, a shared object only reads. A `!@` method is
rejected through one, with the two ways out:

```rig reject
api Shape
  fun area(?@) -> Float
  sub grow(!@, by: Float)

obj Square: Shape
  side: Float

  fun area(?@) -> Float
    @side * @side

  sub grow(!@, by: Float)
    @side += by

sub main()
  s: *{Shape} = *Square(side: 2.0)
  !s.grow(1.0)
```

```error
`*{Shape}` only reads, as any handle: `grow` takes `!@`; hold a `^{Shape}`, or change the value through a `Cell` it holds
```

## Objects and tasks

The compiler decides for each type whether its value may go to another
task ([Concurrency without async](04-concurrency.md)). An object hides
its type, so the decision is made where the type is still known, and
written in the braces: `Sends` to be given to a task, `Syncs` to be
read by several at once. An object that names neither goes to no task.

A value many tasks read is frozen first, then erased:

```rig
api Shape
  fun area(?@) -> Float

obj Square: Shape
  side: Float

  fun area(?@) -> Float
    @side * @side

fun area_of(s: *{Shape + Syncs}) -> Float
  s.area()

sub main()
  f: *{Shape + Syncs} = *Frozen(Square(side: 3.0))
  a = area_of(+f)&
  b = area_of(+f)&
  print(>a + >b)
```

```output
18.0
```

`*{Shape + Syncs}` holds a frozen value, whose count is atomic and
whose contents never change, so `+f` goes to any task. An API may build
on a crossing bound, `api Job: Sends`, and then every `Job` object
carries it.

## What the compiler makes

`rig emit` shows both kinds of call. For the first program of this
chapter, cut to the lines that matter:

```zig
pub fn total(comptime T: type, comptime W_T_Shape: type, shapes: *const rig.List(T)) f64 {
    ...
}

    rig.print(.{ total(Square, __rig_impl_Shape_Square, &squares), " ", total(Circle, __rig_impl_Shape_Circle, ...), "\n" });
```

The bound becomes a second compile-time argument, a struct holding
`Square`'s methods for `Shape`. Zig makes one `total` per type, and
each call inside it is direct.

An object is two words, the value's address and its type's table:
`rig.ApiView`, `rig.ApiBox`, and `rig.ApiShared` for a view, a box,
and a shared handle. The table is a Zig struct of function pointers,
made once for each API and type a program erases.

## The whole idea, on one table

| You write | It means |
|---|---|
| `api Shape` | a named set of methods: required ones, and defaults |
| `obj Square: Shape` | `Square` provides `Shape`, checked where it is written |
| `add Int: Shape` | `Int` provides `Shape`, written in the API's module |
| `[T: Shape]` | a bound: direct calls, and each instance must provide it |
| `obj Tag: Eq + Hash` | `==` and hashing get the type's own meaning, everywhere |
| `?{Shape}`, `!{Shape}` | a view of a value of hidden type |
| `^{Shape}`, `*{Shape}`, `~{Shape}` | a box, a counted handle, a weak handle of one |
| `^{Job + Sends}`, `*{Shape + Syncs}` | an object that may go to a task, or be read by many |

**A bound checks a contract and costs nothing; braces hide the type,
keep its loans, and mark the one indirect call.**

## What is not there yet

An API may name a type each provider chooses, an associated type, as
the built-in `Iter` does for a loop's items
([SPEC, APIs](../../SPEC.md#apis)). An object of such an API,
`^{Source[Item: Int]}`, waits for a program that needs it. An owned
closure takes two allocations; making it a shared object of one
method, one allocation, is measured before it lands
([design/apis.md](../design/apis.md)).

## Where to go next

- [Tests that fail the same way twice](09-tests.md) is the next
  journey: tests for code like this, concurrent code included.
- [SPEC, APIs](../../SPEC.md#apis) and
  [API objects](../../SPEC.md#api-objects) state every rule, and
  [Bounds](../../SPEC.md#bounds) every built-in API.
- [CORE §4](../CORE.md) states the ownership of API objects.
- [design/apis.md](../design/apis.md) records the five stages of APIs
  and why each is shaped as it is.
