# Notes
The guide never shows declarations: parameter type syntax, struct methods, drop body, constructors, Vec methods, loops. I guessed most of it.

- w1: medium. Unsure: push(+s) to clone String (chose clone); `for s in &extra`; param written `tags: !Vec[String]`, call `add_tags(!tags, extra)`.
- w2: medium. Unsure: return type `&Book` and `return &books[0]`; whether `books` param needs `&`; chose bare (reads).
- w3: low. Unsure: drop body syntax (chose `drop()` inside struct, fields bare); chose `finish(<c)` with param `c: Conn`.
- w4: high-medium. `b = +a`, `!b.push(3)`, `b[0] = 10`.
- w5: medium. `(!v).pop() ?? 0` since pop probably returns optional; `while not v.is_empty()`; `total += x`.
- w6: low-medium. Method syntax (`fun is_empty() -> Bool` with `self`) guessed; `not c.is_empty()`.

Ease: 5/10. Sigil table is clear, but the guide omits basic syntax (types of params, methods, drop, constructors).
