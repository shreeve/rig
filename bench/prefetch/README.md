# Prefetch benchmark

Times `xs.prefetch(i)` (SPEC, "Slices"): random lookups into a List of
2^25 `Int`s (256 MiB, far past every cache), each index a key hashed
and masked as a hash table's slot is, 2^24 lookups a pass. It prints the
nanoseconds of one lookup, the fastest of five rounds, the forms
interleaved, for no prefetch (`ahead 0`) and for a prefetch of the
lookup 8, 16, or 64 ahead. It is not part of the test suite or CI.

```sh
bin/rig build --release bench/prefetch/lookup.rig
tools/low ./lookup              # the Mac
taskset -c 8 ./lookup           # pup, on a P-core whose sibling is idle
```

- `flat` folds in each element it reads. Nothing depends on a load, so
  the core already overlaps the misses of many lookups.
- `branchy` runs a loop whose length the element sets, as a Map's
  probe stops where its tags say. Each mispredicted exit discards the
  loads begun past it, so without a prefetch the misses come one at a
  time.

## Results

`rig build --release` (Zig's ReleaseSafe), 2026-10-27, ns a lookup, the
fastest of three runs:

| Loop | Ahead | Apple M5 | pup (Core Ultra 9 185H, core 8) |
|---|---|---|---|
| flat | 0 | 3.02 | 6.52 |
| flat | 8 | 3.50 | 6.96 |
| flat | 16 | 3.30 | 5.89 |
| flat | 64 | 2.86 | 4.78 |
| branchy | 0 | 46.8 | 73.2 |
| branchy | 8 | 11.5 | 16.3 |
| branchy | 16 | 7.93 | 11.9 |
| branchy | 64 | 7.79 | 11.3 |

A prefetch far enough ahead makes `branchy` 6.0 times as fast on the Mac
and 6.5 times on pup, and `flat` 5% faster on the Mac and 36% faster on
pup; one only 8 ahead makes `flat` slower on both, since the line is
already on its way. `branchy` without a prefetch ran in 47 to 62 ns on
the Mac from one build to the next, by where its loop fell.

`xs.prefetch(i)` is one prefetch instruction with no range test. The
same loops with a test of `0 <= i < xs.len` before it (an unsigned
compare and a branch) ran as fast at 64 ahead, and slower closer in:
`flat` 8 ahead 3.96 ns on the Mac (13% more time) and 7.30 on pup (5%),
16 ahead 3.60 (9%) and 6.06 (3%); `branchy` the same within 2%.
