E = []
E.append((r'''### if

```rig
sub main
  x = 5
  if x > 10
    print("big")
  else if x > 3
    print("medium")
  else
    print("small")
```

```output
medium
```

Conditions must be `Bool`.''', r'''The forms of each statement are in
[SYNTAX §10](SYNTAX.md#10-statements-and-control-flow); this section
says what they do.

### if

Conditions must be `Bool`.'''))
E.append((r'''A simple statement (a call, binding, `return`, `break`, or `continue`)
may end with `if cond`: it runs only when `cond` holds.

```rig
fun first_over(limit: Int) -> Int
  i = 0
  while i < 100
    i += 1
    break if i > limit
  return i

sub main
  x = 5
  print(x) if x > 3
  print(first_over(3))
```

```output
5
4
```

A guard ends a statement and applies to all of it: in
`n = parse(s) catch |e| f(e) if ready`, the guard covers the whole
binding, `catch` included, not the handler alone. Inside an
expression, write the ternary `a if c else b`.

```rig
error E
  bad

fun parse(s: String) -> Int!
  return E.bad if s == "x"
  s.len

sub main
  n = 5
  n = parse("x") catch |e| (-1 if e == E.bad else -2) if false
  print(n)
  n = parse("x") catch |e| (-1 if e == E.bad else -2) if true
  print(n)
```

```output
5
-1
```
''', r'''A simple statement (a call, a binding or assignment, a drop, `return`,
`break`, or `continue`) that ends with a guard, `if cond`, runs only
when `cond` holds. The guard covers the whole statement, a `catch`
handler included ([SYNTAX §10](SYNTAX.md#guards)).
'''))
E.append((r'''leaves the loop around this one. A loop can also yield a value
([Loops as values](#loops-as-values)).

```rig
sub main
  i = 0
  while i < 3 : i += 1
    continue if i == 1
    print(i)
  else
    print("done")
```

```output
0
2
done
```
''', r'''leaves the loop around this one. A loop can also yield a value
([Loops as values](#loops-as-values)).
'''))
E.append((r'''labeled too, and `break :name` leaves it. A label may repeat an
enclosing one's name; the innermost is meant.

```rig
sub main
  :outer for i in 0..3
    for j in 0..3
      continue :outer if j > i
      break :outer if i == 2
      print(i, j)
```

```output
0 0
1 0
1 1
```
''', r'''labeled too, and `break :name` leaves it. A jump after `??` or `catch`
may name a label too ([§13](#the-fallback-of-)). A label may repeat an
enclosing one's name; the innermost is meant.
'''))
E.append((r'''may not outlive what it borrows. The value must be used; a `break`
cannot carry a value out of a loop whose value is not.

```rig
fun index_of(xs: ?[4]Int, target: Int) -> Int
  for x, i in xs
    break i if x == target
  else
    -1

sub main
  xs = [3, 1, 4, 1]
  print(index_of(?xs, 4), index_of(?xs, 9))
  n = 27
  steps = 0
  last = while true
    break steps if n == 1
    n = n / 2 if n % 2 == 0 else 3 * n + 1
    steps += 1
  print(last)
```

```output
2 -1
111
```
''', r'''may not outlive what it borrows. The value must be used; a `break`
cannot carry a value out of a loop whose value is not.
'''))
E.append((r'''`match` selects the first arm whose pattern matches. It works on
enums, integers, and `Bool`.

| Pattern | Matches |
|---|---|
| `.name` | an enum variant |
| `.name(a, b)` | a payload variant, binding its fields in order |
| `42`, `-1`, `true` | a literal |
| `lo..hi` | an integer from `lo` up to, not including, `hi` (constant bounds) |
| `_` | everything else |
| any other name | everything else, binding the value to the name |
| `p, q` | any of the alternatives, which bind no names |
| `p if cond` | what `p` matches, when `cond` holds |

An arm is `pattern => statement` or a pattern followed by an indented
block. Every match must cover every value,''', r'''`match` runs the first arm whose pattern matches, and no other. It works
on enums, integers, `Bool`, and error values (`catch |err|`,
[§14](#naming-the-error)); [SYNTAX §12](SYNTAX.md#12-patterns) lists
the patterns. A range pattern's bounds are constants. Every match must
cover every value,'''))
E.append((r'''since which one matched would decide
what a name held, they bind none (`_` fills a payload field), and none
may be a catch-all.
''', r'''since which one matched would decide
what a name held, they bind none (`_` fills a payload field), and none
may be a catch-all.
'''))
E.append((r'''function exits with an error. A deferred body may not move or drop
outer bindings, or propagate with `!`. It runs after the values declared
after it are dropped, so it may not read one through a borrow.

```rig
sub main
  defer print("cleanup 1")
  defer
    print("cleanup 2")
  print("body")
```

```output
body
cleanup 2
cleanup 1
```
''', r'''function exits with an error. A deferred body may not move or drop
outer bindings, or propagate with `!`. It runs after the values declared
after it are dropped, so it may not read one through a borrow.
'''))
