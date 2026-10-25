# Map quick items: bulk table reset, a cheaper small-key hash, 2× growth (2026-10-24)

Three Rig-side items from the beat-tsrs committee (A1) and the Map survey
(#667), each measured alone and together on real Trig. Only the first
cleared the owner's bar (more than 2% faster in time, or at least 1%
fewer single-thread instructions, and nothing slower beyond 2%), so only
it landed.

| Item | What | Kept |
|---|---|---|
| R | `Table.reset` makes each List anew with `List.filled(n, 0)` (one allocation, one `@memset`), where it pushed `n` zeros one at a time onto a List grown by `realloc` | yes |
| H | an object of plain fields (integers of 64 bits or fewer, Bools, enums, nested) hashed as packed words: each pair of words one folded multiply, the pairs xored, then one folded multiply; 2 multiplies for a 16-byte `CacheKey` where it took 4, 3 for a 24-byte `InstantiationKey` where it took 7 | no: 0.3-0.6% fewer instructions, time even |
| G | the table grows 2× at a time (sized for four fifths full) where it grew 4× (sized for two fifths) | no: 5-6% less memory but 1.3-2.0% more instructions and 1.5-3.8% more cycles |

## Trig on pup

Trig bb96105, release builds by Rig 11fa5e04b (base, R, G, by
`RIG_STD`) and by Rig e36e87ae4 (H, RH, RHG); `--singleThreaded`
check mode, pinned to CPU 8 (sibling 9 idle), interleaved, fastest of 20,
user-mode P-core counters; release builds of other sessions ran on the
build pairs during both runs. Every build's output matched base's.

| ts-pattern | time ms (run 2 / 3) | cycles G (2 / 3) | instructions G | peak RSS |
|---|---|---|---|---|
| base | 1282 / 1320 | 5.245 / 5.339 | 12.765 | 327 MB |
| R | 1270 / 1317 | 5.167 / 5.249 (1.5%, 1.7% fewer) | 12.571 (1.5% fewer) | 329 MB |
| H | 1311 / 1296 | 5.284 / 5.359 | 12.697 (0.5% fewer) | 327 MB |
| RH | 1314 / 1315 | 5.276 / 5.281 | 12.514 (2.0% fewer) | 329 MB |
| G | 1316 | 5.446 (3.8% more) | 12.935 (1.3% more) | 309 MB |
| RHG | 1277 | 5.380 | 12.698 | 314 MB |

| zod3 | time ms (2 / 3) | cycles G (2 / 3) | instructions G | peak RSS |
|---|---|---|---|---|
| base | 246.4 / 246.5 | 0.977 / 0.974 | 2.307 | 88 MB |
| R | 242.5 / 242.7 (1.6% faster) | 0.962 / 0.956 | 2.284 (1.0-1.7% fewer) | 88 MB |
| H | 244.4 / 242.9 | 0.966 / 0.972 | 2.307 (0.0-0.3% fewer) | 88 MB |
| RH | 243.9 / 242.6 | 0.948 / 0.961 | 2.280 | 88 MB |
| G | 250.5 | 0.992 (1.5% more) | 2.352 (1.9% more) | 83 MB |
| RHG | 247.5 | 0.984 | 2.314 | 85 MB |

R's 194M fewer instructions on ts-pattern match A1's estimate of 180M.
H's 70M is below A1's 120M: the hash is a smaller share of a Map
operation than the probe and the key compare.

## bench/hash on the Mac

Fastest of 9, interleaved, ns per operation; the load rose from 6 to 15
during the run, so only large differences count.

| row | base | R | H | G |
|---|---|---|---|---|
| int insert | 16.33 | 14.45 (13.0% faster) | 16.44 | 26.43 (38.2% slower) |
| string insert | 29.58 | 25.76 (14.8% faster) | 29.69 | 40.90 (27.7% slower) |
| pair insert | 21.66 | 19.50 (11.1% faster) | 20.82 (4.0% faster) | 31.94 (32.2% slower) |
| pair hit | 6.70 | 6.71 | 6.22 (7.6% faster) | 6.61 |
| pair miss | 10.41 | 10.36 | 9.39 (10.9% faster) | 10.58 |
| int ensure-miss | 17.09 | 15.09 (13.2% faster) | 17.23 | 27.16 (37.1% slower) |
| int / string hit, miss | | within 2.3% | within 2.6% | within 6% |

G rebuilds the table twice as often (each rebuild rehashes every key of
8 bytes or fewer) and probes longer at the higher load.

## Probe statistics (simulated, Rig's table)

A simulation of Rig's table (linear probing, 7-bit tags from the top
bits, slots from the low bits, Rig's growth rule) over Trig's key shapes,
50 to 1,000,000 keys: packed relation keys, packed type lists, dense
single-type keys, mapper pairs, hashed (random) `CacheKey`s,
`InstantiationKey`s with random and dense keys, grids of two small
`U64`s and of two `U32`s, dense Ints, and keys differing only in high
bits. Means over the 84 rows, in slots read per lookup:

| hash | hit | miss | worst probe |
|---|---|---|---|
| today (one multiply per field and a mix) | 1.72 | 4.14 | 213 |
| H (pairs folded, one final multiply) | 1.73 | 4.14 | 224 |
| one folded multiply alone (foldhash's 16-byte step) | 1.71 | 4.02 | 2,074 |
| rustc-hash's FxHasher (tsrs) | 1.51 | 2.98 | 223 |
| wyhash's 16-byte path | 1.72 | 4.14 | 276 |
| Wyhash of the key's bytes (reference) | 1.73 | 4.17 | 296 |

H probes as a random hash does on every shape. A single folded multiply
fails on structured keys (two `U32`s in one word at 400,000 keys: 31.7
slots per miss, a probe of 2,074). FxHasher probes less on dense ids,
which it nearly preserves in order, but more on others (a grid of two
small `U64`s at 1,000,000 keys: 3.70 per miss against 2.33). Today's
one-multiply Int hash itself clusters on dense Ints at 400,000 keys
(12.2 per miss against 9.5); an object of one Int field mixes twice and
does not. A load of 7/8 was not built: linear probing there expects
about 32 slots per miss, against 13 at 4/5.

## Not landed, kept for later

H is a self-contained change to `rig.hash` (`isFlat`, `flatPack`,
`hashFlat` in src/runtime.zig), kept as [flat-hash.diff](flat-hash.diff)
against Rig 11fa5e04b. It pays off where small multi-word keys dominate (7-11% on
`bench/hash`'s pair lookups), and may clear the bar together with
`find` handing back the free slot, so an insert hashes and probes once.
