# Audit: ct-sizes, soundness and emit correctness

Branch `ct-sizes` (3e5383a, 2 commits over main). Lens: programs that `rig check` accepts but that fail to compile in Zig, print wrong results, leak, or corrupt memory.

- Tools: the existing `bin/rig`, plus a scratch build of `main` (made with `git archive main`) for pre-existing comparisons.
- Repro programs are in `/private/tmp/claude-501/-Users-shreeve-Data-Code-rig/cd00b9f1-8a48-4d11-9781-761746a24702/scratchpad/R8a/repro/`. Probe files are in the parent directory.
- Every finding below was run twice.

## Findings

| # | Sev | Kind | Summary | Repro |
|---|---|---|---|---|
| F1 | High | wrong accept (Zig compile error) | Indexing an array of concrete length 0 with a run-time index emits `a[rig.index(i, 0)]`, which Zig rejects. The feature makes this easy to reach: `[7; 0][i]`, `zeros[0]()` then `b[i]`, and `Ring[Int, 0]` with `r.items[i]` in non-generic code. | `repro/F1_zero_len_index.rig` |
| F2 | Medium | wrong accept (Zig/LLVM failure, hang) and runtime crash | Lengths are capped at 2^32−1 elements, but byte size is not capped. Any local reaching 4 GiB fails in LLVM, a large module constant hangs the Zig compiler, and locals from roughly 8 MB up segfault at run time (stack overflow). | `repro/F2_huge_local.rig`, `repro/F2c_huge_const.rig`, `repro/F2b_stack_overflow.rig` |
| F3 | Low | semantic inconsistency (no unsoundness) | Size and fill-count folding does untyped i128 math. `W: U8 =! 200; [W * 2]Int` has length 400, while `K =! W * 2` is rejected as overflow. Intermediate overflow is also accepted: `[BIG*4 - BIG*4]Int` has length 0, while the same expression as a constant is rejected. | `repro/F3_untyped_fold.rig`, `repro/F3b_typed_fold_rejects.rig` |
| F4 | Low | inconsistency | A size may name a module constant declared later (`Z =! [0; B]` before `B =! 3` is accepted and correct), while `A =! B + 1` in the same position reports "use of unbound name `B`". Harmless. | `repro/F5_forward_const.rig` |
| F5 | Low | wrong reject | `[(n)]Int` is a parse error ("unexpected `)`"), while `[(A + B) * 2]Int` and `[0; (n)]` are accepted. `cexp` requires an operator. | `ac1.rig` (original form) |
| P1 | Medium (pre-existing, also on main) | wrong accept (Zig compile error) | `a = [1, 2]; out = a; for x in !out  x += 1` emits `const out = a;` and then `x.* += 1` gives "cannot assign to constant". It works only when the initializer is a literal. Not caused by this branch, but it bites symbolic-array code (`out = xs` in `fun inc[n: Int](xs: [n]Int)`). | `repro/P1_for_write_const.rig` |

### F1: indexing a zero-length array (High)

```rig
struct Ring[T, n: Int]
  items: [n]T

fun at(i: Int) -> Int
  [7; 0][i]

sub main()
  r = Ring[Int, 0](items: [])
  i = 0
  for j in 0..1
    i += j
  print(at(i))
  print(r.items[i])
```

`rig check` exits 0. `rig run` fails as follows:

```
out/__rig_main.zig:13:34: error: indexing into empty array is not allowed
    return @as([0]i64, @splat(7))[rig.index(i, 0)];
out/__rig_main.zig:31:25: error: cannot index into empty array
            r.items[rig.index(i, 0)] = ...   (also for reads)
```

Other accepted forms that fail the same way:

| Form | Probe file |
|---|---|
| `b = zeros[0](); b[i]` | `r6.rig` |
| `r = Ring[Int, 0](...)` then `r.items[i] = 3` | `r7.rig` |
| `fun at(xs: [0]Int, i: Int) -> Int  xs[i]` | `r4.rig` |
| `[Z]Int` with `Z =! 0` | `r5.rig` |
| a struct field `xs: [0]Int` written through `!self` | `r2.rig` |

- The `r2` and `r4` forms fail identically on main, so the bug predates the branch. The branch made zero lengths first-class (`[x; 0]`, `n = 0` instances, `Ring[_, 0]`) and added the fix only for symbolic lengths.
- Suspected code: `src/emit.zig:2426`, `if (self.sema.types.get(n) != .ct_value)`. The `rig.elems(&base)[rig.index(i, n)]` path is taken only for a symbolic length. A concrete `ct_value` 0 falls through to `base[rig.index(i, 0)]`.
- Fix: take the `rig.elems` path when the length is symbolic or `sema.arrayLen(..) == 0`, or always for a non-literal index. Sema already rejects constant indexes into `[0]T`.
- Add behavior tests: an `expect-panic` for `[7; 0][i]` and one for `Ring[Int, 0]` `r.items[i] = x`.

