# Roadmap

Where Rig is going, one line each. Nothing here is scheduled; the order
follows what real programs need, and each item lands only when it can
be checked as thoroughly as what exists. The forms the compiler
rejects today as not supported yet are listed, with their diagnostics,
in [SPEC §19](../SPEC.md#19-reserved-and-unsupported-forms). Where the
work stands is in [HANDOFF](../HANDOFF.md), and the decided engineering
items, with their probe cases, are in
[internals/backlog](internals/backlog.md).

## Language

- **More compile-time values on generic types**: `Bool` and enum value parameters (`obj Ring[T, n: Int]` takes integers only).
- **Owning values in more places**: arrays of owning values.
- **`?String` values**: matching on them.
- **Reading more through temporaries and optionals**: `o?` of an owned optional parameter read through a view where only read (`o?.len`), and a read-only use of an owning field of a temporary (`print(mk().t)`), both rejected today.
- **Quieter follow-on errors**: one mistake about a temporary can still give two diagnostics.
- **Printing byte slices**: `print` of a `[]U8` (rejected today, since it lowers like a `?String`).
- **A labeled value loop on the right of a binding** (`x = $l: for ...`), which needs a grammar change without conflicts.
- **Traits or bounds** whose method dispatch and ownership stay visible in the IR, so a generic signature says what its type parameters support; `[T: Trait]` is kept free for them, told from a value parameter by what the name after `:` denotes.
- **Conditional compilation** on the target's operating system and CPU features and the build mode, as `std.target` gives the architecture (`target.arch`).
- **Compile-time functions**: pure functions over plain data that the checker itself evaluates, for constant tables and sizes computed from a compile-time parameter (`[n * 2]Int`, `[cap(n)]Int`), so a failure is a Rig diagnostic rather than a Zig error.
- **Raw pointers**: pointer types and pointer access inside `raw`, designed together with what `raw` code may assume.
- **Drop bodies for enums and generic types.**

- **Errors that carry data**, after `error` the type: declared sets (`T!E`, `error L = A | B`) and the typed `catch` binding, then member fields moved up through `!`, then `std.json`'s fallible API ([SPEC §13](../SPEC.md#declared-sets-and-fields)).
- **Constant tables**: module constants built from constructors of plain types, for Trig's diagnostics catalog.
- **Several results**, after their first form (SPEC "Several results"):
  in registers when small, `from` per result, and a `for` that binds
  them each step.

## Speed

- **SIMD**: `Simd[T, n]` vectors with `m.first()` and `any`/`all`, `t.lookup(idx)`, `cur.lag[k](prev)`, `+|` and `-|`, and lane shifts; then `pad:` reads and `blocks(N)`, and one load for 4- and 8-byte byte-lane reads on ARM.
- **Zig 0.18**: LLVM's loop vectorizer, which Zig 0.17 turns off
  (docs/internals/zig-0.17.md §16), is back; measure plain loops again,
  and move std/terminal.zig's `widen` back into std/terminal.rig.
- **Checker-proved check elimination**: bounds and overflow checks the checker proves redundant, redesigned around units.
- **A frame-size guard** for every function.

## Concurrency

The model of [CONCURRENCY](design/concurrency.md) is built ([SPEC §18](../SPEC.md#18-tasks)): tasks (`f(x)&`, `>t`) owned by their scope, cancellation and deadlines, sets of tasks, `par`, channels and `select`, actors with their idle path, deadlock detection, failure and supervision, `task.isolate`, seeded deterministic tests, and `std.net` and `std.http` on a poller per worker. What comes next is the concurrency panel's ([concurrency/panel](design/concurrency-panel/README.md)):

- **Files and I/O**: a file layer with one `read`/`write` shape for files, sockets, and HTTP bodies; DNS; then TLS and an HTTP client.
- **Checking the runtime**: the next slices of the model's proofs ([design/concurrency](design/concurrency.md), "Proof obligations"), model checking (TLA+, GenMC) before more hand proofs, and `no_orphans` restated over whoever holds a task.
- **Later**: thread-sanitizer annotations for fibers, freeing a long-sleeping task's stack, and io_uring.

## Kernels and freestanding code

A kernel is the stress test for Rig's ownership model, reached in steps:

- **A freestanding target**: programs with no operating system under them, on Zig's freestanding support, with a runtime that makes no OS calls, a panic hook, and a boot entry point.
- **Containers with explicit allocators**: owning values (List, String, `*T`) built over an allocator the program chooses, not a hidden global one.
- **A teaching kernel** on one CPU in QEMU, with `raw` as the boundary for hardware access: volatile loads and stores, memory layout, interrupt calling conventions and inline assembly.
- **Global state**: rules for module-level mutable state.
- **Concurrency for kernels**: what may cross CPUs and interrupts, with atomics and locks, built on the thread-safe handles above; this is what a kernel beyond one CPU needs.

## Libraries

- **The rest of the standard library** ([STD.md](STD.md) lists what exists): collections, strings, I/O, and allocators, written in Rig over small Zig files. Next for the Zig-backed declarations: Zig-backed types (`obj File owns`, with the kinds `copy`, `owns`, and `view`), and generic ones with declared requirement bounds, which a body-less declaration needs since the checker cannot infer them.
  Settled so far: containers of owning values lend elements as `?v[i]` and `!v[i]`; a generic method call on a `T` is checked at each use; a `[]U8` goes to C as a pointer plus a separate length, and a NUL-terminated copy is made explicitly.
- **String building in std.text**: functions that build new text into a `String`, such as an upper-case copy, a replacement, and a join.
- **`std.json`**: a JSON parser, moving in from the Trig project.
- **A String API** for part-word appends and windowed writes.
- **Exact decimals** (`std.decimal`): a number as a big integer times a power of ten, on `std.bigint`, with rounding modes, a precision for division, and exact parsing and printing; probably a fixed 128-bit form first (about 28 digits, no allocation), as money code wants. It needs a short design round first.
- **A reactive library** in userland, grown from `examples/memo_canary.rig`.

## Tooling

- **Assertions** for `test` blocks, and running one test by name.
- **Sema facts in `rig check --facts`**: add sema's facts table (symbols, types, ownership operations, captures) to the syntax facts it prints today, in a versioned format for tools.
- **A formatter** that writes the canonical style, such as one blank line between top-level declarations.
- **Machine-readable diagnostics**: `rig check --json`, with machine-applicable fixes. Many diagnostics already name the fix, such as "write `rd(?n)`"; the JSON gives each fix as an edit to apply. Later, `rig explain`.
- **A language server**: `rig lsp` gives diagnostics, semantic tokens, the outline, and folding; next, types on hover and go to definition, completion, rename, and formatting, built on the facts table, and a file of a directory module checked as part of its module.
- **The language server in Rig**: someday, rewrite `rig lsp` in Rig itself, on Rig's std.json, reaching the compiler through `extern zig` (src/lib.zig), as a long-running, leak-free real-world Rig program.
- **C-ABI-friendly `extern` types.**
- **Drop plans from the ownership checker**: which bindings are consumed on every path, so the emitter can drop their alive flags and emit a plain `defer` or none.
- **Cached `rig build`**: `rig build` runs `zig build-exe`, which reuses no cached work, so every build compiles in full; emitting a small `build.zig` per package and running `zig build --prefix`, or copying the executable out of a `zig run` cache, would reuse it as `rig run` does.

## Compiler

- **Traces in Rig terms**: a panic, or an error that leaves `main`, prints Zig's stack trace, whose lines are in the emitted Zig (in the package directory `rig run` names); mapping them to `.rig` lines would need a source map.
- **An explicit emitter context**: the emitter keeps per-function state in `Emitter.fun`, swapped out around a closure's body; passing it explicitly would make what each helper reads visible.
- **Tighter generated code**: Debug builds pay for round trips such as `rig.lend(&rig.elemPtr(xs, j).*)` and `rig.eql((&p).*, (&q).*)`, and a generic `for x in xs` copies each element it only lends. Release builds optimize these away.
- **Nexus's `Span.text`** in place of slicing the source by position.
- **Runtime tests outside the runtime**: `src/runtime.zig` carries its unit tests into every emitted package; they could move to their own file.

## Open questions

Language decisions not yet made. Each describes what Rig does today;
any change would be future work.

- **`T??`** as a spelling of the nested optional `(T?)?`; today `??` after a type is the fallback operator, and the error points to `(T?)?`.
- **Function values as module constants** (`handler = on_click` at module level); a module constant holds only compile-time values today.
