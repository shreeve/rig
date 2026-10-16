# Zig 0.17 `@Vector` on Rig's targets: asm summary

Zig 0.17.0, LLVM 22.1.8. Host: Apple M5.

Every number below was reproduced from the files in `zig/` beside this file (outputs and binaries not kept; rebuild with `build.sh`):

- `./build.sh` emits asm into `out/<target>/<mode>/<file>.s`.
- `./asm.py --counts <file> [mode]` prints a per-function instruction-count table.
- `./asm.py out/.../x.s fn...` prints the instructions of the named functions.
- `python3 loopbody.py` prints the instructions in the hot loop of each `bench/kernels.zig` kernel.

The targets:

| Column | Triple and CPU |
|---|---|
| a64 | `aarch64-macos`, `apple_m1` |
| a64lin | `aarch64-linux`, `generic` |
| x64v1 | `x86_64-linux`, baseline (SSE2) |
| x64v2 | `x86_64-linux`, `x86_64_v2` (SSSE3, SSE4.2) |
| x64v3 | `x86_64-linux`, `x86_64_v3` (AVX2) |
| wasm | `wasm32`, `generic` (no SIMD) |
| wasmsimd | `wasm32`, `generic+simd128` |

How to read the counts:

- Counts include `ret`, constant-pool loads and pointer loads and stores, so 4–7 instructions is "one op".
- In the Mach-O (a64) column, the last function in each file also absorbs the trailing alias lines, which inflates it (`eq_u8` 41, `red_or_bool` 28, `w_add` 21). Read a64lin for those.
- ReleaseFast lets LLVM fold identical functions together (ICF). Look for `_x = l_file.y` aliases.

## Files

| File | What it covers |
|---|---|
| `src/loads.zig` | Loads and stores; bounds checks; block loops |
| `src/lanes.zig` | Compare, logic, arithmetic, saturating ops, min and max, shifts |
| `src/bitmask.zig` | `@bitCast(@Vector(N,bool))` for N = 16/32/64; shrn and addp idioms written in portable Zig |
| `src/neon.zig` | NEON idioms through `extern fn @"llvm.aarch64.neon.*"`; the SRI chain; portable addp |
| `src/lookup.zig` | Runtime-index byte lookup: array, `@select` cascade, intrinsics (tbl, pshufb, swizzle) |
| `src/misc.zig` | Reductions, `@select`, splat, iota, `firstTrue`, `countTrues`, prefix XOR, carry-less multiply |
| `src/wide.zig`, `src/wasmwide.zig` | 64-lane vectors; bool-vector storage; where wasm scalarizes |
| `src/swar.zig` | SWAR kernels; the `u128` load pitfall |
| `src/safety_main.zig`, `probe/exact.zig` | Which vector operations ReleaseSafe and Debug check |
| `src/check.zig` | Semantics tests, run on aarch64 in Debug, ReleaseSafe and ReleaseFast, and on wasm32-wasi with and without simd128; all pass |
| `probe/lim/*.zig` | Language limits: what does and does not compile |
| `bench/kernels.zig`, `bench/main.zig` | Timing: compare+bitmask per byte, SIMD against SWAR |
| `out/bench-*.txt` | Raw timing output |

## 1. Loads and stores

`bytes[i..][0..N].*` into `@Vector(N,u8)` is one unaligned load on every target:

| Target | Instructions |
|---|---|
| NEON | `ldr q` / `ldp q,q` |
| SSE | `movdqu` |
| AVX2 | `vmovdqu ymm` |
| wasm | `v128.load p2align=0` |

A load through `*const [N]u8` is the same unaligned load, with no check.

A load through `*const @Vector(16,u8)` assumes the vector's natural alignment. On x86 it emits `movdqa`, which faults on a misaligned address. Use `*align(1) const @Vector`, which gives the same code as the array pointer.

Bounds checks in ReleaseSafe:

