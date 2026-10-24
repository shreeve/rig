# API objects: Core purist (1 of 4)

## §1: two rows widened

| **owning** | `List[T]`, `^T` (`^{A}` too), `String`, `error`, objects holding an owner | moves; one owner; dropped once | built; `^{A}` planned |
| **view** | `?T`, `!T` (`?{A}`, `!{A}` too), `[]T`, `![]T` | as today | built; `{A}` planned |

## §4: one row, last

| a `T` that provides `A` | `?{A}` | `!{A}` | planned |

## The paragraph (end of §4)

**An API object hides its value's type, never its loans.** `?{A}`, `!{A}`, and `^{A}` hold a value of some type that provides `A`. A value lends one by the row above, unwritten where its view lasts only for the use (sentence 4), and a `^T` moves into a `^{A}` as `<b`, keeping its box; either way it carries every loan the value carried (sentence 6; §5's holder rule). A call through one passes on only the loans the API's signature shows, in its `from` and `keeps` (sentence 7, as through a bound). The value's kind is hidden, so through a `!{A}` a program only calls methods: no bare use reads the value, and nothing assigns through it or swaps it (sentence 1; §6). A `^{A}`'s drop may run a `drop` body, so its loans last to its drop unless its braces say `Owned`, which holds none (sentence 6). Its `+` is the one its braces' `Clone` gives (sentence 2). A read view held as a copy (§9) becomes an API object of that copy, a local, so it is never returned or stored beyond its function (sentence 7). *(planned)*

```rig pending
api Shape
  fun area(?@) -> Float

obj Square: Shape
  side: Float

  fun area(?@) -> Float
    @side * @side

fun area_of(s: ?{Shape}) -> Float
  s.area()

sub main()
  sq = Square(side: 2.0)
  shapes: List[^{Shape}] = List()
  !shapes.push(^Square(side: 3.0))
  print(area_of(sq), area_of(shapes[0]))
```

```output
4.0 9.0
```

The reject is `rig pending` plus `error` until built (SPEC's precedent); in CORE it repeats `Shape` and `Square`:

```rig pending
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

## What it does not change

Loan kinds (sentence 5), drop points, temporaries (§3), replacing a box through `!b`, closures, crossing and freezing (Stage 5).

**Hazard:** CORE's "object" is an `obj` value, so always write "API object".
