E = []
E.append((r'''A body that calls itself, or builds its own type, with its type''', r'''```rig
struct Track
  title: String

  drop(!self)
    print("free", self.title)

struct Shelf[T]
  items: Vec[T]

  sub add(!self, x: T)
    !self.items.push(<x)

  fun take(!self) -> T?
    !self.items.pop()

fun pick[T](a: T, b: T, first: Bool) -> T
  if first
    return <a
  <b

sub main
  t = pick(Track(title: "a"), Track(title: "b"), false)
  print("picked", t.title)
  s = Shelf[*Track](items: Vec())
  !s.add(*Track(title: "intro"))
  !s.add(*Track(title: "outro"))
  if !s.take() as last
    print("took", last.title)
  print("left", s.items.len, pick(1, 2, true))
```

```output
free a
picked b
took outro
free outro
left 1 1
free intro
free b
```

A body that calls itself, or builds its own type, with its type'''))
E.append((r'''```rig reject
fun max[T](a: T, b: T) -> T
  a if a > b else b

sub main
  print(max(true, false))
```

```error
`max[Bool]` cannot use `T = Bool`: the generic body applies `>` to `T`, which `Bool` does not support
`>` used on `T` here (ordering comparison)
```''', r'''```rig reject
struct Point
  x: Int

fun max[T](a: T, b: T) -> T
  a if a > b else b

fun larger[T](a: ?T, b: !T) -> Bool
  a > b

sub main
  n = 3
  m = 4
  print(larger(?n, !m), max(true, false))
  p = max(Point(x: 1), Point(x: 2))
  q = Point(x: 3)
  print(p.x, larger(?p, !q))
```

```error
`max[Bool]` cannot use `T = Bool`: the generic body applies `>` to `T`, which `Bool` does not support
`>` used on `T` here (ordering comparison)
`max[Point]` cannot use `T = Point`: the generic body applies `>` to `T`, which `Point` does not support
`larger[Point]` cannot use `T = Point`: the generic body applies `>` to `T`, which `Point` does not support
```'''))
# aliases: drop the UserId example (SYNTAX shows the form), extend the rule example
E.append((r'''`type Name = T` gives a type a second name. An alias is transparent: it
is the same type as `T`.

```rig
type UserId = Int

fun next(id: UserId) -> Int
  id + 1

sub main
  x: UserId = 5
  print(next(x))
```

```output
6
```

An alias names''', r'''`type Name = T` gives a type a second name. An alias is transparent: it
is the same type as `T`. An alias names'''))
E.append((r'''type P = Point
type C = Color

sub main
  p = P(x: 3, y: 4)
  o = P.origin()
  c = C.green
  print(p.x + o.x, c == .green)
```

```output
3 true
```''', r'''type P = Point
type C = Color
type Byte = U8

fun next(b: Byte) -> Int
  Int(b) + 1

sub main
  p = P(x: 3, y: 4)
  o = P.origin()
  c = C.green
  n = 300
  print(p.x + o.x, c == .green, Byte(n - 100), Byte.max, next(7))
```

```output
3 true 200 255 8
```'''))
