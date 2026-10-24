# Reviewer (4 of 4)

## Holes

- **H10, the type hides more than views.** A `^{Shape + Owned + Clone}` hiding a `*Cell` holder can reach other tasks as an error field, as an actor's state, or inside `*Frozen`. *Fix:* treat it as possibly holding anything. The existing error, freezing, and `Sends` rules then reject it.
- **H11.** `+s` of a `?{A}` would be unsized. *Fix:* only a `^{A}` has `+`.
- **H12, copy by representation** (§10). `fun pick(p: ?Point) -> ?{Shape} from p` passes or fails by `ReadView`'s size threshold. *Fix:* decide by kind.
- **H13.** Unstated bounds: `Map[?{Shape}, V]` would compile if `?T` forwards `Hash`. *Fix:* the bounds clause below.
- **Closed as drafted:** `from @field`, closures, `defer`, `Cell`, `Self`-free views, and `Table` (write `^{A}?`). Build note: the drop queue takes erased entries.
- **Accepted limits:** no downcast, and a generic `?T` object cannot be returned.

## Revised text

> **An API object hides its value's type, never its loans.** `?{A}`, `!{A}`, and `^{A}` hold a value of some type that provides `A`. A value lends one by the row above, unwritten where the view lasts only for the use (sentence 4). A `^T` moves into a `^{A}` and keeps its box. Only the value reached is erased, never a place's or an element's type. The object carries every loan the value carried, and since the type is hidden it may hold anything: a view, a handle, a `drop` body. So the loans of a `?{A}` or `!{A}` end at its last use, and those of a `^{A}` at its drop (sentence 6). A call through one passes on only the loans the API's `from` and `keeps` show (sentence 7). Erasing a read view of plain data, or of a type parameter's value, views a local of the erasing block. *(planned)*
>
> **Only its methods reach the value:**
> - through a `!{A}`, nothing reads, assigns, swaps, or moves it;
> - `{A}` is never a type argument, written or inferred, and has no default (§5);
> - it meets only the `Clone`, `Print`, and `Owned` its braces or API name, and only a `^{A}` has a `+`;
> - a `<@` method ends the box, which is dropped exactly once, even if the method fails;
> - `*{A}` and `~{A}` are Stage 5's. *(planned)*

**Verdict: accept with edits.** H10 and H12 are required.
