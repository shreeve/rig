# Compile-time functions (`fun cap[n: Int] -> Int`): review and v1 design

Reviewer: compile-time evaluation / compiler design panel seat.
Tree read: `~/Data/Code/worktrees/rig/fun-and-comptime` at 4805cd800 (built; probes in
`scratchpad/fc-panel/probes-b/`).

## Verdict: AMEND

The proposal is sound in principle and fits Rig's rule exactly: brackets alone,
no parentheses, means nothing runs when the program does. The amendments below
narrow v1 so it lands in one PR without a new kind of type:

1. **v1 call sites take constant arguments only.** `cap[n]`, where `n` is a
   compile-time parameter of an enclosing generic function or type, is v2. It
   needs a new symbolic length type, and today's `[n + 1]T` rejection is lifted
   by the same v2 mechanism ("hidden compile-time arguments", §6).
2. **Inside a compile-time function's own body**, its parameters are values the
   evaluator knows, so `fib[n - 1]` is allowed there. This is the one place
   where today's "arithmetic on a compile-time parameter" rule does not apply.
3. **No zero-parameter form in v1.** `fun t[] -> ...` breaks the "empty brackets
   are rejected" rule (SYNTAX §11). Tables take their size as the parameter
   (`DIGITS = digit_table[256]`).
4. **The evaluator reads the checker's types.** It never infers a type, and it
   shares one arithmetic core with `ctFoldBy` (one classifier per fact).
5. **Compile-time functions are never emitted and never run when the program
   runs.** A call is a constant wherever it is written.
6. **`panic("...")` in a compile-time body is a Rig diagnostic at the call**, the
   `static_assert` of Rig.

## What exists today (grounding)

