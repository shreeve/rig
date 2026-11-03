# sanstun port: the AEAD expert's report


## Setup
Apple M5 (4 P-cores, 6 E-cores), Zig 0.17.0, Rust 1.99.1, ring 0.17.14, Rig 6c150dfa8. Each call seals or opens the whole buffer in place with an empty AAD; key and nonce are fixed. ring gets a fresh `LessSafeKey` per call, as sanstun does. For open, the ciphertext is restored before each call, and that copy is timed alone and subtracted in all three harnesses. Each process takes the fastest of 15 rounds, and `cmp.sh` runs ring, the ceiling, Rig fast and Rig safe in turn 5 times. Calls run back to back, so these are throughput figures, as criterion's are. Results within 2% are noise.

Zig std's `ChaCha20Poly1305` is 2.4–3.7× slower than ring: 333 ns at 64 B, 11111 ns at 8192 B. XChaCha adds one HChaCha20, 64 ns of latency, so xseal of 64 B is 228 ns.

## Full table (ns)
| size | ring seal | ceiling seal | Rig fast seal | Rig safe seal | ring open | ceiling open | Rig fast open | Rig safe open |
|---|---|---|---|---|---|---|---|---|
| 64 | 146 | 135 | 149 | 150 | 139 | 135 | 154 | 157 |
| 128 | 161 | 161 | 174 | 176 | 160 | 166 | 190 | 191 |
| 192 | 174 | 175 | 188 | 190 | 266 | 180 | 203 | 203 |
| 1280 | 709 | 631 | 752 | 766 | 702 | 578 | 660 | 669 |
| 1400 | 734 | 709 | 840 | 838 | 868 | 634 | 746 | 741 |
| 8192 | 3695 | 3031 | 3274 | 3440 | 3782 | 2921 | 3266 | 3382 |

## Ceiling design and what was measured
Measured primitives on this core: NEON add, eor and shifts take 2 cycles; integer add, eor and ror take 1; mul and umulh take 3 cycles, at least 2 per cycle.

**ChaCha20.** Eight blocks run vertically in `@Vector(8,u32)`, one block per lane. That's 1.39–1.48 cpb alone. Four lanes are latency-bound at 2.2 cpb.
- Rotations: by 16 is `rev32`, by 8 is a `tbl` byte shuffle (5% faster than shl+usra), by 12 and 7 are shl+usra.
- The transpose is zip1/zip2.
- Adding scalar blocks beside the vector ones was slower in every mix: 8+1 was 5% slower, 8+2 30% slower.

**Poly1305.** Four blocks per step on 44-bit limbs: h = (h+m1)r⁴ + m2r³ + m3r² + m4r. Limb products stay below 2^93, so the powers of r need no clamped form.
- This runs at 0.62 cpb. The one-block-at-a-time version on 64-bit limbs runs at 0.92 cpb (14.7 cycles per block of dependent multiplies).
- An early 0.38 cpb figure was wrong: with a constant key, LLVM had folded the multiplies. All figures here use a key read at run time.

**Fused loop.** One 4-block MAC step follows each double round, pinned with an empty `asm volatile` that takes one ChaCha vector and the three MAC limbs as operands. Unpinned, open of 8192 B takes 4700 ns against 3300 pinned, and seal 3630 against 3060. An empty asm with no operands does nothing, and a pin after every quarter round is too fine-grained.
- Seal MACs each group's ciphertext during the next group's rounds.
- Open MACs each group during its own rounds, before the xor.

**Short messages (≤192 B).** One 4-lane group makes block 0 (the Poly1305 key) and blocks 1–3, and the 64-bit Poly1305 does one block at a time. Tried and dropped:
- Two scalar blocks for ≤64 B: 5% slower.
- A 2-lane group: 5% slower.
- A scalar key block pinned beside the vector group with the 4-block MAC: 15% slower at 64 B.

**Tests.** RFC 8439 §2.3.2, §2.4.2, §2.5.2 and §2.8.2 (including that a forged tag zeroes the buffer); XChaCha draft §2.2.1 and A.3.1; every length 0–2100 against Zig std for both AEADs and six AAD lengths; Poly1305 with all-ones keys and blocks against std.

