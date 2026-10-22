# Compile-time functions and fun values in tasks: syntax and cost review

Checkout read: `~/Data/Code/worktrees/rig/fun-and-comptime` at 4805cd800 (read-only).
Grammar experiments: `fc-panel/grammar-try/` (a copy), checked with `nexus check`
and built with `zig build`. The diff is in `fc-panel/grammar-recommended.diff`.
Probes are in `fc-panel/probes-b/` and `fc-panel/zigcost/`.

## Verdict

- **Feature 1 (compile-time functions without a keyword)**: the syntax is sound.
  The declaration needs **no grammar change**. Calls in expressions already
  parse. Calls in array sizes, in arithmetic inside types, and with text
  arguments inside types need a small grammar change, which is **conflict-free**
  (tested). Readers lose one fix-it: a forgotten `()` on a generic function
  now declares a compile-time function. The rules below contain that. Done as
  recommended (Rig evaluates, emit writes literals), compiled programs pay
  nothing. The compiler pays for an evaluator, bounded by a step limit and
  memoization.
- **Feature 2 (plain `fun` values cross)**: costs nothing at run time. A
  `fun(...)` value is a `*const fn` word, and task arguments are copied bit
  for bit. The change is in the checker only. The emitted Zig does change:
  `spawnLocal` becomes `spawn`, through the existing local-task fact.
  **Soundness trap:** the type `.function` also types stack closures and closure
  literals, which are structs that hold captures. Unblocking `.function` in
  `sema.blockerIn` as it stands would let a closure that captures `|!x|` run on
  several cores (probe `h.rig`). The type must first tell a function pointer
  from a closure.

## Feature 1: grammar

### What parses today (built binary, `rig parse`)

| Source | Tree | Status |
|---|---|---|
| `fun cap[n: Int] -> Int` + body | `(fun cap ((: n Int)) _ Int ...)`: tparams set, params nil | parses. The Parser wrapper (`paramList`, src/rig.zig:3424) rejects it with "write `fun cap[n: Int]() -> Int`" |
| `X = cap[20]` | `(set _ X _ (index cap 20))` | parses |
| `cap[a, b]` | `(inst cap a b)` | parses |
| `Ring[Int, cap[4]]` | `(generic_inst Ring Int (generic_inst cap 4))` | parses (a targ is a type) |
| `h = hash_of["if"]` | `(index hash_of "if")` | parses |
| `fs[0](1)` | `(call _ (index fs 0) 1)` | parses |
| `[cap[4]]Int` | none | **parse error**: `dim` takes only an integer, a name, a member, or arithmetic |
| `[cap[4] * 2]Int`, `Ring[T, cap[4] + 1]` | none | **parse error**: `cunit` has no call |
| `Ring[T, hash_of["x"]]` | none | **parse error**: `targ` takes no string |
| `fun table[] -> T`, `table[]` | none | parse error ("empty brackets"; SPEC: brackets are never empty) |
| `sub s[n: Int]` | `(sub s ((: n Int)) _ ...)` | parses. The wrapper rejects it with the `()` fix-it |
| `fun cap[n: Int](?@)` in an obj | `(fun cap ((: n Int)) ((read @)) ...)` | an ordinary generic method |

### Recommended grammar change (tested: `nexus check` reports no errors, 1746 states)

```
tatom    = ...
         | ccall                                    # replaces: name:tname "[" args:types ![","] "]" → (generic_inst)
targ     = ...
         | STRING_DQ                                # `hash_of["if"]` inside a type
         | STRING_SQ
dim      = ...
         | ccall                                    # `[cap[n]]T`
cunit    = ...
         | ccall                                    # `[cap[4] * 2]T`, `Ring[T, cap[4] + 1]`

# A compile-time call in a type, or a generic type's instance: `[cap[4]]T`, `Wrap[Int]`.
ccall    = name:name "[" args:types ![","] "]"       → (generic_inst)
         | name "." name "[" types ![","] "]"       → (generic_inst (member 1 3) ...5)
```

How it was reached, so nobody retries the dead ends:

