# types-traits

## Parity means
tsc visitors, GPUI element trees, callbacks, and iterators are writable, with no trait feature resting on lifetimes, overlap, or inference.

## Must build (ranked)
1. **R2 with default bodies.** Visitors need a no-op per node kind; a default is a generic body with `Self: Tr`. 2 weeks.
2. **Generic and enum `drop`; `[n]T` of owning `T`** (rejected today). For SmallVec storage; a view-holding instance keeps its loan to the drop (no `may_dangle`). 1 week.
3. **R3 trait values plus downcast** (`if s as Circle c`) for `AnyElement` and tsc's `Any`; under traits-map §7's enum desugaring, a variant match. 3 weeks.
4. **Second-class adaptors.** Widen "no value holds a callable view" to "a type holding one is only a parameter's, local's, or result's type". Lazy chains, no allocation. 1 week.
5. **`@fields[Tr](?x)`**: unrolled static trait calls; derive-free JSON. 1 week.

## Leave out, and it dissolves
- **Subtyping and variance** (#25860): `^C` becomes `^Tr` only at a value's top, never under `!` or in a container. `!Tr` never assigns the whole value.
- **Associated types and GATs:** trait type parameters, one conformance per generic trait. Lending iterators already work: `next(!self) -> ([]Int)? from self` runs sanitizer-clean.
- **HRTB** (#84591): no lifetimes to quantify.
- **Specialization** (#31844): fast paths come from kind facts.
- **Blanket impls, `impl Trait` returns, auto-trait leakage:** use a generic function, a named type, or `^Tr`.
- **Fn/FnMut/FnOnce:** an owned closure's environment is immutable (`Cell`, or `!App` passed in, as GPUI does). A write-capturing stack closure cannot reach itself, so it is never re-entered.
- **Generic trait methods, `Self` beyond the receiver:** every trait object-safe.
- **Zig-style type functions** break check-once.

## Proof obligations
- **Substitution (stages 1 and 3):** a body checked once, with its recorded requirements, makes every instance check. Stage 2: the oracle rechecks each instance.
- **Trait values are sugar:** no new typing rule (stage 3). Vtable dispatch equals the match (stage 2).
- `^Tr`, `*Tr`, and `~Tr` hold no loan, and no conversion happens below the top.
- **Non-reentrance:** no second-class value is reachable from its own environment (stage 3). Listed callbacks must keep this.

## Disagreements
- Default bodies belong in R2.
- For parity, R3 is a must.
- Iterators as values are R2 (`trait Iter[T]`) plus item 4, not `*fun` adaptors. Go's `iter.Seq` maps to `yields`.
- TRIAGE's "Don't add" should list the above.
