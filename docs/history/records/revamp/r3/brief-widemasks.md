# Queued round: fast wide masks in Simd (json.rig NEEDS, 2026-10-15)

After inline2. Not blocking: std.json's two-copy reader already passes the speed rule on the Mac with today's lowering (citm 8.3% faster); this adds on top.

Need: `((v == SPACE) | (v == LF) | (v == CR) | (v == TAB)).not().bits()` on `Simd[U8, 64]`, then `trailing_zeros` on the cached U64, must run at the study's best-mask speed on both chips (r3/study-prefix-xor.md; scratchpad/clmul-shared/bench.zig has the best-mask code):
- arm64: `Simd[Bool, 64].bits()` lowers to the `addp` reduction (LLVM's plain 64-lane mask is about 85% slower).
- x86: 32- and 64-lane masks are never scalarized (the 4-5x vpextrb case in a full classifier; an empty asm barrier on each 64-bit mask fixed it in the study).
Done: json.rig's whitespace-only stage program (they provide it), timed per 64 bytes on the Mac and pup, matches the study's best mask within a few %. Plus Rig tests that the lowering is used (emit checks), and the JSON guard has no row slower.
Also check where else Rig's 32/64-lane `Simd[Bool]` code is lowered (docs/simd/ZIG-LOWERING.md).

## The program (from json.rig)
`.git/revamp/r3/json-tools/ws_stage.rig`: `rig build --release -o ws_stage ws_stage.rig`, then `ws_stage FILE N`; prints "<ps per 64 bytes> ps/64B <checksum>". citm's checksum is 499,613 × N (99,922,600 for N=200). Today on the Mac (not a quiet window): citm 2611 ps/64B, twitter 2419. The study's best mask on the Mac is about 1600-1850 ps/64B for a heavier step (quotes, escapes, prefix XOR), so the whitespace-only stage should land well under that once `bits()` lowers to `addp`.
