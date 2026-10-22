Array sizes and generic types parameterized by compile-time integers, a fill literal, and a stack-safety fix that applies to every Rig program on non-x86 targets.

## Language

- **Array sizes from compile-time values:** `fun zeros[n: Int] -> [n]Int`, `sub fill[n: Int](xs: ![n]Int)`. A size may also be a module constant, `lib.N`, or constant arithmetic: `[LIMIT * 2 + 1]U8`, `[(A + B)]Int`.
- **Inference of integer value parameters** from `[n]T` and `X[.., n]`: `sum([1, 2, 3])` infers `n = 3`, and `z: [4]Int = zeros()` takes `n` from the annotation.
- **Value parameters on generic structs:** `struct Ring[T, n: Int]` with `items: [n]T`. `Ring[Int, 2 + 2]` is the same type as `Ring[Int, 4]`. Integer parameters only in this version.
- **Fill literal `[x; n]`:** `a = [0; n]`, `buf: [256]U8 = [0; 256]`.
- **Constant expressions in type positions:** a lone name or integer is read by its slot. Anything with an operator is a value, so no named-constant workaround is needed.

## Safety

- **Stack overflow on non-x86 targets.** Zig probes the stack as a frame grows only on x86. On macOS arm64, a frame larger than the one-page guard could step over it and write into heap mappings. Before `main` runs, the program now:
  - on macOS, reserves 64 MiB of inaccessible memory below the guard;
  - on Linux without probes, holds the stack to 16 MiB;
  - stops with a message if it can't do either.
  `test/cli/stack_guard.sh` proves an overflow writes nothing.
- **Size caps:**
  - A value takes at most 8 MiB.
  - A function keeps at most 16 MiB of values on its stack, which is the size of the main stack, so a larger frame could never run.
  - Every generic instance is checked.
  - A 4 GiB array used to take minutes and 11 GB in Zig. It is now rejected at once.
- **Fixed on `main`:**
  - `for x in !out` emitted a `const` that the loop writes.
  - Indexing a zero-length array produced Zig that didn't compile.

## Review

Two independent reviewers (soundness and emit; front end, diagnostics and docs) reported findings. Every critical and high finding is fixed with a test, and most medium and low ones are fixed too. Fixes include:
- the constant-folding blowup (now folded once, in order);
- `invalid` leaking into messages;
- typed arithmetic in sizes;
- hints for Rust's `[Int; 3]`.

## Verification

- `./test/run`: 1345 passed, 0 failed, 0 known (1306 on main).
- The grammar has no conflicts.
- Source +1622/−164 (compiler, without the generated parser).
- Not verified: Linux aarch64 ran only as cross-compiled tests. The stack-limit behavior there is argued from the kernel source; CI covers x86_64 Linux and arm64 macOS.
