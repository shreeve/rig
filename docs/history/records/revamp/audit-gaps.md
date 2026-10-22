# Completeness audit: small gaps (revamp @ 206ea77)

Auditor: completeness. Method: every candidate was compiled with the current
`bin/rig` (programs and results under
`scratchpad/audit-gaps/`, `RIG_OUT_DIR=scratchpad/audit-gaps/out`). For four
candidates I also built a patched **copy** of the sources
(`scratchpad/audit-gaps/rigcopy/`, tracked files untouched) to show how
much of the pipeline already works once the sema rejection goes away. No
tracked file was modified; `./test/run` was not run.

## Summary

- Three candidates are almost free: the backend already lowers nested
  closure captures, field defaults, and `Type.method` references. In the
  patched copy each one runs leak-free once its rejection is removed.
  Field defaults also need one literal check that is missing.
- Module-level constants (`name =! literal-expr`) work end to end in the
  patched copy through the existing `=!` machinery. What's left is
  guard-rails: Copy values only, constant initializers only, no mutable
  globals, name collision in the emitter, and `pub` in the grammar.
- Slicing, `e?`, and break-with-value are real but modest features
  (120–300 LOC each). Most of the ownership model is already in place:
  `[]T` is already a loan carrier, `LoopCtx` joins breaks, and
  `walkPropagate` models early exits.
- Three reserved forms are dead grammar with dead code in three passes.
  They should be deleted: `for *x in`, which `for x in !xs` supersedes;
  `@x` pin, which is not a North-Star sigil; and `zig "..."`, which
  contradicts the raw/extern boundary.
  - Keep `try` blocks and the `pre` expression reserved, since the roadmap
    names both. Deleting the `pre` block statement is optional.
- **Two accept-means-correct bugs found** (not in the candidate list; must
  fix): `g = twice` (unannotated function-valued binding) passes
  `rig check` and emits Zig that does not compile. `:m match ...`/`:m raw`
  with `break :m` passes `rig check` and crashes the emitter with
  `internal error: cannot emit a label on this statement`.

## Ranked table (value-to-cost)

| # | Candidate | Recommendation | Est. LOC (src + tests) | Risk |
|---|---|---|---|---|
| 0a | BUG: unannotated function-valued binding `g = twice` miscompiles | fix now | ~5 + 1 test | low |
| 0b | BUG: label on a non-loop statement + `break :label` crashes emit | fix now (lower as `label: { }`) | ~8 + 2 tests | low |
| 1 | Nested closure capture | implement now (delete the check) | ~-10 + ~6 tests | low |
| 2 | Field default values (literal defaults) | implement now | ~40 + ~5 tests | low |
| 3 | Delete `for *x in`, `@x` pin, `zig "..."` | delete now | ~-80 net; 3 reject tests removed, 3 new parse-error tests | low |
| 4 | Type-qualified method reference `Type.method` as a function value | implement now (after 0a); keep bound `p.m` rejected | ~15 + ~4 tests | low |
| 5 | Module-level constants (`=!`, Copy, constant initializer, `pub`) | implement now | ~130 + ~10 tests | low-med |
| 6 | Slicing: `s[a..b]` on String, `?xs[a..b]` on arrays / Copy Vecs | implement now | ~130 + ~10 tests | med |
| 7 | Optional propagation `e?` | implement now (second wave) | ~150 + ~10 tests | low-med |
| 8 | `break` with a value / `while`/`for` as expressions (with `else`) | implement (second wave) | ~250 + ~12 tests | med |
| 9 | Calling a function-typed field `h.f(x)` | implement now (small) | ~20 + 3 tests | low |
| 10 | `pre` block statement | delete (keep `pre` expr reserved) | ~-10 | low |
| 11 | Value-yielding `try` block | defer (keep reserved; roadmap) | ~200 | med |
| 12 | `pre` expressions (compile-time evaluation) | defer (keep reserved; roadmap) | large | high |
| 13 | Bound method reference `p.get` | keep rejected (would hide a receiver capture) | — | — |
| 14 | `drop` on enums / generic types; generic types across modules | defer | 150–300 each | med |
| 15 | `use std` | keep reserved | — | — |
| 16 | Lexer: `[]*B` / `]`+sigil in type position | note / small fix | ~15 | low |

---

## 0a. BUG — a function name bound without an annotation

```rig
fun twice(n: Int) -> Int
  n * 2
sub main()
  g = twice
  print(g(2))
```

