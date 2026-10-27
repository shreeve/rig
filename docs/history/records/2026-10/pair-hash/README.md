# Hashing an object of integers one multiply a pair (2026-10-26)

`rig.hash` hashed an object part by part: each integer by a folded
multiply (`hashWord`), each part's hash mixed into the whole by another
(`hashMix`), so a two-word key such as Trig's `CacheKey` took four
dependent multiplies and its `InstantiationKey` six. foldhash
(`write_u128`) and abseil (the pair `Mix`) take 128 bits in one folded
multiply. Trig's PGO disassembly diff charged 63M cycles of ts-pattern to
`hashMix` and `hashWord`.

## The change (src/runtime.zig)

An object whose parts, through objects nested by value, are integers of
at most 64 bits, plain enums, and Bools, none with its own `==` or hash,
and that holds 1 to 16 such words (`wordCount`), hashes its words two at
a time: `h = fold(w0 ^ h, w1 ^ K)`, starting from the seed, and an odd
last word as `hashWord` takes it. Each word is read as `hashInt` reads
an integer (a signed one sign-extended), so equal values hash alike. Any
other object, an optional, text, a union, hashes as before. Values of
`.hash()` change for such objects; no test or document depends on them.

Tried and not kept: abseil's two parallel CRC32s (`crc.zig`, pup):
5.8 ns against 5.2 in a dependent chain, 0.95 against 0.52 ns a key in
throughput, the same spread of packed keys over slots.

## Trig c75127e, PGO, pup (runs/)

Built by Rig main f171ad553 and by this branch, fastest of 10
interleaved, warm; one checker on core 8, four on cores 6-9; outputs
identical. Other sessions' release builds ran beside these (load about
2), so walls within 1-2% are noise; instructions are not.

| Project, checkers | wall | cycles | instructions | peak RSS |
|---|---|---|---|---|
| ts-pattern, 1 | 1.2% faster | 1.45% fewer | 1.17% fewer | 0.1% lower |
| ts-pattern, 4 | 1.1% slower | 1.91% fewer | 1.19% fewer | 0.1% lower |
| zod3, 1 | 0.3% faster | 2.50% fewer | 1.12% fewer | 0.4% lower |
| zod3, 4 | 0.2% slower | 2.00% fewer | 1.01% fewer | 0.3% lower |

The same change on the std-hash branch's base gave 0.9-1.2% fewer
instructions and 0.7-2.9% faster walls (std-hash/plain-slots.md).

## std.json (guard.py, Mac, instructions per byte, rig-safe)

| File | main | branch |
|---|---|---|
| twitter | 7.8742 | 7.8743 |
| twitterescaped | 9.3633 | 9.3630 |
| canada | 16.1429 | 16.1431 |
| citm_catalog | 8.0323 | 8.0319 |
| gsoc-2018 | 3.4381 | 3.4382 |
| github_events | 7.0059 | 7.0055 |

Identical to four digits: std.json hashes no such object. All six are
0.1-0.8% under guard.txt.

## bench/hash, the built-in Map (pup core 8, rig-fast, fastest of 7; runs/bench-fast.txt)

Two-word keys (`pair`): insert 4.5% faster, hit 17.1% faster, miss 7.9%
faster. Int and String keys hash as before; their rows moved 0-12%
either way under the load of other builds, in both directions between
rows of the same work, which is noise and code placement.

## Gates

Rig's suite (Mac, `-w 4`): green, 10,627 jobs. Loco's light gate:
GREEN.
