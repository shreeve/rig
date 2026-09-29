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
any other module. What Rig cannot do itself, a module declares in an
`extern zig` block: functions with full Rig signatures, implemented by
a small Zig file beside the module on Zig's standard library
([SPEC §15](../SPEC.md#zig-backed-declarations)). A call to one is
checked like any call. The standard library is new: this page lists
everything it has.

| Module | What it offers |
|---|---|
| [`std.math`](#stdmath) | integer helpers, and Float functions |

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

Float functions, from Zig's. They follow IEEE 754: a result out of
range is an infinity, and an undefined one (the square root of a
negative number) is NaN, which equals nothing, itself included.

| Function | Result |
|---|---|
| `sqrt(x: Float) -> Float` | the square root |
| `floor(x: Float) -> Float` | the largest whole number not above `x` |
| `ceil(x: Float) -> Float` | the smallest whole number not below `x` |
| `exp(x: Float) -> Float` | e to the power `x` |
| `ln(x: Float) -> Float` | the natural logarithm |
| `sin(x: Float) -> Float`, `cos(x: Float) -> Float` | the sine and cosine of `x` radians |
| `pow_f(x: Float, y: Float) -> Float` | `x` to the power `y` |

```rig
use std.math

sub main
  print(math.sqrt(2.0) > 1.414, math.floor(-2.5), math.ceil(-2.5))
  print(math.exp(0.0), math.ln(math.E))
  print(math.cos(math.PI), math.pow_f(2.0, 0.5) == math.sqrt(2.0))
  print(Int(math.floor(7.9)))
```

```output
true -3.0 -2.0
1.0 1.0
-1.0 true
7
```
