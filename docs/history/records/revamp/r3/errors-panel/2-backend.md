# Errors that carry data: the backend view (panel expert 2)

Zig 0.17.0 (installed), aarch64 macOS, `nice -n 19`, machine load 5.7–7
on 10 cores during the runs, so times are noisy; instruction counts
(`/usr/bin/time -l`, minimum of 7 or 9 interleaved runs) are the firm
numbers. Experiments: `errors-panel/backend-scratch/` beside this file
(`bench3.zig` + `run3.sh`, `site_bench.zig` + `runsb.sh`, `site.zig`
for x86-64 and wasm32 code, `inl.zig`, `sizes2.zig`, `trace.zig`,
`anyerr.zig`; raw output in `results3.txt`, `results3b.txt`,
`results_site.txt`).

## The decisions (for SPEC §13 and INTERNALS)

1. **Keep L3's meaning; narrow where the slot parameter appears.**
   Default: a named function gets the hidden `__out` parameter only when
   its set may carry fields (a declared set with a member that has
   fields, or `T!` in a program that declares one); every function
   *value* type (`?fun`, `*fun`, a closure, an API object's methods)
   gets it whenever the program declares any member with fields. *Reason:
   the proposal's "every fallible function" taxes field-less frames
   (Trig's `Bail` recursion) 11–15% in instructions for nothing, while
   uniform value types still mean function-pointer types never differ by
   set.*
2. **The slot is data only; the code stays Zig's error.** Default: the
   slot is `[N]u8 align(A)` sized for the callee's set (the program's
   largest for `T!`), written as the member's field struct after the
   writer casts it, and read only after a `switch` on the code says the
   member has fields. *Reason: a Zig-backed callee, a cancel
   (`task.Stop`), or any field-less member never writes it, and the
   catch needs no translation of the code.*
3. **The catch binding is the slot.** Default: `catch |err|` writes the
   captured code beside the slot's bytes and names that storage `err`
   (one `error_value` storage fact); no copy. A `catch` without a name
   calls the drop glue on the slot before its handler. *Reason: "a catch
   reads once" becomes "a catch reads zero times".*
4. **A set with fields is `struct { code: ZigSet, data: [N_set]u8 align(A) }`;
   `error` is the same with `anyerror` and the program's N.** A set
   without fields stays today's bare Zig error (2 bytes). Rejected: a
   Zig tagged union per set (the code would be translated at every catch
   and at every narrowing) and a bare `union` (a hidden safety tag in safe
   builds changes its size and makes punning between two unions panic).
   *Reason: `switch` on a declared Zig set is exhaustive with no `else`,
   and narrowing `error` to a set is a code test plus a prefix copy.*
5. **No automatic box.** Default: an `error` holds its fields inline at
   the program's largest member; the docs advise `^T` for large fields
   (decision 15 stands). Rejected: boxing `error` per value (16 bytes
   plus an allocation for every stored error with fields). *Reason: a box
   is a hidden allocation (North Star), and it allocates on the failure
   path, where the failure may be running out of memory.*
6. **Program-wide error glue is generated once.** Default: emit writes
   `__rig_error_drop(code, *data)`, `__rig_error_clone`,
   `__rig_error_eql`, `__rig_error_print`, and the `N`, `A` constants in
   one program-wide Zig file every module imports, re-exported from the
   root so the runtime reaches them through `@import("root")`, and a
   zero-size stand-in when no member has fields. *Reason: `error` is one
   type in every module, and its glue must switch over every member in
   the program.*
7. **An error's fields must be able to cross tasks.** Default: add a
   third field rule beside "never a view" and "always clones": no local
   `*` handle, no Cell of more than one word, no Signal, no function.
   *Reason: `Task[T!]` and an actor's failure carry any error to another
   thread, and a rule that depended on which errors a given task can
   produce would be non-local.*
8. **A task's failure data lives in its record.** Default: the job record
   holds the slot beside the result; `start` passes its address to `f`
   when `f` takes `__out` (a comptime test of the last parameter); `>t!`
   and `>t catch` copy it to the waiter's slot inside `wait`, before
   `release` frees the record. Every runtime site that keeps or discards
   a Rig failure keeps or drops its data: `wait`'s cancel path,
   `ParState.fail` (the first is kept, every later one dropped),
   `wait_first`'s `last`, `dropAll` in `select`, `parRun`'s helpers, the
   actor reply. *Reason: the task's frame outlives no catch, the record
   does, and the job's end already orders the write before the read
   (release/acquire).*
9. **Failing out of `main` or a test prints the fields through the
   generated printer, then drops them, then reports leaks.** Default:
   `failMain(code, data)`; the Zig `main` and `runTests` own the root
   slots. *Reason: decision 11 as written; the drop must come before the
   leak check or every such program reports a leak.*
10. **Zig's error return traces: keep Zig's default, never show them.**
    Zig 0.17 enables them only in Debug (measured: `@errorReturnTrace()`
    is non-null in Debug, null in ReleaseSafe and ReleaseFast), so release
    builds pay nothing; Rig prints `error: Set.member(...)` only. A
    `RIG_ERROR_TRACE=1` that dumps the trace in debug builds, as panics
    dump theirs, is a later option. *Reason: the frames are Zig's, not
    Rig's, and turning tracing off would change every debug build's code
    for no release gain.*
11. **Equivalence is a stated gate, with the runtime in a prior commit.**
    Default: `equiv.py` must show no `emit` difference for any program
    with no member that has fields. The runtime's plumbing (comptime-gated
    on the root's declaration) lands first as its own commit, so R3's
    `pkg` section is also unchanged against that base. *Reason: the `pkg`
    hash includes `runtime.zig`, whose text any plumbing changes for every
    program.*

**What I would overturn in the approved design:** only the scope of the
parameter in Q1/§4 ("every fallible function and function type gets it
when the program declares any set with fields"). L3 itself stands
against every alternative measured. I would also correct two claims:
that the `!` frames are "A's instruction for instruction" (true only
for a frame whose one fallible call is its last), and that a set's
value is "a Zig tagged union" (decision 4).

## Q1. Is L3 still the right lowering?

### What the proposal measured, and what it didn't

The proposal's `bench.zig` chains three `noinline` frames, each making
**one** fallible call as its last act. The slot pointer then arrives in
a register and leaves in the same one, so the `!` frames really are A's.
A real frame makes several fallible calls with work between them; the
pointer must then survive a call, so it takes a callee-saved register.
`bench3.zig` is a recursive walk whose every frame makes two fallible
calls (`l = walk(...)!`, `r = walk(...)!`, `l + (r ^ 5)`), caught once
per walk, one failing walk per 100 or 1,000.

Instructions per frame (minimum of 7–9 runs; times are minimum wall):

| Variant | Safe d=4 | Safe d=10 | Fast d=4 | Fast d=10 | time, Safe d=10 | time, Fast d=10 |
|---|---|---|---|---|---|---|
| A, today's error union | 37.92 | 37.17 | 27.92 | 27.20 | 0.51 s | 0.48 s |
| B, L3 slot parameter | 42.10 | 41.18 | 32.03 | 31.18 | 0.59 s | 0.49 s |
| C, tagged `Result` (L1) | 38.04 | 37.26 | 27.90 | 27.20 | 0.67 s | 0.54 s |
| T, slot pointer in the fiber's `TaskState` | 39.83 | 37.24 | 29.68 | 27.22 | 0.57 s | 0.48 s |

So B costs **about 4 instructions per frame that propagates**: 11% more
instructions in ReleaseSafe, 15% more in ReleaseFast. That is 16% slower
in Safe and within noise (2%) in Fast on an M-series core, which hides
the extra moves. The disassembly (`bench3f`, `_bench3.b` against
`_bench3.a`) shows where they go: a third `stp`/`ldp` pair to free a
callee-saved register (`x20`), `mov x20, x3` at entry, and `mov x3, x20`
before each call. The frame grows from 0x50 to 0x60 bytes, **16 bytes a
frame**, which matters for deep recursion on a fiber's fixed stack. x86-64
is the same shape (`site.zig`, `prop_b` against `prop_a`): one more
`push`/`pop` and two `mov`s.

C, the tagged `Result`, keeps the instruction count but is the slowest
in time (31% slower in Safe at depth 10, 12% slower in Fast): every frame
returns a 40-byte object through memory, and it would give up Zig's
`try` and `errdefer`. Its rejection stands.

### The alternative the proposal didn't weigh: the same slot, found through the fiber

Give the slot no parameter. Each catch site saves the running task's
"current slot", installs its own, and restores the old one after the
call; a failing frame writes through the current slot. Under the
proposal's desugaring this is the same program: at every fallible call,
the installed slot is exactly the `__out` that L3 would pass, because
only catch sites (and the roots: `main`, tests, a task's start) install
one, and each restores on both exits, which always run since Rig never
unwinds. It fixes L2's nesting bug, and it removes every signature
change, so function types, shims, thunks, and the runtime's generic
`spawn` see nothing.

Two measurements decide against it:

- **A thread-local is unsound here.** On aarch64 the catch site computes
  the thread-local's address once, before the call, and restores through
  it after (`site_d`: `mov x19, x0` from `__tlv_get_addr`, then `str x20,
  [x19]` after `bl`). A fiber that moves threads during the call restores
  another thread's slot. sched.zig's `me()` exists for exactly this
  reason. The slot must live in the fiber's `TaskState`, reached through
  `task()`.
- **`task()` makes the catch site expensive.** `site_bench.zig`, a loop of
  `v = leaf(x) catch |e| e.pos` over a non-inlined leaf, gives
  instructions per call:

  | Variant | Safe | Fast | time, Fast |
  |---|---|---|---|
  | A, today | 36.35 | 34.33 | 0.21 s |
  | B, slot parameter | 39.37 | 35.33 | 0.21 s |
  | G, a plain global (wasm32, no threads) | 38.33 | 36.35 | 0.21 s |
  | D, a thread-local (unsound, above) | 52.48 | 45.48 | 0.31 s |
  | H, `task()` hoisted out of the loop | 46.46 | 41.46 | 0.26 s |
  | T, `task()` at each catch | 92.01 | 85.97 | 0.68 s |

  A catch per call is 3.2× slower under T than under B. Hoisting `task()`
  would need a storage fact for where to put it, and the result is still
  slower than B.

So neither lowering wins everywhere. B pays per propagating frame,
T per catch site. The fix is to keep B and stop it paying where it buys
nothing.

### The recommendation: L3, with the parameter only where fields can travel

- A **named function** takes `__out` only when its set may carry
  fields. Its callers know its declaration, so a direct call passes the
  slot or doesn't. A field-less declared set (`T!Bail`, `T!GlobError`
  today) is A, byte for byte. That covers Trig's deep `Bail` exits and
  every field-less error in std.
- **Function values are uniform.** In a program with fields, every
  fallible function value type takes `__out` (`FnRef`, `Closure`, an API
  object's slots), so covariance (`fun -> T!A` where `fun -> T!B` is
  expected) never needs a new runtime adapter. The existing comptime
  thunk in `FnRef.ofFn` passes the slot to a function that takes it and
  drops it for one that doesn't, which also covers Zig-backed shims used
  as values. A call through a value whose set has no fields passes a
  dummy pointer, which nothing writes.
- **Subset makes sizing safe.** The caller's slot is sized for the
  callee's set; a `!` passes its own `__out` only to a callee whose set
  is inside its own (decision 10), so `N_callee ≤ N_frame`. `return err`
  of a held `error` copies its bytes into `__out`: the only copy, on the
  failure path.

### Each claim of the proposal, checked

| Claim | Verdict |
|---|---|
| The success path gains one pointer argument | True for a frame whose one fallible call is its last. Otherwise about 4 instructions, one callee-saved register, and 16 bytes of stack per propagating frame (above). |
| A `!` copies nothing | True: `try g(a, __out)` passes the pointer through. |
| Inlining removes it | True. `inl.zig`: with an `inline` callee, `site_b` compiles to 7 instructions, with no stack slot (scalar replacement), and `site_b_unread` folds into `site_a` (8). |
| Function values and shims | Under "every fallible function", a shim used as a value needs a thunk (the proposal's §8). Under decision 1, `FnRef.ofFn`'s existing comptime thunk absorbs it, and direct shim calls need nothing. |
| Recursion | Correct, and the pointer is the same for the whole chain; the cost is the per-frame register and 16 bytes of stack above. |
| wasm32 | Fine. The error union already returns through the shadow stack, so a catch site adds 3 wasm instructions (`site_b` 25 against `site_a` 22) and a propagating frame 2 (`prop_b` 42 against 40). An `anyerror!void` callee returns in a register, so its catch site newly needs a shadow-stack frame (about 6 instructions). |
| Allocates nothing; nested failures can't overwrite | True (the slot is the catching frame's local). |
| A program with no fields emits exactly today's Zig | Achievable (Q6). |

## Q2. A stored `error`: `List[error]`, a field `err: error`, `error?`

Sizes (`sizes2.zig`) for a program whose largest member is
`bad(pos: Int, msg: String)`:

| | ReleaseFast | Debug / ReleaseSafe | wasm32 (Safe) |
|---|---|---|---|
| `String` | 24 | 32 | 16 |
| `{code, [N]u8}` (recommended) | 40 | 48 | 32 |
| `{code, bare union}` | 40 | 56 (hidden safety tag) | 40 |
| `{code, box}` | 16 + an allocation | 16 + an allocation | 8 + an allocation |
| `?{code, [N]u8}` | 48 | 56 | 40 |
| `anyerror` (no fields anywhere) | 2 | 2 | 2 |

- **Inline at the program's largest member (recommended).** `error` is
  `{ code: anyerror, data: [N]u8 align(A) }`. `List[error]` costs `N + 8`
  a slot, even for a field-less error. Drop, clone, `==`, and print are
  one generated `switch` on the code (prototype: `anyerr.zig`, which
  prints `ParseError.bad(pos: 0, msg: "x1")` through it and switches
  exhaustively, with no `else`, on a declared set).
- **A box per error with fields: rejected.** It is a hidden allocation,
  it allocates while failing, and drop must free it.
- **A program-wide tagged union: rejected.** Its tag duplicates Zig's
  code, and a bare union's safety tag in safe builds both grows it and
  makes writing one union type and reading another a panic.
- **A declared set with fields** is the same shape at its own `N`, with
  its code typed as its Zig set: `List[E]` pays only for `E`.
- **`error?`** is Zig's `?T`, 8 bytes more. The code's zero value could
  serve as `none` (as `?anyerror` already does), but that would mean a
  special optional in emit. Leave it for a measured need.

## Q3. Errors crossing tasks

What must hold:

- The error is a moved value whose fields are owned (decision 2 already
  says they are never views). The new requirement is that its fields
  may live on another thread: decision 7.
- The write must happen-before the read. The task writes its record's
  slot before `control.finish()` and the job's end; the waiter reads
  after `waitEnd`, which acquires. That is the ordering the result
  already relies on.
- No path may lose data: a cancel that drops a failed result, a failure
  `parRun` keeps only the first of, `wait_first`'s `last` overwritten,
  and `select`'s `dropAll`. Each must call `__rig_error_drop`, or a
  `String` field leaks. These are the sites in `src/tasks.zig` that hold
  an `anyerror` today: `ParState.failure`, `wait_first`'s `last`,
  `dropAll`, `wait`'s cancel path, and the actor reply near line 1649.

How it lowers: the task's record (one allocation with its `Control`
today) gains `data: [N]u8 align(A)`. `Fiber.run` calls `f` with
`&record.data` appended when `f`'s last parameter is `rig.ErrSlot`
(known at comptime), so the task's failing frame writes straight into
the record, with no copy. `wait` takes the waiter's slot and copies the
member's bytes into it before `release`. Its size comes from the task's
declared set, which emit passes as a comptime type, so a `Task[T!E]`
waiter's smaller slot is never overrun. A cancel or timeout is a
`task.Stop` member, which has no fields and writes nothing.

## Q4. Slot size for `T!` callers

It is acceptable. The slot is stack space at catch sites of `T!` callees
only, in programs that declare fields, and LLVM's stack colouring merges
the slots of sibling catches. A field-less set's catch reserves nothing.
The cost that is not local is `error` and `List[error]`: one large member
in one module enlarges every `error` in the program. Boxing it
automatically is rejected (decision 5). Keep decision 15's advice, and
show the cost: `rig check --facts=storage` could print `error`'s size
and the member that sets it. A catch in a recursive function puts `N`
bytes in every level, and `rig build`'s existing warning for a frame
larger than a page (`src/frames.zig`) already catches the bad case. I
would not add a 64-byte warning: sizes differ by mode and target
(`String` is 24, 32, or 16 bytes above), so Rig cannot state the
threshold honestly at check time.

## Q5. Printing at `main`, and Zig's error return traces

`failMain(err: anyerror)` becomes `failMain(code, *data)`, which calls
the root's `__rig_error_print`. That printer writes the member as
payload enums print (`Set.member(field: value)`, with strings quoted)
and falls back to `errorShown` for a member without fields. Then it
drops the fields, so the leak check that follows sees none. `rig test`'s
report does the same.

Traces (`trace.zig`): Zig keeps error return traces only in Debug. There
the trace pointer is itself a hidden parameter, and every error return
calls `__zig_return_error` (visible in `trace_d.o`). So in debug builds
Zig already does what L3 does, for its own purpose. Recommendation 10:
keep Zig's default, show nothing, and consider `RIG_ERROR_TRACE=1`
later.

## Q6. The `equiv.py` promise

Under decision 1 it is achievable, and narrower in what changes:

- **No member with fields in the program:** no function gains `__out`,
  no function value type changes, no catch reserves a slot, and the glue
  file is a zero-size stand-in. `emit` is identical. `pkg` is identical
  only if the runtime's plumbing (`ErrSlot`, `failMain`'s data, the task
  record's slot, the `Test` table's function type) lands first, as a
  commit that changes no behavior (`if (@hasDecl(root, "__rig_error_data"))
  ... else void`). Otherwise `runtime.zig`'s text changes every
  program's `pkg` hash.
- **Fields in the program:** only functions whose set may carry fields,
  function value types, catch sites of such callees, and the glue file
  change. A field-less function's Zig is unchanged, which the
  proposal's program-wide rule could not promise.

The test is an `equiv.py` run of R3 against the plumbing commit, with
zero `emit` and `pkg` differences outside the new tests. It belongs in
R3's gates.