### F2: array byte size is not capped (Medium)

- `a: [4294967295]U8 = [0; 4294967295]` passes `rig check` (the length is at the cap). `rig run` exits 1 after about 24 s at about 11.5 GB RSS:

  ```
  warning: __rig_main.zig:6:0: stack frame size (4294967376) exceeds limit (4294967295) in function '__rig_main.main'
  error: <unknown>:0: cannot encode offset of relocations; object file too large
  ```

  `[0; 4000000000]` (Int, 32 GB) fails the same way.
- `BIG =! [7; 4000000000]`, a module constant, passes `rig check`. The build did not finish within the 120 s CPU limit.
- `a: [100000000]U8 = [7; 100000000]` passes check and builds, but running it gives "Segmentation fault at address …" in the `main` prologue. That is a stack-probe crash, not silent corruption.
- Heap placement works: `*H[100000000](a: [0; 100000000])` ran fine.
- Suspected code:
  - `src/sema.zig:146` (`max_array_len`) bounds elements, not bytes.
  - `src/resolve.zig:1421` is the only range check.
  - `.git/revamp/design-step2.md` §8 already notes that total size is unchecked.
- Fix idea:
  - In sema, reject any array type (including nested and generic instances, checked per instance) whose byte size exceeds a limit, with a Rig diagnostic.
  - A hard cap below 4 GiB keeps the emitted Zig compiling.
  - A much smaller cap (say 1–8 MiB) for locals and temporaries would also prevent the stack-overflow crash.
  - At minimum, document the stack limit.

### F3: size folding ignores operand types (Low)

- `W: U8 =! 200` with `a: [W * 2]Int = [0; W * 2]` passes check and prints `400`.
- The same expression elsewhere is rejected:
  - `K =! W * 2` gives `integer value 400 does not fit in U8`.
  - `R[W * 2](...)` also gives `expected Int, got U8`.
- `[BIG * 4 - BIG * 4]Int` with `BIG = maxInt(i64)` is accepted as `[0]Int`. `K =! BIG * 4 - BIG * 4` is rejected for overflow.
- Nothing unsafe follows, because the emitted Zig uses the folded number. But the same Rig expression means different things in different positions.
- Suspected code:
  - `sema.constIntBy` (`src/sema.zig:2481`) folds in i128 with no per-operand type.
  - It is called from `resolve.TypeResolver.ctIntOf` (`src/resolve.zig:1444`) and `Checker.ctIntArg`.
- Fix: fold sizes with the typed constant checker, so every intermediate value must fit its operand type. Or reject any size expression whose intermediate values leave the operand type's range.

### P1: `for x in !out` over a copied array (pre-existing)

- On both `main` and this branch, `a = [1, 2]; out = a; for x in !out  x += 1` passes check, and the Zig build then fails with "cannot assign to constant".
- The emitter's `is_var` (`src/emit.zig:1051`) sees `written == false`. It seems the `for` source `!out` never reaches `markWritten` (`src/resolve.zig:91`/`420`).
- `out = [1, 2]` works only because a literal initializer forces `var`.
- It is reachable in symbolic code: `fun inc[n: Int](xs: [n]Int) -> [n]Int  out = xs; for x in !out ...`.

## Clean: probed and correct

Each of these passed check, ran, printed the right values, and had no leaks under the checking allocator.

**Indexing and bounds**
- `!self` writes into `[n]T` fields: `self.items[i] = x`, `+=`, and `bump(!self.items[i])`.
- Nested `self.inner.items[i]`, `self.pts[i].x = …`, and `self.grid[i][j] += …`.
- Rvalue bases: `mk[n](7).items[i]` and `[3; n][i]`.
- A match capture `.full(items) => items[0]`.
- Borrow fields `data: ?[n]Int` and `data: ![n]Int`.
- Large borrowed arrays (5000 elements).
- An out-of-range run-time index or slice on a symbolic array panics with "index out of bounds" or "slice bounds out of range", including `n = 0`.
- A constant index into a symbolic array is checked at run time.

