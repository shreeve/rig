# sanstun port: the protocol expert's report

## Scope and files
This covers everything but the crypto primitives. It was written against `~/Data/Code/rig/bin/rig` (rig 0.2.9; the main checkout is at `1b2f4b59d`) on the Mac, against Rust sanstun 0.1.0 with Rust 1.99.1.

| File | What it is |
|---|---|
| `datapath.rig` (370 lines) | `Instant`, `Index`, `ReplayWindow`, `SessionKey`, `Session`, `Sessions`, `PendingEncapsulate`/`PendingDecapsulate`, `Decrypted`, `Committed`, `Timers`, `Datagram`, `Event`, `Interface.receive` (the data part), and `Tunnel` (begin, commit, poll_event), over a stub cipher with the signature asked of std.crypto |
| `demo.rig` | encrypts on a task, then receive, begin, decrypt, commit, the Established event, and a replay rejected; clean under `RIG_SANITIZE=1` |
| `bench.rig` | the Rig harness shape, for the protocol-only cases |
| `probes.rig`, `p/*.rig` | the forms the rest of the port needs, and the gaps |
| `stdx/` | a std copy plus `hint.rig`/`hint.zig` (`keep`, `wipe`); run with `RIG_STD=$PWD/stdx` |
| `rust-harness/` | the data_path, handshake and timers benches as plain loops of criterion's exact shape |

## 1. Module map
Durations are `Int` nanoseconds. `Instant` is `obj Instant: Ord` with one `pub ns: Int` and `add(?@, d) -> Instant`; the derived ordering emits a plain compare.

| Rust | Rig, ownership, fit |
|---|---|
| **errors.rs** | `pub error Wg` with `too_small(required: Int, available: Int)` plus 14 plain members. Fits exactly. |
| **keys.rs** | `PublicKey: Eq + Hash` over `[32]U8` (plain, usable as a `Map` key). `StaticSecret` and `PresharedKey` wipe in `drop(!@)`, so they are owning and can't be `+`-cloned; a copy is an explicit `copy(?@)`. Debug redaction becomes `Print`. |
| **rng.rs** | `obj Rng unique`, ChaCha20 with fast key erasure: one block per draw, 32 bytes out and 32 for the next key. |
| **tai64n.rs** | `Tai64N: Ord` (secs, nano); `stamp` uses `write[U64, .big]`. Fits. |
| **index.rs** | `Index`/`TunnelId` are plain. The `Arc<()>`/`Weak` lease becomes a `*Cell[Bool]`: the tunnel's `drop` sets it false, and the interface `retain`s the live ones. A one-word `*Cell` can go to other tasks, so the tunnel can still be sent to other cores (probed). The map has no capacity to read, so the garbage-collect trigger needs a counter of our own. |
| **replay.rs** | `ReplayWindow(next: U64, bits: [128]U64)` with `will_accept(?@)!Wg` and `mark(!@)!Wg`. Prototyped. Fits. |
| **ring_buffer.rs** | `events: [16]Event?` filled `[16 of none]`, which works because `Event` is plain (its datagram is inline). A generic `[n]T?` is rejected for owning `T` (G4/G5); a `List[T?]` ring works. |
| **timers.rs** | `Timers(at: [8]Instant, Instant? fields)`, with `tick(!@, t, now)` as a `match`. Prototyped. |
| **ratelimiter.rs** | `enum Source` (v4/v6 prefix) as the key of `Map[Source, Bucket]`, with `retain`. Needs an IP type (G10). |
| **message.rs** | Initiation and datagram are held inline, no boxes (`Datagram(bytes: [148]U8, len)`, read with `view() -> []U8 from @`). Private fields mean only the module can construct them. `DataMessage` becomes the returned length. |
| **crypto.rs** | A thin layer: `hash2`, `hmac`, `mac16`, `seal`/`open` (out-of-place and in-place), `xseal`/`xopen`, and `dh -> SharedKey!Wg`, which rejects an all-zero result. |
| **handshake.rs** | `enum HandshakeState { none, init_sent(s), expired }`. `mem::replace` becomes `@previous = swap(!@state, .init_sent(<s))`. Rust's `split_at_mut` field splits become offsets into one `!dst` (G3). The guarded `(state, previous)` match becomes `if @state as .init_sent(s) and ...`. |
| **session.rs** | Prototyped (below). |
| **tunnel.rs** | Private fields; `with_*` builders take `<@`. `handle_timeout` uses `if x as d and now >= d`. `poll_timeout` folds through `earliest(a: Instant?, b: Instant?)`. |
| **interface.rs** | The factory: `new_tunnel(!@, peer, config, now) -> Tunnel!Wg`. `receive(!@, src, datagram: []U8, now) -> Received!Wg` matches `(type, len)` using `read[U32, .little]`. |

