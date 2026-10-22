# Audit: cmp-foundations (structural `==`, String/`[]U8` ordering)

Branch `cmp-foundations` (4 commits over `main`), worktree `/Users/shreeve/Data/Code/rig-3c1`, its `bin/rig`.
Baseline comparisons use `main` built from `git archive main` into the scratch dir.
Repros are in `/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R3c1/` (called `$R` below), run with `RIG_OUT_DIR=$R/out`.
I ran every finding at least twice.

## Findings

| # | Sev | Kind | Repro | Summary |
|---|---|---|---|---|
| 1 | **Critical** | wrong accept (Zig compile error), **regression** | `$R/f_ctx_handle.rig` | `s == .empty` on a payload enum that holds a handle is accepted, but the emitted Zig fails to compile. `main` compiles and runs it. |
| 2 | **Critical** | wrong accept (leak, missed `drop`, non-equatable compared) | `$R/f_ctx_payload_owning.rig` | A payload variant literal against an enum holding a `Vec` or a `drop` type is accepted. It compares the Vec, leaks its buffer, and never drops the temporary resource. |
| 3 | **High** | wrong accept (Zig compile error), **regression** | `$R/f_ctx_generic.rig` | In a generic body, `o == .nothing` on `Opt[T]` records no `==` requirement on `T`. `Opt[fun(Int)->Int]` (or `Opt[*N]`) then fails in Zig. `main` runs it. |
| 4 | Medium | wrong result | `$R/f_nan_slice.rig` | `?xs[0..2] == ?xs[0..2]` is `true` for a `[]Float` holding NaN, but `xs == xs` (array) is `false`. This contradicts the SPEC/SYNTAX claim that "NaN is never equal". |
| 5 | Low | wrong reject | `$R/f_array_literal_adapt.rig` | `xs == [1, 2]` with `xs: [2]U8` (or `[2]Float`) fails with "cannot compare `[2]U8` with `[2]Int`": the array literal does not adapt to the other operand. |
| 6 | Low | doc overclaim / wrong reject (pre-existing) | `$R/f_generic_opt_vs_T.rig` | The new SPEC text says "On a `T`, `==` compares whatever `==` compares outside a generic body". Yet `a == b` with `a: T?, b: T` is rejected ("cannot compare `T?` with `T`"), and outside a generic body `P?` vs `P` works. |
| 7 | Low | new accept of undocumented type | `$R/f_void_eq.rig` | `f() == f()` for two `sub`s (`Void`) is now accepted and prints `true`. `main` rejected it ("`==` is not defined for `Void`"), and SPEC does not list Void as equatable. |
| 8 | Low | wrong reject | `$R/f_const_array_eq.rig` | `SAME =! ARR == [1, 2]` is rejected as "not known at compile time". The diagnostic and SPEC both say operators over constants and arrays are allowed, and `"a" == "a"` and `"a" < "b"` constants are accepted. |
| 9 | Low | bad diagnostic | `$R/f_imported_type_name/main.rig` | "field `g.h` is a handle `*Point`": the type is named in the imported module's context. It is `*geo.Point`, and the importer has its own `Point`. Same for "`Res` declares `drop`" on an imported `geo.Res`. |
| 10 | Low | docs untested | — | The claims in the list below hold when run, but no test or doc example checks them (AGENTS rule 1). |

### 1–3. The contextual (`.variant`) branch of `synthEquality` skips `checkEquatable`

**Suspected code.** `src/typecheck.zig:1938-1947`: both `isContextual` branches `checkExpr` the literal and return without ever calling `checkEquatable` on the other operand's type. On the emit side, `src/emit.zig:3682` (`comparesStructurally`) sends every payload-enum operand to `rig.eql`. `rig.eql` (`src/runtime.zig`, `eqlAs` `.union` arm) instantiates a payload comparison for **every** variant (`inline else`), so a handle or fn payload in any variant hits the `@compileError` at `src/runtime.zig:187`.

On `main`, a bare `.variant` lowered to Zig's `union == .tag`, which compares only the tag and compiled for any payload. Payload literals (`.v(...)`) are new in this branch (commit 48285f3), so finding 2 is new too.

