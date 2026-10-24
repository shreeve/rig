# Adversary: API objects

**H1, "could hold".** `fun mk(t: ?String) -> ^{Shape}` returns `^Note(text: t)`. If "could hold a view" walks `{A}`'s parts, it finds none, so `b` carries no loan and `<t` frees text that `b.area()` then reads. *Fix:* without `Owned`, `{A}` could hold any view, everywhere.

**H2, `.maybe` read as no.** `shapes: List[^{Shape}]` is declared before `t` and holds `^Logger(out: ?t)`. `t` drops first, and Logger's drop reads it. *Fix:* `.maybe` is yes everywhere, through lists, optionals, and fields. `Owned` counts a part `^{X}` as lacking it.

**H3, variance.** `f(!sqbox)` into `b: !^{Shape}` lets `b = ^Circle(...)` write a Circle into a `^Square`. *Fix:* erase only the value a lend reaches. Never erase a place's type or an element type.

**H4, inferred `T`.** `put[T](a: !T, b: !T)` swaps, called with `put(!w1, !w2)`, which infers `T = {Shape}`. *Fix:* `{A}` is never a type argument, written or inferred.

**H5, "stays in the frame" is too coarse.** `for p in ?pts` (each `p` a copied `?Point`) followed by `!objs.push(p)` into a local list stays in the frame. Yet every element views one reused slot. *Fix:* erase the source place where one exists. Otherwise the copy is a hidden local of the binding's scope, and the object carries a loan on it. Closures, `defer`, and tasks then follow sentence 6.

**H6, zero objects.** `Table[^{Shape}, n]`, `T()`, and `resize` make `{0, 0}`, and assigning over it drops through a null table. *Fix:* an object has no default value.

**H7, a failing `<@`.** The entry frees the box, then `m` fails. A second drop of self is a double free. *Fix:* the entry owns nothing after the move, and `<b.m()` ends `b` with a drop flag. Add sanitize cases for both.

**H8, the implementation's facts.** Knowing that `s` came from a `Reader` must not apply that type's `from @seen`. *Fix:* use only the API's whole-self clauses, and never apply `Iter` rule 9.

**H9, gaps.** `+s` of a `?{A}` is unsized. `*<b` and `Cell(^{A})` need rejecting. The `Self` check must look inside types like `?fun(?Self)`..

## Minimal rules
1. An erasure keeps every loan. Without `Owned`, `{A}` holds any view, and its drop reads them.
2. `Owned` is checked on the concrete type, and its object parts must say `Owned` themselves.
3. Erasure only at a lend's top.
4. `!{A}` allows method calls only. `{A}` is never a type argument and has no default.
5. A dynamic call takes only the API's clauses.
6. A copied view erases through a scoped hidden local.
7. Self is dropped exactly once.
8. `+` works only through `Clone`. No `*`, `~`, or `Cell`.
