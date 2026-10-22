# Notes
Confidence: w1 medium, w2 medium, w3 low-medium, w4 medium, w5 medium, w6 medium.

Unsure (guide gives no details on these):
- Vec construction: chose `Vec[T]()`; no literal syntax known.
- Method names `push`, `pop`, `len`; `pop` assumed to return optional (used `while @v.pop() as x`).
- Parameter type syntax: `name: @T`, `&T`, `<T` (I chose `<Conn` for taking ownership; guide shows only `<x` on values).
- Return view type: `-> &Book`, `return &books[0]`.
- Drop body: chose `drop()` inside the struct using `self`; guide does not show its form. Receiver `self` unannotated for read-only method.
- Struct construction `Book(title: ..., pages: ...)` with named args; `fun` vs `sub` assumed (fun returns value).
- add_tags: `+s` clone for each String, `@tags.push(...)` and call `add_tags(@tags, more)`.
- Field mutation `@c.items.push("tea")`, `b[0] = 10` write syntax.
- `else` branch syntax and `print` of a Vec formatting assumed.

Ease: 5/10. The sigil table is clear, but the guide omits basic syntax (constructors, methods, drop, param types), so I guessed a lot.
