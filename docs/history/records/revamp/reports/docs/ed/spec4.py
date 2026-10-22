E = []
E.append((r'''An `enum` lists variants. A variant may carry an explicit integer value
or payload fields, and an enum may have methods. A variant is written
`.name` where the enum type is known, or `Type.name`.

```rig
enum Shape
  circle(radius: Int)
  rect(w: Int, h: Int)
  point

  fun area(?self) -> Int
    match self
      .circle(r) => 3 * r * r
      .rect(w, h) => w * h
      .point => 0

enum Status
  ok = 200
  missing = 404

sub main
  s: Shape = .rect(w: 2, h: 5)
  c: Shape = Shape.point
  d = Shape.circle(1)
  print(s.area(), c.area(), d.area(), s)
  st: Status = .missing
  print(st == .missing)
```

```output
10 0 3 .rect(w: 2, h: 5)
true
```

A payload variant is constructed with keyword fields, like a struct:
`.rect(w: 2, h: 5)`, `Shape.rect(w: 2, h: 5)`. A variant with exactly
one field also takes it by position, as a pattern binds it:
`.circle(2)` is `.circle(radius: 2)`. A variant or struct with more
fields sets them by name. A pattern binds
the fields in order (`.circle(r) =>`). Enums have no constructor call
(`Shape(...)` is an error); enums compare with `==` ([§6](#operators)). A plain enum's variants may take''', r'''An `enum` lists variants, which may carry an explicit integer value or
payload fields, and may have methods ([SYNTAX §8](SYNTAX.md#enums)). A
variant is named `.name` where the enum type is known, or `Type.name`.
A payload variant is constructed with its fields named, like a struct,
and a variant with exactly one field also takes it by position:
`.circle(2)` is `.circle(radius: 2)`. A pattern binds the fields in
order (`.circle(r) =>`). Enums have no constructor call (`Shape(...)`
is an error), and compare with `==` ([§6](#operators)). A plain enum's variants may take'''))

E.append((r'''```output
42 answer
.some(value: 2.5) 3 x .nothing 0
```
''', r'''```output
42 answer
.some(value: 2.5) 3 x .nothing 0
```

A value parameter sizes a field's array and reads as a value in a
method; an instance's value argument may be arithmetic on constants,
and a constructor infers it from an array field:

```rig
LIMIT = 2

struct Ring[T, n: Int]
  items: [n]T
  head: Int = 0

  sub put(!self, x: T)
    self.items[self.head % n] = x
    self.head += 1

  fun cap(?self) -> Int
    n

sub main
  r = Ring(items: [3 of 0])
  !r.put(7)
  s: Ring[Int, LIMIT * 2] = Ring[Int, 2 + 2](items: [1, 2, 3, 4])
  print(r.items, r.cap(), s.cap())
```

```output
[7, 0, 0] 3 4
```
'''))