- **Grammar.** `fun` takes `[tparams] [params]`, both optional (rig.grammar:712).
  The IR distinguishes a missing parameter list (`_`) from an empty one (`()`).
  Today `fun cap[n: Int] -> Int` is rejected by the checker: "write `fun
  cap[n: Int]()`: a function's parameter list is always written". So the new
  form needs no grammar change in declarations.
- **Expressions.** `cap[3]` is `(index cap 3)`. Today it is rejected: "`cap[3]`
  is a function with compile-time arguments; call it with `cap[3]()`". A type
  argument `Ring[Int, cap[2]]` parses as `(generic_inst cap 2)`, rejected as "not
  known at compile time".
- **Array size (`dim` / `cunit`).** These do not accept `name[...]`:
  `[cap[3]]Int` is "unexpected `[`". A grammar change is needed there (§5).
- **The constant evaluator.** `sema.ctFoldBy` (sema.zig ≈9720) is "the one
  constant evaluator" for module and local constants, array lengths,
  compile-time arguments, and enum values. It covers integer expressions only
  (typed `TypedInt` over `Wide = i256`), reads names through a `names` object,
  and has no statements, environment, or calls.
- **Module constants** are ordered by dependency (`orderModuleConsts`, with
  self-dependency diagnostics) and folded into `const_ints` in
  `resolveDeclarations`. That runs before function bodies are type-checked.
- **Types.** An array length is a `ct_value` (a concrete integer) or a
  `ct_param` (one parameter symbol). There is no type for an expression over
  parameters, which is why `[n + 1]T` is rejected.
- **Instances.** Generic bodies are checked once. Per-instance requirements and
  frames are re-checked at every instance, transitively, with notes such as
  "`inner[-1]` is made by `outer[-1]`" (probe p9). Emit writes each generic
  body once with `comptime` parameters, and Zig instantiates it.
- **Emit already writes folded constants.** `x = LIMIT * 3` emits
  `@as(i64, 12)`, and a constant array emits `[_]i64{ 0, 1, 4, 9 }`. Emitted
  functions already set `@setEvalBranchQuota(maxInt(u32))`.

## 1. Semantics (v1)

### Declaration

```rig pending
fun cap[n: Int] -> Int
  n * 2 + 1
```

- A `fun` with a compile-time parameter list and **no run-time parameter list**
  is a compile-time function. It is decided once, in sema, from the IR (`params
  == _`). That fact is the single classifier, recorded as
  `Symbol.flags.ct_fun`.
- **v1 is module-level `fun` and `pub fun` only.** Not methods, `sub`, or
  closures, and no `inline` or `called` marker.
- **Parameters** are value parameters only: an integer type, `Bool`, or a plain
  enum.
  - No type parameters: `fun size[T] -> Int` is v2.
  - No `?String`/`Static`, `Float`, or optionals in v1.
  - No arrays as parameters.
- **The result** is one of these, or a fixed array (nested) of them: integer,
  `Bool`, plain enum. No `T?`, `T!`, several results, or objects in v1.
- Rejections:
  - `sub show[n: Int]` (no parentheses) stays rejected. The message names both
    readings: "a compile-time function returns a value: write `fun show[n:
    Int] -> T`; a `sub` writes its parameter list: `sub show[n: Int]()`".
  - `fun f -> Int` (neither list) keeps today's message.

### Call

- `cap[8]`: brackets only. The value is a constant of the declared result type.
  It stands wherever a constant can:
  - an expression in run-time code: `x = cap[8]`, `print(cap[8])`;
  - a module constant: `X = fib[20]` and `TABLE = squares[16]`;
  - an array length: `[cap[8]]Int`, `[cap[8] * 2]Int`;
  - a compile-time argument: `show[cap[2]]()`;
  - a generic type's value argument: `Ring[Int, cap[4]]`;
  - an enum value, a range-pattern bound, and the operand of constant
    arithmetic, because these all go through `ctFoldBy` (below).
- **Arguments at a call outside a compile-time body** follow today's
  compile-time-argument rule exactly: a literal, an enum value, a module
  constant, a `=!` binding of one, constant arithmetic, or another
  compile-time call.
  - A run-time value is rejected with the existing message ("compile-time
    argument 1 of `cap` must be known at compile time ...").
  - An enclosing generic's parameter `n` is rejected in v1 with its own message:
    "compile-time argument 1 of `cap` is the compile-time parameter `n`; a
    compile-time function is called with values known where the call is
    written".
- **Rejected spellings:**
  - `cap[3]()` gets "`cap` is a compile-time function: its value is `cap[3]`,
    with no parentheses".
  - A statement `cap[3]` falls under the unused-value rule.
  - `cap` as a value is rejected, as for any function with compile-time
    parameters.
- **Inside a compile-time body**, a compile-time call is an ordinary call that
  the evaluator runs, so its arguments may be any expression of the right type:
  locals, loop variables, `n - 1`. One exception applies when the callee's
  result type names a parameter (`-> [n]Int`). An argument for that parameter
  follows today's rule (a constant, or the caller's own parameter passed
  unchanged), because the body is type-checked once and `[n - 1]Int` is not a
  type v1 can spell. The existing `ctIntArg` already gives this.

### Body: a positive list, checked once at the declaration

The body is first checked by the ordinary checker, as a generic body whose value
parameters are compile-time values. It then passes a purity walk over the
checked IR. Every node must be on this list, and every node's type must be
plain (integer, `Bool`, plain enum, or fixed array of these):

- local bindings (`x = e`, `x: T = e`, `x =! e`), assignment and compound
  assignment to a local or to an element of a local array (`a[i] = v`,
  `a[i] += 1`);
- integer literals, `true`/`false`, `.variant`, `Int.max`/`U8.min` (through
  aliases too), and module integer constants (from `const_ints`; another
  module's too);
- every integer operator `ctFoldBy` knows (`+ - * / %`, wrapping, saturating,
  shifts, bitwise), unary `-`, comparisons, `and`/`or`/`not`, and conversions
  between integer types (`U8(x)`, checked);
- `if`/`else` (statement and value), `a if c else b`, and `match` on integers,
  `Bool`, and plain enums (literal, range, alternative, and `_` patterns, and
  guards);
- `while`, `for i in a..b`, `for x in arr` and its indexed form over a local
  array, `break`, `continue`, labels, and `return`;
- array literals `[a, b]`, fills `[k of x]` (`k` follows today's rule: a
  constant or the parameter), indexing `a[i]`, and `.len`;
- calls of compile-time functions: this module's, or another module's `pub`
  ones (`lib.cap[n]`). Recursion and mutual recursion are allowed;
- `panic(msg, ...)`, which becomes a diagnostic at the call (§1, Errors).

The walk rejects everything else at the offending line, with one message family:
"a compile-time function cannot `{form}`: {reason}". Examples:

- `print(x)` runs when the program does;
- `helper(x)` is a function that runs when the program does: a compile-time
  function calls only compile-time functions, with brackets;
- `xs` is a `List[Int]`, and a compile-time function holds only integers,
  `Bool`, plain enums, and arrays of them;
- `defer`, `raw`, closures, sigils (`<x`, `?x`, `!x`), method calls other than
  `.len`, optionals, `?`/`!`/`catch`, tasks, and floats.

This is the C++ `constexpr` choice of a positive list, not Zig's "anything that
happens to fold". It keeps "brackets are compile time" true *inside* the body
too: no parenthesized call ever runs there.

### Evaluation

The evaluator is `sema.CtEval`, a tree-walking interpreter over the **checked**
IR of the body.

- **Values:** `CtVal = union { int: {v: Wide, ty: TypeId}, bool, variant: {ty,
  index}, array: {ty, elems: []CtVal} }`.
- **Environment:** a frame per call. Locals map to `CtVal`. Arrays are values,
  copied on binding and passing; a copy of k elements counts k steps.
- **Types come from the checker.** Each node's type is read through
  `ctx.typeOf(node)`, which settles how literals are typed. `x: U8 = 200; x + 100`
  overflows `U8` because the checker typed the `+` as `U8`, not because the
  evaluator guessed.
- **One arithmetic core.** Factor the binary-operator core of `ctFoldBy` (the
  big `switch (h)` that computes `+`, `-`, wrapping, saturating, and shift
  results) into `sema.ctArith(op, a, b, int) -> union { value, overflow,
  div_zero, shift_range }`. Both `ctFoldBy` and `CtEval` call it, so constant
  folding and compile-time functions cannot disagree about what `a * b` means.
- **`ctFoldBy` gains one case.** A compile-time call node (the fact in §5) asks
  `names.ctCall(e)`, which evaluates on demand and returns a `TypedInt`. Every
  folding site then gets compile-time calls for free: array lengths,
  compile-time arguments, module constants, enum values, generic value
  arguments.
- **Limits.** They are fixed, so `rig check` gives the same verdict on every
  machine. Steps are counted, never timed.
  - **steps:** 10,000,000 per top-level evaluation, counting each expression
    node, each loop iteration, and each element copied. For scale: a 65,536-entry
    table with a 10-operation body is about 0.7M. Clang's default is about 1M
    and GCC's is far higher; Zig's default of 1000 backward branches is
    unusable for tables.
  - **depth:** 256 nested compile-time calls. The evaluator recurses on the
    compiler's own stack, which is bounded by this guard.
  - **size:** a result obeys the 8 MiB value rule (SPEC Arrays), checked at
    the call as for an instance. Live evaluation memory is capped at 64 MiB.
- **Caching:** a memo of results and of failures, keyed by (declaring module,
  function symbol, argument values). It is kept in that module's context
  (arena), so importers reuse it.
- **Instance checks.** A call with concrete arguments is an instance.
  `checkRequirements` runs at the call (for example, a `[n of 0]` in the body
  with `n = -1` gives the existing "uses `n` as an array length" message).
  Frame-size rules do not apply, since nothing runs.

### Errors: Rig diagnostics at the call

Each error is reported at the call that asked, which is the line in the type,
constant, or expression. It has a note at the body line that failed, and a chain
of "`fib[3]` is called by `fib[4]`" notes, capped at a few frames as instance
notes are:

- `compile-time call \`fib[100]\` overflows \`Int\` (-9223372036854775808..9223372036854775807)`
  with the note "in `fib[n - 1] + fib[n - 2]`";
- `compile-time call \`f[0]\` divides by zero`;
- `compile-time call \`t[3]\` indexes 5 in an array of length 3`;
- `compile-time call \`f[300]\` converts 300 to \`U8\`, which holds 0..255`;
- `compile-time call \`f[40]\` takes more than 10000000 steps`;
- `compile-time call \`f[1000]\` nests more than 256 compile-time calls`;
- `compile-time call \`cap[0]\` panics: cap needs a positive n` (the panic's
  text, formatted as `print` formats it);
- shift-amount and value-size errors follow the same pattern.

A failed call makes the value it was used in poison, so no cascade follows: an
array type from it is `invalid`, as an out-of-range length is today.

## 2. Where calls are evaluated

- **At the use site, once per distinct (function, arguments)**, through the
  memo. A call inside a generic body with constant arguments is evaluated once,
  when the body is checked. It is the same value for every instance.
- **Order.** Module constants and types are resolved in `resolveDeclarations`,
  before function bodies are checked. So a compile-time function is checked on
  demand. When a folding site needs `cap[8]`, the evaluator:
  1. resolves `cap`'s signature;
  2. checks its body (sema, typecheck, purity walk);
  3. evaluates it.

  A `new/open/done` state per compile-time function, the same state machine
  `orderModuleConsts` uses, detects cycles: `N = f[1]` with `fun f[k: Int] ->
  [N]Int` gives "constant `N` depends on itself (`N` → `f` → `N`)". A body
  *calling* another compile-time function only needs that function checked
  before *evaluation*, not before its own check, so mutual recursion works.
  - **Main implementation risk.** The body check runs before the module's other
    declarations are resolved. v1's positive list keeps the body's dependencies
    to what can be resolved first: plain enums, integer type aliases, module
    integer constants, and other compile-time functions. Objects never appear.
  - **Fallback if on-demand checking proves too tangled.** Check every
    compile-time function in one early pass, after plain enums and aliases are
    resolved and before constants are folded. Allow constants they read only
    when they precede them in the combined dependency order.
- **Another module's** `lib.cap[8]` is evaluated in the declaring module's
  context (it was fully checked first, `foreign_semas`). Result types are
  translated as an imported signature's types are, for example a plain enum
  becomes its `imported_nominal`.
- **Generic body with `cap[n]`, `n` a parameter: rejected in v1** (§1).
  Per-instance evaluation is v2 (§6).

## 3. How the result reaches Zig

- The value is a recorded fact (`facts.ctValueOf(node)`). Emit decides nothing.
- **Scalars** are written as today's folded constants: `@as(i64, 17)`, `true`,
  `Mode.loose`.
- **Arrays** are written once per module, per distinct result, as a hidden
  constant (`const __rig_ct_3: [16]i64 = [_]i64{ 0, 1, 4, ... };`), and uses
  reference it. A 64K table used at five sites is then not five 300 KB literals.
  Which hidden constant a call reads is a storage-style fact, decided once.
- **Module constants:** `TABLE = squares[16]` emits `pub const TABLE: [16]i64 =
  [_]i64{...};`, exactly as an array literal constant does today. An integer
  result goes into `const_ints`, so it folds everywhere afterwards.
- **Types and generic arguments** were already `ct_value`, so they emit as
  numbers.
- **The function itself is not emitted.** Inlining, symbols, frames, proofs, the
  ownership checker's per-function pass, and emit all skip it through one
  predicate, `sema.isCtFunction(decl)`. The oracle must either skip it the same
  way or learn it (`test/oracle/coverage` must not drop).
- **Run time: no.** A compile-time function cannot be called at run time in v1.
  It does not need to be, since every call is a constant. A call with a
  run-time argument is rejected. Alternatives for later, with reasons against:
  - Writing `cap(k)` with parentheses to run it would break the bracket rule.
  - Inferring "pure plain" ordinary functions callable from compile-time code
    (Zig, or C++ `constexpr` without the keyword) blurs which code the checker
    runs. Revisit only when a real program needs one function both ways.
- **Ownership.** A compile-time call is a *made value*, as a literal of its
  value is. It is added once, to the positive lists that classify place, made
  value, lend, and view. So `sum(?squares[4])` lends a temporary, exactly as
  `sum(?[0, 1, 4, 9])` does.

## 4. Interplay

- **Module constants:** `X = fib[20]`, `Y = X + 1`, `T = squares[LIMIT]` all
  work. The rule "only a constant scalar is folded" is unchanged: `T[3]` in
  run-time code is read when the program runs. Inside a compile-time body,
  reading a module **array** constant is deferred. It is cheap (the evaluator
  covers every form a constant's value may take) but not needed for v1.
- **Generic types:** `Ring[Int, cap[4]]` in a type (the `generic_inst` node,
  read as a value where the parameter is one) and in an expression
  (`Ring[Int, cap[4]](items: ...)`) both reach `ctFoldBy` and give `ct_value
  9`. `Ring[Int, cap[4]]` and `Ring[Int, 9]` are one type, as `Ring[Int, 2 + 2]`
  and `Ring[Int, 4]` are today.
- **`[n + 1]T`:** v1 does **not** lift this. Lifting it and allowing `cap[n]`
  over a parameter are the same problem: a length that is a computation over
  parameters. They should be solved once, in v2.

## 5. v1 scope, and what the PR touches

**In v1:**

- the declaration form;
- bracket-only calls with constant arguments everywhere `ctFoldBy` folds, and
  as expressions;
- the positive-list body (ints, Bool, plain enums, arrays; locals, loops,
  if/match, compile-time calls, recursion, `panic`);
- `CtEval` with the shared arithmetic core, fixed limits, and the memo;
- cross-module `pub` compile-time functions;
- emission as literals and hidden array constants.

**Grammar:** `dim` and `cunit` gain `name:tname "[" args:types ![","] "]" →
(generic_inst)`, the same node a type argument already makes. This allows
`[cap[8]]T`, `[lib.cap[8]]T`, and `[cap[8] * 2]T`. It needs a Nexus run to
confirm no LALR(1) conflict. The reduce/reduce choice between `tatom` and `cunit`
in `targ` is decided by the next token (`*` versus `,`/`]`). Tell the Nexus
session, which keeps a copy of `rig.grammar`.

**Passes:**

- sema: the `ct_fun` flag, and the `ct_call` fact on `(index f ...)` and
  `(generic_inst f ...)` nodes;
- resolve: `ctIntOf` and the cycle order;
- typecheck: call checking, the purity walk, the new messages;
- sema: `CtEval` and `ctArith`;
- facts: `ctValueOf`;
- storage and ownership: the made-value classification;
- emit: literals and hidden constants;
- skips in inlining, frames, proofs, symbols, and the oracle;
- LSP hover shows the value (optional).

**Docs:**

- SPEC §16, a new subsection "Compile-time functions" with a runnable example
  and a `rig reject`;
- SPEC Arrays and Constants: lengths and constants may be compile-time calls;
- SYNTAX §8 Functions: "always writes its parameter list" gains the exception;
- SYNTAX §8 Generics table: a row;
- SYNTAX §11: brackets-only calls;
- DESIGN "Brackets for compile time": a paragraph;
- ROADMAP, CHANGELOG, HANDOFF;
- a `rig pending` block for `[cap[n]]T` in a generic body and for `[n + 1]T`.

**Deferred, in order of likely need:**

1. **v2:** calls over a parameter and `[n + 1]T` in generic bodies (§6).
2. Text parameters (`hash[s: Static]`), so Trig can hash names at compile
   time. The evaluator needs only byte indexing, `.len`, and `for b in s`. The
   parameter is the string literal's bytes, and the memo key is the bytes.
3. Plain objects as results and parameters (constructor, field read), emitted
   as `.{ .a = 1 }`. This pairs with the ROADMAP "Constant tables" item for
   Trig's catalog.
4. Reading module array constants in a body; optionals and `.get`; several
   results.
5. Zero-parameter tables. Prefer a module constant whose initializer is a block
   (a "constant computed by code") over `fun t[]`, if a real program needs one.
6. Floats: deterministic IEEE is easy to evaluate; printing a literal that
   reads back exactly is the work.
7. Compile-time methods (`fun Ring.slots[k: Int] -> Int`) and type parameters.

## 6. v2 sketch: calls over parameters, and `[n + 1]T`

A new interned type `ct_expr { fun_or_op, args: []TypeId }`, with arguments
that are `ct_param` or `ct_value`. `[cap[n]]Int` written twice is one type;
`[cap[n]]Int` and `[n * 2]Int` are distinct in the generic body, which is sound
and simply stricter. `substituteType` reduces it at each instance with all
`ct_value` arguments by evaluating. A per-instance record, modeled on
`generic_frames` (substitute, skip while a type variable remains, check), reports
evaluation errors at the instance with the "is made by" chain that exists today.

**Emission. Recommendation: hidden compile-time arguments.** For each `ct_expr`
a generic function or type needs, it gets an extra `comptime` parameter
(`fn make(comptime n: i64, comptime __h0: i64) [__h0]i64`). Every call site
passes the value Rig computed as a literal. A generic caller passes its own
hidden argument, so needs propagate up the instance chain the way requirements
already do. Zig never evaluates Rig code, there is one evaluator, and it works
across modules, because each instance is emitted where it is made.

**Rejected alternatives:**

- Emitting `cap` as a Zig function and letting Zig evaluate `cap(n)` gives two
  evaluators that must agree. It also costs Zig comptime's speed and memory,
  and a step budget that Rig's `maxInt(u32)` quota turns into a hang rather
  than an error.
- A per-function `switch` over the instances Rig saw needs whole-program
  knowledge at emit, and breaks one-file-per-module emission.

## The Zig-comptime alternative, briefly

Emitting compile-time functions as Zig `comptime` code and letting Zig evaluate
them fails the North Star:

- Overflow, out-of-bounds, and quota exhaustion surface as Zig errors in
  generated files (North Star 1).
- `rig check`, which never runs Zig, could not know the value. Yet the checker
  needs the number for:
  - type identity (`[cap[4]]Int` = `[9]Int`);
  - the 8 MiB value and 13 MiB frame rules;
  - constant-index rejection and proofs (check elimination needs lengths);
  - compile-time-argument inference and fit checks;
  - requirements such as `array_len`.
- Zig's comptime is also slow. Rig already sets the branch quota to
  `maxInt(u32)`, so a runaway loop hangs the build instead of failing, and the
  verdict would depend on the Zig version.

The checker therefore needs an evaluator in every design, and once it has one,
letting Zig evaluate again only adds a second semantics to keep in sync. **The
checker evaluator is preferred.**

## Tests the PR must include

New file `test/rig/ctfun.rig.test` (plus SPEC/SYNTAX doc examples). `test` cases
run clean under the sanitizer.

**Accept (`test`):**

1. `fun cap[n: Int] -> Int` / `print(cap[3])` → `7`; `x = cap[3]` in run-time code.
2. Array length: `a: [cap[2]]Int = [5 of 0]`, `print(a.len)`; `[cap[2] * 2]U8`; `[lib.cap[2]]Int` (whole: true, two modules).
3. Module constants: `X = fib[20]` → `6765`; `Y = X + 1` folds; `T = squares[5]` → `[0, 1, 4, 9, 16]`; `T[3]` read at run time.
4. Generic type argument: `r: Ring[Int, cap[1]] = Ring(items: [3 of 0])`; expression form `Ring[Int, cap[1]](items: ...)`; `Ring[Int, cap[1]]` assignable to `Ring[Int, 3]`.
5. Compile-time argument: `show[cap[2]]()`.
6. Recursion: `fib[n - 1] + fib[n - 2]` inside the body (the rule that differs from run-time generics); mutual recursion `even[n]`/`odd[n]`.
7. Loops and arrays: a table `fun squares[n: Int] -> [n]Int` built with `t = [n of 0]` and `for i in 0..n` / `t[i] = i * i`; `while` with `break`/`continue`; `for x in t` summing; nested `[2][3]Int` result.
8. Typed arithmetic: `fun f[k: U8] -> U8` with wrapping `+%` → wraps; saturating `+|`; `U8(x)` conversion in range.
9. `match` on a plain enum parameter: `fun width[m: Mode] -> Int`; a `Bool` parameter; a plain-enum result.
10. Calling another compile-time function from the body; reading a module integer constant and `Int.max` in the body.
11. The same call at several sites evaluates once (memo); observable only through emit, see the `code` cases.
12. Enum value from a call (`enum E` with `a = cap[1]`), if the on-demand order supports it in v1; otherwise a `known: true` case.
13. Lending a compile-time array: `sum(?squares[4])` → `14` (a made value, temporary dropped).

**Reject (`fail`), each at the line that asked, with the note into the body:**

1. Overflow: `X = fib[100]` → `compile-time call \`fib[100]\` overflows \`Int\``.
2. Divide by zero: `f[0]` with `100 / n` → `divides by zero`.
3. Index: `t[3]` reading index 5 → `indexes 5 in an array of length 3`.
4. Conversion: `U8(n)` with `n = 300`.
5. Steps: an endless `while true` → `takes more than 10000000 steps`.
6. Depth: unbounded recursion `f[n + 1]` → `nests more than 256 compile-time calls`.
7. Panic: `if n <= 0 \n panic("cap needs a positive n")` with `cap[0]` → `panics: cap needs a positive n`.
8. Instance requirement: a fill `[n of 0]` with `n = -1` → the existing array-length message at the call.
9. Value size: `fun big[n: Int] -> [n]Int` with `big[2000000]` → the existing 8 MiB message.
10. Purity, one case each:
    - `print`;
    - a run-time function call (`helper(x)`);
    - `List[Int]()`;
    - a `?String` local;
    - a `Float`;
    - `defer`;
    - a closure;
    - a method call (`.get`);
    - `raw`;
    - a sigil;
    - an optional result type.
11. Declaration shape:
    - `sub show[n: Int]` without parentheses → the two-reading message;
    - `fun t[] -> Int` → empty brackets;
    - a type parameter `fun s[T] -> Int`;
    - a `?String` parameter;
    - `inline fun c[n: Int] -> Int`;
    - a method form.
12. Call shape:
    - `cap[3]()` → "its value is `cap[3]`, with no parentheses";
    - `cap[k]` with a run-time `k` → the existing "must be known at compile time";
    - `cap` as a value;
    - wrong arity;
    - an argument that does not fit (`cap[300]` for `n: U8`).
13. Generic parameter argument (v1 limit): `fun make[n: Int]() -> [cap[n]]Int` and `x = cap[n]` in a generic body → the v1 message. Doc example kept as `rig pending`.
14. Cycle: `N = f[1]` / `fun f[k: Int] -> [N]Int` → `depends on itself (\`N\` → \`f\` → \`N\`)`.
15. A result-typed argument inside a body: `build[n - 1]` where `build` returns `[n]Int` → the existing arithmetic-on-parameter message.
16. Unchanged: `[n + 1]T` still rejected, with today's message.
17. `rig check` exits 1 on each of these with no Zig run (the North Star "never a Zig error").

**Emit (`code`):**

1. `x = cap[3]` emits `@as(i64, 7)` and no `fn cap`.
2. `T = squares[4]` emits `pub const T: [4]i64 = [_]i64{ 0, 1, 4, 9 };`.
3. Two uses of `squares[64]` in run-time code emit one hidden `__rig_ct_` constant, referenced twice.
4. `[cap[2]]Int` emits `[5]i64`.
5. `Ring[Int, cap[1]]` emits `Ring(i64, 3)`.
6. A `Mode` result emits `Mode.loose`.

**CLI and suites:**

- `check --facts=sema` lists the compile-time value on the call node;
- the oracle: coverage does not drop, and rejections stay unchanged;
- a torture case for deep or long evaluation finishing under the limits in
  bounded time;
- `swarm test/rig.rip all` green (on burst or pup, per the owner's rules, not a
  Mac full run).
