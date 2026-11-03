# std.crypto (#800): adversarial review

I found three real defects and several smaller ones. The algorithms themselves are correct: every random and edge-case comparison against Zig's std.crypto came out byte-identical. The full findings are below the summary. The probes are on pup in `/zfs/trig-pup/records-data/rust-ports/sanstun/review/`.

**Confirmed defects**
1. **High – std/crypto.zig:29.** `std.elf.AT_HWCAP` doesn't exist in Zig 0.17; the name is `std.elf.AT.HWCAP`. Any X25519 program built on aarch64 Linux whose CPU lacks DIT (Cortex-A72, Neoverse N1, `baseline`) fails with a Zig error. That covers Graviton2 and Raspberry Pi 4/5, and breaks North Star 1.
2. **Medium – aead.rig:605-647.** There is no length limit. Past 2^38−64 bytes the U32 counter wraps silently to block 0, the Poly1305 key, and keystream is reused. RFC 8439 caps the length there and Zig asserts it. Found by reading; not run (needs 256 GiB).
3. **Medium – secrets print.** `print(c)` shows `ChaCha(key: [...])`, `print(s)` shows the X25519 secret, and `print(m)` shows `Hmac`'s private, key-equivalent states. `c.key` can also be read and written from any module.
   - The `pub key` field is avoidable today: a private `key` plus `pub fun of(k)`, the pattern `Hmac.of` already uses, works.
   - Hiding the field doesn't stop `print`; that needs a language rule.
4. **Low–medium – aead.rig:555-568.** In debug builds, the default for `rig run` and `rig build`, the Poly1305 carries `1 if a0 < m0 else 0` become `subs; b.lo`, a branch on secret data. Release builds are branch-free.
5. **Low – wiping is inconsistent.** These are never wiped: the comb digits `e` (x25519.rig:177), the key copy in `state()`, the subkey in `subkey()`, `mac[n]`'s state after the key block, and `hmac`'s outer state. The record says the subkey and the comb's key bytes are wiped.
6. **Low – field.rig:4-9.** The stated 2^55 limb bound would overflow `reduce` (2^65.6). The real worst case is about 2^53.3, so the code is right but the comment's proof isn't.
7. **Low – aead.rig:139.** `open_into` panics when `src` is shorter than 16 bytes, so a truncated network packet can crash the process.

**Plausible**
- The X25519 loops get yield checks. None reaches 1,024 turns today, so nothing yields; a batch-DIT form would let a task move threads with DIT state left behind.
- `select`'s negation mask skips the barrier.
- `share` returns a plain `[32]U8` that is never wiped.

---

# Full findings

Read only; worktree std via `RIG_STD`, builds through `tools/heavy`, Mac only. Probes are in `review/`: `cross.*`, `poly/`, `x/`, `api/`, `dit/`, `ct/`, `shim/`, and `stdprobe/` (a std copy with test hooks).

## What passed
- **cross.rig against cross.zig**, the same splitmix64 stream on both sides, 2208 lines, identical:
  - ChaCha20-Poly1305: 120 messages, 34 at edge lengths (0, 1, 15/16/17, 31–33, 63–65, 127–129, 191–193, 255–257, 448, 511–513, 575/576, 1023–1025, 1536/1537, 2047, 4096, 4111), the rest random below 5000. Headers from 0 to 600 bytes and multiples of 16.
  - `seal`, `open`, `seal_into` (exact, and padded by 0–39 bytes) and `open_into` all agree. A one-bit flip anywhere in ciphertext, tag or header always fails and leaves zeros.
  - XChaCha20-Poly1305 on the same messages.
  - X25519: 200 random public keys and shared secrets, some with u's top bit set. Non-canonical u (p, p+1, p+2, p+9, also with the top bit): Rig and Zig agree on which are low order.
  - BLAKE2s: `hash` from 0 to 699 bytes; `mac[1/16/20/32]` for every key length from 0 to 32; `hmac` for keys of 0 to 199 bytes, including 64, 65, 128 and 129. `Hmac.of(k).mac` equals `hmac`, and `Hasher` fed random chunks equals `hash`.
