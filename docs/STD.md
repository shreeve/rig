# The Rig standard library

The standard library ships with the compiler. A program imports one of
its modules with `use std.NAME`, which names it `NAME`
([SPEC §14](../SPEC.md#14-modules)):

```rig
use std.math

sub main
  print(math.gcd(12, 18))
```

```output
6
```

Its modules are Rig code, under `std/` in the repository, checked like
any other module. The standard library is new: this page lists
everything it has.

| Module | What it offers |
|---|---|
| [`std.math`](#stdmath) | integer helpers |

## std.math

Integer helpers, written in Rig. Like the operators, they panic on
overflow.

| Function | Result |
|---|---|
| `abs(n: Int) -> Int` | `n` without its sign; panics on `Int.min` |
| `clamp(x: Int, lo: Int, hi: Int) -> Int` | `lo` when `x < lo`, `hi` when `x > hi`, else `x` |
| `gcd(a: Int, b: Int) -> Int` | the greatest common divisor, never negative; `gcd(0, 0)` is 0 |
| `pow(base: Int, exp: Int) -> Int` | `base` to the power `exp`; a negative `exp` gives 1 divided by `base` to the power `-exp`, truncated as `/` truncates |
| `mod(a: Int, b: Int) -> Int` | the floored remainder, with the sign of `b`; panics when `b` is 0 |
| `PI`, `E` | the Float constants |

```rig
use std.math

sub main
  print(math.abs(-7), math.clamp(15, 0, 10), math.clamp(-3, 0, 10))
  print(math.gcd(-12, 18), math.gcd(0, 0))
  print(math.pow(3, 4), math.pow(2, -1), math.pow(-1, -3))
  print(-7 % 3, math.mod(-7, 3), math.mod(7, -3))
  print(math.PI > 3.14, math.E < 2.72)
```

```output
7 10 0
6 0
81 0 -1
-1 2 -2
true true
```
