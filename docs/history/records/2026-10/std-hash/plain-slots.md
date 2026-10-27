# std.hash revived: plain slots, an inlined probe, pair hashing (2026-10-26)

The owner approved std.hash as a std module on 2026-10-25. #685 had been
held because Trig did not gain (measurement.md). This round rebuilt its
layout for plain keys and values with #701's `$plain` narrowing, and,
at the coordinator's request, made the runtime hash an object of integer
parts one folded multiply a pair. Scripts and raw runs are in
[plain/](plain/).

## What was built (branch `std-hash`, PR #685)

- **Plain slots.** Under `if $plain(K) and $plain(V)` a slot is the
  `Bucket` itself (`ps: List[Bucket[K, V]]`); a free slot holds a copy
  of some entry, and the control byte alone says whether a slot is
  full. `Map[Int, Int]` slots are 16 bytes (24 in #685),
  `Map[CacheKey, U32]` 24, `Map[U32, U32]` 8. Any other Map keeps
  #685's `Bucket[K, V]?` slots; a Set likewise.
- **Control bytes:** 0 free, 1 tombstone, `0x80 | h >> 57` full, so a
  growth's control bytes are one zero fill and a full byte is its sign
  bit (one `pmovmskb`). Tables under 16 slots keep free bytes to 16
  and their copies from 16 on (hashbrown's layout), so `set_ctrl` is two
  stores with no loop.
- **One inlined probe** (`p_probe`) finds the key or the first free slot;
  `p_add` puts into a table with room inline; only building or growing
  the table (`p_add_grown`, `rarely`) is out of line. The probe's group
  reads are proven in bounds by a guard (`0 <= mask and mask + 16 <=
  ctrl.len`) and the loop's own test, which LLVM folds to one compare.
- Growth past 7/8, tombstones, rebuild in place at the same size, as
  #685. Growth writes the control bytes and the slots in one fill each.
- **A table of 1 MiB or more grows in place** (`LARGE`): its Lists are
  lengthened, which `mremap`s their pages, and the keys are placed again
  where they lie. Copying growth held the old and the new table at once:
  1.5M two-word keys peaked at 92 MB copying, 56 MB in place, 65 MB in
  the ordered Map.
- **Hashing stays `.hash()`.** The runtime now hashes an object whose
  parts (nested objects included) are integers of 64 bits or less,
  plain enums and Bools by its words two at a time, one folded multiply
  a pair (foldhash's `write_u128`, abseil's pair `Mix`): `CacheKey` is
  one multiply, `InstantiationKey` two (were four and six). Types with
  their own `==` or hash, and any other shape, hash as before.

Not done: control bytes and slots in one allocation (Rig has no typed
view of raw bytes; two Lists cost one more pointer load and allocation
each); 8-byte SWAR groups for arm64 (all group helpers would need a
width per target; x86 is the timing target).

## Trig (pup, PGO, fastest of 10 interleaved, warm)

Trig c75127e; the switch is `plain/trig-switch.diff`: the relation
results, instantiation cache, mapper caches, six `CacheKey` type caches
and `maybe_keys_set`. One checker on core 8 (sibling 9 idle), four on
cores 6-9. Outputs identical in every run. Builds: `base` and `base2`
are Trig as is, by the branch's Rig without and with pair hashing;
`h4` is the switch by the final Rig (in-place growth and pair hashing);
`h5` is `h4` with the instantiation cache left ordered. Runs: runs/e
(runs/c, runs/d are the earlier rounds, consistent with these).

h4 against base2 (std.hash alone):

| Project, checkers | wall | cycles | instructions | peak RSS |
|---|---|---|---|---|
| ts-pattern, 1 | 4.1% faster | 3.9% fewer | 0.64% more | 3.8% lower |
| ts-pattern, 4 | 2.2% faster | 4.4% fewer | 0.81% more | 1.7% lower |
| zod3, 1 | 3.5% faster | 4.8% fewer | 0.71% more | 3.2% higher |
| zod3, 4 | 1.0% faster | 1.8% fewer | 0.24% more | 2.7% higher |

Round d gave h4 against base2: ts-pattern 3.9% / 4.2% faster, zod3 1.1% /
2.2% faster, the same RSS signs. Copying growth (h3) was 2.1-3.3% faster
on ts-pattern with RSS 2.9% lower at one checker but 2.4% higher at four.

Pair hashing alone (base2 against base): 0.9-1.2% fewer instructions on
both projects; wall 0.7-2.9% faster on ts-pattern, zod3 within noise
(1.2% slower to 2.4% faster). h4 against base (both changes): 4.0-5.0%
faster on ts-pattern.

**zod3's memory.** A heap profile (release, `RIG_HEAP_PROFILE=1`) shows
the peak live bytes equal (52.9 against 52.5 MiB); the instantiation
cache's table had just doubled (4 MiB of 32-byte slots, against the
ordered Map's 2 MiB of entries plus its hashes and table), and the
blocks freed by copying growth below 1 MiB stay in the heap's 16 MiB
cache of large blocks. Leaving the instantiation cache ordered (h5)
halves the excess (RSS 1.0-1.4% higher on zod3, ts-pattern even) but
keeps only about half the speed (ts-pattern 1.3-2.4% faster).

**Against the bar** (more than 2% faster or 1% fewer instructions, RSS
no higher): met on ts-pattern; zod3 is faster (1.0-3.5%) with 2.7-3.2%
more peak RSS. The PR stays a draft.

## bench/hash (pup core 8, fastest of 7, rig-fast; plain/pup-bench.txt)

`rust` is hashbrown with FxHash; `rust-mix` (new variant) is hashbrown
with Rig's Int hash, so keys land as std.hash puts them. FxHash on the
bench's sequential keys makes strided slot sequences a prefetcher
follows, which favours `rust` on misses and removes; `rust-mix` compares
layouts.

| keys | op | hash.Map | Map | hashbrown | hashbrown, Rig's hash |
|---|---|---|---|---|---|
| 16 | hit | 1.65 | 1.65 | 1.23 | 1.77 |
| 16 | miss | 1.17 | 1.37 | 1.44 | 1.60 |
| 1,000 | insert | 18.57 | 14.97 | 17.75 | 21.06 |
| 1,000 | hit | 1.64 | 1.87 | 1.27 | 1.56 |
| 1,000 | miss | 1.42 | 1.55 | 1.06 | 1.82 |
| 1,000 | remove | 11.71 | 16.11 | 3.57 | 9.50 |
| 100,000 | hit | 2.96 | 8.16 | 1.95 | 2.88 |
| 100,000 | miss | 4.58 | 13.61 | 1.74 | 5.05 |
| 4,000,000 | insert | 46.18 | 32.29 | 34.77 | 40.03 |
| 4,000,000 | hit | 20.88 | 18.57 | 9.67 | 19.88 |

With the same hash, hash.Map is within 5% of hashbrown on hits, faster on
misses, 13-23% slower on removes and large inserts (in-place growth
costs about 25% on million-key inserts, `hbB`/`hbC` in the session's
runs). The Map rows (the ordered Map) moved only through pair hashing:
pair miss 16% faster, pair hit 4% faster; String rows in the full
program moved up to 20-37% either way between builds, a code-placement
effect: a program timing only them is unchanged (19-20 ns both ways).
Mac (arm64, loaded): plain/mac-bench.txt; NEON's mask-to-bits makes
hits 15-20% slower than hashbrown's there.

## std.json and the gates

- std.json, map-stage's six programs, rig-safe and rig-fast, fastest of
  11 and 15: within 1.2% either way, flipping between runs; the
  programs' text sizes are byte-identical.
- `tools/emit-diff origin/main`: only `rig/runtime.zig` differs (+80
  lines) in 29 of 30 programs, Trig and std.json included; the 30th is
  bench/hash, which main cannot build.
- Rig's suite (`swarm test/rig.rip all -w 4`, Mac): green, 10,642 jobs.
- Loco's light gate: GREEN.
- Tried and not kept: abseil's two-CRC32 combine (plain/crc.zig):
  5.8 ns against 5.2 dependent and 0.95 against 0.52 ns throughput for a
  two-word key; a key type's own cheaper `hash_into` on a CacheKey-shaped
  bench gained 2-4%.
