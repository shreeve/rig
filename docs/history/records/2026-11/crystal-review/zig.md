# Crystal 1.23.0-dev, seen through Zig and systems cost

Reviewer lens: Zig (comptime, explicit allocation, error unions, cost model,
C ABI, LLVM). Source read at `~/Data/Code/rig/misc/crystal`; Rig read on
`origin/main` (QUICK, SYNTAX, SPEC §15/§16/§18, CORE, mantras, INTERNALS
"Pipeline"/"Generics"/"Split builds", concurrency.md, scheduler.md "Stacks",
ROADMAP). Nothing was built or run; every claim below is from reading code.

## How the compiler works

**Front end.** One hand-written lexer and parser,
`src/compiler/crystal/syntax/lexer.cr` (2,884 lines) and `parser.cr`
(6,621 lines). Whitespace changes meaning: `parse_call_args_space_consumed`
(`syntax/parser.cr:4866`) turns `foo -1` into a call with a negative argument
and `foo - 1` into a subtraction, and the same goes for `&`, `*`, `**`, and `::`
(`parser.cr:4873-4895`). Whether `/` starts a regex or divides is lexer state
(`slash_is_regex!`, `parser.cr:114`, `364`, `393`, ...). It reads well, but it
is hard to give a grammar or a second tool.

**Semantic analysis is whole-program inference by type propagation.** Every
AST node has `dependencies` and `observers` (`semantic/bindings.cr:73-80`).
When a node's type widens it pushes the change to its observers, and a call
whose argument types change runs `recalculate` (`semantic/call.cr:36`).
Every method is typed once per tuple of argument types, cached by
`DefInstanceKey(def_object_id, arg_types, block_type, named_args)`
(`types.cr:887-905`, `semantic/call.cr:396-401`). On a cache miss it runs a fresh `MainVisitor`
over the body (`call.cr:407-410`). So:
- a `def` is a template, and every argument-type tuple makes an instance,
  in both typing and codegen (C++-style bloat, invisible at the call);
- nothing is typed separately. Every compile types the prelude, the stdlib,
  and the program from scratch, through the phases in `semantic.cr:6-15`.
  No typed-module cache exists;
- an error shows where propagation reached a contradiction, often far from
  its cause. That is why `bindings.cr:113-167` builds an "owner trace" to
  explain how a value became `Nil`.
- `SmallNodeList` (`bindings.cr:1-10`) keeps the first two observers inline,
  saving four allocations per node. That shows how much the binding graph
  weighs.

**Incremental builds stop at codegen.** In a debug build Crystal writes one
LLVM module per type. It keeps each module's bitcode in a cache directory
and reuses the old `.o` when the new bitcode is byte-identical
(`compiler.cr:890-940`, `must_compile?` at `918`). Units compile on threads
(`compiler.cr:641-660`). A release build is one module (`compiler.cr:278-283`),
and so is a cross build (`compiler.cr:364`). So an edit costs a full
semantic pass and full Crystal codegen, then saves the LLVM object time of
the types it left alone.

**Unions and how they lower.** Crystal has several union representations:
- a `MixedUnionType` is `{i32 type_id, [N x iK] payload}`. The payload is an
  integer array sized and aligned to the largest member
  (`codegen/unions.cr:17-46`). Values are stored inline, so there is no box,
  but each store writes a type id and each read loads and compares it
  (`unions.cr:56-80`). Because the payload is an integer array, LLVM sees
  type punning, and SROA often keeps such unions in memory;
- a `NilableType` (`T | Nil` with `T` a reference) is a plain nullable
  pointer (`llvm_typer.cr:220-222`), a niche at no cost;
- unions of references, and virtual (hierarchy) types, are an `i32*`: every
  heap object starts with its type id (`llvm_typer.cr:224-242`,
  `type_id.cr:16-22`);
- `LLVMId` numbers types in depth-first order, so "is a subclass of" is a
  range compare (`codegen/llvm_id.cr:4-25`, used at `codegen/match.cr:66-74`);
