# Apple silicon opcodes for SIMD and SWAR work

The AArch64 (Apple silicon) instructions that matter for parsing,
scanning, number conversion and hashing, and how Rig reaches each one.

**Rig never exposes an opcode.** A program writes a portable Rig
operation (`m.bits()`, `x.trailing_zeros()`, `v == q`), and the compiler
lowers it to the best instruction on each target, with a scalar fallback
where a target has none. The x86-64 and WASM columns name the equivalent
the same Rig operation lowers to there.

Status: **used** (Rig emits it today, or on the `simd` branch),
**next** (worth adding), **later** (needed once Rig has hash maps),
**skip** (not worth it for this work).

## Already used, or being wired in now

| Opcode | What it does | Rig operation | x86-64 | WASM | Status |
|---|---|---|---|---|---|
| `fmov` | Moves a vector register's bits to a general register in one instruction | `m.bits()` extraction (the `simd` fix: 17 instructions became 1) | `movq` | `i64x2.extract_lane` | used |
| `cmeq`, `cmhi`, `cmhs`, `cmgt` | Lane-wise compares, giving all-ones or zero lanes | `v == x`, `v < x`, `v >= x` (`(v < 0x20) \| (v >= 0x80)` folds to one signed `cmgt`) | `pcmpeqb`, `pcmpgtb` (signed only; unsigned via `pminub`/`pmaxub`) | `i8x16.eq`, `i8x16.lt_u` | used |
| `umaxv`, `uminv` | Maximum or minimum across all lanes | `m.any()`, `m.all()` (the `simd` fix) | `pmovmskb` + test | `v128.any_true`, `i8x16.all_true` | used |
| `addp` | Pairwise add of neighbouring lanes | 64-lane `m.bits()`, by simdjson's reduction | not needed (`pmovmskb`) | not needed (`i8x16.bitmask`) | used |
| `rbit` + `clz` | Count of trailing zeros (AArch64 has no single `ctz`) | `x.trailing_zeros()` | `tzcnt` (BMI1), else `bsf` | `i64.ctz` | used |
| `clz` | Count of leading zeros | `x.leading_zeros()` (canada +16% to +38%) | `lzcnt`, else `bsr` | `i64.clz` | used |
| `mul` + `umulh` | Full 64×64 → 128-bit multiply, low and high halves | `U128` multiply, in Eisel-Lemire float conversion | `mul` (`rdx:rax`), `mulx` | emulated with 32-bit pieces | used |
| `rev` | Reverses the bytes of a register | `x.swap_bytes()`, and `.big` reads and pushes | `bswap`, `movbe` | shifts and masks | used |
| `ldp` (q registers) | Loads 32 bytes as a pair of vector registers | wide `read[U128]` and vector reads (Rig #115) | `movdqu`, `vmovdqu` | `v128.load` twice | used |
| `tbl` (1, 2, or 4 table registers) | Looks up each lane's byte in a 16-, 32-, or 64-byte table, an out-of-range index giving 0 | `t.lookup(idx)`: byte classification, UTF-8 validation, hex | `pshufb` on the index plus 0x70, saturated (`paddusb`), so bit 7 is set exactly from 16 on; one per 16-byte table piece, ORed; `vpshufb` with the table in both halves on AVX2 | `i8x16.swizzle`, one per table piece, ORed | used |
| `ext` | Joins two vectors, shifted: each lane gets the lane `k` before it | `cur.lag[k](prev)`: vector UTF-8 validation | `palignr`; `vperm2i128` + `vpalignr` for 32 bytes on AVX2 | `i8x16.shuffle` | used |
| `uqsub`, `uqadd` (`sqsub`, `sqadd` signed) | Saturating subtract and add | `-\|` and `+\|`, scalar or lane-wise: UTF-8 range checks | `psubusb`, `paddusb` | `i8x16.sub_sat_u`, `i8x16.add_sat_u` | used |
| `ushr`, `shl` (immediate) | Shifts every lane by one amount | `v >> 4`, `v <<% 4`; `v << 4` adds one compare (`cmhi` + `umaxv`) that panics if a lane loses bits | `psrlw` + `pand` (no byte shift) | `i8x16.shr_u`, `i8x16.shl` | used |

## Worth adding next

| Opcode | What it is for | Rig operation | x86-64 | WASM | Status |
|---|---|---|---|---|---|
| `shrn` #4 | The "nibble mask": narrows a 16-lane compare to a 64-bit mask with 4 bits per byte in one instruction. Then `rbit` + `clz`, shifted right 2, gives the first match. The fastest first-match search on ARM (glibc's string functions, .NET's `IndexOf`) | a mask's first true lane, such as `m.first()` returning `Int?` (requested from Rig) | `pmovmskb` + `tzcnt` | `i8x16.bitmask` + `i32.ctz` | next |
| `cnt` + `addv` | Popcount per byte, then a sum across lanes | `m.bits().count_ones()`, `x.count_ones()` | `popcnt` (scalar), `vpopcntb` (AVX-512 BITALG) | `i8x16.popcnt` | next |
| `udot` | Dot product of 4 bytes with 4 bytes, into each 32-bit lane | possibly 16-digit number parsing (SWAR already wins at 8 digits) | `vpdpbusd` (AVX-VNNI), `pmaddubsw` | `i32x4.dot_i16x8_s` (16-bit lanes) | next, if measured |
| `pmull` | Carry-less multiply | simdjson's in-string quote mask (prefix XOR). Only a two-stage parser needs it, and the JSON parser measured that one pass wins | `pclmulqdq` | none (6 shift-XORs) | skip for now |

## Beyond JSON: hashing

The checker needs hash maps and sets (NEEDS.md item 2), and string
interning hashes every identifier.

| Opcode | What it is for | Rig operation | x86-64 | WASM | Status |
|---|---|---|---|---|---|
| `crc32cx` | CRC-32C of 8 bytes in one instruction: a fast hash for interning and symbol tables | a hashing primitive that lowers to it where available | `crc32` (SSE4.2) | none (scalar hash) | later |
| `aese` + `aesmc` | One AES round, used as a strong, fast mixer (gxhash- and aHash-style hashes) | the same hashing primitive | `aesenc` (AES-NI) | none (scalar hash) | later |

## Not worth it for this work

| Feature | Why not |
|---|---|
| AMX (Apple's matrix coprocessor) | Undocumented, and built for matrix math, not parsing |
| SME (scalable matrix extension, M4 on) | Matrix and streaming work, not byte scanning |
| CSSC (native scalar `ctz`, `cnt`, `abs`, `min`, `max`; ARMv8.9) | Not clearly exposed on Apple's chips; `rbit` + `clz` costs only one more instruction |

## What to ask Rig for, in order

1. The `shrn` nibble-mask lowering, through a mask's first-true-lane
   method (`m.first()`).
2. Done in SIMD round 2: `tbl` (`t.lookup(idx)`), `ext`
   (`cur.lag[k](prev)`), the saturating `+|` and `-|`, and lane shifts.
3. Later, for hash maps: a hashing primitive that lowers to `crc32` or
   AES rounds where the target has them, and to a portable hash where it
   does not.

Each stays a portable Rig operation, with a scalar fallback on targets
that lack the instruction. The measurements behind these choices are in
[README.md](README.md) and [ZIG-LOWERING.md](ZIG-LOWERING.md).