**Zero length through symbolic paths**
- `zeros[0]()`, `Ring[Int, 0].new`, and `for` / `for x, i` over it.
- `print`, `.len`, `?xs[a..b]`, and `[[0; 3]; 0]` / `[[0; 0]; 3]`.
- Symbolic `g[i][j]` with m = 0.
- `Slot[0].full(items: [])`.
- `==` on arrays and on structs holding arrays is rejected everywhere, as before.

**Slicing and borrows**
- `?xs[a..b]` of owned and borrowed `[n]T`, and `for` over the slice.
- Passing `?[n]T` / `![n]T`, including `![n]T?` fields, to generic functions that infer `n` from the field.

**Nested and composite types**
- `[n][m]Int` through `![n][m]Int`.
- Arrays of optionals, plain structs, enums with payloads, and function references in fills.
- `Ring[Pt, 2]`, `Ring[Color, 3]`, `Ring[Int?, 2]`, and `Ring[Ring[Int, 2], 2]`.
- Generic methods with their own params:
  - `resize[m]`, whose `m` is inferred from the expected type
  - `conv[U]`
  - `zip[m](?Ring[T, m])`
- `Two[n, m].swap() -> Two[m, n]`, which is not mistaken for `@This()`.

**Containers and handles (leak-free)**
- `Vec[Plain[Int, 2]]`, `Vec[*Ring[Int, n]]` with a `Vec` field, `*Ring` with `+` / `~` / `-`, and `Cell[Ring[Int, 2]].replace`.
- Pool-in-Pool drop glue with `*Tag` handles.
- Correctly rejected:
  - `Vec[Ring…]` holding a Vec
  - `Ring[*P, 1]`, `Ring[Vec[Int], 0]`, and `Ring[!Int, 2]`
  - `[+h; 3]`, `[?x; 2]`, `mk[*P, 3]`, and `mk[?Int, 2]`

**Value-param widths**
- U8, U16 alias, I32, and U64 params, including U64 = 2^64−1 printed correctly.
- Correctly rejected:
  - an Int param passed to a U8 slot, explicitly or inferred
  - Int-typed `n` used as a U8 type argument
  - an inferred value too large for the width (`R(items: [0; 256])`)
- Run-time arithmetic on `n` (`rig.rt(n)`) panics on overflow instead of failing at Zig comptime.
- Division by `n = 0` panics.
- `x << n` works.
- Comptime-known conditions on `n` (`return -1 if n == 0`, `match n`, and `while n > 0`) emit valid Zig.

**Compile-time evaluation**
- Division or modulo by zero in sizes, and arguments `R[Int, 7 / 0]`, are rejected.
- Negative and above-2^32 sizes are rejected, directly, through `k =! n`, through generic bodies (3 levels deep), through type-only positions (`?Ring[Int, -1]`), and through nested generic fields.
- `-7 / 2`, `%`, and negative divisors fold the same as at run time.
- Hex, binary, octal, `_`, and `-0` literals all work.
- Local-constant sizes are rejected when the source is reassigned, `!`-borrowed, or captured later, and for loop variables, lambda parameters, and shadowed (`new k = …`) names.

**Recursion and ownership**
- `f[n]` calls `f[n]`, `g`/`h` mutual recursion, and inferred self-recursion all give correct results.
- Deeper nesting through `[x; 2]` is rejected cleanly.
- `total[T, n](r: ?Ring[T, n])` is inferred.
- Moving (`<`), passing through generics, and dropping (`-`) Rings with Vec and `*T` fields.
- Cloning a Ring with drop glue is rejected.

**Fill literal**
- A side-effecting element is evaluated exactly once (`[tick(!c); 4]` gives `c == 1`).
- A fallible element `[mayfail(ok)!; n]` propagates and catches correctly.
- Borrow and resource elements are rejected.
- Nested `[[x; 2]; 2]` works, including with `Int?` coercion.
- Coercions: Int literal to Float, a value to `T?`, a struct to `P?`.
- `[x; n]` in closures that name `n` without capturing it.
- A fill as a module constant (`Z =! [1; N]`), across modules via `lib.Z`, `[4; lib.N + 1]`, and `lib.count[lib.N * 2]`.
- A fill as a default field value is rejected, consistent with other non-literal defaults.

**Modules and names**
- The `pub` sizing check covers:
  - pub methods of pub structs
  - forwarding through methods and generic types
- Generic types cannot cross modules, so no hole opens there.
- Value params named `rig`, `std`, `panic`, `u8`, `i64`, `usize`, or `items` emit valid Zig.
- Collisions with methods, locals, module declarations, and types are rejected.
- `k =! n` aliases of both function and struct value params work in types, fills, and compile-time arguments.