- dispatch is no vtable. `codegen_dispatch` (`codegen/call.cr:339-440`) emits
  a chain of type-id tests and direct calls, one branch per matching overload
  and argument type, joined by a phi. That is fine for 2-3 types and grows
  linearly with more.

**Hidden allocation.**
- Every `class` instance is GC memory: `allocate_aggregate` calls `malloc`,
  or `malloc_atomic` when the type holds no pointers
  (`codegen/codegen.cr:2297-2320`).
- A local captured by a closure lives in a heap context for the whole
  function, allocated at its entry (`malloc_closure`, `codegen.cr:2174-2200`),
  so the capture costs at a line that never mentions it.
- `Array(T)` is a class with a separately allocated buffer (`src/array.cr:48-65`),
  two allocations per array.
- `String` is one allocation with an Int32 byte size and a cached Int32
  char length (`src/string.cr:294`), which limits strings to 2 GiB.
- The GC is Boehm (`src/gc/boehm.cr:89-91`), which scans fiber stacks
  conservatively (`boehm.cr:507-508`).
- Exceptions use LLVM `invoke` and landing pads on every call that may raise
  (`codegen/call.cr:517-526`).

**Blocks.** `yield` blocks are inlined at the call site
(`codegen_call_with_block`, `codegen/call.cr:279`), so `each { }` costs
nothing. That is Crystal's best cost-model feature. A block captured as
`&block` becomes a heap closure.

**Codegen quality.** In release mode it is good, close to C for struct and
`Slice` code: one LLVM module at -O3, overflow checks
(`codegen/primitives.cr:138-196`) that LLVM mostly folds, and direct calls
where the type is known. It loses on unions in hot paths, on
GC allocation, and where dispatch chains replace monomorphic calls. A debug
build compiles quickly because of the per-type split.

**The interpreter** (`crystal i`, `src/compiler/crystal/interpreter/`, 11,380
lines) compiles the typed AST to a bytecode with its own stack of 8 MiB, malloc'd
(`interpreter/interpreter.cr:116`). It calls C through libffi
(`interpreter/c.cr:72-74`, `compiler.cr:1972`, `2065`). It shares semantic
analysis with the compiler, so it still pays for whole-program inference;
it skips only LLVM. It is a second backend with semantics of its own:
blocks, closures, and the stack it grows upward
(`fiber/stack_pool.cr:12-19`, which disables guards for it).

**Macros** form a second language, interpreted over the AST and producing
**text** that is parsed again (`macros/macros.cr:22-66`, `parse_macro_source`).
They reflect on types: `@type.instance_vars`, `methods`, `subclasses`,
`annotations`, `has_method?` (`macros/methods.cr:2085-2125`, `1473`).
`instance_vars` means something only after top-level semantic analysis
(`semantic.cr:96-102`). A macro inside a `def` expands at each instantiation, which is
how `JSON::Serializable#to_json` loops over the fields with their
`@[JSON::Field]` annotations (`src/json/serialization.cr:298-330`).
`{{ run("file.cr") }}` compiles a whole host program, caches the
executable, and runs it as a subprocess (`macros/macros.cr:70-136`). Hooks
(`macro included`, `inherited`, `finished`, `method_missing`) run code
the reader cannot see from the call.

**C interop.** A `lib` block declares structs, unions, enums, constants,
`fun`s, varargs, and callbacks, with `@[Link]` for libraries
(`src/lib_c/aarch64-darwin/c/sys/mman.cr:1-28`,
`src/lib_c/aarch64-darwin/c/time.cr:23-26`). Out-parameters are a keyword:
`LibC.clock_gettime(clock, out tp)` (`src/crystal/system/unix/time.cr:35`,
AST `syntax/ast.cr:1622`, declared at `semantic/main_visitor.cr:578`). A
Crystal value converts to its C form through an implicit `to_unsafe` call
(`semantic/conversions.cr:23-47`). The costs:
- it implements the C ABI itself (`codegen/abi/*.cr`, 784 lines across
  x86, x86_64, win64, aarch64, arm, avr, and wasm32);
