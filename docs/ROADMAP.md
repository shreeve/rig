# Roadmap

Where Rig is going, one line each. Nothing here is scheduled; the order
follows what real programs need, and each item lands only when it can
be checked as thoroughly as what exists. The forms the compiler
rejects today as not supported yet are listed, with their diagnostics,
in [SPEC §19](../SPEC.md#19-reserved-and-unsupported-forms).

## Language

- **More compile-time values on generic types**: `Bool` and enum value parameters (`obj Ring[T, n: Int]` takes integers only).
- **Owning values in more places**: arrays of owning values.
- **`?String` values**: matching on them.
- **Reading more through temporaries and optionals**: `o?` of an owned optional parameter read through a view where only read (`o?.len`), and a read-only use of an owning field of a temporary (`print(mk().t)`), both rejected today.
- **Quieter follow-on errors**: one mistake about a temporary can still give two diagnostics.
- **Printing byte slices**: `print` of a `[]U8` (rejected today, since it lowers like a `?String`).
- **A labeled value loop on the right of a binding** (`x = $l: for ...`), which needs a grammar change without conflicts.
- **Traits or bounds** whose dispatch and ownership stay visible in the IR, so a generic signature says what its type parameters support; `[T: Trait]` is kept free for them, told from a value parameter by what the name after `:` denotes.
- **Conditional compilation** on the target's operating system and CPU features and the build mode, as `std.target` gives the architecture (`target.arch`).
- **Compile-time functions**: pure functions over plain data that the checker itself evaluates, for constant tables and sizes computed from a compile-time parameter (`[n * 2]Int`, `[cap(n)]Int`), so a failure is a Rig diagnostic rather than a Zig error.
- **Raw pointers**: pointer types and pointer access inside `raw`, designed together with what `raw` code may assume.
- **Drop bodies for enums and generic types.**

- **Several results**, after their first form (SPEC "Several results"):
  in registers when small, `from` per result, and a `for` that binds
  them each step.

## Speed

- **SIMD**: `Simd[T, n]` vectors with `m.first()` and `any`/`all`, `t.lookup(idx)`, `cur.lag[k](prev)`, `+|` and `-|`, and lane shifts; then `pad:` reads and `blocks(N)`.
- **Checker-proved check elimination**: bounds and overflow checks the checker proves redundant, redesigned around units.
- **A frame-size guard** for every function.

## Concurrency

The model of [CONCURRENCY](design/concurrency.md) is built ([SPEC §18](../SPEC.md#18-tasks)): tasks (`f(x)&`, `>t`) owned by their scope, cancellation and deadlines, sets of tasks, `par`, channels and `select`, actors with their idle path, deadlock detection, failure and supervision, `task.isolate`, seeded deterministic tests, and `std.net` and `std.http` on a poller per worker. What comes next is the concurrency panel's ([concurrency/panel](design/concurrency-panel/README.md)):

- **Files and I/O**: a file layer with one `read`/`write` shape for files, sockets, and HTTP bodies; DNS; then TLS and an HTTP client.
- **Deadlines**: `time.within` calling its closure exactly once, which replaces `within:`, `wait_all`, and `task.both`.
- **Checking the runtime**: model checking (TLA+, GenMC) before more hand proofs, and `no_orphans` restated over whoever holds a task.
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
- **A language server**: `rig lsp` gives diagnostics, semantic tokens, the outline, and folding; next, types on hover and go to definition, built on the facts table.
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

## Decided, not started

Work that is decided but not started. Where Rig stands, and the work in
progress, is in [HANDOFF.md](../HANDOFF.md).

### After v0.3.0's in-flight work

The in-flight list is in HANDOFF.md, "What comes next". Decided, not
started:

- SIMD: `pad:` reads and `blocks(N)`.
- A String API for part-word appends and windowed writes.
- A known over-strict rejection: what a call stores from a view reached
  through a lent read view should carry that view's loans, not a loan
  on the holder (Core sentence 7). `hold(!@, c: ?Cursor)` storing
  `c.items` must say `keeps c`, and then keeps `c` itself lent while the
  holder is used, though only `c.items`' loans need to last. Narrowing
  it needs a new reach fact (what a lent parameter's own view target is,
  apart from what it reaches through the views it holds) and a call rule
  that stores the argument's held loans instead of its lend. Probes:
  the cases `corekeeps-p4 store through view` and `corekeeps-p4b keeps
  through view` of test/rig/probes-08.rig.test.
- Several results, after v1 (SPEC "Several results"):
  - small results in registers: pack results of up to two words of
    integers, `Bool`s, and pointers into a `u128`, which Zig's default
    calling convention returns in registers where it returns a tuple
    or an object through memory; it serves objects too, and lands only
    if it passes the speed rule;
  - write lends ended per argument: while a result holds a write view,
    the lends of the arguments its origins leave out could end at the
    return, as they do when no result holds one;
  - `from` per result, so a write view and a read view may come from
    different parameters whose types could both hold either, and
    several write views a function proves disjoint (sentence 5);
  - a `catch` or `??` fallback that gives every result (`catch 0, 0`);
  - `for k, v in it` over an iterator whose `next` gives several
    results, decided with iterators as values;
  - `ResultBound` per result, so a proven bound on a result reaches the
    name that takes it (`src/proofs.zig`).
- bench/hash after inlining a generic type's small members (#246), on
  the Mac (aarch64), pooled medians of 8 layouts x 21 runs against main:
  - `int hit` is 2-6% slower, and `small 4` and `small 8` 2-3% slower:
    LLVM spills registers differently in a function that holds several
    loops once more is inlined into it. The code of `int hit`'s loop is
    the same as main's, and x86 shows no difference. Needs a study.
  - `int edit_put-hit` is 3.0% slower (95% interval -3.8% to +9.6%):
    inside the noise, but worth measuring again.
  - Judge memory-bound bench/hash rows by medians with intervals and an
    unchanged control row, not by the fastest of N runs, which swung
    single rows several percent either way on unchanged code.
- Every copy out of a view in a generic body takes the per-instance
  `copies` requirement, as `Cell.get` and a `??` through a view of an
  optional do: today a view read where its `T` is expected (`p` in
  `fun copy[T](p: ?T) -> T`, `v` of `if m.get(k) as v`) and
  `m.get(k) ?? d` are rejected outright, as `T` may not copy in every
  instance.
- A generic body's own holding of a `T` (`h = *<x`, `List[*T]`, a call
  passing `<x` to `*T`) at an instance whose `T` is held (`T = ~U`
  makes `*~U`): rejected per instance, with the generic per-instance
  requirements round (option (b)). SPEC "Box" shows it as pending.
- Destination-passing for values over about 64 KiB: emit passes,
  returns, and copies none by value through a Zig temporary, and lowers
  a `defer` or inlined body that declares one to a single call. A
  frame's real size is then bounded by construction; today it is a
  measured bound, `sema.reach_factor` (4) times its reach, which
  `test/cli/frame_reach.sh` checks, and a form Zig copies that reach
  does not model could exceed it. Two did in #230's review, both fixed:
  a payload part a `match <e` arm drops, passed by value at each exit
  (the case `rev230-discard-exits` of test/rig/probes-16.rig.test); and the same at 12,000
  exits, whose 48 GB frame made Zig's aarch64 build fail with `fixup
  value out of range` (`test/cli/discard_build.sh`; a frame over 4 GiB
  draws Zig's warning, and one that large fails to build).
  With it, build debug programs for x86_64 with `-fllvm`, as aarch64's
  are.
- The reference checker (`bin/rig-oracle`) takes memory quadratic in
  the exits of one `match` arm. For an arm `.one(_, n)` of `match <e`
  with that many `return ... if ...` lines, its peak resident memory:

  | Exits | Peak memory |
  |---|---|
  | 50 | 6.7 MB |
  | 100 | 10 MB |
  | 200 | 24 MB |
  | 400 | 74 MB |
  | 12,000 | 52 GiB (measured on Linux) |

  At 12,000 exits it took down a 7 GB CI runner, so that program is a
  CLI test (`test/cli/discard_build.sh`), which the checker never sees,
  rather than a case of test/rig. Make it linear, then the program can
  become a case.
- Switching to Nexus's `Span.text`.
- `text.ByteSet`, a byte set built once when the program runs and
  searched with `set.find(s, at)`: the run-time sibling of
  `text.find_any[set]`. Built when a port needs a set known only at run
  time; none does yet.
- Big integers in the standard library, to replace Trig's own: arbitrary
  precision, enough for JavaScript number and BigInt work (Trig's jsnum
  uses them in 3 places). Trig's version passes all 32,076 of its test
  cases; the std one must pass the same cases and be as fast before Trig
  swaps.
- `std.hash` with 4-byte stored hashes (an entry's hash takes 8 bytes
  today): the tag from the stored bits up to 2^25 slots, and from the
  top of the whole hash, recomputed from the keys, past that. It
  matched the 8-byte version's speed; it saves 4 bytes an entry.
- A built-in generic named through a module agrees on both sides: as
  an expression, `lib.List[Int].filled(2, 3)` reaches the local `List`,
  while as a type, `lib.List[String]` is reported as "`lib.List` is not
  public".
- Generic inference looks through a box as a method call does: with
  `bx: ^List[P]`, `first(?bx)` (`first[T](xs: ?List[T])`) is a type
  mismatch, though `first[P](?bx)` is accepted.
- An unwrap of an optional that traps when it is `none`. `std.hash`'s
  `Map.ensure` reaches its value, which is never `none` there, with a
  `while true` whose only exit is a `return`; the unwrap would replace it.
- A deep clone of a type parameter's value in a generic body (`+k` of a
  `?K` where `K` owns text). With it, `Map.ensure`, `Map.put_new`, and
  `Set.add` take a `?K` and copy the key only when it is stored (owner
  approved); today they take an owned `K`.
- A lane method on a call's write view of a `Simd` reads through it:
  `vs(!v, 0).with(0, 7)`, where `vs` returns `!Simd[I8, 4]`, is
  accepted, and emit writes `rig.withLane(rig.rt(vs(&v, 0)), ...)`
  with no dereference, which Zig rejects.
- One classifier for a plain enum. `sema.isPlainEnum` (what `==` and
  emit's scalar test read) counts a variant with an empty payload,
  `a()`, as bare, but `sema.enumValues` (what `Int(x)`, `from_int`,
  `$variants`, and ordering read) does not, as resolve gives it no
  value. So for `enum E` of `a()` and `b`, `x == E.b` is accepted and
  `x > E.b` and `Int(x)` are rejected as "variants with payloads".
  Decide once whether `a()` is bare (or reject the empty payload), and
  have both read it.
- Objects nested by value, deep or wide, fail inside Zig, not in Rig
  (rule 2), found by #270.
  - Probe: a chain `obj A0` .. `obj A99`, each with nine `Int` fields and
    `a: A<i+1>` (the last `s: String`), then in `main`, `x: A0? = none`
    pushed into a `List[A0?]`.
  - Today Zig reports `evaluation exceeded 1000 backwards branches` in
    the runtime's `needsDrop`, reached from `List.clear`. A chain with
    one field per object fails near 950 deep, and past about 1500 Zig
    itself crashes.
  - Fix:
    - give the runtime's recursive reflective helpers `rig.eval_quota`,
      as emitted functions have;
    - add a sema limit on how deeply types nest by value, below where
      Zig crashes.
- Compiler memory on two generated shapes, the same on main, found by
  #270's review.
  - One straight-line function of 10,000 bindings takes 2.6 GB, and one
    of 20,000 takes 10 GB. Proofs take most of the time, and likely the
    memory.
  - A chain of generic functions, each calling the next at
    `(fun(T) -> Int)?` of its `T` (which adds no instance depth), grows
    about cubically: 300 links take 1 GB, 1000 take 19 GB.
- A generic `?T` parameter bound to an optional of a view fails in Zig
  (rule 2): `sub show[T](x: ?T)` called as `show(b)` with
  `b: (?Node)? = ?n` emits `show(?*const Node, &b)`, and Zig wants a
  `T`.
  - Cause: sema's `copiedByReadView` holds a read view of a view by
    address, while the runtime's `ReadView(T)` copies any pointer.
  - Make the two rules one. This changes how such views are held, so it
    is its own round.
- The "ever deeper instances" message fires on finite chains. Thirty
  generic functions, each calling the next at `Box[T]` of its `T`
  (`f0[T](x: T)` calls `f1(Box(v: x))`, ...), are rejected at the 25th
  with "a generic function cannot call itself with its own type
  parameters nested deeper". No function there calls itself. Say that
  instances nest more than 24 deep instead. The same limit also rejects
  `$name(Wrap[T?])` inside `Wrap`'s own method.
- Lending a handle parameter to write is accepted as `!c` but rejected
  as a capture. In `sub poke(c: *Cell[Int])`, `(!c).set(2)` lends the
  Cell `c` holds, while `f = |!c| (!c).set(3)` is "cannot lend parameter
  `c` to write". So is `!o.h` for `o` an owned parameter. Decide whether
  a capture and a field lend, like `!c`, lend what the handle holds.

### Agent tooling

- `rig check --json`, with machine-applicable fixes. Many diagnostics
  already name the fix, such as "write `rd(?n)`"; the JSON gives each
  fix as an edit to apply.
- A formatter that writes the canonical style.
- Later, `rig explain`.
- The language server's phase 2 (`rig lsp`, editors/README.md): hover,
  go to definition, completion, rename, and formatting; and a file of a
  directory module checked as part of its module.

## Open questions

Language decisions not yet made. Each describes what Rig does today;
any change would be future work.

- **`T??`** as a spelling of the nested optional `(T?)?`; today `??` after a type is the fallback operator, and the error points to `(T?)?`.
- **Function values as module constants** (`handler = on_click` at module level); a module constant holds only compile-time values today.
