# Byte equality benchmark

Times the runtime's `bytesEql` (`src/runtime.zig`), the equality of
text, string patterns, and the built-in tables' text keys, against
`std.mem.eql(u8, …)`, which it replaces.

```sh
zig build-exe -O ReleaseFast --dep runtime -Mroot=bench/eql/eql.zig -Mruntime=src/runtime.zig -femit-bin=/tmp/eql
/tmp/eql check     # bytesEql agrees with std.mem.eql at every length to 300, alignment, and difference
tools/low /tmp/eql # the table below
```

Each row is one length; each round compares 4096 pairs of it at
varied offsets, so the loop knows neither the pointers nor the length.
`eq` pairs are equal, `ne` pairs differ in their first byte. The
numbers are nanoseconds per compare, the fastest of 15 interleaved
rounds, and `rig/std` their ratio.

## Why it is not `std.mem.eql`

`std.mem.eql` reads its words and vectors by an array `@bitCast`,
which Zig 0.17 lowers byte by byte (ZIG-0.17.md, §5.3) and LLVM folds
back into one load only where it optimizes for speed. In code a
`--pgo` profile finds cold, LLVM optimizes for size and the fold does
not happen: on Trig, `std.mem.eql`'s 32-byte step ran byte by byte
through the stack. `bytesEql` reads each word and vector by one
unaligned pointer load, which is a load whatever the optimizer does,
and tests a vector for a nonzero byte by a compare and a mask
(`vpmovmskb`, `vptest`, `umaxv`), not a reduction by `or`, which folds
the bytes one by one.

## Results

Apple M-series (aarch64), ReleaseFast, `rig/std`:

| Length | eq | ne |
|---|---|---|
| 1-3 | 0.95 | 0.95 |
| 4-16 | 0.89-0.90 | 0.89-0.90 |
| 17-32 | 0.80 | 0.88-0.96 |
| 33-64 | 0.49-0.87 | 0.80-0.87 |
| 65-128 | 0.65-0.87 | 0.79-0.88 |

pup (Core Ultra 9 185H, x86-64 with AVX2, `-mcpu=native`, P-core 6):

| Length | eq | ne |
|---|---|---|
| 1-3 | 0.42-0.44 | 0.42-0.44 |
| 4-16 | 0.30-0.32 | 0.30-0.32 |
| 17-32 | 0.44-0.47 | 0.44-0.47 |
| 33-64 | 0.51-0.54 | 0.29 |
| 65-128 | 0.59-0.81 | 0.33 |

On x86-64 with no more than SSE2 (`-mcpu=baseline`), which `rig
build` does not target, `bytesEql` is 20-47% faster at every length
but 17-32 bytes differing in the first, where it is 2-8% slower:
`std.mem.eql` tests 16 bytes there before the rest.
