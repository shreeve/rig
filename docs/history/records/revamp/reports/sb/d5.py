p='SPEC.md'
s=open(p).read()
old='''A borrowed array parameter (`xs: ?[N]T`) is the function's own copy of
the caller's array, so a slice of it cannot be returned; a function
that returns part of its argument takes `xs: []T`.
'''
new='''A borrowed array parameter (`xs: ?[N]T`) is the function's own copy of
the caller's array, so a slice of it cannot be returned; a function
that returns part of its argument takes `xs: []T`.

An array goes where a slice is expected in three ways. Where a `[]T`
is expected, `?a` of a named array (or a field or element of one)
means `?a[..]`, and where a `![]T` is expected, `!a` means `!a[..]`:
the sigil shows the borrow, which is the slice's. A bare named array
there is rejected, since it would borrow the array unseen. A temporary
array, a literal, a fill, or a call's result, is accepted as a `[]T`
argument of a function or method call that keeps no borrow of its
arguments (its result holds none, and it writes through no borrow into
anything that could hold one): it borrows nothing named, and it lives
until the call returns. Anywhere else, such as a struct field or a call
that returns a slice, it is rejected; bind it to a name and pass `?a`.

```rig
fun total(xs: []Int) -> Int
  n = 0
  for x in xs
    n += x
  n

sub zero(s: ![]Int)
  !s.fill(0)

sub main
  a = [1, 2, 3]
  print(total(?a), total([4, 5]), total([3 of 2]))
  !a[..2].copy([7, 8])
  print(a)
  zero(!a)
  print(a)
```

```output
6 9 6
[7, 8, 3]
[0, 0, 0]
```

```rig reject
fun total(xs: []Int) -> Int
  xs.len

fun id(xs: []Int) -> []Int
  xs

sub main
  a = [1, 2, 3]
  print(total(a))
  r = id([1, 2])
  print(r)
```

```error
type mismatch: expected `[]Int`, got `[3]Int`; write `?a` or `?a[..]`
a temporary array is lent as a `[]Int` only to a call that keeps no borrow of it
```
'''
assert old in s; s=s.replace(old,new,1)
open(p,'w').write(s)

p='SYNTAX.md'
s=open(p).read()
old='''written `?xs[a..b]` and is a `[]T`, a read-only view that borrows `xs`
like any `?` borrow. Bounds are checked. A side may be left open, as
in Rust: `xs[a..]`, `xs[..b]`, `xs[..]`.
'''
new='''written `?xs[a..b]` and is a `[]T`, a read-only view that borrows `xs`
like any `?` borrow. Bounds are checked. A side may be left open, as
in Rust: `xs[a..]`, `xs[..b]`, `xs[..]`. Where a `[]T` is expected,
`?a` of an array means `?a[..]` (and `!a` means `!a[..]` where a `![]T`
is), much as Rust's `&a` coerces to `&[T]`; a bare `a` is rejected,
since the borrow would not show. A temporary array (`[4, 5]`,
`[3 of 0]`, a call's result) may be passed as a `[]T` argument to a
call that keeps no borrow of it: `total([4, 5])`.
'''
assert old in s; s=s.replace(old,new,1)
open(p,'w').write(s)

p='docs/INTERNALS.md'
s=open(p).read()
old='''| `readsAsView(node)` |'''
new='''| `arrayViewOf(node)` | for an array lent as a slice: `borrowed` for `?a` where a `[]T` is expected or `!a` where a `![]T` is (the ownership checker walks it as `?a[..]`, emit writes the array's address), `temporary` for a temporary array passed as a `[]T` argument to a call that keeps no borrow of it (emit writes `&` before it, which Zig keeps alive through the call) |
| `readsAsView(node)` |'''
assert old in s; s=s.replace(old,new,1)
open(p,'w').write(s)
