# API objects: the combined Core draft (Rig (OG), from panel reports 1–3)

## §1: two rows widened (panel 1)

| **owning** | `List[T]`, `^T` (`^{A}` too), `String`, `error`, objects holding an owner | moves; one owner; dropped once | built; `^{A}` planned |
| **view** | `?T`, `!T` (`?{A}`, `!{A}` too), `[]T`, `![]T` | as today | built; `{A}` planned |

## §4: one row, last (panel 1; the box form is a move, not a lend: panel 2)

| a `T` that provides `A` | `?{A}` | `!{A}` | planned |

## The paragraph, at the end of §4

> **An API object hides its value's type, never its loans.** `?{A}`,
> `!{A}`, and `^{A}` hold a value of some type that provides `A`. A
> value lends one by the row above, unwritten where the view lasts only
> for the use (sentence 4), and a `^T` moves into a `^{A}` (`b: ^{A} =
> <c`), keeping its box. Only the value a lend or a move reaches is
> erased, never the type of a place or an element. Either way the API
> object carries every loan the value carried, and since its type is
> hidden it is taken to hold any view: a `?{A}`'s and a `!{A}`'s loans
> end at their last use, a `^{A}`'s last until its drop, and `Owned` in
> the braces admits only values that hold none (sentence 6; §5). A call
> through one passes on only the loans the API's signature shows, in its
> `from` and `keeps`, never an implementation's (sentence 7). The value
> has no type a program names, so only its methods reach it: through a
> `!{A}` nothing reads, assigns, swaps, or moves it, `{A}` is never a
> type argument, written or inferred, and an API object has no default
> value (sentence 1; §6). Its `+` is the one its braces' `Clone` gives,
> and it is never put behind `*`, `~`, or a `Cell` (sentences 2 and 8).
> A `<@` method through a `^{A}` ends the box, which is dropped exactly
> once, a failing method's included (sentences 3 and 10). Erasing a view
> held as a copy (§9) views that copy, a local of the erasing block, as
> any view of a local does (sentence 7). *(planned)*

Examples (panel 1): the `rig pending` `area_of` program printing `4.0 9.0`, and a `rig pending` + ```error case (`s: ?{Shape} = ?v[0]` then `!v.push(...)`: "cannot lend `v` to write while a read loan is live").

## How each hole is closed
| Hole (panel 3) | Rule |
|---|---|
| H1: "could hold" finds no parts | it is taken to hold any view |
| H2: `.maybe` read as no | the drop reads them: `dropRunsBody(^{A}) = .yes` (panel 2) |
| H3: variance through `!^{Shape}` | only the value a lend or move reaches is erased |
| H4: an inferred `T = {Shape}` | never a type argument, written or inferred (checked in inference and unify: panel 2) |
| H5: a loop's reused copy slot | a copy is a local of the erasing block (a hidden local with a block-scoped life: panel 2) |
| H6: a zero object | no default value |
| H7: a failing `<@` | dropped exactly once |
| H8: the implementation's facts | the API's clauses only (and `Iter` rule 9 never applies through an object) |
| H9: `+`, `*`, `~`, `Cell`, and a deep `Self` check | `Clone` only; never behind `*`, `~` or `Cell`; the `Self` check looks inside types |

## Compiler notes (panel 2)
- Intern `api_object` with a conservative TypeInfo (it may hold any view; never `holds_type_var`).
- Record erasures once, in `SemContext.erasures`.
- Use one `Dispatch.viaApi()` predicate, replacing the `== .static` tests (ownership 4826, emit 8024/8091/8524).
- The oracle gets an `objectInfo` beside `callableInfo`.
