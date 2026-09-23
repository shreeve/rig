# Roadmap

Where Rig is going, one line each. Nothing here is scheduled; the order
follows what real programs need, and each item lands only when it can
be checked as thoroughly as what exists.

## Language

- **Stack closures as arguments**: pass a non-escaping closure to a call without allocating it.
- **Generic functions**: type parameters on functions, not only on types.
- **Strings**: building and formatting strings, slices of strings and arrays.
- **Optional propagation**: `e?` returns `none` from the enclosing function, mirroring `e!`.
- **Module-level constants** and **field defaults**.
- **Traits or interfaces** whose dispatch and ownership stay visible in the IR.
- **Compile-time evaluation**: `pre` expressions and blocks beyond `pre` parameters.
- **Raw pointers**: pointer types and pointer access inside `raw`, designed together with what `raw` code may assume.
- **Unique heap ownership**: a single-owner box without a reference count.
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
- **`rig check --facts`**: export sema's facts table (symbols, types, ownership operations, captures) as versioned JSON for tools.
- **A formatter.**
- **A language server**: diagnostics, types on hover, go to definition, built on the facts table.
- **C-ABI-friendly `extern` types.**
- **Drop plans from the ownership checker**: which bindings are consumed on every path, so the emitter can drop their alive flags and emit a plain `defer` or none.
