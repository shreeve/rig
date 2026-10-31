# std.crypto (2026-10-31)

The standard library's cryptography, built for the sanstun port (Firezone's
WireGuard) from the code of the sanstun panel (2026-10-30), whose reports
are outside the repository in
`~/Data/Code/Claude/rig/rig/rust-ports/sanstun/panel/` (SUMMARY.md,
aead/REPORT.md, curve-hash/REPORT.md). The owner's words: "I'd want it in
pure Rig (this will be difficult) but also this rig should be in std.crypto
-- so, I'd like it to be usable from other Rig code, but be part of our
std.crypto which is Rig's stdlib". He approved the panel's defaults on
2026-10-30: Rig with one small Zig shim, the names below, and constant
time with DIT around X25519. PR #800.

## Design

**Layout.** `std/crypto/` is the directory module `crypto`, and two
modules sit under it: `std/crypto/x25519/` (`use std.crypto.x25519`, named
`x25519`) and `std/crypto/blake2s/` (`use std.crypto.blake2s`, named
`blake2s`). A module is not a member of another, so the approved
`crypto.x25519.Secret` is written `x25519.Secret` after
`use std.crypto.x25519`; the import path keeps the `crypto`. All three bind
`std/crypto.zig`, each to the functions it needs, so DIT and the barrier
are not public API.

| Module | Members |
|---|---|
| `crypto` (aead.rig, ct.rig) | `ChaCha(key)`, `XChaCha(key)`: `seal`, `open`, `seal_into`, `open_into`; `Forged.tag`; `wipe`, `equal` |
| `x25519` (x25519.rig, field.rig, table.rig) | `Secret(key)`, `Secret.new()`, `s.public()`, `s.share(peer)!`; `KeyError.low_order` |
| `blake2s` (blake2s.rig) | `hash`, `mac[n]`, `Hasher()` with `add` and `done`, `hmac`, `Hmac.of(key).mac(data)` |

**The shim**, std/crypto.zig, is what Rig cannot say:

- `dit_on() -> U64` and `dit_restore(old)`: set PSTATE.DIT, by its system
  register's number (S3_3_C4_C2_5, which every assembler takes), and put it
  back. A no-op off aarch64. On aarch64 the target's features decide at
  compile time when they include FEAT_DIT (every Apple core); on Linux
  otherwise the kernel's `AT_HWCAP` is asked once, so a core without DIT
  (Cortex-A72, Neoverse N1) never executes the instruction.
- `wipe(![]U8)` and `wipe_words(![]U32)`: `std.crypto.secureZero`, volatile
  stores the optimizer keeps.
- `barrier(U64) -> U64`: an empty `asm volatile` with the value as an
  in-out register, so LLVM cannot see that a mask is 0 or all ones and
  turn it back into a branch.
- `entropy(![]U8)`: the operating system's `randomSecure`, for
  `Secret.new`; it panics when the system has none.

**Key objects.** `ChaCha`, `XChaCha`, `x25519.Secret`, and `blake2s.Hmac`
have a `drop` body that wipes the key or the key-derived states. A type
with a `drop` body is owning, so it moves and is never copied (SPEC,
"Kinds of value"). The key field is `pub key: [32]U8`: positional
construction from another module, `crypto.ChaCha(key)`, needs every field
`pub`, and `pub ?key` (read-only) does not allow it. Copies the arithmetic
leaves in registers and on the stack (the ChaCha state words, the clamped
scalar's limbs) are not wiped, as Rust's `zeroize` does not; the clamped
scalar, the comb's key bytes, the XChaCha subkey and the partial block's
keystream are wiped where Rig holds them.

**Parameters.** Nonces, tags, and peers are taken by value (`[12]U8`,
`[16]U8`, `[32]U8`): a `?[32]U8` parameter cannot take a call's result
(`s.share(t.public())`), and a copy of 32 bytes costs nothing measurable.

**The out-of-place pair** is named `seal_into` and `open_into`, the names
the sanstun port's stand-in uses (compare/rig/sanstun/sanstun/stand.rig),
with its argument order, `(!dst, src, nonce, header)`. `seal_into` writes
`src`, then zeros up to 16 bytes from the end of `dst` (WireGuard's
padding), encrypted, and the tag in the last 16; `open_into` reads a
message and its tag from `src`. When `src` fills the message, the cipher
reads `src` and writes `dst` in one pass, with Poly1305 in the same loop:
each function of the AEAD takes a compile-time `ip`, true in place, false
from `src` into `dst`. A padded `seal_into` copies `src` and seals in
place.

**The table.** The comb's table (32 rows of 8 entries of three field
elements, padded to 128 bytes each, 32 KiB) is a module constant,
`std/crypto/x25519/table.rig`, written by `tools/x25519-table.zig` from
Zig's `std.crypto.ecc.Edwards25519`. It is byte for byte the panel's
`base_table.rig` (BASE16), made by its own generator. Computing it at
compile time in Rig would need 256 inversions in the checker; a constant
is what the panel measured.