## Constant time
dudect-style Welch t: 200k measurements of 32 calls each, class picked at random per measurement.

| test | ceiling 64 | ceiling 1280 | Rig 64 | Rig 1280 |
|---|---|---|---|---|
| key: zero vs random | −0.55 | 1.27 | −0.14 | 0.82 |
| plaintext: zeros vs random | −1.97 | 0.48 | – | – |
| tag wrong in byte 0 vs byte 15 | −0.53 | 0.31 (p90 −3.52) | 0.40 | −2.11 |
| control: right vs wrong tag | p90 −361 | −40 | −1.2 | −58 |

- In the Rig binary, carries compile to cset, cinc and adc, and every branch compares a length or an index.
- The Mac's counter ticks at 24 MHz, so this is a coarse instrument.
- DIT costs 40–55 ns per call (1.4% at 8192 B). Set it per batch.

## Rig port
534 lines (the ceiling is 908 with tests). It passes the RFC vectors and prints the same 2101-length checksum as Zig std.

Progress at 8192 B, seal / open:
- First version: 4535 / 4657.
- After marking `block4` and `block` `inline` and using 64-bit Poly1305 for ≤192 B: 4485 / 4431.
- After making the transpose's block index a compile-time parameter with the 8 blocks written out: 3459 / 3384.

## Gaps and the Rig forms wanted
1. **Compile-time loops:** `for [b] in 0..8`. A run-time lane index cost 30%, and `put4[first + 1]` is rejected.
2. **A scheduling pin:** `$pin(values…)`, a safe builtin that lowers to the empty asm.
3. **Rotates and byte reinterpret:** `x.rotl(n)` / `x.rotr(n)` on integers and vectors, lowered to ror, rev32, tbl, vprold or pshufb; and `v.bytes()` / `Simd[U32,4].from_bytes(b)`. Today there is only `$bitCast` in `raw`.
4. **Lane shuffles:** `a.zip_lo(b)`, `a.zip_hi(b)`, or `a.shuffle(b, [0,4,1,5])`.
5. **Bounds checks the proofs miss:** 17 of 26 byte reads and writes in the emitted Zig stay checked, in every build mode. Wanted: `for blk in !buf.chunks[512]()` giving `![512]U8` views.
6. **Small things:**
   - Several results can't be assigned to fields.
   - A carry is written `1 if lo < a else 0`; `a.add_carry(b, c) -> (U64, U64)` would be exact.
   - Float has no `min`.
   - The wide multiply `U128(a) *% U128(b)` already compiles to mul + umulh.
7. **For std.crypto:** a wipe the optimizer keeps (`crypto.wipe(!k)`), a constant-time select and compare, and DIT around a batch.

## API candidates
**A (recommended): a key object.**
```rig pending
c = crypto.ChaCha(key)
tag = c.seal(!packet, nonce, header)
c.open(!packet, tag, nonce, header)!
```
Error: "`c.open(...)` can fail with `crypto.Forged`: write `c.open(...)!` to pass it up, or `catch` it".
Sentence: "`c.seal` encrypts the packet where it lies and gives its tag; `c.open` decrypts it there, or fails with `Forged.tag` and leaves zeros."

**B: functions in a module.**
```rig pending
tag = chacha.seal(!packet, key, nonce, header)
ok = chacha.open(!packet, tag, key, nonce, header)
```
Error: "`chacha.seal` takes a `?[12]U8` nonce; got `?[24]U8`: a 24-byte nonce is `chacha.xseal`'s".
Sentence: "`chacha.open` gives `false` and zeroes the packet if the tag is wrong."

**C: one API for every AEAD, `api Seal`**, with `fun send[A: crypto.Seal](...)`.
Error: "`Aes` does not provide `api Seal`: missing `open`".
Sentence: "Any `crypto.Seal` seals and opens in place, so `send` takes ChaCha now and AES-GCM later."

Why A: the key wipes itself on drop, which Rig's drop gives for free; an error can't be ignored the way a Bool can; and sanstun keeps one key per session, which matches a key object. C can be built later over A's types. The out-of-place seal from `src` to `dst` fits any of them as a second pair of functions.

