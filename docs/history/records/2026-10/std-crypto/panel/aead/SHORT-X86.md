# Short ChaCha20-Poly1305 on x86-64: the ceiling study

Messages of 64, 128 and 192 bytes, sealed and opened in place, on pup
(Core Ultra 9 185H). Zig 0.17.0, `-OReleaseFast -mcpu=native`. Written
from RFC 8439 and measurement only.

All numbers below are from E-core 19 (Crestmont), the only core this
study timed on. They rank variants against each other on that core and
cannot be compared with P-core numbers: see "E-core is not P-core".
`run-x86-short.sh` times the candidates on P-core 6.

## Files

- `zig/short.zig`: the variants (seal and open, in place or out of place; above 192 bytes it calls `ceiling.zig`)
- `zig/variants.zig`: the named configurations
- `zig/cshort.zig`: the correctness check
- `zig/bshort.zig`: the timer (bench.zig's method and line format, sizes 64/128/192, key, nonce and length read at run time)
- `zig/dshort.zig`: dudect on x86 (rdtsc, both classes on the same buffers)
- `build-x86-short.sh`: builds and checks them on pup's E-cores
- `run-x86-short.sh`: ring, the ceiling, std.crypto and the candidates, interleaved on core 6 (`CORE=` overrides, `R` rounds, default 100)

## E-core 19, ns (fastest of 8 interleaved rounds; load 2.5, clock 3.78 GHz)

| size | ring | ceiling | std.crypto | rows | split |
|---|---|---|---|---|---|
| 64 seal | 239 | 209 | 213 | **130** | 133 |
| 64 open | 241 | 204 | 215 | 131 | **127** |
| 128 seal | 266 | 232 | 237 | 198 | **176** |
| 128 open | 265 | 226 | 238 | 184 | **166** |
| 192 seal | 292 | 258 | 260 | 265 | **231** |
| 192 open | 293 | 250 | 261 | 251 | **217** |

On this core ring is slower than the ceiling, the reverse of P-core 6.
That alone shows the cores rank code differently.

## The designs

**rows.** Blocks are kept as rows: a register holds four words of one
row, and a 256-bit register holds the same row of two blocks, one per
128-bit half. Set 0 is block 0 (the Poly1305 key) and block 1, which is
all 64 bytes need. Above 64 bytes a second set holds block 2 (an xmm set,
up to 128 bytes) or blocks 2 and 3 (a ymm set). Each half round is one
`qr` on whole rows; `vpshufd` then turns the rows into diagonals.

- **b stays put.** b is the last word a quarter round makes and the
  first one the next needs. So rows a, c and d turn (by 3, 1, 2, then
  back) and b does not. Each turn then has 3 to 6 cycles of slack, and the
  chain is 14 cycles a half round (rot12 and rot7 are a shift pair and an
  or, 2 cycles).
- **Rotations.** By 16 and 8 they are `vpshufb`.
- **Setup.** The input comes straight from memory: `vbroadcasti128` of
  the key halves and a nonce row, with no 16-word state array.
- **Keystream.** Block 1's keystream is the high halves, combined by
  `vperm2i128`. Block 0's low halves give r and s through
  `vmovq`/`vpextrq`.
- **Pins.** Two sets are tied by an empty `asm volatile` on each set's b
  after every half round. Without that LLVM emits one set's ten double
  rounds after the other's: unpinned 128 B was 240/203 ns, pinned 198/184.

**split.** Block 0 runs in general registers, one `u32` per word, beside
the rows: block 1 as an xmm set at 64 B; 1 and 2 as a ymm set at 128 B;
the ymm set plus block 3 as an xmm set at 192 B. Each vector double round
is pinned to a scalar one, and the two vector sets are pinned as in rows.
On Crestmont the integer ALUs and the vector ports are separate, so the
scalar block costs almost nothing. On Redwood Cove they share ports 0, 1
and 5, so split may lose there.

**MAC (both).** Poly1305 on 64-bit limbs: 4 `mulx` and 2 `imul` a block,
fully unrolled for whole messages (`n == 64*M`), its key read from the
rows. The final reduction is branch-free (masks). Open MACs `src` before
the xor writes `dst`.

## Where the time goes (rows, E-core, 64 B seal, loaded run)

Measured by probes (`r0`: no double rounds; `nomac`; `r0nomac`):

| part | ns |
|---|---|
| total | 150 |
| ChaCha20 | 113 |
| Poly1305 | 31 |
| everything else | 6 |

"Everything else" is about 4%: the prologue, length dispatch, setup,
keystream extraction, xor, final and tag. It costs:

- **Key wipe** (`secureZero` of the Poly1305 key and state): nothing
  measurable (`rowsw`).
- **DIT:** x86 has no user-mode DIT bit. Intel's DOITM is a kernel MSR.
- **Unrolled MAC loop against `blocksN`:** within noise.

## What lost (E-core)

| variant | 64 B | 128 B | 192 B | against |
|---|---|---|---|---|
| ceiling (4 lanes, xmm) | 209/204 | 232/226 | 258/250 | |
| two scalar blocks (`scalar`) | 229/217 | (rows) | (rows) | 1.76x rows at 64 |
| rows, 2+3 as a ymm set at 128 (`rowsy`) | = | 238/222 | 263/245 | 20% slower than rows at 128 |
| rows unpinned | = | 240/203 | 292/254 | 21%/10% slower at 128 |
| rows, Poly1305 on 44-bit limbs, 4 blocks a step | = | 267/258 | 339/330 | 35%/40% slower than rows; mul-bound |
| split, open's MAC started early (`splite`) | 134/131 | 176/169 | 233/227 | = split; latency only, E-core can't see it |
| rows, b turned (`rowsb`) | 139/131 | 196/183 | 259/253 | = rows here; latency only |
| rows at 192 against the ceiling | | | 265/251 | 3% slower; Crestmont splits each 256-bit op in two, and 4 lane blocks need fewer shuffles |

`rowsb` and `splite` cut latency, not work. The E-core is
throughput-bound: it has no uop cache, and it splits 256-bit ops. So it
can't show their gain, if there is one. P-core 6 should show it.

## E-core is not P-core

On Crestmont:

- each ymm op is two uops;
- straight-line code is decode-bound, with no DSB;
- integer and vector ports are separate.

On Redwood Cove:

- ymm is one uop;
- straight-line code runs from the uop cache, 6 wide;
- integer and vector share ports 0, 1 and 5;
- the ROB is 512, so successive calls overlap.

Expected on P-core:

- **rows:** one ymm set is 380 vector uops for blocks 0 and 1. The lanes
  layout spends 1280 uops on blocks 0 to 3.
- **Latency:** about 280 cycles of ChaCha plus 5 × ~14 cycles of MAC at
  64 B.
- **split:** may lose to port contention.
- **rowsb and splite:** may win.

Code placement alone moved identical code by 10% on E-core (rows 64 open:
135 in one build, 121 in another). Treat P-core gaps under ~3% as noise.

## Constant time

Every branch and index depends only on lengths and pointers. The
rotations are fixed shuffles, with no lookups.

dudect results (`dshort`, 100k measurements of 8 calls, E-core):

- rows and split: key (zero vs random) and text (zeros vs random) give
  |t| ≤ 2.4. Tag (wrong in byte 0 vs byte 15) gives |t| ≤ 2.3.
- The control (right vs wrong tag) gives |t| up to 160, so the test sees
  real differences.

**A leak found in the current ceiling on x86.** LLVM compiles
`(t0 ^ w0) | (t1 ^ w1) != 0` into two compares and two branches, so
whether the first eight bytes of a forged tag were right shows in the
time.

- The ceiling's dudect tag test gives t(p90) = −73, −163 and −69 at 64,
  128 and 192 B.
- short.zig puts the or through an empty `asm volatile ("" : "+r" (d))`
  before its one test, and gives |t| < 2.5.
- The ceiling, and Rig's emitted std.crypto, need the same barrier. The
  Rig binary was not dudect-tested here.

The harness also needed both classes on the same buffer. A second buffer
16 bytes off a cache line showed t ≈ 100–300 in every test.

## Correctness

`cshort` (ReleaseSafe and ReleaseFast) checks every variant:

- RFC 8439 §2.4.2 (the ciphertext) and §2.8.2 (seal, tag, open);
- every length 0–2100 against Zig std, with AAD lengths 0, 1, 13, 16,
  33 and 80;
- both in place and out of place;
- a forged tag (one bit, a different byte each length) and a flipped
  ciphertext byte each fail, with `dst` all zeros, in place and out of
  place.

The ceiling's own `zig test` covers §2.3.2 and §2.5.2 for the shared
Poly1305.

## What Rig would need

Compared with REPORT.md's "Gaps".

Rig has today: `Simd[U32, 8]` and `Simd[U32, 4]` with lane-wise
`+% ^ << >>`, compile-time parameters, inline functions, U128 wide
multiply (mulx), and lane reads `x[i][b]`.

It lacks:

1. **Lane shuffles (gap 4).** Rows need:
   - per-half word rotation (`vpshufd`): `v.shuffle([1,2,3,0,5,6,7,4])`;
   - half combine: `a.shuffle(b, [4,5,6,7,12,13,14,15])`;
   - 128→256 broadcast.

   This is the one gap rows cannot do without. Built lane by lane, LLVM
   would have to rediscover each shuffle.
2. **Byte shuffle rotations (gap 3):** `v.rotl(16)` and `v.rotl(8)`
   lowered to `vpshufb`. Loading 32 or 16 bytes as `Simd[U32,8]` or
   `[4]` (`from_bytes`), and storing them back.
3. **The scheduling pin (gap 2),** now in two places:
   - tying two row sets (17% at 128 B);
   - tying split's scalar and vector rounds.
4. **Compile-time loops (gap 1):** the 10 unrolled double rounds, and
   one specialization per M = 1, 2, 3.
5. **Proofs (gap 5):** whole-block xors at `64*b` once `64*(b+1) <= n`
   is tested.
6. **New: a constant-time equality,** `crypto.same(tag, t)` or a value
   barrier, lowered to the or plus the empty asm. Without it the
   optimizer splits the test into branches. This is gap 7's
   "constant-time compare", now shown to be needed on x86.
7. **New: a compile-time test of the target,** so std.crypto picks rows
   on x86 and lanes on arm64.

## Untested ideas

- Poly1305 two-way with r²: it saves about 50 cycles of chain at 192 B,
  but doubles the multiplies. It needs P-core to judge.
- Taking seal's MAC words from registers rather than store-forwarding:
  a few cycles.

## Core 6 result (pup, 2026-10-31 13:38, 50 rounds, run-x86-short.sh)

# x86_64  Intel(R) Core(TM) Ultra 9 185H, core 6, 50 rounds; load average: 3.75, 3.78, 4.92
# clock 4.477 GHz (dependent-add chain)
# clock 4.575 GHz (dependent-add chain)

seal (ns)
| size | ring | ceiling | stdcrypto | lanes4 | rows | split | splite |
|---|---|---|---|---|---|---|---|
| 64 | 126 | 142 | 146 | 144 | 81 | 109 | 109 |
| 128 | 140 | 156 | 160 | 157 | 114 | 127 | 128 |
| 192 | 155 | 169 | 174 | 170 | 128 | 153 | 154 |

open (ns)
| size | ring | ceiling | stdcrypto | lanes4 | rows | split | splite |
|---|---|---|---|---|---|---|---|
| 64 | 127 | 133 | 145 | 137 | 74 | 99 | 104 |
| 128 | 142 | 150 | 163 | 151 | 105 | 115 | 118 |
| 192 | 157 | 158 | 176 | 163 | 121 | 142 | 145 |

rows wins at every size on the P-core: at 64 B it seals in 81 ns and opens in 74, against ring's 126 and 127.
