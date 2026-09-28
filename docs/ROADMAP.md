# Roadmap

Where Rig is going, one line each. Nothing here is scheduled; the order
follows what real programs need, and each item lands only when it can
be checked as thoroughly as what exists. The forms the compiler
rejects today as not supported yet are listed, with their diagnostics,
in [SPEC §18](../SPEC.md#18-reserved-and-unsupported-forms).

## Language

- **More compile-time values on generic types**: `Bool` and enum value parameters (`struct Ring[T, n: Int]` takes integers only).
- **Owning values in more places**: arrays of owning values, and owned closures that take or return them.
- **Strings**: building and formatting strings, and matching on them. A slice of a built (heap) string will be a borrow of it, as an array slice is today.
- **Printing byte slices**: `print` of a `[]U8` (rejected today, since it lowers like a `String`).
- **A labeled value loop on the right of a binding** (`x = :l for ...`), which needs a grammar change without conflicts.
- **Traits or bounds** whose dispatch and ownership stay visible in the IR, so a generic signature says what its type parameters support; `[T: Trait]` is kept free for them, told from a value parameter by what the name after `:` denotes.
- **Conditional compilation** on the target's operating system and architecture and the build mode.
- **Compile-time functions**: pure functions over plain data that the checker itself evaluates, for constant tables and sizes computed from a compile-time parameter (`[n * 2]Int`, `[cap(n)]Int`), so a failure is a Rig diagnostic rather than a Zig error.
- **Raw pointers**: pointer types and pointer access inside `raw`, designed together with what `raw` code may assume.
- **A value-yielding `try` block** with a matching `catch` block.
- **Drop bodies for enums and generic types.**

## Concurrency

- **Structured concurrency**: scope-bound tasks with cancellation and no orphans.
- **Async**: suspended computations with their own ownership, cancellation, and pinning rules, built on structured concurrency.
- **Thread-safe handles**: an atomically counted shared handle and rules for what may cross threads.

## Libraries

- **A standard library**: collections, strings, I/O, and allocators, written in Rig.
  Settled so far: `String` stays a view and `Text` is the owned, growable text; iterators follow the convention `while !it.next() as x` (a `for` never calls user methods); containers of owning values lend elements as `?v[i]` and `!v[i]`; a generic method call on a `T` is checked at each use; a `[]U8` goes to C as a pointer plus a separate length, and a NUL-terminated copy is made explicitly.
- **A reactive library** in userland, grown from `examples/memo_canary.rig`.

## Tooling

- **Assertions** for `test` blocks, and running one test by name.
- **Sema facts in `rig check --facts`**: add sema's facts table (symbols, types, ownership operations, captures) to the syntax facts it prints today, in a versioned format for tools.
- **A formatter** that writes the canonical style, such as `sub main` rather than `sub main()` for a function with no parameters.
- **A language server**: diagnostics, types on hover, go to definition, built on the facts table.
- **C-ABI-friendly `extern` types.**
- **Drop plans from the ownership checker**: which bindings are consumed on every path, so the emitter can drop their alive flags and emit a plain `defer` or none.
- **Cached `rig build`**: `rig build` runs `zig build-exe`, which reuses no cached work, so every build compiles in full; emitting a small `build.zig` per package and running `zig build --prefix`, or copying the executable out of a `zig run` cache, would reuse it as `rig run` does.

## Compiler

- **Traces in Rig terms**: a panic, or an error that leaves `main`, prints Zig's stack trace, whose lines are in the emitted Zig (in the package directory `rig run` names); mapping them to `.rig` lines would need a source map.
- **One place-access analysis in typecheck**: about a dozen predicates each work out whether a place is writable, borrowed, or boxed; one walk over the place (`Checker.placePath`) followed by one access check would replace them.
- **An explicit emitter context**: the emitter keeps per-function state in `Emitter.fun`, swapped out around a closure's body; passing it explicitly would make what each helper reads visible.
- **Tighter generated code**: Debug builds pay for round trips such as `rig.lend(&rig.elemPtr(xs, j).*)` and `rig.eql((&p).*, (&q).*)`, and a generic `for x in xs` copies each element it only lends. Release builds optimize these away.
- **Runtime tests outside the runtime**: `src/runtime.zig` carries its unit tests into every emitted package; they could move to their own file.

## Open questions

Language decisions not yet made. Each describes what Rig does today;
any change would be future work.

- **Which statements take a label**: the reference labels loops, `match`, and `raw`; the compiler also accepts one on any other statement: `break :name` leaves a labeled `if`, and a label on a simple statement has no effect.
- **`T??`** as a spelling of the nested optional `(T?)?`; today `??` after a type is the fallback operator, and the error points to `(T?)?`.
- **Modules in subdirectories**: `use name` finds only `name.rig` beside the root file.
- **Function values as module constants** (`handler = on_click` at module level); a module constant holds only compile-time values today.
- **`errdefer` in a function that cannot fail**, which is accepted and never runs; it could be rejected instead.
- **Compound assignment through a `!T` field**: `w += 1` writes through a `!Int` binding, but `h.w += 1` on a `!Int` field is rejected ("requires a numeric target").
- **Reading a Copy value while it is write-borrowed**: `n` stays readable while `w = !n` is live (memory-safe for a Copy value, but a write borrow is otherwise exclusive).