**Repro 1** (`f_ctx_handle.rig`):
```rig
struct N
  n: Int

enum Slot
  held(p: *N)
  empty

sub main()
  s: Slot = .held(p: *N(n: 1))
  print(s == .empty)
```
`rig check` exits 0. `rig run`:
```
out/rig/runtime.zig:187:35: error: rig.eql: no `==` on *rig.runtime.RcBox(__rig_main.N)
```
`main` prints `false`. The same failure occurs:
- with an fn-typed payload (`f(g: fun(Int) -> Int)`);
- for an imported `geo.HasFn` compared with `.none_`;
- for `o: Slot? ... o == .empty`. This optional case also fails on `main` ("operator == not allowed for type '?Slot'").

**Repro 2** (`f_ctx_payload_owning.rig`):
```rig
struct R
  n: Int

  drop(!self)
    print("drop", self.n)

enum A
  v(items: Vec[Int])
  e

enum D
  r(res: R)
  e

sub main()
  a: A = .e
  v = Vec[Int]()
  !v.push(1)
  print(a == .v(items: <v))
  d: D = .r(res: R(n: 1))
  print(d == .r(res: R(n: 2)))
```
`rig check` exits 0. Output:
```
false
false
drop 1
error: rig: memory leak detected: 1 allocation (32 bytes) never freed
```
Three things are wrong:
- the moved-in Vec temporary leaks;
- `R(n: 2)` is never dropped, so no `drop 2` is printed;
- both `Vec` and `drop` types are documented to have no `==`.

`D.r(res: R(n: 2))`, the qualified non-contextual form, is correctly rejected.

**Repro 3** (`f_ctx_generic.rig`):
```rig
enum Opt[T]
  some(value: T)
  nothing

fun is_nothing[T](o: ?Opt[T]) -> Bool
  o == .nothing

fun inc(x: Int) -> Int
  x + 1

sub main()
  o: Opt[fun(Int) -> Int] = .some(value: inc)
  print(is_nothing(?o))
```
`rig check` exits 0. `rig run` fails with `rig.eql: no `==` on *const fn (i64) i64`. `main` prints `false`. `a == .some(value: v)` in a generic body behaves the same (`t25_genfn.rig`), and `Opt[*N]` fails too (`t12_gen.rig`).

**Fix idea.**
- (a) In typecheck, when the contextual operand is a payload literal (`call` with an `enum_lit` callee), call `checkEquatable(reached_type, other, op)`. This rejects Vec, drop, handle, and fn payloads, and records the per-instance `T` requirement in generic bodies.
- (b) For a **bare** `.variant` of a payload enum (or an optional of one), keep `main`'s semantics: it tests the tag only and is valid for any payload. In `rig.eql`, when one operand's type is `@TypeOf(.enum_literal)`, compare `std.meta.activeTag(x) == lit` (unwrapping the optional first) and never instantiate the payload comparison. Alternatively, emit that from `comparesStructurally` when an operand is a bare `enum_lit`.
- If (b) is not done, a bare `.variant` must also go through `checkEquatable`. That rejects `slot == .empty` on handle-holding enums, a regression from `main`.
- Tests: a behavior test for `handle_enum == .empty` (plain and optional), and reject tests for payload literals holding a Vec or `drop` type and for the generic `Opt[fn]` case.

### 4. NaN in a `[]Float` equals itself when both operands are the same slice

**Repro** (`f_nan_slice.rig`):
```rig
struct S
  v: Float

sub main()
  nan = 0.0 / 0.0
  xs = [nan, 1.0]
  ys = [nan, 1.0]
  ss = [S(v: nan)]
  print(xs == xs, ?xs[0..2] == ?xs[0..2], ?xs[0..2] == ?ys[0..2], ?ss[0..1] == ?ss[0..1])
```
Output: `false true false false`. The expected output is `false false false false`.

**Cause.** `src/runtime.zig:188` sends scalar slices, floats included, to `std.mem.eql`. In Zig 0.16 (`lib/std/mem.zig:740`), `std.mem.eql` returns `true` early when `a.ptr == b.ptr`. The same bug hits a generic `[]T` with `T = Float`.

**Fix.** Exclude floats (and structs or arrays of them) from the `std.mem.eql` fast path: `isScalar` minus `.float`, or loop element by element for floats. Add the NaN-slice line to `test/behavior/types/struct_equality.rig`.

### 5. Array literals don't adapt to the other operand's element type

`xs: [2]U8; xs == [1, 2]` fails with `cannot compare `[2]U8` with `[2]Int``. The same happens for `[2]Float` against `[1, 2]`.

**Suspected code.** `synthEquality`, `src/typecheck.zig:1949`: both operands are synthesized independently. Only numeric literals adapt, through `comparesWithOptional` and `checkNumericComparison`.

