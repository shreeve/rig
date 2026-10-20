# SIMD for Rig

Portable vectors speed up the JSON parser (`std.json`), and later any
scanner. Rig builds them as a general language feature. The design work
was written alongside the parser in the Trig project before it moved
here, and these files hold it.

| File | Contents |
|---|---|
| [simd-proposal.md](../history/simd-proposal.md) | The design: type, operations, the Core paragraph, safety, implementation plan, effort |
| [simd-lowering.md](../internals/simd-lowering.md) | What Zig 0.17's `@Vector` compiles to on aarch64, x86-64 and WASM, with pitfalls |
| [simd-opcodes.md](../history/simd-opcodes.md) | The Apple silicon opcodes for this work, and the Rig operation that reaches each |
| [simd-zig/](../history/simd-zig/) | The Zig probes and benchmarks behind both documents |

## Decisions

1. **Type:** `Simd[T, n]`, generic over the lane count. A mask is
   `Simd[Bool, n]`.
2. **Lane `+`** panics on overflow, like scalar `+`; `+%` wraps.
3. **`v == w`** returns a lane mask. `if mask` is rejected with a hint to
   use `.any()` or `.all()`.
4. **Ownership:** vectors are plain data and do not touch it.
5. **Byte lookup** comes in round 2, with an out-of-range index giving 0.
   Round 1 uses comparisons only.

Before SIMD, Rig builds the bit intrinsics (`x.trailing_zeros()`,
`x.leading_zeros()`, `x.count_ones()`) and the wrapping shift `<<%`,
which both SWAR and SIMD code need.

## What the measurements said

Apple M5, Zig 0.17. Details in [simd-lowering.md](../internals/simd-lowering.md) and the
  [JSON results](../history/json-results.md).

- **SIMD beats SWAR here.** A full 64-byte bit mask costs 0.8 ns with
  NEON's pairwise-add reduction, 1.2 ns with a plain `@bitCast`, and 2.7
  ns with U64 SWAR. Even 16-byte steps beat SWAR on Apple and x86 cores.
- **Two block sizes.** Searches (string ends, whitespace) end within 16
  bytes most of the time, so they take one 16-byte step first; bulk work
  and long strings use 64-byte blocks (gsoc +39% with 16 then 64). Hence
  one generic type, not fixed names.
- **`bits()` needs a per-target lowering:** NEON's `addp` reduction or
  `shrn` nibble mask, x86's single `@bitCast`, WASM's four 16-lane
  bitmasks (a 64-lane cast scalarizes to 511 instructions there).
- **Comparisons are enough to start.** A compare-only classifier runs at
  10 GB/s; a table lookup adds 8-23%, but Zig has no portable form, so it
  needs a native lowering per target (`tbl`, `pshufb`, `i8x16.swizzle`).
- **Projected gain** for the JSON parser from vectors alone: 1.09x
  (canada) to 1.55x (twitter). The rest of the gap to sonic-rs is the
  runtime and compiler fixes recorded in
  [json-results.md](../history/json-results.md).

## Wanted

- **A widening conversion and a typed vector store.** std.terminal
  writes a run of printable bytes into U64 cells, each byte or'd with
  the style bits. As a Rig loop, with its checks proven away, LLVM keeps
  it scalar: a load, an or, and a store a cell. Widened sixteen lanes at
  a time (`uxtl`/`ushll` on ARM, `pmovzx` on x86) the text corpus of
  bench/terminal runs 35% faster. Rig needs `Simd[U8, 16]` to
  `Simd[U64, 16]` and a store of a vector into a `![]U64`; until then
  std/terminal.zig's `widen` does it in Zig.

## Lessons from other languages

From a survey of Rust, C#, Swift, Mojo, Java, Go, C++26, Highway, Odin,
Julia and WASM:

- Rust's `std::simd` has been nightly for years, stalled on lane-count
  bounds, mask types and dynamic shuffles. Decide those up front.
- Mask-to-bitmask is the operation most APIs regret leaving out (Swift,
  Go's portable layer). It is expensive on ARM, so .NET also offers
  `any`, `count` and first-index queries that lower better there.
- The 16-entry byte lookup is "the single most important op" (Highway).
  Its out-of-range rule differs everywhere; zero is native on ARM and
  WASM and cheap on x86.
- Lane `+` wraps silently in Rust, .NET and Go; Swift refuses `+` and
  requires `&+`. Rig keeps its scalar rule instead.
- Generic abstractions that the optimizer must see through caused 10-100x
  slowdowns in Swift and boxing in Java. Rig emits `@Vector` directly.