- it keeps a hand-written `lib_c` for each target triple (`src/lib_c/`,
  about 20 directories);
- passing a closure to C is caught at compile time
  (`semantic/cleanup_transformer.cr:591`) or else as a run-time `raise`
  (`codegen/codegen.cr:1620`).

**Cross-compilation** (`--cross-compile --target`) writes one `.o` and prints
the linker command for the user to run on the target
(`compiler.cr:442-461`). The target must supply libgc, libpcre2, and the
others. It is far behind `zig build-exe -target`, which Rig already gets.

**Fiber stacks.**
- Each stack reserves 8 MiB (`STACK_SIZE`, `src/fiber/stack_pool.cr:6`) by
  `mmap(PRIVATE|ANON)`.
- On Linux the stack is marked `MADV_NOHUGEPAGE`, with a guard of 4096 bytes
  made by `mprotect(PROT_NONE)` (`src/crystal/system/unix/fiber.cr:4-22`).
- `reset_stack` does nothing (`fiber.cr:24-25`), so a reused stack keeps
  every page the last fiber touched.
- The pool is a deque, so the next fiber reuses the stack most recently
  freed, and the thread's dead fiber stack first (`stack_pool.cr:107-116`).
  A `collect_loop` frees half the pool every 5 s (`stack_pool.cr:34-53`).
- Nothing emits stack probes, so a frame larger than 4 KiB can jump the
  guard. The SEGV handler then guesses "stack overflow" from whether the
  address is within 4096 bytes of the stack (`unix/signal.cr:175-201`).
- Rig has already done this better: guards sized from the largest frame
  the compiler bounds, stacks carved 16 at a time, a per-worker cache
  (`docs/internals/scheduler.md`, "Stacks").

**Event loops** are solid and current:
- epoll and kqueue are edge-triggered and register a descriptor once
  (`event_loop/epoll.cr:86`, `kqueue.cr:120`);
- a generational arena indexed by fd keeps the loop from storing GC
  pointers in the kernel (`event_loop/polling.cr:55-80`,
  `polling/arena.cr:1-40`);
- an io_uring loop keeps one ring per scheduler sharing one kernel work
  queue, with lock-free cross-ring cancel on Linux 6.13+
  (`event_loop/io_uring.cr:1-40`);
- IOCP serves Windows, and libevent is the fallback.

**Channels and select.** A Go-like `Channel(T)`. `select` sorts the ops' locks by
object id to avoid deadlock (`channel/select.cr:94`), copies a tuple of ops
to a `StaticArray` so it allocates nothing (`select.cr:83-88`), then takes
the *first* ready op in source order (`select.cr:98-110`), with no random
pick. A blocking select allocates its shared state on the heap
(`select.cr:117-121`). A value sent on a channel stays aliased by the
sender, and data races are possible. `Fiber::ExecutionContext::Isolated`
gives one fiber a thread of its own (`fiber/execution_context/isolated.cr:4-30`).

## Scores (1-10)