**Wrapping arithmetic.** Every operation on secret limbs that cannot
overflow is written wrapping (`+%`, `*%`, `-%`), so `--release` carries no
overflow checks on them: the panel counted 167 never-taken checks in the
comb, each a branch on a secret, and 1% to 5% of its time. The bounds are
argued in field.rig's header. Lengths, indexes, and counters stay checked.

**Carries.** Poly1305's 64-bit carries in the block loop are compares,
`c0: U64 = 1 if a0 < m0 else 0`, as the panel wrote them; LLVM makes them
`cmp`/`cset` (`setb` on x86), which the panel checked in the disassembly.
Written as a wide add, `U128(a) +% U128(b)` with the high word the carry,
they were a branch-free construction by design, but 5% to 13% slower on
messages of 64 to 192 bytes (measured, below), so the wide add is kept
only where a carry is taken once (the final additions of the pad).

## Constant time, primitive by primitive

| Primitive | Why it is constant time | DIT |
|---|---|---|
| ChaCha20 | adds, xors, and rotations of 32-bit words, in vectors; no table, no branch on data; the keystream's lanes are picked by compile-time indexes | not set |
| Poly1305 | 44-bit limbs multiplied as U128 (`mul`/`umulh`), carries by shifts and masks; the final reduction keeps `h` or `h - p` by a mask through the barrier; 64-bit carries by compares, which become `cset` | not set |
| The tag | compared by or-ing the xors of its two halves, through the barrier; a failed open zeroes the message with `wipe` | not set |
| X25519 ladder | five 51-bit limbs, U128 products; the swap is a mask from the scalar's bit, through the barrier; the loop runs 255 times whatever the scalar; Fermat inversion by a fixed chain | set around `share` |
| X25519 comb | signed 4-bit digits recoded by arithmetic shifts; each row's 8 entries are all read, as vectors of two limbs, and one kept by a vector mask through the barrier; negation by a mask | set around `public` |
| Low-order check | the shared secret's bytes or-ed together, through the barrier; the branch is on the result, which `share` reports anyway | (inside the DIT span's result) |
| BLAKE2s | adds, xors, and rotations of 32-bit words; message words picked by the round's fixed schedule, a compile-time index; branches test lengths only | not set |
| HMAC, keyed BLAKE2s | BLAKE2s compressions; a key longer than 64 bytes is hashed (a branch on its public length) | not set |
| `equal` | every byte xored and or-ed, whatever the first difference; the branch is on lengths and on the result | not set |

**Why DIT goes around X25519 only.** The panel's dudect runs (below)
found every X25519 on the Apple M5, dalek's included, leaking without DIT
(|t| up to 43 against a bar of 4.5) and passing with it (|t| at most 2.3);
DIT costs 0% to 1.5% there. The AEADs passed without DIT (|t| at most 3.5,
with the right-against-wrong-tag control at 361), and DIT costs 40 to 55 ns
a call, about 30% of a 64-byte seal. So std.crypto sets it per X25519
call and not per AEAD call. A form that sets DIT around a batch of AEAD
calls, as the panel suggested, is left to the owner (below): on M3 and
later DIT also turns off the data memory-dependent prefetcher that the
GoFetch attack used, which argues for DIT around any secret work.

## Numbers

Apple M5, 2026-10-31, the machine loaded 4 to 16 by other agents' work;
fastest of interleaved rounds in a shuffled order, through `tools/low`.
"panel" is the panel's Rig code built with this branch's `bin/rig`, so
the two columns differ only in the code. Within 2% is noise.