1. Adding `ccall = name:tname "[" ...` to `cunit` gives two **LALR**
   reduce/reduce conflicts (`tname → IDENT` against `cunit → IDENT` on `,`).
   The states for `T[ IDENT` and `T[ a * IDENT` have the same core once `tname`
   can be reached from `cunit`, and merging them merges their lookaheads.
   Canonical LR(1) would not conflict.
2. Spelling `ccall` with a plain `name`, while `tatom` keeps `tname "["`, gives a
   shift/reduce conflict: `tname → IDENT •` against `ccall → IDENT • "["`.
3. One shared `ccall` with `tname` inlined, used by `tatom`, `dim` and `cunit`,
   is conflict-free. After `IDENT [ types ]` the parser reduces to `ccall`, then
   to `tatom` or `cunit` by the next token. Only `cunit` is followed by
   `+ - * / %`, and only `tatom` by `?` `!`. This mirrors how `name` serves
   both `tname` and `cunit` today.

Checks after building the modified grammar:

- `rig parse` gives byte-identical trees for all 43 `.rig` files in `std/`,
  `examples/` and `bench/`.
- The qualified form `geo.Wrap[Int]` still gives `(generic_inst (member geo Wrap) ...)`.
- Swarm areas `types-ct`, `types-generic`, `modules-imported`, `modules-misc`,
  `syntax-misc`, `emit-generic`, `doc-SPEC` and `doc-SYNTAX` all pass, except one
  case in the first trial. That trial also allowed empty brackets, and
  `syntax-misc` "empty type args" then got a checker message instead of the
  parse hint. That is why the recommendation drops empty brackets (below).
  On the recommended grammar, 11 areas run with no failures: `types-ct`,
  `types-generic`, `types-misc-1`, `types-misc-2`, `modules-imported`,
  `modules-misc`, `syntax-misc`, `syntax-bytes`, `emit-generic`, `doc-SPEC` and
  `doc-SYNTAX` (1,606 jobs). The full suite was not run, since full runs on the
  Mac are not allowed.

New trees: `[cap[4]]Int` → `(array_type (generic_inst cap 4) Int)`;
`[cap[4] * 2 + 1]Int` → `(array_type (+ (* (generic_inst cap 4) 2) 1) Int)`;
`[m.cap[2]]Int` → `(generic_inst (member m cap) 2)`;
`[cap[cap[2]]]Int` nests.

### Zero-parameter `fun table[] -> T`: recommend **no**

The grammar takes empty brackets without conflict (`tparams | "[" "]"` and
`postfix "[" "]"`, both tested). But a compile-time function with no
parameters is just a constant, and module constants already exist. SPEC
already says brackets are never empty, and a test asserts the parse hint
"empty brackets: give the compile-time arguments". Keep both. A table is written
`fun table[n: Int] -> [n]U8`, then `TABLE = table[256]`. If the owner wants
parameterless compile-time code, the cleaner reading is to let a module
constant's initializer run compile-time code (`TABLE = build()`), not `[]`.

### Telling call, index, type and generic apart

Every form already parses to a node that sema classifies by what the object
names. The precedent is SYNTAX §11: "`x[...]` indexes `x` or gives it
compile-time arguments by what `x` names".

| Object resolves to | `x[a]` (`index`/`inst` in an expression, `generic_inst` in a type) |
|---|---|
| a local, parameter or field (any value, including an array of `fun`) | an index. `fs[0](1)` calls an element |
| a generic type | an instance (unchanged) |
| a generic function | today's error: "call it with `twice[Int](...)`" |
| a **compile-time function** | a compile-time call. Sema records its value as a fact keyed by the node |

Shadowing works as it does for everything else: a local named `cap` hides the
function. The parser wrapper cannot classify calls, since the callee may be in
another module, so it leaves call nodes alone. Sema decides once and records the
result: the node is a compile-time call, and here is its value
(North Star 4). Emit reads only the value.

`T[n]` in a type where `T` is a compile-time function gives a **value**, not a
type. Where a type is required: "`cap[4]` is a compile-time value (`Int`), not a
type". Version 1 should not have compile-time functions return types; that is
what generics are for.

### Declaration rules and tree shape (Parser wrapper)