| Area | Score | Why |
|---|---|---|
| Syntax | 8 | Ruby's readability with types where you want them; `end` noise and whitespace-sensitive unary operators (`foo -1`) are the cost. |
| Operators | 7 | A rich, coherent set (`&+` wrapping, `//`, `**`, `&.`, `||=`), but any operator can be overloaded and `===` in `case` is a hidden call. |
| Type system | 6 | Nil-safety by flow typing and union types is a real win. But unions widen silently, generics are checked only per instance, nothing compiles separately, and errors land far from causes. |
| Object system | 6 | Choosing class (heap) or struct (value) is a visible cost choice, and type-id ranges make `is_a?` cheap. Reopened classes, mixins, and `method_missing` make "what does this call do" a whole-program question. |
| Grammar | 5 | A 9.5k-line hand-written lexer and parser, with whitespace-dependent parses and regex/slash state. Only Crystal can parse Crystal. |
| Concurrency | 6 | Fibers with good event loops (ET epoll, kqueue, io_uring, IOCP) and new execution contexts. But nothing prevents data races, and 8 MiB stacks with 4 KiB guards and no probes. |
| Channels | 6 | Go's model done carefully (sorted locks, no allocation for a tuple select). Sent values stay shared, the pick is biased to the first ready op, and close raises. |
| Macros and compile time | 5 | Strong reflection, but as text templates in a second untyped language that runs per instance, plus `run` subprocesses. Zig's comptime gets more from one language. |
| Cost model | 4 | Every class is GC'd, captures are heaped at function entry, unions add type-id dispatch, every raising call gets landing pads. Structs, `StaticArray`, `Slice`, and inlined `yield` are the escape hatches. |
| C interop | 8 | `lib` blocks are the best part: structs, unions, callbacks, varargs, `out`. Pulled down by an ABI layer of its own, per-triple `lib_c` copies, and implicit `to_unsafe`. |
| Standard library | 7 | Broad and pleasant, with modern event loops. It allocates freely, and sizes are Int32 (2 GiB strings and arrays). |

## Ideas worth taking, ranked

### 1. C structs and pointer parameters as views: `out` without a keyword

Crystal (`src/lib_c/aarch64-darwin/c/time.cr:23`, `src/crystal/system/unix/time.cr:35`):

```crystal
lib LibC
  struct Timespec
    tv_sec : TimeT
    tv_nsec : Long
  end
  fun clock_gettime(clk : ClockidT, tp : Timespec*) : Int
end
ret = LibC.clock_gettime(clock, out tp)
```

**Rig today.** Only integers, floats, and `Bool` cross the C boundary, and
there are no raw pointers (SPEC §15). ROADMAP lists "raw pointers" and
"C-ABI-friendly `extern` types", with `[]U8` going to C as a pointer plus a
length. Planned, not built.

**Rig form.** The view sigils already say what a C pointer parameter means:

```rig pending
extern obj Timespec
  tv_sec: I64
  tv_nsec: I64

extern fun clock_gettime(clk: I32, tp: !Timespec) -> I32

fun now() -> Timespec
  ts = Timespec()
  raw
    clock_gettime(1, !ts)
  ts
```

- `extern obj` lowers to a Zig `extern struct`. Its fields may only be C
  types: integers, floats, `Bool`, other `extern obj`s, and fixed arrays of
  them.
- In an `extern fun`, `!T` lowers to `*T` and `?T` to `*const T`.
- `?[]U8` lowers to a pointer and a length, as ROADMAP has settled.

This dissolves `out` with no new word: an out-parameter is a write view.

**Guarantees.** It keeps them. A view lent to an `extern` call ends at the
return, as a view lent to any call does. A C function that keeps the
pointer needs `keeps`, so it stays inside `raw`. Zig owns the ABI, so Rig
needs none of Crystal's 784-line `codegen/abi/` layer. Zig's `std.c` and
`translate-c` mean no hand-kept `lib_c` per triple.

**Risk.** Lending an object that holds a `List` or `String` must be
rejected. Only `extern obj` may cross.

### 2. Compile-time field iteration, checked per field, for derived code

Crystal (`src/json/serialization.cr:304`):

```crystal
{% for ivar in @type.instance_vars %} ... @{{ivar}} ... {% end %}
```

**Rig today.** `$variants(T)`, `$name`, `$size`, and `$type` exist, and
`Eq`, `Hash`, `Print`, and `Ord` are derived from fields by the compiler
(SPEC "Own meanings"). No user code can walk an object's fields. So
std.json's typed decode, and any serializer or ORM, needs either the
compiler's help or a code generator.

**Rig form.** A `for` over `$fields(T)`, unrolled when Rig checks the
program. Each copy is checked with `f` naming one field:

