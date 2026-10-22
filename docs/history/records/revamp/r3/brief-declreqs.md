# Queued round: declared requirements for built-in methods

Owner-approved 2026-10-15. Start after #238 (listfill) merges, one at a time with viewvalue (#239): both change typecheck's checking of calls.

## The problem, as a class

What a built-in method needs from `T` (today: that `T` copies) is decided by a switch on method names (`listCopies` in src/typecheck.zig: `get`, `filled`, `resize`), apart from the method's declaration in the `registerBuiltins` table in src/resolve.zig. Two places must agree. #238's review found the bug this makes: the call through the type (`List.resize(!xs, …)`) and the method call each checked a different set of names, and a `String` was freed twice. A new built-in method can forget to join the list.

## Design

1. `Field` gains a declared requirement on the type parameter: `method(ctx, "filled", …, .{ .t = .copies })`. Each built-in method that duplicates a `T` or copies one out of a view declares it in its table entry (`get`, `filled`, `resize`, and any others the audit finds: check every method of every built-in in `registerBuiltins`).
2. Every call to a built-in method, as `xs.m(…)` or `List.m(…)`, checks the declared requirement through the existing generic-requirement path (`Requirement.copies`, the same check Rig-written generics use).
3. `listCopies` is deleted. Nothing in typecheck compares a method name to decide a requirement (grep for name compares in the call checks, and convert each requirement-bearing one).
4. Diagnostics stay as #238 left them (they name the loop with `+x`).

## Later (with traits, owner-approved path)

- Generic Zig-backed declarations with bounds: `fun filled[T: Copy](n: Int, v: T) -> List[T]` (SPEC today: a Zig-backed function takes no compile-time parameters).
- Then List's method declarations move to std/list.rig with `extern zig "list.zig"`. The List type stays compiler-known (indexing places, `for`, slices, element loans, proofs). The `registerBuiltins` method tables go away, leaving one way to declare a method.

## Gates

Classifier change: build, `./test/run --delta`, the full matrix, the corpus, equivalence against main, a test per declared requirement through both call routes, one adversarial review.
