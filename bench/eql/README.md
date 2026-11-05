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

Apple M-series (aarch64), ReleaseFast, `rig/std` (a loaded machine,
two runs):

| Length | eq | ne |
|---|---|---|
| 1-3 | 0.94-0.97 | 0.83-0.97 |
| 4-16 | 0.82-0.92 | 0.89-0.90 |
| 17-32 | 0.80-0.81 | 0.88-0.97 |
| 33-64 | 0.49-0.84 | 0.76-0.88 |
| 65-128 | 0.54-0.88 | 0.48-0.87 |

pup (Core Ultra 9 185H, x86-64 with AVX2, `-mcpu=native`, P-core 6):

| Length | eq | ne |
|---|---|---|
| 1-3 | 0.41 | 0.41 |
| 4-16 | 0.27-0.29 | 0.27-0.30 |
| 17-32 | 0.43-0.46 | 0.43-0.45 |
| 33-64 | 0.51-0.52 | 0.30 |
| 65-128 | 0.63-0.92 | 0.35 |

On x86-64 with no more than SSE2 (`-mcpu=baseline`), which `rig
build` does not target, `bytesEql` is 13-51% faster at every length
but 17-32 bytes differing in the first, where the two are level
(0.99-1.02): `std.mem.eql` tests 16 bytes there before the rest.

## Under `--pgo`

A program whose text keys of 70 bytes are found 400 times while a
loop of arithmetic runs 100 million times, built with `rig build
--release --pgo` on pup: with `std.mem.eql`, the 32-byte step of its
cold copy moves each byte through the stack, 70 one-byte moves, each
beside a 32-byte vector stored and loaded again; with `bytesEql`, the cold
`rig.runtime.eql` is 84 instructions of 16-byte loads, `vpxor`,
`vpor`, and `vptest`, with no byte moved through the stack.