```rig pending
sub write_obj[T](out: !Writer, x: ?T)
  for f in $fields(T)
    !out.key(f.name)
    !out.value(?x.(f))
```

**Guarantees.** They hold only if Rig unrolls the loop in the IR *before*
sema and ownership run, so the checker checks exactly what is emitted. If
Zig's `inline for (@typeInfo(T).@"struct".fields)` did the unrolling, emit
would be deciding something the checker never walked, which breaks North
Star 4.

**Cost.** Checking per instance, as Crystal does. It should be confined to
the loop body, not the whole function, so generic bodies stay
checked-once elsewhere.

**Not this.** Crystal's text templating, and its annotations as a second
attribute language. If per-field options are needed (a JSON key name),
they are a separate naming decision for the owner.

**Fit.** Mantras "Substrate in the language, libraries in userland" and
"concentrate the pain" favor this over growing the list of built-in
derivations.

### 3. `MADV_NOHUGEPAGE` on task stacks (Linux)

Crystal (`src/crystal/system/unix/fiber.cr:12-14`) marks every fiber stack
`MADV_NOHUGEPAGE`.

**Rig today.** `sched.takeStack` (`src/sched.zig:3350-3378`) maps
`guard + 64 MiB + page` with `NORESERVE` and `mprotect`s the stack
read-write. Nothing in `src/*.zig` calls `madvise` on stacks. The only
`MADV_HUGEPAGE` is in `alloc.zig:545`, for the heap.

**Risk.** On a Linux host with THP set to `always` (the RHEL and Fedora
default; pup is evidently `madvise`, given its 5.2 KiB per task), the first
touch of a 2 MiB-aligned stack can fault in a whole huge page. That turns
"one page per sleeping task" into 2 MiB.

**Fix.** One `madvise` per carved chunk, plus a `test/cli` script run under
THP=always.

**Guarantees.** It changes no semantics, so it keeps them. Not measured
here: this needs a pup run with THP switched to `always`.

### 4. Reuse a split unit's object when its own code is unchanged

Crystal (`compiler.cr:890-940`) writes one module per type, compares its
bitcode with the cached copy, and reuses the `.o` when they match.

**Rig today.** Split builds give each unit the whole package and a root
that differs (INTERNALS "Split builds"). Zig's cache keys each unit on every
file it reads, so an edit to one module rebuilds all N units' objects.

**Rig form.** Emit each cut function's body into a file of its own
unit, and give other units its signature only, as the `rig.split.away`
stub already does. Then unit K's inputs change only when K's own bodies,
or the signatures they call, change. Alternatively, hash the
per-unit set of owned declarations and skip `zig build-obj` when the
hash and the shared signature file are unchanged.

**Guarantees.** It keeps them: the same Zig is compiled, only less often.

**Cost.** It must clear the "a speed feature pays for its lines" bar. The
win is in edit-compile time for Trig's debug builds (30 s of Zig), not
run time.

### 5. Guaranteed inlining of a block a callee calls in place

Crystal inlines `yield` blocks by construction (`codegen/call.cr:279`), so
`xs.each { |x| ... }` has the cost of a `while` loop.

**Rig today.** It has stack closures and callable views `?fun`, which never
allocate. Whether a `?fun` passed to a small iterator is inlined is left to
Zig and LLVM. Rig has `inline fun` as a speed marker.

**Worth checking.** Do `inlining.zig`'s program-wide decisions always inline
a callee that takes a closure literal and calls it in a loop? Crystal
shows that this is the case users write most.

**Guarantees.** A marker asks for speed, never for meaning, so they hold.
This is a measurement task, not a feature.

### 6. A reference for Rig's io_uring work

Crystal's loop (`event_loop/io_uring.cr:1-40`) has:
- one ring per scheduler, attached to a shared work queue;
- `IORING_OP_MSG_RING` and sync cancel on Linux 6.13+, so no lock is
  needed to submit to another scheduler's ring;
- a periodic sweep of every ring's completion queue, so a worker stuck in
  CPU work does not strand completions.