- **Raw Poly1305** (through a hook in stdprobe), for both the 44-bit `Mac` and `Mac64`:
  - RFC 8439 A.3 vectors #5–#11, which test the final reduction near p: all correct.
  - All-0xFF messages under the largest clamped r, and 200 random keys: identical to Zig's Poly1305.
- **Extreme X25519 inputs** (`x/`): identical to Zig, and p−1 is refused as low order.
- **By reading against the RFCs:** the counter starts at 1 and block 0 is the Poly1305 key; padding and the length block; HChaCha20 and the short nonce; X25519 clamping, the ladder, a24, the inversion chain and the final reduction; the comb's digits and formulas; BLAKE2s's final block and t values; HMAC's long-key path.
- **API:** aliasing `src` and `dst` is rejected by the loan checker. `Forged` can't be ignored (both a bare call and `_ =` are rejected). Key objects and `Hasher` can't be copied or cloned.
- **Disassembly of `--release=fast`** (arm64 and x86-64-v3): Poly1305 uses `adds`/`adcs`/`cinc`, and the other branches test lengths. Inside the DIT spans the only branches are loop back-edges. DIT is saved and then restored by mask. On x86 the shim compiles to nothing.

## Defect details
1. **Repro:** in `ct/out`, `zig build-exe -target aarch64-linux -mcpu=neoverse_n1 __rig_main.zig`. `cortex_a72` and `baseline` fail the same way; `neoverse_v1`, x86 and macOS compile. Add a cross-compile case to the suite.
2. **Fix:** panic or fail when `n > 274877906880`, in all four entry points.
3. **Repro:** `api/print_obj.rig` and `api/priv.rig`. The `of` workaround is verified by `priv_read` and `priv_make` against stdprobe. Making `print` hide a key object needs a Rig rule, for example that an object with a `drop` body prints as `ChaCha(…)`: an owner decision.
4. **Repro:** `shim/dbg.zig`. Fix with a branch-free carry, `((h & m) | ((h | m) & a.not())) >> 63`, or document that constant time holds only in release builds.
5. For contrast, `kb`, `pad`, the clamped scalar `k` and the partial keystream are wiped, and they are no more secret than the copies above.
6. The worst case is `dbl`'s `f`, about 5·2^51, where `reduce` peaks at 2^61.9. Because the arithmetic wraps, a later edit that trusts the comment would overflow silently, even in debug. The comment should say 2^54.
7. ring returns an error in this case. Suggest returning `Forged.tag` for a short `src`, and keeping the panic for a `dst` that is too short.
8. Minor:
   - STD.md:1001 says the shim does three things; it does four, counting `entropy`.
   - `blake2s.mac[0]` and `mac[40]` are accepted and panic only at run time, though `n` is known at compile time.

## Plausible details
- **Yield checks:** the ladder runs 255 turns and the longest `sqn` 100, against `tick_turns` of 1,024. 64 tasks × 200 shares never left DIT set (0 of 12,800). A long batch-DIT loop could yield mid-span, resume on another worker without DIT, and leave the first thread with DIT set.
- The `msr` asm doesn't fence register-only arithmetic, so multiplies could drift across `dit_on`/`dit_restore`. Not seen in the builds I inspected.
- Moves leave unwiped copies of key objects, the same caveat Rust has.
- On aarch64 targets other than Linux and Apple without DIT at compile time, DIT is silently off.
- XChaCha is advertised for random nonces, but no secure random-bytes function is public.

## The shim and the API
- **The shim:** every function is needed, and each Zig type matches its Rig signature. `entropy` belongs: std.random seeds from `Io.random`, not `randomSecure`. It would be worth making it public for XChaCha nonces.
- **The API:** names follow Rig's vocabulary and std style. Nonce reuse isn't prevented, as in Zig and ring's `LessSafeKey`. `seal_into` silently pads whenever `dst` is longer than `src.len + 16`.

## Not re-measured
I didn't rerun the speed tables or the dudect runs.