`rig check` exits 0, but `rig run` fails inside Zig:
`error: variable of type 'fn (i64) i64' must be const or comptime`, on the
emitted `var g = twice; _ = &g;`. It also fails when the binding is
reassigned (`g = thrice`). Annotated bindings (`f: fun(Int, Int) Int = g`),
arrays of functions, and fields all work.

- Cause: `emitBind` (src/emit.zig:935–1018) annotates only plain and enum
  types (src/emit.zig:988–994, `isPlainTy`, src/emit.zig:3219), so the Zig
  binding gets the function *body* type. The binding is also `var` because
  `isZigComptime(expr)` is true for a function name (src/emit.zig:960–961).
- Fix: also annotate when `ty` is `.function` (`emitTypeTy` already writes
  `*const fn (...)`, src/emit.zig:3096–3104). ~5 LOC.
- Tests: `test/behavior/emit/fn_value_unannotated.rig` covering
  `g = twice; print(g(2))`, and a reassigned variant.

## 0b. BUG — a label on a non-loop statement

```rig
sub main()
  x = 3
  :m match x
    3
      print("three")
      break :m
    else
      print("other")
```

`rig check` exits 0. `rig run` fails with
`3:3: internal error: cannot emit a label on this statement (ctx should reject it)`
(src/emit.zig:1276). `:m raw` with `break :m if x > 1` fails the same way.
Ownership already models labeled non-loop statements (`LoopCtx.is_loop = false`,
src/ownership.zig:2490–2500). `emitLabeled` handles only while, for, and
block (src/emit.zig:1265–1277), and the grammar never produces a labeled
`block`.

- Fix (preferred): for any other statement, emit
  `label: { <stmt> }`. Zig's `break :label;` out of a labeled block has
  the same meaning. ~8 LOC. Add one sentence to SPEC §7 "Labels, break,
  and continue" (SPEC.md:990): `break :name` may also leave a labeled
  `match` or `raw` statement.
- Alternative: reject labels on anything but `while`/`for` in
  `checkStmt` (src/typecheck.zig:288).