**Fix.** When one operand is an array or array-fill literal and the other is not, `checkExpr` the literal against the other's reached type, as the contextual path does.

### 6. Generic `T?` vs `T` rejected, contrary to the new SPEC sentence

`fun holds[T](a: T?, b: T) -> Bool: a == b` fails with `cannot compare `T?` with `T``. The same message appears on `main`.

**Suspected code.** `src/typecheck.zig:1958`: the `type_var` branch runs before `comparesWithOptional`.

**Fix.** Try `comparesWithOptional` first, or when `tb == .type_var` and `ta == .optional(tb)`. Alternatively, soften SPEC §4 "Generic bodies" (the "whatever `==` compares outside a generic body" sentence).

### 7. `Void == Void` now accepted

`EquatableWalk.check` (`src/sema.zig:2144`, `else => return null`) treats `void` (and any unlisted kind) as equatable. `rig.eql` then returns `true` through `.void`.

**Fix.** Return a "no `==`" reason for `.void` and `.noreturn`, or document it. The safest way is to list the equatable leaf kinds explicitly instead of defaulting to null.

### 8. Array `==` in a module constant

`isConstExpr`/`isComptimeKnown` (`src/typecheck.zig:278`) does not accept `==` over constant arrays, though SPEC §4 "Constants" says "operators and array literals over them".

**Fix.** Either fold array `==` in `isComptimeKnown`, or narrow the SPEC and diagnostic wording.

### 9. Imported type names in the `==` reason

`notEquatableReason` (`src/typecheck.zig:6154`) formats `n.ty` with `formatTypeIn(n.ctx, ...)`, which is the foreign module's context. So `*geo.Point` prints as `*Point`, `geo.Res` as `Res`, and so on. `test/reject/modules/imported_equality_handle` asserts the unqualified `*Point`.

**Fix.** When `n.ctx != ctx`, qualify with the module's name, or map the type into the importer's store.

### 10. Doc claims with no test

Each item below behaves as documented when run (`t36_misc.rig`, `t36b.rig`, `t18_orddiag.rig`), but nothing in the suite checks it:
- SPEC §6 / SYNTAX §10 "A method named `eq` is never called by `==`" / "no `eq` method is called": no test.
- "`~T` has no `==`": no reject test.
- "Cell, Signal have no `==`": no reject test; only Vec is covered.
- "owned closure" has no `==`: no test hits the `.closure` message.
- "A borrowed operand (`?P`, `!P`) compares as the value it reaches": no test for `!P` on a concrete struct. The generic tests cover `?T`.
- "Structs, enums, and other slices have no ordering" and SYNTAX "Structs and enums have no ordering": no test for enum or Bool ordering. The `generic_ordering.rig` header says "other slices are not", but the test has no slice case.
- SPEC/SYNTAX "Floats compare as IEEE numbers wherever they are": finding 4 contradicts it for slices.

### Pre-existing, noted only

These are the same on `main` and outside the branch's scope:
- `none == none` says "`none` is not optional (write `none?`)".
- `.a == .a` gives two errors.
- `p == .red` on a struct says "no variant `red` on enum `P`".
- `k == .a(w: 1)` gives two errors: "no field `w`" and "missing field `v`". This matches a plain binding.

## Came up clean

All of these ran leak-free with the right output (Debug, plus ReleaseSafe for t01/t03/t04/t15, whose outputs were identical).
- **Nested shapes** (`t01_nested.rig`): optional of a payload enum holding an array of structs holding String and U8, and structs of those. Slices and arrays of them, `==` and `!=`, variant literal on either side, including against an optional.
- **Errors** (`t02_err.rig`):
  - `E` vs `E?`, `E?` vs `none`, and `E?` vs `.bad`;
  - structs with `E` and `E?` fields, arrays of `E?`;
  - `err == E.bad` and `err == .worse` inside `catch`, where errors match by name across sets.
- **Floats and ints** (`t03_float.rig`): `-0.0 == 0.0` in structs and arrays. NaN fields, arrays, optionals, and payloads are unequal. Payload enums with the same tag and different payload are unequal. U8/I64 fields.
- **Strings** (`t04_str.rig`): shared prefixes, embedded `\x00`, non-ASCII (`"é" > "z"`), the empty string, and all four orderings. `[]U8` ordering of different lengths.
- **Borrowed operands** (`t05_borrow.rig`, `t17_wb.rig`, `t07_retborrow.rig`):
  - `?P`/`!P` against owned values, `?[2]P`, `?P?`;
  - write-borrowed `!String` ordering;
  - functions returning `?P`/`!P`/`?String`, methods returning `?P`;
  - Vec element and slice comparisons.