- Each `bytes[i..][0..N]` costs one `add; cmp; b.hi` (i + N > len) per slice expression, not per byte.
- The checks are not merged across sibling slices. `block_loop_4x16`, which slices `bytes[i+16k..][0..16]` four times, keeps four checks, even though the loop guard `i + 64 <= len` implies them all.
- Slicing once, `blk = bytes[i..][0..64]`, then taking comptime sub-slices `blk[16..32]`, leaves a single check (`block_loop_1x64`).
- The loop guard's own check is not removed either, so one redundant compare per block remains.

Vector alignment depends on the target and the CPU features:

| Target | `@alignOf(@Vector(32,u8))` | `@alignOf(@Vector(64,u8))` |
|---|---|---|
| aarch64 | 16 | 16 |
| x86 baseline | 16 | 16 |
| x86_64_v3 | 32 | 32 |
| wasm32 | 32 | 64 |

`@sizeOf(@Vector(16,u3))` is 8 on aarch64 and 16 on x86.

## 2. Lane-wise ops (16 x u8, ReleaseFast)

Instructions per op, excluding loads and stores:

| Op | a64 | x64v1 | x64v2 | x64v3 | wasmsimd | wasm (scalar) |
|---|---|---|---|---|---|---|
| `==` | 1 (cmeq) | 1 (pcmpeqb) | 1 | 1 | 1 (i8x16.eq) | ~12/lane |
| `!=` | 2 | 3 | 3 | 3 | 2 | |
| `<` (u8) | 1 (cmhi) | 4 (pmaxub, pcmpeqb, not) | 4 | 3 | 1 | |
| `<` (i8) | 1 | 1 (pcmpgtb) | 1 | 1 | 1 | |
| Range `a <= x <= z` | 3 (LLVM rewrites it as sub+cmp) | 4 | 4 | 3 | 3 | |
| `&`, `\|`, `^`, `~`, `&~` | 1 | 1 | 1 | 1 | 1 | ~11/lane |
| `+%`, `-%` | 1 | 1 | 1 | 1 | 1 | |
| `+` checked (ReleaseSafe) | +4 (cmhi, umaxv, fmov, tbnz) | +5 (pmaxub, pcmpeqb, pmovmskb, cmp, jne) | | | +11 | |
| `+\|`, `-\|` (u8, i8) | 1 (uqadd, sqadd) | 1 (paddusb) | 1 | 1 | 1 | ~17/lane |
| `*%` u16 | 1 | 1 (pmullw) | 1 | 1 | 1 | |
| `*%` u32 | 1 | 7 (no pmulld) | 1 | 1 | 1 | |
| `@min`/`@max` u8 | 1 | 1 | 1 | 1 | 1 | |
| `@min` i8 | 1 | 5 (no pminsb) | 1 | 1 | 1 | |
| `@max` u32 | 1 | 8 | 1 | 1 | 1 | |
| `>> splat(k)` u8 | 1 (ushr) | 2 (psrlw, pand) | 2 | 2 | 1 | |
| `>> splat(k)` i8 | 1 | 4 | 4 | 4 | 1 | |
| `>> splat(runtime)` | 2 | ~8 | ~6 | ~6 | 1 | |
| `>>` per-lane amounts (bytes, `@truncate` to u3) | 3 (and, neg, ushl): good | 29: ok | 17 | 13 (pblendvb ladder) | 130 (scalarized): poor | |
| `<<\|` (saturating shift) | 110 (scalarized): poor | 8 | 7 | 5 | 10 | |
| `@shlExact` (ReleaseSafe) | +4 check | +5 | | | +10 | |
| `@abs` i8 | 1 | 3 | 1 | 1 | 1 | |

Wasm without SIMD runs everything lane by lane, at roughly 6–20 instructions per lane. The results are correct (`check.zig` passes) but slow.

## 3. Compare + bitmask