**Sessions.** `Sessions(slots: [8]Session?, current: Index?, last_index, inserted)`.
- Slots are reached with `if !@sessions.slots[i.slot()] as s`; the emitted Zig takes a pointer into the slot, with no copy.
- A getter returning `(!Session)? from @` works if written `return s` (`return !s` gives a misleading error, G8).
- `insert(!@, s: Session)` uses `new s = <s`. The slot index must be computed before the move.

**Deferred API.**
- `encrypt(<@, plaintext: []U8, dst: ![]U8) -> Int!Wg`.
- `decrypt(<@, message: []U8, dst: ![]U8) -> Decrypted`, where `Decrypted` holds `fault: Wg?`, `len`, `session` and `counter`. An error value is stored, sent to a task and back (probed).
- `begin_encapsulate(!@)`, `begin_decapsulate(?@)`, `commit_decapsulate(!@, d, now) -> Committed!Wg`.
- Encrypting on another core is `t = encrypt_task(<p, ?pkt, !buf)&` then `n = >t!`. That is `thread::scope` with no scope. Sending to another core needs no annotation (`rig check --tasks` lists no local task).
- **The buffer.** An object can't hold a write view, so the caller lends `dst` and keeps it. For owned buffers there is `Decrypted[B: Buffer]` over `api Buffer { fun bytes(!@) -> ![]U8 from @ }`, with `enum Plaintext[B] { keepalive, data(buffer: B, len), failed(e) }`, taken out by `swap(!d.plaintext, .keepalive)`. It works, but `List[U8]` can't be given `Buffer` (G9).

**Where Rig fits:** the hot types are all plain data, `read`/`write` with an endian handle the header bytes, error members can carry fields, the lease shrinks to one word, a task with lends replaces `Send`, and secrets wipe on drop.

**Where it fights:** G3, G4/G5, G6, G7, G1/G2.

## 2. Speed leads
Rust, from rust-harness on a loaded Mac, fastest of 3:

| Case | Rust ns/op |
|---|---:|
| begin_encapsulate | 6.8 |
| encrypt, 64 B / 1280 B | 178 / 752 |
| receive | 3.5 |
| begin_decapsulate | 10.3 |
| decrypt, 64 B / 1280 B | 170 / 732 |
| commit_decapsulate | 3.6 |
| poll_event | 1.1 |
| initiate_handshake | 28,650 |
| handle_handshake_initiation | 47,800 |
| handle_handshake_response | 44,100 |
| handle_cookie_reply | 781 (931 with cold inputs) |
| poll_timeout | 5.2 |
| handle_timeout/idle | 16.7 |
| handle_timeout/keepalive | 180 |

Sizes: `Tunnel` 10,816 bytes, `Received` 64, `Event` 32, `PendingEncapsulate` 48, `PendingDecapsulate` 56.

The leads, largest first:
- **L1. Out-of-place AEAD.** Proposed signatures: `seal(key, nonce, aad, src, dst)` encrypts `dst.len - 16` bytes (`src`, then zeros) with the tag at the end; `open(key, nonce, aad, src, dst) -> Bool`; plus in-place versions. This removes the `to_owned` alloc and two copies in each of four handshake opens, and one copy per data seal or open. That is about 1 to 2% at 1280 B and about 5% of handle_cookie_reply.
- **L2. Small messages.** One NEON pass for block 0 (the Poly1305 key) plus the data blocks. A keepalive is block 0 alone (for the AEAD expert).
- **L3. Box the sessions and events.** The tunnel drops from 10.8 KB to about 1 KB, so handshake benches that move tunnels by value get cheaper. Estimated 15 to 25% of handle_cookie_reply.
- **L4. Inline datagrams and initiations.** No malloc or free per message; about 25 to 40 ns of keepalive's 180 ns.
- **L5. `Instant` as one `Int`**, with `expires_at` and `send_until` computed once per session. On macOS, Rust's `Instant + Duration` is a checked, normalized `Timespec` add.
- **L6. Wipe with two vector stores** instead of zeroize's volatile byte loop, which runs on every pending message's drop.
- **L7. Precompute the cookie key** (the Rust source has a TODO for it): 7 to 10% of handle_cookie_reply.
- **L8. Compute each HMAC key's pads once:** `Hmac.init(key)`, then `mac` called repeatedly. About 1% of a handshake.
- **L9. Fixed-base X25519** for public keys (about 5 µs against 21 µs); without it initiate_handshake is about 1.5 times slower.
- **L10. One ChaCha block per RNG draw.** rand makes 4 blocks per refill and throws the rest away. Under 1%.
- **L11. No per-message key object.** ring builds one on every seal and open.
- **L12. Maps are only on the handshake path**, so a plain `Map` is enough.

Rig prototype, stub cipher, `--release`, fastest of 5, not interleaved: begin_encapsulate 0.6 to 0.7 ns, receive 0.3, begin_decapsulate 1.5 to 1.7, commit 3.3 to 3.6, poll_event 0.2. These aren't results: the prototype leaves out `tracing` and part of commit's work, and its replay window clears bit by bit.

