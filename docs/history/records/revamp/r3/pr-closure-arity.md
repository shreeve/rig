# PR closure-arity

Closures may omit trailing parameters where the expected type is known; see the PR for the mechanism and gates.

## Decisions to confirm

SPEC text (Parameters and results): "A closure may ignore a parameter by naming it `_`, and, where its type is known, may leave out the trailing parameters it does not use: it is the same closure with a `_` for each one it omits. Only trailing parameters can be left out, a closure never takes more parameters than its type passes, and an untyped closure keeps the parameters it declares. An argument passed for an omitted parameter is handled as one passed to `_`: a lend ends as any lend does, and an owned argument nothing binds is dropped when the closure returns."

CORE text (proposed, one sentence under the closure/parameter paragraph; CORE is unchanged in this PR since no ownership rule changes): "A closure that declares fewer parameters than its type is the closure with `_` for each omitted trailing parameter, so omitting one changes no ownership: an owned argument for it is dropped as a `_` drops it."

Points to confirm:
- An owned `_` argument drops at the end of the closure (after the body, reverse parameter order), not at entry. This is today's `_` behavior, now stated.
- Padding mutates the tree in typecheck (hidden `_` leaves at positions past the source end), like `dropTail`.
- Diagnostic wording for too many parameters gained "; a closure may take fewer, never more".
