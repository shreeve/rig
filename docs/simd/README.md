# SIMD for Rig

Portable vectors speed up the JSON parser (`std.json`), and later any
scanner. Rig builds them as a general language feature. This folder
holds the design work, written alongside the parser in the Trig project
before it moved here.

| File | Contents |
|---|---|
| [PROPOSAL.md](PROPOSAL.md) | The design: type, operations, the Core paragraph, safety, implementation plan, effort |
| [ZIG-LOWERING.md](ZIG-LOWERING.md) | What Zig 0.17's `@Vector` compiles to on aarch64, x86-64 and WASM, with pitfalls |
| [sketches.rig](sketches.rig) | JSON kernels written in the proposed syntax |
| [OPCODES.md](OPCODES.md) | The Apple silicon opcodes for this work, and the Rig operation that reaches each |
| [zig/](zig/) | The Zig probes and benchmarks behind both documents |

## Decisions

1. **Type:** `Simd[T, n]`, generic over the lane count. A mask is
   `Simd[Bool, n]`.
2. **Lane `+`** panics on overflow, like scalar `+`; `+%` wraps.
3. **`v == w`** returns a lane mask. `if mask` is rejected with a hint to
   use `.any()` or `.all()`.
4. **Timing:** start now, as an exception to the v0.3.0 feature freeze.
   Vectors are plain data and do not touch ownership.
5. **Byte lookup** comes in round 2, with an out-of-range index giving 0.
   Round 1 uses comparisons only.

Before SIMD, Rig builds the bit intrinsics (`x.trailing_zeros()`,
`x.leading_zeros()`, `x.count_ones()`) and the wrapping shift `<<%`,
which both SWAR and SIMD code need.

## What the measurements said

Apple M5, Zig 0.17. Details in ZIG-LOWERING.md and the JSON results.

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
  runtime and compiler fixes in docs/json/.

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
