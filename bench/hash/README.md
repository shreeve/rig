# Hash map benchmark

Times the built-in Map (`std/__rig_builtin.rig`) and std.hash's
unordered Map (`std/hash.rig`) against Zig's `std.HashMap`
(`AutoHashMapUnmanaged` and `StringHashMapUnmanaged`), both allocating
from `smp_allocator`, as a Rig program does, and against Rust's
`HashMap`, which is hashbrown, with FxHasher. It is not part of the
test suite or CI.

```sh
D=$(mktemp -d)
bench/hash/bench-hash --out $D --build-only
bench/hash/bench-hash --out $D --time-only
```

It needs `bin/rig` built first. `bench/hash/bench-hash --help` lists the
variants (`rig-safe` and `zig-safe` by default; `rig-fast`, `zig-fast`,
`hash-safe`, `hash-fast`, and `rust` on request) and the options.
`hash-*` builds map.rig with each `type X = Map[...]` alias rewritten to
`hash.Map[...]`, so the same program times std.hash. `rust` builds
`map.rs` with `rustc -C opt-level=3 -o rust map.rs` (no crate: Rust's
`HashMap` is hashbrown, and FxHasher is written out in the file), and
times only the sized rows.

The sized rows (`int16`, `int1000`, `int100000`, `int4000000`) time
Int keys at four sizes, 4,000,000 operations a row, reported per
operation: insert puts the keys into empty maps (a million keys a
batch: 62,500 maps of 16, 1,000 of 1,000, 10 of 100,000, or one of
4,000,000), remove takes each back out, hit and miss look keys up in
one map of that size, and iterate walks it.

Then each program inserts a million
keys into an empty map, looks each up, looks up a million it does not
hold, and walks the map, for Int and String keys; it inserts, looks up
and misses a million keys of two words as well, shaped as Trig's packed
cache keys are (`AutoHashMapUnmanaged` for Zig); the runs are
interleaved and the fastest of each operation counts. The Rig program
also times the three ways to write the value under a key whether or
not it is new (`ensure`, `ensure_with`, and `edit` then `put`), on
misses and on hits, which Zig's has no rows for.
