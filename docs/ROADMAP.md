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
- **Quieter follow-on errors**: one mistake about a temporary can still give two diagnostics.
- **Printing byte slices**: `print` of a `[]U8` (rejected today, since it lowers like a `?String`).
- **A labeled value loop on the right of a binding** (`x = $l: for ...`), which needs a grammar change without conflicts.
- **APIs, the rest** ([design/apis.md](design/apis.md), whose five stages are built): API objects of an API with an associated type, `^{Source[Item: Int]}`, when a program needs one (Stage 4, phase 5); owned closures as shared objects of one method, one allocation instead of two, kept only if `bench/closures` clears the speed bar (Stage 5, phase 4); and the Lean model's crossing obligation for objects (Stage 5, phase 3).
- **Conditional compilation** on the target's operating system and CPU features and the build mode, as `std.target` gives the architecture (`target.arch`).
- **More compile-time functions** (the first form is built, SPEC "Compile-time functions"): a call over an enclosing generic's parameter and arithmetic on one in a type (`[cap[n]]Int`, `[n * 2]Int`), by hidden compile-time arguments the checker computes per instance; then text parameters (`hash[s: Static]`), plain objects, and reading module array constants in a body.
- **Raw pointers**: pointer types and pointer access inside `raw`, designed together with what `raw` code may assume.
- **Drop bodies for enums and generic types.**
- **A generic body's holding of a held `T`**: `*<x` in a body whose instance's `T` is already held (`T = ~N`) is rejected at that instance, as `*~N` written out is ("stacks one heap holding on another"); today the instance is accepted, and runs clean (SPEC §10, "Boxes, `^T`", pending example).
- **Copies out of a view in a generic body, per instance**: a view read where its `T` goes (`p` in `fun copy[T](p: ?T) -> T`, `v` of `if m.get(k) as v`) and `m.get(k) ?? d` take the per-instance `copies` requirement, as `Cell.get` does; today they are rejected outright, since `T` may not copy in every instance. Over-strict, not unsound; it waits for the generic per-instance requirements round ([backlog](internals/backlog.md)).
- **What a call stores through a lent read view**: `hold(!@, c: ?Cursor)` storing `c.items` keeps `c` itself lent while the holder is used, though only `c.items`' loans need to last (Core sentence 7). Over-strict; narrowing it needs a reach fact for a lent parameter's own view target and a call rule that stores the argument's held loans ([backlog](internals/backlog.md), the `corekeeps-p4` probes).
- **`from @field` through an alias of self**: `whole = ?@` then `whole.text` in a `from @text` body is reported as a view of all of `@`, since an alias of self carries no path. Over-strict; it waits for a program that writes it (the `from @field` review, parked).
- **A field of a bounded iterator's type**: `Hold[I: Iter]{inner: I}` is refused by `[I: Iter]` under `from @field`'s rule 4, which judges a field of a type variable at the declaration; judging it per instance would admit it, when an iterator adapter needs one (the `from @field` review).
- **API objects, the conservative edges** (Stage 4's reviews, each over-strict, none unsound): a `?String` view of a `String` with `add String: Shape` is no `?{Shape}` ("a view provides no API"), though the `String` itself erases; a local task over an object, `area_of(s)&` of a `?{Shape}` or `make()&` giving a `^{Shape + Owned}`, is refused as if it could leave its scope; `fun me(?@) -> ?{Shape} from @` cannot leave, since self erased is a copy by kind (H12); and `swap(!h.g, v)` of a `^{Shape}` is refused as a value that may hold a view, where a `^{Shape + Owned}` swaps. Each waits for a program that needs it.
- **A read view of a branch**: `?(a if c else b)` lends whichever name the branch picks, with no copy; today each branch is lent, `?a if c else ?b` (CORE §3, pending example).
- **A `for` over a made List of owners**: `for x in names()` walks the List a call makes and drops it after the loop, as a `for` over plain elements does; today the List is bound to a name first (CORE §3, pending example).
- **Tables, next** (`Table[T, n]` and `Slot[n]` are built, SPEC "Table"): a `Span` that std mints, covering a run of slots (`start`, `count`) with no test per element; then `program.files` as a table (Trig's phase 2, an eager table of an owning `File`); and, only if catching an id from another table at compile time is ever worth it, generative brands (`Table[T, B]`, `Id[B]`, a scope whose brand is fresh), which need rank-2 scopes and erased parameters. `pop`, `clear`, and `keep` (a `clear` restores every touched slot to `T()`).

- **std's I/O sets**: declared error sets for std's I/O functions and its other fallible ones, which fail with any error today (`text.parse_int -> Int!`, `std.file`, `std.net`, `std.io`), so a caller can match their members and a function that declares a set can pass their failures on with `!` rather than catch them ([SPEC §13](../SPEC.md#declared-sets-and-fields)); they wait for the owner's names.
- **Constant tables**: module constants built from constructors of plain types, for Trig's diagnostics catalog.
- **Text over several lines**: a literal that spans lines, for help text and templates; today each line is a literal and `String(a, b, c)` joins them (SPEC "Strings").
- **Several results**, after their first form (SPEC "Several results"):
  in registers when small, `from` per result, and a `for` that binds
  them each step.

## Speed

- **SIMD**, beyond `Simd[T, n]` as built (SPEC "Vectors"): lane shifts, `pad:` reads and `blocks(N)`, and one load for 4- and 8-byte byte-lane reads on ARM.
- **Zig 0.18**: LLVM's loop vectorizer, which Zig 0.17 turns off
  (docs/internals/zig-0.17.md §16), is back; measure plain loops again,
  and move std/terminal.zig's `widen` back into std/terminal.rig.
- **Checker-proved check elimination** through handles into stores (`@store.lists[Int(list.start) + k]`), which no local fact bounds; locals, Lists, field paths, `for` ranges, and flags are built ([internals/INTERNALS](internals/INTERNALS.md), "Proven checks").
- **A frame-size guard** for every function.
- **Bounds proofs from a guard's false edge** (`return 0 if i >= s.len` before `s[i]`) and constant indexes after a length test (`xs[0]` inside `if xs.len >= 2`): measured on Trig at about 0.1% (121 constant indexes after a test, beside 437 proven; `RIG_NO_PROOFS=1` costs ts-pattern 0.5% and zod3 0.7%), so they wait for a program they pay for.

## Concurrency

The model of [CONCURRENCY](design/concurrency.md) is built ([SPEC §18](../SPEC.md#18-tasks)): tasks (`f(x)&`, `>t`) owned by their scope, cancellation and deadlines, sets of tasks, `par`, channels and `select`, actors with their idle path, deadlock detection, failure and supervision, `task.isolate`, seeded deterministic tests, and `std.net` and `std.http` on a poller per worker. What comes next is the concurrency panel's ([concurrency/panel](design/concurrency-panel/README.md)):

- **Files and I/O**: a file layer with one `read`/`write` shape for files, sockets, and HTTP bodies; DNS; then TLS and an HTTP client.
- **Checking the runtime**: the next slices of the model's proofs ([design/concurrency](design/concurrency.md), "Proof obligations"), and model checking (TLA+, GenMC) before more hand proofs.
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
- **A String API** for part-word appends and windowed writes.
- **Exact decimals** (`std.decimal`): a number as a big integer times a power of ten, on `std.bigint`, with rounding modes, a precision for division, and exact parsing and printing; probably a fixed 128-bit form first (about 28 digits, no allocation), as money code wants. It needs a short design round first.
- **A reactive library** in userland, grown from `examples/memo_canary.rig`.

## Tooling

- **Assertions** for `test` blocks, and running one test by name.
- **A panic's report without Zig's frames**: a debug panic prints Zig stack frames with the machine's own paths, so no doc can show a panicking program's exact stderr; a switch (or a default for `rig test`) that prints only Rig's own lines.
- **Facts for tools**: `rig check --facts=sema` prints sema's facts for the compiler's own debugging; tools need them (symbols, types, ownership operations, captures) in a versioned format.
- **A formatter** that writes the canonical style, such as one blank line between top-level declarations.
- **Machine-readable diagnostics**: `rig check --json`, with machine-applicable fixes. Many diagnostics already name the fix, such as "write `rd(?n)`"; the JSON gives each fix as an edit to apply. Later, `rig explain`.
- **A language server**: `rig lsp` gives diagnostics, semantic tokens, the outline, and folding; next, types on hover and go to definition, completion, rename, and formatting, built on the facts table.
- **The language server in Rig**: someday, rewrite `rig lsp` in Rig itself, on Rig's std.json, reaching the compiler through `extern zig` (src/lib.zig), as a long-running, leak-free real-world Rig program.
- **C-ABI-friendly `extern` types.**
- **Drop plans from the ownership checker**: which bindings are consumed on every path, so the emitter can drop their alive flags and emit a plain `defer` or none.
- **Cached `rig build`**: `rig build` runs `zig build-exe`, which reuses no cached work, so every build compiles in full; emitting a small `build.zig` per package and running `zig build --prefix`, or copying the executable out of a `zig run` cache, would reuse it as `rig run` does.

## Compiler

- **Traces in Rig terms**: a panic, or an error that leaves `main`, prints Zig's stack trace, whose lines are in the emitted Zig (in the package directory `rig run` names); mapping them to `.rig` lines would need a source map.
- **An explicit emitter context**: the emitter keeps per-function state in `Emitter.fun`, swapped out around a closure's body; passing it explicitly would make what each helper reads visible.
- **Tighter generated code**: Debug builds pay for round trips such as `rig.lend(&rig.elemPtr(xs, j).*)` and `rig.eql((&p).*, (&q).*)`, and a generic `for x in xs` copies each element it only lends. Release builds optimize these away.
- **Nexus's `Span.text`** in place of slicing the source by position.
- **Compiler memory on generated shapes**: one straight-line function of 10,000 bindings takes 2.6 GB to check, and 20,000 take 10 GB (proofs most of it); a chain of generic functions each calling the next at `(fun(T) -> Int)?` grows about cubically, 300 links 1 GB and 1000 19 GB. No real program is near either; they wait for one ([backlog](internals/backlog.md)).
- **Runtime tests outside the runtime**: `src/runtime.zig` carries its unit tests into every emitted package; they could move to their own file.

## Open questions

Language decisions not yet made. Each describes what Rig does today;
any change would be future work.

- **`T??`** as a spelling of the nested optional `(T?)?`; today `??` after a type is the fallback operator, and the error points to `(T?)?`.
- **Function values as module constants** (`handler = on_click` at module level); a module constant holds only compile-time values today.
- **An `add` method follows its API's clauses**: `p.name()`, where an `add` block gives `p`'s type the method, keeps and views what the API's declaration says (its `from @`), not a narrower `from @a` the method itself states, since an addition's methods belong to the API and every call through one is checked by the API's signature (the oracle does the same). Narrowing it would need the oracle to read the instance's method for every dispatched call (consolidation round 2, row 11; the owner chose no change).
- **An addition built on another module's API** (Rust's rule, that an API's requirements are provided separately): today a built-in or another module's type provides an API built on another module's API only where one module declares both, so `add Int: Named` in `c` beside `b`'s `add Int: Shape` is refused. A question for the owner when a real program needs it (APIs Stage 3, phase 1 review).
- **`+s` of a `*{A}` in a result**: `first(?xs) -> *{Shape}` returning `+s` keeps `xs` lent while the result lives, since the hidden value may hold a view; `*{Shape + Owned}` or `+ Syncs` frees it. This is CORE's rule ("both forms carry the loans of what they hold"), the cost of an unnamed bound; narrowing it would be a CORE change (APIs Stage 5, phase 2 review).
