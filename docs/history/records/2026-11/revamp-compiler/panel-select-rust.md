# Rust panelist: select as a tagged result

**Verdict: a good idea, and close to what Rust converged on.** `futures::future::select` returns `Either<(A::Output, B), (B::Output, A)>`, a tagged result that you match on. People found nested `Either` unbearable, so `tokio::select!` became a macro whose handlers are blocks. The bodies in the lead's form are blocks too: they run after the winner is committed, in the enclosing scope. Named variants give the macro's ergonomics with no macro, and `match` exhaustiveness checks the arms.

**Cost:** a small anonymous tagged type, with one payload slot per arm. That is the same as the closure form or cheaper, since no closure objects are built.

**Pitfalls:**
- **Spelling.** `a.recv()` already means a blocking receive. Inside `select` it would mean "an operation, not yet run", and that is a hidden mode switch. Keep the operation words and the visible lend: `add: (!a).on_recv()`.
- **Cancellation.** Losing receives must take nothing. That is tokio's "cancel-safe" rule, and Rig's commit-one-arm already gives it. A losing send drops its value, which is the same loss tokio has. Document it, or give the value back in a later version.
- **Errors.** `match task.select(...)!`: the select's own failure stays separate from the variants.
- **Deadline and default.** Make the deadline an arm (`late: time.after(d)`) and the default an `else` arm (tokio's `else =>`). Neither needs a new mechanism.
- **Arms of different types.** These now just work. The closure form could not do this.
- **Nesting and storage.** `r = task.select(...)`, with the match later, should be allowed. The anonymous type must be printable in diagnostics (`select{add: Int?, sub: Int?}`) but never written.

**Better variant:** none needed beyond the operation-word spelling. Drop the closure form after one release, as planned.