| Form | a64 (NEON) | x64v1/v2 | x64v3 | wasmsimd | wasm |
|---|---|---|---|---|---|
| `bm16`: `@bitCast(@Vector(16,bool))` to u16 | cmeq, and(weights), ext, zip1, addv.8h, fmov = **6**: ok | pcmpeqb, pmovmskb = **2**: good | 2: good | i8x16.eq, i8x16.bitmask = **2**: good | 111: poor |
| `bm32` | 2 x 6 + bfi = 13: ok | 2 x 2 + shl, or = 6: good | vpcmpeqb ymm, vpmovmskb = **2**: good | **241 (scalarized)**: poor | 223 |
| `bm64` | 4 x 6 + 3 combines = 28: ok | 4 x 2 + 6 = 14: good | 2 x 2 + shl, or = 6: good | **477 (scalarized)**: poor | 451 |
| `bm64_4x16` (four 16-lane bitcasts, OR-ed together) | 28: ok | 14: good | 10: good | **34: good** | 455 |
| NEON shrn nibble (`@Vector(8,u16) >> 4`, `@truncate`, `@bitCast` u64) | cmeq, **shrn**, fmov = **3**: good | psrlw, pand, packuswb = 4: ok | vpsrlw, vpshufb = 3 | 4 | 163 |
| NEON addp (intrinsic `llvm.aarch64.neon.addp.v16i8`) | 4 cmeq, 4 and, **4 addp**, fmov = **13 per 64B**: good | n/a (LLVM crash) | n/a | n/a | n/a |
| addp in portable Zig (`@shuffle` evens `+%` odds) | alone: one `addp`. In the mask chain LLVM proves the adds disjoint, turns them into `orr`, and emits uzp1/uzp2/orr x3 = 21 per 64B: ok | 49: poor | 38: poor | 55: ok | 539 |
| SRI chain (portable `(a & hi) \| (b >> n)`) | 4 cmeq, 4 and, 3 orr, sri, shrn = 14 per 64B. The mask is **interleaved** (bit 4j+i = byte 16i+j) | | | | |
| SWAR u64 (exact zero-byte detect, multiply-compress) | ~9 per 8B, so 71 per 64B | ~100 | 70 | 150–174 | 187–217 |

The shrn nibble mask comes from plain Zig; LLVM matches it to `shrn` with no intrinsic. Use `@ctz(n) >> 2` for the first index.

`@ctz(bm16)` on NEON costs the same 6 plus `orr`, `rbit`, `clz`. `std.simd.firstTrue` is worse on every target: 20 instructions on a64 and 29 on x64v1 (`first_std`), against 14 and 6 for `@ctz` of the bitcast (`first_ctz`). `std.simd.countTrues` is folded to `@popCount` of the bitmask.

`@reduce(.Or, v == s)` (any match) costs 2–3 instructions on every SIMD target:

| Target | Instructions |
|---|---|
| NEON | umaxv, fmov |
| x86 | pmovmskb, test |
| wasm | v128.any_true |

Wasm simd128 caveat: any `@Vector(N,bool)` with N > 16 that is bitcast to an integer, or reduced (`.Or`/`.And`), is scalarized lane by lane:

| Function | wasmsimd instructions |
|---|---|
| `any32` | 239 |
| `any64` | 465 |
| `all64` | 464 |
| `bm64` | 477 |
| `w_boolstore` | 468 |

Arithmetic, compare and `@select` on 64 x u8 split cleanly (`w_add`, `w_min` and `sel64` are 28 instructions each). Only boolean vectors wider than 16 lanes break down. Keep compare results as 0x00/0xFF bytes through `@select`, or cut them into 16-lane pieces, before reducing or bitcasting (`any64_bytes`: 21; `bm64_4x16`: 34).

### Timing: compare+bitmask per 64 bytes (Apple M5)

The buffer is 32 KiB (stays in cache); each figure is the best of 9 trials. Outputs are cross-checked: identical mask hashes and identical match count and position sum.

