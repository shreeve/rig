# Roadmap

Where Rig is going, one line each. Nothing here is scheduled; the order
follows what real programs need, and each item lands only when it can
be checked as thoroughly as what exists. The forms the compiler
rejects today as not supported yet are listed, with their diagnostics,
in [SPEC §19](../SPEC.md#19-reserved-and-unsupported-forms). Where the
work stands is in [HANDOFF](../HANDOFF.md), and the decided engineering
items, with their probe cases, are in
[internals/backlog](internals/backlog.md). Ideas the owner has not
decided are kept in [IDEAS](IDEAS.md) until he approves or rejects them.

## Language

- **Iterator chains** ([design/iterators.md](design/iterators.md), approved 2026-10-27): `xs.map(f).filter(g).sum()`, `take`, `skip`, `enumerate`, `zip`, and the consumers `sum`, `count`, `reduce`, `collect`, `any`, `all`, `find`, `min`, `max`, each chain fused into the `for` loop it means; read chains first; built after the Swisstable Map and Set lands.
- **More compile-time values on generic types**: `Bool` and enum value parameters (`obj Ring[T, n: Int]` takes integers only).
- **Quieter follow-on errors**: one mistake about a temporary can still give two diagnostics.
- **Printing byte slices**: `print` of a `[]U8` (rejected today, since it lowers like a `?String`).
- **A labeled value loop on the right of a binding** (`x = $l: for ...`), which needs a grammar change without conflicts.
- **APIs, the rest** ([design/apis.md](design/apis.md), whose five stages are built): API objects of an API with an associated type, `^{Source[Item: Int]}`, when a program needs one; owned closures as shared objects of one method, one allocation instead of two, kept only if `bench/closures` clears the speed bar; and the Lean model's crossing obligation for objects.
- **More compile-time functions** (the first form is built, SPEC "Compile-time functions"): a call over an enclosing generic's parameter and arithmetic on one in a type (`[cap[n]]Int`, `[n * 2]Int`), by hidden compile-time arguments the checker computes per instance; then text parameters (`hash[s: Static]`), plain objects, and reading module array constants in a body.
- **Raw pointers**: pointer types and pointer access inside `raw`, designed together with what `raw` code may assume.
- **Drop bodies for enums and generic types.**
- **A read view of a branch**: `?(a if c else b)` lends whichever name the branch picks, with no copy; today each branch is lent, `?a if c else ?b` (CORE §3, pending example).
- **A `for` over a made List of owners**: `for x in names()` walks the List a call makes and drops it after the loop, as a `for` over plain elements does; today the List is bound to a name first (CORE §3, pending example).
- **Tables, next** (`Table[T, n]` and `Slot[n]` are built, SPEC "Table"): a `Span` that std mints, covering a run of slots (`start`, `count`) with no test per element; then `program.files` as a table (an eager table of an owning `File`, for Trig); and, only if catching an id from another table at compile time is ever worth it, generative brands (`Table[T, B]`, `Id[B]`, a scope whose brand is fresh), which need rank-2 scopes and erased parameters. `pop`, `clear`, and `keep` (a `clear` restores every touched slot to `T()`).
- **std's I/O sets in its signatures**: `FileError` and `NetError` exist (`std.file`, `std.net`), but std's I/O functions and its other fallible ones (`text.parse_int -> Int!`, `std.io`) still fail with any error, so a caller cannot match their members, and a function that declares a set cannot pass their failures on with `!` rather than catch them ([SPEC §13](../SPEC.md#declared-sets-and-fields)). Declaring them in the signatures waits for the owner's names for the rest.
- **Per-server `http.serve` limits**: arguments to `http.serve` that set the header, body, and timeout limits for one server; the environment sets them for the whole process today ([STD, std.http](STD.md#stdhttp)).
- **Constant tables**: module constants built from constructors of plain types, for Trig's diagnostics catalog.
- **Not waiting, `task.poll(...)`**: the named select's arms, given at once to whichever can complete now, or `none` when none can, matched as `none =>` (records/2026-11/revamp-compiler/panel-select-designer.md).
- **The closure arms of `task.select` go**: the old spelling, `!ch.on_recv(f)`, is removed in the release after 0.3; `tools/migrate-select.py` rewrites it to named arms (SPEC "Channels").
- **Several results**, after their first form (SPEC "Several results"):
  in registers when small, `from` per result, and a `for` that binds
  them each step.

## Speed

- **A check-speed round** once the language's features settle, after the compiler revamp's phase 2: `rig check` does about 12% more work on bench/check's workload than on 10-13, about 1% for each feature and no single regression (records/2026-11/revamp-compiler/ledger.md). Measured on Trig's real check (about 2 s) as well as the workload, with a budget for each pass.
- **SIMD**, beyond `Simd[T, n]` as built (SPEC "Vectors"): lane shifts, `pad:` reads and `blocks(N)`, and one load for 4- and 8-byte byte-lane reads on ARM.
- **Zig 0.18**: LLVM's loop vectorizer, which Zig 0.17 turns off
  (the Zig 0.17 workarounds in [INTERNALS](internals/INTERNALS.md)), is back; measure plain loops again,
  and move std/terminal.zig's `widen` back into std/terminal.rig.
- **An LLVM backend** (planned for December 2026; the owner, 2026-11-04): a lowered IR first, private to Rig, with a text form a Nexus grammar parses back for round-trip tests and yield points as explicit operations; then LLVM behind a flag, beside the Zig backend.
- **Checker-proved check elimination** through handles into stores (`@store.lists[Int(list.start) + k]`), which no local fact bounds; locals, Lists, field paths, `for` ranges, and flags are built ([internals/INTERNALS](internals/INTERNALS.md), "Proven checks").
- **Bounds proofs from a guard's false edge** (`return 0 if i >= s.len` before `s[i]`) and constant indexes after a length test (`xs[0]` inside `if xs.len >= 2`): measured on Trig at about 0.1% (121 constant indexes after a test, beside 437 proven; `RIG_NO_PROOFS=1` costs ts-pattern 0.5% and zod3 0.7%), so they wait for a program they pay for.

## Concurrency

The model of [CONCURRENCY](design/concurrency.md) is built ([SPEC §18](../SPEC.md#18-tasks)): tasks (`f(x)&`, `>t`) owned by their scope, cancellation and deadlines, sets of tasks, `par`, channels and `select`, actors with their idle path, deadlock detection, failure and supervision, `task.isolate`, seeded deterministic tests, and `std.net` and `std.http` on a poller per worker. What comes next is the concurrency panel's ([concurrency/panel](history/records/2026-10/concurrency-panel/README.md)), in the owner's order (2026-11-07): preemption by signal on by default; tasks as small as the best runtimes'; a mixed-workload benchmark; then files and I/O:

- **Files and I/O**: a file layer with one `read`/`write` shape for files, sockets, and HTTP bodies; DNS; then TLS and an HTTP client.
- **Checking the runtime**: the next slices of the model's proofs ([design/concurrency](design/concurrency.md), "Proof obligations"), and model checking (TLA+, GenMC) before more hand proofs.
- **Tasks as small and as cheap as the best runtimes'** (the owner, 2026-11-04, for v0.3.1; [concurrency-review](history/records/2026-11/concurrency-review/SYNTHESIS.md)), in this order:
  - measure first: the stack a parked task has live, the page tables `ru_maxrss` does not count, and bench/tasks against Tokio, Rayon, Go, and Swift, scaling over cores too;
  - the cheap fixes (built): the deadlock walk off task stacks, free stacks shared between workers and returned in runs, small-page advice on stacks, and every signal handler on the alternate stack;
  - counted loops strip-mined, with one yield check for each block of turns, for `fanout`;
  - small stacks, in this order (the panel, 2026-11-08, [records/2026-11/task-memory/](history/records/2026-11/task-memory/small-stacks.md)): preemption that switches to the worker's stack first, with the vector state off the task's stack; the cheap fixes (surplus stacks released by `madvise`, not `munmap`; no huge pages on stacks; every runtime signal handler on an alternate stack per worker; the deadlock walk off task stacks); cold paths (panic, formatting, foreign calls) on the worker's stack; a census of each `&` site's bound, from a fail-closed analysis of the final executable, as the go/no-go; then size classes chosen by it, with canaries and sanitizer guards. Segments that never move wait: recursive tasks take the large stack;
  - Rayon's fork-join at no cost behind the same `&`: the task record in its maker's frame, and an unstarted task run on its waiter's stack;
    - **one syntax:** the program writes `f()&` and `>t` as now. The runtime takes the free path when the task has not started, its maker waits for it, the wait has no deadline, and the task's frames fit. Otherwise the task runs as a fiber, as one a thief takes does;
    - **why Rig can:** tasks are owned by their scope, so a record in the maker's frame cannot outlive it, and `sched.handoff` already runs an unstarted task the moment it is awaited, on the task's own stack;
    - **to design:** a panic in a task run inline ends only that task and reaches its waiter at `>t`; recursive tasks, whose stack use no bound proves, run on stacks growing by segments;
    - **only half of Rayon's speed:** the rest is loops with no yield checks (preemption by signal) and `par` splitting its work by what is left, as `par_iter` does, so idle workers take large pieces and busy ones split no further. `par` gets that splitting in the same round;
  - connections shaped as actors in `std.net` and `std.http`, so an idle connection holds no stack.

  The memory goal is under Go's 2.9 KiB a sleeping task on the Mac. Small stacks and the fork-join each take a design round first. Small stacks meet preemption first: the signal handler needs 32 KiB free below the stack pointer (`preempt_room` in src/sched.zig), so a task on a small stack could never be stopped until a stop switches to the worker's stack at once, with the vector state off the task's stack (about 0.5 KiB of room).
- **A mixed-workload benchmark**, before any claim against Tokio or Go: open-loop load (bench/http's generator is closed-loop and understates p99), mostly plain requests with a share that compute for about 1 ms, thousands of idle connections held, cancellation and deadlines, on pup; Rig plain and with preemption by signal against Go and hyper, reporting throughput, p50 and p99, and memory.
- **Preemption by signal on every target it can run on**, with no option to choose it (the owner, 2026-11-07; turning it on by default waits for his yes). Each target stops a long computation one way, which the compiler chooses: a signal on Linux x86-64 and arm64 macOS (built, behind `RIG_PREEMPT=signal`), then Linux arm64, and Windows by suspending the thread, as Go does there. Where nothing can interrupt a thread, as in WebAssembly and freestanding code, the yield checks stay. Two cases keep the checks on every target: seeded test runs, whose interleavings must not depend on time, and a program that makes local tasks, which take turns at yield checks ([records/2026-11/preempt/](history/records/2026-11/preempt/design.md)).
- **Later**: thread-sanitizer annotations for fibers, freeing a long-sleeping task's stack, and io_uring.
- **The model's planned rules** ([design/concurrency](design/concurrency.md)): cleanup shielded from a cancel within a grace deadline, so a canceled connection still writes its close frame; a panic in an actor's method, on the actor's own task, waiting for the tasks the method started; a debug build's watchdog for a canceled task still running; a debug dump of what every task waits on, for waits on several channels; and a lint over which actor types call each other.

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
- **Packages**: depending on another person's Rig code by name and version; today `use` finds modules by path only (SPEC §14). A design round after v0.3.1.
- **std.json's writer**: std.json reads; it does not yet write.
- **The rest of std.terminal** ([design/terminal.md](design/terminal.md), "What is not built"): a reading API for a renderer (cells, styles, the cursor, and which rows changed); then OSC (titles, palette and color queries, hyperlinks, the clipboard), then mouse and focus reporting; resize and reflow; and `std.tty` (raw mode, size, PTYs) last. The order is the owner's to choose.
- **Durations in std.time** as keyword units, `ms: 50`, `ns: 500`, or a plain Int or Float of seconds, in place of `n * time.MS` (the owner, 2026-11-04: to decide later).
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

## Open questions

Language decisions not yet made. Each describes what Rig does today;
any change would be future work.

- **`T??`** as a spelling of the nested optional `(T?)?`; today `??` after a type is the fallback operator, and the error points to `(T?)?`.
- **Function values as module constants** (`handler = on_click` at module level); a module constant holds only compile-time values today.
- **An `add` method follows its API's clauses**: `p.name()`, where an `add` block gives `p`'s type the method, keeps and views what the API's declaration says (its `from @`), not a narrower `from @a` the method itself states, since an addition's methods belong to the API and every call through one is checked by the API's signature (the oracle does the same). Narrowing it would need the oracle to read the instance's method for every dispatched call.
- **An addition built on another module's API** (Rust's rule, that an API's requirements are provided separately): today a built-in or another module's type provides an API built on another module's API only where one module declares both, so `add Int: Named` in `c` beside `b`'s `add Int: Shape` is refused. A question for when a real program needs it.
- **`+s` of a `*{A}` in a result**: `first(?xs) -> *{Shape}` returning `+s` keeps `xs` lent while the result lives, since the hidden value may hold a view; `*{Shape + Owned}` or `+ Syncs` frees it. This is CORE's rule ("both forms carry the loans of what they hold"), the cost of an unnamed bound; narrowing it would be a CORE change.