**AEAD** (ns per call, in place, empty header, 9 rounds; ring from the
same run's earlier 5 rounds, as `cmp-aead.sh` interleaves it):

| size | ring seal / open | panel fast | std fast | panel `--release` | std `--release` |
|---|---|---|---|---|---|
| 64 | 148.8 / 144.0 | 149.1 / 155.0 | 148.7 / 153.9 | 149.5 / 156.5 | 149.4 / 155.3 |
| 128 | 159.5 / 164.7 | 175.3 / 190.0 | 175.8 / 185.6 | 174.5 / 189.8 | 175.1 / 190.5 |
| 192 | 175.2 / 264.4 | 188.5 / 202.8 | 187.6 / 202.3 | 188.0 / 202.5 | 188.4 / 202.7 |
| 1280 | 700.6 / 711.9 | 750.9 / 658.7 | 749.2 / 661.0 | 750.1 / 656.7 | 748.4 / 655.2 |
| 1400 | 726.8 / 869.5 | 837.1 / 743.5 | 835.8 / 742.5 | 833.6 / 739.3 | 836.4 / 740.9 |
| 8192 | 3739.1 / 3852.4 | 3259.5 / 3214.0 | 3259.0 / 3232.3 | 3266.4 / 3189.1 | 3258.5 / 3160.5 |

std.crypto's AEAD is the panel's speed in both modes (every cell within
2%). Against ring it is 13% to 16% faster at 8192 bytes (seal and open), 7% to
24% faster on open from 192 to 1400 bytes, even at 64 bytes, and 7% to 15%
slower on seal at 128 to 1400 bytes and on open at 64 and 128: the gaps
the panel traced to the held SIMD item (compile-time loops, a scheduling
pin, lane rotates and shuffles). The panel's Zig ceiling beats ring
everywhere, so that item is where the rest is.

Before the carries went back to compares, std was 5% to 8% slower on seal
and 8% to 13% slower on open at 64 to 192 bytes (157.5 / 167.4 ns at 64,
203.9 / 230.2 at 192); a build with the compares alone, the barrier kept,
gave the panel's numbers, and one without the partial block's wipe
changed nothing.

**X25519 and BLAKE2s** (9 rounds; `rust` is dalek 2 and blake2 0.10, the
panel's harness; `+dit` runs with DIT set for the whole process; "panel"
has no DIT, "panel+dit" is the panel's own build with it; std sets DIT
around each X25519 call):

| case | rust | rust+dit | panel | panel+dit | std | panel `--release` | std `--release` |
|---|---:|---:|---:|---:|---:|---:|---:|
| public key | 7.41 µs | 7.53 µs | 5.39 µs | 5.42 µs | 5.49 µs | 5.60 µs | 5.61 µs |
| shared secret | 20.04 µs | 20.09 µs | 15.44 µs | 15.41 µs | 15.39 µs | 15.76 µs | 15.57 µs |
| hash, 32 B | 78.8 ns | 80.0 ns | 71.7 ns | 73.2 ns | 70.7 ns | 73.1 ns | 71.9 ns |
| hash, 64 B | 80.2 ns | 83.6 ns | 71.3 ns | 71.1 ns | 71.8 ns | 78.9 ns | 78.8 ns |
| hash, 128 B | 147.6 ns | 151.2 ns | 143.6 ns | 144.0 ns | 144.0 ns | 147.3 ns | 148.5 ns |
| hmac, 16 B | 301.7 ns | 301.9 ns | 287.8 ns | 289.9 ns | 292.2 ns | 295.5 ns | 303.3 ns |
| hmac, 32 B | 304.0 ns | 300.8 ns | 293.0 ns | 293.0 ns | 294.1 ns | 299.2 ns | 303.1 ns |
| Hmac reused, 32 B | - | - | 146.7 ns | 146.4 ns | 140.9 ns | 147.4 ns | 149.6 ns |
| mac[16], 128 B | 230.5 ns | 230.1 ns | 220.5 ns | 217.3 ns | 219.1 ns | 224.9 ns | 226.9 ns |
| mac[16], 1024 B | 1.28 µs | 1.29 µs | 1.25 µs | 1.25 µs | 1.23 µs | 1.30 µs | 1.29 µs |

std is the panel's speed (within 2% of panel+dit in the fast build; the
public key's 1.3% includes making the `Secret` and wiping it; hmac in the
safe build is 3% slower than the panel's, at the edge of this run's
noise). Against Rust with DIT, as each must run to be constant time on
this core: the public key 1.37x as fast as dalek, the shared secret 1.31x,
BLAKE2s 5% to 14% faster than blake2, HMAC 2% to 3% faster, keyed BLAKE2s
5% faster, and a reused Hmac 2.1x as fast as an HMAC.

