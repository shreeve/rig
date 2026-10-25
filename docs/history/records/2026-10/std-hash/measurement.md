# std.hash: an unordered Map and Set, measured (2026-10-25)

`hash.Map` and `hash.Set` (std/hash.rig, the std-hash PR) are hashbrown's
layout in safe Rig: a control byte a slot, slots of `Bucket[K, V]?`
holding the key and value in place, groups of 16 control bytes compared
as one `Simd[U8, 16]`, triangular probing, at most 7/8 full, tombstones
only where a probe could have passed, rebuilt in place when tombstones
are at least half the table, otherwise doubled. Hashing is `.hash()`,
in one function (`hash_of`), for the whole-hash decision (7b) to plug
into later.

## bench/hash, ns per operation, fastest of 9, interleaved

`--release=fast` builds; every variant, the safe builds too, is in the
raw outputs beside this file, [pup-bench.txt](pup-bench.txt) and
[mac-bench.txt](mac-bench.txt). Map is the built-in ordered Map; Zig is
`std.AutoHashMapUnmanaged`/`StringHashMapUnmanaged`; Rust is
`std::collections::HashMap` (hashbrown) with FxHasher, run for the sized
rows only. Sized rows: 4,000,000 operations each; insert into empty
maps (a million keys a batch), remove all of them, hit and miss in one
map, iterate it. The 1M rows look keys up in the order they were put
in, which favors the ordered Map, whose entries lie in that order.

### pup (x86-64, core 8, sibling 9 idle)

| keys | op | Map | hash.Map | Zig | Rust (hashbrown) |
|---|---|---|---|---|---|
| 16 | insert | 13.01 | 30.98 | 27.61 | 26.59 |
| 16 | remove | 12.52 | 14.41 | 9.08 | 9.13 |
| 16 | hit | 1.75 | 2.26 | 1.61 | 1.30 |
| 16 | miss | 1.29 | 1.57 | 1.92 | 1.47 |
| 16 | iterate | 0.73 | 0.80 | 1.15 | 0.54 |
| 1,000 | insert | 15.33 | 26.40 | 34.25 | 18.11 |
| 1,000 | remove | 16.67 | 12.41 | 9.78 | 3.69 |
| 1,000 | hit | 1.92 | 1.97 | 1.89 | 1.32 |
| 1,000 | miss | 1.44 | 1.63 | 1.91 | 1.08 |
| 1,000 | iterate | 0.72 | 0.81 | 1.41 | 0.66 |
| 100,000 | insert | 20.78 | 23.83 | 32.01 | 13.69 |
| 100,000 | remove | 39.96 | 22.36 | 17.90 | 10.23 |
| 100,000 | hit | 8.52 | 3.53 | 9.50 | 2.05 |
| 100,000 | miss | 14.33 | 5.33 | 17.20 | 1.84 |
| 100,000 | iterate | 0.91 | 1.40 | 2.95 | 0.67 |
| 4,000,000 | insert | 35.19 | 58.40 | 58.98 | 35.17 |
| 4,000,000 | remove | 67.62 | 43.60 | 28.93 | 15.46 |
| 4,000,000 | hit | 19.02 | 23.51 | 26.52 | 11.11 |
| 4,000,000 | miss | 12.55 | 7.69 | 14.47 | 3.53 |
| 4,000,000 | iterate | 1.10 | 3.58 | 6.48 | 1.98 |
| int, 1M | insert | 25.91 | 49.60 | 49.81 | - |
| int, 1M | hit | 11.06 | 17.29 | 20.82 | - |
| int, 1M | miss | 11.70 | 5.78 | 11.50 | - |
| int, 1M | iterate | 1.05 | 3.46 | 6.61 | - |
| string, 1M | insert | 40.70 | 137.65 | 148.74 | - |
| string, 1M | hit | 19.70 | 46.93 | 59.26 | - |
| string, 1M | miss | 16.93 | 14.59 | 23.02 | - |
| string, 1M | iterate | 1.78 | 4.53 | 6.31 | - |
| pair, 1M | insert | 33.12 | 60.85 | 61.36 | - |
| pair, 1M | hit | 15.05 | 24.89 | 24.09 | - |
| pair, 1M | miss | 14.41 | 8.56 | 11.49 | - |

### Mac (arm64, load 3.6-5.5 during the run)

