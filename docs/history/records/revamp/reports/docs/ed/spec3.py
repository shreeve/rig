E = []
E.append((r'''`fun` declares a function that returns a value; `sub` declares one that
does not. The return type follows `->`, and a `fun` always has one: a
`fun` without `->`, or returning `Void`, is rejected in favor of a
`sub`. A `sub` that may fail is marked `!` after its parameters,
`sub save(n: Int)!`, and its type is `sub(Int)!`
([§14](#14-errors)). A function's value is its last
expression, or the value of a `return`. A function with no parameters
may leave out the empty `()`: `sub main` and `sub main()` are the same
declaration, and this reference writes the shorter one. A call always
has its parentheses, `greet()`: the name alone, `greet`, is the function
as a value.

```rig
fun area(w: Int, h: Int) -> Int
  w * h

fun sign(n: Int) -> Int
  return 1 if n > 0 else -1 if n < 0 else 0

sub report(label: String, n: Int)
  print(label, n)

sub main
  report("area", area(3, 4))
  report("sign", sign(-7))
```

```output
area 12
sign -1
```

Parameters are immutable,''', r'''`fun` declares a function that returns a value, and `sub` one that
does not ([SYNTAX §8](SYNTAX.md#functions)). A `fun` always has a
return type: a `fun` without `->`, or returning `Void`, is rejected in
favor of a `sub`. A `sub` marked `!`, `sub save(n: Int)!`, may fail,
and its type is `sub(Int)!` ([§14](#14-errors)). A function's value is
its last expression, or the value of a `return`. A call always has its
parentheses, `greet()`: the name alone is the function as a value.

Parameters are immutable,'''))
E.append((r'''`U8.max`), which means the same value at every call, in any module. A call passes arguments by position, in
parameter order (`scaled(3, 2)`); by keyword, in any order
(`scaled(by: 4, n: 5)`); or both, positional arguments first
(`scaled(3, by: 2)`). A parameter with a default may be left out
(`scaled(3)`). Each parameter gets exactly one argument, and every
parameter without a default needs one. Arguments are evaluated in the
order written.

```rig
fun scaled(n: Int, by: Int = 10, _: Bool = false) -> Int
  n * by

sub main
  print(scaled(3, 2), scaled(by: 4, n: 5), scaled(3, by: 2), scaled(3))
```

```output
6 20 6 30
```
''', r'''`U8.max`), which means the same value at every call, in any module. A
call passes arguments by position, by keyword, or both, positional
arguments first ([SYNTAX §11](SYNTAX.md#calls)). Each parameter gets
exactly one argument, and every parameter without a default needs one;
arity, keyword names, and argument types are checked. Arguments are
evaluated in the order written.
'''))
E.append((r'''A `struct` lists its fields, then its methods. It is constructed by
naming its fields: `Point(x: 1, y: 2)`. A struct with exactly one field
also takes it by position, as a one-field variant does:
`Meters(3.5)` is `Meters(value: 3.5)`, and so are the built-ins
`Box(x)`, `Cell(0)`, and `*Signal(0)`. A field may have a default
value, and a constructor may omit that field.''', r'''A `struct` lists its fields, then its methods. It is constructed by
naming its fields, `Point(x: 1, y: 2)`, and a struct with exactly one
field also takes it by position: `Meters(3.5)` is
`Meters(value: 3.5)`, as `Box(x)`, `Cell(0)`, and `*Signal(0)` are
([SYNTAX §11](SYNTAX.md#constructors)). A field may have a default
value, and a constructor may omit that field.'''))
E.append((r'''```output
3 anon 5 1 0 0
```

```rig
struct Point
  x: Int
  y: Int

  fun origin -> Self
    Point(x: 0, y: 0)

  fun plus(?self, other: ?Point) -> Point
    Point(x: self.x + other.x, y: self.y + other.y)

  sub shift(!self, dx: Int)
    self.x += dx

sub main
  p = Point.origin()
  q = Point(x: 1, y: 2)
  r = p.plus(?q)
  !r.shift(10)
  print(r, r.x)
```

```output
Point(x: 11, y: 2) 11
```
''', r'''```output
3 anon 5 1 0 0
```
'''))
E.append((r'''**Receiver sigils.** `?`, `!`, or `<` directly before a *place* (a
name followed by any `.field` or `[index]` steps) that is followed by
a method call applies to that place: `?P.m(args)` is `(?P).m(args)`,
`!P.m(args)` is `(!P).m(args)`, and `<P.m(args)` is `(<P).m(args)`.
Postfixes after that call apply to its result: `!v.pop()?`, and
`!a.b().c(x)` is `(!a).b().c(x)`. Writing `?` is optional, since a
read receiver is lent without it. Every other prefix sigil (`+`, `-`,
`*`, `~`), and `?`, `!`, or `<` with no method call after the place,
applies to the whole expression as before: `*Point.origin()` shares
the result, `+n.first()` clones it, `-a.len` negates it, `!x.v`
borrows the field, `<p.f` moves the field, and `?xs[0]` borrows the
element. With parentheses, `?(p.m())` borrows the call's result.

The short form is checked against the method:''', r'''A `?`, `!`, or `<` before a place and a method call marks the receiver:
`!v.push(x)` is `(!v).push(x)` ([SYNTAX §5](SYNTAX.md#receiver-sigils)).
Writing `?` is optional, since a read receiver is lent without it. The
short form is checked against the method:'''))
E.append((r'''```error
a write-borrowing call that returns `Bool` is written `(!t).insert(...)`, so it is never read as negation
```
''', r'''```error
a write-borrowing call that returns `Bool` is written `(!t).insert(...)`, so it is never read as negation
```

```rig
struct Set
  items: Vec[Int]

  fun insert(!self, k: Int) -> Bool
    for x in ?self.items
      return false if x == k
    !self.items.push(k)
    true

sub main
  set = Set(items: Vec())
  if (!set).insert(1)
    print("new")
  if not (!set).insert(1)
    print("seen")
  print(!set.insert(2))
```

```output
new
seen
true
```
'''))