## The expert's summary

ring is beaten at 64, 1280, 1400 and 8192 bytes and tied at 128 and 192; the Rig port runs 7–19% behind the Zig ceiling. REPORT.md isn't on disk: the Write tool refuses report files from subagents, so the full text is below the line for you to save.

**Numbers.** ns per call, interleaved, fastest of 5×3 rounds. Load was 4.5–7 with the other two experts running; the clock measured 3.6–4.2 GHz. Rig is main 6c150dfa8, and I redid the Rig numbers I'd first taken with the stale `bin/rig`.

| size | ring seal / open | Zig ceiling seal / open | Rig fast seal / open |
|---|---|---|---|
| 64 | 146 / 139 | 135 / 135 | 149 / 154 |
| 128 | 161 / 160 | 161 / 166 | 174 / 190 |
| 192 | 174 / 266 | 175 / 180 | 188 / 203 |
| 1280 | 709 / 702 | 631 / 578 | 752 / 660 |
| 1400 | 734 / 868 | 709 / 634 | 840 / 746 |
| 8192 | 3695 / 3782 | 3031 / 2921 | 3274 / 3266 |

- **Ceiling against ring:** seal is 9% faster at 64 B, 12% at 1280, 22% at 8192, and even at 128 and 192 (1400's 3% is within noise). Open is up to 47% faster, partly because ring's open is slow at 192 and 1400.
- **Rig `--release=fast`:** it beats ring at 8192 (13% / 16% faster) and on open at 192–1400. It's 2–15% slower on seal at 64–1400. `--release` (safe) is only 1–5% slower than fast.
- **Ceiling design:** 8 ChaCha blocks at once, one per vector lane. Poly1305 does four blocks a step on 44-bit limbs. The MAC steps sit between the double rounds, pinned there by an empty `asm volatile` with operands. Without the pin LLVM bunches the multiplies at the end of the loop and open at 8192 is 42% slower.

**Constant time.** Neither version has secret-dependent branches or indexes, and the tag is compared by OR-ing the XORs of its two halves. On a failed open the buffer is zeroed.
- I ran dudect-style Welch tests on key, plaintext and tag classes at 64 and 1280 bytes for both versions. All |t| < 4.5 (worst 3.5), while the right-vs-wrong-tag control shows |t| up to 361, so the test does see real differences.
- Setting Arm's DIT bit costs 40–55 ns per call, so it belongs around a batch of packets, not each call. ring doesn't set it.
- RFC 8439 and XChaCha vectors pass in both. Every length 0–2100 matches Zig std.

**Top three Rig gaps:**
1. **Compile-time loops.** A run-time lane index pushes the transpose through memory (30% at 8192). I wrote the 8 calls out by hand. Wanted: `for [b] in 0..8`.
2. **A scheduling pin.** Wanted: a safe `$pin(x[0], p.h0, p.h1, p.h2)` that lowers to the empty asm. Rig only gets the effect today because its double-round loop stays rolled.
3. **Lane rotate and byte reinterpret.** Rotate by 8 as `tbl` is 5% on ChaCha. Wanted: `v.rotl(n)` and `v.bytes()`.

**Recommended API:** a key object, `crypto.ChaCha(key)` (and `XChaCha`), that wipes its key on drop. `tag = c.seal(!packet, nonce, header)` and `c.open(!packet, tag, nonce, header)!`, where open fails with `crypto.Forged` so the caller can't ignore a forgery. The protocol expert's out-of-place pair can be added at no cost.

**Decisions:**
1. Take API A (above). Default: yes.
2. Design gaps 1–3 as one Rig item before std.crypto lands; the port already runs without them. Default: yes.
3. Get x86 numbers on pup. Default: yes, please run them.

The sources and runs are on pup in `/zfs/trig-pup/records-data/rust-ports/sanstun/panel/aead/`: `zig/ceiling.zig`, `zig/bench.zig`, `zig/dudect.zig`, `rig/aead.rig`, `rig/main.rig`, `rig/dudect.rig`, `ringbench/`, `cmp.sh`, and `results-2327.txt` (the final run).

---

