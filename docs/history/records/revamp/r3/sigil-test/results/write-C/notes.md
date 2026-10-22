# Notes
Confidence: w1 medium, w2 medium, w3 low, w4 medium, w5 medium, w6 medium.

Unsure points:
- Creating a Vec: I chose `Vec[String]()`; the guide never says (could be `.new()` or a literal).
- Struct construction: chose `Book(title: "Dune", pages: 412)`; named vs positional unknown.
- Method names `push`, `pop`, `len` guessed. Whether pop returns an optional (I assumed so, used `while @v.pop() as x`).
- Parameter annotations: chose `tags: @Vec[String]`, `extra: &Vec[String]` and `c: &Cart`, passing `@tags` at the call; unsure whether a read param needs `&` or is just bare type.
- Return view type `-> &Book` and `return &books[0]`; unsure if the caller binds with `b = first(shelf)` or `b = &first(shelf)`.
- Drop body: wrote `drop(self)` inside the struct; syntax is a guess. Method receivers `self` and whether `fun` vs `sub` in struct is right is a guess.
- `@b[0] = 10` for index assignment (write mark on an element assignment) is a guess; maybe plain `b[0] = 10`.
- `+s` clone in push in w1 (needed because extra is only read).
- `total += x` assumed to exist. `else` assumed.
- `@cart.items.push` assumed to be the form for a field receiver.

Ease: 5/10. The sigil table is clear, but the guide gives almost nothing about constructors, method names, struct and drop syntax, or parameter type annotations, so much was guessed.
