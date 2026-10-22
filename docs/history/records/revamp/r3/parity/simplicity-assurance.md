# simplicity-assurance

## Parity means
Rust's trust is a proof plus Miri, crater, fuzzing and ten years of attack. Rig matches it with fewer rules and machines that attack daily.

## Must build
1. **A Core budget** (small). The "ten sentences" (§2) are 1,625 words of prose; the Core is 4,538. Stage 1's rules get a cap of 12 rules and 600 words; a new rule retires one.
2. **View-staleness checks** (2–4 weeks), Miri's useful half. `RIG_SANITIZE=views`: each owner counts its writes, and a view asserts the count it was lent at on every read. It catches what the sanitizer misses (Core §4: a change seen, nothing freed), in emitted code.
3. **A fuzzer against the oracle** (3–5 weeks). It mutates accepted corpus programs into near-rejects (drop a sigil, write between a lend and its use, nest headers). The oracle must agree, and accepted mutants run sanitizer-clean.
4. **Crater** (small): Trig, std.json and examples on every release candidate.
5. **An `unsound` label** (small). A `test/known` test within a day, a named class, siblings checked. No release ships with one open (Rust ships with about 100).
6. **A stability promise** (small). Soundness fixes may break code (RFC 1122), and each break ships a migrator, like `tools/migrate-0.3.py`. No editions: in whole-program builds they are pure cost.

## Leave out, and it dissolves
- **Second-class adaptor types** (types-traits 4). They add a new kind of type with exceptions. Write the loop, or use `yields`.
- **Allocators as owners** (systems-ffi 5). Containers become view-kind, and arena drops skip element drops: two exceptions. Use arenas with IDs.
- **Module `var`** (systems-ffi 6). A call could write state a guard proved (Core §9), and threads would race on it. Pass a context.
- **User memory orderings** (concurrency 4). SeqCst only, as in Go.
- **Async.** Scoped threads and channels; no loan spans a suspension.
- **A Tree Borrows model** (rust-soundness 4). It exists to mix raw pointers with references. Without raw pointers, the loan rules are the aliasing model; `noalias` goes on write-view parameters only.

## Proof obligations
Stage 2: staleness checks agree with the interpreter. Stage 3: the capped rules only.

## Disagreements
- Certificates (formal-methods 4) and per-program λRig checks (rust-soundness 1) are one mechanism. Build it once.
- The Lean semantics should replace `bin/rig-oracle`, not become a third checker.
- R3 only as a literal closed-world enum desugaring, with downcast as a match.
