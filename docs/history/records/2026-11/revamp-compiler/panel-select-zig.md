# Zig expert: `match task.select(add: ..., sub: ...)`

**Verdict: a good idea, and not weird.** In Zig you would write `switch (try select(.{ .add = a.recv(), .sub = b.recv() })) { .add => |v| ..., .sub => |v| ... }`. The runtime already works this way: `selectArms` claims exactly one arm with a compare-and-swap and returns the winner's index. Today `selectInto` then calls that arm's closure. The proposal would build `union(enum) { add: ?A, sub: ?B }` from the winning arm instead.

**Cost.** It is cheaper than today. There are no closure objects, no captured views, no allocation, and the winner is picked with one `switch`. Each select gets its own small union, made once by the compiler, so compile time barely changes.

**Pitfalls.**
- *Losing arms.* A losing receive never takes a value, because only the winning arm commits. A losing send drops its value, as it does today, and the docs must say so.
- *Closed channel.* A receive's value is `T?`, so `.add(v)` binds a `T?`. Handle a closed channel with `.add(none)` in the match. Do not add a hidden variant for it.
- *Errors.* A cancel or a deadline is the select's own failure: `match task.select(...)!`. Each body handles its own errors in the enclosing function, which is simpler than threading an error slot through closures.
- *Default and deadline arms.* These become variants with no payload (`.idle`), so nothing new is needed.
- *Arms of different types.* This form allows them; today every closure must give the same type.
- *Exhaustive match.* An arm someone forgets to handle is an error, which is good. `_ =>` is still allowed.
- *Error messages* must name the select's result type in a readable way, such as `select(add, sub)`.

**Refinement.** The result is a plain value, so it can be bound first (`r = task.select(...)`) and matched later, which makes it easy to compose. Drop the closure form after its one release, so select has one mechanism.
