# Rig on one page

Rig is an indented language whose sigils show who owns a value and who may change it.

## Sigils at a glance

| Meaning | Before a value | Before a type |
|---|---|---|
| lend to read / read view | `&x` | `&T` |
| lend to write / write view | `@x` | `@T` |
| move (alone on a line: drop now) | `<x` | |
| clone | `+x` | |
| share / shared handle | `*S(...)` | `*T` |
| negate | `!x` | |

| Meaning | After a type | After a value |
|---|---|---|
| optional / pass `none` up | `T?` | `e?` |
| may fail / pass a failure up | `T!` | `e!` |

## Reading and writing

- A bare argument is read: `total(v)` means `total(&v)`. The callee
  may look at `v` but not change it.
- Every change is marked. `bump(@n)` lets `bump(n: @Int)` change `n`;
  a method that changes its receiver is called `@v.push(3)`.
- A write call whose result is used is written the same way:
  `x = @v.pop()`, `if @v.pop() as x`.
- `&` in a binding makes a lasting view: `r = &v[0]` keeps looking at
  `v[0]`. While `r` is used later on, `v` may not change, move, or drop.
- A value has any number of read views, or one write view, never both.
- `for x in &v`, `match &s`, and `if &o as x` look in place;
  `for x in @v` and `if @o as x` let the body change what they see.

## Moves, clones, drops

- `b = <a` moves: `a` cannot be used afterwards. `f(<a)` hands `a` over.
- `b = +a` clones: `b` is a new owner, and changing it leaves `a` alone.
  For a `*T`, `+h` is one more handle; the value goes with the last one.
- `<a` alone on a line drops `a` now. Anything not moved is dropped at
  the end of its block, and a `drop(...)` body runs at that point.

## Optionals and failure

- `T?` is a `T` or `none`. `a ?? b` is `a`'s value, or `b` if it is `none`.
- `if o as x` runs the block with `x` bound when `o` is not `none`.
- `e?` gives `e`'s value, or returns `none` from the function at once.
- `T!` may fail with an error value: `return Bank.empty` fails.
- `e!` gives `e`'s value, or fails the function with the same error.
- `e catch v` gives `v` instead of failing; `catch |err|` names the error.

## Negation

- `!x` is true when `x` is false: `if !v.is_empty()`, `while !done`.
- `!` binds tighter than a comparison: `!(a == b)` means `a != b`.

## Builtins

- `$size(T)` is a type's size in bytes; `$align(T)` and `$name(T)` work alike.
