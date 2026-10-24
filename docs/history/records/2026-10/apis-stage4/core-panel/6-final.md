# API objects: the final CORE text for the owner (panel of 4, accepted with the reviewer's edits)

## §1: two rows widened
| **owning** | `List[T]`, `^T` (`^{A}` too), `String`, `error`, objects holding an owner | moves; one owner; dropped once | built; `^{A}` planned |
| **view** | `?T`, `!T` (`?{A}`, `!{A}` too), `[]T`, `![]T` | as today | built; `{A}` planned |

## §4: one row, last
| a `T` that provides `A` | `?{A}` | `!{A}` | planned |

## The paragraph and list, at the end of §4

> **An API object hides its value's type, never its loans.** `?{A}`,
> `!{A}`, and `^{A}` hold a value of some type that provides `A`. A
> value lends one by the row above, unwritten where the view lasts only
> for the use (sentence 4). A `^T` moves into a `^{A}` and keeps its
> box. Only the value reached is erased, never a place's or an element's
> type. The API object carries every loan the value carried, and since
> the type is hidden it may hold anything: a view, a handle, a `drop`
> body. So the loans of a `?{A}` or `!{A}` end at its last use, and
> those of a `^{A}` at its drop (sentence 6). A call through one passes
> on only the loans the API's `from` and `keeps` show (sentence 7).
> Erasing a read view of plain data, or of a type parameter's value,
> views a local of the erasing block. *(planned)*
>
> **Only its methods reach the value:**
> - through a `!{A}`, nothing reads, assigns, swaps, or moves it;
> - `{A}` is never a type argument, written or inferred, and has no
>   default (§5);
> - it meets only the `Clone`, `Print`, and `Owned` its braces or API
>   name, each checked on the value's type where it is erased, and only
>   a `^{A}` has a `+`;
> - a `<@` method ends the box, which is dropped exactly once, even if
>   the method fails;
> - `*{A}` and `~{A}` are Stage 5's. *(planned)*

Examples: the `rig pending` `area_of` program printing `4.0 9.0`; a `rig pending` + ```error case (`s: ?{Shape} = ?v[0]`, then `!v.push(...)`: "cannot lend `v` to write while a read loan is live").

## Holes closed: H1–H13
- **Panel 3 (H1–H9):** could-hold, drop reads, variance, inferred type arguments, loop copies, zero objects, a failing `<@`, the implementation's clauses, `+`/`*`/`~`/`Cell`.
- **The reviewer (H10–H13):**
  - H10: the value may hold anything, so the error, freezing and crossing rules reject handles;
  - H11: only `^{A}` has `+`;
  - H12: copies are decided by kind, not by Zig's size threshold;
  - H13: an object meets only the bounds its braces name.

## Accepted limits
No downcast, no upcast between API object types, and an API object of a generic `?T` cannot be returned.

Reports: 1-core.md, 2-compiler.md, 3-adversary.md, 4-draft.md, 5-review.md (this folder).