- **Side effects** (`t06_side.rig`, `t35_alias.rig`, `t35b.rig`):
  - each operand is evaluated once, left to right;
  - `f()! == g()!`, `getS()! <= getS()!`, `getO()? == getO()?`, and `catch` operands;
  - `a == bump(!a)` and `t < bumpS(!t)` see the pre-mutation left operand, in Debug and ReleaseSafe and with a 64-word struct.
- **Vec slices and views** (`t08_vec.rig`):
  - `[]P`, `[]String`, and `[]U8` from a Vec, and `[0]Int` arrays and empty slices;
  - a struct holding a String slice (`s[1..3]`);
  - views (`[]T` fields) rejected.
- **Rejections** (`t09_rej.rig`, `t23_gm.rig`, `t36_misc.rig`, `m4`):
  - Vec, Cell, Signal, `*T`, `~T`, `*sub()`, fn values, and `drop` types, directly, nested, and imported;
  - field paths through generic instances and variants (`p.second.a.inner.h`, `w.item`, `some.value`, `slots.full.held`).
- **Generics**:
  - per-instance `==` requirement through chains (`t10_chain.rig`: `inner[Wrap[*N]] is made by mid[*N]`);
  - generic methods (`self == o`) and comptime-int generics (`Ring[T, n]`, `f[n: Int]`) (`t23_gm.rig`, `t31_ring.rig`, `t32_ctn.rig`);
  - `same[T]` over payload enums, optionals, arrays of String, error sets, `E?`, Bool, and Float (`t41_genall.rig`);
  - one error per instance even with repeated calls (`t42.rig`).
- **Generic ordering** (`t15_gord.rig`):
  - `rig.compare` with every operator, for U8 (200 vs 3), Float with NaN and ±0, and String;
  - through `?T` borrows and literals;
  - a generic bubble sort over `[3]String` and `[3]Float`.
- **Generic literals**:
  - a literal a `T = String` instance cannot hold is rejected, for `<`, `>`, and `==` (`t16_glit.rig`);
  - a `T` vs a String literal is rejected (`t40.rig`).
- **Imports**:
  - imported structs and enums compared directly, as `T` in local generics, and inside local generic instances;
  - an imported module's own private generic `==` (`m1`, `m3`);
  - imported handle structs rejected as `T` with the reason (`m2`).
- **Control flow and precedence** (`t19_ctx.rig`, `t37_prec.rig`):
  - `if`/`else if`/`while` conditions and step, trailing `if` guards, ternaries, struct field initializers, closures, match arm values, `for` bodies, and indexed assignment;
  - `not a < b`, `not p == q`, and `(a == b) == (c < d)`.
- **Constants and literals** (`t29_const.rig`, `t43.rig`, `t26_lit.rig`, `t27_opt.rig`, `t39_optenum.rig`):
  - `"a" < "b"`, `"a" == "a"`, `NAME >= "ri"`, and string constants of different lengths;
  - `U8?`/`Float?` vs literals;
  - `([2]Int)?`, `String?`, `P?`, `([]Int)?`, and `[2]P?` against values and `none`;
  - optional plain enum vs `.red`.
- **Ordering diagnostics** (`t18_orddiag.rig`): "orders numbers, Strings, and `[]U8` slices; got `P`/`C`/`Bool`/`[]Int`/`[2]Int`", and "different types" for `String` vs `[]U8` or `String?`. One error per mistake. Poisoned operands give one error each (`t38_poison.rig`).
- **Numeric comparisons unchanged from `main`** (`t28_num.rig`, `t28b.rig`): mixed U8/I8 literals, borrowed ints, and `x < 300` on U8.
- **Performance**:
  - a 1000-field struct `==` checks, builds, and runs in about 1 s (`t20_big.rig`);
  - a 300-deep struct/enum/optional chain takes about 1.5 s (`t21_deep.rig`);
  - a depth-17 diamond DAG of 131k leaves takes about 1 s; the `visited` memo prevents blow-up (`t22_dag.rig`).
- **Existing tests**: `./test/run equal` (14) and `./test/run ordering` (4) pass. The SPEC §6 and SYNTAX §10 doc examples run as documented.