E.append((r'''A call gives every compile-time argument in brackets
(`max[Float](1, 2)`), or none, and then its type arguments are
inferred by matching each parameter's type against its argument's type
(`T`, `?T`, `!T`, `*T`, `~T`, `T?`, `[]T`, `[N]T`, `Wrap[T]`,
`fun(T) -> U`, `?fun(T) -> U`). A method's receiver gives its type's
parameters. Every argument must agree, and an argument whose type does
not have its parameter's shape is a type mismatch. A closure literal
argument is matched last: its parameters take the types the other
arguments give its parameter's function type, and the type its body
returns binds what only the result mentions, so
`map(?names[..], |s| s.len)` of
`fun map[T, U](xs: []T, f: ?fun(?T) -> U) -> Vec[U]` is
`map[String, Int]`. A parameter no argument other
than a literal gives a type takes one from the type expected of the
call's result, where there is one (a typed binding, parameter, field,
or assigned place, a `return` from a function or from a closure whose
result type is given, and the last expression of either), by matching
the declared result against it the same way; a result lifted into an
expected `T?` or `T!` is matched against the `T`, a propagated or
caught `T!` against its value, and the left of `??` against an optional
of the expected type. So `z: U8 = max(1, 2)` is `max[U8]`. A generic
function call that is an argument of another, and whose result is a
type parameter only literals gave a type (directly, or propagated with
`!` or `?`), takes the type that call gives it: `max(max(1, 2), small)`
with `small: U8` is `max[U8]` twice. One whose result is an optional
that nothing but `none` gave a type (`nothing()`, `id(none)`) binds
like `none`, so `z: Int? = id(nothing())` is `id[Int?]`. A nested call
with a result of another shape (`Wrap.make(1)`, `Opt.some(1)`)
keeps the type its own arguments give it; naming the outer call's type
arguments (`Wrap[Wrap[U8]].make(...)`, `id[Opt[U8]](...)`) passes the
expected type on. Only then does a literal take its default type, and
among literals alone a float literal gives `Float`: `max(3, 2.5)` is
`max[Float]`. An argument that is not a literal keeps
the type it gives, even where the result is expected to have another.
An integer compile-time value that a parameter's or the result's type
holds, as an array length (`[n]T`) or a generic type's value argument
(`Ring[T, n]`), is inferred the same way: `sum([1, 2, 3])` of
`fun sum[n: Int](xs: [n]Int)` is `sum[3]`, and `a: [3]Int = zeros()`
of `fun zeros[n: Int] -> [n]Int` is `zeros[3]`. It takes exactly the
length the argument's type has; arguments that give it different ones
conflict, and the value must fit the parameter's type. Any other
compile-time value is never inferred, so a function that takes one is
always called with brackets, and so is one with a type parameter
neither its arguments nor the expected type determine (one used only in
the result where no type is expected, or given only `none` or a
`.variant`).''', r'''A call gives every compile-time argument in brackets
(`max[Float](1, 2)`), or none. With none, they are inferred in this
order:

1. **From the arguments.** Each parameter's type is matched against
   its argument's type (`T`, `?T`, `!T`, `*T`, `~T`, `T?`, `[]T`,
   `[N]T`, `Wrap[T]`, `fun(T) -> U`, `?fun(T) -> U`), and a method's
   receiver gives its type's parameters. Every argument must agree, and
   an argument whose type does not have its parameter's shape is a type
   mismatch. An argument that is not a literal keeps the type it gives,
   even where the result is expected to have another.
2. **From closure literals**, matched after the other arguments: a
   closure's parameters take the types the other arguments give its
   parameter's function type, and the type its body returns binds what
   only the result mentions, so `map(?names[..], |s| s.len)` of
   `fun map[T, U](xs: []T, f: ?fun(?T) -> U) -> Vec[U]` is
   `map[String, Int]`.
3. **From the expected result.** A parameter that only literals give a
   type takes one from the type expected of the call's result, where
   there is one (a typed binding, parameter, field, or assigned place,
   a `return` from a function or from a closure whose result type is
   given, and the last expression of either), by matching the declared
   result against it the same way. A result lifted into an expected
   `T?` or `T!` is matched against the `T`, a propagated or caught `T!`
   against its value, and the left of `??` against an optional of the
   expected type. So `z: U8 = max(1, 2)` is `max[U8]`.
4. **Through nested calls.** A generic call that is an argument of
   another, and whose result is a type parameter only literals gave a
   type (directly, or propagated with `!` or `?`), takes the type that
   call gives it: `max(max(1, 2), small)` with `small: U8` is
   `max[U8]` twice. One whose result is an optional that nothing but
   `none` gave a type (`nothing()`, `id(none)`) binds like `none`, so
   `z: Int? = id(nothing())` is `id[Int?]`. A nested call with a result
   of another shape (`Wrap.make(1)`, `Opt.some(1)`) keeps the type its
   own arguments give it; naming the outer call's type arguments
   (`Wrap[Wrap[U8]].make(...)`, `id[Opt[U8]](...)`) passes the expected
   type on.
5. **From literals.** Only then does a literal take its default type,
   and among literals alone a float literal gives `Float`:
   `max(3, 2.5)` is `max[Float]`.

An integer compile-time value that a parameter's or the result's type
holds, as an array length (`[n]T`) or a generic type's value argument
(`Ring[T, n]`), is inferred the same way: `sum([1, 2, 3])` of
`fun sum[n: Int](xs: [n]Int)` is `sum[3]`, and `a: [3]Int = zeros()`
of `fun zeros[n: Int] -> [n]Int` is `zeros[3]`. It takes exactly the
length the argument's type has; arguments that give it different ones
conflict, and the value must fit the parameter's type. Any other
compile-time value is never inferred, so a function that takes one is
always called with brackets, and so is one with a type parameter that
none of these determine (one used only in the result where no type is
expected, or given only `none` or a `.variant`).'''))

E.append((r'''```output
7 200 3.0 2.0 2
s true
drop 2
kept 1
6 0 [0, 0, 0]
drop 1
```
''', r'''```output
7 200 3.0 2.0 2
s true
drop 2
kept 1
6 0 [0, 0, 0]
drop 1
```

```rig
fun max[T](a: T, b: T) -> T
  a if a > b else b

fun empty[T] -> Vec[T]
  Vec()

fun id[T](a: T) -> T
  a

fun nothing[T] -> T?
  none

fun half[T](x: T) -> T
  x / 2

sub main
  small: U8 = 200
  v: Vec[Int] = empty()
  !v.push(3)
  o: Int? = id(nothing())
  print(v.len, max(max(1, 2), small), o)
  f: Float = half(7)
  print(half(7), f, max(half(7), 2.5))
```

```output
1 200 none
3 3.5 3.5
```
'''))
