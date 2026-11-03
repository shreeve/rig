# Chains: the owner's decisions (2026-11-03)

After the Zig/Rust/Swift panel (summary.md), the owner approved:

1. A type form only the rewrite writes, no user syntax: the item type of a held source and a bound
   closure's result, resolved by sema each round from names in scope.
2. `min`, `max`, `min_by`, `max_by` lower by peeling the first item; every other consumer is one loop.
   The rewrite holds the source and binds each closure once, in place.
3. **Ties follow Rust:** `min`/`min_by` keep the first of equal items, `max`/`max_by` the last
   (owner, after "the names are Rust's; a port would silently pick another entry"). SPEC and STD
   say so in one line, with a test for each.
4. An empty `sum()` is `0`, as `xs.sum()` gives.
5. A failing closure works with `!`; `catch` on a chain comes later.
6. `T` meeting `none` as `T?` in loop and `if` values: its own change, after chains.
7. Range values not now; `collect` reserves the source's length when nothing filters.

Plus, from Swiss/owner earlier: `!@entries.take(+oldest.key)` where `oldest` views `@entries` is
allowed (the clone runs before the write lend), with a `fail` case for `take(oldest.key)`; the
8-line `trim` is a passing case.
