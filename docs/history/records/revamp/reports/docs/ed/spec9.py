E = []
E.append((r'''With `if ?o as x` and `if !o as x` ([§13](#13-optionals)), an optional
box is used where it is:''', r'''A recursive enum holds its children in boxes, and a function reads one
through a borrow of the box:

```rig
enum Expr
  num(n: Int)
  add(l: Box[Expr], r: Box[Expr])

fun eval(e: ?Box[Expr]) -> Int
  match e
    .num(n) => n
    .add(l, r) => eval(?l) + eval(?r)

fun num(n: Int) -> Box[Expr]
  Box(.num(n))

sub main
  e = Box(Expr.add(l: num(2), r: num(3)))
  print(eval(?e))
```

```output
5
```

With `if ?o as x` and `if !o as x` ([§13](#13-optionals)), an optional
box is used where it is:'''))
E.append((r'''A closure starts with its bar list and has no keyword. The list holds
the closure's **captures** and its **parameters**, captures first:

- an entry with a sigil captures an outer local: `+x` copies a Copy
  value or clones a handle, `<x` moves the binding in, `?x` and `!x`
  borrow it, `~x` holds a shared handle weakly;
- a bare name is a parameter, optionally annotated (`a`, `a: Int`);
- `||` is an empty list.

The body is an expression or an assignment on the same line
(`|!total, n| total += n`), or an indented block. A closure whose body
is an assignment ends a call's arguments: it is the last one.

```rig
sub main
  n = 10
  cell: *Cell[Int] = *Cell(0)
  plus_n = |+n, a: Int| a + n
  bump = |+cell| cell.set(cell.get() + 1)
  hello = || print("hello")
  bump()
  bump()
  hello()
  print(plus_n(5), cell.get())
```

```output
hello
15 2
```

A closure reaches''', r'''A closure starts with its bar list, which holds its **captures**, each
with a sigil, and then its **parameters**, bare names
([SYNTAX §11](SYNTAX.md#closures)). A closure reaches'''))
E.append((r'''call `!self` methods (`!w.push(x)` or `w.push(x)`), lend it on for a
call (`!w`),''', r'''call `!self` methods (`!w.push(x)`), lend it on for a
call (`!w`),'''))
E.append((r'''`a?` mirrors `e!` ([§14](#14-errors)): it is allowed only in a
function returning `T?` (or `T?!`), and not in a closure body or
deferred code.''', r'''`a?` mirrors `e!` ([§14](#14-errors)): it is allowed only in a
function returning `T?` (or `T?!`), or in a closure whose type returns
one ([§12](#parameters-and-results)), and not in deferred code.'''))