The cpuq job queue refused an exclusive run on this machine, so other jobs may have shared it. Two runs differed by about 10%.

The wasm columns are wasmtime (Cranelift) on the same M5. A browser engine on an x86 host will differ: there `i8x16.bitmask` maps to `pmovmskb`.

Job A: write the linear u64 mask of every 64-byte block (ns per 64 B, lower is better):

| Kernel | a64 Fast | a64 Safe | wasm simd128 | wasm no-SIMD |
|---|---|---|---|---|
| simd16 (4 x bitcast u16) | 1.42–1.54 | 1.50 | 1.65 | 13.4 |
| simd32 (2 x bitcast u32) | 1.19–1.26 | 1.25 | **9.78** (scalarized) | 13.6 |
| simd64 (bitcast u64) | 1.19–1.31 | 1.25 | **9.44** (scalarized) | 13.6 |
| NEON addp (intrinsic) | **0.77–0.81** | 0.81 | n/a | n/a |
| addp in portable Zig | 1.24–1.35 | 1.28 | **1.24** | 14.0 |
| nibble (4 x shrn; 256 bits, not linear) | 0.55–0.66 | 0.60 | 0.97 | 12.0 |
| SWAR u64 | 2.68–2.94 | 2.90 | 3.65 | **3.48** |
| SWAR u128 (pointer-cast load) | 3.07 | 3.01 | 3.79 | 3.79 |
| scalar byte loop | 12.8–13.8 | 13.8 | 14.2 | 14.4 |

Job B: visit every '"' position (ns per 64 B):

| Kernel | a64, 1 match in 256 bytes | a64, 1 in 32 | a64, 1 in 8 | wasm simd128, 1 in 256 | wasm no-SIMD, 1 in 256 |
|---|---|---|---|---|---|
| simd16 bitcast, then `@ctz` loop | 2.42–2.60 | 3.48–3.78 | 7.4–8.1 | 2.93 | 9.78 |
| simd16 nibble (shrn) | 2.21–2.45 | 2.83–3.17 | 5.2–5.7 | 2.61 | 15.4 |
| simd32 bitcast | 1.80–1.84 | 2.12–2.22 | 3.9 | 11.0 | 12.1 |
| simd64 bitcast | 1.44–1.58 | 1.65–1.81 | 3.7–4.1 | 10.1 | 13.8 |
| NEON addp, 64 bytes | **0.79–0.87** | **1.29–1.38** | 3.7–4.1 | n/a | n/a |
| SWAR u64 | 3.76–4.11 | 4.10–4.71 | 8.3–8.6 | 4.97 | **5.03** |
| SWAR u128 | 3.92 | 4.15 | 7.97 | 4.12 | **4.20** |
| `std.mem.findScalarPos` loop | 1.75–1.91 | 9.6–10.5 | 36–38 | 3.08 | 17.7 |

Conclusions for M5:

- 16-byte SIMD beats SWAR u64 by about 1.9x, even with NEON's 6-instruction bitmask. The claim that 16-byte NEON loses to SWAR does not hold on Apple cores.
- 64-byte steps are about 2x faster than 16-byte steps.
- The addp intrinsic is the best linear mask on NEON.
- Narrower Arm cores (Cortex-A55/A7x, where `addv` has a long latency) were not measured.
- On wasm without SIMD, SWAR is 4x faster than `@Vector` code.

## 4. Runtime-index byte lookup (pshufb / tbl / swizzle)

Zig has no builtin for this. `@shuffle` needs a comptime mask; `v[i]` with a runtime `i` is a compile error ("vector index not comptime known"); and `std.simd` has nothing for it.

No portable spelling reaches the instruction. Indexing an array copy lane by lane (`lut_array`, `lut_vecarray`, `lut_loop`) goes through memory. On ReleaseFast these cost:

| Target | Instructions | Codegen |
|---|---|---|
| NEON | 65–73 | 16 x (`bfxil`, `ldrb`, `mov.b`) |
| x64v2/v3 | 39 | 16 x (`pextrb`, `pinsrb` from the stack) |
| wasmsimd | ~130 | |

