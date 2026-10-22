# Study: the in-string mask (prefix XOR) on x86 and arm64, 2026-10-15

Owner-requested. Two expert teams, each with a stage-1 microbenchmark in Zig 0.17, timed exclusively (pup under the pup-bench lease; Mac via cpuq at load ~4), the whole step as json.rig asked (quote and backslash masks, find_escaped, prefix XOR, block carry).
Raw files: scratchpad/clmul-x86/ (stage1.zig, res/*.tsv) and scratchpad/clmul-shared/ (bench.zig, mac1.txt, mac2.txt, pup1.txt).

## Findings
- Carry-less multiply exists on both chips (pclmulqdq on x86 with `pclmul`; pmull on arm64 with `aes`). Mac: ties the 6-step shift-XOR ladder (1.58-1.85 ns/64B). pup: about 34% faster on the step (1.75 vs 2.4 ns/64B), about 0.4-0.6 ns/64B, about 1.5-4% of a parse. `pdep` subtract ties pclmul on Intel (slow on Zen 1-2). Tables and multiply tricks lose everywhere.
- 64-byte blocks beat 16-byte by 3.5-4x on both chips. On x86, AVX2 width plus vpshufb tables make stage 1 74% faster than SSE2.
- Mask extraction matters more than the multiply on the Mac: LLVM's plain 64-lane mask is about 85% slower than an `addp` reduction.
- Codegen trap (x86): in a full classifier, Zig/LLVM scalarized 32/64-lane masks (about 1,200 vpextrb), making it 4-5x slower; an empty asm barrier fixed it.
- Full x86 stage 1 at v3: 6.65 ns/64B. std.json's whole parse is 23.2, simdjson's 17.5, so a two-stage std.json needs a stage 2 at about 47% of today's whole parse. Implausible now.
- `rig build` passes no -mcpu, so it builds for the host CPU (AVX2 on pup): binaries aren't portable. Plain x86-64-v3 lacks pclmul.
- pup is Intel Core Ultra 9 185H (Meteor Lake), not AMD.

## Recommendations
1. std.json (json.rig + owner decide): no two-stage redesign now. Next is the one-pass 64-byte whitespace bitmap (sonic-rs's idea), measured earlier at 9-14% faster on pup.
2. Rig, when std.json needs it: `U64.prefix_xor()` (also U16, U32), lowering to pmull / pclmulqdq / the ladder at compile time (LLVM backend; ladder in debug, C backend and wasm).
3. Rig, likely needed by recommendation 1: a 64-lane `Simd[Bool]` `bits()` that lowers to the addp reduction on NEON, and no scalarization of 32/64-lane masks on x86 (check Rig's emitted Zig).
4. Rig: `rig build --cpu <level>` for distributable binaries (x86-64-v3 plus pclmul = haswell), and say in the docs that builds target the host CPU today.