## 3. Harness
- **Two binaries, same output.** Both print `case ns/op` under the same case names: `rust-harness` (bench profile: LTO, one codegen unit) and the Rig bench (`--release`, plus a `--release=fast` row).
- **Matches criterion-0.8.2 exactly:**
  - `iter` drops each result inside the timed loop, so the wipe is timed on both sides.
  - `iter_batched`: SmallInput batches are `ceil(iters/10)` and LargeInput batches `ceil(iters/1000)`; the input `Vec` is black-boxed, the timed part is `outputs.extend(inputs.into_iter().map(routine))`, and outputs are black-boxed and dropped untimed.
  - `SMALL_BATCH` and `LARGE_BATCH` should come from criterion's `target/criterion/<group>/<case>/new/sample.json` `iters`. Batch size matters: handle_cookie_reply is 781 ns warm and 931 ns cold.
  - Setups are copied verbatim from the benches.
- **Rig needs `hint.keep`** (an asm barrier that clobbers memory, as `black_box` does; without the clobber, `receive`'s loads get hoisted out of the loop) **and `crypto.wipe`.**
- **Driver:** per case, 20 rounds, the two binaries in random order, 1 s warm-up, keep each side's fastest. Run under `tools/low` after the quiet check. Report "N% faster/slower", with cycles from `/usr/bin/time -l` for gaps under 2%. pup for x86.
- **Rust's numbers:** compare Rig against rust-harness, run interleaved. Criterion's estimates only validate the harness; they should agree within about 5%.

## 4. Prototype findings
It compiles, runs, and is sanitizer-clean. `rig check` rejected:
- two write slices of one buffer in one call (G3);
- `@slots[s.slot()] = <s`, because the right side moves first;
- `[8 of none]` (G4);
- `?@slot ?? return E` on an owning optional;
- `return !x` (G8);
- partial moves (G6);
- `add List[U8]` (G9);
- dispatching a `-> Int!Wg` method as a task (G7);
- `Ring[String, 2]` over `[n]T?` (G5).

No compiler bugs.

## 5. Gaps

| # | Gap | Smallest fix |
|---|---|---|
| G1 | no `black_box` | `std.hint.keep[T](x: ?T)`, asm with a memory clobber |
| G2 | no secure zero | `std.crypto.wipe(![]U8)`, Zig's `secureZero` |
| G3 | no `split_at_mut` | `w.split(at) -> (![]T, ![]T)`, or the planned two write-view results |
| G4 | `[n of none]` rejected for an owning `T?` | allow it |
| G5 | generic `[n]T?` rejected for owning `T` | same as G4 |
| G6 | no partial moves | move fields out when the type has no `drop` body |
| G7 | a `T!E` function can't be dispatched with `&` unless `E` holds `task.Stop` | the wait fails with `E \| task.Stop` |
| G8 | `return !x` gives the wrong message (diagnostic only) | suggest `return x` |
| G9 | `add` can't target one instance | allow `add List[U8]: A` |
| G10 | no IP or socket address type | `std.net.Ip`, `std.net.Addr` |
| G11 | `std.time.Instant` has no `add`, ordering or constructor | add `add`, `: Ord`, `at(ns)` |
| G12 | no std.crypto | the other two experts |

Notes:
- The "unexpected indentation" error for `=> NEWLINE block` should say how to write the arm.
- The `std/` on disk is out of sync with `bin/rig` (math's `abs`), so `RIG_STD` prototypes must avoid `std.math` until `bin/rig` is rebuilt.

## 6. Build order (Rust lines → estimated Rig lines)

| Step | Modules | Rust → Rig | Needs |
|---|---|---|---|
| 0 | `std.hint.keep`, `std.crypto.wipe` | → 30 | |
| 1 | errors, Index, replay, ring, timers, tai64n, message | 578 → 300 | none |
| 2 | session | 455 → 220 | the stub until std.crypto's AEAD lands |
| 3 | keys, rng, crypto | 284 → 150 | std.crypto |
| 4 | handshake | 459 → 260 | step 3 |
| 5 | ratelimiter, TunnelIndices, interface, Ip/Addr | 384 → 220 | steps 3, 4 |
| 6 | tunnel, plus lib.rs's example as a test | 490 → 260 | steps 2 to 5 |
| 7 | tests/it, harness.rs first | 2,018 → 1,100 | step 6; `--seeds=20`, sanitizer |
| 8 | the bench harness, interleaved, Mac and pup | 406 → 300 | step 6 |

The library is about 2,650 Rust lines and should come to 1,300 to 1,500 in Rig. Steps 1 and 2 can start now; L1's signature should be settled with the crypto experts first.

**Decisions for the owner** (defaults):
1. Lend `dst`; add the owned form only when its test needs it.
2. The RNG doesn't match Rust's `StdRng` byte for byte: yes.
3. Box the sessions and events: yes.