Rig's concurrency.md lists io_uring as measured work. This is a worked
design to read first. It keeps Rig's guarantees: it is runtime only.

### 7. A pointer-free allocation class

Crystal picks `malloc_atomic` when a type holds no pointers
(`codegen.cr:2302-2307`). For Rig, with no GC, the analog is weaker: a
type the compiler knows is pointer-free could take a size-class arena that
never needs zeroing or scanning. Rig's allocator (`alloc.zig`) may already
gain nothing from this. List it only if a profile shows zeroing or page
faults on large pointer-free buffers.

## What Rig should NOT take

- **Whole-program type inference and silent union widening**
  (`semantic/bindings.cr`, `call.cr:396`). Costs:
  - no separate checking and no cache of typed modules;
  - errors far from causes;
  - a type that grows behind the reader's back, turning reads into
    type-id dispatch;
  - nonlinear recalculation.

  Rig checks a generic body once (INTERNALS "Generics"), which is the right
  trade for check speed and for "effects stay visible".
- **Text macros, hooks, and `method_missing`** (`macros/macros.cr:22-66`).
  - A second, untyped language that generates code no checker sees until
    it is parsed again.
  - `macro inherited`/`finished`/`method_missing` run code the reader
    cannot see from the call.
  - It conflicts with "the checker checks exactly what is emitted" and
    with one mechanism per idea. Rig's cteval plus idea 2 cover the
    real uses.
- **`macro run`** (`macros/macros.cr:70-136`). It compiles and runs an
  arbitrary program while compiling. A build then depends on the host and
  the timestamps of files, and `rig check` could no longer give "the same
  verdict on every machine" (SPEC §16).
- **Implicit `to_unsafe`** (`semantic/conversions.cr:23`) and **implicit
  numeric conversions at C calls** (`conversions.cr:2-20`). Both are
  hidden calls at the boundary where cost and safety matter most.
- **Type-id unions as the general sum type** (`codegen/unions.cr:17-46`).
  An integer-array payload defeats SROA, and every read is a load and a
  compare. Rig's enums with payloads lower to Zig tagged unions with real
  field types, which LLVM can split. And "an object that names its none"
  already gives the niche that Crystal's `NilableType` gets.
- **Dispatch by type-id chains** (`codegen/call.cr:339-440`). Linear in the
  number of types and invisible at the call. Rig's `?{Shape}` table call is
  one visible indirection, and a bound `[T: Shape]` is direct.
- **Exceptions with landing pads** (`codegen/call.cr:517-526`). Rig's `T!`
  with `e!` is visible, costs a branch, and leaves LLVM free to optimize.
- **A GC, or a closure context heaped at function entry**
  (`codegen.cr:2174-2200`). These are the opposite of Rig's no-hidden-cost
  rule. Rig's capture list `|+n, ?m|` is the better design.
- **An 8 MiB stack with a 4 KiB guard, no probes, and a guessing SEGV
  handler** (`stack_pool.cr:6`, `unix/fiber.cr:16-18`,
  `unix/signal.cr:175-201`). Rig's guards sized from frame bounds already
  dissolve this problem.
- **A bytecode interpreter as a second backend** (`interpreter/`, 11k
  lines). Its semantics drift from the compiled program's, and it still
  pays for full semantic analysis. If Rig wants faster edit-run, it should
  come from Zig's own backends and incremental builds, idea 4, or a wider
  cteval, never from a second meaning of the program, which accept-means-correct
  cannot cover.
- **Hand-written per-triple libc bindings and an ABI layer of its own**
  (`src/lib_c/`, `codegen/abi/`). Zig provides both, for every target.
- **Int32 sizes** (`string.cr:294`). Rig's `Int` is 64-bit, and should
  stay so.
- **Whitespace-dependent parses** (`syntax/parser.cr:4866-4895`). Rig's
  touching-sigil rule is already positional, but it is one rule, applied
  everywhere. Crystal's per-token exceptions show what happens without one.