Each spelling is poor. Without `& 15`, ReleaseSafe adds 16 bounds checks (`lut_array_unmasked`: 132 on a64).

What works:

- Intrinsics through `extern fn @"llvm.aarch64.neon.tbl1"`, `@"llvm.x86.ssse3.pshuf.b.128"` and `@"llvm.wasm.swizzle"`. Each is one instruction (`lut_intrinsic`: 7 / 6 / 9 total), and `classify_intrinsic` (the simdjson two-nibble classifier) is 13 / 12 / 15.
- Guard each with a comptime `builtin.cpu` feature test, and fall back to the array loop.
- An intrinsic for a missing feature is an **LLVM crash**, not a Zig error: `pshufb` on baseline x86 gives "Cannot select X86ISD::PSHUFB", and the aarch64 intrinsic on wasm gives "Do not know how to split".
- For a comptime table, a `@select` cascade costs about 3 instructions per non-zero entry and needs no intrinsic: 28 (a64), 24 (x64v2), 19 (x64v3), 38 (wasmsimd) for 6 entries.

Out-of-range indices differ by instruction:

| Instruction | Index 16–127 | High bit set |
|---|---|---|
| tbl | 0 | 0 |
| swizzle | 0 | 0 |
| pshufb | wraps (uses the low 4 bits) | 0 |

Rig should define index & 15, or define "≥16 gives 0" and on x86 OR the index with `(idx > 15) ? 0x80 : 0`.

## 5. Reductions (16 x u8)

| Op | a64 | x64v1 | x64v2 | x64v3 | wasmsimd |
|---|---|---|---|---|---|
| `.Or`/`.And` on bool | umaxv / uminv: 2 | pmovmskb, cmp: 2 | 2 | 2 | any_true / all_true: 1 |
| `.Add` u8 (wraps) | addv: 1 | pshufd, paddb, psadbw: 4 | 4 | 3 | ~18 |
| `.Add` widened to u16 first | uaddlp, addv: 2 | 4 | 4 | 4 | ~18 |
| `.Min`/`.Max` u8 | uminv / umaxv: 1 | 9 (shuffle tree) | 3 (phminposuw) | 2 | ~18 |
| `.Min` i8 | sminv: 1 | 25 | 5 | 4 | ~18 |
| `.Or`/`.And`/`.Xor` u8 | 7 (ext+orr, then scalar folds) | 9 | 9 | 7 | ~18 |

All are good on NEON and x86 v2+; wasmsimd is OK (shuffle-tree halving).

## 6. select, splat, iota, firstTrue, prefix XOR, clmul

- `@select`: bsl/bif on NEON (1), pblendvb on v2+ (1). SSE2 needs 3 (`pand`, `pandn`, `por`). Wasm simd uses `v128.bitselect`.
- `@splat` of a runtime value: `dup` (NEON), `movd`+`pshufb` or `vpbroadcastb` (x86), `i8x16.splat` (wasm).
- `std.simd.iota`: a comptime constant; free.
- `std.simd.firstTrue`: `@reduce(.Or)`, then `@select` against iota, then `@reduce(.Min)`. It is 1.5–5x worse than `@ctz` of the bitcast; do not use it.
- Prefix XOR as a u64 shift ladder (`m ^= m << 1, 2, 4, ..., 32`): 6 instructions on aarch64 (eor with shifted operand) and 12 on x86. Good and portable.
- `std.simd.prefixScan(.Xor, 1, @Vector(64,bool))`: 200–2200 instructions. Never use it.
- Carry-less multiply: there is no `@mulCarryless` builtin and no portable std function. `std.crypto.ghash_polyval` uses inline asm.
  - `extern fn @"llvm.aarch64.neon.pmull64"` needs `+aes`: apple_m1 has it, generic aarch64-linux does not.
  - `@"llvm.x86.pclmulqdq"` needs `+pclmul`, which no x86-64-vN level includes.
  - Through these: pmull 5 instructions, vpclmulqdq 4.
  - LLVM 22's generic `llvm.clmul.i64` exists, but is expanded to 63 shift/xor pairs (or 193 mul/and on a64), never to pmull or pclmul.
  - Conclusion: emit the shift ladder.

