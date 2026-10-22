# Notes

Confidence: w1 medium, w2 low, w3 medium, w4 medium, w5 medium, w6 medium.

Unsure points:
- Guide never shows how to create a Vec, push, len, index, or declare parameter/return types. I guessed `Vec[T]()`, `!v.push(x)`, `.len()`, `v[0]`, and `name: !T` / `name: ?T` params.
- w1: used `+s` to clone each String into tags (extra only read). Passed `add_tags(!tags, extra)`.
- w2: return type `-> ?Book`, `return ?books[0]`, bound with `b = ?first(shelf)`. Unsure whether the caller's `?` is needed on a call result, and whether `fun` vs `sub` matters beyond return.
- w3: drop body syntax guessed as `drop(self)` inside the struct. `finish(c: Conn)` takes ownership by plain type; caller writes `finish(<c)`.
- w5: `(!v).pop()` assumed to return `Int?`, so `?? 0`. Assumed `total = total + x` reassigns (no `var`/`mut`).
- w6: method receiver `self` with no sigil assumed to be a read; struct literal `Cart(items: ...)` assumed; `if/else` syntax assumed. `c.items.push` through `!c.items.push`.
- Colons vs no colons after block headers (`if x:`) not stated; I used none, with indentation.

Ease: 4/10. The guide covers ownership sigils well but omits basic syntax (constructors, collections API, param types, drop, methods, mutation of variables).
