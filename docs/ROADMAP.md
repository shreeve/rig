# Roadmap

Where Rig is going, one line each. Nothing here is scheduled; the order
follows what real programs need, and each item lands only when it can
be checked as thoroughly as what exists. The forms the compiler
rejects today as not supported yet are listed, with their diagnostics,
in [SPEC §18](../SPEC.md#18-reserved-and-unsupported-forms).

## Language

- **More compile-time values on generic types**: `Bool` and enum value parameters (`struct Ring[T, n: Int]` takes integers only).
- **Owning values in more places**: arrays of owning values, and owned closures that take or return them.
- **Strings**: matching on them.
- **Reading more through temporaries and optionals**: `o?` of an owned optional parameter read through a view where only read (`o?.len`), and a read-only use of an owning field of a temporary (`print(mk().t)`), both rejected today.
- **Quieter follow-on errors**: one mistake about a temporary can still give two diagnostics.
- **Static Strings**: a String known to view only static bytes (a literal, an argument), which could go into a Cell, a Signal, an owned closure, or a generic `T` stored there, where a String that may view a Text cannot.
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

## Kernels and freestanding code

A kernel is the stress test for Rig's ownership model, reached in steps:

- **A freestanding target**: programs with no operating system under them, on Zig's freestanding support, with a runtime that makes no OS calls, a panic hook, and a boot entry point.
- **Containers with explicit allocators**: owning values (List, String, `*T`) built over an allocator the program chooses, not a hidden global one.
- **A teaching kernel** on one CPU in QEMU, with `raw` as the boundary for hardware access: volatile loads and stores, memory layout, interrupt calling conventions and inline assembly.
- **Global state**: rules for module-level mutable state, designed together with Static Strings.
- **Concurrency for kernels**: what may cross CPUs and interrupts, with atomics and locks, built on the thread-safe handles above; this is what a kernel beyond one CPU needs.

## Libraries

- **The rest of the standard library** ([STD.md](STD.md) lists what exists): collections, strings, I/O, and allocators, written in Rig over small Zig files. Next for the Zig-backed declarations: Zig-backed types (`struct File owns`, with the kinds `copy`, `owns`, and `view`), and generic ones with declared requirement bounds, which a body-less declaration needs since the checker cannot infer them.
  Settled so far: a `for x in it` over an iterator (a type with `next(!self) -> T?`) is the desugaring `while (!it).next() as x`, which the checker walks exactly ([IDEAS.md](../IDEAS.md) §0.3); containers of owning values lend elements as `?v[i]` and `!v[i]`; a generic method call on a `T` is checked at each use; a `[]U8` goes to C as a pointer plus a separate length, and a NUL-terminated copy is made explicitly.
- **Text building in std.text**: functions that build new text into a `Text`, such as an upper-case copy, a replacement, and a join.
- **A reactive library** in userland, grown from `examples/memo_canary.rig`.

## Tooling

- **Assertions** for `test` blocks, and running one test by name.
- **Sema facts in `rig check --facts`**: add sema's facts table (symbols, types, ownership operations, captures) to the syntax facts it prints today, in a versioned format for tools.
- **A formatter** that writes the canonical style, such as one blank line between top-level declarations.
- **A language server**: diagnostics, types on hover, go to definition, built on the facts table.
- **C-ABI-friendly `extern` types.**
- **Drop plans from the ownership checker**: which bindings are consumed on every path, so the emitter can drop their alive flags and emit a plain `defer` or none.
- **Cached `rig build`**: `rig build` runs `zig build-exe`, which reuses no cached work, so every build compiles in full; emitting a small `build.zig` per package and running `zig build --prefix`, or copying the executable out of a `zig run` cache, would reuse it as `rig run` does.

## Compiler

- **Traces in Rig terms**: a panic, or an error that leaves `main`, prints Zig's stack trace, whose lines are in the emitted Zig (in the package directory `rig run` names); mapping them to `.rig` lines would need a source map.
- **An explicit emitter context**: the emitter keeps per-function state in `Emitter.fun`, swapped out around a closure's body; passing it explicitly would make what each helper reads visible.
- **Tighter generated code**: Debug builds pay for round trips such as `rig.lend(&rig.elemPtr(xs, j).*)` and `rig.eql((&p).*, (&q).*)`, and a generic `for x in xs` copies each element it only lends. Release builds optimize these away.
- **Runtime tests outside the runtime**: `src/runtime.zig` carries its unit tests into every emitted package; they could move to their own file.

## Open questions

Language decisions not yet made. Each describes what Rig does today;
any change would be future work.

- **`T??`** as a spelling of the nested optional `(T?)?`; today `??` after a type is the fallback operator, and the error points to `(T?)?`.
- **Modules in subdirectories**: `use name` finds only `name.rig` beside the root file.
- **Function values as module constants** (`handler = on_click` at module level); a module constant holds only compile-time values today.