| keys | op | Map | hash.Map | Zig | Rust (hashbrown) |
|---|---|---|---|---|---|
| 16 | insert | 8.43 | 22.98 | 15.82 | 15.99 |
| 16 | remove | 9.45 | 12.83 | 4.42 | 4.62 |
| 16 | hit | 0.97 | 1.23 | 1.02 | 0.81 |
| 16 | miss | 0.82 | 0.94 | 1.24 | 0.62 |
| 16 | iterate | 0.53 | 0.56 | 0.74 | 0.43 |
| 1,000 | insert | 10.47 | 20.17 | 21.66 | 5.58 |
| 1,000 | remove | 10.91 | 5.82 | 5.60 | 2.71 |
| 1,000 | hit | 1.24 | 1.29 | 1.25 | 0.87 |
| 1,000 | miss | 1.55 | 1.20 | 1.58 | 0.57 |
| 1,000 | iterate | 0.51 | 0.56 | 1.26 | 0.54 |
| 100,000 | insert | 12.69 | 16.00 | 18.93 | 4.39 |
| 100,000 | remove | 20.05 | 11.89 | 8.24 | 2.41 |
| 100,000 | hit | 4.55 | 1.79 | 5.34 | 1.21 |
| 100,000 | miss | 9.88 | 2.56 | 11.75 | 0.57 |
| 100,000 | iterate | 0.48 | 0.90 | 1.18 | 0.57 |
| 4,000,000 | insert | 15.87 | 28.68 | 27.45 | 9.30 |
| 4,000,000 | remove | 30.69 | 19.83 | 10.95 | 5.36 |
| 4,000,000 | hit | 7.94 | 9.66 | 10.45 | 4.45 |
| 4,000,000 | miss | 9.01 | 3.06 | 10.66 | 1.22 |
| 4,000,000 | iterate | 0.51 | 1.68 | 4.82 | 0.59 |
| int, 1M | insert | 14.35 | 25.15 | 25.05 | - |
| int, 1M | hit | 5.21 | 6.70 | 7.76 | - |
| int, 1M | miss | 8.48 | 2.38 | 9.16 | - |
| int, 1M | iterate | 0.53 | 1.71 | 4.61 | - |
| string, 1M | insert | 23.62 | 60.43 | 58.72 | - |
| string, 1M | hit | 11.65 | 21.80 | 30.23 | - |
| string, 1M | miss | 13.27 | 6.34 | 15.10 | - |
| string, 1M | iterate | 0.62 | 1.74 | 4.63 | - |
| pair, 1M | insert | 19.44 | 28.19 | 26.67 | - |
| pair, 1M | hit | 6.73 | 9.05 | 10.46 | - |
| pair, 1M | miss | 10.68 | 3.29 | 8.86 | - |

What it shows: hash.Map's misses are 1.6-3.9 times as fast as Map's at
100,000 keys and up (about even below), and its hits 2.4-2.5 times as
fast when the lookups are scattered (100,000 keys); hits looked up in
insertion order, at 1M and 4M, are 22-56% slower, since Map's entries
lie in that order. Inserts are 1.15-3.4 times as slow, from growth:
each growth writes every slot of the new table (a `none` cannot be
copied in at once into a List of an owning type) and rehashes every
key, and a String key is hashed again on every growth, where Map keeps
its hash (string insert 2.6-3.4 times as slow, about Zig's, which also
keeps none). Removes are faster than Map's from 1,000 keys up (Map
shifts slots back), slower at 16. Iteration is 1.1-3.3 times as slow
(slots 7/16 to 7/8 full, against Map's dense List). Against hashbrown,
hash.Map is 1.5-2.2 times as slow on hits and 1.1-4.5 times on misses;
hashbrown's slot is 16 bytes for an Int key and value, hash.Map's 24
(the optional's flag), and its inserts are 1.2-3.6 times as fast.

## Trig A/B on pup

Trig 8e2f21f in a scratch copy, three release builds by the std-hash
Rig: base (unchanged), h3 (the relation caches, the instantiation cache
and the mapper caches as `hash.Map`), and hall (h3 and the six other
`CacheKey` caches in checker.rig: indexed access, template literal,
error, tuple, union, intersection). Symbol tables stay ordered: Trig
walks them in order (`table_entries`). One checker
(`--singleThreaded`), check mode, core 8, interleaved, fastest of 10;
output identical in every variant; two runs in different orders.

| ts-pattern | time ms (run 1 / 2) | cycles G (1 / 2) | instructions G | peak RSS |
|---|---|---|---|---|
| base | 1271.7 / 1224.6 | 4.922 / 4.958 | 11.300 / 11.304 | 342 MB |
| h3 | 1281.2 / 1206.7 | 4.882 / 4.864 | 11.448 / 11.442 (1.3% more) | 338 MB |
| hall | 1278.6 / 1211.7 | 4.885 / 4.929 | 11.460 / 11.465 (1.4% more) | 343 MB |

| zod3 | time ms (1 / 2) | cycles G (1 / 2) | instructions G | peak RSS |
|---|---|---|---|---|
| base | 239.8 / 221.7 | 0.889 / 0.901 | 2.054 / 2.054 | 92 MB |
| h3 | 245.7 / 226.7 (2.5%, 2.3% slower) | 0.901 / 0.915 | 2.063 / 2.066 | 101 MB |
| hall | 243.0 / 223.9 | 0.900 / 0.907 | 2.069 / 2.069 | 101 MB |

ts-pattern moves within the spread (0.8-1.9% fewer cycles, 1.3% more
instructions, 1% less memory); zod3 is 1-2.5% slower with 10% more peak
memory. As built, `hash.Map` does not clear Trig's bar (more than 2%
faster, or 1% fewer instructions) on these caches; Trig decides.

## Tried and not kept

Growing in place (extend the slots, mark the full ones, and place each
key again with the in-place rehash, so about half stay put) was 30%
slower to grow than building a new table (17-18 ns against 13 per key,
100,000 keys, Mac); popping the old slots rather than taking each in
order, 8-15% slower.

## Deferred

- `List.filled(n, none)` for a List of an optional of an owning type
  (a `none` copies whatever the type holds): it would let growth write
  the free slots at once.
- The whole hash (decision 7b), through `hash_of`.
- A stored hash for keys over 8 bytes, as the built-in Map keeps,
  which would make String growth hash nothing again.
- `at(i)`, which reads an order, has no counterpart.