## 7. Wider than native

64 x u8 splits into 4 q registers on NEON, 4 xmm on SSE, 2 ymm on AVX2 and 4 v128 on wasm. Arithmetic, compare and select stay clean:

| Function | a64 | x64v1 | x64v3 | wasmsimd |
|---|---|---|---|---|
| `w_add` | 11 | 13 | 8 | 28 |

Widening 16 x u8 to 16 x u32 uses ushll/ushll2 (10 instructions), pmovzx (6 on v3) or punpck (16 on v1). Narrowing uses xtn/uzp (7).

Pitfalls of bool vectors:

- `@Vector(N,bool)` in memory is bit-packed: `@sizeOf(@Vector(16,bool))` = 2 and `@Vector(64,bool)` = 8. Storing one is a full bitmask extraction: `w_boolstore` costs 31 on a64 and 468 on wasmsimd.
- `[N]bool` takes a byte per lane, and coercion to it is cheap (`w_boolarr`: cmeq, and #1).
- `@bitCast([16]bool)` to u16 compiles: it packs logical bits, it does not reinterpret bytes.
- `@Vector(16,u3)` in memory is 48 packed bits, so loading one per-lane shift vector costs 40 instructions on a64 (`shr_lanes_u8`). Keep small-int vectors as u8 in memory.

## 8. The scalar fallback

On wasm without simd128, every vector op compiles and is correct (`check.zig` passes under wasmtime), at roughly 6–20 instructions per lane. It is no faster than a plain scalar loop (Job A: 13.4 ns/64B, against 14.4 for scalar), and 4x slower than SWAR.

x86 baseline (SSE2) is not scalar. Most ops cost 1–2 instructions. The poor ones are:

- `<` on unsigned (3)
- `@min`/`@max` on i8, u32 or i32 (5–8)
- `*%` on u32 (7)
- `.Min` reductions (9–25)
- byte lookup (no pshufb: 70)
- `@popCount` (no popcnt: 21)

Nothing failed to compile on any target, except the LLVM intrinsics described above.

Execution on x86 was not verified here: there is no Rosetta or emulator on this machine.

Zig 0.17 builds x86_64 **Debug** with its own self-hosted backend, not LLVM:

- All test files compile under it.
- `extern fn @"llvm.*"` fails to link there ("undefined symbol: llvm.x86.ssse3.pshuf.b.128").
- aarch64 Debug uses LLVM, so the same file works there.

## 9. Safety checks in ReleaseSafe (and Debug, identical)

Run with `bin/safety-ReleaseSafe <case>` and `bin/exact-*`. Every check covers every lane and costs one horizontal-reduce-and-branch per op.

| Operation | Checked? |
|---|---|
| `+`, `-`, `*`, unary `-` | per lane: "integer overflow" |
| `/`, `@rem` | division by zero, per lane |
| `@divTrunc` (minInt / -1) | integer overflow |
| `@divExact` | "exact division produced remainder" |
| `@intCast` to a narrower lane type (including to the u3 shift-amount type) | "integer does not fit" |
| `@intFromFloat` | out of range |
| `@shlExact` | "left shift overflowed bits" |
| Array index with a lane value | bounds check per lane (16 compares for 16 lanes) |
| `bytes[i..][0..N]` | one bounds check |
| `@truncate`, `+%`, `-%`, `*%`, `+\|`, `-\|`, `<<\|` | no (defined) |
| `<<` and `>>` | no: the amount type is `@Vector(N, Log2Int(T))`, so it cannot overflow. `<<` silently drops high bits |
| `@reduce(.Add/.Mul)` | no: wraps by definition, even in safe modes |
| `@bitCast` to or from `@Vector(N,bool)` | no (defined) |
| **`@shrExact`** | **NOT checked** for vectors or scalars, in Debug or ReleaseSafe (`@shrExact(3, 1)` returns 1). A Zig 0.17 safety gap |

## 10. Language limits and bugs (Zig 0.17)

These are compile errors:

| Code | Error |
|---|---|
| `if (a == b)` on vectors | "expected type 'bool', found '@Vector(4, bool)'" (`probe/lim/if_eq.zig`). Use `@reduce(.And, a == b)` |
| `and` / `or` on bool vectors | Use `&`, `\|` and `!` |
| `v[i]` with a runtime `i`, and `&v[i]` | "vector index not comptime known" |
| `for (vec)` | "type '@Vector(4, u8)' does not support field access" |
| Mixing a scalar and a vector (`v + 1`) | Use `@splat`. `@splat` needs a result type, so `v == @splat(34)` fails ("@splat must have a known result type") |
| Vectors of enums | Elements must be int, float, bool or pointer |
| Vector fields in `packed struct` and `extern struct` | |
| `>>` with u8 amounts on u8 lanes | Needs `@Vector(N,u3)` |
| `>> @splat(8)` on u8 lanes | 8 does not fit u3 |

Non-power-of-two integers (`u3`, `u24` and so on) are refused in `export` and C-ABI signatures.

These work:

- `@Vector(0, T)`.
- Odd lengths, such as `@Vector(24,u8)` bitcast to u24.
- `@Vector(N,u1)`.
- `@popCount`, `@ctz` and `@clz` per lane.
- `@intFromBool` on a vector.
- A vector parameter on an `export fn`.

Comptime evaluation of vector ops is correct for everything tested: compare, `@bitCast` to an integer, `@select`, saturating ops, shifts, `@reduce`, `@shuffle`, `@popCount`, `std.simd.firstTrue`, and bool-array bitcast (`probe/lim/comptime_ops.zig`).

Performance bugs:

- **`@bitCast([16]u8)` to u128**, and so `std.mem.readInt(u128, ...)`, is lowered **byte by byte**: 34–49 instructions on a64 and x86, even from an aligned pointer. u64 is fine (1 load). This made SWAR u128 2.7x slower until it was fixed. Use `@as(*align(1) const u128, @ptrCast(p)).*`, or go through `@Vector(16,u8)`.
- `@popCount` of a u16 returns a u5, so `@popCount(a) + @popCount(b)` overflows u5. It traps in safe modes and must be widened first.
- On wasm simd128, bool vectors wider than 16 lanes scalarize (section 3).
- `<<|` scalarizes on NEON (section 2).
- LLVM turns a portable addp chain into uzp/orr once it proves the operands disjoint (section 3).
- The `u64` from `@bitCast` of a `@Vector(64, bool)` (or 32) is still that vector to LLVM. In a classifier whose bits are then shifted with `@shlExact`, LLVM shuffled the lanes instead, and x86 without AVX-512 did it lane by lane (120 `pextrb`/`pinsrb`, or bytes through the stack on SSE2). Taking each 16- or 32-byte piece's bitmask from bytes passed through an empty `asm` (`asm ("" : [out] "=x" (-> V) : [in] "0" (v))`) keeps the bits integers, and LLVM still drops unused pieces and, on AVX2, ORs two masks' pieces before one `vpmovmskb`. An empty `asm` on the `u64` itself works too, but costs every `pmovmskb` even where only some bits are used. Rig's runtime holds the bytes (`maskBitsOpaque`).
- `~` of comparisons ORed together, then masked with lane weights for `addp`: LLVM flips each comparison (`cmeq` + `mvn`, then `bic`), a vector instruction more per 16 lanes. Flipping the `u64` after the reduction avoids it.
