# HashMap and HashSet as compiler built-ins: what was measured (2026-10-27)

The design is [hashmap-builtin-design.md](hashmap-builtin-design.md):
`HashMap` and `HashSet` are declared in std/prelude.rig over the
built-ins `UnorderedMap[K, V]` and `UnorderedSet[K]`, bench/hash's
`zig-hash` ported into the runtime (src/unordered.zig). Branch
`hashmap-builtin` on main 9c07651e3 (#737). "Map" below is the ordered
built-in (`rig-fast`), built by the same `rig`.

## What differs from the prototype, and why

- **Rig's drops and `==`.** The table owns its keys and values and
  drops them as the ordered table does; a key that is not an integer
  of up to 64 bits or text hashes with `rig.hash` and compares with
  `rig.eql`, so a type's own `hash_into` and `==` hold. Integers and
  text keep `zig-hash`'s own hashes (decisions 7 and 8, inside the
  table; `.hash()` is unchanged).
- **A key over 8 bytes stores its hash** (the ordered table's rule),
  where `zig-hash` stores it for every key but an integer.
- **The insert claims its slot, then the caller writes the element**:
  one probe serves `put`, `replace`, `put_new`, and `ensure`. A growth
  moves the old entries first and claims the new key's slot after, where
  `zig-hash` places the new key first; nothing a program sees depends
  on it.
- **The walk steps by a group's full lanes** (`group_count`,
  `full_lanes`, `slot_at`), the lanes held in the iterator: a walk that
  found its next slot from the last (a division and a group load each
  step, carried through memory) took 4-7 ns an entry on the Mac,
  against 0.6 for this.
- **`get` and `edit` hand back the value's view where the lookup found
  its slot.** With `find` then `value(j)`, the slot's address was made
  twice and the multiplier rematerialized on the hit path: in-cache hits
  were 15-25% slower than `zig-hash` on the Mac (rnd16 hit 1.01 against
  0.84). Their origins are `from @` (resolve's `fromSelf`), as a Rig
  declaration with `from @` would have, since the key is only hashed and
  compared.
- **No bounds test on a slot index in a release build** (decision 10's
  exit, as map-builtin.md records for the ordered table): `slotAt`
  tests the index and that its slot is full in a debug build only.
- **The first put** makes `zig-hash`'s first table: 4 groups of 7 (27
  slots, 21 entries before growth) on arm64, 2 of 15 (29 slots, all
  usable) on x86-64.
- **Not taken from the prototype:** its `Options` (only the defaults
  are ported), the sentinel's use by an iterator (the walk reads full
  tags, `> 1`), and `byte_home`.

## Tests

`test/rig/std-hashmap.rig.test`: the Map cases of std-hash ported
(walks sorted), a model of Int keys over puts, takes, gets, edits,
`put_new`, `ensure`, `retain`, clear, and reserve at sizes that grow
the table several times; a model of String keys and values with
clones; drop counts of keys and values with drop bodies (246 keys and
171 values, each dropped once, as the review counted for the Map); keys
with their own `==` and hash, enum, Bool, optional, U8, Static, and text
over 32 bytes; ownership rejections; the entry limit before allocation;
a release build. src/unordered.zig's Zig tests (a model of 60,000
random operations at three key ranges, strided keys, a turnover that
drifts, checked against the table's invariants) pass in Debug,
ReleaseSafe, and ReleaseFast on arm64 and x86-64.

The 49 probes of the Map's review (map-builtin-review.md), each run
with `Map`/`Set` made `HashMap`/`HashSet`, under `RIG_SANITIZE=1`, give
what the Map gives, accepted or rejected with the same messages, and
the same output but for the order of a printed HashMap; the drop probe
drops the same keys and values. The two holes #737 left recorded (a
closure storing its key's view in a `(?String)?` or `List[?String]`
value through `update`) are the HashMap's too, as its declarations are
the Map's.

## Memory, one map of 4,000,000 Int keys

Peak bytes an entry (`bench-hash --mem`): Mac 51.1 (zig-hash 62.9, rust
71.4, Map 30.7); pup 54.5 (zig-hash 50.3, rust 53.5, Map 29.9). A
table at 0.4-0.8 of its slots holds 16-byte entries in 20-40 bytes; the
Map's dense entries and 32-bit index take less.

