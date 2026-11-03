# Chain panel synthesis (2026-11-03)

Reports: zig.md, rust.md, swift.md (each ran hand lowerings on today's Rig; sanitizer-clean).

## Agreed by all three
- The brief's default ("peel with existing features only") cannot be built: a closure bound to an
  untyped local is rejected ("closure parameter `x` needs a type"), and `break item` / `else none`
  does not unify ("incompatible types `T` and `none`"), so `find` needs a type too.
- Build **one internal type form that only the rewrite writes**, resolved by sema in each round from
  names already in scope, so nothing crosses rounds: the item type of the held source (`h.Item` /
  `(item_type h)`), a bound closure's result (`f.Result`), a range bound's type. Emit, ownership,
  storage, and proofs are unchanged (emit writes local types from sema's settled types). About 20
  lines in sema (`resolveType`, or `assocMember` beside `I.Item`), one wrapper-only node kind.
- The rewrite **holds the source and binds each closure once before the loop**, in place (never
  hoisted out of `and`, `or`, `??`, a condition): captures keep their meaning (`|+n|` clones once,
  `|<r|` moves once). Closure calls inline to nothing in release.
- **Round 1 sema checks the chain in its own terms** (closures typed as a generic call's are) and
  records only facts that survive rounds; only a chain that checks clean is rewritten, so no error
  names hidden code. `collect` of views is rejected there, in the chain's words.
- `take` tests its counter before each `next()` (never pulls past what it needs; `take(0)` pulls
  nothing); nothing calls `next()` after `none`.
- Ties: `min_by`/`max_by` keep the **first**; Rust's `max`/`max_by_key` keep the last. Say so in
  SPEC/STD.

## Split
- **min/max family: peel (Zig, Rust) vs one loop (Swift).** Measured: the peel was fastest or tied
  — a flag loop was 1.8x slower on Map items and 3.5x on an Int List (Zig); peel beat one loop
  1.16x-3.5x on 20M U64 (Rust); on trim all within noise of each other or the peel 4% faster
  (2.41 vs 2.51 ms). Rust's own `min_by_key` peels (via `reduce`). Cost: the min family's machine
  code is ~2.4x (the source's `next` is inlined twice). Swift's single loop measured at noise for
  filter/map/sum, which all agree are one loop.
- **A List of owned elements** cannot hold an element in the state (`best = s` is rejected), so
  min/max/find there keep an index and give `?h[i]` after (Swift; Zig peels Lists by index).

## Decisions for the owner (defaults first)
1. Approve the internal type form (rewrite-only; no user syntax). Default: yes.
2. min/max/min_by/max_by lower by peeling; every other consumer is one loop. Default: peel.
3. Ties keep the first item, documented against Rust. Default: yes.
4. Empty `sum()`: `0` (design) vs an optional (`std.iter.sum`). Default: `0`, as `xs.sum()` gives.
5. Failing closures: `!` now; `catch` on a chain later. Default: yes.
6. Let `T` meet `none` as `T?` in loop and `if` values, as its own change. Default: yes, after chains.
7. Range values (`r = 0..n`): not now. `collect` reserves the source's length when nothing filters.