**Not measured:** `seal_into` and `open_into` (the same fused loop,
reading `src`), XChaCha (one HChaCha20 more, about 64 ns), and x86, which
the coordinator runs on pup.

## dudect

A Welch t-test over 200,000 calls (the first 10% dropped) on fixed (all
zero) against random secrets in a random order, at the median and the
50th to 99th percentiles; |t| above 4.5 is a leak. The panel's harness and
`ct/ttest.py`.

The panel's (2026-10-30, ct/results.txt there), X25519 by implementation:

| | without DIT | with DIT |
|---|---|---|
| dalek, shared secret | 43.4, 38.6 (leaks) | 1.2, 2.3 |
| dalek, public key | 6.9, 10.5 (leaks) | 1.8, 0.7 |
| Zig ceiling, shared secret | 6.3, 10.5 (leaks) | 1.4, 1.4 |
| Zig ceiling, public key | 18.9, 28.9 (leaks) | 1.1, 1.1 |
| panel Rig, shared secret | 3.4, 3.7 | 0.6, 1.6 |
| panel Rig, public key | 8.6, 3.3 (leaks) | 1.1, 1.9 |

The test's own checks: fixed against fixed 1.2, random against random 1.1,
and a ladder that swaps by a branch 85. The panel's AEADs, without DIT:
key zero against random, 64 and 1280 bytes, 0.14 and 0.82 (Rig); a wrong
tag in byte 0 against byte 15, 0.40 and 2.11; the right-against-wrong-tag
control 1.2 and 58 (it sees a real difference).

std.crypto's, rerun 2026-10-31 (two seeds each, DIT as std sets it):

| operation | seed 1 | seed 2 |
|---|---|---|
| `Secret.share` | 0.91 | 0.90 |
| `Secret.public` | 2.11 | 1.26 |
| `blake2s.hmac`, 32 bytes, key fixed against random | 1.87 | 1.28 |
| `ChaCha.seal`, 1280 bytes, key fixed against random | 0.71 | 2.07 |

All pass.

## Rig gaps worked around

1. **A slice parameter cannot default to empty.** `header: []U8 = []` is
   rejected ("a default parameter value must be a literal, a module
   constant, or a number type's limit"), and so is a module constant's
   lend. Every seal and open takes its header; a caller with none writes
   `nob: [0]U8 = []` (an empty literal needs its type).
2. **`[32]U8!KeyError` parses as `[32](U8!KeyError)`** and is rejected; the
   result is written `([32]U8)!KeyError`.
3. **A call's result cannot be lent to a `?[32]U8` parameter**
   (`s.share(t.public())`), so nonces, tags, and peers are taken by value.
4. **Positional construction from another module needs every field `pub`**,
   and `pub ?key` does not count, so `crypto.ChaCha(key)` makes the key a
   `pub` field anyone can read or write.
5. **A module is not a member of another**: `crypto.x25519.Secret` is
   `x25519.Secret` after `use std.crypto.x25519`.
6. **A `<@` method cannot write self's fields**, so `Hasher.done` copies
   its state into locals.
7. **The held SIMD item** (compile-time loops, a scheduling pin,
   `rotl`/`rotr`, lane shuffles): the AEAD keeps the panel's hand-written
   eight blocks and compile-time lane indexes.
8. **No inline assembly or DIT in Rig**: the shim, as approved.

## Open for the owner

1. `x25519.Secret.new()` draws a secret from the operating system's
   entropy; it was not among the approved names (it follows
   `random.Random.new()`). Default: keep it.
2. The key objects' `pub key` field (gap 4). Default: keep it until
   positional construction allows a private field.
3. A form that sets DIT around a batch of AEAD calls (for M3 and later,
   where DIT also turns off the prefetcher GoFetch used). Default: not now;
   decide with the sanstun port's numbers.
4. `seal_into` and `open_into`, with `(!dst, src, ...)` as the sanstun
   stand-in has them. Default: keep.