## std.json's guard (Mac, instructions)

0.0-0.7% fewer instructions per byte than guard.txt on all six files
(twitter 0.7%, twitterescaped 0.6%, canada 0.0%, citm_catalog 0.3%,
gsoc-2018 0.6%, github_events 0.6%).

## bench/hash

Times in ns an operation, fastest of 5, interleaved by bench-hash
(`rig-hash` is map.rig with its aliases made `HashMap`). Mac: Apple M5,
tools/low, other agents' suites running (load 3 to 4). pup: Core Ultra
9 185H, every run on core 3 (`taskset -c 3`), builds on cores 10-11.

On the Mac, of the 104 rows, 60 are within 5% of zig-hash or faster, 72
faster than rust (std HashMap with FxHash), and 59 faster than the Map.
On pup, 77 are within 5% of zig-hash or faster (62 faster), 73 faster
than rust, and 58 faster than the Map. The rows where an unordered table
should win are the HashMap's on both machines: removes at 4M (25-35%
faster than the Map), turnovers of 1,000 keys and up (Mac 52% faster at
1,000, pup 40% faster at 4M), inserts at 4M (Mac 21-35% faster, pup
8-24%), misses (52-81% faster at 3M-4M), random hits at 3M-4M (35-45%
faster), and the 4M latency chain (44% and 47% faster). Removes from
1,000 to 3M keys are level with the Map or trail it (Mac rnd3000000 14%
slower, pup rnd150000 49% slower), as the Map's take only clears a tag
and marks a bit. The other rows that trail the Map are its own: walks
(a group's lanes against a dense array), 16-key inserts and turnovers,
text inserts and removes, and removes of 64-byte values.

Against zig-hash the HashMap trails by more than 5% on text keys (a Rig
String is a heap List of bytes, 24 bytes beside the slot's value and
hash, so a slot is 40 bytes and gets no prefetch, and a take frees its
key; str100000 hit is 2.4-2.6 times zig-hash on both machines, as the
Map's is against zig-ordered), on the Mac's 3M-4M inserts and removes
and 1,000-100,000 turnovers (9-19%), and pup's 16-key 64-byte-value
inserts and removes. It leads zig-hash on pup's 4M rows, where Rig's
allocator faults pages in ahead (as the panel found for the Map).

### Mac

| row | HashMap | zig-hash | rust | Map | / zig-hash | / rust | / Map |
|---|---|---|---|---|---|---|---|
| int16 insert | 5.14 | 5.46 | 17.07 | 3.36 | 0.94 | 0.30 | 1.53 |
| int16 remove | 4.03 | 4.30 | 4.92 | 4.26 | 0.94 | 0.82 | 0.95 |
| int16 hit | 0.80 | 0.82 | 0.92 | 0.98 | 0.98 | 0.87 | 0.82 |
| int16 miss | 0.65 | 0.58 | 0.79 | 0.54 | 1.12 | 0.82 | 1.20 |
| int16 iterate | 0.61 | 0.59 | 0.44 | 0.12 | 1.03 | 1.39 | 5.08 |
| int1000 insert | 6.36 | 6.28 | 6.38 | 7.74 | 1.01 | 1.00 | 0.82 |
| int1000 remove | 2.64 | 2.57 | 3.14 | 2.77 | 1.03 | 0.84 | 0.95 |
| int1000 hit | 0.87 | 0.87 | 1.01 | 1.39 | 1.00 | 0.86 | 0.63 |
| int1000 miss | 0.66 | 0.61 | 0.76 | 1.09 | 1.08 | 0.87 | 0.61 |
| int1000 iterate | 0.61 | 0.59 | 0.59 | 0.09 | 1.03 | 1.03 | 6.78 |
| int100000 insert | 7.23 | 6.98 | 4.89 | 6.92 | 1.04 | 1.48 | 1.04 |
| int100000 remove | 4.72 | 4.44 | 3.22 | 4.98 | 1.06 | 1.47 | 0.95 |
| int100000 hit | 1.26 | 1.25 | 1.34 | 1.70 | 1.01 | 0.94 | 0.74 |
| int100000 miss | 0.69 | 0.64 | 0.75 | 1.46 | 1.08 | 0.92 | 0.47 |
| int100000 iterate | 0.81 | 0.83 | 0.63 | 0.14 | 0.98 | 1.29 | 5.79 |
| int4000000 insert | 11.10 | 10.66 | 9.97 | 17.19 | 1.04 | 1.11 | 0.65 |
| int4000000 remove | 9.42 | 8.97 | 6.97 | 14.44 | 1.05 | 1.35 | 0.65 |
| int4000000 hit | 6.39 | 6.43 | 4.67 | 6.59 | 0.99 | 1.37 | 0.97 |
| int4000000 miss | 0.86 | 0.77 | 1.49 | 4.51 | 1.12 | 0.58 | 0.19 |
| int4000000 iterate | 0.69 | 0.70 | 0.61 | 0.21 | 0.99 | 1.13 | 3.29 |
| rnd16 insert | 5.90 | 6.00 | 18.85 | 3.22 | 0.98 | 0.31 | 1.83 |
| rnd16 remove | 4.18 | 4.04 | 6.16 | 4.61 | 1.03 | 0.68 | 0.91 |
| rnd16 hit | 0.88 | 0.84 | 0.80 | 0.95 | 1.05 | 1.10 | 0.93 |
| rnd16 miss | 0.64 | 0.58 | 0.78 | 0.56 | 1.10 | 0.82 | 1.14 |
| rnd16 iterate | 0.59 | 0.60 | 0.46 | 0.10 | 0.98 | 1.28 | 5.90 |
| rnd24 insert | 9.87 | 10.58 | 14.59 | 7.58 | 0.93 | 0.68 | 1.30 |
| rnd24 remove | 3.78 | 3.75 | 9.59 | 4.91 | 1.01 | 0.39 | 0.77 |
| rnd24 hit | 0.90 | 0.88 | 0.84 | 1.17 | 1.02 | 1.07 | 0.77 |
| rnd24 miss | 0.63 | 0.56 | 1.08 | 0.93 | 1.12 | 0.58 | 0.68 |
| rnd24 iterate | 0.61 | 0.63 | 0.45 | 0.11 | 0.97 | 1.36 | 5.55 |
| rnd1000 insert | 8.49 | 8.78 | 14.46 | 7.48 | 0.97 | 0.59 | 1.14 |
| rnd1000 remove | 3.08 | 3.03 | 5.65 | 2.81 | 1.02 | 0.55 | 1.10 |
| rnd1000 hit | 1.03 | 0.90 | 0.92 | 1.25 | 1.14 | 1.12 | 0.82 |
| rnd1000 miss | 0.66 | 0.76 | 1.16 | 1.10 | 0.87 | 0.57 | 0.60 |
| rnd1000 iterate | 0.60 | 0.56 | 0.49 | 0.09 | 1.07 | 1.22 | 6.67 |
| rnd1500 insert | 10.22 | 10.60 | 10.80 | 6.78 | 0.96 | 0.95 | 1.51 |
| rnd1500 remove | 3.17 | 3.15 | 8.64 | 4.16 | 1.01 | 0.37 | 0.76 |
| rnd1500 hit | 0.99 | 0.88 | 0.91 | 1.44 | 1.12 | 1.09 | 0.69 |
| rnd1500 miss | 0.72 | 0.68 | 1.42 | 0.97 | 1.06 | 0.51 | 0.74 |
| rnd1500 iterate | 0.69 | 0.69 | 0.64 | 0.09 | 1.00 | 1.08 | 7.67 |
| rnd100000 insert | 9.75 | 9.83 | 10.52 | 6.71 | 0.99 | 0.93 | 1.45 |
| rnd100000 remove | 4.51 | 4.29 | 8.20 | 5.10 | 1.05 | 0.55 | 0.88 |
| rnd100000 hit | 1.44 | 1.42 | 1.66 | 2.36 | 1.01 | 0.87 | 0.61 |
| rnd100000 miss | 0.87 | 0.77 | 4.83 | 1.47 | 1.13 | 0.18 | 0.59 |
| rnd100000 iterate | 1.44 | 1.59 | 1.26 | 0.16 | 0.91 | 1.14 | 9.00 |
| rnd150000 insert | 7.05 | 6.66 | 11.65 | 6.85 | 1.06 | 0.61 | 1.03 |
| rnd150000 remove | 3.88 | 3.58 | 6.86 | 3.54 | 1.08 | 0.57 | 1.10 |
| rnd150000 hit | 1.64 | 1.55 | 1.33 | 2.09 | 1.06 | 1.23 | 0.78 |
| rnd150000 miss | 1.04 | 1.11 | 1.80 | 1.49 | 0.94 | 0.58 | 0.70 |
| rnd150000 iterate | 1.26 | 1.26 | 1.74 | 0.15 | 1.00 | 0.72 | 8.40 |
| rnd3000000 insert | 12.30 | 11.28 | 9.64 | 9.91 | 1.09 | 1.28 | 1.24 |
| rnd3000000 remove | 7.99 | 7.33 | 9.28 | 7.02 | 1.09 | 0.86 | 1.14 |
| rnd3000000 hit | 5.42 | 5.38 | 4.57 | 8.64 | 1.01 | 1.19 | 0.63 |
| rnd3000000 miss | 1.32 | 1.30 | 4.19 | 3.37 | 1.02 | 0.32 | 0.39 |
| rnd3000000 iterate | 2.12 | 2.06 | 1.11 | 0.16 | 1.03 | 1.91 | 13.25 |
| rnd4000000 insert | 13.24 | 11.15 | 18.69 | 16.70 | 1.19 | 0.71 | 0.79 |
| rnd4000000 remove | 10.42 | 9.04 | 14.44 | 14.55 | 1.15 | 0.72 | 0.72 |
| rnd4000000 hit | 7.42 | 7.12 | 7.38 | 11.48 | 1.04 | 1.01 | 0.65 |
| rnd4000000 miss | 1.96 | 1.94 | 2.90 | 4.34 | 1.01 | 0.68 | 0.45 |
| rnd4000000 iterate | 2.12 | 2.24 | 2.12 | 0.21 | 0.95 | 1.00 | 10.10 |
| lat16 chain | 6.94 | 6.89 | 7.25 | 8.20 | 1.01 | 0.96 | 0.85 |
| lat1000 chain | 6.91 | 6.83 | 7.32 | 9.58 | 1.01 | 0.94 | 0.72 |
| lat100000 chain | 12.89 | 12.75 | 14.26 | 18.08 | 1.01 | 0.90 | 0.71 |
| lat4000000 chain | 98.18 | 99.11 | 135.10 | 174.98 | 0.99 | 0.73 | 0.56 |
| churn16 turnover | 4.06 | 4.00 | 7.17 | 3.87 | 1.01 | 0.57 | 1.05 |
| churn1000 turnover | 2.01 | 1.70 | 7.38 | 4.22 | 1.18 | 0.27 | 0.48 |
| churn100000 turnover | 3.10 | 2.72 | 8.05 | 4.02 | 1.14 | 0.39 | 0.77 |
| churn4000000 turnover | 9.26 | 9.41 | 11.74 | 15.22 | 0.98 | 0.79 | 0.61 |
| mix16 half | 0.68 | 0.68 | 0.74 | 0.70 | 1.00 | 0.92 | 0.97 |
| mix1000 half | 0.77 | 0.82 | 1.04 | 1.11 | 0.94 | 0.74 | 0.69 |
| mix100000 half | 4.06 | 4.50 | 7.34 | 5.23 | 0.90 | 0.55 | 0.78 |
| mix4000000 half | 9.29 | 9.87 | 9.52 | 12.24 | 0.94 | 0.98 | 0.76 |
| str16 insert | 12.39 | 7.65 | 37.96 | 8.11 | 1.62 | 0.33 | 1.53 |
| str16 remove | 18.62 | 9.00 | 28.39 | 19.91 | 2.07 | 0.66 | 0.94 |
| str16 hit | 3.07 | 2.84 | 8.10 | 4.27 | 1.08 | 0.38 | 0.72 |
| str16 miss | 1.81 | 1.64 | 6.01 | 1.97 | 1.10 | 0.30 | 0.92 |
| str1000 insert | 13.73 | 13.10 | 42.59 | 10.81 | 1.05 | 0.32 | 1.27 |
| str1000 remove | 21.40 | 13.85 | 28.43 | 21.18 | 1.55 | 0.75 | 1.01 |
| str1000 hit | 3.45 | 2.62 | 7.75 | 5.41 | 1.32 | 0.45 | 0.64 |
| str1000 miss | 2.42 | 2.25 | 8.23 | 2.44 | 1.08 | 0.29 | 0.99 |
| str100000 insert | 20.29 | 17.52 | 34.35 | 10.83 | 1.16 | 0.59 | 1.87 |
| str100000 remove | 34.51 | 30.30 | 43.23 | 27.03 | 1.14 | 0.80 | 1.28 |
| str100000 hit | 15.52 | 6.49 | 16.08 | 17.28 | 2.39 | 0.97 | 0.90 |
| str100000 miss | 2.92 | 2.50 | 16.48 | 5.34 | 1.17 | 0.18 | 0.55 |
| str1000000 insert | 32.84 | 17.20 | 66.74 | 15.85 | 1.91 | 0.49 | 2.07 |
| str1000000 remove | 45.04 | 37.32 | 70.46 | 35.07 | 1.21 | 0.64 | 1.28 |
| str1000000 hit | 34.41 | 26.84 | 48.08 | 48.38 | 1.28 | 0.72 | 0.71 |
| str1000000 miss | 4.86 | 4.04 | 11.75 | 6.12 | 1.20 | 0.41 | 0.79 |
| big16 insert | 6.60 | 7.49 | 22.05 | 5.90 | 0.88 | 0.30 | 1.12 |
| big16 remove | 4.30 | 4.30 | 8.29 | 4.48 | 1.00 | 0.52 | 0.96 |
| big16 hit | 1.03 | 0.95 | 0.87 | 1.05 | 1.08 | 1.18 | 0.98 |
| big16 iterate | 0.59 | 0.58 | 0.50 | 0.11 | 1.02 | 1.18 | 5.36 |
| big1000 insert | 10.38 | 12.84 | 18.66 | 9.55 | 0.81 | 0.56 | 1.09 |
| big1000 remove | 5.90 | 5.65 | 8.68 | 3.00 | 1.04 | 0.68 | 1.97 |
| big1000 hit | 1.17 | 1.08 | 0.86 | 1.30 | 1.08 | 1.36 | 0.90 |
| big1000 iterate | 0.59 | 0.57 | 0.49 | 0.09 | 1.04 | 1.20 | 6.56 |
| big100000 insert | 18.19 | 17.49 | 16.30 | 10.40 | 1.04 | 1.12 | 1.75 |
| big100000 remove | 9.72 | 8.22 | 12.09 | 5.29 | 1.18 | 0.80 | 1.84 |
| big100000 hit | 2.53 | 2.22 | 2.37 | 3.32 | 1.14 | 1.07 | 0.76 |
| big100000 iterate | 1.38 | 1.52 | 1.31 | 0.59 | 0.91 | 1.05 | 2.34 |
| big1000000 insert | 25.15 | 21.92 | 29.28 | 18.81 | 1.15 | 0.86 | 1.34 |
| big1000000 remove | 11.83 | 9.97 | 17.77 | 7.72 | 1.19 | 0.67 | 1.53 |
| big1000000 hit | 8.85 | 8.48 | 6.71 | 12.07 | 1.04 | 1.32 | 0.73 |
| big1000000 iterate | 2.12 | 2.11 | 2.26 | 0.86 | 1.00 | 0.94 | 2.47 |

### pup

| row | HashMap | zig-hash | rust | Map | / zig-hash | / rust | / Map |
|---|---|---|---|---|---|---|---|
| int16 insert | 6.43 | 7.46 | 25.74 | 6.19 | 0.86 | 0.25 | 1.04 |
| int16 remove | 4.77 | 4.83 | 8.94 | 5.05 | 0.99 | 0.53 | 0.94 |
| int16 hit | 1.10 | 1.21 | 1.28 | 1.27 | 0.91 | 0.86 | 0.87 |
| int16 miss | 0.86 | 0.95 | 1.56 | 0.87 | 0.91 | 0.55 | 0.99 |
| int16 iterate | 0.67 | 0.63 | 0.42 | 0.21 | 1.06 | 1.60 | 3.19 |
| int1000 insert | 12.73 | 12.00 | 17.83 | 10.42 | 1.06 | 0.71 | 1.22 |
| int1000 remove | 3.93 | 3.94 | 4.10 | 4.98 | 1.00 | 0.96 | 0.79 |
| int1000 hit | 1.10 | 1.20 | 1.15 | 1.62 | 0.92 | 0.96 | 0.68 |
| int1000 miss | 0.84 | 0.95 | 1.07 | 1.49 | 0.88 | 0.79 | 0.56 |
| int1000 iterate | 0.66 | 0.63 | 0.53 | 0.21 | 1.05 | 1.25 | 3.14 |
| int100000 insert | 9.92 | 9.43 | 13.41 | 11.85 | 1.05 | 0.74 | 0.84 |
| int100000 remove | 7.07 | 7.33 | 10.21 | 8.11 | 0.96 | 0.69 | 0.87 |
| int100000 hit | 1.97 | 2.02 | 1.98 | 2.90 | 0.98 | 0.99 | 0.68 |
| int100000 miss | 1.35 | 1.41 | 1.80 | 3.36 | 0.96 | 0.75 | 0.40 |
| int100000 iterate | 0.74 | 0.62 | 0.53 | 0.22 | 1.19 | 1.40 | 3.36 |
| int4000000 insert | 23.25 | 34.63 | 33.61 | 30.53 | 0.67 | 0.69 | 0.76 |
| int4000000 remove | 19.16 | 22.40 | 17.72 | 25.52 | 0.86 | 1.08 | 0.75 |
| int4000000 hit | 13.19 | 15.62 | 10.97 | 15.44 | 0.84 | 1.20 | 0.85 |
| int4000000 miss | 1.81 | 2.86 | 3.53 | 9.34 | 0.63 | 0.51 | 0.19 |
| int4000000 iterate | 2.28 | 2.37 | 1.77 | 0.66 | 0.96 | 1.29 | 3.45 |
| rnd16 insert | 6.66 | 7.21 | 26.61 | 5.82 | 0.92 | 0.25 | 1.14 |
| rnd16 remove | 5.71 | 5.84 | 8.59 | 5.21 | 0.98 | 0.66 | 1.10 |
| rnd16 hit | 1.02 | 1.07 | 1.00 | 1.09 | 0.95 | 1.02 | 0.94 |
| rnd16 miss | 0.93 | 0.93 | 1.38 | 0.74 | 1.00 | 0.67 | 1.26 |
| rnd16 iterate | 0.65 | 0.68 | 0.42 | 0.21 | 0.96 | 1.55 | 3.10 |
| rnd24 insert | 6.50 | 7.01 | 15.72 | 9.27 | 0.93 | 0.41 | 0.70 |
| rnd24 remove | 5.74 | 5.82 | 8.17 | 4.63 | 0.99 | 0.70 | 1.24 |
| rnd24 hit | 1.03 | 1.08 | 1.19 | 1.55 | 0.95 | 0.87 | 0.66 |
| rnd24 miss | 0.93 | 0.93 | 1.20 | 1.34 | 1.00 | 0.78 | 0.69 |
| rnd24 iterate | 0.60 | 0.70 | 0.43 | 0.21 | 0.86 | 1.40 | 2.86 |
| rnd1000 insert | 14.37 | 14.55 | 15.05 | 10.00 | 0.99 | 0.95 | 1.44 |
| rnd1000 remove | 5.00 | 4.63 | 9.71 | 5.76 | 1.08 | 0.51 | 0.87 |
| rnd1000 hit | 1.14 | 1.24 | 1.02 | 1.51 | 0.92 | 1.12 | 0.75 |
| rnd1000 miss | 0.99 | 1.05 | 1.27 | 1.35 | 0.94 | 0.78 | 0.73 |
| rnd1000 iterate | 0.60 | 0.59 | 0.41 | 0.21 | 1.02 | 1.46 | 2.86 |
| rnd1500 insert | 11.28 | 11.24 | 11.15 | 9.80 | 1.00 | 1.01 | 1.15 |
| rnd1500 remove | 4.47 | 4.22 | 10.75 | 6.24 | 1.06 | 0.42 | 0.72 |
| rnd1500 hit | 1.25 | 1.28 | 1.19 | 1.77 | 0.98 | 1.05 | 0.71 |
| rnd1500 miss | 1.12 | 1.11 | 1.46 | 1.57 | 1.01 | 0.77 | 0.71 |
| rnd1500 iterate | 0.61 | 0.51 | 0.41 | 0.21 | 1.20 | 1.49 | 2.90 |
| rnd100000 insert | 11.77 | 12.25 | 11.30 | 11.92 | 0.96 | 1.04 | 0.99 |
| rnd100000 remove | 8.67 | 8.52 | 15.84 | 8.38 | 1.02 | 0.55 | 1.03 |
| rnd100000 hit | 2.45 | 2.63 | 2.30 | 4.49 | 0.93 | 1.07 | 0.55 |
| rnd100000 miss | 2.44 | 2.64 | 4.10 | 3.32 | 0.92 | 0.60 | 0.73 |
| rnd100000 iterate | 1.02 | 0.86 | 0.91 | 0.23 | 1.19 | 1.12 | 4.43 |
| rnd150000 insert | 12.82 | 13.23 | 12.26 | 13.23 | 0.97 | 1.05 | 0.97 |
| rnd150000 remove | 12.33 | 11.57 | 17.90 | 8.29 | 1.07 | 0.69 | 1.49 |
| rnd150000 hit | 2.15 | 2.55 | 2.45 | 3.54 | 0.84 | 0.88 | 0.61 |
| rnd150000 miss | 1.52 | 1.68 | 1.98 | 2.27 | 0.90 | 0.77 | 0.67 |
| rnd150000 iterate | 1.36 | 1.15 | 1.20 | 0.24 | 1.18 | 1.13 | 5.67 |
| rnd3000000 insert | 14.59 | 20.03 | 23.45 | 14.96 | 0.73 | 0.62 | 0.98 |
| rnd3000000 remove | 15.08 | 15.09 | 19.38 | 19.97 | 1.00 | 0.78 | 0.76 |
| rnd3000000 hit | 10.55 | 11.92 | 10.47 | 19.03 | 0.89 | 1.01 | 0.55 |
| rnd3000000 miss | 4.03 | 4.66 | 5.40 | 8.41 | 0.86 | 0.75 | 0.48 |
| rnd3000000 iterate | 1.15 | 1.26 | 1.31 | 0.50 | 0.91 | 0.88 | 2.30 |
| rnd4000000 insert | 25.66 | 37.27 | 43.93 | 27.94 | 0.69 | 0.58 | 0.92 |
| rnd4000000 remove | 19.26 | 21.34 | 32.15 | 26.52 | 0.90 | 0.60 | 0.73 |
| rnd4000000 hit | 14.48 | 15.95 | 15.61 | 25.44 | 0.91 | 0.93 | 0.57 |
| rnd4000000 miss | 5.14 | 5.62 | 6.18 | 11.05 | 0.91 | 0.83 | 0.47 |
| rnd4000000 iterate | 2.55 | 2.56 | 2.43 | 0.66 | 1.00 | 1.05 | 3.86 |
| lat16 chain | 5.12 | 5.13 | 4.95 | 4.83 | 1.00 | 1.03 | 1.06 |
| lat1000 chain | 5.20 | 5.25 | 5.30 | 6.74 | 0.99 | 0.98 | 0.77 |
| lat100000 chain | 10.42 | 10.24 | 15.79 | 17.15 | 1.02 | 0.66 | 0.61 |
| lat4000000 chain | 155.43 | 158.48 | 248.61 | 294.59 | 0.98 | 0.63 | 0.53 |
| churn16 turnover | 5.45 | 5.62 | 5.69 | 4.20 | 0.97 | 0.96 | 1.30 |
| churn1000 turnover | 3.87 | 3.24 | 7.83 | 5.44 | 1.19 | 0.49 | 0.71 |
| churn100000 turnover | 4.30 | 4.26 | 8.64 | 5.58 | 1.01 | 0.50 | 0.77 |
| churn4000000 turnover | 16.88 | 19.37 | 29.66 | 28.02 | 0.87 | 0.57 | 0.60 |
| mix16 half | 0.89 | 1.04 | 0.98 | 0.86 | 0.86 | 0.91 | 1.03 |
| mix1000 half | 0.89 | 0.99 | 1.01 | 1.38 | 0.90 | 0.88 | 0.64 |
| mix100000 half | 6.65 | 6.63 | 6.99 | 7.75 | 1.00 | 0.95 | 0.86 |
| mix4000000 half | 13.16 | 14.47 | 12.72 | 24.54 | 0.91 | 1.03 | 0.54 |
| str16 insert | 25.17 | 23.46 | 56.44 | 18.18 | 1.07 | 0.45 | 1.38 |
| str16 remove | 20.85 | 15.30 | 33.24 | 16.87 | 1.36 | 0.63 | 1.24 |
| str16 hit | 3.48 | 3.89 | 15.82 | 4.81 | 0.89 | 0.22 | 0.72 |
| str16 miss | 1.64 | 2.02 | 9.60 | 2.62 | 0.81 | 0.17 | 0.63 |
| str1000 insert | 26.06 | 22.79 | 56.96 | 17.97 | 1.14 | 0.46 | 1.45 |
| str1000 remove | 24.94 | 21.62 | 51.11 | 19.04 | 1.15 | 0.49 | 1.31 |
| str1000 hit | 3.47 | 3.55 | 18.52 | 6.55 | 0.98 | 0.19 | 0.53 |
| str1000 miss | 2.34 | 2.79 | 9.99 | 3.36 | 0.84 | 0.23 | 0.70 |
| str100000 insert | 26.37 | 22.33 | 65.71 | 25.16 | 1.18 | 0.40 | 1.05 |
| str100000 remove | 42.26 | 40.48 | 108.58 | 29.75 | 1.04 | 0.39 | 1.42 |
| str100000 hit | 33.61 | 12.80 | 58.95 | 50.04 | 2.63 | 0.57 | 0.67 |
| str100000 miss | 9.05 | 5.63 | 18.52 | 10.45 | 1.61 | 0.49 | 0.87 |
| str1000000 insert | 53.34 | 51.36 | 158.44 | 40.22 | 1.04 | 0.34 | 1.33 |
| str1000000 remove | 62.35 | 85.82 | 183.92 | 56.48 | 0.73 | 0.34 | 1.10 |
| str1000000 hit | 51.29 | 48.00 | 285.87 | 102.94 | 1.07 | 0.18 | 0.50 |
| str1000000 miss | 11.97 | 8.38 | 27.30 | 14.94 | 1.43 | 0.44 | 0.80 |
| big16 insert | 19.46 | 15.11 | 27.31 | 12.63 | 1.29 | 0.71 | 1.54 |
| big16 remove | 18.56 | 14.83 | 22.39 | 6.23 | 1.25 | 0.83 | 2.98 |
| big16 hit | 1.20 | 1.15 | 1.05 | 1.11 | 1.04 | 1.14 | 1.08 |
| big16 iterate | 0.64 | 0.55 | 0.42 | 0.21 | 1.16 | 1.52 | 3.05 |
| big1000 insert | 22.88 | 26.59 | 23.02 | 13.71 | 0.86 | 0.99 | 1.67 |
| big1000 remove | 8.42 | 8.21 | 16.28 | 7.44 | 1.03 | 0.52 | 1.13 |
| big1000 hit | 1.34 | 1.35 | 1.18 | 1.63 | 0.99 | 1.14 | 0.82 |
| big1000 iterate | 0.63 | 0.60 | 0.44 | 0.25 | 1.05 | 1.43 | 2.52 |
| big100000 insert | 27.45 | 24.84 | 22.57 | 23.17 | 1.11 | 1.22 | 1.18 |
| big100000 remove | 19.22 | 17.43 | 25.59 | 10.42 | 1.10 | 0.75 | 1.84 |
| big100000 hit | 4.44 | 4.67 | 4.26 | 4.95 | 0.95 | 1.04 | 0.90 |
| big100000 iterate | 1.39 | 1.27 | 1.31 | 0.81 | 1.09 | 1.06 | 1.72 |
| big1000000 insert | 53.66 | 85.45 | 95.04 | 33.54 | 0.63 | 0.56 | 1.60 |
| big1000000 remove | 21.61 | 21.96 | 31.89 | 19.47 | 0.98 | 0.68 | 1.11 |
| big1000000 hit | 16.49 | 17.60 | 17.10 | 21.81 | 0.94 | 0.96 | 0.76 |
| big1000000 iterate | 6.28 | 5.82 | 6.06 | 2.69 | 1.08 | 1.04 | 2.33 |
