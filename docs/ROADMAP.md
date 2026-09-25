# Roadmap

Where Rig is going, one line each. Nothing here is scheduled; the order
follows what real programs need, and each item lands only when it can
be checked as thoroughly as what exists. The forms the compiler
rejects today as not supported yet are listed, with their diagnostics,
in [SPEC §19](../SPEC.md#19-reserved-and-unsupported-forms).

## Language

- **Stack closures as arguments**: pass a non-escaping closure to a call without allocating it.
- **Generic functions**: type parameters on functions, not only on types.
- **Generic types across modules**: instances of a module's generic types in its public surface.
- **Owning values in more places**: arrays of owning values, and owned closures that take or return them.
- **Strings**: building and formatting strings, and matching on them. A slice of a built (heap) string will be a borrow of it, as an array slice is today.
- **Struct equality**: `==` on structs.
- **Writable and open slices**: `!xs[a..b]` write slices and `xs[a..]` / `xs[..b]` open ranges.
- **Printing byte slices**: `print` of a `[]U8` (rejected today, since it lowers like a `String`).
- **Aliases of imported and generic types** used as constructors and namespaces.
- **A labeled value loop on the right of a binding** (`x = :l for ...`), which needs a grammar change without conflicts.
- **Traits or interfaces** whose dispatch and ownership stay visible in the IR.
- **Compile-time evaluation**: `pre` expressions and blocks beyond `pre` parameters.
- **Raw pointers**: pointer types and pointer access inside `raw`, designed together with what `raw` code may assume.
- **Unique heap ownership**: a single-owner box without a reference count.
- **Private fields**: a field visible only inside its type's module unless marked `pub`, so setter methods can guard a type's invariants; Rig's tool for encapsulation, rather than properties.
- **A value-yielding `try` block** with a matching `catch` block.
- **Drop bodies for enums and generic types.**

## Concurrency

- **Structured concurrency**: scope-bound tasks with cancellation and no orphans.
- **Async**: suspended computations with their own ownership, cancellation, and pinning rules, built on structured concurrency.
- **Thread-safe handles**: an atomically counted shared handle and rules for what may cross threads.

## Libraries

- **A standard library**: collections, strings, I/O, and allocators, written in Rig.
- **A reactive library** in userland, grown from `examples/memo_canary.rig`.

## Tooling

- **Assertions** for `test` blocks, and running one test by name.
- **Sema facts in `rig check --facts`**: add sema's facts table (symbols, types, ownership operations, captures) to the syntax facts it prints today, in a versioned format for tools.
- **A formatter** that writes the canonical style, such as `sub main` rather than `sub main()` for a function with no parameters.
- **A language server**: diagnostics, types on hover, go to definition, built on the facts table.
- **C-ABI-friendly `extern` types.**
- **Drop plans from the ownership checker**: which bindings are consumed on every path, so the emitter can drop their alive flags and emit a plain `defer` or none.