- Tests: behavior `labeled_match_break.rig` and `labeled_raw_break.rig`.
- Related: `:done if x > 1` cannot be written at all. The rewriter turns
  `if` after the label name into `POST_IF` ("a postfix `if` guard must
  end a statement"). That is acceptable as a parse error, but only if
  labels are documented as loop/match/raw-only.

## 1. Nested closure capture — implement now (delete the check)

**Today.** Any capture list on a closure whose body root is a lambda is
rejected, even a capture of a local declared inside the outer closure:

```
nested_local.rig:4:11: error: nested closure capture of `b` is not supported; lift the capture to the outer scope
    g = |+b, c: Int| b * c
```

The check is src/typecheck.zig:3457–3464. For a closure-local, the hint
("lift the capture to the outer scope") is impossible to follow.
SPEC.md:1895–1896 documents the restriction. The test is
test/reject/ownership/nested_closure_capture.rig.

**Evidence the backend is ready.** The emitter already threads nesting:
`closure_depth` and `envName()` give `__rig_self1`, … (src/emit.zig:2800–2804).
`captureInfo` resolves each capture to the outer local through
`Symbol.origin` (src/emit.zig:2707–2717), and the outer local may itself
be `env.cap_x` (`bindCaptures`, src/emit.zig:2807–2811). I removed the
check in the scratch copy. With that change, all of these print correct
results and pass Debug leak checking:

- stack in stack, re-capturing the outer capture (`|+n|` in `|+n|`), and
  the exact program from the reject test using `*Cell(Int)` (prints `2 4 4`);
- capture of a closure-body local, and capture of a closure parameter;
- three levels deep (`|+n, +b|` inside `|+n|` inside `|+n|`);
- owned in owned, with a `*B` clone-captured at both levels (drop runs once);
- `|~b|` weak capture of an outer capture, then `upgrade`;
- an owned inner closure moved into a `Vec(*sub())` inside the outer body;
- per-iteration nested closures over a `*B` in a loop (drops 0,1,2 in order).

The existing ownership rule still rejects what must be rejected:
`|<b|` of an outer capture gives "cannot move-capture captured resource
`b`; closure captures are owned by the closure environment, which may be
invoked again" (the capture_resource path).

**Change.** Delete src/typecheck.zig:3457–3464. Rewrite
SPEC.md:1895–1896 to say a nested closure captures from the scope where it
is created, which can be the outer closure's captures, parameters, or
locals. Turn test/reject/ownership/nested_closure_capture.rig into a
behavior test.

**Tests.** Behavior tests for each bullet above. Must-reject tests: moving
an outer capture into an inner closure, and an inner closure using an
outer-closure local without capturing it ("closure body uses `b` without
capturing it" already fires).

**Risk.** Low. Ownership's `lookup` crossing logic (src/ownership.zig:623–631)
already handles closure boundaries per level.

## 2. Field default values — implement now

**Today.**
`field default values are not supported yet; pass `x` in every constructor`
(src/resolve.zig:790–792).

**Surface.** `name: T = literal` in a `struct` or generic `type` body.
The grammar already parses it (`field ... "=" value:expr → (default)`,
rig.grammar:448), and the node already exists (`default name type value`,
rig.grammar:284). Defaults are restricted to the same literal forms as
parameter defaults (`isDefaultLiteral`, src/typecheck.zig:3785): number,
string, `true`/`false`, `none`, `.variant`. That keeps defaults Copy and
allocation-free, so no hidden allocation or refcount traffic. `none` is
allowed for an optional owning field (`next: (*Node)? = none`), because
`none` owns nothing.

**Half-built already.** `Field.has_default` exists (src/sema.zig:403–404).
`checkFieldArgs` already skips defaulted fields when reporting missing
ones (src/typecheck.zig:2470). The only gaps are that resolve never sets
the flag and that `emitFields` silently skips `.default` members
(src/emit.zig:406–414, `if (!m.isKind(.@":")) continue;`). Silently
dropping the field is why the reject test's comment says "the backend
would drop the default".

**Changes.**
- resolve: at src/resolve.zig:790–799, drop the error and append with
  `.has_default = h == .default`.
- typecheck: in `checkNominal` (src/typecheck.zig:156–187), for each
  `.default` member, apply the `checkDefault` logic
  (src/typecheck.zig:215–224): require the literal form and run
  `checkExpr(value, field_ty)`. That also brings in `checkLiteralFits`
  (`u: U8 = 300`).
- emit: `emitFields` writes `name: T = <value>` for `.default` members.
  Zig struct field defaults then fill omitted fields, and
  `emitFieldInit` does not change.
- effects/ownership: none. Values are literals.
- Enum payload fields: the diagnostic for `circle(r: Int = 1)` is
  currently misleading ("variant payload fields need types (`name: T`)").
  Reword it to "variant payload fields cannot have defaults".

**Prototype.** Scratch copy, resolve plus emit only. `P(y: 2)` prints
`P(x: 1, y: 2, name: "anon", m: .b, f: 2.5, h: none, u: 7)`. This covers
generic `Box(T)` with `n: Int = 5`, and an imported `pub struct` with a
default used from another module. Without the typecheck part,
`x: Int = "s"` reached Zig (`expected type 'i64', found '*const [1:0]u8'`),
so the literal check is mandatory.

**Tests.**
- Behavior: every literal kind; override versus default; generic type;
  cross-module; an optional-handle field defaulting to `none` with a drop
  body (leak-free).
- Reject: a non-literal default (`b: *B = *B(n: 1)`, and a call); a
  mismatched type; a literal that doesn't fit (`U8 = 300`); a default on a
  variant payload field.

**Docs.** SPEC.md:405–408 ("Field default values are not supported yet"),
SPEC §19 row (SPEC.md:2409), README.md:226, ROADMAP.md:13.

## 3. Delete `for *x in`, `@x` pin, and `zig "..."` — delete now

All three parse, go through the IR, and are rejected in typecheck. Each
one also leaves dead code behind in later passes. None of them is in the
AGENTS.md sigil table, and none has a roadmap item.

### `for *x in xs` (mode `ptr`)
- Today: `by-reference for-loop binding `for *x in ...` is reserved; write
  `for x in ?xs` ...` (src/typecheck.zig:717–720). The hint doesn't
  mention `for x in !xs`, which is the feature this syntax would provide:
  write iteration already exists (SPEC.md:945–950). `*` means *share*
  everywhere else in Rig, so `for *x` would contradict the sigil algebra.
- Dead code: rig.grammar:589–590 (rule); rig.grammar:296 (`ptr` in the
  `for` mode tag); src/ownership.zig:2464 (`mode == .ptr`);
  src/emit.zig:1360 (`mode == .ptr`); docs/INTERNALS.md:258, 272;
  SPEC.md:2403.
- After deletion, `for *x in xs` is a parse error at `*`. Optionally, the
  rewriter can give the hint "write `for x in !xs`".

### `@x` pin
- Today: `pinning sigil `@x` is reserved...` (src/typecheck.zig:1243–1246).
- Dead code: `pin_pfx` token and display (rig.grammar:152, 354); the
  `unary` rule (rig.grammar:666); `pin` in the schema (rig.grammar:335);
  lexer classification (src/rig.zig:605, 698); ownership walk
  (src/ownership.zig:1155); the SPEC §19 row (SPEC.md:2402).
  test/reject/syntax/pin_sigil_reserved.rig goes.
- Pinning belongs to a future async design, which would pick its own
  spelling. `@name(` stays a builtin call, and `@name` alone becomes a
  parse error: "expected `(`".

### `zig "..."`
- Today it's rejected in value position (src/typecheck.zig:1304–1306). At
  module level it reaches the generic
  `only declarations and bindings are allowed at module level` instead
  (src/typecheck.zig:152), which is evidence the path is unmaintained.
  SPEC.md:2406 and 2413–2421 state that inline Zig will not exist ("the
  audit boundary is a `raw` block and the FFI boundary is `extern`").
- Dead code: the `zig` keyword token and display (rig.grammar:80, 362);
  the `stmt | zig` alternative and rule (rig.grammar:397, 487); schema
  (rig.grammar:267); the keyword table (src/rig.zig:158); typecheck
  (src/typecheck.zig:1304–1306); SPEC.md:2406 and the example at
  2413–2421; test/reject/syntax/zig_block_reserved.rig.
- `zig` becomes an ordinary name. It doesn't clash in the emitted Zig
  because `writeZigIdent` handles keywords and `zig` is not one.

**Tests.** Replace the three reserved tests with parse-error tests that
pin the new messages. Run `zig build parser` and update the IR snapshots
(`./test/run --update ir`) only if a snapshot mentions these tags
(test/ir/sigils.rig does not). Risk low; net LOC negative.

## 4. `Type.method` as a function value — implement now (after 0a)

**Today.** `method `P.get` must be called; a bare method reference is not
supported` (src/typecheck.zig:1810–1813; also 1776 for the instance
form, 1891 for imported types).

**Surface.** A method named through its **type** is a plain function
value. Its type is the method's signature including the receiver:
`P.get: fun(?P) Int`, `P.bump: sub(!P)`, `P.make: fun(Int) P`. Nothing is
captured, so nothing is hidden. The **bound** form `p.get` stays rejected:
it would need an implicit receiver capture and an implicit borrow or move
of `p`, which violates "no hidden" rules. Callers can write
`|a| p.get(a)` with an explicit capture.

**Prototype.** Scratch copy: in `qualifiedMember`, for `.nominal_type`,
return `m.ty` instead of the error. `apply(P.make, 4)` gives `P(x: 4)`;
`apply(P.get, ?p)` gives `3`; `apply(P.bump, !p)` with `sub(!P)` gives
`P(x: 4)`. `g = P.get` without an annotation hits bug 0a, and works once
0a is fixed.

**Changes.** typecheck src/typecheck.zig:1810 (and 1891 for imported
nominals). Generic types (`Box.m`) stay rejected, because generic
functions are on the roadmap. Emit needs nothing: `P.get` is already
valid Zig.

**Tests.**
- Behavior: associated function, `?self`, `!self`, and a `self: Self`
  (consuming) method passed as a value.
- Reject: bound `p.get`; `Box.m` on a generic type; a type mismatch
  against the parameter's function type.

## 5. Module-level constants — implement now

**Today.** `module-level bindings are not supported yet; bind values
inside a function` (src/typecheck.zig:148–151). SPEC.md:49, 2408;
README.md:226; ROADMAP.md:13.

**Surface.** `name =! value` and `name: T =! value` at module level, and
`pub name =! value`. The value must be a Copy **constant expression**:
- literals, `none`, and `.variant` (with annotation);
- earlier module constants, referenced in textual order. That makes
  cycles impossible, and the prototype already reports a forward
  reference as "use of unbound name";
- unary and binary operators over those, and array literals of them;
- optionally, constructors of Copy structs with constant arguments, and
  checked conversions (`I32(5)`).

These are rejected:
- a plain `name = value` at module level, with the hint "a module-level
  binding is a constant; write `name =! value`";
- any value that owns a resource, because there is no place to
  initialize it: in the prototype, `b = *B(n: 1)` reached Zig as a
  comptime `SmpAllocator` error;
- any call: in the prototype, `k =! f()` with a `print` in `f` reached
  Zig as "unable to resolve comptime value".

**Why only constants.** resolve still carries vestiges of mutable
globals: `assignable` looks up a module-level `local`
(src/resolve.zig:430–440), and ownership has `isGlobal`/`rejectGlobal`
(src/ownership.zig:616–619, 1573–1580, 2041–2055). Ownership checks one
function at a time, so a mutable global that one function writes while
another holds a loan on it would break "safe code cannot corrupt memory".
The `=!` rule makes every write a "cannot reassign fixed binding" error.
The prototype confirmed this for `limit = 5` inside `main`.

**Prototype.** Scratch copy: remove the typecheck error, and add
`.set => pub const NAME: T = value;` in `emitDecl` (src/emit.zig:228–244).
Result: `print(limit * n, name, xs[1], xs, limit)` gives
`30 rig 2 [1, 2, 3] 10`. The constant machinery composed as hoped:
- `big + limit` was rejected at compile time as overflow;
- `xs[limit]` against a 3-array was rejected as out of bounds;
- `f(limit)` into a `pre` parameter was accepted.

`typecheck.checkSet` sets `comptime_known`/`const_ints` for `=!`
(src/typecheck.zig:424–429).

**Changes.**
- grammar: `decl = defn | PUB decl:defn`; add a `pub` alternative for a
  fixed binding. The schema `pub decl:` list (rig.grammar:275) gains
  `set`. There is no conflict, because every `defn` starts with a
  keyword. Regenerate with `zig build parser`.
- typecheck: in `checkDecl` `.set` (src/typecheck.zig:148), require
  `op == fixed`, a constant expression (a new `isConstExpr`, ~40 LOC,
  next to `isComptimeKnown` at src/typecheck.zig:2349), and a Copy type.
  Module-level `set` is checked in declaration order already.
- resolve: `assignable` (src/resolve.zig:437–439) should stop returning
  module-level symbols. Fixed constants make it unreachable anyway, so
  delete it.
- emit:
  - `emitDecl` `.set` emits `pub const`.
  - `collectModule` (src/emit.zig:215–226) must also collect `set`
    targets. Otherwise `new limit = 5` in a function emits
    `var limit ...` and Zig fails: "local variable shadows declaration
    of 'limit'". Verified in the prototype.
  - `emitName` (src/emit.zig:1722–1728) should wrap global
    `comptime_known` names in `rig.rt(...)` under `rt_names`, like local
    `=!` constants. Then Float arithmetic and anything else sema does not
    fold is evaluated at run time, as Rig checked it.
- modules: `mod.limit` goes through the imported-member path
  (src/typecheck.zig:1944).
- ownership: nothing new. Copy constants are never moved. Keep
  `rejectGlobal`.
- The old reject test (test/reject/types/module_level_binding.rig, `k =
  if ...`) becomes the "constant expression required" test.

**Tests.**
- Behavior: Int, Float, String, Bool, enum, array, and sized constants;
  arithmetic from earlier constants; a `pre` argument; a `pub` constant
  used from another module; shadowing with `new`; Float division by a
  runtime value.
- Reject: plain `=`; a call; an owning value; a forward reference;
  reassigning inside a function; constant overflow; a moved constant.

**Risk.** Low-medium. The main hazard is Zig's comptime evaluation of
constant operands, and it is covered by `rig.rt` plus sema folding.

## 6. Slicing — implement now

**Today.** `slicing `xs[a..b]` is not supported yet`
(src/typecheck.zig:1979–1982). Meanwhile the **type** `[]T` is fully
nameable and resolved:
- rig.grammar:500; src/resolve.zig:1134–1141;
- emitted as `[]const T` (src/emit.zig:2988–2991, 3067–3070);
- iterable (src/typecheck.zig:815–825), indexable (src/typecheck.zig:2001),
  and has `.len` (src/typecheck.zig:1754);
- printable (src/runtime.zig:831);
- treated by ownership as a loan carrier (src/ownership.zig:2899).

**No value can inhabit `[]T`.** `fun total(xs: []Int)` is accepted, but
passing `xs`, `?xs`, or a String to it is a type mismatch. The type exists
in every pass but is unreachable.

**Surface.**
- `s[a..b]` on a `String` gives a `String`, bytes `a ..< b`. Strings are
  Copy, and today every String is a static literal: there is no string
  building, and only numbers cross `extern`. A substring therefore carries
  no loan and needs no sigil. When heap strings arrive, String slicing
  must become a borrow; add a comment and a ROADMAP note.
- `?xs[a..b]` on an array, or a `Vec` of Copy values, gives `[]T`, a
  read-only view. The `?` is **required**: a slice is a read borrow of
  `xs`, and North Star rule 4 says borrows are spelled. Bare `xs[a..b]`
  on an array is rejected with "a slice borrows `xs`; write `?xs[a..b]`".
  The existing `read` node wraps the `index` node, so no grammar change
  is needed: `?xs[1..3]` already parses as `(read (index xs (.. 1 3)))`.
- A `[]T` can be sliced again: `ys[a..b]` gives `[]T` with the same
  loans, so no sigil is needed on a value that already borrows.
- Bounds are checked at run time in every mode: `0 <= a <= b <= len`.
  Constant bounds against an array's length are checked at compile time,
  like `xs[i]` today (src/typecheck.zig:1990–1994).
- Out of scope: writable slices (`![]T`), slices of owning elements
  (`[]*B`), and open ranges (`xs[a..]`).

**Ownership.**
- `?xs[a..b]` produces a read loan on the root of the place. This is the
  same as `?xs[i]`/`?p.f` through `walkBorrow` (src/ownership.zig:1389),
  so while the slice is live, `(!v).push`, writes to `xs`, and moves of
  `xs` conflict.
- `[]T` returned from a function is allowed only when its loans are
  external, that is, derived from a `[]T` parameter. That is the existing
  "returned value carries only borrows the caller handed in" rule.
- **Soundness trap.** `?[N]T` parameters are emitted **by value**
  (docs/INTERNALS.md:517–520), so slicing through one points at the
  callee's copy. The slice's loan must therefore be **local** to the
  parameter variable, not the parameter's external loan. Then returning
  or storing it is rejected ("does not live long enough"). Alternatively,
  reject slicing through a by-value borrowed parameter with the hint
  "take `xs: []T`". Add a must-reject test for exactly this case.

**Emit.** Add a runtime helper, `rig.slice(s, lo, hi)` (~15 LOC in
src/runtime.zig next to `index`, src/runtime.zig:541). It casts `lo` and
`hi` to `usize`, checks `lo <= hi <= s.len`, and returns `s[lo..hi]`.
- Arrays: `rig.slice(&xs, a, b)`.
- Vec: `rig.slice(xs.items(), a, b)`.
- String and slices: `rig.slice(s, a, b)`.

`emitIndex` (src/emit.zig:2138) gains a range branch, and `emitList`
`.read` over a range index takes it (~25 LOC).

**Typecheck.** In `synthIndex` (src/typecheck.zig:1976), a range index
requires integer bounds. The result is String for a String, `[]T` for a
`[]T`, and, when under `read`, `[]T` for an array or a Copy Vec (~50 LOC).
`synthBorrow` must pass the "under read" context down, or handle
`(read (index _ (..)))` itself.

**Tests.**
- Behavior: substring; empty slice; slice passed to a `[]Int` parameter;
  a slice of a slice; iteration and `.len`; a slice returned from a
  `[]T` parameter; a panic on `a > b` and on `b > len`
  (`# expect-panic:`).
- Reject:
  - bare `xs[a..b]` on an array;
  - writing `xs` while a slice is live;
  - `(!v).push` while a Vec slice is live;
  - returning a slice of a local array;
  - returning a slice of a `?[N]T` parameter;
  - a constant out-of-range bound;
  - a Vec of owning elements.

## 7. Optional propagation `e?` — implement (second wave)

**Today.** It's a parse error: `unexpected `?``. The lexer already emits
`SUFFIX_Q` for `x?` (checked with `rig tokens`), so this is purely a
grammar addition.

**Surface.** `e?` on a `T?` operand yields `T`. On `none`, the enclosing
function returns `none`, which requires a `-> U?` return type. This
mirrors `e!` (ROADMAP.md:12). As with `!`, it is not allowed in closure
bodies, `defer`, or `sub main`. It enables `find(k)?.name`, which reaches
a field through an optional without a temporary `if ... as`. An optional
binding holding an owning value must be moved (`(<m)?`), matching
`if <m as x` (SPEC.md:2093–2096). A temporary is unwrapped by ownership
transfer.

**Changes.**
- grammar: `postfix | value:postfix SUFFIX_Q → (unwrap)`, plus a new
  schema node `unwrap value` (rule 4: a named node). The prefix `?x` is
  `READ_PFX` and `??` is its own token, so no conflict is expected;
  verify with Nexus.
- typecheck: `synthUnwrap` next to `synthPropagate` (src/typecheck.zig:1588),
  ~25 LOC.
- effects: `checkUnwrap`, mirroring `checkPropagate`
  (src/effects.zig:113–116, 165–180), ~30 LOC.
- ownership: a `walkUnwrap` that is `walkPropagate` without the
  `try_ctx` branch (src/ownership.zig:2667–2677). It is an exit that runs
  the defers, then it applies the consumed-value rule (~30 LOC).
- emit: `(e orelse return null)`, next to `.propagate`
  (src/emit.zig:1959), ~10 LOC. It needs care inside an error-union
  return (`U?!`): `return null` also works there.

**Tests.**
- Behavior: a chain of lookups; `e?.field`; a `defer` running on the
  none path; an owning optional temporary; the leak check on the none
  path.
- Reject: in a non-optional function; in `sub main`; in a closure; in
  `defer`; on a non-optional operand; an owning optional binding without
  `<`.

## 8. `break` with a value — loops as expressions (second wave)

**Today.** `break` with a value is `not supported yet`
(src/typecheck.zig:282–284). `x = while ...` is rejected with
"`x` would be bound to a value of type `Void`".

**Surface.** A `while` or `for` whose value is used must have an `else`.
The value comes from `break v` (or `break :label v`) or from the `else`
block's value. Every `break` that targets such a loop must carry a value
of the loop's type. A `break v` targeting a loop whose value is unused is
an error. This is the Zig semantics.

```rig
fun find(xs: ?[4]Int, t: Int) -> Int
  for x, i in xs
    break i if x == t
  else
    -1
```

No grammar change: the grammar already has
`BREAK [":" label] [value:tail]` (rig.grammar:417), and `while`/`for`
are `expr`s (rig.grammar:534–535).

**Changes.**
- typecheck (~90 LOC): add a loop stack `{ node, label, expected: ?TypeId,
  value_used }` and push it in `checkWhile`/`checkFor`
  (src/typecheck.zig:700) and in their value-position entry. Route
  `.while`/`.for` in `synthList` (src/typecheck.zig:1281–1284) to a
  value-checking path. `break` resolves its target by label or innermost
  loop, and the `else` body is checked like a branch.
  `isValueStmt`/`terminates` (src/typecheck.zig:3763, 3812) must treat
  a value loop as a value.
- ownership (~80 LOC): `walkJump` (src/ownership.zig:2622) walks the
  value as consumed (the `walkReturnValue` rules: a bare local moves, no
  implicit copy of owning values). It records the value's loans in
  `LoopCtx`, and rejects loans rooted in vars declared inside the loop
  (`l.root >= depth`, the same check `exitState` does at
  src/ownership.zig:2663–2668). `walkLoop` (src/ownership.zig:2503)
  returns the union of break values and the else value.
- emit (~60 LOC): lower every value loop the same way:
  `rig_loop_N: { <loop as statement, no else>; break :rig_loop_N <else value>; }`.
  `break v` targeting it becomes `break :rig_loop_N v`. Because the
  `else` value runs only when no `break` left the block, this preserves
  the else semantics. It also works for the block-wrapped forms (range
  for, consuming `for x in <v`; src/emit.zig:1407, 1455), which Zig's
  native `while ... else` expression could not express. The usage scan
  already treats break values as consumed (src/emit.zig:3351).
- effects: none (it walks children).

**Tests.**
- Behavior: while, range for, array for, consuming for (owning element
  broken out, rest dropped), and labeled outer break with a value;
  `else` taken; a value loop as a `fun`'s last expression; an owning
  value moved out by `break`, leak-free.
- Reject: no `else`; a bare `break` in a value loop; `break v` in a
  statement loop; mismatched break types; breaking a borrow of a
  loop-local; breaking an owning binding without moving it; `break v`
  inside a closure.

**Risk.** Medium, because ownership has to carry values across jumps.
The value is moderate: search loops are common, and Rig has no iterator
adapters or generic functions to replace them.

## 9. Calling a function-typed field — implement now (small)

```rig
struct H
  f: fun(Int) Int
...
print(h.f(2))      # error: no method `f` on type `H`
```

`g = h.f; g(2)` works, and `(h.f)(2)` fails the same way because the
parentheses vanish from the IR. Fix: in `synthMemberCallInner`
(src/typecheck.zig:2505), when no method matches and a data field of
function type (or `*fun`) exists, check a call of the field. Emit
`h.f(2)`, which Zig calls through the pointer field, or
`h.f.value.invoke(.{2})` for an owned closure field. ~20 LOC. Tests:
a plain `fun` field, an owned-closure field, and a reject for an
arity mismatch.

## 10–12. `pre` blocks, `pre` expressions, `try` blocks

- **`pre` block** (`PRE body:block → (pre_block)`, rig.grammar:421).
  Rejected at src/typecheck.zig:1296–1298. A statement-level
  compile-time block does nothing useful without compile-time
  assertions, and ROADMAP.md:15's item is really about `pre`
  expressions. **Delete** the statement form and its schema entry
  (rig.grammar:306) and test/reject/syntax/pre_block_reserved.rig.
  Keep `pre` expressions reserved.
- **`pre` expressions**. **Defer, keep reserved.** Compile-time
  evaluation needs an effect analysis (no allocation, print, extern, or
  refcount) so that accepted programs always evaluate in Zig comptime.
  That is not small.
- **Value-yielding `try` block**. **Defer, keep reserved** (ROADMAP.md:18).
  Ownership already models it: `TryCtx` and `walkTryBlock`
  (src/ownership.zig:243, 2679–2703); `walkPropagate` routes to it
  (src/ownership.zig:2671); resolve walks `catch_block`
  (src/resolve.zig:87). What's missing:
  - effects: `!` inside a try block is allowed in a non-fallible function;
  - typecheck: the block value;
  - emit: `!` inside the block becomes
    `catch |e| { err = e; break :body; }` within a labeled block pair.
  - One design question is open: an `errdefer` inside a try block would
    not fire in Zig when control jumps to the catch. Reject it or define
    it.

  ~200 LOC, medium risk. Worth doing after `e?` and break-with-value,
  since it composes with both.

## 13–16. Keep or defer

- **Bound method reference `p.get`**: keep rejected. The diagnostic
  (src/typecheck.zig:1776) could suggest `Type.get` once item 4 lands.
- **`drop` on enums and generic types** (src/resolve.zig:836–846;
  ROADMAP.md:19): defer. Generic `drop` needs the body checked for all
  `T`, and glue for instances. Enum `drop` needs the user body plus
  per-variant payload glue in `__rig_drop`. 150–300 LOC each.
- **Generic types across modules** ("qualified types do not take [type
  arguments] yet", src/resolve.zig:1221; "generic types cannot cross
  module boundaries yet", src/resolve.zig:1373): defer, medium.
- **`use std`** (src/modules.zig:184): keep reserved for the future
  standard library.
- **Lexer, `]` followed by a sigil in a type**: `fun f(xs: []*B)` fails
  with "unexpected `*`; expected a type", because `]*` lexes as infix
  `star`. `[](*B)` works. This matters only once slices of handles exist.
  Fix it in the rewriter by tracking type context after `:`/`->` (~15
  LOC), or document the parentheses.

## Documentation drift found

- README.md:226 lists "a `rig test` runner" as not yet available, but it
  exists (docs/INTERNALS.md:57–66). Already in the ledger.
- The "lift the capture to the outer scope" hint (src/typecheck.zig:3461)
  cannot be followed for closure-body locals. This goes away with item 1.
- The `for *x` diagnostic (src/typecheck.zig:719) never mentions
  `for x in !xs`. This goes away with item 3.

## Evidence index (scratchpad/audit-gaps/)

- Current binary: break_val*.rig, loop_expr.rig, field_default.rig,
  modconst.rig, slice*.rig, optprop.rig, methref*.rig, nested_*.rig,
  forptr.rig, pin.rig, preblk.rig, tryblk.rig, zig.rig, fnval*.rig (bug
  0a), u_label_match.rig and u_label_raw.rig (bug 0b), fnfield.rig,
  lex_slice.rig, vd.rig, dropenum.rig, dropgen.rig.
- Patched copy (rigcopy/bin/rig): nested_* (all pass), fd*.rig and
  fd_import*.rig (field defaults), mc*.rig (module constants), and
  methref2–5.rig (type-qualified method references).
