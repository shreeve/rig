# SIMD round 1 (`simd` branch): what was built, and open questions

Design: Trig `docs/simd/` (PROPOSAL.md §5.9 round 1, README decisions).

## Built

- `Simd[T, n]` (`Type.simd`), lanes a number or `Bool`, `n` a power of two
  2..64 (constant, or a compile-time parameter checked per instance via
  `Requirement.lane_count`). Mask = `Simd[Bool, n]`. `Simd` reserved.
- Construction: `Simd[T, n].splat(x)`, `Simd[T, n](arr)`, aliases (also
  another module's, `lib.Block(...)`, `lib.Block.splat(...)`).
- Operators lane by lane: `+ - *` (checked, panic in debug and
  `--release`), `+% -% *%`, `& | ^` (ints and masks), unary `-`,
  `== != < <= > >=` (mask), compound forms; scalar/literal splat on either
  side (`splats` fact, emitted `@as(V, @splat(x))`).
- Masks: `bits()` (U64), `any()`, `all()`, `not()`, `select(a, b)`; a mask
  is not a `Bool` (condition, `and`/`or`/`not`, ternary rejected with
  hints).
- Lanes: `v[i]` (checked), `v.with(i, x)`, `v.array()`; lanes are not
  places (`v[i] = x`, `v[i] += x`, `!v[i]`, `?v[i]`, `<v[i]` rejected).
- Bytes: `read`/`write` of a `Simd` of numbers, one check, one unaligned
  load/store (`align(1)`); one-byte lanes may omit the byte order.
- `maskBits` per target: NEON addp (32/64 lanes, LLVM backend + NEON only),
  WASM simd128 16-lane pieces (>16 lanes; `any`/`all` through them too),
  WASM without SIMD a multiply gather, `@bitCast` elsewhere. Runtime test
  checks every form agrees on random masks; probe built and run under
  wasmtime (generic and generic+simd128, Debug and ReleaseSafe), and
  cross-compiled for x86_64-linux and aarch64-linux Debug/ReleaseSafe.
- CORE §1 paragraph (built) and kinds-table row; SPEC "Vectors"; SYNTAX;
  QUICK; INTERNALS "Vectors".
- Matrix `TYPES["simd"]`: 306 programs, 220 ran clean, 86 rejected, 0 failed.

## Also fixed (separate commit)

- `(?s).read[T, e](at)` on a String emitted Zig that did not compile
  (`bytes.len` on `rig.String`): an accept-means-correct bug on main.
  `emitElems` now lends a String's bytes. Test:
  `test/behavior/types/bytes_read_lent_string.rig`.

## Open questions for the owner

1. **"load with one bounds check plus a padded tail" vs. "`pad:` on reads is
   round 2".** I followed the explicit round-2 list and left `pad:` out;
   scanners in the docs and tests use a scalar tail. If round 1 was meant
   to include `pad:`, it is small (`simdReadPadded` from `proto.zig`).
2. **`v.with(i, x)` is in round 1** (§5.9 puts it in round 2) because the
   decided rejection of `v[i] = x` names it as the fix. `select` is in
   (§5.9 round 1). `sum`, `min`/`max`, conversions, shuffle, join, lookup
   are not (rejected as unknown methods).
3. **`/`, `%`, `<<`, `>>`, `<<%` on vectors are rejected** ("does not take a
   `Simd`"): not in the owner's essential list. The shifts are needed for
   round 2's nibble lookup (`v >> 4`).
4. **Lane lends and takes.** PROPOSAL §3 says `!v[i]`, `?v[i]`, `<v[i]` are
   "rejected by the rules that already reject them for any made value",
   but today `?mk()`, `!mk()`, `<mk()` are accepted. A lane is classified
   `made` in `handsOver` (`sema.isLane`), and typecheck rejects the four
   place uses explicitly (`rejectLane`). `!v[i]` would otherwise lend a
   temporary copy, so a callee's write would silently not reach `v`.
5. **"Never expose a vector's size or alignment"**: `@size`/`@align` reject
   any type holding a vector inline (`TypeInfo.vector`, `holdsVector`), and
   a generic `@size(T)` records `Requirement.sized`. PROPOSAL §1.2 had
   `@size(Simd[U8, 64])` = 64; confirm the stricter rule.
6. **WASM without SIMD, `bits()`**: the multiply gather is 851 static
   instructions for the 64-byte kernel vs. 779 for `@bitCast`, but 1.75x
   faster under wasmtime (26.6 vs. 46.6 ns per 64 B); kept the gather.
   NEON's 32-lane addp path is checked for agreement but was not timed.
7. **Lane type as a type parameter** (`Simd[T, 4]` in a generic) is
   rejected in round 1; a lane *count* parameter works.
8. **Scalar one-byte reads** (`read[U8](i)` without an order) were not
   extended; only vectors of one-byte lanes may omit the order.
9. Rig has no WASM target, and the runtime's allocator/process code does
   not build for wasm32-wasi, so the WASM probe exercises the runtime's
   vector helpers directly, not a whole Rig program.
10. The oracle now reads the receiver of bit methods and vector methods
    (it abstained on `x.not()` before), and treats `Simd[T, n].splat` as a
    static call.

No soundness question arose that the design did not answer.

## After Trig's test of c94e359c3 (JSON parser, 22 variants, 10,495/10,495 sanitizer-clean)

Fixed in this PR:

- **Ordering on a vector with a generic lane count** (`v < 0x20` in
  `fun low[n: Int](v: Simd[U8, n])`) passed `rig check` and emitted
  `rig.compare`, which Zig rejects: emit's `orderOperator` treated any
  type that mentions a compile-time parameter as a type parameter's value.
  It now decides by the operand's own type (`type_var` only). A grid,
  `test/behavior/types/simd_generic_lanes.rig`, runs every operator (two
  vectors, scalar and literal on either side, views, compound forms) and
  every method at generic `n`, plus a generic struct over `n`.
- `maskBitsNeon` builds its pieces from the mask as bytes (never
  `[n]bool`) and reads the result as one lane of a `u64` vector; on
  `apple_m1`, `bits()` of 64 lanes went from 38 to 22 instructions, and
  `any()` then `bits()` from 61 to 45. On NEON, `any`/`all` of 16 or more
  lanes reduce the bytes with `umaxv`/`uminv` (the same count alone, and
  shared with `bits()`). x86 and WASM keep their forms (measured: the
  `@reduce(.Or)` and byte-max forms compile identically there).
- Messages: a chained comparison (`v == q | v == 0x5C`) names the
  parenthesized form (in `src/rig.zig`, **which Nexus mirrors: needs a
  Nexus re-sync**); `m.trailing_zeros()` on a mask points to
  `m.bits().trailing_zeros()`; a byte read or write out of range shows
  the byte count, the offset, and the length, for scalars and vectors.

Round-2 input from Trig:

- A first-true-lane method, `m.first()` -> `Int?`, using NEON's `shrn`
  nibble mask on aarch64.
- `pad:` as a STOP byte, allowing `0 <= at <= s.len`, `at == s.len`
  included.
- `blocks(N)` from any offset, yielding the block and its offset.

## After the review of 0cba49eb1

- **Fixed (high): vectors of constants were folded by Zig.** A vector made
  from constants (`splat(1)`, `Simd[U8, 4]([250, ...])`, `splat(LIM)`, a
  `select` or `with` of them, a function returning one) was comptime-known
  in the emitted Zig, so an overflowing lane became a Zig compile error.
  Every vector construction (`splat`, `Simd[T, n](a)`, a scalar splatted
  beside a vector) is now `rig.rt(@as(V, ...))`. Complete because every
  vector value comes from a construction, a parameter, or bytes read at
  run time, and no constant or field default holds one; `with`, `select`,
  lanes, and operators take those as operands. Grid:
  `test/behavior/types/simd_fold_*` (6 constructions x `+ - *`, `-v`,
  `+=`, debug and `--release`), and the review's probes are in
  `test/corpus/review-simd-*`. `sum()` and the shifts are not in round 1
  (rejected), so they are not in the grid.
- **Consistency with scalars:** Rig's own fold rejects a constant scalar
  that overflows (`x: I8 = -128` then `x * -1`: "does not fit"), while
  sema folds no vector, so the same overflow in a lane panics when the
  program runs. Both stop before a wrong value is used; SPEC "Vectors"
  says so.
- Comment added where `maskBits` picks `@bitCast`: wrong bits on aarch64
  without NEON (Zig 0.17); Rig builds no such target.
- equiv vs. main: `emit` changed only for the new String-read test; 52
  rejected programs differ in `check` output only (the `read` messages'
  new wording, and the order of generic-instance diagnostics); all
  others differ in `pkg` only (the runtime).

## First x86 run (pup, Linux x86_64)

- **Fixed:** `simd_bytes` failed under the sanitizer on x86: reading a
  `Simd[U8, 4]` at the last 4 bytes of a 32-byte List touched the guard
  page. Loading through `*align(1) const @Vector(4, u8)` made Zig's own
  x86 Debug backend load a whole 16-byte register. `simdRead` and
  `simdWrite` now load and store exactly `n` bytes as an array and
  bitcast it; LLVM still emits one unaligned load (`ldr q`, `movdqu`).
  Commit 0ca5e289a.
- Also seen there, not from this branch: `cli/inline_grid` (900 s) and
  `cli/results_cache` (120 s) timed out under four rounds' load, and
  `pup-gates.sh` with `GATES_DELTA=1` passed the matrix an empty argument
  (`matrix.py: error: unrecognized arguments`).
