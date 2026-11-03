# sanstun panel, round 1 (2026-10-30): summary and decisions

Three experts on the Mac (Apple M5, loaded 4 to 7 by each other), Rig at main
6c150dfa8. Full reports: `aead/REPORT.md`, `curve-hash/REPORT.md`,
`protocol/REPORT.md`.

## Numbers (Mac, fastest of interleaved rounds)

| | Rust | Zig ceiling | Rig `--release=fast` |
|---|---:|---:|---:|
| ChaCha20-Poly1305 seal, 64 B | 146 ns (ring) | 135 | 149 |
| seal, 1280 B | 709 | 631 | 752 |
| seal, 8192 B | 3,695 | 3,031 | 3,274 |
| open, 1280 B | 702 | 578 | 660 |
| X25519 public key | 7.72 µs (dalek) | 5.45 | 5.38 |
| X25519 shared key | 19.80 µs | 14.96 | 15.05 |
| BLAKE2s, 32 B | 80.3 ns (blake2) | 70.6 | 71.3 |
| HMAC-BLAKE2s | 299 ns | 286 | 290 (144 with the key's pads computed once) |

- X25519 and BLAKE2s in Rig beat Rust now and match the ceilings.
- The AEAD ceiling beats ring (9 to 22% on seal, more on open); Rig is 7 to 19%
  behind the ceiling, for want of compile-time loops, a scheduling pin, and lane
  rotates and shuffles.
- All pass the RFC 8439, 7748 and 7693 vectors and WireGuard's hashes.
- Constant time (dudect): the AEADs pass; X25519, dalek included, passes on
  Apple silicon only with the DIT bit set (0 to 1.5% on X25519, 40 to 55 ns a
  call on the AEAD, so set per batch). sanstun as shipped sets none.

## Decisions for the owner (defaults)

1. std.crypto is Rig, with one small Zig shim for what Rig cannot say: DIT set
   and restored, a wipe the optimizer keeps, a value barrier. Default: yes.
2. Names: `crypto.ChaCha(key)` / `XChaCha` with `seal` and `open` (open fails
   with `crypto.Forged`); `crypto.x25519.Secret` with `public()` and
   `share(peer)!`; `blake2s.hash`, `blake2s.mac[n]`, `blake2s.Hasher` (`add`,
   `done`), `blake2s.hmac`, `blake2s.Hmac.of(key)`; `crypto.wipe`,
   `crypto.equal`. Default: these.
3. The Rig forms the AEAD needs to reach its ceiling (compile-time loops
   `for [b] in 0..8`, a scheduling pin, `rotl`/`rotr`, lane shuffles, chunk
   views) designed as one language item; the port goes ahead without them.
   Default: yes.
4. The protocol's choices: `decrypt` lends the caller's buffer; the RNG is
   ChaCha20 with fast key erasure, not byte-identical to Rust's `StdRng`; a
   tunnel's sessions behind one box. Default: yes.
5. Small std additions the port needs: `std.hint.keep` (Rust's `black_box`),
   `std.net.Ip`/`Addr`, `time.Instant` with `add`, ordering and `at(ns)`.
   Default: yes, with std.crypto.
6. x86 numbers on pup. Default: yes (asked of Swiss).

## x86 AEAD ceiling (pup core 6, 2026-10-31, `aead/results-x86-ceiling.txt`)

On x86 the best ceiling is `lanes`: the arm64 layout, eight blocks in lanes,
with a one-block 64-bit Poly1305 stitched in. At 8192 B it seals in 3,093 ns
and opens in 2,906. ring is 10% faster on seal and 4% faster on open. The
stitched AVX2-rows `ceiling` loses to `lanes`, 3,180 ns on seal and 3,587 on
open. Rig `--release=fast` takes 4,222 and 4,155 ns, about what `mac44` (the
44-bit-limb Poly1305) takes, so Rig takes 36% longer than `lanes` on 8 KB seals
and 43% longer on opens. On short messages (64–192 B) every variant is 8 to
16% behind ring. What closes most of the gap on x86 is Rig emitting `lanes`
with the 64-bit Poly1305, chosen per architecture.