In `paramList` (src/rig.zig:3424), before the fix-it, rewrite the node to a
kind of its own when **all** of these hold:

- it is a `fun`, not a `sub`;
- it is declared at module level (not inside an `obj` or `enum`, and not
  `fun T.name`);
- it has brackets and no parentheses;
- **every** bracket field is `name: Type`, with no bare type parameter and no
  bound.

Proposed shape (the name is the owner's call):
`(ct_fun name:leaf params:group returns body:block)`. The bracket fields move
into `params`. A kind of its own means ownership, storage, proofs, inlining
and emit skip it without a check of their own. Only sema and typecheck (and
the evaluator) read it. In every other case today's fix-it stands unchanged,
so the forgotten-`()` diagnostic survives where it matters most:

- `sub s[n: Int]`: "write `sub s[n: Int]()`: a function's parameter list is
  always written, even when empty". A `sub` gives no value, and compile time has
  no effects, so a compile-time `sub` means nothing.
- `fun first[T] -> T`: "write `fun first[T]() -> T`". A bare type parameter
  marks a generic.
- A bracket-only method or member: reject with "a compile-time function is
  declared at module level; for a method write `fun cap[n: Int](?@)`".
- `inline`/`called` marks: "a compile-time function runs in the compiler; `inline` has no call to inline".
- `from ...` and `keeps ...`: reject. The result is a constant and views
  nothing; a `Static` is already static.
- No `->`: "a compile-time function gives a value: write its type, `-> T`".
- A bodyless Zig-backed `zfun` with brackets only: reject. There is no Zig to
  run at compile time.

The fix-it for a forgotten `()` moves into the evaluator. When the body uses
something that cannot run at compile time, say so: "`print` cannot run at
compile time, in compile-time function `cap`; if `cap` runs when the program
runs, write `fun cap[n: Int]() -> Int`". So the two-character difference
between `fun f[n: Int]() -> Int` and `fun f[n: Int] -> Int` is never silent
when the body does anything run-time-only. The difference itself follows
Rig's rule exactly: no parentheses, nothing at run time.

### Call-site diagnostics

| Misuse | Message |
|---|---|
| `cap(8)` | "`cap` runs at compile time: call it with brackets, `cap[8]`" |
| `cap[x]`, `x` a run-time value | "`cap[...]` runs at compile time, and `x` is known only when the program runs: pass a constant, or declare `fun cap(n: Int) -> Int` to run it then" |
| `cap[n]`, `n` a generic's compile-time parameter | rejected in version 1, by the rule SPEC §16 already gives `n + 1`: "`cap[n]` would run once per instance, which the compiler does not do: pass `cap[...]` of a constant where the instance is named" (see "Generic bodies" below) |
| `f = cap`, `apply(cap, 1)` | "`cap` runs at compile time and has no run-time value: call it, `cap[...]`" |
| `cap[8]()` | "`cap[8]` is a value computed at compile time (`Int`), not a function: drop the `()`" |
| `cap[8]` as a statement | "`cap[8]` computes a value that is not used" |
| `cap[T]`, a type argument | "`cap` takes compile-time values, not types" |
| arguments by name (`cap[n: 8]`) | version 1 takes them by position (`tkwarg` exists only for `inline:`) |
| overflow, index or division at evaluation | at the call site, with the chain: "`fib[100]` overflows `Int` at compile time, in `fib` (3:5)" |
| step limit hit | "`fib[60]` did not finish within 10,000,000 steps at compile time" |

Accepted argument forms: the ones SPEC §16 lists for compile-time values
(literal, enum value, module constant, a `=!` of one, folded arithmetic), plus
another compile-time call. Text arguments (`hash_of["if"]`) are `?String`
compile-time values, which §16 already allows.

### Generic bodies: the one design question with a cost behind it

Rig does not monomorphize. A generic's value parameter is a Zig `comptime`
parameter (`emitTypeTy`: `.ct_param → writeTypeParam`), so `[N]T` is emitted as
`[N]T`. For `[cap[N]]T` in a generic body there are two ways:

- (a) emit `cap` as a Zig function and let Zig's compile-time evaluation run
  `cap(N)` per instance;
- (b) have Rig evaluate it per instance.

Option (a) gives two evaluators with possibly different meanings. It also
brings Zig's eval-branch quota back, and Zig evaluates slowly: 1M loop passes
add about 1.8 s to a Debug build (measured below). And if Zig fails, the error
is Zig's (North Star 1). Version 1 should reject `cap[N]` on a compile-time
parameter, exactly as §16 rejects `N + 1`. The day per-instance evaluation
comes, it lifts both rules together, through one mechanism in Rig.

## Feature 2: plain `fun` values crossing tasks

- **Representation:** `emitTypeTy` `.function` writes `*const fn (P...) R`
  (src/emit.zig:8520). A callable view `?fun` is `rig.FnRef` (a context plus a
  function), and an owned closure is `rig.Closure` behind a handle. A plain
  `fun` value is one word of read-only code address.
- **Runtime copy:** `Task(T).spawn` → `sched.spawn` stores
  `args` in a heap record by plain assignment (`full.* = .{ ..., .args = args }`,
  src/sched.zig:2549). `spawnDetached` and actor messages copy the same way.
  A function pointer needs nothing: no count, no drop, no clone.
  `blockingStop`'s `ownArgs`/`writableArg` (src/sched.zig:1417) checks only for
  `[]const u8` and writable pointers, and `*const fn` is const, so nothing trips.
  A function named directly (`apply(inc, 1)&`) is a comptime `fn` field of the
  args tuple, which is also free. `inline fun` values are already rejected
  ("`inc` is `inline` ... can only be called").
- **Where the change goes:** `sema.blockerIn` (src/sema.zig:6740),
  `.function, .callable => if (local and how == .moves) null else here`, and the
  wording in `typecheck.blockerReason` (src/typecheck.zig:8035). Today
  `apply(inc, 1)&` already compiles, but as a **local** task. `rig check
  --tasks` says it is pinned by `inc`, "a function, whose captures its type does
  not show", and emit writes `rig.Task(i64).spawnLocal(apply, .{ inc, 1 })`.
  `par.map(?xs, |+g, x| g(x))` with a function value `g` is rejected. After the
  change, emit's source is unchanged, and it writes `.spawn(` because
  `isLocalTask` is false. That is a run-time win (no pinning), not a cost.
- **Soundness trap (must fix first):** `.function` is not only a pointer.
  - A stack closure binding `g: fun(Int) -> Int = |+n, x| x + n` has type
    `.function`. Sema marks it with `flags.closure`, and emit writes it as a
    struct of captures with `__rig_invoke` (src/emit.zig:8104).
  - A closure literal lent to a task call is typed `read_view(lambda type)`
    (`crossCheck`, src/typecheck.zig ~7994).
  - `|?g|` of a stack closure is `read_view(function)`.

  Probe `h.rig`, `par.map(?xs, |?g, x| g(+x))` with `g` a stack closure, is
  rejected today only because `.function` blocks. If `.function` is unblocked
  as it stands, a closure capturing `|!counts|` could be read from many cores:
  a data race in safe code (North Star 2). Stack closures cannot be moved,
  copied, or stored ("closure `g` cannot be moved, returned, stored, or
  copied"), so the only leaks are **views** of them. Two fixes:
  1. **Recommended:** let the type say it, per "one classifier per fact". Give
     closure literals and stack closure bindings a type of their own (or type
     every view of one as `.callable`, like `?g` already is in
     typecheck.zig:5784), so `.function` means a function pointer only. Then
     `.function` crosses for both `moves` and `shares`. `.callable` (a FnRef
     that may wrap a closure), owned closures (`.shared`), and closure types
     stay blocked; their captures are checked where the closure is in hand, as
     `par.map` does now.
  2. Smaller but weaker: let `.function` cross for `moves` only and keep it
     blocked under any view. This is sound under today's invariants, but still
     rejects `par.map` with `|+g|` (a copy read by many tasks, so it must share)
     and objects with `fun` fields lent to read. Those are probably the cases
     Trig wants.

  Cases for the change: `h.rig` stays rejected; a closure literal capturing
  `|!x|` lent to `f(...)&` stays rejected or local; `c.rig`
  (`apply(inc, 1)&`, `f = inc; apply(f, 2)&`) becomes non-local (`--tasks` is
  silent, emit writes `.spawn(`); `d.rig` (`par.map` with `|+g|`) is accepted;
  an object with a `fun` field given to a task and sent through a `Chan` is
  accepted. Run with `seeds: 20`, and on pup, since the task runs off-thread.
- One side note: a function value that reaches an `extern` variable has the
  same race exposure as calling that function directly in a task. This is
  nothing new.

## Cost

### Compiled programs

None, provided results are emitted as literals. A constant used in a type
(`[cap[4]]T`, `Ring[T, cap[4]]`) is a number in the Zig type, exactly as `[8]T`.
A table used at run time is `.rodata`, the same as a table written by hand. No
initialization code runs at startup. A table used only in types is not
emitted at all.

### Binaries

Binaries grow by the size of the tables a program actually indexes at run
time, and no more. Measured (Mac, ReleaseSafe, one tiny program indexing a
table, cold cache):

| Table | Zig source | Build time | Peak RSS | Binary |
|---|---|---|---|---|
| 4,096 × U8 (about the baseline) | 15 KB | 4.6 s | 332 MB | 511 KB |
| 65,536 × U8, aggregate literal | 229 KB | 4.4 s | 334 MB | 577 KB |
| 65,536 × I64, aggregate literal | 832 KB | 4.5 s | 355 MB | 1.0 MB |
| 1,048,576 × U8, aggregate literal | 3.6 MB | 8.0 s | 386 MB | 1.6 MB |
| 1,048,576 × U8, string literal `"\x..".*` | 4.1 MB | 6.9 s | 394 MB | 1.6 MB |
| 1,048,576 × I64, aggregate literal | 13 MB | 6.2 s | 901 MB | 8.9 MB |

Below about 64K elements the cost cannot be measured. At 1M it costs seconds
and, for 8-byte elements, close to a gigabyte of compiler memory. These are
single runs, so treat them as orders of magnitude.

### How emit should write constants

1. Each distinct compile-time value that run-time code reads is written
   **once**, as a module-level `const __rig_ct_N: [n]T = ...;`, and referred
   to by name. A table literal is never written at each use.
2. A scalar is written as a literal at its use. An `[n]U8` is written as a
   string literal (`"\x00\x01...".*`): smaller source and faster to analyze
   than an aggregate. Other arrays are aggregate literals.
3. Cap a single emitted constant at about 1M elements or 8 MB, with a
   diagnostic that suggests `@embedFile`-style data instead. This keeps Zig's
   memory bounded.
4. There is **no eval-branch-quota exposure**. The quota counts backward
   branches in Zig's compile-time *execution*, and a literal executes nothing.
   The trouble Rig hit with large enums came from comptime loops over variants
   (`nicheOf` and the like, src/runtime.zig:170). A constant table of a large
   enum type adds elements, not loops. Quota only comes back if ct functions are
   emitted for Zig to evaluate, which is the reason for rejecting `cap[N]` in
   generic bodies (above).

### The compiler

- **The evaluator** is a new pass over checked IR, run from typecheck when an
  array length, an instance argument, or a constant needs the value. A
  tree-walking interpreter does roughly 10–50M simple steps per second. Zig's
  own compile-time evaluation, for comparison, measured about 1M loop passes
  in 1.8 s.
- **Step limit:** 10M steps per top-level evaluation by default, with the
  diagnostic above. `rig check --time` should show it as its own pass, so a
  slow constant is visible.
- **Memoize by (function, argument values).** Compile-time functions are pure,
  so this is sound. It turns naive `fib[40]` (about 330M calls) into 41 calls,
  and repeated `cap[4]` across a program into one evaluation. Key the cache
  per program (`modules.zig` checks in dependency order), so another module's
  constants are evaluated once.
- **Memory:** cap the values an evaluation may build at about the emission cap,
  so a runaway `[n]Int` with `n = 10**9` fails fast instead of exhausting the
  machine.
- **Parser:** the grammar change adds 2 symbols and 16 states (1730 → 1746);
  parse time does not change measurably.
